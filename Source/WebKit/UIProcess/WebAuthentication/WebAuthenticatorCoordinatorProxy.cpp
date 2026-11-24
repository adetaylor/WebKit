/*
 * Copyright (C) 2018-2021 Apple Inc. All rights reserved.
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

#include "config.h"
#include "WebAuthenticatorCoordinatorProxy.h"

#if ENABLE(WEB_AUTHN)

#include "APIUIClient.h"
#include "WebAuthenticatorCoordinatorProxyMessages.h"
#include "WebAuthenticatorCoordinatorProxySwiftUtilities.h"
#include "WebFrameProxy.h"
#include "WebPageProxy.h"
#include "WebProcessProxy.h"
#include <WebCore/AuthenticatorResponse.h>
#include <WebCore/WebAuthenticationUtils.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMallocInlines.h>

// FIXME: https://bugs.webkit.org/show_bug.cgi?id=306415
#include "WebKit-Swift.h"

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebAuthenticatorCoordinatorProxy);

Ref<WebAuthenticatorCoordinatorProxy> WebAuthenticatorCoordinatorProxy::create(WebPageProxy& webPageProxy)
{
    return adoptRef(*new WebAuthenticatorCoordinatorProxy(webPageProxy));
}

WebAuthenticatorCoordinatorProxy::WebAuthenticatorCoordinatorProxy(WebPageProxy& webPageProxy)
    : m_impl(WTF::makeUniqueWithoutFastMallocCheck<WebAuthenticatorCoordinatorProxySwift>(WebAuthenticatorCoordinatorProxySwift::init(WeakPtr { webPageProxy })))
    , m_messageForwarder(m_impl->getMessageReceiver())
    , m_webPageProxy(webPageProxy)
{
    protect(webPageProxy.legacyMainFrameProcess())->addMessageReceiver(Messages::WebAuthenticatorCoordinatorProxy::messageReceiverName(), webPageProxy.webPageIDInMainFrameProcess(), m_messageForwarder.get());
}

WebAuthenticatorCoordinatorProxy::~WebAuthenticatorCoordinatorProxy()
{
    m_impl->cancelForDestruction();
    if (RefPtr webPageProxy = m_webPageProxy.get())
        protect(webPageProxy->legacyMainFrameProcess())->removeMessageReceiver(Messages::WebAuthenticatorCoordinatorProxy::messageReceiverName(), webPageProxy->webPageIDInMainFrameProcess());
}

RefPtr<JSC::ArrayBuffer> webAuthnClientDataJSONForRequest(const WebAuthenticationRequestData& data, const WebCore::SecurityOriginData& callerOrigin)
{
    // AS API makes no difference between SameSite vs CrossOrigin.
    auto scope = data.parentOrigin ? WebAuthn::Scope::CrossOrigin : WebAuthn::Scope::SameOrigin;
    auto topOrigin = data.parentOrigin ? data.parentOrigin->toString() : nullString();
    return WTF::switchOn(data.options, [&](const WebCore::PublicKeyCredentialCreationOptions& options) {
        return WebCore::buildClientDataJson(WebCore::ClientDataType::Create, options.challenge, callerOrigin.securityOrigin(), scope, topOrigin);
    }, [&](const WebCore::PublicKeyCredentialRequestOptions& options) {
        return WebCore::buildClientDataJson(WebCore::ClientDataType::Get, options.challenge, callerOrigin.securityOrigin(), scope, topOrigin);
    });
}

WebAuthnRequestReply webAuthnRequestReply(AuthenticatorManager::Respond result, RefPtr<JSC::ArrayBuffer> clientDataJSON)
{
    ASSERT(RunLoop::isMain());
    return WTF::switchOn(result, [&](const Ref<WebCore::AuthenticatorResponse>& response) {
        auto responseData = response->data();
        responseData.clientDataJSON = WTF::move(clientDataJSON);
        return WebAuthnRequestReply { WTF::move(responseData), response->attachment(), { } };
    }, [&](const WebCore::ExceptionData& exception) {
        return WebAuthnRequestReply { { }, WebCore::AuthenticatorAttachment::Platform, exception };
    });
}

WebAuthenticatorCoordinatorProxyMessageForwarder& WebAuthenticatorCoordinatorProxy::messageReceiver() const
{
    return m_messageForwarder.get();
}

#if HAVE(WEB_AUTHN_AS_MODERN)
void WebAuthenticatorCoordinatorProxy::makeActiveConditionalAssertion()
{
    m_impl->makeActiveConditionalAssertion();
}

void WebAuthenticatorCoordinatorProxy::recordAutofill(const String& username, const URL& url)
{
    m_impl->recordAutofill(username, url);
}
#endif

URL webAuthnFrameURL(const WebFrameProxy& frame)
{
    return frame.url();
}

void webAuthnRequestConditionalMediationRegistration(WebPageProxy& page, const String& username, Vector<String> relatedOrigins, CompletionHandler<void(std::optional<bool>)>&& completionHandler)
{
    page.uiClient().requestWebAuthenticationConditonalMediationRegistration(username, WTF::move(relatedOrigins), WTF::move(completionHandler));
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
