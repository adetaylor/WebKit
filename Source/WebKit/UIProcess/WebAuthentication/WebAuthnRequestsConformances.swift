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

import WebCore_Private
import WebKit_Internal
import wtf

// The CxxCompletionHandler conformances the WebAuthn request handlers share; each type may conform only once. Not
// @unsafe, as WebPageProxy.swift's are not: that would make each .init an unsafe expression.

// AuthenticatorManager::handleRequest's callback (handleRequest and the panel).
extension WebKit.WebAuthnRespondHandler: CxxCompletionHandler {
    typealias Argument = WebKit.AuthenticatorManager.Respond
}

// The embedder's consent to a conditional registration.
extension WebKit.WebAuthnOptionalBoolCompletionHandler: CxxCompletionHandler {
    typealias Argument = WebCore.OptionalBool
}

// runWebAuthenticationPanel's result.
extension WebKit.WebAuthnPanelResultCompletionHandler: CxxCompletionHandler {
    typealias Argument = WebKit.WebAuthenticationPanelResult
}

// The CCID and NFC connections' once-called data callbacks.
extension WebKit.DataReceivedCallback: CxxCompletionHandler {
    typealias Argument = WTF.VectorUInt8
}

// LocalConnection::verifyUser's handler for the platform authenticator's credential creation
// (LocalAuthenticator.swift).
extension WebKit.LocalUserVerificationHandler: CxxCompletionHandler {
    typealias Argument = WebKit.LocalConnection.UserVerification
}

#endif // ENABLE_WEB_AUTHN
