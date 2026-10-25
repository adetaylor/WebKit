// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
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

// Zero values

/// C++ `std::expected<ConstantValue, String>`.
///
/// A constant function is `func constantX(_ shaderModule:, _ resultType:, _ arguments:) -> ConstantResult` (C++
/// `CONSTANT_FUNCTION(X)`). `CALL(x, F, …)` and `CALL_MOVE(x, F, …)` become `x = try constantF(shaderModule, …).get()`
/// inside a `ConstantResult { () throws(ConstantFunctionError) in … }` body.
@_spi(Testing)
public typealias ConstantResult = Result<ConstantValue, ConstantFunctionError>

/// The `String` error of a C++ `ConstantResult`.
@_spi(Testing)
public struct ConstantFunctionError: Error, Equatable {
    @_spi(Testing)
    public let message: MessageText
}

/// C++ `zeroValue(type)`.
@_spi(Testing)
public func zeroValue(_ shaderModule: borrowing ShaderModule, _ type: TypeID) -> ConstantValue {
    let operands = zeroValueOperands(shaderModule, type)
    var zeroValues = LookupMap<TypeID, ConstantValue>()
    var index = 0
    while index < operands.count {
        _ = zeroValues.add(operands[index], zeroValue(shaderModule, operands[index], zeroValues))
        index &+= 1
    }
    return zeroValue(shaderModule, type, zeroValues)
}

/// The body of C++ `zeroValue(type)`: the zero values of the array and struct types that `type` contains come from
/// `zeroValues`, so the type recursion is iterative (`zeroValueOperands`).
private func zeroValue(
    _ shaderModule: borrowing ShaderModule,
    _ type: TypeID,
    _ zeroValues: borrowing LookupMap<TypeID, ConstantValue>
) -> ConstantValue {
    switch shaderModule.types[type] {
    case .primitive(let primitive):
        switch primitive.kind {
        case .abstractInt:
            return .int64(0)
        case .i32:
            return .int32(0)
        case .u32:
            return .uint32(0)
        case .abstractFloat:
            return .double(0.0)
        case .f32:
            return .float(0.0)
        case .f16:
            return .half(Half(Double(0.0)))
        case .bool:
            return .bool(false)
        case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
            wgslFatal("zeroValue of a primitive type that has no values", cppSite: "ConstantFunctions.h:94")
        }
    case .vector(let vector):
        var result = ConstantVector(size: Int(vector.size))
        let value = elementZeroValue(shaderModule, vector.element, zeroValues)
        var i = 0
        while i < Int(vector.size) {
            result.elements[i] = value
            i &+= 1
        }
        return .vector(result)
    case .array(let array):
        guard case .creationFixed(let size) = array.size else {
            wgslFatal("std::get<unsigned> of an array size that is not creation-fixed", cppSite: "ConstantFunctions.h:106")
        }
        var result = ConstantArray(size: Int(size))
        let value = elementZeroValue(shaderModule, array.element, zeroValues)
        var i = 0
        while i < Int(size) {
            result.elements[i] = value
            i &+= 1
        }
        return .array(result)
    case .struct(let structType):
        var constantFields = ConstantStruct()
        let fields = shaderModule.types.fields(of: structType.fields)
        // DEV-02: the fields are set in member declaration order; C++ iterates the type's field HashMap.
        var cursor = shaderModule.cursor(shaderModule[structType.structure].members)
        while let member = shaderModule.next(&cursor) {
            let key = shaderModule[shaderModule[member].originalName].symbol
            guard let fieldType = fields.find(key) else {
                wgslFatal("a struct member that is not a field of the struct type", cppSite: "ConstantFunctions.h:115")
            }
            constantFields.set(key, elementZeroValue(shaderModule, fieldType, zeroValues))
        }
        return .struct(constantFields)
    case .primitiveStruct:
        // Primitive structs can't be zero initialized
        wgslFatal("zeroValue of a primitive struct", cppSite: "ConstantFunctions.h:121")
    case .matrix(let matrix):
        var result = ConstantMatrix(columns: UInt32(matrix.columns), rows: UInt32(matrix.rows))
        let value = elementZeroValue(shaderModule, matrix.element, zeroValues)
        var i = 0
        while i < result.elements.count {
            result.elements[i] = value
            i &+= 1
        }
        return .matrix(result)
    case .reference:
        wgslFatal("zeroValue of a reference type", cppSite: "ConstantFunctions.h:131")
    case .pointer:
        wgslFatal("zeroValue of a pointer type", cppSite: "ConstantFunctions.h:134")
    case .function:
        wgslFatal("zeroValue of a function type", cppSite: "ConstantFunctions.h:137")
    case .texture:
        wgslFatal("zeroValue of a texture type", cppSite: "ConstantFunctions.h:140")
    case .textureStorage:
        wgslFatal("zeroValue of a storage texture type", cppSite: "ConstantFunctions.h:143")
    case .textureDepth:
        wgslFatal("zeroValue of a depth texture type", cppSite: "ConstantFunctions.h:146")
    case .atomic:
        wgslFatal("zeroValue of an atomic type", cppSite: "ConstantFunctions.h:149")
    case .typeConstructor:
        wgslFatal("zeroValue of a type constructor", cppSite: "ConstantFunctions.h:152")
    }
}

// Helpers

/// C++ `constantUnaryOperation<constraint>(arguments, fn)`: `fn` is a closure per scalar alternative, and only the
/// alternatives in `constraint` are matched.
func constantUnaryOperation(
    _ arguments: borrowing [ConstantValue],
    _ constraint: Constraint,
    bool fnBool: (Bool) -> ConstantResult = { _ in wgslFatal("fn has no bool overload", cppSite: "ConstantFunctions.h:165") },
    i32 fnI32: (Int32) -> ConstantResult = { _ in wgslFatal("fn has no i32 overload", cppSite: "ConstantFunctions.h:169") },
    u32 fnU32: (UInt32) -> ConstantResult = { _ in wgslFatal("fn has no u32 overload", cppSite: "ConstantFunctions.h:173") },
    abstractInt fnAbstractInt: (Int64) -> ConstantResult = { _ in
        wgslFatal("fn has no AbstractInt overload", cppSite: "ConstantFunctions.h:177")
    },
    f32 fnF32: (Float) -> ConstantResult = { _ in wgslFatal("fn has no f32 overload", cppSite: "ConstantFunctions.h:181") },
    f16 fnF16: (Half) -> ConstantResult = { _ in wgslFatal("fn has no f16 overload", cppSite: "ConstantFunctions.h:185") },
    abstractFloat fnAbstractFloat: (Double) -> ConstantResult = { _ in
        wgslFatal("fn has no AbstractFloat overload", cppSite: "ConstantFunctions.h:189")
    }
) -> ConstantResult {
    assert(arguments.count == 1)
    return scalarOrVector(arguments[0]) { arg in
        if constraint.contains(.bool), case .bool(let boolean) = arg {
            return fnBool(boolean)
        }
        if constraint.contains(.i32), case .int32(let i32) = arg {
            return fnI32(i32)
        }
        if constraint.contains(.u32), case .uint32(let u32) = arg {
            return fnU32(u32)
        }
        if constraint.contains(.abstractInt), case .int64(let abstractInt) = arg {
            return fnAbstractInt(abstractInt)
        }
        if constraint.contains(.f32), case .float(let f32) = arg {
            return fnF32(f32)
        }
        if constraint.contains(.f16), case .half(let f16) = arg {
            return fnF16(f16)
        }
        if constraint.contains(.abstractFloat), case .double(let abstractFloat) = arg {
            return fnAbstractFloat(abstractFloat)
        }
        wgslFatal("constantUnaryOperation of a value outside its constraint", cppSite: "ConstantFunctions.h:191")
    }
}

/// C++ `constantBinaryOperation<constraint>(arguments, fn)`: the left operand selects the alternative, and the right
/// operand must hold the same one (C++ `std::get`).
func constantBinaryOperation(
    _ arguments: borrowing [ConstantValue],
    _ constraint: Constraint,
    bool fnBool: (Bool, Bool) -> ConstantResult = { _, _ in
        wgslFatal("fn has no bool overload", cppSite: "ConstantFunctions.h:202")
    },
    i32 fnI32: (Int32, Int32) -> ConstantResult = { _, _ in
        wgslFatal("fn has no i32 overload", cppSite: "ConstantFunctions.h:206")
    },
    u32 fnU32: (UInt32, UInt32) -> ConstantResult = { _, _ in
        wgslFatal("fn has no u32 overload", cppSite: "ConstantFunctions.h:210")
    },
    abstractInt fnAbstractInt: (Int64, Int64) -> ConstantResult = { _, _ in
        wgslFatal("fn has no AbstractInt overload", cppSite: "ConstantFunctions.h:214")
    },
    f32 fnF32: (Float, Float) -> ConstantResult = { _, _ in
        wgslFatal("fn has no f32 overload", cppSite: "ConstantFunctions.h:218")
    },
    f16 fnF16: (Half, Half) -> ConstantResult = { _, _ in
        wgslFatal("fn has no f16 overload", cppSite: "ConstantFunctions.h:222")
    },
    abstractFloat fnAbstractFloat: (Double, Double) -> ConstantResult = { _, _ in
        wgslFatal("fn has no AbstractFloat overload", cppSite: "ConstantFunctions.h:226")
    }
) -> ConstantResult {
    assert(arguments.count == 2)
    return scalarOrVector(arguments[0], arguments[1]) { left, right in
        if constraint.contains(.bool), case .bool(let leftBool) = left {
            guard case .bool(let rightBool) = right else {
                wgslFatal("std::get<bool> of a constant that is not a bool", cppSite: "ConstantFunctions.h:202")
            }
            return fnBool(leftBool, rightBool)
        }
        if constraint.contains(.i32), case .int32(let leftI32) = left {
            guard case .int32(let rightI32) = right else {
                wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:206")
            }
            return fnI32(leftI32, rightI32)
        }
        if constraint.contains(.u32), case .uint32(let leftU32) = left {
            guard case .uint32(let rightU32) = right else {
                wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:210")
            }
            return fnU32(leftU32, rightU32)
        }
        if constraint.contains(.abstractInt), case .int64(let leftAbstractInt) = left {
            guard case .int64(let rightAbstractInt) = right else {
                wgslFatal("std::get<int64_t> of a constant that is not an AbstractInt", cppSite: "ConstantFunctions.h:214")
            }
            return fnAbstractInt(leftAbstractInt, rightAbstractInt)
        }
        if constraint.contains(.f32), case .float(let leftF32) = left {
            guard case .float(let rightF32) = right else {
                wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:218")
            }
            return fnF32(leftF32, rightF32)
        }
        if constraint.contains(.f16), case .half(let leftF16) = left {
            guard case .half(let rightF16) = right else {
                wgslFatal("std::get<half> of a constant that is not an f16", cppSite: "ConstantFunctions.h:222")
            }
            return fnF16(leftF16, rightF16)
        }
        if constraint.contains(.abstractFloat), case .double(let leftAbstractFloat) = left {
            guard case .double(let rightAbstractFloat) = right else {
                wgslFatal("std::get<double> of a constant that is not an AbstractFloat", cppSite: "ConstantFunctions.h:226")
            }
            return fnAbstractFloat(leftAbstractFloat, rightAbstractFloat)
        }
        wgslFatal("constantBinaryOperation of a value outside its constraint", cppSite: "ConstantFunctions.h:228")
    }
}

/// C++ `constantTernaryOperation<constraint>(arguments, fn)`: the first operand selects the alternative, and the other two
/// must hold the same one (C++ `std::get`).
func constantTernaryOperation(
    _ arguments: borrowing [ConstantValue],
    _ constraint: Constraint,
    bool fnBool: (Bool, Bool, Bool) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no bool overload", cppSite: "ConstantFunctions.h:239")
    },
    i32 fnI32: (Int32, Int32, Int32) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no i32 overload", cppSite: "ConstantFunctions.h:243")
    },
    u32 fnU32: (UInt32, UInt32, UInt32) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no u32 overload", cppSite: "ConstantFunctions.h:247")
    },
    abstractInt fnAbstractInt: (Int64, Int64, Int64) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no AbstractInt overload", cppSite: "ConstantFunctions.h:251")
    },
    f32 fnF32: (Float, Float, Float) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no f32 overload", cppSite: "ConstantFunctions.h:255")
    },
    f16 fnF16: (Half, Half, Half) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no f16 overload", cppSite: "ConstantFunctions.h:259")
    },
    abstractFloat fnAbstractFloat: (Double, Double, Double) -> ConstantResult = { _, _, _ in
        wgslFatal("fn has no AbstractFloat overload", cppSite: "ConstantFunctions.h:263")
    }
) -> ConstantResult {
    assert(arguments.count == 3)
    return scalarOrVector(arguments[0], arguments[1], arguments[2]) { first, second, third in
        if constraint.contains(.bool), case .bool(let firstBool) = first {
            guard case .bool(let secondBool) = second, case .bool(let thirdBool) = third else {
                wgslFatal("std::get<bool> of a constant that is not a bool", cppSite: "ConstantFunctions.h:239")
            }
            return fnBool(firstBool, secondBool, thirdBool)
        }
        if constraint.contains(.i32), case .int32(let firstI32) = first {
            guard case .int32(let secondI32) = second, case .int32(let thirdI32) = third else {
                wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:243")
            }
            return fnI32(firstI32, secondI32, thirdI32)
        }
        if constraint.contains(.u32), case .uint32(let firstU32) = first {
            guard case .uint32(let secondU32) = second, case .uint32(let thirdU32) = third else {
                wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:247")
            }
            return fnU32(firstU32, secondU32, thirdU32)
        }
        if constraint.contains(.abstractInt), case .int64(let firstAbstractInt) = first {
            guard case .int64(let secondAbstractInt) = second, case .int64(let thirdAbstractInt) = third else {
                wgslFatal("std::get<int64_t> of a constant that is not an AbstractInt", cppSite: "ConstantFunctions.h:251")
            }
            return fnAbstractInt(firstAbstractInt, secondAbstractInt, thirdAbstractInt)
        }
        if constraint.contains(.f32), case .float(let firstF32) = first {
            guard case .float(let secondF32) = second, case .float(let thirdF32) = third else {
                wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "ConstantFunctions.h:255")
            }
            return fnF32(firstF32, secondF32, thirdF32)
        }
        if constraint.contains(.f16), case .half(let firstF16) = first {
            guard case .half(let secondF16) = second, case .half(let thirdF16) = third else {
                wgslFatal("std::get<half> of a constant that is not an f16", cppSite: "ConstantFunctions.h:259")
            }
            return fnF16(firstF16, secondF16, thirdF16)
        }
        if constraint.contains(.abstractFloat), case .double(let firstAbstractFloat) = first {
            guard case .double(let secondAbstractFloat) = second, case .double(let thirdAbstractFloat) = third else {
                wgslFatal("std::get<double> of a constant that is not an AbstractFloat", cppSite: "ConstantFunctions.h:263")
            }
            return fnAbstractFloat(firstAbstractFloat, secondAbstractFloat, thirdAbstractFloat)
        }
        wgslFatal("constantTernaryOperation of a value outside its constraint", cppSite: "ConstantFunctions.h:265")
    }
}

/// C++ `template<typename U> struct StaticCast` and `struct BitwiseCast`: the `Cast` template argument of `convertValue`.
///
/// `StaticCast<U>::cast(t)` is `U(staticCast: t)` and `BitwiseCast<U>::cast(t)` is `U(bitwiseCast: t.bitPattern)` (`ConstantScalar`).
@_spi(Testing)
public enum Cast: Sendable {
    case staticCast
    case bitwiseCast
}

/// C++ `convertValue<DestinationType, Cast>(value)`.
func convertValue<DestinationType: ConstantScalar>(
    _: DestinationType.Type,
    _ value: ConstantValue,
    _ cast: Cast = .staticCast
) -> ConstantValue {
    if cast == .staticCast || DestinationType.size == 4 {
        if case .int32(let i32) = value {
            return cast.cast(DestinationType.self, i32)
        }
        if case .uint32(let u32) = value {
            return cast.cast(DestinationType.self, u32)
        }
        if case .float(let f32) = value {
            return cast.cast(DestinationType.self, f32)
        }
    }

    if cast == .staticCast || DestinationType.size == 2 {
        if case .half(let f16) = value {
            return cast.cast(DestinationType.self, f16)
        }
    }

    if cast == .staticCast {
        if case .bool(let boolean) = value {
            return DestinationType(staticCast: boolean).constantValue
        }
        if case .int64(let abstractInt) = value {
            return DestinationType(staticCast: abstractInt).constantValue
        }
        if case .double(let abstractFloat) = value {
            return DestinationType(staticCast: abstractFloat).constantValue
        }
    }
    wgslFatal("convertValue of a value that the cast does not apply to", cppSite: "ConstantFunctions.h:318")
}

/// C++ `convertValue<Cast>(targetType, value)`.
@_spi(Testing)
public func convertValue(
    _ shaderModule: borrowing ShaderModule,
    _ targetType: TypeID,
    _ value: ConstantValue,
    _ cast: Cast = .staticCast
) -> ConstantValue {
    guard case .primitive(let primitive) = shaderModule.types[targetType] else {
        wgslFatal("std::get<Types::Primitive> of a type that is not primitive", cppSite: "ConstantFunctions.h:325")
    }
    switch primitive.kind {
    case .abstractInt:
        return convertValue(Int64.self, value, cast)
    case .i32:
        return convertValue(Int32.self, value, cast)
    case .u32:
        return convertValue(UInt32.self, value, cast)
    case .abstractFloat:
        return convertValue(Double.self, value, cast)
    case .f32:
        return convertValue(Float.self, value, cast)
    case .f16:
        return convertValue(Half.self, value, cast)
    case .bool:
        return convertValue(Bool.self, value, cast)
    case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
        wgslFatal("convertValue to a primitive type that has no values", cppSite: "ConstantFunctions.h:342")
    }
}

/// C++ `constantConstructor<DestinationType>(resultType, arguments)`.
func constantConstructor<DestinationType: ConstantScalar>(
    _: DestinationType.Type,
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantValue {
    if arguments.isEmpty {
        return zeroValue(shaderModule, resultType)
    }

    assert(arguments.count == 1)
    return convertValue(DestinationType.self, arguments[0])
}

/// C++ `scalarOrVector(functor, arguments...)` for one argument: `functor` is applied to the argument, or to each element of
/// a vector argument.
func scalarOrVector(_ argument: ConstantValue, _ functor: (ConstantValue) -> ConstantResult) -> ConstantResult {
    let vectorSize = firstVectorSize(argument) ?? 0
    if vectorSize == 0 {
        return functor(argument)
    }
    return scalarOrVector(vectorSize: vectorSize, [argument]) { scalars in functor(scalars[0]) }
}

/// C++ `scalarOrVector(functor, arguments...)` for two arguments: a scalar argument is passed unchanged with each element of
/// the first vector argument's length.
func scalarOrVector(
    _ first: ConstantValue,
    _ second: ConstantValue,
    _ functor: (ConstantValue, ConstantValue) -> ConstantResult
) -> ConstantResult {
    let vectorSize = firstVectorSize(first) ?? firstVectorSize(second) ?? 0
    if vectorSize == 0 {
        return functor(first, second)
    }
    return scalarOrVector(vectorSize: vectorSize, [first, second]) { scalars in functor(scalars[0], scalars[1]) }
}

/// C++ `scalarOrVector(functor, arguments...)` for three arguments.
func scalarOrVector(
    _ first: ConstantValue,
    _ second: ConstantValue,
    _ third: ConstantValue,
    _ functor: (ConstantValue, ConstantValue, ConstantValue) -> ConstantResult
) -> ConstantResult {
    let vectorSize = firstVectorSize(first) ?? firstVectorSize(second) ?? firstVectorSize(third) ?? 0
    if vectorSize == 0 {
        return functor(first, second, third)
    }
    return scalarOrVector(vectorSize: vectorSize, [first, second, third]) { scalars in
        functor(scalars[0], scalars[1], scalars[2])
    }
}

/// C++ `scalarOrVector(functor, arguments...)` for four arguments.
func scalarOrVector(
    _ first: ConstantValue,
    _ second: ConstantValue,
    _ third: ConstantValue,
    _ fourth: ConstantValue,
    _ functor: (ConstantValue, ConstantValue, ConstantValue, ConstantValue) -> ConstantResult
) -> ConstantResult {
    let vectorSize = firstVectorSize(first) ?? firstVectorSize(second) ?? firstVectorSize(third) ?? firstVectorSize(fourth) ?? 0
    if vectorSize == 0 {
        return functor(first, second, third, fourth)
    }
    return scalarOrVector(vectorSize: vectorSize, [first, second, third, fourth]) { scalars in
        functor(scalars[0], scalars[1], scalars[2], scalars[3])
    }
}

/// The element loop of C++ `scalarOrVector`, once a vector argument of `vectorSize` elements was found.
private func scalarOrVector(
    vectorSize: Int,
    _ arguments: [ConstantValue],
    _ functor: ([ConstantValue]) -> ConstantResult
) -> ConstantResult {
    var result = ConstantVector(size: vectorSize)
    var scalars = defaultConstantValues(arguments.count)
    var i = 0
    while i < vectorSize {
        var j = 0
        while j < arguments.count {
            if case .vector(let vector) = arguments[j] {
                scalars[j] = vector.elements[i]
            } else {
                scalars[j] = arguments[j]
            }
            j &+= 1
        }
        let tmp = functor(scalars)
        guard case .success(let value) = tmp else {
            return tmp
        }
        result.elements[i] = value
        i &+= 1
    }
    return .success(.vector(result))
}

/// C++ `constantVector(resultType, arguments, size)`.
@_spi(Testing)
public func constantVector(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue],
    _ size: UInt32
) -> ConstantValue {
    var result = ConstantVector(size: Int(size))
    let argumentCount = arguments.count

    assert(shaderModule.types.getIf(Types.Vector.self, resultType) != nil)
    if argumentCount == 0 {
        return zeroValue(shaderModule, resultType)
    }

    if argumentCount == 1 {
        guard case .vector(let vectorType) = shaderModule.types[resultType] else {
            wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:401")
        }
        let elementType = vectorType.element
        if case .vector(let vector) = arguments[0] {
            assert(vector.elements.count == Int(vectorType.size))
            var i = 0
            while i < vector.elements.count {
                result.elements[i] = convertValue(shaderModule, elementType, vector.elements[i])
                i &+= 1
            }
        } else {
            var i = 0
            while i < Int(size) {
                result.elements[i] = convertValue(shaderModule, elementType, arguments[0])
                i &+= 1
            }
        }
        return .vector(result)
    }

    var i = 0
    var argumentIndex = 0
    while argumentIndex < arguments.count {
        let argument = arguments[argumentIndex]
        argumentIndex &+= 1
        guard case .vector(let vector) = argument else {
            result.elements[i] = argument
            i &+= 1
            continue
        }
        var elementIndex = 0
        while elementIndex < vector.elements.count {
            result.elements[i] = vector.elements[elementIndex]
            i &+= 1
            elementIndex &+= 1
        }
    }
    assert(i == Int(size))
    return .vector(result)
}

/// C++ `constantMatrix(resultType, arguments, columns, rows)`.
@_spi(Testing)
public func constantMatrix(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue],
    _ columns: UInt32,
    _ rows: UInt32
) -> ConstantValue {
    if arguments.isEmpty {
        return zeroValue(shaderModule, resultType)
    }

    if arguments.count == 1 {
        guard case .matrix(let matrixType) = shaderModule.types[resultType] else {
            wgslFatal("std::get<Types::Matrix> of a type that is not a matrix", cppSite: "ConstantFunctions.h:436")
        }
        let elementType = matrixType.element
        guard case .matrix(let matrix) = arguments[0] else {
            wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "ConstantFunctions.h:438")
        }
        assert(matrix.elements.count == Int(matrixType.rows) &* Int(matrixType.columns))
        var result = ConstantMatrix(columns: columns, rows: rows)
        var i = 0
        while i < matrix.elements.count {
            result.elements[i] = convertValue(shaderModule, elementType, matrix.elements[i])
            i &+= 1
        }
        return .matrix(result)
    }

    if arguments.count == Int(columns &* rows) {
        return .matrix(ConstantMatrix(columns: columns, rows: rows, copy arguments))
    }

    guard arguments.count == Int(columns) else {
        wgslFatal("a matrix constructor whose argument count is neither 1, columns * rows nor columns", cppSite: "ConstantFunctions.h:450")
    }
    var result = ConstantMatrix(columns: columns, rows: rows)
    var i = 0
    var argumentIndex = 0
    while argumentIndex < arguments.count {
        let arg = arguments[argumentIndex]
        assert(arg.isVector)
        let vector = arg.toVector()
        assert(vector.elements.count == Int(rows))
        var elementIndex = 0
        while elementIndex < vector.elements.count {
            result.elements[i] = vector.elements[elementIndex]
            i &+= 1
            elementIndex &+= 1
        }
        argumentIndex &+= 1
    }
    assert(i == Int(columns &* rows))
    return .matrix(result)
}

// MARK: - Swift-only

/// The array and struct types whose zero values `zeroValue(shaderModule, type)` needs, element and field types before the
/// types that contain them (an iterative post-order walk, so that alias chains of any depth do not recurse).
private func zeroValueOperands(_ shaderModule: borrowing ShaderModule, _ type: TypeID) -> [TypeID] {
    var operands: [TypeID] = []
    var visited = LookupSet<TypeID>()
    var stack: [(type: TypeID, operandsPushed: Bool)] = []
    appendCompositeOperands(shaderModule, type, &stack)
    while let top = stack.popLast() {
        if top.operandsPushed {
            operands.append(top.type)
            continue
        }
        guard visited.add(top.type) else {
            continue
        }
        stack.append((type: top.type, operandsPushed: true))
        appendCompositeOperands(shaderModule, top.type, &stack)
    }
    return operands
}

/// Pushes the array and struct types among the element type or the field types of `type`.
private func appendCompositeOperands(
    _ shaderModule: borrowing ShaderModule,
    _ type: TypeID,
    _ stack: inout [(type: TypeID, operandsPushed: Bool)]
) {
    func append(_ operand: TypeID) {
        switch shaderModule.types[operand] {
        case .array, .struct:
            stack.append((type: operand, operandsPushed: false))
        case .primitive, .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference,
            .pointer, .atomic, .typeConstructor:
            return
        }
    }

    switch shaderModule.types[type] {
    case .array(let array):
        append(array.element)
    case .struct(let structType):
        let fields = shaderModule.types.fields(of: structType.fields)
        var cursor = shaderModule.cursor(shaderModule[structType.structure].members)
        while let member = shaderModule.next(&cursor) {
            if let fieldType = fields.find(shaderModule[shaderModule[member].originalName].symbol) {
                append(fieldType)
            }
        }
    case .primitive, .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference,
        .pointer, .atomic, .typeConstructor:
        return
    }
}

/// A recursive C++ `zeroValue(elementType)` call: the precomputed value of an array or struct type, otherwise the value
/// itself (a scalar, vector or matrix, whose element type is a scalar).
private func elementZeroValue(
    _ shaderModule: borrowing ShaderModule,
    _ type: TypeID,
    _ zeroValues: borrowing LookupMap<TypeID, ConstantValue>
) -> ConstantValue {
    if let value = zeroValues.get(type) {
        return value
    }
    return zeroValue(shaderModule, type, zeroValues)
}

private func firstVectorSize(_ argument: ConstantValue) -> Int? {
    guard case .vector(let vector) = argument else {
        return nil
    }
    return vector.elements.count
}

/// The scalar alternatives of `ConstantValue` (C++ `int64_t`, `int32_t`, `uint32_t`, `double`, `float`, `half`, `bool`):
/// the `DestinationType` of `convertValue` and `constantConstructor`.
protocol ConstantScalar {
    /// C++ `sizeof(DestinationType)`.
    static var size: Int { get }

    /// C++ `ConstantValue(value)`.
    var constantValue: ConstantValue { get }

    /// C++ `StaticCast<Self>::cast(t)`.
    init(staticCast t: Int32)
    init(staticCast t: UInt32)
    init(staticCast t: Float)
    init(staticCast t: Half)
    init(staticCast t: Bool)
    init(staticCast t: Int64)
    init(staticCast t: Double)

    /// C++ `BitwiseCast<Self>::cast(t)` (`std::bit_cast`) of a 4-byte value; only the 4-byte types have it.
    init(bitwiseCast bitPattern: UInt32)

    /// C++ `BitwiseCast<Self>::cast(t)` of a 2-byte value; only `Half` has it.
    init(bitwiseCast bitPattern: UInt16)
}

extension ConstantScalar {
    init(bitwiseCast bitPattern: UInt32) {
        wgslFatal("std::bit_cast between types of different sizes", cppSite: "ConstantFunctions.h:290")
    }

    init(bitwiseCast bitPattern: UInt16) {
        wgslFatal("std::bit_cast between types of different sizes", cppSite: "ConstantFunctions.h:290")
    }
}

extension Cast {
    /// C++ `Cast<DestinationType>::cast(t)`.
    fileprivate func cast<DestinationType: ConstantScalar>(_: DestinationType.Type, _ t: Int32) -> ConstantValue {
        switch self {
        case .staticCast:
            DestinationType(staticCast: t).constantValue
        case .bitwiseCast:
            DestinationType(bitwiseCast: UInt32(bitPattern: t)).constantValue
        }
    }

    fileprivate func cast<DestinationType: ConstantScalar>(_: DestinationType.Type, _ t: UInt32) -> ConstantValue {
        switch self {
        case .staticCast:
            DestinationType(staticCast: t).constantValue
        case .bitwiseCast:
            DestinationType(bitwiseCast: t).constantValue
        }
    }

    fileprivate func cast<DestinationType: ConstantScalar>(_: DestinationType.Type, _ t: Float) -> ConstantValue {
        switch self {
        case .staticCast:
            DestinationType(staticCast: t).constantValue
        case .bitwiseCast:
            DestinationType(bitwiseCast: t.bitPattern).constantValue
        }
    }

    fileprivate func cast<DestinationType: ConstantScalar>(_: DestinationType.Type, _ t: Half) -> ConstantValue {
        switch self {
        case .staticCast:
            DestinationType(staticCast: t).constantValue
        case .bitwiseCast:
            DestinationType(bitwiseCast: t.bitPattern).constantValue
        }
    }
}

/// `static const half max = 0x1.ffcp15;` of `StaticCast<U>::cast(half)` for an integer `U`.
private func staticCastHalfMax() -> Half {
    Half(Double(0x1.ffcp15))
}

/// `std::clamp(t, std::max(T(std::numeric_limits<U>::min()), lowest), max)` of `StaticCast<U>::cast(half)`.
private func staticCastClamp(_ t: Half, min: Float) -> Half {
    let max = staticCastHalfMax()
    let lowest = Half(-Float(max))
    return cxxClamp(t, cxxMax(Half(min), lowest), max)
}

// DEV-13: arm64 FCVTZS semantics (truncate, saturate, NaN -> 0) on every host.
private func arm64ConvertToInt64(_ value: Double) -> Int64 {
    if value.isNaN {
        return 0
    }
    if value >= 9_223_372_036_854_775_808.0 {
        return .max
    }
    if value <= -9_223_372_036_854_775_808.0 {
        return .min
    }
    guard let result = Int64(exactly: value.rounded(.towardZero)) else {
        wgslFatal("float-to-int conversion out of range after the range checks", cppSite: "ConstantFunctions.h:283")
    }
    return result
}

extension Int64: ConstantScalar {
    static var size: Int { 8 }

    var constantValue: ConstantValue { .int64(self) }

    init(staticCast t: Int32) { self = Int64(t) }

    init(staticCast t: UInt32) { self = Int64(t) }

    init(staticCast t: Float) {
        self = arm64ConvertToInt64(Double(cxxClamp(t, Float(Int64.min), Float(Int64.max &- ((128 &<< 0) &- 1)))))
    }

    init(staticCast t: Half) { self = arm64ConvertToInt64(Double(Float(staticCastClamp(t, min: Float(Int64.min))))) }

    init(staticCast t: Bool) { self = t ? 1 : 0 }

    init(staticCast t: Int64) { self = t }

    // DEV-13: static_cast<int64_t>(double) is not clamped.
    init(staticCast t: Double) { self = arm64ConvertToInt64(t) }
}

extension Int32: ConstantScalar {
    static var size: Int { 4 }

    var constantValue: ConstantValue { .int32(self) }

    init(staticCast t: Int32) { self = t }

    init(staticCast t: UInt32) { self = Int32(bitPattern: t) }

    init(staticCast t: Float) {
        self = arm64ConvertToInt32(cxxClamp(t, Float(Int32.min), Float(Int32.max &- ((128 &<< 0) &- 1))))
    }

    init(staticCast t: Half) { self = arm64ConvertToInt32(Float(staticCastClamp(t, min: Float(Int32.min)))) }

    init(staticCast t: Bool) { self = t ? 1 : 0 }

    init(staticCast t: Int64) { self = Int32(truncatingIfNeeded: t) }

    // DEV-13: static_cast<int32_t>(double) is not clamped.
    init(staticCast t: Double) { self = arm64ConvertToInt32(t) }

    init(bitwiseCast bitPattern: UInt32) { self = Int32(bitPattern: bitPattern) }
}

extension UInt32: ConstantScalar {
    static var size: Int { 4 }

    var constantValue: ConstantValue { .uint32(self) }

    init(staticCast t: Int32) { self = UInt32(bitPattern: t) }

    init(staticCast t: UInt32) { self = t }

    init(staticCast t: Float) {
        self = arm64ConvertToUInt32(cxxClamp(t, Float(UInt32.min), Float(UInt32.max &- ((128 &<< 1) &- 1))))
    }

    init(staticCast t: Half) { self = arm64ConvertToUInt32(Float(staticCastClamp(t, min: Float(UInt32.min)))) }

    init(staticCast t: Bool) { self = t ? 1 : 0 }

    init(staticCast t: Int64) { self = UInt32(truncatingIfNeeded: t) }

    // DEV-13: static_cast<uint32_t>(double) is not clamped.
    init(staticCast t: Double) { self = arm64ConvertToUInt32(t) }

    init(bitwiseCast bitPattern: UInt32) { self = bitPattern }
}

extension Double: ConstantScalar {
    static var size: Int { 8 }

    var constantValue: ConstantValue { .double(self) }

    init(staticCast t: Int32) { self = Double(t) }

    init(staticCast t: UInt32) { self = Double(t) }

    init(staticCast t: Float) { self = Double(t) }

    init(staticCast t: Half) { self = Double(t) }

    init(staticCast t: Bool) { self = t ? 1 : 0 }

    init(staticCast t: Int64) { self = Double(t) }

    init(staticCast t: Double) { self = t }
}

extension Float: ConstantScalar {
    static var size: Int { 4 }

    var constantValue: ConstantValue { .float(self) }

    init(staticCast t: Int32) { self = Float(t) }

    init(staticCast t: UInt32) { self = Float(t) }

    init(staticCast t: Float) { self = t }

    init(staticCast t: Half) { self = Float(t) }

    init(staticCast t: Bool) { self = t ? 1 : 0 }

    init(staticCast t: Int64) { self = Float(t) }

    init(staticCast t: Double) { self = Float(t) }

    init(bitwiseCast bitPattern: UInt32) { self = Float(bitPattern: bitPattern) }
}

extension Half: ConstantScalar {
    static var size: Int { 2 }

    var constantValue: ConstantValue { .half(self) }

    init(staticCast t: Int32) { self = Half(Double(t)) }

    init(staticCast t: UInt32) { self = Half(Double(t)) }

    init(staticCast t: Float) { self = Half(t) }

    init(staticCast t: Half) { self = t }

    init(staticCast t: Bool) { self = Half(Float(t ? 1 : 0)) }

    init(staticCast t: Int64) { self = Half(Double(t)) }

    init(staticCast t: Double) { self = Half(t) }

    init(bitwiseCast bitPattern: UInt16) { self = Half(bitPattern: bitPattern) }
}

extension Bool: ConstantScalar {
    static var size: Int { 1 }

    var constantValue: ConstantValue { .bool(self) }

    init(staticCast t: Int32) { self = t != 0 }

    init(staticCast t: UInt32) { self = t != 0 }

    init(staticCast t: Float) { self = t != 0 }

    init(staticCast t: Half) { self = Float(t) != 0 }

    init(staticCast t: Bool) { self = t }

    init(staticCast t: Int64) { self = t != 0 }

    init(staticCast t: Double) { self = t != 0 }
}

extension ConstantFunctionError {
    /// The message of a `ConstEvalArithmetic` error.
    init(_ error: ConstEvalError) {
        message = "\(error.message)"
    }
}

// MARK: - Testing

/// The C++ constant functions in ConstantFunctions.h order; the raw value is the stem of the Swift name (`constantAdd` is
/// `add`).
@_spi(Testing)
public enum ConstantFunctionName: String, CaseIterable, Sendable {
    case add
    case minus
    case multiply
    case divide
    case modulo
    case equal
    case notEqual
    case lt
    case ltEq
    case gt
    case gtEq
    case not
    case or
    case and
    case bitwiseOr
    case bitwiseAnd
    case bitwiseNot
    case bitwiseXor
    case bitwiseShiftLeft
    case bitwiseShiftRight
    case bool
    case f32
    case f16
    case i32
    case u32
    case vec2
    case vec3
    case vec4
    case mat2x2
    case mat2x3
    case mat2x4
    case mat3x2
    case mat3x3
    case mat3x4
    case mat4x2
    case mat4x3
    case mat4x4
    case all
    case any
    case select
    case acos
    case asin
    case atan
    case cos
    case sin
    case tan
    case acosh
    case asinh
    case atanh
    case cosh
    case sinh
    case tanh
    case abs
    case atan2
    case ceil
    case clamp
    case countLeadingZeros
    case countOneBits
    case countTrailingZeros
    case cross
    case degrees
    case determinant
    case distance
    case dot
    case dot4U8Packed
    case dot4I8Packed
    case length
    case exp
    case exp2
    case extractBits
    case faceForward
    case firstLeadingBit
    case firstTrailingBit
    case floor
    case fma
    case fract
    case frexp
    case insertBits
    case inverseSqrt
    case ldexp
    case log
    case log2
    case max
    case min
    case mix
    case modf
    case normalize
    case pow
    case quantizeToF16
    case radians
    case reflect
    case refract
    case reverseBits
    case round
    case saturate
    case sign
    case smoothstep
    case sqrt
    case step
    case transpose
    case trunc
    case pack4x8snorm
    case pack4x8unorm
    case pack4xI8
    case pack4xU8
    case pack4xI8Clamp
    case pack4xU8Clamp
    case pack2x16snorm
    case pack2x16unorm
    case pack2x16float
    case unpack4x8snorm
    case unpack4x8unorm
    case unpack4xI8
    case unpack4xU8
    case unpack2x16snorm
    case unpack2x16unorm
    case unpack2x16float
    case bitcast
}

/// The C++ validation functions in ConstantFunctions.h order; the raw value is the stem of the Swift name (`validateAdd`
/// is `add`).
@_spi(Testing)
public enum ValidationFunctionName: String, CaseIterable, Sendable {
    case clamp
    case add
    case minus
    case multiply
    case smoothstep
    case divide
    case modulo
    case ldexp
    case bitwiseShiftLeft
    case bitwiseShiftRight
    case extractBits
    case insertBits
    case workgroupUniformLoad
    case subgroupShuffle
    case subgroupBroadcast
    case quadBroadcast
}

extension ShaderModule {
    /// Calls `constant<name>(self, resultType, arguments)`, for the tests.
    @_spi(Testing)
    public func evaluateConstantFunctionForTesting(
        name: ConstantFunctionName,
        resultType: TypeID,
        arguments: [ConstantValue]
    ) -> ConstantResult {
        switch name {
        case .add: constantAdd(self, resultType, arguments)
        case .minus: constantMinus(self, resultType, arguments)
        case .multiply: constantMultiply(self, resultType, arguments)
        case .divide: constantDivide(self, resultType, arguments)
        case .modulo: constantModulo(self, resultType, arguments)
        case .equal: constantEqual(self, resultType, arguments)
        case .notEqual: constantNotEqual(self, resultType, arguments)
        case .lt: constantLt(self, resultType, arguments)
        case .ltEq: constantLtEq(self, resultType, arguments)
        case .gt: constantGt(self, resultType, arguments)
        case .gtEq: constantGtEq(self, resultType, arguments)
        case .not: constantNot(self, resultType, arguments)
        case .or: constantOr(self, resultType, arguments)
        case .and: constantAnd(self, resultType, arguments)
        case .bitwiseOr: constantBitwiseOr(self, resultType, arguments)
        case .bitwiseAnd: constantBitwiseAnd(self, resultType, arguments)
        case .bitwiseNot: constantBitwiseNot(self, resultType, arguments)
        case .bitwiseXor: constantBitwiseXor(self, resultType, arguments)
        case .bitwiseShiftLeft: constantBitwiseShiftLeft(self, resultType, arguments)
        case .bitwiseShiftRight: constantBitwiseShiftRight(self, resultType, arguments)
        case .bool: constantBool(self, resultType, arguments)
        case .f32: constantF32(self, resultType, arguments)
        case .f16: constantF16(self, resultType, arguments)
        case .i32: constantI32(self, resultType, arguments)
        case .u32: constantU32(self, resultType, arguments)
        case .vec2: constantVec2(self, resultType, arguments)
        case .vec3: constantVec3(self, resultType, arguments)
        case .vec4: constantVec4(self, resultType, arguments)
        case .mat2x2: constantMat2x2(self, resultType, arguments)
        case .mat2x3: constantMat2x3(self, resultType, arguments)
        case .mat2x4: constantMat2x4(self, resultType, arguments)
        case .mat3x2: constantMat3x2(self, resultType, arguments)
        case .mat3x3: constantMat3x3(self, resultType, arguments)
        case .mat3x4: constantMat3x4(self, resultType, arguments)
        case .mat4x2: constantMat4x2(self, resultType, arguments)
        case .mat4x3: constantMat4x3(self, resultType, arguments)
        case .mat4x4: constantMat4x4(self, resultType, arguments)
        case .all: constantAll(self, resultType, arguments)
        case .any: constantAny(self, resultType, arguments)
        case .select: constantSelect(self, resultType, arguments)
        case .acos: constantAcos(self, resultType, arguments)
        case .asin: constantAsin(self, resultType, arguments)
        case .atan: constantAtan(self, resultType, arguments)
        case .cos: constantCos(self, resultType, arguments)
        case .sin: constantSin(self, resultType, arguments)
        case .tan: constantTan(self, resultType, arguments)
        case .acosh: constantAcosh(self, resultType, arguments)
        case .asinh: constantAsinh(self, resultType, arguments)
        case .atanh: constantAtanh(self, resultType, arguments)
        case .cosh: constantCosh(self, resultType, arguments)
        case .sinh: constantSinh(self, resultType, arguments)
        case .tanh: constantTanh(self, resultType, arguments)
        case .abs: constantAbs(self, resultType, arguments)
        case .atan2: constantAtan2(self, resultType, arguments)
        case .ceil: constantCeil(self, resultType, arguments)
        case .clamp: constantClamp(self, resultType, arguments)
        case .countLeadingZeros: constantCountLeadingZeros(self, resultType, arguments)
        case .countOneBits: constantCountOneBits(self, resultType, arguments)
        case .countTrailingZeros: constantCountTrailingZeros(self, resultType, arguments)
        case .cross: constantCross(self, resultType, arguments)
        case .degrees: constantDegrees(self, resultType, arguments)
        case .determinant: constantDeterminant(self, resultType, arguments)
        case .distance: constantDistance(self, resultType, arguments)
        case .dot: constantDot(self, resultType, arguments)
        case .dot4U8Packed: constantDot4U8Packed(self, resultType, arguments)
        case .dot4I8Packed: constantDot4I8Packed(self, resultType, arguments)
        case .length: constantLength(self, resultType, arguments)
        case .exp: constantExp(self, resultType, arguments)
        case .exp2: constantExp2(self, resultType, arguments)
        case .extractBits: constantExtractBits(self, resultType, arguments)
        case .faceForward: constantFaceForward(self, resultType, arguments)
        case .firstLeadingBit: constantFirstLeadingBit(self, resultType, arguments)
        case .firstTrailingBit: constantFirstTrailingBit(self, resultType, arguments)
        case .floor: constantFloor(self, resultType, arguments)
        case .fma: constantFma(self, resultType, arguments)
        case .fract: constantFract(self, resultType, arguments)
        case .frexp: constantFrexp(self, resultType, arguments)
        case .insertBits: constantInsertBits(self, resultType, arguments)
        case .inverseSqrt: constantInverseSqrt(self, resultType, arguments)
        case .ldexp: constantLdexp(self, resultType, arguments)
        case .log: constantLog(self, resultType, arguments)
        case .log2: constantLog2(self, resultType, arguments)
        case .max: constantMax(self, resultType, arguments)
        case .min: constantMin(self, resultType, arguments)
        case .mix: constantMix(self, resultType, arguments)
        case .modf: constantModf(self, resultType, arguments)
        case .normalize: constantNormalize(self, resultType, arguments)
        case .pow: constantPow(self, resultType, arguments)
        case .quantizeToF16: constantQuantizeToF16(self, resultType, arguments)
        case .radians: constantRadians(self, resultType, arguments)
        case .reflect: constantReflect(self, resultType, arguments)
        case .refract: constantRefract(self, resultType, arguments)
        case .reverseBits: constantReverseBits(self, resultType, arguments)
        case .round: constantRound(self, resultType, arguments)
        case .saturate: constantSaturate(self, resultType, arguments)
        case .sign: constantSign(self, resultType, arguments)
        case .smoothstep: constantSmoothstep(self, resultType, arguments)
        case .sqrt: constantSqrt(self, resultType, arguments)
        case .step: constantStep(self, resultType, arguments)
        case .transpose: constantTranspose(self, resultType, arguments)
        case .trunc: constantTrunc(self, resultType, arguments)
        case .pack4x8snorm: constantPack4x8snorm(self, resultType, arguments)
        case .pack4x8unorm: constantPack4x8unorm(self, resultType, arguments)
        case .pack4xI8: constantPack4xI8(self, resultType, arguments)
        case .pack4xU8: constantPack4xU8(self, resultType, arguments)
        case .pack4xI8Clamp: constantPack4xI8Clamp(self, resultType, arguments)
        case .pack4xU8Clamp: constantPack4xU8Clamp(self, resultType, arguments)
        case .pack2x16snorm: constantPack2x16snorm(self, resultType, arguments)
        case .pack2x16unorm: constantPack2x16unorm(self, resultType, arguments)
        case .pack2x16float: constantPack2x16float(self, resultType, arguments)
        case .unpack4x8snorm: constantUnpack4x8snorm(self, resultType, arguments)
        case .unpack4x8unorm: constantUnpack4x8unorm(self, resultType, arguments)
        case .unpack4xI8: constantUnpack4xI8(self, resultType, arguments)
        case .unpack4xU8: constantUnpack4xU8(self, resultType, arguments)
        case .unpack2x16snorm: constantUnpack2x16snorm(self, resultType, arguments)
        case .unpack2x16unorm: constantUnpack2x16unorm(self, resultType, arguments)
        case .unpack2x16float: constantUnpack2x16float(self, resultType, arguments)
        case .bitcast: constantBitcast(self, resultType, arguments)
        }
    }

    /// Calls `validate<name>(self, arguments, types)`.
    @_spi(Testing)
    public func evaluateValidationFunctionForTesting(
        name: ValidationFunctionName,
        arguments: [ConstantValue?],
        types: [TypeID]
    ) -> MessageText? {
        switch name {
        case .clamp: validateClamp(self, arguments, types)
        case .add: validateAdd(self, arguments, types)
        case .minus: validateMinus(self, arguments, types)
        case .multiply: validateMultiply(self, arguments, types)
        case .smoothstep: validateSmoothstep(self, arguments, types)
        case .divide: validateDivide(self, arguments, types)
        case .modulo: validateModulo(self, arguments, types)
        case .ldexp: validateLdexp(self, arguments, types)
        case .bitwiseShiftLeft: validateBitwiseShiftLeft(self, arguments, types)
        case .bitwiseShiftRight: validateBitwiseShiftRight(self, arguments, types)
        case .extractBits: validateExtractBits(self, arguments, types)
        case .insertBits: validateInsertBits(self, arguments, types)
        case .workgroupUniformLoad: validateWorkgroupUniformLoad(self, arguments, types)
        case .subgroupShuffle: validateSubgroupShuffle(self, arguments, types)
        case .subgroupBroadcast: validateSubgroupBroadcast(self, arguments, types)
        case .quadBroadcast: validateQuadBroadcast(self, arguments, types)
        }
    }
}
