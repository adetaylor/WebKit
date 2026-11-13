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

#import "config.h"

#if ENABLE(VP9) && PLATFORM(COCOA)

#import <WebCore/SharedBuffer.h>
#import <WebCore/TrackInfo.h>
#import <WebCore/VP9UtilitiesCocoa.h>
#import <wtf/Vector.h>

namespace TestWebKitAPI {
using namespace WebCore;

// An 11-byte VP9 key frame header: profile 0, color_space 2 (BT.709), studio range, 640x480.
static constexpr uint8_t vp9KeyFrame[] = { 0x82, 0x49, 0x83, 0x42, 0x40, 0x27, 0xF0, 0x1D, 0xF0, 0x00, 0x00 };

static void expectAtom(const VideoInfo& info, std::initializer_list<uint8_t> bytes)
{
    ASSERT_EQ(info.extensionAtoms().size(), 1u);
    EXPECT_EQ(info.extensionAtoms()[0].first, FourCC('vpcC'));
    EXPECT_EQ(Vector<uint8_t> { info.extensionAtoms()[0].second->span() }, Vector<uint8_t> { bytes });
}

// Swift traps on an empty span with no base address passed back to C++, so each shell is fed one.
TEST(VP9UtilitiesCocoa, EmptyInput)
{
    Vector<uint8_t> emptyVector;
    static constexpr uint8_t oneByte[] = { 0 };
    for (auto input : { std::span<const uint8_t> { }, emptyVector.span(), std::span { oneByte }.first(0) }) {
        EXPECT_FALSE(parseVP8FrameHeader(input));
        EXPECT_FALSE(createVideoInfoFromVP9Stream(input, 0, 0));
        EXPECT_FALSE(createVideoInfoFromVP9Stream(input, 320, 240));
    }

    VPCodecConfigurationRecord unnamed;
    unnamed.level = 0;
    Ref info = createVideoInfoFromVPCodecConfigurationRecord(unnamed);
    EXPECT_EQ(info->codecName(), FourCC('vp08'));
    EXPECT_FALSE(info->codecString().isNull());
    EXPECT_TRUE(info->codecString().isEmpty());
}

TEST(VP9UtilitiesCocoa, ParseVP8FrameHeader)
{
    // The first word is read little-endian, so its top bit, the key frame flag, is bit 7 of the start code's first byte.
    static constexpr uint8_t keyFrame[] = { 0x10, 0x02, 0x00, 0x9D, 0x01, 0x2A, 0x80, 0x42, 0xE0, 0x01, 0xC0 };
    auto header = parseVP8FrameHeader(std::span { keyFrame });
    ASSERT_TRUE(header);
    EXPECT_TRUE(header->keyframe);
    EXPECT_EQ(header->version, 1);
    EXPECT_TRUE(header->showFrame);
    EXPECT_EQ(header->partitionSize, 0x50002u);
    EXPECT_EQ(header->horizontalScale, 1);
    EXPECT_EQ(header->width, 640);
    EXPECT_EQ(header->verticalScale, 0);
    EXPECT_EQ(header->height, 480);
    EXPECT_TRUE(header->colorSpace);
    EXPECT_TRUE(header->needsClamping);

    auto notKey = WTF::toArray(keyFrame);
    notKey[3] = 0x1D;
    header = parseVP8FrameHeader(std::span { notKey });
    ASSERT_TRUE(header);
    EXPECT_FALSE(header->keyframe);
    EXPECT_EQ(header->version, 1);
    EXPECT_TRUE(header->showFrame);
    EXPECT_EQ(header->width, 0);
    EXPECT_EQ(header->height, 0);
    EXPECT_FALSE(header->colorSpace);

    auto badStartCode = WTF::toArray(keyFrame);
    badStartCode[4] = 0x02;
    EXPECT_FALSE(parseVP8FrameHeader(std::span { badStartCode }));
    EXPECT_FALSE(parseVP8FrameHeader(std::span { keyFrame }.first(10)));
}

TEST(VP9UtilitiesCocoa, CreateVideoInfoFromVP9Stream)
{
    RefPtr info = createVideoInfoFromVP9Stream(std::span { vp9KeyFrame }, 0, 0);
    ASSERT_TRUE(info);
    EXPECT_EQ(info->codecName(), FourCC('vp09'));
    EXPECT_EQ(info->codecString(), "vp09.00.10.08"_s);
    EXPECT_EQ(info->size(), FloatSize(640, 480));
    EXPECT_EQ(info->displaySize(), FloatSize(640, 480));
    EXPECT_EQ(info->bitDepth(), 8);
    EXPECT_EQ(info->colorSpace().primaries, PlatformVideoColorPrimaries::Bt709);
    EXPECT_EQ(info->colorSpace().transfer, PlatformVideoTransferCharacteristics::Bt709);
    EXPECT_EQ(info->colorSpace().matrix, PlatformVideoMatrixCoefficients::Bt709);
    EXPECT_EQ(info->colorSpace().fullRange, false);
    EXPECT_FALSE(info->colorSpace().chromaLocation);
    expectAtom(*info, { 0x01, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x82, 0x01, 0x01, 0x01, 0x00, 0x00 });

    info = createVideoInfoFromVP9Stream(std::span { vp9KeyFrame }, 1280, 0);
    ASSERT_TRUE(info);
    EXPECT_EQ(info->size(), FloatSize(1280, 480));

    // color_space 0 (unknown) is taken as BT.709.
    auto unknownColorSpace = WTF::toArray(vp9KeyFrame);
    unknownColorSpace[4] = 0x00;
    info = createVideoInfoFromVP9Stream(std::span { unknownColorSpace }, 0, 0);
    ASSERT_TRUE(info);
    EXPECT_EQ(info->codecString(), "vp09.00.10.08"_s);
    EXPECT_EQ(info->colorSpace().primaries, PlatformVideoColorPrimaries::Bt709);

    // color_space 1 (BT.601), full range.
    auto bt601 = WTF::toArray(vp9KeyFrame);
    bt601[4] = 0x30;
    info = createVideoInfoFromVP9Stream(std::span { bt601 }, 0, 0);
    ASSERT_TRUE(info);
    EXPECT_EQ(info->codecString(), "vp09.00.10.08.01.06.06.06.01"_s);
    EXPECT_EQ(info->colorSpace().primaries, PlatformVideoColorPrimaries::Smpte170m);
    EXPECT_EQ(info->colorSpace().transfer, PlatformVideoTransferCharacteristics::Smpte170m);
    EXPECT_EQ(info->colorSpace().matrix, PlatformVideoMatrixCoefficients::Smpte170m);
    EXPECT_EQ(info->colorSpace().fullRange, true);
    expectAtom(*info, { 0x01, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x83, 0x06, 0x06, 0x06, 0x00, 0x00 });

    auto notKey = WTF::toArray(vp9KeyFrame);
    notKey[0] |= 0x04;
    EXPECT_FALSE(createVideoInfoFromVP9Stream(std::span { notKey }, 0, 0));
}

TEST(VP9UtilitiesCocoa, CreateVideoInfoFromVPCodecConfigurationRecord)
{
    static constexpr uint8_t vpcc[] = { 0x01, 0x00, 0x00, 0x00, 0x02, 0x1F, 0xA3, 0x09, 0x10, 0x09, 0x00, 0x00 };
    auto record = createVPCodecConfigurationRecordFromVPCC(std::span { vpcc });
    ASSERT_TRUE(record);
    record->frameWidth = 1920;
    record->frameHeight = 1080;

    // A vpcC record has no codec name, so it is described as VP8.
    Ref info = createVideoInfoFromVPCodecConfigurationRecord(*record);
    EXPECT_EQ(info->codecName(), FourCC('vp08'));
    EXPECT_EQ(info->codecString(), ".02.31.10.01.09.16.09.01"_s);
    EXPECT_EQ(info->size(), FloatSize(1920, 1080));
    EXPECT_EQ(info->displaySize(), FloatSize(1920, 1080));
    EXPECT_EQ(info->bitDepth(), 10);
    EXPECT_EQ(info->colorSpace().primaries, PlatformVideoColorPrimaries::Bt2020);
    EXPECT_EQ(info->colorSpace().transfer, PlatformVideoTransferCharacteristics::SmpteSt2084);
    EXPECT_EQ(info->colorSpace().matrix, PlatformVideoMatrixCoefficients::Bt2020NonconstantLuminance);
    EXPECT_EQ(info->colorSpace().fullRange, true);
    expectAtom(info.get(), { 0x01, 0x00, 0x00, 0x00, 0x02, 0x1F, 0xA3, 0x09, 0x10, 0x09, 0x00, 0x00 });

    record->codecName = "vp09"_s;
    info = createVideoInfoFromVPCodecConfigurationRecord(*record, PlatformVideoColorSpace { .transfer = PlatformVideoTransferCharacteristics::AribStdB67Hlg, .fullRange = false });
    EXPECT_EQ(info->codecName(), FourCC('vp09'));
    EXPECT_EQ(info->codecString(), "vp09.02.31.10.01.09.16.09.01"_s);
    EXPECT_EQ(info->colorSpace().primaries, PlatformVideoColorPrimaries::Bt2020);
    EXPECT_EQ(info->colorSpace().transfer, PlatformVideoTransferCharacteristics::AribStdB67Hlg);
    EXPECT_EQ(info->colorSpace().fullRange, false);

    // Code points without a platform value are unspecified, and only "vp09" is VP9.
    record->codecName = "vp9"_s;
    record->colorPrimaries = 22;
    record->transferCharacteristics = 3;
    record->matrixCoefficients = 11;
    info = createVideoInfoFromVPCodecConfigurationRecord(*record);
    EXPECT_EQ(info->codecName(), FourCC('vp08'));
    EXPECT_EQ(info->codecString(), "vp9"_s);
    EXPECT_EQ(info->colorSpace().primaries, PlatformVideoColorPrimaries::JedecP22Phosphors);
    EXPECT_EQ(info->colorSpace().transfer, PlatformVideoTransferCharacteristics::Unspecified);
    EXPECT_EQ(info->colorSpace().matrix, PlatformVideoMatrixCoefficients::Unspecified);
}

}

#endif
