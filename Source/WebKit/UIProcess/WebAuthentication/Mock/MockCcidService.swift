// Copyright (C) 2022 Apple Inc. All rights reserved.
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

#if ENABLE_WEB_AUTHN

import CryptoTokenKit
import Foundation
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

@objc
@implementation
extension _WKMockTKSmartCard {
    @nonobjc
    private let service: WebKit.WeakPtrMockCcidService

    init(service: WebKit.MockCcidService) {
        self.service = .init(service, .Yes)
        super.init()
    }

    override func beginSession(reply: @escaping (Bool, (any Error)?) -> Void) {
        reply(true, nil)
    }

    override func endSession() {
    }

    override func transmit(_ request: Data, reply: @escaping (Data?, (any Error)?) -> Void) {
        guard let service = service.get() else {
            preconditionFailure("A smart card without its service")
        }
        reply(service.nextReply(request), nil)
    }
}

extension WebKit.MockCcidService {
    fileprivate func nextReply(_ request: Data) -> Data? {
        guard var ccid = m_configuration.ccid.value else {
            preconditionFailure("A smart card service without a smart card configuration")
        }
        // Command-aware replies let a test model a legacy U2F-only key: the applet selection command can be
        // answered with a non-match, forcing the connection to fall back to the U2F_VERSION command.
        let requestBytes = [UInt8](request)
        if !ccid.appletSelectionResponseBase64.isEmpty()
            && requestBytes == Array(fido.kCtapNfcAppletSelectionCommand)
        {
            return data(fromBase64: ccid.appletSelectionResponseBase64)
        }
        if !ccid.u2fVersionResponseBase64.isEmpty() && requestBytes == Array(fido.kCtapNfcU2fVersionCommand) {
            return data(fromBase64: ccid.u2fVersionResponseBase64)
        }

        if ccid.payloadBase64.isEmpty() {
            return nil
        }

        let result = data(fromBase64: ccid.payloadBase64[0])
        ccid.payloadBase64.removeAt(0)
        m_configuration.ccid = .init(ccid)
        return result
    }
}

private func data(fromBase64 base64String: borrowing WTF.String) -> Data? {
    if base64String.isEmpty() {
        return nil
    }
    return NSData(base64Encoded: makeSwiftString(base64String), options: .ignoreUnknownCharacters) as Data?
}

#endif // ENABLE_WEB_AUTHN
