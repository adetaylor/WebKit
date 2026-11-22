/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
#include "WebAuthenticationUtils.h"

#if ENABLE(WEB_AUTHN)

#include "WebAuthenticationConstants.h"
#include <pal/crypto/CryptoDigest.h>
#include <wtf/JSONValues.h>
#include <wtf/StdLibExtras.h>
#include <wtf/URL.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

Ref<ArrayBuffer> buildClientDataJson(ClientDataType type, const BufferSource& challenge, const SecurityOrigin& origin, WebAuthn::Scope scope, const String& topOrigin)
{
    // https://www.w3.org/TR/webauthn-2/#clientdatajson-verification
    auto object = JSON::Object::create();
    switch (type) {
    case ClientDataType::Create:
        object->setString("type"_s, "webauthn.create"_s);
        break;
    case ClientDataType::Get:
        object->setString("type"_s, "webauthn.get"_s);
        break;
    }
    object->setString("challenge"_s, base64URLEncodeToString(challenge.span()));
    object->setString("origin"_s, origin.toRawString());

    if (scope != WebAuthn::Scope::SameOrigin)
        object->setBoolean("crossOrigin"_s, scope != WebAuthn::Scope::SameOrigin);

    if (!topOrigin.isNull())
        object->setString("topOrigin"_s, topOrigin);

    return ArrayBuffer::create(byteCast<uint8_t>(object->toJSONString().utf8().span()));
}

Vector<uint8_t> buildClientDataJsonHash(const ArrayBuffer& clientDataJson)
{
    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(clientDataJson.span());
    return crypto->computeHash();
}

Vector<uint8_t> encodeRawPublicKey(const Vector<uint8_t>& x, const Vector<uint8_t>& y)
{
    Vector<uint8_t> rawKey(ReserveCapacityTag { }, 1 + x.size() + y.size());
    rawKey.append(0x04);
    rawKey.appendVector(x);
    rawKey.appendVector(y);
    return rawKey;
}

String toString(AuthenticatorTransport transport)
{
    switch (transport) {
    case AuthenticatorTransport::Usb:
        return authenticatorTransportUsb;
        break;
    case AuthenticatorTransport::Nfc:
        return authenticatorTransportNfc;
        break;
    case AuthenticatorTransport::Ble:
        return authenticatorTransportBle;
        break;
    case AuthenticatorTransport::Internal:
        return authenticatorTransportInternal;
        break;
    case AuthenticatorTransport::Cable:
        return authenticatorTransportCable;
    case AuthenticatorTransport::Hybrid:
        return authenticatorTransportHybrid;
    case AuthenticatorTransport::SmartCard:
        return authenticatorTransportSmartCard;
    default:
        break;
    }
    ASSERT_NOT_REACHED();
    return nullString();
}

std::optional<AuthenticatorTransport> convertStringToAuthenticatorTransport(const String& transport)
{
    if (transport == authenticatorTransportUsb)
        return AuthenticatorTransport::Usb;
    if (transport == authenticatorTransportNfc)
        return AuthenticatorTransport::Nfc;
    if (transport == authenticatorTransportBle)
        return AuthenticatorTransport::Ble;
    if (transport == authenticatorTransportInternal)
        return AuthenticatorTransport::Internal;
    if (transport == authenticatorTransportCable)
        return AuthenticatorTransport::Cable;
    if (transport == authenticatorTransportHybrid)
        return AuthenticatorTransport::Hybrid;
    if (transport == authenticatorTransportSmartCard)
        return AuthenticatorTransport::SmartCard;
    return std::nullopt;
}

std::optional<ASCIILiteral> validateCrossDeviceFallbackURL(const URL& url)
{
    if (!url.isValid() || !url.protocolIs("https"_s))
        return "The cross-device fallback URL is not a valid https URL."_s;
    if (url.host().isEmpty() || URL::hostIsIPAddress(url.host()))
        return "The effective domain of the cross-device fallback URL is not a valid domain."_s;
    return std::nullopt;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
