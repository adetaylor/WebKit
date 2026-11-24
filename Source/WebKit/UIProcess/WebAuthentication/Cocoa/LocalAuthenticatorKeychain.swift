// Copyright (C) 2018-2025 Apple Inc. All rights reserved.
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

// The Keychain queries of the local authenticator's credentials, which LocalAuthenticator.swift and
// WebAuthenticationPanelCredentials.swift share.

// kSecAttrSharingGroup in _WKWebAuthenticationPanel.mm.
let sharingGroupAttribute = "ggrp"
// SecuritySPI.h declares kSecAttrAlias without nullability.
var aliasAttribute: CFString { kSecAttrAlias }

/// Whether AuthenticationServicesCore keeps the credential ID in the alias attribute; never without the unified UI.
func webAuthnShouldUseAlternateKeychainAttribute() -> Bool {
    #if HAVE_UNIFIED_ASC_AUTH_UI
    WebKit.webAuthnASCShouldUseAlternateKeychainAttribute()
    #else
    false
    #endif
}

func keychainQuery(_ attributes: [CFString: Any]) -> NSMutableDictionary {
    NSMutableDictionary(dictionary: attributes)
}

func updateQueryIfNecessary(_ dictionary: NSMutableDictionary) {
    if !WebKit.webAuthnASCShouldUseAlternateCredentialStore() {
        return
    }

    dictionary[kSecAttrSynchronizable] = true
}

/// Runs `operation` on `query` with the credential ID.
///
/// The ID is the credential's alias where the alternate Keychain attribute is in use, and its application label when
/// no item has that alias; else its application label. A nil `credentialID` runs `query` as it is.
func performQuery(_ query: NSMutableDictionary, credentialID: Data?, _ operation: (CFDictionary) -> OSStatus) -> OSStatus {
    let useAlternateKeychainAttribute = webAuthnShouldUseAlternateKeychainAttribute()
    guard let credentialID else {
        return operation(query as CFDictionary)
    }
    query[useAlternateKeychainAttribute ? aliasAttribute : kSecAttrApplicationLabel] = credentialID
    var status = operation(query as CFDictionary)
    if useAlternateKeychainAttribute && status == errSecItemNotFound {
        query.removeObject(forKey: aliasAttribute)
        query[kSecAttrApplicationLabel] = credentialID
        status = operation(query as CFDictionary)
    }
    return status
}

/// The items `query` matches with `credentialID`, as `performQuery` looks them up, and the status of the last lookup.
func copyMatchingItems(_ query: NSMutableDictionary, credentialID: Data?, _ status: inout OSStatus) -> CFTypeRef? {
    var result: CFTypeRef?
    status = performQuery(query, credentialID: credentialID) { query in
        var status = errSecSuccess
        result = WebKit.copyMatchingKeychainItems(query, &status)
        return status
    }
    return result
}

// checked_objc_cast: nil stays nil, and an object of another class traps. Not for a Core Foundation type, which `as?`
// does not check (it succeeds on any object): use checkedCFCast.
func checkedObjectCast<T>(_ value: Any?, to type: T.Type) -> T? {
    guard let value else {
        return nil
    }
    guard let object = value as? T else {
        preconditionFailure("An object of an unexpected class")
    }
    return object
}

// A Core Foundation type checkedCFCast can check, by its type ID.
protocol WebAuthnCFTypeIDProviding: AnyObject {
    static var typeID: CFTypeID { get }
}

extension SecKey: WebAuthnCFTypeIDProviding {
    static var typeID: CFTypeID { SecKeyGetTypeID() }
}

extension SecAccessControl: WebAuthnCFTypeIDProviding {
    static var typeID: CFTypeID { SecAccessControlGetTypeID() }
}

extension SecIdentity: WebAuthnCFTypeIDProviding {
    static var typeID: CFTypeID { SecIdentityGetTypeID() }
}

// checked_cf_cast: nil stays nil, and an object whose Core Foundation type ID is not T's traps.
func checkedCFCast<T: WebAuthnCFTypeIDProviding>(_ value: Any?, to type: T.Type) -> T? {
    guard let value else {
        return nil
    }
    let object = value as AnyObject
    guard CFGetTypeID(object) == T.typeID, let cfObject = object as? T else {
        preconditionFailure("An object of an unexpected Core Foundation type")
    }
    return cfObject
}

extension Data {
    /// The bytes of `bytes`.
    init(_ bytes: borrowing cbor.Bytes) {
        self.init(makeByteArray(bytes.span()))
    }
}

#endif // ENABLE_WEB_AUTHN
