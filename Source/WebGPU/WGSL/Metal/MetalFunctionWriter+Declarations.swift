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

extension FunctionDefinitionWriter {
    mutating func shouldForceInlining(_ functionDefinition: FunctionID) -> Bool {
        switch gpuClass {
        case .belowApple9:
            return false
        case .apple9OrLater:
            break
        }
        if entryPointStage != nil {
            return false
        }

        guard let returnType = shaderModule[functionDefinition].maybeReturnType else {
            return false
        }

        guard let type = shaderModule.inferredType(of: returnType) else {
            return false
        }

        if shaderModule.types.getIf(Types.Struct.self, type) == nil && shaderModule.types.getIf(Types.Array.self, type) == nil {
            return false
        }

        guard let size = ShaderModule.maybeSize(of: type, in: &shaderModule) else {
            return false
        }
        return size >= MTLWorkaround.minimumInlinedReturnSize
    }

    /// C++ `visit(AST::Function&)` of an entry point, which writes its callees first.
    ///
    /// It takes the entry point's EntryPointInitialized, so the writer emits only functions of entry points whose workgroup
    /// variables GlobalVariableRewriter zero-initialized.
    mutating func emitEntryPoint(_ initialized: EntryPointInitialized) {
        // DEV-03: the callees come first through CallGraph's iterative walk, where the C++ recurses; the first visit wins.
        let functions = shaderModule.callGraph.calleesFirstOrder(from: initialized.function, visited: &visitedFunctions)
        var functionIndex = 0
        while functionIndex < functions.count {
            let functionDefinition = functions[functionIndex]
            functionIndex &+= 1

            var attributes = shaderModule.cursor(shaderModule[functionDefinition].attributes)
            while let attribute = shaderModule.next(&attributes) {
                checkErrorAndVisit(attribute)
                body.append(" ")
            }

            if shouldForceInlining(functionDefinition) {
                body.append(MTLWorkaround.forceInlineAttribute)
            }

            if let returnType = shaderModule[functionDefinition].maybeReturnType {
                guard let type = shaderModule.inferredType(of: returnType) else {
                    wgslFatal("a return type without an inferred type", cppSite: "MetalFunctionWriter.cpp:1009")
                }
                printValueType(type)
            } else {
                body.append("void")
            }

            body.append(" ")
            appendName(shaderModule[functionDefinition].name)
            body.append("(")
            var first = true
            var parameters = shaderModule.cursor(shaderModule[functionDefinition].parameters)
            while let parameter = shaderModule.next(&parameters) {
                if !first {
                    body.append(", ")
                }
                switch shaderModule[parameter].role {
                case .userDefined, .packedResource:
                    checkErrorAndVisit(parameter)
                case .stageIn:
                    checkErrorAndVisit(parameter)
                    body.append(" ")
                    body.append(.stageIn)
                case .bindGroup:
                    visitArgumentBufferParameter(parameter)
                }
                first = false
            }

            // Clear the flag set while serializing StageAttribute
            entryPointStage = nil

            currentFunction = functionDefinition
            body.append(")\n")
            checkErrorAndVisitCompound(shaderModule[functionDefinition].body)

            body.append("\n\n")

            currentFunction = nil
        }
    }

    /// A function is written only by emitEntryPoint, never by a traversal.
    mutating func visit(_ function: FunctionID) {
        wgslFatal("a function reached the writer without its entry point's EntryPointInitialized", cppSite: "MetalFunctionWriter.cpp:992")
    }

    mutating func visit(_ structure: StructureID) {
        let structDecl = shaderModule[structure]
        structRole = structDecl.role
        body.append(indent)
        body.append("struct ")
        appendName(structDecl.name)
        body.append(" {\n")
        do {
            indent.increment()
            defer { indent.decrement() }
            var paddingID: UInt32 = 0
            let shouldPack = structDecl.role == .packedResource

            var members = shaderModule.cursor(structDecl.members)
            while let member = shaderModule.next(&members) {
                let name = shaderModule[member].name
                let type = shaderModule.inferredType(of: shaderModule[member].type)
                // Both tests, unconditionally: Swift 6.4's ownership verifier rejects their short-circuit here.
                let isExternalTexture = shaderModule.types.isPrimitive(type, .textureExternal)
                let isExternalTextureReference = shaderModule.types.isPrimitiveReference(type, .textureExternal)
                if isExternalTexture || isExternalTextureReference {
                    visitExternalTextureMember(member, name)
                    continue
                }

                body.append(indent)

                // Check if this member has @builtin(clip_distances) attribute
                // Metal requires: float name [[clip_distance]] [N];
                if let clipDistancesArray = clipDistancesArray(member) {
                    visitClipDistancesMember(member, name, clipDistancesArray)
                } else {
                    guard let type else {
                        wgslFatal("a structure member without an inferred type", cppSite: "MetalFunctionWriter.cpp:1114")
                    }
                    printValueType(type)
                    body.append(" ")
                    appendName(name)

                    var attributes = shaderModule.cursor(shaderModule[member].attributes)
                    while let attribute = shaderModule.next(&attributes) {
                        body.append(" ")
                        visit(attribute)
                    }
                }
                body.append(";\n")

                if shouldPack && shaderModule[member].padding != 0 {
                    addPadding(&paddingID, shaderModule[member].padding)
                }
            }

            if structDecl.role == .vertexOutput || structDecl.role == .fragmentOutput {
                visitStageOutputConstructor(structDecl)
            } else if structDecl.role == .fragmentOutputWrapper || structDecl.role == .vertexOutputWrapper {
                visitStageOutputWrapperConstructor(structDecl)
            }
        }
        body.append(indent)
        body.append("};\n\n")

        if structDecl.role == .packedResource {
            visitPackedTypeImpls(structDecl)
        }

        structRole = nil

        if structDecl.role == .bindGroup {
            visitBindGroupMemberSizes(structDecl)
        }
    }

    // The parts of visit(AST::Structure&) that most structures skip, out of line so that the member loop stays small enough
    // for its node accesses to be inlined.

    @inline(never)
    private mutating func visitExternalTextureMember(_ member: StructureMemberID, _ name: IdentifierID) {
        var bindingIndex: Int64 = 0
        var attributes = shaderModule.cursor(shaderModule[member].attributes)
        while let attribute = shaderModule.next(&attributes) {
            if case .bindingAttribute(let bindingAttribute) = shaderModule[attribute].kind {
                if let bindingIndexValue = shaderModule.constantValueForWriter(bindingAttribute.binding) {
                    bindingIndex = bindingIndexValue.integerValue()
                    break
                }
            }
        }
        appendExternalTexturePlane("texture2d<float> __", name, "_FirstPlane ", bindingIndex)
        appendExternalTexturePlane("texture2d<float> __", name, "_SecondPlane ", bindingIndex &+ 1)
        appendExternalTexturePlane("float3x2 __", name, "_UVRemapMatrix ", bindingIndex &+ 2)
        appendExternalTexturePlane("float4x3 __", name, "_ColorSpaceConversionMatrix ", bindingIndex &+ 3)
        appendExternalTexturePlane("float3x3 __", name, "_PrimariesConversionMatrix ", bindingIndex &+ 4)
        appendExternalTexturePlane("uint2 __", name, "_VisibleSize ", bindingIndex &+ 5)
    }

    @inline(never)
    private mutating func visitClipDistancesMember(_ member: StructureMemberID, _ name: IdentifierID, _ arrayType: Types.Array) {
        // For clip_distances, generate: float name [[clip_distance]] [N];
        printValueType(arrayType.element) // Generate float
        body.append(" ")
        appendName(name)

        // Generate attributes (e.g., [[clip_distance]])
        var attributes = shaderModule.cursor(shaderModule[member].attributes)
        while let attribute = shaderModule.next(&attributes) {
            body.append(" ")
            visit(attribute)
        }

        // Generate array subscript [N]
        body.append(" ")
        if case .creationFixed(let size) = arrayType.size {
            body.appendArrayExtent(size)
        } else {
            body.appendArrayExtent(nil)
        }
    }

    @inline(never)
    private mutating func visitStageOutputConstructor(_ structDecl: Structure) {
        body.append("\n")
        body.append(indent)
        body.append("template<typename T>\n")
        body.append(indent)
        appendName(structDecl.name)
        body.append("(const thread T& other)\n")
        do {
            indent.increment()
            defer { indent.decrement() }
            var prefix: MSLText = ":"

            // First pass: initialize non-clip_distances members in initializer list
            var members = shaderModule.cursor(structDecl.members)
            while let member = shaderModule.next(&members) {
                // Check if this is a clip_distances member
                if clipDistancesArray(member) != nil {
                    continue // Skip C-style arrays in member initializer list
                }

                let name = shaderModule[member].name
                body.append(indent)
                body.append(prefix)
                body.append(" ")
                appendName(name)
                body.append("(other.")
                appendName(name)
                body.append(")\n")
                prefix = ","
            }
        }
        body.append(indent)
        body.append("{\n")
        do {
            indent.increment()
            defer { indent.decrement() }

            // Second pass: copy clip_distances arrays in constructor body
            var members = shaderModule.cursor(structDecl.members)
            while let member = shaderModule.next(&members) {
                if let arrayType = clipDistancesArray(member) {
                    let name = shaderModule[member].name
                    let copyLoop = ClipDistanceCopyLoop(arrayType)

                    // Generate: for (unsigned i = 0; i < N; ++i) field5[i] = other.field5[i];
                    body.append(indent)
                    body.append("for (unsigned __i = 0; __i < ")
                    if let count = copyLoop.count {
                        body.appendDecimal(count)
                    }
                    body.append("; ++__i) ")
                    appendName(name)
                    emitClipDistanceIndex(BoundsMint.clipDistanceCopyLoop(copyLoop))
                    body.append(" = other.")
                    appendName(name)
                    emitClipDistanceIndex(BoundsMint.clipDistanceCopyLoop(copyLoop))
                    body.append(";\n")
                }
            }
        }
        body.append(indent)
        body.append("}\n")
    }

    @inline(never)
    private mutating func visitStageOutputWrapperConstructor(_ structDecl: Structure) {
        assert(shaderModule.count(structDecl.members) == 1)
        let member = shaderModule[structDecl.members, 0]

        body.append("\n")
        body.append(indent)
        body.append("template<typename T>\n")
        body.append(indent)
        appendName(structDecl.name)
        body.append("(T value)\n")
        do {
            indent.increment()
            defer { indent.decrement() }
            body.append(indent)
            body.append(": ")
            appendName(shaderModule[member].name)
            body.append("(value)\n")
        }
        body.append(indent)
        body.append("{ }\n")
    }

    @inline(never)
    private mutating func visitPackedTypeImpls(_ structDecl: Structure) {
        guard let original = structDecl.original else {
            wgslFatal("a packed resource structure without its original", cppSite: "MetalFunctionWriter.cpp:1202")
        }
        body.append(indent)
        body.append("template<> struct __PackedTypeImpl<")
        appendName(shaderModule[original].name)
        body.append("> { using Type = ")
        appendName(structDecl.name)
        body.append("; };\n")
        body.append(indent)
        body.append("template<> struct __UnpackedTypeImpl<")
        appendName(structDecl.name)
        body.append("> { using Type = ")
        appendName(shaderModule[original].name)
        body.append("; };\n\n")
    }

    @inline(never)
    private mutating func visitBindGroupMemberSizes(_ structDecl: Structure) {
        var members = shaderModule.cursor(structDecl.members)
        while let member = shaderModule.next(&members) {
            guard var type = shaderModule.inferredType(of: shaderModule[member].type) else {
                wgslFatal("a structure member without an inferred type", cppSite: "MetalFunctionWriter.cpp:1213")
            }
            if let reference = shaderModule.types.getIf(Types.Reference.self, type) {
                type = reference.element
            }
            if let maybeSize = ShaderModule.maybeSize(of: type, in: &shaderModule), maybeSize.bytes < UInt32.max {
                body.append(indent)
                body.append("static_assert(sizeof(")
                appendName(structDecl.name)
                body.append("::")
                appendName(shaderModule[member].name)
                body.append(") == ")
                body.appendDecimal(maybeSize.bytes)
                body.append(");\n\n")
            }
        }
    }

    // Records a call to the packing helper for a struct, or for an array of structs, along with the
    // helpers of its members that it calls in turn, so that generatePackingHelpers() emits only those.
    mutating func usePackingHelper(_ helper: PackingHelper, _ type: TypeID?) {
        // DEV-03: a worklist of the types left to record, where the C++ recurses; only the membership of the helper sets is
        // observable, not the order of the adds.
        var pendingTypes: [TypeID] = []
        var nextType = type
        while true {
            if var type = nextType {
                if let reference = shaderModule.types.getIf(Types.Reference.self, type) {
                    type = reference.element
                }

                // The array helpers are templates, which call the helper for the element type on each element.
                if let array = shaderModule.types.getIf(Types.Array.self, type) {
                    pendingTypes.append(array.element)
                } else if let structType = shaderModule.types.getIf(Types.Struct.self, type) {
                    // A struct's helpers belong to its packed counterpart, but the calls are typed with the original.
                    var structure: StructureID? = structType.structure
                    if shaderModule[structType.structure].role != .packedResource {
                        structure = packedStructures.get(structType.structure)
                    }
                    if let structure {
                        let isNewEntry =
                            switch helper {
                            case .pack:
                                usedPackHelpers.add(structure)
                            case .unpack:
                                usedUnpackHelpers.add(structure)
                            }
                        if isNewEntry {
                            var members = shaderModule.cursor(shaderModule[structure].members)
                            while let member = shaderModule.next(&members) {
                                guard let memberType = shaderModule.inferredType(of: shaderModule[member].type) else {
                                    continue
                                }
                                pendingTypes.append(memberType)
                            }
                        }
                    }
                }
            }
            guard let pendingType = pendingTypes.popLast() else {
                return
            }
            nextType = pendingType
        }
    }

    mutating func generatePackingHelpers(_ structure: StructureID) {
        let structureNode = shaderModule[structure]
        if structureNode.role != .packedResource {
            return
        }
        guard let inferredType = structureNode.inferredType else {
            wgslFatal("a packed resource structure without an inferred type", cppSite: "MetalFunctionWriter.cpp:1257")
        }
        if !shaderModule.isConstructible(inferredType) {
            return
        }

        let packedName = structureNode.name
        guard let original = structureNode.original else {
            wgslFatal("a packed resource structure without its original", cppSite: "MetalFunctionWriter.cpp:1261")
        }
        let unpackedName = shaderModule[original].name

        if usedPackHelpers.contains(structure) {
            generatePackHelper(structureNode, packedName, unpackedName)
        }

        if usedUnpackHelpers.contains(structure) {
            generateUnpackHelper(structureNode, packedName, unpackedName)
        }
    }

    // The two helpers of generatePackingHelpers, out of line so that its checks stay small enough for their node accesses
    // to be inlined.

    @inline(never)
    private mutating func generatePackHelper(_ structureNode: Structure, _ packedName: IdentifierID, _ unpackedName: IdentifierID) {
        body.append(indent)
        body.append("static __attribute__((always_inline)) ")
        appendName(packedName)
        body.append(" __pack(")
        appendName(unpackedName)
        body.append(" unpacked)\n")
        body.append(indent)
        body.append("{\n")
        do {
            indent.increment()
            defer { indent.decrement() }
            body.append(indent)
            appendName(packedName)
            body.append(" packed;\n")
            var members = shaderModule.cursor(structureNode.members)
            while let member = shaderModule.next(&members) {
                let name = shaderModule[member].name
                let needsPack = memberNeedsPacking(member)
                if needsPack {
                    body.append(indent)
                    body.append("packed.")
                    appendName(name)
                    body.append(" = __pack(unpacked.")
                    appendName(name)
                    body.append(");\n")
                } else {
                    body.append(indent)
                    body.append("packed.")
                    appendName(name)
                    body.append(" = unpacked.")
                    appendName(name)
                    body.append(";\n")
                }
            }
            body.append(indent)
            body.append("return packed;\n")
        }
        body.append(indent)
        body.append("}\n\n")
    }

    @inline(never)
    private mutating func generateUnpackHelper(_ structureNode: Structure, _ packedName: IdentifierID, _ unpackedName: IdentifierID) {
        body.append(indent)
        body.append("static ")
        appendName(unpackedName)
        body.append(" __unpack(")
        appendName(packedName)
        body.append(" packed)\n")
        body.append(indent)
        body.append("{\n")
        do {
            indent.increment()
            defer { indent.decrement() }
            body.append(indent)
            appendName(unpackedName)
            body.append(" unpacked;\n")
            var members = shaderModule.cursor(structureNode.members)
            while let member = shaderModule.next(&members) {
                let name = shaderModule[member].name
                let needsUnpack = memberNeedsPacking(member)
                if needsUnpack {
                    body.append(indent)
                    body.append("unpacked.")
                    appendName(name)
                    body.append(" = __unpack(packed.")
                    appendName(name)
                    body.append(");\n")
                } else {
                    body.append(indent)
                    body.append("unpacked.")
                    appendName(name)
                    body.append(" = packed.")
                    appendName(name)
                    body.append(";\n")
                }
            }
            body.append(indent)
            body.append("return unpacked;\n")
        }
        body.append(indent)
        body.append("}\n\n")
    }

    mutating func shouldPackType() -> Bool {
        if structRole == .packedResource || structRole == .bindGroup {
            return true
        }
        if variableRole == .packedResource {
            return true
        }
        if parameterRole == .packedResource {
            return true
        }
        return false
    }

    mutating func emitPackedVector(_ vector: Types.Vector, _ shouldPack: Bool) -> Bool {
        if !shouldPack {
            return false
        }

        // The only vectors that need to be packed are the vectors with 3 elements,
        // because their size differs between Metal and WGSL (4 * element size vs
        // 3 * element size, respectively)
        if vector.size != 3 {
            return false
        }

        guard case .primitive(let primitive) = shaderModule.types[vector.element] else {
            wgslFatal("a packed vector whose element is not a primitive", cppSite: "MetalFunctionWriter.cpp:1334")
        }
        switch primitive.kind {
        case .abstractInt, .i32:
            body.append("packed_int")
            body.appendDecimal(UInt32(vector.size))
        case .u32:
            body.append("packed_uint")
            body.appendDecimal(UInt32(vector.size))
        case .abstractFloat, .f32:
            body.append("packed_float")
            body.appendDecimal(UInt32(vector.size))
        case .f16:
            body.append("packed_half")
            body.appendDecimal(UInt32(vector.size))
        case .bool, .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
            wgslFatal("a packed vector of a non-numeric primitive", cppSite: "MetalFunctionWriter.cpp:1358")
        }
        return true
    }

    mutating func visit(_ variable: VariableID) {
        serializeVariable(variable)
    }

    mutating func visit(_ assertion: ConstAssertID) {
        // const_assert should not generate any code
    }

    mutating func serializeVariable(_ variable: VariableID) {
        let variableNode = shaderModule[variable]
        if variableNode.flavor == .const {
            return
        }

        let savedVariableRole = variableRole
        variableRole = variableNode.role
        defer { variableRole = savedVariableRole }

        let type = variableNode.storeType
        if shaderModule.types.isPrimitiveReference(type, .textureExternal) {
            assert(variableNode.maybeInitializer != nil)
            guard let initializer = variableNode.maybeInitializer else {
                // DEV-08: C++ asserts in Debug and dereferences nullptr in release.
                wgslFatal("a texture_external variable without an initializer", cppSite: "MetalFunctionWriter.cpp:1384")
            }
            body.append("texture_external ")
            appendName(variableNode.name)
            body.append(" { ")
            visit(initializer)
            body.append("_FirstPlane, ")
            visit(initializer)
            body.append("_SecondPlane, ")
            visit(initializer)
            body.append("_UVRemapMatrix, ")
            visit(initializer)
            body.append("_ColorSpaceConversionMatrix, ")
            visit(initializer)
            body.append("_PrimariesConversionMatrix, ")
            visit(initializer)
            body.append("_VisibleSize }")
            return
        }

        if let qualifier = variableNode.maybeQualifier {
            switch qualifier.addressSpace {
            case .workgroup:
                body.append("threadgroup ")
            case .function, .handle, .private, .storage, .uniform:
                break
            }
        }

        if !emitTextureReference(type) {
            guard let type else {
                wgslFatal("a variable without a store type", cppSite: "MetalFunctionWriter.cpp:1414")
            }
            printValueType(type)
        }
        body.append(" ")
        appendName(variableNode.name)

        if variableNode.flavor == .override {
            return
        }

        switch VariableInitialization(variableNode.maybeInitializer) {
        case .expression(let initializer):
            body.append(" = ")
            visitExpression(type, initializer)
        case .valueInitialized:
            body.append(" { }")
        }
    }

    // Every texture is bound through an argument buffer, so any texture a function can name is in the
    // constant address space, and is referred to there instead of being copied. A copy would only copy
    // the texture's handle, but it is expensive to compile: since MSL 3.2 some of a texture's copy
    // constructors take a coherent(device) texture, which is a separate specialization of the texture
    // class, and resolving the copy has to instantiate that specialization, which costs about as much
    // as the texture class itself. That is paid for each texture type a library copies.
    mutating func emitTextureReference(_ type: TypeID?) -> Bool {
        guard var type else {
            wgslFatal("a texture reference check of a missing type", cppSite: "MetalFunctionWriter.cpp:1441")
        }
        if let reference = shaderModule.types.getIf(Types.Reference.self, type) {
            if reference.addressSpace != .handle {
                return false
            }
            type = reference.element
        }

        if shaderModule.types.getIf(Types.Texture.self, type) == nil && shaderModule.types.getIf(Types.TextureStorage.self, type) == nil
            && shaderModule.types.getIf(Types.TextureDepth.self, type) == nil
        {
            return false
        }

        body.append("const constant ")
        printValueType(type)
        body.append("&")
        return true
    }

    mutating func visit(_ attribute: AttributeID) {
        dispatch(attribute)
    }

    mutating func visit(_ builtin: BuiltinAttribute, _ id: AttributeID) {
        // Built-in attributes are only valid for parameters. If a struct member originally
        // had a built-in attribute it must have already been hoisted into a parameter, but
        // we keep the original struct so we can reconstruct it.
        if let structRole,
            structRole != .vertexOutput && structRole != .vertexOutputWrapper && structRole != .fragmentOutput
                && structRole != .fragmentOutputWrapper
        {
            return
        }

        switch builtin.builtin {
        case .clipDistances:
            body.append(.clipDistance)
        case .fragDepth:
            body.append(.depthAny)
        case .frontFacing:
            body.append(.frontFacing)
        case .globalInvocationId:
            body.append(.threadPositionInGrid)
        case .instanceIndex:
            body.append(.instanceID)
        case .localInvocationId:
            body.append(.threadPositionInThreadgroup)
        case .localInvocationIndex:
            body.append(.threadIndexInThreadgroup)
        case .numWorkgroups:
            body.append(.threadgroupsPerGrid)
        case .position:
            body.append(.position)
        case .primitiveIndex:
            body.append(.primitiveID)
        case .sampleIndex:
            body.append(.sampleID)
        case .sampleMask:
            body.append(.sampleMask)
        case .subgroupInvocationId:
            body.append(.threadIndexInSimdgroup)
        case .subgroupSize:
            body.append(.threadsPerSimdgroup)
        case .subgroupId:
            body.append(.simdgroupIndexInThreadgroup)
        case .numSubgroups:
            body.append(.simdgroupsPerThreadgroup)
        case .vertexIndex:
            body.append(.vertexID)
        case .workgroupId:
            body.append(.threadgroupPositionInGrid)
        }
    }

    mutating func visit(_ stage: StageAttribute, _ id: AttributeID) {
        entryPointStage = stage.stage
        switch stage.stage {
        case .vertex:
            body.append(.vertex)
        case .fragment:
            body.append(.fragment)
        case .compute:
            body.append(.kernel)
        }
    }

    mutating func visit(_ group: GroupAttribute, _ id: AttributeID) {
        guard let groupValue = shaderModule.constantValueForWriter(group.group) else {
            wgslFatal("a @group attribute without a constant value", cppSite: "MetalFunctionWriter.cpp:1540")
        }
        var bufferIndex = UInt32(truncatingIfNeeded: groupValue.integerValue())
        if entryPointStage == .vertex {
            assert(shaderModule.configuration.maxBuffersPlusVertexBuffersForVertexStage > 0)
            let max = shaderModule.configuration.maxBuffersPlusVertexBuffersForVertexStage &- 1
            bufferIndex = vertexBufferIndexForBindGroup(bufferIndex, maxIndex: max)
        }
        body.append(.buffer(bufferIndex))
    }

    mutating func visit(_ binding: BindingAttribute, _ id: AttributeID) {
        guard let bindingValue = shaderModule.constantValueForWriter(binding.binding) else {
            wgslFatal("a @binding attribute without a constant value", cppSite: "MetalFunctionWriter.cpp:1551")
        }
        body.append(.id(bindingValue.integerValue()))
    }

    mutating func visit(_ location: LocationAttribute, _ id: AttributeID) {
        if let role = structRole {
            switch role {
            case .vertexOutput, .fragmentInput, .vertexOutputWrapper:
                body.append(.userLocation(locationValue(location)))
                return
            case .bindGroup, .userDefined, .computeInput, .userDefinedResource, .packedResource:
                return
            case .fragmentOutputWrapper, .fragmentOutput:
                body.append(.color(locationValue(location)))
                return
            case .vertexInput:
                body.append(.attribute(locationValue(location)))
            }
        }
    }

    mutating func visit(_ attribute: WorkgroupSizeAttribute, _ id: AttributeID) {
        // This attribute shouldn't generate any code. The workgroup size is passed
        // to the API through the EntryPointInformation.
    }

    mutating func visit(_ attribute: SizeAttribute, _ id: AttributeID) {
        // This attribute shouldn't generate any code. The size is used when serializing
        // structs.
    }

    mutating func visit(_ attribute: AlignAttribute, _ id: AttributeID) {
        // This attribute shouldn't generate any code. The alignment is used when
        // serializing structs.
    }
}

private func convertToSampleMode(_ type: InterpolationType, _ sampleType: InterpolationSampling) -> MSLAttribute {
    switch type {
    case .flat:
        return .flat
    case .linear:
        switch sampleType {
        case .first, .either:
            wgslFatal("a linear interpolation with first or either sampling", cppSite: "MetalFunctionWriter.cpp:1608")
        case .center:
            return .centerNoPerspective
        case .centroid:
            return .centroidNoPerspective
        case .sample:
            return .sampleNoPerspective
        }
    case .perspective:
        switch sampleType {
        case .first, .either:
            wgslFatal("a perspective interpolation with first or either sampling", cppSite: "MetalFunctionWriter.cpp:1620")
        case .center:
            return .centerPerspective
        case .centroid:
            return .centroidPerspective
        case .sample:
            return .samplePerspective
        }
    }
}

extension FunctionDefinitionWriter {
    mutating func visit(_ attribute: InterpolateAttribute, _ id: AttributeID) {
        body.append(convertToSampleMode(attribute.type, attribute.sampling))
    }

    mutating func visit(_ attribute: InvariantAttribute, _ id: AttributeID) {
        if structRole != .vertexOutput && structRole != .vertexOutputWrapper {
            return
        }

        body.append(.invariant)
    }
}

// MARK: - Swift-only

/// How the writer initializes a variable it declares: `= initializer` or value-initialized `{ }`, never uninitialized.
enum VariableInitialization {
    case expression(ExpressionID)
    case valueInitialized

    init(_ initializer: ExpressionID?) {
        if let initializer {
            self = .expression(initializer)
        } else {
            self = .valueInitialized
        }
    }
}

/// The bound of the writer's clip-distance copy loop (MetalFunctionWriter.cpp:1177-1181).
///
/// `__i` runs from 0 while it is less than the array's element count, so the loop's subscripts are in bounds. A nil count is
/// printed as no bound, as the C++ does, which Metal rejects. Only this file makes one; BoundsMint.clipDistanceCopyLoop requires
/// one.
struct ClipDistanceCopyLoop: ~Copyable {
    let count: UInt32?

    fileprivate init(_ arrayType: Types.Array) {
        switch arrayType.size {
        case .creationFixed(let count):
            self.count = count
        case .runtime, .overrideSized:
            self.count = nil
        }
    }
}

extension FunctionDefinitionWriter {
    private mutating func appendName(_ identifier: IdentifierID) {
        body.append(identifier: shaderModule.symbol(of: identifier), in: shaderModule.symbols)
    }

    /// The loop over a member's attributes that visit(AST::Structure&) repeats for each of its three member passes.
    private mutating func isClipDistances(_ member: StructureMemberID) -> Bool {
        var attributes = shaderModule.cursor(shaderModule[member].attributes)
        while let attribute = shaderModule.next(&attributes) {
            if case .builtinAttribute(let builtinAttr) = shaderModule[attribute].kind {
                if builtinAttr.builtin == .clipDistances {
                    return true
                }
            }
        }
        return false
    }

    /// The array type of a clip_distances member, which the three member passes of visit(AST::Structure&) write as a C-style
    /// array; nil for every other member.
    private mutating func clipDistancesArray(_ member: StructureMemberID) -> Types.Array? {
        guard isClipDistances(member) else {
            return nil
        }
        // DEV-26: C++ writes every clip_distances member as an array, with undefined behaviour for one that is not.
        return shaderModule.types.getIf(Types.Array.self, shaderModule.inferredType(of: shaderModule[member].type))
    }

    /// generatePackingHelpers' `needsPack`/`needsUnpack`: packed structs and arrays, and matrices with three rows.
    private mutating func memberNeedsPacking(_ member: StructureMemberID) -> Bool {
        guard let memberType = shaderModule.inferredType(of: shaderModule[member].type) else {
            wgslFatal("a structure member without an inferred type", cppSite: "MetalFunctionWriter.cpp:1272")
        }
        var needsPack = !shaderModule.packing(of: memberType).isDisjoint(with: [.pStruct, .pArray])
        if !needsPack {
            if let matrix = shaderModule.types.getIf(Types.Matrix.self, memberType) {
                needsPack = matrix.rows == 3
            }
        }
        return needsPack
    }

    /// visit(AST::Structure&)'s `addPadding` lambda.
    private mutating func addPadding(_ paddingID: inout UInt32, _ paddingSize: UInt32) {
        paddingID &+= 1
        body.append(indent)
        body.append("uint8_t __padding")
        body.appendDecimal(paddingID)
        body.appendArrayExtent(paddingSize)
        body.append("; \n")
    }

    /// A line of a texture_external member's expansion in visit(AST::Structure&).
    private mutating func appendExternalTexturePlane(_ type: MSLText, _ name: IdentifierID, _ suffix: MSLText, _ bindingIndex: Int64) {
        body.append(indent)
        body.append(type)
        appendName(name)
        body.append(suffix)
        body.append(.id(bindingIndex))
        body.append(";\n")
    }

    /// `location.location().constantValue()->integerValue()`.
    private mutating func locationValue(_ location: LocationAttribute) -> Int64 {
        guard let value = shaderModule.constantValueForWriter(location.location) else {
            wgslFatal("a @location attribute without a constant value", cppSite: "MetalFunctionWriter.cpp:1562")
        }
        return value.integerValue()
    }

    /// `[__i]`, a subscript of the clip-distance copy loop.
    private mutating func emitClipDistanceIndex(_ proof: SubscriptProof) {
        let openSubscript = body.emitSubscript(proof)
        // lint-exempt-next-line(L-MSL-3): the copy loop's own induction variable, declared by its header (MetalFunctionWriter.cpp:1178)
        body.append("__i")
        body.closeSubscript(openSubscript)
    }
}
