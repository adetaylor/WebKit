/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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
#include "AV1Utilities.h"

#if ENABLE(WEBCORE_SWIFT)

#include "MediaParsersShellSupport.h"
#include "PlatformMediaCapabilitiesVideoConfiguration.h"
#include "TrackInfo.h"
#include "WebCore-Swift.h"

namespace WebCore {

// The parsing, validation and av1C construction are in AV1Utilities.swift.

std::optional<AV1CodecConfigurationRecord> parseAV1CodecParameters(StringView codec)
{
    auto result = parseAV1CodecParametersImpl(mediaParserText(codec));
    if (!result.parsed)
        return std::nullopt;
    return av1CodecConfigurationRecord(result.fields, "av01"_s);
}

String createAV1CodecParametersString(const AV1CodecConfigurationRecord& record)
{
    return makeStringFromShortString(createAV1CodecParametersStringImpl(av1CodecFields(record)));
}

bool validateAV1ConfigurationRecord(const AV1CodecConfigurationRecord& record)
{
    return validateAV1ConfigurationRecordImpl(av1CodecFields(record));
}

bool validateAV1PerLevelConstraints(const AV1CodecConfigurationRecord& record, const PlatformMediaCapabilitiesVideoConfiguration& configuration)
{
    return validateAV1PerLevelConstraintsImpl(av1CodecFields(record), configuration.width, configuration.height, configuration.framerate, configuration.bitrate);
}

std::optional<AV1CodecConfigurationRecord> parseAV1DecoderConfigurationRecord(std::span<const uint8_t> buffer)
{
    auto result = parseAV1DecoderConfigurationRecordImpl({ buffer });
    if (!result.parsed)
        return std::nullopt;
    return av1CodecConfigurationRecord(result.fields, "av01"_s);
}

RefPtr<VideoInfo> createVideoInfoFromAV1Stream(std::span<const uint8_t> data, std::optional<FloatSize> displaySize, const std::optional<PlatformVideoColorSpace>& colorSpaceOverride)
{
    Vector<uint8_t> atom;
    MediaParserShortString codecString;
    auto result = createVideoInfoFromAV1StreamImpl({ data }, atom, codecString);
    if (!result.created)
        return nullptr;
    if (displaySize) {
        result.videoInfo.displayWidth = displaySize->width();
        result.videoInfo.displayHeight = displaySize->height();
    }
    return makeVideoInfo(result.videoInfo, makeStringFromShortString(codecString), WTF::move(atom), colorSpaceOverride);
}

std::optional<AV1ConfigurationProfile> parseAV1ProfileString(StringView string)
{
    auto result = parseAV1ProfileStringImpl(mediaParserText(string));
    if (!result.parsed)
        return std::nullopt;
    return static_cast<AV1ConfigurationProfile>(result.value);
}

std::optional<AV1ConfigurationLevel> parseAV1LevelString(StringView string)
{
    auto result = parseAV1LevelStringImpl(mediaParserText(string));
    if (!result.parsed)
        return std::nullopt;
    return static_cast<AV1ConfigurationLevel>(result.value);
}

}

#endif // ENABLE(WEBCORE_SWIFT)
