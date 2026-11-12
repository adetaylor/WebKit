/*
 * Copyright (C) 2012 Google Inc. All rights reserved.
 * Copyright (C) 2013-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
 * Copyright (C) 2015 Ericsson AB. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer
 *    in the documentation and/or other materials provided with the
 *    distribution.
 * 3. Neither the name of Google Inc. nor the names of its contributors
 *    may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "MediaConstraintsEvaluation.h"

#if ENABLE(MEDIA_STREAM)

#include "JSMeteringMode.h"
#include "MediaConstraints.h"
#include "RealtimeMediaSourceCapabilities.h"
#include "RealtimeMediaSourceSettings.h"
#include "RealtimeVideoCaptureSource.h"
#include "WebCore-Swift.h"

namespace WebCore {

static MediaIntConstraintValues constraintValues(const std::optional<IntConstraint>& constraint)
{
    MediaIntConstraintValues values;
    if (!constraint)
        return values;
    values.isPresent = true;
    values.hasMin = constraint->getMin(values.min);
    values.hasMax = constraint->getMax(values.max);
    values.hasExact = constraint->getExact(values.exact);
    values.hasIdeal = constraint->getIdeal(values.ideal);
    return values;
}

static MediaDoubleConstraintValues constraintValues(const std::optional<DoubleConstraint>& constraint)
{
    MediaDoubleConstraintValues values;
    if (!constraint)
        return values;
    values.isPresent = true;
    values.hasMin = constraint->getMin(values.min);
    values.hasMax = constraint->getMax(values.max);
    values.hasExact = constraint->getExact(values.exact);
    values.hasIdeal = constraint->getIdeal(values.ideal);
    return values;
}

static MediaBooleanConstraintValues constraintValues(const std::optional<BooleanConstraint>& constraint)
{
    MediaBooleanConstraintValues values;
    if (!constraint)
        return values;
    values.isPresent = true;
    values.hasExact = constraint->getExact(values.exact);
    values.hasIdeal = constraint->getIdeal(values.ideal);
    return values;
}

// What a string means to the engine, for each kind of string constraint: the bits of the strings it matches, and its
// mode, if it has one.
struct StringMeaning {
    uint8_t matches { 0 };
    std::optional<uint8_t> mode;
};

static void addMode(MediaStringListValues& list, uint8_t mode)
{
    uint32_t entry = mode + 1;
    unsigned shift = 0;
    for (; shift < 32 && (list.applyOrder >> shift) & 0xF; shift += 4) {
        if (((list.applyOrder >> shift) & 0xF) == entry)
            return;
    }
    if (shift < 32)
        list.applyOrder |= entry << shift;
}

template<typename Meaning>
static MediaStringConstraintValues constraintValues(const std::optional<StringConstraint>& constraint, NOESCAPE const Meaning& meaning)
{
    MediaStringConstraintValues values;
    if (!constraint)
        return values;
    values.isPresent = true;
    auto addStrings = [&](const Vector<String>& strings, MediaStringListValues& list, MediaStringListValues& listWithoutEmptyStrings) {
        list.hasValues = !strings.isEmpty();
        for (auto& string : strings) {
            StringMeaning stringMeaning = meaning(string);
            list.matches |= stringMeaning.matches;
            if (stringMeaning.mode)
                addMode(list, *stringMeaning.mode);
            if (string.isEmpty())
                continue;
            listWithoutEmptyStrings.hasValues = true;
            listWithoutEmptyStrings.matches |= stringMeaning.matches;
            if (stringMeaning.mode)
                addMode(listWithoutEmptyStrings, *stringMeaning.mode);
        }
    };
    addStrings(constraint->exactValues(), values.exact, values.exactWithoutEmptyStrings);
    addStrings(constraint->idealValues(), values.ideal, values.idealWithoutEmptyStrings);
    return values;
}

static StringMeaning facingModeMeaning(const String& string)
{
    StringMeaning meaning;
    for (uint8_t mode = 0; mode <= static_cast<uint8_t>(VideoFacingMode::Right); ++mode) {
        if (string == convertEnumerationToString(static_cast<VideoFacingMode>(mode)))
            meaning.matches |= static_cast<uint8_t>(1 << mode);
    }
    meaning.mode = string.isEmpty() ? mediaConstraintsEmptyFacingMode : static_cast<uint8_t>(RealtimeMediaSourceSettings::videoFacingModeEnum(string));
    return meaning;
}

static StringMeaning whiteBalanceModeMeaning(const String& string)
{
    StringMeaning meaning;
    for (uint8_t mode = 0; mode <= static_cast<uint8_t>(MeteringMode::Continuous); ++mode) {
        if (string == convertEnumerationToString(static_cast<MeteringMode>(mode)))
            meaning.matches |= static_cast<uint8_t>(1 << mode);
    }
    if (auto mode = parseEnumerationFromString<MeteringMode>(string))
        meaning.mode = static_cast<uint8_t>(*mode);
    return meaning;
}

static MediaConstraintSetValues constraintSetValues(const MediaTrackConstraintSetMap& set, const String& hashedId, const String& groupId)
{
    auto matchesHashedId = [&](const String& string) {
        return StringMeaning { static_cast<uint8_t>(string == hashedId), std::nullopt };
    };
    auto matchesGroupId = [&](const String& string) {
        return StringMeaning { static_cast<uint8_t>(string == groupId), std::nullopt };
    };
    return {
        constraintValues(set.width()),
        constraintValues(set.height()),
        constraintValues(set.sampleRate()),
        constraintValues(set.sampleSize()),
        constraintValues(set.aspectRatio()),
        constraintValues(set.frameRate()),
        constraintValues(set.volume()),
        constraintValues(set.zoom()),
        constraintValues(set.echoCancellation()),
        constraintValues(set.torch()),
        constraintValues(set.backgroundBlur()),
        constraintValues(set.powerEfficient()),
        constraintValues(set.facingMode(), facingModeMeaning),
        constraintValues(set.deviceId(), matchesHashedId),
        constraintValues(set.groupId(), matchesGroupId),
        constraintValues(set.whiteBalanceMode(), whiteBalanceModeMeaning),
    };
}

MediaConstraintsCapabilities mediaConstraintsCapabilities(const RealtimeMediaSourceCapabilities& capabilities)
{
    return {
        { capabilities.width().min(), capabilities.width().max() },
        { capabilities.height().min(), capabilities.height().max() },
        { capabilities.sampleRate().min(), capabilities.sampleRate().max() },
        { capabilities.sampleSize().min(), capabilities.sampleSize().max() },
        { capabilities.aspectRatio().min(), capabilities.aspectRatio().max() },
        { capabilities.frameRate().min(), capabilities.frameRate().max() },
        { capabilities.volume().min(), capabilities.volume().max() },
        { capabilities.zoom().min(), capabilities.zoom().max() },
        capabilityModeBits(capabilities.facingMode()),
        capabilityModeBits(capabilities.whiteBalanceModes()),
        static_cast<uint8_t>(capabilities.echoCancellation()),
        capabilities.torch(),
        capabilities.supportsWidth(),
        capabilities.supportsHeight(),
        capabilities.supportsAspectRatio(),
        capabilities.supportsFrameRate(),
        capabilities.supportsZoom(),
        capabilities.supportsVolume(),
        capabilities.supportsSampleRate(),
        capabilities.supportsSampleSize(),
        capabilities.supportsFacingMode(),
        capabilities.supportsEchoCancellation(),
        capabilities.supportsDeviceId(),
        capabilities.supportsWhiteBalanceMode(),
        capabilities.supportsTorch(),
        capabilities.supportsBackgroundBlur(),
    };
}

MediaConstraintsEvaluation evaluateMediaConstraints(const MediaConstraints& constraints, const MediaConstraintsSourceDescription& source, MediaConstraintsEvaluationPurpose purpose)
{
    Vector<MediaConstraintSetValues, 4> advancedSets;
    advancedSets.reserveInitialCapacity(constraints.advancedConstraints.size());
    for (auto& set : constraints.advancedConstraints)
        advancedSets.append(constraintSetValues(set, source.hashedId, source.groupId));

    Vector<int32_t, 16> discreteSampleValues;
    if (source.discreteSampleRates)
        discreteSampleValues.appendVector(*source.discreteSampleRates);
    if (source.discreteSampleSizes)
        discreteSampleValues.appendVector(*source.discreteSampleSizes);

    MediaConstraintsSourceState state;
    state.capabilities = source.capabilities;
    state.mandatory = constraintSetValues(constraints.mandatoryConstraints, source.hashedId, source.groupId);
    state.frameRate = source.frameRate;
    state.zoom = source.zoom;
    state.volume = source.volume;
    state.facingModeFitnessScoreAdjustment = source.facingModeFitnessScoreAdjustment;
    state.width = source.size.width();
    state.height = source.size.height();
    state.sampleRate = source.sampleRate;
    state.sampleSize = source.sampleSize;
    state.advancedSetCount = static_cast<uint32_t>(advancedSets.size());
    state.hasDiscreteSampleRates = !!source.discreteSampleRates;
    state.discreteSampleRateCount = source.discreteSampleRates ? static_cast<uint32_t>(source.discreteSampleRates->size()) : 0;
    state.hasDiscreteSampleSizes = !!source.discreteSampleSizes;
    state.discreteSampleSizeCount = source.discreteSampleSizes ? static_cast<uint32_t>(source.discreteSampleSizes->size()) : 0;
    state.isCamera = source.isCamera;
    state.purpose = purpose;

    MediaVideoPresetTable presets;
    if (source.presets) {
        presets = *source.presets;
        state.usesPresets = true;
        state.canResizeVideoFrames = presets.canResizeVideoFrames;
        state.presetCount = static_cast<uint32_t>(presets.presets.size());
        state.standardVideoSizeCount = static_cast<uint32_t>(presets.standardVideoSizes.size());
    }

    return mediaConstraintsEvaluate(MediaConstraintsEngineView { advancedSets.span(), presets.presets, presets.frameRateRanges, discreteSampleValues.span(), presets.standardVideoSizes }, state);
}

MediaConstraintsSourceNeeds mediaConstraintsSourceNeeds(const MediaConstraints& constraints)
{
    MediaConstraintsSourceNeeds needs;
    needs.evaluates = constraints.isConstraintSet([](auto& set) {
        return set.width() || set.height() || set.frameRate() || set.zoom() || !set.isEmpty();
    });
    if (!needs.evaluates)
        return needs;
    needs.presets = constraints.isConstraintSet([](auto& set) {
        return set.width() || set.height() || set.frameRate() || set.zoom();
    });
    needs.groupId = constraints.isConstraintSet([](auto& set) {
        return set.groupId() && !set.groupId()->isEmpty();
    });
    needs.facingMode = constraints.isConstraintSet([](auto& set) {
        return set.facingMode() && !set.facingMode()->isEmpty();
    });
    return needs;
}

CaptureConstraints* CaptureConstraints::create(MediaConstraints&& constraints)
{
    return &adoptRef(*new CaptureConstraints(WTF::move(constraints))).leakRef();
}

CaptureConstraints::CaptureConstraints(MediaConstraints&& constraints)
    : m_constraints(makeUniqueWithoutFastMallocCheck<MediaConstraints>(WTF::move(constraints)))
{
}

CaptureConstraints::~CaptureConstraints() = default;

bool CaptureConstraints::isValid() const
{
    return m_constraints->isValid;
}

bool CaptureConstraints::isWellFormed() const
{
    return areCaptureConstraintsWellFormed(*m_constraints);
}

bool areCaptureConstraintsWellFormed(const MediaConstraints& constraints)
{
    if (!constraints.mandatoryConstraints.isValid())
        return false;
    return std::ranges::all_of(constraints.advancedConstraints, [](auto& constraint) {
        return constraint.isValid();
    });
}

MediaConstraintsEvaluation evaluateCaptureConstraints(const CaptureConstraints& captureConstraints, const String& hashedId, const String& groupId, const CaptureConstraintsSourceValues& values, NOESCAPE std::span<const MediaVideoPresetValues> presets, NOESCAPE std::span<const MediaFrameRateRangeValues> frameRateRanges, MediaConstraintsEvaluationPurpose purpose)
{
    auto& constraints = captureConstraints.constraints();
    auto needs = mediaConstraintsSourceNeeds(constraints);
    if (!needs.evaluates)
        return { };

    std::optional<MediaVideoPresetTable> table;
    if (needs.presets && values.usesPresets)
        table = MediaVideoPresetTable { presets, frameRateRanges, RealtimeVideoCaptureSource::standardVideoSizes(), values.canResizeVideoFrames };

    return evaluateMediaConstraints(constraints, {
        values.capabilities,
        hashedId,
        needs.groupId ? groupId : emptyString(),
        { values.width, values.height },
        values.frameRate,
        values.zoom,
        values.volume,
        values.sampleRate,
        values.sampleSize,
        std::nullopt,
        std::nullopt,
        needs.facingMode ? values.facingModeFitnessScoreAdjustment : 0,
        values.isCamera,
        table,
    }, purpose);
}

MediaVideoPresetMatch bestCaptureVideoPreset(NOESCAPE std::span<const MediaVideoPresetValues> presets, NOESCAPE std::span<const MediaFrameRateRangeValues> frameRateRanges, const MediaVideoPresetSearch& search)
{
    return bestVideoPresetMatch({ presets, frameRateRanges, RealtimeVideoCaptureSource::standardVideoSizes(), search.canResizeVideoFrames }, search);
}

MediaVideoPresetMatch bestVideoPresetMatch(const MediaVideoPresetTable& table, const MediaVideoPresetSearch& search)
{
    auto presetSearch = search;
    presetSearch.presetCount = static_cast<uint32_t>(table.presets.size());
    presetSearch.standardVideoSizeCount = static_cast<uint32_t>(table.standardVideoSizes.size());
    presetSearch.canResizeVideoFrames = table.canResizeVideoFrames;
    return mediaConstraintsBestVideoPreset(MediaConstraintsEngineView { { }, table.presets, table.frameRateRanges, { }, table.standardVideoSizes }, presetSearch);
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
