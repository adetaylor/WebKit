// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (C) 2026 Apple Inc. All rights reserved.
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

import Testing
@_spi(Testing) import WGSL

// rewriteEntryPoints (EntryPointRewriter.cpp) inside a CompilationScope, as prepare runs it. Each expected text is what
// the C++ `AST::StringDumper` printed for the same source and entry point map after insertBoundsChecks and
// rewriteEntryPoints; insertBoundsChecks changes nothing in these sources (no index accesses). The
// sources the C++ rejects in staticCheck (an array return type, nested IO structures, @location in a compute shader)
// reach the branches only an unchecked module reaches; their expectations follow EntryPointRewriter.cpp.

// MARK: - Helpers

/// The module after the static passes of WGSL.cpp:100-113, which prepare gets. `ignoringErrors` runs every pass even when
/// one fails.
private func staticPasses(_ source: String, ignoringErrors: Bool, sourceLocation: SourceLocation = #_sourceLocation) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    func check(_ result: FailedCheck?) {
        if !ignoringErrors, let result, !result.errors.isEmpty {
            logCompilationError(result, sourceLocation: sourceLocation)
        }
    }
    check(parse(&module))
    check(reorderGlobals(&module))
    check(typeCheck(&module))
    check(validateAttributes(&module))
    buildCallGraph(&module)
    check(validateIO(&module))
    check(validateVisibility(&module))
    mangleNames(&module)
    rewriteEvaluationOrder(&module)
    rewritePointers(&module)
    check(aliasAnalysis(&module))
    check(uniformityAnalysis(&module))
    return module
}

/// Runs `body` on the compile thread when the module is built with -Onone (TestWGSLAPI.swift).
private func onRewriteThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in body() }
    }
    return body()
}

/// The prepare map, whose keys alone rewriteEntryPoints reads: every call-graph entry point (`@all`) when `entryPoints` is nil.
private func layoutMap(_ module: borrowing ShaderModule, _ entryPoints: [String]?) -> LookupMap<Name, Int?> {
    var layouts = LookupMap<Name, Int?>()
    guard let entryPoints else {
        for entryPoint in module.callGraph.entrypoints {
            layouts.add(module.symbols.name(of: entryPoint.originalName), nil)
        }
        return layouts
    }
    for entryPoint in entryPoints {
        layouts.add(Name(entryPoint), nil)
    }
    return layouts
}

private struct Rewritten: Sendable {
    var before = ""
    var after = ""
    var rolledBack = ""
    var facts: [String] = []
}

/// The dumps before rewriteEntryPoints, after it inside the scope and after the rollback, and `facts` of the rewritten
/// module.
private func rewrite(
    _ source: String,
    entryPoints: [String]? = nil,
    ignoringErrors: Bool = false,
    facts: @escaping @Sendable (borrowing ShaderModule, _ declarationCountBefore: Int) -> [String] = { _, _ in [] }
) -> Rewritten {
    onRewriteThread {
        var module = staticPasses(source, ignoringErrors: ignoringErrors)
        var result = Rewritten()
        result.before = ASTStringDumper.dump(module)
        let layouts = layoutMap(module, entryPoints)
        let declarationCount = module.count(module.declarations)
        ModuleState.withTestScope(&module) { module in
            rewriteEntryPoints(&module, layouts)
            result.after = ASTStringDumper.dump(module)
            result.facts = facts(module, declarationCount)
        }
        result.rolledBack = ASTStringDumper.dump(module)
        return result
    }
}

private func text(_ module: borrowing ShaderModule, _ symbol: Symbol) -> String {
    String(decoding: module.symbols.codeUnits(of: symbol), as: UTF16.self)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    text(module, module.symbol(of: identifier))
}

private func function(_ module: borrowing ShaderModule, _ originalName: String) -> FunctionID? {
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration, text(module, module[function].originalName) == originalName {
            return function
        }
    }
    return nil
}

/// The structures named `name`, in declaration order.
private func structures(_ module: borrowing ShaderModule, _ name: String) -> [StructureID] {
    var result: [StructureID] = []
    for declaration in module.elements(module.declarations) {
        if case .structure(let structure) = declaration, text(module, module[structure].name) == name {
            result.append(structure)
        }
    }
    return result
}

private func spelling(_ builtin: Builtin?) -> String {
    guard let builtin else {
        return "-"
    }
    return String(describing: builtin)
}

/// "name role builtin provenance" for each parameter of the function whose source name is `originalName`.
private func parameterFacts(_ module: borrowing ShaderModule, _ originalName: String) -> [String] {
    guard let function = function(module, originalName) else {
        return ["no function \(originalName)"]
    }
    var result: [String] = []
    for parameter in module.elements(module[function].parameters) {
        let node = module[parameter]
        let provenance = module.symbols.provenance(of: module.symbol(of: node.name))
        result.append("\(text(module, node.name)) \(node.role) \(spelling(node.builtin)) \(provenance)")
    }
    return result
}

/// "name role provenance" for each declaration rewriteEntryPoints appended (every one is a structure).
private func appendedStructureFacts(_ module: borrowing ShaderModule, _ declarationCountBefore: Int) -> [String] {
    var result: [String] = []
    let declarations = module.elements(module.declarations)
    for declaration in declarations[declarationCountBefore...] {
        guard case .structure(let structure) = declaration else {
            result.append("not a structure")
            continue
        }
        let node = module[structure]
        let provenance = module.symbols.provenance(of: module.symbol(of: node.name))
        result.append("\(text(module, node.name)) \(node.role) \(provenance)")
    }
    return result
}

/// The kind of the return type expression of the function whose source name is `originalName`, and the structure its
/// inferred type names.
private func returnTypeFacts(_ module: borrowing ShaderModule, _ originalName: String) -> String {
    guard let function = function(module, originalName), let returnType = module[function].maybeReturnType else {
        return "no return type"
    }
    var description = "\(module[returnType].kind.tag)"
    if case .identityExpression(let identity) = module[returnType].kind {
        description += "(\(module[identity.expression].kind.tag))"
    }
    if let structType = module.types.getIf(Types.Struct.self, module.inferredType(of: returnType)) {
        description += " " + text(module, module[structType.structure].name)
    }
    return description
}

// MARK: - Sources

private let everyStageSource =
    """
    struct VIn {
        @location(0) pos: vec4f,
        @builtin(vertex_index) vi: u32,
        @location(1) uv: vec2f,
    }
    struct VOut {
        @builtin(position) position: vec4f,
        @location(0) color: vec4f,
    }
    @vertex
    fn vs(input: VIn, @builtin(instance_index) ii: u32, @location(2) extra: f32) -> VOut {
        var out: VOut;
        out.position = input.pos + vec4f(f32(input.vi + ii) + extra);
        out.color = vec4f(input.uv, 0, 1);
        return out;
    }
    @fragment
    fn fs(@location(0) color: vec4f, @builtin(front_facing) ff: bool) -> @location(0) vec4f {
        if ff { return color; }
        return vec4f(0);
    }
    @compute @workgroup_size(1)
    fn cs(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
        _ = lid + gid;
    }
    """

private let hoistedBuiltinsSource =
    """
    struct CIn {
        @builtin(local_invocation_id) lid: vec3u,
        @builtin(workgroup_id) wid: vec3u,
    }
    struct CIn2 {
        @builtin(local_invocation_index) index: u32,
    }
    @compute @workgroup_size(1)
    fn first(a: CIn, b: CIn2, @builtin(num_workgroups) n: vec3u) {
        _ = a.lid + a.wid + n + vec3u(b.index);
    }
    @compute @workgroup_size(1)
    fn second(c: CIn2) {
        _ = c.index;
    }
    """

private let outputStructuresSource =
    """
    struct VOut {
        @builtin(position) position: vec4f,
        @location(0) @interpolate(flat) value: u32,
    }
    struct FOut {
        @location(0) color: vec4f,
        @builtin(frag_depth) depth: f32,
    }
    @vertex
    fn vs1() -> VOut {
        return VOut(vec4f(), 1);
    }
    @vertex
    fn vs2(@builtin(vertex_index) vi: u32) -> VOut {
        return VOut(vec4f(), vi);
    }
    @fragment
    fn fs(@location(0) @interpolate(flat) value: u32, @builtin(position) position: vec4f) -> FOut {
        return FOut(vec4f(f32(value)), position.z);
    }
    """

private let wrappedReturnTypesSource =
    """
    alias V = vec4f;
    @vertex
    fn vs() -> @builtin(position) vec4<f32> {
        return vec4<f32>();
    }
    @vertex
    fn vs2() -> @builtin(position) V {
        return V();
    }
    """

/// The C++ rejects it in validateAttributes (`@location` on an array).
private let arrayReturnTypeSource =
    """
    @fragment
    fn main() -> @location(0) array<f32, 4> {
        return array<f32, 4>();
    }
    """

/// The C++ rejects it in validateIO ("nested structures cannot be used for entry point IO").
private let nestedStructuresSource =
    """
    struct Inner {
        @location(0) x: f32,
        @builtin(position) p: vec4f,
    }
    struct Outer {
        inner: Inner,
    }
    @fragment
    fn main(a: Outer) {
        _ = a.inner.x;
    }
    """

/// The C++ rejects it in validateAttributes (`@location` in the compute shader stage).
private let computeInputSource =
    """
    @compute @workgroup_size(1)
    fn main(@location(0) x: f32, @builtin(local_invocation_index) i: u32) {
        _ = x + f32(i);
    }
    """

// MARK: - Tests

@Suite
struct WGSLEntryPointRewriterTests {
    @Test
    func rewritesEveryStage() {
        let expected =
            """
            struct type0 {
                @location(0) field0: vec4f,
                @builtin(vertex_index) field1: u32,
                @location(1) field2: vec2f
            }

            struct type1 {
                @builtin(position) field3: vec4f,
                @location(0) field4: vec4f
            }

            @vertex
            fn function0(
                @builtin(vertex_index) __builtin0: u32
                @builtin(instance_index) parameter1: u32
                __function0_in: __function0_inT
            ) ->  __type1_VertexOutput
            {
                var parameter0: type0;
                parameter0.field0 = __function0_in.field0;
                parameter0.field1 = __builtin0;
                parameter0.field2 = __function0_in.field2;
                var parameter2: f32 = __function0_in.parameter2;
                var local0: type1;
                local0.field3 = parameter0.field0 + vec4f(f32(parameter0.field1 + parameter1) + parameter2);
                local0.field4 = vec4f(parameter0.field2, 0, 1);
                return local0;
            }

            @fragment
            fn function1(
                @builtin(front_facing) parameter4: bool
                __function1_in: __function1_inT
            ) -> @location(0) __function1_FragmentOutput
            {
                var parameter3: vec4f = __function1_in.parameter3;
                if parameter4
                {
                    return parameter3;
                }

                return vec4f(0);
            }

            @compute @workgroup_size(1)
            fn function2(
                @builtin(local_invocation_id) parameter5: vec3u
                @builtin(global_invocation_id) parameter6: vec3u
            )
            {
                _ = parameter5 + parameter6;
            }

            struct __type1_VertexOutput {
                @builtin(position) field3: vec4f,
                @location(0) field4: vec4f
            }

            struct __function0_inT {
                @location(0) field0: vec4f,
                @location(1) field2: vec2f,
                @location(2) parameter2: f32
            }

            struct __function1_FragmentOutput {
                @location(0) __value: __type
            }

            struct __function1_inT {
                @location(0) parameter3: vec4f
            }
            """
        let result = rewrite(everyStageSource) { module, declarationCount in
            parameterFacts(module, "vs") + parameterFacts(module, "fs") + parameterFacts(module, "cs")
                + appendedStructureFacts(module, declarationCount)
                + [returnTypeFacts(module, "vs"), returnTypeFacts(module, "fs"), returnTypeFacts(module, "cs")]
        }
        #expect(result.after == expected + "\n\n")
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "__builtin0 userDefined vertexIndex reserved",
                "parameter1 userDefined instanceIndex mangled",
                "__function0_in stageIn - reserved",
                "parameter4 userDefined frontFacing mangled",
                "__function1_in stageIn - reserved",
                "parameter5 userDefined localInvocationId mangled",
                "parameter6 userDefined globalInvocationId mangled",
                "__type1_VertexOutput vertexOutput reserved",
                "__function0_inT vertexInput reserved",
                "__function1_FragmentOutput fragmentOutputWrapper reserved",
                "__function1_inT fragmentInput reserved",
                "identifierExpression __type1_VertexOutput",
                "identifierExpression __function1_FragmentOutput",
                "no return type",
            ]
        )
    }

    @Test
    func numbersHoistedBuiltinsPerEntryPoint() {
        let expected =
            """
            struct type0 {
                @builtin(local_invocation_id) field0: vec3u,
                @builtin(workgroup_id) field1: vec3u
            }

            struct type1 {
                @builtin(local_invocation_index) field2: u32
            }

            @compute @workgroup_size(1)
            fn function0(
                @builtin(local_invocation_id) __builtin0: vec3u
                @builtin(workgroup_id) __builtin1: vec3u
                @builtin(local_invocation_index) __builtin2: u32
                @builtin(num_workgroups) parameter2: vec3u
            )
            {
                var parameter0: type0;
                parameter0.field0 = __builtin0;
                parameter0.field1 = __builtin1;
                var parameter1: type1;
                parameter1.field2 = __builtin2;
                _ = parameter0.field0 + parameter0.field1 + parameter2 + vec3u(parameter1.field2);
            }

            @compute @workgroup_size(1)
            fn function1(
                @builtin(local_invocation_index) __builtin0: u32
            )
            {
                var parameter3: type1;
                parameter3.field2 = __builtin0;
                _ = parameter3.field2;
            }
            """
        let result = rewrite(hoistedBuiltinsSource) { module, _ in
            var facts = parameterFacts(module, "first") + parameterFacts(module, "second")
            // A hoisted builtin keeps the member's type expression and attributes (C++ `data.type`, `data.attributes`).
            guard let first = function(module, "first"), let structure = structures(module, "type0").first else {
                return facts + ["missing first or type0"]
            }
            let member = module[module.elements(module[structure].members)[0]]
            let parameter = module[module.elements(module[first].parameters)[0]]
            facts.append("shares type \(parameter.typeName == member.type)")
            facts.append("copies attributes \(module.elements(parameter.attributes) == module.elements(member.attributes))")
            facts.append("own attribute list \(parameter.attributes != member.attributes)")
            return facts
        }
        #expect(result.after == expected + "\n\n")
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "__builtin0 userDefined localInvocationId reserved",
                "__builtin1 userDefined workgroupId reserved",
                "__builtin2 userDefined localInvocationIndex reserved",
                "parameter2 userDefined numWorkgroups mangled",
                "__builtin0 userDefined localInvocationIndex reserved",
                "shares type true",
                "copies attributes true",
                "own attribute list true",
            ]
        )
    }

    @Test
    func duplicatesOutputStructuresSharingMemberIDs() {
        let expected =
            """
            struct type0 {
                @builtin(position) field0: vec4f,
                @location(0)  field1: u32
            }

            struct type1 {
                @location(0) field2: vec4f,
                @builtin(frag_depth) field3: f32
            }

            @vertex
            fn function0() ->  __type0_VertexOutput
            {
                return type0(vec4f(), 1);
            }

            @vertex
            fn function1(
                @builtin(vertex_index) parameter0: u32
            ) ->  __type0_VertexOutput
            {
                return type0(vec4f(), parameter0);
            }

            @fragment
            fn function2(
                @builtin(position) parameter2: vec4f
                __function2_in: __function2_inT
            ) ->  __type1_FragmentOutput
            {
                var parameter1: u32 = __function2_in.parameter1;
                return type1(vec4f(f32(parameter1)), parameter2.z);
            }

            struct __type0_VertexOutput {
                @builtin(position) field0: vec4f,
                @location(0)  field1: u32
            }

            struct __type0_VertexOutput {
                @builtin(position) field0: vec4f,
                @location(0)  field1: u32
            }

            struct __type1_FragmentOutput {
                @location(0) field2: vec4f,
                @builtin(frag_depth) field3: f32
            }

            struct __function2_inT {
                @location(0)  parameter1: u32
            }
            """
        let result = rewrite(outputStructuresSource) { module, declarationCount in
            var facts = appendedStructureFacts(module, declarationCount)
            facts += [returnTypeFacts(module, "vs1"), returnTypeFacts(module, "vs2"), returnTypeFacts(module, "fs")]
            for (original, duplicate) in [("type0", "__type0_VertexOutput"), ("type1", "__type1_FragmentOutput")] {
                guard let originalStructure = structures(module, original).first else {
                    facts.append("missing \(original)")
                    continue
                }
                let members = module[originalStructure].members
                for structure in structures(module, duplicate) {
                    let duplicateMembers = module[structure].members
                    facts.append(
                        "\(duplicate) shares members \(module.elements(duplicateMembers) == module.elements(members)) own list \(duplicateMembers != members)"
                    )
                }
            }
            for name in ["vs1", "fs"] {
                if let function = function(module, name), let returnType = module[function].maybeReturnType {
                    facts.append("\(name) evaluation \(module.evaluation(of: returnType).map { "\($0)" } ?? "-")")
                }
            }
            return facts
        }
        #expect(result.after == expected + "\n\n")
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "__type0_VertexOutput vertexOutput reserved",
                "__type0_VertexOutput vertexOutput reserved",
                "__type1_FragmentOutput fragmentOutput reserved",
                "__function2_inT fragmentInput reserved",
                "identifierExpression __type0_VertexOutput",
                "identifierExpression __type0_VertexOutput",
                "identifierExpression __type1_FragmentOutput",
                "__type0_VertexOutput shares members true own list true",
                "__type0_VertexOutput shares members true own list true",
                "__type1_FragmentOutput shares members true own list true",
                "vs1 evaluation constant",
                "fs evaluation constant",
            ]
        )
    }

    @Test
    func rewritesOnlyTheEntryPointsOfTheMap() {
        let expected =
            """
            struct type0 {
                @builtin(position) field0: vec4f,
                @location(0)  field1: u32
            }

            struct type1 {
                @location(0) field2: vec4f,
                @builtin(frag_depth) field3: f32
            }

            @vertex
            fn function0() ->  type0
            {
                return type0(vec4f(), 1);
            }

            @vertex
            fn function1(
                @builtin(vertex_index) parameter0: u32
            ) ->  __type0_VertexOutput
            {
                return type0(vec4f(), parameter0);
            }

            @fragment
            fn function2(
                @builtin(position) parameter2: vec4f
                __function2_in: __function2_inT
            ) ->  __type1_FragmentOutput
            {
                var parameter1: u32 = __function2_in.parameter1;
                return type1(vec4f(f32(parameter1)), parameter2.z);
            }

            struct __type0_VertexOutput {
                @builtin(position) field0: vec4f,
                @location(0)  field1: u32
            }

            struct __type1_FragmentOutput {
                @location(0) field2: vec4f,
                @builtin(frag_depth) field3: f32
            }

            struct __function2_inT {
                @location(0)  parameter1: u32
            }
            """
        let result = rewrite(outputStructuresSource, entryPoints: ["vs2", "fs"])
        #expect(result.after == expected + "\n\n")
        #expect(result.rolledBack == result.before)

        let none = rewrite(outputStructuresSource, entryPoints: ["function0", "missing"])
        #expect(none.after == none.before)
    }

    @Test
    func wrapsNamedAndElaboratedReturnTypes() {
        let expected =
            """
            alias V = vec4f;
            @vertex
            fn function0() -> @builtin(position) __function0_VertexOutput
            {
                return vec4<f32>();
            }

            @vertex
            fn function1() -> @builtin(position) __function1_VertexOutput
            {
                return V();
            }

            struct __function0_VertexOutput {
                @builtin(position) __value: __type
            }

            struct __function1_VertexOutput {
                @builtin(position) __value: __type
            }
            """
        let result = rewrite(wrappedReturnTypesSource) { module, declarationCount in
            var facts = appendedStructureFacts(module, declarationCount)
            facts += [returnTypeFacts(module, "vs"), returnTypeFacts(module, "vs2")]
            guard let function = function(module, "vs"), let wrapper = structures(module, "__function0_VertexOutput").first else {
                return facts + ["missing vs or its wrapper"]
            }
            let member = module[module.elements(module[wrapper].members)[0]]
            let returnAttributes = module[function].returnAttributes
            facts.append("value \(module.symbols.provenance(of: module.symbol(of: member.name)))")
            facts.append("shares return attributes \(module.elements(member.attributes) == module.elements(returnAttributes))")
            facts.append("own attribute list \(member.attributes != returnAttributes)")
            guard case .identifierExpression(let fieldType) = module[member.type].kind else {
                return facts + ["field type is not an identifier"]
            }
            facts.append("type \(module.symbols.provenance(of: module.symbol(of: fieldType.identifier)))")
            let vector = module.types.getIf(Types.Vector.self, module.inferredType(of: member.type))
            facts.append("field type is vec4f \(vector?.size == 4 && vector?.element == module.types.f32Type)")
            return facts
        }
        #expect(result.after == expected + "\n\n")
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "__function0_VertexOutput vertexOutputWrapper reserved",
                "__function1_VertexOutput vertexOutputWrapper reserved",
                "identifierExpression __function0_VertexOutput",
                "identifierExpression __function1_VertexOutput",
                "value reserved",
                "shares return attributes true",
                "own attribute list true",
                "type reserved",
                "field type is vec4f true",
            ]
        )
    }

    @Test
    func wrapsAnArrayReturnTypeInAnIdentityExpression() {
        // EntryPointRewriter.cpp:198 replaces a 96-byte ArrayTypeExpression with a 112-byte IdentifierExpression: overload (3).
        #expect(ShaderModule.replaceWraps(.arrayTypeExpression, .identifierExpression))
        let result = rewrite(arrayReturnTypeSource, ignoringErrors: true) { module, declarationCount in
            appendedStructureFacts(module, declarationCount) + [returnTypeFacts(module, "main")]
        }
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "__function0_FragmentOutput fragmentOutputWrapper reserved",
                "identityExpression(identifierExpression) __function0_FragmentOutput",
            ]
        )
    }

    @Test
    func materializesNestedStructurePaths() {
        let result = rewrite(nestedStructuresSource, ignoringErrors: true) { module, declarationCount in
            parameterFacts(module, "main") + appendedStructureFacts(module, declarationCount)
        }
        #expect(result.after.contains(Self.nestedMaterializations))
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "__builtin0 userDefined position reserved",
                "__function0_in stageIn - reserved",
                "__function0_inT fragmentInput reserved",
            ]
        )
    }

    /// EntryPointRewriter.cpp:288-306 declares a variable per structure on the path and :268-283 assigns through the whole path.
    static let nestedMaterializations = """
        {
            var parameter0: type1;
            var field2: type0;
            parameter0.field2.field0 = __function0_in.field0;
            parameter0.field2.field1 = __builtin0;
            _ = parameter0.field2.field0;
        }
        """

    @Test
    func buildsAComputeInputStructure() {
        let result = rewrite(computeInputSource, ignoringErrors: true) { module, declarationCount in
            parameterFacts(module, "main") + appendedStructureFacts(module, declarationCount)
        }
        #expect(result.after.contains("var parameter0: f32 = __function0_in.parameter0;"))
        #expect(result.rolledBack == result.before)
        #expect(
            result.facts == [
                "parameter1 userDefined localInvocationIndex mangled",
                "__function0_in stageIn - reserved",
                "__function0_inT computeInput reserved",
            ]
        )
    }
}
