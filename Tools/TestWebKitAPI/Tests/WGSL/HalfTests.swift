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

private struct HalfTestGenerator {
    var state: UInt64

    // SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }

    // Every other sample gets an exponent from below half the smallest half subnormal to above the largest half.
    mutating func nextDouble() -> Double {
        var bits = next()
        if next() & 1 == 0 {
            bits = (bits & 0x800F_FFFF_FFFF_FFFF) | ((990 + next() % 71) &<< 52)
        }
        return Double(bitPattern: bits)
    }
}

private func hex(_ value: some BinaryInteger) -> String {
    "0x" + String(value, radix: 16)
}

private struct MismatchLog {
    private(set) var count = 0
    private(set) var first: [String] = []

    mutating func record(_ text: String) {
        count += 1
        if first.count < 10 {
            first.append(text)
        }
    }

    var summary: Comment {
        Comment(rawValue: String(count) + " mismatches, first: " + first.joined(separator: ", "))
    }
}

// x86_64 C++ widens `half` to float with compiler-rt __extendhfsf2, which keeps a signaling NaN (DEV-11).
#if arch(x86_64)
private let floatWideningQuietsNaN = false
#else
private let floatWideningQuietsNaN = true
#endif

private func isNaN(_ pattern: UInt16) -> Bool {
    pattern & 0x7C00 == 0x7C00 && pattern & 0x3FF != 0
}

// The C++ widening: exact, and a NaN keeps its payload.
private func expectedFloat(_ pattern: UInt16, quietingNaN: Bool) -> Float {
    let sign: FloatingPointSign = pattern & 0x8000 == 0 ? .plus : .minus
    let exponent = Int((pattern &>> 10) & 0x1F)
    let fraction = pattern & 0x3FF
    if exponent == 0 {
        return Float(sign: sign, exponent: -24, significand: Float(fraction))
    }
    if exponent < 31 {
        return Float(sign: sign, exponent: exponent - 15, significand: 1 + Float(fraction) / 1024)
    }
    if fraction == 0 {
        return sign == .minus ? -Float.infinity : Float.infinity
    }
    let quiet: UInt32 = quietingNaN ? 0x0040_0000 : 0
    return Float(bitPattern: UInt32(pattern & 0x8000) &<< 16 | 0x7F80_0000 | quiet | UInt32(fraction) &<< 13)
}

// Double(half) quiets a NaN on every architecture.
private func expectedDouble(_ pattern: UInt16) -> Double {
    guard isNaN(pattern) else {
        return Double(expectedFloat(pattern, quietingNaN: true))
    }
    return Double(bitPattern: UInt64(pattern & 0x8000) &<< 48 | 0x7FF8_0000_0000_0000 | UInt64(pattern & 0x3FF) &<< 42)
}

@Suite
struct WGSLHalfTests {
    #if arch(arm64)
    @Test
    func floatConversionMatchesFloat16() {
        var log = MismatchLog()
        func check(_ bits: UInt32) {
            let value = Float(bitPattern: bits)
            if Half(value).bitPattern != Float16(value).bitPattern {
                log.record(hex(bits))
            }
        }
        var bits: UInt32 = 0
        repeat {
            check(bits)
            bits &+= 1 &<< 20
        } while bits != 0
        // A prime stride also varies the low bits: about 2^20 floats.
        repeat {
            check(bits)
            bits &+= 4093
        } while bits >= 4093
        #expect(log.count == 0, log.summary)
    }

    @Test
    func doubleConversionMatchesFloat16() {
        var log = MismatchLog()
        var generator = HalfTestGenerator(state: 0x5EED_0F16)
        for _ in 0..<1_000_000 {
            let value = generator.nextDouble()
            if Half(value).bitPattern != Float16(value).bitPattern {
                log.record(hex(value.bitPattern))
            }
        }
        #expect(log.count == 0, log.summary)
    }

    @Test
    func widenedValuesMatchFloat16() {
        var log = MismatchLog()
        for pattern in UInt16.min...UInt16.max {
            let half = Half(bitPattern: pattern)
            let reference = Float16(bitPattern: pattern)
            if Float(half).bitPattern != Float(reference).bitPattern || Double(half).bitPattern != Double(reference).bitPattern {
                log.record(hex(pattern))
            }
        }
        #expect(log.count == 0, log.summary)
    }
    #endif

    @Test
    func widenedValuesAreExact() {
        var log = MismatchLog()
        for pattern in UInt16.min...UInt16.max {
            let half = Half(bitPattern: pattern)
            let expected = expectedFloat(pattern, quietingNaN: floatWideningQuietsNaN)
            let roundTrip = isNaN(pattern) ? pattern | 0x0200 : pattern
            if Float(half).bitPattern != expected.bitPattern || Double(half).bitPattern != expectedDouble(pattern).bitPattern
                || Half(Float(half)).bitPattern != roundTrip || Half(Double(half)).bitPattern != roundTrip
            {
                log.record(hex(pattern))
            }
        }
        #expect(log.count == 0, log.summary)
    }

    @Test
    func conversionsRoundToNearestEven() {
        let cases: [(Double, UInt16)] = [
            (0, 0x0000),
            (-0.0, 0x8000),
            (1, 0x3C00),
            (0.1, 0x2E66),
            (-2, 0xC000),
            (65_504, 0x7BFF),
            (65_519.99, 0x7BFF),
            (65_520, 0x7C00),
            (-65_520, 0xFC00),
            (65_536, 0x7C00),
            (1e300, 0x7C00),
            (.infinity, 0x7C00),
            (-.infinity, 0xFC00),
            (0x1p-14, 0x0400),
            (0x1p-14 - 0x1p-25, 0x0400),
            (0x1p-24, 0x0001),
            (0x1p-25, 0x0000),
            (-0x1p-25, 0x8000),
            (0x3p-25, 0x0002),
            (1e-300, 0x0000),
            (Double.leastNonzeroMagnitude, 0x0000),
            (1 + 0x1p-11, 0x3C00),
            (1 + 0x3p-11, 0x3C02),
        ]
        for (value, expected) in cases {
            #expect(Half(value).bitPattern == expected, Comment(rawValue: hex(value.bitPattern)))
            #expect(Half(Float(value)).bitPattern == expected, Comment(rawValue: hex(value.bitPattern)))
        }
        #expect(Half(Float.leastNonzeroMagnitude).bitPattern == 0x0000)
        #expect(Half(-Float.leastNonzeroMagnitude).bitPattern == 0x8000)
        #expect(Half(Float.greatestFiniteMagnitude).bitPattern == 0x7C00)
    }

    @Test
    func midpointsRoundToNearestEven() {
        var log = MismatchLog()
        for pattern in UInt16(0)..<0x7C00 {
            let low = Float(Half(bitPattern: pattern))
            let high = pattern == 0x7BFF ? 65_536 : Float(Half(bitPattern: pattern + 1))
            let midpoint = low + (high - low) / 2
            let even = pattern & 1 == 0 ? pattern : pattern + 1
            for sign: UInt16 in [0, 0x8000] {
                let factor: Float = sign == 0 ? 1 : -1
                let cases: [(Float, UInt16)] = [
                    (midpoint, even),
                    (midpoint.nextDown, pattern),
                    (midpoint.nextUp, pattern + 1),
                ]
                for (magnitude, expected) in cases {
                    let value = factor * magnitude
                    if Half(value).bitPattern != sign | expected {
                        log.record(hex(value.bitPattern))
                    }
                }
                let doubleMidpoint = Double(midpoint)
                let doubleCases: [(Double, UInt16)] = [
                    (doubleMidpoint, even),
                    (doubleMidpoint.nextDown, pattern),
                    (doubleMidpoint.nextUp, pattern + 1),
                ]
                for (magnitude, expected) in doubleCases {
                    let value = Double(factor) * magnitude
                    if Half(value).bitPattern != sign | expected {
                        log.record(hex(value.bitPattern))
                    }
                }
            }
        }
        #expect(log.count == 0, log.summary)
    }

    @Test
    func doubleConversionRoundsOnce() {
        // static_cast<half>(double) rounds once; going through float first would round twice.
        #expect(Half(1 + 0x1p-11 + 0x1p-40).bitPattern == 0x3C01)
        #expect(Half(Float(1 + 0x1p-11 + 0x1p-40)).bitPattern == 0x3C00)
        #expect(Half(0x1.0000000000001p-25).bitPattern == 0x0001)
        #expect(Half(Float(0x1.0000000000001p-25)).bitPattern == 0x0000)
    }

    @Test
    func nanConversionsMatchCxx() {
        // To half, AArch64 FCVT and x86_64 compiler-rt (__truncsfhf2, __truncdfhf2) agree.
        let floats: [(UInt32, UInt16)] = [
            (0x7F80_0001, 0x7E00),
            (0x7FC0_0000, 0x7E00),
            (0xFFC0_0000, 0xFE00),
            (0x7FBF_FFFF, 0x7FFF),
            (0x7F80_2000, 0x7E01),
            (0x7FFF_E000, 0x7FFF),
            (0xFF80_1FFF, 0xFE00),
        ]
        for (bits, expected) in floats {
            #expect(Half(Float(bitPattern: bits)).bitPattern == expected, Comment(rawValue: hex(bits)))
        }
        let doubles: [(UInt64, UInt16)] = [
            (0x7FF0_0000_0000_0001, 0x7E00),
            (0x7FF8_0000_0000_0000, 0x7E00),
            (0xFFF4_0000_0000_0000, 0xFF00),
            (0x7FF0_0400_0000_0000, 0x7E01),
            (0x7FF7_FFFF_FFFF_FFFF, 0x7FFF),
        ]
        for (bits, expected) in doubles {
            #expect(Half(Double(bitPattern: bits)).bitPattern == expected, Comment(rawValue: hex(bits)))
        }
        // From half to float, AArch64 FCVT quiets and x86_64 __extendhfsf2 does not; to double both quiet.
        let halves: [(half: UInt16, arm64Float: UInt32, x86_64Float: UInt32, double: UInt64)] = [
            (0x7C01, 0x7FC0_2000, 0x7F80_2000, 0x7FF8_0400_0000_0000),
            (0x7E00, 0x7FC0_0000, 0x7FC0_0000, 0x7FF8_0000_0000_0000),
            (0xFDFF, 0xFFFF_E000, 0xFFBF_E000, 0xFFFF_FC00_0000_0000),
            (0x7FFF, 0x7FFF_E000, 0x7FFF_E000, 0x7FFF_FC00_0000_0000),
            (0xFC01, 0xFFC0_2000, 0xFF80_2000, 0xFFF8_0400_0000_0000),
        ]
        for vector in halves {
            let half = Half(bitPattern: vector.half)
            let expectedFloat = floatWideningQuietsNaN ? vector.arm64Float : vector.x86_64Float
            #expect(Float(half).bitPattern == expectedFloat, Comment(rawValue: hex(vector.half)))
            #expect(Double(half).bitPattern == vector.double, Comment(rawValue: hex(vector.half)))
        }
    }

    #if arch(x86_64)
    @Test
    func DEV_11_floatWideningKeepsSignalingNaN() {
        var log = MismatchLog()
        for sign: UInt16 in [0, 0x8000] {
            for payload in UInt16(1)...0x1FF {
                let half = Half(bitPattern: sign | 0x7C00 | payload)
                let float = Float(half)
                let double = Double(half)
                if float.bitPattern != UInt32(sign) &<< 16 | 0x7F80_0000 | UInt32(payload) &<< 13 || !float.isSignalingNaN
                    || double.bitPattern != UInt64(sign) &<< 48 | 0x7FF8_0000_0000_0000 | UInt64(payload) &<< 42
                {
                    log.record(hex(half.bitPattern))
                }
            }
        }
        #expect(log.count == 0, log.summary)
    }
    #endif
}
