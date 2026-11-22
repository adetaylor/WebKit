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

/// The authenticator data of an attestation object, or nil when the object is not a map with an `authData` byte string.
@_lifetime(copy attestationObject)
private func authenticatorData(_ attestationObject: Span<UInt8>) -> Span<UInt8>? {
    guard let map = CBORView(attestationObject), map.isMap else {
        assertionFailure()
        return nil
    }
    guard let item = map.value(forKey: "authData"), let authData = item.byteString else {
        assertionFailure()
        return nil
    }
    return authData
}

/// The credential public key in authenticator data: the item after the credential ID, which must take the rest of the
/// bytes; nil when there is none.
@_lifetime(copy authData)
private func cosePublicKey(_ authData: Span<UInt8>) -> CBORView? {
    let credentialIDLengthOffset = WebCore.rpIdHashLength + WebCore.flagsLength + WebCore.signCounterLength + WebCore.aaguidLength
    if authData.count < credentialIDLengthOffset + WebCore.credentialIdLengthLength {
        return nil
    }

    let credentialIDLength = Int(authData[credentialIDLengthOffset]) << 8 | Int(authData[credentialIDLengthOffset + 1])
    let cosePublicKeyOffset = credentialIDLengthOffset + WebCore.credentialIdLengthLength + credentialIDLength
    if authData.count <= cosePublicKeyOffset {
        return nil
    }

    return CBORView(authData.extracting(cosePublicKeyOffset...))
}

extension WebCore.AuthenticatorAttestationResponse {
    /// The attestation object's authenticator data, or null when the object has none.
    @cxx
    @implementation
    public func getAuthenticatorData() -> fido.ArrayBufferPtr {
        let objectBytes = attestationObject().toVector()
        let encoded: Span<UInt8> = objectBytes.span()
        guard let authData = authenticatorData(encoded) else {
            return fido.ArrayBufferPtr()
        }
        // A span into a non-empty vector has a base address even when empty, so it can cross as a std::span.
        return fido.tryCreateArrayBuffer(authData)
    }

    /// The COSE algorithm of the credential public key, or 0 when there is none.
    @cxx
    @implementation
    public func getPublicKeyAlgorithm() -> Int64 {
        let objectBytes = attestationObject().toVector()
        let encoded: Span<UInt8> = objectBytes.span()
        guard let authData = authenticatorData(encoded), let key = cosePublicKey(authData), key.isMap else {
            return 0
        }

        guard let algItem = key.value(forKey: COSE.alg), let alg = algItem.integer else {
            assertionFailure()
            return 0
        }
        return alg
    }

    /// The credential public key as SPKI, or null when it is not an ES256 P-256 key.
    @cxx
    @implementation
    public func getPublicKey() -> fido.ArrayBufferPtr {
        let objectBytes = attestationObject().toVector()
        let encoded: Span<UInt8> = objectBytes.span()
        guard let authData = authenticatorData(encoded), let key = cosePublicKey(authData), key.isMap else {
            return fido.ArrayBufferPtr()
        }

        guard let algItem = key.value(forKey: COSE.alg), let alg = algItem.integer else {
            assertionFailure()
            return fido.ArrayBufferPtr()
        }

        guard let ktyItem = key.value(forKey: COSE.kty), let kty = ktyItem.integer else {
            assertionFailure()
            return fido.ArrayBufferPtr()
        }

        let crv = key.value(forKey: COSE.crv)?.integer

        switch alg {
        case COSE.ES256:
            if kty != COSE.EC2 || crv != COSE.P_256 {
                return fido.ArrayBufferPtr()
            }

            guard let xItem = key.value(forKey: COSE.x), let x = xItem.byteString else {
                assertionFailure()
                return fido.ArrayBufferPtr()
            }

            guard let yItem = key.value(forKey: COSE.y), let y = yItem.byteString else {
                assertionFailure()
                return fido.ArrayBufferPtr()
            }
            let rawPublicKey = WebCore.encodeRawPublicKey(makeByteVector(x), makeByteVector(y))
            guard
                let peerKey = WebCore.CryptoKeyEC
                    .importRaw(
                        .ECDH,
                        makeWTFString("P-256"),
                        consuming: rawPublicKey,
                        true,
                        WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageDeriveBits)
                    )
                    .get()
            else {
                return fido.ArrayBufferPtr()
            }
            let keySpki = fido.exportSpki(peerKey)
            let spki: Span<UInt8> = keySpki.span()
            return fido.tryCreateArrayBuffer(spki)
        default:
            break
        }

        return fido.ArrayBufferPtr()
    }
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
