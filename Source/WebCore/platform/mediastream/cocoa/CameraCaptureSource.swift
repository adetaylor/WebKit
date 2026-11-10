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

// A camera: its AVCaptureSession, input, video and photo outputs, their delegates, and its state and decisions.
// AVVideoCaptureSource, a RealtimeMediaSource for callers in C++, holds one by identifier through
// CameraCaptureSourceHandle and gets its frames, photos and events through CameraCaptureSourceHandle.h's functions.
//
// WebCore soft-links AVFoundation and CoreMedia: their classes, constants and functions come from the generated
// accessors (platform/cocoa/SoftLinkAccessors.in). No AVFoundation class is named where Swift would need its class
// object: a cast goes through AVFoundationClass.cast(_:to:), and a typed collection through an NSArray re-declaration.

import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Synchronization
import WebCore_Private.Core.CameraCaptureSourceHandle
import WebCore_Private.Core.RealtimeVideoUtilities
import WebCore_Private.Core.WebCoreObjCExceptionCatching
import os
import pal.spi.cf.CoreVideoSPI
import pal.spi.cocoa.AVFoundationSPI

private let logger = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

private let verifyCaptureInterval: TimeInterval = 30
private let framesToDropWhenStarting: UInt64 = 4
private let photoCapturePipelineReadinessTimeout: TimeInterval = 60

// VideoFrameRotation.
private let rotationNone: UInt16 = 0
private let rotationUpsideDown: UInt16 = 180
private let rotationRight: UInt16 = 90
private let rotationLeft: UInt16 = 270

// MARK: Device types

// The camera device types, in the order that selects the preferred back camera.
private var cameraCaptureDeviceTypeList: [AVCaptureDevice.DeviceType] {
    [
        AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInTripleCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInDualWideCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInUltraWideCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInDualCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInTelephotoCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeDeskViewCamera,
        AVFoundationSoftLink.AVCaptureDeviceTypeExternalUnknown,
    ].compactMap { $0 }
}

private func cameraZoomScaleFactor(_ deviceType: AVCaptureDevice.DeviceType) -> Double {
#if os(iOS) || os(visionOS) || os(tvOS)
    let usesWideZoom = deviceType == AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInTripleCamera || deviceType == AVFoundationSoftLink.AVCaptureDeviceTypeBuiltInDualWideCamera
    return usesWideZoom ? 2.0 : 1.0
#else
    return 1.0
#endif
}

private func isExternalUnknown(_ deviceType: AVCaptureDevice.DeviceType) -> Bool {
    deviceType == AVFoundationSoftLink.AVCaptureDeviceTypeExternalUnknown
}

@MainActor
private var useRotationCoordinatorAPI = false

// MARK: Key-value observation

// The one string-key KVO registration of this file, with no context: Swift's typed KVO would name the observed class.
private func addKeyValueObserver(_ observer: NSObject, to object: NSObject, keyPath: Swift.String) {
    unsafe object.addObserver(observer, forKeyPath: keyPath, options: .new, context: nil)
}

private func removeKeyValueObserver(_ observer: NSObject, from object: NSObject, keyPath: Swift.String) {
    object.removeObserver(observer, forKeyPath: keyPath)
}

// MARK: State and decisions

// The source's state and what it does on each event, as plain values.
private struct CameraCaptureState {
    var currentFrameRate: Double = 0
    var currentZoom: Double = 1
    var zoomScaleFactor: Double = 1
    var beginConfigurationCount: UInt64 = 0
    var lastFramesCount: UInt64 = 0
    var sensorOrientation: Int32 = 0
    var deviceOrientation: Int32 = 0
    var videoFrameRotation: UInt16 = 0
    var useSensorAndDeviceOrientation = true
    var interrupted = false
    var isRunning = false
    var hasBegunConfigurationForConstraints = false
    var needsTorchReconfiguration = false
    var needsWhiteBalanceReconfiguration = false
    var shouldCallNotifyMutedChange = false

    // Returns whether the rotation of the frames changed.
    mutating func computeVideoFrameRotation(isFrontCamera: Bool) -> Bool {
        if !useSensorAndDeviceOrientation {
            return false
        }

        let rotation: UInt16
        switch sensorOrientation &- deviceOrientation {
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
        if rotation == videoFrameRotation {
            return false
        }

        videoFrameRotation = rotation
        return true
    }

    mutating func horizonLevelRotationDidChange(_ rotation: UInt16) -> Bool {
        useSensorAndDeviceOrientation = false
        if rotation == videoFrameRotation {
            return false
        }
        videoFrameRotation = rotation
        return true
    }

    // Each returns whether to begin or commit the session's configuration.
    mutating func beginConfiguration() -> Bool {
        beginConfigurationCount &+= 1
        return beginConfigurationCount <= 1
    }

    mutating func commitConfiguration() -> Bool {
        if beginConfigurationCount == 0 {
            return false
        }
        beginConfigurationCount -= 1
        return beginConfigurationCount == 0
    }

    mutating func startApplyingConstraints() {
        assert(!hasBegunConfigurationForConstraints)
        hasBegunConfigurationForConstraints = false
    }

    mutating func beginConfigurationForConstraintsIfNeeded() -> Bool {
        if hasBegunConfigurationForConstraints {
            return false
        }
        hasBegunConfigurationForConstraints = true
        return true
    }

    mutating func endApplyingConstraints() -> Bool {
        if !hasBegunConfigurationForConstraints {
            return false
        }
        hasBegunConfigurationForConstraints = false
        return true
    }

    // WTF's clampTo(double, double, double).
    mutating func clampFrameRate(minimum: Double, maximum: Double) -> Double {
        if currentFrameRate >= maximum {
            currentFrameRate = maximum
        } else if currentFrameRate <= minimum {
            currentFrameRate = minimum
        }
        return currentFrameRate
    }

    // The session's running state changed while the source is muted or not. Returns whether to act on it.
    mutating func runningDidChange(_ running: Bool, isMuted: Bool) -> Bool {
        if running == isRunning && running == !isMuted {
            return false
        }
        isRunning = running
        return true
    }

    enum VerifyCapturingTimerAction {
        case stop
        case keep
        case start
    }

    mutating func verifyCapturingTimerAction(isTimerActive: Bool) -> VerifyCapturingTimerAction {
        if !isRunning || interrupted {
            lastFramesCount = 0
            return .stop
        }
        if isTimerActive {
            return .keep
        }
        lastFramesCount = 0
        return .start
    }

    // Returns whether no frame arrived since the last check.
    mutating func hasStoppedCapturing(framesCount: UInt64) -> Bool {
        if lastFramesCount != framesCount {
            lastFramesCount = framesCount
            return false
        }
        return true
    }

    // Each returns whether to wait until the session runs.
    mutating func deferWhiteBalanceModeUpdate() -> Bool {
        if isRunning {
            return false
        }
        needsWhiteBalanceReconfiguration = true
        return true
    }

    mutating func deferTorchUpdate() -> Bool {
        if isRunning {
            return false
        }
        needsTorchReconfiguration = true
        return true
    }

    struct Reconfiguration {
        var torch = false
        var whiteBalanceMode = false
    }

    // The deferred changes to apply now that the session runs.
    mutating func takeReconfiguration() -> Reconfiguration? {
        if !isRunning || (!needsTorchReconfiguration && !needsWhiteBalanceReconfiguration) {
            return nil
        }
        let reconfiguration = Reconfiguration(torch: needsTorchReconfiguration, whiteBalanceMode: needsWhiteBalanceReconfiguration)
        needsTorchReconfiguration = false
        needsWhiteBalanceReconfiguration = false
        return reconfiguration
    }
}

// MARK: Value conversions

private func avWhiteBalanceMode(for mode: WebCore.MeteringMode) -> AVCaptureDevice.WhiteBalanceMode {
    switch mode {
    case .Manual:
        return .locked
    case .SingleShot, .None:
        return .autoWhiteBalance
    case .Continuous:
        return .continuousAutoWhiteBalance
    @unknown default:
        return .autoWhiteBalance
    }
}

private func meteringMode(for mode: AVCaptureDevice.WhiteBalanceMode) -> WebCore.MeteringMode {
    switch mode {
    case .locked:
        return .Manual
    case .autoWhiteBalance:
        return .SingleShot
    case .continuousAutoWhiteBalance:
        return .Continuous
    @unknown default:
        return .None
    }
}

// FillLightMode.
private let fillLightModeAuto: UInt8 = 0
private let fillLightModeOff: UInt8 = 1
private let fillLightModeFlash: UInt8 = 2

private func webFillLightMode(for mode: AVCaptureDevice.TorchMode) -> UInt8 {
    switch mode {
    case .off:
        return fillLightModeOff
    case .on:
        return fillLightModeFlash
    case .auto:
        return fillLightModeAuto
    @unknown default:
        assertionFailure("an unknown torch mode")
        return fillLightModeAuto
    }
}

#if os(iOS) || os(visionOS) || os(tvOS)
private func flashMode(for mode: UInt8) -> AVCaptureDevice.FlashMode {
    switch mode {
    case fillLightModeOff:
        return .off
    case fillLightModeFlash:
        return .on
    default:
        return .auto
    }
}
#endif

// AVCaptureVideoOrientation, which is deprecated: the connection's videoOrientation is read by key.
private let videoOrientationPortrait = 1
private let videoOrientationPortraitUpsideDown = 2
private let videoOrientationLandscapeRight = 3
private let videoOrientationLandscapeLeft = 4

private func sensorOrientation(forVideoOrientation videoOrientation: Int) -> Int32 {
#if os(macOS)
    switch videoOrientation {
    case videoOrientationPortrait:
        return 0
    case videoOrientationPortraitUpsideDown:
        return 180
    case videoOrientationLandscapeRight:
        return 90
    case videoOrientationLandscapeLeft:
        return -90
    default:
        return 0
    }
#else
    switch videoOrientation {
    case videoOrientationPortrait:
        return 180
    case videoOrientationPortraitUpsideDown:
        return 0
    case videoOrientationLandscapeRight:
        return 90
    case videoOrientationLandscapeLeft:
        return -90
    default:
        return 0
    }
#endif
}

// WTF's clampTo<int>(float), as roundedIntSize() uses it: NaN gives INT_MIN.
private func clampToInt32ForIntSize(_ value: Float) -> Int32 {
    if value >= Float(Int32.max) {
        return .max
    }
    if !(value > Float(Int32.min)) {
        return .min
    }
    return Int32(value)
}

private func isFormatPowerEfficient(_ format: AVCaptureDevice.Format) -> Bool {
#if os(iOS) || os(visionOS) || os(tvOS)
    return format.isVideoBinned
#else
    return false
#endif
}

// RealtimeVideoCaptureSource::frameRateRangeIncludesRate().
private func frameRateRangeIncludesRate(minimum: Double, maximum: Double, _ frameRate: Double) -> Bool {
    let epsilon = 0.001
    return frameRate + epsilon >= minimum && frameRate - epsilon <= maximum
}

// CMTimeMake(1, frameRate): the frame rate converts to the timescale as arm64 converts a double to an int32_t.
private func frameDuration(forFrameRate frameRate: Double) -> CMTime {
    CMTimeMake(value: 1, timescale: Int32(arm64Truncating: frameRate))
}

private func isFrameRateMatching(_ frameRate: Double, minFrameDuration: CMTime, maxFrameDuration: CMTime) -> Bool {
    if !minFrameDuration.flags.contains(.valid) || !maxFrameDuration.flags.contains(.valid) {
        return false
    }
    let duration = frameDuration(forFrameRate: frameRate)
    return CMTimeCompare(duration, minFrameDuration) >= 0 && CMTimeCompare(duration, maxFrameDuration) <= 0
}

private func photoDimensions(_ value: NSValue) -> CMVideoDimensions {
    value.videoDimensionsValue
}

// The smallest of the format's maximum photo dimensions that holds the requested size, or the first.
private func maxPhotoSize(for format: AVCaptureDevice.Format, requested: (width: Int32, height: Int32)) -> (width: Int32, height: Int32) {
    let maxPhotoDimensions = format.__supportedMaxPhotoDimensions
    guard let first = maxPhotoDimensions.first else {
        return (0, 0)
    }
    var best = photoDimensions(first)
    for value in maxPhotoDimensions {
        let dimensions = photoDimensions(value)
        if dimensions.width >= requested.width && dimensions.height >= requested.height {
            if dimensions.width &* dimensions.height < best.width &* best.height {
                best = dimensions
            }
        }
    }
    return (best.width, best.height)
}

// MARK: Delegate

// The video output's sample buffer delegate, the photo output's capture delegate, the readiness coordinator's delegate,
// and the target of the source's key-value observations and notifications. Frames are delivered on the capture queue,
// with no hop to the main thread, as AVVideoCaptureSource did; everything else hops to the main thread. The source is
// reached weakly, and only on the main thread.
private final class CameraCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, Sendable {
    let identifier: UInt64
    let framesCount = Atomic<UInt64>(0)
    let videoFrameRotation = Atomic<UInt16>(0)
    @MainActor weak var source: CameraCaptureSource?

    init(identifier: UInt64) {
        self.identifier = identifier
    }

    // Runs the work on the main thread: now if this is the main thread, as WTF's ensureOnMainRunLoop() does.
    private func performOnMainThread(_ work: @escaping @MainActor @Sendable (CameraCaptureSource) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let source = self.source {
                    work(source)
                }
            }
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let source = self.source {
                    work(source)
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if framesCount.add(1, ordering: .relaxed).newValue <= framesToDropWhenStarting {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        var presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        if !presentationTime.flags.contains(.valid) {
            presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
        WebCore.cameraCaptureSourceDidCaptureFrame(identifier, pixelBuffer, presentationTime, videoFrameRotation.load(ordering: .relaxed), connection.isVideoMirrored)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .PhotoOutputFailed)
            let code = (error as NSError).code
            let description = error.localizedDescription
            DispatchQueue.main.async {
                logger.error("AVVideoCaptureSource photo capture failed: \(code), \(description, privacy: .public)")
            }
            return
        }

        let data = photo.fileDataRepresentation() ?? Data()
        WebCore.cameraCaptureSourceDidCapturePhoto(identifier, data)
    }

    override func observeValue(forKeyPath keyPath: Swift.String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath else {
            return
        }
        let newValue = (change?[.newKey] as? NSNumber)?.boolValue ?? false
        let willChange = (change?[.notificationIsPriorKey] as? NSNumber)?.boolValue ?? false
        performOnMainThread { source in
            if willChange {
                return
            }
            switch keyPath {
            case "running":
                source.captureSessionIsRunningDidChange(newValue)
            case "suspended":
                source.captureDeviceSuspendedDidChange()
            case "portraitEffectActive":
                source.portraitEffectDidChange()
            default:
                break
            }
        }
    }

    @objc func deviceConnectedDidChange(_ notification: Notification) {
        let object = notification.object as AnyObject?
        let box = ObjectBox(object)
        performOnMainThread { source in
            source.deviceDisconnected(box.object)
        }
    }

#if os(iOS) || os(visionOS) || os(tvOS)
    @objc func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVFoundationSoftLink.AVCaptureSessionErrorKey] as? NSError
        let code = error?.code ?? 0
        performOnMainThread { source in
            source.captureSessionRuntimeError(code: code)
        }
    }

    @objc func beginSessionInterrupted(_ notification: Notification) {
        performOnMainThread { source in
            source.captureSessionBeginInterruption()
        }
    }

    @objc func endSessionInterrupted(_ notification: Notification) {
        performOnMainThread { source in
            source.captureSessionEndInterruption()
        }
    }
#endif
}

#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
extension CameraCaptureDelegate: AVCapturePhotoOutputReadinessCoordinatorDelegate {
    func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator, captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness) {
        performOnMainThread { source in
            source.captureReadinessDidChange()
        }
    }
}
#endif

// An object for its trip to the main thread, where only the main thread uses it: a notification's object (a device,
// which is only compared with the source's own), or RealtimeMediaSourceCenter's identity, which the C++ only passed
// on and the session only reads.
private struct ObjectBox: @unchecked Sendable {
    let object: AnyObject?

    init(_ object: AnyObject?) {
        self.object = object
    }
}

// MARK: Source

@MainActor
private var cameraCaptureSources: [UInt64: CameraCaptureSource] = [:]

@MainActor
private var lastCameraCaptureSourceIdentifier: UInt64 = 0

@MainActor
private final class CameraCaptureSource {
    let identifier: UInt64
    let device: AVCaptureDevice
    private let delegate: CameraCaptureDelegate
    private let captureQueue: DispatchQueue
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
    private var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var pendingPhotoSettings: AVCapturePhotoSettings?
    private var pendingCaptureWatchdog: DispatchWorkItem?
#endif
    private var state = CameraCaptureState()
    private var defaultTorchMode: AVCaptureDevice.TorchMode
    private var torch = false
    private var whiteBalanceMode = WebCore.MeteringMode.None
    private var isTorchChangePending = false
    private var isWhiteBalanceModeChangePending = false
    // The presets' formats, in the order of the presets AVVideoCaptureSource made from them.
    private var presetFormats: [AnyObject] = []
    private var presetFrameRateRanges: [[(minimum: Double, maximum: Double)]] = []
    private var currentFormat: AnyObject?
    private var appliedFormat: AnyObject?
    private var verifyCapturingTimer: (any DispatchSourceTimer)?
#if os(iOS) || os(visionOS) || os(tvOS)
    private var startupTimer: DispatchWorkItem?
#endif
    var mediaEnvironment: Swift.String?
#if ENABLE_APP_PRIVACY_REPORT
    var assumedIdentity: tcc_identity_t?
#endif

    init(identifier: UInt64, device: AVCaptureDevice) {
        self.identifier = identifier
        self.device = device
        self.delegate = CameraCaptureDelegate(identifier: identifier)
        self.captureQueue = CameraCaptureSource.videoCaptureQueue
        self.defaultTorchMode = device.torchMode
        state.zoomScaleFactor = cameraZoomScaleFactor(device.deviceType)
        delegate.source = self
        addKeyValueObserver(delegate, to: device, keyPath: "suspended")
        addKeyValueObserver(delegate, to: device, keyPath: "portraitEffectActive")
    }

    func invalidate() {
        verifyCapturingTimer?.cancel()
        verifyCapturingTimer = nil
#if os(iOS) || os(visionOS) || os(tvOS)
        startupTimer?.cancel()
        startupTimer = nil
#endif
#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
        pendingCaptureWatchdog?.cancel()
#endif
        removeNotificationObservers()
        removeKeyValueObserver(delegate, from: device, keyPath: "suspended")
        removeKeyValueObserver(delegate, from: device, keyPath: "portraitEffectActive")
        delegate.source = nil

        if case .none = session {
            return
        }

        stopSession()
        clearSession()
    }

    // The serial "WebCoreAVVideoCaptureSource video capture queue", which targets the high-priority global queue and
    // drains an autorelease pool per item.
    static let videoCaptureQueue = DispatchQueue(label: "WebCoreAVVideoCaptureSource video capture queue", autoreleaseFrequency: .workItem, target: DispatchQueue.global(qos: .userInteractive))

    static let photoQueue = DispatchQueue(label: "WebKit::AVPhotoCapture Queue")

    private func event(_ event: WebCore.CameraCaptureSourceEvent, _ value: Bool = false) {
        WebCore.cameraCaptureSourceDidChange(identifier, event, value)
    }

    private func setVideoFrameRotation() {
        delegate.videoFrameRotation.store(state.videoFrameRotation, ordering: .relaxed)
    }

    private var isFrontCamera: Bool {
        device.position == .front
    }

    // MARK: Capture verification

    private func verifyIsCapturing() {
        assert(state.isRunning)

        if !state.hasStoppedCapturing(framesCount: delegate.framesCount.load(ordering: .relaxed)) {
            return
        }

        logger.error("AVVideoCaptureSource::verifyIsCapturing - no frame received in \(Int(verifyCaptureInterval)) seconds, failing")
        event(.CaptureFailed)
    }

    private func updateVerifyCapturingTimer() {
        switch state.verifyCapturingTimerAction(isTimerActive: verifyCapturingTimer != nil) {
        case .stop:
            verifyCapturingTimer?.cancel()
            verifyCapturingTimer = nil
            delegate.framesCount.store(0, ordering: .relaxed)
        case .keep:
            break
        case .start:
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.verifyIsCapturing()
                }
            }
            timer.schedule(deadline: .now() + verifyCaptureInterval, repeating: verifyCaptureInterval)
            timer.resume()
            verifyCapturingTimer = timer
            delegate.framesCount.store(0, ordering: .relaxed)
        }
    }

#if os(iOS) || os(visionOS) || os(tvOS)
    private func startupTimerFired() {
        startupTimer = nil
        let shouldNotify = state.shouldCallNotifyMutedChange
        state.shouldCallNotifyMutedChange = false
        if shouldNotify {
            event(.MutedChanged, !state.isRunning)
        }
    }
#endif

    // MARK: Session

    private func clearSession() {
        logger.log("AVVideoCaptureSource::clearSession")
        guard let session else {
            assertionFailure("no session")
            return
        }
        removeKeyValueObserver(delegate, from: session, keyPath: "running")
        self.session = nil
        photoOutput = nil
#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
        readinessCoordinator = nil
        if case .some = pendingPhotoSettings {
            pendingPhotoSettings = nil
            pendingCaptureWatchdog?.cancel()
            pendingCaptureWatchdog = nil
            WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .SessionCleared)
        }
#endif
    }

    private func addNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(delegate, selector: #selector(CameraCaptureDelegate.deviceConnectedDidChange(_:)), name: AVFoundationSoftLink.AVCaptureDeviceWasDisconnectedNotification, object: nil)
#if os(iOS) || os(visionOS) || os(tvOS)
        center.addObserver(delegate, selector: #selector(CameraCaptureDelegate.sessionRuntimeError(_:)), name: AVFoundationSoftLink.AVCaptureSessionRuntimeErrorNotification, object: session)
        center.addObserver(delegate, selector: #selector(CameraCaptureDelegate.beginSessionInterrupted(_:)), name: AVFoundationSoftLink.AVCaptureSessionWasInterruptedNotification, object: session)
        center.addObserver(delegate, selector: #selector(CameraCaptureDelegate.endSessionInterrupted(_:)), name: AVFoundationSoftLink.AVCaptureSessionInterruptionEndedNotification, object: session)
#endif
    }

    private func removeNotificationObservers() {
        let center: NotificationCenter = .default
        center.removeObserver(delegate)
    }

    func startProducingData() {
        if case .none = session, !setupSession() {
            return
        }
        guard let session else {
            return
        }

        let isRunning = session.isRunning
        logger.log("AVVideoCaptureSource::startProducingData \(isRunning)")
        if isRunning {
            return
        }

        addNotificationObservers()
        session.startRunning()

#if os(iOS) || os(visionOS) || os(tvOS)
        state.shouldCallNotifyMutedChange = false

        startupTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.startupTimerFired()
            }
        }
        startupTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timer)
#endif
    }

    func stopProducingData() {
        guard let session else {
            return
        }

        logger.log("AVVideoCaptureSource::stopProducingData \(session.isRunning)")
        removeNotificationObservers()
        stopSession()

        state.interrupted = false

#if os(iOS) || os(visionOS) || os(tvOS)
        clearSession()
#endif
    }

    private func stopSession() {
        assert(state.beginConfigurationCount == 0)

        if let session, let exception = WebCoreCatchingObjCException({ session.stopRunning() }) {
            logger.error("AVVideoCaptureSource error calling -stopRunning \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
        }

        WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .TrackStopped)
    }

    func startApplyingConstraints() {
        state.startApplyingConstraints()
    }

    func endApplyingConstraints() {
        if state.endApplyingConstraints() {
            commitConfiguration()
        }
    }

    private func beginConfigurationForConstraintsIfNeeded() {
        if state.beginConfigurationForConstraintsIfNeeded() {
            beginConfiguration()
        }
    }

    private func beginConfiguration() {
        if !state.beginConfiguration() {
            return
        }

        session?.beginConfiguration()
    }

    private func commitConfiguration() {
        assert(state.beginConfigurationCount != 0)
        if !state.commitConfiguration() {
            return
        }

        guard let session else {
            return
        }

        if let exception = WebCoreCatchingObjCException({ session.commitConfiguration() }) {
            logger.error("AVVideoCaptureSource error calling -commitConfiguration \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
        }
    }

    func settingsDidChange(whiteBalanceModeChanged: Bool, torchChanged: Bool) {
        if !whiteBalanceModeChanged && !torchChanged {
            return
        }

        isWhiteBalanceModeChangePending = whiteBalanceModeChanged
        isTorchChangePending = torchChanged
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                startApplyingConstraints()
                if whiteBalanceModeChanged {
                    updateWhiteBalanceMode()
                }
                if torchChanged {
                    updateTorch()
                }
                endApplyingConstraints()
                isWhiteBalanceModeChangePending = false
                isTorchChangePending = false
            }
        }
    }

    func setTorchAndWhiteBalanceMode(torch: Bool, whiteBalanceMode: WebCore.MeteringMode) {
        self.torch = torch
        self.whiteBalanceMode = whiteBalanceMode
    }

    func portraitEffectDidChange() {
        event(.ConfigurationChanged)
    }

    // MARK: Frame rate and zoom

    // Returns whether the preset changed, rather than the zoom only or nothing.
    func applyFrameRateAndZoom(frameRate requestedFrameRate: Double, zoom: Double, presetIndex: Int32) -> Bool {
        let requestedZoom = zoom * state.zoomScaleFactor
        let format: AnyObject? = presetIndex >= 0 && Int(presetIndex) < presetFormats.count ? presetFormats[Int(presetIndex)] : nil
        let isSamePreset = format != nil && currentFormat != nil && format === currentFormat
        let isSamePresetAndFrameRate = state.currentFrameRate == requestedFrameRate && isSamePreset
        if isSamePresetAndFrameRate && state.currentZoom == requestedZoom {
            return false
        }

        if isSamePresetAndFrameRate {
            logger.log("AVVideoCaptureSource::applyFrameRateAndZoomWithPreset, applying zoom only")
            if !lockForConfiguration() {
                return false
            }

            let device = self.device
            if let exception = WebCoreCatchingObjCException({ device.videoZoomFactor = requestedZoom }) {
                logger.error("AVVideoCaptureSource error applying zoom \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
            } else {
                state.currentZoom = requestedZoom
            }

            device.unlockForConfiguration()
            return false
        }

        beginConfigurationForConstraintsIfNeeded()

        currentFormat = format

        state.currentFrameRate = requestedFrameRate
        state.currentZoom = requestedZoom

        setSessionSizeFrameRateAndZoom()

#if os(iOS) || os(visionOS) || os(tvOS)
        // Updating the device configuration may switch off the torch. We reenable torch asynchronously if needed.
        if torch {
            isTorchChangePending = true
            isWhiteBalanceModeChangePending = false
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    startApplyingConstraints()
                    updateTorch()
                    endApplyingConstraints()
                    isTorchChangePending = false
                    isWhiteBalanceModeChangePending = false
                }
            }
        }
#endif
        return true
    }

    private func areSettingsMatching() -> Bool {
        guard let appliedFormat, appliedFormat === currentFormat else {
            return false
        }
#if os(iOS) || os(visionOS) || os(tvOS)
        if device.videoZoomFactor != state.currentZoom {
            return false
        }
#endif
        return isFrameRateMatching(state.currentFrameRate, minFrameDuration: device.activeVideoMinFrameDuration, maxFrameDuration: device.activeVideoMaxFrameDuration)
    }

    // The supported range of the active format that includes the frame rate, with the longest minimum frame duration.
    private func frameRateRange(forFrameRate rate: Double) -> AVFrameRateRange? {
        var best: AVFrameRateRange?
        guard let ranges = AVFoundationMember.videoSupportedFrameRateRanges(of: device.activeFormat)?.videoSupportedFrameRateRanges else {
            return nil
        }
        for element in ranges {
            guard let range = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVFrameRateRange) else {
                continue
            }
            if frameRateRangeIncludesRate(minimum: range.minFrameRate, maximum: range.maxFrameRate, rate) {
                guard let current = best else {
                    best = range
                    continue
                }
                if CMTimeCompare(range.minFrameDuration, current.minFrameDuration) > 0 {
                    best = range
                }
            }
        }

        if case .none = best {
            logger.error("AVVideoCaptureSource no frame rate range for rate \(rate)")
        }

        return best
    }

    private func setSessionSizeFrameRateAndZoom() {
        assert(state.beginConfigurationCount != 0)
        guard case .some = session else {
            return
        }

        guard let currentFormat, let format = AVFoundationClass.cast(currentFormat, to: AVFoundationClass.AVCaptureDeviceFormat) else {
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
#if os(iOS) || os(visionOS) || os(tvOS)
        logger.log("AVVideoCaptureSource::setSessionSizeFrameRateAndZoom \(dimensions.width) x \(dimensions.height), \(self.state.currentFrameRate), \(self.state.currentZoom) binned: \(format.isVideoBinned)")
#else
        logger.log("AVVideoCaptureSource::setSessionSizeFrameRateAndZoom \(dimensions.width) x \(dimensions.height), \(self.state.currentFrameRate), \(self.state.currentZoom)")
#endif

        if areSettingsMatching() {
            logger.log("AVVideoCaptureSource::setSessionSizeFrameRateAndZoom settings already match")
            return
        }

        if !lockForConfiguration() {
            return
        }

        beginConfiguration()
        let device = self.device
        let exception = WebCoreCatchingObjCException {
            MainActor.assumeIsolated {
                device.activeFormat = format

#if os(macOS)
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let settings: [Swift.String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as Swift.String: NSNumber(value: WebCore.preferedPixelBufferFormat()),
                    kCVPixelBufferWidthKey as Swift.String: NSNumber(value: dimensions.width),
                    kCVPixelBufferHeightKey as Swift.String: NSNumber(value: dimensions.height),
                    kCVPixelBufferIOSurfacePropertiesKey as Swift.String: [Swift.String: Any](),
                ]
                self.videoOutput?.videoSettings = settings
#endif

                if let frameRateRange = self.frameRateRange(forFrameRate: self.state.currentFrameRate) {
                    let frameRate = self.state.clampFrameRate(minimum: frameRateRange.minFrameRate, maximum: frameRateRange.maxFrameRate)

                    var duration = frameDuration(forFrameRate: frameRate)
                    if CMTimeCompare(duration, frameRateRange.minFrameDuration) < 0 {
                        duration = frameRateRange.minFrameDuration
                    } else if CMTimeCompare(duration, frameRateRange.maxFrameDuration) > 0 {
                        duration = frameRateRange.maxFrameDuration
                    }

                    logger.log("AVVideoCaptureSource::setSessionSizeFrameRateAndZoom setting frame rate to \(frameRate), duration \(duration.value)/\(duration.timescale)")

#if os(macOS)
                    if let connection = self.videoOutput?.connection(with: AVFoundationSoftLink.AVMediaTypeVideo) {
                        if connection.isVideoMinFrameDurationSupported {
                            connection.videoMinFrameDuration = duration
                        }
                        if connection.isVideoMaxFrameDurationSupported {
                            connection.videoMaxFrameDuration = duration
                        }
                    }
#else
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
#endif
                } else {
                    logger.error("AVVideoCaptureSource cannot find proper frame rate range for the selected preset")
                }

#if os(iOS) || os(visionOS) || os(tvOS)
                if self.state.currentZoom != device.videoZoomFactor {
                    logger.log("AVVideoCaptureSource::setSessionSizeFrameRateAndZoom setting zoom to \(self.state.currentZoom)")
                    device.videoZoomFactor = self.state.currentZoom
                }
#endif

                self.appliedFormat = self.currentFormat
            }
        }
        if let exception {
            logger.error("AVVideoCaptureSource error configuring device \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
            assertionFailure("an exception configuring the device")
        }

        device.unlockForConfiguration()
        commitConfiguration()
    }

    private func lockForConfiguration() -> Bool {
        do {
            try device.lockForConfiguration()
            return true
        } catch {
            logger.error("AVVideoCaptureSource error locking configuration \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Torch and white balance

    private func updateWhiteBalanceMode() {
        if state.deferWhiteBalanceModeUpdate() {
            return
        }

        beginConfigurationForConstraintsIfNeeded()

        if !lockForConfiguration() {
            return
        }

        let device = self.device
        let mode = avWhiteBalanceMode(for: whiteBalanceMode)
        if let exception = WebCoreCatchingObjCException({ device.whiteBalanceMode = mode }) {
            logger.error("AVVideoCaptureSource error setting white balance mode \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
        }

        device.unlockForConfiguration()
        event(.SettingsChanged)
    }

    private func updateTorch() {
        if state.deferTorchUpdate() {
            return
        }

        beginConfigurationForConstraintsIfNeeded()

        if !lockForConfiguration() {
            return
        }

        let device = self.device
        let torch = self.torch
        let defaultTorchMode = self.defaultTorchMode
        let exception = WebCoreCatchingObjCException {
            if torch {
                do {
                    try device.setTorchModeOn(level: AVFoundationSoftLink.AVCaptureMaxAvailableTorchLevel)
                } catch {
                    logger.error("AVVideoCaptureSource error turning on torch \(error.localizedDescription, privacy: .public)")
                }
            } else {
                device.torchMode = defaultTorchMode
            }
        }
        if let exception {
            logger.error("AVVideoCaptureSource error turning on torch \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
        }

        device.unlockForConfiguration()
        event(.SettingsChanged)
    }

    private func reconfigureIfNeeded() {
        guard let reconfiguration = state.takeReconfiguration() else {
            return
        }

        startApplyingConstraints()

        if reconfiguration.torch {
            updateTorch()
        }

        if reconfiguration.whiteBalanceMode {
            updateWhiteBalanceMode()
        }

        endApplyingConstraints()
    }

    // MARK: Orientation

    private func sensorOrientationFromVideoOutput() -> Int32 {
        if isExternalUnknown(device.deviceType) {
            return 0
        }

        guard let connection = videoOutput?.connection(with: AVFoundationSoftLink.AVMediaTypeVideo) else {
            return 0
        }
        return sensorOrientation(forVideoOrientation: (connection.value(forKey: "videoOrientation") as? NSNumber)?.intValue ?? 0)
    }

    private func computeVideoFrameRotation() {
        if !state.computeVideoFrameRotation(isFrontCamera: isFrontCamera) {
            return
        }

        setVideoFrameRotation()
        event(.VideoFrameRotationChanged)
    }

    func monitorOrientation(_ orientation: Int32) {
#if os(iOS) || os(visionOS) || os(tvOS)
        if isExternalUnknown(device.deviceType) {
            state.useSensorAndDeviceOrientation = false
        }
#endif
        orientationChanged(orientation)
    }

    func orientationChanged(_ orientation: Int32) {
        assert(orientation == 0 || orientation == 90 || orientation == -90 || orientation == 180)
        state.deviceOrientation = orientation
        computeVideoFrameRotation()
    }

    func rotationAngleForHorizonLevelDisplayChanged(_ rotation: UInt16) {
        if !state.horizonLevelRotationDidChange(rotation) {
            return
        }

        setVideoFrameRotation()
        event(.VideoFrameRotationChanged)
    }

    var videoFrameRotation: UInt16 {
        state.videoFrameRotation
    }

    // MARK: Session setup

    private func setupSession() -> Bool {
        if case .some = session {
            return true
        }

        logger.log("AVVideoCaptureSource::setupSession")

        var newSession: AVCaptureSession?
#if ENABLE_EXTENSION_CAPABILITIES
        if let mediaEnvironment, !mediaEnvironment.isEmpty, AVFoundationClass.AVCaptureSession.instancesRespond(to: NSSelectorFromString("initWithMediaEnvironment:")) {
            newSession = AVFoundationClass.AVCaptureSession.init(mediaEnvironment: mediaEnvironment)
        }
#endif

#if ENABLE_APP_PRIVACY_REPORT
        if case .none = newSession {
            if case .none = assumedIdentity {
                logger.error("AVVideoCaptureSource RealtimeMediaSourceCenter::identity() returned null!")
            }
            if let assumedIdentity, AVFoundationClass.AVCaptureSession.instancesRespond(to: NSSelectorFromString("initWithAssumedIdentity:")) {
                newSession = AVFoundationClass.AVCaptureSession.init(assumedIdentity: assumedIdentity)
            }
        }
#endif

        if case .none = newSession {
#if ENABLE_EXTENSION_CAPABILITIES
            logger.error("AVVideoCaptureSource allocating AVCaptureSession without media environment nor identity")
#endif
            newSession = AVFoundationClass.AVCaptureSession.init()
        }

        guard let session = newSession else {
            logger.error("AVVideoCaptureSource failed to allocate AVCaptureSession")
            event(.CaptureFailed)
            return false
        }
        self.session = session

#if os(tvOS)
        session.isMultitaskingCameraAccessEnabled = true
#elseif os(iOS) || os(visionOS)
        WebCore.cameraCaptureSessionAuthorizeMultipleForegroundAppLayout(session)
#endif
        addKeyValueObserver(delegate, to: session, keyPath: "running")

        let success = setupCaptureSession()
        if !success {
            event(.CaptureFailed)
        }

        return success
    }

    private func setupCaptureSession() -> Bool {
        beginConfiguration()
        defer {
            commitConfiguration()
        }

        guard let session else {
            return false
        }

        let videoIn: AVCaptureDeviceInput
        do {
            videoIn = try AVFoundationClass.AVCaptureDeviceInput.init(device: device)
        } catch {
            logger.error("AVVideoCaptureSource failed to allocate AVCaptureDeviceInput \(error.localizedDescription, privacy: .public)")
            return false
        }

        if !session.canAddInput(videoIn) {
            logger.error("AVVideoCaptureSource unable to add video input device")
            return false
        }
        session.addInput(videoIn)

        let videoOutput = AVFoundationClass.AVCaptureVideoDataOutput.init()
        self.videoOutput = videoOutput
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as Swift.String: NSNumber(value: WebCore.preferedPixelBufferFormat())]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegate, queue: captureQueue)

        if !session.canAddOutput(videoOutput) {
            logger.error("AVVideoCaptureSource unable to add video output device")
            return false
        }
        session.addOutput(videoOutput)

#if os(iOS) || os(visionOS) || os(tvOS)
        if useRotationCoordinatorAPI, let connection = videoOutput.connection(with: AVFoundationSoftLink.AVMediaTypeVideo), connection.isVideoRotationAngleSupported(0) {
            logger.log("Setting AVVideoCaptureSource connection angle to 0")
            connection.videoRotationAngle = 0
        }
#endif

        setSessionSizeFrameRateAndZoom()
        state.needsTorchReconfiguration = state.needsTorchReconfiguration || torch

        state.sensorOrientation = sensorOrientationFromVideoOutput()
        computeVideoFrameRotation()

        return true
    }

    // MARK: Running and interruption

    func captureSessionIsRunningDidChange(_ running: Bool) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                logger.log("AVVideoCaptureSource::captureSessionIsRunningDidChange \(running)")
                let isMuted = WebCore.cameraCaptureSourceIsMuted(identifier)
                if !state.runningDidChange(running, isMuted: isMuted) {
                    return
                }

                reconfigureIfNeeded()

                updateVerifyCapturingTimer()

#if os(iOS) || os(visionOS) || os(tvOS)
                if startupTimer != nil {
                    state.shouldCallNotifyMutedChange = true
                    return
                }
#endif

                event(.MutedChanged, !state.isRunning)
            }
        }
    }

    func captureDeviceSuspendedDidChange() {
#if os(macOS)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                state.interrupted = device.isSuspended
                logger.log("AVVideoCaptureSource::captureDeviceSuspendedDidChange \(self.state.interrupted)")

                updateVerifyCapturingTimer()

                if state.interrupted != WebCore.cameraCaptureSourceIsMuted(identifier) {
                    event(.MutedChanged, state.interrupted)
                }
            }
        }
#endif
    }

    var isInterrupted: Bool {
        state.interrupted
    }

#if os(iOS) || os(visionOS) || os(tvOS)
    func captureSessionRuntimeError(code: Int) {
        if !state.isRunning || code != AVError.Code.mediaServicesWereReset.rawValue {
            return
        }

        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                // Try to restart the session, but reset isRunning immediately so if it fails we won't try again.
                logger.error("AVVideoCaptureSource restarting session")
                session?.startRunning()
                state.isRunning = session?.isRunning ?? false
            }
        }
    }

    func captureSessionBeginInterruption() {
        state.interrupted = true
    }

    func captureSessionEndInterruption() {
        logger.log("AVVideoCaptureSource::captureSessionEndInterruption")
        state.interrupted = false
    }
#endif

    func deviceDisconnected(_ object: AnyObject?) {
        logger.log("AVVideoCaptureSource::deviceDisconnected")
        if object === device {
            event(.CaptureFailed)
        }
    }

    // MARK: Settings, capabilities and presets

    func deviceValues() -> WebCore.CameraCaptureDeviceValues {
        var values = WebCore.CameraCaptureDeviceValues()
        switch device.position {
        case .front:
            values.position = .Front
        case .back:
            values.position = .Back
        default:
            values.position = .Unspecified
        }
        var whiteBalanceModes: UInt8 = 0
        if device.isWhiteBalanceModeSupported(.locked) {
            whiteBalanceModes |= 1 << WebCore.MeteringMode.Manual.rawValue
        }
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
            whiteBalanceModes |= 1 << WebCore.MeteringMode.SingleShot.rawValue
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            whiteBalanceModes |= 1 << WebCore.MeteringMode.Continuous.rawValue
        }
        values.whiteBalanceModes = whiteBalanceModes
        values.whiteBalanceMode = meteringMode(for: device.whiteBalanceMode)
        values.hasTorch = device.hasTorch
        values.isTorchOn = device.torchMode == .on
        values.isPortraitEffectActive = device.isPortraitEffectActive
#if HAVE_AVCAPTUREDEVICE_MINFOCUSLENGTH
        let minimumFocusDistance = Double(device.minimumFocusDistance)
        if minimumFocusDistance != -1.0 {
            assert(minimumFocusDistance >= 0)
            values.hasMinimumFocusDistance = true
            values.minimumFocusDistance = minimumFocusDistance
        }
#endif
        values.isTorchChangePending = isTorchChangePending
        values.isWhiteBalanceModeChangePending = isWhiteBalanceModeChangePending
        return values
    }

    func fillLightMode() -> WebCore.CameraCaptureFillLightMode {
        var mode = WebCore.CameraCaptureFillLightMode()
        if device.hasTorch {
            mode.hasTorch = true
            mode.mode = webFillLightMode(for: device.torchMode)
        }
        return mode
    }

    func facingModeFitnessScoreAdjustment() -> Double {
        if device.position != .back {
            return 0
        }

        let deviceTypes = cameraCaptureDeviceTypeList
        let relativePriority = deviceTypes.firstIndex(of: device.deviceType) ?? deviceTypes.count
        return Double(deviceTypes.count - relativePriority)
    }

    private func computeMinZoom() -> (has: Bool, value: Double) {
#if os(iOS) || os(visionOS) || os(tvOS)
        if state.zoomScaleFactor == 1.0 {
            return (false, 1)
        }
        return (true, 1.0 / state.zoomScaleFactor)
#else
        return (false, 1)
#endif
    }

    private func computeMaxZoom(_ format: AVCaptureDevice.Format) -> (has: Bool, value: Double) {
#if os(iOS) || os(visionOS) || os(tvOS)
        // We restrict zoom for now as it might require elevated permissions.
        return (true, min(Double(format.videoMaxZoomFactor) / state.zoomScaleFactor, 10.0))
#else
        return (false, 1)
#endif
    }

    // The device's formats that make presets: one per size, in the device's order, without the packed-Bayer ProRes RAW
    // sensor formats, which aren't supported.
    func generatePresets() -> UInt32 {
        presetFormats = []
        presetFrameRateRanges = []
        var sizes: [(width: Int32, height: Int32)] = []
        for element in AVFoundationMember.formats(of: device)?.formats ?? NSArray() {
            guard let format = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVCaptureDeviceFormat) else {
                continue
            }
            let formatDescription = format.formatDescription
            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
            if mediaSubType == kCVPixelFormatType_96VersatileBayerPacked12 || mediaSubType == FourCharCode(kCVPixelFormatType_96BayerPacked12_BGGR) {
                continue
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            if sizes.contains(where: { $0.width == dimensions.width && $0.height == dimensions.height }) {
                continue
            }
            sizes.append((dimensions.width, dimensions.height))

            var frameRates: [(minimum: Double, maximum: Double)] = []
            for rangeElement in AVFoundationMember.videoSupportedFrameRateRanges(of: format)?.videoSupportedFrameRateRanges ?? NSArray() {
                if let range = AVFoundationClass.cast(rangeElement as AnyObject, to: AVFoundationClass.AVFrameRateRange) {
                    frameRates.append((range.minFrameRate, range.maxFrameRate))
                }
            }
            presetFormats.append(format)
            presetFrameRateRanges.append(frameRates)
        }
        return UInt32(presetFormats.count)
    }

    func preset(_ index: UInt32) -> WebCore.CameraCapturePresetValues {
        var values = WebCore.CameraCapturePresetValues()
        guard Int(index) < presetFormats.count, let format = AVFoundationClass.cast(presetFormats[Int(index)], to: AVFoundationClass.AVCaptureDeviceFormat) else {
            return values
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        values.width = dimensions.width
        values.height = dimensions.height
        let minZoom = computeMinZoom()
        values.hasMinZoom = minZoom.has
        values.minZoom = minZoom.value
        let maxZoom = computeMaxZoom(format)
        values.hasMaxZoom = maxZoom.has
        values.maxZoom = maxZoom.value
        values.isEfficient = isFormatPowerEfficient(format)
        values.frameRateRangeCount = UInt32(presetFrameRateRanges[Int(index)].count)
        return values
    }

    func presetFrameRateRange(_ presetIndex: UInt32, _ rangeIndex: UInt32) -> WebCore.CameraCaptureFrameRateRange {
        var range = WebCore.CameraCaptureFrameRateRange()
        guard Int(presetIndex) < presetFrameRateRanges.count, Int(rangeIndex) < presetFrameRateRanges[Int(presetIndex)].count else {
            return range
        }
        let value = presetFrameRateRanges[Int(presetIndex)][Int(rangeIndex)]
        range.minimum = value.minimum
        range.maximum = value.maximum
        return range
    }

    // MARK: Photo

    private func makePhotoOutput() -> AVCapturePhotoOutput? {
        if let photoOutput {
            return photoOutput
        }

        let output = AVFoundationClass.AVCapturePhotoOutput.init()
        guard let session, session.canAddOutput(output) else {
            logger.error("AVVideoCaptureSource unable to add photo output")
            return nil
        }
        session.addOutput(output)
        photoOutput = output

#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
        let coordinator = AVFoundationClass.AVCapturePhotoOutputReadinessCoordinator.init(photoOutput: output)
        coordinator.delegate = delegate
        readinessCoordinator = coordinator
#endif

        return output
    }

    private func maxPhotoSizeForCurrentPreset(_ requested: (width: Int32, height: Int32)) -> (width: Int32, height: Int32) {
        let format = device.activeFormat
        if format.responds(to: NSSelectorFromString("supportedMaxPhotoDimensions")) {
            return maxPhotoSize(for: format, requested: requested)
        }

        if let currentFormat, let current = AVFoundationClass.cast(currentFormat, to: AVFoundationClass.AVCaptureDeviceFormat) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(current.formatDescription)
            return (dimensions.width, dimensions.height)
        }

        return (0, 0)
    }

    private func photoConfiguration(_ request: WebCore.CameraCapturePhotoRequest, photoOutput: AVCapturePhotoOutput) -> AVCapturePhotoSettings? {
        var settings: AVCapturePhotoSettings?
        let exception = WebCoreCatchingObjCException {
            MainActor.assumeIsolated {
                let format: [Swift.String: Any] = [
                    AVFoundationSoftLink.AVVideoCodecKey: AVFoundationSoftLink.AVVideoCodecTypeJPEG.rawValue,
                    AVFoundationSoftLink.AVVideoCompressionPropertiesKey: [AVFoundationSoftLink.AVVideoQualityKey: NSNumber(value: 1)],
                ]
                let photoSettings = AVFoundationClass.AVCapturePhotoSettings.init(format: format)

#if os(iOS) || os(visionOS) || os(tvOS)
                if request.hasFillLightMode {
                    let mode = flashMode(for: request.fillLightMode)
                    if photoOutput.__supportedFlashModes.contains(NSNumber(value: mode.rawValue)) {
                        photoSettings.flashMode = mode
                    }
                }

                if request.hasRedEyeReduction && photoOutput.isAutoRedEyeReductionSupported {
                    photoSettings.isAutoRedEyeReductionEnabled = request.redEyeReduction
                }
#endif

                if photoSettings.responds(to: NSSelectorFromString("setMaxPhotoDimensions:")) {
                    var requested: (width: Int32, height: Int32) = (0, 0)
                    if request.hasImageSize {
                        requested = (clampToInt32ForIntSize(Float(request.imageWidth).rounded()), clampToInt32ForIntSize(Float(request.imageHeight).rounded()))
                    }
                    let dimensions = self.maxPhotoSizeForCurrentPreset(requested)
                    if dimensions.width > 0 && dimensions.height > 0 {
                        photoSettings.maxPhotoDimensions = CMVideoDimensions(width: dimensions.width, height: dimensions.height)
                    }
                }
                settings = photoSettings
            }
        }
        if let exception {
            logger.error("AVVideoCaptureSource error configuring photoSettings \(exception.name.rawValue, privacy: .public), reason : \(exception.reason ?? "", privacy: .public)")
            return nil
        }
        return settings
    }

    func takePhoto(_ request: WebCore.CameraCapturePhotoRequest) {
        guard let photoOutput = makePhotoOutput() else {
            WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .InternalError)
            return
        }

        guard let photoSettings = photoConfiguration(request, photoOutput: photoOutput) else {
            logger.error("AVVideoCaptureSource photoConfiguration() failed")
            WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .InternalError)
            return
        }

        if photoSettings.responds(to: NSSelectorFromString("setMaxPhotoDimensions:")) {
            let requested = photoSettings.maxPhotoDimensions
            if requested.width > 0 && requested.height > 0 {
                let current = photoOutput.maxPhotoDimensions
                if requested.width > current.width || requested.height > current.height {
                    if let exception = WebCoreCatchingObjCException({ photoOutput.maxPhotoDimensions = requested }) {
                        logger.error("AVVideoCaptureSource error calling setMaxPhotoDimensions: \(exception.name.rawValue, privacy: .public), reason: \(exception.reason ?? "", privacy: .public)")
                        WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .SetMaxPhotoDimensionsFailed)
                        return
                    }
                }
            }
        }

#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
        if let readinessCoordinator, readinessCoordinator.captureReadiness != .ready {
            pendingPhotoSettings = photoSettings
            pendingCaptureWatchdog?.cancel()
            let watchdog = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.pendingCaptureTimedOut()
                }
            }
            pendingCaptureWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + photoCapturePipelineReadinessTimeout, execute: watchdog)
            return
        }
#endif

        dispatchCaptureOnPhotoQueue(photoOutput, photoSettings)
    }

#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
    private func pendingCaptureTimedOut() {
        if case .none = pendingPhotoSettings {
            return
        }

        logger.error("AVVideoCaptureSource photo pipeline readiness timeout")
        pendingPhotoSettings = nil
        WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .PipelineReadinessTimeout)
    }
#endif

    private func dispatchCaptureOnPhotoQueue(_ photoOutput: AVCapturePhotoOutput, _ photoSettings: AVCapturePhotoSettings) {
        let request = PhotoCaptureRequest(photoOutput: photoOutput, photoSettings: photoSettings, delegate: delegate)
        let identifier = self.identifier
        CameraCaptureSource.photoQueue.async {
            if let exception = WebCoreCatchingObjCException({ request.photoOutput.capturePhoto(with: request.photoSettings, delegate: request.delegate) }) {
                let name = exception.name.rawValue
                let reason = exception.reason ?? ""
                DispatchQueue.main.async {
                    logger.error("AVVideoCaptureSource error taking photo \(name, privacy: .public), reason: \(reason, privacy: .public)")
                    WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .CapturePhotoFailed)
                }
            }
        }
    }

    func captureReadinessDidChange() {
#if HAVE_AVCAPTUREPHOTOOUTPUT_READINESS_COORDINATOR
        guard let readinessCoordinator, let pendingPhotoSettings else {
            return
        }

        let readiness = readinessCoordinator.captureReadiness
        if readiness == .sessionNotRunning {
            self.pendingPhotoSettings = nil
            pendingCaptureWatchdog?.cancel()
            pendingCaptureWatchdog = nil
            WebCore.cameraCaptureSourceDidFailToCapturePhoto(identifier, .SessionNotRunning)
            return
        }
        if readiness != .ready {
            return
        }

        pendingCaptureWatchdog?.cancel()
        pendingCaptureWatchdog = nil
        self.pendingPhotoSettings = nil
        if let photoOutput {
            dispatchCaptureOnPhotoQueue(photoOutput, pendingPhotoSettings)
        }
#endif
    }
}

// A photo capture for its trip to the photo queue. AVCapturePhotoOutput's capturePhoto(with:delegate:) may be called on
// any queue, the settings are used once, by that call, and the delegate is Sendable.
private struct PhotoCaptureRequest: @unchecked Sendable {
    let photoOutput: AVCapturePhotoOutput
    let photoSettings: AVCapturePhotoSettings
    let delegate: CameraCaptureDelegate
}

// MARK: Entry points

// A source for the device with this unique ID, by identifier, or 0 if there is no such device.
@_expose(Cxx)
func cameraCaptureSourceCreate(_ uniqueID: borrowing NSObject?) -> UInt64 {
    guard let uniqueID = (copy uniqueID as? NSString).map({ $0 as Swift.String }) else {
        return 0
    }
    return MainActor.assumeIsolated {
        guard let device = AVFoundationClass.AVCaptureDevice.init(uniqueID: uniqueID) else {
            return 0
        }
        lastCameraCaptureSourceIdentifier &+= 1
        let identifier = lastCameraCaptureSourceIdentifier
        cameraCaptureSources[identifier] = CameraCaptureSource(identifier: identifier, device: device)
        return identifier
    }
}

// Adds the camera device types to the array, in the order that selects the preferred back camera.
@_expose(Cxx)
func cameraCaptureSourceAddDeviceTypes(_ deviceTypes: borrowing NSObject?) {
    guard let deviceTypes = copy deviceTypes as? NSMutableArray else {
        return
    }
    for deviceType in cameraCaptureDeviceTypeList {
        deviceTypes.add(deviceType.rawValue as NSString)
    }
}

#if ENABLE_EXTENSION_CAPABILITIES
// RealtimeMediaSourceCenter's media environment, for the session that the source makes.
@_expose(Cxx)
func cameraCaptureSourceSetMediaEnvironment(_ identifier: UInt64, _ mediaEnvironment: borrowing NSObject?) {
    let environment = (copy mediaEnvironment as? NSString).map { $0 as Swift.String }
    MainActor.assumeIsolated {
        cameraCaptureSources[identifier]?.mediaEnvironment = environment
    }
}
#endif

#if ENABLE_APP_PRIVACY_REPORT
// RealtimeMediaSourceCenter's identity, for the session that the source makes.
@_expose(Cxx)
func cameraCaptureSourceSetAssumedIdentity(_ identifier: UInt64, _ identity: borrowing NSObject?) {
    let box = ObjectBox(copy identity)
    MainActor.assumeIsolated {
        cameraCaptureSources[identifier]?.assumedIdentity = box.object as? tcc_identity_t
    }
}
#endif

// MARK: Handle

extension WebCore.CameraCaptureSourceHandle {
    @MainActor
    private var source: CameraCaptureSource? {
        cameraCaptureSources[m_identifier]
    }

    @cxx
    @implementation
    static func setUseRotationCoordinatorAPI(_ value: Bool) {
        MainActor.assumeIsolated {
            useRotationCoordinatorAPI = value
        }
    }

    @cxx
    @implementation
    mutating func destroy() {
        let identifier = m_identifier
        m_identifier = 0
        MainActor.assumeIsolated {
            cameraCaptureSources.removeValue(forKey: identifier)?.invalidate()
        }
    }

    @cxx
    @implementation
    mutating func startProducingData() {
        MainActor.assumeIsolated {
            source?.startProducingData()
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
    mutating func startApplyingConstraints() {
        MainActor.assumeIsolated {
            source?.startApplyingConstraints()
        }
    }

    @cxx
    @implementation
    mutating func endApplyingConstraints() {
        MainActor.assumeIsolated {
            source?.endApplyingConstraints()
        }
    }

    @cxx
    @implementation
    mutating func settingsDidChange(_ whiteBalanceModeChanged: Bool, _ torchChanged: Bool, _ torch: Bool, _ whiteBalanceMode: WebCore.MeteringMode) {
        MainActor.assumeIsolated {
            source?.setTorchAndWhiteBalanceMode(torch: torch, whiteBalanceMode: whiteBalanceMode)
            source?.settingsDidChange(whiteBalanceModeChanged: whiteBalanceModeChanged, torchChanged: torchChanged)
        }
    }

    @cxx
    @implementation
    mutating func setTorchAndWhiteBalanceMode(_ torch: Bool, _ whiteBalanceMode: WebCore.MeteringMode) {
        MainActor.assumeIsolated {
            source?.setTorchAndWhiteBalanceMode(torch: torch, whiteBalanceMode: whiteBalanceMode)
        }
    }

    @cxx
    @implementation
    mutating func applyFrameRateAndZoomWithPreset(_ frameRate: Double, _ zoom: Double, _ presetIndex: Int32) -> Bool {
        MainActor.assumeIsolated {
            source?.applyFrameRateAndZoom(frameRate: frameRate, zoom: zoom, presetIndex: presetIndex) ?? false
        }
    }

    @cxx
    @implementation
    mutating func monitorOrientation(_ orientation: Int32) {
        MainActor.assumeIsolated {
            source?.monitorOrientation(orientation)
        }
    }

    @cxx
    @implementation
    mutating func orientationChanged(_ orientation: Int32) {
        MainActor.assumeIsolated {
            source?.orientationChanged(orientation)
        }
    }

    @cxx
    @implementation
    mutating func rotationAngleForHorizonLevelDisplayChanged(_ rotation: UInt16) {
        MainActor.assumeIsolated {
            source?.rotationAngleForHorizonLevelDisplayChanged(rotation)
        }
    }

    @cxx
    @implementation
    mutating func takePhoto(_ request: WebCore.CameraCapturePhotoRequest) {
        MainActor.assumeIsolated {
            source?.takePhoto(request)
        }
    }

    @cxx
    @implementation
    func videoFrameRotation() -> UInt16 {
        MainActor.assumeIsolated {
            source?.videoFrameRotation ?? 0
        }
    }

    @cxx
    @implementation
    func isInterrupted() -> Bool {
        MainActor.assumeIsolated {
            source?.isInterrupted ?? false
        }
    }

    @cxx
    @implementation
    func facingModeFitnessScoreAdjustment() -> Double {
        MainActor.assumeIsolated {
            source?.facingModeFitnessScoreAdjustment() ?? 0
        }
    }

    @cxx
    @implementation
    func deviceValues() -> WebCore.CameraCaptureDeviceValues {
        MainActor.assumeIsolated {
            source?.deviceValues() ?? WebCore.CameraCaptureDeviceValues()
        }
    }

    @cxx
    @implementation
    func fillLightMode() -> WebCore.CameraCaptureFillLightMode {
        MainActor.assumeIsolated {
            source?.fillLightMode() ?? WebCore.CameraCaptureFillLightMode()
        }
    }

    @cxx
    @implementation
    func presetCount() -> UInt32 {
        MainActor.assumeIsolated {
            source?.generatePresets() ?? 0
        }
    }

    @cxx
    @implementation
    func preset(_ index: UInt32) -> WebCore.CameraCapturePresetValues {
        MainActor.assumeIsolated {
            source?.preset(index) ?? WebCore.CameraCapturePresetValues()
        }
    }

    @cxx
    @implementation
    func presetFrameRateRange(_ presetIndex: UInt32, _ rangeIndex: UInt32) -> WebCore.CameraCaptureFrameRateRange {
        MainActor.assumeIsolated {
            source?.presetFrameRateRange(presetIndex, rangeIndex) ?? WebCore.CameraCaptureFrameRateRange()
        }
    }
}

#endif
