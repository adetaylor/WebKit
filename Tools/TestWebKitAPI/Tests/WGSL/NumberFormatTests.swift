// swift-format-ignore-file: AlwaysUseLowerCamelCase
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

import Testing
@_spi(Testing) import WGSL

// The expected strings are WTF's output (String::number, numberToStringWithTrailingPoint, PrintStream::print).
@Suite
struct WGSLNumberFormatTests {
    private static func text(_ bytes: ContiguousArray<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // (bit pattern, String::number, numberToStringWithTrailingPoint, printf("%lf"))
    private static let doubles: [(UInt64, String, String, String)] = [
        (0x3eb0_c6f7_a0b5_ed8d, "0.000001", "0.000001", "0.000001"),
        (0x3e7a_d7f2_9abc_af48, "1e-7", "1e-7", "0.000000"),
        (0x3e84_21f5_f40d_8376, "1.5e-7", "1.5e-7", "0.000000"),
        (0x4415_af1d_78b5_8c40, "100000000000000000000", "100000000000000000000.", "100000000000000000000.000000"),
        (0x444b_1ae4_d6e2_ef50, "1e+21", "1e+21", "1000000000000000000000.000000"),
        (0x444b_1ae4_d6e2_ef4e, "999999999999999700000", "999999999999999700000.", "999999999999999737856.000000"),
        (0x0000_0000_0000_0001, "5e-324", "5e-324", "0.000000"),
        (0x0010_0000_0000_0000, "2.2250738585072014e-308", "2.2250738585072014e-308", "0.000000"),
        (0x437b_69b4_ba63_0f35, "123456789012345680", "123456789012345680.", "123456789012345680.000000"),
        (0x3fb9_9999_9999_999a, "0.1", "0.1", "0.100000"),
        (0xbff8_0000_0000_0000, "-1.5", "-1.5", "-1.500000"),
        (0x404c_a5dc_1a63_c1f8, "57.29577951308232", "57.29577951308232", "57.295780"),
        (0x3f91_df46_a252_9d39, "0.017453292519943295", "0.017453292519943295", "0.017453"),
        (0x3ff0_0000_0000_0000, "1", "1.", "1.000000"),
        (0xc000_0000_0000_0000, "-2", "-2.", "-2.000000"),
        (0x405e_dd2f_1a9f_be77, "123.456", "123.456", "123.456000"),
        (0x3f80_0000_0000_0000, "0.0078125", "0.0078125", "0.007812"),
        (0x3eb0_c6f7_a0b5_ed8c, "9.999999999999997e-7", "9.999999999999997e-7", "0.000001"),
        (0x432f_ffff_ffff_ffff, "4503599627370495.5", "4503599627370495.5", "4503599627370495.500000"),
        (0x412e_847f_ffff_ef39, "999999.9999995", "999999.9999995", "999999.999999"),
        (0x4340_0000_0000_0001, "9007199254740994", "9007199254740994.", "9007199254740994.000000"),
        (0x3fd5_5555_5555_5555, "0.3333333333333333", "0.3333333333333333", "0.333333"),
        (0x3c5c_55de_4000_0000, "6.14426533e-18", "6.14426533e-18", "0.000000"),
        (0x01a5_6e1f_c2f8_f359, "1e-300", "1e-300", "0.000000"),
        (0x0000_0000_0000_0000, "0", "0.", "0.000000"),
        (0x8000_0000_0000_0000, "0", "0.", "-0.000000"),
        (0x7ff0_0000_0000_0000, "Infinity", "Infinity", "inf"),
        (0xfff0_0000_0000_0000, "-Infinity", "-Infinity", "-inf"),
        (0x7ff8_0000_0000_0000, "NaN", "NaN", "nan"),
        (0xfff8_0000_0000_0001, "NaN", "NaN", "nan"),
    ]

    // (bit pattern, String::number(float), numberToStringWithTrailingPoint(double(f)), printf("%lf", double(f)))
    private static let floats: [(UInt32, String, String, String)] = [
        (0x3dcc_cccd, "0.1", "0.10000000149011612", "0.100000"),
        (0x7f7f_ffff, "3.4028235e+38", "3.4028234663852886e+38", "340282346638528859811704183484516925440.000000"),
        (0x0000_0001, "1e-45", "1.401298464324817e-45", "0.000000"),
        (0x0080_0000, "1.1754944e-38", "1.1754943508222875e-38", "0.000000"),
        (0x3eaa_aaab, "0.33333334", "0.3333333432674408", "0.333333"),
        (0x3fc0_0000, "1.5", "1.5", "1.500000"),
        (0x4046_6666, "3.1", "3.0999999046325684", "3.100000"),
        (0x6258_d727, "1e+21", "1.0000000200408773e+21", "1000000020040877342720.000000"),
        (0x5015_02f9, "10000000000", "10000000000.", "10000000000.000000"),
        (0x4b80_0000, "16777216", "16777216.", "16777216.000000"),
        (0x3727_c5ac, "0.00001", "0.000009999999747378752", "0.000010"),
        (0x8000_0000, "0", "0.", "-0.000000"),
        (0xff80_0000, "-Infinity", "-Infinity", "-inf"),
        (0x7fc0_0001, "NaN", "NaN", "nan"),
    ]

    // String::number(half) is String::number(float(h)) (h, float(h) bits, String::number,
    // numberToStringWithTrailingPoint(double(h))).
    private static let halves: [(UInt16, UInt32, String, String)] = [
        (0x2e66, 0x3dcc_c000, "0.099975586", "0.0999755859375"),
        (0x0001, 0x3380_0000, "5.9604645e-8", "5.960464477539063e-8"),
        (0x7bff, 0x477f_e000, "65504", "65504."),
        (0x3c00, 0x3f80_0000, "1", "1."),
        (0x3555, 0x3eaa_a000, "0.33325195", "0.333251953125"),
    ]

    @Test
    func numberDouble() {
        for (bits, expected, _, _) in Self.doubles {
            #expect(Self.text(WTFNumberFormat.number(Double(bitPattern: bits))) == expected, "bits \(bits)")
        }
    }

    @Test
    func numberFloat() {
        for (bits, expected, _, _) in Self.floats {
            #expect(Self.text(WTFNumberFormat.number(Float(bitPattern: bits))) == expected, "bits \(bits)")
        }
    }

    @Test
    func numberHalf() {
        for (bits, floatBits, expected, expectedWithTrailingPoint) in Self.halves {
            let value = Half(bitPattern: bits)
            #expect(Float(value).bitPattern == floatBits)
            #expect(Self.text(WTFNumberFormat.number(value)) == expected)
            #expect(Self.text(WTFNumberFormat.number(Float(value))) == expected)
            #expect(Self.text(WTFNumberFormat.withTrailingPoint(Double(value))) == expectedWithTrailingPoint)
        }
    }

    @Test
    func withTrailingPoint() {
        for (bits, _, expected, _) in Self.doubles {
            #expect(Self.text(WTFNumberFormat.withTrailingPoint(Double(bitPattern: bits))) == expected, "bits \(bits)")
        }
        for (bits, _, expected, _) in Self.floats {
            #expect(Self.text(WTFNumberFormat.withTrailingPoint(Double(Float(bitPattern: bits)))) == expected, "bits \(bits)")
        }
    }

    @Test
    func printfF() {
        for (bits, _, _, expected) in Self.doubles {
            #expect(Self.text(WTFNumberFormat.printfF(Double(bitPattern: bits))) == expected, "bits \(bits)")
        }
        for (bits, _, _, expected) in Self.floats {
            #expect(Self.text(WTFNumberFormat.printfF(Double(Float(bitPattern: bits)))) == expected, "bits \(bits)")
        }
        #expect(
            Self.text(WTFNumberFormat.printfF(0x1.fffffffffffffp1023))
                == "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.000000"
        )
    }

    @Test
    func appendsToExistingBytes() {
        var output = ContiguousArray("x=".utf8)
        WTFNumberFormat.appendNumber(1.5, to: &output)
        output.append(UInt8(ascii: ","))
        WTFNumberFormat.appendNumber(Float(0.1), to: &output)
        output.append(UInt8(ascii: ","))
        WTFNumberFormat.appendWithTrailingPoint(2, to: &output)
        output.append(UInt8(ascii: ","))
        WTFNumberFormat.appendPrintfF(0.0078125, to: &output)
        output.append(UInt8(ascii: ","))
        WTFNumberFormat.appendNumber(Half(bitPattern: 0x3555), to: &output)
        #expect(Self.text(output) == "x=1.5,0.1,2.,0.007812,0.33325195")
    }

    // An independent check of the shortest digits: Swift's own `description` (SwiftDtoa) also prints the shortest
    // digits that round-trip, closest to the value, so both must agree on the digits and the decimal point.
    private static func digitsAndPoint(_ text: String) -> (digits: [UInt8], point: Int) {
        var digits: [UInt8] = []
        var point: Int?
        var exponent = 0
        var bytes = Array(text.utf8)
        if bytes.first == UInt8(ascii: "-") {
            bytes.removeFirst()
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: ".") {
                point = digits.count
            } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                exponent = Int(String(decoding: bytes[(index + 1)...], as: UTF8.self)) ?? Int.min
                break
            } else {
                digits.append(byte)
            }
            index += 1
        }
        var decimalPoint = (point ?? digits.count) + exponent
        while digits.first == UInt8(ascii: "0") {
            digits.removeFirst()
            decimalPoint -= 1
        }
        while digits.last == UInt8(ascii: "0") {
            digits.removeLast()
        }
        return (digits, digits.isEmpty ? 0 : decimalPoint)
    }

    @Test
    func shortestDigitsAgreeWithSwiftDescription() {
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
        var mismatches = 0
        for _ in 0..<20_000 {
            let d = Double(bitPattern: next())
            let f = Float(bitPattern: UInt32(truncatingIfNeeded: next()))
            if d.isFinite && d != 0 {
                let expected = Self.digitsAndPoint(d.description)
                if Self.digitsAndPoint(Self.text(WTFNumberFormat.number(d))) != expected
                    || Self.digitsAndPoint(Self.text(WTFNumberFormat.withTrailingPoint(d))) != expected
                {
                    mismatches += 1
                }
            }
            if f.isFinite && f != 0 && Self.digitsAndPoint(Self.text(WTFNumberFormat.number(f))) != Self.digitsAndPoint(f.description) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }
}
