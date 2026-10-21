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
    enum BindingType {
        case undefined
        case buffer
        case texture
        case textureMultisampled
        case textureStorageReadOnly
        case textureStorageReadWrite
        case textureStorageWriteOnly
        case sampler
        case samplerComparison
        case textureExternal
    }
}

private func bindingTypeForPrimitive(_ primitive: Types.Primitive) -> RewriteGlobalVariables.BindingType {
    switch primitive.kind {
    case .abstractInt, .abstractFloat, .i32, .u32, .f32, .f16, .bool, .void:
        return .buffer
    case .sampler:
        return .sampler
    case .samplerComparison:
        return .samplerComparison

    case .textureExternal:
        return .textureExternal

    case .accessMode, .texelFormat, .addressSpace:
        return .undefined
    }
}

extension RewriteGlobalVariables {
    static func bindingTypeForType(_ shaderModule: borrowing ShaderModule, _ type: TypeID?) -> BindingType {
        guard let type else {
            return .undefined
        }

        switch shaderModule.types[type] {
        case .primitive(let primitive):
            return bindingTypeForPrimitive(primitive)
        case .vector:
            return .buffer
        case .array:
            return .buffer
        case .struct:
            return .buffer
        case .primitiveStruct:
            return .buffer
        case .matrix:
            return .buffer
        case .reference:
            return .buffer
        case .pointer:
            return .buffer
        case .function:
            wgslFatal("bindingTypeForType of a function type", cppSite: "GlobalVariableRewriter.cpp:1654")
        case .texture(let texture):
            return texture.kind == .textureMultisampled2d ? .textureMultisampled : .texture
        case .textureStorage(let storageTexture):
            switch storageTexture.access {
            case .read:
                return .textureStorageReadOnly
            case .readWrite:
                return .textureStorageReadWrite
            case .write:
                return .textureStorageWriteOnly
            }
        case .textureDepth(let texture):
            return texture.kind == .textureDepthMultisampled2d ? .textureMultisampled : .texture
        case .atomic:
            return .buffer
        case .typeConstructor:
            wgslFatal("bindingTypeForType of a type constructor", cppSite: "GlobalVariableRewriter.cpp:1676")
        }
    }

    static func isExternalTexture(_ shaderModule: borrowing ShaderModule, _ variable: VariableID) -> Bool {
        bindingTypeForType(shaderModule, shaderModule[variable].storeType) == .textureExternal
    }

    mutating func insertStructs(_ usedResources: UsedResources) -> [UInt32] {
        var groups: [UInt32] = []
        var nameScratch = ContiguousArray<UInt8>()
        var groupBindings = groupBindingMap.makeIterator()
        while let groupBinding = groupBindings.next() {
            guard let usedBindings = usedResources.find(groupBinding.key) else {
                continue
            }

            let bindingGlobalMap = groupBinding.value

            var entries: [(binding: UInt32, member: StructureMemberID)] = []
            var metalId: UInt32 = 0
            var bufferSizeToOwnerMap = LookupMap<VariableID, Int>()
            var bindingIndex = 0
            while bindingIndex < bindingGlobalMap.count {
                let (binding, globalName) = bindingGlobalMap[bindingIndex]
                bindingIndex &+= 1
                var group = UInt32(truncatingIfNeeded: groupBinding.key)
                guard let global = globals.find(globalName) else {
                    wgslFatal("a binding of m_groupBindingMap without a global", cppSite: "GlobalVariableRewriter.cpp:1702")
                }

                if let owner = reverseBufferLengthMap.find(global.declaration) {
                    if Self.isExternalTexture(shaderModule, owner) {
                        continue
                    }
                    if shaderModule[owner].addressSpace != .storage {
                        continue
                    }
                    if !bufferSizeToOwnerMap.contains(global.declaration) {
                        continue
                    }
                } else if !usedBindings.contains(UInt64(binding)) {
                    continue
                } else if !reads.contains(globalName) {
                    continue
                }
                assert(shaderModule[global.declaration].maybeTypeName != nil)

                entries.append((metalId, createArgumentBufferEntry(metalId, global.declaration)))

                if let mappedGroup = generateLayoutGroupMapping.find(UInt32(truncatingIfNeeded: groupBinding.key)) {
                    group = mappedGroup
                } else {
                    let newGroup = UInt32(truncatingIfNeeded: modifyGeneratedLayout { $0.bindGroupLayouts.count })
                    generateLayoutGroupMapping.add(group, newGroup)
                    modifyGeneratedLayout { $0.bindGroupLayouts.append(BindGroupLayout(group: group, entries: [])) }
                    group = newGroup
                }

                guard let resource = global.resource else {
                    wgslFatal("a binding of m_groupBindingMap without a resource", cppSite: "GlobalVariableRewriter.cpp:1731")
                }
                let declaration = shaderModule[global.declaration]
                let entry = BindGroupLayoutEntry(
                    binding: metalId,
                    webBinding: resource.binding,
                    visibility: ShaderStages(stage),
                    bindingMember: Self.bindingMemberForGlobal(shaderModule, global),
                    name: shaderModule.symbols.string(of: shaderModule.symbol(of: declaration.name), scratch: &nameScratch)
                )

                if let variable = bufferLengthMap.find(global.declaration) {
                    bufferSizeToOwnerMap.add(variable, modifyGeneratedLayout { $0.bindGroupLayouts[Int(group)].entries.count })
                } else if let owner = bufferSizeToOwnerMap.find(global.declaration) {
                    // FIXME: <rdar://150369108> since we only ever generate a layout
                    // for one shader stage at a time, we always store the indices in
                    // the vertex slot, but we should use a structs to pass information
                    // from the compiler to the API (instead of reusing the same struct
                    // the API uses to pass information to the compiler)
                    modifyGeneratedLayout {
                        $0.bindGroupLayouts[Int(group)].entries[owner].vertex.argumentBufferSizeIndex = metalId
                    }
                }

                let type = declaration.storeType
                if shaderModule.types.isPrimitive(type, .textureExternal) {
                    metalId &+= 6
                } else {
                    metalId &+= 1
                }

                modifyGeneratedLayout { $0.bindGroupLayouts[Int(group)].entries.append(entry) }
            }

            if entries.isEmpty {
                continue
            }

            groups.append(UInt32(truncatingIfNeeded: groupBinding.key))
            finalizeArgumentBufferStruct(UInt32(truncatingIfNeeded: groupBinding.key), &entries)
        }
        return groups
    }

    mutating func createArgumentBufferEntry(_ binding: UInt32, _ variable: VariableID) -> StructureMemberID {
        let declaration = shaderModule[variable]
        guard let referenceType = declaration.maybeReferenceType else {
            wgslFatal("an argument buffer entry for a variable without a reference type", cppSite: "GlobalVariableRewriter.cpp:1779")
        }
        return createArgumentBufferEntry(binding, declaration.span, shaderModule.symbol(of: declaration.name), referenceType)
    }

    mutating func createArgumentBufferEntry(
        _ binding: UInt32,
        _ span: SourceSpan,
        _ name: Symbol,
        _ type: ExpressionID
    ) -> StructureMemberID {
        let bindingValue = shaderModule.construct(span: span, AbstractIntegerLiteral(value: Int64(binding)))
        shaderModule.setInferredType(shaderModule.types.abstractIntType, for: bindingValue)
        shaderModule.setConstantValue(.uint32(binding), for: bindingValue)
        let bindingAttribute = shaderModule.construct(span: span, .bindingAttribute(BindingAttribute(binding: bindingValue)))
        modifyEntryPointInformation { $0.bindingCount &+= 1 }
        let attributes = shaderModule.makeList([bindingAttribute])
        return shaderModule.constructStructureMember(
            span: span,
            name: shaderModule.makeIdentifier(name),
            type: type,
            attributes: attributes
        )
    }

    mutating func finalizeArgumentBufferStruct(_ group: UInt32, _ entries: inout [(binding: UInt32, member: StructureMemberID)]) {
        entries.sort { $0.binding < $1.binding }

        var structMembers: [StructureMemberID] = []
        structMembers.reserveCapacity(entries.count)
        forEachElement(entries) { entry in
            structMembers.append(entry.member)
        }

        let name = argumentBufferStructName(group)
        let members = shaderModule.makeList(structMembers)
        let argumentBufferStruct = shaderModule.constructStructure(
            span: .empty,
            name: name,
            members: members,
            role: .bindGroup
        )
        let structType = shaderModule.types.structType(argumentBufferStruct)
        shaderModule.modify(argumentBufferStruct) { $0.inferredType = structType }
        shaderModule.append(shaderModule.declarations, .structure(argumentBufferStruct))
        structTypes.add(UInt64(group), structType)
    }
}
