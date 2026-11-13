// Copyright (C) 2015-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer
//    in the documentation and/or other materials provided with the
//    distribution.
// 3. Neither the name of Google Inc. nor the names of its contributors
//    may be used to endorse or promote products derived from this
//    software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM

// The settings and capabilities of a mock camera or display, for MockRealtimeVideoSource and the GPU process's Swift
// mock camera.

import WebCore_Private.Core.MockVideoSettings

private struct SupportedConstraint {
    static let width: UInt32 = 1 << 0
    static let height: UInt32 = 1 << 1
    static let aspectRatio: UInt32 = 1 << 2
    static let frameRate: UInt32 = 1 << 3
    static let facingMode: UInt32 = 1 << 4
    static let deviceId: UInt32 = 1 << 9
    static let groupId: UInt32 = 1 << 10
    static let displaySurface: UInt32 = 1 << 11
    static let logicalSurface: UInt32 = 1 << 12
    static let focusDistance: UInt32 = 1 << 13
    static let whiteBalanceMode: UInt32 = 1 << 14
    static let zoom: UInt32 = 1 << 15
    static let torch: UInt32 = 1 << 16
    static let backgroundBlur: UInt32 = 1 << 17
    static let powerEfficient: UInt32 = 1 << 18
}

// VideoFacingMode::Unknown and Environment, VideoFrameRotation::Right and Left, DisplaySurfaceType::Monitor and Window,
// RealtimeMediaSourceCapabilities::BackgroundBlur::On.
private let facingModeUnknown: UInt8 = 0
private let facingModeEnvironment: UInt8 = 2
private let rotationRight: UInt16 = 90
private let rotationLeft: UInt16 = 270
private let displaySurfaceMonitor: UInt8 = 0
private let displaySurfaceWindow: UInt8 = 1
private let backgroundBlurOn: UInt8 = 1

extension WebCore.MockVideoSettings {
    @cxx
    @implementation
    static func settings(_ inputs: WebCore.MockVideoSettingsInputs) -> WebCore.CaptureSettingsValues {
        var settings = WebCore.CaptureSettingsValues()
        let isCamera = inputs.kind == .Camera
        if isCamera {
            settings.facingMode = inputs.facingMode
        } else {
            settings.displaySurface = inputs.kind == .Screen ? displaySurfaceMonitor : displaySurfaceWindow
            settings.logicalSurface = false
        }
        settings.frameRate = Float(inputs.frameRate)
        var width = inputs.width
        var height = inputs.height
        if isCamera && (inputs.deviceOrientation == rotationLeft || inputs.deviceOrientation == rotationRight) {
            swap(&width, &height)
        }
        settings.width = UInt32(truncatingIfNeeded: width)
        settings.height = UInt32(truncatingIfNeeded: height)

        var supported = SupportedConstraint.frameRate | SupportedConstraint.width | SupportedConstraint.height
        if isCamera {
            supported |= SupportedConstraint.aspectRatio
        }
        supported |= SupportedConstraint.deviceId | SupportedConstraint.groupId
        if isCamera {
            if inputs.facingMode != facingModeUnknown {
                supported |= SupportedConstraint.facingMode
            }
            if inputs.isZoomSupported {
                supported |= SupportedConstraint.zoom
                settings.zoom = inputs.zoom
            }
            if inputs.hasWhiteBalanceModes {
                supported |= SupportedConstraint.whiteBalanceMode
                settings.whiteBalanceMode = inputs.whiteBalanceMode
            }
            if inputs.hasTorch {
                supported |= SupportedConstraint.torch
                settings.torch = inputs.torch
            }
            if inputs.canBePowerEfficient {
                settings.powerEfficient = inputs.presetIsEfficient
            }
            supported |= SupportedConstraint.powerEfficient
            supported |= SupportedConstraint.backgroundBlur
            settings.backgroundBlur = inputs.hasBackgroundBlur
        } else {
            supported |= SupportedConstraint.displaySurface | SupportedConstraint.logicalSurface
        }
        settings.supportedConstraints = supported
        return settings
    }

    @cxx
    @implementation
    static func capabilities(_ inputs: WebCore.MockVideoCapabilityInputs) -> WebCore.CaptureCapabilityValues {
        var capabilities = WebCore.CaptureCapabilityValues()
        var supported = inputs.settingsSupportedConstraints
        capabilities.supportedConstraints = supported
        switch inputs.kind {
        case .Camera:
            if inputs.facingMode != facingModeUnknown {
                capabilities.facingModes = UInt8(1) << inputs.facingMode
            }
            capabilities.widthMin = inputs.ranges.widthMin
            capabilities.widthMax = inputs.ranges.widthMax
            capabilities.heightMin = inputs.ranges.heightMin
            capabilities.heightMax = inputs.ranges.heightMax
            capabilities.aspectRatioMin = inputs.ranges.aspectRatioMin
            capabilities.aspectRatioMax = inputs.ranges.aspectRatioMax
            capabilities.frameRateMin = inputs.ranges.frameRateMin
            capabilities.frameRateMax = inputs.ranges.frameRateMax
            capabilities.zoomMin = inputs.ranges.zoomMin
            capabilities.zoomMax = inputs.ranges.zoomMax
            if inputs.facingMode == facingModeEnvironment {
                capabilities.focusDistanceMin = 0.2
                capabilities.focusDistanceMax = .greatestFiniteMagnitude
                supported |= SupportedConstraint.focusDistance
            }
            if inputs.whiteBalanceModes != 0 {
                capabilities.whiteBalanceModes = inputs.whiteBalanceModes
                supported |= SupportedConstraint.whiteBalanceMode
            }
            if inputs.hasTorch {
                capabilities.torch = true
                supported |= SupportedConstraint.torch
            }
            capabilities.backgroundBlur = inputs.hasBackgroundBlur ? backgroundBlurOn : 0
            supported |= SupportedConstraint.backgroundBlur
            capabilities.powerEfficient = inputs.canBePowerEfficient
            supported |= SupportedConstraint.powerEfficient
            capabilities.supportedConstraints = supported
        case .Screen, .Window:
            capabilities.widthMin = 72
            capabilities.widthMax = inputs.displayWidth
            capabilities.heightMin = 45
            capabilities.heightMax = inputs.displayHeight
            capabilities.frameRateMin = 0.01
            capabilities.frameRateMax = 60
        @unknown default:
            capabilities.widthMin = 72
            capabilities.widthMax = 2880
            capabilities.heightMin = 45
            capabilities.heightMax = 1800
            capabilities.frameRateMin = 0.01
            capabilities.frameRateMax = 60
        }
        return capabilities
    }
}

#endif
