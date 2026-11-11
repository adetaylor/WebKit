/*
 * Copyright (C) 2012 Google Inc. All rights reserved.
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
 * Copyright (C) 2015 Ericsson AB. All rights reserved.
 * Copyright (C) 2013-2026 Apple Inc. All rights reserved.
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
 *
 * Copyright (C) 2018-2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <wtf/Platform.h>
#if ENABLE(MEDIA_STREAM)

#include <cstdint>
#include <limits>
#include <wtf/SwiftBridging.h>
#include <wtf/text/WTFString.h>

// The decisions that the C++ RealtimeMediaSource and RealtimeVideoCaptureSource and the GPU process's Swift capture
// sources (cocoa/CaptureSource.swift) both make, in CaptureSourceDecisions.swift, and the plain values that a source's
// settings and capabilities are made of.

namespace WebCore {

struct CaptureSourceSize {
    int32_t width { 0 };
    int32_t height { 0 };
};

// RealtimeMediaSourceSettings without its strings, which the C++ facades know. supportedConstraints has bit i set for
// the i-th member of RealtimeMediaSourceSupportedConstraints, in declaration order.
struct CaptureSettingsValues {
    double volume { 0 };
    double zoom { 1 };
    float frameRate { 0 };
    uint32_t width { 0 };
    uint32_t height { 0 };
    uint32_t sampleRate { 0 };
    uint32_t sampleSize { 0 };
    uint32_t supportedConstraints { 0 };
    // A VideoFacingMode, a DisplaySurfaceType and a MeteringMode.
    uint8_t facingMode { 0 };
    uint8_t displaySurface { 4 };
    uint8_t whiteBalanceMode { 0 };
    bool echoCancellation { false };
    bool logicalSurface { false };
    bool torch { false };
    bool backgroundBlur { false };
    bool powerEfficient { false };
};

// RealtimeMediaSourceCapabilities without its strings. facingModes and whiteBalanceModes have bit i set for mode i.
struct CaptureCapabilityValues {
    double aspectRatioMin { 0 };
    double aspectRatioMax { 0 };
    double frameRateMin { 0 };
    double frameRateMax { 0 };
    double volumeMin { 0 };
    double volumeMax { 0 };
    double focusDistanceMin { 0 };
    double focusDistanceMax { 0 };
    double zoomMin { 0 };
    double zoomMax { 0 };
    int32_t widthMin { 0 };
    int32_t widthMax { 0 };
    int32_t heightMin { 0 };
    int32_t heightMax { 0 };
    int32_t sampleRateMin { 0 };
    int32_t sampleRateMax { 0 };
    int32_t sampleSizeMin { 0 };
    int32_t sampleSizeMax { 0 };
    uint32_t supportedConstraints { 0 };
    uint8_t facingModes { 0 };
    uint8_t whiteBalanceModes { 0 };
    // A RealtimeMediaSourceCapabilities::EchoCancellation and BackgroundBlur.
    uint8_t echoCancellation { 1 };
    uint8_t backgroundBlur { 0 };
    bool torch { false };
    bool powerEfficient { false };
};

class SWIFT_PRIVATE_FILEID("WebCore/CaptureSourceDecisions.swift") CaptureSourceDecisions {
public:
    static CaptureSourceSize resolvedSize(CaptureSourceSize, CaptureSourceSize intrinsicSize);
    static CaptureSourceSize resizedVideoFrameSize(CaptureSourceSize desired, CaptureSourceSize actual);
    static uint64_t frameDecimation(double observedFrameRate, double frameRate);
    static CaptureSourceSize photoSize(double width, double height, CaptureSourceSize intrinsicSize);
};

// RealtimeVideoCaptureSource::updateCapabilities(): the size, aspect ratio, frame rate and zoom ranges of a source's
// presets, which addPreset() takes one at a time.
struct SWIFT_PRIVATE_FILEID("WebCore/CaptureSourceDecisions.swift") CaptureVideoCapabilityRanges {
    void addPreset(int32_t width, int32_t height, double minZoom, double maxZoom, double maxFrameRate);
    // A CaptureCapabilityValues with only the ranges, or with none (widthMax 0) if the presets don't give a size and
    // frame rate.
    CaptureCapabilityValues ranges(bool canResizeVideoFrames) const;

    int32_t minimumWidth { std::numeric_limits<int32_t>::max() };
    int32_t maximumWidth { 0 };
    int32_t minimumHeight { std::numeric_limits<int32_t>::max() };
    int32_t maximumHeight { 0 };
    double minimumAspectRatio { std::numeric_limits<double>::max() };
    double maximumAspectRatio { 0 };
    double maximumFrameRate { 0 };
    double minimumZoom { std::numeric_limits<double>::max() };
    double maximumZoom { 1 };
};

#if !defined(__swift__)
class RealtimeMediaSourceCapabilities;
class RealtimeMediaSourceSettings;
class RealtimeMediaSourceSupportedConstraints;

uint32_t captureSupportedConstraintBits(const RealtimeMediaSourceSupportedConstraints&);
WEBCORE_EXPORT CaptureSettingsValues captureSettingsValues(const RealtimeMediaSourceSettings&);
WEBCORE_EXPORT CaptureCapabilityValues captureCapabilityValues(const RealtimeMediaSourceCapabilities&);

// The settings and capabilities of the values that CaptureSource.swift's models make, with the strings of the facade.
RealtimeMediaSourceSettings captureSettings(const CaptureSettingsValues&, const String& label, const String& deviceId, const String& groupId);
RealtimeMediaSourceCapabilities captureCapabilities(const CaptureCapabilityValues&, const String& deviceId, const String& groupId);
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
