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

// The output AudioUnits of WebCore and the GPU process: the default output unit (RemoteIO on iOS), owned here and
// configured as WebCore's C++ configured it. C++ reaches them through WebCore::AudioOutputUnit, by identifier, on the main
// thread only. What renders a unit's quanta is attached while it is stopped:
// - a GPU-process audio destination plays out the ring the web process writes, in Swift (AudioUnitIsland.swift);
// - an in-process audio destination (AudioDestinationCocoa) renders in C++, from a callback that the unit calls directly.

// WebCore::AudioOutputUnit::Kind.
enum OutputUnitKind: UInt8 {
    case remoteDestination
    case inProcessDestination
    // A remote destination on a generic output unit, which needs no hardware: tests render it on their own thread.
    case genericOutputForTesting
}

final class OutputUnit {
    let kind: OutputUnitKind
    let renderCallbackScope: AudioUnitScope
    var stopped: AudioUnitOwner?
    var running: RunningAudioUnit?
    var hasRenderCallback: Bool

    init(_ kind: OutputUnitKind, _ renderCallbackScope: AudioUnitScope, _ owner: consuming AudioUnitOwner?) {
        self.kind = kind
        self.renderCallbackScope = renderCallbackScope
        stopped = consume owner
        hasRenderCallback = kind != .inProcessDestination
    }

    deinit {
        if let running = running.take() {
            running.stopForDisposal().dispose()
        }
        if let stopped = stopped.take() {
            stopped.dispose()
        }
    }

    func start() -> OSStatus {
        if let unit = running.take() {
            let status = unit.startWhileRunning()
            running = consume unit
            return status
        }
        guard let owner = stopped.take() else {
            return kAudio_ParamError
        }
        precondition(hasRenderCallback)
        switch owner.start() {
        case .running(let unit):
            running = consume unit
            return noErr
        case .stopped(let owner, let status):
            stopped = consume owner
            return status
        }
    }

    func stop() -> OSStatus {
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
            return noErr
        case .running(let unit, let status):
            running = consume unit
            return status
        }
    }

    func latency() -> UInt64 {
        if let owner = stopped.take() {
            let latency = owner.latency()
            stopped = consume owner
            return latency
        }
        if let unit = running.take() {
            let latency = unit.latency()
            running = consume unit
            return latency
        }
        return 0
    }

    func setObject(_ object: UnsafeMutableRawPointer?, for property: AudioUnitPropertyID) -> OSStatus {
        if let owner = stopped.take() {
            let status = unsafe owner.setObject(object, for: property)
            stopped = consume owner
            return status
        }
        if let unit = running.take() {
            let status = unsafe unit.setObject(object, for: property)
            running = consume unit
            return status
        }
        return kAudio_ParamError
    }

    var isRunning: Bool {
        running != nil
    }

    // The render state of a stopped unit that exists.
    func withStoppedRenderState(_ body: (RenderStateReference) -> Void) {
        precondition(!isRunning)
        if let owner = stopped.take() {
            body(owner.renderState)
            stopped = consume owner
        }
    }

    func renderForTesting(_ ioData: UnsafeMutablePointer<AudioBufferList>, _ frameCount: UInt32, _ sampleTime: Float64, _ throughAudioUnit: Bool)
        -> OSStatus
    {
        precondition(kind != .inProcessDestination && (kind == .genericOutputForTesting || !throughAudioUnit))
        guard let owner = stopped.take() else {
            return kAudio_ParamError
        }
        let status = unsafe owner.renderForTesting(ioData, frameCount, sampleTime, throughAudioUnit)
        stopped = consume owner
        return status
    }

    func setCxxRenderCallback(_ callback: AURenderCallback, _ refCon: UnsafeMutableRawPointer?) {
        precondition(kind == .inProcessDestination && !isRunning)
        hasRenderCallback = true
        if let owner = stopped.take() {
            _ = unsafe owner.setRenderCallback(callback, refCon, scope: renderCallbackScope)
            stopped = consume owner
        }
    }
}

// The stream format of the destinations: deinterleaved Float32.
private func setFloat32StreamFormat(_ format: inout AudioStreamBasicDescription, _ sampleRate: Float, _ channelCount: UInt32) {
    format.mSampleRate = Float64(sampleRate)
    format.mFormatID = kAudioFormatLinearPCM
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved
    format.mBytesPerPacket = 4
    format.mFramesPerPacket = 1
    format.mBytesPerFrame = 4
    format.mChannelsPerFrame = channelCount
    format.mBitsPerChannel = 32
}

// Like the C++ it replaces, this goes on when a property can't be set; a unit that can't be made at all fails to start.
private func makeOutputUnit(_ kind: OutputUnitKind, _ sampleRate: Float, _ channelCount: UInt32) -> OutputUnit {
    let sampleCapacity = kind == .inProcessDestination ? 0 : Int(channelCount)
    if kind == .genericOutputForTesting {
        let scope = kAudioUnitScope_Input
        guard let owner = AudioUnitOwner(componentSubType: kAudioUnitSubType_GenericOutput, renderSampleCapacity: sampleCapacity)
        else {
            return OutputUnit(kind, scope, nil)
        }
        var format = AudioStreamBasicDescription()
        setFloat32StreamFormat(&format, sampleRate, channelCount)
        _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Input)
        _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Output)
        _ = unsafe owner.setRenderCallback(remoteDestinationRenderCallback, owner.renderState.refCon, scope: scope)
        _ = owner.initialize()
        return OutputUnit(kind, scope, owner)
    }
#if os(macOS)
    let scope = kAudioUnitScope_Global
    guard let owner = AudioUnitOwner(componentSubType: kAudioUnitSubType_DefaultOutput, renderSampleCapacity: sampleCapacity)
    else {
        return OutputUnit(kind, scope, nil)
    }
    _ = owner.initialize()
    if kind == .remoteDestination {
        _ = unsafe owner.setRenderCallback(remoteDestinationRenderCallback, owner.renderState.refCon, scope: scope)
    }
    var format = AudioStreamBasicDescription()
    setFloat32StreamFormat(&format, sampleRate, channelCount)
    _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Input)
#else
    let scope = kAudioUnitScope_Input
    guard let owner = AudioUnitOwner(componentSubType: kAudioUnitSubType_RemoteIO, renderSampleCapacity: sampleCapacity)
    else {
        return OutputUnit(kind, scope, nil)
    }
    _ = owner.setUInt32(1, for: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output)
    _ = owner.initialize()
    if kind == .remoteDestination {
        _ = unsafe owner.setRenderCallback(remoteDestinationRenderCallback, owner.renderState.refCon, scope: scope)
    }
    var format = owner.streamFormat(scope: kAudioUnitScope_Output)
    setFloat32StreamFormat(&format, sampleRate, channelCount)
    _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Input)
#endif
    return OutputUnit(kind, scope, owner)
}

private func withOutputUnit<Result>(_ identifier: UInt64, _ missing: Result, _ body: (OutputUnit) -> Result) -> Result {
    guard let unit = outputUnit(identifier) else {
        return missing
    }
    return body(unit)
}

// Calls body with the render state of a stopped unit, for AudioUnitIsland.swift's attach functions. Traps if the unit is
// running.
func withStoppedOutputUnitRenderState(_ identifier: UInt64, _ body: (RenderStateReference) -> Void) {
    withOutputUnit(identifier, ()) { $0.withStoppedRenderState(body) }
}

@_expose(Cxx)
func audioOutputUnitCreate(_ kind: UInt8, _ sampleRate: Float, _ channelCount: UInt32) -> UInt64 {
    precondition(WTF.isMainThread())
    guard let kind = OutputUnitKind(rawValue: kind) else {
        preconditionFailure()
    }
    return addOutputUnit(makeOutputUnit(kind, sampleRate, channelCount))
}

// Stops the unit if it is running, then disposes of it.
@_expose(Cxx)
func audioOutputUnitDestroy(_ identifier: UInt64) {
    _ = removeOutputUnit(identifier)
}

@_expose(Cxx)
func audioOutputUnitStart(_ identifier: UInt64) -> Int32 {
    withOutputUnit(identifier, kAudio_ParamError) { $0.start() }
}

@_expose(Cxx)
func audioOutputUnitStop(_ identifier: UInt64) -> Int32 {
    withOutputUnit(identifier, kAudio_ParamError) { $0.stop() }
}

@_expose(Cxx)
func audioOutputUnitLatency(_ identifier: UInt64) -> UInt64 {
    withOutputUnit(identifier, 0) { $0.latency() }
}

// Sets a global property whose value is an object, such as kAudioOutputUnitProperty_IntendedSpatialExperience.
@_expose(Cxx)
func audioOutputUnitSetObjectProperty(_ identifier: UInt64, _ property: UInt32, _ object: UnsafeMutableRawPointer?) -> Int32 {
    withOutputUnit(identifier, kAudio_ParamError) { unsafe $0.setObject(object, for: property) }
}

#endif // ENABLE_WEBCORE_SWIFT
