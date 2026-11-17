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

#import "config.h"
#import "LibWebRTCCodecsProxy.h"

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#import <WebCore/CMUtilities.h>
#import <WebCore/HEVCUtilitiesCocoa.h>
#import <WebCore/LibWebRTCProvider.h>
#import <VideoToolbox/VTCompressionProperties.h>

namespace WebKit {
using namespace WebCore;

void setLibWebRTCLoggingLevel(uint8_t level)
{
    WebCore::LibWebRTCProvider::setRTCLogging(static_cast<WTFLogLevel>(level));
}

bool isValidDecoderCodecString(VideoCodecType codecType, CodecStringArgument& codecStringArgument)
{
    auto codecString = codecStringArgument.take();
    if (!codecString)
        return false;
    return codecString->isNull() || isValidWebRTCDecoderCodecString(codecType, *codecString);
}

static PlatformVideoColorSpace platformColorSpace(LibWebRTCCodecsColorSpace colorSpace)
{
    PlatformVideoColorSpace result;
    if (colorSpace.hasPrimaries)
        result.primaries = colorSpace.primaries;
    if (colorSpace.hasTransfer)
        result.transfer = colorSpace.transfer;
    if (colorSpace.hasMatrix)
        result.matrix = colorSpace.matrix;
    if (colorSpace.hasFullRange)
        result.fullRange = colorSpace.fullRange;
    if (colorSpace.hasChromaLocation)
        result.chromaLocation = colorSpace.chromaLocation;
    return result;
}

static LibWebRTCCodecsColorSpace codecsColorSpace(const PlatformVideoColorSpace& colorSpace)
{
    LibWebRTCCodecsColorSpace result;
    if (colorSpace.primaries) {
        result.hasPrimaries = true;
        result.primaries = *colorSpace.primaries;
    }
    if (colorSpace.transfer) {
        result.hasTransfer = true;
        result.transfer = *colorSpace.transfer;
    }
    if (colorSpace.matrix) {
        result.hasMatrix = true;
        result.matrix = *colorSpace.matrix;
    }
    if (colorSpace.fullRange) {
        result.hasFullRange = true;
        result.fullRange = *colorSpace.fullRange;
    }
    if (colorSpace.chromaLocation) {
        result.hasChromaLocation = true;
        result.chromaLocation = *colorSpace.chromaLocation;
    }
    return result;
}

CMFormatDescriptionRef createDecoderFormatDescription(const VideoInfo& videoInfo, LibWebRTCCodecsColorSpace colorSpaceOverride)
{
    auto colorSpace = platformColorSpace(colorSpaceOverride);
    if (!colorSpace.isValid())
        return createFormatDescriptionFromTrackInfo(videoInfo).leakRef();

    auto data = videoInfo.toVideoInfoData();
    overrideVideoColorSpaceAsNeeded(data.second.colorSpace, colorSpace);
    Ref updatedVideoInfo = VideoInfo::create(WTF::move(data));
    return createFormatDescriptionFromTrackInfo(updatedVideoInfo).leakRef();
}

LibWebRTCCodecsColorSpace colorSpaceOfPixelBuffer(CVPixelBufferRef pixelBuffer)
{
    return codecsColorSpace(computeVideoFrameColorSpace(pixelBuffer));
}

bool isValidEncoderConfiguration(VideoCodecType codecType, CodecStringArgument& codecStringArgument, bool useLowLatency, VideoEncoderScalabilityMode scalabilityMode)
{
    auto codecString = codecStringArgument.take();
    if (!codecString)
        return false;
    return isValidWebRTCEncoderConfiguration(codecType, *codecString, useLowLatency, scalabilityMode);
}

void attachCodecsColorSpace(CVPixelBufferRef pixelBuffer, LibWebRTCCodecsColorSpace colorSpace)
{
    attachColorSpaceToPixelBuffer(platformColorSpace(colorSpace), pixelBuffer);
}

CFDictionaryRef copyCompressionSessionColorProperties(LibWebRTCCodecsColorSpace codecsColorSpace)
{
    auto colorSpace = platformColorSpace(codecsColorSpace);
    RetainPtr properties = adoptCF(CFDictionaryCreateMutable(kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    if (colorSpace.primaries) {
        if (RetainPtr primaries = convertToCMColorPrimaries(*colorSpace.primaries))
            CFDictionarySetValue(properties.get(), kVTCompressionPropertyKey_ColorPrimaries, primaries.get());
    }
    if (colorSpace.transfer) {
        if (RetainPtr transferFunction = convertToCMTransferFunction(*colorSpace.transfer))
            CFDictionarySetValue(properties.get(), kVTCompressionPropertyKey_TransferFunction, transferFunction.get());
    }
    if (colorSpace.matrix) {
        if (RetainPtr matrix = convertToCMYCbCRMatrix(*colorSpace.matrix))
            CFDictionarySetValue(properties.get(), kVTCompressionPropertyKey_YCbCrMatrix, matrix.get());
    }
    return properties.leakRef();
}

}

#endif
