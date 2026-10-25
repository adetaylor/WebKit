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

private func span(_ n: UInt32) -> SourceSpan {
    SourceSpan(line: n, lineOffset: n, offset: n, length: n)
}

private struct SplitMix64 {
    private var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

private let names: [StaticString] = ["n0", "n1", "n2", "n3", "n4", "n5", "n6", "n7"]

private func identifierExpression(_ module: inout ShaderModule, _ name: StaticString, _ n: UInt32, type: TypeID? = nil) -> ExpressionID {
    let identifier = module.makeIdentifier(name, span: span(n))
    let expression = module.constructIdentifierExpression(span: span(n), identifier: identifier)
    module.setInferredType(type, for: expression)
    return expression
}

private func noAttributes(_ module: inout ShaderModule) -> ListID<AttributeID> {
    module.makeEmptyList(AttributeID.self)
}

// The nodes of a small module, built outside any scope (as by the parser and staticCheck):
//
//   diagnostic(off, derivative_uniformity);
//   struct S { a: f32, b: u32 }
//   @group(0) @binding(1) var<uniform> g: S;
//   @must_use fn f(p: i32) -> i32 { let x = p + 1; foo(x, 2); switch x { default: {} } return x; }
//   alias A = f32;
//   const_assert true;
private struct Fixture {
    let structure: StructureID
    let members: ListID<StructureMemberID>
    let memberName: IdentifierID
    let global: VariableID
    let groupAttribute: AttributeID
    let function: FunctionID
    let functionName: IdentifierID
    let parameters: ListID<ParameterID>
    let body: StatementID
    let bodyStatements: ListID<StatementID>
    let binary: ExpressionID
    let reference: ExpressionID
    let call: ExpressionID
    let arguments: ListID<ExpressionID>
    let switchStatement: StatementID
    let clause: SwitchClauseID
    let alias: TypeAliasID
    let assertion: ConstAssertID
}

private func buildFixture(_ module: inout ShaderModule) -> Fixture {
    let directive = module.construct(
        span: span(1),
        .diagnosticDirective(DiagnosticDirective(diagnostic: Diagnostic(severity: .off, triggeringRule: .derivativeUniformity)))
    )
    module.append(module.directives, directive)

    let f32Name = identifierExpression(&module, "f32", 2, type: module.types.f32Type)
    let u32Name = identifierExpression(&module, "u32", 3, type: module.types.u32Type)
    let memberA = module.constructStructureMember(
        span: span(4),
        name: module.makeIdentifier("a"),
        type: f32Name,
        attributes: noAttributes(&module)
    )
    let memberB = module.constructStructureMember(
        span: span(5),
        name: module.makeIdentifier("b"),
        type: u32Name,
        attributes: noAttributes(&module)
    )
    let members = module.makeList([memberA, memberB])
    let structure = module.constructStructure(span: span(6), name: module.makeIdentifier("S"), members: members, role: .userDefined)
    let structType = module.types.structType(structure)
    module.modify(structure) {
        $0.inferredType = structType
        $0.size = 8
        $0.alignment = 4
    }
    module.append(module.declarations, .structure(structure))

    let zero = module.construct(span: span(7), AbstractIntegerLiteral(value: 0))
    module.setConstantValue(.int64(0), for: zero)
    let one = module.construct(span: span(8), AbstractIntegerLiteral(value: 1))
    module.setConstantValue(.int64(1), for: one)
    let groupAttribute = module.construct(span: span(9), .groupAttribute(GroupAttribute(group: zero)))
    let bindingAttribute = module.construct(span: span(10), .bindingAttribute(BindingAttribute(binding: one)))
    let global = module.constructVariable(
        span: span(11),
        flavor: .var,
        name: module.makeIdentifier("g"),
        qualifier: VariableQualifier(span: span(12), addressSpace: .uniform, accessMode: .read),
        type: identifierExpression(&module, "S", 13, type: structType),
        initializer: nil,
        attributes: module.makeList([groupAttribute, bindingAttribute])
    )
    module.append(module.declarations, .variable(global))

    let parameter = module.constructParameter(
        span: span(14),
        name: module.makeIdentifier("p"),
        typeName: identifierExpression(&module, "i32", 15, type: module.types.i32Type),
        attributes: noAttributes(&module),
        role: .userDefined
    )
    let parameters = module.makeList([parameter])
    let reference = identifierExpression(&module, "p", 16, type: module.types.i32Type)
    let literal = module.construct(span: span(17), Signed32Literal(value: 1))
    module.setConstantValue(.int32(1), for: literal)
    let binary = module.construct(span: span(18), BinaryExpression(leftExpression: reference, rightExpression: literal, operation: .add))
    module.setInferredType(module.types.i32Type, for: binary)
    let x = module.constructVariable(
        span: span(19),
        flavor: .let,
        name: module.makeIdentifier("x"),
        type: nil,
        initializer: binary,
        attributes: noAttributes(&module)
    )
    let arguments = module.makeList([
        identifierExpression(&module, "x", 20), module.construct(span: span(21), AbstractIntegerLiteral(value: 2)),
    ])
    let call = module.construct(span: span(22), CallExpression(target: identifierExpression(&module, "foo", 23), arguments: arguments))
    let emptyBody = module.construct(
        span: span(24),
        CompoundStatement(attributes: noAttributes(&module), statements: module.makeEmptyList(StatementID.self))
    )
    let clause = module.constructSwitchClause(selectors: module.makeEmptyList(ExpressionID.self), body: emptyBody)
    let switchStatement = module.construct(
        span: span(25),
        SwitchStatement(
            attributes: noAttributes(&module),
            value: identifierExpression(&module, "x", 26),
            bodyAttributes: noAttributes(&module),
            clauses: module.makeEmptyList(SwitchClauseID.self),
            defaultClause: clause
        )
    )
    let bodyStatements = module.makeList([
        module.construct(span: span(27), VariableStatement(variable: x)),
        module.constructCallStatement(span: span(28), call: call),
        switchStatement,
        module.construct(span: span(29), ReturnStatement(maybeExpression: identifierExpression(&module, "x", 30))),
    ])
    let body = module.construct(span: span(31), CompoundStatement(attributes: noAttributes(&module), statements: bodyStatements))
    let function = module.constructFunction(
        span: span(32),
        name: module.makeIdentifier("f", span: span(33)),
        parameters: parameters,
        returnType: identifierExpression(&module, "i32", 34, type: module.types.i32Type),
        body: body,
        attributes: module.makeList([module.construct(span: span(35), .mustUseAttribute(MustUseAttribute()))]),
        returnAttributes: noAttributes(&module)
    )
    module.append(module.declarations, .function(function))

    let alias = module.constructTypeAlias(span: span(36), name: module.makeIdentifier("A"), type: identifierExpression(&module, "f32", 37))
    module.append(module.declarations, .typeAlias(alias))
    let test = module.construct(span: span(38), BoolLiteral(value: true))
    module.setConstantValue(.bool(true), for: test)
    let assertion = module.constructConstAssert(span: span(39), test: test)
    module.append(module.declarations, .constAssert(assertion))

    return Fixture(
        structure: structure,
        members: members,
        memberName: module[memberA].name,
        global: global,
        groupAttribute: groupAttribute,
        function: function,
        functionName: module[function].name,
        parameters: parameters,
        body: body,
        bodyStatements: bodyStatements,
        binary: binary,
        reference: reference,
        call: call,
        arguments: arguments,
        switchStatement: switchStatement,
        clause: clause,
        alias: alias,
        assertion: assertion
    )
}

private func makeFixtureModule() -> ShaderModule {
    ShaderModule(source: SourceText("fn f() {}"))
}

private let editKinds = 26

// One of the writes a prepare or generate pass makes: new nodes of every category, logged edits of older nodes and lists,
// replacements, types and override validations. None writes an older slot directly (that would trap).
private func edit(_ module: inout ShaderModule, _ fixture: Fixture, _ kind: Int, _ rng: inout SplitMix64) {
    let name = names[rng.below(names.count)]
    let n = UInt32(truncatingIfNeeded: 1000 + rng.below(1000))
    switch kind {
    case 0:
        let fresh = identifierExpression(&module, name, n, type: module.types.u32Type)
        module.setEvaluation(.runtime, for: fresh)
        module.setConstantValue(.uint32(n), for: fresh)
        module.cacheEvaluatedConstantValue(.uint32(n &+ 1), for: fresh)
    case 1:
        module.replace(fixture.binary, with: identifierExpression(&module, name, n, type: module.types.i32Type))
    case 2:
        let literal = module.construct(span: span(n), Unsigned32Literal(value: n))
        module.setConstantValue(.uint32(n), for: literal)
        module.replace(fixture.reference, with: literal)
    case 3:
        module.modify(fixture.function) {
            $0.mustUse.toggle()
            $0.stage = .compute
        }
    case 4:
        module.modify(fixture.global) {
            $0.role = .packedResource
            $0.group = n
        }
    case 5:
        let target = module.symbols.intern(name)
        module.modify(CallExpression.self, fixture.call) {
            $0.isConstructor = true
            $0.resolvedTarget = target
        }
    case 6:
        module.append(fixture.arguments, identifierExpression(&module, name, n))
    case 7:
        module.insert(fixture.bodyStatements, 0, module.construct(span: span(n), BreakStatement()))
    case 8:
        let parameter = module.constructParameter(
            span: span(n),
            name: module.makeIdentifier(name),
            typeName: identifierExpression(&module, "u32", n),
            attributes: noAttributes(&module),
            role: .bindGroup
        )
        module.insertVector(fixture.parameters, module.count(fixture.parameters), [parameter, parameter])
    case 9:
        if module.count(fixture.bodyStatements) > 0 {
            module.remove(fixture.bodyStatements, 0)
        }
    case 10:
        if module.count(fixture.arguments) > 0 {
            _ = module.takeLast(fixture.arguments)
        }
    case 11:
        module.clear(fixture.members)
    case 12:
        if module.count(fixture.arguments) > 0 {
            module.set(fixture.arguments, 0, module.construct(span: span(n), BoolLiteral(value: false)))
        }
    case 13:
        let symbol = module.symbols.intern(name)
        module.replace(fixture.functionName, keepingSpanWith: symbol)
    case 14:
        let packed = module.constructStructure(
            span: span(n),
            name: module.makeIdentifier(name),
            members: fixture.members,
            role: .packedResource,
            original: fixture.structure
        )
        module.append(module.declarations, .structure(packed))
    case 15:
        let vector = module.types.vectorType(UInt8(2 + rng.below(3)), module.types.f32Type)
        _ = module.types.arrayType(vector, .creationFixed(n))
    case 16:
        module.addOverrideValidationForTesting(ensuringOverrideValueOf: fixture.binary, guards: [fixture.call])
    case 17:
        module.modify(fixture.structure) { $0.size = n }
    case 18:
        module.modify(fixture.body) { $0.span = span(n) }
    case 19:
        module.modify(SwitchStatement.self, fixture.switchStatement) { $0.isInsideLoop = true }
    case 20:
        let body = module.construct(
            span: span(n),
            CompoundStatement(attributes: noAttributes(&module), statements: module.makeEmptyList(StatementID.self))
        )
        let function = module.constructFunction(
            span: span(n),
            name: module.makeIdentifier(name),
            parameters: module.makeEmptyList(ParameterID.self),
            returnType: nil,
            body: body,
            attributes: noAttributes(&module),
            returnAttributes: noAttributes(&module)
        )
        module.insert(module.declarations, 0, .function(function))
    case 21:
        module.uses.insert(UsesFlags(rawValue: 1 << UInt32(rng.below(28))))
    case 22:
        let symbol = module.symbols.intern(name)
        module.replace(fixture.memberName, with: Identifier(span: span(n), symbol: symbol))
    case 23:
        module.modify(fixture.groupAttribute) { $0.span = span(n) }
    case 24:
        let type = identifierExpression(&module, name, n)
        let structure = module.constructStructure(
            span: span(n),
            name: module.makeIdentifier(name),
            members: module.makeEmptyList(StructureMemberID.self),
            role: .vertexOutput
        )
        _ = module.types.structType(structure)
        let member = module.constructStructureMember(
            span: span(n),
            name: module.makeIdentifier(name),
            type: type,
            attributes: noAttributes(&module)
        )
        module.append(fixture.members, member)
        module.modify(member) { $0.offset = n }
    default:
        module.modify(fixture.clause) { _ in }
        module.modify(fixture.alias) { _ in }
        module.modify(fixture.assertion) { _ in }
        let variable = module.constructVariable(
            span: span(n),
            flavor: .override,
            name: module.makeIdentifier(name),
            type: identifierExpression(&module, "f32", n, type: module.types.f32Type),
            initializer: nil,
            attributes: noAttributes(&module)
        )
        module.modify(variable) { $0.id = n }
        _ = module.constructTypeAlias(span: span(n), name: module.makeIdentifier(name), type: identifierExpression(&module, name, n))
        _ = module.constructConstAssert(span: span(n), test: module.construct(span: span(n), BoolLiteral(value: true)))
        _ = module.construct(span: span(n), .mustUseAttribute(MustUseAttribute()))
    }
}

private func randomEdits(_ module: inout ShaderModule, _ fixture: Fixture, _ count: Int, _ rng: inout SplitMix64) {
    var index = 0
    while index < count {
        edit(&module, fixture, rng.below(editKinds), &rng)
        index += 1
    }
}

private func check(_ module: consuming ShaderModule) -> ModuleState {
    switch ModuleState.staticCheck(module, passes: { _ in .success(warnings: [], entryPoints: []) }) {
    case .checked(let state):
        return state
    case .failed:
        fatalError("the fixture failed staticCheck")
    }
}

private struct Cycle: ~Copyable {
    var module: ModuleState
    var prepared: Bool
    var generated: ShaderModuleSnapshot?
}

// One C++ pipeline creation: prepare (a scope with random edits), then generate (a nested scope with more edits),
// which hands back the module with both scopes rolled back.
private func prepareAndGenerate(_ state: consuming ModuleState, _ fixture: Fixture, seed: UInt64, failPrepare: Bool = false) -> Cycle {
    let step = state.prepare { module -> Result<Int, CompilationMessage> in
        var rng = SplitMix64(seed)
        randomEdits(&module, fixture, 40, &rng)
        guard !failPrepare else {
            return .failure(CompilationMessage("prepare failed", span: .empty))
        }
        return .success(module.expressionCount)
    }
    switch consume step {
    case .prepared(let prepared, _):
        let generation = prepared.generate { module -> Result<ShaderModuleSnapshot, CompilationMessage> in
            var rng = SplitMix64(seed &+ 1)
            randomEdits(&module, fixture, 40, &rng)
            return .success(module.snapshot())
        }
        let output = try? generation.result.get()
        return Cycle(module: generation.takeModule(), prepared: true, generated: output)
    case .failed(let module, _):
        return Cycle(module: module, prepared: false, generated: nil)
    }
}

@Suite
struct WGSLRollbackTests {
    @Test
    func everyKindOfEditIsRolledBack() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        let before = module.snapshot()
        var kind = 0
        while kind < editKinds {
            var rng = SplitMix64(UInt64(kind))
            ModuleState.withTestScope(&module) { module in
                let start = module.snapshot()
                edit(&module, fixture, kind, &rng)
                #expect(module.isInCompilationScope == true)
                // Kind 21 sets a `uses` flag, which the snapshot excludes.
                #expect((module.snapshot() != start) == (kind != 21), "edit \(kind)")
            }
            #expect(module.snapshot() == before, "edit \(kind)")
            #expect(module.isInCompilationScope == false)
            kind += 1
        }
    }

    // IRBench-style rewrite cycles: each scope's random edits are undone exactly, and nothing grows across cycles.
    @Test
    func randomRewriteCyclesRestoreTheModule() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        let before = module.snapshot()
        let counts = [
            module.expressionCount, module.statementCount, module.identifierCount, module.listCount, module.listPoolCount,
            module.types.count,
        ]
        var rng = SplitMix64(0x5EED)
        var cycle = 0
        while cycle < 300 {
            let editCount = 1 + rng.below(60)
            ModuleState.withTestScope(&module) { module in
                randomEdits(&module, fixture, editCount, &rng)
            }
            #expect(module.snapshot() == before, "cycle \(cycle)")
            #expect(module.undoEntryCount == 0)
            #expect(module.currentOverrideValidationsSize == 0)
            cycle += 1
        }
        #expect(
            [
                module.expressionCount, module.statementCount, module.identifierCount, module.listCount, module.listPoolCount,
                module.types.count,
            ]
                == counts
        )
    }

    // An inner scope rolls back to the state its outer scope had when it opened, including logged writes to nodes the
    // outer scope created; the outer rollback then restores the module.
    @Test
    func nestedScopesRollBackInnermostFirst() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        let before = module.snapshot()
        var rng = SplitMix64(7)
        ModuleState.withTestScope(&module) { module in
            randomEdits(&module, fixture, 50, &rng)
            let outerNode = identifierExpression(&module, "outer", 500, type: module.types.f32Type)
            let outerList = module.makeList([outerNode])
            let outerState = module.snapshot()
            ModuleState.withTestScope(&module) { module in
                randomEdits(&module, fixture, 50, &rng)
                module.modify(outerNode) { $0.span = span(501) }
                module.replace(outerNode, with: identifierExpression(&module, "inner", 502))
                module.append(outerList, outerNode)
                module.clear(outerList)
                #expect(module.span(of: outerNode) == span(502))
            }
            #expect(module.snapshot() == outerState)
            #expect(module.span(of: outerNode) == span(500))
            #expect(module.count(outerList) == 1)
        }
        #expect(module.snapshot() == before)
    }

    // The evaluate() cache (WGSL.cpp:361) survives the rollback of a scope the node predates, exactly as in C++.
    @Test
    func evaluateCacheFollowsTheCxxRules() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        let before = module.snapshot()
        let old = fixture.binary
        let index = Int(old.raw)

        // S1: a cache write on an untouched older node survives.
        ModuleState.withTestScope(&module) { module in
            module.cacheEvaluatedConstantValue(.int32(5), for: old)
        }
        var expected = before.constantValues
        expected[index] = .int32(5)
        #expect(module.snapshot().nodes == before.nodes)
        #expect(module.snapshot().constantValues == expected)

        // S2: replace, then cache, then rollback: the undo restores the pre-replace slot, which had the S1 cache.
        ModuleState.withTestScope(&module) { module in
            module.replace(old, with: identifierExpression(&module, "r", 600))
            module.cacheEvaluatedConstantValue(.int32(6), for: old)
            #expect(module.constantValue(of: old) == .int32(6))
        }
        #expect(module.constantValue(of: old) == .int32(5))

        // S3: cache, then replace, then rollback: the undo restores the cached value.
        ModuleState.withTestScope(&module) { module in
            module.cacheEvaluatedConstantValue(.int32(7), for: old)
            module.replace(old, with: identifierExpression(&module, "r", 601))
        }
        #expect(module.constantValue(of: old) == .int32(7))
        #expect(module.snapshot().nodes == before.nodes)

        // S4: a node created in a scope dies with it, and the next node with its ID inherits nothing.
        var recycled: ExpressionID?
        ModuleState.withTestScope(&module) { module in
            let fresh = identifierExpression(&module, "r", 602)
            module.cacheEvaluatedConstantValue(.int32(8), for: fresh)
            recycled = fresh
        }
        ModuleState.withTestScope(&module) { module in
            let again = identifierExpression(&module, "r", 603)
            #expect(again == recycled)
            #expect(module.constantValue(of: again) == nil)
        }

        // S5: a node of the outer scope cached in an inner scope keeps the value until the outer rollback.
        ModuleState.withTestScope(&module) { module in
            let outer = identifierExpression(&module, "r", 604)
            ModuleState.withTestScope(&module) { module in
                module.cacheEvaluatedConstantValue(.int32(9), for: outer)
            }
            #expect(module.constantValue(of: outer) == .int32(9))
        }
        #expect(module.snapshot().nodes == before.nodes)
        #expect(module.snapshot().constantValues == expected.enumerated().map { $0.offset == index ? .int32(7) : $0.element })
    }

    // staticCheck -> prepare -> generate hands back a module equal to the checked one; so do a failed prepare and an
    // abandoned prepared module.
    @Test
    func theTypestateRollsBackPrepareAndGenerate() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        let checked = module.snapshot()
        var state = check(module)

        var cycle = prepareAndGenerate(state, fixture, seed: 1)
        #expect(cycle.prepared == true)
        #expect(cycle.generated != nil)
        #expect(cycle.generated?.nodes != checked.nodes)
        #expect(cycle.module.shaderModule.snapshot() == checked)
        #expect(cycle.module.shaderModule.isInCompilationScope == false)

        cycle = prepareAndGenerate(cycle.module, fixture, seed: 2, failPrepare: true)
        #expect(cycle.prepared == false)
        #expect(cycle.module.shaderModule.snapshot() == checked)

        state = cycle.module
        switch state.prepare({ module -> Result<Void, CompilationMessage> in
            var rng = SplitMix64(3)
            randomEdits(&module, fixture, 40, &rng)
            return .success(())
        }) {
        case .prepared(let prepared, _):
            #expect(prepared.shaderModule.isInCompilationScope == true)
            let abandoned = prepared.rollBack()
            #expect(abandoned.shaderModule.snapshot() == checked)
        case .failed:
            Issue.record("prepare failed")
        }
    }

    // Pipelines created one after the other from one module see the same module (C++ RepeatedGenerationIsDeterministic).
    @Test
    func RepeatedGenerationIsDeterministic() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        let checked = module.snapshot()
        var cycle = prepareAndGenerate(check(module), fixture, seed: 42)
        let first = cycle.generated
        #expect(first != nil)
        var index = 0
        while index < 5 {
            cycle = prepareAndGenerate(cycle.module, fixture, seed: 42)
            #expect(cycle.generated == first)
            #expect(cycle.module.shaderModule.snapshot() == checked)
            index += 1
        }
    }

    // The m_uses* flags are set in prepare and cleared by the writer, and never rolled back.
    @Test
    func theUsesFlagsAreStickyAndDistinct() {
        let all: [UsesFlags] = [
            .externalTextures, .packArray, .unpackArray, .packVector, .unpackVector, .workgroupUniformLoad,
            .workgroupUniformLoadAtomic, .division, .modulo, .frexp, .modf, .atomicCompareExchange, .fragDepth, .dot,
            .firstLeadingBit, .firstTrailingBit, .sign, .sampleMask, .frontFacing, .sampleIndex, .dot4I8Packed, .dot4U8Packed,
            .extractBits, .packedVec3, .min, .ftoi, .insertBits, .zeroWorkgroupVar,
        ]
        var union = UsesFlags()
        for flag in all {
            #expect(flag.rawValue.nonzeroBitCount == 1)
            #expect(!union.contains(flag))
            union.formUnion(flag)
        }
        #expect(union.rawValue.nonzeroBitCount == 28)

        var module = makeFixtureModule()
        _ = buildFixture(&module)
        ModuleState.withTestScope(&module) { module in
            module.uses.insert(.packArray)
            module.uses.insert(.min)
        }
        #expect(module.uses == [.packArray, .min])
        module.uses.remove(.packArray)
        #expect(module.uses == [.min])
    }

    // The staticCheck-only state is written outside any scope and read everywhere; interning is never rolled back.
    @Test
    func staticCheckStateAndSymbolsOutliveScopes() {
        var module = ShaderModule(source: SourceText(""), configuration: Configuration(supportedFeatures: [.shaderF16]))
        let fixture = buildFixture(&module)
        module.enableExtension(.f16)
        module.addRequiredFeature(.pointerCompositeAccess)
        module.addOverrideID(4_294_967_295)
        module.addOverride(fixture.global)
        module.setSeverityFor(.subgroupUniformity, .warning)
        #expect(module.hasFeature(.shaderF16) == true)
        #expect(module.hasFeature(.subgroups) == false)
        let before = module.snapshot()
        let symbolCount = module.symbols.count

        var interned: Symbol?
        ModuleState.withTestScope(&module) { module in
            interned = module.symbols.intern("onlyInTheScope")
            #expect(module.enabledExtensions == [.f16])
        }
        #expect(module.snapshot() == before)
        #expect(module.symbols.count == symbolCount + 1)
        let again = module.symbols.intern("onlyInTheScope")
        #expect(again == interned)
        #expect(module.enabledExtensions == [.f16])
        #expect(module.requiredFeatures == [.pointerCompositeAccess])
        #expect(module.containsOverrideID(4_294_967_295) == true)
        #expect(module.containsOverrideID(0) == false)
        #expect(module.overrides == [fixture.global])
        #expect(module.severityFor(.subgroupUniformity) == .warning)
        #expect(module.severityFor(.derivativeUniformity) == nil)
    }

    // DEV-07: C++ revertReplacements(0) underflows when the scope opened on an empty replacement log; Swift restores the
    // module.
    @Test
    func DEV_07_rollbackOfAScopeOpenedOnAnEmptyLog() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        #expect(module.undoEntryCount == 0)
        let before = module.snapshot()
        ModuleState.withTestScope(&module) { module in
            var rng = SplitMix64(9)
            edit(&module, fixture, 1, &rng)
            edit(&module, fixture, 2, &rng)
            #expect(module.undoEntryCount > 0)
        }
        #expect(module.snapshot() == before)
    }

    // DEV-17: C++ leaves the original structure's m_packed pointing at the freed packed structure; Swift undoes it.
    @Test
    func DEV_17_packedBackLinkIsUndone() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        ModuleState.withTestScope(&module) { module in
            let packed = module.constructStructure(
                span: span(700),
                name: module.makeIdentifier("S_packed"),
                members: fixture.members,
                role: .packedResource,
                original: fixture.structure
            )
            #expect(module[fixture.structure].packed == packed)
            #expect(module[packed].original == fixture.structure)
            #expect(module[packed].size == 8)
            #expect(module[packed].alignment == 4)
        }
        #expect(module[fixture.structure].packed == nil)
    }

    // DEV-19: C++ records an undo closure for every staticCheck replacement and keeps it forever; Swift logs only
    // inside a scope.
    @Test
    func DEV_19_noUndoIsRecordedOutsideAScope() {
        var module = makeFixtureModule()
        let fixture = buildFixture(&module)
        var rng = SplitMix64(11)
        var kind = 0
        while kind < editKinds {
            edit(&module, fixture, kind, &rng)
            kind += 1
        }
        #expect(module.undoEntryCount == 0)
        ModuleState.withTestScope(&module) { module in
            let g = module.symbols.intern("g")
            module.replace(fixture.functionName, keepingSpanWith: g)
            #expect(module.undoEntryCount == 1)
        }
        #expect(module.undoEntryCount == 0)
    }
}

// MARK: - The real passes

// The C++ WGSLMetalGenerationTests.RepeatedGenerationIsDeterministic shader.
private let vertexShader = """
    @vertex
    fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
        var positions = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
        return vec4<f32>(positions[i], 0.0, 1.0);
    }
    """

// Overrides with and without defaults and @id, an override-sized workgroup array, a runtime-sized array, bounds checks.
private let computeShader = """
    override blockSize: u32 = 64;
    @id(7) override scale: f32 = 2.0;
    override rows: u32;
    var<workgroup> tile: array<f32, blockSize>;
    @group(0) @binding(0) var<storage, read_write> data: array<f32>;
    @group(0) @binding(1) var<uniform> params: vec4<u32>;

    @compute @workgroup_size(blockSize, 2)
    fn main(@builtin(local_invocation_index) index: u32, @builtin(global_invocation_id) id: vec3<u32>) {
        tile[index % blockSize] = data[id.x] * scale;
        workgroupBarrier();
        data[id.x + params.x] = tile[(index + 1) % blockSize] + f32(rows);
    }
    """

private let fragmentShader = """
    @group(0) @binding(0) var t: texture_2d<f32>;
    @group(0) @binding(1) var s: sampler;
    struct Out {
        @location(0) color: vec4f,
        @builtin(frag_depth) depth: f32,
    }

    @fragment
    fn main(@location(0) uv: vec2f) -> Out {
        var out: Out;
        out.color = textureSample(t, s, uv);
        out.depth = 0.5;
        return out;
    }
    """

private let constantsA = [PipelineConstant(key: Name("blockSize"), value: 8), PipelineConstant(key: Name("rows"), value: 1)]
private let constantsB = [
    PipelineConstant(key: Name("blockSize"), value: 16), PipelineConstant(key: Name("rows"), value: 2),
    PipelineConstant(key: Name("7"), value: 0.5),
]

private struct Generation: Equatable, Sendable {
    var msl: String
    var resolvedOverrides: ResolvedOverrides
    var workgroupSize: WorkgroupSizeEvaluation?
}

/// What the pipeline-creation sequence did to the module.
private struct Pipelines: Sendable {
    var generations: [Generation] = []
    var failures: [String] = []
    /// After each pipeline, the module equals the checked one, except for the evaluate() cache entries that were empty.
    var nodesAreRestored = true
    var constantsOnlyGainCachedValues = true
    /// After each pipeline, the module equals the one after the first pipeline.
    var laterPipelinesLeaveTheModuleUnchanged = true
    /// After each pipeline, the module equals the checked one exactly.
    var moduleIsRestored = true
}

private func onlyCachedValuesAdded(_ before: ShaderModuleSnapshot, _ after: ShaderModuleSnapshot) -> Bool {
    guard before.constantValues.count == after.constantValues.count else {
        return false
    }
    return zip(before.constantValues, after.constantValues).allSatisfy { $0 == nil || $0 == $1 }
}

/// Pipeline.mm prepareLibrary and ComputePipeline.mm metalSize, once per constant set, on one checked module.
private func createPipelines(_ source: String, _ constantSets: [[PipelineConstant]]) -> Pipelines {
    onCompileThread { _ in
        var pipelines = Pipelines()
        var module: CheckedModule
        switch staticCheck(SourceText(source), configuration: testsConfiguration) {
        case .success(let checked):
            module = checked
        case .failure(let failedCheck):
            pipelines.failures.append("staticCheck: \(failedCheck.errors.map(\.message))")
            return pipelines
        }
        let checked = module.snapshot()
        var first: ShaderModuleSnapshot?
        for constants in constantSets {
            switch module.compileEntryPoint(Name("main"), constants: constants, deviceState: DeviceState()) {
            case .compiled(let information, let library):
                var generation = Generation(msl: library.msl.string, resolvedOverrides: library.resolvedOverrides)
                if information.typedEntryPoint == .compute {
                    generation.workgroupSize = module.evaluateWorkgroupSize(entryPoint: Name("main"), overrides: library.resolvedOverrides)
                }
                pipelines.generations.append(generation)
            case .prepareFailed(let error):
                pipelines.failures.append("prepare: \(error.message)")
            case .entryPointNotFound:
                pipelines.failures.append("entryPointNotFound")
            case .invalidPipelineConstant:
                pipelines.failures.append("invalidPipelineConstant")
            case .generateFailed(let error):
                pipelines.failures.append("generate: \(error.message)")
            }
            let after = module.snapshot()
            pipelines.nodesAreRestored = pipelines.nodesAreRestored && after.nodes == checked.nodes
            pipelines.constantsOnlyGainCachedValues = pipelines.constantsOnlyGainCachedValues && onlyCachedValuesAdded(checked, after)
            pipelines.moduleIsRestored = pipelines.moduleIsRestored && after == checked
            if let first {
                pipelines.laterPipelinesLeaveTheModuleUnchanged = pipelines.laterPipelinesLeaveTheModuleUnchanged && after == first
            } else {
                first = after
            }
        }
        return pipelines
    }
}

/// Every way out of prepare and generate, each followed by a snapshot of the rolled-back module.
private struct Rollbacks: Sendable {
    var outcomes: [String] = []
    var restored: [Bool] = []
    var nodesRestored: [Bool] = []
    var constantsOnlyGainCachedValues: [Bool] = []
}

private func rollBackEveryWay(_ source: String) -> Rollbacks {
    onCompileThread { _ in
        var rollbacks = Rollbacks()
        var module: CheckedModule
        switch staticCheck(SourceText(source), configuration: testsConfiguration) {
        case .success(let checked):
            module = checked
        case .failure(let failedCheck):
            rollbacks.outcomes.append("staticCheck: \(failedCheck.errors.map(\.message))")
            return rollbacks
        }
        let before = module.snapshot()
        func record(_ outcome: String, _ module: borrowing CheckedModule) {
            let after = module.snapshot()
            rollbacks.outcomes.append(outcome)
            rollbacks.restored.append(after == before)
            rollbacks.nodesRestored.append(after.nodes == before.nodes)
            rollbacks.constantsOnlyGainCachedValues.append(onlyCachedValuesAdded(before, after))
        }

        switch module.prepare(entryPoints: [Name("main")]) {
        case .prepared(let prepared):
            module = prepared.abandon()
            record("abandoned", module)
        case .failed(let error, let rolledBack):
            module = rolledBack
            record("prepare failed: \(error.message)", module)
        }

        var emptyLayout = PipelineLayout()
        switch module.prepare(entryPoint: Name("main"), layout: &emptyLayout) {
        case .prepared(let prepared):
            module = prepared.abandon()
            record("abandoned", module)
        case .failed(let error, let rolledBack):
            module = rolledBack
            record("prepare failed: \(error.message)", module)
        }

        let overrideSets: [[OverrideAssignment]] = [[], [OverrideAssignment(key: Name("rows"), value: .u32(3))]]
        for overrides in overrideSets {
            switch module.prepare(entryPoints: [Name("main")]) {
            case .prepared(let prepared):
                switch prepared.generate(overrides: overrides) {
                case .generated(_, let rolledBack):
                    module = rolledBack
                    record("generated", module)
                case .failed(let error, let rolledBack):
                    module = rolledBack
                    record("generate failed: \(error.message)", module)
                }
            case .failed(let error, let rolledBack):
                module = rolledBack
                record("prepare failed: \(error.message)", module)
            }
        }
        return rollbacks
    }
}

extension WGSLRollbackTests {
    @Suite
    struct RealPasses {
        // C++ WGSLMetalGenerationTests.RepeatedGenerationIsDeterministic, with the module compared after every pipeline too.
        @Test
        func RepeatedGenerationIsDeterministic() {
            for source in [vertexShader, fragmentShader] {
                let pipelines = createPipelines(source, [[], [], []])
                #expect(pipelines.failures.isEmpty, "\(pipelines.failures)")
                #expect(pipelines.generations.count == 3)
                #expect(pipelines.generations.first?.msl.isEmpty == false)
                #expect(pipelines.generations.allSatisfy { $0 == pipelines.generations.first })
                #expect(pipelines.moduleIsRestored)
            }

            let pipelines = createPipelines(computeShader, [constantsA, constantsA, constantsA])
            #expect(pipelines.failures.isEmpty, "\(pipelines.failures)")
            #expect(pipelines.generations.count == 3)
            #expect(pipelines.generations.allSatisfy { $0 == pipelines.generations.first })
            #expect(pipelines.nodesAreRestored)
            #expect(pipelines.constantsOnlyGainCachedValues)
            #expect(pipelines.laterPipelinesLeaveTheModuleUnchanged)
        }

        // The C++ evaluate() cache survives the rollbacks; the workgroup size follows each pipeline's constants.
        @Test
        func constantSetsABA() {
            let pipelines = createPipelines(computeShader, [constantsA, constantsB, constantsA, []])
            #expect(pipelines.failures == ["generate: override rows is used in shader but not provided"])
            guard pipelines.generations.count == 3 else {
                Issue.record("\(pipelines.generations.count) pipelines")
                return
            }
            let a = pipelines.generations[0]
            let b = pipelines.generations[1]
            #expect(pipelines.generations[2] == a)
            #expect(a.msl != b.msl)
            #expect(a.workgroupSize?.width == .value(.u32(8)))
            #expect(a.workgroupSize?.height == .value(.abstractInt(2)))
            #expect(a.workgroupSize?.depth == .absent)
            #expect(a.workgroupSize?.size == WorkgroupExtent(width: 8, height: 2, depth: 1))
            #expect(b.workgroupSize?.size == WorkgroupExtent(width: 16, height: 2, depth: 1))
            #expect(a.resolvedOverrides.count == 3)
            #expect(a.resolvedOverrides.entries.map(\.value) == [.u32(8), .f32(2.0), .u32(1)])
            #expect(b.resolvedOverrides.entries.map(\.value) == [.u32(16), .f32(0.5), .u32(2)])
            #expect(pipelines.nodesAreRestored)
            #expect(pipelines.constantsOnlyGainCachedValues)
        }

        // C++ keeps a key no override has in the map generate() leaves behind (WGSLShaderModule.cpp:46-89).
        @Test
        func resolvedOverridesKeepUnknownKeys() {
            let outcome = onCompileThread { _ -> (entries: [ResolvedOverride], mangledNames: [String])? in
                switch staticCheck(SourceText(computeShader), configuration: testsConfiguration) {
                case .success(let module):
                    switch module.prepare(entryPoints: [Name("main")]) {
                    case .prepared(let prepared):
                        let mangledNames = prepared.entryPoint(named: Name("main"))?.specializationConstants.map(\.mangledName) ?? []
                        let overrides = [
                            OverrideAssignment(key: Name("unknown"), value: .bool(true)),
                            OverrideAssignment(key: Name("rows"), value: .u32(5)),
                            OverrideAssignment(key: Name("unknown"), value: .bool(false)),
                        ]
                        switch prepared.generate(overrides: overrides) {
                        case .generated(let library, _):
                            return (library.resolvedOverrides.entries, mangledNames)
                        case .failed:
                            return nil
                        }
                    case .failed:
                        return nil
                    }
                case .failure:
                    return nil
                }
            }
            guard let outcome else {
                Issue.record("the compilation failed")
                return
            }
            #expect(outcome.entries.count == 4)
            #expect(outcome.entries.first == ResolvedOverride(name: Name("unknown"), value: .bool(false)))
            #expect(outcome.entries.dropFirst().map(\.name.description).sorted() == outcome.mangledNames.sorted())
            #expect(outcome.entries.contains { $0.value == .u32(5) })
        }

        // A failed generate leaves the caller's map as validateOverrides left it: here the defaults it evaluated before the override
        // without one.
        @Test
        func resolvedOverridesAfterAFailedGenerate() {
            let outcome = onCompileThread { _ -> (message: String, entries: [ResolvedOverride])? in
                switch staticCheck(SourceText(computeShader), configuration: testsConfiguration) {
                case .success(let module):
                    switch module.prepare(entryPoints: [Name("main")]) {
                    case .prepared(let prepared):
                        var resolvedOverrides = ResolvedOverrides([])
                        let overrides = [OverrideAssignment(key: Name("unknown"), value: .i32(-1))]
                        switch prepared.generate(overrides: overrides, deviceState: DeviceState(), resolvedOverrides: &resolvedOverrides) {
                        case .generated:
                            return nil
                        case .failed(let error, _):
                            return (error.message, resolvedOverrides.entries)
                        }
                    case .failed:
                        return nil
                    }
                case .failure:
                    return nil
                }
            }
            guard let outcome else {
                Issue.record("generate did not fail")
                return
            }
            #expect(outcome.message == "override rows is used in shader but not provided")
            #expect(outcome.entries.map(\.value) == [.i32(-1), .u32(64), .f32(2.0)])
            #expect(outcome.entries.first?.name == Name("unknown"))
        }

        // The module after a rollback is the one prepare received, whichever way prepare or generate ended.
        @Test
        func snapshotIsIdenticalBeforePrepareAndAfterRollback() {
            let vertex = rollBackEveryWay(vertexShader)
            #expect(vertex.outcomes == ["abandoned", "abandoned", "generated", "generated"])
            #expect(vertex.restored == [true, true, true, true])

            let fragment = rollBackEveryWay(fragmentShader)
            #expect(
                fragment.outcomes == ["abandoned", "prepare failed: Shader is incompatible with layout pipeline", "generated", "generated"]
            )
            #expect(fragment.restored == [true, true, true, true])

            let compute = rollBackEveryWay(computeShader)
            #expect(
                compute.outcomes == [
                    "abandoned", "prepare failed: Shader is incompatible with layout pipeline",
                    "generate failed: override rows is used in shader but not provided", "generated",
                ]
            )
            #expect(compute.restored.prefix(2) == [true, true])
            #expect(compute.nodesRestored == [true, true, true, true])
            #expect(compute.constantsOnlyGainCachedValues == [true, true, true, true])
        }
    }
}
