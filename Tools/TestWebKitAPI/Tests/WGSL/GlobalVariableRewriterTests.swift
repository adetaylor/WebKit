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

// GlobalVariableRewriter (GlobalVariableRewriter.cpp): the visitor hooks, the WTF hash-order sites A-D, the minBindingSize record
// point and the callee side-effect sequences of the iterative visitCallee (DEV-03). Unless a test says otherwise, each expected
// AST, layout and message is what the C++ printed after rewriteGlobalVariables for the same source and layout.

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

private func onCompileThreadIfNeeded<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in body() }
    }
    return body()
}

/// A minBindingSize the rewriter recorded into the explicit layout.
private struct Assignment: Equatable, Sendable {
    var bindGroupLayout: Int
    var entry: Int
    var size: UInt64
}

/// What rewriteGlobalVariables left in the module, the reflection and the explicit layout.
private struct Rewritten: Sendable {
    var error: String?
    var errorSpan: SourceSpan?
    var dump = ""
    /// The `@group` of each bind group layout of each entry point's default layout, in reflection order.
    var defaultLayoutGroups: [[UInt32]] = []
    /// In the order of their first assignment.
    var assignments: [Assignment] = []
    var overrideValidationsBefore = 0
    var overrideValidationsAfter = 0
    /// The parameter names of each function, by source name.
    var parameters: [String: [String]] = [:]
}

/// insertBoundsChecks, rewriteEntryPoints and rewriteGlobalVariables inside a CompilationScope, as prepare runs them (WGSL.cpp:145-147):
/// every entry point with a default layout (the `@all` unit), or `entryPoint` with the explicit `layout`.
private func rewrite(_ source: String, entryPoint: String? = nil, layout: PipelineLayout? = nil) -> Rewritten {
    onCompileThreadIfNeeded {
        guard var module = staticPasses(source) else {
            return Rewritten(error: "the static passes failed")
        }
        var pipelineLayouts = LookupMap<Name, Int?>()
        var explicitLayouts: [ExplicitPipelineLayout] = []
        if let entryPoint, let layout {
            _ = pipelineLayouts.add(Name(entryPoint), 0)
            explicitLayouts.append(ExplicitPipelineLayout(reading: layout, access: PipelineLayout.Access.self))
        } else {
            for entryPoint in module.callGraph.entrypoints {
                _ = pipelineLayouts.add(module.symbols.name(of: entryPoint.originalName), nil)
            }
        }
        var result = Rewritten()
        ModuleState.withTestScope(&module) { module in
            insertBoundsChecks(&module)
            rewriteEntryPoints(&module, pipelineLayouts)
            result.overrideValidationsBefore = module.currentOverrideValidationsSize
            var informations = Reflection.EntryPointInformations()
            if let error = rewriteGlobalVariables(&module, pipelineLayouts, &explicitLayouts, &informations) {
                result.error = String(decoding: error.utf16, as: UTF16.self)
                result.errorSpan = error.span
            }
            result.overrideValidationsAfter = module.currentOverrideValidationsSize
            result.dump = ASTStringDumper.dump(module)
            for information in informations.entries {
                result.defaultLayoutGroups.append(information.defaultLayout?.bindGroupLayouts.map(\.group) ?? [])
            }
            for declaration in module.elements(module.declarations) {
                guard case .function(let function) = declaration else {
                    continue
                }
                result.parameters[text(module, module[function].originalName)] = module.elements(module[function].parameters)
                    .map {
                        text(module, module[$0].name)
                    }
            }
        }
        if let explicitLayout = explicitLayouts.first {
            for address in explicitLayout.minBindingSizeAssignments {
                guard case .buffer(let buffer) = explicitLayout[address].bindingMember else {
                    continue
                }
                result.assignments.append(
                    Assignment(bindGroupLayout: address.bindGroupLayout, entry: address.entry, size: buffer.minBindingSize)
                )
            }
        }
        return result
    }
}

/// One storage buffer entry at binding 0 of each bind group layout, visible to compute with argument buffer index 0; `sizeIndex` gives
/// the argument buffer size index of the layouts that have one.
private func storageLayout(_ types: [BufferBindingType], sizeIndex: [Int: UInt32] = [:]) -> PipelineLayout {
    var layout = PipelineLayout()
    for (group, type) in types.enumerated() {
        let slots = StageSlots(argumentBufferIndex: 0, argumentBufferSizeIndex: sizeIndex[group])
        let entry = BindGroupLayoutEntry(
            binding: 0,
            webBinding: 0,
            visibility: [.compute],
            bindingMember: .buffer(BufferBindingLayout(type: type, hasDynamicOffset: false, minBindingSize: 0)),
            name: "",
            vertex: StageSlots(),
            fragment: StageSlots(),
            compute: slots
        )
        layout.bindGroupLayouts.append(BindGroupLayout(group: UInt32(group), entries: [entry]))
    }
    return layout
}

// MARK: - Sources

/// Every statement hook of the pass on a packed struct (the comments in `hooksAfter` say which hook wrote each line).
private let hooksSource = """
    struct S { v: vec3f, f: f32 }
    @group(0) @binding(0) var<storage, read_write> s: S;
    fn load() -> S { return s; }
    @compute @workgroup_size(1) fn main() {
      var t = load();
      s = t;
      s.v += vec3f(1);
      _ = s;
      let u = s;
      {
        let w = s;
      }
    }
    """

// visit(Function) appends `global0` to function0 (visitCallee); visit(Expression) unpacks the returned value (`return __unpack`);
// visit(VariableStatement) unpacks the initializers (`local1`, and `local2` inside the block, which visit(CompoundStatement) visits);
// visit(AssignmentStatement) packs the right-hand side (`__pack(local0)`); visit(CompoundAssignmentStatement) unpacks the left-hand
// side (`__unpack(global0.field0) +=`); visit(PhonyAssignmentStatement) packs nothing (`_ = global0`).
private let hooksAfter = [
    "struct type0 {",
    "    field0: vec3f,",
    "    field1: f32",
    "}",
    "",
    "@group(0) @binding(0) var<storage,read_write> global0: __type0_Packed;",
    "fn function0(",
    "    global0: __type0_Packed&",
    ") ->  type0",
    "{",
    "    return __unpack(global0);",
    "}",
    "",
    "@compute @workgroup_size(1)",
    "fn function1(",
    "    @group(0) __ArgumentBuffer_0: __ArgumentBufferT_0_0",
    ")",
    "{",
    "    var global0: __type0_Packed& = __ArgumentBuffer_0.global0;",
    "    var local0 = function0(global0);",
    "    global0 = __pack(local0);",
    "    __unpack(global0.field0) += vec3f(1);",
    "    _ = global0;",
    "    var local1 = __unpack(global0);",
    "    {",
    "        var local2 = __unpack(global0);",
    "    }",
    "",
    "}",
    "",
    "struct __type0_Packed {",
    "    field0: vec3f,",
    "    field1: f32",
    "}",
    "",
    "struct __ArgumentBufferT_0_0 {",
    "    @binding(0) global0: __type0_Packed&,",
    "    @binding(1) __global0_ArrayLength: u32&",
    "}",
    "",
    "",
]
.joined(separator: "\n")

/// The override is reached only through the resolved type of the parameter, so only visit(Parameter)'s recordTypeReads reads it.
private let parameterTypeSource = """
    override n: u32 = 4;
    alias A = array<f32, n>;
    var<workgroup> w: A;
    fn f(p: ptr<workgroup, A>) {}
    @compute @workgroup_size(1) fn main() { f(&w); }
    """

private let combinedSizeSource = """
    fn f() { var a: array<u32, 3000>; }
    @compute @workgroup_size(1) fn main() { f(); }
    """

/// Groups 0-4 inserted in order, group 4 with bindings 0, 3, 1.
private let groupsSource = """
    @group(0) @binding(0) var<storage, read_write> b0: u32;
    @group(1) @binding(0) var<storage, read_write> b1: u32;
    @group(2) @binding(0) var<storage, read_write> b2: u32;
    @group(3) @binding(0) var<storage, read_write> b3: u32;
    @group(4) @binding(0) var<storage, read_write> b4: u32;
    @group(4) @binding(3) var<storage, read_write> b5: u32;
    @group(4) @binding(1) var<storage, read_write> b6: u32;
    @compute @workgroup_size(1) fn main() { b0 = b1 + b2 + b3 + b4 + b5 + b6; }
    """

// Site A (`m_groupBindingMap`, never copied) orders the `__ArgumentBuffer_<g>` parameters and the argument buffer structs 0, 3, 2, 1, 4;
// site B (the copy made at GlobalVariableRewriter.cpp:1208) iterates the groups 1, 0, 3, 2, 4 and group 4's bindings 0, 3, 1, and each
// materialization is inserted at index 0, so they appear in the reverse order.
private let groupsAfter = [
    "@group(0) @binding(0) var<storage,read_write> global0: u32;",
    "@group(1) @binding(0) var<storage,read_write> global1: u32;",
    "@group(2) @binding(0) var<storage,read_write> global2: u32;",
    "@group(3) @binding(0) var<storage,read_write> global3: u32;",
    "@group(4) @binding(0) var<storage,read_write> global4: u32;",
    "@group(4) @binding(3) var<storage,read_write> global5: u32;",
    "@group(4) @binding(1) var<storage,read_write> global6: u32;",
    "@compute @workgroup_size(1)",
    "fn function0(",
    "    @group(0) __ArgumentBuffer_0: __ArgumentBufferT_0_0",
    "    @group(3) __ArgumentBuffer_3: __ArgumentBufferT_0_3",
    "    @group(2) __ArgumentBuffer_2: __ArgumentBufferT_0_2",
    "    @group(1) __ArgumentBuffer_1: __ArgumentBufferT_0_1",
    "    @group(4) __ArgumentBuffer_4: __ArgumentBufferT_0_4",
    ")",
    "{",
    "    var global6: u32& = __ArgumentBuffer_4.global6;",
    "    var global5: u32& = __ArgumentBuffer_4.global5;",
    "    var global4: u32& = __ArgumentBuffer_4.global4;",
    "    var global2: u32& = __ArgumentBuffer_2.global2;",
    "    var global3: u32& = __ArgumentBuffer_3.global3;",
    "    var global0: u32& = __ArgumentBuffer_0.global0;",
    "    var global1: u32& = __ArgumentBuffer_1.global1;",
    "    global0 = global1 + global2 + global3 + global4 + global5 + global6;",
    "}",
    "",
    "struct __ArgumentBufferT_0_0 {",
    "    @binding(0) global0: u32&,",
    "    @binding(1) __global0_ArrayLength: u32&",
    "}",
    "",
    "struct __ArgumentBufferT_0_3 {",
    "    @binding(0) global3: u32&,",
    "    @binding(1) __global3_ArrayLength: u32&",
    "}",
    "",
    "struct __ArgumentBufferT_0_2 {",
    "    @binding(0) global2: u32&,",
    "    @binding(1) __global2_ArrayLength: u32&",
    "}",
    "",
    "struct __ArgumentBufferT_0_1 {",
    "    @binding(0) global1: u32&,",
    "    @binding(1) __global1_ArrayLength: u32&",
    "}",
    "",
    "struct __ArgumentBufferT_0_4 {",
    "    @binding(0) global4: u32&,",
    "    @binding(1) global6: u32&,",
    "    @binding(2) global5: u32&,",
    "    @binding(3) __global4_ArrayLength: u32&,",
    "    @binding(4) __global5_ArrayLength: u32&,",
    "    @binding(5) __global6_ArrayLength: u32&",
    "}",
    "",
    "",
]
.joined(separator: "\n")

/// Five groups inserted in order: the copy at GlobalVariableRewriter.cpp:1208 iterates them 1, 0, 3, 2, 4.
private let fiveGroupsSource = """
    @group(0) @binding(0) var<storage, read_write> b0: array<u32, 4>;
    @group(1) @binding(0) var<storage, read_write> b1: array<u32, 4>;
    @group(2) @binding(0) var<storage, read_write> b2: array<u32, 4>;
    @group(3) @binding(0) var<storage, read_write> b3: array<u32, 4>;
    @group(4) @binding(0) var<storage, read_write> b4: array<u32>;
    @compute @workgroup_size(1) fn main() { b0[0] = b1[0] + b2[0] + b3[0] + b4[0]; }
    """

/// `k` is reached through `g` and through `h`: the second edge finds `k` already visited.
private let diamondSource = """
    @group(0) @binding(0) var<storage, read_write> buf: array<u32, 4>;
    fn k() -> u32 { return buf[0]; }
    fn g() -> u32 { return k(); }
    fn h() -> u32 { return k() + 1u; }
    @compute @workgroup_size(1) fn main() { buf[1] = g() + h(); }
    """

// `h` (function2) calls `function0(global0)`: the edge h -> k finds k visited and only appends its cached reads at h's call site.
private let diamondAfter = [
    "@group(0) @binding(0) var<storage,read_write> global0: array<u32, 4>;",
    "fn function0(",
    "    global0: array<u32, 4>&",
    ") ->  u32",
    "{",
    "    return global0[0];",
    "}",
    "",
    "fn function1(",
    "    global0: array<u32, 4>&",
    ") ->  u32",
    "{",
    "    return function0(global0);",
    "}",
    "",
    "fn function2(",
    "    global0: array<u32, 4>&",
    ") ->  u32",
    "{",
    "    return function0(global0) + 1u;",
    "}",
    "",
    "@compute @workgroup_size(1)",
    "fn function3(",
    "    @group(0) __ArgumentBuffer_0: __ArgumentBufferT_0_0",
    ")",
    "{",
    "    var global0: array<u32, 4>& = __ArgumentBuffer_0.global0;",
    "    global0[1] = function1(global0) + function2(global0);",
    "}",
    "",
    "struct __ArgumentBufferT_0_0 {",
    "    @binding(0) global0: array<u32, 4>&,",
    "    @binding(1) __global0_ArrayLength: u32&",
    "}",
    "",
    "",
]
.joined(separator: "\n")

// MARK: - Callee side effects: a recursive transcription of GlobalVariableRewriter.cpp:199-357

private struct SplitMix64 {
    var state: UInt64

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

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }
}

private enum CalleeArgument {
    case none
    case buffer(Int)
    case parameter
}

/// One statement of a generated body.
private enum CalleeStatement {
    /// `_ = p<k>;`
    case readPrivate(Int)
    /// `_ = arrayLength(&b<k>);`: reads `b<k>` and its length.
    case readBuffer(Int)
    /// `_ = arrayLength(a);`: adds `a` to the function's length parameters.
    case lengthOfParameter
    /// `_ = h<j>(…);`
    case call(Int, CalleeArgument)
    /// `var big: array<u32, 3000>;`: the function's variables exceed 8192 bytes, an error once its body has been visited.
    case bigVariable
}

/// Random modules of storage buffers, private globals, helpers and compute entry points.
///
/// Storage buffers `b<k>` are runtime-sized, so each has a `__<b>_ArrayLength` global; private globals are `p<k>`; helpers `h<i>` call
/// only `h<j>` with `j > i`, and about half of them take a storage pointer `a`; compute entry points `e<k>` call helpers. The helpers
/// form diamonds (one helper called from several callers, also from several entry points) and pass pointers on.
private struct CalleeModel {
    var bufferCount = 0
    var privateCount = 0
    var takesPointer: [Bool] = []
    var helpers: [[CalleeStatement]] = []
    var entryPoints: [[CalleeStatement]] = []

    init(_ random: inout SplitMix64) {
        bufferCount = 1 + random.below(3)
        privateCount = random.below(3)
        let helperCount = 1 + random.below(8)
        for _ in 0..<helperCount {
            takesPointer.append(random.chance(50))
        }
        for helper in 0..<helperCount {
            helpers.append(body(&random, caller: helper, firstCallee: helper + 1))
        }
        for _ in 0..<(1 + random.below(3)) {
            entryPoints.append(body(&random, caller: nil, firstCallee: 0))
        }
    }

    private func body(_ random: inout SplitMix64, caller: Int?, firstCallee: Int) -> [CalleeStatement] {
        let callerTakesPointer = caller.map { takesPointer[$0] } ?? false
        var body: [CalleeStatement] = []
        for _ in 0..<random.below(7) {
            let kind = random.below(10)
            if kind == 0 && privateCount > 0 {
                body.append(.readPrivate(random.below(privateCount)))
            } else if kind == 1 {
                body.append(.readBuffer(random.below(bufferCount)))
            } else if kind == 2 && callerTakesPointer {
                body.append(.lengthOfParameter)
            } else if firstCallee < takesPointer.count {
                let callee = firstCallee + random.below(takesPointer.count - firstCallee)
                var argument = CalleeArgument.none
                if takesPointer[callee] {
                    argument = callerTakesPointer && random.chance(50) ? .parameter : .buffer(random.below(bufferCount))
                }
                body.append(.call(callee, argument))
            }
        }
        if caller != nil && random.chance(5) {
            body.append(.bigVariable)
        }
        return body
    }

    var source: String {
        var lines: [String] = []
        for index in 0..<bufferCount {
            lines.append("@group(0) @binding(\(index)) var<storage, read_write> b\(index): array<u32>;")
        }
        for index in 0..<privateCount {
            lines.append("var<private> p\(index): u32;")
        }
        for (index, body) in helpers.enumerated() {
            let parameter = takesPointer[index] ? "a: ptr<storage, array<u32>, read_write>" : ""
            lines.append("fn h\(index)(\(parameter)) -> u32 {" + text(body) + " return 0u; }")
        }
        for (index, body) in entryPoints.enumerated() {
            lines.append("@compute @workgroup_size(1) fn e\(index)() {" + text(body) + " }")
        }
        return lines.joined(separator: "\n")
    }

    private func text(_ body: [CalleeStatement]) -> String {
        var text = ""
        for statement in body {
            switch statement {
            case .readPrivate(let index): text += " _ = p\(index);"
            case .readBuffer(let index): text += " _ = arrayLength(&b\(index));"
            case .lengthOfParameter: text += " _ = arrayLength(a);"
            case .call(let callee, .none): text += " _ = h\(callee)();"
            case .call(let callee, .buffer(let index)): text += " _ = h\(callee)(&b\(index));"
            case .call(let callee, .parameter): text += " _ = h\(callee)(a);"
            case .bigVariable: text += " var big: array<u32, 3000>;"
            }
        }
        return text
    }
}

/// An argument by the name at its base (getBase), and whether visitCallee put it in `m_doNotUnpack`.
private struct CalleeArgumentName: Equatable {
    var name: String
    var doNotUnpack = false
}

/// What the body visit of a function does that visitCallee depends on, in the real module's names.
private enum BodyEffect {
    /// readVariable of an identifier.
    case read(String)
    /// `m_lengthParameters.add(m_currentFunction, …)` (GlobalVariableRewriter.cpp:724).
    case lengthParameter(String)
    /// The packing of a call's arguments: its own arguments' reads, then every argument visitCallee appended that is not in
    /// `m_doNotUnpack`.
    case call(ExpressionID, reads: [String])
    case combinedSizeError
}

/// GlobalVariableRewriter.cpp:199-357 as written (recursive), with the body visit reduced to `BodyEffect`s, over the real call graph.
private struct CalleeTranscription {
    var callees: [FunctionID: [CallGraph.Callee]] = [:]
    var bodies: [FunctionID: [BodyEffect]] = [:]
    var globals = Set<String>()
    var parameters: [FunctionID: [String]] = [:]
    var arguments: [ExpressionID: [CalleeArgumentName]] = [:]
    var lengthParameters: [FunctionID: [String]] = [:]
    var visitedFunctions: [FunctionID: [String]] = [:]
    var reads: [String] = []
    var hasError = false
    /// Edges that found their target visited and appended non-empty cached reads.
    var revisitEdgesWithReads = 0
    var lengthArgumentsAppended = 0
    /// A length argument's parameter index is past the end of the call's arguments (only after an error): `call->arguments()[index]`
    /// is WTF::Vector::at, whose CrashOnOverflow kills the C++ (GlobalVariableRewriter.cpp:286), and the Swift traps there too.
    var crashes = false

    static func lengthName(_ name: String) -> String { "__" + name + "_ArrayLength" }

    mutating func run(_ entryPoints: [FunctionID]) {
        for entryPoint in entryPoints {
            reads = []
            visit(entryPoint)
            if hasError || crashes {
                return
            }
        }
    }

    private mutating func readVariable(_ name: String) {
        if globals.contains(name) && !reads.contains(name) {
            reads.append(name)
        }
    }

    private mutating func visitCallee(_ callee: CallGraph.Callee) {
        if let cached = visitedFunctions[callee.target] {
            reads = cached
            if !reads.isEmpty {
                revisitEdgesWithReads += 1
            }
            updateCallSites(callee)
            return
        }
        visit(callee.target)
        updateCallee(callee)
        updateCallSites(callee)
        visitedFunctions[callee.target] = reads
    }

    private mutating func updateCallee(_ callee: CallGraph.Callee) {
        for read in reads {
            parameters[callee.target, default: []].append(read)
        }
        for length in lengthParameters[callee.target] ?? [] {
            let lengthName = Self.lengthName(length)
            if reads.contains(lengthName) {
                continue
            }
            parameters[callee.target, default: []].append(lengthName)
        }
    }

    private mutating func updateCallSites(_ callee: CallGraph.Callee) {
        for read in reads {
            for callSite in callee.callSites {
                arguments[callSite.call, default: []].append(CalleeArgumentName(name: read, doNotUnpack: true))
            }
        }
        var pendingLengthParameters: [(caller: FunctionID, name: String)] = []
        for lengthParameter in lengthParameters[callee.target] ?? [] {
            let lengthName = Self.lengthName(lengthParameter)
            if reads.contains(lengthName) {
                continue
            }
            let targetParameters = parameters[callee.target] ?? []
            let index = targetParameters.firstIndex(of: lengthParameter) ?? targetParameters.count
            for callSite in callee.callSites {
                let callArguments = arguments[callSite.call] ?? []
                guard index < callArguments.count else {
                    crashes = true
                    return
                }
                let base = callArguments[index].name
                pendingLengthParameters.append((callSite.caller, base))
                arguments[callSite.call, default: []].append(CalleeArgumentName(name: Self.lengthName(base)))
                lengthArgumentsAppended += 1
            }
        }
        for (caller, name) in pendingLengthParameters where !(lengthParameters[caller] ?? []).contains(name) {
            lengthParameters[caller, default: []].append(name)
        }
    }

    private mutating func visit(_ function: FunctionID) {
        var functionReads: [String] = []
        for callee in callees[function] ?? [] {
            visitCallee(callee)
            if hasError {
                return
            }
            for read in reads where !functionReads.contains(read) {
                functionReads.append(read)
            }
        }
        reads = functionReads
        var combinedSizeError = false
        for effect in bodies[function] ?? [] {
            switch effect {
            case .read(let name):
                readVariable(name)
            case .lengthParameter(let name):
                if !(lengthParameters[function] ?? []).contains(name) {
                    lengthParameters[function, default: []].append(name)
                }
            case .call(let call, let argumentReads):
                for name in argumentReads {
                    readVariable(name)
                }
                for argument in arguments[call] ?? [] where !argument.doNotUnpack {
                    readVariable(argument.name)
                }
            case .combinedSizeError:
                combinedSizeError = true
            }
        }
        if combinedSizeError {
            hasError = true
        }
    }
}

/// The name at the base of an argument expression, as getBase finds it (GlobalVariableRewriter.cpp:808-828), for the expressions the
/// model produces.
private func baseName(_ module: borrowing ShaderModule, _ expression: ExpressionID) -> String {
    switch module[expression].kind {
    case .identifierExpression(let identifier): text(module, identifier.identifier)
    case .unaryExpression(let unary): baseName(module, unary.expression)
    case .identityExpression(let identity): baseName(module, identity.expression)
    default: "not an identifier"
    }
}

/// The outcome of comparing the real pass with the transcription on one model.
private struct CalleeComparison: Sendable {
    var differences: [String] = []
    var failedError = false
    var revisitEdgesWithReads = 0
    var lengthArgumentsAppended = 0
    var crashes = false
    var sharedAcrossEntryPoints = false
}

/// Runs the static passes, then both the transcription and the real prepare passes (every entry point with a default layout) on the
/// module of `model`, and compares the appended parameters, the appended call arguments and `m_lengthParameters`.
private func compareCalleeSideEffects(_ model: CalleeModel) -> CalleeComparison {
    var comparison = CalleeComparison()
    let source = model.source
    guard var module = staticPasses(source) else {
        comparison.differences.append("the static passes failed:\n\(source)")
        return comparison
    }

    var functions: [String: FunctionID] = [:]
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration {
            functions[text(module, module[function].originalName)] = function
        }
    }
    var variableNames: [String: String] = [:]
    for declaration in module.elements(module.declarations) {
        if case .variable(let variable) = declaration {
            variableNames[text(module, module[variable].originalName)] = text(module, module[variable].name)
        }
    }

    var transcription = CalleeTranscription()
    for index in 0..<model.bufferCount {
        let name = variableNames["b\(index)"] ?? "b\(index)"
        transcription.globals.insert(name)
        transcription.globals.insert(CalleeTranscription.lengthName(name))
    }
    for index in 0..<model.privateCount {
        transcription.globals.insert(variableNames["p\(index)"] ?? "p\(index)")
    }

    let entryPoints = module.callGraph.entrypoints.map(\.function)
    var reachable = Set<FunctionID>()
    for entryPoint in entryPoints {
        reachable.formUnion(module.callGraph.calleesFirstOrder(from: entryPoint))
    }
    let bodies =
        model.helpers.enumerated().map { ("h\($0.offset)", $0.element) }
        + model.entryPoints.enumerated().map { ("e\($0.offset)", $0.element) }
    for (name, body) in bodies {
        guard let function = functions[name] else {
            comparison.differences.append("no function \(name)")
            return comparison
        }
        let parameterNames = module.elements(module[function].parameters).map { text(module, module[$0].name) }
        transcription.parameters[function] = parameterNames
        guard reachable.contains(function) else {
            continue
        }
        let callees = module.callGraph.callees(function)
        transcription.callees[function] = callees
        var callIndices: [FunctionID: Int] = [:]
        var effects: [BodyEffect] = []
        for statement in body {
            switch statement {
            case .readPrivate(let index):
                effects.append(.read(variableNames["p\(index)"] ?? ""))
            case .readBuffer(let index):
                let buffer = variableNames["b\(index)"] ?? ""
                effects.append(.read(buffer))
                effects.append(.read(CalleeTranscription.lengthName(buffer)))
            case .lengthOfParameter:
                effects.append(.lengthParameter(parameterNames.first ?? ""))
            case .call(let calleeIndex, let argument):
                guard let target = functions["h\(calleeIndex)"],
                    let callee = callees.first(where: { $0.target == target })
                else {
                    comparison.differences.append("no callee record for h\(calleeIndex) in \(name)")
                    return comparison
                }
                let callIndex = callIndices[target, default: 0]
                callIndices[target] = callIndex + 1
                let call = callee.callSites[callIndex].call
                var argumentNames: [CalleeArgumentName] = []
                var argumentReads: [String] = []
                switch argument {
                case .none:
                    break
                case .buffer(let index):
                    let buffer = variableNames["b\(index)"] ?? ""
                    argumentNames.append(CalleeArgumentName(name: buffer))
                    argumentReads.append(buffer)
                case .parameter:
                    argumentNames.append(CalleeArgumentName(name: parameterNames.first ?? ""))
                }
                transcription.arguments[call] = argumentNames
                effects.append(.call(call, reads: argumentReads))
            case .bigVariable:
                effects.append(.combinedSizeError)
            }
        }
        transcription.bodies[function] = effects
    }
    transcription.run(entryPoints)
    comparison.revisitEdgesWithReads = transcription.revisitEdgesWithReads
    comparison.lengthArgumentsAppended = transcription.lengthArgumentsAppended
    // The real pass traps here as the C++ does (wgsl-trap-tests --run GVRLengthArgumentPastTheEndAfterAnError).
    comparison.crashes = transcription.crashes
    if transcription.crashes {
        return comparison
    }
    for (name, _) in bodies where name.hasPrefix("h") {
        var callers = Set<FunctionID>()
        if let function = functions[name] {
            for entryPoint in entryPoints where module.callGraph.calleesFirstOrder(from: entryPoint).contains(function) {
                callers.insert(entryPoint)
            }
        }
        if callers.count > 1 {
            comparison.sharedAcrossEntryPoints = true
        }
    }

    var pipelineLayouts = LookupMap<Name, Int?>()
    for entryPoint in module.callGraph.entrypoints {
        _ = pipelineLayouts.add(module.symbols.name(of: entryPoint.originalName), nil)
    }
    ModuleState.withTestScope(&module) { module in
        insertBoundsChecks(&module)
        rewriteEntryPoints(&module, pipelineLayouts)
        var explicitLayouts: [ExplicitPipelineLayout] = []
        var informations = Reflection.EntryPointInformations()
        var lengthParameters: [(function: FunctionID, names: [Symbol])] = []
        let error = rewriteGlobalVariablesForTesting(
            &module,
            pipelineLayouts,
            &explicitLayouts,
            &informations,
            lengthParameters: &lengthParameters
        )
        comparison.failedError = error != nil
        if (error != nil) != transcription.hasError {
            comparison.differences.append("error: \(error.map { String(decoding: $0.utf16, as: UTF16.self) } ?? "none")")
        }

        for (name, _) in bodies where name.hasPrefix("h") {
            guard let function = functions[name] else {
                continue
            }
            let actual = module.elements(module[function].parameters).map { text(module, module[$0].name) }
            if actual != transcription.parameters[function] ?? [] {
                comparison.differences.append("\(name) parameters \(actual), transcription \(transcription.parameters[function] ?? [])")
            }
        }
        for (call, expected) in transcription.arguments {
            let actual = module.elements(module.downcast(CallExpression.self, call).arguments).map { baseName(module, $0) }
            if actual != expected.map(\.name) {
                comparison.differences.append("call arguments \(actual), transcription \(expected.map(\.name))")
            }
        }
        var actualLengthParameters: [FunctionID: [String]] = [:]
        for entry in lengthParameters {
            actualLengthParameters[entry.function] = entry.names.map { text(module, $0) }
        }
        if actualLengthParameters != transcription.lengthParameters {
            comparison.differences.append("m_lengthParameters \(actualLengthParameters), transcription \(transcription.lengthParameters)")
        }
    }
    if !comparison.differences.isEmpty {
        comparison.differences.insert(source, at: 0)
    }
    return comparison
}

// MARK: - Tests

@Suite
struct WGSLGlobalVariableRewriterTests {
    // MARK: Hooks
    //
    // visit(Variable) (GlobalVariableRewriter.cpp:379-384) is not exercised: only AST::Visitor::visit(VariableStatement&), which the pass
    // overrides without calling it, and the declaration loop of AST::Visitor::visit(ShaderModule&), which the pass never runs, reach it.

    @Test
    func statementAndExpressionHooksPackAndUnpack() {
        let result = rewrite(hooksSource)
        #expect(result.error == nil)
        #expect(result.dump == hooksAfter)
    }

    @Test
    func parameterHookRecordsTheReadsOfItsType() {
        let result = rewrite(parameterTypeSource)
        #expect(result.error == nil)
        #expect(result.parameters["f"] == ["parameter0", "global0"])
    }

    @Test
    func functionHookChecksTheCombinedVariableSize() {
        let result = rewrite(combinedSizeSource)
        #expect(result.error == "The combined byte size of all variables in this function exceeds 8192 bytes")
        #expect(result.errorSpan == SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 36))
    }

    // MARK: WTF iteration order

    @Test
    func siteAOrdersTheDefaultLayoutAndTheArgumentBuffers() {
        let result = rewrite(groupsSource)
        #expect(result.error == nil)
        #expect(result.defaultLayoutGroups == [[0, 3, 2, 1, 4]])
        #expect(result.dump == groupsAfter)
    }

    @Test
    func siteBMaterializesInTheReverseOfTheCopiedOrder() {
        let result = rewrite(groupsSource)
        let materializations = result.dump.split(separator: "\n").filter { $0.contains("= __ArgumentBuffer_") }
            .map {
                String($0.split(separator: ":")[0].split(separator: " ")[1])
            }
        #expect(materializations == ["global6", "global5", "global4", "global2", "global3", "global0", "global1"])
    }

    @Test
    func siteCReportsTheFirstErrorInTheCopiedOrder() {
        // Group 0 is read-only (an access mode error), group 1 uniform (an address space error): the copy iterates group 1 first.
        let layout = storageLayout([.readOnlyStorage, .uniform, .storage, .storage, .storage], sizeIndex: [4: 1])
        let result = rewrite(fiveGroupsSource, entryPoint: "main", layout: layout)
        #expect(result.error == "Shader is incompatible with layout pipeline: variableAddressSpace != entryAddressSpace")
        #expect(result.errorSpan == SourceSpan.empty)
    }

    @Test
    func siteDRegistersNoValidationForResources() {
        // validateUsedGlobals (GlobalVariableRewriter.cpp:1236-1257) iterates the copied resources, but a resource has no initializer,
        // so the order in which it would register validations cannot be observed: the only two validations are determineUsedGlobals'
        // combined workgroup and private size checks (:1521-1536).
        let result = rewrite(groupsSource)
        #expect(result.error == nil)
        #expect(result.overrideValidationsAfter - result.overrideValidationsBefore == 2)
    }

    // MARK: minBindingSize record point (GlobalVariableRewriter.cpp:2422-2423)

    @Test
    func minBindingSizesAreRecordedInTheCopiedOrder() {
        // The runtime-sized array counts one element. The C++ write-back gives the same values.
        let layout = storageLayout([.storage, .storage, .storage, .storage, .storage], sizeIndex: [4: 1])
        let result = rewrite(fiveGroupsSource, entryPoint: "main", layout: layout)
        #expect(result.error == nil)
        #expect(
            result.assignments == [
                Assignment(bindGroupLayout: 1, entry: 0, size: 16),
                Assignment(bindGroupLayout: 0, entry: 0, size: 16),
                Assignment(bindGroupLayout: 3, entry: 0, size: 16),
                Assignment(bindGroupLayout: 2, entry: 0, size: 16),
                Assignment(bindGroupLayout: 4, entry: 0, size: 4),
            ]
        )
    }

    @Test
    func minBindingSizesAreRecordedUpToTheFirstIncompatibleEntry() {
        // Group 3 comes third in the copied order: groups 1 and 0 are recorded before its error, groups 2 and 4 never are.
        let layout = storageLayout([.storage, .storage, .storage, .uniform, .storage], sizeIndex: [4: 1])
        let result = rewrite(fiveGroupsSource, entryPoint: "main", layout: layout)
        #expect(result.error == "Shader is incompatible with layout pipeline: variableAddressSpace != entryAddressSpace")
        #expect(
            result.assignments == [Assignment(bindGroupLayout: 1, entry: 0, size: 16), Assignment(bindGroupLayout: 0, entry: 0, size: 16)]
        )
    }

    @Test
    func minBindingSizeIsNotRecordedForAnUnusedEntry() {
        // Only the entry point's used resources are iterated; `b4` is not read by `other`.
        let source = fiveGroupsSource + "\n@compute @workgroup_size(1) fn other() { b0[0] = b1[0]; }"
        let layout = storageLayout([.storage, .storage, .storage, .storage, .storage], sizeIndex: [4: 1])
        let result = rewrite(source, entryPoint: "other", layout: layout)
        #expect(result.error == nil)
        #expect(
            result.assignments == [Assignment(bindGroupLayout: 0, entry: 0, size: 16), Assignment(bindGroupLayout: 1, entry: 0, size: 16)]
        )
    }

    // MARK: Callee side effects

    @Test
    func diamondRevisitEdgeAppendsTheCachedReads() {
        let result = rewrite(diamondSource)
        #expect(result.error == nil)
        #expect(result.dump == diamondAfter)
        #expect(result.parameters["k"] == ["global0"])
        #expect(result.parameters["h"] == ["global0"])
    }

    @Test
    func calleeSideEffectsMatchARecursiveTranscription() {
        struct Outcome: Sendable {
            var differences: [String] = []
            var errors = 0
            var revisitEdgesWithReads = 0
            var lengthArgumentsAppended = 0
            var crashes = 0
            var sharedAcrossEntryPoints = 0
        }
        let outcome = onCompileThreadIfNeeded {
            var random = SplitMix64(state: 0x4756_5243_414c_4c45)
            var outcome = Outcome()
            for _ in 0..<1000 {
                let comparison = compareCalleeSideEffects(CalleeModel(&random))
                outcome.differences += comparison.differences
                outcome.errors += comparison.failedError ? 1 : 0
                outcome.revisitEdgesWithReads += comparison.revisitEdgesWithReads
                outcome.lengthArgumentsAppended += comparison.lengthArgumentsAppended
                outcome.crashes += comparison.crashes ? 1 : 0
                outcome.sharedAcrossEntryPoints += comparison.sharedAcrossEntryPoints ? 1 : 0
                if outcome.differences.count > 20 {
                    break
                }
            }
            return outcome
        }
        #expect(outcome.differences.isEmpty, "\(outcome.differences.joined(separator: "\n"))")
        // The models reach every path: the error stop, revisit edges with cached reads, length arguments, helpers shared by entry
        // points, and the C++ crash on a length argument past the end after an error (those models are not run).
        #expect(outcome.errors >= 50)
        #expect(outcome.revisitEdgesWithReads >= 500)
        #expect(outcome.lengthArgumentsAppended >= 500)
        #expect(outcome.crashes > 0)
        #expect(outcome.sharedAcrossEntryPoints >= 200)
    }
}
