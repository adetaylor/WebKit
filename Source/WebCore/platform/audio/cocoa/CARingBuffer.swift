// Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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

// The safe Span overloads Swift synthesizes for the views' spans call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.CARingBufferSwiftBridge

// CARingBuffer's logic. Its arithmetic is the C++'s: sizes and offsets are size_t (UInt) and frames uint64_t
// (UInt64), and both wrap where the C++'s unsigned arithmetic does. Every byte range is checked against the span it is
// in, so wrapped values only shorten what is copied, as in the C++.

// CARingBuffer::FetchMode.
enum CARingBufferFetchMode: UInt32 {
    case copy
    case mixInt16
    case mixInt32
    case mixFloat32
    case mixFloat64
}

struct RingLayout {
    let bytesPerFrame: UInt
    let capacityBytes: UInt
    let channelCount: UInt32
    let frameCount: UInt32

    init(_ geometry: WebCore.CARingBufferGeometry) {
        bytesPerFrame = UInt(truncatingIfNeeded: geometry.bytesPerFrame)
        capacityBytes = UInt(truncatingIfNeeded: geometry.capacityBytes)
        channelCount = geometry.channelCount
        frameCount = geometry.frameCount
    }

    func frameOffset(_ frame: UInt64) -> UInt {
        UInt(truncatingIfNeeded: (frame % UInt64(frameCount)) &* UInt64(bytesPerFrame))
    }

    // The bytes of a channel within all the channels' bytes.
    func channelRange(_ channel: UInt) -> Range<Int> {
        let start = Int(channel &* capacityBytes)
        return start..<start + Int(capacityBytes)
    }
}

// std::clamp().
private func clamp(_ value: UInt64, _ low: UInt64, _ high: UInt64) -> UInt64 {
    value < low ? low : (high < value ? high : value)
}

// std::min(), for the IO path: Swift's generic min() needs the Swift runtime at -Onone.
func audioMinimum(_ a: UInt64, _ b: UInt64) -> UInt64 {
    b < a ? b : a
}

func audioMinimum(_ a: UInt, _ b: UInt) -> UInt {
    b < a ? b : a
}

func audioMinimum(_ a: Int, _ b: Int) -> Int {
    b < a ? b : a
}

// std::bit_ceil(), which traps if the result doesn't fit.
private func roundUpToPowerOfTwo(_ value: UInt) -> UInt {
    if value < 2 {
        return 1
    }
    let bits = UInt.bitWidth &- (value &- 1).leadingZeroBitCount
    precondition(bits < UInt.bitWidth)
    return 1 &<< UInt(bits)
}

// Zeroes count bytes of bytes from offset, as memset does. Traps unless the range is inside the span.
func zeroAudioBytes(_ bytes: inout MutableSpan<UInt8>, at offset: Int, count: Int) {
    precondition(count >= 0 && offset >= 0 && count <= bytes.count &- offset)
    withMutableSubspan(of: &bytes, offset..<(offset &+ count)) { subspan in
        subspan.update(repeating: 0)
    }
}

// CARingBuffer's constructor. Traps if the capacity overflows, as the C++'s CheckedSize does.
@_expose(Cxx)
func caRingBufferMakeGeometry(_ bytesPerFrame: UInt64, _ frameCount: UInt64, _ channelCount: UInt32)
    -> WebCore.CARingBufferGeometry
{
    let (capacity, overflow) = UInt(truncatingIfNeeded: bytesPerFrame).multipliedReportingOverflow(
        by: UInt(truncatingIfNeeded: frameCount)
    )
    precondition(!overflow)
    var geometry = WebCore.CARingBufferGeometry()
    geometry.bytesPerFrame = bytesPerFrame
    geometry.capacityBytes = UInt64(capacity)
    geometry.channelCount = channelCount
    geometry.frameCount = UInt32(truncatingIfNeeded: frameCount)
    return geometry
}

// The storage of a ring of at least frameCount frames, with headerSize bytes before the channels.
@_expose(Cxx)
func caRingBufferStorageSize(_ bytesPerFrame: UInt32, _ frameCount: UInt64, _ channelCount: UInt32, _ headerSize: UInt64)
    -> WebCore.CARingBufferStorageSize
{
    let frames = roundUpToPowerOfTwo(UInt(truncatingIfNeeded: frameCount))
    let (capacity, capacityOverflow) = UInt(bytesPerFrame).multipliedReportingOverflow(by: frames)
    let (channels, channelsOverflow) = capacity.multipliedReportingOverflow(by: UInt(channelCount))
    let (total, totalOverflow) = channels.addingReportingOverflow(UInt(truncatingIfNeeded: headerSize))
    var size = WebCore.CARingBufferStorageSize()
    size.frameCount = UInt64(frames)
    size.byteCount = UInt64(total)
    size.isValid = !capacityOverflow && !channelsOverflow && !totalOverflow
    return size
}

// The storage a shared ring's handle needs, for a handle that may come from another process: not valid if its frame
// count doesn't fit in a size_t, if the storage size overflows, or if the frame count, rounded up, doesn't fit in the
// 32 bits a ring keeps of it.
@_expose(Cxx)
func caRingBufferMappedStorageSize(_ bytesPerFrame: UInt32, _ frameCount: UInt64, _ channelCount: UInt32, _ headerSize: UInt64)
    -> WebCore.CARingBufferStorageSize
{
    guard let frames = UInt(exactly: frameCount) else {
        return WebCore.CARingBufferStorageSize()
    }
    var size = caRingBufferStorageSize(bytesPerFrame, UInt64(frames), channelCount, headerSize)
    if size.frameCount > UInt64(UInt32.max) {
        size.isValid = false
    }
    return size
}

// CARingBuffer::store(). False for CARingBuffer::TooMuch.
@_expose(Cxx)
func caRingBufferStore(
    _ ring: inout WebCore.CARingBufferWriteView,
    _ storeBounds: inout WebCore.CARingBufferBounds,
    _ source: borrowing WebCore.ConstAudioBufferListView,
    _ frameCount: UInt64,
    _ startFrame: UInt64,
    _ writeAhead: UInt64
) -> Bool {
    storeThroughIOViews(&ring, &storeBounds, source, frameCount, startFrame, writeAhead)
}

// CARingBuffer::getFetchTimeBounds(): the bounds a writer stored, limited to frameCount frames.
func fetchBounds(_ layout: RingLayout, _ storedBounds: WebCore.CARingBufferBounds) -> WebCore.CARingBufferBounds {
    var bounds = storedBounds
    let frameCount = UInt64(layout.frameCount)
    bounds.startFrame = audioMinimum(bounds.startFrame, UInt64.max &- frameCount)
    bounds.endFrame = clamp(bounds.endFrame, bounds.startFrame, bounds.startFrame &+ frameCount)
    return bounds
}

func caRingBufferFetchBounds(_ geometry: WebCore.CARingBufferGeometry, _ storedBounds: WebCore.CARingBufferBounds)
    -> WebCore.CARingBufferBounds
{
    fetchBounds(RingLayout(geometry), storedBounds)
}

// CARingBuffer::fetch() and fetchIfHasEnoughData(). Unless requireEnoughData, the frames the ring doesn't hold are zeroed
// and the result is true; with it, the result is false, and nothing is fetched, unless the ring holds all the frames.
@_expose(Cxx)
@discardableResult
func caRingBufferFetch(
    _ ring: borrowing WebCore.CARingBufferReadView,
    _ destination: inout WebCore.AudioBufferListView,
    _ frameCount: UInt64,
    _ startFrame: UInt64,
    _ mode: UInt32,
    _ requireEnoughData: Bool
) -> Bool {
    if requireEnoughData {
        return fetchIfHasEnoughData(ring, &destination, frameCount, startFrame, CARingBufferFetchMode(rawValue: mode))
    }
    let layout = RingLayout(ring.geometry())
    let channels: Span<UInt8> = ring.channels()
    fetchFrames(
        layout,
        channels,
        &destination,
        UInt(truncatingIfNeeded: frameCount),
        startFrame,
        CARingBufferFetchMode(rawValue: mode),
        fetchBounds(layout, loadRingBounds(ring.header()))
    )
    return true
}

@inline(__always)
func fetchIfHasEnoughData(
    _ ring: borrowing WebCore.CARingBufferReadView,
    _ destination: inout WebCore.AudioBufferListView,
    _ frameCount: UInt64,
    _ startFrame: UInt64,
    _ mode: CARingBufferFetchMode?
) -> Bool {
    let layout = RingLayout(ring.geometry())
    let bounds = fetchBounds(layout, loadRingBounds(ring.header()))
    if startFrame < bounds.startFrame || startFrame &+ frameCount > bounds.endFrame {
        return false
    }
    let channels: Span<UInt8> = ring.channels()
    fetchFrames(layout, channels, &destination, UInt(truncatingIfNeeded: frameCount), startFrame, mode, bounds)
    return true
}

@inline(__always)
private func fetchFrames(
    _ layout: RingLayout,
    _ channels: Span<UInt8>,
    _ destination: inout WebCore.AudioBufferListView,
    _ frameCount: UInt,
    _ startFrame: UInt64,
    _ mode: CARingBufferFetchMode?,
    _ bounds: WebCore.CARingBufferBounds
) {
    if frameCount == 0 {
        return
    }
    let endFrame = startFrame &+ UInt64(frameCount)
    let startRead = clamp(startFrame, bounds.startFrame, bounds.endFrame)
    let endRead = clamp(endFrame, bounds.startFrame, bounds.endFrame)
    let bytesPerFrame = layout.bytesPerFrame
    if startRead == endRead {
        zeroBuffers(&destination, 0, frameCount &* bytesPerFrame)
        return
    }

    let byteCount = UInt(truncatingIfNeeded: (endRead &- startRead) &* UInt64(bytesPerFrame))
    let destinationOffset = UInt(truncatingIfNeeded: (startRead &- startFrame) &* UInt64(bytesPerFrame))
    if destinationOffset > 0 {
        zeroBuffers(&destination, 0, min(frameCount &* bytesPerFrame, destinationOffset))
    }
    let framesAfterEnd = UInt(truncatingIfNeeded: endFrame &- endRead)
    if framesAfterEnd > 0 {
        zeroBuffers(&destination, destinationOffset &+ byteCount, framesAfterEnd &* bytesPerFrame)
    }

    let offset0 = layout.frameOffset(startRead)
    let offset1 = layout.frameOffset(endRead)
    if offset0 < offset1 {
        fetchBuffers(&destination, destinationOffset, channels, layout, offset0, offset1 &- offset0, mode, true)
    } else {
        let firstByteCount = layout.capacityBytes &- offset0
        fetchBuffers(&destination, destinationOffset, channels, layout, offset0, firstByteCount, mode, offset1 == 0)
        if offset1 != 0 {
            fetchBuffers(&destination, destinationOffset &+ firstByteCount, channels, layout, 0, offset1, mode, true)
        }
    }
}

// Zeroes byteCount bytes of each destination buffer from offset, as far as the buffer goes.
private func zeroBuffers(_ destination: inout WebCore.AudioBufferListView, _ offset: UInt, _ byteCount: UInt) {
    let bufferCount = destination.bufferCount()
    var index: UInt32 = 0
    while index < bufferCount {
        var bytes: MutableSpan<UInt8> = destination.mutableBytes(index)
        let size = UInt(bytes.count)
        if offset <= size {
            zeroAudioBytes(&bytes, at: Int(offset), count: Int(min(byteCount, size &- offset)))
        }
        index &+= 1
    }
}

// Copies or mixes byteCount bytes of each channel from sourceOffset into its destination buffer at destinationOffset, as
// far as the buffer goes.
private func fetchBuffers(
    _ destination: inout WebCore.AudioBufferListView,
    _ destinationOffset: UInt,
    _ channels: Span<UInt8>,
    _ layout: RingLayout,
    _ sourceOffset: UInt,
    _ byteCount: UInt,
    _ mode: CARingBufferFetchMode?,
    _ updateDataByteSize: Bool
) {
    assert(destination.bufferCount() == layout.channelCount)
    let bufferCount = min(destination.bufferCount(), layout.channelCount)
    var index: UInt32 = 0
    while index < bufferCount {
        if let count = fetchBuffer(&destination, index, destinationOffset, channels, layout, sourceOffset, byteCount, mode),
            updateDataByteSize
        {
            destination.setDataByteSize(index, UInt32(truncatingIfNeeded: destinationOffset &+ count))
        }
        index &+= 1
    }
}

// The samples in byteCount bytes, for a mix into destination at destinationOffset from source at sourceOffset. Traps unless
// the bytes from each offset to the end of its span are a whole number of samples, as the C++'s spanReinterpretCast()
// does.
@inline(__always)
private func mixSampleCount(
    _ source: borrowing Span<UInt8>,
    _ sourceOffset: Int,
    _ destination: borrowing MutableSpan<UInt8>,
    _ destinationOffset: Int,
    _ byteCount: Int,
    _ sampleSize: Int
) -> Int {
    precondition(
        (source.count &- sourceOffset) % sampleSize == 0 && (destination.count &- destinationOffset) % sampleSize == 0
    )
    return byteCount / sampleSize
}

// The bytes it fetched into the buffer, or nil if the buffer ends before destinationOffset.
@inline(__always)
private func fetchBuffer(
    _ destination: inout WebCore.AudioBufferListView,
    _ index: UInt32,
    _ destinationOffset: UInt,
    _ channels: Span<UInt8>,
    _ layout: RingLayout,
    _ sourceOffset: UInt,
    _ byteCount: UInt,
    _ mode: CARingBufferFetchMode?
) -> UInt? {
    var bytes: MutableSpan<UInt8> = destination.mutableBytes(index)
    let size = UInt(bytes.count)
    if destinationOffset > size {
        return nil
    }
    let channel = channels.extracting(layout.channelRange(UInt(index)))
    precondition(sourceOffset <= UInt(channel.count))
    let count = min(byteCount, size &- destinationOffset)
    let at = Int(destinationOffset)
    let from = Int(sourceOffset)
    let length = Int(count)
    switch mode {
    case .copy:
        copyBytes(from: channel, at: from, to: &bytes, at: at, count: length)
    case .mixInt16:
        mixInt16Samples(channel, from, &bytes, at, mixSampleCount(channel, from, bytes, at, length, 2))
    case .mixInt32:
        mixInt32Samples(channel, from, &bytes, at, mixSampleCount(channel, from, bytes, at, length, 4))
    case .mixFloat32:
        WebCore.mixFloatingPointSamples(&bytes, at, channel, from, mixSampleCount(channel, from, bytes, at, length, 4), false)
    case .mixFloat64:
        WebCore.mixFloatingPointSamples(&bytes, at, channel, from, mixSampleCount(channel, from, bytes, at, length, 8), true)
    case nil:
        break
    }
    return count
}

#endif // ENABLE_WEBCORE_SWIFT
