/*
 * Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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
#include "RemoteGraphicsContextGLResources.h"

#if ENABLE(GPU_PROCESS) && ENABLE(WEBGL) && !PLATFORM(COCOA)

#include "GPUConnectionToWebProcess.h"
#include "Logging.h"
#include "RemoteGraphicsContextGLInitializationState.h"
#include "RemoteGraphicsContextGLResourcesMessages.h"
#include "RemoteGraphicsContextGLProxyMessages.h"
#include "RemoteSharedResourceCache.h"
#include "StreamConnectionWorkQueue.h"
#include <WebCore/GraphicsContext.h>
#include <WebCore/NativeImage.h>
#include <WebCore/NotImplemented.h>
#include <WebCore/TypedArrayPixelBuffer.h>
#include <wtf/MainThread.h>

#if ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeap.h"
#endif

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, streamConnection());

namespace WebKit {

using namespace WebCore;

namespace {
std::optional<uint64_t> estimatedMemoryCostForIPC(GraphicsContextGL& context)
{
    if (auto memoryCost = context.estimatedMemoryCost())
        return static_cast<uint64_t>(*memoryCost);
    return std::nullopt;
}
}

#if !USE(GRAPHICS_LAYER_WC) && !USE(GBM)
Ref<RemoteGraphicsContextGLResources> RemoteGraphicsContextGLResources::create(GPUConnectionToWebProcess& gpuConnectionToWebProcess, GraphicsContextGLAttributes&& attributes, RemoteGraphicsContextGLIdentifier graphicsContextGLIdentifier, RemoteRenderingBackend& renderingBackend, IPC::SwiftReceiverOwner& owner)
{
    ASSERT_NOT_REACHED();
    auto instance = adoptRef(*new RemoteGraphicsContextGLResources(gpuConnectionToWebProcess, graphicsContextGLIdentifier, renderingBackend, owner));
    instance->initialize(WTF::move(attributes));
    return instance;
}
#endif

RemoteGraphicsContextGLResources::RemoteGraphicsContextGLResources(GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteGraphicsContextGLIdentifier identifier, RemoteRenderingBackend& renderingBackend, IPC::SwiftReceiverOwner& owner)
    : m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_owner(owner)
    , m_identifier(identifier)
    , m_renderingBackend(renderingBackend)
    , m_sharedResourceCache(gpuConnectionToWebProcess.sharedResourceCache())
#if ENABLE(VIDEO)
    , m_videoFrameObjectHeap(gpuConnectionToWebProcess.videoFrameObjectHeap())
#endif
    , m_renderingResourcesRequest(ScopedWebGLRenderingResourcesRequest::acquire())
    , m_webProcessIdentity(gpuConnectionToWebProcess.webProcessIdentity())
{
    assertIsMainRunLoop();
}

// <https://gcc.gnu.org/bugzilla/show_bug.cgi?id=121717>
IGNORE_GCC_WARNINGS_BEGIN("free-nonheap-object")
RemoteGraphicsContextGLResources::~RemoteGraphicsContextGLResources()
{
    ASSERT(!m_context);
    if (m_swiftState)
        destroySwiftState(std::exchange(m_swiftState, 0));
}
IGNORE_GCC_WARNINGS_END

void RemoteGraphicsContextGLResources::initialize(GraphicsContextGLAttributes&& attributes)
{
    assertIsMainRunLoop();
    Ref workQueue = this->workQueue();
    workQueue->dispatch([attributes = WTF::move(attributes), protectedThis = protect(*this)]() mutable {
        protectedThis->workQueueInitialize(WTF::move(attributes));
    });
}

void RemoteGraphicsContextGLResources::workQueueInitialize(WebCore::GraphicsContextGLAttributes&& attributes)
{
    assertIsCurrent(workQueue());
    RefPtr streamConnection = this->streamConnection();
    if (!streamConnection)
        return;
    platformWorkQueueInitialize(WTF::move(attributes));
    if (RefPtr context = m_context) {
        context->setClient(this);
        auto contextAttributes = context->contextAttributes();
        auto knownActiveExtensions = context->knownActiveExtensions();
        auto requestableExtensions = context->requestableExtensions();
        m_estimatedMemoryCost = estimatedMemoryCostForIPC(*context);
        RemoteGraphicsContextGLInitializationState initializationState {
            .attributes = contextAttributes,
            .knownActiveExtensions = knownActiveExtensions.toRaw(),
            .requestableExtensions = requestableExtensions.toRaw(),
            .estimatedMemoryCost = m_estimatedMemoryCost,
            .maxCombinedTextureImageUnits = context->maxCombinedTextureImageUnits(),
            .maxVertexAttribs = context->maxVertexAttribs(),
            .maxTextureSize = context->maxTextureSize(),
            .maxCubeMapTextureSize = context->maxCubeMapTextureSize(),
            .maxRenderbufferSize = context->maxRenderbufferSize(),
            .maxViewportDims = context->maxViewportDims(),
            .maxDrawingBufferSize = context->maxDrawingBufferSize(),
        };
        // MAX_SAMPLES is core in ES3 and otherwise comes from GL_ANGLE_framebuffer_multisample.
        // Querying it without either would just add INVALID_ENUM to the error queue.
        if (contextAttributes.isWebGL2 || knownActiveExtensions.contains(GCGLExtension::ANGLE_framebuffer_multisample))
            initializationState.maxSamples = context->maxSamples();
        if (contextAttributes.isWebGL2) {
            initializationState.maxTransformFeedbackSeparateAttribs = context->maxTransformFeedbackSeparateAttribs();
            initializationState.maxUniformBufferBindings = context->maxUniformBufferBindings();
            initializationState.uniformBufferOffsetAlignment = context->uniformBufferOffsetAlignment();
            initializationState.max3DTextureSize = context->max3DTextureSize();
            initializationState.maxArrayTextureLayers = context->maxArrayTextureLayers();
        }
        send(Messages::RemoteGraphicsContextGLProxy::WasCreated({ initializationState }));
        // The owner and its stream connection keep this until the stream connection stops.
        m_owner->setCompanion(*this);
        streamConnection->startReceivingMessages(*this, Messages::RemoteGraphicsContextGLResources::messageReceiverName(), m_identifier.toUInt64());
        m_swiftState = createSwiftState(context->islandShell());
    } else
        send(Messages::RemoteGraphicsContextGLProxy::WasCreated(std::nullopt));
}

void RemoteGraphicsContextGLResources::didStopReceiving()
{
    RELEASE_ASSERT(workQueue().isCurrent());
    assertIsCurrent(workQueue());
    if (RefPtr context = std::exchange(m_context, nullptr))
        context->setClient(nullptr);
    if (m_swiftState)
        destroySwiftState(std::exchange(m_swiftState, 0));
    m_renderingResourcesRequest = { };
}

void RemoteGraphicsContextGLResources::forceContextLost()
{
    assertIsCurrent(workQueue());
    send(Messages::RemoteGraphicsContextGLProxy::WasLost());
}

void RemoteGraphicsContextGLResources::addDebugMessage(GCGLenum type, GCGLenum id, GCGLenum severity, std::span<const char8_t> message)
{
    assertIsCurrent(workQueue());
    send(Messages::RemoteGraphicsContextGLProxy::addDebugMessage(type, id, severity, message));
}

void RemoteGraphicsContextGLResources::didChangeMemoryCost()
{
    assertIsCurrent(workQueue());
    if (m_memoryCostUpdateScheduled)
        return;

    m_memoryCostUpdateScheduled = true;
    protect(workQueue())->dispatch([protectedThis = protect(*this)] {
        assertIsCurrent(protectedThis->workQueue());

        protectedThis->m_memoryCostUpdateScheduled = false;
        protectedThis->updateMemoryCost();
    });
}

void RemoteGraphicsContextGLResources::updateMemoryCost()
{
    assertIsCurrent(workQueue());
    RefPtr context = m_context;
    if (!context)
        return;

    auto memoryCost = estimatedMemoryCostForIPC(*context);
    if (memoryCost == m_estimatedMemoryCost)
        return;

    m_estimatedMemoryCost = memoryCost;
    send(Messages::RemoteGraphicsContextGLProxy::MemoryCostChanged(memoryCost));
}

void RemoteGraphicsContextGLResources::reshape(int32_t width, int32_t height)
{
    assertIsCurrent(workQueue());
    if (width && height)
        protect(m_context)->reshape(width, height);
    else
        forceContextLost();
}

#if !USE(GRAPHICS_LAYER_WC) && !USE(GBM)
void RemoteGraphicsContextGLResources::prepareForDisplay(CompletionHandler<void()>&& completionHandler)
{
    assertIsCurrent(workQueue());
    notImplemented();
    completionHandler();
}
#endif

void RemoteGraphicsContextGLResources::copyNativeImage(WebCore::GraphicsContextGL::SurfaceBuffer buffer, RemoteNativeImageReference nativeImageReference)
{
    assertIsCurrent(workQueue());
    RefPtr image = protect(m_context)->copyNativeImage(buffer);
    // FIXME: Handle OOM.
    MESSAGE_CHECK(image);
    bool success = m_sharedResourceCache->addNativeImage(nativeImageReference, image.releaseNonNull());
    MESSAGE_CHECK(success);
}

#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)
void RemoteGraphicsContextGLResources::surfaceBufferToVideoFrame(WebCore::GraphicsContextGL::SurfaceBuffer buffer, WebKit::RemoteVideoFrameReference reference, CompletionHandler<void(std::optional<WebKit::RemoteVideoFrameProxy::Properties>&&)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    std::optional<WebKit::RemoteVideoFrameProxy::Properties> result;
    if (RefPtr videoFrame = protect(m_context)->surfaceBufferToVideoFrame(buffer)) {
        result = RemoteVideoFrameProxy::properties(*videoFrame);
        m_videoFrameObjectHeap->add(reference, videoFrame.releaseNonNull());
    }
    completionHandler(WTF::move(result));
}
#endif

bool RemoteGraphicsContextGLResources::webXREnabled() const
{
    RefPtr gpuConnectionToWebProcess = m_gpuConnectionToWebProcess.get();
    if (gpuConnectionToWebProcess)
        return gpuConnectionToWebProcess->isWebXREnabled();
    return false;
}

bool RemoteGraphicsContextGLResources::webXRPromptAccepted() const
{
    return webXREnabled();
}

void RemoteGraphicsContextGLResources::simulateEventForTesting(WebCore::GraphicsContextGL::SimulatedEventForTesting event)
{
    assertIsCurrent(workQueue());
    // FIXME: only run this in testing mode. https://bugs.webkit.org/show_bug.cgi?id=222544
    if (event == WebCore::GraphicsContextGL::SimulatedEventForTesting::Timeout) {
        // Simulate the timeout by just discarding the context. The subsequent messages act like
        // unauthorized or old messages from Web process, they are skipped.
        callOnMainRunLoop([gpuConnectionToWebProcess = m_gpuConnectionToWebProcess, identifier = m_identifier]() {
            if (auto connectionToWeb = gpuConnectionToWebProcess.get())
                connectionToWeb->releaseGraphicsContextGLForTesting(identifier);
        });
        return;
    }
    protect(m_context)->simulateEventForTesting(event);
}

void RemoteGraphicsContextGLResources::getBufferSubDataInline(uint32_t target, uint64_t offset, uint64_t dataSize, CompletionHandler<void(std::span<const uint8_t>)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    static constexpr size_t getBufferSubDataInlineSizeLimit = 64 * KB; // NOTE: when changing, change the value in RemoteGraphicsContextGLProxy too.

    RefPtr context = m_context;
    if (!dataSize || dataSize > getBufferSubDataInlineSizeLimit) {
        context->addError(GCGLErrorCode::InvalidOperation);
        completionHandler({ });
        return;
    }

    MallocSpan<uint8_t> buffer = MallocSpan<uint8_t>::tryMalloc(dataSize);
    if (buffer) {
        if (!context->getBufferSubDataWithStatus(target, offset, buffer.mutableSpan()))
            buffer = { };
    } else
        context->addError(GCGLErrorCode::OutOfMemory);

    completionHandler(buffer.span());
}

void RemoteGraphicsContextGLResources::getBufferSubDataSharedMemory(uint32_t target, uint64_t offset, uint64_t dataSize, WebCore::SharedMemory::Handle handle, CompletionHandler<void(bool)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    bool validBufferData = false;

    static constexpr size_t readPixelsSharedMemorySizeLimit = 100 * MB; // NOTE: when changing, change the value in RemoteGraphicsContextGLProxy too.

    if (dataSize > readPixelsSharedMemorySizeLimit) {
        completionHandler({ });
        return;
    }

    RefPtr context = m_context;

    handle.setOwnershipOfMemory(m_webProcessIdentity, WebKit::MemoryLedger::Default);
    auto buffer = SharedMemory::map(WTF::move(handle), SharedMemory::Protection::ReadWrite);
    if (buffer && dataSize <= buffer->size())
        validBufferData = context->getBufferSubDataWithStatus(target, offset, buffer->mutableSpan().subspan(0, dataSize));
    else
        context->addError(GCGLErrorCode::InvalidOperation);

    completionHandler(validBufferData);
}

void RemoteGraphicsContextGLResources::readPixelsInline(WebCore::IntRect rect, uint32_t format, uint32_t type, bool packReverseRowOrder, CompletionHandler<void(std::optional<WebCore::IntSize>, std::span<const uint8_t>)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    static constexpr size_t readPixelsInlineSizeLimit = 64 * KB; // NOTE: when changing, change the value in RemoteGraphicsContextGLProxy too.
    unsigned bytesPerGroup = GraphicsContextGL::computeBytesPerGroup(format, type);
    auto replyImageBytes = rect.area<RecordOverflow>() * bytesPerGroup;
    if (!bytesPerGroup || replyImageBytes.hasOverflowed()) {
        completionHandler(std::nullopt, { });
        return;
    }
    MallocSpan<uint8_t> pixels;
    if (replyImageBytes && replyImageBytes <= readPixelsInlineSizeLimit)
        pixels = MallocSpan<uint8_t>::tryZeroedMalloc(replyImageBytes);

    RefPtr context = m_context;
    std::optional<WebCore::IntSize> readArea;
    if (pixels.sizeInBytes() == replyImageBytes)
        readArea = context->readPixelsWithStatus(rect, format, type, packReverseRowOrder, pixels.mutableSpan());
    else
        context->addError(GCGLErrorCode::OutOfMemory);
    if (!readArea)
        pixels = { };
    completionHandler(readArea, pixels.span());
}


void RemoteGraphicsContextGLResources::readPixelsSharedMemory(WebCore::IntRect rect, uint32_t format, uint32_t type, bool packReverseRowOrder, SharedMemory::Handle handle, CompletionHandler<void(std::optional<WebCore::IntSize>)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    std::optional<WebCore::IntSize> readArea;

    RefPtr context = m_context;
    handle.setOwnershipOfMemory(m_webProcessIdentity, WebKit::MemoryLedger::Default);
    if (auto buffer = SharedMemory::map(WTF::move(handle), SharedMemory::Protection::ReadWrite))
        readArea = context->readPixelsWithStatus(rect, format, type, packReverseRowOrder, buffer->mutableSpan());
    else
        context->addError(GCGLErrorCode::InvalidOperation);

    completionHandler(readArea);
}

#if ENABLE(WEBXR)

void RemoteGraphicsContextGLResources::framebufferDiscard(uint32_t target, std::span<const uint32_t> attachments)
{
    assertIsCurrent(workQueue());
    MESSAGE_CHECK(webXRPromptAccepted());
    protect(m_context)->framebufferDiscard(target, Vector(attachments));
}

#endif

void RemoteGraphicsContextGLResources::setDrawingBufferColorSpace(WebCore::ColorSpace&& colorSpace)
{
    assertIsCurrent(workQueue());
    protect(m_context)->setDrawingBufferColorSpace(colorSpace);
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEBGL)
