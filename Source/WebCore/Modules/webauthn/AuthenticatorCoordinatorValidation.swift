// Copyright (C) 2018-2024 Apple Inc. All rights reserved.
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

// MARK: create()

/// The checks `AuthenticatorCoordinator::create` makes of the options after the document's own, with the defaults
/// filled in: the options to pass to the client, or the exception to reject with.
///
/// `effectiveDomain` is the domain of the document's origin.
///
/// The options and `effectiveDomain` are borrowed from the caller, which assigns `createOptions.publicKey` only after
/// this returns.
@_expose(Cxx)
func webAuthnValidateCreationOptions(
    _ creationOptions: WebCore.PublicKeyCredentialCreationOptions,
    effectiveDomain: WTF.String,
    effectiveDomainIsIPAddress: Bool
) -> fido.WebAuthnValidatedCreationOptions {
    var options = creationOptions
    // Step 5.
    if options.user.id.byteLength() < 1 || options.user.id.byteLength() > 64 {
        return .init(rejectingWith: .TypeError, "The length options.user.id must be between 1-64 bytes.")
    }

    // Step 6. Skipped since SecurityOrigin doesn't have the concept of "opaque origin".
    // Step 7. The effective domain may be represented in various manners, such as a domain or an ip address.
    // Only the domain format of host is permitted in WebAuthN.
    if effectiveDomainIsIPAddress {
        return .init(rejectingWith: .SecurityError, "The effective domain of the document is not a valid domain.")
    }

    // Step 8.
    if options.rp.id.isNull() {
        options.rp.id = effectiveDomain
    }

    // Step 9-11.
    // Most of the jobs are done by bindings.
    if options.pubKeyCredParams.isEmpty() {
        options.pubKeyCredParams.append(consuming: .publicKey(algorithm: COSE.ES256))
        options.pubKeyCredParams.append(consuming: .publicKey(algorithm: COSE.RS256))
    } else {
        let parameters: Span<WebCore.PublicKeyCredentialParameters> = options.pubKeyCredParams.span()
        for index in parameters.indices where parameters[index].type != fido.publicKeyCredentialTypePublicKey() {
            return .init(
                rejectingWith: .NotSupportedError,
                "options.pubKeyCredParams contains unsupported PublicKeyCredentialType value."
            )
        }
    }

    // Step 12-13.
    assert(!options.rp.id.isNull())

    var extensionInputs = WebCore.AuthenticationExtensionsClientInputs()
    extensionInputs.credProps = .init(false)
    if let extensions = options.extensions.value {
        extensionInputs.credProps = extensions.credProps
        extensionInputs.largeBlob = extensions.largeBlob
        extensionInputs.prf = extensions.prf
    }

    if let largeBlob = extensionInputs.largeBlob.value, largeBlob.read.hasValue || largeBlob.write.hasValue {
        return .init(rejectingWith: .NotAllowedError, "Read and write may not be present in largeBlob for registration.")
    }
    options.extensions = .init(extensionInputs)

    return .init(accepting: options)
}

extension WebCore.PublicKeyCredentialParameters {
    fileprivate static func publicKey(algorithm: Int64) -> Self {
        var parameters = Self()
        parameters.type = fido.publicKeyCredentialTypePublicKey()
        parameters.alg = algorithm
        return parameters
    }
}

extension fido.WebAuthnValidatedCreationOptions {
    fileprivate init(accepting options: WebCore.PublicKeyCredentialCreationOptions) {
        self.init()
        self.options = .init(options)
    }

    fileprivate init(rejectingWith code: WebCore.ExceptionCode, _ message: Swift.String) {
        self.init()
        self.exception = WebCore.ExceptionData(code: code, message: makeWTFString(message))
    }
}

// MARK: discoverFromExternalSource()

/// The checks `AuthenticatorCoordinator::discoverFromExternalSource` makes of the options after the document's own and
/// before the cross-device fallback URL's, with the defaults filled in and the appid resolved: the options to go on
/// with, or the exception to reject with.
///
/// `effectiveDomain` is the domain of the document's origin; `callerProtocol` and `callerHost` are the origin's.
///
/// The four owning parameters are borrowed from the caller, which assigns `requestOptions.publicKey` only after this
/// returns.
@_expose(Cxx)
func webAuthnValidateRequestOptions(
    _ requestOptions: WebCore.PublicKeyCredentialRequestOptions,
    effectiveDomain: WTF.String,
    effectiveDomainIsIPAddress: Bool,
    callerProtocol: WTF.String,
    callerHost: WTF.String
) -> fido.WebAuthnValidatedRequestOptions {
    var options = requestOptions
    // Step 5. Skipped since SecurityOrigin doesn't have the concept of "opaque origin".
    // Step 6. The effective domain may be represented in various manners, such as a domain or an ip address.
    // Only the domain format of host is permitted in WebAuthN.
    if effectiveDomainIsIPAddress {
        return .init(rejectingWith: .SecurityError, "The effective domain of the document is not a valid domain.")
    }

    // Step 7.
    if options.rpId.isEmpty() {
        options.rpId = effectiveDomain
    }

    // Step 8-9.
    // Only FIDO AppID Extension is supported.
    if var extensions = options.extensions.value, !extensions.appid.isNull() {
        // The following implements https://www.w3.org/TR/webauthn/#sctn-appid-extension as of 4 March 2019.
        if extensions.appid.isEmpty() {
            return .init(rejectingWith: .NotAllowedError, "Empty appid in create request.")
        }
        guard
            let appid = processAppIdExtension(
                callerProtocol: callerProtocol,
                callerHost: callerHost,
                appId: extensions.appid
            )
        else {
            return .init(
                rejectingWith: .SecurityError,
                "The origin of the document is not authorized for the provided App ID."
            )
        }
        extensions.appid = appid
        options.extensions = .init(extensions)
    }

    return .init(accepting: options)
}

extension fido.WebAuthnValidatedRequestOptions {
    fileprivate init(accepting options: WebCore.PublicKeyCredentialRequestOptions) {
        self.init()
        self.options = .init(options)
    }

    fileprivate init(rejectingWith code: WebCore.ExceptionCode, _ message: Swift.String) {
        self.init()
        self.exception = WebCore.ExceptionData(code: code, message: makeWTFString(message))
    }
}

// MARK: The appid extension

// The following roughly implements Step 1-3 of the spec to avoid the complexity of making unnecessary network requests:
// https://fidoalliance.org/specs/fido-v2.0-id-20180227/fido-appid-and-facets-v2.0-id-20180227.html#determining-if-a-caller-s-facetid-is-authorized-for-an-appid
// It follows what Chrome and Firefox do, see:
// https://bugzilla.mozilla.org/show_bug.cgi?id=1244959#c8
// https://bugs.chromium.org/p/chromium/issues/detail?id=818303
private func processAppIdExtension(
    callerProtocol: WTF.String,
    callerHost: borrowing WTF.String,
    appId: borrowing WTF.String
) -> WTF.String? {
    // Step 1. Skipped since facetId should always be secure origins.
    assert(fido.webAuthnURLSchemeIsSecure(callerProtocol))

    // Step 2. Follow Chrome and Firefox to use the origin directly without adding a trailing slash.

    // Step 3. Relax the comparison to same site.
    let appIdURL = fido.webAuthnURLFromString(appId)
    guard appIdURL.isValid(), callerProtocol == fido.webAuthnURLProtocol(appIdURL) else {
        return nil
    }
    if !fido.webAuthnIsSameSite(appIdURL, callerHost) {
        guard needsAppIdQuirks(host: callerHost, appId: appId) else {
            return nil
        }
    }
    return copy appId
}

// Not borrowing: the right operand of || is an autoclosure, whose capture of a borrowing parameter would consume it.
private func needsAppIdQuirks(host: WTF.String, appId: WTF.String) -> Bool {
    // FIXME(197524): Remove this quirk in 2023. As an early adopter of U2F features, Google has a large number of
    // existing device registrations that authenticate 'google.com' against 'gstatic.com'. Firefox and other browsers
    // have agreed to grant an exception to the AppId rules for a limited time period (5 years from January, 2018) to
    // allow existing Google users to seamlessly transition to proper WebAuthN behavior.
    if webAuthnEqualsLettersIgnoringASCIICase(host, "google.com") || webAuthnEndsWithIgnoringASCIICase(host, ".google.com") {
        return webAuthnEqualsASCII(appId, "https://www.gstatic.com/securitykey/origins.json")
            || webAuthnEqualsASCII(appId, "https://www.gstatic.com/securitykey/a/google.com/origins.json")
    }
    return false
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
