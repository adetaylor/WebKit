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
internal import WebCore_Private.Core.CBORBytes
internal import WebCore_Private.Core.WebAuthenticationConstants
internal import WebCore_Private.Core.WebAuthenticationUtils
internal import WebCore_Private.Core.WebAuthnSwiftTypes

// Each `&+` in this file adds sizes of buffers in memory and small constants: the sum cannot overflow.

/// A SHA-256 hash of the given RP ID.
public func produceRpIdHash(_ rpId: WTF.String) -> cbor.Bytes {
    var sink = fido.WebAuthnByteSink()
    sink.reserve(Int(rpId.length()))
    emitUTF8(of: rpId) { sink.addByte($0) }
    return fido.pin.pinSHA256(sink.take())
}

/// The COSE_Key of an ES256 public key, encoded.
public func encodeES256PublicKeyAsCBOR(_ x: cbor.Bytes, _ y: cbor.Bytes) -> cbor.Bytes {
    var writer = CBORWriter(reservingCapacity: 24 &+ x.size() &+ y.size())
    writer.beginMap(count: 5)
    writer.writeInteger(COSE.kty)
    writer.writeInteger(COSE.EC2)
    writer.writeInteger(COSE.alg)
    writer.writeInteger(COSE.ES256)
    writer.writeInteger(COSE.crv)
    writer.writeInteger(COSE.P_256)
    writer.writeInteger(COSE.x)
    writer.writeByteString(x.span())
    writer.writeInteger(COSE.y)
    writer.writeByteString(y.span())
    return writer.takeVector()
}

/// The attested credential data of an authenticator data.
///
/// https://www.w3.org/TR/webauthn/#attested-credential-data
public func buildAttestedCredentialData(_ aaguid: cbor.Bytes, _ credentialID: cbor.Bytes, _ coseKey: cbor.Bytes) -> cbor.Bytes {
    var data = fido.WebAuthnByteSink()
    data.reserve(WebCore.aaguidLength &+ WebCore.credentialIdLengthLength &+ credentialID.size() &+ coseKey.size())

    // aaguid
    assert(aaguid.size() == WebCore.aaguidLength)
    data.append(aaguid.span())

    // credentialIdLength
    assert(credentialID.size() <= Int(UInt16.max))
    data.addByte(UInt8(truncatingIfNeeded: credentialID.size() >> 8))
    data.addByte(UInt8(truncatingIfNeeded: credentialID.size()))

    // credentialId
    data.append(credentialID.span())

    // credentialPublicKey
    data.append(coseKey.span())
    return data.take()
}

/// The authenticator data: the RP ID hash, flags, signature counter and any attested credential data.
///
/// https://www.w3.org/TR/webauthn/#sec-authenticator-data
public func buildAuthData(_ rpId: WTF.String, _ flags: UInt8, _ counter: UInt32, _ optionalAttestedCredentialData: cbor.Bytes) -> cbor.Bytes
{
    var data = fido.WebAuthnByteSink()
    data.reserve(WebCore.rpIdHashLength &+ WebCore.flagsLength &+ WebCore.signCounterLength &+ optionalAttestedCredentialData.size())

    // RP ID hash
    let rpIDHash = produceRpIdHash(rpId)
    data.append(rpIDHash.span())

    // FLAGS
    data.addByte(flags)

    // COUNTER
    data.addByte(UInt8(truncatingIfNeeded: counter >> 24))
    data.addByte(UInt8(truncatingIfNeeded: counter >> 16))
    data.addByte(UInt8(truncatingIfNeeded: counter >> 8))
    data.addByte(UInt8(truncatingIfNeeded: counter))

    // ATTESTED CRED. DATA
    data.append(optionalAttestedCredentialData.span())
    return data.take()
}

/// The user entity map {"id", "name", "displayName"}, encoded.
public func buildUserEntityMap(_ userID: cbor.Bytes, _ name: WTF.String, _ displayName: WTF.String) -> cbor.Bytes {
    var writer = CBORWriter(reservingCapacity: 32 &+ userID.size())
    writer.beginMap(count: 3)
    writer.writeTextString(FidoName.entityID)
    writer.writeByteString(userID.span())
    writer.writeTextString(FidoName.entityName)
    writer.writeTextString(name)
    writer.writeTextString(FidoName.displayName)
    writer.writeTextString(displayName)
    return writer.takeVector()
}

/// The credential descriptor map {"id"}, encoded.
public func buildCredentialDescriptor(_ credentialID: cbor.Bytes) -> cbor.Bytes {
    var writer = CBORWriter(reservingCapacity: 8 &+ credentialID.size())
    writer.beginMap(count: 1)
    writer.writeTextString(FidoName.credentialID)
    writer.writeByteString(credentialID.span())
    return writer.takeVector()
}

extension CBORView {
    /// How many levels of arrays and maps lie below this item: 0 for a scalar and for an empty array or map.
    fileprivate var nestingDepth: Int {
        var deepest = 0
        if var elements {
            while let element = elements.next() {
                deepest = max(deepest, 1 + element.nestingDepth)
            }
        } else if var entries {
            while let entry = entries.next() {
                deepest = max(deepest, 1 + entry.value.nestingDepth)
            }
        }
        return deepest
    }
}

/// The most levels of nesting a map embedded in another (an attestation statement, a credential's tag) can have: the
/// writer allows 16 levels and the embedded map is the second.
private let maxEmbeddedMapNestingDepth = 15

/// The attestation object: the format, statement and authenticator data, as the attestation conveyance preference allows.
///
/// https://www.w3.org/TR/webauthn/#attestation-object
///
/// `statementMap` is one encoded map; empty bytes when it is not one or cannot be read. A statement that nests too deeply
/// for the writer (more than 16 levels of maps and arrays, counting the object's own map) traps: where the C++ writer
/// gives no result, its caller dereferences the empty result.
public func buildAttestationObject(
    _ authData: cbor.Bytes,
    _ format: WTF.String,
    _ statementMap: cbor.Bytes,
    _ attestation: WebCore.AttestationConveyancePreference,
    _ shouldZeroAAGUID: WebCore.ShouldZeroAAGUID = .No
) -> cbor.Bytes {
    var writer = CBORWriter(reservingCapacity: 40 &+ authData.size() &+ statementMap.size())
    writer.beginMap(count: 3)
    // The following implements Step 20 with regard to AttestationConveyancePreference
    // of https://www.w3.org/TR/webauthn/#createCredential as of 4 March 2019.
    // None attestation is always returned if it is requested to keep consistency, and therefore skip the
    // step to return self attestation.
    if attestation == .None {
        var data = makeByteArray(authData)
        let aaguidOffset = WebCore.rpIdHashLength + WebCore.flagsLength + WebCore.signCounterLength
        if data.count >= aaguidOffset + WebCore.aaguidLength && shouldZeroAAGUID == .Yes {
            for index in aaguidOffset..<(aaguidOffset + WebCore.aaguidLength) {
                data[index] = 0
            }
        }
        writer.writeTextString("fmt")
        writer.writeTextString("none")
        writer.writeTextString("attStmt")
        writer.beginMap(count: 0)
        writer.writeTextString("authData")
        writer.writeByteString(data.span)
        return writer.takeVector()
    }
    guard let statement = CBORView(statementMap.span()) else {
        // What the reader cannot read for its depth the writer could not write either.
        precondition(
            CBORDecoder.read(statementMap.span(), maxNestingLevel: cbor.kCBORMaxDepth, allowTrailingData: false).error != .TooMuchNesting,
            "An attestation statement that nests too deeply"
        )
        return cbor.Bytes()
    }
    guard statement.isMap else {
        return cbor.Bytes()
    }
    precondition(statement.nestingDepth <= maxEmbeddedMapNestingDepth, "An attestation statement that nests too deeply")
    writer.writeTextString("fmt")
    writer.writeTextString(format)
    writer.writeTextString("attStmt")
    writer.append(encodedItem: statement.encoded)
    writer.writeTextString("authData")
    writer.writeByteString(authData.span())
    return writer.takeVector()
}

/// The encoded user entity map with the large blob stored under its key, or nil when it is not a map.
public func userEntityMapWithLargeBlob(_ userEntityMap: cbor.Bytes, _ largeBlob: cbor.Bytes) -> cbor.Bytes? {
    guard let map = CBORView(userEntityMap.span()), map.isMap else {
        return nil
    }
    var blobWriter = CBORWriter(reservingCapacity: 8 &+ largeBlob.size())
    blobWriter.writeByteString(largeBlob.span())
    let encodedBlob = blobWriter.takeBytes()
    var writer = CBORWriter(reservingCapacity: userEntityMap.size() &+ encodedBlob.count &+ 16)
    writer.append(map, settingTextKey: "largeBlob", toEncodedItem: encodedBlob.span)
    return writer.takeVector()
}

/// The large blob stored in an encoded user entity map, or nil when it holds none.
public func largeBlobFromUserEntityMap(_ userEntityMap: cbor.Bytes) -> cbor.Bytes? {
    guard let map = CBORView(userEntityMap.span()), let item = map.value(forKey: "largeBlob"), let largeBlob = item.byteString else {
        return nil
    }
    return makeByteVector(largeBlob)
}

/// The encoded user entity map with the entry for `key` set to `value`, or removed when `value` is null; nil when
/// the map cannot be read.
private func replacingUserEntityString(
    _ userEntityMap: cbor.Bytes,
    setting key: Swift.String,
    to value: borrowing WTF.String
) -> cbor.Bytes? {
    guard let map = CBORView(userEntityMap.span()), map.isMap else {
        return nil
    }
    var writer = CBORWriter(reservingCapacity: userEntityMap.size() &+ 16)
    if value.isNull() {
        writer.append(map, settingTextKey: key, toEncodedItem: nil)
    } else {
        var valueWriter = CBORWriter(reservingCapacity: 16)
        valueWriter.writeTextString(value)
        let encodedValue = valueWriter.takeBytes()
        writer.append(map, settingTextKey: key, toEncodedItem: encodedValue.span)
    }
    return writer.takeVector()
}

/// The encoded user entity map with its name replaced, or nil when it is not a map.
public func userEntityMapReplacingName(_ userEntityMap: cbor.Bytes, _ name: WTF.String) -> cbor.Bytes? {
    replacingUserEntityString(userEntityMap, setting: FidoName.entityName, to: name)
}

/// The encoded user entity map with its display name replaced, or nil when it is not a map.
public func userEntityMapReplacingDisplayName(_ userEntityMap: cbor.Bytes, _ displayName: WTF.String) -> cbor.Bytes? {
    replacingUserEntityString(userEntityMap, setting: FidoName.displayName, to: displayName)
}

/// A credential exported from or imported into the local authenticator's Keychain.
public struct LocalCredentialBlob {
    /// The private key's encoding.
    public var privateKey: cbor.Bytes
    /// The Keychain key type.
    public var keyType: Int64
    /// The key size in bits.
    public var keySize: Int64
    /// The relying party the credential belongs to.
    public var relyingParty: WTF.String
    /// The Keychain application tag.
    public var applicationTag: cbor.Bytes

    /// Creates a blob from its parts.
    public init(privateKey: cbor.Bytes, keyType: Int64, keySize: Int64, relyingParty: WTF.String, applicationTag: cbor.Bytes) {
        self.privateKey = privateKey
        self.keyType = keyType
        self.keySize = keySize
        self.relyingParty = relyingParty
        self.applicationTag = applicationTag
    }
}

/// The encoded credential blob, or nil when its tag is not a map or the blob nests too deeply.
public func encodeLocalCredentialBlob(_ blob: LocalCredentialBlob) -> cbor.Bytes? {
    guard let tag = CBORView(blob.applicationTag.span()), tag.isMap, tag.nestingDepth <= maxEmbeddedMapNestingDepth else {
        return nil
    }
    // The keys in `ctapLess` order: by length, then by character.
    var writer = CBORWriter(reservingCapacity: 64 &+ blob.privateKey.size() &+ tag.encoded.count)
    writer.beginMap(count: 5)
    writer.writeTextString("rp")
    writer.writeTextString(blob.relyingParty)
    writer.writeTextString("tag")
    writer.append(encodedItem: tag.encoded)
    writer.writeTextString("priv")
    writer.writeByteString(blob.privateKey.span())
    writer.writeTextString("key_size")
    writer.writeInteger(blob.keySize)
    writer.writeTextString("key_type")
    writer.writeInteger(blob.keyType)
    return writer.takeVector()
}

/// The credential an encoded blob holds, or nil when it is not one.
public func decodeLocalCredentialBlob(_ bytes: cbor.Bytes) -> LocalCredentialBlob? {
    decodeLocalCredentialBlob(bytes.span())
}

/// The credential an encoded blob holds, or nil when it is not one.
public func decodeLocalCredentialBlob(_ bytes: Span<UInt8>) -> LocalCredentialBlob? {
    guard let map = CBORView(bytes),
        let privateKeyItem = map.value(forKey: "priv"), let privateKey = privateKeyItem.byteString,
        let keyTypeItem = map.value(forKey: "key_type"), let keyType = keyTypeItem.integer,
        let keySizeItem = map.value(forKey: "key_size"), let keySize = keySizeItem.integer,
        let relyingPartyItem = map.value(forKey: "rp"), let relyingParty = relyingPartyItem.string,
        let tag = map.value(forKey: "tag"), tag.isMap
    else {
        return nil
    }
    return LocalCredentialBlob(
        privateKey: makeByteVector(privateKey),
        keyType: keyType,
        keySize: keySize,
        relyingParty: makeWTFString(relyingParty),
        applicationTag: makeByteVector(tag.encoded)
    )
}

extension WebCore {
    /// Decodes the options of a mock request for `command`.
    @cxx
    @implementation
    public static func decodeMockRequestOptions(
        _ request: cbor.Bytes,
        _ command: fido.CtapRequestCommand
    ) -> WebCore.OptionalMockRequestOptions {
        decodeMockRequestOptionsBody(request, command)
    }

    // The body takes the bytes: a span of an `@cxx @implementation` parameter does not compile (see WebAuthnApdu.swift).
    private static func decodeMockRequestOptionsBody(
        _ request: cbor.Bytes,
        _ command: fido.CtapRequestCommand
    ) -> WebCore.OptionalMockRequestOptions {
        let data: Span<UInt8> = request.span()
        guard let requestMap = CBORView(data) else {
            return WebCore.OptionalMockRequestOptions()
        }
        var options = WebCore.MockRequestOptions()
        // A field of the wrong CBOR type traps.
        let optionsKey: Int64
        switch command {
        case .authenticatorMakeCredential:
            optionsKey = fido.kCtapMakeCredentialRequestOptionsKey
        case .authenticatorGetAssertion:
            optionsKey = fido.kCtapGetAssertionRequestOptionsKey
        default:
            return WebCore.OptionalMockRequestOptions(options)
        }
        guard requestMap.isMap else {
            preconditionFailure("CTAP2 request of the wrong CBOR type")
        }
        if let optionMap = requestMap.value(forKey: optionsKey) { // Find options.
            guard optionMap.isMap else {
                preconditionFailure("CTAP2 request field of the wrong CBOR type")
            }
            if command == .authenticatorMakeCredential, let residentKey = optionMap.value(forKey: FidoName.residentKey) {
                guard let requireResidentKey = residentKey.bool else {
                    preconditionFailure("CTAP2 request field of the wrong CBOR type")
                }
                options.requireResidentKey = WebCore.OptionalBool(requireResidentKey)
            }
            if let userVerification = optionMap.value(forKey: FidoName.userVerification) {
                guard let requireUserVerification = userVerification.bool else {
                    preconditionFailure("CTAP2 request field of the wrong CBOR type")
                }
                options.requireUserVerification = WebCore.OptionalBool(requireUserVerification)
            }
        }
        return WebCore.OptionalMockRequestOptions(options)
    }
}

// The client data JSON of https://www.w3.org/TR/webauthn-2/#clientdatajson-verification, as `JSON::Object::toJSONString`
// writes it: the members in insertion order, no space, strings escaped as `appendQuotedJSONString` does and then as UTF-8.

/// `value` as a quoted JSON string in UTF-8: `"`, `\` and the control characters escaped (the short forms for
/// backspace, tab, line feed, form feed and carriage return, `\u00xx` for the rest), an unpaired surrogate as
/// `\uxxxx`, and every other character as UTF-8.
private func appendQuotedJSONString(_ value: borrowing WTF.String, to output: inout [UInt8]) {
    let units = utf16Units(of: value)
    output.reserveCapacity(output.count &+ units.count &+ 2)
    output.append(UInt8(ascii: "\""))
    var index = 0
    while index < units.count {
        let unit = units[index]
        index += 1
        switch unit {
        case 0x22:
            appendShortEscape("\"", to: &output)
        case 0x5C:
            appendShortEscape("\\", to: &output)
        case 0x08:
            appendShortEscape("b", to: &output)
        case 0x09:
            appendShortEscape("t", to: &output)
        case 0x0A:
            appendShortEscape("n", to: &output)
        case 0x0C:
            appendShortEscape("f", to: &output)
        case 0x0D:
            appendShortEscape("r", to: &output)
        case 0x00...0x1F:
            appendEscapedUnit(unit, to: &output)
        case 0x20...0x7F:
            output.append(UInt8(truncatingIfNeeded: unit))
        case 0xD800...0xDFFF:
            if unit < 0xDC00, index < units.count, units[index] & 0xFC00 == 0xDC00 {
                let scalar = 0x10000 &+ ((UInt32(unit) &- 0xD800) << 10) &+ (UInt32(units[index]) &- 0xDC00)
                index += 1
                emitUTF8(scalar: scalar) { output.append($0) }
            } else {
                appendEscapedUnit(unit, to: &output)
            }
        default:
            emitUTF8(scalar: UInt32(unit)) { output.append($0) }
        }
    }
    output.append(UInt8(ascii: "\""))
}

/// `\` and `character`, the short form of an escape.
@inline(always)
private func appendShortEscape(_ character: Unicode.Scalar, to output: inout [UInt8]) {
    output.append(UInt8(ascii: "\\"))
    output.append(UInt8(ascii: character))
}

/// `\uxxxx` for `unit`, with lowercase hexadecimal digits.
private func appendEscapedUnit(_ unit: UInt16, to output: inout [UInt8]) {
    output.append(UInt8(ascii: "\\"))
    output.append(UInt8(ascii: "u"))
    for shift in stride(from: 12, through: 0, by: -4) {
        let nibble = UInt8(truncatingIfNeeded: unit >> UInt16(shift) & 0xF)
        output.append(nibble < 10 ? UInt8(ascii: "0") &+ nibble : UInt8(ascii: "a") &+ (nibble &- 10))
    }
}

/// The body of `buildClientDataJson`, which forwards here.
///
/// `challenge` is the challenge in base64url, `origin` the origin's serialization, and `topOrigin` the top origin's, or a
/// null string when the request has none.
@_expose(Cxx)
func webAuthnClientDataJSON(
    _ type: WebCore.ClientDataType,
    _ challenge: consuming WTF.String,
    _ origin: consuming WTF.String,
    _ scope: WebAuthn.Scope,
    _ topOrigin: consuming WTF.String
) -> cbor.Bytes {
    var json: [UInt8] = []
    switch type {
    case .Create:
        json.append(contentsOf: "{\"type\":\"webauthn.create\",\"challenge\":".utf8)
    case .Get:
        json.append(contentsOf: "{\"type\":\"webauthn.get\",\"challenge\":".utf8)
    @unknown default:
        json.append(contentsOf: "{\"type\":\"webauthn.get\",\"challenge\":".utf8)
    }
    appendQuotedJSONString(challenge, to: &json)
    json.append(contentsOf: ",\"origin\":".utf8)
    appendQuotedJSONString(origin, to: &json)
    if scope != .SameOrigin {
        json.append(contentsOf: ",\"crossOrigin\":true".utf8)
    }
    if !topOrigin.isNull() {
        json.append(contentsOf: ",\"topOrigin\":".utf8)
        appendQuotedJSONString(topOrigin, to: &json)
    }
    json.append(UInt8(ascii: "}"))
    return makeByteVector(json)
}

/// The body of `buildClientDataJsonHash`, which forwards here: the SHA-256 of the client data JSON.
///
/// `clientData` is the span of the caller's `ArrayBuffer`: it stays allocated, at its length, for the call, nothing here
/// or in the C++ it calls writes it, and its bytes have no invalid bit patterns.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func webAuthnClientDataHash(_ clientData: cbor.ByteSpan) -> cbor.Bytes {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: clientData)
    var sink = fido.WebAuthnByteSink()
    sink.reserve(data.count)
    sink.append(data)
    return fido.pin.pinSHA256(sink.take())
}

// MARK: The transports and the cross-device fallback URL

/// WebAuthenticationConstants.h's `authenticatorTransport*` (ASCIILiteral, which does not import).
///
/// Each literal is pinned by a static_assert in WebAuthenticationUtils.cpp.
private enum AuthenticatorTransportName {
    static let usb = "usb"
    static let nfc = "nfc"
    static let ble = "ble"
    static let `internal` = "internal"
    static let cable = "cable"
    static let hybrid = "hybrid"
    static let smartCard = "smart-card"
}

/// The body of `toString(AuthenticatorTransport)`, which forwards here: the transport's name, or a null string for a
/// value that is none of the transports.
@_expose(Cxx)
func webAuthnTransportString(_ transport: WebCore.AuthenticatorTransport) -> WTF.String {
    let name: Swift.String
    switch transport {
    case .Usb: name = AuthenticatorTransportName.usb
    case .Nfc: name = AuthenticatorTransportName.nfc
    case .Ble: name = AuthenticatorTransportName.ble
    case .Internal: name = AuthenticatorTransportName.internal
    case .Cable: name = AuthenticatorTransportName.cable
    case .Hybrid: name = AuthenticatorTransportName.hybrid
    case .SmartCard: name = AuthenticatorTransportName.smartCard
    default:
        assertionFailure()
        return WTF.String()
    }
    return makeWTFString(name)
}

/// The body of `convertStringToAuthenticatorTransport`, which forwards here: the transport named exactly `name`, or
/// none.
@_expose(Cxx)
func webAuthnTransport(_ name: consuming WTF.String) -> WebCore.OptionalAuthenticatorTransport {
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.usb) {
        return .init(.Usb)
    }
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.nfc) {
        return .init(.Nfc)
    }
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.ble) {
        return .init(.Ble)
    }
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.internal) {
        return .init(.Internal)
    }
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.cable) {
        return .init(.Cable)
    }
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.hybrid) {
        return .init(.Hybrid)
    }
    if webAuthnEqualsASCII(name, AuthenticatorTransportName.smartCard) {
        return .init(.SmartCard)
    }
    return .init()
}

/// The body of `validateCrossDeviceFallbackURL`, which forwards here: why `url` can't be used as the
/// crossDeviceFallbackUrl extension input, or none if it can.
@_expose(Cxx)
func webAuthnCrossDeviceFallbackURLError(_ url: consuming WTF.URL) -> WebCore.OptionalWebAuthnString {
    if !url.isValid() || !fido.webAuthnURLIsHTTPS(url) {
        return .init(makeWTFString("The cross-device fallback URL is not a valid https URL."))
    }
    if fido.webAuthnURLHostIsEmptyOrIPAddress(url) {
        return .init(makeWTFString("The effective domain of the cross-device fallback URL is not a valid domain."))
    }
    return .init()
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
