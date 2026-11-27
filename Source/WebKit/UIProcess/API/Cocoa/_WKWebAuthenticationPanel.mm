/*
 * Copyright (C) 2019-2021 Apple Inc. All rights reserved.
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
#import "_WKWebAuthenticationPanelInternal.h"


#import "LocalAuthenticator.h"
#import "LocalService.h"
#import "Logging.h"
#import "WebAuthenticationPanelClient.h"
#import "WebAuthenticationPanelCredentials.h"
#import "WebKit-Swift.h"
#import "_WKAuthenticationExtensionsClientInputs.h"
#import "_WKAuthenticationExtensionsClientOutputsInternal.h"
#import "_WKAuthenticatorSelectionCriteria.h"
#import "_WKPublicKeyCredentialCreationOptions.h"
#import "_WKPublicKeyCredentialDescriptor.h"
#import "_WKPublicKeyCredentialParameters.h"
#import "_WKPublicKeyCredentialRequestOptions.h"
#import "_WKPublicKeyCredentialRelyingPartyEntity.h"
#import "_WKPublicKeyCredentialUserEntity.h"
#import <WebCore/AuthenticationExtensionsClientInputs.h>
#import <WebCore/AuthenticatorAttachment.h>
#import <WebCore/AuthenticatorSelectionCriteria.h>
#import <WebCore/BufferSource.h>
#import <WebCore/CredentialRequestOptions.h>
#import <WebCore/MediationRequirement.h>
#import <WebCore/MockWebAuthenticationConfiguration.h>
#import <WebCore/PublicKeyCredentialCreationOptions.h>
#import <WebCore/PublicKeyCredentialRequestOptions.h>
#import <WebCore/WebAuthenticationConstants.h>
#import <WebCore/WebCoreObjCExtras.h>
#import <objc/runtime.h>
#import <wtf/RetainPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/text/Base64.h>

#import "AuthenticationServicesCoreSoftLink.h"

NSString * const _WKLocalAuthenticatorCredentialNameKey = @"_WKLocalAuthenticatorCredentialNameKey";
NSString * const _WKLocalAuthenticatorCredentialDisplayNameKey = @"_WKLocalAuthenticatorCredentialDisplayNameKey";
NSString * const _WKLocalAuthenticatorCredentialIDKey = @"_WKLocalAuthenticatorCredentialIDKey";
NSString * const _WKLocalAuthenticatorCredentialRelyingPartyIDKey = @"_WKLocalAuthenticatorCredentialRelyingPartyIDKey";
NSString * const _WKLocalAuthenticatorCredentialLastModificationDateKey = @"_WKLocalAuthenticatorCredentialLastModificationDateKey";
NSString * const _WKLocalAuthenticatorCredentialCreationDateKey = @"_WKLocalAuthenticatorCredentialCreationDateKey";
NSString * const _WKLocalAuthenticatorCredentialGroupKey = @"_WKLocalAuthenticatorCredentialGroupKey";
NSString * const _WKLocalAuthenticatorCredentialSynchronizableKey = @"_WKLocalAuthenticatorCredentialSynchronizableKey";
NSString * const _WKLocalAuthenticatorCredentialUserHandleKey = @"_WKLocalAuthenticatorCredentialUserHandleKey";
NSString * const _WKLocalAuthenticatorCredentialLastUsedDateKey = @"_WKLocalAuthenticatorCredentialLastUsedDateKey";

@implementation _WKWebAuthenticationPanel {
#if ENABLE(WEB_AUTHN)
    WeakPtr<WebKit::WebAuthenticationPanelClient> _client;
    RetainPtr<NSMutableSet> _transports;
#endif
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;

#if ENABLE(WEB_AUTHN)
    API::Object::constructInWrapper<API::WebAuthenticationPanel>(self);
#endif
    return self;
}

#if ENABLE(WEB_AUTHN)

- (void)dealloc
{
    if (WebCoreObjCScheduleDeallocateOnMainRunLoop(_WKWebAuthenticationPanel.class, self))
        return;

    protect(*_panel)->~WebAuthenticationPanel();

    [super dealloc];
}

- (id <_WKWebAuthenticationPanelDelegate>)delegate
{
    RefPtr client = _client.get();
    if (!client)
        return nil;
    return client->delegate().autorelease();
}

- (void)setDelegate:(id<_WKWebAuthenticationPanelDelegate>)delegate
{
    Ref client = WebKit::WebAuthenticationPanelClient::create(self, delegate);
    _client = client.ptr();
    protect(*_panel)->setClient(WTF::move(client));
}


- (NSString *)relyingPartyID
{
    return _panel->rpId().createNSString().autorelease();
}

- (NSSet *)transports
{
    if (!_transports)
        _transports = [self makeTransports];
    return _transports.get();
}

- (_WKWebAuthenticationType)type
{
    return [self webAuthenticationType];
}

- (NSString *)userName
{
    return _panel->userName().createNSString().autorelease();
}

#else // ENABLE(WEB_AUTHN)
- (id <_WKWebAuthenticationPanelDelegate>)delegate
{
    return nil;
}
- (void)setDelegate:(id<_WKWebAuthenticationPanelDelegate>)delegate
{
}
#endif // ENABLE(WEB_AUTHN)

+ (NSArray<NSDictionary *> *)getAllLocalAuthenticatorCredentials
{
#if ENABLE(WEB_AUTHN)
    return [self localAuthenticatorCredentialsInAccessGroup:WebCore::LocalAuthenticatorAccessGroup relyingPartyID:nil credentialID:nil];
#else
    return nullptr;
#endif
}

+ (NSArray<NSDictionary *> *)getAllLocalAuthenticatorCredentialsWithAccessGroup:(NSString *)accessGroup
{
#if ENABLE(WEB_AUTHN)
    return [self localAuthenticatorCredentialsInAccessGroup:accessGroup relyingPartyID:nil credentialID:nil];
#else
    return nullptr;
#endif
}

+ (NSArray<NSDictionary *> *)getAllLocalAuthenticatorCredentialsWithRPID:(NSString *)rpID
{
#if ENABLE(WEB_AUTHN)
    return [self localAuthenticatorCredentialsInAccessGroup:WebCore::LocalAuthenticatorAccessGroup relyingPartyID:rpID credentialID:nil];
#else
    return nullptr;
#endif
}

+ (NSArray<NSDictionary *> *)getAllLocalAuthenticatorCredentialsWithCredentialID:(NSData *)credentialID
{
#if ENABLE(WEB_AUTHN)
    return [self localAuthenticatorCredentialsInAccessGroup:WebCore::LocalAuthenticatorAccessGroup relyingPartyID:nil credentialID:credentialID];
#else
    return nullptr;
#endif
}

+ (NSArray<NSDictionary *> *)getAllLocalAuthenticatorCredentialsWithRPIDAndAccessGroup:(NSString *)accessGroup rpID:(NSString *)rpID
{
#if ENABLE(WEB_AUTHN)
    return [self localAuthenticatorCredentialsInAccessGroup:accessGroup relyingPartyID:rpID credentialID:nil];
#else
    return nullptr;
#endif
}

+ (NSArray<NSDictionary *> *)getAllLocalAuthenticatorCredentialsWithCredentialIDAndAccessGroup:(NSString *)accessGroup credentialID:(NSData *)credentialID
{
#if ENABLE(WEB_AUTHN)
    return [self localAuthenticatorCredentialsInAccessGroup:accessGroup relyingPartyID:nil credentialID:credentialID];
#else
    return nullptr;
#endif
}


+ (void)deleteLocalAuthenticatorCredentialWithID:(NSData *)credentialID
{
    [self deleteLocalAuthenticatorCredentialWithGroupAndID:nil credential:credentialID];
}

+ (void)deleteLocalAuthenticatorCredentialWithGroupAndID:(NSString *)group credential:(NSData *)credentialID
{
#if ENABLE(WEB_AUTHN)
    [self performDeleteLocalAuthenticatorCredentialWithGroupAndID:group credential:credentialID];
#endif
}

+ (void)clearAllLocalAuthenticatorCredentials
{
#if ENABLE(WEB_AUTHN)
    WebKit::LocalAuthenticator::clearAllCredentials();
#endif
}

+ (void)setDisplayNameForLocalCredentialWithGroupAndID:(NSString *)group credential:(NSData *)credentialID displayName: (NSString *)displayName
{
#if ENABLE(WEB_AUTHN)
    [self setLocalAuthenticatorCredentialDisplayName:displayName group:group credentialID:credentialID];
#endif
}

+ (void)setNameForLocalCredentialWithGroupAndID:(NSString *)group credential:(NSData *)credentialID name:(NSString *)name
{
#if ENABLE(WEB_AUTHN)
    [self setLocalAuthenticatorCredentialName:name group:group credentialID:credentialID];
#endif
}

+ (NSData *)importLocalAuthenticatorCredential:(NSData *)credentialBlob error:(NSError **)error
{
    return [self importLocalAuthenticatorWithAccessGroup:WebCore::LocalAuthenticatorAccessGroup credential:credentialBlob error:error];
}

+ (NSData *)importLocalAuthenticatorWithAccessGroup:(NSString *)accessGroup credential:(NSData *)credentialBlob error:(NSError **)error
{
#if ENABLE(WEB_AUTHN)
    return [self importLocalAuthenticatorCredential:credentialBlob accessGroup:accessGroup error:error];
#else
    return nullptr;
#endif // ENABLE(WEB_AUTHN)
}

+ (NSData *)exportLocalAuthenticatorCredentialWithID:(NSData *)credentialID error:(NSError **)error
{
    return [self exportLocalAuthenticatorCredentialWithGroupAndID:nil credential:credentialID error:error];
}

+ (NSData *)exportLocalAuthenticatorCredentialWithGroupAndID:(NSString *)group credential:(NSData *)credentialID error:(NSError **)error
{
#if ENABLE(WEB_AUTHN)
    return [self exportLocalAuthenticatorCredential:credentialID group:group error:error];
#else
    return nullptr;
#endif // ENABLE(WEB_AUTHN)
}

- (void)cancel
{
#if ENABLE(WEB_AUTHN)
    protect(*_panel)->cancel();
#endif
}

#if ENABLE(WEB_AUTHN)

static WebCore::PublicKeyCredentialRpEntity publicKeyCredentialRpEntity(_WKPublicKeyCredentialRelyingPartyEntity *rpEntity)
{
    WebCore::PublicKeyCredentialRpEntity result;
    result.name = rpEntity.name;
    result.icon = rpEntity.icon;
    result.id = rpEntity.identifier;

    return result;
}

static WebCore::PublicKeyCredentialUserEntity publicKeyCredentialUserEntity(_WKPublicKeyCredentialUserEntity *userEntity)
{
    return WebCore::PublicKeyCredentialUserEntity {
        WebCore::PublicKeyCredentialEntity { userEntity.name, userEntity.icon },
        WebCore::toBufferSource(retainPtr(userEntity.identifier).get()),
        userEntity.displayName
    };
}

static Vector<WebCore::PublicKeyCredentialParameters> publicKeyCredentialParameters(NSArray<_WKPublicKeyCredentialParameters *> *publicKeyCredentialParamaters)
{
    return Vector<WebCore::PublicKeyCredentialParameters>(publicKeyCredentialParamaters.count, [publicKeyCredentialParamaters](size_t i) {
        _WKPublicKeyCredentialParameters *param = publicKeyCredentialParamaters[i];
        return WebCore::PublicKeyCredentialParameters { WebCore::PublicKeyCredentialType::PublicKey, param.algorithm.longLongValue };
    });
}

NODELETE static WebCore::AuthenticatorTransport authenticatorTransport(_WKWebAuthenticationTransport transport)
{
    switch (transport) {
    case _WKWebAuthenticationTransportUSB:
        return WebCore::AuthenticatorTransport::Usb;
    case _WKWebAuthenticationTransportNFC:
        return WebCore::AuthenticatorTransport::Nfc;
    case _WKWebAuthenticationTransportBLE:
        return WebCore::AuthenticatorTransport::Ble;
    case _WKWebAuthenticationTransportInternal:
        return WebCore::AuthenticatorTransport::Internal;
    case _WKWebAuthenticationTransportCaBLE:
        return WebCore::AuthenticatorTransport::Cable;
    case _WKWebAuthenticationTransportHybrid:
        return WebCore::AuthenticatorTransport::Hybrid;
    case _WKWebAuthenticationTransportSmartCard:
        return WebCore::AuthenticatorTransport::SmartCard;
    }
}

static Vector<WebCore::AuthenticatorTransport> authenticatorTransports(NSArray<NSNumber *> *transports)
{
    return Vector<WebCore::AuthenticatorTransport>(transports.count, [transports](size_t i) {
        NSNumber *transport = transports[i];
        return authenticatorTransport((_WKWebAuthenticationTransport)transport.intValue);
    });
}

static Vector<WebCore::PublicKeyCredentialDescriptor> publicKeyCredentialDescriptors(NSArray<_WKPublicKeyCredentialDescriptor *> *credentials)
{
    return Vector<WebCore::PublicKeyCredentialDescriptor>(credentials.count, [credentials](size_t i) {
        RetainPtr<_WKPublicKeyCredentialDescriptor> credential = credentials[i];
        return WebCore::PublicKeyCredentialDescriptor {
            WebCore::PublicKeyCredentialType::PublicKey,
            WebCore::toBufferSource(retainPtr(credential.get().identifier).get()),
            authenticatorTransports(retainPtr(credential.get().transports).get()) };
    });
}

NODELETE static std::optional<WebCore::AuthenticatorAttachment> authenticatorAttachment(_WKAuthenticatorAttachment attachment)
{
    switch (attachment) {
    case _WKAuthenticatorAttachmentAll:
        return std::nullopt;
    case _WKAuthenticatorAttachmentPlatform:
        return WebCore::AuthenticatorAttachment::Platform;
    case _WKAuthenticatorAttachmentCrossPlatform:
        return WebCore::AuthenticatorAttachment::CrossPlatform;
    default:
        ASSERT_NOT_REACHED();
        return std::nullopt;
    }
}

NODELETE static WebCore::UserVerificationRequirement userVerification(_WKUserVerificationRequirement uv)
{
    switch (uv) {
    case _WKUserVerificationRequirementRequired:
        return WebCore::UserVerificationRequirement::Required;
    case _WKUserVerificationRequirementPreferred:
        return WebCore::UserVerificationRequirement::Preferred;
    case _WKUserVerificationRequirementDiscouraged:
        return WebCore::UserVerificationRequirement::Discouraged;
    default:
        ASSERT_NOT_REACHED();
        return WebCore::UserVerificationRequirement::Preferred;
    }
}

NODELETE static std::optional<WebCore::ResidentKeyRequirement> toWebCore(_WKResidentKeyRequirement uv)
{
    switch (uv) {
    case _WKResidentKeyRequirementNotPresent:
        return std::nullopt;
    case _WKResidentKeyRequirementRequired:
        return WebCore::ResidentKeyRequirement::Required;
    case _WKResidentKeyRequirementPreferred:
        return WebCore::ResidentKeyRequirement::Preferred;
    case _WKResidentKeyRequirementDiscouraged:
        return WebCore::ResidentKeyRequirement::Discouraged;
    default:
        ASSERT_NOT_REACHED();
        return WebCore::ResidentKeyRequirement::Preferred;
    }
}

static WebCore::AuthenticatorSelectionCriteria authenticatorSelectionCriteria(_WKAuthenticatorSelectionCriteria *authenticatorSelection)
{
    WebCore::AuthenticatorSelectionCriteria result;
    result.authenticatorAttachment = authenticatorAttachment(authenticatorSelection.authenticatorAttachment);
    result.residentKey = toWebCore(authenticatorSelection.residentKey);
    result.requireResidentKey = authenticatorSelection.requireResidentKey;
    result.userVerification = userVerification(authenticatorSelection.userVerification);

    return result;
}

NODELETE static WebCore::AttestationConveyancePreference attestationConveyancePreference(_WKAttestationConveyancePreference attestation)
{
    switch (attestation) {
    case _WKAttestationConveyancePreferenceNone:
        return WebCore::AttestationConveyancePreference::None;
    case _WKAttestationConveyancePreferenceIndirect:
        return WebCore::AttestationConveyancePreference::Indirect;
    case _WKAttestationConveyancePreferenceDirect:
        return WebCore::AttestationConveyancePreference::Direct;
    case _WKAttestationConveyancePreferenceEnterprise:
        return WebCore::AttestationConveyancePreference::Enterprise;
    default:
        ASSERT_NOT_REACHED();
        return WebCore::AttestationConveyancePreference::None;
    }
}

static WebCore::AuthenticationExtensionsClientInputs authenticationExtensionsClientInputs(_WKAuthenticationExtensionsClientInputs *extensions)
{
    WebCore::AuthenticationExtensionsClientInputs result;
    result.appid = extensions.appid;

    id<_WKAuthenticationPRFInputValuesStaging> evalValue = [extensions respondsToSelector:@selector(eval)] ? extensions.eval : nil;
    NSDictionary<NSData *, id<_WKAuthenticationPRFInputValuesStaging>> *evalByCredentialValue = [extensions respondsToSelector:@selector(evalByCredential)] ? extensions.evalByCredential : nil;

    if (extensions.prf || evalValue || evalByCredentialValue) {
        WebCore::AuthenticationExtensionsClientInputs::PRFInputs prfInputs;
        if (evalValue) {
            RetainPtr<_WKAuthenticationPRFInputValues> eval = (_WKAuthenticationPRFInputValues *)evalValue;
            prfInputs.eval = WebCore::AuthenticationExtensionsClientInputs::PRFValues {
                WebCore::toBufferSource(eval.get().prfSalt1),
                eval.get().prfSalt2 ? std::optional { WebCore::toBufferSource(eval.get().prfSalt2) } : std::nullopt,
            };
        }
        if (evalByCredentialValue) {
            RetainPtr<NSDictionary<NSData *, _WKAuthenticationPRFInputValues *>> evalByCredential = (NSDictionary<NSData *, _WKAuthenticationPRFInputValues *> *)evalByCredentialValue;
            Vector<KeyValuePair<String, WebCore::AuthenticationExtensionsClientInputs::PRFValues>> evalByCredentialVector;
            for (NSData *credentialId in evalByCredential.get()) {
                _WKAuthenticationPRFInputValues *prfInputValues = evalByCredential.get()[credentialId];
                evalByCredentialVector.append({
                    base64URLEncodeToString(span(credentialId)),
                    WebCore::AuthenticationExtensionsClientInputs::PRFValues {
                        WebCore::toBufferSource(prfInputValues.prfSalt1),
                        prfInputValues.prfSalt2 ? std::optional { WebCore::toBufferSource(prfInputValues.prfSalt2) } : std::nullopt,
                    }
                });
            }
            prfInputs.evalByCredential = WTF::move(evalByCredentialVector);
        }
        result.prf = WTF::move(prfInputs);
    }

    if (extensions.largeBlob) {
        _WKAuthenticationExtensionsLargeBlobInputs *largeBlob = (_WKAuthenticationExtensionsLargeBlobInputs *)extensions.largeBlob;
        WebCore::AuthenticationExtensionsClientInputs::LargeBlobInputs largeBlobInputs;

        if (largeBlob.support)
            largeBlobInputs.support = String(largeBlob.support);

        if (largeBlob.read)
            largeBlobInputs.read = largeBlob.read;

        if (largeBlob.write)
            largeBlobInputs.write = WebCore::toBufferSource(largeBlob.write);

        result.largeBlob = WTF::move(largeBlobInputs);
    }

    return result;
}
#endif

+ (WebCore::PublicKeyCredentialCreationOptions)convertToCoreCreationOptionsWithOptions:(_WKPublicKeyCredentialCreationOptions *)options
{
#if ENABLE(WEB_AUTHN)
    return WebCore::PublicKeyCredentialCreationOptions {
        .rp = publicKeyCredentialRpEntity(retainPtr(options.relyingParty).get()),
        .user = publicKeyCredentialUserEntity(retainPtr(options.user).get()),
        .challenge = JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1),
        .pubKeyCredParams = publicKeyCredentialParameters(retainPtr(options.publicKeyCredentialParamaters).get()),
        .timeout = options.timeout ? std::optional { options.timeout.unsignedIntValue } : std::nullopt,
        .excludeCredentials = options.excludeCredentials ? publicKeyCredentialDescriptors(retainPtr(options.excludeCredentials).get()) : Vector<WebCore::PublicKeyCredentialDescriptor> { },
        .authenticatorSelection = options.authenticatorSelection ? std::optional { authenticatorSelectionCriteria(retainPtr(options.authenticatorSelection).get()) } : std::nullopt,
        .attestation = attestationConveyancePreference(options.attestation),
        .extensions = (options.extensionsCBOR && options.extensionsCBOR.length > 0) ? WebCore::AuthenticationExtensionsClientInputs::fromCBOR(span(options.extensionsCBOR)) : authenticationExtensionsClientInputs(retainPtr(options.extensions).get()),
    };
#else
    return WebCore::PublicKeyCredentialCreationOptions { };
#endif
}

- (void)makeCredentialWithChallenge:(NSData *)challenge origin:(NSString *)origin options:(_WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    [self performMakeCredentialWithChallenge:challenge origin:origin options:options completionHandler:handler];
#endif
}

- (void)makeCredentialWithMediationRequirement:(_WKWebAuthenticationMediationRequirement)mediation clientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    [self performMakeCredentialWithMediationRequirement:mediation clientDataHash:clientDataHash options:options completionHandler:handler];
#endif
}

- (void)makeCredentialWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse *, NSError *))handler
{
    [self makeCredentialWithMediationRequirement:_WKWebAuthenticationMediationRequirementOptional clientDataHash:clientDataHash options:options completionHandler:handler];
}

+ (WebCore::PublicKeyCredentialRequestOptions)convertToCoreRequestOptionsWithOptions:(_WKPublicKeyCredentialRequestOptions *)options
{
#if ENABLE(WEB_AUTHN)
    return WebCore::PublicKeyCredentialRequestOptions {
        .challenge = JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1),
        .timeout = options.timeout ? std::optional { options.timeout.unsignedIntValue } : std::nullopt,
        .rpId = options.relyingPartyIdentifier ? String { options.relyingPartyIdentifier } : String { },
        .allowCredentials = options.allowCredentials ? publicKeyCredentialDescriptors(retainPtr(options.allowCredentials).get()) : Vector<WebCore::PublicKeyCredentialDescriptor> { },
        .userVerification = userVerification(options.userVerification),
        .extensions = (options.extensionsCBOR && options.extensionsCBOR.length > 0) ? WebCore::AuthenticationExtensionsClientInputs::fromCBOR(span(options.extensionsCBOR)) : authenticationExtensionsClientInputs(retainPtr(options.extensions).get()),
        .authenticatorAttachment = authenticatorAttachment(options.authenticatorAttachment),
    };
#else
    return WebCore::PublicKeyCredentialRequestOptions { };
#endif
}

- (void)getAssertionWithChallenge:(NSData *)challenge origin:(NSString *)origin options:(_WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    [self performGetAssertionWithChallenge:challenge origin:origin options:options completionHandler:handler];
#endif
}

- (void)getAssertionWithMediationRequirement:(_WKWebAuthenticationMediationRequirement)mediation clientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    [self performGetAssertionWithMediationRequirement:mediation clientDataHash:clientDataHash options:options completionHandler:handler];
#endif
}

- (void)getAssertionWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse *, NSError *))handler
{
    [self getAssertionWithMediationRequirement:_WKWebAuthenticationMediationRequirementOptional clientDataHash:clientDataHash options:options completionHandler:handler];
}

+ (BOOL)isUserVerifyingPlatformAuthenticatorAvailable
{
#if ENABLE(WEB_AUTHN)
    return WebKit::LocalService::isAvailable();
#else
    return NO;
#endif
}

+ (NSData *)getClientDataJSONForAuthenticationType:(_WKWebAuthenticationType)type challenge:(NSData *)challenge origin:(NSString *)origin
{
#if ENABLE(WEB_AUTHN)
    return [self performGetClientDataJSONWithTopOrigin:type challenge:challenge origin:origin topOrigin:nil crossOrigin:NO];
#else
    return nil;
#endif
}

+ (NSData *)getClientDataJSONWithTopOrigin:(_WKWebAuthenticationType)type challenge:(NSData *)challenge origin:(NSString *)origin topOrigin:(NSString *)topOrigin crossOrigin:(BOOL)crossOrigin
{
#if ENABLE(WEB_AUTHN)
    return [self performGetClientDataJSONWithTopOrigin:type challenge:challenge origin:origin topOrigin:topOrigin crossOrigin:crossOrigin];
#else
    return nil;
#endif
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeMakeCredentialCommandWithClientDataJSON:clientDataJSON options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
#if ENABLE(WEB_AUTHN)
    return [self performEncodeMakeCredentialCommandWithClientDataJSON:clientDataJSON options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:authenticatorSupportedExtensions];
#else
    return nil;
#endif
}

+ (NSData *)encodeGetAssertionCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeGetAssertionCommandWithClientDataJSON:clientDataJSON options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeGetAssertionCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
#if ENABLE(WEB_AUTHN)
    return [self performEncodeGetAssertionCommandWithClientDataJSON:clientDataJSON options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:authenticatorSupportedExtensions];
#else
    return nil;
#endif
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeMakeCredentialCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
#if ENABLE(WEB_AUTHN)
    return [self performEncodeMakeCredentialCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:authenticatorSupportedExtensions];
#else
    return nil;
#endif
}

+ (NSData *) encodeMakeCredentialCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedCredentialParameters:(NSArray<_WKPublicKeyCredentialParameters *> *)credentialParameters
{
#if ENABLE(WEB_AUTHN)
    return [self performEncodeMakeCredentialCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability credentialParameters:credentialParameters];
#else
    return nil;
#endif
}


+ (NSData *)encodeGetAssertionCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeGetAssertionCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeGetAssertionCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
#if ENABLE(WEB_AUTHN)
    return [self performEncodeGetAssertionCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:authenticatorSupportedExtensions];
#else
    return nil;
#endif
}

- (void)setMockConfiguration:(NSDictionary *)configuration
{
#if ENABLE(WEB_AUTHN)
    WebCore::MockWebAuthenticationConfiguration::LocalConfiguration localConfiguration;
    localConfiguration.userVerification = WebCore::MockWebAuthenticationConfiguration::UserVerification::Yes;
    if (configuration[@"privateKeyBase64"])
        localConfiguration.privateKeyBase64 = dynamic_objc_cast<NSString>(configuration[@"privateKeyBase64"]);

    WebCore::MockWebAuthenticationConfiguration mockConfiguration;
    mockConfiguration.local = WTF::move(localConfiguration);

    protect(*_panel)->setMockConfiguration(WTF::move(mockConfiguration));
#endif
}

#if ENABLE(WEB_AUTHN)
#pragma mark WKObject protocol implementation

- (API::Object&)_apiObject
{
    return *_panel;
}
#endif

@end

#if ENABLE(WEB_AUTHN)

namespace WebKit {

Vector<WebCore::PublicKeyCredentialParameters> webAuthenticationPanelCredentialParameters(NSArray<_WKPublicKeyCredentialParameters *> *parameters)
{
    return publicKeyCredentialParameters(parameters);
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
