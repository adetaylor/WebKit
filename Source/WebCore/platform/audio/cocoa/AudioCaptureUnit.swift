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

// The capture AudioUnits of CoreAudioCaptureUnit: voice processing, HALOutput on macOS or RemoteIO, or a mock that needs no
// hardware. C++ reaches them through WebCore::AudioCaptureUnitHandle, by identifier, on the main thread only. Their
// microphone and speaker callbacks are Swift (AudioUnitIsland.swift): the microphone's renders into the unit's own buffers
// and hands each quantum to the C++ that delivers it to the observers; the speaker's plays out a track playout, Swift to
// Swift.

// WebCore::AudioCaptureUnitHandle::Kind.
enum CaptureUnitKind: UInt8 {
    case voiceProcessing
    case plain
    case mockWithEchoCancellation
    case mockWithoutEchoCancellation

    var isMock: Bool {
        self == .mockWithEchoCancellation || self == .mockWithoutEchoCancellation
    }
}

// WebCore::AudioCaptureUnitHandle::Switch: what the main thread tells the IO threads.
enum CaptureUnitSwitch: UInt8 {
    case producingMicrophoneSamples
    case reconfiguring
    // The speaker's producer knows that the unit started (AudioUnitEvent.speakerStarting), so the speaker can play it out.
    case speakerStartAcknowledged
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
            renderState.returnCurrentSnapshotWhileStopped()
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
            renderState.returnCurrentSnapshotWhileStopped()
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
        }
    }
}

// MARK: The C++ API

private func withCaptureUnit<Result>(_ identifier: UInt64, _ missing: Result, _ body: (CaptureUnit) -> Result) -> Result {
    guard let unit = captureUnit(identifier) else {
        return missing
    }
    return body(unit)
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

// A capture unit of the given kind (createAudioUnit() and CoreAudioCaptureInternalUnit::create()), on macOS the stored voice
// processing unit if there's one, or 0 and the status of AudioComponentInstanceNew() (-1 without a component).
@_expose(Cxx)
func audioCaptureUnitCreate(_ kind: UInt8) -> WebCore.AudioCaptureUnitCreation {
    precondition(WTF.isMainThread())
    guard let kind = CaptureUnitKind(rawValue: kind) else {
        preconditionFailure()
    }
    var result = WebCore.AudioCaptureUnitCreation()
    if kind.isMock {
        result.identifier = addCaptureUnit(CaptureUnit(mockWithEchoCancellation: kind == .mockWithEchoCancellation))
        return result
    }
#if os(macOS)
    if kind == .voiceProcessing, let stored = AudioUnitOwner.takeStoredVoiceProcessingUnit(renderSampleCapacity: 0) {
        result.identifier = addCaptureUnit(CaptureUnit(kind, stored))
        result.reusedStoredUnit = true
        return result
    }
#endif
    switch AudioUnitOwner.make(componentSubType: componentSubType(kind), renderSampleCapacity: 0) {
    case .made(let owner):
        result.identifier = addCaptureUnit(CaptureUnit(kind, owner))
    case .noComponent:
        result.status = -1
    case .failed(let status):
        result.status = status
    }
    return result
}

// Returns whether a voice processing unit was kept for the next capture (macOS), which C++ deallocates after a while.
@_expose(Cxx)
func audioCaptureUnitDestroy(_ identifier: UInt64) -> Bool {
    guard let unit = removeCaptureUnit(identifier) else {
        return false
    }
    return unit.destroy()
}

// A property whose value is the first size bytes of value, at most 8: a UInt32, or kAUVoiceIOProperty_OtherAudioDuckingConfiguration's
// struct. A mock has no properties.
@_expose(Cxx)
func audioCaptureUnitSetProperty(_ identifier: UInt64, _ property: UInt32, _ scope: UInt32, _ element: UInt32, _ value: UInt64, _ size: UInt32)
    -> Int32
{
    withCaptureUnit(identifier, kAudio_ParamError) { unit in
        if unit.kind.isMock {
            return noErr
        }
        return unit.withOwner(kAudio_ParamError) { $0.setSmallValue(value, size: size, for: property, scope: scope, element: element) }
    }
}

@_expose(Cxx)
func audioCaptureUnitGetUInt32Property(_ identifier: UInt64, _ property: UInt32, _ scope: UInt32, _ element: UInt32)
    -> WebCore.AudioCaptureUnitPropertyValue
{
    var result = WebCore.AudioCaptureUnitPropertyValue()
    result.status = withCaptureUnit(identifier, kAudio_ParamError) { unit in
        if unit.kind.isMock {
            return noErr
        }
        return unit.withOwner(kAudio_ParamError) { owner in
            let (status, value) = owner.uint32(for: property, scope: scope, element: element)
            result.value = value
            return status
        }
    }
    return result
}

// CoreAudioCaptureUnit::configureMicrophoneProc(), up to its buffer: installs the microphone callback and sets the
// microphone's format to the unit's own at sampleRate, which it returns. Without a format, failedStep says which step
// failed (1: setting the callback, 2: getting the format, 3: setting it).
@_expose(Cxx)
func audioCaptureUnitConfigureMicrophone(_ identifier: UInt64, _ sampleRate: Float64) -> WebCore.AudioCaptureUnitFormat {
    var result = WebCore.AudioCaptureUnitFormat()
    withCaptureUnit(identifier, ()) { unit in
        if let mock = unit.mock {
            mock.outputFormat.mSampleRate = sampleRate
            result.format = mock.outputFormat
            return
        }
        unit.withOwner(()) { owner in
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
    }
    return result
}

// The microphone's buffers, the sizes of CoreAudioCaptureUnit's AudioSampleBufferList's, and how the microphone times its
// quanta.
@_expose(Cxx)
func audioCaptureUnitAllocateMicrophoneBuffers(_ identifier: UInt64, _ buffers: WebCore.AudioCaptureMicrophoneBuffers) {
    withCaptureUnit(identifier, ()) { unit in
        precondition(!unit.isRunning)
        unit.renderState.allocateMicrophoneBuffers(
            bufferCount: Int(buffers.bufferCount),
            byteCount: Int(buffers.bytesPerBuffer),
            channelsPerBuffer: buffers.channelsPerBuffer
        )
        unit.renderState.setMicrophoneTiming(sampleRate: buffers.sampleRate, dtsConversionRatio: buffers.dtsConversionRatio)
        if let mock = unit.mock {
            mock.attachRender(unit.renderState)
        } else {
            unit.withOwner(()) { $0.attachCaptureRender() }
        }
    }
}

// CoreAudioCaptureUnit::configureSpeakerProc(): installs the speaker callback and sets the speaker's format to the
// producer's, or to the unit's own, at sampleRate, which it returns. Without a format, failedStep says which step failed
// (1: setting the callback, 2: getting the format, 3: setting it).
@_expose(Cxx)
func audioCaptureUnitConfigureSpeaker(
    _ identifier: UInt64,
    _ sampleRate: Float64,
    _ producerFormat: AudioStreamBasicDescription,
    _ hasProducerFormat: Bool
) -> WebCore.AudioCaptureUnitFormat {
    var result = WebCore.AudioCaptureUnitFormat()
    withCaptureUnit(identifier, ()) { unit in
        var format = producerFormat
        if let mock = unit.mock {
            if !hasProducerFormat {
                format = mock.inputFormat
            }
            format.mSampleRate = sampleRate
            mock.inputFormat = format
        } else {
            unit.withOwner(()) { owner in
                result.status = owner.installRenderCallback(.speaker, scope: kAudioUnitScope_Input, element: outputBus)
                if result.status != noErr {
                    result.failedStep = 1
                    return
                }
                if !hasProducerFormat {
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
                return
            }
        }
        unit.renderState.setSpeakerBytesPerFrame(UInt64(format.mBytesPerFrame))
        result.format = format
    }
    return result
}

@_expose(Cxx)
func audioCaptureUnitInitialize(_ identifier: UInt64) -> Int32 {
    withCaptureUnit(identifier, kAudio_ParamError) { unit in
        if let mock = unit.mock {
            return mock.initialize()
        }
        return unit.withOwner(kAudio_ParamError) { $0.initialize() }
    }
}

@_expose(Cxx)
func audioCaptureUnitUninitialize(_ identifier: UInt64) -> Int32 {
    withCaptureUnit(identifier, kAudio_ParamError) { unit in
        if unit.mock != nil {
            return noErr
        }
        return unit.withOwner(kAudio_ParamError) { $0.uninitialize() }
    }
}

// Once started, the speaker callback tells the main thread to tell the speaker's producer (AudioUnitEvent.speakerStarting),
// and plays out its track once the main thread has (CaptureUnitSwitch.speakerStartAcknowledged).
@_expose(Cxx)
func audioCaptureUnitStart(_ identifier: UInt64) -> Int32 {
    withCaptureUnit(identifier, kAudio_ParamError) { $0.start() }
}

@_expose(Cxx)
func audioCaptureUnitStop(_ identifier: UInt64) -> Int32 {
    withCaptureUnit(identifier, kAudio_ParamError) { $0.stop() }
}

@_expose(Cxx)
func audioCaptureUnitSetSwitch(_ identifier: UInt64, _ captureSwitch: UInt8, _ value: Bool) {
    guard let captureSwitch = CaptureUnitSwitch(rawValue: captureSwitch) else {
        preconditionFailure()
    }
    withCaptureUnit(identifier, ()) { $0.setSwitch(captureSwitch, value) }
}

// The microphone's quanta since the unit last started, and the frame count of the first quantum its buffer was too small for.
@_expose(Cxx)
func audioCaptureUnitCounters(_ identifier: UInt64) -> WebCore.AudioCaptureUnitCounters {
    var counters = WebCore.AudioCaptureUnitCounters()
    withCaptureUnit(identifier, ()) { unit in
        counters.microphoneProcCount = unit.renderState.microphoneProcCount
        let failedRenderFrames = unit.renderState.failedRenderFrames
        counters.hasFailedRenderFrameCount = failedRenderFrames & failedRenderFlag != 0
        counters.failedRenderFrameCount = UInt32(truncatingIfNeeded: failedRenderFrames)
    }
    return counters
}

func takeCaptureUnitEvents(_ identifier: UInt64) -> UInt32? {
    guard let unit = captureUnit(identifier) else {
        return nil
    }
    unit.renderState.collectRetiredSnapshot()
    return takeRenderStateEvents(unit.renderState)
}

#if os(iOS) || os(visionOS)
@_expose(Cxx)
func audioCaptureUnitSetMutedSpeechActivityListener(_ identifier: UInt64, _ enable: Bool) -> Int32 {
    withCaptureUnit(identifier, kAudio_ParamError) { unit in
        if unit.kind.isMock {
            return noErr
        }
        return unit.withOwner(kAudio_ParamError) { $0.setMutedSpeechActivityListener(enable) }
    }
}
#endif

#if os(macOS)
// CoreAudioCaptureUnit::prewarmAudioUnitCreation(), on its creation queue: makes a voice processing unit for the next
// capture. Returns whether one is stored, which C++ deallocates after a while.
@_expose(Cxx)
func audioCaptureUnitPrewarmVoiceProcessingUnit() -> Bool {
    AudioUnitOwner.prewarmVoiceProcessingUnit()
}

@_expose(Cxx)
func audioCaptureUnitDeallocateStoredVoiceProcessingUnit() {
    AudioUnitOwner.deallocateStoredVoiceProcessingUnit()
}
#endif

// The mock's device sample rate, which its formats follow (0: none), and the AudioSession buffer size its quanta follow.
@_expose(Cxx)
func audioCaptureUnitConfigureMock(_ identifier: UInt64, _ deviceSampleRate: Float64, _ bufferSize: UInt64) {
    withCaptureUnit(identifier, ()) { unit in
        guard let mock = unit.mock else {
            return
        }
        if deviceSampleRate != 0 {
            mock.inputFormat.mSampleRate = deviceSampleRate
            mock.outputFormat.mSampleRate = deviceSampleRate
        }
        mock.bufferSize.store(Int(truncatingIfNeeded: bufferSize), ordering: .relaxed)
    }
}

// MockAudioCaptureInternalUnit::delaySamples(): pauses a running mock's quanta, until C++ resumes them.
@_expose(Cxx)
func audioCaptureUnitSetMockPaused(_ identifier: UInt64, _ paused: Bool) {
    withCaptureUnit(identifier, ()) { unit in
        guard let mock = unit.mock else {
            return
        }
        if paused {
            mock.stop()
        } else if !mock.isRunning {
            mock.start(unit.renderState)
        }
    }
}

// MockAudioCaptureUnit::increaseBufferSize(): the mocks' quanta fake a microphone buffer that is too small, until a buffer
// is big enough.
@_expose(Cxx)
func audioCaptureUnitSetMockIncreaseBufferSize(_ value: Bool) {
    mockShouldIncreaseBufferSize.store(value, ordering: .relaxed)
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
