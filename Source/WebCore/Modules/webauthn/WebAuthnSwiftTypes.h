/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include <WebCore/ApduCommand.h>
#include <WebCore/ApduResponse.h>
#include <WebCore/AuthenticationExtensionsClientInputs.h>
#include <WebCore/AuthenticationExtensionsClientOutputs.h>
#include <WebCore/AuthenticationResponseJSON.h>
#include <WebCore/AuthenticatorAssertionResponse.h>
#include <WebCore/AuthenticatorAttestationResponse.h>
#include <WebCore/AuthenticatorGetInfoResponse.h>
#include <WebCore/AuthenticatorResponse.h>
#include <WebCore/AuthenticatorResponseData.h>
#include <WebCore/BufferSource.h>
#include <WebCore/CBORBytes.h>
#include <WebCore/CryptoKeyAES.h>
#include <WebCore/CryptoKeyEC.h>
#include <WebCore/CryptoKeyHMAC.h>
#include <WebCore/DeviceRequestConverter.h>
#include <WebCore/DeviceResponseConverter.h>
#include <WebCore/ExceptionCode.h>
#include <WebCore/ExceptionData.h>
#include <WebCore/FidoHidMessage.h>
#include <WebCore/FidoHidPacket.h>
#include <WebCore/LegacySchemeRegistry.h>
#include <WebCore/Pin.h>
#include <WebCore/PublicKeyCredentialCreationOptions.h>
#include <WebCore/PublicKeyCredentialCreationOptionsJSON.h>
#include <WebCore/PublicKeyCredentialRequestOptions.h>
#include <WebCore/PublicKeyCredentialRequestOptionsJSON.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/RegistrationResponseJSON.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/U2fCommandConstructor.h>
#include <WebCore/U2fResponseConverter.h>
#include <WebCore/WebAuthenticationUtils.h>
#include <WebCore/WellKnownOriginList.h>
#include <wtf/URL.h>
#include <wtf/Variant.h>
#include <wtf/text/Base64.h>

namespace fido {

// Names for the template instantiations in the WebAuthn entries' signatures, which Swift cannot spell.
using StringVector = Vector<String>;
using ByteVectorVector = Vector<Vector<uint8_t>>;
using OptionalByteVector = std::optional<Vector<uint8_t>>;
using OptionalUInt32 = std::optional<uint32_t>;
using PinProtocolVector = Vector<PINUVAuthProtocol>;
using OptionalPinProtocolVector = std::optional<PinProtocolVector>;
using OptionalStringVector = std::optional<Vector<String>>;
using OptionalPinParameters = std::optional<PinParameters>;
using OptionalHmacSecretParameters = std::optional<HmacSecretParameters>;
using CredentialParametersVector = Vector<WebCore::PublicKeyCredentialParameters>;
using OptionalCredentialParametersVector = std::optional<Vector<WebCore::PublicKeyCredentialParameters>>;
using CredentialDescriptorVector = Vector<WebCore::PublicKeyCredentialDescriptor>;
using OptionalCredentialDescriptorVector = std::optional<Vector<WebCore::PublicKeyCredentialDescriptor>>;
using TransportVector = Vector<WebCore::AuthenticatorTransport>;
using OptionalTransportVector = std::optional<TransportVector>;
using AttestationResponsePtr = RefPtr<WebCore::AuthenticatorAttestationResponse>;
using AssertionResponsePtr = RefPtr<WebCore::AuthenticatorAssertionResponse>;
using OptionalGetInfoResponse = std::optional<AuthenticatorGetInfoResponse>;
using CryptoKeyAESPtr = RefPtr<WebCore::CryptoKeyAES>;
using CryptoKeyECPtr = RefPtr<WebCore::CryptoKeyEC>;
using CryptoKeyHMACPtr = RefPtr<WebCore::CryptoKeyHMAC>;
using OptionalTokenRequest = std::optional<pin::TokenRequest>;
using OptionalSetPinRequest = std::optional<pin::SetPinRequest>;
using OptionalHmacSecretRequest = std::optional<pin::HmacSecretRequest>;
using OptionalHmacSecretResponse = std::optional<pin::HmacSecretResponse>;
using OptionalApduCommand = std::optional<apdu::ApduCommand>;
using OptionalApduResponse = std::optional<apdu::ApduResponse>;
using OptionalClientOutputs = std::optional<WebCore::AuthenticationExtensionsClientOutputs>;
using OptionalClientInputs = std::optional<WebCore::AuthenticationExtensionsClientInputs>;
using ArrayBufferPtr = RefPtr<JSC::ArrayBuffer>;
// PublicKeyCredentialType has one enumerator, which Swift imports with no cases.
inline WebCore::PublicKeyCredentialType publicKeyCredentialTypePublicKey() { return WebCore::PublicKeyCredentialType::PublicKey; }
// WTF::emptyString() by value: Swift imports its const String& result as a pointer.
inline String emptyWTFString() { return emptyString(); }
// CStringBase::length(), which Swift does not import on the CString template.
inline size_t utf8CStringLength(const UTF8CString& string) { return string.length(); }
// For WebKit's Swift: ApduCommand::kApduMaxResponseLength, a static constexpr member Swift does not import.
inline size_t apduMaxResponseLength() { return apdu::ApduCommand::kApduMaxResponseLength; }
// ApduResponse::data() by value: Swift imports neither of its const and non-const reference overloads.
inline Vector<uint8_t> apduResponseData(const apdu::ApduResponse& response) { return response.data(); }
// base64EncodeToString and base64URLEncodeToString of a byte vector: Swift reaches only their std::span overloads,
// and only unsafely.
// A byte vector built by bulk copies. Swift gets a Span overload of add (noescape) only on a function whose signature
// has no Vector, so the vector is a member. Its Swift callers pass no empty Span (an empty Span() traps at a std::span).
struct WebAuthnByteSink {
    void reserve(size_t capacity) { bytes.reserveCapacity(capacity); }
    void add([[clang::noescape]] std::span<const uint8_t> span) { bytes.append(span); }
    void addByte(uint8_t byte) { bytes.append(byte); }
    Vector<uint8_t> take() { return std::exchange(bytes, { }); }
    Vector<uint8_t> bytes;
};
// A BufferSource holding an ArrayBuffer, the shape every option and extension input from the panel, the JSON parsers and
// the request validation takes. Swift calls none of BufferSource's constructors: each takes the Variant or an rvalue
// Ref.
inline WebCore::BufferSource bufferSourceFromArrayBuffer(Ref<JSC::ArrayBuffer> buffer) { return WebCore::BufferSource(WTF::move(buffer)); }
// The same over a copy of bytes.
inline WebCore::BufferSource bufferSourceFromBytes(const Vector<uint8_t>& bytes) { return WebCore::BufferSource(JSC::ArrayBuffer::create(bytes.span())); }

// Build the extension inputs and outputs that the CBOR codecs read. Swift cannot construct their nested optionals,
// or their Ref and RefPtr members, field by field. A largeBlob setter follows beginLargeBlob.
struct WebAuthnClientInputsBuilder {
    void setAppid(const String& appid) { inputs.appid = appid; }
    void setCredProps(bool credProps) { inputs.credProps = credProps; }
    void setCrossDeviceFallbackURL(const String& url) { inputs.crossDeviceFallbackURL = url; }
    void beginLargeBlob() { inputs.largeBlob = WebCore::AuthenticationExtensionsClientInputs::LargeBlobInputs { }; }
    void setLargeBlobSupport(const String& support) { inputs.largeBlob->support = support; }
    void setLargeBlobRead(bool read) { inputs.largeBlob->read = read; }
    void setLargeBlobWrite(const Vector<uint8_t>& write) { inputs.largeBlob->write = bufferSourceFromBytes(write); }
    // The PRF inputs: beginPRF, then eval's first salt and optionally its second, then for evalByCredential its begin
    // and, per credential, its first salt and optionally the second, which applies to the last credential added.
    void beginPRF() { inputs.prf = WebCore::AuthenticationExtensionsClientInputs::PRFInputs { }; }
    void setPRFEval(const Vector<uint8_t>& first) { inputs.prf->eval = WebCore::AuthenticationExtensionsClientInputs::PRFValues { bufferSourceFromBytes(first), std::nullopt }; }
    void setPRFEvalSecond(const Vector<uint8_t>& second) { inputs.prf->eval->second = bufferSourceFromBytes(second); }
    void beginPRFEvalByCredential() { inputs.prf->evalByCredential = Vector<KeyValuePair<String, WebCore::AuthenticationExtensionsClientInputs::PRFValues>> { }; }
    void addPRFEvalByCredential(const String& credentialID, const Vector<uint8_t>& first) { inputs.prf->evalByCredential->append({ credentialID, WebCore::AuthenticationExtensionsClientInputs::PRFValues { bufferSourceFromBytes(first), std::nullopt } }); }
    void setLastPRFEvalByCredentialSecond(const Vector<uint8_t>& second) { inputs.prf->evalByCredential->last().value.second = bufferSourceFromBytes(second); }
    // The builder is used once: take moves the inputs out.
    std::optional<WebCore::AuthenticationExtensionsClientInputs> take() { return WTF::move(inputs); }
    WebCore::AuthenticationExtensionsClientInputs inputs;
};

struct WebAuthnClientOutputsBuilder {
    void setAppid(bool appid) { outputs.appid = appid; }
    void setCredPropsRk(bool rk) { outputs.credProps = WebCore::CredentialPropertiesOutput { rk }; }
    void beginLargeBlob() { outputs.largeBlob = WebCore::AuthenticationExtensionsClientOutputs::LargeBlobOutputs { }; }
    void setLargeBlobSupported(bool supported) { outputs.largeBlob->supported = supported; }
    void setLargeBlobBlob(const Vector<uint8_t>& blob) { outputs.largeBlob->blob = JSC::ArrayBuffer::create(blob.span()); }
    void setLargeBlobWritten(bool written) { outputs.largeBlob->written = written; }
    std::optional<WebCore::AuthenticationExtensionsClientOutputs> take() { return std::exchange(outputs, { }); }
    WebCore::AuthenticationExtensionsClientOutputs outputs;
};

// The bytes of the large blob output's blob, or nullopt when it has none.
inline std::optional<Vector<uint8_t>> largeBlobOutputBytes(const WebCore::AuthenticationExtensionsClientOutputs::LargeBlobOutputs& largeBlob)
{
    if (RefPtr blob = largeBlob.blob)
        return blob->toVector();
    return std::nullopt;
}

// ArrayBuffer::tryCreate of a span: Swift gets a Span overload only for a noescape std::span parameter, which
// ArrayBuffer.h gives create() alone.
inline ArrayBufferPtr tryCreateArrayBuffer([[clang::noescape]] std::span<const uint8_t> bytes) { return JSC::ArrayBuffer::tryCreate(bytes); }
// CryptoKeyEC::exportSpki()'s value, which stops on an exception: Swift does not import ExceptionOr's returnValue(),
// and imports releaseReturnValue() as unsafe.
inline Vector<uint8_t> exportSpki(const WebCore::CryptoKeyEC& key) { return key.exportSpki().releaseReturnValue(); }

inline String base64EncodeBytes(const Vector<uint8_t>& bytes) { return base64EncodeToString(bytes.span()); }
inline String base64URLEncodeBytes(const Vector<uint8_t>& bytes) { return base64URLEncodeToString(bytes.span()); }
// base64URLDecode of a String: Swift reaches only its StringView overload, which it cannot spell.
inline std::optional<Vector<uint8_t>> base64URLDecodeString(const String& string) { return base64URLDecode(string); }
// base64Decode of a String, for the same reason.
inline std::optional<Vector<uint8_t>> base64DecodeString(const String& string) { return base64Decode(string); }
// The ArrayBuffer of a base64url String's bytes, made from the decoded Vector in place: through
// base64URLDecodeString, Swift's Optional(fromCxx:) copies the Vector before the buffer is made.
inline std::optional<WebCore::BufferSource> bufferSourceFromBase64URLString(const String& string)
{
    auto bytes = base64URLDecode(string);
    if (!bytes)
        return std::nullopt;
    return WebCore::BufferSource(JSC::ArrayBuffer::create(bytes->span()));
}

// The JSON dictionaries' list, for the signatures of PublicKeyCredential's Swift parsers.
using CredentialDescriptorJSONVector = Vector<WebCore::PublicKeyCredentialDescriptorJSON>;

// What PublicKeyCredential's Swift JSON parsers return to their C++ shells, which move the other members out of the
// JSON dictionary and make the ExceptionOr Swift cannot use: the parsed members when the parse succeeded (the challenge
// is set), else the exception.
struct WebAuthnParsedCreationOptionsMembers {
    std::optional<WebCore::PublicKeyCredentialUserEntity> user;
    std::optional<WebCore::BufferSource> challenge;
    Vector<WebCore::PublicKeyCredentialDescriptor> excludeCredentials;
    WebCore::AttestationConveyancePreference attestation { WebCore::AttestationConveyancePreference::None };
    std::optional<WebCore::AuthenticationExtensionsClientInputs> extensions;
    WebCore::ExceptionData exception { WebCore::ExceptionCode::EncodingError, { } };
};
struct WebAuthnParsedRequestOptionsMembers {
    std::optional<WebCore::BufferSource> challenge;
    Vector<WebCore::PublicKeyCredentialDescriptor> allowCredentials;
    WebCore::UserVerificationRequirement userVerification { WebCore::UserVerificationRequirement::Preferred };
    std::optional<WebCore::AuthenticationExtensionsClientInputs> extensions;
    WebCore::ExceptionData exception { WebCore::ExceptionCode::EncodingError, { } };
};

// What AuthenticatorCoordinator's Swift checks of the create() and get() options return to its C++, which settles the
// promise: the options with their defaults filled in when they pass, else the exception.
struct WebAuthnValidatedCreationOptions {
    std::optional<WebCore::PublicKeyCredentialCreationOptions> options;
    WebCore::ExceptionData exception { };
};
struct WebAuthnValidatedRequestOptions {
    std::optional<WebCore::PublicKeyCredentialRequestOptions> options;
    WebCore::ExceptionData exception { };
};

// For AuthenticatorCoordinator's appid check: Swift calls none of URL's String constructors (each takes a pointer to
// an encoding), compares RegistrableDomain only in C++, and makes no StringView for URL::protocol() or
// LegacySchemeRegistry.
inline URL webAuthnURLFromString(const String& string) { return URL { string }; }
inline String webAuthnURLProtocol(const URL& url) { return url.protocol().toString(); }
inline bool webAuthnIsSameSite(const URL& url, const String& host) { return WebCore::RegistrableDomain(url) == WebCore::RegistrableDomain::uncheckedCreateFromHost(host); }
// The legacy path's cross-site assertion and the Signal* handlers' check that the relying party is the origin's
// registrable domain.
inline String webAuthnRegistrableDomain(const WebCore::SecurityOriginData& origin) { return WebCore::RegistrableDomain(origin).string(); }
inline bool webAuthnRelyingPartyIsRegistrableDomainOf(const String& relyingPartyIdentifier, const WebCore::SecurityOriginData& origin) { return WebCore::RegistrableDomain::uncheckedCreateFromHost(relyingPartyIdentifier) == WebCore::RegistrableDomain { origin }; }
inline bool webAuthnURLSchemeIsSecure(const String& scheme) { return WebCore::LegacySchemeRegistry::shouldTreatURLSchemeAsSecure(scheme); }

// For validateCrossDeviceFallbackURL's Swift: URL::protocolIs and URL::hostIsIPAddress take an ASCIILiteral and a
// StringView, which Swift cannot make.
inline bool webAuthnURLIsHTTPS(const URL& url) { return url.protocolIs("https"_s); }
inline bool webAuthnURLHostIsEmptyOrIPAddress(const URL& url) { return url.host().isEmpty() || URL::hostIsIPAddress(url.host()); }

// For the Swift JSON parsers: Swift has no initializer for a struct with a base class.
inline WebCore::PublicKeyCredentialUserEntity makePublicKeyCredentialUserEntity(String name, WebCore::BufferSource id, String displayName)
{
    return { WebCore::PublicKeyCredentialEntity { WTF::move(name), { } }, WTF::move(id), WTF::move(displayName) };
}

// PublicKeyCredential::toJSON()'s result (PublicKeyCredentialJSON) from either alternative: Swift calls none of the
// Variant's constructors.
using PublicKeyCredentialJSONVariant = Variant<WebCore::RegistrationResponseJSON, WebCore::AuthenticationResponseJSON>;
inline PublicKeyCredentialJSONVariant publicKeyCredentialJSON(WebCore::RegistrationResponseJSON json) { return json; }
inline PublicKeyCredentialJSONVariant publicKeyCredentialJSON(WebCore::AuthenticationResponseJSON json) { return json; }

// The response as its subclass, or null: Swift's as? does not downcast a C++ class. The response's type() says which.
inline AttestationResponsePtr attestationResponse(WebCore::AuthenticatorResponse& response) { return dynamicDowncast<WebCore::AuthenticatorAttestationResponse>(response); }
inline AssertionResponsePtr assertionResponse(WebCore::AuthenticatorResponse& response) { return dynamicDowncast<WebCore::AuthenticatorAssertionResponse>(response); }

} // namespace fido

#endif // ENABLE(WEB_AUTHN)
