/*
 * Copyright (C) 2018-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2021 Apple Inc. All rights reserved.
 * Copyright (C) 2025-2026 Apple Inc. All rights reserved.
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

#include <WebCore/PlatformVideoColorPrimaries.h>
#include <WebCore/PlatformVideoMatrixCoefficients.h>
#include <WebCore/PlatformVideoTransferCharacteristics.h>
#include <cstddef>
#include <cstdint>

namespace WebCore {

// Padded to 4 bytes for Swift interop (rdar://191583570).
struct alignas(4) AVCParameters {
    uint8_t profileIDC { 0 };
    uint8_t constraintsFlags { 0 };
    uint8_t levelIDC { 0 };
};

struct DoViParameters {
    enum class Codec { AVC1, AVC3, HEV1, HVC1 } codec { Codec::HVC1 };
    uint16_t bitstreamProfileID { 0 };
    uint16_t bitstreamLevelID { 0 };
};

// HEVCParameters without its Vector, which Swift can't build.
struct HEVCCodecFields {
    enum class Codec : uint8_t { Hev1, Hvc1 };
    Codec codec { Codec::Hvc1 };
    uint16_t generalProfileSpace { 0 };
    uint16_t generalProfileIDC { 0 };
    uint32_t generalProfileCompatibilityFlags { 0 };
    uint8_t generalTierFlag { 0 };
    uint8_t generalConstraintIndicatorFlags[6] { };
    uint8_t generalConstraintIndicatorFlagCount { 6 };
    uint16_t generalLevelIDC { 0 };
};

// The QP of the last slice a bitstream parser saw, and the raw value of the parser's status: whether it found one.
struct SliceQPResult {
    int32_t qp { 0 };
    uint8_t status { 0 };
};

// What Swift parses out of a codec string or a decoder configuration record, if it parsed.
struct AVCParametersResult {
    AVCParameters parameters;
    bool parsed { false };
};

struct DoViParametersResult {
    DoViParameters parameters;
    bool parsed { false };
};

struct HEVCCodecFieldsResult {
    HEVCCodecFields fields;
    bool parsed { false };
};

// VideoCodecType and VideoEncoderScalabilityMode for Swift, whose headers would bring WebCore_Private into this module.
enum class WebRTCVideoCodec : uint8_t { H264, H265, VP9, AV1 };
enum class WebRTCScalabilityMode : uint8_t { L1T1, L1T2, L1T3 };

// Whether the GPU process's LibWebRTC decoders and encoders take a codec string. A parsed HEVC string is valid only if
// VideoToolbox can decode it, which the caller asks with the fields.
struct WebRTCCodecStringCheck {
    HEVCCodecFields hevcFields;
    bool valid { false };
    bool needsHEVCDecoderCheck { false };
};

// The codec names a parse can produce, so that Swift doesn't build the String. Unnamed is a null String.
enum class CodecKind : uint8_t {
    Unnamed,
    Av01,
    Vp8,
    Vp9,
    Vp08,
    Vp09,
};

// The parts of a VideoInfo that Swift computes; makeVideoInfo() builds the VideoInfo.
struct VideoInfoFields {
    uint32_t codecName { 0 };
    uint32_t atomType { 0 };
    float width { 0 };
    float height { 0 };
    float displayWidth { 0 };
    float displayHeight { 0 };
    uint8_t bitDepth { 8 };
    PlatformVideoColorPrimaries primaries { PlatformVideoColorPrimaries::Unspecified };
    PlatformVideoTransferCharacteristics transfer { PlatformVideoTransferCharacteristics::Unspecified };
    PlatformVideoMatrixCoefficients matrix { PlatformVideoMatrixCoefficients::Unspecified };
    bool fullRange { false };
};

// A parameter set NAL unit in the caller's buffer.
struct ParameterSetRange {
    uint8_t type { 0 };
    size_t offset { 0 };
    size_t size { 0 };
};

}
