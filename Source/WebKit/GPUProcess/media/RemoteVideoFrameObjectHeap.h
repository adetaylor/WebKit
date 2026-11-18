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

#include "Connection.h"
#include "ObjectIdentifierDomains.h"
#include "RemoteVideoFrameIdentifier.h"
#include "RemoteVideoFrameProxy.h"
#include "WorkQueueMessageReceiver.h"
#include <WebCore/VideoFrame.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>

#include "SwiftCoding.h"

#if PLATFORM(COCOA)
#include "SharedVideoFrame.h"
#include <WebCore/ColorSpace.h>
#endif

namespace WebKit {

// Holds the VideoFrames that the GPU process lends to the web process, which refers to them with RemoteVideoFrameReferences,
// for any thread, and receives the web process's messages about them on its work queue. The frames, and on Cocoa platforms
// what reads and writes them for the web process, are in the Swift state that m_swiftState holds
// (RemoteVideoFrameObjectHeap.swift), which also handles the messages. On Cocoa platforms, it holds what its readers use of a
// frame, its pixel buffer and display transform, rather than the frame.
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
    RemoteVideoFrameReference add(Ref<WebCore::VideoFrame>&& frame)
    {
        auto reference = RemoteVideoFrameReference::generateForAdd();
        add(reference, WTF::move(frame));
        return reference;
    }
    // Adds `frame` under `reference`. On Cocoa platforms, it takes the frame's pixel buffer then; a frame without one
    // can't be read.
    void add(RemoteVideoFrameReference reference, Ref<WebCore::VideoFrame>&& frame)
    {
#if PLATFORM(COCOA)
        swiftAdd(reference.identifier().toUInt64(), frame->pixelBuffer(), static_cast<uint16_t>(frame->rotation()), frame->isMirrored());
#else
#if ASSERT_ENABLED
        frame->markAsPublished();
#endif
        swiftAdd(reference.identifier().toUInt64(), frame.ptr());
#endif
    }

    void stopListeningForIPC(Ref<RemoteVideoFrameObjectHeap>&&) { close(); }
#if PLATFORM(COCOA)
    // Implemented in Swift: drops what converts the frames the web process reads back.
    void lowMemoryHandler();
    // An identifier for a frame that Swift adds.
    static uint64_t generateFrameIdentifier() { return RemoteVideoFrameIdentifier::generate().toUInt64(); }
#else
    void lowMemoryHandler() { }
#endif

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

private:
    explicit RemoteVideoFrameObjectHeap(Ref<IPC::Connection>&&);

    // Implemented in Swift, in RemoteVideoFrameObjectHeap.swift, on the state that m_swiftState holds. Each is safe on
    // any thread.
    static uintptr_t createSwiftState();
    static void destroySwiftState(uintptr_t);
#if PLATFORM(COCOA)
    void swiftAdd(uint64_t identifier, CVPixelBufferRef WTF_NULLABLE, uint16_t rotation, bool isMirrored);
#else
    void swiftAdd(uint64_t identifier, WebCore::VideoFrame* WTF_NONNULL);
#endif
    // Stops writing frames for the web process, and releases the frames.
    void swiftRemoveAll();

    const Ref<IPC::Connection> m_connection;
    bool m_isClosed { false };
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    const uintptr_t m_swiftState;
    IPC::SwiftStateDispatch m_swiftStateDispatch;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// How long a read waits for the frame of a reference that isn't in the heap yet. The GPU process adds a frame under a
// reference it allocates before it sends the reference anywhere, so a miss for such a reference is final. The web process
// allocates the references of the frames it requests: an asynchronous request can let the reference reach a consumer on
// another connection (e.g. WebGL copyTextureFromVideoFrame on its own stream) before the request that adds the frame is
// handled. The 10 s are an outer safety cap for that, not a steady-state wait.
inline double remoteVideoFrameReadTimeoutSeconds(uint64_t identifier) { return isInGPUProcessObjectIdentifierDomain(identifier) ? 0 : 10; }

}

#if PLATFORM(COCOA)
namespace IPC {
// ConvertFrameBuffer's reply when the Swift handler sends none, the colour space it replies with when it fails.
template<> struct AsyncReplyError<WebCore::ColorSpace> {
    static WebCore::ColorSpace create() { return WebCore::ColorSpace::SRGB(); }
};
}
#endif

#endif
