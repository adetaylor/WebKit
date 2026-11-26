//  Copyright (C) 1999-2000 Harri Porten (porten@kde.org)
//  Copyright (C) 2006-2024 Apple Inc. All rights reserved.
//  Copyright (C) 2007 Cameron Zwarich (cwzwarich@uwaterloo.ca)
//  Copyright (C) 2010 Zoltan Herczeg (zherczeg@inf.u-szeged.hu)
//  Copyright (C) 2012 Mathias Bynens (mathias@qiwi.be)
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.
//
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

// The lexer's five vector scans, as the C++ lexer's SIMD::find calls: parseIdentifier at both widths, parseString at
// both widths, the Latin-1 comment directive value, and the single-line comment's line terminator.
//
// Every scan takes the source up to the end of the code and the index to start from, and returns the first index at or
// after it that the scan's stop test flags, or the span's count when there is none. Like SIMD::find, a scan over at
// least one vector's worth of characters loads whole vectors (one per step, a set lane of the stop mask marking a
// stop, and a last vector overlapping the one before it for the tail), and a shorter one runs the scalar test.
//
// Each stop test is a SIMD mask built from lane compares, which lower to one compare instruction each, and the loop
// asks `any(mask)`. Only the vector that stops goes on to find its first stopping lane, from the mask's two 64-bit
// words: no across-lanes reduction sits between the load and the index.
//
// Each scan spells its loop out with an always-inlined stop test, one vector per step as SIMD::find does, and is itself
// always inlined into its caller, as the C++'s are: a call and a frame cost more than a short identifier's scan.

private typealias Vector8 = SIMD16<UInt8>
private typealias Vector16 = SIMD8<UInt16>
private typealias Mask8 = SIMDMask<SIMD16<Int8>>
private typealias Mask16 = SIMDMask<SIMD8<Int16>>

// The first lane set in the mask; the mask must have one. The mask's lanes are all ones or zeros, so its two 64-bit
// words say where the first set one is: the first nonzero word's trailing zero count, divided by the lane width.
@inline(always)
private func firstStop(_ mask: Mask8) -> Int {
    let words = bitCast(Vector8.zero.replacing(with: 0xFF, where: mask), to: SIMD2<UInt64>.self)
    return words[0] != 0 ? words[0].trailingZeroBitCount &>> 3 : 8 &+ (words[1].trailingZeroBitCount &>> 3)
}

@inline(always)
private func firstStop(_ mask: Mask16) -> Int {
    let words = bitCast(Vector16.zero.replacing(with: 0xFFFF, where: mask), to: SIMD2<UInt64>.self)
    return words[0] != 0 ? words[0].trailingZeroBitCount &>> 4 : 4 &+ (words[1].trailingZeroBitCount &>> 4)
}

// The lanes that are not [A-Za-z0-9_$].
@inline(always)
private func nonIdentifierMask(_ v: Vector8) -> Mask8 {
    let folded = v | 0x20
    return ((folded &- 0x61) .> 25) .& ((v &- 0x30) .> 9) .& (v .!= 0x24) .& (v .!= 0x5F)
}

@inline(always)
private func nonIdentifierMask(_ v: Vector16) -> Mask16 {
    let folded = v | 0x20
    return ((folded &- 0x61) .> 25) .& ((v &- 0x30) .> 9) .& (v .!= 0x24) .& (v .!= 0x5F)
}

// A quote, a backslash or a character below 0xE.
@inline(always)
private func stringStopMask(_ v: Vector8, _ quote: Vector8) -> Mask8 {
    (v .== quote) .| (v .== 0x5C) .| (v .< 0x0E)
}

@inline(always)
private func stringStopMask(_ v: Vector16, _ quote: Vector16) -> Mask16 {
    (v .== quote) .| (v .== 0x5C) .| (v .< 0x0E)
}

// Also a character above 0xFF.
@inline(always)
private func stringStopOrNonLatin1Mask(_ v: Vector16, _ quote: Vector16) -> Mask16 {
    stringStopMask(v, quote) .| (v .> 0xFF)
}

// White space, a line terminator (\t through \r, space and U+00A0 together), a quote or an apostrophe.
@inline(always)
private func directiveEndMask(_ v: Vector8) -> Mask8 {
    ((v &- 9) .<= 4) .| (v .== 0x20) .| (v .== 0x22) .| (v .== 0x27) .| (v .== 0xA0)
}

@inline(always)
private func lineTerminatorMask(_ v: Vector8) -> Mask8 {
    (v .== 0x0A) .| (v .== 0x0D)
}

// LS and PS differ only in the lowest bit.
@inline(always)
private func lineTerminatorMask(_ v: Vector16) -> Mask16 {
    (v .== 0x0A) .| (v .== 0x0D) .| ((v & 0xFFFE) .== 0x2028)
}

extension UInt8 {
    /// The first index at or after `start` of a character that cannot continue an ASCII identifier, `characters.count`
    /// when there is none. A span too short for a vector stops at the first character that is not an identifier part
    /// at all, as the C++'s scalar match does.
    @inline(always)
    static func findIdentifierEnd(_ characters: Span<UInt8>, from start: Int) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        var i = start
        if count &- start >= 16 {
            while i <= count &- 16 {
                let m = nonIdentifierMask(bytes.load(fromByteOffset: i, as: Vector8.self))
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 16
            }
            if i < count {
                let m = nonIdentifierMask(bytes.load(fromByteOffset: count &- 16, as: Vector8.self))
                if any(m) {
                    return count &- 16 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count && UInt32(characters[i]).isIdentPart {
            i &+= 1
        }
        return i
    }

    /// The first index at or after `start` of a quote, a backslash or a character below 0xE; `characters.count` when
    /// there is none. `checksLatin1` is for the 16-bit scan: every 8-bit character is Latin-1.
    @inline(always)
    static func findStringStop(_ characters: Span<UInt8>, from start: Int, quote: UInt8, checksLatin1: Bool) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        let quotes = Vector8(repeating: quote)
        var i = start
        if count &- start >= 16 {
            while i <= count &- 16 {
                let m = stringStopMask(bytes.load(fromByteOffset: i, as: Vector8.self), quotes)
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 16
            }
            if i < count {
                let m = stringStopMask(bytes.load(fromByteOffset: count &- 16, as: Vector8.self), quotes)
                if any(m) {
                    return count &- 16 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count {
            let character = characters[i]
            if character == quote || character == 0x5C || character < 0xE {
                return i
            }
            i &+= 1
        }
        return count
    }

    /// The first index at or after `start` of white space, a line terminator, a quote or an apostrophe;
    /// `characters.count` when there is none.
    @inline(always)
    static func findDirectiveEnd(_ characters: Span<UInt8>, from start: Int) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        var i = start
        if count &- start >= 16 {
            while i <= count &- 16 {
                let m = directiveEndMask(bytes.load(fromByteOffset: i, as: Vector8.self))
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 16
            }
            if i < count {
                let m = directiveEndMask(bytes.load(fromByteOffset: count &- 16, as: Vector8.self))
                if any(m) {
                    return count &- 16 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count {
            let character = UInt32(characters[i])
            if character.isWhiteSpace || character.isLineTerminator || character == 0x22 || character == 0x27 {
                return i
            }
            i &+= 1
        }
        return count
    }

    /// The first index at or after `start` of a line feed or carriage return; `characters.count` when there is none.
    @inline(always)
    static func findLineTerminator(_ characters: Span<UInt8>, from start: Int) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        var i = start
        if count &- start >= 16 {
            while i <= count &- 16 {
                let m = lineTerminatorMask(bytes.load(fromByteOffset: i, as: Vector8.self))
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 16
            }
            if i < count {
                let m = lineTerminatorMask(bytes.load(fromByteOffset: count &- 16, as: Vector8.self))
                if any(m) {
                    return count &- 16 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count && !UInt32(characters[i]).isLineTerminator {
            i &+= 1
        }
        return i
    }
}

extension UInt16 {
    /// The first index at or after `start` of a character that is not [A-Za-z0-9_$], `characters.count` when there is
    /// none.
    @inline(always)
    static func findIdentifierEnd(_ characters: Span<UInt16>, from start: Int) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        var i = start
        if count &- start >= 8 {
            while i <= count &- 8 {
                let m = nonIdentifierMask(bytes.load(fromByteOffset: i &* 2, as: Vector16.self))
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 8
            }
            if i < count {
                let m = nonIdentifierMask(bytes.load(fromByteOffset: (count &- 8) &* 2, as: Vector16.self))
                if any(m) {
                    return count &- 8 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count {
            let character = characters[i]
            let isAlphanumeric =
                (character >= 0x30 && character <= 0x39) || (character | 0x20 >= 0x61 && character | 0x20 <= 0x7A)
            if !isAlphanumeric && character != 0x5F && character != 0x24 {
                return i
            }
            i &+= 1
        }
        return count
    }

    /// The first index at or after `start` of a quote, a backslash, a character below 0xE or, when `checksLatin1`, a
    /// character above 0xFF; `characters.count` when there is none.
    @inline(always)
    static func findStringStop(_ characters: Span<UInt16>, from start: Int, quote: UInt16, checksLatin1: Bool) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        let quotes = Vector16(repeating: quote)
        var i = start
        if count &- start >= 8 {
            if checksLatin1 {
                while i <= count &- 8 {
                    let m = stringStopOrNonLatin1Mask(bytes.load(fromByteOffset: i &* 2, as: Vector16.self), quotes)
                    if any(m) {
                        return i &+ firstStop(m)
                    }
                    i &+= 8
                }
                if i < count {
                    let m = stringStopOrNonLatin1Mask(bytes.load(fromByteOffset: (count &- 8) &* 2, as: Vector16.self), quotes)
                    if any(m) {
                        return count &- 8 &+ firstStop(m)
                    }
                }
                return count
            }
            while i <= count &- 8 {
                let m = stringStopMask(bytes.load(fromByteOffset: i &* 2, as: Vector16.self), quotes)
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 8
            }
            if i < count {
                let m = stringStopMask(bytes.load(fromByteOffset: (count &- 8) &* 2, as: Vector16.self), quotes)
                if any(m) {
                    return count &- 8 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count {
            let character = characters[i]
            if character == quote || character == 0x5C || character < 0xE || (checksLatin1 && character > 0xFF) {
                return i
            }
            i &+= 1
        }
        return count
    }

    /// The first index at or after `start` of white space, a line terminator, a quote or an apostrophe;
    /// `characters.count` when there is none. The C++ scans 16-bit characters one by one here, and so does this.
    @inline(always)
    static func findDirectiveEnd(_ characters: Span<UInt16>, from start: Int) -> Int {
        var i = start
        while i < characters.count {
            let character = UInt32(characters[i])
            if character.isWhiteSpace || character.isLineTerminator || character == 0x22 || character == 0x27 {
                return i
            }
            i &+= 1
        }
        return characters.count
    }

    /// The first index at or after `start` of a line feed, a carriage return, U+2028 or U+2029; `characters.count`
    /// when there is none.
    @inline(always)
    static func findLineTerminator(_ characters: Span<UInt16>, from start: Int) -> Int {
        let count = characters.count
        let bytes = characters.bytes
        var i = start
        if count &- start >= 8 {
            while i <= count &- 8 {
                let m = lineTerminatorMask(bytes.load(fromByteOffset: i &* 2, as: Vector16.self))
                if any(m) {
                    return i &+ firstStop(m)
                }
                i &+= 8
            }
            if i < count {
                let m = lineTerminatorMask(bytes.load(fromByteOffset: (count &- 8) &* 2, as: Vector16.self))
                if any(m) {
                    return count &- 8 &+ firstStop(m)
                }
            }
            return count
        }
        while i < count && !UInt32(characters[i]).isLineTerminator {
            i &+= 1
        }
        return i
    }
}
