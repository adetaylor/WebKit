/*
 * Copyright (C) 2018 Apple Inc. All rights reserved.
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
#import "MockLocalConnection.h"

#if ENABLE(WEB_AUTHN)

#import "WebKit-Swift.h"
#import <JavaScriptCore/ArrayBuffer.h>
#import <WebCore/AuthenticatorAssertionResponse.h>
#import <WebCore/ExceptionData.h>
#import <wtf/Borrow.h>
#import <wtf/RunLoop.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/Base64.h>
#import <wtf/text/WTFString.h>

#import "LocalAuthenticationSoftLink.h"

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(MockLocalConnection);

Ref<MockLocalConnection> MockLocalConnection::create(const WebCore::MockWebAuthenticationConfiguration& configuration)
{
    return adoptRef(*new MockLocalConnection(configuration));
}

MockLocalConnection::MockLocalConnection(const MockWebAuthenticationConfiguration& configuration)
    : m_configuration(configuration)
{
}

void MockLocalConnection::verifyUser(const String&, ClientDataType, SecAccessControlRef, WebCore::UserVerificationRequirement, UserVerificationCallback&& callback)
{
    // Mock async operations.
    RunLoop::mainSingleton().dispatch([configuration = m_configuration, callback = WTF::move(callback)]() mutable {
        ASSERT(configuration.local);
        callback(webAuthnMockUserVerification(configuration.local->userVerification), adoptNS([allocLAContextInstance() init]).get());
    });
}

void MockLocalConnection::verifyUser(SecAccessControlRef, LAContext *, CompletionHandler<void(UserVerification)>&& callback)
{
    // Mock async operations.
    RunLoop::mainSingleton().dispatch([configuration = m_configuration, callback = WTF::move(callback)]() mutable {
        ASSERT(configuration.local);
        callback(webAuthnMockUserVerification(configuration.local->userVerification));
    });
}

RetainPtr<SecKeyRef> MockLocalConnection::createCredentialPrivateKey(LAContext *, SecAccessControlRef, const String& secAttrLabel, NSData *secAttrApplicationTag) const
{
    ASSERT(m_configuration.local);
    return adoptCF(webAuthnMockCreateCredentialPrivateKey(m_configuration.local->privateKeyBase64.createNSString().get(), secAttrLabel.createNSString().get(), secAttrApplicationTag));
}

void MockLocalConnection::filterResponses(Vector<Ref<AuthenticatorAssertionResponse>>& responses) const
{
    const auto& preferredCredentialIdBase64 = m_configuration.local->preferredCredentialIdBase64;
    if (preferredCredentialIdBase64.isEmpty())
        return;

    RefPtr<AuthenticatorAssertionResponse> matchingResponse;
    for (auto& response : borrow(responses)) {
        RefPtr rawId = response->rawId();
        ASSERT(rawId);
        auto rawIdBase64 = base64EncodeToString(rawId->span());
        if (rawIdBase64 == preferredCredentialIdBase64) {
            matchingResponse = response.copyRef();
            break;
        }
    }
    responses.clear();
    responses.append(matchingResponse.releaseNonNull());
}

RetainPtr<NSArray> MockLocalConnection::getExistingCredentials(const String& rpId)
{
    return adoptNS(webAuthnMockExistingCredentials(rpId.createNSString().get()));
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
