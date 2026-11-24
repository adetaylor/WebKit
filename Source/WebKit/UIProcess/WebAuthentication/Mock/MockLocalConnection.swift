// Copyright (C) 2018 Apple Inc. All rights reserved.
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

import Foundation
import Security
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

/// The configured user verification as the platform authenticator's result.
@_expose(Cxx)
func webAuthnMockUserVerification(
    _ userVerification: WebCore.MockWebAuthenticationConfiguration.UserVerification
) -> WebKit.LocalConnection.UserVerification {
    switch userVerification {
    case .No:
        return .No
    case .Yes:
        return .Yes
    case .Cancel:
        return .Cancel
    case .Presence:
        return .Presence
    @unknown default:
        return .No
    }
}

/// The configured private key, added to the Keychain with `label` and `tag`; nil (logged) if Security fails.
@_expose(Cxx)
func webAuthnMockCreateCredentialPrivateKey(privateKeyBase64: NSString, label: NSString, tag: NSData?) -> SecKey? {
    // The query's dictionary takes no nil value.
    guard let tag else {
        preconditionFailure("A credential private key without a tag")
    }
    // Get Key and add it to Keychain.
    let options: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 256,
    ]
    // SecKeyCreateWithData's data is nonnull.
    guard let keyData = NSData(base64Encoded: privateKeyBase64 as String, options: .ignoreUnknownCharacters) else {
        preconditionFailure("A configured private key that is not base64")
    }
    guard let key = SecKeyCreateWithData(keyData as CFData, options as CFDictionary, nil) else {
        return nil
    }

    let addQuery: [CFString: Any] = [
        kSecValueRef: key,
        kSecClass: kSecClassKey,
        kSecAttrLabel: label,
        kSecAttrApplicationTag: tag,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        kSecUseDataProtectionKeychain: true,
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status != errSecSuccess {
        webAuthnLogError("Couldn't add the key to the keychain. \(status)")
        return nil
    }

    return key
}

/// The Keychain's credentials for the relying party in any synchronization state, most recently modified first; nil
/// if there are none or the lookup fails.
@_expose(Cxx)
func webAuthnMockExistingCredentials(rpId: NSString) -> NSArray? {
    // Search Keychain for existing credential matched the RP ID.
    webAuthnCredentialsByModificationDate(matching: [
        kSecClass: kSecClassKey,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        kSecAttrLabel: rpId,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecUseDataProtectionKeychain: true,
    ])
}

#endif // ENABLE_WEB_AUTHN
