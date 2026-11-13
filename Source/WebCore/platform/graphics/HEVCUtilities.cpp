/*
 * Copyright (C) 2018-2026 Apple Inc. All rights reserved.
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
#include "HEVCUtilities.h"

#if ENABLE(WEBCORE_SWIFT)

#include "FourCC.h"
#include "MediaParsersShellSupport.h"
#include "SharedBuffer.h"
#include "WebCore-Swift.h"

namespace WebCore {

// The parsing and the string building are in HEVCCodecStrings.swift.

std::optional<AVCParameters> parseAVCCodecParameters(StringView codec)
{
    auto result = parseAVCCodecParametersImpl(mediaParserText(codec));
    if (!result.parsed)
        return std::nullopt;
    return result.parameters;
}

String createAVCCodecParametersString(const AVCParameters& parameters)
{
    return makeStringFromShortString(createAVCCodecParametersStringImpl(parameters));
}

std::optional<AVCParameters> parseAVCDecoderConfigurationRecord(const SharedBuffer& buffer)
{
    auto result = parseAVCDecoderConfigurationRecordImpl({ buffer.span() });
    if (!result.parsed)
        return std::nullopt;
    return result.parameters;
}

std::optional<HEVCParameters> parseHEVCCodecParameters(StringView codec)
{
    auto result = parseHEVCCodecParametersImpl(mediaParserText(codec));
    if (!result.parsed)
        return std::nullopt;
    return makeHEVCParameters(result.fields);
}

String createHEVCCodecParametersString(const HEVCParameters& parameters)
{
    HEVCCodecFields fields;
    fields.codec = parameters.codec == HEVCParameters::Codec::Hev1 ? HEVCCodecFields::Codec::Hev1 : HEVCCodecFields::Codec::Hvc1;
    fields.generalProfileSpace = parameters.generalProfileSpace;
    fields.generalProfileIDC = parameters.generalProfileIDC;
    fields.generalProfileCompatibilityFlags = parameters.generalProfileCompatibilityFlags;
    fields.generalTierFlag = parameters.generalTierFlag;
    fields.generalLevelIDC = parameters.generalLevelIDC;
    // Internals passes any number of constraint flags, so they don't go in the fields.
    return createHEVCCodecParametersStringImpl(fields, { parameters.generalConstraintIndicatorFlags.span() });
}

std::optional<HEVCParameters> parseHEVCDecoderConfigurationRecord(FourCC codecCode, const SharedBuffer& buffer)
{
    auto result = parseHEVCDecoderConfigurationRecordImpl(codecCode.value, { buffer.span() });
    if (!result.parsed)
        return std::nullopt;
    return makeHEVCParameters(result.fields);
}

std::optional<DoViParameters> parseDoViCodecParameters(StringView codec)
{
    auto result = parseDoViCodecParametersImpl(mediaParserText(codec));
    if (!result.parsed)
        return std::nullopt;
    return result.parameters;
}

std::optional<DoViParameters> parseDoViDecoderConfigurationRecord(const SharedBuffer& buffer)
{
    auto result = parseDoViDecoderConfigurationRecordImpl({ buffer.span() });
    if (!result.parsed)
        return std::nullopt;
    return result.parameters;
}

String createDoViCodecParametersString(const DoViParameters& parameters)
{
    return makeStringFromShortString(createDoViCodecParametersStringImpl(parameters));
}

std::optional<HVCCParameterSets> parseHVCCParameterSets(std::span<const uint8_t> hvcc)
{
    swift::Int lengthFieldSize = 0;
    MediaParserUInt32Vector words;
    if (!parseHVCCParameterSetsImpl({ hvcc }, lengthFieldSize, words))
        return std::nullopt;

    // Four words per parameter set: its NAL unit type, its offset in hvcc (low half, then high half), and its size.
    HVCCParameterSets result;
    result.lengthFieldSize = static_cast<size_t>(lengthFieldSize);
    result.paramSets.reserveInitialCapacity(words.size() / 4);
    for (size_t i = 0; i + 3 < words.size(); i += 4) {
        auto offset = static_cast<size_t>(words[i + 1] | static_cast<uint64_t>(words[i + 2]) << 32);
        result.paramSets.append({ static_cast<HEVCNaluType>(words[i]), hvcc.subspan(offset, words[i + 3]) });
    }
    return result;
}

}

#endif // ENABLE(WEBCORE_SWIFT)
