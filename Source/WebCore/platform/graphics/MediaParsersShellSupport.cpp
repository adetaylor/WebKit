/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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
#include "MediaParsersShellSupport.h"

#include "FourCC.h"
#include "HEVCUtilities.h"
#include "SharedBuffer.h"
#include "TrackInfo.h"
#include "VideoCodecParameterTypes.h"

namespace WebCore {

String codecNameString(CodecKind kind)
{
    switch (kind) {
    case CodecKind::Unnamed:
        return { };
    case CodecKind::Av01:
        return "av01"_s;
    case CodecKind::Vp8:
        return "vp8"_s;
    case CodecKind::Vp9:
        return "vp9"_s;
    case CodecKind::Vp08:
        return "vp08"_s;
    case CodecKind::Vp09:
        return "vp09"_s;
    }
    ASSERT_NOT_REACHED();
    return { };
}

HEVCParameters makeHEVCParameters(const HEVCCodecFields& fields)
{
    return {
        .codec = fields.codec == HEVCCodecFields::Codec::Hev1 ? HEVCParameters::Codec::Hev1 : HEVCParameters::Codec::Hvc1,
        .generalProfileSpace = fields.generalProfileSpace,
        .generalProfileIDC = fields.generalProfileIDC,
        .generalProfileCompatibilityFlags = fields.generalProfileCompatibilityFlags,
        .generalTierFlag = fields.generalTierFlag,
        .generalConstraintIndicatorFlags = std::span { fields.generalConstraintIndicatorFlags }.first(fields.generalConstraintIndicatorFlagCount),
        .generalLevelIDC = fields.generalLevelIDC,
    };
}

Ref<VideoInfo> makeVideoInfo(const VideoInfoFields& fields, String&& codecString, Vector<uint8_t>&& atom, const std::optional<PlatformVideoColorSpace>& colorSpaceOverride)
{
    PlatformVideoColorSpace colorSpace {
        .primaries = fields.primaries,
        .transfer = fields.transfer,
        .matrix = fields.matrix,
        .fullRange = fields.fullRange,
    };
    overrideVideoColorSpaceAsNeeded(colorSpace, colorSpaceOverride);

    return VideoInfo::create({
        {
            .codecName = FourCC { fields.codecName },
            .codecString = WTF::move(codecString)
        }, {
            .size = { fields.width, fields.height },
            .displaySize = { fields.displayWidth, fields.displayHeight },
            .bitDepth = fields.bitDepth,
            .colorSpace = WTF::move(colorSpace),
            .extensionAtoms = { FillWith { }, 1, TrackInfo::AtomData { FourCC { fields.atomType }, SharedBuffer::create(WTF::move(atom)) } }
        }
    });
}

}
