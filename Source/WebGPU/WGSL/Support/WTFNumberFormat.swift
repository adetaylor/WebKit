// Copyright 2010 the V8 project authors. All rights reserved.
// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of Google Inc. nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// License header from dragonbox
//    https://github.com/jk-jeon/dragonbox/blob/master/LICENSE-Boost
//    https://github.com/jk-jeon/dragonbox/blob/master/LICENSE-Apache2-LLVM

/// The WTF number formatters that WGSL output goes through, appending ASCII to a byte buffer.
///
/// `appendNumber` is `String::number(double/float/half)` (dragonbox, `wtf/dtoa.cpp`), `appendWithTrailingPoint` is
/// `numberToStringWithTrailingPoint(double)` (double-conversion's `EcmaScriptConverterWithTrailingPoint`) and
/// `appendPrintfF` is `PrintStream::print(double)` (`printf("%lf")`, `wtf/PrintStream.cpp`).
@_spi(Testing)
public enum WTFNumberFormat {
    /// `String::number(double)`, `makeString(double)`: the shortest digits that round-trip, in the ECMAScript layout.
    @_spi(Testing)
    public static func appendNumber(_ number: Double, to output: inout ContiguousArray<UInt8>) {
        Dragonbox.toCharsN(.binary64, number.bitPattern, to: &output)
    }

    /// `String::number(float)`, `makeString(float)`: the shortest digits that round-trip to binary32.
    @_spi(Testing)
    public static func appendNumber(_ number: Float, to output: inout ContiguousArray<UInt8>) {
        Dragonbox.toCharsN(.binary32, UInt64(number.bitPattern), to: &output)
    }

    /// `String::number(half)`: the `half` promotes to `float`.
    @_spi(Testing)
    public static func appendNumber(_ number: Half, to output: inout ContiguousArray<UInt8>) {
        appendNumber(Float(number), to: &output)
    }

    /// `numberToStringWithTrailingPoint(double)`: like `appendNumber(_: Double, to:)`, but `1.` for integral values.
    @_spi(Testing)
    public static func appendWithTrailingPoint(_ number: Double, to output: inout ContiguousArray<UInt8>) {
        DoubleConversion.toShortest(number, to: &output)
    }

    /// `printInternal(PrintStream&, double)`: `printf("%lf")`, with Darwin's `nan`, `inf` and `-inf`.
    @_spi(Testing)
    public static func appendPrintfF(_ number: Double, to output: inout ContiguousArray<UInt8>) {
        PrintfF.print(number, to: &output)
    }

    /// `String::number(double)` as a new buffer.
    @_spi(Testing)
    public static func number(_ number: Double) -> ContiguousArray<UInt8> {
        var output = ContiguousArray<UInt8>()
        appendNumber(number, to: &output)
        return output
    }

    /// `String::number(float)` as a new buffer.
    @_spi(Testing)
    public static func number(_ number: Float) -> ContiguousArray<UInt8> {
        var output = ContiguousArray<UInt8>()
        appendNumber(number, to: &output)
        return output
    }

    /// `String::number(half)` as a new buffer.
    @_spi(Testing)
    public static func number(_ number: Half) -> ContiguousArray<UInt8> {
        var output = ContiguousArray<UInt8>()
        appendNumber(number, to: &output)
        return output
    }

    /// `numberToStringWithTrailingPoint(double)` as a new buffer.
    @_spi(Testing)
    public static func withTrailingPoint(_ number: Double) -> ContiguousArray<UInt8> {
        var output = ContiguousArray<UInt8>()
        appendWithTrailingPoint(number, to: &output)
        return output
    }

    /// `printf("%lf")` as a new buffer.
    @_spi(Testing)
    public static func printfF(_ number: Double) -> ContiguousArray<UInt8> {
        var output = ContiguousArray<UInt8>()
        appendPrintfF(number, to: &output)
        return output
    }
}

// MARK: - Digits

private enum DecimalDigits {
    static let powersOfTen: [UInt64] = [
        1, 10, 100, 1000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000,
        100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000, 1_000_000_000_000_000,
        10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000, 10_000_000_000_000_000_000,
    ]

    static func count(_ value: UInt64) -> Int32 {
        var result = 1
        while result < 20 && value >= powersOfTen[result] {
            result += 1
        }
        return Int32(result)
    }

    // Appends `value` (< 10^width) as exactly `width` digits, with leading zeros.
    static func append(_ value: UInt64, width: Int32, to output: inout ContiguousArray<UInt8>) {
        assert(width >= 20 || value < powersOfTen[Int(width)])
        var value = value
        var index = output.count + Int(width)
        output.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: Int(width)))
        while value != 0 {
            index -= 1
            output[index] = UInt8(ascii: "0") &+ UInt8(truncatingIfNeeded: value % 10)
            value /= 10
        }
    }

    static func append(_ value: UInt64, to output: inout ContiguousArray<UInt8>) {
        append(value, width: count(value), to: &output)
    }

    static func appendZeros(_ count: Int32, to output: inout ContiguousArray<UInt8>) {
        if count > 0 {
            output.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: Int(count)))
        }
    }
}

// MARK: - dragonbox (wtf/dragonbox), the policies WTF uses: nearest_to_even, to_even, trailing_zero::ignore, cache::full

private enum Dragonbox {
    enum Format {
        case binary32
        case binary64
    }

    struct CacheEntry {
        var high: UInt64
        var low: UInt64
    }

    struct ComputeMulResult {
        var integerPart: UInt64
        var isInteger: Bool
    }

    struct ComputeMulParityResult {
        var parity: Bool
        var isInteger: Bool
    }

    struct DecimalFP {
        var significand: UInt64
        var exponent: Int32
    }

    // MARK: Logarithms (detail/log.h)

    static func floorLog10Pow2(_ e: Int32) -> Int32 {
        (e * 315_653) >> 20
    }

    static func floorLog2Pow10(_ e: Int32) -> Int32 {
        (e * 1_741_647) >> 19
    }

    static func floorLog10Pow2MinusLog10Of4Over3(_ e: Int32) -> Int32 {
        (e * 631_305 - 261_663) >> 21
    }

    // MARK: Division (detail/div.h)

    // divide_by_pow10_info<1> and <2>.
    static func checkDivisibilityAndDivideByPow10(_ format: Format, _ n: inout UInt32) -> Bool {
        let magicNumber = format.divideByPow10MagicNumber
        n &*= magicNumber
        let mask: UInt32 = (1 << 16) - 1
        let result = (n & mask) < magicNumber
        n >>= 16
        return result
    }

    static func smallDivisionByPow10(_ format: Format, _ n: UInt32) -> UInt32 {
        (n &* format.divideByPow10MagicNumber) >> 16
    }

    // MARK: Cache (detail/cache_holder.h)

    static func getCache(_ format: Format, _ k: Int32) -> CacheEntry {
        let index = Int(k - format.cacheMinK)
        switch format {
        case .binary32:
            return CacheEntry(high: DragonboxCache.binary32[index], low: 0)
        case .binary64:
            return CacheEntry(high: DragonboxCache.binary64[2 * index], low: DragonboxCache.binary64[2 * index + 1])
        }
    }

    // MARK: compute_mul_impl

    static func computeMul(_ format: Format, _ u: UInt64, _ cache: CacheEntry) -> ComputeMulResult {
        switch format {
        case .binary32:
            // umul96_upper64
            let r = (UInt64(UInt32(truncatingIfNeeded: u)) << 32).multipliedFullWidth(by: cache.high).high
            return ComputeMulResult(integerPart: r >> 32, isInteger: UInt32(truncatingIfNeeded: r) == 0)
        case .binary64:
            // umul192_upper128
            let product = u.multipliedFullWidth(by: cache.high)
            let low = product.low &+ u.multipliedFullWidth(by: cache.low).high
            let high = product.high &+ (low < product.low ? 1 : 0)
            return ComputeMulResult(integerPart: high, isInteger: low == 0)
        }
    }

    static func computeDelta(_ cache: CacheEntry, _ beta: Int32) -> UInt32 {
        UInt32(truncatingIfNeeded: cache.high >> (64 - 1 - beta))
    }

    static func computeMulParity(_ format: Format, _ twoF: UInt64, _ cache: CacheEntry, _ beta: Int32) -> ComputeMulParityResult {
        assert(beta >= 1)
        assert(beta < 64)
        switch format {
        case .binary32:
            // umul96_lower64
            let r = UInt64(UInt32(truncatingIfNeeded: twoF)) &* cache.high
            return ComputeMulParityResult(
                parity: (r >> (64 - beta)) & 1 != 0,
                isInteger: UInt32(truncatingIfNeeded: r >> (32 - beta)) == 0
            )
        case .binary64:
            // umul192_lower128
            let product = twoF.multipliedFullWidth(by: cache.low)
            let high = (twoF &* cache.high) &+ product.high
            let low = product.low
            return ComputeMulParityResult(
                parity: (high >> (64 - beta)) & 1 != 0,
                isInteger: ((high << beta) | (low >> (64 - beta))) == 0
            )
        }
    }

    static func computeLeftEndpointForShorterIntervalCase(_ format: Format, _ cache: CacheEntry, _ beta: Int32) -> UInt64 {
        let significandBits = format.significandBits
        return format.carrier((cache.high &- (cache.high >> (significandBits + 2))) >> (64 - significandBits - 1 - beta))
    }

    static func computeRightEndpointForShorterIntervalCase(_ format: Format, _ cache: CacheEntry, _ beta: Int32) -> UInt64 {
        let significandBits = format.significandBits
        return format.carrier((cache.high &+ (cache.high >> (significandBits + 1))) >> (64 - significandBits - 1 - beta))
    }

    static func computeRoundUpForShorterIntervalCase(_ format: Format, _ cache: CacheEntry, _ beta: Int32) -> UInt64 {
        format.carrier(format.carrier(cache.high >> (64 - format.significandBits - 2 - beta)) &+ 1) / 2
    }

    static func isLeftEndpointIntegerShorterInterval(_ format: Format, _ exponent: Int32) -> Bool {
        exponent >= format.caseShorterIntervalLeftEndpointLowerThreshold && exponent <= format.caseShorterIntervalLeftEndpointUpperThreshold
    }

    // binary_to_decimal_rounding::to_even
    static func preferRoundDown(_ significand: UInt64) -> Bool {
        significand % 2 != 0
    }

    // MARK: impl

    // The main algorithm assumes the input is a normal/subnormal finite number.
    // interval_type::symmetric_boundary: both endpoints are included when `isClosed`.
    static func computeNearestNormal(_ format: Format, _ twoFC: UInt64, _ binaryExponent: Int32, isClosed: Bool) -> DecimalFP {
        // Step 1: Schubfach multiplier calculation

        // Compute k and beta.
        let minusK = floorLog10Pow2(binaryExponent) - format.kappa
        let cache = getCache(format, -minusK)
        let beta = binaryExponent + floorLog2Pow10(-minusK)

        // Compute zi and deltai.
        // 10^kappa <= deltai < 10^(kappa + 1)
        let deltai = computeDelta(cache, beta)
        // For the case of binary32, the result of integer check is not correct for
        // 29711844 * 2^-82
        // = 6.1442653300000000008655037797566933477355632930994033813476... * 10^-18
        // and 29711844 * 2^-81
        // = 1.2288530660000000001731007559513386695471126586198806762695... * 10^-17,
        // and they are the unique counterexamples. However, since 29711844 is even,
        // this does not cause any problem for the endpoints calculations; it can only
        // cause a problem when we need to perform integer check for the center.
        // Fortunately, with these inputs, that branch is never executed, so we are
        // fine.
        let zResult = computeMul(format, format.carrier((twoFC | 1) << beta), cache)

        // Step 2: Try larger divisor; remove trailing zeros if necessary

        let bigDivisor = format.bigDivisor
        let smallDivisor = format.smallDivisor

        var decimalSignificand = zResult.integerPart / UInt64(bigDivisor)
        var r = UInt32(truncatingIfNeeded: zResult.integerPart &- UInt64(bigDivisor) &* decimalSignificand)

        smallDivisorCase: do {
            if r < deltai {
                // Exclude the right endpoint if necessary.
                if r == 0 && zResult.isInteger && !isClosed {
                    decimalSignificand &-= 1
                    r = bigDivisor
                    break smallDivisorCase
                }
            } else if r > deltai {
                break smallDivisorCase
            } else {
                // r == deltai; compare fractional parts.
                let xResult = computeMulParity(format, format.carrier(twoFC &- 1), cache, beta)
                if !(xResult.parity || (xResult.isInteger && isClosed)) {
                    break smallDivisorCase
                }
            }

            // We may need to remove trailing zeros.
            return DecimalFP(significand: decimalSignificand, exponent: minusK + format.kappa + 1)
        }

        // Step 3: Find the significand with the smaller divisor

        decimalSignificand = format.carrier(decimalSignificand &* 10)

        var dist = r &- (deltai / 2) &+ (smallDivisor / 2)
        let approxYParity = ((dist ^ (smallDivisor / 2)) & 1) != 0

        // Is dist divisible by 10^kappa?
        let divisibleBySmallDivisor = checkDivisibilityAndDivideByPow10(format, &dist)

        // Add dist / 10^kappa to the significand.
        decimalSignificand = format.carrier(decimalSignificand &+ UInt64(dist))

        if divisibleBySmallDivisor {
            // Check z^(f) >= epsilon^(f).
            // We have either yi == zi - epsiloni or yi == (zi - epsiloni) - 1,
            // where yi == zi - epsiloni if and only if z^(f) >= epsilon^(f).
            // Since there are only 2 possibilities, we only need to care about the
            // parity. Also, zi and r should have the same parity since the divisor
            // is an even number.
            let yResult = computeMulParity(format, twoFC, cache, beta)
            if yResult.parity != approxYParity {
                decimalSignificand = format.carrier(decimalSignificand &- 1)
            } else {
                // If z^(f) >= epsilon^(f), we might have a tie
                // when z^(f) == epsilon^(f), or equivalently, when y is an integer.
                if preferRoundDown(decimalSignificand) && yResult.isInteger {
                    decimalSignificand = format.carrier(decimalSignificand &- 1)
                }
            }
        }
        return DecimalFP(significand: decimalSignificand, exponent: minusK + format.kappa)
    }

    // interval_type::closed: both endpoints are included.
    static func computeNearestShorter(_ format: Format, _ binaryExponent: Int32) -> DecimalFP {
        // Compute k and beta.
        let minusK = floorLog10Pow2MinusLog10Of4Over3(binaryExponent)
        let beta = binaryExponent + floorLog2Pow10(-minusK)

        // Compute xi and zi.
        let cache = getCache(format, -minusK)

        var xi = computeLeftEndpointForShorterIntervalCase(format, cache, beta)
        let zi = computeRightEndpointForShorterIntervalCase(format, cache, beta)

        // If we don't accept the left endpoint or
        // if the left endpoint is not an integer, increase it.
        if !isLeftEndpointIntegerShorterInterval(format, binaryExponent) {
            xi = format.carrier(xi &+ 1)
        }

        // Try bigger divisor.
        var decimalSignificand = zi / 10

        // If succeed, remove trailing zeros if necessary and return.
        if format.carrier(decimalSignificand &* 10) >= xi {
            return DecimalFP(significand: decimalSignificand, exponent: minusK + 1)
        }

        // Otherwise, compute the round-up of y.
        decimalSignificand = computeRoundUpForShorterIntervalCase(format, cache, beta)

        // When tie occurs, choose one of them according to the rule.
        if preferRoundDown(decimalSignificand) && binaryExponent >= format.shorterIntervalTieLowerThreshold
            && binaryExponent <= format.shorterIntervalTieUpperThreshold
        {
            decimalSignificand = format.carrier(decimalSignificand &- 1)
        } else if decimalSignificand < xi {
            decimalSignificand = format.carrier(decimalSignificand &+ 1)
        }
        return DecimalFP(significand: decimalSignificand, exponent: minusK)
    }

    // MARK: to_decimal_impl (detail/policy_holder.h), decimal_to_binary_rounding::nearest_to_even

    // `bits` is the bit pattern of a finite non-zero value; the sign is ignored (policy::sign::ignore).
    static func toDecimal(_ format: Format, _ bits: UInt64) -> DecimalFP {
        let significandMask = (UInt64(1) << format.significandBits) - 1
        let exponentBits = (bits >> format.significandBits) & ((UInt64(1) << format.exponentBits) - 1)
        var twoFC = (bits & significandMask) << 1
        var exponent = Int32(truncatingIfNeeded: exponentBits)
        let hasEvenSignificandBits = bits % 2 == 0

        // Is the input a normal number?
        if exponent != 0 {
            exponent += format.exponentBias - format.significandBits

            // Shorter interval case; proceed like Schubfach.
            // One might think this condition is wrong, since when exponent_bits ==
            // 1 and two_fc == 0, the interval is actually regular. However, it
            // turns out that this seemingly wrong condition is actually fine,
            // because the end result is anyway the same.
            if twoFC == 0 {
                return computeNearestShorter(format, exponent)
            }

            twoFC |= UInt64(1) << (format.significandBits + 1)
        } else {
            // Is the input a subnormal number?
            exponent = format.minExponent - format.significandBits
        }

        return computeNearestNormal(format, twoFC, exponent, isClosed: hasEvenSignificandBits)
    }

    // MARK: dragonbox_to_chars

    static func countDigitsBase10WithMax17(_ v: UInt64) -> Int32 {
        v >= 10_000_000_000_000_000 ? 17 : DecimalDigits.count(v)
    }

    // double_to_chars_impl<mode, print_trailing_zero>: the significand's digits (`toExponential`: `d.ddd` and the
    // exponent). Without `printTrailingZero`, the significand's trailing zeros are not printed.
    static func doubleToCharsImpl(
        _ significand: UInt64,
        _ exponent: Int32,
        toExponential: Bool,
        printTrailingZero: Bool,
        to output: inout ContiguousArray<UInt8>
    ) {
        var significand = significand
        var exponent = exponent
        if !printTrailingZero {
            while significand != 0 && significand % 10 == 0 {
                significand /= 10
                exponent += 1
            }
        }
        let digitsCount = DecimalDigits.count(significand)
        guard toExponential else {
            DecimalDigits.append(significand, width: digitsCount, to: &output)
            return
        }

        let tail = DecimalDigits.powersOfTen[Int(digitsCount - 1)]
        DecimalDigits.append(significand / tail, width: 1, to: &output)
        if digitsCount > 1 {
            output.append(UInt8(ascii: "."))
            DecimalDigits.append(significand % tail, width: digitsCount - 1, to: &output)
        }
        exponent += digitsCount - 1

        // Print exponent and return
        if exponent < 0 {
            output.append(UInt8(ascii: "e"))
            output.append(UInt8(ascii: "-"))
            exponent = -exponent
        } else {
            output.append(UInt8(ascii: "e"))
            output.append(UInt8(ascii: "+"))
        }
        DecimalDigits.append(UInt64(exponent), to: &output)
    }

    static func validShortestRepresentation(_ decimalPoint: Int32) -> Bool {
        DoubleConversion.validShortestRepresentation(decimalPoint - 1)
    }

    static func toShortest(_ significand: UInt64, _ exponent: Int32, to output: inout ContiguousArray<UInt8>) {
        assert(significand != 0)

        // significand = 12340, exponent = -2, result = 123.4
        // significand = 12345, exponent = -2, result = 123.45
        // significand = 12345, exponent =  2, result = 1234500
        let significandDigitsCount = countDigitsBase10WithMax17(significand)
        let integralDigitsCount = significandDigitsCount + exponent
        if !validShortestRepresentation(integralDigitsCount) {
            doubleToCharsImpl(significand, exponent, toExponential: true, printTrailingZero: false, to: &output)
            return
        }

        if exponent >= 0 {
            doubleToCharsImpl(significand, exponent, toExponential: false, printTrailingZero: true, to: &output)
            DecimalDigits.appendZeros(exponent, to: &output)
            return
        }

        if integralDigitsCount > 0 {
            // significand = 12345, exponent = -2, significand_digits_count = 5, integral_digits_count = 3, fractional_digits_count = 2
            let fractionalDigitsCount = significandDigitsCount - integralDigitsCount
            assert(0 < fractionalDigitsCount && fractionalDigitsCount < 17 && fractionalDigitsCount == -exponent)
            let base = DecimalDigits.powersOfTen[Int(fractionalDigitsCount)]

            // Obtain and write the integral part.
            let integral = significand / base
            doubleToCharsImpl(integral, exponent, toExponential: false, printTrailingZero: true, to: &output)

            // Obtain and write the fractional part if needed.
            let fractional = significand % base
            if fractional != 0 {
                // Given this case:
                //     significand = 12305, exponent = -2, integral_digits_count = 3, fractional_digits_count = 2, integral = 123, fractional = 5
                // Write ".0" first and then write "5".
                let actualFractionalDigitsCount = countDigitsBase10WithMax17(fractional)
                output.append(UInt8(ascii: "."))
                DecimalDigits.appendZeros(fractionalDigitsCount - actualFractionalDigitsCount, to: &output)
                doubleToCharsImpl(fractional, exponent, toExponential: false, printTrailingZero: false, to: &output)
            }
        } else {
            // Given this case:
            //     significand = 12345, exponent = -7, integral_digits_count = -2, result = 0.0012345
            // Write "0.00" first and then write "12345".
            output.append(UInt8(ascii: "0"))
            output.append(UInt8(ascii: "."))
            DecimalDigits.appendZeros(-integralDigitsCount, to: &output)
            doubleToCharsImpl(significand, exponent, toExponential: false, printTrailingZero: false, to: &output)
        }
    }

    // to_chars_n_impl<Mode::ToShortest>
    static func toCharsN(_ format: Format, _ bits: UInt64, to output: inout ContiguousArray<UInt8>) {
        let exponentBits = (bits >> format.significandBits) & ((UInt64(1) << format.exponentBits) - 1)
        let isNegative = (bits >> (format.significandBits + format.exponentBits)) & 1 != 0
        let isNonzero = bits & ~(UInt64(1) << (format.significandBits + format.exponentBits)) != 0

        if exponentBits != (UInt64(1) << format.exponentBits) - 1 {
            if isNegative && isNonzero {
                output.append(UInt8(ascii: "-"))
            }
            if isNonzero {
                let result = toDecimal(format, bits)
                toShortest(result.significand, result.exponent, to: &output)
            } else {
                output.append(UInt8(ascii: "0"))
            }
        } else {
            if bits & ((UInt64(1) << format.significandBits) - 1) == 0 {
                if isNegative {
                    output.append(UInt8(ascii: "-"))
                }
                output.append(contentsOf: "Infinity".utf8)
                return
            }
            output.append(contentsOf: "NaN".utf8)
        }
    }
}

extension Dragonbox.Format {
    var significandBits: Int32 {
        switch self {
        case .binary32: 23
        case .binary64: 52
        }
    }

    var exponentBits: Int32 {
        switch self {
        case .binary32: 8
        case .binary64: 11
        }
    }

    var minExponent: Int32 {
        switch self {
        case .binary32: -126
        case .binary64: -1022
        }
    }

    var exponentBias: Int32 {
        switch self {
        case .binary32: -127
        case .binary64: -1023
        }
    }

    var kappa: Int32 {
        switch self {
        case .binary32: 1
        case .binary64: 2
        }
    }

    // 10^(kappa + 1) and 10^kappa.
    var bigDivisor: UInt32 {
        switch self {
        case .binary32: 100
        case .binary64: 1000
        }
    }

    var smallDivisor: UInt32 {
        switch self {
        case .binary32: 10
        case .binary64: 100
        }
    }

    // divide_by_pow10_info<kappa>::magic_number (the shift amount is 16 for both).
    var divideByPow10MagicNumber: UInt32 {
        switch self {
        case .binary32: 6554
        case .binary64: 656
        }
    }

    var cacheMinK: Int32 {
        switch self {
        case .binary32: -31
        case .binary64: -292
        }
    }

    // The values of impl's constexpr thresholds.
    var caseShorterIntervalLeftEndpointLowerThreshold: Int32 { 2 }

    var caseShorterIntervalLeftEndpointUpperThreshold: Int32 { 3 }

    var shorterIntervalTieLowerThreshold: Int32 {
        switch self {
        case .binary32: -35
        case .binary64: -77
        }
    }

    var shorterIntervalTieUpperThreshold: Int32 {
        switch self {
        case .binary32: -35
        case .binary64: -77
        }
    }

    // A value of carrier_uint: uint32_t for binary32, uint64_t for binary64.
    func carrier(_ value: UInt64) -> UInt64 {
        switch self {
        case .binary32: UInt64(UInt32(truncatingIfNeeded: value))
        case .binary64: value
        }
    }
}

// MARK: - double-conversion (wtf/dtoa/double-conversion.cc), EcmaScriptConverterWithTrailingPoint

// Flags UNIQUE_ZERO | EMIT_POSITIVE_EXPONENT_SIGN | EMIT_TRAILING_DECIMAL_POINT, "Infinity", "NaN", 'e', decimal
// range [-6, 21).
private enum DoubleConversion {
    static let decimalInShortestLow: Int32 = -6
    static let decimalInShortestHigh: Int32 = 21

    // `decimal_rep`: the `length` digits of `digits`, without trailing zeros.
    struct DecimalRep {
        var digits: UInt64
        var length: Int32

        func append(_ range: Range<Int32>, to output: inout ContiguousArray<UInt8>) {
            let tail = DecimalDigits.powersOfTen[Int(length - range.upperBound)]
            let value = (digits / tail) % DecimalDigits.powersOfTen[Int(range.count)]
            DecimalDigits.append(value, width: Int32(range.count), to: &output)
        }
    }

    static func validShortestRepresentation(_ exponent: Int32) -> Bool {
        decimalInShortestLow <= exponent && exponent < decimalInShortestHigh
    }

    static func handleSpecialValues(_ value: Double, to output: inout ContiguousArray<UInt8>) {
        if value.isInfinite {
            if value < 0 {
                output.append(UInt8(ascii: "-"))
            }
            output.append(contentsOf: "Infinity".utf8)
            return
        }
        output.append(contentsOf: "NaN".utf8)
    }

    static func createExponentialRepresentation(_ decimalDigits: DecimalRep, _ exponent: Int32, to output: inout ContiguousArray<UInt8>) {
        var exponent = exponent
        decimalDigits.append(0..<1, to: &output)
        if decimalDigits.length > 1 {
            output.append(UInt8(ascii: "."))
            decimalDigits.append(1..<decimalDigits.length, to: &output)
        }
        output.append(UInt8(ascii: "e"))
        if exponent < 0 {
            output.append(UInt8(ascii: "-"))
            exponent = -exponent
        } else {
            output.append(UInt8(ascii: "+"))
        }
        if exponent == 0 {
            output.append(UInt8(ascii: "0"))
            return
        }
        DecimalDigits.append(UInt64(exponent), to: &output)
    }

    static func createDecimalRepresentation(
        _ decimalDigits: DecimalRep,
        _ decimalPoint: Int32,
        _ digitsAfterPoint: Int32,
        to output: inout ContiguousArray<UInt8>
    ) {
        let length = decimalDigits.length
        // Create a representation that is padded with zeros if needed.
        if decimalPoint <= 0 {
            // "0.00000decimal_rep" or "0.000decimal_rep00".
            output.append(UInt8(ascii: "0"))
            if digitsAfterPoint > 0 {
                output.append(UInt8(ascii: "."))
                DecimalDigits.appendZeros(-decimalPoint, to: &output)
                decimalDigits.append(0..<length, to: &output)
                let remainingDigits = digitsAfterPoint - (-decimalPoint) - length
                DecimalDigits.appendZeros(remainingDigits, to: &output)
            }
        } else if decimalPoint >= length {
            // "decimal_rep0000.00000" or "decimal_rep.0000".
            decimalDigits.append(0..<length, to: &output)
            DecimalDigits.appendZeros(decimalPoint - length, to: &output)
            if digitsAfterPoint > 0 {
                output.append(UInt8(ascii: "."))
                DecimalDigits.appendZeros(digitsAfterPoint, to: &output)
            }
        } else {
            // "decima.l_rep000".
            assert(digitsAfterPoint > 0)
            decimalDigits.append(0..<decimalPoint, to: &output)
            output.append(UInt8(ascii: "."))
            decimalDigits.append(decimalPoint..<length, to: &output)
            let remainingDigits = digitsAfterPoint - (length - decimalPoint)
            DecimalDigits.appendZeros(remainingDigits, to: &output)
        }
        if digitsAfterPoint == 0 {
            // EMIT_TRAILING_DECIMAL_POINT
            output.append(UInt8(ascii: "."))
        }
    }

    // DoubleToAscii(SHORTEST). double-conversion's Grisu3 (with its bignum fallback) and dragonbox both produce the
    // shortest digits that round-trip and, among those, the closest (ties to even), so dragonbox's digits are used.
    static func doubleToAscii(_ value: Double) -> (decimalRep: DecimalRep, decimalPoint: Int32) {
        if value == 0 {
            return (DecimalRep(digits: 0, length: 1), 1)
        }
        let decimal = Dragonbox.toDecimal(.binary64, value.bitPattern)
        var digits = decimal.significand
        var exponent = decimal.exponent
        while digits % 10 == 0 {
            digits /= 10
            exponent += 1
        }
        let length = DecimalDigits.count(digits)
        return (DecimalRep(digits: digits, length: length), length + exponent)
    }

    // DoubleToStringConverter::ToShortest, ToShortestIeeeNumber
    static func toShortest(_ value: Double, to output: inout ContiguousArray<UInt8>) {
        if !value.isFinite {
            handleSpecialValues(value, to: &output)
            return
        }

        let (decimalRep, decimalPoint) = doubleToAscii(value)

        // UNIQUE_ZERO
        if value.sign == .minus && value != 0 {
            output.append(UInt8(ascii: "-"))
        }

        let exponent = decimalPoint - 1
        if validShortestRepresentation(exponent) {
            createDecimalRepresentation(decimalRep, decimalPoint, max(0, decimalRep.length - decimalPoint), to: &output)
        } else {
            createExponentialRepresentation(decimalRep, exponent, to: &output)
        }
    }
}

// MARK: - printf("%lf") (Darwin libc)

// The exact value, rounded half to even to 6 fractional digits, computed with a small arbitrary-precision integer.
private enum PrintfF {
    static func print(_ value: Double, to output: inout ContiguousArray<UInt8>) {
        if value.isNaN {
            output.append(contentsOf: "nan".utf8)
            return
        }
        if value.sign == .minus {
            output.append(UInt8(ascii: "-"))
        }
        if value.isInfinite {
            output.append(contentsOf: "inf".utf8)
            return
        }

        let exponentBits = Int(value.exponentBitPattern)
        var scaled = BigUInt(value.significandBitPattern | (exponentBits == 0 ? 0 : 1 << 52))
        let binaryExponent = exponentBits == 0 ? -1074 : exponentBits - 1075
        scaled.multiply(by: 1_000_000)
        if binaryExponent >= 0 {
            scaled.shiftLeft(by: binaryExponent)
        } else {
            scaled.shiftRightRoundingHalfEven(by: -binaryExponent)
        }

        var digits = scaled.decimalDigits()
        if digits.count < 7 {
            digits.insert(contentsOf: repeatElement(UInt8(ascii: "0"), count: 7 - digits.count), at: 0)
        }
        output.append(contentsOf: digits[..<(digits.count - 6)])
        output.append(UInt8(ascii: "."))
        output.append(contentsOf: digits[(digits.count - 6)...])
    }

    // Little-endian 32-bit limbs, no high zero limbs (zero has no limbs).
    struct BigUInt {
        var limbs: ContiguousArray<UInt32>

        init(_ value: UInt64) {
            limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
            normalize()
        }

        mutating func normalize() {
            while let last = limbs.last, last == 0 {
                limbs.removeLast()
            }
        }

        mutating func multiply(by multiplier: UInt32) {
            var carry: UInt64 = 0
            for i in limbs.indices {
                let product = UInt64(limbs[i]) * UInt64(multiplier) + carry
                limbs[i] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            if carry != 0 {
                limbs.append(UInt32(truncatingIfNeeded: carry))
            }
        }

        mutating func addOne() {
            for i in limbs.indices {
                limbs[i] &+= 1
                if limbs[i] != 0 {
                    return
                }
            }
            limbs.append(1)
        }

        mutating func shiftLeft(by count: Int) {
            guard !limbs.isEmpty else {
                return
            }
            let bitShift = count % 32
            var result = ContiguousArray<UInt32>(repeating: 0, count: count / 32)
            result.reserveCapacity(count / 32 + limbs.count + 1)
            var carry: UInt32 = 0
            for limb in limbs {
                result.append(bitShift == 0 ? limb : (limb << bitShift) | carry)
                carry = bitShift == 0 ? 0 : limb >> (32 - bitShift)
            }
            result.append(carry)
            limbs = result
            normalize()
        }

        func bit(_ index: Int) -> Bool {
            let word = index / 32
            return word < limbs.count && (limbs[word] >> (index % 32)) & 1 != 0
        }

        // self >>= count, rounding the discarded bits half to even.
        mutating func shiftRightRoundingHalfEven(by count: Int) {
            let half = bit(count - 1)
            var sticky = false
            let stickyWords = (count - 1) / 32
            for i in 0..<Swift.min(stickyWords, limbs.count) where limbs[i] != 0 {
                sticky = true
                break
            }
            if !sticky && stickyWords < limbs.count {
                let stickyBits = (count - 1) % 32
                sticky = stickyBits != 0 && limbs[stickyWords] & ((1 << stickyBits) - 1) != 0
            }

            let wordShift = count / 32
            let bitShift = count % 32
            var result = ContiguousArray<UInt32>()
            if wordShift < limbs.count {
                result.reserveCapacity(limbs.count - wordShift)
                for i in wordShift..<limbs.count {
                    let next = i + 1 < limbs.count ? limbs[i + 1] : 0
                    result.append(bitShift == 0 ? limbs[i] : (limbs[i] >> bitShift) | (next << (32 - bitShift)))
                }
            }
            limbs = result
            normalize()

            if half && (sticky || bit(0)) {
                addOne()
            }
        }

        // The ASCII decimal digits, most significant first ("0" for zero).
        func decimalDigits() -> ContiguousArray<UInt8> {
            var value = limbs
            var chunks = ContiguousArray<UInt32>()
            repeat {
                var remainder: UInt64 = 0
                var i = value.count - 1
                while i >= 0 {
                    let current = (remainder << 32) | UInt64(value[i])
                    value[i] = UInt32(truncatingIfNeeded: current / 1_000_000_000)
                    remainder = current % 1_000_000_000
                    i -= 1
                }
                while let last = value.last, last == 0 {
                    value.removeLast()
                }
                chunks.append(UInt32(truncatingIfNeeded: remainder))
            } while !value.isEmpty

            var digits = ContiguousArray<UInt8>()
            var i = chunks.count - 1
            DecimalDigits.append(UInt64(chunks[i]), to: &digits)
            while i > 0 {
                i -= 1
                DecimalDigits.append(UInt64(chunks[i]), width: 9, to: &digits)
            }
            return digits
        }
    }
}

// MARK: - Cache tables (dragonbox/detail/cache_holder.h)

private enum DragonboxCache {
    // swift-format-ignore
    static let binary32: [UInt64] = [
        0x81ce_b32c_4b43_fcf5, 0xa242_5ff7_5e14_fc32, 0xcad2_f7f5_359a_3b3f, 0xfd87_b5f2_8300_ca0e,
        0x9e74_d1b7_91e0_7e49, 0xc612_0625_7658_9ddb, 0xf796_87ae_d3ee_c552, 0x9abe_14cd_4475_3b53,
        0xc16d_9a00_9592_8a28, 0xf1c9_0080_baf7_2cb2, 0x971d_a050_74da_7bef, 0xbce5_0864_9211_1aeb,
        0xec1e_4a7d_b695_61a6, 0x9392_ee8e_921d_5d08, 0xb877_aa32_36a4_b44a, 0xe695_94be_c44d_e15c,
        0x901d_7cf7_3ab0_acda, 0xb424_dc35_095c_d810, 0xe12e_1342_4bb4_0e14, 0x8cbc_cc09_6f50_88cc,
        0xafeb_ff0b_cb24_aaff, 0xdbe6_fece_bded_d5bf, 0x8970_5f41_36b4_a598, 0xabcc_7711_8461_cefd,
        0xd6bf_94d5_e57a_42bd, 0x8637_bd05_af6c_69b6, 0xa7c5_ac47_1b47_8424, 0xd1b7_1758_e219_652c,
        0x8312_6e97_8d4f_df3c, 0xa3d7_0a3d_70a3_d70b, 0xcccc_cccc_cccc_cccd, 0x8000_0000_0000_0000,
        0xa000_0000_0000_0000, 0xc800_0000_0000_0000, 0xfa00_0000_0000_0000, 0x9c40_0000_0000_0000,
        0xc350_0000_0000_0000, 0xf424_0000_0000_0000, 0x9896_8000_0000_0000, 0xbebc_2000_0000_0000,
        0xee6b_2800_0000_0000, 0x9502_f900_0000_0000, 0xba43_b740_0000_0000, 0xe8d4_a510_0000_0000,
        0x9184_e72a_0000_0000, 0xb5e6_20f4_8000_0000, 0xe35f_a931_a000_0000, 0x8e1b_c9bf_0400_0000,
        0xb1a2_bc2e_c500_0000, 0xde0b_6b3a_7640_0000, 0x8ac7_2304_89e8_0000, 0xad78_ebc5_ac62_0000,
        0xd8d7_26b7_177a_8000, 0x8786_7832_6eac_9000, 0xa968_163f_0a57_b400, 0xd3c2_1bce_cced_a100,
        0x8459_5161_4014_84a0, 0xa56f_a5b9_9019_a5c8, 0xcecb_8f27_f420_0f3a, 0x813f_3978_f894_0985,
        0xa18f_07d7_36b9_0be6, 0xc9f2_c9cd_0467_4edf, 0xfc6f_7c40_4581_2297, 0x9dc5_ada8_2b70_b59e,
        0xc537_1912_364c_e306, 0xf684_df56_c3e0_1bc7, 0x9a13_0b96_3a6c_115d, 0xc097_ce7b_c907_15b4,
        0xf0bd_c21a_bb48_db21, 0x9676_9950_b50d_88f5, 0xbc14_3fa4_e250_eb32, 0xeb19_4f8e_1ae5_25fe,
        0x92ef_d1b8_d0cf_37bf, 0xb7ab_c627_0503_05ae, 0xe596_b7b0_c643_c71a, 0x8f7e_32ce_7bea_5c70,
        0xb35d_bf82_1ae4_f38c, 0xe035_2f62_a19e_306f,
    ]

    // Each entry is two words: the high 64 bits, then the low 64 bits.
    // swift-format-ignore
    static let binary64: [UInt64] = [
        0xff77_b1fc_bebc_dc4f, 0x25e8_e89c_13bb_0f7b, 0x9faa_cf3d_f736_09b1, 0x77b1_9161_8c54_e9ad,
        0xc795_830d_7503_8c1d, 0xd59d_f5b9_ef6a_2418, 0xf97a_e3d0_d244_6f25, 0x4b05_7328_6b44_ad1e,
        0x9bec_ce62_836a_c577, 0x4ee3_67f9_430a_ec33, 0xc2e8_01fb_2445_76d5, 0x229c_41f7_93cd_a740,
        0xf3a2_0279_ed56_d48a, 0x6b43_5275_78c1_1110, 0x9845_418c_3456_44d6, 0x830a_1389_6b78_aaaa,
        0xbe56_91ef_416b_d60c, 0x23cc_986b_c656_d554, 0xedec_366b_11c6_cb8f, 0x2cbf_be86_b7ec_8aa9,
        0x94b3_a202_eb1c_3f39, 0x7bf7_d714_32f3_d6aa, 0xb9e0_8a83_a5e3_4f07, 0xdaf5_ccd9_3fb0_cc54,
        0xe858_ad24_8f5c_22c9, 0xd1b3_400f_8f9c_ff69, 0x9137_6c36_d999_95be, 0x2310_0809_b9c2_1fa2,
        0xb585_4744_8fff_fb2d, 0xabd4_0a0c_2832_a78b, 0xe2e6_9915_b3ff_f9f9, 0x16c9_0c8f_323f_516d,
        0x8dd0_1fad_907f_fc3b, 0xae3d_a7d9_7f67_92e4, 0xb144_2798_f49f_fb4a, 0x99cd_11cf_df41_779d,
        0xdd95_317f_31c7_fa1d, 0x4040_5643_d711_d584, 0x8a7d_3eef_7f1c_fc52, 0x4828_35ea_666b_2573,
        0xad1c_8eab_5ee4_3b66, 0xda32_4365_0005_eed0, 0xd863_b256_369d_4a40, 0x90be_d43e_4007_6a83,
        0x873e_4f75_e222_4e68, 0x5a77_44a6_e804_a292, 0xa90d_e353_5aaa_e202, 0x7115_15d0_a205_cb37,
        0xd351_5c28_3155_9a83, 0x0d5a_5b44_ca87_3e04, 0x8412_d999_1ed5_8091, 0xe858_790a_fe94_86c3,
        0xa517_8fff_668a_e0b6, 0x626e_974d_be39_a873, 0xce5d_73ff_402d_98e3, 0xfb0a_3d21_2dc8_1290,
        0x80fa_687f_881c_7f8e, 0x7ce6_6634_bc9d_0b9a, 0xa139_029f_6a23_9f72, 0x1c1f_ffc1_ebc4_4e81,
        0xc987_4347_44ac_874e, 0xa327_ffb2_66b5_6221, 0xfbe9_1419_15d7_a922, 0x4bf1_ff9f_0062_baa9,
        0x9d71_ac8f_ada6_c9b5, 0x6f77_3fc3_603d_b4aa, 0xc4ce_17b3_9910_7c22, 0xcb55_0fb4_384d_21d4,
        0xf601_9da0_7f54_9b2b, 0x7e2a_53a1_4660_6a49, 0x99c1_0284_4f94_e0fb, 0x2eda_7444_cbfc_426e,
        0xc031_4325_637a_1939, 0xfa91_1155_fefb_5309, 0xf03d_93ee_bc58_9f88, 0x7935_55ab_7eba_27cb,
        0x9626_7c75_35b7_63b5, 0x4bc1_558b_2f34_58df, 0xbbb0_1b92_8325_3ca2, 0x9eb1_aaed_fb01_6f17,
        0xea9c_2277_23ee_8bcb, 0x465e_15a9_79c1_cadd, 0x92a1_958a_7675_175f, 0x0bfa_cd89_ec19_1eca,
        0xb749_faed_1412_5d36, 0xcef9_80ec_671f_667c, 0xe51c_79a8_5916_f484, 0x82b7_e127_80e7_401b,
        0x8f31_cc09_37ae_58d2, 0xd1b2_ecb8_b090_8811, 0xb2fe_3f0b_8599_ef07, 0x861f_a7e6_dcb4_aa16,
        0xdfbd_cece_6700_6ac9, 0x67a7_91e0_93e1_d49b, 0x8bd6_a141_0060_42bd, 0xe0c8_bb2c_5c6d_24e1,
        0xaecc_4991_4078_536d, 0x58fa_e9f7_7388_6e19, 0xda7f_5bf5_9096_6848, 0xaf39_a475_506a_899f,
        0x888f_9979_7a5e_012d, 0x6d84_06c9_5242_9604, 0xaab3_7fd7_d8f5_8178, 0xc8e5_087b_a6d3_3b84,
        0xd560_5fcd_cf32_e1d6, 0xfb1e_4a9a_9088_0a65, 0x855c_3be0_a17f_cd26, 0x5cf2_eea0_9a55_0680,
        0xa6b3_4ad8_c9df_c06f, 0xf42f_aa48_c0ea_481f, 0xd060_1d8e_fc57_b08b, 0xf13b_94da_f124_da27,
        0x823c_1279_5db6_ce57, 0x76c5_3d08_d6b7_0859, 0xa2cb_1717_b524_81ed, 0x5476_8c4b_0c64_ca6f,
        0xcb7d_dcdd_a26d_a268, 0xa994_2f5d_cf7d_fd0a, 0xfe5d_5415_0b09_0b02, 0xd3f9_3b35_435d_7c4d,
        0x9efa_548d_26e5_a6e1, 0xc47b_c501_4a1a_6db0, 0xc6b8_e9b0_709f_109a, 0x359a_b641_9ca1_091c,
        0xf867_241c_8cc6_d4c0, 0xc301_63d2_03c9_4b63, 0x9b40_7691_d7fc_44f8, 0x79e0_de63_425d_cf1e,
        0xc210_9436_4dfb_5636, 0x9859_15fc_12f5_42e5, 0xf294_b943_e17a_2bc4, 0x3e6f_5b7b_17b2_939e,
        0x979c_f3ca_6cec_5b5a, 0xa705_992c_eecf_9c43, 0xbd84_30bd_0827_7231, 0x50c6_ff78_2a83_8354,
        0xece5_3cec_4a31_4ebd, 0xa4f8_bf56_3524_6429, 0x940f_4613_ae5e_d136, 0x871b_7795_e136_be9a,
        0xb913_1798_99f6_8584, 0x28e2_557b_5984_6e40, 0xe757_dd7e_c074_26e5, 0x331a_eada_2fe5_89d0,
        0x9096_ea6f_3848_984f, 0x3ff0_d2c8_5def_7622, 0xb4bc_a50b_065a_be63, 0x0fed_077a_756b_53aa,
        0xe1eb_ce4d_c7f1_6dfb, 0xd3e8_4959_12c6_2895, 0x8d33_60f0_9cf6_e4bd, 0x6471_2dd7_abbb_d95d,
        0xb080_392c_c434_9dec, 0xbd8d_794d_96aa_cfb4, 0xdca0_4777_f541_c567, 0xecf0_d7a0_fc55_83a1,
        0x89e4_2caa_f949_1b60, 0xf416_86c4_9db5_7245, 0xac5d_37d5_b79b_6239, 0x311c_2875_c522_ced6,
        0xd774_85cb_2582_3ac7, 0x7d63_3293_366b_828c, 0x86a8_d39e_f771_64bc, 0xae5d_ff9c_0203_3198,
        0xa853_0886_b54d_bdeb, 0xd9f5_7f83_0283_fdfd, 0xd267_caa8_62a1_2d66, 0xd072_df63_c324_fd7c,
        0x8380_dea9_3da4_bc60, 0x4247_cb9e_59f7_1e6e, 0xa461_1653_8d0d_eb78, 0x52d9_be85_f074_e609,
        0xcd79_5be8_7051_6656, 0x6790_2e27_6c92_1f8c, 0x806b_d971_4632_dff6, 0x00ba_1cd8_a3db_53b7,
        0xa086_cfcd_97bf_97f3, 0x80e8_a40e_ccd2_28a5, 0xc8a8_83c0_fdaf_7df0, 0x6122_cd12_8006_b2ce,
        0xfad2_a4b1_3d1b_5d6c, 0x796b_8057_2008_5f82, 0x9cc3_a6ee_c631_1a63, 0xcbe3_3036_7405_3bb1,
        0xc3f4_90aa_77bd_60fc, 0xbedb_fc44_1106_8a9d, 0xf4f1_b4d5_15ac_b93b, 0xee92_fb55_1548_2d45,
        0x9917_1105_2d8b_f3c5, 0x751b_dd15_2d4d_1c4b, 0xbf5c_d546_78ee_f0b6, 0xd262_d45a_78a0_635e,
        0xef34_0a98_172a_ace4, 0x86fb_8971_16c8_7c35, 0x9580_869f_0e7a_ac0e, 0xd45d_35e6_ae3d_4da1,
        0xbae0_a846_d219_5712, 0x8974_8360_59cc_a10a, 0xe998_d258_869f_acd7, 0x2bd1_a438_703f_c94c,
        0x91ff_8377_5423_cc06, 0x7b63_06a3_4627_ddd0, 0xb67f_6455_292c_bf08, 0x1a3b_c84c_17b1_d543,
        0xe41f_3d6a_7377_eeca, 0x20ca_ba5f_1d9e_4a94, 0x8e93_8662_882a_f53e, 0x547e_b47b_7282_ee9d,
        0xb238_67fb_2a35_b28d, 0xe99e_619a_4f23_aa44, 0xdec6_81f9_f4c3_1f31, 0x6405_fa00_e2ec_94d5,
        0x8b3c_113c_38f9_f37e, 0xde83_bc40_8dd3_dd05, 0xae0b_158b_4738_705e, 0x9624_ab50_b148_d446,
        0xd98d_daee_1906_8c76, 0x3bad_d624_dd9b_0958, 0x87f8_a8d4_cfa4_17c9, 0xe54c_a5d7_0a80_e5d7,
        0xa9f6_d30a_038d_1dbc, 0x5e9f_cf4c_cd21_1f4d, 0xd474_87cc_8470_652b, 0x7647_c320_0069_6720,
        0x84c8_d4df_d2c6_3f3b, 0x29ec_d9f4_0041_e074, 0xa5fb_0a17_c777_cf09, 0xf468_1071_0052_5891,
        0xcf79_cc9d_b955_c2cc, 0x7182_148d_4066_eeb5, 0x81ac_1fe2_93d5_99bf, 0xc6f1_4cd8_4840_5531,
        0xa217_27db_38cb_002f, 0xb8ad_a00e_5a50_6a7d, 0xca9c_f1d2_06fd_c03b, 0xa6d9_0811_f0e4_851d,
        0xfd44_2e46_88bd_304a, 0x908f_4a16_6d1d_a664, 0x9e4a_9cec_1576_3e2e, 0x9a59_8e4e_0432_87ff,
        0xc5dd_4427_1ad3_cdba, 0x40ef_f1e1_853f_29fe, 0xf754_9530_e188_c128, 0xd12b_ee59_e68e_f47d,
        0x9a94_dd3e_8cf5_78b9, 0x82bb_74f8_3019_58cf, 0xc13a_148e_3032_d6e7, 0xe36a_5236_3c1f_af02,
        0xf188_99b1_bc3f_8ca1, 0xdc44_e6c3_cb27_9ac2, 0x96f5_600f_15a7_b7e5, 0x29ab_103a_5ef8_c0ba,
        0xbcb2_b812_db11_a5de, 0x7415_d448_f6b6_f0e8, 0xebdf_6617_91d6_0f56, 0x111b_495b_3464_ad22,
        0x936b_9fce_bb25_c995, 0xcab1_0dd9_00be_ec35, 0xb846_87c2_69ef_3bfb, 0x3d5d_514f_40ee_a743,
        0xe658_29b3_046b_0afa, 0x0cb4_a5a3_112a_5113, 0x8ff7_1a0f_e2c2_e6dc, 0x47f0_e785_eaba_72ac,
        0xb3f4_e093_db73_a093, 0x59ed_2167_6569_0f57, 0xe0f2_18b8_d250_88b8, 0x3068_69c1_3ec3_532d,
        0x8c97_4f73_8372_5573, 0x1e41_4218_c73a_13fc, 0xafbd_2350_644e_eacf, 0xe5d1_929e_f908_98fb,
        0xdbac_6c24_7d62_a583, 0xdf45_f746_b74a_bf3a, 0x894b_c396_ce5d_a772, 0x6b8b_ba8c_328e_b784,
        0xab9e_b47c_81f5_114f, 0x066e_a92f_3f32_6565, 0xd686_619b_a272_55a2, 0xc80a_537b_0efe_febe,
        0x8613_fd01_4587_7585, 0xbd06_742c_e95f_5f37, 0xa798_fc41_96e9_52e7, 0x2c48_1138_23b7_3705,
        0xd17f_3b51_fca3_a7a0, 0xf75a_1586_2ca5_04c6, 0x82ef_8513_3de6_48c4, 0x9a98_4d73_dbe7_22fc,
        0xa3ab_6658_0d5f_daf5, 0xc13e_60d0_d2e0_ebbb, 0xcc96_3fee_10b7_d1b3, 0x318d_f905_0799_26a9,
        0xffbb_cfe9_94e5_c61f, 0xfdf1_7746_497f_7053, 0x9fd5_61f1_fd0f_9bd3, 0xfeb6_ea8b_edef_a634,
        0xc7ca_ba6e_7c53_82c8, 0xfe64_a52e_e96b_8fc1, 0xf9bd_690a_1b68_637b, 0x3dfd_ce7a_a3c6_73b1,
        0x9c16_61a6_5121_3e2d, 0x06be_a10c_a65c_084f, 0xc31b_fa0f_e569_8db8, 0x486e_494f_cff3_0a63,
        0xf3e2_f893_dec3_f126, 0x5a89_dba3_c3ef_ccfb, 0x986d_db5c_6b3a_76b7, 0xf896_2946_5a75_e01d,
        0xbe89_5233_8609_1465, 0xf6bb_b397_f113_5824, 0xee2b_a6c0_678b_597f, 0x746a_a07d_ed58_2e2d,
        0x94db_4838_40b7_17ef, 0xa8c2_a44e_b457_1cdd, 0xba12_1a46_50e4_ddeb, 0x92f3_4d62_616c_e414,
        0xe896_a0d7_e51e_1566, 0x77b0_20ba_f9c8_1d18, 0x915e_2486_ef32_cd60, 0x0ace_1474_dc1d_122f,
        0xb5b5_ada8_aaff_80b8, 0x0d81_9992_1324_56bb, 0xe323_1912_d5bf_60e6, 0x10e1_fff6_97ed_6c6a,
        0x8df5_efab_c597_9c8f, 0xca8d_3ffa_1ef4_63c2, 0xb173_6b96_b6fd_83b3, 0xbd30_8ff8_a6b1_7cb3,
        0xddd0_467c_64bc_e4a0, 0xac7c_b3f6_d05d_dbdf, 0x8aa2_2c0d_bef6_0ee4, 0x6bcd_f07a_423a_a96c,
        0xad4a_b711_2eb3_929d, 0x86c1_6c98_d2c9_53c7, 0xd89d_64d5_7a60_7744, 0xe871_c7bf_077b_a8b8,
        0x8762_5f05_6c7c_4a8b, 0x1147_1cd7_64ad_4973, 0xa93a_f6c6_c79b_5d2d, 0xd598_e40d_3dd8_9bd0,
        0xd389_b478_7982_3479, 0x4aff_1d10_8d4e_c2c4, 0x8436_10cb_4bf1_60cb, 0xcedf_722a_5851_39bb,
        0xa543_94fe_1eed_b8fe, 0xc297_4eb4_ee65_8829, 0xce94_7a3d_a6a9_273e, 0x733d_2262_29fe_ea33,
        0x811c_cc66_8829_b887, 0x0806_357d_5a3f_5260, 0xa163_ff80_2a34_26a8, 0xca07_c2dc_b0cf_26f8,
        0xc9bc_ff60_34c1_3052, 0xfc89_b393_dd02_f0b6, 0xfc2c_3f38_41f1_7c67, 0xbbac_2078_d443_ace3,
        0x9d9b_a783_2936_edc0, 0xd54b_944b_84aa_4c0e, 0xc502_9163_f384_a931, 0x0a9e_795e_65d4_df12,
        0xf643_35bc_f065_d37d, 0x4d46_17b5_ff4a_16d6, 0x99ea_0196_163f_a42e, 0x504b_ced1_bf8e_4e46,
        0xc064_81fb_9bcf_8d39, 0xe45e_c286_2f71_e1d7, 0xf07d_a27a_82c3_7088, 0x5d76_7327_bb4e_5a4d,
        0x964e_858c_91ba_2655, 0x3a6a_07f8_d510_f870, 0xbbe2_26ef_b628_afea, 0x8904_89f7_0a55_368c,
        0xeada_b0ab_a3b2_dbe5, 0x2b45_ac74_ccea_842f, 0x92c8_ae6b_464f_c96f, 0x3b0b_8bc9_0012_929e,
        0xb77a_da06_17e3_bbcb, 0x09ce_6ebb_4017_3745, 0xe559_9087_9ddc_aabd, 0xcc42_0a6a_101d_0516,
        0x8f57_fa54_c2a9_eab6, 0x9fa9_4682_4a12_232e, 0xb32d_f8e9_f354_6564, 0x4793_9822_dc96_abfa,
        0xdff9_7724_7029_7ebd, 0x5978_7e2b_93bc_56f8, 0x8bfb_ea76_c619_ef36, 0x57eb_4edb_3c55_b65b,
        0xaefa_e514_77a0_6b03, 0xede6_2292_0b6b_23f2, 0xdab9_9e59_9588_85c4, 0xe95f_ab36_8e45_ecee,
        0x88b4_02f7_fd75_539b, 0x11db_cb02_18eb_b415, 0xaae1_03b5_fcd2_a881, 0xd652_bdc2_9f26_a11a,
        0xd599_44a3_7c07_52a2, 0x4be7_6d33_46f0_4960, 0x857f_cae6_2d84_93a5, 0x6f70_a440_0c56_2ddc,
        0xa6df_bd9f_b8e5_b88e, 0xcb4c_cd50_0f6b_b953, 0xd097_ad07_a71f_26b2, 0x7e20_00a4_1346_a7a8,
        0x825e_cc24_c873_782f, 0x8ed4_0066_8c0c_28c9, 0xa2f6_7f2d_fa90_563b, 0x7289_0080_2f0f_32fb,
        0xcbb4_1ef9_7934_6bca, 0x4f2b_40a0_3ad2_ffba, 0xfea1_26b7_d781_86bc, 0xe2f6_10c8_4987_bfa9,
        0x9f24_b832_e6b0_f436, 0x0dd9_ca7d_2df4_d7ca, 0xc6ed_e63f_a05d_3143, 0x9150_3d1c_7972_0dbc,
        0xf8a9_5fcf_8874_7d94, 0x75a4_4c63_97ce_912b, 0x9b69_dbe1_b548_ce7c, 0xc986_afbe_3ee1_1abb,
        0xc244_52da_229b_021b, 0xfbe8_5bad_ce99_6169, 0xf2d5_6790_ab41_c2a2, 0xfae2_7299_423f_b9c4,
        0x97c5_60ba_6b09_19a5, 0xdccd_879f_c967_d41b, 0xbdb6_b8e9_05cb_600f, 0x5400_e987_bbc1_c921,
        0xed24_6723_473e_3813, 0x2901_23e9_aab2_3b69, 0x9436_c076_0c86_e30b, 0xf9a0_b672_0aaf_6522,
        0xb944_7093_8fa8_9bce, 0xf808_e40e_8d5b_3e6a, 0xe795_8cb8_7392_c2c2, 0xb60b_1d12_30b2_0e05,
        0x90bd_77f3_483b_b9b9, 0xb1c6_f22b_5e6f_48c3, 0xb4ec_d5f0_1a4a_a828, 0x1e38_aeb6_360b_1af4,
        0xe228_0b6c_20dd_5232, 0x25c6_da63_c38d_e1b1, 0x8d59_0723_948a_535f, 0x579c_487e_5a38_ad0f,
        0xb0af_48ec_79ac_e837, 0x2d83_5a9d_f0c6_d852, 0xdcdb_1b27_9818_2244, 0xf8e4_3145_6cf8_8e66,
        0x8a08_f0f8_bf0f_156b, 0x1b8e_9ecb_641b_5900, 0xac8b_2d36_eed2_dac5, 0xe272_467e_3d22_2f40,
        0xd7ad_f884_aa87_9177, 0x5b0e_d81d_cc6a_bb10, 0x86cc_bb52_ea94_baea, 0x98e9_4712_9fc2_b4ea,
        0xa87f_ea27_a539_e9a5, 0x3f23_98d7_47b3_6225, 0xd29f_e4b1_8e88_640e, 0x8eec_7f0d_19a0_3aae,
        0x83a3_eeee_f915_3e89, 0x1953_cf68_3004_24ad, 0xa48c_eaaa_b75a_8e2b, 0x5fa8_c342_3c05_2dd8,
        0xcdb0_2555_6531_31b6, 0x3792_f412_cb06_794e, 0x808e_1755_5f3e_bf11, 0xe2bb_d88b_bee4_0bd1,
        0xa0b1_9d2a_b70e_6ed6, 0x5b6a_ceae_ae9d_0ec5, 0xc8de_0475_64d2_0a8b, 0xf245_825a_5a44_5276,
        0xfb15_8592_be06_8d2e, 0xeed6_e2f0_f0d5_6713, 0x9ced_737b_b6c4_183d, 0x5546_4dd6_9685_606c,
        0xc428_d05a_a475_1e4c, 0xaa97_e14c_3c26_b887, 0xf533_0471_4d92_65df, 0xd53d_d99f_4b30_66a9,
        0x993f_e2c6_d07b_7fab, 0xe546_a803_8efe_402a, 0xbf8f_db78_849a_5f96, 0xde98_5204_72bd_d034,
        0xef73_d256_a5c0_f77c, 0x963e_6685_8f6d_4441, 0x95a8_6376_2798_9aad, 0xdde7_0013_79a4_4aa9,
        0xbb12_7c53_b17e_c159, 0x5560_c018_580d_5d53, 0xe9d7_1b68_9dde_71af, 0xaab8_f01e_6e10_b4a7,
        0x9226_7121_62ab_070d, 0xcab3_9613_04ca_70e9, 0xb6b0_0d69_bb55_c8d1, 0x3d60_7b97_c5fd_0d23,
        0xe45c_10c4_2a2b_3b05, 0x8cb8_9a7d_b77c_506b, 0x8eb9_8a7a_9a5b_04e3, 0x77f3_608e_92ad_b243,
        0xb267_ed19_40f1_c61c, 0x55f0_38b2_3759_1ed4, 0xdf01_e85f_912e_37a3, 0x6b6c_46de_c52f_6689,
        0x8b61_313b_babc_e2c6, 0x2323_ac4b_3b3d_a016, 0xae39_7d8a_a96c_1b77, 0xabec_975e_0a0d_081b,
        0xd9c7_dced_53c7_2255, 0x96e7_bd35_8c90_4a22, 0x881c_ea14_545c_7575, 0x7e50_d641_77da_2e55,
        0xaa24_2499_6973_92d2, 0xdde5_0bd1_d5d0_b9ea, 0xd4ad_2dbf_c3d0_7787, 0x955e_4ec6_4b44_e865,
        0x84ec_3c97_da62_4ab4, 0xbd5a_f13b_ef0b_113f, 0xa627_4bbd_d0fa_dd61, 0xecb1_ad8a_eacd_d58f,
        0xcfb1_1ead_4539_94ba, 0x67de_18ed_a581_4af3, 0x81ce_b32c_4b43_fcf4, 0x80ea_cf94_8770_ced8,
        0xa242_5ff7_5e14_fc31, 0xa125_8379_a94d_028e, 0xcad2_f7f5_359a_3b3e, 0x096e_e458_13a0_4331,
        0xfd87_b5f2_8300_ca0d, 0x8bca_9d6e_1888_53fd, 0x9e74_d1b7_91e0_7e48, 0x775e_a264_cf55_347e,
        0xc612_0625_7658_9dda, 0x9536_4afe_032a_819e, 0xf796_87ae_d3ee_c551, 0x3a83_ddbd_83f5_2205,
        0x9abe_14cd_4475_3b52, 0xc492_6a96_7279_3543, 0xc16d_9a00_9592_8a27, 0x75b7_053c_0f17_8294,
        0xf1c9_0080_baf7_2cb1, 0x5324_c68b_12dd_6339, 0x971d_a050_74da_7bee, 0xd3f6_fc16_ebca_5e04,
        0xbce5_0864_9211_1aea, 0x88f4_bb1c_a6bc_f585, 0xec1e_4a7d_b695_61a5, 0x2b31_e9e3_d06c_32e6,
        0x9392_ee8e_921d_5d07, 0x3aff_322e_6243_9fd0, 0xb877_aa32_36a4_b449, 0x09be_feb9_fad4_87c3,
        0xe695_94be_c44d_e15b, 0x4c2e_be68_7989_a9b4, 0x901d_7cf7_3ab0_acd9, 0x0f9d_3701_4bf6_0a11,
        0xb424_dc35_095c_d80f, 0x5384_84c1_9ef3_8c95, 0xe12e_1342_4bb4_0e13, 0x2865_a5f2_06b0_6fba,
        0x8cbc_cc09_6f50_88cb, 0xf93f_87b7_442e_45d4, 0xafeb_ff0b_cb24_aafe, 0xf78f_69a5_1539_d749,
        0xdbe6_fece_bded_d5be, 0xb573_440e_5a88_4d1c, 0x8970_5f41_36b4_a597, 0x3168_0a88_f895_3031,
        0xabcc_7711_8461_cefc, 0xfdc2_0d2b_36ba_7c3e, 0xd6bf_94d5_e57a_42bc, 0x3d32_9076_0469_1b4d,
        0x8637_bd05_af6c_69b5, 0xa63f_9a49_c2c1_b110, 0xa7c5_ac47_1b47_8423, 0x0fcf_80dc_3372_1d54,
        0xd1b7_1758_e219_652b, 0xd3c3_6113_404e_a4a9, 0x8312_6e97_8d4f_df3b, 0x645a_1cac_0831_26ea,
        0xa3d7_0a3d_70a3_d70a, 0x3d70_a3d7_0a3d_70a4, 0xcccc_cccc_cccc_cccc, 0xcccc_cccc_cccc_cccd,
        0x8000_0000_0000_0000, 0x0000_0000_0000_0000, 0xa000_0000_0000_0000, 0x0000_0000_0000_0000,
        0xc800_0000_0000_0000, 0x0000_0000_0000_0000, 0xfa00_0000_0000_0000, 0x0000_0000_0000_0000,
        0x9c40_0000_0000_0000, 0x0000_0000_0000_0000, 0xc350_0000_0000_0000, 0x0000_0000_0000_0000,
        0xf424_0000_0000_0000, 0x0000_0000_0000_0000, 0x9896_8000_0000_0000, 0x0000_0000_0000_0000,
        0xbebc_2000_0000_0000, 0x0000_0000_0000_0000, 0xee6b_2800_0000_0000, 0x0000_0000_0000_0000,
        0x9502_f900_0000_0000, 0x0000_0000_0000_0000, 0xba43_b740_0000_0000, 0x0000_0000_0000_0000,
        0xe8d4_a510_0000_0000, 0x0000_0000_0000_0000, 0x9184_e72a_0000_0000, 0x0000_0000_0000_0000,
        0xb5e6_20f4_8000_0000, 0x0000_0000_0000_0000, 0xe35f_a931_a000_0000, 0x0000_0000_0000_0000,
        0x8e1b_c9bf_0400_0000, 0x0000_0000_0000_0000, 0xb1a2_bc2e_c500_0000, 0x0000_0000_0000_0000,
        0xde0b_6b3a_7640_0000, 0x0000_0000_0000_0000, 0x8ac7_2304_89e8_0000, 0x0000_0000_0000_0000,
        0xad78_ebc5_ac62_0000, 0x0000_0000_0000_0000, 0xd8d7_26b7_177a_8000, 0x0000_0000_0000_0000,
        0x8786_7832_6eac_9000, 0x0000_0000_0000_0000, 0xa968_163f_0a57_b400, 0x0000_0000_0000_0000,
        0xd3c2_1bce_cced_a100, 0x0000_0000_0000_0000, 0x8459_5161_4014_84a0, 0x0000_0000_0000_0000,
        0xa56f_a5b9_9019_a5c8, 0x0000_0000_0000_0000, 0xcecb_8f27_f420_0f3a, 0x0000_0000_0000_0000,
        0x813f_3978_f894_0984, 0x4000_0000_0000_0000, 0xa18f_07d7_36b9_0be5, 0x5000_0000_0000_0000,
        0xc9f2_c9cd_0467_4ede, 0xa400_0000_0000_0000, 0xfc6f_7c40_4581_2296, 0x4d00_0000_0000_0000,
        0x9dc5_ada8_2b70_b59d, 0xf020_0000_0000_0000, 0xc537_1912_364c_e305, 0x6c28_0000_0000_0000,
        0xf684_df56_c3e0_1bc6, 0xc732_0000_0000_0000, 0x9a13_0b96_3a6c_115c, 0x3c7f_4000_0000_0000,
        0xc097_ce7b_c907_15b3, 0x4b9f_1000_0000_0000, 0xf0bd_c21a_bb48_db20, 0x1e86_d400_0000_0000,
        0x9676_9950_b50d_88f4, 0x1314_4480_0000_0000, 0xbc14_3fa4_e250_eb31, 0x17d9_55a0_0000_0000,
        0xeb19_4f8e_1ae5_25fd, 0x5dcf_ab08_0000_0000, 0x92ef_d1b8_d0cf_37be, 0x5aa1_cae5_0000_0000,
        0xb7ab_c627_0503_05ad, 0xf14a_3d9e_4000_0000, 0xe596_b7b0_c643_c719, 0x6d9c_cd05_d000_0000,
        0x8f7e_32ce_7bea_5c6f, 0xe482_0023_a200_0000, 0xb35d_bf82_1ae4_f38b, 0xdda2_802c_8a80_0000,
        0xe035_2f62_a19e_306e, 0xd50b_2037_ad20_0000, 0x8c21_3d9d_a502_de45, 0x4526_f422_cc34_0000,
        0xaf29_8d05_0e43_95d6, 0x9670_b12b_7f41_0000, 0xdaf3_f046_51d4_7b4c, 0x3c0c_dd76_5f11_4000,
        0x88d8_762b_f324_cd0f, 0xa588_0a69_fb6a_c800, 0xab0e_93b6_efee_0053, 0x8eea_0d04_7a45_7a00,
        0xd5d2_38a4_abe9_8068, 0x72a4_9045_98d6_d880, 0x85a3_6366_eb71_f041, 0x47a6_da2b_7f86_4750,
        0xa70c_3c40_a64e_6c51, 0x9990_90b6_5f67_d924, 0xd0cf_4b50_cfe2_0765, 0xfff4_b4e3_f741_cf6d,
        0x8281_8f12_81ed_449f, 0xbff8_f10e_7a89_21a5, 0xa321_f2d7_2268_95c7, 0xaff7_2d52_192b_6a0e,
        0xcbea_6f8c_eb02_bb39, 0x9bf4_f8a6_9f76_4491, 0xfee5_0b70_25c3_6a08, 0x02f2_36d0_4753_d5b5,
        0x9f4f_2726_179a_2245, 0x01d7_6242_2c94_6591, 0xc722_f0ef_9d80_aad6, 0x424d_3ad2_b7b9_7ef6,
        0xf8eb_ad2b_84e0_d58b, 0xd2e0_8987_65a7_deb3, 0x9b93_4c3b_330c_8577, 0x63cc_55f4_9f88_eb30,
        0xc278_1f49_ffcf_a6d5, 0x3cbf_6b71_c76b_25fc, 0xf316_271c_7fc3_908a, 0x8bef_464e_3945_ef7b,
        0x97ed_d871_cfda_3a56, 0x9775_8bf0_e3cb_b5ad, 0xbde9_4e8e_43d0_c8ec, 0x3d52_eeed_1cbe_a318,
        0xed63_a231_d4c4_fb27, 0x4ca7_aaa8_63ee_4bde, 0x945e_455f_24fb_1cf8, 0x8fe8_caa9_3e74_ef6b,
        0xb975_d6b6_ee39_e436, 0xb3e2_fd53_8e12_2b45, 0xe7d3_4c64_a9c8_5d44, 0x60db_bca8_7196_b617,
        0x90e4_0fbe_ea1d_3a4a, 0xbc89_55e9_46fe_31ce, 0xb51d_13ae_a4a4_88dd, 0x6bab_ab63_98bd_be42,
        0xe264_589a_4dcd_ab14, 0xc696_963c_7eed_2dd2, 0x8d7e_b760_70a0_8aec, 0xfc1e_1de5_cf54_3ca3,
        0xb0de_6538_8cc8_ada8, 0x3b25_a55f_4329_4bcc, 0xdd15_fe86_affa_d912, 0x49ef_0eb7_13f3_9ebf,
        0x8a2d_bf14_2dfc_c7ab, 0x6e35_6932_6c78_4338, 0xacb9_2ed9_397b_f996, 0x49c2_c37f_0796_5405,
        0xd7e7_7a8f_87da_f7fb, 0xdc33_745e_c97b_e907, 0x86f0_ac99_b4e8_dafd, 0x69a0_28bb_3ded_71a4,
        0xa8ac_d7c0_2223_11bc, 0xc408_32ea_0d68_ce0d, 0xd2d8_0db0_2aab_d62b, 0xf50a_3fa4_90c3_0191,
        0x83c7_088e_1aab_65db, 0x7926_67c6_da79_e0fb, 0xa4b8_cab1_a156_3f52, 0x5770_01b8_9118_5939,
        0xcde6_fd5e_09ab_cf26, 0xed4c_0226_b55e_6f87, 0x80b0_5e5a_c60b_6178, 0x544f_8158_315b_05b5,
        0xa0dc_75f1_778e_39d6, 0x6963_61ae_3db1_c722, 0xc913_936d_d571_c84c, 0x03bc_3a19_cd1e_38ea,
        0xfb58_7849_4ace_3a5f, 0x04ab_48a0_4065_c724, 0x9d17_4b2d_cec0_e47b, 0x62eb_0d64_283f_9c77,
        0xc45d_1df9_4271_1d9a, 0x3ba5_d0bd_324f_8395, 0xf574_6577_930d_6500, 0xca8f_44ec_7ee3_647a,
        0x9968_bf6a_bbe8_5f20, 0x7e99_8b13_cf4e_1ecc, 0xbfc2_ef45_6ae2_76e8, 0x9e3f_edd8_c321_a67f,
        0xefb3_ab16_c59b_14a2, 0xc5cf_e94e_f3ea_101f, 0x95d0_4aee_3b80_ece5, 0xbba1_f1d1_5872_4a13,
        0xbb44_5da9_ca61_281f, 0x2a8a_6e45_ae8e_dc98, 0xea15_7514_3cf9_7226, 0xf52d_09d7_1a32_93be,
        0x924d_692c_a61b_e758, 0x593c_2626_705f_9c57, 0xb6e0_c377_cfa2_e12e, 0x6f8b_2fb0_0c77_836d,
        0xe498_f455_c38b_997a, 0x0b6d_fb9c_0f95_6448, 0x8edf_98b5_9a37_3fec, 0x4724_bd41_89bd_5ead,
        0xb297_7ee3_00c5_0fe7, 0x58ed_ec91_ec2c_b658, 0xdf3d_5e9b_c0f6_53e1, 0x2f29_67b6_6737_e3ee,
        0x8b86_5b21_5899_f46c, 0xbd79_e0d2_0082_ee75, 0xae67_f1e9_aec0_7187, 0xecd8_5906_80a3_aa12,
        0xda01_ee64_1a70_8de9, 0xe80e_6f48_20cc_9496, 0x8841_34fe_9086_58b2, 0x3109_058d_147f_dcde,
        0xaa51_823e_34a7_eede, 0xbd4b_46f0_599f_d416, 0xd4e5_e2cd_c1d1_ea96, 0x6c9e_18ac_7007_c91b,
        0x850f_adc0_9923_329e, 0x03e2_cf6b_c604_ddb1, 0xa653_9930_bf6b_ff45, 0x84db_8346_b786_151d,
        0xcfe8_7f7c_ef46_ff16, 0xe612_6418_6567_9a64, 0x81f1_4fae_158c_5f6e, 0x4fcb_7e8f_3f60_c07f,
        0xa26d_a399_9aef_7749, 0xe3be_5e33_0f38_f09e, 0xcb09_0c80_01ab_551c, 0x5cad_f5bf_d307_2cc6,
        0xfdcb_4fa0_0216_2a63, 0x73d9_732f_c7c8_f7f7, 0x9e9f_11c4_014d_da7e, 0x2867_e7fd_dcdd_9afb,
        0xc646_d635_01a1_511d, 0xb281_e1fd_5415_01b9, 0xf7d8_8bc2_4209_a565, 0x1f22_5a7c_a91a_4227,
        0x9ae7_5759_6946_075f, 0x3375_788d_e9b0_6959, 0xc1a1_2d2f_c397_8937, 0x0052_d6b1_641c_83af,
        0xf209_787b_b47d_6b84, 0xc067_8c5d_bd23_a49b, 0x9745_eb4d_50ce_6332, 0xf840_b7ba_9636_46e1,
        0xbd17_6620_a501_fbff, 0xb650_e5a9_3bc3_d899, 0xec5d_3fa8_ce42_7aff, 0xa3e5_1f13_8ab4_cebf,
        0x93ba_47c9_80e9_8cdf, 0xc66f_336c_36b1_0138, 0xb8a8_d9bb_e123_f017, 0xb80b_0047_445d_4185,
        0xe6d3_102a_d96c_ec1d, 0xa60d_c059_1574_91e6, 0x9043_ea1a_c7e4_1392, 0x87c8_9837_ad68_db30,
        0xb454_e4a1_79dd_1877, 0x29ba_be45_98c3_11fc, 0xe16a_1dc9_d854_5e94, 0xf429_6dd6_fef3_d67b,
        0x8ce2_529e_2734_bb1d, 0x1899_e4a6_5f58_660d, 0xb01a_e745_b101_e9e4, 0x5ec0_5dcf_f72e_7f90,
        0xdc21_a117_1d42_645d, 0x7670_7543_f4fa_1f74, 0x8995_04ae_7249_7eba, 0x6a06_494a_791c_53a9,
        0xabfa_45da_0edb_de69, 0x0487_db9d_1763_6893, 0xd6f8_d750_9292_d603, 0x45a9_d284_5d3c_42b7,
        0x865b_8692_5b9b_c5c2, 0x0b8a_2392_ba45_a9b3, 0xa7f2_6836_f282_b732, 0x8e6c_ac77_68d7_141f,
        0xd1ef_0244_af23_64ff, 0x3207_d795_430c_d927, 0x8335_616a_ed76_1f1f, 0x7f44_e6bd_49e8_07b9,
        0xa402_b9c5_a8d3_a6e7, 0x5f16_206c_9c62_09a7, 0xcd03_6837_1308_90a1, 0x36db_a887_c37a_8c10,
        0x8022_2122_6be5_5a64, 0xc249_4954_da2c_978a, 0xa02a_a96b_06de_b0fd, 0xf2db_9baa_10b7_bd6d,
        0xc835_53c5_c896_5d3d, 0x6f92_8294_94e5_acc8, 0xfa42_a8b7_3abb_f48c, 0xcb77_2339_ba1f_17fa,
        0x9c69_a972_84b5_78d7, 0xff2a_7604_1453_6efc, 0xc384_13cf_25e2_d70d, 0xfef5_1385_1968_4abb,
        0xf465_18c2_ef5b_8cd1, 0x7eb2_5866_5fc2_5d6a, 0x98bf_2f79_d599_3802, 0xef2f_773f_fbd9_7a62,
        0xbeee_fb58_4aff_8603, 0xaafb_550f_facf_d8fb, 0xeeaa_ba2e_5dbf_6784, 0x95ba_2a53_f983_cf39,
        0x952a_b45c_fa97_a0b2, 0xdd94_5a74_7bf2_6184, 0xba75_6174_393d_88df, 0x94f9_7111_9aee_f9e5,
        0xe912_b9d1_478c_eb17, 0x7a37_cd56_01aa_b85e, 0x91ab_b422_ccb8_12ee, 0xac62_e055_c10a_b33b,
        0xb616_a12b_7fe6_17aa, 0x577b_986b_314d_600a, 0xe39c_4976_5fdf_9d94, 0xed5a_7e85_fda0_b80c,
        0x8e41_ade9_fbeb_c27d, 0x1458_8f13_be84_7308, 0xb1d2_1964_7ae6_b31c, 0x596e_b2d8_ae25_8fc9,
        0xde46_9fbd_99a0_5fe3, 0x6fca_5f8e_d9ae_f3bc, 0x8aec_23d6_8004_3bee, 0x25de_7bb9_480d_5855,
        0xada7_2ccc_2005_4ae9, 0xaf56_1aa7_9a10_ae6b, 0xd910_f7ff_2806_9da4, 0x1b2b_a151_8094_da05,
        0x87aa_9aff_7904_2286, 0x90fb_44d2_f05d_0843, 0xa995_41bf_5745_2b28, 0x353a_1607_ac74_4a54,
        0xd3fa_922f_2d16_75f2, 0x4288_9b89_9791_5ce9, 0x847c_9b5d_7c2e_09b7, 0x6995_6135_feba_da12,
        0xa59b_c234_db39_8c25, 0x43fa_b983_7e69_9096, 0xcf02_b2c2_1207_ef2e, 0x94f9_67e4_5e03_f4bc,
        0x8161_afb9_4b44_f57d, 0x1d1b_e0ee_bac2_78f6, 0xa1ba_1ba7_9e16_32dc, 0x6462_d92a_6973_1733,
        0xca28_a291_859b_bf93, 0x7d7b_8f75_03cf_dcff, 0xfcb2_cb35_e702_af78, 0x5cda_7352_44c3_d43f,
        0x9def_bf01_b061_adab, 0x3a08_8813_6afa_64a8, 0xc56b_aec2_1c7a_1916, 0x088a_aa18_45b8_fdd1,
        0xf6c6_9a72_a398_9f5b, 0x8aad_549e_5727_3d46, 0x9a3c_2087_a63f_6399, 0x36ac_54e2_f678_864c,
        0xc0cb_28a9_8fcf_3c7f, 0x8457_6a1b_b416_a7de, 0xf0fd_f2d3_f3c3_0b9f, 0x656d_44a2_a11c_51d6,
        0x969e_b7c4_7859_e743, 0x9f64_4ae5_a4b1_b326, 0xbc46_65b5_9670_6114, 0x873d_5d9f_0dde_1fef,
        0xeb57_ff22_fc0c_7959, 0xa90c_b506_d155_a7eb, 0x9316_ff75_dd87_cbd8, 0x09a7_f124_42d5_88f3,
        0xb7dc_bf53_54e9_bece, 0x0c11_ed6d_538a_eb30, 0xe5d3_ef28_2a24_2e81, 0x8f16_68c8_a86d_a5fb,
        0x8fa4_7579_1a56_9d10, 0xf96e_017d_6944_87bd, 0xb38d_92d7_60ec_4455, 0x37c9_81dc_c395_a9ad,
        0xe070_f78d_3927_556a, 0x85bb_e253_f47b_1418, 0x8c46_9ab8_43b8_9562, 0x9395_6d74_78cc_ec8f,
        0xaf58_4166_54a6_babb, 0x387a_c8d1_9700_27b3, 0xdb2e_51bf_e9d0_696a, 0x0699_7b05_fcc0_319f,
        0x88fc_f317_f222_41e2, 0x441f_ece3_bdf8_1f04, 0xab3c_2fdd_eeaa_d25a, 0xd527_e81c_ad76_26c4,
        0xd60b_3bd5_6a55_86f1, 0x8a71_e223_d8d3_b075, 0x85c7_0565_6275_7456, 0xf687_2d56_6784_4e4a,
        0xa738_c6be_bb12_d16c, 0xb428_f8ac_0165_61dc, 0xd106_f86e_69d7_85c7, 0xe133_36d7_01be_ba53,
        0x82a4_5b45_0226_b39c, 0xecc0_0246_6117_3474, 0xa34d_7216_42b0_6084, 0x27f0_02d7_f95d_0191,
        0xcc20_ce9b_d35c_78a5, 0x31ec_038d_f7b4_41f5, 0xff29_0242_c833_96ce, 0x7e67_0471_75a1_5272,
        0x9f79_a169_bd20_3e41, 0x0f00_62c6_e984_d387, 0xc758_09c4_2c68_4dd1, 0x52c0_7b78_a3e6_0869,
        0xf92e_0c35_3782_6145, 0xa770_9a56_ccdf_8a83, 0x9bbc_c7a1_42b1_7ccb, 0x88a6_6076_400b_b692,
        0xc2ab_f989_935d_dbfe, 0x6acf_f893_d00e_a436, 0xf356_f7eb_f835_52fe, 0x0583_f6b8_c412_4d44,
        0x9816_5af3_7b21_53de, 0xc372_7a33_7a8b_704b, 0xbe1b_f1b0_59e9_a8d6, 0x744f_18c0_592e_4c5d,
        0xeda2_ee1c_7064_130c, 0x1162_def0_6f79_df74, 0x9485_d4d1_c63e_8be7, 0x8add_cb56_45ac_2ba9,
        0xb9a7_4a06_37ce_2ee1, 0x6d95_3e2b_d717_3693, 0xe811_1c87_c5c1_ba99, 0xc8fa_8db6_ccdd_0438,
        0x910a_b1d4_db99_14a0, 0x1d9c_9892_400a_22a3, 0xb54d_5e4a_127f_59c8, 0x2503_beb6_d00c_ab4c,
        0xe2a0_b5dc_971f_303a, 0x2e44_ae64_840f_d61e, 0x8da4_71a9_de73_7e24, 0x5cea_ecfe_d289_e5d3,
        0xb10d_8e14_5610_5dad, 0x7425_a83e_872c_5f48, 0xdd50_f199_6b94_7518, 0xd12f_124e_28f7_771a,
        0x8a52_96ff_e33c_c92f, 0x82bd_6b70_d99a_aa70, 0xace7_3cbf_dc0b_fb7b, 0x636c_c64d_1001_550c,
        0xd821_0bef_d30e_fa5a, 0x3c47_f7e0_5401_aa4f, 0x8714_a775_e3e9_5c78, 0x65ac_faec_3481_0a72,
        0xa8d9_d153_5ce3_b396, 0x7f18_39a7_41a1_4d0e, 0xd310_45a8_341c_a07c, 0x1ede_4811_1209_a051,
        0x83ea_2b89_2091_e44d, 0x934a_ed0a_ab46_0433, 0xa4e4_b66b_68b6_5d60, 0xf81d_a84d_5617_8540,
        0xce1d_e406_42e3_f4b9, 0x3625_1260_ab9d_668f, 0x80d2_ae83_e9ce_78f3, 0xc1d7_2b7c_6b42_601a,
        0xa107_5a24_e442_1730, 0xb24c_f65b_8612_f820, 0xc949_30ae_1d52_9cfc, 0xdee0_33f2_6797_b628,
        0xfb9b_7cd9_a4a7_443c, 0x1698_40ef_017d_a3b2, 0x9d41_2e08_06e8_8aa5, 0x8e1f_2895_60ee_864f,
        0xc491_798a_08a2_ad4e, 0xf1a6_f2ba_b92a_27e3, 0xf5b5_d7ec_8acb_58a2, 0xae10_af69_6774_b1dc,
        0x9991_a6f3_d6bf_1765, 0xacca_6da1_e0a8_ef2a, 0xbff6_10b0_cc6e_dd3f, 0x17fd_090a_58d3_2af4,
        0xeff3_94dc_ff8a_948e, 0xddfc_4b4c_ef07_f5b1, 0x95f8_3d0a_1fb6_9cd9, 0x4abd_af10_1564_f98f,
        0xbb76_4c4c_a7a4_440f, 0x9d6d_1ad4_1abe_37f2, 0xea53_df5f_d18d_5513, 0x84c8_6189_216d_c5ee,
        0x9274_6b9b_e2f8_552c, 0x32fd_3cf5_b4e4_9bb5, 0xb711_8682_dbb6_6a77, 0x3fbc_8c33_221d_c2a2,
        0xe4d5_e823_92a4_0515, 0x0fab_af3f_eaa5_334b, 0x8f05_b116_3ba6_832d, 0x29cb_4d87_f2a7_400f,
        0xb2c7_1d5b_ca90_23f8, 0x743e_20e9_ef51_1013, 0xdf78_e4b2_bd34_2cf6, 0x914d_a924_6b25_5417,
        0x8bab_8eef_b640_9c1a, 0x1ad0_89b6_c2f7_548f, 0xae96_72ab_a3d0_c320, 0xa184_ac24_73b5_29b2,
        0xda3c_0f56_8cc4_f3e8, 0xc9e5_d72d_90a2_741f, 0x8865_8996_17fb_1871, 0x7e2f_a67c_7a65_8893,
        0xaa7e_ebfb_9df9_de8d, 0xddbb_901b_98fe_eab8, 0xd51e_a6fa_8578_5631, 0x552a_7422_7f3e_a566,
        0x8533_285c_936b_35de, 0xd53a_8895_8f87_2760, 0xa67f_f273_b846_0356, 0x8a89_2aba_f368_f138,
        0xd01f_ef10_a657_842c, 0x2d2b_7569_b043_2d86, 0x8213_f56a_67f6_b29b, 0x9c3b_2962_0e29_fc74,
        0xa298_f2c5_01f4_5f42, 0x8349_f3ba_91b4_7b90, 0xcb3f_2f76_4271_7713, 0x241c_70a9_3621_9a74,
        0xfe0e_fb53_d30d_d4d7, 0xed23_8cd3_83aa_0111, 0x9ec9_5d14_63e8_a506, 0xf436_3804_324a_40ab,
        0xc67b_b459_7ce2_ce48, 0xb143_c605_3edc_d0d6, 0xf81a_a16f_dc1b_81da, 0xdd94_b786_8e94_050b,
        0x9b10_a4e5_e991_3128, 0xca7c_f2b4_191c_8327, 0xc1d4_ce1f_63f5_7d72, 0xfd1c_2f61_1f63_a3f1,
        0xf24a_01a7_3cf2_dccf, 0xbc63_3b39_673c_8ced, 0x976e_4108_8617_ca01, 0xd5be_0503_e085_d814,
        0xbd49_d14a_a79d_bc82, 0x4b2d_8644_d8a7_4e19, 0xec9c_459d_5185_2ba2, 0xddf8_e7d6_0ed1_219f,
        0x93e1_ab82_52f3_3b45, 0xcabb_90e5_c942_b504, 0xb8da_1662_e7b0_0a17, 0x3d6a_751f_3b93_6244,
        0xe710_9bfb_a19c_0c9d, 0x0cc5_1267_0a78_3ad5, 0x906a_617d_4501_87e2, 0x27fb_2b80_668b_24c6,
        0xb484_f9dc_9641_e9da, 0xb1f9_f660_802d_edf7, 0xe1a6_3853_bbd2_6451, 0x5e78_73f8_a039_6974,
        0x8d07_e334_5563_7eb2, 0xdb0b_487b_6423_e1e9, 0xb049_dc01_6abc_5e5f, 0x91ce_1a9a_3d2c_da63,
        0xdc5c_5301_c56b_75f7, 0x7641_a140_cc78_10fc, 0x89b9_b3e1_1b63_29ba, 0xa9e9_04c8_7fcb_0a9e,
        0xac28_20d9_623b_f429, 0x5463_45fa_9fbd_cd45, 0xd732_290f_baca_f133, 0xa97c_1779_47ad_4096,
        0x867f_59a9_d4be_d6c0, 0x49ed_8eab_cccc_485e, 0xa81f_3014_49ee_8c70, 0x5c68_f256_bfff_5a75,
        0xd226_fc19_5c6a_2f8c, 0x7383_2eec_6fff_3112, 0x8358_5d8f_d9c2_5db7, 0xc831_fd53_c5ff_7eac,
        0xa42e_74f3_d032_f525, 0xba3e_7ca8_b77f_5e56, 0xcd3a_1230_c43f_b26f, 0x28ce_1bd2_e55f_35ec,
        0x8044_4b5e_7aa7_cf85, 0x7980_d163_cf5b_81b4, 0xa055_5e36_1951_c366, 0xd7e1_05bc_c332_6220,
        0xc86a_b5c3_9fa6_3440, 0x8dd9_472b_f3fe_faa8, 0xfa85_6334_878f_c150, 0xb14f_98f6_f0fe_b952,
        0x9c93_5e00_d4b9_d8d2, 0x6ed1_bf9a_569f_33d4, 0xc3b8_3581_09e8_4f07, 0x0a86_2f80_ec47_00c9,
        0xf4a6_42e1_4c62_62c8, 0xcd27_bb61_2758_c0fb, 0x98e7_e9cc_cfbd_7dbd, 0x8038_d51c_b897_789d,
        0xbf21_e440_03ac_dd2c, 0xe047_0a63_e6bd_56c4, 0xeeea_5d50_0498_1478, 0x1858_ccfc_e06c_ac75,
        0x9552_7a52_02df_0ccb, 0x0f37_801e_0c43_ebc9, 0xbaa7_18e6_8396_cffd, 0xd305_6025_8f54_e6bb,
        0xe950_df20_247c_83fd, 0x47c6_b82e_f32a_206a, 0x91d2_8b74_16cd_d27e, 0x4cdc_331d_57fa_5442,
        0xb647_2e51_1c81_471d, 0xe013_3fe4_adf8_e953, 0xe3d8_f9e5_63a1_98e5, 0x5818_0fdd_d977_23a7,
        0x8e67_9c2f_5e44_ff8f, 0x570f_09ea_a7ea_7649, 0xb201_833b_35d6_3f73, 0x2cd2_cc65_51e5_13db,
        0xde81_e40a_034b_cf4f, 0xf807_7f7e_a65e_58d2, 0x8b11_2e86_420f_6191, 0xfb04_afaf_27fa_f783,
        0xadd5_7a27_d293_39f6, 0x79c5_db9a_f1f9_b564, 0xd94a_d8b1_c738_0874, 0x1837_5281_ae78_22bd,
        0x87ce_c76f_1c83_0548, 0x8f22_9391_0d0b_15b6, 0xa9c2_794a_e3a3_c69a, 0xb2eb_3875_504d_db23,
        0xd433_179d_9c8c_b841, 0x5fa6_0692_a461_51ec, 0x849f_eec2_81d7_f328, 0xdbc7_c41b_a6bc_d334,
        0xa5c7_ea73_224d_eff3, 0x12b9_b522_906c_0801, 0xcf39_e50f_eae1_6bef, 0xd768_226b_3487_0a01,
        0x8184_2f29_f2cc_e375, 0xe6a1_1583_00d4_6641, 0xa1e5_3af4_6f80_1c53, 0x6049_5ae3_c109_7fd1,
        0xca5e_89b1_8b60_2368, 0x385b_b19c_b14b_dfc5, 0xfcf6_2c1d_ee38_2c42, 0x4672_9e03_dd9e_d7b6,
        0x9e19_db92_b4e3_1ba9, 0x6c07_a2c2_6a83_46d2, 0xc5a0_5277_621b_e293, 0xc709_8b73_0524_1886,
        0xf708_6715_3aa2_db38, 0xb8cb_ee4f_c66d_1ea8,
    ]
}
