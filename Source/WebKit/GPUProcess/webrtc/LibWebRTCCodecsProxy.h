/*
 * Copyright (C) 2020-2025 Apple Inc. All rights reserved.
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

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#include "SwiftCoding.h"
#include <CoreMedia/CMFormatDescription.h>
#include <WebCore/PlatformVideoColorSpace.h>
#include <WebCore/VideoCodecType.h>
#include <WebCore/VideoEncoderScalabilityMode.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class VideoInfo;
}

namespace WebKit {

// Swift doesn't give a function that takes a class template's reference type the overloads that take a Span, unless
// the type is spelled through an alias.
using CodecStringArgument = IPC::CxxDecodedArgument<String>;

// A WebCore::PlatformVideoColorSpace that Swift can make and read: each value counts only if the flag before it is set.
struct LibWebRTCCodecsColorSpace {
    bool hasPrimaries { false };
    WebCore::PlatformVideoColorPrimaries primaries { };
    bool hasTransfer { false };
    WebCore::PlatformVideoTransferCharacteristics transfer { };
    bool hasMatrix { false };
    WebCore::PlatformVideoMatrixCoefficients matrix { };
    bool hasFullRange { false };
    bool fullRange { false };
    bool hasChromaLocation { false };
    WebCore::PlatformVideoChromaLocation chromaLocation { };
};

// What LibWebRTCCodecsProxy.swift's decoders leave to WebCore: the check of a codec string, which a null String passes;
// the format description of a video info, with the values that the override sets replacing the video info's, returned
// +1; and the colour space of a decoded frame, as WebCore::VideoFrameCV computes it.
bool isValidDecoderCodecString(WebCore::VideoCodecType, CodecStringArgument&);
CMFormatDescriptionRef WTF_NULLABLE createDecoderFormatDescription(const WebCore::VideoInfo&, LibWebRTCCodecsColorSpace colorSpaceOverride) CF_RETURNS_RETAINED;
LibWebRTCCodecsColorSpace colorSpaceOfPixelBuffer(CVPixelBufferRef WTF_NONNULL);

// What LibWebRTCCodecsProxy.swift's encoders leave to WebCore: the check of a configuration and its codec string, which
// a null String passes; giving a frame its colour space; and the colour properties of a compression session for the
// colour space of the frames it encodes, returned +1.
bool isValidEncoderConfiguration(WebCore::VideoCodecType, CodecStringArgument&, bool useLowLatency, WebCore::VideoEncoderScalabilityMode);
void attachCodecsColorSpace(CVPixelBufferRef WTF_NONNULL, LibWebRTCCodecsColorSpace);
CFDictionaryRef WTF_NONNULL copyCompressionSessionColorProperties(LibWebRTCCodecsColorSpace) CF_RETURNS_RETAINED;

void setLibWebRTCLoggingLevel(uint8_t);

}

#endif
