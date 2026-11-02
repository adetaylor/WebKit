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

// Safety: target is only written in init, dispatch asserts the stream connection's work queue, and weak loads are atomic in the Swift runtime
@_expose(Cxx)
final class TestWithStreamSwiftTypesWeakRef: @unchecked Sendable {
    private weak var target: TestWithStreamSwiftTypes?
    init(target: TestWithStreamSwiftTypes) {
        self.target = target
    }

    @used
    func getMessageTarget() -> TestWithStreamSwiftTypes? {
        target
    }

    @used
    func dispatchSendString(
        connection: sending IPC.StreamServerConnection,
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        assert(connection.isCurrentWorkQueue())
        let url: String?
        do {
            url = try IPCCoding.WTFString.decode(from: &decoder)
        } catch {
            return false
        }
        guard let target else {
            return true
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
    func dispatchSendValues(
        connection: sending IPC.StreamServerConnection,
        decoder: inout IPC.SwiftDecoder
    ) -> Bool {
        assert(connection.isCurrentWorkQueue())
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
        guard let target else {
            return true
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.sendValues(
                    connection: connection,
                    value: value,
                    optionalValue: optionalValue,
                    bytes: bytes
                )
            )
        } catch {
            markMessageInvalid(error, on: connection)
        }
        return true
    }

    @used
    func dispatchSendCxxString(
        connection: sending IPC.StreamServerConnection,
        url: sending WTF.String
    ) {
        assert(connection.isCurrentWorkQueue())
        guard let target else {
            return
        }
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
