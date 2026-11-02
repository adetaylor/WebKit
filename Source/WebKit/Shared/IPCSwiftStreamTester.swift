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

    // Records the UTF-8 form of the text, then a terminating 0, so a null string records only the 0.
    func recordTextSwift(connection: IPC.StreamServerConnection, text: String?) {
        for byte in text?.utf8 ?? "".utf8 {
            recordedDigest = recordedDigest &* 31 &+ UInt32(byte)
        }
        recordedDigest = recordedDigest &* 31
    }
}

#endif
