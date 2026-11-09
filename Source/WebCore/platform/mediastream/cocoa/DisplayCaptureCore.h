/*
 * Copyright (C) 2017-2022 Apple Inc. All rights reserved.
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#include <cstdint>
#include <limits>
#include <wtf/SwiftBridging.h>

// The state and decisions of display capture, as plain values, with the methods implemented in Swift
// (DisplayCaptureCore.swift). DisplayCaptureSourceCocoa and ScreenCaptureKitCaptureSource keep their API and their
// ScreenCaptureKit, CoreMedia and VideoToolbox objects, hand these types plain values and apply what they decide.

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

// DisplayCaptureSourceCocoa's capture clock, and the size it gives a frame for a video frame observer.
class SWIFT_PRIVATE_FILEID("WebCore/DisplayCaptureCore.swift") DisplayCaptureSourceCore {
public:
    // Times are seconds of MonotonicTime.
    void startClock(double now);
    void stopClock(double now);
    // How long the source has produced frames, over all its runs.
    double elapsedTime(double now) const;
    // The presentation time of a frame emitted at `now`.
    double sampleTime(double now) const;

    // A frame size for `desired` that keeps the aspect ratio of `intrinsic`, since getDisplayMedia allows max
    // constraints only.
    static DisplayCaptureSize resizedVideoFrameSize(DisplayCaptureSize desired, DisplayCaptureSize intrinsic);

private:
    double m_startTime { std::numeric_limits<double>::quiet_NaN() };
    double m_elapsedTime { 0 };
};

// The SCFrameStatus of a frame's SCStreamFrameInfoStatus attachment.
enum class DisplayCaptureFrameStatus : int64_t {
    Complete,
    Idle,
    Blank,
    Suspended,
    Started,
    Stopped,
};

// What a ScreenCaptureKit frame's attachments say, read in their order as ScreenCaptureKitCaptureSource reads them: the
// last scale factor, content scale and content rect, whether the presenter overlay disallows reconfiguration, and the
// first status.
struct DisplayCaptureFrameAttachments {
    double scaleFactor { 1 };
    double contentScale { 1 };
    DisplayCaptureFloatRect contentRect;
    bool shouldDisallowReconfiguration { false };
    bool hasStatus { false };
    // A DisplayCaptureFrameStatus, or a status it doesn't name.
    int64_t status { 0 };
};

// ScreenCaptureKitCaptureSource's state: whether it runs, prewarms or has had a frame, the configuration it asked for,
// and its content and intrinsic sizes; and what it does on each event.
class SWIFT_PRIVATE_FILEID("WebCore/DisplayCaptureCore.swift") ScreenCaptureKitCaptureCore {
public:
    enum class WhenReadyAction : uint8_t {
        // The source has had a frame: call the callback now.
        CallNow,
        // Keep the callback for the first frame of the running stream.
        Wait,
        // Keep the callback, and start the stream to get a first frame.
        StartPrewarming,
    };
    WhenReadyAction whenReady();
    // Returns whether to start the content stream.
    bool startInternal(bool isPrewarming);
    void didStartContentStream();
    void stop();
    bool isRunning() const;

    // The content filter's content rect size and point pixel scale.
    void setContentSize(double width, double height, float pointPixelScale);
    // Returns whether the width, height or frame rate changed.
    bool commitConfiguration(uint32_t width, uint32_t height, float frameRate);

    struct StreamConfiguration {
        double minimumFrameInterval { 0 };
        uint32_t width { 0 };
        uint32_t height { 0 };
        bool hasMinimumFrameInterval { false };
        bool hasSize { false };
    };
    // The minimum frame interval and the size of the SCStreamConfiguration to capture with.
    StreamConfiguration streamConfiguration() const;

    void resetIntrinsicSize();
    // The intrinsic size, or the frame of the captured window or display (hasContentFrame), or a default size. The
    // frame's size is kept unless isEmptyContentFrameDefault and it is empty.
    DisplayCaptureSize intrinsicSize(bool hasContentFrame, double frameWidth, double frameHeight, bool isEmptyContentFrameDefault);

    struct FrameDecision {
        // The frame's content rect, scaled by the scale factor.
        DisplayCaptureFloatRect contentRect;
        // Use the frame: neither an extra frame while prewarming nor one with a status that has no content.
        bool shouldUseFrame { false };
        bool isPrewarmingFrame { false };
        // The content size changed: make the stream configuration again.
        bool shouldUpdateStreamConfiguration { false };
    };
    FrameDecision frameDidArrive(DisplayCaptureFrameAttachments);
    DisplayCaptureFloatSize contentSize() const;
    // Whether to crop a frame of `size` (its presentation dimensions) to the content rect.
    static bool shouldCropFrame(DisplayCaptureFloatRect contentRect, DisplayCaptureFloatSize);

    // The frame, after any cropping, has presentation dimensions `size`. Returns whether the intrinsic size changed.
    bool intrinsicSizeDidChange(DisplayCaptureFloatSize);
    // Returns whether this is the source's first frame.
    bool firstFrameDidArrive();

private:
    DisplayCaptureFloatSize m_contentSize;
    uint32_t m_width { 0 };
    uint32_t m_height { 0 };
    float m_frameRate { 0 };
    DisplayCaptureSize m_intrinsicSize;
    bool m_hasIntrinsicSize { false };
    bool m_isRunning { false };
    bool m_didReceiveVideoFrame { false };
    bool m_isPrewarming { false };
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
