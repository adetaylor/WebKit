/*
 * Copyright (C) 2015-2022 Apple Inc. All rights reserved.
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
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include <cstdint>
#include <wtf/SwiftBridging.h>
#include <wtf/text/WTFString.h>

typedef struct CGImage *CGImageRef;
OBJC_CLASS NSData;
OBJC_CLASS NSString;

// The mock camera's frames, as MockVideoSource.swift draws them: MockRealtimeVideoSourceMac holds a generator by
// identifier, tells it what to draw with plain values, and gets its frames and photos through the functions at the end
// of this file.

namespace WebCore {

enum class MockVideoSourceKind : uint8_t {
    Camera,
    Screen,
    Window,
};

// What doesn't change for a source: what it captures and its background colour, as 8-bit sRGB.
struct MockVideoSourceDescription {
    MockVideoSourceKind kind { MockVideoSourceKind::Camera };
    uint8_t fillRed { 0 };
    uint8_t fillGreen { 0 };
    uint8_t fillBlue { 0 };
    uint8_t fillAlpha { 255 };
};

// What the source's state says about its frames.
struct MockVideoSourceState {
    // A VideoFacingMode.
    uint8_t facingMode { 0 };
    // Whether to draw more than the background: the source isn't muted, or is muted for a photo.
    bool drawsContent { true };
    // The size frames are drawn at: the preset's, or the source's.
    int32_t captureWidth { 0 };
    int32_t captureHeight { 0 };
    // The source's size and frame rate.
    int32_t width { 0 };
    int32_t height { 0 };
    double frameRate { 30 };
    double zoom { 1 };
};

class SWIFT_PRIVATE_FILEID("WebCore/MockVideoSource.swift") MockVideoSourceHandle {
public:
    MockVideoSourceHandle() = default;

    static MockVideoSourceHandle create(MockVideoSourceDescription, MockVideoSourceState);
    void destroy();
    uint64_t identifier() const { return m_identifier; }

    // Any thread.
    void setState(MockVideoSourceState) const;
    // Starts the frame timer and the capture clock, and stops them.
    void startProducingData(double frameRate) const;
    void stopProducingData() const;
    // Starts or stops the frame timer only.
    void startTimer(double frameRate) const;
    void stopTimer() const;
    void delaySamples(double seconds) const;
    // Takes a photo; the result comes through mockVideoSourceDidTakePhoto() with the request's identifier.
    void takePhoto(bool drawsContent, uint64_t requestIdentifier) const;
    // The source starts applying constraints: a photo being taken fails.
    void configurationWillChange() const;

    // The GPU process's Swift mock cameras (MockRealtimeVideoSource::setIsInterrupted() and
    // triggerCameraConfigurationChange() for the C++ ones).
    static void setSwiftCamerasInterrupted(bool);
    static void triggerSwiftCameraConfigurationChange();

private:
    uint64_t m_identifier { 0 };
};

// A handle on the mock device of MockRealtimeMediaSourceCenter's devices with this persistent ID, or 0, for the lookups
// below, which find nothing once the devices change. Main thread only (implemented by MockRealtimeMediaSourceCenter.cpp).
SWIFT_MAIN_ACTOR uint64_t mockDeviceHandle(const String& persistentID);

// A mock microphone, for the GPU process's Swift microphone source.
struct MockMicrophoneValues {
    uint32_t deviceID { 0 };
    bool found { false };
    bool hasEchoCancellation { false };
    bool echoCancellation { false };
};
SWIFT_MAIN_ACTOR MockMicrophoneValues mockMicrophone(uint64_t deviceHandle);

// A mock camera, for the GPU process's Swift mock camera. whiteBalanceModes has bit i set for MeteringMode i.
struct MockCameraDeviceValues {
    double defaultFrameRate { 30 };
    uint32_t presetCount { 0 };
    // A VideoFacingMode.
    uint8_t facingMode { 0 };
    uint8_t whiteBalanceModes { 0 };
    MockVideoSourceDescription description;
    bool found { false };
    bool isInvalid { false };
    bool hasTorch { false };
    bool hasBackgroundBlur { false };
};

struct MockCameraPresetValues {
    double minZoom { 1 };
    double maxZoom { 1 };
    int32_t width { 0 };
    int32_t height { 0 };
    uint32_t frameRateRangeCount { 0 };
    bool isEfficient { false };
};

struct MockCameraFrameRateRange {
    double minimum { 0 };
    double maximum { 0 };
};

SWIFT_MAIN_ACTOR MockCameraDeviceValues mockCameraDeviceValues(uint64_t deviceHandle);
SWIFT_MAIN_ACTOR MockCameraPresetValues mockCameraPreset(uint64_t deviceHandle, uint32_t presetIndex);
SWIFT_MAIN_ACTOR MockCameraFrameRateRange mockCameraPresetFrameRateRange(uint64_t deviceHandle, uint32_t presetIndex, uint32_t rangeIndex);

// Implemented by MockRealtimeVideoSourceCocoa.mm, on the generator's queue. Returns the frame rate the source's observers
// see.
double mockVideoSourceDidGenerateFrame(uint64_t identifier, CGImageRef WTF_NONNULL, double presentationTime);
// The photo as PNG data, or the error's message. Any thread.
void mockVideoSourceDidTakePhoto(uint64_t identifier, uint64_t requestIdentifier, NSData * WTF_NULLABLE, NSString * WTF_NULLABLE errorMessage);

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
