/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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

// Swift refers to these classes through objc_lookUpClass instead of a class symbol, which the soft link does not
// provide. A lookup made before the framework is loaded misses, and the class lookup hook WebKit installs at
// initialization (WebAuthnSoftLinkForSwift.h) then loads it through the soft-link getter, which traps if it cannot.
// Objective-C++ is unaffected.
#ifndef WK_SOFT_LINKED_OBJC_CLASS
#if defined(__swift__)
#define WK_SOFT_LINKED_OBJC_CLASS __attribute__((objc_runtime_visible))
#else
#define WK_SOFT_LINKED_OBJC_CLASS
#endif
#endif

OBJC_CLASS NSString;
typedef NSString *ASAuthorizationPublicKeyCredentialUserVerificationPreference;
typedef NSString *ASAuthorizationCustomMethod;

#if PLATFORM(MAC)
@class NSWindow;
typedef NSWindow *ASPresentationAnchor;
#else
@class UIWindow;
typedef UIWindow *ASPresentationAnchor;
#endif

@class ASAuthorizationController;

NS_ASSUME_NONNULL_BEGIN

@protocol ASAuthorizationControllerPresentationContextProviding <NSObject>
@required

#if !TARGET_OS_WATCH
- (ASPresentationAnchor)presentationAnchorForAuthorizationController:(ASAuthorizationController *)controller;
#endif

@end

@protocol ASAuthorizationProvider <NSObject>

@end

@protocol ASAuthorizationCredential <NSObject, NSCopying, NSSecureCoding>

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorization : NSObject

@property (nonatomic, readonly, strong) id<ASAuthorizationProvider> provider;

@property (nonatomic, readonly, strong) id<ASAuthorizationCredential> credential;

+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)init NS_UNAVAILABLE;

@end

@protocol ASAuthorizationControllerDelegate <NSObject>
@optional

- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithAuthorization:(ASAuthorization *)authorization NS_SWIFT_NAME(authorizationController(controller:didCompleteWithAuthorization:));
- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithError:(NSError *)error NS_SWIFT_NAME(authorizationController(controller:didCompleteWithError:));

- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithCustomMethod:(ASAuthorizationCustomMethod)method;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationRequest : NSObject <NSCopying, NSSecureCoding>
@property (nonatomic, readonly, strong) id<ASAuthorizationProvider> provider;
@end
typedef NSString *ASAuthorizationPublicKeyCredentialAttestationKind;

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationController : NSObject
@property (nonatomic, weak, nullable) id<ASAuthorizationControllerDelegate> delegate;
@property (nonatomic, weak, nullable) id<ASAuthorizationControllerPresentationContextProviding> presentationContextProvider;

- (void)cancel;

+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithAuthorizationRequests:(NSArray<ASAuthorizationRequest *> *)authorizationRequests;

- (void)performRequests;
- (void)performAutoFillAssistedRequests;
@end

@protocol ASAuthorizationPublicKeyCredentialRegistrationRequest <NSObject, NSSecureCoding, NSCopying>

@property (nonatomic, readonly, copy) NSString *relyingPartyIdentifier;

@property (nonatomic, copy) NSData *userID;

@property (nonatomic, copy) NSString *name;

@property (nonatomic, nullable, copy) NSString *displayName;

@property (nonatomic, copy) NSData *challenge;

@property (nonatomic, strong) ASAuthorizationPublicKeyCredentialUserVerificationPreference userVerificationPreference;

@property (nonatomic, strong) ASAuthorizationPublicKeyCredentialAttestationKind attestationPreference;

@end

typedef NS_ENUM(NSInteger, ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement) {
    ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirementRequired,
    ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirementPreferred,
};

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput : NSObject
- (instancetype)initWithSupportRequirement:(ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement)requirement;
@property (nonatomic, assign) ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement supportRequirement;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialLargeBlobRegistrationOutput : NSObject

@property (nonatomic, readonly) BOOL isSupported;

@end

typedef NS_ENUM(NSInteger, ASAuthorizationPublicKeyCredentialAttachment) {
    ASAuthorizationPublicKeyCredentialAttachmentPlatform,
    ASAuthorizationPublicKeyCredentialAttachmentCrossPlatform,
};

@protocol ASPublicKeyCredential <ASAuthorizationCredential>

@property (nonatomic, readonly, copy) NSData *rawClientDataJSON;

@property (nonatomic, readonly, copy) NSData *credentialID;

@end

@protocol ASAuthorizationPublicKeyCredentialRegistration <ASPublicKeyCredential>

@property (nonatomic, readonly, nullable, copy) NSData *rawAttestationObject;

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPlatformPublicKeyCredentialRegistration : NSObject <ASAuthorizationPublicKeyCredentialRegistration>
@property (nonatomic, readonly) ASAuthorizationPublicKeyCredentialAttachment attachment;
@property (nonatomic, readonly, nullable) ASAuthorizationPublicKeyCredentialLargeBlobRegistrationOutput *largeBlob NS_REFINED_FOR_SWIFT;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest : ASAuthorizationRequest <ASAuthorizationPublicKeyCredentialRegistrationRequest>

@property (nonatomic, nullable, copy) ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput *largeBlob;

@end

typedef NS_ENUM(NSInteger, ASPublicKeyCredentialClientDataCrossOriginValue) {
    ASPublicKeyCredentialClientDataCrossOriginValueNotSet,
    ASPublicKeyCredentialClientDataCrossOriginValueCrossOrigin,
    ASPublicKeyCredentialClientDataCrossOriginValueSameOriginWithAncestors,
};

WK_SOFT_LINKED_OBJC_CLASS
@interface ASPublicKeyCredentialClientData : NSObject
- (instancetype)initWithChallenge:(NSData *)challenge origin:(NSString *)origin;

@property (nonatomic, copy) NSData *challenge;

@property (nonatomic, copy) NSString *origin;

@property (nonatomic, copy, nullable) NSString *topOrigin;

@property (nonatomic) ASPublicKeyCredentialClientDataCrossOriginValue crossOrigin;

@end

@protocol ASAuthorizationPublicKeyCredentialDescriptor <NSObject, NSSecureCoding, NSCopying>

@property (nonatomic, copy) NSData *credentialID;

@end

@protocol ASAuthorizationPublicKeyCredentialAssertionRequest <NSObject, NSSecureCoding, NSCopying>

@property (nonatomic, copy) NSData *challenge;

@property (nonatomic, copy) NSString *relyingPartyIdentifier;

@property (nonatomic, copy) NSArray<id<ASAuthorizationPublicKeyCredentialDescriptor>> *allowedCredentials;

@property (nonatomic, copy) ASAuthorizationPublicKeyCredentialUserVerificationPreference userVerificationPreference;

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPlatformPublicKeyCredentialDescriptor : NSObject <ASAuthorizationPublicKeyCredentialDescriptor>

- (instancetype)initWithCredentialID:(NSData *)credentialID NS_DESIGNATED_INITIALIZER;

@end

@protocol ASAuthorizationWebBrowserPlatformPublicKeyCredentialRegistrationRequest
@property (nonatomic, readonly, nullable) ASPublicKeyCredentialClientData *clientData;
@property (nonatomic, nullable, copy) NSArray<ASAuthorizationPlatformPublicKeyCredentialDescriptor *> *excludedCredentials;
@property (nonatomic) BOOL shouldShowHybridTransport;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest () <ASAuthorizationWebBrowserPlatformPublicKeyCredentialRegistrationRequest>
@end

typedef NS_ENUM(NSInteger, ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperation) {
    ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperationRead,
    ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperationWrite,
};

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput : NSObject
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithOperation:(ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperation)operation;

@property (nonatomic, readonly) ASAuthorizationPublicKeyCredentialLargeBlobAssertionOperation operation;
@property (nonatomic, nullable, copy) NSData *dataToWrite;

@end

@protocol ASAuthorizationPublicKeyCredentialAssertion <ASPublicKeyCredential>

@property (nonatomic, readonly, copy) NSData *rawAuthenticatorData;

@property (nonatomic, readonly, copy) NSData *userID;

@property (nonatomic, readonly, copy) NSData *signature;

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialLargeBlobAssertionOutput : NSObject

@property (nonatomic, nullable, readonly) NSData *readData;
@property (nonatomic, readonly) BOOL didWrite;

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPlatformPublicKeyCredentialAssertion : NSObject <ASAuthorizationPublicKeyCredentialAssertion>
@property (nonatomic, readonly) ASAuthorizationPublicKeyCredentialAttachment attachment;

@property (nonatomic, readonly, nullable) ASAuthorizationPublicKeyCredentialLargeBlobAssertionOutput *largeBlob NS_REFINED_FOR_SWIFT;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPlatformPublicKeyCredentialAssertionRequest : ASAuthorizationRequest <ASAuthorizationPublicKeyCredentialAssertionRequest>
@property (nonatomic, copy) NSArray<ASAuthorizationPlatformPublicKeyCredentialDescriptor *> *allowedCredentials;
@property (nonatomic, nullable, copy) ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput *largeBlob;
@end

@protocol ASAuthorizationWebBrowserPlatformPublicKeyCredentialAssertionRequest
@property (nonatomic, readonly, nullable) ASPublicKeyCredentialClientData *clientData;
@property (nonatomic) BOOL shouldShowHybridTransport;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialAssertionRequest () <ASAuthorizationWebBrowserPlatformPublicKeyCredentialAssertionRequest>
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPlatformPublicKeyCredentialProvider : NSObject <ASAuthorizationProvider>

- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier NS_DESIGNATED_INITIALIZER;

- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge name:(NSString *)name userID:(NSData *)userID NS_SWIFT_NAME(createCredentialRegistrationRequest(challenge:name:userID:));

- (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithChallenge:(NSData *)challenge NS_SWIFT_NAME(createCredentialAssertionRequest(challenge:));

- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData name:(NSString *)name userID:(NSData *)userID;

- (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData;


@property (nonatomic, readonly, copy) NSString *relyingPartyIdentifier;
@end

@protocol ASAuthorizationWebBrowserPlatformPublicKeyCredentialProvider

- (ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData name:(NSString *)name userID:(NSData *)userID;

- (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData;

@end

@interface ASAuthorizationPlatformPublicKeyCredentialProvider () <ASAuthorizationWebBrowserPlatformPublicKeyCredentialProvider>
@end

typedef NSString *ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport;

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor : NSObject <ASAuthorizationPublicKeyCredentialDescriptor>

- (instancetype)initWithCredentialID:(NSData *)credentialID transports:(NSArray<ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport> *)allowedTransports;

@property (nonatomic, copy) NSArray<ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport> *transports;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationSecurityKeyPublicKeyCredentialRegistration : NSObject <ASAuthorizationPublicKeyCredentialRegistration>
@property (nonatomic, readonly) NSArray<ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport> *transports;
@end

typedef NSInteger ASCOSEAlgorithmIdentifier NS_TYPED_EXTENSIBLE_ENUM;

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialParameters : NSObject <NSSecureCoding, NSCopying>

- (instancetype)initWithAlgorithm:(ASCOSEAlgorithmIdentifier)algorithm;

@property (nonatomic, readonly) ASCOSEAlgorithmIdentifier algorithm;

@end

typedef NSString *ASAuthorizationPublicKeyCredentialResidentKeyPreference;

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest : ASAuthorizationRequest <ASAuthorizationPublicKeyCredentialRegistrationRequest>

@property (nonatomic, copy) NSArray<ASAuthorizationPublicKeyCredentialParameters *> *credentialParameters;

@property (nonatomic, copy) NSArray<ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor *> *excludedCredentials;

@property (nonatomic, copy) ASAuthorizationPublicKeyCredentialResidentKeyPreference residentKeyPreference;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationSecurityKeyPublicKeyCredentialAssertion : NSObject <ASAuthorizationPublicKeyCredentialAssertion>
@property (nonatomic, readonly) BOOL appID;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest : ASAuthorizationRequest <ASAuthorizationPublicKeyCredentialAssertionRequest>

@property (nonatomic, copy) NSArray<ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor *> *allowedCredentials;
@property (nonatomic, nullable, copy) NSString *appID;

@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationSecurityKeyPublicKeyCredentialProvider : NSObject <ASAuthorizationProvider>

- (instancetype)initWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier NS_DESIGNATED_INITIALIZER;

- (ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithChallenge:(NSData *)challenge displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID NS_SWIFT_NAME(createCredentialRegistrationRequest(challenge:displayName:name:userID:));

- (ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithChallenge:(NSData *)challenge NS_SWIFT_NAME(createCredentialAssertionRequest(challenge:));

- (ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest *)createCredentialRegistrationRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData displayName:(NSString *)displayName name:(NSString *)name userID:(NSData *)userID;

- (ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest *)createCredentialAssertionRequestWithClientData:(ASPublicKeyCredentialClientData *)clientData;

@property (nonatomic, readonly, copy) NSString *relyingPartyIdentifier;

@end

typedef NS_ENUM(NSInteger, ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyle) {
    ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyleStandard,
    ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyleConditional,
};

@interface ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest ()
@property (nonatomic) ASAuthorizationPlatformPublicKeyCredentialRegistrationRequestStyle requestStyle;
@end

#if HAVE(WEB_AUTHN_PRF_API)
WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialPRFAssertionOutput : NSObject
@property (nonatomic, readonly) NSData *first;
@property (nonatomic, nullable, readonly) NSData *second;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialPRFAssertionInputValues : NSObject
- (instancetype)initWithSaltInput1:(NSData *)saltInput1 saltInput2:(nullable NSData *)saltInput2;
@property (nonatomic, readonly) NSData *saltInput1;
@property (nonatomic, nullable, readonly) NSData *saltInput2;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialPRFAssertionInput : NSObject
- (instancetype)initWithInputValues:(nullable ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *)inputValues perCredentialInputValues:(nullable NSDictionary<NSData *, ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *> *)perCredentialInputValues;
@property (nonatomic, nullable, readonly) ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *inputValues;
@property (nonatomic, nullable, readonly) NSDictionary<NSData *, ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *> *perCredentialInputValues;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialAssertionRequest ()
@property (nonatomic, nullable) ASAuthorizationPublicKeyCredentialPRFAssertionInput *prf;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialAssertion ()
@property (nonatomic, nullable, readonly) ASAuthorizationPublicKeyCredentialPRFAssertionOutput *prf;
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest ()
@property (nonatomic, nullable) ASAuthorizationPublicKeyCredentialPRFAssertionInput *prf;
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialAssertion ()
@property (nonatomic, nullable, readonly) ASAuthorizationPublicKeyCredentialPRFAssertionOutput *prf;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialPRFRegistrationInput : NSObject
+ (instancetype)checkForSupport;
- (instancetype)initWithInputValues:(nullable ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *)inputValues;
@property (nonatomic, readonly) BOOL shouldCheckForSupport;
@property (nonatomic, nullable, readonly) ASAuthorizationPublicKeyCredentialPRFAssertionInputValues *inputValues;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest ()
@property (nonatomic, nullable) ASAuthorizationPublicKeyCredentialPRFRegistrationInput *prf;
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest ()
@property (nonatomic, nullable) ASAuthorizationPublicKeyCredentialPRFRegistrationInput *prf;
@end

WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationPublicKeyCredentialPRFRegistrationOutput : NSObject
@property (nonatomic, readonly) BOOL isSupported;
@property (nonatomic, nullable, readonly) NSData *first;
@property (nonatomic, nullable, readonly) NSData *second;
@end

@interface ASAuthorizationPlatformPublicKeyCredentialRegistration ()
@property (nonatomic, nullable, readonly) ASAuthorizationPublicKeyCredentialPRFRegistrationOutput *prf;
@end

@interface ASAuthorizationSecurityKeyPublicKeyCredentialRegistration ()
@property (nonatomic, nullable, readonly) ASAuthorizationPublicKeyCredentialPRFRegistrationOutput *prf;
@end
#endif

extern NSErrorDomain const ASAuthorizationErrorDomain;

typedef NS_ERROR_ENUM(ASAuthorizationErrorDomain, ASAuthorizationError) {
    ASAuthorizationErrorUnknown = 1000,
    ASAuthorizationErrorCanceled = 1001,
    ASAuthorizationErrorInvalidResponse = 1002,
    ASAuthorizationErrorNotHandled = 1003,
    ASAuthorizationErrorFailed = 1004,
    ASAuthorizationErrorNotInteractive = 1005,
    ASAuthorizationErrorMatchedExcludedCredential = 1006,
#if HAVE(CROSS_DEVICE_FALLBACK_URL_API)
    ASAuthorizationErrorCrossDeviceFallback = 1011,
#endif
};

#if HAVE(WEB_AUTHN_PUBLIC_KEY_CREDENTIAL_MANAGER)
WK_SOFT_LINKED_OBJC_CLASS
@interface ASAuthorizationWebBrowserPublicKeyCredentialManager : NSObject
@property (class, nonatomic, readonly) BOOL isDeviceConfiguredForPasskeys;
@end
#endif

NS_ASSUME_NONNULL_END
