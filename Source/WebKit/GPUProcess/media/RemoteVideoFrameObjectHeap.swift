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
import CoreGraphics
import CoreVideo
#endif
private import Cxx
import Dispatch
import Synchronization
import WebCore_Private
import WebKit_Internal
#if WTF_PLATFORM_COCOA
import os

// RELEASE_LOG_ERROR(WebRTC, ...).
private var releaseLog: os.Logger {
    os.Logger(WTF.osLog(WebKit.LogChannel.WebRTC()))
}

private typealias ProxyProcessorMessages = WebKit.RemoteVideoFrameObjectHeap.RemoteVideoFrameObjectHeapProxyProcessorMessages

// What converts the frames the web process reads back: their rotation, and their conversion to 32-bit BGRA.
private struct ConversionSessions {
    var rotation: WebCore.ImageRotationSessionVT?
    var conformer: WebCore.PixelBufferConformerCV?
}
#endif

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

// The frames of a RemoteVideoFrameObjectHeap, for any thread, which its Swift readers and producers use directly, and the
// handler of its message that releases one.
final class VideoFrameHeap: Sendable {
    fileprivate let frames = Mutex(VideoFrameTable())
    #if WTF_PLATFORM_COCOA
    // The heap queue's reader of the frames the web process shares, and the writer of the frames it reads back, which
    // removeAll() disables on any thread.
    private let frameSource = Mutex(SharedVideoFrameSource(heap: nil, resourceOwner: WebCore.ProcessIdentity(), hasResourceOwner: false, useIOSurfaceBufferPool: false))
    private let writer: WebKit.SharedVideoFrameWriterForSwift = WebKit.SharedVideoFrameWriterForSwift.create()
    // What the writer hands the semaphore and memory it makes to, made once for the heap's connection.
    private let writerCallbacks = Mutex<WriterCallbacks?>(nil)
    fileprivate let conversionSessions = Mutex(ConversionSessions())
    #endif

    fileprivate func add(_ reference: VideoFrameReference, _ frame: HeapFrame) {
        let (_, waiters) = frames.withLock { ($0.add(reference, frame), $0.takeWaiters()) }
        for waiter in waiters {
            waiter.signal()
        }
    }

    func removeAll() {
        #if WTF_PLATFORM_COCOA
        writer.disable()
        #endif
        let (_, waiters) = frames.withLock { ($0.removeAll(), $0.takeWaiters()) }
        for waiter in waiters {
            waiter.signal()
        }
    }

    // Waits for a frame that isn't in the heap yet only if the web process allocated its reference
    // (remoteVideoFrameReadTimeoutSeconds()), so never on a Swift concurrency thread.
    @available(*, noasync)
    fileprivate func read(_ reference: VideoFrameReference) -> HeapFrame? {
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

    fileprivate func release(_ reference: VideoFrameReference, pendingReads: UInt64) {
        _ = frames.withLock { $0.remove(reference, pendingReads: pendingReads) }
    }

    func releaseVideoFrame(connection: IPC.Connection, write: IPCTypes.RemoteVideoFrameWriteReference) {
        release(VideoFrameReference(identifier: write.reference.identifier.rawValue, version: write.reference.version), pendingReads: write.pendingReads)
    }

    #if WTF_PLATFORM_COCOA
    // Adds a frame under a newly generated reference, whose identifier this returns, with version 0.
    func lend(_ pixelBuffer: CVPixelBuffer?, rotation: UInt16, isMirrored: Bool) -> UInt64 {
        let identifier = WebKit.RemoteVideoFrameObjectHeap.generateFrameIdentifier()
        add(VideoFrameReference(identifier: identifier, version: 0), HeapFrame(pixelBuffer: pixelBuffer, rotation: rotation, isMirrored: isMirrored))
        return identifier
    }

    // The pixel buffer of the frame of a read reference, for the Swift readers of shared video frames.
    @available(*, noasync)
    func readPixelBuffer(identifier: UInt64, version: UInt64) -> CVPixelBuffer? {
        read(VideoFrameReference(identifier: identifier, version: version))?.pixelBuffer
    }

    // MARK: Messages, on the heap's work queue

    func getVideoFrameBuffer(connection: IPC.Connection, read: IPCTypes.RemoteVideoFrameReadReference) {
        let identifier = read.reference.identifier
        var buffer: IPCTypes.Buffer? = nil
        if let pixelBuffer = self.read(VideoFrameReference(identifier: identifier.rawValue, version: read.reference.version))?.pixelBuffer {
            buffer = write(pixelBuffer, on: connection)
            // FIXME: We should assert that the write succeeded once we support enough pixel buffer types.
        }
        ProxyProcessorMessages.newVideoFrameBuffer(on: connection, to: 0, identifier: identifier, frame: buffer)
    }

    func setSharedVideoFrameSemaphore(connection: IPC.Connection, semaphore: borrowing IPCTypes.Semaphore) {
        let port = semaphore.port
        frameSource.withLock { $0.setSemaphore(port) }
    }

    func setSharedVideoFrameMemory(connection: IPC.Connection, storageHandle: borrowing IPCTypes.SharedMemoryHandle) {
        let port = storageHandle.port
        let size = storageHandle.size
        _ = frameSource.withLock { $0.setSharedMemory(port, size) }
    }

    func convertFrameBuffer(
        connection: IPC.Connection,
        frame: consuming IPCTypes.SharedVideoFrame,
        shouldApplyRotation: Bool,
        reply: consuming RemoteVideoFrameObjectHeapConvertFrameBufferReply
    ) {
        let colorSpace = sendConvertedFrameBuffer(frame, shouldApplyRotation: shouldApplyRotation, on: connection)
        reply.send(encodedBy: { IPC.encodeColorSpace($0, colorSpace) })
    }

    // Takes the frame from the heap if the SharedVideoFrame refers to a heap frame, and otherwise reads the frame it carries,
    // and sends it back as 32-bit BGRA. When requested, the frame is oriented and callers must not apply the rotation and
    // mirroring of the frame again.
    @available(*, noasync)
    private func sendConvertedFrameBuffer(_ frame: borrowing IPCTypes.SharedVideoFrame, shouldApplyRotation: Bool, on connection: IPC.Connection) -> CGColorSpace {
        var destinationColorSpace = sRGBColorSpace
        var source: HeapFrame?
        switch frame.buffer {
        case .remoteVideoFrameReadReference(let read):
            if let pixelBuffer = self.read(VideoFrameReference(identifier: read.reference.identifier.rawValue, version: read.reference.version))?.pixelBuffer {
                source = HeapFrame(pixelBuffer: pixelBuffer, rotation: frame.rotation.rawValue, isMirrored: frame.mirrored)
            }
        default:
            source = frameSource.withLock { frameSource in
                frameSource.read(frame).map { HeapFrame(pixelBuffer: $0.pixelBuffer, rotation: $0.rotation, isMirrored: $0.isMirrored) }
            }
        }
        guard let source, var pixelBuffer = source.pixelBuffer else {
            ProxyProcessorMessages.newConvertedVideoFrameBuffer(on: connection, to: 0, frame: nil)
            return destinationColorSpace
        }
        let rotation = source.rotation
        let isMirrored = source.isMirrored

        if shouldApplyRotation && (rotation != 0 || isMirrored) {
            // The heap frame is Sendable, so the session's lock region doesn't take in the pixel buffer.
            let input = HeapFrame(pixelBuffer: pixelBuffer, rotation: rotation, isMirrored: isMirrored)
            let rotated = conversionSessions.withLock { sessions in
                if sessions.rotation == nil {
                    sessions.rotation = WebCore.ImageRotationSessionVT(.Yes)
                }
                guard let inputBuffer = input.pixelBuffer else {
                    return HeapFrame(pixelBuffer: nil, rotation: 0, isMirrored: false)
                }
                let rotated = WebCore.copyRotatedPixelBuffer(&sessions.rotation!, inputBuffer, WebCore.VideoFrameRotation(rawValue: input.rotation) ?? .None, input.isMirrored)
                return HeapFrame(pixelBuffer: rotated, rotation: 0, isMirrored: false)
            }.pixelBuffer
            guard let rotated else {
                releaseLog.error("RemoteVideoFrameObjectHeap::convertFrameBuffer rotation failed")
                ProxyProcessorMessages.newConvertedVideoFrameBuffer(on: connection, to: 0, frame: nil)
                return destinationColorSpace
            }
            pixelBuffer = rotated
        }

        destinationColorSpace = WebCore.copyCGColorSpaceForCVPixelBuffer(pixelBuffer)

        if CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA {
            let input = HeapFrame(pixelBuffer: pixelBuffer, rotation: 0, isMirrored: false)
            let converted = conversionSessions.withLock { sessions in
                if sessions.conformer == nil {
                    sessions.conformer = WebCore.PixelBufferConformerCV(kCVPixelFormatType_32BGRA)
                }
                guard let inputBuffer = input.pixelBuffer else {
                    return HeapFrame(pixelBuffer: nil, rotation: 0, isMirrored: false)
                }
                return HeapFrame(pixelBuffer: WebCore.copyConvertedPixelBuffer(&sessions.conformer!, inputBuffer), rotation: 0, isMirrored: false)
            }.pixelBuffer
            guard let converted else {
                releaseLog.error("RemoteVideoFrameObjectHeap::convertFrameBuffer conformer failed")
                ProxyProcessorMessages.newConvertedVideoFrameBuffer(on: connection, to: 0, frame: nil)
                return destinationColorSpace
            }
            pixelBuffer = converted
        }

        let buffer = write(pixelBuffer, on: connection)
        ProxyProcessorMessages.newConvertedVideoFrameBuffer(on: connection, to: 0, frame: buffer)
        return destinationColorSpace
    }

    // Writes the pixel buffer into the memory it shares with the web process, which then reads it as the null buffer.
    private func write(_ pixelBuffer: CVPixelBuffer, on connection: IPC.Connection) -> IPCTypes.Buffer? {
        let callbacks = writerCallbacks.withLock { callbacks in
            if let callbacks {
                return callbacks
            }
            let made = WriterCallbacks(connection: connection)
            callbacks = made
            return made
        }
        let written = writer.writeToSharedMemory(pixelBuffer, callbacks.newSemaphore, callbacks.newMemory)
        return written ? .null : nil
    }
    #endif
}

#if WTF_PLATFORM_COCOA
private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// The functions the heap's writer sends the web process the semaphore and memory it makes with, on the heap's connection,
// which every message to the heap comes from. @unchecked Sendable: they don't change once made, and are only called on the
// heap's work queue, during a write.
private final class WriterCallbacks: @unchecked Sendable {
    let newSemaphore: WebKit.SharedVideoFrameSemaphoreFunction
    let newMemory: WebKit.SharedVideoFrameMemoryFunction

    init(connection: IPC.Connection) {
        newSemaphore = WebKit.SharedVideoFrameSemaphoreFunction { (port: mach_port_t) in
            ProxyProcessorMessages.setSharedVideoFrameSemaphore(on: connection, to: 0, semaphore: IPCTypes.Semaphore(copying: port))
        }
        newMemory = WebKit.SharedVideoFrameMemoryFunction { (port: mach_port_t, size: UInt64) in
            ProxyProcessorMessages.setSharedVideoFrameMemory(on: connection, to: 0, storageHandle: IPCTypes.SharedMemoryHandle(copying: port, size: size))
        }
    }
}
#endif

// The members of the C++ heap (RemoteVideoFrameObjectHeap.h) that reach its Swift state, which m_swiftState holds
// retained, by address, from the heap's constructor to its destructor, and the handlers of its messages that take Swift
// types and the heap, on its work queue.
extension WebKit.RemoteVideoFrameObjectHeap {
    @cxx
    @implementation
    static func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(VideoFrameHeap()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<VideoFrameHeap>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The heap has no Swift state")
        }
        return unsafe address
    }

    // The heap's frames, for its Swift readers and producers.
    var frames: VideoFrameHeap {
        state
    }

    var state: VideoFrameHeap {
        // Safety: m_swiftState is a retained VideoFrameHeap from the constructor to the destructor, and
        // nothing changes it.
        unsafe Unmanaged<VideoFrameHeap>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    #if WTF_PLATFORM_COCOA
    @cxx
    @implementation
    func swiftAdd(_ identifier: UInt64, _ pixelBuffer: CVPixelBuffer?, _ rotation: UInt16, _ isMirrored: Bool) {
        let frame = HeapFrame(pixelBuffer: pixelBuffer, rotation: rotation, isMirrored: isMirrored)
        state.add(VideoFrameReference(identifier: identifier, version: 0), frame)
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

    #if WTF_PLATFORM_COCOA
    @cxx
    @implementation
    func lowMemoryHandler() {
        state.conversionSessions.withLock { $0 = ConversionSessions() }
    }
    #endif
}

#endif
