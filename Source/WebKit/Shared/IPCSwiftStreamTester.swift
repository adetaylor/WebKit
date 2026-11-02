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

// Receives the IPCSwiftStreamTester messages sent over an IPCStreamTester's stream connection. Like any
// stream receiver, it is confined to the connection's work queue.
@_expose(Cxx)
final class IPCSwiftStreamTester {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefIPCSwiftStreamTesterMessageForwarder?

    private var recordedDigest: UInt32 = 0

    private var benchSink: UInt64 = 0

    private var deferredSum: UInt32 = 0
    private var deferredReply: IPCSwiftStreamTesterDeferAddSwiftReply?

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
        self.messageForwarder = WebKit.IPCSwiftStreamTesterMessageForwarder.create(target: self)
    }

    @used
    func getMessageReceiver() -> RefIPCSwiftStreamTesterMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    func record(connection: IPC.StreamServerConnection, value: UInt32) {
        recordedDigest = recordedDigest &* 31 &+ value
    }

    func takeRecordedDigest(connection: IPC.StreamServerConnection) -> UInt32 {
        defer {
            recordedDigest = 0
        }
        return recordedDigest
    }

    func add(connection: IPC.StreamServerConnection, a: UInt32, b: UInt32) -> UInt32 {
        a &+ b
    }

    func repeatTextSwift(connection: IPC.StreamServerConnection, text: String?, count: UInt32) throws(InvalidMessage) -> String? {
        try messageCheck("RepeatTextSwift repeats at most 4096 times") {
            count <= 4096
        }
        guard let text else {
            return nil
        }
        return String(repeating: text, count: Int(count))
    }

    func addSwift(connection: IPC.StreamServerConnection, a: UInt32, b: UInt32, reply: consuming IPCSwiftStreamTesterAddSwiftReply) {
        reply.send(a &+ b)
    }

    func deferAddSwift(connection: IPC.StreamServerConnection, a: UInt32, b: UInt32, reply: consuming IPCSwiftStreamTesterDeferAddSwiftReply) {
        deferredSum = a &+ b
        deferredReply = consume reply
    }

    // Sends the deferred reply, or drops it, which sends the default reply.
    func completeDeferredAddSwift(connection: IPC.StreamServerConnection, send: Bool) {
        guard let reply = deferredReply.take() else {
            return
        }
        if send {
            reply.send(deferredSum)
        }
    }

    // The handlers of IPCTester::benchmarkStreamDispatch(), which IPCStreamTester's C++ ones match.

    func benchFourValues(connection: IPC.StreamServerConnection, a: UInt32, b: UInt32, c: UInt32, d: UInt32) {
        benchSink &+= UInt64(a &+ b &+ c &+ d)
    }

    func benchEmptySwift(connection: IPC.StreamServerConnection) {
    }

    func benchFourValuesSwift(connection: IPC.StreamServerConnection, a: UInt32, b: UInt32, c: UInt32, d: UInt32) {
        benchSink &+= UInt64(a &+ b &+ c &+ d)
    }

    func benchStringSwift(connection: IPC.StreamServerConnection, text: String?) {
        benchSink &+= UInt64(text?.utf8.count ?? 0)
    }

    func benchVectorSwift(connection: IPC.StreamServerConnection, values: [UInt32]) {
        benchSink &+= UInt64(values.count)
    }

    func benchSyncSwift(connection: IPC.StreamServerConnection, value: UInt64) -> UInt64 {
        value
    }

    func benchEnabledFourValuesSwift(connection: IPC.StreamServerConnection, a: UInt32, b: UInt32, c: UInt32, d: UInt32) {
        benchSink &+= UInt64(a &+ b &+ c &+ d)
    }

    // A message with EnabledBy makes dispatch check these, as WebGPU's receivers check theirs.
    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        WebKit.ipcTesterSharedPreferences()
    }

    func takeRecordedDigestSwift(connection: IPC.StreamServerConnection) -> UInt32 {
        takeRecordedDigest(connection: connection)
    }

    // Records the UTF-8 form of the text, then a terminating 0, so a null string records only the 0.
    func recordTextSwift(connection: IPC.StreamServerConnection, text: String?) {
        for byte in text?.utf8 ?? "".utf8 {
            recordedDigest = recordedDigest &* 31 &+ UInt32(byte)
        }
        recordedDigest = recordedDigest &* 31
    }
}

#endif
