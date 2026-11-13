/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include <WebCore/IntSize.h>
#include <WebCore/MediaConstraintType.h>
#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/SwiftBridging.h>

// The plain values through which RealtimeMediaSource hands MediaConstraints, its capabilities and its state to the
// constraint engine (MediaConstraintsEngine.swift), and the engine's answers. MediaConstraintsEvaluation.cpp makes them.

namespace WebCore {

// A numeric constraint of a MediaTrackConstraintSetMap. isPresent with no part set is a present but empty constraint.
struct MediaIntConstraintValues {
    int32_t min { 0 };
    int32_t max { 0 };
    int32_t exact { 0 };
    int32_t ideal { 0 };
    bool isPresent { false };
    bool hasMin { false };
    bool hasMax { false };
    bool hasExact { false };
    bool hasIdeal { false };
};

struct MediaDoubleConstraintValues {
    double min { 0 };
    double max { 0 };
    double exact { 0 };
    double ideal { 0 };
    bool isPresent { false };
    bool hasMin { false };
    bool hasMax { false };
    bool hasExact { false };
    bool hasIdeal { false };
};

struct MediaBooleanConstraintValues {
    bool isPresent { false };
    bool hasExact { false };
    bool exact { false };
    bool hasIdeal { false };
    bool ideal { false };
};

// The exact or ideal strings of a string constraint, compared with the strings the engine compares them with: for a
// device or group ID, bit 0 of matches is whether the list holds the source's hashed device ID or group ID; for a facing
// or white balance mode, bit i is whether it holds the name of mode i. applyOrder lists, in the order of their first
// string, the modes the strings name, one per 4 bits from the lowest, each plus 1, ending at 0. For facing modes the
// mode of a string is RealtimeMediaSourceSettings::videoFacingModeEnum()'s, and the empty string is the extra mode
// mediaConstraintsEmptyFacingMode; for white balance modes, strings that name no mode are left out.
struct MediaStringListValues {
    uint32_t applyOrder { 0 };
    uint8_t matches { 0 };
    bool hasValues { false };
};

constexpr uint8_t mediaConstraintsEmptyFacingMode = 5;

// A string constraint, as given and with its empty strings removed, as MediaTrackConstraintSetMap::set() leaves a
// device ID.
struct MediaStringConstraintValues {
    MediaStringListValues exact;
    MediaStringListValues ideal;
    MediaStringListValues exactWithoutEmptyStrings;
    MediaStringListValues idealWithoutEmptyStrings;
    bool isPresent { false };
};

// The constraints of a MediaTrackConstraintSetMap that the engine reads.
struct MediaConstraintSetValues {
    MediaIntConstraintValues width;
    MediaIntConstraintValues height;
    MediaIntConstraintValues sampleRate;
    MediaIntConstraintValues sampleSize;
    MediaDoubleConstraintValues aspectRatio;
    MediaDoubleConstraintValues frameRate;
    MediaDoubleConstraintValues volume;
    MediaDoubleConstraintValues zoom;
    MediaBooleanConstraintValues echoCancellation;
    MediaBooleanConstraintValues torch;
    MediaBooleanConstraintValues backgroundBlur;
    MediaBooleanConstraintValues powerEfficient;
    MediaStringConstraintValues facingMode;
    MediaStringConstraintValues deviceId;
    MediaStringConstraintValues groupId;
    MediaStringConstraintValues whiteBalanceMode;
};

struct MediaIntRange {
    int32_t min { 0 };
    int32_t max { 0 };
};

struct MediaDoubleRange {
    double min { 0 };
    double max { 0 };
};

// A RealtimeMediaSourceCapabilities. facingModes and whiteBalanceModes have bit i set for mode i;
// echoCancellation is a RealtimeMediaSourceCapabilities::EchoCancellation.
struct MediaConstraintsCapabilities {
    MediaIntRange width;
    MediaIntRange height;
    MediaIntRange sampleRate;
    MediaIntRange sampleSize;
    MediaDoubleRange aspectRatio;
    MediaDoubleRange frameRate;
    MediaDoubleRange volume;
    MediaDoubleRange zoom;
    uint8_t facingModes { 0 };
    uint8_t whiteBalanceModes { 0 };
    uint8_t echoCancellation { 0 };
    bool torch { false };
    bool supportsWidth { false };
    bool supportsHeight { false };
    bool supportsAspectRatio { false };
    bool supportsFrameRate { false };
    bool supportsZoom { false };
    bool supportsVolume { false };
    bool supportsSampleRate { false };
    bool supportsSampleSize { false };
    bool supportsFacingMode { false };
    bool supportsEchoCancellation { false };
    bool supportsDeviceId { false };
    bool supportsWhiteBalanceMode { false };
    bool supportsTorch { false };
    bool supportsBackgroundBlur { false };
};

// What the caller of the engine needs: RealtimeMediaSource::hasAnyInvalidConstraint() the fitness score,
// extractVideoPresetConstraints() the size, frame rate and zoom constraints, applyConstraints() those and the settings
// to change.
enum class MediaConstraintsEvaluationPurpose : uint8_t {
    FitnessScore,
    VideoPresetConstraints,
    Application,
};

// What the engine reads of a source besides its capabilities, and the mandatory constraints. The discrete sample rates,
// then the discrete sample sizes, are the view's discrete sample values. usesPresets is whether the source checks sizes,
// frame rates and zooms against the view's presets, as a RealtimeVideoCaptureSource does.
struct MediaConstraintsSourceState {
    MediaConstraintsCapabilities capabilities;
    MediaConstraintSetValues mandatory;
    double frameRate { 0 };
    double zoom { 0 };
    double volume { 0 };
    double facingModeFitnessScoreAdjustment { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
    int32_t sampleRate { 0 };
    int32_t sampleSize { 0 };
    uint32_t advancedSetCount { 0 };
    uint32_t presetCount { 0 };
    uint32_t standardVideoSizeCount { 0 };
    uint32_t discreteSampleRateCount { 0 };
    uint32_t discreteSampleSizeCount { 0 };
    MediaConstraintsEvaluationPurpose purpose { MediaConstraintsEvaluationPurpose::Application };
    bool hasDiscreteSampleRates { false };
    bool hasDiscreteSampleSizes { false };
    bool isCamera { false };
    bool usesPresets { false };
    bool canResizeVideoFrames { false };
};

// What a capture source of the GPU process (CaptureSource.swift) tells the engine about itself besides its hashed IDs and
// presets. usesPresets is whether it has any.
struct CaptureConstraintsSourceValues {
    MediaConstraintsCapabilities capabilities;
    double frameRate { 0 };
    double zoom { 0 };
    double volume { 0 };
    double facingModeFitnessScoreAdjustment { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
    int32_t sampleRate { 0 };
    int32_t sampleSize { 0 };
    bool isCamera { false };
    bool usesPresets { false };
    bool canResizeVideoFrames { false };
};

// RealtimeMediaSource::VideoPresetConstraints.
struct MediaVideoPresetConstraints {
    double frameRate { 0 };
    double zoom { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
    bool hasWidth { false };
    bool hasHeight { false };
    bool hasFrameRate { false };
    bool hasZoom { false };
    bool shouldPreferPowerEfficiency { false };
};

// The engine's answer for a MediaConstraints: the first constraint it can't satisfy, or what the purpose asks for: the
// source's fitness score; the size, frame rate and zoom constraints to apply; or those and the settings to change, each
// of which the caller applies only if its sets flag is set. hasConstraintsToApply is false when applyConstraints()
// would do nothing.
struct alignas(8) MediaConstraintsEvaluation {
    double fitnessScore { 0 };
    MediaVideoPresetConstraints videoPresetConstraints;
    double volume { 0 };
    int32_t sampleRate { 0 };
    int32_t sampleSize { 0 };
    MediaConstraintType invalidConstraint { MediaConstraintType::Unknown };
    bool hasInvalidConstraint { false };
    bool hasConstraintsToApply { false };
    bool setsSampleRate { false };
    bool setsSampleSize { false };
    bool setsVolume { false };
    bool setsEchoCancellation { false };
    bool echoCancellation { false };
    bool setsFacingMode { false };
    uint8_t facingMode { 0 };
    bool setsWhiteBalanceMode { false };
    uint8_t whiteBalanceMode { 0 };
    bool setsTorch { false };
    bool torch { false };
};
static_assert(!(sizeof(MediaConstraintsEvaluation) % 8));

// A VideoPreset; its frame rate ranges are the view's frameRateCount ranges from firstFrameRate.
struct MediaVideoPresetValues {
    double minZoom { 1 };
    double maxZoom { 1 };
    int32_t width { 0 };
    int32_t height { 0 };
    uint32_t firstFrameRate { 0 };
    uint32_t frameRateCount { 0 };
    bool isEfficient { false };
};

struct MediaFrameRateRangeValues {
    double minimum { 0 };
    double maximum { 0 };
};

struct MediaVideoSizeValues {
    int32_t width { 0 };
    int32_t height { 0 };
};

// What RealtimeVideoCaptureSource::bestSupportedSizeFrameRateAndZoomConsideringObservers() reads.
struct MediaVideoPresetSearch {
    MediaVideoPresetConstraints constraints;
    double frameRate { 0 };
    double zoom { 0 };
    double settingsFrameRate { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
    int32_t settingsWidth { 0 };
    int32_t settingsHeight { 0 };
    uint32_t presetCount { 0 };
    uint32_t standardVideoSizeCount { 0 };
    bool canResizeVideoFrames { false };
    bool hasSeveralVideoFrameObserversWithAdaptors { false };
};

// The preset to use, by index, and the size, frame rate and zoom to capture at; found is false if no preset fits.
struct alignas(8) MediaVideoPresetMatch {
    double frameRate { 0 };
    double zoom { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
    uint32_t presetIndex { 0 };
    bool found { false };
};
static_assert(!(sizeof(MediaVideoPresetMatch) % 8));

// The advanced constraint sets, presets, frame rate ranges, discrete sample values and
// RealtimeVideoCaptureSource::standardVideoSizes() lent to the engine for one call. Only C++ makes one; an index past
// the end of a span traps.
class SWIFT_NONESCAPABLE SWIFT_SAFE MediaConstraintsEngineView {
public:
#if !defined(__swift__)
    MediaConstraintsEngineView(std::span<const MediaConstraintSetValues> advancedSets LIFETIME_BOUND, std::span<const MediaVideoPresetValues> presets LIFETIME_BOUND, std::span<const MediaFrameRateRangeValues> frameRateRanges LIFETIME_BOUND, std::span<const int32_t> discreteSampleValues LIFETIME_BOUND, std::span<const IntSize> standardVideoSizes LIFETIME_BOUND)
        : m_advancedSets(advancedSets)
        , m_presets(presets)
        , m_frameRateRanges(frameRateRanges)
        , m_discreteSampleValues(discreteSampleValues)
        , m_standardVideoSizes(standardVideoSizes)
    {
    }
#endif

    MediaConstraintSetValues advancedSet(size_t index) const { return m_advancedSets[index]; }
    MediaVideoPresetValues preset(size_t index) const { return m_presets[index]; }
    MediaFrameRateRangeValues frameRateRange(size_t index) const { return m_frameRateRanges[index]; }
    int32_t discreteSampleValue(size_t index) const { return m_discreteSampleValues[index]; }
    MediaVideoSizeValues standardVideoSize(size_t index) const
    {
        auto size = m_standardVideoSizes[index];
        return { size.width(), size.height() };
    }

private:
    std::span<const MediaConstraintSetValues> m_advancedSets;
    std::span<const MediaVideoPresetValues> m_presets;
    std::span<const MediaFrameRateRangeValues> m_frameRateRanges;
    std::span<const int32_t> m_discreteSampleValues;
    std::span<const IntSize> m_standardVideoSizes;
};

} // namespace WebCore
