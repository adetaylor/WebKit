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
final class TestWithSwiftWorkQueueWeakRef {
    private let target: TestWithSwiftWorkQueue
    init(target: TestWithSwiftWorkQueue) {
        self.target = target
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        target.sharedPreferencesForWebProcess()
    }

    @used
    func dispatchSendString(
        connection: IPC.Connection,
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
                    connection: connection,
                    url: url
                )
            )
        } catch {
            markMessageInvalid(error, on: connection)
        }
        return true
    }

    @used
    func dispatchSendStringSync(
        connection: IPC.Connection,
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
                    connection: connection,
                    url: url
                )
            )
            IPCCoding.WTFString.encode(reply.0, to: replyEncoder)
            UInt64.encode(reply.1, to: replyEncoder)
            replyEncoder.send()
        } catch {
            markMessageInvalid(error, on: connection)
            replyEncoder.cancel()
        }
        return true
    }

    @used
    func dispatchSendStringAsync(
        connection: IPC.Connection,
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
                    connection: connection,
                    url: url,
                    reply: TestWithSwiftWorkQueueSendStringAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: connection)
        }
        return true
    }

    @used
    func dispatchSendEmptyAsync(
        connection: IPC.Connection,
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendEmptyAsync(
                    connection: connection,
                    reply: TestWithSwiftWorkQueueSendEmptyAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: connection)
        }
        return true
    }

    @used
    func dispatchSendCxxDecoded(
        connection: IPC.Connection,
        decoder: inout IPC.SwiftDecoder,
        replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        let value: UInt32
        let handle: CxxDecodedArguments.TestWithSwiftWorkQueue.SendCxxDecodedHandle
        do {
            value = try UInt32.decode(from: &decoder)
            guard let decodedHandle = CxxDecodedArguments.TestWithSwiftWorkQueue.SendCxxDecodedHandle.decode(&decoder) else {
                return false
            }
            handle = decodedHandle
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendCxxDecoded(
                    connection: connection,
                    value: value,
                    handle: handle,
                    reply: TestWithSwiftWorkQueueSendCxxDecodedReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: connection)
        }
        return true
    }

    @used
    func dispatchSendCxxString(
        connection: IPC.Connection,
        url: sending WTF.String
    ) {
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
    func dispatchSendCxxStringSync(
        connection: IPC.Connection,
        url: sending WTF.String,
        completionHandler: sending CompletionHandlers.TestWithSwiftWorkQueue.SendCxxStringSyncCompletionHandler
    ) {
        do throws(InvalidMessage) {
            let reply = try mayThrowInvalidMessage(
                target.sendCxxStringSync(
                    connection: connection,
                    url: url
                )
            )
            CompletionHandlers.TestWithSwiftWorkQueue.complete(completionHandler, reply)
        } catch {
            markMessageInvalid(error, on: connection)
            CompletionHandlers.TestWithSwiftWorkQueue.completeWithDefaultReply(completionHandler)
        }
    }

    @used
    func dispatchSendCxxStringAsync(
        connection: IPC.Connection,
        url: sending WTF.String,
        completionHandler: sending CompletionHandlers.TestWithSwiftWorkQueue.SendCxxStringAsyncCompletionHandler
    ) {
        do throws(InvalidMessage) {
            let reply = try mayThrowInvalidMessage(
                target.sendCxxStringAsync(
                    connection: connection,
                    url: url
                )
            )
            CompletionHandlers.TestWithSwiftWorkQueue.complete(completionHandler, reply)
        } catch {
            markMessageInvalid(error, on: connection)
            CompletionHandlers.TestWithSwiftWorkQueue.completeWithDefaultReply(completionHandler)
        }
    }
}

struct TestWithSwiftWorkQueueSendStringAsyncReply: ~Copyable {
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

struct TestWithSwiftWorkQueueSendEmptyAsyncReply: ~Copyable {
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

struct TestWithSwiftWorkQueueSendCxxDecodedReply: ~Copyable {
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

extension WebKit.TestWithSwiftWorkQueueMessageForwarder {
    static func create(target: TestWithSwiftWorkQueue) -> RefTestWithSwiftWorkQueueMessageForwarder {
        let weakRefContainer = TestWithSwiftWorkQueueWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithSwiftWorkQueueMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}
