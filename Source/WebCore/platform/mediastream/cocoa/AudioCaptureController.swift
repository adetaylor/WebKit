// Copyright (C) 2019 Apple Inc. All rights reserved.
// Copyright (C) 2017-2023 Apple Inc. All rights reserved.
// Copyright (C) 2024 Apple Inc. All rights reserved.
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

#if HAVE_AVAUDIOAPPLICATION
import AVFAudio
#endif
public import AudioToolbox
#if os(macOS)
import CoreAudio
#endif
import Darwin
import Dispatch
import Foundation
import Synchronization
import WebCore_Private.Core.AudioCaptureControllerHandle
import WebCore_Private.Core.CARingBufferSwiftBridge
#if os(macOS) && HAVE_AVAUDIOAPPLICATION
import WebCore_Private.Core.WebCoreObjCExceptionCatching
#endif
import os
import pal.spi.cf.CoreAudioSPI

// A microphone capture unit, CoreAudioCaptureUnit's and BaseAudioCaptureUnit's logic: it makes, configures, starts,
// reconfigures and stops the capture AudioUnit (AudioCaptureUnit.swift's CaptureUnit), suspends and resumes capture, keeps a
// voice processing unit for the next capture on macOS, mutes the uplink and the microphone, detects voice activity, and
// fails capture that stops producing samples. CoreAudioCaptureUnit holds one by identifier through
// AudioCaptureControllerHandle and keeps what C++ needs: the clients, the capture device's persistent ID, the volume, the
// callbacks and the C++ delivery of the microphone's samples, which it is told about through AudioCaptureControllerHandle.h's
// functions. Main thread only.

private let logger = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

private var outputBus: AudioUnitElement { 0 }
private var inputBus: AudioUnitElement { 1 }

private var lowPriorityError1: OSStatus { 560557684 }
private var lowPriorityError2: OSStatus { 561017449 }
private var voiceActivityThrottlingDuration: Double { 5 }

// The status's four bytes as `%.4s` printed them, up to a zero byte.
private func fourCharacters(_ status: OSStatus) -> Swift.String {
    var characters = ""
    for shift: UInt32 in [0, 8, 16, 24] {
        let byte = UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> shift)
        if byte == 0 {
            break
        }
        characters.unicodeScalars.append(Unicode.Scalar(byte))
    }
    return characters
}

// The C++ int a sample rate converted to.
private func integerSampleRate(_ rate: Double) -> Int {
    guard rate.isFinite else {
        return 0
    }
    return Int(min(max(rate, Double(Int32.min)), Double(Int32.max)))
}

// WebCore::Timer on the main thread: a one-shot or repeating timer that a restart reschedules.
@MainActor
private final class MainThreadTimer {
    private let action: @MainActor () -> Void
    private var source: (any DispatchSourceTimer)?
    private(set) var repeatInterval: Double = 0

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var isActive: Bool {
        source != nil
    }

    func startOneShot(_ interval: Double) {
        start(interval, repeating: false)
    }

    func startRepeating(_ interval: Double) {
        start(interval, repeating: true)
    }

    func stop() {
        source?.cancel()
        source = nil
        repeatInterval = 0
    }

    private func start(_ interval: Double, repeating: Bool) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.fire()
            }
        }
        if repeating {
            repeatInterval = interval
            timer.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            timer.schedule(deadline: .now() + interval)
        }
        timer.resume()
        source = timer
    }

    private func fire() {
        if repeatInterval == 0 {
            source?.cancel()
            source = nil
        }
        action()
    }
}

@MainActor
private var audioCaptureControllers: [UInt64: AudioCaptureController] = [:]

// The default unit, the one that can cancel echo and render audio.
@MainActor
private var defaultAudioCaptureController: AudioCaptureController?

@MainActor
private func defaultController() -> AudioCaptureController {
    guard let controller = defaultAudioCaptureController else {
        preconditionFailure()
    }
    return controller
}

#if os(macOS)
// prewarmAudioUnitCreation()'s NativePromise: the callbacks that wait for the voice processing unit that a queue makes.
private enum AudioUnitCreationWarmup {
    case none
    case pending(UInt64)
    case settled
}
#endif

@MainActor
final class AudioCaptureController {
    let identifier: UInt64
    private let canEnableEchoCancellation: Bool
    private var enableEchoCancellation: Bool
    private var sampleRate: Int
    private var isSuspended = false
    private var needsReconfiguration = false
    private var isRenderingAudio = false
    private var producingCount: Int32 = 0
    private var outputDeviceID: UInt32 = 0
    private var captureDeviceID: UInt32 = 0
    private var isProducingMicrophoneSamples = true
    private var hasVoiceActivityListener = false
    private var voiceActivityThrottleTimer: MainThreadTimer?

    private var usesMockUnit = false
    private var sampleRateOverride: Int?
    private var unit: CaptureUnit?
    private var unitIdentifier: UInt64 = 0
    // The C++ that the microphone delivers its quanta to (deliverToCxxObservers()), as an address.
    private var cxxDeliveryContext: UInt = 0
    private var speakerProcFormat: AudioStreamBasicDescription?
    private var dtsConversionRatio: Double = 0
    private var ioUnitInitialized = false
    private var ioUnitStarted = false
    private var microphoneProcsCalledLastTime: UInt64 = 0
    // What the units released since the capture started counted: reconfiguring replaces the unit, whose count starts at 0.
    private var microphoneProcsCalledByReleasedUnits: UInt64 = 0
    private var verifyCapturingTimer: MainThreadTimer?
    private var updateMutedStateTimer: MainThreadTimer?
    private var minimumMicrophoneSampleFrames: Int?
    private var isReconfiguring = false
    // The track the speaker plays out, and its format, while a producer is registered (the default unit only).
    private var speakerTrack: TrackPlayout?
    private var speakerProducerFormat: AudioStreamBasicDescription?
    private var shouldUseVPIO = true
    private var canRenderAudio = true
    private var voiceActivityDetectionEnabled = false
    // A mock AudioUnit's: whether its output is muted, whether it detects voice activity, which it then fakes, and how long
    // it pauses its samples.
    private var mockOutputMuted = false
    private var mockVoiceActivityDetectionEnabled = false
    private var mockVoiceDetectionTimer: MainThreadTimer?
    private var mockDelayTimer: MainThreadTimer?
#if os(macOS)
    private var hasStoredVPIOUnit = false
    private var storedVPIOUnitDeallocationTimer: MainThreadTimer?
    private var audioUnitCreationWarmup = AudioUnitCreationWarmup.none
    private var audioUnitCreationWarmupCount: UInt64 = 0
    private var audioUnitCreationWarmupCallbacks: [@MainActor @Sendable () -> Void] = []
#endif

    init(identifier: UInt64, canEnableEchoCancellation: Bool) {
        self.identifier = identifier
        self.canEnableEchoCancellation = canEnableEchoCancellation
        enableEchoCancellation = canEnableEchoCancellation
        sampleRate = integerSampleRate(WebCore.audioCaptureSessionSampleRate())
    }

    // ~CoreAudioCaptureUnit(): a unit that is left goes without being kept for the next capture.
    func invalidate() {
        updateVoiceActivityDetection()
        if let unit = unit.take() {
            _ = removeCaptureUnit(unitIdentifier)
            _ = unit.destroy()
        }
        for timer in [voiceActivityThrottleTimer, verifyCapturingTimer, updateMutedStateTimer, mockVoiceDetectionTimer, mockDelayTimer] {
            timer?.stop()
        }
#if os(macOS)
        storedVPIOUnitDeallocationTimer?.stop()
#endif
    }

    private func notify(_ event: WebCore.AudioCaptureControllerEvent, _ value: Bool = false) {
        WebCore.coreAudioCaptureUnitDidChange(identifier, event, value)
    }

    private var hasClients: Bool {
        WebCore.coreAudioCaptureUnitHasClients(identifier)
    }

    private var preferredIOBufferSize: Int {
        Int(clamping: WebCore.audioCaptureSessionBufferSize())
    }

    var state: WebCore.AudioCaptureControllerState {
        var state = WebCore.AudioCaptureControllerState()
        state.sampleRate = Int32(clamping: sampleRate)
        state.actualSampleRate = Int32(clamping: actualSampleRate)
        state.enableEchoCancellation = enableEchoCancellation
        state.usesVoiceProcessing = shouldUseVPIO
        state.isSuspended = isSuspended
        state.isRunning = ioUnitStarted
        state.canRenderAudio = canRenderAudio
        state.isRenderingAudio = isRenderingAudio
        state.hasAudioUnit = unit != nil
        return state
    }

    func configureMock(usesMockUnit: Bool, sampleRateOverride: Int?) {
        self.usesMockUnit = usesMockUnit
        self.sampleRateOverride = sampleRateOverride
    }

    func setDeliveryContext(_ address: UInt) {
        cxxDeliveryContext = address
    }

    func setEnableEchoCancellation(_ value: Bool) {
        assert(canEnableEchoCancellation || (!value && !enableEchoCancellation))
        enableEchoCancellation = value
    }

    func setSampleRate(_ value: Int) {
        sampleRate = value
    }

    // MARK: Starting and stopping

    func startProducingData() {
        if isSuspended {
            resume()
        }
        setIsProducingMicrophoneSamples(true)
        producingCount &+= 1
        if producingCount != 1 {
            return
        }
#if os(macOS)
        prewarmAudioUnitCreation { [weak self] in
            self?.continueStartProducingData()
        }
#else
        continueStartProducingData()
#endif
    }

    private func continueStartProducingData() {
        if producingCount == 0 || !hasClients {
            return
        }
        if ioUnitStarted {
            return
        }
        // The IO unit start is deferred (prewarmAudioUnitCreation on macOS), so the unit may have been suspended after
        // startProducingData() checked; resume() restarts capture then.
        if isSuspended {
            return
        }
        if unit != nil {
            cleanupAudioUnit()
        }
        let error = startUnit()
        if error != noErr {
            if error == lowPriorityError1 || error == lowPriorityError2 {
                logger.error("BaseAudioCaptureUnit::startProducingData failed due to not high enough priority, suspending unit")
                suspend()
            } else {
                captureFailed()
            }
        }
    }

    private func startUnit() -> OSStatus {
        notify(.UnitWillStart)
        if !WebCore.audioCaptureSessionCanStartCapture() {
            return lowPriorityError2
        }
        return startInternal()
    }

    func prepareForNewCapture() {
        resetSampleRate()
        if !isSuspended {
            return
        }
        isSuspended = false
        if producingCount == 0 {
            return
        }
        logger.error("BaseAudioCaptureUnit::prepareForNewCapture, notifying suspended sources of capture failure")
        captureFailed()
    }

    func captureFailed() {
        logger.error("BaseAudioCaptureUnit::captureFailed")
        notify(.CaptureFailed)
        stopRunning()
    }

    func stopProducingData() {
        assert(producingCount != 0)
#if os(macOS)
        if !isSuspended {
            prewarmAudioUnitCreation { [weak self] in
                self?.continueStopProducingData()
            }
            return
        }
#endif
        continueStopProducingData()
    }

    private func continueStopProducingData() {
        if producingCount != 0 {
            producingCount -= 1
            if producingCount != 0 {
                return
            }
        }
        if shouldContinueRunning {
            setIsProducingMicrophoneSamples(false)
            return
        }
        stopRunning()
    }

    private var shouldContinueRunning: Bool {
        producingCount != 0 || isRenderingAudio || hasClients
    }

    func clientWasRemoved() {
        if !shouldContinueRunning {
            stopRunning()
        }
    }

    private func setIsProducingMicrophoneSamples(_ value: Bool) {
        isProducingMicrophoneSamples = value
        isProducingMicrophoneSamplesChanged()
    }

    private func setIsRenderingAudio(_ value: Bool) {
        isRenderingAudio = value
        if !shouldContinueRunning {
            stopRunning()
        }
    }

    private func stopRunning() {
        stopInternal()
        cleanupAudioUnit()
    }

    func reconfigure() {
        if isSuspended {
            needsReconfiguration = true
            return
        }
        _ = reconfigureAudioUnit()
    }

    func resume() {
        if !isSuspended {
            return
        }
        assert(!ioUnitStarted)
        logger.info("BaseAudioCaptureUnit::resume")
        isSuspended = false
        if needsReconfiguration {
            needsReconfiguration = false
            reconfigure()
        }
        notify(.Resumed)
    }

    func suspend() {
        if isSuspended {
            return
        }
        logger.info("BaseAudioCaptureUnit::suspend")
        isSuspended = true
        stopInternal()
        notify(.Suspended)
    }

    // MARK: Voice activity

    fileprivate func voiceActivityDetected() {
        if voiceActivityThrottleTimer == nil {
            voiceActivityThrottleTimer = MainThreadTimer {}
        }
        guard let throttleTimer = voiceActivityThrottleTimer, !throttleTimer.isActive, hasVoiceActivityListener else {
            return
        }
        logger.info("BaseAudioCaptureUnit::voiceActivityDetected")
        notify(.VoiceActivityDetected)
        throttleTimer.startOneShot(voiceActivityThrottlingDuration)
    }

    fileprivate func disableVoiceActivityThrottleTimerForTesting() {
        voiceActivityThrottleTimer?.stop()
    }

    func setHasVoiceActivityListener(_ value: Bool) {
        hasVoiceActivityListener = value
        updateVoiceActivityDetection()
    }

    private var shouldEnableVoiceActivityDetection: Bool {
#if os(macOS)
        hasVoiceActivityListener && ioUnitStarted
#else
        hasVoiceActivityListener && !isProducingMicrophoneSamples && ioUnitStarted
#endif
    }

    private func updateVoiceActivityDetection(shouldDisable: Bool = false) {
        if unit == nil {
            return
        }
        if voiceActivityDetectionEnabled {
            if shouldEnableVoiceActivityDetection && !shouldDisable {
                return
            }
            if setUnitVoiceActivityDetection(false) {
                voiceActivityDetectionEnabled = false
            }
            return
        }
        if !shouldEnableVoiceActivityDetection {
            return
        }
        if setUnitVoiceActivityDetection(true) {
            voiceActivityDetectionEnabled = true
        }
    }

    // A mock fakes voice activity every 100 ms while its output is muted.
    private func setUnitVoiceActivityDetection(_ shouldEnable: Bool) -> Bool {
        guard let unit else {
            preconditionFailure()
        }
        if unit.kind.isMock {
            mockVoiceActivityDetectionEnabled = shouldEnable
            if mockVoiceDetectionTimer == nil {
                mockVoiceDetectionTimer = MainThreadTimer {
                    mockVoiceDetected()
                }
            }
            if !mockVoiceActivityDetectionEnabled || !mockOutputMuted {
                mockVoiceDetectionTimer?.stop()
            } else {
                mockVoiceDetectionTimer?.startRepeating(0.1)
            }
            return true
        }
#if HAVE_VOICEACTIVITYDETECTION
#if os(macOS)
        var deviceID = defaultController().captureDeviceID
        if deviceID == 0 {
            let (status, defaultDeviceID) = defaultInputDevice()
            if status != noErr {
                return false
            }
            deviceID = defaultDeviceID
        }
        return manageSpeechActivityListener(deviceID, shouldEnable)
#else
        let status = unit.setMutedSpeechActivityListener(shouldEnable)
        if status != noErr {
            logger.error(
                "CoreAudioCaptureInternalUnit::setVoiceActivityDetection failed activation, error \(status) (\(fourCharacters(status), privacy: .public))"
            )
        }
        return status == noErr
#endif
#else
        return false
#endif
    }

    // MARK: Mute

    private func updateMutedState(sync: Bool = false) {
        let muteUplinkOutput: UInt32 = unit != nil && ioUnitStarted && !isProducingMicrophoneSamples ? 1 : 0
        if !sync && muteUplinkOutput != 0 {
            logger.info("CoreAudioCaptureUnit::updateMutedState(\(self.identifier)) delaying mute in case unit gets stopped or unmuted soon")
            // Some time for playback to stop or for capture to restart, but not too long if the user decided to stop capture.
            if updateMutedStateTimer == nil {
                updateMutedStateTimer = MainThreadTimer { [weak self] in
                    self?.updateMutedState(sync: true)
                }
            }
            updateMutedStateTimer?.startOneShot(0.5)
            return
        }
        updateMutedStateTimer?.stop()
        if unit != nil {
            let error = setUnitProperty(kAUVoiceIOProperty_MuteOutput, kAudioUnitScope_Global, outputBus, muteUplinkOutput)
            if error != noErr {
                logger.error(
                    "CoreAudioCaptureUnit::updateMutedState(\(self.identifier)) unable to set kAUVoiceIOProperty_MuteOutput, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            }
        }
        let isAnyOtherUnitCapturing = isAnyUnitCapturing(except: self)
        logger.info("CoreAudioCaptureUnit::updateMutedState muteUplinkOutput=\(muteUplinkOutput) isAnyOtherUnitCapturing=\(isAnyOtherUnitCapturing)")
        if isAnyOtherUnitCapturing {
            return
        }
        setMutedState(muteUplinkOutput != 0)
    }

    fileprivate var capturesMicrophoneSamples: Bool {
        isProducingMicrophoneSamples
    }

    // MARK: The AudioUnit

    private func defaultInputDevice() -> (OSStatus, UInt32) {
        guard let unit else {
            preconditionFailure()
        }
        if unit.kind.isMock {
            return (0, 1)
        }
#if os(macOS)
        let (status, deviceID) = unit.uint32Property(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, inputBus)
        if status != noErr {
            logger.error("CoreAudioCaptureInternalUnit unable to get default input device ID, error \(status) (\(fourCharacters(status), privacy: .public))")
            return (status, 0)
        }
        return (status, deviceID)
#else
        return (-1, 0)
#endif
    }

    private func defaultOutputDevice() -> (OSStatus, UInt32) {
        guard let unit else {
            preconditionFailure()
        }
        if unit.kind.isMock {
            return (0, 0)
        }
#if os(macOS)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if unsafe AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) {
            var deviceID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = unsafe AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
            return (status, deviceID)
        }
#endif
        return (-1, 0)
    }

    // A mock AudioUnit sets only its device, whose sample rate it takes, and its muted state; it ignores other properties.
    private func setUnitProperty(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: UInt32) -> OSStatus {
        guard let unit else {
            preconditionFailure()
        }
        if !unit.kind.isMock {
            return unit.setUInt32Property(property, scope, element, value)
        }
        if property == kAudioOutputUnitProperty_CurrentDevice {
            if element == outputBus {
                assert(value == 0)
                return 0
            }
            assert(value != 0)
            let mockSampleRate = WebCore.audioCaptureMockMicrophoneSampleRate(value)
            if mockSampleRate == 0 {
                return -1
            }
            unit.configureMock(deviceSampleRate: mockSampleRate, bufferSize: preferredIOBufferSize)
            return 0
        }
        if property == kAUVoiceIOProperty_MuteOutput {
            mockOutputMuted = value & 0xff != 0
            _ = setUnitVoiceActivityDetection(mockVoiceActivityDetectionEnabled)
        }
        return 0
    }

    private func verifyCaptureInterval(_ isProducingSamples: Bool) -> Double {
        if let unit, unit.kind.isMock {
            return 1
        }
        return isProducingSamples ? 20 : 2
    }

    private func resetSampleRate() {
        setSampleRate(sampleRateOverride ?? integerSampleRate(WebCore.audioCaptureSessionSampleRate()))
    }

    private var actualSampleRate: Int {
        if speakerTrack != nil, let format = speakerProducerFormat {
            return integerSampleRate(format.mSampleRate)
        }
        return sampleRate
    }

    private func setupAudioUnit() -> OSStatus {
        if unit != nil {
            return 0
        }
        assert(hasClients)

        var timebaseInfo = mach_timebase_info_data_t()
        unsafe mach_timebase_info(&timebaseInfo)
        dtsConversionRatio = 1e-9 * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)

        let isEchoCancellationChanging = shouldUseVPIO != enableEchoCancellation
        shouldUseVPIO = enableEchoCancellation
        let kind: CaptureUnitKind =
            usesMockUnit ? (shouldUseVPIO ? .mockWithEchoCancellation : .mockWithoutEchoCancellation) : (shouldUseVPIO ? .voiceProcessing : .plain)
#if os(macOS)
        if kind == .voiceProcessing {
            logger.log("CoreAudioCaptureUnit::takeStoredVPIOUnit(\(defaultController().identifier))")
        }
#endif
        let creation = CaptureUnit.create(kind)
#if os(macOS)
        if kind == .voiceProcessing {
            let controller = defaultController()
            controller.storedVPIOUnitDeallocationTimer?.stop()
            controller.hasStoredVPIOUnit = false
        }
#endif
        guard let newUnit = creation.unit else {
            if creation.status == -1 {
                logger.error("CoreAudioCaptureInternalUnit unable to find capture unit component")
            } else {
                logger.error(
                    "CoreAudioCaptureInternalUnit unable to open capture unit, error \(creation.status) (\(fourCharacters(creation.status), privacy: .public))"
                )
            }
            return creation.status
        }
        if creation.reusedStoredUnit {
            logger.log("Creating a CoreAudioCaptureInternalUnit with a stored VPIO unit")
        } else if !newUnit.kind.isMock {
            logger.log("Successfully created a CoreAudioCaptureInternalUnit")
        }

        unit = newUnit
        unitIdentifier = addCaptureUnit(newUnit)
        newUnit.setSwitch(.reconfiguring, isReconfiguring)
        newUnit.setSwitch(.producingMicrophoneSamples, isProducingMicrophoneSamples)
        attachSpeakerSamplesProducer()
        notify(.MicrophoneConfigurationNeeded)
        if newUnit.kind.isMock {
            newUnit.configureMock(deviceSampleRate: 0, bufferSize: preferredIOBufferSize)
        }

        let canRenderAudio = !newUnit.kind.isMock && shouldUseVPIO
        if self.canRenderAudio != canRenderAudio {
            self.canRenderAudio = canRenderAudio
            notifySpeakerSamplesProducer { $0.canRenderAudioChanged() }
        }

        if isEchoCancellationChanging {
            notify(.EchoCancellationChanged)
        }

#if HAVE_VPIO_DUCKING_LEVEL_API
        if shouldUseVPIO {
            let error = newUnit.kind.isMock ? noErr : newUnit.setOtherAudioDuckingConfiguration(inputBus)
            if error != noErr && error != kAudioUnitErr_InvalidProperty {
                logger.error(
                    "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) unable to set ducking level, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
                return error
            }
        }
#endif

#if os(macOS)
        if !shouldUseVPIO {
            var error = setUnitProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, 1)
            if error != noErr {
                logger.error(
                    "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) unable to enable capture unit input, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
                return error
            }
            error = setUnitProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, 0)
            if error != noErr {
                logger.error(
                    "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) unable to enable capture unit output, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
                return error
            }
        }

        var deviceID = captureDeviceID
        // FIXME: We probably want to make default input/output devices.
        if deviceID == 0 {
            let (status, defaultDeviceID) = defaultInputDevice()
            if status != noErr {
                return status
            }
            deviceID = defaultDeviceID
        }

        let deviceError = setUnitProperty(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, inputBus, deviceID)
        if deviceError != noErr {
            logger.error(
                "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) unable to set capture unit capture device ID \(deviceID), error \(deviceError) (\(fourCharacters(deviceError), privacy: .public))"
            )
            return deviceError
        }

        if shouldUseVPIO {
            var (error, defaultOutputDeviceID) = defaultOutputDevice()
            if error == noErr {
                error = setUnitProperty(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputBus, defaultOutputDeviceID)
                if error != noErr {
                    logger.error(
                        "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) unable to set capture unit output device ID \(defaultOutputDeviceID), error \(error) (\(fourCharacters(error), privacy: .public))"
                    )
                }
            }
            outputDeviceID = error == noErr ? defaultOutputDeviceID : 0
        } else {
            // With HALOutput, we cannot rely on sample rate conversions, we stick to hardware sample rate.
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nominalSampleRate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            if unsafe AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nominalSampleRate) == noErr {
                setSampleRate(integerSampleRate(nominalSampleRate))
            }
        }
#else
        let enableError = setUnitProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, 1)
        if enableError != noErr {
            logger.error(
                "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) unable to enable capture unit input, error \(enableError) (\(fourCharacters(enableError), privacy: .public))"
            )
            return enableError
        }
#endif

        // FIXME: Add support for different speaker/microphone sample rates.
        let actualSampleRate = self.actualSampleRate
        var error = configureMicrophoneProc(actualSampleRate)
        if error != noErr {
            return error
        }
        error = configureSpeakerProc(actualSampleRate)
        if error != noErr {
            return error
        }
        error = newUnit.initialize()
        if error != noErr {
            logger.error(
                "CoreAudioCaptureUnit::setupAudioUnit(\(self.identifier)) AudioUnitInitialize() failed, error \(error) (\(fourCharacters(error), privacy: .public))"
            )
            return error
        }
        ioUnitInitialized = true

        unduck()
        return 0
    }

    private func unduck() {
        if unit == nil {
            return
        }
        let (status, outputDevice) = defaultOutputDevice()
        if status == noErr {
            _ = AudioDeviceDuck(outputDevice, 1.0, nil, 0)
        }
    }

    private func configureMicrophoneProc(_ sampleRate: Int) -> OSStatus {
        guard let unit else {
            preconditionFailure()
        }
        let result = unit.configureMicrophone(Float64(sampleRate))
        guard let format = result.format else {
            let error = result.status
            switch result.failedStep {
            case 1:
                logger.error(
                    "CoreAudioCaptureUnit::configureMicrophoneProc(\(self.identifier)) unable to set capture unit mic proc, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            case 2:
                logger.error(
                    "CoreAudioCaptureUnit::configureMicrophoneProc(\(self.identifier)) unable to get output stream format, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            default:
                logger.error(
                    "CoreAudioCaptureUnit::configureMicrophoneProc(\(self.identifier)) unable to set output stream format, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            }
            return error
        }

        var bufferSize = preferredIOBufferSize
        if let minimumFrames = minimumMicrophoneSampleFrames {
            let minimumBufferSize = minimumFrames &* Int(format.mBytesPerPacket)
            if minimumBufferSize > bufferSize {
                bufferSize = minimumBufferSize
            }
            minimumMicrophoneSampleFrames = nil
        }
        let sizes = WebCore.coreAudioCaptureUnitAllocateMicrophoneBuffer(identifier, format, UInt64(clamping: bufferSize &* 2))
        unit.allocateMicrophoneBuffers(format, sizes, sampleRate: format.mSampleRate, dtsConversionRatio: dtsConversionRatio)
        // Sinks of another format would drop the quanta: their owners give them rings in this one, before the unit starts.
        notify(.MicrophoneFormatChanged)
        return noErr
    }

    private func configureSpeakerProc(_ sampleRate: Int) -> OSStatus {
        guard let unit else {
            preconditionFailure()
        }
        let producerFormat = speakerTrack != nil ? speakerProducerFormat : nil
        assert(producerFormat.map { $0.mSampleRate == Float64(sampleRate) } ?? true)
        let result = unit.configureSpeaker(Float64(sampleRate), producerFormat)
        guard let format = result.format else {
            let error = result.status
            if result.failedStep == 1 {
                logger.error(
                    "CoreAudioCaptureUnit::configureSpeakerProc(\(self.identifier)) unable to set capture unit speaker proc, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            } else {
                logger.error(
                    "CoreAudioCaptureUnit::configureSpeakerProc(\(self.identifier)) unable to get input stream format, error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            }
            return error
        }
        speakerProcFormat = format
        return noErr
    }

    // The unit's IO threads' events since the last call.
    fileprivate func dispatchUnitEvents() {
        if unitIdentifier == 0 || unit == nil {
            return
        }
        guard let events = takeCaptureUnitEvents(unitIdentifier), events != 0 else {
            return
        }
        handleUnitEvents(events)
    }

    private func handleUnitEvents(_ events: UInt32) {
        if events & AudioUnitEvent.speakerStarting != 0 {
            notifySpeakerSamplesProducer { $0.captureUnitIsStarting() }
            unit?.setSwitch(.speakerStartAcknowledged, true)
        }
        if events & AudioUnitEvent.firstMicrophoneQuantum != 0 {
            notify(.FirstMicrophoneQuantum)
        }
        if events & AudioUnitEvent.sinkStarted != 0 {
            notify(.SinkStarted)
        }
        if events & AudioUnitEvent.microphoneBufferTooSmall != 0, let unit, minimumMicrophoneSampleFrames == nil {
            let failedRenderFrames = unit.renderState.failedRenderFrames
            if failedRenderFrames & failedRenderFlag != 0 {
                let frameCount = UInt32(truncatingIfNeeded: failedRenderFrames)
                logger.error(
                    "CoreAudioCaptureUnit::processMicrophoneSamples(\(self.identifier)) AudioUnitRender failed with error \(kAudio_ParamError), inNumberFrames \(frameCount) "
                )
                minimumMicrophoneSampleFrames = Int(frameCount)
                // Our buffer might be too small, the preferred buffer size or sample rate might have changed.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.reconfigure()
                    }
                }
            }
        }
    }

    // The unit hands its microphone's quanta to the C++ (attached once per unit), and its speaker plays out the producer's
    // track, if any.
    private func attachSpeakerSamplesProducer() {
        guard let unit else {
            return
        }
        if !unit.hasCxxDeliveryContext {
            precondition(!unit.isRunning)
            unsafe unit.renderState.setCxxDeliveryContext(UnsafeMutableRawPointer(bitPattern: cxxDeliveryContext))
            unit.hasCxxDeliveryContext = true
        }
        unit.attachSpeakerTrack(speakerTrack)
    }

    private func cleanupAudioUnit() {
        if ioUnitInitialized {
            assert(unit != nil)
            if let unit {
                let error = unit.uninitialize()
                if error != noErr {
                    logger.error(
                        "CoreAudioCaptureUnit::cleanupAudioUnit(\(self.identifier)) AudioUnitUninitialize failed with error \(error) (\(fourCharacters(error), privacy: .public))"
                    )
                }
            }
            ioUnitInitialized = false
        }

        updateVoiceActivityDetection()
        updateMutedState()

        if let unit = unit.take() {
            microphoneProcsCalledByReleasedUnits &+= unit.renderState.microphoneProcCount
            _ = removeCaptureUnit(unitIdentifier)
#if os(macOS)
            if unit.destroy() {
                defaultController().storedVPIOUnitWasKept()
            }
#else
            _ = unit.destroy()
#endif
        }
        mockOutputMuted = false
        mockVoiceActivityDetectionEnabled = false
        mockVoiceDetectionTimer?.stop()
        mockDelayTimer?.stop()
        notify(.AudioUnitReleased)
    }

    // A mock pauses its samples for a while; a real unit doesn't.
    func delaySamples(_ seconds: Double) {
        guard let unit, unit.kind.isMock else {
            return
        }
        unit.setMockPaused(true)
        if mockDelayTimer == nil {
            mockDelayTimer = MainThreadTimer { [weak self] in
                self?.unit?.setMockPaused(false)
            }
        }
        mockDelayTimer?.startOneShot(seconds)
    }

    @discardableResult
    private func reconfigureAudioUnit() -> OSStatus {
        guard unit != nil else {
            return 0
        }
        if !hasClients {
            logger.error("CoreAudioCaptureUnit::reconfigureAudioUnit(\(self.identifier)) stopping since there are no clients")
            stopRunning()
            return 0
        }

        isReconfiguring = true
        unit?.setSwitch(.reconfiguring, true)
        defer {
            isReconfiguring = false
            unit?.setSwitch(.reconfiguring, false)
        }

        if ioUnitStarted, let unit {
            let error = unit.stop()
            if error != noErr {
                logger.error(
                    "CoreAudioCaptureUnit::reconfigureAudioUnit(\(self.identifier)) AudioOutputUnitStop failed with error \(error) (\(fourCharacters(error), privacy: .public))"
                )
                return error
            }
        }

        cleanupAudioUnit()
        let setupError = setupAudioUnit()
        if setupError != 0 {
            return setupError
        }

        if ioUnitStarted, let unit {
            let error = unit.start()
            if error != noErr {
                logger.error(
                    "CoreAudioCaptureUnit::reconfigureAudioUnit(\(self.identifier)) AudioOutputUnitStart failed with error \(error) (\(fourCharacters(error), privacy: .public))"
                )
                return error
            }
        }
        return noErr
    }

    private func startInternal() -> OSStatus {
        setIsProducingMicrophoneSamples(true)

        if unit == nil {
            let error = setupAudioUnit()
            if error != 0 {
                cleanupAudioUnit()
                assert(unit == nil)
                return error
            }
        }
        guard let unit else {
            preconditionFailure()
        }

        unduck()

        if unit.kind.isMock {
            unit.configureMock(deviceSampleRate: 0, bufferSize: preferredIOBufferSize)
        }

        let error = unit.start()
        if error != noErr {
            notifySpeakerSamplesProducer { $0.captureUnitHasStopped() }
            logger.error("CoreAudioCaptureUnit::start(\(self.identifier)) AudioOutputUnitStart failed with error \(error) (\(fourCharacters(error), privacy: .public))")
            cleanupAudioUnit()
            assert(self.unit == nil)
            return error
        }

        ioUnitStarted = true

        microphoneProcsCalledByReleasedUnits = 0
        microphoneProcsCalledLastTime = 0
        startVerifyCapturingTimer()

        updateVoiceActivityDetection()
        updateMutedState()

        return noErr
    }

    private func startVerifyCapturingTimer() {
        if verifyCapturingTimer == nil {
            verifyCapturingTimer = MainThreadTimer { [weak self] in
                self?.verifyIsCapturing()
            }
        }
        verifyCapturingTimer?.startRepeating(verifyCaptureInterval(microphoneProcsCalledLastTime == 0 || isProducingMicrophoneSamples))
    }

    private func isProducingMicrophoneSamplesChanged() {
        unit?.setSwitch(.producingMicrophoneSamples, isProducingMicrophoneSamples)
        updateMutedState()
        updateVoiceActivityDetection()

        if !ioUnitStarted {
            return
        }
        startVerifyCapturingTimer()
    }

    func validateOutputDevice() {
#if os(macOS)
        if !shouldUseVPIO || unit == nil {
            return
        }
        let (status, currentDefaultOutputDeviceID) = defaultOutputDevice()
        if status != noErr {
            return
        }
        if currentDefaultOutputDeviceID == 0 || outputDeviceID == currentDefaultOutputDeviceID {
            return
        }
        reconfigure()
#endif
    }

    private func verifyIsCapturing() {
        unit?.forEachProducerSink { sink in
            let dropped = sink.takeNewDroppedQuantumCount()
            if dropped != 0 {
                logger.error("CoreAudioCaptureUnit::verifyIsCapturing - a producer sink dropped \(dropped) quanta of another format")
            }
        }

        let microphoneProcsCalled = microphoneProcsCalledByReleasedUnits &+ (unit?.renderState.microphoneProcCount ?? 0)
        if microphoneProcsCalledLastTime != microphoneProcsCalled {
            microphoneProcsCalledLastTime = microphoneProcsCalled
            return
        }

        let interval = Int(verifyCapturingTimer?.repeatInterval ?? 0)
        logger.error("CoreAudioCaptureUnit::verifyIsCapturing - no audio received in \(interval) seconds, failing")
        captureFailed()
    }

    private func stopInternal() {
        verifyCapturingTimer?.stop()

        guard let unit, ioUnitStarted else {
            return
        }

        let error = unit.stop()
        if error != noErr {
            logger.error("CoreAudioCaptureUnit::stop(\(self.identifier)) AudioOutputUnitStop failed with error \(error) (\(fourCharacters(error), privacy: .public))")
            return
        }
        notifySpeakerSamplesProducer { $0.captureUnitHasStopped() }

        ioUnitStarted = false
#if !os(macOS)
        notify(.UnitStopped)
#endif
        updateVoiceActivityDetection()
        updateMutedState()
    }

    // What the default unit's registered producer, if any, is told (CoreAudioCaptureUnit's C++ told it the same).
    private func notifySpeakerSamplesProducer(_ body: (any AudioSpeakerSamplesProducer) -> Void) {
        guard self === defaultAudioCaptureController, let producer = registeredSpeakerSamplesProducer.producer else {
            return
        }
        body(producer)
    }

    // The speaker's producer's track and format, registered or not (nil).
    fileprivate func setSpeakerSamplesProducer(_ track: TrackPlayout?, _ format: AudioStreamBasicDescription) {
        guard let track else {
            speakerTrack = nil
            speakerProducerFormat = nil
            attachSpeakerSamplesProducer()
            setIsRenderingAudio(false)
            return
        }
        setIsRenderingAudio(true)
        speakerTrack = track
        speakerProducerFormat = format
        attachSpeakerSamplesProducer()
        if unit != nil && !(speakerProcFormat.map { sameFormat($0, format) } ?? false) {
            reconfigure()
        }
    }

    func changeCaptureDevice(_ change: WebCore.AudioCaptureDeviceChange, _ deviceID: UInt32) {
        switch change {
        case .WillChange:
            if !voiceActivityDetectionEnabled {
                return
            }
            updateVoiceActivityDetection(shouldDisable: true)
        case .Set:
            captureDeviceID = deviceID
        case .Changed:
            captureDeviceID = deviceID
#if os(macOS)
            reconfigureAudioUnit()
#endif
            updateVoiceActivityDetection()
        @unknown default:
            preconditionFailure()
        }
    }

    func attachSink(_ sinkIdentifier: UInt64, _ attach: Bool) {
        unit?.attachSink(sinkIdentifier, attach)
    }

    func setMicrophoneOptions(gain: Float, appliesGain: Bool, deliversToCxx: Bool, armFirstQuantum: Bool) {
        guard let unit else {
            return
        }
        unit.setMicrophoneOptions(gain: gain, appliesGain: appliesGain, deliversToCxx: deliversToCxx)
        // Delivering the first sample tells the source's observers it started producing data.
        if armFirstQuantum {
            unit.setSwitch(.firstMicrophoneQuantumArmed, true)
        }
    }

    // MARK: The stored voice processing unit

#if os(macOS)
    private func storedVPIOUnitWasKept() {
        logger.log("CoreAudioCaptureUnit::setStoredVPIOUnit(\(self.identifier))")
        hasStoredVPIOUnit = true
        if storedVPIOUnitDeallocationTimer == nil {
            storedVPIOUnitDeallocationTimer = MainThreadTimer { [weak self] in
                self?.deallocateStoredVPIOUnit()
            }
        }
        storedVPIOUnitDeallocationTimer?.startOneShot(3)
    }

    private func deallocateStoredVPIOUnit() {
        if !hasStoredVPIOUnit {
            return
        }
        logger.log("CoreAudioCaptureUnit::deallocateStoredVPIOUnit")
        hasStoredVPIOUnit = false
        AudioUnitOwner.deallocateStoredVoiceProcessingUnit()
        audioUnitCreationWarmup = .none
    }

    func prewarmAudioUnitCreation(_ callback: @escaping @MainActor @Sendable () -> Void) {
        switch audioUnitCreationWarmup {
        case .pending:
            audioUnitCreationWarmupCallbacks.append(callback)
            return
        case .settled:
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    callback()
                }
            }
            return
        case .none:
            break
        }

        if !enableEchoCancellation {
            callback()
            return
        }

        audioUnitCreationWarmupCount &+= 1
        let warmup = audioUnitCreationWarmupCount
        audioUnitCreationWarmup = .pending(warmup)
        let identifier = self.identifier
        DispatchQueue(label: "CoreAudioCaptureUnit AudioUnit creation", qos: .userInitiated).async {
            let isStored = AudioUnitOwner.prewarmVoiceProcessingUnit()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = audioCaptureControllers[identifier]
                    if let controller, isStored {
                        controller.storedVPIOUnitWasKept()
                    }
                    callback()
                    controller?.settleAudioUnitCreationWarmup(warmup)
                }
            }
        }
    }

    private func settleAudioUnitCreationWarmup(_ warmup: UInt64) {
        guard case .pending(let pending) = audioUnitCreationWarmup, pending == warmup else {
            return
        }
        audioUnitCreationWarmup = .settled
        let callbacks = audioUnitCreationWarmupCallbacks
        audioUnitCreationWarmupCallbacks = []
        for callback in callbacks {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    callback()
                }
            }
        }
    }
#endif
}

private func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
        && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
        && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBitsPerChannel == b.mBitsPerChannel
}

@MainActor
private func isAnyUnitCapturing(except excluded: AudioCaptureController? = nil) -> Bool {
    audioCaptureControllers.values.contains { $0.capturesMicrophoneSamples && $0 !== excluded }
}

@MainActor
private func mockVoiceDetected() {
    let controller = defaultController()
    controller.voiceActivityDetected()
    controller.disableVoiceActivityThrottleTimerForTesting()
}

#if os(macOS) && HAVE_VOICEACTIVITYDETECTION
@MainActor
private func manageSpeechActivityListener(_ deviceID: UInt32, _ enable: Bool) -> Bool {
    let (error, failedStep) = setDeviceVoiceActivityDetection(deviceID, enable)
    if failedStep == 1 {
        logger.error(
            "CoreAudioCaptureUnit manageSpeechActivityListener unable to set kVoiceActivityDetectionEnable, error \(error) (\(fourCharacters(error), privacy: .public))"
        )
    } else if error != noErr && !enable {
        logger.error(
            "CoreAudioCaptureUnit manageSpeechActivityListener unable to remove kVoiceActivityDetectionEnable listener, error \(error) (\(fourCharacters(error), privacy: .public))"
        )
    } else if error != noErr {
        logger.error(
            "CoreAudioCaptureUnit manageSpeechActivityListener unable to set kVoiceActivityDetectionEnable listener, error \(error) (\(fourCharacters(error), privacy: .public))"
        )
    }
    return error == noErr
}
#endif

// A unit heard speech while its output was muted (audioCaptureVoiceActivityDetected()).
@MainActor
func audioCaptureControllerVoiceActivityDetected() {
    defaultAudioCaptureController?.voiceActivityDetected()
}

// The unit's IO threads' events, with the output units' (audioUnitsDispatchSwiftEvents()).
func dispatchAudioCaptureControllerUnitEvents() {
    MainActor.assumeIsolated {
        for identifier in audioCaptureControllers.keys.sorted() {
            audioCaptureControllers[identifier]?.dispatchUnitEvents()
        }
    }
}

// The C++ that a controller's units deliver their microphone's quanta to (audioUnitAttachRing()).
func setAudioCaptureControllerDeliveryContext(_ identifier: UInt64, _ address: UInt) -> Bool {
    MainActor.assumeIsolated {
        guard let controller = audioCaptureControllers[identifier] else {
            return false
        }
        controller.setDeliveryContext(address)
        return true
    }
}

// MARK: The microphone's mute state

#if HAVE_AVAUDIOAPPLICATION
@MainActor
private var muteStatusObserver: (any NSObjectProtocol)?

@MainActor
private var hasMuteStatusListener = false

private func sharedAudioApplication() -> AVAudioApplication? {
    guard AVFAudioFrameworkIsAvailable, let applicationClass = AVFAudioClass.AVAudioApplication else {
        return nil
    }
    return applicationClass.shared
}

#if os(macOS)
// The handler that enables AVAudioApplicationInputMuteStateChangeNotification on macOS.
private func setNoopInputMuteStateChangeHandler(_ audioApplication: AVAudioApplication, _ shouldAddHandler: Bool) {
    var failure: Swift.String?
    let exception = WebCoreCatchingObjCException {
        do {
            if shouldAddHandler {
                try audioApplication.setInputMuteStateChangeHandler { _ in true }
            } else {
                try audioApplication.setInputMuteStateChangeHandler(nil)
            }
        } catch {
            failure = error.localizedDescription
        }
    }
    if let failure {
        logger.error(
            "WebCoreAudioInputMuteChangeListener failed to set mute state change handler due to error: \(failure), shouldAddHandler: \(shouldAddHandler)."
        )
    }
    if let exception {
        logger.error(
            "WebCoreAudioInputMuteChangeListener failed to set mute state change handler due to exception: \(exception), shouldAddHandler: \(shouldAddHandler)."
        )
    }
}
#endif

@MainActor
private func startMuteStatusObserver() {
    guard let audioApplication = sharedAudioApplication() else {
        return
    }
#if os(macOS)
    setNoopInputMuteStateChangeHandler(audioApplication, true)
#endif
    muteStatusObserver = NotificationCenter.default.addObserver(
        forName: AVFAudioSoftLink.AVAudioApplicationInputMuteStateChangeNotification,
        object: audioApplication,
        queue: nil
    ) { notification in
        let isMuting = (notification.userInfo?[AVFAudioSoftLink.AVAudioApplicationMuteStateKey] as? NSNumber)?.boolValue ?? false
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handleMuteStatusChangedNotification(isMuting)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handleMuteStatusChangedNotification(isMuting)
                }
            }
        }
    }
}

@MainActor
private func stopMuteStatusObserver() {
    guard let audioApplication = sharedAudioApplication() else {
        return
    }
#if os(macOS)
    setNoopInputMuteStateChangeHandler(audioApplication, false)
#endif
    if let observer = muteStatusObserver.take() {
        NotificationCenter.default.removeObserver(observer)
    }
}

@MainActor
private func handleMuteStatusChangedNotification(_ isMuting: Bool) {
    let isAnyUnitCapturing = isAnyUnitCapturing()
    logger.info("CoreAudioCaptureUnit::handleMuteStatusChangedNotification isMuting=\(isMuting) isAnyUnitCapturing=\(isAnyUnitCapturing)")
    guard let controller = defaultAudioCaptureController, hasMuteStatusListener, isMuting == isAnyUnitCapturing else {
        return
    }
    WebCore.coreAudioCaptureUnitDidChange(controller.identifier, .MuteStatusChanged, isMuting)
}
#endif

@MainActor
private func setMutedState(_ isMuted: Bool) {
#if HAVE_AVAUDIOAPPLICATION
    guard let audioApplication = sharedAudioApplication() else {
        return
    }
    do {
        try audioApplication.setInputMuted(isMuted)
    } catch {
        logger.error("CoreAudioCaptureUnit::setMutedState failed due to error: \(error.localizedDescription).")
    }
#endif
}

// MARK: The speaker's producer

// A GPU-process MediaStream track renderer whose track the default capture unit's speaker plays out instead of its own output
// unit while it is registered (RemoteAudioMediaStreamTrackRendererInternalUnitManager.swift), and which the default unit tells
// when that changes.
@_spi(WebKitGPU)
@MainActor
public protocol AudioSpeakerSamplesProducer: AnyObject {
    var speakerTrackPlayout: TrackPlayout { get }
    var speakerFormat: AudioStreamBasicDescription { get }
    // The capture unit is starting, so its speaker plays out the track.
    func captureUnitIsStarting()
    // The capture unit stopped, or another producer replaced this one, so the speaker no longer plays out the track.
    func captureUnitHasStopped()
    func canRenderAudioChanged()
}

@MainActor
private final class RegisteredSpeakerSamplesProducer {
    weak var producer: (any AudioSpeakerSamplesProducer)?
}

@MainActor
private let registeredSpeakerSamplesProducer = RegisteredSpeakerSamplesProducer()

// What CoreAudioCaptureSourceFactory's C++ told and asked of the default capture unit about the speaker. Main thread only.
@_spi(WebKitGPU)
@MainActor
public enum AudioCaptureSpeaker {
    // The default unit's speaker plays out the producer's track from now on; a producer it replaces is told it stopped.
    public static func register(_ producer: any AudioSpeakerSamplesProducer) {
        let previous = registeredSpeakerSamplesProducer.producer
        registeredSpeakerSamplesProducer.producer = producer
        if let previous, previous !== producer {
            previous.captureUnitHasStopped()
        }
        defaultAudioCaptureController?.setSpeakerSamplesProducer(producer.speakerTrackPlayout, producer.speakerFormat)
    }

    public static func unregister(_ producer: any AudioSpeakerSamplesProducer) {
        guard registeredSpeakerSamplesProducer.producer === producer else {
            return
        }
        registeredSpeakerSamplesProducer.producer = nil
        defaultAudioCaptureController?.setSpeakerSamplesProducer(nil, AudioStreamBasicDescription())
    }

    // Whether the default unit renders the speaker's audio: it is running and, on macOS, can render audio.
    public static var shouldCaptureUnitRenderAudio: Bool {
        guard let state = defaultAudioCaptureController?.state else {
            return false
        }
#if os(macOS)
        return state.isRunning && state.canRenderAudio
#else
        return state.isRunning
#endif
    }

    public static var isCaptureUnitRunning: Bool {
        defaultAudioCaptureController?.state.isRunning ?? false
    }

    public static var isCaptureUnitSuspended: Bool {
        defaultAudioCaptureController?.state.isSuspended ?? false
    }
}

// MARK: The C++ API

extension WebCore.AudioCaptureControllerHandle {
    @MainActor
    private var controller: AudioCaptureController? {
        audioCaptureControllers[m_identifier]
    }

    @cxx
    @implementation
    static func create(_ canEnableEchoCancellation: Bool) -> UInt64 {
        MainActor.assumeIsolated {
            let identifier = nextAudioUnitIdentifier()
            let controller = AudioCaptureController(identifier: identifier, canEnableEchoCancellation: canEnableEchoCancellation)
            audioCaptureControllers[identifier] = controller
            if canEnableEchoCancellation {
                precondition(defaultAudioCaptureController == nil)
                defaultAudioCaptureController = controller
                if let producer = registeredSpeakerSamplesProducer.producer {
                    controller.setSpeakerSamplesProducer(producer.speakerTrackPlayout, producer.speakerFormat)
                }
            }
            return identifier
        }
    }

    @cxx
    @implementation
    mutating func destroy() {
        let identifier = m_identifier
        m_identifier = 0
        MainActor.assumeIsolated {
            guard let controller = audioCaptureControllers.removeValue(forKey: identifier) else {
                return
            }
            if defaultAudioCaptureController === controller {
                defaultAudioCaptureController = nil
            }
            controller.invalidate()
        }
    }

    @cxx
    @implementation
    func state() -> WebCore.AudioCaptureControllerState {
        MainActor.assumeIsolated {
            controller?.state ?? WebCore.AudioCaptureControllerState()
        }
    }

    @cxx
    @implementation
    func configureMock(_ usesMockUnit: Bool, _ sampleRateOverride: Int32) {
        MainActor.assumeIsolated {
            controller?.configureMock(usesMockUnit: usesMockUnit, sampleRateOverride: sampleRateOverride == 0 ? nil : Int(sampleRateOverride))
        }
    }

    @cxx
    @implementation
    func clientWasRemoved() {
        MainActor.assumeIsolated {
            controller?.clientWasRemoved()
        }
    }

    @cxx
    @implementation
    func startProducingData() {
        MainActor.assumeIsolated {
            controller?.startProducingData()
        }
    }

    @cxx
    @implementation
    func stopProducingData() {
        MainActor.assumeIsolated {
            controller?.stopProducingData()
        }
    }

    @cxx
    @implementation
    func prepareForNewCapture() {
        MainActor.assumeIsolated {
            controller?.prepareForNewCapture()
        }
    }

    @cxx
    @implementation
    func changeCaptureDevice(_ change: WebCore.AudioCaptureDeviceChange, _ deviceID: UInt32) {
        MainActor.assumeIsolated {
            controller?.changeCaptureDevice(change, deviceID)
        }
    }

    @cxx
    @implementation
    func setEnableEchoCancellation(_ value: Bool) {
        MainActor.assumeIsolated {
            controller?.setEnableEchoCancellation(value)
        }
    }

    @cxx
    @implementation
    func setSampleRate(_ value: Int32) {
        MainActor.assumeIsolated {
            controller?.setSampleRate(Int(value))
        }
    }

    @cxx
    @implementation
    func reconfigure() {
        MainActor.assumeIsolated {
            controller?.reconfigure()
        }
    }

    @cxx
    @implementation
    func suspend() {
        MainActor.assumeIsolated {
            controller?.suspend()
        }
    }

    @cxx
    @implementation
    func resume() {
        MainActor.assumeIsolated {
            controller?.resume()
        }
    }

    @cxx
    @implementation
    func delaySamples(_ seconds: Double) {
        MainActor.assumeIsolated {
            controller?.delaySamples(seconds)
        }
    }

    @cxx
    @implementation
    func validateOutputDevice() {
        MainActor.assumeIsolated {
            controller?.validateOutputDevice()
        }
    }

    @cxx
    @implementation
    func captureFailed() {
        MainActor.assumeIsolated {
            controller?.captureFailed()
        }
    }

    @cxx
    @implementation
    func setHasVoiceActivityListener(_ value: Bool) {
        MainActor.assumeIsolated {
            controller?.setHasVoiceActivityListener(value)
        }
    }

    @cxx
    @implementation
    static func setHasMuteStatusListener(_ value: Bool) {
#if HAVE_AVAUDIOAPPLICATION
        MainActor.assumeIsolated {
            hasMuteStatusListener = value
            if value {
                startMuteStatusObserver()
            } else {
                stopMuteStatusObserver()
            }
        }
#endif
    }

    @cxx
    @implementation
    func prewarmAudioUnitCreation() {
#if os(macOS)
        MainActor.assumeIsolated {
            controller?.prewarmAudioUnitCreation {}
        }
#endif
    }

    @cxx
    @implementation
    func attachSink(_ sinkIdentifier: UInt64, _ attach: Bool) {
        MainActor.assumeIsolated {
            controller?.attachSink(sinkIdentifier, attach)
        }
    }

    @cxx
    @implementation
    func setMicrophoneOptions(_ gain: Float, _ appliesGain: Bool, _ deliversToCxx: Bool, _ armFirstQuantum: Bool) {
        MainActor.assumeIsolated {
            controller?.setMicrophoneOptions(gain: gain, appliesGain: appliesGain, deliversToCxx: deliversToCxx, armFirstQuantum: armFirstQuantum)
        }
    }

    // MockAudioCaptureUnit::increaseBufferSize(): the mocks' quanta fake a microphone buffer that is too small, until a buffer
    // is big enough.
    @cxx
    @implementation
    static func setMockIncreaseBufferSize(_ value: Bool) {
        mockShouldIncreaseBufferSize.store(value, ordering: .relaxed)
    }
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM
