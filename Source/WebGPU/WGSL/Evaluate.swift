// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

/// C++ `HashMap<String, ConstantValue>` of override values: keyed by override key and, after validateOverrides, by
/// mangled name.
@_spi(Testing)
public typealias OverrideValues = LookupMap<Name, ConstantValue>

/// C++ `evaluate(module, expression, overrideValues)`.
///
/// The node's constant seeds the result, and a successful result is cached on the node with a write that no
/// CompilationScope undoes.
@_spi(Testing)
public func evaluate(_ shaderModule: inout ShaderModule, _ expression: ExpressionID, _ overrideValues: OverrideValues) -> ConstantValue? {
    var result = shaderModule.constantValueForEvaluateSeed(expression)

    func call(_ function: Symbol?, _ callArguments: CallArguments) -> ConstantValue? {
        let argumentCount = callArguments.count(shaderModule)
        // Allocated once the first argument has a value: most evaluations at generate time fail on it.
        var arguments: [ConstantValue] = []
        var i = 0
        while i < argumentCount {
            let argument = callArguments.argument(i, shaderModule)
            guard let value = evaluate(&shaderModule, argument, overrideValues) else {
                return nil
            }

            if i == 0 {
                arguments.reserveCapacity(argumentCount)
            }
            arguments.append(value)
            i &+= 1
        }

        if spellsArray(shaderModule.symbols, function) {
            return .array(ConstantArray(arguments))
        }

        guard let function else {
            if let type = shaderModule.inferredType(of: expression), let structType = shaderModule.types.getIf(Types.Struct.self, type) {
                var constantFields = ConstantStruct()
                let members = shaderModule[structType.structure].members
                i = 0
                while i < argumentCount {
                    let argument = arguments[i]
                    let member = shaderModule[shaderModule[members, i]]
                    constantFields.set(shaderModule.symbol(of: member.originalName), argument)
                    i &+= 1
                }
                return .struct(constantFields)
            }
            return nil
        }

        guard let overload = shaderModule.lookupOverload(function), let constantFunction = overload.constantFunction else {
            return nil
        }

        guard let resultType = shaderModule.inferredType(of: expression) else {
            wgslFatal("a constant function call without an inferred type", cppSite: "WGSL.cpp:224")
        }
        guard case .success(let result) = constantFunction(shaderModule, resultType, arguments) else {
            return nil
        }
        return result
    }

    switch shaderModule[expression].kind {
    case .binaryExpression(let binary):
        if binary.operation == .shortCircuitAnd {
            let lhsValue = evaluate(&shaderModule, binary.leftExpression, overrideValues)
            if let lhsValue, !lhsValue.toBool() {
                result = .bool(false)
            } else {
                let rhsValue = evaluate(&shaderModule, binary.rightExpression, overrideValues)
                if let lhsValue, let rhsValue {
                    result = .bool(lhsValue.toBool() && rhsValue.toBool())
                }
            }
        } else if binary.operation == .shortCircuitOr {
            let lhsValue = evaluate(&shaderModule, binary.leftExpression, overrideValues)
            if let lhsValue, lhsValue.toBool() {
                result = .bool(true)
            } else {
                let rhsValue = evaluate(&shaderModule, binary.rightExpression, overrideValues)
                if let lhsValue, let rhsValue {
                    result = .bool(lhsValue.toBool() || rhsValue.toBool())
                }
            }
        } else {
            let operation = operatorSymbol(binary.operation)
            result = call(operation, .binary(binary.leftExpression, binary.rightExpression))
        }

    case .unaryExpression(let unary):
        let operation = operatorSymbol(unary.operation)
        result = call(operation, .unary(unary.expression))

    case .identifierExpression(let identifierExpression):
        if !overrideValues.isEmpty,
            let value = overrideValues.find(shaderModule.symbols.cachedName(of: shaderModule.symbol(of: identifierExpression.identifier)))
        {
            result = value
        }

    case .callExpression(let callExpression):
        result = call(callExpression.resolvedTarget, .list(callExpression.arguments))

    // C++ has one IndexAccessExpression kind; BoundsCheck's checked accesses reach evaluate at generate time.
    case .indexAccessExpression, .checkedIndexAccessExpression:
        guard let access = shaderModule.anyIndexAccess(expression) else {
            wgslFatal("an index access that anyIndexAccess does not take apart", cppSite: "WGSL.cpp:281")
        }
        let baseValue = evaluate(&shaderModule, access.base, overrideValues)
        let indexValue = evaluate(&shaderModule, access.index, overrideValues)

        guard let baseValue, let indexValue else {
            return nil
        }

        let size = baseValue.upperBound()
        let index = indexValue.integerValue()
        if index < 0 || index >= Int64(size) {
            return nil
        }

        result = baseValue[UInt32(truncatingIfNeeded: index)]

    case .fieldAccessExpression(let access):
        let base = evaluate(&shaderModule, access.base, overrideValues)
        let fieldName = shaderModule.symbol(of: access.originalFieldName)
        let length = shaderModule.symbols.length(of: fieldName)

        guard let base else {
            break
        }

        if case .struct(let constantStruct) = base {
            result = constantStruct.get(fieldName)
            break
        }

        guard case .vector(let constantVector) = base else {
            wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "WGSL.cpp:310")
        }
        func constAccess(_ vector: ConstantVector, _ field: UInt16) -> ConstantValue {
            switch field {
            case UInt16(UInt8(ascii: "r")), UInt16(UInt8(ascii: "x")):
                return vector.elements[0]
            case UInt16(UInt8(ascii: "g")), UInt16(UInt8(ascii: "y")):
                return vector.elements[1]
            case UInt16(UInt8(ascii: "b")), UInt16(UInt8(ascii: "z")):
                return vector.elements[2]
            case UInt16(UInt8(ascii: "a")), UInt16(UInt8(ascii: "w")):
                return vector.elements[3]
            default: // lint-exempt(L-ENUM-1): a code unit
                wgslFatal("a vector field that is not a swizzle component", cppSite: "WGSL.cpp:325")
            }
        }

        if length == 1 {
            result = constAccess(constantVector, shaderModule.symbols.codeUnit(of: fieldName, at: 0))
            break
        }

        var resultVector = ConstantVector(size: length)
        var i = 0
        while i < length {
            resultVector.elements[i] = constAccess(constantVector, shaderModule.symbols.codeUnit(of: fieldName, at: i))
            i &+= 1
        }
        result = .vector(resultVector)

    // Literals
    case .abstractFloatLiteral, .abstractIntegerLiteral, .boolLiteral, .float32Literal, .float16Literal, .signed32Literal,
        .unsigned32Literal:
        guard result != nil else {
            wgslFatal("a literal without a constant value", cppSite: "WGSL.cpp:350")
        }

    case .identityExpression, .pointerDereferenceExpression, .arrayTypeExpression, .elaboratedTypeExpression, .referenceTypeExpression:
        return nil
    }

    if var value = result {
        guard let type = shaderModule.inferredType(of: expression) else {
            wgslFatal("an evaluated expression without an inferred type", cppSite: "WGSL.cpp:359")
        }
        if !convertValueImpl(shaderModule.span(of: expression), type, &value, shaderModule.types) {
            return nil
        }
        shaderModule.cacheEvaluatedConstantValue(value, for: expression)
        result = value
    }
    return result
}

/// C++ `function == "array"_s`; evaluate writes nothing but its cache, so it does not intern the text.
private func spellsArray(_ symbols: borrowing SymbolTable, _ function: Symbol?) -> Bool {
    guard let function, symbols.length(of: function) == 5 else {
        return false
    }
    return symbols.codeUnitsView(of: function).elementsEqual("array".utf16)
}

/// The predeclared symbol spelling `toASCIILiteral(operation)`, the overload `call` looks up.
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

/// The predeclared symbol spelling `toASCIILiteral(operation)`.
private func operatorSymbol(_ operation: UnaryOperation) -> Symbol {
    switch operation {
    case .addressOf: Symbol(.bitwiseAnd)
    case .complement: Symbol(.bitwiseNot)
    case .dereference: Symbol(.multiply)
    case .negate: Symbol(.minus)
    case .not: Symbol(.not)
    }
}

// MARK: - The ShaderModule::OverrideValidator closures

// The bodies of the closures that BoundsCheck.cpp and GlobalVariableRewriter.cpp register for validateOverrides.
extension ShaderModule {
    /// C++ `validator(overrideValues)`.
    mutating func runOverrideValidation(_ validation: OverrideValidation, _ overrideValues: OverrideValues) -> CompilationMessage? {
        var guardIndex = 0
        while guardIndex < validation.guards.count {
            if skipsRightHandSide(validation.guards[guardIndex], overrideValues) {
                return nil
            }
            guardIndex &+= 1
        }

        switch validation.check {
        case .boundsCheckIndex(let access, let index, let size):
            return validateBoundsCheckIndex(access, index, size, overrideValues)
        case .boundsCheckOverrideIndex(let access, let index, let constant, let sizeExpression):
            return validateBoundsCheckOverrideIndex(access, index, constant, sizeExpression, overrideValues)
        case .ensureOverrideValue(let expression):
            if case .failure(let error) = ensureOverrideValue(expression, overrideValues) {
                return error
            }
            return nil
        case .binaryValidation(let expression, let rightExpression, let validate):
            return validateBinaryExpression(expression, rightExpression, validate, overrideValues)
        case .callValidation(let expression, let validate):
            return validateCallExpression(expression, validate, overrideValues)
        case .combinedWorkgroupSize(let span, let types, let limit):
            var combinedWorkgroupVariablesSize = CheckedUInt32(0)
            var index = 0
            while index < types.count {
                combinedWorkgroupVariablesSize += Self.size(of: types[index], in: &self)
                index &+= 1
            }
            if combinedWorkgroupVariablesSize.hasOverflowed || combinedWorkgroupVariablesSize.value > limit {
                return CompilationMessage(
                    text: "The combined byte size of all variables in the workgroup address space exceeds \(limit) bytes",
                    span: span
                )
            }
            return nil
        case .combinedPrivateSize(let span, let types, let limit):
            var combinedPrivateVariablesSize = CheckedUInt32(0)
            var index = 0
            while index < types.count {
                combinedPrivateVariablesSize += Self.size(of: types[index], in: &self)
                index &+= 1
            }
            if combinedPrivateVariablesSize.hasOverflowed || combinedPrivateVariablesSize.value > limit {
                return CompilationMessage(
                    text: "The combined byte size of all variables in the private address space exceeds \(limit) bytes",
                    span: span
                )
            }
            return nil
        }
    }

    private mutating func skipsRightHandSide(_ expression: ExpressionID, _ overrideValues: OverrideValues) -> Bool {
        let binary = downcast(BinaryExpression.self, expression)
        assert(binary.operation == .shortCircuitAnd || binary.operation == .shortCircuitOr)

        guard let value = evaluate(&self, binary.leftExpression, overrideValues), case .bool(let bool) = value else {
            return false
        }

        return bool == (binary.operation == .shortCircuitOr)
    }

    private mutating func validateBoundsCheckIndex(
        _ access: ExpressionID,
        _ indexExpression: ExpressionID,
        _ size: UInt32,
        _ constantValues: OverrideValues
    ) -> CompilationMessage? {
        let index = evaluate(&self, indexExpression, constantValues)

        if let index, index.integerValue() < 0 || index.integerValue() >= Int64(size) {
            return CompilationMessage(text: "index \(index.integerValue()) out of bounds[0..\(size &- 1)]", span: span(of: access))
        }

        return nil
    }

    private mutating func validateBoundsCheckOverrideIndex(
        _ access: ExpressionID,
        _ indexExpression: ExpressionID,
        _ sizeConstant: UInt32?,
        _ sizeExpression: ExpressionID?,
        _ constantValues: OverrideValues
    ) -> CompilationMessage? {
        let index = evaluate(&self, indexExpression, constantValues)
        var size: Int64?
        if let sizeConstant {
            size = Int64(sizeConstant)
        } else if let sizeExpression {
            if let maybeSize = evaluate(&self, sizeExpression, constantValues) {
                size = maybeSize.integerValue()
            }
        }

        if let size, size < 1 {
            return CompilationMessage(text: "array count must be greater than 0", span: span(of: access))
        }

        if let index, index.integerValue() < 0 || (size.map { index.integerValue() >= $0 } ?? false) {
            let bounds: MessageText = if let size { " [0..\(size &- 1)]" } else { "" }
            return CompilationMessage(text: "index \(index.integerValue()) out of bounds\(bounds)", span: span(of: access))
        }

        if (sizeExpression != nil || sizeConstant != nil) && (index == nil || size == nil) {
            replaceUnvalidatedOverrideIndexAccess(access, sizeConstant, sizeExpression)
        }

        return nil
    }

    private mutating func validateBinaryExpression(
        _ expression: ExpressionID,
        _ rightExpression: ExpressionID,
        _ validate: ValidationFunction,
        _ overrideValues: OverrideValues
    ) -> CompilationMessage? {
        // Once pack() has wrapped the binary in an IdentityExpression, C++ reads that IdentityExpression's expression, which
        // shares its offset with m_lhs, as the left operand, and the binary's old m_rhs as the right one.
        let leftExpression =
            if let identity = dynamicDowncast(IdentityExpression.self, expression) {
                identity.expression
            } else {
                downcast(BinaryExpression.self, expression).leftExpression
            }
        var validationArguments: [ConstantValue?] = Array(repeatElement(nil, count: 2))
        if let value = evaluate(&self, leftExpression, overrideValues) {
            validationArguments[0] = value
        }
        if let value = evaluate(&self, rightExpression, overrideValues) {
            validationArguments[1] = value
        }

        guard let leftType = inferredType(of: leftExpression), let rightType = inferredType(of: rightExpression) else {
            wgslFatal("a validated operand without an inferred type", cppSite: "GlobalVariableRewriter.cpp:673")
        }
        let paramTypes = [leftType, rightType]

        if let error = validate(self, validationArguments, paramTypes) {
            return CompilationMessage(text: error, span: span(of: expression))
        }

        return nil
    }

    private mutating func validateCallExpression(
        _ expression: ExpressionID,
        _ validate: ValidationFunction,
        _ overrideValues: OverrideValues
    ) -> CompilationMessage? {
        let call = downcast(CallExpression.self, expression)
        let argumentCount = count(call.arguments)
        var validationArguments: [ConstantValue?] = Array(repeatElement(nil, count: argumentCount))
        var i = 0
        while i < argumentCount {
            if let value = evaluate(&self, self[call.arguments, i], overrideValues) {
                validationArguments[i] = value
            }
            i &+= 1
        }

        var paramTypes: [TypeID] = []
        paramTypes.reserveCapacity(argumentCount)
        i = 0
        while i < argumentCount {
            guard let type = inferredType(of: self[call.arguments, i]) else {
                wgslFatal("a validated argument without an inferred type", cppSite: "GlobalVariableRewriter.cpp:794")
            }
            paramTypes.append(type)
            i &+= 1
        }

        if let error = validate(self, validationArguments, paramTypes) {
            return CompilationMessage(text: error, span: span(of: expression))
        }

        return nil
    }
}

// MARK: - Testing hooks

// These hooks drive validateOverrides through ModuleState.withTestScope without the prepare passes, which register the
// override validations and compute the reflection that validateOverrides reads.
extension ShaderModule {
    /// validateOverrides for a prepare result with one entry point, which uses the overrides keyed `specializationConstantKeys`.
    @_spi(Testing)
    public mutating func validateOverridesForTesting(
        specializationConstantKeys: [Name],
        _ overrideValues: inout OverrideValues
    ) -> CompilationMessage? {
        var specializationConstants: [SpecializationConstant] = []
        var index = 0
        while index < specializationConstantKeys.count {
            specializationConstants.append(SpecializationConstant(key: specializationConstantKeys[index], mangledName: "", type: .unsigned))
            index &+= 1
        }
        let entryPoint = EntryPointInformation(
            originalName: Name(utf16: []),
            mangledName: "",
            stage: .compute,
            typedEntryPoint: .compute,
            defaultLayout: nil,
            specializationConstants: specializationConstants,
            sizeForWorkgroupVariables: 0,
            bindingCount: 0,
            usesInvariant: false
        )
        return validateOverrides([entryPoint], &overrideValues)
    }

    /// The validation BoundsCheck.cpp:152 registers for a vector or matrix access.
    @_spi(Testing)
    public mutating func addOverrideValidationForTesting(boundsCheckOf access: ExpressionID, index: ExpressionID, size: UInt32) {
        addOverrideValidation(OverrideValidation(guards: [], check: .boundsCheckIndex(access: access, index: index, size: size)))
    }

    /// The validation BoundsCheck.cpp:220 registers for an array access.
    @_spi(Testing)
    public mutating func addOverrideValidationForTesting(
        boundsCheckOf access: ExpressionID,
        index: ExpressionID,
        constant: UInt32?,
        sizeExpression: ExpressionID?
    ) {
        let check = OverrideValidation.Check.boundsCheckOverrideIndex(
            access: access,
            index: index,
            constant: constant,
            sizeExpression: sizeExpression
        )
        addOverrideValidation(OverrideValidation(guards: [], check: check))
    }

    /// The validation GlobalVariableRewriter.cpp:657-665 registers for a binary expression whose operator has a validation
    /// function.
    @_spi(Testing)
    public mutating func addOverrideValidationForTesting(validationOfBinaryExpression expression: ExpressionID, guards: [ExpressionID]) {
        let binary = downcast(BinaryExpression.self, expression)
        guard let validate = lookupOverload(operatorSymbol(binary.operation))?.validationFunction else {
            wgslFatal("a binary operator without a validation function", cppSite: "GlobalVariableRewriter.cpp:660")
        }
        let check = OverrideValidation.Check.binaryValidation(expression, rightExpression: binary.rightExpression, validate)
        addOverrideValidation(OverrideValidation(guards: guards, check: check))
    }

    /// The validation GlobalVariableRewriter.cpp:784-785 registers for a call whose overload has a validation function.
    @_spi(Testing)
    public mutating func addOverrideValidationForTesting(validationOfCallExpression expression: ExpressionID, guards: [ExpressionID]) {
        guard let validate = downcast(CallExpression.self, expression).validationFunction else {
            wgslFatal("a call without a validation function", cppSite: "GlobalVariableRewriter.cpp:784")
        }
        addOverrideValidation(OverrideValidation(guards: guards, check: .callValidation(expression, validate)))
    }

    /// The validations GlobalVariableRewriter.cpp:1522 (`workgroup`) and :1530 register.
    @_spi(Testing)
    public mutating func addOverrideValidationForTesting(combinedSizeOf types: [TypeID], workgroup: Bool, span: SourceSpan, limit: UInt32) {
        let check: OverrideValidation.Check =
            if workgroup {
                .combinedWorkgroupSize(span: span, types: types, limit: limit)
            } else {
                .combinedPrivateSize(span: span, types: types, limit: limit)
            }
        addOverrideValidation(OverrideValidation(guards: [], check: check))
    }
}
