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

// CTAP2 request encoding (authenticatorMakeCredential, authenticatorGetAssertion, authenticatorGetInfo).

/// Whether `a` and `b` have the same code units (WTF `String` equality; Swift's `==` compares canonical equivalence).
public func sameCodeUnits(_ a: Swift.String, _ b: Swift.String) -> Bool {
    let aUTF8 = a.utf8
    let bUTF8 = b.utf8
    let aBytes: Span<UInt8> = aUTF8.span
    let bBytes: Span<UInt8> = bUTF8.span
    if aBytes.count != bBytes.count {
        return false
    }
    for index in aBytes.indices where aBytes[index] != bBytes[index] {
        return false
    }
    return true
}

/// Whether `strings` has a string with the code units of `string`.
private func containsString(_ strings: [Swift.String], _ string: Swift.String) -> Bool {
    strings.contains { sameCodeUnits($0, string) }
}

/// A byte string of the bytes of `source`.
private func writeByteString(_ writer: inout CBORWriter, _ source: borrowing WebCore.BufferSource) {
    let bytes: Span<UInt8> = source.span()
    writer.writeByteString(bytes)
}

/// The Swift strings of a `Vector<String>`.
private func makeSwiftStrings(_ strings: borrowing fido.StringVector) -> [Swift.String] {
    var result: [Swift.String] = []
    let count = strings.size()
    result.reserveCapacity(count)
    for index in 0..<count {
        result.append(makeSwiftString(strings[index]))
    }
    return result
}

/// The name of a credential type: PublicKeyCredentialType has one value.
private func publicKeyCredentialTypeName(_ type: WebCore.PublicKeyCredentialType) -> Swift.String {
    FidoName.publicKey
}

// The maps below write their keys in `ctapLess` order: integers ascending, then text by length, then by character.

private func writeRpEntity(_ writer: inout CBORWriter, _ rpEntity: borrowing WebCore.PublicKeyCredentialRpEntity) {
    let hasID = !rpEntity.id.isEmpty()
    let hasIcon = !rpEntity.icon.isEmpty()
    writer.beginMap(count: 1 + (hasID ? 1 : 0) + (hasIcon ? 1 : 0))
    if hasID {
        writer.writeTextString(FidoName.entityID)
        writer.writeTextString(rpEntity.id)
    }
    if hasIcon {
        writer.writeTextString(FidoName.iconURL)
        writer.writeTextString(rpEntity.icon)
    }
    writer.writeTextString(FidoName.entityName)
    writer.writeTextString(rpEntity.name)
}

private func writeUserEntity(_ writer: inout CBORWriter, _ userEntity: borrowing WebCore.PublicKeyCredentialUserEntity) {
    let hasIcon = !userEntity.icon.isEmpty()
    writer.beginMap(count: hasIcon ? 4 : 3)
    writer.writeTextString(FidoName.entityID)
    writeByteString(&writer, userEntity.id)
    if hasIcon {
        writer.writeTextString(FidoName.iconURL)
        writer.writeTextString(userEntity.icon)
    }
    writer.writeTextString(FidoName.entityName)
    writer.writeTextString(userEntity.name)
    writer.writeTextString(FidoName.displayName)
    writer.writeTextString(userEntity.displayName)
}

/// A credential parameter as plain values.
private struct CredentialParameter {
    var type: WebCore.PublicKeyCredentialType
    var alg: Int64
}

private func credentialParameters(_ parameters: borrowing fido.CredentialParametersVector) -> [CredentialParameter] {
    var result: [CredentialParameter] = []
    let count = parameters.size()
    result.reserveCapacity(count)
    for index in 0..<count {
        result.append(CredentialParameter(type: parameters[index].type, alg: parameters[index].alg))
    }
    return result
}

private func writeParameters(_ writer: inout CBORWriter, _ parameters: [CredentialParameter]) {
    writer.beginArray(count: parameters.count)
    for credential in parameters {
        writer.beginMap(count: 2)
        writer.writeTextString(FidoName.credentialAlgorithm)
        writer.writeInteger(credential.alg)
        writer.writeTextString(FidoName.credentialTypeMap)
        writer.writeTextString(publicKeyCredentialTypeName(credential.type))
    }
}

private func writeDescriptor(_ writer: inout CBORWriter, _ descriptor: borrowing WebCore.PublicKeyCredentialDescriptor) {
    writer.beginMap(count: 2)
    writer.writeTextString(FidoName.credentialID)
    writeByteString(&writer, descriptor.id)
    writer.writeTextString(FidoName.credentialType)
    writer.writeTextString(publicKeyCredentialTypeName(descriptor.type))
}

private func writeDescriptors(_ writer: inout CBORWriter, _ descriptors: borrowing fido.CredentialDescriptorVector) {
    let count = descriptors.size()
    writer.beginArray(count: count)
    for index in 0..<count {
        writeDescriptor(&writer, descriptors[index])
    }
}

private func trimmedParameters(
    _ parameters: [CredentialParameter],
    _ authenticatorSupportedParameters: fido.OptionalCredentialParametersVector
) -> [CredentialParameter] {
    // HashSet<int64_t> (its hash table marks empty and deleted slots apart from the keys, so every value is a key).
    var authenticatorSupportedAlgorithms = Set<Int64>()
    if let supported = Optional(fromCxx: authenticatorSupportedParameters) {
        for parameter in credentialParameters(supported) where parameter.type == fido.publicKeyCredentialTypePublicKey() {
            authenticatorSupportedAlgorithms.insert(parameter.alg)
        }
    }

    for parameter in parameters {
        if parameter.type != fido.publicKeyCredentialTypePublicKey() {
            continue
        }
        if authenticatorSupportedAlgorithms.contains(parameter.alg) {
            return [parameter]
        }
        // Support for ES256 required by U2F backwards compatibility.
        if parameter.alg == COSE.ES256 {
            return [parameter]
        }
    }

    // We know the algorithms the authenticator supports and none of those were requested.
    if !authenticatorSupportedAlgorithms.isEmpty {
        return [parameters[0]] // parameters.first(): traps when empty, as Vector::first does.
    }
    return parameters
}

/// The hmac-secret / hmac-secret-mc extension input map.
private func writeHmacSecret(_ writer: inout CBORWriter, _ parameters: borrowing fido.HmacSecretParameters) {
    // keyAgreement is the platform COSE key map that CBORWriter encoded; embed the map itself.
    let keyAgreementBytes: Span<UInt8> = parameters.keyAgreement.span()
    guard let keyAgreement = CBORView(keyAgreementBytes) else {
        preconditionFailure("HmacSecretParameters.keyAgreement is CBORWriter output")
    }
    writer.beginMap(count: 4)
    writer.writeInteger(fido.kHmacSecretKeyAgreementKey)
    writer.append(encodedItem: keyAgreement.encoded)
    writer.writeInteger(fido.kHmacSecretSaltEncKey)
    writer.writeByteString(parameters.saltEnc.span())
    writer.writeInteger(fido.kHmacSecretSaltAuthKey)
    writer.writeByteString(parameters.saltAuth.span())
    writer.writeInteger(fido.kHmacSecretPinUvAuthProtocolKey)
    writer.writeInteger(Int64(parameters.protocol))
}

/// Whether user verification is requested, from the effective requirement and the authenticator's capability.
private func requiresUserVerification(
    _ effectiveUVRequirement: WebCore.UserVerificationRequirement,
    _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability
) -> Bool {
    switch effectiveUVRequirement {
    case .Required, .Preferred:
        return uvCapability == .supportedAndConfigured
    default:
        return false
    }
}

/// The command byte, which the map of the request's parameters follows.
private func beginRequest(_ command: fido.CtapRequestCommand) -> CBORWriter {
    var writer = CBORWriter(reservingCapacity: 256)
    writer.append(byte: command.rawValue)
    return writer
}

/// The pinUvAuthParam and pinUvAuthProtocol entries, at `authKey` and the key after it.
private func writePinParameters(_ writer: inout CBORWriter, _ pin: borrowing fido.PinParameters, authKey: Int64, protocolKey: Int64) {
    writer.writeInteger(authKey)
    writer.writeByteString(pin.auth.span())
    writer.writeInteger(protocolKey)
    writer.writeInteger(Int64(pin.protocol))
}

private func makeCredentialRequest(
    hash: borrowing cbor.Bytes,
    options: WebCore.PublicKeyCredentialCreationOptions,
    uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability,
    effectiveUVRequirement: WebCore.UserVerificationRequirement,
    residentKeyAvailability: fido.AuthenticatorSupportedOptions.ResidentKeyAvailability,
    authenticatorSupportedExtensions: fido.StringVector,
    pin: fido.OptionalPinParameters,
    overrideParameters: fido.OptionalCredentialParametersVector,
    overrideExcludeCredentials: fido.OptionalCredentialDescriptorVector,
    hmacSecret: fido.OptionalHmacSecretParameters
) -> cbor.Bytes {
    let supportedExtensions = makeSwiftStrings(authenticatorSupportedExtensions)
    let pinParameters = Optional(fromCxx: pin)

    let excludeCredentials = Optional(fromCxx: overrideExcludeCredentials)
    let writesExcludeList = excludeCredentials.map { !$0.isEmpty() } ?? !options.excludeCredentials.isEmpty()

    let extensions = Optional(fromCxx: options.extensions)
    let hmacSecretParameters = Optional(fromCxx: hmacSecret)
    var largeBlobInputs: WebCore.AuthenticationExtensionsClientInputs.LargeBlobInputs?
    var writesPrf = false
    if let extensions {
        if containsString(supportedExtensions, "largeBlob") {
            largeBlobInputs = Optional(fromCxx: extensions.largeBlob)
        }
        // Convert prf extension to hmac-secret: true for makeCredential
        writesPrf = extensions.prf.hasValue && containsString(supportedExtensions, FidoName.extensionHmacSecret)
    }
    // Add hmac-secret-mc extension with encrypted parameters
    let writesHmacSecretMc = hmacSecretParameters != nil && containsString(supportedExtensions, FidoName.extensionHmacSecretMc)
    let extensionCount = (largeBlobInputs != nil ? 1 : 0) + (writesPrf ? 1 : 0) + (writesHmacSecretMc ? 1 : 0)

    var writesResidentKey = false
    var writesUserVerification = false
    if let authenticatorSelection = Optional(fromCxx: options.authenticatorSelection) {
        // Resident keys are not supported by default.
        if let residentKey = Optional(fromCxx: authenticatorSelection.residentKey) {
            writesResidentKey = residentKey == .Required || (residentKey == .Preferred && residentKeyAvailability == .supported)
        } else {
            writesResidentKey = authenticatorSelection.requireResidentKey
        }
        // User verification is not required by default.
        writesUserVerification = requiresUserVerification(effectiveUVRequirement, uvCapability)
    }
    let optionCount = (writesResidentKey ? 1 : 0) + (writesUserVerification ? 1 : 0)

    var writer = beginRequest(.authenticatorMakeCredential)
    writer.beginMap(
        count: 4 + (writesExcludeList ? 1 : 0) + (extensionCount > 0 ? 1 : 0) + (optionCount > 0 ? 1 : 0) + (pinParameters != nil ? 2 : 0)
    )
    writer.writeInteger(fido.kCtapMakeCredentialClientDataHashKey)
    writer.writeByteString(hash.span())
    writer.writeInteger(fido.kCtapMakeCredentialRpKey)
    writeRpEntity(&writer, options.rp)
    writer.writeInteger(fido.kCtapMakeCredentialUserKey)
    writeUserEntity(&writer, options.user)
    writer.writeInteger(fido.kCtapMakeCredentialPubKeyCredParamsKey)
    writeParameters(&writer, trimmedParameters(credentialParameters(options.pubKeyCredParams), overrideParameters))
    if writesExcludeList {
        writer.writeInteger(fido.kCtapMakeCredentialExcludeListKey)
        if let excludeCredentials {
            writeDescriptors(&writer, excludeCredentials)
        } else {
            writeDescriptors(&writer, options.excludeCredentials)
        }
    }
    if extensionCount > 0 {
        writer.writeInteger(fido.kCtapMakeCredentialExtensionsKey)
        writer.beginMap(count: extensionCount)
        if let largeBlobInputs {
            let writesSupport = !largeBlobInputs.support.isNull()
            writer.writeTextString("largeBlob")
            writer.beginMap(count: writesSupport ? 1 : 0)
            if writesSupport {
                writer.writeTextString("support")
                writer.writeTextString(largeBlobInputs.support)
            }
        }
        if writesPrf {
            writer.writeTextString(FidoName.extensionHmacSecret)
            writer.writeBool(true)
        }
        if writesHmacSecretMc, let hmacSecretParameters {
            writer.writeTextString(FidoName.extensionHmacSecretMc)
            writeHmacSecret(&writer, hmacSecretParameters)
        }
    }
    if optionCount > 0 {
        writer.writeInteger(fido.kCtapMakeCredentialRequestOptionsKey)
        writer.beginMap(count: optionCount)
        if writesResidentKey {
            writer.writeTextString(FidoName.residentKey)
            writer.writeBool(true)
        }
        if writesUserVerification {
            writer.writeTextString(FidoName.userVerification)
            writer.writeBool(true)
        }
    }
    if let pinParameters {
        writePinParameters(
            &writer,
            pinParameters,
            authKey: fido.kCtapMakeCredentialPinUvAuthParamKey,
            protocolKey: fido.kCtapMakeCredentialPinUvAuthProtocolKey
        )
    }
    return writer.takeVector()
}

private func getAssertionRequest(
    hash: borrowing cbor.Bytes,
    options: WebCore.PublicKeyCredentialRequestOptions,
    uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability,
    effectiveUVRequirement: WebCore.UserVerificationRequirement,
    authenticatorSupportedExtensions: fido.StringVector,
    pin: fido.OptionalPinParameters,
    overrideAllowCredentials: fido.OptionalCredentialDescriptorVector,
    hmacSecret: fido.OptionalHmacSecretParameters
) -> cbor.Bytes {
    let supportedExtensions = makeSwiftStrings(authenticatorSupportedExtensions)
    let pinParameters = Optional(fromCxx: pin)

    let allowCredentials = Optional(fromCxx: overrideAllowCredentials)
    let writesAllowList = allowCredentials != nil || !options.allowCredentials.isEmpty()

    let extensions = Optional(fromCxx: options.extensions)
    let hmacSecretParameters = Optional(fromCxx: hmacSecret)
    var largeBlobInputs: WebCore.AuthenticationExtensionsClientInputs.LargeBlobInputs?
    if let extensions, containsString(supportedExtensions, "largeBlob") {
        largeBlobInputs = Optional(fromCxx: extensions.largeBlob)
    }
    // Add hmac-secret extension with encrypted salt parameters
    let writesHmacSecret = hmacSecretParameters != nil && containsString(supportedExtensions, FidoName.extensionHmacSecret)
    let extensionCount = (largeBlobInputs != nil ? 1 : 0) + (writesHmacSecret ? 1 : 0)

    // User verification is not required by default.
    let writesUserVerification = requiresUserVerification(effectiveUVRequirement, uvCapability)

    var writer = beginRequest(.authenticatorGetAssertion)
    writer.beginMap(count: 3 + (writesAllowList ? 1 : 0) + (extensionCount > 0 ? 1 : 0) + (pinParameters != nil ? 2 : 0))
    writer.writeInteger(fido.kCtapGetAssertionRpIdKey)
    writer.writeTextString(options.rpId)
    writer.writeInteger(fido.kCtapGetAssertionClientDataHashKey)
    writer.writeByteString(hash.span())
    if writesAllowList {
        writer.writeInteger(fido.kCtapGetAssertionAllowListKey)
        if let allowCredentials {
            writeDescriptors(&writer, allowCredentials)
        } else {
            writeDescriptors(&writer, options.allowCredentials)
        }
    }
    if extensionCount > 0 {
        writer.writeInteger(fido.kCtapGetAssertionExtensionsKey)
        writer.beginMap(count: extensionCount)
        if let largeBlobInputs {
            let read = Optional(fromCxx: largeBlobInputs.read)
            let write = Optional(fromCxx: largeBlobInputs.write)
            writer.writeTextString("largeBlob")
            writer.beginMap(count: (read != nil ? 1 : 0) + (write != nil ? 1 : 0))
            if let read {
                writer.writeTextString("read")
                writer.writeBool(read)
            }
            if let write {
                writer.writeTextString("write")
                writeByteString(&writer, write)
            }
        }
        if writesHmacSecret, let hmacSecretParameters {
            writer.writeTextString(FidoName.extensionHmacSecret)
            writeHmacSecret(&writer, hmacSecretParameters)
        }
    }
    writer.writeInteger(fido.kCtapGetAssertionRequestOptionsKey)
    writer.beginMap(count: writesUserVerification ? 2 : 1)
    writer.writeTextString(FidoName.userPresence)
    writer.writeBool(true)
    if writesUserVerification {
        writer.writeTextString(FidoName.userVerification)
        writer.writeBool(true)
    }
    if let pinParameters {
        writePinParameters(
            &writer,
            pinParameters,
            authKey: fido.kCtapGetAssertionPinUvAuthParamKey,
            protocolKey: fido.kCtapGetAssertionPinUvAuthProtocolKey
        )
    }
    return writer.takeVector()
}

private func silentGetAssertionRequest(
    _ rpId: WTF.String,
    _ hash: borrowing cbor.Bytes,
    _ credentials: fido.CredentialDescriptorVector,
    _ pin: fido.OptionalPinParameters
) -> cbor.Bytes {
    let pinParameters = Optional(fromCxx: pin)
    var writer = beginRequest(.authenticatorGetAssertion)
    writer.beginMap(count: 4 + (pinParameters != nil ? 2 : 0))
    writer.writeInteger(fido.kCtapGetAssertionRpIdKey)
    writer.writeTextString(rpId)
    writer.writeInteger(fido.kCtapGetAssertionClientDataHashKey)
    writer.writeByteString(hash.span())
    writer.writeInteger(fido.kCtapGetAssertionAllowListKey)
    writeDescriptors(&writer, credentials)
    writer.writeInteger(fido.kCtapGetAssertionRequestOptionsKey)
    writer.beginMap(count: 1)
    writer.writeTextString(FidoName.userPresence)
    writer.writeBool(false)
    if let pinParameters {
        writePinParameters(
            &writer,
            pinParameters,
            authKey: fido.kCtapGetAssertionPinUvAuthParamKey,
            protocolKey: fido.kCtapGetAssertionPinUvAuthProtocolKey
        )
    }
    return writer.takeVector()
}

extension fido {
    /// The CTAP makeCredential request, encoded for tests, with no hmac-secret parameters.
    @cxx
    @implementation
    public static func encodeMakeCredentialRequestAsCBORForTesting(
        _ hash: cbor.Bytes,
        _ options: WebCore.PublicKeyCredentialCreationOptions,
        _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability,
        _ effectiveUVRequirement: WebCore.UserVerificationRequirement,
        _ residentKeyAvailability: fido.AuthenticatorSupportedOptions.ResidentKeyAvailability,
        _ authenticatorSupportedExtensions: fido.StringVector,
        _ pin: fido.OptionalPinParameters,
        _ overrideParameters: fido.OptionalCredentialParametersVector,
        _ overrideExcludeCredentials: fido.OptionalCredentialDescriptorVector
    ) -> cbor.Bytes {
        encodeMakeCredentialRequestAsCBOR(
            hash,
            options,
            uvCapability,
            effectiveUVRequirement,
            residentKeyAvailability,
            authenticatorSupportedExtensions,
            pin,
            overrideParameters,
            overrideExcludeCredentials,
            fido.OptionalHmacSecretParameters()
        )
    }

    /// The CTAP getAssertion request, encoded for tests, with no hmac-secret parameters.
    @cxx
    @implementation
    public static func encodeGetAssertionRequestAsCBORForTesting(
        _ hash: cbor.Bytes,
        _ options: WebCore.PublicKeyCredentialRequestOptions,
        _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability,
        _ effectiveUVRequirement: WebCore.UserVerificationRequirement,
        _ authenticatorSupportedExtensions: fido.StringVector,
        _ pin: fido.OptionalPinParameters,
        _ overrideAllowCredentials: fido.OptionalCredentialDescriptorVector
    ) -> cbor.Bytes {
        encodeGetAssertionRequestAsCBOR(
            hash,
            options,
            uvCapability,
            effectiveUVRequirement,
            authenticatorSupportedExtensions,
            pin,
            overrideAllowCredentials,
            fido.OptionalHmacSecretParameters()
        )
    }

    /// The CTAP makeCredential request, encoded.
    @cxx
    @implementation
    public static func encodeMakeCredentialRequestAsCBOR(
        _ hash: cbor.Bytes,
        _ options: WebCore.PublicKeyCredentialCreationOptions,
        _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability,
        _ effectiveUVRequirement: WebCore.UserVerificationRequirement,
        _ residentKeyAvailability: fido.AuthenticatorSupportedOptions.ResidentKeyAvailability,
        _ authenticatorSupportedExtensions: fido.StringVector,
        _ pin: fido.OptionalPinParameters,
        _ overrideParameters: fido.OptionalCredentialParametersVector,
        _ overrideExcludeCredentials: fido.OptionalCredentialDescriptorVector,
        _ hmacSecret: fido.OptionalHmacSecretParameters
    ) -> cbor.Bytes {
        makeCredentialRequest(
            hash: hash,
            options: options,
            uvCapability: uvCapability,
            effectiveUVRequirement: effectiveUVRequirement,
            residentKeyAvailability: residentKeyAvailability,
            authenticatorSupportedExtensions: authenticatorSupportedExtensions,
            pin: pin,
            overrideParameters: overrideParameters,
            overrideExcludeCredentials: overrideExcludeCredentials,
            hmacSecret: hmacSecret
        )
    }

    /// The CTAP getAssertion request, encoded.
    @cxx
    @implementation
    public static func encodeGetAssertionRequestAsCBOR(
        _ hash: cbor.Bytes,
        _ options: WebCore.PublicKeyCredentialRequestOptions,
        _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability,
        _ effectiveUVRequirement: WebCore.UserVerificationRequirement,
        _ authenticatorSupportedExtensions: fido.StringVector,
        _ pin: fido.OptionalPinParameters,
        _ overrideAllowCredentials: fido.OptionalCredentialDescriptorVector,
        _ hmacSecret: fido.OptionalHmacSecretParameters
    ) -> cbor.Bytes {
        getAssertionRequest(
            hash: hash,
            options: options,
            uvCapability: uvCapability,
            effectiveUVRequirement: effectiveUVRequirement,
            authenticatorSupportedExtensions: authenticatorSupportedExtensions,
            pin: pin,
            overrideAllowCredentials: overrideAllowCredentials,
            hmacSecret: hmacSecret
        )
    }

    /// A request that only lets the user pick an authenticator.
    @cxx
    @implementation
    public static func encodeBogusRequestForAuthenticatorSelection() -> cbor.Bytes {
        var writer = beginRequest(.authenticatorMakeCredential)
        writer.beginMap(count: 6)
        // Vector<uint8_t>(FillWith { }, 0, 32) is size 0 filled with 32s: an empty hash.
        writer.writeInteger(fido.kCtapMakeCredentialClientDataHashKey)
        writer.writeByteString(Span<UInt8>())
        writer.writeInteger(fido.kCtapMakeCredentialRpKey)
        writer.beginMap(count: 2)
        writer.writeTextString(FidoName.entityID)
        writer.writeTextString("notarealwebsite.com")
        writer.writeTextString(FidoName.entityName)
        writer.writeTextString("notarealwebsite.com")

        writer.writeInteger(fido.kCtapMakeCredentialUserKey)
        writer.beginMap(count: 3)
        writer.writeTextString(FidoName.entityID)
        let zeroByte: [UInt8] = [0]
        writer.writeByteString(zeroByte.span)
        writer.writeTextString(FidoName.entityName)
        writer.writeTextString("bogus")
        writer.writeTextString(FidoName.displayName)
        writer.writeTextString("bogus")

        writer.writeInteger(fido.kCtapMakeCredentialPubKeyCredParamsKey)
        writeParameters(&writer, [CredentialParameter(type: fido.publicKeyCredentialTypePublicKey(), alg: COSE.ES256)])
        writer.writeInteger(fido.kCtapMakeCredentialPinUvAuthParamKey)
        writer.writeByteString(Span<UInt8>())
        writer.writeInteger(fido.kCtapMakeCredentialPinUvAuthProtocolKey)
        writer.writeInteger(pin.kProtocolVersion)
        return writer.takeVector()
    }

    /// A silent getAssertion request, encoded.
    @cxx
    @implementation
    public static func encodeSilentGetAssertion(
        _ rpId: WTF.String,
        _ hash: cbor.Bytes,
        _ credentials: fido.CredentialDescriptorVector,
        _ pin: fido.OptionalPinParameters
    ) -> cbor.Bytes {
        silentGetAssertionRequest(rpId, hash, credentials, pin)
    }

    /// A request that is only a command byte.
    @cxx
    @implementation
    public static func encodeEmptyAuthenticatorRequest(_ cmd: fido.CtapRequestCommand) -> cbor.Bytes {
        makeByteVector([cmd.rawValue])
    }
}

/// The body of `fido::encodeAsCBOR(AuthenticatorGetInfoResponse)`, which forwards here.
///
/// `response` is the caller's, alive and unchanged for the call; only its fields are read.
@_expose(Cxx)
func encodeGetInfoResponseAsCBOR(_ response: borrowing fido.AuthenticatorGetInfoResponse) -> cbor.Bytes {
    let fields = fido.getInfoResponseFields(response)
    let extensions = Optional(fromCxx: fields.extensions)
    let maxMsgSize = Optional(fromCxx: fields.maxMsgSize)
    let pinProtocols = Optional(fromCxx: fields.pinProtocols)
    let transports = Optional(fromCxx: fields.transports)
    let remaining = Optional(fromCxx: fields.remainingDiscoverableCredentials)
    let minPINLength = Optional(fromCxx: fields.minPINLength)
    let maxCredentialCountInList = Optional(fromCxx: fields.maxCredentialCountInList)
    let maxCredentialIDLength = Optional(fromCxx: fields.maxCredentialIDLength)

    var writer = CBORWriter(reservingCapacity: 128)
    writer.beginMap(
        count: 3 + (extensions != nil ? 1 : 0) + (maxMsgSize != nil ? 1 : 0) + (pinProtocols != nil ? 1 : 0)
            + (transports != nil ? 1 : 0) + (remaining != nil ? 1 : 0) + (minPINLength != nil ? 1 : 0)
            + (maxCredentialCountInList != nil ? 1 : 0) + (maxCredentialIDLength != nil ? 1 : 0)
    )

    writer.writeInteger(fido.kCtapAuthenticatorGetInfoVersionsKey)
    writer.beginArray(count: fields.versions.size())
    for index in 0..<fields.versions.size() {
        writer.writeTextString(fields.versions[index].name)
    }

    if let extensions {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoExtensionsKey)
        writer.beginArray(count: extensions.size())
        for index in 0..<extensions.size() {
            writer.writeTextString(extensions[index])
        }
    }

    writer.writeInteger(fido.kCtapAuthenticatorGetInfoAAGUIDKey)
    writer.writeByteString(fields.aaguid.span())

    // The options map.
    let userVerification: Bool?
    switch fields.userVerificationAvailability {
    case .supportedAndConfigured:
        userVerification = true
    case .supportedButNotConfigured:
        userVerification = false
    default:
        userVerification = nil
    }
    let clientPin: Bool?
    switch fields.clientPinAvailability {
    case .supportedAndPinSet:
        clientPin = true
    case .supportedButPinNotSet:
        clientPin = false
    default:
        clientPin = nil
    }
    writer.writeInteger(fido.kCtapAuthenticatorGetInfoOptionsKey)
    writer.beginMap(count: 3 + (userVerification != nil ? 1 : 0) + (clientPin != nil ? 1 : 0))
    writer.writeTextString(FidoName.residentKey)
    writer.writeBool(fields.residentKeyAvailability == .supported)
    writer.writeTextString(FidoName.userPresence)
    writer.writeBool(fields.userPresenceRequired)
    if let userVerification {
        writer.writeTextString(FidoName.userVerification)
        writer.writeBool(userVerification)
    }
    writer.writeTextString(FidoName.platformDevice)
    writer.writeBool(fields.isPlatformDevice)
    if let clientPin {
        writer.writeTextString(FidoName.clientPin)
        writer.writeBool(clientPin)
    }

    if let maxMsgSize {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoMaxMsgSizeKey)
        writer.writeInteger(Int64(maxMsgSize))
    }
    if let pinProtocols {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoPinUVAuthProtocolsKey)
        writer.beginArray(count: pinProtocols.size())
        for index in 0..<pinProtocols.size() {
            writer.writeInteger(Int64(pinProtocols[index].rawValue))
        }
    }
    if let maxCredentialCountInList {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoMaxCredentialCountInListKey)
        writer.writeInteger(Int64(maxCredentialCountInList))
    }
    if let maxCredentialIDLength {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoMaxCredentialIdLengthKey)
        writer.writeInteger(Int64(maxCredentialIDLength))
    }
    if let transports {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoTransportsKey)
        writer.beginArray(count: transports.size())
        for index in 0..<transports.size() {
            writer.writeTextString(WebCore.toString(transports[index]))
        }
    }
    if let minPINLength {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoMinPINLengthKey)
        writer.writeInteger(Int64(minPINLength))
    }
    if let remaining {
        writer.writeInteger(fido.kCtapAuthenticatorGetInfoRemainingDiscoverableCredentialsKey)
        writer.writeInteger(Int64(remaining))
    }
    return writer.takeVector()
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
