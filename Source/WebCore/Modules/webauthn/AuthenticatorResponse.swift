// Copyright (C) 2019-2021 Apple Inc. All rights reserved.
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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf
internal import WebCore_Private.Core.WebAuthnSwiftTypes

extension JSC.ArrayBuffer {
    var base64URLEncodedString: WTF.String {
        fido.base64URLEncodeBytes(toVector())
    }
}

extension WebCore.AuthenticatorResponse {
    /// The fields every data() in this file starts from.
    ///
    /// data() is virtual and Swift has no qualified base call, so an override calling data() would call itself. The
    /// extension outputs are copied as stored, without the clone extensions() makes.
    fileprivate func baseResponseData() -> WebCore.AuthenticatorResponseData {
        var data = WebCore.AuthenticatorResponseData()
        data.rawId = fido.ArrayBufferPtr(rawId())
        data.extensionOutputs = fido.OptionalClientOutputs(m_extensions)
        data.clientDataJSON = fido.ArrayBufferPtr(clientDataJSON())
        return data
    }

    /// The response's fields, to send to another process or rebuild it with tryCreate().
    @cxx
    @implementation
    public func data() -> WebCore.AuthenticatorResponseData {
        baseResponseData()
    }
}

extension WebCore.AuthenticatorAttestationResponse {
    @cxx
    @implementation
    override func data() -> WebCore.AuthenticatorResponseData {
        var data = baseResponseData()
        data.isAuthenticatorAttestationResponse = true
        data.attestationObject = fido.ArrayBufferPtr(attestationObject())
        data.transports = m_transports
        return data
    }

    /// The response as PublicKeyCredential.toJSON() gives it, with each buffer base64url-encoded.
    @cxx
    @implementation
    public func toJSON() -> WebCore.RegistrationResponseJSON.AuthenticatorAttestationResponseJSON {
        var transports = fido.StringVector()
        for index in 0..<m_transports.size() {
            transports.append(consuming: webAuthnTransportString(m_transports[index]))
        }
        var value = WebCore.RegistrationResponseJSON.AuthenticatorAttestationResponseJSON()
        if let clientData = clientDataJSON() {
            value.clientDataJSON = clientData.base64URLEncodedString
        }
        value.transports = transports
        if let authData = getAuthenticatorData().get() {
            value.authenticatorData = authData.base64URLEncodedString
        }
        if let publicKey = getPublicKey().get() {
            value.publicKey = publicKey.base64URLEncodedString
        }
        value.attestationObject = attestationObject().base64URLEncodedString
        value.publicKeyAlgorithm = getPublicKeyAlgorithm()
        return value
    }
}

extension WebCore.AuthenticatorAssertionResponse {
    @cxx
    @implementation
    override func data() -> WebCore.AuthenticatorResponseData {
        var data = baseResponseData()
        data.isAuthenticatorAttestationResponse = false
        data.authenticatorData = m_authenticatorData
        data.signature = m_signature
        data.userHandle = m_userHandle
        return data
    }

    /// The response as PublicKeyCredential.toJSON() gives it, with each buffer base64url-encoded.
    @cxx
    @implementation
    public func toJSON() -> WebCore.AuthenticationResponseJSON.AuthenticatorAssertionResponseJSON {
        var value = WebCore.AuthenticationResponseJSON.AuthenticatorAssertionResponseJSON()
        if let authData = authenticatorData() {
            value.authenticatorData = authData.base64URLEncodedString
        }
        if let signature = self.signature() {
            value.signature = signature.base64URLEncodedString
        }
        if let handle = userHandle() {
            value.userHandle = handle.base64URLEncodedString
        }
        if let clientData = clientDataJSON() {
            value.clientDataJSON = clientData.base64URLEncodedString
        }
        return value
    }
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
