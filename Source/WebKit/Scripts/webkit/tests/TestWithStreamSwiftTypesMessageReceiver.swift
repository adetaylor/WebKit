//
// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1.  Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import WebKit_Internal

@_expose(Cxx)
final class TestWithStreamSwiftTypesWeakRef {
    private let target: TestWithStreamSwiftTypes
    init(target: TestWithStreamSwiftTypes) {
        self.target = target
    }

    @used
    func dispatchSendString(
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        let url: String?
        do {
            url = try IPCCoding.WTFString.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendString(
                    url: url
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendValues(
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        let value: UInt32
        let optionalValue: UInt64?
        let bytes: [UInt8]
        do {
            value = try UInt32.decode(from: &decoder)
            optionalValue = try IPCCoding.StdOptional<UInt64>.decode(from: &decoder)
            bytes = try IPCCoding.Vector<UInt8>.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendValues(
                    value: value,
                    optionalValue: optionalValue,
                    bytes: bytes
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendCxxString(
        connection: IPC.StreamServerConnection,
        url: sending WTF.String
    ) {
        assert(connection.isCurrentWorkQueue())
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendCxxString(
                    connection: connection,
                    url: url
                )
            )
        } catch {
            markMessageInvalid(error, on: connection)
        }
    }

    @used
    func dispatchSendStringSync(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        let url: String?
        do {
            url = try IPCCoding.WTFString.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            let reply = try mayThrowInvalidMessage(
                target.sendStringSync(
                    url: url
                )
            )
            IPCCoding.WTFString.encode(reply.0, to: replyEncoder)
            UInt64.encode(reply.1, to: replyEncoder)
            if !replyEncoder.send() {
                IPCCoding.WTFString.encode(reply.0, to: replyEncoder)
                UInt64.encode(reply.1, to: replyEncoder)
                replyEncoder.send()
            }
        } catch {
            markMessageInvalid(error, on: &decoder)
            replyEncoder.cancel()
        }
        return true
    }

    @used
    func dispatchSendEmptySync(
        connection: IPC.StreamServerConnection,
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendEmptySync(
                    connection: connection
                )
            )
            if !replyEncoder.send() {
                replyEncoder.send()
            }
        } catch {
            markMessageInvalid(error, on: &decoder)
            replyEncoder.cancel()
        }
        return true
    }

    @used
    func dispatchSendStringAsync(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        let url: String?
        do {
            url = try IPCCoding.WTFString.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendStringAsync(
                    url: url,
                    reply: TestWithStreamSwiftTypesSendStringAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendValuesAsync(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        let value: UInt32
        do {
            value = try UInt32.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendValuesAsync(
                    value: value,
                    reply: TestWithStreamSwiftTypesSendValuesAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendEmptyAsync(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendEmptyAsync(
                    reply: TestWithStreamSwiftTypesSendEmptyAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendCxxDecoded(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        let value: UInt32
        let handle: CxxDecodedArguments.TestWithStreamSwiftTypes.SendCxxDecodedHandle
        do {
            value = try UInt32.decode(from: &decoder)
            guard let decodedHandle = CxxDecodedArguments.TestWithStreamSwiftTypes.SendCxxDecodedHandle.decode(&decoder) else {
                return false
            }
            handle = decodedHandle
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendCxxDecoded(
                    value: value,
                    handle: handle,
                    reply: TestWithStreamSwiftTypesSendCxxDecodedReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendLentBytes(
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        let value: UInt32
        var bytesPosition = IPC.LentBytesPosition()
        let tail: UInt64
        do {
            value = try UInt32.decode(from: &decoder)
            guard decoder.decodeLentBytesPosition(&bytesPosition) else {
                return false
            }
            tail = try UInt64.decode(from: &decoder)
        } catch {
            return false
        }
        let bytes = decoder.lentBytes(bytesPosition)
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendLentBytes(
                    value: value,
                    bytes: bytes,
                    tail: tail
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendLentBytesSync(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        var bytesPosition = IPC.LentBytesPosition()
        guard decoder.decodeLentBytesPosition(&bytesPosition) else {
            return false
        }
        let bytes = decoder.lentBytes(bytesPosition)
        do throws(InvalidMessage) {
            let reply = try mayThrowInvalidMessage(
                target.sendLentBytesSync(
                    bytes: bytes
                )
            )
            UInt64.encode(reply, to: replyEncoder)
            if !replyEncoder.send() {
                UInt64.encode(reply, to: replyEncoder)
                replyEncoder.send()
            }
        } catch {
            markMessageInvalid(error, on: &decoder)
            replyEncoder.cancel()
        }
        return true
    }

    @used
    func dispatchSendSemaphore(
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        let value: UInt32
        let semaphore: IPCTypes.Semaphore
        let handle: IPCTypes.SharedMemoryHandle?
        do {
            value = try UInt32.decode(from: &decoder)
        } catch {
            return false
        }
        do {
            semaphore = try IPCTypes.Semaphore.decode(from: &decoder)
        } catch {
            return false
        }
        do {
            handle = try IPCCoding.OwnedOptional<IPCTypes.SharedMemoryHandle>.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendSemaphore(
                    value: value,
                    semaphore: semaphore,
                    handle: handle
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendSendRight(
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        let right: IPCTypes.MachSendRight
        do {
            right = try IPCTypes.MachSendRight.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendSendRight(
                    right: right,
                    reply: TestWithStreamSwiftTypesSendSendRightReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }
}

struct TestWithStreamSwiftTypesSendStringAsyncReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    consuming func send(_ reply: String?) {
        IPCCoding.WTFString.encode(reply, to: replyEncoder)
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

struct TestWithStreamSwiftTypesSendValuesAsyncReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    consuming func send(_ reply: (first: UInt32, second: UInt64?)) {
        UInt32.encode(reply.0, to: replyEncoder)
        IPCCoding.StdOptional<UInt64>.encode(reply.1, to: replyEncoder)
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

struct TestWithStreamSwiftTypesSendEmptyAsyncReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    consuming func send() {
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

struct TestWithStreamSwiftTypesSendCxxDecodedReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    consuming func send(_ reply: Bool) {
        Bool.encode(reply, to: replyEncoder)
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

struct TestWithStreamSwiftTypesSendSendRightReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    consuming func send(_ reply: consuming IPCTypes.MachSendRightVector) {
        IPCTypes.MachSendRightVector.encode(reply, to: replyEncoder)
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

extension WebKit.TestWithStreamSwiftTypesMessageForwarder {
    static func create(target: TestWithStreamSwiftTypes) -> RefTestWithStreamSwiftTypesMessageForwarder {
        let weakRefContainer = TestWithStreamSwiftTypesWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithStreamSwiftTypesMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}
