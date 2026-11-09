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

    func setUInt32(_ value: UInt32, for property: AudioUnitPropertyID, scope: AudioUnitScope) -> OSStatus {
        var value = value
        return unsafe AudioUnitSetProperty(unit, property, scope, 0, &value, UInt32(MemoryLayout<UInt32>.size))
    }

    func streamFormat(_ format: inout AudioStreamBasicDescription, scope: AudioUnitScope) -> OSStatus {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return unsafe AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, &size)
    }

    func streamFormat(scope: AudioUnitScope) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = unsafe AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, &size)
        return format
    }

    func setStreamFormat(_ format: AudioStreamBasicDescription, scope: AudioUnitScope) -> OSStatus {
        var format = format
        return unsafe AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            scope,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
    }

    func installRenderCallback(_ callback: SwiftRenderCallback, scope: AudioUnitScope) -> OSStatus {
        unsafe setRenderCallback(callback.function, renderState.refCon, scope: scope)
    }

    func setRenderCallback(_ callback: AURenderCallback, _ refCon: UnsafeMutableRawPointer?, scope: AudioUnitScope)
        -> OSStatus
    {
        var callbackStruct = unsafe AURenderCallbackStruct(inputProc: callback, inputProcRefCon: refCon)
        return unsafe AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            scope,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
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

// The Swift render callbacks of AudioUnitIsland.swift that a unit can have, with its render state as refCon.
enum SwiftRenderCallback {
    case remoteDestination
    case trackPlayout
    case inProcessTrack
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
