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

// evaluate() (WGSL.cpp:188-364), ensureOverrideValue, validateOverrides and containsOverride (WGSLShaderModule.cpp:38-99)
// on modules that passed the static passes. Expected messages and spans come from the C++ (WebGPU's prepare + generate
// sequence on the same source). The tests register the override validations the prepare passes register for these sources,
// in their order, and run generate's validateOverrides inside ModuleState.withTestScope.

// MARK: - Helpers

/// The module after the static passes up to aliasAnalysis (WGSL.cpp:94-113; uniformity analysis writes nothing evaluate reads).
private func checkedModule(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    func check(_ result: FailedCheck?) {
        if let result, !result.errors.isEmpty {
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
    return module
}

/// Runs `body` on the compile thread when the module is built with -Onone (TestWGSLAPI.swift).
private func onEvaluateThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in body() }
    }
    return body()
}

private func text(_ module: borrowing ShaderModule, _ symbol: Symbol) -> String {
    String(decoding: module.symbols.codeUnits(of: symbol), as: UTF16.self)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    text(module, module.symbol(of: identifier))
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

private func initializer(_ module: borrowing ShaderModule, _ name: String) -> ExpressionID? {
    variable(module, name).flatMap { module[$0].maybeInitializer }
}

private func function(_ module: borrowing ShaderModule, _ name: String) -> FunctionID? {
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration, text(module, module[function].originalName) == name {
            return function
        }
    }
    return nil
}

/// The statements in the body of the function `name`.
private func statements(_ module: borrowing ShaderModule, _ name: String) -> [StatementID] {
    guard let function = function(module, name), case .compoundStatement(let body) = module[module[function].body].kind else {
        return []
    }
    return module.elements(body.statements)
}

/// The mangled name of the module-scope variable whose source name is `name`, the key validateOverrides gives its value.
private func mangledName(_ module: borrowing ShaderModule, _ name: String) -> Name {
    guard let variable = variable(module, name) else {
        return Name(utf16: [])
    }
    return module.symbols.name(of: module.symbol(of: module[variable].name))
}

private func message(_ error: CompilationMessage?) -> String? {
    error.map { "\($0.span.line):\($0.span.lineOffset): \(String(decoding: $0.utf16, as: UTF16.self))" }
}

/// MSL's spelling of the scalar constants these tests print.
private func spelling(_ value: ConstantValue?) -> String {
    switch value {
    case .uint32(let value): "\(value)u"
    case .int32(let value): "\(value)"
    case .int64(let value): "\(value)"
    case .bool(let value): "\(value)"
    case .float(let value) where value.rounded() == value: "\(Int32(value))."
    case .none: "-"
    default: "?"
    }
}

// MARK: - Sticky sequences

/// One pipeline: an entry point and the GPUProgrammableStage constants, converted to the overrides' types.
private struct StickyPipeline: Sendable {
    /// A constant's value: a scalar, which crosses to the compile thread (ConstantValue is not Sendable).
    enum Value: Sendable {
        case uint32(UInt32)
        case float(Float)

        var constantValue: ConstantValue {
            switch self {
            case .uint32(let value): .uint32(value)
            case .float(let value): .float(value)
            }
        }
    }

    let entry: String
    let constants: [(key: String, value: Value)]

    init(_ entry: String, _ constants: [(key: String, value: UInt32)] = []) {
        self.init(entry, values: constants.map { ($0.key, .uint32($0.value)) })
    }

    init(_ entry: String, values: [(key: String, value: Value)]) {
        self.entry = entry
        self.constants = values
    }
}

/// What the modelled prepare reports: the overrides the entry point uses (keys), sizeForWorkgroupVariables, and the
/// nodes whose constants the Metal writer prints.
private struct ModelledPrepare {
    var specializationConstantKeys: [String]
    var sizeForWorkgroupVariables: UInt32 = 0
    var printedNodes: [ExpressionID] = []
}

/// `GlobalVariableRewriter.cpp:1108-1112, :1225-1231` for the workgroup variables `names`.
private func sizeForWorkgroupVariables(_ module: borrowing ShaderModule, _ names: [String]) -> UInt32 {
    var size: UInt32 = 0
    for name in names {
        guard let variable = variable(module, name), let storeType = module[variable].storeType else {
            continue
        }
        size += wtfRoundUpToMultipleOf(16, module.size(of: storeType).bytes)
    }
    return size
}

/// The override-sized count of the workgroup array `name`.
private func arrayCount(_ module: borrowing ShaderModule, _ name: String) -> ExpressionID? {
    guard let variable = variable(module, name), let storeType = module[variable].storeType,
        case .array(let array) = module.types[storeType], case .overrideSized(let count) = array.size
    else {
        return nil
    }
    return count
}

/// Replays WebGPU's prepareLibrary + metalSize sequence (Pipeline.mm:52-176, ComputePipeline.mm:59-130) on one shared module
/// and on a fresh module per pipeline, and returns its transcript. `prepare` stands for the
/// prepare passes inside the prepare scope; generate's validateOverrides and the writer's reads follow in the same scope;
/// the workgroup size is evaluated after the rollback with the values generate re-keyed.
private func replay(
    _ source: String,
    _ pipelines: [StickyPipeline],
    prepare: @escaping @Sendable (inout ShaderModule, String) -> ModelledPrepare
) -> [String] {
    onEvaluateThread {
        var transcript: [String] = []
        for mode in ["shared", "fresh"] {
            var module = checkedModule(source)
            for (index, pipeline) in pipelines.enumerated() {
                if mode == "fresh" {
                    module = checkedModule(source)
                }
                var values = OverrideValues()
                for constant in pipeline.constants {
                    values.set(Name(constant.key), constant.value.constantValue)
                }
                var outcome = ""
                var failed = false
                ModuleState.withTestScope(&module) { module in
                    let prepared = prepare(&module, pipeline.entry)
                    let keys = prepared.specializationConstantKeys.map { Name($0) }
                    if let error = module.validateOverridesForTesting(specializationConstantKeys: keys, &values) {
                        outcome = "generate error: \(message(error) ?? "")"
                        failed = true
                        return
                    }
                    let printed = prepared.printedNodes.map { spelling(module.constantValueForWriter($0)) }
                    outcome = "sizeForWorkgroupVariables=\(prepared.sizeForWorkgroupVariables) msl=\(printed.joined(separator: ","))"
                }
                if !failed, let function = function(module, pipeline.entry), let size = module[function].workgroupSize {
                    let width = evaluate(&module, size.x, values)
                    let height = size.y.map { evaluate(&module, $0, values) } ?? .uint32(1)
                    let depth = size.z.map { evaluate(&module, $0, values) } ?? .uint32(1)
                    if let width, let height, let depth {
                        outcome += " workgroupSize=\(width.integerValue()),\(height.integerValue()),\(depth.integerValue())"
                    } else {
                        outcome += " workgroupSize=<failed>"
                    }
                }
                transcript.append("[\(mode) #\(index + 1)] \(outcome)")
            }
        }
        return transcript
    }
}

/// GlobalVariableRewriter's registrations for a workgroup array with an override-sized count: the count's operator
/// validation where the type is packed, the count's ensureOverrideValue where the zero-initialization loop is packed,
/// then the combined workgroup size check.
private func registerWorkgroupArrayValidations(_ module: inout ShaderModule, _ entry: String, _ name: String) {
    guard let count = arrayCount(module, name), let variable = variable(module, name), let storeType = module[variable].storeType,
        let function = function(module, entry)
    else {
        return
    }
    if case .binaryExpression = module[count].kind {
        module.addOverrideValidationForTesting(validationOfBinaryExpression: count, guards: [])
    }
    module.addOverrideValidationForTesting(ensuringOverrideValueOf: count, guards: [])
    module.addOverrideValidationForTesting(
        combinedSizeOf: [storeType],
        workgroup: true,
        span: module.span(of: .function(function)),
        limit: testsConfiguration.maximumCombinedWorkgroupVariablesSize
    )
}

/// `var<workgroup> a: array<u32, …>` used by `entry`, with the overrides `keys`.
private func prepareWorkgroupArray(keys: [String]) -> @Sendable (inout ShaderModule, String) -> ModelledPrepare {
    { module, entry in
        var prepared = ModelledPrepare(specializationConstantKeys: keys)
        prepared.sizeForWorkgroupVariables = sizeForWorkgroupVariables(module, ["a"])
        registerWorkgroupArrayValidations(&module, entry, "a")
        if let count = arrayCount(module, "a") {
            prepared.printedNodes = [count]
        }
        return prepared
    }
}

/// GlobalVariableRewriter.cpp:513-528: replaces `expression` with the call `operation(<a copy of expression>)`, which wraps
/// `expression` in an IdentityExpression when its C++ class is smaller than CallExpression.
private func packInPlace(_ module: inout ShaderModule, _ expression: ExpressionID, _ operation: ReservedName.Fixed) {
    let symbol = module.symbols.intern(.fixed(operation))
    let callee = module.constructIdentifierExpression(span: .empty, identifier: module.makeIdentifier(symbol))
    module.setInferredType(module.types.u32Type, for: callee)
    let argument = module.construct(copyOf: expression)
    var call = CallExpression(target: callee, arguments: module.makeList([argument]))
    call.resolvedTarget = symbol
    let callExpression = module.construct(span: .empty, call)
    module.setInferredType(module.inferredType(of: argument), for: callExpression)
    module.replace(expression, with: callExpression)
}

/// The access `arr[I]` of a constant array of 3: BoundsCheck skips it once it has a constant (BoundsCheck.cpp:66-67),
/// otherwise registers its override validation (BoundsCheck.cpp:220).
private func registerConstantArrayBoundsCheck(_ module: inout ShaderModule, _ access: ExpressionID) {
    guard module.constantValueForBoundsCheckSkip(access) == nil, case .indexAccessExpression(let indexAccess) = module[access].kind else {
        return
    }
    module.addOverrideValidationForTesting(boundsCheckOf: access, index: indexAccess.index, constant: 3, sizeExpression: nil)
}

// MARK: - Tests

@Suite
struct WGSLEvaluateTests {
    // MARK: evaluate

    private static let overrides = """
        override o: i32 = 3;
        override p: bool;
        override q: bool;
        const c = 4;
        struct S { a: i32, b: i32 }
        override arithmetic: i32 = o * 2 + c;
        override negation: i32 = -o;
        override builtinCall: i32 = max(o, 7);
        override conjunction = p && q;
        override disjunction = p || q;
        override element: i32 = array(10, 20, 30)[o];
        override field: i32 = S(o, 2).b;
        override swizzle: i32 = vec3(o, 5, 6).z;
        override swizzles: i32 = vec3(o, 5, 6).zx.y;
        """

    @Test
    func evaluatesOperatorsCallsAndAccesses() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(Self.overrides)
            var values = OverrideValues()
            values.set(mangledName(module, "o"), .int32(1))
            var results: [String] = []
            for name in ["arithmetic", "negation", "builtinCall", "element", "field", "swizzle", "swizzles"] {
                guard let expression = initializer(module, name) else {
                    results.append("\(name)=missing")
                    continue
                }
                results.append("\(name)=\(spelling(evaluate(&module, expression, values)))")
            }
            return results
        }
        #expect(results == ["arithmetic=6", "negation=-1", "builtinCall=7", "element=20", "field=2", "swizzle=6", "swizzles=1"])
    }

    @Test
    func failsWhenAnOverrideIsMissingOrAnIndexIsOutOfBounds() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(Self.overrides)
            var results: [String] = []
            for value: Int32 in [3, -1, 2] {
                var values = OverrideValues()
                values.set(mangledName(module, "o"), .int32(value))
                if let expression = initializer(module, "element") {
                    results.append(spelling(evaluate(&module, expression, values)))
                }
            }
            if let expression = initializer(module, "arithmetic") {
                results.append(spelling(evaluate(&module, expression, OverrideValues())))
            }
            return results
        }
        #expect(results == ["-", "-", "30", "-"])
    }

    // WGSL.cpp:233-252: the right operand is evaluated only when the left one does not decide; when it fails, the result is
    // the seed, here the `false` cached by the first evaluation.
    @Test
    func shortCircuitOperators() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(Self.overrides)
            let p = mangledName(module, "p")
            let q = mangledName(module, "q")
            var results: [String] = []
            for (pValue, qValue) in [(false, nil), (true, nil), (true, false), (true, true)] as [(Bool, Bool?)] {
                var values = OverrideValues()
                values.set(p, .bool(pValue))
                if let qValue {
                    values.set(q, .bool(qValue))
                }
                for name in ["conjunction", "disjunction"] {
                    guard let expression = initializer(module, name) else {
                        continue
                    }
                    results.append(spelling(evaluate(&module, expression, values)))
                }
            }
            return results
        }
        #expect(results == ["false", "-", "false", "true", "false", "true", "true", "true"])
    }

    // WGSL.cpp:191-192 and :359-362: a result is cached on the node, outside any CompilationScope, and seeds later evaluations
    // whose own inputs fail.
    @Test
    func cachedResultSurvivesRollbackAndSeedsLaterEvaluations() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(Self.overrides)
            guard let swizzle = initializer(module, "swizzle"), case .fieldAccessExpression(let access) = module[swizzle].kind,
                case .callExpression(let constructor) = module[access.base].kind
            else {
                return ["missing"]
            }
            let identifier = module[constructor.arguments, 0]
            var results = [spelling(module.constantValueForEvaluateSeed(identifier))]
            var values = OverrideValues()
            values.set(mangledName(module, "o"), .int32(9))
            ModuleState.withTestScope(&module) { module in
                results.append(spelling(evaluate(&module, identifier, values)))
            }
            results.append(spelling(module.constantValueForEvaluateSeed(identifier)))
            results.append(spelling(evaluate(&module, identifier, OverrideValues())))
            values.set(mangledName(module, "o"), .int32(4))
            results.append(spelling(evaluate(&module, identifier, values)))
            return results
        }
        #expect(results == ["-", "9", "9", "9", "4"])
    }

    // Every kind of C++'s `default` group returns nil before the cache write, even with a constant value.
    @Test
    func defaultGroupKindsReturnNilEvenWithAConstantValue() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(Self.overrides)
            guard let arithmetic = initializer(module, "arithmetic") else {
                return ["missing"]
            }
            let identity = module.constructIdentityExpression(span: .empty, expression: arithmetic)
            module.setConstantValue(.int32(42), for: identity)
            let dereference = module.construct(span: .empty, PointerDereferenceExpression(target: arithmetic))
            module.setInferredType(module.inferredType(of: arithmetic), for: dereference)
            module.setConstantValue(.int32(43), for: dereference)
            var values = OverrideValues()
            values.set(mangledName(module, "o"), .int32(1))
            return [
                spelling(evaluate(&module, identity, values)), spelling(module.constantValueForEvaluateSeed(identity)),
                spelling(evaluate(&module, dereference, values)), spelling(module.constantValueForEvaluateSeed(dereference)),
            ]
        }
        #expect(results == ["-", "42", "-", "43"])
    }

    // MARK: validateOverrides, ensureOverrideValue, containsOverride

    private static let keyedOverrides = """
        @id(7) override a: u32;
        override b: u32 = 2;
        override c: u32;
        @group(0) @binding(0) var<storage, read_write> o: array<u32>;
        @compute @workgroup_size(1)
        fn main() {
            o[0] = a + b + c;
        }
        """

    // WGSLShaderModule.cpp:48-79; the errors are the C++'s for pipelines {7: 1} and {c: 4} (shared or fresh module alike).
    @Test
    func validateOverridesRekeysUserValuesAndReportsMissingOnes() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(Self.keyedOverrides)
            let a = mangledName(module, "a")
            let b = mangledName(module, "b")
            let c = mangledName(module, "c")
            let keys = [Name("7"), Name("b"), Name("c")]
            var results: [String] = []
            ModuleState.withTestScope(&module) { module in
                var values = OverrideValues()
                values.set(Name("7"), .uint32(1))
                values.set(Name("c"), .uint32(3))
                results.append(message(module.validateOverridesForTesting(specializationConstantKeys: keys, &values)) ?? "ok")
                results.append(
                    [Name("7"), Name("b"), Name("c"), a, b, c].map { spelling(values.find($0)) }.joined(separator: ",")
                )

                values = OverrideValues()
                values.set(Name("7"), .uint32(1))
                results.append(message(module.validateOverridesForTesting(specializationConstantKeys: keys, &values)) ?? "ok")

                values = OverrideValues()
                values.set(Name("c"), .uint32(4))
                results.append(message(module.validateOverridesForTesting(specializationConstantKeys: keys, &values)) ?? "ok")

                values = OverrideValues()
                results.append(message(module.validateOverridesForTesting(specializationConstantKeys: [], &values)) ?? "ok")
                results.append("\(values.count)")
            }
            return results
        }
        #expect(
            results == [
                "ok", "-,-,-,1u,2u,3u",
                "3:0: override c is used in shader but not provided",
                "1:7: override a is used in shader but not provided",
                "ok", "0",
            ]
        )
    }

    // WGSLShaderModule.cpp:38-44 and :72-77: the C++ for pipelines {o: 1}, {o: 5} and {o: 0} (shared or fresh module alike),
    // with the workgroup size evaluated after a successful generate.
    @Test
    func overrideInitializerThatFailsToEvaluate() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(
                """
                override o: u32;
                override k: u32 = array(1u, 2u)[o];
                @group(0) @binding(0) var<storage, read_write> out: array<u32>;
                @compute @workgroup_size(k)
                fn main() {
                    out[0] = k;
                }
                """
            )
            var results: [String] = []
            for value: UInt32 in [1, 5, 0] {
                var values = OverrideValues()
                values.set(Name("o"), .uint32(value))
                var error: String?
                ModuleState.withTestScope(&module) { module in
                    error = message(module.validateOverridesForTesting(specializationConstantKeys: [Name("o"), Name("k")], &values))
                }
                results.append(error ?? "ok")
                if error == nil, let function = function(module, "main"), let size = module[function].workgroupSize {
                    results.append(spelling(evaluate(&module, size.x, values)))
                }
            }
            return results
        }
        #expect(results == ["ok", "2u", "2:18: Failed to evaluate override value", "ok", "1u"])
    }

    private static let guardedValidations = """
        override p: bool;
        override d: u32;
        @group(0) @binding(0) var<storage, read_write> out: array<u32>;
        @compute @workgroup_size(1)
        fn main() {
            if (p && (1u / d == 1u)) {
                out[0] = 1u;
            }
            out[1] = clamp(1u, d, 2u);
        }
        """

    /// Registers GlobalVariableRewriter's validations for `guardedValidations` (`all`), or only the guarded and call
    /// validations.
    private static func registerGuardedValidations(_ module: inout ShaderModule, all: Bool) {
        let body = statements(module, "main")
        guard body.count == 2, case .ifStatement(let ifStatement) = module[body[0]].kind,
            case .binaryExpression(let conjunction) = module[ifStatement.test].kind,
            case .binaryExpression(let equality) = module[conjunction.rightExpression].kind,
            case .assignmentStatement(let assignment) = module[body[1]].kind
        else {
            Issue.record("unexpected statements")
            return
        }
        if all {
            module.addOverrideValidationForTesting(ensuringOverrideValueOf: ifStatement.test, guards: [])
        }
        module.addOverrideValidationForTesting(validationOfBinaryExpression: equality.leftExpression, guards: [ifStatement.test])
        if all {
            module.addOverrideValidationForTesting(ensuringOverrideValueOf: assignment.rhs, guards: [])
        }
        module.addOverrideValidationForTesting(validationOfCallExpression: assignment.rhs, guards: [])
    }

    // GlobalVariableRewriter.cpp:440-449 and :452-466: a validation registered under `p && …` is skipped when `p` decides.
    // The `all` results are the C++'s for pipelines {p: 0, d: 1}, {p: 0, d: 0}, {p: 1, d: 0} and {p: 0, d: 5}, on a shared
    // module and on a fresh module per pipeline: on the shared one the condition's ensureOverrideValue succeeds with the
    // `false` cached by the earlier pipelines, so the guarded division validation reports the error.
    @Test
    func validationsRunInOrderAndGuardsSkipThem() {
        let results = onEvaluateThread { () -> [String] in
            var results: [String] = []
            for (all, shared) in [(true, true), (true, false), (false, false)] {
                var module = checkedModule(Self.guardedValidations)
                for (p, d) in [(false, 1), (false, 0), (true, 0), (false, 5)] as [(Bool, UInt32)] {
                    if !shared {
                        module = checkedModule(Self.guardedValidations)
                    }
                    var values = OverrideValues()
                    values.set(Name("p"), .bool(p))
                    values.set(Name("d"), .uint32(d))
                    ModuleState.withTestScope(&module) { module in
                        Self.registerGuardedValidations(&module, all: all)
                        let error = module.validateOverridesForTesting(specializationConstantKeys: [Name("p"), Name("d")], &values)
                        results.append(message(error) ?? "ok")
                    }
                }
            }
            return results
        }
        #expect(
            results == [
                "ok", "ok", "6:17: invalid division by zero", "9:13: Failed to evaluate override value",
                "ok", "ok", "6:10: Failed to evaluate override value", "9:13: Failed to evaluate override value",
                "ok", "ok", "6:17: invalid division by zero", "9:13: clamp called with low (5u) greater than high (2u)",
            ]
        )
    }

    /// Runs validateOverrides for each of `values` on a fresh module of `source`, with the validations `register` makes in the
    /// prepare scope.
    private static func validationResults(
        _ source: String,
        _ key: String,
        _ values: [Int32],
        register: @escaping @Sendable (inout ShaderModule, [StatementID]) -> Void
    ) -> [String] {
        onEvaluateThread {
            var results: [String] = []
            for value in values {
                var module = checkedModule(source)
                var overrideValues = OverrideValues()
                let storeType = variable(module, key).flatMap { module[$0].storeType }
                overrideValues.set(Name(key), storeType == module.types.i32Type ? .int32(value) : .uint32(UInt32(bitPattern: value)))
                ModuleState.withTestScope(&module) { module in
                    register(&module, statements(module, "main"))
                    results.append(
                        message(module.validateOverridesForTesting(specializationConstantKeys: [Name(key)], &overrideValues)) ?? "ok"
                    )
                }
            }
            return results
        }
    }

    /// The index access on the left-hand side (`lhs`) or right-hand side of the assignment `statement`.
    private static func indexAccess(_ module: borrowing ShaderModule, _ statement: StatementID, lhs: Bool) -> (ExpressionID, ExpressionID)?
    {
        guard case .assignmentStatement(let assignment) = module[statement].kind else {
            return nil
        }
        let access = lhs ? assignment.lhs : assignment.rhs
        guard case .indexAccessExpression(let indexAccess) = module[access].kind else {
            return nil
        }
        return (access, indexAccess.index)
    }

    // BoundsCheck.cpp:152-159 and :220-235; the results are the C++'s for the same pipelines on fresh modules.
    @Test
    func boundsCheckValidations() {
        let vector = Self.validationResults(
            """
            override i: i32;
            const v = vec4(1, 2, 3, 4);
            @group(0) @binding(0) var<storage, read_write> o: array<i32>;
            @compute @workgroup_size(1)
            fn main() {
                o[0] = v[i];
            }
            """,
            "i",
            [2, 5, -1]
        ) { module, body in
            guard let (access, index) = Self.indexAccess(module, body[0], lhs: false) else {
                Issue.record("no access")
                return
            }
            module.addOverrideValidationForTesting(boundsCheckOf: access, index: index, size: 4)
        }
        #expect(vector == ["ok", "6:11: index 5 out of bounds[0..3]", "6:11: index -1 out of bounds[0..3]"])

        let constantArray = Self.validationResults(
            """
            override i: i32;
            @group(0) @binding(0) var<storage, read_write> o: array<i32>;
            @compute @workgroup_size(1)
            fn main() {
                o[1] = array(1, 2, 3)[i];
            }
            """,
            "i",
            [2, 5, -1]
        ) { module, body in
            guard let (access, index) = Self.indexAccess(module, body[0], lhs: false) else {
                Issue.record("no access")
                return
            }
            module.addOverrideValidationForTesting(boundsCheckOf: access, index: index, constant: 3, sizeExpression: nil)
        }
        #expect(constantArray == ["ok", "5:11: index 5 out of bounds [0..2]", "5:11: index -1 out of bounds [0..2]"])

        let runtimeArray = Self.validationResults(
            """
            override i: i32;
            @group(0) @binding(0) var<storage, read_write> o: array<i32>;
            @compute @workgroup_size(1)
            fn main() {
                o[i] = 1;
            }
            """,
            "i",
            [2, -1]
        ) { module, body in
            guard let (access, index) = Self.indexAccess(module, body[0], lhs: true) else {
                Issue.record("no access")
                return
            }
            module.addOverrideValidationForTesting(boundsCheckOf: access, index: index, constant: nil, sizeExpression: nil)
        }
        #expect(runtimeArray == ["ok", "5:4: index -1 out of bounds"])

        let overrideSizedArray = Self.validationResults(
            """
            override n: u32 = 4;
            var<workgroup> w: array<i32, n>;
            @compute @workgroup_size(1)
            fn main() {
                w[0] = 1;
            }
            """,
            "n",
            [3, 0]
        ) { module, body in
            guard let (access, index) = Self.indexAccess(module, body[0], lhs: true), let count = arrayCount(module, "w") else {
                Issue.record("no access")
                return
            }
            module.addOverrideValidationForTesting(boundsCheckOf: access, index: index, constant: nil, sizeExpression: count)
        }
        #expect(overrideSizedArray == ["ok", "5:4: array count must be greater than 0"])
    }

    // GlobalVariableRewriter.cpp:1530-1537 (the workgroup check is sticky_s4's); the C++'s message.
    @Test
    func combinedPrivateSizeValidation() {
        let results = onEvaluateThread { () -> [String] in
            var module = checkedModule(
                """
                var<private> big: array<i32, 2048>;
                var<private> one: i32;
                @compute @workgroup_size(1)
                fn main() {
                    big[0] = one;
                }
                """
            )
            var results: [String] = []
            ModuleState.withTestScope(&module) { module in
                guard let big = variable(module, "big").flatMap({ module[$0].storeType }),
                    let one = variable(module, "one").flatMap({ module[$0].storeType }), let main = function(module, "main")
                else {
                    Issue.record("missing declarations")
                    return
                }
                module.addOverrideValidationForTesting(
                    combinedSizeOf: [big, one],
                    workgroup: false,
                    span: module.span(of: .function(main)),
                    limit: 8192
                )
                var values = OverrideValues()
                results.append(message(module.validateOverridesForTesting(specializationConstantKeys: [], &values)) ?? "ok")
            }
            return results
        }
        #expect(results == ["4:0: The combined byte size of all variables in the private address space exceeds 8192 bytes"])
    }

    // WGSLShaderModule.cpp:91-99.
    @Test
    func containsOverrideByIdOrName() {
        let results = onEvaluateThread { () -> [Bool] in
            let module = checkedModule(Self.keyedOverrides)
            return ["7", "a", "b", "c", "o", "07"].map { module.containsOverride(Name($0)) }
        }
        #expect(results == [true, false, true, true, false, false])
    }

    // GlobalVariableRewriter registers the operator validation of `m * o` (GlobalVariableRewriter.cpp:657-665), then packs
    // it in place for the packed matrix `m`, wrapping the binary in an IdentityExpression: the validation evaluates the
    // __pack call as its left operand and still caches the right operand, which the writer prints (the C++ for pipelines
    // {o: 2} and {o: 0}, shared or fresh module alike).
    @Test
    func validationOfAPackedBinaryExpression() {
        let transcript = replay(
            """
            override o: f32 = 1.0;
            @group(0) @binding(0) var<storage, read_write> m: mat3x3f;
            @compute @workgroup_size(1)
            fn main() {
                m = m * o;
            }
            """,
            [StickyPipeline("main", values: [("o", .float(2))]), StickyPipeline("main", values: [("o", .float(0))])],
            prepare: { module, entry in
                let body = statements(module, entry)
                guard body.count == 1, case .assignmentStatement(let assignment) = module[body[0]].kind,
                    case .binaryExpression(let product) = module[assignment.rhs].kind
                else {
                    Issue.record("unexpected statements")
                    return ModelledPrepare(specializationConstantKeys: ["o"])
                }
                packInPlace(&module, product.leftExpression, .unpack)
                module.addOverrideValidationForTesting(validationOfBinaryExpression: assignment.rhs, guards: [])
                packInPlace(&module, assignment.rhs, .pack)
                #expect(module[assignment.rhs].kind.tag == .identityExpression)
                return ModelledPrepare(specializationConstantKeys: ["o"], printedNodes: [product.rightExpression])
            }
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=0 msl=2. workgroupSize=1,1,1",
                "[shared #2] sizeForWorkgroupVariables=0 msl=0. workgroupSize=1,1,1",
                "[fresh #1] sizeForWorkgroupVariables=0 msl=2. workgroupSize=1,1,1",
                "[fresh #2] sizeForWorkgroupVariables=0 msl=0. workgroupSize=1,1,1",
            ]
        )
    }

    // MARK: The sticky sequences, against the C++ outputs

    // s1: sizeForWorkgroupVariables is computed before evaluation, so it is the previous pipeline's (shared) or one
    // element's (fresh); the MSL count is evaluated by generate.
    @Test
    func sticky_s1() {
        let transcript = replay(
            """
            override N: u32 = 4;
            var<workgroup> a: array<u32, N>;
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(64)
            fn main(@builtin(local_invocation_index) i: u32) {
                a[i] = i;
                workgroupBarrier();
                o[i] = a[63u - i];
            }
            """,
            [StickyPipeline("main", [("N", 4096)]), StickyPipeline("main", [("N", 8)]), StickyPipeline("main")],
            prepare: prepareWorkgroupArray(keys: ["N"])
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=16 msl=4096u workgroupSize=64,1,1",
                "[shared #2] sizeForWorkgroupVariables=16384 msl=8u workgroupSize=64,1,1",
                "[shared #3] sizeForWorkgroupVariables=32 msl=4u workgroupSize=64,1,1",
                "[fresh #1] sizeForWorkgroupVariables=16 msl=4096u workgroupSize=64,1,1",
                "[fresh #2] sizeForWorkgroupVariables=16 msl=8u workgroupSize=64,1,1",
                "[fresh #3] sizeForWorkgroupVariables=16 msl=4u workgroupSize=64,1,1",
            ]
        )
    }

    // s3: an override workgroup size.
    @Test
    func sticky_s3() {
        let transcript = replay(
            """
            override W: u32 = 1;
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(W)
            fn main(@builtin(local_invocation_index) i: u32) {
                o[i] = i;
            }
            """,
            [StickyPipeline("main", [("W", 64)]), StickyPipeline("main", [("W", 2)]), StickyPipeline("main")],
            prepare: { _, _ in ModelledPrepare(specializationConstantKeys: ["W"]) }
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=0 msl= workgroupSize=64,1,1",
                "[shared #2] sizeForWorkgroupVariables=0 msl= workgroupSize=2,1,1",
                "[shared #3] sizeForWorkgroupVariables=0 msl= workgroupSize=1,1,1",
                "[fresh #1] sizeForWorkgroupVariables=0 msl= workgroupSize=64,1,1",
                "[fresh #2] sizeForWorkgroupVariables=0 msl= workgroupSize=2,1,1",
                "[fresh #3] sizeForWorkgroupVariables=0 msl= workgroupSize=1,1,1",
            ]
        )
    }

    // s4: the count evaluated by the failed first pipeline makes the second report 32768.
    @Test
    func sticky_s4() {
        let transcript = replay(
            """
            override N: u32 = 4;
            override W: u32 = 1;
            var<workgroup> a: array<u32, N * 2>;
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(W * 2)
            fn main(@builtin(local_invocation_index) i: u32) {
                a[i] = i;
                workgroupBarrier();
                o[i] = a[i];
            }
            """,
            [
                StickyPipeline("main", [("N", 4096), ("W", 64)]), StickyPipeline("main", [("N", 8), ("W", 2)]),
                StickyPipeline("main"),
            ],
            prepare: prepareWorkgroupArray(keys: ["N", "W"])
        )
        let tooBig = "generate error: 6:0: The combined byte size of all variables in the workgroup address space exceeds 16384 bytes"
        #expect(
            transcript == [
                "[shared #1] \(tooBig)",
                "[shared #2] sizeForWorkgroupVariables=32768 msl=16u workgroupSize=4,1,1",
                "[shared #3] sizeForWorkgroupVariables=64 msl=8u workgroupSize=2,1,1",
                "[fresh #1] \(tooBig)",
                "[fresh #2] sizeForWorkgroupVariables=16 msl=16u workgroupSize=4,1,1",
                "[fresh #3] sizeForWorkgroupVariables=16 msl=8u workgroupSize=2,1,1",
            ]
        )
    }

    // s6: two entry points share `a`; only main1 uses N. The shared MSL differs only by the sticky helper flag.
    @Test
    func sticky_s6() {
        let transcript = replay(
            """
            override N: u32 = 4;
            var<workgroup> a: array<u32, N>;
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(64)
            fn main1(@builtin(local_invocation_index) i: u32) {
                a[i] = i;
                o[i] = a[i];
            }
            @compute @workgroup_size(64)
            fn main2(@builtin(local_invocation_index) i: u32) {
                let p = &a;
                o[i] = 1u;
            }
            """,
            [StickyPipeline("main1", [("N", 4096)]), StickyPipeline("main2")],
            prepare: { module, entry in
                guard entry == "main1" else {
                    return ModelledPrepare(specializationConstantKeys: [])
                }
                return prepareWorkgroupArray(keys: ["N"])(&module, entry)
            }
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=16 msl=4096u workgroupSize=64,1,1",
                "[shared #2] sizeForWorkgroupVariables=0 msl= workgroupSize=64,1,1",
                "[fresh #1] sizeForWorkgroupVariables=16 msl=4096u workgroupSize=64,1,1",
                "[fresh #2] sizeForWorkgroupVariables=0 msl= workgroupSize=64,1,1",
            ]
        )
    }

    // s7: the count's operator validation rejects a zero divisor in both modes.
    @Test
    func sticky_s7() {
        let transcript = replay(
            """
            override N: u32 = 8;
            override D: u32 = 2;
            var<workgroup> a: array<u32, N / D>;
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(64)
            fn main(@builtin(local_invocation_index) i: u32) {
                a[i] = i;
                o[i] = a[i];
            }
            """,
            [StickyPipeline("main", [("N", 64), ("D", 2)]), StickyPipeline("main", [("D", 0)])],
            prepare: prepareWorkgroupArray(keys: ["N", "D"])
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=16 msl=32u workgroupSize=64,1,1",
                "[shared #2] generate error: 3:31: invalid division by zero",
                "[fresh #1] sizeForWorkgroupVariables=16 msl=32u workgroupSize=64,1,1",
                "[fresh #2] generate error: 3:31: invalid division by zero",
            ]
        )
    }

    // s8: BoundsCheck skips the access cached by the first pipeline, so the shared module reports the evaluation failure
    // of the enclosing expression instead of the bounds error.
    @Test
    func sticky_s8() {
        let transcript = replay(
            """
            const arr = array(10u, 20u, 30u);
            override I: u32 = 0;
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(1)
            fn main() {
                o[0] = arr[I] / 1u;
            }
            """,
            [StickyPipeline("main", [("I", 1)]), StickyPipeline("main", [("I", 5)])],
            prepare: { module, entry in
                let body = statements(module, entry)
                guard body.count == 1, case .assignmentStatement(let assignment) = module[body[0]].kind,
                    case .binaryExpression(let quotient) = module[assignment.rhs].kind
                else {
                    Issue.record("unexpected statements")
                    return ModelledPrepare(specializationConstantKeys: ["I"])
                }
                registerConstantArrayBoundsCheck(&module, quotient.leftExpression)
                module.addOverrideValidationForTesting(ensuringOverrideValueOf: assignment.rhs, guards: [])
                module.addOverrideValidationForTesting(validationOfBinaryExpression: assignment.rhs, guards: [])
                return ModelledPrepare(specializationConstantKeys: ["I"], printedNodes: [assignment.rhs])
            }
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=0 msl=20u workgroupSize=1,1,1",
                "[shared #2] generate error: 6:18: Failed to evaluate override value",
                "[fresh #1] sizeForWorkgroupVariables=0 msl=20u workgroupSize=1,1,1",
                "[fresh #2] generate error: 6:11: index 5 out of bounds [0..2]",
            ]
        )
    }

    // s9: BoundsCheck and validateGlobal both skip the cached initializer, so the shared module accepts I=5 and keeps
    // printing the first pipeline's value.
    @Test
    func sticky_s9() {
        let transcript = replay(
            """
            const arr = array(10u, 20u, 30u);
            override I: u32 = 0;
            var<private> x: u32 = arr[I];
            @group(0) @binding(0) var<storage, read_write> o: array<u32>;
            @compute @workgroup_size(1)
            fn main() {
                o[0] = x;
            }
            """,
            [StickyPipeline("main", [("I", 1)]), StickyPipeline("main", [("I", 5)]), StickyPipeline("main", [("I", 2)])],
            prepare: { module, _ in
                guard let access = initializer(module, "x") else {
                    Issue.record("no initializer")
                    return ModelledPrepare(specializationConstantKeys: ["I"])
                }
                registerConstantArrayBoundsCheck(&module, access)
                // GlobalVariableRewriter.cpp:1237-1247
                if module.constantValueForGlobalValidation(access) == nil {
                    module.addOverrideValidationForTesting(ensuringOverrideValueOf: access, guards: [])
                }
                return ModelledPrepare(specializationConstantKeys: ["I"], printedNodes: [access])
            }
        )
        #expect(
            transcript == [
                "[shared #1] sizeForWorkgroupVariables=0 msl=20u workgroupSize=1,1,1",
                "[shared #2] sizeForWorkgroupVariables=0 msl=20u workgroupSize=1,1,1",
                "[shared #3] sizeForWorkgroupVariables=0 msl=20u workgroupSize=1,1,1",
                "[fresh #1] sizeForWorkgroupVariables=0 msl=20u workgroupSize=1,1,1",
                "[fresh #2] generate error: 3:22: index 5 out of bounds [0..2]",
                "[fresh #3] sizeForWorkgroupVariables=0 msl=30u workgroupSize=1,1,1",
            ]
        )
    }
}
