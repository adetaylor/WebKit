// Copyright (C) 2017 Google Inc. All rights reserved.
// Copyright (C) 2017-2025 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.WebAuthenticationUtils

private struct CredentialTypes: OptionSet {
    let rawValue: UInt8

    static let password = CredentialTypes(rawValue: 1 << 0)
    static let federated = CredentialTypes(rawValue: 1 << 1)
    static let identity = CredentialTypes(rawValue: 1 << 2)
    static let otp = CredentialTypes(rawValue: 1 << 3)
    static let publicKey = CredentialTypes(rawValue: 1 << 4)
    static let digital = CredentialTypes(rawValue: 1 << 5)
    static let phoneNumberPossession = CredentialTypes(rawValue: 1 << 6)

    static let each: [CredentialTypes] = [.password, .federated, .identity, .otp, .publicKey, .digital, .phoneNumberPossession]

    // NOTE: allowedWith must be symmetric — if type A lists B, then B must
    // also list A. Asymmetry causes inconsistent rejection depending on
    // iteration order. See https://w3c.github.io/webappsec-credential-management/#credential-type-registry
    var allowedWith: CredentialTypes {
        switch self {
        case .password: .federated
        case .federated: .password
        default: []
        }
    }
}

// https://w3c.github.io/webappsec-credential-management/#credential-type-registry
/// The message of the NotSupportedError a request for these credential types is rejected with, or none when they may be
/// requested together.
@_expose(Cxx)
func credentialTypeCombinationError(
    password: Bool,
    federated: Bool,
    identity: Bool,
    otp: Bool,
    publicKey: Bool,
    digital: Bool,
    phoneNumberPossession: Bool
) -> WebCore.OptionalWebAuthnString {
    var requestedTypes: CredentialTypes = []
    if password { requestedTypes.insert(.password) }
    if federated { requestedTypes.insert(.federated) }
    if identity { requestedTypes.insert(.identity) }
    if otp { requestedTypes.insert(.otp) }
    if publicKey { requestedTypes.insert(.publicKey) }
    if digital { requestedTypes.insert(.digital) }
    if phoneNumberPossession { requestedTypes.insert(.phoneNumberPossession) }

    if requestedTypes.isEmpty {
        return .init(makeWTFString("No credential type was specified."))
    }

    for type in CredentialTypes.each where requestedTypes.contains(type) {
        let others = requestedTypes.subtracting(type)
        if !others.isEmpty && !type.allowedWith.isSuperset(of: others) {
            return .init(makeWTFString("The credential type combination is not supported."))
        }
    }
    return .init()
}

#endif
