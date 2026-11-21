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
#include <JavaScriptCore/ArrayBuffer.h>
#include <WebCore/AuthenticationExtensionsClientOutputs.h>
#include <WebCore/AuthenticatorAttachment.h>
#include <WebCore/AuthenticatorTransport.h>
#include <WebCore/BufferSource.h>
#include <WebCore/CBORBytes.h>
#include <WebCore/CredentialPropertiesOutput.h>
#include <WebCore/DeviceResponseConverter.h>
#include <WebCore/FidoConstants.h>
#include <WebCore/U2fResponseConverter.h>
#include <WebCore/WebAuthenticationUtils.h>

namespace TestWebKitAPI {
using namespace WebCore;
using namespace fido;

constexpr auto kTestAuthenticatorGetInfoResponseWithNoVersion = WTF::toArray<uint8_t>({
    // Success status byte
    0x00,
    // Map of 6 elements
    0xA6,
    // Key(01) - versions
    0x01,
    // Array(0)
    0x80,
    // Key(02) - extensions
    0x02,
    // Array(2)
    0x82,
    // "uvm"
    0x63, 0x75, 0x76, 0x6D,
    // "hmac-secret"
    0x6B, 0x68, 0x6D, 0x61, 0x63, 0x2D, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74,
    // Key(03) - AAGUID
    0x03,
    // Bytes(16)
    0x50, 0xF8, 0xA0, 0x11, 0xF3, 0x8C, 0x0A, 0x4D, 0x15, 0x80, 0x06, 0x17,
    0x11, 0x1F, 0x9E, 0xDC, 0x7D,
    // Key(04) - options
    0x04,
    // Map(05)
    0xA5,
    // Key - "rk"
    0x62, 0x72, 0x6B,
    // true
    0xF5,
    // Key - "up"
    0x62, 0x75, 0x70,
    // true
    0xF5,
    // Key - "uv"
    0x62, 0x75, 0x76,
    // true
    0xF5,
    // Key - "plat"
    0x64, 0x70, 0x6C, 0x61, 0x74,
    // true
    0xF5,
    // Key - "clientPin"
    0x69, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74, 0x50, 0x69, 0x6E,
    // false
    0xF4,
    // Key(05) - Max message size
    0x05,
    // 1200
    0x19, 0x04, 0xB0,
    // Key(06) - Pin protocols
    0x06,
    // Array[1]
    0x81, 0x01,
});

constexpr auto kTestAuthenticatorGetInfoResponseWithDuplicateVersion = WTF::toArray<uint8_t>({
    // Success status byte
    0x00,
    // Map of 6 elements
    0xA6,
    // Key(01) - versions
    0x01,
    // Array(02)
    0x82,
    // "U2F_V2"
    0x66, 0x55, 0x32, 0x46, 0x5F, 0x56, 0x32,
    // "U2F_V2"
    0x66, 0x55, 0x32, 0x46, 0x5F, 0x56, 0x32,
    // Key(02) - extensions
    0x02,
    // Array(2)
    0x82,
    // "uvm"
    0x63, 0x75, 0x76, 0x6D,
    // "hmac-secret"
    0x6B, 0x68, 0x6D, 0x61, 0x63, 0x2D, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74,
    // Key(03) - AAGUID
    0x03,
    // Bytes(16)
    0x50, 0xF8, 0xA0, 0x11, 0xF3, 0x8C, 0x0A, 0x4D, 0x15, 0x80, 0x06, 0x17,
    0x11, 0x1F, 0x9E, 0xDC, 0x7D,
    // Key(04) - options
    0x04,
    // Map(05)
    0xA5,
    // Key - "rk"
    0x62, 0x72, 0x6B,
    // true
    0xF5,
    // Key - "up"
    0x62, 0x75, 0x70,
    // true
    0xF5,
    // Key - "uv"
    0x62, 0x75, 0x76,
    // true
    0xF5,
    // Key - "plat"
    0x64, 0x70, 0x6C, 0x61, 0x74,
    // true
    0xF5,
    // Key - "clientPin"
    0x69, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74, 0x50, 0x69, 0x6E,
    // false
    0xF4,
    // Key(05) - Max message size
    0x05,
    // 1200
    0x19, 0x04, 0xB0,
    // Key(06) - Pin protocols
    0x06,
    // Array[1]
    0x81, 0x01,
});

constexpr auto kTestAuthenticatorGetInfoResponseWithIncorrectAaguid = WTF::toArray<uint8_t>({
    // Success status byte
    0x00,
    // Map of 6 elements
    0xA6,
    // Key(01) - versions
    0x01,
    // Array(01)
    0x81,
    // "U2F_V2"
    0x66, 0x55, 0x32, 0x46, 0x5F, 0x56, 0x32,
    // Key(02) - extensions
    0x02,
    // Array(2)
    0x82,
    // "uvm"
    0x63, 0x75, 0x76, 0x6D,
    // "hmac-secret"
    0x6B, 0x68, 0x6D, 0x61, 0x63, 0x2D, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74,
    // Key(03) - AAGUID
    0x03,
    // Bytes(17) - FIDO2 device AAGUID must be 16 bytes long in order to be
    // correct.
    0x51, 0xF8, 0xA0, 0x11, 0xF3, 0x8C, 0x0A, 0x4D, 0x15, 0x80, 0x06, 0x17,
    0x11, 0x1F, 0x9E, 0xDC, 0x7D, 0x00,
    // Key(04) - options
    0x04,
    // Map(05)
    0xA5,
    // Key - "rk"
    0x62, 0x72, 0x6B,
    // true
    0xF5,
    // Key - "up"
    0x62, 0x75, 0x70,
    // true
    0xF5,
    // Key - "uv"
    0x62, 0x75, 0x76,
    // true
    0xF5,
    // Key - "plat"
    0x64, 0x70, 0x6C, 0x61, 0x74,
    // true
    0xF5,
    // Key - "clientPin"
    0x69, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74, 0x50, 0x69, 0x6E,
    // false
    0xF4,
    // Key(05) - Max message size
    0x05,
    // 1200
    0x19, 0x04, 0xB0,
    // Key(06) - Pin protocols
    0x06,
    // Array[1]
    0x81, 0x01,
});

// The attested credential data, excluding the public key bytes. Append
// with kTestECPublicKeyCOSE to get the complete attestation data.
constexpr auto kTestAttestedCredentialDataPrefix = WTF::toArray<uint8_t>({
    // 16-byte aaguid
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    // 2-byte length
    0x00, 0x40,
    // 64-byte key handle
    0x3E, 0xBD, 0x89, 0xBF, 0x77, 0xEC, 0x50, 0x97, 0x55, 0xEE, 0x9C, 0x26,
    0x35, 0xEF, 0xAA, 0xAC, 0x7B, 0x2B, 0x9C, 0x5C, 0xEF, 0x17, 0x36, 0xC3,
    0x71, 0x7D, 0xA4, 0x85, 0x34, 0xC8, 0xC6, 0xB6, 0x54, 0xD7, 0xFF, 0x94,
    0x5F, 0x50, 0xB5, 0xCC, 0x4E, 0x78, 0x05, 0x5B, 0xDD, 0x39, 0x6B, 0x64,
    0xF7, 0x8D, 0xA2, 0xC5, 0xF9, 0x62, 0x00, 0xCC, 0xD4, 0x15, 0xCD, 0x08,
    0xFE, 0x42, 0x00, 0x38,
});

// The authenticator data, excluding the attested credential data bytes. Append
// with attested credential data to get the complete authenticator data.
constexpr auto kTestAuthenticatorDataPrefix = WTF::toArray<uint8_t>({
    // sha256 hash of rp id.
    0x11, 0x94, 0x22, 0x8D, 0xA8, 0xFD, 0xBD, 0xEE, 0xFD, 0x26, 0x1B, 0xD7,
    0xB6, 0x59, 0x5C, 0xFD, 0x70, 0xA5, 0x0D, 0x70, 0xC6, 0x40, 0x7B, 0xCF,
    0x01, 0x3D, 0xE9, 0x6D, 0x4E, 0xFB, 0x17, 0xDE,
    // flags (TUP and AT bits set)
    0x41,
    // counter
    0x00, 0x00, 0x00, 0x00
});

// Components of the CBOR needed to form an authenticator object.
// Combined diagnostic notation:
// {"fmt": "fido-u2f", "attStmt": {"sig": h'30...}, "authData": h'D4C9D9...'}
constexpr auto kFormatFidoU2fCBOR = WTF::toArray<uint8_t>({
    // map(3)
    0xA3,
    // text(3)
    0x63,
    // "fmt"
    0x66, 0x6D, 0x74,
    // text(8)
    0x68,
    // "fido-u2f"
    0x66, 0x69, 0x64, 0x6F, 0x2D, 0x75, 0x32, 0x66
});

constexpr auto kAttStmtCBOR = WTF::toArray<uint8_t>({
    // text(7)
    0x67,
    // "attStmt"
    0x61, 0x74, 0x74, 0x53, 0x74, 0x6D, 0x74
});

constexpr auto kAuthDataCBOR = WTF::toArray<uint8_t>({
    // text(8)
    0x68,
    // "authData"
    0x61, 0x75, 0x74, 0x68, 0x44, 0x61, 0x74, 0x61,
    // bytes(196). i.e., the authenticator_data byte array corresponding to
    // kTestAuthenticatorDataPrefix|, |kTestAttestedCredentialDataPrefix|,
    // and test_data::kTestECPublicKeyCOSE.
    0x58, 0xC4
});

constexpr auto kTestDeviceAaguid = WTF::toArray<uint8_t>({
    0xF8, 0xA0, 0x11, 0xF3, 0x8C, 0x0A, 0x4D, 0x15, 0x80, 0x06, 0x17, 0x11, 0x1F, 0x9E, 0xDC, 0x7D
});

Vector<uint8_t> getTestAttestedCredentialDataBytes()
{
    // Combine kTestAttestedCredentialDataPrefix and kTestECPublicKeyCOSE.
    Vector<uint8_t> testAttestedData { kTestAttestedCredentialDataPrefix };
    testAttestedData.append(std::span { TestData::kTestECPublicKeyCOSE });
    return testAttestedData;
}

Vector<uint8_t> getTestAuthenticatorDataBytes()
{
    // Build the test authenticator data.
    Vector<uint8_t> testAuthenticatorData { kTestAuthenticatorDataPrefix };
    auto testAttestedData = getTestAttestedCredentialDataBytes();
    testAuthenticatorData.appendVector(testAttestedData);
    return testAuthenticatorData;
}

Vector<uint8_t> getTestAttestationObjectBytes()
{
    Vector<uint8_t> testAuthenticatorObject { kFormatFidoU2fCBOR };
    testAuthenticatorObject.append(std::span { kAttStmtCBOR });
    testAuthenticatorObject.append(std::span { TestData::kU2fAttestationStatementCBOR });
    testAuthenticatorObject.append(std::span { kAuthDataCBOR });
    auto testAuthenticatorData = getTestAuthenticatorDataBytes();
    testAuthenticatorObject.appendVector(testAuthenticatorData);
    return testAuthenticatorObject;
}

Vector<uint8_t> getTestSignResponse()
{
    return std::span { TestData::kTestU2fSignResponse };
}

// Get a subset of the response for testing error handling.
Vector<uint8_t> getTestCorruptedSignResponse(size_t length)
{
    ASSERT(length < sizeof(TestData::kTestU2fSignResponse));
    Vector<uint8_t> testCorruptedSignResponse(ReserveCapacityTag { }, length);
    testCorruptedSignResponse.append(std::span { TestData::kTestU2fSignResponse }.first(length));
    return testCorruptedSignResponse;
}

// Return a key handle used for GetAssertion request.
BufferSource getTestCredentialRawIdBytes()
{
    return WebCore::toBufferSource(TestData::kU2fSignKeyHandle);
}

// Return a malformed U2fRegisterResponse.
Vector<uint8_t> getTestU2fRegisterResponse(size_t prefixSize, const uint8_t appendix[], size_t appendixSize)
{
    Vector<uint8_t> result(ReserveCapacityTag { }, prefixSize + appendixSize);
    result.append(std::span { TestData::kTestU2fRegisterResponse }.first(prefixSize));
    result.append(std::span { appendix, appendixSize });
    return result;
}

// Leveraging example 4 of section 6.1 of the spec
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html#commands
TEST(CTAPResponseTest, TestReadMakeCredentialResponse)
{
    auto makeCredentialResponse = readCTAPMakeCredentialResponse(std::span { TestData::kTestMakeCredentialResponse }, AuthenticatorAttachment::CrossPlatform, { });
    ASSERT_TRUE(makeCredentialResponse);
    auto attestationObjectBytes = makeCredentialResponse->attestationObject().toVector();
    auto attestationObject = cbor::readCanonical(attestationObjectBytes.span());
    ASSERT_TRUE(attestationObject.error == cbor::DecoderError::CBORNoError);
    ASSERT_TRUE(isCBORMap(attestationObject.canonical.span()));

    auto expectBytesEqual = [](std::optional<std::span<const uint8_t>> actual, const CBORItem& expected) {
        ASSERT_TRUE(actual.has_value());
        EXPECT_TRUE(std::ranges::equal(*actual, expected.span()));
    };

    auto key = [](const String& name) {
        return cborText(name);
    };

    expectBytesEqual(cborMapLookup(attestationObject.canonical.span(), key(kFormatKey).span()), cborText("packed"_s));
    expectBytesEqual(cborMapLookup(attestationObject.canonical.span(), key(kAuthDataKey).span()), cborBytes(std::span { TestData::kCtap2MakeCredentialAuthData }));

    auto attestationStatement = cborMapLookup(attestationObject.canonical.span(), key(kAttestationStatementKey).span());
    ASSERT_TRUE(attestationStatement.has_value());
    ASSERT_TRUE(isCBORMap(*attestationStatement));

    expectBytesEqual(cborMapLookup(*attestationStatement, key("alg"_s).span()), cborInteger(-7));
    expectBytesEqual(cborMapLookup(*attestationStatement, key("sig"_s).span()), cborBytes(std::span { TestData::kCtap2MakeCredentialSignature }));
    expectBytesEqual(cborMapLookup(*attestationStatement, key("x5c"_s).span()), cborArray({ cborBytes(std::span { TestData::kCtap2MakeCredentialCertificate }) }));
    EXPECT_EQ(makeCredentialResponse->rawId().byteLength(), sizeof(TestData::kCtap2MakeCredentialCredentialId));
    EXPECT_TRUE(equalSpans(makeCredentialResponse->rawId().span(), std::span { TestData::kCtap2MakeCredentialCredentialId }));
}

// Leveraging example 5 of section 6.1 of the CTAP spec.
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html
TEST(CTAPResponseTest, TestReadGetAssertionResponse1)
{
    auto getAssertionResponse = readCTAPGetAssertionResponse(std::span { TestData::kDeviceGetAssertionResponseShort }, AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(getAssertionResponse);

    EXPECT_EQ(getAssertionResponse->authenticatorData()->byteLength(), sizeof(TestData::kCtap2GetAssertionAuthData));
    EXPECT_TRUE(equalSpans(getAssertionResponse->authenticatorData()->span(), std::span { TestData::kCtap2GetAssertionAuthData }));
    EXPECT_EQ(getAssertionResponse->signature()->byteLength(), sizeof(TestData::kCtap2GetAssertionSignature));
    EXPECT_TRUE(equalSpans(getAssertionResponse->signature()->span(), std::span { TestData::kCtap2GetAssertionSignature }));
}

TEST(CTAPResponseTest, TestReadGetAssertionResponse2)
{
    auto getAssertionResponse = readCTAPGetAssertionResponse(std::span { TestData::kDeviceGetAssertionResponse }, AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(getAssertionResponse);

    EXPECT_EQ(getAssertionResponse->authenticatorData()->byteLength(), sizeof(TestData::kCtap2GetAssertionAuthData));
    EXPECT_TRUE(equalSpans(getAssertionResponse->authenticatorData()->span(), std::span { TestData::kCtap2GetAssertionAuthData }));
    EXPECT_EQ(getAssertionResponse->signature()->byteLength(), sizeof(TestData::kCtap2GetAssertionSignature));
    EXPECT_TRUE(equalSpans(getAssertionResponse->signature()->span(), std::span { TestData::kCtap2GetAssertionSignature }));
    EXPECT_EQ(getAssertionResponse->userHandle()->byteLength(), sizeof(TestData::kCtap2GetAssertionUserHandle));
    EXPECT_TRUE(equalSpans(getAssertionResponse->userHandle()->span(), std::span { TestData::kCtap2GetAssertionUserHandle }));
}

TEST(CTAPResponseTest, TestReadGetAssertionResponse3)
{
    auto getAssertionResponse = readCTAPGetAssertionResponse(std::span { TestData::kDeviceGetAssertionResponseLong }, AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(getAssertionResponse);

    EXPECT_EQ(getAssertionResponse->authenticatorData()->byteLength(), sizeof(TestData::kCtap2GetAssertionAuthData));
    EXPECT_TRUE(equalSpans(getAssertionResponse->authenticatorData()->span(), std::span { TestData::kCtap2GetAssertionAuthData }));
    EXPECT_EQ(getAssertionResponse->signature()->byteLength(), sizeof(TestData::kCtap2GetAssertionSignature));
    EXPECT_TRUE(equalSpans(getAssertionResponse->signature()->span(), std::span { TestData::kCtap2GetAssertionSignature }));
    EXPECT_EQ(getAssertionResponse->userHandle()->byteLength(), sizeof(TestData::kCtap2GetAssertionUserHandle));
    EXPECT_TRUE(equalSpans(getAssertionResponse->userHandle()->span(), std::span { TestData::kCtap2GetAssertionUserHandle }));
    EXPECT_EQ(getAssertionResponse->name(), "johnpsmith@example.com"_s);
    EXPECT_EQ(getAssertionResponse->displayName(), "John P. Smith"_s);
    EXPECT_EQ(getAssertionResponse->numberOfCredentials(), 1u);
}

// Test that U2F register response is properly parsed.
TEST(CTAPResponseTest, TestParseRegisterResponseData)
{
    auto response = readU2fRegisterResponse(TestData::kRelyingPartyId, std::span { TestData::kTestU2fRegisterResponse }, AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(response);
    EXPECT_EQ(response->rawId().byteLength(), sizeof(TestData::kU2fSignKeyHandle));
    EXPECT_TRUE(equalSpans(response->rawId().span(), std::span { TestData::kU2fSignKeyHandle }));
    auto expectedAttestationObject = getTestAttestationObjectBytes();
    EXPECT_EQ(response->attestationObject().byteLength(), expectedAttestationObject.size());
    EXPECT_TRUE(equalSpans(response->attestationObject().span(), expectedAttestationObject.span()));
}

// Test malformed user public key.
TEST(CTAPResponseTest, TestParseIncorrectRegisterResponseData1)
{
    const uint8_t testData1[] = { 0x05 };
    auto response = readU2fRegisterResponse(TestData::kRelyingPartyId, std::span { testData1 }, AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData2[] = { 0x05, 0x00 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, std::span { testData2 }, AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData3[] = { 0x05, 0x04, 0x00 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, std::span { testData3 }, AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

// Test malformed key handle.
TEST(CTAPResponseTest, TestParseIncorrectRegisterResponseData2)
{
    auto response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(kU2fKeyHandleLengthOffset, nullptr, 0), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData[] = { 0x40 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(kU2fKeyHandleLengthOffset, testData, sizeof(testData)), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

// Test malformed X.509.
TEST(CTAPResponseTest, TestParseIncorrectRegisterResponseData3)
{
    const auto prefix = kU2fKeyHandleOffset + 64;
    auto response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix, nullptr, 0), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData1[] = { 0x40 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix, testData1, sizeof(testData1)), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData2[] = { 0x30 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix, testData2, sizeof(testData2)), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData3[] = { 0x30, 0x82 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix, testData3, sizeof(testData3)), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData4[] = { 0x30, 0xC1 };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix, testData4, sizeof(testData4)), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);

    const uint8_t testData5[] = { 0x30, 0x82, 0x02, 0x4A };
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix, testData5, sizeof(testData5)), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

// Test malformed signature.
TEST(CTAPResponseTest, TestParseIncorrectRegisterResponseData4)
{
    const auto prefix = sizeof(TestData::kTestU2fRegisterResponse);
    auto response = readU2fRegisterResponse(TestData::kRelyingPartyId, getTestU2fRegisterResponse(prefix - 71, nullptr, 0), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

// Test malformed X.509 but pass.
TEST(CTAPResponseTest, TestParseIncorrectRegisterResponseData5)
{
    const auto prefix = kU2fKeyHandleOffset + 64;
    const auto signatureSize = 71;
    const auto suffix = sizeof(TestData::kTestU2fRegisterResponse) - signatureSize;

    Vector<uint8_t> testData1;
    testData1.append(std::span { TestData::kTestU2fRegisterResponse }.first(prefix));
    testData1.append(0x30);
    testData1.append(0x01);
    testData1.append(0x00);
    testData1.append(std::span { TestData::kTestU2fRegisterResponse }.subspan(suffix, signatureSize));
    auto response = readU2fRegisterResponse(TestData::kRelyingPartyId, testData1, AuthenticatorAttachment::CrossPlatform);
    EXPECT_TRUE(response);

    Vector<uint8_t> testData2;
    testData2.append(std::span { TestData::kTestU2fRegisterResponse }.first(prefix));
    testData2.append(0x30);
    testData2.append(0x81);
    testData2.append(0x01);
    testData2.append(0x00);
    testData2.append(std::span { TestData::kTestU2fRegisterResponse }.subspan(suffix, signatureSize));
    response = readU2fRegisterResponse(TestData::kRelyingPartyId, testData2, AuthenticatorAttachment::CrossPlatform);
    EXPECT_TRUE(response);
}

// Tests that U2F authenticator data is properly serialized.
TEST(CTAPResponseTest, TestParseSignResponseData)
{
    auto response = readU2fSignResponse(TestData::kRelyingPartyId, getTestCredentialRawIdBytes(), getTestSignResponse(), AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(response);
    EXPECT_EQ(response->rawId().byteLength(), sizeof(TestData::kU2fSignKeyHandle));
    EXPECT_TRUE(equalSpans(response->rawId().span(), std::span { TestData::kU2fSignKeyHandle }));
    EXPECT_EQ(response->authenticatorData()->byteLength(), sizeof(TestData::kTestSignAuthenticatorData));
    EXPECT_TRUE(equalSpans(response->authenticatorData()->span(), std::span { TestData::kTestSignAuthenticatorData }));
    EXPECT_EQ(response->signature()->byteLength(), sizeof(TestData::kU2fSignature));
    EXPECT_TRUE(equalSpans(response->signature()->span(), std::span { TestData::kU2fSignature }));
}

TEST(CTAPResponseTest, TestParseU2fSignWithNullKeyHandle)
{
    auto response = readU2fSignResponse(TestData::kRelyingPartyId, JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1), getTestSignResponse(), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

TEST(CTAPResponseTest, TestParseU2fSignWithNullResponse)
{
    auto response = readU2fSignResponse(TestData::kRelyingPartyId, getTestCredentialRawIdBytes(), Vector<uint8_t>(), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

TEST(CTAPResponseTest, TestParseU2fSignWithCorruptedCounter)
{
    // A sign response of less than 5 bytes.
    auto response = readU2fSignResponse(TestData::kRelyingPartyId, getTestCredentialRawIdBytes(), getTestCorruptedSignResponse(3), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

TEST(CTAPResponseTest, TestParseU2fSignWithCorruptedSignature)
{
    // A sign response no more than 5 bytes.
    auto response = readU2fSignResponse(TestData::kRelyingPartyId, getTestCredentialRawIdBytes(), getTestCorruptedSignResponse(5), AuthenticatorAttachment::CrossPlatform);
    EXPECT_FALSE(response);
}

TEST(CTAPResponseTest, TestReadGetInfoResponse)
{
    auto getInfoResponse = readCTAPGetInfoResponse(std::span { TestData::kTestGetInfoResponsePlatformDevice });
    ASSERT_TRUE(getInfoResponse);
    ASSERT_TRUE(getInfoResponse->maxMsgSize());
    EXPECT_EQ(*getInfoResponse->maxMsgSize(), 1200u);
    EXPECT_NE(getInfoResponse->versions().find(ProtocolVersion::kCtap2), getInfoResponse->versions().end());
    EXPECT_NE(getInfoResponse->versions().find(ProtocolVersion::kU2f), getInfoResponse->versions().end());
    EXPECT_TRUE(getInfoResponse->options().isPlatformDevice());
    EXPECT_EQ(AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, getInfoResponse->options().residentKeyAvailability());
    EXPECT_TRUE(getInfoResponse->options().userPresenceRequired());
    EXPECT_EQ(AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, getInfoResponse->options().userVerificationAvailability());
    EXPECT_EQ(AuthenticatorSupportedOptions::ClientPinAvailability::kSupportedButPinNotSet, getInfoResponse->options().clientPinAvailability());
}

TEST(CTAPResponseTest, TestReadGetInfoResponse2)
{
    auto getInfoResponse = readCTAPGetInfoResponse(std::span { TestData::kTestGetInfoResponsePlatformDevice2 });
    ASSERT_TRUE(getInfoResponse);
    ASSERT_TRUE(getInfoResponse->maxMsgSize());
    EXPECT_EQ(*getInfoResponse->maxMsgSize(), 1200u);
    EXPECT_NE(getInfoResponse->versions().find(ProtocolVersion::kCtap2), getInfoResponse->versions().end());
    EXPECT_NE(getInfoResponse->versions().find(ProtocolVersion::kU2f), getInfoResponse->versions().end());
    EXPECT_TRUE(getInfoResponse->options().isPlatformDevice());
    EXPECT_EQ(AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, getInfoResponse->options().residentKeyAvailability());
    EXPECT_TRUE(getInfoResponse->options().userPresenceRequired());
    EXPECT_EQ(AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured, getInfoResponse->options().userVerificationAvailability());
    EXPECT_EQ(AuthenticatorSupportedOptions::ClientPinAvailability::kSupportedButPinNotSet, getInfoResponse->options().clientPinAvailability());
}

TEST(CTAPResponseTest, TestReadGetInfoResponseDeviceYubikey5c)
{
    auto getInfoResponse = readCTAPGetInfoResponse(std::span { TestData::kTestGetInfoResponseDeviceYubikey5c });
    ASSERT_TRUE(getInfoResponse);
    ASSERT_TRUE(getInfoResponse->maxMsgSize());
    EXPECT_EQ(*getInfoResponse->maxMsgSize(), 1200u);
    EXPECT_NE(getInfoResponse->versions().find(ProtocolVersion::kCtap2), getInfoResponse->versions().end());
    EXPECT_NE(getInfoResponse->versions().find(ProtocolVersion::kU2f), getInfoResponse->versions().end());
    EXPECT_FALSE(getInfoResponse->options().isPlatformDevice());
    EXPECT_EQ(AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported, getInfoResponse->options().residentKeyAvailability());
    EXPECT_TRUE(getInfoResponse->options().userPresenceRequired());
    EXPECT_EQ(AuthenticatorSupportedOptions::UserVerificationAvailability::kNotSupported, getInfoResponse->options().userVerificationAvailability());
    EXPECT_EQ(AuthenticatorSupportedOptions::ClientPinAvailability::kSupportedAndPinSet, getInfoResponse->options().clientPinAvailability());
    EXPECT_TRUE(getInfoResponse->transports());
    EXPECT_EQ(getInfoResponse->transports()->size(), 1u);
    EXPECT_EQ(AuthenticatorTransport::Usb, getInfoResponse->transports()->first());
}

TEST(CTAPResponseTest, TestReadGetInfoResponseWithIncorrectFormat)
{
    EXPECT_FALSE(readCTAPGetInfoResponse(std::span { kTestAuthenticatorGetInfoResponseWithNoVersion }));
    EXPECT_FALSE(readCTAPGetInfoResponse(std::span { kTestAuthenticatorGetInfoResponseWithDuplicateVersion }));
    EXPECT_FALSE(readCTAPGetInfoResponse(std::span { kTestAuthenticatorGetInfoResponseWithIncorrectAaguid }));
}

TEST(CTAPResponseTest, TestSerializeGetInfoResponse)
{
    AuthenticatorGetInfoResponse response({ ProtocolVersion::kCtap2, ProtocolVersion::kU2f }, std::span { kTestDeviceAaguid });
    response.setExtensions({ "uvm"_s, "hmac-secret"_s });
    AuthenticatorSupportedOptions options;
    options.setResidentKeyAvailability(AuthenticatorSupportedOptions::ResidentKeyAvailability::kSupported);
    options.setIsPlatformDevice(true);
    options.setClientPinAvailability(AuthenticatorSupportedOptions::ClientPinAvailability::kSupportedButPinNotSet);
    options.setUserVerificationAvailability(AuthenticatorSupportedOptions::UserVerificationAvailability::kSupportedAndConfigured);
    response.setOptions(WTF::move(options));
    response.setMaxMsgSize(1200);
    response.setPinProtocols({ PINUVAuthProtocol::kPinProtocol1 });

    auto responseAsCBOR = encodeAsCBOR(WTF::move(response));
    EXPECT_EQ(responseAsCBOR.size(), sizeof(TestData::kTestGetInfoResponsePlatformDevice) - 1);
    EXPECT_TRUE(equalSpans(responseAsCBOR.span(), std::span { TestData::kTestGetInfoResponsePlatformDevice }.subspan(1)));
}

TEST(CTAPResponseTest, TestReadMakeCredentialResponseWithHmacSecret)
{
    // CBOR-encoded response with hmac-secret: true extension in authenticatorData
    // This is the response format when makeCredential is called with hmac-secret extension
    auto response = readCTAPMakeCredentialResponse(std::span { TestData::kTestMakeCredentialResponseWithHmacSecret }, AuthenticatorAttachment::CrossPlatform, { }, AttestationConveyancePreference::Direct);
    ASSERT_TRUE(response);

    // Verify extension output contains prf.enabled: true (converted from hmac-secret: true)
    auto extensions = response->extensions();
    ASSERT_TRUE(extensions.prf);
    ASSERT_TRUE(extensions.prf->enabled);
    EXPECT_TRUE(*extensions.prf->enabled);
}

static Vector<uint8_t> encodeCredPropsExtensionOutputs(const CBORItem& credPropsMap)
{
    return cborMap({ { cborText("credProps"_s), credPropsMap } });
}

TEST(CTAPResponseTest, TestExtensionOutputsCredPropsWithoutRk)
{
    {
        auto outputs = AuthenticationExtensionsClientOutputs::fromCBOR(encodeCredPropsExtensionOutputs(cborMap({ })));
        ASSERT_TRUE(outputs);
        EXPECT_TRUE(outputs->credProps.has_value());
    }

    {
        auto credProps = cborMap({ { cborText("unknownKey"_s), cborBool(true) } });
        auto outputs = AuthenticationExtensionsClientOutputs::fromCBOR(encodeCredPropsExtensionOutputs(credProps));
        ASSERT_TRUE(outputs);
        EXPECT_TRUE(outputs->credProps.has_value());
    }
}

static Vector<uint8_t> testAuthenticatorData(uint8_t flags, std::optional<std::span<const uint8_t>> attestedCredentialID)
{
    Vector<uint8_t> authenticatorData(FillWith { }, 32, 0x11);
    authenticatorData.append(flags);
    authenticatorData.appendList({ 0x00, 0x00, 0x00, 0x01 });
    if (attestedCredentialID) {
        authenticatorData.append(std::span { kTestDeviceAaguid });
        authenticatorData.append(static_cast<uint8_t>(attestedCredentialID->size() >> 8));
        authenticatorData.append(static_cast<uint8_t>(attestedCredentialID->size()));
        authenticatorData.append(*attestedCredentialID);
        authenticatorData.append(std::span { TestData::kTestECPublicKeyCOSE });
    }
    return authenticatorData;
}

static Vector<uint8_t> testMakeCredentialResponse(std::span<const uint8_t> credentialID, const CBORItem& attestationStatement)
{
    Vector<uint8_t> response { 0x00 };
    response.appendVector(cborMap({
        { cborInteger(1), cborText("packed"_s) },
        { cborInteger(2), cborBytes(testAuthenticatorData(0x41, credentialID).span()) },
        { cborInteger(3), attestationStatement },
    }));
    return response;
}

static Vector<uint8_t> testGetAssertionResponse(std::span<const uint8_t> credentialID, std::span<const uint8_t> authenticatorData)
{
    Vector<uint8_t> response { 0x00 };
    response.appendVector(cborMap({
        { cborInteger(1), cborMap({ { cborText("id"_s), cborBytes(credentialID) }, { cborText("type"_s), cborText("public-key"_s) } }) },
        { cborInteger(2), cborBytes(authenticatorData) },
        { cborInteger(3), cborBytes(std::span { TestData::kCtap2GetAssertionSignature }) },
    }));
    return response;
}

// A map of one key per level, levels deep, with an empty map innermost.
static CBORItem nestedCBORMap(size_t levels)
{
    auto map = cborMap({ });
    for (size_t level = 1; level < levels; ++level)
        map = cborMap({ { cborText("x"_s), map } });
    return map;
}

TEST(CTAPResponseTest, TestReadMakeCredentialResponseStatementNesting)
{
    // The reader allows 17 levels, the response map's included, and rejects the response past that. This pins the
    // reader's side: a statement the attestation object's writer cannot write is not reached from here.
    Vector<uint8_t> credentialID(FillWith { }, 16, 0x70);
    auto statement = nestedCBORMap(16);
    auto response = readCTAPMakeCredentialResponse(testMakeCredentialResponse(credentialID.span(), statement), AuthenticatorAttachment::CrossPlatform, { });
    ASSERT_TRUE(response);
    auto attestationObject = response->attestationObject().toVector();
    auto writtenStatement = cborMapLookup(attestationObject.span(), cborText(kAttestationStatementKey).span());
    ASSERT_TRUE(writtenStatement);
    EXPECT_TRUE(std::ranges::equal(*writtenStatement, statement.span()));

    EXPECT_FALSE(readCTAPMakeCredentialResponse(testMakeCredentialResponse(credentialID.span(), nestedCBORMap(17)), AuthenticatorAttachment::CrossPlatform, { }));
}

TEST(CTAPResponseTest, TestReadMakeCredentialResponseCredentialIDLengths)
{
    auto statement = cborMap({ { cborText("alg"_s), cborInteger(-7) } });
    EXPECT_FALSE(readCTAPMakeCredentialResponse(testMakeCredentialResponse({ }, statement), AuthenticatorAttachment::CrossPlatform, { }));

    // The attested credential data holds the length in two bytes.
    Vector<uint8_t> credentialID(FillWith { }, 65535, 0x5c);
    auto response = readCTAPMakeCredentialResponse(testMakeCredentialResponse(credentialID.span(), statement), AuthenticatorAttachment::CrossPlatform, { });
    ASSERT_TRUE(response);
    EXPECT_TRUE(equalSpans(response->rawId().span(), credentialID.span()));
}

TEST(CTAPResponseTest, TestReadMakeCredentialResponsePublicKey)
{
    Vector<uint8_t> credentialID(FillWith { }, 16, 0x70);
    auto response = readCTAPMakeCredentialResponse(testMakeCredentialResponse(credentialID.span(), cborMap({ })), AuthenticatorAttachment::CrossPlatform, { });
    ASSERT_TRUE(response);
    EXPECT_EQ(response->getPublicKeyAlgorithm(), -7);
    auto publicKey = response->getPublicKey();
    ASSERT_TRUE(publicKey);
    // The P-256 key as SubjectPublicKeyInfo ends with the uncompressed point.
    EXPECT_EQ(publicKey->byteLength(), 91u);
    EXPECT_TRUE(equalSpans(publicKey->span().last(64).first(32), std::span { TestData::kTestECPublicKeyCOSE }.subspan(10, 32)));
}

TEST(CTAPResponseTest, TestReadGetAssertionResponseCredentialIDLengths)
{
    auto authenticatorData = testAuthenticatorData(0x01, std::nullopt);
    // An empty credential ID is read as it is.
    auto response = readCTAPGetAssertionResponse(testGetAssertionResponse({ }, authenticatorData.span()), AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(response);
    EXPECT_EQ(response->rawId().byteLength(), 0u);

    Vector<uint8_t> credentialID(FillWith { }, 65536, 0x6d);
    response = readCTAPGetAssertionResponse(testGetAssertionResponse(credentialID.span(), authenticatorData.span()), AuthenticatorAttachment::CrossPlatform);
    ASSERT_TRUE(response);
    EXPECT_TRUE(equalSpans(response->rawId().span(), credentialID.span()));
}

static Vector<uint8_t> testGetInfoResponse(std::initializer_list<CBORMapEntry> moreEntries)
{
    Vector<CBORMapEntry> entries {
        { cborInteger(1), cborArray({ cborText("FIDO_2_0"_s) }) },
        { cborInteger(3), cborBytes(std::span { kTestDeviceAaguid }) },
    };
    entries.appendRange(moreEntries.begin(), moreEntries.end());
    std::ranges::sort(entries, [](auto& a, auto& b) {
        return a.first[0] < b.first[0];
    });
    Vector<uint8_t> response { 0x00 };
    appendCBORHead(response, 5, entries.size());
    for (auto& entry : entries) {
        response.appendVector(entry.first);
        response.appendVector(entry.second);
    }
    return response;
}

TEST(CTAPResponseTest, TestReadGetInfoResponseIntegerWidths)
{
    auto response = readCTAPGetInfoResponse(testGetInfoResponse({ { cborInteger(5), cborInteger(0xffffffff) } }));
    ASSERT_TRUE(response);
    EXPECT_EQ(response->maxMsgSize(), 0xffffffffu);

    // A wider value keeps its low 32 bits, as the C++ reader narrowed it.
    response = readCTAPGetInfoResponse(testGetInfoResponse({ { cborInteger(5), cborInteger(0x100000001) } }));
    ASSERT_TRUE(response);
    EXPECT_EQ(response->maxMsgSize(), 1u);

    EXPECT_FALSE(readCTAPGetInfoResponse(testGetInfoResponse({ { cborInteger(5), cborInteger(-1) } })));
}

TEST(CTAPResponseTest, TestReadGetInfoResponseExtensions)
{
    EXPECT_FALSE(readCTAPGetInfoResponse(testGetInfoResponse({ { cborInteger(2), cborArray({ cborText("hmac-secret"_s), cborInteger(1) }) } })));

    auto response = readCTAPGetInfoResponse(testGetInfoResponse({ { cborInteger(2), cborArray({ cborText(emptyString()) }) } }));
    ASSERT_TRUE(response);
    ASSERT_TRUE(response->extensions());
    ASSERT_EQ(response->extensions()->size(), 1u);
    EXPECT_EQ(response->extensions()->first(), emptyString());
}

} // namespace TestWebKitAPI


#endif // ENABLE(WEB_AUTHN)
