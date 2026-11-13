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
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
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

// The constraints that a web process sends for a capture source of the GPU process (CaptureSource.swift), which Swift
// holds and hands back to the C++ that evaluates them.
class CaptureConstraints final : public ThreadSafeRefCounted<CaptureConstraints> {
public:
    WEBCORE_EXPORT static CaptureConstraints* WTF_NONNULL create(MediaConstraints&&) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT ~CaptureConstraints();

    const MediaConstraints& constraints() const { return *m_constraints; }

    // Whether there are any (MediaConstraints::isValid).
    WEBCORE_EXPORT bool isValid() const;
    // Whether the mandatory and advanced constraint sets are each well formed, as a web process must send them.
    WEBCORE_EXPORT bool isWellFormed() const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<CaptureConstraints>::ref(); }
    void deref() const { ThreadSafeRefCounted<CaptureConstraints>::deref(); }
#endif

private:
    explicit CaptureConstraints(MediaConstraints&&);

    const std::unique_ptr<MediaConstraints> m_constraints;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// Whether the mandatory and advanced constraint sets are each well formed, as a web process must send them.
WEBCORE_EXPORT bool areCaptureConstraintsWellFormed(const MediaConstraints&);

// evaluateMediaConstraints(), for a capture source of the GPU process, which describes itself with plain values.
WEBCORE_EXPORT MediaConstraintsEvaluation evaluateCaptureConstraints(const CaptureConstraints&, const String& hashedId, const String& groupId, const CaptureConstraintsSourceValues&, NOESCAPE std::span<const MediaVideoPresetValues>, NOESCAPE std::span<const MediaFrameRateRangeValues>, MediaConstraintsEvaluationPurpose);
WEBCORE_EXPORT MediaVideoPresetMatch bestCaptureVideoPreset(NOESCAPE std::span<const MediaVideoPresetValues>, NOESCAPE std::span<const MediaFrameRateRangeValues>, const MediaVideoPresetSearch&);

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
