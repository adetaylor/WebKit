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

#import "config.h"
#import "WebAuthnSoftLinkForSwift.h"

#if ENABLE(WEB_AUTHN)

#import <array>
#import <mutex>
#import <objc/runtime.h>
#import <wtf/SetForScope.h>
#import <wtf/StdLibExtras.h>
#import <wtf/text/ASCIILiteral.h>
#import <wtf/text/StringCommon.h>

#import "AuthenticationServicesCoreSoftLink.h"
#import "AuthenticationServicesSoftLink.h"
#import "NearFieldSoftLink.h"

namespace WebKit {

// The classes Swift may look up by name whose soft link is not optional, each with its getter. The optional ones
// (ASCWebKitSPISupport, ASCWebAuthenticationExtensionsClientInputs, ASGlobalFrameIdentifier, NFHardwareManager) are
// left out: they may be absent, and MockNfcService registers an NFHardwareManager where NearField has none.
struct SoftLinkedClass {
    ASCIILiteral name;
    ::Class (**getter)();
};

static constexpr auto softLinkedClasses = WTF::toArray<SoftLinkedClass>({
    { "ASAuthorizationController"_s, &getASAuthorizationControllerClassSingleton },
    { "ASAuthorizationPlatformPublicKeyCredentialProvider"_s, &getASAuthorizationPlatformPublicKeyCredentialProviderClassSingleton },
#if HAVE(SECURITY_KEY_API)
    { "ASAuthorizationSecurityKeyPublicKeyCredentialProvider"_s, &getASAuthorizationSecurityKeyPublicKeyCredentialProviderClassSingleton },
#endif
#if HAVE(WEB_AUTHN_PUBLIC_KEY_CREDENTIAL_MANAGER)
    { "ASAuthorizationWebBrowserPublicKeyCredentialManager"_s, &getASAuthorizationWebBrowserPublicKeyCredentialManagerClassSingleton },
#endif
    { "ASPublicKeyCredentialClientData"_s, &getASPublicKeyCredentialClientDataClassSingleton },
    { "ASAuthorizationPlatformPublicKeyCredentialRegistration"_s, &getASAuthorizationPlatformPublicKeyCredentialRegistrationClassSingleton },
    { "ASAuthorizationSecurityKeyPublicKeyCredentialRegistration"_s, &getASAuthorizationSecurityKeyPublicKeyCredentialRegistrationClassSingleton },
    { "ASAuthorizationPlatformPublicKeyCredentialAssertion"_s, &getASAuthorizationPlatformPublicKeyCredentialAssertionClassSingleton },
    { "ASAuthorizationPublicKeyCredentialParameters"_s, &getASAuthorizationPublicKeyCredentialParametersClassSingleton },
    { "ASAuthorizationPlatformPublicKeyCredentialDescriptor"_s, &getASAuthorizationPlatformPublicKeyCredentialDescriptorClassSingleton },
    { "ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor"_s, &getASAuthorizationSecurityKeyPublicKeyCredentialDescriptorClassSingleton },
    { "ASAuthorizationSecurityKeyPublicKeyCredentialAssertion"_s, &getASAuthorizationSecurityKeyPublicKeyCredentialAssertionClassSingleton },
    { "ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput"_s, &getASAuthorizationPublicKeyCredentialLargeBlobAssertionInputClassSingleton },
    { "ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput"_s, &getASAuthorizationPublicKeyCredentialLargeBlobRegistrationInputClassSingleton },
#if HAVE(WEB_AUTHN_PRF_API)
    { "ASAuthorizationPublicKeyCredentialPRFRegistrationInput"_s, &getASAuthorizationPublicKeyCredentialPRFRegistrationInputClassSingleton },
    { "ASAuthorizationPublicKeyCredentialPRFAssertionInputValues"_s, &getASAuthorizationPublicKeyCredentialPRFAssertionInputValuesClassSingleton },
    { "ASAuthorizationPublicKeyCredentialPRFAssertionInput"_s, &getASAuthorizationPublicKeyCredentialPRFAssertionInputClassSingleton },
#endif
#if HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI)
    { "ASCAgentProxy"_s, &getASCAgentProxyClassSingleton },
    { "ASCAppleIDCredential"_s, &getASCAppleIDCredentialClassSingleton },
    { "ASCAuthorizationPresentationContext"_s, &getASCAuthorizationPresentationContextClassSingleton },
    { "ASCAuthorizationPresenter"_s, &getASCAuthorizationPresenterClassSingleton },
    { "ASCAuthorizationRemotePresenter"_s, &getASCAuthorizationRemotePresenterClassSingleton },
    { "ASCCredentialRequestContext"_s, &getASCCredentialRequestContextClassSingleton },
    { "ASCPlatformPublicKeyCredentialAssertion"_s, &getASCPlatformPublicKeyCredentialAssertionClassSingleton },
    { "ASCPlatformPublicKeyCredentialLoginChoice"_s, &getASCPlatformPublicKeyCredentialLoginChoiceClassSingleton },
    { "ASCPlatformPublicKeyCredentialRegistration"_s, &getASCPlatformPublicKeyCredentialRegistrationClassSingleton },
    { "ASCPublicKeyCredentialAssertionOptions"_s, &getASCPublicKeyCredentialAssertionOptionsClassSingleton },
    { "ASCPublicKeyCredentialCreationOptions"_s, &getASCPublicKeyCredentialCreationOptionsClassSingleton },
    { "ASCPublicKeyCredentialDescriptor"_s, &getASCPublicKeyCredentialDescriptorClassSingleton },
    { "ASCSecurityKeyPublicKeyCredentialAssertion"_s, &getASCSecurityKeyPublicKeyCredentialAssertionClassSingleton },
    { "ASCSecurityKeyPublicKeyCredentialLoginChoice"_s, &getASCSecurityKeyPublicKeyCredentialLoginChoiceClassSingleton },
    { "ASCSecurityKeyPublicKeyCredentialRegistration"_s, &getASCSecurityKeyPublicKeyCredentialRegistrationClassSingleton },
#endif
#if HAVE(NEAR_FIELD)
    { "NFTag"_s, &getNFTagClassSingleton },
    { "NFSession"_s, &getNFSessionClassSingleton },
    { "NFReaderSession"_s, &getNFReaderSessionClassSingleton },
#endif
});

// The classes Swift may name that have no getter (it casts to them; C++ never makes one), each with its framework.
// A miss loads the framework, so that a cast made before anything else loaded it is still right.
struct SoftLinkedClassWithoutGetter {
    ASCIILiteral name;
    void* (*library)(bool isOptional);
};

static constexpr auto softLinkedClassesWithoutGetter = WTF::toArray<SoftLinkedClassWithoutGetter>({
    { "ASAuthorization"_s, &AuthenticationServicesLibrary },
    { "ASAuthorizationRequest"_s, &AuthenticationServicesLibrary },
    { "ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest"_s, &AuthenticationServicesLibrary },
    { "ASAuthorizationPlatformPublicKeyCredentialAssertionRequest"_s, &AuthenticationServicesLibrary },
#if HAVE(SECURITY_KEY_API)
    { "ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest"_s, &AuthenticationServicesLibrary },
    { "ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest"_s, &AuthenticationServicesLibrary },
#endif
    { "ASAuthorizationPublicKeyCredentialLargeBlobRegistrationOutput"_s, &AuthenticationServicesLibrary },
    { "ASAuthorizationPublicKeyCredentialLargeBlobAssertionOutput"_s, &AuthenticationServicesLibrary },
#if HAVE(WEB_AUTHN_PRF_API)
    { "ASAuthorizationPublicKeyCredentialPRFRegistrationOutput"_s, &AuthenticationServicesLibrary },
    { "ASAuthorizationPublicKeyCredentialPRFAssertionOutput"_s, &AuthenticationServicesLibrary },
#endif
});

static objc_hook_getClass previousGetClassHook;

// Set while the hook loads a class, so that the getter's own lookup of it goes to the previous hook.
static thread_local bool isLoadingSoftLinkedClass;

// Runs only when a lookup misses: once per class, or never if the framework was already loaded.
static BOOL softLinkedClassLookupHook(const char* name, Class* outClass)
{
    if (isLoadingSoftLinkedClass)
        return previousGetClassHook(name, outClass);

    auto nameSpan = unsafeSpan(name);
    for (auto& entry : softLinkedClasses) {
        if (!equalSpans(entry.name.span(), nameSpan))
            continue;
        SetForScope loading(isLoadingSoftLinkedClass, true);
        // The getter loads the framework and RELEASE_ASSERTs the class.
        *outClass = (*entry.getter)();
        return YES;
    }
    for (auto& entry : softLinkedClassesWithoutGetter) {
        if (!equalSpans(entry.name.span(), nameSpan))
            continue;
        SetForScope loading(isLoadingSoftLinkedClass, true);
        entry.library(false);
        // The header declares the class, so the framework must have it: a nil here would reach Swift as a nil
        // object in a non-optional reference.
        SUPPRESS_UNRETAINED_LOCAL Class result = objc_getClass(name);
        RELEASE_ASSERT(result);
        *outClass = result;
        return YES;
    }
    return previousGetClassHook(name, outClass);
}

void installSoftLinkedClassLookupHook()
{
    static std::once_flag once;
    std::call_once(once, [] {
        objc_setHook_getClass(softLinkedClassLookupHook, &previousGetClassHook);
    });
}

#if HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI) || HAVE(WEB_AUTHN_AS_MODERN)

bool webAuthnASCShouldUseAlternateCredentialStore()
{
    return [getASCWebKitSPISupportClassSingleton() shouldUseAlternateCredentialStore];
}

bool webAuthnASCShouldUseAlternateKeychainAttribute()
{
    if (![getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(shouldUseAlternateKeychainAttribute)])
        return false;
    return [getASCWebKitSPISupportClassSingleton() shouldUseAlternateKeychainAttribute];
}

NSData *webAuthnASCEnterpriseAttestationIdentityPersistentReference(NSString *relyingParty)
{
    return [getASCWebKitSPISupportClassSingleton() entepriseAttestationIdentityPersistentReferenceForRelyingParty:relyingParty];
}

NSData *webAuthnASCAlternateLargeBlobIfNecessary(NSString *relyingParty, NSData *clientDataHash)
{
    if (![getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(alternateLargeBlobIfNecessaryForRelyingParty:clientDataHash:)])
        return nil;
    return [getASCWebKitSPISupportClassSingleton() alternateLargeBlobIfNecessaryForRelyingParty:relyingParty clientDataHash:clientDataHash];
}

bool webAuthnASCGetCanCurrentProcessAccessPasskeys(NSString *relyingParty, void (^completionHandler)(BOOL))
{
    if (![getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(getCanCurrentProcessAccessPasskeysForRelyingParty:withCompletionHandler:)])
        return false;
    [getASCWebKitSPISupportClassSingleton() getCanCurrentProcessAccessPasskeysForRelyingParty:relyingParty withCompletionHandler:completionHandler];
    return true;
}

bool webAuthnASCGetArePasskeysDisallowed(NSString *relyingParty, void (^completionHandler)(BOOL))
{
    if (![getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(getArePasskeysDisallowedForRelyingParty:withCompletionHandler:)])
        return false;
    [getASCWebKitSPISupportClassSingleton() getArePasskeysDisallowedForRelyingParty:relyingParty withCompletionHandler:completionHandler];
    return true;
}

bool webAuthnASCGetClientCapabilities(NSString *relyingParty, void (^completionHandler)(NSDictionary<NSString *, NSNumber *> *))
{
    if (![getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(getClientCapabilitiesForRelyingParty:withCompletionHandler:)])
        return false;
    [getASCWebKitSPISupportClassSingleton() getClientCapabilitiesForRelyingParty:relyingParty withCompletionHandler:completionHandler];
    return true;
}

#endif // HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI) || HAVE(WEB_AUTHN_AS_MODERN)

#if HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI)

NSObject<NSCopying, NSSecureCoding> *createWebAuthnASCExtensionsClientInputs(NSString *appID)
{
    if (![getASCWebAuthenticationExtensionsClientInputsClassSingleton() instancesRespondToSelector:@selector(initWithAppID:)])
        return nil;
    return [allocASCWebAuthenticationExtensionsClientInputsInstance() initWithAppID:appID];
}

NSObject<NSCopying, NSSecureCoding> *createWebAuthnASGlobalFrameIdentifier(NSNumber *pageID, NSNumber *frameID)
{
    return [allocASGlobalFrameIdentifierInstance() initWithPageID:pageID frameID:frameID];
}

// Whether the object's class is the class or a subclass of it, asked of the runtime rather than of the object, whose
// -isKindOfClass: a subclass may override. false when the class is absent.
static bool isObjectOfSoftLinkedClass(id object, Class expectedClass)
{
    if (!expectedClass)
        return false;
    for (SUPPRESS_UNRETAINED_LOCAL Class objectClass = object_getClass(object); objectClass; objectClass = class_getSuperclass(objectClass)) {
        if (objectClass == expectedClass)
            return true;
    }
    return false;
}

// Swift sees the optional classes' objects as NSObject, so each setter checks the class; when the class is absent, only
// nil passes.
void webAuthnSetASCAssertionOptionsExtensions(ASCPublicKeyCredentialAssertionOptions *options, NSObject<NSCopying, NSSecureCoding> *extensions)
{
    RELEASE_ASSERT(!extensions || isObjectOfSoftLinkedClass(extensions, getASCWebAuthenticationExtensionsClientInputsClassSingleton()));
    options.extensions = static_cast<ASCWebAuthenticationExtensionsClientInputs *>(extensions);
}

void webAuthnSetASCCreationOptionsExtensions(ASCPublicKeyCredentialCreationOptions *options, NSObject<NSCopying, NSSecureCoding> *extensions)
{
    RELEASE_ASSERT(!extensions || isObjectOfSoftLinkedClass(extensions, getASCWebAuthenticationExtensionsClientInputsClassSingleton()));
    options.extensions = static_cast<ASCWebAuthenticationExtensionsClientInputs *>(extensions);
}

bool webAuthnSetASCCredentialRequestContextGlobalFrameID(ASCCredentialRequestContext *context, NSObject<NSCopying, NSSecureCoding> *globalFrameID)
{
    RELEASE_ASSERT(!globalFrameID || isObjectOfSoftLinkedClass(globalFrameID, getASGlobalFrameIdentifierClassSingleton()));
    if (![context respondsToSelector:@selector(setGlobalFrameID:)])
        return false;
    context.globalFrameID = static_cast<ASGlobalFrameIdentifier *>(globalFrameID);
    return true;
}

#endif // HAVE(ASC_AUTH_UI) || HAVE(UNIFIED_ASC_AUTH_UI)

#if HAVE(NEAR_FIELD)

bool webAuthnNFIsReaderModeSupported()
{
    return [[getNFHardwareManagerClassSingleton() sharedHardwareManager] areFeaturesSupported:NFFeatureReaderMode outError:nil];
}

NSObject<NFSession> *webAuthnNFStartReaderSession(void (^startCallback)(NFReaderSession *, NSError *))
{
    return [[getNFHardwareManagerClassSingleton() sharedHardwareManager] startReaderSession:startCallback];
}

#endif // HAVE(NEAR_FIELD)

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
