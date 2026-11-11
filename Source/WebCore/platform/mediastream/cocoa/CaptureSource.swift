// Copyright (C) 2011-2023 Apple Inc. All rights reserved.
// Copyright (C) 2013-2019 Apple Inc. All rights reserved.
// Copyright (C) 2018-2023 Apple Inc. All rights reserved.
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

// A capture source of the GPU process, in Swift: what RealtimeMediaSource and RealtimeVideoCaptureSource do for the
// camera, display, microphone and mock sources, without a C++ source. The GPU process's capture receiver
// (WebKit/GPUProcess/webrtc/UserMediaCaptureManagerProxy.swift) holds these; callers in other processes keep the C++
// RealtimeMediaSource facades, which make the same decisions (CaptureSourceDecisions.swift) and get the same settings.

import CoreVideo
import Dispatch
public import Foundation
import Synchronization
import WebCore_Private.Core.CaptureSourceDecisions
import WebCore_Private.Core.CaptureSourceSupport
import WebCore_Private.Core.DisplayCaptureSourceHandle
import WebCore_Private.Core.MediaConstraintsEvaluation
import WebCore_Private.Core.MockRealtimeMediaSourceCenter
import WebCore_Private.Core.RealtimeMediaSourceCenter

// MARK: Values

// RealtimeMediaSourceSupportedConstraints.
@_spi(WebKitGPU) public struct CaptureSupportedConstraints: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let width = Self(rawValue: 1 << 0)
    public static let height = Self(rawValue: 1 << 1)
    public static let aspectRatio = Self(rawValue: 1 << 2)
    public static let frameRate = Self(rawValue: 1 << 3)
    public static let facingMode = Self(rawValue: 1 << 4)
    public static let volume = Self(rawValue: 1 << 5)
    public static let sampleRate = Self(rawValue: 1 << 6)
    public static let sampleSize = Self(rawValue: 1 << 7)
    public static let echoCancellation = Self(rawValue: 1 << 8)
    public static let deviceId = Self(rawValue: 1 << 9)
    public static let groupId = Self(rawValue: 1 << 10)
    public static let displaySurface = Self(rawValue: 1 << 11)
    public static let logicalSurface = Self(rawValue: 1 << 12)
    public static let focusDistance = Self(rawValue: 1 << 13)
    public static let whiteBalanceMode = Self(rawValue: 1 << 14)
    public static let zoom = Self(rawValue: 1 << 15)
    public static let torch = Self(rawValue: 1 << 16)
    public static let backgroundBlur = Self(rawValue: 1 << 17)
    public static let powerEfficient = Self(rawValue: 1 << 18)
}

// VideoFacingMode, DisplaySurfaceType and MeteringMode, by their C++ values.
@_spi(WebKitGPU) public enum CaptureFacingMode: UInt8, Sendable {
    case unknown = 0
    case user
    case environment
    case left
    case right
}

@_spi(WebKitGPU) public enum CaptureDisplaySurface: UInt8, Sendable {
    case monitor = 0
    case window
    case application
    case browser
    case invalid
}

@_spi(WebKitGPU) public enum CaptureMeteringMode: UInt8, Sendable {
    case none = 0
    case manual
    case singleShot
    case continuous
}

// RealtimeMediaSourceSettings.
@_spi(WebKitGPU) public struct CaptureSettings: Sendable {
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var frameRate: Float = 0
    public var facingMode = CaptureFacingMode.unknown
    public var volume: Double = 0
    public var sampleRate: UInt32 = 0
    public var sampleSize: UInt32 = 0
    public var echoCancellation = false
    public var deviceId = ""
    public var groupId = ""
    public var label = ""
    public var displaySurface = CaptureDisplaySurface.invalid
    public var logicalSurface = false
    public var whiteBalanceMode = CaptureMeteringMode.none
    public var zoom: Double = 1
    public var torch = false
    public var backgroundBlur = false
    public var powerEfficient = false
    public var supportedConstraints = CaptureSupportedConstraints()

    public init() {
    }
}

// LongCapabilityRange and DoubleCapabilityRange.
@_spi(WebKitGPU) public struct CaptureRange<Value: Sendable & Comparable & Numeric>: Sendable {
    public var min: Value = 0
    public var max: Value = 0

    public init() {
    }

    public init(_ min: Value, _ max: Value) {
        self.min = min
        self.max = max
    }
}

// RealtimeMediaSourceCapabilities's EchoCancellation and BackgroundBlur.
@_spi(WebKitGPU) public enum CaptureEchoCancellationCapability: UInt8, Sendable {
    case off = 0
    case on
    case onOrOff
}

@_spi(WebKitGPU) public enum CaptureBackgroundBlurCapability: UInt8, Sendable {
    case off = 0
    case on
    case onOff
}

// RealtimeMediaSourceCapabilities.
@_spi(WebKitGPU) public struct CaptureCapabilities: Sendable {
    public var width = CaptureRange<Int32>()
    public var height = CaptureRange<Int32>()
    public var aspectRatio = CaptureRange<Double>()
    public var frameRate = CaptureRange<Double>()
    public var facingModes: [CaptureFacingMode] = []
    public var volume = CaptureRange<Double>()
    public var sampleRate = CaptureRange<Int32>()
    public var sampleSize = CaptureRange<Int32>()
    public var echoCancellation = CaptureEchoCancellationCapability.on
    public var deviceId = ""
    public var groupId = ""
    public var focusDistance = CaptureRange<Double>()
    public var whiteBalanceModes: [CaptureMeteringMode] = []
    public var zoom = CaptureRange<Double>()
    public var torch = false
    public var backgroundBlur = CaptureBackgroundBlurCapability.off
    public var powerEfficient = false
    public var supportedConstraints = CaptureSupportedConstraints()

    public init(supportedConstraints: CaptureSupportedConstraints = []) {
        self.supportedConstraints = supportedConstraints
    }
}

// FillLightMode and PhotoSettings.
@_spi(WebKitGPU) public enum CaptureFillLightMode: UInt8, Sendable {
    case auto = 0
    case off
    case flash
}

@_spi(WebKitGPU) public struct CapturePhotoSettings: Sendable {
    public var fillLightMode: CaptureFillLightMode?
    public var imageHeight: Double?
    public var imageWidth: Double?
    public var redEyeReduction: Bool?

    public init(fillLightMode: CaptureFillLightMode? = nil, imageHeight: Double? = nil, imageWidth: Double? = nil, redEyeReduction: Bool? = nil) {
        self.fillLightMode = fillLightMode
        self.imageHeight = imageHeight
        self.imageWidth = imageWidth
        self.redEyeReduction = redEyeReduction
    }
}

// MediaSettingsRange and PhotoCapabilities.
@_spi(WebKitGPU) public struct CaptureSettingsRange: Sendable {
    public var max: Double?
    public var min: Double?
    public var step: Double?
}

@_spi(WebKitGPU) public struct CapturePhotoCapabilities: Sendable {
    public var redEyeReduction: UInt8?
    public var imageHeight: CaptureSettingsRange?
    public var imageWidth: CaptureSettingsRange?
    public var fillLightMode: [CaptureFillLightMode]?

    public init() {
    }
}

// RealtimeMediaSourceSettings::Flag.
@_spi(WebKitGPU) public struct CaptureSettingsFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let width = Self(rawValue: 1 << 0)
    public static let height = Self(rawValue: 1 << 1)
    public static let frameRate = Self(rawValue: 1 << 2)
    public static let facingMode = Self(rawValue: 1 << 3)
    public static let volume = Self(rawValue: 1 << 4)
    public static let sampleRate = Self(rawValue: 1 << 5)
    public static let sampleSize = Self(rawValue: 1 << 6)
    public static let echoCancellation = Self(rawValue: 1 << 7)
    public static let deviceId = Self(rawValue: 1 << 8)
    public static let groupId = Self(rawValue: 1 << 9)
    public static let label = Self(rawValue: 1 << 10)
    public static let displaySurface = Self(rawValue: 1 << 11)
    public static let logicalSurface = Self(rawValue: 1 << 12)
    public static let whiteBalanceMode = Self(rawValue: 1 << 13)
    public static let zoom = Self(rawValue: 1 << 14)
    public static let torch = Self(rawValue: 1 << 15)
    public static let backgroundBlur = Self(rawValue: 1 << 16)
    public static let powerEfficient = Self(rawValue: 1 << 17)
}

// CaptureDevice::DeviceType, for the kinds the GPU process captures.
@_spi(WebKitGPU) public enum CaptureDeviceKind: Sendable {
    case microphone
    case camera
    case screen
    case window

    public var isVideo: Bool {
        self != .microphone
    }
}

// A CaptureDevice and the salts its IDs are hashed with.
@_spi(WebKitGPU) public struct CaptureDeviceDescription: Sendable {
    public var persistentID: Swift.String
    public var label: Swift.String
    public var groupID: Swift.String
    public var kind: CaptureDeviceKind
    public var isDefault: Bool
    public var isEphemeral: Bool
    public var persistentDeviceSalt: Swift.String
    public var ephemeralDeviceSalt: Swift.String

    public init(persistentID: Swift.String, label: Swift.String, groupID: Swift.String, kind: CaptureDeviceKind, isDefault: Bool, isEphemeral: Bool, persistentDeviceSalt: Swift.String, ephemeralDeviceSalt: Swift.String) {
        self.persistentID = persistentID
        self.label = label
        self.groupID = groupID
        self.kind = kind
        self.isDefault = isDefault
        self.isEphemeral = isEphemeral
        self.persistentDeviceSalt = persistentDeviceSalt
        self.ephemeralDeviceSalt = ephemeralDeviceSalt
    }
}

// CaptureSourceError's denial reason and message.
@_spi(WebKitGPU) public struct CaptureSourceFailure: Error, Sendable {
    public var message: Swift.String
    // A MediaAccessDenialReason.
    public var denialReason: UInt8
    // A MediaConstraintType.
    public var invalidConstraint: UInt8

    public init(message: Swift.String = "", denialReason: UInt8, invalidConstraint: UInt8 = 0) {
        self.message = message
        self.denialReason = denialReason
        self.invalidConstraint = invalidConstraint
    }

    // MediaAccessDenialReason::PermissionDenied, InvalidConstraint and InvalidAccess.
    public static let permissionDenied: UInt8 = 6
    public static let invalidConstraint: UInt8 = 4
    public static let invalidAccess: UInt8 = 7

    public static func constraint(_ type: UInt8) -> Self {
        Self(denialReason: invalidConstraint, invalidConstraint: type)
    }
}

// RealtimeMediaSource::ApplyConstraintsError.
@_spi(WebKitGPU) public struct CaptureConstraintsFailure: Error, Sendable {
    // A MediaConstraintType.
    public var invalidConstraint: UInt8
    public var message: Swift.String

    public init(invalidConstraint: UInt8, message: Swift.String) {
        self.invalidConstraint = invalidConstraint
        self.message = message
    }
}

// CaptureSettings and CaptureCapabilities, with the strings the C++ facades add.
extension CaptureSettings {
    public init(_ values: WebCore.CaptureSettingsValues, label: Swift.String = "", deviceId: Swift.String = "", groupId: Swift.String = "") {
        self.init()
        width = values.width
        height = values.height
        frameRate = values.frameRate
        facingMode = CaptureFacingMode(rawValue: values.facingMode) ?? .unknown
        volume = values.volume
        sampleRate = values.sampleRate
        sampleSize = values.sampleSize
        echoCancellation = values.echoCancellation
        self.deviceId = deviceId
        self.groupId = groupId
        self.label = label
        displaySurface = CaptureDisplaySurface(rawValue: values.displaySurface) ?? .invalid
        logicalSurface = values.logicalSurface
        whiteBalanceMode = CaptureMeteringMode(rawValue: values.whiteBalanceMode) ?? .none
        zoom = values.zoom
        torch = values.torch
        backgroundBlur = values.backgroundBlur
        powerEfficient = values.powerEfficient
        supportedConstraints = CaptureSupportedConstraints(rawValue: values.supportedConstraints)
    }
}

extension CaptureCapabilities {
    public init(_ values: WebCore.CaptureCapabilityValues, deviceId: Swift.String = "", groupId: Swift.String = "") {
        self.init(supportedConstraints: CaptureSupportedConstraints(rawValue: values.supportedConstraints))
        width = CaptureRange(values.widthMin, values.widthMax)
        height = CaptureRange(values.heightMin, values.heightMax)
        aspectRatio = CaptureRange(values.aspectRatioMin, values.aspectRatioMax)
        frameRate = CaptureRange(values.frameRateMin, values.frameRateMax)
        facingModes = (0..<8).compactMap { values.facingModes & (1 << $0) != 0 ? CaptureFacingMode(rawValue: UInt8($0)) : nil }
        volume = CaptureRange(values.volumeMin, values.volumeMax)
        sampleRate = CaptureRange(values.sampleRateMin, values.sampleRateMax)
        sampleSize = CaptureRange(values.sampleSizeMin, values.sampleSizeMax)
        echoCancellation = CaptureEchoCancellationCapability(rawValue: values.echoCancellation) ?? .on
        self.deviceId = deviceId
        self.groupId = groupId
        focusDistance = CaptureRange(values.focusDistanceMin, values.focusDistanceMax)
        whiteBalanceModes = (0..<8).compactMap { values.whiteBalanceModes & (1 << $0) != 0 ? CaptureMeteringMode(rawValue: UInt8($0)) : nil }
        zoom = CaptureRange(values.zoomMin, values.zoomMax)
        torch = values.torch
        backgroundBlur = CaptureBackgroundBlurCapability(rawValue: values.backgroundBlur) ?? .off
        powerEfficient = values.powerEfficient
    }
}

// MARK: Observers

// What RealtimeMediaSourceObserver hears, on the main thread.
@_spi(WebKitGPU) @MainActor public protocol CaptureSourceObserver: AnyObject {
    func captureSourceStarted()
    func captureSourceStopped()
    func captureSourceMutedChanged()
    func captureSourceSettingsChanged()
    func captureSourceConfigurationChanged()
    func captureSourceAudioUnitWillStart()
    // Whether the observer keeps the source from ending.
    func captureSourcePreventsEnding() -> Bool
}

// What RealtimeMediaSource::VideoFrameObserver gets, on the thread the source produces frames on.
@_spi(WebKitGPU) public protocol CaptureVideoFrameObserver: AnyObject, Sendable {
    func captureVideoFrameAvailable(_ frame: CaptureFrame, captureTime: Double)
}

// MARK: Frames

// A video frame observer and its adaptation: decimation and resizing (RealtimeMediaSource's VideoFrameAdaptor).
private struct VideoFrameObserverEntry {
    weak var observer: (any CaptureVideoFrameObserver)?
    let identity: ObjectIdentifier
    var width: Int32
    var height: Int32
    var frameRate: Double
    var hasAdaptor: Bool
    var frameDecimation: UInt64 = 1
    var frameDecimationCounter: UInt64 = 0
    var session: WebCore.CaptureVideoFrameSession?
}

// The fan-out of a video source's frames to its observers, on any thread, as RealtimeMediaSource::videoFrameAvailable().
final class CaptureVideoFrameFanOut: Sendable {
    private struct State: ~Copyable {
        var observers: [VideoFrameObserverEntry] = []
        var observedFrameTimes: [Double] = []
        var observedFrameRate: Double = 0
        var rotationSession: WebCore.CaptureVideoFrameSession?
    }

    private let state = Mutex(State())
    let isApplyingRotation = Atomic<Bool>(false)
    private let canUseIOSurface: Bool
    private let isDisplay: Bool
    private let requestedFrameRateBits = Atomic<UInt64>(30.0.bitPattern)

    init(canUseIOSurface: Bool, isDisplay: Bool) {
        self.canUseIOSurface = canUseIOSurface
        self.isDisplay = isDisplay
    }

    func setRequestedFrameRate(_ frameRate: Double) {
        requestedFrameRateBits.store(frameRate.bitPattern, ordering: .relaxed)
    }

    // RealtimeMediaSource::observedFrameRate(), which DisplayCaptureSourceCocoa makes its frame rate.
    var frameRateForDecimation: Double {
        isDisplay ? Double(bitPattern: requestedFrameRateBits.load(ordering: .relaxed)) : observedFrameRate
    }

    // RealtimeMediaSource::computeResizedVideoFrameSize(), or DisplayCaptureSourceCocoa's.
    func resizedVideoFrameSize(_ desired: WebCore.CaptureSourceSize, _ actual: WebCore.CaptureSourceSize) -> WebCore.CaptureSourceSize {
        guard isDisplay else {
            return WebCore.CaptureSourceDecisions.resizedVideoFrameSize(desired, actual)
        }
        let size = WebCore.DisplayCaptureSourceHandle.resizedVideoFrameSize(WebCore.DisplayCaptureSize(width: desired.width, height: desired.height), WebCore.DisplayCaptureSize(width: actual.width, height: actual.height))
        return WebCore.CaptureSourceSize(width: size.width, height: size.height)
    }

    var observedFrameRate: Double {
        state.withLock { $0.observedFrameRate }
    }

    var observersWithAdaptorCount: Int {
        state.withLock { $0.observers.filter(\.hasAdaptor).count }
    }

    func add(_ observer: any CaptureVideoFrameObserver, width: Int32 = 0, height: Int32 = 0, frameRate: Double = 0, hasAdaptor: Bool = false) {
        state.withLock {
            $0.observers.append(VideoFrameObserverEntry(observer: observer, identity: ObjectIdentifier(observer), width: width, height: height, frameRate: frameRate, hasAdaptor: hasAdaptor))
        }
    }

    func remove(_ observer: any CaptureVideoFrameObserver) {
        let identity = ObjectIdentifier(observer)
        state.withLock {
            $0.observers.removeAll { $0.identity == identity }
        }
    }

    // RealtimeVideoCaptureSource::dispatchVideoFrameToObservers(): notes the frame's time for the observed frame rate.
    func noteFrameTime(_ time: Double) {
        state.withLock { state in
            state.observedFrameTimes.append(time)
            state.observedFrameTimes.removeAll { $0 <= time - 2 }
            if let first = state.observedFrameTimes.first, let last = state.observedFrameTimes.last, last - first > 1 {
                state.observedFrameRate = Double(state.observedFrameTimes.count) / (last - first)
            }
        }
    }

    // Delivers the frame to each observer: rotated if the source applies rotation, decimated and resized per observer.
    func deliver(_ frame: CaptureFrame, captureTime: Double, observedFrameRate: Double) {
        let applyRotation = isApplyingRotation.load(ordering: .relaxed) && !frame.frame.hasNoTransformation()
        let canUseIOSurface = self.canUseIOSurface
        let deliveries: [(any CaptureVideoFrameObserver, CaptureFrame)] = state.withLock { state in
            var frame = frame
            var shouldSwapAdaptorSize = false
            if applyRotation {
                if state.rotationSession == nil {
                    state.rotationSession = WebCore.CaptureVideoFrameSession.create(canUseIOSurface)
                }
                if let rotated = state.rotationSession?.rotate(frame.frame) {
                    shouldSwapAdaptorSize = frame.frame.has90DegreeRotation()
                    frame = CaptureFrame(rotated)
                }
            }
            let presentationSize = frame.frame.presentationSize()
            let actual = WebCore.CaptureSourceSize(width: presentationSize.width(), height: presentationSize.height())

            var deliveries: [(any CaptureVideoFrameObserver, CaptureFrame)] = []
            for index in state.observers.indices {
                guard let observer = state.observers[index].observer else {
                    continue
                }
                var delivered = frame
                if state.observers[index].hasAdaptor {
                    if state.observers[index].frameDecimation > 1 {
                        state.observers[index].frameDecimationCounter &+= 1
                        if state.observers[index].frameDecimationCounter % state.observers[index].frameDecimation != 0 {
                            continue
                        }
                    }
                    state.observers[index].frameDecimation = WebCore.CaptureSourceDecisions.frameDecimation(observedFrameRate, state.observers[index].frameRate)
                    if state.observers[index].width != 0 || state.observers[index].height != 0 {
                        var adaptorSize = WebCore.CaptureSourceSize(width: state.observers[index].width, height: state.observers[index].height)
                        if shouldSwapAdaptorSize {
                            adaptorSize = WebCore.CaptureSourceSize(width: adaptorSize.height, height: adaptorSize.width)
                        }
                        let desired = resizedVideoFrameSize(adaptorSize, actual)
                        if desired.width != actual.width || desired.height != actual.height {
                            let pixelFormat = frame.frame.pixelFormat()
                            if state.observers[index].session?.pixelFormat() != pixelFormat {
                                state.observers[index].session = WebCore.CaptureVideoFrameSession.createWithPixelFormat(pixelFormat)
                            }
                            if let resized = state.observers[index].session?.resize(frame.frame, desired) {
                                delivered = CaptureFrame(resized)
                            }
                        }
                    }
                }
                deliveries.append((observer, delivered))
            }
            return deliveries
        }
        for (observer, delivered) in deliveries {
            observer.captureVideoFrameAvailable(delivered, captureTime: captureTime)
        }
    }
}

// A video frame on its way to the observers. A VideoFrame doesn't change once it is made: its members are const, the
// members that update it are unsafe in Swift, and setOwnershipIdentity() only tells the kernel who owns its IOSurface.
// It is thread-safe ref-counted, so any thread may hold and read it, as RealtimeMediaSource's observers do.
@_spi(WebKitGPU) public struct CaptureFrame: @unchecked Sendable {
    public let frame: WebCore.VideoFrame

    init(_ frame: WebCore.VideoFrame) {
        self.frame = frame
    }
}

// MARK: Backends

// What a source does with its device: CameraCaptureSource, DisplaySource, the microphone controller or a mock.
@MainActor
protocol CaptureSourceBackend: AnyObject {
    var source: CaptureSource? { get set }
    func startProducingData()
    func stopProducingData()
    func endProducingData()
    // RealtimeMediaSource::settingsDidChange() and the source's own settings and capabilities.
    func settingsDidChange(_ flags: CaptureSettingsFlags)
    func settings() -> CaptureSettings
    func capabilities() -> CaptureCapabilities
    // Video sources: their presets, which apply a size, frame rate and zoom; the frame rotation; photos.
    func presets() -> [CapturePreset]
    func applyFrameRateAndZoom(frameRate: Double, zoom: Double, preset: CapturePreset?) -> Bool
    func startApplyingConstraints()
    func endApplyingConstraints()
    var videoFrameRotation: UInt16 { get }
    var isInterrupted: Bool { get }
    var isPowerEfficient: Bool { get }
    var canResizeVideoFrames: Bool { get }
    var facingModeFitnessScoreAdjustment: Double { get }
    // A display resizes its frames keeping their aspect ratio, sets only a higher frame rate from constraints, and
    // decimates by its frame rate rather than the observed one (DisplayCaptureSourceCocoa).
    var isDisplay: Bool { get }
    func takePhoto(_ settings: CapturePhotoSettings, completion: @escaping @MainActor (Result<(Data, Swift.String), CaptureSourceFailure>) -> Void)
    func photoCapabilities() -> CapturePhotoCapabilities?
    func photoSettings() -> CapturePhotoSettings?
    func setIsInBackground(_ isInBackground: Bool)
    func monitorOrientation(_ orientation: Int32)
    func orientationChanged(_ orientation: Int32)
    func rotationAngleForHorizonLevelDisplayChanged(_ rotation: UInt16)
    func delaySamples(_ seconds: Double)
    // How the source becomes ready: a display waits for its first frame (DisplayCaptureSourceCocoa::whenReady()).
    func whenReady(_ completion: @escaping @MainActor (CaptureSourceFailure?) -> Void)
}

extension CaptureSourceBackend {
    func endProducingData() {
        source?.stop()
    }

    func settingsDidChange(_ flags: CaptureSettingsFlags) {
    }

    func presets() -> [CapturePreset] {
        []
    }

    func applyFrameRateAndZoom(frameRate: Double, zoom: Double, preset: CapturePreset?) -> Bool {
        false
    }

    func startApplyingConstraints() {
    }

    func endApplyingConstraints() {
    }

    var videoFrameRotation: UInt16 {
        0
    }

    var isInterrupted: Bool {
        false
    }

    var isPowerEfficient: Bool {
        false
    }

    var canResizeVideoFrames: Bool {
        false
    }

    var facingModeFitnessScoreAdjustment: Double {
        0
    }

    var isDisplay: Bool {
        false
    }

    func takePhoto(_ settings: CapturePhotoSettings, completion: @escaping @MainActor (Result<(Data, Swift.String), CaptureSourceFailure>) -> Void) {
        completion(.failure(CaptureSourceFailure(message: "Not supported", denialReason: 0)))
    }

    func photoCapabilities() -> CapturePhotoCapabilities? {
        nil
    }

    func photoSettings() -> CapturePhotoSettings? {
        nil
    }

    func setIsInBackground(_ isInBackground: Bool) {
    }

    func monitorOrientation(_ orientation: Int32) {
    }

    func orientationChanged(_ orientation: Int32) {
    }

    func rotationAngleForHorizonLevelDisplayChanged(_ rotation: UInt16) {
    }

    func delaySamples(_ seconds: Double) {
    }

    func whenReady(_ completion: @escaping @MainActor (CaptureSourceFailure?) -> Void) {
        completion(nil)
    }
}

// A VideoPreset.
struct CapturePreset: Sendable {
    var width: Int32
    var height: Int32
    var frameRateRanges: [(minimum: Double, maximum: Double)]
    var minZoom: Double
    var maxZoom: Double
    var isEfficient: Bool
    // The camera format the preset stands for.
    var formatIndex: Int32?

    var isZoomSupported: Bool {
        minZoom != 1 || maxZoom != 1
    }
}

// MARK: Source

// MediaConstraintType::Unknown.
private let unknownConstraint: UInt8 = 0

// A source of the GPU process: RealtimeMediaSource's state machine, settings bookkeeping and constraints, and
// RealtimeVideoCaptureSource's presets, photo queue and observed frame rate, over a backend.
@_spi(WebKitGPU) @MainActor public final class CaptureSource {
    public let device: CaptureDeviceDescription
    public let pageIdentifier: UInt64
    let backend: any CaptureSourceBackend
    let frames: CaptureVideoFrameFanOut

    private var observers: [ObjectIdentifier: () -> (any CaptureSourceObserver)?] = [:]
    private var observerOrder: [ObjectIdentifier] = []

    public private(set) var isProducingData = false
    public private(set) var isEnded = false
    public private(set) var muted = false
    public private(set) var captureDidFail = false
    public private(set) var fitnessScore: Double = 0
    public private(set) var name: Swift.String
    public private(set) var persistentID: Swift.String
    private var pendingSettingsDidChangeNotification = false
    private var settingsCapabilitiesUpdateCount = 0

    // RealtimeMediaSource's settings.
    private var requestedSize = WebCore.CaptureSourceSize()
    public private(set) var intrinsicSize = WebCore.CaptureSourceSize()
    public private(set) var frameRate: Double = 30
    public private(set) var zoom: Double = 1
    public private(set) var torch = false
    public private(set) var facingMode = CaptureFacingMode.user
    public private(set) var whiteBalanceMode = CaptureMeteringMode.none
    public private(set) var volume: Double = 1
    public private(set) var sampleRate: Int32 = 0
    public private(set) var sampleSize: Int32 = 0
    public private(set) var echoCancellation = false

    // RealtimeVideoCaptureSource's presets and operation queue.
    private var cachedPresets: [CapturePreset]?
    private var currentPreset: CapturePreset?
    public private(set) var mutedForPhotoCapture = false
    private var pendingOperations: [PendingOperation] = []
    private var captureInFlight = false

    private enum PendingOperation {
        case photo(CapturePhotoSettings, @MainActor (Result<(Data, Swift.String), CaptureSourceFailure>) -> Void)
        case constraints(WebCore.CaptureConstraints, @MainActor (CaptureConstraintsFailure?) -> Void)
    }

    init(device: CaptureDeviceDescription, pageIdentifier: UInt64, backend: any CaptureSourceBackend) {
        self.device = device
        self.pageIdentifier = pageIdentifier
        self.backend = backend
        name = device.label
        persistentID = device.persistentID
        frames = CaptureVideoFrameFanOut(canUseIOSurface: true, isDisplay: backend.isDisplay)
        backend.source = self
    }

    // A capture queue may hold the last reference; what this holds goes on the main thread.
    isolated deinit {
    }

    public var isVideo: Bool {
        device.kind.isVideo
    }

    // MARK: Hashed IDs

    public var hashedID: Swift.String {
        CaptureSource.hash(persistentID, device.isEphemeral ? device.ephemeralDeviceSalt : device.persistentDeviceSalt)
    }

    public var hashedGroupID: Swift.String {
        CaptureSource.hash(device.groupID, device.ephemeralDeviceSalt)
    }

    // RealtimeMediaSourceCenter::hashStringWithSalt().
    static func hash(_ string: Swift.String, _ salt: Swift.String) -> Swift.String {
        WebCore.captureHashStringWithSalt(string, salt)
    }

    // MARK: Observers

    public func addObserver(_ observer: any CaptureSourceObserver) {
        let identifier = ObjectIdentifier(observer)
        if observers[identifier] == nil {
            observerOrder.append(identifier)
        }
        observers[identifier] = { [weak observer] in observer }
    }

    public func removeObserver(_ observer: any CaptureSourceObserver) {
        let identifier = ObjectIdentifier(observer)
        observers[identifier] = nil
        observerOrder.removeAll { $0 == identifier }
        if liveObservers().isEmpty {
            stop()
        }
    }

    private func liveObservers() -> [any CaptureSourceObserver] {
        observerOrder.compactMap { observers[$0]?() }
    }

    private func forEachObserver(_ body: (any CaptureSourceObserver) -> Void) {
        for observer in liveObservers() {
            body(observer)
        }
    }

    public func addVideoFrameObserver(_ observer: any CaptureVideoFrameObserver) {
        frames.add(observer)
    }

    public func addVideoFrameObserver(_ observer: any CaptureVideoFrameObserver, width: Int32, height: Int32, frameRate: Double) {
        frames.add(observer, width: width, height: height, frameRate: frameRate, hasAdaptor: true)
    }

    public func removeVideoFrameObserver(_ observer: any CaptureVideoFrameObserver) {
        frames.remove(observer)
    }

    // MARK: State

    public func whenReady(_ completion: @escaping @MainActor (CaptureSourceFailure?) -> Void) {
        backend.whenReady(completion)
    }

    public func start() {
        if isProducingData || isEnded {
            return
        }
        isProducingData = true
        backend.startProducingData()
        if !isProducingData {
            return
        }
        forEachObserver { $0.captureSourceStarted() }
    }

    public func stop() {
        if !isProducingData || isEnded {
            return
        }
        isProducingData = false
        backend.stopProducingData()
    }

    public func requestToEnd(_ callingObserver: any CaptureSourceObserver) {
        if liveObservers().contains(where: { $0.captureSourcePreventsEnding() }) {
            return
        }
        end(callingObserver)
    }

    public func endImmediately() {
        end(nil)
    }

    private func end(_ callingObserver: (any CaptureSourceObserver)?) {
        if isEnded {
            return
        }
        backend.endProducingData()
        isEnded = true
        didEnd()
        let calling = callingObserver.map { ObjectIdentifier($0) }
        forEachObserver {
            if ObjectIdentifier($0) != calling {
                $0.captureSourceStopped()
            }
        }
    }

    public func captureFailed() {
        captureDidFail = true
        endImmediately()
    }

    public var interrupted: Bool {
        backend.isInterrupted
    }

    public func setMuted(_ muted: Bool) {
        let changed = self.muted != muted
        if changed && !muted && isProducingData {
            stop()
        }
        self.muted = muted
        if muted {
            stop()
        } else {
            start()
        }
        if changed {
            forEachObserver { $0.captureSourceMutedChanged() }
        }
    }

    // RealtimeMediaSource::notifyMutedChange(), for an interruption.
    func notifyMutedChange(_ muted: Bool) {
        if self.muted == muted {
            return
        }
        self.muted = muted
        forEachObserver { $0.captureSourceMutedChanged() }
    }

    func configurationChanged() {
        forEachObserver { $0.captureSourceConfigurationChanged() }
    }

    func audioUnitWillStart() {
        forEachObserver { $0.captureSourceAudioUnitWillStart() }
    }

    func setName(_ name: Swift.String, persistentID: Swift.String) {
        self.name = name
        self.persistentID = persistentID
    }

    public func setIsInBackground(_ isInBackground: Bool) {
        backend.setIsInBackground(isInBackground)
    }

    public var isPowerEfficient: Bool {
        backend.isPowerEfficient
    }

    public func setShouldApplyRotation() {
        frames.isApplyingRotation.store(true, ordering: .relaxed)
    }

    public var videoFrameRotation: UInt16 {
        backend.videoFrameRotation
    }

    public func monitorOrientation(_ orientation: Int32) {
        backend.monitorOrientation(orientation)
    }

    public func orientationChanged(_ orientation: Int32) {
        backend.orientationChanged(orientation)
    }

    public func rotationAngleForHorizonLevelDisplayChanged(_ persistentID: Swift.String, _ rotation: UInt16) {
        guard persistentID == self.persistentID else {
            return
        }
        backend.rotationAngleForHorizonLevelDisplayChanged(rotation)
    }

    public func delaySamples(_ seconds: Double) {
        backend.delaySamples(seconds)
    }

    // MARK: Settings

    public func settings() -> CaptureSettings {
        backend.settings()
    }

    public func capabilities() -> CaptureCapabilities {
        backend.capabilities()
    }

    public func resizedVideoFrameSize(_ desired: WebCore.CaptureSourceSize, _ actual: WebCore.CaptureSourceSize) -> WebCore.CaptureSourceSize {
        frames.resizedVideoFrameSize(desired, actual)
    }

    public var size: WebCore.CaptureSourceSize {
        WebCore.CaptureSourceDecisions.resolvedSize(requestedSize, intrinsicSize)
    }

    func notifySettingsDidChange(_ flags: CaptureSettingsFlags) {
        settingsCapabilitiesUpdateCount += 1
        backend.settingsDidChange(flags)
        if pendingSettingsDidChangeNotification {
            return
        }
        pendingSettingsDidChangeNotification = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.pendingSettingsDidChangeNotification = false
                self.forEachObserver { $0.captureSourceSettingsChanged() }
            }
        }
    }

    func setSize(_ size: WebCore.CaptureSourceSize) {
        if size.width == requestedSize.width && size.height == requestedSize.height {
            return
        }
        requestedSize = size
        notifySettingsDidChange([.width, .height])
    }

    func setIntrinsicSize(_ size: WebCore.CaptureSourceSize, notifyObservers: Bool = true) {
        if size.width == intrinsicSize.width && size.height == intrinsicSize.height {
            return
        }
        intrinsicSize = size
        if notifyObservers {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.notifySettingsDidChange([.width, .height])
                }
            }
        }
    }

    func setFrameRate(_ frameRate: Double) {
        if self.frameRate == frameRate {
            return
        }
        self.frameRate = frameRate
        frames.setRequestedFrameRate(frameRate)
        notifySettingsDidChange(.frameRate)
    }

    func setZoom(_ zoom: Double) {
        if self.zoom == zoom {
            return
        }
        self.zoom = zoom
        notifySettingsDidChange(.zoom)
    }

    func setTorch(_ torch: Bool) {
        if self.torch == torch {
            return
        }
        self.torch = torch
        notifySettingsDidChange(.torch)
    }

    func setFacingMode(_ facingMode: CaptureFacingMode) {
        if self.facingMode == facingMode {
            return
        }
        self.facingMode = facingMode
        notifySettingsDidChange(.facingMode)
    }

    func setWhiteBalanceMode(_ mode: CaptureMeteringMode) {
        if whiteBalanceMode == mode {
            return
        }
        whiteBalanceMode = mode
        notifySettingsDidChange(.whiteBalanceMode)
    }

    func setVolume(_ volume: Double) {
        if self.volume == volume {
            return
        }
        self.volume = volume
        notifySettingsDidChange(.volume)
    }

    func setSampleRate(_ sampleRate: Int32) {
        if self.sampleRate == sampleRate {
            return
        }
        self.sampleRate = sampleRate
        notifySettingsDidChange(.sampleRate)
    }

    func setSampleSize(_ sampleSize: Int32) {
        if self.sampleSize == sampleSize {
            return
        }
        self.sampleSize = sampleSize
        notifySettingsDidChange(.sampleSize)
    }

    func setEchoCancellation(_ echoCancellation: Bool) {
        if self.echoCancellation == echoCancellation {
            return
        }
        self.echoCancellation = echoCancellation
        notifySettingsDidChange(.echoCancellation)
    }

    // The values a backend starts with, without notifying the observers.
    func initialize(frameRate: Double? = nil, facingMode: CaptureFacingMode? = nil, size: WebCore.CaptureSourceSize? = nil, intrinsicSize: WebCore.CaptureSourceSize? = nil, volume: Double? = nil, sampleRate: Int32? = nil, echoCancellation: Bool? = nil) {
        if let frameRate {
            self.frameRate = frameRate
            frames.setRequestedFrameRate(frameRate)
        }
        if let facingMode {
            self.facingMode = facingMode
        }
        if let size {
            requestedSize = size
        }
        if let intrinsicSize {
            self.intrinsicSize = intrinsicSize
        }
        if let volume {
            self.volume = volume
        }
        if let sampleRate {
            self.sampleRate = sampleRate
        }
        if let echoCancellation {
            self.echoCancellation = echoCancellation
        }
    }

    // MARK: Frames

    // A frame the backend produced, on any thread: RealtimeVideoCaptureSource::dispatchVideoFrameToObservers().
    nonisolated func videoFrameAvailable(_ frame: CaptureFrame, captureTime: Double) {
        frames.noteFrameTime(frame.frame.presentationTime().toDouble())
        frames.deliver(frame, captureTime: captureTime, observedFrameRate: frames.frameRateForDecimation)
    }

    // MARK: Presets

    func presets() -> [CapturePreset] {
        if let cachedPresets {
            return cachedPresets
        }
        let presets = backend.presets().map { preset in
            var preset = preset
            preset.frameRateRanges.sort { $0.minimum < $1.minimum }
            return preset
        }
        cachedPresets = presets
        return presets
    }

    func presetsDidChange() {
        cachedPresets = nil
    }

    var canBePowerEfficient: Bool {
        let presets = presets()
        return presets.contains(where: \.isEfficient) && presets.contains(where: { !$0.isEfficient })
    }

    var currentPresetIsEfficient: Bool {
        currentPreset?.isEfficient ?? false
    }

    // RealtimeVideoCaptureSource::updateCapabilities().
    func updateVideoCapabilities(_ capabilities: inout WebCore.CaptureCapabilityValues) {
        var ranges = WebCore.CaptureVideoCapabilityRanges()
        for preset in presets() {
            ranges.addPreset(preset.width, preset.height, preset.minZoom, preset.maxZoom, preset.frameRateRanges.map(\.maximum).max() ?? 0)
        }
        let values = ranges.ranges(backend.canResizeVideoFrames)
        guard values.widthMax != 0 else {
            return
        }
        capabilities.widthMin = values.widthMin
        capabilities.widthMax = values.widthMax
        capabilities.heightMin = values.heightMin
        capabilities.heightMax = values.heightMax
        capabilities.aspectRatioMin = values.aspectRatioMin
        capabilities.aspectRatioMax = values.aspectRatioMax
        capabilities.frameRateMin = values.frameRateMin
        capabilities.frameRateMax = values.frameRateMax
        capabilities.zoomMin = values.zoomMin
        capabilities.zoomMax = values.zoomMax
    }

    // The presets and their frame rate ranges, as the constraint engine reads them.
    private func presetTable() -> (presets: [WebCore.MediaVideoPresetValues], ranges: [WebCore.MediaFrameRateRangeValues]) {
        var presetValues: [WebCore.MediaVideoPresetValues] = []
        var ranges: [WebCore.MediaFrameRateRangeValues] = []
        for preset in presets() {
            presetValues.append(WebCore.MediaVideoPresetValues(minZoom: preset.minZoom, maxZoom: preset.maxZoom, width: preset.width, height: preset.height, firstFrameRate: UInt32(ranges.count), frameRateCount: UInt32(preset.frameRateRanges.count), isEfficient: preset.isEfficient))
            for range in preset.frameRateRanges {
                ranges.append(WebCore.MediaFrameRateRangeValues(minimum: range.minimum, maximum: range.maximum))
            }
        }
        return (presetValues, ranges)
    }

    // MARK: Constraints

    // What the constraint engine reads of this source besides the constraints.
    private func constraintSourceValues() -> WebCore.CaptureConstraintsSourceValues {
        var values = WebCore.CaptureConstraintsSourceValues()
        values.capabilities = constraintCapabilities(capabilities())
        let size = self.size
        values.width = size.width
        values.height = size.height
        values.frameRate = frameRate
        values.zoom = zoom
        values.volume = volume
        values.sampleRate = sampleRate
        values.sampleSize = sampleSize
        values.facingModeFitnessScoreAdjustment = backend.facingModeFitnessScoreAdjustment
        values.isCamera = device.kind == .camera
        values.usesPresets = !presets().isEmpty
        values.canResizeVideoFrames = backend.canResizeVideoFrames
        return values
    }

    private func evaluate(_ constraints: WebCore.CaptureConstraints, _ purpose: WebCore.MediaConstraintsEvaluationPurpose) -> WebCore.MediaConstraintsEvaluation {
        let table = presetTable()
        let presets: Span<WebCore.MediaVideoPresetValues> = table.presets.span
        let ranges: Span<WebCore.MediaFrameRateRangeValues> = table.ranges.span
        return WebCore.evaluateCaptureConstraints(constraints, captureWTFString(hashedID), captureWTFString(settings().groupId), constraintSourceValues(), presets, ranges, purpose)
    }

    // RealtimeMediaSource::hasAnyInvalidConstraint(), which notes the fitness score.
    public func invalidConstraint(_ constraints: WebCore.CaptureConstraints) -> UInt8? {
        let evaluation = evaluate(constraints, .FitnessScore)
        if evaluation.hasInvalidConstraint {
            return evaluation.invalidConstraint.rawValue
        }
        fitnessScore = evaluation.fitnessScore
        return nil
    }

    // RealtimeMediaSource::extractVideoPresetConstraints().
    public func videoPresetConstraints(_ constraints: WebCore.CaptureConstraints) -> WebCore.MediaVideoPresetConstraints {
        let evaluation = evaluate(constraints, .VideoPresetConstraints)
        if evaluation.hasInvalidConstraint {
            return WebCore.MediaVideoPresetConstraints()
        }
        return evaluation.videoPresetConstraints
    }

    // RealtimeVideoCaptureSource::applyConstraints(): after the operations in flight.
    public func applyConstraints(_ constraints: WebCore.CaptureConstraints, completion: @escaping @MainActor (CaptureConstraintsFailure?) -> Void) {
        if isVideo && (captureInFlight || !pendingOperations.isEmpty) {
            pendingOperations.append(.constraints(constraints, completion))
            return
        }
        completion(applyConstraintsNow(constraints))
    }

    // RealtimeMediaSource::applyConstraints().
    public func applyConstraintsNow(_ constraints: WebCore.CaptureConstraints) -> CaptureConstraintsFailure? {
        let evaluation = evaluate(constraints, .Application)
        if evaluation.hasInvalidConstraint {
            return CaptureConstraintsFailure(invalidConstraint: evaluation.invalidConstraint.rawValue, message: "Invalid constraint")
        }
        applyEvaluatedConstraints(evaluation)
        return nil
    }

    private func applyEvaluatedConstraints(_ evaluation: WebCore.MediaConstraintsEvaluation) {
        guard evaluation.hasConstraintsToApply else {
            return
        }
        backend.startApplyingConstraints()
        let presetConstraints = evaluation.videoPresetConstraints
        if presetConstraints.hasWidth || presetConstraints.hasHeight || presetConstraints.hasFrameRate || presetConstraints.hasZoom {
            setSizeFrameRateAndZoom(presetConstraints)
        }
        if evaluation.setsSampleRate {
            setSampleRate(evaluation.sampleRate)
        }
        if evaluation.setsSampleSize {
            setSampleSize(evaluation.sampleSize)
        }
        if evaluation.setsVolume {
            setVolume(evaluation.volume)
        }
        if evaluation.setsEchoCancellation {
            setEchoCancellation(evaluation.echoCancellation)
        }
        if evaluation.setsFacingMode, let mode = CaptureFacingMode(rawValue: evaluation.facingMode) {
            setFacingMode(mode)
        }
        if evaluation.setsWhiteBalanceMode, let mode = CaptureMeteringMode(rawValue: evaluation.whiteBalanceMode) {
            setWhiteBalanceMode(mode)
        }
        if evaluation.setsTorch {
            setTorch(evaluation.torch)
        }
        backend.endApplyingConstraints()
    }

    // RealtimeMediaSource::setSizeFrameRateAndZoom(), or RealtimeVideoCaptureSource's for a source with presets.
    private func setSizeFrameRateAndZoom(_ constraints: WebCore.MediaVideoPresetConstraints) {
        if backend.isDisplay {
            // A display captures at full size and lets each video frame observer resize.
            if constraints.hasFrameRate && constraints.frameRate > frameRate {
                setFrameRate(constraints.frameRate)
            }
            return
        }
        if presets().isEmpty {
            var size = WebCore.CaptureSourceSize()
            if constraints.hasWidth {
                size.width = constraints.width
            }
            if constraints.hasHeight {
                size.height = constraints.height
            }
            setSize(size)
            if constraints.hasFrameRate {
                setFrameRate(constraints.frameRate)
            }
            if constraints.hasZoom {
                setZoom(constraints.zoom)
            }
            return
        }
        guard let match = bestPreset(constraints) else {
            return
        }
        let preset = presets()[Int(match.presetIndex)]
        currentPreset = preset
        applyFrameRateAndZoom(frameRate: match.frameRate, zoom: match.zoom, preset: preset)
        setSize(WebCore.CaptureSourceSize(width: preset.width, height: preset.height))
        setFrameRate(match.frameRate)
        setZoom(match.zoom)
    }

    private func applyFrameRateAndZoom(frameRate: Double, zoom: Double, preset: CapturePreset?) {
        if backend.applyFrameRateAndZoom(frameRate: frameRate, zoom: zoom, preset: preset), let preset {
            currentPreset = preset
            setIntrinsicSize(WebCore.CaptureSourceSize(width: preset.width, height: preset.height))
        }
    }

    // RealtimeVideoCaptureSource::bestSupportedSizeFrameRateAndZoomConsideringObservers().
    private func bestPreset(_ constraints: WebCore.MediaVideoPresetConstraints) -> WebCore.MediaVideoPresetMatch? {
        let settings = self.settings()
        var search = WebCore.MediaVideoPresetSearch()
        search.constraints = constraints
        search.hasSeveralVideoFrameObserversWithAdaptors = frames.observersWithAdaptorCount > 1
        search.settingsWidth = Int32(truncatingIfNeeded: settings.width)
        search.settingsHeight = Int32(truncatingIfNeeded: settings.height)
        search.settingsFrameRate = Double(settings.frameRate)
        let size = self.size
        search.width = size.width
        search.height = size.height
        search.frameRate = frameRate
        search.zoom = zoom
        search.canResizeVideoFrames = backend.canResizeVideoFrames
        let table = presetTable()
        let presets: Span<WebCore.MediaVideoPresetValues> = table.presets.span
        let ranges: Span<WebCore.MediaFrameRateRangeValues> = table.ranges.span
        let match = WebCore.bestCaptureVideoPreset(presets, ranges, search)
        return match.found ? match : nil
    }

    // MARK: Photos

    // RealtimeVideoCaptureSource::takePhoto().
    public func takePhoto(_ settings: CapturePhotoSettings, completion: @escaping @MainActor (Result<(Data, Swift.String), CaptureSourceFailure>) -> Void) {
        if isEnded {
            completion(.success((Data(), "")))
            return
        }
        var settings = settings
        if (settings.imageHeight != nil) != (settings.imageWidth != nil) {
            let sanitized = WebCore.CaptureSourceDecisions.photoSize(settings.imageWidth ?? 0, settings.imageHeight ?? 0, intrinsicSize)
            settings.imageHeight = Double(sanitized.height)
            settings.imageWidth = Double(sanitized.width)
        }
        pendingOperations.append(.photo(settings, completion))
        if !captureInFlight {
            dispatchNextOperation()
        }
    }

    private func dispatchNextOperation() {
        while case .constraints(let constraints, let completion)? = pendingOperations.first {
            pendingOperations.removeFirst()
            completion(applyConstraintsNow(constraints))
        }
        guard case .photo(let settings, let completion)? = pendingOperations.first else {
            return
        }
        pendingOperations.removeFirst()
        captureInFlight = true

        var newPreset: CapturePreset?
        var newMatch: WebCore.MediaVideoPresetMatch?
        if settings.imageHeight != nil || settings.imageWidth != nil {
            var constraints = WebCore.MediaVideoPresetConstraints()
            if let width = settings.imageWidth {
                constraints.hasWidth = true
                constraints.width = captureDimension(width)
            }
            if let height = settings.imageHeight {
                constraints.hasHeight = true
                constraints.height = captureDimension(height)
            }
            if let match = bestPreset(constraints) {
                let preset = presets()[Int(match.presetIndex)]
                if currentPreset?.width != preset.width || currentPreset?.height != preset.height {
                    newPreset = preset
                    newMatch = match
                }
            }
        }

        var restore: (preset: CapturePreset?, size: WebCore.CaptureSourceSize, frameRate: Double, zoom: Double)?
        if let newPreset, let newMatch {
            restore = (currentPreset, size, frameRate, zoom)
            if !muted {
                setMuted(true)
                mutedForPhotoCapture = true
            }
            setSizeFrameRateAndZoomForPhoto(preset: newPreset, frameRate: newMatch.frameRate, zoom: newMatch.zoom)
        }

        backend.takePhoto(settings) { [weak self] result in
            guard let self else {
                completion(result)
                return
            }
            captureInFlight = false
            if let restore {
                setSizeFrameRateAndZoomForPhoto(preset: restore.preset, frameRate: restore.frameRate, zoom: restore.zoom)
                if mutedForPhotoCapture {
                    mutedForPhotoCapture = false
                    setMuted(false)
                }
            }
            completion(result)
            if !pendingOperations.isEmpty {
                dispatchNextOperation()
            }
        }
    }

    private func setSizeFrameRateAndZoomForPhoto(preset: CapturePreset?, frameRate: Double, zoom: Double) {
        currentPreset = preset
        backend.startApplyingConstraints()
        applyFrameRateAndZoom(frameRate: frameRate, zoom: zoom, preset: preset)
        if let preset {
            setSize(WebCore.CaptureSourceSize(width: preset.width, height: preset.height))
        }
        backend.endApplyingConstraints()
    }

    // RealtimeVideoCaptureSource::didEnd().
    private func didEnd() {
        let pending = pendingOperations
        pendingOperations = []
        for operation in pending {
            switch operation {
            case .photo(_, let completion):
                completion(.failure(CaptureSourceFailure(message: "Track ended", denialReason: 0)))
            case .constraints(_, let completion):
                completion(nil)
            }
        }
    }

    public func photoCapabilities() -> CapturePhotoCapabilities? {
        backend.photoCapabilities()
    }

    public func photoSettings() -> CapturePhotoSettings? {
        backend.photoSettings()
    }
}

// A WTF::String for the C++ that the capture sources call.
func captureWTFString(_ string: Swift.String) -> WTF.String {
    WTF.String(string as CFString)
}

// MediaConstraintsCapabilities, as MediaConstraintsEvaluation.cpp flattens a RealtimeMediaSourceCapabilities.
private func constraintCapabilities(_ capabilities: CaptureCapabilities) -> WebCore.MediaConstraintsCapabilities {
    var values = WebCore.MediaConstraintsCapabilities()
    values.width = WebCore.MediaIntRange(min: capabilities.width.min, max: capabilities.width.max)
    values.height = WebCore.MediaIntRange(min: capabilities.height.min, max: capabilities.height.max)
    values.sampleRate = WebCore.MediaIntRange(min: capabilities.sampleRate.min, max: capabilities.sampleRate.max)
    values.sampleSize = WebCore.MediaIntRange(min: capabilities.sampleSize.min, max: capabilities.sampleSize.max)
    values.aspectRatio = WebCore.MediaDoubleRange(min: capabilities.aspectRatio.min, max: capabilities.aspectRatio.max)
    values.frameRate = WebCore.MediaDoubleRange(min: capabilities.frameRate.min, max: capabilities.frameRate.max)
    values.volume = WebCore.MediaDoubleRange(min: capabilities.volume.min, max: capabilities.volume.max)
    values.zoom = WebCore.MediaDoubleRange(min: capabilities.zoom.min, max: capabilities.zoom.max)
    for mode in capabilities.facingModes {
        values.facingModes |= UInt8(1) << mode.rawValue
    }
    for mode in capabilities.whiteBalanceModes {
        values.whiteBalanceModes |= UInt8(1) << mode.rawValue
    }
    values.echoCancellation = capabilities.echoCancellation.rawValue
    values.torch = capabilities.torch
    let supported = capabilities.supportedConstraints
    values.supportsWidth = supported.contains(.width)
    values.supportsHeight = supported.contains(.height)
    values.supportsAspectRatio = supported.contains(.aspectRatio)
    values.supportsFrameRate = supported.contains(.frameRate)
    values.supportsZoom = supported.contains(.zoom)
    values.supportsVolume = supported.contains(.volume)
    values.supportsSampleRate = supported.contains(.sampleRate)
    values.supportsSampleSize = supported.contains(.sampleSize)
    values.supportsFacingMode = supported.contains(.facingMode)
    values.supportsEchoCancellation = supported.contains(.echoCancellation)
    values.supportsDeviceId = supported.contains(.deviceId)
    values.supportsWhiteBalanceMode = supported.contains(.whiteBalanceMode)
    values.supportsTorch = supported.contains(.torch)
    values.supportsBackgroundBlur = supported.contains(.backgroundBlur)
    return values
}

// MARK: Factory

// The sources RealtimeMediaSourceCenter's factories make for the GPU process: the mocks while
// MockRealtimeMediaSourceCenter is enabled, otherwise AVFoundation's cameras and ScreenCaptureKit's displays.
// Microphones aren't made here yet (UserMediaCaptureMicrophones in WebKit).
@_spi(WebKitGPU) @MainActor public enum CaptureSourceFactory {
    public static func create(device: CaptureDeviceDescription, pageIdentifier: UInt64) -> Result<CaptureSource, CaptureSourceFailure> {
        let usesMocks = WebCore.MockRealtimeMediaSourceCenter.mockRealtimeMediaSourceCenterEnabled()
        switch device.kind {
        case .camera:
            return usesMocks ? createMockCamera(device, pageIdentifier) : createCamera(device, pageIdentifier)
        case .screen, .window:
            return usesMocks ? createMockDisplay(device, pageIdentifier) : createDisplay(device, pageIdentifier)
        case .microphone:
            return .failure(CaptureSourceFailure(message: "No microphone source", denialReason: CaptureSourceFailure.permissionDenied))
        }
    }

    private static func createMockCamera(_ device: CaptureDeviceDescription, _ pageIdentifier: UInt64) -> Result<CaptureSource, CaptureSourceFailure> {
        switch MockCameraBackend.create(persistentID: device.persistentID) {
        case .success(let backend):
            let source = CaptureSource(device: device, pageIdentifier: pageIdentifier, backend: backend)
            backend.initialize(source)
            return .success(source)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    // AVVideoCaptureSource::create().
    private static func createCamera(_ device: CaptureDeviceDescription, _ pageIdentifier: UInt64) -> Result<CaptureSource, CaptureSourceFailure> {
#if HAVE_AVCAPTUREDEVICE
        guard let backend = CameraCaptureBackend.create(uniqueID: device.persistentID) else {
            return .failure(CaptureSourceFailure(message: "No AVVideoCaptureSource device", denialReason: CaptureSourceFailure.permissionDenied))
        }
        let source = CaptureSource(device: device, pageIdentifier: pageIdentifier, backend: backend)
        let capabilities = source.capabilities()
        if capabilities.width.max == 0 || capabilities.height.max == 0 || capabilities.frameRate.max == 0 {
            return .failure(CaptureSourceFailure(message: "AVVideoCaptureSource device has invalid width, height or frameRate capabilities", denialReason: CaptureSourceFailure.permissionDenied))
        }
        return .success(source)
#else
        return .failure(CaptureSourceFailure(message: "No AVVideoCaptureSource device", denialReason: CaptureSourceFailure.permissionDenied))
#endif
    }

    private static func createMockDisplay(_ device: CaptureDeviceDescription, _ pageIdentifier: UInt64) -> Result<CaptureSource, CaptureSourceFailure> {
        let lookup = WebCore.mockDisplayWithPersistentID(captureWTFString(device.persistentID))
        guard lookup.found else {
            return .failure(CaptureSourceFailure(message: "Unable to find mock display device with given persistentID", denialReason: CaptureSourceFailure.permissionDenied))
        }
        let backend = DisplayCaptureBackend.createMock(lookup.display)
        return .success(CaptureSource(device: device, pageIdentifier: pageIdentifier, backend: backend))
    }

    // DisplayCaptureSourceCocoa::create().
    private static func createDisplay(_ device: CaptureDeviceDescription, _ pageIdentifier: UInt64) -> Result<CaptureSource, CaptureSourceFailure> {
#if HAVE_SCREEN_CAPTURE_KIT
        guard WebCore.ScreenCaptureKitSharingSession.isFrameworkAvailable() else {
            return .failure(CaptureSourceFailure(message: "ScreenCaptureKit is unavailable", denialReason: CaptureSourceFailure.permissionDenied))
        }
        guard let deviceID = UInt32(device.persistentID) else {
            return .failure(CaptureSourceFailure(message: "Invalid display device ID", denialReason: CaptureSourceFailure.permissionDenied))
        }
        let backend = DisplayCaptureBackend.create(isWindow: device.kind == .window, deviceID: deviceID)
        return .success(CaptureSource(device: device, pageIdentifier: pageIdentifier, backend: backend))
#else
        return .failure(CaptureSourceFailure(message: "No display capture", denialReason: CaptureSourceFailure.permissionDenied))
#endif
    }
}

#endif
