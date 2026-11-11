// Copyright (C) 2017-2025 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS && ENABLE_MEDIA_STREAM

// The capture receiver of one web process's connection to the GPU process: the sources it creates for the web process's
// tracks, their settings, constraints, photos and frames. The sources are Swift (WebCore's CaptureSource.swift); the
// microphones still go through UserMediaCaptureMicrophoneProxy, the C++ that the microphone's unit needs until it is
// Swift.

import Dispatch
import Foundation
import Synchronization
import WebKit_Internal
@_spi(WebKitGPU) internal import WebCore

// MARK: Wire values

private func swiftString(_ string: borrowing WTF.String) -> String {
    IPCCoding.WTFString.swiftString(string) ?? ""
}

// MediaAccessDenialReason::NoReason and MediaConstraintType::Unknown.
private let noDenialReason = IPCTypes.MediaAccessDenialReason.noReason
private let unknownConstraint = IPCTypes.MediaConstraintType.unknown

private func captureSourceError(_ failure: CaptureSourceFailure) -> IPCTypes.CaptureSourceError {
    IPCTypes.CaptureSourceError(
        errorMessage: failure.message,
        denialReason: IPCTypes.MediaAccessDenialReason(rawValue: failure.denialReason) ?? .otherFailure,
        invalidConstraint: IPCTypes.MediaConstraintType(rawValue: failure.invalidConstraint) ?? unknownConstraint
    )
}

private let noCaptureSourceError = IPCTypes.CaptureSourceError(errorMessage: nil, denialReason: noDenialReason, invalidConstraint: unknownConstraint)

private func supportedConstraints(_ constraints: CaptureSupportedConstraints) -> IPCTypes.RealtimeMediaSourceSupportedConstraints {
    IPCTypes.RealtimeMediaSourceSupportedConstraints(
        supportsWidth: constraints.contains(.width),
        supportsHeight: constraints.contains(.height),
        supportsAspectRatio: constraints.contains(.aspectRatio),
        supportsFrameRate: constraints.contains(.frameRate),
        supportsFacingMode: constraints.contains(.facingMode),
        supportsVolume: constraints.contains(.volume),
        supportsSampleRate: constraints.contains(.sampleRate),
        supportsSampleSize: constraints.contains(.sampleSize),
        supportsEchoCancellation: constraints.contains(.echoCancellation),
        supportsDeviceId: constraints.contains(.deviceId),
        supportsGroupId: constraints.contains(.groupId),
        supportsDisplaySurface: constraints.contains(.displaySurface),
        supportsLogicalSurface: constraints.contains(.logicalSurface),
        supportsFocusDistance: constraints.contains(.focusDistance),
        supportsWhiteBalanceMode: constraints.contains(.whiteBalanceMode),
        supportsZoom: constraints.contains(.zoom),
        supportsTorch: constraints.contains(.torch),
        supportsBackgroundBlur: constraints.contains(.backgroundBlur),
        supportsPowerEfficient: constraints.contains(.powerEfficient)
    )
}

private func wireSettings(_ settings: CaptureSettings) -> IPCTypes.RealtimeMediaSourceSettings {
    IPCTypes.RealtimeMediaSourceSettings(
        width: settings.width,
        height: settings.height,
        frameRate: settings.frameRate,
        facingMode: IPCTypes.VideoFacingMode(rawValue: settings.facingMode.rawValue) ?? .unknown,
        volume: settings.volume,
        sampleRate: settings.sampleRate,
        sampleSize: settings.sampleSize,
        echoCancellation: settings.echoCancellation,
        deviceId: settings.deviceId,
        groupId: settings.groupId,
        label: settings.label,
        displaySurface: IPCTypes.DisplaySurfaceType(rawValue: settings.displaySurface.rawValue) ?? .invalid,
        logicalSurface: settings.logicalSurface,
        whiteBalanceMode: IPCTypes.MeteringMode(rawValue: settings.whiteBalanceMode.rawValue) ?? IPCTypes.MeteringMode(rawValue: 0)!,
        zoom: settings.zoom,
        torch: settings.torch,
        backgroundBlur: settings.backgroundBlur,
        powerEfficient: settings.powerEfficient,
        supportedConstraints: supportedConstraints(settings.supportedConstraints)
    )
}

private func longRange(_ range: CaptureRange<Int32>) -> IPCTypes.LongCapabilityRange {
    IPCTypes.LongCapabilityRange(min: range.min, max: range.max)
}

private func doubleRange(_ range: CaptureRange<Double>) -> IPCTypes.DoubleCapabilityRange {
    IPCTypes.DoubleCapabilityRange(min: range.min, max: range.max)
}

private func wireCapabilities(_ capabilities: CaptureCapabilities) -> IPCTypes.RealtimeMediaSourceCapabilities {
    IPCTypes.RealtimeMediaSourceCapabilities(
        width: longRange(capabilities.width),
        height: longRange(capabilities.height),
        aspectRatio: doubleRange(capabilities.aspectRatio),
        frameRate: doubleRange(capabilities.frameRate),
        facingMode: capabilities.facingModes.compactMap { IPCTypes.VideoFacingMode(rawValue: $0.rawValue) },
        volume: doubleRange(capabilities.volume),
        sampleRate: longRange(capabilities.sampleRate),
        sampleSize: longRange(capabilities.sampleSize),
        echoCancellation: IPCTypes.EchoCancellation(rawValue: capabilities.echoCancellation.rawValue) ?? .on,
        deviceId: capabilities.deviceId,
        groupId: capabilities.groupId,
        focusDistance: doubleRange(capabilities.focusDistance),
        whiteBalanceModes: capabilities.whiteBalanceModes.compactMap { IPCTypes.MeteringMode(rawValue: $0.rawValue) },
        zoom: doubleRange(capabilities.zoom),
        torch: capabilities.torch,
        backgroundBlur: IPCTypes.BackgroundBlur(rawValue: capabilities.backgroundBlur.rawValue) ?? .off,
        powerEfficient: capabilities.powerEfficient,
        supportedConstraints: supportedConstraints(capabilities.supportedConstraints)
    )
}

private let emptyCapabilities = wireCapabilities(CaptureCapabilities())
private let emptySettings = wireSettings(CaptureSettings())

private func capturePhotoSettings(_ settings: IPCTypes.PhotoSettings) -> CapturePhotoSettings {
    CapturePhotoSettings(
        fillLightMode: settings.fillLightMode.flatMap { CaptureFillLightMode(rawValue: $0.rawValue) },
        imageHeight: settings.imageHeight,
        imageWidth: settings.imageWidth,
        redEyeReduction: settings.redEyeReduction
    )
}

private func wirePhotoSettings(_ settings: CapturePhotoSettings) -> IPCTypes.PhotoSettings {
    IPCTypes.PhotoSettings(
        fillLightMode: settings.fillLightMode.flatMap { IPCTypes.FillLightMode(rawValue: $0.rawValue) },
        imageHeight: settings.imageHeight,
        imageWidth: settings.imageWidth,
        redEyeReduction: settings.redEyeReduction
    )
}

private func wireRange(_ range: CaptureSettingsRange?) -> IPCTypes.MediaSettingsRange? {
    range.map { IPCTypes.MediaSettingsRange(max: $0.max, min: $0.min, step: $0.step) }
}

private func wirePhotoCapabilities(_ capabilities: CapturePhotoCapabilities) -> IPCTypes.PhotoCapabilities {
    IPCTypes.PhotoCapabilities(
        redEyeReduction: capabilities.redEyeReduction.flatMap { IPCTypes.RedEyeReduction(rawValue: $0) },
        imageHeight: wireRange(capabilities.imageHeight),
        imageWidth: wireRange(capabilities.imageWidth),
        fillLightMode: capabilities.fillLightMode?.compactMap { IPCTypes.FillLightMode(rawValue: $0.rawValue) }
    )
}

private func deviceKind(_ type: IPCTypes.DeviceType) -> CaptureDeviceKind? {
    switch type {
    case .microphone:
        return .microphone
    case .camera, .canvas:
        return .camera
    case .screen:
        return .screen
    case .window:
        return .window
    default:
        return nil
    }
}

// CaptureDevice::DeviceType, for the C++ GPU runtime.
private func cxxDeviceType(_ kind: CaptureDeviceKind) -> WebCore.CaptureDevice.DeviceType {
    switch kind {
    case .microphone:
        return .Microphone
    case .camera:
        return .Camera
    case .screen:
        return .Screen
    case .window:
        return .Window
    }
}

// MARK: Source proxy

// The GPU process's end of a web process's track: UserMediaCaptureManagerProxySourceProxy, for a Swift source.
@MainActor
final class CaptureSourceProxy: CaptureSourceObserver {
    let identifier: IPCTypes.RealtimeMediaSourceIdentifier
    let source: CaptureSource
    private let connection: IPC.Connection
    private let frameSender: CaptureFrameSender
    private var isObservingMedia = false
    private var isEnded = false
    private var cachedSettings: CaptureSettings?
    private var widthConstraint: Int32 = 0
    private var heightConstraint: Int32 = 0
    private var frameRateConstraint: Double = 0
    private var videoConstraints: WebCore.CaptureConstraints?
    private var pendingActions: [() -> Void] = []
    private var isApplyingConstraints = false

    init(identifier: IPCTypes.RealtimeMediaSourceIdentifier, connection: IPC.Connection, source: CaptureSource, framePublisher: WebKit.UserMediaCaptureFramePublisher) {
        self.identifier = identifier
        self.connection = connection
        self.source = source
        frameSender = CaptureFrameSender(identifier: identifier, connection: connection, publisher: framePublisher)
        source.addObserver(self)
    }

    isolated deinit {
        unobserveMedia()
        source.removeObserver(self)
    }

    var isUsingSource: CaptureSource {
        source
    }

    func unobserveMedia() {
        guard isObservingMedia else {
            return
        }
        isObservingMedia = false
        source.removeVideoFrameObserver(frameSender)
    }

    func observeMedia() {
        guard !isObservingMedia else {
            return
        }
        isObservingMedia = true
        if widthConstraint != 0 || heightConstraint != 0 || frameRateConstraint != 0 {
            source.addVideoFrameObserver(frameSender, width: widthConstraint, height: heightConstraint, frameRate: frameRateConstraint)
        } else {
            source.addVideoFrameObserver(frameSender)
        }
    }

    var observesMedia: Bool {
        isObservingMedia
    }

    func whenReady() async -> (error: IPCTypes.CaptureSourceError, settings: IPCTypes.RealtimeMediaSourceSettings, capabilities: IPCTypes.RealtimeMediaSourceCapabilities) {
        let failure: CaptureSourceFailure? = await withCheckedContinuation { continuation in
            source.whenReady { failure in
                continuation.resume(returning: failure)
            }
        }
        if let failure {
            return (captureSourceError(failure), emptySettings, emptyCapabilities)
        }
        return (noCaptureSourceError, wireSettings(settings()), wireCapabilities(source.capabilities()))
    }

    func start() {
        // A web process may send StartProducingData repeatedly.
        if isObservingMedia {
            return
        }
        source.start()
        observeMedia()
    }

    func stop() {
        source.stop()
        unobserveMedia()
    }

    func end() {
        isEnded = true
        source.requestToEnd(self)
    }

    // UserMediaCaptureManagerProxySourceProxy::updateVideoConstraints().
    @discardableResult
    private func updateVideoConstraints(_ constraints: WebCore.CaptureConstraints) -> Bool {
        videoConstraints = constraints
        let resulting = source.videoPresetConstraints(constraints)
        var didChange = false
        if resulting.hasWidth {
            didChange = didChange || widthConstraint != resulting.width
            widthConstraint = resulting.width
        } else if resulting.hasHeight {
            didChange = didChange || widthConstraint != 0
            widthConstraint = 0
        }
        if resulting.hasHeight {
            didChange = didChange || heightConstraint != resulting.height
            heightConstraint = resulting.height
        } else if resulting.hasWidth {
            didChange = didChange || heightConstraint != 0
            heightConstraint = 0
        }
        if resulting.hasFrameRate {
            didChange = didChange || frameRateConstraint != resulting.frameRate
            frameRateConstraint = resulting.frameRate
        } else {
            didChange = didChange || frameRateConstraint != 0
            frameRateConstraint = 0
        }
        return didChange
    }

    // queueAndProcessSerialAction(): one action at a time, in order.
    private func queueAction(_ action: @escaping () -> Void) {
        pendingActions.append(action)
        if pendingActions.count == 1 {
            action()
        }
    }

    private func actionDidFinish() {
        pendingActions.removeFirst()
        if let next = pendingActions.first {
            next()
        }
    }

    func applyConstraints(_ constraints: WebCore.CaptureConstraints, completion: @escaping @MainActor (CaptureConstraintsFailure?) -> Void) {
        queueAction { [weak self] in
            guard let self else {
                completion(CaptureConstraintsFailure(invalidConstraint: 0, message: ""))
                return
            }
            guard source.isVideo else {
                source.applyConstraints(constraints) { failure in
                    completion(failure)
                }
                actionDidFinish()
                return
            }
            let wasObservingMedia = isObservingMedia
            unobserveMedia()
            source.applyConstraints(constraints) { [weak self] failure in
                guard let self else {
                    completion(CaptureConstraintsFailure(invalidConstraint: 0, message: ""))
                    return
                }
                if failure == nil {
                    updateVideoConstraints(constraints)
                    cachedSettings = nil
                }
                if wasObservingMedia {
                    observeMedia()
                }
                completion(failure)
            }
            actionDidFinish()
        }
    }

    // UserMediaCaptureManagerProxySourceProxy::settings(): a video source's settings at the size and frame rate of its
    // constraints.
    func settings() -> CaptureSettings {
        guard source.isVideo else {
            return source.settings()
        }
        if let cachedSettings {
            return cachedSettings
        }
        var settings = source.settings()
        if widthConstraint != 0 || heightConstraint != 0 {
            var desired = source.resizedVideoFrameSize(WebCore.CaptureSourceSize(width: widthConstraint, height: heightConstraint), source.intrinsicSize)
            // VideoFrameRotation::Left and Right.
            if source.videoFrameRotation == 270 || source.videoFrameRotation == 90 {
                desired = WebCore.CaptureSourceSize(width: desired.height, height: desired.width)
            }
            settings.width = UInt32(truncatingIfNeeded: desired.width)
            settings.height = UInt32(truncatingIfNeeded: desired.height)
        }
        if frameRateConstraint != 0 && frameRateConstraint < Double(settings.frameRate) {
            settings.frameRate = Float(frameRateConstraint)
        }
        cachedSettings = settings
        return settings
    }

    func copySettings(from proxy: CaptureSourceProxy) {
        cachedSettings = proxy.cachedSettings
        widthConstraint = proxy.widthConstraint
        heightConstraint = proxy.heightConstraint
        frameRateConstraint = proxy.frameRateConstraint
        videoConstraints = proxy.videoConstraints
    }

    func takePhoto(_ settings: CapturePhotoSettings) async -> Result<(Data, String), CaptureSourceFailure> {
        await withCheckedContinuation { continuation in
            queueAction { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(CaptureSourceFailure(message: "Track has ended", denialReason: 0)))
                    return
                }
                source.takePhoto(settings) { [weak self] result in
                    continuation.resume(returning: result)
                    self?.actionDidFinish()
                }
            }
        }
    }

    // MARK: CaptureSourceObserver

    func captureSourceStarted() {
    }

    func captureSourceStopped() {
        WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceStopped(on: connection, to: 0, id: identifier, didFail: source.captureDidFail)
    }

    func captureSourceMutedChanged() {
        WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceMutedChanged(on: connection, to: 0, id: identifier, muted: source.muted, interrupted: source.interrupted)
    }

    func captureSourceSettingsChanged() {
        cachedSettings = nil
        WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceSettingsChanged(on: connection, to: 0, id: identifier, settings: wireSettings(settings()))
    }

    func captureSourceConfigurationChanged() {
        if isObservingMedia && (source.device.kind == .screen || source.device.kind == .window), let videoConstraints, updateVideoConstraints(videoConstraints) {
            source.removeVideoFrameObserver(frameSender)
            source.addVideoFrameObserver(frameSender, width: widthConstraint, height: heightConstraint, frameRate: frameRateConstraint)
        }
        cachedSettings = nil
        WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceConfigurationChanged(on: connection, to: 0, id: identifier, persistentID: source.persistentID, settings: wireSettings(settings()), capabilities: wireCapabilities(source.capabilities()))
    }

    func captureSourceAudioUnitWillStart() {
    }

    func captureSourcePreventsEnding() -> Bool {
        !isEnded
    }
}

// The video frames of a source proxy, on the thread the source produces them on: each is tagged with the web process's
// identity and added to the frame heap, or sent as a pixel buffer without a heap, as
// UserMediaCaptureManagerProxySourceProxy::videoFrameAvailable() does.
final class CaptureFrameSender: CaptureVideoFrameObserver {
    private let identifier: IPCTypes.RealtimeMediaSourceIdentifier
    private let connection: IPC.Connection
    private let publisher: WebKit.UserMediaCaptureFramePublisher

    init(identifier: IPCTypes.RealtimeMediaSourceIdentifier, connection: IPC.Connection, publisher: WebKit.UserMediaCaptureFramePublisher) {
        self.identifier = identifier
        self.connection = connection
        self.publisher = publisher
    }

    func captureVideoFrameAvailable(_ frame: CaptureFrame, captureTime: Double) {
        let published = publisher.publish(frame.frame)
        let metadata = IPCTypes.VideoFrameTimeMetadata(processingDuration: nil, captureTime: captureTime, receiveTime: nil, rtpTimestamp: nil)
        let presentationTime = IPCTypes.MediaTime(timeValue: published.timeValue, timeScale: published.timeScale, timeFlags: published.timeFlags)
        let rotation = IPCTypes.VideoFrameRotation(rawValue: published.rotation) ?? .none
        guard published.hasReference else {
            let surface = WebKit.userMediaCaptureFrameSurface(frame.frame).map { IPCTypes.MachSendRight(surface: $0) } ?? IPCTypes.MachSendRight()
            WebKit.UserMediaCaptureManagerProxy.RemoteCaptureSampleManagerMessages.videoFrameAvailableCV(on: connection, to: 0, id: identifier, pixelBuffer: consume surface, rotation: rotation, mirrored: published.isMirrored, presentationTime: presentationTime, metadata: metadata)
            return
        }
        guard let frameIdentifier = IPCTypes.RemoteVideoFrameIdentifier(rawValue: published.identifier) else {
            return
        }
        let properties = IPCTypes.RemoteVideoFrameProxyProperties(
            presentationTime: presentationTime,
            isMirrored: published.isMirrored,
            rotation: rotation,
            size: IPCTypes.IntSize(width: published.width, height: published.height),
            pixelFormat: published.pixelFormat,
            colorSpace: IPCTypes.PlatformVideoColorSpace(
                primaries: published.hasPrimaries ? IPCTypes.PlatformVideoColorPrimaries(rawValue: published.primaries) : nil,
                transfer: published.hasTransfer ? IPCTypes.PlatformVideoTransferCharacteristics(rawValue: published.transfer) : nil,
                matrix: published.hasMatrix ? IPCTypes.PlatformVideoMatrixCoefficients(rawValue: published.matrix) : nil,
                fullRange: published.hasFullRange ? published.fullRange : nil,
                chromaLocation: published.hasChromaLocation ? IPCTypes.PlatformVideoChromaLocation(rawValue: published.chromaLocation) : nil
            ),
            shouldIgnoreAlpha: published.shouldIgnoreAlpha
        )
        let reference = IPCTypes.RemoteVideoFrameReference(identifier: frameIdentifier, version: published.version)
        WebKit.UserMediaCaptureManagerProxy.RemoteCaptureSampleManagerMessages.videoFrameAvailable(on: connection, to: 0, id: identifier, reference: reference, sample: properties, metadata: metadata)
    }
}

// MARK: Receiver state

// UserMediaCaptureManagerProxy's sources and pages, which m_swiftState holds.
@MainActor
final class UserMediaCaptureManagerProxyState {
    // The C++ receiver, which owns this state: they keep each other alive until the connection closes (close()).
    private var receiver: WebKit.UserMediaCaptureManagerProxy?
    private var proxies: [IPCTypes.RealtimeMediaSourceIdentifier: CaptureSourceProxy] = [:]
    fileprivate var microphones: Set<IPCTypes.RealtimeMediaSourceIdentifier> = []
    private var pageCameraSources: [UInt64: [() -> CaptureSource?]] = [:]
    fileprivate var orientation: Int32 = 0

    init(proxy: WebKit.UserMediaCaptureManagerProxy) {
        receiver = proxy
    }

    // The receiver, until the connection closes.
    private var proxy: WebKit.UserMediaCaptureManagerProxy {
        guard let receiver else {
            preconditionFailure("The capture receiver's connection has closed")
        }
        return receiver
    }

    var hasSourceProxies: Bool {
        !proxies.isEmpty || !microphones.isEmpty
    }

    func close() {
        let proxies = self.proxies
        self.proxies = [:]
        for proxy in proxies.values {
            proxy.stop()
        }
        for identifier in microphones {
            receiver?.microphoneStop(identifier.rawValue)
        }
        microphones = []
        receiver?.microphoneClear()
        receiver = nil
    }

    func clear() {
        proxies = [:]
        microphones = []
        proxy.microphoneClear()
    }

    func setOrientation(_ orientation: Int32) {
        self.orientation = orientation
        for proxy in proxies.values where proxy.source.device.kind == .camera {
            proxy.source.orientationChanged(orientation)
        }
    }

    func rotationAngleForCaptureDeviceChanged(_ persistentID: String, _ rotation: UInt16) {
        for proxy in proxies.values where proxy.source.device.kind == .camera {
            proxy.source.rotationAngleForHorizonLevelDisplayChanged(persistentID, rotation)
        }
    }

    private func liveCameraSources(_ pageIdentifier: UInt64) -> [CaptureSource] {
        let sources = (pageCameraSources[pageIdentifier] ?? []).compactMap { $0() }
        pageCameraSources[pageIdentifier] = sources.map { source in { [weak source] in source } }
        return sources
    }

    private func addCameraSource(_ source: CaptureSource, _ pageIdentifier: UInt64) {
        pageCameraSources[pageIdentifier, default: []].append { [weak source] in source }
    }

    // UserMediaCaptureManagerProxy::createCameraSource(): a camera that is already capturing for the page is shared.
    private func cameraSource(_ device: CaptureDeviceDescription, _ pageIdentifier: UInt64) -> Result<CaptureSource, CaptureSourceFailure> {
        let cameras = liveCameraSources(pageIdentifier)
        if let source = cameras.first(where: { $0.persistentID == device.persistentID && !$0.isEnded }) {
            return .success(source)
        }
        let result = CaptureSourceFactory.create(device: device, pageIdentifier: pageIdentifier)
        guard case .success(let source) = result else {
            return result
        }
#if os(iOS) || os(visionOS) || os(tvOS)
        // FIXME: Support multiple cameras simultaneously.
        for camera in cameras {
            camera.endImmediately()
        }
#endif
        source.monitorOrientation(orientation)
        proxy.startMonitoringCaptureDeviceRotation(pageIdentifier, WTF.String(device.persistentID))
        addCameraSource(source, pageIdentifier)
        return .success(source)
    }

    func createMediaSource(
        connection: IPC.Connection,
        identifier: IPCTypes.RealtimeMediaSourceIdentifier,
        device: IPCTypes.CaptureDevice,
        hashSalts: IPCTypes.MediaDeviceHashSalts,
        constraints: WebCore.CaptureConstraints?,
        constraintsHolder: CxxDecodedArguments.UserMediaCaptureManagerProxy.CreateMediaSourceForCaptureDeviceWithConstraintsConstraints,
        shouldUseGPUProcessRemoteFrames: Bool,
        pageIdentifier: IPCTypes.PageIdentifier
    ) async throws(InvalidMessage) -> (error: IPCTypes.CaptureSourceError, settings: IPCTypes.RealtimeMediaSourceSettings, capabilities: IPCTypes.RealtimeMediaSourceCapabilities) {
        guard let kind = deviceKind(device.type) else {
            return (IPCTypes.CaptureSourceError(errorMessage: "Unsupported device", denialReason: .invalidAccess, invalidConstraint: unknownConstraint), emptySettings, emptyCapabilities)
        }
        guard proxy.willStartCapture(cxxDeviceType(kind), pageIdentifier.rawValue) else {
            return (IPCTypes.CaptureSourceError(errorMessage: "Request is not allowed", denialReason: .permissionDenied, invalidConstraint: unknownConstraint), emptySettings, emptyCapabilities)
        }
        try messageCheck { proxies[identifier] == nil && !microphones.contains(identifier) }

        if kind == .microphone {
            let reply = createMicrophone(identifier, device, hashSalts, constraintsHolder, pageIdentifier)
            if reply.error.denialReason == noDenialReason {
                microphones.insert(identifier)
            }
            return reply
        }

        let description = CaptureDeviceDescription(
            persistentID: device.persistentId ?? "",
            label: device.label ?? "",
            groupID: device.groupId ?? "",
            kind: kind,
            isDefault: device.isDefault,
            isEphemeral: device.isEphemeral,
            persistentDeviceSalt: hashSalts.persistentDeviceSalt ?? "",
            ephemeralDeviceSalt: hashSalts.ephemeralDeviceSalt ?? ""
        )
        let result = kind == .camera ? cameraSource(description, pageIdentifier.rawValue) : CaptureSourceFactory.create(device: description, pageIdentifier: pageIdentifier.rawValue)
        let source: CaptureSource
        switch result {
        case .success(let created):
            source = created
        case .failure(let failure):
            return (captureSourceError(failure), emptySettings, emptyCapabilities)
        }

        let sourceProxy = CaptureSourceProxy(identifier: identifier, connection: connection, source: source, framePublisher: proxy.framePublisher(shouldUseGPUProcessRemoteFrames))
        proxies[identifier] = sourceProxy

        guard let constraints, constraints.isValid() else {
            return await sourceProxy.whenReady()
        }
        try messageCheck { constraints.isWellFormed() }

        let failure: CaptureConstraintsFailure? = await withCheckedContinuation { continuation in
            sourceProxy.applyConstraints(constraints) { failure in
                continuation.resume(returning: failure)
            }
        }
        if let failure {
            return (IPCTypes.CaptureSourceError(errorMessage: nil, denialReason: .invalidConstraint, invalidConstraint: IPCTypes.MediaConstraintType(rawValue: failure.invalidConstraint) ?? unknownConstraint), emptySettings, emptyCapabilities)
        }
        return await sourceProxy.whenReady()
    }

    private func createMicrophone(
        _ identifier: IPCTypes.RealtimeMediaSourceIdentifier,
        _ device: IPCTypes.CaptureDevice,
        _ hashSalts: IPCTypes.MediaDeviceHashSalts,
        _ constraints: CxxDecodedArguments.UserMediaCaptureManagerProxy.CreateMediaSourceForCaptureDeviceWithConstraintsConstraints,
        _ pageIdentifier: IPCTypes.PageIdentifier
    ) -> (error: IPCTypes.CaptureSourceError, settings: IPCTypes.RealtimeMediaSourceSettings, capabilities: IPCTypes.RealtimeMediaSourceCapabilities) {
        let result = proxy.createMicrophone(
            identifier.rawValue,
            IPCCoding.WTFString.cxxString(device.persistentId),
            cxxDeviceType(.microphone),
            IPCCoding.WTFString.cxxString(device.label),
            IPCCoding.WTFString.cxxString(device.groupId),
            device.isDefault,
            device.isEphemeral,
            IPCCoding.WTFString.cxxString(hashSalts.persistentDeviceSalt),
            IPCCoding.WTFString.cxxString(hashSalts.ephemeralDeviceSalt),
            constraints,
            pageIdentifier.rawValue
        )
        if result.denialReason != noDenialReason.rawValue {
            return (IPCTypes.CaptureSourceError(errorMessage: swiftString(result.errorMessage), denialReason: IPCTypes.MediaAccessDenialReason(rawValue: result.denialReason) ?? .otherFailure, invalidConstraint: IPCTypes.MediaConstraintType(rawValue: result.invalidConstraint) ?? unknownConstraint), emptySettings, emptyCapabilities)
        }
        let settings = CaptureSettings(result.settings, label: swiftString(result.label), deviceId: swiftString(result.deviceId), groupId: swiftString(result.groupId))
        let capabilities = CaptureCapabilities(result.capabilities, deviceId: swiftString(result.capabilityDeviceId), groupId: swiftString(result.capabilityGroupId))
        return (noCaptureSourceError, wireSettings(settings), wireCapabilities(capabilities))
    }

    func startProducingData(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ pageIdentifier: IPCTypes.PageIdentifier) {
        if microphones.contains(identifier) {
            proxy.microphoneStart(identifier.rawValue, pageIdentifier.rawValue)
            return
        }
        guard let sourceProxy = proxies[identifier] else {
            return
        }
        let deviceType = cxxDeviceType(sourceProxy.source.device.kind)
        switch proxy.applyCaptureEnvironment(deviceType, pageIdentifier.rawValue) {
        case WebKit.UserMediaCaptureEnvironmentFailure.NoMediaEnvironment:
            sourceProxy.source.captureFailed()
            return
        case WebKit.UserMediaCaptureEnvironmentFailure.NoAttribution:
            return
        default:
            break
        }
        proxy.startProducingData(deviceType, pageIdentifier.rawValue)
        sourceProxy.start()
    }

    func reapplyCaptureEnvironment(_ pageIdentifier: UInt64) {
        for sourceProxy in proxies.values {
            let source = sourceProxy.source
            guard source.pageIdentifier == pageIdentifier, source.isProducingData else {
                continue
            }
            proxy.reapplyCaptureEnvironmentForSource(cxxDeviceType(source.device.kind), pageIdentifier)
            return
        }
        proxy.microphoneReapplyCaptureEnvironment(pageIdentifier)
    }

    func stopProducingData(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        if microphones.contains(identifier) {
            proxy.microphoneStop(identifier.rawValue)
            return
        }
        proxies[identifier]?.stop()
    }

    func removeSource(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        if microphones.remove(identifier) != nil {
            proxy.microphoneRemove(identifier.rawValue)
            return
        }
        guard let sourceProxy = proxies.removeValue(forKey: identifier) else {
            return
        }
        let source = sourceProxy.source
        if proxies.values.contains(where: { $0.source === source }) {
            return
        }
        guard source.device.kind == .camera else {
            return
        }
        let pageIdentifier = source.pageIdentifier
        let remaining = liveCameraSources(pageIdentifier).filter { $0 !== source }
        pageCameraSources[pageIdentifier] = remaining.map { remainingSource in { [weak remainingSource] in remainingSource } }
        if !remaining.contains(where: { $0.persistentID == source.persistentID && !$0.isEnded }) {
            proxy.stopMonitoringCaptureDeviceRotation(pageIdentifier, WTF.String(source.persistentID))
        }
    }

    func applyConstraints(connection: IPC.Connection, _ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ constraints: WebCore.CaptureConstraints?, _ holder: CxxDecodedArguments.UserMediaCaptureManagerProxy.ApplyConstraintsConstraints) throws(InvalidMessage) {
        if microphones.contains(identifier) {
            proxy.microphoneApplyConstraints(identifier.rawValue, holder)
            return
        }
        guard let sourceProxy = proxies[identifier] else {
            WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.applyConstraintsFailed(on: connection, to: 0, id: identifier, invalidConstraint: unknownConstraint, message: "Unknown source")
            return
        }
        guard let constraints else {
            return
        }
        try messageCheck { constraints.isWellFormed() }
        sourceProxy.applyConstraints(constraints) { [weak sourceProxy] failure in
            if let failure {
                WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.applyConstraintsFailed(on: connection, to: 0, id: identifier, invalidConstraint: IPCTypes.MediaConstraintType(rawValue: failure.invalidConstraint) ?? unknownConstraint, message: failure.message)
                return
            }
            guard let sourceProxy else {
                return
            }
            WebKit.UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.applyConstraintsSucceeded(on: connection, to: 0, id: identifier, settings: wireSettings(sourceProxy.settings()))
        }
    }

    func clone(connection: IPC.Connection, _ clonedID: IPCTypes.RealtimeMediaSourceIdentifier, _ cloneID: IPCTypes.RealtimeMediaSourceIdentifier, _ pageIdentifier: IPCTypes.PageIdentifier) throws(InvalidMessage) {
        try messageCheck { proxies[clonedID] != nil || microphones.contains(clonedID) }
        try messageCheck { proxies[cloneID] == nil && !microphones.contains(cloneID) }
        if microphones.contains(clonedID) {
            microphones.insert(cloneID)
            proxy.microphoneClone(clonedID.rawValue, cloneID.rawValue, pageIdentifier.rawValue)
            return
        }
        guard let proxyToClone = proxies[clonedID] else {
            return
        }
        let source = proxyToClone.source
        if source.device.kind == .camera {
            addCameraSource(source, pageIdentifier.rawValue)
        }
        let cloneProxy = CaptureSourceProxy(identifier: cloneID, connection: connection, source: source, framePublisher: proxy.framePublisher(true))
        cloneProxy.copySettings(from: proxyToClone)
        if proxyToClone.observesMedia {
            cloneProxy.observeMedia()
        }
        proxies[cloneID] = cloneProxy
    }

    func takePhoto(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ settings: IPCTypes.PhotoSettings) async -> Result<([UInt8], String?), IPCUnexpected<String?>> {
        guard let sourceProxy = proxies[identifier] else {
            return .failure(IPCUnexpected("Device not available"))
        }
        switch await sourceProxy.takePhoto(capturePhotoSettings(settings)) {
        case .success(let (data, mimeType)):
            return .success(([UInt8](data), mimeType))
        case .failure(let failure):
            return .failure(IPCUnexpected(failure.message))
        }
    }

    func photoCapabilities(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) -> Result<IPCTypes.PhotoCapabilities, IPCUnexpected<String?>> {
        guard let sourceProxy = proxies[identifier] else {
            return .failure(IPCUnexpected("Device not available"))
        }
        guard let capabilities = sourceProxy.source.photoCapabilities() else {
            return .failure(IPCUnexpected("Not supported"))
        }
        return .success(wirePhotoCapabilities(capabilities))
    }

    func photoSettings(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) -> Result<IPCTypes.PhotoSettings, IPCUnexpected<String?>> {
        guard let sourceProxy = proxies[identifier] else {
            return .failure(IPCUnexpected("Device not available"))
        }
        guard let settings = sourceProxy.source.photoSettings() else {
            return .failure(IPCUnexpected("Not supported"))
        }
        return .success(wirePhotoSettings(settings))
    }

    func endProducingData(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        if microphones.contains(identifier) {
            proxy.microphoneEnd(identifier.rawValue)
            return
        }
        proxies[identifier]?.end()
    }

    func setShouldApplyRotation(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        proxies[identifier]?.source.setShouldApplyRotation()
    }

    func setIsInBackground(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ isInBackground: Bool) {
        if microphones.contains(identifier) {
            proxy.microphoneSetIsInBackground(identifier.rawValue, isInBackground)
            return
        }
        proxies[identifier]?.source.setIsInBackground(isInBackground)
    }

    func isPowerEfficient(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) -> Bool {
        proxies[identifier]?.source.isPowerEfficient ?? false
    }
}

// MARK: Receiver

// The members of the C++ receiver that reach its Swift state, which m_swiftState holds retained, by address, from the
// receiver's constructor to its destructor, and the handlers of its messages.
extension WebKit.UserMediaCaptureManagerProxy {
    @cxx
    @implementation
    @MainActor
    func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(UserMediaCaptureManagerProxyState(proxy: self)).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<UserMediaCaptureManagerProxyState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The receiver has no Swift state")
        }
        return unsafe address
    }

    @MainActor
    private var state: UserMediaCaptureManagerProxyState {
        Self.state(m_swiftState)
    }

    @MainActor
    private static func state(_ swiftState: UInt) -> UserMediaCaptureManagerProxyState {
        // Safety: m_swiftState is a retained UserMediaCaptureManagerProxyState from the constructor to the destructor,
        // and nothing else changes it.
        unsafe Unmanaged<UserMediaCaptureManagerProxyState>.fromOpaque(stateAddress(swiftState)).takeUnretainedValue()
    }

    @cxx
    @implementation
    func close() {
        let swiftState = m_swiftState
        MainActor.assumeIsolated {
            Self.state(swiftState).close()
        }
    }

    @cxx
    @implementation
    func clear() {
        let swiftState = m_swiftState
        MainActor.assumeIsolated {
            Self.state(swiftState).clear()
        }
    }

    @cxx
    @implementation
    func setOrientation(_ orientation: Int32) {
        let swiftState = m_swiftState
        MainActor.assumeIsolated {
            Self.state(swiftState).setOrientation(orientation)
        }
    }

    @cxx
    @implementation
    func swiftRotationAngleForCaptureDeviceChanged(_ persistentID: WTF.String, _ rotation: UInt16) {
        let persistentID = swiftString(persistentID)
        let swiftState = m_swiftState
        MainActor.assumeIsolated {
            Self.state(swiftState).rotationAngleForCaptureDeviceChanged(persistentID, rotation)
        }
    }

    @cxx
    @implementation
    func hasSourceProxies() -> Bool {
        let swiftState = m_swiftState
        return MainActor.assumeIsolated {
            Self.state(swiftState).hasSourceProxies
        }
    }

    @cxx
    @implementation
    func swiftReapplyCaptureEnvironment(_ pageIdentifier: UInt64) {
        let swiftState = m_swiftState
        MainActor.assumeIsolated {
            Self.state(swiftState).reapplyCaptureEnvironment(pageIdentifier)
        }
    }

    // MARK: Messages

    @MainActor
    func createMediaSourceForCaptureDeviceWithConstraints(
        connection: IPC.Connection,
        id: IPCTypes.RealtimeMediaSourceIdentifier,
        device: IPCTypes.CaptureDevice,
        hashSalts: IPCTypes.MediaDeviceHashSalts,
        constraints: CxxDecodedArguments.UserMediaCaptureManagerProxy.CreateMediaSourceForCaptureDeviceWithConstraintsConstraints,
        shouldUseGPUProcessRemoteFrames: Bool,
        pageIdentifier: IPCTypes.PageIdentifier
    ) async throws(InvalidMessage) -> (error: IPCTypes.CaptureSourceError, settings: IPCTypes.RealtimeMediaSourceSettings, capabilities: IPCTypes.RealtimeMediaSourceCapabilities) {
        let mediaConstraints = device.type == .microphone ? nil : Self.takeConstraints(constraints)
        return try await state.createMediaSource(connection: connection, identifier: id, device: device, hashSalts: hashSalts, constraints: mediaConstraints, constraintsHolder: constraints, shouldUseGPUProcessRemoteFrames: shouldUseGPUProcessRemoteFrames, pageIdentifier: pageIdentifier)
    }

    @MainActor
    func startProducingData(connection: IPC.Connection, id: IPCTypes.RealtimeMediaSourceIdentifier, pageIdentifier: IPCTypes.PageIdentifier) {
        state.startProducingData(id, pageIdentifier)
    }

    @MainActor
    func stopProducingData(connection: IPC.Connection, id: IPCTypes.RealtimeMediaSourceIdentifier) {
        state.stopProducingData(id)
    }

    @MainActor
    func removeSource(connection: IPC.Connection, id: IPCTypes.RealtimeMediaSourceIdentifier) {
        state.removeSource(id)
    }

    @MainActor
    func applyConstraints(connection: IPC.Connection, id: IPCTypes.RealtimeMediaSourceIdentifier, constraints: CxxDecodedArguments.UserMediaCaptureManagerProxy.ApplyConstraintsConstraints) throws(InvalidMessage) {
        let isMicrophone = state.isMicrophone(id)
        try state.applyConstraints(connection: connection, id, isMicrophone ? nil : Self.takeConstraints(constraints), constraints)
    }

    @MainActor
    func takePhoto(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier, settings: IPCTypes.PhotoSettings) async -> Result<([UInt8], String?), IPCUnexpected<String?>> {
        await state.takePhoto(sourceID, settings)
    }

    @MainActor
    func getPhotoCapabilities(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier) -> Result<IPCTypes.PhotoCapabilities, IPCUnexpected<String?>> {
        state.photoCapabilities(sourceID)
    }

    @MainActor
    func getPhotoSettings(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier) -> Result<IPCTypes.PhotoSettings, IPCUnexpected<String?>> {
        state.photoSettings(sourceID)
    }

    @MainActor
    func clone(connection: IPC.Connection, clonedID: IPCTypes.RealtimeMediaSourceIdentifier, cloneID: IPCTypes.RealtimeMediaSourceIdentifier, pageIdentifier: IPCTypes.PageIdentifier) throws(InvalidMessage) {
        try state.clone(connection: connection, clonedID, cloneID, pageIdentifier)
    }

    @MainActor
    func endProducingData(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier) {
        state.endProducingData(sourceID)
    }

    @MainActor
    func setShouldApplyRotation(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier) {
        state.setShouldApplyRotation(sourceID)
    }

    @MainActor
    func setIsInBackground(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier, isInBackground: Bool) {
        state.setIsInBackground(sourceID, isInBackground)
    }

    @MainActor
    func isPowerEfficient(connection: IPC.Connection, sourceID: IPCTypes.RealtimeMediaSourceIdentifier) -> Bool {
        state.isPowerEfficient(sourceID)
    }
}

extension UserMediaCaptureManagerProxyState {
    func isMicrophone(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) -> Bool {
        microphones.contains(identifier)
    }
}

#endif
