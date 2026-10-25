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

/// `static_cast<int32_t>(double)` as `StaticCast` (ConstantFunctions.h:269-285) leaves it unclamped: C++ UB that compiles
/// to arm64 FCVTZS (truncate, saturate, NaN -> 0).
// DEV-13: arm64 FCVTZS/FCVTZU semantics on every host.
@_spi(Testing)
public func arm64ConvertToInt32(_ value: Double) -> Int32 {
    if value.isNaN {
        return 0
    }
    if value >= 2_147_483_648.0 {
        return .max
    }
    if value <= -2_147_483_649.0 {
        return .min
    }
    guard let result = Int32(exactly: value.rounded(.towardZero)) else {
        wgslFatal("float-to-int conversion out of range after the range checks", cppSite: "ConstantFunctions.h:283")
    }
    return result
}

/// `static_cast<int32_t>(float)` after the `StaticCast` clamp (only NaN reaches the conversion unclamped).
@_spi(Testing)
public func arm64ConvertToInt32(_ value: Float) -> Int32 {
    arm64ConvertToInt32(Double(value))
}

/// `static_cast<uint32_t>(double)`: arm64 FCVTZU (truncate, saturate, NaN -> 0).
// DEV-13: arm64 FCVTZS/FCVTZU semantics on every host.
@_spi(Testing)
public func arm64ConvertToUInt32(_ value: Double) -> UInt32 {
    if value.isNaN || value <= -1.0 {
        return 0
    }
    if value >= 4_294_967_296.0 {
        return .max
    }
    guard let result = UInt32(exactly: value.rounded(.towardZero)) else {
        wgslFatal("float-to-int conversion out of range after the range checks", cppSite: "ConstantFunctions.h:283")
    }
    return result
}

/// `static_cast<uint32_t>(float)` after the `StaticCast` clamp.
@_spi(Testing)
public func arm64ConvertToUInt32(_ value: Float) -> UInt32 {
    arm64ConvertToUInt32(Double(value))
}

// Arithmetic operators

/// WGSL AbstractInt (C++ `int64_t`).
///
/// No operators: overflow is a shader error, never a wrap or a trap.
@_spi(Testing)
public struct AbstractInt: Equatable, Sendable {
    @_spi(Testing)
    public let value: Int64

    @_spi(Testing)
    public init(_ value: Int64) {
        self.value = value
    }

    // i32 and u32 wrap on overflow, but AbstractInt has no width to wrap to.
    @_spi(Testing)
    public func adding(_ other: AbstractInt) -> Result<AbstractInt, ConstEvalError> {
        let (result, overflow) = value.addingReportingOverflow(other.value)
        guard !overflow else {
            return .failure(.additionOverflow)
        }
        return .success(AbstractInt(result))
    }

    /// `-arg` under -fwrapv: `-INT64_MIN == INT64_MIN`, no error.
    @_spi(Testing)
    public var negated: AbstractInt {
        AbstractInt(0 &- value)
    }

    // i32 and u32 wrap on overflow, but AbstractInt has no width to wrap to.
    @_spi(Testing)
    public func subtracting(_ other: AbstractInt) -> Result<AbstractInt, ConstEvalError> {
        let (result, overflow) = value.subtractingReportingOverflow(other.value)
        guard !overflow else {
            return .failure(.subtractionOverflow)
        }
        return .success(AbstractInt(result))
    }

    // i32 and u32 wrap on overflow, but AbstractInt has no width to wrap to.
    @_spi(Testing)
    public func multiplying(_ other: AbstractInt) -> Result<AbstractInt, ConstEvalError> {
        let (result, overflow) = value.multipliedReportingOverflow(by: other.value)
        guard !overflow else {
            return .failure(.multiplyOverflow)
        }
        return .success(AbstractInt(result))
    }

    @_spi(Testing)
    public func dividing(_ other: AbstractInt) -> Result<AbstractInt, ConstEvalError> {
        ConstInt.divide(value, other.value).map(AbstractInt.init)
    }

    @_spi(Testing)
    public func modulo(_ other: AbstractInt) -> Result<AbstractInt, ConstEvalError> {
        ConstInt.modulo(value, other.value).map(AbstractInt.init)
    }
}

/// The integer lambdas of the arithmetic, bit-shift and `abs` constant functions (ConstantFunctions.h:504-826, 959-964).
/// i32 and u32 `+ - *` and unary minus wrap (`static_cast<T>(left + right)` under -fwrapv).
@_spi(Testing)
public enum ConstInt {
    @_spi(Testing)
    public static func add(_ left: Int32, _ right: Int32) -> Int32 {
        left &+ right
    }

    @_spi(Testing)
    public static func add(_ left: UInt32, _ right: UInt32) -> UInt32 {
        left &+ right
    }

    @_spi(Testing)
    public static func negate(_ arg: Int32) -> Int32 {
        0 &- arg
    }

    @_spi(Testing)
    public static func negate(_ arg: UInt32) -> UInt32 {
        0 &- arg
    }

    @_spi(Testing)
    public static func subtract(_ left: Int32, _ right: Int32) -> Int32 {
        left &- right
    }

    @_spi(Testing)
    public static func subtract(_ left: UInt32, _ right: UInt32) -> UInt32 {
        left &- right
    }

    @_spi(Testing)
    public static func multiply(_ left: Int32, _ right: Int32) -> Int32 {
        left &* right
    }

    @_spi(Testing)
    public static func multiply(_ left: UInt32, _ right: UInt32) -> UInt32 {
        left &* right
    }

    @_spi(Testing)
    public static func divide<T: FixedWidthInteger>(_ left: T, _ right: T) -> Result<T, ConstEvalError> {
        if right == 0 {
            return .failure(.invalidDivisionByZero)
        }
        if T.isSigned {
            if left == T.min && right == T(truncatingIfNeeded: -1) {
                return .failure(.invalidDivisionOverflow)
            }
        }
        return .success(left / right)
    }

    @_spi(Testing)
    public static func modulo<T: FixedWidthInteger>(_ left: T, _ right: T) -> Result<T, ConstEvalError> {
        if right == 0 {
            return .failure(.invalidModuloByZero)
        }
        if T.isSigned {
            if left == T.min && right == T(truncatingIfNeeded: -1) {
                return .failure(.invalidModuloOverflow)
            }
        }
        return .success(left % right)
    }

    // Bit Expressions

    @_spi(Testing)
    public static func shiftLeft(_ left: Int32, _ right: UInt32) -> Result<Int32, ConstEvalError> {
        guard right < 32 else {
            return .failure(.shiftLeftValueTooLarge)
        }
        let mask = UInt64.max &<< (32 &- (right &+ 1))
        let leftBits = UInt64(bitPattern: Int64(left)) & mask
        if leftBits != 0 && leftBits != mask {
            return .failure(.shiftLeftOverflows)
        }
        return .success(left &<< right)
    }

    @_spi(Testing)
    public static func shiftLeft(_ left: UInt32, _ right: UInt32) -> Result<UInt32, ConstEvalError> {
        guard right < 32 else {
            return .failure(.shiftLeftValueTooLarge)
        }
        let mask = UInt64.max &<< (32 &- right)
        if UInt64(left) & mask != 0 {
            return .failure(.shiftLeftOverflows)
        }
        return .success(left &<< right)
    }

    @_spi(Testing)
    public static func shiftLeft(_ left: AbstractInt, _ right: UInt32) -> Result<AbstractInt, ConstEvalError> {
        // https://www.w3.org/TR/WGSL/#bit-expr
        // An abstract-int shift left is defined as e1 * 2^e2, so the only rule is that the
        // result has to be representable. Zero shifted by any amount at all is still zero.
        if right >= 64 {
            if left.value != 0 {
                return .failure(.shiftLeftOverflows)
            }
            return .success(left)
        }
        let mask = UInt64.max &<< (64 &- (right &+ 1))
        let leftBits = UInt64(bitPattern: left.value) & mask
        if leftBits != 0 && leftBits != mask {
            return .failure(.shiftLeftOverflows)
        }
        return .success(AbstractInt(left.value &<< right))
    }

    @_spi(Testing)
    public static func shiftRight(_ left: Int32, _ right: UInt32) -> Result<Int32, ConstEvalError> {
        guard right < 32 else {
            return .failure(.shiftRightValueTooLarge)
        }
        return .success(left &>> right)
    }

    @_spi(Testing)
    public static func shiftRight(_ left: UInt32, _ right: UInt32) -> Result<UInt32, ConstEvalError> {
        guard right < 32 else {
            return .failure(.shiftRightValueTooLarge)
        }
        return .success(left &>> right)
    }

    @_spi(Testing)
    public static func shiftRight(_ left: AbstractInt, _ right: UInt32) -> AbstractInt {
        // Abstract-int right shifts are permitted to shift by >= bitwidth
        if right >= 64 {
            return AbstractInt(left.value < 0 ? -1 : 0)
        }
        return AbstractInt(left.value &>> right)
    }

    // Numeric Built-in Functions

    /// `std::abs(int32_t)` compiled with -fwrapv: `abs(INT32_MIN) == INT32_MIN`.
    @_spi(Testing)
    public static func abs(_ n: Int32) -> Int32 {
        n < 0 ? 0 &- n : n
    }

    @_spi(Testing)
    public static func abs(_ n: UInt32) -> UInt32 {
        n
    }

    @_spi(Testing)
    public static func abs(_ n: AbstractInt) -> AbstractInt {
        AbstractInt(n.value < 0 ? 0 &- n.value : n.value)
    }
}

/// The WGSL `clamp` constant function (ConstantFunctions.h:968-973): `std::min(std::max(e, low), high)`, not `std::clamp`.
@_spi(Testing)
public func constClamp<T: Comparable>(_ e: T, _ low: T, _ high: T) -> T {
    cxxMin(cxxMax(e, low), high)
}

/// The `constantDeterminant` lambdas (ConstantFunctions.h:1046-1068), with the multiply-adds clang forms
/// (`-ffp-contract=on`, `llvm.fmuladd`): fused on arm64; x86_64 has no FMA, so each is a multiply and then an add of
/// the addend to the product, which decides which NaN operand propagates.
@_spi(Testing)
public enum Determinant {
    // DEV-11: fused on arm64 as clang contracts it there, unfused elsewhere as x86_64 C++ computes it.
    @_spi(Testing)
    public static func solve2<T: FloatingPoint>(
        _ a: T,
        _ b: T,
        _ c: T,
        _ d: T
    ) -> T {
        #if arch(arm64) || arch(arm64_32)
        (-(b * c)).addingProduct(a, d) // lint-exempt(L-CE-7): floating-point arithmetic
        #else
        a * d + -(b * c) // lint-exempt(L-CE-7): floating-point arithmetic
        #endif
    }

    // DEV-11: fused on arm64 as clang contracts it there, unfused elsewhere as x86_64 C++ computes it.
    @_spi(Testing)
    public static func solve3<T: FloatingPoint>(
        _ a: T,
        _ b: T,
        _ c: T,
        _ d: T,
        _ e: T,
        _ f: T,
        _ g: T,
        _ h: T,
        _ i: T
    ) -> T {
        #if arch(arm64) || arch(arm64_32)
        var result = (b * f * g).addingProduct(a * e, i) // lint-exempt(L-CE-7): floating-point arithmetic
        result = result.addingProduct(c * d, h) // lint-exempt(L-CE-7): floating-point arithmetic
        result = result.addingProduct(-(c * e), g) // lint-exempt(L-CE-7): floating-point arithmetic
        result = result.addingProduct(-(b * d), i) // lint-exempt(L-CE-7): floating-point arithmetic
        return result.addingProduct(-(a * f), h) // lint-exempt(L-CE-7): floating-point arithmetic
        #else
        var result = a * e * i + b * f * g // lint-exempt(L-CE-7): floating-point arithmetic
        result = c * d * h + result // lint-exempt(L-CE-7): floating-point arithmetic
        result = -(c * e) * g + result // lint-exempt(L-CE-7): floating-point arithmetic
        result = -(b * d) * i + result // lint-exempt(L-CE-7): floating-point arithmetic
        return -(a * f) * h + result // lint-exempt(L-CE-7): floating-point arithmetic
        #endif
    }

    /// `roundSolve3` is the conversion of each `solve3` result back to the element type: the identity for f32 and
    /// AbstractFloat, the rounding to f16 for f16 (whose arithmetic runs in `Float`).
    // DEV-11: fused on arm64 as clang contracts it there, unfused elsewhere as x86_64 C++ computes it.
    @_spi(Testing)
    public static func solve4<T: FloatingPoint>(
        _ a: T,
        _ b: T,
        _ c: T,
        _ d: T,
        _ e: T,
        _ f: T,
        _ g: T,
        _ h: T,
        _ i: T,
        _ j: T,
        _ k: T,
        _ l: T,
        _ m: T,
        _ n: T,
        _ o: T,
        _ p: T,
        roundSolve3: (T) -> T = { $0 }
    ) -> T {
        let minorA = roundSolve3(solve3(f, g, h, j, k, l, n, o, p))
        let minorB = roundSolve3(solve3(e, g, h, i, k, l, m, o, p))
        let minorC = roundSolve3(solve3(e, f, h, i, j, l, m, n, p))
        let minorD = roundSolve3(solve3(e, f, g, i, j, k, m, n, o))
        #if arch(arm64) || arch(arm64_32)
        var result = (-(b * minorB)).addingProduct(a, minorA) // lint-exempt(L-CE-7): floating-point arithmetic
        result = result.addingProduct(c, minorC)
        return result.addingProduct(-d, minorD) // lint-exempt(L-CE-7): floating-point arithmetic
        #else
        var result = a * minorA + -(b * minorB) // lint-exempt(L-CE-7): floating-point arithmetic
        result = c * minorC + result // lint-exempt(L-CE-7): floating-point arithmetic
        return -d * minorD + result // lint-exempt(L-CE-7): floating-point arithmetic
        #endif
    }
}

/// `std::min` (`(b < a) ? b : a`).
@_spi(Testing)
public func cxxMin<T: Comparable>(_ a: T, _ b: T) -> T {
    b < a ? b : a
}

/// `std::max` (`(a < b) ? b : a`): `std::max(-0.0, 0.0)` is -0.0, where `Swift.max` gives 0.0.
@_spi(Testing)
public func cxxMax<T: Comparable>(_ a: T, _ b: T) -> T {
    a < b ? b : a
}

/// `std::clamp` (`v < low ? low : (high < v ? high : v)`), including libc++'s hardened bounds check.
@_spi(Testing)
public func cxxClamp<T: Comparable>(_ v: T, _ low: T, _ high: T) -> T {
    guard !(high < low) else {
        wgslFatal("Bad bounds passed to std::clamp", cppSite: "ConstantFunctions.h:278")
    }
    return v < low ? low : (high < v ? high : v)
}

/// `std::min` on `half`: the promoted floats are compared and one of the arguments is returned unchanged.
@_spi(Testing)
public func cxxMin(_ a: Half, _ b: Half) -> Half {
    Float(b) < Float(a) ? b : a
}

@_spi(Testing)
public func cxxMax(_ a: Half, _ b: Half) -> Half {
    Float(a) < Float(b) ? b : a
}

@_spi(Testing)
public func cxxClamp(_ v: Half, _ low: Half, _ high: Half) -> Half {
    guard !(Float(high) < Float(low)) else {
        wgslFatal("Bad bounds passed to std::clamp", cppSite: "ConstantFunctions.h:278")
    }
    return Float(v) < Float(low) ? low : (Float(high) < Float(v) ? high : v)
}

@_spi(Testing)
public func constClamp(_ e: Half, _ low: Half, _ high: Half) -> Half {
    cxxMin(cxxMax(e, low), high)
}

/// `fmod` (ConstantFunctions.h:675): `truncatingRemainder`, never the IEEE `remainder(dividingBy:)`.
@_spi(Testing)
public func cxxFmod(_ left: Float, _ right: Float) -> Float {
    left.truncatingRemainder(dividingBy: right)
}

@_spi(Testing)
public func cxxFmod(_ left: Double, _ right: Double) -> Double {
    left.truncatingRemainder(dividingBy: right)
}

/// The fixed messages of the integer constant functions (ConstantFunctions.h:519-817); the float overflow checks reuse
/// the first three.
@_spi(Testing)
public enum ConstEvalError: Error, Equatable, Sendable {
    case additionOverflow
    case subtractionOverflow
    case multiplyOverflow
    case invalidDivisionByZero
    case invalidDivisionOverflow
    case invalidModuloByZero
    case invalidModuloOverflow
    case shiftLeftOverflows
    case shiftLeftValueTooLarge
    case shiftRightValueTooLarge

    @_spi(Testing)
    public var message: StaticString {
        switch self {
        case .additionOverflow:
            "addition overflow"
        case .subtractionOverflow:
            "subtraction overflow"
        case .multiplyOverflow:
            "multiply overflow"
        case .invalidDivisionByZero:
            "invalid division by zero"
        case .invalidDivisionOverflow:
            "invalid division overflow"
        case .invalidModuloByZero:
            "invalid modulo by zero"
        case .invalidModuloOverflow:
            "invalid modulo overflow"
        case .shiftLeftOverflows:
            "shift left overflows"
        case .shiftLeftValueTooLarge:
            "shift left value must be less than the bit width of the shifted value, which is 32"
        case .shiftRightValueTooLarge:
            "shift right value must be less than the bit width of the shifted value, which is 32"
        }
    }
}
