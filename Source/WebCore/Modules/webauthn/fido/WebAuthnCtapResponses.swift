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

// CTAP2 response decoding.

/// The response code a device response starts with; an empty or unknown one is `ctap2ErrInvalidCBOR`.
private func responseCode(_ bytes: Span<UInt8>) -> fido.CtapDeviceResponseCode {
    if bytes.isEmpty {
        return .ctap2ErrInvalidCBOR
    }
    // init?(rawValue:) of an imported C++ enum never fails; the check is the one above.
    guard let code = fido.CtapDeviceResponseCode(rawValue: bytes[0]) else {
        preconditionFailure("an imported C++ enum's init(rawValue:) never fails")
    }
    return code.isDeviceResponseCode ? code : .ctap2ErrInvalidCBOR
}

/// The CBOR map after a success status byte, as a view of the bytes it was read from.
@_lifetime(copy bytes)
func decodeResponseMap(_ bytes: Span<UInt8>) -> CBORView? {
    if bytes.count <= fido.kResponseCodeLength {
        return nil
    }
    if responseCode(bytes) != .success {
        return nil
    }
    guard let map = CBORView(bytes.extracting(1...)), map.isMap else {
        return nil
    }
    return map
}

/// A big-endian 16-bit length at `offset`; the caller has checked the bounds.
private func readLength16(_ bytes: Span<UInt8>, _ offset: Int) -> Int {
    (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
}

/// The credential ID in authenticator data: empty when the authenticator data has no complete credential ID.
private func credentialID(fromAuthenticatorData authenticatorData: Span<UInt8>) -> cbor.Bytes {
    let credentialIDLengthOffset = WebCore.rpIdHashLength + WebCore.flagsLength + WebCore.signCounterLength + WebCore.aaguidLength
    if authenticatorData.count < credentialIDLengthOffset + WebCore.credentialIdLengthLength {
        return cbor.Bytes()
    }
    let credentialIDLength = readLength16(authenticatorData, credentialIDLengthOffset)
    let start = credentialIDLengthOffset + WebCore.credentialIdLengthLength
    if authenticatorData.count < start + credentialIDLength {
        return cbor.Bytes()
    }
    return makeByteVector(authenticatorData.extracting(start..<(start + credentialIDLength)))
}

/// The prf state that `parseAuthenticatorDataExtensions` builds, as plain values.
private struct PRFState {
    var enabled: Bool?
    /// The decrypted output of the last hmac-secret byte string that decrypted.
    var output: [UInt8]?

    /// Takes what an hmac-secret value says: its flag, or the output of its encrypted bytes.
    mutating func apply(_ value: CBORView, _ hmacSharedKey: WebCore.CryptoKeyAES?, _ pinProtocol: fido.PINUVAuthProtocol) {
        if let flag = value.bool {
            enabled = flag
        } else if let encryptedOutput = value.byteString, let hmacSharedKey {
            if let decrypted = hmacSecretOutput(pinProtocol, hmacSharedKey, encryptedOutput) {
                output = decrypted
            }
        }
    }

    /// The extension outputs, with prf when the response had an hmac-secret flag or output.
    func makeOutputs() -> fido.OptionalClientOutputs {
        var first = cbor.Bytes()
        var second = cbor.Bytes()
        var hasSecond = false
        if let output {
            // first: the first hmacSecretOutputLength bytes (fewer if shorter); second: the next ones, for a dual output.
            first = makeByteVector(Array(output.prefix(WebCore.hmacSecretOutputLength)))
            if output.count == WebCore.hmacSecretDualOutputLength {
                second = makeByteVector(Array(output[WebCore.hmacSecretOutputLength..<WebCore.hmacSecretDualOutputLength]))
                hasSecond = true
            }
        }
        return WebCore.makeClientOutputsWithPRF(enabled != nil, enabled ?? false, output != nil, first, hasSecond, second)
    }
}

/// The prf state of the extensions in `authData`, or nil when it cannot be read; callers then use empty outputs.
private func parseAuthenticatorDataExtensions(
    _ authData: Span<UInt8>,
    _ hmacSharedKey: WebCore.CryptoKeyAES?,
    _ pinProtocol: fido.PINUVAuthProtocol
) -> PRFState? {
    let minAuthDataLength = WebCore.rpIdHashLength + WebCore.flagsLength + WebCore.signCounterLength
    if authData.count < minAuthDataLength {
        return nil
    }

    let flags = authData[WebCore.rpIdHashLength]
    if flags & WebAuthn.extensionDataIncludedFlag == 0 {
        return nil
    }

    var offset = minAuthDataLength
    if flags & WebAuthn.attestedCredentialDataIncludedFlag != 0 {
        offset += WebCore.aaguidLength
        if authData.count < offset + WebCore.credentialIdLengthLength {
            return nil
        }
        let credentialIDLength = readLength16(authData, offset)
        offset += WebCore.credentialIdLengthLength + credentialIDLength
        if authData.count <= offset {
            return nil
        }
        guard let publicKey = CBORView(prefixOf: authData.extracting(offset...)) else {
            return nil
        }
        offset += publicKey.encoded.count
    }

    if authData.count <= offset {
        return nil
    }
    guard let extensionsMap = CBORView(authData.extracting(offset...)), extensionsMap.isMap else {
        return nil
    }

    var state = PRFState()
    // hmac-secret-mc is looked at only when hmac-secret is present.
    guard let hmacSecret = extensionsMap.value(forKey: FidoName.extensionHmacSecret) else {
        return state
    }
    state.apply(hmacSecret, hmacSharedKey, pinProtocol)
    if let hmacSecretMc = extensionsMap.value(forKey: FidoName.extensionHmacSecretMc) {
        state.apply(hmacSecretMc, hmacSharedKey, pinProtocol)
    }
    return state
}

extension fido {
    /// The response code a device response starts with.
    @cxx
    @implementation
    public static func getResponseCode(_ buffer: cbor.Bytes) -> fido.CtapDeviceResponseCode {
        getResponseCodeBody(buffer)
    }

    // The body takes the span: a span of an `@cxx @implementation` parameter does not compile (see WebAuthnApdu.swift).
    private static func getResponseCodeBody(_ buffer: cbor.Bytes) -> fido.CtapDeviceResponseCode {
        responseCode(buffer.span())
    }

    /// Reads a CTAP makeCredential response.
    @cxx
    @implementation
    public static func readCTAPMakeCredentialResponse(
        _ inBuffer: cbor.Bytes,
        _ attachment: WebCore.AuthenticatorAttachment,
        _ transports: fido.TransportVector,
        _ attestation: WebCore.AttestationConveyancePreference,
        _ hmacSharedKey: fido.CryptoKeyAESPtr,
        _ pinProtocol: fido.PINUVAuthProtocol
    ) -> fido.AttestationResponsePtr {
        readMakeCredentialResponse(inBuffer, attachment, transports, attestation, hmacSharedKey, pinProtocol)
    }

    /// Reads a CTAP getAssertion response.
    @cxx
    @implementation
    public static func readCTAPGetAssertionResponse(
        _ inBuffer: cbor.Bytes,
        _ attachment: WebCore.AuthenticatorAttachment,
        _ hmacSharedKey: fido.CryptoKeyAESPtr,
        _ pinProtocol: fido.PINUVAuthProtocol
    ) -> fido.AssertionResponsePtr {
        readGetAssertionResponse(inBuffer, attachment, hmacSharedKey, pinProtocol)
    }

    /// Reads a CTAP getInfo response.
    @cxx
    @implementation
    public static func readCTAPGetInfoResponse(_ inBuffer: cbor.Bytes) -> fido.OptionalGetInfoResponse {
        readGetInfoResponse(inBuffer)
    }
}

/// The attestation object `{"fmt": format, "attStmt": attStatement, "authData": authData}`, the keys in `CTAPLess`
/// order, the format and the statement as they were read.
private func encodeAttestationObject(format: CBORView, attStatement: CBORView, authData: Span<UInt8>) -> cbor.Bytes {
    var writer = CBORWriter(reservingCapacity: authData.count + 64)
    writer.beginMap(count: 3)
    writer.writeTextString(FidoName.format)
    writer.append(encodedItem: format.encoded)
    writer.writeTextString(FidoName.attestationStatement)
    writer.append(encodedItem: attStatement.encoded)
    writer.writeTextString(FidoName.authData)
    writer.writeByteString(authData)
    return writer.takeVector()
}

private func readMakeCredentialResponse(
    _ inBuffer: borrowing cbor.Bytes,
    _ attachment: WebCore.AuthenticatorAttachment,
    _ transports: fido.TransportVector,
    _ attestation: WebCore.AttestationConveyancePreference,
    _ hmacSharedKey: fido.CryptoKeyAESPtr,
    _ pinProtocol: fido.PINUVAuthProtocol
) -> fido.AttestationResponsePtr {
    let bytes: Span<UInt8> = inBuffer.span()
    guard let responseMap = decodeResponseMap(bytes) else {
        return fido.AttestationResponsePtr()
    }
    guard let format = responseMap.value(forKey: fido.kCtapMakeCredentialResponseFormatKey), format.isText else {
        return fido.AttestationResponsePtr()
    }
    guard let authDataItem = responseMap.value(forKey: fido.kCtapMakeCredentialResponseAuthDataKey), let authData = authDataItem.byteString
    else {
        return fido.AttestationResponsePtr()
    }
    let credentialID = credentialID(fromAuthenticatorData: authData)
    if credentialID.isEmpty() {
        return fido.AttestationResponsePtr()
    }
    guard let attStmt = responseMap.value(forKey: fido.kCtapMakeCredentialResponseAttStmtKey), attStmt.isMap else {
        return fido.AttestationResponsePtr()
    }

    let extensions = (parseAuthenticatorDataExtensions(authData, hmacSharedKey.get(), pinProtocol) ?? PRFState()).makeOutputs()

    let attestationObject: cbor.Bytes
    if attestation == .None {
        attestationObject = buildAttestationObject(
            makeByteVector(authData),
            fido.emptyWTFString(),
            makeByteVector([0xa0]),
            attestation,
            .Yes
        )
    } else {
        attestationObject = encodeAttestationObject(format: format, attStatement: attStmt, authData: authData)
    }

    let response = WebCore.AuthenticatorAttestationResponse
        .create(credentialID, attestationObject, consuming: extensions, attachment, consuming: transports).get()
    return fido.AttestationResponsePtr(response)
}

private func readGetAssertionResponse(
    _ inBuffer: borrowing cbor.Bytes,
    _ attachment: WebCore.AuthenticatorAttachment,
    _ hmacSharedKey: fido.CryptoKeyAESPtr,
    _ pinProtocol: fido.PINUVAuthProtocol
) -> fido.AssertionResponsePtr {
    let bytes: Span<UInt8> = inBuffer.span()
    guard let responseMap = decodeResponseMap(bytes) else {
        return fido.AssertionResponsePtr()
    }
    guard let credential = responseMap.value(forKey: fido.kCtapGetAssertionResponseCredentialKey), credential.isMap,
        let credentialIDItem = credential.value(forKey: FidoName.credentialID), let credentialID = credentialIDItem.byteString
    else {
        return fido.AssertionResponsePtr()
    }
    guard let authDataItem = responseMap.value(forKey: fido.kCtapGetAssertionResponseAuthDataKey), let authData = authDataItem.byteString
    else {
        return fido.AssertionResponsePtr()
    }
    guard let signatureItem = responseMap.value(forKey: fido.kCtapGetAssertionResponseSignatureKey),
        let signature = signatureItem.byteString
    else {
        return fido.AssertionResponsePtr()
    }

    // Parse extensions from authenticatorData
    let extensions = (parseAuthenticatorDataExtensions(authData, hmacSharedKey.get(), pinProtocol) ?? PRFState()).makeOutputs()

    var userHandle = cbor.Bytes()
    var name: Swift.String?
    var displayName: Swift.String?
    if let user = responseMap.value(forKey: fido.kCtapGetAssertionResponseUserKey), user.isMap {
        guard let idItem = user.value(forKey: FidoName.entityID), let id = idItem.byteString else {
            return fido.AssertionResponsePtr()
        }
        userHandle = makeByteVector(id)
        if let value = user.value(forKey: FidoName.entityName) {
            guard let string = value.string else {
                return fido.AssertionResponsePtr()
            }
            name = string
        }
        if let value = user.value(forKey: FidoName.displayName) {
            guard let string = value.string else {
                return fido.AssertionResponsePtr()
            }
            displayName = string
        }
    }

    let response = WebCore.AuthenticatorAssertionResponse
        .create(
            makeByteVector(credentialID),
            makeByteVector(authData),
            makeByteVector(signature),
            userHandle,
            consuming: extensions,
            attachment
        )
        .get()
    if let name {
        response.setName(makeWTFString(name))
    }
    if let displayName {
        response.setDisplayName(makeWTFString(displayName))
    }
    if let value = responseMap.value(forKey: fido.kCtapGetAssertionResponseNumberOfCredentialsKey), let numberOfCredentials = value.unsigned
    {
        response.setNumberOfCredentials(Int(numberOfCredentials))
    }
    return fido.AssertionResponsePtr(response)
}

/// A getInfo response that `readCTAPGetInfoResponse` rejects.
private struct MalformedGetInfoResponse: Error {}

private func readGetInfoResponse(_ inBuffer: borrowing cbor.Bytes) -> fido.OptionalGetInfoResponse {
    let bytes: Span<UInt8> = inBuffer.span()
    guard let responseMap = decodeResponseMap(bytes) else {
        return noGetInfoResponse()
    }

    var fields = fido.GetInfoResponseFields()
    do {
        try readVersions(responseMap, into: &fields)
        try readAAGUID(responseMap, into: &fields)
        try readExtensions(responseMap, into: &fields)
        try readOptions(responseMap, into: &fields)
        fields.maxMsgSize = try readUInt32(responseMap, fido.kCtapAuthenticatorGetInfoMaxMsgSizeKey)
        try readPinProtocols(responseMap, into: &fields)
        fields.maxCredentialCountInList = try readUInt32(responseMap, fido.kCtapAuthenticatorGetInfoMaxCredentialCountInListKey)
        fields.maxCredentialIDLength = try readUInt32(responseMap, fido.kCtapAuthenticatorGetInfoMaxCredentialIdLengthKey)
        try readTransports(responseMap, into: &fields)
        fields.minPINLength = try readUInt32(responseMap, fido.kCtapAuthenticatorGetInfoMinPINLengthKey)
        fields.remainingDiscoverableCredentials = try readUInt32(
            responseMap,
            fido.kCtapAuthenticatorGetInfoRemainingDiscoverableCredentialsKey
        )
    } catch {
        return noGetInfoResponse()
    }
    return fido.makeGetInfoResponse(consuming: fields)
}

/// The unsigned integer at `key`, narrowed as the `uint32_t` setters narrow `getUnsigned()`; none when there is no entry.
private func readUInt32(_ responseMap: CBORView, _ key: Int64) throws(MalformedGetInfoResponse) -> fido.OptionalUInt32 {
    guard let value = responseMap.value(forKey: key) else {
        return fido.OptionalUInt32()
    }
    guard let number = value.unsigned else {
        throw MalformedGetInfoResponse()
    }
    return fido.OptionalUInt32(UInt32(truncatingIfNeeded: number))
}

private func readVersions(_ responseMap: CBORView, into fields: inout fido.GetInfoResponseFields) throws(MalformedGetInfoResponse) {
    guard let versionsItem = responseMap.value(forKey: fido.kCtapAuthenticatorGetInfoVersionsKey), var versions = versionsItem.elements
    else {
        throw MalformedGetInfoResponse()
    }
    // StdSet<ProtocolVersion>: kept in enum order.
    var protocolVersions: [fido.ProtocolVersion] = []
    while let version = versions.next() {
        guard version.isText else {
            throw MalformedGetInfoResponse()
        }
        let protocolVersion = protocolVersionNamed(by: version)
        if protocolVersion == .unknown {
            continue
        }
        if protocolVersions.contains(protocolVersion) {
            throw MalformedGetInfoResponse()
        }
        protocolVersions.append(protocolVersion)
    }
    if protocolVersions.isEmpty {
        throw MalformedGetInfoResponse()
    }
    protocolVersions.sort { $0.rawValue < $1.rawValue }
    for protocolVersion in protocolVersions {
        fields.versions.append(consuming: protocolVersion)
    }
}

private func readAAGUID(_ responseMap: CBORView, into fields: inout fido.GetInfoResponseFields) throws(MalformedGetInfoResponse) {
    guard let aaguidItem = responseMap.value(forKey: fido.kCtapAuthenticatorGetInfoAAGUIDKey), let aaguid = aaguidItem.byteString,
        aaguid.count == WebCore.aaguidLength
    else {
        throw MalformedGetInfoResponse()
    }
    fields.aaguid = makeByteVector(aaguid)
}

private func readExtensions(_ responseMap: CBORView, into fields: inout fido.GetInfoResponseFields) throws(MalformedGetInfoResponse) {
    guard let value = responseMap.value(forKey: fido.kCtapAuthenticatorGetInfoExtensionsKey) else {
        return
    }
    guard var extensions = value.elements else {
        throw MalformedGetInfoResponse()
    }
    var extensionNames = fido.StringVector()
    while let extensionName = extensions.next() {
        guard let string = extensionName.string else {
            throw MalformedGetInfoResponse()
        }
        extensionNames.append(consuming: makeWTFString(string))
    }
    fields.extensions = fido.OptionalStringVector(extensionNames)
}

/// The boolean option at `key`; nil when there is no entry.
private func readOption(_ options: CBORView, _ key: Swift.String) throws(MalformedGetInfoResponse) -> Bool? {
    guard let option = options.value(forKey: key) else {
        return nil
    }
    guard let flag = option.bool else {
        throw MalformedGetInfoResponse()
    }
    return flag
}

private func readOptions(_ responseMap: CBORView, into fields: inout fido.GetInfoResponseFields) throws(MalformedGetInfoResponse) {
    guard let options = responseMap.value(forKey: fido.kCtapAuthenticatorGetInfoOptionsKey) else {
        return
    }
    guard options.isMap else {
        throw MalformedGetInfoResponse()
    }
    if let flag = try readOption(options, FidoName.platformDevice) {
        fields.isPlatformDevice = flag
    }
    if let flag = try readOption(options, FidoName.residentKey) {
        fields.residentKeyAvailability = flag ? .supported : .notSupported
    }
    if let flag = try readOption(options, FidoName.userPresence) {
        fields.userPresenceRequired = flag
    }
    if let flag = try readOption(options, FidoName.userVerification) {
        fields.userVerificationAvailability = flag ? .supportedAndConfigured : .supportedButNotConfigured
    }
    if let flag = try readOption(options, FidoName.clientPin) {
        fields.clientPinAvailability = flag ? .supportedAndPinSet : .supportedButPinNotSet
    }
}

private func readPinProtocols(_ responseMap: CBORView, into fields: inout fido.GetInfoResponseFields) throws(MalformedGetInfoResponse) {
    guard let value = responseMap.value(forKey: fido.kCtapAuthenticatorGetInfoPinUVAuthProtocolsKey) else {
        return
    }
    guard var protocols = value.elements else {
        throw MalformedGetInfoResponse()
    }
    // StdSet<PINUVAuthProtocol>: 1 before 2, each once; unknown protocols are ignored.
    var hasProtocol1 = false
    var hasProtocol2 = false
    while let protocolValue = protocols.next() {
        guard let number = protocolValue.unsigned else {
            throw MalformedGetInfoResponse()
        }
        if number == Int64(fido.PINUVAuthProtocol.pinProtocol1.rawValue) {
            hasProtocol1 = true
        } else if number == Int64(fido.PINUVAuthProtocol.pinProtocol2.rawValue) {
            hasProtocol2 = true
        }
    }
    var pinProtocols = fido.PinProtocolVector()
    if hasProtocol1 {
        pinProtocols.append(consuming: .pinProtocol1)
    }
    if hasProtocol2 {
        pinProtocols.append(consuming: .pinProtocol2)
    }
    fields.pinProtocols = fido.OptionalPinProtocolVector(pinProtocols)
}

private func readTransports(_ responseMap: CBORView, into fields: inout fido.GetInfoResponseFields) throws(MalformedGetInfoResponse) {
    guard let value = responseMap.value(forKey: fido.kCtapAuthenticatorGetInfoTransportsKey) else {
        return
    }
    guard var transports = value.elements else {
        throw MalformedGetInfoResponse()
    }
    var transportList = fido.TransportVector()
    while let transportName = transports.next() {
        guard let string = transportName.string else {
            throw MalformedGetInfoResponse()
        }
        if let transport = Optional(fromCxx: WebCore.convertStringToAuthenticatorTransport(makeWTFString(string))) {
            transportList.append(consuming: transport)
        }
    }
    fields.transports = fido.OptionalTransportVector(transportList)
}

/// A response with no value, which `makeGetInfoResponse` gives for an empty versions list.
private func noGetInfoResponse() -> fido.OptionalGetInfoResponse {
    fido.makeGetInfoResponse(consuming: fido.GetInfoResponseFields())
}

/// The protocol version a text string stands for, against FidoConstants.h's names.
private func protocolVersionNamed(by name: CBORView) -> fido.ProtocolVersion {
    if name.textEquals(FidoName.ctap21Version) {
        return .ctap21
    }
    if name.textEquals(FidoName.ctap21PreVersion) {
        return .ctap21Pre
    }
    if name.textEquals(FidoName.ctap2Version) {
        return .ctap2
    }
    if name.textEquals(FidoName.u2fVersion) {
        return .u2f
    }
    return .unknown
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
