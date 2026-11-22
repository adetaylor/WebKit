// Copyright (C) 2022 Apple Inc. All rights reserved.
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

import CryptoKit
import Security
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

private func privateKeyOptions() -> CFDictionary {
    [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 256,
    ] as CFDictionary
}

func flagsForConfig(_ config: borrowing WebKit.VirtualAuthenticatorConfiguration) -> UInt8 {
    var flags = WebAuthn.attestedCredentialDataIncludedFlag
    if config.isUserConsenting {
        flags = flags | WebAuthn.userPresenceFlag
    }
    if config.isUserVerified {
        flags = flags | WebAuthn.userVerifiedFlag
    }
    return flags
}

func createPrivateKey() -> SecKey? {
    SecKeyCreateRandomKey(privateKeyOptions(), nil)
}

func credentialIDAndCosePubKeyForPrivateKey(_ privateKey: SecKey) -> (credentialID: cbor.Bytes, cosePublicKey: cbor.Bytes) {
    // The public key's external representation: 04 | X | Y. Empty when the copy fails.
    var publicKeyData: [UInt8] = []
    if let publicKey = SecKeyCopyPublicKey(privateKey), let representation = SecKeyCopyExternalRepresentation(publicKey, nil) {
        publicKeyData = [UInt8](representation as Data)
        assert(publicKeyData.count == 1 + 2 * WebCore.ES256FieldElementLength)
    } else {
        assertionFailure()
    }

    let credentialID = makeByteVector(Array(Insecure.SHA1.hash(data: publicKeyData)))

    // COSE Encoding
    let xRange = 1..<(1 + WebCore.ES256FieldElementLength)
    let yRange = (1 + WebCore.ES256FieldElementLength)..<(1 + 2 * WebCore.ES256FieldElementLength)
    let x = publicKeyData.isEmpty ? [UInt8](repeating: 0, count: xRange.count) : Array(publicKeyData[xRange])
    let y = publicKeyData.isEmpty ? [UInt8](repeating: 0, count: yRange.count) : Array(publicKeyData[yRange])
    let cosePublicKey = encodeES256PublicKeyAsCBOR(makeByteVector(x), makeByteVector(y))
    return (credentialID, cosePublicKey)
}

func base64PrivateKey(_ privateKey: SecKey) -> WTF.String {
    guard let representation = SecKeyCopyExternalRepresentation(privateKey, nil) else {
        assertionFailure()
        return fido.emptyWTFString()
    }
    return fido.base64EncodeBytes(makeByteVector([UInt8](representation as Data)))
}

func privateKeyFromBase64(_ base64PrivateKey: WTF.String) -> SecKey? {
    guard let privateKey = Data(base64Encoded: makeSwiftString(base64PrivateKey)) else {
        return nil
    }
    return SecKeyCreateWithData(privateKey as CFData, privateKeyOptions(), nil)
}

func signatureForPrivateKey(_ privateKey: SecKey, _ authData: Span<UInt8>, _ clientDataHash: Span<UInt8>) -> cbor.Bytes {
    var dataToSign = makeByteArray(authData)
    dataToSign.append(contentsOf: makeByteArray(clientDataHash))
    guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, Data(dataToSign) as CFData, nil) else {
        assertionFailure()
        return cbor.Bytes()
    }
    return makeByteVector([UInt8](signature as Data))
}

#endif // ENABLE_WEB_AUTHN
