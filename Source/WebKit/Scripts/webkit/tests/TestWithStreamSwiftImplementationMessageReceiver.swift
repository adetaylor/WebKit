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

extension SwiftDispatch.TestWithStreamSwiftImplementation {

    @cxx
    @implementation
    static func dispatchSendString(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
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

    @cxx
    @implementation
    static func dispatchSendValues(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
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

    @cxx
    @implementation
    static func dispatchSendEmpty(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendEmpty()
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    #if WTF_PLATFORM_COCOA
    @cxx
    @implementation
    static func dispatchSendCocoaValue(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
        let value: UInt64
        do {
            value = try UInt64.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendCocoaValue(
                    value: value
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }
    #endif

    @cxx
    @implementation
    static func dispatchSendStringSync(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder,
        _ replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        var decoder = decoder
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

    @cxx
    @implementation
    static func dispatchSendEmptySync(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ connection: IPC.StreamServerConnection,
        _ decoder: IPC.SwiftDecoder,
        _ replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        var decoder = decoder
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

    @cxx
    @implementation
    static func dispatchSendStringAsync(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder,
        _ replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        var decoder = decoder
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
                    reply: TestWithStreamSwiftImplementationSendStringAsyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @cxx
    @implementation
    static func dispatchSendLaterSync(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder,
        _ replyEncoder: sending IPC.SwiftReplyEncoder
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
                target.sendLaterSync(
                    value: value,
                    reply: TestWithStreamSwiftImplementationSendLaterSyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @cxx
    @implementation
    static func dispatchSendCxxEncodedSync(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder,
        _ replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        var decoder = decoder
        let count: UInt32
        do {
            count = try UInt32.decode(from: &decoder)
        } catch {
            return false
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendCxxEncodedSync(
                    count: count,
                    reply: TestWithStreamSwiftImplementationSendCxxEncodedSyncReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @cxx
    @implementation
    static func dispatchSendCxxDecoded(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder,
        _ replyEncoder: sending IPC.SwiftReplyEncoder
    ) -> Bool {
        var decoder = decoder
        let value: UInt32
        let handle: CxxDecodedArguments.TestWithStreamSwiftImplementation.SendCxxDecodedHandle
        do {
            value = try UInt32.decode(from: &decoder)
            guard let decodedHandle = CxxDecodedArguments.TestWithStreamSwiftImplementation.SendCxxDecodedHandle.decode(&decoder) else {
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
                    reply: TestWithStreamSwiftImplementationSendCxxDecodedReply(replyEncoder: replyEncoder)
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }

    @cxx
    @implementation
    static func dispatchSendLentBytes(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
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

    @cxx
    @implementation
    static func dispatchSendWithConnection(
        _ target: WebKit.TestWithStreamSwiftImplementation,
        _ connection: IPC.StreamServerConnection,
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
}

struct TestWithStreamSwiftImplementationSendStringAsyncReply: ~Copyable {
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

struct TestWithStreamSwiftImplementationSendLaterSyncReply: ~Copyable {
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

struct TestWithStreamSwiftImplementationSendCxxEncodedSyncReply: ~Copyable {
    private let replyEncoder: IPC.SwiftReplyEncoder

    fileprivate init(replyEncoder: IPC.SwiftReplyEncoder) {
        self.replyEncoder = replyEncoder
    }

    // C++ encodes the reply, with the encoder it is given.
    consuming func send(encodedBy encode: (IPC.SwiftReplyEncoder) -> Void) {
        encode(replyEncoder)
        replyEncoder.send()
    }

    deinit {
        replyEncoder.cancel()
    }
}

struct TestWithStreamSwiftImplementationSendCxxDecodedReply: ~Copyable {
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
