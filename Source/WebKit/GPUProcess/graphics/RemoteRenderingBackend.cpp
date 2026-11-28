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

#include "GPUProcess.h"
#include "ImageBufferShareableBitmapBackend.h"
#include "SharedFont.h"
#include <WebCore/Filter.h>
#include <WebCore/Gradient.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NullImageBufferBackend.h>

#if HAVE(IOSURFACE)
#include "ImageBufferShareableMappedIOSurfaceBackend.h"
#include "ImageBufferShareableMappedIOSurfaceBitmapBackend.h"
#endif

#if USE(CG)
#include <pal/spi/cg/CoreGraphicsSPI.h>
#endif

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#import "DynamicContentScalingBifurcatedImageBuffer.h"
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
    : m_streamConnection(WTF::move(streamConnection))
    , m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_sharedResourceCache(gpuConnectionToWebProcess.sharedResourceCache())
    , m_sharedPreferencesForWebProcess(gpuConnectionToWebProcess.sharedPreferencesForWebProcessValue())
    , m_renderingBackendIdentifier(identifier)
    , m_owner(IPC::SwiftReceiverOwner::create(m_streamConnection.copyRef(), "RemoteRenderingBackend work queue"_s, IPC::ReceiverName::RemoteRenderingBackend, identifier.toUInt64(), m_sharedPreferencesForWebProcess, gpuConnectionToWebProcess.terminateWebProcessOnInvalidMessage()))
{
    ASSERT(RunLoop::isMain());
    weakPtrFactory().prepareForUseOnlyOnNonMainThread();
}

// What Swift can't do of the backend's work: take the arguments it has no form of, and send messages.

RemoteRenderingBackend::~RemoteRenderingBackend()
{
    if (auto swiftState = std::exchange(m_swiftState, 0))
        destroySwiftState(swiftState);
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
#if HAVE(IOSURFACE)
    if (renderingMode == RenderingMode::Accelerated) {
        if (isSmallLayerBacking({ logicalSize, resolutionScale, colorSpace, bufferFormat, purpose }))
            imageBuffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBitmapBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
        if (!imageBuffer)
            imageBuffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBackend, ImageBufferType>(logicalSize, resolutionScale, colorSpace, bufferFormat, purpose, creationContext);
    }
#else
    UNUSED_PARAM(renderingMode);
#endif
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
    RefPtr<ShareableBitmap> bitmap;
#if USE(CG)
    bitmap = ShareableBitmap::createFromImagePixels(image);
#endif
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

#if HAVE(IOSURFACE)
IOSurfaceRef RemoteRenderingBackend::surfaceForCopy(ImageBuffer& imageBuffer, bool& isDisplayP3)
{
    isDisplayP3 = imageBuffer.colorSpace() == ColorSpace::DisplayP3();
    auto* surface = imageBuffer.surface();
    return surface ? surface->surface() : nullptr;
}
#endif

#if USE(CG)
RefPtr<NativeImage> RemoteRenderingBackend::createTransientNativeImage(CGImageRef image)
{
    RefPtr nativeImage = NativeImage::create(RetainPtr { image });
    if (nativeImage)
        CGImageSetCachingFlags(nativeImage->platformImage().get(), kCGImageCachingTransient);
    return nativeImage;
}
#endif

Ref<SharedFont> RemoteRenderingBackend::createFont(const FontInternalAttributes& fontAttributes, const FontPlatformDataAttributes& platformData, FontCustomPlatformData* customPlatformData, uint64_t& renderingResourceIdentifier)
{
    FontPlatformData platform = FontPlatformData::create(platformData, customPlatformData);
    Ref font = SharedFont::create(platform, fontAttributes.origin, fontAttributes.isInterstitial, fontAttributes.visibility, fontAttributes.isTextOrientationFallback, fontAttributes.isSmallCapsFace, fontAttributes.renderingResourceIdentifier);
    renderingResourceIdentifier = font->renderingResourceIdentifier().toUInt64();
    return font;
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
