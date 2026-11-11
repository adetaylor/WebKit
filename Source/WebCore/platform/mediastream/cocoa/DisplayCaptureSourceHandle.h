/*
 * Copyright (C) 2017-2022 Apple Inc. All rights reserved.
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2022-2023 Apple Inc. All rights reserved.
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
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include <WebCore/DisplayCapturePromptType.h>
#include <WebCore/MockVideoSourceHandle.h>
#include <cstdint>
#include <wtf/SwiftBridging.h>
#include <wtf/text/WTFString.h>

typedef struct CGImage *CGImageRef;
typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;
OBJC_CLASS NSString;

// A screen or window capture, as DisplayCaptureSource.swift implements it: its emit timer, clock and sizes, with
// ScreenCaptureKitCapturer.swift's stream or the mock display capturer. DisplayCaptureSourceCocoa, a RealtimeMediaSource
// for callers in C++, holds one by identifier, calls it with plain values, and gets its frames and events through the
// functions at the end of this file.

namespace WebCore {

struct DisplayCaptureSize {
    int32_t width { 0 };
    int32_t height { 0 };
};

struct DisplayCaptureFloatSize {
    float width { 0 };
    float height { 0 };
};

struct DisplayCaptureFloatRect {
    float x { 0 };
    float y { 0 };
    float width { 0 };
    float height { 0 };
};

// A mock display: what it draws and its size.
struct MockDisplayDescription {
    MockVideoSourceDescription video;
    int32_t width { 0 };
    int32_t height { 0 };
};

// The mock display with a persistent ID of MockRealtimeMediaSourceCenter's devices, if there is one (implemented by
// MockRealtimeMediaSourceCenter.cpp).
struct MockDisplayLookup {
    MockDisplayDescription display;
    bool found { false };
};
MockDisplayLookup mockDisplayWithPersistentID(const String& persistentID);

enum class DisplayCaptureSourceEvent : uint8_t {
    CaptureFailed,
    ConfigurationChanged,
    // The capturer is ready, after whenReady(): it has its first frame.
    Ready,
};

class SWIFT_PRIVATE_FILEID("WebCore/DisplayCaptureSource.swift") DisplayCaptureSourceHandle {
public:
    DisplayCaptureSourceHandle() = default;

#if HAVE(SCREEN_CAPTURE_KIT)
    // A source for the display, or the window if isWindow, with this ID, which ScreenCaptureKitSharingSessionManager's
    // prompt picked.
    static DisplayCaptureSourceHandle create(bool isWindow, uint32_t deviceID);
#endif
    // A source for the mock display.
    static DisplayCaptureSourceHandle createMock(MockDisplayDescription);
    // The latest mock display source changes to the screen or window description, of its kind.
    static void triggerMockConfigurationChange(MockDisplayDescription screen, MockDisplayDescription window);
    // A frame size for `desired` that keeps the aspect ratio of `intrinsic`, since getDisplayMedia allows max
    // constraints only.
    static DisplayCaptureSize resizedVideoFrameSize(DisplayCaptureSize desired, DisplayCaptureSize intrinsic);

    void destroy();
    bool isValid() const { return !!m_identifier; }
    uint64_t identifier() const { return m_identifier; }

    // The source's frame rate, and the width, height and frame rate of its settings, for the capturer's configuration.
    void startProducingData(double frameRate, uint32_t width, uint32_t height, float settingsFrameRate);
    void stopProducingData();
    void endProducingData();
    void setFrameRate(double);
    void commitConfiguration(uint32_t width, uint32_t height, float frameRate);
    void whenReady();
    DisplayCaptureSize intrinsicSize() const;
    // Whether the capturer captures a window, not a display.
    bool isWindow() const;


private:
    uint64_t m_identifier { 0 };
};

#if HAVE(SCREEN_CAPTURE_KIT)
// The getDisplayMedia prompt, through ScreenCaptureKit's content sharing picker. ScreenCaptureKitSharingSessionManager
// holds the prompt's completion handler and gets the result through screenCaptureKitPromptDidComplete().
class ScreenCaptureKitSharingSession {
public:
    // Whether ScreenCaptureKit loads.
    static bool isFrameworkAvailable();
    // Whether ScreenCaptureKit has the content sharing picker.
    static bool isPickerAvailable();
    static void prompt(DisplayCapturePromptType);
    static void cancelPrompt();
};
#endif

// Implemented by DisplayCaptureSourceCocoa.cpp, on the main thread.
void displayCaptureSourceDidChange(uint64_t identifier, DisplayCaptureSourceEvent);
bool displayCaptureSourceIsMuted(uint64_t identifier);
// The capturer's current frame, a sample buffer or an image, emitted at sampleTime (seconds) with presentation size
// `size`.
void displayCaptureSourceDidEmitFrame(uint64_t identifier, CMSampleBufferRef WTF_NULLABLE, CGImageRef WTF_NULLABLE, double sampleTime, DisplayCaptureSize);
// The frame cropped to `rect` of a frame of `frameSize`, through the source's ImageTransferSessionVT, or null.
CMSampleBufferRef WTF_NULLABLE displayCaptureSourceCopyCroppedFrame(uint64_t identifier, CMSampleBufferRef WTF_NONNULL, DisplayCaptureFloatRect, DisplayCaptureFloatSize) CF_RETURNS_RETAINED;

#if HAVE(SCREEN_CAPTURE_KIT)
// Implemented by ScreenCaptureKitSharingSessionManager.mm. The prompt picked nothing (!hasDevice), or a window with
// this ID and title, or a display with this ID.
void screenCaptureKitPromptDidComplete(bool hasDevice, bool isWindow, uint32_t deviceID, NSString * WTF_NULLABLE title);
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
