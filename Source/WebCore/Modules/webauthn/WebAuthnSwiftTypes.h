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
#include <WebCore/AuthenticatorGetInfoResponse.h>
#include <WebCore/BufferSource.h>
#include <WebCore/CBORBytes.h>
#include <WebCore/CryptoKeyAES.h>
#include <WebCore/CryptoKeyEC.h>
#include <WebCore/CryptoKeyHMAC.h>
#include <WebCore/DeviceRequestConverter.h>
#include <WebCore/DeviceResponseConverter.h>
#include <WebCore/FidoHidMessage.h>
#include <WebCore/FidoHidPacket.h>
#include <WebCore/Pin.h>
#include <WebCore/PublicKeyCredentialCreationOptions.h>
#include <WebCore/PublicKeyCredentialRequestOptions.h>
#include <WebCore/U2fCommandConstructor.h>
#include <WebCore/U2fResponseConverter.h>
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

} // namespace fido

#endif // ENABLE(WEB_AUTHN)
