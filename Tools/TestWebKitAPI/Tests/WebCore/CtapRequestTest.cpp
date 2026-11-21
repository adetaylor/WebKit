// Copyright 2017 The Chromium Authors. All rights reserved.
// Copyright (C) 2018-2021 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"

#if ENABLE(WEB_AUTHN)

#include "CBORTestUtilities.h"
#include "FidoTestData.h"
#include "Helpers/PlatformUtilities.h"
#include <WebCore/AuthenticationExtensionsClientInputs.h>
#include <WebCore/AuthenticatorAttachment.h>
#include <WebCore/AuthenticatorSelectionCriteria.h>
#include <WebCore/DeviceRequestConverter.h>
#include <WebCore/FidoConstants.h>
#include <WebCore/Pin.h>
#include <WebCore/PublicKeyCredentialCreationOptions.h>
#include <WebCore/PublicKeyCredentialRequestOptions.h>
#include <wtf/text/Base64.h>

namespace TestWebKitAPI {
using namespace WebCore;
using namespace fido;

static PublicKeyCredentialRpEntity testRp()
{
    return PublicKeyCredentialRpEntity {
        PublicKeyCredentialEntity { "Acme"_s, { } },
        "acme.com"_s
    };
}

static PublicKeyCredentialUserEntity testUser()
{
    return PublicKeyCredentialUserEntity {
        PublicKeyCredentialEntity { "johnpsmith@example.com"_s, "https://pics.acme.com/00/p/aBjjjpqPb.png"_s },
        WebCore::toBufferSource(TestData::kUserId),
        "John P. Smith"_s
    };
}

static BufferSource testChallenge()
{
    return BufferSource { JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1) };
}

static PublicKeyCredentialRequestOptions testRequestOptions()
{
    return PublicKeyCredentialRequestOptions {
        .challenge = testChallenge(),
        .timeout = { },
        .rpId = "acme.com"_s,
        .allowCredentials = { },
        .userVerification = UserVerificationRequirement::Preferred,
        .extensions = { },
        .authenticatorAttachment = { },
    };
}

// Leveraging example 2 of section 6.1 of the spec
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html
TEST(CTAPRequestTest, TestConstructMakeCredentialRequestParam)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    WebCore::AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, true, UserVerificationRequirement::Preferred };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequest));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequest }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestParamNoUVNoRK)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, false, UserVerificationRequirement::Discouraged };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestShort }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestParamUVRequiredButNotSupported)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, false, UserVerificationRequirement::Required };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestShort }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestParamWithPin)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, true, UserVerificationRequirement::Preferred };

    PinParameters pin;
    pin.protocol = pin::kProtocolVersion;
    pin.auth.append(std::span { TestData::kCtap2PinAuth });

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions, pin);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestWithPin));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestWithPin }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestRKPreferred)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, ResidentKeyRequirement::Preferred, true, UserVerificationRequirement::Preferred };

    PinParameters pin;
    pin.protocol = pin::kProtocolVersion;
    pin.auth.append(std::span { TestData::kCtap2PinAuth });

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions, pin);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestWithPin));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestWithPin }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestRKPreferredNotSupported)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, ResidentKeyRequirement::Preferred, true, UserVerificationRequirement::Required };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kNotSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestShort }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestRKDiscouraged)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, ResidentKeyRequirement::Discouraged, true, UserVerificationRequirement::Required };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, std::nullopt };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestShort }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestWithLargeBlob)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, false, UserVerificationRequirement::Discouraged };
    AuthenticationExtensionsClientInputs extensionInputs = {
        .appid = WTF::nullString(),
        .credProps = false,
        .largeBlob = AuthenticationExtensionsClientInputs::LargeBlobInputs {
            .support = "required"_s,
            .read = std::nullopt,
            .write = std::nullopt,
        },
        .prf = std::nullopt,
    };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, extensionInputs };
    Vector<uint8_t> hash;
    Vector<String> extensions = { "largeBlob"_s };
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestShortWithLargeBlob));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestShortWithLargeBlob }));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestWithUnsupportedLargeBlob)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, false, UserVerificationRequirement::Discouraged };
    AuthenticationExtensionsClientInputs extensionInputs = {
        .appid = WTF::nullString(),
        .credProps = false,
        .largeBlob = AuthenticationExtensionsClientInputs::LargeBlobInputs {
            .support = "required"_s,
            .read = std::nullopt,
            .write = std::nullopt,
        },
        .prf = std::nullopt,
    };

    PublicKeyCredentialCreationOptions options { testRp(), testUser(), testChallenge(), params, std::nullopt, { }, selection, AttestationConveyancePreference::None, extensionInputs };
    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeMakeCredentialRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.authenticatorSelection->userVerification, AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kCtapMakeCredentialRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kCtapMakeCredentialRequestShort }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequest)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);

    options.userVerification = UserVerificationRequirement::Required;

    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.userVerification, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequest));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequest }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestNoUV)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);

    options.userVerification = UserVerificationRequirement::Discouraged;

    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.userVerification, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequestShort }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestUVRequiredButNotSupported)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);

    options.userVerification = UserVerificationRequirement::Required;

    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, options.userVerification, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequestShort));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequestShort }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestWithPin)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);

    options.userVerification = UserVerificationRequirement::Required;

    PinParameters pin;
    pin.protocol = pin::kProtocolVersion;
    pin.auth.append(std::span { TestData::kCtap2PinAuth });

    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.userVerification, extensions, pin);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequestWithPin));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequestWithPin }));
}

TEST(CTAPRequestTest, TestConstructCtapAuthenticatorRequestParam)
{
    static constexpr uint8_t kSerializedGetInfoCmd = 0x04;
    static constexpr uint8_t kSerializedGetNextAssertionCmd = 0x08;
    static constexpr uint8_t kSerializedResetCmd = 0x07;

    auto serializedData1 = encodeEmptyAuthenticatorRequest(CtapRequestCommand::kAuthenticatorGetInfo);
    EXPECT_EQ(serializedData1.size(), 1u);
    EXPECT_TRUE(equalSpans(serializedData1.span(), singleElementSpan(kSerializedGetInfoCmd)));

    auto serializedData2 = encodeEmptyAuthenticatorRequest(CtapRequestCommand::kAuthenticatorGetNextAssertion);
    EXPECT_EQ(serializedData2.size(), 1u);
    EXPECT_TRUE(equalSpans(serializedData2.span(), singleElementSpan(kSerializedGetNextAssertionCmd)));

    auto serializedData3 = encodeEmptyAuthenticatorRequest(CtapRequestCommand::kAuthenticatorReset);
    EXPECT_EQ(serializedData3.size(), 1u);
    EXPECT_TRUE(equalSpans(serializedData3.span(), singleElementSpan(kSerializedResetCmd)));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestLargeBlobRead)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);
    options.extensions = AuthenticationExtensionsClientInputs {
        .appid = WTF::nullString(),
        .credProps = false,
        .largeBlob = AuthenticationExtensionsClientInputs::LargeBlobInputs {
            .support = WTF::nullString(),
            .read = true,
            .write = std::nullopt,
        },
        .prf = std::nullopt,
    };

    options.userVerification = UserVerificationRequirement::Required;

    Vector<uint8_t> hash;
    Vector<String> extensions = { "largeBlob"_s };
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.userVerification, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequestWithLargeBlobRead));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequestWithLargeBlobRead }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestUnsupportedLargeBlobRead)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);
    options.extensions = AuthenticationExtensionsClientInputs {
        .appid = WTF::nullString(),
        .credProps = false,
        .largeBlob = AuthenticationExtensionsClientInputs::LargeBlobInputs {
            .support = WTF::nullString(),
            .read = true,
            .write = std::nullopt,
        },
        .prf = std::nullopt,
    };

    options.userVerification = UserVerificationRequirement::Required;

    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.userVerification, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequest));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequest }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestLargeBlobWrite)
{
    auto options = testRequestOptions();

    const uint8_t id1[] = {
        0xf2, 0x20, 0x06, 0xde, 0x4f, 0x90, 0x5a, 0xf6, 0x8a, 0x43, 0x94,
        0x2f, 0x02, 0x4f, 0x2a, 0x5e, 0xce, 0x60, 0x3d, 0x9c, 0x6d, 0x4b,
        0x3d, 0xf8, 0xbe, 0x08, 0xed, 0x01, 0xfc, 0x44, 0x26, 0x46, 0xd0,
        0x34, 0x85, 0x8a, 0xc7, 0x5b, 0xed, 0x3f, 0xd5, 0x80, 0xbf, 0x98,
        0x08, 0xd9, 0x4f, 0xcb, 0xee, 0x82, 0xb9, 0xb2, 0xef, 0x66, 0x77,
        0xaf, 0x0a, 0xdc, 0xc3, 0x58, 0x52, 0xea, 0x6b, 0x9e };
    auto descriptor1 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id1),
        .transports = { },
    };
    options.allowCredentials.append(descriptor1);

    const uint8_t id2[] = {
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03 };
    auto descriptor2 = PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id2),
        .transports = { },
    };
    options.allowCredentials.append(descriptor2);

    const uint8_t blob[] = {
        0xAB, 0xCD, 0xEF
    };
    options.extensions = AuthenticationExtensionsClientInputs {
        .appid = WTF::nullString(),
        .credProps = false,
        .largeBlob = AuthenticationExtensionsClientInputs::LargeBlobInputs {
            .support = WTF::nullString(),
            .read = std::nullopt,
            .write = WebCore::toBufferSource(blob),
        },
        .prf = std::nullopt,
    };

    options.userVerification = UserVerificationRequirement::Required;

    Vector<uint8_t> hash;
    Vector<String> extensions;
    hash.append(std::span { TestData::kClientDataHash });
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, options.userVerification, extensions);
    EXPECT_EQ(serializedData.size(), sizeof(TestData::kTestComplexCtapGetAssertionRequest));
    EXPECT_TRUE(equalSpans(serializedData.span(), std::span { TestData::kTestComplexCtapGetAssertionRequest }));
}

TEST(CTAPRequestTest, TestConstructGetAssertionRequestWithHmacSecret)
{
    auto options = testRequestOptions();

    // Create hmac-secret extension inputs (two 32-byte salts)
    const uint8_t salt1Data[32] = { 0x00 }; // 32 bytes of zeros
    const uint8_t salt2Data[32] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

    AuthenticationExtensionsClientInputs extensions;
    AuthenticationExtensionsClientInputs::PRFInputs prfInputs;
    prfInputs.eval = AuthenticationExtensionsClientInputs::PRFValues {
        WebCore::toBufferSource(salt1Data),
        WebCore::toBufferSource(salt2Data),
    };
    extensions.prf = WTF::move(prfInputs);

    options.extensions = extensions;

    Vector<uint8_t> hash;
    Vector<String> supportedExtensions { "hmac-secret"_s };
    hash.append(std::span { TestData::kClientDataHash });

    // Note: This will encode without HmacSecretParameters since that requires key agreement
    // The full flow with HmacSecretParameters is tested separately
    auto serializedData = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedButNotConfigured, options.userVerification, supportedExtensions);

    // Verify the request was encoded successfully
    EXPECT_FALSE(serializedData.isEmpty());
    EXPECT_EQ(serializedData[0], static_cast<uint8_t>(CtapRequestCommand::kAuthenticatorGetAssertion));
}

static PublicKeyCredentialDescriptor testDescriptor(size_t idLength)
{
    Vector<uint8_t> id(FillWith { }, idLength, 0x5c);
    return PublicKeyCredentialDescriptor { PublicKeyCredentialType::PublicKey, WebCore::toBufferSource(id.span()), { } };
}

static PublicKeyCredentialCreationOptions testCreationOptions(PublicKeyCredentialUserEntity user, Vector<PublicKeyCredentialDescriptor> excludeCredentials)
{
    Vector<PublicKeyCredentialParameters> params { { PublicKeyCredentialType::PublicKey, -7 } };
    return PublicKeyCredentialCreationOptions { testRp(), WTF::move(user), testChallenge(), params, std::nullopt, WTF::move(excludeCredentials), std::nullopt, AttestationConveyancePreference::None, std::nullopt };
}

// The encoded "id" of the first descriptor in the request's credential list under listKey.
static std::optional<std::span<const uint8_t>> firstDescriptorID(std::span<const uint8_t> request, int64_t listKey)
{
    auto list = cborMapLookup(request.subspan(1), cborInteger(listKey).span());
    if (!list)
        return std::nullopt;
    auto head = readCBORHead(*list);
    if (!head || head->majorType != 4 || !head->argument)
        return std::nullopt;
    return cborMapLookup(list->subspan(head->headLength), cborText("id"_s).span());
}

TEST(CTAPRequestTest, TestConstructRequestsWithCredentialIDLengths)
{
    Vector<uint8_t> hash;
    hash.append(std::span { TestData::kClientDataHash });
    // A credential ID of 65,535 bytes has a 3-byte head; one of 65,536 bytes needs 5.
    for (auto [length, headLength] : std::array { std::pair<size_t, size_t> { 65535, 3 }, std::pair<size_t, size_t> { 65536, 5 } }) {
        auto makeCredential = encodeMakeCredentialRequestAsCBOR(hash, testCreationOptions(testUser(), { testDescriptor(length) }), AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, UserVerificationRequirement::Discouraged, AuthenticatorSupportedOptions::ResidentKeyAvailability::kNotSupported, { });
        auto excluded = firstDescriptorID(makeCredential.span(), 5);
        ASSERT_TRUE(excluded);
        auto excludedHead = readCBORHead(*excluded);
        ASSERT_TRUE(excludedHead);
        EXPECT_EQ(excludedHead->majorType, 2);
        EXPECT_EQ(excludedHead->argument, length);
        EXPECT_EQ(excludedHead->headLength, headLength);
        EXPECT_EQ(excluded->size(), headLength + length);

        auto options = testRequestOptions();
        options.allowCredentials = { testDescriptor(length) };
        auto getAssertion = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, UserVerificationRequirement::Discouraged, { });
        auto allowed = firstDescriptorID(getAssertion.span(), 3);
        ASSERT_TRUE(allowed);
        auto allowedHead = readCBORHead(*allowed);
        ASSERT_TRUE(allowedHead);
        EXPECT_EQ(allowedHead->argument, length);
        EXPECT_EQ(allowedHead->headLength, headLength);
    }
}

TEST(CTAPRequestTest, TestConstructRequestsWithEmptyCredentialOverride)
{
    Vector<uint8_t> hash;
    hash.append(std::span { TestData::kClientDataHash });
    // An empty override replaces the options' list: makeCredential then has no exclude list, and getAssertion an empty
    // allow list.
    auto makeCredential = encodeMakeCredentialRequestAsCBOR(hash, testCreationOptions(testUser(), { testDescriptor(16) }), AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, UserVerificationRequirement::Discouraged, AuthenticatorSupportedOptions::ResidentKeyAvailability::kNotSupported, { }, std::nullopt, std::nullopt, Vector<PublicKeyCredentialDescriptor> { });
    EXPECT_FALSE(cborMapLookup(makeCredential.span().subspan(1), cborInteger(5).span()));

    auto options = testRequestOptions();
    options.allowCredentials = { testDescriptor(16) };
    auto getAssertion = encodeGetAssertionRequestAsCBOR(hash, options, AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, UserVerificationRequirement::Discouraged, { }, std::nullopt, Vector<PublicKeyCredentialDescriptor> { });
    auto allowed = cborMapLookup(getAssertion.span().subspan(1), cborInteger(3).span());
    ASSERT_TRUE(allowed);
    EXPECT_TRUE(std::ranges::equal(*allowed, cborArray({ }).span()));
}

TEST(CTAPRequestTest, TestConstructMakeCredentialRequestWithEmptyUserID)
{
    auto user = testUser();
    user.id = testChallenge();
    Vector<uint8_t> hash;
    hash.append(std::span { TestData::kClientDataHash });
    auto makeCredential = encodeMakeCredentialRequestAsCBOR(hash, testCreationOptions(WTF::move(user), { }), AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, UserVerificationRequirement::Discouraged, AuthenticatorSupportedOptions::ResidentKeyAvailability::kNotSupported, { });
    auto userMap = cborMapLookup(makeCredential.span().subspan(1), cborInteger(3).span());
    ASSERT_TRUE(userMap);
    auto id = cborMapLookup(*userMap, cborText("id"_s).span());
    ASSERT_TRUE(id);
    EXPECT_TRUE(std::ranges::equal(*id, cborBytes({ }).span()));
}

static CBORItem evalByCredentialCBOR(std::initializer_list<CBORMapEntry> entries)
{
    return cborMap({ { cborText("prf"_s), cborMap({ { cborText("evalByCredential"_s), cborMap(entries) } }) } });
}

static AuthenticationExtensionsClientInputs evalByCredentialInputs(std::initializer_list<std::pair<String, uint8_t>> entries)
{
    Vector<KeyValuePair<String, AuthenticationExtensionsClientInputs::PRFValues>> values;
    for (auto& entry : entries) {
        Vector<uint8_t> first(FillWith { }, 4, entry.second);
        values.append({ entry.first, AuthenticationExtensionsClientInputs::PRFValues { WebCore::toBufferSource(first.span()), std::nullopt } });
    }
    AuthenticationExtensionsClientInputs inputs;
    inputs.prf = AuthenticationExtensionsClientInputs::PRFInputs { std::nullopt, WTF::move(values) };
    return inputs;
}

static CBORItem firstValue(uint8_t byte)
{
    Vector<uint8_t> first(FillWith { }, 4, byte);
    return cborMap({ { cborText("first"_s), cborBytes(first.span()) } });
}

TEST(CTAPRequestTest, TestExtensionInputsEvalByCredentialKeys)
{
    auto utf16 = [](std::initializer_list<char16_t> units) {
        return String(std::span<const char16_t> { units.begin(), units.size() });
    };
    // Keys sort by their UTF-16 code units and are written as UTF-8, an unpaired surrogate as U+FFFD: two keys can then
    // be written alike.
    CBORItem replacement { 0x63, 0xef, 0xbf, 0xbd };
    auto surrogates = evalByCredentialCBOR({ { replacement, firstValue(1) }, { replacement, firstValue(2) } });
    EXPECT_EQ(evalByCredentialInputs({ { utf16({ 0xd800 }), 1 }, { utf16({ 0xdbff }), 2 } }).toCBOR(), surrogates);
    EXPECT_EQ(evalByCredentialInputs({ { utf16({ 0xdbff }), 2 }, { utf16({ 0xd800 }), 1 } }).toCBOR(), surrogates);

    // Equal keys keep the later value, whatever their string's width; the null key equals the empty one.
    EXPECT_EQ(evalByCredentialInputs({ { "a"_s, 1 }, { "b"_s, 2 }, { "a"_s, 3 } }).toCBOR(), evalByCredentialCBOR({ { cborText("a"_s), firstValue(3) }, { cborText("b"_s), firstValue(2) } }));
    EXPECT_EQ(evalByCredentialInputs({ { String::fromLatin1("\xE9"), 1 }, { utf16({ 0xe9 }), 2 } }).toCBOR(), evalByCredentialCBOR({ { CBORItem { 0x62, 0xc3, 0xa9 }, firstValue(2) } }));
    EXPECT_EQ(evalByCredentialInputs({ { String(), 1 }, { emptyString(), 2 } }).toCBOR(), evalByCredentialCBOR({ { cborText(emptyString()), firstValue(2) } }));
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
