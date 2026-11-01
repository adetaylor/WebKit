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

private struct RingLayout {
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

private func makeBounds(_ startFrame: UInt64, _ endFrame: UInt64, _ writeAhead: UInt64 = 0) -> WebCore.CARingBufferBounds {
    var bounds = WebCore.CARingBufferBounds()
    bounds.startFrame = startFrame
    bounds.endFrame = endFrame
    bounds.writeAhead = writeAhead
    return bounds
}

// std::clamp().
private func clamp(_ value: UInt64, _ low: UInt64, _ high: UInt64) -> UInt64 {
    value < low ? low : (high < value ? high : value)
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

private func setBounds(
    _ storeBounds: inout WebCore.CARingBufferBounds,
    _ ring: inout WebCore.CARingBufferWriteView,
    _ bounds: WebCore.CARingBufferBounds
) {
    ring.storeBounds(bounds)
    storeBounds = bounds
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
    if frameCount == 0 {
        return true
    }
    let layout = RingLayout(ring.geometry())
    if frameCount > UInt64(layout.frameCount) {
        return false
    }

    let endFrame = startFrame &+ frameCount
    if startFrame < storeBounds.startFrame {
        // Throw everything out when going backwards.
        setBounds(&storeBounds, &ring, makeBounds(startFrame, startFrame))
    } else if endFrame &- storeBounds.startFrame > UInt64(layout.frameCount) {
        // Advance the start past the frames about to be overwritten, one buffer of time behind where this writes.
        let newStartFrame = endFrame &- UInt64(layout.frameCount)
        setBounds(&storeBounds, &ring, makeBounds(newStartFrame, max(newStartFrame, storeBounds.endFrame)))
    }

    storeFrames(layout, &ring, storeBounds.endFrame, source, startFrame, endFrame)

    setBounds(&storeBounds, &ring, makeBounds(storeBounds.startFrame, endFrame, writeAhead))
    return true
}

// Out of line: the store entry then saves fewer registers, which measured about 1% faster for small stores.
@inline(never)
private func storeFrames(
    _ layout: RingLayout,
    _ ring: inout WebCore.CARingBufferWriteView,
    _ storedEndFrame: UInt64,
    _ source: borrowing WebCore.ConstAudioBufferListView,
    _ startFrame: UInt64,
    _ endFrame: UInt64
) {
    var channels: MutableSpan<UInt8> = ring.mutableChannels()
    var offset0: UInt
    if startFrame > storedEndFrame {
        // Zero the frames this skips.
        offset0 = layout.frameOffset(storedEndFrame)
        let offset1 = layout.frameOffset(startFrame)
        if offset0 < offset1 {
            zeroChannels(&channels, layout, offset0, offset1 &- offset0)
        } else {
            zeroChannels(&channels, layout, offset0, layout.capacityBytes &- offset0)
            zeroChannels(&channels, layout, 0, offset1)
        }
        offset0 = offset1
    } else {
        offset0 = layout.frameOffset(startFrame)
    }

    let offset1 = layout.frameOffset(endFrame)
    if offset0 < offset1 {
        storeChannels(&channels, layout, offset0, source, 0, offset1 &- offset0)
    } else {
        let byteCount = layout.capacityBytes &- offset0
        storeChannels(&channels, layout, offset0, source, 0, byteCount)
        storeChannels(&channels, layout, 0, source, byteCount, offset1)
    }
}

private func zeroChannels(_ channels: inout MutableSpan<UInt8>, _ layout: RingLayout, _ offset: UInt, _ byteCount: UInt) {
    // Each channel's range, as the C++'s subspan() checks it.
    precondition(layout.channelCount == 0 || (offset <= layout.capacityBytes && byteCount <= layout.capacityBytes &- offset))
    // Where the channels are in the span is checked when they are zeroed.
    var start = Int(truncatingIfNeeded: offset)
    var channel: UInt32 = 0
    while channel < layout.channelCount {
        zeroAudioBytes(&channels, at: start, count: Int(byteCount))
        start &+= Int(truncatingIfNeeded: layout.capacityBytes)
        channel &+= 1
    }
}

// Copies byteCount bytes of each source buffer from sourceOffset to its channel at offset. The part of that range that
// the buffer doesn't cover, all of it for a channel without a buffer, is zeroed.
private func storeChannels(
    _ channels: inout MutableSpan<UInt8>,
    _ layout: RingLayout,
    _ offset: UInt,
    _ source: borrowing WebCore.ConstAudioBufferListView,
    _ sourceOffset: UInt,
    _ byteCount: UInt
) {
    precondition(layout.channelCount == 0 || (offset <= layout.capacityBytes && byteCount <= layout.capacityBytes &- offset))
    let bufferCount = source.bufferCount()
    assert(bufferCount == layout.channelCount)
    // Where the channels are in the span is checked when they are written.
    var start = Int(truncatingIfNeeded: offset)
    var channel: UInt32 = 0
    while channel < layout.channelCount {
        var copied: UInt = 0
        if channel < bufferCount {
            let bytes: Span<UInt8> = source.bytes(channel)
            let available = UInt(bytes.count)
            if sourceOffset <= available {
                copied = min(byteCount, available &- sourceOffset)
                copyBytes(from: bytes, at: Int(sourceOffset), to: &channels, at: start, count: Int(copied))
            }
        }
        zeroAudioBytes(&channels, at: start &+ Int(copied), count: Int(byteCount &- copied))
        start &+= Int(truncatingIfNeeded: layout.capacityBytes)
        channel &+= 1
    }
}

// CARingBuffer::getFetchTimeBounds(): the bounds a writer stored, limited to frameCount frames.
private func fetchBounds(_ layout: RingLayout, _ storedBounds: WebCore.CARingBufferBounds) -> WebCore.CARingBufferBounds {
    var bounds = storedBounds
    let frameCount = UInt64(layout.frameCount)
    bounds.startFrame = min(bounds.startFrame, UInt64.max &- frameCount)
    bounds.endFrame = clamp(bounds.endFrame, bounds.startFrame, bounds.startFrame &+ frameCount)
    return bounds
}

@_expose(Cxx)
func caRingBufferFetchTimeBounds(_ geometry: WebCore.CARingBufferGeometry, _ storedBounds: WebCore.CARingBufferBounds)
    -> WebCore.CARingBufferBounds
{
    fetchBounds(RingLayout(geometry), storedBounds)
}

// CARingBuffer::fetch(): the frames the ring doesn't hold are zeroed.
@_expose(Cxx)
func caRingBufferFetch(
    _ ring: borrowing WebCore.CARingBufferReadView,
    _ destination: inout WebCore.AudioBufferListView,
    _ frameCount: UInt64,
    _ startFrame: UInt64,
    _ mode: UInt32
) {
    let layout = RingLayout(ring.geometry())
    let channels: Span<UInt8> = ring.channels()
    fetchFrames(
        layout,
        channels,
        &destination,
        UInt(truncatingIfNeeded: frameCount),
        startFrame,
        CARingBufferFetchMode(rawValue: mode),
        fetchBounds(layout, ring.storedBounds())
    )
}

// CARingBuffer::fetchIfHasEnoughData(): false, and nothing fetched, unless the ring holds all the frames.
@_expose(Cxx)
func caRingBufferFetchIfHasEnoughData(
    _ ring: borrowing WebCore.CARingBufferReadView,
    _ destination: inout WebCore.AudioBufferListView,
    _ frameCount: UInt64,
    _ startFrame: UInt64,
    _ mode: UInt32
) -> Bool {
    fetchIfHasEnoughData(ring, &destination, frameCount, startFrame, CARingBufferFetchMode(rawValue: mode))
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
    let bounds = fetchBounds(layout, ring.storedBounds())
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
        mixInt16Samples(channel, from, &bytes, at, length)
    case .mixInt32:
        mixInt32Samples(channel, from, &bytes, at, length)
    case .mixFloat32:
        WebCore.mixFloat32Samples(&bytes, at, channel, from, length)
    case .mixFloat64:
        WebCore.mixFloat64Samples(&bytes, at, channel, from, length)
    case nil:
        break
    }
    return count
}

#endif // ENABLE_WEBCORE_SWIFT
