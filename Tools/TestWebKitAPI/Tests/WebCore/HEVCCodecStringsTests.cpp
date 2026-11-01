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

#include <WebCore/FourCC.h>
#include <WebCore/HEVCUtilities.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/text/StringView.h>

namespace TestWebKitAPI {
using namespace WebCore;

static constexpr FourCC hvc1 { std::span { "hvc1" } };
static constexpr FourCC hev1 { std::span { "hev1" } };

static Vector<char16_t> widened(ASCIILiteral string)
{
    Vector<char16_t> characters;
    for (auto character : string.span())
        characters.append(character);
    return characters;
}

static Ref<SharedBuffer> makeBuffer(std::span<const uint8_t> data)
{
    return SharedBuffer::create(data);
}

static Vector<size_t> flatten(std::span<const uint8_t> hvcc, const HVCCParameterSets& sets)
{
    Vector<size_t> result;
    result.append(sets.lengthFieldSize);
    for (auto& set : sets.paramSets)
        result.appendList({ static_cast<size_t>(set.type), static_cast<size_t>(set.data.data() - hvcc.data()), set.data.size() });
    return result;
}

// Swift traps on an empty span with no base address passed back to C++, so each shell is fed one.
TEST(HEVCUtilities, EmptyInput)
{
    for (auto codec : { StringView { }, StringView { ""_s }, StringView { std::span<const char16_t> { } } }) {
        EXPECT_FALSE(parseAVCCodecParameters(codec));
        EXPECT_FALSE(parseHEVCCodecParameters(codec));
        EXPECT_FALSE(parseDoViCodecParameters(codec));
    }

    Ref empty = SharedBuffer::create();
    EXPECT_FALSE(parseAVCDecoderConfigurationRecord(empty));
    EXPECT_FALSE(parseHEVCDecoderConfigurationRecord(hvc1, empty));
    EXPECT_FALSE(parseDoViDecoderConfigurationRecord(empty));

    Vector<uint8_t> emptyVector;
    static constexpr uint8_t oneByte[] = { 0 };
    for (auto hvcc : { std::span<const uint8_t> { }, emptyVector.span(), std::span { oneByte }.first(0) })
        EXPECT_FALSE(parseHVCCParameterSets(hvcc));

    HEVCParameters noFlags;
    noFlags.generalConstraintIndicatorFlags = { };
    EXPECT_EQ(createHEVCCodecParametersString(noFlags), "hvc1.0.0.L0"_s);
}

TEST(HEVCUtilities, ParseAVCCodecParameters)
{
    auto parameters = parseAVCCodecParameters("avc1.42E01E"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->profileIDC, 0x42);
    EXPECT_EQ(parameters->constraintsFlags, 0xE0);
    EXPECT_EQ(parameters->levelIDC, 0x1E);

    // Seven or eight digits lose their upper bits, and anything after the number is ignored.
    parameters = parseAVCCodecParameters("avc1.12345678.anything"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->profileIDC, 0x34);
    EXPECT_EQ(parameters->constraintsFlags, 0x56);
    EXPECT_EQ(parameters->levelIDC, 0x78);

    // WTF's parseInteger and split leniencies.
    parameters = parseAVCCodecParameters(".avc1.. +64001f\t."_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->profileIDC, 0x64);
    EXPECT_EQ(parameters->constraintsFlags, 0x00);
    EXPECT_EQ(parameters->levelIDC, 0x1F);

    parameters = parseAVCCodecParameters(StringView { widened("avc1.4d401f"_s).span() });
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->profileIDC, 0x4D);

    EXPECT_FALSE(parseAVCCodecParameters("avc1"_s));
    EXPECT_FALSE(parseAVCCodecParameters("avc3.42E01E"_s));
    EXPECT_FALSE(parseAVCCodecParameters("AVC1.42E01E"_s));
    EXPECT_FALSE(parseAVCCodecParameters("avc1.100000000"_s));
    EXPECT_FALSE(parseAVCCodecParameters("avc1.42E01G"_s));
}

TEST(HEVCUtilities, ParseHEVCCodecParameters)
{
    auto parameters = parseHEVCCodecParameters("hvc1.1.6.L93.B0"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, HEVCParameters::Codec::Hvc1);
    EXPECT_EQ(parameters->generalProfileSpace, 0);
    EXPECT_EQ(parameters->generalProfileIDC, 1);
    EXPECT_EQ(parameters->generalProfileCompatibilityFlags, 0x60000000u);
    EXPECT_EQ(parameters->generalTierFlag, 0);
    EXPECT_EQ(parameters->generalLevelIDC, 93);
    EXPECT_EQ(parameters->generalConstraintIndicatorFlags, (Vector<unsigned char, 6> { 0xB0, 0, 0, 0, 0, 0 }));

    parameters = parseHEVCCodecParameters(StringView { widened("hev1.C31.10.H120.B0.23.1.2.3.4.5"_s).span() });
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, HEVCParameters::Codec::Hev1);
    EXPECT_EQ(parameters->generalProfileSpace, 3);
    EXPECT_EQ(parameters->generalProfileIDC, 31);
    EXPECT_EQ(parameters->generalProfileCompatibilityFlags, 0x08000000u);
    EXPECT_EQ(parameters->generalTierFlag, 1);
    EXPECT_EQ(parameters->generalLevelIDC, 120);
    EXPECT_EQ(parameters->generalConstraintIndicatorFlags, (Vector<unsigned char, 6> { 0xB0, 0x23, 1, 2, 3, 4 }));

    parameters = parseHEVCCodecParameters("hvc1.A 2.ffffffff.L+0"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->generalProfileSpace, 1);
    EXPECT_EQ(parameters->generalProfileIDC, 2);
    EXPECT_EQ(parameters->generalProfileCompatibilityFlags, 0xFFFFFFFFu);
    EXPECT_EQ(parameters->generalLevelIDC, 0);

    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.1.6"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc2.1.6.L93"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.D1.6.L93"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.A.6.L93"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.1.6.l93"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.1.6.L256"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.256.6.L93"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.1.100000000.L93"_s));
    EXPECT_FALSE(parseHEVCCodecParameters("hvc1.1.6.L93.B0.100"_s));
}

TEST(HEVCUtilities, ParseDoViCodecParameters)
{
    auto parameters = parseDoViCodecParameters("dvh1.05.06"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, DoViParameters::Codec::HVC1);
    EXPECT_EQ(parameters->bitstreamProfileID, 5);
    EXPECT_EQ(parameters->bitstreamLevelID, 6);

    parameters = parseDoViCodecParameters("dvhe.stn.13"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, DoViParameters::Codec::HEV1);
    EXPECT_EQ(parameters->bitstreamProfileID, 5);
    EXPECT_EQ(parameters->bitstreamLevelID, 13);

    parameters = parseDoViCodecParameters(StringView { widened("DVAV.SE.05"_s).span() });
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, DoViParameters::Codec::AVC3);
    EXPECT_EQ(parameters->bitstreamProfileID, 9);
    EXPECT_EQ(parameters->bitstreamLevelID, 5);

    parameters = parseDoViCodecParameters("dva1.09.00.extra"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, DoViParameters::Codec::AVC1);
    EXPECT_EQ(parameters->bitstreamProfileID, 9);
    EXPECT_EQ(parameters->bitstreamLevelID, 0);

    // The codec name is matched by ORing each character with 0x20, so 0x11 matches '1'.
    parameters = parseDoViCodecParameters("dvh\x11.08.01"_s);
    ASSERT_TRUE(parameters);
    EXPECT_EQ(parameters->codec, DoViParameters::Codec::HVC1);
    EXPECT_EQ(parameters->bitstreamProfileID, 8);

    EXPECT_FALSE(parseDoViCodecParameters("dvh1.09.05"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dva1.05.05"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh1.05.14"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh1.04.10"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh1.06.01"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh1.5.06"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh1..stn.06"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh1.05"_s));
    EXPECT_FALSE(parseDoViCodecParameters("dvh2.05.06"_s));
}

TEST(HEVCUtilities, CreateCodecParametersStrings)
{
    EXPECT_EQ(createAVCCodecParametersString({ 0x42, 0xE0, 0x1E }), "avc1.42E01E"_s);
    EXPECT_EQ(createAVCCodecParametersString({ 0, 0, 0 }), "avc1.000000"_s);

    EXPECT_EQ(createHEVCCodecParametersString(*parseHEVCCodecParameters("hvc1.1.6.L93.B0"_s)), "hvc1.1.6.L93.B0"_s);
    EXPECT_EQ(createHEVCCodecParametersString(*parseHEVCCodecParameters("hev1.C31.10.H120.b0.0.1"_s)), "hev1.C31.10.H120.B0.00.01"_s);
    EXPECT_EQ(createHEVCCodecParametersString({ }), "hvc1.0.0.L0"_s);

    HEVCParameters parameters;
    parameters.generalProfileSpace = 4;
    parameters.generalProfileIDC = 1000;
    parameters.generalProfileCompatibilityFlags = 1;
    parameters.generalTierFlag = 2;
    parameters.generalLevelIDC = 65535;
    parameters.generalConstraintIndicatorFlags = { 0, 0x10, 0, 0, 0, 0, 0, 0xFF, 0 };
    EXPECT_EQ(createHEVCCodecParametersString(parameters), "hvc1.D1000.80000000.H65535.00.10.00.00.00.00.00.FF"_s);

    EXPECT_EQ(createDoViCodecParametersString({ DoViParameters::Codec::AVC1, 9, 5 }), "dvh1.09.05"_s);
    EXPECT_EQ(createDoViCodecParametersString({ DoViParameters::Codec::HVC1, 12, 13 }), "dvh1.12.13"_s);
    EXPECT_EQ(createDoViCodecParametersString({ DoViParameters::Codec::HEV1, 100, 1000 }), "dvh1.100.1000"_s);
}

TEST(HEVCUtilities, ParseDecoderConfigurationRecords)
{
    static constexpr uint8_t avcC[24] = { 0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1 };
    auto avc = parseAVCDecoderConfigurationRecord(makeBuffer(std::span { avcC }));
    ASSERT_TRUE(avc);
    EXPECT_EQ(avc->profileIDC, 0x64);
    EXPECT_EQ(avc->constraintsFlags, 0x00);
    EXPECT_EQ(avc->levelIDC, 0x1F);
    EXPECT_FALSE(parseAVCDecoderConfigurationRecord(makeBuffer(std::span { avcC }.first(23))));

    static constexpr uint8_t hvcC[23] = { 0x01, 0x62, 0x60, 0x00, 0x00, 0x00, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x01, 0x5D };
    auto hevc = parseHEVCDecoderConfigurationRecord(hev1, makeBuffer(std::span { hvcC }));
    ASSERT_TRUE(hevc);
    EXPECT_EQ(hevc->codec, HEVCParameters::Codec::Hev1);
    EXPECT_EQ(hevc->generalProfileSpace, 1);
    EXPECT_EQ(hevc->generalTierFlag, 1);
    EXPECT_EQ(hevc->generalProfileIDC, 2);
    EXPECT_EQ(hevc->generalProfileCompatibilityFlags, 0x60000000u);
    EXPECT_EQ(hevc->generalLevelIDC, 93);
    EXPECT_EQ(createHEVCCodecParametersString(*hevc), "hev1.A2.6.H93.B0.00.00.00.00.01"_s);
    EXPECT_EQ(parseHEVCDecoderConfigurationRecord(hvc1, makeBuffer(std::span { hvcC }))->codec, HEVCParameters::Codec::Hvc1);
    EXPECT_FALSE(parseHEVCDecoderConfigurationRecord(FourCC { std::span { "avc1" } }, makeBuffer(std::span { hvcC })));
    EXPECT_FALSE(parseHEVCDecoderConfigurationRecord(hvc1, makeBuffer(std::span { hvcC }.first(22))));

    // dv_profile 5, dv_level 6, then the rpu, el and bl flags.
    static constexpr uint8_t dvcC[24] = { 0x01, 0x00, 0x0A, 0x35 };
    auto dovi = parseDoViDecoderConfigurationRecord(makeBuffer(std::span { dvcC }));
    ASSERT_TRUE(dovi);
    EXPECT_EQ(dovi->codec, DoViParameters::Codec::HVC1);
    EXPECT_EQ(dovi->bitstreamProfileID, 5);
    EXPECT_EQ(dovi->bitstreamLevelID, 6);
    EXPECT_FALSE(parseDoViDecoderConfigurationRecord(makeBuffer(std::span { dvcC }.first(23))));
}

TEST(HEVCUtilities, ParseHVCCParameterSets)
{
    static constexpr uint8_t hvcc[] = {
        0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5D, 0xF0, 0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00,
        0x0F, // lengthSizeMinusOne 3
        0x03, // numOfArrays
        0xA0, 0x00, 0x01, 0x00, 0x03, 0x40, 0x01, 0x0C, // VPS
        0x21, 0x00, 0x02, 0x00, 0x02, 0x42, 0x01, 0x00, 0x01, 0x42, // two SPS
        0xFF, 0x00, 0x00, // no NAL units of type 63
    };
    auto sets = parseHVCCParameterSets(std::span { hvcc });
    ASSERT_TRUE(sets);
    EXPECT_EQ(flatten(std::span { hvcc }, *sets), (Vector<size_t> { 4, 32, 28, 3, 33, 36, 2, 33, 40, 1 }));

    // The third array header is missing.
    EXPECT_FALSE(parseHVCCParameterSets(std::span { hvcc }.first(41)));
    EXPECT_FALSE(parseHVCCParameterSets(std::span { hvcc }.first(22)));

    // Two arrays, the last NAL unit ending with the box, and a length field size of 1.
    Vector<uint8_t> modified(std::span { hvcc });
    modified[21] = 0xFC;
    modified[22] = 2;
    sets = parseHVCCParameterSets(modified.span().first(41));
    ASSERT_TRUE(sets);
    EXPECT_EQ(flatten(modified.span(), *sets), (Vector<size_t> { 1, 32, 28, 3, 33, 36, 2, 33, 40, 1 }));

    // Fixed fields only.
    modified[22] = 0;
    sets = parseHVCCParameterSets(modified.span().first(23));
    ASSERT_TRUE(sets);
    EXPECT_EQ(flatten(modified.span(), *sets), (Vector<size_t> { 1 }));

    // A zero-size NAL unit, or one past the end of the box.
    modified[22] = 2;
    modified[34] = 0;
    modified[35] = 0;
    EXPECT_FALSE(parseHVCCParameterSets(modified.span()));
    modified[34] = 0xFF;
    modified[35] = 0xFF;
    EXPECT_FALSE(parseHVCCParameterSets(modified.span()));
}

} // namespace TestWebKitAPI
