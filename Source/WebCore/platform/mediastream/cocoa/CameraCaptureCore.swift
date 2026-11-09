// Copyright (C) 2013-2023 Apple Inc. All rights reserved.
// Copyright (C) 2013-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM && HAVE_AVCAPTUREDEVICE

// What AVVideoCaptureSource does on each event, on the plain state that CameraCaptureCore.h declares and the source
// holds. The source keeps its AVFoundation objects and applies what these return.

import WebCore_Private.Core.CameraCaptureCore

// VideoFrameRotation.
private let rotationNone: UInt16 = 0
private let rotationUpsideDown: UInt16 = 180
private let rotationRight: UInt16 = 90
private let rotationLeft: UInt16 = 270

extension WebCore.CameraCaptureCore {
    // MARK: Rotation

    @cxx
    @implementation
    func videoFrameRotation() -> UInt16 {
        m_videoFrameRotation
    }

    @cxx
    @implementation
    mutating func setSensorOrientation(_ orientation: Int32) {
        m_sensorOrientation = orientation
    }

    @cxx
    @implementation
    mutating func setDeviceOrientation(_ orientation: Int32) {
        m_deviceOrientation = orientation
    }

    @cxx
    @implementation
    mutating func stopUsingSensorAndDeviceOrientation() {
        m_useSensorAndDeviceOrientation = false
    }

    @cxx
    @implementation
    mutating func computeVideoFrameRotation(_ isFrontCamera: Bool) -> Bool {
        if !m_useSensorAndDeviceOrientation {
            return false
        }

        let rotation: UInt16
        switch m_sensorOrientation &- m_deviceOrientation {
        case 0:
            rotation = rotationNone
        case 180, -180:
            rotation = rotationUpsideDown
        case 90, -270:
            rotation = isFrontCamera ? rotationLeft : rotationRight
        case -90, 270:
            rotation = isFrontCamera ? rotationRight : rotationLeft
        default:
            assertionFailure("an orientation that isn't a multiple of 90 degrees")
            rotation = rotationNone
        }
        if rotation == m_videoFrameRotation {
            return false
        }

        m_videoFrameRotation = rotation
        return true
    }

    @cxx
    @implementation
    mutating func horizonLevelRotationDidChange(_ rotation: UInt16) -> Bool {
        m_useSensorAndDeviceOrientation = false
        if rotation == m_videoFrameRotation {
            return false
        }
        m_videoFrameRotation = rotation
        return true
    }

    // MARK: Session configuration

    @cxx
    @implementation
    mutating func beginConfiguration() -> Bool {
        m_beginConfigurationCount &+= 1
        return m_beginConfigurationCount <= 1
    }

    @cxx
    @implementation
    mutating func commitConfiguration() -> Bool {
        if m_beginConfigurationCount == 0 {
            return false
        }
        m_beginConfigurationCount -= 1
        return m_beginConfigurationCount == 0
    }

    @cxx
    @implementation
    func hasBegunConfiguration() -> Bool {
        m_beginConfigurationCount != 0
    }

    @cxx
    @implementation
    mutating func startApplyingConstraints() {
        assert(!m_hasBegunConfigurationForConstraints)
        m_hasBegunConfigurationForConstraints = false
    }

    @cxx
    @implementation
    mutating func beginConfigurationForConstraintsIfNeeded() -> Bool {
        if m_hasBegunConfigurationForConstraints {
            return false
        }
        m_hasBegunConfigurationForConstraints = true
        return true
    }

    @cxx
    @implementation
    mutating func endApplyingConstraints() -> Bool {
        if !m_hasBegunConfigurationForConstraints {
            return false
        }
        m_hasBegunConfigurationForConstraints = false
        return true
    }

    // MARK: Frame rate and zoom

    @cxx
    @implementation
    func zoomScaleFactor() -> Double {
        m_zoomScaleFactor
    }

    @cxx
    @implementation
    mutating func setZoomScaleFactor(_ factor: Double) {
        m_zoomScaleFactor = factor
    }

    @cxx
    @implementation
    func currentFrameRate() -> Double {
        m_currentFrameRate
    }

    @cxx
    @implementation
    func currentZoom() -> Double {
        m_currentZoom
    }

    @cxx
    @implementation
    func frameRateAndZoomChange(_ frameRate: Double, _ zoom: Double, _ isSamePreset: Bool) -> FrameRateAndZoomChange {
        var change = FrameRateAndZoomChange()
        change.frameRate = frameRate
        change.zoom = zoom * m_zoomScaleFactor
        let isSamePresetAndFrameRate = m_currentFrameRate == frameRate && isSamePreset
        if isSamePresetAndFrameRate && m_currentZoom == change.zoom {
            change.action = .None
        } else if isSamePresetAndFrameRate {
            change.action = .ApplyZoom
        } else {
            change.action = .Reconfigure
        }
        return change
    }

    @cxx
    @implementation
    mutating func didApplyZoom(_ zoom: Double) {
        m_currentZoom = zoom
    }

    @cxx
    @implementation
    mutating func setFrameRateAndZoom(_ frameRate: Double, _ zoom: Double) {
        m_currentFrameRate = frameRate
        m_currentZoom = zoom
    }

    // WTF's clampTo(double, double, double).
    @cxx
    @implementation
    mutating func clampFrameRate(_ minFrameRate: Double, _ maxFrameRate: Double) -> Double {
        if m_currentFrameRate >= maxFrameRate {
            m_currentFrameRate = maxFrameRate
        } else if m_currentFrameRate <= minFrameRate {
            m_currentFrameRate = minFrameRate
        }
        return m_currentFrameRate
    }

    // MARK: Running and interruption

    @cxx
    @implementation
    func isRunning() -> Bool {
        m_isRunning
    }

    @cxx
    @implementation
    mutating func runningDidChange(_ isRunning: Bool, _ isMuted: Bool) -> Bool {
        if isRunning == m_isRunning && isRunning == !isMuted {
            return false
        }
        m_isRunning = isRunning
        return true
    }

    @cxx
    @implementation
    mutating func setRunning(_ isRunning: Bool) {
        m_isRunning = isRunning
    }

    @cxx
    @implementation
    func isInterrupted() -> Bool {
        m_interrupted
    }

    @cxx
    @implementation
    mutating func setInterrupted(_ interrupted: Bool) {
        m_interrupted = interrupted
    }

    @cxx
    @implementation
    mutating func setShouldNotifyMutedChangeAfterStartup(_ shouldNotify: Bool) {
        m_shouldCallNotifyMutedChange = shouldNotify
    }

    @cxx
    @implementation
    mutating func takeShouldNotifyMutedChangeAfterStartup() -> Bool {
        let shouldNotify = m_shouldCallNotifyMutedChange
        m_shouldCallNotifyMutedChange = false
        return shouldNotify
    }

    // MARK: Verifying capture

    @cxx
    @implementation
    mutating func verifyCapturingTimerAction(_ isTimerActive: Bool) -> VerifyCapturingTimerAction {
        if !m_isRunning || m_interrupted {
            m_lastFramesCount = 0
            return .Stop
        }
        if isTimerActive {
            return .Keep
        }
        m_lastFramesCount = 0
        return .Start
    }

    @cxx
    @implementation
    mutating func hasStoppedCapturing(_ framesCount: UInt64) -> Bool {
        if m_lastFramesCount != framesCount {
            m_lastFramesCount = framesCount
            return false
        }
        return true
    }

    // MARK: Torch and white balance

    @cxx
    @implementation
    mutating func deferWhiteBalanceModeUpdate() -> Bool {
        if m_isRunning {
            return false
        }
        m_needsWhiteBalanceReconfiguration = true
        return true
    }

    @cxx
    @implementation
    mutating func deferTorchUpdate() -> Bool {
        if m_isRunning {
            return false
        }
        m_needsTorchReconfiguration = true
        return true
    }

    @cxx
    @implementation
    mutating func needsTorchReconfigurationIf(_ torch: Bool) {
        m_needsTorchReconfiguration = m_needsTorchReconfiguration || torch
    }

    @cxx
    @implementation
    mutating func takeReconfiguration() -> Reconfiguration {
        var reconfiguration = Reconfiguration()
        if !m_isRunning || (!m_needsTorchReconfiguration && !m_needsWhiteBalanceReconfiguration) {
            return reconfiguration
        }
        reconfiguration.isNeeded = true
        reconfiguration.torch = m_needsTorchReconfiguration
        reconfiguration.whiteBalanceMode = m_needsWhiteBalanceReconfiguration
        m_needsTorchReconfiguration = false
        m_needsWhiteBalanceReconfiguration = false
        return reconfiguration
    }
}

#endif
