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

// The zero-initialization of workgroup variables and the reads of GlobalVariableRewriter (GlobalVariableRewriter.cpp:2534-2905).
// Each expected AST is what the C++ `AST::StringDumper` printed after rewriteGlobalVariables for the same source and layout.

// MARK: - Helpers

/// The module after the static passes (WGSL.cpp:94-113), or nil if one of them failed.
private func staticPasses(_ source: String) -> ShaderModule? {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    func failed(_ result: FailedCheck?) -> Bool {
        result.map { !$0.errors.isEmpty } ?? false
    }
    if failed(parse(&module)) || failed(reorderGlobals(&module)) || failed(typeCheck(&module)) || failed(validateAttributes(&module)) {
        return nil
    }
    buildCallGraph(&module)
    if failed(validateIO(&module)) || failed(validateVisibility(&module)) {
        return nil
    }
    mangleNames(&module)
    rewriteEvaluationOrder(&module)
    rewritePointers(&module)
    if failed(aliasAnalysis(&module)) || failed(uniformityAnalysis(&module)) {
        return nil
    }
    return module
}

private func text(_ module: borrowing ShaderModule, _ symbol: Symbol) -> String {
    String(decoding: module.symbols.codeUnits(of: symbol), as: UTF16.self)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    text(module, module.symbol(of: identifier))
}

/// What the AST of a zero-initialization block contains, in pre-order.
private struct ZeroInitCensus: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    var proofs: [SubscriptProof.Reason] = []
    var unchecked = 0
    /// The index variable of each loop, and whether the loop is internally generated.
    var loops: [String] = []
    var calls: [String] = []

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ access: IndexAccessExpression, _ id: ExpressionID) {
        unchecked += 1
        visitChildren(access, id)
    }

    mutating func visit(_ access: CheckedIndexAccessExpression, _ id: ExpressionID) {
        proofs.append(access.proof.reason)
        visitChildren(access, id)
    }

    mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        var loop = "not a variable"
        if let initializer = statement.maybeInitializer, case .variableStatement(let variableStatement) = shaderModule[initializer].kind {
            loop = text(shaderModule, shaderModule[variableStatement.variable].name)
        }
        loops.append(statement.isInternallyGenerated ? loop : "\(loop) (not internally generated)")
        visitChildren(statement, id)
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        if case .identifierExpression(let callee) = shaderModule[call.target].kind {
            calls.append(text(shaderModule, callee.identifier))
        }
        visitChildren(call, id)
    }
}

private struct Census: Equatable, Sendable {
    var proofs: [SubscriptProof.Reason] = []
    var unchecked = 0
    var loops: [String] = []
    var calls: [String] = []
}

/// What GlobalVariableRewriter made of an entry point's body.
private struct EntryPointFacts: Equatable, Sendable {
    /// The kind of each statement of the body.
    var statements: [StatementKindTag] = []
    /// The callee of the call statement after the `if`.
    var barrier = ""
    /// The text of the test of the `if`, with the inferred type of each operand.
    var test = ""
    var census = Census()
    /// The names of the function's parameters.
    var parameters: [String] = []
    var initialized = false
}

private struct Rewritten: Sendable {
    var error: String?
    var facts: [EntryPointFacts] = []
    var usesZeroWorkgroupVar = false
}

private func typeText(_ module: borrowing ShaderModule, _ expression: ExpressionID) -> String {
    guard let type = module.inferredType(of: expression) else {
        return "untyped"
    }
    return String(decoding: module.typeString(type).codeUnits, as: UTF16.self)
}

/// The census of a zero-initialization block that is one loop nest, taken without recursion: each loop's body is the next loop, and the
/// innermost body is one call whose argument is a chain of index accesses.
private func nestedLoopCensus(_ module: borrowing ShaderModule, _ body: StatementID) -> Census {
    var census = Census()
    var statement = body
    while true {
        guard case .compoundStatement(let compound) = module[statement].kind, module.count(compound.statements) == 1 else {
            census.calls.append("not one statement")
            return census
        }
        let inner = module[compound.statements, 0]
        switch module[inner].kind {
        case .forStatement(let loop):
            var name = "not a variable"
            if let initializer = loop.maybeInitializer, case .variableStatement(let variableStatement) = module[initializer].kind {
                name = text(module, module[variableStatement.variable].name)
            }
            census.loops.append(loop.isInternallyGenerated ? name : "\(name) (not internally generated)")
            statement = loop.body
        case .callStatement(let callStatement):
            guard case .callExpression(let call) = module[callStatement.call].kind, module.count(call.arguments) == 1 else {
                census.calls.append("not a call with one argument")
                return census
            }
            if case .identifierExpression(let callee) = module[call.target].kind {
                census.calls.append(text(module, callee.identifier))
            }
            var expression = module[call.arguments, 0]
            while true {
                switch module[expression].kind {
                case .checkedIndexAccessExpression(let access):
                    census.proofs.append(access.proof.reason)
                    expression = access.base
                case .indexAccessExpression(let access):
                    census.unchecked += 1
                    expression = access.base
                default:
                    return census
                }
            }
        default:
            census.calls.append("unexpected statement")
            return census
        }
    }
}

private func facts(_ module: inout ShaderModule, _ function: FunctionID, initialized: Bool, nestedLoops: Bool) -> EntryPointFacts {
    var result = EntryPointFacts(initialized: initialized)
    for parameter in module.elements(module[function].parameters) {
        result.parameters.append(text(module, module[parameter].name))
    }
    guard case .compoundStatement(let body) = module[module[function].body].kind else {
        return result
    }
    let statements = module.elements(body.statements)
    result.statements = statements.map { module[$0].kind.tag }
    guard let ifIndex = statements.firstIndex(where: { module[$0].kind.tag == .ifStatement }),
        case .ifStatement(let ifStatement) = module[statements[ifIndex]].kind,
        case .binaryExpression(let test) = module[ifStatement.test].kind
    else {
        return result
    }
    if ifIndex + 1 < statements.count, case .callStatement(let callStatement) = module[statements[ifIndex + 1]].kind,
        case .callExpression(let call) = module[callStatement.call].kind,
        case .identifierExpression(let callee) = module[call.target].kind
    {
        result.barrier = text(module, callee.identifier)
    }
    var lhs = "not an identifier"
    if case .identifierExpression(let identifier) = module[test.leftExpression].kind {
        lhs = text(module, identifier.identifier)
    }
    var rhs = "not a literal"
    if case .unsigned32Literal(let literal) = module[test.rightExpression].kind {
        rhs = "\(literal.value)u"
    }
    result.test =
        "\(lhs): \(typeText(module, test.leftExpression)) \(test.operation) \(rhs): \(typeText(module, test.rightExpression))"
        + " -> \(typeText(module, ifStatement.test))"

    if nestedLoops {
        result.census = nestedLoopCensus(module, ifStatement.trueBody)
        return result
    }
    var census = ZeroInitCensus(shaderModule: module)
    census.visit(ifStatement.trueBody)
    module = census.shaderModule
    result.census = Census(proofs: census.proofs, unchecked: census.unchecked, loops: census.loops, calls: census.calls)
    return result
}

/// Runs insertBoundsChecks, rewriteEntryPoints and rewriteGlobalVariables with a default layout for every entry point inside the
/// prepare scope, as prepare does, and collects `EntryPointFacts` for each entry point. `nestedLoops` takes the census of a zeroing
/// block that is one loop nest without recursion, so that it fits the 512 KiB test threads of the -O runner.
private func rewrite(_ source: String, nestedLoops: Bool = false) -> Rewritten {
    onCompileThreadIfNeeded {
        guard var module = staticPasses(source) else {
            return Rewritten(error: "the static passes failed")
        }
        var layouts = LookupMap<Name, Int?>()
        for entryPoint in module.callGraph.entrypoints {
            layouts.add(module.symbols.name(of: entryPoint.originalName), nil)
        }
        let entryPoints = module.callGraph.entrypoints
        var result = Rewritten()
        ModuleState.withTestScope(&module) { module in
            insertBoundsChecks(&module)
            rewriteEntryPoints(&module, layouts)
            var explicitLayouts: [ExplicitPipelineLayout] = []
            var informations = Reflection.EntryPointInformations()
            if let error = rewriteGlobalVariables(&module, layouts, &explicitLayouts, &informations) {
                result.error = String(decoding: error.utf16, as: UTF16.self)
                return
            }
            for entryPoint in entryPoints {
                let information = informations.find(module.symbols.name(of: entryPoint.originalName))
                let initialized = information?.initialized?.function == entryPoint.function
                result.facts.append(facts(&module, entryPoint.function, initialized: initialized, nestedLoops: nestedLoops))
            }
            result.usesZeroWorkgroupVar = module.uses.contains(.zeroWorkgroupVar)
        }
        return result
    }
}

private func onCompileThreadIfNeeded<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in body() }
    }
    return body()
}

private struct Prepared: Sendable {
    var error: String?
    var dump = ""
    var entryPoints: [EntryPointInformation] = []
}

/// prepare of every entry point with a default layout, through the public API.
private func prepare(_ source: String) -> Prepared {
    onCompileThread { scope in
        switch scope.staticCheck(SourceText(source)) {
        case .success(let module):
            return prepared(scope.prepare(module))
        case .failure:
            return Prepared(error: "staticCheck failed")
        }
    }
}

private func prepared(_ outcome: consuming PrepareOutcome) -> Prepared {
    switch consume outcome {
    case .prepared(let prepared):
        let result = Prepared(dump: prepared.dumpAST(), entryPoints: prepared.entryPoints)
        _ = prepared.abandon()
        return result
    case .failed(let error, _):
        return Prepared(error: String(decoding: error.utf16, as: UTF16.self))
    }
}

/// prepare of `entryPoint` with the explicit `layout`, through the public API.
private func prepare(_ source: String, entryPoint: String, layout: PipelineLayout) -> Prepared {
    onCompileThread { scope in
        switch scope.staticCheck(SourceText(source)) {
        case .success(let module):
            var layout = layout
            return prepared(module.prepare(entryPoint: Name(entryPoint), layout: &layout))
        case .failure:
            return Prepared(error: "staticCheck failed")
        }
    }
}

// MARK: - Sources

private let everyKindSource = """
    struct A { a: atomic<u32>, b: array<vec2f, 3>, c: f32 }
    struct B { x: i32, y: vec3f }
    var<workgroup> w0: array<array<i32, 4>, 2>;
    var<workgroup> w1: A;
    var<workgroup> w2: B;
    var<workgroup> w3: atomic<i32>;
    var<workgroup> w4: f32;
    var<private> p0: i32 = 3;
    @compute @workgroup_size(1)
    fn main() {
      w0[1][2] = p0;
      atomicAdd(&w1.a, 1u);
      w2.x = 2;
      atomicAdd(&w3, 1);
      w4 = 1.0;
    }

    """

private let localInvocationIndexSource = """
    var<workgroup> counter: atomic<u32>;
    var<workgroup> tile: array<vec4f, 2>;
    @compute @workgroup_size(8)
    fn main(@builtin(local_invocation_index) index: u32, @builtin(global_invocation_id) id: vec3u) {
      atomicAdd(&counter, index);
      tile[index % 2] = vec4f(f32(id.x));
    }

    """

private let overrideSizedSource = """
    override n: u32 = 4;
    alias A = array<f32, n>;
    var<workgroup> w: A;
    var<workgroup> v: array<atomic<i32>, n>;
    @compute @workgroup_size(1)
    fn main() {
      w[0] = 1.0;
      atomicStore(&v[1], 2);
    }

    """

private let privateOnlySource = """
    var<private> p: vec2f = vec2f(1, 2);
    var<private> q: i32;
    @compute @workgroup_size(1)
    fn main() {
      q = i32(p.x);
    }
    @compute @workgroup_size(1)
    fn empty() {
    }

    """

private let explicitLayoutSource = """
    @group(0) @binding(0) var<storage, read_write> a: array<u32>;
    @group(0) @binding(1) var<uniform> u: vec4f;
    var<workgroup> w: array<u32, 2>;
    @compute @workgroup_size(1)
    fn main() {
      w[0] = a[0];
      a[1] = w[1] + u32(u.x);
    }

    """

/// A workgroup variable whose type is `depth` arrays nested through aliases, which no single type expression limits.
private func nestedArraySource(depth: Int) -> String {
    var source = "alias A0 = array<u32, 2>;\n"
    for level in 1..<depth {
        source += "alias A\(level) = array<A\(level - 1), 1>;\n"
    }
    source += "var<workgroup> w: A\(depth - 1);\n@compute @workgroup_size(1)\nfn main() {\n  _ = w;\n}\n"
    return source
}

// MARK: - Tests

@Suite
struct WGSLGlobalVariableRewriterInitializationTests {
    // GlobalVariableRewriter.cpp:2534-2826: every used private global is declared at the top of the entry point's body, in reverse
    // order; the workgroup ones are zeroed by invocation 0 before a workgroupBarrier(): arrays by internally generated loops,
    // constructible structures and other types by __wgslZeroWorkgroupVar, atomics by atomicStore, and other structures member by
    // member.
    @Test
    func everyKindOfWorkgroupVariableIsZeroed() {
        let prepared = prepare(everyKindSource)
        #expect(prepared.error == nil)
        #expect(
            prepared.dump == """
                struct type0 {
                    field0: atomic<u32>,
                    field1: array<vec2f, 3>,
                    field2: f32
                }

                struct type1 {
                    field3: i32,
                    field4: vec3f
                }

                var<workgroup,read_write> global0: array<array<i32, 4>, 2>;
                var<workgroup,read_write> global1: type0;
                var<workgroup,read_write> global2: type1;
                var<workgroup,read_write> global3: atomic<i32>;
                var<workgroup,read_write> global4: f32;
                var<private,read_write> global5: i32 = 3;
                @compute @workgroup_size(1)
                fn function0(
                    @builtin(local_invocation_index) __localInvocationIndex: u32
                )
                {
                    var<workgroup,read_write> global4: f32;
                    var<workgroup,read_write> global3: atomic<i32>;
                    var<workgroup,read_write> global2: type1;
                    var<workgroup,read_write> global1: type0;
                    var<private,read_write> global5: i32 = 3;
                    var<workgroup,read_write> global0: array<array<i32, 4>, 2>;
                    if __localInvocationIndex == 0u
                    {
                for (        var __i0 = 0u;;__i0 < 2u;        __i0 += 1u;)        {
                for (            var __i1 = 0u;;__i1 < 4u;            __i1 += 1u;)            {
                __wgslZeroWorkgroupVar(global0[__i0][__i1]);
                            }

                        }

                atomicStore(&global1.field0, 0);
                for (        var __i0 = 0u;;__i0 < 3u;        __i0 += 1u;)        {
                __wgslZeroWorkgroupVar(global1.field1[__i0]);
                        }

                __wgslZeroWorkgroupVar(global1.field2);
                __wgslZeroWorkgroupVar(global2);
                atomicStore(&global3, 0);
                __wgslZeroWorkgroupVar(global4);
                    }

                workgroupBarrier();
                    global0[1][2] = global5;
                atomicAdd(&global1.field0, 1u);
                    global2.field3 = 2;
                atomicAdd(&global3, 1);
                    global4 = 1.000000;
                }
                """ + "\n\n"
        )
        #expect(prepared.entryPoints.map(\.sizeForWorkgroupVariables) == [144])
    }

    // GlobalVariableRewriter.cpp:2546-2588: the `if` and the barrier are both inserted at the offset after the local definitions, so
    // the `if` precedes the barrier; testRhs is left untyped and testLhs typed twice (GlobalVariableRewriter.cpp:2562-2563). The loop
    // accesses are CheckedIndexAccessExpressions whose proof is the loop's induction, and the loops are internally generated.
    @Test
    func zeroingPrecedesTheBarrierAndIndexesThroughLoopInductionProofs() {
        let rewritten = rewrite(everyKindSource)
        #expect(rewritten.error == nil)
        #expect(
            rewritten.facts == [
                EntryPointFacts(
                    statements: [
                        .variableStatement, .variableStatement, .variableStatement, .variableStatement, .variableStatement,
                        .variableStatement, .ifStatement, .callStatement, .assignmentStatement, .callStatement, .assignmentStatement,
                        .callStatement, .assignmentStatement,
                    ],
                    barrier: "workgroupBarrier",
                    test: "__localInvocationIndex: u32 equal 0u: untyped -> bool",
                    census: Census(
                        proofs: [.loopInduction, .loopInduction, .loopInduction],
                        unchecked: 0,
                        loops: ["__i0", "__i1", "__i0"],
                        calls: [
                            "__wgslZeroWorkgroupVar", "atomicStore", "__wgslZeroWorkgroupVar", "__wgslZeroWorkgroupVar",
                            "__wgslZeroWorkgroupVar", "atomicStore", "__wgslZeroWorkgroupVar",
                        ]
                    ),
                    parameters: ["__localInvocationIndex"],
                    initialized: true
                )
            ]
        )
        #expect(rewritten.usesZeroWorkgroupVar)
    }

    // GlobalVariableRewriter.cpp:2609-2613: an existing @builtin(local_invocation_index) parameter is the `if`'s test; none is added.
    @Test
    func anExistingLocalInvocationIndexParameterIsReused() {
        let prepared = prepare(localInvocationIndexSource)
        #expect(prepared.error == nil)
        #expect(
            prepared.dump == """
                var<workgroup,read_write> global0: atomic<u32>;
                var<workgroup,read_write> global1: array<vec4f, 2>;
                @compute @workgroup_size(8)
                fn function0(
                    @builtin(local_invocation_index) parameter0: u32
                    @builtin(global_invocation_id) parameter1: vec3u
                )
                {
                    var<workgroup,read_write> global1: array<vec4f, 2>;
                    var<workgroup,read_write> global0: atomic<u32>;
                    if parameter0 == 0u
                    {
                atomicStore(&global0, 0);
                for (        var __i0 = 0u;;__i0 < 2u;        __i0 += 1u;)        {
                __wgslZeroWorkgroupVar(global1[__i0]);
                        }

                    }

                workgroupBarrier();
                atomicAdd(&global0, parameter0);
                    global1[parameter0 % 2] = vec4f(f32(parameter1.x));
                }
                """ + "\n\n"
        )

        let rewritten = rewrite(localInvocationIndexSource)
        #expect(rewritten.facts.map(\.parameters) == [["parameter0", "parameter1"]])
        #expect(rewritten.facts.map(\.test) == ["parameter0: u32 equal 0u: untyped -> bool"])
    }

    // GlobalVariableRewriter.cpp:2715-2725: the loop over an override-sized array runs to the override expression of its type.
    // GlobalVariableRewriter.cpp:2860-2884: the override that the aliased type names is a read of the entry point, so it is one of its
    // specialization constants.
    @Test
    func overrideSizedArraysLoopToTheOverrideAndTheOverrideIsRead() {
        let prepared = prepare(overrideSizedSource)
        #expect(prepared.error == nil)
        #expect(
            prepared.dump == """
                var global0: u32 = 4;
                alias A = array<f32, global0>;
                var<workgroup,read_write> global1: A;
                var<workgroup,read_write> global2: array<atomic<i32>, global0>;
                @compute @workgroup_size(1)
                fn function0(
                    @builtin(local_invocation_index) __localInvocationIndex: u32
                )
                {
                    var<workgroup,read_write> global2: array<atomic<i32>, global0>;
                    var<workgroup,read_write> global1: A;
                    if __localInvocationIndex == 0u
                    {
                for (        var __i0 = 0u;;__i0 < global0;        __i0 += 1u;)        {
                __wgslZeroWorkgroupVar(global1[__i0]);
                        }

                for (        var __i0 = 0u;;__i0 < global0;        __i0 += 1u;)        {
                atomicStore(&global2[__i0], 0);
                        }

                    }

                workgroupBarrier();
                    global1[0] = 1.000000;
                atomicStore(&global2[1], 2);
                }
                """ + "\n\n"
        )
        #expect(prepared.entryPoints.map { $0.specializationConstants.map(\.key) } == [[Name("n")]])
    }

    // GlobalVariableRewriter.cpp:2865-2884: an override that only an aliased type names is still read, through the resolved type.
    @Test
    func anOverrideOnlyAnAliasedTypeNamesIsRead() {
        let prepared = prepare(
            """
            override n: u32 = 4;
            alias A = array<f32, n>;
            var<workgroup> w: A;
            @compute @workgroup_size(1)
            fn main() {
              w[0] = 1.0;
            }

            """
        )
        #expect(prepared.error == nil)
        #expect(prepared.entryPoints.map { $0.specializationConstants.map(\.key) } == [[Name("n")]])
        #expect(prepared.entryPoints.map { $0.specializationConstants.map(\.mangledName) } == [["global0"]])
    }

    // GlobalVariableRewriter.cpp:2546-2550: without a workgroup variable there is nothing to zero: no `if`, no barrier and no
    // local_invocation_index parameter. An entry point that reads no global is initialized too (GlobalVariableRewriter.cpp:1198).
    @Test
    func entryPointsWithoutWorkgroupVariablesAreInitializedWithoutABarrier() {
        let prepared = prepare(privateOnlySource)
        #expect(prepared.error == nil)
        #expect(
            prepared.dump == """
                var<private,read_write> global0: vec2f = vec2f(1, 2);
                var<private,read_write> global1: i32;
                @compute @workgroup_size(1)
                fn function0()
                {
                    var<private,read_write> global0: vec2f = vec2f(1, 2);
                    var<private,read_write> global1: i32;
                    global1 = i32(global0.x);
                }

                @compute @workgroup_size(1)
                fn function1()
                {}
                """ + "\n\n"
        )

        let rewritten = rewrite(privateOnlySource)
        #expect(rewritten.error == nil)
        #expect(
            rewritten.facts == [
                EntryPointFacts(statements: [.variableStatement, .variableStatement, .assignmentStatement], initialized: true),
                EntryPointFacts(initialized: true),
            ]
        )
        #expect(!rewritten.usesZeroWorkgroupVar)
    }

    // GlobalVariableRewriter.cpp:2891-2904: the argument buffer parameter, its structure (numbered by entry point) and the dynamic
    // offsets parameter. The zeroing comes after the local definitions and before the resource materializations.
    @Test
    func argumentBufferAndDynamicOffsetNames() {
        let layout = PipelineLayout(bindGroupLayouts: [
            BindGroupLayout(
                group: 0,
                entries: [
                    BindGroupLayoutEntry(
                        binding: 0,
                        webBinding: 0,
                        visibility: .compute,
                        bindingMember: .buffer(BufferBindingLayout(type: .storage, hasDynamicOffset: true, minBindingSize: 0)),
                        name: "",
                        compute: StageSlots(argumentBufferIndex: 0, argumentBufferSizeIndex: 1, bufferDynamicOffset: 0)
                    ),
                    BindGroupLayoutEntry(
                        binding: 1,
                        webBinding: 1,
                        visibility: .compute,
                        bindingMember: .buffer(BufferBindingLayout(type: .uniform, hasDynamicOffset: false, minBindingSize: 0)),
                        name: "",
                        compute: StageSlots(argumentBufferIndex: 2)
                    ),
                ]
            )
        ])
        let prepared = prepare(explicitLayoutSource, entryPoint: "main", layout: layout)
        #expect(prepared.error == nil)
        #expect(
            prepared.dump == """
                @group(0) @binding(0) var<storage,read_write> global0: array<u32>;
                @group(0) @binding(1) var<uniform,read> global1: vec4f;
                var<workgroup,read_write> global2: array<u32, 2>;
                @compute @workgroup_size(1)
                fn function0(
                    @group(0) __ArgumentBuffer_0: __ArgumentBufferT_0_0
                    @group(8) __DynamicOffsets: u32
                    @builtin(local_invocation_index) __localInvocationIndex: u32
                )
                {
                    var<workgroup,read_write> global2: array<u32, 2>;
                    if __localInvocationIndex == 0u
                    {
                for (        var __i0 = 0u;;__i0 < 2u;        __i0 += 1u;)        {
                __wgslZeroWorkgroupVar(global2[__i0]);
                        }

                    }

                workgroupBarrier();
                    var global1: vec4f& = __ArgumentBuffer_0.global1;
                    var __global0_ArrayLength: u32& = __ArgumentBuffer_0.__global0_ArrayLength;
                    var global0: array<u32>& = __dynamicOffset(__ArgumentBuffer_0.global0, 0u);
                    global2[0] = global0[__wgslMin(u32(0), __global0_ArrayLength / 4u - 1u)];
                    global0[__wgslMin(u32(1), __global0_ArrayLength / 4u - 1u)] = global2[1] + u32(global1.x);
                }

                struct __ArgumentBufferT_0_0 {
                    @binding(0) global0: array<u32>&,
                    @binding(1) __global0_ArrayLength: u32&,
                    @binding(2) global1: vec4f&
                }
                """ + "\n\n"
        )
    }

    // DEV-03: C++ storeInitialValue recurses once per nested array, and aliases nest arrays as deep as the declarations (release C++
    // overflows a 476 KiB stack on this input); the Swift walk is iterative and makes the same loops in the same order.
    @Test
    func DEV_03_deeplyNestedWorkgroupArrayIsZeroedLoopByLoop() {
        let depth = 1000
        let rewritten = rewrite(nestedArraySource(depth: depth), nestedLoops: true)
        #expect(rewritten.error == nil)
        guard let facts = rewritten.facts.first else {
            Issue.record("no entry point")
            return
        }
        #expect(facts.statements == [.variableStatement, .ifStatement, .callStatement, .phonyAssignmentStatement])
        #expect(facts.barrier == "workgroupBarrier")
        #expect(facts.census.loops == (0..<depth).map { "__i\($0)" })
        #expect(facts.census.proofs == Array(repeating: .loopInduction, count: depth))
        #expect(facts.census.unchecked == 0)
        #expect(facts.census.calls == ["__wgslZeroWorkgroupVar"])
        #expect(facts.initialized)
    }
}
