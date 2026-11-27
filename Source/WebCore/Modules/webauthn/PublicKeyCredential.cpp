/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
#include "PublicKeyCredential.h"

#if ENABLE(WEB_AUTHN)

#include "AllAcceptedCredentialsOptions.h"
#include "AuthenticatorCoordinator.h"
#include "AuthenticatorResponse.h"
#include "CurrentUserDetailsOptions.h"
#include "Document.h"
#include "DocumentPage.h"
#include "ExceptionOr.h"
#include "JSDOMPromiseDeferred.h"
#include "Page.h"
#include "PublicKeyCredentialCreationOptions.h"
#include "PublicKeyCredentialCreationOptionsJSON.h"
#include "PublicKeyCredentialRequestOptions.h"
#include "PublicKeyCredentialRequestOptionsJSON.h"
#include "Settings.h"
#include "UnknownCredentialOptions.h"
#include "WebCore-Swift.h"
#include <wtf/text/Base64.h>

namespace WebCore {

Ref<PublicKeyCredential> PublicKeyCredential::create(Ref<AuthenticatorResponse>&& response)
{
    return adoptRef(*new PublicKeyCredential(WTF::move(response)));
}

ArrayBuffer& PublicKeyCredential::rawId() const
{
    return m_response->rawId();
}

AuthenticationExtensionsClientOutputs PublicKeyCredential::getClientExtensionResults() const
{
    return m_response->extensions();
}

AuthenticatorAttachment PublicKeyCredential::authenticatorAttachment() const
{
    return m_response->attachment();
}

PublicKeyCredential::PublicKeyCredential(Ref<AuthenticatorResponse>&& response)
    : BasicCredential(base64URLEncodeToString(response->rawId().span()), Type::PublicKey, Discovery::Remote)
    , m_response(WTF::move(response))
{
}

void PublicKeyCredential::isUserVerifyingPlatformAuthenticatorAvailable(Document& document, DOMPromiseDeferred<IDLBoolean>&& promise)
{
    if (RefPtr page = document.page())
        page->authenticatorCoordinator().isUserVerifyingPlatformAuthenticatorAvailable(document, WTF::move(promise));
}

void PublicKeyCredential::getClientCapabilities(Document& document, DOMPromiseDeferred<IDLRecord<IDLDOMString, IDLBoolean>>&& promise)
{
    if (RefPtr page = document.page())
        page->authenticatorCoordinator().getClientCapabilities(document, WTF::move(promise));
}

ExceptionOr<PublicKeyCredentialCreationOptions> PublicKeyCredential::parseCreationOptionsFromJSON(PublicKeyCredentialCreationOptionsJSON&& jsonOptions)
{
    bool hasExtensions = !!jsonOptions.extensions;
    auto members = webAuthnParseCreationOptionsMembersFromJSON(WTF::move(jsonOptions.user), WTF::move(jsonOptions.challenge), WTF::move(jsonOptions.excludeCredentials), WTF::move(jsonOptions.attestation), hasExtensions, hasExtensions ? WTF::move(*jsonOptions.extensions) : AuthenticationExtensionsClientInputsJSON { });
    if (!members.challenge)
        return WTF::move(members.exception).toException();

    return PublicKeyCredentialCreationOptions {
        .rp = WTF::move(jsonOptions.rp),
        .user = WTF::move(*members.user),
        .challenge = WTF::move(*members.challenge),
        .pubKeyCredParams = WTF::move(jsonOptions.pubKeyCredParams),
        .timeout = WTF::move(jsonOptions.timeout),
        .excludeCredentials = WTF::move(members.excludeCredentials),
        .authenticatorSelection = WTF::move(jsonOptions.authenticatorSelection),
        .attestation = members.attestation,
        .extensions = WTF::move(members.extensions),
    };
}

ExceptionOr<PublicKeyCredentialRequestOptions> PublicKeyCredential::parseRequestOptionsFromJSON(PublicKeyCredentialRequestOptionsJSON&& jsonOptions)
{
    bool hasExtensions = !!jsonOptions.extensions;
    auto members = webAuthnParseRequestOptionsMembersFromJSON(WTF::move(jsonOptions.challenge), WTF::move(jsonOptions.allowCredentials), WTF::move(jsonOptions.userVerification), hasExtensions, hasExtensions ? WTF::move(*jsonOptions.extensions) : AuthenticationExtensionsClientInputsJSON { });
    if (!members.challenge)
        return WTF::move(members.exception).toException();

    return PublicKeyCredentialRequestOptions {
        .challenge = WTF::move(*members.challenge),
        .timeout = WTF::move(jsonOptions.timeout),
        .rpId = WTF::move(jsonOptions.rpId),
        .allowCredentials = WTF::move(members.allowCredentials),
        .userVerification = members.userVerification,
        .extensions = WTF::move(members.extensions),
        .authenticatorAttachment = { },
    };
}

void PublicKeyCredential::signalUnknownCredential(Document& document, UnknownCredentialOptions&& options, DOMPromiseDeferred<void>&& promise)
{
    if (RefPtr page = document.page())
        page->authenticatorCoordinator().signalUnknownCredential(document, WTF::move(options), WTF::move(promise));
}

void PublicKeyCredential::signalAllAcceptedCredentials(Document& document, AllAcceptedCredentialsOptions&& options, DOMPromiseDeferred<void>&& promise)
{
    if (RefPtr page = document.page())
        page->authenticatorCoordinator().signalAllAcceptedCredentials(document, WTF::move(options), WTF::move(promise));
}

void PublicKeyCredential::signalCurrentUserDetails(Document& document, CurrentUserDetailsOptions&& options, DOMPromiseDeferred<void>&& promise)
{
    if (RefPtr page = document.page())
        page->authenticatorCoordinator().signalCurrentUserDetails(document, WTF::move(options), WTF::move(promise));
}

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
