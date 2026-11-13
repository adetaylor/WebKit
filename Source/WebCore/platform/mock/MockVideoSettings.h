/*
 * Copyright (C) 2015-2023 Apple Inc. All rights reserved.
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

#pragma once

#include <wtf/Platform.h>
#if ENABLE(MEDIA_STREAM)

#include <WebCore/CaptureSourceDecisions.h>
#include <cstdint>
#include <wtf/SwiftBridging.h>

// The settings and capabilities of a mock camera or display, as MockVideoSettings.swift decides them, for
// MockRealtimeVideoSource and the GPU process's Swift mock camera.

namespace WebCore {

enum class MockVideoKind : uint8_t {
    Camera,
    Screen,
    Window,
};

// What a mock video source's device and state say about its settings.
struct MockVideoSettingsInputs {
    double frameRate { 0 };
    double zoom { 1 };
    int32_t width { 0 };
    int32_t height { 0 };
    // A VideoFrameRotation, a VideoFacingMode and a MeteringMode.
    uint16_t deviceOrientation { 0 };
    uint8_t facingMode { 0 };
    uint8_t whiteBalanceMode { 0 };
    MockVideoKind kind { MockVideoKind::Camera };
    bool torch { false };
    // Whether a preset supports zoom, the presets can be power efficient, and the current preset is.
    bool isZoomSupported { false };
    bool canBePowerEfficient { false };
    bool presetIsEfficient { false };
    // What the device has.
    bool hasWhiteBalanceModes { false };
    bool hasTorch { false };
    bool hasBackgroundBlur { false };
};

// What a mock video source's device says about its capabilities. ranges are the presets' (CaptureVideoCapabilityRanges)
// for a camera.
struct MockVideoCapabilityInputs {
    CaptureCapabilityValues ranges;
    uint32_t settingsSupportedConstraints { 0 };
    int32_t displayWidth { 0 };
    int32_t displayHeight { 0 };
    MockVideoKind kind { MockVideoKind::Camera };
    // The device's VideoFacingMode, and its MeteringModes, bit i for mode i.
    uint8_t facingMode { 0 };
    uint8_t whiteBalanceModes { 0 };
    bool hasTorch { false };
    bool hasBackgroundBlur { false };
    bool canBePowerEfficient { false };
};

class SWIFT_PRIVATE_FILEID("WebCore/MockVideoSettings.swift") MockVideoSettings {
public:
    static CaptureSettingsValues settings(MockVideoSettingsInputs);
    static CaptureCapabilityValues capabilities(MockVideoCapabilityInputs);
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
