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

private func addressSpaceForBindingMember(_ bindingMember: BindingMember) -> AddressSpace {
    switch bindingMember {
    case .buffer(let bufferBinding):
        switch bufferBinding.type {
        case .uniform:
            return .uniform
        case .storage:
            return .storage
        case .readOnlyStorage:
            return .storage
        }
    case .sampler:
        return .handle
    case .texture:
        return .handle
    case .storageTexture:
        return .handle
    case .externalTexture:
        return .handle
    }
}

private func accessModeForBindingMember(_ bindingMember: BindingMember) -> AccessMode {
    switch bindingMember {
    case .buffer(let bufferBinding):
        switch bufferBinding.type {
        case .uniform:
            return .read
        case .storage:
            return .readWrite
        case .readOnlyStorage:
            return .read
        }
    case .sampler:
        return .read
    case .texture:
        return .read
    case .storageTexture:
        return .read
    case .externalTexture:
        return .read
    }
}

private func isBuffer(_ shaderModule: borrowing ShaderModule, _ variable: VariableID) -> Bool {
    RewriteGlobalVariables.bindingTypeForType(shaderModule, shaderModule[variable].storeType) == .buffer
}

private func isSampler(_ shaderModule: borrowing ShaderModule, _ variable: VariableID, _ bindingType: SamplerBindingType) -> Bool {
    switch bindingType {
    case .filtering, .nonFiltering:
        return RewriteGlobalVariables.bindingTypeForType(shaderModule, shaderModule[variable].storeType) == .sampler
    case .comparison:
        return RewriteGlobalVariables.bindingTypeForType(shaderModule, shaderModule[variable].storeType) == .samplerComparison
    }
}

private func textureKindEqualsViewDimension(
    _ kind: Types.Texture.Kind,
    _ viewDimension: TextureViewDimension,
    _ isMultisampled: Bool,
    _ sampleType: TextureSampleType
) -> Bool {
    if isMultisampled {
        return kind == .textureMultisampled2d && viewDimension == .twoDimensional
    }

    switch viewDimension {
    case .oneDimensional:
        return kind == .texture1d && sampleType != .depth
    case .twoDimensional:
        return kind == .texture2d
    case .twoDimensionalArray:
        return kind == .texture2dArray
    case .cube:
        return kind == .textureCube
    case .cubeArray:
        return kind == .textureCubeArray
    case .threeDimensional:
        return kind == .texture3d && sampleType != .depth
    }
}

private func depthTextureKindEqualsViewDimension(
    _ kind: Types.TextureDepth.Kind,
    _ viewDimension: TextureViewDimension,
    _ isMultisampled: Bool
) -> Bool {
    if isMultisampled {
        return kind == .textureDepthMultisampled2d && viewDimension == .twoDimensional
    }

    switch viewDimension {
    case .oneDimensional:
        return false
    case .twoDimensional:
        return kind == .textureDepth2d
    case .twoDimensionalArray:
        return kind == .textureDepth2dArray
    case .cube:
        return kind == .textureDepthCube
    case .cubeArray:
        return kind == .textureDepthCubeArray
    case .threeDimensional:
        return false
    }
}

private func nameForBindingType(_ bindingType: RewriteGlobalVariables.BindingType) -> StaticString {
    switch bindingType {
    case .undefined:
        return "Undefined"
    case .buffer:
        return "Buffer"
    case .texture:
        return "Texture"
    case .textureMultisampled:
        return "TextureMultisampled"
    case .textureStorageReadOnly:
        return "TextureStorageReadOnly"
    case .textureStorageReadWrite:
        return "TextureStorageReadWrite"
    case .textureStorageWriteOnly:
        return "TextureStorageWriteOnly"
    case .sampler:
        return "Sampler"
    case .samplerComparison:
        return "SamplerComparison"
    case .textureExternal:
        return "TextureExternal"
    }
}

private func nameForTextureSampleType(_ sampleType: TextureSampleType) -> StaticString {
    switch sampleType {
    case .float:
        return "Float"
    case .unfilterableFloat:
        return "UnfilterableFloat"
    case .depth:
        return "Depth"
    case .signedInt:
        return "SignedInt"
    case .unsignedInt:
        return "UnsignedInt"
    }
}

private func nameForTextureDepthKind(_ kind: Types.TextureDepth.Kind) -> StaticString {
    switch kind {
    case .textureDepth2d:
        return "TextureDepth2d"
    case .textureDepth2dArray:
        return "TextureDepth2d"
    case .textureDepthCube:
        return "TextureDepth2d"
    case .textureDepthCubeArray:
        return "TextureDepth2d"
    case .textureDepthMultisampled2d:
        return "Texture2d"
    }
}

private func nameForTextureKind(_ kind: Types.Texture.Kind) -> StaticString {
    switch kind {
    case .texture1d:
        return "Texture1d"
    case .texture2d:
        return "Texture2d"
    case .texture2dArray:
        return "Texture2d"
    case .textureCube:
        return "Texture2d"
    case .textureCubeArray:
        return "Texture2d"
    case .textureMultisampled2d:
        return "Texture2d"
    case .texture3d:
        return "Texture3d"
    }
}

private func nameForTextureViewDimension(_ viewDimension: TextureViewDimension) -> StaticString {
    switch viewDimension {
    case .oneDimensional:
        return "1d"
    case .twoDimensional:
        return "2d"
    case .twoDimensionalArray:
        return "2d_array"
    case .cube:
        return "cube"
    case .cubeArray:
        return "cube-array"
    case .threeDimensional:
        return "3d"
    }
}

private func nameForPrimitiveKind(_ primitiveKind: Types.Primitive.Kind) -> StaticString {
    switch primitiveKind {
    case .abstractInt:
        return "<AbstractInt>"
    case .i32:
        return "int32"
    case .u32:
        return "uint32"
    case .abstractFloat:
        return "<AbstractFloat>"
    case .f16:
        return "f16"
    case .f32:
        return "f32"
    case .void:
        return "void"
    case .bool:
        return "bool"
    case .sampler:
        return "sampler"
    case .samplerComparison:
        return "sampler_comparison"
    case .textureExternal:
        return "texture_external"
    case .accessMode:
        return "access_mode"
    case .texelFormat:
        return "texel_format"
    case .addressSpace:
        return "address_space"
    }
}

/// C++ returns an empty String for a match; nil here.
private func errorValidatingTexture(
    _ shaderModule: borrowing ShaderModule,
    _ variable: VariableID,
    _ textureBinding: TextureBindingLayout
) -> MessageText? {
    let isMultisampled = textureBinding.multisampled
    let targetValue: RewriteGlobalVariables.BindingType = isMultisampled ? .textureMultisampled : .texture
    let storeType = shaderModule[variable].storeType
    let bindingForType = RewriteGlobalVariables.bindingTypeForType(shaderModule, storeType)
    if bindingForType != targetValue {
        return "types don't match: WGSL type \(nameForBindingType(bindingForType)) target type \(nameForBindingType(targetValue))"
    }

    let multisampledText: StaticString = isMultisampled ? "yes" : "no"
    let sampleType = textureBinding.sampleType
    guard let possibleTexture = shaderModule.types.getIf(Types.Texture.self, storeType) else {
        let possibleTextureDepth = shaderModule.types.getIf(Types.TextureDepth.self, storeType)
        guard let possibleTextureDepth, sampleType == .depth else {
            return "depth validation failed: \(nameForTextureSampleType(sampleType))"
        }

        let result = depthTextureKindEqualsViewDimension(possibleTextureDepth.kind, textureBinding.viewDimension, isMultisampled)
        if !result {
            return """
                viewDimensions don't match: \(nameForTextureDepthKind(possibleTextureDepth.kind)), textureBinding view dimension \
                \(nameForTextureViewDimension(textureBinding.viewDimension)), multisampled = \(multisampledText)
                """
        }

        return nil
    }

    // The C++ also checks for a null element type, which a Types.Texture never has.
    if !textureKindEqualsViewDimension(possibleTexture.kind, textureBinding.viewDimension, isMultisampled, sampleType) {
        return """
            viewDimensions don't match: \(nameForTextureKind(possibleTexture.kind)), bindingViewDimension = \
            \(nameForTextureViewDimension(textureBinding.viewDimension)), multisampled = \(multisampledText), bindingSampleType = \
            \(nameForTextureSampleType(sampleType))
            """
    }

    var result = false
    if let primitive = shaderModule.types.getIf(Types.Primitive.self, possibleTexture.element) {
        switch sampleType {
        case .float, .unfilterableFloat:
            result = primitive.kind == .f32 || primitive.kind == .f16
        case .depth:
            break
        case .signedInt:
            result = primitive.kind == .i32
        case .unsignedInt:
            result = primitive.kind == .u32
        }

        if !result {
            return """
                element types don't match: sampleType \(nameForTextureSampleType(sampleType)), primitive->kind \
                \(nameForPrimitiveKind(primitive.kind))
                """
        }
    }

    if !result {
        return "WGSL texture has no elementType: sampleType \(nameForTextureSampleType(sampleType))"
    }

    return nil
}

private func storageTextureKindEqualsViewDimension(_ kind: Types.TextureStorage.Kind, _ viewDimension: TextureViewDimension) -> Bool {
    switch viewDimension {
    case .oneDimensional:
        return kind == .textureStorage1d
    case .twoDimensional:
        return kind == .textureStorage2d
    case .twoDimensionalArray:
        return kind == .textureStorage2dArray
    case .cube:
        return false
    case .cubeArray:
        return false
    case .threeDimensional:
        return kind == .textureStorage3d
    }
}

private func isStorageTexture(
    _ shaderModule: borrowing ShaderModule,
    _ variable: VariableID,
    _ storageTexture: StorageTextureBindingLayout
) -> Bool {
    let textureAccess = storageTexture.access
    let storeType = shaderModule[variable].storeType
    guard let possibleStorageTexture = shaderModule.types.getIf(Types.TextureStorage.self, storeType) else {
        return false
    }

    if !storageTextureKindEqualsViewDimension(possibleStorageTexture.kind, storageTexture.viewDimension)
        || possibleStorageTexture.format != storageTexture.format
    {
        return false
    }

    switch RewriteGlobalVariables.bindingTypeForType(shaderModule, storeType) {
    case .textureStorageReadOnly:
        return textureAccess == .readOnly
    case .textureStorageReadWrite:
        return textureAccess == .readWrite
    case .textureStorageWriteOnly:
        return textureAccess == .writeOnly || textureAccess == .readWrite
    case .undefined, .buffer, .texture, .textureMultisampled, .sampler, .samplerComparison, .textureExternal:
        return false
    }
}

/// C++ returns an empty String for a match; nil here.
private func errorValidatingTypes(
    _ shaderModule: borrowing ShaderModule,
    _ variable: VariableID,
    _ bindingMember: BindingMember
) -> MessageText? {
    switch bindingMember {
    case .buffer:
        return isBuffer(shaderModule, variable) ? nil : "WGSL variable is not a buffer"
    case .sampler(let samplerBinding):
        return isSampler(shaderModule, variable, samplerBinding) ? nil : "WGSL variable is not a sampler"
    case .texture(let textureBinding):
        return errorValidatingTexture(shaderModule, variable, textureBinding)
    case .storageTexture(let storageTexture):
        return isStorageTexture(shaderModule, variable, storageTexture) ? nil : "WGSL variable is not a storage texture"
    case .externalTexture:
        return RewriteGlobalVariables.isExternalTexture(shaderModule, variable) ? nil : "WGSL variable is not an external texture"
    }
}

extension RewriteGlobalVariables {
    /// C++ returns an empty String for a match; nil here.
    static func errorValidatingVariableAndEntryMatch(
        _ shaderModule: borrowing ShaderModule,
        _ variable: VariableID,
        _ entry: ExplicitBindGroupLayoutEntry
    ) -> MessageText? {
        if let error = errorValidatingTypes(shaderModule, variable, entry.bindingMember) {
            return error
        }

        let variableAddressSpace = shaderModule[variable].addressSpace
        let entryAddressSpace = addressSpaceForBindingMember(entry.bindingMember)
        if let variableAddressSpace, variableAddressSpace != entryAddressSpace {
            return "variableAddressSpace != entryAddressSpace"
        }

        let variableAccessMode = shaderModule[variable].accessMode
        let entryAccessMode = accessModeForBindingMember(entry.bindingMember)
        if let variableAccessMode, variableAccessMode != entryAccessMode {
            return "variableAccessMode != entryAccessMode"
        }

        return nil
    }

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpuprogrammablestage
    /// `explicitLayout` indexes `explicitLayouts`.
    mutating func errorValidatingTextureSamplerPairs(_ entryPoint: CallGraph.EntryPoint, explicitLayout: Int) -> CompilationMessage? {
        let bindGroupLayouts = explicitLayouts[explicitLayout].bindGroupLayouts
        let stage = ShaderStages(self.stage)
        func findEntry(_ resource: Global.Resource) -> ExplicitBindGroupLayoutEntry? {
            // A bind group's index into bindGroupLayouts is its @group number.
            if Int(resource.group) >= bindGroupLayouts.count {
                return nil
            }
            let entries = bindGroupLayouts[Int(resource.group)]
            var index = 0
            while index < entries.count {
                let entry = entries[index]
                if entry.binding == resource.binding && entry.visibility.contains(stage) {
                    return entry
                }
                index &+= 1
            }
            return nil
        }

        var pairIndex = 0
        while pairIndex < entryPoint.textureSamplerPairs.count {
            let pair = entryPoint.textureSamplerPairs[pairIndex]
            pairIndex &+= 1
            guard let samplerEntry = findEntry(pair.sampler) else {
                continue
            }
            guard case .sampler(let samplerBinding) = samplerEntry.bindingMember, samplerBinding == .filtering else {
                continue
            }

            guard let textureEntry = findEntry(pair.texture) else {
                continue
            }
            // A texture that is not bound as a plain texture, an external texture for instance, is
            // filterable whatever the sampler.
            guard case .texture(let textureBinding) = textureEntry.bindingMember, textureBinding.sampleType != .float else {
                continue
            }

            let entryPointName = shaderModule.symbols.text(of: entryPoint.originalName)
            return CompilationMessage(
                text: """
                    Shader is incompatible with layout pipeline: entry point '\(entryPointName)' uses the filtering sampler at \
                    @group(\(pair.sampler.group)) @binding(\(pair.sampler.binding)) with the texture at @group(\(pair.texture.group)) \
                    @binding(\(pair.texture.binding)), whose sample type is \(nameForTextureSampleType(textureBinding.sampleType))
                    """,
                span: .empty
            )
        }

        return nil
    }
}
