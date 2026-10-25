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

// Arithmetic operators

func constantAdd(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 2)

    if case .matrix(let left) = arguments[0] {
        guard case .matrix(let right) = arguments[1] else {
            wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "ConstantFunctions.h:509")
        }
        guard case .matrix(let matrixType) = shaderModule.types[resultType] else {
            wgslFatal("std::get<Types::Matrix> of a type that is not a matrix", cppSite: "ConstantFunctions.h:510")
        }
        let elementType = matrixType.element
        assert(left.columns == right.columns)
        assert(left.rows == right.rows)
        return ConstantResult { () throws(ConstantFunctionError) in
            var result = ConstantMatrix(columns: left.columns, rows: left.rows)
            for i in 0..<result.elements.count {
                result.elements[i] = try constantAdd(shaderModule, elementType, [left.elements[i], right.elements[i]]).get()
            }
            return .matrix(result)
        }
    }

    return constantBinaryOperation(
        arguments,
        .number,
        i32: { left, right in .success(.int32(ConstInt.add(left, right))) },
        u32: { left, right in .success(.uint32(ConstInt.add(left, right))) },
        // i32 and u32 wrap on overflow, but AbstractInt has no width to wrap to.
        abstractInt: { left, right in integerResult(AbstractInt(left).adding(AbstractInt(right))) },
        f32: { (left: Float, right: Float) in finiteResult(left + right, .additionOverflow) },
        f16: { left, right in finiteResult(Half(Float(left) + Float(right)), .additionOverflow) },
        abstractFloat: { (left: Double, right: Double) in finiteResult(left + right, .additionOverflow) }
    )
}

func constantMinus(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    if arguments.count == 1 {
        return constantUnaryOperation(
            arguments,
            .number,
            i32: { arg in .success(.int32(ConstInt.negate(arg))) },
            u32: { arg in .success(.uint32(ConstInt.negate(arg))) },
            abstractInt: { arg in .success(.int64(AbstractInt(arg).negated.value)) },
            f32: { (arg: Float) in .success(.float(-arg)) },
            f16: { arg in .success(.half(Half(-Float(arg)))) },
            abstractFloat: { (arg: Double) in .success(.double(-arg)) }
        )
    }

    if case .matrix(let left) = arguments[0] {
        guard case .matrix(let right) = arguments[1] else {
            wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "ConstantFunctions.h:546")
        }
        guard case .matrix(let matrixType) = shaderModule.types[resultType] else {
            wgslFatal("std::get<Types::Matrix> of a type that is not a matrix", cppSite: "ConstantFunctions.h:547")
        }
        let elementType = matrixType.element
        assert(left.columns == right.columns)
        assert(left.rows == right.rows)
        return ConstantResult { () throws(ConstantFunctionError) in
            var result = ConstantMatrix(columns: left.columns, rows: left.rows)
            for i in 0..<result.elements.count {
                result.elements[i] = try constantMinus(shaderModule, elementType, [left.elements[i], right.elements[i]]).get()
            }
            return .matrix(result)
        }
    }

    return constantBinaryOperation(
        arguments,
        .number,
        i32: { left, right in .success(.int32(ConstInt.subtract(left, right))) },
        u32: { left, right in .success(.uint32(ConstInt.subtract(left, right))) },
        // i32 and u32 wrap on overflow, but AbstractInt has no width to wrap to.
        abstractInt: { left, right in integerResult(AbstractInt(left).subtracting(AbstractInt(right))) },
        f32: { (left: Float, right: Float) in finiteResult(left - right, .subtractionOverflow) },
        f16: { left, right in finiteResult(Half(Float(left) - Float(right)), .subtractionOverflow) },
        abstractFloat: { (left: Double, right: Double) in finiteResult(left - right, .subtractionOverflow) }
    )
}

func constantMultiply(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    assert(arguments.count == 2)

    let leftMatrix: ConstantMatrix? = if case .matrix(let matrix) = arguments[0] { matrix } else { nil }
    let rightMatrix: ConstantMatrix? = if case .matrix(let matrix) = arguments[1] { matrix } else { nil }
    if let leftMatrix, let rightMatrix {
        assert(leftMatrix.columns == rightMatrix.rows)
        guard case .matrix(let matrixType) = shaderModule.types[resultType] else {
            wgslFatal("std::get<Types::Matrix> of a type that is not a matrix", cppSite: "ConstantFunctions.h:584")
        }
        let elementType = matrixType.element
        return ConstantResult { () throws(ConstantFunctionError) in
            var result = ConstantMatrix(columns: rightMatrix.columns, rows: leftMatrix.rows)
            for i in 0..<Int(rightMatrix.columns) {
                for j in 0..<Int(leftMatrix.rows) {
                    var value = zeroValue(shaderModule, elementType)
                    for k in 0..<Int(leftMatrix.columns) {
                        let tmp = try constantMultiply(
                            shaderModule,
                            elementType,
                            [
                                leftMatrix.elements[k &* Int(leftMatrix.rows) &+ j],
                                rightMatrix.elements[i &* Int(rightMatrix.rows) &+ k],
                            ]
                        )
                        .get()
                        value = try constantAdd(shaderModule, elementType, [value, tmp]).get()
                    }
                    result.elements[i &* Int(result.rows) &+ j] = value
                }
            }
            return .matrix(result)
        }
    }
    if leftMatrix != nil || rightMatrix != nil {
        if case .vector(let rightVector) = arguments[1] {
            guard case .vector(let vectorType) = shaderModule.types[resultType] else {
                wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:600")
            }
            let elementType = vectorType.element
            guard let leftMatrix else {
                wgslFatal("a matrix times vector product whose left operand is not a matrix", cppSite: "ConstantFunctions.h:601")
            }
            let columns = leftMatrix.columns
            let rows = leftMatrix.rows
            return ConstantResult { () throws(ConstantFunctionError) in
                var result = ConstantVector(size: Int(rows))
                var leftVector = ConstantVector(size: Int(columns))
                for i in 0..<Int(rows) {
                    for j in 0..<Int(columns) {
                        leftVector.elements[j] = leftMatrix.elements[j &* Int(rows) &+ i]
                    }
                    result.elements[i] = try constantDot(shaderModule, elementType, [.vector(leftVector), .vector(rightVector)]).get()
                }
                return .vector(result)
            }
        }

        if case .vector(let leftVector) = arguments[0] {
            guard case .vector(let vectorType) = shaderModule.types[resultType] else {
                wgslFatal("std::get<Types::Vector> of a type that is not a vector", cppSite: "ConstantFunctions.h:614")
            }
            let elementType = vectorType.element
            guard let rightMatrix else {
                wgslFatal("a vector times matrix product whose right operand is not a matrix", cppSite: "ConstantFunctions.h:615")
            }
            let columns = rightMatrix.columns
            let rows = rightMatrix.rows
            return ConstantResult { () throws(ConstantFunctionError) in
                var result = ConstantVector(size: Int(columns))
                var rightVector = ConstantVector(size: Int(rows))
                for i in 0..<Int(columns) {
                    for j in 0..<Int(rows) {
                        rightVector.elements[j] = rightMatrix.elements[i &* Int(rows) &+ j]
                    }
                    result.elements[i] = try constantDot(shaderModule, elementType, [.vector(leftVector), .vector(rightVector)]).get()
                }
                return .vector(result)
            }
        }

        let matrix: ConstantMatrix
        let scalar: ConstantValue
        if let leftMatrix {
            matrix = leftMatrix
            scalar = arguments[1]
        } else {
            guard let rightMatrix else {
                wgslFatal("a matrix times scalar product without a matrix operand", cppSite: "ConstantFunctions.h:633")
            }
            matrix = rightMatrix
            scalar = arguments[0]
        }

        guard case .matrix(let matrixType) = shaderModule.types[resultType] else {
            wgslFatal("std::get<Types::Matrix> of a type that is not a matrix", cppSite: "ConstantFunctions.h:637")
        }
        let elementType = matrixType.element
        return ConstantResult { () throws(ConstantFunctionError) in
            var result = ConstantMatrix(columns: matrix.columns, rows: matrix.rows)
            for i in 0..<result.elements.count {
                result.elements[i] = try constantMultiply(shaderModule, elementType, [matrix.elements[i], scalar]).get()
            }
            return .matrix(result)
        }
    }

    return constantBinaryOperation(
        arguments,
        .number,
        i32: { left, right in .success(.int32(ConstInt.multiply(left, right))) },
        u32: { left, right in .success(.uint32(ConstInt.multiply(left, right))) },
        // i32 and u32 wrap on overflow, but AbstractInt has no width to wrap to.
        abstractInt: { left, right in integerResult(AbstractInt(left).multiplying(AbstractInt(right))) },
        f32: { (left: Float, right: Float) in finiteResult(left * right, .multiplyOverflow) },
        f16: { left, right in finiteResult(Half(Float(left) * Float(right)), .multiplyOverflow) },
        abstractFloat: { (left: Double, right: Double) in finiteResult(left * right, .multiplyOverflow) }
    )
}

func constantDivide(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    constantBinaryOperation(
        arguments,
        .number,
        i32: { left, right in integerResult(ConstInt.divide(left, right)) },
        u32: { left, right in integerResult(ConstInt.divide(left, right)) },
        abstractInt: { left, right in integerResult(ConstInt.divide(left, right)) },
        f32: { left, right in .success(.float(left / right)) },
        f16: { left, right in .success(.half(Half(Float(left) / Float(right)))) },
        abstractFloat: { left, right in .success(.double(left / right)) }
    )
}

func constantModulo(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    constantBinaryOperation(
        arguments,
        .number,
        i32: { left, right in integerResult(ConstInt.modulo(left, right)) },
        u32: { left, right in integerResult(ConstInt.modulo(left, right)) },
        abstractInt: { left, right in integerResult(ConstInt.modulo(left, right)) },
        f32: { left, right in .success(.float(cxxFmod(left, right))) },
        f16: { left, right in .success(.half(Half(cxxFmod(Float(left), Float(right))))) },
        abstractFloat: { left, right in .success(.double(cxxFmod(left, right))) }
    )
}

// Comparison Operations

func constantEqual(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .scalar,
        bool: { left, right in .success(.bool(left == right)) },
        i32: { left, right in .success(.bool(left == right)) },
        u32: { left, right in .success(.bool(left == right)) },
        abstractInt: { left, right in .success(.bool(left == right)) },
        f32: { left, right in .success(.bool(left == right)) },
        f16: { left, right in .success(.bool(Float(left) == Float(right))) },
        abstractFloat: { left, right in .success(.bool(left == right)) }
    )
}

func constantNotEqual(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .scalar,
        bool: { left, right in .success(.bool(left != right)) },
        i32: { left, right in .success(.bool(left != right)) },
        u32: { left, right in .success(.bool(left != right)) },
        abstractInt: { left, right in .success(.bool(left != right)) },
        f32: { left, right in .success(.bool(left != right)) },
        f16: { left, right in .success(.bool(Float(left) != Float(right))) },
        abstractFloat: { left, right in .success(.bool(left != right)) }
    )
}

func constantLt(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .scalar,
        bool: { left, right in .success(.bool(promoted(left) < promoted(right))) },
        i32: { left, right in .success(.bool(left < right)) },
        u32: { left, right in .success(.bool(left < right)) },
        abstractInt: { left, right in .success(.bool(left < right)) },
        f32: { left, right in .success(.bool(left < right)) },
        f16: { left, right in .success(.bool(Float(left) < Float(right))) },
        abstractFloat: { left, right in .success(.bool(left < right)) }
    )
}

func constantLtEq(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .scalar,
        bool: { left, right in .success(.bool(promoted(left) <= promoted(right))) },
        i32: { left, right in .success(.bool(left <= right)) },
        u32: { left, right in .success(.bool(left <= right)) },
        abstractInt: { left, right in .success(.bool(left <= right)) },
        f32: { left, right in .success(.bool(left <= right)) },
        f16: { left, right in .success(.bool(Float(left) <= Float(right))) },
        abstractFloat: { left, right in .success(.bool(left <= right)) }
    )
}

func constantGt(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .scalar,
        bool: { left, right in .success(.bool(promoted(left) > promoted(right))) },
        i32: { left, right in .success(.bool(left > right)) },
        u32: { left, right in .success(.bool(left > right)) },
        abstractInt: { left, right in .success(.bool(left > right)) },
        f32: { left, right in .success(.bool(left > right)) },
        f16: { left, right in .success(.bool(Float(left) > Float(right))) },
        abstractFloat: { left, right in .success(.bool(left > right)) }
    )
}

func constantGtEq(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .scalar,
        bool: { left, right in .success(.bool(promoted(left) >= promoted(right))) },
        i32: { left, right in .success(.bool(left >= right)) },
        u32: { left, right in .success(.bool(left >= right)) },
        abstractInt: { left, right in .success(.bool(left >= right)) },
        f32: { left, right in .success(.bool(left >= right)) },
        f16: { left, right in .success(.bool(Float(left) >= Float(right))) },
        abstractFloat: { left, right in .success(.bool(left >= right)) }
    )
}

// Logical Expressions

func constantNot(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantUnaryOperation(arguments, .bool, bool: { arg in .success(.bool(!arg)) })
}

func constantOr(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(arguments, .bool, bool: { left, right in .success(.bool(left || right)) })
}

func constantAnd(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    constantBinaryOperation(arguments, .bool, bool: { left, right in .success(.bool(left && right)) })
}

// Bit Expressions

func constantBitwiseOr(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    scalarOrVector(arguments[0], arguments[1]) { left, right in
        if case .bool(let leftBool) = left {
            guard case .bool(let rightBool) = right else {
                wgslFatal("std::get<bool> of a constant that is not a bool", cppSite: "ConstantFunctions.h:710")
            }
            return .success(.bool(promoted(leftBool) | promoted(rightBool) != 0))
        }
        if case .int32(let leftI32) = left {
            guard case .int32(let rightI32) = right else {
                wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:712")
            }
            return .success(.int32(leftI32 | rightI32))
        }
        if case .uint32(let leftU32) = left {
            guard case .uint32(let rightU32) = right else {
                wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:714")
            }
            return .success(.uint32(leftU32 | rightU32))
        }
        if case .int64(let leftAbstractInt) = left {
            guard case .int64(let rightAbstractInt) = right else {
                wgslFatal("std::get<int64_t> of a constant that is not an AbstractInt", cppSite: "ConstantFunctions.h:716")
            }
            return .success(.int64(leftAbstractInt | rightAbstractInt))
        }
        wgslFatal("BitwiseOr of a constant that is not a bool or an integer", cppSite: "ConstantFunctions.h:717")
    }
}

func constantBitwiseAnd(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    scalarOrVector(arguments[0], arguments[1]) { left, right in
        if case .bool(let leftBool) = left {
            guard case .bool(let rightBool) = right else {
                wgslFatal("std::get<bool> of a constant that is not a bool", cppSite: "ConstantFunctions.h:726")
            }
            return .success(.bool(promoted(leftBool) & promoted(rightBool) != 0))
        }
        if case .int32(let leftI32) = left {
            guard case .int32(let rightI32) = right else {
                wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "ConstantFunctions.h:728")
            }
            return .success(.int32(leftI32 & rightI32))
        }
        if case .uint32(let leftU32) = left {
            guard case .uint32(let rightU32) = right else {
                wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:730")
            }
            return .success(.uint32(leftU32 & rightU32))
        }
        if case .int64(let leftAbstractInt) = left {
            guard case .int64(let rightAbstractInt) = right else {
                wgslFatal("std::get<int64_t> of a constant that is not an AbstractInt", cppSite: "ConstantFunctions.h:732")
            }
            return .success(.int64(leftAbstractInt & rightAbstractInt))
        }
        wgslFatal("BitwiseAnd of a constant that is not a bool or an integer", cppSite: "ConstantFunctions.h:733")
    }
}

func constantBitwiseNot(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantUnaryOperation(
        arguments,
        .integer,
        i32: { arg in .success(.int32(~arg)) },
        u32: { arg in .success(.uint32(~arg)) },
        abstractInt: { arg in .success(.int64(~arg)) }
    )
}

func constantBitwiseXor(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    constantBinaryOperation(
        arguments,
        .integer,
        i32: { left, right in .success(.int32(left ^ right)) },
        u32: { left, right in .success(.uint32(left ^ right)) },
        abstractInt: { left, right in .success(.int64(left ^ right)) }
    )
}

func constantBitwiseShiftLeft(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    // We can't use a BINARY_OPERATION here since the arguments might not all have the same type
    // i.e. we accept (u32, u32) as well as (i32, u32)
    assert(arguments.count == 2)
    return scalarOrVector(arguments[0], arguments[1]) { left, rightValue in
        guard case .uint32(let right) = rightValue else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:777")
        }
        if case .int32(let i32) = left {
            return integerResult(ConstInt.shiftLeft(i32, right))
        }
        if case .uint32(let u32) = left {
            return integerResult(ConstInt.shiftLeft(u32, right))
        }
        if case .int64(let abstractInt) = left {
            return integerResult(ConstInt.shiftLeft(AbstractInt(abstractInt), right))
        }
        wgslFatal("BitwiseShiftLeft of a constant that is not an integer", cppSite: "ConstantFunctions.h:784")
    }
}

func constantBitwiseShiftRight(
    _ shaderModule: borrowing ShaderModule,
    _ resultType: TypeID,
    _ arguments: borrowing [ConstantValue]
) -> ConstantResult {
    // We can't use a BINARY_OPERATION here since the arguments might not all have the same type
    // i.e. we accept (u32, u32) as well as (i32, u32)
    assert(arguments.count == 2)
    return scalarOrVector(arguments[0], arguments[1]) { left, rightValue in
        guard case .uint32(let right) = rightValue else {
            wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "ConstantFunctions.h:808")
        }
        if case .int32(let i32) = left {
            return integerResult(ConstInt.shiftRight(i32, right))
        }
        if case .uint32(let u32) = left {
            return integerResult(ConstInt.shiftRight(u32, right))
        }
        if case .int64(let abstractInt) = left {
            return .success(.int64(ConstInt.shiftRight(AbstractInt(abstractInt), right).value))
        }
        wgslFatal("BitwiseShiftRight of a constant that is not an integer", cppSite: "ConstantFunctions.h:815")
    }
}

// Constructors

func constantBool(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    .success(constantConstructor(Bool.self, shaderModule, resultType, arguments))
}

func constantF32(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    .success(constantConstructor(Float.self, shaderModule, resultType, arguments))
}

func constantF16(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    .success(constantConstructor(Half.self, shaderModule, resultType, arguments))
}

func constantI32(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    if !arguments.isEmpty {
        if case .int64(let abstractInt) = arguments[0] {
            let result = convertInteger(Int32.self, abstractInt)
            if let result {
                return .success(.int32(result))
            }
            return .failure(ConstantFunctionError(message: "value \(abstractInt) cannot be represented as 'i32'"))
        }
    }

    return .success(constantConstructor(Int32.self, shaderModule, resultType, arguments))
}

func constantU32(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    if !arguments.isEmpty {
        if case .int64(let abstractInt) = arguments[0] {
            let result = convertInteger(UInt32.self, abstractInt)
            if let result {
                return .success(.uint32(result))
            }
            return .failure(ConstantFunctionError(message: "value \(abstractInt) cannot be represented as 'u32'"))
        }
    }

    return .success(constantConstructor(UInt32.self, shaderModule, resultType, arguments))
}

func constantVec2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    .success(constantVector(shaderModule, resultType, arguments, 2))
}

func constantVec3(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    .success(constantVector(shaderModule, resultType, arguments, 3))
}

func constantVec4(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    .success(constantVector(shaderModule, resultType, arguments, 4))
}

func constantMat2x2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 2, 2))
}

func constantMat2x3(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 2, 3))
}

func constantMat2x4(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 2, 4))
}

func constantMat3x2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 3, 2))
}

func constantMat3x3(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 3, 3))
}

func constantMat3x4(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 3, 4))
}

func constantMat4x2(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 4, 2))
}

func constantMat4x3(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 4, 3))
}

func constantMat4x4(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    .success(constantMatrix(shaderModule, resultType, arguments, 4, 4))
}

// Logical Built-in Functions

func constantAll(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 1)
    let arg = arguments[0]
    if arg.isBool {
        return .success(arg)
    }

    assert(arg.isVector)
    for element in arg.toVector().elements where !element.toBool() {
        return .success(.bool(false))
    }
    return .success(.bool(true))
}

func constantAny(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult {
    assert(arguments.count == 1)
    let arg = arguments[0]
    if arg.isBool {
        return .success(arg)
    }

    assert(arg.isVector)
    for element in arg.toVector().elements where element.toBool() {
        return .success(.bool(true))
    }
    return .success(.bool(false))
}

func constantSelect(_ shaderModule: borrowing ShaderModule, _ resultType: TypeID, _ arguments: borrowing [ConstantValue]) -> ConstantResult
{
    assert(arguments.count == 3)
    let falseValue = arguments[0]
    let trueValue = arguments[1]
    let condition = arguments[2]
    if condition.isBool {
        return .success(condition.toBool() ? trueValue : falseValue)
    }

    assert(falseValue.isVector)
    assert(trueValue.isVector)
    assert(condition.isVector)

    let falseVector = arguments[0].toVector()
    let trueVector = arguments[1].toVector()
    let conditionVector = arguments[2].toVector()

    let size = conditionVector.elements.count
    assert(size == falseVector.elements.count)
    assert(size == trueVector.elements.count)

    var result = ConstantVector(size: size)
    for i in 0..<size {
        result.elements[i] =
            conditionVector.elements[i].toBool()
            ? trueVector.elements[i]
            : falseVector.elements[i]
    }
    return .success(.vector(result))
}

// MARK: - Swift-only

/// `if (!std::isfinite(static_cast<double>(result))) return makeUnexpected(message);` then `return { { result } };`.
private func finiteResult(_ result: Float, _ error: ConstEvalError) -> ConstantResult {
    guard Double(result).isFinite else {
        return .failure(ConstantFunctionError(error))
    }
    return .success(.float(result))
}

private func finiteResult(_ result: Half, _ error: ConstEvalError) -> ConstantResult {
    guard Double(result).isFinite else {
        return .failure(ConstantFunctionError(error))
    }
    return .success(.half(result))
}

private func finiteResult(_ result: Double, _ error: ConstEvalError) -> ConstantResult {
    guard result.isFinite else {
        return .failure(ConstantFunctionError(error))
    }
    return .success(.double(result))
}

/// A `ConstInt` or `AbstractInt` lambda result as a `ConstantResult`.
private func integerResult<T: ConstantScalar>(_ result: Result<T, ConstEvalError>) -> ConstantResult {
    switch result {
    case .success(let value):
        .success(value.constantValue)
    case .failure(let error):
        .failure(ConstantFunctionError(error))
    }
}

private func integerResult(_ result: Result<AbstractInt, ConstEvalError>) -> ConstantResult {
    switch result {
    case .success(let value):
        .success(.int64(value.value))
    case .failure(let error):
        .failure(ConstantFunctionError(error))
    }
}

/// The integral promotion of a `bool` operand in C++ (`false` is 0, `true` is 1).
private func promoted(_ value: Bool) -> Int32 {
    value ? 1 : 0
}
