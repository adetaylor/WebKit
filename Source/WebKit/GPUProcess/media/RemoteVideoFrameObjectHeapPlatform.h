/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)

#include "ObjectIdentifierDomains.h"
#include "RemoteVideoFrameIdentifier.h"
#include <WebCore/VideoFrame.h>
#include <optional>
#include <wtf/Lock.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/ThreadSafeRefCounted.h>

#if PLATFORM(COCOA)
#include "Connection.h"
#include "SharedVideoFrame.h"
#include "SwiftCoding.h"
#include <WebCore/ColorSpace.h>
#include <wtf/RetainPtr.h>
#endif

namespace IPC {
class Connection;
class Semaphore;
}

namespace WebCore {
class ImageRotationSessionVT;
class PixelBufferConformerCV;
}

namespace WebKit {

using RefPtrVideoFrame = RefPtr<WebCore::VideoFrame>;
#if PLATFORM(COCOA)
using OptionalRemoteVideoFrameReadReference = std::optional<RemoteVideoFrameReadReference>;
#endif

// What RemoteVideoFrameObjectHeap.swift does through C++: its connection, and on Cocoa the shared frame writer and reader
// and the pixel buffer conversions.
class RemoteVideoFrameObjectHeapPlatform final : public ThreadSafeRefCounted<RemoteVideoFrameObjectHeapPlatform> {
public:
    static Ref<RemoteVideoFrameObjectHeapPlatform> create(Ref<IPC::Connection>&&);
    ~RemoteVideoFrameObjectHeapPlatform();

    // Stops the heap's messages and writing frames for the web process.
    void close();
    void lowMemoryHandler();

#if PLATFORM(COCOA)
    void sendVideoFrameBuffer(RemoteVideoFrameIdentifier, WebCore::VideoFrame* WTF_NULLABLE);
    // Takes frameFromHeap if the SharedVideoFrame refers to a heap frame, and otherwise reads the frame it carries, and
    // sends it back as 32-bit BGRA.
    WebCore::ColorSpace convertFrameBuffer(SharedVideoFrame&&, WebCore::VideoFrame* WTF_NULLABLE frameFromHeap, bool shouldApplyRotation);
    // Each takes a right of its own to the port that the heap's IPCTypes.Semaphore or SharedMemoryHandle owns.
    void setSharedVideoFrameSemaphore(mach_port_t);
    void setSharedVideoFrameMemory(mach_port_t, uint64_t size);
#endif

private:
    explicit RemoteVideoFrameObjectHeapPlatform(Ref<IPC::Connection>&&);

    const Ref<IPC::Connection> m_connection;
#if PLATFORM(COCOA)
    SharedVideoFrameWriter m_sharedVideoFrameWriter;
    SharedVideoFrameReader m_sharedVideoFrameReader;
    Lock m_pixelBufferConformerLock;
    std::unique_ptr<WebCore::PixelBufferConformerCV> m_pixelBufferConformer WTF_GUARDED_BY_LOCK(m_pixelBufferConformerLock);
    std::unique_ptr<WebCore::ImageRotationSessionVT> m_imageRotationSession WTF_GUARDED_BY_LOCK(m_pixelBufferConformerLock);
#endif
};

// Swift doesn't see the members that ObjectIdentifierGeneric inherits.
inline uint64_t remoteVideoFrameIdentifierValue(RemoteVideoFrameIdentifier identifier) { return identifier.toUInt64(); }

// How long a read waits for the frame of a reference that isn't in the heap yet. The GPU process adds a frame under a
// reference it allocates before it sends the reference anywhere, so a miss for such a reference is final. The web process
// allocates the references of the frames it requests: an asynchronous request can let the reference reach a consumer on
// another connection (e.g. WebGL copyTextureFromVideoFrame on its own stream) before the request that adds the frame is
// handled. The 10 s are an outer safety cap for that, not a steady-state wait.
inline double remoteVideoFrameReadTimeoutSeconds(uint64_t identifier) { return isInGPUProcessObjectIdentifierDomain(identifier) ? 0 : 10; }

#if PLATFORM(COCOA)
OptionalRemoteVideoFrameReadReference sharedVideoFrameReadReference(const SharedVideoFrame&);
#endif

}

#if PLATFORM(COCOA)
namespace IPC {

// ConvertFrameBuffer's reply when its Swift handler finds the message invalid, as when the C++ handler failed.
template<> struct AsyncReplyError<WebCore::ColorSpace> {
    static WebCore::ColorSpace create() { return WebCore::ColorSpace { WebCore::ColorSpace::SRGB().platformColorSpace() }; }
};

}
#endif

#endif
