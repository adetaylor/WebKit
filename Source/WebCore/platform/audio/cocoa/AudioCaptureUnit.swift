// Copyright (C) 2016-2025 Apple Inc. All rights reserved.
// Copyright (C) 2017-2023 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

import AudioToolbox
import Dispatch
import Foundation
import Synchronization
import WebCore_Private.Core.CARingBufferSwiftBridge

// The capture AudioUnits of the microphone: voice processing, HALOutput on macOS or RemoteIO, or a mock that needs no
// hardware. AudioCaptureController.swift makes and runs them on the main thread. Their microphone and speaker callbacks are
// Swift (AudioUnitIsland.swift): the microphone's renders into the unit's own buffers, feeds the sinks and hands each quantum
// to the C++ that delivers it to the observers; the speaker's plays out a track playout, Swift to Swift.

enum CaptureUnitKind: UInt8 {
    case voiceProcessing
    case plain
    case mockWithEchoCancellation
    case mockWithoutEchoCancellation

    var isMock: Bool {
        self == .mockWithEchoCancellation || self == .mockWithoutEchoCancellation
    }
}

// What the main thread tells the IO threads.
enum CaptureUnitSwitch: UInt8 {
    case producingMicrophoneSamples
    case reconfiguring
    // The speaker's producer knows that the unit started (AudioUnitEvent.speakerStarting), so the speaker can play it out.
    case speakerStartAcknowledged
    // The next microphone quantum is an event (AudioUnitEvent.firstMicrophoneQuantum).
    case firstMicrophoneQuantumArmed
}

private var outputBus: AudioUnitElement { 0 }
private var inputBus: AudioUnitElement { 1 }

final class CaptureUnit {
    let kind: CaptureUnitKind
    let renderState: RenderStateReference
    var stopped: AudioUnitOwner?
    var running: RunningAudioUnit?
    let mock: MockCaptureBackend?
    private var speakerTrack: TrackPlayout?
    // Whether C++ attached the context the microphone callback hands its quanta to, which stays the same for the unit's life.
    var hasCxxDeliveryContext = false
    // What the microphone callback does with each quantum: the sinks it feeds, the volume, and whether the C++ observers
    // get the quantum.
    private var sinks: [(identifier: UInt64, sink: CaptureSink)] = []
    private var gain: Float = 1
    private var appliesGain = false
    private var deliversToCxx = true

    init(_ kind: CaptureUnitKind, _ owner: consuming AudioUnitOwner) {
        self.kind = kind
        renderState = owner.renderState
        stopped = consume owner
        mock = nil
    }

    init(mockWithEchoCancellation enableEchoCancellation: Bool) {
        kind = enableEchoCancellation ? .mockWithEchoCancellation : .mockWithoutEchoCancellation
        renderState = makeRenderState(sampleCapacity: 0)
        stopped = nil
        mock = MockCaptureBackend(enableEchoCancellation: enableEchoCancellation)
    }

    var isRunning: Bool {
        if let mock {
            return mock.isRunning
        }
        return running != nil
    }

    // Stops the unit if it runs, then disposes of it or, on macOS, keeps a voice processing unit for the next capture.
    // Returns whether it kept it.
    func destroy() -> Bool {
        if let mock {
            mock.stop()
            renderState.freeSnapshotsWhileStopped()
            renderState.freeMicrophoneBuffers()
            mock.freeBuffers()
            freeRenderState(renderState)
            return false
        }
        let owner: AudioUnitOwner
        if let unit = running.take() {
            owner = unit.stopForDisposal()
        } else if let unit = stopped.take() {
            owner = unit
        } else {
            preconditionFailure()
        }
        renderState.freeSnapshotsWhileStopped()
        renderState.freeMicrophoneBuffers()
#if os(macOS)
        if kind == .voiceProcessing {
            owner.storeForReuse()
            return true
        }
#endif
        owner.dispose()
        return false
    }

    func withOwner<Result>(_ missing: Result, _ body: (borrowing AudioUnitOwner) -> Result) -> Result {
        if let owner = stopped.take() {
            let result = body(owner)
            stopped = consume owner
            return result
        }
        if let unit = running.take() {
            let result = unit.withOwner(body)
            running = consume unit
            return result
        }
        return missing
    }

    // Starting a running unit starts it again, as the C++ did.
    func start() -> OSStatus {
        renderState.speakerWillStart()
        if let mock {
            if !mock.isRunning {
                mock.start(renderState)
            }
            renderState.resetMicrophoneProcCount()
            return noErr
        }
        if let unit = running.take() {
            let status = unit.startWhileRunning()
            running = consume unit
            if status == noErr {
                renderState.resetMicrophoneProcCount()
            }
            return status
        }
        guard let owner = stopped.take() else {
            return kAudio_ParamError
        }
        switch owner.start() {
        case .running(let unit):
            running = consume unit
            renderState.resetMicrophoneProcCount()
            return noErr
        case .stopped(let owner, let status):
            stopped = consume owner
            return status
        }
    }

    func stop() -> OSStatus {
        if let mock {
            mock.stop()
            renderState.returnCurrentSnapshotsWhileStopped()
            return noErr
        }
        if let owner = stopped.take() {
            let status = owner.stopWhileStopped()
            stopped = consume owner
            return status
        }
        guard let unit = running.take() else {
            return kAudio_ParamError
        }
        switch unit.stop() {
        case .stopped(let owner):
            stopped = consume owner
            renderState.returnCurrentSnapshotsWhileStopped()
            return noErr
        case .running(let unit, let status):
            running = consume unit
            return status
        }
    }

    // The track the speaker plays out, which changes whenever the speaker's producer does, running or not.
    func attachSpeakerTrack(_ track: TrackPlayout?) {
        if speakerTrack !== track {
            speakerTrack = track
            renderState.publishSnapshot(speakerTrack: track)
        }
    }

    func setSwitch(_ captureSwitch: CaptureUnitSwitch, _ value: Bool) {
        switch captureSwitch {
        case .producingMicrophoneSamples:
            renderState.setProducingMicrophoneSamples(value)
        case .reconfiguring:
            renderState.setReconfiguring(value)
        case .speakerStartAcknowledged:
            precondition(value)
            renderState.acknowledgeSpeakerStart()
        case .firstMicrophoneQuantumArmed:
            precondition(value)
            renderState.armFirstMicrophoneQuantum()
        }
    }

    // A sink detaches by identifier, even once C++ destroyed it.
    func attachSink(_ identifier: UInt64, _ attach: Bool) {
        let index = sinks.firstIndex { $0.identifier == identifier }
        if attach == (index != nil) {
            return
        }
        if let index {
            sinks.remove(at: index)
        } else {
            guard let sink = captureSink(identifier) else {
                return
            }
            sink.isAttachedToUnit = true
            sinks.append((identifier, sink))
        }
        publishMicrophoneSnapshot()
    }

    func setMicrophoneOptions(gain: Float, appliesGain: Bool, deliversToCxx: Bool) {
        self.gain = gain
        self.appliesGain = appliesGain
        self.deliversToCxx = deliversToCxx
        publishMicrophoneSnapshot()
    }

    // The producers among the sinks it feeds.
    func forEachProducerSink(_ body: (CaptureSink) -> Void) {
        for (_, sink) in sinks where sink.isProducer {
            body(sink)
        }
    }

    private func publishMicrophoneSnapshot() {
        renderState.publishMicrophoneSnapshot(gain: gain, appliesGain: appliesGain, deliversToCxx: deliversToCxx, sinks: sinks.map { $0.sink })
    }
}

// What configuring a unit's microphone or speaker did: the format it set, or the status of the step that failed (1: setting
// the callback, 2: getting the format, 3: setting it).
struct CaptureUnitFormatResult {
    var format: AudioStreamBasicDescription?
    var status: OSStatus = noErr
    var failedStep: UInt32 = 0
}

private func componentSubType(_ kind: CaptureUnitKind) -> OSType {
    if kind == .voiceProcessing {
        return kAudioUnitSubType_VoiceProcessingIO
    }
#if os(macOS)
    return kAudioUnitSubType_HALOutput
#else
    return kAudioUnitSubType_RemoteIO
#endif
}

// The unit's AudioUnit, through which AudioCaptureController.swift configures and runs it on the main thread.
extension CaptureUnit {
    // A capture unit of the given kind (createAudioUnit() and CoreAudioCaptureInternalUnit::create()), on macOS the stored voice
    // processing unit if there's one, or the status of AudioComponentInstanceNew() (-1 without a component).
    static func create(_ kind: CaptureUnitKind) -> (unit: CaptureUnit?, status: OSStatus, reusedStoredUnit: Bool) {
        precondition(WTF.isMainThread())
        if kind.isMock {
            return (CaptureUnit(mockWithEchoCancellation: kind == .mockWithEchoCancellation), noErr, false)
        }
#if os(macOS)
        if kind == .voiceProcessing, let stored = AudioUnitOwner.takeStoredVoiceProcessingUnit(renderSampleCapacity: 0) {
            return (CaptureUnit(kind, stored), noErr, true)
        }
#endif
        switch AudioUnitOwner.make(componentSubType: componentSubType(kind), renderSampleCapacity: 0) {
        case .made(let owner):
            return (CaptureUnit(kind, owner), noErr, false)
        case .noComponent:
            return (nil, -1, false)
        case .failed(let status):
            return (nil, status, false)
        }
    }

    // A mock has no properties.
    func setUInt32Property(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: UInt32) -> OSStatus {
        if kind.isMock {
            return noErr
        }
        return withOwner(kAudio_ParamError) { $0.setUInt32(value, for: property, scope: scope, element: element) }
    }

    func uint32Property(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement) -> (OSStatus, UInt32) {
        if kind.isMock {
            return (noErr, 0)
        }
        return withOwner((kAudio_ParamError, 0)) { $0.uint32(for: property, scope: scope, element: element) }
    }

#if HAVE_VPIO_DUCKING_LEVEL_API
    // A voice processing unit ducks other audio as little as it can.
    func setOtherAudioDuckingConfiguration(_ element: AudioUnitElement) -> OSStatus {
        let configuration = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: true, mDuckingLevel: .min)
        return withOwner(kAudio_ParamError) {
            $0.setValue(configuration, for: kAUVoiceIOProperty_OtherAudioDuckingConfiguration, scope: kAudioUnitScope_Global, element: element)
        }
    }
#endif

    // CoreAudioCaptureUnit::configureMicrophoneProc(), up to its buffer: installs the microphone callback and sets the
    // microphone's format to the unit's own at sampleRate.
    func configureMicrophone(_ sampleRate: Float64) -> CaptureUnitFormatResult {
        var result = CaptureUnitFormatResult()
        if let mock {
            mock.outputFormat.mSampleRate = sampleRate
            result.format = mock.outputFormat
            return result
        }
        withOwner(()) { owner in
            result.status = owner.installRenderCallback(
                .microphone,
                property: kAudioOutputUnitProperty_SetInputCallback,
                scope: kAudioUnitScope_Global,
                element: inputBus
            )
            if result.status != noErr {
                result.failedStep = 1
                return
            }
            var format = AudioStreamBasicDescription()
            result.status = owner.streamFormat(&format, scope: kAudioUnitScope_Output, element: inputBus)
            if result.status != noErr {
                result.failedStep = 2
                return
            }
            format.mSampleRate = sampleRate
            result.status = owner.setStreamFormat(format, scope: kAudioUnitScope_Output, element: inputBus)
            if result.status != noErr {
                result.failedStep = 3
                return
            }
            result.format = format
        }
        return result
    }

    // The microphone's buffers, the sizes of CoreAudioCaptureUnit's AudioSampleBufferList's, and how the microphone times its
    // quanta.
    func allocateMicrophoneBuffers(
        _ format: AudioStreamBasicDescription,
        _ sizes: WebCore.AudioCaptureMicrophoneBufferSizes,
        sampleRate: Float64,
        dtsConversionRatio: Float64
    ) {
        precondition(!isRunning)
        renderState.allocateMicrophoneBuffers(
            bufferCount: Int(sizes.bufferCount),
            byteCount: Int(sizes.bytesPerBuffer),
            channelsPerBuffer: sizes.channelsPerBuffer
        )
        renderState.setMicrophoneFormat(format)
        renderState.setMicrophoneTiming(sampleRate: sampleRate, dtsConversionRatio: dtsConversionRatio)
        if let mock {
            mock.attachRender(renderState)
        } else {
            withOwner(()) { $0.attachCaptureRender() }
        }
    }

    // CoreAudioCaptureUnit::configureSpeakerProc(): installs the speaker callback and sets the speaker's format to the
    // producer's, or to the unit's own, at sampleRate.
    func configureSpeaker(_ sampleRate: Float64, _ producerFormat: AudioStreamBasicDescription?) -> CaptureUnitFormatResult {
        var result = CaptureUnitFormatResult()
        var format = producerFormat ?? AudioStreamBasicDescription()
        if let mock {
            if producerFormat == nil {
                format = mock.inputFormat
            }
            format.mSampleRate = sampleRate
            mock.inputFormat = format
        } else {
            withOwner(()) { owner in
                result.status = owner.installRenderCallback(.speaker, scope: kAudioUnitScope_Input, element: outputBus)
                if result.status != noErr {
                    result.failedStep = 1
                    return
                }
                if producerFormat == nil {
                    result.status = owner.streamFormat(&format, scope: kAudioUnitScope_Input, element: outputBus)
                    if result.status != noErr {
                        result.failedStep = 2
                        return
                    }
                }
                format.mSampleRate = sampleRate
                result.status = owner.setStreamFormat(format, scope: kAudioUnitScope_Input, element: outputBus)
                if result.status != noErr {
                    result.failedStep = 3
                }
            }
            if result.status != noErr {
                return result
            }
        }
        renderState.setSpeakerBytesPerFrame(UInt64(format.mBytesPerFrame))
        result.format = format
        return result
    }

    func initialize() -> OSStatus {
        if let mock {
            return mock.initialize()
        }
        return withOwner(kAudio_ParamError) { $0.initialize() }
    }

    func uninitialize() -> OSStatus {
        if mock != nil {
            return noErr
        }
        return withOwner(kAudio_ParamError) { $0.uninitialize() }
    }

#if os(iOS) || os(visionOS)
    func setMutedSpeechActivityListener(_ enable: Bool) -> OSStatus {
        if kind.isMock {
            return noErr
        }
        return withOwner(kAudio_ParamError) { $0.setMutedSpeechActivityListener(enable) }
    }
#endif

    // A mock's device sample rate, which its formats follow (0: none), and the AudioSession buffer size its quanta follow.
    func configureMock(deviceSampleRate: Float64, bufferSize: Int) {
        guard let mock else {
            return
        }
        if deviceSampleRate != 0 {
            mock.inputFormat.mSampleRate = deviceSampleRate
            mock.outputFormat.mSampleRate = deviceSampleRate
        }
        mock.bufferSize.store(bufferSize, ordering: .relaxed)
    }

    // MockAudioCaptureInternalUnit::delaySamples(): pauses a running mock's quanta, until the main thread resumes them.
    func setMockPaused(_ paused: Bool) {
        guard let mock else {
            return
        }
        if paused {
            mock.stop()
        } else if !mock.isRunning {
            mock.start(renderState)
        }
    }
}

// A producer, which stores the quanta of the given format into the ring that C++ then attaches (audioUnitAttachRing()), or
// a peak (WebCore::AudioCaptureSink).
@_expose(Cxx)
func audioCaptureSinkCreate(_ isProducer: Bool, _ format: AudioStreamBasicDescription) -> UInt64 {
    addCaptureSink(CaptureSink(isProducer: isProducer, format: format))
}

// Its ring goes first, so C++ can then free it and the semaphore.
@_expose(Cxx)
func audioCaptureSinkDestroy(_ identifier: UInt64) {
    guard let sink = removeCaptureSink(identifier) else {
        return
    }
    if sink.isProducer {
        sink.detachRing()
    }
}

// The main thread enables a sink while its source produces data.
@_expose(Cxx)
func audioCaptureSinkSetEnabled(_ identifier: UInt64, _ value: Bool) {
    captureSink(identifier)?.setEnabled(value)
}

// A producer's first stored frame's MediaTime, once there's one, and the quanta it dropped because their format wasn't its.
@_expose(Cxx)
func audioCaptureSinkStatus(_ identifier: UInt64) -> WebCore.AudioCaptureSinkStatus {
    captureSink(identifier)?.status() ?? WebCore.AudioCaptureSinkStatus()
}

// A peak's largest sample magnitude since the last call.
@_expose(Cxx)
func audioCaptureSinkTakePeak(_ identifier: UInt64) -> Float {
    captureSink(identifier)?.takePeak() ?? 0
}

// On any thread: a unit heard speech while its output was muted (the device's listener on macOS, the voice processing unit's
// elsewhere).
func audioCaptureVoiceActivityDetected() {
#if ENABLE_MEDIA_STREAM
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            audioCaptureControllerVoiceActivityDetected()
        }
    }
#endif
}

func takeCaptureUnitEvents(_ identifier: UInt64) -> UInt32? {
    guard let unit = captureUnit(identifier) else {
        return nil
    }
    unit.renderState.collectRetiredSnapshots()
    return takeRenderStateEvents(unit.renderState)
}

// MARK: Tests

// Tests only (WebCore::AudioCaptureUnitForTesting): a mock unit whose speaker plays out the track in the given format once
// started, rendered by audioOutputUnitRenderForTesting() on the test's thread.
@_expose(Cxx)
func audioCaptureUnitCreateMockSpeakerForTesting(_ trackPlayoutIdentifier: UInt64, _ format: AudioStreamBasicDescription) -> UInt64 {
    guard let unit = CaptureUnit.create(.mockWithEchoCancellation).unit else {
        return 0
    }
    _ = unit.configureSpeaker(format.mSampleRate, format)
    unit.attachSpeakerTrack(trackPlayout(trackPlayoutIdentifier))
    unit.setSwitch(.speakerStartAcknowledged, true)
    return addCaptureUnit(unit)
}

// Tests only: a running mock unit with echo cancellation at 44100 Hz that feeds the given sinks (0: none) its samples times
// gain, and no C++ observer.
@_expose(Cxx)
func audioCaptureUnitStartMockMicrophoneForTesting(_ gain: Float, _ firstSinkIdentifier: UInt64, _ secondSinkIdentifier: UInt64) -> UInt64 {
    mockShouldIncreaseBufferSize.store(false, ordering: .relaxed)
    guard let unit = CaptureUnit.create(.mockWithEchoCancellation).unit, let format = unit.configureMicrophone(44100).format else {
        return 0
    }
    var sizes = WebCore.AudioCaptureMicrophoneBufferSizes()
    sizes.bufferCount = format.mChannelsPerFrame
    sizes.channelsPerBuffer = 1
    sizes.bytesPerBuffer = 8192
    unit.allocateMicrophoneBuffers(format, sizes, sampleRate: 44100, dtsConversionRatio: 1e-9)
    _ = unit.configureSpeaker(44100, nil)
    guard unit.initialize() == noErr else {
        return 0
    }
    unit.configureMock(deviceSampleRate: 0, bufferSize: 512)
    unit.setSwitch(.producingMicrophoneSamples, true)
    for sinkIdentifier in [firstSinkIdentifier, secondSinkIdentifier] where sinkIdentifier != 0 {
        unit.attachSink(sinkIdentifier, true)
        captureSink(sinkIdentifier)?.setEnabled(true)
    }
    unit.setMicrophoneOptions(gain: gain, appliesGain: true, deliversToCxx: false)
    let identifier = addCaptureUnit(unit)
    guard unit.start() == noErr else {
        audioCaptureUnitDestroyForTesting(identifier)
        return 0
    }
    return identifier
}

// Tests only: stops and disposes of a unit that a test made.
@_expose(Cxx)
func audioCaptureUnitDestroyForTesting(_ identifier: UInt64) {
    _ = removeCaptureUnit(identifier)?.destroy()
}

// MARK: The mock

// MockAudioCaptureInternalUnit: a capture unit without hardware. Every 20 ms, its queue fills its buffers with a bip-bop,
// a hum and, without echo cancellation, a noise, then calls the unit's microphone and speaker callbacks. The main thread
// changes its formats only while it is stopped.
final class MockCaptureBackend: @unchecked Sendable {
    // The speaker's format, which its buffers have (kAudioUnitScope_Input), and the microphone's (kAudioUnitScope_Output).
    var inputFormat: AudioStreamBasicDescription
    var outputFormat: AudioStreamBasicDescription
    let bufferSize = Atomic<Int>(512)
    private let enableEchoCancellation: Bool
    private let buffers = makeMockCaptureBuffers()
    // The queue's.
    private var bipBop: [Float] = []
    private var samplesEmitted: UInt64 = 0
    private var samplesRendered: UInt64 = 0
    private let isProducingData = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "MockAudioCaptureInternalUnit Capture Queue", qos: .userInteractive)

    init(enableEchoCancellation: Bool) {
        self.enableEchoCancellation = enableEchoCancellation
        inputFormat = mockFormat(sampleRate: 44100, channelCount: 2)
        outputFormat = inputFormat
    }

    var isRunning: Bool {
        isProducingData.load(ordering: .relaxed)
    }

    func initialize() -> OSStatus {
        outputFormat.mSampleRate != inputFormat.mSampleRate ? -1 : noErr
    }

    // Once stopped.
    func freeBuffers() {
        freeMockCaptureBuffers(buffers)
    }

    func attachRender(_ state: RenderStateReference) {
        attachMockCaptureRender(state, buffers)
    }

    func start(_ state: RenderStateReference) {
        isProducingData.store(true, ordering: .relaxed)
        let format = inputFormat
        let renderTime = DispatchTime.now()
        queue.async { [self] in
            generate(renderTime, state, format)
        }
    }

    func stop() {
        isProducingData.store(false, ordering: .relaxed)
        queue.sync {}
    }

    private var renderInterval: Double { 0.02 }

    // MockAudioCaptureInternalUnit::sampleRate().
    private func sampleRate(_ format: AudioStreamBasicDescription) -> Int {
        Int(format.mSampleRate)
    }

    // MockAudioCaptureInternalUnit::reconfigure().
    private func reconfigure(_ format: AudioStreamBasicDescription) {
        let rate = sampleRate(format)
        buffers.allocate(format, frameCount: roundUpToPowerOfTwo(Int(renderInterval * Double(rate) * 2)))
        bipBop = makeBipBop(rate, enableEchoCancellation)
    }

    private func generate(_ renderTime: DispatchTime, _ state: RenderStateReference, _ format: AudioStreamBasicDescription) {
        var nextRenderTime = renderTime + renderInterval
        let now = DispatchTime.now()
        if nextRenderTime < now {
            nextRenderTime = now
        }
        let renderTime = nextRenderTime
        queue.asyncAfter(deadline: renderTime) { [self] in
            if isProducingData.load(ordering: .relaxed) {
                generate(renderTime, state, format)
            }
        }
        if !buffers.isAllocated || bipBop.isEmpty {
            reconfigure(format)
        }
        let rate = sampleRate(format)
        let bufferSize = UInt32(truncatingIfNeeded: self.bufferSize.load(ordering: .relaxed))
        var totalFrameCount = UInt32(truncatingIfNeeded: (Int(renderInterval * Double(rate)) + 15) & ~15)
        var frameCount = min(totalFrameCount, bufferSize)
        let humPeriod = Float(rate) / Float(150)
        while frameCount != 0 {
            let bipBopStart = UInt32(truncatingIfNeeded: samplesRendered % UInt64(bipBop.count))
            let bipBopCount = min(frameCount, UInt32(truncatingIfNeeded: bipBop.count) - bipBopStart)
            buffers.fill(
                byteCount: frameCount &* format.mBytesPerFrame,
                bipBop,
                start: Int(bipBopStart),
                count: Int(bipBopCount),
                humStart: samplesRendered,
                humPeriod: humPeriod
            )
            let sampleTime = Double(Int64(bitPattern: samplesEmitted)) / Double(Int32(truncatingIfNeeded: rate))
            samplesEmitted &+= UInt64(bipBopCount)
            let exposedFrameCount = mockShouldIncreaseBufferSize.load(ordering: .relaxed) ? 10 &* bipBopCount : bipBopCount
            emitMockQuantum(state, buffers, sampleTime: sampleTime, frameCount: bipBopCount, exposedFrameCount: exposedFrameCount)
            samplesRendered &+= UInt64(bipBopCount)
            totalFrameCount &-= bipBopCount
            frameCount = min(totalFrameCount, bufferSize)
        }
    }
}

// createAudioFormat(): deinterleaved Float32.
private func mockFormat(sampleRate: Float64, channelCount: UInt32) -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    format.mSampleRate = sampleRate
    format.mFormatID = kAudioFormatLinearPCM
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved
    format.mBytesPerPacket = 4
    format.mFramesPerPacket = 1
    format.mBytesPerFrame = 4
    format.mChannelsPerFrame = channelCount
    format.mBitsPerChannel = 32
    return format
}

private func roundUpToPowerOfTwo(_ value: Int) -> Int {
    var result = 1
    while result < value {
        result <<= 1
    }
    return result
}

// Two seconds: a 1500 Hz bip at 0 s and a 500 Hz bop at 1 s, each 70 ms at half volume, plus a quiet 3000 Hz noise
// without echo cancellation, as MockAudioCaptureInternalUnit::reconfigure() made them with addHum().
private func makeBipBop(_ rate: Int, _ enableEchoCancellation: Bool) -> [Float] {
    let sampleCount = 2 * rate
    var samples = [Float](repeating: 0, count: sampleCount)
    let bipBopSampleCount = Int((0.07 * Double(rate)).rounded(.up))
    func addHum(_ amplitude: Float, _ frequency: Float, _ start: Int, _ count: Int) {
        precondition(start >= 0 && count >= 0 && count <= sampleCount - start)
        let humPeriod = Float(rate) / frequency
        let tau = 2 * Double.pi
        for i in 0..<count {
            samples[start + i] += Float(Double(amplitude) * sin(Double(UInt64(i)) * tau / Double(humPeriod)))
        }
    }
    addHum(0.5, 1500, 0, bipBopSampleCount)
    addHum(0.5, 500, rate, bipBopSampleCount)
    if !enableEchoCancellation {
        addHum(0.05, 3000, 0, sampleCount)
    }
    return samples
}

#endif // ENABLE_WEBCORE_SWIFT
