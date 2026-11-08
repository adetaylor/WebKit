// Copyright (C) 2022 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS && ENABLE_VIDEO

private import Cxx
import Dispatch
import Synchronization
import WebCore_Private
import WebKit_Internal

// @unchecked Sendable: the heap only stores and hands out the reference, never using the frame, and the reference count
// is atomic. The threads it hands the frame to share it in C++ as they did before; VideoFrame's in-place updates are
// unsafe in Swift, and assert in Debug builds that the frame isn't published.
private struct HeapFrame: @unchecked Sendable {
    let frame: WebCore.VideoFrame
}

private struct VideoFrameReference: Hashable {
    let identifier: UInt64
    let version: UInt64
}

private struct VideoFrameReferenceState {
    var retiredReads: UInt64 = 0
    // The reference is removed after this many reads.
    var finalRead: UInt64?
    // Nil when the web process released the reference before the frame was added.
    var frame: HeapFrame?
}

// The frames lent to the web process, with the reads and the release it announced for each: the protocol of
// IPC::ThreadSafeObjectHeap, without waiting, which no caller did. Each function returns the frame it lets go of, for
// the caller to release once the lock is no longer held.
private struct VideoFrameTable {
    private var states: [VideoFrameReference: VideoFrameReferenceState] = [:]
    // The reads waiting for a frame to be added.
    private var waiters: [DispatchSemaphore] = []

    mutating func addWaiter(_ waiter: DispatchSemaphore) {
        waiters.append(waiter)
    }

    mutating func removeWaiter(_ waiter: DispatchSemaphore) {
        waiters.removeAll { $0 === waiter }
    }

    mutating func takeWaiters() -> [DispatchSemaphore] {
        var taken: [DispatchSemaphore] = []
        swap(&taken, &waiters)
        return taken
    }

    mutating func add(_ reference: VideoFrameReference, _ frame: HeapFrame) -> HeapFrame? {
        guard let index = states.index(forKey: reference) else {
            states[reference] = VideoFrameReferenceState(frame: frame)
            return nil
        }
        if states.values[index].finalRead == 0 {
            states.remove(at: index)
            return frame
        }
        if states.values[index].frame != nil {
            return frame
        }
        states.values[index].frame = frame
        return nil
    }

    mutating func read(_ reference: VideoFrameReference) -> HeapFrame? {
        guard let index = states.index(forKey: reference), let frame = states.values[index].frame else {
            return nil
        }
        states.values[index].retiredReads &+= 1
        if states.values[index].finalRead == states.values[index].retiredReads {
            states.remove(at: index)
        }
        return frame
    }

    mutating func remove(_ reference: VideoFrameReference, pendingReads finalRead: UInt64) -> HeapFrame? {
        guard let index = states.index(forKey: reference) else {
            states[reference] = VideoFrameReferenceState(finalRead: finalRead)
            return nil
        }
        let state = states.values[index]
        if state.finalRead != nil || state.retiredReads > finalRead {
            return nil
        }
        if state.retiredReads == finalRead {
            states.remove(at: index)
            return state.frame
        }
        states.values[index].finalRead = finalRead
        return nil
    }

    mutating func removeAll() -> [VideoFrameReference: VideoFrameReferenceState] {
        var removed: [VideoFrameReference: VideoFrameReferenceState] = [:]
        swap(&removed, &states)
        return removed
    }
}

private func videoFrameReference(_ read: borrowing WebKit.RemoteVideoFrameReadReference) -> VideoFrameReference {
    VideoFrameReference(identifier: WebKit.remoteVideoFrameIdentifierValue(read.identifier()), version: read.version())
}

// Holds the VideoFrames that the GPU process lends to the web process, which refers to them with RemoteVideoFrameReferences,
// for any thread, and handles the web process's messages about them on its work queue.
@_expose(Cxx)
final class RemoteVideoFrameObjectHeap {
    private let platform: WebKit.RemoteVideoFrameObjectHeapPlatform
    private let frames = Mutex(VideoFrameTable())
    private let isClosedFlag = Atomic<Bool>(false)

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(platform: WebKit.RemoteVideoFrameObjectHeapPlatform) {
        self.platform = platform
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the connection it is registered with does.
    @used
    func getMessageReceiver() -> RefRemoteVideoFrameObjectHeapMessageForwarder {
        WebKit.RemoteVideoFrameObjectHeapMessageForwarder.create(target: self)
    }

    // Clients might hold on to the heap after this. They should also stop themselves, but if they do not, releasing the
    // frames avoids big memory leaks, and they fail gracefully to look them up. Frames can still be added.
    @used
    func close() {
        guard !isClosedFlag.exchange(true, ordering: .relaxed) else {
            return
        }
        platform.close()
        let (_, waiters) = frames.withLock { ($0.removeAll(), $0.takeWaiters()) }
        for waiter in waiters {
            waiter.signal()
        }
    }

    @used
    func isClosed() -> Bool {
        isClosedFlag.load(ordering: .relaxed)
    }

    @used
    func add(identifier: UInt64, frame: WebCore.VideoFrame) {
        let (_, waiters) = frames.withLock {
            ($0.add(VideoFrameReference(identifier: identifier, version: 0), HeapFrame(frame: frame)), $0.takeWaiters())
        }
        for waiter in waiters {
            waiter.signal()
        }
    }

    @used
    func read(identifier: UInt64, version: UInt64) -> WebKit.RefPtrVideoFrame {
        WebKit.RefPtrVideoFrame(readFrame(VideoFrameReference(identifier: identifier, version: version)))
    }

    // Waits for a frame that isn't in the heap yet only if the web process allocated its reference
    // (remoteVideoFrameReadTimeoutSeconds()).
    private func readFrame(_ reference: VideoFrameReference) -> WebCore.VideoFrame? {
        let timeout = WebKit.remoteVideoFrameReadTimeoutSeconds(reference.identifier)
        guard timeout > 0 else {
            return frames.withLock { $0.read(reference) }?.frame
        }
        let deadline = DispatchTime.now() + timeout
        while true {
            let waiter = DispatchSemaphore(value: 0)
            let frame: HeapFrame?? = frames.withLock { table in
                if let frame = table.read(reference) {
                    return .some(frame)
                }
                table.addWaiter(waiter)
                return .none
            }
            if let frame {
                return frame?.frame
            }
            if waiter.wait(timeout: deadline) == .timedOut {
                return frames.withLock { table in
                    table.removeWaiter(waiter)
                    return table.read(reference)
                }?.frame
            }
        }
    }

    func releaseVideoFrame(connection: IPC.Connection, write: WebKit.RemoteVideoFrameWriteReference) {
        let reference = VideoFrameReference(
            identifier: WebKit.remoteVideoFrameIdentifierValue(write.identifier()),
            version: write.version()
        )
        let pendingReads = write.pendingReads()
        _ = frames.withLock { $0.remove(reference, pendingReads: pendingReads) }
    }

    #if WTF_PLATFORM_COCOA
    func getVideoFrameBuffer(connection: IPC.Connection, read: WebKit.RemoteVideoFrameReadReference) {
        platform.sendVideoFrameBuffer(read.identifier(), readFrame(videoFrameReference(read)))
    }

    func convertFrameBuffer(
        connection: IPC.Connection,
        frame: consuming WebKit.SharedVideoFrame,
        shouldApplyRotation: Bool
    ) -> WebCore.ColorSpace {
        var frameFromHeap: WebCore.VideoFrame?
        if let read = WebKit.sharedVideoFrameReadReference(frame).value {
            frameFromHeap = readFrame(videoFrameReference(read))
        }
        return platform.convertFrameBuffer(consuming: frame, frameFromHeap, shouldApplyRotation)
    }

    func setSharedVideoFrameSemaphore(
        connection: IPC.Connection,
        semaphore: borrowing IPCTypes.Semaphore
    ) {
        platform.setSharedVideoFrameSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(
        connection: IPC.Connection,
        storageHandle: borrowing IPCTypes.SharedMemoryHandle
    ) {
        platform.setSharedVideoFrameMemory(storageHandle.port, storageHandle.size)
    }
    #endif
}

#endif
