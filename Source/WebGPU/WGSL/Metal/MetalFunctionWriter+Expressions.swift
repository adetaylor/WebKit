// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

extension FunctionDefinitionWriter {
    /// C++ `visit(const Type*, AST::CallExpression&)`.
    mutating func visitCallExpression(_ type: TypeID?, _ call: CallExpression, _ id: ExpressionID) {
        if let target = shaderModule.dynamicDowncast(ElaboratedTypeExpression.self, call.target) {
            let bitcast = bitcastName
            if equal(shaderModule.symbols, shaderModule.symbol(of: target.base), bitcast) {
                emitBitcast(call, id)
                return
            }
        }

        let isArray =
            call.isConstructor && shaderModule.types.getIf(Types.Array.self, nonNull(type, cppSite: "MetalFunctionWriter.cpp:2780")) != nil
        let isStruct =
            call.isConstructor && !isArray
            && shaderModule.types.getIf(
                Types.Struct.self,
                nonNull(shaderModule.inferredType(of: call.target), cppSite: "MetalFunctionWriter.cpp:2781")
            ) != nil
        if isArray || isStruct {
            printValueType(nonNull(type, cppSite: "MetalFunctionWriter.cpp:2783"))
            body.append("(")
            var arrayElementType: TypeID?
            if isArray {
                arrayElementType = shaderModule.types.getIf(Types.Array.self, type)?.element
            }

            body.append("{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                var arguments = shaderModule.cursor(call.arguments)
                while let argument = shaderModule.next(&arguments) {
                    body.append(indent)
                    if isStruct {
                        visit(argument)
                    } else {
                        visitExpression(arrayElementType, argument)
                    }
                    body.append(",\n")
                }
            }
            body.append(indent)
            body.append("})")
            return
        }

        if let target = shaderModule.dynamicDowncast(IdentifierExpression.self, call.target) {
            let targetName = shaderModule.symbol(of: target.identifier)
            if let mappedBuiltin = builtinEmitter(targetName, shaderModule.symbols) {
                emitBuiltin(mappedBuiltin, call, id)
                return
            }

            if call.isConstructor {
                printConstructorTarget(
                    nonNull(type, cppSite: "MetalFunctionWriter.cpp:2955"),
                    isFloatToIntConversion: shaderModule.isFloatToIntConversion(id)
                )
            } else if let mappedName = mappedName(targetName) {
                body.append(emitMappedName(mappedName, call))
            } else {
                if shaderModule.count(call.arguments) != 0 {
                    let pack = packName
                    let unpack = unpackName
                    if equal(shaderModule.symbols, targetName, pack) {
                        usePackingHelper(.pack, shaderModule.inferredType(of: shaderModule[call.arguments, 0]))
                    } else if equal(shaderModule.symbols, targetName, unpack) {
                        usePackingHelper(.unpack, shaderModule.inferredType(of: shaderModule[call.arguments, 0]))
                    }
                }
                body.append(identifier: targetName, in: shaderModule.symbols)
            }
            visitArguments(call)
            return
        }

        printConstructorTarget(
            nonNull(type, cppSite: "MetalFunctionWriter.cpp:2976"),
            isFloatToIntConversion: shaderModule.isFloatToIntConversion(id)
        )
        visitArguments(call)
    }

    mutating func visit(_ unary: UnaryExpression, _ id: ExpressionID) {
        body.append("(")
        switch unary.operation {
        case .complement:
            body.append("~")
        case .negate:
            body.append("-")
        case .not:
            body.append("!")
        case .addressOf:
            body.append("&")
        case .dereference:
            body.append("*")
        }
        visit(unary.expression)
        body.append(")")
    }

    /// The spelling comes from `emission(for:rhs:helpers:)`.
    mutating func serializeBinaryExpression(_ lhs: ExpressionID, _ operation: BinaryOperation, _ rhs: ExpressionID) {
        let rightClass = ScalarClass(rightOperandType: shaderModule.inferredType(of: rhs), in: shaderModule.types)
        switch emission(for: operation, rhs: rightClass, helpers: shaderModule.uses) {
        case .call(let helperFunction):
            body.append(helperFunction)
            body.append("(")
            visit(lhs)
            body.append(", ")
            visit(rhs)
            body.append(")")
        case .infix(let infixOperator):
            body.append("(")
            visit(lhs)
            body.append(infixOperator)
            visit(rhs)
            body.append(")")
        }
    }

    mutating func visit(_ binary: BinaryExpression, _ id: ExpressionID) {
        serializeBinaryExpression(binary.leftExpression, binary.operation, binary.rightExpression)
    }

    mutating func visit(_ pointerDereference: PointerDereferenceExpression, _ id: ExpressionID) {
        body.append("(*")
        visit(pointerDereference.target)
        body.append(")")
    }

    /// An unchecked access never reaches the writer: BoundsCheck converts every access it visits, and accesses inside `override`
    /// declarations are never printed.
    mutating func visit(_ access: IndexAccessExpression, _ id: ExpressionID) {
        wgslFatal("unchecked index access reached the writer", cppSite: "BoundsCheck.cpp invariant")
    }

    /// C++ `visit(AST::IndexAccessExpression&)`: every access BoundsCheck justified.
    mutating func visit(_ access: CheckedIndexAccessExpression, _ id: ExpressionID) {
        // DEV-03: a chain of accesses, each the base of the one before it (the zero-initialization of a nested array,
        // GlobalVariableRewriter.cpp:2660), is written with a loop where the C++ recurses through the bases: the prefixes outermost
        // first, the innermost base, then the subscripts innermost first.
        let base = indexAccessChain.count
        var current = access
        while true {
            let baseType = nonNull(shaderModule.inferredType(of: current.base), cppSite: "MetalFunctionWriter.cpp:3112")
            let isPointer = shaderModule.types.getIf(Types.Pointer.self, baseType) != nil

            var isPackedMatrix = false
            do {
                var elementType: TypeID?
                if let ref = shaderModule.types.getIf(Types.Reference.self, baseType) {
                    if ref.addressSpace == .storage || ref.addressSpace == .uniform {
                        elementType = ref.element
                    }
                } else if let ptr = shaderModule.types.getIf(Types.Pointer.self, baseType) {
                    if ptr.addressSpace == .storage || ptr.addressSpace == .uniform {
                        elementType = ptr.element
                    }
                }
                if let elementType {
                    if let matrix = shaderModule.types.getIf(Types.Matrix.self, elementType) {
                        isPackedMatrix = matrix.rows == 3
                    }
                }
            }

            if isPointer {
                body.append("(*(")
            }
            indexAccessChain.append(
                IndexAccessSuffix(isPointer: isPointer, isPackedMatrix: isPackedMatrix, proof: current.proof, index: current.index)
            )
            guard let nested = directlyWrittenAccess(current.base) else {
                break
            }
            current = nested
        }
        visit(current.base)
        while indexAccessChain.count > base {
            let suffix = indexAccessChain.removeLast()
            if suffix.isPointer {
                body.append("))")
            }
            if suffix.isPackedMatrix {
                body.append(".columns")
            }
            let openSubscript = body.emitSubscript(suffix.proof)
            visit(suffix.index)
            body.closeSubscript(openSubscript)
        }
    }

    /// The access `visit(expression)` writes with nothing before it: not a constant, not behind a call or identity expression.
    private mutating func directlyWrittenAccess(_ expression: ExpressionID) -> CheckedIndexAccessExpression? {
        guard !hasError, shaderModule.constantValueForWriter(expression) == nil,
            case .checkedIndexAccessExpression(let access) = shaderModule[expression].kind
        else {
            return nil
        }
        return access
    }

    mutating func visit(_ identifier: IdentifierExpression, _ id: ExpressionID) {
        if !constantValues.isEmpty,
            let value = constantValues.find(shaderModule.symbols.cachedName(of: shaderModule.symbol(of: identifier.identifier)))
        {
            body.append("(")
            serializeConstant(shaderModule.inferredType(of: id), value)
            body.append(")")
            return
        }
        body.append(identifier: shaderModule.symbol(of: identifier.identifier), in: shaderModule.symbols)
    }

    mutating func visit(_ access: FieldAccessExpression, _ id: ExpressionID) {
        visit(access.base)
        let baseType = shaderModule.inferredType(of: access.base)
        if shaderModule.types.getIf(Types.Pointer.self, baseType) != nil {
            body.append("->")
        } else {
            body.append(".")
        }
        body.append(identifier: shaderModule.symbol(of: access.fieldName), in: shaderModule.symbols)
    }

    mutating func visit(_ literal: BoolLiteral, _ id: ExpressionID) {
        body.append(literal.value ? "true" : "false")
    }

    mutating func visit(_ literal: AbstractIntegerLiteral, _ id: ExpressionID) {
        body.append(MSLNumber.abstractInt(literal.value))
        guard let primitiveType = shaderModule.types.getIf(Types.Primitive.self, shaderModule.inferredType(of: id)) else {
            wgslFatal("std::get<Types::Primitive> of an integer literal's type", cppSite: "MetalFunctionWriter.cpp:3173")
        }
        if primitiveType.kind == .u32 {
            body.append("u")
        }
    }

    mutating func visit(_ literal: Signed32Literal, _ id: ExpressionID) {
        body.append(MSLNumber.i32(literal.value))
    }

    mutating func visit(_ literal: Unsigned32Literal, _ id: ExpressionID) {
        body.append(MSLNumber.u32(literal.value))
    }

    mutating func visit(_ literal: AbstractFloatLiteral, _ id: ExpressionID) {
        body.append(MSLNumber.abstractFloat(literal.value))
    }

    mutating func visit(_ literal: Float32Literal, _ id: ExpressionID) {
        body.append(MSLNumber.f32(literal.value))
    }

    mutating func visit(_ literal: Float16Literal, _ id: ExpressionID) {
        body.append(MSLNumber.f16(literal.value))
    }
}

// MARK: - The call-target tables of visitCallExpression

extension FunctionDefinitionWriter {
    /// C++ `mappedBuiltin(this, call)`.
    private mutating func emitBuiltin(_ builtin: BuiltinEmitter, _ call: CallExpression, _ id: ExpressionID) {
        switch builtin {
        case .dynamicOffset:
            emitDynamicOffset(call, id)
        case .arrayLength:
            emitArrayLength(call, id)
        case .atomicAdd:
            emitAtomicAdd(call, id)
        case .atomicAnd:
            emitAtomicAnd(call, id)
        case .atomicExchange:
            emitAtomicExchange(call, id)
        case .atomicLoad:
            emitAtomicLoad(call, id)
        case .atomicMax:
            emitAtomicMax(call, id)
        case .atomicMin:
            emitAtomicMin(call, id)
        case .atomicOr:
            emitAtomicOr(call, id)
        case .atomicStore:
            emitAtomicStore(call, id)
        case .atomicSub:
            emitAtomicSub(call, id)
        case .atomicXor:
            emitAtomicXor(call, id)
        case .degrees:
            emitDegrees(call, id)
        case .distance:
            emitDistance(call, id)
        case .length:
            emitLength(call, id)
        case .pack2x16float:
            emitPack2x16Float(call, id)
        case .pack4xI8:
            emitPack4xI8(call, id)
        case .pack4xI8Clamp:
            emitPack4xI8Clamp(call, id)
        case .pack4xU8:
            emitPack4xU8(call, id)
        case .pack4xU8Clamp:
            emitPack4xU8Clamp(call, id)
        case .quadSwapDiagonal:
            emitQuadSwapDiagonal(call, id)
        case .quadSwapX:
            emitQuadSwapX(call, id)
        case .quadSwapY:
            emitQuadSwapY(call, id)
        case .quantizeToF16:
            emitQuantizeToF16(call, id)
        case .radians:
            emitRadians(call, id)
        case .storageBarrier:
            emitStorageBarrier(call, id)
        case .subgroupBallot:
            emitSubgroupBallot(call, id)
        case .textureBarrier:
            emitTextureBarrier(call, id)
        case .textureDimensions:
            emitTextureDimensions(call, id)
        case .textureGather:
            emitTextureGather(call, id)
        case .textureGatherCompare:
            emitTextureGatherCompare(call, id)
        case .textureLoad:
            emitTextureLoad(call, id)
        case .textureNumLayers:
            emitTextureNumLayers(call, id)
        case .textureNumLevels:
            emitTextureNumLevels(call, id)
        case .textureNumSamples:
            emitTextureNumSamples(call, id)
        case .textureSample:
            emitTextureSample(call, id)
        case .textureSampleBias:
            emitTextureSampleBias(call, id)
        case .textureSampleCompare:
            emitTextureSampleCompare(call, id)
        case .textureSampleCompareLevel:
            emitTextureSampleCompareLevel(call, id)
        case .textureSampleGrad:
            emitTextureSampleGrad(call, id)
        case .textureSampleLevel:
            emitTextureSampleLevel(call, id)
        case .textureStore:
            emitTextureStore(call, id)
        case .unpack2x16float:
            emitUnpack2x16Float(call, id)
        case .unpack4xI8:
            emitUnpack4xI8(call, id)
        case .unpack4xU8:
            emitUnpack4xU8(call, id)
        case .workgroupBarrier:
            emitWorkgroupBarrier(call, id)
        case .workgroupUniformLoad:
            emitWorkgroupUniformLoad(call, id)
        }
    }

    /// C++ `mappedName(m_helperGenerator, call)`: the MSL name, after emitting the helper it names the first time.
    private mutating func emitMappedName(_ mappedName: MappedName, _ call: CallExpression) -> MSLText {
        switch mappedName {
        case .helper(let helper):
            return emitHelper(helper)
        case .name(let name):
            return name
        case .textureSampleBaseClampToEdge:
            let texture = shaderModule[call.arguments, 0]
            let textureType = nonNull(shaderModule.inferredType(of: texture), cppSite: "MetalFunctionWriter.cpp:2928")
            if shaderModule.types.getIf(Types.Texture.self, textureType) != nil {
                if !helperGenerator.didEmitTextureSampleBaseClampToEdge {
                    helperGenerator.didEmitTextureSampleBaseClampToEdge = true
                    helperGenerator.emitTextureSampleBaseClampToEdge()
                }
            } else {
                if !helperGenerator.didEmitTextureExternalSampleBaseClampToEdge {
                    helperGenerator.didEmitTextureExternalSampleBaseClampToEdge = true
                    helperGenerator.emitTextureExternalSampleBaseClampToEdge()
                }
            }
            return "__wgslTextureSampleBaseClampToEdge"
        }
    }

    /// C++ `EMIT_HELPER(name)`.
    private mutating func emitHelper(_ helper: EmittedHelper) -> MSLText {
        switch helper {
        case .acos:
            if !helperGenerator.didEmitAcos {
                helperGenerator.didEmitAcos = true
                helperGenerator.emitAcos()
            }
            return "__wgslAcos"
        case .acosh:
            if !helperGenerator.didEmitAcosh {
                helperGenerator.didEmitAcosh = true
                helperGenerator.emitAcosh()
            }
            return "__wgslAcosh"
        case .asin:
            if !helperGenerator.didEmitAsin {
                helperGenerator.didEmitAsin = true
                helperGenerator.emitAsin()
            }
            return "__wgslAsin"
        case .atanh:
            if !helperGenerator.didEmitAtanh {
                helperGenerator.didEmitAtanh = true
                helperGenerator.emitAtanh()
            }
            return "__wgslAtanh"
        case .inverseSqrt:
            if !helperGenerator.didEmitInverseSqrt {
                helperGenerator.didEmitInverseSqrt = true
                helperGenerator.emitInverseSqrt()
            }
            return "__wgslInverseSqrt"
        case .log:
            if !helperGenerator.didEmitLog {
                helperGenerator.didEmitLog = true
                helperGenerator.emitLog()
            }
            return "__wgslLog"
        case .log2:
            if !helperGenerator.didEmitLog2 {
                helperGenerator.didEmitLog2 = true
                helperGenerator.emitLog2()
            }
            return "__wgslLog2"
        case .packFloatToSnorm2x16:
            if !helperGenerator.didEmitPackFloatToSnorm2x16 {
                helperGenerator.didEmitPackFloatToSnorm2x16 = true
                helperGenerator.emitPackFloatToSnorm2x16()
            }
            return "__wgslPackFloatToSnorm2x16"
        case .packFloatToUnorm2x16:
            if !helperGenerator.didEmitPackFloatToUnorm2x16 {
                helperGenerator.didEmitPackFloatToUnorm2x16 = true
                helperGenerator.emitPackFloatToUnorm2x16()
            }
            return "__wgslPackFloatToUnorm2x16"
        case .packFloatToSnorm4x8:
            if !helperGenerator.didEmitPackFloatToSnorm4x8 {
                helperGenerator.didEmitPackFloatToSnorm4x8 = true
                helperGenerator.emitPackFloatToSnorm4x8()
            }
            return "__wgslPackFloatToSnorm4x8"
        case .packFloatToUnorm4x8:
            if !helperGenerator.didEmitPackFloatToUnorm4x8 {
                helperGenerator.didEmitPackFloatToUnorm4x8 = true
                helperGenerator.emitPackFloatToUnorm4x8()
            }
            return "__wgslPackFloatToUnorm4x8"
        case .sqrt:
            if !helperGenerator.didEmitSqrt {
                helperGenerator.didEmitSqrt = true
                helperGenerator.emitSqrt()
            }
            return "__wgslSqrt"
        }
    }
}

/// An entry of the C++ `builtins` table (MetalFunctionWriter.cpp:2805-2853): the builtin's emitter.
private enum BuiltinEmitter {
    case dynamicOffset
    case arrayLength
    case atomicAdd
    case atomicAnd
    case atomicExchange
    case atomicLoad
    case atomicMax
    case atomicMin
    case atomicOr
    case atomicStore
    case atomicSub
    case atomicXor
    case degrees
    case distance
    case length
    case pack2x16float
    case pack4xI8
    case pack4xI8Clamp
    case pack4xU8
    case pack4xU8Clamp
    case quadSwapDiagonal
    case quadSwapX
    case quadSwapY
    case quantizeToF16
    case radians
    case storageBarrier
    case subgroupBallot
    case textureBarrier
    case textureDimensions
    case textureGather
    case textureGatherCompare
    case textureLoad
    case textureNumLayers
    case textureNumLevels
    case textureNumSamples
    case textureSample
    case textureSampleBias
    case textureSampleCompare
    case textureSampleCompareLevel
    case textureSampleGrad
    case textureSampleLevel
    case textureStore
    case unpack2x16float
    case unpack4xI8
    case unpack4xU8
    case workgroupBarrier
    case workgroupUniformLoad
}

/// The helpers C++ `EMIT_HELPER` names.
private enum EmittedHelper {
    case acos
    case acosh
    case asin
    case atanh
    case inverseSqrt
    case log
    case log2
    case packFloatToSnorm2x16
    case packFloatToUnorm2x16
    case packFloatToSnorm4x8
    case packFloatToUnorm4x8
    case sqrt
}

/// An entry of the C++ `mappedNames` table (MetalFunctionWriter.cpp:2871-2944).
private enum MappedName {
    /// C++ `EMIT_HELPER`: the `__wgsl<Name>` helper, emitted into the output the first time it is named.
    case helper(EmittedHelper)
    /// C++ `NOOP_HELPER`.
    case name(MSLText)
    case textureSampleBaseClampToEdge
}

/// C++ `builtins`, in its order; `__dynamicOffset` is reserved, not predeclared, so builtinEmitter matches it by text.
private let builtinEmitters: [(name: BuiltinSymbols, emitter: BuiltinEmitter)] = [
    (.arrayLength, .arrayLength),
    (.atomicAdd, .atomicAdd),
    (.atomicAnd, .atomicAnd),
    (.atomicExchange, .atomicExchange),
    (.atomicLoad, .atomicLoad),
    (.atomicMax, .atomicMax),
    (.atomicMin, .atomicMin),
    (.atomicOr, .atomicOr),
    (.atomicStore, .atomicStore),
    (.atomicSub, .atomicSub),
    (.atomicXor, .atomicXor),
    (.degrees, .degrees),
    (.distance, .distance),
    (.length, .length),
    (.pack2x16float, .pack2x16float),
    (.pack4xI8, .pack4xI8),
    (.pack4xI8Clamp, .pack4xI8Clamp),
    (.pack4xU8, .pack4xU8),
    (.pack4xU8Clamp, .pack4xU8Clamp),
    (.quadSwapDiagonal, .quadSwapDiagonal),
    (.quadSwapX, .quadSwapX),
    (.quadSwapY, .quadSwapY),
    (.quantizeToF16, .quantizeToF16),
    (.radians, .radians),
    (.storageBarrier, .storageBarrier),
    (.subgroupBallot, .subgroupBallot),
    (.textureBarrier, .textureBarrier),
    (.textureDimensions, .textureDimensions),
    (.textureGather, .textureGather),
    (.textureGatherCompare, .textureGatherCompare),
    (.textureLoad, .textureLoad),
    (.textureNumLayers, .textureNumLayers),
    (.textureNumLevels, .textureNumLevels),
    (.textureNumSamples, .textureNumSamples),
    (.textureSample, .textureSample),
    (.textureSampleBias, .textureSampleBias),
    (.textureSampleCompare, .textureSampleCompare),
    (.textureSampleCompareLevel, .textureSampleCompareLevel),
    (.textureSampleGrad, .textureSampleGrad),
    (.textureSampleLevel, .textureSampleLevel),
    (.textureStore, .textureStore),
    (.unpack2x16float, .unpack2x16float),
    (.unpack4xI8, .unpack4xI8),
    (.unpack4xU8, .unpack4xU8),
    (.workgroupBarrier, .workgroupBarrier),
    (.workgroupUniformLoad, .workgroupUniformLoad),
]

/// C++ `mappedNames`, in its order.
private let mappedNameEntries: [(name: BuiltinSymbols, mappedName: MappedName)] = [
    (.acos, .helper(.acos)),
    (.acosh, .helper(.acosh)),
    (.asin, .helper(.asin)),
    (.atanh, .helper(.atanh)),
    (.atomicCompareExchangeWeak, .name("__wgslAtomicCompareExchangeWeak")),
    (.countLeadingZeros, .name("clz")),
    (.countOneBits, .name("popcount")),
    (.countTrailingZeros, .name("ctz")),
    (.dot, .name("__wgslDot")),
    (.dot4I8Packed, .name("__wgslDot4I8Packed")),
    (.dot4U8Packed, .name("__wgslDot4U8Packed")),
    (.dpdx, .name("dfdx")),
    (.dpdxCoarse, .name("dfdx")),
    (.dpdxFine, .name("dfdx")),
    (.dpdy, .name("dfdy")),
    (.dpdyCoarse, .name("dfdy")),
    (.dpdyFine, .name("dfdy")),
    (.extractBits, .name("__wgslExtractBits")),
    (.faceForward, .name("faceforward")),
    (.firstLeadingBit, .name("__wgslFirstLeadingBit")),
    (.firstTrailingBit, .name("__wgslFirstTrailingBit")),
    (.frexp, .name("__wgslFrexp")),
    (.fwidthCoarse, .name("fwidth")),
    (.fwidthFine, .name("fwidth")),
    (.insertBits, .name("__wgslInsertBits")),
    (.inverseSqrt, .helper(.inverseSqrt)),
    (.log, .helper(.log)),
    (.log2, .helper(.log2)),
    (.modf, .name("__wgslModf")),
    (.pack2x16snorm, .helper(.packFloatToSnorm2x16)),
    (.pack2x16unorm, .helper(.packFloatToUnorm2x16)),
    (.pack4x8snorm, .helper(.packFloatToSnorm4x8)),
    (.pack4x8unorm, .helper(.packFloatToUnorm4x8)),
    (.quadBroadcast, .name("quad_broadcast")),
    (.reverseBits, .name("reverse_bits")),
    (.round, .name("rint")),
    (.sign, .name("__wgslSign")),
    (.sqrt, .helper(.sqrt)),
    (.subgroupAdd, .name("simd_sum")),
    (.subgroupAll, .name("simd_all")),
    (.subgroupAnd, .name("simd_and")),
    (.subgroupAny, .name("simd_any")),
    (.subgroupBroadcast, .name("simd_broadcast")),
    (.subgroupBroadcastFirst, .name("simd_broadcast_first")),
    (.subgroupElect, .name("simd_is_first")),
    (.subgroupExclusiveAdd, .name("simd_prefix_exclusive_sum")),
    (.subgroupExclusiveMul, .name("simd_prefix_exclusive_product")),
    (.subgroupInclusiveAdd, .name("simd_prefix_inclusive_sum")),
    (.subgroupInclusiveMul, .name("simd_prefix_inclusive_product")),
    (.subgroupMax, .name("simd_max")),
    (.subgroupMin, .name("simd_min")),
    (.subgroupMul, .name("simd_product")),
    (.subgroupOr, .name("simd_or")),
    (.subgroupShuffle, .name("simd_shuffle")),
    (.subgroupShuffleDown, .name("simd_shuffle_down")),
    (.subgroupShuffleUp, .name("simd_shuffle_up")),
    (.subgroupShuffleXor, .name("simd_shuffle_xor")),
    (.subgroupXor, .name("simd_xor")),
    (.textureSampleBaseClampToEdge, .textureSampleBaseClampToEdge),
    (.unpack2x16snorm, .name("unpack_snorm2x16_to_float")),
    (.unpack2x16unorm, .name("unpack_unorm2x16_to_float")),
    (.unpack4x8snorm, .name("unpack_snorm4x8_to_float")),
    (.unpack4x8unorm, .name("unpack_unorm4x8_to_float")),
]

/// `builtinEmitters` and `mappedNameEntries` indexed by predeclared symbol, made once per process.
private struct CallTargetTables: Sendable {
    var builtins: [BuiltinEmitter?]
    var mappedNames: [MappedName?]

    init() {
        builtins = Array(repeating: nil, count: predeclaredSymbolNames.count)
        var index = 0
        while index < builtinEmitters.count {
            builtins[Int(builtinEmitters[index].name.rawValue)] = builtinEmitters[index].emitter
            index &+= 1
        }
        mappedNames = Array(repeating: nil, count: predeclaredSymbolNames.count)
        index = 0
        while index < mappedNameEntries.count {
            mappedNames[Int(mappedNameEntries[index].name.rawValue)] = mappedNameEntries[index].mappedName
            index &+= 1
        }
    }
}

private let callTargetTables = CallTargetTables()

private let bitcastName = ContiguousArray("bitcast".utf16)
private let dynamicOffsetName = ContiguousArray(ReservedName.Fixed.dynamicOffset.spelling.description.utf16)
private let packName = ContiguousArray(ReservedName.Fixed.pack.spelling.description.utf16)
private let unpackName = ContiguousArray(ReservedName.Fixed.unpack.spelling.description.utf16)

/// C++ `builtins.get(targetName)`.
private func builtinEmitter(_ targetName: Symbol, _ symbols: borrowing SymbolTable) -> BuiltinEmitter? {
    guard let index = targetName.predeclaredIndex else {
        let dynamicOffset = dynamicOffsetName
        return equal(symbols, targetName, dynamicOffset) ? .dynamicOffset : nil
    }
    return callTargetTables.builtins[index]
}

/// C++ `mappedNames.get(targetName)`.
private func mappedName(_ targetName: Symbol) -> MappedName? {
    guard let index = targetName.predeclaredIndex else {
        return nil
    }
    return callTargetTables.mappedNames[index]
}

/// WTF `String == ASCIILiteral` on a symbol's code units.
private func equal(_ symbols: borrowing SymbolTable, _ symbol: Symbol, _ text: borrowing ContiguousArray<UInt16>) -> Bool {
    let length = symbols.length(of: symbol)
    guard length == text.count else {
        return false
    }
    var index = 0
    while index < length {
        guard symbols.codeUnit(of: symbol, at: index) == text[index] else {
            return false
        }
        index &+= 1
    }
    return true
}

/// C++ `*type`: the writer never meets a null type there, and C++ would crash on one.
private func nonNull(_ type: TypeID?, cppSite: StaticString) -> TypeID {
    guard let type else {
        wgslFatal("a null type was dereferenced", cppSite: cppSite)
    }
    return type
}

/// What `visit(CheckedIndexAccessExpression)` writes after an access's base.
struct IndexAccessSuffix {
    let isPointer: Bool
    let isPackedMatrix: Bool
    let proof: SubscriptProof
    let index: ExpressionID
}
