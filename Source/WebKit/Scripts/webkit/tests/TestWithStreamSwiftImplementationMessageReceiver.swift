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
        _ receiver: WebKit.TestWithStreamSwiftImplementation,
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
                receiver.sendString(
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
        _ receiver: WebKit.TestWithStreamSwiftImplementation,
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
                receiver.sendValues(
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
        _ receiver: WebKit.TestWithStreamSwiftImplementation,
        _ decoder: IPC.SwiftDecoder
    ) -> Bool {
        var decoder = decoder
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                receiver.sendEmpty()
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
        _ receiver: WebKit.TestWithStreamSwiftImplementation,
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
                receiver.sendCocoaValue(
                    value: value
                )
            )
        } catch {
            markMessageInvalid(error, on: &decoder)
        }
        return true
    }
    #endif
}
