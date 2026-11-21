// Copyright (C) 2019-2021 Apple Inc. All rights reserved.
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

#if ENABLE_WEB_AUTHN

import CryptoKit
import Foundation
import Security
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

@objc(WKLocalAuthenticatorCredentials)
@implementation
extension _WKWebAuthenticationPanel {
    class func localAuthenticatorCredentials(
        inAccessGroup accessGroup: String?,
        relyingPartyID rpID: String?,
        credentialID: Data?
    ) -> NSMutableArray? {
        // A nil access group cannot go in the query.
        guard let accessGroup else {
            preconditionFailure("A nil access group")
        }
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true,
        ])
        if let rpID {
            query[kSecAttrLabel] = rpID
        }

        var status = errSecSuccess
        let attributesArrayRef = copyMatchingItems(query, credentialID: credentialID, &status)

        if status != errSecSuccess && status != errSecItemNotFound {
            return nil
        }

        let attributesArray = checkedObjectCast(attributesArrayRef, to: [NSDictionary].self) ?? []
        let result = NSMutableArray(capacity: attributesArray.count)
        for attributes in attributesArray {
            let tag = (attributes[kSecAttrApplicationTag] as? Data) ?? Data()
            guard let responseMap = CBORView(tag.span), responseMap.isMap else {
                assertionFailure()
                return nil
            }

            guard let username = responseMap.value(forKey: FidoName.entityName)?.string else {
                assertionFailure()
                return nil
            }

            let storedCredentialID = attributes[aliasAttribute] ?? attributes[kSecAttrApplicationLabel]
            let credential = NSMutableDictionary(object: username, forKey: _WKLocalAuthenticatorCredentialNameKey as NSString)
            // The first missing value ends the entries.
            let entries: [(String, Any?)] = [
                (_WKLocalAuthenticatorCredentialIDKey, storedCredentialID),
                (_WKLocalAuthenticatorCredentialRelyingPartyIDKey, attributes[kSecAttrLabel]),
                (_WKLocalAuthenticatorCredentialLastModificationDateKey, attributes[kSecAttrModificationDate]),
                (_WKLocalAuthenticatorCredentialCreationDateKey, attributes[kSecAttrCreationDate]),
            ]
            for (key, value) in entries {
                guard let value else {
                    break
                }
                credential[key] = value
            }

            if let userHandle = responseMap.value(forKey: FidoName.entityID)?.byteString {
                credential[_WKLocalAuthenticatorCredentialUserHandleKey] = Data(makeByteArray(userHandle))
            } else {
                credential[_WKLocalAuthenticatorCredentialUserHandleKey] = NSNull()
            }

            if let synchronizable = attributes[kSecAttrSynchronizable] {
                credential[_WKLocalAuthenticatorCredentialSynchronizableKey] = synchronizable
            }
            #if ENABLE_ONGOING_CREDENTIAL_SHARING_WEBKIT_SPI
            if let group = attributes[sharingGroupAttribute] {
                credential[_WKLocalAuthenticatorCredentialGroupKey] = group
            }
            #endif

            if let displayName = responseMap.value(forKey: FidoName.displayName)?.string {
                credential[_WKLocalAuthenticatorCredentialDisplayNameKey] = displayName
            }

            result.add(credential)
        }

        return result
    }

    class func setLocalAuthenticatorCredentialName(_ name: String?, group: String?, credentialID: Data?) {
        updateUserEntityMap(ofCredential: credentialID, group: group) { userEntityMap in
            userEntityMapReplacingName(userEntityMap, name.map(makeWTFString) ?? WTF.String())
        }
    }

    class func setLocalAuthenticatorCredentialDisplayName(_ displayName: String?, group: String?, credentialID: Data?) {
        updateUserEntityMap(ofCredential: credentialID, group: group) { userEntityMap in
            userEntityMapReplacingDisplayName(userEntityMap, displayName.map(makeWTFString) ?? WTF.String())
        }
    }

    class func importLocalAuthenticatorCredential(_ credentialBlob: Data, accessGroup: String?) throws -> Data {
        guard let credential = decodeLocalCredentialBlob(credentialBlob.span) else {
            throw localAuthenticatorError(.malformedCredential)
        }

        let options: [CFString: Any] = [
            // Key type values are string values of numbers, stored as kCFNumberSInt64Type in attributes, but must be passed as string here
            kSecAttrKeyType: String(Int32(truncatingIfNeeded: credential.keyType)),
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: NSNumber(value: credential.keySize),
        ]
        let privateKeyData = Data(credential.privateKey)
        guard let key = SecKeyCreateWithData(privateKeyData as CFData, options as CFDictionary, nil) else {
            throw localAuthenticatorError(.malformedCredential)
        }

        guard let publicKey = SecKeyCopyPublicKey(key) else {
            preconditionFailure("A private key without a public key")
        }
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw localAuthenticatorError(.malformedCredential)
        }

        let credentialID = Data(Insecure.SHA1.hash(data: publicKeyData))

        let relyingParty = makeSwiftString(credential.relyingParty)
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecAttrLabel: relyingParty,
            kSecUseDataProtectionKeychain: true,
        ])
        updateQueryIfNecessary(query)
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }

        var status = performQuery(query, credentialID: credentialID) { SecItemCopyMatching($0, nil) }

        if status == errSecSuccess {
            // Credential with same id already exists, duplicate key.
            throw localAuthenticatorError(.duplicateCredential)
        }

        let addQuery = keychainQuery([
            kSecValueRef: key,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrLabel: relyingParty,
            kSecAttrApplicationTag: Data(credential.applicationTag),
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ])
        updateQueryIfNecessary(addQuery)

        if let accessGroup {
            addQuery[kSecAttrAccessGroup] = accessGroup
        }

        status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw localAuthenticatorError(.unknown)
        }

        return credentialID
    }

    class func exportLocalAuthenticatorCredential(_ credentialID: Data?, group: String?) throws -> Data {
        let credentialID = requireCredentialID(credentialID)
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecReturnRef: true,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ])
        updateQueryForGroupIfNecessary(query, group)

        var status = errSecSuccess
        let privateKeyRef = copyMatchingItems(query, credentialID: credentialID, &status)

        if status != errSecSuccess && status != errSecItemNotFound {
            throw localAuthenticatorError(.credentialNotFound)
        }

        // SecKeyCopyExternalRepresentation needs a key.
        guard let privateKey = checkedObjectCast(privateKeyRef, to: SecKey.self) else {
            preconditionFailure("No private key for the credential")
        }
        guard let privateKeyRepresentation = SecKeyCopyExternalRepresentation(privateKey, nil) as Data? else {
            throw localAuthenticatorError(.credentialNotFound)
        }

        query.removeObject(forKey: kSecReturnRef)
        query[kSecReturnAttributes] = true
        let attributesRef = WebKit.copyMatchingKeychainItems(query as CFDictionary, &status)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw localAuthenticatorError(.credentialNotFound)
        }
        let attributes = checkedObjectCast(attributesRef, to: NSDictionary.self)

        guard let keyType = int64Value(of: attributes?[kSecAttrKeyType]) else {
            throw localAuthenticatorError(.malformedCredential)
        }
        guard let keySize = int64Value(of: attributes?[kSecAttrKeySizeInBits]) else {
            throw localAuthenticatorError(.malformedCredential)
        }

        let relyingParty = attributes?[kSecAttrLabel] as? String
        let tag = (attributes?[kSecAttrApplicationTag] as? Data) ?? Data()
        guard let tagMap = CBORView(tag.span), tagMap.isMap else {
            throw localAuthenticatorError(.malformedCredential)
        }
        let credential = LocalCredentialBlob(
            privateKey: makeByteVector(privateKeyRepresentation.span),
            keyType: keyType,
            keySize: keySize,
            relyingParty: relyingParty.map(makeWTFString) ?? WTF.String(),
            applicationTag: makeByteVector(tag.span)
        )
        // The encoding fails only when the tag nests too deeply for the blob.
        guard let serializedCredential = encodeLocalCredentialBlob(credential) else {
            preconditionFailure("A credential tag that nests too deeply")
        }
        return Data(serializedCredential)
    }
}

// MARK: - Helpers

private func localAuthenticatorError(_ code: WKError.Code) -> NSError {
    NSError(domain: WKErrorDomain, code: code.rawValue, userInfo: nil)
}

private func updateQueryForGroupIfNecessary(_ dictionary: NSMutableDictionary, _ group: String?) {
    #if ENABLE_ONGOING_CREDENTIAL_SHARING_WEBKIT_SPI
    if let group {
        dictionary[sharingGroupAttribute] = group
    }
    #endif
}

// The credential ID a query is built with; it must not be nil.
private func requireCredentialID(_ credentialID: Data?) -> Data {
    guard let credentialID else {
        preconditionFailure("A nil credential ID")
    }
    return credentialID
}

// The attribute as an Int64, or nil when the number does not convert exactly; a missing attribute traps.
private func int64Value(of attribute: Any?) -> Int64? {
    guard let number = checkedObjectCast(attribute, to: NSNumber.self) else {
        preconditionFailure("A Keychain attribute that is not a number")
    }
    return Int64(exactly: number)
}

// Reads the Keychain item of the credential and writes back its user entity map, edited by `update`.
private func updateUserEntityMap(ofCredential credentialID: Data?, group: String?, _ update: (cbor.Bytes) -> cbor.Bytes?) {
    let credentialID = requireCredentialID(credentialID)
    let query = keychainQuery([
        kSecClass: kSecClassKey,
        kSecReturnAttributes: true,
        kSecReturnPersistentRef: true,
        kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        kSecUseDataProtectionKeychain: true,
    ])
    updateQueryForGroupIfNecessary(query, group)

    var status = errSecSuccess
    let attributesRef = copyMatchingItems(query, credentialID: credentialID, &status)

    if status != errSecSuccess && status != errSecItemNotFound {
        assertionFailure()
        return
    }

    let attributes = checkedObjectCast(attributesRef, to: NSDictionary.self)
    let tag = (attributes?[kSecAttrApplicationTag] as? Data) ?? Data()
    guard let updatedTag = update(makeByteVector(tag.span)) else {
        assertionFailure()
        return
    }

    guard let persistentRef = attributes?[kSecValuePersistentRef] else {
        preconditionFailure("A Keychain item without a persistent reference")
    }
    let updateQuery = keychainQuery([
        kSecValuePersistentRef: persistentRef,
        kSecClass: kSecClassKey,
        kSecAttrSynchronizable: kSecAttrSynchronizableAny,
    ])
    updateQueryForGroupIfNecessary(updateQuery, group)
    let updateParams = [kSecAttrApplicationTag: Data(updatedTag)] as CFDictionary

    status = SecItemUpdate(updateQuery as CFDictionary, updateParams)
    if status != errSecSuccess && status != errSecItemNotFound {
        assertionFailure()
        return
    }
}

#endif // ENABLE_WEB_AUTHN
