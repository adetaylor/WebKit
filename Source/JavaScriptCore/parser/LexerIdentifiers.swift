//  Copyright (C) 1999-2000 Harri Porten (porten@kde.org)
//  Copyright (C) 2002-2023 Apple Inc. All rights reserved.
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

internal import JSCSwiftBoundary

// Identifiers, keywords and private names, including the \u-escape and surrogate-pair slow case.

extension Lexer {
    /// The identifier, keyword or private name at the cursor.
    mutating func parseIdentifier(
        _ data: inout TokenData,
        lexerFlags: LexerFlags,
        strictMode: Bool,
        buildIdentifiers: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        data.escaped = false
        let remaining = codeEnd - code
        let ignoreReservedWords = lexerFlags.contains(.ignoreReservedWords)
        if remaining >= Self.maxTokenLength && !ignoreReservedWords {
            if let keyword = keywordAtCursor() {
                code += keyword.length
                reloadCurrent()
                if buildIdentifiers {
                    data.ident = facade.wellKnownIdentifier(keyword.name)
                }
                return keyword.type == .reservedIfStrict && !strictMode ? .identifier : keyword.type
            }
        }

        let isPrivateName = current == .ascii("#")
        let isBuiltinName = Unit.bitWidth == 8 && current == .ascii("@") && parsingBuiltinFunction
        var isWellKnownSymbol = false
        if isBuiltinName {
            shift()
            if current == .ascii("@") {
                isWellKnownSymbol = true
                shift()
            }
        }

        let identifierStart = code
        if isPrivateName {
            shift()
        }

        var orAllChars: UInt32 = 0
        if Unit.bitWidth == 8 {
            code = Unit.findIdentifierEnd(source, from: code)
            reloadCurrent()
            // The scan stops at a non-ASCII character, and these are the Latin-1 ones that continue the identifier.
            while UInt32(current).isIdentPart {
                shift()
            }
            if current == .ascii("\\") {
                return parseIdentifierSlowCase(
                    &data,
                    lexerFlags: lexerFlags,
                    strictMode: strictMode,
                    identifierStart,
                    buildIdentifiers: buildIdentifiers,
                    &facade
                )
            }
        } else {
            // The scan skips ASCII only, which adds nothing to orAllChars.
            code = Unit.findIdentifierEnd(source, from: code)
            reloadCurrent()
            while current.isSingleCharacterIdentPart {
                orAllChars |= UInt32(current)
                shift()
            }
            if UInt32(current).isSurrogate || current == .ascii("\\") {
                return parseIdentifierSlowCase(
                    &data,
                    lexerFlags: lexerFlags,
                    strictMode: strictMode,
                    identifierStart,
                    buildIdentifiers: buildIdentifiers,
                    &facade
                )
            }
        }

        if buildIdentifiers || (Unit.bitWidth == 8 && parsingBuiltinFunction) {
            let characters = source.extracting(identifierStart..<code)
            if isBuiltinName {
                data.ident = Unit.makeBuiltinIdentifier(characters, isWellKnownSymbol, &facade)
                if data.ident.isNull {
                    return .invalidPrivateNameError
                }
            } else if orAllChars & ~0xFF == 0 {
                data.ident = Unit.makeLatin1Identifier(characters, &facade)
            } else {
                data.ident = Unit.makeIdentifier(characters, &facade)
            }
        } else {
            data.ident = JSC.JSParseIdentifier()
        }

        let identType = isPrivateName ? JSC.JSTokenType.privateName : JSC.JSTokenType.identifier
        if remaining < Self.maxTokenLength && !ignoreReservedWords && !isBuiltinName && !isPrivateName {
            precondition(buildIdentifiers)
            guard let token = Self.keywordToken(of: source.extracting(identifierStart..<code)) else {
                return identType
            }
            return token != .reservedIfStrict || strictMode ? token : identType
        }
        return identType
    }

    // An identifier with a `\u` escape or a surrogate pair, from `identifierStart`
    // to the cursor already scanned. Collects its characters in `buffer16`.
    private mutating func parseIdentifierSlowCase(
        _ data: inout TokenData,
        lexerFlags: LexerFlags,
        strictMode: Bool,
        _ start: Int,
        buildIdentifiers: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        var identifierStart = start
        var identCharsStart = identifierStart
        let isPrivateName = source[identifierStart] == .ascii("#")
        if isPrivateName {
            identCharsStart += 1
        }
        let identType = isPrivateName ? JSC.JSTokenType.privateName : JSC.JSTokenType.identifier

        if let error = fillIdentifierBuffer(
            &data,
            &identifierStart,
            isStart: identCharsStart == code,
            buildIdentifiers: buildIdentifiers
        ) {
            return error
        }

        while true {
            if current.isSingleCharacterIdentPart {
                shift()
                continue
            }
            if !UInt32(current).isSurrogate && current != .ascii("\\") {
                break
            }
            if let error = fillIdentifierBuffer(
                &data,
                &identifierStart,
                isStart: false,
                buildIdentifiers: buildIdentifiers
            ) {
                return error
            }
        }

        if buildIdentifiers {
            if identifierStart != code {
                append16(identifierStart..<code)
            }
            data.ident = UInt16.makeIdentifier(buffer16.span, &facade)
        } else {
            data.ident = JSC.JSParseIdentifier()
        }

        var keyword: JSC.JSTokenType?
        if !lexerFlags.contains(.ignoreReservedWords) {
            precondition(buildIdentifiers)
            keyword = Self.keywordToken(of: buffer16.span)
        }
        buffer16.removeAll()

        if let token = keyword, token != .reservedIfStrict || strictMode {
            return .escapedKeyword
        }
        return identType
    }

    /// Flushes the characters from `identifierStart` to the cursor to `buffer16`, then consumes the `\u` escape or surrogate pair at the cursor.
    ///
    /// Returns the error token, or nil when the escape or pair was consumed.
    private mutating func fillIdentifierBuffer(
        _ data: inout TokenData,
        _ identifierStart: inout Int,
        isStart: Bool,
        buildIdentifiers: Bool
    ) -> JSC.JSTokenType? {
        if identifierStart != code {
            append16(identifierStart..<code)
        }

        if current == .ascii("\\") {
            data.escaped = true
            shift()
            if current != .ascii("u") {
                return atEnd ? .unterminatedIdentifierEscapeError : .invalidIdentifierEscapeError
            }
            shift()
            let character = parseUnicodeEscape()
            guard case .value(let codePoint) = character else {
                if case .incomplete = character {
                    return .unterminatedIdentifierUnicodeEscapeError
                }
                return .invalidIdentifierUnicodeEscapeError
            }
            if isStart ? !codePoint.isIdentStart : !codePoint.isIdentPart {
                return .invalidIdentifierUnicodeEscapeError
            }
            if buildIdentifiers {
                recordUnicodeCodePoint(codePoint)
            }
            identifierStart = code
            return nil
        }

        if !UInt32(current).surrogateIsLead {
            return .invalidUnicodeEncodingError
        }
        guard let codePoint = currentCodePoint else {
            return .invalidUnicodeEncodingError
        }
        if isStart ? !codePoint.isNonLatin1IdentStart : !codePoint.isNonLatin1IdentPart {
            return .invalidIdentifierUnicodeError
        }
        append16(code..<code + 2)
        shift()
        shift()
        identifierStart = code
        return nil
    }

    // MARK: Identifiers

    @inline(always)
    func makeIdentifier(_ start: Int, _ end: Int, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseIdentifier {
        Unit.makeIdentifier(source.extracting(start..<end), &facade)
    }

    /// An identifier, keyword or private name at the cursor, or a one-character identifier when the next character ends it.
    mutating func lexIdentifierStartingAtCursor(
        _ data: inout TokenData,
        _ lexerFlags: LexerFlags,
        _ strictMode: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        // We observe one character identifier very frequently because real world web pages are shipping minified JavaScript.
        // This path handles it in a fast path.
        if dispatchType() == .latin1IdentifierStart {
            let next = peek(1)
            // This quickly detects the character is not a part of identifier-part *and* back-slash.
            if next.isLatin1 && CharacterType(latin1: UInt8(truncatingIfNeeded: next)) > .backSlash {
                let start = code
                shift()
                data.ident =
                    lexerFlags.contains(.dontBuildKeywords) ? JSC.JSParseIdentifier() : makeIdentifier(start, start + 1, &facade)
                return .identifier
            }
        }
        // Each call specializes the scan for a constant buildIdentifiers.
        return lexerFlags.contains(.dontBuildKeywords)
            ? parseIdentifier(&data, lexerFlags: lexerFlags, strictMode: strictMode, buildIdentifiers: false, &facade)
            : parseIdentifier(&data, lexerFlags: lexerFlags, strictMode: strictMode, buildIdentifiers: true, &facade)
    }
}
