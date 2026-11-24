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

struct LexerFlags: OptionSet {
    let rawValue: UInt8

    static let ignoreReservedWords = LexerFlags(rawValue: 1 << 0)
    static let dontBuildStrings = LexerFlags(rawValue: 1 << 1)
    static let dontBuildKeywords = LexerFlags(rawValue: 1 << 2)
}

enum RawStringsBuildMode {
    case buildRawStrings
    case dontBuildRawStrings
}

// What the lexer reports for an error, in the order the message is assembled. The parser appends it to the
// facade's message with `appendErrorMessage`.
enum LexerErrorMessage {
    case text(Swift.String)
    case unterminatedRegularExpression(start: Int, end: Int)
    case invalidRegularExpressionFlag(start: Int, end: Int, codePoint: UInt32)
}

enum NumberParseResult {
    case number(Double)
    case bigInt(JSC.JSParseIdentifier)
}

enum StringParseResult {
    case parsedSuccessfully
    case unterminated
    case cannotBeParsed
}

extension JSC.JSTextPosition {
    init(offset: Int) {
        self.init()
        self.offset = Int32(truncatingIfNeeded: offset)
    }
}

extension JSC.JSTokenType {
    /// Integer for a whole value that WTF's truncateDoubleToInt64 reproduces, Double otherwise.
    init(integerLike value: Double) {
        if (value != 0 || value.sign == .plus) && Double(WTF.truncateDoubleToInt64(value)) == value {
            self = .integer
        } else {
            self = .double
        }
    }
}

/// The lexer, over the characters of the whole source provider. `code` is an index into `source` and `codeEnd` the end
/// of the range being lexed, so every read of the source is bounds-checked against the provider.
struct Lexer<Unit: LexerCharacter>: ~Copyable, ~Escapable {
    let source: Span<Unit>
    var code: Int
    let codeEnd: Int
    var current: Unit
    var hasLineTerminatorBeforeToken = false
    var atLineStart = true
    let parsingBuiltinFunction: Bool
    var buffer8 = UniqueArray<UInt8>()
    var buffer16 = UniqueArray<UInt16>()
    var bufferForRawTemplateString16 = UniqueArray<UInt16>()
    var isReparsingFunction = false
    var sawError = false
    var errorMessage: LexerErrorMessage?
    var sourceURLDirective: JSC.JSParseExtent?
    var sourceMappingURLDirective: JSC.JSParseExtent?
    let scriptMode: JSC.JSParserScriptMode

    static var initialReadBufferCapacity: Int { 32 }
    // The limit is 1 << (52 - 1) = 2251799813685248
    static var numberOfDigitsForSafeInt52: Int { 15 }

    @_lifetime(copy source)
    init(source: Span<Unit>, modes: JSC.JSParseModes) {
        let end = Int(modes.endOffset)
        self.source = source.extracting(first: end)
        parsingBuiltinFunction = modes.builtinMode == .Builtin || modes.exposePrivateIdentifiers
        scriptMode = modes.scriptMode
        code = Int(modes.startOffset)
        codeEnd = end
        current = self.source.count > code && code >= 0 ? self.source[code] : 0
        buffer8.reserveCapacity(Self.initialReadBufferCapacity)
        buffer16.reserveCapacity(Self.initialReadBufferCapacity)
        bufferForRawTemplateString16.reserveCapacity(Self.initialReadBufferCapacity)
    }

    // MARK: Cursor

    var currentOffset: Int { code }
    var currentPosition: JSC.JSTextPosition { JSC.JSTextPosition(offset: code) }
    var nextCharacterIsCommaOrCloseBracket: Bool { current == .ascii(",") || current == .ascii("]") }

    @inline(always)
    mutating func shift() {
        // `code` never exceeds `source.count` (<= Int.max), so the increment cannot overflow.
        code &+= 1
        current = character(at: code)
    }

    /// The character at index, or 0 outside the source.
    @inline(always)
    func character(at index: Int) -> Unit {
        UInt(bitPattern: index) < UInt(bitPattern: source.count) ? source[index] : 0
    }

    /// Sets `current` from `code`, after the cursor was moved by assignment.
    @inline(always)
    mutating func reloadCurrent() {
        current = character(at: code)
    }

    @inline(always)
    var atEnd: Bool {
        current == 0 && code == codeEnd
    }

    /// The character `offset` (1 to 4) places ahead, or 0 past the end.
    @inline(always)
    func peek(_ offset: Int) -> Unit {
        assert(offset > 0 && offset < 5)
        return character(at: code &+ offset)
    }

    mutating func shiftLineTerminator() {
        assert(current.isLineTerminator)
        let previous = current
        shift()
        if Unit.isCRLFPair(previous, current) {
            shift()
        }
    }

    @inline(always)
    mutating func skipWhitespace() {
        var index = code
        while UInt(bitPattern: index) < UInt(bitPattern: source.count) && source[index].isWhiteSpace {
            index &+= 1
        }
        if index != code {
            code = index
            reloadCurrent()
        }
    }

    // Moves the cursor to `offset`, clearing the error. An offset outside the source reads as 0.
    mutating func setOffset(_ offset: Int) {
        sawError = false
        errorMessage = nil
        code = offset
        buffer8.removeAll()
        buffer16.removeAll()
        reloadCurrent()
    }

    mutating func clearErrorCodeAndBuffers() {
        sawError = false
        errorMessage = nil
        buffer8.removeAll()
        buffer16.removeAll()
    }

    mutating func clear() {
        buffer8 = UniqueArray<UInt8>()
        buffer16 = UniqueArray<UInt16>()
        bufferForRawTemplateString16 = UniqueArray<UInt16>()
        isReparsingFunction = false
    }

    /// The lexer state the parser saves and restores; atLineStart is not part of it.
    struct SavePoint {
        var offset: Int
        var hasLineTerminatorBeforeToken: Bool
    }

    mutating func restore(_ savePoint: SavePoint) {
        setOffset(savePoint.offset)
        hasLineTerminatorBeforeToken = savePoint.hasLineTerminatorBeforeToken
    }

    /// The source characters in `range`.
    @_lifetime(borrow self)
    func tokenCharacters(_ range: Range<Int>) -> Span<Unit> {
        source.extracting(range)
    }

    /// Appends the lexer's error message to the facade's.
    func appendErrorMessage(_ facade: inout JSC.JSParseFacade) {
        guard let errorMessage else {
            return
        }
        switch errorMessage {
        case .text(let text):
            appendErrorText(text, &facade)
        case .unterminatedRegularExpression(let start, let end):
            appendErrorText("Unterminated regular expression literal '", &facade)
            Unit.appendErrorCharacters(tokenCharacters(start..<end), &facade)
            appendErrorText("'", &facade)
        case .invalidRegularExpressionFlag(let start, let end, let codePoint):
            appendErrorText("Invalid non-latin character in RexExp literal's flags '", &facade)
            Unit.appendErrorCharacters(tokenCharacters(start..<end), &facade)
            if let scalar = Unicode.Scalar(codePoint) {
                let units = Array(Swift.String(Character(scalar)).utf16)
                facade.appendErrorCharacters16(units.span)
            } else {
                appendErrorText("`invalid unicode character`", &facade)
            }
            appendErrorText("'", &facade)
        }
    }

    private func appendErrorText(_ text: Swift.String, _ facade: inout JSC.JSParseFacade) {
        facade.appendErrorCharacters8(text.utf8.span)
    }

    var invalidCharacterMessage: LexerErrorMessage {
        let text: Swift.String
        switch current {
        case 0: text = "Invalid character: '\\0'"
        case .ascii("\n"): text = "Invalid character: '\\n'"
        case .ascii("\u{0B}"): text = "Invalid character: '\\v'"
        case .ascii("\r"): text = "Invalid character: '\\r'"
        case .ascii("#"): text = "Invalid character: '#'"
        case .ascii("@"): text = "Invalid character: '@'"
        case .ascii("`"): text = "Invalid character: '`'"
        default:
            let digits = Swift.String(UInt32(current), radix: 16)
            text = "Invalid character '\\u" + Swift.String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "'"
        }
        return .text(text)
    }

    // MARK: Code points

    /// ICU's U16_GET at `index`, reading forward only and not past `codeEnd`.
    func codePoint(at index: Int) -> UInt32 {
        let unit = UInt32(source[index])
        if Unit.bitWidth > 8 && unit.isSurrogate && unit.surrogateIsLead && index + 1 != codeEnd {
            let next = UInt32(source[index + 1])
            if next.isTrailSurrogate {
                return UInt32.supplementaryCodePoint(lead: unit, trail: next)
            }
        }
        return unit
    }

    /// The code point an error message names for a lead surrogate with no trail surrogate.
    static var errorCodePoint: UInt32 { 0xFFFF_FFFF }

    /// The code point at the cursor, or nil for a lead surrogate with no trail surrogate.
    var currentCodePoint: UInt32? {
        if Unit.bitWidth == 8 {
            return UInt32(current)
        }
        let unit = UInt32(current)
        if !unit.isSurrogate {
            return unit
        }
        let trail = UInt32(peek(1))
        // U16_IS_SURROGATE_TRAIL tests one bit, so a lead followed by any unit with bit 0x400 set is taken as a pair.
        if !unit.isLeadSurrogate || !trail.surrogateIsTrail {
            return nil
        }
        return UInt32.supplementaryCodePoint(lead: unit, trail: trail)
    }

    // MARK: Recording

    @inline(always)
    mutating func record8(_ character: UInt8) {
        buffer8.append(character)
    }

    @inline(always)
    mutating func record16(_ character: UInt16) {
        buffer16.append(character)
    }

    mutating func recordUnicodeCodePoint(_ codePoint: UInt32) {
        if codePoint < 0x10000 {
            record16(UInt16(truncatingIfNeeded: codePoint))
        } else {
            record16(UInt16(truncatingIfNeeded: 0xD7C0 &+ (codePoint >> 10)))
            record16(UInt16(truncatingIfNeeded: 0xDC00 | (codePoint & 0x3FF)))
        }
    }

    /// Appends source characters that are all Latin-1 to the 8-bit buffer.
    mutating func append8(_ range: Range<Int>) {
        Unit.appendLatin1(source.extracting(range), to: &buffer8)
    }

    mutating func append16(_ range: Range<Int>) {
        Unit.append(source.extracting(range), to: &buffer16)
    }

    mutating func appendRaw(_ range: Range<Int>) {
        Unit.append(source.extracting(range), to: &bufferForRawTemplateString16)
    }

    // MARK: Tokens

    @inline(always)
    mutating func lex(
        _ token: inout Token,
        flags: LexerFlags,
        strictMode: Bool,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSTokenType
    {
        hasLineTerminatorBeforeToken = false
        return lexWithoutClearingLineTerminator(&token, flags: flags, strictMode: strictMode, &facade)
    }

    var nextTokenIsColon: Bool {
        var index = code
        while index < codeEnd && (source[index].isWhiteSpace || source[index].isLineTerminator) {
            index += 1
        }
        return index < codeEnd && source[index] == .ascii(":")
    }

    @inline(always)
    func fillTokenInfo(_ token: inout Token) {
        token.endPosition = currentPosition
    }

    func fillTokenInfo(_ token: inout Token, _ endPosition: JSC.JSTextPosition) {
        token.endPosition = endPosition
    }

    mutating func returnError(_ type: JSC.JSTokenType, _ token: inout Token) -> JSC.JSTokenType {
        sawError = true
        fillTokenInfo(&token)
        precondition(type.canBeError)
        return type
    }

    /// The character type of the cursor, for the main dispatch: the table's for a Latin-1 character, and for another
    /// the identifier start, line terminator or invalid character it is.
    @inline(always)
    func dispatchType() -> CharacterType {
        if current.isLatin1 {
            return CharacterType(latin1: UInt8(truncatingIfNeeded: current))
        }
        if codePoint(at: code).isNonLatin1IdentStart {
            return .nonLatin1IdentifierStart
        }
        if current.isLineTerminator {
            return .lineTerminator
        }
        return .invalid
    }

    mutating func lexWithoutClearingLineTerminator(
        _ tokenRecord: inout Token,
        flags: LexerFlags,
        strictMode: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        assert(!sawError)
        assert(buffer8.isEmpty)
        assert(buffer16.isEmpty)
        var lexerFlags = flags
        var token = JSC.JSTokenType.error

        start: while true {
            skipWhitespace()
            tokenRecord.startPosition = currentPosition

            let type = dispatchType()
            switch type {
            case .greater, .equal, .exclamationMark, .add, .multiply, .and, .xor, .modulo, .or, .openParen, .closeParen, .openBracket,
                .closeBracket, .comma, .colon, .question, .tilde, .semicolon, .backQuote, .openBrace, .closeBrace:
                token = lexPunctuator(type)

            case .less:
                shift()
                if current == .ascii("!") && peek(1) == .ascii("-") && peek(2) == .ascii("-") && scriptMode == .Classic {
                    // <!-- marks the beginning of a line comment (for www usage)
                    if let result = scanSingleLineComment(&tokenRecord, checkForDirectives: false) {
                        return result
                    }
                    continue start
                }
                if current == .ascii("<") {
                    shift()
                    if current == .ascii("=") {
                        shift()
                        token = .lShiftEqual
                    } else {
                        token = .lShift
                    }
                } else if current == .ascii("=") {
                    shift()
                    token = .le
                } else {
                    token = .lt
                }

            case .sub:
                shift()
                if current == .ascii("-") {
                    shift()
                    if (atLineStart || hasLineTerminatorBeforeToken) && current == .ascii(">") && scriptMode == .Classic {
                        shift()
                        if let result = scanSingleLineComment(&tokenRecord, checkForDirectives: false) {
                            return result
                        }
                        continue start
                    }
                    token = !hasLineTerminatorBeforeToken ? .minusMinus : .autoMinusMinus
                } else if current == .ascii("=") {
                    shift()
                    token = .minusEqual
                } else {
                    token = .minus
                }

            case .slash:
                shift()
                if current == .ascii("/") {
                    shift()
                    if let result = scanSingleLineComment(&tokenRecord, checkForDirectives: true) {
                        return result
                    }
                    continue start
                }
                if current == .ascii("*") {
                    shift()
                    if parseMultilineComment() {
                        continue start
                    }
                    errorMessage = .text("Multiline comment was not closed properly")
                    return returnError(.unterminatedMultilineCommentError, &tokenRecord)
                }
                if current == .ascii("=") {
                    shift()
                    token = .divEqual
                } else {
                    token = .divide
                }

            case .dot:
                shift()
                if !current.isASCIIDigit {
                    if current == .ascii(".") && peek(1) == .ascii(".") {
                        shift()
                        shift()
                        token = .dotDotDot
                    } else {
                        token = .dot
                    }
                    break
                }
                token = lexNumberAfterDot(&tokenRecord.data, &facade)
                if token.canBeError {
                    return returnError(token, &tokenRecord)
                }

            case .zero, .number:
                token = lexNumber(&tokenRecord.data, strictMode: strictMode, &facade)
                if token.canBeError {
                    return returnError(token, &tokenRecord)
                }

            case .quote:
                // Each call specializes the scan for a constant buildStrings.
                let result =
                    lexerFlags.contains(.dontBuildStrings)
                    ? parseString(&tokenRecord.data, strictMode: strictMode, buildStrings: false, &facade)
                    : parseString(&tokenRecord.data, strictMode: strictMode, buildStrings: true, &facade)
                if result != .parsedSuccessfully {
                    return returnError(
                        result == .unterminated ? .unterminatedStringLiteralError : .invalidStringLiteralError,
                        &tokenRecord
                    )
                }
                shift()
                atLineStart = false
                fillTokenInfo(&tokenRecord)
                return .string

            case .latin1IdentifierStart, .whiteSpace, .nonLatin1IdentifierStart, .backSlash:
                token = lexIdentifierStartingAtCursor(&tokenRecord.data, lexerFlags, strictMode, &facade)

            case .lineTerminator:
                shiftLineTerminator()
                atLineStart = true
                hasLineTerminatorBeforeToken = true
                continue start

            case .hash:
                // Hashbang is only permitted at the start of the source text.
                let next = peek(1)
                if next == .ascii("!") && code == 0 {
                    shift()
                    shift()
                    if let result = scanSingleLineComment(&tokenRecord, checkForDirectives: false) {
                        return result
                    }
                    continue start
                }

                let isValidPrivateName: Bool
                if next.isLatin1 {
                    isValidPrivateName =
                        CharacterType(latin1: UInt8(truncatingIfNeeded: next)) == .latin1IdentifierStart || next == .ascii("\\")
                } else {
                    isValidPrivateName = codePoint(at: code + 1).isNonLatin1IdentStart
                }
                if !isValidPrivateName {
                    errorMessage = invalidCharacterMessage
                    return returnError(.error, &tokenRecord)
                }
                lexerFlags.remove(.dontBuildKeywords)
                token = lexIdentifierStartingAtCursor(&tokenRecord.data, lexerFlags, strictMode, &facade)

            case .privateIdentifierStart:
                if !parsingBuiltinFunction {
                    errorMessage = invalidCharacterMessage
                    return returnError(.error, &tokenRecord)
                }
                token = lexIdentifierStartingAtCursor(&tokenRecord.data, lexerFlags, strictMode, &facade)

            case .otherIdentifierPart:
                errorMessage = invalidCharacterMessage
                return returnError(.error, &tokenRecord)

            case .invalid:
                if current == 0 && atEnd {
                    fillTokenInfo(&tokenRecord)
                    return .eof
                }
                errorMessage = invalidCharacterMessage
                return returnError(.error, &tokenRecord)
            }

            atLineStart = false
            fillTokenInfo(&tokenRecord)
            return token
        }
    }

    /// The token of an operator or punctuator, which has no comment form and no error: `type` is the character at the
    /// cursor, `dispatchType()`.
    @inline(always)
    private mutating func lexPunctuator(_ type: CharacterType) -> JSC.JSTokenType {
        var token = JSC.JSTokenType.error
        switch type {
        case .greater:
            shift()
            if current == .ascii(">") {
                shift()
                if current == .ascii(">") {
                    shift()
                    if current == .ascii("=") {
                        shift()
                        token = .urShiftEqual
                    } else {
                        token = .urShift
                    }
                } else if current == .ascii("=") {
                    shift()
                    token = .rShiftEqual
                } else {
                    token = .rShift
                }
            } else if current == .ascii("=") {
                shift()
                token = .ge
            } else {
                token = .gt
            }

        case .equal:
            if peek(1) == .ascii(">") {
                token = .arrowFunction
                shift()
                shift()
                break
            }
            shift()
            if current == .ascii("=") {
                shift()
                if current == .ascii("=") {
                    shift()
                    token = .strEq
                } else {
                    token = .eqEq
                }
            } else {
                token = .equal
            }

        case .exclamationMark:
            shift()
            if current == .ascii("=") {
                shift()
                if current == .ascii("=") {
                    shift()
                    token = .strNEq
                } else {
                    token = .ne
                }
            } else {
                token = .exclamation
            }

        case .add:
            shift()
            if current == .ascii("+") {
                shift()
                token = !hasLineTerminatorBeforeToken ? .plusPlus : .autoPlusPlus
            } else if current == .ascii("=") {
                shift()
                token = .plusEqual
            } else {
                token = .plus
            }

        case .multiply:
            shift()
            if current == .ascii("=") {
                shift()
                token = .multEqual
            } else if current == .ascii("*") {
                shift()
                if current == .ascii("=") {
                    shift()
                    token = .powEqual
                } else {
                    token = .pow
                }
            } else {
                token = .times
            }

        case .and:
            shift()
            if current == .ascii("&") {
                shift()
                if current == .ascii("=") {
                    shift()
                    token = .andEqual
                } else {
                    token = .and
                }
            } else if current == .ascii("=") {
                shift()
                token = .bitAndEqual
            } else {
                token = .bitAnd
            }

        case .xor:
            shift()
            if current == .ascii("=") {
                shift()
                token = .bitXorEqual
            } else {
                token = .bitXor
            }

        case .modulo:
            shift()
            if current == .ascii("=") {
                shift()
                token = .modEqual
            } else {
                token = .mod
            }

        case .or:
            shift()
            if current == .ascii("=") {
                shift()
                token = .bitOrEqual
            } else if current == .ascii("|") {
                shift()
                if current == .ascii("=") {
                    shift()
                    token = .orEqual
                } else {
                    token = .or
                }
            } else {
                token = .bitOr
            }

        case .openParen:
            token = .openParen
            shift()

        case .closeParen:
            token = .closeParen
            shift()

        case .openBracket:
            token = .openBracket
            shift()

        case .closeBracket:
            token = .closeBracket
            shift()

        case .comma:
            token = .comma
            shift()

        case .colon:
            token = .colon
            shift()

        case .question:
            shift()
            if current == .ascii("?") {
                shift()
                if current == .ascii("=") {
                    shift()
                    token = .coalesceEqual
                } else {
                    token = .coalesce
                }
            } else if current == .ascii(".") && !peek(1).isASCIIDigit {
                shift()
                token = .questionDot
            } else {
                token = .question
            }

        case .tilde:
            token = .tilde
            shift()

        case .semicolon:
            shift()
            token = .semicolon

        case .backQuote:
            shift()
            token = .backQuote

        case .openBrace:
            shift()
            token = .openBrace

        case .closeBrace:
            shift()
            token = .closeBrace

        default:
            preconditionFailure("not a punctuator")
        }
        return token
    }
}
