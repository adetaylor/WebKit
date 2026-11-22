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
#import "WKError.h"
#import "WebAuthenticationPanelClient.h"
#import "WebAuthenticationPanelCredentials.h"
#import "_WKAuthenticationExtensionsClientInputs.h"
#import "_WKAuthenticationExtensionsClientOutputsInternal.h"
#import "_WKAuthenticatorAssertionResponseInternal.h"
#import "_WKAuthenticatorAttestationResponseInternal.h"
#import "_WKAuthenticatorSelectionCriteria.h"
#import "_WKPublicKeyCredentialCreationOptions.h"
#import "_WKPublicKeyCredentialDescriptor.h"
#import "_WKPublicKeyCredentialParameters.h"
#import "_WKPublicKeyCredentialRequestOptions.h"
#import "_WKPublicKeyCredentialRelyingPartyEntity.h"
#import "_WKPublicKeyCredentialUserEntity.h"
#import <WebCore/AuthenticationExtensionsClientInputs.h>
#import <WebCore/AuthenticatorAttachment.h>
#import <WebCore/AuthenticatorResponse.h>
#import <WebCore/AuthenticatorResponseData.h>
#import <WebCore/AuthenticatorSelectionCriteria.h>
#import <WebCore/BufferSource.h>
#import <WebCore/CredentialRequestOptions.h>
#import <WebCore/DeviceRequestConverter.h>
#import <WebCore/FidoConstants.h>
#import <WebCore/MediationRequirement.h>
#import <WebCore/MockWebAuthenticationConfiguration.h>
#import <WebCore/PublicKeyCredentialCreationOptions.h>
#import <WebCore/PublicKeyCredentialRequestOptions.h>
#import <WebCore/WebAuthenticationConstants.h>
#import <WebCore/WebAuthenticationUtils.h>
#import <WebCore/WebCoreObjCExtras.h>
#import <objc/runtime.h>
#import <pal/crypto/CryptoDigest.h>
#import <wtf/BlockPtr.h>
#import <wtf/Borrow.h>
#import <wtf/RetainPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/text/Base64.h>

#import "AuthenticationServicesCoreSoftLink.h"

#if ENABLE(WEB_AUTHN)

#define kSecAttrSharingGroup @"ggrp"

static inline void updateQueryForGroupIfNecessary(NSMutableDictionary *dictionary, NSString *group)
{
#if ENABLE(ONGOING_CREDENTIAL_SHARING_WEBKIT_SPI)
    if (group != nil)
        [dictionary setObject:group forKey:kSecAttrSharingGroup];
#endif // ENABLE(ONGOING_CREDENTIAL_SHARING_WEBKIT_SPI)
}

static RetainPtr<NSData> produceClientDataJson(_WKWebAuthenticationType type, NSData *challenge, NSString *origin, NSString *topOrigin = nil, WebAuthn::Scope scope = WebAuthn::Scope::SameOrigin)
{
    WebCore::ClientDataType clientDataType;
    switch (type) {
    case _WKWebAuthenticationTypeCreate:
        clientDataType = WebCore::ClientDataType::Create;
        break;
    case _WKWebAuthenticationTypeGet:
        clientDataType = WebCore::ClientDataType::Get;
        break;
    }
    auto challengeBuffer = ArrayBuffer::tryCreate(span(challenge));
    auto securityOrigin = WebCore::SecurityOrigin::createFromString(origin);

    auto clientDataJson = buildClientDataJson(clientDataType, WebCore::BufferSource(challengeBuffer ? challengeBuffer.releaseNonNull() : JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1)), securityOrigin, scope, topOrigin);
    return toNSData(clientDataJson->span());
}

static Vector<uint8_t> produceClientDataJsonHash(NSData *clientDataJson)
{
    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(span(clientDataJson));
    return crypto->computeHash();
}
#endif

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

NODELETE static _WKWebAuthenticationTransport wkWebAuthenticationTransport(WebCore::AuthenticatorTransport transport)
{
    switch (transport) {
    case WebCore::AuthenticatorTransport::Usb:
        return _WKWebAuthenticationTransportUSB;
    case WebCore::AuthenticatorTransport::Nfc:
        return _WKWebAuthenticationTransportNFC;
    case WebCore::AuthenticatorTransport::Ble:
        return _WKWebAuthenticationTransportBLE;
    case WebCore::AuthenticatorTransport::Internal:
        return _WKWebAuthenticationTransportInternal;
    case WebCore::AuthenticatorTransport::Cable:
        return _WKWebAuthenticationTransportCaBLE;
    case WebCore::AuthenticatorTransport::Hybrid:
        return _WKWebAuthenticationTransportHybrid;
    case WebCore::AuthenticatorTransport::SmartCard:
        return _WKWebAuthenticationTransportSmartCard;
    }
}

- (NSSet *)transports
{
    if (_transports)
        return _transports.get();

    auto& transports = _panel->transports();
    _transports = adoptNS([[NSMutableSet alloc] initWithCapacity:transports.size()]);
    for (auto& transport : borrow(transports))
        [_transports addObject:adoptNS([[NSNumber alloc] initWithInt:wkWebAuthenticationTransport(transport)]).get()];
    return _transports.get();
}

NODELETE static _WKWebAuthenticationType wkWebAuthenticationType(WebCore::ClientDataType type)
{
    switch (type) {
    case WebCore::ClientDataType::Create:
        return _WKWebAuthenticationTypeCreate;
    case WebCore::ClientDataType::Get:
        return _WKWebAuthenticationTypeGet;
    default:
        ASSERT_NOT_REACHED();
        return _WKWebAuthenticationTypeCreate;
    }
}

NODELETE static fido::AuthenticatorSupportedOptions::UserVerificationAvailability coreUserVerificationAvailability(_WKWebAuthenticationUserVerificationAvailability wkAvailability)
{
    switch (wkAvailability) {
    case _WKWebAuthenticationUserVerificationAvailabilitySupportedAndConfigured:
        return fido::AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured;
    case _WKWebAuthenticationUserVerificationAvailabilitySupportedButNotConfigured:
        return fido::AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedButNotConfigured;
    case _WKWebAuthenticationUserVerificationAvailabilityNotSupported:
        return fido::AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported;
    }

    ASSERT_NOT_REACHED();
    return fido::AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported;
}

- (_WKWebAuthenticationType)type
{
    return wkWebAuthenticationType(_panel->clientDataType());
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
    BOOL useAlternateKeychainAttribute = WebKit::shouldUseAlternateKeychainAttribute();
    auto deleteQuery = adoptNS([[NSMutableDictionary alloc] init]);
    [deleteQuery setDictionary:@{
        (__bridge id)kSecClass: bridge_id_cast(kSecClassKey),
        (__bridge id)kSecUseDataProtectionKeychain: @YES,
        (__bridge id)kSecAttrSynchronizable: (id)kSecAttrSynchronizableAny
    }];
    updateQueryForGroupIfNecessary(deleteQuery.get(), group);

    CFStringRef credentialIdKey = useAlternateKeychainAttribute ? kSecAttrAlias : kSecAttrApplicationLabel;
    [deleteQuery setObject:credentialID forKey:(__bridge id)credentialIdKey];

    SecItemDelete((__bridge CFDictionaryRef)deleteQuery.get());

    if (useAlternateKeychainAttribute) {
        [deleteQuery removeObjectForKey:bridge_cast(kSecAttrAlias)];
        [deleteQuery setObject:credentialID forKey:bridge_cast(kSecAttrApplicationLabel)];
        SecItemDelete((__bridge CFDictionaryRef)deleteQuery.get());
    }
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

NODELETE static WebCore::MediationRequirement toWebCore(_WKWebAuthenticationMediationRequirement mediation)
{
    switch (mediation) {
    case _WKWebAuthenticationMediationRequirementSilent:
        return WebCore::MediationRequirement::Silent;
    case _WKWebAuthenticationMediationRequirementOptional:
        return WebCore::MediationRequirement::Optional;
    case _WKWebAuthenticationMediationRequirementRequired:
        return WebCore::MediationRequirement::Required;
    case _WKWebAuthenticationMediationRequirementConditional:
        return WebCore::MediationRequirement::Conditional;
    default:
        ASSERT_NOT_REACHED();
        return WebCore::MediationRequirement::Optional;
    }
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

#if ENABLE(WEB_AUTHN)
NODELETE static _WKAuthenticatorAttachment authenticatorAttachmentToWKAuthenticatorAttachment(WebCore::AuthenticatorAttachment attachment)
{
    switch (attachment) {
    case WebCore::AuthenticatorAttachment::Platform:
        return _WKAuthenticatorAttachmentPlatform;
    case WebCore::AuthenticatorAttachment::CrossPlatform:
        return _WKAuthenticatorAttachmentCrossPlatform;
    }
}

static RetainPtr<NSArray<NSNumber *>> wkTransports(const Vector<WebCore::AuthenticatorTransport>& transports)
{
    auto wkTransports = adoptNS([NSMutableArray<NSNumber *> new]);
    for (auto transport : transports)
        [wkTransports addObject:[NSNumber numberWithInt:(int)transport]];
    return wkTransports;
}

static RetainPtr<_WKAuthenticationExtensionsClientOutputs> wkAuthenticationExtensionsClientOutputs(const WebCore::AuthenticationExtensionsClientOutputs& outputs)
{
    RetainPtr<NSData> first;
    RetainPtr<NSData> second;
    if (outputs.prf && outputs.prf->results) {
        Ref firstBuffer = outputs.prf->results->first;
        RefPtr secondBuffer = outputs.prf->results->second;

        first = WTF::toNSData(firstBuffer->span());
        if (secondBuffer)
            second = WTF::toNSData(secondBuffer->span());
    }
    RetainPtr<_WKAuthenticationExtensionsLargeBlobOutputs> largeBlob;
    if (outputs.largeBlob) {
        RetainPtr<NSData> blob;
        if (RefPtr blobBuffer = outputs.largeBlob->blob)
            blob = WTF::toNSData(blobBuffer->span());
        largeBlob = adoptNS([[_WKAuthenticationExtensionsLargeBlobOutputs alloc] initWithSupported:outputs.largeBlob->supported.value_or(false) blob:blob.get() written:outputs.largeBlob->written.value_or(false)]);
    }
    return adoptNS([[_WKAuthenticationExtensionsClientOutputs alloc] initWithAppid:(outputs.appid && *outputs.appid) prfEnabled:(outputs.prf && outputs.prf->enabled && *outputs.prf->enabled) prfFirst:first.get() prfSecond:second.get() largeBlob:largeBlob.get()]);
}

static RetainPtr<_WKAuthenticatorAttestationResponse> wkAuthenticatorAttestationResponse(const WebCore::AuthenticatorResponseData& data, NSData *clientDataJSON, WebCore::AuthenticatorAttachment attachment)
{
    RetainPtr<_WKAuthenticationExtensionsClientOutputs> extensions;
    if (data.extensionOutputs)
        extensions = wkAuthenticationExtensionsClientOutputs(*data.extensionOutputs);
    auto value = adoptNS([[_WKAuthenticatorAttestationResponse alloc] initWithClientDataJSON:clientDataJSON rawId:toNSData(WebCore::BufferSource { Ref { *data.rawId } }).get() extensions:WTF::move(extensions) attestationObject:toNSData(WebCore::BufferSource { Ref { *data.attestationObject } }).get() attachment:authenticatorAttachmentToWKAuthenticatorAttachment(attachment) transports:wkTransports(data.transports).get()]);

    return value;
}
#endif

- (void)makeCredentialWithChallenge:(NSData *)challenge origin:(NSString *)origin options:(_WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    auto clientDataJSON = produceClientDataJson(_WKWebAuthenticationTypeCreate, challenge, origin);
    auto hash = produceClientDataJsonHash(clientDataJSON.get());
    auto callback = [handler = makeBlockPtr(handler), clientDataJSON = WTF::move(clientDataJSON)] (Variant<Ref<WebCore::AuthenticatorResponse>, WebCore::ExceptionData>&& result) mutable {
        WTF::switchOn(result, [&](const Ref<WebCore::AuthenticatorResponse>& response) {
            handler(wkAuthenticatorAttestationResponse(response->data(), clientDataJSON.get(), response->attachment()).get(), nil);
        }, [&](const WebCore::ExceptionData& exception) {
            handler(nil, adoptNS([[NSError alloc] initWithDomain:WKErrorDomain code:static_cast<NSInteger>(exception.code) userInfo:@{ NSLocalizedDescriptionKey: exception.message.createNSString().get() }]).get());
        });
    };
    protect(*_panel)->handleRequest({ WTF::move(hash), [_WKWebAuthenticationPanel convertToCoreCreationOptionsWithOptions:options], nullptr, WebKit::WebAuthenticationPanelResult::Unavailable, nullptr, std::nullopt, { }, String(), nullptr, std::nullopt, std::nullopt }, WTF::move(callback));
#endif
}

- (void)makeCredentialWithMediationRequirement:(_WKWebAuthenticationMediationRequirement)mediation clientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    auto callback = [handler = makeBlockPtr(handler)] (Variant<Ref<WebCore::AuthenticatorResponse>, WebCore::ExceptionData>&& result) mutable {
        WTF::switchOn(result, [&](const Ref<WebCore::AuthenticatorResponse>& response) {
            handler(wkAuthenticatorAttestationResponse(response->data(), nullptr, response->attachment()).get(), nil);
        }, [&](const WebCore::ExceptionData& exception) {
            handler(nil, adoptNS([[NSError alloc] initWithDomain:WKErrorDomain code:static_cast<NSInteger>(exception.code) userInfo:@{ NSLocalizedDescriptionKey: exception.message.createNSString().get() }]).get());
        });
    };
    protect(*_panel)->handleRequest({ makeVector(clientDataHash), [_WKWebAuthenticationPanel convertToCoreCreationOptionsWithOptions:options], nullptr, WebKit::WebAuthenticationPanelResult::Unavailable, nullptr, std::nullopt, { }, String(), nullptr, toWebCore(mediation), std::nullopt }, WTF::move(callback));
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

#if ENABLE(WEB_AUTHN)
static RetainPtr<_WKAuthenticatorAssertionResponse> wkAuthenticatorAssertionResponse(const WebCore::AuthenticatorResponseData& data, NSData *clientDataJSON, WebCore::AuthenticatorAttachment attachment)
{
    RetainPtr<NSData> userHandle;
    if (RefPtr userHandleArray = data.userHandle)
        userHandle = toNSData(userHandleArray->span());
    RetainPtr<_WKAuthenticationExtensionsClientOutputs> extensions;
    if (data.extensionOutputs)
        extensions = wkAuthenticationExtensionsClientOutputs(*data.extensionOutputs);

    return adoptNS([[_WKAuthenticatorAssertionResponse alloc] initWithClientDataJSON:clientDataJSON rawId:toNSData(Ref { *data.rawId }->span()).get() extensions:WTF::move(extensions) authenticatorData:toNSData(Ref { *data.authenticatorData }->span()).get() signature:toNSData(Ref { *data.signature }->span()).get() userHandle:userHandle.get() attachment:authenticatorAttachmentToWKAuthenticatorAttachment(attachment)]);
}
#endif

- (void)getAssertionWithChallenge:(NSData *)challenge origin:(NSString *)origin options:(_WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    auto clientDataJSON = produceClientDataJson(_WKWebAuthenticationTypeGet, challenge, origin);
    auto hash = produceClientDataJsonHash(clientDataJSON.get());
    auto callback = [handler = makeBlockPtr(handler), clientDataJSON = WTF::move(clientDataJSON)] (Variant<Ref<WebCore::AuthenticatorResponse>, WebCore::ExceptionData>&& result) mutable {
        WTF::switchOn(result, [&](const Ref<WebCore::AuthenticatorResponse>& response) {
            handler(wkAuthenticatorAssertionResponse(response->data(), clientDataJSON.get(), response->attachment()).get(), nil);
        }, [&](const WebCore::ExceptionData& exception) {
            handler(nil, adoptNS([[NSError alloc] initWithDomain:WKErrorDomain code:static_cast<NSInteger>(exception.code) userInfo:@{ NSLocalizedDescriptionKey: exception.message.createNSString().get() }]).get());
        });
    };
    protect(*_panel)->handleRequest({ WTF::move(hash), [_WKWebAuthenticationPanel convertToCoreRequestOptionsWithOptions:options], nullptr, WebKit::WebAuthenticationPanelResult::Unavailable, nullptr, std::nullopt, { }, String(), nullptr, std::nullopt, std::nullopt }, WTF::move(callback));
#endif
}

- (void)getAssertionWithMediationRequirement:(_WKWebAuthenticationMediationRequirement)mediation clientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse *, NSError *))handler
{
#if ENABLE(WEB_AUTHN)
    auto callback = [handler = makeBlockPtr(handler)] (Variant<Ref<WebCore::AuthenticatorResponse>, WebCore::ExceptionData>&& result) mutable {
        WTF::switchOn(result, [&](const Ref<WebCore::AuthenticatorResponse>& response) {
            handler(wkAuthenticatorAssertionResponse(response->data(), nullptr, response->attachment()).get(), nil);
        }, [&](const WebCore::ExceptionData& exception) {
            handler(nil, adoptNS([[NSError alloc] initWithDomain:WKErrorDomain code:static_cast<NSInteger>(exception.code) userInfo:@{ NSLocalizedDescriptionKey: exception.message.createNSString().get() }]).get());
        });
    };
    protect(*_panel)->handleRequest({ makeVector(clientDataHash), [_WKWebAuthenticationPanel convertToCoreRequestOptionsWithOptions:options], nullptr, WebKit::WebAuthenticationPanelResult::Unavailable, nullptr, std::nullopt, { }, String(), nullptr, toWebCore(mediation), std::nullopt }, WTF::move(callback));
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
    RetainPtr<NSData> clientDataJSON;

#if ENABLE(WEB_AUTHN)
    clientDataJSON = produceClientDataJson(type, challenge, origin);
#endif

    return clientDataJSON.autorelease();
}

+ (NSData *)getClientDataJSONWithTopOrigin:(_WKWebAuthenticationType)type challenge:(NSData *)challenge origin:(NSString *)origin topOrigin:(NSString *)topOrigin crossOrigin:(BOOL)crossOrigin
{
    RetainPtr<NSData> clientDataJSON;

#if ENABLE(WEB_AUTHN)
    clientDataJSON = produceClientDataJson(type, challenge, origin, topOrigin, crossOrigin ? WebAuthn::Scope::CrossOrigin: WebAuthn::Scope::SameOrigin);
#endif

    return clientDataJSON.autorelease();
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeMakeCredentialCommandWithClientDataJSON:clientDataJSON options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
    RetainPtr<NSData> encodedCommand;
#if ENABLE(WEB_AUTHN)
    auto hash = produceClientDataJsonHash(clientDataJSON);
    auto coreOptions = [_WKWebAuthenticationPanel convertToCoreCreationOptionsWithOptions:options];
    bool needsPRF = coreOptions.extensions && coreOptions.extensions->prf;
    bool supportsHmacSecret = authenticatorSupportedExtensions && [authenticatorSupportedExtensions containsObject:@"hmac-secret"];
    WebCore::UserVerificationRequirement effectiveUVRequirement = coreOptions.authenticatorSelection ? coreOptions.authenticatorSelection->userVerification : WebCore::UserVerificationRequirement::Preferred;
    if (needsPRF && supportsHmacSecret)
        effectiveUVRequirement = WebCore::UserVerificationRequirement::Required;
    const Vector encodedVector = fido::encodeMakeCredentialRequestAsCBOR(hash, coreOptions, coreUserVerificationAvailability(userVerificationAvailability), effectiveUVRequirement, fido::AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, makeVector<String>(authenticatorSupportedExtensions), std::nullopt);
    encodedCommand = toNSData(encodedVector);
#endif

    return encodedCommand.autorelease();
}

+ (NSData *)encodeGetAssertionCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeGetAssertionCommandWithClientDataJSON:clientDataJSON options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeGetAssertionCommandWithClientDataJSON:(NSData *)clientDataJSON options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
    RetainPtr<NSData> encodedCommand;
#if ENABLE(WEB_AUTHN)
    auto hash = produceClientDataJsonHash(clientDataJSON);
    auto coreOptions = [_WKWebAuthenticationPanel convertToCoreRequestOptionsWithOptions:options];

    bool needsPRF = coreOptions.extensions && coreOptions.extensions->prf;
    bool supportsHmacSecret = authenticatorSupportedExtensions && [authenticatorSupportedExtensions containsObject:@"hmac-secret"];
    WebCore::UserVerificationRequirement effectiveUVRequirement = (needsPRF && supportsHmacSecret)
        ? WebCore::UserVerificationRequirement::Required
        : coreOptions.userVerification;

    const Vector encodedVector = fido::encodeGetAssertionRequestAsCBOR(hash, coreOptions, coreUserVerificationAvailability(userVerificationAvailability), effectiveUVRequirement, makeVector<String>(authenticatorSupportedExtensions), std::nullopt);
    encodedCommand = toNSData(encodedVector);
#endif

    return encodedCommand.autorelease();
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeMakeCredentialCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeMakeCredentialCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
    RetainPtr<NSData> encodedCommand;
#if ENABLE(WEB_AUTHN)
    auto coreOptions = [_WKWebAuthenticationPanel convertToCoreCreationOptionsWithOptions:options];
    auto effectiveUV = coreOptions.authenticatorSelection ? coreOptions.authenticatorSelection->userVerification : WebCore::UserVerificationRequirement::Discouraged;
    const Vector encodedVector = fido::encodeMakeCredentialRequestAsCBOR(makeVector(clientDataHash), coreOptions, coreUserVerificationAvailability(userVerificationAvailability), effectiveUV, fido::AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, makeVector<String>(authenticatorSupportedExtensions), std::nullopt);
    encodedCommand = toNSData(encodedVector);
#endif

    return encodedCommand.autorelease();
}

+ (NSData *) encodeMakeCredentialCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedCredentialParameters:(NSArray<_WKPublicKeyCredentialParameters *> *)credentialParameters
{
    RetainPtr<NSData> encodedCommand;

#if ENABLE(WEB_AUTHN)
    auto coreOptions = [_WKWebAuthenticationPanel convertToCoreCreationOptionsWithOptions:options];
    auto effectiveUV = coreOptions.authenticatorSelection ? coreOptions.authenticatorSelection->userVerification : WebCore::UserVerificationRequirement::Discouraged;
    const Vector encodedVector = fido::encodeMakeCredentialRequestAsCBOR(makeVector(clientDataHash), coreOptions, coreUserVerificationAvailability(userVerificationAvailability), effectiveUV, fido::AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, { }, std::nullopt, publicKeyCredentialParameters(credentialParameters));
    encodedCommand = toNSData(encodedVector);
#endif

    return encodedCommand.autorelease();
}


+ (NSData *)encodeGetAssertionCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability
{
    return [self encodeGetAssertionCommandWithClientDataHash:clientDataHash options:options userVerificationAvailability:userVerificationAvailability authenticatorSupportedExtensions:nil];
}

+ (NSData *)encodeGetAssertionCommandWithClientDataHash:(NSData *)clientDataHash options:(_WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(NSArray<NSString *> *)authenticatorSupportedExtensions
{
    RetainPtr<NSData> encodedCommand;
#if ENABLE(WEB_AUTHN)
    auto coreOptions = [_WKWebAuthenticationPanel convertToCoreRequestOptionsWithOptions:options];

    // Calculate effective UV requirement (PRF forces UV to Required)
    bool needsPRF = coreOptions.extensions && coreOptions.extensions->prf;
    bool supportsHmacSecret = authenticatorSupportedExtensions && [authenticatorSupportedExtensions containsObject:@"hmac-secret"];
    WebCore::UserVerificationRequirement effectiveUVRequirement = (needsPRF && supportsHmacSecret)
        ? WebCore::UserVerificationRequirement::Required
        : coreOptions.userVerification;

    const Vector encodedVector = fido::encodeGetAssertionRequestAsCBOR(makeVector(clientDataHash), coreOptions, coreUserVerificationAvailability(userVerificationAvailability), effectiveUVRequirement, makeVector<String>(authenticatorSupportedExtensions), std::nullopt);
    encodedCommand = toNSData(encodedVector);
#endif

    return encodedCommand.autorelease();
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
