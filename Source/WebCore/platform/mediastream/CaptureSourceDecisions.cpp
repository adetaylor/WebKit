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

#include "config.h"
#include "CaptureSourceDecisions.h"

#if ENABLE(MEDIA_STREAM)

#include "RealtimeMediaSourceCapabilities.h"
#include "RealtimeMediaSourceSettings.h"

namespace WebCore {

static RealtimeMediaSourceSupportedConstraints supportedConstraints(uint32_t bits)
{
    auto has = [bits](unsigned index) {
        return !!(bits & (1u << index));
    };
    return { has(0), has(1), has(2), has(3), has(4), has(5), has(6), has(7), has(8), has(9), has(10), has(11), has(12), has(13), has(14), has(15), has(16), has(17), has(18) };
}

uint32_t captureSupportedConstraintBits(const RealtimeMediaSourceSupportedConstraints& constraints)
{
    uint32_t bits = 0;
    unsigned index = 0;
    for (bool supported : { constraints.supportsWidth(), constraints.supportsHeight(), constraints.supportsAspectRatio(), constraints.supportsFrameRate(), constraints.supportsFacingMode(), constraints.supportsVolume(), constraints.supportsSampleRate(), constraints.supportsSampleSize(), constraints.supportsEchoCancellation(), constraints.supportsDeviceId(), constraints.supportsGroupId(), constraints.supportsDisplaySurface(), constraints.supportsLogicalSurface(), constraints.supportsFocusDistance(), constraints.supportsWhiteBalanceMode(), constraints.supportsZoom(), constraints.supportsTorch(), constraints.supportsBackgroundBlur(), constraints.supportsPowerEfficient() }) {
        if (supported)
            bits |= 1u << index;
        ++index;
    }
    return bits;
}

template<typename Mode>
static Vector<Mode> modes(uint8_t bits)
{
    Vector<Mode> result;
    for (uint8_t index = 0; index < 8; ++index) {
        if (bits & (1 << index))
            result.append(static_cast<Mode>(index));
    }
    return result;
}

RealtimeMediaSourceSettings captureSettings(const CaptureSettingsValues& values, const String& label, const String& deviceId, const String& groupId)
{
    return {
        values.width,
        values.height,
        values.frameRate,
        static_cast<VideoFacingMode>(values.facingMode),
        values.volume,
        values.sampleRate,
        values.sampleSize,
        values.echoCancellation,
        String { deviceId },
        String { groupId },
        String { label },
        static_cast<DisplaySurfaceType>(values.displaySurface),
        values.logicalSurface,
        static_cast<MeteringMode>(values.whiteBalanceMode),
        values.zoom,
        values.torch,
        values.backgroundBlur,
        values.powerEfficient,
        supportedConstraints(values.supportedConstraints),
    };
}

RealtimeMediaSourceCapabilities captureCapabilities(const CaptureCapabilityValues& values, const String& deviceId, const String& groupId)
{
    return {
        { values.widthMin, values.widthMax },
        { values.heightMin, values.heightMax },
        { values.aspectRatioMin, values.aspectRatioMax },
        { values.frameRateMin, values.frameRateMax },
        modes<VideoFacingMode>(values.facingModes),
        { values.volumeMin, values.volumeMax },
        { values.sampleRateMin, values.sampleRateMax },
        { values.sampleSizeMin, values.sampleSizeMax },
        static_cast<RealtimeMediaSourceCapabilities::EchoCancellation>(values.echoCancellation),
        String { deviceId },
        String { groupId },
        { values.focusDistanceMin, values.focusDistanceMax },
        modes<MeteringMode>(values.whiteBalanceModes),
        { values.zoomMin, values.zoomMax },
        values.torch,
        static_cast<RealtimeMediaSourceCapabilities::BackgroundBlur>(values.backgroundBlur),
        values.powerEfficient,
        supportedConstraints(values.supportedConstraints),
    };
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
