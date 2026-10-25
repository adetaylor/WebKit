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

// Data Packing
func constantPack4x8snorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1602")
    }
    var packed = [Int8](repeating: 0, count: 4)
    for i in 0..<4 {
        guard case .float(let e) = vector.elements[i] else {
            wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:1605")
        }
        packed[i] = Int8(truncatingIfNeeded: arm64ConvertToInt32((0.5 + Double(127 * cxxMin(1, cxxMax(-1, e)))).rounded(.down)))
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack4x8unorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1614")
    }
    var packed = [UInt8](repeating: 0, count: 4)
    for i in 0..<4 {
        guard case .float(let e) = vector.elements[i] else {
            wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:1617")
        }
        packed[i] = UInt8(truncatingIfNeeded: arm64ConvertToUInt32((0.5 + Double(255 * cxxMin(1, cxxMax(0, e)))).rounded(.down)))
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack4xI8(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1626")
    }
    var packed = [UInt8](repeating: 0, count: 4)
    for i in 0..<4 {
        guard case .int32(let e) = vector.elements[i] else {
            wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:1629")
        }
        packed[i] = UInt8(truncatingIfNeeded: e)
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack4xU8(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1638")
    }
    var packed = [UInt8](repeating: 0, count: 4)
    for i in 0..<4 {
        guard case .uint32(let e) = vector.elements[i] else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1641")
        }
        packed[i] = UInt8(truncatingIfNeeded: e)
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack4xI8Clamp(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1650")
    }
    var packed = [UInt8](repeating: 0, count: 4)
    for i in 0..<4 {
        guard case .int32(let e) = vector.elements[i] else {
            wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:1653")
        }
        packed[i] = UInt8(truncatingIfNeeded: cxxMin(127, cxxMax(-128, e)))
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack4xU8Clamp(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1662")
    }
    var packed = [UInt8](repeating: 0, count: 4)
    for i in 0..<4 {
        guard case .uint32(let e) = vector.elements[i] else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1665")
        }
        packed[i] = UInt8(truncatingIfNeeded: cxxMin(255, e))
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack2x16snorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1674")
    }
    var packed = [Int16](repeating: 0, count: 2)
    for i in 0..<2 {
        guard case .float(let e) = vector.elements[i] else {
            wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:1677")
        }
        packed[i] = Int16(truncatingIfNeeded: arm64ConvertToInt32((0.5 + Double(32_767 * cxxMin(1, cxxMax(-1, e)))).rounded(.down)))
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack2x16unorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1686")
    }
    var packed = [UInt16](repeating: 0, count: 2)
    for i in 0..<2 {
        guard case .float(let e) = vector.elements[i] else {
            wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:1689")
        }
        packed[i] = UInt16(truncatingIfNeeded: arm64ConvertToUInt32((0.5 + Double(65_535 * cxxMin(1, cxxMax(0, e)))).rounded(.down)))
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

func constantPack2x16float(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .vector(let vector) = arguments[0] else {
        wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantFunctions.h:1698")
    }
    var packed = [Half](repeating: Half(bitPattern: 0), count: 2)
    for i in 0..<2 {
        guard case .float(let e) = vector.elements[i] else {
            wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:1701")
        }
        guard let converted = convertFloat(Half.self, e) else {
            return .failure(ConstantFunctionError(message: "value \(number: e) cannot be represented as 'f16'"))
        }
        packed[i] = converted
    }
    return .success(.uint32(bitCastToUInt32(packed)))
}

// Data Unpacking
func constantUnpack4x8snorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1714")
    }
    let packed = bitCastToArray(argument, of: Int8.self)
    var result = ConstantVector(size: 4)
    for i in 0..<4 {
        let e = Float(packed[i])
        result.elements[i] = .float(cxxMax(e / 127, -1))
    }
    return .success(.vector(result))
}

func constantUnpack4x8unorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1727")
    }
    let packed = bitCastToArray(argument, of: UInt8.self)
    var result = ConstantVector(size: 4)
    for i in 0..<4 {
        let e = Float(packed[i])
        result.elements[i] = .float(e / 255)
    }
    return .success(.vector(result))
}

func constantUnpack4xI8(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1740")
    }
    let packed = bitCastToArray(argument, of: Int8.self)
    var result = ConstantVector(size: 4)
    for i in 0..<4 {
        result.elements[i] = .int32(Int32(packed[i]))
    }
    return .success(.vector(result))
}

func constantUnpack4xU8(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1751")
    }
    let packed = bitCastToArray(argument, of: UInt8.self)
    var result = ConstantVector(size: 4)
    for i in 0..<4 {
        result.elements[i] = .uint32(UInt32(packed[i]))
    }
    return .success(.vector(result))
}

func constantUnpack2x16snorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1762")
    }
    let packed = bitCastToArray(argument, of: Int16.self)
    var result = ConstantVector(size: 2)
    for i in 0..<2 {
        let e = Float(packed[i])
        result.elements[i] = .float(cxxMax(e / 32_767, -1))
    }
    return .success(.vector(result))
}

func constantUnpack2x16unorm(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1775")
    }
    let packed = bitCastToArray(argument, of: UInt16.self)
    var result = ConstantVector(size: 2)
    for i in 0..<2 {
        let e = Float(packed[i])
        result.elements[i] = .float(e / 65_535)
    }
    return .success(.vector(result))
}

func constantUnpack2x16float(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    guard case .uint32(let argument) = arguments[0] else {
        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:1788")
    }
    let packed = bitCastToHalfArray(argument)
    var result = ConstantVector(size: 2)
    for i in 0..<2 {
        result.elements[i] = .float(Float(packed[i]))
    }
    return .success(.vector(result))
}

func constantBitcast(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    func split(_ result: inout ConstantVector, _ argument: ConstantValue, _ offset: Int) -> MessageText? {
        let value: UInt32
        if case .int32(let i32) = argument {
            value = UInt32(bitPattern: i32)
        } else if case .uint32(let u32) = argument {
            value = u32
        } else if case .float(let f32) = argument {
            value = f32.bitPattern
        } else if case .int64(let abstractInt) = argument {
            guard let i32 = convertInteger(Int32.self, abstractInt) else {
                return "value \(abstractInt) cannot be represented as 'i32'"
            }
            value = UInt32(bitPattern: i32)
        } else if case .double(let abstractFloat) = argument {
            guard let f32 = convertFloat(Float.self, abstractFloat) else {
                return "value \(number: abstractFloat) cannot be represented as 'f32'"
            }
            value = f32.bitPattern
        } else {
            wgslFatal("bitcast of a constant that is not a 32-bit scalar", cppSite: "ConstantFunctions.h:1817")
        }

        let parts = bitCastToHalfArray(value)
        result.elements[offset] = .half(parts[0])
        result.elements[offset &+ 1] = .half(parts[1])
        return nil
    }

    func join(_ type: TypeID, _ vector: ConstantVector, _ offset: Int) -> ConstantValue {
        guard case .half(let low) = vector.elements[offset], case .half(let high) = vector.elements[offset &+ 1] else {
            wgslFatal("std::get<half> of a constant that is not an f16", cppSite: "ConstantFunctions.h:1829")
        }
        var value: UInt32 = 0
        value |= UInt32(low.bitPattern)
        value |= UInt32(high.bitPattern) &<< 16
        return convertValue(shaderModule, type, .uint32(value), .bitwiseCast)
    }

    func vectorVector(_ dst: Types.Vector, _ src: ConstantVector) -> ConstantResult {
        if Int(dst.size) == src.elements.count {
            return scalarOrVector(.vector(src)) { value in
                constantBitcast(shaderModule, dst.element, [value])
            }
        }

        var result = ConstantVector(size: Int(dst.size))
        if dst.size == 4 {
            if let error = split(&result, src.elements[0], 0) {
                return .failure(ConstantFunctionError(message: error))
            }
            if let error = split(&result, src.elements[1], 2) {
                return .failure(ConstantFunctionError(message: error))
            }
        } else {
            result.elements[0] = join(dst.element, src, 0)
            result.elements[1] = join(dst.element, src, 2)
        }
        return .success(.vector(result))
    }

    let argument = arguments[0]
    if let dstVector = shaderModule.types.getIf(Types.Vector.self, resultType) {
        if case .vector(let srcVector) = argument {
            return vectorVector(dstVector, srcVector)
        }

        guard dstVector.size == 2 else {
            wgslFatal("bitcast of a scalar to a vector that is not a vec2", cppSite: "ConstantFunctions.h:1859")
        }
        var result = ConstantVector(size: 2)
        _ = split(&result, argument, 0)
        return .success(.vector(result))
    }

    if case .vector(let srcVector) = argument {
        return .success(join(resultType, srcVector, 0))
    }

    if case .int64(let abstractInt) = argument {
        guard let primitive = shaderModule.types.getIf(Types.Primitive.self, resultType) else {
            wgslFatal("std::get<Types::Primitive> of a type that is not primitive", cppSite: "ConstantFunctions.h:1869")
        }

        if primitive.kind == .u32 {
            guard let result = convertInteger(UInt32.self, abstractInt) else {
                return .failure(ConstantFunctionError(message: "value \(abstractInt) cannot be represented as 'u32'"))
            }
            return .success(.uint32(result))
        }

        guard let result = convertInteger(Int32.self, abstractInt) else {
            return .failure(ConstantFunctionError(message: "value \(abstractInt) cannot be represented as 'i32'"))
        }
        return .success(convertValue(shaderModule, resultType, .int32(result), .bitwiseCast))
    }

    if case .double(let abstractFloat) = argument {
        guard let result = convertFloat(Float.self, abstractFloat) else {
            return .failure(ConstantFunctionError(message: "value \(number: abstractFloat) cannot be represented as 'f32'"))
        }
        return .success(convertValue(shaderModule, resultType, .float(result), .bitwiseCast))
    }

    return .success(convertValue(shaderModule, resultType, argument, .bitwiseCast))
}

// Type checker helpers

func containsZero(_ shaderModule: borrowing ShaderModule, _ value: ConstantValue, _ valueType: TypeID) -> Bool {
    let wrapped = Result { () throws(ConstantFunctionError) -> Bool in
        let zero = zeroValue(shaderModule, valueType)
        let equal = try constantEqual(shaderModule, shaderModule.types.voidType, [value, zero]).get()
        let any = try constantAny(shaderModule, shaderModule.types.voidType, [equal]).get()
        return any.toBool()
    }

    guard case .success(let result) = wrapped else {
        return false
    }
    return result
}

// MARK: - Swift-only

/// `std::bit_cast<uint32_t>(packed)` of a `std::array` of 8- or 16-bit integers: element 0 is the low bits.
private func bitCastToUInt32<T: FixedWidthInteger>(_ packed: [T]) -> UInt32 {
    var result: UInt32 = 0
    for i in 0..<packed.count {
        result |= UInt32(truncatingIfNeeded: T.Magnitude(truncatingIfNeeded: packed[i])) &<< (i &* T.bitWidth)
    }
    return result
}

/// `std::bit_cast<uint32_t>(packed)` of a `std::array<half, 2>`.
private func bitCastToUInt32(_ packed: [Half]) -> UInt32 {
    bitCastToUInt32(packed.map(\.bitPattern))
}

/// `std::bit_cast<std::array<T, 32 / T::bitWidth>>(value)`.
private func bitCastToArray<T: FixedWidthInteger>(_ value: UInt32, of _: T.Type) -> [T] {
    var result: [T] = []
    result.reserveCapacity(32 / T.bitWidth)
    for i in 0..<(32 / T.bitWidth) {
        result.append(T(truncatingIfNeeded: value &>> (i &* T.bitWidth)))
    }
    return result
}

/// `std::bit_cast<std::array<half, 2>>(value)`.
private func bitCastToHalfArray(_ value: UInt32) -> [Half] {
    bitCastToArray(value, of: UInt16.self).map { Half(bitPattern: $0) }
}
