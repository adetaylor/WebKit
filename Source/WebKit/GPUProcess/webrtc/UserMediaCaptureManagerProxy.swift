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
// tracks, their settings, constraints, photos, frames and audio. The sources are Swift (WebCore's CaptureSource.swift).

import CoreVideo
private import Cxx
import Dispatch
import Foundation
import Synchronization
import WebKit_Internal
@_spi(WebKitGPU) internal import WebCore
import os

// RELEASE_LOG_ERROR(WebRTC, ...).
private var releaseLog: os.Logger {
    os.Logger(WTF.osLog(WebKit.LogChannel.WebRTC()))
}

// MARK: Wire values

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
    private var microphoneDelivery: MicrophoneDelivery?
    // A microphone's unit is starting (UserMediaCaptureManagerProxy::microphoneUnitWillStart()).
    var audioUnitWillStart: (@MainActor () -> Void)?

    init(identifier: IPCTypes.RealtimeMediaSourceIdentifier, connection: IPC.Connection, source: CaptureSource, framePublisher: CaptureFramePublisher) {
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

    private var isMicrophone: Bool {
        source.device.kind == .microphone
    }

    func unobserveMedia() {
        guard isObservingMedia else {
            return
        }
        isObservingMedia = false
        if isMicrophone {
            removeMicrophoneDelivery()
            return
        }
        source.removeVideoFrameObserver(frameSender)
    }

    func observeMedia() {
        guard !isObservingMedia else {
            return
        }
        isObservingMedia = true
        if isMicrophone {
            if let microphoneDelivery {
                source.addMicrophoneSink(microphoneDelivery.sink)
            } else {
                prepareMicrophoneDelivery()
            }
            return
        }
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
        if isMicrophone {
            prepareMicrophoneDelivery()
        }
        observeMedia()
    }

    // UserMediaCaptureManagerProxySourceProxy::prepareAudioSink(): a sink of the microphone's format, with a ring for the
    // web process, or, without a format yet, a sink that waits for the unit's. The old sink goes first, as invalidating it
    // waits for the IO thread to finish with the old ring and semaphore.
    private func prepareMicrophoneDelivery() {
        removeMicrophoneDelivery()
        let delivery = MicrophoneDelivery(connection: connection, identifier: identifier, format: source.microphoneFormat)
        delivery.sink.formatChangedHandler = { [weak self] in
            guard let self, self.microphoneDelivery != nil else {
                return
            }
            self.prepareMicrophoneDelivery()
        }
        microphoneDelivery = delivery
        if isObservingMedia {
            source.addMicrophoneSink(delivery.sink)
        }
    }

    private func removeMicrophoneDelivery() {
        guard let delivery = microphoneDelivery.take() else {
            return
        }
        source.removeMicrophoneSink(delivery.sink)
        delivery.sink.invalidate()
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
        precondition(WTF.isMainThread())
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
        UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceStopped(on: connection, to: 0, id: identifier, didFail: source.captureDidFail)
    }

    func captureSourceMutedChanged() {
        UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceMutedChanged(on: connection, to: 0, id: identifier, muted: source.muted, interrupted: source.interrupted)
    }

    func captureSourceSettingsChanged() {
        cachedSettings = nil
        UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceSettingsChanged(on: connection, to: 0, id: identifier, settings: wireSettings(settings()))
    }

    func captureSourceConfigurationChanged() {
        if isObservingMedia && (source.device.kind == .screen || source.device.kind == .window), let videoConstraints, updateVideoConstraints(videoConstraints) {
            source.removeVideoFrameObserver(frameSender)
            source.addVideoFrameObserver(frameSender, width: widthConstraint, height: heightConstraint, frameRate: frameRateConstraint)
        }
        cachedSettings = nil
        UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.sourceConfigurationChanged(on: connection, to: 0, id: identifier, persistentID: source.persistentID, settings: wireSettings(settings()), capabilities: wireCapabilities(source.capabilities()))
    }

    func captureSourceAudioUnitWillStart() {
        audioUnitWillStart?()
    }

    func captureSourcePreventsEnding() -> Bool {
        !isEnded
    }
}

// A microphone source proxy's producer sink, and the ring it stores into, which the web process reads once the first quantum
// is stored, as UserMediaCaptureManagerProxySourceProxy had them. The sink keeps the ring and its semaphore right until it is
// gone; invalidating it waits for the IO thread to finish with them.
@MainActor
private final class MicrophoneDelivery {
    let sink: MicrophoneSink
    private let semaphore: CaptureAudioSemaphore?

    init(connection: IPC.Connection, identifier: IPCTypes.RealtimeMediaSourceIdentifier, format: AudioStreamBasicDescription?) {
        sink = MicrophoneSink(format: format ?? AudioStreamBasicDescription())
        guard let format else {
            semaphore = nil
            return
        }
        // A ring of 2 seconds of the format.
        guard let ring = SharedAudioProducerRing(format: format, frameCount: UInt64(format.mSampleRate * 2)),
            let entry = ring.makeReadOnlyMemoryEntry(),
            let audioSemaphore = CaptureAudioSemaphore(),
            let semaphoreRight = AudioSemaphoreRight(port: audioSemaphore.port)
        else {
            releaseLog.error("UserMediaCaptureAudioStorage: unable to allocate the ring")
            semaphore = nil
            return
        }
        semaphore = audioSemaphore
        let memory = IPCTypes.SharedMemoryHandle(copying: entry.port, size: entry.size)
        // Safety: the entry's port is the right that makeReadOnlyMemoryEntry() gave this, which the handle has copied.
        unsafe WTF.deallocateSendRightSafely(entry.port)
        let frameChunkSize = WebKit.userMediaCaptureAudioFrameChunkSize()
        let wireFormat = IPCTypes.AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: format.mFormatID,
            mFormatFlags: format.mFormatFlags,
            mBytesPerPacket: format.mBytesPerPacket,
            mFramesPerPacket: format.mFramesPerPacket,
            mBytesPerFrame: format.mBytesPerFrame,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: format.mBitsPerChannel,
            mReserved: format.mReserved
        )
        sink.attach(ring: ring, semaphore: semaphoreRight, frameChunkSize: frameChunkSize)
        var pending: PendingStorage? = PendingStorage(
            handle: IPCTypes.ConsumerSharedCARingBufferHandle(memory: memory, frameCount: ring.frameCount),
            semaphore: IPCTypes.Semaphore(copying: audioSemaphore.port)
        )
        sink.startedHandler = { timeValue, timeScale in
            guard let storage = pending.take() else {
                return
            }
            UserMediaCaptureManagerProxy.RemoteCaptureSampleManagerMessages.audioStorageChanged(
                on: connection,
                to: 0,
                id: identifier,
                storageHandle: storage.handle,
                description: IPCTypes.CAAudioStreamDescription(streamDescription: wireFormat),
                captureSemaphore: storage.semaphore,
                mediaTime: IPCTypes.MediaTime(timeValue: timeValue, timeScale: timeScale, timeFlags: 1),
                frameChunkSize: frameChunkSize
            )
        }
    }

    isolated deinit {
        sink.invalidate()
    }
}

// What a microphone's ring is sent to the web process with, once.
private struct PendingStorage: ~Copyable {
    var handle: IPCTypes.ConsumerSharedCARingBufferHandle
    var semaphore: IPCTypes.Semaphore
}

// The semaphore a microphone's producer sink signals for the web process (IPC::Semaphore), destroyed when this goes.
private final class CaptureAudioSemaphore: Sendable {
    let port: semaphore_t

    init?() {
        var semaphore = semaphore_t()
        // Safety: mach_task_self_ is set before any Swift code runs, and never changes. semaphore_create() only writes the
        // semaphore, before it returns.
        guard unsafe semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS else {
            return nil
        }
        port = semaphore
    }

    deinit {
        // Safety: as in init. The semaphore is this object's own, which only this deinit destroys.
        _ = unsafe semaphore_destroy(mach_task_self_, port)
    }
}

// The video frames of a source proxy, on the thread the source produces them on: each is tagged with the web process's
// identity and added to the frame heap, or sent as a pixel buffer without a heap, as
// UserMediaCaptureManagerProxySourceProxy::videoFrameAvailable() does.
final class CaptureFrameSender: CaptureVideoFrameObserver {
    private let identifier: IPCTypes.RealtimeMediaSourceIdentifier
    private let connection: IPC.Connection
    private let publisher: CaptureFramePublisher

    init(identifier: IPCTypes.RealtimeMediaSourceIdentifier, connection: IPC.Connection, publisher: CaptureFramePublisher) {
        self.identifier = identifier
        self.connection = connection
        self.publisher = publisher
    }

    func captureVideoFrameAvailable(_ frame: CaptureFrame, captureTime: Double) {
        let videoFrame = frame.frame
        if let resourceOwner = publisher.resourceOwner {
            videoFrame.setOwnershipIdentity(resourceOwner)
        }
        let frameProperties = WebCore.captureFrameValues(videoFrame)
        let metadata = IPCTypes.VideoFrameTimeMetadata(processingDuration: nil, captureTime: captureTime, receiveTime: nil, rtpTimestamp: nil)
        let presentationTime = IPCTypes.MediaTime(timeValue: frameProperties.timeValue, timeScale: frameProperties.timeScale, timeFlags: frameProperties.timeFlags)
        let rotationValue = frameProperties.rotation
        let rotation = IPCTypes.VideoFrameRotation(rawValue: rotationValue) ?? .none
        let pixelBuffer = WebCore.captureFramePixelBuffer(videoFrame)
        guard let heap = publisher.heap else {
            // Safety: the frame keeps its pixel buffer, which keeps its IOSurface, while the right to it is made.
            let surface = pixelBuffer.flatMap { unsafe CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }.map { IPCTypes.MachSendRight(surface: $0) } ?? IPCTypes.MachSendRight()
            UserMediaCaptureManagerProxy.RemoteCaptureSampleManagerMessages.videoFrameAvailableCV(on: connection, to: 0, id: identifier, pixelBuffer: consume surface, rotation: rotation, mirrored: frameProperties.isMirrored, presentationTime: presentationTime, metadata: metadata)
            return
        }
        guard let frameIdentifier = IPCTypes.RemoteVideoFrameIdentifier(rawValue: heap.lend(pixelBuffer, rotation: rotationValue, isMirrored: frameProperties.isMirrored)) else {
            return
        }
        let properties = IPCTypes.RemoteVideoFrameProxyProperties(
            presentationTime: presentationTime,
            isMirrored: frameProperties.isMirrored,
            rotation: rotation,
            size: IPCTypes.IntSize(width: frameProperties.width, height: frameProperties.height),
            pixelFormat: frameProperties.pixelFormat,
            colorSpace: IPCTypes.PlatformVideoColorSpace(frameProperties.colorSpace),
            shouldIgnoreAlpha: frameProperties.shouldIgnoreAlpha
        )
        let reference = IPCTypes.RemoteVideoFrameReference(identifier: frameIdentifier, version: 0)
        UserMediaCaptureManagerProxy.RemoteCaptureSampleManagerMessages.videoFrameAvailable(on: connection, to: 0, id: identifier, reference: reference, sample: properties, metadata: metadata)
    }
}

// What a source proxy's frames are published with: the frame heap they are lent through, if the web process reads them
// from it, else their pixel buffers' IOSurfaces are sent; and the web process's identity, which their IOSurfaces are
// attributed to, if it has one. @unchecked Sendable: the heap is Sendable, and the identity is never changed once made, so
// any thread may read it.
final class CaptureFramePublisher: @unchecked Sendable {
    let heap: VideoFrameHeap?
    let resourceOwner: WebCore.ProcessIdentity?

    init(heap: VideoFrameHeap?, resourceOwner: WebCore.ProcessIdentity?) {
        self.heap = heap
        self.resourceOwner = resourceOwner
    }
}

// MARK: Receiver state

// What UserMediaCaptureEnvironment found missing.
enum UserMediaCaptureEnvironmentFailure {
    case noAttribution
    case noMediaEnvironment
}

// The capture receiver's sources and pages.
@MainActor
final class UserMediaCaptureManagerProxyState {
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    private var connection: WebKit.GPUConnectionToWebProcess?
    private var proxies: [IPCTypes.RealtimeMediaSourceIdentifier: CaptureSourceProxy] = [:]
    private var pageCameraSources: [UInt64: [() -> CaptureSource?]] = [:]
#if os(iOS) || os(visionOS) || os(tvOS)
    private var pageMicrophones: [UInt64: () -> CaptureSource?] = [:]
#endif
    private var orientation: Int32
    // The web process whose connection this is the capture receiver of.
    private let process: UInt64

    init(connection: WebKit.GPUConnectionToWebProcess, process: UInt64) {
        self.connection = connection
        self.process = process
        orientation = captureEnvironment.orientation
    }

    // The connection, until it closes.
    private var gpuConnection: WebKit.GPUConnectionToWebProcess {
        guard let connection else {
            preconditionFailure("The capture receiver's connection has closed")
        }
        return connection
    }

    // UserMediaCaptureManagerProxy::framePublisher(): the connection's frame heap, if the web process reads the frames from
    // it, and the web process's identity.
    private func framePublisher(usesFrameHeap: Bool) -> CaptureFramePublisher {
        let connection = gpuConnection
        let identity = WebKit.userMediaCaptureResourceOwner(connection)
        return CaptureFramePublisher(heap: usesFrameHeap ? connection.videoFrameObjectHeap().frames : nil, resourceOwner: Bool(fromCxx: identity) ? identity : nil)
    }

    // What the GPU process does for the capture of a page's device, before it starts (GPUProxyForCapture and
    // UserMediaCaptureManagerProxy::applyCaptureEnvironment()).
    private func applyCaptureEnvironment(_ kind: CaptureDeviceKind, _ pageIdentifier: UInt64) -> UserMediaCaptureEnvironmentFailure? {
        let connection = gpuConnection
        guard connection.setCaptureAttributionString() else {
            releaseLog.error("Unable to set capture attribution, failing capture.")
            return .noAttribution
        }
        #if WTF_PLATFORM_IOS_FAMILY
        guard WebKit.applyUserMediaCaptureEnvironment(connection, kind == .camera, pageIdentifier) else {
            releaseLog.error("Unable to set media environment, failing capture.")
            return .noMediaEnvironment
        }
        #endif
        return nil
    }

    private func reapplyCaptureEnvironmentForSource(_ kind: CaptureDeviceKind, _ pageIdentifier: UInt64) {
        if applyCaptureEnvironment(kind, pageIdentifier) != nil {
            releaseLog.error("UserMediaCaptureManagerProxy::reapplyCaptureEnvironment failed for a running capture")
        }
        #if WTF_PLATFORM_IOS_FAMILY
        WebKit.provideUserMediaCapturePresentingApplicationPID(gpuConnection, pageIdentifier)
        #endif
    }

    private func didStartProducingData(_ kind: CaptureDeviceKind, _ pageIdentifier: UInt64) {
        let connection = gpuConnection
        WebKit.userMediaCaptureDidApplyEnvironment(connection, pageIdentifier)
        if kind == .microphone {
            connection.startCapturingAudio()
        }
        #if WTF_PLATFORM_IOS_FAMILY
        if kind == .camera {
            WebKit.userMediaCaptureCameraWillStart(connection, pageIdentifier)
        }
        #endif
    }

    var hasSourceProxies: Bool {
        !proxies.isEmpty
    }

    func close() {
        let proxies = self.proxies
        self.proxies = [:]
        for proxy in proxies.values {
            proxy.stop()
        }
        connection = nil
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

    // The UI process monitors the rotation of the cameras that capture for a page.
    private func monitorRotation(_ pageIdentifier: UInt64, _ persistentID: String, start: Bool) {
        guard let connection, let uiProcessConnection = WebKit.userMediaCaptureUIProcessConnection(connection), let page = IPCTypes.PageIdentifier(rawValue: pageIdentifier) else {
            return
        }
        if start {
            UserMediaCaptureManagerProxy.GPUProcessProxyMessages.startMonitoringCaptureDeviceRotation(
                on: uiProcessConnection,
                to: 0,
                pageID: page,
                devicePersistentId: persistentID,
                reason: .capture
            )
        } else {
            UserMediaCaptureManagerProxy.GPUProcessProxyMessages.stopMonitoringCaptureDeviceRotation(
                on: uiProcessConnection,
                to: 0,
                pageID: page,
                devicePersistentId: persistentID,
                reason: .capture
            )
        }
    }

    // What the UI process allowed the web process to capture.
    private func allowsCapture(_ kind: CaptureDeviceKind) -> Bool {
        guard let access = webProcessConnections[process]?.state.captureAccess else {
            return false
        }
        switch kind {
        case .microphone:
            return access.audio
        case .camera:
            return access.video
        case .screen, .window:
            return access.display
        }
    }

    private func liveCameraSources(_ pageIdentifier: UInt64) -> [CaptureSource] {
        let sources = (pageCameraSources[pageIdentifier] ?? []).compactMap { $0() }
        pageCameraSources[pageIdentifier] = sources.map { source in { [weak source] in source } }
        return sources
    }

    private func addCameraSource(_ source: CaptureSource, _ pageIdentifier: UInt64) {
        guard !liveCameraSources(pageIdentifier).contains(where: { $0 === source }) else {
            return
        }
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
        monitorRotation(pageIdentifier, device.persistentID, start: true)
        addCameraSource(source, pageIdentifier)
        return .success(source)
    }

    func createMediaSource(
        connection: IPC.Connection,
        identifier: IPCTypes.RealtimeMediaSourceIdentifier,
        device: IPCTypes.CaptureDevice,
        hashSalts: IPCTypes.MediaDeviceHashSalts,
        constraints: WebCore.CaptureConstraints?,
        shouldUseGPUProcessRemoteFrames: Bool,
        pageIdentifier: IPCTypes.PageIdentifier
    ) async throws(InvalidMessage) -> (error: IPCTypes.CaptureSourceError, settings: IPCTypes.RealtimeMediaSourceSettings, capabilities: IPCTypes.RealtimeMediaSourceCapabilities) {
        guard let kind = deviceKind(device.type) else {
            return (IPCTypes.CaptureSourceError(errorMessage: "Unsupported device", denialReason: .invalidAccess, invalidConstraint: unknownConstraint), emptySettings, emptyCapabilities)
        }
        guard allowsCapture(kind) else {
            return (IPCTypes.CaptureSourceError(errorMessage: "Request is not allowed", denialReason: .permissionDenied, invalidConstraint: unknownConstraint), emptySettings, emptyCapabilities)
        }
        try messageCheck { proxies[identifier] == nil }

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
        if kind == .microphone {
            addMicrophoneSource(source, pageIdentifier.rawValue)
        }

        // As C++ did, for the sources of video only.
        if kind != .microphone, let constraints, constraints.isValid() {
            try messageCheck { constraints.isWellFormed() }
        }
        let sourceProxy = makeSourceProxy(identifier: identifier, connection: connection, source: source, framePublisher: framePublisher(usesFrameHeap: shouldUseGPUProcessRemoteFrames))
        proxies[identifier] = sourceProxy

        guard let constraints, constraints.isValid() else {
            return await sourceProxy.whenReady()
        }

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

    private func makeSourceProxy(identifier: IPCTypes.RealtimeMediaSourceIdentifier, connection: IPC.Connection, source: CaptureSource, framePublisher: CaptureFramePublisher) -> CaptureSourceProxy {
        let sourceProxy = CaptureSourceProxy(identifier: identifier, connection: connection, source: source, framePublisher: framePublisher)
        if source.device.kind == .microphone {
            let pageIdentifier = source.pageIdentifier
            sourceProxy.audioUnitWillStart = { [weak self] in
                guard let connection = self?.connection else {
                    return
                }
                WebKit.userMediaCaptureMicrophoneUnitWillStart(connection, pageIdentifier)
            }
        }
        return sourceProxy
    }

    // UserMediaCaptureMicrophones::create(): on iOS, a page captures from one microphone at a time.
    private func addMicrophoneSource(_ source: CaptureSource, _ pageIdentifier: UInt64) {
#if os(iOS) || os(visionOS) || os(tvOS)
        // FIXME: Support multiple microphones simultaneously.
        if let microphone = pageMicrophones[pageIdentifier]?(), microphone !== source, microphone.persistentID != source.persistentID, !microphone.isEnded {
            microphone.endImmediately()
        }
        pageMicrophones[pageIdentifier] = { [weak source] in source }
#endif
    }

    func startProducingData(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ pageIdentifier: IPCTypes.PageIdentifier) {
        guard let sourceProxy = proxies[identifier] else {
            return
        }
        let kind = sourceProxy.source.device.kind
        switch applyCaptureEnvironment(kind, pageIdentifier.rawValue) {
        case .noMediaEnvironment:
            sourceProxy.source.captureFailed()
            return
        case .noAttribution:
            return
        case nil:
            break
        }
        didStartProducingData(kind, pageIdentifier.rawValue)
        sourceProxy.start()
    }

    func reapplyCaptureEnvironment(_ pageIdentifier: UInt64) {
        for sourceProxy in proxies.values {
            let source = sourceProxy.source
            guard source.pageIdentifier == pageIdentifier, source.isProducingData else {
                continue
            }
            reapplyCaptureEnvironmentForSource(source.device.kind, pageIdentifier)
            return
        }
    }

    func stopProducingData(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        proxies[identifier]?.stop()
    }

    func removeSource(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        guard let sourceProxy = proxies.removeValue(forKey: identifier) else {
            return
        }
        let source = sourceProxy.source
        if proxies.values.contains(where: { $0.source === source }) {
            return
        }
#if os(iOS) || os(visionOS) || os(tvOS)
        if source.device.kind == .microphone, let microphone = pageMicrophones[source.pageIdentifier]?(), microphone === source {
            pageMicrophones[source.pageIdentifier] = nil
        }
#endif
        guard source.device.kind == .camera else {
            return
        }
        let pageIdentifier = source.pageIdentifier
        let remaining = liveCameraSources(pageIdentifier).filter { $0 !== source }
        pageCameraSources[pageIdentifier] = remaining.map { remainingSource in { [weak remainingSource] in remainingSource } }
        if !remaining.contains(where: { $0.persistentID == source.persistentID && !$0.isEnded }) {
            monitorRotation(pageIdentifier, source.persistentID, start: false)
        }
    }

    func applyConstraints(connection: IPC.Connection, _ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ constraints: WebCore.CaptureConstraints?) throws(InvalidMessage) {
        guard let sourceProxy = proxies[identifier] else {
            UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.applyConstraintsFailed(on: connection, to: 0, id: identifier, invalidConstraint: unknownConstraint, message: "Unknown source")
            return
        }
        guard let constraints else {
            return
        }
        try messageCheck { constraints.isWellFormed() }
        sourceProxy.applyConstraints(constraints) { [weak sourceProxy] failure in
            if let failure {
                UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.applyConstraintsFailed(on: connection, to: 0, id: identifier, invalidConstraint: IPCTypes.MediaConstraintType(rawValue: failure.invalidConstraint) ?? unknownConstraint, message: failure.message)
                return
            }
            guard let sourceProxy else {
                return
            }
            UserMediaCaptureManagerProxy.UserMediaCaptureManagerMessages.applyConstraintsSucceeded(on: connection, to: 0, id: identifier, settings: wireSettings(sourceProxy.settings()))
        }
    }

    func clone(connection: IPC.Connection, _ clonedID: IPCTypes.RealtimeMediaSourceIdentifier, _ cloneID: IPCTypes.RealtimeMediaSourceIdentifier, _ pageIdentifier: IPCTypes.PageIdentifier) throws(InvalidMessage) {
        try messageCheck { proxies[clonedID] != nil }
        try messageCheck { proxies[cloneID] == nil }
        guard let proxyToClone = proxies[clonedID] else {
            return
        }
        let source = proxyToClone.source
        if source.device.kind == .camera {
            addCameraSource(source, pageIdentifier.rawValue)
        }
        let cloneProxy = makeSourceProxy(identifier: cloneID, connection: connection, source: source, framePublisher: framePublisher(usesFrameHeap: true))
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
        proxies[identifier]?.end()
    }

    func setShouldApplyRotation(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) {
        proxies[identifier]?.source.setShouldApplyRotation()
    }

    func setIsInBackground(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier, _ isInBackground: Bool) {
        proxies[identifier]?.source.setIsInBackground(isInBackground)
    }

    func isPowerEfficient(_ identifier: IPCTypes.RealtimeMediaSourceIdentifier) -> Bool {
        proxies[identifier]?.source.isPowerEfficient ?? false
    }
}

// MARK: Receiver

// Receives the capture messages of one web process's connection to the GPU process, which owns it (GPUConnectionState).
@_expose(Cxx)
final class UserMediaCaptureManagerProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefUserMediaCaptureManagerProxyMessageForwarder?
    private let state: UserMediaCaptureManagerProxyState

    @_expose(!Cxx)
    @MainActor
    init(connection: WebKit.GPUConnectionToWebProcess, process: UInt64) {
        state = UserMediaCaptureManagerProxyState(connection: connection, process: process)
        messageForwarder = WebKit.UserMediaCaptureManagerProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefUserMediaCaptureManagerProxyMessageForwarder {
        guard let messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @_expose(!Cxx)
    @MainActor
    var captureState: UserMediaCaptureManagerProxyState {
        state
    }

    @MainActor
    func createMediaSourceForCaptureDeviceWithConstraints(
        connection: IPC.Connection,
        id: IPCTypes.RealtimeMediaSourceIdentifier,
        device: IPCTypes.CaptureDevice,
        hashSalts: IPCTypes.MediaDeviceHashSalts,
        constraints: WebCore.CaptureConstraints,
        shouldUseGPUProcessRemoteFrames: Bool,
        pageIdentifier: IPCTypes.PageIdentifier
    ) async throws(InvalidMessage) -> (error: IPCTypes.CaptureSourceError, settings: IPCTypes.RealtimeMediaSourceSettings, capabilities: IPCTypes.RealtimeMediaSourceCapabilities) {
        try await state.createMediaSource(connection: connection, identifier: id, device: device, hashSalts: hashSalts, constraints: constraints, shouldUseGPUProcessRemoteFrames: shouldUseGPUProcessRemoteFrames, pageIdentifier: pageIdentifier)
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
    func applyConstraints(connection: IPC.Connection, id: IPCTypes.RealtimeMediaSourceIdentifier, constraints: WebCore.CaptureConstraints) throws(InvalidMessage) {
        try state.applyConstraints(connection: connection, id, constraints)
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

extension UserMediaCaptureManagerProxy: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        !state.hasSourceProxies
    }

    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        state.close()
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftReapplyCaptureEnvironment(_ pageIdentifier: UInt64) {
        state.userMediaCaptureManager?.captureState.reapplyCaptureEnvironment(pageIdentifier)
    }

    // The sources stop before the connection's frame heap closes.
    @cxx
    @implementation
    @MainActor
    func swiftCloseUserMediaCaptureManager() {
        state.userMediaCaptureManager?.captureState.close()
    }
}

#endif
