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

import CoreAudioTypes
import WebCore_Private.Core.CARingBufferSwiftBridge

// CAAudioStreamDescription's constructor from a sample rate, a channel count, a format and an interleaving: a packed,
// native-endian linear PCM description with one frame per packet. A format that isn't PCM gives a word size of 0.
@_expose(Cxx)
func caAudioStreamDescriptionMake(_ sampleRate: Double, _ channelCount: UInt32, _ format: UInt32, _ isInterleaved: Bool)
    -> AudioStreamBasicDescription
{
    var flags: AudioFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
    var wordSize: UInt32 = 0
    switch AudioStreamPCMFormat(rawValue: format) {
    case .uint8:
        wordSize = 1
    case .int16:
        wordSize = 2
        flags |= kAudioFormatFlagIsSignedInteger
    case .int24:
        wordSize = 3
        flags |= kAudioFormatFlagIsSignedInteger
    case .int32:
        wordSize = 4
        flags |= kAudioFormatFlagIsSignedInteger
    case .float32:
        wordSize = 4
        flags |= kAudioFormatFlagIsFloat
    case .float64:
        wordSize = 8
        flags |= kAudioFormatFlagIsFloat
    case .noFormat, nil:
        assertionFailure()
    }
    var bytesPerFrame = wordSize
    if isInterleaved {
        bytesPerFrame = wordSize &* channelCount
    } else {
        flags |= kAudioFormatFlagIsNonInterleaved
    }
    return AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: wordSize &* 8,
        mReserved: 0
    )
}

// CAAudioStreamDescription::format(): the PCM format a description holds, or none if it isn't a packed, native-endian
// linear PCM format of whole-byte samples that WebCore knows.
@_expose(Cxx)
func caAudioStreamDescriptionFormat(_ description: AudioStreamBasicDescription) -> UInt32 {
    let none = AudioStreamPCMFormat.noFormat.rawValue
    guard description.mFormatID == kAudioFormatLinearPCM, description.mFramesPerPacket == 1,
        description.mBytesPerFrame == description.mBytesPerPacket, description.mChannelsPerFrame != 0,
        description.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
        description.mBitsPerChannel % 8 == 0
    else {
        return none
    }
    let bytesPerSample = description.mBitsPerChannel / 8
    let interleavedChannels =
        description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? description.mChannelsPerFrame : 1
    guard description.mBytesPerFrame % interleavedChannels == 0,
        description.mBytesPerFrame / interleavedChannels == bytesPerSample
    else {
        return none
    }
    let kind =
        description.mFormatFlags
        & (kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagsSampleFractionMask)
    let format: AudioStreamPCMFormat
    switch (kind, bytesPerSample) {
    case (kLinearPCMFormatFlagIsFloat, 4):
        format = .float32
    case (kLinearPCMFormatFlagIsFloat, 8):
        format = .float64
    case (kLinearPCMFormatFlagIsSignedInteger, 2):
        format = .int16
    case (kLinearPCMFormatFlagIsSignedInteger, 4):
        format = .int32
    case (kLinearPCMFormatFlagIsSignedInteger, 3):
        format = .int24
    case (kLinearPCMFormatFlagIsFloat, _), (kLinearPCMFormatFlagIsSignedInteger, _):
        format = .noFormat
    case (_, 1):
        format = .uint8
    default:
        format = .noFormat
    }
    return format.rawValue
}

// The buffers of a WebAudioBufferList: bytesPerBuffer for each of channelStreams buffers of sampleCount frames, in one flat
// buffer of flatBufferSize bytes. Not valid if a size overflows a size_t.
@_expose(Cxx)
func webAudioBufferListSizes(
    _ interleavedChannels: UInt32,
    _ bytesPerFrame: UInt32,
    _ channelStreams: UInt32,
    _ sampleCount: UInt64
) -> WebCore.WebAudioBufferListSizes {
    var sizes = WebCore.WebAudioBufferListSizes()
    let (totalSampleCount, totalOverflow) = UInt(truncatingIfNeeded: sampleCount).multipliedReportingOverflow(
        by: UInt(interleavedChannels)
    )
    let (bytesPerBuffer, bufferOverflow) = UInt(bytesPerFrame).multipliedReportingOverflow(by: totalSampleCount)
    let (flatBufferSize, flatOverflow) = UInt(channelStreams).multipliedReportingOverflow(by: bytesPerBuffer)
    guard !totalOverflow, !bufferOverflow, !flatOverflow else {
        return sizes
    }
    sizes.bytesPerBuffer = UInt64(bytesPerBuffer)
    sizes.flatBufferSize = UInt64(flatBufferSize)
    sizes.isValid = true
    return sizes
}

#endif // ENABLE_WEBCORE_SWIFT
