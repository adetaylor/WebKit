// Copyright (C) 2026 Apple Inc. All rights reserved.
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

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Internal.AnnexBUtilities
import WebCore_Internal.MediaParsersCxxBridging

// The NAL units of an Annex B stream, as findNaluIndices() finds them: a NAL unit starts at each 00 00 01 that begins
// before count - 3 (one byte earlier for 00 00 00 01), and its payload runs to the next one or to the end.
struct NaluIndexScanner: ~Escapable {
    private let buffer: Span<UInt8>
    private var position = 0
    // Found while sizing the previous payload.
    private var pendingStartCode: Int?

    @_lifetime(copy buffer)
    init(_ buffer: Span<UInt8>) {
        self.buffer = buffer
    }

    mutating func next() -> WebCore.NaluIndex? {
        if pendingStartCode == nil {
            pendingStartCode = nextStartCode()
        }
        guard let startCode = pendingStartCode else {
            return nil
        }
        let payloadStartOffset = startCode + 3
        var payloadEnd = buffer.count
        pendingStartCode = nextStartCode()
        if let pendingStartCode {
            payloadEnd = startOffset(ofStartCode: pendingStartCode)
        }
        var index = WebCore.NaluIndex()
        index.startOffset = startOffset(ofStartCode: startCode)
        index.payloadStartOffset = payloadStartOffset
        index.payloadSize = payloadEnd - payloadStartOffset
        return index
    }

    // findNaluIndices()'s scan: it skips three bytes whenever the third can't end a start code. Inside the loop,
    // position < count - 3, so the wrapping arithmetic never wraps; it only spares the overflow checks.
    private mutating func nextStartCode() -> Int? {
        let end = buffer.count - 3
        while position < end {
            let candidate = position
            let third = buffer[candidate &+ 2]
            if third > 1 {
                position = candidate &+ 3
            } else if third == 1 {
                position = candidate &+ 3
                if buffer[candidate &+ 1] == 0 && buffer[candidate] == 0 {
                    return candidate
                }
            } else {
                position = candidate &+ 1
            }
        }
        return nil
    }

    private func startOffset(ofStartCode startCode: Int) -> Int {
        startCode > 0 && buffer[startCode - 1] == 0 ? startCode - 1 : startCode
    }
}

@inline(__always)
func appendNaluIndices(of buffer: Span<UInt8>, to indices: inout WebCore.NaluIndexVector) {
    var scanner = NaluIndexScanner(buffer)
    while let index = scanner.next() {
        indices.append(consuming: index)
    }
}

// parseRbsp(): the bytes of `data` without its emulation prevention bytes (see RbspByteIterator), copied in runs.
func appendRbsp(of data: Span<UInt8>, to output: inout WebCore.MediaParserByteVector) {
    var runStart = 0
    var position = 0
    while data.count - position >= 3 {
        let third = data[position + 2]
        if third == 3 && data[position] == 0 && data[position + 1] == 0 {
            appendBytes(data.extracting(runStart..<(position + 2)), to: &output)
            position += 3
            runStart = position
        } else if third == 0 {
            position += 1
        } else {
            position += 3
        }
    }
    appendBytes(data.extracting(runStart..<data.count), to: &output)
}

// annexBToLengthPrefixed(): each NAL unit with a non-empty payload as a 32-bit big-endian length (the payload size
// truncated to 32 bits) followed by the payload. Reserves the exact size first, with size_t's wrapping, then fills it.
@inline(__always)
func appendLengthPrefixed(_ indices: Span<WebCore.NaluIndex>, of data: Span<UInt8>, to output: inout WebCore.MediaParserByteVector) {
    var totalSize = 0
    var position = 0
    while position < indices.count {
        let payloadSize = indices[position].payloadSize
        if payloadSize != 0 {
            totalSize &+= 4 &+ payloadSize
        }
        position += 1
    }
    if totalSize == 0 {
        return
    }

    let start = output.size()
    if output.capacity() == 0 {
        output.reserveInitialCapacity(totalSize)
    }
    // Every byte grow() leaves uninitialized is written below.
    output.grow(start &+ totalSize)
    var bytes: MutableSpan<UInt8> = output.mutableSpan()
    var offset = start
    position = 0
    while position < indices.count {
        let index = indices[position]
        position += 1
        if index.payloadSize == 0 {
            continue
        }
        let length = UInt32(truncatingIfNeeded: index.payloadSize)
        bytes[offset] = UInt8(truncatingIfNeeded: length >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: length >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: length >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: length)
        offset += 4
        let payload = data.extracting(index.payloadStartOffset..<(index.payloadStartOffset + index.payloadSize))
        copyBytes(payload, into: &bytes, at: offset)
        offset += payload.count
    }
}

private func appendBytes(_ bytes: Span<UInt8>, to output: inout WebCore.MediaParserByteVector) {
    // An empty Span may have no base address, which Cxx's std::span conversion traps on.
    if bytes.isEmpty {
        return
    }
    WebCore.appendBytes(&output, bytes)
}

// Entry points for AnnexBUtilities.cpp.

@_expose(Cxx)
func findNaluIndicesImpl(_ buffer: borrowing WebCore.MediaParserBytes, _ indices: inout WebCore.NaluIndexVector) {
    let bytes: Span<UInt8> = buffer.span()
    appendNaluIndices(of: bytes, to: &indices)
}

@_expose(Cxx)
func parseRbspImpl(_ data: borrowing WebCore.MediaParserBytes, _ output: inout WebCore.MediaParserByteVector) {
    let bytes: Span<UInt8> = data.span()
    appendRbsp(of: bytes, to: &output)
}

@_expose(Cxx)
func annexBToLengthPrefixedImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ indices: borrowing WebCore.MediaParserNaluIndices,
    _ output: inout WebCore.MediaParserByteVector
) {
    let bytes: Span<UInt8> = data.span()
    let naluIndices: Span<WebCore.NaluIndex> = indices.span()
    appendLengthPrefixed(naluIndices, of: bytes, to: &output)
}

#endif // ENABLE_WEBCORE_SWIFT
