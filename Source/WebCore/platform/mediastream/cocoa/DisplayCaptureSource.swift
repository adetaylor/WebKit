// Copyright (C) 2013 Google Inc. All rights reserved.
// Copyright (C) 2013-2023 Apple Inc. All rights reserved.
// Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
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

// A screen or window capture: the emit timer, capture clock and sizes that DisplayCaptureSourceCocoa had, with a
// capturer, ScreenCaptureKit's (ScreenCaptureKitCapturer.swift) or the mock display's. DisplayCaptureSourceCocoa, a
// RealtimeMediaSource for callers in C++, holds one by identifier through DisplayCaptureSourceHandle and gets its frames
// and events through DisplayCaptureSourceHandle.h's functions.

import CoreGraphics
import CoreMedia
import Dispatch
import Foundation
import WebCore_Private.Core.DisplayCaptureSourceHandle
import WebCore_Private.Core.MockVideoSourceHandle

// A capturer's current frame.
enum DisplayFrame {
    case sampleBuffer(CMSampleBuffer)
    case image(CGImage)
}

// What captures a DisplaySource's frames. It reports to the source on the main thread.
@MainActor
protocol DisplayCapturer: AnyObject {
    var source: DisplaySource? { get set }
    var currentFrame: DisplayFrame? { get }
    // Whether the capturer captures a window, not a display.
    var isWindow: Bool { get }

    func start() -> Bool
    func stop()
    func end()
    func commitConfiguration(width: UInt32, height: UInt32, frameRate: Float)
    func intrinsicSize() -> WebCore.DisplayCaptureSize
    // Call the source's capturerIsReady() when the capturer has its first frame.
    func whenReady()
    // The source is going away: release what the capturer holds.
    func invalidate()
}

// The seconds of MonotonicTime.
private func displayCaptureNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

// The C++ computed these with -fwrapv, and arm64's sdiv gives INT_MIN for INT_MIN / -1.
private func wrappingMultiply(_ a: Int32, _ b: Int32) -> Int32 {
    a &* b
}

private func wrappingDivide(_ a: Int32, _ b: Int32) -> Int32 {
    a.dividedReportingOverflow(by: b).partialValue
}

// A frame's presentation size, as IntSize(CMVideoFormatDescriptionGetPresentationDimensions()) has it, or an empty
// size for a frame that isn't video.
private func presentationSize(of sampleBuffer: CMSampleBuffer) -> WebCore.DisplayCaptureSize {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer), CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video else {
        return WebCore.DisplayCaptureSize()
    }
    let size = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, usePixelAspectRatio: true, useCleanAperture: true)
    return WebCore.DisplayCaptureSize(width: Int32(arm64Truncating: size.width), height: Int32(arm64Truncating: size.height))
}

// MARK: Source

@MainActor
private var displayCaptureSources: [UInt64: DisplaySource] = [:]

@MainActor
private var lastDisplayCaptureSourceIdentifier: UInt64 = 0

@MainActor
final class DisplaySource {
    let identifier: UInt64
    private let capturer: any DisplayCapturer
    // The capture clock: when the current run started (NaN if none), and how long the earlier runs took.
    private var startTime = Double.nan
    private var elapsedTime: Double = 0
    private var timer: (any DispatchSourceTimer)?

    init(identifier: UInt64, capturer: any DisplayCapturer) {
        self.identifier = identifier
        self.capturer = capturer
        capturer.source = self
    }

    func invalidate() {
        stopTimer()
        capturer.invalidate()
    }

    var isWindow: Bool {
        capturer.isWindow
    }

    func intrinsicSize() -> WebCore.DisplayCaptureSize {
        capturer.intrinsicSize()
    }

    func commitConfiguration(width: UInt32, height: UInt32, frameRate: Float) {
        capturer.commitConfiguration(width: width, height: height, frameRate: frameRate)
    }

    func whenReady() {
        capturer.whenReady()
    }

    // MARK: Capturer events

    func capturerFailed() {
        WebCore.displayCaptureSourceDidChange(identifier, .CaptureFailed)
    }

    func capturerConfigurationChanged() {
        WebCore.displayCaptureSourceDidChange(identifier, .ConfigurationChanged)
    }

    func capturerIsReady() {
        WebCore.displayCaptureSourceDidChange(identifier, .Ready)
    }

    // MARK: Producing data

    func startProducingData(frameRate: Double, width: UInt32, height: UInt32, settingsFrameRate: Float) {
        startTime = displayCaptureNow()
        startTimer(frameRate: frameRate)
        capturer.commitConfiguration(width: width, height: height, frameRate: settingsFrameRate)
        if !capturer.start() {
            capturerFailed()
        }
    }

    func stopProducingData() {
        stopTimer()
        elapsedTime += displayCaptureNow() - startTime
        startTime = .nan
        capturer.stop()
    }

    func endProducingData() {
        capturer.end()
    }

    func setFrameRate(_ frameRate: Double) {
        if timer != nil {
            startTimer(frameRate: frameRate)
        }
    }

    // A repeating timer on the main thread, as RunLoop::Timer::startRepeating(1_s / frameRate) was.
    private func startTimer(frameRate: Double) {
        timer?.cancel()
        let interval = DispatchTimeInterval.nanoseconds(Int(arm64Truncating: 1_000_000_000 / frameRate))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.emitFrame()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func emitFrame() {
        if WebCore.displayCaptureSourceIsMuted(identifier) {
            return
        }

        let now = displayCaptureNow()
        let sampleTime = (startTime.isNaN ? elapsedTime : elapsedTime + (now - startTime)) + 0.1

        guard let frame = capturer.currentFrame else {
            return
        }
        switch frame {
        case .sampleBuffer(let sampleBuffer):
            let size = presentationSize(of: sampleBuffer)
            if size.width <= 0 || size.height <= 0 {
                return
            }
            WebCore.displayCaptureSourceDidEmitFrame(identifier, sampleBuffer, nil, sampleTime, size)
        case .image(let image):
            let size = WebCore.DisplayCaptureSize(width: Int32(truncatingIfNeeded: image.width), height: Int32(truncatingIfNeeded: image.height))
            if size.width <= 0 || size.height <= 0 {
                return
            }
            WebCore.displayCaptureSourceDidEmitFrame(identifier, nil, image, sampleTime, size)
        }
    }
}

// MARK: Mock capturer

@MainActor
private weak var latestMockDisplayCapturer: MockDisplayCapturer?

// The mock display capturer, over a mock video generator (MockVideoSource.swift) drawing the display's frames at its
// size and 30 frames a second.
@MainActor
private final class MockDisplayCapturer: DisplayCapturer {
    weak var source: DisplaySource?
    private var display: WebCore.MockDisplayDescription
    private var generator: MockVideoGenerator
    private var frameRate: Float = 0
    private var isRunning = false
    private var isWaitingForReady = false
    private var readyTimer: DispatchWorkItem?

    init(display: WebCore.MockDisplayDescription) {
        self.display = display
        generator = Self.makeGenerator(display)
    }

    private static func makeGenerator(_ display: WebCore.MockDisplayDescription) -> MockVideoGenerator {
        var state = WebCore.MockVideoSourceState()
        state.captureWidth = display.width
        state.captureHeight = display.height
        state.width = display.width
        state.height = display.height
        return MockVideoGenerator(state: MockVideoFrameState(display.video, state)) { _, _ in
            30
        }
    }

    var currentFrame: DisplayFrame? {
        generator.latestImage.map { DisplayFrame.image($0) }
    }

    var isWindow: Bool {
        false
    }

    func start() -> Bool {
        assert(frameRate != 0)
        assert(!isWaitingForReady)
        assert(!isRunning)

        isRunning = true
        generator.startProducingData(frameRate: 30)
        return true
    }

    func stop() {
        assert(!isWaitingForReady)

        isRunning = false
        generator.stopProducingData()
    }

    func end() {
        stop()
    }

    func commitConfiguration(width: UInt32, height: UInt32, frameRate: Float) {
        self.frameRate = frameRate
    }

    func intrinsicSize() -> WebCore.DisplayCaptureSize {
        WebCore.DisplayCaptureSize(width: display.width, height: display.height)
    }

    func whenReady() {
        assert(!isRunning)

        isWaitingForReady = true
        readyTimer?.cancel()
        let readyTimer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.readyTimerFired()
            }
        }
        self.readyTimer = readyTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: readyTimer)
    }

    private func readyTimerFired() {
        assert(!isRunning)

        readyTimer = nil
        source?.capturerConfigurationChanged()
        isWaitingForReady = false
        source?.capturerIsReady()
    }

    // The display changed to the other mock display of its kind.
    func configurationChanged(screen: WebCore.MockDisplayDescription, window: WebCore.MockDisplayDescription) {
        display = display.video.kind == .Window ? window : screen
        generator.invalidate()
        generator = Self.makeGenerator(display)
        if isRunning {
            generator.startProducingData(frameRate: 30)
        }
        source?.capturerConfigurationChanged()
    }

    func invalidate() {
        readyTimer?.cancel()
        readyTimer = nil
        generator.invalidate()
    }
}

// MARK: Handle

@MainActor
private func makeDisplayCaptureSource(_ capturer: (UInt64) -> any DisplayCapturer) -> UInt64 {
    lastDisplayCaptureSourceIdentifier &+= 1
    let identifier = lastDisplayCaptureSourceIdentifier
    displayCaptureSources[identifier] = DisplaySource(identifier: identifier, capturer: capturer(identifier))
    return identifier
}

extension WebCore.DisplayCaptureSourceHandle {
    @MainActor
    private var source: DisplaySource? {
        displayCaptureSources[m_identifier]
    }

#if HAVE_SCREEN_CAPTURE_KIT
    @cxx
    @implementation
    static func create(_ isWindow: Bool, _ deviceID: UInt32) -> WebCore.DisplayCaptureSourceHandle {
        var handle = WebCore.DisplayCaptureSourceHandle()
        handle.m_identifier = MainActor.assumeIsolated {
            makeDisplayCaptureSource { identifier in
                ScreenCaptureKitCapturer(identifier: identifier, isWindow: isWindow, deviceID: deviceID)
            }
        }
        return handle
    }
#endif

    @cxx
    @implementation
    static func createMock(_ display: WebCore.MockDisplayDescription) -> WebCore.DisplayCaptureSourceHandle {
        var handle = WebCore.DisplayCaptureSourceHandle()
        handle.m_identifier = MainActor.assumeIsolated {
            makeDisplayCaptureSource { _ in
                let capturer = MockDisplayCapturer(display: display)
                latestMockDisplayCapturer = capturer
                return capturer
            }
        }
        return handle
    }

    @cxx
    @implementation
    static func triggerMockConfigurationChange(_ screen: WebCore.MockDisplayDescription, _ window: WebCore.MockDisplayDescription) {
        MainActor.assumeIsolated {
            latestMockDisplayCapturer?.configurationChanged(screen: screen, window: window)
        }
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

    @cxx
    @implementation
    mutating func destroy() {
        let identifier = m_identifier
        m_identifier = 0
        MainActor.assumeIsolated {
            displayCaptureSources.removeValue(forKey: identifier)?.invalidate()
        }
    }

    @cxx
    @implementation
    mutating func startProducingData(_ frameRate: Double, _ width: UInt32, _ height: UInt32, _ settingsFrameRate: Float) {
        MainActor.assumeIsolated {
            source?.startProducingData(frameRate: frameRate, width: width, height: height, settingsFrameRate: settingsFrameRate)
        }
    }

    @cxx
    @implementation
    mutating func stopProducingData() {
        MainActor.assumeIsolated {
            source?.stopProducingData()
        }
    }

    @cxx
    @implementation
    mutating func endProducingData() {
        MainActor.assumeIsolated {
            source?.endProducingData()
        }
    }

    @cxx
    @implementation
    mutating func setFrameRate(_ frameRate: Double) {
        MainActor.assumeIsolated {
            source?.setFrameRate(frameRate)
        }
    }

    @cxx
    @implementation
    mutating func commitConfiguration(_ width: UInt32, _ height: UInt32, _ frameRate: Float) {
        MainActor.assumeIsolated {
            source?.commitConfiguration(width: width, height: height, frameRate: frameRate)
        }
    }

    @cxx
    @implementation
    mutating func whenReady() {
        MainActor.assumeIsolated {
            source?.whenReady()
        }
    }

    @cxx
    @implementation
    func intrinsicSize() -> WebCore.DisplayCaptureSize {
        MainActor.assumeIsolated {
            source?.intrinsicSize() ?? WebCore.DisplayCaptureSize()
        }
    }

    @cxx
    @implementation
    func isWindow() -> Bool {
        MainActor.assumeIsolated {
            source?.isWindow ?? false
        }
    }

}

#endif
