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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

extension TypeChecker {
    // Expressions
    @inline(never)
    mutating func visit(_ expression: ExpressionID) throws(CompilationMessage) {
        // DEV-04: the second inference of a `&&`/`||` left operand (chooseOverload's) reuses binaryExpression's.
        if let leftOperand = inferredLeftOperand {
            inferredLeftOperand = nil
            if leftOperand == expression {
                guard let type = shaderModule.inferredType(of: expression) else {
                    coldFatal("the memoised left operand has no inferred type", cppSite: "TypeCheck.cpp:1435")
                }
                inferred(type)
                evaluated(inferredEvaluation(of: expression, shaderModule))
                return
            }
        }

        switch shaderModule.tag(of: expression) {
        case .abstractFloatLiteral:
            visitAbstractFloatLiteralPayload(expression)
        case .abstractIntegerLiteral:
            visitAbstractIntegerLiteralPayload(expression)
        case .boolLiteral:
            visitBoolLiteralPayload(expression)
        case .float32Literal:
            visitFloat32LiteralPayload(expression)
        case .float16Literal:
            visitFloat16LiteralPayload(expression)
        case .signed32Literal:
            visitSigned32LiteralPayload(expression)
        case .unsigned32Literal:
            visitUnsigned32LiteralPayload(expression)

        case .binaryExpression:
            try visitBinaryExpressionPayload(expression)
        case .callExpression:
            try visitCallExpressionPayload(expression)
        case .fieldAccessExpression:
            try visitFieldAccessExpressionPayload(expression)
        case .identifierExpression:
            try visitIdentifierExpressionPayload(expression)
        case .indexAccessExpression:
            try visitIndexAccessExpressionPayload(expression)
        case .unaryExpression:
            try visitUnaryExpressionPayload(expression)
        case .arrayTypeExpression:
            try visitArrayTypeExpressionPayload(expression)
        case .elaboratedTypeExpression:
            try visitElaboratedTypeExpressionPayload(expression)

        case .identityExpression, .checkedIndexAccessExpression, .pointerDereferenceExpression, .referenceTypeExpression:
            visitUnexpectedExpression()
        }
    }

    mutating func visit(_ access: FieldAccessExpression, _ id: ExpressionID) throws(CompilationMessage) {
        func accessImpl(_ baseType: TypeID, _ canBeReference: inout Bool, _ isVector: inout Bool) throws(CompilationMessage) -> TypeID {
            if let structType = shaderModule.types.getIf(Types.Struct.self, baseType) {
                let fieldName = shaderModule.symbol(of: access.fieldName)
                guard let fieldType = shaderModule.types.fields(of: structType.fields).find(fieldName) else {
                    throw CompilationMessage(
                        text:
                            "struct '\(typeString(baseType))' does not have a member called '\(shaderModule.symbols.text(of: fieldName))'",
                        span: shaderModule.span(of: id)
                    )
                }

                if let constant = constantValue(of: access.base) {
                    guard case .struct(let constantStruct) = constant else {
                        coldFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "TypeCheck.cpp:1283")
                    }
                    shaderModule.setConstantValue(constantStruct.get(fieldName), for: id)
                }
                return fieldType
            }

            if let primitiveStruct = shaderModule.types.getIf(Types.PrimitiveStruct.self, baseType) {
                let keys = Types.PrimitiveStruct.keys(primitiveStruct.kind)
                let fieldName = shaderModule.symbol(of: access.fieldName)
                guard let key = keys.tryGet(fieldName) else {
                    throw CompilationMessage(
                        text:
                            "struct '\(typeString(baseType))' does not have a member called '\(shaderModule.symbols.text(of: fieldName))'",
                        span: shaderModule.span(of: id)
                    )
                }

                if let constant = constantValue(of: access.base) {
                    guard case .struct(let constantStruct) = constant else {
                        coldFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "TypeCheck.cpp:1296")
                    }
                    shaderModule.setConstantValue(constantStruct.get(fieldName), for: id)
                }

                return shaderModule.types[primitiveStruct.values, key]
            }

            if let vector = shaderModule.types.getIf(Types.Vector.self, baseType) {
                let result = try vectorFieldAccess(vector, access, id)
                isVector = true
                canBeReference = shaderModule.types.getIf(Types.Vector.self, result) == nil
                return result
            }

            throw CompilationMessage(
                text: "invalid member access expression. Expected vector or struct, got '\(typeString(baseType))'",
                span: shaderModule.span(of: id)
            )
        }

        func referenceImpl(_ addressSpace: AddressSpace, _ element: TypeID, _ accessMode: AccessMode) throws(CompilationMessage) {
            var canBeReference = true
            var isVector = false

            var result = try accessImpl(element, &canBeReference, &isVector)

            if canBeReference {
                result = shaderModule.types.referenceType(addressSpace, result, accessMode, isVectorComponent: isVector)
            }

            inferred(result)
            evaluated(inferredEvaluation(of: access.base, shaderModule))
        }

        let baseType = try infer(access.base, maxEvaluation)

        // Out of line, so that the frame recursing through `infer` does not hold the locals of the rest.
        @inline(never)
        func resultImpl() throws(CompilationMessage) {
            if let reference = shaderModule.types.getIf(Types.Reference.self, baseType) {
                return try referenceImpl(reference.addressSpace, reference.element, reference.accessMode)
            }

            if let pointer = shaderModule.types.getIf(Types.Pointer.self, baseType) {
                return try referenceImpl(pointer.addressSpace, pointer.element, pointer.accessMode)
            }

            // C++ passes no out-parameters here.
            var canBeReference = true
            var isVector = false
            let result = try accessImpl(baseType, &canBeReference, &isVector)
            inferred(result)
            evaluated(inferredEvaluation(of: access.base, shaderModule))
        }
        try resultImpl()
    }

    mutating func visit(_ access: IndexAccessExpression, _ id: ExpressionID) throws(CompilationMessage) {
        func constantAccess(_ alternative: ConstantAccessAlternative, _ typeSize: UInt32?) throws(CompilationMessage) {
            guard let constantIndex = constantValue(of: access.index) else {
                return
            }
            let constantBase = constantValue(of: access.base)

            var size = typeSize ?? 0
            if size == 0, let constantBase {
                size = UInt32(truncatingIfNeeded: alternative.get(constantBase, cppSite: "TypeCheck.cpp:1355").upperBound())
            }

            let index = constantIndex.integerValue()
            if index < 0 || (size != 0 && UInt64(bitPattern: index) >= UInt64(size)) {
                let bounds: MessageText = size != 0 ? " [0..\(size &- 1)]" : ""
                throw CompilationMessage(text: "index \(index) is out of bounds\(bounds)", span: shaderModule.span(of: id))
            }

            if let constantBase {
                let element = alternative.get(constantBase, cppSite: "TypeCheck.cpp:1364")[UInt32(truncatingIfNeeded: index)]
                shaderModule.setConstantValue(element, for: id)
            }
        }

        func accessImpl(_ base: TypeID, _ isVector: inout Bool) throws(CompilationMessage) -> TypeID {
            var result: TypeID?
            if let array = shaderModule.types.getIf(Types.Array.self, base) {
                result = array.element
                var size: UInt32?
                if case .creationFixed(let constantSize) = array.size {
                    size = constantSize
                }
                try constantAccess(.array, size)
            } else if let vector = shaderModule.types.getIf(Types.Vector.self, base) {
                isVector = true
                result = vector.element
                try constantAccess(.vector, UInt32(vector.size))
            } else if let matrix = shaderModule.types.getIf(Types.Matrix.self, base) {
                result = shaderModule.types.vectorType(matrix.rows, matrix.element)
                try constantAccess(.matrix, UInt32(matrix.columns))
            }

            guard var result else {
                throw CompilationMessage(text: "cannot index type '\(typeString(base))'", span: shaderModule.span(of: id))
            }

            if !shaderModule.hasConstantValue(access.index) {
                guard let concreteResult = concretizeMemoized(result) else {
                    coldFatal("an indexed element type has no concrete type", cppSite: "TypeCheck.cpp:1391")
                }
                result = concreteResult
            }
            evaluated(max(inferredEvaluation(of: access.base, shaderModule), inferredEvaluation(of: access.index, shaderModule)))
            return result
        }

        let base = try infer(access.base, maxEvaluation)
        let index = try infer(access.index, maxEvaluation)

        // Out of line, so that the frame recursing through `infer` does not hold the locals of the rest.
        @inline(never)
        func resultImpl() throws(CompilationMessage) {
            guard
                unify(shaderModule.types.i32Type, index) || unify(shaderModule.types.u32Type, index)
                    || unify(shaderModule.types.abstractIntType, index)
            else {
                throw CompilationMessage(
                    text: "index must be of type 'i32' or 'u32', found: '\(typeString(index))'",
                    span: shaderModule.span(of: id)
                )
            }

            func referenceImpl(_ addressSpace: AddressSpace, _ element: TypeID, _ accessMode: AccessMode) throws(CompilationMessage) {
                var isVector = false
                var result = try accessImpl(element, &isVector)
                result = shaderModule.types.referenceType(addressSpace, result, accessMode, isVectorComponent: isVector)
                inferred(result)
            }

            if let reference = shaderModule.types.getIf(Types.Reference.self, base) {
                try referenceImpl(reference.addressSpace, reference.element, reference.accessMode)
                return
            }

            if let pointer = shaderModule.types.getIf(Types.Pointer.self, base) {
                try referenceImpl(pointer.addressSpace, pointer.element, pointer.accessMode)
                return
            }

            // C++ passes no out-parameter here.
            var isVector = false
            let result = try accessImpl(base, &isVector)
            inferred(result)
        }
        try resultImpl()
    }

    mutating func visit(_ binary: BinaryExpression, _ id: ExpressionID) throws(CompilationMessage) {
        try binaryExpression(shaderModule.span(of: id), id, binary.operation, binary.leftExpression, binary.rightExpression)
    }

    // DEV-04: a nested `&&`/`||` infers its left operand once, where C++ infers it twice per level.
    mutating func binaryExpression(
        _ span: SourceSpan,
        _ expression: ExpressionID?,
        _ operation: BinaryOperation,
        _ leftExpression: ExpressionID,
        _ rightExpression: ExpressionID
    ) throws(CompilationMessage) {
        if operation == .shortCircuitAnd || operation == .shortCircuitOr {
            let lhsType = try infer(leftExpression, maxEvaluation)
            if lhsType == shaderModule.types.boolType {
                if let lhsValue = constantValue(of: leftExpression) {
                    let lhsBool = lhsValue.toBool()
                    let shortCircuits = (operation == .shortCircuitAnd && !lhsBool) || (operation == .shortCircuitOr && lhsBool)
                    if shortCircuits {
                        let suppressScope = suppressConstantErrors
                        suppressConstantErrors = true
                        defer { suppressConstantErrors = suppressScope }
                        var rhsType = try infer(rightExpression, maxEvaluation)
                        if let reference = shaderModule.types.getIf(Types.Reference.self, rhsType) {
                            rhsType = reference.element
                        }
                        guard rhsType == shaderModule.types.boolType else {
                            throw CompilationMessage(
                                text:
                                    "no matching overload for operator \(toASCIILiteral(operation))(\(typeString(lhsType)), \(typeString(rhsType)))",
                                span: span
                            )
                        }
                        inferred(shaderModule.types.boolType)
                        evaluated(inferredEvaluation(of: leftExpression, shaderModule))
                        if let expression {
                            shaderModule.setConstantValue(.bool(operation == .shortCircuitAnd ? false : true), for: expression)
                        }
                        return
                    }
                }
            }
            // DEV-04: chooseOverload infers the left operand again; that inference reuses this one.
            inferredLeftOperand = leftExpression
        }

        defer { inferredLeftOperand = nil }
        _ = try chooseOverload("operator", span, expression, operatorSymbol(operation), .binary(leftExpression, rightExpression), [])

        var operationName: StaticString?
        if operation == .divide {
            operationName = "division"
        } else if operation == .modulo {
            operationName = "modulo"
        }
        if let operationName {
            var rightType = shaderModule.inferredType(of: rightExpression)
            if let vectorType = shaderModule.types.getIf(Types.Vector.self, rightType) {
                rightType = vectorType.element
            }
            if satisfies(rightType, .integer, shaderModule.types) {
                if operation == .divide {
                    shaderModule.uses.insert(.division)
                } else {
                    shaderModule.uses.insert(.modulo)
                }
                let leftValue = constantValue(of: leftExpression)
                let rightValue = constantValue(of: rightExpression)
                if leftValue == nil, let rightValue {
                    guard let rightExpressionType = shaderModule.inferredType(of: rightExpression) else {
                        coldFatal("an operand chooseOverload accepted has no inferred type", cppSite: "TypeCheck.cpp:1476")
                    }
                    if containsZero(rightValue, rightExpressionType) {
                        throw CompilationMessage(text: "invalid \(operationName) by zero", span: span)
                    }
                }
            }
        }
    }

    mutating func visit(_ identifier: IdentifierExpression, _ id: ExpressionID) throws(CompilationMessage) {
        let name = shaderModule.symbol(of: identifier.identifier)
        guard let binding = readVariable(name) else {
            throw CompilationMessage(
                text: "unresolved identifier '\(shaderModule.symbols.text(of: name))'",
                span: shaderModule.span(of: id)
            )
        }

        guard binding.kind == .value else {
            throw CompilationMessage(
                text: "cannot use \(bindingKindToString(binding.kind)) '\(shaderModule.symbols.text(of: name))' as value",
                span: shaderModule.span(of: id)
            )
        }

        guard binding.evaluation <= maxEvaluation else {
            throw CompilationMessage(
                text: "cannot use \(evaluationToString(binding.evaluation)) value in \(evaluationToString(maxEvaluation)) expression",
                span: shaderModule.span(of: id)
            )
        }

        // https://www.w3.org/TR/WGSL/#continue-statement
        if inContinuingClause && binding.declaredAfterContinue {
            throw CompilationMessage(
                text:
                    "the 'continuing' clause cannot use '\(shaderModule.symbols.text(of: name))', which is declared after a 'continue' statement in the loop body",
                span: shaderModule.span(of: id)
            )
        }

        evaluated(binding.evaluation)
        inferred(binding.type)
        if let constantValue = binding.constantValue {
            try setConstantValue(id, binding.type, constantValue)
        }
    }

    mutating func visit(_ unary: UnaryExpression, _ id: ExpressionID) throws(CompilationMessage) {
        if unary.operation == .addressOf {
            let type = try infer(unary.expression, .runtime)
            guard let reference = shaderModule.types.getIf(Types.Reference.self, type) else {
                throw CompilationMessage(text: "cannot take address of expression", span: shaderModule.span(of: id))
            }

            guard reference.addressSpace != .handle else {
                throw CompilationMessage(
                    text: "cannot take the address of expression in handle address space",
                    span: shaderModule.span(of: id)
                )
            }

            guard !reference.isVectorComponent else {
                throw CompilationMessage(text: "cannot take the address of a vector component", span: shaderModule.span(of: id))
            }

            evaluated(.runtime)
            inferred(shaderModule.types.pointerType(reference.addressSpace, reference.element, reference.accessMode))
            return
        }

        if unary.operation == .dereference {
            let type = try infer(unary.expression, .runtime)
            guard let pointer = shaderModule.types.getIf(Types.Pointer.self, type) else {
                throw CompilationMessage(
                    text: "cannot dereference expression of type '\(typeString(type))'",
                    span: shaderModule.span(of: id)
                )
            }

            evaluated(.runtime)
            inferred(shaderModule.types.referenceType(pointer.addressSpace, pointer.element, pointer.accessMode))
            return
        }

        _ = try chooseOverload("operator", shaderModule.span(of: id), id, operatorSymbol(unary.operation), .unary(unary.expression), [])
    }

    // Literal Expressions
    mutating func visit(_ literal: BoolLiteral, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.boolType)
        shaderModule.setConstantValue(.bool(literal.value), for: id)
    }

    mutating func visit(_ literal: Signed32Literal, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.i32Type)
        shaderModule.setConstantValue(.int32(literal.value), for: id)
    }

    mutating func visit(_ literal: Float32Literal, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.f32Type)
        shaderModule.setConstantValue(.float(literal.value), for: id)
    }

    mutating func visit(_ literal: Float16Literal, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.f16Type)
        shaderModule.setConstantValue(.half(literal.value), for: id)
    }

    mutating func visit(_ literal: Unsigned32Literal, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.u32Type)
        shaderModule.setConstantValue(.uint32(literal.value), for: id)
    }

    mutating func visit(_ literal: AbstractIntegerLiteral, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.abstractIntType)
        shaderModule.setConstantValue(.int64(literal.value), for: id)
    }

    mutating func visit(_ literal: AbstractFloatLiteral, _ id: ExpressionID) {
        evaluated(.constant)
        inferred(shaderModule.types.abstractFloatType)
        shaderModule.setConstantValue(.double(literal.value), for: id)
    }

    // Types
    mutating func visit(_ array: ArrayTypeExpression, _ id: ExpressionID) throws(CompilationMessage) {
        guard let maybeElementType = array.maybeElementType else {
            throw CompilationMessage(text: "'array' requires at least 1 template argument", span: shaderModule.span(of: id))
        }

        let elementType = try resolve(maybeElementType)
        guard hasCreationFixedFootprint(elementType) else {
            throw CompilationMessage(
                text: "'\(typeString(elementType))' cannot be used as an element type of an array",
                span: shaderModule.span(of: id)
            )
        }

        var size = Types.Array.Size.runtime
        if let maybeElementCount = array.maybeElementCount {
            let elementCountType = try infer(maybeElementCount, min(maxEvaluation, .override))
            guard unify(shaderModule.types.i32Type, elementCountType) || unify(shaderModule.types.u32Type, elementCountType) else {
                throw CompilationMessage(
                    text: "array count must be an i32 or u32 value, found '\(typeString(elementCountType))'",
                    span: shaderModule.span(of: id)
                )
            }

            var value = constantValue(of: maybeElementCount)
            if value != nil {
                guard let concreteType = concretizeMemoized(elementCountType) else {
                    coldFatal("an array count type has no concrete type", cppSite: "TypeCheck.cpp:2039")
                }
                try convertValue(shaderModule.span(of: maybeElementCount), concreteType, &value)
                guard let convertedValue = value else {
                    coldFatal("optional operator-> on an array count convertValue dropped", cppSite: "TypeCheck.cpp:2040")
                }
                let elementCount = convertedValue.integerValue()
                guard elementCount >= 1 else {
                    throw CompilationMessage(text: "array count must be greater than 0", span: shaderModule.span(of: id))
                }
                size = .creationFixed(UInt32(truncatingIfNeeded: elementCount))
            } else {
                var countExpression = maybeElementCount
                if case .identifierExpression(let identifier) = shaderModule[countExpression].kind {
                    let identifierExpression = countExpression
                    countExpression = arrayCountOverrides.ensure(shaderModule.symbol(of: identifier.identifier)) { identifierExpression }
                }
                size = .overrideSized(countExpression)
            }
        }

        inferred(shaderModule.types.arrayType(elementType, size))
        evaluated(.constant)
    }

    mutating func lookupType(_ name: Identifier) throws(CompilationMessage) -> TypeID {
        guard let binding = readVariable(name) else {
            throw CompilationMessage(text: "unresolved type '\(shaderModule.symbols.text(of: name.symbol))'", span: name.span)
        }

        guard binding.kind == .type else {
            throw CompilationMessage(
                text: "cannot use \(bindingKindToString(binding.kind)) '\(shaderModule.symbols.text(of: name.symbol))' as type",
                span: name.span
            )
        }

        try validateF16Usage(name.span, binding.type)

        return binding.type
    }

    mutating func validateF16Usage(_ span: SourceSpan, _ type: TypeID) throws(CompilationMessage) {
        if shaderModule.enabledExtensions.contains(.f16) {
            return
        }

        var type = type
        if let matrix = shaderModule.types.getIf(Types.Matrix.self, type) {
            type = matrix.element
        } else if let vector = shaderModule.types.getIf(Types.Vector.self, type) {
            type = vector.element
        }

        guard type != shaderModule.types.f16Type else {
            throw CompilationMessage(text: "f16 type used without f16 extension enabled", span: span)
        }
    }

    mutating func visit(_ type: ElaboratedTypeExpression, _ id: ExpressionID) throws(CompilationMessage) {
        let base = try lookupType(shaderModule[type.base])

        guard let constructor = shaderModule.types.getIf(Types.TypeConstructor.self, base) else {
            throw CompilationMessage(
                text: "type '\(typeString(base))' does not take template arguments",
                span: shaderModule.span(of: id)
            )
        }

        let constructedType = try construct(constructor, type, id)

        inferred(constructedType)
        evaluated(.constant)
    }

    // Private helpers
    mutating func vectorFieldAccess(
        _ vector: Types.Vector,
        _ access: FieldAccessExpression,
        _ id: ExpressionID
    ) throws(CompilationMessage) -> TypeID {
        let fieldName = shaderModule.symbol(of: access.fieldName)

        let swizzle: Swizzle
        switch Swizzle.validate(fieldName, shaderModule.symbols, vectorSize: vector.size) {
        case .success(let validated):
            swizzle = validated
        case .failure(.character):
            throw CompilationMessage(text: "invalid vector swizzle character", span: shaderModule.span(of: id))
        case .failure(.member):
            throw CompilationMessage(text: "invalid vector swizzle member", span: shaderModule.span(of: id))
        case .failure(.size):
            throw CompilationMessage(text: "invalid vector swizzle size", span: shaderModule.span(of: id))
        }
        shaderModule.symbols.markSwizzle(fieldName, swizzle)

        let constantValue = constantValue(of: access.base)

        if swizzle.count == 1 {
            if let constantValue {
                shaderModule.setConstantValue(constantValue.toVector().elements[swizzle.componentIndex(at: 0)], for: id)
            }
            return vector.element
        }

        if let constantValue {
            let vector = constantValue.toVector()
            var result = ConstantVector(size: swizzle.count)
            var i = 0
            while i < swizzle.count {
                result.elements[i] = vector.elements[swizzle.componentIndex(at: i)]
                i &+= 1
            }
            shaderModule.setConstantValue(.vector(result), for: id)
        }
        return shaderModule.types.vectorType(UInt8(truncatingIfNeeded: swizzle.count), vector.element)
    }
}

// MARK: - Swift-only

// At -O a call to a non-mutating ShaderModule method that is not inlined copies the whole module (688 B) into the
// caller's frame. These out-of-line helpers keep such calls out of the frames of the recursive expression visits
// (constantValue(of:) is inlined into its helper, with no copy).
extension TypeChecker {
    @inline(never)
    private mutating func constantValue(of expression: ExpressionID) -> ConstantValue? {
        shaderModule.constantValue(of: expression)
    }

    @inline(never)
    private mutating func typeString(_ type: TypeID) -> MessageText {
        ShaderModule.typeString(type, in: &shaderModule)
    }

    @inline(never)
    private mutating func hasCreationFixedFootprint(_ type: TypeID) -> Bool {
        shaderModule.hasCreationFixedFootprint(type, knownStructures: creationFixedStructures)
    }

    @inline(never)
    private mutating func containsZero(_ value: ConstantValue, _ valueType: TypeID) -> Bool {
        WGSL.containsZero(shaderModule, value, valueType)
    }

    // A trap reached straight from the dispatcher's switch makes it destroy `self` first, in its own frame.
    @inline(never)
    private mutating func visitUnexpectedExpression() -> Never {
        coldFatal("unexpected expression kind", cppSite: "TypeCheck.cpp:1269")
    }

    private mutating func visitAbstractFloatLiteralPayload(_ id: ExpressionID) {
        guard case .abstractFloatLiteral(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1230")
        }
        visit(node, id)
    }

    private mutating func visitAbstractIntegerLiteralPayload(_ id: ExpressionID) {
        guard case .abstractIntegerLiteral(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1233")
        }
        visit(node, id)
    }

    private mutating func visitBoolLiteralPayload(_ id: ExpressionID) {
        guard case .boolLiteral(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1236")
        }
        visit(node, id)
    }

    private mutating func visitFloat32LiteralPayload(_ id: ExpressionID) {
        guard case .float32Literal(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1239")
        }
        visit(node, id)
    }

    private mutating func visitFloat16LiteralPayload(_ id: ExpressionID) {
        guard case .float16Literal(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1242")
        }
        visit(node, id)
    }

    private mutating func visitSigned32LiteralPayload(_ id: ExpressionID) {
        guard case .signed32Literal(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1245")
        }
        visit(node, id)
    }

    private mutating func visitUnsigned32LiteralPayload(_ id: ExpressionID) {
        guard case .unsigned32Literal(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1248")
        }
        visit(node, id)
    }

    private mutating func visitBinaryExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .binaryExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1252")
        }
        try visit(node, id)
    }

    private mutating func visitCallExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .callExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1254")
        }
        try visit(node, id)
    }

    private mutating func visitFieldAccessExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .fieldAccessExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1256")
        }
        try visit(node, id)
    }

    private mutating func visitIdentifierExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .identifierExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1258")
        }
        try visit(node, id)
    }

    private mutating func visitIndexAccessExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .indexAccessExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1260")
        }
        try visit(node, id)
    }

    private mutating func visitUnaryExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .unaryExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1262")
        }
        try visit(node, id)
    }

    private mutating func visitArrayTypeExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .arrayTypeExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1264")
        }
        try visit(node, id)
    }

    private mutating func visitElaboratedTypeExpressionPayload(_ id: ExpressionID) throws(CompilationMessage) {
        guard case .elaboratedTypeExpression(let node) = shaderModule[id].kind else {
            coldFatal("tag/kind mismatch", cppSite: "TypeCheck.cpp:1266")
        }
        try visit(node, id)
    }
}

/// C++ `expression.evaluation()`: `*m_evaluation`, a libc++ hardening trap on an expression that was never inferred.
private func inferredEvaluation(of expression: ExpressionID, _ shaderModule: borrowing ShaderModule) -> Evaluation {
    guard let evaluation = shaderModule.evaluation(of: expression) else {
        coldFatal("evaluation() of an expression that was never inferred", cppSite: "ASTExpression.h:74")
    }
    return evaluation
}

/// wgslFatal out of line, so that the recursive visits do not build its message in their own frames.
@inline(never)
private func coldFatal(_ message: StaticString, cppSite: StaticString) -> Never {
    wgslFatal(message, cppSite: cppSite)
}

/// The predeclared symbol spelling `toASCIILiteral(operation)`, the overload chooseOverload looks up.
private func operatorSymbol(_ operation: BinaryOperation) -> Symbol {
    switch operation {
    case .add: Symbol(.add)
    case .subtract: Symbol(.minus)
    case .multiply: Symbol(.multiply)
    case .divide: Symbol(.divide)
    case .modulo: Symbol(.modulo)
    case .and: Symbol(.bitwiseAnd)
    case .or: Symbol(.bitwiseOr)
    case .xor: Symbol(.bitwiseXor)
    case .leftShift: Symbol(.bitwiseShiftLeft)
    case .rightShift: Symbol(.bitwiseShiftRight)
    case .equal: Symbol(.equal)
    case .notEqual: Symbol(.notEqual)
    case .greaterThan: Symbol(.gt)
    case .greaterEqual: Symbol(.gtEq)
    case .lessThan: Symbol(.lt)
    case .lessEqual: Symbol(.ltEq)
    case .shortCircuitAnd: Symbol(.and)
    case .shortCircuitOr: Symbol(.or)
    }
}

/// The predeclared symbol spelling `toASCIILiteral(operation)`; `&` and `*` (address-of, dereference) never reach
/// chooseOverload.
private func operatorSymbol(_ operation: UnaryOperation) -> Symbol {
    switch operation {
    case .addressOf: Symbol(.bitwiseAnd)
    case .complement: Symbol(.bitwiseNot)
    case .dereference: Symbol(.multiply)
    case .negate: Symbol(.minus)
    case .not: Symbol(.not)
    }
}

/// The `T` of the C++ `constantAccess<T>` lambda of visit(IndexAccessExpression).
private enum ConstantAccessAlternative {
    case array
    case vector
    case matrix

    /// C++ `std::get<T>(value)`: terminates on another alternative.
    func get(_ value: ConstantValue, cppSite: StaticString) -> ConstantValue {
        switch self {
        case .array:
            if case .array = value {
                return value
            }
        case .vector:
            if case .vector = value {
                return value
            }
        case .matrix:
            if case .matrix = value {
                return value
            }
        }
        coldFatal("std::get of a constant that is not the indexed alternative", cppSite: cppSite)
    }
}
