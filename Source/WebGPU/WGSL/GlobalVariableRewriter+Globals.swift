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

private func buffersForStage(_ configuration: Configuration, _ stage: ShaderStage) -> UInt32 {
    switch stage {
    case .compute:
        configuration.maxBuffersForComputeStage
    case .vertex:
        configuration.maxBuffersPlusVertexBuffersForVertexStage
    case .fragment:
        configuration.maxBuffersForFragmentStage
    }
}

extension RewriteGlobalVariables {
    mutating func collectGlobals() -> CompilationMessage? {
        var bufferLengths: [(variable: VariableID, group: UInt32)] = []
        // we can't use a range-based for loop here since we might create new structs
        // and insert them into the declarations vector
        let size = shaderModule.count(shaderModule.declarations)
        globals.reserveInitialCapacity(size)
        var i = 0
        while i < size {
            let declaration = shaderModule[shaderModule.declarations, i]
            i &+= 1
            guard case .variable(let globalVar) = declaration else {
                continue
            }
            let variable = shaderModule[globalVar]
            var resource: Global.Resource?
            if let group = variable.group {
                guard let binding = variable.binding else {
                    wgslFatal("a global with @group has no @binding", cppSite: "GlobalVariableRewriter.cpp:860")
                }
                let bufferIndex = group
                let buffersCountForStage = buffersForStage(shaderModule.configuration, stage)
                if bufferIndex >= buffersCountForStage {
                    return CompilationMessage(
                        text:
                            "global has buffer index \(bufferIndex) which exceeds the max allowed buffer index \(buffersCountForStage) for this stage",
                        span: .empty
                    )
                }

                resource = Global.Resource(group: group, binding: binding)
                if bufferLengths.capacity == 0 {
                    // The first resource: room for every declaration left to be one.
                    bufferLengths.reserveCapacity(size &- i &+ 1)
                    globalsByBinding.reserveInitialCapacity(size &- i &+ 1)
                }
            }

            let name = shaderModule.symbol(of: variable.name)
            let result = globals.add(name, Global(resource: resource, declaration: globalVar))
            assert(result)

            if let resource {
                // DEV-05: an ordinary key; C++ keys on {group + 1, binding + 1}, which traps on the hash table's empty and deleted keys.
                globalsByBinding.add(BindingKey(resource), globalVar)

                groupBindingMap.modify(UInt64(resource.group), default: []) { $0.append((binding: resource.binding, name: name)) }
                packResource(globalVar)

                bufferLengths.append((variable: globalVar, group: resource.group))
            }
        }

        groupBindingMap.modifyEach { _, vector in
            vector.sort { $0.binding < $1.binding }
        }

        if !bufferLengths.isEmpty {
            var index = 0
            while index < bufferLengths.count {
                let (variable, group) = bufferLengths[index]
                index &+= 1
                let name = shaderModule.symbols.intern(.arrayLength(of: shaderModule.symbol(of: shaderModule[variable].name)))
                let lengthType = bufferLengthType()
                let attributes = shaderModule.makeEmptyList(AttributeID.self)
                let lengthVariable = shaderModule.constructVariable(
                    span: .empty,
                    flavor: .var,
                    name: shaderModule.makeIdentifier(name),
                    type: lengthType,
                    initializer: nil,
                    attributes: attributes
                )
                let lengthReferenceType = bufferLengthReferenceType()
                shaderModule.modify(lengthVariable) { $0.maybeReferenceType = lengthReferenceType }

                let maybeBinding = groupBindingMap.modify(UInt64(group)) { vector -> UInt32 in
                    guard let last = vector.last else {
                        wgslFatal("Vector::last() of an empty group", cppSite: "GlobalVariableRewriter.cpp:906")
                    }
                    let binding = last.binding &+ 1
                    vector.append((binding: binding, name: name))
                    return binding
                }
                guard let binding = maybeBinding else {
                    wgslFatal("a buffer's group is not in m_groupBindingMap", cppSite: "GlobalVariableRewriter.cpp:904")
                }

                let result = globals.add(
                    name,
                    Global(resource: Global.Resource(group: group, binding: binding), declaration: lengthVariable)
                )
                assert(result)

                bufferLengthMap.add(variable, lengthVariable)
                reverseBufferLengthMap.add(lengthVariable, variable)
            }
        }

        return nil
    }

    mutating func bufferLengthType() -> ExpressionID {
        if let cachedBufferLengthType {
            return cachedBufferLengthType
        }
        let bufferLengthType = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier("u32"))
        shaderModule.setInferredType(shaderModule.types.u32Type, for: bufferLengthType)
        cachedBufferLengthType = bufferLengthType
        return bufferLengthType
    }

    mutating func bufferLengthReferenceType() -> ExpressionID {
        if let cachedBufferLengthReferenceType {
            return cachedBufferLengthReferenceType
        }

        let lengthType = bufferLengthType()
        let bufferLengthReferenceType = shaderModule.construct(span: .empty, ReferenceTypeExpression(type: lengthType))
        shaderModule.setInferredType(
            shaderModule.types.referenceType(.handle, shaderModule.types.u32Type, .read),
            for: bufferLengthReferenceType
        )
        cachedBufferLengthReferenceType = bufferLengthReferenceType
        return bufferLengthReferenceType
    }

    mutating func packResource(_ global: VariableID) {
        guard let maybeTypeName = shaderModule[global].maybeTypeName else {
            wgslFatal("a resource variable without a type", cppSite: "GlobalVariableRewriter.cpp:953")
        }

        let resolvedType = shaderModule.inferredType(of: maybeTypeName)
        if let arrayType = shaderModule.types.getIf(Types.Array.self, resolvedType) {
            packArrayResource(global, arrayType)
            return
        }

        if let structType = resolvedType, shaderModule.types.getIf(Types.Struct.self, structType) != nil {
            packStructResource(global, structType)
            return
        }

        if let matrixType = shaderModule.types.getIf(Types.Matrix.self, resolvedType) {
            if matrixType.rows == 3 {
                shaderModule.uses.insert(.packedVec3)
                shaderModule.uses.insert(.packVector)
                shaderModule.uses.insert(.unpackVector)
                shaderModule.modify(global) { $0.role = .packedResource }
            }
            return
        }
    }

    /// `structType` is the TypeID of a struct type (C++ `const Types::Struct*`).
    mutating func packStructResource(_ global: VariableID, _ structType: TypeID) {
        guard let packedStructType = packStructType(structType) else {
            return
        }

        guard case .struct(let packedStruct) = shaderModule.types[packedStructType] else {
            wgslFatal("std::get<Types::Struct> of a packed struct type", cppSite: "GlobalVariableRewriter.cpp:983")
        }
        let packedType = shaderModule.constructIdentifierExpression(
            span: .empty,
            identifier: shaderModule.makeIdentifier(shaderModule.symbol(of: shaderModule[packedStruct.structure].name))
        )
        shaderModule.setInferredType(packedStructType, for: packedType)
        guard let namedTypeName = shaderModule[global].maybeTypeName else {
            wgslFatal("a resource variable without a type", cppSite: "GlobalVariableRewriter.cpp:986")
        }
        _ = shaderModule.downcast(IdentifierExpression.self, namedTypeName)
        shaderModule.replace(namedTypeName, with: packedType)
        updateReference(global, packedType)
        shaderModule.modify(global) { $0.role = .packedResource }
    }

    mutating func packArrayResource(_ global: VariableID, _ arrayType: Types.Array) {
        guard let packedArrayType = packArrayType(arrayType) else {
            return
        }

        guard case .array(let packedArray) = shaderModule.types[packedArrayType] else {
            wgslFatal("std::get<Types::Array> of a packed array type", cppSite: "GlobalVariableRewriter.cpp:998")
        }
        let packedElementType = packedArray.element
        let packedType = shaderModule.constructIdentifierExpression(
            span: .empty,
            // This name is not used by the codegen
            identifier: shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.packedArray)))
        )
        shaderModule.setInferredType(packedElementType, for: packedType)

        guard let typeName = shaderModule[global].maybeTypeName else {
            wgslFatal("a resource variable without a type", cppSite: "GlobalVariableRewriter.cpp:1005")
        }
        let maybeArrayTypeName = shaderModule.dynamicDowncast(ArrayTypeExpression.self, typeName)
        let packedArrayTypeName = shaderModule.construct(
            span: shaderModule.span(of: typeName),
            ArrayTypeExpression(maybeElementType: packedType, maybeElementCount: maybeArrayTypeName?.maybeElementCount)
        )
        shaderModule.setInferredType(packedArrayType, for: packedArrayTypeName)

        if maybeArrayTypeName != nil {
            shaderModule.replace(typeName, with: packedArrayTypeName)
        } else {
            _ = shaderModule.downcast(IdentifierExpression.self, typeName)
            shaderModule.replace(typeName, with: packedArrayTypeName)
        }
        updateReference(global, packedArrayTypeName)
        shaderModule.modify(global) { $0.role = .packedResource }
    }

    mutating func updateReference(_ global: VariableID, _ packedType: ExpressionID) {
        guard let maybeReference = shaderModule[global].maybeReferenceType else {
            wgslFatal("a resource variable without a reference type", cppSite: "GlobalVariableRewriter.cpp:1026")
        }
        _ = shaderModule.downcast(ReferenceTypeExpression.self, maybeReference)
        guard let referenceType = shaderModule.types.getIf(Types.Reference.self, shaderModule.inferredType(of: maybeReference)) else {
            wgslFatal("a reference type expression whose type is not a reference", cppSite: "GlobalVariableRewriter.cpp:1034")
        }
        let packedTypeReference = shaderModule.construct(span: .empty, ReferenceTypeExpression(type: packedType))
        guard let packedStoreType = shaderModule.inferredType(of: packedType) else {
            wgslFatal("a packed type without a type", cppSite: "GlobalVariableRewriter.cpp:1035")
        }
        shaderModule.setInferredType(
            shaderModule.types.referenceType(referenceType.addressSpace, packedStoreType, referenceType.accessMode),
            for: packedTypeReference
        )
        shaderModule.replace(maybeReference, with: packedTypeReference)
    }

    /// C++ packType, as one step of packTypes: the packed type (nil for none), or the packStructType or packArrayType call
    /// it returns.
    mutating func packType(_ type: TypeID?) -> PackTypeStep {
        if let structType = type, shaderModule.types.getIf(Types.Struct.self, structType) != nil {
            return .packStructType(structType)
        }
        if let arrayType = shaderModule.types.getIf(Types.Array.self, type) {
            return .packArrayType(type, arrayType)
        }
        if let vectorType = shaderModule.types.getIf(Types.Vector.self, type) {
            if vectorType.size == 3 {
                shaderModule.uses.insert(.packedVec3)
                return .packed(type)
            }
        }
        if let matrixType = shaderModule.types.getIf(Types.Matrix.self, type) {
            if matrixType.rows == 3 {
                shaderModule.uses.insert(.packedVec3)
                shaderModule.uses.insert(.packVector)
                shaderModule.uses.insert(.unpackVector)
                return .packed(type)
            }
        }
        return .packed(nil)
    }

    /// `structType` is the TypeID of a struct type, the key of `packedStructTypes` (C++ `const Types::Struct*`).
    mutating func packStructType(_ structType: TypeID) -> TypeID? {
        packTypes(.packStructType(structType))
    }

    /// C++ packStructType up to its loop over the members, which packTypes runs with the frame pushed here.
    mutating func packStructType(_ structType: TypeID, _ frames: inout [PackTypeFrame]) -> PackTypeStep {
        guard case .struct(let structTypePayload) = shaderModule.types[structType] else {
            wgslFatal("packStructType of a type that is not a struct", cppSite: "GlobalVariableRewriter.cpp:1064")
        }
        let structure = structTypePayload.structure
        if shaderModule[structure].role == .userDefinedResource {
            return .packed(packedStructTypes.get(structType))
        }

        // Ensure we pack nested structs
        frames.append(
            .structType(structType, structure, members: shaderModule.cursor(shaderModule[structure].members), packedAnyMember: false)
        )
        return .nextMember
    }

    /// C++ packStructType after its loop over the members.
    mutating func packStructType(_ structType: TypeID, _ structure: StructureID, packedAnyMember: Bool) -> TypeID? {
        if !packedAnyMember && !shaderModule[structure].hasSizeOrAlignmentAttributes {
            return nil
        }

        assert(shaderModule[structure].role == .userDefined)
        shaderModule.modify(structure) { $0.role = .userDefinedResource }

        let packedStructName = shaderModule.symbols.intern(.packedStruct(of: shaderModule.symbol(of: shaderModule[structure].name)))

        let members = shaderModule.makeList(shaderModule.elements(shaderModule[structure].members))
        let packedStruct = shaderModule.constructStructure(
            span: .empty,
            name: shaderModule.makeIdentifier(packedStructName),
            members: members,
            role: .packedResource,
            original: structure
        )
        shaderModule.append(shaderModule.declarations, .structure(packedStruct))
        let packedStructType = shaderModule.types.structType(packedStruct)
        shaderModule.modify(packedStruct) { $0.inferredType = packedStructType }
        packedStructTypes.add(structType, packedStructType)
        return packedStructType
    }

    mutating func packArrayType(_ arrayType: Types.Array) -> TypeID? {
        packTypes(.packArrayType(nil, arrayType))
    }

    /// C++ packArrayType after the packType of the element, which packTypes makes.
    mutating func packArrayType(_ arrayType: Types.Array, packedElementType: TypeID?) -> TypeID? {
        guard let packedElementType else {
            return nil
        }

        shaderModule.uses.insert(.unpackArray)
        shaderModule.uses.insert(.packArray)
        return shaderModule.types.arrayType(packedElementType, arrayType.size)
    }
}

private func getRoundedSize(_ shaderModule: inout ShaderModule, _ variable: VariableID) -> UInt64 {
    var size: UInt32 = 0
    if let type = shaderModule[variable].storeType {
        size = ShaderModule.size(of: type, in: &shaderModule).bytes
    }
    return UInt64(wtfRoundUpToMultipleOf(16, size))
}

extension RewriteGlobalVariables {
    mutating func insertParameter(
        _ span: SourceSpan,
        _ function: FunctionID,
        _ group: UInt32,
        _ name: Identifier,
        _ type: ExpressionID? = nil,
        _ parameterRole: ParameterRole = .bindGroup
    ) {
        let parameterType: ExpressionID
        if let type {
            parameterType = type
        } else {
            let structName = argumentBufferStructName(group)
            parameterType = shaderModule.constructIdentifierExpression(span: span, identifier: structName)
            shaderModule.setInferredType(structTypes.get(UInt64(group)), for: parameterType)
        }
        let groupValue = shaderModule.construct(span: span, AbstractIntegerLiteral(value: Int64(group)))
        shaderModule.setInferredType(shaderModule.types.abstractIntType, for: groupValue)
        shaderModule.setConstantValue(.uint32(group), for: groupValue)
        let groupAttribute = shaderModule.construct(span: span, .groupAttribute(GroupAttribute(group: groupValue)))
        let attributes = shaderModule.makeList([groupAttribute])
        let parameter = shaderModule.constructParameter(
            span: span,
            name: name,
            typeName: parameterType,
            attributes: attributes,
            role: parameterRole
        )
        shaderModule.append(shaderModule[function].parameters, parameter)
    }

    /// On success, stores the entry point's `EntryPointInitialized` (from insertLocalDefinitions, or entryPointReadsNoGlobals when
    /// `reads` is empty) in its information.
    mutating func visitEntryPoint(_ entryPoint: CallGraph.EntryPoint) -> CompilationMessage? {
        let originalName = entryPoint.apiName
        // C++ `it->value`: the index of the explicit layout in `explicitLayouts`, or nil for a default layout.
        guard let pipelineLayout = pipelineLayouts.find(originalName) else {
            return nil
        }

        reads.clear()
        structTypes.clear()
        globalsUsingDynamicOffset.clear()
        generateLayoutGroupMapping.clear()

        let information = Reflection.EntryPointInformation(
            originalName: originalName,
            mangledName: shaderModule.symbol(of: shaderModule[entryPoint.function].name),
            stage: entryPoint.stage
        )
        guard let result = entryPointInformations.add(information) else {
            wgslFatal("an entry point's information is added twice", cppSite: "GlobalVariableRewriter.cpp:1147")
        }

        stage = entryPoint.stage
        entryPointInformation = result

        let function = shaderModule[entryPoint.function]
        switch stage {
        case .compute:
            var attributes = shaderModule.cursor(function.attributes)
            while let attribute = shaderModule.next(&attributes) {
                guard let workgroupSize = shaderModule.dynamicDowncast(WorkgroupSizeAttribute.self, attribute) else {
                    continue
                }
                let typedEntryPoint = Reflection.TypedEntryPoint.compute(
                    Reflection.WorkgroupSize(width: workgroupSize.x, height: workgroupSize.maybeY, depth: workgroupSize.maybeZ)
                )
                modifyEntryPointInformation { $0.typedEntryPoint = typedEntryPoint }
                break
            }
        case .vertex:
            modifyEntryPointInformation { $0.typedEntryPoint = .vertex(invariantIsPresent: false) }
            if function.returnTypeInvariant {
                modifyEntryPointInformation { $0.usesInvariant = true }
            } else if let returnType = function.maybeReturnType {
                if let structType = shaderModule.types.getIf(Types.Struct.self, shaderModule.inferredType(of: returnType)) {
                    var members = shaderModule.cursor(shaderModule[structType.structure].members)
                    while let member = shaderModule.next(&members) {
                        if shaderModule[member].invariant {
                            modifyEntryPointInformation { $0.usesInvariant = true }
                            break
                        }
                    }
                }
            }
        case .fragment:
            modifyEntryPointInformation { $0.typedEntryPoint = .fragment }
        }

        switch pipelineLayout {
        case .none:
            modifyEntryPointInformation { $0.defaultLayout = PipelineLayout() }
            generatedLayout = result
        case .some(let explicitLayout):
            generatedLayout = nil
            collectDynamicOffsetGlobals(explicitLayout: explicitLayout)
        }

        visit(entryPoint.function)
        if hasError {
            return expectedError
        }

        if reads.isEmpty {
            insertDynamicOffsetsBufferIfNeeded(entryPoint.function)
            let initialized = entryPointReadsNoGlobals(entryPoint.function)
            modifyEntryPointInformation { $0.initialized = initialized }
            return nil
        }

        let maybeUsedGlobals: UsedGlobals
        do {
            maybeUsedGlobals = try determineUsedGlobals(entryPoint)
        } catch {
            insertDynamicOffsetsBufferIfNeeded(entryPoint.function)
            return error
        }
        let usedGlobals = maybeUsedGlobals.wtfCopy()
        if let explicitLayout = pipelineLayout {
            if let error = errorValidatingTextureSamplerPairs(entryPoint, explicitLayout: explicitLayout) {
                insertDynamicOffsetsBufferIfNeeded(entryPoint.function)
                return error
            }
        }
        let groups: [UInt32]
        if let explicitLayout = pipelineLayout {
            do {
                groups = try insertStructs(explicitLayout: explicitLayout, usedGlobals.resources)
            } catch {
                insertDynamicOffsetsBufferIfNeeded(entryPoint.function)
                return error
            }
        } else {
            groups = insertStructs(usedGlobals.resources)
        }
        insertParameters(entryPoint.function, groups)
        insertMaterializations(entryPoint.function, usedGlobals.resources)
        let initialized = insertLocalDefinitions(entryPoint.function, usedGlobals.privateGlobals)
        modifyEntryPointInformation { $0.initialized = initialized }
        validateUsedGlobals(usedGlobals)

        var index = 0
        while index < usedGlobals.privateGlobals.count {
            let variable = usedGlobals.privateGlobals[index].declaration
            index &+= 1
            if shaderModule[variable].addressSpace == .workgroup {
                let roundedSize = getRoundedSize(&shaderModule, variable)
                modifyEntryPointInformation { $0.sizeForWorkgroupVariables &+= roundedSize }
            }
        }
        return nil
    }

    mutating func validateUsedGlobals(_ usedGlobals: UsedGlobals) {
        func validateGlobal(_ global: Global) {
            let variable = shaderModule[global.declaration]
            if let initializer = variable.maybeInitializer {
                if shaderModule.constantValueForGlobalValidation(initializer) != nil {
                    return
                }
                shaderModule.addOverrideValidation(OverrideValidation(guards: [], check: .ensureOverrideValue(initializer)))
            }
        }

        forEachElement(usedGlobals.privateGlobals) { global in
            validateGlobal(global)
        }

        forEachElement(usedGlobals.resources) { _, bindings in
            forEachElement(bindings) { _, global in
                validateGlobal(global)
            }
        }
    }

    /// `explicitLayout` indexes `explicitLayouts`.
    mutating func collectDynamicOffsetGlobals(explicitLayout: Int) {
        let bindGroupLayouts = explicitLayouts[explicitLayout].bindGroupLayouts
        var group: UInt32 = 0
        var bindGroupLayoutIndex = 0
        while bindGroupLayoutIndex < bindGroupLayouts.count {
            let entries = bindGroupLayouts[bindGroupLayoutIndex]
            var entryIndex = 0
            while entryIndex < entries.count {
                let entry = entries[entryIndex]
                entryIndex &+= 1
                if !entry.visibility.contains(ShaderStages(stage)) {
                    continue
                }

                let bufferDynamicOffset =
                    switch stage {
                    case .vertex:
                        entry.vertex.bufferDynamicOffset
                    case .fragment:
                        entry.fragment.bufferDynamicOffset
                    case .compute:
                        entry.compute.bufferDynamicOffset
                    }

                guard let bufferDynamicOffset else {
                    continue
                }

                // DEV-05: an ordinary key; C++ keys on {group + 1, binding + 1}, which traps on the hash table's empty and deleted keys.
                globalsUsingDynamicOffset.add(
                    BindingKey(ResourceBinding(group: group, binding: entry.binding)),
                    DynamicOffsetSlot(bufferDynamicOffset)
                )
            }
            group &+= 1
            bindGroupLayoutIndex &+= 1
        }
    }
}

private func convertAccess(_ accessMode: AccessMode) -> StorageTextureAccess {
    switch accessMode {
    case .read:
        .readOnly
    case .readWrite:
        .readWrite
    case .write:
        .writeOnly
    }
}

/// The `addressSpace` lambda of bindingMemberForGlobal.
private func bufferBindingType(_ shaderModule: borrowing ShaderModule, _ maybeReference: ExpressionID?) -> BufferBindingType {
    if let maybeReference {
        _ = shaderModule.downcast(ReferenceTypeExpression.self, maybeReference)
        let referenceType = shaderModule.types.getIf(Types.Reference.self, shaderModule.inferredType(of: maybeReference))
        if let referenceType, referenceType.addressSpace == .storage {
            return referenceType.accessMode == .read ? .readOnlyStorage : .storage
        }
    }

    return .uniform
}

extension RewriteGlobalVariables {
    static func bindingMemberForGlobal(_ shaderModule: borrowing ShaderModule, _ global: Global) -> BindingMember {
        let variable = shaderModule[global.declaration]
        let maybeReference = variable.maybeReferenceType
        guard let type = variable.storeType else {
            wgslFatal("a resource variable without a store type", cppSite: "GlobalVariableRewriter.cpp:1306")
        }

        switch shaderModule.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .abstractInt, .i32, .u32, .abstractFloat, .f32, .f16, .void, .bool:
                return .buffer(
                    BufferBindingLayout(
                        type: bufferBindingType(shaderModule, maybeReference),
                        hasDynamicOffset: false,
                        minBindingSize: UInt64(shaderModule.size(of: type).bytes)
                    )
                )
            case .sampler:
                return .sampler(.filtering)
            case .samplerComparison:
                return .sampler(.comparison)
            case .textureExternal:
                return .externalTexture
            case .accessMode, .texelFormat, .addressSpace:
                wgslFatal("a resource variable of an enumeration type", cppSite: "GlobalVariableRewriter.cpp:1347")
            }
        case .vector, .matrix, .array, .struct:
            return .buffer(
                BufferBindingLayout(
                    type: bufferBindingType(shaderModule, maybeReference),
                    hasDynamicOffset: false,
                    minBindingSize: UInt64(shaderModule.size(of: type).bytes)
                )
            )
        case .texture(let texture):
            let viewDimension: TextureViewDimension
            var multisampled = false
            switch texture.kind {
            case .texture1d:
                viewDimension = .oneDimensional
            case .texture2d:
                viewDimension = .twoDimensional
            case .texture2dArray:
                viewDimension = .twoDimensionalArray
            case .texture3d:
                viewDimension = .threeDimensional
            case .textureCube:
                viewDimension = .cube
            case .textureCubeArray:
                viewDimension = .cubeArray
            case .textureMultisampled2d:
                viewDimension = .twoDimensional
                multisampled = true
            }

            return .texture(TextureBindingLayout(sampleType: .unfilterableFloat, viewDimension: viewDimension, multisampled: multisampled))
        case .textureStorage(let texture):
            let viewDimension: TextureViewDimension
            switch texture.kind {
            case .textureStorage1d:
                viewDimension = .oneDimensional
            case .textureStorage2d:
                viewDimension = .twoDimensional
            case .textureStorage2dArray:
                viewDimension = .twoDimensionalArray
            case .textureStorage3d:
                viewDimension = .threeDimensional
            }

            return .storageTexture(
                StorageTextureBindingLayout(access: convertAccess(texture.access), format: texture.format, viewDimension: viewDimension)
            )
        case .textureDepth(let texture):
            let viewDimension: TextureViewDimension
            var multisampled = false
            switch texture.kind {
            case .textureDepth2d:
                viewDimension = .twoDimensional
            case .textureDepth2dArray:
                viewDimension = .twoDimensionalArray
            case .textureDepthCube:
                viewDimension = .cube
            case .textureDepthCubeArray:
                viewDimension = .cubeArray
            case .textureDepthMultisampled2d:
                viewDimension = .twoDimensional
                multisampled = true
            }

            return .texture(TextureBindingLayout(sampleType: .depth, viewDimension: viewDimension, multisampled: multisampled))
        case .atomic:
            return .buffer(
                BufferBindingLayout(
                    type: bufferBindingType(shaderModule, maybeReference),
                    hasDynamicOffset: false,
                    minBindingSize: UInt64(shaderModule.size(of: type).bytes)
                )
            )
        case .primitiveStruct:
            wgslFatal("a resource variable of a primitive struct type", cppSite: "GlobalVariableRewriter.cpp:1467")
        case .reference:
            wgslFatal("a resource variable of a reference type", cppSite: "GlobalVariableRewriter.cpp:1469")
        case .pointer:
            wgslFatal("a resource variable of a pointer type", cppSite: "GlobalVariableRewriter.cpp:1471")
        case .function:
            wgslFatal("a resource variable of a function type", cppSite: "GlobalVariableRewriter.cpp:1473")
        case .typeConstructor:
            wgslFatal("a resource variable of a type constructor type", cppSite: "GlobalVariableRewriter.cpp:1475")
        }
    }

    mutating func determineUsedGlobals(_ entryPoint: CallGraph.EntryPoint) throws(CompilationMessage) -> UsedGlobals {
        var usedGlobals = UsedGlobals()
        let function = shaderModule[entryPoint.function]

        // https://www.w3.org/TR/WGSL/#limits
        let maximumCombinedPrivateVariablesSize: UInt32 = 8_192
        let maximumCombinedWorkgroupVariablesSize = shaderModule.configuration.maximumCombinedWorkgroupVariablesSize
        var workgroupVariables: [TypeID] = []
        var privateVariables: [TypeID] = []

        var globalNames = reads.makeIterator()
        while let globalName = globalNames.next() {
            guard let global = globals.find(globalName) else {
                wgslFatal("a read global is not in m_globals", cppSite: "GlobalVariableRewriter.cpp:1493")
            }
            let variable = shaderModule[global.declaration]
            let resource: Global.Resource
            switch variable.flavor {
            case .override:
                usesOverride(global.declaration)
                continue
            case .var, .let, .const:
                guard let globalResource = global.resource else {
                    usedGlobals.privateGlobals.append(global)

                    guard let storeType = variable.storeType else {
                        wgslFatal("a private global without a store type", cppSite: "GlobalVariableRewriter.cpp:1507")
                    }
                    if let qualifier = variable.maybeQualifier, qualifier.addressSpace == .workgroup {
                        workgroupVariables.append(storeType)
                    } else {
                        privateVariables.append(storeType)
                    }
                    continue
                }
                resource = globalResource
            }

            let group = resource.group
            let binding = resource.binding
            usedGlobals.resources.modify(UInt64(group), default: IndexMap<Global>()) { bindings in
                let bindingResult = bindings.add(UInt64(binding), global)
                assert(bindingResult)
            }
        }

        shaderModule.addOverrideValidation(
            OverrideValidation(
                guards: [],
                check: .combinedWorkgroupSize(span: function.span, types: workgroupVariables, limit: maximumCombinedWorkgroupVariablesSize)
            )
        )
        shaderModule.addOverrideValidation(
            OverrideValidation(
                guards: [],
                check: .combinedPrivateSize(span: function.span, types: privateVariables, limit: maximumCombinedPrivateVariablesSize)
            )
        )

        return usedGlobals
    }

    mutating func usesOverride(_ variable: VariableID) {
        let constantType: SpecializationConstantType
        let node = shaderModule[variable]
        guard let type = node.storeType, case .primitive(let primitive) = shaderModule.types[type] else {
            wgslFatal("std::get<Types::Primitive> of an override's type", cppSite: "GlobalVariableRewriter.cpp:1548")
        }
        switch primitive.kind {
        case .bool:
            constantType = .boolean
        case .f32:
            constantType = .float
        case .f16:
            constantType = .half
        case .i32:
            constantType = .int
        case .u32:
            constantType = .unsigned
        case .void, .abstractInt, .abstractFloat, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat,
            .addressSpace:
            wgslFatal("an override of a type without a specialization constant type", cppSite: "GlobalVariableRewriter.cpp:1574")
        }

        let entryName =
            if let id = node.id {
                Name(utf16: ("\(id)" as MessageText).codeUnits)
            } else {
                shaderModule.symbols.cachedName(of: shaderModule.symbol(of: node.originalName))
            }
        let constant = Reflection.SpecializationConstant(
            key: entryName,
            mangledName: shaderModule.symbol(of: node.name),
            type: constantType,
            defaultValue: node.maybeInitializer
        )
        modifyEntryPointInformation { _ = $0.addSpecializationConstant(constant) }
    }
}

// MARK: - Swift-only

/// The `k` of a `__DynamicOffsets[k]` subscript in the MSL: the dynamic offset slot WebGPU assigned to a binding of the explicit
/// layout, or one of the fragment stage's slots that WebGPU reserves ahead of those (RenderBundleEncoder's
/// startIndexForFragmentDynamicOffsets).
///
/// Only this file makes one: collectDynamicOffsetGlobals for a binding, and the reserved constants.
/// `MSLWriter.appendDynamicOffsetsElement`, the only `__DynamicOffsets[` sink, takes nothing else.
struct DynamicOffsetSlot: Hashable, Sendable {
    let index: UInt32
    /// C++ prints a reserved slot as a bare integer and a binding's slot as the u32 constant it passes to `__dynamicOffset`.
    let isReserved: Bool

    fileprivate init(_ index: UInt32, isReserved: Bool = false) {
        self.index = index
        self.isReserved = isReserved
    }

    /// The viewport's depth range, which a fragment return clamps `frag_depth` to.
    static let fragDepthMinimum = DynamicOffsetSlot(0, isReserved: true)
    static let fragDepthMaximum = DynamicOffsetSlot(1, isReserved: true)
    /// The pipeline's sample mask, which a fragment return masks `sample_mask` with.
    static let sampleMask = DynamicOffsetSlot(2, isReserved: true)
}

extension RewriteGlobalVariables {
    /// A packStructType or packArrayType call of the C++ recursion, waiting for the packType of a member or of the element.
    enum PackTypeFrame {
        /// `members` is past the member being packed.
        case structType(TypeID, StructureID, members: ListCursor<StructureMemberID>, packedAnyMember: Bool)
        /// The array type is nil for the one packArrayResource starts from.
        case arrayType(TypeID?, Types.Array)
    }

    /// What packTypes does next.
    enum PackTypeStep {
        case packStructType(TypeID)
        case packArrayType(TypeID?, Types.Array)
        case nextMember
        /// The call returned this packed type, or nil.
        case packed(TypeID?)
    }

    // DEV-03: C++ recurses through packType, packStructType and packArrayType once per level of nested structs and arrays,
    // which named types make as deep as the declarations; the pending calls are kept in `frames`.
    // DEV-04: C++ packs a type again each time it meets it, with the same result and no further effect, so a struct that
    // needs no packing is walked once per path to it, exponentially many; here each type is packed once per walk.
    private mutating func packTypes(_ start: PackTypeStep) -> TypeID? {
        var frames: [PackTypeFrame] = []
        var packedTypes = SmallKeyMap<TypeID, TypeID?>()
        swap(&frames, &packTypesFrames)
        swap(&packedTypes, &packTypesMemo)
        defer {
            packedTypes.removeAllKeepingCapacity()
            swap(&packedTypes, &packTypesMemo)
            swap(&frames, &packTypesFrames)
        }
        var step = start
        while true {
            switch step {
            case .packStructType(let structType):
                if let packedType = packedTypes.find(structType) {
                    step = .packed(packedType)
                } else {
                    step = packStructType(structType, &frames)
                }
            case .packArrayType(let arrayTypeID, let arrayType):
                if let arrayTypeID, let packedType = packedTypes.find(arrayTypeID) {
                    step = .packed(packedType)
                } else {
                    frames.append(.arrayType(arrayTypeID, arrayType))
                    step = packType(arrayType.element)
                }
            case .nextMember:
                guard case .structType(let structType, let structure, var members, let packedAnyMember) = frames.popLast() else {
                    wgslFatal("packStructType's member loop without its frame", cppSite: "GlobalVariableRewriter.cpp:1071")
                }
                if let member = shaderModule.next(&members) {
                    frames.append(.structType(structType, structure, members: members, packedAnyMember: packedAnyMember))
                    step = packType(shaderModule.inferredType(of: shaderModule[member].type))
                } else {
                    let packedStructType = packStructType(structType, structure, packedAnyMember: packedAnyMember)
                    packedTypes.set(structType, packedStructType)
                    step = .packed(packedStructType)
                }
            case .packed(let packedType):
                guard let frame = frames.popLast() else {
                    return packedType
                }
                switch frame {
                case .structType(let structType, let structure, let members, let packedAnyMember):
                    frames.append(
                        .structType(structType, structure, members: members, packedAnyMember: packedAnyMember || packedType != nil)
                    )
                    step = .nextMember
                case .arrayType(let arrayTypeID, let arrayType):
                    let packedArrayType = packArrayType(arrayType, packedElementType: packedType)
                    if let arrayTypeID {
                        packedTypes.set(arrayTypeID, packedArrayType)
                    }
                    step = .packed(packedArrayType)
                }
            }
        }
    }
}
