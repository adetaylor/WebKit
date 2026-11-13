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

// Expected values are the C++ results (ConstantFunctions.h, arm64e, -fwrapv).

private func message<T>(_ result: Result<T, ConstEvalError>) -> String? {
    guard case .failure(let error) = result else {
        return nil
    }
    return error.message.description
}

private func value<T>(_ result: Result<T, ConstEvalError>) -> T? {
    guard case .success(let value) = result else {
        return nil
    }
    return value
}

private func bits(_ value: Float) -> UInt32 {
    value.bitPattern
}

private func bits(_ value: Double) -> UInt64 {
    value.bitPattern
}

struct WGSLConstEvalArithmeticTests {
    @Test
    func abstractIntOverflowIsAnError() {
        let max = AbstractInt(.max)
        let min = AbstractInt(.min)
        #expect(message(max.adding(AbstractInt(1))) == "addition overflow")
        #expect(message(min.subtracting(AbstractInt(1))) == "subtraction overflow")
        #expect(message(AbstractInt(3_037_000_500).multiplying(AbstractInt(3_037_000_500))) == "multiply overflow")
        #expect(message(min.multiplying(AbstractInt(-1))) == "multiply overflow")
        #expect(value(max.adding(min)) == AbstractInt(-1))
        #expect(value(AbstractInt(-3_037_000_499).multiplying(AbstractInt(3_037_000_499))) == AbstractInt(-9_223_372_030_926_249_001))
        #expect(value(min.subtracting(AbstractInt(-1))) == AbstractInt(.min + 1))
    }

    @Test
    func unaryMinusWraps() {
        #expect(AbstractInt(.min).negated == AbstractInt(.min))
        #expect(AbstractInt(5).negated == AbstractInt(-5))
        #expect(ConstInt.negate(Int32.min) == .min)
        #expect(ConstInt.negate(Int32(7)) == -7)
        #expect(ConstInt.negate(UInt32(1)) == .max)
    }

    @Test
    func concreteIntegersWrap() {
        #expect(ConstInt.add(Int32.max, 1) == .min)
        #expect(ConstInt.add(UInt32.max, 2) == 1)
        #expect(ConstInt.subtract(Int32.min, 1) == .max)
        #expect(ConstInt.subtract(UInt32(0), 1) == .max)
        #expect(ConstInt.multiply(Int32(65_536), 65_536) == 0)
        #expect(ConstInt.multiply(Int32(46_341), 46_341) == -2_147_479_015)
        #expect(ConstInt.multiply(UInt32(0x8000_0001), 3) == 0x8000_0003)
    }

    @Test
    func divisionAndModulo() {
        #expect(message(ConstInt.divide(Int32(1), 0)) == "invalid division by zero")
        #expect(message(ConstInt.divide(UInt32(1), 0)) == "invalid division by zero")
        #expect(message(ConstInt.divide(Int32.min, -1)) == "invalid division overflow")
        #expect(message(AbstractInt(.min).dividing(AbstractInt(-1))) == "invalid division overflow")
        #expect(message(ConstInt.modulo(Int32(1), 0)) == "invalid modulo by zero")
        #expect(message(ConstInt.modulo(Int32.min, -1)) == "invalid modulo overflow")
        #expect(message(AbstractInt(.min).modulo(AbstractInt(-1))) == "invalid modulo overflow")
        #expect(message(AbstractInt(7).modulo(AbstractInt(0))) == "invalid modulo by zero")
        #expect(value(ConstInt.divide(Int32(-7), 2)) == -3)
        #expect(value(ConstInt.modulo(Int32(-7), 2)) == -1)
        #expect(value(ConstInt.modulo(Int32(7), -2)) == 1)
        #expect(value(ConstInt.divide(UInt32.max, 0x8000_0000)) == 1)
        #expect(value(ConstInt.divide(Int32.min, 1)) == .min)
        #expect(value(AbstractInt(.min).dividing(AbstractInt(2))) == AbstractInt(-4_611_686_018_427_387_904))
    }

    @Test
    func absOfMinimumIsMinimum() {
        #expect(ConstInt.abs(Int32.min) == .min)
        #expect(ConstInt.abs(Int32(-5)) == 5)
        #expect(ConstInt.abs(UInt32.max) == .max)
        #expect(ConstInt.abs(AbstractInt(.min)) == AbstractInt(.min))
        #expect(ConstInt.abs(AbstractInt(-3)) == AbstractInt(3))
    }

    @Test
    func shiftLeft() {
        let tooLarge = "shift left value must be less than the bit width of the shifted value, which is 32"
        #expect(message(ConstInt.shiftLeft(Int32(0), 32)) == tooLarge)
        #expect(message(ConstInt.shiftLeft(UInt32(0), 0xFFFF_FFFF)) == tooLarge)
        #expect(message(ConstInt.shiftLeft(Int32(1), 31)) == "shift left overflows")
        #expect(message(ConstInt.shiftLeft(Int32(0x4000_0000), 1)) == "shift left overflows")
        #expect(value(ConstInt.shiftLeft(Int32(-1), 31)) == .min)
        #expect(value(ConstInt.shiftLeft(Int32(-0x4000_0000), 1)) == .min)
        #expect(value(ConstInt.shiftLeft(Int32(3), 29)) == 0x6000_0000)
        #expect(value(ConstInt.shiftLeft(UInt32(1), 31)) == 0x8000_0000)
        #expect(message(ConstInt.shiftLeft(UInt32(2), 31)) == "shift left overflows")
        #expect(value(ConstInt.shiftLeft(UInt32(0xFFFF), 16)) == 0xFFFF_0000)
        #expect(value(ConstInt.shiftLeft(AbstractInt(0), 100)) == AbstractInt(0))
        #expect(message(ConstInt.shiftLeft(AbstractInt(1), 64)) == "shift left overflows")
        #expect(message(ConstInt.shiftLeft(AbstractInt(1), 63)) == "shift left overflows")
        #expect(value(ConstInt.shiftLeft(AbstractInt(-1), 63)) == AbstractInt(.min))
        #expect(value(ConstInt.shiftLeft(AbstractInt(1), 62)) == AbstractInt(0x4000_0000_0000_0000))
        #expect(message(ConstInt.shiftLeft(AbstractInt(0x8000_0000), 32)) == "shift left overflows")
        #expect(value(ConstInt.shiftLeft(AbstractInt(0x4000_0000), 32)) == AbstractInt(0x4000_0000_0000_0000))
        #expect(value(ConstInt.shiftLeft(AbstractInt(-0x8000_0000), 32)) == AbstractInt(.min))
    }

    @Test
    func shiftRight() {
        let tooLarge = "shift right value must be less than the bit width of the shifted value, which is 32"
        #expect(message(ConstInt.shiftRight(Int32(-1), 32)) == tooLarge)
        #expect(message(ConstInt.shiftRight(UInt32(1), 33)) == tooLarge)
        #expect(value(ConstInt.shiftRight(Int32(-8), 1)) == -4)
        #expect(value(ConstInt.shiftRight(Int32.min, 31)) == -1)
        #expect(value(ConstInt.shiftRight(UInt32(0x8000_0000), 31)) == 1)
        #expect(ConstInt.shiftRight(AbstractInt(-5), 64) == AbstractInt(-1))
        #expect(ConstInt.shiftRight(AbstractInt(5), 0xFFFF_FFFF) == AbstractInt(0))
        #expect(ConstInt.shiftRight(AbstractInt(.min), 63) == AbstractInt(-1))
        #expect(ConstInt.shiftRight(AbstractInt(.max), 62) == AbstractInt(1))
    }

    @Test
    func minMaxFollowTheCxxArgumentOrder() {
        #expect(bits(cxxMax(-0.0 as Float, 0.0)) == 0x8000_0000)
        #expect(bits(Swift.max(-0.0 as Float, 0.0)) == 0)
        #expect(bits(cxxMax(0.0 as Float, -0.0)) == 0)
        #expect(bits(cxxMin(0.0 as Double, -0.0)) == 0)
        #expect(bits(cxxMin(-0.0 as Double, 0.0)) == 0x8000_0000_0000_0000)
        #expect(cxxMax(Float.nan, 1).isNaN)
        #expect(cxxMax(1, Float.nan) == 1)
        #expect(cxxMin(Double.nan, 1).isNaN)
        #expect(cxxMin(1, Double.nan) == 1)
        #expect(cxxMax(Int32(-1), 1) == 1)
        #expect(cxxMin(UInt32(0), .max) == 0)
    }

    @Test
    func halfMinMaxReturnTheArgumentBits() {
        let negativeZero = Half(bitPattern: 0x8000)
        let zero = Half(bitPattern: 0)
        let one = Half(bitPattern: 0x3c00)
        let signalingNaN = Half(bitPattern: 0x7d01)
        #expect(cxxMax(negativeZero, zero).bitPattern == 0x8000)
        #expect(cxxMin(zero, negativeZero).bitPattern == 0)
        #expect(cxxMax(signalingNaN, one).bitPattern == 0x7d01)
        #expect(cxxMin(one, signalingNaN).bitPattern == 0x3c00)
        #expect(constClamp(signalingNaN, zero, one).bitPattern == 0x7d01)
        #expect(constClamp(Half(bitPattern: 0x4000), zero, one).bitPattern == 0x3c00)
        #expect(cxxClamp(negativeZero, zero, one).bitPattern == 0x8000)
        #expect(cxxClamp(Half(bitPattern: 0xbc00), zero, one).bitPattern == 0)
    }

    @Test
    func clamp() {
        #expect(constClamp(Float.nan, 0, 1).isNaN)
        #expect(constClamp(0.5, Float.nan, 1) == 0.5)
        #expect(constClamp(2, 0, Float.nan) == 2)
        #expect(bits(constClamp(-0.0 as Float, 0.0, 1.0)) == 0x8000_0000)
        #expect(bits(constClamp(0.0 as Float, -0.0, -0.0)) == 0)
        #expect(constClamp(Int32(7), 0, 5) == 5)
        #expect(constClamp(Int32(-7), 0, 5) == 0)
        #expect(cxxClamp(Float.nan, 0, 1).isNaN)
        #expect(bits(cxxClamp(-0.0 as Float, 0.0, 1.0)) == 0x8000_0000)
        #expect(cxxClamp(UInt32(9), 3, 5) == 5)
        #expect(cxxClamp(Double(-9), -3, 5) == -3)
    }

    @Test
    func floatToIntConversions() {
        #expect(arm64ConvertToInt32(2_147_483_647.5) == .max)
        #expect(arm64ConvertToInt32(-2_147_483_648.5) == .min)
        #expect(arm64ConvertToInt32(-2_147_483_649.0) == .min)
        #expect(arm64ConvertToInt32(-1.9) == -1)
        #expect(arm64ConvertToInt32(1.9 as Float) == 1)
        #expect(arm64ConvertToUInt32(-0.999_999) == 0)
        #expect(arm64ConvertToUInt32(4_294_967_295.5) == .max)
        #expect(arm64ConvertToUInt32(3.99 as Float) == 3)
    }

    // DEV-13: the out-of-range and NaN conversions that are UB in C++ get the arm64 result on every host.
    @Test
    func DEV_13_floatToIntSaturatesOnEveryHost() {
        #expect(arm64ConvertToInt32(Double.nan) == 0)
        #expect(arm64ConvertToInt32(-Double.nan) == 0)
        #expect(arm64ConvertToInt32(1e300) == .max)
        #expect(arm64ConvertToInt32(-Double.infinity) == .min)
        #expect(arm64ConvertToInt32(2_147_483_648.0) == .max)
        #expect(arm64ConvertToInt32(Float.nan) == 0)
        #expect(arm64ConvertToInt32(Float.infinity) == .max)
        #expect(arm64ConvertToUInt32(Double.nan) == 0)
        #expect(arm64ConvertToUInt32(-1.0) == 0)
        #expect(arm64ConvertToUInt32(-Double.infinity) == 0)
        #expect(arm64ConvertToUInt32(4_294_967_296.0) == .max)
        #expect(arm64ConvertToUInt32(Float.nan) == 0)
        #expect(arm64ConvertToUInt32(-Float.infinity) == 0)
    }

    @Test
    func fmodIsTruncatingRemainder() {
        #expect(cxxFmod(5.5 as Float, 2) == 1.5)
        #expect(cxxFmod(-5.5 as Float, 2) == -1.5)
        #expect(cxxFmod(5.0 as Double, 3) == 2)
        #expect((5.0 as Double).remainder(dividingBy: 3) == -1)
        #expect(bits(cxxFmod(-4.0 as Double, 2)) == 0x8000_0000_0000_0000)
        #expect(cxxFmod(1 as Float, .infinity) == 1)
        #expect(cxxFmod(1 as Float, 0).isNaN)
        #expect(cxxFmod(Double.infinity, 1).isNaN)
    }

    @Test
    func determinant() {
        #expect(Determinant.solve2(1 as Float, 2, 3, 4) == -2)
        #expect(Determinant.solve3(2 as Double, 0, 0, 0, 3, 0, 0, 0, 4) == 24)
        #expect(Determinant.solve3(1 as Float, 2, 3, 4, 5, 6, 7, 8, 10) == -3)
        #expect(Determinant.solve4(1 as Double, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4) == 24)
        #expect(Determinant.solve4(1 as Float, 2, 3, 4, 5, 6, 7, 8, 2, 6, 4, 8, 3, 1, 1, 2) == 72)
        #expect(Determinant.solve4(1 as Float, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, roundSolve3: { $0 * 2 }) == 0)
    }

    // DEV-11: clang contracts the determinant's multiply-adds on arm64 only; Swift mirrors each architecture.
    @Test
    func DEV_11_determinantContraction() {
        // Matrix elements in the C++'s column-major order, solveN's arguments as constantDeterminant passes them.
        let m2: [Float] = [-1368.867_187_5, 85.367_187_5, 11_773.546_875, 91_993.5]
        let d2 = Determinant.solve2(m2[0], m2[2], m2[1], m2[3])
        let m3 = [0x3f80_0000, 0x47cc_65a0, 0xc3cf_ea50, 0x48b9_0760, 0x3f80_0000, 0xc655_3a00, 0xc4dd_3d80, 0x4576_b880, 0x3f80_0000]
            .map { Float(bitPattern: $0) }
        let d3 = Determinant.solve3(m3[0], m3[3], m3[6], m3[1], m3[4], m3[7], m3[2], m3[5], m3[8])
        let m4 = [
            0x4000_0000, 0x474c_4940, 0x478a_1540, 0x4258_7a10, 0x40be_c000, 0x4000_0000, 0xc953_8640, 0xc339_ba80,
            0x439e_b400, 0x492b_2170, 0x4000_0000, 0xc8bc_1980, 0x4294_9eb0, 0x433e_83a0, 0x3e38_7700, 0x4000_0000,
        ]
        .map { Float(bitPattern: $0) }
        let d4 = Determinant.solve4(
            m4[0],
            m4[4],
            m4[8],
            m4[12],
            m4[1],
            m4[5],
            m4[9],
            m4[13],
            m4[2],
            m4[6],
            m4[10],
            m4[14],
            m4[3],
            m4[7],
            m4[11],
            m4[15]
        )
        let m64 = [0x40ab_1e7c_3280_0000, 0xc0c4_1b55_b480_0000, 0x4022_ec89_3700_0000, 0x41c0_4d95_3180_0000]
            .map {
                Double(bitPattern: $0)
            }
        let d64 = Determinant.solve2(m64[0], m64[2], m64[1], m64[3])
        #expect(bits(m2[0]) == 0xc4ab_1bc0 && bits(m2[1]) == 0x42aa_bc00 && bits(m2[2]) == 0x4637_f630 && bits(m2[3]) == 0x47b3_acc0)
        #if arch(arm64)
        #expect(bits(d2) == 0xccf2_1a7f)
        #expect(bits(d3) == 0x53d9_3c21)
        #expect(bits(d4) == 0xdd90_2f46)
        #expect(bits(d64) == 0x427b_a1fb_dfc5_ee8f)
        #else
        #expect(bits(d2) == 0xccf2_1a7e)
        #expect(bits(d3) == 0x53d9_3c20)
        #expect(bits(d4) == 0xdd90_2f45)
        #expect(bits(d64) == 0x427b_a1fb_dfc5_ee8e)
        #endif
    }

    @Test
    func libmMatchesTheCxx() {
        #if arch(arm64)
        #expect(bits(LibM.sinf(1)) == 0x3f57_6aa4)
        #expect(bits(LibM.tanf(Float(bitPattern: 0x3fc9_0fdb))) == 0xcbae_8a4a)
        #expect(bits(LibM.log2f(3)) == 0x3fca_e00d)
        #expect(bits(LibM.atan2f(1, -1)) == 0x4016_cbe4)
        #expect(bits(LibM.powf(2, 0.5)) == 0x3fb5_04f3)
        #expect(bits(LibM.acosh(2)) == 0x3ff5_1242_7198_0434)
        #expect(bits(LibM.exp2(0.5)) == 0x3ff6_a09e_667f_3bcd)
        #expect(bits(LibM.tanh(0.5)) == 0x3fdd_9353_d756_8af3)
        #expect(bits(LibM.cos(Double(bitPattern: 0x4009_21fb_5444_2d18))) == 0xbff0_0000_0000_0000)
        #endif
        #expect(LibM.expf(0) == 1)
        #expect(LibM.log(1) == 0)
        #expect(LibM.asinf(2).isNaN)
    }

    @Test
    func frexpAndModf() {
        #expect(LibM.frexpf(-8) == (-0.5, 4))
        #expect(LibM.frexpf(-3) == (-0.75, 2))
        #expect(LibM.frexp(1) == (0.5, 1))
        #expect(LibM.frexpf(.leastNonzeroMagnitude) == (0.5, -148))
        #expect(bits(LibM.frexpf(-0.0).fract) == 0x8000_0000 && LibM.frexpf(-0.0).exp == 0)
        #expect(LibM.frexpf(.infinity) == (.infinity, 0))
        #expect(LibM.frexp(-.infinity) == (-.infinity, 0))
        let signalingNaN = Float(bitPattern: 0x7fa0_0001)
        #expect(bits(LibM.frexpf(signalingNaN).fract) == 0x7fa0_0001 && LibM.frexpf(signalingNaN).exp == 0)

        #expect(LibM.modff(2.5) == (0.5, 2))
        #expect(LibM.modf(-2.5) == (-0.5, -2))
        #expect(bits(LibM.modff(-3).fract) == 0x8000_0000 && LibM.modff(-3).whole == -3)
        #expect(bits(LibM.modf(-0.0).fract) == 0x8000_0000_0000_0000 && bits(LibM.modf(-0.0).whole) == 0x8000_0000_0000_0000)
        #expect(bits(LibM.modff(-.infinity).fract) == 0x8000_0000 && LibM.modff(-.infinity).whole == -.infinity)
        #expect(bits(LibM.modff(.leastNonzeroMagnitude).fract) == 1 && LibM.modff(.leastNonzeroMagnitude).whole == 0)
        #expect(bits(LibM.modff(signalingNaN).fract) == 0x7fa0_0001 && bits(LibM.modff(signalingNaN).whole) == 0x7fa0_0001)
    }

    @Test
    func ldexp() {
        #expect(bits(LibM.ldexpf(1, -149)) == 1)
        #expect(bits(LibM.ldexpf(1, -150)) == 0)
        #expect(LibM.ldexpf(1, 128) == .infinity)
        #expect(LibM.ldexp(1, 1023) == 0x1p1023)
        #expect(LibM.ldexp(1, -1074) == .leastNonzeroMagnitude)
        #expect(LibM.ldexp(3, -1) == 1.5)
    }

    @Test
    func errorMessages() {
        let expected: [(ConstEvalError, String)] = [
            (.additionOverflow, "addition overflow"),
            (.subtractionOverflow, "subtraction overflow"),
            (.multiplyOverflow, "multiply overflow"),
            (.invalidDivisionByZero, "invalid division by zero"),
            (.invalidDivisionOverflow, "invalid division overflow"),
            (.invalidModuloByZero, "invalid modulo by zero"),
            (.invalidModuloOverflow, "invalid modulo overflow"),
            (.shiftLeftOverflows, "shift left overflows"),
            (.shiftLeftValueTooLarge, "shift left value must be less than the bit width of the shifted value, which is 32"),
            (.shiftRightValueTooLarge, "shift right value must be less than the bit width of the shifted value, which is 32"),
        ]
        for (error, text) in expected {
            #expect(error.message.description == text)
        }
    }
}
