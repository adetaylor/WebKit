/*
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2013-2026 Apple Inc. All rights reserved.
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
#if ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)

#include <cstdint>
#include <wtf/SwiftBridging.h>

namespace WebCore {

// AVVideoCaptureSource's state, as plain values, and what it does on each event, implemented in Swift
// (CameraCaptureCore.swift): the rotation of its frames, the nesting of its session configuration, the frame rate and
// zoom it applied, whether its session runs or is interrupted, whether it still receives frames, and the torch and
// white balance changes it defers until its session runs. AVVideoCaptureSource keeps its API and its AVFoundation
// objects, and applies what these methods return.
class SWIFT_PRIVATE_FILEID("WebCore/CameraCaptureCore.swift") CameraCaptureCore {
public:
    // Rotations are VideoFrameRotation values, orientations IntDegrees.
    uint16_t videoFrameRotation() const;
    void setSensorOrientation(int32_t);
    void setDeviceOrientation(int32_t);
    void stopUsingSensorAndDeviceOrientation();
    // Returns whether the rotation of the frames changed.
    bool computeVideoFrameRotation(bool isFrontCamera);
    // The rotation the system gives for the device's horizon-level display. Returns whether it changed.
    bool horizonLevelRotationDidChange(uint16_t rotation);

    // Each returns whether to begin or commit the session's configuration.
    bool beginConfiguration();
    bool commitConfiguration();
    bool hasBegunConfiguration() const;
    void startApplyingConstraints();
    bool beginConfigurationForConstraintsIfNeeded();
    bool endApplyingConstraints();

    double zoomScaleFactor() const;
    void setZoomScaleFactor(double);
    double currentFrameRate() const;
    double currentZoom() const;

    enum class FrameRateAndZoomAction : uint8_t {
        None,
        // The preset and frame rate are the ones applied: set the zoom of the device only, then didApplyZoom().
        ApplyZoom,
        // Apply the preset, then setFrameRateAndZoom(), and configure the session.
        Reconfigure,
    };
    struct FrameRateAndZoomChange {
        double frameRate { 0 };
        // The requested zoom, as a zoom factor of the device.
        double zoom { 1 };
        FrameRateAndZoomAction action { FrameRateAndZoomAction::None };
    };
    // isSamePreset: the preset is the current one, by format.
    FrameRateAndZoomChange frameRateAndZoomChange(double frameRate, double zoom, bool isSamePreset) const;
    void didApplyZoom(double);
    void setFrameRateAndZoom(double frameRate, double zoom);
    // Clamps the frame rate to the range that the device's active format supports for it, and returns it.
    double clampFrameRate(double minFrameRate, double maxFrameRate);

    bool isRunning() const;
    // The session's running state changed while the source is muted or not. Returns whether to act on it.
    bool runningDidChange(bool isRunning, bool isMuted);
    void setRunning(bool);
    bool isInterrupted() const;
    void setInterrupted(bool);
    void setShouldNotifyMutedChangeAfterStartup(bool);
    bool takeShouldNotifyMutedChangeAfterStartup();

    enum class VerifyCapturingTimerAction : uint8_t {
        // Stop the timer and reset the frame count.
        Stop,
        Keep,
        // Start the timer and reset the frame count.
        Start,
    };
    VerifyCapturingTimerAction verifyCapturingTimerAction(bool isTimerActive);
    // Returns whether no frame arrived since the last check, given the number of frames received.
    bool hasStoppedCapturing(uint64_t framesCount);

    // Each returns whether to wait until the session runs; then reconfiguration() includes the change.
    bool deferWhiteBalanceModeUpdate();
    bool deferTorchUpdate();
    void needsTorchReconfigurationIf(bool);

    struct Reconfiguration {
        bool isNeeded { false };
        bool torch { false };
        bool whiteBalanceMode { false };
    };
    // The deferred changes to apply now that the session runs.
    Reconfiguration takeReconfiguration();

private:
    double m_currentFrameRate { 0 };
    double m_currentZoom { 1 };
    double m_zoomScaleFactor { 1 };
    uint64_t m_beginConfigurationCount { 0 };
    uint64_t m_lastFramesCount { 0 };
    int32_t m_sensorOrientation { 0 };
    int32_t m_deviceOrientation { 0 };
    uint16_t m_videoFrameRotation { 0 };
    bool m_useSensorAndDeviceOrientation { true };
    bool m_interrupted { false };
    bool m_isRunning { false };
    bool m_hasBegunConfigurationForConstraints { false };
    bool m_needsTorchReconfiguration { false };
    bool m_needsWhiteBalanceReconfiguration { false };
    bool m_shouldCallNotifyMutedChange { false };
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)
