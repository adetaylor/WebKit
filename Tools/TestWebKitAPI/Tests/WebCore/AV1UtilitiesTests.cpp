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

#include <WebCore/AV1Utilities.h>
#include <WebCore/PlatformMediaCapabilitiesVideoConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/TrackInfo.h>
#include <wtf/Vector.h>

namespace TestWebKitAPI {
using namespace WebCore;

// obu_type=1 (sequence header), has_size_field=1.
static constexpr uint8_t sequenceHeaderOBUHeader = 0x0A;
// obu_size ULEB128 for the 4-byte payload.
static constexpr uint8_t sequenceHeaderOBUSize = 0x04;

static Vector<char16_t> widened(ASCIILiteral literal)
{
    Vector<char16_t> characters;
    for (auto character : literal.span())
        characters.append(character);
    return characters;
}

// The `>=` bounds check in getSequenceHeaderOBU() rejected an OBU ending exactly at the buffer end.
// The payload { 0x18, 0x00, 0x30, 0x00 } is a minimal reduced_still_picture_header for a 2x2 stream.
TEST(AV1Utilities, SequenceHeaderOBUExactlyFillsBuffer)
{
    std::array<uint8_t, 6> stream { sequenceHeaderOBUHeader, sequenceHeaderOBUSize, 0x18, 0x00, 0x30, 0x00 };
    auto videoInfo = createVideoInfoFromAV1Stream(stream);
    ASSERT_NE(videoInfo, nullptr);
    EXPECT_EQ(videoInfo->size(), FloatSize(2, 2));
}

TEST(AV1Utilities, SequenceHeaderOBUFollowedByTrailingData)
{
    std::array<uint8_t, 8> stream { sequenceHeaderOBUHeader, sequenceHeaderOBUSize, 0x18, 0x00, 0x30, 0x00, 0x12, 0x00 };
    auto videoInfo = createVideoInfoFromAV1Stream(stream);
    ASSERT_NE(videoInfo, nullptr);
    EXPECT_EQ(videoInfo->size(), FloatSize(2, 2));
}

TEST(AV1Utilities, SequenceHeaderOBUPayloadExceedsBuffer)
{
    std::array<uint8_t, 5> stream { sequenceHeaderOBUHeader, sequenceHeaderOBUSize, 0x18, 0x00, 0x30 };
    EXPECT_EQ(createVideoInfoFromAV1Stream(stream), nullptr);
}

// Swift traps on an empty span with no base address passed back to C++, so each shell is fed one.
TEST(AV1Utilities, EmptyInput)
{
    Vector<char16_t> emptyCharacters;
    for (auto string : { StringView { }, StringView { emptyString() }, StringView { emptyCharacters.span() } }) {
        EXPECT_FALSE(parseAV1CodecParameters(string));
        EXPECT_FALSE(parseAV1ProfileString(string));
        EXPECT_FALSE(parseAV1LevelString(string));
    }
    EXPECT_FALSE(parseAV1CodecParameters("...."_s));

    Vector<uint8_t> emptyBytes;
    static constexpr uint8_t oneByte[] = { 0 };
    for (auto bytes : { std::span<const uint8_t> { }, emptyBytes.span(), std::span { oneByte }.first(0) }) {
        EXPECT_FALSE(parseAV1DecoderConfigurationRecord(bytes));
        EXPECT_EQ(createVideoInfoFromAV1Stream(bytes), nullptr);
    }

    std::array<uint8_t, 2> emptySequenceHeader { sequenceHeaderOBUHeader, 0x00 };
    EXPECT_EQ(createVideoInfoFromAV1Stream(emptySequenceHeader), nullptr);
}

TEST(AV1Utilities, ParseCodecParameters)
{
    auto record = parseAV1CodecParameters("av01.0.04M.08"_s);
    ASSERT_TRUE(record);
    AV1CodecConfigurationRecord defaults;
    EXPECT_EQ(record->codecName, "av01"_s);
    EXPECT_TRUE(record->profile == AV1ConfigurationProfile::Main);
    EXPECT_TRUE(record->level == AV1ConfigurationLevel::Level_3_0);
    EXPECT_TRUE(record->tier == AV1ConfigurationTier::Main);
    EXPECT_EQ(record->bitDepth, 8);
    EXPECT_EQ(record->monochrome, defaults.monochrome);
    EXPECT_EQ(record->chromaSubsampling, defaults.chromaSubsampling);
    EXPECT_EQ(record->colorPrimaries, defaults.colorPrimaries);
    EXPECT_EQ(record->transferCharacteristics, defaults.transferCharacteristics);
    EXPECT_EQ(record->matrixCoefficients, defaults.matrixCoefficients);
    EXPECT_TRUE(record->videoFullRangeFlag == defaults.videoFullRangeFlag);

    record = parseAV1CodecParameters("av01.2.19H.12.1.110.09.16.09.1"_s);
    ASSERT_TRUE(record);
    EXPECT_TRUE(record->profile == AV1ConfigurationProfile::Professional);
    EXPECT_TRUE(record->level == AV1ConfigurationLevel::Level_6_3);
    EXPECT_TRUE(record->tier == AV1ConfigurationTier::High);
    EXPECT_EQ(record->bitDepth, 12);
    EXPECT_EQ(record->monochrome, 1);
    EXPECT_EQ(record->chromaSubsampling, 110);
    EXPECT_EQ(record->colorPrimaries, 9);
    EXPECT_EQ(record->transferCharacteristics, 16);
    EXPECT_EQ(record->matrixCoefficients, 9);
    EXPECT_TRUE(record->videoFullRangeFlag == AV1ConfigurationRange::FullRange);

    // WTF's parseInteger() and StringView::split() leniencies.
    record = parseAV1CodecParameters("av01..+1.08H. 10\t"_s);
    ASSERT_TRUE(record);
    EXPECT_TRUE(record->profile == AV1ConfigurationProfile::High);
    EXPECT_TRUE(record->level == AV1ConfigurationLevel::Level_4_0);
    EXPECT_EQ(record->bitDepth, 10);

    // The optional fields may stop early, except after matrixCoefficients.
    EXPECT_TRUE(parseAV1CodecParameters("av01.0.04M.08.0"_s));
    EXPECT_TRUE(parseAV1CodecParameters("av01.0.04M.08.0.110.01.01"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.110.01.01.01"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.110.01.01.01.0.0"_s));

    EXPECT_TRUE(parseAV1CodecParameters("av01.0.31M.08"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.24M.08"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.3.04M.08"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04X.08"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.4M.08"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.13"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M"_s));
    EXPECT_FALSE(parseAV1CodecParameters("AV01.0.04M.08"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.2"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.113"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.110.03"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.110.01.03"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.110.01.01.03"_s));
    EXPECT_FALSE(parseAV1CodecParameters("av01.0.04M.08.0.110.01.01.01.2"_s));

    auto characters = widened("av01.1.08M.10.0.000.01.13.00.1"_s);
    record = parseAV1CodecParameters(StringView { characters.span() });
    ASSERT_TRUE(record);
    EXPECT_EQ(record->codecName, "av01"_s);
    EXPECT_TRUE(record->profile == AV1ConfigurationProfile::High);
    EXPECT_EQ(record->transferCharacteristics, 13);
    EXPECT_EQ(record->matrixCoefficients, 0);
    characters.append(0x2603);
    EXPECT_FALSE(parseAV1CodecParameters(StringView { characters.span() }));
}

TEST(AV1Utilities, CreateCodecParametersString)
{
    // The short form exactly when the optional fields have the record's defaults.
    EXPECT_EQ(createAV1CodecParametersString(AV1CodecConfigurationRecord { }), "av01.0.00M.08"_s);
    EXPECT_EQ(createAV1CodecParametersString(*parseAV1CodecParameters("av01.2.19H.12.1.110.09.16.09.1"_s)), "av01.2.19H.12.1.110.09.16.09.1"_s);

    AV1CodecConfigurationRecord record;
    record.videoFullRangeFlag = AV1ConfigurationRange::FullRange;
    EXPECT_EQ(createAV1CodecParametersString(record), "av01.0.00M.08.0.110.01.01.01.1"_s);

    // Values outside the enumerations keep their last digits, and any tier but Main is H.
    record.profile = static_cast<AV1ConfigurationProfile>(12);
    record.level = static_cast<AV1ConfigurationLevel>(123);
    record.tier = static_cast<AV1ConfigurationTier>(7);
    record.bitDepth = 255;
    record.monochrome = 9;
    record.chromaSubsampling = 255;
    record.colorPrimaries = 100;
    record.videoFullRangeFlag = static_cast<AV1ConfigurationRange>(13);
    EXPECT_EQ(createAV1CodecParametersString(record), "av01.2.23H.55.9.255.00.01.01.3"_s);
}

TEST(AV1Utilities, ValidateConfigurationRecord)
{
    auto validate = [](ASCIILiteral codec) {
        auto record = parseAV1CodecParameters(codec);
        return record && validateAV1ConfigurationRecord(*record);
    };
    EXPECT_TRUE(validate("av01.0.04M.08"_s));
    EXPECT_TRUE(validate("av01.0.04M.10.0.112"_s));
    EXPECT_FALSE(validate("av01.0.04M.12"_s));
    EXPECT_FALSE(validate("av01.0.04M.08.0.000"_s));
    EXPECT_TRUE(validate("av01.1.04M.10.0.000"_s));
    EXPECT_FALSE(validate("av01.1.04M.08.1.000"_s));
    EXPECT_FALSE(validate("av01.1.04M.08.0.110"_s));
    EXPECT_TRUE(validate("av01.2.04M.12.0.100"_s));
    EXPECT_FALSE(validate("av01.2.04M.10.0.100"_s));
    EXPECT_FALSE(validate("av01.2.04M.11"_s));
    EXPECT_FALSE(validate("av01.0.04M.08.1.111"_s));

    // A profile outside the enumeration skips the profile checks.
    AV1CodecConfigurationRecord record;
    record.profile = static_cast<AV1ConfigurationProfile>(5);
    record.bitDepth = 3;
    EXPECT_TRUE(validateAV1ConfigurationRecord(record));
    record.chromaSubsampling = 1;
    EXPECT_FALSE(validateAV1ConfigurationRecord(record));
}

TEST(AV1Utilities, PerLevelConstraints)
{
    auto record = *parseAV1CodecParameters("av01.0.08M.08"_s);
    PlatformMediaCapabilitiesVideoConfiguration configuration;
    configuration.width = 1920;
    configuration.height = 1080;
    configuration.framerate = 30;
    configuration.bitrate = 10'000'000;
    EXPECT_TRUE(validateAV1PerLevelConstraints(record, configuration));

    configuration.framerate = 60;
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
    configuration.framerate = std::numeric_limits<double>::quiet_NaN();
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
    configuration.framerate = 30;

    configuration.bitrate = 20'000'000;
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
    record.tier = AV1ConfigurationTier::High;
    EXPECT_TRUE(validateAV1PerLevelConstraints(record, configuration));

    configuration.width = 6145;
    configuration.height = 1;
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
    configuration.width = 1;
    configuration.height = 3457;
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
    configuration.width = 6144;
    configuration.height = 384;
    EXPECT_TRUE(validateAV1PerLevelConstraints(record, configuration));
    configuration.height = 385;
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
    configuration.height = 1;

    record.level = AV1ConfigurationLevel::Level_2_2;
    EXPECT_FALSE(validateAV1PerLevelConstraints(record, configuration));
}

TEST(AV1Utilities, ParseDecoderConfigurationRecord)
{
    std::array<uint8_t, 6> av1C { 0x81, 0x48, 0x4E, 0x00, 0x0A, 0x00 };
    auto record = parseAV1DecoderConfigurationRecord(av1C);
    ASSERT_TRUE(record);
    AV1CodecConfigurationRecord defaults;
    EXPECT_EQ(record->codecName, "av01"_s);
    EXPECT_TRUE(record->profile == AV1ConfigurationProfile::Professional);
    EXPECT_TRUE(record->level == AV1ConfigurationLevel::Level_4_0);
    EXPECT_TRUE(record->tier == AV1ConfigurationTier::Main);
    EXPECT_EQ(record->bitDepth, 10);
    EXPECT_EQ(record->monochrome, 0);
    EXPECT_EQ(record->chromaSubsampling, 112);
    EXPECT_EQ(record->colorPrimaries, defaults.colorPrimaries);
    EXPECT_EQ(record->width, 0u);
    EXPECT_EQ(record->height, 0u);

    auto parse = [](std::array<uint8_t, 4> bytes) {
        return parseAV1DecoderConfigurationRecord(bytes);
    };
    EXPECT_TRUE(parse({ 0x81, 0x5F, 0xF0, 0x00 }));
    EXPECT_FALSE(parse({ 0x01, 0x48, 0x4E, 0x00 }));
    EXPECT_FALSE(parse({ 0x82, 0x48, 0x4E, 0x00 }));
    EXPECT_FALSE(parse({ 0x81, 0x68, 0x4E, 0x00 }));
    EXPECT_FALSE(parse({ 0x81, 0x18, 0x4E, 0x00 }));
    EXPECT_FALSE(parse({ 0x81, 0x48, 0x20, 0x00 }));
    EXPECT_FALSE(parseAV1DecoderConfigurationRecord(std::span { av1C }.first(3)));
}

TEST(AV1Utilities, ProfileAndLevelStrings)
{
    EXPECT_TRUE(parseAV1ProfileString("1"_s) == AV1ConfigurationProfile::High);
    EXPECT_TRUE(parseAV1ProfileString(" +2\n"_s) == AV1ConfigurationProfile::Professional);
    EXPECT_FALSE(parseAV1ProfileString("3"_s));
    EXPECT_FALSE(parseAV1ProfileString("1x"_s));
    EXPECT_FALSE(parseAV1ProfileString("-0"_s));

    EXPECT_TRUE(parseAV1LevelString("023"_s) == AV1ConfigurationLevel::Level_7_3);
    EXPECT_TRUE(parseAV1LevelString("31"_s) == AV1ConfigurationLevel::Level_Maximum);
    EXPECT_FALSE(parseAV1LevelString("24"_s));
    EXPECT_FALSE(parseAV1LevelString("287"_s));

    auto characters = widened("2"_s);
    EXPECT_TRUE(parseAV1ProfileString(StringView { characters.span() }) == AV1ConfigurationProfile::Professional);
    EXPECT_TRUE(parseAV1LevelString(StringView { characters.span() }) == AV1ConfigurationLevel::Level_2_2);
    characters.append(0x2603);
    EXPECT_FALSE(parseAV1ProfileString(StringView { characters.span() }));
    EXPECT_FALSE(parseAV1LevelString(StringView { characters.span() }));
}

TEST(AV1Utilities, VideoInfoFromStream)
{
    // A temporal delimiter, then the sequence header OBU with an extension byte and a two-byte obu_size.
    std::array<uint8_t, 11> stream { 0x12, 0x00, 0x0E, 0x00, 0x84, 0x00, 0x18, 0x00, 0x30, 0x00, 0xFF };
    auto videoInfo = createVideoInfoFromAV1Stream(stream);
    ASSERT_NE(videoInfo, nullptr);
    EXPECT_EQ(videoInfo->codecName(), FourCC(std::span { "av01" }));
    EXPECT_EQ(videoInfo->codecString(), "av01.0.00M.08.0.110.02.02.02.0"_s);
    EXPECT_EQ(videoInfo->size(), FloatSize(2, 2));
    EXPECT_EQ(videoInfo->displaySize(), FloatSize(2, 2));
    EXPECT_EQ(videoInfo->bitDepth(), 8);
    EXPECT_TRUE(videoInfo->colorSpace().primaries == PlatformVideoColorPrimaries::Unspecified);
    EXPECT_TRUE(videoInfo->colorSpace().transfer == PlatformVideoTransferCharacteristics::Unspecified);
    EXPECT_TRUE(videoInfo->colorSpace().matrix == PlatformVideoMatrixCoefficients::Unspecified);
    ASSERT_TRUE(videoInfo->colorSpace().fullRange);
    EXPECT_FALSE(*videoInfo->colorSpace().fullRange);
    ASSERT_EQ(videoInfo->extensionAtoms().size(), 1u);
    EXPECT_EQ(videoInfo->extensionAtoms()[0].first, FourCC(std::span { "av1C" }));
    std::array<uint8_t, 12> av1C { 0x81, 0x00, 0x0C, 0x00, 0x0E, 0x00, 0x84, 0x00, 0x18, 0x00, 0x30, 0x00 };
    EXPECT_TRUE(equalSpans(videoInfo->extensionAtoms()[0].second->span(), std::span<const uint8_t> { av1C }));

    PlatformVideoColorSpace colorSpaceOverride { .primaries = PlatformVideoColorPrimaries::Bt709, .fullRange = true };
    videoInfo = createVideoInfoFromAV1Stream(stream, FloatSize(4, 3), colorSpaceOverride);
    ASSERT_NE(videoInfo, nullptr);
    EXPECT_EQ(videoInfo->size(), FloatSize(2, 2));
    EXPECT_EQ(videoInfo->displaySize(), FloatSize(4, 3));
    EXPECT_TRUE(videoInfo->colorSpace().primaries == PlatformVideoColorPrimaries::Bt709);
    EXPECT_TRUE(videoInfo->colorSpace().transfer == PlatformVideoTransferCharacteristics::Unspecified);
    ASSERT_TRUE(videoInfo->colorSpace().fullRange);
    EXPECT_TRUE(*videoInfo->colorSpace().fullRange);

    // obu_forbidden_bit, no obu_has_size_field, an obu_size of 2^32 - 1 (read as 0 and so a 0-byte OBU).
    EXPECT_EQ(createVideoInfoFromAV1Stream(std::array<uint8_t, 2> { 0x8A, 0x00 }), nullptr);
    EXPECT_EQ(createVideoInfoFromAV1Stream(std::array<uint8_t, 2> { 0x08, 0x00 }), nullptr);
    EXPECT_EQ(createVideoInfoFromAV1Stream(std::array<uint8_t, 6> { 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }), nullptr);
}

} // namespace TestWebKitAPI
