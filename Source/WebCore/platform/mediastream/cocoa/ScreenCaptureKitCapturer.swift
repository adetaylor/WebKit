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


#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM && HAVE_SCREEN_CAPTURE_KIT

// The ScreenCaptureKit capturer of a screen or window DisplaySource: its SCStream, configuration and content, the
// stream's delegate and output, and what it does with each frame's attachments.
//
// WebCore soft-links ScreenCaptureKit and CoreMedia: their classes, constants and functions come from the generated
// accessors (platform/cocoa/SoftLinkAccessors.in). No ScreenCaptureKit class is named where Swift would need its class
// object, and only Objective-C methods are called, not the framework's Swift overlay.

import CoreGraphics
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import ScreenCaptureKit
import WebCore_Private.Core.DisplayCaptureSourceHandle
import WebCore_Private.Core.RealtimeVideoUtilities
import os

private let logger = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

private let defaultIntrinsicSize = WebCore.DisplayCaptureSize(width: 640, height: 480)

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

private func presentationSize(of sampleBuffer: CMSampleBuffer) -> WebCore.DisplayCaptureFloatSize {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        return WebCore.DisplayCaptureFloatSize()
    }
    let size = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, usePixelAspectRatio: true, useCleanAperture: true)
    return WebCore.DisplayCaptureFloatSize(width: Float(size.width), height: Float(size.height))
}

// Whether to crop a frame of `frameSize` (its presentation dimensions) to the content rect.
private func shouldCropFrame(_ contentRect: WebCore.DisplayCaptureFloatRect, _ frameSize: WebCore.DisplayCaptureFloatSize) -> Bool {
    if isEmpty(contentRect.width, contentRect.height) || isEmpty(frameSize.width, frameSize.height) {
        return false
    }
    return !areSizesRoughlyEqual(size(of: contentRect), frameSize)
}

// SCStreamConfiguration's colorSpaceName and colorMatrix are assign properties, which keep the string without retaining
// it. Both strings are CF constants, which live as long as the process.
private func setColorProperties(of configuration: SCStreamConfiguration) {
    unsafe configuration.colorSpaceName = CGColorSpace.sRGB
    // kCGDisplayStreamYCbCrMatrix_SMPTE_240M_1995, which CGDisplayStream.h gives the CoreVideo string's value.
    unsafe configuration.colorMatrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
}

// What a frame's attachments say, read in their order: the last scale factor, content scale and content rect, whether
// the presenter overlay disallows reconfiguration, and the first status (an SCFrameStatus, or a status it doesn't name).
private struct FrameAttachments {
    var scaleFactor: Double = 1
    var contentScale: Double = 1
    var contentRect = WebCore.DisplayCaptureFloatRect()
    var shouldDisallowReconfiguration = false
    var status: Int?
}

private func rect(from value: Any?) -> CGRect? {
    guard let dictionary = value as? NSDictionary else {
        return nil
    }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

private func frameAttachments(of sampleBuffer: CMSampleBuffer, isVideoEffectEnabled: Bool) -> FrameAttachments {
    var attachments = FrameAttachments()
    guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else {
        return attachments
    }
    for element in array as NSArray {
        guard let attachment = element as? NSDictionary else {
            continue
        }

        if let scaleFactor = attachment[ScreenCaptureKitSoftLink.SCStreamFrameInfoScaleFactor.rawValue] as? NSNumber {
            attachments.scaleFactor = Double(scaleFactor.floatValue)
        }

        if let contentScale = attachment[ScreenCaptureKitSoftLink.SCStreamFrameInfoContentScale.rawValue] as? NSNumber {
            attachments.contentScale = Double(contentScale.floatValue)
        }

        if let contentRect = rect(from: attachment[ScreenCaptureKitSoftLink.SCStreamFrameInfoContentRect.rawValue]) {
            attachments.contentRect = WebCore.DisplayCaptureFloatRect(x: Float(contentRect.origin.x), y: Float(contentRect.origin.y), width: Float(contentRect.size.width), height: Float(contentRect.size.height))
        }

        if isVideoEffectEnabled, let overlayRect = rect(from: attachment[ScreenCaptureKitSoftLink.SCStreamFrameInfoPresenterOverlayContentRect.rawValue]) {
            attachments.shouldDisallowReconfiguration = overlayRect.origin.x != 0 && overlayRect.origin.y != 0
        }

        if attachments.status == nil {
            guard let status = attachment[ScreenCaptureKitSoftLink.SCStreamFrameInfoStatus.rawValue] as? NSNumber else {
                continue
            }
            attachments.status = status.intValue
        }
    }
    return attachments
}

// The windows or displays of a content filter, or none if ScreenCaptureKit doesn't have the property.
private func includedWindows(of contentFilter: SCContentFilter) -> NSArray {
    ScreenCaptureKitMember.includedWindows(of: contentFilter)?.includedWindows ?? NSArray()
}

private func includedDisplays(of contentFilter: SCContentFilter) -> NSArray {
    ScreenCaptureKitMember.includedDisplays(of: contentFilter)?.includedDisplays ?? NSArray()
}

// MARK: Delegate

// A frame, for its trip from the stream's sample handler queue to the main thread: ScreenCaptureKit doesn't touch a
// sample buffer once it has delivered it, and the capturer only reads it.
private struct SampleBufferBox: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

// The stream's delegate and screen output. Every callback hops to the main thread, where the capturer is reached weakly.
private final class ScreenCaptureDelegate: NSObject, SCStreamDelegate, SCStreamOutput, Sendable {
    @MainActor weak var capturer: ScreenCaptureKitCapturer?

    private func performOnMainThread(_ work: @escaping @MainActor @Sendable (ScreenCaptureKitCapturer) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let capturer = self.capturer {
                    work(capturer)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        performOnMainThread { capturer in
            capturer.sessionFailed(error, "-[SCStreamDelegate stream:didStopWithError:] called")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        assert(type == .screen)

        let box = SampleBufferBox(sampleBuffer: sampleBuffer)
        performOnMainThread { capturer in
            capturer.streamDidOutputVideoSampleBuffer(box.sampleBuffer)
        }
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        performOnMainThread { capturer in
            capturer.isVideoEffectEnabled = true
        }
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        performOnMainThread { capturer in
            capturer.isVideoEffectEnabled = false
        }
    }
}

// MARK: Capturer

@MainActor
final class ScreenCaptureKitCapturer: DisplayCapturer, ScreenCaptureSessionSourceObserver {
    private enum Content {
        case window(SCWindow)
        case display(SCDisplay)
    }

    weak var source: DisplaySource?
    private let identifier: UInt64
    private(set) var isWindow: Bool
    private var deviceID: UInt32
    private var content: Content?
    private var delegate: ScreenCaptureDelegate?
    private var contentFilter: SCContentFilter?
    private var frame: CMSampleBuffer?
    private var sessionSource: ScreenCaptureSessionSource?
    private var configuration: SCStreamConfiguration?
    private var captureQueue: DispatchQueue?
    var isVideoEffectEnabled = false
    private var isWaitingForReady = false

    // The content size, the configuration asked for, and the intrinsic size.
    private var contentSize = WebCore.DisplayCaptureFloatSize()
    private var width: UInt32 = 0
    private var height: UInt32 = 0
    private var frameRate: Float = 0
    private var intrinsicSizeValue = WebCore.DisplayCaptureSize()
    private var hasIntrinsicSize = false
    private var isRunning = false
    private var didReceiveVideoFrame = false
    private var isPrewarming = false

    init(identifier: UInt64, isWindow: Bool, deviceID: UInt32) {
        self.identifier = identifier
        self.isWindow = isWindow
        self.deviceID = deviceID
    }

    private var manager: ScreenCaptureKitSharingSessionManager {
        ScreenCaptureKitSharingSessionManager.shared
    }

    private var contentStream: SCStream? {
        sessionSource?.stream
    }

    var currentFrame: DisplayFrame? {
        frame.map { DisplayFrame.sampleBuffer($0) }
    }

    func invalidate() {
        if sessionSource == nil {
            manager.cancelPendingSession(isWindow: isWindow, deviceID: deviceID)
        }
        setSessionSource(nil)
    }

    private func setSessionSource(_ newSource: ScreenCaptureSessionSource?) {
        let oldSource = sessionSource
        sessionSource = newSource
        if let oldSource, oldSource !== newSource {
            manager.sessionSourceDidEnd(oldSource)
        }
    }

    func whenReady() {
        if didReceiveVideoFrame {
            source?.capturerIsReady()
            return
        }
        isWaitingForReady = true
        if isRunning {
            return
        }
        // Start to get the first frame, whose size finalizes the source's settings.
        startInternal(isPrewarming: true)
    }

    func start() -> Bool {
        startInternal(isPrewarming: false)
        return isRunning
    }

    private func startInternal(isPrewarming: Bool) {
        assert(ScreenCaptureKitFrameworkIsAvailable)
        assert(!isWaitingForReady || !isRunning)

        logger.log("ScreenCaptureKitCaptureSource::startInternal")

        self.isPrewarming = isPrewarming
        if isRunning {
            return
        }
        isRunning = true
        startContentStream()
    }

    func stop() {
        logger.log("ScreenCaptureKitCaptureSource::stop")

        isRunning = false
        guard let contentStream else {
            return
        }

        contentStream.stopCapture { @Sendable [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        self?.sessionFailed(error, "-[SCStream stopCaptureWithCompletionHandler:] failed")
                    }
                }
            }
        }

        // Keep the session source, so the picker stays active: it helps capture in some fullscreen cases.
        if let sessionSource {
            contentFilter = sessionSource.contentFilter
        }
    }

    func end() {
        stop()
    }

    func sessionFailed(_ error: (any Error)?, _ message: StaticString) {
        if !isRunning {
            return
        }

        if let error {
            logger.error("ScreenCaptureKitCaptureSource::sessionFailedWithError \(message, privacy: .public) with error '\(error as NSError, privacy: .public)'")
        } else {
            logger.error("ScreenCaptureKitCaptureSource::sessionFailedWithError \(message, privacy: .public)")
        }

        source?.capturerFailed()
        setSessionSource(nil)
    }

    func sessionFilterDidChange(_ contentFilter: SCContentFilter) {
        logger.log("ScreenCaptureKitCaptureSource::sessionFilterDidChange")

        switch contentFilter.style {
        case .window:
            let windows = includedWindows(of: contentFilter)
            assert(windows.count == 1)
            guard windows.count > 0, let window = ScreenCaptureKitClass.cast(windows[0] as AnyObject, to: ScreenCaptureKitClass.SCWindow) else {
                return
            }
            isWindow = true
            deviceID = window.windowID
            content = .window(window)
        case .display:
            let displays = includedDisplays(of: contentFilter)
            assert(displays.count == 1)
            guard displays.count > 0, let display = ScreenCaptureKitClass.cast(displays[0] as AnyObject, to: ScreenCaptureKitClass.SCDisplay) else {
                return
            }
            isWindow = false
            deviceID = display.displayID
            content = .display(display)
        default:
            assertionFailure()
            return
        }

        hasIntrinsicSize = false
        if let contentStream {
            contentStream.updateContentFilter(contentFilter) { @Sendable [weak self] error in
                guard let error else {
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.sessionFailed(error, "-[SCStream updateContentFilter:completionHandler:] failed")
                    }
                }
            }
        }

        source?.capturerConfigurationChanged()
    }

    private func streamConfiguration() -> SCStreamConfiguration {
        if let configuration {
            return configuration
        }

        let configuration = ScreenCaptureKitClass.SCStreamConfiguration.init()
        configuration.pixelFormat = WebCore.preferedPixelBufferFormat()
        configuration.showsCursor = true
        configuration.queueDepth = 6
        setColorProperties(of: configuration)
        configuration.presenterOverlayPrivacyAlertSetting = .never

        if frameRate != 0 {
            configuration.minimumFrameInterval = CMTimeMakeWithSeconds(Double(1 / frameRate), preferredTimescale: 1000)
        }

        var width = self.width
        var height = self.height
        if width == 0 && height == 0 {
            width = UInt32(arm64Truncating: contentSize.width)
            height = UInt32(arm64Truncating: contentSize.height)
        } else if !isEmpty(contentSize.width, contentSize.height) {
            let aspectRatio = contentSize.width / contentSize.height
            if width == 0 {
                width = UInt32(arm64Truncating: Float(height) * aspectRatio)
            } else {
                height = UInt32(arm64Truncating: Float(width) / aspectRatio)
            }
        }
        if width != 0 && height != 0 {
            configuration.width = Int(width)
            configuration.height = Int(height)
        }

        self.configuration = configuration
        return configuration
    }

    // The content filter's content rect size and point pixel scale.
    private func setContentSize(width: Double, height: Double, pointPixelScale: Float) {
        var contentSize = WebCore.DisplayCaptureFloatSize(width: Float(width), height: Float(height))
        if isEmpty(contentSize.width, contentSize.height) {
            contentSize = WebCore.DisplayCaptureFloatSize(width: Float(defaultIntrinsicSize.width), height: Float(defaultIntrinsicSize.height))
        }
        if pointPixelScale != 0 {
            contentSize.width *= pointPixelScale
            contentSize.height *= pointPixelScale
        }
        self.contentSize = contentSize
    }

    private func startContentStream() {
        logger.log("ScreenCaptureKitCaptureSource::startContentStream")

        let delegate = self.delegate ?? ScreenCaptureDelegate()
        if self.delegate == nil {
            delegate.capturer = self
            self.delegate = delegate
        }

        if case .none = contentFilter {
            contentFilter = manager.takeContentFilter(isWindow: isWindow, deviceID: deviceID)
            let contentRect = contentFilter?.contentRect ?? .zero
            let pointPixelScale = contentFilter?.pointPixelScale ?? 0
            setContentSize(width: contentRect.size.width, height: contentRect.size.height, pointPixelScale: pointPixelScale)

            logger.log("ScreenCaptureKitCaptureSource::startContentStream contentFilter.contentRect = \(self.contentSize.width) x \(self.contentSize.height), contentFilter.pointPixelScale = \(pointPixelScale)")
        }

        guard let contentFilter else {
            sessionFailed(nil, "Unknown display device - no content filter")
            return
        }

        setSessionSource(manager.createSessionSource(observer: self, contentFilter: contentFilter, configuration: streamConfiguration(), delegate: delegate))
        guard let sessionSource else {
            sessionFailed(nil, "Failed to allocate stream")
            return
        }

        let filter = sessionSource.contentFilter
        switch filter.style {
        case .window:
            let windows = includedWindows(of: filter)
            assert(windows.count == 1)
            guard windows.count > 0, let window = ScreenCaptureKitClass.cast(windows[0] as AnyObject, to: ScreenCaptureKitClass.SCWindow) else {
                return
            }
            content = .window(window)
        case .display:
            let displays = includedDisplays(of: filter)
            assert(displays.count == 1)
            guard displays.count > 0, let display = ScreenCaptureKitClass.cast(displays[0] as AnyObject, to: ScreenCaptureKitClass.SCDisplay) else {
                return
            }
            content = .display(display)
        default:
            assertionFailure()
            return
        }

        let contentStream = sessionSource.stream
        do {
            try contentStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: queue())
        } catch {
            sessionFailed(error, "-[SCStream addStreamOutput:type:sampleHandlerQueue:error:] failed")
            return
        }

        contentStream.startCapture { @Sendable [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    if let error {
                        self.sessionFailed(error, "-[SCStream startCaptureWithCompletionHandler:] failed")
                        return
                    }
                    self.hasIntrinsicSize = false
                    self.source?.capturerConfigurationChanged()
                    logger.log("ScreenCaptureKitCaptureSource::startContentStream stream started")
                }
            }
        }

        isRunning = true
    }

    func intrinsicSize() -> WebCore.DisplayCaptureSize {
        if hasIntrinsicSize {
            return intrinsicSizeValue
        }
        guard let content else {
            return defaultIntrinsicSize
        }
        let frame = switch content {
        case .window(let window): window.frame
        case .display(let display): display.frame
        }
        intrinsicSizeValue = WebCore.DisplayCaptureSize(width: Int32(arm64Truncating: frame.size.width), height: Int32(arm64Truncating: frame.size.height))
        hasIntrinsicSize = true
        return intrinsicSizeValue
    }

    private func updateStreamConfiguration() {
        assert(sessionSource != nil)

        logger.log("ScreenCaptureKitCaptureSource::updateStreamConfiguration")

        let configuration = streamConfiguration()
        contentStream?.updateConfiguration(configuration) { @Sendable [weak self] error in
            guard let error else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sessionFailed(error, "-[SCStream updateConfiguration:completionHandler:] failed")
                }
            }
        }
    }

    func commitConfiguration(width: UInt32, height: UInt32, frameRate: Float) {
        if self.width == width && self.height == height && self.frameRate == frameRate {
            return
        }
        self.width = width
        self.height = height
        self.frameRate = frameRate

        logger.log("ScreenCaptureKitCaptureSource::commitConfiguration \(width) x \(height), \(frameRate)")

        if case .none = contentStream {
            return
        }

        configuration = nil
        updateStreamConfiguration()
    }

    func streamDidOutputVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let attachments = frameAttachments(of: sampleBuffer, isVideoEffectEnabled: isVideoEffectEnabled)

        if didReceiveVideoFrame && isPrewarming {
            logger.log("ScreenCaptureKitCaptureSource::streamDidOutputVideoSampleBuffer pre-warming, ignoring frame")
            return
        }
        if let status = attachments.status {
            switch status {
            case SCFrameStatus.idle.rawValue, SCFrameStatus.blank.rawValue, SCFrameStatus.suspended.rawValue, SCFrameStatus.stopped.rawValue:
                return
            default:
                break
            }
        }

        var contentRect = attachments.contentRect
        if attachments.scaleFactor != 1 {
            contentRect = scaled(contentRect, by: Float(attachments.scaleFactor))
        }
        var scaledContentRect = contentRect
        if attachments.contentScale != 0 && attachments.contentScale != 1 {
            scaledContentRect = scaled(scaledContentRect, by: Float(1 / attachments.contentScale))
        }
        var shouldUpdateStreamConfiguration = false
        if !attachments.shouldDisallowReconfiguration && !areSizesRoughlyEqual(contentSize, size(of: scaledContentRect)) {
            contentSize = size(of: scaledContentRect)
            shouldUpdateStreamConfiguration = true
        }

        var frame = sampleBuffer
        self.frame = frame

        // FIXME: for now we will rely on cropping to handle large presenter overlay.
        // We might further want to reduce calling updateStreamConfiguration once we crop when user is resizing.
        if shouldUpdateStreamConfiguration {
            logger.log("ScreenCaptureKitCaptureSource::streamDidOutputVideoSampleBuffer resetting m_contentSize to \(self.contentSize.width) x \(self.contentSize.height)")
            configuration = nil
            updateStreamConfiguration()
        }

        var frameSize = presentationSize(of: frame)
        if shouldCropFrame(contentRect, frameSize), let croppedFrame = WebCore.displayCaptureSourceCopyCroppedFrame(identifier, frame, contentRect, frameSize) {
            frame = croppedFrame
            self.frame = frame
            frameSize = presentationSize(of: frame)
        }

        let intrinsicSize = WebCore.DisplayCaptureSize(width: clampToInt32ForIntSize(frameSize.width), height: clampToInt32ForIntSize(frameSize.height))
        if !hasIntrinsicSize || intrinsicSizeValue.width != intrinsicSize.width || intrinsicSizeValue.height != intrinsicSize.height {
            intrinsicSizeValue = intrinsicSize
            hasIntrinsicSize = true
            logger.log("ScreenCaptureKitCaptureSource::streamDidOutputVideoSampleBuffer resetting m_intrinsicSize to \(intrinsicSize.width) x \(intrinsicSize.height)")
            source?.capturerConfigurationChanged()
        }

        let isFirstFrame = !didReceiveVideoFrame
        didReceiveVideoFrame = true
        if isFirstFrame && isWaitingForReady {
            isWaitingForReady = false
            source?.capturerIsReady()
        }
    }

    private func queue() -> DispatchQueue {
        if let captureQueue {
            return captureQueue
        }
        let captureQueue = DispatchQueue(label: "CGDisplayStreamCaptureSource Capture Queue", autoreleaseFrequency: .workItem)
        self.captureQueue = captureQueue
        return captureQueue
    }
}

#endif
