/*
 * Copyright (C) 2020-2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "RemoteRenderingBackend.h"

#if ENABLE(GPU_PROCESS)

#include "GPUConnectionToWebProcess.h"
#include "Logging.h"
#include "RemoteImageBufferProxyMessages.h"
#include "RemoteRenderingBackendProxyMessages.h"
#include "RemoteSharedResourceCache.h"
#include <WebCore/FontCustomPlatformData.h>
#include <wtf/CheckedArithmetic.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "GPUProcess.h"
#include "ImageBufferShareableBitmapBackend.h"
#include "ImageBufferShareableMappedIOSurfaceBackend.h"
#include "ImageBufferShareableMappedIOSurfaceBitmapBackend.h"
#include "SharedFont.h"
#include <WebCore/Filter.h>
#include <WebCore/Gradient.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NullImageBufferBackend.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#import "DynamicContentScalingBifurcatedImageBuffer.h"
#endif
#else
#include "BufferIdentifierSet.h"
#include "GPUProcess.h"
#include "GPUProcessProxyMessages.h"
#include "ImageBufferShareableBitmapBackend.h"
#include "PrepareBackingStoreBuffersData.h"
#include "RemoteDisplayListRecorder.h"
#include "RemoteGraphicsContextIdentifier.h"
#include "RemoteImageBuffer.h"
#include "RemoteImageBufferSet.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include "RemoteMediaPlayerProxy.h"
#include "RemoteRenderingBackendMessages.h"
#include "RemoteSnapshotRecorder.h"
#include "SharedFont.h"
#include "WebPageProxy.h"
#include <WebCore/Filter.h>
#include <WebCore/SVGFilterRenderer.h>
#include <WebCore/Gradient.h>
#include <WebCore/HTMLCanvasElement.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NullImageBufferBackend.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/Borrow.h>
#include <wtf/RunLoop.h>
#include <wtf/StdLibExtras.h>
#include <wtf/SystemTracing.h>

#if HAVE(IOSURFACE)
#include "ImageBufferRemoteIOSurfaceBackend.h"
#include "ImageBufferShareableMappedIOSurfaceBackend.h"
#include "ImageBufferShareableMappedIOSurfaceBitmapBackend.h"
#include <WebCore/IOSurfacePool.h>
#endif


#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#import "DynamicContentScalingBifurcatedImageBuffer.h"
#import "DynamicContentScalingImageBufferBackend.h"
#endif
#endif

namespace WebKit {
using namespace WebCore;

bool isSmallLayerBacking(const ImageBufferParameters& parameters)
{
    const unsigned maxSmallLayerBackingArea = 64u * 64u; // 4096 == 16kb backing store which equals 1 page on AS.
    auto checkedArea = ImageBuffer::calculateBackendSize(parameters.logicalSize, parameters.resolutionScale).area<RecordOverflow>();
    return (parameters.purpose == RenderingPurpose::LayerBacking)
        && !checkedArea.hasOverflowed() && checkedArea <= maxSmallLayerBackingArea
        && (parameters.bufferFormat.pixelFormat == PixelFormat::BGRA8 || parameters.bufferFormat.pixelFormat == PixelFormat::BGRX8);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteRenderingBackend);

Ref<RemoteRenderingBackend> RemoteRenderingBackend::create(GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteRenderingBackendIdentifier identifier, Ref<IPC::StreamServerConnection>&& streamConnection)
{
    return adoptRef(*new RemoteRenderingBackend(gpuConnectionToWebProcess, identifier, WTF::move(streamConnection)));
}

RemoteRenderingBackend::RemoteRenderingBackend(GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteRenderingBackendIdentifier identifier, Ref<IPC::StreamServerConnection>&& streamConnection)
    : m_workQueue(IPC::StreamConnectionWorkQueue::create("RemoteRenderingBackend work queue"_s))
    , m_streamConnection(WTF::move(streamConnection))
    , m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_sharedResourceCache(gpuConnectionToWebProcess.sharedResourceCache())
    , m_sharedPreferencesForWebProcess(gpuConnectionToWebProcess.sharedPreferencesForWebProcessValue())
    , m_renderingBackendIdentifier(identifier)
{
    ASSERT(RunLoop::isMain());
    weakPtrFactory().prepareForUseOnlyOnNonMainThread();
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

// What Swift can't do of the backend's work: take the arguments it has no form of, and send messages.

RemoteRenderingBackend::~RemoteRenderingBackend()
{
    if (auto swiftState = std::exchange(m_swiftState, 0))
        destroySwiftState(swiftState);
}

void RemoteRenderingBackend::didReceiveInvalidMessage(IPC::StreamServerConnection&, IPC::MessageName messageName, const Vector<uint32_t>&)
{
    RELEASE_LOG_FAULT_WITH_PAYLOAD(IPC, "Received an invalid message %s from WebContent process %" PRIu64 ", requesting for it to be terminated.", description(messageName), m_gpuConnectionToWebProcess->webProcessIdentifier().toUInt64());
    callOnMainRunLoop([gpuConnectionToWebProcess = m_gpuConnectionToWebProcess, messageName] {
        gpuConnectionToWebProcess->terminateWebProcess(messageName);
    });
}

void RemoteRenderingBackend::cacheNativeImageFromSharedNativeImage(RemoteNativeImageReadReference&& reference)
{
    auto identifier = reference.identifier();
    auto image = m_sharedResourceCache->readNativeImage(m_streamConnection, WTF::move(reference));
    swiftCacheSharedNativeImage(identifier, !!image, image ? image->get() : nullptr);
}

void RemoteRenderingBackend::cacheFontCustomPlatformData(FontCustomPlatformSerializedData&& serializedData)
{
#if HAVE(CTFONTMANAGER_CREATEMEMORYSAFEFONTDESCRIPTORFROMDATA)
    bool shouldUseLockdownFontParser = (m_sharedPreferencesForWebProcess.lockdownFontParserEnabled && m_gpuConnectionToWebProcess->isLockdownModeEnabled()) || m_sharedPreferencesForWebProcess.forceLockdownFontParserEnabled;
#else
    bool shouldUseLockdownFontParser = false;
#endif
    auto customPlatformData = FontCustomPlatformData::tryMakeFromSerializationData(WTF::move(serializedData), shouldUseLockdownFontParser);
    swiftCacheFontCustomPlatformData(customPlatformData ? customPlatformData->ptr() : nullptr, customPlatformData ? (*customPlatformData)->m_renderingResourceIdentifier.toUInt64() : 0);
}

void RemoteRenderingBackend::sendDidFailToCreateBackend(RenderingResourceIdentifier identifier)
{
    m_streamConnection->send(Messages::RemoteImageBufferProxy::DidFailToCreateBackend(), identifier);
}

void RemoteRenderingBackend::sendDidMarkLayersAsVolatile(MarkSurfacesAsVolatileRequestIdentifier requestIdentifier, ImageBufferSetVolatileBuffers&& markedBufferSets, bool allSucceeded)
{
    m_streamConnection->send(Messages::RemoteRenderingBackendProxy::DidMarkLayersAsVolatile(requestIdentifier, WTF::move(markedBufferSets), allSucceeded), m_renderingBackendIdentifier);
}

void RemoteRenderingBackend::sendDidFinalizeRenderingUpdate(RenderingUpdateID renderingUpdateID)
{
    m_streamConnection->send(Messages::RemoteRenderingBackendProxy::DidFinalizeRenderingUpdate(renderingUpdateID), m_renderingBackendIdentifier);
}

void RemoteRenderingBackend::adjustImageBufferCreationContext(RemoteSharedResourceCache& sharedResourceCache, ImageBufferCreationContext& creationContext)
{
#if HAVE(IOSURFACE)
    creationContext.surfacePool = sharedResourceCache.ioSurfacePool();
#endif
    creationContext.resourceOwner = sharedResourceCache.resourceOwner();
}

void RemoteRenderingBackend::clearSurfacePool(ImageBufferCreationContext& creationContext)
{
#if HAVE(IOSURFACE)
    creationContext.surfacePool = nullptr;
#else
    UNUSED_PARAM(creationContext);
#endif
}

template<typename ImageBufferType>
static RefPtr<ImageBuffer> createImageBufferOfType(const FloatSize& logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, const ColorSpace& colorSpace, ImageBufferFormat bufferFormat, const ImageBufferCreationContext& creationContext)
{
    RefPtr<ImageBuffer> imageBuffer;
    if (renderingMode == RenderingMode::Accelerated) {
        if (isSmallLayerBacking({ logicalSize, resolutionScale, colorSpace, bufferFormat, purpose }))
            imageBuffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBitmapBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
        if (!imageBuffer)
            imageBuffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
    }
    if (!imageBuffer)
        imageBuffer = ImageBuffer::create<ImageBufferShareableBitmapBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
    return imageBuffer;
}

RefPtr<ImageBuffer> RemoteRenderingBackend::makeImageBuffer(FloatSize logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, ColorSpace colorSpace, ImageBufferFormat bufferFormat, const ImageBufferCreationContext& baseCreationContext)
{
    auto& preferences = m_sharedPreferencesForWebProcess;
    RELEASE_ASSERT(renderingMode == RenderingMode::Accelerated || renderingMode == RenderingMode::Unaccelerated);
    auto creationContext = baseCreationContext;
#if USE(APPLE_INTERNAL_SDK)
    creationContext.useIOSurfaceWebKitBehavior = preferences.useIOSurfaceWebKitBehavior;
#endif
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    if (preferences.useCGDisplayListsForDOMRendering && creationContext.dynamicContentScalingResourceCache) {
        if (RefPtr imageBuffer = createImageBufferOfType<DynamicContentScalingBifurcatedImageBuffer>(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, creationContext))
            return imageBuffer;
    }
#endif
    UNUSED_VARIABLE(preferences);
    return createImageBufferOfType<ImageBuffer>(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, creationContext);
}

RefPtr<ImageBuffer> RemoteRenderingBackend::createImageBufferAdoptingBitmap(FloatSize logicalSize, float resolutionScale, ColorSpace colorSpace, ImageBufferFormat bufferFormat, RenderingPurpose purpose, const ImageBufferCreationContext& creationContext, ShareableBitmapHandleBox& bitmap)
{
    ImageBuffer::Parameters parameters { logicalSize, resolutionScale, colorSpace, bufferFormat, purpose };
    auto backend = ImageBufferShareableBitmapBackend::create(parameters, WTF::move(*bitmap));
    if (!backend)
        return nullptr;
    return ImageBuffer::create(parameters, creationContext, WTF::move(backend));
}

bool RemoteRenderingBackend::addSerializedImageBuffer(RemoteSharedResourceCache& sharedResourceCache, RemoteSerializedImageBufferIdentifier identifier, RefPtr<ImageBuffer>& imageBuffer)
{
    imageBuffer->releaseGraphicsContext();
    return sharedResourceCache.addSerializedImageBuffer(identifier, imageBuffer.releaseNonNull());
}

std::optional<ImageBufferTransferIdentifier> RemoteRenderingBackend::depositTransferredImageBuffer(ProcessIdentifier owner, RefPtr<ImageBuffer>& imageBuffer)
{
    return GPUProcess::singleton().depositTransferredImageBuffer(owner, imageBuffer.releaseNonNull());
}

RefPtr<ImageBuffer> RemoteRenderingBackend::takeTransferredImageBuffer(const ImageBufferTransferHandle& handle)
{
    RefPtr imageBuffer = GPUProcess::singleton().takeTransferredImageBuffer(handle.identifier);
    if (!imageBuffer || handle.parameters != imageBuffer->parameters())
        return nullptr;
    if (handle.renderingMode == imageBuffer->renderingMode())
        return imageBuffer;
    if (handle.renderingMode == RenderingMode::Accelerated && imageBuffer->renderingMode() == RenderingMode::Unaccelerated)
        return imageBuffer;
    return nullptr;
}

std::optional<ShareableBitmap::Handle> RemoteRenderingBackend::createBitmapHandleReplacingPlatformImage(NativeImage& image)
{
    auto& resourceOwner = m_sharedResourceCache->resourceOwner();
    RefPtr bitmap = ShareableBitmap::createFromImagePixels(image);
    if (!bitmap)
        bitmap = ShareableBitmap::createFromImageDraw(image, ColorSpace { image.colorSpace() });
    if (!bitmap)
        return std::nullopt;
    auto handle = bitmap->createHandle();
    if (!handle)
        return std::nullopt;
    if (resourceOwner)
        handle->setOwnershipOfMemory(resourceOwner, MemoryLedger::Graphics);
    auto platformImage = bitmap->createPlatformImage();
    if (!platformImage) {
        ASSERT_NOT_REACHED();
        return std::nullopt;
    }
    image.replacePlatformImage(WTF::move(platformImage));
    return handle;
}

RefPtr<NativeImage> RemoteRenderingBackend::createNativeImage(ShareableBitmap& bitmap)
{
    return NativeImage::create(bitmap.createPlatformImage(DontCopyBackingStore, ShouldInterpolate::Yes));
}

IOSurfaceRef RemoteRenderingBackend::surfaceForCopy(ImageBuffer& imageBuffer, bool& isDisplayP3)
{
    isDisplayP3 = imageBuffer.colorSpace() == ColorSpace::DisplayP3();
    auto* surface = imageBuffer.surface();
    return surface ? surface->surface() : nullptr;
}

RefPtr<NativeImage> RemoteRenderingBackend::createTransientNativeImage(CGImageRef image)
{
    RefPtr nativeImage = NativeImage::create(RetainPtr { image });
    if (nativeImage)
        CGImageSetCachingFlags(nativeImage->platformImage().get(), kCGImageCachingTransient);
    return nativeImage;
}

Ref<SharedFont> RemoteRenderingBackend::createFont(const FontInternalAttributes& fontAttributes, const FontPlatformDataAttributes& platformData, FontCustomPlatformData* customPlatformData, uint64_t& renderingResourceIdentifier)
{
    FontPlatformData platform = FontPlatformData::create(platformData, customPlatformData);
    Ref font = SharedFont::create(platform, fontAttributes.origin, fontAttributes.isInterstitial, fontAttributes.visibility, fontAttributes.isTextOrientationFallback, fontAttributes.isSmallCapsFace, fontAttributes.renderingResourceIdentifier);
    renderingResourceIdentifier = font->renderingResourceIdentifier().toUInt64();
    return font;
}



#else

#define MESSAGE_CHECK(assertion, message) MESSAGE_CHECK_WITH_MESSAGE_BASE(assertion, m_streamConnection, message);
#define MESSAGE_CHECK_WITH_RETURN_VALUE(assertion, returnValue) MESSAGE_CHECK_WITH_RETURN_VALUE_BASE(assertion, m_streamConnection, returnValue)

RemoteRenderingBackend::~RemoteRenderingBackend()
{
}

void RemoteRenderingBackend::startListeningForIPC()
{
    dispatch([protectedThis = Ref { *this }] {
        protectedThis->workQueueInitialize();
    });
}

void RemoteRenderingBackend::stopListeningForIPC()
{
    m_workQueue->stopAndWaitForCompletion([protectedThis = Ref { *this }] {
        protectedThis->workQueueUninitialize();
    });
}

std::optional<SharedPreferencesForWebProcess> RemoteRenderingBackend::sharedPreferencesForWebProcess() const
{
    return m_sharedPreferencesForWebProcess;
}

void RemoteRenderingBackend::workQueueInitialize()
{
    assertIsCurrent(workQueue());
    m_streamConnection->open(*this, m_workQueue.get());
    m_streamConnection->startReceivingMessages(*this, Messages::RemoteRenderingBackend::messageReceiverName(), m_renderingBackendIdentifier.toUInt64());
}

void RemoteRenderingBackend::workQueueUninitialize()
{
    assertIsCurrent(workQueue());
    m_remoteImageBuffers.clear();
    m_remoteDisplayListRecorders.clear();
    m_remoteSnapshotRecorders.clear();
    m_remoteImageBufferSets.clear();
    // Make sure we destroy the ResourceCache on the WorkQueue since it gets populated on the WorkQueue.
    m_remoteResourceCache.releaseAllResources();

    Ref streamConnection = m_streamConnection;
    streamConnection->stopReceivingMessages(Messages::RemoteRenderingBackend::messageReceiverName(), m_renderingBackendIdentifier.toUInt64());
    streamConnection->invalidate();
}

void RemoteRenderingBackend::didReceiveInvalidMessage(IPC::StreamServerConnection&, IPC::MessageName messageName, const Vector<uint32_t>&)
{
    RELEASE_LOG_FAULT_WITH_PAYLOAD(IPC, "Received an invalid message %s from WebContent process %" PRIu64 ", requesting for it to be terminated.", description(messageName), m_gpuConnectionToWebProcess->webProcessIdentifier().toUInt64());
    callOnMainRunLoop([gpuConnectionToWebProcess = m_gpuConnectionToWebProcess, messageName] {
        gpuConnectionToWebProcess->terminateWebProcess(messageName);
    });
}

void RemoteRenderingBackend::dispatch(Function<void()>&& task)
{
    m_workQueue->dispatch(WTF::move(task));
}

void RemoteRenderingBackend::moveToSerializedBuffer(RenderingResourceIdentifier identifier, RemoteSerializedImageBufferIdentifier serializedIdentifier)
{
    assertIsCurrent(workQueue());
    // This transfers ownership of the RemoteImageBuffer contents to the transfer heap.
    RefPtr imageBuffer = takeImageBuffer(identifier);
    MESSAGE_CHECK(imageBuffer, "Missing ImageBuffer");
    MESSAGE_CHECK(imageBuffer->hasOneRef(), "ImageBuffer in use");
    // Avoid leaking cross-RemoteRenderingBackend state through context by releasing the context.
    imageBuffer->releaseGraphicsContext();
    bool success = m_sharedResourceCache->addSerializedImageBuffer(serializedIdentifier, imageBuffer.releaseNonNull());
    MESSAGE_CHECK(success, "Duplicate SerializedImageBuffer");
}

static void adjustImageBufferCreationContext(RemoteSharedResourceCache& sharedResourceCache, ImageBufferCreationContext& creationContext)
{
#if HAVE(IOSURFACE)
    creationContext.surfacePool = sharedResourceCache.ioSurfacePool();
#endif
    creationContext.resourceOwner = sharedResourceCache.resourceOwner();
}

void RemoteRenderingBackend::moveToImageBuffer(RemoteSerializedImageBufferIdentifier identifier, RenderingResourceIdentifier imageBufferIdentifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    assertIsCurrent(workQueue());
    RefPtr imageBuffer = m_sharedResourceCache->takeSerializedImageBuffer(identifier);
    MESSAGE_CHECK(imageBuffer, "Missing SerializedImageBuffer");

    ImageBufferCreationContext creationContext;
    adjustImageBufferCreationContext(m_sharedResourceCache, creationContext);
    imageBuffer->transferToNewContext(creationContext);
    bool success = addImageBuffer(imageBuffer.releaseNonNull(), imageBufferIdentifier, contextIdentifier);
    MESSAGE_CHECK(success, "Duplicate ImageBuffer");
}

void RemoteRenderingBackend::moveSerializedBufferToTransferHeap(RemoteSerializedImageBufferIdentifier serializedIdentifier, CompletionHandler<void(std::optional<WebCore::ImageBufferTransferIdentifier>)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    std::optional<WebCore::ImageBufferTransferIdentifier> result;
    [&] {
        RefPtr imageBuffer = m_sharedResourceCache->takeSerializedImageBuffer(serializedIdentifier);
        MESSAGE_CHECK(imageBuffer, "Missing SerializedImageBuffer");
        result = GPUProcess::singleton().depositTransferredImageBuffer(m_gpuConnectionToWebProcess->webProcessIdentifier(), imageBuffer.releaseNonNull());
    }();
    // The identifier exists only once the buffer has been deposited, so a claim made with it can
    // never arrive too early.
    completionHandler(result);
}

static bool transferHandleDescribes(const ImageBufferTransferHandle& handle, const ImageBuffer& imageBuffer)
{
    if (handle.parameters != imageBuffer.parameters())
        return false;
    if (handle.renderingMode == imageBuffer.renderingMode())
        return true;
    return handle.renderingMode == RenderingMode::Accelerated && imageBuffer.renderingMode() == RenderingMode::Unaccelerated;
}

void RemoteRenderingBackend::takeTransferredBuffer(const ImageBufferTransferHandle& handle, RenderingResourceIdentifier imageBufferIdentifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    assertIsCurrent(workQueue());
    RefPtr imageBuffer = GPUProcess::singleton().takeTransferredImageBuffer(handle.identifier);
    if (imageBuffer && !transferHandleDescribes(handle, *imageBuffer))
        imageBuffer = nullptr;
    if (!imageBuffer) {
        // Discarded along with the process that owned it, claimed already by a process that was
        // given the same identifier, or misdescribed by the sender.
        RELEASE_LOG(RemoteLayerBuffers, "[renderingBackend=%" PRIu64 "] RemoteRenderingBackend::takeTransferredBuffer - no buffer to take for image buffer %" PRIu64, m_renderingBackendIdentifier.toUInt64(), imageBufferIdentifier.toUInt64());
        imageBuffer = ImageBuffer::create<NullImageBufferBackend>({ 0, 0 }, 1, ColorSpace::SRGB(), { PixelFormat::BGRA8 }, RenderingPurpose::Unspecified, { });
        RELEASE_ASSERT(imageBuffer);
        streamConnection().send(Messages::RemoteImageBufferProxy::DidFailToCreateBackend(), imageBufferIdentifier);
        bool success = addImageBuffer(imageBuffer.releaseNonNull(), imageBufferIdentifier, contextIdentifier);
        MESSAGE_CHECK(success, "Duplicate ImageBuffer");
        return;
    }

    ImageBufferCreationContext creationContext;
    adjustImageBufferCreationContext(m_sharedResourceCache, creationContext);
#if HAVE(IOSURFACE)
    // The sender may have kept a send right to the surface, and could then alias it in a buffer of its own
    // with CreateMappableImageBuffer.
    creationContext.surfacePool = nullptr;
#endif
    imageBuffer->transferToNewContext(creationContext);
    bool success = addImageBuffer(imageBuffer.releaseNonNull(), imageBufferIdentifier, contextIdentifier);
    MESSAGE_CHECK(success, "Duplicate ImageBuffer");
}

void RemoteRenderingBackend::createSnapshot(RemoteSnapshotIdentifier snapshotIdentifier, FrameIdentifier rootFrameIdentifier, const FloatSize& size, CompletionHandler<void()>&& completionHandler)
{
    assertIsCurrent(workQueue());
    GPUProcess::singleton().createSnapshot(snapshotIdentifier, rootFrameIdentifier, size, m_gpuConnectionToWebProcess->webProcessIdentifier());
    completionHandler();
}

void RemoteRenderingBackend::createSnapshotRecorder(RemoteSnapshotRecorderIdentifier identifier, RemoteSnapshotIdentifier snapshotIdentifier)
{
    assertIsCurrent(workQueue());
    auto result = m_remoteSnapshotRecorders.add(identifier, RemoteSnapshotRecorder::create(identifier, snapshotIdentifier, *this));
    MESSAGE_CHECK(result.isNewEntry, "Recorder already created");
}

void RemoteRenderingBackend::sinkSnapshotRecorderIntoSnapshotFrame(RemoteSnapshotRecorderIdentifier identifier, FrameIdentifier frameIdentifier, CompletionHandler<void(bool)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    // FIXME: using global identifiers (frameIdentifier) is not secure. Do not follow this pattern.
    RefPtr recorder = m_remoteSnapshotRecorders.take(identifier).get();
    MESSAGE_CHECK(recorder, "Recorder sunk into snapshot before being cached");
    recorder->sinkIntoSnapshotFrame(frameIdentifier, workQueue());
    completionHandler(true);
}


template<typename ImageBufferType>
static RefPtr<ImageBuffer> allocateImageBufferInternal(const FloatSize& logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, const ColorSpace& colorSpace, ImageBufferFormat bufferFormat, ImageBufferCreationContext& creationContext)
{
    RefPtr<ImageBuffer> imageBuffer;

    switch (renderingMode) {
    case RenderingMode::Accelerated:
#if HAVE(IOSURFACE)
        if (isSmallLayerBacking({ logicalSize, resolutionScale, colorSpace, bufferFormat, purpose }))
            imageBuffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBitmapBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
        if (!imageBuffer)
            imageBuffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
#endif
        [[fallthrough]];

    case RenderingMode::Unaccelerated:
        if (!imageBuffer)
            imageBuffer = ImageBuffer::create<ImageBufferShareableBitmapBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
        break;

    case RenderingMode::PDFDocument:
    case RenderingMode::DisplayList:
        // FIXME: PDFDocument and DisplayList are only meaningful for a GraphicsContext. Add a type-specific rendering mode, such as ImageBufferRenderingMode, so that they cannot be passed here.
        RELEASE_ASSERT_NOT_REACHED();
    }

    return imageBuffer;
}

NODELETE static void adjustImageBufferRenderingMode(const RemoteSharedResourceCache& sharedResourceCache, const SharedPreferencesForWebProcess& preferences, RenderingPurpose purpose, RenderingMode& renderingMode)
{
    if (renderingMode == RenderingMode::Accelerated && sharedResourceCache.reachedAcceleratedImageBufferLimit(purpose, preferences.acceleratedImageBufferLimit))
        renderingMode = RenderingMode::Unaccelerated;
}

RefPtr<ImageBuffer> RemoteRenderingBackend::allocateImageBuffer(const FloatSize& logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, const ColorSpace& colorSpace, ImageBufferFormat bufferFormat, ImageBufferCreationContext creationContext, std::optional<ImageBufferBackendHandle>&& providedBackingStore)
{
    assertIsCurrent(workQueue());
    // PDF documents and display lists are drawn through contexts that are not ImageBuffers. This also covers
    // the configurations of image buffer sets.
    MESSAGE_CHECK_WITH_RETURN_VALUE(renderingMode != RenderingMode::PDFDocument && renderingMode != RenderingMode::DisplayList, nullptr);
    if (purpose == RenderingPurpose::Canvas && m_sharedResourceCache->reachedImageBufferForCanvasLimit())
        return nullptr;

    adjustImageBufferCreationContext(m_sharedResourceCache, creationContext);
#if HAVE(IOSURFACE) && USE(APPLE_INTERNAL_SDK)
    creationContext.useIOSurfaceWebKitBehavior = m_sharedPreferencesForWebProcess.useIOSurfaceWebKitBehavior;
#endif

    // Backing store the web process allocated is adopted as-is. Its geometry is
    // attacker-controlled, so the backends validate it against what was requested and
    // fail the allocation rather than drawing into a surface of the wrong shape. The
    // rendering mode is not adjusted here: we have to use the backing store we were
    // given, or none at all.
    if (providedBackingStore) {
        ImageBuffer::Parameters parameters { logicalSize, resolutionScale, colorSpace, bufferFormat, purpose };
        switch (renderingMode) {
        case RenderingMode::Unaccelerated:
            if (!std::holds_alternative<ShareableBitmap::Handle>(*providedBackingStore))
                return nullptr;
            if (auto backend = ImageBufferShareableBitmapBackend::create(parameters, std::get<ShareableBitmap::Handle>(WTF::move(*providedBackingStore))))
                return ImageBuffer::create(parameters, creationContext, WTF::move(backend));
            return nullptr;
        case RenderingMode::Accelerated:
            // This has no backing store the web process can hand over.
            return nullptr;
        case RenderingMode::PDFDocument:
        case RenderingMode::DisplayList:
            // FIXME: PDFDocument and DisplayList are only meaningful for a GraphicsContext. Add a type-specific rendering mode, such as ImageBufferRenderingMode, so that they cannot be passed here.
            RELEASE_ASSERT_NOT_REACHED();
        }
        return nullptr;
    }

    adjustImageBufferRenderingMode(m_sharedResourceCache, m_sharedPreferencesForWebProcess, purpose, renderingMode);

    RefPtr<ImageBuffer> imageBuffer;

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    if (m_sharedPreferencesForWebProcess.useCGDisplayListsForDOMRendering && creationContext.dynamicContentScalingResourceCache)
        imageBuffer = allocateImageBufferInternal<DynamicContentScalingBifurcatedImageBuffer>(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, creationContext);
#endif

    if (!imageBuffer)
        imageBuffer = allocateImageBufferInternal<ImageBuffer>(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, creationContext);

    return imageBuffer;
}


void RemoteRenderingBackend::createImageBuffer(const FloatSize& logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, const ColorSpace& colorSpace, ImageBufferFormat pixelFormat, RenderingResourceIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    createImageBufferWithBackingStore(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, pixelFormat, std::nullopt, identifier, contextIdentifier);
}

void RemoteRenderingBackend::createMappableImageBuffer(const FloatSize& logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, const ColorSpace& colorSpace, ImageBufferFormat pixelFormat, ImageBufferBackendHandle&& backingStore, RenderingResourceIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    createImageBufferWithBackingStore(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, pixelFormat, WTF::move(backingStore), identifier, contextIdentifier);
}

void RemoteRenderingBackend::createImageBufferWithBackingStore(const FloatSize& logicalSize, RenderingMode renderingMode, RenderingPurpose purpose, float resolutionScale, const ColorSpace& colorSpace, ImageBufferFormat pixelFormat, std::optional<ImageBufferBackendHandle>&& backingStore, RenderingResourceIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    assertIsCurrent(workQueue());

    RefPtr<ImageBuffer> imageBuffer = allocateImageBuffer(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, pixelFormat, { }, WTF::move(backingStore));
    if (!imageBuffer) {
        RELEASE_LOG(RemoteLayerBuffers, "[renderingBackend=%" PRIu64 "] RemoteRenderingBackend::createImageBuffer - failed to allocate image buffer %" PRIu64, m_renderingBackendIdentifier.toUInt64(), identifier.toUInt64());
        // On failure to create a remote image buffer we still create a null display list recorder.
        // Commands to draw to the failed image might have already be issued and we must process
        // them.
        imageBuffer = ImageBuffer::create<NullImageBufferBackend>({ 0, 0 }, 1, ColorSpace::SRGB(), { PixelFormat::BGRA8 }, RenderingPurpose::Unspecified, { });
        RELEASE_ASSERT(imageBuffer);
        streamConnection().send(Messages::RemoteImageBufferProxy::DidFailToCreateBackend(), identifier);
    }
    bool success = addImageBuffer(imageBuffer.releaseNonNull(), identifier, contextIdentifier);
    MESSAGE_CHECK(success, "Duplicate ImageBuffers");
}

void RemoteRenderingBackend::releaseImageBuffer(RenderingResourceIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteImageBuffers.take(identifier).get();
    MESSAGE_CHECK(success, "Missing ImageBuffer");
}

bool RemoteRenderingBackend::addImageBuffer(Ref<ImageBuffer>&& imageBuffer, RenderingResourceIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    assertIsCurrent(workQueue());
    return m_remoteImageBuffers.add(identifier, RemoteImageBuffer::create(WTF::move(imageBuffer), identifier, contextIdentifier, *this)).isNewEntry;
}

RefPtr<ImageBuffer> RemoteRenderingBackend::takeImageBuffer(RenderingResourceIdentifier identifier)
{
    assertIsCurrent(workQueue());
    RefPtr remoteImageBuffer = m_remoteImageBuffers.take(identifier).get(); // NOLINT
    if (!remoteImageBuffer)
        return nullptr;
    return RemoteImageBuffer::sinkIntoImageBuffer(remoteImageBuffer.releaseNonNull());
}

void RemoteRenderingBackend::sinkImageBufferIntoNativeImage(RenderingResourceIdentifier identifier, RenderingResourceIdentifier imageIdentifier)
{
    assertIsCurrent(workQueue());
    // Like releaseImageBuffer(), the buffer is gone after this. The web process does not release it again.
    RefPtr imageBuffer = takeImageBuffer(identifier);
    MESSAGE_CHECK(imageBuffer, "Missing ImageBuffer");
    MESSAGE_CHECK(imageBuffer->hasOneRef(), "ImageBuffer in use");
    RefPtr image = ImageBuffer::sinkIntoNativeImage(WTF::move(imageBuffer));
    // The buffer may have failed to allocate.
    if (!image)
        image = createPlaceholderNativeImage();
    MESSAGE_CHECK(image, "NativeImage could not be created");
    bool success = m_remoteResourceCache.cacheNativeImage(imageIdentifier, image.releaseNonNull());
    MESSAGE_CHECK(success, "NativeImage already exists");
}


RefPtr<NativeImage> RemoteRenderingBackend::createPlaceholderNativeImage()
{
    return ImageBuffer::sinkIntoNativeImage(ImageBuffer::create({ 1, 1 }, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, ColorSpace::SRGB(), PixelFormat::BGRA8));
}

void RemoteRenderingBackend::createImageBufferSet(ImageBufferSetIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier)
{
    assertIsCurrent(workQueue());
    auto result = m_remoteImageBufferSets.add(identifier, RemoteImageBufferSet::create(identifier, contextIdentifier, *this));
    MESSAGE_CHECK(result.isNewEntry, "Duplicate ImageBufferSet");
}

void RemoteRenderingBackend::releaseImageBufferSet(ImageBufferSetIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteImageBufferSets.take(identifier).get();
    MESSAGE_CHECK(success, "Missing ImageBufferSet");
}

void RemoteRenderingBackend::destroyGetPixelBufferSharedMemory()
{
    m_getPixelBufferSharedMemory = nullptr;
}

void RemoteRenderingBackend::nativeImageBitmap(RenderingResourceIdentifier imageIdentifier, CompletionHandler<void(std::optional<ShareableBitmap::Handle>)>&& completionHandler)
{
    std::optional<ShareableBitmap::Handle> result;
    [&] {
        RefPtr image = m_remoteResourceCache.cachedNativeImage(imageIdentifier);
        MESSAGE_CHECK(image, "NativeImage not cached.");
        RefPtr<ShareableBitmap> bitmap;
#if USE(CG)
        bitmap = ShareableBitmap::createFromImagePixels(*image);
#endif
        if (!bitmap)
            bitmap = ShareableBitmap::createFromImageDraw(*image, ColorSpace { image->colorSpace() });
        if (!bitmap)
            return;
        auto handle = bitmap->createHandle();
        if (!handle)
            return;
        if (sharedResourceCache().resourceOwner())
            handle->setOwnershipOfMemory(sharedResourceCache().resourceOwner(), WebCore::MemoryLedger::Graphics);
        auto platformImage = bitmap->createPlatformImage();
        if (!platformImage) {
            ASSERT_NOT_REACHED();
            return;
        }
        image->replacePlatformImage(WTF::move(platformImage));
        result = WTF::move(handle);
    }();
    ASSERT(result);
    completionHandler(WTF::move(result));
}

void RemoteRenderingBackend::cacheNativeImage(ShareableBitmap::Handle&& handle, RenderingResourceIdentifier imageIdentifier)
{
    assertIsCurrent(workQueue());

    auto bitmap = ShareableBitmap::create(WTF::move(handle));
    if (!bitmap)
        return;

    auto image = NativeImage::create(bitmap->createPlatformImage(DontCopyBackingStore, ShouldInterpolate::Yes));
    if (!image)
        return;

    bool success = m_remoteResourceCache.cacheNativeImage(imageIdentifier, image.releaseNonNull());
    MESSAGE_CHECK(success, "NativeImage already cached.");
}

void RemoteRenderingBackend::cacheNativeImageFromSharedNativeImage(RemoteNativeImageReadReference&& reference)
{
    assertIsCurrent(workQueue());
    auto identifier = reference.identifier();
    // Another stream connection publishes the image, possibly on this work queue. Wait without blocking the queue.
    auto image = m_sharedResourceCache->readNativeImage(m_streamConnection, WTF::move(reference));
    if (!image) {
        m_streamConnection->markCurrentlyDispatchedMessageAsDeferred();
        return;
    }
    MESSAGE_CHECK(*image, "Shared NativeImage not found.");
    bool success = m_remoteResourceCache.cacheNativeImage(identifier, image->releaseNonNull());
    MESSAGE_CHECK(success, "NativeImage already cached.");
}

void RemoteRenderingBackend::releaseNativeImage(RenderingResourceIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseNativeImage(identifier);
    MESSAGE_CHECK(success, "NativeImage released before being cached.");
}

void RemoteRenderingBackend::cacheFont(const Font::Attributes& fontAttributes, FontPlatformDataAttributes platformData, std::optional<RenderingResourceIdentifier> fontCustomPlatformDataIdentifier)
{
    assertIsCurrent(workQueue());

    RefPtr<FontCustomPlatformData> customPlatformData = nullptr;
    if (fontCustomPlatformDataIdentifier) {
        customPlatformData = m_remoteResourceCache.cachedFontCustomPlatformData(*fontCustomPlatformDataIdentifier);
        MESSAGE_CHECK(customPlatformData, "CacheFont without caching custom data");
    }

    FontPlatformData platform = FontPlatformData::create(platformData, customPlatformData.get());

    Ref font = SharedFont::create(platform, fontAttributes.origin, fontAttributes.isInterstitial, fontAttributes.visibility, fontAttributes.isTextOrientationFallback, fontAttributes.isSmallCapsFace, fontAttributes.renderingResourceIdentifier);

    bool success = m_remoteResourceCache.cacheFont(WTF::move(font));
    MESSAGE_CHECK(success, "Font already cached.");
}

void RemoteRenderingBackend::releaseFont(WebCore::RenderingResourceIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseFont(identifier);
    MESSAGE_CHECK(success, "Font released before being cached.");
}

void RemoteRenderingBackend::cacheFontCustomPlatformData(WebCore::FontCustomPlatformSerializedData&& fontCustomPlatformSerializedData)
{
    assertIsCurrent(workQueue());

    auto customPlatformData = FontCustomPlatformData::tryMakeFromSerializationData(WTF::move(fontCustomPlatformSerializedData), shouldUseLockdownFontParser());
    MESSAGE_CHECK(customPlatformData.has_value(), "cacheFontCustomPlatformData couldn't deserialize FontCustomPlatformData");

    bool success = m_remoteResourceCache.cacheFontCustomPlatformData(WTF::move(customPlatformData.value()));
    MESSAGE_CHECK(success, "FontCustomPlatformData already cached.");
}

void RemoteRenderingBackend::releaseFontCustomPlatformData(WebCore::RenderingResourceIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseFontCustomPlatformData(identifier);
    MESSAGE_CHECK(success, "FontCustomPlatformData released before being cached.");
}

void RemoteRenderingBackend::cachePathImpl(Ref<WebCore::PathImpl>&& path, RemotePathImplIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.cachePathImpl(identifier, WTF::move(path));
    MESSAGE_CHECK(success, "Path already cached.");
}

void RemoteRenderingBackend::releasePathImpl(RemotePathImplIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releasePathImpl(identifier);
    MESSAGE_CHECK(success, "Path released before being cached.");
}

void RemoteRenderingBackend::cacheGradient(Ref<const Gradient>&& gradient, RemoteGradientIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.cacheGradient(identifier, WTF::move(gradient));
    MESSAGE_CHECK(success, "Gradient already cached.");
}

void RemoteRenderingBackend::releaseGradient(RemoteGradientIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseGradient(identifier);
    MESSAGE_CHECK(success, "Gradient released before being cached.");
}

void RemoteRenderingBackend::cacheMeshGradient(Ref<MeshGradient>&& gradient, RemoteMeshGradientIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.cacheMeshGradient(identifier, WTF::move(gradient));
    MESSAGE_CHECK(success, "Mesh gradient already cached.");
}

void RemoteRenderingBackend::releaseMeshGradient(RemoteMeshGradientIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseMeshGradient(identifier);
    MESSAGE_CHECK(success, "Mesh gradient released before being cached.");
}


void RemoteRenderingBackend::cacheFilter(Ref<Filter>&& filter)
{
    assertIsCurrent(workQueue());
    MESSAGE_CHECK(filter->hasValidRenderingResourceIdentifier(), "Received a Filter without a valid resource identifier.");
    bool success = m_remoteResourceCache.cacheFilter(WTF::move(filter));
    MESSAGE_CHECK(success, "Filter already cached.");
}

void RemoteRenderingBackend::releaseFilter(RenderingResourceIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseFilter(identifier);
    MESSAGE_CHECK(success, "Filter released before being cached.");
}

void RemoteRenderingBackend::createDisplayListRecorder(RemoteDisplayListRecorderIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteDisplayListRecorders.add(identifier, RemoteDisplayListRecorder::create(identifier, *this)).isNewEntry;
    MESSAGE_CHECK(success, "Recorder already created");
}

void RemoteRenderingBackend::sinkDisplayListRecorderIntoDisplayList(RemoteDisplayListRecorderIdentifier identifier, RemoteDisplayListIdentifier displayListIdentifier)
{
    assertIsCurrent(workQueue());
    RefPtr recorder = m_remoteDisplayListRecorders.take(identifier).get();
    MESSAGE_CHECK(recorder, "Recorder sunk into display list before being cached");
    Ref displayList = recorder->takeDisplayList();
    bool success = m_remoteResourceCache.cacheDisplayList(displayListIdentifier, WTF::move(displayList));
    MESSAGE_CHECK(success, "Display list already created");
}

void RemoteRenderingBackend::releaseDisplayList(RemoteDisplayListIdentifier identifier)
{
    assertIsCurrent(workQueue());
    bool success = m_remoteResourceCache.releaseDisplayList(identifier);
    MESSAGE_CHECK(success, "Display list released before being cached");
}

void RemoteRenderingBackend::releaseMemory()
{
    assertIsCurrent(workQueue());
    m_remoteResourceCache.releaseMemory();
}

#if USE(GRAPHICS_LAYER_WC)
void RemoteRenderingBackend::flush(IPC::Semaphore&& semaphore)
{
    semaphore.signal();
}
#endif

#if PLATFORM(COCOA)
void RemoteRenderingBackend::prepareImageBufferSetsForDisplay(Vector<ImageBufferSetPrepareBufferForDisplayInputData> swapBuffersInput)
{
    assertIsCurrent(workQueue());

    for (unsigned i = 0; i < swapBuffersInput.size(); ++i) {
        RefPtr<RemoteImageBufferSet> remoteImageBufferSet = m_remoteImageBufferSets.get(swapBuffersInput[i].remoteBufferSet);
        MESSAGE_CHECK(remoteImageBufferSet, "BufferSet is being updated before being created");
        auto displayRequirement = remoteImageBufferSet->ensureBufferForDisplay(borrow(swapBuffersInput)[i], false);

        if (displayRequirement != SwapBuffersDisplayRequirement::NeedsNoDisplay)
            remoteImageBufferSet->prepareBufferForDisplay(swapBuffersInput[i].dirtyRegion, swapBuffersInput[i].requiresClearedPixels);
    }
}

void RemoteRenderingBackend::prepareImageBufferSetsForDisplaySync(Vector<ImageBufferSetPrepareBufferForDisplayInputData> swapBuffersInput, CompletionHandler<void(Vector<SwapBuffersDisplayRequirement>&&)>&& completionHandler)
{
    assertIsCurrent(workQueue());

    Vector<SwapBuffersDisplayRequirement> outputData;
    outputData.resizeToFit(swapBuffersInput.size());

    for (unsigned i = 0; i < swapBuffersInput.size(); ++i) {
        RefPtr<RemoteImageBufferSet> remoteImageBufferSet = m_remoteImageBufferSets.get(swapBuffersInput[i].remoteBufferSet);
        MESSAGE_CHECK(remoteImageBufferSet, "BufferSet is being updated before being created");
        borrow(outputData)[i] = remoteImageBufferSet->ensureBufferForDisplay(borrow(swapBuffersInput)[i], true);
    }

    completionHandler(WTF::move(outputData));

    // Defer preparing all the front buffers (which triggers pixel copy
    // operations) until after we've sent the completion handler (and any
    // buffer backend created messages) to unblock the WebProcess as soon
    // as possible.
    for (unsigned i = 0; i < swapBuffersInput.size(); ++i) {
        RefPtr<RemoteImageBufferSet> remoteImageBufferSet = m_remoteImageBufferSets.get(swapBuffersInput[i].remoteBufferSet);
        MESSAGE_CHECK(remoteImageBufferSet, "BufferSet is being updated before being created");

        if (outputData[i] != SwapBuffersDisplayRequirement::NeedsNoDisplay)
            remoteImageBufferSet->prepareBufferForDisplay(swapBuffersInput[i].dirtyRegion, swapBuffersInput[i].requiresClearedPixels);
    }
}
#endif

void RemoteRenderingBackend::markSurfacesVolatile(MarkSurfacesAsVolatileRequestIdentifier requestIdentifier, const Vector<std::pair<ImageBufferSetIdentifier, OptionSet<BufferInSetType>>>& identifiers, bool forcePurge)
{
    assertIsCurrent(workQueue());
    LOG_WITH_STREAM(RemoteLayerBuffers, stream << "GPU Process: RemoteRenderingBackend::markSurfacesVolatile " << identifiers);

    Vector<std::pair<ImageBufferSetIdentifier, OptionSet<BufferInSetType>>> markedBufferSets;
    bool allSucceeded = true;

    for (auto identifier : identifiers) {
        RefPtr<RemoteImageBufferSet> remoteImageBufferSet = m_remoteImageBufferSets.get(identifier.first);

        MESSAGE_CHECK(remoteImageBufferSet, "BufferSet is being marked volatile before being created");
        MESSAGE_CHECK(!remoteImageBufferSet->isPreparingForDisplay(), "BufferSet is being marked volatile while preparing for display");

        OptionSet<BufferInSetType> volatileBuffers;
        if (!remoteImageBufferSet->makeBuffersVolatile(identifier.second, volatileBuffers, forcePurge))
            allSucceeded = false;

        if (!volatileBuffers.isEmpty())
            markedBufferSets.append(std::make_pair(identifier.first, volatileBuffers));
    }

    LOG_WITH_STREAM(RemoteLayerBuffers, stream << "GPU Process: markSurfacesVolatile - surfaces marked volatile " << markedBufferSets);
    send(Messages::RemoteRenderingBackendProxy::DidMarkLayersAsVolatile(requestIdentifier, WTF::move(markedBufferSets), allSucceeded));
}

void RemoteRenderingBackend::finalizeRenderingUpdate(RenderingUpdateID renderingUpdateID)
{
    send(Messages::RemoteRenderingBackendProxy::DidFinalizeRenderingUpdate(renderingUpdateID));
}

RefPtr<ImageBuffer> RemoteRenderingBackend::imageBuffer(RenderingResourceIdentifier renderingResourceIdentifier)
{
    assertIsCurrent(workQueue());
    RefPtr<RemoteImageBuffer> remoteImageBuffer = m_remoteImageBuffers.get(renderingResourceIdentifier);
    if (!remoteImageBuffer.get())
        return nullptr;
    return remoteImageBuffer->imageBuffer();
}

#if PLATFORM(COCOA)
bool RemoteRenderingBackend::shouldUseLockdownFontParser() const
{
#if HAVE(CTFONTMANAGER_CREATEMEMORYSAFEFONTDESCRIPTORFROMDATA)
    return (m_sharedPreferencesForWebProcess.lockdownFontParserEnabled && m_gpuConnectionToWebProcess->isLockdownModeEnabled()) || m_sharedPreferencesForWebProcess.forceLockdownFontParserEnabled;
#else
    return false;
#endif
}
#elif USE(CAIRO) || USE(SKIA)
bool RemoteRenderingBackend::shouldUseLockdownFontParser() const
{
    return false;
}
#endif

void RemoteRenderingBackend::getImageBufferResourceLimitsForTesting(CompletionHandler<void(WebCore::ImageBufferResourceLimits)>&& callback)
{
    callback(m_sharedResourceCache->getResourceLimitsForTesting(m_sharedPreferencesForWebProcess.acceleratedImageBufferLimit));
}

#if USE(CG) && !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
CGImageRef copyCachedNativeImage(RemoteRenderingBackend& backend, uint64_t renderingResourceIdentifier, bool& found)
{
    RefPtr image = backend.remoteResourceCache().cachedNativeImage(RenderingResourceIdentifier { renderingResourceIdentifier });
    found = !!image;
    if (!image)
        return nullptr;
    return image->platformImage().leakRef();
}
#endif

#undef MESSAGE_CHECK
#undef MESSAGE_CHECK_WITH_RETURN_VALUE

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
