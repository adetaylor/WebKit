/*
 * Copyright (C) 2020-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#pragma once

#include <WebCore/MediaParsersCxxBridging.h>
#include <WebCore/VideoCodecParameterTypes.h>
#include <cstdint>
#include <wtf/text/WTFString.h>

namespace WebCore {

namespace VPConfigurationLevel {
constexpr uint8_t Level_1   = 10;
constexpr uint8_t Level_1_1 = 11;
constexpr uint8_t Level_2   = 20;
constexpr uint8_t Level_2_1 = 21;
constexpr uint8_t Level_3   = 30;
constexpr uint8_t Level_3_1 = 31;
constexpr uint8_t Level_4   = 40;
constexpr uint8_t Level_4_1 = 41;
constexpr uint8_t Level_5   = 50;
constexpr uint8_t Level_5_1 = 51;
constexpr uint8_t Level_5_2 = 52;
constexpr uint8_t Level_6   = 60;
constexpr uint8_t Level_6_1 = 61;
constexpr uint8_t Level_6_2 = 62;
}

namespace VPConfigurationChromaSubsampling {
constexpr uint8_t Subsampling_420_Vertical = 0;
constexpr uint8_t Subsampling_420_Colocated = 1;
constexpr uint8_t Subsampling_422 = 2;
constexpr uint8_t Subsampling_444 = 3;
}

namespace VPConfigurationRange {
constexpr uint8_t VideoRange = 0;
constexpr uint8_t FullRange = 1;
}

// Ref: ISO/IEC 23091-2:2019
namespace VPConfigurationColorPrimaries {
constexpr uint8_t BT_709_6 = 1;
constexpr uint8_t Unspecified = 2;
constexpr uint8_t BT_470_6_M = 4;
constexpr uint8_t BT_470_7_BG = 5;
constexpr uint8_t BT_601_7 = 6;
constexpr uint8_t SMPTE_ST_240 = 7;
constexpr uint8_t Film = 8;
constexpr uint8_t BT_2020_Nonconstant_Luminance = 9;
constexpr uint8_t SMPTE_ST_428_1 = 10;
constexpr uint8_t SMPTE_RP_431_2 = 11;
constexpr uint8_t SMPTE_EG_432_1 = 12;
constexpr uint8_t EBU_Tech_3213_E = 22;
}

// Ref: ISO/IEC 23091-2:2019
namespace VPConfigurationTransferCharacteristics {
constexpr uint8_t BT_709_6 = 1;
constexpr uint8_t Unspecified = 2;
constexpr uint8_t BT_470_6_M = 4;
constexpr uint8_t BT_470_7_BG = 5;
constexpr uint8_t BT_601_7 = 6;
constexpr uint8_t SMPTE_ST_240 = 7;
constexpr uint8_t Linear = 8;
constexpr uint8_t Logrithmic = 9;
constexpr uint8_t Logrithmic_Sqrt = 10;
constexpr uint8_t IEC_61966_2_4 = 11;
constexpr uint8_t BT_1361_0 = 12;
constexpr uint8_t IEC_61966_2_1 = 13;
constexpr uint8_t BT_2020_10bit = 14;
constexpr uint8_t BT_2020_12bit = 15;
constexpr uint8_t SMPTE_ST_2084 = 16;
constexpr uint8_t SMPTE_ST_428_1 = 17;
constexpr uint8_t BT_2100_HLG = 18;
}

namespace VPConfigurationMatrixCoefficients {
constexpr uint8_t Identity = 0;
constexpr uint8_t BT_709_6 = 1;
constexpr uint8_t Unspecified = 2;
constexpr uint8_t FCC = 4;
constexpr uint8_t BT_470_7_BG = 5;
constexpr uint8_t BT_601_7 = 6;
constexpr uint8_t SMPTE_ST_240 = 7;
constexpr uint8_t YCgCo = 8;
constexpr uint8_t BT_2020_Nonconstant_Luminance = 9;
constexpr uint8_t BT_2020_Constant_Luminance = 10;
constexpr uint8_t SMPTE_ST_2085 = 11;
constexpr uint8_t Chromacity_Constant_Luminance = 12;
constexpr uint8_t Chromacity_Nonconstant_Luminance = 13;
constexpr uint8_t BT_2100_ICC = 14;
}

struct VPCodecConfigurationRecord {
    String codecName;
    uint8_t profile { 0 };
    uint8_t level { VPConfigurationLevel::Level_1 };
    uint8_t bitDepth { 8 };
    uint8_t chromaSubsampling { VPConfigurationChromaSubsampling::Subsampling_420_Colocated };
    uint8_t videoFullRangeFlag { VPConfigurationRange::VideoRange };
    uint8_t colorPrimaries { VPConfigurationColorPrimaries::BT_709_6 };
    uint8_t transferCharacteristics { VPConfigurationTransferCharacteristics::BT_709_6 };
    uint8_t matrixCoefficients { VPConfigurationMatrixCoefficients::BT_709_6 };

    // Additional information parsed from bitstream
    uint16_t frameWidth { 0 };
    uint16_t frameHeight { 0 };
};

// VPCodecConfigurationRecord without its codecName, so that it crosses between C++ and Swift as a plain value.
struct VPCodecFields {
    uint8_t profile { 0 };
    uint8_t level { VPConfigurationLevel::Level_1 };
    uint8_t bitDepth { 8 };
    uint8_t chromaSubsampling { VPConfigurationChromaSubsampling::Subsampling_420_Colocated };
    uint8_t videoFullRangeFlag { VPConfigurationRange::VideoRange };
    uint8_t colorPrimaries { VPConfigurationColorPrimaries::BT_709_6 };
    uint8_t transferCharacteristics { VPConfigurationTransferCharacteristics::BT_709_6 };
    uint8_t matrixCoefficients { VPConfigurationMatrixCoefficients::BT_709_6 };
    uint16_t frameWidth { 0 };
    uint16_t frameHeight { 0 };
};

inline VPCodecFields vpCodecFields(const VPCodecConfigurationRecord& record)
{
    return {
        .profile = record.profile,
        .level = record.level,
        .bitDepth = record.bitDepth,
        .chromaSubsampling = record.chromaSubsampling,
        .videoFullRangeFlag = record.videoFullRangeFlag,
        .colorPrimaries = record.colorPrimaries,
        .transferCharacteristics = record.transferCharacteristics,
        .matrixCoefficients = record.matrixCoefficients,
        .frameWidth = record.frameWidth,
        .frameHeight = record.frameHeight,
    };
}

inline VPCodecConfigurationRecord vpCodecConfigurationRecord(const VPCodecFields& fields, String&& codecName)
{
    return {
        .codecName = WTF::move(codecName),
        .profile = fields.profile,
        .level = fields.level,
        .bitDepth = fields.bitDepth,
        .chromaSubsampling = fields.chromaSubsampling,
        .videoFullRangeFlag = fields.videoFullRangeFlag,
        .colorPrimaries = fields.colorPrimaries,
        .transferCharacteristics = fields.transferCharacteristics,
        .matrixCoefficients = fields.matrixCoefficients,
        .frameWidth = fields.frameWidth,
        .frameHeight = fields.frameHeight,
    };
}

// What Swift parses out of a codec string, a vpcC record or a frame: the record's fields, and the codec name it gives them.
// Padded to a multiple of 8 bytes for Swift interop (rdar://191583570).
struct alignas(8) VPCodecFieldsResult {
    VPCodecFields fields;
    CodecKind codecName { CodecKind::Unnamed };
    bool parsed { false };
};

struct VP8FrameHeader {
    bool keyframe { false };
    uint8_t version { 0 };
    bool showFrame { true };
    uint32_t partitionSize { 0 };
    uint8_t horizontalScale { 0 };
    uint16_t width { 0 };
    uint8_t verticalScale { 0 };
    uint16_t height { 0 };
    bool colorSpace { false };
    bool needsClamping { false };
};

struct VP8FrameHeaderResult {
    VP8FrameHeader header;
    bool parsed { false };
};

// The parts of a VideoInfo that Swift computes, and its codec string, if Swift could make one.
struct VPVideoInfoResult {
    VideoInfoFields fields;
    MediaParserShortString codecString;
    bool created { false };
};

enum class VPXCodec : uint8_t { Vp8, Vp9 };

// What the VP9 VideoInfo builder reads from libwebm's vp9_parser::Vp9HeaderParser.
struct VP9HeaderFields {
    int profile { 0 };
    int bitDepth { 0 };
    int colorRange { 0 };
    int subsamplingX { 0 };
    int subsamplingY { 0 };
    int colorSpace { 0 };
    int width { 0 };
    int height { 0 };
    int displayWidth { 0 };
    int displayHeight { 0 };
};

// What the VP8 and VP9 VideoInfo builders read from a WebM Video element and its Colour element, as libwebm keeps
// them: each value, unvalidated, and whether the element was present.
struct WebMVideoFields {
    bool hasColour { false };
    bool hasChromaSubsamplingX { false };
    bool hasChromaSubsamplingY { false };
    bool hasRange { false };
    bool hasBitsPerChannel { false };
    bool hasTransferCharacteristics { false };
    bool hasMatrixCoefficients { false };
    bool hasPrimaries { false };
    bool hasDisplayWidth { false };
    bool hasDisplayHeight { false };
    uint64_t chromaSubsamplingX { 0 };
    uint64_t chromaSubsamplingY { 0 };
    uint64_t range { 0 };
    uint64_t bitsPerChannel { 0 };
    uint64_t transferCharacteristics { 0 };
    uint64_t matrixCoefficients { 0 };
    uint64_t primaries { 0 };
    uint64_t displayWidth { 0 };
    uint64_t displayHeight { 0 };
};

}
