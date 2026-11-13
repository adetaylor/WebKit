// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2017 Apple Inc. All rights reserved.
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

#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif
private import Cxx
import WebCore_Private.Core.CARingBufferSwiftBridge

// AudioSampleBufferList's kernels. The integer arithmetic is the C++'s as compiled for arm64 (Arm64Truncating.swift):
// a float-to-integer conversion saturates to 32 bits, gives 0 for a NaN, and a 16-bit result keeps the low 16 bits of
// that. The floating-point gains stay vDSP's, in the C++, and the floating-point mixes are C++ calls of vDSP
// (CARingBufferSwiftBridge.h), so vDSP still decides which NaN they give.

// AudioStreamDescription::PCMFormat.
enum AudioStreamPCMFormat: UInt32 {
    case noFormat
    case uint8
    case int16
    case int24
    case int32
    case float32
    case float64
}

private func applyInt16Gain(_ bytes: inout MutableSpan<UInt8>, _ gain: Float) {
    var raw = bytes.mutableBytes
    let end = raw.byteCount & ~1
    var i = 0
    #if arch(arm64)
    // Eight samples at a time. The vector FCVTZS saturates and gives 0 for a NaN, as the scalar conversion does.
    let vectorEnd = end & ~15
    while i < vectorEnd {
        let samples = raw.load(fromByteOffset: i, as: SIMD8<Int16>.self)
        let low = vcvtq_s32_f32(vmulq_n_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(samples))), gain))
        let high = vcvtq_s32_f32(vmulq_n_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(samples))), gain))
        raw.storeBytes(of: vcombine_s16(vmovn_s32(low), vmovn_s32(high)), toByteOffset: i, as: SIMD8<Int16>.self)
        i &+= 16
    }
    #endif
    while i < end {
        let value = Int32(arm64Truncating: Float(raw.load(fromByteOffset: i, as: Int16.self)) * gain)
        raw.storeBytes(of: Int16(truncatingIfNeeded: value), toByteOffset: i, as: Int16.self)
        i &+= 2
    }
}

private func applyInt32Gain(_ bytes: inout MutableSpan<UInt8>, _ gain: Float) {
    var raw = bytes.mutableBytes
    let end = raw.byteCount & ~3
    var i = 0
    #if arch(arm64)
    let vectorEnd = end & ~15
    while i < vectorEnd {
        let samples = raw.load(fromByteOffset: i, as: SIMD4<Int32>.self)
        raw.storeBytes(of: vcvtq_s32_f32(vmulq_n_f32(vcvtq_f32_s32(samples), gain)), toByteOffset: i, as: SIMD4<Int32>.self)
        i &+= 16
    }
    #endif
    while i < end {
        let value = raw.load(fromByteOffset: i, as: Int32.self)
        raw.storeBytes(of: Int32(arm64Truncating: Float(value) * gain), toByteOffset: i, as: Int32.self)
        i &+= 4
    }
}

// AudioSampleBufferList::applyGain() for the integer formats: every whole sample of every buffer is multiplied by gain.
@_expose(Cxx)
func audioSampleBufferListApplyGain(_ list: inout WebCore.AudioBufferListView, _ gain: Float, _ format: UInt32) {
    let bufferCount = list.bufferCount()
    var index: UInt32 = 0
    while index < bufferCount {
        var bytes: MutableSpan<UInt8> = list.mutableBytes(index)
        switch AudioStreamPCMFormat(rawValue: format) {
        case .int16:
            applyInt16Gain(&bytes, gain)
        case .int32:
            applyInt32Gain(&bytes, gain)
        case .float32, .float64, .uint8, .int24, .noFormat:
            assertionFailure()
        case nil:
            break
        }
        index &+= 1
    }
}

// AudioSampleBufferList::mixBuffers(): adds frameCount samples of each source buffer to the destination buffer with the
// same index, for as many buffers as both lists have. Traps unless every buffer holds frameCount whole samples.
@_expose(Cxx)
func audioSampleBufferListMixBuffers(
    _ destination: inout WebCore.AudioBufferListView,
    _ source: borrowing WebCore.ConstAudioBufferListView,
    _ format: UInt32,
    _ frameCount: UInt64
) {
    let bufferCount = min(source.bufferCount(), destination.bufferCount())
    // A count past Int.max becomes negative, which the checks below reject, as the C++'s first() does.
    let frames = Int(truncatingIfNeeded: frameCount)
    var index: UInt32 = 0
    while index < bufferCount {
        let sourceBytes: Span<UInt8> = source.bytes(index)
        var destinationBytes: MutableSpan<UInt8> = destination.mutableBytes(index)
        switch AudioStreamPCMFormat(rawValue: format) {
        case .int16:
            mixInt16Samples(sourceBytes, 0, &destinationBytes, 0, frames)
        case .int32:
            mixInt32Samples(sourceBytes, 0, &destinationBytes, 0, frames)
        case .float32:
            precondition(frames >= 0 && frames <= sourceBytes.count / 4 && frames <= destinationBytes.count / 4)
            WebCore.mixFloatingPointSamples(&destinationBytes, 0, sourceBytes, 0, frames, false)
        case .float64:
            precondition(frames >= 0 && frames <= sourceBytes.count / 8 && frames <= destinationBytes.count / 8)
            WebCore.mixFloatingPointSamples(&destinationBytes, 0, sourceBytes, 0, frames, true)
        case .uint8, .int24, .noFormat:
            assertionFailure()
        case nil:
            break
        }
        index &+= 1
    }
}

// AudioSampleBufferList::zeroABL(): zeroes the first byteCount bytes of every buffer. Traps unless each holds that many.
@_expose(Cxx)
func audioSampleBufferListZero(_ list: inout WebCore.AudioBufferListView, _ byteCount: UInt64) {
    let bufferCount = list.bufferCount()
    var index: UInt32 = 0
    while index < bufferCount {
        var bytes: MutableSpan<UInt8> = list.mutableBytes(index)
        precondition(byteCount <= UInt64(bytes.count))
        zeroAudioBytes(&bytes, at: 0, count: Int(byteCount))
        index &+= 1
    }
}

#endif // ENABLE_WEBCORE_SWIFT
