/*
 * Copyright (C) 2018-2026 Apple Inc. All rights reserved.
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

#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)

#include <WebCore/CDMFactory.h>
#include <WebCore/CDMFairPlayStreaming.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/CDMPrivate.h>
#include <WebCore/CDMRestrictions.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/HexNumber.h>
#include <wtf/Logger.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/Base64.h>
#include <wtf/text/StringBuilder.h>

namespace TestWebKitAPI {
using namespace WebCore;

class FairPlayTestClient final : public CDMPrivateClient {
public:
    FairPlayTestClient()
        : m_logger(Logger::create(this))
    {
    }

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger.get(); }
#endif

private:
    Ref<Logger> m_logger;
};

// Also registers the 'sinf', 'skd' and 'mpts' init data types.
static std::unique_ptr<CDMPrivate> createFairPlayCDM()
{
    static NeverDestroyed<FairPlayTestClient> client;
    for (auto& factory : CDMFactory::registeredFactories()) {
        if (factory->supportsKeySystem("com.apple.fps"_s))
            return factory->createCDM("com.apple.fps"_s, emptyString(), client.get());
    }
    return nullptr;
}

static Ref<SharedBuffer> buffer(std::span<const uint8_t> bytes)
{
    return SharedBuffer::create(bytes);
}

static Ref<SharedBuffer> buffer(const String& text)
{
    return SharedBuffer::create(text.latin1().span());
}

static Vector<uint8_t> concatenate(std::initializer_list<std::span<const uint8_t>> parts)
{
    Vector<uint8_t> result;
    for (auto part : parts)
        result.append(part);
    return result;
}

static std::span<const uint8_t> bytes(ASCIILiteral literal)
{
    return byteCast<uint8_t>(literal.span8());
}

static Vector<uint8_t> box(ASCIILiteral type, std::span<const uint8_t> payload)
{
    uint32_t size = payload.size() + 8;
    Vector<uint8_t> result { static_cast<uint8_t>(size >> 24), static_cast<uint8_t>(size >> 16), static_cast<uint8_t>(size >> 8), static_cast<uint8_t>(size) };
    result.append(bytes(type));
    result.append(payload);
    return result;
}

static Vector<uint8_t> schm(ASCIILiteral scheme)
{
    static constexpr uint8_t versionAndFlags[] = { 0, 0, 0, 0 };
    static constexpr uint8_t schemeVersion[] = { 0, 1, 0, 0 };
    return box("schm"_s, concatenate({ std::span { versionAndFlags }, bytes(scheme), std::span { schemeVersion } }));
}

// A version 1 'schi' holding a 'tenc' whose default key ID is 16 times keyIDByte.
static Vector<uint8_t> schi(uint8_t keyIDByte)
{
    Vector<uint8_t> tenc { 1, 0, 0, 0, 0, 0x19, 1, 8 };
    tenc.grow(tenc.size() + 16);
    std::ranges::fill(tenc.mutableSpan().last(16), keyIDByte);
    return box("schi"_s, box("tenc"_s, tenc.span()).span());
}

static Vector<uint8_t> frma()
{
    return box("frma"_s, bytes("avc1"_s));
}

// {"sinf":[...]} with each payload in base64.
static Ref<SharedBuffer> sinfInitData(std::initializer_list<std::span<const uint8_t>> payloads)
{
    StringBuilder json;
    json.append("{\"sinf\":["_s);
    bool first = true;
    for (auto payload : payloads) {
        json.append(first ? ""_s : ","_s, '"', base64EncodeToString(payload), '"');
        first = false;
    }
    json.append("]}"_s);
    return buffer(json.toString());
}

static Vector<uint8_t> keyID(uint8_t byte)
{
    return Vector<uint8_t> { FillWith { }, 16, byte };
}

static void expectKeyIDs(const std::optional<Vector<Ref<SharedBuffer>>>& keyIDs, std::initializer_list<uint8_t> expectedBytes)
{
    ASSERT_TRUE(keyIDs);
    ASSERT_EQ(keyIDs->size(), expectedBytes.size());
    size_t index = 0;
    for (auto byte : expectedBytes)
        EXPECT_EQ(Vector<uint8_t> { (*keyIDs)[index++]->span() }, keyID(byte));
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

// The init data of LayoutTests/http/tests/media/fairplay/fps-init-data-sinf.html: frma 'mp4a', schm 'cbcs' and a tenc
// with an all-zero default key ID.
static constexpr auto layoutTestSinf = "{\"sinf\":[\"AAAADGZybWFtcDRhAAAAFHNjaG0AAAAAY2JjcwABAAAAAAA5c2NoaQAAADF0ZW5jAQAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAENwoLj77jCjwCAAw3SqKao8=\"]}"_s;

// A FairPlay pssh box from Tools/TestWebKitAPI/Tests/WebCore/ISOBox.cpp.
static constexpr auto fairPlayPssh = "AAAAsHBzc2gAAAAAlM6G+wf/T0OtuJPS+paMogAAAJAAAACQZnBzZAAAABBmcHNpAAAAAGNlbmMAAAA8ZnBzawAAABxma3JpAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAYZmthaQAAAAAAAAAAAAAAAAAAAPEAAAA8ZnBzawAAABxma3JpAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAYZmthaQAAAAAAAAAAAAAAAAAAAPI="_s;

TEST(CDMFairPlayStreaming, ExtractKeyIDsSinf)
{
    ASSERT_TRUE(createFairPlayCDM());

    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(buffer(layoutTestSinf)), { 0 });

    auto valid = concatenate({ frma().span(), schm("cbcs"_s).span(), schi(1).span() });
    auto invalidScheme = concatenate({ frma().span(), schm("cens"_s).span(), schi(2).span() });
    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ valid.span() })), { 1 });
    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ invalidScheme.span(), valid.span(), valid.span() })), { 1, 1 });
    // Entries with a scheme and a key ID, but no valid scheme, give no key IDs rather than none at all.
    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ invalidScheme.span() })), { });

    for (auto scheme : { "cbcs"_s, "cbc2"_s, "cbc1"_s, "cenc"_s }) {
        auto payload = concatenate({ schm(scheme).span(), schi(3).span() });
        expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ payload.span() })), { 3 });
    }

    // The last scheme and the last key ID win; a 'schi' without a 'tenc' keeps the key ID.
    auto lastSchemeValid = concatenate({ schm("cens"_s).span(), schi(4).span(), schm("cbcs"_s).span(), schi(5).span(), box("schi"_s, box("zzzz"_s, { }).span()).span() });
    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ lastSchemeValid.span() })), { 5 });
    auto lastSchemeInvalid = concatenate({ schm("cbcs"_s).span(), schi(4).span(), schm("cens"_s).span() });
    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ lastSchemeInvalid.span() })), { });

    // A 'schm' that doesn't parse ends the walk, keeping what came before.
    auto truncatedSchm = schm("cens"_s);
    truncatedSchm.shrink(truncatedSchm.size() - 1);
    auto endsEarly = concatenate({ schm("cbcs"_s).span(), schi(6).span(), truncatedSchm.span() });
    expectKeyIDs(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ endsEarly.span() })), { 6 });

    // Other boxes are stepped over by their size, even one smaller than a box header.
    static constexpr uint8_t tinyBox[] = { 0, 0, 0, 7, 'z', 'z', 'z' };
    auto afterTinyBox = concatenate({ std::span { tinyBox }, schm("cbcs"_s).span(), schi(7).span() });
    EXPECT_TRUE(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ afterTinyBox.span() })));

    // A whole 'sinf' box is one box to step over.
    auto wholeBox = box("sinf"_s, valid.span());
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ wholeBox.span() })));

    auto noKeyID = concatenate({ frma().span(), schm("cbcs"_s).span() });
    auto noScheme = concatenate({ frma().span(), schi(8).span() });
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ noKeyID.span(), noScheme.span() })));
}

TEST(CDMFairPlayStreaming, ExtractKeyIDsSinfJSON)
{
    ASSERT_TRUE(createFairPlayCDM());

    // 68 bytes, so the base64 is padded.
    auto valid = base64EncodeToString(concatenate({ schm("cbcs"_s).span(), schi(9).span(), box("free"_s, { }).span() }));
    auto extract = [](const String& json) {
        return CDMPrivateFairPlayStreaming::extractKeyIDsSinf(buffer(json));
    };
    expectKeyIDs(extract(makeString("{\"sinf\":[1,null,{},\""_s, valid, "\"]}"_s)), { 9 });
    expectKeyIDs(extract(makeString("{\"other\":0,\"sinf\":[\""_s, valid, "\"]}"_s)), { 9 });

    // Whitespace is ignored. Padding is optional, but must be right when present.
    StringBuilder spaced;
    for (unsigned i = 0; i < valid.length(); ++i) {
        spaced.append(valid[i]);
        if (i % 5 == 4)
            spaced.append(i % 2 ? " "_s : "\\n"_s);
    }
    expectKeyIDs(extract(makeString("{\"sinf\":[\""_s, spaced.toString(), "\"]}"_s)), { 9 });
    auto unpadded = valid;
    while (unpadded.endsWith('='))
        unpadded = unpadded.left(unpadded.length() - 1);
    EXPECT_NE(unpadded, valid);
    expectKeyIDs(extract(makeString("{\"sinf\":[\""_s, unpadded, "\"]}"_s)), { 9 });
    EXPECT_FALSE(extract(makeString("{\"sinf\":[\""_s, valid, "=\"]}"_s)));

    // Escapes, including one outside Latin-1 that makes the string 16-bit and the base64 invalid.
    StringBuilder escaped;
    for (auto character : StringView { valid }.codeUnits())
        escaped.append("\\u00"_s, hex(static_cast<uint8_t>(character), 2));
    expectKeyIDs(extract(makeString("{\"sinf\":[\""_s, escaped.toString(), "\"]}"_s)), { 9 });
    EXPECT_FALSE(extract(makeString("{\"sinf\":[\""_s, valid, "\\u2603\"]}"_s)));

    EXPECT_FALSE(extract("{\"sinf\":[]}"_s));
    EXPECT_FALSE(extract("{\"sinf\":[\"\"]}"_s));
    EXPECT_FALSE(extract("{\"sinf\":\"AAAA\"}"_s));
    EXPECT_FALSE(extract("[]"_s));
    EXPECT_FALSE(extract("{"_s));
    EXPECT_FALSE(extract(makeString("{\"SINF\":[\""_s, valid, "\"]}"_s)));
}

TEST(CDMFairPlayStreaming, ExtractKeyIDsMptsAndSkd)
{
    ASSERT_TRUE(createFairPlayCDM());

#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    auto keyIDs = CDMPrivateFairPlayStreaming::extractKeyIDsMpts(buffer("{\"codc\":1,\"mtyp\":2,\"cont\":\"mpts\"}"_s));
    ASSERT_TRUE(keyIDs);
    ASSERT_EQ(keyIDs->size(), 1U);
    EXPECT_EQ(Vector<uint8_t> { (*keyIDs)[0]->span() }, Vector<uint8_t> { bytes("TransportStreamIdentifier"_s) });
    EXPECT_TRUE(CDMPrivateFairPlayStreaming::extractKeyIDsMpts(buffer("{\"codc\":1.5,\"mtyp\":-2,\"cont\":\"mpts\"}"_s)));
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsMpts(buffer("{\"codc\":1,\"mtyp\":2,\"cont\":\"MPTS\"}"_s)));
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsMpts(buffer("{\"mtyp\":2,\"cont\":\"mpts\"}"_s)));
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsMpts(buffer("{\"codc\":\"1\",\"mtyp\":2,\"cont\":\"mpts\"}"_s)));
#endif

    static constexpr uint8_t skd[] = { 's', 'k', 'd', ':', '/', '/', 'k' };
    auto skdKeyIDs = CDMPrivateFairPlayStreaming::extractKeyIDsSkd(buffer(std::span { skd }));
    ASSERT_TRUE(skdKeyIDs);
    ASSERT_EQ(skdKeyIDs->size(), 1U);
    EXPECT_EQ(Vector<uint8_t> { (*skdKeyIDs)[0]->span() }, Vector<uint8_t> { std::span { skd } });
}

TEST(CDMFairPlayStreaming, EmptyInitData)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    for (auto& empty : emptyBuffers()) {
        EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(empty));
        auto skdKeyIDs = CDMPrivateFairPlayStreaming::extractKeyIDsSkd(empty);
        ASSERT_TRUE(skdKeyIDs);
        ASSERT_EQ(skdKeyIDs->size(), 1U);
        EXPECT_TRUE((*skdKeyIDs)[0]->isEmpty());
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
        EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsMpts(empty));
        EXPECT_TRUE(cdm->supportsInitData("mpts"_s, empty));
#endif
        EXPECT_FALSE(cdm->supportsInitData("sinf"_s, empty));
        EXPECT_TRUE(cdm->supportsInitData("skd"_s, empty));
        EXPECT_FALSE(cdm->supportsInitData("cenc"_s, empty));
        EXPECT_FALSE(cdm->supportsInitData("keyids"_s, empty));
    }

    // Empty entries, and entries that decode to nothing.
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(sinfInitData({ std::span { emptyBytes }.first(0) })));
    EXPECT_FALSE(CDMPrivateFairPlayStreaming::extractKeyIDsSinf(buffer("{\"sinf\":[\" \\n \"]}"_s)));
    EXPECT_FALSE(cdm->supportsInitData("sinf"_s, buffer("{\"sinf\":[\"\"]}"_s)));
}

TEST(CDMFairPlayStreaming, SupportsInitData)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    EXPECT_TRUE(cdm->supportsInitData("sinf"_s, buffer(layoutTestSinf)));
    EXPECT_TRUE(cdm->supportsInitData(utf16("sinf"_s), buffer(layoutTestSinf)));
    EXPECT_FALSE(cdm->supportsInitData("SINF"_s, buffer(layoutTestSinf)));
    EXPECT_FALSE(cdm->supportsInitData("sinf "_s, buffer(layoutTestSinf)));
    EXPECT_FALSE(cdm->supportsInitData("keyids"_s, buffer(layoutTestSinf)));
    EXPECT_FALSE(cdm->supportsInitData("webm"_s, buffer(layoutTestSinf)));
    EXPECT_FALSE(cdm->supportsInitData(emptyString(), buffer(layoutTestSinf)));

    auto invalidScheme = concatenate({ schm("cens"_s).span(), schi(1).span() });
    EXPECT_FALSE(cdm->supportsInitData("sinf"_s, sinfInitData({ invalidScheme.span() })));

    static constexpr uint8_t keyID[] = { 1 };
    EXPECT_TRUE(cdm->supportsInitData("skd"_s, buffer(std::span { keyID })));
    EXPECT_TRUE(cdm->supportsInitData(utf16("skd"_s), buffer(std::span { keyID })));

#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
    auto pssh = base64Decode(StringView { fairPlayPssh });
    ASSERT_TRUE(pssh);
    EXPECT_TRUE(cdm->supportsInitData("cenc"_s, buffer(pssh->span())));
    auto otherSystem = *pssh;
    otherSystem[12] = 0xed;
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(otherSystem.span())));
#endif

#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    EXPECT_TRUE(cdm->supportsInitData("mpts"_s, buffer(std::span { keyID })));
#endif
}

// A null init data type is not supported.
TEST(CDMFairPlayStreaming, NullInitDataType)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    EXPECT_FALSE(cdm->supportsInitData(String { }, buffer(layoutTestSinf)));
    CDMKeySystemConfiguration configuration;
    configuration.initDataTypes = { AtomString { } };
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.initDataTypes.append("skd"_s);
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
}

TEST(CDMFairPlayStreaming, SupportedInitDataTypes)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    auto types = cdm->supportedInitDataTypes();
    EXPECT_TRUE(types.contains("sinf"_s));
    EXPECT_TRUE(types.contains("skd"_s));
    size_t expectedCount = 2;
#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
    EXPECT_TRUE(types.contains("cenc"_s));
    ++expectedCount;
#endif
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    EXPECT_TRUE(types.contains("mpts"_s));
    ++expectedCount;
#endif
    EXPECT_EQ(types.size(), expectedCount);
}

static CDMKeySystemConfiguration layoutTestConfiguration()
{
    CDMKeySystemConfiguration configuration;
    configuration.initDataTypes = { "sinf"_s };
    configuration.videoCapabilities = { { "video/mp4"_s, emptyString(), std::nullopt } };
    configuration.distinctiveIdentifier = CDMRequirement::NotAllowed;
    configuration.persistentState = CDMRequirement::NotAllowed;
    configuration.sessionTypes = { CDMSessionType::Temporary };
    return configuration;
}

TEST(CDMFairPlayStreaming, SupportsConfiguration)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    EXPECT_TRUE(cdm->supportsConfiguration(layoutTestConfiguration()));

    auto configuration = layoutTestConfiguration();
    configuration.initDataTypes = { "keyids"_s };
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.initDataTypes = { };
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.initDataTypes = { "keyids"_s, AtomString { utf16("skd"_s) } };
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));

    configuration = layoutTestConfiguration();
    configuration.distinctiveIdentifier = CDMRequirement::Required;
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.distinctiveIdentifier = CDMRequirement::Optional;
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));

    configuration = layoutTestConfiguration();
    configuration.videoCapabilities = { { "video/mp4"_s, emptyString(), CDMEncryptionScheme::cenc } };
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.videoCapabilities.append({ "video/mp4"_s, emptyString(), CDMEncryptionScheme::cbcs });
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
    configuration.audioCapabilities = { { "application/x-not-a-type"_s, emptyString(), std::nullopt } };
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.audioCapabilities = { };
    configuration.videoCapabilities = { };
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));

#if PLATFORM(MAC)
    // Persistent keys are iOS-only.
    configuration = layoutTestConfiguration();
    configuration.sessionTypes = { CDMSessionType::PersistentLicense };
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.sessionTypes.append(CDMSessionType::Temporary);
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
#endif

    EXPECT_EQ(cdm->distinctiveIdentifiersRequirement(configuration, { }), CDMRequirement::NotAllowed);
    EXPECT_EQ(cdm->persistentStateRequirement(configuration, { }), CDMRequirement::Optional);
    EXPECT_TRUE(cdm->distinctiveIdentifiersAreUniquePerOriginAndClearable(configuration));
}

TEST(CDMFairPlayStreaming, SupportsConfigurationWithRestrictions)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    auto configuration = layoutTestConfiguration();
    CDMRestrictions restrictions;
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));

    // Every requested session type denied, which includes requesting none.
    restrictions.deniedSessionTypes.add(CDMSessionType::Temporary);
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.sessionTypes.append(CDMSessionType::PersistentUsageRecord);
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.sessionTypes = { };
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, { }));

    // Denied persistent state allows only temporary sessions, and not required persistent state.
    configuration = layoutTestConfiguration();
    restrictions = { };
    restrictions.persistentStateDenied = true;
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.sessionTypes = { CDMSessionType::PersistentUsageRecord };
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.sessionTypes = { CDMSessionType::PersistentUsageRecord, CDMSessionType::Temporary };
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.persistentState = CDMRequirement::Required;
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));

    // The configuration itself must be supported too.
    configuration = layoutTestConfiguration();
    configuration.initDataTypes = { "webm"_s };
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, { }));
}

TEST(CDMFairPlayStreaming, SupportsSessionTypeWithConfiguration)
{
    auto cdm = createFairPlayCDM();
    ASSERT_TRUE(cdm);

    auto configuration = layoutTestConfiguration();
    EXPECT_TRUE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::Temporary, configuration));
    EXPECT_FALSE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::PersistentLicense, configuration));
    EXPECT_FALSE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::PersistentUsageRecord, configuration));
    configuration.persistentState = CDMRequirement::Optional;
    EXPECT_TRUE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::PersistentLicense, configuration));
    EXPECT_TRUE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::PersistentUsageRecord, configuration));
    configuration.persistentState = CDMRequirement::Required;
    EXPECT_FALSE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::Temporary, configuration));
    configuration.persistentState = CDMRequirement::Optional;
    configuration.initDataTypes = { "keyids"_s };
    EXPECT_FALSE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::Temporary, configuration));
}

} // namespace TestWebKitAPI

#endif // ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
