/*
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

#import "config.h"
#import "H264UtilitiesCocoa.h"

#if ENABLE(WEBCORE_SWIFT)

#import "AnnexBUtilities.h"
#import "CMUtilities.h"
#import "FormatDescriptionUtilities.h"
#import "H264Utilities.h"
#import "Logging.h"
#import "TrackInfo.h"
#import "WebCore-Swift.h"

#import <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

// The avcC walk and the Annex B parameter set search are in H264Utilities.swift.

RefPtr<VideoInfo> createVideoInfoFromAVCC(std::span<const uint8_t> avcc)
{
    MediaParserByteVector parameterSets;
    MediaParserUInt32Vector parameterSetSizes;
    size_t lengthSize = createVideoInfoFromAVCCImpl({ avcc }, parameterSets, parameterSetSizes);
    if (!lengthSize)
        return nullptr;

    Vector<const uint8_t*> paramSetPtrs;
    Vector<size_t> paramSetSizes;
    paramSetPtrs.reserveInitialCapacity(parameterSetSizes.size());
    paramSetSizes.reserveInitialCapacity(parameterSetSizes.size());
    auto remainingParameterSets = parameterSets.span();
    for (size_t size : parameterSetSizes) {
        paramSetPtrs.append(remainingParameterSets.data());
        paramSetSizes.append(size);
        remainingParameterSets = remainingParameterSets.subspan(size);
    }

    CMFormatDescriptionRef rawDescription = nullptr;
    if (PAL::CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, paramSetPtrs.size(), paramSetPtrs.span().data(), paramSetSizes.span().data(), lengthSize, &rawDescription))
        return nullptr;
    RetainPtr description = adoptCF(rawDescription);
    return createVideoInfoFromFormatDescription(description, findAVCCMaxNumReorderFrames(avcc));
}

Vector<uint8_t> convertAVCCMSampleBufferToAnnexB(CMSampleBufferRef avccSampleBuffer, bool isKeyframe)
{
    return convertParameterSetsCMSampleBufferToAnnexB(avccSampleBuffer, isKeyframe, PAL::CMVideoFormatDescriptionGetH264ParameterSetAtIndex);
}

RefPtr<VideoInfo> createVideoInfoFromAVCAnnexBStream(std::span<const uint8_t> data, const Vector<NaluIndex>& naluIndices)
{
    ParameterSetRange sps;
    ParameterSetRange pps;
    if (!createVideoInfoFromAVCAnnexBStreamImpl({ data }, { naluIndices.span() }, sps, pps)) {
        if (sps.type)
            RELEASE_LOG_ERROR(WebRTC, "createVideoInfoFromAVCAnnexBStream NAL unit following SPS is not PPS");
        return nullptr;
    }

    std::array<std::span<const uint8_t>, 2> paramSets { data.subspan(sps.offset, sps.size), data.subspan(pps.offset, pps.size) };
    std::array<const uint8_t*, 2> paramSetPointers { paramSets[0].data(), paramSets[1].data() };
    std::array<size_t, 2> paramSetSizes { paramSets[0].size(), paramSets[1].size() };

    CMFormatDescriptionRef rawDescription = nullptr;
    if (PAL::CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, paramSetPointers.size(), paramSetPointers.data(), paramSetSizes.data(), 4, &rawDescription) != noErr)
        return nullptr;
    RetainPtr description = adoptCF(rawDescription);
    return createVideoInfoFromFormatDescription(description, findH264AnnexBMaxNumReorderFrames(data, naluIndices));
}

Vector<uint8_t> convertAVCAnnexBToLengthPrefixed(std::span<const uint8_t> data, const Vector<NaluIndex>& naluIndices)
{
    Vector<uint8_t> result;
    if (!convertAVCAnnexBToLengthPrefixedImpl({ data }, { naluIndices.span() }, result))
        RELEASE_LOG_ERROR(WebRTC, "convertAVCAnnexBToLengthPrefixed NAL unit following SPS is not PPS");
    return result;
}

} // namespace WebCore

#endif // ENABLE(WEBCORE_SWIFT)
