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

public import AudioToolbox
import WebCore_Private.Core.CARingBufferSwiftBridge
import os

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

    // Whether the unit is a track renderer that plays out a track (attachTrackPlayout()), and the track, which it keeps
    // alive for as long as it can render from it.
    var rendersPlayout = false
    var trackPlayout: TrackPlayout?

    // What a remote destination renders from, when Swift attached it (attachRemoteDestinationRing()), which it keeps alive
    // for as long as it can render from it.
    var ringOwner: SharedAudioRing?
    var frameCounterOwner: SharedMemoryMapping?
    var semaphoreOwner: AudioSemaphoreRight?

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
    let unit = makeOutputUnitWithoutSession(kind, sampleRate, channelCount)
    if kind == .remoteDestination || kind == .inProcessDestination {
        WebCore.preferAudioSessionBufferSizeForOutputUnit()
    }
    return unit
}

private func makeOutputUnitWithoutSession(_ kind: OutputUnitKind, _ sampleRate: Float, _ channelCount: UInt32) -> OutputUnit {
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

// What making a track renderer's unit did: the unit and its stream format, or the status of the step that failed
// (WebCore::AudioOutputUnitTrackRendererCreation's failedStep).
enum TrackRendererMaking {
    case made(OutputUnit, AudioStreamBasicDescription)
    case failed(OSStatus, UInt32)
}

// LocalAudioMediaStreamTrackRendererInternalUnit::createAudioUnitIfNeeded(): the default output unit (RemoteIO on iOS) on
// the given device (0: the default one, or iOS), in the given stream format or, if there's none, the unit's own at
// sampleRate. Its render callback plays out a track (rendersPlayout) or calls a C++ one.
func makeTrackRenderer(_ deviceID: UInt32, _ sampleRate: Float64, _ format: AudioStreamBasicDescription?, _ rendersPlayout: Bool)
    -> TrackRendererMaking
{
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
        return .failed(noErr, 1)
    case .failed(let status):
        return .failed(status, 2)
    }
#if os(macOS)
    if deviceID != 0 {
        let status = owner.setUInt32(deviceID, for: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global)
        if status != noErr {
            owner.dispose()
            return .failed(status, 4)
        }
    }
#else
    let enableStatus = owner.setUInt32(1, for: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output)
    if enableStatus != noErr {
        owner.dispose()
        return .failed(enableStatus, 3)
    }
#endif
    let callback: SwiftRenderCallback = rendersPlayout ? .trackPlayout : .inProcessTrack
    let callbackStatus = owner.installRenderCallback(callback, scope: kAudioUnitScope_Global)
    if callbackStatus != noErr {
        owner.dispose()
        return .failed(callbackStatus, 5)
    }
    var streamFormat = format ?? AudioStreamBasicDescription()
    if format == nil {
        let status = owner.streamFormat(&streamFormat, scope: kAudioUnitScope_Input)
        if status != noErr {
            owner.dispose()
            return .failed(status, 6)
        }
        streamFormat.mSampleRate = sampleRate
    }
    let formatStatus = owner.setStreamFormat(streamFormat, scope: kAudioUnitScope_Input)
    if formatStatus != noErr {
        owner.dispose()
        return .failed(formatStatus, 7)
    }
    let initializeStatus = owner.initialize()
    if initializeStatus != noErr {
        owner.dispose()
        return .failed(initializeStatus, 8)
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
    return .made(unit, streamFormat)
}

// A track renderer's unit for C++ (WebCore::AudioOutputUnit::createTrackRenderer()), by identifier.
@_expose(Cxx)
func audioOutputUnitCreateTrackRenderer(
    _ deviceID: UInt32,
    _ sampleRate: Float64,
    _ format: AudioStreamBasicDescription,
    _ hasFormat: Bool,
    _ rendersPlayout: Bool
) -> WebCore.AudioOutputUnitTrackRendererCreation {
    switch makeTrackRenderer(deviceID, sampleRate, hasFormat ? format : nil, rendersPlayout) {
    case .made(let unit, let streamFormat):
        var result = WebCore.AudioOutputUnitTrackRendererCreation()
        result.format = streamFormat
        result.identifier = addOutputUnit(unit)
        return result
    case .failed(let status, let step):
        return trackRendererCreationFailure(status, step)
    }
}

private func trackRendererCreationFailure(_ status: OSStatus, _ step: UInt32) -> WebCore.AudioOutputUnitTrackRendererCreation {
    var result = WebCore.AudioOutputUnitTrackRendererCreation()
    result.status = status
    result.failedStep = step
    return result
}

// Main thread only: the events of the output unit's IO threads since the last call (AudioUnitEvent), or those of the
// current unit of a track renderer unit.
@_expose(Cxx)
func audioOutputUnitTakeEvents(_ identifier: UInt64) -> UInt32 {
#if ENABLE_MEDIA_STREAM
    if let unit = trackRendererUnit(identifier) {
        return unit.takeEvents()
    }
#endif
    return withOutputUnit(identifier, 0) { $0.takeEvents() }
}

// The IO threads' events of the units whose owners are in Swift, after the C++ ones' (WebCore::AudioOutputUnit::dispatchEvents()).
@_expose(Cxx)
func audioUnitsDispatchSwiftEvents() {
#if ENABLE_MEDIA_STREAM
    dispatchTrackRendererUnitEvents()
    dispatchAudioCaptureControllerUnitEvents()
#endif
}

@_expose(Cxx)
func audioOutputUnitCreate(_ kind: UInt8, _ sampleRate: Float, _ channelCount: UInt32) -> UInt64 {
    precondition(WTF.isMainThread())
    guard let kind = OutputUnitKind(rawValue: kind), kind != .trackRenderer else {
        preconditionFailure()
    }
    return addOutputUnit(makeOutputUnit(kind, sampleRate, channelCount))
}

// Stops the unit if it is running, then disposes of it. Also for C++'s track renderer units.
@_expose(Cxx)
func audioOutputUnitDestroy(_ identifier: UInt64) {
#if ENABLE_MEDIA_STREAM
    if destroyCxxTrackRendererUnit(identifier) {
        return
    }
#endif
    _ = removeOutputUnit(identifier)
}

// Also for track renderer units, which start their unit if they can make it.
@_expose(Cxx)
func audioOutputUnitStart(_ identifier: UInt64) -> Int32 {
#if ENABLE_MEDIA_STREAM
    if let unit = trackRendererUnit(identifier) {
        unit.start()
        return noErr
    }
#endif
    return withOutputUnit(identifier, kAudio_ParamError) { $0.start() }
}

// Also for track renderer units, which dispose of their unit.
@_expose(Cxx)
func audioOutputUnitStop(_ identifier: UInt64) -> Int32 {
#if ENABLE_MEDIA_STREAM
    if let unit = trackRendererUnit(identifier) {
        unit.stop()
        return noErr
    }
#endif
    return withOutputUnit(identifier, kAudio_ParamError) { $0.stop() }
}

@_expose(Cxx)
func audioOutputUnitLatency(_ identifier: UInt64) -> UInt64 {
    withOutputUnit(identifier, 0) { $0.latency() }
}

// MARK: The GPU process's units

// A GPU-process audio destination's output unit (RemoteAudioDestination), which plays out the ring the web process writes.
// Main thread only: each member traps elsewhere.
@_spi(WebKitGPU)
public final class RemoteDestinationOutputUnit {
    private let unit: OutputUnit
    // The unit's identifier in the table, by which C++ sets its spatial experience (audioOutputUnitSetObjectProperty()).
    public let identifier: UInt64

    public init(sampleRate: Float, channelCount: UInt32) {
        precondition(WTF.isMainThread())
        unit = makeOutputUnit(.remoteDestination, sampleRate, channelCount)
        identifier = addOutputUnit(unit)
    }

    deinit {
        _ = removeOutputUnit(identifier)
    }

    public func start() -> OSStatus {
        precondition(WTF.isMainThread())
        return unit.start()
    }

    public func stop() -> OSStatus {
        precondition(WTF.isMainThread())
        return unit.stop()
    }

    public var latency: UInt64 {
        precondition(WTF.isMainThread())
        return unit.latency()
    }

    // While stopped: the ring it plays out (or none), the shared counter it adds each quantum's frames to (or none) and the
    // semaphore it signals after each quantum (or none). The unit keeps them until the next attach().
    public func attach(ring: SharedAudioRing?, frameCounter: SharedMemoryMapping?, semaphore: AudioSemaphoreRight?) {
        precondition(WTF.isMainThread())
        unit.attachRemoteDestinationRing(ring, frameCounter, semaphore)
    }
}

#if ENABLE_MEDIA_STREAM
private let trackRendererLogger = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

// AudioMediaStreamTrackRenderer::defaultDeviceID().
let audioTrackRendererDefaultDeviceID = "default"

// LocalAudioMediaStreamTrackRendererInternalUnit's unit: a track renderer on a device, made when it first starts or its
// format is first asked for, and disposed of whenever it stops. A GPU-process one plays out a track playout; an in-process
// one renders from the C++ callback of WebCore::LocalAudioMediaStreamTrackRendererInternalUnit. WebCore's main thread only
// (the web thread on iOS's WebKit1, so not the main actor): each member traps elsewhere.
@_spi(WebKitGPU)
public final class TrackRendererUnit {
    // An in-process unit's C++ callback is only stored here; calling it is unsafe (OutputUnit.setCxxRenderCallback()).
    @safe private enum Source {
        case playout(TrackPlayout)
        case cxx(AURenderCallback, UInt)
    }

    // What it renders from: set when it's made, or, in process, by the C++ before it first starts.
    private var source: Source?
    let identifier: UInt64
    private var deviceID: UInt32 = 0
    private var outputFormat: AudioStreamBasicDescription?
    private var unit: OutputUnit?
    private var isStarted = false
    // Called on the main thread when the unit's IO thread saw its timeline jump.
    public var timelineDiscontinuityHandler: (() -> Void)? {
        get {
            precondition(WTF.isMainThread())
            return storedTimelineDiscontinuityHandler
        }
        set {
            precondition(WTF.isMainThread())
            storedTimelineDiscontinuityHandler = newValue
        }
    }
    private var storedTimelineDiscontinuityHandler: (() -> Void)?

    public convenience init(playing track: TrackPlayout) {
        self.init(.playout(track))
    }

    // An in-process unit, without a source until it has its C++ callback (setCxxRenderCallback()).
    fileprivate convenience init() {
        self.init(nil)
    }

    private init(_ source: Source?) {
        self.source = source
        identifier = nextAudioUnitIdentifier()
        unsafe trackRendererUnits[identifier] = WeakTrackRendererUnit(self)
    }

    deinit {
        precondition(WTF.isMainThread())
        stop()
        _ = unsafe trackRendererUnits.removeValue(forKey: identifier)
    }

    // The unit's stream format, once it's made: the device's own at the audio session's sample rate. nil if it can't be
    // made.
    public var format: AudioStreamBasicDescription? {
        precondition(WTF.isMainThread())
        makeUnitIfNeeded()
        return outputFormat
    }

    // macOS: the device (0: the default one), which restarts a running unit.
    public func setDevice(_ deviceID: UInt32) {
        precondition(WTF.isMainThread())
        if self.deviceID == deviceID {
            return
        }
        let shouldRestart = isStarted
        if isStarted {
            stop()
        }
        self.deviceID = deviceID
        if shouldRestart {
            start()
        }
    }

    // macOS: the device for an audio output device's persistent ID; the default one for
    // AudioMediaStreamTrackRenderer::defaultDeviceID() or an ID that matches no device.
    public func setDevice(persistentID: Swift.String) {
#if os(macOS)
        setDevice(audioTrackRendererOutputDevice(persistentID))
#else
        setDevice(0)
#endif
    }

    public static func isDefaultDevice(_ persistentID: Swift.String) -> Bool {
        persistentID == audioTrackRendererDefaultDeviceID
    }

    public func start() {
        precondition(WTF.isMainThread())
        trackRendererLogger.info("LocalAudioMediaStreamTrackRendererInternalUnit::start")
        if isStarted {
            return
        }
        makeUnitIfNeeded()
        guard let unit else {
            return
        }
        let error = unit.start()
        if error != noErr {
            trackRendererLogger.error("AudioMediaStreamTrackRendererInternalUnit::start AudioOutputUnitStart failed, error = \(error)")
            self.unit = nil
            return
        }
        isStarted = true
        trackRendererLogger.log("AudioMediaStreamTrackRendererInternalUnit is started")
    }

    public func stop() {
        precondition(WTF.isMainThread())
        trackRendererLogger.info("LocalAudioMediaStreamTrackRendererInternalUnit::stop")
        guard let unit else {
            return
        }
        if isStarted {
            _ = unit.stop()
            isStarted = false
        }
        self.unit = nil
    }

    // Before an in-process unit first starts: the C++ callback that renders each quantum, with its refCon, as an address.
    // The caller keeps what refCon points to alive until the unit goes.
    @unsafe
    fileprivate func setCxxRenderCallback(_ render: AURenderCallback, _ refCon: UInt) {
        precondition(WTF.isMainThread() && source == nil)
        source = unsafe .cxx(render, refCon)
    }

    private func makeUnitIfNeeded() {
        if unit != nil {
            return
        }
        let playsOutTrack: Bool
        switch source {
        case .playout:
            playsOutTrack = true
        case .cxx:
            playsOutTrack = false
        case nil:
            return
        }
        switch makeTrackRenderer(deviceID, WebCore.audioCaptureSessionSampleRate(), outputFormat, playsOutTrack) {
        case .failed(let status, let step):
            let steps = [
                "", "unable to find remote IO unit component", "unable to open vpio unit", "unable to enable vpio unit output",
                "unable to set unit device ID", "unable to set vpio unit speaker proc", "unable to get input stream format",
                "unable to set input stream format", "AudioUnitInitialize() failed",
            ]
            let description = steps[min(Int(step), steps.count - 1)]
            trackRendererLogger.error(
                "AudioMediaStreamTrackRendererInternalUnit::createAudioUnit \(description, privacy: .public), error = \(status)"
            )
        case .made(let made, let streamFormat):
            if outputFormat == nil {
                outputFormat = streamFormat
            }
            switch source {
            case .playout(let track):
                made.attachTrackPlayout(track)
            case .cxx(let render, let refCon):
                unsafe made.setCxxRenderCallback(render, UnsafeMutableRawPointer(bitPattern: refCon))
            case nil:
                preconditionFailure()
            }
            unit = made
        }
    }

    func takeEvents() -> UInt32 {
        precondition(WTF.isMainThread())
        return unit?.takeEvents() ?? 0
    }

    fileprivate func dispatchEvents() {
        guard let timelineDiscontinuityHandler = storedTimelineDiscontinuityHandler else {
            return
        }
        if takeEvents() & AudioUnitEvent.timelineDiscontinuity != 0 {
            timelineDiscontinuityHandler()
        }
    }
}

private final class WeakTrackRendererUnit {
    weak var unit: TrackRendererUnit?

    init(_ unit: TrackRendererUnit) {
        self.unit = unit
    }
}

// The track renderer units, on WebCore's main thread only, as the output units' table.
nonisolated(unsafe) private var trackRendererUnits: [UInt64: WeakTrackRendererUnit] = [:]

// The in-process ones, which C++ owns by identifier.
nonisolated(unsafe) private var cxxTrackRendererUnits: [UInt64: TrackRendererUnit] = [:]

private func trackRendererUnit(_ identifier: UInt64) -> TrackRendererUnit? {
    precondition(WTF.isMainThread())
    return unsafe trackRendererUnits[identifier]?.unit
}

// The Swift owners' units' events; the C++ owners take theirs by identifier (audioOutputUnitTakeEvents()).
private func dispatchTrackRendererUnitEvents() {
    precondition(WTF.isMainThread())
    for identifier in unsafe trackRendererUnits.keys.sorted() {
        trackRendererUnit(identifier)?.dispatchEvents()
    }
}

// WebCore::AudioTrackRendererUnit's unit, which C++ owns by identifier until audioOutputUnitDestroy(), and whose C++ render
// callback it attaches (audioOutputUnitAttachCxxRenderCallback()) before it first starts.
@_expose(Cxx)
func audioTrackRendererUnitCreate() -> UInt64 {
    precondition(WTF.isMainThread())
    let unit = TrackRendererUnit()
    unsafe cxxTrackRendererUnits[unit.identifier] = unit
    return unit.identifier
}

private func destroyCxxTrackRendererUnit(_ identifier: UInt64) -> Bool {
    precondition(WTF.isMainThread())
    return unsafe cxxTrackRendererUnits.removeValue(forKey: identifier) != nil
}

// An in-process track renderer unit's C++ render callback (audioOutputUnitAttachCxxRenderCallback()). False if the identifier
// isn't one's.
@unsafe
func setTrackRendererUnitCxxRenderCallback(_ identifier: UInt64, _ render: AURenderCallback, _ refCon: UnsafeMutableRawPointer?) -> Bool {
    precondition(WTF.isMainThread())
    guard let unit = unsafe cxxTrackRendererUnits[identifier] else {
        return false
    }
    unsafe unit.setCxxRenderCallback(render, UInt(bitPattern: refCon))
    return true
}

// The device for an audio output device's persistent ID (TrackRendererUnit.setDevice(persistentID:)).
@_expose(Cxx)
func audioTrackRendererUnitSetDevice(_ identifier: UInt64, _ persistentID: borrowing CFString?) {
#if os(macOS)
    trackRendererUnit(identifier)?.setDevice(audioTrackRendererOutputDevice(copy persistentID))
#else
    trackRendererUnit(identifier)?.setDevice(0)
#endif
}

// The unit's stream format, made if needed; a format whose mFormatID is 0 if it can't be made.
@_expose(Cxx)
func audioTrackRendererUnitFormat(_ identifier: UInt64) -> AudioStreamBasicDescription {
    trackRendererUnit(identifier)?.format ?? AudioStreamBasicDescription()
}
#endif // ENABLE_MEDIA_STREAM

#endif // ENABLE_WEBCORE_SWIFT
