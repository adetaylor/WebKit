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
import WebCore_Private.Core.CARingBufferSwiftBridge

// The render quanta of the GPU process's audio destination (RemoteAudioDestination) and track renderer units
// (RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit), which play out rings the web process writes. Their
// output buffers are deinterleaved Float32, one per channel. Samples are moved as bit patterns, so NaNs keep theirs.

// RemoteAudioDestination::render(), after its check for a ring, on the destination unit's IO thread
// (AudioUnitIsland.swift): fetches frameCount frames from startFrame and advances it, remembering each channel's last
// sample, or on an underrun fades the output from those samples to silence rather than leave stale samples in it. Returns
// whether it fetched. Like the rest of the IO path, it needs no Swift runtime, even at -Onone.
func renderRemoteDestinationQuantum(
    _ geometry: WebCore.CARingBufferGeometry,
    _ storedBounds: WebCore.CARingBufferBounds,
    _ channels: borrowing IOConstBytes,
    _ output: inout IOBufferList,
    _ lastRenderedSamples: inout IOBytes,
    _ startFrame: inout UInt64,
    _ frameCount: UInt32
) -> Bool {
    if fetchIfHasEnoughData(geometry, storedBounds, channels, &output, UInt64(frameCount), startFrame) {
        startFrame &+= UInt64(frameCount)
        rememberLastRenderedSamples(&output, Int(frameCount), &lastRenderedSamples)
        return true
    }
    fadeOutToSilence(&output, Int(frameCount), &lastRenderedSamples)
    return false
}

// CARingBuffer::fetchIfHasEnoughData() in Copy mode, into the buffers of a render callback.
private func fetchIfHasEnoughData(
    _ geometry: WebCore.CARingBufferGeometry,
    _ storedBounds: WebCore.CARingBufferBounds,
    _ channels: borrowing IOConstBytes,
    _ output: inout IOBufferList,
    _ frameCount: UInt64,
    _ startFrame: UInt64
) -> Bool {
    let layout = RingLayout(geometry)
    let bounds = fetchBounds(layout, storedBounds)
    if startFrame < bounds.startFrame || startFrame &+ frameCount > bounds.endFrame {
        return false
    }
    if frameCount == 0 {
        return true
    }
    // The ring holds every frame, so nothing is zeroed.
    let offset0 = layout.frameOffset(startFrame)
    let offset1 = layout.frameOffset(startFrame &+ frameCount)
    if offset0 < offset1 {
        copyChannels(&output, 0, channels, layout, offset0, offset1 &- offset0, true)
    } else {
        let firstByteCount = layout.capacityBytes &- offset0
        copyChannels(&output, 0, channels, layout, offset0, firstByteCount, offset1 == 0)
        if offset1 != 0 {
            copyChannels(&output, firstByteCount, channels, layout, 0, offset1, true)
        }
    }
    return true
}

// Copies byteCount bytes of each channel from sourceOffset into its output buffer at destinationOffset, as far as the
// buffer goes, as CARingBuffer.swift's fetchBuffers() does in Copy mode.
private func copyChannels(
    _ output: inout IOBufferList,
    _ destinationOffset: UInt,
    _ channels: borrowing IOConstBytes,
    _ layout: RingLayout,
    _ sourceOffset: UInt,
    _ byteCount: UInt,
    _ updateDataByteSize: Bool
) {
    let bufferCount = output.bufferCount
    assert(bufferCount == Int(layout.channelCount))
    let count = bufferCount < Int(layout.channelCount) ? bufferCount : Int(layout.channelCount)
    var index = 0
    while index < count {
        var copied: UInt? = nil
        do {
            var bytes = output.bytes(index)
            let size = UInt(bytes.count)
            if destinationOffset <= size {
                // The channel's bytes, as CARingBuffer.swift's channelRange() and its checks bound them.
                let channelStart = UInt(index) &* layout.capacityBytes
                precondition(channelStart <= UInt(channels.count) && layout.capacityBytes <= UInt(channels.count) &- channelStart)
                precondition(sourceOffset <= layout.capacityBytes)
                let length = audioMinimum(byteCount, size &- destinationOffset)
                precondition(length <= layout.capacityBytes &- sourceOffset)
                bytes.copy(from: channels, at: Int(channelStart &+ sourceOffset), to: Int(destinationOffset), count: Int(length))
                copied = length
            }
        }
        if let copied, updateDataByteSize {
            output.setDataByteSize(index, UInt32(truncatingIfNeeded: destinationOffset &+ copied))
        }
        index &+= 1
    }
}

private func rememberLastRenderedSamples(_ output: inout IOBufferList, _ frameCount: Int, _ last: inout IOBytes) {
    if frameCount == 0 {
        return
    }
    let bufferCount = output.bufferCount
    let lastCount = last.count / 4
    var channel = 0
    while channel < lastCount && channel < bufferCount {
        let samples = output.bytes(channel)
        let count = audioMinimum(frameCount, samples.count / 4)
        last.setSampleBits(count != 0 ? samples.sampleBits(at: count &- 1) : 0, at: channel)
        channel &+= 1
    }
}

private func fadeOutToSilence(_ output: inout IOBufferList, _ frameCount: Int, _ last: inout IOBytes) {
    let bufferCount = output.bufferCount
    let lastCount = last.count / 4
    var channel = 0
    while channel < bufferCount {
        var samples = output.bytes(channel)
        let total = samples.count / 4
        let count = audioMinimum(frameCount, total)
        let startSample: Float = channel < lastCount ? last.float(at: channel) : 0
        var frame = 0
        if startSample != 0 && count != 0 {
            // A linear ramp from the last rendered sample down to zero, to declick.
            let step = startSample / Float(count)
            var value = startSample
            while frame < count {
                value -= step
                samples.setFloat(value, at: frame)
                frame &+= 1
            }
        }
        samples.zero(at: frame &* 4, count: (total &- frame) &* 4)
        channel &+= 1
    }
    // Silent now, so a following underrun outputs pure silence.
    last.zero(at: 0, count: lastCount &* 4)
}

// RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit::render(), on a track renderer unit's IO thread or the capture
// unit's (AudioUnitIsland.swift): fetches sampleCount frames from readOffset and advances it, or on an underrun zeroes
// sampleCount frames of each buffer; and counts the chunks of frameChunkSize frames to ask the web process for, which the
// caller signals. Returns whether it fetched.
func renderTrackQuantum(
    _ geometry: WebCore.CARingBufferGeometry,
    _ storedBounds: WebCore.CARingBufferBounds,
    _ channels: borrowing IOConstBytes,
    _ output: inout IOBufferList,
    _ readOffset: inout UInt64,
    _ generateOffset: inout UInt64,
    _ signalCount: inout UInt64,
    _ sampleCount: UInt64,
    _ frameChunkSize: UInt64,
    _ bytesPerFrame: UInt64
) -> Bool {
    let fetched = fetchIfHasEnoughData(geometry, storedBounds, channels, &output, sampleCount, readOffset)
    if fetched {
        readOffset &+= sampleCount
    } else {
        zeroTrackOutput(&output, sampleCount &* bytesPerFrame)
    }
    var requestedSampleCount = generateOffset
    signalCount = 0
    while requestedSampleCount < sampleCount {
        requestedSampleCount &+= frameChunkSize
        signalCount &+= 1
    }
    generateOffset = requestedSampleCount &- sampleCount
    return fetched
}

// AudioSampleBufferList::zeroABL(), which traps unless every buffer holds the bytes.
func zeroTrackOutput(_ output: inout IOBufferList, _ byteCount: UInt64) {
    let bufferCount = output.bufferCount
    var index = 0
    while index < bufferCount {
        var bytes = output.bytes(index)
        precondition(byteCount <= UInt64(bytes.count))
        bytes.zero(at: 0, count: Int(byteCount))
        index &+= 1
    }
}

// MARK: Stores

// CARingBuffer::store(), in three steps that each caller runs with its own views of the ring and the source: the plan,
// with the bounds to publish before the write; each channel's write (storeRingChannel()); and the bounds to publish after.
// The capture unit's producer sink stores this way on its IO thread (AudioUnitIsland.swift), and so does the C++ store
// (CARingBuffer.swift's caRingBufferStore()).
struct RingStorePlan {
    let layout: RingLayout
    // Whether the store publishes boundsBefore before it writes: it goes backwards, or overwrites the oldest frames.
    let publishesBoundsBefore: Bool
    let boundsBefore: WebCore.CARingBufferBounds
    let boundsAfter: WebCore.CARingBufferBounds
    // The frames it skips, which it zeroes: zeroCount0 bytes from zeroOffset0, then zeroCount1 bytes from 0.
    let zeroOffset0: UInt
    let zeroCount0: UInt
    let zeroCount1: UInt
    // The frames it copies: copyCount0 bytes from copyOffset0, then copyCount1 bytes from 0, which come copyCount0 bytes
    // into each source buffer.
    let copyOffset0: UInt
    let copyCount0: UInt
    let copyCount1: UInt
}

private func ringBounds(_ startFrame: UInt64, _ endFrame: UInt64, _ writeAhead: UInt64) -> WebCore.CARingBufferBounds {
    var bounds = WebCore.CARingBufferBounds()
    bounds.startFrame = startFrame
    bounds.endFrame = endFrame
    bounds.writeAhead = writeAhead
    return bounds
}

// The plan of a store of frameCount frames from startFrame, or none: a store of no frames writes nothing, and one of more
// frames than the ring holds is CARingBuffer::TooMuch.
func planRingStore(
    _ geometry: WebCore.CARingBufferGeometry,
    _ storeBounds: WebCore.CARingBufferBounds,
    _ frameCount: UInt64,
    _ startFrame: UInt64,
    _ writeAhead: UInt64
) -> RingStorePlan? {
    let layout = RingLayout(geometry)
    if frameCount == 0 || frameCount > UInt64(layout.frameCount) {
        return nil
    }
    let endFrame = startFrame &+ frameCount
    var publishesBoundsBefore = false
    var bounds = storeBounds
    if startFrame < bounds.startFrame {
        // Throw everything out when going backwards.
        bounds = ringBounds(startFrame, startFrame, 0)
        publishesBoundsBefore = true
    } else if endFrame &- bounds.startFrame > UInt64(layout.frameCount) {
        // Advance the start past the frames about to be overwritten, one buffer of time behind where this writes.
        let newStartFrame = endFrame &- UInt64(layout.frameCount)
        bounds = ringBounds(newStartFrame, bounds.endFrame < newStartFrame ? newStartFrame : bounds.endFrame, 0)
        publishesBoundsBefore = true
    }

    var zeroOffset0: UInt = 0
    var zeroCount0: UInt = 0
    var zeroCount1: UInt = 0
    var offset0: UInt
    if startFrame > bounds.endFrame {
        // Zero the frames this skips.
        offset0 = layout.frameOffset(bounds.endFrame)
        let offset1 = layout.frameOffset(startFrame)
        zeroOffset0 = offset0
        if offset0 < offset1 {
            zeroCount0 = offset1 &- offset0
        } else {
            zeroCount0 = layout.capacityBytes &- offset0
            zeroCount1 = offset1
        }
        offset0 = offset1
    } else {
        offset0 = layout.frameOffset(startFrame)
    }
    let offset1 = layout.frameOffset(endFrame)
    let copyCount0 = offset0 < offset1 ? offset1 &- offset0 : layout.capacityBytes &- offset0
    let copyCount1 = offset0 < offset1 ? 0 : offset1
    // Each channel's ranges, as the C++'s subspan() checks them.
    if layout.channelCount != 0 {
        precondition(zeroOffset0 <= layout.capacityBytes && zeroCount0 <= layout.capacityBytes &- zeroOffset0)
        precondition(zeroCount1 <= layout.capacityBytes)
        precondition(offset0 <= layout.capacityBytes && copyCount0 <= layout.capacityBytes &- offset0)
        precondition(copyCount1 <= layout.capacityBytes)
    }
    return RingStorePlan(
        layout: layout,
        publishesBoundsBefore: publishesBoundsBefore,
        boundsBefore: bounds,
        boundsAfter: ringBounds(bounds.startFrame, endFrame, writeAhead),
        zeroOffset0: zeroOffset0,
        zeroCount0: zeroCount0,
        zeroCount1: zeroCount1,
        copyOffset0: offset0,
        copyCount0: copyCount0,
        copyCount1: copyCount1
    )
}

// One channel's write of a store: zeroes the frames it skips, then copies the source buffer's bytes, zeroing what the
// buffer doesn't cover. Where the channel's bytes are among all the channels' bytes is checked as they are written.
func storeRingChannel(_ plan: RingStorePlan, _ channels: inout IOBytes, _ channel: UInt32, _ source: borrowing IOConstBytes) {
    let channelStart = zeroSkippedRingFrames(plan, &channels, channel)
    storeRingBytes(&channels, channelStart &+ Int(truncatingIfNeeded: plan.copyOffset0), source, 0, plan.copyCount0)
    storeRingBytes(&channels, channelStart, source, plan.copyCount0, plan.copyCount1)
}

// The write of a channel without a source buffer, which zeroes its frames.
func zeroRingChannel(_ plan: RingStorePlan, _ channels: inout IOBytes, _ channel: UInt32) {
    let channelStart = zeroSkippedRingFrames(plan, &channels, channel)
    channels.zero(at: channelStart &+ Int(truncatingIfNeeded: plan.copyOffset0), count: Int(plan.copyCount0))
    channels.zero(at: channelStart, count: Int(plan.copyCount1))
}

private func zeroSkippedRingFrames(_ plan: RingStorePlan, _ channels: inout IOBytes, _ channel: UInt32) -> Int {
    let channelStart = Int(truncatingIfNeeded: UInt(channel) &* plan.layout.capacityBytes)
    channels.zero(at: channelStart &+ Int(truncatingIfNeeded: plan.zeroOffset0), count: Int(plan.zeroCount0))
    channels.zero(at: channelStart, count: Int(plan.zeroCount1))
    return channelStart
}

private func storeRingBytes(_ channels: inout IOBytes, _ start: Int, _ source: borrowing IOConstBytes, _ sourceOffset: UInt, _ byteCount: UInt) {
    var copied: UInt = 0
    let available = UInt(source.count)
    if sourceOffset <= available {
        copied = audioMinimum(byteCount, available &- sourceOffset)
        channels.copy(from: source, at: Int(sourceOffset), to: start, count: Int(copied))
    }
    channels.zero(at: start &+ Int(copied), count: Int(byteCount &- copied))
}

// The capture unit's producer sink (AudioUnitIsland.swift): stores frameCount frames of each source buffer from
// startFrame into the ring, as CARingBuffer::store() does. False for CARingBuffer::TooMuch.
func storeRingQuantum(
    _ geometry: WebCore.CARingBufferGeometry,
    _ header: inout IORingHeader,
    _ channels: inout IOBytes,
    _ storeBounds: inout WebCore.CARingBufferBounds,
    _ sources: borrowing IOSourceBuffers,
    _ frameCount: UInt64,
    _ startFrame: UInt64
) -> Bool {
    guard let plan = planRingStore(geometry, storeBounds, frameCount, startFrame, 0) else {
        return frameCount == 0
    }
    assert(sources.count == Int(plan.layout.channelCount))
    if plan.publishesBoundsBefore {
        header.store(plan.boundsBefore)
        storeBounds = plan.boundsBefore
    }
    var channel: UInt32 = 0
    while channel < plan.layout.channelCount {
        if Int(channel) < sources.count {
            storeRingChannel(plan, &channels, channel, sources.bytes(Int(channel)))
        } else {
            zeroRingChannel(plan, &channels, channel)
        }
        channel &+= 1
    }
    header.store(plan.boundsAfter)
    storeBounds = plan.boundsAfter
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
