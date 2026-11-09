// Copyright (C) 2017-2024 Apple Inc. All rights reserved.
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM

// The decisions of DisplayCaptureSourceCocoa and ScreenCaptureKitCaptureSource, on the plain state that
// DisplayCaptureCore.h declares and the C++ classes hold. The C++ keeps the ScreenCaptureKit, CoreMedia and VideoToolbox
// objects and applies what these return. The arithmetic is the C++'s, operation for operation: floats stay floats, and
// conversions to integers saturate as arm64's do.

import WebCore_Private.Core.DisplayCaptureCore

private let defaultIntrinsicSize = WebCore.DisplayCaptureSize(width: 640, height: 480)

// The C++ classes compute these with -fwrapv, and arm64's sdiv gives INT_MIN for INT_MIN / -1.
private func wrappingMultiply(_ a: Int32, _ b: Int32) -> Int32 {
    a &* b
}

private func wrappingDivide(_ a: Int32, _ b: Int32) -> Int32 {
    a.dividedReportingOverflow(by: b).partialValue
}

// WTF's clampTo<int>(float), which IntSize(const FloatSize&) uses: NaN gives INT_MIN.
private func clampToInt32ForIntSize(_ value: Float) -> Int32 {
    if value >= Float(Int32.max) {
        return .max
    }
    if !(value > Float(Int32.min)) {
        return .min
    }
    return Int32(value)
}

private func isEmpty(_ width: Float, _ height: Float) -> Bool {
    width <= 0 || height <= 0
}

// ScreenCaptureKitCaptureSource's areSizesRoughlyEqual.
private func areSizesRoughlyEqual(_ a: WebCore.DisplayCaptureFloatSize, _ b: WebCore.DisplayCaptureFloatSize) -> Bool {
    abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
}

// FloatRect::scale(float).
private func scaled(_ rect: WebCore.DisplayCaptureFloatRect, by factor: Float) -> WebCore.DisplayCaptureFloatRect {
    WebCore.DisplayCaptureFloatRect(x: rect.x * factor, y: rect.y * factor, width: rect.width * factor, height: rect.height * factor)
}

private func size(of rect: WebCore.DisplayCaptureFloatRect) -> WebCore.DisplayCaptureFloatSize {
    WebCore.DisplayCaptureFloatSize(width: rect.width, height: rect.height)
}

// MARK: DisplayCaptureSourceCocoa

private func captureElapsedTime(startTime: Double, elapsedTime: Double, now: Double) -> Double {
    if startTime.isNaN {
        return elapsedTime
    }
    return elapsedTime + (now - startTime)
}

extension WebCore.DisplayCaptureSourceCore {
    @cxx
    @implementation
    mutating func startClock(_ now: Double) {
        m_startTime = now
    }

    @cxx
    @implementation
    mutating func stopClock(_ now: Double) {
        m_elapsedTime += now - m_startTime
        m_startTime = .nan
    }

    @cxx
    @implementation
    func elapsedTime(_ now: Double) -> Double {
        captureElapsedTime(startTime: m_startTime, elapsedTime: m_elapsedTime, now: now)
    }

    @cxx
    @implementation
    func sampleTime(_ now: Double) -> Double {
        captureElapsedTime(startTime: m_startTime, elapsedTime: m_elapsedTime, now: now) + 0.1
    }

    @cxx
    @implementation
    static func resizedVideoFrameSize(
        _ desired: WebCore.DisplayCaptureSize,
        _ intrinsic: WebCore.DisplayCaptureSize
    ) -> WebCore.DisplayCaptureSize {
        if intrinsic.width == 0 || intrinsic.height == 0 {
            return desired
        }

        var desired = desired
        if desired.height == 0 {
            desired.height = intrinsic.height
        }
        if desired.width == 0 {
            desired.width = intrinsic.width
        }

        let maxHeight = min(desired.height, intrinsic.height)
        let maxWidth = min(desired.width, intrinsic.width)

        let heightForMaxWidth = wrappingDivide(wrappingMultiply(maxWidth, intrinsic.height), intrinsic.width)
        let widthForMaxHeight = wrappingDivide(wrappingMultiply(maxHeight, intrinsic.width), intrinsic.height)

        if heightForMaxWidth <= maxHeight {
            return WebCore.DisplayCaptureSize(width: maxWidth, height: heightForMaxWidth)
        }

        if widthForMaxHeight <= maxWidth {
            return WebCore.DisplayCaptureSize(width: widthForMaxHeight, height: maxHeight)
        }

        return intrinsic
    }
}

// MARK: ScreenCaptureKitCaptureSource

extension WebCore.ScreenCaptureKitCaptureCore {
    @cxx
    @implementation
    mutating func whenReady() -> WhenReadyAction {
        if m_didReceiveVideoFrame {
            return .CallNow
        }
        if m_isRunning {
            return .Wait
        }
        m_isPrewarming = true
        return .StartPrewarming
    }

    @cxx
    @implementation
    mutating func startInternal(_ isPrewarming: Bool) -> Bool {
        m_isPrewarming = isPrewarming
        if m_isRunning {
            return false
        }
        m_isRunning = true
        return true
    }

    @cxx
    @implementation
    mutating func didStartContentStream() {
        m_isRunning = true
    }

    @cxx
    @implementation
    mutating func stop() {
        m_isRunning = false
    }

    @cxx
    @implementation
    func isRunning() -> Bool {
        m_isRunning
    }

    @cxx
    @implementation
    mutating func setContentSize(_ width: Double, _ height: Double, _ pointPixelScale: Float) {
        var contentSize = WebCore.DisplayCaptureFloatSize(width: Float(width), height: Float(height))
        if isEmpty(contentSize.width, contentSize.height) {
            contentSize = WebCore.DisplayCaptureFloatSize(
                width: Float(defaultIntrinsicSize.width),
                height: Float(defaultIntrinsicSize.height)
            )
        }
        if pointPixelScale != 0 {
            contentSize.width *= pointPixelScale
            contentSize.height *= pointPixelScale
        }
        m_contentSize = contentSize
    }

    @cxx
    @implementation
    mutating func commitConfiguration(_ width: UInt32, _ height: UInt32, _ frameRate: Float) -> Bool {
        if m_width == width && m_height == height && m_frameRate == frameRate {
            return false
        }
        m_width = width
        m_height = height
        m_frameRate = frameRate
        return true
    }

    @cxx
    @implementation
    func streamConfiguration() -> StreamConfiguration {
        var configuration = StreamConfiguration()

        if m_frameRate != 0 {
            configuration.hasMinimumFrameInterval = true
            configuration.minimumFrameInterval = Double(1 / m_frameRate)
        }

        var width = m_width
        var height = m_height

        if width == 0 && height == 0 {
            width = UInt32(arm64Truncating: m_contentSize.width)
            height = UInt32(arm64Truncating: m_contentSize.height)
        } else if !isEmpty(m_contentSize.width, m_contentSize.height) {
            let aspectRatio = m_contentSize.width / m_contentSize.height
            if width == 0 {
                width = UInt32(arm64Truncating: Float(height) * aspectRatio)
            } else {
                height = UInt32(arm64Truncating: Float(width) / aspectRatio)
            }
        }

        if width != 0 && height != 0 {
            configuration.hasSize = true
            configuration.width = width
            configuration.height = height
        }

        return configuration
    }

    @cxx
    @implementation
    mutating func resetIntrinsicSize() {
        m_hasIntrinsicSize = false
    }

    @cxx
    @implementation
    mutating func intrinsicSize(
        _ hasContentFrame: Bool,
        _ frameWidth: Double,
        _ frameHeight: Double,
        _ isEmptyContentFrameDefault: Bool
    ) -> WebCore.DisplayCaptureSize {
        if m_hasIntrinsicSize {
            return m_intrinsicSize
        }
        if !hasContentFrame {
            return defaultIntrinsicSize
        }
        if isEmptyContentFrameDefault && (frameWidth == 0 || frameHeight == 0) {
            return defaultIntrinsicSize
        }
        m_intrinsicSize = WebCore.DisplayCaptureSize(width: Int32(arm64Truncating: frameWidth), height: Int32(arm64Truncating: frameHeight))
        m_hasIntrinsicSize = true
        return m_intrinsicSize
    }

    @cxx
    @implementation
    mutating func frameDidArrive(_ attachments: WebCore.DisplayCaptureFrameAttachments) -> FrameDecision {
        var decision = FrameDecision()

        if m_didReceiveVideoFrame && m_isPrewarming {
            decision.isPrewarmingFrame = true
            return decision
        }

        if attachments.hasStatus {
            switch attachments.status {
            case WebCore.DisplayCaptureFrameStatus.Idle.rawValue,
                WebCore.DisplayCaptureFrameStatus.Blank.rawValue,
                WebCore.DisplayCaptureFrameStatus.Suspended.rawValue,
                WebCore.DisplayCaptureFrameStatus.Stopped.rawValue:
                return decision
            default:
                break
            }
        }

        decision.shouldUseFrame = true

        var contentRect = attachments.contentRect
        if attachments.scaleFactor != 1 {
            contentRect = scaled(contentRect, by: Float(attachments.scaleFactor))
        }
        decision.contentRect = contentRect

        var scaledContentRect = contentRect
        if attachments.contentScale != 0 && attachments.contentScale != 1 {
            scaledContentRect = scaled(scaledContentRect, by: Float(1 / attachments.contentScale))
        }

        if !attachments.shouldDisallowReconfiguration && !areSizesRoughlyEqual(m_contentSize, size(of: scaledContentRect)) {
            m_contentSize = size(of: scaledContentRect)
            decision.shouldUpdateStreamConfiguration = true
        }

        return decision
    }

    @cxx
    @implementation
    func contentSize() -> WebCore.DisplayCaptureFloatSize {
        m_contentSize
    }

    @cxx
    @implementation
    static func shouldCropFrame(_ contentRect: WebCore.DisplayCaptureFloatRect, _ frameSize: WebCore.DisplayCaptureFloatSize) -> Bool {
        if isEmpty(contentRect.width, contentRect.height) || isEmpty(frameSize.width, frameSize.height) {
            return false
        }
        return !areSizesRoughlyEqual(size(of: contentRect), frameSize)
    }

    @cxx
    @implementation
    mutating func intrinsicSizeDidChange(_ frameSize: WebCore.DisplayCaptureFloatSize) -> Bool {
        let intrinsicSize = WebCore.DisplayCaptureSize(
            width: clampToInt32ForIntSize(frameSize.width),
            height: clampToInt32ForIntSize(frameSize.height)
        )
        if m_hasIntrinsicSize && m_intrinsicSize.width == intrinsicSize.width && m_intrinsicSize.height == intrinsicSize.height {
            return false
        }
        m_intrinsicSize = intrinsicSize
        m_hasIntrinsicSize = true
        return true
    }

    @cxx
    @implementation
    mutating func firstFrameDidArrive() -> Bool {
        if m_didReceiveVideoFrame {
            return false
        }
        m_didReceiveVideoFrame = true
        return true
    }
}

#endif
