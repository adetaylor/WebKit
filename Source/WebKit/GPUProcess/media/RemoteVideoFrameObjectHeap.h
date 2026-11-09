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
#include "RemoteVideoFrameProxy.h"
#include "WorkQueueMessageReceiver.h"
#include <WebCore/VideoFrame.h>
#include <optional>
#include <wtf/CompletionHandler.h>
#include <wtf/Lock.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>

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

// Holds the VideoFrames that the GPU process lends to the web process, which refers to them with RemoteVideoFrameReferences,
// for any thread, and receives the web process's messages about them on its work queue. The frames are in the Swift state
// that m_swiftState holds (RemoteVideoFrameObjectHeap.swift), which also handles the messages that take Swift types.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteVideoFrameObjectHeap.swift") RemoteVideoFrameObjectHeap final : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteVideoFrameObjectHeap);
public:
    static Ref<RemoteVideoFrameObjectHeap> create(Ref<IPC::Connection>&&);
    ~RemoteVideoFrameObjectHeap();

    void ref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::ref(); }
    void deref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::deref(); }

    // Stops the heap's messages and writing frames for the web process, and releases the frames. Clients might hold on to
    // the heap after this. They should also stop themselves, but if they do not, releasing the frames avoids big memory
    // leaks, and they fail gracefully to look them up. Frames can still be added.
    void close();
    // Adds `frame` under a newly generated reference.
    RemoteVideoFrameReference add(Ref<WebCore::VideoFrame>&&);
    // Adds `frame` under `reference`.
    void add(RemoteVideoFrameReference, Ref<WebCore::VideoFrame>&&);
    RefPtr<WebCore::VideoFrame> get(RemoteVideoFrameReadReference&&);

    void stopListeningForIPC(Ref<RemoteVideoFrameObjectHeap>&&) { close(); }
    void lowMemoryHandler();

#if PLATFORM(COCOA)
    // Each takes a right of its own to the port that the heap's IPCTypes.Semaphore or SharedMemoryHandle owns.
    void setSharedVideoFrameSemaphore(mach_port_t);
    void setSharedVideoFrameMemory(mach_port_t, uint64_t size);
#endif

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

private:
    explicit RemoteVideoFrameObjectHeap(Ref<IPC::Connection>&&);

    // Messages that take C++ types.
    void releaseVideoFrame(RemoteVideoFrameWriteReference&&);
#if PLATFORM(COCOA)
    void getVideoFrameBuffer(RemoteVideoFrameReadReference&&);
    void convertFrameBuffer(SharedVideoFrame&&, bool shouldApplyRotation, CompletionHandler<void(WebCore::ColorSpace)>&&);
    // Takes frameFromHeap if the SharedVideoFrame refers to a heap frame, and otherwise reads the frame it carries, and
    // sends it back as 32-bit BGRA.
    WebCore::ColorSpace sendConvertedFrameBuffer(SharedVideoFrame&&, WebCore::VideoFrame* WTF_NULLABLE frameFromHeap, bool shouldApplyRotation);
#endif

    // Implemented in Swift, in RemoteVideoFrameObjectHeap.swift, on the state that m_swiftState holds. Each is safe on
    // any thread.
    static uintptr_t createSwiftState();
    static void destroySwiftState(uintptr_t);
    void swiftAdd(uint64_t identifier, WebCore::VideoFrame* WTF_NONNULL);
    RefPtrVideoFrame swiftRead(uint64_t identifier, uint64_t version);
    void swiftRelease(uint64_t identifier, uint64_t version, uint64_t pendingReads);
    void swiftRemoveAll();

    const Ref<IPC::Connection> m_connection;
#if PLATFORM(COCOA)
    SharedVideoFrameWriter m_sharedVideoFrameWriter;
    SharedVideoFrameReader m_sharedVideoFrameReader;
    Lock m_pixelBufferConformerLock;
    std::unique_ptr<WebCore::PixelBufferConformerCV> m_pixelBufferConformer WTF_GUARDED_BY_LOCK(m_pixelBufferConformerLock);
    std::unique_ptr<WebCore::ImageRotationSessionVT> m_imageRotationSession WTF_GUARDED_BY_LOCK(m_pixelBufferConformerLock);
#endif
    bool m_isClosed { false };
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    const uintptr_t m_swiftState;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// How long a read waits for the frame of a reference that isn't in the heap yet. The GPU process adds a frame under a
// reference it allocates before it sends the reference anywhere, so a miss for such a reference is final. The web process
// allocates the references of the frames it requests: an asynchronous request can let the reference reach a consumer on
// another connection (e.g. WebGL copyTextureFromVideoFrame on its own stream) before the request that adds the frame is
// handled. The 10 s are an outer safety cap for that, not a steady-state wait.
inline double remoteVideoFrameReadTimeoutSeconds(uint64_t identifier) { return isInGPUProcessObjectIdentifierDomain(identifier) ? 0 : 10; }

}

#endif
