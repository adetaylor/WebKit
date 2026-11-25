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

internal import JSCSwiftBoundary

// The comments, the sourceURL and sourceMappingURL directives, regular expression and template string rescans.

extension Lexer {
    // True when the comment closed. A line terminator inside sets
    // `hasLineTerminatorBeforeToken`.
    @inline(always)
    mutating func parseMultilineComment() -> Bool {
        while true {
            while current == .ascii("*") {
                shift()
                if current == .ascii("/") {
                    shift()
                    return true
                }
            }

            if atEnd {
                return false
            }

            if current.isLineTerminator {
                shiftLineTerminator()
                hasLineTerminatorBeforeToken = true
            } else {
                shift()
                // Skip the plain characters up to the next `*`, line terminator or the end on a local index.
                var index = code
                while UInt(bitPattern: index) < UInt(bitPattern: source.count)
                    && source[index] != .ascii("*") && !source[index].isLineTerminator
                {
                    index &+= 1
                }
                code = index
                reloadCurrent()
            }
        }
    }

    // Consumes `text` as far as it matches, and reports whether all of it did. A failed match keeps the prefix it
    // consumed (`consume("source")` on "sourc" consumes "sourc").
    private mutating func consume(_ text: Swift.String) -> Bool {
        let bytes = text.utf8Span.span
        for index in bytes.indices {
            if current != Unit(truncatingIfNeeded: bytes[index]) {
                return false
            }
            shift()
        }
        return true
    }

    mutating func parseCommentDirective() {
        // sourceURL and sourceMappingURL directives.
        if !consume("source") {
            return
        }

        if consume("URL=") {
            sourceURLDirective = parseCommentDirectiveValue()
            return
        }

        if consume("MappingURL=") {
            sourceMappingURLDirective = parseCommentDirectiveValue()
            return
        }
    }

    // The value, up to white space, a line terminator or a quote; nil when more than white space follows it on the line.
    private mutating func parseCommentDirectiveValue() -> JSC.JSParseExtent? {
        skipWhitespace()
        let start = code
        if Unit.bitWidth == 8 {
            var index = start
            while index < codeEnd {
                let character = source[index]
                if character.isWhiteSpace || character.isLineTerminator || character == .ascii("\"") || character == .ascii("'") {
                    break
                }
                index += 1
            }
            code = index
            reloadCurrent()
        } else {
            while !current.isWhiteSpace && !current.isLineTerminator && current != .ascii("\"") && current != .ascii("'")
                && !atEnd
            {
                shift()
            }
        }
        let end = code

        skipWhitespace()
        if !current.isLineTerminator && !atEnd {
            return nil
        }

        var extent = JSC.JSParseExtent()
        extent.start = UInt32(truncatingIfNeeded: start)
        extent.length = UInt32(truncatingIfNeeded: end - start)
        return extent
    }

    // The cursor is after the comment's opening. Returns the token to return from
    // the scan, or nil when the caller restarts the scan.
    mutating func scanSingleLineComment(_ tokenRecord: inout Token, checkForDirectives: Bool) -> JSC.JSTokenType? {
        if checkForDirectives {
            // Script comment directives like "//# sourceURL=test.js".
            if (current == .ascii("#") || current == .ascii("@")) && peek(1).isWhiteSpace {
                shift()
                shift()
                parseCommentDirective()
            }
        }

        let endPosition = currentPosition

        var index = code
        while index < codeEnd && !source[index].isLineTerminator {
            index &+= 1
        }
        code = index
        if code == codeEnd {
            current = 0
            fillTokenInfo(&tokenRecord, endPosition)
            return .eof
        }

        current = source[code]
        shiftLineTerminator()
        atLineStart = true
        hasLineTerminatorBeforeToken = true
        // The caller restarts the token scan unless a restricted keyword needs the
        // automatic semicolon that the line terminator implies.
        if !tokenRecord.type.isRestrictedKeyword {
            return nil
        }

        fillTokenInfo(&tokenRecord, endPosition)
        return .semicolon
    }

    // MARK: Rescans the parser asks for

    // The regular expression whose opening '/' (and `patternPrefix`, the '=' of a '/=' token, or 0) the parser
    // consumed. The pattern is taken verbatim from the source, including the prefix.
    mutating func scanRegExp(
        _ tokenRecord: inout Token,
        patternPrefix: UInt16,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSTokenType
    {
        assert(!Unit(truncatingIfNeeded: patternPrefix).isLineTerminator)
        assert(patternPrefix != 0x2F)
        assert(patternPrefix != 0x5B)
        var lastWasEscape = false
        var inBrackets = false
        var charactersOredTogether: UInt16 = 0

        var patternStart = code
        if patternPrefix != 0 {
            patternStart -= 1
            // The check is on the source's own character, so a wrong prefix cannot give a wrong span.
            precondition(source[patternStart] == Unit(truncatingIfNeeded: patternPrefix))
            charactersOredTogether |= patternPrefix
        }

        while true {
            if current.isLineTerminator || atEnd {
                errorMessage = .unterminatedRegularExpression(start: Int(tokenRecord.startPosition.offset), end: code)
                return returnError(.unterminatedRegexpLiteralError, &tokenRecord)
            }

            let previous = current

            shift()

            if previous == .ascii("/") && !lastWasEscape && !inBrackets {
                break
            }

            charactersOredTogether |= UInt16(truncatingIfNeeded: previous)

            if lastWasEscape {
                lastWasEscape = false
                continue
            }

            switch previous {
            case .ascii("["):
                inBrackets = true
            case .ascii("]"):
                inBrackets = false
            case .ascii("\\"):
                lastWasEscape = true
            default:
                break
            }
        }

        tokenRecord.data.pattern = Unit.makePatternIdentifier(
            source.extracting(patternStart..<(code - 1)),
            orAllCharacters: charactersOredTogether,
            &facade
        )

        let flagsStart = code
        while current.isLatin1 {
            if !UInt32(current).isIdentPart {
                break
            }
            shift()
        }

        // Normally this would not be a lex error but dealing with surrogate pairs here is annoying and it's going to be an error anyway...
        if !current.isLatin1 && !current.isWhiteSpace && !current.isLineTerminator {
            errorMessage = .invalidRegularExpressionFlag(
                start: Int(tokenRecord.startPosition.offset),
                end: code,
                codePoint: currentCodePoint ?? Self.errorCodePoint
            )
            return returnError(.invalidIdentifierUnicodeError, &tokenRecord)
        }

        tokenRecord.data.flags = Unit.makeLatin1Identifier(source.extracting(flagsStart..<code), &facade)

        // Since RegExp always ends with / or flags (IdentifierPart), atLineStart always becomes false.
        atLineStart = false

        fillTokenInfo(&tokenRecord)
        return .regExp
    }

    /// The template string that continues after a '`' or a '}' the previous token scan already consumed.
    mutating func scanTemplateString(
        _ tokenRecord: inout Token,
        rawStringsBuildMode: RawStringsBuildMode,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        let result = parseTemplateLiteral(&tokenRecord.data, rawStringsBuildMode: rawStringsBuildMode, &facade)

        // Since TemplateString always ends with ` or }, atLineStart always becomes false.
        atLineStart = false
        if result != .parsedSuccessfully {
            return returnError(
                result == .unterminated ? .unterminatedTemplateLiteralError : .invalidTemplateLiteralError,
                &tokenRecord
            )
        }
        fillTokenInfo(&tokenRecord)
        return .template
    }
}
