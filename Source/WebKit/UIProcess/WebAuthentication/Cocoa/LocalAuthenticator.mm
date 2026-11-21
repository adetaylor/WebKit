/*
 * Copyright (C) 2018-2025 Apple Inc. All rights reserved.
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
#import "LocalAuthenticator.h"

#if ENABLE(WEB_AUTHN)

#import <WebCore/AuthenticatorAssertionResponse.h>
#import <WebCore/ExceptionData.h>
#import <WebCore/PublicKeyCredentialCreationOptions.h>
#import <WebCore/PublicKeyCredentialRequestOptions.h>
#import <WebCore/WebAuthenticationConstants.h>
#import <wtf/RunLoop.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/text/MakeString.h>

#import "AuthenticationServicesCoreSoftLink.h"

namespace WebKit {
using namespace WebCore;

BOOL shouldUseAlternateKeychainAttribute()
{
#if HAVE(UNIFIED_ASC_AUTH_UI)
    if (![WebKit::getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(shouldUseAlternateKeychainAttribute)])
        return NO;

    return [WebKit::getASCWebKitSPISupportClassSingleton() shouldUseAlternateKeychainAttribute];
#else
    return NO;
#endif
}

bool shouldUpdateQuery()
{
    if (WebKit::getASCWebKitSPISupportClassSingleton())
        return [WebKit::getASCWebKitSPISupportClassSingleton() shouldUseAlternateCredentialStore];

    return false;
}

CFDataRef copyEnterpriseAttestationIdentityPersistentReference(const String& rpId)
{
    RetainPtr<NSData> persistentRef = [WebKit::getASCWebKitSPISupportClassSingleton() entepriseAttestationIdentityPersistentReferenceForRelyingParty:rpId.createNSString().get()];
    return bridge_cast(WTF::move(persistentRef)).leakRef();
}

void addAuthenticationContext(const AuthenticatorAssertionResponse& response, CFMutableDictionaryRef query)
{
    if (RetainPtr context = response.laContext())
        [bridge_cast(query) setObject:context.get() forKey:(id)kSecUseAuthenticationContext];
}

LocalAuthenticator::LocalAuthenticator(Ref<LocalConnection>&& connection)
    : m_connection(WTF::move(connection))
{
}

LocalAuthenticator::~LocalAuthenticator() = default;

// The steps that hold the LAContext are C++: Swift cannot take an Objective-C object as a parameter of a C++ member
// it implements.
void LocalAuthenticator::requestLAContextForUserVerification()
{
    if (RefPtr observer = this->observer()) {
        auto callback = [weakThis = WeakPtr { *this }] (LAContext *context) {
            ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
            if (RefPtr protectedThis = weakThis.get())
                protectedThis->continueMakeCredentialAfterReceivingLAContext(context);
        };
        observer->requestLAContextForUserVerification(WTF::move(callback));
    }
}

void LocalAuthenticator::continueMakeCredentialAfterReceivingLAContext(LAContext *context)
{
    ASSERT(m_state == State::RequestReceived);
    m_state = State::PolicyDecided;

    RetainPtr<SecAccessControlRef> accessControl;
    {
        CFErrorRef rawError = nullptr;
        accessControl = adoptCF(SecAccessControlCreateWithFlags(NULL, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, kSecAccessControlPrivateKeyUsage | kSecAccessControlUserPresence, &rawError));
        // FIXME: The Security framework API is missing the `CF_RETURNS_RETAINED` annotation (rdar://161546781).
        SUPPRESS_RETAINPTR_CTOR_ADOPT if (RetainPtr error = adoptCF(rawError)) {
            receiveException({ ExceptionCode::UnknownError, makeString("Couldn't create access control: "_s, String(bridge_cast(error.get()).localizedDescription)) });
            return;
        }
    }

    auto callback = [accessControl, context = retainPtr(context), weakThis = WeakPtr { *this }] (LocalConnection::UserVerification verification) {
        ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->continueMakeCredentialAfterUserVerification(accessControl.get(), verification, context.get());
    };
    m_connection->verifyUser(accessControl.get(), context, WTF::move(callback));
}

void LocalAuthenticator::continueMakeCredentialAfterUserVerification(SecAccessControlRef accessControlRef, LocalConnection::UserVerification verification, LAContext *context)
{
    ASSERT(m_state == State::PolicyDecided);
    m_state = State::UserVerified;
    auto& creationOptions = std::get<PublicKeyCredentialCreationOptions>(requestData().options);

    if (!validateUserVerification(verification))
        return;

    // Here is the keychain schema.
    // kSecAttrLabel: RP ID
    // kSecAttrApplicationLabel: Credential ID (auto-gen by Keychain)
    // kSecAttrApplicationTag: { "id": UserEntity.id, "name": UserEntity.name, "displayName": UserEntity.name} (CBOR encoded)
    // Noted, the vale of kSecAttrApplicationLabel is automatically generated by the Keychain, which is a SHA-1 hash of
    // the public key.
    ASSERT(creationOptions.rp.id);
    const auto& secAttrLabel = creationOptions.rp.id;
    auto secAttrApplicationTag = WTF::toNSData(userEntityTag().span());

    // Step 7.
    // The above-to-create private key will be inserted into keychain while using SEP.
    auto privateKey = m_connection->createCredentialPrivateKey(context, accessControlRef, secAttrLabel, secAttrApplicationTag.get());
    if (!privateKey) {
        receiveException({ ExceptionCode::UnknownError, "Couldn't create private key."_s });
        return;
    }

    RetainPtr<CFDataRef> publicKeyDataRef;
    {
        auto publicKey = adoptCF(SecKeyCopyPublicKey(privateKey.get()));
        CFErrorRef rawError = nullptr;
        publicKeyDataRef = adoptCF(SecKeyCopyExternalRepresentation(publicKey.get(), &rawError));
        // FIXME: The Security framework API is missing the `CF_RETURNS_RETAINED` annotation (rdar://161546781).
        SUPPRESS_RETAINPTR_CTOR_ADOPT if (RetainPtr error = adoptCF(rawError)) {
            receiveException({ ExceptionCode::UnknownError, makeString("Couldn't export the public key: "_s, String((bridge_cast(error.get())).localizedDescription)) });
            return;
        }
        ASSERT(((NSData *)publicKeyDataRef.get()).length == (1 + 2 * ES256FieldElementLength)); // 04 | X | Y
    }

    continueMakeCredentialAfterCreatingPrivateKey(publicKeyDataRef.get(), verification);
}

// Vector<Ref<AuthenticatorAssertionResponse>> imports as unsafe, so LocalAuthenticator.swift names the credentials by index.
void LocalAuthenticator::selectAssertionResponseFromObserver(const CredentialIndices& indices)
{
    auto assertionResponses = WTF::map(indices, [&](size_t index) {
        return m_existingCredentials[index].copyRef();
    });

    // Step 6-7. User consent is implicitly acquired by selecting responses.
    m_connection->filterResponses(assertionResponses);

    if (RefPtr observer = this->observer()) {
        auto callback = [weakThis = WeakPtr { *this }] (AuthenticatorAssertionResponse* response) {
            RELEASE_ASSERT(RunLoop::isMain());
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis)
                return;

            auto result = protectedThis->m_existingCredentials.findIf([expectedResponse = response] (auto& response) {
                return response.ptr() == expectedResponse;
            });
            if (result == notFound)
                return;
            protectedThis->continueGetAssertionAfterResponseSelected(protectedThis->m_existingCredentials[result].copyRef());
        };
        observer->selectAssertionResponse(WTF::move(assertionResponses), WebAuthenticationSource::Local, WTF::move(callback));
    }
}

void LocalAuthenticator::continueGetAssertionAfterResponseSelected(Ref<WebCore::AuthenticatorAssertionResponse>&& response)
{
    ASSERT(m_state == State::RequestReceived);
    m_state = State::ResponseSelected;

    RetainPtr accessControlRef = response->accessControl();
    RetainPtr context = response->laContext();
    auto callback = [weakThis = WeakPtr { *this }, response = WTF::move(response)] (LocalConnection::UserVerification verification) mutable {
        ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->continueGetAssertionAfterUserVerification(response, verification);
    };

    m_connection->verifyUser(accessControlRef.get(), context.get(), WTF::move(callback));
}

// AuthenticationServicesCore is soft-linked, which LocalAuthenticator.swift does not reach.
RefPtr<ArrayBuffer> LocalAuthenticator::alternateBlobIfNecessary() const
{
#if HAVE(WEB_AUTHN_PRF_API)
    return nullptr;
#else
    RetainPtr nsClientDataHash = toNSData(requestData().hash.span());
    auto& requestOptions = std::get<WebCore::PublicKeyCredentialRequestOptions>(requestData().options);
    if (![WebKit::getASCWebKitSPISupportClassSingleton() respondsToSelector:@selector(alternateLargeBlobIfNecessaryForRelyingParty:clientDataHash:)])
        return nullptr;
    NSData *alternateBlob = [WebKit::getASCWebKitSPISupportClassSingleton() alternateLargeBlobIfNecessaryForRelyingParty:requestOptions.rpId.createNSString().autorelease() clientDataHash:nsClientDataHash.get()];
    if (!alternateBlob)
        return nullptr;

    return ArrayBuffer::tryCreate(span(alternateBlob));
#endif // not HAVE(WEB_AUTHN_PRF_API)
}

bool LocalAuthenticator::validateUserVerification(LocalConnection::UserVerification verification) const
{
    if (verification == LocalConnection::UserVerification::Cancel) {
        if (RefPtr observer = this->observer())
            observer->cancelRequest();
        return false;
    }

    if (verification == LocalConnection::UserVerification::No) {
        receiveException({ ExceptionCode::NotAllowedError, "Couldn't verify user."_s });
        RELEASE_LOG_ERROR(WebAuthn, "Could not verify user.");
        return false;
    }

    return true;
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
