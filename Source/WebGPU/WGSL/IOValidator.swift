// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2026 Apple Inc. All rights reserved.
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

private enum Direction: UInt8 {
    case input
    case output
}

private struct IOValidator: ASTScopedVisitor, ~Copyable {
    typealias ContextValue = CallGraphGlobalID?

    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<CallGraphGlobalID?>()

    private typealias Builtins = LookupSet<Builtin>
    private typealias Locations = LookupSet<UInt64>

    private var usedGlobals = IDSet<CallGraphGlobalID>()
    private var textureSamplerPairs: [CallGraph.TextureSamplerPair] = []
    private var stage = ShaderStage.vertex
    // DEV-04: what visit(Function) leaves in usedGlobals and textureSamplerPairs for each function, per entry point.
    private var visitedFunctions = LookupMap<FunctionID, VisitedFunction>()

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func validateIO() {
        collectGlobals()

        var index = 0
        while index < shaderModule.callGraph.entrypoints.count {
            let entryPoint = shaderModule.callGraph.entrypoints[index]
            validateEntryPointIO(entryPoint)
            guard !hasError else {
                return
            }

            stage = entryPoint.stage
            visitedFunctions = LookupMap()
            visit(entryPoint.function)
            guard !hasError else {
                return
            }

            let entryPointUsedGlobals = usedGlobals
            var entryPointTextureSamplerPairs: [CallGraph.TextureSamplerPair] = []
            swap(&entryPointTextureSamplerPairs, &textureSamplerPairs)
            shaderModule.modifyCallGraph { callGraph in
                callGraph.modifyEntryPoint(at: index) { entryPoint in
                    entryPoint.usedGlobals.addAll(entryPointUsedGlobals)
                    entryPoint.textureSamplerPairs = entryPointTextureSamplerPairs
                }
            }
            usedGlobals.clear()
            textureSamplerPairs.removeAll()

            validateResources(shaderModule.callGraph.entrypoints[index])
            guard !hasError else {
                return
            }
            index += 1
        }
    }

    private mutating func collectGlobals() {
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            guard case .variable(let globalVar) = declaration else {
                continue
            }
            let variable = shaderModule[globalVar]
            var resource: CallGraph.Global.Resource?
            if let group = variable.group {
                guard let binding = variable.binding else {
                    wgslFatal("a global variable with @group but no @binding", cppSite: "IOValidator.cpp:118")
                }
                resource = ResourceBinding(group: group, binding: binding)
            }

            let global = shaderModule.modifyCallGraph { callGraph in
                callGraph.addGlobal(CallGraph.Global(resource: resource, declaration: globalVar))
            }
            introduceVariable(variable.name, global)
        }
    }

    // The C++ recursion over the callees, as CallGraph.walk events: per edge, a callee whose record already has used
    // globals is reused (`.edge`, skipped), any other is visited and its record written back (`.edgeDone`); the
    // function's own body is visited last (`.exit`).
    mutating func visit(_ function: FunctionID) {
        var calleeLocals: [CalleeLocals] = []
        var calleeWalk = shaderModule.callGraph.walk(from: function)
        while let event = calleeWalk.next(shaderModule.callGraph) {
            switch event {
            case .enter:
                calleeLocals.append(CalleeLocals())
            case .edge(let caller, let calleeIndex):
                let callee = shaderModule.callGraph.callees(caller)[calleeIndex]
                let current = calleeLocals.count - 1
                if !callee.usedGlobals.isEmpty {
                    calleeLocals[current].usedGlobals.addAll(callee.usedGlobals)
                    appendIfNotContains(callee.textureSamplerPairs, to: &calleeLocals[current].textureSamplerPairs)
                    calleeWalk.skip()
                } else if hasError {
                    // DEV-04: after an error C++ goes on visiting callees, which only writes records nobody reads.
                    calleeWalk.skip()
                } else if let visited = visitedFunctions.get(callee.target) {
                    // DEV-04: the callee was visited for this entry point already; a second visit finds the same.
                    calleeLocals[current].isVisitingCallee = true
                    usedGlobals = visited.usedGlobals
                    textureSamplerPairs = visited.textureSamplerPairs
                    calleeWalk.skip()
                } else {
                    calleeLocals[current].isVisitingCallee = true
                    calleeWalk.descend()
                }
            case .edgeDone(let caller, let calleeIndex):
                let current = calleeLocals.count - 1
                guard calleeLocals[current].isVisitingCallee else {
                    break
                }
                calleeLocals[current].isVisitingCallee = false
                let calleeUsedGlobals = usedGlobals
                let calleeTextureSamplerPairs = textureSamplerPairs
                shaderModule.modifyCallGraph { callGraph in
                    callGraph.modifyCallee(of: caller, at: calleeIndex) { callee in
                        callee.usedGlobals.addAll(calleeUsedGlobals)
                        callee.textureSamplerPairs = calleeTextureSamplerPairs
                    }
                }
                calleeLocals[current].usedGlobals.addAll(usedGlobals)
                appendIfNotContains(textureSamplerPairs, to: &calleeLocals[current].textureSamplerPairs)
                usedGlobals.clear()
                textureSamplerPairs.removeAll()
            case .exit(let exited, _):
                let locals = calleeLocals.removeLast()
                usedGlobals.addAll(locals.usedGlobals)
                appendIfNotContains(locals.textureSamplerPairs, to: &textureSamplerPairs)
                visitChildren(exited)
                if !hasError {
                    visitedFunctions.set(exited, VisitedFunction(usedGlobals: usedGlobals, textureSamplerPairs: textureSamplerPairs))
                }
            }
        }
    }

    mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        introduceVariable(shaderModule[statement.variable].name, nil)
        visitChildren(statement, id)
    }

    mutating func visit(_ parameter: ParameterID) {
        introduceVariable(shaderModule[parameter].name, nil)
        visitChildren(parameter)
    }

    mutating func visit(_ identifier: IdentifierExpression, _ id: ExpressionID) {
        visitChildren(identifier, id)

        guard let variable = readVariable(identifier.identifier), let global = variable else {
            return
        }

        let variableNode = shaderModule[shaderModule.callGraph[global].declaration]
        if let addressSpace = variableNode.addressSpace {
            if stage != .compute && addressSpace == .workgroup {
                error(
                    shaderModule.span(of: id),
                    "var with `workgroup` address space cannot be used by `\(toString(stage))` pipeline stage"
                )
                return
            }

            if stage == .vertex {
                if let textureStorage = shaderModule.types.getIf(Types.TextureStorage.self, variableNode.storeType),
                    textureStorage.access.rawValue & AccessMode.write.rawValue != 0
                {
                    error(
                        shaderModule.span(of: id),
                        "storage texture with `read_write` access mode cannot be used by `vertex` pipeline stage"
                    )
                    return
                }

                if let accessMode = variableNode.accessMode, addressSpace == .storage, accessMode.rawValue & AccessMode.write.rawValue != 0
                {
                    error(
                        shaderModule.span(of: id),
                        "var with `storage` address space and `read_write` access mode cannot be used by `vertex` pipeline stage"
                    )
                    return
                }
            }
        }
        usedGlobals.add(global)
    }

    private static func isTextureBinding(_ type: TypeID?, _ types: borrowing TypeStore) -> Bool {
        guard let type else {
            return false
        }
        switch types[type] {
        case .texture, .textureDepth, .textureStorage:
            return true
        case .primitive(let primitive):
            return primitive.kind == .textureExternal
        case .vector, .matrix, .array, .struct, .primitiveStruct, .function, .reference, .pointer, .atomic, .typeConstructor:
            return false
        }
    }

    private static func isSamplerBinding(_ type: TypeID?, _ types: borrowing TypeStore) -> Bool {
        guard let type else {
            return false
        }
        guard let primitive = types.getIf(Types.Primitive.self, type) else {
            return false
        }
        return primitive.kind == .sampler || primitive.kind == .samplerComparison
    }

    private static func takesTextureAndSampler(_ builtin: Symbol?) -> Bool {
        guard let builtin else {
            return false
        }
        return builtin == BuiltinSymbols.textureGather
            || builtin == BuiltinSymbols.textureGatherCompare
            || builtin == BuiltinSymbols.textureSample
            || builtin == BuiltinSymbols.textureSampleBaseClampToEdge
            || builtin == BuiltinSymbols.textureSampleBias
            || builtin == BuiltinSymbols.textureSampleCompare
            || builtin == BuiltinSymbols.textureSampleCompareLevel
            || builtin == BuiltinSymbols.textureSampleGrad
            || builtin == BuiltinSymbols.textureSampleLevel
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        visitChildren(call, id)

        // Only the type checker knows whether a call names a builtin or a user function, and it
        // records that as the resolved target.
        guard Self.takesTextureAndSampler(call.resolvedTarget) else {
            return
        }

        var texture: CallGraphGlobalID?
        var sampler: CallGraphGlobalID?
        var arguments = shaderModule.cursor(call.arguments)
        while let argument = shaderModule.next(&arguments) {
            guard case .identifierExpression(let identifier) = shaderModule[argument].kind else {
                continue
            }
            // FIXME: a texture or a sampler reaching the builtin through a function parameter
            // resolves to no global, so the pair goes unrecorded. Tracking those needs the pair
            // analysis to run over the call graph rather than over each function in isolation.
            guard let variable = readVariable(identifier.identifier), let global = variable else {
                continue
            }
            let storeType = shaderModule[shaderModule.callGraph[global].declaration].storeType
            if Self.isTextureBinding(storeType, shaderModule.types) {
                texture = global
            } else if Self.isSamplerBinding(storeType, shaderModule.types) {
                sampler = global
            }
        }

        guard let texture, let sampler, let textureResource = shaderModule.callGraph[texture].resource,
            let samplerResource = shaderModule.callGraph[sampler].resource
        else {
            return
        }

        textureSamplerPairs.appendIfNotContains(CallGraph.TextureSamplerPair(texture: textureResource, sampler: samplerResource))
    }

    private mutating func validateResources(_ entryPoint: CallGraph.EntryPoint) {
        // DEV-05: every (group, binding) is an ordinary key; C++ keys on {group + 1, binding + 1}, which traps at UINT_MAX.
        var usedResources = LookupMap<ResourceBinding, CallGraphGlobalID>()
        // DEV-01: the globals in declaration order (C++ iterates a pointer-hash set); the first conflict is reported.
        entryPoint.usedGlobals.forEachInCreationOrder { global in
            guard !hasError else {
                return
            }
            let globalNode = shaderModule.callGraph[global]
            guard let resource = globalNode.resource else {
                return
            }

            guard usedResources.add(resource, global) else {
                guard let original = usedResources.get(resource) else {
                    wgslFatal("a binding conflict without the first variable", cppSite: "IOValidator.cpp:278")
                }
                let variable = shaderModule[globalNode.declaration]
                let entryPointName = shaderModule.symbols.text(of: entryPoint.originalName)
                let originalDeclaration = originalName(shaderModule.callGraph[original].declaration)
                let variableName = originalName(globalNode.declaration)
                error(
                    variable.span,
                    """
                    entry point '\(entryPointName)' uses variables '\(originalDeclaration)' and '\(variableName)', \
                    both which use the same resource binding: @group(\(resource.group)) @binding(\(resource.binding))
                    """
                )
                return
            }
        }
    }

    private mutating func validateEntryPointIO(_ entryPoint: CallGraph.EntryPoint) {
        let function = shaderModule[entryPoint.function]
        var builtins = Builtins()
        var locations = Locations()
        var parameters = shaderModule.cursor(function.parameters)
        while !parameters.isAtEnd {
            let parameter = shaderModule[shaderModule.advance(&parameters)]
            let span = parameter.span
            let type = shaderModule.inferredType(of: parameter.typeName)

            if let builtin = parameter.builtin {
                validateBuiltinIO(span, type, entryPoint.stage, builtin, .input, &builtins)
                guard !hasError else {
                    return
                }
                continue
            }

            if let location = parameter.location {
                validateLocationIO(span, type, entryPoint.stage, location, &locations)
                guard !hasError else {
                    return
                }
                validateInterpolationIO(span, entryPoint.stage, .input, type, parameter.interpolation)
                guard !hasError else {
                    return
                }
                continue
            }

            if let structType = shaderModule.types.getIf(Types.Struct.self, type) {
                validateStructIO(entryPoint.stage, structType, .input, &builtins, &locations)
                guard !hasError else {
                    return
                }
                continue
            }

            error(span, "missing entry point IO attribute on parameter")
            return
        }

        guard let returnType = function.maybeReturnType else {
            if entryPoint.stage == .vertex {
                error(function.span, "a vertex shader must include the 'position' builtin in its return type")
            }
            return
        }

        builtins.clear()
        locations.clear()
        let span = shaderModule.span(of: returnType)
        let type = shaderModule.inferredType(of: returnType)

        if let builtin = function.returnTypeBuiltin {
            validateBuiltinIO(span, type, entryPoint.stage, builtin, .output, &builtins)
            guard !hasError else {
                return
            }
        } else if let location = function.returnTypeLocation {
            validateLocationIO(span, type, entryPoint.stage, location, &locations)
            guard !hasError else {
                return
            }
        } else if let structType = shaderModule.types.getIf(Types.Struct.self, type) {
            validateStructIO(entryPoint.stage, structType, .output, &builtins, &locations)
            guard !hasError else {
                return
            }
        } else {
            error(span, "missing entry point IO attribute on return type")
            return
        }

        if entryPoint.stage == .vertex && !builtins.contains(.position) {
            error(span, "a vertex shader must include the 'position' builtin in its return type")
        }
    }

    private mutating func validateBuiltinIO(
        _ span: SourceSpan,
        _ type: TypeID?,
        _ stage: ShaderStage,
        _ builtin: Builtin,
        _ direction: Direction,
        _ builtins: inout Builtins
    ) {
        switch builtin {
        case .clipDistances:
            // clip_distances requires the extension to be enabled
            guard shaderModule.enabledExtensions.contains(.clipDistances) else {
                error(span, "@builtin(clip_distances) requires the 'clip_distances' extension to be enabled")
                return
            }
            // @builtin(clip_distances) must be array<f32, N> where N is determined by the array size
            var isValidType = false
            if let arrayType = shaderModule.types.getIf(Types.Array.self, type), arrayType.element == shaderModule.types.f32Type,
                case .creationFixed(let size) = arrayType.size
            {
                isValidType = size <= 8
            }
            guard isValidType else {
                error(span, "store type of @builtin(clip_distances) must be 'array<f32, N>' (N <= 8)")
                return
            }
            guard stage == .vertex && direction == .output else {
                error(span, "@builtin(clip_distances) can only be used for vertex shader output")
                return
            }
        case .fragDepth:
            guard builtinCase(span, type, stage, direction, .fragDepth, .type(shaderModule.types.f32Type), (.fragment, .output)) else {
                return
            }
        case .frontFacing:
            guard builtinCase(span, type, stage, direction, .frontFacing, .type(shaderModule.types.boolType), (.fragment, .input)) else {
                return
            }
        case .globalInvocationId:
            guard
                builtinCase(
                    span,
                    type,
                    stage,
                    direction,
                    .globalInvocationId,
                    .vector(3, shaderModule.types.u32Type, "vec3<u32>"),
                    (.compute, .input)
                )
            else {
                return
            }
        case .instanceIndex:
            guard builtinCase(span, type, stage, direction, .instanceIndex, .type(shaderModule.types.u32Type), (.vertex, .input)) else {
                return
            }
        case .localInvocationId:
            guard
                builtinCase(
                    span,
                    type,
                    stage,
                    direction,
                    .localInvocationId,
                    .vector(3, shaderModule.types.u32Type, "vec3<u32>"),
                    (.compute, .input)
                )
            else {
                return
            }
        case .localInvocationIndex:
            guard builtinCase(span, type, stage, direction, .localInvocationIndex, .type(shaderModule.types.u32Type), (.compute, .input))
            else {
                return
            }
        case .numWorkgroups:
            guard
                builtinCase(
                    span,
                    type,
                    stage,
                    direction,
                    .numWorkgroups,
                    .vector(3, shaderModule.types.u32Type, "vec3<u32>"),
                    (.compute, .input)
                )
            else {
                return
            }
        case .primitiveIndex:
            // primitive_index requires the extension to be enabled
            guard shaderModule.enabledExtensions.contains(.primitiveIndex) else {
                error(span, "@builtin(primitive_index) requires the 'primitive_index' extension to be enabled")
                return
            }
            // Type check: must be u32
            guard type == shaderModule.types.u32Type else {
                error(span, "store type of @builtin(primitive_index) must be 'u32'")
                return
            }
            // Stage and direction check: must be fragment shader input
            guard stage == .fragment && direction == .input else {
                error(span, "@builtin(primitive_index) can only be used for fragment shader input")
                return
            }
        case .sampleIndex:
            guard builtinCase(span, type, stage, direction, .sampleIndex, .type(shaderModule.types.u32Type), (.fragment, .input)) else {
                return
            }
        case .subgroupInvocationId, .subgroupSize:
            // subgroup_invocation_id / subgroup_size require the 'subgroups' extension.
            guard shaderModule.enabledExtensions.contains(.subgroups) else {
                error(span, "@builtin(\(toString(builtin))) requires the 'subgroups' extension to be enabled")
                return
            }
            guard type == shaderModule.types.u32Type else {
                error(span, "store type of @builtin(\(toString(builtin))) must be 'u32'")
                return
            }
            guard (stage == .compute || stage == .fragment) && direction == .input else {
                error(span, "@builtin(\(toString(builtin))) can only be used for compute or fragment shader input")
                return
            }
        case .subgroupId, .numSubgroups:
            // subgroup_id / num_subgroups are gated on the 'subgroups' enable-extension. The
            // 'subgroup_id' language extension is reported (and 'requires subgroup_id;' is
            // accepted), but per WGSL §3.8.5 it is not required to be explicitly requested.
            guard shaderModule.enabledExtensions.contains(.subgroups) else {
                error(span, "@builtin(\(toString(builtin))) requires the 'subgroups' extension to be enabled")
                return
            }
            guard type == shaderModule.types.u32Type else {
                error(span, "store type of @builtin(\(toString(builtin))) must be 'u32'")
                return
            }
            guard stage == .compute && direction == .input else {
                error(span, "@builtin(\(toString(builtin))) can only be used for compute shader input")
                return
            }
        case .vertexIndex:
            guard builtinCase(span, type, stage, direction, .vertexIndex, .type(shaderModule.types.u32Type), (.vertex, .input)) else {
                return
            }
        case .workgroupId:
            guard
                builtinCase(
                    span,
                    type,
                    stage,
                    direction,
                    .workgroupId,
                    .vector(3, shaderModule.types.u32Type, "vec3<u32>"),
                    (.compute, .input)
                )
            else {
                return
            }
        case .sampleMask:
            guard
                builtinCase(
                    span,
                    type,
                    stage,
                    direction,
                    .sampleMask,
                    .type(shaderModule.types.u32Type),
                    (.fragment, .input),
                    (.fragment, .output)
                )
            else {
                return
            }
        case .position:
            guard
                builtinCase(
                    span,
                    type,
                    stage,
                    direction,
                    .position,
                    .vector(4, shaderModule.types.f32Type, "vec4<f32>"),
                    (.vertex, .output),
                    (.fragment, .input)
                )
            else {
                return
            }
        }

        if !builtins.add(builtin) {
            error(span, "@builtin(\(toString(builtin))) appears multiple times as pipeline input")
        }
    }

    private mutating func validateLocationIO(
        _ span: SourceSpan,
        _ type: TypeID?,
        _ stage: ShaderStage,
        _ location: UInt32,
        _ locations: inout Locations
    ) {
        guard stage != .compute else {
            error(span, "@location cannot be used by compute shaders")
            return
        }

        if !satisfies(type, .number, shaderModule.types) {
            let vector = shaderModule.types.getIf(Types.Vector.self, type)
            guard let vector, satisfies(vector.element, .number, shaderModule.types) else {
                guard let type else {
                    wgslFatal("@location on a declaration without an inferred type", cppSite: "IOValidator.cpp:478")
                }
                error(span, "cannot apply @location to declaration of type '\(ShaderModule.typeString(type, in: &shaderModule))'")
                return
            }
        }

        if !locations.add(UInt64(location)) {
            error(span, "@location(\(location)) appears multiple times")
        }
    }

    private mutating func validateInterpolationIO(
        _ span: SourceSpan,
        _ stage: ShaderStage,
        _ direction: Direction,
        _ type: TypeID?,
        _ interpolation: Interpolation?
    ) {
        guard (stage == .vertex && direction == .output) || (stage == .fragment && direction == .input) else {
            return
        }

        if !satisfies(type, .integer, shaderModule.types) {
            let vector = shaderModule.types.getIf(Types.Vector.self, type)
            guard let vector, satisfies(vector.element, .integer, shaderModule.types) else {
                return
            }
        }

        if interpolation?.type != .flat {
            let location: StaticString = stage == .vertex ? "vertex output" : "fragment input"
            error(span, "integral user-defined \(location) must have a @interpolate(flat) attribute")
        }
    }

    private mutating func validateStructIO(
        _ stage: ShaderStage,
        _ structType: Types.Struct,
        _ direction: Direction,
        _ builtins: inout Builtins,
        _ locations: inout Locations
    ) {
        var members = shaderModule.cursor(shaderModule[structType.structure].members)
        while !members.isAtEnd {
            let member = shaderModule[shaderModule.advance(&members)]
            let span = member.span
            let type = shaderModule.inferredType(of: member.type)

            if let builtin = member.builtin {
                validateBuiltinIO(span, type, stage, builtin, direction, &builtins)
                guard !hasError else {
                    return
                }
                continue
            }

            if let location = member.location {
                validateLocationIO(span, type, stage, location, &locations)
                guard !hasError else {
                    return
                }
                validateInterpolationIO(span, stage, direction, type, member.interpolation)
                guard !hasError else {
                    return
                }
                continue
            }

            if shaderModule.types.getIf(Types.Struct.self, type) != nil {
                error(span, "nested structures cannot be used for entry point IO")
                return
            }

            error(span, "missing entry point IO attribute")
            return
        }
    }

    private mutating func error(_ span: SourceSpan, _ message: MessageText) {
        setError(CompilationMessage(text: message, span: span))
    }

    // MARK: - Swift-only helpers

    /// The C++ TYPE_CHECK and VEC_CHECK macros: the store type a builtin requires.
    private enum StoreTypeCheck {
        case type(TypeID)
        case vector(UInt8, TypeID, StaticString)
    }

    /// The C++ CASE and CASE2 macros: the store type check, then the stages and directions the builtin may be used for.
    private mutating func builtinCase(
        _ span: SourceSpan,
        _ type: TypeID?,
        _ stage: ShaderStage,
        _ direction: Direction,
        _ builtin: Builtin,
        _ storeTypeCheck: StoreTypeCheck,
        _ allowed: (ShaderStage, Direction),
        _ alsoAllowed: (ShaderStage, Direction)? = nil
    ) -> Bool {
        switch storeTypeCheck {
        case .type(let expectedType):
            guard type == expectedType else {
                error(
                    span,
                    "store type of @builtin(\(toString(builtin))) must be '\(ShaderModule.typeString(expectedType, in: &shaderModule))'"
                )
                return false
            }
        case .vector(let size, let element, let spelling):
            guard let vector = shaderModule.types.getIf(Types.Vector.self, type), vector.size == size, vector.element == element else {
                error(span, "store type of @builtin(\(toString(builtin))) must be '\(spelling)'")
                return false
            }
        }

        var isAllowed = stage == allowed.0 && direction == allowed.1
        if let alsoAllowed {
            isAllowed = isAllowed || (stage == alsoAllowed.0 && direction == alsoAllowed.1)
        }
        guard isAllowed else {
            let directionName: StaticString = direction == .input ? "input" : "output"
            error(span, "@builtin(\(toString(builtin))) cannot be used for \(toString(stage)) shader \(directionName)")
            return false
        }
        return true
    }

    private mutating func originalName(_ variable: VariableID) -> MessageText {
        shaderModule.symbols.text(of: shaderModule.symbol(of: shaderModule[variable].originalName))
    }
}

/// The locals of one active C++ `IOValidator::visit(Function&)`.
private struct CalleeLocals {
    var usedGlobals = IDSet<CallGraphGlobalID>()
    var textureSamplerPairs: [CallGraph.TextureSamplerPair] = []
    /// After `.edge`: the callee is being visited, so its record is written back at `.edgeDone`.
    var isVisitingCallee = false
}

private struct VisitedFunction {
    let usedGlobals: IDSet<CallGraphGlobalID>
    let textureSamplerPairs: [CallGraph.TextureSamplerPair]
}

private func appendIfNotContains(_ pairs: [CallGraph.TextureSamplerPair], to destination: inout [CallGraph.TextureSamplerPair]) {
    var index = 0
    while index < pairs.count {
        destination.appendIfNotContains(pairs[index])
        index += 1
    }
}

@_spi(Testing)
public func validateIO(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    var validator = IOValidator(shaderModule: shaderModule)
    validator.validateIO()
    let error = validator.result()
    shaderModule = validator.shaderModule
    guard let error else {
        return nil
    }
    return FailedCheck(errors: [error], warnings: [])
}
