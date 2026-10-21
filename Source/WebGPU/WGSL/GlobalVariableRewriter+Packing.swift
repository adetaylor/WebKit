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

extension RewriteGlobalVariables {
    @discardableResult
    mutating func pack(_ expectedPacking: Packing, _ expression: ExpressionID) -> Packing {
        if isTopLevelExpression && (shaderModule.evaluation(of: expression) ?? .runtime) == .override {
            addOverrideValidation(.ensureOverrideValue(expression))
        }

        let topLevelExpression = isTopLevelExpression
        isTopLevelExpression = false
        defer { isTopLevelExpression = topLevelExpression }

        if doNotUnpack.contains(expression) {
            return expectedPacking
        }

        // C++ instantiates this lambda once per expression kind: `getPacking` may have replaced `expression` (in place, with a
        // node of the same kind), and replace(_:with:) picks the C++ replace overload from that kind.
        func visitAndReplace(_ packing: Packing) -> Packing {
            if !expectedPacking.isDisjoint(with: packing) {
                return packing
            }

            var type = shaderModule.inferredType(of: expression)
            if let referenceType = shaderModule.types.getIf(Types.Reference.self, type) {
                type = referenceType.element
            }
            guard let type else {
                wgslFatal("a packed expression without a type", cppSite: "GlobalVariableRewriter.cpp:493")
            }
            let operation: ReservedName.Fixed
            if shaderModule.types.getIf(Types.Struct.self, type) != nil {
                if !shaderModule.isConstructible(type) {
                    return packing
                }
                operation = packing.contains(.packed) ? .unpack : .pack
            } else if shaderModule.types.getIf(Types.Array.self, type) != nil {
                if packing.contains(.packed) {
                    operation = .unpack
                    shaderModule.uses.insert(.unpackArray)
                } else {
                    operation = .pack
                    shaderModule.uses.insert(.packArray)
                }
            } else {
                if packing.contains(.packed) {
                    operation = .unpack
                    shaderModule.uses.insert(.unpackVector)
                } else {
                    operation = .pack
                    shaderModule.uses.insert(.packVector)
                }
            }
            let operationName = shaderModule.symbols.intern(.fixed(operation))
            let callee = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(operationName))
            shaderModule.setInferredType(shaderModule.types.u32Type, for: callee)
            let argument = shaderModule.construct(copyOf: expression)
            var callExpression = CallExpression(target: callee, arguments: shaderModule.makeList([argument]))
            callExpression.resolvedTarget = operationName
            let call = shaderModule.construct(span: .empty, callExpression)
            shaderModule.setInferredType(shaderModule.inferredType(of: argument), for: call)
            shaderModule.replace(expression, with: call)
            return Packing.either.symmetricDifference(packing)
        }

        switch shaderModule.tag(of: expression) {
        case .identifierExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(IdentifierExpression.self, expression), expression))
        case .fieldAccessExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(FieldAccessExpression.self, expression), expression))
        case .indexAccessExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(IndexAccessExpression.self, expression), expression))
        case .checkedIndexAccessExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(CheckedIndexAccessExpression.self, expression), expression))
        case .binaryExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(BinaryExpression.self, expression), expression))
        case .unaryExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(UnaryExpression.self, expression), expression))
        case .callExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(CallExpression.self, expression), expression))
        case .identityExpression:
            return visitAndReplace(getPacking(shaderModule.downcast(IdentityExpression.self, expression), expression))
        case .abstractFloatLiteral, .abstractIntegerLiteral, .boolLiteral, .float32Literal, .float16Literal, .signed32Literal,
            .unsigned32Literal, .pointerDereferenceExpression, .arrayTypeExpression, .elaboratedTypeExpression, .referenceTypeExpression:
            dispatch(expression)
            return .unpacked
        }
    }

    mutating func getPacking(_ identifier: IdentifierExpression, _ id: ExpressionID) -> Packing {
        let global = readVariable(identifier)
        if let global, global.resource != nil {
            guard let type = shaderModule.inferredType(of: id) else {
                wgslFatal("a resource read without a type", cppSite: "GlobalVariableRewriter.cpp:557")
            }
            return packingForType(type)
        }

        return .unpacked
    }

    mutating func getPacking(_ expression: FieldAccessExpression, _ id: ExpressionID) -> Packing {
        guard var baseType = shaderModule.inferredType(of: expression.base) else {
            // All AST nodes should have an inferred type, but we create field
            // access nodes from the EntryPointRewriter which don't have a trivial
            // type, so we work around it by returning unpacked since those are only
            // used for marshalling inputs/outputs and don't need to packed/unpacked.
            return .unpacked
        }

        if let referenceType = shaderModule.types.getIf(Types.Reference.self, baseType) {
            baseType = referenceType.element
        }

        var isPointer = false
        if let pointerType = shaderModule.types.getIf(Types.Pointer.self, baseType) {
            isPointer = true
            baseType = pointerType.element
        }

        if shaderModule.types.getIf(Types.Vector.self, baseType) != nil {
            guard let type = shaderModule.inferredType(of: id) else {
                wgslFatal("a vector field access without a type", cppSite: "GlobalVariableRewriter.cpp:583")
            }
            if shaderModule.types.getIf(Types.Vector.self, type) != nil {
                var base = expression.base
                if isPointer {
                    let dereference = shaderModule.construct(
                        span: shaderModule.span(of: expression.base),
                        UnaryExpression(expression: expression.base, operation: .dereference)
                    )
                    shaderModule.setInferredType(baseType, for: dereference)

                    let fieldAccessExpression = shaderModule.constructFieldAccessExpression(
                        span: shaderModule.span(of: id),
                        base: dereference,
                        fieldName: shaderModule.makeIdentifier(shaderModule[expression.fieldName].symbol)
                    )
                    shaderModule.setInferredType(type, for: fieldAccessExpression)

                    shaderModule.replace(id, with: fieldAccessExpression)
                    // C++ reads the base of the replaced node.
                    base = dereference
                }
                pack(.unpacked, base)
            } else {
                pack(.either, expression.base)
            }
            return .unpacked
        }

        let basePacking = pack(.either, expression.base)
        if basePacking.contains(.unpacked) {
            return .unpacked
        }

        assert(shaderModule.types.getIf(Types.Struct.self, baseType) != nil)
        guard let structType = shaderModule.types.getIf(Types.Struct.self, baseType) else {
            wgslFatal("std::get<Types::Struct> on another type", cppSite: "GlobalVariableRewriter.cpp:612")
        }
        guard let fieldType = shaderModule.types.fields(of: structType.fields).get(shaderModule[expression.originalFieldName].symbol) else {
            wgslFatal("a packed field access to a missing member", cppSite: "GlobalVariableRewriter.cpp:614")
        }
        return packingForType(fieldType)
    }

    mutating func getPacking(_ expression: IndexAccessExpression, _ id: ExpressionID) -> Packing {
        let basePacking = pack(.either, expression.base)
        pack(.unpacked, expression.index)
        if basePacking.contains(.unpacked) {
            return .unpacked
        }
        var baseType = shaderModule.inferredType(of: expression.base)
        if let referenceType = shaderModule.types.getIf(Types.Reference.self, baseType) {
            baseType = referenceType.element
        }
        if let pointerType = shaderModule.types.getIf(Types.Pointer.self, baseType) {
            baseType = pointerType.element
        }
        guard let baseType else {
            wgslFatal("a packed index access without a type", cppSite: "GlobalVariableRewriter.cpp:628")
        }
        if shaderModule.types.getIf(Types.Vector.self, baseType) != nil {
            return .unpacked
        }
        if let matrixType = shaderModule.types.getIf(Types.Matrix.self, baseType) {
            // Indexing a packed matrix (rows == 3) yields a PackedVec3 column,
            // which still needs to be unpacked before it can be swizzled or used
            // as a vec3. See Type::packing().
            if matrixType.rows == 3 {
                return .packedVec3
            }
            return .unpacked
        }
        assert(shaderModule.types.getIf(Types.Array.self, baseType) != nil)
        guard let arrayType = shaderModule.types.getIf(Types.Array.self, baseType) else {
            wgslFatal("std::get<Types::Array> on another type", cppSite: "GlobalVariableRewriter.cpp:639")
        }
        return packingForType(arrayType.element)
    }

    /// C++ has one IndexAccessExpression kind for both: a checked access packs as an unchecked one.
    mutating func getPacking(_ expression: CheckedIndexAccessExpression, _ id: ExpressionID) -> Packing {
        getPacking(IndexAccessExpression(base: expression.base, index: expression.index), id)
    }

    mutating func getPacking(_ expression: BinaryExpression, _ id: ExpressionID) -> Packing {
        pack(.unpacked, expression.leftExpression)

        if expression.operation == .shortCircuitAnd || expression.operation == .shortCircuitOr {
            let leftEval = shaderModule.evaluation(of: expression.leftExpression) ?? .runtime
            if leftEval < .runtime {
                shortCircuitedOperators.append(id)
                pack(.unpacked, expression.rightExpression)
                shortCircuitedOperators.removeLast()
                return .unpacked
            }
        }

        pack(.unpacked, expression.rightExpression)

        let operation = operatorSymbol(expression.operation)
        if let overload = shaderModule.lookupOverload(operation) {
            if let validate = overload.validationFunction {
                let leftEval = shaderModule.evaluation(of: expression.leftExpression) ?? .runtime
                let rightEval = shaderModule.evaluation(of: expression.rightExpression) ?? .runtime
                if leftEval == .override || rightEval == .override {
                    addOverrideValidation(.binaryValidation(id, rightExpression: expression.rightExpression, validate))
                }
            }
        }

        return .unpacked
    }

    mutating func getPacking(_ expression: UnaryExpression, _ id: ExpressionID) -> Packing {
        if expression.operation == .addressOf {
            pack(.either, expression.expression)
            // we can't pack/unpack pointers, so we return Either to avoid that
            return .either
        }
        if expression.operation == .dereference {
            // similarly to above, pointers are handled differently, so we can't trust
            // the packing of the underlying element and instead we skip any packing
            // of the operand (since we can't pack/unpack pointers) and return the
            // packing of the resulting type from dereferencing
            pack(.either, expression.expression)
            guard let pointer = shaderModule.types.getIf(Types.Pointer.self, shaderModule.inferredType(of: expression.expression)) else {
                wgslFatal("a dereference of a non-pointer", cppSite: "GlobalVariableRewriter.cpp:702")
            }
            if pointer.addressSpace == .storage || pointer.addressSpace == .uniform {
                guard let type = shaderModule.inferredType(of: id) else {
                    wgslFatal("a dereference without a type", cppSite: "GlobalVariableRewriter.cpp:703")
                }
                return shaderModule.packing(of: type)
            }
            return .unpacked
        }
        return pack(.unpacked, expression.expression)
    }

    mutating func getPacking(_ expression: IdentityExpression, _ id: ExpressionID) -> Packing {
        pack(.either, expression.expression)
    }

    mutating func getPacking(_ call: CallExpression, _ id: ExpressionID) -> Packing {
        if let target = shaderModule.dynamicDowncast(IdentifierExpression.self, call.target) {
            if shaderModule[target.identifier].symbol == BuiltinSymbols.arrayLength {
                assert(shaderModule.count(call.arguments) == 1)
                let arrayPointer = shaderModule[call.arguments, 0]
                var arrayOffset: UInt32 = 0
                let base = getBase(arrayPointer, &arrayOffset)
                let identifier = shaderModule[base.identifier].symbol
                if !globals.contains(identifier) {
                    guard let currentFunction else {
                        wgslFatal("arrayLength outside a function", cppSite: "GlobalVariableRewriter.cpp:724")
                    }
                    lengthParameters.modify(currentFunction, default: OrderedSet()) { _ = $0.add(identifier) }
                }
                let lengthName = shaderModule.symbols.intern(.arrayLength(of: identifier))
                let length = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(lengthName))
                shaderModule.setInferredType(shaderModule.types.u32Type, for: length)

                let arrayPointerType = shaderModule.inferredType(of: arrayPointer)
                assert(shaderModule.types.getIf(Types.Pointer.self, arrayPointerType) != nil)
                guard let pointerType = shaderModule.types.getIf(Types.Pointer.self, arrayPointerType) else {
                    wgslFatal("std::get<Types::Pointer> on another type", cppSite: "GlobalVariableRewriter.cpp:736")
                }
                let arrayType = pointerType.element
                assert(shaderModule.types.getIf(Types.Array.self, arrayType) != nil)
                guard let array = shaderModule.types.getIf(Types.Array.self, arrayType) else {
                    wgslFatal("std::get<Types::Array> on another type", cppSite: "GlobalVariableRewriter.cpp:738")
                }
                let elementType = array.element
                let elementSize = ShaderModule.size(of: elementType, in: &shaderModule)
                let elementAlignment = ShaderModule.alignment(of: elementType, in: &shaderModule)
                let runtimeArrayLayout = RuntimeArrayLayout(
                    offsetInBinding: arrayOffset,
                    elementSize: elementSize,
                    elementAlignment: ByteAlignment(elementAlignment)
                )

                let strideExpression = shaderModule.construct(span: .empty, Unsigned32Literal(value: runtimeArrayLayout.stride))
                shaderModule.setInferredType(shaderModule.types.u32Type, for: strideExpression)

                var lhs = length
                if runtimeArrayLayout.offsetInBinding != 0 {
                    let arrayOffsetExpression = shaderModule.construct(
                        span: .empty,
                        Unsigned32Literal(value: runtimeArrayLayout.offsetInBinding)
                    )
                    shaderModule.setInferredType(shaderModule.types.u32Type, for: arrayOffsetExpression)
                    lhs = shaderModule.construct(
                        span: .empty,
                        BinaryExpression(leftExpression: length, rightExpression: arrayOffsetExpression, operation: .subtract)
                    )
                    shaderModule.setInferredType(shaderModule.types.u32Type, for: lhs)
                }

                shaderModule.uses.insert(.division)
                let elementCount = shaderModule.construct(
                    span: .empty,
                    BinaryExpression(leftExpression: lhs, rightExpression: strideExpression, operation: .divide)
                )
                shaderModule.setInferredType(shaderModule.types.u32Type, for: elementCount)

                shaderModule.replace(id, with: elementCount)
                // mark both the array and array length as read
                readVariable(base)
                readVariable(shaderModule.downcast(IdentifierExpression.self, length))
                return .unpacked
            }
        }

        var arguments = shaderModule.cursor(call.arguments)
        while let argument = shaderModule.next(&arguments) {
            pack(.unpacked, argument)
        }

        if let validate = call.validationFunction {
            addOverrideValidation(.callValidation(id, validate))
        }

        return .unpacked
    }

    mutating func packingForType(_ type: TypeID) -> Packing {
        shaderModule.packing(of: type)
    }

    /// C++ recurses through the identity, unary and field access expressions down to the identifier; a loop here.
    mutating func getBase(_ expression: ExpressionID, _ arrayOffset: inout UInt32) -> IdentifierExpression {
        var expression = expression
        while true {
            if let identityExpression = shaderModule.dynamicDowncast(IdentityExpression.self, expression) {
                expression = identityExpression.expression
                continue
            }
            if let unaryExpression = shaderModule.dynamicDowncast(UnaryExpression.self, expression) {
                expression = unaryExpression.expression
                continue
            }
            if let fieldAccess = shaderModule.dynamicDowncast(FieldAccessExpression.self, expression) {
                let base = fieldAccess.base
                var type = shaderModule.inferredType(of: base)
                if let reference = shaderModule.types.getIf(Types.Reference.self, type) {
                    type = reference.element
                }
                if let pointer = shaderModule.types.getIf(Types.Pointer.self, type) {
                    type = pointer.element
                }
                guard let structType = shaderModule.types.getIf(Types.Struct.self, type) else {
                    wgslFatal("std::get<Types::Struct> on another type", cppSite: "GlobalVariableRewriter.cpp:825")
                }
                let members = shaderModule[structType.structure].members
                let memberCount = shaderModule.count(members)
                guard memberCount > 0 else {
                    wgslFatal("Vector::last() of an empty member list", cppSite: "GlobalVariableRewriter.cpp:826")
                }
                let lastMember = shaderModule[shaderModule[members, memberCount &- 1]]
                guard shaderModule[lastMember.name].symbol == shaderModule[fieldAccess.fieldName].symbol else {
                    wgslFatal("arrayLength of a field that is not the last member", cppSite: "GlobalVariableRewriter.cpp:827")
                }
                arrayOffset &+= lastMember.offset
                expression = base
                continue
            }
            if let identifierExpression = shaderModule.dynamicDowncast(IdentifierExpression.self, expression) {
                return identifierExpression
            }
            wgslFatal("arrayLength of an expression without a base identifier", cppSite: "GlobalVariableRewriter.cpp:833")
        }
    }
}

/// The predeclared symbol spelling `toASCIILiteral(operation)`.
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
