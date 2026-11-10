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

extension SwiftDispatch.TestWithStreamSwiftState {
    @cxx
    @implementation
    static func dispatchSendToReceiver(
        _ target: WebKit.TestWithStreamSwiftState,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
        let value: UInt32
        do {
            value = try UInt32.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendToReceiver(
                    value: value
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }
}

// The dispatch of the receiver's messages that go to its Swift state, the target, which the receiver's generated C++
// keeps until the receiver goes, and calls with each of them on the queue it dispatches them on.
@_expose(Cxx)
final class TestWithStreamSwiftStateStateDispatch {
    private let target: TestWithStreamSwiftStateState

    private init(target: TestWithStreamSwiftStateState) {
        self.target = target
    }

    @used
    static func create(_ receiver: WebKit.TestWithStreamSwiftState) -> TestWithStreamSwiftStateStateDispatch {
        TestWithStreamSwiftStateStateDispatch(target: receiver.state)
    }

    @used
    func dispatchSendValues(
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        let value: UInt32
        let optionalValue: UInt64?
        do {
            value = try UInt32.decode(from: &decoder)
            optionalValue = try IPCCoding.StdOptional<UInt64>.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendValues(
                    value: value,
                    optionalValue: optionalValue
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @used
    func dispatchSendWithConnection(
        connection: IPC.StreamServerConnection,
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        let value: UInt32
        do {
            value = try UInt32.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendWithConnection(
                    connection: connection,
                    value: value
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
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
    func dispatchSendLaterSync(
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
                target.sendLaterSync(
                    value: value,
                    reply: TestWithStreamSwiftStateSendLaterSyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
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
                    reply: TestWithStreamSwiftStateSendStringAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }
}

struct TestWithStreamSwiftStateSendLaterSyncReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    consuming func send(_ reply: (first: Double, second: Double)) {
        Double.encode(reply.0, to: replyEncoder)
        Double.encode(reply.1, to: replyEncoder)
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

struct TestWithStreamSwiftStateSendStringAsyncReply: ~Copyable {
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
