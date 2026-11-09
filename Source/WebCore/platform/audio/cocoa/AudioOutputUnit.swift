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
// Copyright (C) 2021 Apple Inc. All rights reserved.
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
    // A MediaStream track renderer: a GPU-process one plays out a ring (attachTrackPlayout()), an in-process one renders
    // from a C++ callback (attachRenderCallback()).
    case trackRenderer
}

final class OutputUnit {
    let kind: OutputUnitKind
    let renderCallbackScope: AudioUnitScope
    // The callback installed on the unit, if Swift's, and the state it renders with.
    let renderCallback: SwiftRenderCallback?
    let renderState: RenderStateReference?
    var stopped: AudioUnitOwner?
    var running: RunningAudioUnit?
    var hasRenderCallback: Bool

    init(_ kind: OutputUnitKind, _ renderCallbackScope: AudioUnitScope, _ renderCallback: SwiftRenderCallback?, _ owner: consuming AudioUnitOwner?) {
        self.kind = kind
        self.renderCallbackScope = renderCallbackScope
        self.renderCallback = renderCallback
        if let owner = owner.take() {
            renderState = owner.renderState
            stopped = consume owner
        } else {
            renderState = nil
            stopped = nil
        }
        hasRenderCallback = kind == .remoteDestination || kind == .genericOutputForTesting
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

    // Whether the unit is a track renderer that plays out a track (attachTrackPlayout()).
    var rendersPlayout = false

    func takeEvents() -> UInt32 {
        guard let renderState else {
            return 0
        }
        return takeRenderStateEvents(renderState)
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
            return OutputUnit(kind, scope, nil, nil)
        }
        var format = AudioStreamBasicDescription()
        setFloat32StreamFormat(&format, sampleRate, channelCount)
        _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Input)
        _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Output)
        _ = owner.installRenderCallback(.remoteDestination, scope: scope)
        _ = owner.initialize()
        return OutputUnit(kind, scope, .remoteDestination, owner)
    }
#if os(macOS)
    let scope = kAudioUnitScope_Global
    guard let owner = AudioUnitOwner(componentSubType: kAudioUnitSubType_DefaultOutput, renderSampleCapacity: sampleCapacity)
    else {
        return OutputUnit(kind, scope, nil, nil)
    }
    _ = owner.initialize()
    if kind == .remoteDestination {
        _ = owner.installRenderCallback(.remoteDestination, scope: scope)
    }
    var format = AudioStreamBasicDescription()
    setFloat32StreamFormat(&format, sampleRate, channelCount)
    _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Input)
#else
    let scope = kAudioUnitScope_Input
    guard let owner = AudioUnitOwner(componentSubType: kAudioUnitSubType_RemoteIO, renderSampleCapacity: sampleCapacity)
    else {
        return OutputUnit(kind, scope, nil, nil)
    }
    _ = owner.setUInt32(1, for: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output)
    _ = owner.initialize()
    if kind == .remoteDestination {
        _ = owner.installRenderCallback(.remoteDestination, scope: scope)
    }
    var format = owner.streamFormat(scope: kAudioUnitScope_Output)
    setFloat32StreamFormat(&format, sampleRate, channelCount)
    _ = owner.setStreamFormat(format, scope: kAudioUnitScope_Input)
#endif
    return OutputUnit(kind, scope, kind == .remoteDestination ? .remoteDestination : nil, owner)
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

// LocalAudioMediaStreamTrackRendererInternalUnit::createAudioUnitIfNeeded(): the default output unit (RemoteIO on iOS) on
// the given device (0: the default one, or iOS), in the given stream format or, if there's none, the unit's own at
// sampleRate. Its render callback plays out a track (rendersPlayout) or calls a C++ one.
@_expose(Cxx)
func audioOutputUnitCreateTrackRenderer(
    _ deviceID: UInt32,
    _ sampleRate: Float64,
    _ format: AudioStreamBasicDescription,
    _ hasFormat: Bool,
    _ rendersPlayout: Bool
) -> WebCore.AudioOutputUnitTrackRendererCreation {
    precondition(WTF.isMainThread())
#if os(macOS)
    let subType = kAudioUnitSubType_DefaultOutput
#else
    let subType = kAudioUnitSubType_RemoteIO
#endif
    let owner: AudioUnitOwner
    switch AudioUnitOwner.make(componentSubType: subType, renderSampleCapacity: 0) {
    case .made(let made):
        owner = made
    case .noComponent:
        return trackRendererCreationFailure(noErr, 1)
    case .failed(let status):
        return trackRendererCreationFailure(status, 2)
    }
#if os(macOS)
    if deviceID != 0 {
        let status = owner.setUInt32(deviceID, for: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global)
        if status != noErr {
            owner.dispose()
            return trackRendererCreationFailure(status, 4)
        }
    }
#else
    let enableStatus = owner.setUInt32(1, for: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output)
    if enableStatus != noErr {
        owner.dispose()
        return trackRendererCreationFailure(enableStatus, 3)
    }
#endif
    let callback: SwiftRenderCallback = rendersPlayout ? .trackPlayout : .inProcessTrack
    let callbackStatus = owner.installRenderCallback(callback, scope: kAudioUnitScope_Global)
    if callbackStatus != noErr {
        owner.dispose()
        return trackRendererCreationFailure(callbackStatus, 5)
    }
    var streamFormat = format
    if !hasFormat {
        let status = owner.streamFormat(&streamFormat, scope: kAudioUnitScope_Input)
        if status != noErr {
            owner.dispose()
            return trackRendererCreationFailure(status, 6)
        }
        streamFormat.mSampleRate = sampleRate
    }
    let formatStatus = owner.setStreamFormat(streamFormat, scope: kAudioUnitScope_Input)
    if formatStatus != noErr {
        owner.dispose()
        return trackRendererCreationFailure(formatStatus, 7)
    }
    let initializeStatus = owner.initialize()
    if initializeStatus != noErr {
        owner.dispose()
        return trackRendererCreationFailure(initializeStatus, 8)
    }
    switch AudioStreamPCMFormat(rawValue: caAudioStreamDescriptionFormat(streamFormat)) {
    case .float32:
        setTrackClipFormat(owner.renderState, TrackClipFormat.float32)
    case .float64:
        setTrackClipFormat(owner.renderState, TrackClipFormat.float64)
    default:
        break
    }
    let unit = OutputUnit(.trackRenderer, kAudioUnitScope_Global, callback, owner)
    unit.rendersPlayout = rendersPlayout
    var result = WebCore.AudioOutputUnitTrackRendererCreation()
    result.format = streamFormat
    result.identifier = addOutputUnit(unit)
    return result
}

private func trackRendererCreationFailure(_ status: OSStatus, _ step: UInt32) -> WebCore.AudioOutputUnitTrackRendererCreation {
    var result = WebCore.AudioOutputUnitTrackRendererCreation()
    result.status = status
    result.failedStep = step
    return result
}

// Main thread only: the events of the unit's IO thread since the last call (AudioUnitEvent).
@_expose(Cxx)
func audioOutputUnitTakeEvents(_ identifier: UInt64) -> UInt32 {
    withOutputUnit(identifier, 0) { $0.takeEvents() }
}

@_expose(Cxx)
func audioOutputUnitCreate(_ kind: UInt8, _ sampleRate: Float, _ channelCount: UInt32) -> UInt64 {
    precondition(WTF.isMainThread())
    guard let kind = OutputUnitKind(rawValue: kind), kind != .trackRenderer else {
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

#endif // ENABLE_WEBCORE_SWIFT
