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

#include <WebCore/VP9Utilities.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {
using namespace WebCore;

static void expectRecord(const std::optional<VPCodecConfigurationRecord>& record, ASCIILiteral codecName, std::array<uint8_t, 8> values)
{
    ASSERT_TRUE(record);
    EXPECT_EQ(record->codecName, codecName);
    EXPECT_EQ(record->profile, values[0]);
    EXPECT_EQ(record->level, values[1]);
    EXPECT_EQ(record->bitDepth, values[2]);
    EXPECT_EQ(record->chromaSubsampling, values[3]);
    EXPECT_EQ(record->colorPrimaries, values[4]);
    EXPECT_EQ(record->transferCharacteristics, values[5]);
    EXPECT_EQ(record->matrixCoefficients, values[6]);
    EXPECT_EQ(record->videoFullRangeFlag, values[7]);
}

template<size_t length>
static String utf16(const char16_t (&characters)[length])
{
    return std::span { characters }.first(length - 1);
}

static std::optional<VPCodecConfigurationRecord> parseUTF16(ASCIILiteral codec)
{
    String string = codec;
    string.convertTo16Bit();
    return parseVPCodecParameters(string);
}

class VP9FrameWriter {
public:
    void write(uint32_t value, unsigned bits)
    {
        for (unsigned bit = bits; bit--;) {
            if (!(m_bitCount % 8))
                m_bytes.append(0);
            if ((value >> bit) & 1)
                m_bytes.last() |= 0x80 >> (m_bitCount % 8);
            ++m_bitCount;
        }
    }

    Vector<uint8_t> take()
    {
        while (m_bytes.size() < 11)
            m_bytes.append(0);
        return WTF::move(m_bytes);
    }

private:
    Vector<uint8_t> m_bytes;
    size_t m_bitCount { 0 };
};

struct VP9KeyFrame {
    unsigned profile { 0 };
    bool twelveBit { false };
    unsigned colorSpace { 2 };
    bool fullRange { false };
    bool subsamplingX { true };
    bool subsamplingY { true };
    unsigned width { 640 };
    unsigned height { 480 };
};

static Vector<uint8_t> vp9KeyFrameBytes(const VP9KeyFrame& frame)
{
    VP9FrameWriter writer;
    writer.write(2, 2); // frame_marker
    writer.write(frame.profile & 1, 1);
    writer.write(frame.profile >> 1, 1);
    if (frame.profile == 3)
        writer.write(0, 1);
    writer.write(0, 1); // show_existing_frame
    writer.write(0, 1); // frame_type: KEY_FRAME
    writer.write(1, 1); // show_frame
    writer.write(0, 1); // error_resilient_mode
    writer.write(0x498342, 24); // frame_sync_code
    if (frame.profile >= 2)
        writer.write(frame.twelveBit, 1);
    writer.write(frame.colorSpace, 3);
    if (frame.colorSpace != 7) {
        writer.write(frame.fullRange, 1);
        if (frame.profile == 1 || frame.profile == 3) {
            writer.write(frame.subsamplingX, 1);
            writer.write(frame.subsamplingY, 1);
            writer.write(0, 1);
        }
    } else if (frame.profile == 1 || frame.profile == 3)
        writer.write(0, 1);
    writer.write(frame.width - 1, 16);
    writer.write(frame.height - 1, 16);
    return writer.take();
}

// Swift traps on an empty span with no base address passed back to C++, so each shell is fed one.
TEST(VP9Utilities, EmptyInput)
{
    Vector<uint8_t> emptyVector;
    static constexpr uint8_t oneByte[] = { 0 };
    for (auto input : { std::span<const uint8_t> { }, emptyVector.span(), std::span { oneByte }.first(0) }) {
        EXPECT_FALSE(createVPCodecConfigurationRecordFromVPCC(input));
        EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, input));
        EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, input));
    }

    for (auto codec : { StringView { }, StringView { emptyString() }, StringView { std::span<const char16_t> { } } }) {
        EXPECT_FALSE(parseVPCodecParameters(codec));
        EXPECT_FALSE(parseVPCodecParametersIgnoringColorFields(codec));
    }

    VPCodecConfigurationRecord unnamed;
    auto string = createVPCodecParametersString(unnamed);
    EXPECT_FALSE(string.isNull());
    EXPECT_EQ(string, ".00.10.08"_s);

    unnamed.level = 12;
    string = createVPCodecParametersString(unnamed);
    EXPECT_FALSE(string.isNull());
    EXPECT_TRUE(string.isEmpty());

    unnamed.codecName = emptyString();
    string = createVPCodecParametersString(unnamed);
    EXPECT_FALSE(string.isNull());
    EXPECT_TRUE(string.isEmpty());
}

TEST(VP9Utilities, ParseLegacyCodecStrings)
{
    expectRecord(parseVPCodecParameters("vp8"_s), "vp8"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParameters("vp9"_s), "vp9"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParameters("vp8.0"_s), "vp8"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParameters("vp9.0"_s), "vp9"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    // StringView::split() skips empty pieces, so the name may follow dots.
    expectRecord(parseVPCodecParameters(".vp9."_s), "vp9"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseUTF16("vp9.0"_s), "vp9"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });

    EXPECT_FALSE(parseVPCodecParameters("vp9.1"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp9.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp9.0.0"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp9..0"_s));
    EXPECT_FALSE(parseVPCodecParameters("VP9"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp10"_s));
    EXPECT_FALSE(parseVPCodecParameters("."_s));
}

TEST(VP9Utilities, ParseCodecStrings)
{
    expectRecord(parseVPCodecParameters("vp09.00.10.08"_s), "vp09"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParameters("vp08.00.41.08.01.01.01.01.00"_s), "vp08"_s, { 0, 41, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParameters("vp09.02.10.10.01.09.16.09.01"_s), "vp09"_s, { 2, 10, 10, 1, 9, 16, 9, 1 });
    expectRecord(parseVPCodecParameters("vp09.01.62.12.03.22.18.00.01"_s), "vp09"_s, { 1, 62, 12, 3, 22, 18, 0, 1 });
    expectRecord(parseUTF16("vp09.02.10.10.01.09.16.09.01"_s), "vp09"_s, { 2, 10, 10, 1, 9, 16, 9, 1 });

    // WTF's parseInteger() and StringView::split() leniencies.
    expectRecord(parseVPCodecParameters("vp09. +3 .000010.\t8\n"_s), "vp09"_s, { 3, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParameters("vp09..00..10..08.."_s), "vp09"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });

    EXPECT_FALSE(parseVPCodecParameters("vp09"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.04.10.08"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.12.08"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.09"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.-0.10.08"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.256.10.08"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.0x0.10.08"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.01.01.01"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.01.01.01.00.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.04.01.01.01.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.03.01.01.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.01.19.01.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.01.01.15.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.01.01.01.02"_s));
    // Matrix coefficients 0 (RGB) need 4:4:4.
    EXPECT_FALSE(parseVPCodecParameters("vp09.00.10.08.01.01.01.00.00"_s));
    EXPECT_FALSE(parseVPCodecParameters("vp9.00.10.08"_s));
}

// The validity tables are Swift mirrors of the VPConfiguration* constants: every value of every field.
TEST(VP9Utilities, ParseCodecStringFieldValues)
{
    auto contains = [](std::initializer_list<uint8_t> values, unsigned value) {
        return std::ranges::find(values, value) != values.end();
    };
    auto levels = {
        VPConfigurationLevel::Level_1, VPConfigurationLevel::Level_1_1, VPConfigurationLevel::Level_2, VPConfigurationLevel::Level_2_1,
        VPConfigurationLevel::Level_3, VPConfigurationLevel::Level_3_1, VPConfigurationLevel::Level_4, VPConfigurationLevel::Level_4_1,
        VPConfigurationLevel::Level_5, VPConfigurationLevel::Level_5_1, VPConfigurationLevel::Level_5_2, VPConfigurationLevel::Level_6,
        VPConfigurationLevel::Level_6_1, VPConfigurationLevel::Level_6_2,
    };
    auto primaries = {
        VPConfigurationColorPrimaries::BT_709_6, VPConfigurationColorPrimaries::Unspecified, VPConfigurationColorPrimaries::BT_470_6_M,
        VPConfigurationColorPrimaries::BT_470_7_BG, VPConfigurationColorPrimaries::BT_601_7, VPConfigurationColorPrimaries::SMPTE_ST_240,
        VPConfigurationColorPrimaries::Film, VPConfigurationColorPrimaries::BT_2020_Nonconstant_Luminance, VPConfigurationColorPrimaries::SMPTE_ST_428_1,
        VPConfigurationColorPrimaries::SMPTE_RP_431_2, VPConfigurationColorPrimaries::SMPTE_EG_432_1, VPConfigurationColorPrimaries::EBU_Tech_3213_E,
    };
    auto transfers = {
        VPConfigurationTransferCharacteristics::BT_709_6, VPConfigurationTransferCharacteristics::Unspecified, VPConfigurationTransferCharacteristics::BT_470_6_M,
        VPConfigurationTransferCharacteristics::BT_470_7_BG, VPConfigurationTransferCharacteristics::BT_601_7, VPConfigurationTransferCharacteristics::SMPTE_ST_240,
        VPConfigurationTransferCharacteristics::Linear, VPConfigurationTransferCharacteristics::Logrithmic, VPConfigurationTransferCharacteristics::Logrithmic_Sqrt,
        VPConfigurationTransferCharacteristics::IEC_61966_2_4, VPConfigurationTransferCharacteristics::BT_1361_0, VPConfigurationTransferCharacteristics::IEC_61966_2_1,
        VPConfigurationTransferCharacteristics::BT_2020_10bit, VPConfigurationTransferCharacteristics::BT_2020_12bit, VPConfigurationTransferCharacteristics::SMPTE_ST_2084,
        VPConfigurationTransferCharacteristics::SMPTE_ST_428_1, VPConfigurationTransferCharacteristics::BT_2100_HLG,
    };
    auto matrices = {
        VPConfigurationMatrixCoefficients::Identity, VPConfigurationMatrixCoefficients::BT_709_6, VPConfigurationMatrixCoefficients::Unspecified,
        VPConfigurationMatrixCoefficients::FCC, VPConfigurationMatrixCoefficients::BT_470_7_BG, VPConfigurationMatrixCoefficients::BT_601_7,
        VPConfigurationMatrixCoefficients::SMPTE_ST_240, VPConfigurationMatrixCoefficients::YCgCo, VPConfigurationMatrixCoefficients::BT_2020_Nonconstant_Luminance,
        VPConfigurationMatrixCoefficients::BT_2020_Constant_Luminance, VPConfigurationMatrixCoefficients::SMPTE_ST_2085, VPConfigurationMatrixCoefficients::Chromacity_Constant_Luminance,
        VPConfigurationMatrixCoefficients::Chromacity_Nonconstant_Luminance, VPConfigurationMatrixCoefficients::BT_2100_ICC,
    };

    for (unsigned value = 0; value < 256; ++value) {
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09."_s, value, ".10.08"_s)), value <= 3);
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00."_s, value, ".08"_s)), contains(levels, value));
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00.10."_s, value)), value == 8 || value == 10 || value == 12);
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00.10.08."_s, value, ".01.01.01.00"_s)), value <= VPConfigurationChromaSubsampling::Subsampling_444);
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00.10.08.01."_s, value, ".01.01.00"_s)), contains(primaries, value));
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00.10.08.01.01."_s, value, ".01.00"_s)), contains(transfers, value));
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00.10.08.03.01.01."_s, value, ".00"_s)), contains(matrices, value));
        EXPECT_EQ(!!parseVPCodecParameters(makeString("vp09.00.10.08.01.01.01.01."_s, value)), value == VPConfigurationRange::VideoRange || value == VPConfigurationRange::FullRange);
    }
}

TEST(VP9Utilities, ParseCodecStringsIgnoringColorFields)
{
    expectRecord(parseVPCodecParametersIgnoringColorFields("vp09.00.10.08.02.99.99.99.99.99"_s), "vp09"_s, { 0, 10, 8, 2, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParametersIgnoringColorFields("vp09.00.10.08"_s), "vp09"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParametersIgnoringColorFields("vp09.02.10.10.01.09.16.09.01"_s), "vp09"_s, { 2, 10, 10, 1, 1, 1, 1, 0 });
    // The fifth field ends at a dot, and anything after it is ignored, even outside Latin-1.
    expectRecord(parseVPCodecParametersIgnoringColorFields(utf16(u"vp09.00.10.08.03.☃")), "vp09"_s, { 0, 10, 8, 3, 1, 1, 1, 0 });
    // Four dots or more: the text up to the fourth is parsed alone, then the fifth field.
    expectRecord(parseVPCodecParametersIgnoringColorFields("vp9....1"_s), "vp9"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    expectRecord(parseVPCodecParametersIgnoringColorFields("vp09.00.10.08. 0 "_s), "vp09"_s, { 0, 10, 8, 0, 1, 1, 1, 0 });

    EXPECT_FALSE(parseVPCodecParametersIgnoringColorFields("vp09.00.10.08."_s));
    EXPECT_FALSE(parseVPCodecParametersIgnoringColorFields("vp09.00.10.08.04"_s));
    EXPECT_FALSE(parseVPCodecParametersIgnoringColorFields("vp09.00.10.08..01"_s));
    EXPECT_FALSE(parseVPCodecParametersIgnoringColorFields("vp09.00.10.09.01"_s));
    EXPECT_FALSE(parseVPCodecParametersIgnoringColorFields("vp09.00.10"_s));
}

TEST(VP9Utilities, CreateCodecString)
{
    VPCodecConfigurationRecord record;
    record.codecName = "vp09"_s;
    EXPECT_EQ(createVPCodecParametersString(record), "vp09.00.10.08"_s);

    record = *parseVPCodecParameters("vp09.02.10.10.01.09.16.09.01"_s);
    EXPECT_EQ(createVPCodecParametersString(record), "vp09.02.10.10.01.09.16.09.01"_s);

    record = *parseVPCodecParameters("vp08.03.62.12.00.22.02.04.00"_s);
    EXPECT_EQ(createVPCodecParametersString(record), "vp08.03.62.12.00.22.02.04.00"_s);

    // One default colour field differing is enough to write them all.
    record = *parseVPCodecParameters("vp09.00.10.08.01.01.01.01.01"_s);
    EXPECT_EQ(createVPCodecParametersString(record), "vp09.00.10.08.01.01.01.01.01"_s);

    // Any field out of range leaves only the name.
    auto fields = { &VPCodecConfigurationRecord::profile, &VPCodecConfigurationRecord::level, &VPCodecConfigurationRecord::bitDepth,
        &VPCodecConfigurationRecord::chromaSubsampling, &VPCodecConfigurationRecord::colorPrimaries, &VPCodecConfigurationRecord::transferCharacteristics,
        &VPCodecConfigurationRecord::matrixCoefficients, &VPCodecConfigurationRecord::videoFullRangeFlag };
    for (auto field : fields) {
        VPCodecConfigurationRecord invalid;
        invalid.codecName = "vp8"_s;
        invalid.*field = 200;
        EXPECT_EQ(createVPCodecParametersString(invalid), "vp8"_s);
    }

    // The name is copied, whatever it is.
    record = { };
    record.codecName = utf16(u"vp☃");
    EXPECT_EQ(createVPCodecParametersString(record), utf16(u"vp☃.00.10.08"));
    record.matrixCoefficients = 99;
    EXPECT_EQ(createVPCodecParametersString(record), utf16(u"vp☃"));

    for (auto codec : { "vp09.00.10.08"_s, "vp09.01.20.08.00.01.01.01.00"_s, "vp08.00.11.10.02.04.04.04.01"_s })
        EXPECT_EQ(createVPCodecParametersString(*parseVPCodecParameters(codec)), codec);
}

TEST(VP9Utilities, VPCCRecord)
{
    static constexpr uint8_t vpcc[] = { 0x01, 0x00, 0x00, 0x00, 0x02, 0x1F, 0xA3, 0x09, 0x10, 0x09, 0x00, 0x00, 0xFF };
    auto record = createVPCodecConfigurationRecordFromVPCC(std::span { vpcc });
    ASSERT_TRUE(record);
    EXPECT_TRUE(record->codecName.isNull());
    EXPECT_EQ(record->profile, 2);
    EXPECT_EQ(record->level, 31);
    EXPECT_EQ(record->bitDepth, 10);
    EXPECT_EQ(record->chromaSubsampling, 1);
    EXPECT_EQ(record->videoFullRangeFlag, 1);
    EXPECT_EQ(record->colorPrimaries, 9);
    EXPECT_EQ(record->transferCharacteristics, 16);
    EXPECT_EQ(record->matrixCoefficients, 9);
    EXPECT_EQ(record->frameWidth, 0);
    EXPECT_EQ(createVPCodecParametersString(*record), ".02.31.10.01.09.16.09.01"_s);

    EXPECT_TRUE(createVPCodecConfigurationRecordFromVPCC(std::span { vpcc }.first(12)));
    EXPECT_FALSE(createVPCodecConfigurationRecordFromVPCC(std::span { vpcc }.first(11)));

    static constexpr uint8_t withInitializationData[] = { 0x01, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x82, 0x01, 0x01, 0x01, 0x00, 0x01 };
    EXPECT_FALSE(createVPCodecConfigurationRecordFromVPCC(std::span { withInitializationData }));
}

TEST(VP9Utilities, VP8ByteStream)
{
    // A frame whose first byte has bit 0 set is taken as a key frame.
    static constexpr uint8_t frame[] = { 0x01, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x80, 0x02, 0xE0, 0x01, 0x00 };
    auto record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, std::span { frame });
    expectRecord(record, "vp08"_s, { 0, 10, 8, 1, 6, 6, 6, 0 });
    EXPECT_EQ(record->frameWidth, 0);

    auto withColorSpace = WTF::toArray(frame);
    withColorSpace[10] = 0x80;
    expectRecord(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, std::span { withColorSpace }), "vp08"_s, { 0, 10, 8, 1, 2, 2, 2, 0 });

    auto invalid = WTF::toArray(frame);
    invalid[0] = 0x00;
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, std::span { invalid }));
    invalid = WTF::toArray(frame);
    invalid[0] = 0x09;
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, std::span { invalid }));
    invalid = WTF::toArray(frame);
    invalid[5] = 0x2B;
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, std::span { invalid }));
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp8, std::span { frame }.first(10)));
}

TEST(VP9Utilities, VP9ByteStream)
{
    auto frame = vp9KeyFrameBytes({ });
    auto record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, frame.span());
    expectRecord(record, "vp09"_s, { 0, 10, 8, 1, 1, 1, 1, 0 });
    EXPECT_EQ(record->frameWidth, 640);
    EXPECT_EQ(record->frameHeight, 480);

    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .profile = 2, .twelveBit = true, .colorSpace = 5, .fullRange = true }).span());
    expectRecord(record, "vp09"_s, { 2, 10, 12, 1, 9, 15, 9, 1 });
    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .profile = 2, .colorSpace = 5 }).span());
    expectRecord(record, "vp09"_s, { 2, 10, 10, 1, 9, 14, 9, 0 });
    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .profile = 1, .colorSpace = 1, .subsamplingY = false }).span());
    expectRecord(record, "vp09"_s, { 1, 10, 8, 2, 6, 6, 6, 0 });
    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .profile = 1, .colorSpace = 4, .subsamplingX = false, .subsamplingY = false }).span());
    expectRecord(record, "vp09"_s, { 1, 10, 8, 3, 7, 7, 7, 0 });
    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .profile = 3, .colorSpace = 7 }).span());
    expectRecord(record, "vp09"_s, { 3, 10, 10, 3, 1, 13, 0, 1 });
    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .colorSpace = 6 }).span());
    expectRecord(record, "vp09"_s, { 0, 10, 8, 1, 2, 2, 2, 0 });

    // frame_width_minus_1 of 65535 wraps to 0.
    record = vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, vp9KeyFrameBytes({ .width = 65536, .height = 1 }).span());
    ASSERT_TRUE(record);
    EXPECT_EQ(record->frameWidth, 0);
    EXPECT_EQ(record->frameHeight, 1);

    auto notKey = frame;
    notKey[0] |= 0x04;
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, notKey.span()));
    auto badSync = frame;
    badSync[1] = 0x48;
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, badSync.span()));
    EXPECT_FALSE(vpCodecConfigurationRecordFromVPXByteStream(VPXCodec::Vp9, frame.span().first(10)));
}

}
