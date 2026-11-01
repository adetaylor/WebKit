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

private func sampleCount(_ bytes: borrowing MutableSpan<UInt8>) -> Int {
    bytes.count / 4
}

private func loadSample(_ bytes: inout MutableSpan<UInt8>, _ index: Int) -> Float {
    Float(bitPattern: bytes.mutableBytes.load(fromByteOffset: index &* 4, as: UInt32.self))
}

private func storeSample(_ bytes: inout MutableSpan<UInt8>, _ index: Int, _ value: Float) {
    var raw = bytes.mutableBytes
    raw.storeBytes(of: value.bitPattern, toByteOffset: index &* 4, as: UInt32.self)
}

// RemoteAudioDestination::render(), after its check for a ring: fetches frameCount frames from startFrame and advances
// it, remembering each channel's last sample, or on an underrun fades the output from those samples to silence rather
// than leave stale samples in it. Returns whether it fetched.
@_expose(Cxx)
func caRingBufferRenderForAudioDestination(
    _ ring: borrowing WebCore.CARingBufferReadView,
    _ startFrame: inout UInt64,
    _ output: inout WebCore.AudioBufferListView,
    _ lastRenderedSamples: inout WebCore.FloatSamplesView,
    _ frameCount: UInt32
) -> Bool {
    var last: MutableSpan<Float> = lastRenderedSamples.mutableSamples()
    if fetchIfHasEnoughData(ring, &output, UInt64(frameCount), startFrame, .copy) {
        startFrame &+= UInt64(frameCount)
        rememberLastRenderedSamples(&output, Int(frameCount), &last)
        return true
    }
    fadeOutToSilence(&output, Int(frameCount), &last)
    return false
}

@inline(__always)
private func rememberLastRenderedSamples(_ output: inout WebCore.AudioBufferListView, _ frameCount: Int, _ last: inout MutableSpan<Float>) {
    if frameCount == 0 {
        return
    }
    let bufferCount = Int(output.bufferCount())
    var channel = 0
    while channel < last.count && channel < bufferCount {
        var samples: MutableSpan<UInt8> = output.mutableBytes(UInt32(channel))
        let count = min(frameCount, sampleCount(samples))
        last[channel] = count != 0 ? loadSample(&samples, count &- 1) : 0
        channel &+= 1
    }
}

private func fadeOutToSilence(_ output: inout WebCore.AudioBufferListView, _ frameCount: Int, _ last: inout MutableSpan<Float>) {
    let bufferCount = output.bufferCount()
    var channel: UInt32 = 0
    while channel < bufferCount {
        var samples: MutableSpan<UInt8> = output.mutableBytes(channel)
        let total = sampleCount(samples)
        let count = min(frameCount, total)
        let startSample: Float = Int(channel) < last.count ? last[Int(channel)] : 0
        var frame = 0
        if startSample != 0 && count != 0 {
            // A linear ramp from the last rendered sample down to zero, to declick.
            let step = startSample / Float(count)
            var value = startSample
            while frame < count {
                value -= step
                storeSample(&samples, frame, value)
                frame &+= 1
            }
        }
        zeroAudioBytes(&samples, at: frame &* 4, count: (total &- frame) &* 4)
        channel &+= 1
    }
    // Silent now, so a following underrun outputs pure silence.
    last.update(repeating: 0)
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
