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

#pragma once

#if ENABLE(GPU_PROCESS) && ENABLE(WEBGL)


namespace IPC {
class StreamConnectionWorkQueue;
}

namespace WebKit {

// The work queue of every WebGL context's receiver.
IPC::StreamConnectionWorkQueue& remoteGraphicsContextGLStreamWorkQueueSingleton();

}

#if PLATFORM(COCOA)

#include "RemoteGraphicsContextGLInitializationState.h"
#include "RemoteNativeImageIdentifier.h"
#include "RemoteVideoFrameIdentifier.h"
#include "RemoteVideoFrameProxyProperties.h"
#include "ScopedRenderingResourcesRequest.h"
#include "SwiftCoding.h"
#include "SwiftReceiverOwner.h"
#include <WebCore/GraphicsContextGLCocoa.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/SharedMemory.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <CoreVideo/CVBuffer.h>

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteRenderingBackend;
class RemoteSharedResourceCache;
class RemoteVideoFrameObjectHeap;

// What RemoteGraphicsContextGL (RemoteGraphicsContextGL.swift), the Swift receiver of a WebGL context's messages, can't do
// in Swift: make the context and be its client, a C++ interface, and pass the context's members the IPC handles and C++
// objects they take. On the receiver's work queue, except for create().
class RemoteGraphicsContextGLClient final : public RefCounted<RemoteGraphicsContextGLClient>, private WebCore::GraphicsContextGL::Client {
public:
    // Makes the context on the work queue and tells the web process whether it could. If it could, starts the receiver.
    static void create(IPC::SwiftReceiverOwner&, GPUConnectionToWebProcess&, RemoteRenderingBackend&, uint64_t identifier, const WebCore::GraphicsContextGLAttributes&);
    ~RemoteGraphicsContextGLClient();

    // Implemented in Swift (RemoteGraphicsContextGL.swift): tells the web process that the context was created, and makes
    // the receiver of its messages and starts it.
    void startReceiver();
    // Implemented in Swift: the requests of the contexts for the WebGL rendering resources, which the GPU process frees a
    // second after the last request ends. A client requests them from its creation, on the main thread, to its end.
    static void acquireWebGLRenderingResources();
    static void releaseWebGLRenderingResources();
    void sendWasCreated(RemoteGraphicsContextGLInitializationState&);

    IPC::SwiftReceiverOwner& owner() const SWIFT_RETURNS_UNRETAINED { return m_owner.get(); }
    uint64_t identifier() const { return m_identifier; }
    WebCore::GraphicsContextGLCocoa& context() const SWIFT_RETURNS_UNRETAINED { return *m_context; }
    RemoteSharedResourceCache& sharedResourceCache() const SWIFT_RETURNS_UNRETAINED { return m_sharedResourceCache.get(); }
    RemoteVideoFrameObjectHeap& videoFrameObjectHeap() const SWIFT_RETURNS_UNRETAINED { return m_videoFrameObjectHeap.get(); }
    WebCore::ProcessIdentity webProcessIdentity() const { return m_webProcessIdentity; }
    // Whether the context's memory cost changed since the last call, after which the owner runs the receiver's scheduled work.
    bool takeMemoryCostChange() { return std::exchange(m_memoryCostChanged, false); }
    // Simulates a timeout by releasing the context on the main thread, as if the web process had.
    void releaseForTesting();
    bool getBufferSubData(uint32_t target, uint64_t offset, uint64_t dataSize, IPC::CxxDecodedArgument<WebCore::SharedMemoryHandle>&);
    bool readPixels(int32_t x, int32_t y, int32_t width, int32_t height, uint32_t format, uint32_t type, bool packReverseRowOrder, IPC::CxxDecodedArgument<WebCore::SharedMemoryHandle>&, WebCore::IntSize& readArea);
#if ENABLE(WEBXR)
    bool webXREnabled() const;
    bool webXRPromptAccepted() const;
#endif

private:
    RemoteGraphicsContextGLClient(IPC::SwiftReceiverOwner&, GPUConnectionToWebProcess&, RemoteRenderingBackend&, uint64_t identifier);
    void initialize(WebCore::GraphicsContextGLAttributes&&);

    void forceContextLost() final;
    void addDebugMessage(GCGLenum, GCGLenum, GCGLenum, std::span<const char8_t>) final;
    void didChangeMemoryCost() final;
    RefPtr<WebCore::SharedMemory> mapForWriting(IPC::CxxDecodedArgument<WebCore::SharedMemoryHandle>&);

    const Ref<IPC::SwiftReceiverOwner> m_owner;
    const ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    const Ref<RemoteSharedResourceCache> m_sharedResourceCache;
    const Ref<RemoteVideoFrameObjectHeap> m_videoFrameObjectHeap;
    const WebCore::ProcessIdentity m_webProcessIdentity;
    const uint64_t m_identifier;
    ScopedRenderingResourcesRequest m_renderingResourcesRequest { ScopedRenderingResourcesRequest::acquire() };
    RefPtr<WebCore::GraphicsContextGLCocoa> m_context;
    bool m_memoryCostChanged { false };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

using RemoteGraphicsContextGLTask = Function<void()>;
// After the last context goes, on the work queue.
void releaseWebGLThreadResources();
void encodeDisplayBuffer(WebCore::GraphicsContextGLCocoa&, IPC::SwiftReplyEncoder&);
bool copyNativeImage(WebCore::GraphicsContextGLCocoa&, RemoteSharedResourceCache&, WebCore::GraphicsContextGLSurfaceBuffer, RemoteNativeImageReference);
#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)
std::optional<RemoteVideoFrameProxyProperties> surfaceBufferToVideoFrame(WebCore::GraphicsContextGLCocoa&, RemoteVideoFrameObjectHeap&, WebCore::GraphicsContextGLSurfaceBuffer, RemoteVideoFrameReference);
#endif
bool copyTextureFromVideoFrame(WebCore::GraphicsContextGLCocoa&, CVBufferRef WTF_NONNULL, uint16_t rotation, bool isMirrored, uint32_t texture, uint32_t target, int32_t level, uint32_t internalFormat, uint32_t type, bool unpackFlipY, bool unpackPremultiplyAlpha);

// The payloads, lent by the message for the call.
void lendBufferData(WebCore::GraphicsContextGLCocoa&, uint32_t target, const IPC::LentBytes&, uint32_t usage);
void lendBufferSubData(WebCore::GraphicsContextGLCocoa&, uint32_t target, uint64_t offset, const IPC::LentBytes&);
void lendTexImage2D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t border, uint32_t format, uint32_t type, const IPC::LentBytes&);
void lendTexSubImage2D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t width, int32_t height, uint32_t format, uint32_t type, const IPC::LentBytes&);
void lendCompressedTexImage2D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t border, const IPC::LentBytes&);
void lendCompressedTexSubImage2D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t width, int32_t height, uint32_t format, const IPC::LentBytes&);
void lendTexImage3D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, int32_t internalformat, int32_t width, int32_t height, int32_t depth, int32_t border, uint32_t format, uint32_t type, const IPC::LentBytes&);
void lendTexSubImage3D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t zoffset, int32_t width, int32_t height, int32_t depth, uint32_t format, uint32_t type, const IPC::LentBytes&);
void lendCompressedTexImage3D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t depth, int32_t border, const IPC::LentBytes&);
void lendCompressedTexSubImage3D(WebCore::GraphicsContextGLCocoa&, uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t zoffset, int32_t width, int32_t height, int32_t depth, uint32_t format, const IPC::LentBytes&);

#if ENABLE(WEBXR)
// Unsafe: each pointer must address its count of elements.
SWIFT_UNSAFE void framebufferDiscard(WebCore::GraphicsContextGLCocoa&, uint32_t target, const uint32_t* WTF_NULLABLE attachments, size_t attachmentCount);
uint32_t createExternalImage(WebCore::GraphicsContextGLCocoa&, const WebCore::GraphicsContextGL::ExternalImageSource&, uint32_t internalFormat, int32_t layer);
uint32_t createExternalSync(WebCore::GraphicsContextGLCocoa&, const WebCore::GraphicsContextGL::ExternalSyncSource&);
SWIFT_UNSAFE bool addFoveation(WebCore::GraphicsContextGLCocoa&, int32_t leftWidth, int32_t leftHeight, int32_t rightWidth, int32_t rightHeight, int32_t screenWidth, int32_t screenHeight, const float* WTF_NULLABLE horizontalSamplesLeft, size_t horizontalSamplesLeftCount, const float* WTF_NULLABLE verticalSamples, size_t verticalSamplesCount, const float* WTF_NULLABLE horizontalSamplesRight, size_t horizontalSamplesRightCount);
#endif

} // namespace WebKit

#endif // PLATFORM(COCOA)

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEBGL)
