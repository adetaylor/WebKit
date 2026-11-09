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

// RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit::render(), up to its zeroing of the output on an underrun:
// fetches sampleCount frames from readOffset and advances it, and counts the chunks of frameChunkSize frames to ask the
// web process for.
@_expose(Cxx)
func caRingBufferRenderForTrackRenderer(
    _ ring: borrowing WebCore.CARingBufferReadView,
    _ readOffset: inout UInt64,
    _ generateOffset: inout UInt64,
    _ output: inout WebCore.AudioBufferListView,
    _ sampleCount: UInt64,
    _ frameChunkSize: UInt64
) -> WebCore.CARingBufferTrackRenderResult {
    var result = WebCore.CARingBufferTrackRenderResult()
    if fetchIfHasEnoughData(ring, &output, sampleCount, readOffset, .copy) {
        readOffset &+= sampleCount
        result.fetched = true
    }
    var requestedSampleCount = generateOffset
    while requestedSampleCount < sampleCount {
        requestedSampleCount &+= frameChunkSize
        result.signalCount &+= 1
    }
    generateOffset = requestedSampleCount &- sampleCount
    return result
}

#endif // ENABLE_WEBCORE_SWIFT
