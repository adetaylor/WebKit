/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(WEB_AUTHN)

#import "AuthenticationServicesCoreSPI.h"
#import "AuthenticationServicesForwardDeclarations.h"
#import "NearFieldSPI.h"
#import <Foundation/Foundation.h>

// What Swift sees of the soft-linked frameworks AuthenticationServices, AuthenticationServicesCore and NearField:
// - their classes, declared objc_runtime_visible for Swift (Swift looks each one up by name). A lookup made before the
//   framework is loaded misses; the hook installSoftLinkedClassLookupHook() installs then calls the class's soft-link
//   getter, which loads the framework and traps if it cannot, so the lookup never comes back nil;
// - the optional classes, which may be absent and so cannot trap, only through the helpers below: Swift cannot name
//   them, and sees what it makes of one as an NSObject, whose class the setters check;
// - the framework calls whose reply comes on a framework queue: Swift's block for one is Sendable (the
//   ASCWebKitSPISupport helpers also reply on the main run loop), and the delegates the framework calls there are
//   Objective-C;
// - the error domains' getters.
// The soft-link headers stay out of Swift: their class getters are shared mutable state, and their inline
// alloc<Class>Instance() would give Swift an object whose initializer never ran.

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

namespace WebKit {

#if !defined(__swift__)
// Called once in the UI process, before any of its Swift runs; only UI-process Swift names these classes.
void installSoftLinkedClassLookupHook();
#endif

NSErrorDomain get_AuthenticationServices_ASAuthorizationErrorDomainSingleton();

#if HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI) || HAVE(WEB_AUTHN_AS_MODERN)

NSErrorDomain get_AuthenticationServicesCore_ASCAuthorizationErrorDomainSingleton();

// ASCWebKitSPISupport's class members, as the Objective-C++ calls them: on an absent class they answer NO or nil, and
// the ones the class may not implement are guarded by respondsToSelector:.
bool webAuthnASCShouldUseAlternateCredentialStore();
bool webAuthnASCShouldUseAlternateKeychainAttribute();
NSData * _Nullable webAuthnASCEnterpriseAttestationIdentityPersistentReference(NSString * relyingParty);
NSData * _Nullable webAuthnASCAlternateLargeBlobIfNecessary(NSString * relyingParty, NSData * clientDataHash);
// Each returns whether it made the call; the handler is called only if it did, once, on the main run loop.
bool webAuthnASCGetCanCurrentProcessAccessPasskeys(NSString * relyingParty, NS_SWIFT_SENDABLE void (^)(BOOL));
bool webAuthnASCGetArePasskeysDisallowed(NSString * relyingParty, NS_SWIFT_SENDABLE void (^)(BOOL));
bool webAuthnASCGetClientCapabilities(NSString * relyingParty, NS_SWIFT_SENDABLE void (^)(NSDictionary<NSString *, NSNumber *> *));

#endif // HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI) || HAVE(WEB_AUTHN_AS_MODERN)

#if HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI)
// An ASCWebAuthenticationExtensionsClientInputs, or nil when the class is absent or has no initWithAppID:.
NSObject<NSCopying, NSSecureCoding> * _Nullable createWebAuthnASCExtensionsClientInputs(NSString * _Nullable appID) NS_RETURNS_RETAINED;
// An ASGlobalFrameIdentifier, or nil when the class is absent.
NSObject<NSCopying, NSSecureCoding> * _Nullable createWebAuthnASGlobalFrameIdentifier(NSNumber * pageID, NSNumber * frameID) NS_RETURNS_RETAINED;

// Each traps unless the value is nil or of the class the matching create function above makes, as the runtime gives
// it rather than as the object answers -isKindOfClass:.
void webAuthnSetASCAssertionOptionsExtensions(ASCPublicKeyCredentialAssertionOptions *, NSObject<NSCopying, NSSecureCoding> * _Nullable extensions);
void webAuthnSetASCCreationOptionsExtensions(ASCPublicKeyCredentialCreationOptions *, NSObject<NSCopying, NSSecureCoding> * _Nullable extensions);
// Returns whether the context has the property (as the Objective-C++ asks); sets it only if so.
bool webAuthnSetASCCredentialRequestContextGlobalFrameID(ASCCredentialRequestContext *, NSObject<NSCopying, NSSecureCoding> * _Nullable globalFrameID);
#endif

#if HAVE(NEAR_FIELD)
// false when NearField has no hardware manager.
bool webAuthnNFIsReaderModeSupported();
// Starts a reader session on the shared hardware manager, whose reply comes on NearField's queue. nil, with no call
// made and the handler never called, when NearField has no hardware manager.
NSObject<NFSession> * _Nullable webAuthnNFStartReaderSession(NS_SWIFT_SENDABLE void (^)(NFReaderSession * _Nullable, NSError * _Nullable));
#endif

} // namespace WebKit

NS_HEADER_AUDIT_END(nullability, sendability)

#endif // ENABLE(WEB_AUTHN)
