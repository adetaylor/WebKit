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

internal import Darwin

/// The libm functions the constant functions call (`WRAP_STD(fn)` and friends, ConstantFunctions.h:499-500).
///
/// `std::fn` on f32 runs the `…f` function, on f16 the `…f` function of the promoted float, on AbstractFloat the double
/// one. The Swift standard library has no transcendental functions, and byte identity needs the same libm as the C++.
@_spi(Testing)
public enum LibM {
    // Trigonometric and hyperbolic (ConstantFunctions.h:946-957).

    @_spi(Testing)
    public static func acosf(_ x: Float) -> Float {
        Darwin.acosf(x)
    }

    @_spi(Testing)
    public static func acos(_ x: Double) -> Double {
        Darwin.acos(x)
    }

    @_spi(Testing)
    public static func asinf(_ x: Float) -> Float {
        Darwin.asinf(x)
    }

    @_spi(Testing)
    public static func asin(_ x: Double) -> Double {
        Darwin.asin(x)
    }

    @_spi(Testing)
    public static func atanf(_ x: Float) -> Float {
        Darwin.atanf(x)
    }

    @_spi(Testing)
    public static func atan(_ x: Double) -> Double {
        Darwin.atan(x)
    }

    @_spi(Testing)
    public static func cosf(_ x: Float) -> Float {
        Darwin.cosf(x)
    }

    @_spi(Testing)
    public static func cos(_ x: Double) -> Double {
        Darwin.cos(x)
    }

    @_spi(Testing)
    public static func sinf(_ x: Float) -> Float {
        Darwin.sinf(x)
    }

    @_spi(Testing)
    public static func sin(_ x: Double) -> Double {
        Darwin.sin(x)
    }

    @_spi(Testing)
    public static func tanf(_ x: Float) -> Float {
        Darwin.tanf(x)
    }

    @_spi(Testing)
    public static func tan(_ x: Double) -> Double {
        Darwin.tan(x)
    }

    @_spi(Testing)
    public static func acoshf(_ x: Float) -> Float {
        Darwin.acoshf(x)
    }

    @_spi(Testing)
    public static func acosh(_ x: Double) -> Double {
        Darwin.acosh(x)
    }

    @_spi(Testing)
    public static func asinhf(_ x: Float) -> Float {
        Darwin.asinhf(x)
    }

    @_spi(Testing)
    public static func asinh(_ x: Double) -> Double {
        Darwin.asinh(x)
    }

    @_spi(Testing)
    public static func atanhf(_ x: Float) -> Float {
        Darwin.atanhf(x)
    }

    @_spi(Testing)
    public static func atanh(_ x: Double) -> Double {
        Darwin.atanh(x)
    }

    @_spi(Testing)
    public static func coshf(_ x: Float) -> Float {
        Darwin.coshf(x)
    }

    @_spi(Testing)
    public static func cosh(_ x: Double) -> Double {
        Darwin.cosh(x)
    }

    @_spi(Testing)
    public static func sinhf(_ x: Float) -> Float {
        Darwin.sinhf(x)
    }

    @_spi(Testing)
    public static func sinh(_ x: Double) -> Double {
        Darwin.sinh(x)
    }

    @_spi(Testing)
    public static func tanhf(_ x: Float) -> Float {
        Darwin.tanhf(x)
    }

    @_spi(Testing)
    public static func tanh(_ x: Double) -> Double {
        Darwin.tanh(x)
    }

    // ConstantFunctions.h:966

    @_spi(Testing)
    public static func atan2f(_ y: Float, _ x: Float) -> Float {
        Darwin.atan2f(y, x)
    }

    @_spi(Testing)
    public static func atan2(_ y: Double, _ x: Double) -> Double {
        Darwin.atan2(y, x)
    }

    // Exponential and logarithmic (ConstantFunctions.h:1159-1160, 1383-1384, 1464).

    @_spi(Testing)
    public static func expf(_ x: Float) -> Float {
        Darwin.expf(x)
    }

    @_spi(Testing)
    public static func exp(_ x: Double) -> Double {
        Darwin.exp(x)
    }

    @_spi(Testing)
    public static func exp2f(_ x: Float) -> Float {
        Darwin.exp2f(x)
    }

    @_spi(Testing)
    public static func exp2(_ x: Double) -> Double {
        Darwin.exp2(x)
    }

    /// `std::frexp(value, &exp)` (ConstantFunctions.h:1275), without the out-pointer.
    @_spi(Testing)
    public static func frexpf(_ value: Float) -> (fract: Float, exp: Int32) {
        guard value.isFinite && value != 0 else {
            return (value, 0)
        }
        return (Float(signOf: value, magnitudeOf: value.significand / 2), Int32(truncatingIfNeeded: value.exponent &+ 1))
    }

    @_spi(Testing)
    public static func frexp(_ value: Double) -> (fract: Double, exp: Int32) {
        guard value.isFinite && value != 0 else {
            return (value, 0)
        }
        return (Double(signOf: value, magnitudeOf: value.significand / 2), Int32(truncatingIfNeeded: value.exponent &+ 1))
    }

    // ConstantFunctions.h:1359-1377

    @_spi(Testing)
    public static func ldexpf(_ x: Float, _ exp: Int32) -> Float {
        Darwin.ldexpf(x, exp)
    }

    @_spi(Testing)
    public static func ldexp(_ x: Double, _ exp: Int32) -> Double {
        Darwin.ldexp(x, exp)
    }

    @_spi(Testing)
    public static func logf(_ x: Float) -> Float {
        Darwin.logf(x)
    }

    @_spi(Testing)
    public static func log(_ x: Double) -> Double {
        Darwin.log(x)
    }

    @_spi(Testing)
    public static func log2f(_ x: Float) -> Float {
        Darwin.log2f(x)
    }

    @_spi(Testing)
    public static func log2(_ x: Double) -> Double {
        Darwin.log2(x)
    }

    /// `std::modf(value, &whole)` (ConstantFunctions.h:1415), without the out-pointer: the fraction keeps the sign of
    /// `value` (`modf(-3.0)` is (-0.0, -3.0), where the Swift overlay's `modf` gives +0.0).
    @_spi(Testing)
    public static func modff(_ value: Float) -> (fract: Float, whole: Float) {
        if value.isNaN {
            return (value, value)
        }
        let whole = value.rounded(.towardZero)
        if value.isInfinite {
            return (Float(signOf: value, magnitudeOf: 0), whole)
        }
        return (Float(signOf: value, magnitudeOf: value - whole), whole)
    }

    @_spi(Testing)
    public static func modf(_ value: Double) -> (fract: Double, whole: Double) {
        if value.isNaN {
            return (value, value)
        }
        let whole = value.rounded(.towardZero)
        if value.isInfinite {
            return (Double(signOf: value, magnitudeOf: 0), whole)
        }
        return (Double(signOf: value, magnitudeOf: value - whole), whole)
    }

    @_spi(Testing)
    public static func powf(_ base: Float, _ exp: Float) -> Float {
        Darwin.powf(base, exp)
    }

    @_spi(Testing)
    public static func pow(_ base: Double, _ exp: Double) -> Double {
        Darwin.pow(base, exp)
    }
}
