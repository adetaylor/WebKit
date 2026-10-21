// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

// Numeric Built-in Functions

func constantAcos(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.acosf, LibM.acos)
}

func constantAsin(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.asinf, LibM.asin)
}

func constantAtan(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.atanf, LibM.atan)
}

func constantCos(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.cosf, LibM.cos)
}

func constantSin(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.sinf, LibM.sin)
}

func constantTan(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.tanf, LibM.tan)
}

func constantAcosh(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.acoshf, LibM.acosh)
}

func constantAsinh(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.asinhf, LibM.asinh)
}

func constantAtanh(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.atanhf, LibM.atanh)
}

func constantCosh(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.coshf, LibM.cosh)
}

func constantSinh(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.sinhf, LibM.sinh)
}

func constantTanh(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.tanhf, LibM.tanh)
}

func constantAbs(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .number,
        i32: { n in .success(.int32(ConstInt.abs(n))) },
        u32: { n in .success(.uint32(n)) },
        abstractInt: { n in .success(.int64(ConstInt.abs(AbstractInt(n)).value)) },
        f32: { n in .success(.float(n.magnitude)) },
        f16: { n in .success(.half(Half(Float(n).magnitude))) },
        abstractFloat: { n in .success(.double(n.magnitude)) }
    )
}

func constantAtan2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .float,
        f32: { arg, args in .success(.float(LibM.atan2f(arg, args))) },
        f16: { arg, args in .success(.half(Half(LibM.atan2f(Float(arg), Float(args))))) },
        abstractFloat: { arg, args in .success(.double(LibM.atan2(arg, args))) }
    )
}

func constantCeil(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, { $0.rounded(.up) }, { $0.rounded(.up) })
}

func constantClamp(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    func clamp<T: Comparable & ConstantScalar>(_ e: T, _ low: T, _ high: T, _ number: (T) -> MessageText) -> ConstantResult {
        if low > high {
            return .failure(ConstantFunctionError(message: "clamp called with low (\(number(low))) greater than high (\(number(high)))"))
        }
        return .success(constClamp(e, low, high).constantValue)
    }

    return constantTernaryOperation(
        arguments,
        .number,
        i32: { e, low, high in clamp(e, low, high) { "\($0)" } },
        u32: { e, low, high in clamp(e, low, high) { "\($0)" } },
        abstractInt: { e, low, high in clamp(e, low, high) { "\($0)" } },
        f32: { e, low, high in clamp(e, low, high) { "\(number: $0)" } },
        f16: { e, low, high in
            if Float(low) > Float(high) {
                return .failure(
                    ConstantFunctionError(message: "clamp called with low (\(number: low)) greater than high (\(number: high))")
                )
            }
            return .success(.half(constClamp(e, low, high)))
        },
        abstractFloat: { e, low, high in clamp(e, low, high) { "\(number: $0)" } }
    )
}

func constantCountLeadingZeros(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    func countLeadingZeros<T: FixedWidthInteger>(_ arg: T) -> T {
        T(truncatingIfNeeded: UInt32(truncatingIfNeeded: arg).leadingZeroBitCount)
    }

    return constantUnaryOperation(
        arguments,
        .concreteInteger,
        i32: { arg in .success(.int32(countLeadingZeros(arg))) },
        u32: { arg in .success(.uint32(countLeadingZeros(arg))) }
    )
}

func constantCountOneBits(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    func countOneBits<T: FixedWidthInteger>(_ arg: T) -> T {
        T(truncatingIfNeeded: UInt32(truncatingIfNeeded: arg).nonzeroBitCount)
    }

    return constantUnaryOperation(
        arguments,
        .concreteInteger,
        i32: { arg in .success(.int32(countOneBits(arg))) },
        u32: { arg in .success(.uint32(countOneBits(arg))) }
    )
}

func constantCountTrailingZeros(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    func countTrailingZeros<T: FixedWidthInteger>(_ arg: T) -> T {
        T(truncatingIfNeeded: UInt32(truncatingIfNeeded: arg).trailingZeroBitCount)
    }

    return constantUnaryOperation(
        arguments,
        .concreteInteger,
        i32: { arg in .success(.int32(countTrailingZeros(arg))) },
        u32: { arg in .success(.uint32(countTrailingZeros(arg))) }
    )
}

func constantCross(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 2)
    let lhs = arguments[0].toVector()
    let rhs = arguments[1].toVector()

    // `T` is computed in `P` (f16 in f32, as `half` promotes); `round` is `static_cast<T>` back to `P`'s precision and
    // `make` the `ConstantValue` of `static_cast<T>(value)`.
    func cross<P: BinaryFloatingPoint>(
        _ element: (ConstantValue) -> P,
        _ round: (P) -> P,
        _ make: (P) -> ConstantValue
    ) -> ConstantResult {
        let u0 = element(lhs.elements[0])
        let u1 = element(lhs.elements[1])
        let u2 = element(lhs.elements[2])
        let v0 = element(rhs.elements[0])
        let v1 = element(rhs.elements[1])
        let v2 = element(rhs.elements[2])

        // Each product has to be representable in T on its own, so it is rounded back to T before
        // being subtracted: half arithmetic promotes to float, which would otherwise hide a product
        // that overflows f16 behind a difference that does not.
        func product(_ left: P, _ right: P) -> P? {
            let result = round(left * right) // lint-exempt(L-CE-7): floating-point arithmetic
            if !result.isFinite {
                return nil
            }
            return result
        }

        let products: [P?] = [
            product(u1, v2), product(u2, v1),
            product(u2, v0), product(u0, v2),
            product(u0, v1), product(u1, v0),
        ]
        var index = 0
        while index < products.count {
            if products[index] == nil {
                return .failure(ConstantFunctionError(message: "cross overflow"))
            }
            index &+= 1
        }
        guard let p0 = products[0], let p1 = products[1], let p2 = products[2], let p3 = products[3], let p4 = products[4],
            let p5 = products[5]
        else {
            wgslFatal("a cross product that was checked to be finite is missing", cppSite: "ConstantFunctions.h:1023")
        }

        var result = ConstantVector(size: 3)
        result.elements[0] = make(p0 - p1) // lint-exempt(L-CE-7): floating-point arithmetic
        result.elements[1] = make(p2 - p3) // lint-exempt(L-CE-7): floating-point arithmetic
        result.elements[2] = make(p4 - p5) // lint-exempt(L-CE-7): floating-point arithmetic
        return .success(.vector(result))
    }

    if case .float = lhs.elements[0] {
        return cross(
            { value in
                guard case .float(let f32) = value else {
                    wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:995")
                }
                return f32
            },
            { $0 },
            { .float($0) }
        )
    }
    if case .half = lhs.elements[0] {
        return cross(
            { value in
                guard case .half(let f16) = value else {
                    wgslFatal("std::get<half> of a constant that is not an f16", cppSite: "ConstantFunctions.h:995")
                }
                return Float(f16)
            },
            { Float(Half($0)) },
            { .half(Half($0)) }
        )
    }
    if case .double = lhs.elements[0] {
        return cross(
            { value in
                guard case .double(let abstractFloat) = value else {
                    wgslFatal("std::get<double> of a constant that is not an AbstractFloat", cppSite: "ConstantFunctions.h:995")
                }
                return abstractFloat
            },
            { $0 },
            { .double($0) }
        )
    }
    wgslFatal("cross of a vector that is not a float vector", cppSite: "ConstantFunctions.h:1035")
}

func constantDegrees(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    constantUnaryOperation(
        arguments,
        .float,
        f32: { arg in .success(.float(Float(Double(arg) * (180 / Double.pi)))) },
        f16: { arg in .success(.half(Half(Double(arg) * (180 / Double.pi)))) },
        abstractFloat: { arg in .success(.double(arg * (180 / Double.pi))) }
    )
}

func constantDeterminant(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    assert(arguments.count == 1)
    guard case .matrix(let matrix) = arguments[0] else {
        wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "ConstantFunctions.h:1044")
    }
    let columns = matrix.columns

    // `T` is computed in `P` (f16 in f32); `roundSolve3` rounds each `solve3` of `solve4` to `T`.
    func determinant<P: FloatingPoint>(_ element: (Int) -> P, roundSolve3: (P) -> P) -> P {
        switch columns {
        case 2:
            return Determinant.solve2(
                element(0),
                element(2),
                element(1),
                element(3)
            )

        case 3:
            return Determinant.solve3(
                element(0),
                element(3),
                element(6),
                element(1),
                element(4),
                element(7),
                element(2),
                element(5),
                element(8)
            )
        case 4:
            return Determinant.solve4(
                element(0),
                element(4),
                element(8),
                element(12),
                element(1),
                element(5),
                element(9),
                element(13),
                element(2),
                element(6),
                element(10),
                element(14),
                element(3),
                element(7),
                element(11),
                element(15),
                roundSolve3: roundSolve3
            )
        default: // lint-exempt(L-ENUM-1): columns is a UInt32
            wgslFatal("determinant of a matrix that is not square 2x2, 3x3 or 4x4", cppSite: "ConstantFunctions.h:1092")
        }
    }

    if case .float = matrix.elements[0] {
        return .success(
            .float(
                determinant(
                    { index in
                        guard case .float(let f32) = matrix.elements[index] else {
                            wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:1074")
                        }
                        return f32
                    },
                    roundSolve3: { $0 }
                )
            )
        )
    }
    if case .half = matrix.elements[0] {
        return .success(
            .half(
                Half(
                    determinant(
                        { index in
                            guard case .half(let f16) = matrix.elements[index] else {
                                wgslFatal("std::get<half> of a constant that is not an f16", cppSite: "ConstantFunctions.h:1074")
                            }
                            return Float(f16)
                        },
                        roundSolve3: { Float(Half($0)) }
                    )
                )
            )
        )
    }
    if case .double = matrix.elements[0] {
        return .success(
            .double(
                determinant(
                    { index in
                        guard case .double(let abstractFloat) = matrix.elements[index] else {
                            wgslFatal("std::get<double> of a constant that is not an AbstractFloat", cppSite: "ConstantFunctions.h:1074")
                        }
                        return abstractFloat
                    },
                    roundSolve3: { $0 }
                )
            )
        )
    }
    wgslFatal("determinant of a matrix that is not a float matrix", cppSite: "ConstantFunctions.h:1102")
}

func constantDistance(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    ConstantResult { () throws(ConstantFunctionError) in
        // we can't produce the type for the intermediate computation here. C++ passes nullptr so we crash if we ever
        // start depending on it; the scalar result type makes the matrix path trap the same way.
        let minus = try constantMinus(shaderModule, resultType, arguments).get()
        return try constantLength(shaderModule, resultType, [minus]).get()
    }
}

func constantDot(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    ConstantResult { () throws(ConstantFunctionError) in
        let product = try constantMultiply(shaderModule, resultType, arguments).get()
        var result = zeroValue(shaderModule, resultType)
        let elements = product.toVector().elements
        var index = 0
        while index < elements.count {
            result = try constantAdd(shaderModule, resultType, [result, elements[index]]).get()
            index &+= 1
        }
        return result
    }
}

func constantDot4U8Packed(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let lhsBits) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1127")
    }
    guard case .uint32(let rhsBits) = arguments[1] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1128")
    }
    let lhs = unsignedBytes(lhsBits)
    let rhs = unsignedBytes(rhsBits)
    let result: UInt32 = lhs[0] &* rhs[0] &+ lhs[1] &* rhs[1] &+ lhs[2] &* rhs[2] &+ lhs[3] &* rhs[3]
    return .success(.uint32(result))
}

func constantDot4I8Packed(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let lhsBits) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1136")
    }
    guard case .uint32(let rhsBits) = arguments[1] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1137")
    }
    let lhs = signedBytes(lhsBits)
    let rhs = signedBytes(rhsBits)
    let result: Int32 = lhs[0] &* rhs[0] &+ lhs[1] &* rhs[1] &+ lhs[2] &* rhs[2] &+ lhs[3] &* rhs[3]
    return .success(.int32(result))
}

func constantLength(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    assert(arguments.count == 1)
    let arg = arguments[0]
    if !arg.isVector {
        return constantAbs(shaderModule, resultType, arguments)
    }

    return ConstantResult { () throws(ConstantFunctionError) in
        var result = zeroValue(shaderModule, resultType)
        let elements = arg.toVector().elements
        var index = 0
        while index < elements.count {
            let element = elements[index]
            let tmp = try constantMultiply(shaderModule, resultType, [element, element]).get()
            result = try constantAdd(shaderModule, resultType, [result, tmp]).get()
            index &+= 1
        }
        return try constantSqrt(shaderModule, resultType, [result]).get()
    }
}

func constantExp(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.expf, LibM.exp)
}

func constantExp2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.exp2f, LibM.exp2)
}

// https://www.w3.org/TR/WGSL/#extractBits-builtin
// https://www.w3.org/TR/WGSL/#insertBits-builtin
// offset + count must be at most the bit width of the operand. The sum is taken in 64 bits so that
// two in-range u32 values cannot wrap past the limit.
func validateBitOffsetAndCount(_ offset: UInt64, _ count: UInt64) -> MessageText? {
    let bitWidth: UInt64 = 32
    if offset &+ count > bitWidth {
        return
            "the sum of offset (\(offset)) and count (\(count)) must be at most the bit width of the operand, which is \(bitWidth)"
    }
    return nil
}

func constantExtractBits(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    // We can't use a TERNARY_OPERATION here since the arguments might not all have the same type
    // i.e. we accept (u32, u32, u32) as well as (i32, u32, u32)
    assert(arguments.count == 3)
    guard case .uint32(let offset) = arguments[1] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1180")
    }
    guard case .uint32(let count) = arguments[2] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1181")
    }
    if let error = validateBitOffsetAndCount(UInt64(offset), UInt64(count)) {
        return .failure(ConstantFunctionError(message: error))
    }

    func extractBits<T: FixedWidthInteger>(_ e: T) -> T {
        let w: UInt32 = 32
        let o = cxxMin(offset, w)
        let c = cxxMin(count, w &- o)
        if c == 0 {
            return 0
        }
        if c == w {
            return e
        }
        let srcMask = ((UInt32(1) &<< c) &- 1) &<< o
        var result = T(truncatingIfNeeded: (UInt32(truncatingIfNeeded: e) & srcMask) &>> o)
        if T.isSigned {
            if result & (T(1) &<< (c &- 1)) != 0 {
                let dstMask = srcMask &>> o
                result |= T(truncatingIfNeeded: ~dstMask)
            }
        }
        return result
    }

    return scalarOrVector(arguments[0]) { e in
        if case .int32(let i32) = e {
            return .success(.int32(extractBits(i32)))
        }
        if case .uint32(let u32) = e {
            return .success(.uint32(extractBits(u32)))
        }
        wgslFatal("extractBits of a value that is not an i32 or a u32", cppSite: "ConstantFunctions.h:1209")
    }
}

func constantFaceForward(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    assert(arguments.count == 3)
    let e1 = arguments[0]
    let e2 = arguments[1]
    let e3 = arguments[2]

    guard case .vector(let vectorType) = shaderModule.types[resultType] else {
        wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:1220")
    }
    let elementType = vectorType.element
    return ConstantResult { () throws(ConstantFunctionError) in
        let dot = try constantDot(shaderModule, elementType, [e2, e3]).get()
        let lt = try constantLt(shaderModule, elementType, [dot, zeroValue(shaderModule, elementType)]).get()
        if lt.toBool() {
            return e1
        }
        return try constantMinus(shaderModule, resultType, [e1]).get()
    }
}

func constantFirstLeadingBit(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .concreteInteger,
        i32: { e in
            let ue = UInt32(bitPattern: e)
            if e == 0 || e == -1 {
                return .success(.int32(-1))
            }
            let count = e < 0 ? (~ue).leadingZeroBitCount : ue.leadingZeroBitCount
            return .success(.int32(Int32(truncatingIfNeeded: 31 &- count)))
        },
        u32: { e in
            if e == 0 {
                return .success(.uint32(UInt32.max))
            }
            return .success(.uint32(UInt32(truncatingIfNeeded: 31 &- e.leadingZeroBitCount)))
        }
    )
}

func constantFirstTrailingBit(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    func firstTrailingBit<T: FixedWidthInteger>(_ e: T) -> T {
        if e == 0 {
            return T(truncatingIfNeeded: -1)
        }
        let ue = UInt32(truncatingIfNeeded: e)
        return T(truncatingIfNeeded: ue.trailingZeroBitCount)
    }

    return constantUnaryOperation(
        arguments,
        .concreteInteger,
        i32: { e in .success(.int32(firstTrailingBit(e))) },
        u32: { e in .success(.uint32(firstTrailingBit(e))) }
    )
}

func constantFloor(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, { $0.rounded(.down) }, { $0.rounded(.down) })
}

func constantFma(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 3)
    return ConstantResult { () throws(ConstantFunctionError) in
        let product = try constantMultiply(shaderModule, resultType, [arguments[0], arguments[1]]).get()
        return try constantAdd(shaderModule, resultType, [product, arguments[2]]).get()
    }
}

func constantFract(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 1)
    let arg = arguments[0]
    return ConstantResult { () throws(ConstantFunctionError) in
        let floor = try constantFloor(shaderModule, resultType, [arg]).get()
        return try constantMinus(shaderModule, resultType, [arg, floor]).get()
    }
}

func constantFrexp(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 1)

    func frexpScalar(_ value: ConstantValue) -> (fract: ConstantValue, exp: ConstantValue) {
        if case .float(let f32) = value {
            let (fract, exp) = LibM.frexpf(f32)
            return (.float(fract), .int32(exp))
        }
        if case .half(let f16) = value {
            let (fract, exp) = LibM.frexpf(Float(f16))
            return (.half(Half(fract)), .int32(exp))
        }
        if case .double(let abstractFloat) = value {
            let (fract, exp) = LibM.frexp(abstractFloat)
            return (.double(fract), .int64(Int64(exp)))
        }
        wgslFatal("frexp of a value that is not a float", cppSite: "ConstantFunctions.h:1286")
    }

    let (fract, exp) = { () -> (ConstantValue, ConstantValue) in
        let arg = arguments[0]

        guard case .vector(let argVector) = arg else {
            return frexpScalar(arg)
        }

        let size = argVector.elements.count
        var fractVector = ConstantVector(size: size)
        var expVector = ConstantVector(size: size)
        var i = 0
        while i < size {
            let (fract, exp) = frexpScalar(argVector.elements[i])
            fractVector.elements[i] = fract
            expVector.elements[i] = exp
            i &+= 1
        }
        return (.vector(fractVector), .vector(expVector))
    }()

    return .success(.struct(ConstantStruct.frexpResult(fract: fract, exp: exp)))
}

func constantInsertBits(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let offsetArgument) = arguments[2] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1313")
    }
    guard case .uint32(let countArgument) = arguments[3] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1313")
    }
    if let error = validateBitOffsetAndCount(UInt64(offsetArgument), UInt64(countArgument)) {
        return .failure(ConstantFunctionError(message: error))
    }

    return scalarOrVector(arguments[0], arguments[1], arguments[2], arguments[3]) { eValue, newbitsValue, offset, count in
        guard case .uint32(let offsetValue) = offset else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1318")
        }
        guard case .uint32(let countValue) = count else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1319")
        }
        let w: UInt32 = 32
        let o = cxxMin(offsetValue, w)
        let c = cxxMin(countValue, w &- o)
        if c == 0 {
            return .success(eValue)
        }
        if c == w {
            return .success(newbitsValue)
        }

        func fn<T: FixedWidthInteger>(_ e: T, _ newbits: T) -> T {
            let from = newbits &<< o
            let mask = T(truncatingIfNeeded: ((UInt32(1) &<< c) &- 1) &<< o)
            var result = e
            result &= ~mask
            result |= (from & mask)
            return result
        }

        if case .int32(let e) = eValue {
            guard case .int32(let newbits) = newbitsValue else {
                wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:1335")
            }
            return .success(.int32(fn(e, newbits)))
        }
        guard case .uint32(let e) = eValue else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1336")
        }
        guard case .uint32(let newbits) = newbitsValue else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1336")
        }
        return .success(.uint32(fn(e, newbits)))
    }
}

func constantInverseSqrt(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .float,
        f32: { arg in .success(.float(Float(1.0 / Double(arg.squareRoot())))) },
        f16: { arg in .success(.half(Half(1.0 / Double(Float(arg).squareRoot())))) },
        abstractFloat: { arg in .success(.double(1.0 / arg.squareRoot())) }
    )
}

func constantLdexp(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    scalarOrVector(arguments[0], arguments[1]) { e1, e2 in
        if case .double(let abstractE1) = e1 {
            let bias: Int64 = 1023
            let e2Value: Int64
            if case .int64(let abstractE2) = e2 {
                e2Value = abstractE2
            } else {
                guard case .int32(let i32E2) = e2 else {
                    wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:1354")
                }
                e2Value = Int64(truncatingIfNeeded: i32E2)
            }
            if e2Value &+ bias <= 0 {
                return .success(.double(Double(0)))
            }
            if e2Value > bias &+ 1 {
                return .failure(ConstantFunctionError(message: "e2 must be less than or equal to \(bias &+ 1)"))
            }
            return .success(.double(LibM.ldexp(abstractE1, Int32(truncatingIfNeeded: e2Value))))
        }

        guard case .int32(let i32E2) = e2 else {
            wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:1362")
        }
        if case .float(let f32E1) = e1 {
            let bias: Int32 = 127
            if i32E2 &+ bias <= 0 {
                return .success(.float(Float(0)))
            }
            if i32E2 > bias &+ 1 {
                return .failure(ConstantFunctionError(message: "e2 must be less than or equal to \(bias &+ 1)"))
            }
            return .success(.float(LibM.ldexpf(f32E1, i32E2)))
        }
        if case .half(let f16E1) = e1 {
            let bias: Int32 = 15
            if i32E2 &+ bias <= 0 {
                return .success(.half(Half(Float(0))))
            }
            if i32E2 > bias &+ 1 {
                return .failure(ConstantFunctionError(message: "e2 must be less than or equal to \(bias &+ 1)"))
            }
            return .success(.half(Half(LibM.ldexpf(Float(f16E1), i32E2))))
        }
        wgslFatal("ldexp of a value that is not a float", cppSite: "ConstantFunctions.h:1379")
    }
}

func constantLog(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.logf, LibM.log)
}

func constantLog2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, LibM.log2f, LibM.log2)
}

func constantMax(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .number,
        i32: { arg, args in .success(.int32(cxxMax(arg, args))) },
        u32: { arg, args in .success(.uint32(cxxMax(arg, args))) },
        abstractInt: { arg, args in .success(.int64(cxxMax(arg, args))) },
        f32: { arg, args in .success(.float(cxxMax(arg, args))) },
        f16: { arg, args in .success(.half(cxxMax(arg, args))) },
        abstractFloat: { arg, args in .success(.double(cxxMax(arg, args))) }
    )
}

func constantMin(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .number,
        i32: { arg, args in .success(.int32(cxxMin(arg, args))) },
        u32: { arg, args in .success(.uint32(cxxMin(arg, args))) },
        abstractInt: { arg, args in .success(.int64(cxxMin(arg, args))) },
        f32: { arg, args in .success(.float(cxxMin(arg, args))) },
        f16: { arg, args in .success(.half(cxxMin(arg, args))) },
        abstractFloat: { arg, args in .success(.double(cxxMin(arg, args))) }
    )
}

func constantMix(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    // https://www.w3.org/TR/WGSL/#mix-builtin
    // Every step of e1 * (1 - e3) + e2 * e3 has to be representable in T, so the steps are taken
    // one at a time and rounded back to T: written as a single expression, half arithmetic
    // promotes to float and an intermediate that overflows f16 would go unnoticed.
    func mix<T: FixedWidthInteger>(_ e1: T, _ e2: T, _ e3: T) -> T {
        let oneMinusE3 = 1 &- e3
        let scaledE1 = e1 &* oneMinusE3
        let scaledE2 = e2 &* e3
        return scaledE1 &+ scaledE2
    }

    // `T` is computed in `P` (f16 in f32); `round` is `static_cast<T>` back to `P`'s precision.
    func mix<P: BinaryFloatingPoint>(_ e1: P, _ e2: P, _ e3: P, _ round: (P) -> P) -> P? {
        let oneMinusE3 = round(1 - e3) // lint-exempt(L-CE-7): floating-point arithmetic
        let scaledE1 = round(e1 * oneMinusE3) // lint-exempt(L-CE-7): floating-point arithmetic
        let scaledE2 = round(e2 * e3) // lint-exempt(L-CE-7): floating-point arithmetic
        let result = round(scaledE1 + scaledE2) // lint-exempt(L-CE-7): floating-point arithmetic
        if !oneMinusE3.isFinite || !scaledE1.isFinite || !scaledE2.isFinite || !result.isFinite {
            return nil
        }
        return result
    }

    return constantTernaryOperation(
        arguments,
        .number,
        i32: { e1, e2, e3 in .success(.int32(mix(e1, e2, e3))) },
        u32: { e1, e2, e3 in .success(.uint32(mix(e1, e2, e3))) },
        abstractInt: { e1, e2, e3 in .success(.int64(mix(e1, e2, e3))) },
        f32: { e1, e2, e3 in
            guard let result = mix(e1, e2, e3, { $0 }) else {
                return .failure(ConstantFunctionError(message: "mix overflow"))
            }
            return .success(.float(result))
        },
        f16: { e1, e2, e3 in
            guard let result = mix(Float(e1), Float(e2), Float(e3), { Float(Half($0)) }) else {
                return .failure(ConstantFunctionError(message: "mix overflow"))
            }
            return .success(.half(Half(result)))
        },
        abstractFloat: { e1, e2, e3 in
            guard let result = mix(e1, e2, e3, { $0 }) else {
                return .failure(ConstantFunctionError(message: "mix overflow"))
            }
            return .success(.double(result))
        }
    )
}

func constantModf(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 1)

    func modfScalar(_ value: ConstantValue) -> (fract: ConstantValue, whole: ConstantValue) {
        if case .float(let f32) = value {
            let (fract, whole) = LibM.modff(f32)
            return (.float(fract), .float(whole))
        }
        if case .half(let f16) = value {
            let (fract, whole) = LibM.modff(Float(f16))
            return (.half(Half(fract)), .half(Half(whole)))
        }
        if case .double(let abstractFloat) = value {
            let (fract, whole) = LibM.modf(abstractFloat)
            return (.double(fract), .double(whole))
        }
        wgslFatal("modf of a value that is not a float", cppSite: "ConstantFunctions.h:1426")
    }

    let (fract, whole) = { () -> (ConstantValue, ConstantValue) in
        let arg = arguments[0]

        guard case .vector(let argVector) = arg else {
            return modfScalar(arg)
        }

        let size = argVector.elements.count
        var fractVector = ConstantVector(size: size)
        var wholeVector = ConstantVector(size: size)
        var i = 0
        while i < size {
            let (fract, whole) = modfScalar(argVector.elements[i])
            fractVector.elements[i] = fract
            wholeVector.elements[i] = whole
            i &+= 1
        }
        return (.vector(fractVector), .vector(wholeVector))
    }()

    return .success(.struct(ConstantStruct.modfResult(fract: fract, whole: whole)))
}

func constantNormalize(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    assert(arguments.count == 1)
    guard case .vector(let vectorType) = shaderModule.types[resultType] else {
        wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:1453")
    }
    let elementType = vectorType.element
    let arg = arguments[0]
    return ConstantResult { () throws(ConstantFunctionError) in
        let length = try constantLength(shaderModule, elementType, arguments).get()
        return try constantDivide(shaderModule, resultType, [arg, length]).get()
    }
}

func constantPow(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .float,
        f32: { base, exp in
            if base < 0 {
                return .failure(ConstantFunctionError(message: "pow called with negative base (\(number: base))"))
            }
            if base == 0 && exp <= 0 {
                return .failure(ConstantFunctionError(message: "pow called with base 0 and non-positive exponent (\(number: exp))"))
            }
            let result = LibM.powf(base, exp)
            if !result.isFinite {
                return .failure(ConstantFunctionError(message: "pow overflow"))
            }
            return .success(.float(result))
        },
        f16: { base, exp in
            if Float(base) < 0 {
                return .failure(ConstantFunctionError(message: "pow called with negative base (\(number: base))"))
            }
            if Float(base) == 0 && Float(exp) <= 0 {
                return .failure(ConstantFunctionError(message: "pow called with base 0 and non-positive exponent (\(number: exp))"))
            }
            let result = LibM.powf(Float(base), Float(exp))
            if !result.isFinite {
                return .failure(ConstantFunctionError(message: "pow overflow"))
            }
            return .success(.half(Half(result)))
        },
        abstractFloat: { base, exp in
            if base < 0 {
                return .failure(ConstantFunctionError(message: "pow called with negative base (\(number: base))"))
            }
            if base == 0 && exp <= 0 {
                return .failure(ConstantFunctionError(message: "pow called with base 0 and non-positive exponent (\(number: exp))"))
            }
            let result = LibM.pow(base, exp)
            if !result.isFinite {
                return .failure(ConstantFunctionError(message: "pow overflow"))
            }
            return .success(.double(result))
        }
    )
}

func constantQuantizeToF16(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .f32,
        f32: { arg in
            guard let converted = convertFloat(Half.self, arg) else {
                return .failure(ConstantFunctionError(message: "value \(number: arg) cannot be represented as 'f16'"))
            }
            return .success(.float(Float(converted)))
        }
    )
}

func constantRadians(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    constantUnaryOperation(
        arguments,
        .float,
        f32: { arg in .success(.float(Float(Double(arg) * (Double.pi / Double(Float(180)))))) },
        f16: { arg in .success(.half(Half(Double(arg) * (Double.pi / Double(Half(Float(180))))))) },
        abstractFloat: { arg in .success(.double(arg * (Double.pi / Double(180)))) }
    )
}

func constantReflect(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    assert(arguments.count == 2)
    let e1 = arguments[0]
    let e2 = arguments[1]
    guard case .vector(let vectorType) = shaderModule.types[resultType] else {
        wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:1487")
    }
    let elementType = vectorType.element
    guard case .primitive(let primitive) = shaderModule.types[elementType] else {
        wgslFatal("std::get<Types::Primitive> of a type that is not primitive", cppSite: "ConstantFunctions.h:1488")
    }

    // `two` is `static_cast<T>(2)`.
    func reflect(_ two: ConstantValue) -> ConstantResult {
        ConstantResult { () throws(ConstantFunctionError) in
            let dot = try constantDot(shaderModule, elementType, [e2, e1]).get()
            let doubleResult = try constantMultiply(shaderModule, resultType, [two, dot]).get()
            let prod = try constantMultiply(shaderModule, resultType, [doubleResult, e2]).get()
            return try constantMinus(shaderModule, resultType, [e1, prod]).get()
        }
    }

    if primitive.kind == .f32 {
        return reflect(.float(Float(2)))
    }
    if primitive.kind == .f16 {
        return reflect(.half(Half(Float(2))))
    }
    if primitive.kind == .abstractFloat {
        return reflect(.double(Double(2)))
    }
    wgslFatal("reflect of a vector that is not a float vector", cppSite: "ConstantFunctions.h:1503")
}

func constantRefract(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    assert(arguments.count == 3)
    let e1 = arguments[0]
    let e2 = arguments[1]

    // `e3` is the `ConstantValue` of the `T` argument, `one` and `zero` are `static_cast<T>(1.0)` and
    // `static_cast<T>(0.0)`.
    func refract(_ e3: ConstantValue, _ one: ConstantValue, _ zero: ConstantValue) -> ConstantResult {
        ConstantResult { () throws(ConstantFunctionError) in
            guard case .vector(let vectorType) = shaderModule.types[resultType] else {
                wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:1514")
            }
            let elementType = vectorType.element
            let dot = try constantDot(shaderModule, elementType, [e2, e1]).get()
            let dotSquared = try constantMultiply(shaderModule, elementType, [dot, dot]).get()
            let sub = try constantMinus(shaderModule, elementType, [one, dotSquared]).get()
            let e3Squared = try constantMultiply(shaderModule, elementType, [e3, e3]).get()
            let mul = try constantMultiply(shaderModule, elementType, [e3Squared, sub]).get()
            let k = try constantMinus(shaderModule, elementType, [one, mul]).get()
            let lt = try constantLt(shaderModule, elementType, [k, zero]).get()

            if lt.toBool() {
                return zeroValue(shaderModule, resultType)
            }

            do {
                let mul = try constantMultiply(shaderModule, elementType, [e3, dot]).get()
                let sqrt = try constantSqrt(shaderModule, elementType, [k]).get()
                let sum = try constantAdd(shaderModule, elementType, [mul, sqrt]).get()
                let mul2 = try constantMultiply(shaderModule, resultType, [e3, e1]).get()
                let mul3 = try constantMultiply(shaderModule, resultType, [sum, e2]).get()
                return try constantMinus(shaderModule, resultType, [mul2, mul3]).get()
            }
        }
    }

    if case .float(let f32) = arguments[2] {
        return refract(.float(f32), .float(Float(1.0)), .float(Float(0.0)))
    }
    if case .half(let f16) = arguments[2] {
        return refract(.half(f16), .half(Half(Double(1.0))), .half(Half(Double(0.0))))
    }
    if case .double(let abstractFloat) = arguments[2] {
        return refract(.double(abstractFloat), .double(1.0), .double(0.0))
    }
    wgslFatal("refract of a value that is not a float", cppSite: "ConstantFunctions.h:1542")
}

func constantReverseBits(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    func reverseBits<T: FixedWidthInteger>(_ e: T) -> T {
        let v = UInt32(truncatingIfNeeded: e)
        var result: T = 0
        var k: UInt32 = 0
        while k < 32 {
            let bit: Int32 = (v & (UInt32(1) &<< (31 &- k))) != 0 ? 1 : 0
            // `!!(…) << k` is an `int`: bit 31 sign-extends into a wider `T`.
            result |= T(truncatingIfNeeded: bit &<< k)
            k &+= 1
        }
        return result
    }

    return constantUnaryOperation(
        arguments,
        .integer,
        i32: { e in .success(.int32(reverseBits(e))) },
        u32: { e in .success(.uint32(reverseBits(e))) },
        abstractInt: { e in .success(.int64(reverseBits(e))) }
    )
}

func constantRound(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, { $0.rounded(.toNearestOrEven) }, { $0.rounded(.toNearestOrEven) })
}

func constantSaturate(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .float,
        f32: { e in .success(.float(cxxMin(cxxMax(e, Float(0)), Float(1)))) },
        f16: { e in .success(.half(cxxMin(cxxMax(e, Half(Float(0))), Half(Float(1))))) },
        abstractFloat: { e in .success(.double(cxxMin(cxxMax(e, Double(0)), Double(1)))) }
    )
}

func constantSign(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    func sign<T: Comparable & SignedNumeric>(_ e: T) -> T {
        let result: T
        if e > 0 {
            result = 1
        } else if e < 0 {
            result = -1
        } else {
            result = 0
        }
        return result
    }

    return constantUnaryOperation(
        arguments,
        .number,
        i32: { e in .success(.int32(sign(e))) },
        u32: { e in .success(.uint32(e > 0 ? 1 : 0)) },
        abstractInt: { e in .success(.int64(sign(e))) },
        f32: { e in .success(.float(sign(e))) },
        f16: { e in .success(.half(Half(sign(Float(e))))) },
        abstractFloat: { e in .success(.double(sign(e))) }
    )
}

func constantSmoothstep(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    // `e` and `t` have the promoted type `P` (f32 for f16); the result is a double.
    func smoothstep<P: BinaryFloatingPoint>(_ low: P, _ high: P, _ x: P, _ widened: (P) -> Double) -> Double {
        let e = (x - low) / (high - low) // lint-exempt(L-CE-7): floating-point arithmetic
        let t = cxxMin(cxxMax(e, P(0)), P(1))
        return widened(t * t) * smoothstepThreeMinusTwoT(widened(t)) // lint-exempt(L-CE-7): floating-point arithmetic
    }

    return constantTernaryOperation(
        arguments,
        .float,
        f32: { low, high, x in
            if low == high {
                return .failure(
                    ConstantFunctionError(message: "smoothstep called with low (\(number: low)) equal high (\(number: high))")
                )
            }
            return .success(.double(smoothstep(low, high, x) { Double($0) }))
        },
        f16: { low, high, x in
            if Float(low) == Float(high) {
                return .failure(
                    ConstantFunctionError(message: "smoothstep called with low (\(number: low)) equal high (\(number: high))")
                )
            }
            return .success(.double(smoothstep(Float(low), Float(high), Float(x)) { Double($0) }))
        },
        abstractFloat: { low, high, x in
            if low == high {
                return .failure(
                    ConstantFunctionError(message: "smoothstep called with low (\(number: low)) equal high (\(number: high))")
                )
            }
            return .success(.double(smoothstep(low, high, x) { $0 }))
        }
    )
}

func constantSqrt(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, { $0.squareRoot() }, { $0.squareRoot() })
}

func constantStep(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .float,
        f32: { edge, x in .success(.double(edge <= x ? 1.0 : 0.0)) },
        f16: { edge, x in .success(.double(Float(edge) <= Float(x) ? 1.0 : 0.0)) },
        abstractFloat: { edge, x in .success(.double(edge <= x ? 1.0 : 0.0)) }
    )
}

func constantTranspose(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    assert(arguments.count == 1)
    guard case .matrix(let matrix) = arguments[0] else {
        wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "ConstantFunctions.h:1585")
    }
    let columns = matrix.columns
    let rows = matrix.rows
    var result = ConstantMatrix(columns: rows, rows: columns)
    var j: UInt32 = 0
    while j < rows {
        var i: UInt32 = 0
        while i < columns {
            result.elements[Int(j &* columns &+ i)] = matrix.elements[Int(i &* rows &+ j)]
            i &+= 1
        }
        j &+= 1
    }
    return .success(.matrix(result))
}

func constantTrunc(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperationWrapStd(arguments, { $0.rounded(.towardZero) }, { $0.rounded(.towardZero) })
}

// MARK: - Swift-only

/// C++ `UNARY_OPERATION(name, Float, WRAP_STD(fn))` (`CONSTANT_TRIGONOMETRIC`): `std::fn` returns `T`, so f16 runs the f32
/// function on the promoted value and rounds the result back to f16.
private func constantUnaryOperationWrapStd(
    _ arguments: borrowing [ConstantValue],
    _ fnF32: (Float) -> Float,
    _ fnAbstractFloat: (Double) -> Double
) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .float,
        f32: { arg in .success(.float(fnF32(arg))) },
        f16: { arg in .success(.half(Half(fnF32(Float(arg))))) },
        abstractFloat: { arg in .success(.double(fnAbstractFloat(arg))) }
    )
}

/// `std::bit_cast<std::array<uint8_t, 4>>(value)`, each byte widened as the `int` promotion does.
private func unsignedBytes(_ value: UInt32) -> [UInt32] {
    [value & 0xFF, (value &>> 8) & 0xFF, (value &>> 16) & 0xFF, (value &>> 24) & 0xFF]
}

/// `std::bit_cast<std::array<int8_t, 4>>(value)`, each byte sign-extended as the `int` promotion does.
private func signedBytes(_ value: UInt32) -> [Int32] {
    [
        Int32(Int8(truncatingIfNeeded: value)),
        Int32(Int8(truncatingIfNeeded: value &>> 8)),
        Int32(Int8(truncatingIfNeeded: value &>> 16)),
        Int32(Int8(truncatingIfNeeded: value &>> 24)),
    ]
}

/// `3.0 - 2.0 * t` of `constantSmoothstep`.
// DEV-11: clang contracts it on arm64 (equal to the unfused value, since 2.0 * t is exact), not on x86_64.
private func smoothstepThreeMinusTwoT(_ t: Double) -> Double {
    #if arch(arm64)
    3.0.addingProduct(-2.0, t)
    #else
    3.0 - 2.0 * t
    #endif
}
