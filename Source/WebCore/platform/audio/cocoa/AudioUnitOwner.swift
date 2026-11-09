// Copyright (C) 2010 Google Inc. All rights reserved.
// Copyright (C) 2011, 2014, 2020 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1.  Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 3.  Neither the name of Apple Inc. ("Apple") nor the names of
//     its contributors may be used to endorse or promote products derived
//     from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2020 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

import AudioToolbox
#if os(macOS)
import CoreAudio
#endif
import Synchronization
import WebCore_Private.Core.CARingBufferSwiftBridge

// An IO AudioUnit, from its creation to its disposal, on the main thread, through the soft-linked AudioToolbox accessors.
// Its typestate orders the calls: only a stopped unit can be disposed of, and the state its render callback uses is
// allocated before the callback can be installed and freed only once the unit is disposed of. Dropping an owner without
// disposing of it traps.
@safe struct AudioUnitOwner: ~Copyable {
    private let unit: AudioUnit
    let renderState: RenderStateReference

    enum MakeResult: ~Copyable {
        case made(AudioUnitOwner)
        case noComponent
        case failed(OSStatus)
    }

    // An output unit of the given subtype, or why there's none.
    static func make(componentSubType: OSType, renderSampleCapacity: Int) -> MakeResult {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = unsafe AudioComponentFindNext(nil, &description) else {
            return .noComponent
        }
        var instance: AudioComponentInstance?
        let status = unsafe AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance = unsafe instance else {
            return .failed(status)
        }
        return .made(unsafe AudioUnitOwner(instance, renderSampleCapacity))
    }

    private init(_ instance: AudioUnit, _ renderSampleCapacity: Int) {
        unsafe unit = instance
        renderState = makeRenderState(sampleCapacity: renderSampleCapacity)
    }

#if os(macOS)
    // The stored voice processing unit, if there's one (storeForReuse(), prewarmVoiceProcessingUnit()).
    static func takeStoredVoiceProcessingUnit(renderSampleCapacity: Int) -> AudioUnitOwner? {
        precondition(WTF.isMainThread())
        guard let stored = unsafe storedVoiceProcessingUnit.exchange(nil, ordering: .acquiring) else {
            return nil
        }
        return unsafe AudioUnitOwner(AudioUnit(OpaquePointer(stored)), renderSampleCapacity)
    }

    // Keeps a stopped voice processing unit for the next capture, which starts sooner with it, instead of disposing of it.
    // Its callbacks go, with the state they render with.
    consuming func storeForReuse() {
        precondition(WTF.isMainThread())
        _ = unsafe setRenderCallback(nil, nil, property: kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, element: 1)
        _ = unsafe setRenderCallback(nil, nil, property: kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, element: 0)
        freeRenderState(renderState)
        let raw = unsafe UnsafeMutableRawPointer(unit)
        discard self
        if let previous = unsafe storedVoiceProcessingUnit.exchange(raw, ordering: .acquiringAndReleasing) {
            _ = unsafe AudioComponentInstanceDispose(AudioUnit(OpaquePointer(previous)))
        }
    }

    // On any thread: makes a voice processing unit and stores it, unless one is stored already. Returns whether one is.
    static func prewarmVoiceProcessingUnit() -> Bool {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = unsafe AudioComponentFindNext(nil, &description) else {
            return false
        }
        var instance: AudioComponentInstance?
        guard unsafe AudioComponentInstanceNew(component, &instance) == noErr, let instance = unsafe instance else {
            return false
        }
        let raw = UnsafeMutableRawPointer(instance)
        if !(unsafe storedVoiceProcessingUnit.compareExchange(expected: nil, desired: raw, ordering: .acquiringAndReleasing).exchanged) {
            _ = unsafe AudioComponentInstanceDispose(instance)
        }
        return true
    }

    // The main thread's, after a while without a capture.
    static func deallocateStoredVoiceProcessingUnit() {
        precondition(WTF.isMainThread())
        if let stored = unsafe storedVoiceProcessingUnit.exchange(nil, ordering: .acquiring) {
            _ = unsafe AudioComponentInstanceDispose(AudioUnit(OpaquePointer(stored)))
        }
    }
#endif

    // An output unit of the given subtype whose render callback can remember renderSampleCapacity samples.
    init?(componentSubType: OSType, renderSampleCapacity: Int) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = unsafe AudioComponentFindNext(nil, &description) else {
            return nil
        }
        var instance: AudioComponentInstance?
        guard unsafe AudioComponentInstanceNew(component, &instance) == noErr, let instance = unsafe instance else {
            return nil
        }
        unsafe unit = instance
        renderState = makeRenderState(sampleCapacity: renderSampleCapacity)
    }

    deinit {
        preconditionFailure()
    }

    func initialize() -> OSStatus {
        unsafe AudioUnitInitialize(unit)
    }

    func uninitialize() -> OSStatus {
        unsafe AudioUnitUninitialize(unit)
    }

    func setUInt32(_ value: UInt32, for property: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement = 0) -> OSStatus {
        var value = value
        return unsafe AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<UInt32>.size))
    }

    // A property whose value is the first size bytes of value, at most 8, such as a UInt32 or a small struct.
    func setSmallValue(_ value: UInt64, size: UInt32, for property: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement)
        -> OSStatus
    {
        precondition(size <= 8)
        var value = value
        return unsafe AudioUnitSetProperty(unit, property, scope, element, &value, size)
    }

    func uint32(for property: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement) -> (OSStatus, UInt32) {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = unsafe AudioUnitGetProperty(unit, property, scope, element, &value, &size)
        return (status, value)
    }

    func streamFormat(_ format: inout AudioStreamBasicDescription, scope: AudioUnitScope, element: AudioUnitElement = 0) -> OSStatus {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return unsafe AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, &size)
    }

    func streamFormat(scope: AudioUnitScope) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = unsafe AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, &size)
        return format
    }

    func setStreamFormat(_ format: AudioStreamBasicDescription, scope: AudioUnitScope, element: AudioUnitElement = 0) -> OSStatus {
        var format = format
        return unsafe AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            scope,
            element,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
    }

    func installRenderCallback(
        _ callback: SwiftRenderCallback,
        property: AudioUnitPropertyID = kAudioUnitProperty_SetRenderCallback,
        scope: AudioUnitScope,
        element: AudioUnitElement = 0
    ) -> OSStatus {
        unsafe setRenderCallback(callback.function, renderState.refCon, property: property, scope: scope, element: element)
    }

    func setRenderCallback(
        _ callback: AURenderCallback?,
        _ refCon: UnsafeMutableRawPointer?,
        property: AudioUnitPropertyID = kAudioUnitProperty_SetRenderCallback,
        scope: AudioUnitScope,
        element: AudioUnitElement = 0
    ) -> OSStatus {
        var callbackStruct = unsafe AURenderCallbackStruct(inputProc: callback, inputProcRefCon: refCon)
        return unsafe AudioUnitSetProperty(
            unit,
            property,
            scope,
            element,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
    }

#if os(iOS) || os(visionOS)
    // CoreAudioCaptureInternalUnit::setVoiceActivityDetection(): while its output is muted, a voice processing unit tells
    // WebCore when speech starts.
    func setMutedSpeechActivityListener(_ enable: Bool) -> OSStatus {
        if !enable {
            return unsafe AudioUnitSetProperty(unit, kAUVoiceIOProperty_MutedSpeechActivityEventListener, kAudioUnitScope_Global, 0, nil, 0)
        }
        let listener: AUVoiceIOMutedSpeechActivityEventListener = { event in
            // kAUVoiceIOSpeechActivityHasStarted.
            if event.rawValue == 0 {
                WebCore.audioCaptureVoiceActivityDetected()
            }
        }
        // The property's value is the block pointer, which the unit copies.
        let audioUnit = unsafe unit
        return withExtendedLifetime(listener) {
            var block = unsafe unsafeBitCast(listener, to: UnsafeRawPointer.self)
            return unsafe AudioUnitSetProperty(
                audioUnit,
                kAUVoiceIOProperty_MutedSpeechActivityEventListener,
                kAudioUnitScope_Global,
                0,
                &block,
                UInt32(MemoryLayout<UnsafeRawPointer>.size)
            )
        }
    }
#endif

    // A capture unit's microphone callback renders the unit's input with AudioUnitRender(), through the pointer this copies
    // on the main thread, so that the IO thread never resolves the soft link.
    func attachCaptureRender() {
        precondition(WTF.isMainThread())
        let render = unsafe unsafeBitCast(softLinkPointer_AudioUnitRender, to: CaptureRenderFunction.self)
        unsafe renderState.setCaptureRender(render, target: UnsafeMutableRawPointer(unit))
    }

    // A global property whose value is an object, passed as AudioUnitSetProperty()'s data, as the C++ did.
    func setObject(_ object: UnsafeMutableRawPointer?, for property: AudioUnitPropertyID) -> OSStatus {
        unsafe AudioUnitSetProperty(unit, property, kAudioUnitScope_Global, 0, object, UInt32(MemoryLayout<UnsafeRawPointer>.size))
    }

    // kAudioUnitProperty_Latency, as the size_t the C++ converted it to, or 0.
    func latency() -> UInt64 {
        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard unsafe AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size) == noErr
        else {
            return 0
        }
        return latency >= 0 && latency < 18_446_744_073_709_551_616.0 ? UInt64(latency) : 0
    }

    // AudioOutputUnitStop() on a unit that isn't running, which the C++ also called.
    func stopWhileStopped() -> OSStatus {
        unsafe AudioOutputUnitStop(unit)
    }

    // Renders one quantum of frameCount frames into ioData on this thread, through AudioUnitRender() or by calling the
    // remote destination render callback directly.
    func renderForTesting(
        _ renderCallback: SwiftRenderCallback,
        _ ioData: UnsafeMutablePointer<AudioBufferList>,
        _ frameCount: UInt32,
        _ sampleTime: Float64,
        _ throughAudioUnit: Bool,
        _ actionFlags: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid
        if throughAudioUnit {
            return unsafe AudioUnitRender(unit, actionFlags, &timeStamp, 0, frameCount, ioData)
        }
        return unsafe renderCallback.function(renderState.refCon, actionFlags, &timeStamp, 0, frameCount, ioData)
    }

    consuming func start() -> AudioUnitStartResult {
        let status = unsafe AudioOutputUnitStart(unit)
        if status != noErr {
            return .stopped(self, status)
        }
        return .running(RunningAudioUnit(owner: self))
    }

    consuming func dispose() {
        _ = unsafe AudioUnitUninitialize(unit)
        _ = unsafe AudioComponentInstanceDispose(unit)
        freeRenderState(renderState)
        discard self
    }

    fileprivate func stopUnit() -> OSStatus {
        unsafe AudioOutputUnitStop(unit)
    }

    fileprivate func startUnit() -> OSStatus {
        unsafe AudioOutputUnitStart(unit)
    }

    fileprivate func latencyWhileRunning() -> UInt64 {
        latency()
    }
}

#if os(macOS)
// CoreAudioCaptureUnit's voice activity detection on macOS, which the capture device does: enables or disables it and the
// listener of its state, which tells WebCore when speech starts. Returns noErr, or the status of the step that failed (1:
// enabling or disabling the detection, 2: adding or removing the listener).
func setDeviceVoiceActivityDetection(_ deviceID: AudioObjectID, _ enable: Bool) -> (OSStatus, UInt32) {
    var enableAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var shouldEnable: UInt32 = enable ? 1 : 0
    let status = unsafe AudioObjectSetPropertyData(deviceID, &enableAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &shouldEnable)
    if status != noErr {
        return (status, 1)
    }
    var stateAddress = voiceActivityStateAddress
    let listenerStatus =
        enable
        ? unsafe AudioObjectAddPropertyListener(deviceID, &stateAddress, voiceActivityListener, nil)
        : unsafe AudioObjectRemovePropertyListener(deviceID, &stateAddress, voiceActivityListener, nil)
    return (listenerStatus, listenerStatus == noErr ? 0 : 2)
}

private var voiceActivityStateAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
}

// On a HAL notification thread, as CoreAudioCaptureUnit::processVoiceActivityEvent() was.
private func voiceActivityListener(
    _ deviceID: AudioObjectID,
    _ addressCount: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    var address = voiceActivityStateAddress
    var voiceDetected: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    if unsafe AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &voiceDetected) == kAudioHardwareNoError && voiceDetected == 1 {
        WebCore.audioCaptureVoiceActivityDetected()
    }
    return 0
}

// A voice processing unit without render state, kept by the main thread or made ahead of time by any thread.
nonisolated(unsafe) private let storedVoiceProcessingUnit = unsafe Atomic<UnsafeMutableRawPointer?>(nil)
#endif

// The Swift render callbacks of AudioUnitIsland.swift that a unit can have, with its render state as refCon.
enum SwiftRenderCallback {
    case remoteDestination
    case trackPlayout
    case inProcessTrack
    case microphone
    case speaker
}

enum AudioUnitStartResult: ~Copyable {
    case running(RunningAudioUnit)
    case stopped(AudioUnitOwner, OSStatus)
}

enum AudioUnitStopResult: ~Copyable {
    case stopped(AudioUnitOwner)
    case running(RunningAudioUnit, OSStatus)
}

// A unit between a successful AudioOutputUnitStart() and a successful AudioOutputUnitStop(). It can't be disposed of.
struct RunningAudioUnit: ~Copyable {
    fileprivate let owner: AudioUnitOwner

    // AudioOutputUnitStart() again, which the C++ also called.
    func startWhileRunning() -> OSStatus {
        owner.startUnit()
    }

    func latency() -> UInt64 {
        owner.latencyWhileRunning()
    }

    func setObject(_ object: UnsafeMutableRawPointer?, for property: AudioUnitPropertyID) -> OSStatus {
        unsafe owner.setObject(object, for: property)
    }

    // What a running unit can do that a stopped one can, such as setting a property.
    func withOwner<Result>(_ body: (borrowing AudioUnitOwner) -> Result) -> Result {
        body(owner)
    }

    consuming func stop() -> AudioUnitStopResult {
        let status = owner.stopUnit()
        if status != noErr {
            return .running(self, status)
        }
        return .stopped(owner)
    }

    // AudioComponentInstanceDispose() stops a unit that is still running, so this hands the owner back either way.
    consuming func stopForDisposal() -> AudioUnitOwner {
        _ = owner.stopUnit()
        return owner
    }
}

#endif // ENABLE_WEBCORE_SWIFT
