// Copyright (C) 2017 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.AttestationConveyancePreference
internal import WebCore_Private.Core.AuthenticatorAttachment
internal import WebCore_Private.Core.CBORBytes
internal import WebCore_Private.Core.PublicKeyCredential
internal import WebCore_Private.Core.PublicKeyCredentialCreationOptionsJSON
internal import WebCore_Private.Core.PublicKeyCredentialRequestOptionsJSON
internal import WebCore_Private.Core.UserVerificationRequirement
internal import WebCore_Private.Core.WebAuthenticationUtils
internal import WebCore_Private.Core.WebAuthnSwiftTypes

// MARK: Options from JSON

/// The members that need parsing of the options `PublicKeyCredential::parseCreationOptionsFromJSON` returns.
///
/// The C++ moves the others out of the JSON dictionary, and makes the result an `ExceptionOr`.
@_expose(Cxx)
func webAuthnParseCreationOptionsMembersFromJSON(
    _ user: consuming WebCore.PublicKeyCredentialUserEntityJSON,
    _ challenge: consuming WTF.String,
    _ excludeCredentials: consuming fido.CredentialDescriptorJSONVector,
    _ attestation: consuming WTF.String,
    _ hasExtensions: Bool,
    _ extensions: consuming WebCore.AuthenticationExtensionsClientInputsJSON
) -> fido.WebAuthnParsedCreationOptionsMembers {
    // The optimizer may end a consuming parameter's lifetime before a read through its storage.
    defer {
        extendLifetime(user)
        extendLifetime(excludeCredentials)
        extendLifetime(extensions)
    }
    // One result on every path, so it is made in the return value; a second one for the failure costs a copy.
    var reader = JSONOptionsReader()
    var result = fido.WebAuthnParsedCreationOptionsMembers()
    guard reader.readUserEntity(user, into: &result),
        let parsedChallenge = reader.bufferSource(fromBase64URL: challenge, named: "challenge"),
        reader.readDescriptors(excludeCredentials, into: &result.excludeCredentials),
        let parsedExtensions = hasExtensions ? reader.extensionInputs(extensions) : fido.OptionalClientInputs()
    else {
        // The C++ reads only the code and the message when the challenge is not set.
        result.exception.message = reader.failureMessage
        return result
    }

    result.challenge = .init(parsedChallenge)
    result.attestation = WebCore.AttestationConveyancePreference(idlName: attestation)
    result.extensions = parsedExtensions
    return result
}

/// The members that need parsing of the options `PublicKeyCredential::parseRequestOptionsFromJSON` returns.
///
/// The C++ moves the others out of the JSON dictionary, and makes the result an `ExceptionOr`.
@_expose(Cxx)
func webAuthnParseRequestOptionsMembersFromJSON(
    _ challenge: consuming WTF.String,
    _ allowCredentials: consuming fido.CredentialDescriptorJSONVector,
    _ userVerification: consuming WTF.String,
    _ hasExtensions: Bool,
    _ extensions: consuming WebCore.AuthenticationExtensionsClientInputsJSON
) -> fido.WebAuthnParsedRequestOptionsMembers {
    // The optimizer may end a consuming parameter's lifetime before a read through its storage.
    defer {
        extendLifetime(allowCredentials)
        extendLifetime(extensions)
    }
    // One result on every path, so it is made in the return value.
    var reader = JSONOptionsReader()
    var result = fido.WebAuthnParsedRequestOptionsMembers()
    guard let parsedChallenge = reader.bufferSource(fromBase64URL: challenge, named: "challenge"),
        reader.readDescriptors(allowCredentials, into: &result.allowCredentials),
        let parsedExtensions = hasExtensions ? reader.extensionInputs(extensions) : fido.OptionalClientInputs()
    else {
        result.exception.message = reader.failureMessage
        return result
    }

    result.challenge = .init(parsedChallenge)
    result.userVerification = WebCore.UserVerificationRequirement(idlName: userVerification)
    result.extensions = parsedExtensions
    return result
}

private struct JSONOptionsReader {
    var failureMessage = WTF.String()

    mutating func bytes(fromBase64URL value: borrowing WTF.String, named name: Swift.String) -> cbor.Bytes? {
        if let bytes = Optional(fromCxx: fido.base64URLDecodeString(value)) {
            return bytes
        }
        failureMessage = invalidEncoding(named: name, value: value)
        return nil
    }

    mutating func bufferSource(fromBase64URL value: borrowing WTF.String, named name: Swift.String) -> WebCore.BufferSource? {
        if let source = Optional(fromCxx: fido.bufferSourceFromBase64URLString(value)) {
            return source
        }
        failureMessage = invalidEncoding(named: name, value: value)
        return nil
    }

    /// Sets the result's user entity, made in its optional.
    mutating func readUserEntity(
        _ json: borrowing WebCore.PublicKeyCredentialUserEntityJSON,
        into result: inout fido.WebAuthnParsedCreationOptionsMembers
    ) -> Bool {
        guard let id = bufferSource(fromBase64URL: json.id, named: "user.id") else {
            return false
        }
        result.user = .init(fido.makePublicKeyCredentialUserEntity(json.name, id, json.displayName))
        return true
    }

    /// Appends each descriptor to the result's list.
    mutating func readDescriptors(
        _ json: borrowing fido.CredentialDescriptorJSONVector,
        into descriptors: inout fido.CredentialDescriptorVector
    ) -> Bool {
        let jsonDescriptors: Span<WebCore.PublicKeyCredentialDescriptorJSON> = json.span()
        for index in jsonDescriptors.indices {
            guard let descriptor = credentialDescriptor(jsonDescriptors[index]) else {
                return false
            }
            descriptors.append(consuming: descriptor)
        }
        return true
    }

    mutating func credentialDescriptor(
        _ json: borrowing WebCore.PublicKeyCredentialDescriptorJSON
    ) -> WebCore.PublicKeyCredentialDescriptor? {
        guard webAuthnEqualsASCII(json.type, "public-key") else {
            failureMessage = makeMessage("Unrecognized credential type: ", json.type)
            return nil
        }
        guard let id = bufferSource(fromBase64URL: json.id, named: "credential ID") else {
            return nil
        }

        var transports = fido.TransportVector()
        let transportStrings: Span<WTF.String> = json.transports.span()
        for index in transportStrings.indices {
            if let transport = Optional(fromCxx: webAuthnTransport(transportStrings[index])) {
                transports.append(consuming: transport)
            }
        }

        return WebCore.PublicKeyCredentialDescriptor(
            type: fido.publicKeyCredentialTypePublicKey(),
            id: id,
            transports: transports
        )
    }

    /// The extension inputs of options that have them.
    ///
    /// The large blob inputs are read before the PRF inputs.
    mutating func extensionInputs(_ json: borrowing WebCore.AuthenticationExtensionsClientInputsJSON) -> fido.OptionalClientInputs? {
        var inputs = fido.WebAuthnClientInputsBuilder()
        inputs.setAppid(json.appid)
        if let credProps = Optional(fromCxx: json.credProps) {
            inputs.setCredProps(credProps)
        }
        if let largeBlob = Optional(fromCxx: json.largeBlob) {
            guard readLargeBlob(largeBlob, into: &inputs) else {
                return nil
            }
        }
        if let prf = Optional(fromCxx: json.prf) {
            guard readPRF(prf, into: &inputs) else {
                return nil
            }
        }
        inputs.setCrossDeviceFallbackURL(json.crossDeviceFallbackURL)
        return inputs.take()
    }

    /// The large blob inputs. `write` is decoded even when it is null, which gives an empty buffer.
    private mutating func readLargeBlob(
        _ json: borrowing WebCore.AuthenticationExtensionsClientInputsJSON.LargeBlobInputsJSON,
        into inputs: inout fido.WebAuthnClientInputsBuilder
    ) -> Bool {
        guard let write = bytes(fromBase64URL: json.write, named: "largeBlob.write") else {
            return false
        }
        inputs.beginLargeBlob()
        inputs.setLargeBlobSupport(json.support)
        if let read = Optional(fromCxx: json.read) {
            inputs.setLargeBlobRead(read)
        }
        inputs.setLargeBlobWrite(write)
        return true
    }

    /// The PRF inputs: `eval`, then each credential's values of `evalByCredential` in order.
    private mutating func readPRF(
        _ json: borrowing WebCore.AuthenticationExtensionsClientInputsJSON.PRFInputsJSON,
        into inputs: inout fido.WebAuthnClientInputsBuilder
    ) -> Bool {
        inputs.beginPRF()
        if let eval = Optional(fromCxx: json.eval) {
            guard let values = prfValues(eval) else {
                return false
            }
            inputs.setPRFEval(values.first)
            if let second = values.second {
                inputs.setPRFEvalSecond(second)
            }
        }
        if let evalByCredential = Optional(fromCxx: json.evalByCredential) {
            inputs.beginPRFEvalByCredential()
            for index in 0..<evalByCredential.size() {
                let entry = evalByCredential[index]
                guard let values = prfValues(entry.value) else {
                    return false
                }
                inputs.addPRFEvalByCredential(entry.key, values.first)
                if let second = values.second {
                    inputs.setLastPRFEvalByCredentialSecond(second)
                }
            }
        }
        return true
    }

    /// The PRF salts: `second` is decoded only when it is not null, so an empty string gives an empty buffer.
    private mutating func prfValues(
        _ json: borrowing WebCore.AuthenticationExtensionsClientInputsJSON.PRFValuesJSON
    ) -> (first: cbor.Bytes, second: cbor.Bytes?)? {
        guard let first = bytes(fromBase64URL: json.first, named: "prf.first") else {
            return nil
        }
        if json.second.isNull() {
            return (first, nil)
        }
        guard let second = bytes(fromBase64URL: json.second, named: "prf.second") else {
            return nil
        }
        return (first, second)
    }
}

extension WebCore.AttestationConveyancePreference {
    /// The preference an IDL enumeration value names; none for a string that names none.
    fileprivate init(idlName string: borrowing WTF.String) {
        if webAuthnEqualsASCII(string, "indirect") {
            self = .Indirect
        } else if webAuthnEqualsASCII(string, "direct") {
            self = .Direct
        } else if webAuthnEqualsASCII(string, "enterprise") {
            self = .Enterprise
        } else {
            self = .None
        }
    }
}

extension WebCore.UserVerificationRequirement {
    /// The requirement an IDL enumeration value names; preferred for a string that names none.
    fileprivate init(idlName string: borrowing WTF.String) {
        if webAuthnEqualsASCII(string, "required") {
            self = .Required
        } else if webAuthnEqualsASCII(string, "discouraged") {
            self = .Discouraged
        } else {
            self = .Preferred
        }
    }
}

/// The message for a member that is not base64url: the member's name and its value.
private func invalidEncoding(named name: Swift.String, value: borrowing WTF.String) -> WTF.String {
    makeMessage("Invalid encoding of \(name): ", value, " (It should be Base64URL encoded.)")
}

/// The ASCII prefix and suffix around the value as one string, keeping the value's unpaired surrogates: 8-bit when the
/// value is, as `makeString` makes it.
private func makeMessage(_ prefix: Swift.String, _ value: borrowing WTF.String, _ suffix: Swift.String = "") -> WTF.String {
    let length = prefix.utf8.count &+ Int(value.length()) &+ suffix.utf8.count
    if value.is8Bit() {
        var characters: [UInt8] = []
        characters.reserveCapacity(length)
        characters.append(contentsOf: prefix.utf8)
        let valueCharacters: Span<UInt8> = WTF.bytesOfLatin1Characters(value.span8())
        for index in valueCharacters.indices {
            characters.append(valueCharacters[index])
        }
        characters.append(contentsOf: suffix.utf8)
        return WTF.String(WTF.latin1CharactersOfBytes(characters.span))
    }

    var units: [UInt16] = []
    units.reserveCapacity(length)
    appendASCII(prefix, to: &units)
    appendUTF16Units(of: value, to: &units)
    appendASCII(suffix, to: &units)
    return WTF.String(units.span)
}

private func appendASCII(_ literal: Swift.String, to units: inout [UInt16]) {
    for byte in literal.utf8 {
        units.append(UInt16(byte))
    }
}

// MARK: Credential to JSON

extension WebCore.PublicKeyCredential {
    /// The credential as the JSON its response type gives.
    @cxx
    @implementation
    public func toJSON() -> WebCore.PublicKeyCredentialJSON {
        if let attestationResponse = fido.attestationResponse(response()).get() {
            let encodedId = rawId().base64URLEncodedString
            return fido.publicKeyCredentialJSON(
                WebCore.RegistrationResponseJSON(
                    id: encodedId,
                    rawId: encodedId,
                    response: attestationResponse.toJSON(),
                    authenticatorAttachment: authenticatorAttachment().idlName,
                    clientExtensionResults: getClientExtensionResults().toJSON(),
                    type: type()
                )
            )
        }
        if let assertionResponse = fido.assertionResponse(response()).get() {
            let encodedId = rawId().base64URLEncodedString
            return fido.publicKeyCredentialJSON(
                WebCore.AuthenticationResponseJSON(
                    id: encodedId,
                    rawId: encodedId,
                    response: assertionResponse.toJSON(),
                    authenticatorAttachment: authenticatorAttachment().idlName,
                    clientExtensionResults: getClientExtensionResults().toJSON(),
                    type: type()
                )
            )
        }

        assertionFailure()
        return fido.publicKeyCredentialJSON(WebCore.AuthenticationResponseJSON())
    }
}

extension WebCore.AuthenticatorAttachment {
    /// The IDL enumeration value.
    fileprivate var idlName: WTF.String {
        switch self {
        case .Platform:
            return makeWTFString("platform")
        case .CrossPlatform:
            return makeWTFString("cross-platform")
        @unknown default:
            preconditionFailure("An unknown authenticator attachment")
        }
    }
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
