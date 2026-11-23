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

// Safety: target is only written in init, assumeIsolated asserts the main thread, and weak loads are atomic in the Swift runtime
@_expose(Cxx)
final class TestWithSwiftUntrustedWeakRef: @unchecked Sendable {
    private weak var target: TestWithSwiftUntrustedTarget?
    @_expose(!Cxx)
    init(target: TestWithSwiftUntrustedTarget) {
        self.target = target
    }

    @used
    func hasMessageTarget() -> Bool {
        target != nil
    }

    @used
    func messageTarget() -> TestWithSwiftUntrustedTarget {
        guard let target else {
            fatalError("messageTarget() called without a message target")
        }
        return target
    }

    @used
    func dispatchUntrustedOrigin(
        connection: sending IPC.Connection,
        origin: sending WebCore.UntrustedSecurityOriginData,
        completionHandler: sending CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginCompletionHandler
    ) {
        MainActor.assumeIsolated {
            guard let target else {
                return
            }
            Task.immediateOnMainActor {
                await UntrustedOriginInvocation(
                    target: target,
                    connection: connection,
                    origin: origin,
                    completionHandler: completionHandler
                )
                .run()
            }
        }
    }

    private final class UntrustedOriginInvocation {
        private let target: TestWithSwiftUntrustedTarget
        private let connection: IPC.Connection
        private let origin: WebCore.UntrustedSecurityOriginData
        private let completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginCompletionHandler

        init(
            target: TestWithSwiftUntrustedTarget,
            connection: IPC.Connection,
            origin: WebCore.UntrustedSecurityOriginData,
            completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginCompletionHandler
        ) {
            self.target = target
            self.connection = connection
            self.origin = origin
            self.completionHandler = completionHandler
        }

        @MainActor
        func run() async {
            do {
                let reply = try await mayThrowInvalidMessage(
                    target.untrustedOrigin(
                        connection: connection,
                        origin: origin
                    )
                )
                CompletionHandlers.TestWithSwiftUntrusted.complete(completionHandler, reply)
            } catch {
                markMessageInvalid(error, on: connection)
                if let reply = error.reply(as: Bool.self) {
                    CompletionHandlers.TestWithSwiftUntrusted.complete(completionHandler, reply)
                } else {
                    CompletionHandlers.TestWithSwiftUntrusted.completeWithDefaultReply(completionHandler)
                }
            }
        }
    }

    @used
    func dispatchUntrustedOptionalOrigin(
        connection: sending IPC.Connection,
        frameID: sending WebCore.FrameIdentifier,
        parentOrigin: sending WebCore.UntrustedOptionalSecurityOriginData,
        completionHandler: sending CompletionHandlers.TestWithSwiftUntrusted.UntrustedOptionalOriginCompletionHandler
    ) {
        MainActor.assumeIsolated {
            guard let target else {
                return
            }
            Task.immediateOnMainActor {
                await UntrustedOptionalOriginInvocation(
                    target: target,
                    connection: connection,
                    frameID: frameID,
                    parentOrigin: parentOrigin,
                    completionHandler: completionHandler
                )
                .run()
            }
        }
    }

    private final class UntrustedOptionalOriginInvocation {
        private let target: TestWithSwiftUntrustedTarget
        private let connection: IPC.Connection
        private let frameID: WebCore.FrameIdentifier
        private let parentOrigin: WebCore.UntrustedOptionalSecurityOriginData
        private let completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOptionalOriginCompletionHandler

        init(
            target: TestWithSwiftUntrustedTarget,
            connection: IPC.Connection,
            frameID: WebCore.FrameIdentifier,
            parentOrigin: WebCore.UntrustedOptionalSecurityOriginData,
            completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOptionalOriginCompletionHandler
        ) {
            self.target = target
            self.connection = connection
            self.frameID = frameID
            self.parentOrigin = parentOrigin
            self.completionHandler = completionHandler
        }

        @MainActor
        func run() async {
            do {
                let reply = try await mayThrowInvalidMessage(
                    target.untrustedOptionalOrigin(
                        connection: connection,
                        frameID: frameID,
                        parentOrigin: parentOrigin
                    )
                )
                completionHandler.pointee(consuming: reply)
            } catch {
                markMessageInvalid(error, on: connection)
                if let reply = error.reply(as: WebCore.ExceptionData.self) {
                    completionHandler.pointee(consuming: reply)
                } else {
                    CompletionHandlers.TestWithSwiftUntrusted.completeWithDefaultReply(completionHandler)
                }
            }
        }
    }

    @used
    func dispatchUntrustedOriginWithoutReply(
        connection: sending IPC.Connection,
        origin: sending WebCore.UntrustedSecurityOriginData
    ) {
        MainActor.assumeIsolated {
            guard let target else {
                return
            }
            Task.immediateOnMainActor {
                await UntrustedOriginWithoutReplyInvocation(
                    target: target,
                    connection: connection,
                    origin: origin
                )
                .run()
            }
        }
    }

    private final class UntrustedOriginWithoutReplyInvocation {
        private let target: TestWithSwiftUntrustedTarget
        private let connection: IPC.Connection
        private let origin: WebCore.UntrustedSecurityOriginData

        init(
            target: TestWithSwiftUntrustedTarget,
            connection: IPC.Connection,
            origin: WebCore.UntrustedSecurityOriginData
        ) {
            self.target = target
            self.connection = connection
            self.origin = origin
        }

        @MainActor
        func run() async {
            do {
                try await mayThrowInvalidMessage(
                    target.untrustedOriginWithoutReply(
                        connection: connection,
                        origin: origin
                    )
                )
            } catch {
                markMessageInvalid(error, on: connection)
            }
        }
    }

    @used
    func dispatchUntrustedOriginWithReplies(
        connection: sending IPC.Connection,
        origin: sending WebCore.UntrustedSecurityOriginData,
        completionHandler: sending CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginWithRepliesCompletionHandler
    ) {
        MainActor.assumeIsolated {
            guard let target else {
                return
            }
            Task.immediateOnMainActor {
                await UntrustedOriginWithRepliesInvocation(
                    target: target,
                    connection: connection,
                    origin: origin,
                    completionHandler: completionHandler
                )
                .run()
            }
        }
    }

    private final class UntrustedOriginWithRepliesInvocation {
        private let target: TestWithSwiftUntrustedTarget
        private let connection: IPC.Connection
        private let origin: WebCore.UntrustedSecurityOriginData
        private let completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginWithRepliesCompletionHandler

        init(
            target: TestWithSwiftUntrustedTarget,
            connection: IPC.Connection,
            origin: WebCore.UntrustedSecurityOriginData,
            completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginWithRepliesCompletionHandler
        ) {
            self.target = target
            self.connection = connection
            self.origin = origin
            self.completionHandler = completionHandler
        }

        @MainActor
        func run() async {
            do {
                let reply = try await mayThrowInvalidMessage(
                    target.untrustedOriginWithReplies(
                        connection: connection,
                        origin: origin
                    )
                )
                CompletionHandlers.TestWithSwiftUntrusted.complete(completionHandler, consuming: reply.0, consuming: reply.1)
            } catch {
                markMessageInvalid(error, on: connection)
                if let reply = error.reply(as: (WebCore.FrameIdentifier, WebCore.ExceptionData).self) {
                    CompletionHandlers.TestWithSwiftUntrusted.complete(completionHandler, consuming: reply.0, consuming: reply.1)
                } else {
                    CompletionHandlers.TestWithSwiftUntrusted.completeWithDefaultReply(completionHandler)
                }
            }
        }
    }

    @used
    func dispatchUntrustedOriginWithUnnamedReply(
        connection: sending IPC.Connection,
        origin: sending WebCore.UntrustedSecurityOriginData,
        completionHandler: sending CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginWithUnnamedReplyCompletionHandler
    ) {
        MainActor.assumeIsolated {
            guard let target else {
                return
            }
            Task.immediateOnMainActor {
                await UntrustedOriginWithUnnamedReplyInvocation(
                    target: target,
                    connection: connection,
                    origin: origin,
                    completionHandler: completionHandler
                )
                .run()
            }
        }
    }

    private final class UntrustedOriginWithUnnamedReplyInvocation {
        private let target: TestWithSwiftUntrustedTarget
        private let connection: IPC.Connection
        private let origin: WebCore.UntrustedSecurityOriginData
        private let completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginWithUnnamedReplyCompletionHandler

        init(
            target: TestWithSwiftUntrustedTarget,
            connection: IPC.Connection,
            origin: WebCore.UntrustedSecurityOriginData,
            completionHandler: CompletionHandlers.TestWithSwiftUntrusted.UntrustedOriginWithUnnamedReplyCompletionHandler
        ) {
            self.target = target
            self.connection = connection
            self.origin = origin
            self.completionHandler = completionHandler
        }

        @MainActor
        func run() async {
            do {
                let reply = try await mayThrowInvalidMessage(
                    target.untrustedOriginWithUnnamedReply(
                        connection: connection,
                        origin: origin
                    )
                )
                completionHandler.pointee(consuming: reply)
            } catch {
                markMessageInvalid(error, on: connection)
                CompletionHandlers.TestWithSwiftUntrusted.completeWithDefaultReply(completionHandler)
            }
        }
    }
}

extension WebKit.TestWithSwiftUntrustedMessageForwarder {
    static func create(target: TestWithSwiftUntrustedTarget) -> RefTestWithSwiftUntrustedMessageForwarder {
        let weakRefContainer = TestWithSwiftUntrustedWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithSwiftUntrustedMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}
