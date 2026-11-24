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
#include "WebCore-Swift.h"
#include <string_view>
#include <wtf/URL.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

Ref<ArrayBuffer> buildClientDataJson(ClientDataType type, const BufferSource& challenge, const SecurityOrigin& origin, WebAuthn::Scope scope, const String& topOrigin)
{
    return ArrayBuffer::create(webAuthnClientDataJSON(type, base64URLEncodeToString(challenge.span()), origin.toRawString(), scope, topOrigin).span());
}

Vector<uint8_t> buildClientDataJsonHash(const ArrayBuffer& clientDataJson)
{
    return webAuthnClientDataHash(clientDataJson.span());
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
    return webAuthnTransportString(transport);
}

std::optional<AuthenticatorTransport> convertStringToAuthenticatorTransport(const String& transport)
{
    return webAuthnTransport(transport);
}

std::optional<String> validateCrossDeviceFallbackURL(const URL& url)
{
    return webAuthnCrossDeviceFallbackURLError(url);
}

// The WebAuthenticationConstants.h names that WebAuthenticationUtils.swift's AuthenticatorTransportName spells as
// literals (ASCIILiteral does not import).
static consteval bool spells(ASCIILiteral name, std::string_view literal)
{
    return std::string_view(name.characters(), name.length()) == literal;
}
static_assert(spells(authenticatorTransportUsb, "usb") && spells(authenticatorTransportNfc, "nfc") && spells(authenticatorTransportBle, "ble") && spells(authenticatorTransportInternal, "internal"));
static_assert(spells(authenticatorTransportCable, "cable") && spells(authenticatorTransportHybrid, "hybrid") && spells(authenticatorTransportSmartCard, "smart-card"));

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
