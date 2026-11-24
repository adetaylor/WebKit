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

#import "WebKit-Swift.h"
#import <WebCore/AuthenticatorAssertionResponse.h>
#import <WebCore/ExceptionData.h>
#import <wtf/RunLoop.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

#import "LocalAuthenticationSoftLink.h"

namespace WebKit {
using namespace WebCore;

void addAuthenticationContext(const AuthenticatorAssertionResponse& response, CFMutableDictionaryRef query)
{
    if (RetainPtr context = response.laContext())
        [bridge_cast(query) setObject:context.get() forKey:(id)kSecUseAuthenticationContext];
}

SecKeyRef copyWebAuthnCredentialPrivateKey(const LocalConnection& connection, LAContext *context, SecAccessControlRef accessControl, const String& secAttrLabel, NSData *secAttrApplicationTag)
{
    return connection.createCredentialPrivateKey(context, accessControl, secAttrLabel, secAttrApplicationTag).leakRef();
}

LocalAuthenticator::LocalAuthenticator(Ref<LocalConnection>&& connection)
    : m_connection(WTF::move(connection))
{
}

LocalAuthenticator::~LocalAuthenticator() = default;

// The observer's handler takes an LAContext, which Swift can neither make nor call.
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

// An @cxx member cannot take an Objective-C object, so this forwards to an exposed Swift function.
void LocalAuthenticator::continueMakeCredentialAfterReceivingLAContext(LAContext *context)
{
    webAuthnContinueMakeCredentialAfterReceivingLAContext(this, context);
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
