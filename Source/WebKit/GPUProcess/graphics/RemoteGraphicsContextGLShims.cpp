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
#include "RemoteGraphicsContextGLShims.h"

#if ENABLE(GPU_PROCESS) && ENABLE(WEBGL)

#include "StreamConnectionWorkQueue.h"
#include <wtf/NeverDestroyed.h>

#if PLATFORM(COCOA)
#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "RemoteGraphicsContextGLInitializationState.h"
#include "RemoteGraphicsContextGLProxyMessages.h"
#include "RemoteRenderingBackend.h"
#include "RemoteSharedResourceCache.h"
#include "RemoteVideoFrameObjectHeap.h"
#include "RemoteVideoFrameProxy.h"
#include <WebCore/IOSurface.h>
#include <WebCore/VideoFrameCV.h>
#include <wtf/MachSendRight.h>
#include <wtf/MainThread.h>
#endif

namespace WebKit {

// Currently we have one global WebGL processing instance.
IPC::StreamConnectionWorkQueue& remoteGraphicsContextGLStreamWorkQueueSingleton()
{
    // NeverDestroyed owns the initial ref.
    static NeverDestroyed<IPC::StreamConnectionWorkQueue> instance { "RemoteGraphicsContextGL work queue"_s };
    return instance.get();
}

#if PLATFORM(COCOA)

using namespace WebCore;

void RemoteGraphicsContextGLClient::create(IPC::SwiftReceiverOwner& owner, GPUConnectionToWebProcess& connection, RemoteRenderingBackend& renderingBackend, uint64_t identifier, const GraphicsContextGLAttributes& attributes)
{
    Ref client = adoptRef(*new RemoteGraphicsContextGLClient(owner, connection, renderingBackend, identifier));
    remoteGraphicsContextGLStreamWorkQueueSingleton().dispatch([client = WTF::move(client), attributes = GraphicsContextGLAttributes { attributes }]() mutable {
        client->initialize(WTF::move(attributes));
    });
}

RemoteGraphicsContextGLClient::RemoteGraphicsContextGLClient(IPC::SwiftReceiverOwner& owner, GPUConnectionToWebProcess& connection, RemoteRenderingBackend& renderingBackend, uint64_t identifier)
    : m_owner(owner)
    , m_connection(connection)
    , m_sharedResourceCache(renderingBackend.sharedResourceCache())
    , m_videoFrameObjectHeap(connection.videoFrameObjectHeap())
    , m_webProcessIdentity(connection.webProcessIdentity())
    , m_identifier(identifier)
{
    acquireWebGLRenderingResources();
}

RemoteGraphicsContextGLClient::~RemoteGraphicsContextGLClient()
{
    if (RefPtr context = m_context)
        context->setClient(nullptr);
    releaseWebGLRenderingResources();
}

void RemoteGraphicsContextGLClient::initialize(GraphicsContextGLAttributes&& attributes)
{
    if (!m_owner->streamConnection())
        return;
    m_context = GraphicsContextGLCocoa::create(WTF::move(attributes), ProcessIdentity { m_webProcessIdentity });
    RefPtr context = m_context;
    if (!context) {
        m_owner->connection().send(Messages::RemoteGraphicsContextGLProxy::WasCreated(std::nullopt), m_identifier);
        return;
    }
    context->setClient(this);
    startReceiver();
}

void RemoteGraphicsContextGLClient::sendWasCreated(RemoteGraphicsContextGLInitializationState& initializationState)
{
    initializationState.estimatedMemoryCost = m_context->estimatedMemoryCost().transform([](size_t cost) { return static_cast<uint64_t>(cost); });
    m_owner->connection().send(Messages::RemoteGraphicsContextGLProxy::WasCreated({ initializationState }), m_identifier);
}

void RemoteGraphicsContextGLClient::forceContextLost()
{
    m_owner->connection().send(Messages::RemoteGraphicsContextGLProxy::WasLost(), m_identifier);
}

void RemoteGraphicsContextGLClient::addDebugMessage(GCGLenum type, GCGLenum id, GCGLenum severity, std::span<const char8_t> message)
{
    m_owner->connection().send(Messages::RemoteGraphicsContextGLProxy::addDebugMessage(type, id, severity, message), m_identifier);
}

void RemoteGraphicsContextGLClient::didChangeMemoryCost()
{
    if (std::exchange(m_memoryCostChanged, true))
        return;
    m_owner->scheduleWork();
}

void releaseWebGLThreadResources()
{
    remoteGraphicsContextGLStreamWorkQueueSingleton().dispatch([] {
        GraphicsContextGLANGLE::releaseThreadResources(GraphicsContextGLANGLE::ReleaseThreadResourceBehavior::TerminateAndReleaseThreadResources);
    });
}

void encodeDisplayBuffer(GraphicsContextGLCocoa& context, IPC::SwiftReplyEncoder& encoder)
{
    MachSendRight sendRight;
    if (auto* surface = context.displayBufferSurface())
        sendRight = surface->createSendRight();
    encoder.encodeWithArgumentCoder(WTF::move(sendRight));
}

bool copyNativeImage(GraphicsContextGLCocoa& context, RemoteSharedResourceCache& cache, GraphicsContextGLSurfaceBuffer buffer, RemoteNativeImageReference reference)
{
    // FIXME: Handle OOM.
    RefPtr image = context.copyNativeImage(buffer);
    return image && cache.addNativeImage(reference, image.releaseNonNull());
}

#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)
std::optional<RemoteVideoFrameProxyProperties> surfaceBufferToVideoFrame(GraphicsContextGLCocoa& context, RemoteVideoFrameObjectHeap& heap, GraphicsContextGLSurfaceBuffer buffer, RemoteVideoFrameReference reference)
{
    RefPtr videoFrame = context.surfaceBufferToVideoFrame(buffer);
    if (!videoFrame)
        return std::nullopt;
    auto properties = RemoteVideoFrameProxy::properties(*videoFrame);
    heap.add(reference, videoFrame.releaseNonNull());
    return properties;
}
#endif

bool copyTextureFromVideoFrame(GraphicsContextGLCocoa& context, CVBufferRef pixelBuffer, uint16_t rotation, bool isMirrored, uint32_t texture, uint32_t target, int32_t level, uint32_t internalFormat, uint32_t type, bool unpackFlipY, bool unpackPremultiplyAlpha)
{
    Ref videoFrame = VideoFrameCV::create({ }, isMirrored, static_cast<VideoFrame::Rotation>(rotation), RetainPtr { static_cast<CVPixelBufferRef>(pixelBuffer) });
    return context.copyTextureFromVideoFrame(videoFrame, texture, target, level, internalFormat, type, unpackFlipY, unpackPremultiplyAlpha);
}

RefPtr<SharedMemory> RemoteGraphicsContextGLClient::mapForWriting(IPC::CxxDecodedArgument<SharedMemoryHandle>& argument)
{
    auto handle = argument.take();
    RELEASE_ASSERT(handle);
    handle->setOwnershipOfMemory(m_webProcessIdentity, WebKit::MemoryLedger::Default);
    return SharedMemory::map(WTF::move(*handle), SharedMemory::Protection::ReadWrite);
}

bool RemoteGraphicsContextGLClient::getBufferSubData(uint32_t target, uint64_t offset, uint64_t dataSize, IPC::CxxDecodedArgument<SharedMemoryHandle>& handle)
{
    RefPtr buffer = mapForWriting(handle);
    if (!buffer || dataSize > buffer->size()) {
        m_context->addError(GCGLErrorCode::InvalidOperation);
        return false;
    }
    return m_context->getBufferSubDataWithStatus(target, static_cast<GCGLintptr>(offset), buffer->mutableSpan().subspan(0, dataSize));
}

bool RemoteGraphicsContextGLClient::readPixels(int32_t x, int32_t y, int32_t width, int32_t height, uint32_t format, uint32_t type, bool packReverseRowOrder, IPC::CxxDecodedArgument<SharedMemoryHandle>& handle, IntSize& readArea)
{
    RefPtr buffer = mapForWriting(handle);
    if (!buffer) {
        m_context->addError(GCGLErrorCode::InvalidOperation);
        return false;
    }
    auto area = m_context->readPixelsWithStatus({ x, y, width, height }, format, type, packReverseRowOrder, buffer->mutableSpan());
    readArea = area.value_or(IntSize { });
    return !!area;
}

void RemoteGraphicsContextGLClient::releaseForTesting()
{
    callOnMainRunLoop([connection = m_connection, identifier = m_identifier] {
        if (RefPtr connectionToWeb = connection.get())
            connectionToWeb->releaseGraphicsContextGLForTesting(RemoteGraphicsContextGLIdentifier { identifier });
    });
}

void lendBufferData(GraphicsContextGLCocoa& context, uint32_t target, const IPC::LentBytes& data, uint32_t usage)
{
    context.bufferData(target, data.span(), usage);
}

void lendBufferSubData(GraphicsContextGLCocoa& context, uint32_t target, uint64_t offset, const IPC::LentBytes& data)
{
    context.bufferSubData(target, static_cast<GCGLintptr>(offset), data.span());
}

void lendTexImage2D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t border, uint32_t format, uint32_t type, const IPC::LentBytes& pixels)
{
    context.texImage2D(target, level, internalformat, width, height, border, format, type, pixels.span());
}

void lendTexSubImage2D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t width, int32_t height, uint32_t format, uint32_t type, const IPC::LentBytes& pixels)
{
    context.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels.span());
}

void lendCompressedTexImage2D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t border, const IPC::LentBytes& data)
{
    context.compressedTexImage2D(target, level, internalformat, width, height, border, data.span());
}

void lendCompressedTexSubImage2D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t width, int32_t height, uint32_t format, const IPC::LentBytes& data)
{
    context.compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, data.span());
}

void lendTexImage3D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, int32_t internalformat, int32_t width, int32_t height, int32_t depth, int32_t border, uint32_t format, uint32_t type, const IPC::LentBytes& pixels)
{
    context.texImage3D(target, level, internalformat, width, height, depth, border, format, type, pixels.span());
}

void lendTexSubImage3D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t zoffset, int32_t width, int32_t height, int32_t depth, uint32_t format, uint32_t type, const IPC::LentBytes& pixels)
{
    context.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels.span());
}

void lendCompressedTexImage3D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t depth, int32_t border, const IPC::LentBytes& data)
{
    context.compressedTexImage3D(target, level, internalformat, width, height, depth, border, data.span());
}

void lendCompressedTexSubImage3D(GraphicsContextGLCocoa& context, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t zoffset, int32_t width, int32_t height, int32_t depth, uint32_t format, const IPC::LentBytes& data)
{
    context.compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, data.span());
}

#if ENABLE(WEBXR)
bool RemoteGraphicsContextGLClient::webXREnabled() const
{
    RefPtr connection = m_connection.get();
    return connection && connection->isWebXREnabled();
}

bool RemoteGraphicsContextGLClient::webXRPromptAccepted() const
{
#if !PLATFORM(IOS_FAMILY_SIMULATOR)
    auto currentAcceptedValue = protect(GPUProcess::singleton())->immersiveModeProcessIdentity();
    return currentAcceptedValue && m_webProcessIdentity == *currentAcceptedValue;
#else
    return webXREnabled();
#endif
}

void framebufferDiscard(GraphicsContextGLCocoa& context, uint32_t target, const uint32_t* attachments, size_t attachmentCount)
{
    context.framebufferDiscard(target, unsafeMakeSpan(attachments, attachmentCount));
}

uint32_t createExternalImage(GraphicsContextGLCocoa& context, const GraphicsContextGL::ExternalImageSource& source, uint32_t internalFormat, int32_t layer)
{
    return context.createExternalImage(GraphicsContextGL::ExternalImageSource { source }, internalFormat, layer);
}

uint32_t createExternalSync(GraphicsContextGLCocoa& context, const GraphicsContextGL::ExternalSyncSource& source)
{
    return context.createExternalSync(GraphicsContextGL::ExternalSyncSource { source });
}

bool addFoveation(GraphicsContextGLCocoa& context, int32_t leftWidth, int32_t leftHeight, int32_t rightWidth, int32_t rightHeight, int32_t screenWidth, int32_t screenHeight, const float* horizontalSamplesLeft, size_t horizontalSamplesLeftCount, const float* verticalSamples, size_t verticalSamplesCount, const float* horizontalSamplesRight, size_t horizontalSamplesRightCount)
{
    return context.addFoveation({ leftWidth, leftHeight }, { rightWidth, rightHeight }, { screenWidth, screenHeight }, unsafeMakeSpan(horizontalSamplesLeft, horizontalSamplesLeftCount), unsafeMakeSpan(verticalSamples, verticalSamplesCount), unsafeMakeSpan(horizontalSamplesRight, horizontalSamplesRightCount));
}
#endif

#endif // PLATFORM(COCOA)

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEBGL)
