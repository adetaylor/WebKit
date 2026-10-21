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
    // Declarations
    mutating func visit(_ declaration: Declaration) throws(CompilationMessage) {
        switch declaration {
        case .function(let function):
            try visit(function)
        case .variable(let variable):
            try visit(variable)
        case .structure(let structure):
            try visit(structure)
        case .typeAlias(let alias):
            try visit(alias)
        case .constAssert(let assertion):
            try visit(assertion)
        }
    }

    mutating func visit(_ structure: StructureID) throws(CompilationMessage) {
        var fields = SymbolMap<TypeID>()
        let members = shaderModule[structure].members
        let memberCount = shaderModule.count(members)
        fields.reserveInitialCapacity(memberCount)
        var isCreationFixed = true
        var i = 0
        while i < memberCount {
            let member = shaderModule[shaderModule[members, i]]
            try visitAttributes(member.attributes)
            let memberType = try resolve(member.type)

            if !shaderModule.hasCreationFixedFootprint(memberType, knownStructures: creationFixedStructures) {
                isCreationFixed = false
                guard shaderModule.containsRuntimeArray(memberType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(memberType, in: &shaderModule))' cannot be used as a struct member because it does not have creation-fixed footprint",
                        span: member.span
                    )
                }

                guard shaderModule.types.getIf(Types.Array.self, memberType) != nil else {
                    throw CompilationMessage(
                        text: "a struct that contains a runtime array cannot be nested inside another struct",
                        span: member.span
                    )
                }

                guard i == memberCount &- 1 else {
                    throw CompilationMessage(text: "runtime arrays may only appear as the last member of a struct", span: member.span)
                }
            }

            let isNewEntry = fields.add(shaderModule.symbol(of: member.name), memberType)
            assert(isNewEntry)
            i &+= 1
        }

        let structType = shaderModule.types.structType(structure, fields)
        if isCreationFixed {
            creationFixedStructures.add(structType)
        }
        shaderModule.modify(structure) { $0.inferredType = structType }
        try introduceType(shaderModule[shaderModule[structure].name], structType)
    }

    mutating func visit(_ variable: VariableID) throws(CompilationMessage) {
        let node = shaderModule[variable]
        try visitAttributes(node.attributes)

        var result: TypeID? = nil
        // C++ `std::optional<ConstantValue>* value`, which points at the initializer's constant value.
        var value = false

        var evaluation = Evaluation.runtime
        if node.flavor == .const {
            evaluation = .constant
        } else if node.flavor == .override {
            evaluation = .override
        }

        if let typeName = node.maybeTypeName {
            result = try resolve(typeName)
        }

        if let initializer = node.maybeInitializer {
            var initializerEvaluation = evaluation
            if node.flavor == .var && isModuleScope() {
                initializerEvaluation = .override
            }
            var initializerType = try infer(initializer, initializerEvaluation)
            if shaderModule.hasConstantValue(initializer) {
                value = true
            }

            if let reference = shaderModule.types.getIf(Types.Reference.self, initializerType) {
                initializerType = reference.element
                shaderModule.setInferredType(initializerType, for: initializer)
            }

            if result == nil {
                guard initializerType != shaderModule.types.voidType else {
                    throw CompilationMessage(text: "cannot initialize variable with expression of type 'void'", span: node.span)
                }

                if node.flavor == .const {
                    result = initializerType
                } else {
                    result = concretizeMemoized(initializerType)
                    guard result != nil else {
                        throw CompilationMessage(
                            text:
                                "'\(ShaderModule.typeString(initializerType, in: &shaderModule))' cannot be used as the type of a '\(variableFlavorToString(node.flavor))'",
                            span: node.span
                        )
                    }
                    shaderModule.setInferredType(result, for: initializer)
                }
            } else if let result {
                guard unify(result, initializerType) else {
                    throw CompilationMessage(
                        text:
                            "cannot initialize var of type '\(ShaderModule.typeString(result, in: &shaderModule))' with value of type '\(ShaderModule.typeString(initializerType, in: &shaderModule))'",
                        span: node.span
                    )
                }
                shaderModule.setInferredType(result, for: initializer)
            }
        }

        guard let storeType = result else {
            wgslFatal("a variable has neither a type nor an initializer", cppSite: "TypeCheck.cpp:626")
        }

        switch node.flavor {
        case .let:
            guard !isModuleScope() else {
                throw CompilationMessage(text: "module-scope 'let' is invalid, use 'const'", span: node.span)
            }
            guard shaderModule.isConstructible(storeType) || shaderModule.types.getIf(Types.Pointer.self, storeType) != nil else {
                throw CompilationMessage(
                    text: "'\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used as the type of a 'let'",
                    span: node.span
                )
            }
            guard node.maybeInitializer != nil else {
                wgslFatal("a 'let' has no initializer", cppSite: "TypeCheck.cpp:629")
            }
        case .const:
            guard node.maybeInitializer != nil else {
                wgslFatal("a 'const' has no initializer", cppSite: "TypeCheck.cpp:632")
            }
            guard shaderModule.isConstructible(storeType) else {
                throw CompilationMessage(
                    text: "'\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used as the type of a 'const'",
                    span: node.span
                )
            }
        case .override:
            guard isModuleScope() else {
                wgslFatal("an 'override' is not at module scope", cppSite: "TypeCheck.cpp:637")
            }
            guard satisfies(storeType, .concreteScalar, shaderModule.types) else {
                throw CompilationMessage(
                    text: "'\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used as the type of an 'override'",
                    span: node.span
                )
            }
            shaderModule.addOverride(variable)
        case .var:
            let addressSpace: AddressSpace
            let accessMode: AccessMode
            if let maybeQualifier = node.maybeQualifier {
                addressSpace = maybeQualifier.addressSpace
                accessMode = maybeQualifier.accessMode

                // https://www.w3.org/TR/WGSL/#access-mode - the access mode is named by a predeclared
                // enumerant, so a module-scope declaration of that name hides it and leaves the
                // qualifier naming a value that is not an access mode at all.
                if maybeQualifier.hasExplicitAccessMode && moduleScopeNames.contains(shaderModule.symbols.intern(toString(accessMode))) {
                    throw CompilationMessage(
                        text: "cannot use '\(toString(accessMode))' as access mode because it is shadowed by a module-scope declaration",
                        span: maybeQualifier.span
                    )
                }
            } else if !isModuleScope() {
                addressSpace = .function
                accessMode = .readWrite
            } else {
                addressSpace = .handle
                accessMode = .read
            }
            shaderModule.modify(variable) {
                $0.addressSpace = addressSpace
                $0.accessMode = accessMode
            }

            // https://www.w3.org/TR/WGSL/#var-and-value
            switch addressSpace {
            case .storage:
                guard accessMode != .write else {
                    throw CompilationMessage(text: "access mode 'write' is not valid for the <storage> address space", span: node.span)
                }
                guard shaderModule.isHostShareable(storeType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used in address space <storage> because it's not host-shareable",
                        span: node.span
                    )
                }
                if accessMode == .read && shaderModule.types.getIf(Types.Atomic.self, storeType) != nil {
                    throw CompilationMessage(
                        text: "atomic variables in <storage> address space must have read_write access mode",
                        span: node.span
                    )
                }
            case .uniform:
                guard shaderModule.isHostShareable(storeType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used in address space <uniform> because it's not host-shareable",
                        span: node.span
                    )
                }
                guard shaderModule.isConstructible(storeType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used in address space <uniform> because it's not constructible",
                        span: node.span
                    )
                }
            case .workgroup:
                guard shaderModule.hasFixedFootprint(storeType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used in address space <workgroup> because it doesn't have fixed footprint",
                        span: node.span
                    )
                }
            case .function:
                guard shaderModule.isConstructible(storeType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used in address space <function> because it's not constructible",
                        span: node.span
                    )
                }
            case .private:
                guard shaderModule.isConstructible(storeType) else {
                    throw CompilationMessage(
                        text:
                            "type '\(ShaderModule.typeString(storeType, in: &shaderModule))' cannot be used in address space <private> because it's not constructible",
                        span: node.span
                    )
                }
            case .handle:
                let primitive = shaderModule.types.getIf(Types.Primitive.self, storeType)
                let isTextureOrSampler =
                    shaderModule.types.getIf(Types.Texture.self, storeType) != nil
                    || shaderModule.types.getIf(Types.TextureStorage.self, storeType) != nil
                    || shaderModule.types.getIf(Types.TextureDepth.self, storeType) != nil
                    || (primitive != nil
                        && (primitive?.kind == .textureExternal || primitive?.kind == .sampler || primitive?.kind == .samplerComparison))
                guard isTextureOrSampler else {
                    throw CompilationMessage(
                        text: "module-scope 'var' declarations that are not of texture or sampler types must provide an address space",
                        span: node.span
                    )
                }
            }

            if addressSpace == .function && isModuleScope() {
                throw CompilationMessage(text: "module-scope 'var' must not use address space 'function'", span: node.span)
            }
            if addressSpace != .function && !isModuleScope() {
                throw CompilationMessage(text: "function-scope 'var' declaration must use 'function' address space", span: node.span)
            }
            if (addressSpace == .storage || addressSpace == .uniform || addressSpace == .handle || addressSpace == .workgroup)
                && node.maybeInitializer != nil
            {
                throw CompilationMessage(
                    text: "variables in the address space '\(toString(addressSpace))' cannot have an initializer",
                    span: node.span
                )
            }
            if addressSpace != .workgroup && shaderModule.containsOverrideArray(storeType) {
                throw CompilationMessage(
                    text: "array with an 'override' element count can only be used as the store type of a 'var<workgroup>'",
                    span: node.span
                )
            }
        }

        if value, let initializer = node.maybeInitializer {
            try convertValue(node.span, storeType, of: initializer)
        }

        if node.flavor != .const {
            value = false
        }

        shaderModule.modify(variable) { $0.storeType = storeType }

        var bindingType = storeType
        if node.flavor == .var {
            guard let addressSpace = shaderModule[variable].addressSpace, let accessMode = shaderModule[variable].accessMode else {
                wgslFatal("a 'var' has no address space", cppSite: "TypeCheck.cpp:726")
            }
            bindingType = shaderModule.types.referenceType(addressSpace, storeType, accessMode)
            let typeName: ExpressionID
            if let maybeTypeName = node.maybeTypeName {
                typeName = maybeTypeName
            } else {
                let typeNameSymbol = shaderModule.symbols.intern(ShaderModule.typeString(bindingType, in: &shaderModule).codeUnits)
                typeName = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(typeNameSymbol))
            }
            let referenceType = shaderModule.construct(span: shaderModule.span(of: typeName), ReferenceTypeExpression(type: typeName))
            shaderModule.setInferredType(bindingType, for: referenceType)
            shaderModule.modify(variable) { $0.maybeReferenceType = referenceType }
        }

        var bindingValue: ConstantValue? = nil
        if value, let initializer = node.maybeInitializer {
            bindingValue = shaderModule.constantValue(of: initializer)
        }
        try introduceValue(shaderModule[node.name], bindingType, evaluation, bindingValue)
    }

    mutating func visit(_ alias: TypeAliasID) throws(CompilationMessage) {
        let node = shaderModule[alias]
        let type = try resolve(node.type)
        try introduceType(shaderModule[node.name], type)
    }

    mutating func visit(_ assertion: ConstAssertID) throws(CompilationMessage) {
        let node = shaderModule[assertion]
        let testType = try infer(node.test, .constant)
        guard unify(shaderModule.types.boolType, testType) else {
            throw CompilationMessage(
                text: "const assertion condition must be a bool, got '\(ShaderModule.typeString(testType, in: &shaderModule))'",
                span: shaderModule.span(of: node.test)
            )
        }

        // TODO: we might be able to remove this since we introduced the Evaluation abovee
        guard let constantValue = shaderModule.constantValue(of: node.test) else {
            throw CompilationMessage(text: "const assertion requires a const-expression", span: shaderModule.span(of: node.test))
        }

        guard case .bool(let passed) = constantValue else {
            wgslFatal("std::get<bool> of a const assertion's non-bool value", cppSite: "TypeCheck.cpp:761")
        }
        guard passed else {
            throw CompilationMessage(text: "const assertion failed", span: node.span)
        }
    }

    mutating func visit(_ function: FunctionID) throws(CompilationMessage) {
        let node = shaderModule[function]
        var mustUse = false
        // AST::Function::stage() is filled in by AttributeValidator, which runs after this pass, so the
        // stage attribute has to be read off the function directly to know whether it is an entry point.
        var isEntryPoint = false
        var attributes = shaderModule.cursor(node.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if shaderModule.is(MustUseAttribute.self, attribute) {
                mustUse = true
                continue
            }

            if shaderModule.is(StageAttribute.self, attribute) {
                isEntryPoint = true
            }

            try visit(attribute)
        }

        var parameters: [TypeID] = []
        parameters.reserveCapacity(shaderModule.count(node.parameters))
        var parameterCursor = shaderModule.cursor(node.parameters)
        while let parameterID = shaderModule.next(&parameterCursor) {
            let parameter = shaderModule[parameterID]
            try visitAttributes(parameter.attributes)
            let parameterType = try resolve(parameter.typeName)
            if !shaderModule.isConstructible(parameterType) && shaderModule.types.getIf(Types.Pointer.self, parameterType) == nil
                && !shaderModule.isTexture(parameterType) && !shaderModule.isSampler(parameterType)
            {
                throw CompilationMessage(
                    text: "type of function parameter must be constructible or a pointer, sampler or texture",
                    span: parameter.span
                )
            }
            parameters.append(parameterType)
        }

        try visitAttributes(node.returnAttributes)
        let functionReturnType: TypeID
        if let maybeReturnType = node.maybeReturnType {
            functionReturnType = try resolve(maybeReturnType)
            returnType = functionReturnType
            guard shaderModule.isConstructible(functionReturnType) else {
                throw CompilationMessage(
                    text: "function return type must be a constructible type",
                    span: shaderModule.span(of: maybeReturnType)
                )
            }
        } else {
            functionReturnType = shaderModule.types.voidType
            returnType = functionReturnType
        }

        do {
            let functionContext = openContextScope()
            defer { closeContextScope(functionContext) }
            var i = 0
            while i < parameters.count {
                try introduceValue(shaderModule[shaderModule[shaderModule[node.parameters, i]].name], parameters[i])
                i &+= 1
            }
            // We visit the statements here instead of the compound statement since
            // we don't want to introduce an extra context scope
            let body = shaderModule.downcast(CompoundStatement.self, node.body)
            try visitStatements(body.statements)

            let behaviors = try analyze(body, node.body)
            if behaviors.contains(.next) && node.maybeReturnType != nil {
                throw CompilationMessage(text: "missing return at end of function", span: node.span)
            }
            assert(behaviors.isDisjoint(with: [.break, .continue]))
        }

        let functionType = shaderModule.types.functionType(parameters, functionReturnType, mustUse: mustUse, isEntryPoint: isEntryPoint)
        try introduceFunction(shaderModule[node.name], functionType)

        returnType = nil
    }

    // Attributes
    mutating func visit(_ attribute: AttributeID) throws(CompilationMessage) {
        switch shaderModule[attribute].kind {
        case .alignAttribute(let node):
            try visit(node, attribute)
        case .bindingAttribute(let node):
            try visit(node, attribute)
        case .groupAttribute(let node):
            try visit(node, attribute)
        case .idAttribute(let node):
            try visit(node, attribute)
        case .locationAttribute(let node):
            try visit(node, attribute)
        case .sizeAttribute(let node):
            try visit(node, attribute)
        case .workgroupSizeAttribute(let node):
            try visit(node, attribute)
        case .builtinAttribute, .constAttribute, .diagnosticAttribute, .interpolateAttribute, .invariantAttribute, .mustUseAttribute,
            .stageAttribute:
            return
        }
    }

    mutating func visit(_ attribute: AlignAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let type = try check(attribute.alignment, .concreteInteger, .constant)
        guard type != nil else {
            throw CompilationMessage(text: "@align must be an i32 or u32 value", span: shaderModule.span(of: id))
        }
    }

    mutating func visit(_ attribute: BindingAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let type = try check(attribute.binding, .concreteInteger, .constant)
        guard type != nil else {
            throw CompilationMessage(text: "@binding must be an i32 or u32 value", span: shaderModule.span(of: id))
        }
    }

    mutating func visit(_ attribute: GroupAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let type = try check(attribute.group, .concreteInteger, .constant)
        guard type != nil else {
            throw CompilationMessage(text: "@group must be an i32 or u32 value", span: shaderModule.span(of: id))
        }
    }

    mutating func visit(_ attribute: IdAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let type = try check(attribute.value, .concreteInteger, .constant)
        guard type != nil else {
            throw CompilationMessage(text: "@id must be an i32 or u32 value", span: shaderModule.span(of: id))
        }
    }

    mutating func visit(_ attribute: LocationAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let type = try check(attribute.location, .concreteInteger, .constant)
        guard type != nil else {
            throw CompilationMessage(text: "@location must be an i32 or u32 value", span: shaderModule.span(of: id))
        }
    }

    mutating func visit(_ attribute: SizeAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let type = try check(attribute.size, .concreteInteger, .constant)
        guard type != nil else {
            throw CompilationMessage(text: "@size must be an i32 or u32 value", span: shaderModule.span(of: id))
        }
    }

    mutating func visit(_ attribute: WorkgroupSizeAttribute, _ id: AttributeID) throws(CompilationMessage) {
        let xType = try infer(attribute.x, .override)
        guard satisfies(xType, .concreteInteger, shaderModule.types) else {
            throw CompilationMessage(text: "@workgroup_size x dimension must be an i32 or u32 value", span: shaderModule.span(of: id))
        }

        var yType: TypeID? = nil
        var zType: TypeID? = nil
        if let y = attribute.maybeY {
            yType = try infer(y, .override)
            guard satisfies(yType, .concreteInteger, shaderModule.types) else {
                throw CompilationMessage(text: "@workgroup_size y dimension must be an i32 or u32 value", span: shaderModule.span(of: id))
            }

            if let z = attribute.maybeZ {
                zType = try infer(z, .override)
                guard satisfies(zType, .concreteInteger, shaderModule.types) else {
                    throw CompilationMessage(
                        text: "@workgroup_size z dimension must be an i32 or u32 value",
                        span: shaderModule.span(of: id)
                    )
                }
            }
        }

        func satisfiesAll(_ type: TypeID) -> Bool {
            guard unify(type, xType) else {
                return false
            }
            if let yType, !unify(type, yType) {
                return false
            }
            if let zType, !unify(type, zType) {
                return false
            }
            return true
        }

        guard satisfiesAll(shaderModule.types.i32Type) || satisfiesAll(shaderModule.types.u32Type) else {
            throw CompilationMessage(
                text: "@workgroup_size arguments must be of the same type, either i32 or u32",
                span: shaderModule.span(of: id)
            )
        }
    }
}
