// Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if ENABLE_IPC_TESTING_API && ENABLE_IPC_TESTING_SWIFT

import WebKit_Internal

// Receives the IPCSwiftWorkQueueTester messages that IPCTester registers it for, on a work queue. Like any WorkQueue
// receiver, it is confined to that queue.
@_expose(Cxx)
final class IPCSwiftWorkQueueTester {
    private var recordedDigest: UInt32 = 0
    private var recordedTexts: [String?] = []
    private var alwaysDispatchedOnItsQueue = true

    private var benchSink: UInt64 = 0

    private var deferredSum: UInt32 = 0
    private var deferredReply: IPCSwiftWorkQueueTesterDeferAddSwiftReply?

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
        WebKit.didCreateSwiftWorkQueueTester()
    }

    deinit {
        WebKit.didDestroySwiftWorkQueueTester()
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the connection it is registered with does.
    @used
    func getMessageReceiver() -> RefIPCSwiftWorkQueueTesterMessageForwarder {
        WebKit.IPCSwiftWorkQueueTesterMessageForwarder.create(target: self)
    }

    private func noteDispatch() {
        if !WebKit.isOnSwiftWorkQueueTesterQueue() {
            alwaysDispatchedOnItsQueue = false
        }
    }

    func record(connection: IPC.Connection, value: UInt32) {
        noteDispatch()
        recordedDigest = recordedDigest &* 31 &+ value
    }

    func takeRecordedDigest(connection: IPC.Connection) -> UInt32 {
        noteDispatch()
        defer {
            recordedDigest = 0
        }
        return recordedDigest
    }

    func add(connection: IPC.Connection, a: UInt32, b: UInt32) -> UInt32 {
        noteDispatch()
        return a &+ b
    }

    func wasAlwaysDispatchedOnItsQueue(connection: IPC.Connection) -> Bool {
        noteDispatch()
        return alwaysDispatchedOnItsQueue
    }

    func recordTextSwift(connection: IPC.Connection, text: String?) {
        noteDispatch()
        recordedTexts.append(text)
    }

    func takeRecordedTextsSwift(connection: IPC.Connection) -> (count: UInt32, utf8Length: UInt32) {
        noteDispatch()
        defer {
            recordedTexts = []
        }
        let utf8Length = recordedTexts.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        return (UInt32(truncatingIfNeeded: recordedTexts.count), UInt32(truncatingIfNeeded: utf8Length))
    }

    func addSwift(connection: IPC.Connection, a: UInt32, b: UInt32, reply: consuming IPCSwiftWorkQueueTesterAddSwiftReply) {
        noteDispatch()
        reply.send(a &+ b)
    }

    func deferAddSwift(connection: IPC.Connection, a: UInt32, b: UInt32, reply: consuming IPCSwiftWorkQueueTesterDeferAddSwiftReply) {
        noteDispatch()
        deferredSum = a &+ b
        deferredReply = consume reply
    }

    // Sends the deferred reply, or drops it, which sends the default reply.
    func completeDeferredAddSwift(connection: IPC.Connection, send: Bool) {
        noteDispatch()
        guard let reply = deferredReply.take() else {
            return
        }
        if send {
            reply.send(deferredSum)
        }
    }

    func halveEvenNumberSwift(
        connection: IPC.Connection,
        value: UInt32,
        reply: consuming IPCSwiftWorkQueueTesterHalveEvenNumberSwiftReply
    ) throws(InvalidMessage) {
        noteDispatch()
        try messageCheck("HalveEvenNumberSwift takes an even number") {
            value.isMultiple(of: 2)
        }
        reply.send(value / 2)
    }

    func digestBytesSwift(connection: IPC.Connection, bytes: [UInt8]) -> (count: UInt32, digest: UInt32) {
        noteDispatch()
        let digest = bytes.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
        return (UInt32(truncatingIfNeeded: bytes.count), digest)
    }

    func describeLogLevelSwift(
        connection: IPC.Connection,
        level: IPCTypes.WTFLogLevel,
        count: UInt32
    ) -> (levelValue: UInt32, count: UInt32) {
        noteDispatch()
        return (UInt32(level.rawValue), count)
    }

    // Sends Record and RecordTextSwift back to the process that sent this, to the tester there with that identifier.
    func sendRecordBackSwift(connection: IPC.Connection, testerIdentifier: UInt64, value: UInt32, text: String?) {
        noteDispatch()
        Self.IPCSwiftWorkQueueTesterMessages.record(on: connection, to: testerIdentifier, value: value)
        Self.IPCSwiftWorkQueueTesterMessages.recordTextSwift(on: connection, to: testerIdentifier, text: text)
    }

    #if WTF_PLATFORM_COCOA
    // Sends the semaphore back, in a SignalSemaphoreSwift message.
    func sendSemaphoreBackSwift(connection: IPC.Connection, testerIdentifier: UInt64, semaphore: consuming IPCTypes.Semaphore) {
        noteDispatch()
        Self.IPCSwiftWorkQueueTesterMessages.signalSemaphoreSwift(on: connection, to: testerIdentifier, semaphore: semaphore)
    }

    // A [Swift] struct that holds an owned type is ~Copyable, so the handler borrows it.
    func describeRingBufferSwift(
        connection: IPC.Connection,
        handle: borrowing IPCTypes.ConsumerSharedCARingBufferHandle
    ) -> (frameCount: UInt64, memorySize: UInt64) {
        noteDispatch()
        return (handle.frameCount, handle.memory.size)
    }

    func signalSemaphoreSwift(connection: IPC.Connection, semaphore: consuming IPCTypes.Semaphore) {
        noteDispatch()
        semaphore.signal()
    }

    func echoSemaphoreSwift(connection: IPC.Connection, semaphore: consuming IPCTypes.Semaphore) -> IPCTypes.Semaphore {
        noteDispatch()
        return semaphore
    }

    func sharedMemorySizeSwift(connection: IPC.Connection, handle: borrowing IPCTypes.SharedMemoryHandle) -> UInt64 {
        noteDispatch()
        return handle.size
    }

    func echoSharedMemorySwift(
        connection: IPC.Connection,
        handle: consuming IPCTypes.SharedMemoryHandle?,
        reply: consuming IPCSwiftWorkQueueTesterEchoSharedMemorySwiftReply
    ) {
        noteDispatch()
        reply.send(handle)
    }

    func countSendRightsSwift(connection: IPC.Connection, rights: borrowing IPCTypes.MachSendRightVector) -> UInt64 {
        noteDispatch()
        return UInt64(rights.count)
    }
    #endif

    #if ENABLE_GPU_PROCESS && WTF_PLATFORM_COCOA && ENABLE_VIDEO
    // The fields of a video frame's Swift form, for a test to compare with the ones it sent.
    func describeSharedVideoFrameSwift(
        connection: IPC.Connection,
        frame: borrowing IPCTypes.SharedVideoFrame
    ) -> (timeValue: Int64, timeScale: UInt32, flags: UInt32, rotation: UInt16, colorSpace: UInt32, bufferKind: UInt8, bufferValue: UInt64) {
        noteDispatch()
        let flags = (frame.mirrored ? 1 : 0) | (frame.shouldIgnoreAlpha ? 2 : 0) | describeFullRange(frame.colorSpace) | UInt32(frame.time.timeFlags) << 8
        let (bufferKind, bufferValue): (UInt8, UInt64) =
            switch frame.buffer {
            case .null: (0, 0)
            case .remoteVideoFrameReadReference(let read): (1, read.reference.identifier.rawValue &+ read.reference.version << 48)
            case .machSendRight(let right): (2, right.isNull ? 0 : 1)
            case .intSize(let size): (3, UInt64(UInt32(bitPattern: size.width)) << 32 | UInt64(UInt32(bitPattern: size.height)))
            }
        return (frame.time.timeValue, frame.time.timeScale, flags, frame.rotation.rawValue, describe(frame.colorSpace), bufferKind, bufferValue)
    }

    func echoSharedVideoFrameSwift(
        connection: IPC.Connection,
        frame: consuming IPCTypes.SharedVideoFrame,
        reply: consuming IPCSwiftWorkQueueTesterEchoSharedVideoFrameSwiftReply
    ) {
        noteDispatch()
        reply.send(frame)
    }

    func describeVideoFramePropertiesSwift(
        connection: IPC.Connection,
        properties: IPCTypes.RemoteVideoFrameProxyProperties
    ) -> (timeValue: Int64, flags: UInt32, rotation: UInt16, width: Int32, height: Int32, pixelFormat: UInt32, colorSpace: UInt32) {
        noteDispatch()
        let flags = (properties.isMirrored ? 1 : 0) | (properties.shouldIgnoreAlpha ? 2 : 0) | describeFullRange(properties.colorSpace)
        return (
            properties.presentationTime.timeValue, flags, properties.rotation.rawValue, properties.size.width, properties.size.height,
            properties.pixelFormat, describe(properties.colorSpace)
        )
    }

    func echoVideoFramePropertiesSwift(
        connection: IPC.Connection,
        properties: IPCTypes.RemoteVideoFrameProxyProperties,
        marker: UInt64,
        reply: consuming IPCSwiftWorkQueueTesterEchoVideoFramePropertiesSwiftReply
    ) {
        noteDispatch()
        reply.send((properties: properties, marker: marker))
    }

    func describeVideoFrameWriteReferenceSwift(
        connection: IPC.Connection,
        write: IPCTypes.RemoteVideoFrameWriteReference
    ) -> (identifier: UInt64, version: UInt64, pendingReads: UInt64) {
        noteDispatch()
        return (write.reference.identifier.rawValue, write.reference.version, write.pendingReads)
    }

    // 4 if the color space says whether it is full range, and 8 more if it is.
    private func describeFullRange(_ colorSpace: IPCTypes.PlatformVideoColorSpace) -> UInt32 {
        colorSpace.fullRange.map { $0 ? 12 : 4 } ?? 0
    }

    // A byte per member, from the most significant: primaries, transfer, matrix, chroma location; 0xFF for none.
    private func describe(_ colorSpace: IPCTypes.PlatformVideoColorSpace) -> UInt32 {
        let primaries = UInt32(colorSpace.primaries?.rawValue ?? 0xFF)
        let transfer = UInt32(colorSpace.transfer?.rawValue ?? 0xFF)
        let matrix = UInt32(colorSpace.matrix?.rawValue ?? 0xFF)
        let chromaLocation = UInt32(colorSpace.chromaLocation?.rawValue ?? 0xFF)
        return primaries << 24 | transfer << 16 | matrix << 8 | chromaLocation
    }
    #endif

    // The handlers of IPCTester::benchmarkWorkQueueDispatch(), which IPCWorkQueueTester's C++ ones match.

    func benchEmpty(connection: IPC.Connection) {
    }

    func benchFourValues(connection: IPC.Connection, a: UInt32, b: UInt32, c: UInt32, d: UInt32) {
        benchSink &+= UInt64(a &+ b &+ c &+ d)
    }

    func benchString(connection: IPC.Connection, text: WTF.String) {
        benchSink &+= UInt64(text.length())
    }

    func benchReply(connection: IPC.Connection, value: UInt64) -> UInt64 {
        value
    }

    func benchEmptySwift(connection: IPC.Connection) {
    }

    func benchFourValuesSwift(connection: IPC.Connection, a: UInt32, b: UInt32, c: UInt32, d: UInt32) {
        benchSink &+= UInt64(a &+ b &+ c &+ d)
    }

    func benchStringSwift(connection: IPC.Connection, text: String?) {
        benchSink &+= UInt64(text?.utf8.count ?? 0)
    }

    func benchVectorSwift(connection: IPC.Connection, values: [UInt32]) {
        benchSink &+= UInt64(values.count)
    }

    func benchReplySwift(connection: IPC.Connection, value: UInt64, reply: consuming IPCSwiftWorkQueueTesterBenchReplySwiftReply) {
        reply.send(value)
    }
}

#endif
