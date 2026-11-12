// Copyright (C) 2016-2025 Apple Inc. All rights reserved.
// Copyright (C) 2017-2022 Apple Inc. All rights reserved.
// Copyright (C) 2017-2023 Apple Inc. All rights reserved.
// Copyright (C) 2019 Apple Inc. All rights reserved.
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

// A microphone source of the GPU process: what CoreAudioCaptureSource does for a C++ caller, over a capture unit's
// controller (AudioCaptureController.swift), of which it is a Swift client. CoreAudioCaptureUnit makes the units, and does
// what needs C++: picking the capture device, and iOS's status bar while in the background.

public import CoreAudio
import Dispatch
import WebCore_Private.Core.AudioCaptureControllerHandle
import WebCore_Private.Core.CaptureSourceDecisions
import WebCore_Private.Core.MockVideoSourceHandle

// MARK: Sinks

// A producer sink of a GPU-process microphone (WebCore::AudioCaptureSink, for Swift): it stores the microphone's quanta of
// its format into the ring that its owner attaches by identifier, until it is invalidated, which waits for the IO thread
// to finish with the ring. Its owner keeps the ring until then.
@_spi(WebKitGPU) @MainActor public final class MicrophoneSink {
    public let identifier: UInt64
    public let format: AudioStreamBasicDescription
    // The first stored frame's time, once, as a time value and scale.
    public var startedHandler: (@MainActor (Int64, UInt32) -> Void)?
    // The microphone's quanta have another format, which needs another sink and ring.
    public var formatChangedHandler: (@MainActor () -> Void)?
    private var hasNotifiedStart = false
    private var isValid = true

    public init(format: AudioStreamBasicDescription) {
        self.format = format
        identifier = addCaptureSink(CaptureSink(isProducer: true, format: format))
    }

    isolated deinit {
        invalidate()
    }

    public func invalidate() {
        guard isValid else {
            return
        }
        isValid = false
        removeCaptureSink(identifier)?.detachRing()
    }

    func setEnabled(_ value: Bool) {
        captureSink(identifier)?.setEnabled(value)
    }

    func notifyStartedIfNeeded() {
        guard !hasNotifiedStart, let status = captureSink(identifier)?.status(), status.hasStartTime else {
            return
        }
        hasNotifiedStart = true
        startedHandler?(status.startTimeValue, status.startTimeScale)
    }

    func notifyFormatChanged() {
        formatChangedHandler?()
    }
}

private func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
        && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
        && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBitsPerChannel == b.mBitsPerChannel
}

// MARK: Source

@MainActor
final class MicrophoneCaptureBackend: CaptureSourceBackend, AudioCaptureControllerClient {
    weak var source: CaptureSource?
    private var controllerIdentifier: UInt64
#if os(macOS)
    // A unit without echo cancellation, which this releases.
    private var ownsController = false
#endif
    private let captureDeviceID: UInt32
    // A mock's echo cancellation, which it can't change.
    private let echoCancellationCapability: Bool?
    private var canResumeAfterInterruption = true
    private var shouldInitializeAudioUnit = true
    private var isChangingEchoCancellation = false
    private var hasStartedProducingData = false
    private var sinks: [MicrophoneSink] = []

    init(captureDeviceID: UInt32, echoCancellationCapability: Bool?) {
        controllerIdentifier = WebCore.coreAudioCaptureDefaultController()
        self.captureDeviceID = captureDeviceID
        self.echoCancellationCapability = echoCancellationCapability
    }

    isolated deinit {
        controller?.removeClient(self)
#if os(macOS)
        if ownsController {
            WebCore.coreAudioCaptureReleaseController(controllerIdentifier)
        }
#endif
    }

    private var controller: AudioCaptureController? {
        audioCaptureController(controllerIdentifier)
    }

    private var controllerState: WebCore.AudioCaptureControllerState {
        controller?.state ?? WebCore.AudioCaptureControllerState()
    }

    // The CoreAudioCaptureSource constructor: the unit is reset for a new capture.
    func initialize(_ source: CaptureSource) {
        self.source = source
        controller?.prepareForNewCapture()
        let state = controllerState
        source.initialize(volume: state.volume, sampleRate: state.sampleRate, echoCancellation: echoCancellationCapability ?? state.enableEchoCancellation)
    }

#if os(macOS)
    private func useController(withEchoCancellation echoCancellation: Bool) {
        if ownsController {
            WebCore.coreAudioCaptureReleaseController(controllerIdentifier)
        }
        ownsController = !echoCancellation
        controllerIdentifier = echoCancellation ? WebCore.coreAudioCaptureDefaultController() : WebCore.coreAudioCaptureCreateControllerWithoutEchoCancellation()
    }
#endif

    // CoreAudioCaptureSource::initializeToStartProducingData().
    private func initializeToStartProducingData() {
        guard shouldInitializeAudioUnit, let source else {
            return
        }
        shouldInitializeAudioUnit = false

#if os(macOS)
        if source.echoCancellation != controllerState.enableEchoCancellation {
            useController(withEchoCancellation: source.echoCancellation)
        }
#endif
        guard let controller else {
            return
        }
        // The client goes first, as changing the capture device can reconfigure the unit.
        controller.addClient(self)
        WebCore.coreAudioCaptureUnitSetCaptureDevice(controllerIdentifier, captureWTFString(source.persistentID), captureDeviceID, source.device.isDefault)

        let state = controller.state
        let shouldReconfigure = source.echoCancellation != state.enableEchoCancellation || source.sampleRate != state.sampleRate || source.volume != state.volume
#if !os(macOS)
        controller.setEnableEchoCancellation(source.echoCancellation)
#endif
        controller.setSampleRate(Int(source.sampleRate))
        controller.setVolume(source.volume)
        if shouldReconfigure {
            controller.reconfigure()
        }
    }

    // MARK: CaptureSourceBackend

    func startProducingData() {
        canResumeAfterInterruption = true
        initializeToStartProducingData()
        controller?.startProducingData()
        controller?.updateSwiftMicrophoneConfiguration()
    }

    func stopProducingData() {
        controller?.stopProducingData()
        controller?.updateSwiftMicrophoneConfiguration()
    }

    func endProducingData() {
        guard let controller else {
            return
        }
        controller.removeClient(self)
        if source?.isProducingData ?? false {
            controller.stopProducingData()
        }
    }

    func settings() -> CaptureSettings {
        guard let source else {
            return CaptureSettings()
        }
        let state = controllerState
        let values = WebCore.AudioCaptureControllerHandle.microphoneSettings(source.volume, state.isRenderingAudio ? state.actualSampleRate : source.sampleRate, source.echoCancellation)
        return CaptureSettings(values, label: source.name, deviceId: source.hashedID, groupId: source.hashedGroupID)
    }

    func capabilities() -> CaptureCapabilities {
        guard let source else {
            return CaptureCapabilities()
        }
        let echoCancellation: CaptureEchoCancellationCapability = echoCancellationCapability.map { $0 ? .on : .off } ?? .onOrOff
        let sampleRates = WebCore.coreAudioCaptureUnitSampleRateRange(controllerIdentifier)
        let supportedConstraints = WebCore.AudioCaptureControllerHandle.microphoneSettings(0, 0, false).supportedConstraints
        let values = WebCore.AudioCaptureControllerHandle.microphoneCapabilities(supportedConstraints, echoCancellation.rawValue, sampleRates.minimum, sampleRates.maximum)
        return CaptureCapabilities(values, deviceId: source.hashedID, groupId: source.hashedGroupID)
    }

    // CoreAudioCaptureSource::settingsDidChange().
    func settingsDidChange(_ flags: CaptureSettingsFlags) {
        if shouldInitializeAudioUnit || isChangingEchoCancellation {
            return
        }
        guard let source, let controller else {
            return
        }
        var shouldReconfigure = false
        if flags.contains(.echoCancellation) {
#if os(macOS)
            changeAudioUnit()
            return
#else
            controller.setEnableEchoCancellation(source.echoCancellation)
            shouldReconfigure = true
#endif
        }
        if flags.contains(.sampleRate) {
            controller.setSampleRate(Int(source.sampleRate))
            shouldReconfigure = true
        }
        if shouldReconfigure {
            controller.reconfigure()
        }
    }

#if os(macOS)
    // CoreAudioCaptureSource::changeAudioUnit(): the unit with or without echo cancellation, as the source has.
    private func changeAudioUnit() {
        guard let source else {
            return
        }
        controller?.removeClient(self)
        if source.isProducingData {
            controller?.stopProducingData()
        }
        useController(withEchoCancellation: source.echoCancellation)
        shouldInitializeAudioUnit = true
        if source.isProducingData {
            startProducingData()
        }
    }
#endif

    var isInterrupted: Bool {
        controllerState.isSuspended
    }

    func setIsInBackground(_ isInBackground: Bool) {
#if !os(macOS)
        if source?.isProducingData ?? false {
            WebCore.coreAudioCaptureUnitSetIsInBackground(controllerIdentifier, isInBackground)
        }
#endif
    }

    func delaySamples(_ seconds: Double) {
        controller?.delaySamples(seconds)
    }

    var microphoneFormat: AudioStreamBasicDescription? {
        controller?.microphoneFormat
    }

    func addMicrophoneSink(_ sink: MicrophoneSink) {
        sinks.append(sink)
        controller?.updateSwiftMicrophoneConfiguration()
    }

    func removeMicrophoneSink(_ sink: MicrophoneSink) {
        sinks.removeAll { $0 === sink }
        controller?.updateSwiftMicrophoneConfiguration()
    }

    // MARK: AudioCaptureControllerClient

    var isProducingMicrophoneData: Bool {
        source?.isProducingData ?? false
    }

    var needsFirstMicrophoneQuantum: Bool {
        isProducingMicrophoneData && !hasStartedProducingData
    }

    var microphoneSinks: [MicrophoneSink] {
        sinks
    }

    func audioCaptureControllerDidChange(_ event: WebCore.AudioCaptureControllerEvent) {
        guard let source else {
            return
        }
        switch event {
        case .UnitWillStart:
            source.audioUnitWillStart()
        case .CaptureFailed:
            source.captureFailed()
        case .Suspended:
            canResumeAfterInterruption = source.isProducingData
            source.setMuted(true)
        case .Resumed:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let source = self.source, !self.controllerState.isSuspended, self.canResumeAfterInterruption else {
                        return
                    }
                    source.setMuted(false)
                }
            }
        case .EchoCancellationChanged:
            echoCancellationChanged()
        case .MicrophoneFormatChanged:
            guard let format = microphoneFormat else {
                return
            }
            for sink in sinks where !sameFormat(sink.format, format) {
                sink.notifyFormatChanged()
            }
        case .FirstMicrophoneQuantum:
            if source.isProducingData {
                hasStartedProducingData = true
            }
        case .SinkStarted:
            for sink in sinks {
                sink.notifyStartedIfNeeded()
            }
        default:
            break
        }
    }

    func audioCaptureDeviceDidChange(_ event: WebCore.AudioCaptureDeviceEvent, persistentID: Swift.String, label: Swift.String) {
        guard let source, source.isProducingData, source.persistentID != persistentID else {
            return
        }
        switch event {
        case .VPIOUnitWillChangeCaptureDevice:
#if os(macOS)
            // CoreAudioCaptureSource::vpioUnitWillChangeCaptureDeviceTo(): capture moves to a unit without echo
            // cancellation, so that only one voice processing unit runs.
            guard source.echoCancellation else {
                return
            }
            isChangingEchoCancellation = true
            source.setEchoCancellation(false)
            isChangingEchoCancellation = false
            changeAudioUnit()
            source.configurationChanged()
#endif
        case .NewCurrentMicrophoneDevice:
            // CoreAudioCaptureSource::handleNewCurrentMicrophoneDevice().
            source.setName(label, persistentID: persistentID)
            source.configurationChanged()
        @unknown default:
            break
        }
    }

    // CoreAudioCaptureSource::echoCancellationChanged().
    private func echoCancellationChanged() {
        guard let source, source.isProducingData else {
            return
        }
        let enableEchoCancellation = controllerState.enableEchoCancellation
        if source.echoCancellation == enableEchoCancellation {
            return
        }
        isChangingEchoCancellation = true
        source.setEchoCancellation(enableEchoCancellation)
        isChangingEchoCancellation = false
        source.configurationChanged()
    }
}

// MARK: Factory

extension MicrophoneCaptureBackend {
    // CoreAudioCaptureSource::create(), and MockRealtimeAudioSource::create() while MockRealtimeMediaSourceCenter is enabled.
    static func create(_ device: CaptureDeviceDescription, usesMocks: Bool) -> Result<MicrophoneCaptureBackend, CaptureSourceFailure> {
        if usesMocks {
            let microphone = WebCore.mockMicrophone(WebCore.mockDeviceHandle(captureWTFString(device.persistentID)))
            guard microphone.found else {
                return .failure(CaptureSourceFailure(message: "No mock microphone device", denialReason: CaptureSourceFailure.permissionDenied))
            }
            return .success(MicrophoneCaptureBackend(captureDeviceID: microphone.deviceID, echoCancellationCapability: microphone.hasEchoCancellation ? microphone.echoCancellation : nil))
        }
#if os(macOS)
        guard let deviceID = audioCaptureMicrophoneDeviceID(device.persistentID) else {
            return .failure(CaptureSourceFailure(message: "No CoreAudioCaptureSource device", denialReason: CaptureSourceFailure.permissionDenied))
        }
        return .success(MicrophoneCaptureBackend(captureDeviceID: deviceID, echoCancellationCapability: nil))
#else
        guard WebCore.audioCaptureSessionHasMicrophone(captureWTFString(device.persistentID), device.isDefault) else {
            return .failure(CaptureSourceFailure(message: "No AVAudioSessionCaptureDevice device", denialReason: CaptureSourceFailure.permissionDenied))
        }
        return .success(MicrophoneCaptureBackend(captureDeviceID: 0, echoCancellationCapability: nil))
#endif
    }
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM
