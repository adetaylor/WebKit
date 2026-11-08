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

extension SwiftDispatch.TestWithSwiftImplementation {

    @cxx
    @implementation
    static func dispatchSendString(
        _ target: WebKit.TestWithSwiftImplementation,
        _ connection: sending IPC.Connection,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
        let url: String?
        do {
            url = try IPCCoding.WTFString.decode(from: &decoder)
        } catch {
            return false
        }
        MainActor.assumeIsolated {
            Task.immediateOnMainActor {
                await SendStringInvocation(
                    target: target,
                    connection: connection,
                    url: url
                )
                .run()
            }
        }
        return true
    }

    private final class SendStringInvocation {
        private let target: WebKit.TestWithSwiftImplementation
        private let connection: IPC.Connection
        private let url: String?

        init(
            target: WebKit.TestWithSwiftImplementation,
            connection: IPC.Connection,
            url: String?
        ) {
            self.target = target
            self.connection = connection
            self.url = url
        }

        @MainActor
        func run() async {
            do {
                try await mayThrowInvalidMessage(
                    target.sendString(
                        connection: connection,
                        url: url
                    )
                )
            } catch {
                markMessageInvalid(error, on: connection)
            }
        }
    }

    @cxx
    @implementation
    static func dispatchSendStringAsync(
        _ target: WebKit.TestWithSwiftImplementation,
        _ connection: sending IPC.Connection,
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
        MainActor.assumeIsolated {
            Task.immediateOnMainActor {
                await SendStringAsyncInvocation(
                    target: target,
                    connection: connection,
                    url: url,
                    replyEncoder: replyEncoder
                )
                .run()
            }
        }
        return true
    }

    private final class SendStringAsyncInvocation {
        private let target: WebKit.TestWithSwiftImplementation
        private let connection: IPC.Connection
        private let url: String?
        private let replyEncoder: IPC.SwiftReplyEncoder

        init(
            target: WebKit.TestWithSwiftImplementation,
            connection: IPC.Connection,
            url: String?,
            replyEncoder: IPC.SwiftReplyEncoder
        ) {
            self.target = target
            self.connection = connection
            self.url = url
            self.replyEncoder = replyEncoder
        }

        @MainActor
        func run() async {
            do {
                let reply = try await mayThrowInvalidMessage(
                    target.sendStringAsync(
                        connection: connection,
                        url: url
                    )
                )
                IPCCoding.WTFString.encode(reply, to: replyEncoder)
                replyEncoder.send()
            } catch {
                markMessageInvalid(error, on: connection)
                replyEncoder.cancel()
            }
        }
    }

    @cxx
    @implementation
    static func dispatchSendStringSync(
        _ target: WebKit.TestWithSwiftImplementation,
        _ connection: sending IPC.Connection,
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
        MainActor.assumeIsolated {
            Task.immediateOnMainActor {
                await SendStringSyncInvocation(
                    target: target,
                    connection: connection,
                    url: url,
                    replyEncoder: replyEncoder
                )
                .run()
            }
        }
        return true
    }

    private final class SendStringSyncInvocation {
        private let target: WebKit.TestWithSwiftImplementation
        private let connection: IPC.Connection
        private let url: String?
        private let replyEncoder: IPC.SwiftReplyEncoder

        init(
            target: WebKit.TestWithSwiftImplementation,
            connection: IPC.Connection,
            url: String?,
            replyEncoder: IPC.SwiftReplyEncoder
        ) {
            self.target = target
            self.connection = connection
            self.url = url
            self.replyEncoder = replyEncoder
        }

        @MainActor
        func run() async {
            do {
                let reply = try await mayThrowInvalidMessage(
                    target.sendStringSync(
                        connection: connection,
                        url: url
                    )
                )
                UInt64.encode(reply, to: replyEncoder)
                replyEncoder.send()
            } catch {
                markMessageInvalid(error, on: connection)
                replyEncoder.cancel()
            }
        }
    }

    @cxx
    @implementation
    static func dispatchSendDirect(
        _ target: WebKit.TestWithSwiftImplementation,
        _ connection: sending IPC.Connection,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
        let value: UInt32
        do {
            value = try UInt32.decode(from: &decoder)
        } catch {
            return false
        }
        MainActor.assumeIsolated {
            do throws(InvalidMessage) {
                try mayThrowInvalidMessage(
                    target.sendDirect(
                        connection: connection,
                        value: value
                    )
                )
            } catch {
                markMessageInvalid(error, on: connection)
            }
        }
        return true
    }
}
