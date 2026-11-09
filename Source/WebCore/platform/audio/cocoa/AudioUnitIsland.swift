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
    // A track renderer's: the sample time of the last quantum (0 before the first), how to clip its output, and the C++
    // render callback of an in-process track renderer.
    var lastSampleTime: UInt64 = 0
    var clipFormat: UInt8 = 0
    var cxxRender: AURenderCallback? = nil
    var cxxRefCon: UnsafeMutableRawPointer? = nil
}

// The events of a unit's IO thread that only the main thread can act on (WebCore::AudioOutputUnit::Event).
enum AudioUnitEvent {
    // A track renderer saw its timeline jump.
    static var timelineDiscontinuity: UInt32 { 1 }
}

// How a track renderer clips its output (CAAudioStreamDescription::PCMFormat): Float32 and Float64 to [-1, 1].
enum TrackClipFormat {
    static var none: UInt8 { 0 }
    static var float32: UInt8 { 1 }
    static var float64: UInt8 { 2 }
}

// An output unit's render state, which its owner frees.
@safe struct RenderStateReference {
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

    func attachTrackPlayout(_ attachment: WebCore.AudioOutputUnitRingAttachment) {
        precondition(kind == .trackRenderer && rendersPlayout && !isRunning)
        if let renderState {
            unsafe setTrackRenderSource(renderState, attachment.track, nil, nil)
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

// A remote destination's ring, frame counter and semaphore (WebCore::AudioOutputUnit::attachRing()), or a track renderer's
// playout (attachTrackPlayout()). The caller keeps their memory and the semaphore alive until it attaches others or destroys
// the unit. A ring without a header is no ring.
@_expose(Cxx)
func audioUnitAttachRing(_ identifier: UInt64, _ attachment: WebCore.AudioOutputUnitRingAttachment) {
    if unsafe attachment.track != nil {
        guard let unit = outputUnit(identifier) else {
            return
        }
        unsafe unit.attachTrackPlayout(attachment)
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
    _ track: UnsafeMutablePointer<WebCore.AudioTrackPlayoutState>?,
    _ cxxRender: AURenderCallback?,
    _ cxxRefCon: UnsafeMutableRawPointer?
) {
    unsafe reference.state.pointee.ring.track = track
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
    guard let ioData = unsafe ioData, let track = unsafe state.pointee.ring.track else {
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
// Traps unless the track's ring covers what it reads.
private func renderTrack(
    _ track: UnsafeMutablePointer<WebCore.AudioTrackPlayoutState>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ frameCount: UInt32,
    _ actionFlags: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let renderingGuard = unsafe UnsafeMutableRawPointer(track).assumingMemoryBound(to: Atomic<UInt64>.self)
    precondition(unsafe renderingGuard.pointee.exchange(1, ordering: .acquiring) == 0)
    let ring = unsafe track.pointee.ring
    var output = unsafe IOBufferList(ioData)
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
        // kAudioUnitRenderAction_OutputIsSilence.
        unsafe actionFlags.pointee = 1 << 4
    }
    let semaphore = unsafe ring.semaphore
    while signalCount > 0 {
        _ = semaphore_signal(semaphore)
        signalCount &-= 1
    }
    unsafe renderingGuard.pointee.store(0, ordering: .releasing)
    return fetched ? 0 : -1
}

// The capture unit's speaker callback, on its IO thread (RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit::
// produceSpeakerSamples()), until that callback is Swift: plays out a track as its unit's render callback does, without
// the timeline check or clipping, as the C++ did.
@_expose(Cxx)
func audioTrackRenderForSpeaker(
    _ track: UnsafeMutablePointer<WebCore.AudioTrackPlayoutState>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ frameCount: UInt32,
    _ actionFlags: UnsafeMutablePointer<UInt32>
) -> Int32 {
    unsafe renderTrack(track, ioData, frameCount, actionFlags)
}

// MARK: Tests

// Tests only, on a thread other than the main thread and while the main thread leaves the unit alone: renders one quantum
// of frameCount frames into ioData, by calling the unit's render callback directly, or through AudioUnitRender() on a unit
// made for testing.
@_expose(Cxx)
func audioOutputUnitRenderForTesting(
    _ identifier: UInt64,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ frameCount: UInt32,
    _ sampleTime: Float64,
    _ throughAudioUnit: Bool,
    _ actionFlags: UnsafeMutablePointer<UInt32>
) -> Int32 {
    guard let unit = unsafe outputUnits[identifier] else {
        return kAudio_ParamError
    }
    return unsafe unit.renderForTesting(ioData, frameCount, sampleTime, throughAudioUnit, actionFlags)
}

#endif // ENABLE_WEBCORE_SWIFT
