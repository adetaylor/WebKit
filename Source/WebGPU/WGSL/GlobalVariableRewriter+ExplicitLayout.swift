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
    /// `explicitLayout` indexes `explicitLayouts`.
    ///
    /// At GlobalVariableRewriter.cpp:2422-2423 the store size of each serialized buffer variable is recorded with
    /// `explicitLayouts[explicitLayout].recordMinBindingSize(_:at:)`.
    mutating func insertStructs(explicitLayout: Int, _ usedResources: UsedResources) throws(CompilationMessage) -> [UInt32] {
        var groups: [UInt32] = []
        var group: UInt32 = 0
        var serializedVariables = LookupMap<VariableID, ExplicitPipelineLayout.EntryAddress?>()
        let bindGroupLayoutCount = explicitLayouts[explicitLayout].bindGroupLayouts.count
        var bindGroupLayoutIndex = 0
        while bindGroupLayoutIndex < bindGroupLayoutCount {
            var entries: [(binding: UInt32, member: StructureMemberID)] = []
            var bufferLengths: [(binding: UInt32, variable: VariableID?)] = []
            let entryCount = explicitLayouts[explicitLayout].bindGroupLayouts[bindGroupLayoutIndex].count
            var entryIndex = 0
            while entryIndex < entryCount {
                let entryAddress = ExplicitPipelineLayout.EntryAddress(bindGroupLayout: bindGroupLayoutIndex, entry: entryIndex)
                let entry = explicitLayouts[explicitLayout][entryAddress]
                entryIndex &+= 1
                guard entry.visibility.contains(ShaderStages(stage)) else {
                    continue
                }

                let argumentBufferIndex =
                    switch stage {
                    case .vertex:
                        entry.vertex.argumentBufferIndex
                    case .fragment:
                        entry.fragment.argumentBufferIndex
                    case .compute:
                        entry.compute.argumentBufferIndex
                    }
                let argumentBufferSizeIndex =
                    switch stage {
                    case .vertex:
                        entry.vertex.argumentBufferSizeIndex
                    case .fragment:
                        entry.fragment.argumentBufferSizeIndex
                    case .compute:
                        entry.compute.argumentBufferSizeIndex
                    }

                var variable: VariableID?

                if globalsByBinding.contains(BindingKey(ResourceBinding(group: group, binding: entry.binding))) {
                    if let bindings = usedResources.find(UInt64(group)) {
                        if let global = bindings.find(UInt64(entry.binding)) {
                            variable = global.declaration
                            serializedVariables.add(global.declaration, entryAddress)
                            guard let argumentBufferIndex else {
                                wgslFatal(
                                    "the layout entry has no argument buffer index for the stage",
                                    cppSite: "GlobalVariableRewriter.cpp:2274"
                                )
                            }
                            entries.append((argumentBufferIndex, createArgumentBufferEntry(argumentBufferIndex, global.declaration)))
                        }
                    }
                }

                if variable == nil {
                    let type = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier("void"))
                    let inferredType: TypeID
                    switch entry.bindingMember {
                    case .buffer(let buffer):
                        let addressSpace: AddressSpace
                        let accessMode: AccessMode
                        switch buffer.type {
                        case .uniform:
                            addressSpace = .uniform
                            accessMode = .read
                        case .storage:
                            addressSpace = .storage
                            accessMode = .readWrite
                        case .readOnlyStorage:
                            addressSpace = .storage
                            accessMode = .read
                        }
                        inferredType = shaderModule.types.pointerType(addressSpace, shaderModule.types.voidType, accessMode)
                    case .sampler:
                        inferredType = shaderModule.types.samplerType
                    case .texture(let layout):
                        let sampleType: TypeID
                        switch layout.sampleType {
                        case .float, .unfilterableFloat, .depth:
                            sampleType = shaderModule.types.f32Type
                        case .signedInt:
                            sampleType = shaderModule.types.i32Type
                        case .unsignedInt:
                            sampleType = shaderModule.types.u32Type
                        }
                        let textureKind: Types.Texture.Kind
                        switch layout.viewDimension {
                        case .oneDimensional:
                            textureKind = .texture1d
                        case .twoDimensional:
                            if layout.multisampled {
                                textureKind = .textureMultisampled2d
                            } else {
                                textureKind = .texture2d
                            }
                        case .twoDimensionalArray:
                            textureKind = .texture2dArray
                        case .cube:
                            textureKind = .textureCube
                        case .cubeArray:
                            textureKind = .textureCubeArray
                        case .threeDimensional:
                            textureKind = .texture3d
                        }
                        inferredType = shaderModule.types.textureType(textureKind, sampleType)
                    case .storageTexture(let layout):
                        let textureStorageKind: Types.TextureStorage.Kind
                        switch layout.viewDimension {
                        case .oneDimensional:
                            textureStorageKind = .textureStorage1d
                        case .twoDimensional:
                            textureStorageKind = .textureStorage2d
                        case .twoDimensionalArray:
                            textureStorageKind = .textureStorage2dArray
                        case .threeDimensional:
                            textureStorageKind = .textureStorage3d
                        case .cube, .cubeArray:
                            wgslFatal("a storage texture binding cannot be a cube", cppSite: "GlobalVariableRewriter.cpp:2361")
                        }
                        let accessMode: AccessMode
                        switch layout.access {
                        case .writeOnly:
                            accessMode = .write
                        case .readOnly:
                            accessMode = .read
                        case .readWrite:
                            accessMode = .readWrite
                        }
                        inferredType = shaderModule.types.textureStorageType(textureStorageKind, layout.format, accessMode)
                    case .externalTexture:
                        shaderModule.uses.insert(.externalTextures)
                        inferredType = shaderModule.types.textureExternalType
                    }
                    shaderModule.setInferredType(inferredType, for: type)

                    guard let argumentBufferIndex else {
                        wgslFatal("the layout entry has no argument buffer index for the stage", cppSite: "GlobalVariableRewriter.cpp:2383")
                    }
                    let name = shaderModule.symbols.intern(.argumentBufferPlaceholder(argumentBufferIndex))
                    entries.append((argumentBufferIndex, createArgumentBufferEntry(argumentBufferIndex, .empty, name, type)))
                }

                if let argumentBufferSizeIndex {
                    bufferLengths.append((argumentBufferSizeIndex, variable))
                }
            }

            var bufferLengthIndex = 0
            while bufferLengthIndex < bufferLengths.count {
                let (binding, variable) = bufferLengths[bufferLengthIndex]
                bufferLengthIndex &+= 1
                if let variable {
                    guard let lengthVariable = bufferLengthMap.find(variable) else {
                        wgslFatal("a buffer with a size index has no length variable", cppSite: "GlobalVariableRewriter.cpp:2395")
                    }
                    serializedVariables.add(lengthVariable, nil)
                    entries.append((binding, createArgumentBufferEntry(binding, lengthVariable)))
                } else {
                    let name = shaderModule.symbols.intern(.argumentBufferPlaceholder(binding))
                    entries.append((binding, createArgumentBufferEntry(binding, .empty, name, bufferLengthType())))
                }
            }

            bindGroupLayoutIndex &+= 1
            if entries.isEmpty {
                group &+= 1
                continue
            }

            groups.append(group)
            finalizeArgumentBufferStruct(group, &entries)
            group &+= 1
        }

        var groupIterator = usedResources.makeIterator()
        while let (_, bindingGlobalMap) = groupIterator.next() {
            var bindingIterator = bindingGlobalMap.makeIterator()
            while let (_, global) = bindingIterator.next() {
                let variable = global.declaration
                if let serializedEntry = serializedVariables.find(variable), let entryAddress = serializedEntry {
                    let entry = explicitLayouts[explicitLayout][entryAddress]
                    if let error = Self.errorValidatingVariableAndEntryMatch(shaderModule, variable, entry) {
                        throw CompilationMessage(text: "Shader is incompatible with layout pipeline: \(error)", span: .empty)
                    }

                    if case .buffer = entry.bindingMember {
                        guard let storeType = shaderModule[variable].storeType else {
                            wgslFatal("a buffer variable has no store type", cppSite: "GlobalVariableRewriter.cpp:2423")
                        }
                        let size = ShaderModule.size(of: storeType, in: &shaderModule)
                        explicitLayouts[explicitLayout].recordMinBindingSize(UInt64(size.bytes), at: entryAddress)
                    }
                }

                guard reads.contains(shaderModule.symbol(of: shaderModule[variable].name)) else {
                    continue
                }

                guard serializedVariables.contains(variable) else {
                    throw CompilationMessage(text: "Shader is incompatible with layout pipeline", span: .empty)
                }
            }
        }

        return groups
    }

    mutating func insertDynamicOffsetsBufferIfNeeded(_ span: SourceSpan, _ function: FunctionID) {
        if !globalsUsingDynamicOffset.isEmpty
            || (stage == .fragment && (shaderModule.uses.contains(.fragDepth) || shaderModule.uses.contains(.sampleMask)))
        {
            let group: UInt32
            switch stage {
            case .vertex:
                group = shaderModule.configuration.maxBuffersPlusVertexBuffersForVertexStage
            case .fragment:
                group = shaderModule.configuration.maxBuffersForFragmentStage
            case .compute:
                group = shaderModule.configuration.maxBuffersForComputeStage
            }

            let type = shaderModule.constructIdentifierExpression(span: span, identifier: shaderModule.makeIdentifier("u32"))
            shaderModule.setInferredType(shaderModule.types.pointerType(.uniform, shaderModule.types.u32Type, .read), for: type)

            let name = dynamicOffsetVariableName()
            insertParameter(span, function, group, name, type, .userDefined)
        }
    }

    mutating func insertDynamicOffsetsBufferIfNeeded(_ function: FunctionID) {
        insertDynamicOffsetsBufferIfNeeded(shaderModule[function].span, function)
    }

    mutating func insertParameters(_ function: FunctionID, _ groups: [UInt32]) {
        let span = shaderModule[function].span
        var index = 0
        while index < groups.count {
            let group = groups[index]
            index &+= 1
            let name = argumentBufferParameterName(group)
            insertParameter(span, function, group, name)
        }
        insertDynamicOffsetsBufferIfNeeded(span, function)
    }

    mutating func insertMaterializations(_ function: FunctionID, _ usedResources: UsedResources) {
        let span = shaderModule[function].span
        // The C++ inserts each statement at the front of the body; they go in at once, last first, which is the same list without
        // moving the body once per resource.
        var variableStatements: [StatementID] = []
        var groupIterator = usedResources.makeIterator()
        while let (group, bindings) = groupIterator.next() {
            let argument = shaderModule.constructIdentifierExpression(
                span: span,
                identifier: argumentBufferParameterName(UInt32(truncatingIfNeeded: group))
            )

            var bindingIterator = bindings.makeIterator()
            while let (binding, global) = bindingIterator.next() {
                let name = shaderModule.symbol(of: shaderModule[global.declaration].name)
                var fieldName = name
                let storeType = shaderModule[global.declaration].storeType
                if shaderModule.types.isPrimitive(storeType, .textureExternal) {
                    fieldName = shaderModule.symbols.intern(.externalTexture(of: name))
                    shaderModule.uses.insert(.externalTextures)
                }
                let access = shaderModule.constructFieldAccessExpression(
                    span: .empty,
                    base: argument,
                    fieldName: shaderModule.makeIdentifier(fieldName)
                )
                var initializer = access

                let resource = ResourceBinding(group: UInt32(truncatingIfNeeded: group), binding: UInt32(truncatingIfNeeded: binding))
                if shaderModule[global.declaration].binding != nil, let offsetSlot = globalsUsingDynamicOffset.find(BindingKey(resource)) {
                    let offset = offsetSlot.index
                    let target = shaderModule.constructIdentifierExpression(
                        span: .empty,
                        identifier: shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.dynamicOffset)))
                    )
                    guard let referenceType = shaderModule[global.declaration].maybeReferenceType,
                        let reference = shaderModule.types.getIf(Types.Reference.self, shaderModule.inferredType(of: referenceType))
                    else {
                        wgslFatal("a resource's reference type is not a reference", cppSite: "GlobalVariableRewriter.cpp:2504")
                    }
                    guard let storeType else {
                        wgslFatal("a resource has no store type", cppSite: "GlobalVariableRewriter.cpp:2505")
                    }
                    shaderModule.setInferredType(
                        shaderModule.types.pointerType(reference.addressSpace, storeType, reference.accessMode),
                        for: target
                    )

                    let offsetExpression = shaderModule.construct(span: span, Unsigned32Literal(value: offset))
                    shaderModule.setInferredType(shaderModule.types.u32Type, for: offsetExpression)
                    shaderModule.setConstantValue(.uint32(offset), for: offsetExpression)
                    let arguments = shaderModule.makeList([access, offsetExpression])
                    initializer = shaderModule.construct(span: .empty, CallExpression(target: target, arguments: arguments))
                    entryPointInformations.addDynamicOffsetCall(initializer, offsetSlot)
                }

                let attributes = shaderModule.makeEmptyList(AttributeID.self)
                let variable = shaderModule.constructVariable(
                    span: .empty,
                    flavor: .let,
                    name: shaderModule.makeIdentifier(name),
                    qualifier: nil,
                    type: shaderModule[global.declaration].maybeReferenceType,
                    initializer: initializer,
                    attributes: attributes,
                    role: .packedResource
                )

                let variableStatement = shaderModule.construct(span: .empty, VariableStatement(variable: variable))
                variableStatements.append(variableStatement)
            }
        }
        if !variableStatements.isEmpty {
            let body = shaderModule.downcast(CompoundStatement.self, shaderModule[function].body)
            variableStatements.reverse()
            shaderModule.insertVector(body.statements, 0, variableStatements)
        }
    }
}
