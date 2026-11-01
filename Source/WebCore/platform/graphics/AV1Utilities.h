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

#pragma once

#include <WebCore/AV1CodecConfigurationRecord.h>
#include <WebCore/FloatSize.h>
#include <WebCore/PlatformExportMacros.h>
#include <WebCore/PlatformVideoColorSpace.h>
#include <optional>
#include <span>
#include <wtf/RefPtr.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

struct PlatformMediaCapabilitiesVideoConfiguration;
class VideoInfo;

WEBCORE_EXPORT std::optional<AV1CodecConfigurationRecord> parseAV1CodecParameters(StringView codecString);
WEBCORE_EXPORT String createAV1CodecParametersString(const AV1CodecConfigurationRecord&);

NODELETE WEBCORE_EXPORT bool validateAV1ConfigurationRecord(const AV1CodecConfigurationRecord&);
WEBCORE_EXPORT bool validateAV1PerLevelConstraints(const AV1CodecConfigurationRecord&, const PlatformMediaCapabilitiesVideoConfiguration&);

WEBCORE_EXPORT std::optional<AV1CodecConfigurationRecord> parseAV1DecoderConfigurationRecord(std::span<const uint8_t>);
WEBCORE_EXPORT RefPtr<VideoInfo> createVideoInfoFromAV1Stream(std::span<const uint8_t>, std::optional<FloatSize> = std::nullopt, const std::optional<PlatformVideoColorSpace>& colorSpaceOverride = std::nullopt);

// A whole string that parseInteger<uint8_t>() reads as one of the enumeration's values.
WEBCORE_EXPORT std::optional<AV1ConfigurationProfile> parseAV1ProfileString(StringView);
WEBCORE_EXPORT std::optional<AV1ConfigurationLevel> parseAV1LevelString(StringView);

}
