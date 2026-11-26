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

private enum RadixLiteral {
    case hexadecimal
    case binary
    case octal

    var radix: UInt8 {
        switch self {
        case .hexadecimal: 16
        case .binary: 2
        case .octal: 8
        }
    }

    var missingDigitsMessage: Swift.String {
        switch self {
        case .hexadecimal: "No hexadecimal digits after '0x'"
        case .binary: "No binary digits after '0b'"
        case .octal: "No octal digits after '0o'"
        }
    }

    var errorToken: JSC.JSTokenType {
        switch self {
        case .hexadecimal: .unterminatedHexNumberError
        case .binary: .unterminatedBinaryNumberError
        case .octal: .unterminatedOctalNumberError
        }
    }

    func hasDigit<Unit: LexerCodePoint>(_ character: Unit) -> Bool {
        switch self {
        case .hexadecimal: character.isASCIIHexDigit
        case .binary: character.isASCIIBinaryDigit
        case .octal: character.isASCIIOctalDigit
        }
    }
}

// The decimal scanner of DecimalNumberScanner.h, with the same limit on the digits of the mantissa. It does not read a
// fraction eight digits at a time, as that scanner does.
private let maxMantissaDigitsForDecimalNumber = 19

private struct ScannedDecimalNumber {
    var end: Int
    var mantissa: UInt64
    var exponent: Int64
    var digitCount: Int
}

extension Lexer {
    // MARK: Number tokens

    /// The number that starts with a '.' the cursor has passed; the current character is a digit.
    mutating func lexNumberAfterDot(_ data: inout TokenData, _ facade: inout JSC.JSParseFacade) -> JSC.JSTokenType {
        let type = lexDecimalWithoutSeparators(&data, start: code - 1, integerEnd: code - 1, integerValue: 0, &facade)
        if type != .error {
            return type
        }
        if !parseNumberAfterDecimalPoint() {
            errorMessage = .text("Non-number found after decimal point")
            return atEnd ? .unterminatedNumericLiteralError : .invalidNumericLiteralError
        }
        if current.isASCIIAlphaCaselessEqual(.ascii("e")) && !parseNumberAfterExponentIndicator() {
            errorMessage = .text("Non-number found after exponent indicator")
            return atEnd ? .unterminatedNumericLiteralError : .invalidNumericLiteralError
        }
        var parsedLength = 0
        data.doubleValue = facade.parseDouble8(buffer8.span, &parsedLength)

        return finishNumber(
            .double,
            identifierMessage: .text("No identifiers allowed directly after numeric literal"),
            errorToken: atEnd ? .unterminatedNumericLiteralError : .invalidNumericLiteralError
        )
    }

    /// The number token that starts at the cursor, whose first character is a digit.
    mutating func lexNumber(_ data: inout TokenData, strictMode: Bool, _ facade: inout JSC.JSParseFacade) -> JSC.JSTokenType {
        var token = JSC.JSTokenType.error

        if current == .ascii("0") {
            shift()
            if current.isASCIIAlphaCaselessEqual(.ascii("x")) {
                return lexRadixLiteral(.hexadecimal, &data, &facade)
            }
            if current.isASCIIAlphaCaselessEqual(.ascii("b")) {
                return lexRadixLiteral(.binary, &data, &facade)
            }
            if current.isASCIIAlphaCaselessEqual(.ascii("o")) {
                return lexRadixLiteral(.octal, &data, &facade)
            }

            if current == .ascii("_") {
                errorMessage = .text("Numeric literals may not begin with 0_")
                return .unterminatedOctalNumberError
            }
            if strictMode && current.isASCIIDigit {
                errorMessage = .text("Decimal integer literals with a leading zero are forbidden in strict mode")
                return .unterminatedOctalNumberError
            }

            if current.isASCIIOctalDigit {
                record8(.ascii("0"))
                if case .number(let value)? = parseOctal(&facade) {
                    data.doubleValue = value
                    token = JSC.JSTokenType(integerLike: value)
                }
            } else {
                if !current.isASCIIDigit && current != .ascii(".") && current.cannotBeIdentStart {
                    data.doubleValue = 0
                    return .integer
                }
                if current == .ascii(".") || current.isASCIIAlphaCaselessEqual(.ascii("e")) {
                    let type = lexDecimalWithoutSeparators(&data, start: code - 1, integerEnd: code, integerValue: 0, &facade)
                    if type != .error {
                        return type
                    }
                }
                record8(.ascii("0"))
            }
        }

        if token != .integer && token != .double {
            if buffer8.isEmpty {
                let start = code
                var pointer = code + 1
                var result = UInt64(source[start] &- .ascii("0"))
                while pointer < codeEnd && source[pointer].isASCIIDigit {
                    result = result &* 10 &+ UInt64(source[pointer] &- .ascii("0"))
                    pointer += 1
                }

                if pointer < codeEnd && (source[pointer] != .ascii(".") && source[pointer].cannotBeIdentStart)
                    && pointer - start <= Self.numberOfDigitsForSafeInt52
                {
                    data.doubleValue = Double(result)
                    code = pointer
                    current = source[pointer]
                    return .integer
                }

                // Separators, BigInt suffixes, and identifiers cannot follow a literal that the fast path accepts.
                if pointer == codeEnd || source[pointer] == .ascii(".") || source[pointer].isASCIIAlphaCaselessEqual(.ascii("e"))
                    || source[pointer].cannotBeIdentStart
                {
                    let type = lexDecimalWithoutSeparators(&data, start: start, integerEnd: pointer, integerValue: result, &facade)
                    if type != .error {
                        return type
                    }
                }
            }

            if let parsed = parseDecimal(&facade) {
                switch parsed {
                case .number(let value):
                    data.doubleValue = value
                    token = JSC.JSTokenType(integerLike: value)
                case .bigInt(let digits):
                    token = .bigInt
                    shift()
                    data.bigIntString = digits
                    data.radix = 10
                }
            } else {
                token = .integer
                if current == .ascii(".") {
                    shift()
                    if current.isASCIIDigit && !parseNumberAfterDecimalPoint() {
                        errorMessage = .text("Non-number found after decimal point")
                        return atEnd ? .unterminatedNumericLiteralError : .invalidNumericLiteralError
                    }
                    token = .double
                }
                if current.isASCIIAlphaCaselessEqual(.ascii("e")) && !parseNumberAfterExponentIndicator() {
                    errorMessage = .text("Non-number found after exponent indicator")
                    return atEnd ? .unterminatedNumericLiteralError : .invalidNumericLiteralError
                }
                var parsedLength = 0
                data.doubleValue = facade.parseDouble8(buffer8.span, &parsedLength)
                if token == .integer {
                    token = JSC.JSTokenType(integerLike: data.doubleValue)
                }
            }
        }

        return finishNumber(
            token,
            identifierMessage: .text("No identifiers allowed directly after numeric literal"),
            errorToken: atEnd ? .unterminatedNumericLiteralError : .invalidNumericLiteralError
        )
    }

    /// A hexadecimal, binary or octal literal; the cursor is at its prefix letter.
    private mutating func lexRadixLiteral(
        _ literal: RadixLiteral,
        _ data: inout TokenData,
        _ facade: inout JSC.JSParseFacade
    )
        -> JSC.JSTokenType
    {
        if !literal.hasDigit(peek(1)) {
            errorMessage = .text(literal.missingDigitsMessage)
            return literal.errorToken
        }

        // Shift out the prefix letter.
        shift()

        let parsed: NumberParseResult?
        switch literal {
        case .hexadecimal: parsed = parseHex(&facade)
        case .binary: parsed = parseBinary(&facade)
        case .octal: parsed = parseOctal(&facade)
        }

        var token = JSC.JSTokenType.error
        switch parsed {
        case nil:
            data.doubleValue = 0
        case .number(let value)?:
            data.doubleValue = value
        case .bigInt(let digits)?:
            token = .bigInt
            shift()
            data.bigIntString = digits
            data.radix = literal.radix
        }

        if token != .bigInt {
            token = JSC.JSTokenType(integerLike: data.doubleValue)
        }
        return finishNumber(token, identifierMessage: .identifierAfterRadixLiteral(radix: literal.radix), errorToken: literal.errorToken)
    }

    // MARK: Number parts

    /// The end of a number lexer: `token` when no identifier character follows the literal, otherwise `errorToken`.
    @inline(always)
    private mutating func finishNumber(
        _ token: JSC.JSTokenType,
        identifierMessage: LexerErrorMessage,
        errorToken: JSC.JSTokenType
    ) -> JSC.JSTokenType {
        if current.cannotBeIdentStart {
            buffer8.removeAll()
            return token
        }
        if let codePoint = currentCodePoint, codePoint.isIdentStart {
            errorMessage = identifierMessage
            return errorToken
        }
        buffer8.removeAll()
        return token
    }

    /// Records the digits of `start..<code` the lexer consumed: everything but numeric separators.
    private mutating func recordDigits(from start: Int) {
        var index = start
        while index < code {
            let character = source[index]
            if character != .ascii("_") {
                record8(UInt8(truncatingIfNeeded: character))
            }
            index += 1
        }
    }

    private mutating func parseHex(_ facade: inout JSC.JSParseFacade) -> NumberParseResult? {
        assert(current.isASCIIHexDigit)
        // Most hexadecimal values fit into 4 bytes.
        var hexValue: UInt32 = 0
        var maximumDigits = 7

        repeat {
            if current == .ascii("_") {
                if !peek(1).isASCIIHexDigit {
                    return nil
                }
                shift()
            }
            hexValue = (hexValue << 4) &+ UInt32(current.asciiHexValue)
            shift()
            maximumDigits -= 1
        } while current.isASCIIHexDigitOrSeparator && maximumDigits >= 0

        if maximumDigits >= 0 && current != .ascii("n") {
            return .number(Double(hexValue))
        }

        // No more place in the hexValue buffer. The values are shifted out and placed into the buffer.
        for _ in 0..<8 {
            let digit = UInt8(truncatingIfNeeded: hexValue >> 28)
            record8(digit < 10 ? digit + .ascii("0") : digit - 10 + .ascii("a"))
            hexValue <<= 4
        }

        while current.isASCIIHexDigitOrSeparator {
            if current == .ascii("_") {
                if !peek(1).isASCIIHexDigit {
                    return nil
                }
                shift()
            }
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        }

        if current == .ascii("n") {
            return .bigInt(UInt8.makeIdentifier(buffer8.span, &facade))
        }
        return .number(JSC.parseIntOverflow8(buffer8.span, 16))
    }

    private mutating func parseBinary(_ facade: inout JSC.JSParseFacade) -> NumberParseResult? {
        assert(current.isASCIIBinaryDigit)
        let start = code

        // Most binary values fit into 4 bytes.
        var binaryValue: UInt32 = 0
        let maximumDigits = 32
        var digit = maximumDigits - 1

        repeat {
            if current == .ascii("_") {
                if !peek(1).isASCIIBinaryDigit {
                    return nil
                }
                shift()
            }
            binaryValue = (binaryValue << 1) &+ UInt32(current &- .ascii("0"))
            shift()
            digit -= 1
        } while current.isASCIIBinaryDigitOrSeparator && digit >= 0

        if !current.isASCIIDigitOrSeparator && digit >= 0 && current != .ascii("n") {
            return .number(Double(binaryValue))
        }

        recordDigits(from: start)

        while current.isASCIIBinaryDigitOrSeparator {
            if current == .ascii("_") {
                if !peek(1).isASCIIBinaryDigit {
                    return nil
                }
                shift()
            }
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        }

        if current == .ascii("n") {
            return .bigInt(UInt8.makeIdentifier(buffer8.span, &facade))
        }
        if current.isASCIIDigit {
            return nil
        }
        return .number(JSC.parseIntOverflow8(buffer8.span, 2))
    }

    /// The digits of a legacy octal literal (after a recorded '0') or of a literal with the 0o prefix.
    private mutating func parseOctal(_ facade: inout JSC.JSParseFacade) -> NumberParseResult? {
        assert(current.isASCIIOctalDigit)
        assert(buffer8.isEmpty || (buffer8.count == 1 && buffer8[0] == .ascii("0")))
        let isLegacyLiteral = !buffer8.isEmpty
        let start = code

        // Most octal values fit into 4 bytes.
        var octalValue: UInt32 = 0
        let maximumDigits = 10
        var digit = maximumDigits - 1

        repeat {
            if current == .ascii("_") {
                if !peek(1).isASCIIOctalDigit || isLegacyLiteral {
                    return nil
                }
                shift()
            }
            octalValue = octalValue &* 8 &+ UInt32(current &- .ascii("0"))
            shift()
            digit -= 1
        } while current.isASCIIOctalDigitOrSeparator && digit >= 0

        if !current.isASCIIDigitOrSeparator && digit >= 0 && current != .ascii("n") {
            return .number(Double(octalValue))
        }

        recordDigits(from: start)

        while current.isASCIIOctalDigitOrSeparator {
            if current == .ascii("_") {
                if !peek(1).isASCIIOctalDigit || isLegacyLiteral {
                    return nil
                }
                shift()
            }
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        }

        if current == .ascii("n") && !isLegacyLiteral {
            return .bigInt(UInt8.makeIdentifier(buffer8.span, &facade))
        }
        if current.isASCIIDigit {
            return nil
        }
        return .number(JSC.parseIntOverflow8(buffer8.span, 8))
    }

    private mutating func parseDecimal(_ facade: inout JSC.JSParseFacade) -> NumberParseResult? {
        assert(current.isASCIIDigit || !buffer8.isEmpty)
        let isLegacyLiteral = !buffer8.isEmpty && current.isASCIIDigitOrSeparator

        // parseOctal may have run first, leaving digits in the buffer.
        if buffer8.isEmpty {
            let start = code

            // Most decimal values fit into 4 bytes.
            var decimalValue: UInt32 = 0
            let maximumDigits = 10
            var digit = maximumDigits - 1

            repeat {
                if current == .ascii("_") {
                    if !peek(1).isASCIIDigit || isLegacyLiteral {
                        return nil
                    }
                    shift()
                }
                decimalValue = decimalValue &* 10 &+ UInt32(current &- .ascii("0"))
                shift()
                digit -= 1
            } while current.isASCIIDigitOrSeparator && digit >= 0

            if digit >= 0 && current != .ascii(".") && !current.isASCIIAlphaCaselessEqual(.ascii("e")) && current != .ascii("n") {
                return .number(Double(decimalValue))
            }

            recordDigits(from: start)
        }

        while current.isASCIIDigitOrSeparator {
            if current == .ascii("_") {
                if !peek(1).isASCIIDigit || isLegacyLiteral {
                    return nil
                }
                shift()
            }
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        }

        if current == .ascii("n") && !isLegacyLiteral {
            return .bigInt(UInt8.makeIdentifier(buffer8.span, &facade))
        }
        return nil
    }

    private mutating func parseNumberAfterDecimalPoint() -> Bool {
        record8(.ascii("."))

        repeat {
            if current == .ascii("_") {
                if !peek(1).isASCIIDigit {
                    return false
                }
                shift()
            }
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        } while current.isASCIIDigitOrSeparator

        return true
    }

    private mutating func parseNumberAfterExponentIndicator() -> Bool {
        record8(.ascii("e"))
        shift()
        if current == .ascii("+") || current == .ascii("-") {
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        }

        if !current.isASCIIDigit {
            return false
        }

        repeat {
            if current == .ascii("_") {
                if !peek(1).isASCIIDigit {
                    return false
                }
                shift()
            }
            record8(UInt8(truncatingIfNeeded: current))
            shift()
        } while current.isASCIIDigitOrSeparator

        return true
    }

    // MARK: Decimals scanned in place

    // Converts a decimal literal as it is scanned, rather than copying it into buffer8 for parseDouble8. If the literal has
    // separators, a BigInt suffix, too many digits, or a syntax error, or is directly followed by an identifier, this consumes
    // nothing and returns .error so that the general path handles it. Kept out of line so that lexing short integers, the
    // most common literals, does not pay for it.
    @inline(never)
    mutating func lexDecimalWithoutSeparators(
        _ data: inout TokenData,
        start: Int,
        integerEnd: Int,
        integerValue: UInt64,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        guard let decimal = scanDecimalNumber(start: start, integerEnd: integerEnd, integer: integerValue) else {
            return .error
        }
        let next = decimal.end < codeEnd ? source[decimal.end] : 0
        if !next.cannotBeIdentStart {
            return .error
        }
        let value = WTF.parseDoubleFromDecimalDigits(decimal.mantissa, decimal.exponent, decimal.digitCount)
        data.doubleValue = value
        code = decimal.end
        current = next
        if integerEnd < codeEnd && source[integerEnd] == .ascii(".") {
            return .double
        }
        return JSC.JSTokenType(integerLike: value)
    }

    @inline(never)
    mutating func scanDecimalArrayElementFollowedByComma(
        _ value: inout Double,
        start: Int,
        integerEnd: Int,
        integerValue: UInt64,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSTokenType {
        guard let decimal = scanDecimalNumber(start: start, integerEnd: integerEnd, integer: integerValue),
            decimal.end < codeEnd, source[decimal.end] == .ascii(",")
        else {
            return .error
        }
        value = WTF.parseDoubleFromDecimalDigits(decimal.mantissa, decimal.exponent, decimal.digitCount)
        code = decimal.end + 1
        reloadCurrent()
        hasLineTerminatorBeforeToken = false
        if source[integerEnd] == .ascii(".") {
            return .double
        }
        return JSC.JSTokenType(integerLike: value)
    }

    // The rest of a decimal literal whose integer part start..<integerEnd (possibly empty, as in ".5") has the value
    // integer; nil past 19 significant digits or on a syntax error.
    private func scanDecimalNumber(
        start: Int,
        integerEnd: Int,
        integer: UInt64
    )
        -> ScannedDecimalNumber?
    {
        let integerDigits = integerEnd - start
        if integerDigits > maxMantissaDigitsForDecimalNumber {
            return nil
        }

        var mantissa = integer
        var cursor = integerEnd
        var fractionStart = integerEnd
        if cursor < codeEnd && source[cursor] == .ascii(".") {
            cursor += 1
            fractionStart = cursor
            while cursor < codeEnd && source[cursor].isASCIIDigit {
                mantissa = mantissa &* 10 &+ UInt64(source[cursor] &- .ascii("0"))
                cursor += 1
            }
            if cursor == fractionStart && integerDigits == 0 {
                return nil
            }
        }
        let fractionDigits = cursor - fractionStart
        var exponent = -Int64(fractionDigits)
        if cursor < codeEnd && (source[cursor] == .ascii("e") || source[cursor] == .ascii("E")) {
            cursor += 1
            var negativeExponent = false
            if cursor < codeEnd && (source[cursor] == .ascii("+") || source[cursor] == .ascii("-")) {
                negativeExponent = source[cursor] == .ascii("-")
                cursor += 1
            }
            if cursor >= codeEnd || !source[cursor].isASCIIDigit {
                return nil
            }
            // An exponent this large gives zero or infinity, unless as many leading zeros in the fraction offset it,
            // so it is left to the double parser.
            let maxExplicitExponent: Int64 = 100000
            var explicitExponent: Int64 = 0
            while cursor < codeEnd && source[cursor].isASCIIDigit {
                explicitExponent = explicitExponent * 10 + Int64(source[cursor] &- .ascii("0"))
                if explicitExponent >= maxExplicitExponent {
                    return nil
                }
                cursor += 1
            }
            exponent += negativeExponent ? -explicitExponent : explicitExponent
        }

        var digitCount = integerDigits + fractionDigits
        if digitCount > maxMantissaDigitsForDecimalNumber {
            // An integer part of 0 and the zeros after it are not significant, and add nothing to the mantissa.
            if integer != 0 {
                return nil
            }
            var firstSignificant = fractionStart
            while firstSignificant < cursor && source[firstSignificant] == .ascii("0") {
                firstSignificant += 1
            }
            digitCount = fractionStart + fractionDigits - firstSignificant
            if digitCount > maxMantissaDigitsForDecimalNumber {
                return nil
            }
        }
        return ScannedDecimalNumber(end: cursor, mantissa: mantissa, exponent: exponent, digitCount: digitCount)
    }

    // Consumes a decimal literal or `null` immediately followed by ',' (including the ',') and returns the literal's
    // token type. Otherwise consumes nothing and returns the error token.
    @inline(always)
    mutating func scanSimpleArrayElementFollowedByComma(_ value: inout Double, _ facade: inout JSC.JSParseFacade) -> JSC.JSTokenType {
        let start = code
        var pointer = start
        let type: JSC.JSTokenType
        if pointer < codeEnd && source[pointer].isASCIIDigit {
            var result = UInt64(source[pointer] &- .ascii("0"))
            pointer += 1
            if result != 0 {
                while pointer < codeEnd && source[pointer].isASCIIDigit {
                    result = result &* 10 &+ UInt64(source[pointer] &- .ascii("0"))
                    pointer += 1
                }
            }
            if pointer - start > Self.numberOfDigitsForSafeInt52
                || (pointer < codeEnd && (source[pointer] == .ascii(".") || source[pointer].isASCIIAlphaCaselessEqual(.ascii("e"))))
            {
                return scanDecimalArrayElementFollowedByComma(
                    &value,
                    start: start,
                    integerEnd: pointer,
                    integerValue: result,
                    &facade
                )
            }
            value = Double(result)
            type = .integer
        } else if codeEnd - pointer >= 2 && source[pointer] == .ascii(".") && source[pointer + 1].isASCIIDigit {
            return scanDecimalArrayElementFollowedByComma(
                &value,
                start: start,
                integerEnd: start,
                integerValue: 0,
                &facade
            )
        } else if codeEnd - pointer >= 4 && source[pointer] == .ascii("n") && source[pointer + 1] == .ascii("u")
            && source[pointer + 2] == .ascii("l") && source[pointer + 3] == .ascii("l")
        {
            pointer += 4
            type = .nullKeyword
        } else {
            return .error
        }

        if pointer >= codeEnd || source[pointer] != .ascii(",") {
            return .error
        }

        code = pointer + 1
        reloadCurrent()
        hasLineTerminatorBeforeToken = false
        return type
    }
}
