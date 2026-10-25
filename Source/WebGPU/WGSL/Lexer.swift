// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

// ICU's XID_Start within ASCII is exactly the letters, and its XID_Continue the letters, the digits and "_": ASCII never
// reaches the identifier character classes.
private func isIdentifierStart(
    _ character: UInt16,
    _ code: borrowing ContiguousArray<UInt16>,
    _ index: Int,
    _ classes: borrowing IdentifierCharacterClasses
) -> Int {
    if character == UInt16(ascii: "_") {
        return 1
    }
    if character < 0x80 {
        return isASCIIAlpha(character) ? 1 : 0
    }

    var length = 1
    if code.count - index > 1 && isSurrogate(character) {
        length += 1
    }
    if let scalar = singleCodePoint(code, index, length), classes.isXIDStart(scalar) {
        return length
    }
    return 0
}

private func isIdentifierContinue(
    _ character: UInt16,
    _ code: borrowing ContiguousArray<UInt16>,
    _ index: Int,
    _ classes: borrowing IdentifierCharacterClasses
) -> Int {
    let startLength = isIdentifierStart(character, code, index, classes)
    if startLength != 0 {
        return startLength
    }
    if character < 0x80 {
        return isASCIIDigit(character) ? 1 : 0
    }

    var length = 1
    if code.count - index > 1 && isSurrogate(character) {
        length += 1
    }
    if let scalar = singleCodePoint(code, index, length), classes.isXIDContinue(scalar) {
        return length
    }
    return 0
}

private func isIdentifierStart(_ character: UInt8, _ classes: borrowing IdentifierCharacterClasses) -> Int {
    if isASCIIAlpha(UInt16(character)) || character == UInt8(ascii: "_") {
        return 1
    }
    if character >= 0x80 && classes.isXIDStart(UInt32(character)) {
        return 1
    }
    return 0
}

private func isIdentifierContinue(_ character: UInt8, _ classes: borrowing IdentifierCharacterClasses) -> Int {
    if isASCIIAlphanumeric(UInt16(character)) || character == UInt8(ascii: "_") {
        return 1
    }
    if character >= 0x80 && classes.isXIDContinue(UInt32(character)) {
        return 1
    }
    return 0
}

// https://www.w3.org/TR/WGSL/#blankspace-and-line-breaks
private func isLineBreak(_ character: UInt16) -> Bool {
    character == UInt16(ascii: "\n") || character == 0x0B || character == 0x0C || character == UInt16(ascii: "\r")
        || character == 0x85 || character == 0x2028 || character == 0x2029
}

@_spi(Testing)
public struct Lexer {
    // StringParsingBuffer<T> m_code: the source's code units as stored, and the position in them.
    private let latin1: ContiguousArray<UInt8>
    private let utf16: ContiguousArray<UInt16>
    private let is8Bit: Bool
    private var position: Int
    private let end: Int
    private var current: UInt16
    private var currentPosition = SourcePosition(line: 1, lineOffset: 0, offset: 0)
    private var tokenStartingPosition = SourcePosition(line: 0, lineOffset: 0, offset: 0)
    private let identifierCharacterClasses: IdentifierCharacterClasses
    private var numberBytes = ContiguousArray<UInt8>()
    // The tokens lex() returned, counted for the parser's arena reservation (`TokenCounts`).
    private(set) var tokenCounts = TokenCounts()

    @_spi(Testing)
    public init(_ source: SourceText, identifierCharacterClasses: IdentifierCharacterClasses) {
        switch source.storage {
        case .latin1(let codeUnits):
            latin1 = codeUnits
            utf16 = []
            is8Bit = true
            end = codeUnits.count
            current = end > 0 ? UInt16(codeUnits[0]) : 0
        case .utf16(let codeUnits):
            latin1 = []
            utf16 = codeUnits
            is8Bit = false
            end = codeUnits.count
            current = end > 0 ? codeUnits[0] : 0
        }
        position = 0
        self.identifierCharacterClasses = identifierCharacterClasses
    }

    private var currentOffset: UInt32 {
        @inline(__always)
        get { currentPosition.offset }
    }
    private var currentTokenLength: UInt32 {
        @inline(__always)
        get { currentOffset &- tokenStartingPosition.offset }
    }

    // The small readers of the lexer are inlined: a call takes a copy of it.
    @inline(__always)
    private func makeToken(_ type: TokenType) -> Token {
        Token(type, tokenStartingPosition, currentTokenLength)
    }

    @inline(__always)
    private func makeFloatToken(_ type: TokenType, _ floatValue: Double) -> Token {
        Token(type, tokenStartingPosition, currentTokenLength, floatValue: floatValue)
    }

    @inline(__always)
    private func makeIntegerToken(_ type: TokenType, _ integerValue: Int64) -> Token {
        Token(type, tokenStartingPosition, currentTokenLength, integerValue: integerValue)
    }

    @inline(__always)
    private func makeIdentifierToken(_ identifier: Range<Int>) -> Token {
        Token(.identifier, tokenStartingPosition, currentTokenLength, ident: identifier)
    }

    @_spi(Testing)
    public mutating func lex() -> [Token] {
        var tokens: [Token] = []
        // About a token per four code units; a large module grows from there.
        tokens.reserveCapacity(end / 4 + 16)
        var counts = TokenCounts()
        let weights = TokenCounts.weights

        while true {
            let token = nextToken()
            tokens.append(token)
            counts.add(token.type, weights)
            switch token.type {
            case .gtGtEq:
                tokens.append(makeToken(.placeholder))
                fallthrough
            case .gtGt, .gtEq, .minusMinus:
                tokens.append(makeToken(.placeholder))
            default: // lint-exempt(L-ENUM-1): as the C++, only the four splittable tokens get placeholders
                break
            }

            if token.type == .endOfFile || token.type == .invalid {
                break
            }
        }

        tokenCounts = counts
        return tokens
    }

    private mutating func nextToken() -> Token {
        if !skipWhitespaceAndComments() {
            return makeToken(.invalid)
        }

        tokenStartingPosition = currentPosition

        if isAtEndOfFile() {
            return makeToken(.endOfFile)
        }

        switch current {
        case UInt16(ascii: "!"):
            shift()
            if current == UInt16(ascii: "=") {
                shift()
                return makeToken(.bangEq)
            }
            return makeToken(.bang)
        case UInt16(ascii: "%"):
            shift()
            switch current {
            case UInt16(ascii: "="):
                shift()
                return makeToken(.moduloEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.modulo)
            }
        case UInt16(ascii: "&"):
            shift()
            switch current {
            case UInt16(ascii: "&"):
                shift()
                return makeToken(.andAnd)
            case UInt16(ascii: "="):
                shift()
                return makeToken(.andEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.and)
            }
        case UInt16(ascii: "("):
            shift()
            return makeToken(.parenLeft)
        case UInt16(ascii: ")"):
            shift()
            return makeToken(.parenRight)
        case UInt16(ascii: "{"):
            shift()
            return makeToken(.braceLeft)
        case UInt16(ascii: "}"):
            shift()
            return makeToken(.braceRight)
        case UInt16(ascii: "["):
            shift()
            return makeToken(.bracketLeft)
        case UInt16(ascii: "]"):
            shift()
            return makeToken(.bracketRight)
        case UInt16(ascii: ":"):
            shift()
            return makeToken(.colon)
        case UInt16(ascii: ","):
            shift()
            return makeToken(.comma)
        case UInt16(ascii: ";"):
            shift()
            return makeToken(.semicolon)
        case UInt16(ascii: "="):
            shift()
            if current == UInt16(ascii: "=") {
                shift()
                return makeToken(.eqEq)
            }
            return makeToken(.equal)
        case UInt16(ascii: ">"):
            shift()
            switch current {
            case UInt16(ascii: "="):
                shift()
                return makeToken(.gtEq)
            case UInt16(ascii: ">"):
                shift()
                switch current {
                case UInt16(ascii: "="):
                    shift()
                    return makeToken(.gtGtEq)
                default: // lint-exempt(L-ENUM-1): a code unit
                    return makeToken(.gtGt)
                }
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.gt)
            }
        case UInt16(ascii: "<"):
            shift()
            switch current {
            case UInt16(ascii: "="):
                shift()
                return makeToken(.ltEq)
            case UInt16(ascii: "<"):
                shift()
                switch current {
                case UInt16(ascii: "="):
                    shift()
                    return makeToken(.ltLtEq)
                default: // lint-exempt(L-ENUM-1): a code unit
                    return makeToken(.ltLt)
                }
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.lt)
            }
        case UInt16(ascii: "@"):
            shift()
            return makeToken(.attribute)
        case UInt16(ascii: "*"):
            shift()
            switch current {
            case UInt16(ascii: "="):
                shift()
                return makeToken(.starEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.star)
            }
        case UInt16(ascii: "/"):
            shift()
            switch current {
            case UInt16(ascii: "="):
                shift()
                return makeToken(.slashEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.slash)
            }
        case UInt16(ascii: "-"):
            shift()
            switch current {
            case UInt16(ascii: ">"):
                shift()
                return makeToken(.arrow)
            case UInt16(ascii: "-"):
                shift()
                return makeToken(.minusMinus)
            case UInt16(ascii: "="):
                shift()
                return makeToken(.minusEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.minus)
            }
        case UInt16(ascii: "+"):
            shift()
            switch current {
            case UInt16(ascii: "+"):
                shift()
                return makeToken(.plusPlus)
            case UInt16(ascii: "="):
                shift()
                return makeToken(.plusEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.plus)
            }
        case UInt16(ascii: "^"):
            shift()
            switch current {
            case UInt16(ascii: "="):
                shift()
                return makeToken(.xorEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.xor)
            }
        case UInt16(ascii: "|"):
            shift()
            switch current {
            case UInt16(ascii: "|"):
                shift()
                return makeToken(.orOr)
            case UInt16(ascii: "="):
                shift()
                return makeToken(.orEq)
            default: // lint-exempt(L-ENUM-1): a code unit
                return makeToken(.or)
            }
        case UInt16(ascii: "~"):
            shift()
            return makeToken(.tilde)
        default: // lint-exempt(L-ENUM-1): a code unit
            if isASCIIDigit(current) || current == UInt16(ascii: ".") {
                return lexNumber()
            }
            let consumed = identifierStartLength()
            if consumed != 0 {
                return lexIdentifier(consumed)
            }
        }
        return makeToken(.invalid)
    }

    // The identifier tail of nextToken, out of line: the punctuation cases stay small.
    @inline(never)
    private mutating func lexIdentifier(_ consumed: Int) -> Token {
        var length = consumed
        let startOfToken = position
        shift(consumed)
        let index = is8Bit ? asciiIdentifierRunEnd(latin1, position) : asciiIdentifierRunEnd(utf16, position)
        length += index - position
        shift(from: position, to: index, lines: 0, lineStart: nil)
        while !isAtEndOfFile() {
            let consumed = identifierContinueLength()
            if consumed == 0 {
                break
            }
            length += consumed
            shift(consumed)
        }

        let view = startOfToken..<(startOfToken + Int(currentTokenLength))

        let tokenType = lexerKeywords.get(view, self)
        if tokenType != .invalid {
            return makeToken(tokenType)
        }

        if lexerReservedWordSet.contains(view, self) {
            return makeToken(.reservedWord)
        }

        if length >= 2 && codeUnit(at: startOfToken) == UInt16(ascii: "_")
            && codeUnit(at: startOfToken + 1) == UInt16(ascii: "_")
        {
            return makeToken(.invalid)
        }

        return makeIdentifierToken(view)
    }

    @discardableResult
    @inline(__always)
    private mutating func shift(_ i: Int = 1) -> UInt16 {
        assert(i <= end - position)

        let last = current
        // At one point timing showed that setting m_current to 0 unconditionally was faster than an if-else sequence.
        current = 0
        position += i
        currentPosition.offset &+= UInt32(truncatingIfNeeded: i)
        currentPosition.lineOffset &+= UInt32(truncatingIfNeeded: i)
        if position < end {
            current = codeUnit(at: position)
        }
        return last
    }

    @inline(__always)
    private func peek(_ i: Int = 0) -> UInt16 {
        if i >= end - position {
            return 0
        }
        return codeUnit(at: position + i)
    }

    private mutating func newLine() {
        currentPosition.line &+= 1
        currentPosition.lineOffset = 0
    }

    // shift() over the code units start..<index, which held `lines` "\n", the last one just before lineStart.
    private mutating func shift(from start: Int, to index: Int, lines: UInt32, lineStart: Int?) {
        let count = UInt32(truncatingIfNeeded: index - start)
        position = index
        currentPosition.offset &+= count
        if let lineStart {
            currentPosition.line &+= lines
            currentPosition.lineOffset = UInt32(truncatingIfNeeded: index - lineStart)
        } else {
            currentPosition.lineOffset &+= count
        }
        current = position < end ? codeUnit(at: position) : 0
    }

    private mutating func skipBlockComments() -> Bool {
        assert(peek(0) == UInt16(ascii: "/") && peek(1) == UInt16(ascii: "*"))
        shift(2)

        let start = position
        var index = position
        var lines: UInt32 = 0
        var lineStart: Int?
        var depth: UInt32 = 1
        var closed = false

        while index < end {
            let ch = codeUnit(at: index)
            index += 1
            if ch == 0 {
                break
            }
            if ch == UInt16(ascii: "/") && index < end && codeUnit(at: index) == UInt16(ascii: "*") {
                index += 1
                depth &+= 1
            } else if ch == UInt16(ascii: "*") && index < end && codeUnit(at: index) == UInt16(ascii: "/") {
                index += 1
                depth &-= 1
                if depth == 0 {
                    // This block comment is closed, so for a construction like "/* */ */"
                    // there will be a successfully parsed block comment "/* */"
                    // and " */" will be processed separately.
                    closed = true
                    break
                }
            } else if ch == UInt16(ascii: "\n") {
                lines &+= 1
                lineStart = index
            }
        }

        shift(from: start, to: index, lines: lines, lineStart: lineStart)
        return closed
    }

    private mutating func skipLineComment() -> Bool {
        assert(peek(0) == UInt16(ascii: "/") && peek(1) == UInt16(ascii: "/"))
        // Note that in the case of \r\n this makes the comment end on the \r. It is
        // fine, as the \n after that is simple whitespace.
        let start = position
        var index = position
        var terminated = true
        while index < end {
            let ch = codeUnit(at: index)
            if isLineBreak(ch) {
                break
            }
            if ch == 0 {
                terminated = false
                break
            }
            index += 1
        }
        shift(from: start, to: index, lines: 0, lineStart: nil)
        return terminated
    }

    private mutating func skipWhitespaceAndComments() -> Bool {
        while !isAtEndOfFile() {
            var isWhitespace = isUnicodeCompatibleASCIIWhitespace(current) || current == 0x85
            if !is8Bit {
                isWhitespace = isWhitespace || current == 0x200E || current == 0x200F || current == 0x2028 || current == 0x2029
            }
            if isWhitespace {
                if shift() == UInt16(ascii: "\n") {
                    newLine()
                }
            } else if current == UInt16(ascii: "/") {
                if peek(1) == UInt16(ascii: "/") {
                    if !skipLineComment() {
                        return false
                    }
                } else if peek(1) == UInt16(ascii: "*") {
                    if !skipBlockComments() {
                        return false
                    }
                } else {
                    break
                }
            } else {
                break
            }
        }
        return true
    }

    @inline(__always)
    func isAtEndOfFile() -> Bool {
        if position >= end {
            assert(current == 0)
            return true
        }
        return false
    }

    private mutating func lexNumber() -> Token {
        // Grammar:
        // decimal_int_literal:
        // | /0[iu]?/
        // | /[1-9][0-9]*[iu]?/
        //
        // hex_int_literal :
        // | /0[xX][0-9a-fA-F]+[iu]?/
        //
        // decimal_float_literal:
        // | /0[fh]/`
        // | /[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?[fh]?/
        // | /[0-9]+\.[0-9]*([eE][+-]?[0-9]+)?[fh]?/
        // | /[0-9]+[eE][+-]?[0-9]+[fh]?/
        // | /[1-9][0-9]*[fh]/
        //
        // hex_float_literal:
        // | /0[xX][0-9a-fA-F]*\.[0-9a-fA-F]+([pP][+-]?[0-9]+[fh]?)?/
        // | /0[xX][0-9a-fA-F]+\.[0-9a-fA-F]*([pP][+-]?[0-9]+[fh]?)?/
        // | /0[xX][0-9a-fA-F]+[pP][+-]?[0-9]+[fh]?/

        // State machine:
        // Start -> InitZero (0)
        //       -> Decimal (1-9)
        //       -> FloatFractNoIntegral(.)
        //
        // InitZero -> End (i, u, f, h, ∅)
        //          -> Hex (x, X)
        //          -> Float (0-9)
        //          -> FloatFract(.)
        //          -> FloatExponent(e, E)
        //
        // Decimal -> End (i, u, f, h, ∅)
        //         -> Decimal (0-9)
        //         -> FloatFract(.)
        //         -> FloatExponent(e, E)
        //
        // Float -> Float (0-9)
        //       -> FloatFract(.)
        //       -> FloatExponent(e, E)
        //
        // FloatFractNoIntegral -> FloatFract (0-9)
        //                      -> End(∅)
        //
        // FloatFract -> FloatFract (0-9)
        //            -> FloatExponent(e, E)
        //            -> End(f, h, ∅)
        //
        // FloatExponent -> FloatExponentPostSign(+, -)
        //               -> FloatExponentNonEmpty(0-9)
        //
        // FloatExponentPostSign -> FloatExponentNonEmpty(0-9)
        //
        // FloatExponentNonEmpty -> FloatExponentNonEmpty(0-9)
        //                       -> End(f, h, ∅)
        //
        // Hex -> HexNonEmpty(0-9, a-f, A-F)
        //     -> HexFloatFractNoIntegral(.)
        //
        // HexNonEmpty -> HexNonEmpty(0-9, a-f, A-F)
        //             -> End(i, u, ∅)
        //             -> HexFloatFract(.)
        //             -> HexFloatExponentRequireSuffix(p, P)
        //
        // HexFloatFractNoIntegral -> HexFloatFract(0-9, a-f, A-F)
        //
        // HexFloatFract -> HexFloatFract(0-9, a-f, A-F)
        //               -> HexFloatExponent(p, P)
        //               -> End(∅)
        //
        // HexFloatExponent -> HexFloatExponentNonEmpty(0-9)
        //                  -> HexFloatExponentPostSign(+, -)
        //
        // HexFloatExponentPostSign -> HexFloatExponentNonEmpty(0-9)
        //
        // HexFloatExponentNonEmpty -> HexFloatExponentNonEmpty(0-9)
        //                          -> End(f, h, ∅)
        //
        // HexFloatExponentRequireSuffix -> HexFloatExponentRequireSuffixNonEmpty(0-9)
        //                               -> HexFloatExponentRequireSuffixPostSign(+, -)
        //
        // HexFloatExponentRequireSuffixPostSign -> HexFloatExponentRequireSuffixNonEmpty(0-9)
        //
        // HexFloatExponentRequireSuffixNonEmpty -> HexFloatExponentRequireSuffixNonEmpty(0-9)
        //                                       -> End(f, h)

        var state = NumberState.start
        var suffix = NumberLiteralSuffix.none
        var exponentSign: UInt16 = 0
        var isHex = false
        let start = position
        var integral = position
        var fract: Int?
        var exponent: Int?

        while true {
            switch state {
            case .start:
                switch current {
                case UInt16(ascii: "0"):
                    state = .initZero
                case UInt16(ascii: "."):
                    state = .floatFractNoIntegral
                default: // lint-exempt(L-ENUM-1): a code unit
                    assert(isASCIIDigit(current))
                    state = .decimal
                }

            case .initZero:
                switch current {
                case UInt16(ascii: "i"), UInt16(ascii: "u"), UInt16(ascii: "f"), UInt16(ascii: "h"):
                    state = .end
                    suffix = numberLiteralSuffix(current)

                case UInt16(ascii: "x"), UInt16(ascii: "X"):
                    state = .hex

                case UInt16(ascii: "."):
                    state = .floatFract

                case UInt16(ascii: "e"), UInt16(ascii: "E"):
                    state = .floatExponent

                default: // lint-exempt(L-ENUM-1): a code unit
                    if isASCIIDigit(current) {
                        state = .float
                    } else {
                        state = .endNoShift
                    }
                }

            case .decimal:
                switch current {
                case UInt16(ascii: "i"), UInt16(ascii: "u"), UInt16(ascii: "f"), UInt16(ascii: "h"):
                    state = .end
                    suffix = numberLiteralSuffix(current)

                case UInt16(ascii: "."):
                    state = .floatFract

                case UInt16(ascii: "e"), UInt16(ascii: "E"):
                    state = .floatExponent

                default: // lint-exempt(L-ENUM-1): a code unit
                    if !isASCIIDigit(current) {
                        state = .endNoShift
                    }
                }

            case .float:
                switch current {
                case UInt16(ascii: "."):
                    state = .floatFract

                case UInt16(ascii: "e"), UInt16(ascii: "E"):
                    state = .floatExponent

                default: // lint-exempt(L-ENUM-1): a code unit
                    if !isASCIIDigit(current) {
                        return makeToken(.invalid)
                    }
                }
            case .floatFractNoIntegral:
                fract = position
                if !isASCIIDigit(current) {
                    return makeToken(.period)
                }
                state = .floatFract
            case .floatFract:
                if fract == nil {
                    fract = position
                }
                switch current {
                case UInt16(ascii: "f"), UInt16(ascii: "h"):
                    state = .end
                    suffix = numberLiteralSuffix(current)

                case UInt16(ascii: "e"), UInt16(ascii: "E"):
                    state = .floatExponent

                default: // lint-exempt(L-ENUM-1): a code unit
                    if !isASCIIDigit(current) {
                        state = .endNoShift
                    }
                }
            case .floatExponent:
                exponent = position
                switch current {
                case UInt16(ascii: "+"), UInt16(ascii: "-"):
                    exponentSign = current
                    state = .floatExponentPostSign
                default: // lint-exempt(L-ENUM-1): a code unit
                    if !isASCIIDigit(current) {
                        return makeToken(.invalid)
                    }
                    state = .floatExponentNonEmpty
                }
            case .floatExponentPostSign:
                if exponentSign == UInt16(ascii: "+") {
                    exponent = position
                }
                if !isASCIIDigit(current) {
                    return makeToken(.invalid)
                }
                state = .floatExponentNonEmpty
            case .floatExponentNonEmpty:
                switch current {
                case UInt16(ascii: "f"), UInt16(ascii: "h"):
                    state = .end
                    suffix = numberLiteralSuffix(current)
                default: // lint-exempt(L-ENUM-1): a code unit
                    if !isASCIIDigit(current) {
                        state = .endNoShift
                    }
                }
            case .hex:
                isHex = true
                integral = position
                if current == UInt16(ascii: ".") {
                    state = .hexFloatFractNoIntegral
                } else if isASCIIHexDigit(current) {
                    state = .hexNonEmpty
                } else {
                    return makeToken(.invalid)
                }
            case .hexNonEmpty:
                switch current {
                case UInt16(ascii: "i"), UInt16(ascii: "u"):
                    state = .end
                    suffix = numberLiteralSuffix(current)

                case UInt16(ascii: "p"), UInt16(ascii: "P"):
                    state = .hexFloatExponentRequireSuffix

                case UInt16(ascii: "."):
                    state = .hexFloatFract

                default: // lint-exempt(L-ENUM-1): a code unit
                    if !isASCIIHexDigit(current) {
                        state = .endNoShift
                    }
                }
            case .hexFloatFractNoIntegral:
                fract = position
                if !isASCIIHexDigit(current) {
                    return makeToken(.invalid)
                }
                state = .hexFloatFract
            case .hexFloatFract:
                if fract == nil {
                    fract = position
                }
                if isASCIIHexDigit(current) {
                    break
                }
                if current == UInt16(ascii: "p") || current == UInt16(ascii: "P") {
                    state = .hexFloatExponent
                } else {
                    state = .endNoShift
                }
            case .hexFloatExponent:
                exponent = position
                if isASCIIDigit(current) {
                    state = .hexFloatExponentNonEmpty
                } else if current == UInt16(ascii: "+") || current == UInt16(ascii: "-") {
                    exponentSign = current
                    state = .hexFloatExponentPostSign
                } else {
                    return makeToken(.invalid)
                }
            case .hexFloatExponentPostSign:
                if exponentSign == UInt16(ascii: "+") {
                    exponent = position
                }
                if isASCIIDigit(current) {
                    state = .hexFloatExponentNonEmpty
                    break
                }
                return makeToken(.invalid)
            case .hexFloatExponentNonEmpty:
                if isASCIIDigit(current) {
                    state = .hexFloatExponentNonEmpty
                } else if current == UInt16(ascii: "f") || current == UInt16(ascii: "h") {
                    state = .end
                    suffix = numberLiteralSuffix(current)
                } else {
                    state = .endNoShift
                }
            case .hexFloatExponentRequireSuffix:
                exponent = position
                if isASCIIDigit(current) {
                    state = .hexFloatExponentRequireSuffixNonEmpty
                } else if current == UInt16(ascii: "+") || current == UInt16(ascii: "-") {
                    exponentSign = current
                    state = .hexFloatExponentRequireSuffixPostSign
                } else {
                    return makeToken(.invalid)
                }
            case .hexFloatExponentRequireSuffixPostSign:
                if exponentSign == UInt16(ascii: "+") {
                    exponent = position
                }
                if isASCIIDigit(current) {
                    state = .hexFloatExponentRequireSuffixNonEmpty
                    break
                }
                return makeToken(.invalid)
            case .hexFloatExponentRequireSuffixNonEmpty:
                if isASCIIDigit(current) {
                    state = .hexFloatExponentNonEmpty
                } else if current == UInt16(ascii: "f") || current == UInt16(ascii: "h") {
                    state = .end
                    suffix = numberLiteralSuffix(current)
                } else {
                    return makeToken(.invalid)
                }
            case .end, .endNoShift:
                wgslFatal("lexNumber ran past its end state", cppSite: "Lexer.cpp:1022")
            }

            if state == .endNoShift {
                break
            }
            shift()
            if state == .end {
                break
            }
        }

        let scan = NumberLiteralScan(
            start: start,
            integral: integral,
            end: position,
            suffix: suffix,
            isHex: isHex,
            hasFraction: fract != nil,
            hasExponent: exponent != nil
        )
        let literal = is8Bit ? NumberParsing.literal(latin1, scan) : NumberParsing.literal(utf16, scan, &numberBytes)
        switch literal {
        case .invalid:
            return makeToken(.invalid)
        case .integerLiteral(let value):
            return makeIntegerToken(.integerLiteral, value)
        case .integerLiteralSigned(let value):
            return makeIntegerToken(.integerLiteralSigned, Int64(value))
        case .integerLiteralUnsigned(let value):
            return makeIntegerToken(.integerLiteralUnsigned, Int64(value))
        case .abstractFloatLiteral(let value):
            return makeFloatToken(.abstractFloatLiteral, value)
        case .floatLiteral(let value):
            return makeFloatToken(.floatLiteral, Double(value))
        case .halfLiteral(let value):
            return makeFloatToken(.halfLiteral, Double(Half(value)))
        }
    }

    // MARK: - Code units

    @inline(__always)
    fileprivate func codeUnit(at index: Int) -> UInt16 {
        is8Bit ? UInt16(latin1[index]) : utf16[index]
    }

    // isIdentifierStart(m_current, m_code.span()) for this representation.
    @inline(__always)
    private func identifierStartLength() -> Int {
        if is8Bit {
            return isIdentifierStart(UInt8(truncatingIfNeeded: current), identifierCharacterClasses)
        }
        return isIdentifierStart(current, utf16, position, identifierCharacterClasses)
    }

    // isIdentifierContinue(m_current, m_code.span()) for this representation.
    @inline(__always)
    private func identifierContinueLength() -> Int {
        if is8Bit {
            return isIdentifierContinue(UInt8(truncatingIfNeeded: current), identifierCharacterClasses)
        }
        return isIdentifierContinue(current, utf16, position, identifierCharacterClasses)
    }
}

// MARK: - lexNumber

private enum NumberState {
    case start

    case initZero
    case decimal

    case float
    case floatFractNoIntegral
    case floatFract
    case floatExponent
    case floatExponentPostSign
    case floatExponentNonEmpty

    case hex
    case hexNonEmpty
    case hexFloatFractNoIntegral
    case hexFloatFract
    case hexFloatExponent
    case hexFloatExponentPostSign
    case hexFloatExponentNonEmpty
    case hexFloatExponentRequireSuffix
    case hexFloatExponentRequireSuffixPostSign
    case hexFloatExponentRequireSuffixNonEmpty

    case end
    case endNoShift
}

private func numberLiteralSuffix(_ character: UInt16) -> NumberLiteralSuffix {
    switch character {
    case UInt16(ascii: "i"):
        .i
    case UInt16(ascii: "u"):
        .u
    case UInt16(ascii: "f"):
        .f
    case UInt16(ascii: "h"):
        .h
    default: // lint-exempt(L-ENUM-1): a code unit
        wgslFatal("not a number literal suffix", cppSite: "Lexer.cpp:761")
    }
}

// MARK: - Keywords and reserved words

// The C++ SortedArrayMap / SortedArraySet of ASCII literals: exact code-unit matches. The C++ searches by binary search;
// here a lookup compares only the words with the text's length and first code unit.
private struct SortedWordTable: Sendable {
    private let text: [UInt8]
    private let starts: [Int]
    private let tokenTypes: [TokenType]
    // The word indices ordered by length, then first code unit; `buckets[length * 128 + first]` is the range of `order`
    // with that length and first code unit, as start << 8 | count.
    private let order: [Int]
    private let buckets: [UInt32]
    private let maxLength: Int

    init(_ words: [(StaticString, TokenType)]) {
        var text: [UInt8] = []
        var starts: [Int] = [0]
        var tokenTypes: [TokenType] = []
        var maxLength = 0
        var index = 0
        while index < words.count {
            text.append(contentsOf: words[index].0.description.utf8)
            starts.append(text.count)
            tokenTypes.append(words[index].1)
            maxLength = Swift.max(maxLength, starts[index + 1] - starts[index])
            index += 1
        }
        func bucket(_ word: Int) -> Int {
            (starts[word + 1] - starts[word]) * 128 + Int(text[starts[word]])
        }
        var counts = [Int](repeating: 0, count: (maxLength + 1) * 128 + 1)
        index = 0
        while index < tokenTypes.count {
            counts[bucket(index) + 1] += 1
            index += 1
        }
        var buckets = [UInt32](repeating: 0, count: (maxLength + 1) * 128)
        index = 0
        while index < buckets.count {
            buckets[index] = UInt32(counts[index]) << 8 | UInt32(counts[index + 1])
            counts[index + 1] += counts[index]
            index += 1
        }
        var order = [Int](repeating: 0, count: tokenTypes.count)
        index = 0
        while index < tokenTypes.count {
            order[counts[bucket(index)]] = index
            counts[bucket(index)] += 1
            index += 1
        }
        self.text = text
        self.starts = starts
        self.tokenTypes = tokenTypes
        self.order = order
        self.buckets = buckets
        self.maxLength = maxLength
        assert(isSorted)
    }

    // The value for `range`'s text, or .invalid (the C++ SortedArrayMap's default value).
    // Inlined, as the lexer's readers: a call takes a copy of the lexer.
    @inline(__always)
    func get(_ range: Range<Int>, _ lexer: borrowing Lexer) -> TokenType {
        guard let index = find(range, lexer) else {
            return .invalid
        }
        return tokenTypes[index]
    }

    @inline(__always)
    func contains(_ range: Range<Int>, _ lexer: borrowing Lexer) -> Bool {
        find(range, lexer) != nil
    }

    @inline(__always)
    private func find(_ range: Range<Int>, _ lexer: borrowing Lexer) -> Int? {
        let length = range.count
        guard length > 0 && length <= maxLength else {
            return nil
        }
        let first = lexer.codeUnit(at: range.lowerBound)
        guard first < 128 else {
            return nil
        }
        let bucket = buckets[length * 128 + Int(first)]
        var position = Int(bucket >> 8)
        let end = position + Int(bucket & 0xFF)
        while position < end {
            let word = order[position]
            if matches(word, range, lexer) {
                return word
            }
            position += 1
        }
        return nil
    }

    // Whether word `index`, of the same length and first code unit as the text of `range`, spells it.
    @inline(__always)
    private func matches(_ index: Int, _ range: Range<Int>, _ lexer: borrowing Lexer) -> Bool {
        let wordStart = starts[index]
        var offset = 1
        while offset < range.count {
            if UInt16(text[wordStart + offset]) != lexer.codeUnit(at: range.lowerBound + offset) {
                return false
            }
            offset += 1
        }
        return true
    }

    private var isSorted: Bool {
        var index = 1
        while index < tokenTypes.count {
            guard compareWords(index - 1, index) < 0 else {
                return false
            }
            index += 1
        }
        return true
    }

    private func compareWords(_ a: Int, _ b: Int) -> Int {
        let aLength = starts[a + 1] - starts[a]
        let bLength = starts[b + 1] - starts[b]
        var offset = 0
        while offset < aLength && offset < bLength {
            let aUnit = text[starts[a] + offset]
            let bUnit = text[starts[b] + offset]
            if aUnit != bUnit {
                return aUnit < bUnit ? -1 : 1
            }
            offset += 1
        }
        if aLength == bLength {
            return 0
        }
        return aLength < bLength ? -1 : 1
    }
}

private let lexerKeywords = SortedWordTable([
    ("_", .underbar),

    ("alias", .keywordAlias),
    ("break", .keywordBreak),
    ("case", .keywordCase),
    ("const", .keywordConst),
    ("const_assert", .keywordConstAssert),
    ("continue", .keywordContinue),
    ("continuing", .keywordContinuing),
    ("default", .keywordDefault),
    ("diagnostic", .keywordDiagnostic),
    ("discard", .keywordDiscard),
    ("else", .keywordElse),
    ("enable", .keywordEnable),
    ("false", .keywordFalse),
    ("fn", .keywordFn),
    ("for", .keywordFor),
    ("if", .keywordIf),
    ("let", .keywordLet),
    ("loop", .keywordLoop),
    ("override", .keywordOverride),
    ("requires", .keywordRequires),
    ("return", .keywordReturn),
    ("struct", .keywordStruct),
    ("switch", .keywordSwitch),
    ("true", .keywordTrue),
    ("var", .keywordVar),
    ("while", .keywordWhile),
])

// https://www.w3.org/TR/WGSL/#reserved-words
private let lexerReservedWordSet = SortedWordTable([
    ("NULL", .reservedWord),
    ("Self", .reservedWord),
    ("abstract", .reservedWord),
    ("active", .reservedWord),
    ("alignas", .reservedWord),
    ("alignof", .reservedWord),
    ("as", .reservedWord),
    ("asm", .reservedWord),
    ("asm_fragment", .reservedWord),
    ("async", .reservedWord),
    ("attribute", .reservedWord),
    ("auto", .reservedWord),
    ("await", .reservedWord),
    ("become", .reservedWord),
    ("cast", .reservedWord),
    ("catch", .reservedWord),
    ("class", .reservedWord),
    ("co_await", .reservedWord),
    ("co_return", .reservedWord),
    ("co_yield", .reservedWord),
    ("coherent", .reservedWord),
    ("column_major", .reservedWord),
    ("common", .reservedWord),
    ("compile", .reservedWord),
    ("compile_fragment", .reservedWord),
    ("concept", .reservedWord),
    ("const_cast", .reservedWord),
    ("consteval", .reservedWord),
    ("constexpr", .reservedWord),
    ("constinit", .reservedWord),
    ("crate", .reservedWord),
    ("debugger", .reservedWord),
    ("decltype", .reservedWord),
    ("delete", .reservedWord),
    ("demote", .reservedWord),
    ("demote_to_helper", .reservedWord),
    ("do", .reservedWord),
    ("dynamic_cast", .reservedWord),
    ("enum", .reservedWord),
    ("explicit", .reservedWord),
    ("export", .reservedWord),
    ("extends", .reservedWord),
    ("extern", .reservedWord),
    ("external", .reservedWord),
    ("fallthrough", .reservedWord),
    ("filter", .reservedWord),
    ("final", .reservedWord),
    ("finally", .reservedWord),
    ("friend", .reservedWord),
    ("from", .reservedWord),
    ("fxgroup", .reservedWord),
    ("get", .reservedWord),
    ("goto", .reservedWord),
    ("groupshared", .reservedWord),
    ("highp", .reservedWord),
    ("impl", .reservedWord),
    ("implements", .reservedWord),
    ("import", .reservedWord),
    ("inline", .reservedWord),
    ("instanceof", .reservedWord),
    ("interface", .reservedWord),
    ("layout", .reservedWord),
    ("lowp", .reservedWord),
    ("macro", .reservedWord),
    ("macro_rules", .reservedWord),
    ("match", .reservedWord),
    ("mediump", .reservedWord),
    ("meta", .reservedWord),
    ("mod", .reservedWord),
    ("module", .reservedWord),
    ("move", .reservedWord),
    ("mut", .reservedWord),
    ("mutable", .reservedWord),
    ("namespace", .reservedWord),
    ("new", .reservedWord),
    ("nil", .reservedWord),
    ("noexcept", .reservedWord),
    ("noinline", .reservedWord),
    ("nointerpolation", .reservedWord),
    ("non_coherent", .reservedWord),
    ("noncoherent", .reservedWord),
    ("noperspective", .reservedWord),
    ("null", .reservedWord),
    ("nullptr", .reservedWord),
    ("of", .reservedWord),
    ("operator", .reservedWord),
    ("package", .reservedWord),
    ("packoffset", .reservedWord),
    ("partition", .reservedWord),
    ("pass", .reservedWord),
    ("patch", .reservedWord),
    ("pixelfragment", .reservedWord),
    ("precise", .reservedWord),
    ("precision", .reservedWord),
    ("premerge", .reservedWord),
    ("priv", .reservedWord),
    ("protected", .reservedWord),
    ("pub", .reservedWord),
    ("public", .reservedWord),
    ("readonly", .reservedWord),
    ("ref", .reservedWord),
    ("regardless", .reservedWord),
    ("register", .reservedWord),
    ("reinterpret_cast", .reservedWord),
    ("require", .reservedWord),
    ("resource", .reservedWord),
    ("restrict", .reservedWord),
    ("self", .reservedWord),
    ("set", .reservedWord),
    ("shared", .reservedWord),
    ("sizeof", .reservedWord),
    ("smooth", .reservedWord),
    ("snorm", .reservedWord),
    ("static", .reservedWord),
    ("static_assert", .reservedWord),
    ("static_cast", .reservedWord),
    ("std", .reservedWord),
    ("subroutine", .reservedWord),
    ("super", .reservedWord),
    ("target", .reservedWord),
    ("template", .reservedWord),
    ("this", .reservedWord),
    ("thread_local", .reservedWord),
    ("throw", .reservedWord),
    ("trait", .reservedWord),
    ("try", .reservedWord),
    ("type", .reservedWord),
    ("typedef", .reservedWord),
    ("typeid", .reservedWord),
    ("typename", .reservedWord),
    ("typeof", .reservedWord),
    ("union", .reservedWord),
    ("unless", .reservedWord),
    ("unorm", .reservedWord),
    ("unsafe", .reservedWord),
    ("unsized", .reservedWord),
    ("use", .reservedWord),
    ("using", .reservedWord),
    ("varying", .reservedWord),
    ("virtual", .reservedWord),
    ("volatile", .reservedWord),
    ("wgsl", .reservedWord),
    ("where", .reservedWord),
    ("with", .reservedWord),
    ("writeonly", .reservedWord),
    ("yield", .reservedWord),
])

// MARK: - Character classes

extension UInt16 {
    fileprivate init(ascii scalar: Unicode.Scalar) { self = UInt16(UInt8(ascii: scalar)) }
}

private func isASCIIDigit(_ character: UInt16) -> Bool {
    character >= UInt16(ascii: "0") && character <= UInt16(ascii: "9")
}

private func isASCIIHexDigit(_ character: UInt16) -> Bool {
    isASCIIDigit(character) || ((character | 0x20) >= UInt16(ascii: "a") && (character | 0x20) <= UInt16(ascii: "f"))
}

private func isASCIIAlpha(_ character: UInt16) -> Bool {
    (character | 0x20) >= UInt16(ascii: "a") && (character | 0x20) <= UInt16(ascii: "z")
}

private func isASCIIAlphanumeric(_ character: UInt16) -> Bool {
    isASCIIDigit(character) || isASCIIAlpha(character)
}

private func isUnicodeCompatibleASCIIWhitespace(_ character: UInt16) -> Bool {
    character == UInt16(ascii: " ") || character == UInt16(ascii: "\n") || character == UInt16(ascii: "\t")
        || character == UInt16(ascii: "\r") || character == 0x0C || character == 0x0B
}

private func isSurrogate(_ character: UInt16) -> Bool {
    character & 0xF800 == 0xD800
}

// The code point of u_stringHasBinaryProperty(code + index, length, …), which holds only for a string of exactly one
// code point: one non-surrogate unit, or a lead and a trail surrogate. A lone surrogate is never XID.
private func singleCodePoint(_ code: borrowing ContiguousArray<UInt16>, _ index: Int, _ length: Int) -> UInt32? {
    let lead = code[index]
    if length == 1 {
        return isSurrogate(lead) ? nil : UInt32(lead)
    }
    let trail = code[index + 1]
    guard lead & 0xFC00 == 0xD800, trail & 0xFC00 == 0xDC00 else {
        return nil
    }
    return 0x10000 + ((UInt32(lead) & 0x3FF) << 10) + (UInt32(trail) & 0x3FF)
}
