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

#if PLATFORM(COCOA)

#import <WebCore/AnnexBUtilities.h>
#import <WebCore/FourCC.h>
#import <WebCore/HEVCUtilitiesCocoa.h>
#import <WebCore/TrackInfo.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>

#import <pal/cf/CoreMediaSoftLink.h>

namespace TestWebKitAPI {
using namespace WebCore;

// Arbitrary placeholder payloads: convertHEVCCMSampleBufferToAnnexB() and
// CMVideoFormatDescriptionGetHEVCParameterSetAtIndex() only need to copy these bytes
// verbatim, so they don't need to be syntactically valid H.265 parameter sets.
static constexpr uint8_t vpsBytes[] = { 0xaa, 0xbb };
static constexpr uint8_t spsBytes[] = { 0xcc, 0xdd, 0xee };
static constexpr uint8_t ppsBytes[] = { 0xff };
static constexpr uint8_t slice1Bytes[] = { 0x26, 0x01, 0x11, 0x22, 0x33 };
static constexpr uint8_t slice2Bytes[] = { 0x02, 0x01, 0x44, 0x55 };

static void appendByte(Vector<uint8_t>& buffer, uint8_t byte)
{
    buffer.append(byte);
}

static void appendBytes(Vector<uint8_t>& buffer, std::span<const uint8_t> bytes)
{
    buffer.append(bytes);
}

// Builds a minimal but structurally valid ISO/IEC 14496-15 HEVCDecoderConfigurationRecord
// ("hvcC" box payload) carrying exactly one VPS, one SPS and one PPS NAL unit, with a
// 4-byte NAL length field (lengthSizeMinusOne = 3), matching the length prefixes used by
// createHEVCSampleBuffer() below.
static RetainPtr<NSData> makeHVCCData(std::span<const uint8_t> vps, std::span<const uint8_t> sps, std::span<const uint8_t> pps)
{
    Vector<uint8_t> hvcC;
    appendByte(hvcC, 0x01); // configurationVersion
    appendByte(hvcC, 0x01); // general_profile_space(2)=0 | general_tier_flag(1)=0 | general_profile_idc(5)=1 (Main)
    appendBytes(hvcC, std::array<uint8_t, 4> { 0x60, 0x00, 0x00, 0x00 }); // general_profile_compatibility_flags
    appendBytes(hvcC, std::array<uint8_t, 6> { 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 }); // general_constraint_indicator_flags
    appendByte(hvcC, 0x5d); // general_level_idc (93 = level 3.1)
    appendBytes(hvcC, std::array<uint8_t, 2> { 0xf0, 0x00 }); // reserved(4) | min_spatial_segmentation_idc(12)=0
    appendByte(hvcC, 0xfc); // reserved(6) | parallelismType(2)=0
    appendByte(hvcC, 0xfd); // reserved(6) | chroma_format_idc(2)=1 (4:2:0)
    appendByte(hvcC, 0xf8); // reserved(5) | bit_depth_luma_minus8(3)=0
    appendByte(hvcC, 0xf8); // reserved(5) | bit_depth_chroma_minus8(3)=0
    appendBytes(hvcC, std::array<uint8_t, 2> { 0x00, 0x00 }); // avgFrameRate=0 (unspecified)
    appendByte(hvcC, 0x03); // constantFrameRate(2)=0 | numTemporalLayers(3)=0 | temporalIdNested(1)=0 | lengthSizeMinusOne(2)=3
    appendByte(hvcC, 0x03); // numOfArrays

    auto appendArray = [&](uint8_t naluType, std::span<const uint8_t> nalu) {
        appendByte(hvcC, static_cast<uint8_t>(0x80 | naluType)); // array_completeness=1 | reserved=0 | NAL_unit_type(6)
        appendBytes(hvcC, std::array<uint8_t, 2> { 0x00, 0x01 }); // numNalus = 1
        appendBytes(hvcC, std::array<uint8_t, 2> { static_cast<uint8_t>(nalu.size() >> 8), static_cast<uint8_t>(nalu.size() & 0xff) });
        appendBytes(hvcC, nalu);
    };
    appendArray(32, vps); // VPS
    appendArray(33, sps); // SPS
    appendArray(34, pps); // PPS

    return adoptNS([[NSData alloc] initWithBytes:hvcC.span().data() length:hvcC.size()]);
}

static RetainPtr<CMFormatDescriptionRef> createHEVCFormatDescription(std::span<const uint8_t> vps, std::span<const uint8_t> sps, std::span<const uint8_t> pps)
{
    RetainPtr hvcCData = makeHVCCData(vps, sps, pps);
    NSDictionary *extensions = @{
        (__bridge NSString *)PAL::kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{ @"hvcC": hvcCData.get() },
    };
    CMFormatDescriptionRef rawDescription = nullptr;
    PAL::CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_HEVC, 64, 64, (__bridge CFDictionaryRef)extensions, &rawDescription);
    return adoptCF(rawDescription);
}

// Builds a CMSampleBuffer whose data buffer is a sequence of 4-byte-length-prefixed NAL
// units (the "hvcC"/AVCC style convertHEVCCMSampleBufferToAnnexB() expects), matching the
// lengthSizeMinusOne encoded by createHEVCFormatDescription() above.
static RetainPtr<CMSampleBufferRef> createHEVCSampleBuffer(CMVideoFormatDescriptionRef formatDescription, std::initializer_list<std::span<const uint8_t>> nalus)
{
    Vector<uint8_t> frameData;
    for (auto nalu : nalus) {
        uint32_t length = CFSwapInt32HostToBig(static_cast<uint32_t>(nalu.size()));
        frameData.append(std::span { reinterpret_cast<const uint8_t*>(&length), 4 });
        frameData.append(nalu);
    }

    CMBlockBufferRef rawBlockBuffer = nullptr;
    if (PAL::CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, frameData.size(), kCFAllocatorDefault, nullptr, 0, frameData.size(), kCMBlockBufferAssureMemoryNowFlag, &rawBlockBuffer))
        return nullptr;
    RetainPtr blockBuffer = adoptCF(rawBlockBuffer);

    if (PAL::CMBlockBufferReplaceDataBytes(frameData.span().data(), blockBuffer, 0, frameData.size()))
        return nullptr;

    CMSampleTimingInfo timing = { PAL::CMTimeMake(1, 30), PAL::CMTimeMake(0, 30), PAL::CMTimeMake(0, 30) };
    size_t sampleSize = frameData.size();
    CMSampleBufferRef rawSampleBuffer = nullptr;
    if (PAL::CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true, nullptr, nullptr, formatDescription, 1, 1, &timing, 1, &sampleSize, &rawSampleBuffer))
        return nullptr;
    return adoptCF(rawSampleBuffer);
}

static Vector<uint8_t> annexBStartCode()
{
    return { 0, 0, 0, 1 };
}

TEST(HEVCUtilitiesCocoa, KeyframePrependsParameterSets)
{
    auto description = createHEVCFormatDescription(vpsBytes, spsBytes, ppsBytes);
    ASSERT_TRUE(description);
    auto sample = createHEVCSampleBuffer(description, { slice1Bytes, slice2Bytes });
    ASSERT_TRUE(sample);

    auto annexB = convertHEVCCMSampleBufferToAnnexB(sample, true);

    Vector<uint8_t> expected;
    expected.append(annexBStartCode().span());
    expected.append(std::span { vpsBytes });
    expected.append(annexBStartCode().span());
    expected.append(std::span { spsBytes });
    expected.append(annexBStartCode().span());
    expected.append(std::span { ppsBytes });
    expected.append(annexBStartCode().span());
    expected.append(std::span { slice1Bytes });
    expected.append(annexBStartCode().span());
    expected.append(std::span { slice2Bytes });

    EXPECT_EQ(annexB, expected);
}

TEST(HEVCUtilitiesCocoa, NonKeyframeOmitsParameterSets)
{
    auto description = createHEVCFormatDescription(vpsBytes, spsBytes, ppsBytes);
    ASSERT_TRUE(description);
    auto sample = createHEVCSampleBuffer(description, { slice1Bytes, slice2Bytes });
    ASSERT_TRUE(sample);

    auto annexB = convertHEVCCMSampleBufferToAnnexB(sample, false);

    Vector<uint8_t> expected;
    expected.append(annexBStartCode().span());
    expected.append(std::span { slice1Bytes });
    expected.append(annexBStartCode().span());
    expected.append(std::span { slice2Bytes });

    EXPECT_EQ(annexB, expected);
}

// Regression test for a bug where the second (and later) NAL unit's length was read from a
// stale, non-advancing pointer instead of the current position in the block buffer, which
// corrupted every NALU after the first one in a multi-NALU sample.
TEST(HEVCUtilitiesCocoa, MultipleNALUsOfDifferentSizesAreAllExtracted)
{
    auto description = createHEVCFormatDescription(vpsBytes, spsBytes, ppsBytes);
    ASSERT_TRUE(description);
    auto sample = createHEVCSampleBuffer(description, { slice1Bytes, slice2Bytes });
    ASSERT_TRUE(sample);

    auto annexB = convertHEVCCMSampleBufferToAnnexB(sample, false);
    ASSERT_EQ(annexB.size(), 4 + sizeof(slice1Bytes) + 4 + sizeof(slice2Bytes));

    size_t slice2Offset = 4 + sizeof(slice1Bytes) + 4;
    for (size_t i = 0; i < sizeof(slice2Bytes); ++i)
        EXPECT_EQ(annexB[slice2Offset + i], slice2Bytes[i]);
}

// A NAL length prefix claiming more data than actually remains in the block buffer must be
// rejected rather than read out of bounds.
TEST(HEVCUtilitiesCocoa, TruncatedNALULengthReturnsEmpty)
{
    auto description = createHEVCFormatDescription(vpsBytes, spsBytes, ppsBytes);
    ASSERT_TRUE(description);

    Vector<uint8_t> frameData;
    uint32_t badLength = CFSwapInt32HostToBig(100);
    frameData.append(std::span { reinterpret_cast<const uint8_t*>(&badLength), 4 });
    frameData.append(std::span { slice1Bytes });

    CMBlockBufferRef rawBlockBuffer = nullptr;
    ASSERT_EQ(PAL::CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, frameData.size(), kCFAllocatorDefault, nullptr, 0, frameData.size(), kCMBlockBufferAssureMemoryNowFlag, &rawBlockBuffer), noErr);
    RetainPtr blockBuffer = adoptCF(rawBlockBuffer);
    ASSERT_EQ(PAL::CMBlockBufferReplaceDataBytes(frameData.span().data(), blockBuffer, 0, frameData.size()), noErr);

    CMSampleTimingInfo timing = { PAL::CMTimeMake(1, 30), PAL::CMTimeMake(0, 30), PAL::CMTimeMake(0, 30) };
    size_t sampleSize = frameData.size();
    CMSampleBufferRef rawSampleBuffer = nullptr;
    ASSERT_EQ(PAL::CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true, nullptr, nullptr, description, 1, 1, &timing, 1, &sampleSize, &rawSampleBuffer), noErr);
    RetainPtr sample = adoptCF(rawSampleBuffer);

    EXPECT_TRUE(convertHEVCCMSampleBufferToAnnexB(sample, false).isEmpty());
}

// Annex B stream carrying an SPS and an IDR slice but no VPS.
static constexpr uint8_t kHEVCAnnexBSpsThenSlice[] = {
    0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0xaa, 0xbb, 0xcc,
    0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x11, 0x22, 0x33,
};

TEST(HEVCUtilitiesCocoa, CreateVideoInfoFromAnnexBReturnsNullptrForSpsOnlyFrame)
{
    auto naluIndices = findNaluIndices(std::span { kHEVCAnnexBSpsThenSlice });
    ASSERT_EQ(naluIndices.size(), 2u);
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(std::span { kHEVCAnnexBSpsThenSlice }, naluIndices));
}

TEST(HEVCUtilitiesCocoa, ConvertsAnnexBToLengthPrefixedKeepsAllNalusWhenVpsMissing)
{
    auto naluIndices = findNaluIndices(std::span { kHEVCAnnexBSpsThenSlice });
    ASSERT_EQ(naluIndices.size(), 2u);

    auto lengthPrefixed = convertHEVCAnnexBToLengthPrefixed(std::span { kHEVCAnnexBSpsThenSlice }, naluIndices);
    constexpr size_t spsSize = 5;
    constexpr size_t sliceSize = 5;
    ASSERT_EQ(lengthPrefixed.size(), 4 + spsSize + 4 + sliceSize);
    EXPECT_EQ(lengthPrefixed[3], spsSize);
    EXPECT_EQ(lengthPrefixed[4], 0x42);
    EXPECT_EQ(lengthPrefixed[4 + spsSize + 3], sliceSize);
    EXPECT_EQ(lengthPrefixed[4 + spsSize + 4], 0x26);
}

// VPS present but not followed by SPS/PPS.
static constexpr uint8_t kHEVCAnnexBVpsThenSlice[] = {
    0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xaa, 0xbb,
    0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x11, 0x22, 0x33,
};

TEST(HEVCUtilitiesCocoa, CreateVideoInfoFromAnnexBReturnsNullptrWhenVpsNotFollowedBySpsAndPps)
{
    auto naluIndices = findNaluIndices(std::span { kHEVCAnnexBVpsThenSlice });
    ASSERT_EQ(naluIndices.size(), 2u);
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(std::span { kHEVCAnnexBVpsThenSlice }, naluIndices));
}

TEST(HEVCUtilitiesCocoa, ConvertsAnnexBToLengthPrefixedKeepsVpsWhenSpsAndPpsMissing)
{
    auto naluIndices = findNaluIndices(std::span { kHEVCAnnexBVpsThenSlice });
    ASSERT_EQ(naluIndices.size(), 2u);

    auto lengthPrefixed = convertHEVCAnnexBToLengthPrefixed(std::span { kHEVCAnnexBVpsThenSlice }, naluIndices);
    constexpr size_t vpsSize = 4;
    constexpr size_t sliceSize = 5;
    ASSERT_EQ(lengthPrefixed.size(), 4 + vpsSize + 4 + sliceSize);
    EXPECT_EQ(lengthPrefixed[3], vpsSize);
    EXPECT_EQ(lengthPrefixed[4], 0x40);
    EXPECT_EQ(lengthPrefixed[4 + vpsSize + 3], sliceSize);
    EXPECT_EQ(lengthPrefixed[4 + vpsSize + 4], 0x26);
}

// VPS, SPS and PPS of a 1920x1080 stream (libwebrtc's h265_bitstream_parser_unittest.cc), then an IDR slice.
static constexpr uint8_t kHEVCAnnexBParameterSetsThenSlice[] = {
    0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x04, 0x08,
    0x00, 0x00, 0x03, 0x00, 0x9d, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x78,
    0x95, 0x98, 0x09, 0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x04, 0x08,
    0x00, 0x00, 0x03, 0x00, 0x9d, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x78,
    0xb0, 0x03, 0xc0, 0x80, 0x10, 0xe5, 0x96, 0x56, 0x69, 0x24, 0xca, 0xe0,
    0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x01, 0xe0, 0x80,
    0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc1, 0x72, 0xb4, 0x62, 0x40, 0x00,
    0x00, 0x01, 0x26, 0x01, 0xaf, 0x08, 0x42, 0x23, 0x10,
};

TEST(HEVCUtilitiesCocoa, CreateVideoInfoFromAnnexBParameterSets)
{
    auto naluIndices = findNaluIndices(std::span { kHEVCAnnexBParameterSetsThenSlice });
    ASSERT_EQ(naluIndices.size(), 4u);
    RefPtr videoInfo = createVideoInfoFromHEVCAnnexBStream(std::span { kHEVCAnnexBParameterSetsThenSlice }, naluIndices);
    ASSERT_TRUE(!!videoInfo);
    EXPECT_EQ(videoInfo->codecName(), FourCC(kCMVideoCodecType_HEVC));
    EXPECT_EQ(videoInfo->size(), FloatSize(1920, 1080));
    EXPECT_EQ(videoInfo->reorderQueueMaxSize(), 2);

    // Without the PPS.
    naluIndices.removeAt(2);
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(std::span { kHEVCAnnexBParameterSetsThenSlice }, naluIndices));
}

TEST(HEVCUtilitiesCocoa, ConvertsAnnexBToLengthPrefixedSkipsParameterSets)
{
    auto naluIndices = findNaluIndices(std::span { kHEVCAnnexBParameterSetsThenSlice });
    ASSERT_EQ(naluIndices.size(), 4u);

    auto lengthPrefixed = convertHEVCAnnexBToLengthPrefixed(std::span { kHEVCAnnexBParameterSetsThenSlice }, naluIndices);
    constexpr size_t sliceSize = 7;
    ASSERT_EQ(lengthPrefixed.size(), 4 + sliceSize);
    EXPECT_EQ(lengthPrefixed[3], sliceSize);
    EXPECT_TRUE(equalSpans(lengthPrefixed.span().subspan(4), std::span { kHEVCAnnexBParameterSetsThenSlice }.last(sliceSize)));
}

TEST(HEVCUtilitiesCocoa, AnnexBEmptyInput)
{
    static constexpr uint8_t nonNullEmpty[1] { };
    Vector<uint8_t> emptyVector;
    for (auto data : { std::span<const uint8_t> { }, emptyVector.span(), std::span { nonNullEmpty }.first(0) }) {
        EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(data, { }));
        EXPECT_TRUE(convertHEVCAnnexBToLengthPrefixed(data, { }).isEmpty());
    }
    EXPECT_FALSE(!!createVideoInfoFromHVCC({ }));

    // Two NAL units with empty payloads, then a VPS of one byte.
    static constexpr uint8_t startCodes[] = { 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x40 };
    auto naluIndices = findNaluIndices(std::span { startCodes });
    ASSERT_EQ(naluIndices.size(), 3u);
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(std::span { startCodes }, naluIndices));
    EXPECT_EQ(convertHEVCAnnexBToLengthPrefixed(std::span { startCodes }, naluIndices).size(), 4u + 1u);
}

// Indices whose payloads don't lie within the data are not found.
TEST(HEVCUtilitiesCocoa, AnnexBIndicesOutsideTheData)
{
    static constexpr uint8_t vpsSpsPps[] = { 0x00, 0x00, 0x01, 0x40, 0x01, 0x00, 0x00, 0x01, 0x42, 0x01, 0x00, 0x00, 0x01, 0x44, 0x01 };
    auto vps = std::span { vpsSpsPps };

    Vector<NaluIndex> vpsOutside { { 0, 30, 2 }, { 5, 8, 2 }, { 10, 13, 2 } };
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(vps, vpsOutside));

    Vector<NaluIndex> vpsTooLong { { 0, 3, 20 }, { 5, 8, 2 }, { 10, 13, 2 } };
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(vps, vpsTooLong));

    Vector<NaluIndex> spsOutside { { 0, 3, 2 }, { 5, 30, 2 }, { 10, 13, 2 } };
    EXPECT_FALSE(!!createVideoInfoFromHEVCAnnexBStream(vps, spsOutside));
    EXPECT_EQ(convertHEVCAnnexBToLengthPrefixed(vps.first(10), Vector<NaluIndex> { { 0, 3, 2 }, { 5, 8, 2 }, { 10, 13, 0 } }).size(), 4u + 2u + 4u + 2u);
}

TEST(HEVCUtilitiesCocoa, WebRTCDecoderCodecStrings)
{
    EXPECT_TRUE(isValidWebRTCDecoderCodecString(VideoCodecType::H264, "avc1.64001F"_s));
    EXPECT_TRUE(isValidWebRTCDecoderCodecString(VideoCodecType::H264, "avc1.640034"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::H264, "avc1.6E0034"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::H264, "avc1.640035"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::H264, "avc3.64001F"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::H265, "hvc1"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::H265, "avc1.64001F"_s));
    EXPECT_TRUE(isValidWebRTCDecoderCodecString(VideoCodecType::VP9, "vp09.00.10.08"_s));

    EXPECT_TRUE(isValidWebRTCDecoderCodecString(VideoCodecType::AV1, "av01.0.04M.08"_s));
    EXPECT_TRUE(isValidWebRTCDecoderCodecString(VideoCodecType::AV1, "av01.2."_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::AV1, "av01.3.04M.08"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::AV1, "av01.0"_s));
    EXPECT_FALSE(isValidWebRTCDecoderCodecString(VideoCodecType::AV1, "av01.00"_s));

    String utf16 = "avc1.64001F"_s;
    utf16.convertTo16Bit();
    EXPECT_TRUE(isValidWebRTCDecoderCodecString(VideoCodecType::H264, utf16));
}

TEST(HEVCUtilitiesCocoa, WebRTCEncoderConfigurations)
{
    EXPECT_TRUE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, { }, false, VideoEncoderScalabilityMode::L1T1));
    EXPECT_TRUE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, { }, true, VideoEncoderScalabilityMode::L1T2));
    EXPECT_FALSE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, { }, false, VideoEncoderScalabilityMode::L1T2));
    EXPECT_FALSE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, { }, true, VideoEncoderScalabilityMode::L1T3));
    EXPECT_TRUE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, "avc1.42E01F"_s, false, VideoEncoderScalabilityMode::L1T1));
    EXPECT_FALSE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, "avc1.7A0033"_s, false, VideoEncoderScalabilityMode::L1T1));
    EXPECT_FALSE(isValidWebRTCEncoderConfiguration(VideoCodecType::H264, ""_s, false, VideoEncoderScalabilityMode::L1T1));

    EXPECT_TRUE(isValidWebRTCEncoderConfiguration(VideoCodecType::H265, { }, false, VideoEncoderScalabilityMode::L1T1));
    EXPECT_FALSE(isValidWebRTCEncoderConfiguration(VideoCodecType::H265, { }, true, VideoEncoderScalabilityMode::L1T2));
    EXPECT_FALSE(isValidWebRTCEncoderConfiguration(VideoCodecType::H265, "hvc1"_s, false, VideoEncoderScalabilityMode::L1T1));
}

} // namespace TestWebKitAPI

#endif // PLATFORM(COCOA)
