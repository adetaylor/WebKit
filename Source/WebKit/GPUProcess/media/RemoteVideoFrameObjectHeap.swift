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

#if WTF_PLATFORM_COCOA
import CoreVideo
#endif
private import Cxx
import Dispatch
import Synchronization
import WebCore_Private
import WebKit_Internal

#if WTF_PLATFORM_COCOA
// What the heap's readers use of a frame: its pixel buffer, and the display transform that the pixel buffer doesn't
// carry. @unchecked Sendable: the heap only stores and hands out the pixel buffer, never its pixels, and its reference
// count is atomic.
private struct HeapFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer?
    let rotation: UInt16
    let isMirrored: Bool
}
#else
// @unchecked Sendable: the heap only stores and hands out the reference, never using the frame, and the reference count
// is atomic. The threads it hands the frame to share it in C++ as they did before; VideoFrame's in-place updates are
// unsafe in Swift, and assert in Debug builds that the frame isn't published.
private struct HeapFrame: @unchecked Sendable {
    let frame: WebCore.VideoFrame
}
#endif

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

// The frames of a RemoteVideoFrameObjectHeap, for any thread.
private final class RemoteVideoFrameObjectHeapState {
    let frames = Mutex(VideoFrameTable())

    func add(_ reference: VideoFrameReference, _ frame: HeapFrame) {
        let (_, waiters) = frames.withLock { ($0.add(reference, frame), $0.takeWaiters()) }
        for waiter in waiters {
            waiter.signal()
        }
    }

    func removeAll() {
        let (_, waiters) = frames.withLock { ($0.removeAll(), $0.takeWaiters()) }
        for waiter in waiters {
            waiter.signal()
        }
    }

    // Waits for a frame that isn't in the heap yet only if the web process allocated its reference
    // (remoteVideoFrameReadTimeoutSeconds()).
    func read(_ reference: VideoFrameReference) -> HeapFrame? {
        let timeout = WebKit.remoteVideoFrameReadTimeoutSeconds(reference.identifier)
        guard timeout > 0 else {
            return frames.withLock { $0.read(reference) }
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
                return frame
            }
            if waiter.wait(timeout: deadline) == .timedOut {
                return frames.withLock { table in
                    table.removeWaiter(waiter)
                    return table.read(reference)
                }
            }
        }
    }

    func release(_ reference: VideoFrameReference, pendingReads: UInt64) {
        _ = frames.withLock { $0.remove(reference, pendingReads: pendingReads) }
    }
}

// The members of the C++ heap (RemoteVideoFrameObjectHeap.h) that reach its Swift state, which m_swiftState holds
// retained, by address, from the heap's constructor to its destructor, and the handlers of its messages that take Swift
// types, on its work queue.
extension WebKit.RemoteVideoFrameObjectHeap {
    @cxx
    @implementation
    static func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteVideoFrameObjectHeapState()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<RemoteVideoFrameObjectHeapState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The heap has no Swift state")
        }
        return unsafe address
    }

    fileprivate var state: RemoteVideoFrameObjectHeapState {
        // Safety: m_swiftState is a retained RemoteVideoFrameObjectHeapState from the constructor to the destructor, and
        // nothing changes it.
        unsafe Unmanaged<RemoteVideoFrameObjectHeapState>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    #if WTF_PLATFORM_COCOA
    @cxx
    @implementation
    func swiftAdd(_ identifier: UInt64, _ pixelBuffer: CVPixelBuffer?, _ rotation: UInt16, _ isMirrored: Bool) {
        let frame = HeapFrame(pixelBuffer: pixelBuffer, rotation: rotation, isMirrored: isMirrored)
        state.add(VideoFrameReference(identifier: identifier, version: 0), frame)
    }

    // Adds a frame under a newly generated reference, whose identifier this returns, with version 0.
    func lend(_ pixelBuffer: CVPixelBuffer, rotation: UInt16, isMirrored: Bool) -> UInt64 {
        let identifier = Self.generateFrameIdentifier()
        state.add(VideoFrameReference(identifier: identifier, version: 0), HeapFrame(pixelBuffer: pixelBuffer, rotation: rotation, isMirrored: isMirrored))
        return identifier
    }

    // The pixel buffer of the frame of a read reference, for the Swift readers of shared video frames.
    func readPixelBuffer(identifier: UInt64, version: UInt64) -> CVPixelBuffer? {
        state.read(VideoFrameReference(identifier: identifier, version: version))?.pixelBuffer
    }
    #else
    @cxx
    @implementation
    func swiftAdd(_ identifier: UInt64, _ frame: WebCore.VideoFrame) {
        state.add(VideoFrameReference(identifier: identifier, version: 0), HeapFrame(frame: frame))
    }
    #endif


    @cxx
    @implementation
    func swiftRemoveAll() {
        state.removeAll()
    }

    func releaseVideoFrame(connection: IPC.Connection, write: IPCTypes.RemoteVideoFrameWriteReference) {
        let reference = VideoFrameReference(identifier: write.reference.identifier.rawValue, version: write.reference.version)
        state.release(reference, pendingReads: write.pendingReads)
    }

    #if WTF_PLATFORM_COCOA
    func setSharedVideoFrameSemaphore(
        connection: IPC.Connection,
        semaphore: borrowing IPCTypes.Semaphore
    ) {
        setSharedVideoFrameSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(
        connection: IPC.Connection,
        storageHandle: borrowing IPCTypes.SharedMemoryHandle
    ) {
        setSharedVideoFrameMemory(storageHandle.port, storageHandle.size)
    }
    #endif
}

#if WTF_PLATFORM_COCOA
// The frame of a read reference, for C++ (RemoteVideoFrameObjectHeap::get()): its pixel buffer, returned +1, and its
// display transform.
@_expose(Cxx)
func readRemoteVideoFrame(
    _ heap: WebKit.RemoteVideoFrameObjectHeap,
    _ identifier: UInt64,
    _ version: UInt64,
    _ transform: inout WebKit.RemoteVideoFrameTransform
) -> CVPixelBuffer? {
    guard let frame = heap.state.read(VideoFrameReference(identifier: identifier, version: version)) else {
        return nil
    }
    transform.rotation = frame.rotation
    transform.isMirrored = frame.isMirrored
    return frame.pixelBuffer
}
#endif

#endif
