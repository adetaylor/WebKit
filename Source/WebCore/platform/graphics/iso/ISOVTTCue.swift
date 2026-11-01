// Copyright (C) 2012-2026 Apple Inc. All rights reserved.
// Copyright (C) 2014-2023 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

// The safe Span overload Swift synthesizes for MediaParserBytes.span() calls a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Internal.ISOParseResults
import WebCore_Internal.MediaParsersCxxBridging

// WebVTT cues in ISO BMFF (ISO/IEC 14496-30): a 'vttc' box holding string boxes. ISOWebVTTCue (ISOVTTCue.cpp) builds
// its strings from the ranges these return.

// A string box of a cue: a box header, then the string's bytes up to the end of the box. The contents are positions in
// the parsed bytes.
struct ISOWebVTTStringBox: ISOBoxParsing {
    static let sourceIDType: UInt32 = 0x7673_6964 // 'vsid'
    static let identifierType: UInt32 = 0x6964_656E // 'iden'
    static let originalStartTimeType: UInt32 = 0x6374_696D // 'ctim'
    static let settingsType: UInt32 = 0x7374_7467 // 'sttg'
    static let cueTextType: UInt32 = 0x7061_796C // 'payl'

    var header: ISOBoxHeader
    var contents: Range<Int>

    static func parse(_ cursor: inout ByteCursor) -> ISOWebVTTStringBox? {
        let start = cursor.offset
        guard let header = ISOBoxHeader.parse(&cursor) else {
            return nil
        }
        // A size smaller than the header wraps around and then fails the check below.
        let count = header.size &- UInt64(cursor.offset &- start)
        guard let remaining = cursor.remaining, count <= UInt64(remaining) else {
            return nil
        }
        let contentsStart = Int(cursor.offset)
        cursor.advance(by: count)
        return ISOWebVTTStringBox(header: header, contents: contentsStart..<(contentsStart + Int(count)))
    }
}

enum ISOWebVTTCueBox {
    static let boxType: UInt32 = 0x7674_7463 // 'vttc'

    // The cue at offset: its box header, then string boxes until one can't be read. Records the string boxes in
    // ranges, with base added to their positions, and leaves the other fields of ranges alone. Returns the box's size,
    // or nil if the header can't be read. Afterwards offset is past the last string box read (or the header), or, on
    // failure, wherever reading the header stopped.
    static func parse(
        _ bytes: Span<UInt8>,
        at offset: inout UInt32,
        base: Int = 0,
        into ranges: inout WebCore.ISOWebVTTCueRanges
    ) -> UInt64? {
        var cursor = ByteCursor(bytes, offset: offset)
        guard let header = ISOBoxHeader.parse(&cursor) else {
            offset = cursor.offset
            return nil
        }
        // The string boxes are read from the cue's own bytes; a cue smaller than its header has none.
        let end = max(UInt64(offset) + header.size, UInt64(cursor.offset))
        let cueBytes = bytes.extracting(0..<Int(end))
        offset = cursor.offset
        while let stringBox = ISOWebVTTStringBox.read(cueBytes, at: &offset) {
            let string = WebCore.ISOWebVTTCueString(
                isPresent: true,
                contents: WebCore.ISOByteRange(offset: base + stringBox.contents.lowerBound, size: stringBox.contents.count)
            )
            switch stringBox.header.type {
            case ISOWebVTTStringBox.sourceIDType:
                ranges.sourceID = string
            case ISOWebVTTStringBox.identifierType:
                ranges.identifier = string
            case ISOWebVTTStringBox.originalStartTimeType:
                ranges.originalStartTime = string
            case ISOWebVTTStringBox.settingsType:
                ranges.settings = string
            case ISOWebVTTStringBox.cueTextType:
                ranges.cueText = string
            default:
                break
            }
        }
        return header.size
    }

    // The cue at the start of bytes; true if reading it stopped within its size. The ranges are recorded whenever the
    // header can be read, whatever the result.
    static func read(_ bytes: Span<UInt8>, base: Int = 0, into ranges: inout WebCore.ISOWebVTTCueRanges) -> Bool {
        var offset: UInt32 = 0
        guard let size = parse(bytes, at: &offset, base: base, into: &ranges) else {
            return false
        }
        return UInt64(offset) <= size
    }
}

// ISOWebVTTCue::parse(view, offset).
@_expose(Cxx)
func parseWebVTTCueImpl(
    _ bytes: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ ranges: inout WebCore.ISOWebVTTCueRanges
) -> Bool {
    let span: Span<UInt8> = bytes.span()
    return ISOWebVTTCueBox.parse(span, at: &offset, into: &ranges) != nil
}

// ISOWebVTTCue::read(view).
@_expose(Cxx)
func readWebVTTCueImpl(_ bytes: borrowing WebCore.MediaParserBytes, _ ranges: inout WebCore.ISOWebVTTCueRanges) -> Bool {
    let span: Span<UInt8> = bytes.span()
    return ISOWebVTTCueBox.read(span, into: &ranges)
}

// One step of InbandTextTrackPrivateAVF::processVTTSample's walk over the boxes of its sample buffer: the box at
// offset, and its cue if it is a 'vttc'. On success offset moves past the box, by at least one byte. Returns false
// when no box header fits in what is left.
@_expose(Cxx)
func parseWebVTTSampleBoxImpl(
    _ buffer: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ box: inout WebCore.ISOWebVTTSampleBox
) -> Bool {
    let bytes: Span<UInt8> = buffer.span()
    guard UInt64(offset) <= UInt64(bytes.count) else {
        return false
    }
    let start = Int(offset)
    // Each box is peeked and read at offset 0 of the rest of the buffer.
    let rest = bytes.extracting(start..<bytes.count)
    guard let (type, size) = ISOBoxHeader.peek(rest, at: 0), let next = UInt32(exactly: UInt64(offset) + size) else {
        return false
    }
    box = WebCore.ISOWebVTTSampleBox()
    box.type = type
    box.size = size
    if type == ISOWebVTTCueBox.boxType {
        box.isCue = true
        _ = ISOWebVTTCueBox.read(rest, base: start, into: &box.cue)
    }
    offset = next
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
