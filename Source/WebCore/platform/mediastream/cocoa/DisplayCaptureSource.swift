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
import WebCore_Private.Core.CaptureSourceDecisions
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

// MARK: Owner

// Who a display source tells about its events and frames: DisplayCaptureSourceCocoa, the C++ facade, through
// DisplayCaptureSourceHandle.h's functions, unless a Swift capture source (CaptureSource.swift) owns it.
@MainActor
protocol DisplayCaptureSourceOwner: AnyObject {
    func displayDidChange(_ event: WebCore.DisplayCaptureSourceEvent)
    var displayIsMuted: Bool { get }
    func displayDidEmitFrame(_ frame: DisplayFrame, sampleTime: Double, size: WebCore.DisplayCaptureSize)
    func displayCroppedFrame(_ frame: CMSampleBuffer, _ rect: WebCore.DisplayCaptureFloatRect, _ frameSize: WebCore.DisplayCaptureFloatSize) -> CMSampleBuffer?
}

@MainActor
private var displayCaptureSourceOwners: [UInt64: () -> (any DisplayCaptureSourceOwner)?] = [:]

@MainActor
func setDisplayCaptureSourceOwner(_ identifier: UInt64, _ owner: (any DisplayCaptureSourceOwner)?) {
    if let owner {
        displayCaptureSourceOwners[identifier] = { [weak owner] in owner }
    } else {
        displayCaptureSourceOwners.removeValue(forKey: identifier)
    }
}

@MainActor
private func displayOwner(_ identifier: UInt64) -> (any DisplayCaptureSourceOwner)? {
    displayCaptureSourceOwners[identifier]?()
}

@MainActor
private func displayDidChange(_ identifier: UInt64, _ event: WebCore.DisplayCaptureSourceEvent) {
    if let owner = displayOwner(identifier) {
        owner.displayDidChange(event)
        return
    }
    WebCore.displayCaptureSourceDidChange(identifier, event)
}

@MainActor
private func displayIsMuted(_ identifier: UInt64) -> Bool {
    if let owner = displayOwner(identifier) {
        return owner.displayIsMuted
    }
    return WebCore.displayCaptureSourceIsMuted(identifier)
}

@MainActor
private func displayDidEmitFrame(_ identifier: UInt64, _ frame: DisplayFrame, _ sampleTime: Double, _ size: WebCore.DisplayCaptureSize) {
    if let owner = displayOwner(identifier) {
        owner.displayDidEmitFrame(frame, sampleTime: sampleTime, size: size)
        return
    }
    switch frame {
    case .sampleBuffer(let sampleBuffer):
        WebCore.displayCaptureSourceDidEmitFrame(identifier, sampleBuffer, nil, sampleTime, size)
    case .image(let image):
        WebCore.displayCaptureSourceDidEmitFrame(identifier, nil, image, sampleTime, size)
    }
}

// The frame cropped, for ScreenCaptureKitCapturer.swift.
@MainActor
func displayCroppedFrame(_ identifier: UInt64, _ frame: CMSampleBuffer, _ rect: WebCore.DisplayCaptureFloatRect, _ frameSize: WebCore.DisplayCaptureFloatSize) -> CMSampleBuffer? {
    if let owner = displayOwner(identifier) {
        return owner.displayCroppedFrame(frame, rect, frameSize)
    }
    return WebCore.displayCaptureSourceCopyCroppedFrame(identifier, frame, rect, frameSize)
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

    // DisplayCaptureSourceCocoa's settings and capabilities, which it gets from here.
    func settings(frameRate: Double, width: Int32, height: Int32) -> WebCore.CaptureSettingsValues {
        var settings = WebCore.CaptureSettingsValues()
        settings.frameRate = Float(frameRate)
        settings.width = UInt32(truncatingIfNeeded: width)
        settings.height = UInt32(truncatingIfNeeded: height)
        // DisplaySurfaceType::Window and Monitor.
        settings.displaySurface = capturer.isWindow ? 1 : 0
        settings.logicalSurface = false
        // RealtimeMediaSourceSupportedConstraints's width, height, frame rate, device ID, display surface and logical
        // surface.
        settings.supportedConstraints = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 9) | (1 << 11) | (1 << 12)
        return settings
    }

    func capabilities(settingsSupportedConstraints: UInt32) -> WebCore.CaptureCapabilityValues {
        var capabilities = WebCore.CaptureCapabilityValues()
        capabilities.supportedConstraints = settingsSupportedConstraints
        let intrinsicSize = capturer.intrinsicSize()
        if intrinsicSize.width != 0 {
            capabilities.widthMin = 1
            capabilities.widthMax = intrinsicSize.width
        }
        if intrinsicSize.height != 0 {
            capabilities.heightMin = 1
            capabilities.heightMax = intrinsicSize.height
        }
        capabilities.frameRateMin = 0.01
        capabilities.frameRateMax = 30
        return capabilities
    }

    func commitConfiguration(width: UInt32, height: UInt32, frameRate: Float) {
        capturer.commitConfiguration(width: width, height: height, frameRate: frameRate)
    }

    func whenReady() {
        capturer.whenReady()
    }

    // MARK: Capturer events

    func capturerFailed() {
        displayDidChange(identifier, .CaptureFailed)
    }

    func capturerConfigurationChanged() {
        displayDidChange(identifier, .ConfigurationChanged)
    }

    func capturerIsReady() {
        displayDidChange(identifier, .Ready)
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
        if displayIsMuted(identifier) {
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
            displayDidEmitFrame(identifier, frame, sampleTime, size)
        case .image(let image):
            let size = WebCore.DisplayCaptureSize(width: Int32(truncatingIfNeeded: image.width), height: Int32(truncatingIfNeeded: image.height))
            if size.width <= 0 || size.height <= 0 {
                return
            }
            displayDidEmitFrame(identifier, frame, sampleTime, size)
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

// MARK: Swift capture source

// Keeps the process out of app nap while a display is captured, and for 5 seconds after, as WebCore::UserActivity does.
@MainActor
private final class DisplayCaptureProcessActivity {
    private static let hysteresisSeconds = 5.0

    private var activity: (any NSObjectProtocol)?
    private var isActive = false
    private var stopGeneration = 0

    func start() {
        if isActive {
            return
        }
        isActive = true
        stopGeneration &+= 1
        if activity == nil {
            let options = ProcessInfo.ActivityOptions([.userInitiatedAllowingIdleSystemSleep, .latencyCritical])
                .subtracting([.suddenTerminationDisabled, .automaticTerminationDisabled])
            activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "App nap disabled for screen capture")
        }
    }

    func stop() {
        if !isActive {
            return
        }
        isActive = false
        stopGeneration &+= 1
        let generation = stopGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hysteresisSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.stopGeneration == generation else {
                    return
                }
                self.end()
            }
        }
    }

    private func end() {
        if let activity = activity.take() {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    isolated deinit {
        end()
    }
}

// A display capture that a Swift capture source of the GPU process owns: what DisplayCaptureSourceCocoa does.
@MainActor
final class DisplayCaptureBackend: CaptureSourceBackend, DisplayCaptureSourceOwner {
    weak var source: CaptureSource?
    private let identifier: UInt64
    private let processActivity = DisplayCaptureProcessActivity()
    private var frameSession: WebCore.CaptureVideoFrameSession?
    private var cropSession: WebCore.CaptureVideoFrameSession?
    private var whenReadyCompletion: (@MainActor (CaptureSourceFailure?) -> Void)?

#if HAVE_SCREEN_CAPTURE_KIT
    // A capture of the display, or the window if isWindow, with this ID.
    static func create(isWindow: Bool, deviceID: UInt32) -> DisplayCaptureBackend {
        DisplayCaptureBackend(identifier: makeDisplayCaptureSource { identifier in
            ScreenCaptureKitCapturer(identifier: identifier, isWindow: isWindow, deviceID: deviceID)
        })
    }
#endif

    static func createMock(_ display: WebCore.MockDisplayDescription) -> DisplayCaptureBackend {
        DisplayCaptureBackend(identifier: makeDisplayCaptureSource { _ in
            let capturer = MockDisplayCapturer(display: display)
            latestMockDisplayCapturer = capturer
            return capturer
        })
    }

    private init(identifier: UInt64) {
        self.identifier = identifier
        setDisplayCaptureSourceOwner(identifier, self)
    }

    isolated deinit {
        setDisplayCaptureSourceOwner(identifier, nil)
        displayCaptureSources.removeValue(forKey: identifier)?.invalidate()
        if let completion = whenReadyCompletion {
            whenReadyCompletion = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(CaptureSourceFailure(message: "Source no longer needed", denialReason: CaptureSourceFailure.invalidAccess))
                }
            }
        }
    }

    private var display: DisplaySource? {
        displayCaptureSources[identifier]
    }

    var isWindow: Bool {
        display?.isWindow ?? false
    }

    // MARK: CaptureSourceBackend

    var isDisplay: Bool {
        true
    }

    func startProducingData() {
        guard let source else {
            return
        }
        processActivity.start()
        let settings = settings()
        display?.startProducingData(frameRate: source.frameRate, width: settings.width, height: settings.height, settingsFrameRate: settings.frameRate)
    }

    func stopProducingData() {
        processActivity.stop()
        display?.stopProducingData()
    }

    func endProducingData() {
        display?.endProducingData()
    }

    func settingsDidChange(_ flags: CaptureSettingsFlags) {
        if flags.contains(.frameRate), let source {
            display?.setFrameRate(source.frameRate)
        }
    }

    func endApplyingConstraints() {
        let settings = settings()
        display?.commitConfiguration(width: settings.width, height: settings.height, frameRate: settings.frameRate)
    }

    func settings() -> CaptureSettings {
        guard let source, let display else {
            return CaptureSettings()
        }
        let size = source.size
        return CaptureSettings(display.settings(frameRate: source.frameRate, width: size.width, height: size.height), label: source.name, deviceId: source.hashedID)
    }

    func capabilities() -> CaptureCapabilities {
        guard let source, let display else {
            return CaptureCapabilities()
        }
        return CaptureCapabilities(display.capabilities(settingsSupportedConstraints: settings().supportedConstraints.rawValue), deviceId: source.hashedID)
    }

    func whenReady(_ completion: @escaping @MainActor (CaptureSourceFailure?) -> Void) {
        whenReadyCompletion = completion
        display?.whenReady()
    }

    // MARK: DisplayCaptureSourceOwner

    func displayDidChange(_ event: WebCore.DisplayCaptureSourceEvent) {
        switch event {
        case .CaptureFailed:
            source?.captureFailed()
        case .ConfigurationChanged:
            capturerConfigurationChanged()
        case .Ready:
            whenReadyCompletion.take()?(nil)
        @unknown default:
            break
        }
    }

    var displayIsMuted: Bool {
        source?.muted ?? true
    }

    // DisplayCaptureSourceCocoa::didEmitFrame().
    func displayDidEmitFrame(_ frame: DisplayFrame, sampleTime: Double, size: WebCore.DisplayCaptureSize) {
        guard let source else {
            return
        }
        let imageSize = WebCore.CaptureSourceSize(width: size.width, height: size.height)
        if source.intrinsicSize.width != imageSize.width || source.intrinsicSize.height != imageSize.height || source.size.width != imageSize.width || source.size.height != imageSize.height {
            source.setIntrinsicSize(imageSize)
            source.setSize(imageSize)
        }
        if frameSession == nil {
            frameSession = WebCore.CaptureVideoFrameSession.create(true)
        }
        let videoFrame: WebCore.VideoFrame?
        switch frame {
        case .sampleBuffer(let sampleBuffer):
            videoFrame = frameSession?.frameFromSampleBuffer(sampleBuffer, sampleTime, source.size)
        case .image(let image):
            videoFrame = frameSession?.frameFromImage(image, sampleTime, source.size, 0)
        }
        guard let videoFrame else {
            assertionFailure("DisplayCaptureBackend couldn't make a video frame")
            return
        }
        // MonotonicTime::now(), as DisplayCaptureSourceCocoa has it.
        source.videoFrameAvailable(CaptureFrame(videoFrame), captureTime: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
    }

    func displayCroppedFrame(_ frame: CMSampleBuffer, _ rect: WebCore.DisplayCaptureFloatRect, _ frameSize: WebCore.DisplayCaptureFloatSize) -> CMSampleBuffer? {
        let session = cropSession ?? WebCore.CaptureVideoFrameSession.create(true)
        cropSession = session
        return WebCore.captureCroppedSampleBuffer(session, frame, rect.x, rect.y, rect.width, rect.height, frameSize.width, frameSize.height)
    }

    // DisplayCaptureSourceCocoa::capturerConfigurationChanged().
    private func capturerConfigurationChanged() {
        guard let source, let display else {
            return
        }
        let intrinsicSize = display.intrinsicSize()
        let size = WebCore.CaptureSourceSize(width: intrinsicSize.width, height: intrinsicSize.height)
        if source.intrinsicSize.width != size.width || source.intrinsicSize.height != size.height {
            source.setIntrinsicSize(size)
        }
        source.configurationChanged()
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

    @cxx
    @implementation
    func settings(_ frameRate: Double, _ width: Int32, _ height: Int32) -> WebCore.CaptureSettingsValues {
        MainActor.assumeIsolated {
            source?.settings(frameRate: frameRate, width: width, height: height) ?? WebCore.CaptureSettingsValues()
        }
    }

    @cxx
    @implementation
    func capabilities(_ settingsSupportedConstraints: UInt32) -> WebCore.CaptureCapabilityValues {
        MainActor.assumeIsolated {
            source?.capabilities(settingsSupportedConstraints: settingsSupportedConstraints) ?? WebCore.CaptureCapabilityValues()
        }
    }
}

#endif
