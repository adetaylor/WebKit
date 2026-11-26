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

internal import JSCSwiftBoundary

// A width of the source's characters: Latin-1 at 8 bits, UTF-16 at 16. The lexer is generic over it, and specialized
// for each; what differs between the widths is here.
protocol LexerCharacter: LexerCodePoint & BitwiseCopyable {
    static func makeIdentifier(_ characters: Span<Self>, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier
    /// Every character must be Latin-1.
    static func makeLatin1Identifier(_ characters: Span<Self>, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier
    /// A regular expression's pattern, as a 16-bit identifier.
    static func makePatternIdentifier(
        _ characters: Span<Self>,
        orAllCharacters: UInt16,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSParseIdentifier
    static func makeBuiltinIdentifier(
        _ characters: Span<Self>,
        _ isWellKnownSymbol: Bool,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSParseIdentifier
    static func append(_ characters: Span<Self>, to buffer: inout UniqueArray<UInt16>)
    /// Every character must be Latin-1.
    static func appendLatin1(_ characters: Span<Self>, to buffer: inout UniqueArray<UInt8>)
    static func appendErrorCharacters(_ characters: Span<Self>, _ facade: inout JSC.JSParseFacade)
    /// The characters as the parser's error message prints them, through UTF-8: an unpaired surrogate becomes U+FFFD.
    static func appendPrintedErrorCharacters(_ characters: Span<Self>, _ facade: inout JSC.JSParseFacade)

    // The vector scans of LexerVectorScans.swift. Each returns the first index at or after `start` that the scan stops
    // at, or the span's count; the span is the source up to the end of the code.
    /// A character that is not [A-Za-z0-9_$]; a span too short for a vector skips every identifier part.
    static func findIdentifierEnd(_ characters: Span<Self>, from start: Int) -> Int
    /// A quote, a backslash, a character below 0xE or, for 16-bit characters and `checksLatin1`, one above 0xFF.
    static func findStringStop(_ characters: Span<Self>, from start: Int, quote: Self, checksLatin1: Bool) -> Int
    /// White space, a line terminator, a quote or an apostrophe.
    static func findDirectiveEnd(_ characters: Span<Self>, from start: Int) -> Int
    static func findLineTerminator(_ characters: Span<Self>, from start: Int) -> Int
}

// The @inline(always) on these statics and on the predicates in LexerCharacterTypes.swift keeps the per-character
// helpers inside the scan loops.
extension UInt8: LexerCharacter {
    @inline(always)
    static func makeIdentifier(_ characters: Span<UInt8>, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier {
        // The arena makes the empty identifier for no characters, and a std::span is made only from a span with an
        // address, which an empty Span may lack.
        characters.isEmpty ? facade.makeEmptyIdentifier() : facade.makeIdentifier8(characters)
    }

    @inline(always)
    static func makeLatin1Identifier(_ characters: Span<UInt8>, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier {
        makeIdentifier(characters, &facade)
    }

    @inline(always)
    static func makePatternIdentifier(
        _ characters: Span<UInt8>,
        orAllCharacters: UInt16,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSParseIdentifier
    {
        makeIdentifier(characters, &facade)
    }

    static func makeBuiltinIdentifier(
        _ characters: Span<UInt8>,
        _ isWellKnownSymbol: Bool,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSParseIdentifier
    {
        facade.makeBuiltinIdentifier8(characters, isWellKnownSymbol)
    }

    @inline(always)
    static func append(_ characters: Span<UInt8>, to buffer: inout UniqueArray<UInt16>) {
        buffer.append(addingCount: characters.count) { output in
            for i in characters.indices {
                output.append(UInt16(characters[i]))
            }
        }
    }

    @inline(always)
    static func appendLatin1(_ characters: Span<UInt8>, to buffer: inout UniqueArray<UInt8>) {
        buffer.append(copying: characters)
    }

    static func appendErrorCharacters(_ characters: Span<UInt8>, _ facade: inout JSC.JSParseFacade) {
        if !characters.isEmpty {
            facade.appendErrorCharacters8(characters)
        }
    }

    static func appendPrintedErrorCharacters(_ characters: Span<UInt8>, _ facade: inout JSC.JSParseFacade) {
        appendErrorCharacters(characters, &facade)
    }
}

extension UInt16: LexerCharacter {
    @inline(always)
    static func makeIdentifier(_ characters: Span<UInt16>, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier {
        characters.isEmpty ? facade.makeEmptyIdentifier() : facade.makeIdentifier16(characters)
    }

    @inline(always)
    static func makeLatin1Identifier(_ characters: Span<UInt16>, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier {
        characters.isEmpty ? facade.makeEmptyIdentifier() : facade.makeLatin1Identifier(characters)
    }

    @inline(always)
    static func makePatternIdentifier(
        _ characters: Span<UInt16>,
        orAllCharacters: UInt16,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSParseIdentifier
    {
        if orAllCharacters & ~0xFF == 0 {
            return makeLatin1Identifier(characters, &facade)
        }
        return makeIdentifier(characters, &facade)
    }

    static func makeBuiltinIdentifier(
        _ characters: Span<UInt16>,
        _ isWellKnownSymbol: Bool,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSParseIdentifier
    {
        facade.makeBuiltinIdentifier16(characters, isWellKnownSymbol)
    }

    @inline(always)
    static func append(_ characters: Span<UInt16>, to buffer: inout UniqueArray<UInt16>) {
        buffer.append(copying: characters)
    }

    @inline(always)
    static func appendLatin1(_ characters: Span<UInt16>, to buffer: inout UniqueArray<UInt8>) {
        buffer.append(addingCount: characters.count) { output in
            for i in characters.indices {
                output.append(UInt8(truncatingIfNeeded: characters[i]))
            }
        }
    }

    static func appendErrorCharacters(_ characters: Span<UInt16>, _ facade: inout JSC.JSParseFacade) {
        if !characters.isEmpty {
            facade.appendErrorCharacters16(characters)
        }
    }

    static func appendPrintedErrorCharacters(_ characters: Span<UInt16>, _ facade: inout JSC.JSParseFacade) {
        if !characters.isEmpty {
            facade.appendPrintedErrorCharacters16(characters)
        }
    }
}
