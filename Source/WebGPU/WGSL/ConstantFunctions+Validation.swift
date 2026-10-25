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

func validateClamp(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if let low = arguments[1], let high = arguments[2] {
        do throws(ConstantFunctionError) {
            let gt = try constantGt(shaderModule, shaderModule.types.voidType, [low, high]).get()
            let any = try constantAny(shaderModule, shaderModule.types.voidType, [gt]).get()
            if any.toBool() {
                return "clamp called with low (\(shaderModule.dump(low))) greater than high (\(shaderModule.dump(high)))"
            }
        } catch {
            return error.message
        }
    }

    return nil
}

func containsInfinity(_ value: ConstantValue) -> Bool {
    if case .float(let f) = value {
        return f.isInfinite
    }
    if case .half(let h) = value {
        return Float(h).isInfinite
    }
    if case .double(let d) = value {
        return d.isInfinite
    }
    if case .vector(let v) = value {
        for element in v.elements where containsInfinity(element) {
            return true
        }
    }
    return false
}

func validateAdd(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if let left = arguments[0], let right = arguments[1], !left.isMatrix {
        do throws(ConstantFunctionError) {
            let result = try constantBinaryOperation(
                [left, right],
                .number,
                i32: { left, right in .success(.int32(left &+ right)) },
                u32: { left, right in .success(.uint32(left &+ right)) },
                abstractInt: { left, right in .success(.int64(left &+ right)) },
                f32: { (left: Float, right: Float) in .success(.float(left + right)) },
                f16: { left, right in .success(.half(Half(Float(left) + Float(right)))) },
                abstractFloat: { (left: Double, right: Double) in .success(.double(left + right)) }
            )
            .get()
            if containsInfinity(result) {
                return "addition of (\(shaderModule.dump(left))) and (\(shaderModule.dump(right))) overflows"
            }
        } catch {
            return error.message
        }
    }
    return nil
}

func validateMinus(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if arguments.count == 2, let left = arguments[0], let right = arguments[1], !left.isMatrix {
        do throws(ConstantFunctionError) {
            let result = try constantBinaryOperation(
                [left, right],
                .number,
                i32: { left, right in .success(.int32(left &- right)) },
                u32: { left, right in .success(.uint32(left &- right)) },
                abstractInt: { left, right in .success(.int64(left &- right)) },
                f32: { (left: Float, right: Float) in .success(.float(left - right)) },
                f16: { left, right in .success(.half(Half(Float(left) - Float(right)))) },
                abstractFloat: { (left: Double, right: Double) in .success(.double(left - right)) }
            )
            .get()
            if containsInfinity(result) {
                return "subtraction of (\(shaderModule.dump(left))) and (\(shaderModule.dump(right))) overflows"
            }
        } catch {
            return error.message
        }
    }
    return nil
}

func validateMultiply(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if let left = arguments[0], let right = arguments[1], !left.isMatrix, !right.isMatrix {
        do throws(ConstantFunctionError) {
            let result = try constantBinaryOperation(
                [left, right],
                .number,
                i32: { left, right in .success(.int32(left &* right)) },
                u32: { left, right in .success(.uint32(left &* right)) },
                abstractInt: { left, right in .success(.int64(left &* right)) },
                f32: { (left: Float, right: Float) in .success(.float(left * right)) },
                f16: { left, right in .success(.half(Half(Float(left) * Float(right)))) },
                abstractFloat: { (left: Double, right: Double) in .success(.double(left * right)) }
            )
            .get()
            if containsInfinity(result) {
                return "multiplication of (\(shaderModule.dump(left))) and (\(shaderModule.dump(right))) overflows"
            }
        } catch {
            return error.message
        }
    }
    return nil
}

func validateSmoothstep(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if let low = arguments[0], let high = arguments[1] {
        do throws(ConstantFunctionError) {
            let equal = try constantEqual(shaderModule, shaderModule.types.voidType, [low, high]).get()
            let any = try constantAny(shaderModule, shaderModule.types.voidType, [equal]).get()
            if any.toBool() {
                return "smoothstep called with low (\(shaderModule.dump(low))) equal high (\(shaderModule.dump(high)))"
            }
        } catch {
            return error.message
        }
    }

    return nil
}

func validateDivide(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if let left = arguments[0], let right = arguments[1] {
        let result = constantDivide(shaderModule, shaderModule.types.voidType, [left, right])
        if case .failure(let error) = result {
            return error.message
        }
    } else if let right = arguments[1] {
        // right / right only errors for integer zero, which is exactly
        // the case where division is invalid regardless of the dividend.
        let result = constantDivide(shaderModule, shaderModule.types.voidType, [right, right])
        if case .failure(let error) = result {
            return error.message
        }
    }

    return nil
}

func validateModulo(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if let left = arguments[0], let right = arguments[1] {
        let result = constantModulo(shaderModule, shaderModule.types.voidType, [left, right])
        if case .failure(let error) = result {
            return error.message
        }
    } else if let right = arguments[1] {
        let result = constantModulo(shaderModule, shaderModule.types.voidType, [right, right])
        if case .failure(let error) = result {
            return error.message
        }
    }

    return nil
}

func ldexpBiasForType(_ shaderModule: borrowing ShaderModule, _ type: TypeID) -> Int32 {
    var type = type
    if let vectorType = shaderModule.types.getIf(Types.Vector.self, type) {
        type = vectorType.element
    }
    if let primitive = shaderModule.types.getIf(Types.Primitive.self, type) {
        switch primitive.kind {
        case .f16:
            return 15
        case .f32:
            return 127
        case .abstractFloat, .abstractInt:
            return 1023
        case .i32, .u32, .void, .bool, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
            break
        }
    }
    wgslFatal("ldexpBiasForType of a type that is not a float", cppSite: "ConstantFunctions.h:2067")
}

func validateLdexp(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    guard let e2 = arguments[1] else {
        return nil
    }

    let bias = ldexpBiasForType(shaderModule, types[0])
    let maxExponent = bias &+ 1

    func checkScalar(_ value: ConstantValue) -> Bool {
        if case .int32(let i32) = value {
            return i32 > maxExponent
        }
        if case .int64(let abstractInt) = value {
            return abstractInt > Int64(maxExponent)
        }
        return false
    }

    if case .vector(let vec) = e2 {
        for element in vec.elements where checkScalar(element) {
            return "e2 must be less than or equal to \(maxExponent)"
        }
        return nil
    }
    if checkScalar(e2) {
        return "e2 must be less than or equal to \(maxExponent)"
    }
    return nil
}

func shiftAmountExceedsBitWidth(_ lhs: ConstantValue?, _ rhs: ConstantValue?) -> Bool {
    guard let rhs else {
        return false
    }

    var bitWidth: UInt32 = 32
    if let lhsValue = lhs {
        if case .vector(let vec) = lhsValue {
            if case .int64 = vec.elements[0] {
                bitWidth = 64
            }
        } else if case .int64 = lhsValue {
            bitWidth = 64
        }
    }

    func checkScalarExceedsBitWidth(_ value: ConstantValue) -> Bool {
        if case .uint32(let u) = value {
            return u >= bitWidth
        }
        return false
    }

    if case .vector(let vec) = rhs {
        for element in vec.elements where checkScalarExceedsBitWidth(element) {
            return true
        }
        return false
    }
    return checkScalarExceedsBitWidth(rhs)
}

func validateBitwiseShiftLeft(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if shiftAmountExceedsBitWidth(arguments[0], arguments[1]) {
        return "shift left value must be less than the bit width of the shifted value, which is 32"
    }
    return nil
}

func validateBitwiseShiftRight(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if shiftAmountExceedsBitWidth(arguments[0], arguments[1]) {
        return "shift right value must be less than the bit width of the shifted value, which is 32"
    }
    return nil
}

// Only checked when both the offset and the count are known: as const-expressions that is a
// shader-creation error handled by constantExtractBits/constantInsertBits, and as
// override-expressions the same call is validated again with the override values substituted in at
// pipeline creation.
func validateBitOffsetAndCount(_ offset: ConstantValue?, _ count: ConstantValue?) -> MessageText? {
    guard let offset, let count else {
        return nil
    }
    return validateBitOffsetAndCount(UInt64(bitPattern: offset.integerValue()), UInt64(bitPattern: count.integerValue()))
}

func validateExtractBits(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    validateBitOffsetAndCount(arguments[1], arguments[2])
}

func validateInsertBits(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    validateBitOffsetAndCount(arguments[2], arguments[3])
}

// https://www.w3.org/TR/WGSL/#workgroupUniformLoad-builtin
// The pointee has to be a concrete plain type with a fixed footprint and no atomics in it, which is
// exactly what constructible means. A pointer straight at an atomic is the other overload of this
// builtin, and is allowed.
func validateWorkgroupUniformLoad(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    guard let pointer = shaderModule.types.getIf(Types.Pointer.self, types[0]) else {
        return nil
    }

    let element = pointer.element
    if shaderModule.types.getIf(Types.Atomic.self, element) != nil || shaderModule.isConstructible(element) {
        return nil
    }

    return "the type of the argument to 'workgroupUniformLoad' must be constructible, but '\(shaderModule.typeString(element))' is not"
}

// https://www.w3.org/TR/WGSL/#subgroupShuffle-builtin
// For subgroupShuffle{,Up,Down,Xor}, if the id/delta/mask argument is a const-expression
// outside the range [0, 128) it is a shader-creation error. Non-const arguments are not
// checked here (an out-of-range override is a pipeline-creation error handled separately).
func validateSubgroupShuffle(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    if arguments.count == 2, let argument = arguments[1] {
        let id = argument.integerValue()
        if id < 0 || id >= 128 {
            return "the id argument of a subgroup shuffle must be in the range [0, 128), but was \(id)"
        }
    }
    return nil
}

// https://www.w3.org/TR/WGSL/#subgroupBroadcast-builtin
// subgroupBroadcast requires its id argument to be a const-expression in the range [0, 128).
func validateSubgroupBroadcast(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    guard arguments.count == 2, let argument = arguments[1] else {
        return "the id argument of subgroupBroadcast must be a const-expression"
    }
    let id = argument.integerValue()
    if id < 0 || id >= 128 {
        return "the id argument of subgroupBroadcast must be in the range [0, 128), but was \(id)"
    }
    return nil
}

// https://www.w3.org/TR/WGSL/#quadBroadcast-builtin
// quadBroadcast requires its id argument to be a const-expression in the range [0, 4).
func validateQuadBroadcast(
    _ shaderModule: borrowing ShaderModule,
    _ arguments: borrowing [ConstantValue?],
    _ types: borrowing [TypeID]
) -> MessageText? {
    guard arguments.count == 2, let argument = arguments[1] else {
        return "the id argument of quadBroadcast must be a const-expression"
    }
    let id = argument.integerValue()
    if id < 0 || id >= 4 {
        return "the id argument of quadBroadcast must be in the range [0, 4), but was \(id)"
    }
    return nil
}
