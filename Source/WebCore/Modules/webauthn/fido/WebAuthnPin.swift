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

// CTAP2 PIN protocol: requests, responses and the hmac-secret extension.
// https://fidoalliance.org/specs/fido-v2.1-ps-20210615/fido-client-to-authenticator-protocol-v2.1-ps-20210615.html#authnrClientPin-cmd

// A protocol 2 shared secret is an HMAC key then an AES key, 32 bytes each; its ciphertexts start with a 16-byte IV.
private let pinSharedKeyLength = 32
private let pinIVLength = 16
// Protocol 1 truncates HMACs to their left 16 bytes, as it does the PIN hash.
private let pinProtocol1AuthLength = 16
// SetPin pads the new PIN with zeros to 64 bytes.
private let pinPaddedLength = 64

/// The value, trapping on null as the C++ does when it dereferences the pointer.
private func nonNull<T>(_ value: T?) -> T {
    guard let value else {
        preconditionFailure("unexpected null pointer")
    }
    return value
}

/// The bytes of `first`, then those of `second`.
private func concatenation(_ first: borrowing cbor.Bytes, _ second: borrowing cbor.Bytes) -> cbor.Bytes {
    var sink = fido.WebAuthnByteSink()
    sink.reserve(first.size() + second.size())
    sink.append(first.span())
    sink.append(second.span())
    return sink.take()
}

private func decryptForProtocol(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ key: borrowing WebCore.CryptoKeyAES,
    _ ciphertext: borrowing cbor.Bytes
) -> cbor.Bytes {
    if pinProtocol == .pinProtocol2 {
        // Protocol 2: the IV, then the ciphertext.
        let size = ciphertext.size()
        if size < pinIVLength {
            return cbor.Bytes()
        }
        return fido.pin.pinAESCBCDecrypt(key, ciphertext.subvector(0, pinIVLength), ciphertext.subvector(pinIVLength, size - pinIVLength))
    }
    // Protocol 1: a zero IV.
    return fido.pin.pinAESCBCDecrypt(key, cbor.Bytes(), ciphertext)
}

private func encryptForProtocol(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ key: borrowing WebCore.CryptoKeyAES,
    _ plaintext: borrowing cbor.Bytes
) -> cbor.Bytes {
    if pinProtocol == .pinProtocol2 {
        // Protocol 2: a random IV, prepended.
        let iv = fido.pin.pinRandomIV()
        return concatenation(iv, fido.pin.pinAESCBCEncrypt(key, iv, plaintext))
    }
    return fido.pin.pinAESCBCEncrypt(key, cbor.Bytes(), plaintext)
}

private func authenticateForProtocol(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ key: borrowing WebCore.CryptoKeyHMAC,
    _ message: borrowing cbor.Bytes
) -> cbor.Bytes {
    var signature = fido.pin.pinHMACSign(key, message)
    if pinProtocol == .pinProtocol1 {
        signature.shrink(pinProtocol1AuthLength)
    }
    return signature
}

// CTAP 2.1 6.5.6 (protocol 1: SHA-256) and 6.5.7 (protocol 2: HKDF-SHA-256 for the HMAC key, then the AES key).
// Empty when a step fails.
private func deriveProtocolSharedSecret(_ pinProtocol: fido.PINUVAuthProtocol, _ ecdhResult: borrowing cbor.Bytes) -> cbor.Bytes {
    switch pinProtocol {
    case .pinProtocol1:
        return fido.pin.pinSHA256(ecdhResult)
    case .pinProtocol2:
        let hmacKey = fido.pin.pinHKDF(ecdhResult, .HMACKey)
        if hmacKey.isEmpty() {
            return hmacKey
        }
        let aesKey = fido.pin.pinHKDF(ecdhResult, .AESKey)
        if aesKey.isEmpty() {
            return aesKey
        }
        return concatenation(hmacKey, aesKey)
    default:
        return cbor.Bytes()
    }
}

private func importAESKey(_ material: consuming cbor.Bytes) -> fido.CryptoKeyAESPtr {
    WebCore.CryptoKeyAES.importRaw(
        .AES_CBC,
        consuming: material,
        true,
        WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageEncrypt | WebCore.CryptoKeyUsageDecrypt)
    )
}

private func importHMACKey(_ material: consuming cbor.Bytes) -> fido.CryptoKeyHMACPtr {
    let lengthInBits = material.size() * 8
    return WebCore.CryptoKeyHMAC.importRaw(
        lengthInBits,
        .SHA_256,
        consuming: material,
        true,
        WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageSign)
    )
}

// The halves of the shared secret a protocol uses for HMAC and AES keys: protocol 2 splits it, protocol 1 uses it whole.
private func sharedSecretHalves(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ sharedSecret: borrowing cbor.Bytes
) -> (hmac: cbor.Bytes, aes: cbor.Bytes) {
    if pinProtocol == .pinProtocol2 {
        let size = sharedSecret.size()
        return (sharedSecret.subvector(0, pinSharedKeyLength), sharedSecret.subvector(size - pinSharedKeyLength, pinSharedKeyLength))
    }
    return (copy sharedSecret, copy sharedSecret)
}

// The authenticatorClientPin command byte, then the head of the CBOR map of protocol and subcommand,
// which `additionalEntries` more entries (with keys above both) follow.
private func beginPinCommand(
    _ writer: inout CBORWriter,
    _ subcommand: fido.pin.Subcommand,
    _ pinProtocol: fido.PINUVAuthProtocol,
    additionalEntries: Int
) {
    writer.append(byte: fido.CtapRequestCommand.authenticatorClientPin.rawValue)
    writer.beginMap(count: 2 + additionalEntries)
    writer.writeInteger(Int64(fido.pin.RequestKey.protocol.rawValue))
    writer.writeInteger(Int64(pinProtocol.rawValue))
    writer.writeInteger(Int64(fido.pin.RequestKey.subcommand.rawValue))
    writer.writeInteger(Int64(subcommand.rawValue))
}

private func writeRequestKey(_ writer: inout CBORWriter, _ key: fido.pin.RequestKey) {
    writer.writeInteger(Int64(key.rawValue))
}

// The COSE key map of its encoding; an empty byte string when it is not one data item.
private func writeCOSEKey(_ writer: inout CBORWriter, _ coseKey: borrowing cbor.Bytes) {
    if let item = CBORView(coseKey.span()) {
        writer.append(encodedItem: item.encoded)
    } else {
        writer.writeByteString(Span<UInt8>())
    }
}

// A P-256 ECDH COSE key (RFC 8152 7.1, 13.1.1).
private func parseKeyAgreementCOSE(_ coseKey: CBORView) -> fido.CryptoKeyECPtr {
    guard let kty = coseKey.value(forKey: COSE.kty), kty.integer == COSE.EC2,
        let alg = coseKey.value(forKey: COSE.alg), alg.integer == COSE.ECDH256,
        let crv = coseKey.value(forKey: COSE.crv), crv.integer == COSE.P_256
    else {
        return fido.CryptoKeyECPtr()
    }
    guard let xItem = coseKey.value(forKey: COSE.x), let x = xItem.byteString,
        let yItem = coseKey.value(forKey: COSE.y), let y = yItem.byteString
    else {
        return fido.CryptoKeyECPtr()
    }
    let rawPublicKey = WebCore.encodeRawPublicKey(makeByteVector(x), makeByteVector(y))
    return WebCore.CryptoKeyEC.importRaw(
        .ECDH,
        makeWTFString("P-256"),
        consuming: rawPublicKey,
        true,
        WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageDeriveBits)
    )
}

private func readRetriesResponse(_ buffer: borrowing cbor.Bytes) -> fido.pin.RetriesParseResult {
    var result = fido.pin.RetriesParseResult()
    let bytes: Span<UInt8> = buffer.span()
    guard let map = decodeResponseMap(bytes) else {
        return result
    }
    guard let item = map.value(forKey: Int64(fido.pin.ResponseKey.retries.rawValue)), let retries = item.unsigned else {
        return result
    }
    // Non-negative: unsigned holds only CBOR unsigned integers.
    result.retries = UInt64(retries)
    result.valid = true
    return result
}

private func readKeyAgreementResponse(_ buffer: borrowing cbor.Bytes) -> fido.CryptoKeyECPtr {
    let bytes: Span<UInt8> = buffer.span()
    guard let map = decodeResponseMap(bytes) else {
        return fido.CryptoKeyECPtr()
    }
    guard let coseKey = map.value(forKey: Int64(fido.pin.ResponseKey.keyAgreement.rawValue)), coseKey.isMap else {
        return fido.CryptoKeyECPtr()
    }
    return parseKeyAgreementCOSE(coseKey)
}

private func readTokenResponse(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ sharedKey: borrowing WebCore.CryptoKeyAES,
    _ buffer: borrowing cbor.Bytes
) -> fido.CryptoKeyHMACPtr {
    let bytes: Span<UInt8> = buffer.span()
    guard let map = decodeResponseMap(bytes) else {
        return fido.CryptoKeyHMACPtr()
    }
    guard let item = map.value(forKey: Int64(fido.pin.ResponseKey.pinToken.rawValue)), let encryptedToken = item.byteString else {
        return fido.CryptoKeyHMACPtr()
    }
    let token = decryptForProtocol(pinProtocol, sharedKey, makeByteVector(encryptedToken))
    if token.isEmpty() {
        return fido.CryptoKeyHMACPtr()
    }
    return importHMACKey(token)
}

extension fido.pin {
    /// The COSE encoding of a public key.
    @cxx
    @implementation
    public static func encodeCOSEPublicKey(_ key: cbor.Bytes) -> cbor.Bytes {
        encodeCOSEPublicKeyBody(key)
    }

    private static func encodeCOSEPublicKeyBody(_ key: cbor.Bytes) -> cbor.Bytes {
        // The key is 65 bytes; a shorter one traps reading x or y.
        let bytes: Span<UInt8> = key.span()
        let fieldLength = WebCore.ES256FieldElementLength
        var writer = CBORWriter(reservingCapacity: 24 + 2 * fieldLength)
        writer.beginMap(count: 5)
        writer.writeInteger(COSE.kty)
        writer.writeInteger(COSE.EC2)
        writer.writeInteger(COSE.alg)
        writer.writeInteger(COSE.ECDH256)
        writer.writeInteger(COSE.crv)
        writer.writeInteger(COSE.P_256)
        writer.writeInteger(COSE.x)
        writer.writeByteString(bytes.extracting(1..<(1 + fieldLength)))
        writer.writeInteger(COSE.y)
        writer.writeByteString(bytes.extracting((1 + fieldLength)..<(1 + 2 * fieldLength)))
        return writer.takeVector()
    }

    /// The PIN as UTF-8, or empty when it is too short or too long.
    @cxx
    @implementation
    public static func validatePinAsUTF8(_ pin: WTF.String) -> WTF.UTF8CString {
        // The CTAP2 four-character minimum, counted in UTF-16 code units.
        if pin.length() < 4 {
            return WTF.UTF8CString()
        }
        let utf8 = pin.utf8()
        let length = fido.utf8CStringLength(utf8)
        if length < fido.pin.kMinBytes || length > fido.pin.kMaxBytes {
            return WTF.UTF8CString()
        }
        return utf8
    }

    /// Parses the response to a retries request.
    @cxx
    @implementation
    public static func parseRetriesResponse(_ buffer: cbor.Bytes) -> fido.pin.RetriesParseResult {
        readRetriesResponse(buffer)
    }

    /// Parses the response to a key agreement request.
    @cxx
    @implementation
    public static func parseKeyAgreementResponse(_ buffer: cbor.Bytes) -> fido.CryptoKeyECPtr {
        readKeyAgreementResponse(buffer)
    }

    /// Parses the response to a token request.
    @cxx
    @implementation
    public static func parseTokenResponse(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ sharedKey: borrowing WebCore.CryptoKeyAES,
        _ buffer: cbor.Bytes
    ) -> fido.CryptoKeyHMACPtr {
        readTokenResponse(pinProtocol, sharedKey, buffer)
    }

    /// The pinUvAuthParam of a client data hash for a token.
    @cxx
    @implementation
    public static func tokenPinAuth(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ token: borrowing WebCore.CryptoKeyHMAC,
        _ clientDataHash: cbor.Bytes
    ) -> cbor.Bytes {
        authenticateForProtocol(pinProtocol, token, clientDataHash)
    }

    /// The CBOR of a retries request.
    @cxx
    @implementation
    public static func encodeAsCBOR(_ request: fido.pin.RetriesRequest) -> cbor.Bytes {
        var writer = CBORWriter(reservingCapacity: 8)
        beginPinCommand(&writer, .getRetries, request.`protocol`, additionalEntries: 0)
        return writer.takeVector()
    }

    /// The CBOR of a key agreement request.
    @cxx
    @implementation
    public static func encodeAsCBOR(_ request: fido.pin.KeyAgreementRequest) -> cbor.Bytes {
        var writer = CBORWriter(reservingCapacity: 8)
        beginPinCommand(&writer, .getKeyAgreement, request.`protocol`, additionalEntries: 0)
        return writer.takeVector()
    }
}

// What a PIN request is made of, before the C++ request object (a move-only optional) or its encoding is made of it.
private struct SetPinInputs {
    var sharedKey: fido.CryptoKeyAESPtr
    var rawPublicKey: cbor.Bytes
    var newPinEnc: cbor.Bytes
    var pinUvAuthParam: cbor.Bytes
}

private struct TokenInputs {
    var sharedKey: fido.CryptoKeyAESPtr
    var rawPublicKey: cbor.Bytes
    var pinHash: cbor.Bytes
}

private struct HmacSecretInputs {
    var sharedKey: fido.CryptoKeyAESPtr
    var rawPublicKey: cbor.Bytes
    var saltEnc: cbor.Bytes
    var saltAuth: cbor.Bytes
}

private func setPinInputs(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ newPin: WTF.String,
    _ peerKey: borrowing WebCore.CryptoKeyEC
) -> SetPinInputs? {
    let validated = fido.pin.validatePinAsUTF8(newPin)
    if fido.utf8CStringLength(validated) == 0 {
        return nil
    }

    // CTAP2 5.5.4, getting sharedSecret from the authenticator: a P-256 key pair, ECDH, the protocol's KDF.
    let agreement = fido.pin.pinKeyAgreement(peerKey)
    precondition(agreement.generated, "P-256 key pair generation failed")
    if !agreement.derived {
        return nil
    }
    let sharedSecret = deriveProtocolSharedSecret(pinProtocol, agreement.sharedSecret)
    if sharedSecret.isEmpty() {
        return nil
    }
    let halves = sharedSecretHalves(pinProtocol, sharedSecret)
    let sharedKeyPtr = importAESKey(halves.aes)
    let sharedKey = nonNull(sharedKeyPtr.get())
    precondition(agreement.exported, "P-256 public key export failed")

    let pinBytes: Span<UInt8> = validated.span()
    var paddedPinSink = fido.WebAuthnByteSink()
    paddedPinSink.reserve(max(pinPaddedLength, pinBytes.count))
    paddedPinSink.append(pinBytes)
    for _ in pinBytes.count..<max(pinPaddedLength, pinBytes.count) {
        paddedPinSink.addByte(0)
    }
    let paddedPin = paddedPinSink.take()

    let hmacKey = nonNull(importHMACKey(halves.hmac).get())
    let newPinEnc = encryptForProtocol(pinProtocol, sharedKey, paddedPin)
    let pinUvAuthParam = authenticateForProtocol(pinProtocol, hmacKey, newPinEnc)
    return SetPinInputs(sharedKey: sharedKeyPtr, rawPublicKey: agreement.rawPublicKey, newPinEnc: newPinEnc, pinUvAuthParam: pinUvAuthParam)
}

private func tokenInputs(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ pin: WTF.UTF8CString,
    _ peerKey: borrowing WebCore.CryptoKeyEC
) -> TokenInputs? {
    // CTAP2 5.5.4, as above.
    let agreement = fido.pin.pinKeyAgreement(peerKey)
    precondition(agreement.generated, "P-256 key pair generation failed")
    if !agreement.derived {
        return nil
    }
    let sharedSecret = deriveProtocolSharedSecret(pinProtocol, agreement.sharedSecret)
    if sharedSecret.isEmpty() {
        return nil
    }
    let sharedKeyPtr = importAESKey(sharedSecretHalves(pinProtocol, sharedSecret).aes)
    _ = nonNull(sharedKeyPtr.get())
    precondition(agreement.exported, "P-256 public key export failed")

    // The left 16 bytes of the PIN's SHA-256.
    var pinHash = fido.pin.pinSHA256(makeByteVector(pin.span()))
    pinHash.shrink(pinProtocol1AuthLength)
    return TokenInputs(sharedKey: sharedKeyPtr, rawPublicKey: agreement.rawPublicKey, pinHash: pinHash)
}

private func hmacSecretInputs(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ salt1: cbor.Bytes,
    _ salt2: fido.OptionalByteVector,
    _ peerKey: fido.CryptoKeyECPtr
) -> HmacSecretInputs? {
    let secondSalt = Optional(fromCxx: salt2)
    if salt1.size() != pinSharedKeyLength {
        return nil
    }
    if let secondSalt, secondSalt.size() != pinSharedKeyLength {
        return nil
    }

    let agreement = fido.pin.pinKeyAgreement(nonNull(peerKey.get()))
    if !agreement.generated || !agreement.derived {
        return nil
    }
    let sharedSecret = deriveProtocolSharedSecret(pinProtocol, agreement.sharedSecret)
    if sharedSecret.isEmpty() {
        return nil
    }
    let halves = sharedSecretHalves(pinProtocol, sharedSecret)
    let sharedKeyPtr = importAESKey(halves.aes)
    guard let sharedKey = sharedKeyPtr.get(), agreement.exported else {
        return nil
    }

    let salts = secondSalt.map { concatenation(salt1, $0) } ?? salt1
    let saltEnc = encryptForProtocol(pinProtocol, sharedKey, salts)
    guard let hmacKey = importHMACKey(halves.hmac).get() else {
        return nil
    }
    let saltAuth = authenticateForProtocol(pinProtocol, hmacKey, saltEnc)
    return HmacSecretInputs(sharedKey: sharedKeyPtr, rawPublicKey: agreement.rawPublicKey, saltEnc: saltEnc, saltAuth: saltAuth)
}

private func encodeTokenCommand(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ sharedKey: borrowing WebCore.CryptoKeyAES,
    _ coseKey: borrowing cbor.Bytes,
    _ pinHash: borrowing cbor.Bytes
) -> cbor.Bytes {
    let encryptedPin = encryptForProtocol(pinProtocol, sharedKey, pinHash)
    var writer = CBORWriter(reservingCapacity: 16 + coseKey.size() + encryptedPin.size())
    beginPinCommand(&writer, .getPinToken, pinProtocol, additionalEntries: 2)
    writeRequestKey(&writer, .keyAgreement)
    writeCOSEKey(&writer, coseKey)
    writeRequestKey(&writer, .pinHashEnc)
    writer.writeByteString(encryptedPin.span())
    return writer.takeVector()
}

private func encodeSetPinCommand(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ coseKey: borrowing cbor.Bytes,
    _ newPinEnc: borrowing cbor.Bytes,
    _ pinUvAuthParam: borrowing cbor.Bytes
) -> cbor.Bytes {
    var writer = CBORWriter(reservingCapacity: 24 + coseKey.size() + newPinEnc.size() + pinUvAuthParam.size())
    beginPinCommand(&writer, .setPin, pinProtocol, additionalEntries: 3)
    writeRequestKey(&writer, .keyAgreement)
    writeCOSEKey(&writer, coseKey)
    writeRequestKey(&writer, .pinAuth)
    writer.writeByteString(pinUvAuthParam.span())
    writeRequestKey(&writer, .newPinEnc)
    writer.writeByteString(newPinEnc.span())
    return writer.takeVector()
}

extension fido.pin.SetPinRequest {
    /// Creates a set-PIN request, if the new PIN is valid.
    @cxx
    @implementation
    public static func tryCreate(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ newPin: WTF.String,
        _ peerKey: borrowing WebCore.CryptoKeyEC
    ) -> fido.OptionalSetPinRequest {
        guard let inputs = setPinInputs(pinProtocol, newPin, peerKey) else {
            return fido.OptionalSetPinRequest()
        }
        return fido.pin.SetPinRequest.makeOptional(
            nonNull(inputs.sharedKey.get()),
            consuming: fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey),
            consuming: inputs.newPinEnc,
            consuming: inputs.pinUvAuthParam,
            pinProtocol
        )
    }
}

extension fido.pin.TokenRequest {
    /// Creates a token request, if the PIN is valid.
    @cxx
    @implementation
    public static func tryCreate(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ pin: WTF.UTF8CString,
        _ peerKey: borrowing WebCore.CryptoKeyEC
    ) -> fido.OptionalTokenRequest {
        tryCreateBody(pinProtocol, pin, peerKey)
    }

    private static func tryCreateBody(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ pin: WTF.UTF8CString,
        _ peerKey: borrowing WebCore.CryptoKeyEC
    ) -> fido.OptionalTokenRequest {
        guard let inputs = tokenInputs(pinProtocol, pin, peerKey) else {
            return fido.OptionalTokenRequest()
        }
        return fido.pin.TokenRequest.makeOptional(
            nonNull(inputs.sharedKey.get()),
            consuming: fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey),
            consuming: inputs.pinHash,
            pinProtocol
        )
    }
}

extension fido.pin.HmacSecretRequest {
    /// Creates an hmac-secret request.
    @cxx
    @implementation
    public static func create(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ salt1: cbor.Bytes,
        _ salt2: fido.OptionalByteVector,
        _ peerKey: fido.CryptoKeyECPtr
    ) -> fido.OptionalHmacSecretRequest {
        guard let inputs = hmacSecretInputs(pinProtocol, salt1, salt2, peerKey) else {
            return fido.OptionalHmacSecretRequest()
        }
        return fido.pin.HmacSecretRequest.makeOptional(
            nonNull(inputs.sharedKey.get()),
            consuming: fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey),
            consuming: inputs.saltEnc,
            consuming: inputs.saltAuth,
            pinProtocol
        )
    }
}

// The PIN requests as WebKit's Swift needs them: the CBOR command and what the C++ request holds on to, in plain types.
extension fido.pin {
    /// The parts of a token request.
    @cxx
    @implementation
    public static func tokenRequestParts(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ pin: WTF.UTF8CString,
        _ peerKey: borrowing WebCore.CryptoKeyEC
    ) -> fido.pin.TokenRequestParts {
        var parts = fido.pin.TokenRequestParts()
        guard let inputs = tokenInputs(pinProtocol, pin, peerKey) else {
            return parts
        }
        parts.command = encodeTokenCommand(
            pinProtocol,
            nonNull(inputs.sharedKey.get()),
            fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey),
            inputs.pinHash
        )
        parts.sharedKey = inputs.sharedKey
        return parts
    }

    /// The parts of a set-PIN request.
    @cxx
    @implementation
    public static func setPinRequestParts(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ newPin: WTF.String,
        _ peerKey: borrowing WebCore.CryptoKeyEC
    ) -> fido.pin.SetPinRequestParts {
        var parts = fido.pin.SetPinRequestParts()
        guard let inputs = setPinInputs(pinProtocol, newPin, peerKey) else {
            return parts
        }
        parts.command = encodeSetPinCommand(
            pinProtocol,
            fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey),
            inputs.newPinEnc,
            inputs.pinUvAuthParam
        )
        parts.pinAuth = inputs.pinUvAuthParam
        parts.valid = true
        return parts
    }

    /// The parts of an hmac-secret request.
    @cxx
    @implementation
    public static func hmacSecretRequestParts(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ salt1: cbor.Bytes,
        _ salt2: fido.OptionalByteVector,
        _ peerKey: fido.CryptoKeyECPtr
    ) -> fido.pin.HmacSecretRequestParts {
        var parts = fido.pin.HmacSecretRequestParts()
        guard let inputs = hmacSecretInputs(pinProtocol, salt1, salt2, peerKey) else {
            return parts
        }
        parts.parameters.keyAgreement = fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey)
        parts.parameters.saltEnc = inputs.saltEnc
        parts.parameters.saltAuth = inputs.saltAuth
        parts.parameters.`protocol` = Int32(pinProtocol.rawValue)
        parts.sharedKey = inputs.sharedKey
        parts.pinProtocol = pinProtocol
        parts.valid = true
        return parts
    }
}

// The decrypted hmac-secret output, or nil when it is not one or two outputs.
private func decryptHmacSecretOutput(
    _ pinProtocol: fido.PINUVAuthProtocol,
    _ sharedKey: borrowing WebCore.CryptoKeyAES,
    _ encryptedOutput: borrowing cbor.Bytes
) -> cbor.Bytes? {
    let output = decryptForProtocol(pinProtocol, sharedKey, encryptedOutput)
    let size = output.size()
    // One or two 32-byte outputs.
    if size != pinSharedKeyLength && size != 2 * pinSharedKeyLength {
        return nil
    }
    return output
}

/// The hmac-secret extension output for the CTAP response converters, as `HmacSecretResponse::parse` gives it.
func hmacSecretOutput(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedKey: WebCore.CryptoKeyAES, _ encryptedOutput: Span<UInt8>) -> [UInt8]?
{
    decryptHmacSecretOutput(pinProtocol, sharedKey, makeByteVector(encryptedOutput)).map { makeByteArray($0) }
}

extension fido.pin.HmacSecretResponse {
    /// Parses an hmac-secret response.
    @cxx
    @implementation
    public static func parse(
        _ pinProtocol: fido.PINUVAuthProtocol,
        _ sharedKey: borrowing WebCore.CryptoKeyAES,
        _ encryptedOutput: cbor.Bytes
    ) -> fido.OptionalHmacSecretResponse {
        guard let output = decryptHmacSecretOutput(pinProtocol, sharedKey, encryptedOutput) else {
            return fido.OptionalHmacSecretResponse()
        }
        return fido.OptionalHmacSecretResponse(fido.pin.HmacSecretResponse(consuming: output))
    }
}

/// The definition of `fido::pin::KeyAgreementResponse::parseFromCOSE`, which forwards here.
///
/// `coseKey` is `parseFromCOSE`'s by-value parameter, moved in; it is only read here, and the one C++ call made while
/// it lives is `CryptoKeyEC::importRaw`, which reaches nothing of it.
@_expose(Cxx)
func parseKeyAgreementFromCOSE(_ coseKey: cbor.Bytes) -> fido.CryptoKeyECPtr {
    guard let map = CBORView(coseKey.span()), map.isMap else {
        return fido.CryptoKeyECPtr()
    }
    return parseKeyAgreementCOSE(map)
}

/// The body of `fido::pin::encodeAsCBOR(const TokenRequest&)`, which forwards here.
///
/// `request` is the caller's `const&`, alive and unchanged for the call. The C++ called while it lives, `pinRandomIV`
/// and `pinAESCBCEncrypt`, takes the key and copied bytes. `encodeAsCBOR` then replaces `m_coseKey` with `{0xa0}`.
@_expose(Cxx)
func encodeTokenRequestAsCBOR(_ request: borrowing fido.pin.TokenRequest) -> cbor.Bytes {
    request.encodedAsCBOR()
}

// SWIFT_PRIVATE_FILEID opens the private members to extensions in this file only.
extension fido.pin.TokenRequest {
    fileprivate func encodedAsCBOR() -> cbor.Bytes {
        encodeTokenCommand(m_protocol, sharedKey(), m_coseKey, m_pinHash)
    }
}

/// The body of `fido::pin::encodeAsCBOR(SetPinRequest)`, which forwards here.
///
/// `request` is `encodeAsCBOR`'s by-value parameter, alive and unchanged for the call; no C++ is called while it lives.
@_expose(Cxx)
func encodeSetPinRequestAsCBOR(_ request: borrowing fido.pin.SetPinRequest) -> cbor.Bytes {
    request.encodedAsCBOR()
}

extension fido.pin.SetPinRequest {
    fileprivate func encodedAsCBOR() -> cbor.Bytes {
        encodeSetPinCommand(m_protocol, m_coseKey, m_newPinEnc, m_pinUvAuthParam)
    }
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
