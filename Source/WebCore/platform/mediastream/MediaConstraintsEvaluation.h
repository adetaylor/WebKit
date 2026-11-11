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

#if ENABLE(MEDIA_STREAM)

#include <WebCore/IntSize.h>
#include <WebCore/MediaConstraintsSwiftBridge.h>
#include <optional>
#include <span>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class RealtimeMediaSourceCapabilities;
struct MediaConstraints;

// A source's video presets, for the constraint engine.
struct MediaVideoPresetTable {
    std::span<const MediaVideoPresetValues> presets;
    std::span<const MediaFrameRateRangeValues> frameRateRanges;
    std::span<const IntSize> standardVideoSizes;
    bool canResizeVideoFrames { false };
};

// What evaluating constraints reads of a RealtimeMediaSource. A source with presets checks sizes, frame rates and zooms
// against them.
struct MediaConstraintsSourceDescription {
    MediaConstraintsCapabilities capabilities;
    String hashedId;
    String groupId;
    IntSize size;
    double frameRate { 0 };
    double zoom { 0 };
    double volume { 0 };
    int sampleRate { 0 };
    int sampleSize { 0 };
    std::optional<Vector<int>> discreteSampleRates;
    std::optional<Vector<int>> discreteSampleSizes;
    double facingModeFitnessScoreAdjustment { 0 };
    bool isCamera { false };
    std::optional<MediaVideoPresetTable> presets;
};

// What the constraints read of a source: nothing (then it isn't described), its presets, its group ID or its facing mode
// fitness.
struct MediaConstraintsSourceNeeds {
    bool evaluates { false };
    bool presets { false };
    bool groupId { false };
    bool facingMode { false };
};

WEBCORE_EXPORT MediaConstraintsSourceNeeds mediaConstraintsSourceNeeds(const MediaConstraints&);
WEBCORE_EXPORT MediaConstraintsCapabilities mediaConstraintsCapabilities(const RealtimeMediaSourceCapabilities&);
WEBCORE_EXPORT MediaConstraintsEvaluation evaluateMediaConstraints(const MediaConstraints&, const MediaConstraintsSourceDescription&, MediaConstraintsEvaluationPurpose);
WEBCORE_EXPORT MediaVideoPresetMatch bestVideoPresetMatch(const MediaVideoPresetTable&, const MediaVideoPresetSearch&);

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
