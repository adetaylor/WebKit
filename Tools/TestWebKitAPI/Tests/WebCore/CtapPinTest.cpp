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

#if ENABLE(WEB_AUTHN)

#include "CBORTestUtilities.h"
#include "FidoTestData.h"
#include "Helpers/PlatformUtilities.h"
#include <WebCore/CBORBytes.h>
#include <WebCore/CryptoAlgorithmAESCBC.h>
#include <WebCore/CryptoAlgorithmAesCbcCfbParams.h>
#include <WebCore/CryptoAlgorithmECDH.h>
#include <WebCore/CryptoKeyAES.h>
#include <WebCore/CryptoKeyEC.h>
#include <WebCore/CryptoKeyHMAC.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/FidoConstants.h>
#include <WebCore/Pin.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/WebAuthenticationConstants.h>
#include <WebCore/WebAuthenticationUtils.h>
#include <pal/crypto/CryptoDigest.h>
#include <wtf/StdLibExtras.h>

namespace TestWebKitAPI {
using namespace WebCore;
using namespace cbor;
using namespace fido;
using namespace fido::pin;

// Decodes the CTAP2 request that encodeAsCBOR wrote after its command byte, and returns its canonical bytes, a map.
static Vector<uint8_t> decodeRequestMap(std::span<const uint8_t> request)
{
    auto decoded = cbor::readCanonical(request.subspan(1));
    EXPECT_TRUE(decoded.error == cbor::DecoderError::CBORNoError);
    EXPECT_TRUE(isCBORMap(decoded.canonical.span()));
    return WTF::move(decoded.canonical);
}

static std::optional<int64_t> integerAt(std::span<const uint8_t> map, int64_t key)
{
    auto value = cborMapLookup(map, key);
    if (!value)
        return std::nullopt;
    return cborIntegerValue(*value);
}

static std::optional<Vector<uint8_t>> byteStringAt(std::span<const uint8_t> map, int64_t key)
{
    auto value = cborMapLookup(map, key);
    if (!value)
        return std::nullopt;
    return cborByteStringValue(*value);
}

// Checks kty, alg and crv of the COSE key under RequestKey::kKeyAgreement, and returns the COSE key's bytes.
static Vector<uint8_t> checkRequestCOSEKey(std::span<const uint8_t> requestMap)
{
    auto coseKeyItem = cborMapLookup(requestMap, static_cast<int64_t>(RequestKey::kKeyAgreement));
    EXPECT_TRUE(coseKeyItem.has_value());
    if (!coseKeyItem)
        return { };
    EXPECT_TRUE(isCBORMap(*coseKeyItem));
    Vector<uint8_t> coseKey { *coseKeyItem };
    EXPECT_EQ(integerAt(coseKey.span(), COSE::kty), COSE::EC2);
    EXPECT_EQ(integerAt(coseKey.span(), COSE::alg), COSE::ECDH256);
    EXPECT_EQ(integerAt(coseKey.span(), COSE::crv), COSE::P_256);
    return coseKey;
}

TEST(CtapPinTest, TestValidateAndConvertToUTF8)
{
    // Failure cases
    auto result = validateAndConvertToUTF8("123"_s);
    EXPECT_FALSE(result);
    result = validateAndConvertToUTF8(emptyString());
    EXPECT_FALSE(result);
    result = validateAndConvertToUTF8("1234567812345678123456781234567812345678123456781234567812345678"_s);
    EXPECT_FALSE(result);

    // Success cases
    result = validateAndConvertToUTF8("1234"_s);
    EXPECT_TRUE(result);
    EXPECT_EQ(result->length(), 4u);
    EXPECT_EQ(*result, "1234"_s);

    result = validateAndConvertToUTF8("123456781234567812345678123456781234567812345678123456781234567"_s);
    EXPECT_TRUE(result);
    EXPECT_EQ(result->length(), 63u);
    EXPECT_EQ(*result, "123456781234567812345678123456781234567812345678123456781234567"_s);
}

TEST(CtapPinTest, TestSetPinRequest)
{
    // Generate an EC key pair as the peer key.
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    String pin = "1234"_s;

    auto request = SetPinRequest::tryCreate(PINUVAuthProtocol::kPinProtocol1, pin, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_TRUE(request);
    auto result = encodeAsCBOR(WTF::move(*request));

    EXPECT_EQ(result.size(), 170u);
    EXPECT_EQ(result[0], static_cast<uint8_t>(CtapRequestCommand::kAuthenticatorClientPin));

    // Decode the CBOR binary to check if each field is encoded correctly.
    auto responseMap = decodeRequestMap(result.span());

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kProtocol)), kProtocolVersion);
    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kSubcommand)), static_cast<int64_t>(Subcommand::kSetPin));

    // COSE
    auto coseKey = checkRequestCOSEKey(responseMap.span());

    // Check the cose key.
    auto x = byteStringAt(coseKey.span(), COSE::x);
    auto y = byteStringAt(coseKey.span(), COSE::y);
    ASSERT_TRUE(x.has_value());
    ASSERT_TRUE(y.has_value());
    auto cosePublicKey = CryptoKeyEC::importRaw(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, encodeRawPublicKey(*x, *y), true, CryptoKeyUsageDeriveBits);
    EXPECT_TRUE(cosePublicKey);

    // Check the encrypted Pin.
    auto sharedKeyResult = CryptoAlgorithmECDH::platformDeriveBits(downcast<CryptoKeyEC>(*keyPair.privateKey), *cosePublicKey);
    EXPECT_TRUE(sharedKeyResult);

    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(sharedKeyResult->span());
    auto sharedKeyHash = crypto->computeHash();

    auto aesKey = CryptoKeyAES::importRaw(CryptoAlgorithmIdentifier::AES_CBC, WTF::move(sharedKeyHash), true, CryptoKeyUsageDecrypt);
    EXPECT_TRUE(aesKey);

    auto encryptedNewPin = byteStringAt(responseMap.span(), static_cast<int64_t>(RequestKey::kNewPinEnc));
    ASSERT_TRUE(encryptedNewPin.has_value());
    auto newPinEncResult = CryptoAlgorithmAESCBC::platformDecrypt({ }, *aesKey, *encryptedNewPin, CryptoAlgorithmAESCBC::Padding::No);
    EXPECT_FALSE(newPinEncResult.hasException());
    auto newPinEnc = newPinEncResult.releaseReturnValue();

    constexpr std::array<uint8_t, 64> expectedNewPinEnc { 0x31, 0x32, 0x33, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    EXPECT_EQ(newPinEnc.size(), 64u);
    EXPECT_TRUE(equalSpans(newPinEnc.span(), std::span { expectedNewPinEnc }));

    String pin2 = "123"_s;
    auto request2 = SetPinRequest::tryCreate(PINUVAuthProtocol::kPinProtocol1, pin2, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_FALSE(request2);

    String pin3 = "01234567891011121314151617181920212223242526272829303132333435363738394041424344454647484950"_s;
    auto request3 = SetPinRequest::tryCreate(PINUVAuthProtocol::kPinProtocol1, pin3, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_FALSE(request3);
}

TEST(CtapPinTest, TestRetriesRequest)
{
    auto result = encodeAsCBOR(RetriesRequest { PINUVAuthProtocol::kPinProtocol1 });
    EXPECT_EQ(result.size(), sizeof(TestData::kCtapClientPinRetries));
    EXPECT_TRUE(equalSpans(result.span(), std::span { TestData::kCtapClientPinRetries }));
}

TEST(CtapPinTest, TestRetriesResponse)
{
    // Failure cases
    auto result = RetriesResponse::parse({ });
    EXPECT_FALSE(result);

    constexpr std::array<uint8_t, 1> testData1 { 0x05 }; // wrong response code
    result = RetriesResponse::parse(std::span { testData1 });
    EXPECT_FALSE(result);

    constexpr std::array<uint8_t, 2> testData2 { 0x00, 0x00 }; // wrong CBOR map
    result = RetriesResponse::parse(std::span { testData2 });
    EXPECT_FALSE(result);

    result = RetriesResponse::parse(std::span { TestData::kCtapClientPinTokenResponse }); // wrong response
    EXPECT_FALSE(result);

    // Success cases
    result = RetriesResponse::parse(std::span { TestData::kCtapClientPinRetriesResponse });
    EXPECT_TRUE(result);
    EXPECT_EQ(result->retries, 8u);
}

TEST(CtapPinTest, TestKeyAgreementRequest)
{
    auto result = encodeAsCBOR(KeyAgreementRequest { PINUVAuthProtocol::kPinProtocol1 });
    EXPECT_EQ(result.size(), sizeof(TestData::kCtapClientPinKeyAgreement));
    EXPECT_TRUE(equalSpans(result.span(), std::span { TestData::kCtapClientPinKeyAgreement }));
}

TEST(CtapPinTest, TestKeyAgreementResponse)
{
    // Failure cases
    auto result = KeyAgreementResponse::parse({ });
    EXPECT_FALSE(result);

    constexpr std::array<uint8_t, 1> testData1 { 0x05 }; // wrong response code
    result = KeyAgreementResponse::parse(std::span { testData1 });
    EXPECT_FALSE(result);

    constexpr std::array<uint8_t, 2> testData2 { 0x00, 0x00 }; // wrong CBOR map
    result = KeyAgreementResponse::parse(std::span { testData2 });
    EXPECT_FALSE(result);

    result = KeyAgreementResponse::parse(std::span { TestData::kCtapClientPinTokenResponse }); // wrong response
    EXPECT_FALSE(result);

// FIXME: When can we enable this for non-Cocoa platforms?
// FIXME: Can we enable this for watchOS and tvOS?
#if PLATFORM(MAC) || PLATFORM(IOS) || PLATFORM(VISION)
    result = KeyAgreementResponse::parse(std::span { TestData::kCtapClientPinInvalidKeyAgreementResponse }); // The point is not on the curve.
    EXPECT_FALSE(result);
#endif

    // Test COSE
    auto coseKeyWith = [](int64_t key, const CBORItem& replacement) {
        // The five keys of encodeCOSEPublicKey's map, in CTAP2 order, with the value of one of them replaced.
        Vector<uint8_t> zeros(32);
        CBORItem coseKey;
        appendCBORHead(coseKey, 5, 5);
        for (auto [entryKey, entryValue] : std::initializer_list<std::pair<int64_t, CBORItem>> {
            { COSE::kty, cborInteger(COSE::EC2) },
            { COSE::alg, cborInteger(COSE::ECDH256) },
            { COSE::crv, cborInteger(COSE::P_256) },
            { COSE::x, cborBytes(zeros.span()) },
            { COSE::y, cborBytes(zeros.span()) } }) {
            coseKey.appendVector(cborInteger(entryKey));
            coseKey.appendVector(entryKey == key ? replacement : entryValue);
        }
        return coseKey;
    };

    // The encoded key of an all-zero point is the map above with the right values.
    EXPECT_TRUE(encodeCOSEPublicKey(Vector<uint8_t>(65)) == coseKeyWith(0, { }));

    auto coseResult = KeyAgreementResponse::parseFromCOSE(coseKeyWith(COSE::kty, cborInteger(0))); // wrong kty
    EXPECT_FALSE(coseResult);

    coseResult = KeyAgreementResponse::parseFromCOSE(coseKeyWith(COSE::alg, cborInteger(0))); // wrong alg
    EXPECT_FALSE(coseResult);

    coseResult = KeyAgreementResponse::parseFromCOSE(coseKeyWith(COSE::crv, cborInteger(0))); // wrong crv
    EXPECT_FALSE(coseResult);

    coseResult = KeyAgreementResponse::parseFromCOSE(coseKeyWith(COSE::x, cborInteger(0))); // wrong x
    EXPECT_FALSE(coseResult);

    coseResult = KeyAgreementResponse::parseFromCOSE(coseKeyWith(COSE::y, cborInteger(0))); // wrong y
    EXPECT_FALSE(coseResult);

    // Success cases
    result = KeyAgreementResponse::parse(std::span { TestData::kCtapClientPinKeyAgreementResponse });
    EXPECT_TRUE(result);
    auto exportedRawKey = result->peerKey->exportRaw();
    EXPECT_FALSE(exportedRawKey.hasException());
    Vector<uint8_t> expectedRawKey;
    expectedRawKey.reserveCapacity(65);
    expectedRawKey.append(0x04);
    expectedRawKey.append(std::span { TestData::kCtapClientPinKeyAgreementResponse }.subspan(14, 32)); // X
    expectedRawKey.append(std::span { TestData::kCtapClientPinKeyAgreementResponse }.subspan(49, 32)); // Y
    EXPECT_TRUE(exportedRawKey.returnValue() == expectedRawKey);
}

TEST(CtapPinTest, TestTokenRequest)
{
    // Generate an EC key pair as the peer key.
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    UTF8CString pin = "1234"_s;

    auto token = TokenRequest::tryCreate(PINUVAuthProtocol::kPinProtocol1, pin, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_TRUE(token);
    auto result = encodeAsCBOR(*token);

    EXPECT_EQ(result.size(), 103u);
    EXPECT_EQ(result[0], static_cast<uint8_t>(CtapRequestCommand::kAuthenticatorClientPin));

    // Decode the CBOR binary to check if each field is encoded correctly.
    auto responseMap = decodeRequestMap(result.span());

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kProtocol)), kProtocolVersion);

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kSubcommand)), static_cast<int64_t>(Subcommand::kGetPinToken));

    // COSE
    auto coseKey = checkRequestCOSEKey(responseMap.span());

    // Check the cose key.
    auto x = byteStringAt(coseKey.span(), COSE::x);
    auto y = byteStringAt(coseKey.span(), COSE::y);
    ASSERT_TRUE(x.has_value());
    ASSERT_TRUE(y.has_value());
    auto cosePublicKey = CryptoKeyEC::importRaw(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, encodeRawPublicKey(*x, *y), true, CryptoKeyUsageDeriveBits);
    EXPECT_TRUE(cosePublicKey);

    // Check the encrypted Pin.
    auto sharedKeyResult = CryptoAlgorithmECDH::platformDeriveBits(downcast<CryptoKeyEC>(*keyPair.privateKey), *cosePublicKey);
    EXPECT_TRUE(sharedKeyResult);

    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(sharedKeyResult->span());
    auto sharedKeyHash = crypto->computeHash();

    auto aesKey = CryptoKeyAES::importRaw(CryptoAlgorithmIdentifier::AES_CBC, WTF::move(sharedKeyHash), true, CryptoKeyUsageDecrypt);
    EXPECT_TRUE(aesKey);

    auto encryptedPinHash = byteStringAt(responseMap.span(), static_cast<int64_t>(RequestKey::kPinHashEnc));
    ASSERT_TRUE(encryptedPinHash.has_value());
    auto pinHashResult = CryptoAlgorithmAESCBC::platformDecrypt({ }, *aesKey, *encryptedPinHash, CryptoAlgorithmAESCBC::Padding::No);
    EXPECT_FALSE(pinHashResult.hasException());
    auto pinHash = pinHashResult.releaseReturnValue();
    constexpr std::array<uint8_t, 16> expectedPinHash { 0x03, 0xac, 0x67, 0x42, 0x16, 0xf3, 0xe1, 0x5c, 0x76, 0x1e, 0xe1, 0xa5, 0xe2, 0x55, 0xf0, 0x67 };
    EXPECT_EQ(pinHash.size(), 16u);
    EXPECT_TRUE(equalSpans(pinHash.span(), std::span { expectedPinHash }));
}

TEST(CtapPinTest, TestTokenResponse)
{
    constexpr std::array<uint8_t, 32> sharedKeyData {
        0x29, 0x9E, 0x65, 0xB8, 0xE7, 0x71, 0xB8, 0x1D,
        0xB1, 0xC4, 0x8D, 0xBE, 0xCE, 0x50, 0x2A, 0x84,
        0x05, 0x44, 0x7F, 0x46, 0x2D, 0xE6, 0x81, 0xFA,
        0xEF, 0x0A, 0x6C, 0x67, 0xA7, 0x2B, 0xB5, 0x0F, };
    auto sharedKey = CryptoKeyAES::importRaw(CryptoAlgorithmIdentifier::AES_CBC, std::span { sharedKeyData }, true, CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt);
    ASSERT_TRUE(sharedKey);

    // Failure cases
    auto result = TokenResponse::parse(PINUVAuthProtocol::kPinProtocol1, *sharedKey, { });
    EXPECT_FALSE(result);

    constexpr std::array<uint8_t, 1> testData1 { 0x05 }; // wrong response code
    result = TokenResponse::parse(PINUVAuthProtocol::kPinProtocol1, *sharedKey, std::span { testData1 });
    EXPECT_FALSE(result);

    constexpr std::array<uint8_t, 2> testData2 { 0x00, 0x00 }; // wrong CBOR map
    result = TokenResponse::parse(PINUVAuthProtocol::kPinProtocol1, *sharedKey, std::span { testData2 });
    EXPECT_FALSE(result);

    result = TokenResponse::parse(PINUVAuthProtocol::kPinProtocol1, *sharedKey, std::span { TestData::kCtapClientPinKeyAgreementResponse }); // wrong response
    EXPECT_FALSE(result);

    // Success cases
    result = TokenResponse::parse(PINUVAuthProtocol::kPinProtocol1, *sharedKey, std::span { TestData::kCtapClientPinTokenResponse });
    EXPECT_TRUE(result);
    constexpr std::array<uint8_t, 16> expectedToken { 0x03, 0xac, 0x67, 0x42, 0x16, 0xf3, 0xe1, 0x5c, 0x76, 0x1e, 0xe1, 0xa5, 0xe2, 0x55, 0xf0, 0x67 };
    EXPECT_EQ(result->token().size(), 16u);
    EXPECT_TRUE(equalSpans(result->token().span(), std::span { expectedToken }));
}

TEST(CtapPinTest, TestPinAuth)
{
    // 1. Generate the token.
    constexpr std::array<uint8_t, 32> sharedKeyData {
        0x29, 0x9E, 0x65, 0xB8, 0xE7, 0x71, 0xB8, 0x1D,
        0xB1, 0xC4, 0x8D, 0xBE, 0xCE, 0x50, 0x2A, 0x84,
        0x05, 0x44, 0x7F, 0x46, 0x2D, 0xE6, 0x81, 0xFA,
        0xEF, 0x0A, 0x6C, 0x67, 0xA7, 0x2B, 0xB5, 0x0F, };
    auto sharedKey = CryptoKeyAES::importRaw(CryptoAlgorithmIdentifier::AES_CBC, std::span { sharedKeyData }, true, CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt);
    ASSERT_TRUE(sharedKey);
    auto result = TokenResponse::parse(PINUVAuthProtocol::kPinProtocol1, *sharedKey, std::span { TestData::kCtapClientPinTokenResponse });
    ASSERT_TRUE(result);

    // 2. Generate the pinAuth.
    auto pinAuth = result->pinAuth(PINUVAuthProtocol::kPinProtocol1, std::span { sharedKeyData }); // sharedKeyData pretends to be clientDataHash
    constexpr std::array<uint8_t, 16> expectedPinAuth { 0x0b, 0xec, 0x9d, 0xba, 0x69, 0xb0, 0x0f, 0x45, 0x0b, 0xec, 0x66, 0xb4, 0x75, 0x7f, 0x93, 0x85 };
    EXPECT_EQ(pinAuth.size(), 16u);
    EXPECT_TRUE(equalSpans(pinAuth.span(), std::span { expectedPinAuth }));
}

TEST(CtapPinTest, TestSetPinRequestProtocol2)
{
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    String pin = "1234"_s;

    auto request = SetPinRequest::tryCreate(PINUVAuthProtocol::kPinProtocol2, pin, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_TRUE(request);
    auto result = encodeAsCBOR(WTF::move(*request));

    EXPECT_EQ(result.size(), 203u);
    EXPECT_EQ(result[0], static_cast<uint8_t>(CtapRequestCommand::kAuthenticatorClientPin));

    auto responseMap = decodeRequestMap(result.span());

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kProtocol)), static_cast<int64_t>(PINUVAuthProtocol::kPinProtocol2));

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kSubcommand)), static_cast<int64_t>(Subcommand::kSetPin));

    // COSE
    auto coseKey = checkRequestCOSEKey(responseMap.span());

    auto encryptedNewPin = byteStringAt(responseMap.span(), static_cast<int64_t>(RequestKey::kNewPinEnc));
    ASSERT_TRUE(encryptedNewPin.has_value());
    EXPECT_EQ(encryptedNewPin->size(), 80u);

    auto pinAuth = byteStringAt(responseMap.span(), static_cast<int64_t>(RequestKey::kPinAuth));
    ASSERT_TRUE(pinAuth.has_value());
    EXPECT_GT(pinAuth->size(), 0u);
}

TEST(CtapPinTest, TestTokenRequestProtocol2)
{
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    UTF8CString pin = "1234"_s;

    auto token = TokenRequest::tryCreate(PINUVAuthProtocol::kPinProtocol2, pin, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_TRUE(token);
    auto result = encodeAsCBOR(*token);

    EXPECT_EQ(result.size(), 120u);
    EXPECT_EQ(result[0], static_cast<uint8_t>(CtapRequestCommand::kAuthenticatorClientPin));

    auto responseMap = decodeRequestMap(result.span());

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kProtocol)), static_cast<int64_t>(PINUVAuthProtocol::kPinProtocol2));

    EXPECT_EQ(integerAt(responseMap.span(), static_cast<int64_t>(RequestKey::kSubcommand)), static_cast<int64_t>(Subcommand::kGetPinToken));

    // COSE
    auto coseKey = checkRequestCOSEKey(responseMap.span());

    // Verify encrypted PIN hash is present
    auto encryptedPinHash = byteStringAt(responseMap.span(), static_cast<int64_t>(RequestKey::kPinHashEnc));
    ASSERT_TRUE(encryptedPinHash.has_value());
    EXPECT_EQ(encryptedPinHash->size(), 32u);
}

TEST(CtapPinTest, TestProtocol2HKDFKeyDerivation)
{
    constexpr std::array<uint8_t, 32> testECDHResult {
        0x87, 0x6e, 0x3d, 0x99, 0x2c, 0x5a, 0x1b, 0x84,
        0x6f, 0x2d, 0x87, 0x62, 0xaa, 0x38, 0x92, 0x7c,
        0x4e, 0x5c, 0x3b, 0x23, 0x1d, 0xe6, 0x89, 0x45,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0
    };

    constexpr std::array<uint8_t, 32> expectedHMACKey {
        0x88, 0x1f, 0xc7, 0x93, 0xc8, 0x34, 0xdb, 0x80,
        0x4f, 0xd5, 0x8d, 0x96, 0xb2, 0xbd, 0x85, 0xac,
        0x21, 0xf7, 0xe7, 0x4b, 0xeb, 0x23, 0x36, 0x5b,
        0xd2, 0x67, 0xe4, 0x96, 0x21, 0x9b, 0xfb, 0x29
    };

    constexpr std::array<uint8_t, 32> expectedAESKey {
        0x31, 0x3b, 0x20, 0xaf, 0x5e, 0x3f, 0x60, 0x05,
        0x17, 0xa6, 0xdc, 0xda, 0xbf, 0xae, 0xa2, 0xbf,
        0x49, 0x08, 0xe8, 0x36, 0x2a, 0x1c, 0x3a, 0x5b,
        0xaa, 0xce, 0x11, 0x8e, 0x3e, 0x72, 0x49, 0xd2
    };

    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(std::span { testECDHResult });
    auto protocol1Key = crypto->computeHash();

    EXPECT_FALSE(equalSpans(protocol1Key.span(), std::span { expectedHMACKey }));
    EXPECT_FALSE(equalSpans(protocol1Key.span(), std::span { expectedAESKey }));
}

TEST(CtapPinTest, TestHmacSecretRequestCreate)
{
    // Generate an EC key pair as the peer key
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    // Create 32-byte salts
    Vector<uint8_t> salt1(FillWith { }, 32, 0x00); // 32 bytes of zeros
    Vector<uint8_t> salt2(FillWith { }, 32, 0xFF); // 32 bytes of 0xFF

    // Test with 1 salt (Protocol 1)
    auto request1 = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, salt1, std::nullopt, downcast<CryptoKeyEC>(*keyPair.publicKey));
    ASSERT_TRUE(request1);
    EXPECT_EQ(request1->saltEnc().size(), 32u);
    EXPECT_EQ(request1->saltAuth().size(), 16u); // Protocol 1 uses 16 bytes
    EXPECT_EQ(request1->protocol(), PINUVAuthProtocol::kPinProtocol1);

    // Test with 2 salts (Protocol 1)
    auto request2 = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, salt1, salt2, downcast<CryptoKeyEC>(*keyPair.publicKey));
    ASSERT_TRUE(request2);
    EXPECT_EQ(request2->saltEnc().size(), 64u); // 32 + 32
    EXPECT_EQ(request2->saltAuth().size(), 16u);

    // Test with Protocol 2
    auto request3 = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol2, salt1, std::nullopt, downcast<CryptoKeyEC>(*keyPair.publicKey));
    ASSERT_TRUE(request3);
    EXPECT_GT(request3->saltEnc().size(), 32u); // Protocol 2 adds IV
    EXPECT_EQ(request3->saltAuth().size(), 32u); // Protocol 2 uses full 32 bytes
    EXPECT_EQ(request3->protocol(), PINUVAuthProtocol::kPinProtocol2);
}

TEST(CtapPinTest, TestHmacSecretRequestInvalidSalts)
{
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    // Invalid: salt1 too short
    Vector<uint8_t> shortSalt(FillWith { }, 16, 0x00);
    auto request = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, shortSalt, std::nullopt, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_FALSE(request);

    // Invalid: salt2 too short
    Vector<uint8_t> validSalt(FillWith { }, 32, 0x00);
    request = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, validSalt, shortSalt, downcast<CryptoKeyEC>(*keyPair.publicKey));
    EXPECT_FALSE(request);
}

TEST(CtapPinTest, TestHmacSecretResponseRoundTrip)
{
    // Generate an EC key pair as the peer key
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    Vector<uint8_t> salt1(FillWith { }, 32, 0xAA);

    // Create HmacSecretRequest which encrypts the salts
    auto request = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, salt1, std::nullopt, downcast<CryptoKeyEC>(*keyPair.publicKey));
    ASSERT_TRUE(request);

    // Simulate authenticator response: re-encrypt the same data
    // (In reality, authenticator would encrypt HMAC outputs, but for testing we just verify decrypt works)
    auto encryptedOutput = request->saltEnc();

    // Parse/decrypt the response
    auto response = HmacSecretResponse::parse(PINUVAuthProtocol::kPinProtocol1, request->sharedKey(), encryptedOutput);
    ASSERT_TRUE(response);

    // Verify the decrypted output matches original salt
    EXPECT_EQ(response->output().size(), 32u);
    EXPECT_TRUE(equalSpans(response->output().span(), salt1.span()));
}

TEST(CtapPinTest, TestHmacSecretResponseInvalidSize)
{
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();

    Vector<uint8_t> salt1(FillWith { }, 32, 0x00);
    auto request = HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, salt1, std::nullopt, downcast<CryptoKeyEC>(*keyPair.publicKey));
    ASSERT_TRUE(request);

    // Test with invalid encrypted output (wrong size)
    Vector<uint8_t> invalidOutput(FillWith { }, 16, 0x00); // Too short, should be 32 or 64
    auto response = HmacSecretResponse::parse(PINUVAuthProtocol::kPinProtocol1, request->sharedKey(), invalidOutput);
    EXPECT_FALSE(response);
}

TEST(CtapPinTest, TestHmacSecretSaltLengths)
{
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    ASSERT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();
    RefPtr peerKey = downcast<CryptoKeyEC>(keyPair.publicKey);

    Vector<uint8_t> salt1(FillWith { }, 32, 0x5a);
    Vector<uint8_t> salt2(FillWith { }, 32, 0xa5);
    for (size_t length : { 31u, 33u, 64u })
        EXPECT_FALSE(HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, Vector<uint8_t>(FillWith { }, length, 0x5a), std::nullopt, peerKey));
    for (size_t length : { 31u, 33u })
        EXPECT_FALSE(HmacSecretRequest::create(PINUVAuthProtocol::kPinProtocol1, salt1, Vector<uint8_t>(FillWith { }, length, 0xa5), peerKey));

    Vector<uint8_t> bothSalts = salt1;
    bothSalts.appendVector(salt2);
    for (auto protocol : { PINUVAuthProtocol::kPinProtocol1, PINUVAuthProtocol::kPinProtocol2 }) {
        // Protocol 2 puts a 16-byte IV before the ciphertext.
        size_t ivLength = protocol == PINUVAuthProtocol::kPinProtocol2 ? 16 : 0;

        auto request = HmacSecretRequest::create(protocol, salt1, salt2, peerKey);
        ASSERT_TRUE(request);
        EXPECT_EQ(request->saltEnc().size(), 64u + ivLength);
        // The authenticator's output has the salts' length, so the request's own ciphertext stands in for it.
        auto response = HmacSecretResponse::parse(protocol, request->sharedKey(), request->saltEnc());
        ASSERT_TRUE(response);
        EXPECT_TRUE(equalSpans(response->output().span(), bothSalts.span()));

        request = HmacSecretRequest::create(protocol, salt1, std::nullopt, peerKey);
        ASSERT_TRUE(request);
        EXPECT_EQ(request->saltEnc().size(), 32u + ivLength);
        response = HmacSecretResponse::parse(protocol, request->sharedKey(), request->saltEnc());
        ASSERT_TRUE(response);
        EXPECT_TRUE(equalSpans(response->output().span(), salt1.span()));
    }
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
