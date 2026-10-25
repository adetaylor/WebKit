// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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
//
// The decimal parser is a Swift translation of fast_float 8.2.10 (Source/WTF/wtf/fast_float/fast_float.h), used under
// its MIT License:
//
//    Copyright (c) 2021 The fast_float authors
//
//    Permission is hereby granted, free of charge, to any
//    person obtaining a copy of this software and associated
//    documentation files (the "Software"), to deal in the
//    Software without restriction, including without
//    limitation the rights to use, copy, modify, merge,
//    publish, distribute, sublicense, and/or sell copies of
//    the Software, and to permit persons to whom the Software
//    is furnished to do so, subject to the following
//    conditions:
//
//    The above copyright notice and this permission notice
//    shall be included in all copies or substantial portions
//    of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
//    ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
//    TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
//    PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
//    SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
//    OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
//    IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//    DEALINGS IN THE SOFTWARE.

// MARK: - Lexer<T>::lexNumber, after the state machine

/// The suffix of a number token, as the state machine of `Lexer::lexNumber` records it in `char suffix`.
@_spi(Testing)
public enum NumberLiteralSuffix: Sendable {
    case none
    case i
    case u
    case f
    case h
}

/// What the state machine of `Lexer::lexNumber` recorded about a number token, with offsets in code units.
@_spi(Testing)
public struct NumberLiteralScan: Sendable {
    /// The token's first code unit (`start`).
    @_spi(Testing)
    public var start: Int
    /// The first digit (`integral`): `start`, or just after `0x`.
    @_spi(Testing)
    public var integral: Int
    /// Just past the token, suffix included (`m_code.position()`).
    @_spi(Testing)
    public var end: Int
    @_spi(Testing)
    public var suffix: NumberLiteralSuffix
    @_spi(Testing)
    public var isHex: Bool
    /// `fract != nullptr`.
    @_spi(Testing)
    public var hasFraction: Bool
    /// `exponent != nullptr`.
    @_spi(Testing)
    public var hasExponent: Bool

    @_spi(Testing)
    public init(start: Int, integral: Int, end: Int, suffix: NumberLiteralSuffix, isHex: Bool, hasFraction: Bool, hasExponent: Bool) {
        self.start = start
        self.integral = integral
        self.end = end
        self.suffix = suffix
        self.isHex = isHex
        self.hasFraction = hasFraction
        self.hasExponent = hasExponent
    }
}

/// The token `Lexer::lexNumber` makes once the state machine has accepted a number.
@_spi(Testing)
public enum NumberLiteral: Equatable, Sendable {
    case invalid
    case integerLiteral(Int64)
    case integerLiteralSigned(Int32)
    case integerLiteralUnsigned(UInt32)
    case abstractFloatLiteral(Double)
    case floatLiteral(Float)
    /// The double that passed `convertFloat<half>`'s range check; the token stores it rounded once to `half`.
    case halfLiteral(Double)
}

/// Literal text to numbers, with the exact semantics of the C++ lexer.
///
/// The C++ uses `WTF::parseInteger`, `WTF::parseDouble` (fast_float) and Darwin `strtod` for hexadecimal floats.
/// This is pure Swift: nothing here calls the OS runtime's text-to-number conversions.
@_spi(Testing)
public enum NumberParsing {
    /// The token for the number `scan` describes, in Latin-1 code units.
    @_spi(Testing)
    public static func literal(_ codeUnits: ContiguousArray<UInt8>, _ scan: NumberLiteralScan) -> NumberLiteral {
        if !scan.hasFraction && !scan.hasExponent && scan.suffix != .f && scan.suffix != .h {
            let base: UInt8 = scan.isHex ? 16 : 10
            guard let result = parseInteger(codeUnits, scan.integral..<scan.end, base: base) else {
                return .invalid
            }
            return convert(result, scan.suffix)
        }

        if !scan.isHex {
            var parsedLength = 0
            let result = parseDouble(codeUnits, scan.integral..<scan.end, parsedLength: &parsedLength)
            return convert(result, scan.suffix)
        }

        var length = scan.end - scan.start
        if scan.suffix != .none {
            length -= 1
        }
        var parsedLength = 0
        guard let result = stringToDouble(codeUnits, scan.start..<(scan.start + length), parsedLength: &parsedLength),
            parsedLength == length
        else {
            return .invalid
        }
        return convert(result, scan.suffix)
    }

    /// The token for the number `scan` describes, in UTF-16 code units.
    @_spi(Testing)
    public static func literal(_ codeUnits: ContiguousArray<UInt16>, _ scan: NumberLiteralScan) -> NumberLiteral {
        var bytes = ContiguousArray<UInt8>()
        return literal(codeUnits, scan, &bytes)
    }

    /// `literal(codeUnits, scan)`, with the token's code units narrowed into `bytes`, which the lexer reuses for every number.
    ///
    /// Number tokens are ASCII. The hexadecimal-float path narrows each code unit to `char` as the C++ copy into
    /// the `strtod` buffer does; the other paths compare whole code units, so a non-ASCII unit becomes 0xFF,
    /// which no parser accepts either.
    @_spi(Testing)
    public static func literal(
        _ codeUnits: ContiguousArray<UInt16>,
        _ scan: NumberLiteralScan,
        _ bytes: inout ContiguousArray<UInt8>
    ) -> NumberLiteral {
        let narrowsToChar = scan.isHex && (scan.hasFraction || scan.hasExponent || scan.suffix == .f || scan.suffix == .h)
        while bytes.popLast() != nil {}
        if bytes.capacity < scan.end - scan.start {
            bytes.reserveCapacity(scan.end - scan.start)
        }
        var index = scan.start
        while index < scan.end {
            let codeUnit = codeUnits[index]
            if narrowsToChar || codeUnit < 0x80 {
                bytes.append(UInt8(truncatingIfNeeded: codeUnit))
            } else {
                bytes.append(0xFF)
            }
            index += 1
        }
        let rebased = NumberLiteralScan(
            start: 0,
            integral: scan.integral - scan.start,
            end: scan.end - scan.start,
            suffix: scan.suffix,
            isHex: scan.isHex,
            hasFraction: scan.hasFraction,
            hasExponent: scan.hasExponent
        )
        return literal(bytes, rebased)
    }

    private static func convert(_ value: Int64, _ suffix: NumberLiteralSuffix) -> NumberLiteral {
        switch suffix {
        case .i:
            if let result = Int32(exactly: value) {
                return .integerLiteralSigned(result)
            }
        case .u:
            if let result = UInt32(exactly: value) {
                return .integerLiteralUnsigned(result)
            }
        case .f:
            return .floatLiteral(Float(value))
        case .h:
            if Float(value) <= halfMax && Float(value) >= -halfMax {
                return .halfLiteral(Double(value))
            }
        case .none:
            return .integerLiteral(value)
        }
        return .invalid
    }

    private static func convert(_ value: Double, _ suffix: NumberLiteralSuffix) -> NumberLiteral {
        switch suffix {
        case .i, .u:
            break
        case .f:
            if let result = convertFloat(value, max: Double(Float.greatestFiniteMagnitude)) {
                return .floatLiteral(Float(result))
            }
        case .h:
            if let result = convertFloat(value, max: Double(halfMax)) {
                return .halfLiteral(result)
            }
        case .none:
            if let result = convertFloat(value, max: Double.greatestFiniteMagnitude) {
                return .abstractFloatLiteral(result)
            }
        }
        return .invalid
    }

    private static let halfMax: Float = 0x1.ffcp15

    // convertFloat<To>(double) (ConstantValue.h:222-245): the range check is on the double.
    private static func convertFloat(_ value: Double, max: Double) -> Double? {
        let lowest = -max
        if value > max {
            return nil
        }
        if value < lowest {
            return nil
        }
        if value.isNaN {
            return nil
        }
        return value
    }

    // MARK: - WTF::parseInteger (StringToIntegerConversion.h)

    /// `WTF::parseInteger<int64_t>(data, base, TrailingJunkPolicy::Allow)`.
    @_spi(Testing)
    public static func parseInteger(_ data: ContiguousArray<UInt8>, _ range: Range<Int>, base: UInt8) -> Int64? {
        var position = range.lowerBound
        let end = range.upperBound

        while position != end && isUnicodeCompatibleASCIIWhitespace(data[position]) {
            position += 1
        }

        var isNegative = false
        if position != end && data[position] == UInt8(ascii: "-") {
            isNegative = true
            position += 1
        } else if position != end && data[position] == UInt8(ascii: "+") {
            position += 1
        }

        guard position != end && isCharacterAllowedInBase(data[position], base) else {
            return nil
        }

        var value: Int64 = 0
        var hasOverflowed = false
        repeat {
            let character = data[position]
            position += 1
            let digitValue = Int64(isASCIIDigit(character) ? character - UInt8(ascii: "0") : (character | 0x20) - UInt8(ascii: "a") + 10)
            let multiplied = value.multipliedReportingOverflow(by: Int64(base))
            let added =
                isNegative
                ? multiplied.partialValue.subtractingReportingOverflow(digitValue)
                : multiplied.partialValue.addingReportingOverflow(digitValue)
            hasOverflowed = hasOverflowed || multiplied.overflow || added.overflow
            value = added.partialValue
        } while position != end && isCharacterAllowedInBase(data[position], base)

        if hasOverflowed {
            return nil
        }
        return value
    }

    private static func isCharacterAllowedInBase(_ character: UInt8, _ base: UInt8) -> Bool {
        if isASCIIDigit(character) {
            return character - UInt8(ascii: "0") < base
        }
        let letterCount = Int(base) - 10 < 26 ? Int(base) - 10 : 26
        let lower = Int(character | 0x20)
        return lower >= Int(UInt8(ascii: "a")) && lower < Int(UInt8(ascii: "a")) + letterCount
    }

    private static func isASCIIDigit(_ character: UInt8) -> Bool {
        character >= UInt8(ascii: "0") && character <= UInt8(ascii: "9")
    }

    private static func isUnicodeCompatibleASCIIWhitespace(_ character: UInt8) -> Bool {
        character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D || character == 0x0C || character == 0x0B
    }

    // MARK: - WTF::parseDouble (FastFloat.cpp)

    /// Parses as `WTF::parseDouble(span, parsedLength)` does.
    ///
    /// That is fast_float's `from_chars` with `chars_format::general | chars_format::no_infnan |
    /// chars_format::allow_leading_plus`. The result is 0 when nothing parses; out-of-range input gives ±infinity or
    /// a correctly rounded subnormal or zero.
    @_spi(Testing)
    public static func parseDouble(_ string: ContiguousArray<UInt8>, _ range: Range<Int>, parsedLength: inout Int) -> Double {
        var doubleValue = 0.0
        let resultPointer = FastFloat.fromCharsFloatAdvanced(string, range.lowerBound, range.upperBound, &doubleValue)
        parsedLength = resultPointer - range.lowerBound
        return doubleValue
    }

    // MARK: - WTF::stringToDouble (StdLibExtras.h:1630-1642)

    /// Parses as `WTF::stringToDouble(buffer, parsedLength)` does, for the hexadecimal floats the lexer passes it.
    ///
    /// That is Darwin `strtod`: correctly rounded, and `nil` where `strtod` sets `ERANGE` (overflow, and an underflow
    /// to zero or to an inexact subnormal). Input that does not start with `0x` or `0X` parses nothing.
    @_spi(Testing)
    public static func stringToDouble(_ buffer: ContiguousArray<UInt8>, _ range: Range<Int>, parsedLength: inout Int) -> Double? {
        let result = HexFloat.parse(buffer, range.lowerBound, range.upperBound)
        if result.isOutOfRange {
            parsedLength = 0
            return nil
        }
        parsedLength = result.end - range.lowerBound
        return result.value
    }
}

// MARK: - fast_float

private enum FastFloat {
    // binary_format<double>
    static let mantissaExplicitBits: Int32 = 52
    static let minimumExponent: Int32 = -1023
    static let infinitePower: Int32 = 0x7FF
    static let signIndex: UInt64 = 63
    static let minExponentFastPath: Int64 = -22
    static let maxExponentFastPath: Int64 = 22
    static let maxExponentRoundToEven: Int64 = 23
    static let minExponentRoundToEven: Int64 = -4
    static let maxMantissaFastPath: UInt64 = 2 << 52
    static let largestPowerOfTen: Int64 = 308
    static let smallestPowerOfTen: Int64 = -342
    static let maxDigits = 769
    static let exponentMask: UInt64 = 0x7FF0_0000_0000_0000
    static let mantissaMask: UInt64 = 0x000F_FFFF_FFFF_FFFF
    static let hiddenBitMask: UInt64 = 0x0010_0000_0000_0000
    static let powersOfTen: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    // Bias so we can get the real exponent with an invalid adjusted_mantissa.
    static let invalidAMBias: Int32 = -0x8000

    struct AdjustedMantissa: Equatable {
        var mantissa: UInt64 = 0
        // a negative value indicates an invalid result
        var power2: Int32 = 0
    }

    struct ParsedNumberString {
        var exponent: Int64 = 0
        var mantissa: UInt64 = 0
        var lastMatch = 0
        var negative = false
        var valid = false
        var tooManyDigits = false
        // contains the range of the significant digits
        var integer = 0..<0
        // nil when there is no decimal point
        var fraction: Range<Int>? = nil
    }

    static func isInteger(_ character: UInt8) -> Bool {
        character &- UInt8(ascii: "0") < 10
    }

    static func reportParseError(_ position: Int) -> ParsedNumberString {
        var answer = ParsedNumberString()
        answer.valid = false
        answer.lastMatch = position
        return answer
    }

    // Assuming that you use no more than 19 digits, this will
    // parse an ASCII string.
    static func parseNumberString(_ s: ContiguousArray<UInt8>, _ first: Int, _ pend: Int) -> ParsedNumberString {
        let decimalPoint = UInt8(ascii: ".")
        var p = first

        var answer = ParsedNumberString()
        answer.valid = false
        answer.tooManyDigits = false
        // assume p < pend
        answer.negative = s[p] == UInt8(ascii: "-")
        if s[p] == UInt8(ascii: "-") || s[p] == UInt8(ascii: "+") {
            p += 1
            if p == pend {
                return reportParseError(p)
            }
            // a sign must be followed by an integer or the dot
            if !isInteger(s[p]) && s[p] != decimalPoint {
                return reportParseError(p)
            }
        }
        let startDigits = p

        var i: UInt64 = 0
        while p != pend && isInteger(s[p]) {
            // might overflow, handled later
            i = 10 &* i &+ UInt64(s[p] &- UInt8(ascii: "0"))
            p += 1
        }
        let endOfIntegerPart = p
        var digitCount = Int64(endOfIntegerPart - startDigits)
        answer.integer = startDigits..<endOfIntegerPart

        var exponent: Int64 = 0
        let hasDecimalPoint = p != pend && s[p] == decimalPoint
        if hasDecimalPoint {
            p += 1
            let before = p
            while p != pend && isInteger(s[p]) {
                let digit = s[p] &- UInt8(ascii: "0")
                p += 1
                // in rare cases, this will overflow, but that's ok
                i = i &* 10 &+ UInt64(digit)
            }
            exponent = Int64(before - p)
            answer.fraction = before..<p
            digitCount -= exponent
        }
        // we must have encountered at least one integer!
        if digitCount == 0 {
            return reportParseError(p)
        }
        // explicit exponential part
        var expNumber: Int64 = 0
        if p != pend && (s[p] == UInt8(ascii: "e") || s[p] == UInt8(ascii: "E")) {
            let locationOfE = p
            p += 1
            var negExp = false
            if p != pend && s[p] == UInt8(ascii: "-") {
                negExp = true
                p += 1
            } else if p != pend && s[p] == UInt8(ascii: "+") {
                p += 1
            }
            if p == pend || !isInteger(s[p]) {
                // Fixed notation is enabled, so we will be ignoring the 'e'.
                p = locationOfE
            } else {
                while p != pend && isInteger(s[p]) {
                    let digit = s[p] &- UInt8(ascii: "0")
                    if expNumber < 0x1000_0000 {
                        expNumber = 10 * expNumber + Int64(digit)
                    }
                    p += 1
                }
                if negExp {
                    expNumber = -expNumber
                }
                exponent += expNumber
            }
        }
        answer.lastMatch = p
        answer.valid = true

        // We can deal with up to 19 digits.
        if digitCount > 19 {
            // It is possible that the integer had an overflow.
            // We have to handle the case where we have 0.0000somenumber.
            // We need to be mindful of the case where we only have zeroes...
            // E.g., 0.000000000...000.
            var start = startDigits
            while start != pend && (s[start] == UInt8(ascii: "0") || s[start] == decimalPoint) {
                if s[start] == UInt8(ascii: "0") {
                    digitCount -= 1
                }
                start += 1
            }

            if digitCount > 19 {
                answer.tooManyDigits = true
                // Let us start again, this time, avoiding overflows.
                i = 0
                p = answer.integer.lowerBound
                let intEnd = answer.integer.upperBound
                let minimalNineteenDigitInteger: UInt64 = 1_000_000_000_000_000_000
                while i < minimalNineteenDigitInteger && p != intEnd {
                    i = i * 10 + UInt64(s[p] - UInt8(ascii: "0"))
                    p += 1
                }
                if i >= minimalNineteenDigitInteger {
                    // We have a big integer
                    exponent = Int64(endOfIntegerPart - p) + expNumber
                } else {
                    // We have a value with a fractional component.
                    let fraction = answer.fraction ?? p..<p
                    p = fraction.lowerBound
                    while i < minimalNineteenDigitInteger && p != fraction.upperBound {
                        i = i * 10 + UInt64(s[p] - UInt8(ascii: "0"))
                        p += 1
                    }
                    exponent = Int64(fraction.lowerBound - p) + expNumber
                }
                // We have now corrected both exponent and i, to a truncated value
            }
        }
        answer.exponent = exponent
        answer.mantissa = i
        return answer
    }

    // The ptr of from_chars_result; WTF::parseDouble ignores the error code.
    static func fromCharsFloatAdvanced(_ s: ContiguousArray<UInt8>, _ first: Int, _ last: Int, _ value: inout Double) -> Int {
        if first == last {
            return first
        }
        let pns = parseNumberString(s, first, last)
        if !pns.valid {
            // no_infnan
            return first
        }
        return fromCharsAdvanced(s, pns, &value)
    }

    // The C++ hot path parses without the digit spans and re-parses for the two slow paths; that re-parse gives
    // this same ParsedNumberString, so the hot path is folded into this function.
    static func fromCharsAdvanced(_ s: ContiguousArray<UInt8>, _ pns: ParsedNumberString, _ value: inout Double) -> Int {
        if !pns.tooManyDigits && clingerFastPath(pns.mantissa, pns.exponent, pns.negative, &value) {
            return pns.lastMatch
        }

        var am = computeFloat(pns.exponent, pns.mantissa)
        if pns.tooManyDigits && am.power2 >= 0 {
            if am != computeFloat(pns.exponent, pns.mantissa + 1) {
                am = computeError(pns.exponent, pns.mantissa)
            }
        }
        // If we called computeFloat(pns.exponent, pns.mantissa)
        // and we have an invalid power (am.power2 < 0), then we need to go the long
        // way around again. This is very uncommon.
        if am.power2 < 0 {
            am = digitComp(s, pns, am)
        }
        value = toFloat(pns.negative, am)
        return pns.lastMatch
    }

    // Swift always runs with round-to-nearest, the only rounding mode for which the C++ takes Clinger's fast
    // path as written here.
    static func clingerFastPath(_ mantissa: UInt64, _ exponent: Int64, _ isNegative: Bool, _ value: inout Double) -> Bool {
        if minExponentFastPath <= exponent && exponent <= maxExponentFastPath {
            if mantissa <= maxMantissaFastPath {
                value = Double(mantissa)
                if exponent < 0 {
                    value = value / powersOfTen[Int(-exponent)]
                } else {
                    value = value * powersOfTen[Int(exponent)]
                }
                if isNegative {
                    value = -value
                }
                return true
            }
        }
        return false
    }

    static func toFloat(_ negative: Bool, _ am: AdjustedMantissa) -> Double {
        var word = am.mantissa
        word = word | UInt64(truncatingIfNeeded: am.power2) << UInt64(mantissaExplicitBits)
        word = word | (negative ? UInt64(1) : 0) << signIndex
        return Double(bitPattern: word)
    }

    // MARK: decimal_to_binary

    // This will compute or rather approximate w * 5**q and return a pair of 64-bit
    // words approximating the result, with the "high" part corresponding to the
    // most significant bits and the low part corresponding to the least significant
    // bits.
    static func computeProductApproximation(_ q: Int64, _ w: UInt64) -> (high: UInt64, low: UInt64) {
        let bitPrecision = mantissaExplicitBits + 3
        let index = 2 * Int(q - smallestPowerOfTen)
        // For small values of q, e.g., q in [0,27], the answer is always exact
        // because full_multiplication(w, power_of_five_128[index]) gives the exact answer.
        var firstProduct = w.multipliedFullWidth(by: powerOfFive128[index])
        let precisionMask = UInt64.max >> UInt64(bitPrecision)
        if (firstProduct.high & precisionMask) == precisionMask {
            let secondProduct = w.multipliedFullWidth(by: powerOfFive128[index + 1])
            firstProduct.low &+= secondProduct.high
            if secondProduct.high > firstProduct.low {
                firstProduct.high += 1
            }
        }
        return (firstProduct.high, firstProduct.low)
    }

    // For q in (0,350), we have that
    //  f = (((152170 + 65536) * q ) >> 16);
    // is equal to
    //   floor(p) + q
    // where
    //   p = log(5**q)/log(2) = q * log(5)/log(2)
    //
    // For negative values of q in (-400,0), we have that
    //  f = (((152170 + 65536) * q ) >> 16);
    // is equal to
    //   -ceil(p) + q
    // where
    //   p = log(5**-q)/log(2) = -q * log(5)/log(2)
    static func power(_ q: Int32) -> Int32 {
        (((152_170 + 65_536) * q) >> 16) + 63
    }

    // create an adjusted mantissa, biased by the invalid power2
    // for significant digits already multiplied by 10 ** q.
    static func computeErrorScaled(_ q: Int64, _ w: UInt64, _ lz: Int32) -> AdjustedMantissa {
        let hilz = Int32(truncatingIfNeeded: w >> 63) ^ 1
        var answer = AdjustedMantissa()
        answer.mantissa = w << UInt64(hilz)
        let bias = mantissaExplicitBits - minimumExponent
        answer.power2 = power(Int32(truncatingIfNeeded: q)) + bias - hilz - lz - 62 + invalidAMBias
        return answer
    }

    // w * 10 ** q, without rounding the representation up.
    // the power2 in the exponent will be adjusted by invalidAMBias.
    static func computeError(_ q: Int64, _ w: UInt64) -> AdjustedMantissa {
        let lz = Int32(w.leadingZeroBitCount)
        let shifted = w << UInt64(lz)
        let product = computeProductApproximation(q, shifted)
        return computeErrorScaled(q, product.high, lz)
    }

    // Computes w * 10 ** q.
    // The returned value should be a valid number that simply needs to be
    // packed. However, in some very rare cases, the computation will fail. In such
    // cases, we return an adjusted_mantissa with a negative power of 2: the caller
    // should recompute in such cases.
    static func computeFloat(_ q: Int64, _ w: UInt64) -> AdjustedMantissa {
        var answer = AdjustedMantissa()
        if w == 0 || q < smallestPowerOfTen {
            answer.power2 = 0
            answer.mantissa = 0
            // result should be zero
            return answer
        }
        if q > largestPowerOfTen {
            // we want to get infinity:
            answer.power2 = infinitePower
            answer.mantissa = 0
            return answer
        }
        // At this point in time q is in [powers::smallest_power_of_five,
        // powers::largest_power_of_five].

        // We want the most significant bit of i to be 1. Shift if needed.
        let lz = Int32(w.leadingZeroBitCount)
        let shifted = w << UInt64(lz)

        // The required precision is mantissaExplicitBits + 3 because
        // 1. We need the implicit bit
        // 2. We need an extra bit for rounding purposes
        // 3. We might lose a bit due to the "upperbit" routine (result too small,
        // requiring a shift)
        let product = computeProductApproximation(q, shifted)
        // The computed 'product' is always sufficient.
        // Mathematical proof:
        // Noble Mushtak and Daniel Lemire, Fast Number Parsing Without Fallback (to
        // appear) See script/mushtak_lemire.py

        let upperbit = Int32(truncatingIfNeeded: product.high >> 63)
        let shift = upperbit + 64 - mantissaExplicitBits - 3

        answer.mantissa = product.high >> UInt64(shift)

        answer.power2 = power(Int32(truncatingIfNeeded: q)) + upperbit - lz - minimumExponent
        // we have a subnormal?
        if answer.power2 <= 0 {
            // Here have that answer.power2 <= 0 so -answer.power2 >= 0
            if -answer.power2 + 1 >= 64 {
                // if we have more than 64 bits below the minimum exponent, you
                // have a zero for sure.
                answer.power2 = 0
                answer.mantissa = 0
                // result should be zero
                return answer
            }
            // next line is safe because -answer.power2 + 1 < 64
            answer.mantissa >>= UInt64(-answer.power2 + 1)
            // Thankfully, we can't have both "round-to-even" and subnormals because
            // "round-to-even" only occurs for powers close to 0 in the 32-bit and
            // and 64-bit case (with no more than 19 digits).
            answer.mantissa += answer.mantissa & 1
            answer.mantissa >>= 1
            // There is a weird scenario where we don't have a subnormal but just.
            // Suppose we start with 2.2250738585072013e-308, we end up
            // with 0x3fffffffffffff x 2^-1023-53 which is technically subnormal
            // whereas 0x40000000000000 x 2^-1023-53  is normal. Now, we need to round
            // up 0x3fffffffffffff x 2^-1023-53  and once we do, we are no longer
            // subnormal, but we can only know this after rounding.
            // So we only declare a subnormal if we are smaller than the threshold.
            answer.power2 = answer.mantissa < (UInt64(1) << UInt64(mantissaExplicitBits)) ? 0 : 1
            return answer
        }

        // usually, we round *up*, but if we fall right in between and and we have an
        // even basis, we need to round down
        // We are only concerned with the cases where 5**q fits in single 64-bit word.
        if product.low <= 1 && q >= minExponentRoundToEven && q <= maxExponentRoundToEven && (answer.mantissa & 3) == 1 {
            // we may fall between two floats!
            // To be in-between two floats we need that in doing
            //   answer.mantissa = product.high >> (upperbit + 64 - mantissaExplicitBits - 3);
            // ... we dropped out only zeroes. But if this happened, then we can go
            // back!!!
            if (answer.mantissa << UInt64(shift)) == product.high {
                // flip it so that we do not round up
                answer.mantissa &= ~UInt64(1)
            }
        }

        // round up
        answer.mantissa += answer.mantissa & 1
        answer.mantissa >>= 1
        if answer.mantissa >= (UInt64(2) << UInt64(mantissaExplicitBits)) {
            answer.mantissa = UInt64(1) << UInt64(mantissaExplicitBits)
            // undo previous addition
            answer.power2 += 1
        }

        answer.mantissa &= ~(UInt64(1) << UInt64(mantissaExplicitBits))
        if answer.power2 >= infinitePower {
            // infinity
            answer.power2 = infinitePower
            answer.mantissa = 0
        }
        return answer
    }

    // MARK: digit_comparison

    // 1e0 to 1e19
    static let powersOfTenUInt64: [UInt64] = [
        1,
        10,
        100,
        1000,
        10000,
        100_000,
        1_000_000,
        10_000_000,
        100_000_000,
        1_000_000_000,
        10_000_000_000,
        100_000_000_000,
        1_000_000_000_000,
        10_000_000_000_000,
        100_000_000_000_000,
        1_000_000_000_000_000,
        10_000_000_000_000_000,
        100_000_000_000_000_000,
        1_000_000_000_000_000_000,
        10_000_000_000_000_000_000,
    ]

    // calculate the exponent, in scientific notation, of the number.
    static func scientificExponent(_ mantissa: UInt64, _ exponent: Int32) -> Int32 {
        var mantissa = mantissa
        var exponent = exponent
        while mantissa >= 10000 {
            mantissa /= 10000
            exponent += 4
        }
        while mantissa >= 100 {
            mantissa /= 100
            exponent += 2
        }
        while mantissa >= 10 {
            mantissa /= 10
            exponent += 1
        }
        return exponent
    }

    // this converts a native floating-point number to an extended-precision float.
    static func toExtended(_ value: Double) -> AdjustedMantissa {
        var am = AdjustedMantissa()
        let bias = mantissaExplicitBits - minimumExponent
        let bits = value.bitPattern
        if (bits & exponentMask) == 0 {
            // denormal
            am.power2 = 1 - bias
            am.mantissa = bits & mantissaMask
        } else {
            // normal
            am.power2 = Int32(truncatingIfNeeded: (bits & exponentMask) >> UInt64(mantissaExplicitBits))
            am.power2 -= bias
            am.mantissa = (bits & mantissaMask) | hiddenBitMask
        }
        return am
    }

    // get the extended precision value of the halfway point between b and b+u.
    // we are given a native float that represents b, so we need to adjust it
    // halfway between b and b+u.
    static func toExtendedHalfway(_ value: Double) -> AdjustedMantissa {
        var am = toExtended(value)
        am.mantissa <<= 1
        am.mantissa += 1
        am.power2 -= 1
        return am
    }

    // round an extended-precision float to the nearest machine float.
    static func round(_ am: inout AdjustedMantissa, _ callback: (inout AdjustedMantissa, Int32) -> Void) {
        let mantissaShift: Int32 = 64 - mantissaExplicitBits - 1
        if -am.power2 >= mantissaShift {
            // have a denormal float
            let shift = -am.power2 + 1
            callback(&am, shift < 64 ? shift : 64)
            // check for round-up: if rounding-nearest carried us to the hidden bit.
            am.power2 = am.mantissa < (UInt64(1) << UInt64(mantissaExplicitBits)) ? 0 : 1
            return
        }

        // have a normal float, use the default shift.
        callback(&am, mantissaShift)

        // check for carry
        if am.mantissa >= (UInt64(2) << UInt64(mantissaExplicitBits)) {
            am.mantissa = UInt64(1) << UInt64(mantissaExplicitBits)
            am.power2 += 1
        }

        // check for infinite: we could have carried to an infinite power
        am.mantissa &= ~(UInt64(1) << UInt64(mantissaExplicitBits))
        if am.power2 >= infinitePower {
            am.power2 = infinitePower
            am.mantissa = 0
        }
    }

    static func roundNearestTieEven(_ am: inout AdjustedMantissa, _ shift: Int32, _ callback: (Bool, Bool, Bool) -> Bool) {
        let mask: UInt64 = shift == 64 ? UInt64.max : (UInt64(1) << UInt64(shift)) - 1
        let halfway: UInt64 = shift == 0 ? 0 : UInt64(1) << UInt64(shift - 1)
        let truncatedBits = am.mantissa & mask
        let isAbove = truncatedBits > halfway
        let isHalfway = truncatedBits == halfway

        // shift digits into position
        if shift == 64 {
            am.mantissa = 0
        } else {
            am.mantissa >>= UInt64(shift)
        }
        am.power2 += shift

        let isOdd = (am.mantissa & 1) == 1
        am.mantissa += callback(isOdd, isHalfway, isAbove) ? 1 : 0
    }

    static func roundDown(_ am: inout AdjustedMantissa, _ shift: Int32) {
        if shift == 64 {
            am.mantissa = 0
        } else {
            am.mantissa >>= UInt64(shift)
        }
        am.power2 += shift
    }

    static func skipZeros(_ s: ContiguousArray<UInt8>, _ first: inout Int, _ last: Int) {
        while first != last {
            if s[first] != UInt8(ascii: "0") {
                break
            }
            first += 1
        }
    }

    // determine if any non-zero digits were truncated.
    // all characters must be valid digits.
    static func isTruncated(_ s: ContiguousArray<UInt8>, _ first: Int, _ last: Int) -> Bool {
        var first = first
        while first != last {
            if s[first] != UInt8(ascii: "0") {
                return true
            }
            first += 1
        }
        return false
    }

    static func parseOneDigit(_ s: ContiguousArray<UInt8>, _ p: inout Int, _ value: inout UInt64, _ counter: inout Int, _ count: inout Int)
    {
        value = value * 10 + UInt64(s[p] - UInt8(ascii: "0"))
        p += 1
        counter += 1
        count += 1
    }

    static func addNative(_ big: inout BigInt, _ power: UInt64, _ value: UInt64) {
        _ = big.mul(power)
        _ = big.add(value)
    }

    static func roundUpBigInt(_ big: inout BigInt, _ count: inout Int) {
        // need to round-up the digits, but need to avoid rounding
        // ....9999 to ...10000, which could cause a false halfway point.
        addNative(&big, 10, 1)
        count += 1
    }

    // parse the significant digits into a big integer
    static func parseMantissa(
        _ s: ContiguousArray<UInt8>,
        _ result: inout BigInt,
        _ num: ParsedNumberString,
        _ maxDigits: Int,
        _ digits: inout Int
    ) {
        // try to minimize the number of big integer and scalar multiplication.
        // therefore, try to parse 8 digits at a time, and multiply by the largest
        // scalar value (9 or 19 digits) for each step.
        var counter = 0
        digits = 0
        var value: UInt64 = 0
        let step = 19

        // process all integer digits.
        var p = num.integer.lowerBound
        var pend = num.integer.upperBound
        skipZeros(s, &p, pend)
        // process all digits, in increments of step per loop
        while p != pend {
            while counter < step && p != pend && digits < maxDigits {
                parseOneDigit(s, &p, &value, &counter, &digits)
            }
            if digits == maxDigits {
                // add the temporary value, then check if we've truncated any digits
                addNative(&result, powersOfTenUInt64[counter], value)
                var truncated = isTruncated(s, p, pend)
                if let fraction = num.fraction {
                    truncated = truncated || isTruncated(s, fraction.lowerBound, fraction.upperBound)
                }
                if truncated {
                    roundUpBigInt(&result, &digits)
                }
                return
            } else {
                addNative(&result, powersOfTenUInt64[counter], value)
                counter = 0
                value = 0
            }
        }

        // add our fraction digits, if they're available.
        if let fraction = num.fraction {
            p = fraction.lowerBound
            pend = fraction.upperBound
            if digits == 0 {
                skipZeros(s, &p, pend)
            }
            // process all digits, in increments of step per loop
            while p != pend {
                while counter < step && p != pend && digits < maxDigits {
                    parseOneDigit(s, &p, &value, &counter, &digits)
                }
                if digits == maxDigits {
                    // add the temporary value, then check if we've truncated any digits
                    addNative(&result, powersOfTenUInt64[counter], value)
                    let truncated = isTruncated(s, p, pend)
                    if truncated {
                        roundUpBigInt(&result, &digits)
                    }
                    return
                } else {
                    addNative(&result, powersOfTenUInt64[counter], value)
                    counter = 0
                    value = 0
                }
            }
        }

        if counter != 0 {
            addNative(&result, powersOfTenUInt64[counter], value)
        }
    }

    static func positiveDigitComp(_ bigmant: inout BigInt, _ exponent: Int32) -> AdjustedMantissa {
        _ = bigmant.pow10(UInt32(truncatingIfNeeded: exponent))
        var answer = AdjustedMantissa()
        var truncated = false
        answer.mantissa = bigmant.hi64(&truncated)
        let bias = mantissaExplicitBits - minimumExponent
        answer.power2 = bigmant.bitLength() - 64 + bias

        round(&answer) { a, shift in
            roundNearestTieEven(&a, shift) { isOdd, isHalfway, isAbove in
                isAbove || (isHalfway && truncated) || (isOdd && isHalfway)
            }
        }
        return answer
    }

    // the scaling here is quite simple: we have, for the real digits `m * 10^e`,
    // and for the theoretical digits `n * 2^f`. Since `e` is always negative,
    // to scale them identically, we do `n * 2^f * 5^-f`, so we now have `m * 2^e`.
    // we then need to scale by `2^(f- e)`, and then the two significant digits
    // are of the same magnitude.
    static func negativeDigitComp(_ bigmant: inout BigInt, _ am: AdjustedMantissa, _ exponent: Int32) -> AdjustedMantissa {
        let realExp = exponent

        // get the value of `b`, rounded down, and get a bigint representation of b+h
        var amB = am
        round(&amB) { a, shift in
            roundDown(&a, shift)
        }
        let b = toFloat(false, amB)
        let theor = toExtendedHalfway(b)
        var theorDigits = BigInt(theor.mantissa)
        let theorExp = theor.power2

        // scale real digits and theor digits to be same power.
        let pow2Exp = theorExp - realExp
        let pow5Exp = UInt32(truncatingIfNeeded: -realExp)
        if pow5Exp != 0 {
            _ = theorDigits.pow5(pow5Exp)
        }
        if pow2Exp > 0 {
            _ = theorDigits.pow2(UInt32(truncatingIfNeeded: pow2Exp))
        } else if pow2Exp < 0 {
            _ = bigmant.pow2(UInt32(truncatingIfNeeded: -pow2Exp))
        }

        // compare digits, and use it to direct rounding
        let ord = bigmant.compare(theorDigits)
        var answer = am
        round(&answer) { a, shift in
            roundNearestTieEven(&a, shift) { isOdd, _, _ in
                if ord > 0 {
                    return true
                } else if ord < 0 {
                    return false
                } else {
                    return isOdd
                }
            }
        }
        return answer
    }

    // parse the significant digits as a big integer to unambiguously round
    // the significant digits. here, we are trying to determine how to round
    // an extended float representation close to `b+h`, halfway between `b`
    // (the float rounded-down) and `b+u`, the next positive float. this
    // algorithm is always correct, and uses one of two approaches. when
    // the exponent is positive relative to the significant digits (such as
    // 1234), we create a big-integer representation, get the high 64-bits,
    // determine if any lower bits are truncated, and use that to direct
    // rounding. in case of a negative exponent relative to the significant
    // digits (such as 1.2345), we create a theoretical representation of
    // `b` as a big-integer type, scaled to the same binary exponent as
    // the actual digits. we then compare the big integer representations
    // of both, and use that to direct rounding.
    static func digitComp(_ s: ContiguousArray<UInt8>, _ num: ParsedNumberString, _ am: AdjustedMantissa) -> AdjustedMantissa {
        var am = am
        // remove the invalid exponent bias
        am.power2 -= invalidAMBias

        let sciExp = scientificExponent(num.mantissa, Int32(truncatingIfNeeded: num.exponent))
        var digits = 0
        var bigmant = BigInt()
        parseMantissa(s, &bigmant, num, maxDigits, &digits)
        // can't underflow, since digits is at most maxDigits.
        let exponent = sciExp + 1 - Int32(truncatingIfNeeded: digits)
        guard exponent >= 0 else {
            return negativeDigitComp(&bigmant, am, exponent)
        }
        return positiveDigitComp(&bigmant, exponent)
    }

    // Powers of five from 5^-342 all the way to 5^308 rounded toward one.
    static let powerOfFive128: [UInt64] = [
        0xeef4_53d6_923b_d65a, 0x113f_aa29_06a1_3b3f,
        0x9558_b466_1b65_65f8, 0x4ac7_ca59_a424_c507,
        0xbaae_e17f_a23e_bf76, 0x5d79_bcf0_0d2d_f649,
        0xe95a_99df_8ace_6f53, 0xf4d8_2c2c_1079_73dc,
        0x91d8_a02b_b6c1_0594, 0x7907_1b9b_8a4b_e869,
        0xb64e_c836_a471_46f9, 0x9748_e282_6cde_e284,
        0xe3e2_7a44_4d8d_98b7, 0xfd1b_1b23_0816_9b25,
        0x8e6d_8c6a_b078_7f72, 0xfe30_f0f5_e50e_20f7,
        0xb208_ef85_5c96_9f4f, 0xbdbd_2d33_5e51_a935,
        0xde8b_2b66_b3bc_4723, 0xad2c_7880_35e6_1382,
        0x8b16_fb20_3055_ac76, 0x4c3b_cb50_21af_cc31,
        0xaddc_b9e8_3c6b_1793, 0xdf4a_be24_2a1b_bf3d,
        0xd953_e862_4b85_dd78, 0xd71d_6dad_34a2_af0d,
        0x87d4_713d_6f33_aa6b, 0x8672_648c_40e5_ad68,
        0xa9c9_8d8c_cb00_9506, 0x680e_fdaf_511f_18c2,
        0xd43b_f0ef_fdc0_ba48, 0x0212_bd1b_2566_def2,
        0x84a5_7695_fe98_746d, 0x014b_b630_f760_4b57,
        0xa5ce_d43b_7e3e_9188, 0x419e_a3bd_3538_5e2d,
        0xcf42_894a_5dce_35ea, 0x5206_4cac_8286_75b9,
        0x8189_95ce_7aa0_e1b2, 0x7343_efeb_d194_0993,
        0xa1eb_fb42_1949_1a1f, 0x1014_ebe6_c5f9_0bf8,
        0xca66_fa12_9f9b_60a6, 0xd41a_26e0_7777_4ef6,
        0xfd00_b897_4782_38d0, 0x8920_b098_9555_22b4,
        0x9e20_735e_8cb1_6382, 0x55b4_6e5f_5d55_35b0,
        0xc5a8_9036_2fdd_bc62, 0xeb21_89f7_34aa_831d,
        0xf712_b443_bbd5_2b7b, 0xa5e9_ec75_01d5_23e4,
        0x9a6b_b0aa_5565_3b2d, 0x47b2_33c9_2125_366e,
        0xc106_9cd4_eabe_89f8, 0x999e_c0bb_696e_840a,
        0xf148_440a_256e_2c76, 0xc006_70ea_43ca_250d,
        0x96cd_2a86_5764_dbca, 0x3804_0692_6a5e_5728,
        0xbc80_7527_ed3e_12bc, 0xc605_0837_04f5_ecf2,
        0xeba0_9271_e88d_976b, 0xf786_4a44_c633_682e,
        0x9344_5b87_3158_7ea3, 0x7ab3_ee6a_fbe0_211d,
        0xb815_7268_fdae_9e4c, 0x5960_ea05_bad8_2964,
        0xe61a_cf03_3d1a_45df, 0x6fb9_2487_298e_33bd,
        0x8fd0_c162_0630_6bab, 0xa5d3_b6d4_79f8_e056,
        0xb3c4_f1ba_87bc_8696, 0x8f48_a489_9877_186c,
        0xe0b6_2e29_29ab_a83c, 0x331a_cdab_fe94_de87,
        0x8c71_dcd9_ba0b_4925, 0x9ff0_c08b_7f1d_0b14,
        0xaf8e_5410_288e_1b6f, 0x07ec_f0ae_5ee4_4dd9,
        0xdb71_e914_32b1_a24a, 0xc9e8_2cd9_f69d_6150,
        0x8927_31ac_9faf_056e, 0xbe31_1c08_3a22_5cd2,
        0xab70_fe17_c79a_c6ca, 0x6dbd_630a_48aa_f406,
        0xd64d_3d9d_b981_787d, 0x092c_bbcc_dad5_b108,
        0x85f0_4682_93f0_eb4e, 0x25bb_f560_08c5_8ea5,
        0xa76c_5823_38ed_2621, 0xaf2a_f2b8_0af6_f24e,
        0xd147_6e2c_0728_6faa, 0x1af5_af66_0db4_aee1,
        0x82cc_a4db_8479_45ca, 0x50d9_8d9f_c890_ed4d,
        0xa37f_ce12_6597_973c, 0xe50f_f107_bab5_28a0,
        0xcc5f_c196_fefd_7d0c, 0x1e53_ed49_a962_72c8,
        0xff77_b1fc_bebc_dc4f, 0x25e8_e89c_13bb_0f7a,
        0x9faa_cf3d_f736_09b1, 0x77b1_9161_8c54_e9ac,
        0xc795_830d_7503_8c1d, 0xd59d_f5b9_ef6a_2417,
        0xf97a_e3d0_d244_6f25, 0x4b05_7328_6b44_ad1d,
        0x9bec_ce62_836a_c577, 0x4ee3_67f9_430a_ec32,
        0xc2e8_01fb_2445_76d5, 0x229c_41f7_93cd_a73f,
        0xf3a2_0279_ed56_d48a, 0x6b43_5275_78c1_110f,
        0x9845_418c_3456_44d6, 0x830a_1389_6b78_aaa9,
        0xbe56_91ef_416b_d60c, 0x23cc_986b_c656_d553,
        0xedec_366b_11c6_cb8f, 0x2cbf_be86_b7ec_8aa8,
        0x94b3_a202_eb1c_3f39, 0x7bf7_d714_32f3_d6a9,
        0xb9e0_8a83_a5e3_4f07, 0xdaf5_ccd9_3fb0_cc53,
        0xe858_ad24_8f5c_22c9, 0xd1b3_400f_8f9c_ff68,
        0x9137_6c36_d999_95be, 0x2310_0809_b9c2_1fa1,
        0xb585_4744_8fff_fb2d, 0xabd4_0a0c_2832_a78a,
        0xe2e6_9915_b3ff_f9f9, 0x16c9_0c8f_323f_516c,
        0x8dd0_1fad_907f_fc3b, 0xae3d_a7d9_7f67_92e3,
        0xb144_2798_f49f_fb4a, 0x99cd_11cf_df41_779c,
        0xdd95_317f_31c7_fa1d, 0x4040_5643_d711_d583,
        0x8a7d_3eef_7f1c_fc52, 0x4828_35ea_666b_2572,
        0xad1c_8eab_5ee4_3b66, 0xda32_4365_0005_eecf,
        0xd863_b256_369d_4a40, 0x90be_d43e_4007_6a82,
        0x873e_4f75_e222_4e68, 0x5a77_44a6_e804_a291,
        0xa90d_e353_5aaa_e202, 0x7115_15d0_a205_cb36,
        0xd351_5c28_3155_9a83, 0x0d5a_5b44_ca87_3e03,
        0x8412_d999_1ed5_8091, 0xe858_790a_fe94_86c2,
        0xa517_8fff_668a_e0b6, 0x626e_974d_be39_a872,
        0xce5d_73ff_402d_98e3, 0xfb0a_3d21_2dc8_128f,
        0x80fa_687f_881c_7f8e, 0x7ce6_6634_bc9d_0b99,
        0xa139_029f_6a23_9f72, 0x1c1f_ffc1_ebc4_4e80,
        0xc987_4347_44ac_874e, 0xa327_ffb2_66b5_6220,
        0xfbe9_1419_15d7_a922, 0x4bf1_ff9f_0062_baa8,
        0x9d71_ac8f_ada6_c9b5, 0x6f77_3fc3_603d_b4a9,
        0xc4ce_17b3_9910_7c22, 0xcb55_0fb4_384d_21d3,
        0xf601_9da0_7f54_9b2b, 0x7e2a_53a1_4660_6a48,
        0x99c1_0284_4f94_e0fb, 0x2eda_7444_cbfc_426d,
        0xc031_4325_637a_1939, 0xfa91_1155_fefb_5308,
        0xf03d_93ee_bc58_9f88, 0x7935_55ab_7eba_27ca,
        0x9626_7c75_35b7_63b5, 0x4bc1_558b_2f34_58de,
        0xbbb0_1b92_8325_3ca2, 0x9eb1_aaed_fb01_6f16,
        0xea9c_2277_23ee_8bcb, 0x465e_15a9_79c1_cadc,
        0x92a1_958a_7675_175f, 0x0bfa_cd89_ec19_1ec9,
        0xb749_faed_1412_5d36, 0xcef9_80ec_671f_667b,
        0xe51c_79a8_5916_f484, 0x82b7_e127_80e7_401a,
        0x8f31_cc09_37ae_58d2, 0xd1b2_ecb8_b090_8810,
        0xb2fe_3f0b_8599_ef07, 0x861f_a7e6_dcb4_aa15,
        0xdfbd_cece_6700_6ac9, 0x67a7_91e0_93e1_d49a,
        0x8bd6_a141_0060_42bd, 0xe0c8_bb2c_5c6d_24e0,
        0xaecc_4991_4078_536d, 0x58fa_e9f7_7388_6e18,
        0xda7f_5bf5_9096_6848, 0xaf39_a475_506a_899e,
        0x888f_9979_7a5e_012d, 0x6d84_06c9_5242_9603,
        0xaab3_7fd7_d8f5_8178, 0xc8e5_087b_a6d3_3b83,
        0xd560_5fcd_cf32_e1d6, 0xfb1e_4a9a_9088_0a64,
        0x855c_3be0_a17f_cd26, 0x5cf2_eea0_9a55_067f,
        0xa6b3_4ad8_c9df_c06f, 0xf42f_aa48_c0ea_481e,
        0xd060_1d8e_fc57_b08b, 0xf13b_94da_f124_da26,
        0x823c_1279_5db6_ce57, 0x76c5_3d08_d6b7_0858,
        0xa2cb_1717_b524_81ed, 0x5476_8c4b_0c64_ca6e,
        0xcb7d_dcdd_a26d_a268, 0xa994_2f5d_cf7d_fd09,
        0xfe5d_5415_0b09_0b02, 0xd3f9_3b35_435d_7c4c,
        0x9efa_548d_26e5_a6e1, 0xc47b_c501_4a1a_6daf,
        0xc6b8_e9b0_709f_109a, 0x359a_b641_9ca1_091b,
        0xf867_241c_8cc6_d4c0, 0xc301_63d2_03c9_4b62,
        0x9b40_7691_d7fc_44f8, 0x79e0_de63_425d_cf1d,
        0xc210_9436_4dfb_5636, 0x9859_15fc_12f5_42e4,
        0xf294_b943_e17a_2bc4, 0x3e6f_5b7b_17b2_939d,
        0x979c_f3ca_6cec_5b5a, 0xa705_992c_eecf_9c42,
        0xbd84_30bd_0827_7231, 0x50c6_ff78_2a83_8353,
        0xece5_3cec_4a31_4ebd, 0xa4f8_bf56_3524_6428,
        0x940f_4613_ae5e_d136, 0x871b_7795_e136_be99,
        0xb913_1798_99f6_8584, 0x28e2_557b_5984_6e3f,
        0xe757_dd7e_c074_26e5, 0x331a_eada_2fe5_89cf,
        0x9096_ea6f_3848_984f, 0x3ff0_d2c8_5def_7621,
        0xb4bc_a50b_065a_be63, 0x0fed_077a_756b_53a9,
        0xe1eb_ce4d_c7f1_6dfb, 0xd3e8_4959_12c6_2894,
        0x8d33_60f0_9cf6_e4bd, 0x6471_2dd7_abbb_d95c,
        0xb080_392c_c434_9dec, 0xbd8d_794d_96aa_cfb3,
        0xdca0_4777_f541_c567, 0xecf0_d7a0_fc55_83a0,
        0x89e4_2caa_f949_1b60, 0xf416_86c4_9db5_7244,
        0xac5d_37d5_b79b_6239, 0x311c_2875_c522_ced5,
        0xd774_85cb_2582_3ac7, 0x7d63_3293_366b_828b,
        0x86a8_d39e_f771_64bc, 0xae5d_ff9c_0203_3197,
        0xa853_0886_b54d_bdeb, 0xd9f5_7f83_0283_fdfc,
        0xd267_caa8_62a1_2d66, 0xd072_df63_c324_fd7b,
        0x8380_dea9_3da4_bc60, 0x4247_cb9e_59f7_1e6d,
        0xa461_1653_8d0d_eb78, 0x52d9_be85_f074_e608,
        0xcd79_5be8_7051_6656, 0x6790_2e27_6c92_1f8b,
        0x806b_d971_4632_dff6, 0x00ba_1cd8_a3db_53b6,
        0xa086_cfcd_97bf_97f3, 0x80e8_a40e_ccd2_28a4,
        0xc8a8_83c0_fdaf_7df0, 0x6122_cd12_8006_b2cd,
        0xfad2_a4b1_3d1b_5d6c, 0x796b_8057_2008_5f81,
        0x9cc3_a6ee_c631_1a63, 0xcbe3_3036_7405_3bb0,
        0xc3f4_90aa_77bd_60fc, 0xbedb_fc44_1106_8a9c,
        0xf4f1_b4d5_15ac_b93b, 0xee92_fb55_1548_2d44,
        0x9917_1105_2d8b_f3c5, 0x751b_dd15_2d4d_1c4a,
        0xbf5c_d546_78ee_f0b6, 0xd262_d45a_78a0_635d,
        0xef34_0a98_172a_ace4, 0x86fb_8971_16c8_7c34,
        0x9580_869f_0e7a_ac0e, 0xd45d_35e6_ae3d_4da0,
        0xbae0_a846_d219_5712, 0x8974_8360_59cc_a109,
        0xe998_d258_869f_acd7, 0x2bd1_a438_703f_c94b,
        0x91ff_8377_5423_cc06, 0x7b63_06a3_4627_ddcf,
        0xb67f_6455_292c_bf08, 0x1a3b_c84c_17b1_d542,
        0xe41f_3d6a_7377_eeca, 0x20ca_ba5f_1d9e_4a93,
        0x8e93_8662_882a_f53e, 0x547e_b47b_7282_ee9c,
        0xb238_67fb_2a35_b28d, 0xe99e_619a_4f23_aa43,
        0xdec6_81f9_f4c3_1f31, 0x6405_fa00_e2ec_94d4,
        0x8b3c_113c_38f9_f37e, 0xde83_bc40_8dd3_dd04,
        0xae0b_158b_4738_705e, 0x9624_ab50_b148_d445,
        0xd98d_daee_1906_8c76, 0x3bad_d624_dd9b_0957,
        0x87f8_a8d4_cfa4_17c9, 0xe54c_a5d7_0a80_e5d6,
        0xa9f6_d30a_038d_1dbc, 0x5e9f_cf4c_cd21_1f4c,
        0xd474_87cc_8470_652b, 0x7647_c320_0069_671f,
        0x84c8_d4df_d2c6_3f3b, 0x29ec_d9f4_0041_e073,
        0xa5fb_0a17_c777_cf09, 0xf468_1071_0052_5890,
        0xcf79_cc9d_b955_c2cc, 0x7182_148d_4066_eeb4,
        0x81ac_1fe2_93d5_99bf, 0xc6f1_4cd8_4840_5530,
        0xa217_27db_38cb_002f, 0xb8ad_a00e_5a50_6a7c,
        0xca9c_f1d2_06fd_c03b, 0xa6d9_0811_f0e4_851c,
        0xfd44_2e46_88bd_304a, 0x908f_4a16_6d1d_a663,
        0x9e4a_9cec_1576_3e2e, 0x9a59_8e4e_0432_87fe,
        0xc5dd_4427_1ad3_cdba, 0x40ef_f1e1_853f_29fd,
        0xf754_9530_e188_c128, 0xd12b_ee59_e68e_f47c,
        0x9a94_dd3e_8cf5_78b9, 0x82bb_74f8_3019_58ce,
        0xc13a_148e_3032_d6e7, 0xe36a_5236_3c1f_af01,
        0xf188_99b1_bc3f_8ca1, 0xdc44_e6c3_cb27_9ac1,
        0x96f5_600f_15a7_b7e5, 0x29ab_103a_5ef8_c0b9,
        0xbcb2_b812_db11_a5de, 0x7415_d448_f6b6_f0e7,
        0xebdf_6617_91d6_0f56, 0x111b_495b_3464_ad21,
        0x936b_9fce_bb25_c995, 0xcab1_0dd9_00be_ec34,
        0xb846_87c2_69ef_3bfb, 0x3d5d_514f_40ee_a742,
        0xe658_29b3_046b_0afa, 0x0cb4_a5a3_112a_5112,
        0x8ff7_1a0f_e2c2_e6dc, 0x47f0_e785_eaba_72ab,
        0xb3f4_e093_db73_a093, 0x59ed_2167_6569_0f56,
        0xe0f2_18b8_d250_88b8, 0x3068_69c1_3ec3_532c,
        0x8c97_4f73_8372_5573, 0x1e41_4218_c73a_13fb,
        0xafbd_2350_644e_eacf, 0xe5d1_929e_f908_98fa,
        0xdbac_6c24_7d62_a583, 0xdf45_f746_b74a_bf39,
        0x894b_c396_ce5d_a772, 0x6b8b_ba8c_328e_b783,
        0xab9e_b47c_81f5_114f, 0x066e_a92f_3f32_6564,
        0xd686_619b_a272_55a2, 0xc80a_537b_0efe_febd,
        0x8613_fd01_4587_7585, 0xbd06_742c_e95f_5f36,
        0xa798_fc41_96e9_52e7, 0x2c48_1138_23b7_3704,
        0xd17f_3b51_fca3_a7a0, 0xf75a_1586_2ca5_04c5,
        0x82ef_8513_3de6_48c4, 0x9a98_4d73_dbe7_22fb,
        0xa3ab_6658_0d5f_daf5, 0xc13e_60d0_d2e0_ebba,
        0xcc96_3fee_10b7_d1b3, 0x318d_f905_0799_26a8,
        0xffbb_cfe9_94e5_c61f, 0xfdf1_7746_497f_7052,
        0x9fd5_61f1_fd0f_9bd3, 0xfeb6_ea8b_edef_a633,
        0xc7ca_ba6e_7c53_82c8, 0xfe64_a52e_e96b_8fc0,
        0xf9bd_690a_1b68_637b, 0x3dfd_ce7a_a3c6_73b0,
        0x9c16_61a6_5121_3e2d, 0x06be_a10c_a65c_084e,
        0xc31b_fa0f_e569_8db8, 0x486e_494f_cff3_0a62,
        0xf3e2_f893_dec3_f126, 0x5a89_dba3_c3ef_ccfa,
        0x986d_db5c_6b3a_76b7, 0xf896_2946_5a75_e01c,
        0xbe89_5233_8609_1465, 0xf6bb_b397_f113_5823,
        0xee2b_a6c0_678b_597f, 0x746a_a07d_ed58_2e2c,
        0x94db_4838_40b7_17ef, 0xa8c2_a44e_b457_1cdc,
        0xba12_1a46_50e4_ddeb, 0x92f3_4d62_616c_e413,
        0xe896_a0d7_e51e_1566, 0x77b0_20ba_f9c8_1d17,
        0x915e_2486_ef32_cd60, 0x0ace_1474_dc1d_122e,
        0xb5b5_ada8_aaff_80b8, 0x0d81_9992_1324_56ba,
        0xe323_1912_d5bf_60e6, 0x10e1_fff6_97ed_6c69,
        0x8df5_efab_c597_9c8f, 0xca8d_3ffa_1ef4_63c1,
        0xb173_6b96_b6fd_83b3, 0xbd30_8ff8_a6b1_7cb2,
        0xddd0_467c_64bc_e4a0, 0xac7c_b3f6_d05d_dbde,
        0x8aa2_2c0d_bef6_0ee4, 0x6bcd_f07a_423a_a96b,
        0xad4a_b711_2eb3_929d, 0x86c1_6c98_d2c9_53c6,
        0xd89d_64d5_7a60_7744, 0xe871_c7bf_077b_a8b7,
        0x8762_5f05_6c7c_4a8b, 0x1147_1cd7_64ad_4972,
        0xa93a_f6c6_c79b_5d2d, 0xd598_e40d_3dd8_9bcf,
        0xd389_b478_7982_3479, 0x4aff_1d10_8d4e_c2c3,
        0x8436_10cb_4bf1_60cb, 0xcedf_722a_5851_39ba,
        0xa543_94fe_1eed_b8fe, 0xc297_4eb4_ee65_8828,
        0xce94_7a3d_a6a9_273e, 0x733d_2262_29fe_ea32,
        0x811c_cc66_8829_b887, 0x0806_357d_5a3f_525f,
        0xa163_ff80_2a34_26a8, 0xca07_c2dc_b0cf_26f7,
        0xc9bc_ff60_34c1_3052, 0xfc89_b393_dd02_f0b5,
        0xfc2c_3f38_41f1_7c67, 0xbbac_2078_d443_ace2,
        0x9d9b_a783_2936_edc0, 0xd54b_944b_84aa_4c0d,
        0xc502_9163_f384_a931, 0x0a9e_795e_65d4_df11,
        0xf643_35bc_f065_d37d, 0x4d46_17b5_ff4a_16d5,
        0x99ea_0196_163f_a42e, 0x504b_ced1_bf8e_4e45,
        0xc064_81fb_9bcf_8d39, 0xe45e_c286_2f71_e1d6,
        0xf07d_a27a_82c3_7088, 0x5d76_7327_bb4e_5a4c,
        0x964e_858c_91ba_2655, 0x3a6a_07f8_d510_f86f,
        0xbbe2_26ef_b628_afea, 0x8904_89f7_0a55_368b,
        0xeada_b0ab_a3b2_dbe5, 0x2b45_ac74_ccea_842e,
        0x92c8_ae6b_464f_c96f, 0x3b0b_8bc9_0012_929d,
        0xb77a_da06_17e3_bbcb, 0x09ce_6ebb_4017_3744,
        0xe559_9087_9ddc_aabd, 0xcc42_0a6a_101d_0515,
        0x8f57_fa54_c2a9_eab6, 0x9fa9_4682_4a12_232d,
        0xb32d_f8e9_f354_6564, 0x4793_9822_dc96_abf9,
        0xdff9_7724_7029_7ebd, 0x5978_7e2b_93bc_56f7,
        0x8bfb_ea76_c619_ef36, 0x57eb_4edb_3c55_b65a,
        0xaefa_e514_77a0_6b03, 0xede6_2292_0b6b_23f1,
        0xdab9_9e59_9588_85c4, 0xe95f_ab36_8e45_eced,
        0x88b4_02f7_fd75_539b, 0x11db_cb02_18eb_b414,
        0xaae1_03b5_fcd2_a881, 0xd652_bdc2_9f26_a119,
        0xd599_44a3_7c07_52a2, 0x4be7_6d33_46f0_495f,
        0x857f_cae6_2d84_93a5, 0x6f70_a440_0c56_2ddb,
        0xa6df_bd9f_b8e5_b88e, 0xcb4c_cd50_0f6b_b952,
        0xd097_ad07_a71f_26b2, 0x7e20_00a4_1346_a7a7,
        0x825e_cc24_c873_782f, 0x8ed4_0066_8c0c_28c8,
        0xa2f6_7f2d_fa90_563b, 0x7289_0080_2f0f_32fa,
        0xcbb4_1ef9_7934_6bca, 0x4f2b_40a0_3ad2_ffb9,
        0xfea1_26b7_d781_86bc, 0xe2f6_10c8_4987_bfa8,
        0x9f24_b832_e6b0_f436, 0x0dd9_ca7d_2df4_d7c9,
        0xc6ed_e63f_a05d_3143, 0x9150_3d1c_7972_0dbb,
        0xf8a9_5fcf_8874_7d94, 0x75a4_4c63_97ce_912a,
        0x9b69_dbe1_b548_ce7c, 0xc986_afbe_3ee1_1aba,
        0xc244_52da_229b_021b, 0xfbe8_5bad_ce99_6168,
        0xf2d5_6790_ab41_c2a2, 0xfae2_7299_423f_b9c3,
        0x97c5_60ba_6b09_19a5, 0xdccd_879f_c967_d41a,
        0xbdb6_b8e9_05cb_600f, 0x5400_e987_bbc1_c920,
        0xed24_6723_473e_3813, 0x2901_23e9_aab2_3b68,
        0x9436_c076_0c86_e30b, 0xf9a0_b672_0aaf_6521,
        0xb944_7093_8fa8_9bce, 0xf808_e40e_8d5b_3e69,
        0xe795_8cb8_7392_c2c2, 0xb60b_1d12_30b2_0e04,
        0x90bd_77f3_483b_b9b9, 0xb1c6_f22b_5e6f_48c2,
        0xb4ec_d5f0_1a4a_a828, 0x1e38_aeb6_360b_1af3,
        0xe228_0b6c_20dd_5232, 0x25c6_da63_c38d_e1b0,
        0x8d59_0723_948a_535f, 0x579c_487e_5a38_ad0e,
        0xb0af_48ec_79ac_e837, 0x2d83_5a9d_f0c6_d851,
        0xdcdb_1b27_9818_2244, 0xf8e4_3145_6cf8_8e65,
        0x8a08_f0f8_bf0f_156b, 0x1b8e_9ecb_641b_58ff,
        0xac8b_2d36_eed2_dac5, 0xe272_467e_3d22_2f3f,
        0xd7ad_f884_aa87_9177, 0x5b0e_d81d_cc6a_bb0f,
        0x86cc_bb52_ea94_baea, 0x98e9_4712_9fc2_b4e9,
        0xa87f_ea27_a539_e9a5, 0x3f23_98d7_47b3_6224,
        0xd29f_e4b1_8e88_640e, 0x8eec_7f0d_19a0_3aad,
        0x83a3_eeee_f915_3e89, 0x1953_cf68_3004_24ac,
        0xa48c_eaaa_b75a_8e2b, 0x5fa8_c342_3c05_2dd7,
        0xcdb0_2555_6531_31b6, 0x3792_f412_cb06_794d,
        0x808e_1755_5f3e_bf11, 0xe2bb_d88b_bee4_0bd0,
        0xa0b1_9d2a_b70e_6ed6, 0x5b6a_ceae_ae9d_0ec4,
        0xc8de_0475_64d2_0a8b, 0xf245_825a_5a44_5275,
        0xfb15_8592_be06_8d2e, 0xeed6_e2f0_f0d5_6712,
        0x9ced_737b_b6c4_183d, 0x5546_4dd6_9685_606b,
        0xc428_d05a_a475_1e4c, 0xaa97_e14c_3c26_b886,
        0xf533_0471_4d92_65df, 0xd53d_d99f_4b30_66a8,
        0x993f_e2c6_d07b_7fab, 0xe546_a803_8efe_4029,
        0xbf8f_db78_849a_5f96, 0xde98_5204_72bd_d033,
        0xef73_d256_a5c0_f77c, 0x963e_6685_8f6d_4440,
        0x95a8_6376_2798_9aad, 0xdde7_0013_79a4_4aa8,
        0xbb12_7c53_b17e_c159, 0x5560_c018_580d_5d52,
        0xe9d7_1b68_9dde_71af, 0xaab8_f01e_6e10_b4a6,
        0x9226_7121_62ab_070d, 0xcab3_9613_04ca_70e8,
        0xb6b0_0d69_bb55_c8d1, 0x3d60_7b97_c5fd_0d22,
        0xe45c_10c4_2a2b_3b05, 0x8cb8_9a7d_b77c_506a,
        0x8eb9_8a7a_9a5b_04e3, 0x77f3_608e_92ad_b242,
        0xb267_ed19_40f1_c61c, 0x55f0_38b2_3759_1ed3,
        0xdf01_e85f_912e_37a3, 0x6b6c_46de_c52f_6688,
        0x8b61_313b_babc_e2c6, 0x2323_ac4b_3b3d_a015,
        0xae39_7d8a_a96c_1b77, 0xabec_975e_0a0d_081a,
        0xd9c7_dced_53c7_2255, 0x96e7_bd35_8c90_4a21,
        0x881c_ea14_545c_7575, 0x7e50_d641_77da_2e54,
        0xaa24_2499_6973_92d2, 0xdde5_0bd1_d5d0_b9e9,
        0xd4ad_2dbf_c3d0_7787, 0x955e_4ec6_4b44_e864,
        0x84ec_3c97_da62_4ab4, 0xbd5a_f13b_ef0b_113e,
        0xa627_4bbd_d0fa_dd61, 0xecb1_ad8a_eacd_d58e,
        0xcfb1_1ead_4539_94ba, 0x67de_18ed_a581_4af2,
        0x81ce_b32c_4b43_fcf4, 0x80ea_cf94_8770_ced7,
        0xa242_5ff7_5e14_fc31, 0xa125_8379_a94d_028d,
        0xcad2_f7f5_359a_3b3e, 0x096e_e458_13a0_4330,
        0xfd87_b5f2_8300_ca0d, 0x8bca_9d6e_1888_53fc,
        0x9e74_d1b7_91e0_7e48, 0x775e_a264_cf55_347e,
        0xc612_0625_7658_9dda, 0x9536_4afe_032a_819e,
        0xf796_87ae_d3ee_c551, 0x3a83_ddbd_83f5_2205,
        0x9abe_14cd_4475_3b52, 0xc492_6a96_7279_3543,
        0xc16d_9a00_9592_8a27, 0x75b7_053c_0f17_8294,
        0xf1c9_0080_baf7_2cb1, 0x5324_c68b_12dd_6339,
        0x971d_a050_74da_7bee, 0xd3f6_fc16_ebca_5e04,
        0xbce5_0864_9211_1aea, 0x88f4_bb1c_a6bc_f585,
        0xec1e_4a7d_b695_61a5, 0x2b31_e9e3_d06c_32e6,
        0x9392_ee8e_921d_5d07, 0x3aff_322e_6243_9fd0,
        0xb877_aa32_36a4_b449, 0x09be_feb9_fad4_87c3,
        0xe695_94be_c44d_e15b, 0x4c2e_be68_7989_a9b4,
        0x901d_7cf7_3ab0_acd9, 0x0f9d_3701_4bf6_0a11,
        0xb424_dc35_095c_d80f, 0x5384_84c1_9ef3_8c95,
        0xe12e_1342_4bb4_0e13, 0x2865_a5f2_06b0_6fba,
        0x8cbc_cc09_6f50_88cb, 0xf93f_87b7_442e_45d4,
        0xafeb_ff0b_cb24_aafe, 0xf78f_69a5_1539_d749,
        0xdbe6_fece_bded_d5be, 0xb573_440e_5a88_4d1c,
        0x8970_5f41_36b4_a597, 0x3168_0a88_f895_3031,
        0xabcc_7711_8461_cefc, 0xfdc2_0d2b_36ba_7c3e,
        0xd6bf_94d5_e57a_42bc, 0x3d32_9076_0469_1b4d,
        0x8637_bd05_af6c_69b5, 0xa63f_9a49_c2c1_b110,
        0xa7c5_ac47_1b47_8423, 0x0fcf_80dc_3372_1d54,
        0xd1b7_1758_e219_652b, 0xd3c3_6113_404e_a4a9,
        0x8312_6e97_8d4f_df3b, 0x645a_1cac_0831_26ea,
        0xa3d7_0a3d_70a3_d70a, 0x3d70_a3d7_0a3d_70a4,
        0xcccc_cccc_cccc_cccc, 0xcccc_cccc_cccc_cccd,
        0x8000_0000_0000_0000, 0x0000_0000_0000_0000,
        0xa000_0000_0000_0000, 0x0000_0000_0000_0000,
        0xc800_0000_0000_0000, 0x0000_0000_0000_0000,
        0xfa00_0000_0000_0000, 0x0000_0000_0000_0000,
        0x9c40_0000_0000_0000, 0x0000_0000_0000_0000,
        0xc350_0000_0000_0000, 0x0000_0000_0000_0000,
        0xf424_0000_0000_0000, 0x0000_0000_0000_0000,
        0x9896_8000_0000_0000, 0x0000_0000_0000_0000,
        0xbebc_2000_0000_0000, 0x0000_0000_0000_0000,
        0xee6b_2800_0000_0000, 0x0000_0000_0000_0000,
        0x9502_f900_0000_0000, 0x0000_0000_0000_0000,
        0xba43_b740_0000_0000, 0x0000_0000_0000_0000,
        0xe8d4_a510_0000_0000, 0x0000_0000_0000_0000,
        0x9184_e72a_0000_0000, 0x0000_0000_0000_0000,
        0xb5e6_20f4_8000_0000, 0x0000_0000_0000_0000,
        0xe35f_a931_a000_0000, 0x0000_0000_0000_0000,
        0x8e1b_c9bf_0400_0000, 0x0000_0000_0000_0000,
        0xb1a2_bc2e_c500_0000, 0x0000_0000_0000_0000,
        0xde0b_6b3a_7640_0000, 0x0000_0000_0000_0000,
        0x8ac7_2304_89e8_0000, 0x0000_0000_0000_0000,
        0xad78_ebc5_ac62_0000, 0x0000_0000_0000_0000,
        0xd8d7_26b7_177a_8000, 0x0000_0000_0000_0000,
        0x8786_7832_6eac_9000, 0x0000_0000_0000_0000,
        0xa968_163f_0a57_b400, 0x0000_0000_0000_0000,
        0xd3c2_1bce_cced_a100, 0x0000_0000_0000_0000,
        0x8459_5161_4014_84a0, 0x0000_0000_0000_0000,
        0xa56f_a5b9_9019_a5c8, 0x0000_0000_0000_0000,
        0xcecb_8f27_f420_0f3a, 0x0000_0000_0000_0000,
        0x813f_3978_f894_0984, 0x4000_0000_0000_0000,
        0xa18f_07d7_36b9_0be5, 0x5000_0000_0000_0000,
        0xc9f2_c9cd_0467_4ede, 0xa400_0000_0000_0000,
        0xfc6f_7c40_4581_2296, 0x4d00_0000_0000_0000,
        0x9dc5_ada8_2b70_b59d, 0xf020_0000_0000_0000,
        0xc537_1912_364c_e305, 0x6c28_0000_0000_0000,
        0xf684_df56_c3e0_1bc6, 0xc732_0000_0000_0000,
        0x9a13_0b96_3a6c_115c, 0x3c7f_4000_0000_0000,
        0xc097_ce7b_c907_15b3, 0x4b9f_1000_0000_0000,
        0xf0bd_c21a_bb48_db20, 0x1e86_d400_0000_0000,
        0x9676_9950_b50d_88f4, 0x1314_4480_0000_0000,
        0xbc14_3fa4_e250_eb31, 0x17d9_55a0_0000_0000,
        0xeb19_4f8e_1ae5_25fd, 0x5dcf_ab08_0000_0000,
        0x92ef_d1b8_d0cf_37be, 0x5aa1_cae5_0000_0000,
        0xb7ab_c627_0503_05ad, 0xf14a_3d9e_4000_0000,
        0xe596_b7b0_c643_c719, 0x6d9c_cd05_d000_0000,
        0x8f7e_32ce_7bea_5c6f, 0xe482_0023_a200_0000,
        0xb35d_bf82_1ae4_f38b, 0xdda2_802c_8a80_0000,
        0xe035_2f62_a19e_306e, 0xd50b_2037_ad20_0000,
        0x8c21_3d9d_a502_de45, 0x4526_f422_cc34_0000,
        0xaf29_8d05_0e43_95d6, 0x9670_b12b_7f41_0000,
        0xdaf3_f046_51d4_7b4c, 0x3c0c_dd76_5f11_4000,
        0x88d8_762b_f324_cd0f, 0xa588_0a69_fb6a_c800,
        0xab0e_93b6_efee_0053, 0x8eea_0d04_7a45_7a00,
        0xd5d2_38a4_abe9_8068, 0x72a4_9045_98d6_d880,
        0x85a3_6366_eb71_f041, 0x47a6_da2b_7f86_4750,
        0xa70c_3c40_a64e_6c51, 0x9990_90b6_5f67_d924,
        0xd0cf_4b50_cfe2_0765, 0xfff4_b4e3_f741_cf6d,
        0x8281_8f12_81ed_449f, 0xbff8_f10e_7a89_21a4,
        0xa321_f2d7_2268_95c7, 0xaff7_2d52_192b_6a0d,
        0xcbea_6f8c_eb02_bb39, 0x9bf4_f8a6_9f76_4490,
        0xfee5_0b70_25c3_6a08, 0x02f2_36d0_4753_d5b4,
        0x9f4f_2726_179a_2245, 0x01d7_6242_2c94_6590,
        0xc722_f0ef_9d80_aad6, 0x424d_3ad2_b7b9_7ef5,
        0xf8eb_ad2b_84e0_d58b, 0xd2e0_8987_65a7_deb2,
        0x9b93_4c3b_330c_8577, 0x63cc_55f4_9f88_eb2f,
        0xc278_1f49_ffcf_a6d5, 0x3cbf_6b71_c76b_25fb,
        0xf316_271c_7fc3_908a, 0x8bef_464e_3945_ef7a,
        0x97ed_d871_cfda_3a56, 0x9775_8bf0_e3cb_b5ac,
        0xbde9_4e8e_43d0_c8ec, 0x3d52_eeed_1cbe_a317,
        0xed63_a231_d4c4_fb27, 0x4ca7_aaa8_63ee_4bdd,
        0x945e_455f_24fb_1cf8, 0x8fe8_caa9_3e74_ef6a,
        0xb975_d6b6_ee39_e436, 0xb3e2_fd53_8e12_2b44,
        0xe7d3_4c64_a9c8_5d44, 0x60db_bca8_7196_b616,
        0x90e4_0fbe_ea1d_3a4a, 0xbc89_55e9_46fe_31cd,
        0xb51d_13ae_a4a4_88dd, 0x6bab_ab63_98bd_be41,
        0xe264_589a_4dcd_ab14, 0xc696_963c_7eed_2dd1,
        0x8d7e_b760_70a0_8aec, 0xfc1e_1de5_cf54_3ca2,
        0xb0de_6538_8cc8_ada8, 0x3b25_a55f_4329_4bcb,
        0xdd15_fe86_affa_d912, 0x49ef_0eb7_13f3_9ebe,
        0x8a2d_bf14_2dfc_c7ab, 0x6e35_6932_6c78_4337,
        0xacb9_2ed9_397b_f996, 0x49c2_c37f_0796_5404,
        0xd7e7_7a8f_87da_f7fb, 0xdc33_745e_c97b_e906,
        0x86f0_ac99_b4e8_dafd, 0x69a0_28bb_3ded_71a3,
        0xa8ac_d7c0_2223_11bc, 0xc408_32ea_0d68_ce0c,
        0xd2d8_0db0_2aab_d62b, 0xf50a_3fa4_90c3_0190,
        0x83c7_088e_1aab_65db, 0x7926_67c6_da79_e0fa,
        0xa4b8_cab1_a156_3f52, 0x5770_01b8_9118_5938,
        0xcde6_fd5e_09ab_cf26, 0xed4c_0226_b55e_6f86,
        0x80b0_5e5a_c60b_6178, 0x544f_8158_315b_05b4,
        0xa0dc_75f1_778e_39d6, 0x6963_61ae_3db1_c721,
        0xc913_936d_d571_c84c, 0x03bc_3a19_cd1e_38e9,
        0xfb58_7849_4ace_3a5f, 0x04ab_48a0_4065_c723,
        0x9d17_4b2d_cec0_e47b, 0x62eb_0d64_283f_9c76,
        0xc45d_1df9_4271_1d9a, 0x3ba5_d0bd_324f_8394,
        0xf574_6577_930d_6500, 0xca8f_44ec_7ee3_6479,
        0x9968_bf6a_bbe8_5f20, 0x7e99_8b13_cf4e_1ecb,
        0xbfc2_ef45_6ae2_76e8, 0x9e3f_edd8_c321_a67e,
        0xefb3_ab16_c59b_14a2, 0xc5cf_e94e_f3ea_101e,
        0x95d0_4aee_3b80_ece5, 0xbba1_f1d1_5872_4a12,
        0xbb44_5da9_ca61_281f, 0x2a8a_6e45_ae8e_dc97,
        0xea15_7514_3cf9_7226, 0xf52d_09d7_1a32_93bd,
        0x924d_692c_a61b_e758, 0x593c_2626_705f_9c56,
        0xb6e0_c377_cfa2_e12e, 0x6f8b_2fb0_0c77_836c,
        0xe498_f455_c38b_997a, 0x0b6d_fb9c_0f95_6447,
        0x8edf_98b5_9a37_3fec, 0x4724_bd41_89bd_5eac,
        0xb297_7ee3_00c5_0fe7, 0x58ed_ec91_ec2c_b657,
        0xdf3d_5e9b_c0f6_53e1, 0x2f29_67b6_6737_e3ed,
        0x8b86_5b21_5899_f46c, 0xbd79_e0d2_0082_ee74,
        0xae67_f1e9_aec0_7187, 0xecd8_5906_80a3_aa11,
        0xda01_ee64_1a70_8de9, 0xe80e_6f48_20cc_9495,
        0x8841_34fe_9086_58b2, 0x3109_058d_147f_dcdd,
        0xaa51_823e_34a7_eede, 0xbd4b_46f0_599f_d415,
        0xd4e5_e2cd_c1d1_ea96, 0x6c9e_18ac_7007_c91a,
        0x850f_adc0_9923_329e, 0x03e2_cf6b_c604_ddb0,
        0xa653_9930_bf6b_ff45, 0x84db_8346_b786_151c,
        0xcfe8_7f7c_ef46_ff16, 0xe612_6418_6567_9a63,
        0x81f1_4fae_158c_5f6e, 0x4fcb_7e8f_3f60_c07e,
        0xa26d_a399_9aef_7749, 0xe3be_5e33_0f38_f09d,
        0xcb09_0c80_01ab_551c, 0x5cad_f5bf_d307_2cc5,
        0xfdcb_4fa0_0216_2a63, 0x73d9_732f_c7c8_f7f6,
        0x9e9f_11c4_014d_da7e, 0x2867_e7fd_dcdd_9afa,
        0xc646_d635_01a1_511d, 0xb281_e1fd_5415_01b8,
        0xf7d8_8bc2_4209_a565, 0x1f22_5a7c_a91a_4226,
        0x9ae7_5759_6946_075f, 0x3375_788d_e9b0_6958,
        0xc1a1_2d2f_c397_8937, 0x0052_d6b1_641c_83ae,
        0xf209_787b_b47d_6b84, 0xc067_8c5d_bd23_a49a,
        0x9745_eb4d_50ce_6332, 0xf840_b7ba_9636_46e0,
        0xbd17_6620_a501_fbff, 0xb650_e5a9_3bc3_d898,
        0xec5d_3fa8_ce42_7aff, 0xa3e5_1f13_8ab4_cebe,
        0x93ba_47c9_80e9_8cdf, 0xc66f_336c_36b1_0137,
        0xb8a8_d9bb_e123_f017, 0xb80b_0047_445d_4184,
        0xe6d3_102a_d96c_ec1d, 0xa60d_c059_1574_91e5,
        0x9043_ea1a_c7e4_1392, 0x87c8_9837_ad68_db2f,
        0xb454_e4a1_79dd_1877, 0x29ba_be45_98c3_11fb,
        0xe16a_1dc9_d854_5e94, 0xf429_6dd6_fef3_d67a,
        0x8ce2_529e_2734_bb1d, 0x1899_e4a6_5f58_660c,
        0xb01a_e745_b101_e9e4, 0x5ec0_5dcf_f72e_7f8f,
        0xdc21_a117_1d42_645d, 0x7670_7543_f4fa_1f73,
        0x8995_04ae_7249_7eba, 0x6a06_494a_791c_53a8,
        0xabfa_45da_0edb_de69, 0x0487_db9d_1763_6892,
        0xd6f8_d750_9292_d603, 0x45a9_d284_5d3c_42b6,
        0x865b_8692_5b9b_c5c2, 0x0b8a_2392_ba45_a9b2,
        0xa7f2_6836_f282_b732, 0x8e6c_ac77_68d7_141e,
        0xd1ef_0244_af23_64ff, 0x3207_d795_430c_d926,
        0x8335_616a_ed76_1f1f, 0x7f44_e6bd_49e8_07b8,
        0xa402_b9c5_a8d3_a6e7, 0x5f16_206c_9c62_09a6,
        0xcd03_6837_1308_90a1, 0x36db_a887_c37a_8c0f,
        0x8022_2122_6be5_5a64, 0xc249_4954_da2c_9789,
        0xa02a_a96b_06de_b0fd, 0xf2db_9baa_10b7_bd6c,
        0xc835_53c5_c896_5d3d, 0x6f92_8294_94e5_acc7,
        0xfa42_a8b7_3abb_f48c, 0xcb77_2339_ba1f_17f9,
        0x9c69_a972_84b5_78d7, 0xff2a_7604_1453_6efb,
        0xc384_13cf_25e2_d70d, 0xfef5_1385_1968_4aba,
        0xf465_18c2_ef5b_8cd1, 0x7eb2_5866_5fc2_5d69,
        0x98bf_2f79_d599_3802, 0xef2f_773f_fbd9_7a61,
        0xbeee_fb58_4aff_8603, 0xaafb_550f_facf_d8fa,
        0xeeaa_ba2e_5dbf_6784, 0x95ba_2a53_f983_cf38,
        0x952a_b45c_fa97_a0b2, 0xdd94_5a74_7bf2_6183,
        0xba75_6174_393d_88df, 0x94f9_7111_9aee_f9e4,
        0xe912_b9d1_478c_eb17, 0x7a37_cd56_01aa_b85d,
        0x91ab_b422_ccb8_12ee, 0xac62_e055_c10a_b33a,
        0xb616_a12b_7fe6_17aa, 0x577b_986b_314d_6009,
        0xe39c_4976_5fdf_9d94, 0xed5a_7e85_fda0_b80b,
        0x8e41_ade9_fbeb_c27d, 0x1458_8f13_be84_7307,
        0xb1d2_1964_7ae6_b31c, 0x596e_b2d8_ae25_8fc8,
        0xde46_9fbd_99a0_5fe3, 0x6fca_5f8e_d9ae_f3bb,
        0x8aec_23d6_8004_3bee, 0x25de_7bb9_480d_5854,
        0xada7_2ccc_2005_4ae9, 0xaf56_1aa7_9a10_ae6a,
        0xd910_f7ff_2806_9da4, 0x1b2b_a151_8094_da04,
        0x87aa_9aff_7904_2286, 0x90fb_44d2_f05d_0842,
        0xa995_41bf_5745_2b28, 0x353a_1607_ac74_4a53,
        0xd3fa_922f_2d16_75f2, 0x4288_9b89_9791_5ce8,
        0x847c_9b5d_7c2e_09b7, 0x6995_6135_feba_da11,
        0xa59b_c234_db39_8c25, 0x43fa_b983_7e69_9095,
        0xcf02_b2c2_1207_ef2e, 0x94f9_67e4_5e03_f4bb,
        0x8161_afb9_4b44_f57d, 0x1d1b_e0ee_bac2_78f5,
        0xa1ba_1ba7_9e16_32dc, 0x6462_d92a_6973_1732,
        0xca28_a291_859b_bf93, 0x7d7b_8f75_03cf_dcfe,
        0xfcb2_cb35_e702_af78, 0x5cda_7352_44c3_d43e,
        0x9def_bf01_b061_adab, 0x3a08_8813_6afa_64a7,
        0xc56b_aec2_1c7a_1916, 0x088a_aa18_45b8_fdd0,
        0xf6c6_9a72_a398_9f5b, 0x8aad_549e_5727_3d45,
        0x9a3c_2087_a63f_6399, 0x36ac_54e2_f678_864b,
        0xc0cb_28a9_8fcf_3c7f, 0x8457_6a1b_b416_a7dd,
        0xf0fd_f2d3_f3c3_0b9f, 0x656d_44a2_a11c_51d5,
        0x969e_b7c4_7859_e743, 0x9f64_4ae5_a4b1_b325,
        0xbc46_65b5_9670_6114, 0x873d_5d9f_0dde_1fee,
        0xeb57_ff22_fc0c_7959, 0xa90c_b506_d155_a7ea,
        0x9316_ff75_dd87_cbd8, 0x09a7_f124_42d5_88f2,
        0xb7dc_bf53_54e9_bece, 0x0c11_ed6d_538a_eb2f,
        0xe5d3_ef28_2a24_2e81, 0x8f16_68c8_a86d_a5fa,
        0x8fa4_7579_1a56_9d10, 0xf96e_017d_6944_87bc,
        0xb38d_92d7_60ec_4455, 0x37c9_81dc_c395_a9ac,
        0xe070_f78d_3927_556a, 0x85bb_e253_f47b_1417,
        0x8c46_9ab8_43b8_9562, 0x9395_6d74_78cc_ec8e,
        0xaf58_4166_54a6_babb, 0x387a_c8d1_9700_27b2,
        0xdb2e_51bf_e9d0_696a, 0x0699_7b05_fcc0_319e,
        0x88fc_f317_f222_41e2, 0x441f_ece3_bdf8_1f03,
        0xab3c_2fdd_eeaa_d25a, 0xd527_e81c_ad76_26c3,
        0xd60b_3bd5_6a55_86f1, 0x8a71_e223_d8d3_b074,
        0x85c7_0565_6275_7456, 0xf687_2d56_6784_4e49,
        0xa738_c6be_bb12_d16c, 0xb428_f8ac_0165_61db,
        0xd106_f86e_69d7_85c7, 0xe133_36d7_01be_ba52,
        0x82a4_5b45_0226_b39c, 0xecc0_0246_6117_3473,
        0xa34d_7216_42b0_6084, 0x27f0_02d7_f95d_0190,
        0xcc20_ce9b_d35c_78a5, 0x31ec_038d_f7b4_41f4,
        0xff29_0242_c833_96ce, 0x7e67_0471_75a1_5271,
        0x9f79_a169_bd20_3e41, 0x0f00_62c6_e984_d386,
        0xc758_09c4_2c68_4dd1, 0x52c0_7b78_a3e6_0868,
        0xf92e_0c35_3782_6145, 0xa770_9a56_ccdf_8a82,
        0x9bbc_c7a1_42b1_7ccb, 0x88a6_6076_400b_b691,
        0xc2ab_f989_935d_dbfe, 0x6acf_f893_d00e_a435,
        0xf356_f7eb_f835_52fe, 0x0583_f6b8_c412_4d43,
        0x9816_5af3_7b21_53de, 0xc372_7a33_7a8b_704a,
        0xbe1b_f1b0_59e9_a8d6, 0x744f_18c0_592e_4c5c,
        0xeda2_ee1c_7064_130c, 0x1162_def0_6f79_df73,
        0x9485_d4d1_c63e_8be7, 0x8add_cb56_45ac_2ba8,
        0xb9a7_4a06_37ce_2ee1, 0x6d95_3e2b_d717_3692,
        0xe811_1c87_c5c1_ba99, 0xc8fa_8db6_ccdd_0437,
        0x910a_b1d4_db99_14a0, 0x1d9c_9892_400a_22a2,
        0xb54d_5e4a_127f_59c8, 0x2503_beb6_d00c_ab4b,
        0xe2a0_b5dc_971f_303a, 0x2e44_ae64_840f_d61d,
        0x8da4_71a9_de73_7e24, 0x5cea_ecfe_d289_e5d2,
        0xb10d_8e14_5610_5dad, 0x7425_a83e_872c_5f47,
        0xdd50_f199_6b94_7518, 0xd12f_124e_28f7_7719,
        0x8a52_96ff_e33c_c92f, 0x82bd_6b70_d99a_aa6f,
        0xace7_3cbf_dc0b_fb7b, 0x636c_c64d_1001_550b,
        0xd821_0bef_d30e_fa5a, 0x3c47_f7e0_5401_aa4e,
        0x8714_a775_e3e9_5c78, 0x65ac_faec_3481_0a71,
        0xa8d9_d153_5ce3_b396, 0x7f18_39a7_41a1_4d0d,
        0xd310_45a8_341c_a07c, 0x1ede_4811_1209_a050,
        0x83ea_2b89_2091_e44d, 0x934a_ed0a_ab46_0432,
        0xa4e4_b66b_68b6_5d60, 0xf81d_a84d_5617_853f,
        0xce1d_e406_42e3_f4b9, 0x3625_1260_ab9d_668e,
        0x80d2_ae83_e9ce_78f3, 0xc1d7_2b7c_6b42_6019,
        0xa107_5a24_e442_1730, 0xb24c_f65b_8612_f81f,
        0xc949_30ae_1d52_9cfc, 0xdee0_33f2_6797_b627,
        0xfb9b_7cd9_a4a7_443c, 0x1698_40ef_017d_a3b1,
        0x9d41_2e08_06e8_8aa5, 0x8e1f_2895_60ee_864e,
        0xc491_798a_08a2_ad4e, 0xf1a6_f2ba_b92a_27e2,
        0xf5b5_d7ec_8acb_58a2, 0xae10_af69_6774_b1db,
        0x9991_a6f3_d6bf_1765, 0xacca_6da1_e0a8_ef29,
        0xbff6_10b0_cc6e_dd3f, 0x17fd_090a_58d3_2af3,
        0xeff3_94dc_ff8a_948e, 0xddfc_4b4c_ef07_f5b0,
        0x95f8_3d0a_1fb6_9cd9, 0x4abd_af10_1564_f98e,
        0xbb76_4c4c_a7a4_440f, 0x9d6d_1ad4_1abe_37f1,
        0xea53_df5f_d18d_5513, 0x84c8_6189_216d_c5ed,
        0x9274_6b9b_e2f8_552c, 0x32fd_3cf5_b4e4_9bb4,
        0xb711_8682_dbb6_6a77, 0x3fbc_8c33_221d_c2a1,
        0xe4d5_e823_92a4_0515, 0x0fab_af3f_eaa5_334a,
        0x8f05_b116_3ba6_832d, 0x29cb_4d87_f2a7_400e,
        0xb2c7_1d5b_ca90_23f8, 0x743e_20e9_ef51_1012,
        0xdf78_e4b2_bd34_2cf6, 0x914d_a924_6b25_5416,
        0x8bab_8eef_b640_9c1a, 0x1ad0_89b6_c2f7_548e,
        0xae96_72ab_a3d0_c320, 0xa184_ac24_73b5_29b1,
        0xda3c_0f56_8cc4_f3e8, 0xc9e5_d72d_90a2_741e,
        0x8865_8996_17fb_1871, 0x7e2f_a67c_7a65_8892,
        0xaa7e_ebfb_9df9_de8d, 0xddbb_901b_98fe_eab7,
        0xd51e_a6fa_8578_5631, 0x552a_7422_7f3e_a565,
        0x8533_285c_936b_35de, 0xd53a_8895_8f87_275f,
        0xa67f_f273_b846_0356, 0x8a89_2aba_f368_f137,
        0xd01f_ef10_a657_842c, 0x2d2b_7569_b043_2d85,
        0x8213_f56a_67f6_b29b, 0x9c3b_2962_0e29_fc73,
        0xa298_f2c5_01f4_5f42, 0x8349_f3ba_91b4_7b8f,
        0xcb3f_2f76_4271_7713, 0x241c_70a9_3621_9a73,
        0xfe0e_fb53_d30d_d4d7, 0xed23_8cd3_83aa_0110,
        0x9ec9_5d14_63e8_a506, 0xf436_3804_324a_40aa,
        0xc67b_b459_7ce2_ce48, 0xb143_c605_3edc_d0d5,
        0xf81a_a16f_dc1b_81da, 0xdd94_b786_8e94_050a,
        0x9b10_a4e5_e991_3128, 0xca7c_f2b4_191c_8326,
        0xc1d4_ce1f_63f5_7d72, 0xfd1c_2f61_1f63_a3f0,
        0xf24a_01a7_3cf2_dccf, 0xbc63_3b39_673c_8cec,
        0x976e_4108_8617_ca01, 0xd5be_0503_e085_d813,
        0xbd49_d14a_a79d_bc82, 0x4b2d_8644_d8a7_4e18,
        0xec9c_459d_5185_2ba2, 0xddf8_e7d6_0ed1_219e,
        0x93e1_ab82_52f3_3b45, 0xcabb_90e5_c942_b503,
        0xb8da_1662_e7b0_0a17, 0x3d6a_751f_3b93_6243,
        0xe710_9bfb_a19c_0c9d, 0x0cc5_1267_0a78_3ad4,
        0x906a_617d_4501_87e2, 0x27fb_2b80_668b_24c5,
        0xb484_f9dc_9641_e9da, 0xb1f9_f660_802d_edf6,
        0xe1a6_3853_bbd2_6451, 0x5e78_73f8_a039_6973,
        0x8d07_e334_5563_7eb2, 0xdb0b_487b_6423_e1e8,
        0xb049_dc01_6abc_5e5f, 0x91ce_1a9a_3d2c_da62,
        0xdc5c_5301_c56b_75f7, 0x7641_a140_cc78_10fb,
        0x89b9_b3e1_1b63_29ba, 0xa9e9_04c8_7fcb_0a9d,
        0xac28_20d9_623b_f429, 0x5463_45fa_9fbd_cd44,
        0xd732_290f_baca_f133, 0xa97c_1779_47ad_4095,
        0x867f_59a9_d4be_d6c0, 0x49ed_8eab_cccc_485d,
        0xa81f_3014_49ee_8c70, 0x5c68_f256_bfff_5a74,
        0xd226_fc19_5c6a_2f8c, 0x7383_2eec_6fff_3111,
        0x8358_5d8f_d9c2_5db7, 0xc831_fd53_c5ff_7eab,
        0xa42e_74f3_d032_f525, 0xba3e_7ca8_b77f_5e55,
        0xcd3a_1230_c43f_b26f, 0x28ce_1bd2_e55f_35eb,
        0x8044_4b5e_7aa7_cf85, 0x7980_d163_cf5b_81b3,
        0xa055_5e36_1951_c366, 0xd7e1_05bc_c332_621f,
        0xc86a_b5c3_9fa6_3440, 0x8dd9_472b_f3fe_faa7,
        0xfa85_6334_878f_c150, 0xb14f_98f6_f0fe_b951,
        0x9c93_5e00_d4b9_d8d2, 0x6ed1_bf9a_569f_33d3,
        0xc3b8_3581_09e8_4f07, 0x0a86_2f80_ec47_00c8,
        0xf4a6_42e1_4c62_62c8, 0xcd27_bb61_2758_c0fa,
        0x98e7_e9cc_cfbd_7dbd, 0x8038_d51c_b897_789c,
        0xbf21_e440_03ac_dd2c, 0xe047_0a63_e6bd_56c3,
        0xeeea_5d50_0498_1478, 0x1858_ccfc_e06c_ac74,
        0x9552_7a52_02df_0ccb, 0x0f37_801e_0c43_ebc8,
        0xbaa7_18e6_8396_cffd, 0xd305_6025_8f54_e6ba,
        0xe950_df20_247c_83fd, 0x47c6_b82e_f32a_2069,
        0x91d2_8b74_16cd_d27e, 0x4cdc_331d_57fa_5441,
        0xb647_2e51_1c81_471d, 0xe013_3fe4_adf8_e952,
        0xe3d8_f9e5_63a1_98e5, 0x5818_0fdd_d977_23a6,
        0x8e67_9c2f_5e44_ff8f, 0x570f_09ea_a7ea_7648,
    ]
}

// MARK: - fast_float bigint

// vector-like type with a fixed capacity: only the length changes. Each operation that would exceed the capacity
// fails, after the same partial update as the C++.
private struct StackVec {
    // number of bits in a bigint. this needs to be at least the number
    // of bits required to store the largest bigint, which is
    // `log2(10**(digits + max_exp))`, or `log2(10**(767 + 342))`, or
    // ~3600 bits, so we round to 4000.
    static let capacity = 4000 / 64

    var data: [UInt64] = []

    init() {}

    // create stack vector from existing limb span.
    init(_ s: [UInt64]) {
        _ = tryExtend(s)
    }

    var len: Int { data.count }

    var isEmpty: Bool { data.isEmpty }

    // index from the end of the container
    func rindex(_ index: Int) -> UInt64 {
        data[data.count - index - 1]
    }

    // append item to vector, returning if item was added
    mutating func tryPush(_ value: UInt64) -> Bool {
        if len < Self.capacity {
            data.append(value)
            return true
        }
        return false
    }

    // try to add items to the vector, returning if items were added
    mutating func tryExtend(_ s: [UInt64]) -> Bool {
        if len + s.count <= Self.capacity {
            data.append(contentsOf: s)
            return true
        }
        return false
    }

    // try to resize the vector, returning if the vector was resized.
    mutating func tryResize(_ newLen: Int, _ value: UInt64) -> Bool {
        if newLen > Self.capacity {
            return false
        }
        if newLen > len {
            data.append(contentsOf: repeatElement(value, count: newLen - len))
        } else {
            data.removeLast(len - newLen)
        }
        return true
    }

    // check if any limbs are non-zero after the given index.
    // this needs to be done in reverse order, since the index
    // is relative to the most significant limbs.
    func nonzero(_ index: Int) -> Bool {
        var index = index
        while index < len {
            if rindex(index) != 0 {
                return true
            }
            index += 1
        }
        return false
    }

    // normalize the big integer, so most-significant zero limbs are removed.
    mutating func normalize() {
        while len > 0 && rindex(0) == 0 {
            data.removeLast()
        }
    }
}

private func uint64Hi64(_ r0: UInt64, _ truncated: inout Bool) -> UInt64 {
    truncated = false
    let shl = r0.leadingZeroBitCount
    return r0 << UInt64(shl)
}

private func uint64Hi64(_ r0: UInt64, _ r1: UInt64, _ truncated: inout Bool) -> UInt64 {
    let shl = r0.leadingZeroBitCount
    if shl == 0 {
        truncated = r1 != 0
        return r0
    }
    let shr = 64 - shl
    truncated = (r1 << UInt64(shl)) != 0
    return (r0 << UInt64(shl)) | (r1 >> UInt64(shr))
}

// multiply two small integers, getting both the high and low bits.
private func scalarMul(_ x: UInt64, _ y: UInt64, _ carry: inout UInt64) -> UInt64 {
    let z = x.multipliedFullWidth(by: y)
    let low = z.low.addingReportingOverflow(carry)
    // cannot overflow
    carry = z.high &+ (low.overflow ? 1 : 0)
    return low.partialValue
}

// add scalar value to bigint starting from offset.
// used in grade school multiplication
private func smallAddFrom(_ vec: inout StackVec, _ y: UInt64, _ start: Int) -> Bool {
    var index = start
    var carry = y
    while carry != 0 && index < vec.len {
        let sum = vec.data[index].addingReportingOverflow(carry)
        vec.data[index] = sum.partialValue
        carry = sum.overflow ? 1 : 0
        index += 1
    }
    if carry != 0 {
        guard vec.tryPush(carry) else {
            return false
        }
    }
    return true
}

// add scalar value to bigint.
private func smallAdd(_ vec: inout StackVec, _ y: UInt64) -> Bool {
    smallAddFrom(&vec, y, 0)
}

// multiply bigint by scalar value.
private func smallMul(_ vec: inout StackVec, _ y: UInt64) -> Bool {
    var carry: UInt64 = 0
    var index = 0
    while index < vec.len {
        vec.data[index] = scalarMul(vec.data[index], y, &carry)
        index += 1
    }
    if carry != 0 {
        guard vec.tryPush(carry) else {
            return false
        }
    }
    return true
}

// add bigint to bigint starting from index.
// used in grade school multiplication
private func largeAddFrom(_ x: inout StackVec, _ y: [UInt64], _ start: Int) -> Bool {
    // the effective x buffer is from `xstart..x.len()`, so exit early
    // if we can't get that current range.
    if x.len < start || y.count > x.len - start {
        guard x.tryResize(y.count + start, 0) else {
            return false
        }
    }

    var carry = false
    var index = 0
    while index < y.count {
        var xi = x.data[index + start]
        let yi = y[index]
        var c2 = false
        let sum = xi.addingReportingOverflow(yi)
        xi = sum.partialValue
        if carry {
            let carried = xi.addingReportingOverflow(1)
            xi = carried.partialValue
            c2 = carried.overflow
        }
        x.data[index + start] = xi
        carry = sum.overflow || c2
        index += 1
    }

    // handle overflow
    if carry {
        guard smallAddFrom(&x, 1, y.count + start) else {
            return false
        }
    }
    return true
}

// grade-school multiplication algorithm
private func longMul(_ x: inout StackVec, _ y: [UInt64]) -> Bool {
    let z = StackVec(x.data)
    let zs = z.data

    if !y.isEmpty {
        let y0 = y[0]
        guard smallMul(&x, y0) else {
            return false
        }
        var index = 1
        while index < y.count {
            let yi = y[index]
            if yi != 0 {
                // re-use the same buffer throughout
                var zi = StackVec()
                guard zi.tryExtend(zs) else {
                    return false
                }
                guard smallMul(&zi, yi) else {
                    return false
                }
                guard largeAddFrom(&x, zi.data, index) else {
                    return false
                }
            }
            index += 1
        }
    }

    x.normalize()
    return true
}

// grade-school multiplication algorithm
private func largeMul(_ x: inout StackVec, _ y: [UInt64]) -> Bool {
    if y.count == 1 {
        guard smallMul(&x, y[0]) else {
            return false
        }
    } else {
        guard longMul(&x, y) else {
            return false
        }
    }
    return true
}

// big integer type. implements a small subset of big integer
// arithmetic, using simple algorithms since asymptotically
// faster algorithms are slower for a small number of limbs.
// all operations assume the big-integer is normalized.
private struct BigInt {
    static let largeStep: UInt32 = 135
    static let smallPowerOf5: [UInt64] = [
        1,
        5,
        25,
        125,
        625,
        3125,
        15625,
        78125,
        390_625,
        1_953_125,
        9_765_625,
        48_828_125,
        244_140_625,
        1_220_703_125,
        6_103_515_625,
        30_517_578_125,
        152_587_890_625,
        762_939_453_125,
        3_814_697_265_625,
        19_073_486_328_125,
        95_367_431_640_625,
        476_837_158_203_125,
        2_384_185_791_015_625,
        11_920_928_955_078_125,
        59_604_644_775_390_625,
        298_023_223_876_953_125,
        1_490_116_119_384_765_625,
        7_450_580_596_923_828_125,
    ]
    static let largePowerOf5: [UInt64] = [
        1_414_648_277_510_068_013, 9_180_637_584_431_281_687, 4_539_964_771_860_779_200, 10_482_974_169_319_127_550,
        198_276_706_040_285_095,
    ]

    // storage of the limbs, in little-endian order.
    var vec = StackVec()

    init() {}

    init(_ value: UInt64) {
        vec.data.append(value)
        vec.normalize()
    }

    // get the high 64 bits from the vector, and if bits were truncated.
    // this is to get the significant digits for the float.
    func hi64(_ truncated: inout Bool) -> UInt64 {
        if vec.len == 0 {
            truncated = false
            return 0
        } else if vec.len == 1 {
            return uint64Hi64(vec.rindex(0), &truncated)
        } else {
            let result = uint64Hi64(vec.rindex(0), vec.rindex(1), &truncated)
            truncated = truncated || vec.nonzero(2)
            return result
        }
    }

    // compare two big integers, returning the large value.
    // assumes both are normalized. if the return value is
    // negative, other is larger, if the return value is
    // positive, this is larger, otherwise they are equal.
    // the limbs are stored in little-endian order, so we
    // must compare the limbs in ever order.
    func compare(_ other: BigInt) -> Int {
        if vec.len > other.vec.len {
            return 1
        } else if vec.len < other.vec.len {
            return -1
        } else {
            var index = vec.len
            while index > 0 {
                let xi = vec.data[index - 1]
                let yi = other.vec.data[index - 1]
                if xi > yi {
                    return 1
                } else if xi < yi {
                    return -1
                }
                index -= 1
            }
            return 0
        }
    }

    // shift left each limb n bits, carrying over to the new limb
    // returns true if we were able to shift all the digits.
    mutating func shlBits(_ n: Int) -> Bool {
        // Internally, for each item, we shift left by n, and add the previous
        // right shifted limb-bits.
        // For example, we transform (for u8) shifted left 2, to:
        //      b10100100 b01000010
        //      b10 b10010001 b00001000
        let shl = UInt64(n)
        let shr = 64 - shl
        var prev: UInt64 = 0
        var index = 0
        while index < vec.len {
            let xi = vec.data[index]
            vec.data[index] = (xi << shl) | (prev >> shr)
            prev = xi
            index += 1
        }

        let carry = prev >> shr
        if carry != 0 {
            return vec.tryPush(carry)
        }
        return true
    }

    // move the limbs left by `n` limbs.
    mutating func shlLimbs(_ n: Int) -> Bool {
        if n + vec.len > StackVec.capacity {
            return false
        } else if !vec.isEmpty {
            // move limbs and fill in empty limbs
            vec.data.insert(contentsOf: repeatElement(0, count: n), at: 0)
            return true
        } else {
            return true
        }
    }

    // move the limbs left by `n` bits.
    mutating func shl(_ n: Int) -> Bool {
        let rem = n % 64
        let div = n / 64
        if rem != 0 {
            guard shlBits(rem) else {
                return false
            }
        }
        if div != 0 {
            guard shlLimbs(div) else {
                return false
            }
        }
        return true
    }

    // get the number of leading zeros in the bigint.
    func ctlz() -> Int32 {
        if vec.isEmpty {
            return 0
        }
        return Int32(vec.rindex(0).leadingZeroBitCount)
    }

    // get the number of bits in the bigint.
    func bitLength() -> Int32 {
        let lz = ctlz()
        return Int32(64 * vec.len) - lz
    }

    mutating func mul(_ y: UInt64) -> Bool { smallMul(&vec, y) }

    mutating func add(_ y: UInt64) -> Bool { smallAdd(&vec, y) }

    // multiply as if by 2 raised to a power.
    mutating func pow2(_ exp: UInt32) -> Bool { shl(Int(exp)) }

    // multiply as if by 5 raised to a power.
    mutating func pow5(_ exp: UInt32) -> Bool {
        var exp = exp
        // multiply by a power of 5
        while exp >= Self.largeStep {
            guard largeMul(&vec, Self.largePowerOf5) else {
                return false
            }
            exp -= Self.largeStep
        }
        let smallStep: UInt32 = 27
        let maxNative: UInt64 = 7_450_580_596_923_828_125
        while exp >= smallStep {
            guard smallMul(&vec, maxNative) else {
                return false
            }
            exp -= smallStep
        }
        if exp != 0 {
            guard smallMul(&vec, Self.smallPowerOf5[Int(exp)]) else {
                return false
            }
        }
        return true
    }

    // multiply as if by 10 raised to a power.
    mutating func pow10(_ exp: UInt32) -> Bool {
        guard pow5(exp) else {
            return false
        }
        return pow2(exp)
    }
}

// MARK: - Darwin strtod, hexadecimal form (gdtoa gethex)

private enum HexFloat {
    struct Result {
        var value: Double
        // one past the last code unit strtod consumed
        var end: Int
        // strtod set errno to ERANGE
        var isOutOfRange: Bool
    }

    // binary64 as gethex sees it: a 53-bit integer significand whose least significant bit has an exponent in
    // [emin, emax].
    static let nbits = 53
    static let emin: Int64 = 1 - 1023 - 53 + 1
    static let emax: Int64 = 2046 - 1023 - 53 + 1

    static func hexDigitValue(_ character: UInt8) -> UInt64? {
        if character >= UInt8(ascii: "0") && character <= UInt8(ascii: "9") {
            return UInt64(character - UInt8(ascii: "0"))
        }
        if character >= UInt8(ascii: "a") && character <= UInt8(ascii: "f") {
            return UInt64(character - UInt8(ascii: "a") + 10)
        }
        if character >= UInt8(ascii: "A") && character <= UInt8(ascii: "F") {
            return UInt64(character - UInt8(ascii: "A") + 10)
        }
        return nil
    }

    static func isDecimalDigit(_ character: UInt8) -> Bool {
        character >= UInt8(ascii: "0") && character <= UInt8(ascii: "9")
    }

    // `strtod` on the NUL-terminated buffer `s[first..<last]`, for input starting with `0x` or `0X`.
    static func parse(_ s: ContiguousArray<UInt8>, _ first: Int, _ last: Int) -> Result {
        func at(_ index: Int) -> UInt8 {
            index < last ? s[index] : 0
        }
        guard at(first) == UInt8(ascii: "0") && (at(first + 1) == UInt8(ascii: "x") || at(first + 1) == UInt8(ascii: "X")) else {
            return Result(value: 0, end: first, isOutOfRange: false)
        }

        let decimalPoint = UInt8(ascii: ".")
        var havedig = 0
        var s0 = first + 2
        while at(s0 + havedig) == UInt8(ascii: "0") {
            havedig += 1
        }
        s0 += havedig
        var p = s0
        var decpt: Int? = nil
        var zret = false
        var e: Int64 = 0
        var scanDigits = true
        if hexDigitValue(at(p)) != nil {
            havedig += 1
        } else {
            zret = true
            if at(p) != decimalPoint {
                scanDigits = false
            } else {
                p += 1
                decpt = p
                if hexDigitValue(at(p)) == nil {
                    scanDigits = false
                } else {
                    while at(p) == UInt8(ascii: "0") {
                        p += 1
                    }
                    if hexDigitValue(at(p)) != nil {
                        zret = false
                    }
                    havedig = 1
                    s0 = p
                }
            }
        }
        if scanDigits {
            while hexDigitValue(at(p)) != nil {
                p += 1
            }
            if at(p) == decimalPoint && decpt == nil {
                p += 1
                decpt = p
                while hexDigitValue(at(p)) != nil {
                    p += 1
                }
            }
            if let decpt {
                e = -(Int64(p - decpt) << 2)
            }
        }

        // pcheck:
        let s1 = p
        var big = false
        var esign = false
        if at(p) == UInt8(ascii: "p") || at(p) == UInt8(ascii: "P") {
            p += 1
            if at(p) == UInt8(ascii: "-") {
                esign = true
                p += 1
            } else if at(p) == UInt8(ascii: "+") {
                p += 1
            }
            if !isDecimalDigit(at(p)) {
                p = s1
            } else {
                var e1 = Int64(at(p) - UInt8(ascii: "0"))
                p += 1
                while isDecimalDigit(at(p)) {
                    if e1 & 0xF800_0000 != 0 {
                        big = true
                    }
                    if !big {
                        e1 = 10 * e1 + Int64(at(p) - UInt8(ascii: "0"))
                    }
                    p += 1
                }
                if esign {
                    e1 = -e1
                }
                e += e1
            }
        }
        let end = havedig == 0 ? s0 - 1 : p
        if zret {
            return Result(value: 0, end: end, isOutOfRange: false)
        }
        if big {
            return Result(value: esign ? 0 : .infinity, end: end, isOutOfRange: true)
        }

        // The significand is the hex digits s0..<s1 without the point: keep the first 16 digits (the first is non-zero,
        // so at least 61 bits) and fold the rest into a sticky bit.
        var significand: UInt64 = 0
        var significandDigits = 0
        var sticky = false
        var index = s0
        while index < s1 {
            if let digit = hexDigitValue(at(index)) {
                if significandDigits < 16 {
                    significand = significand << 4 | digit
                    significandDigits += 1
                } else {
                    sticky = sticky || digit != 0
                    e += 4
                }
            }
            index += 1
        }
        return round(significand, e, sticky, end)
    }

    // Rounds significand * 2^e (plus a non-zero amount below its last bit when sticky) to nearest even, with
    // strtod's ERANGE: overflow, or an inexact result that is still subnormal (or zero) after rounding.
    static func round(_ significand: UInt64, _ exponent: Int64, _ sticky: Bool, _ end: Int) -> Result {
        var e = exponent
        let n = 64 - significand.leadingZeroBitCount
        var mantissa: UInt64
        // bit 1: the highest lost bit; bit 0: any lower lost bit
        var lostBits = 0
        if n > nbits {
            let shift = n - nbits
            let lost = significand & ((UInt64(1) << UInt64(shift)) - 1)
            let half = UInt64(1) << UInt64(shift - 1)
            if lost & half != 0 {
                lostBits |= 2
            }
            if lost & (half - 1) != 0 || sticky {
                lostBits |= 1
            }
            mantissa = significand >> UInt64(shift)
            e += Int64(shift)
        } else {
            mantissa = significand << UInt64(nbits - n)
            e -= Int64(nbits - n)
            if sticky {
                lostBits |= 1
            }
        }
        if e > emax {
            return Result(value: .infinity, end: end, isOutOfRange: true)
        }

        var isDenormal = false
        if e < emin {
            isDenormal = true
            let shift = emin - e
            if shift >= Int64(nbits) {
                return Result(value: 0, end: end, isOutOfRange: true)
            }
            let lost = mantissa & ((UInt64(1) << UInt64(shift)) - 1)
            let half = UInt64(1) << UInt64(shift - 1)
            if lostBits != 0 {
                lostBits = 1
            } else if lost & (half - 1) != 0 {
                lostBits = 1
            }
            if lost & half != 0 {
                lostBits |= 2
            }
            mantissa >>= UInt64(shift)
            e = emin
        }

        if lostBits & 2 != 0 && (lostBits & 1 != 0 || mantissa & 1 != 0) {
            mantissa += 1
            if isDenormal {
                if mantissa == UInt64(1) << UInt64(nbits - 1) {
                    isDenormal = false
                }
            } else if mantissa == UInt64(1) << UInt64(nbits) {
                mantissa >>= 1
                e += 1
                if e > emax {
                    return Result(value: .infinity, end: end, isOutOfRange: true)
                }
            }
        }

        if isDenormal {
            if lostBits != 0 {
                return Result(value: Double(bitPattern: mantissa), end: end, isOutOfRange: true)
            }
            return Result(value: Double(bitPattern: mantissa), end: end, isOutOfRange: false)
        }
        let biasedExponent = UInt64(e - emin + 1)
        let bits = biasedExponent << 52 | (mantissa & 0x000F_FFFF_FFFF_FFFF)
        return Result(value: Double(bitPattern: bits), end: end, isOutOfRange: false)
    }
}
