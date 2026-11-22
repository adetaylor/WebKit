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

#include "config.h"
#include "AuthenticatorAttestationResponse.h"

#if ENABLE(WEB_AUTHN)

#include "AuthenticatorResponseData.h"
#include "WebAuthenticationUtils.h"
#include <wtf/Borrow.h>
#include <wtf/text/Base64.h>

namespace WebCore {

Ref<AuthenticatorAttestationResponse> AuthenticatorAttestationResponse::create(Ref<ArrayBuffer>&& rawId, Ref<ArrayBuffer>&& attestationObject, AuthenticatorAttachment attachment, Vector<AuthenticatorTransport>&& transports)
{
    return adoptRef(*new AuthenticatorAttestationResponse(WTF::move(rawId), WTF::move(attestationObject), attachment, WTF::move(transports)));
}

Ref<AuthenticatorAttestationResponse> AuthenticatorAttestationResponse::create(const Vector<uint8_t>& rawId, const Vector<uint8_t>& attestationObject, AuthenticatorAttachment attachment, Vector<AuthenticatorTransport>&& transports)
{
    return create(ArrayBuffer::create(borrow(rawId)->span()), ArrayBuffer::create(borrow(attestationObject)->span()), attachment, WTF::move(transports));
}

Ref<AuthenticatorAttestationResponse> AuthenticatorAttestationResponse::create(const Vector<uint8_t>& rawId, const Vector<uint8_t>& attestationObject, std::optional<AuthenticationExtensionsClientOutputs>&& extensions, AuthenticatorAttachment attachment, Vector<AuthenticatorTransport>&& transports)
{
    auto response = create(ArrayBuffer::create(borrow(rawId)->span()), ArrayBuffer::create(borrow(attestationObject)->span()), attachment, WTF::move(transports));
    if (extensions)
        response->setExtensions(WTF::move(*extensions));
    return response;
}

AuthenticatorAttestationResponse::AuthenticatorAttestationResponse(Ref<ArrayBuffer>&& rawId, Ref<ArrayBuffer>&& attestationObject, AuthenticatorAttachment attachment, Vector<AuthenticatorTransport>&& transports)
    : AuthenticatorResponse(WTF::move(rawId), attachment)
    , m_attestationObject(WTF::move(attestationObject))
    , m_transports(WTF::move(transports))
{
}

AuthenticatorResponseData AuthenticatorAttestationResponse::data() const
{
    auto data = AuthenticatorResponse::data();
    data.isAuthenticatorAttestationResponse = true;
    data.attestationObject = m_attestationObject.copyRef();
    data.transports = m_transports;
    return data;
}

RegistrationResponseJSON::AuthenticatorAttestationResponseJSON AuthenticatorAttestationResponse::toJSON()
{
    Vector<String> transports;
    for (auto transport : getTransports())
        transports.append(toString(transport));
    RegistrationResponseJSON::AuthenticatorAttestationResponseJSON value;
    if (RefPtr clientData = clientDataJSON())
        value.clientDataJSON = base64URLEncodeToString(clientData->span());
    value.transports = transports;
    if (auto authData = getAuthenticatorData())
        value.authenticatorData = base64URLEncodeToString(authData->span());
    if (auto publicKey = getPublicKey())
        value.publicKey = base64URLEncodeToString(publicKey->span());
    value.attestationObject = base64URLEncodeToString(attestationObject().span());
    value.publicKeyAlgorithm = getPublicKeyAlgorithm();

    return value;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
