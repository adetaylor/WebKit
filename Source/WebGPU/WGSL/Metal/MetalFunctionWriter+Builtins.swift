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

private let noArrayIndexArgument = UInt32.max

extension FunctionDefinitionWriter {
    mutating func isArrayTexture(_ type: TypeID?) -> Bool {
        if let texture = shaderModule.types.getIf(Types.Texture.self, type) {
            return texture.kind == .texture2dArray || texture.kind == .textureCubeArray
        }
        if let textureStorage = shaderModule.types.getIf(Types.TextureStorage.self, type) {
            return textureStorage.kind == .textureStorage2dArray
        }
        if let textureDepth = shaderModule.types.getIf(Types.TextureDepth.self, type) {
            return textureDepth.kind == .textureDepth2dArray || textureDepth.kind == .textureDepthCubeArray
        }
        return false
    }

    // WGSL requires the array index of a texture builtin to be clamped to [0, textureNumLayers(t) - 1].
    // Metal applies the upper bound itself, but its array index parameter is unsigned, so a negative
    // signed index would convert to a very large value and select the last layer rather than the first.
    // Only the lower bound has to be applied here, and only when the index is signed.
    mutating func visitArrayIndexArgument(_ arrayIndex: ExpressionID) {
        let primitive = shaderModule.types.getIf(Types.Primitive.self, shaderModule.inferredType(of: arrayIndex))
        if let primitive, primitive.kind == .u32 {
            visit(arrayIndex)
            return
        }

        body.append("max(")
        visit(arrayIndex)
        body.append(", 0)")
    }

    mutating func visitArguments(_ call: CallExpression, startOffset: UInt32 = 0, arrayIndexOffset: UInt32 = noArrayIndexArgument) {
        body.append("(")
        var i = startOffset
        while Int(i) < shaderModule.count(call.arguments) {
            if i != startOffset {
                body.append(", ")
            }
            if i == arrayIndexOffset {
                visitArrayIndexArgument(shaderModule[call.arguments, Int(i)])
            } else {
                visit(shaderModule[call.arguments, Int(i)])
            }
            i &+= 1
        }
        body.append(")")
    }

    // The array index of a texture builtin, when the texture is arrayed, always immediately follows
    // the coordinates.
    mutating func arrayIndexOffsetForTexture(_ call: CallExpression, _ textureOffset: UInt32, _ coordinatesOffset: UInt32) -> UInt32 {
        let texture = shaderModule[call.arguments, Int(textureOffset)]
        if !isArrayTexture(shaderModule.inferredType(of: texture)) {
            return noArrayIndexArgument
        }
        return coordinatesOffset &+ 1
    }

    mutating func emitTextureDimensions(_ call: CallExpression, _ id: ExpressionID) {
        let vector = shaderModule.types.getIf(Types.Vector.self, shaderModule.inferredType(of: id))
        func get(_ property: MSLText) {
            visit(shaderModule[call.arguments, 0])
            body.append(".get_")
            body.append(property)
            body.append("(")
            if vector != nil && shaderModule.count(call.arguments) > 1 {
                body.append("min(")
                visit(shaderModule[call.arguments, 0])
                body.append(".get_num_mip_levels() - 1, uint(")
                visit(shaderModule[call.arguments, 1])
                body.append(")")
                body.append(")")
            }
            body.append(")")
        }

        guard let vector else {
            get("width")
            return
        }

        let size = vector.size
        assert(size >= 2 && size <= 3)
        body.append("uint")
        body.appendDecimal(Int(size))
        body.append("(")
        get("width")
        body.append(", ")
        get("height")
        if size > 2 {
            body.append(", ")
            get("depth")
        }
        body.append(")")
    }

    mutating func emitTextureGather(_ call: CallExpression, _ id: ExpressionID) {
        assert(shaderModule.count(call.arguments) > 1)
        var offset: UInt32 = 0
        var component: MSLText?
        var hasOffset = true
        let firstArgument = shaderModule[call.arguments, 0]
        if shaderModule.types.getIf(Types.Primitive.self, shaderModule.inferredType(of: firstArgument)) != nil {
            offset = 1
            guard let componentValue = shaderModule.constantValueForWriter(firstArgument) else {
                wgslFatal("textureGather's component is not a constant", cppSite: "MetalFunctionWriter.cpp:2031")
            }
            switch componentValue.integerValue() {
            case 0:
                component = "x"
            case 1:
                component = "y"
            case 2:
                component = "z"
            case 3:
                component = "w"
            default: // lint-exempt(L-ENUM-1): an Int64 component index, as the C++ switch
                wgslFatal("textureGather's component is not 0, 1, 2 or 3", cppSite: "MetalFunctionWriter.cpp:2045")
            }

            let texture = shaderModule[call.arguments, 1]
            guard let textureType = shaderModule.types.getIf(Types.Texture.self, shaderModule.inferredType(of: texture)) else {
                wgslFatal("textureGather's texture is not a sampled texture", cppSite: "MetalFunctionWriter.cpp:2048")
            }
            if textureType.kind == .texture2d || textureType.kind == .texture2dArray {
                let lastArgument = shaderModule[call.arguments, shaderModule.count(call.arguments) &- 1]
                let vectorType = shaderModule.types.getIf(Types.Vector.self, shaderModule.inferredType(of: lastArgument))
                if vectorType == nil || !satisfies(vectorType?.element, .integer, shaderModule.types) {
                    hasOffset = false
                }
            }
        }
        visit(shaderModule[call.arguments, Int(offset)])
        body.append(".gather(")
        let arrayIndexOffset = arrayIndexOffsetForTexture(call, offset, offset &+ 2)
        var i = offset &+ 1
        while Int(i) < shaderModule.count(call.arguments) {
            if i != offset &+ 1 {
                body.append(", ")
            }
            if i == arrayIndexOffset {
                visitArrayIndexArgument(shaderModule[call.arguments, Int(i)])
            } else {
                visit(shaderModule[call.arguments, Int(i)])
            }
            i &+= 1
        }
        if !hasOffset {
            body.append(", int2(0)")
        }
        if let component {
            body.append(", component::")
            body.append(component)
        }
        body.append(")")
    }

    mutating func emitTextureGatherCompare(_ call: CallExpression, _ id: ExpressionID) {
        assert(shaderModule.count(call.arguments) > 1)
        visit(shaderModule[call.arguments, 0])
        body.append(".gather_compare")
        visitArguments(call, startOffset: 1, arrayIndexOffset: arrayIndexOffsetForTexture(call, 0, 2))
    }

    mutating func emitTextureLoad(_ call: CallExpression, _ id: ExpressionID) {
        let texture = shaderModule[call.arguments, 0]
        let textureType = shaderModule.inferredType(of: texture)

        let primitive = shaderModule.types.getIf(Types.Primitive.self, textureType)
        let isExternalTexture = primitive?.kind == .textureExternal
        if !isExternalTexture {
            visit(shaderModule[call.arguments, 0])
            body.append(".read")
            body.append("(")
            var is1d = true
            var cast: MSLText = "uint"
            if let vector = shaderModule.types.getIf(Types.Vector.self, shaderModule.inferredType(of: shaderModule[call.arguments, 1])) {
                is1d = false
                switch vector.size {
                case 2:
                    cast = "uint2"
                case 3:
                    cast = "uint3"
                default: // lint-exempt(L-ENUM-1): a vector size, as the C++ switch
                    wgslFatal("textureLoad's coordinates are not a vec2 or a vec3", cppSite: "MetalFunctionWriter.cpp:2105")
                }
            }
            var first = true
            let argumentCount = shaderModule.count(call.arguments)
            var i = 1
            while i < argumentCount {
                defer { i &+= 1 }
                if first {
                    body.append(cast)
                    body.append("(")
                    visit(shaderModule[call.arguments, i])
                    body.append(")")
                } else if is1d && i == argumentCount &- 1 {
                    // From the MSL spec for texture1d::read:
                    // > Since mipmaps are not supported for 1D textures, lod must be 0.
                    continue
                } else {
                    body.append(", ")
                    visit(shaderModule[call.arguments, i])
                }
                first = false
            }
            body.append(")")
            return
        }

        let coordinates = shaderModule[call.arguments, 1]
        body.append("({\n")
        do {
            indent.increment()
            defer { indent.decrement() }
            body.append(indent)
            body.append("auto __coords = uint2((")
            visit(texture)
            body.append(".UVRemapMatrix * float3(float2(")
            visit(coordinates)
            body.append("), 1)).xy);\n")

            body.append(indent)
            body.append("auto __y = float(")
            visit(texture)
            body.append(".FirstPlane.read(__coords).r);\n")

            body.append(indent)
            body.append("auto __xAdjustment = ")
            visit(texture)
            body.append(indent)
            body.append(".SecondPlane.get_width(0) / static_cast<float>(")
            visit(texture)
            body.append(indent)
            body.append(".FirstPlane.get_width(0));")

            body.append(indent)
            body.append("auto __yAdjustment = ")
            visit(texture)
            body.append(indent)
            body.append(".SecondPlane.get_height(0) / static_cast<float>(")
            visit(texture)
            body.append(indent)
            body.append(".FirstPlane.get_height(0));")

            // The frame's alpha comes from the second plane's alpha channel, and its blue channel says
            // whether plane 0 is premultiplied already, for the reasons given above
            // __wgslTextureSampleBaseClampToEdge.
            body.append(indent)
            body.append("auto __second = ")
            visit(texture)
            body.append(".SecondPlane.read(uint2(uint(__coords.x * __xAdjustment), uint(__coords.y * __yAdjustment)));\n")

            body.append(indent)
            body.append("auto __ycbcr = float3(__y, float2(__second.rg));\n")

            body.append(indent)
            body.append("float3 const __rgb = ")
            visit(texture)
            body.append(".ColorSpaceConversionMatrix * float4(__ycbcr, 1);\n")
            body.append(indent)
            visit(texture)
            body.append(".to_destination_color_space(__rgb, __second.a, __second.b);\n")
        }
        body.append(indent)
        body.append("})")
    }

    mutating func emitTextureSample(_ call: CallExpression, _ id: ExpressionID) {
        assert(shaderModule.count(call.arguments) > 1)
        visit(shaderModule[call.arguments, 0])
        body.append(".sample")
        visitArguments(call, startOffset: 1, arrayIndexOffset: arrayIndexOffsetForTexture(call, 0, 2))
    }

    mutating func emitTextureSampleCompare(_ call: CallExpression, _ id: ExpressionID) {
        assert(shaderModule.count(call.arguments) > 1)
        visit(shaderModule[call.arguments, 0])
        body.append(".sample_compare")
        visitArguments(call, startOffset: 1, arrayIndexOffset: arrayIndexOffsetForTexture(call, 0, 2))
    }

    // textureSampleCompareLevel always samples mip level 0, whereas textureSampleCompare derives the
    // level from screen-space derivatives and is therefore only available in a fragment shader. Metal
    // spells that difference as an explicit level(0) lod option, which sits after the depth reference
    // and before the optional offset.
    mutating func emitTextureSampleCompareLevel(_ call: CallExpression, _ id: ExpressionID) {
        let arguments = call.arguments
        assert(shaderModule.count(arguments) > 1)
        let arrayIndexOffset = arrayIndexOffsetForTexture(call, 0, 2)
        let depthReferenceOffset: UInt32 = arrayIndexOffset == noArrayIndexArgument ? 3 : 4
        assert(shaderModule.count(arguments) > Int(depthReferenceOffset))

        visit(shaderModule[arguments, 0])
        body.append(".sample_compare(")
        var i: UInt32 = 1
        while i <= depthReferenceOffset {
            if i != 1 {
                body.append(", ")
            }
            if i == arrayIndexOffset {
                visitArrayIndexArgument(shaderModule[arguments, Int(i)])
            } else {
                visit(shaderModule[arguments, Int(i)])
            }
            i &+= 1
        }
        body.append(", level(0)")
        i = depthReferenceOffset &+ 1
        while Int(i) < shaderModule.count(arguments) {
            body.append(", ")
            visit(shaderModule[arguments, Int(i)])
            i &+= 1
        }
        body.append(")")
    }

    mutating func emitTextureSampleGrad(_ call: CallExpression, _ id: ExpressionID) {
        assert(shaderModule.count(call.arguments) > 1)
        let texture = shaderModule[call.arguments, 0]
        guard let textureType = shaderModule.types.getIf(Types.Texture.self, shaderModule.inferredType(of: texture)) else {
            wgslFatal("textureSampleGrad's texture is not a sampled texture", cppSite: "MetalFunctionWriter.cpp:2229")
        }

        let gradientIndex: Int
        let gradientFunction: MSLText
        switch textureType.kind {
        case .texture1d, .texture2d, .textureMultisampled2d:
            gradientIndex = 3
            gradientFunction = "gradient2d"

        case .texture3d:
            gradientIndex = 3
            gradientFunction = "gradient3d"

        case .textureCube:
            gradientIndex = 3
            gradientFunction = "gradientcube"

        case .texture2dArray:
            gradientIndex = 4
            gradientFunction = "gradient2d"

        case .textureCubeArray:
            gradientIndex = 4
            gradientFunction = "gradientcube"
        }
        visit(texture)
        body.append(".sample(")
        var i = 1
        while i < gradientIndex {
            if i != 1 {
                body.append(", ")
            }
            if i == 3 {
                visitArrayIndexArgument(shaderModule[call.arguments, i])
            } else {
                visit(shaderModule[call.arguments, i])
            }
            i &+= 1
        }
        body.append(", ")
        body.append(gradientFunction)
        body.append("(")
        visit(shaderModule[call.arguments, gradientIndex])
        body.append(", ")
        visit(shaderModule[call.arguments, gradientIndex &+ 1])
        body.append(")")
        i = gradientIndex &+ 2
        while i < shaderModule.count(call.arguments) {
            body.append(", ")
            visit(shaderModule[call.arguments, i])
            i &+= 1
        }
        body.append(")")
    }

    mutating func emitTextureSampleLevel(_ call: CallExpression, _ id: ExpressionID) {
        var isArray = false
        var is1d = false
        let texture = shaderModule[call.arguments, 0]
        let type = shaderModule.inferredType(of: texture)
        if let textureType = shaderModule.types.getIf(Types.Texture.self, type) {
            switch textureType.kind {
            case .texture2dArray, .textureCubeArray:
                isArray = true
            case .texture1d:
                is1d = true
            case .texture2d, .texture3d, .textureCube, .textureMultisampled2d:
                break
            }
        } else if let textureStorageType = shaderModule.types.getIf(Types.TextureStorage.self, type) {
            switch textureStorageType.kind {
            case .textureStorage2dArray:
                isArray = true
            case .textureStorage1d:
                is1d = true
            case .textureStorage2d, .textureStorage3d:
                break
            }
        } else {
            guard let textureDepthType = shaderModule.types.getIf(Types.TextureDepth.self, type) else {
                wgslFatal("textureSampleLevel's texture is not a texture", cppSite: "MetalFunctionWriter.cpp:2316")
            }
            switch textureDepthType.kind {
            case .textureDepth2dArray, .textureDepthCubeArray:
                isArray = true
            case .textureDepth2d, .textureDepthCube, .textureDepthMultisampled2d:
                break
            }
        }

        let levelIndex = isArray ? 4 : 3
        visit(texture)
        body.append(".sample(")
        var i = 1
        while i < levelIndex {
            if i != 1 {
                body.append(",")
            }
            if i == 3 {
                visitArrayIndexArgument(shaderModule[call.arguments, i])
            } else {
                visit(shaderModule[call.arguments, i])
            }
            i &+= 1
        }
        if !is1d {
            body.append(", level(")
            visit(shaderModule[call.arguments, levelIndex])
            body.append(")")
        }
        i = levelIndex &+ 1
        while i < shaderModule.count(call.arguments) {
            body.append(",")
            visit(shaderModule[call.arguments, i])
            i &+= 1
        }
        body.append(")")
    }

    // Emits the __wgslTextureSampleBiasWithOffset overload for this texture and returns whether there is
    // one; WGSL only allows an offset on the 2d, 2d-array and 3d overloads.
    mutating func emitTextureSampleBiasWithOffsetHelper(_ kind: Types.Texture.Kind) -> Bool {
        switch kind {
        case .texture2d:
            if !helperGenerator.didEmitTextureSampleBiasWithOffset2d {
                helperGenerator.didEmitTextureSampleBiasWithOffset2d = true
                helperGenerator.emitTextureSampleBiasWithOffset2d()
            }
            return true
        case .texture2dArray:
            if !helperGenerator.didEmitTextureSampleBiasWithOffset2dArray {
                helperGenerator.didEmitTextureSampleBiasWithOffset2dArray = true
                helperGenerator.emitTextureSampleBiasWithOffset2dArray()
            }
            return true
        case .texture3d:
            if !helperGenerator.didEmitTextureSampleBiasWithOffset3d {
                helperGenerator.didEmitTextureSampleBiasWithOffset3d = true
                helperGenerator.emitTextureSampleBiasWithOffset3d()
            }
            return true
        case .texture1d, .textureCube, .textureCubeArray, .textureMultisampled2d:
            return false
        }
    }

    mutating func emitTextureSampleBias(_ call: CallExpression, _ id: ExpressionID) {
        let texture = shaderModule[call.arguments, 0]
        guard let textureType = shaderModule.types.getIf(Types.Texture.self, shaderModule.inferredType(of: texture)) else {
            wgslFatal("textureSampleBias's texture is not a sampled texture", cppSite: "MetalFunctionWriter.cpp:2381")
        }
        var isArray = false
        switch textureType.kind {
        case .texture2dArray, .textureCubeArray:
            isArray = true
        case .texture1d, .texture2d, .texture3d, .textureCube, .textureMultisampled2d:
            break
        }

        let biasIndex = isArray ? 4 : 3

        // Passed as template parameters because sample() needs a compile-time constant offset, which is
        // what keeps a hardware fast path available. WGSL requires the offset to be a const-expression.
        var offset: ConstantValue?
        if shaderModule.count(call.arguments) > biasIndex &+ 1 {
            offset = shaderModule.constantValueForWriter(shaderModule[call.arguments, biasIndex &+ 1])
        }
        var useHelper = false
        if let offset, offset.isVector {
            useHelper = emitTextureSampleBiasWithOffsetHelper(textureType.kind)
        }

        if useHelper, let offset {
            body.append("__wgslTextureSampleBiasWithOffset<")
            var i = 0
            while i < offset.upperBound() {
                if i != 0 {
                    body.append(", ")
                }
                body.appendDecimal(offset[UInt32(truncatingIfNeeded: i)].integerValue())
                i &+= 1
            }
            body.append(">(")
            visit(texture)
            body.append(", ")
        } else {
            visit(texture)
            body.append(".sample(")
        }

        // The sampler, the coordinates and the array index are spelled the same either way.
        var i = 1
        while i < biasIndex {
            if i != 1 {
                body.append(", ")
            }
            if i == 3 {
                visitArrayIndexArgument(shaderModule[call.arguments, i])
            } else {
                visit(shaderModule[call.arguments, i])
            }
            i &+= 1
        }

        body.append(useHelper ? ", clamp(" : ", bias(clamp(")
        visit(shaderModule[call.arguments, biasIndex])
        // https://www.w3.org/TR/WGSL/#texturesamplebias : the bias must be between -16.0 and 15.99.
        // Metal applies the bias as given, so the clamp has to be spelled out here.
        body.append(useHelper ? ", -16.0f, 15.99f)" : ", -16.0f, 15.99f))")

        // The helper already has the offset as a template parameter.
        if !useHelper {
            i = biasIndex &+ 1
            while i < shaderModule.count(call.arguments) {
                body.append(", ")
                visit(shaderModule[call.arguments, i])
                i &+= 1
            }
        }
        body.append(")")
    }

    mutating func emitTextureNumLayers(_ call: CallExpression, _ id: ExpressionID) {
        visit(shaderModule[call.arguments, 0])
        body.append(".get_array_size()")
    }

    mutating func emitTextureNumLevels(_ call: CallExpression, _ id: ExpressionID) {
        visit(shaderModule[call.arguments, 0])
        body.append(".get_num_mip_levels()")
    }

    mutating func emitTextureNumSamples(_ call: CallExpression, _ id: ExpressionID) {
        visit(shaderModule[call.arguments, 0])
        body.append(".get_num_samples()")
    }

    mutating func emitTextureStore(_ call: CallExpression, _ id: ExpressionID) {
        var cast: MSLText = "uint"
        if let vector = shaderModule.types.getIf(Types.Vector.self, shaderModule.inferredType(of: shaderModule[call.arguments, 1])) {
            switch vector.size {
            case 2:
                cast = "uint2"
            case 3:
                cast = "uint3"
            default: // lint-exempt(L-ENUM-1): a vector size, as the C++ switch
                wgslFatal("textureStore's coordinates are not a vec2 or a vec3", cppSite: "MetalFunctionWriter.cpp:2476")
            }
        }

        let texture = shaderModule[call.arguments, 0]
        let coords = shaderModule[call.arguments, 1]
        var arrayIndex: ExpressionID?
        let value: ExpressionID
        if shaderModule.count(call.arguments) == 3 {
            value = shaderModule[call.arguments, 2]
        } else {
            arrayIndex = shaderModule[call.arguments, 2]
            value = shaderModule[call.arguments, 3]
        }

        visit(texture)
        body.append(".write(")
        visit(value)
        body.append(", ")
        body.append(cast)
        body.append("(")
        visit(coords)
        body.append(")")
        if let arrayIndex {
            body.append(", ")
            visit(arrayIndex)
        }
        body.append(")")

        guard let textureType = shaderModule.types.getIf(Types.TextureStorage.self, shaderModule.inferredType(of: texture)) else {
            wgslFatal("textureStore's texture is not a storage texture", cppSite: "MetalFunctionWriter.cpp:2503")
        }
        if textureType.access == .readWrite {
            body.append(";\n")
            body.append(indent)
            visit(texture)
            body.append(".fence()")
        }
    }

    mutating func emitStorageBarrier(_ call: CallExpression, _ id: ExpressionID) {
        body.append("threadgroup_barrier(mem_flags::mem_device)")
    }

    mutating func emitTextureBarrier(_ call: CallExpression, _ id: ExpressionID) {
        body.append("threadgroup_barrier(mem_flags::mem_texture)")
    }

    mutating func emitWorkgroupBarrier(_ call: CallExpression, _ id: ExpressionID) {
        body.append("threadgroup_barrier(mem_flags::mem_threadgroup)")
    }

    mutating func emitWorkgroupUniformLoad(_ call: CallExpression, _ id: ExpressionID) {
        body.append("__workgroup_uniform_load(")
        visit(shaderModule[call.arguments, 0])
        body.append(")")
    }

    mutating func emitSubgroupBallot(_ call: CallExpression, _ id: ExpressionID) {
        // WGSL's subgroupBallot returns a vec4<u32> bitmask (x: lanes 0-31, y: 32-63, ...).
        // Metal's simd_ballot returns a simd_vote; reinterpret its bits into the vec4 layout.
        body.append("uint4(as_type<uint2>((uint64_t)(simd_vote::vote_t)simd_ballot(")
        visit(shaderModule[call.arguments, 0])
        body.append(")), 0u, 0u)")
    }

    mutating func emitQuadSwap(_ call: CallExpression, _ id: ExpressionID, _ mask: UInt32) {
        // WGSL's quadSwap* map to Metal's quad_shuffle_xor with a fixed mask.
        body.append("quad_shuffle_xor(")
        visit(shaderModule[call.arguments, 0])
        body.append(", ")
        body.appendDecimal(mask)
        body.append(")")
    }

    mutating func emitQuadSwapDiagonal(_ call: CallExpression, _ id: ExpressionID) {
        emitQuadSwap(call, id, 3)
    }

    mutating func emitQuadSwapX(_ call: CallExpression, _ id: ExpressionID) {
        emitQuadSwap(call, id, 1)
    }

    mutating func emitQuadSwapY(_ call: CallExpression, _ id: ExpressionID) {
        emitQuadSwap(call, id, 2)
    }

    mutating func atomicFunction(_ name: MSLText, _ call: CallExpression, _ id: ExpressionID) {
        body.append(name)
        body.append("(")
        var first = true
        var arguments = shaderModule.cursor(call.arguments)
        while let argument = shaderModule.next(&arguments) {
            if !first {
                body.append(", ")
            }
            first = false
            visit(argument)
        }
        body.append(", memory_order_relaxed)")
    }

    mutating func emitAtomicLoad(_ call: CallExpression, _ id: ExpressionID) {
        if let prefix = MTLWorkaround.atomicLoadPrefix(gpuClass) {
            body.append(prefix)
        }
        atomicFunction("atomic_load_explicit", call, id)
        if let suffix = MTLWorkaround.atomicLoadSuffix(gpuClass) {
            body.append(suffix)
        }
    }

    mutating func emitAtomicStore(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_store_explicit", call, id)
    }

    mutating func emitAtomicAdd(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_add_explicit", call, id)
    }

    mutating func emitAtomicSub(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_sub_explicit", call, id)
    }

    mutating func emitAtomicMax(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_max_explicit", call, id)
    }

    mutating func emitAtomicMin(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_min_explicit", call, id)
    }

    mutating func emitAtomicAnd(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_and_explicit", call, id)
    }

    mutating func emitAtomicOr(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_or_explicit", call, id)
    }

    mutating func emitAtomicXor(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_fetch_xor_explicit", call, id)
    }

    mutating func emitAtomicExchange(_ call: CallExpression, _ id: ExpressionID) {
        atomicFunction("atomic_exchange_explicit", call, id)
    }

    mutating func emitArrayLength(_ call: CallExpression, _ id: ExpressionID) -> Never {
        wgslFatal("arrayLength reached the writer", cppSite: "MetalFunctionWriter.cpp:2634")
    }

    mutating func emitDistance(_ call: CallExpression, _ id: ExpressionID) {
        let argumentType = shaderModule.inferredType(of: shaderModule[call.arguments, 0])
        if shaderModule.types.getIf(Types.Primitive.self, argumentType) != nil {
            body.append("abs(")
            visit(shaderModule[call.arguments, 0])
            body.append(" - ")
            visit(shaderModule[call.arguments, 1])
            body.append(")")
            return
        }
        visit(call.target)
        visitArguments(call)
    }

    mutating func emitLength(_ call: CallExpression, _ id: ExpressionID) {
        let argumentType = shaderModule.inferredType(of: shaderModule[call.arguments, 0])
        if shaderModule.types.getIf(Types.Vector.self, argumentType) == nil {
            body.append("abs")
        } else {
            body.append("length")
        }
        visitArguments(call)
    }

    mutating func emitDegrees(_ call: CallExpression, _ id: ExpressionID) {
        body.append("static_cast<")
        guard let type = shaderModule.inferredType(of: id) else {
            wgslFatal("degrees has no inferred type", cppSite: "MetalFunctionWriter.cpp:2665")
        }
        printValueType(type)
        body.append(">(")
        visit(shaderModule[call.arguments, 0])
        body.append(" * ")
        body.append(MSLNumber.double(180 / Double.pi))
        body.append(")")
    }

    mutating func emitDynamicOffset(_ call: CallExpression, _ id: ExpressionID) {
        guard let targetType = shaderModule.inferredType(of: call.target),
            let pointer = shaderModule.types.getIf(Types.Pointer.self, targetType)
        else {
            wgslFatal("__dynamicOffset's target is not a pointer", cppSite: "MetalFunctionWriter.cpp:2674")
        }
        let addressSpace = serializeAddressSpace(pointer.addressSpace)

        body.append("(*(")
        printValueType(targetType)
        body.append(")(((")
        if let addressSpace {
            body.append(addressSpace)
        }
        body.append(" uint8_t*)&(")
        visit(shaderModule[call.arguments, 0])
        body.append(")) + ")
        // The subscript is the slot insertMaterializations recorded for this call. It passed the same slot as the call's u32
        // constant argument, which is what C++ prints.
        guard let slot = prepareResult.dynamicOffsetSlot(of: id) else {
            wgslFatal("a __dynamicOffset call that GlobalVariableRewriter did not build", cppSite: "MetalFunctionWriter.cpp:2682")
        }
        guard case .uint32(slot.index) = shaderModule.constantValueForWriter(shaderModule[call.arguments, 1]) else {
            wgslFatal("__dynamicOffset's u32 argument is not its slot", cppSite: "MetalFunctionWriter.cpp:2682")
        }
        body.appendDynamicOffsetsElement(slot)
        body.append("))")
    }

    mutating func emitBitcast(_ call: CallExpression, _ id: ExpressionID) {
        body.append("as_type<")
        guard let type = shaderModule.inferredType(of: call.target) else {
            wgslFatal("bitcast's target has no inferred type", cppSite: "MetalFunctionWriter.cpp:2689")
        }
        printValueType(type)
        body.append(">(")
        visit(shaderModule[call.arguments, 0])
        body.append(")")
    }

    mutating func emitPack2x16Float(_ call: CallExpression, _ id: ExpressionID) {
        body.append("as_type<uint>(half2(")
        visit(shaderModule[call.arguments, 0])
        body.append("))")
    }

    mutating func emitUnpack2x16Float(_ call: CallExpression, _ id: ExpressionID) {
        body.append("float2(as_type<half2>(")
        visit(shaderModule[call.arguments, 0])
        body.append("))")
    }

    mutating func emitPack4xI8(_ call: CallExpression, _ id: ExpressionID) {
        body.append("as_type<uint>(char4(")
        visit(shaderModule[call.arguments, 0])
        body.append("))")
    }

    mutating func emitPack4xI8Clamp(_ call: CallExpression, _ id: ExpressionID) {
        body.append("as_type<uint>(char4(clamp(")
        visit(shaderModule[call.arguments, 0])
        body.append(", -128, 127)))")
    }

    mutating func emitUnpack4xI8(_ call: CallExpression, _ id: ExpressionID) {
        body.append("int4(as_type<char4>(")
        visit(shaderModule[call.arguments, 0])
        body.append("))")
    }

    mutating func emitPack4xU8(_ call: CallExpression, _ id: ExpressionID) {
        body.append("as_type<uint>(uchar4(")
        visit(shaderModule[call.arguments, 0])
        body.append("))")
    }

    mutating func emitPack4xU8Clamp(_ call: CallExpression, _ id: ExpressionID) {
        body.append("as_type<uint>(uchar4(min(")
        visit(shaderModule[call.arguments, 0])
        body.append(", 255)))")
    }

    mutating func emitQuantizeToF16(_ call: CallExpression, _ id: ExpressionID) {
        let argument = shaderModule[call.arguments, 0]
        var suffix: UInt8?
        if let vectorType = shaderModule.types.getIf(Types.Vector.self, shaderModule.inferredType(of: argument)) {
            suffix = vectorType.size
        }
        body.append("float")
        if let suffix {
            body.appendDecimal(Int(suffix))
        }
        body.append("(half")
        if let suffix {
            body.appendDecimal(Int(suffix))
        }
        body.append("(")
        visit(argument)
        body.append("))")
    }

    mutating func emitRadians(_ call: CallExpression, _ id: ExpressionID) {
        body.append("static_cast<")
        guard let type = shaderModule.inferredType(of: id) else {
            wgslFatal("radians has no inferred type", cppSite: "MetalFunctionWriter.cpp:2758")
        }
        printValueType(type)
        body.append(">(")
        visit(shaderModule[call.arguments, 0])
        body.append(" * ")
        body.append(MSLNumber.double(Double.pi / 180))
        body.append(")")
    }

    mutating func emitUnpack4xU8(_ call: CallExpression, _ id: ExpressionID) {
        body.append("uint4(as_type<uchar4>(")
        visit(shaderModule[call.arguments, 0])
        body.append("))")
    }
}
