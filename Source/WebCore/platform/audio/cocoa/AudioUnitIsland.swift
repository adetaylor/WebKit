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
import AudioToolbox
import Darwin
import Synchronization
import WebCore_Private.Core.CARingBufferSwiftBridge

// The audited `unsafe` of WebCore's CoreAudio glue: memory that C++ or CoreAudio hands over as pointers, and the atomics
// shared with other threads and processes. Everything else in the glue is safe Swift over what this file lends it.
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
    var ring = unsafe WebCore.AudioOutputUnitRingAttachment()
    var startFrame: UInt64 = 0
    let lastRenderedSamples: UnsafeMutableRawPointer
    let lastRenderedSampleCount: Int
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
    return unsafe RenderStateReference(state: state)
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

// A remote destination's ring, frame counter and semaphore (WebCore::AudioOutputUnit::attachRing()). The caller keeps their
// memory and the semaphore alive until it attaches others or destroys the unit. A ring without a header is no ring.
@_expose(Cxx)
func audioUnitAttachRing(_ identifier: UInt64, _ attachment: WebCore.AudioOutputUnitRingAttachment) {
    unsafe checkRingAttachment(attachment)
    var ring = unsafe attachment
    if unsafe ring.frameCounterByteCount == 0 {
        unsafe ring.frameCounter = nil
    }
    withStoppedOutputUnitRenderState(identifier) { reference in
        unsafe reference.state.pointee.ring = ring
    }
}

// An in-process destination's C++ render callback (WebCore::AudioOutputUnit::attachRenderCallback()), before the unit
// first starts. The unit calls it on its IO thread with refCon, so no Swift runs there. callback is an AURenderCallback.
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
    _ throughAudioUnit: Bool
) -> Int32 {
    guard let unit = unsafe outputUnits[identifier] else {
        return kAudio_ParamError
    }
    return unsafe unit.renderForTesting(ioData, frameCount, sampleTime, throughAudioUnit)
}

#endif // ENABLE_WEBCORE_SWIFT
