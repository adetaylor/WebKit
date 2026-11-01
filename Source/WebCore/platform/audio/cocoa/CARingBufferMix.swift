// Copyright (C) 2010 Google Inc. All rights reserved.
// Copyright (C) 2020 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1.  Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
// ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
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

// The integer mixes of CARingBuffer's fetch: each adds the byteCount / sample size samples of source at sourceOffset to
// those of destination at destinationOffset, wrapping. Each traps unless the bytes from each offset to the end of its
// span are a whole number of samples, as the C++'s spanReinterpretCast() does, and unless both ranges are inside their
// spans. (The floating-point mixes are C++, CARingBufferSwiftBridge.h.)
//
// Samples need not be aligned. Each loop moves 64-byte SIMD vectors, then single samples. The kernels stay out of line, which
// keeps the copy path that calls them small.

@inline(__always)
private func checkMixRanges(
    _ source: borrowing RawSpan,
    _ sourceOffset: Int,
    _ destination: borrowing MutableRawSpan,
    _ destinationOffset: Int,
    _ byteCount: Int,
    _ sampleSize: Int
) {
    // Every operand is non-negative before the subtractions, so they can't overflow.
    precondition(
        sourceOffset >= 0 && destinationOffset >= 0 && byteCount >= 0 && sourceOffset <= source.byteCount
            && destinationOffset <= destination.byteCount
            && (source.byteCount &- sourceOffset) % sampleSize == 0
            && (destination.byteCount &- destinationOffset) % sampleSize == 0
            && byteCount <= source.byteCount &- sourceOffset && byteCount <= destination.byteCount &- destinationOffset
    )
}

@inline(never)
func mixInt16Samples(
    _ source: Span<UInt8>,
    _ sourceOffset: Int,
    _ destination: inout MutableSpan<UInt8>,
    _ destinationOffset: Int,
    _ byteCount: Int
) {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    checkMixRanges(sourceBytes, sourceOffset, destinationBytes, destinationOffset, byteCount, 2)
    let end = byteCount & ~1
    let vectorEnd = byteCount & ~63
    var i = 0
    while i < vectorEnd {
        let s = sourceBytes.load(fromByteOffset: sourceOffset &+ i, as: SIMD32<Int16>.self)
        let d = destinationBytes.load(fromByteOffset: destinationOffset &+ i, as: SIMD32<Int16>.self)
        destinationBytes.storeBytes(of: d &+ s, toByteOffset: destinationOffset &+ i, as: SIMD32<Int16>.self)
        i &+= 64
    }
    while i < end {
        let s = sourceBytes.load(fromByteOffset: sourceOffset &+ i, as: Int16.self)
        let d = destinationBytes.load(fromByteOffset: destinationOffset &+ i, as: Int16.self)
        destinationBytes.storeBytes(of: d &+ s, toByteOffset: destinationOffset &+ i, as: Int16.self)
        i &+= 2
    }
}

@inline(never)
func mixInt32Samples(
    _ source: Span<UInt8>,
    _ sourceOffset: Int,
    _ destination: inout MutableSpan<UInt8>,
    _ destinationOffset: Int,
    _ byteCount: Int
) {
    let sourceBytes = source.bytes
    var destinationBytes = destination.mutableBytes
    checkMixRanges(sourceBytes, sourceOffset, destinationBytes, destinationOffset, byteCount, 4)
    let end = byteCount & ~3
    let vectorEnd = byteCount & ~63
    var i = 0
    while i < vectorEnd {
        let s = sourceBytes.load(fromByteOffset: sourceOffset &+ i, as: SIMD16<Int32>.self)
        let d = destinationBytes.load(fromByteOffset: destinationOffset &+ i, as: SIMD16<Int32>.self)
        destinationBytes.storeBytes(of: d &+ s, toByteOffset: destinationOffset &+ i, as: SIMD16<Int32>.self)
        i &+= 64
    }
    while i < end {
        let s = sourceBytes.load(fromByteOffset: sourceOffset &+ i, as: Int32.self)
        let d = destinationBytes.load(fromByteOffset: destinationOffset &+ i, as: Int32.self)
        destinationBytes.storeBytes(of: d &+ s, toByteOffset: destinationOffset &+ i, as: Int32.self)
        i &+= 4
    }
}

#endif // ENABLE_WEBCORE_SWIFT
