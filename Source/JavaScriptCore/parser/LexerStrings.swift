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

// String literals and template literals.

enum ParsedUnicodeEscapeValue {
    case value(UInt32)
    case incomplete
    case invalid
}

/// UCHAR_MAX_VALUE.
private let maximumCodePoint: UInt32 = 0x10FFFF

extension Lexer {
    /// A character parseString leaves to the slow case: a control character below 0xE, or one outside Latin-1.
    @inline(always)
    private func requiresSlowCase(_ character: Unit) -> Bool {
        character < 0xE || !character.isLatin1
    }

    mutating func parseUnicodeEscape() -> ParsedUnicodeEscapeValue {
        if current == .ascii("{") {
            shift()
            var codePoint: UInt32 = 0
            repeat {
                if !current.isASCIIHexDigit {
                    return current != 0 ? .invalid : .incomplete
                }
                codePoint = (codePoint << 4) | UInt32(current.asciiHexValue)
                if codePoint > maximumCodePoint {
                    // For raw template literal syntax, we consume `NotEscapeSequence`.
                    // Here, we consume NotCodePoint's HexDigits.
                    //
                    // NotEscapeSequence ::
                    //     u { [lookahead not one of HexDigit]
                    //     u { NotCodePoint
                    //     u { CodePoint [lookahead != }]
                    //
                    // NotCodePoint ::
                    //     HexDigits but not if MV of HexDigits <= 0x10FFFF
                    //
                    // CodePoint ::
                    //     HexDigits but not if MV of HexDigits > 0x10FFFF
                    shift()
                    while current.isASCIIHexDigit {
                        shift()
                    }
                    return atEnd ? .incomplete : .invalid
                }
                shift()
            } while current != .ascii("}")
            shift()
            return .value(codePoint)
        }

        let character2 = peek(1)
        let character3 = peek(2)
        let character4 = peek(3)
        if !current.isASCIIHexDigit || !character2.isASCIIHexDigit || !character3.isASCIIHexDigit
            || !character4.isASCIIHexDigit
        {
            let result: ParsedUnicodeEscapeValue = (code + 4) >= codeEnd ? .incomplete : .invalid

            // For raw template literal syntax, we consume `NotEscapeSequence`.
            //
            // NotEscapeSequence ::
            //     u [lookahead not one of HexDigit][lookahead != {]
            //     u HexDigit [lookahead not one of HexDigit]
            //     u HexDigit HexDigit [lookahead not one of HexDigit]
            //     u HexDigit HexDigit HexDigit [lookahead not one of HexDigit]
            while current.isASCIIHexDigit {
                shift()
            }
            return result
        }

        let result = Unit.convertUnicode(current, character2, character3, character4)
        shift()
        shift()
        shift()
        shift()
        return .value(result)
    }

    /// The first index at or after `start` of a quote, a backslash, a character below 0xE or (for a string built from
    /// 16-bit characters) a non-Latin-1 character; `codeEnd` when there is none.
    private func findStringStop(_ start: Int, _ quote: Unit, buildStrings: Bool) -> Int {
        let checksLatin1 = Unit.bitWidth > 8 && buildStrings
        var index = start
        while index < codeEnd {
            let character = source[index]
            if character == quote || character == .ascii("\\") || character < 0xE || (checksLatin1 && !character.isLatin1) {
                return index
            }
            index &+= 1
        }
        return codeEnd
    }

    /// The fast loop of parseString hit something only the slow case handles: restarts the string from its opening quote.
    @inline(always)
    private mutating func restartInSlowCase(
        at offset: Int,
        _ data: inout TokenData,
        strictMode: Bool,
        buildStrings: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> StringParseResult {
        setOffset(offset)
        return parseStringSlowCase(&data, strictMode: strictMode, buildStrings: buildStrings, &facade)
    }

    mutating func parseString(
        _ data: inout TokenData,
        strictMode: Bool,
        buildStrings: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> StringParseResult {
        let startingOffset = code
        let quote = current
        shift()

        var stringStart = code

        var found = findStringStop(stringStart, quote, buildStrings: buildStrings)
        if found == codeEnd {
            return restartInSlowCase(at: startingOffset, &data, strictMode: strictMode, buildStrings: buildStrings, &facade)
        }

        code = found
        current = source[found]
        if current == quote {
            if buildStrings {
                data.ident = Unit.makeLatin1Identifier(source.extracting(stringStart..<found), &facade)
            } else {
                data.ident = JSC.JSParseIdentifier()
            }
            return .parsedSuccessfully
        }

        while current != quote {
            if current == .ascii("\\") {
                if buildStrings && stringStart != code {
                    append8(stringStart..<code)
                }
                shift()

                let escape = current.singleEscapeValue

                // Most common escape sequences first.
                if escape != 0 {
                    if buildStrings {
                        record8(escape)
                    }
                    shift()
                } else if current.isLineTerminator {
                    shiftLineTerminator()
                } else if current == .ascii("x") {
                    shift()
                    if !current.isASCIIHexDigit || !peek(1).isASCIIHexDigit {
                        errorMessage = .text("\\x can only be followed by a hex character sequence")
                        return (atEnd || (current.isASCIIHexDigit && (code + 1 == codeEnd)))
                            ? .unterminated : .cannotBeParsed
                    }
                    let previous = current
                    shift()
                    if buildStrings {
                        record8(Unit.convertHex(previous, current))
                    }
                    shift()
                } else {
                    return restartInSlowCase(at: startingOffset, &data, strictMode: strictMode, buildStrings: buildStrings, &facade)
                }
                stringStart = code

                // Retry the scan to skip the next plain segment to an interesting character.
                found = findStringStop(stringStart, quote, buildStrings: buildStrings)
                if found == codeEnd {
                    return restartInSlowCase(at: startingOffset, &data, strictMode: strictMode, buildStrings: buildStrings, &facade)
                }
                code = found
                current = source[found]

                if requiresSlowCase(current) {
                    return restartInSlowCase(at: startingOffset, &data, strictMode: strictMode, buildStrings: buildStrings, &facade)
                }
                continue
            }

            if requiresSlowCase(current) {
                return restartInSlowCase(at: startingOffset, &data, strictMode: strictMode, buildStrings: buildStrings, &facade)
            }

            shift()
        }

        if buildStrings {
            if code != stringStart {
                append8(stringStart..<code)
            }
            data.ident = UInt8.makeIdentifier(buffer8.span, &facade)
            buffer8.removeAll()
        } else {
            data.ident = JSC.JSParseIdentifier()
        }

        return .parsedSuccessfully
    }

    mutating func parseComplexEscape(strictMode: Bool, buildStrings: Bool) -> StringParseResult {
        if current == .ascii("x") {
            shift()
            if !current.isASCIIHexDigit || !peek(1).isASCIIHexDigit {
                // For raw template literal syntax, we consume `NotEscapeSequence`.
                //
                // NotEscapeSequence ::
                //     x [lookahread not one of HexDigit]
                //     x HexDigit [lookahread not one of HexDigit]
                if current.isASCIIHexDigit {
                    shift()
                }
                assert(!current.isASCIIHexDigit)

                errorMessage = .text("\\x can only be followed by a hex character sequence")
                return atEnd ? .unterminated : .cannotBeParsed
            }

            let previous = current
            shift()
            if buildStrings {
                record16(UInt16(Unit.convertHex(previous, current)))
            }
            shift()

            return .parsedSuccessfully
        }

        if current == .ascii("u") {
            shift()

            let character = parseUnicodeEscape()
            if case .value(let codePoint) = character {
                if buildStrings {
                    recordUnicodeCodePoint(codePoint)
                }
                return .parsedSuccessfully
            }

            errorMessage = .text("\\u can only be followed by a Unicode character sequence")
            return atEnd ? .unterminated : .cannotBeParsed
        }

        if strictMode {
            if current.isASCIIDigit {
                // The only valid numeric escape in strict mode is '\0', and this must not be followed by a decimal digit.
                let character1 = current
                shift()
                if character1 != .ascii("0") || current.isASCIIDigit {
                    // For raw template literal syntax, we consume `NotEscapeSequence`.
                    //
                    // NotEscapeSequence ::
                    //     0 DecimalDigit
                    //     DecimalDigit but not 0
                    if character1 == .ascii("0") {
                        shift()
                    }

                    errorMessage = .text("The only valid numeric escape in strict mode is '\\0'")
                    return atEnd ? .unterminated : .cannotBeParsed
                }
                if buildStrings {
                    record16(0)
                }
                return .parsedSuccessfully
            }
        } else {
            if current.isASCIIOctalDigit {
                // Octal character sequences
                let character1 = Int(current)
                shift()
                if current.isASCIIOctalDigit {
                    // Two octal characters
                    let character2 = Int(current)
                    shift()
                    if character1 >= 0x30 && character1 <= 0x33 && current.isASCIIOctalDigit {
                        if buildStrings {
                            record16(UInt16(truncatingIfNeeded: (character1 - 0x30) * 64 + (character2 - 0x30) * 8 + Int(current) - 0x30))
                        }
                        shift()
                    } else if buildStrings {
                        record16(UInt16(truncatingIfNeeded: (character1 - 0x30) * 8 + character2 - 0x30))
                    }
                } else if buildStrings {
                    record16(UInt16(truncatingIfNeeded: character1 - 0x30))
                }
                return .parsedSuccessfully
            }
        }

        if !atEnd {
            if buildStrings {
                record16(UInt16(truncatingIfNeeded: current))
            }
            shift()
            return .parsedSuccessfully
        }

        errorMessage = .text("Unterminated string constant")
        return .unterminated
    }

    mutating func parseStringSlowCase(
        _ data: inout TokenData,
        strictMode: Bool,
        buildStrings: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> StringParseResult {
        let quote = current
        shift()

        var stringStart = code

        while current != quote {
            if current == .ascii("\\") {
                if buildStrings && stringStart != code {
                    append16(stringStart..<code)
                }
                shift()

                let escape = current.singleEscapeValue

                // Most common escape sequences first
                if escape != 0 {
                    if buildStrings {
                        record16(UInt16(escape))
                    }
                    shift()
                } else if current.isLineTerminator {
                    shiftLineTerminator()
                } else {
                    let result = parseComplexEscape(strictMode: strictMode, buildStrings: buildStrings)
                    if result != .parsedSuccessfully {
                        return result
                    }
                }

                stringStart = code
                continue
            }
            if current.needsLiteralSpecialHandling {
                // New-line or end of input is not allowed
                if atEnd || current == .ascii("\r") || current == .ascii("\n") {
                    errorMessage = .text("Unexpected EOF")
                    return atEnd ? .unterminated : .cannotBeParsed
                }
                // An unescaped LS or PS may appear in a string literal, but it does not stop being a LineTerminator
                // (ECMA-262 #11.3): it stays part of the string's value *and* ends the line.
                if current.isLineTerminator {
                    shiftLineTerminator()
                    continue
                }
                // Anything else is just a normal character
            }
            shift()
        }

        if buildStrings {
            if code != stringStart {
                append16(stringStart..<code)
            }
            data.ident = UInt16.makeIdentifier(buffer16.span, &facade)
        } else {
            data.ident = JSC.JSParseIdentifier()
        }

        buffer16.removeAll()
        return .parsedSuccessfully
    }

    mutating func parseTemplateLiteral(
        _ data: inout TokenData,
        rawStringsBuildMode: RawStringsBuildMode,
        _ facade: inout JSC.JSParseFacade
    ) -> StringParseResult {
        var parseCookedFailed = false
        var stringStart = code
        var rawStringStart = code
        let buildRaw = rawStringsBuildMode == .buildRawStrings

        while current != .ascii("`") {
            if current == .ascii("\\") {
                if stringStart != code {
                    append16(stringStart..<code)
                }
                shift()

                let escape = current.singleEscapeValue

                // Most common escape sequences first.
                if escape != 0 {
                    record16(UInt16(escape))
                    shift()
                } else if current.isLineTerminator {
                    // Normalize <CR>, <CR><LF> to <LF>.
                    if current == .ascii("\r") {
                        assert(rawStringStart != code, "We should have at least shifted the escape.")

                        if buildRaw {
                            appendRaw(rawStringStart..<code)
                            bufferForRawTemplateString16.append(0x0A)
                        }

                        shiftLineTerminator()
                        rawStringStart = code
                    } else {
                        shiftLineTerminator()
                    }
                } else {
                    let result = parseComplexEscape(strictMode: true, buildStrings: true)
                    if result != .parsedSuccessfully {
                        guard buildRaw && result == .cannotBeParsed else {
                            return result
                        }
                        parseCookedFailed = true
                    }
                }

                stringStart = code
                continue
            }

            if current == .ascii("$") && peek(1) == .ascii("{") {
                break
            }

            if current.needsLiteralSpecialHandling {
                // End of input is not allowed. Unlike String, line terminator is allowed.
                if atEnd {
                    errorMessage = .text("Unexpected EOF")
                    return .unterminated
                }

                if current.isLineTerminator {
                    if current == .ascii("\r") {
                        // Normalize <CR>, <CR><LF> to <LF>.
                        if stringStart != code {
                            append16(stringStart..<code)
                        }
                        if rawStringStart != code && buildRaw {
                            appendRaw(rawStringStart..<code)
                        }

                        record16(0x0A)
                        if buildRaw {
                            bufferForRawTemplateString16.append(0x0A)
                        }
                        shiftLineTerminator()
                        stringStart = code
                        rawStringStart = code
                    } else {
                        shiftLineTerminator()
                    }
                    continue
                }
                // Anything else is just a normal character
            }

            shift()
        }

        let isTail = current == .ascii("`")

        if code != stringStart {
            append16(stringStart..<code)
        }
        if rawStringStart != code && buildRaw {
            appendRaw(rawStringStart..<code)
        }

        if !parseCookedFailed {
            data.cooked = UInt16.makeIdentifier(buffer16.span, &facade)
        } else {
            data.cooked = JSC.JSParseIdentifier()
        }

        // Line terminator normalization (e.g. <CR> => <LF>) should be applied to both the raw and cooked representations.
        if buildRaw {
            data.raw = UInt16.makeIdentifier(bufferForRawTemplateString16.span, &facade)
        } else {
            data.raw = JSC.JSParseIdentifier()
        }

        data.isTail = isTail

        buffer16.removeAll()
        bufferForRawTemplateString16.removeAll()

        if isTail {
            // Skip `
            shift()
        } else {
            // Skip $ and {
            shift()
            shift()
        }

        return .parsedSuccessfully
    }
}
