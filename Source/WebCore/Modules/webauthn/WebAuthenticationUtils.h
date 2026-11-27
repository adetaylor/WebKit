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

#pragma once

#if ENABLE(WEB_AUTHN)

#include <WebCore/AuthenticatorTransport.h>
#include <WebCore/BufferSource.h>
#include <WebCore/FidoConstants.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/WebAuthenticationConstants.h>
#include <wtf/Forward.h>
#include <wtf/text/ASCIILiteral.h>

namespace WebCore {

WEBCORE_EXPORT Ref<ArrayBuffer> buildClientDataJson(ClientDataType /*type*/, const BufferSource& challenge, const SecurityOrigin& /*origin*/, WebAuthn::Scope, const String& topOrigin = { });

WEBCORE_EXPORT Vector<uint8_t> buildClientDataJsonHash(const ArrayBuffer& clientDataJson);

// encodeRawPublicKey takes X & Y and returns them as a 0x04 || X || Y byte array.
WEBCORE_EXPORT Vector<uint8_t> encodeRawPublicKey(const Vector<uint8_t>& X, const Vector<uint8_t>& Y);

WEBCORE_EXPORT String toString(AuthenticatorTransport);

NODELETE WEBCORE_EXPORT std::optional<AuthenticatorTransport> convertStringToAuthenticatorTransport(const String& transport);

// Returns why a URL can't be used as the crossDeviceFallbackUrl extension input, or nullopt if it can.
WEBCORE_EXPORT std::optional<String> validateCrossDeviceFallbackURL(const URL&);

// Names the results' types for the Swift implementations, which cannot spell a template instantiation.
using OptionalAuthenticatorTransport = std::optional<AuthenticatorTransport>;
using OptionalWebAuthnString = std::optional<String>;

// Names the members' type for the Swift implementation, which cannot spell a template instantiation.
using OptionalBool = std::optional<bool>;

// The options of a CTAP2 makeCredential or getAssertion request that the mock HID device acts on; each is nullopt
// when the request does not set it.
struct MockRequestOptions {
    OptionalBool requireResidentKey;
    OptionalBool requireUserVerification;
};
using OptionalMockRequestOptions = std::optional<MockRequestOptions>;

// Reads them from the request's CBOR (the bytes after the command byte); nullopt when the request cannot be read.
WEBCORE_EXPORT OptionalMockRequestOptions decodeMockRequestOptions(Vector<uint8_t> request, fido::CtapRequestCommand);

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
