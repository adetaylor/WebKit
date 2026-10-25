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

import Foundation
import Testing
@_spi(Testing) import WGSL

// insertBoundsChecks (BoundsCheck.cpp) and its generate-time half, the override validation's replacement (BoundsCheck.cpp:238-258).
// Each expected AST is what the C++ `AST::StringDumper` printed after insertBoundsChecks for the same source. The tests run
// insertBoundsChecks inside ModuleState.withTestScope (the prepare scope) and generate's validateOverrides in a nested scope.

// MARK: - Helpers

/// The module after the static passes (WGSL.cpp:94-113), or nil if one of them failed.
private func checkedModule(_ source: SourceText) -> ShaderModule? {
    var module = ShaderModule(source: source, configuration: testsConfiguration)
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

/// Runs `body` on the compile thread when the module is built with -Onone (TestWGSLAPI.swift).
private func onBoundsCheckThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in body() }
    }
    return body()
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    String(decoding: module.symbols.codeUnits(of: module.symbol(of: identifier)), as: UTF16.self)
}

/// The module-scope variable whose source name is `name`.
private func variable(_ module: borrowing ShaderModule, _ name: String) -> VariableID? {
    for declaration in module.elements(module.declarations) {
        if case .variable(let variable) = declaration, text(module, module[variable].originalName) == name {
            return variable
        }
    }
    return nil
}

/// The mangled name of the module-scope variable `name`, the key validateOverrides gives its value.
private func mangledName(_ module: borrowing ShaderModule, _ name: String) -> Name {
    guard let variable = variable(module, name) else {
        return Name("")
    }
    return module.symbols.name(of: module.symbol(of: module[variable].name))
}

/// The statements of the body of the first function.
private func bodyStatements(_ module: borrowing ShaderModule) -> [StatementID] {
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration, case .compoundStatement(let body) = module[module[function].body].kind {
            return module.elements(body.statements)
        }
    }
    return []
}

/// The expression under any IdentityExpressions.
private func unwrapped(_ module: borrowing ShaderModule, _ expression: ExpressionID) -> ExpressionID {
    var expression = expression
    while case .identityExpression(let identity) = module[expression].kind {
        expression = identity.expression
    }
    return expression
}

/// The left-hand side of an assignment, or the initializer of a variable statement.
private func operand(_ module: borrowing ShaderModule, _ statement: StatementID, lhs: Bool = true) -> ExpressionID? {
    switch module[statement].kind {
    case .assignmentStatement(let assignment):
        unwrapped(module, lhs ? assignment.lhs : assignment.rhs)
    case .variableStatement(let variableStatement):
        module[variableStatement.variable].maybeInitializer.map { unwrapped(module, $0) }
    default:
        nil
    }
}

private func proof(_ module: borrowing ShaderModule, _ expression: ExpressionID?) -> SubscriptProof.Reason? {
    guard let expression, case .checkedIndexAccessExpression(let access) = module[expression].kind else {
        return nil
    }
    return access.proof.reason
}

private func isUncheckedAccess(_ module: borrowing ShaderModule, _ expression: ExpressionID?) -> Bool {
    guard let expression, case .indexAccessExpression = module[expression].kind else {
        return false
    }
    return true
}

/// Walks the accesses C++ BoundsCheck visits (BoundsCheck.cpp:58-75).
///
/// Those are every access outside override declarations, except the children of a constant-valued access, each once. Accesses
/// inside override declarations are counted separately.
private struct AccessCensus: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    /// The proofs of the checked accesses, in pre-order.
    var proofs: [SubscriptProof.Reason] = []
    var unchecked = 0
    var uncheckedInOverrides = 0
    var checkedInOverrides = 0
    private var insideOverride = false
    private var seen = Set<ExpressionID>()

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ variable: VariableID) {
        let saved = insideOverride
        insideOverride = insideOverride || shaderModule[variable].flavor == .override
        visitChildren(variable)
        insideOverride = saved
    }

    mutating func visit(_ access: IndexAccessExpression, _ id: ExpressionID) {
        if insideOverride {
            uncheckedInOverrides += 1
        } else {
            unchecked += 1
        }
        visitChildren(access, id)
    }

    mutating func visit(_ access: CheckedIndexAccessExpression, _ id: ExpressionID) {
        if insideOverride {
            checkedInOverrides += 1
            visitChildren(access, id)
            return
        }
        guard seen.insert(id).inserted else {
            return
        }
        proofs.append(access.proof.reason)
        if access.proof.reason == .constantValue {
            return
        }
        visitChildren(access, id)
    }
}

private struct Census: Equatable, CustomStringConvertible {
    var proofs: [SubscriptProof.Reason] = []
    var unchecked = 0
    var uncheckedInOverrides = 0
    var checkedInOverrides = 0

    var description: String {
        "proofs=\(proofs) unchecked=\(unchecked) uncheckedInOverrides=\(uncheckedInOverrides) checkedInOverrides=\(checkedInOverrides)"
    }
}

private func census(_ module: inout ShaderModule) -> Census {
    var visitor = AccessCensus(shaderModule: module)
    visitor.visitShaderModule()
    module = visitor.shaderModule
    return Census(
        proofs: visitor.proofs,
        unchecked: visitor.unchecked,
        uncheckedInOverrides: visitor.uncheckedInOverrides,
        checkedInOverrides: visitor.checkedInOverrides
    )
}

/// What insertBoundsChecks did inside the prepare scope, and the module's state after the scope was rolled back.
private struct BoundsCheckRun: Sendable {
    var dump = ""
    var census = Census()
    var validations = 0
    var dumpBefore = ""
    var dumpAfterRollback = ""
    var usesMinAfterRollback = false
    var uncheckedAfterRollback = 0
}

private func runBoundsCheck(_ source: SourceText) -> BoundsCheckRun? {
    guard var module = checkedModule(source) else {
        return nil
    }
    var run = BoundsCheckRun()
    run.dumpBefore = ASTStringDumper.dump(module)
    ModuleState.withTestScope(&module) { module in
        insertBoundsChecks(&module)
        run.dump = ASTStringDumper.dump(module)
        run.census = census(&module)
        run.validations = module.currentOverrideValidationsSize
    }
    run.dumpAfterRollback = ASTStringDumper.dump(module)
    run.usesMinAfterRollback = module.uses.contains(.min)
    run.uncheckedAfterRollback = census(&module).unchecked
    return run
}

// MARK: - Tests

@Suite
struct WGSLBoundsCheckTests {
    // BoundsCheck.cpp:87-143, :162-172, :186-217: vector, matrix and runtime-sized array accesses are replaced by the clamped access,
    // through a reference or a pointer, with `u32(...)` around a non-u32 index.
    @Test
    func vectorMatrixAndRuntimeArrayAccessesAreClamped() {
        let run = onBoundsCheckThread {
            runBoundsCheck(
                SourceText(
                    """
                    @group(0) @binding(0) var<storage, read_write> buffer: array<vec4f>;
                    @compute @workgroup_size(1)
                    fn main(@builtin(local_invocation_index) li: u32) {
                        var v = vec4f(1, 2, 3, 4);
                        var m = mat3x3f();
                        var i: i32 = 2;
                        let p = &v;
                        buffer[li] = v;
                        buffer[i].x = v[i] + m[li][i] + (*p)[li];
                    }

                    """
                )
            )
        }
        guard let run else {
            Issue.record("the static passes failed")
            return
        }
        #expect(
            run.dump == """
                @group(0) @binding(0) var<storage,read_write> global0: array<vec4f>;
                @compute @workgroup_size(1)
                fn function0(
                    @builtin(local_invocation_index) parameter0: u32
                )
                {
                    var local0 = vec4f(1, 2, 3, 4);
                    var local1 = mat3x3f();
                    var local2: i32 = 2;
                    global0[__wgslMin(parameter0, arrayLength(&global0) - 1u)] = local0;
                    global0[__wgslMin(u32(local2), arrayLength(&global0) - 1u)].x = local0[__wgslMin(u32(local2), 4u - 1u)] + local1[__wgslMin(parameter0, 3u - 1u)][__wgslMin(u32(local2), 3u - 1u)] + local0[__wgslMin(parameter0, 4u - 1u)];
                }
                """ + "\n\n"
        )
        #expect(run.census == Census(proofs: Array(repeating: .clamped, count: 6)), "\(run.census)")
        #expect(run.validations == 6)
        #expect(run.dumpAfterRollback == run.dumpBefore)
        #expect(run.uncheckedAfterRollback == 6)
        // setUsesMin() is sticky: the rollback keeps it, as in C++.
        #expect(run.usesMinAfterRollback)
    }

    // BoundsCheck.cpp:174-235: constant- and override-sized array accesses are not clamped; their override validation checks
    // them at generate time. Constant-valued accesses (at module scope, in an attribute and in a body) are skipped.
    @Test
    func sizedArrayAccessesAreValidatedAndConstantAccessesAreSkipped() {
        let run = onBoundsCheckThread {
            runBoundsCheck(
                SourceText(
                    """
                    override n: u32 = 4;
                    const c = array(1, 2, 3);
                    var<workgroup> w: array<i32, n>;
                    var<private> fixed: array<i32, 4>;
                    var<private> g: i32 = c[0];
                    @compute @workgroup_size(c[1])
                    fn main(@builtin(local_invocation_index) li: u32) {
                        fixed[li] = 1;
                        fixed[2] = 2;
                        w[li] = 3;
                        w[1] = c[1];
                        let x = c[li];
                    }

                    """
                )
            )
        }
        guard let run else {
            Issue.record("the static passes failed")
            return
        }
        #expect(
            run.dump == """
                var global0: u32 = 4;
                var global1 = array(1, 2, 3);
                var<workgroup,read_write> global2: array<i32, global0>;
                var<private,read_write> global3: array<i32, 4>;
                var<private,read_write> global4: i32 = global1[0];
                @compute @workgroup_size(global1[1])
                fn function0(
                    @builtin(local_invocation_index) parameter0: u32
                )
                {
                    global3[parameter0] = 1;
                    global3[2] = 2;
                    global2[parameter0] = 3;
                    global2[1] = global1[1];
                    var local0 = global1[parameter0];
                }
                """ + "\n\n"
        )
        let expected = Census(proofs: [
            .constantValue, .constantValue, .overrideValidated, .inBoundsConstant, .overrideValidated, .overrideValidated,
            .constantValue, .overrideValidated,
        ])
        #expect(run.census == expected, "\(run.census)")
        #expect(run.validations == 5)
        #expect(run.dumpAfterRollback == run.dumpBefore)
        #expect(!run.usesMinAfterRollback)
    }

    // BoundsCheck.cpp:66-75. PointerRewriter shares `v[arr[idx[1]]]` between both uses of `*p`. The constant-valued index
    // `arr[idx[1]]` is marked without visiting its children, so `idx[1]` stays unchecked; the second use reaches the access
    // already checked, and the checked hook (m_visited) returns without visiting its children again.
    @Test
    func constantValuedAccessChildrenAreNotVisitedAndASharedAccessIsVisitedOnce() {
        struct Outcome: Sendable {
            var run = BoundsCheckRun()
            var shared = false
            var outer: SubscriptProof.Reason?
            var index: SubscriptProof.Reason?
            var innerIsUnchecked = false
        }
        let result = onBoundsCheckThread { () -> Outcome? in
            let source = SourceText(
                """
                const arr = array(1, 2, 3, 4);
                const idx = array(0, 1);
                @compute @workgroup_size(1)
                fn main() {
                    var v: array<i32, 4>;
                    let p = &v[arr[idx[1]]];
                    *p = 1;
                    let x = *p;
                }

                """
            )
            guard var module = checkedModule(source), let run = runBoundsCheck(source) else {
                return nil
            }
            var result = Outcome(run: run)
            ModuleState.withTestScope(&module) { module in
                insertBoundsChecks(&module)
                let statements = bodyStatements(module)
                guard statements.count == 3, let first = operand(module, statements[1]), let second = operand(module, statements[2]) else {
                    return
                }
                result.shared = first == second
                result.outer = proof(module, first)
                guard case .checkedIndexAccessExpression(let outer) = module[first].kind else {
                    return
                }
                result.index = proof(module, outer.index)
                guard case .checkedIndexAccessExpression(let index) = module[outer.index].kind else {
                    return
                }
                result.innerIsUnchecked = isUncheckedAccess(module, index.index)
            }
            return result
        }
        guard let result else {
            Issue.record("the static passes failed")
            return
        }
        #expect(
            result.run.dump == """
                var global0 = array(1, 2, 3, 4);
                var global1 = array(0, 1);
                @compute @workgroup_size(1)
                fn function0()
                {
                    var local0: array<i32, 4>;
                    local0[global0[global1[1]]] = 1;
                    var local2 = local0[global0[global1[1]]];
                }
                """ + "\n\n"
        )
        #expect(result.shared)
        #expect(result.outer == .inBoundsConstant)
        #expect(result.index == .constantValue)
        #expect(result.innerIsUnchecked)
        #expect(result.run.census == Census(proofs: [.inBoundsConstant, .constantValue]), "\(result.run.census)")
        #expect(result.run.validations == 1)
    }

    // BoundsCheck.cpp:58-63: override declarations are not visited, so their accesses stay unchecked and register no validation.
    // A user value for `o` with an out-of-range `k` therefore passes validateOverrides, as in C++.
    @Test
    func overrideInitializersAreNotVisited() {
        struct Outcome: Sendable {
            var run = BoundsCheckRun()
            var error: String?
        }
        let result = onBoundsCheckThread { () -> Outcome? in
            let source = SourceText(
                """
                const arr = array(10u, 20u, 30u);
                override k: u32 = 2;
                override o: u32 = arr[k];
                @group(0) @binding(0) var<storage, read_write> out: array<u32>;
                @compute @workgroup_size(1) fn main() { out[0] = o; }
                """
            )
            guard var module = checkedModule(source), let run = runBoundsCheck(source) else {
                return nil
            }
            var result = Outcome(run: run)
            ModuleState.withTestScope(&module) { module in
                insertBoundsChecks(&module)
                ModuleState.withTestScope(&module) { module in
                    var values = OverrideValues()
                    values.set(Name("k"), .uint32(9))
                    values.set(Name("o"), .uint32(7))
                    let error = module.validateOverridesForTesting(specializationConstantKeys: [Name("k"), Name("o")], &values)
                    result.error = error.map { String(decoding: $0.utf16, as: UTF16.self) }
                }
            }
            return result
        }
        guard let result else {
            Issue.record("the static passes failed")
            return
        }
        #expect(
            result.run.dump == """
                var global0 = array(10u, 20u, 30u);
                var global1: u32 = 2;
                var global2: u32 = global0[global1];
                @group(0) @binding(0) var<storage,read_write> global3: array<u32>;
                @compute @workgroup_size(1)
                fn function0()
                {
                    global3[__wgslMin(u32(0), arrayLength(&global3) - 1u)] = global2;
                }
                """ + "\n\n"
        )
        #expect(result.run.census == Census(proofs: [.clamped], uncheckedInOverrides: 1), "\(result.run.census)")
        #expect(result.run.validations == 1)
        #expect(result.error == nil)
    }

    // evaluate() at generate time sees the checked access as C++ sees its IndexAccessExpression (the C++ MSL is
    // `int local1 = 20;`).
    @Test
    func EvaluateSeesCheckedIndexAccess_ovidx() {
        struct Outcome: Sendable {
            var run = BoundsCheckRun()
            var proof: SubscriptProof.Reason?
            var error: String?
            var value: String?
        }
        let result = onBoundsCheckThread { () -> Outcome? in
            let source = SourceText(
                """
                override o: u32 = 1;
                @group(0) @binding(0) var<storage, read_write> out: array<i32>;
                @compute @workgroup_size(1) fn main() {
                  const arr = array(10, 20, 30);
                  let x = arr[o];
                  out[0] = x;
                }

                """
            )
            guard var module = checkedModule(source), let run = runBoundsCheck(source) else {
                return nil
            }
            var result = Outcome(run: run)
            ModuleState.withTestScope(&module) { module in
                insertBoundsChecks(&module)
                let statements = bodyStatements(module)
                guard statements.count == 3, let access = operand(module, statements[1]) else {
                    return
                }
                result.proof = proof(module, access)
                ModuleState.withTestScope(&module) { module in
                    var values = OverrideValues()
                    let error = module.validateOverridesForTesting(specializationConstantKeys: [Name("o")], &values)
                    result.error = error.map { String(decoding: $0.utf16, as: UTF16.self) }
                    result.value = evaluate(&module, access, values).map { String(decoding: module.dump($0).codeUnits, as: UTF16.self) }
                }
            }
            return result
        }
        guard let result else {
            Issue.record("the static passes failed")
            return
        }
        #expect(
            result.run.dump == """
                var global0: u32 = 1;
                @group(0) @binding(0) var<storage,read_write> global1: array<i32>;
                @compute @workgroup_size(1)
                fn function0()
                {
                    var local0 = array(10, 20, 30);
                    var local1 = local0[global0];
                    global1[__wgslMin(u32(0), arrayLength(&global1) - 1u)] = local1;
                }
                """ + "\n\n"
        )
        #expect(result.proof == .overrideValidated)
        #expect(result.error == nil)
        #expect(result.value == "20i")
        #expect(result.run.census == Census(proofs: [.overrideValidated, .clamped]), "\(result.run.census)")
    }

    // The override initializer `arr[k]` is not visited by insertBoundsChecks and evaluates to the C++ value (the C++ MSL stores
    // `30u`).
    @Test
    func EvaluateSeesCheckedIndexAccess_ovinit() {
        struct Outcome: Sendable {
            var run = BoundsCheckRun()
            var initializerIsUnchecked = false
            var error: String?
            var value: String?
        }
        let result = onBoundsCheckThread { () -> Outcome? in
            let source = SourceText(
                """
                const arr = array(10u, 20u, 30u);
                override k: u32 = 2;
                override o: u32 = arr[k];
                @group(0) @binding(0) var<storage, read_write> out: array<u32>;
                @compute @workgroup_size(1) fn main() { out[0] = o; }

                """
            )
            guard var module = checkedModule(source), let run = runBoundsCheck(source) else {
                return nil
            }
            var result = Outcome(run: run)
            let key = mangledName(module, "o")
            ModuleState.withTestScope(&module) { module in
                insertBoundsChecks(&module)
                result.initializerIsUnchecked = isUncheckedAccess(module, variable(module, "o").flatMap { module[$0].maybeInitializer })
                ModuleState.withTestScope(&module) { module in
                    var values = OverrideValues()
                    let error = module.validateOverridesForTesting(specializationConstantKeys: [Name("k"), Name("o")], &values)
                    result.error = error.map { String(decoding: $0.utf16, as: UTF16.self) }
                    result.value = values.find(key).map { String(decoding: module.dump($0).codeUnits, as: UTF16.self) }
                }
            }
            return result
        }
        guard let result else {
            Issue.record("the static passes failed")
            return
        }
        #expect(result.initializerIsUnchecked)
        #expect(result.error == nil)
        #expect(result.value == "30u")
    }

    // BoundsCheck.cpp:238-245: at generate time, an access whose index the override validation cannot evaluate is replaced by
    // the clamped access; the generation scope's rollback restores the prepare-time access.
    @Test
    func overrideValidationClampsAnAccessItCannotEvaluate() {
        struct Outcome: Sendable {
            var prepared: SubscriptProof.Reason?
            var generated: SubscriptProof.Reason?
            var generatedDump = ""
            var error: String?
            var afterGeneration: SubscriptProof.Reason?
            var afterPrepare = false
        }
        let result = onBoundsCheckThread { () -> Outcome? in
            let source = SourceText(
                """
                override n: u32 = 2;
                @group(0) @binding(0) var<storage, read_write> out: array<i32>;
                var<private> fixed: array<i32, 3>;
                var<workgroup> w: array<i32, n>;
                @compute @workgroup_size(1)
                fn main(@builtin(local_invocation_index) li: u32) {
                    out[0] = fixed[li];
                    w[li] = 1;
                }

                """
            )
            guard var module = checkedModule(source) else {
                return nil
            }
            var result = Outcome()
            var access: ExpressionID?
            ModuleState.withTestScope(&module) { module in
                insertBoundsChecks(&module)
                let statements = bodyStatements(module)
                guard statements.count == 2, let rhs = operand(module, statements[0], lhs: false) else {
                    return
                }
                access = rhs
                result.prepared = proof(module, rhs)
                ModuleState.withTestScope(&module) { module in
                    var values = OverrideValues()
                    let error = module.validateOverridesForTesting(specializationConstantKeys: [Name("n")], &values)
                    result.error = error.map { String(decoding: $0.utf16, as: UTF16.self) }
                    result.generated = proof(module, rhs)
                    result.generatedDump = ASTStringDumper.dump(module)
                }
                result.afterGeneration = proof(module, rhs)
            }
            result.afterPrepare = isUncheckedAccess(module, access)
            return result
        }
        guard let result else {
            Issue.record("the static passes failed")
            return
        }
        #expect(result.prepared == .overrideValidated)
        #expect(result.error == nil)
        #expect(result.generated == .clamped)
        #expect(
            result.generatedDump.contains(
                "global1[__wgslMin(u32(0), arrayLength(&global1) - 1u)] = global2[__wgslMin(parameter0, 3u - 1u)];"
            ),
            "\(result.generatedDump)"
        )
        #expect(result.generatedDump.contains("global3[__wgslMin(parameter0, global0 - 1u)] = 1;"), "\(result.generatedDump)")
        #expect(result.afterGeneration == .overrideValidated)
        #expect(result.afterPrepare)
    }

    // BoundsCheck.cpp:247-257: when GlobalVariableRewriter has packed the access into `__pack(copy)` (GlobalVariableRewriter.cpp:520-528,
    // a wrapping replace), the replacement goes to the copy inside the call.
    @Test
    func overrideValidationClampsThePackedCopy() {
        struct Outcome: Sendable {
            var copy: SubscriptProof.Reason?
            var accessIsIdentity = false
        }
        let result = onBoundsCheckThread { () -> Outcome? in
            let source = SourceText(
                """
                var<private> fixed: array<i32, 3>;
                @compute @workgroup_size(1)
                fn main(@builtin(local_invocation_index) li: u32) {
                    let x = fixed[li];
                }

                """
            )
            guard var module = checkedModule(source) else {
                return nil
            }
            var result = Outcome()
            ModuleState.withTestScope(&module) { module in
                insertBoundsChecks(&module)
                let statements = bodyStatements(module)
                guard statements.count == 1, let access = operand(module, statements[0]) else {
                    return
                }
                let copy = module.construct(copyOf: access)
                let target = module.constructIdentifierExpression(
                    span: .empty,
                    identifier: module.makeIdentifier(module.symbols.intern(ReservedName.fixed(.pack)))
                )
                let call = module.construct(span: .empty, CallExpression(target: target, arguments: module.makeList([copy])))
                module.replace(access, with: call)
                ModuleState.withTestScope(&module) { module in
                    var values = OverrideValues()
                    _ = module.validateOverridesForTesting(specializationConstantKeys: [], &values)
                    result.copy = proof(module, copy)
                    if case .identityExpression = module[access].kind {
                        result.accessIsIdentity = true
                    }
                }
            }
            return result
        }
        guard let result else {
            Issue.record("the static passes failed")
            return
        }
        #expect(result.copy == .clamped)
        #expect(result.accessIsIdentity)
    }

    // Every shader of the TestWGSL corpus that passes the static passes: no access C++ BoundsCheck visits stays unchecked, no
    // access inside an override declaration is checked, and the rollback restores the module.
    @Test
    func everyVisitedAccessOfTheShaderCorpusIsChecked() {
        let directory = Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("shaders") } ?? "shaders"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".wgsl") }.sorted()
        #expect(names.count > 40)
        var checkedShaders = 0
        for name in names {
            let source = file(name)
            let run = onBoundsCheckThread { runBoundsCheck(source) }
            guard let run else {
                continue
            }
            checkedShaders += 1
            #expect(run.census.unchecked == 0, "\(name): \(run.census)")
            #expect(run.census.checkedInOverrides == 0, "\(name): \(run.census)")
            #expect(run.dumpAfterRollback == run.dumpBefore, "\(name)")
        }
        #expect(checkedShaders > 20)
    }
}
