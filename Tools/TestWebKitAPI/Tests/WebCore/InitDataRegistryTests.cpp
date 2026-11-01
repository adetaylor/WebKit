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

#include "config.h"

#if ENABLE(ENCRYPTED_MEDIA)

#include <WebCore/CDMFactory.h>
#include <WebCore/CDMPrivate.h>
#include <WebCore/InitDataRegistry.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/Logger.h>
#include <wtf/NeverDestroyed.h>

namespace TestWebKitAPI {
using namespace WebCore;

static Ref<SharedBuffer> buffer(std::span<const uint8_t> bytes)
{
    return SharedBuffer::create(bytes);
}

static Ref<SharedBuffer> buffer(ASCIILiteral text)
{
    return SharedBuffer::create(text.span8());
}

static std::span<const uint8_t> bytes(ASCIILiteral literal)
{
    return byteCast<uint8_t>(literal.span8());
}

static void appendUInt32(Vector<uint8_t>& vector, uint32_t value)
{
    vector.appendList({ static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16), static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value) });
}

static Vector<uint8_t> box(ASCIILiteral type, std::span<const uint8_t> payload)
{
    Vector<uint8_t> result;
    appendUInt32(result, payload.size() + 8);
    result.append(bytes(type));
    result.append(payload);
    return result;
}

static Vector<uint8_t> fullBox(ASCIILiteral type, uint8_t version, std::span<const uint8_t> payload)
{
    Vector<uint8_t> versionAndFlags { version, 0, 0, 0 };
    versionAndFlags.append(payload);
    return box(type, versionAndFlags.span());
}

static Vector<uint8_t> keyID(uint8_t byte)
{
    return Vector<uint8_t> { FillWith { }, 16, byte };
}

static constexpr uint8_t commonSystemID[] = { 0x10, 0x77, 0xef, 0xec, 0xc0, 0xb2, 0x4d, 0x02, 0xac, 0xe3, 0x3c, 0x1e, 0x52, 0xe2, 0xfb, 0x4b };
static constexpr uint8_t fairPlaySystemID[] = { 0x94, 0xce, 0x86, 0xfb, 0x07, 0xff, 0x4f, 0x43, 0xad, 0xb8, 0x93, 0xd2, 0xfa, 0x96, 0x8c, 0xa2 };

// A pssh box; version 1 lists keyIDBytes, a key ID of 16 such bytes each.
static Vector<uint8_t> pssh(std::span<const uint8_t> systemID, uint8_t version, std::initializer_list<uint8_t> keyIDBytes, std::span<const uint8_t> data)
{
    Vector<uint8_t> payload { systemID };
    if (version) {
        appendUInt32(payload, keyIDBytes.size());
        for (auto byte : keyIDBytes)
            payload.append(keyID(byte).span());
    }
    appendUInt32(payload, data.size());
    payload.append(data);
    return fullBox("pssh"_s, version, payload.span());
}

static Vector<uint8_t> concatenate(std::initializer_list<std::span<const uint8_t>> parts)
{
    Vector<uint8_t> result;
    for (auto part : parts)
        result.append(part);
    return result;
}

// An fpsd with an fpsi for scheme and an fpsk per byte of requestKeyIDBytes, whose fkri has a key ID of 16 such bytes.
static Vector<uint8_t> fairPlayInitData(ASCIILiteral scheme, std::initializer_list<uint8_t> requestKeyIDBytes)
{
    auto fpsd = fullBox("fpsi"_s, 0, bytes(scheme));
    for (auto byte : requestKeyIDBytes) {
        auto fkri = fullBox("fkri"_s, 0, keyID(byte).span());
        static constexpr uint8_t assetID[] = { 1, 2, 3 };
        auto fkai = box("fkai"_s, std::span { assetID });
        fpsd.append(box("fpsk"_s, concatenate({ fkri.span(), fkai.span() }).span()).span());
    }
    return box("fpsd"_s, fpsd.span());
}

static void expectKeyIDs(const std::optional<CDMKeyIDs>& keyIDs, std::initializer_list<uint8_t> expectedBytes)
{
    ASSERT_TRUE(keyIDs);
    ASSERT_EQ(keyIDs->size(), expectedBytes.size());
    size_t index = 0;
    for (auto byte : expectedBytes)
        EXPECT_EQ(Vector<uint8_t> { (*keyIDs)[index++]->span() }, keyID(byte));
}

static void expectSame(const RefPtr<SharedBuffer>& sanitized, std::span<const uint8_t> expected)
{
    ASSERT_TRUE(sanitized);
    EXPECT_EQ(Vector<uint8_t> { sanitized->span() }, Vector<uint8_t> { expected });
}

static String utf16(ASCIILiteral literal)
{
    Vector<char16_t> characters;
    for (auto character : literal.span8())
        characters.append(character);
    String string { characters.span() };
    EXPECT_FALSE(string.is8Bit());
    return string;
}

static constexpr uint8_t emptyBytes[1] { };

// Swift traps on an empty span with no base address passed back to C++, so the shells get empty inputs of every kind.
static Vector<Ref<SharedBuffer>> emptyBuffers()
{
    Vector<Ref<SharedBuffer>> buffers;
    buffers.append(SharedBuffer::create());
    buffers.append(SharedBuffer::create(Vector<uint8_t> { }));
    buffers.append(buffer(std::span { emptyBytes }.first(0)));
    return buffers;
}

static InitDataRegistry& registry()
{
    return InitDataRegistry::singleton();
}

#if USE(AVFOUNDATION)
// The 'sinf', 'skd' and 'mpts' types work before the CDM factories are registered.
TEST(InitDataRegistry, FairPlayTypesWithoutCDMFactories)
{
    static constexpr uint8_t skd[] = { 's', 'k', 'd', ':', '/', '/', 'k' };
    auto keyIDs = registry().extractKeyIDs("skd"_s, buffer(std::span { skd }));
    ASSERT_TRUE(keyIDs);
    ASSERT_EQ(keyIDs->size(), 1U);
    expectSame(registry().sanitizeInitData("skd"_s, buffer(std::span { skd })), std::span { skd });
}
#endif

TEST(InitDataRegistry, KeyIDs)
{
    expectKeyIDs(registry().extractKeyIDs("keyids"_s, buffer("{\"kids\":[\"AQEBAQEBAQEBAQEBAQEBAQ\",\"AgICAgICAgICAgICAgICAg==\"]}"_s)), { 1, 2 });
    expectSame(registry().sanitizeInitData("keyids"_s, buffer("{\"kids\":[1,\"AQEBAQEBAQEBAQEBAQEBAQ==\",\"*\"],\"x\":0}"_s)), bytes("{\"kids\":[\"AQEBAQEBAQEBAQEBAQEBAQ\"]}"_s));
    EXPECT_FALSE(registry().extractKeyIDs("keyids"_s, buffer("{\"kids\":[\"\"]}"_s)));
    EXPECT_FALSE(registry().extractKeyIDs("keyids"_s, buffer("{\"kid\":[]}"_s)));
    EXPECT_FALSE(registry().sanitizeInitData("keyids"_s, buffer("[]"_s)));
}

TEST(InitDataRegistry, Cenc)
{
    auto version1 = pssh(std::span { commonSystemID }, 1, { 1, 2 }, { });
    auto version0 = pssh(std::span { commonSystemID }, 0, { }, bytes("data"_s));
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(version1.span())), { 1, 2 });
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(version0.span())), { });

    auto both = concatenate({ version1.span(), version0.span(), pssh(std::span { commonSystemID }, 1, { 3 }, bytes("x"_s)).span() });
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(both.span())), { 1, 2, 3 });
    expectSame(registry().sanitizeInitData("cenc"_s, buffer(both.span())), both.span());

    // Trailing bytes that hold no box header are ignored.
    static constexpr uint8_t trailing[] = { 0, 0, 0, 9, 'p', 's', 's' };
    auto withTrailingBytes = concatenate({ version1.span(), std::span { trailing } });
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(withTrailingBytes.span())), { 1, 2 });
    expectSame(registry().sanitizeInitData("cenc"_s, buffer(withTrailingBytes.span())), withTrailingBytes.span());

    auto otherBox = concatenate({ version1.span(), box("free"_s, { }).span() });
    EXPECT_FALSE(registry().extractKeyIDs("cenc"_s, buffer(otherBox.span())));
    EXPECT_FALSE(registry().sanitizeInitData("cenc"_s, buffer(otherBox.span())));

    auto tooManyKeyIDs = version1;
    tooManyKeyIDs[31] = 3;
    EXPECT_FALSE(registry().extractKeyIDs("cenc"_s, buffer(tooManyKeyIDs.span())));

    auto truncated = version1;
    truncated.shrink(truncated.size() - 1);
    EXPECT_FALSE(registry().extractKeyIDs("cenc"_s, buffer(truncated.span())));

    // Under 64 KB.
    Vector<uint8_t> largeData { FillWith { }, 65535 - 32, 0 };
    auto largest = pssh(std::span { commonSystemID }, 0, { }, largeData.span());
    ASSERT_EQ(largest.size(), 65535U);
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(largest.span())), { });
    largeData.append(0);
    auto tooLarge = pssh(std::span { commonSystemID }, 0, { }, largeData.span());
    EXPECT_FALSE(registry().extractKeyIDs("cenc"_s, buffer(tooLarge.span())));
    EXPECT_FALSE(registry().sanitizeInitData("cenc"_s, buffer(tooLarge.span())));
}

#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
TEST(InitDataRegistry, CencFairPlay)
{
    // The FairPlay request key IDs come first, then the pssh's own.
    auto fairPlay = pssh(std::span { fairPlaySystemID }, 1, { 3 }, fairPlayInitData("cbcs"_s, { 1, 2 }).span());
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(fairPlay.span())), { 1, 2, 3 });
    auto mixed = concatenate({ pssh(std::span { commonSystemID }, 1, { 4 }, { }).span(), fairPlay.span() });
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(mixed.span())), { 4, 1, 2, 3 });
    expectSame(registry().sanitizeInitData("cenc"_s, buffer(mixed.span())), mixed.span());

    for (auto scheme : { "cbcs"_s, "cbc2"_s, "cbc1"_s, "cenc"_s }) {
        auto box = pssh(std::span { fairPlaySystemID }, 0, { }, fairPlayInitData(scheme, { 5 }).span());
        expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(box.span())), { 5 });
    }
    // Requests with another scheme have no key IDs.
    auto otherScheme = pssh(std::span { fairPlaySystemID }, 1, { 6 }, fairPlayInitData("cens"_s, { 5 }).span());
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(otherScheme.span())), { 6 });

    // A pssh with FairPlay's system ID must hold FairPlay init data, which other system IDs needn't.
    auto notFairPlayInitData = pssh(std::span { fairPlaySystemID }, 1, { 7 }, bytes("data"_s));
    EXPECT_FALSE(registry().extractKeyIDs("cenc"_s, buffer(notFairPlayInitData.span())));
    EXPECT_FALSE(registry().sanitizeInitData("cenc"_s, buffer(notFairPlayInitData.span())));
    auto otherSystem = pssh(std::span { commonSystemID }, 1, { 7 }, fairPlayInitData("cbcs"_s, { 8 }).span());
    expectKeyIDs(registry().extractKeyIDs("cenc"_s, buffer(otherSystem.span())), { 7 });
}

TEST(InitDataRegistry, ExtractFairPlayPsshFromCenc)
{
    auto fairPlay = pssh(std::span { fairPlaySystemID }, 0, { }, fairPlayInitData("cbcs"_s, { 1 }).span());
    auto common = pssh(std::span { commonSystemID }, 1, { 2 }, { });
    expectSame(InitDataRegistry::extractFairPlayPsshFromCenc(buffer(fairPlay.span())), fairPlay.span());
    auto commonFirst = concatenate({ common.span(), fairPlay.span(), common.span() });
    expectSame(InitDataRegistry::extractFairPlayPsshFromCenc(buffer(commonFirst.span())), fairPlay.span());
    EXPECT_FALSE(InitDataRegistry::extractFairPlayPsshFromCenc(buffer(common.span())));

    // The boxes before it are only stepped over.
    auto brokenCommon = common;
    brokenCommon[31] = 9;
    auto afterBrokenBox = concatenate({ brokenCommon.span(), fairPlay.span() });
    EXPECT_FALSE(registry().extractKeyIDs("cenc"_s, buffer(afterBrokenBox.span())));
    expectSame(InitDataRegistry::extractFairPlayPsshFromCenc(buffer(afterBrokenBox.span())), fairPlay.span());

    auto afterOtherBox = concatenate({ box("free"_s, { }).span(), fairPlay.span() });
    EXPECT_FALSE(InitDataRegistry::extractFairPlayPsshFromCenc(buffer(afterOtherBox.span())));

    Vector<uint8_t> largeData { FillWith { }, 65536, 0 };
    auto tooLarge = concatenate({ fairPlay.span(), pssh(std::span { commonSystemID }, 0, { }, largeData.span()).span() });
    EXPECT_FALSE(InitDataRegistry::extractFairPlayPsshFromCenc(buffer(tooLarge.span())));
}
#endif

TEST(InitDataRegistry, WebM)
{
    auto keyID16 = keyID(1);
    expectKeyIDs(registry().extractKeyIDs("webm"_s, buffer(keyID16.span())), { 1 });
    expectSame(registry().sanitizeInitData("webm"_s, buffer(keyID16.span())), keyID16.span());

    Vector<uint8_t> largest { FillWith { }, 65536, 2 };
    expectSame(registry().sanitizeInitData("webm"_s, buffer(largest.span())), largest.span());
    largest.append(2);
    EXPECT_FALSE(registry().sanitizeInitData("webm"_s, buffer(largest.span())));
    EXPECT_FALSE(registry().extractKeyIDs("webm"_s, buffer(largest.span())));
}

TEST(InitDataRegistry, TypeNames)
{
    auto keyID16 = keyID(1);
    EXPECT_TRUE(registry().extractKeyIDs(utf16("webm"_s), buffer(keyID16.span())));
    EXPECT_TRUE(registry().sanitizeInitData(utf16("cenc"_s), buffer(pssh(std::span { commonSystemID }, 0, { }, { }).span())));
    for (auto type : { "WEBM"_s, "webm "_s, "web"_s, "Cenc"_s, "keyIDs"_s, "clearkey"_s, ""_s }) {
        EXPECT_FALSE(registry().extractKeyIDs(type, buffer(keyID16.span())));
        EXPECT_FALSE(registry().sanitizeInitData(type, buffer(keyID16.span())));
    }
    static constexpr char16_t webmAndSnowman[] = { 'w', 'e', 'b', 'm', 0x2603 };
    EXPECT_FALSE(registry().extractKeyIDs(String { std::span { webmAndSnowman } }, buffer(keyID16.span())));
    EXPECT_FALSE(registry().extractKeyIDs(emptyString(), buffer(keyID16.span())));

#if USE(AVFOUNDATION)
    CDMFactory::registeredFactories();
    static constexpr uint8_t skd[] = { 's', 'k', 'd' };
    expectSame(registry().sanitizeInitData(utf16("skd"_s), buffer(std::span { skd })), std::span { skd });
    EXPECT_FALSE(registry().sanitizeInitData("SKD"_s, buffer(std::span { skd })));
    EXPECT_FALSE(registry().extractKeyIDs("sinf"_s, buffer("{\"sinf\":[]}"_s)));
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    auto mpts = registry().extractKeyIDs("mpts"_s, buffer("{\"codc\":1,\"mtyp\":2,\"cont\":\"mpts\"}"_s));
    ASSERT_TRUE(mpts);
    EXPECT_EQ(mpts->size(), 1U);
    EXPECT_TRUE(registry().sanitizeInitData("mpts"_s, buffer("x"_s)));
#endif
#endif
}

// A null init data type is not found.
TEST(InitDataRegistry, NullType)
{
    auto keyID16 = keyID(1);
    EXPECT_FALSE(registry().extractKeyIDs(String { }, buffer(keyID16.span())));
    EXPECT_FALSE(registry().sanitizeInitData(String { }, buffer(keyID16.span())));
}

TEST(InitDataRegistry, EmptyInitData)
{
#if USE(AVFOUNDATION)
    CDMFactory::registeredFactories();
#endif
    for (auto& empty : emptyBuffers()) {
        EXPECT_FALSE(registry().extractKeyIDs("keyids"_s, empty));
        EXPECT_FALSE(registry().sanitizeInitData("keyids"_s, empty));
        expectKeyIDs(registry().extractKeyIDs("cenc"_s, empty), { });
        auto sanitized = registry().sanitizeInitData("cenc"_s, empty);
        ASSERT_TRUE(sanitized);
        EXPECT_TRUE(sanitized->isEmpty());
        EXPECT_FALSE(registry().extractKeyIDs("webm"_s, empty));
        EXPECT_FALSE(registry().sanitizeInitData("webm"_s, empty));
        EXPECT_FALSE(registry().extractKeyIDs("other"_s, empty));
#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
        EXPECT_FALSE(InitDataRegistry::extractFairPlayPsshFromCenc(empty));
#endif
#if USE(AVFOUNDATION)
        EXPECT_FALSE(registry().extractKeyIDs("sinf"_s, empty));
        auto skd = registry().extractKeyIDs("skd"_s, empty);
        ASSERT_TRUE(skd);
        ASSERT_EQ(skd->size(), 1U);
        EXPECT_TRUE((*skd)[0]->isEmpty());
#endif
    }
}

#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
class InitDataRegistryTestClient final : public CDMPrivateClient {
public:
    InitDataRegistryTestClient()
        : m_logger(Logger::create(this))
    {
    }

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger.get(); }
#endif

private:
    Ref<Logger> m_logger;
};

TEST(InitDataRegistry, FairPlaySupportsCenc)
{
    static NeverDestroyed<InitDataRegistryTestClient> client;
    std::unique_ptr<CDMPrivate> cdm;
    for (auto& factory : CDMFactory::registeredFactories()) {
        if (factory->supportsKeySystem("com.apple.fps"_s))
            cdm = factory->createCDM("com.apple.fps"_s, emptyString(), client.get());
    }
    ASSERT_TRUE(cdm);

    auto fairPlay = pssh(std::span { fairPlaySystemID }, 0, { }, fairPlayInitData("cens"_s, { }).span());
    auto common = pssh(std::span { commonSystemID }, 1, { 2 }, { });
    EXPECT_TRUE(cdm->supportsInitData("cenc"_s, buffer(fairPlay.span())));
    EXPECT_TRUE(cdm->supportsInitData("cenc"_s, buffer(concatenate({ common.span(), fairPlay.span() }).span())));
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(common.span())));
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(concatenate({ fairPlay.span(), box("free"_s, { }).span() }).span())));
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(pssh(std::span { fairPlaySystemID }, 0, { }, bytes("data"_s)).span())));
}
#endif

} // namespace TestWebKitAPI

#endif // ENABLE(ENCRYPTED_MEDIA)
