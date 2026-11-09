// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

private import Cxx
import Accelerate
import AudioToolbox
import Darwin
import Synchronization
import WebCore_Private.Core.CARingBufferSwiftBridge

// The audited `unsafe` of WebCore's CoreAudio glue: memory that C++ or CoreAudio hands over as pointers, and the atomics
// shared with other threads and processes. Apart from AudioUnitOwner.swift's AudioUnit calls, the rest of the glue is safe
// Swift over what this file lends it.
//
// Code that can run on an audio IO thread is written so that it needs no Swift runtime even at -Onone: no generics,
// closures, globals, classes or Optional payloads of classes; while loops; and memmove, memset and atomics only.

// MARK: The bounds of a ring

// The bounds of a ring are in a 32-byte, 8-byte-aligned header (CARingBufferBoundsStorage): a sequence count, then the
// bounds' startFrame, endFrame and writeAhead. All four words are only ever accessed atomically, because the writer can be
// another process. The writer makes the count odd, stores the bounds and makes the count even again; a reader keeps a copy
// of the bounds that it read between two loads of the same even count.
//
// This is the sequence lock of H.-J. Boehm, "Can Seqlocks Get Along with Programming Language Memory Models?" (HP
// Laboratories, HPL-2012-68, 2012), with its fences:
// - the reader loads the count with acquire ordering, the bounds relaxed, then has an acquire fence before it loads the
//   count again, relaxed. If the reader saw any store of a later write, the fence makes the second load see that write's
//   odd count, or a later count;
// - the writer stores the odd count relaxed and has a release fence before it stores the bounds relaxed, then stores the
//   even count with release ordering, so a reader that sees the even count sees the bounds.
//
// A writer in another process can keep the count odd, or change it all the time, so a reader gives up after
// ringBoundsLoadAttempts attempts and takes the last copy it read. Its callers clamp what they read to the ring.

private var ringHeaderByteCount: Int { 32 }

private var ringBoundsLoadAttempts: Int { 64 }

@inline(__always)
private func ringHeaderWord(_ header: UnsafeRawPointer, _ index: Int) -> UnsafePointer<Atomic<UInt64>> {
    unsafe header.advanced(by: index &* 8).assumingMemoryBound(to: Atomic<UInt64>.self)
}

// The bounds a ring's writer stored, from a header at an address that C++ or the attachment of an audio unit vouches for.
func loadRingBounds(at header: UnsafeRawPointer) -> WebCore.CARingBufferBounds {
    var bounds = WebCore.CARingBufferBounds()
    var attempt = 0
    while attempt < ringBoundsLoadAttempts {
        let sequence = unsafe ringHeaderWord(header, 0).pointee.load(ordering: .acquiring)
        bounds.startFrame = unsafe ringHeaderWord(header, 1).pointee.load(ordering: .relaxed)
        bounds.endFrame = unsafe ringHeaderWord(header, 2).pointee.load(ordering: .relaxed)
        bounds.writeAhead = unsafe ringHeaderWord(header, 3).pointee.load(ordering: .relaxed)
        atomicMemoryFence(ordering: .acquiring)
        let sequenceAfter = unsafe ringHeaderWord(header, 0).pointee.load(ordering: .relaxed)
        if sequence == sequenceAfter && sequence & 1 == 0 {
            return bounds
        }
        attempt &+= 1
    }
    return bounds
}

private func storeRingBounds(at header: UnsafeMutableRawPointer, _ bounds: WebCore.CARingBufferBounds) {
    let sequence = unsafe ringHeaderWord(header, 0).pointee.load(ordering: .relaxed)
    unsafe ringHeaderWord(header, 0).pointee.store(sequence &+ 1, ordering: .relaxed)
    atomicMemoryFence(ordering: .releasing)
    unsafe ringHeaderWord(header, 1).pointee.store(bounds.startFrame, ordering: .relaxed)
    unsafe ringHeaderWord(header, 2).pointee.store(bounds.endFrame, ordering: .relaxed)
    unsafe ringHeaderWord(header, 3).pointee.store(bounds.writeAhead, ordering: .relaxed)
    unsafe ringHeaderWord(header, 0).pointee.store(sequence &+ 2, ordering: .releasing)
}

// Traps unless the header is whole and aligned for its atomics.
@inline(__always)
private func checkRingHeader(_ address: UnsafeRawPointer?, _ byteCount: Int) -> UnsafeRawPointer {
    precondition(byteCount >= ringHeaderByteCount)
    guard let address = unsafe address else {
        preconditionFailure()
    }
    precondition(Int(bitPattern: address) & 7 == 0)
    return unsafe address
}

// The bounds stored in the header of a ring that a C++ view lends.
func loadRingBounds(_ header: Span<UInt8>) -> WebCore.CARingBufferBounds {
    header.withUnsafeBytes { bytes in
        unsafe loadRingBounds(at: checkRingHeader(bytes.baseAddress, bytes.count))
    }
}

// Stores bounds in the header of a ring that a C++ view lends.
func storeRingBounds(_ header: inout MutableSpan<UInt8>, _ bounds: WebCore.CARingBufferBounds) {
    header.withUnsafeMutableBytes { bytes in
        let address = unsafe checkRingHeader(UnsafeRawPointer(bytes.baseAddress), bytes.count)
        unsafe storeRingBounds(at: UnsafeMutableRawPointer(mutating: address), bounds)
    }
}

// CARingBuffer::getFetchTimeBounds(), which may run on any thread, so it doesn't make a view.
@_expose(Cxx)
func caRingBufferFetchTimeBounds(
    _ geometry: WebCore.CARingBufferGeometry,
    _ header: UnsafePointer<WebCore.CARingBufferBoundsStorage>
) -> WebCore.CARingBufferBounds {
    let address = unsafe checkRingHeader(UnsafeRawPointer(header), ringHeaderByteCount)
    return caRingBufferFetchBounds(geometry, unsafe loadRingBounds(at: address))
}

// MARK: IO views

// What a render callback lends the code it calls for one quantum: the buffers of the AudioBufferList that CoreAudio passes
// it, a ring's channels and the unit's own samples. They can't outlive the callback, and every access is checked against
// the bytes they cover, as a span's is. They are not spans because a span's copy and fill need the Swift runtime at -Onone.

// Bytes that a render callback reads.
@safe struct IOConstBytes: ~Escapable {
    private let base: UnsafeRawPointer?
    let count: Int

    @_lifetime(borrow base)
    fileprivate init(_ base: UnsafeRawPointer?, _ count: Int) {
        precondition(count >= 0)
        precondition(unsafe base != nil || count == 0)
        unsafe self.base = base
        self.count = count
    }

    fileprivate func address(_ offset: Int) -> UnsafeRawPointer {
        guard let base = unsafe base else {
            preconditionFailure()
        }
        return unsafe base.advanced(by: offset)
    }
}

// Bytes that a render callback writes.
@safe struct IOBytes: ~Copyable, ~Escapable {
    private let base: UnsafeMutableRawPointer?
    let count: Int

    @_lifetime(borrow base)
    fileprivate init(_ base: UnsafeMutableRawPointer?, _ count: Int) {
        precondition(count >= 0)
        precondition(unsafe base != nil || count == 0)
        unsafe self.base = base
        self.count = count
    }

    private func address(_ offset: Int) -> UnsafeMutableRawPointer {
        guard let base = unsafe base else {
            preconditionFailure()
        }
        return unsafe base.advanced(by: offset)
    }

    // Zeroes byteCount bytes from offset, as memset does. Traps unless the range is inside the bytes.
    mutating func zero(at offset: Int, count byteCount: Int) {
        precondition(byteCount >= 0 && offset >= 0 && byteCount <= count &- offset)
        if byteCount == 0 {
            return
        }
        _ = unsafe memset(address(offset), 0, byteCount)
    }

    // Copies byteCount bytes of source from sourceOffset to offset, as memmove does. Traps unless both ranges are inside
    // their bytes.
    mutating func copy(from source: borrowing IOConstBytes, at sourceOffset: Int, to offset: Int, count byteCount: Int) {
        precondition(
            byteCount >= 0 && sourceOffset >= 0 && offset >= 0 && byteCount <= source.count &- sourceOffset
                && byteCount <= count &- offset
        )
        if byteCount == 0 {
            return
        }
        _ = unsafe memmove(address(offset), source.address(sourceOffset), byteCount)
    }

    // The 32-bit sample at index, as a float or as its bit pattern. Traps unless the sample is inside the bytes.
    func float(at index: Int) -> Float {
        precondition(index >= 0 && index < count / 4)
        return unsafe address(0).loadUnaligned(fromByteOffset: index &* 4, as: Float.self)
    }

    func sampleBits(at index: Int) -> UInt32 {
        precondition(index >= 0 && index < count / 4)
        return unsafe address(0).loadUnaligned(fromByteOffset: index &* 4, as: UInt32.self)
    }

    mutating func setFloat(_ value: Float, at index: Int) {
        precondition(index >= 0 && index < count / 4)
        unsafe address(0).storeBytes(of: value, toByteOffset: index &* 4, as: Float.self)
    }

    mutating func setSampleBits(_ value: UInt32, at index: Int) {
        precondition(index >= 0 && index < count / 4)
        unsafe address(0).storeBytes(of: value, toByteOffset: index &* 4, as: UInt32.self)
    }
}

// The AudioBufferList that CoreAudio passes a render callback. Its buffer count and sizes are read when they are used, and
// trusted, as the C++ that reads an AudioBufferList does.
@safe struct IOBufferList: ~Copyable, ~Escapable {
    private let list: UnsafeMutablePointer<AudioBufferList>

    @_lifetime(borrow list)
    fileprivate init(_ list: UnsafeMutablePointer<AudioBufferList>) {
        unsafe self.list = list
    }

    var bufferCount: Int {
        Int(unsafe list.pointee.mNumberBuffers)
    }

    private func buffer(_ index: Int) -> UnsafeMutablePointer<AudioBuffer> {
        precondition(index >= 0 && index < bufferCount)
        // mBuffers follows mNumberBuffers, aligned for AudioBuffer's pointer.
        let first = unsafe UnsafeMutableRawPointer(list).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
        return unsafe first.advanced(by: index)
    }

    @_lifetime(&self)
    mutating func bytes(_ index: Int) -> IOBytes {
        let buffer = unsafe buffer(index)
        let bytes = unsafe IOBytes(buffer.pointee.mData, Int(buffer.pointee.mDataByteSize))
        return unsafe _overrideLifetime(bytes, mutating: &self)
    }

    mutating func setDataByteSize(_ index: Int, _ size: UInt32) {
        unsafe buffer(index).pointee.mDataByteSize = size
    }
}

// MARK: Render state

// What an output unit's render callback keeps between quanta, at an address that stays put from before the callback is
// installed until after the unit is disposed of (AudioUnitOwner). The main thread changes it only while the unit is
// stopped.
@unsafe struct OutputRenderState: ~Copyable {
    let isRendering = Atomic<Bool>(false)
    // AudioUnitEvent bits for the main thread, which the IO thread wakes through controlSemaphore.
    let pendingEvents = Atomic<UInt32>(0)
    var controlSemaphore: semaphore_t = 0
    var ring = unsafe WebCore.AudioOutputUnitRingAttachment()
    var startFrame: UInt64 = 0
    let lastRenderedSamples: UnsafeMutableRawPointer
    let lastRenderedSampleCount: Int
    // A track renderer's: the sample time of the last quantum (0 before the first), how to clip its output, and what it
    // renders from, a GPU-process track playout or the C++ render callback of an in-process track renderer.
    var lastSampleTime: UInt64 = 0
    var clipFormat: UInt8 = 0
    var track: UnsafeMutablePointer<TrackPlayoutState>? = nil
    var cxxRender: AURenderCallback? = nil
    var cxxRefCon: UnsafeMutableRawPointer? = nil
    // A capture unit's (AudioCaptureUnit.swift): what renders its microphone, AudioUnitRender() on its AudioUnit or the
    // mock's render function, into its own buffers; how it times a quantum; whom it delivers the quantum to; the main
    // thread's switches; the speaker's snapshot hand-off (CaptureSnapshot); and its counters.
    var captureRender: CaptureRenderFunction? = nil
    var captureRenderTarget: UnsafeMutableRawPointer? = nil
    var microphoneList: UnsafeMutablePointer<AudioBufferList>? = nil
    var microphoneData: UnsafeMutableRawPointer? = nil
    var microphoneBufferByteCount: Int = 0
    var microphoneChannelsPerBuffer: UInt32 = 0
    var microphoneSampleRate: Float64 = 0
    var dtsConversionRatio: Float64 = 0
    var speakerBytesPerFrame: UInt64 = 0
    var cxxDeliveryContext: UnsafeMutableRawPointer? = nil
    let isCapturing = Atomic<Bool>(false)
    let isProducingMicrophoneSamples = Atomic<Bool>(false)
    let isReconfiguring = Atomic<Bool>(false)
    let speakerStartPending = Atomic<Bool>(false)
    let speakerStartAcknowledged = Atomic<Bool>(false)
    let microphoneProcCount = Atomic<UInt64>(0)
    // 0, or failedRenderFlag and the frame count of the first quantum the microphone buffer was too small for.
    let failedRenderFrames = Atomic<UInt64>(0)
    let pendingSnapshot = unsafe Atomic<UnsafeMutableRawPointer?>(nil)
    let retiredSnapshot = unsafe Atomic<UnsafeMutableRawPointer?>(nil)
    var currentSnapshot: UnsafeMutableRawPointer? = nil
}

// AudioUnitRender()'s signature, which the mock capture unit's render function shares.
typealias CaptureRenderFunction = @convention(c) (
    UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>?, UnsafePointer<AudioTimeStamp>, UInt32, UInt32,
    UnsafeMutablePointer<AudioBufferList>
) -> OSStatus

// The events of a unit's IO thread that only the main thread can act on (WebCore::AudioOutputUnit::Event).
enum AudioUnitEvent {
    // A track renderer saw its timeline jump.
    static var timelineDiscontinuity: UInt32 { 1 }
    // A capture unit's speaker callback ran for the first time since the unit started.
    static var speakerStarting: UInt32 { 2 }
    // A capture unit's microphone buffer was too small for a quantum (failedRenderFrames).
    static var microphoneBufferTooSmall: UInt32 { 4 }
}

// How a track renderer clips its output (CAAudioStreamDescription::PCMFormat): Float32 and Float64 to [-1, 1].
enum TrackClipFormat {
    static var none: UInt8 { 0 }
    static var float32: UInt8 { 1 }
    static var float64: UInt8 { 2 }
}

// An output unit's render state, which its owner frees. The IO threads and the mock capture unit's queue use it too.
@safe struct RenderStateReference: @unchecked Sendable {
    fileprivate let state: UnsafeMutablePointer<OutputRenderState>

    var refCon: UnsafeMutableRawPointer {
        unsafe UnsafeMutableRawPointer(state)
    }
}

// The state of a render callback that remembers sampleCapacity samples between quanta, zeroed.
func makeRenderState(sampleCapacity: Int) -> RenderStateReference {
    precondition(sampleCapacity >= 0 && sampleCapacity <= Int.max / 4)
    let samples = UnsafeMutableRawPointer.allocate(byteCount: sampleCapacity &* 4, alignment: 16)
    unsafe samples.initializeMemory(as: UInt8.self, repeating: 0, count: sampleCapacity &* 4)
    let state = UnsafeMutablePointer<OutputRenderState>.allocate(capacity: 1)
    unsafe state.initialize(to: OutputRenderState(lastRenderedSamples: samples, lastRenderedSampleCount: sampleCapacity))
    unsafe state.pointee.controlSemaphore = audioControlSemaphore()
    return unsafe RenderStateReference(state: state)
}

// The main thread's, while the unit is stopped.
func setTrackClipFormat(_ reference: RenderStateReference, _ format: UInt8) {
    unsafe reference.state.pointee.clipFormat = format
}

// Main thread only: the events that the unit's IO thread posted since the last call.
func takeRenderStateEvents(_ reference: RenderStateReference) -> UInt32 {
    unsafe reference.state.pointee.pendingEvents.exchange(0, ordering: .acquiring)
}

// MARK: The control thread

// IO threads can't dispatch to the main thread, so a unit's posts an event bit and signals this process's audio control
// semaphore, which wakes a thread that has C++ hop to the main thread (audioUnitEventsArrived()).

nonisolated(unsafe) private var controlSemaphore: semaphore_t = 0

// Main thread only: the semaphore, which starts the control thread the first time.
private func audioControlSemaphore() -> semaphore_t {
    precondition(WTF.isMainThread())
    if unsafe controlSemaphore == 0 {
        var semaphore: semaphore_t = 0
        precondition(unsafe semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS)
        unsafe controlSemaphore = semaphore
        startAudioControlThread(semaphore)
    }
    return unsafe controlSemaphore
}

// On an IO thread: wait-free.
@inline(__always)
private func postEvent(_ state: UnsafeMutablePointer<OutputRenderState>, _ event: UInt32) {
    _ = unsafe state.pointee.pendingEvents.bitwiseOr(event, ordering: .releasing)
    _ = unsafe semaphore_signal(state.pointee.controlSemaphore)
}

// Only once the unit that renders with it is disposed of.
func freeRenderState(_ reference: RenderStateReference) {
    let samples = unsafe reference.state.pointee.lastRenderedSamples
    unsafe reference.state.deinitialize(count: 1)
    unsafe reference.state.deallocate()
    unsafe samples.deallocate()
}

// MARK: The output units

// AudioOutputUnit.swift's units by identifier, on WebCore's main thread only (which is the web thread on iOS's WebKit1, so
// not the main actor).
nonisolated(unsafe) private var outputUnits: [UInt64: OutputUnit] = [:]

nonisolated(unsafe) private var lastOutputUnitIdentifier: UInt64 = 0

func addOutputUnit(_ unit: OutputUnit) -> UInt64 {
    precondition(WTF.isMainThread())
    unsafe lastOutputUnitIdentifier &+= 1
    unsafe outputUnits[lastOutputUnitIdentifier] = unit
    return unsafe lastOutputUnitIdentifier
}

func outputUnit(_ identifier: UInt64) -> OutputUnit? {
    precondition(WTF.isMainThread())
    return unsafe outputUnits[identifier]
}

func removeOutputUnit(_ identifier: UInt64) -> OutputUnit? {
    precondition(WTF.isMainThread())
    return unsafe outputUnits.removeValue(forKey: identifier)
}

extension SwiftRenderCallback {
    var function: AURenderCallback {
        switch self {
        case .remoteDestination:
            unsafe remoteDestinationRenderCallback
        case .trackPlayout:
            unsafe trackRendererRenderCallback
        case .inProcessTrack:
            unsafe inProcessTrackRendererRenderCallback
        case .microphone:
            unsafe microphoneRenderCallback
        case .speaker:
            unsafe speakerRenderCallback
        }
    }
}

// What AudioOutputUnit.swift's units take from C++ as pointers.
extension OutputUnit {
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

    func setCxxRenderCallback(_ callback: AURenderCallback, _ refCon: UnsafeMutableRawPointer?) {
        precondition(!isRunning)
        if kind == .trackRenderer {
            precondition(!rendersPlayout)
            if let renderState {
                unsafe setTrackRenderSource(renderState, nil, callback, refCon)
                hasRenderCallback = unsafe refCon != nil
            }
            return
        }
        precondition(kind == .inProcessDestination)
        hasRenderCallback = true
        if let owner = stopped.take() {
            _ = unsafe owner.setRenderCallback(callback, refCon, scope: renderCallbackScope)
            stopped = consume owner
        }
    }

    func attachTrackPlayout(_ track: TrackPlayout) {
        precondition(kind == .trackRenderer && rendersPlayout && !isRunning)
        if let renderState {
            setTrackRenderSource(renderState, track, nil, nil)
            trackPlayout = track
            hasRenderCallback = true
        }
    }

    func renderForTesting(
        _ ioData: UnsafeMutablePointer<AudioBufferList>,
        _ frameCount: UInt32,
        _ sampleTime: Float64,
        _ throughAudioUnit: Bool,
        _ actionFlags: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        precondition(kind != .inProcessDestination && hasRenderCallback && (kind == .genericOutputForTesting || !throughAudioUnit))
        guard let renderCallback, let owner = stopped.take() else {
            return kAudio_ParamError
        }
        let status = unsafe owner.renderForTesting(renderCallback, ioData, frameCount, sampleTime, throughAudioUnit, actionFlags)
        stopped = consume owner
        return status
    }
}

// Sets a global property whose value is an object, such as kAudioOutputUnitProperty_IntendedSpatialExperience.
@_expose(Cxx)
func audioOutputUnitSetObjectProperty(_ identifier: UInt64, _ property: UInt32, _ object: UnsafeMutableRawPointer?) -> Int32 {
    guard let unit = outputUnit(identifier) else {
        return kAudio_ParamError
    }
    return unsafe unit.setObject(object, for: property)
}

// MARK: Track playouts

// What a GPU-process track renderer and the capture unit's speaker callback play out
// (RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit): the ring the web process writes, the semaphore it signals for
// each chunk of frameChunkSize frames it asks for, and where it reads. The main thread changes it only while it holds
// isRendering; a render callback that finds it held outputs silence.
@unsafe struct TrackPlayoutState: ~Copyable {
    let isRendering = Atomic<Bool>(false)
    var ring = unsafe WebCore.AudioOutputUnitRingAttachment()
    var readOffset: UInt64 = 0
    var generateOffset: UInt64 = 0
    var frameChunkSize: UInt64 = 0
    var bytesPerFrame: UInt64 = 0
}

// A track playout on the main thread. Its state lives until the last of its owner (the table, until
// audioTrackPlayoutDestroy()), the track renderer units that render from it and the capture snapshots that hold it lets go.
@safe final class TrackPlayout {
    fileprivate let state: UnsafeMutablePointer<TrackPlayoutState>

    init() {
        unsafe state = UnsafeMutablePointer<TrackPlayoutState>.allocate(capacity: 1)
        unsafe state.initialize(to: TrackPlayoutState())
    }

    deinit {
        unsafe state.deinitialize(count: 1)
        unsafe state.deallocate()
    }

    // A new ring, read from its start in chunks of the attachment's frameChunkSize frames of bytesPerFrame bytes. Waits for
    // a render callback that is rendering from the track to finish, as the C++ waited for the speaker callback's lock.
    func attachRing(_ attachment: WebCore.AudioOutputUnitRingAttachment) {
        precondition(WTF.isMainThread())
        while unsafe state.pointee.isRendering.exchange(true, ordering: .acquiring) {
            sched_yield()
        }
        unsafe state.pointee.ring = attachment
        unsafe state.pointee.ring.frameCounter = nil
        unsafe state.pointee.readOffset = 0
        unsafe state.pointee.generateOffset = 0
        unsafe state.pointee.frameChunkSize = attachment.frameChunkSize
        unsafe state.pointee.bytesPerFrame = attachment.bytesPerFrame
        unsafe state.pointee.isRendering.store(false, ordering: .releasing)
    }
}

nonisolated(unsafe) private var trackPlayouts: [UInt64: TrackPlayout] = [:]

func trackPlayout(_ identifier: UInt64) -> TrackPlayout? {
    precondition(WTF.isMainThread())
    return unsafe trackPlayouts[identifier]
}

// RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit's playout (WebCore::AudioTrackPlayout), without a ring until
// it attaches one (audioUnitAttachRing()).
@_expose(Cxx)
func audioTrackPlayoutCreate() -> UInt64 {
    precondition(WTF.isMainThread())
    unsafe lastOutputUnitIdentifier &+= 1
    unsafe trackPlayouts[lastOutputUnitIdentifier] = TrackPlayout()
    return unsafe lastOutputUnitIdentifier
}

// Its ring goes first: the units that still hold the track play out silence.
@_expose(Cxx)
func audioTrackPlayoutDestroy(_ identifier: UInt64) {
    precondition(WTF.isMainThread())
    guard let track = unsafe trackPlayouts.removeValue(forKey: identifier) else {
        return
    }
    unsafe track.attachRing(WebCore.AudioOutputUnitRingAttachment())
}

// MARK: Capture units

nonisolated(unsafe) private var captureUnits: [UInt64: CaptureUnit] = [:]

func addCaptureUnit(_ unit: CaptureUnit) -> UInt64 {
    precondition(WTF.isMainThread())
    unsafe lastOutputUnitIdentifier &+= 1
    unsafe captureUnits[lastOutputUnitIdentifier] = unit
    return unsafe lastOutputUnitIdentifier
}

func captureUnit(_ identifier: UInt64) -> CaptureUnit? {
    precondition(WTF.isMainThread())
    return unsafe captureUnits[identifier]
}

func removeCaptureUnit(_ identifier: UInt64) -> CaptureUnit? {
    precondition(WTF.isMainThread())
    return unsafe captureUnits.removeValue(forKey: identifier)
}

// What a capture unit's speaker callback renders from, published by the main thread and taken by the IO thread without
// waiting (the hand-off): the track playout it plays out, if any. The snapshot keeps the track alive.
@unsafe struct CaptureSnapshot: ~Copyable {
    let speakerTrack: UnsafeMutablePointer<TrackPlayoutState>?
    let speakerTrackOwner: Unmanaged<TrackPlayout>?
}

// The capture unit's state's capture fields, on the main thread while the unit is stopped (AudioCaptureUnit.swift).
extension RenderStateReference {
    // Microphone buffers for bufferCount buffers of byteCount bytes, in one flat buffer as WebAudioBufferList's, freeing the
    // previous ones.
    func allocateMicrophoneBuffers(bufferCount: Int, byteCount: Int, channelsPerBuffer: UInt32) {
        freeMicrophoneBuffers()
        precondition(bufferCount > 0 && bufferCount <= 1024 && byteCount >= 0 && byteCount <= Int(UInt32.max))
        let (flatByteCount, overflow) = bufferCount.multipliedReportingOverflow(by: byteCount)
        precondition(!overflow)
        let list = unsafe UnsafeMutableRawPointer.allocate(
            byteCount: 8 &+ bufferCount &* MemoryLayout<AudioBuffer>.stride,
            alignment: 16
        ).assumingMemoryBound(to: AudioBufferList.self)
        unsafe list.pointee.mNumberBuffers = UInt32(bufferCount)
        let data = UnsafeMutableRawPointer.allocate(byteCount: flatByteCount == 0 ? 1 : flatByteCount, alignment: 16)
        unsafe data.initializeMemory(as: UInt8.self, repeating: 0, count: flatByteCount)
        unsafe state.pointee.microphoneList = list
        unsafe state.pointee.microphoneData = data
        unsafe state.pointee.microphoneBufferByteCount = byteCount
        unsafe state.pointee.microphoneChannelsPerBuffer = channelsPerBuffer
        let buffers = unsafe UnsafeMutableRawPointer(list).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
        var index = 0
        while index < bufferCount {
            unsafe buffers.advanced(by: index).initialize(to: AudioBuffer())
            index &+= 1
        }
        unsafe resetMicrophoneBuffers(state)
    }

    func freeMicrophoneBuffers() {
        guard let list = unsafe state.pointee.microphoneList, let data = unsafe state.pointee.microphoneData else {
            return
        }
        unsafe data.deallocate()
        unsafe UnsafeMutableRawPointer(list).deallocate()
        unsafe state.pointee.microphoneList = nil
        unsafe state.pointee.microphoneData = nil
        unsafe state.pointee.microphoneBufferByteCount = 0
    }

    func setCaptureRender(_ function: CaptureRenderFunction, target: UnsafeMutableRawPointer) {
        unsafe state.pointee.captureRender = function
        unsafe state.pointee.captureRenderTarget = target
    }

    func setMicrophoneTiming(sampleRate: Float64, dtsConversionRatio: Float64) {
        unsafe state.pointee.microphoneSampleRate = sampleRate
        unsafe state.pointee.dtsConversionRatio = dtsConversionRatio
    }

    func setSpeakerBytesPerFrame(_ bytesPerFrame: UInt64) {
        unsafe state.pointee.speakerBytesPerFrame = bytesPerFrame
    }

    func setCxxDeliveryContext(_ context: UnsafeMutableRawPointer?) {
        unsafe state.pointee.cxxDeliveryContext = context
    }

    // The main thread's switches, which the IO thread reads at each quantum.
    func setProducingMicrophoneSamples(_ value: Bool) {
        unsafe state.pointee.isProducingMicrophoneSamples.store(value, ordering: .releasing)
    }

    func setReconfiguring(_ value: Bool) {
        unsafe state.pointee.isReconfiguring.store(value, ordering: .releasing)
    }

    // The speaker callback asks the main thread to tell the speaker's producer once, then outputs silence until the main
    // thread has.
    func speakerWillStart() {
        unsafe state.pointee.speakerStartAcknowledged.store(false, ordering: .releasing)
        unsafe state.pointee.speakerStartPending.store(true, ordering: .releasing)
    }

    func acknowledgeSpeakerStart() {
        unsafe state.pointee.speakerStartAcknowledged.store(true, ordering: .releasing)
    }

    var microphoneProcCount: UInt64 {
        unsafe state.pointee.microphoneProcCount.load(ordering: .relaxed)
    }

    func resetMicrophoneProcCount() {
        unsafe state.pointee.microphoneProcCount.store(0, ordering: .relaxed)
    }

    // 0, or failedRenderFlag and the frame count of the first quantum the microphone buffer was too small for, which the
    // next unit provides for.
    var failedRenderFrames: UInt64 {
        unsafe state.pointee.failedRenderFrames.load(ordering: .acquiring)
    }

    // Main thread only: publishes what the speaker callback renders from. The IO thread swaps it in at its next quantum;
    // the snapshot it retires is freed here, at the next publication or once the unit stops.
    func publishSnapshot(speakerTrack: TrackPlayout?) {
        collectRetiredSnapshot()
        let snapshot = UnsafeMutablePointer<CaptureSnapshot>.allocate(capacity: 1)
        unsafe snapshot.initialize(
            to: CaptureSnapshot(
                speakerTrack: speakerTrack?.state,
                speakerTrackOwner: speakerTrack.map { unsafe Unmanaged.passRetained($0) }
            )
        )
        if let unseen = unsafe state.pointee.pendingSnapshot.exchange(UnsafeMutableRawPointer(snapshot), ordering: .acquiringAndReleasing) {
            unsafe freeSnapshot(unseen)
        }
    }

    func collectRetiredSnapshot() {
        if let retired = unsafe state.pointee.retiredSnapshot.exchange(nil, ordering: .acquiring) {
            unsafe freeSnapshot(retired)
        }
    }

    // Once the unit stopped, so no IO thread holds a snapshot: frees them all.
    func freeSnapshotsWhileStopped() {
        collectRetiredSnapshot()
        if let pending = unsafe state.pointee.pendingSnapshot.exchange(nil, ordering: .acquiring) {
            unsafe freeSnapshot(pending)
        }
        if let current = unsafe state.pointee.currentSnapshot {
            unsafe state.pointee.currentSnapshot = nil
            unsafe freeSnapshot(current)
        }
    }

    // Once the unit stopped: hands the IO thread's snapshot back as the pending one, so the next start renders from it.
    func returnCurrentSnapshotWhileStopped() {
        collectRetiredSnapshot()
        guard let current = unsafe state.pointee.currentSnapshot else {
            return
        }
        unsafe state.pointee.currentSnapshot = nil
        if unsafe state.pointee.pendingSnapshot.load(ordering: .acquiring) == nil {
            unsafe state.pointee.pendingSnapshot.store(current, ordering: .releasing)
        } else {
            unsafe freeSnapshot(current)
        }
    }
}

// AudioSampleBufferList::reset(): every microphone buffer back to its place in the flat buffer and its capacity, in case
// the last render moved it.
@inline(__always)
private func resetMicrophoneBuffers(_ state: UnsafeMutablePointer<OutputRenderState>) {
    guard let list = unsafe state.pointee.microphoneList, let data = unsafe state.pointee.microphoneData else {
        preconditionFailure()
    }
    let byteCount = unsafe state.pointee.microphoneBufferByteCount
    let channels = unsafe state.pointee.microphoneChannelsPerBuffer
    let buffers = unsafe UnsafeMutableRawPointer(list).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
    var index = 0
    while index < Int(unsafe list.pointee.mNumberBuffers) {
        unsafe buffers.advanced(by: index).pointee.mNumberChannels = channels
        unsafe buffers.advanced(by: index).pointee.mDataByteSize = UInt32(truncatingIfNeeded: byteCount)
        unsafe buffers.advanced(by: index).pointee.mData = data.advanced(by: index &* byteCount)
        index &+= 1
    }
}

var failedRenderFlag: UInt64 { 1 << 32 }

private func freeSnapshot(_ raw: UnsafeMutableRawPointer) {
    let snapshot = unsafe raw.assumingMemoryBound(to: CaptureSnapshot.self)
    unsafe snapshot.pointee.speakerTrackOwner?.release()
    unsafe snapshot.deinitialize(count: 1)
    unsafe snapshot.deallocate()
}

// IO thread only, wait-free: takes a published snapshot once the main thread has freed the one retired before.
@inline(__always)
private func takePublishedSnapshot(_ state: UnsafeMutablePointer<OutputRenderState>) {
    if unsafe state.pointee.retiredSnapshot.load(ordering: .acquiring) != nil {
        return
    }
    guard let next = unsafe state.pointee.pendingSnapshot.exchange(nil, ordering: .acquiring) else {
        return
    }
    if let current = unsafe state.pointee.currentSnapshot {
        unsafe state.pointee.retiredSnapshot.store(current, ordering: .releasing)
    }
    unsafe state.pointee.currentSnapshot = next
}


// MARK: Attaching what a stopped unit renders from

// Traps unless the attachment's memory covers what the unit will read and write, aligned for its atomics.
private func checkRingAttachment(_ attachment: WebCore.AudioOutputUnitRingAttachment) {
    let geometry = unsafe attachment.geometry
    let channels = unsafe attachment.channels
    let channelsByteCount = unsafe attachment.channelsByteCount
    let frameCounterByteCount = unsafe attachment.frameCounterByteCount
    if let header = unsafe attachment.header {
        _ = unsafe checkRingHeader(UnsafeRawPointer(header), ringHeaderByteCount)
        let (byteCount, overflow) = geometry.capacityBytes.multipliedReportingOverflow(by: UInt64(geometry.channelCount))
        precondition(!overflow && byteCount <= channelsByteCount && channelsByteCount <= UInt64(Int.max))
        precondition(unsafe channels != nil || channelsByteCount == 0)
    }
    if let counter = unsafe attachment.frameCounter {
        precondition(frameCounterByteCount % 4 == 0)
        precondition(Int(bitPattern: UnsafeRawPointer(counter)) & 3 == 0)
    }
}

// What a unit renders from or delivers to:
// - a remote destination's ring, frame counter and semaphore (WebCore::AudioOutputUnit::attachRing());
// - a track renderer's track playout, by identifier (WebCore::AudioOutputUnit::attachTrackPlayout());
// - a track playout's ring and semaphore (WebCore::AudioTrackPlayout::attachRing());
// - the C++ that a capture unit delivers its microphone's quanta to, and the track playout its speaker plays out, by
//   identifier (WebCore::AudioCaptureUnitHandle::attach()).
// The caller keeps their memory and the semaphore alive until it attaches others or destroys the unit. A ring without a
// header is no ring.
@_expose(Cxx)
func audioUnitAttachRing(_ identifier: UInt64, _ attachment: WebCore.AudioOutputUnitRingAttachment) {
    if let track = trackPlayout(identifier) {
        unsafe checkRingAttachment(attachment)
        unsafe track.attachRing(attachment)
        return
    }
    if let unit = captureUnit(identifier) {
        if !unit.hasCxxDeliveryContext {
            precondition(!unit.isRunning)
            unsafe unit.renderState.setCxxDeliveryContext(attachment.cxxDeliveryContext)
            unit.hasCxxDeliveryContext = true
        }
        let speakerTrack = unsafe attachment.trackPlayoutIdentifier
        unit.attachSpeakerTrack(speakerTrack == 0 ? nil : trackPlayout(speakerTrack))
        return
    }
    if unsafe attachment.trackPlayoutIdentifier != 0 {
        guard let unit = outputUnit(identifier), let track = trackPlayout(unsafe attachment.trackPlayoutIdentifier) else {
            return
        }
        unit.attachTrackPlayout(track)
        return
    }
    unsafe checkRingAttachment(attachment)
    var ring = unsafe attachment
    if unsafe ring.frameCounterByteCount == 0 {
        unsafe ring.frameCounter = nil
    }
    withStoppedOutputUnitRenderState(identifier) { reference in
        unsafe reference.state.pointee.ring = ring
    }
}

// Stores what a stopped track renderer renders from: a GPU-process playout or an in-process C++ render callback.
func setTrackRenderSource(
    _ reference: RenderStateReference,
    _ track: TrackPlayout?,
    _ cxxRender: AURenderCallback?,
    _ cxxRefCon: UnsafeMutableRawPointer?
) {
    unsafe reference.state.pointee.track = track?.state
    unsafe reference.state.pointee.cxxRender = cxxRender
    unsafe reference.state.pointee.cxxRefCon = cxxRefCon
}

// An in-process destination's or track renderer's C++ render callback (WebCore::AudioOutputUnit::attachRenderCallback()),
// before the unit first starts. A destination's unit calls it on its IO thread with refCon, so no Swift runs there; a track
// renderer's checks its timeline, calls it and clips. callback is an AURenderCallback.
@_expose(Cxx)
func audioOutputUnitAttachCxxRenderCallback(_ identifier: UInt64, _ callback: UnsafeRawPointer, _ refCon: UnsafeMutableRawPointer?) {
    let renderCallback = unsafe unsafeBitCast(callback, to: AURenderCallback.self)
    guard let unit = outputUnit(identifier) else {
        return
    }
    unsafe unit.setCxxRenderCallback(renderCallback, refCon)
}

// MARK: Render callbacks

// The render callback of a GPU-process audio destination (RemoteAudioDestination): plays out the ring the web process
// writes, then adds the quantum's frames to the shared counter and signals the semaphore, as RemoteAudioDestination::render()
// did.
func remoteDestinationRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    precondition(pthread_main_np() == 0)
    let state = unsafe refCon.assumingMemoryBound(to: OutputRenderState.self)
    precondition(!(unsafe state.pointee.isRendering.exchange(true, ordering: .acquiring)))
    let status = unsafe renderRemoteDestination(state, frameCount, ioData)
    unsafe state.pointee.isRendering.store(false, ordering: .releasing)
    return status
}

private func renderRemoteDestination(
    _ state: UnsafeMutablePointer<OutputRenderState>,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ring = unsafe state.pointee.ring
    guard let header = unsafe ring.header else {
        return -1
    }
    guard let ioData = unsafe ioData else {
        preconditionFailure()
    }
    let bounds = unsafe loadRingBounds(at: UnsafeRawPointer(header))
    let channels = unsafe IOConstBytes(UnsafeRawPointer(ring.channels), Int(ring.channelsByteCount))
    var output = unsafe IOBufferList(ioData)
    var lastRenderedSamples = unsafe IOBytes(
        state.pointee.lastRenderedSamples,
        state.pointee.lastRenderedSampleCount &* 4
    )
    let rendered = unsafe renderRemoteDestinationQuantum(
        ring.geometry,
        bounds,
        channels,
        &output,
        &lastRenderedSamples,
        &state.pointee.startFrame,
        frameCount
    )
    if let counter = unsafe ring.frameCounter {
        _ = unsafe UnsafeMutableRawPointer(counter).assumingMemoryBound(to: Atomic<UInt32>.self).pointee.add(
            frameCount,
            ordering: .sequentiallyConsistent
        )
    }
    _ = unsafe semaphore_signal(ring.semaphore)
    return rendered ? 0 : -1
}

// The render callback of a GPU-process track renderer (RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit): checks
// the timeline, plays out the ring the web process writes and clips, as LocalAudioMediaStreamTrackRendererInternalUnit's
// render() and the manager unit's render() did. A timeline jump is an event for the main thread, which resets the track.
func trackRendererRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    precondition(pthread_main_np() == 0)
    let state = unsafe refCon.assumingMemoryBound(to: OutputRenderState.self)
    precondition(!(unsafe state.pointee.isRendering.exchange(true, ordering: .acquiring)))
    unsafe checkTimeline(state, timeStamp.pointee.mSampleTime, frameCount)
    guard let ioData = unsafe ioData, let track = unsafe state.pointee.track else {
        preconditionFailure()
    }
    let status = unsafe renderTrack(track, ioData, frameCount, actionFlags)
    unsafe clip(ioData, state.pointee.clipFormat)
    unsafe state.pointee.isRendering.store(false, ordering: .releasing)
    return status
}

// The render callback of an in-process track renderer: checks the timeline, calls the C++ render callback that mixes the
// track's sources, and clips. The call to C++ is the one indirect call of the IO path, and only in process.
func inProcessTrackRendererRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    precondition(pthread_main_np() == 0)
    let state = unsafe refCon.assumingMemoryBound(to: OutputRenderState.self)
    precondition(!(unsafe state.pointee.isRendering.exchange(true, ordering: .acquiring)))
    unsafe checkTimeline(state, timeStamp.pointee.mSampleTime, frameCount)
    guard let render = unsafe state.pointee.cxxRender, let cxxRefCon = unsafe state.pointee.cxxRefCon, let ioData = unsafe ioData else {
        preconditionFailure()
    }
    let status = unsafe render(cxxRefCon, actionFlags, timeStamp, busNumber, frameCount, ioData)
    unsafe clip(ioData, state.pointee.clipFormat)
    unsafe state.pointee.isRendering.store(false, ordering: .releasing)
    return status
}

// LocalAudioMediaStreamTrackRendererInternalUnit::render()'s timeline check: a quantum that starts more than a quantum
// after the last one, or not after it, means the timeline jumped.
@inline(__always)
private func checkTimeline(_ state: UnsafeMutablePointer<OutputRenderState>, _ sampleTime: Float64, _ frameCount: UInt32) {
    let lastSampleTime = unsafe state.pointee.lastSampleTime
    if lastSampleTime != 0
        && (float64(lastSampleTime &+ UInt64(2 &* frameCount)) < sampleTime || sampleTime <= float64(lastSampleTime))
    {
        unsafe postEvent(state, AudioUnitEvent.timelineDiscontinuity)
    }
    // std::numeric_limits<Float64>::max().
    let isValid = sampleTime < 1.7976931348623157e308 - Float64(Int(frameCount)) && sampleTime >= 0
        && sampleTime < 18_446_744_073_709_551_616.0
    unsafe state.pointee.lastSampleTime = isValid ? UInt64(sampleTime) : 0
}

// The C++ conversion of a uint64_t to a double: both halves convert exactly, so their sum rounds once, as the conversion
// does. Swift's Double(_: UInt64) is generic, which needs the Swift runtime at -Onone.
@inline(__always)
private func float64(_ value: UInt64) -> Float64 {
    Float64(Int(value >> 32)) * 4_294_967_296.0 + Float64(Int(value & 0xFFFF_FFFF))
}

// Clips Float32 or Float64 samples to [-1, 1] with vDSP, as the C++ did.
private func clip(_ ioData: UnsafeMutablePointer<AudioBufferList>, _ format: UInt8) {
    if format == TrackClipFormat.none {
        return
    }
    let bufferCount = Int(unsafe ioData.pointee.mNumberBuffers)
    let first = unsafe UnsafeMutableRawPointer(ioData).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
    var index = 0
    while index < bufferCount {
        let buffer = unsafe first.advanced(by: index).pointee
        if let data = unsafe buffer.mData {
            if format == TrackClipFormat.float32 {
                var minimum: Float = -1
                var maximum: Float = 1
                let samples = unsafe data.assumingMemoryBound(to: Float.self)
                unsafe vDSP_vclip(samples, 1, &minimum, &maximum, samples, 1, vDSP_Length(buffer.mDataByteSize / 4))
            } else {
                var minimum: Double = -1
                var maximum: Double = 1
                let samples = unsafe data.assumingMemoryBound(to: Double.self)
                unsafe vDSP_vclipD(samples, 1, &minimum, &maximum, samples, 1, vDSP_Length(buffer.mDataByteSize / 8))
            }
        }
        index &+= 1
    }
}

// The manager unit's render(): plays out the track's ring into ioData and signals its semaphore for each chunk it asks for.
// Traps unless the track's ring covers what it reads. While the main thread changes the track, it outputs silence, as the
// C++'s speaker callback did when it couldn't take its lock.
private func renderTrack(
    _ track: UnsafeMutablePointer<TrackPlayoutState>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ frameCount: UInt32,
    _ actionFlags: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    var output = unsafe IOBufferList(ioData)
    if unsafe track.pointee.isRendering.exchange(true, ordering: .acquiring) {
        unsafe zeroTrackOutput(&output, UInt64(frameCount) &* track.pointee.bytesPerFrame)
        unsafe actionFlags.pointee = silenceActionFlag
        return 0
    }
    let ring = unsafe track.pointee.ring
    var signalCount: UInt64 = 0
    var fetched = false
    if let header = unsafe ring.header {
        let geometry = unsafe ring.geometry
        let (byteCount, overflow) = geometry.capacityBytes.multipliedReportingOverflow(by: UInt64(geometry.channelCount))
        let channelsByteCount = unsafe ring.channelsByteCount
        precondition(!overflow && byteCount <= channelsByteCount && channelsByteCount <= UInt64(Int.max))
        let headerAddress = unsafe checkRingHeader(UnsafeRawPointer(header), ringHeaderByteCount)
        let bounds = unsafe loadRingBounds(at: headerAddress)
        let channels = unsafe IOConstBytes(UnsafeRawPointer(ring.channels), Int(ring.channelsByteCount))
        fetched = unsafe renderTrackQuantum(
            geometry,
            bounds,
            channels,
            &output,
            &track.pointee.readOffset,
            &track.pointee.generateOffset,
            &signalCount,
            UInt64(frameCount),
            track.pointee.frameChunkSize,
            track.pointee.bytesPerFrame
        )
    } else {
        // Not reached: a track renderer starts only once its track has a ring.
        unsafe zeroTrackOutput(&output, UInt64(frameCount) &* track.pointee.bytesPerFrame)
    }
    if !fetched {
        unsafe actionFlags.pointee = silenceActionFlag
    }
    let semaphore = unsafe ring.semaphore
    while signalCount > 0 {
        _ = semaphore_signal(semaphore)
        signalCount &-= 1
    }
    unsafe track.pointee.isRendering.store(false, ordering: .releasing)
    return fetched ? 0 : -1
}

// kAudioUnitRenderAction_OutputIsSilence.
private var silenceActionFlag: UInt32 { 1 << 4 }

// MARK: Capture callbacks

// The capture unit's microphone callback (CoreAudioCaptureUnit::processMicrophoneSamples()): renders the quantum into the
// unit's own buffers through AudioUnitRender() (or the mock's render function: the one indirect call of the GPU IO path),
// counts it, times it and, while the unit produces microphone samples, delivers it to the C++ observers. A buffer too small
// for the quantum is an event for the main thread, which reconfigures the unit.
func microphoneRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    precondition(pthread_main_np() == 0)
    let state = unsafe refCon.assumingMemoryBound(to: OutputRenderState.self)
    precondition(!(unsafe state.pointee.isCapturing.exchange(true, ordering: .acquiring)))
    let status = unsafe captureMicrophone(state, actionFlags, timeStamp, busNumber, frameCount)
    unsafe state.pointee.isCapturing.store(false, ordering: .releasing)
    return status
}

private func captureMicrophone(
    _ state: UnsafeMutablePointer<OutputRenderState>,
    _ actionFlags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32
) -> OSStatus {
    if unsafe state.pointee.isReconfiguring.load(ordering: .acquiring) {
        return 0
    }
    guard let render = unsafe state.pointee.captureRender, let target = unsafe state.pointee.captureRenderTarget,
        let list = unsafe state.pointee.microphoneList
    else {
        preconditionFailure()
    }
    unsafe resetMicrophoneBuffers(state)
    // The one indirect call of the GPU-process IO path: AudioUnitRender(), or the mock's render function.
    let status = unsafe render(target, actionFlags, timeStamp, busNumber, frameCount, list)
    if status != 0 {
        // kAudio_ParamError: the buffer might be too small for the preferred buffer size or sample rate.
        if status == -50
            && (unsafe state.pointee.failedRenderFrames.compareExchange(
                expected: 0,
                desired: failedRenderFlag | UInt64(frameCount),
                ordering: .acquiringAndReleasing
            ).exchanged)
        {
            unsafe postEvent(state, AudioUnitEvent.microphoneBufferTooSmall)
        }
        return status
    }
    _ = unsafe state.pointee.microphoneProcCount.add(1, ordering: .relaxed)
    if !(unsafe state.pointee.isProducingMicrophoneSamples.load(ordering: .acquiring)) {
        return 0
    }
    let times = unsafe audioCaptureTimes(
        timeStamp.pointee.mSampleTime,
        timeStamp.pointee.mHostTime,
        state.pointee.dtsConversionRatio,
        state.pointee.microphoneSampleRate
    )
    if let context = unsafe state.pointee.cxxDeliveryContext {
        unsafe WebCore.deliverToCxxObservers(context, list, frameCount, times)
    }
    return 0
}

// The times of a microphone quantum, with the C++'s conversions as compiled for arm64 (saturating): its sample time
// truncated to an integer frame, the host time scaled to the presentation clock, and the times its sample buffer records.
private func audioCaptureTimes(_ sampleTime: Float64, _ hostTime: UInt64, _ dtsConversionRatio: Float64, _ sampleRate: Float64)
    -> WebCore.AudioCaptureTimes
{
    var times = WebCore.AudioCaptureTimes()
    let adjustedHostTime = dtsConversionRatio * float64(hostTime)
    let frame = saturatingUInt64(sampleTime)
    times.sampleTime = sampleTime
    times.mediaTimeValue = Int64(bitPattern: frame)
    let scale = saturatingUInt64(sampleRate)
    times.mediaTimeScale = scale > 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: scale)
    times.adjustedHostTime = adjustedHostTime
    times.bufferTimestamp = saturatingUInt64(adjustedHostTime)
    times.bufferHostTime = float64(frame)
    return times
}

// A double converted to uint64_t as arm64's fcvtzu does: NaN and negative values give 0, values too large give the maximum.
@inline(__always)
private func saturatingUInt64(_ value: Float64) -> UInt64 {
    if value >= 18_446_744_073_709_551_616.0 {
        return UInt64.max
    }
    return value > 0 ? UInt64(value) : 0
}

// The capture unit's speaker callback (CoreAudioCaptureUnit::provideSpeakerData()): takes the speaker snapshot the main
// thread published, then plays out its track Swift to Swift, or outputs silence while the unit reconfigures, until the main
// thread has told the speaker's producer that the unit started, or without a track.
func speakerRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<UInt32>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    precondition(pthread_main_np() == 0)
    let state = unsafe refCon.assumingMemoryBound(to: OutputRenderState.self)
    precondition(!(unsafe state.pointee.isRendering.exchange(true, ordering: .acquiring)))
    guard let ioData = unsafe ioData else {
        preconditionFailure()
    }
    unsafe takePublishedSnapshot(state)
    var track: UnsafeMutablePointer<TrackPlayoutState>? = nil
    if let snapshot = unsafe state.pointee.currentSnapshot {
        unsafe track = snapshot.assumingMemoryBound(to: CaptureSnapshot.self).pointee.speakerTrack
    }
    let status: OSStatus
    if let track = unsafe track, !(unsafe state.pointee.isReconfiguring.load(ordering: .acquiring)),
        !(unsafe state.pointee.speakerStartPending.load(ordering: .acquiring)),
        unsafe state.pointee.speakerStartAcknowledged.load(ordering: .acquiring)
    {
        status = unsafe renderTrack(track, ioData, frameCount, actionFlags)
    } else {
        if unsafe state.pointee.speakerStartPending.exchange(false, ordering: .acquiringAndReleasing) {
            unsafe postEvent(state, AudioUnitEvent.speakerStarting)
        }
        var output = unsafe IOBufferList(ioData)
        unsafe zeroTrackOutput(&output, UInt64(frameCount) &* state.pointee.speakerBytesPerFrame)
        unsafe actionFlags.pointee = silenceActionFlag
        status = 0
    }
    unsafe state.pointee.isRendering.store(false, ordering: .releasing)
    return status
}

// MARK: The mock capture unit

// MockAudioCaptureUnit::increaseBufferSize(): the mock's quanta fake a microphone buffer that is too small until a buffer
// is big enough (mockCaptureRender()).
let mockShouldIncreaseBufferSize = Atomic<Bool>(false)

// The mock microphone's buffers (AudioCaptureUnit.swift's MockCaptureBackend), at an address that stays put for the mock's
// life, which its render function copies into the microphone's, as MockAudioCaptureInternalUnit's did. The mock's queue
// allocates them before its first quantum.
@unsafe struct MockCaptureBuffers: ~Copyable {
    var list: UnsafeMutablePointer<AudioBufferList>? = nil
    var data: UnsafeMutableRawPointer? = nil
    var bytesPerBuffer: Int = 0
    var bytesPerPacket: UInt32 = 0
}

@safe struct MockCaptureBuffersReference: @unchecked Sendable {
    fileprivate let buffers: UnsafeMutablePointer<MockCaptureBuffers>
}

func makeMockCaptureBuffers() -> MockCaptureBuffersReference {
    let buffers = UnsafeMutablePointer<MockCaptureBuffers>.allocate(capacity: 1)
    unsafe buffers.initialize(to: MockCaptureBuffers())
    return unsafe MockCaptureBuffersReference(buffers: buffers)
}

// Once the mock's queue is done with them.
func freeMockCaptureBuffers(_ reference: MockCaptureBuffersReference) {
    reference.freeList()
    unsafe reference.buffers.deinitialize(count: 1)
    unsafe reference.buffers.deallocate()
}

extension MockCaptureBuffersReference {
    var isAllocated: Bool {
        unsafe buffers.pointee.list != nil
    }

    fileprivate func freeList() {
        if let list = unsafe buffers.pointee.list {
            unsafe UnsafeMutableRawPointer(list).deallocate()
        }
        unsafe buffers.pointee.data?.deallocate()
        unsafe buffers.pointee.list = nil
        unsafe buffers.pointee.data = nil
    }

    // A WebAudioBufferList's buffers for frameCount frames of the format, zeroed.
    func allocate(_ format: AudioStreamBasicDescription, frameCount: Int) {
        freeList()
        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bufferCount = isInterleaved ? 1 : Int(format.mChannelsPerFrame)
        let channelsPerBuffer: UInt32 = isInterleaved ? format.mChannelsPerFrame : 1
        let sizes = webAudioBufferListSizes(channelsPerBuffer, format.mBytesPerFrame, UInt32(bufferCount), UInt64(frameCount))
        precondition(sizes.isValid && bufferCount > 0 && sizes.bytesPerBuffer <= UInt64(UInt32.max))
        let bytesPerBuffer = Int(sizes.bytesPerBuffer)
        let list = unsafe UnsafeMutableRawPointer.allocate(byteCount: 8 &+ bufferCount &* MemoryLayout<AudioBuffer>.stride, alignment: 16)
            .assumingMemoryBound(to: AudioBufferList.self)
        unsafe list.pointee.mNumberBuffers = UInt32(bufferCount)
        let flatByteCount = Int(sizes.flatBufferSize)
        let data = UnsafeMutableRawPointer.allocate(byteCount: flatByteCount == 0 ? 1 : flatByteCount, alignment: 16)
        unsafe data.initializeMemory(as: UInt8.self, repeating: 0, count: flatByteCount)
        let audioBuffers = unsafe UnsafeMutableRawPointer(list).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
        var index = 0
        while index < bufferCount {
            unsafe audioBuffers.advanced(by: index).initialize(
                to: AudioBuffer(
                    mNumberChannels: channelsPerBuffer,
                    mDataByteSize: UInt32(bytesPerBuffer),
                    mData: data.advanced(by: index &* bytesPerBuffer)
                )
            )
            index &+= 1
        }
        unsafe buffers.pointee.list = list
        unsafe buffers.pointee.data = data
        unsafe buffers.pointee.bytesPerBuffer = bytesPerBuffer
        unsafe buffers.pointee.bytesPerPacket = format.mBytesPerPacket
    }

    // MockAudioCaptureInternalUnit::generateSampleBuffers(): each buffer holds byteCount bytes, the first count Float32
    // samples of which are samples from start plus a hum of humPeriod frames from frame humStart, as addHum() made it.
    func fill(byteCount: UInt32, _ samples: borrowing [Float], start: Int, count: Int, humStart: UInt64, humPeriod: Float) {
        guard let list = unsafe buffers.pointee.list else {
            preconditionFailure()
        }
        let bytesPerBuffer = unsafe buffers.pointee.bytesPerBuffer
        precondition(Int(byteCount) <= bytesPerBuffer && count >= 0 && count &* 4 <= Int(byteCount))
        precondition(start >= 0 && count <= samples.count &- start)
        let audioBuffers = unsafe UnsafeMutableRawPointer(list).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
        let tau = 2 * Double.pi
        var index = 0
        while index < Int(unsafe list.pointee.mNumberBuffers) {
            let buffer = unsafe audioBuffers.advanced(by: index)
            unsafe buffer.pointee.mDataByteSize = byteCount
            guard let floats = unsafe buffer.pointee.mData?.assumingMemoryBound(to: Float.self) else {
                preconditionFailure()
            }
            var frame = 0
            while frame < count {
                let hum = Float(Double(Float(0.1)) * sin(Double(humStart &+ UInt64(frame)) * tau / Double(humPeriod)))
                unsafe floats[frame] = samples[start &+ frame] + hum
                frame &+= 1
            }
            index &+= 1
        }
    }
}

// The microphone callback of a mock capture unit renders the mock's buffers with mockCaptureRender().
func attachMockCaptureRender(_ state: RenderStateReference, _ buffers: MockCaptureBuffersReference) {
    unsafe state.setCaptureRender(mockCaptureRender, target: UnsafeMutableRawPointer(buffers.buffers))
}

// MockAudioCaptureInternalUnit::render(): copies frameCount packets of each mock buffer into the destination, or fails as
// the C++ did when asked to fake a too-small buffer.
private func mockCaptureRender(
    _ target: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<UInt32>?,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ destination: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    let mock = unsafe target.assumingMemoryBound(to: MockCaptureBuffers.self)
    let destinationCount = Int(unsafe destination.pointee.mNumberBuffers)
    let destinationBuffers = unsafe UnsafeMutableRawPointer(destination).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
    let copySize = Int(frameCount) &* Int(unsafe mock.pointee.bytesPerPacket)
    if mockShouldIncreaseBufferSize.load(ordering: .relaxed) {
        if destinationCount != 0 && copySize <= Int(unsafe destinationBuffers.pointee.mDataByteSize) {
            mockShouldIncreaseBufferSize.store(false, ordering: .relaxed)
        }
        // Still an error: there isn't enough data to write.
        return -50
    }
    guard let source = unsafe mock.pointee.list else {
        preconditionFailure()
    }
    let sourceCount = Int(unsafe source.pointee.mNumberBuffers)
    if destinationCount > sourceCount {
        return -50
    }
    let sourceBuffers = unsafe UnsafeMutableRawPointer(source).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
    var index = 0
    while index < destinationCount {
        let from = unsafe sourceBuffers.advanced(by: index).pointee
        let to = unsafe destinationBuffers.advanced(by: index).pointee
        precondition(copySize <= Int(unsafe from.mDataByteSize))
        if copySize > Int(unsafe to.mDataByteSize) {
            return -50
        }
        if copySize != 0 {
            guard let toData = unsafe to.mData, let fromData = unsafe from.mData else {
                preconditionFailure()
            }
            _ = unsafe memmove(toData, fromData, copySize)
        }
        index &+= 1
    }
    return 0
}

// MockAudioCaptureInternalUnit::emitSampleBuffers(): calls a capture unit's microphone callback for exposedFrameCount
// frames, then its speaker callback for frameCount frames into the mock's buffers, as its IO thread would.
func emitMockQuantum(
    _ state: RenderStateReference,
    _ buffers: MockCaptureBuffersReference,
    sampleTime: Float64,
    frameCount: UInt32,
    exposedFrameCount: UInt32
) {
    guard let list = unsafe buffers.buffers.pointee.list else {
        preconditionFailure()
    }
    var timeStamp = AudioTimeStamp()
    timeStamp.mSampleTime = sampleTime
    timeStamp.mHostTime = saturatingUInt64(sampleTime)
    var flags: UInt32 = 0
    _ = unsafe microphoneRenderCallback(state.refCon, &flags, &timeStamp, 1, exposedFrameCount, nil)
    flags = 0
    _ = unsafe speakerRenderCallback(state.refCon, &flags, &timeStamp, 1, frameCount, list)
}


// MARK: Tests

// Tests only, on a thread other than the main thread and while the main thread leaves the unit alone: renders one quantum
// of frameCount frames into ioData, by calling the unit's render callback (a capture unit's speaker callback) directly, or
// through AudioUnitRender() on a unit made for testing.
@_expose(Cxx)
func audioOutputUnitRenderForTesting(
    _ identifier: UInt64,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ frameCount: UInt32,
    _ sampleTime: Float64,
    _ throughAudioUnit: Bool,
    _ actionFlags: UnsafeMutablePointer<UInt32>
) -> Int32 {
    if let unit = unsafe captureUnits[identifier] {
        precondition(!throughAudioUnit)
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid
        return unsafe speakerRenderCallback(unit.renderState.refCon, actionFlags, &timeStamp, 0, frameCount, ioData)
    }
    guard let unit = unsafe outputUnits[identifier] else {
        return kAudio_ParamError
    }
    return unsafe unit.renderForTesting(ioData, frameCount, sampleTime, throughAudioUnit, actionFlags)
}

#endif // ENABLE_WEBCORE_SWIFT
