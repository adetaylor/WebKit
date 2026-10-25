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
    /// The branches are out-of-line local functions, so that a call nested in an argument recurses through the frame of
    /// one branch rather than all of them: as one function, its frame was 6 KiB under -sanitize=address.
    mutating func visit(_ call: CallExpression, _ id: ExpressionID) throws(CompilationMessage) {
        let target = call.target
        var isNamedType = shaderModule.is(IdentifierExpression.self, target)
        var isParameterizedType = shaderModule.is(ElaboratedTypeExpression.self, target)
        var isArrayType = shaderModule.is(ArrayTypeExpression.self, target)

        var typeArguments: [TypeID] = []
        var targetName: Symbol
        if isNamedType {
            targetName = shaderModule.symbol(of: shaderModule.downcast(IdentifierExpression.self, target).identifier)
        } else if isArrayType {
            targetName = shaderModule.symbols.intern("array")
        } else {
            let elaborated = shaderModule.downcast(ElaboratedTypeExpression.self, target)
            var arguments = shaderModule.cursor(elaborated.arguments)
            while let argument = shaderModule.next(&arguments) {
                let argumentType = try resolve(argument)
                typeArguments.append(argumentType)
            }
            targetName = shaderModule.symbol(of: elaborated.base)
        }

        let targetBinding = readVariable(targetName)
        if let targetBinding {
            shaderModule.setInferredType(targetBinding.type, for: target)
            if targetBinding.kind == .type {
                try validateF16Usage(shaderModule.span(of: id), targetBinding.type)

                shaderModule.modify(CallExpression.self, id) { $0.isConstructor = true }
                if let structType = shaderModule.types.getIf(Types.Struct.self, targetBinding.type) {
                    @inline(never)
                    func structInitializer() throws(CompilationMessage) {
                        guard shaderModule.isConstructible(targetBinding.type) else {
                            throw CompilationMessage(text: "struct is not constructible", span: shaderModule.span(of: id))
                        }

                        guard discardResult != .yes else {
                            throw CompilationMessage(text: "value constructor evaluated but not used", span: shaderModule.span(of: id))
                        }

                        let numberOfArguments = shaderModule.count(call.arguments)
                        let fields = shaderModule.types.fields(of: structType.fields)
                        let numberOfFields = fields.count
                        if numberOfArguments != 0 && numberOfArguments != numberOfFields {
                            let errorKind: StaticString = numberOfArguments < numberOfFields ? "few" : "many"
                            throw CompilationMessage(
                                text:
                                    "struct initializer has too \(errorKind) inputs: expected \(numberOfFields), found \(numberOfArguments)",
                                span: shaderModule.span(of: id)
                            )
                        }

                        let members = shaderModule[structType.structure].members
                        var constantFields = ConstantStruct()
                        var isConstant = true
                        var evaluation = Evaluation.constant
                        var i = 0
                        while i < numberOfArguments {
                            let argument = shaderModule[call.arguments, i]
                            let memberName = shaderModule.symbol(of: shaderModule[shaderModule[members, i]].name)
                            guard let fieldType = fields.get(memberName) else {
                                wgslFatal("a struct member without a field type", cppSite: "TypeCheck.cpp:1556")
                            }
                            let argumentType = try infer(argument, maxEvaluation)
                            evaluation = cxxMax(evaluation, evaluationOfInferred(argument))
                            guard unify(fieldType, argumentType) else {
                                throw CompilationMessage(
                                    text:
                                        "type in struct initializer does not match struct member type: expected '\(ShaderModule.typeString(fieldType, in: &shaderModule))', found '\(ShaderModule.typeString(argumentType, in: &shaderModule))'",
                                    span: shaderModule.span(of: argument)
                                )
                            }

                            shaderModule.setInferredType(fieldType, for: argument)
                            if shaderModule.hasConstantValue(argument) {
                                let value = try convertedConstantValue(argument, fieldType, cppSite: "TypeCheck.cpp:1566")
                                constantFields.set(memberName, value)
                                i &+= 1
                                continue
                            }
                            isConstant = false
                            i &+= 1
                        }
                        if isConstant {
                            if numberOfArguments != 0 {
                                try setConstantValue(id, targetBinding.type, .struct(consume constantFields))
                            } else {
                                try setZeroValue(id, targetBinding.type)
                            }
                        }
                        inferred(targetBinding.type)
                        evaluated(evaluation)
                    }
                    try structInitializer()
                    return
                }

                if let vectorType = shaderModule.types.getIf(Types.Vector.self, targetBinding.type) {
                    typeArguments.append(vectorType.element)
                    switch vectorType.size {
                    case 2:
                        targetName = Symbol(.vec2)
                    case 3:
                        targetName = Symbol(.vec3)
                    case 4:
                        targetName = Symbol(.vec4)
                    default: // lint-exempt(L-ENUM-1): a vector size is a UInt8, an open domain
                        wgslFatal("a vector size other than 2, 3 or 4", cppSite: "TypeCheck.cpp:1595")
                    }
                }

                if let matrixType = shaderModule.types.getIf(Types.Matrix.self, targetBinding.type) {
                    typeArguments.append(matrixType.element)
                    let matrixName: MessageText = "mat\(matrixType.columns)x\(matrixType.rows)"
                    targetName = shaderModule.symbols.intern(matrixName.codeUnits)
                }

                // A primitive type's `toString()` is its name.
                if case .primitive(let primitive) = shaderModule.types[targetBinding.type] {
                    targetName = shaderModule.symbols.intern(primitive.kind.name)
                }

                if case .array = shaderModule.types[targetBinding.type] {
                    isNamedType = false
                    isParameterizedType = false
                    isArrayType = true
                }
            } else if targetBinding.kind == .function {
                @inline(never)
                func functionCall() throws(CompilationMessage) {
                    guard case .function(let functionType) = shaderModule.types[targetBinding.type] else {
                        wgslFatal("std::get<Types::Function> of a function binding that is not a function", cppSite: "TypeCheck.cpp:1613")
                    }
                    let numberOfArguments = shaderModule.count(call.arguments)
                    let numberOfParameters = shaderModule.types.count(of: functionType.parameters)
                    @inline(never)
                    func checkCallee() throws(CompilationMessage) {
                        if maxEvaluation < .runtime {
                            throw CompilationMessage(
                                text: "cannot call function from \(evaluationToString(maxEvaluation)) context",
                                span: shaderModule.span(of: id)
                            )
                        }

                        // https://www.w3.org/TR/WGSL/#function-restriction
                        if functionType.isEntryPoint {
                            throw CompilationMessage(
                                text: "cannot call entry point '\(shaderModule.symbols.text(of: targetName))'",
                                span: shaderModule.span(of: id)
                            )
                        }

                        if numberOfArguments != numberOfParameters {
                            let errorKind: StaticString = numberOfArguments < numberOfParameters ? "few" : "many"
                            throw CompilationMessage(
                                text:
                                    "funtion call has too \(errorKind) arguments: expected \(numberOfParameters), found \(numberOfArguments)",
                                span: shaderModule.span(of: id)
                            )
                        }

                        if discardResult == .yes && functionType.mustUse {
                            throw CompilationMessage(
                                text:
                                    "ignoring return value of function '\(shaderModule.symbols.text(of: targetName))' annotated with @must_use",
                                span: shaderModule.span(of: id)
                            )
                        }

                        if discardResult == .no && shaderModule.isPrimitive(functionType.result, .void) {
                            throw CompilationMessage(
                                text: "function '\(shaderModule.symbols.text(of: targetName))' does not return a value",
                                span: shaderModule.span(of: id)
                            )
                        }
                    }
                    try checkCallee()

                    var i = 0
                    while i < numberOfArguments {
                        let argument = shaderModule[call.arguments, i]
                        let parameterType = shaderModule.types[functionType.parameters, i]
                        let argumentType = try infer(argument, maxEvaluation)
                        guard unify(parameterType, argumentType) else {
                            throw CompilationMessage(
                                text:
                                    "type in function call does not match parameter type: expected '\(ShaderModule.typeString(parameterType, in: &shaderModule))', found '\(ShaderModule.typeString(argumentType, in: &shaderModule))'",
                                span: shaderModule.span(of: argument)
                            )
                        }

                        shaderModule.setInferredType(parameterType, for: argument)
                        try convertValue(shaderModule.span(of: argument), parameterType, of: argument)
                        i &+= 1
                    }
                    inferred(functionType.result)
                    evaluated(.runtime)
                }
                try functionCall()
                return
            } else {
                throw CompilationMessage(
                    text: "cannot call value of type '\(ShaderModule.typeString(targetBinding.type, in: &shaderModule))'",
                    span: shaderModule.span(of: target)
                )
            }
        }

        if isNamedType || isParameterizedType {
            shaderModule.modify(CallExpression.self, id) { $0.resolvedTarget = targetName }
            let result = try chooseOverload("initializer", shaderModule.span(of: id), id, targetName, .list(call.arguments), typeArguments)
            if let result {
                @inline(never)
                func checkBuiltinCall() throws(CompilationMessage) {
                    shaderModule.setInferredType(result, for: target)

                    // Subgroup and quad built-in functions require the 'subgroups' extension to be enabled.
                    let subgroupText = subgroupPrefix
                    let quadText = quadPrefix
                    if (startsWith(shaderModule.symbols, targetName, subgroupText)
                        || startsWith(shaderModule.symbols, targetName, quadText))
                        && !shaderModule.enabledExtensions.contains(.subgroups)
                    {
                        throw CompilationMessage(
                            text: "'\(shaderModule.symbols.text(of: targetName))' requires the 'subgroups' extension to be enabled",
                            span: shaderModule.span(of: id)
                        )
                    }

                    // FIXME: <rdar://150366527> this will go away once we track used intrinsics properly
                    if targetName == BuiltinSymbols.workgroupUniformLoad {
                        guard let argument = shaderModule.inferredType(of: shaderModule[call.arguments, 0]),
                            case .pointer(let pointer) = shaderModule.types[argument]
                        else {
                            wgslFatal("std::get<Types::Pointer> of a workgroupUniformLoad argument", cppSite: "TypeCheck.cpp:1666")
                        }
                        if case .atomic = shaderModule.types[pointer.element] {
                            shaderModule.uses.insert(.workgroupUniformLoadAtomic)
                        } else {
                            shaderModule.uses.insert(.workgroupUniformLoad)
                        }
                    } else if targetName == BuiltinSymbols.frexp {
                        shaderModule.uses.insert(.frexp)
                    } else if targetName == BuiltinSymbols.modf {
                        shaderModule.uses.insert(.modf)
                    } else if targetName == BuiltinSymbols.atomicCompareExchangeWeak {
                        shaderModule.uses.insert(.atomicCompareExchange)
                    } else if targetName == BuiltinSymbols.dot {
                        shaderModule.uses.insert(.dot)
                    } else if targetName == BuiltinSymbols.firstLeadingBit {
                        shaderModule.uses.insert(.firstLeadingBit)
                    } else if targetName == BuiltinSymbols.firstTrailingBit {
                        shaderModule.uses.insert(.firstTrailingBit)
                    } else if targetName == BuiltinSymbols.sign {
                        shaderModule.uses.insert(.sign)
                    } else if targetName == BuiltinSymbols.dot4I8Packed {
                        shaderModule.uses.insert(.dot4I8Packed)
                    } else if targetName == BuiltinSymbols.dot4U8Packed {
                        shaderModule.uses.insert(.dot4U8Packed)
                    } else if targetName == BuiltinSymbols.extractBits {
                        shaderModule.uses.insert(.extractBits)
                    } else if targetName == BuiltinSymbols.insertBits {
                        shaderModule.uses.insert(.insertBits)
                    } else if targetName == BuiltinSymbols.textureGather
                        || targetName == BuiltinSymbols.textureGatherCompare
                        || targetName == BuiltinSymbols.textureSample
                        || targetName == BuiltinSymbols.textureSampleBias
                        || targetName == BuiltinSymbols.textureSampleCompare
                        || targetName == BuiltinSymbols.textureSampleCompareLevel
                        || targetName == BuiltinSymbols.textureSampleGrad
                        || targetName == BuiltinSymbols.textureSampleLevel
                    {
                        if targetName == BuiltinSymbols.textureGather {
                            let component = shaderModule[call.arguments, 0]
                            if satisfies(shaderModule.inferredType(of: component), .concreteInteger, shaderModule.types) {
                                guard let constant = shaderModule.constantValue(of: component) else {
                                    throw CompilationMessage(
                                        text: "the component argument must be a const-expression",
                                        span: shaderModule.span(of: component)
                                    )
                                }
                                let componentValue = constant.integerValue()
                                if componentValue < 0 || componentValue > 3 {
                                    throw CompilationMessage(
                                        text: "the component argument must be at least 0 and at most 3. component is \(componentValue)",
                                        span: shaderModule.span(of: component)
                                    )
                                }
                            }
                        }

                        let argumentCount = shaderModule.count(call.arguments)
                        guard argumentCount > 0 else {
                            wgslFatal("last() of an empty argument list", cppSite: "TypeCheck.cpp:1716")
                        }
                        let lastArg = shaderModule[call.arguments, argumentCount &- 1]
                        // vec2<i32> for the 2d overloads and vec3<i32> for the 3d ones; for any other last
                        // argument this builtin has no offset to validate.
                        guard let vectorType = shaderModule.types.getIf(Types.Vector.self, shaderModule.inferredType(of: lastArg)),
                            vectorType.size == 2 || vectorType.size == 3, vectorType.element == shaderModule.types.i32Type
                        else {
                            return
                        }

                        guard let maybeConstant = shaderModule.constantValue(of: lastArg) else {
                            throw CompilationMessage(
                                text: "the offset argument must be a const-expression",
                                span: shaderModule.span(of: lastArg)
                            )
                        }

                        guard case .vector(let vector) = maybeConstant else {
                            wgslFatal("std::get<ConstantVector> of an offset that is not a vector", cppSite: "TypeCheck.cpp:1727")
                        }
                        var i = 0
                        while i < Int(vectorType.size) {
                            guard case .int32(let i32) = vector.elements[i] else {
                                wgslFatal("std::get<int32_t> of an offset component that is not an i32", cppSite: "TypeCheck.cpp:1729")
                            }
                            if i32 < -8 || i32 > 7 {
                                throw CompilationMessage(
                                    text:
                                        "each component of the offset argument must be at least -8 and at most 7. offset component \(i) is \(i32)",
                                    span: shaderModule.span(of: lastArg)
                                )
                            }
                            i &+= 1
                        }
                    }
                }
                try checkBuiltinCall()
                return
            }

            // FIXME: <rdar://150366527> similarly to above: this shouldn't be a string check
            let bitcastText = bitcastName
            if equal(shaderModule.symbols, targetName, bitcastText) {
                try bitcast(call, id, typeArguments)
                return
            }

            throw CompilationMessage(
                text: "unresolved call target '\(shaderModule.symbols.text(of: targetName))'",
                span: shaderModule.span(of: target)
            )
        }

        guard isArrayType else {
            wgslFatal("a call target that is not a type, a function or an array", cppSite: "TypeCheck.cpp:1746")
        }
        @inline(never)
        func arrayConstructor() throws(CompilationMessage) {
            let arraySymbol = shaderModule.symbols.intern("array")
            shaderModule.modify(CallExpression.self, id) { $0.resolvedTarget = arraySymbol }
            let array = shaderModule.dynamicDowncast(ArrayTypeExpression.self, target)
            let arrayType = targetBinding.flatMap { shaderModule.types.getIf(Types.Array.self, $0.type) }
            var elementType: TypeID?
            let elementCount: UInt32

            // DEV-08: C++ `array->span()` is the span of `target`; `array` is null for an alias of an array type, where C++
            // dereferences it (UB: Debug crashes) and the release build prints the span of `target`.
            if array?.maybeElementType != nil || arrayType != nil {
                if (array != nil && array?.maybeElementCount == nil) || arrayType?.isRuntimeSized == true {
                    throw CompilationMessage(text: "cannot construct a runtime-sized array", span: shaderModule.span(of: id))
                }

                let resolvedElementType: TypeID
                let elementCountType: TypeID
                if let arrayType {
                    resolvedElementType = arrayType.element
                    elementCountType = shaderModule.types.u32Type
                } else {
                    guard let maybeElementType = array?.maybeElementType, let maybeElementCount = array?.maybeElementCount else {
                        wgslFatal("an array type expression without an element type or count", cppSite: "TypeCheck.cpp:1762")
                    }
                    resolvedElementType = try resolve(maybeElementType)
                    elementCountType = try infer(maybeElementCount, maxEvaluation)
                }
                elementType = resolvedElementType

                // Out of line, so that the frame recursing through `infer` does not hold their locals.
                @inline(never)
                func checkElementCount() throws(CompilationMessage) -> UInt32 {
                    if !unify(shaderModule.types.i32Type, elementCountType) && !unify(shaderModule.types.u32Type, elementCountType) {
                        throw CompilationMessage(
                            text:
                                "array count must be an i32 or u32 value, found '\(ShaderModule.typeString(elementCountType, in: &shaderModule))'",
                            span: shaderModule.span(of: target)
                        )
                    }

                    guard shaderModule.isConstructible(resolvedElementType) else {
                        throw CompilationMessage(
                            text:
                                "'\(ShaderModule.typeString(resolvedElementType, in: &shaderModule))' cannot be used as an element type of an array",
                            span: shaderModule.span(of: target)
                        )
                    }

                    let constantValue: ConstantValue?
                    if arrayType == nil {
                        guard let maybeElementCount = array?.maybeElementCount else {
                            wgslFatal("an array type expression without an element count", cppSite: "TypeCheck.cpp:1775")
                        }
                        constantValue = shaderModule.constantValue(of: maybeElementCount)
                    } else if case .creationFixed(let maybeConstant) = arrayType?.size {
                        constantValue = .uint32(maybeConstant)
                    } else {
                        constantValue = nil
                    }

                    guard let constantValue else {
                        throw CompilationMessage(
                            text: "array must have constant size in order to be constructed",
                            span: shaderModule.span(of: id)
                        )
                    }

                    let intElementCount = constantValue.integerValue()
                    if intElementCount < 1 {
                        throw CompilationMessage(text: "array count must be greater than 0", span: shaderModule.span(of: id))
                    }

                    if intElementCount > Int64(UInt16.max) {
                        throw CompilationMessage(
                            text: "array count (\(intElementCount)) must be less than 65536",
                            span: shaderModule.span(of: id)
                        )
                    }
                    let elementCount = UInt32(truncatingIfNeeded: intElementCount)

                    let numberOfArguments = UInt32(truncatingIfNeeded: shaderModule.count(call.arguments))
                    if numberOfArguments != 0 && numberOfArguments != elementCount {
                        let errorKind: StaticString = shaderModule.count(call.arguments) < Int(elementCount) ? "few" : "many"
                        throw CompilationMessage(
                            text:
                                "array constructor has too \(errorKind) elements: expected \(elementCount), found \(shaderModule.count(call.arguments))",
                            span: shaderModule.span(of: id)
                        )
                    }
                    return elementCount
                }
                elementCount = try checkElementCount()

                var arguments = shaderModule.cursor(call.arguments)
                while let argument = shaderModule.next(&arguments) {
                    let argumentType = try infer(argument, maxEvaluation)
                    guard unify(resolvedElementType, argumentType) else {
                        throw CompilationMessage(
                            text:
                                "'\(ShaderModule.typeString(argumentType, in: &shaderModule))' cannot be used to construct an array of '\(ShaderModule.typeString(resolvedElementType, in: &shaderModule))'",
                            span: shaderModule.span(of: argument)
                        )
                    }
                    shaderModule.setInferredType(resolvedElementType, for: argument)
                }
            } else {
                assert(array?.maybeElementCount == nil)
                elementCount = UInt32(truncatingIfNeeded: shaderModule.count(call.arguments))
                if elementCount == 0 {
                    throw CompilationMessage(text: "cannot infer array element type from constructor", span: shaderModule.span(of: id))
                }

                var arguments = shaderModule.cursor(call.arguments)
                while let argument = shaderModule.next(&arguments) {
                    var argumentType = try infer(argument, maxEvaluation)
                    if let reference = shaderModule.types.getIf(Types.Reference.self, argumentType) {
                        argumentType = reference.element
                    }

                    guard let currentElementType = elementType else {
                        elementType = argumentType

                        guard shaderModule.isConstructible(argumentType) else {
                            throw CompilationMessage(
                                text:
                                    "'\(ShaderModule.typeString(argumentType, in: &shaderModule))' cannot be used as an element type of an array",
                                span: shaderModule.span(of: target)
                            )
                        }

                        continue
                    }
                    if unify(currentElementType, argumentType) {
                        continue
                    }
                    if unify(argumentType, currentElementType) {
                        elementType = argumentType
                        continue
                    }
                    throw CompilationMessage(
                        text: "cannot infer common array element type from constructor arguments",
                        span: shaderModule.span(of: argument)
                    )
                }

                arguments = shaderModule.cursor(call.arguments)
                while let argument = shaderModule.next(&arguments) {
                    shaderModule.setInferredType(elementType, for: argument)
                }
            }

            // Out of line, so that the frame recursing through `infer` does not hold its locals.
            @inline(never)
            func resultImpl() throws(CompilationMessage) {
                guard let elementType else {
                    wgslFatal("an array constructor without an element type", cppSite: "TypeCheck.cpp:1837")
                }
                shaderModule.modify(CallExpression.self, id) { $0.isConstructor = true }
                let result = shaderModule.types.arrayType(elementType, .creationFixed(elementCount))
                inferred(result)

                let argumentCount = shaderModule.count(call.arguments)
                // https://www.w3.org/TR/WGSL/#limits
                let maximumConstantArraySize = 2047
                // C++ fills a FixedVector(argumentCount) by index; it is only read when every argument is constant and there are at
                // most maximumConstantArraySize of them.
                let collectsArguments = argumentCount <= maximumConstantArraySize
                var arguments: [ConstantValue] = []
                if collectsArguments {
                    arguments.reserveCapacity(argumentCount)
                }
                var isConstant = true
                var evaluation = Evaluation.constant
                var i = 0
                while i < argumentCount {
                    let argument = shaderModule[call.arguments, i]
                    evaluation = cxxMax(evaluation, evaluationOfInferred(argument))
                    if !shaderModule.hasConstantValue(argument) {
                        isConstant = false
                    } else if collectsArguments {
                        arguments.append(
                            try convertedConstantValue(argument, inferredTypeOfInferred(argument), cppSite: "TypeCheck.cpp:1852")
                        )
                    } else {
                        try convertConstantValue(argument, inferredTypeOfInferred(argument), cppSite: "TypeCheck.cpp:1852")
                    }
                    i &+= 1
                }
                evaluated(evaluation)
                if isConstant {
                    if argumentCount != 0 {
                        if argumentCount > maximumConstantArraySize {
                            throw CompilationMessage(
                                text: "constant array cannot have more than \(maximumConstantArraySize) elements",
                                span: shaderModule.span(of: id)
                            )
                        }
                        try setConstantValue(id, result, .array(ConstantArray(consume arguments)))
                    } else {
                        try setZeroValue(id, result)
                    }
                }
            }
            try resultImpl()
        }
        try arrayConstructor()
    }

    mutating func bitcast(_ call: CallExpression, _ id: ExpressionID, _ typeArguments: [TypeID]) throws(CompilationMessage) {
        // The checks and the rest are out of line, so that the frame recursing through `infer` does not hold their locals.
        @inline(never)
        func checkArguments() throws(CompilationMessage) {
            let argumentCount = shaderModule.count(call.arguments)
            if argumentCount != 1 {
                throw CompilationMessage(text: "bitcast expects a single argument, found \(argumentCount)", span: shaderModule.span(of: id))
            }

            if typeArguments.count != 1 {
                throw CompilationMessage(
                    text: "bitcast expects a single template argument, found \(typeArguments.count)",
                    span: shaderModule.span(of: id)
                )
            }

            if discardResult == .yes {
                throw CompilationMessage(text: "cannot discard the result of bitcast", span: shaderModule.span(of: id))
            }
        }
        try checkArguments()

        let argument = shaderModule[call.arguments, 0]
        let destinationType = typeArguments[0]
        var sourceType = try infer(argument, maxEvaluation)

        @inline(never)
        func resultImpl() throws(CompilationMessage) {
            if let reference = shaderModule.types.getIf(Types.Reference.self, sourceType) {
                sourceType = reference.element
            }

            func primitivePrimitive(_ p1: TypeID, _ p2: TypeID, _ types: borrowing TypeStore) -> Bool {
                (satisfies(p1, .concrete32BitNumber, types) && satisfies(p2, .concrete32BitNumber, types))
                    || (p1 == types.f16Type && p2 == types.f16Type)
            }

            func vectorVector16To32Bit(_ v1: Types.Vector, _ v2: Types.Vector, _ types: borrowing TypeStore) -> Bool {
                v1.size == 2 && satisfies(v1.element, .concrete32BitNumber, types) && v2.size == 4 && v2.element == types.f16Type
            }

            func vectorVector(_ v1: Types.Vector, _ v2: Types.Vector, _ types: borrowing TypeStore) -> Bool {
                (v1.size == v2.size && primitivePrimitive(v1.element, v2.element, types))
                    || vectorVector16To32Bit(v1, v2, types)
                    || vectorVector16To32Bit(v2, v1, types)
            }

            func vectorPrimitive(_ v: Types.Vector, _ p: TypeID, _ types: borrowing TypeStore) -> Bool {
                v.size == 2 && v.element == types.f16Type && satisfies(p, .concrete32BitNumber, types)
            }

            var allowed = false
            if let dstVector = shaderModule.types.getIf(Types.Vector.self, destinationType) {
                if let srcVector = shaderModule.types.getIf(Types.Vector.self, sourceType) {
                    allowed = vectorVector(srcVector, dstVector, shaderModule.types)
                } else {
                    allowed = vectorPrimitive(dstVector, sourceType, shaderModule.types)
                }
            } else if let srcVector = shaderModule.types.getIf(Types.Vector.self, sourceType) {
                allowed = vectorPrimitive(srcVector, destinationType, shaderModule.types)
            } else {
                allowed = primitivePrimitive(sourceType, destinationType, shaderModule.types)
            }

            if allowed {
                shaderModule.setInferredType(destinationType, for: call.target)
                if let value = shaderModule.constantValue(of: argument) {
                    let result = constantBitcast(shaderModule, destinationType, [value])
                    switch consume result {
                    case .failure(let error):
                        throw CompilationMessage(text: error.message, span: shaderModule.span(of: id))
                    case .success(let value):
                        try setConstantValue(id, destinationType, value)
                    }
                }
                evaluated(evaluationOfInferred(argument))
                inferred(destinationType)
                return
            }

            let concreteType = concretizeMemoized(sourceType) ?? sourceType
            throw CompilationMessage(
                text:
                    "cannot bitcast from '\(ShaderModule.typeString(concreteType, in: &shaderModule))' to '\(ShaderModule.typeString(destinationType, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }
        try resultImpl()
    }

    mutating func chooseOverload(
        _ kind: StaticString,
        _ span: SourceSpan,
        _ expression: ExpressionID?,
        _ target: Symbol,
        _ callArguments: CallArguments,
        _ typeArguments: [TypeID]
    ) throws(CompilationMessage) -> TypeID? {
        guard let overload = shaderModule.lookupOverload(target) else {
            return nil
        }

        // C++ `valueArguments` is `argumentTypeStack[valueArgumentsStart..<argumentTypeStackTop]`, above the arguments of the
        // enclosing calls.
        let callArgumentCount = callArguments.count(shaderModule)
        let valueArgumentsStart = argumentTypeStackTop
        defer { argumentTypeStackTop = valueArgumentsStart }
        var i = 0
        while i < callArgumentCount {
            let type = try infer(callArguments.argument(i, shaderModule), maxEvaluation)
            if argumentTypeStackTop < argumentTypeStack.count {
                argumentTypeStack[argumentTypeStackTop] = type
            } else {
                argumentTypeStack.append(type)
            }
            argumentTypeStackTop &+= 1
            i &+= 1
        }

        return try chooseOverloadForArguments(
            kind,
            span,
            expression,
            target,
            overload,
            callArguments,
            callArgumentCount,
            valueArgumentsStart,
            typeArguments
        )
    }

    /// The rest of chooseOverload, outlined so that the frame recursing through `infer` stays small: inlined, Swift -O
    /// -sanitize=address overflowed 512 KiB on a 126-deep unary chain that ASan C++ survives.
    @inline(never)
    private mutating func chooseOverloadForArguments(
        _ kind: StaticString,
        _ span: SourceSpan,
        _ expression: ExpressionID?,
        _ target: Symbol,
        _ overload: OverloadedDeclaration,
        _ callArguments: CallArguments,
        _ callArgumentCount: Int,
        _ valueArgumentsStart: Int,
        _ typeArguments: [TypeID]
    ) throws(CompilationMessage) -> TypeID? {
        var i = 0
        let selectedResult = resolveOverloadsMemoized(
            target,
            overload.overloads,
            argumentTypeStack[valueArgumentsStart..<argumentTypeStackTop],
            typeArguments
        )
        if let selectedResult {
            let selectedParameters = overloadBuffers.selectedParameters
            assert(selectedParameters.count == callArgumentCount)
            if discardResult == .yes && overload.mustUse {
                throw CompilationMessage(text: "ignoring return value of builtin '\(shaderModule.symbols.text(of: target))'", span: span)
            }

            // A builtin that returns nothing, such as a barrier, cannot appear where a value is
            // expected. This is the same rule already applied to user-declared functions above.
            if discardResult == .no && shaderModule.isPrimitive(selectedResult, .void) {
                throw CompilationMessage(text: "builtin '\(shaderModule.symbols.text(of: target))' does not return a value", span: span)
            }

            i = 0
            while i < callArgumentCount {
                shaderModule.setInferredType(selectedParameters[i], for: callArguments.argument(i, shaderModule))
                i &+= 1
            }
            inferred(selectedResult)

            if let expression, shaderModule.is(CallExpression.self, expression) {
                let isConstructor = overload.kind == .constructor
                let visibility = overload.visibility
                let validationFunction = overload.validationFunction
                shaderModule.modify(CallExpression.self, expression) { call in
                    call.isConstructor = isConstructor
                    call.visibility = visibility
                    call.validationFunction = validationFunction
                }

                if shaderModule.isFloatToIntConversion(expression, selectedResult) {
                    shaderModule.uses.insert(.ftoi)
                }
            }

            // Only the function that is called reads `arguments` (constantFunction) or `validationArguments`
            // (validationFunction), so neither is built for a builtin without that function; both reuse the checker's
            // buffers.
            let argumentCount = callArgumentCount
            let collectsArguments = overload.constantFunction != nil
            let collectsValidationArguments = overload.validationFunction != nil
            var arguments: [ConstantValue] = []
            var validationArguments: [ConstantValue?] = []
            swap(&arguments, &constantArgumentsBuffer)
            swap(&validationArguments, &validationArgumentsBuffer)
            defer {
                while arguments.popLast() != nil {}
                while validationArguments.popLast() != nil {}
                swap(&arguments, &constantArgumentsBuffer)
                swap(&validationArguments, &validationArgumentsBuffer)
            }
            var isConstant = true
            var evaluation = Evaluation.constant
            i = 0
            while i < argumentCount {
                let argument = callArguments.argument(i, shaderModule)
                evaluation = cxxMax(evaluation, evaluationOfInferred(argument))
                var value: ConstantValue?
                if !shaderModule.hasConstantValue(argument) {
                    isConstant = false
                } else {
                    value = try convertedConstantValue(argument, inferredTypeOfInferred(argument), cppSite: "TypeCheck.cpp:2282")
                }
                if collectsArguments {
                    arguments.append(value ?? .defaultValue)
                }
                if collectsValidationArguments {
                    validationArguments.append(value)
                }
                i &+= 1
            }

            let constantFunction = overload.constantFunction
            if constantFunction == nil && maxEvaluation < .runtime {
                if !suppressConstantErrors {
                    throw CompilationMessage(text: "cannot call function from \(evaluationToString(maxEvaluation)) context", span: span)
                }
            }

            if constantFunction == nil {
                evaluation = .runtime
            }
            evaluated(evaluation)

            if isConstant, let constantFunction {
                let result = constantFunction(shaderModule, selectedResult, arguments)
                switch consume result {
                case .failure(let error):
                    if !suppressConstantErrors {
                        throw CompilationMessage(text: error.message, span: span)
                    }
                case .success(let value):
                    if let expression {
                        try setConstantValue(expression, selectedResult, value)
                    }
                }
            } else if let validate = overload.validationFunction {
                if let error = validate(shaderModule, validationArguments, selectedParameters) {
                    throw CompilationMessage(text: error, span: span)
                }
            }

            return selectedResult
        }

        var valueArgumentsStream = StringPrintStream()
        var first = true
        i = 0
        while i < callArgumentCount {
            if !first {
                valueArgumentsStream.print(", ")
            }
            first = false
            ShaderModule.dump(argumentTypeStack[valueArgumentsStart + i], in: &shaderModule, into: &valueArgumentsStream)
            i &+= 1
        }
        var typeArgumentsStream = StringPrintStream()
        first = true
        if !typeArguments.isEmpty {
            typeArgumentsStream.print("<")
            i = 0
            while i < typeArguments.count {
                if !first {
                    typeArgumentsStream.print(", ")
                }
                first = false
                ShaderModule.dump(typeArguments[i], in: &shaderModule, into: &typeArgumentsStream)
                i &+= 1
            }
            typeArgumentsStream.print(">")
        }

        throw CompilationMessage(
            text:
                "no matching overload for \(kind) \(shaderModule.symbols.text(of: target))\(typeArgumentsStream.toString())(\(valueArgumentsStream.toString()))",
            span: span
        )
    }

    mutating func infer(
        _ expression: ExpressionID,
        _ evaluation: Evaluation,
        _ discardResult: DiscardResult = .no
    ) throws(CompilationMessage) -> TypeID {
        if evaluation > maxEvaluation {
            throw evaluationError(expression, evaluation)
        }

        let discardResultScope = self.discardResult
        self.discardResult = discardResult
        defer { self.discardResult = discardResultScope }
        let evaluationScope = maxEvaluation
        maxEvaluation = evaluation
        defer { maxEvaluation = evaluationScope }

        assert(inferredType == nil)
        assert(currentEvaluation == nil)
        try visit(expression)
        assert(inferredType != nil)
        assert(currentEvaluation != nil)

        guard let inferredType else {
            notInferred("infer: the visit inferred no type", cppSite: "TypeCheck.cpp:2357")
        }
        guard let currentEvaluation else {
            notInferred("infer: the visit set no evaluation", cppSite: "TypeCheck.cpp:2358")
        }

        shaderModule.setInferredType(inferredType, evaluation: currentEvaluation, for: expression)
        self.inferredType = nil
        self.currentEvaluation = nil

        return inferredType
    }
}

// MARK: - Swift-only

extension TypeChecker {
    /// infer's evaluation error, out of line so that its message is not built in the frame recursing through `infer`.
    @inline(never)
    private mutating func evaluationError(_ expression: ExpressionID, _ evaluation: Evaluation) -> CompilationMessage {
        CompilationMessage(
            text: "cannot use \(evaluationToString(evaluation)) value in \(evaluationToString(maxEvaluation)) expression",
            span: shaderModule.span(of: expression)
        )
    }

    /// `concretize(type, m_types)`, memoized per type: it is a function of the type's structure that creates types only the
    /// first time, and the store is not rolled back while a TypeChecker runs.
    mutating func concretizeMemoized(_ type: TypeID) -> TypeID? {
        if let concretized = concretizedTypes.find(type) {
            return concretized
        }
        let concretized = concretize(type, &shaderModule.types)
        _ = concretizedTypes.add(type, concretized)
        return concretized
    }

    /// `resolveOverloads(m_types, overload->overloads, valueArguments, typeArguments)` through `overloadMemo`; the selected
    /// parameters are `overloadBuffers.selectedParameters`.
    mutating func resolveOverloadsMemoized(
        _ target: Symbol,
        _ candidates: [OverloadCandidate],
        _ valueArguments: ArraySlice<TypeID>,
        _ typeArguments: [TypeID]
    ) -> TypeID? {
        guard let declaration = target.builtinDeclarationIndex else {
            return resolveOverloads(&shaderModule.types, candidates, valueArguments, typeArguments, &overloadBuffers)
        }
        if let result = overloadMemo.find(declaration, valueArguments, typeArguments, &overloadBuffers) {
            return result
        }
        let result = resolveOverloads(&shaderModule.types, candidates, valueArguments, typeArguments, &overloadBuffers)
        if let result {
            overloadMemo.add(declaration, valueArguments, typeArguments, result, overloadBuffers.selectedParameters)
        }
        return result
    }

    /// C++ `auto& value = argument.m_constantValue; CHECK(convertValue(argument.span(), type, value));` followed by
    /// `*value`, which traps when a suppressed conversion error has dropped the value.
    ///
    /// `convertValue(_:_:of:)` that also copies the converted value out, in the same access to the table.
    mutating func convertedConstantValue(
        _ argument: ExpressionID,
        _ type: TypeID,
        cppSite: StaticString
    ) throws(CompilationMessage) -> ConstantValue {
        let span = shaderModule.span(of: argument)
        let suppressed = suppressConstantErrors
        var converted = true
        var result: ConstantValue?
        _ = shaderModule.modifyConstantValue(of: argument) { value, types in
            converted = convertValueImpl(span, type, &value, types)
            if converted {
                result = value
            }
            return converted || !suppressed
        }
        guard let result else {
            if !converted && !suppressed {
                throw conversionError(span, type, of: argument)
            }
            wgslFatal("*value of a constant that a suppressed conversion error dropped", cppSite: cppSite)
        }
        return result
    }

    /// `convertedConstantValue` where the value is not used: the conversion and the trap without the copy.
    mutating func convertConstantValue(_ argument: ExpressionID, _ type: TypeID, cppSite: StaticString) throws(CompilationMessage) {
        try convertValue(shaderModule.span(of: argument), type, of: argument)
        guard shaderModule.hasConstantValue(argument) else {
            wgslFatal("*value of a constant that a suppressed conversion error dropped", cppSite: cppSite)
        }
    }

    /// C++ `argument.evaluation()`, which dereferences the optional.
    @inline(__always)
    mutating func evaluationOfInferred(_ argument: ExpressionID) -> Evaluation {
        guard let evaluation = shaderModule.evaluation(of: argument) else {
            notInferred("evaluation() of an expression that was not inferred", cppSite: "ASTExpression.h:74")
        }
        return evaluation
    }

    /// C++ `argument.inferredType()` where a type is required.
    @inline(__always)
    mutating func inferredTypeOfInferred(_ argument: ExpressionID) -> TypeID {
        guard let type = shaderModule.inferredType(of: argument) else {
            notInferred("inferredType() of an expression that was not inferred", cppSite: "ASTExpression.h:68")
        }
        return type
    }

    /// C++ `CHECK(setConstantValue(call, type, zeroValue(type)))`.
    mutating func setZeroValue(_ call: ExpressionID, _ type: TypeID) throws(CompilationMessage) {
        // DEV-23: C++ materialises a zero value of any size and runs out of memory; Swift rejects one over the limit first.
        if let size = zeroValueSize(type), size > maximumZeroValueSize {
            throw CompilationMessage(
                text: "zero value of type '\(ShaderModule.typeString(type, in: &shaderModule))' is too large",
                span: shaderModule.span(of: call)
            )
        }
        try setConstantValue(call, type, zeroValue(shaderModule, type))
    }

    /// The number of constant values (scalars, vectors, matrices, arrays and structs) that `zeroValue(type)` creates.
    ///
    /// At most `maximumZeroValueSize + 1`; nil when `zeroValue(type)` traps. Iterative over the type structure; a struct with a
    /// struct inside takes a walk that sizes each type once.
    mutating func zeroValueSize(_ type: TypeID) -> UInt64? {
        let cap = maximumZeroValueSize &+ 1
        guard let chain = zeroValueChain(type) else {
            return nil
        }
        let endSize: UInt64
        if case .struct(let structType) = shaderModule.types[chain.end] {
            guard let structSize = flatStructZeroValueSize(structType) ?? structuredZeroValueSize(chain.end) else {
                return nil
            }
            endSize = structSize
        } else {
            endSize = 1
        }
        // copies <= cap < 2^27 and endSize <= cap, so the product does not wrap.
        return min(chain.size &+ min(chain.copies &* endSize, cap), cap)
    }

    /// The arrays, vectors and matrices of `zeroValue(type)` above its first scalar or struct element type `end`.
    ///
    /// `size` counts those composite values and `copies` the zero values of `end` they hold, both at most
    /// `maximumZeroValueSize + 1`. Nil when `zeroValue(type)` traps above `end` or on a scalar `end`.
    private mutating func zeroValueChain(_ type: TypeID) -> (size: UInt64, copies: UInt64, end: TypeID)? {
        let cap = maximumZeroValueSize &+ 1
        var size: UInt64 = 0
        var copies: UInt64 = 1
        var current = type
        while true {
            let count: UInt64
            let element: TypeID
            switch shaderModule.types[current] {
            case .vector(let vector):
                (count, element) = (UInt64(vector.size), vector.element)
            case .matrix(let matrix):
                (count, element) = (UInt64(matrix.columns) &* UInt64(matrix.rows), matrix.element)
            case .array(let array):
                guard case .creationFixed(let arraySize) = array.size else {
                    return nil
                }
                (count, element) = (UInt64(arraySize), array.element)
            case .struct:
                return (size: size, copies: copies, end: current)
            case .primitive, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic,
                .typeConstructor:
                guard zeroValueChildren(current) != nil else {
                    return nil
                }
                return (size: size, copies: copies, end: current)
            }
            // count < 2^32, so neither operation wraps.
            size = min(size &+ copies, cap)
            copies = min(copies &* count, cap)
            current = element
        }
    }

    /// `zeroValueSize` of a struct type whose fields hold no struct, without the memoised walk; nil for any other struct.
    private mutating func flatStructZeroValueSize(_ structType: Types.Struct) -> UInt64? {
        let cap = maximumZeroValueSize &+ 1
        let fields = shaderModule.types.fields(of: structType.fields)
        var size: UInt64 = 1
        var cursor = shaderModule.cursor(shaderModule[structType.structure].members)
        while let member = shaderModule.next(&cursor) {
            guard let fieldType = fields.find(shaderModule[shaderModule[member].originalName].symbol),
                let chain = zeroValueChain(fieldType), case .primitive = shaderModule.types[chain.end]
            else {
                return nil
            }
            size = min(size &+ min(chain.size &+ chain.copies, cap), cap)
        }
        return size
    }

    /// `zeroValueSize` for any type, with the sizes of the types it contains memoised: for the types in structs.
    private mutating func structuredZeroValueSize(_ type: TypeID) -> UInt64? {
        let cap = maximumZeroValueSize &+ 1
        // `unsized` while the type's children are being sized.
        let unsized = UInt64.max
        var sizes = SmallKeyMap<SizedType, UInt64>()
        var stack: [TypeID] = [type]
        while let current = stack.last {
            let known = sizes.find(SizedType(type: current))
            if let known, known != unsized {
                stack.removeLast()
                continue
            }
            let isFirstVisit = known == nil
            if isFirstVisit {
                sizes.add(SizedType(type: current), unsized)
            }
            guard let children = zeroValueChildren(current) else {
                return nil
            }
            var size: UInt64 = 1
            var isReady = true
            var index = 0
            while index < children.count {
                let child = children[index]
                let childSize = sizes.find(SizedType(type: child.type))
                if let childSize, childSize != unsized {
                    // count < 2^32 and childSize <= cap < 2^27, so neither operation wraps.
                    let childValues = child.count &* childSize
                    size = size &+ (childValues > cap ? cap : childValues)
                    size = size > cap ? cap : size
                } else if isFirstVisit && childSize == nil {
                    isReady = false
                    stack.append(child.type)
                } else {
                    return nil
                }
                index &+= 1
            }
            if isReady {
                sizes.set(SizedType(type: current), size)
                stack.removeLast()
            }
        }
        return sizes.find(SizedType(type: type))
    }

    /// The element or field types of `type`, each with the number of its values in `zeroValue(type)`, or nil when
    /// `zeroValue(type)` traps for `type` itself.
    private mutating func zeroValueChildren(_ type: TypeID) -> [(type: TypeID, count: UInt64)]? {
        switch shaderModule.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .abstractInt, .i32, .u32, .abstractFloat, .f32, .f16, .bool:
                return []
            case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
                return nil
            }
        case .vector(let vector):
            return [(type: vector.element, count: UInt64(vector.size))]
        case .matrix(let matrix):
            return [(type: matrix.element, count: UInt64(matrix.columns) &* UInt64(matrix.rows))]
        case .array(let array):
            guard case .creationFixed(let size) = array.size else {
                return nil
            }
            return [(type: array.element, count: UInt64(size))]
        case .struct(let structType):
            let fields = shaderModule.types.fields(of: structType.fields)
            var children: [(type: TypeID, count: UInt64)] = []
            var cursor = shaderModule.cursor(shaderModule[structType.structure].members)
            while let member = shaderModule.next(&cursor) {
                guard let fieldType = fields.find(shaderModule[shaderModule[member].originalName].symbol) else {
                    return nil
                }
                children.append((type: fieldType, count: 1))
            }
            return children
        case .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic, .typeConstructor:
            return nil
        }
    }
}

/// DEV-23's limit on the values of a zero value: C++ needs more than 4 GiB to materialise one this large.
private let maximumZeroValueSize: UInt64 = 1 << 26

/// A type, as a key of the memo of zero value sizes.
private struct SizedType: SmallKey {
    let type: TypeID

    var smallKeyBits: UInt64 { UInt64(type.raw) }
}

@inline(never)
private func notInferred(_ message: StaticString, cppSite: StaticString) -> Never {
    wgslFatal(message, cppSite: cppSite)
}

extension ShaderModule {
    /// C++ `CallExpression::isFloatToIntConversion(result)` (ASTCallExpression.h); a nil `result` stands for the call's own
    /// inferred type.
    @inline(__always)
    func isFloatToIntConversion(_ call: ExpressionID, _ result: TypeID? = nil) -> Bool {
        func getPrimitiveType(_ type: TypeID?, _ types: borrowing TypeStore) -> Types.Primitive? {
            var type = type
            if let reference = types.getIf(Types.Reference.self, type) {
                type = reference.element
            }
            if let vector = types.getIf(Types.Vector.self, type) {
                type = vector.element
            }
            return types.getIf(Types.Primitive.self, type)
        }

        let callExpression = downcast(CallExpression.self, call)
        if !callExpression.isConstructor {
            return false
        }

        guard let resultPrimitive = getPrimitiveType(result ?? inferredType(of: call), types) else {
            return false
        }
        if resultPrimitive.kind != .i32 && resultPrimitive.kind != .u32 {
            return false
        }

        if count(callExpression.arguments) != 1 {
            return false
        }

        let argument = self[callExpression.arguments, 0]
        guard let argumentPrimitive = getPrimitiveType(inferredType(of: argument), types) else {
            return false
        }
        if argumentPrimitive.kind != .f32 && argumentPrimitive.kind != .f16 && argumentPrimitive.kind != .abstractFloat {
            return false
        }

        return true
    }
}

private let subgroupPrefix = ContiguousArray("subgroup".utf16)
private let quadPrefix = ContiguousArray("quad".utf16)
private let bitcastName = ContiguousArray("bitcast".utf16)

/// WTF `String::startsWith` on a symbol's code units.
@inline(__always)
private func startsWith(_ symbols: borrowing SymbolTable, _ symbol: Symbol, _ prefix: ContiguousArray<UInt16>) -> Bool {
    guard symbols.length(of: symbol) >= prefix.count else {
        return false
    }
    var index = 0
    while index < prefix.count {
        guard symbols.codeUnit(of: symbol, at: index) == prefix[index] else {
            return false
        }
        index &+= 1
    }
    return true
}

/// WTF `String == ASCIILiteral` on a symbol's code units.
@inline(__always)
private func equal(_ symbols: borrowing SymbolTable, _ symbol: Symbol, _ text: ContiguousArray<UInt16>) -> Bool {
    symbols.length(of: symbol) == text.count && startsWith(symbols, symbol, text)
}
