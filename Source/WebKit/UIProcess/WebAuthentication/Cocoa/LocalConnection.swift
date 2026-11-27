// Copyright (C) 2018-2021 Apple Inc. All rights reserved.
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

#if WTF_PLATFORM_MAC
import AppKit
#endif
import Foundation
// Only LAContext's interface: Swift sends it messages and never names its class, so the soft link stays.
import LocalAuthentication
import Security
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

// The platform authenticator's LocalAuthentication and Keychain work, which LocalConnection.mm and LocalService.mm call
// with the Objective-C and Core Foundation objects. The LocalAuthentication replies, which come on another thread and
// hop to the main thread with the C++ handlers, are in LocalConnection.mm; the reply's result is mapped here, on the reply's
// thread, with no state shared.

/// The title of the Touch ID prompt for the relying party.
@_expose(Cxx)
func webAuthnTouchIDPromptTitle(rpId: consuming WTF.String, type: WebCore.ClientDataType) -> WTF.String {
    #if WTF_PLATFORM_MAC
    switch type {
    case .Create:
        return WebCore.makeCredentialTouchIDPromptTitle(bundleName(), rpId)
    case .Get:
        return WebCore.getAssertionTouchIDPromptTitle(bundleName(), rpId)
    @unknown default:
        assertionFailure("An unexpected client data type")
        return WebCore.genericTouchIDPromptTitle()
    }
    #else
    return WebCore.genericTouchIDPromptTitle()
    #endif
}

/// The result of a LocalAuthentication evaluation's reply, on the reply's thread.
@_expose(Cxx)
func webAuthnUserVerification(information: NSDictionary?, error: NSError?) -> WebKit.LocalConnection.UserVerification {
    var verification = WebKit.LocalConnection.UserVerification.Yes
    if let error {
        webAuthnLogError("Couldn't authenticate with biometrics: \(error)")
        verification = error.code == LAError.Code.userCancel.rawValue ? .Cancel : .No
    }
    if information?["UserPresence"] != nil {
        verification = .Presence
    }
    return verification
}

/// A new credential key, or nil (logged) if Security fails.
///
/// A Secure Enclave key with `context` as its authentication context if any, or a synchronizable key where the
/// alternate credential store is in use.
@_expose(Cxx)
func webAuthnCreateCredentialPrivateKey(
    context: LAContext?,
    accessControl: SecAccessControl?,
    label: NSString,
    tag: NSData?
) -> SecKey? {
    // The query's dictionaries take no nil value.
    guard let accessControl, let tag else {
        preconditionFailure("A credential private key without an access control or a tag")
    }
    let attributes: [CFString: Any]
    if shouldUseAlternateAttributes() {
        attributes = [
            kSecAttrSynchronizable: true,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrAccessGroup: WebCore.LocalAuthenticatorAccessGroup,
                kSecAttrLabel: label,
                kSecAttrApplicationTag: tag,
            ] as [CFString: Any],
        ]
    } else {
        var privateKeyAttributes: [CFString: Any] = [
            kSecAttrAccessControl: accessControl,
            kSecAttrIsPermanent: true,
            kSecAttrAccessGroup: WebCore.LocalAuthenticatorAccessGroup,
            kSecAttrLabel: label,
            kSecAttrApplicationTag: tag,
        ]
        if let context {
            // Boxed as an NSObject: boxing an LAContext would need its class metadata, which references the class
            // symbol and links LocalAuthentication, which is soft-linked.
            privateKeyAttributes[kSecUseAuthenticationContext] = context as NSObject
        }
        attributes = [
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateKeyAttributes,
        ]
    }

    var errorDescription = WebCore.OptionalWebAuthnString()
    let key = WebKit.createWebAuthnRandomKey(attributes as CFDictionary, &errorDescription)
    if let description = Optional(fromCxx: errorDescription) {
        webAuthnLogError("Couldn't create private key: \(makeSwiftString(description))")
    }
    return key
}

/// The Keychain's credentials for the relying party, most recently modified first; nil if there are none or the
/// lookup fails.
@_expose(Cxx)
func webAuthnExistingCredentials(rpId: NSString) -> NSArray? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassKey,
        kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        kSecAttrAccessGroup: WebCore.LocalAuthenticatorAccessGroup,
        kSecAttrLabel: rpId,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecUseDataProtectionKeychain: true,
    ]
    return webAuthnCredentialsByModificationDate(matching: query)
}

/// The Keychain items `query` matches, most recently modified first; nil if there are none or the lookup fails.
func webAuthnCredentialsByModificationDate(matching query: [CFString: Any]) -> NSArray? {
    var status = errSecSuccess
    let result = WebKit.copyMatchingKeychainItems(query as CFDictionary, &status)
    if status != errSecSuccess && status != errSecItemNotFound {
        return nil
    }
    // No array: no credentials.
    guard let attributesArray = checkedObjectCast(result, to: NSArray.self) else {
        return nil
    }
    return attributesArray.sortedArray { a, b in
        let modificationDate = { (attributes: Any) in
            checkedObjectCast(checkedObjectCast(attributes, to: NSDictionary.self)?[kSecAttrModificationDate], to: NSDate.self)
        }
        // A message to a nil date answered NSOrderedSame.
        guard let later = modificationDate(b) else {
            return .orderedSame
        }
        guard let earlier = modificationDate(a) else {
            preconditionFailure("A Keychain item without a modification date")
        }
        return later.compare(earlier as Date)
    } as NSArray
}

/// Whether the platform authenticator can be used: where the alternate credential store is in use, or where the
/// device can evaluate the biometrics policy now or after a lockout.
@_expose(Cxx)
func webAuthnLocalServiceIsAvailable() -> Bool {
    if WebKit.webAuthnASCShouldUseAlternateCredentialStore() {
        return true
    }

    var canEvaluatePolicy = false
    let error = WebKit.canEvaluateBiometricsPolicy(WebKit.createWebAuthnLAContext(), &canEvaluatePolicy) as NSError?
    if (!canEvaluatePolicy || error != nil) && error?.code != LAError.Code.biometryLockout.rawValue {
        webAuthnLogError("Couldn't find local authenticators: \(error.map { "\($0)" } ?? "(null)")")
        return false
    }
    return true
}

#if WTF_PLATFORM_MAC
private func bundleName() -> WTF.String {
    NSRunningApplication.current.localizedName.map { WTF.String($0 as CFString) } ?? WTF.String()
}
#endif

private func shouldUseAlternateAttributes() -> Bool {
    #if ENABLE_SYNCED_CREDENTIALS
    // False when ASCWebKitSPISupport is absent.
    return WebKit.webAuthnASCShouldUseAlternateCredentialStore()
    #else
    return false
    #endif
}

// LOG_ERROR, which builds with assertions keep; the WebAuthn connections and authenticators share it.
func webAuthnLogError(_ message: @autoclosure () -> Swift.String) {
    #if ASSERT_ENABLED
    // The logger's interpolation takes an escaping autoclosure, which cannot capture the non-escaping `message`.
    let text = message()
    WebKit.LogChannel.WebAuthn().releaseLog.error("\(text, privacy: .public)")
    #endif
}

#endif // ENABLE_WEB_AUTHN
