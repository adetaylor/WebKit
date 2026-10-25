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

// The writer's visitor hooks and the spellings of the bounds-check clamp. Each expected fragment is from the C++ MSL of the same
// source (every entry point with its default layout, family 4 unless a test says otherwise),
// chosen so that the default traversal, which visits the node's children instead, would print something else.

private enum Generation: Sendable {
    case msl(String)
    case failed(String)
}

private func generated(_ source: String, _ deviceState: DeviceState, _ sourceLocation: SourceLocation) -> String {
    let generation = onCompileThread { compileThread -> Generation in
        switch compileThread.staticCheck(wtfSource(source)) {
        case .failure(let failedCheck):
            return .failed(failedCheck.errors.map(\.dumpDescription).joined(separator: "\n"))
        case .success(let checked):
            switch compileThread.prepare(checked) {
            case .failed(let error, _):
                return .failed(error.dumpDescription)
            case .prepared(let prepared):
                switch compileThread.generate(prepared, deviceState) {
                case .generated(let library, _):
                    return .msl(library.msl.string)
                case .failed(let error, _):
                    return .failed(error.dumpDescription)
                }
            }
        }
    }
    switch generation {
    case .msl(let msl):
        return msl
    case .failed(let message):
        Issue.record("compilation failed: \(message)", sourceLocation: sourceLocation)
        return ""
    }
}

/// Every fragment occurs in `msl`, compared as UTF-8 bytes.
private func expectFragments(_ msl: String, _ fragments: [(hook: String, text: String)], sourceLocation: SourceLocation = #_sourceLocation)
{
    let bytes = Array(msl.utf8)
    for fragment in fragments {
        let needle = Array(fragment.text.utf8)
        var found = false
        var start = 0
        while !found && start + needle.count <= bytes.count {
            found = bytes[start..<start + needle.count].elementsEqual(needle)
            start += 1
        }
        #expect(found, "\(fragment.hook): \"\(fragment.text)\" not in the MSL", sourceLocation: sourceLocation)
    }
}

private let statementsSource = """
    fn callee(p: ptr<function, i32>, q: f32) -> i32 {
        return *p + i32(q);
    }

    fn sink(p: ptr<function, i32>) {
        *p = 8;
    }

    @compute @workgroup_size(7, 11, 13)
    fn main(@builtin(local_invocation_index) li: u32) {
        var a = i32(li);
        var b = 2;
        a = b;
        a += b;
        a++;
        b--;
        {
            _ = a;
        }
        if (a > 3) {
            b = 4;
        } else {
            b = 5;
        }
        for (var i = 0; i < a; i++) {
            if (i == 2) {
                continue;
            }
            if (i == 3) {
                break;
            }
        }
        loop {
            if (a > 100) {
                break;
            }
            continuing {
                a = a + 9;
                break if a > 50;
            }
        }
        while (b < 10) {
            b += 1;
        }
        switch (b) {
            case 1: {
                a = 6;
            }
            default: {
                a = 7;
            }
        }
        _ = callee(&a, f32(b));
        const_assert 12345 > 0;
        sink(&a);
        let n = -a;
        let m = !(a > b);
    }

    @fragment
    fn fs(@builtin(position) position: vec4f) -> @location(0) vec4f {
        if (position.x > 1.0) {
            discard;
        }
        return position;
    }
    """

private let declarationsSource = """
    struct VertexOut {
        @builtin(position) @invariant position: vec4f,
        @location(3) @interpolate(flat) value: u32,
        @location(4) @interpolate(linear, centroid) other: f32,
    }

    struct Big {
        @size(4096) first: f32,
        @align(1024) second: vec4f,
    }

    @group(0) @binding(5) var<storage, read> big: Big;

    @vertex
    fn vs(@location(2) input: vec4f) -> VertexOut {
        var out: VertexOut;
        out.position = input + big.second;
        out.value = 1u;
        out.other = big.first;
        return out;
    }

    @fragment
    fn fs(@location(3) @interpolate(flat) value: u32) -> @location(1) vec4f {
        return vec4f(f32(value));
    }
    """

// The bounds-check self-test inputs: a runtime-sized array (codegen1Source) and a fixed-size array (shift1Source).
private let codegen1Source = """
    struct S { a: vec3f, b: f32, c: vec2f, };
    struct T { s: array<S, 2>, m: mat3x3f, x: u32, };
    @group(0) @binding(0) var<storage, read_write> buf: T;
    @group(0) @binding(1) var<storage, read_write> rt: array<vec3f>;
    @group(0) @binding(2) var<uniform> u: vec4u;
    var<workgroup> wg: array<atomic<u32>, 4>;
    var<private> pv: S;
    @compute @workgroup_size(4) fn main(@builtin(local_invocation_index) li: u32) {
      var i: i32 = i32(u.x);
      let sh = u.y;
      buf.x = (u.z << sh) >> sh;
      i = i + 2147483647;
      i = -i;
      var t: T;
      t.s[u.w].a = vec3f(1.0);
      buf = t;
      rt[u.x] = vec3f(f32(arrayLength(&rt)));
      loop { if (i > 3) { break; } i++; }
      atomicAdd(&wg[u.x], 1u);
      buf.x = u.x / u.y + u.x % u.z;
      buf.s[0].b = f32(i32(buf.s[1].b));
    }
    """

private let shift1Source = """
    @group(0) @binding(0) var<storage, read_write> buf: array<u32>;
    @group(0) @binding(1) var<storage, read> amt: vec4<u32>;
    var<private> arr: array<u32, 8>;

    @compute @workgroup_size(1)
    fn main() {
        let s = amt.x;
        // index derived from an over-wide runtime shift
        let i = 1u << s;
        let j = 0x80000000u >> s;
        let k = (-2147483647i - 1i) >> s;
        buf[i] = 1u;
        arr[j] = 2u;
        buf[u32(k)] = arr[j];
        var x = amt.y;
        x <<= s;
        buf[0] = x;
    }
    """

/// The module of `source` after the static passes, for the white-box tests.
private func checkedModule(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) -> StaticCheckTestingOutcome {
    let outcome = staticCheckForTesting(wtfSource(source), configuration: testsConfiguration, stopAfter: .uniformityAnalysis)
    if let failure = outcome.failure {
        logCompilationError(failure, sourceLocation: sourceLocation)
    }
    return outcome
}

private func text(_ bytes: ContiguousArray<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
}

@Suite
struct WGSLMetalFunctionWriterTests {
    // The runtime-sized array's clamp is byte-identical to C++ and Metal compiles it.
    @Test
    func secRuntimeArrayClampSpelling() {
        testCompilation(
            codegen1Source,
            checkLiteral("global1[__wgslMin(unsigned(global2.x), (__wgslDiv(__global1_ArrayLength, 16u) - 1u))]")
        )
        testCompilationForAppleGPUFamily(
            9,
            codegen1Source,
            checkLiteral("global1[__wgslMin(unsigned(global2.x), (__wgslDiv(__global1_ArrayLength, 16u) - 1u))]")
        )
    }

    // The fixed-size array's clamp.
    @Test
    func secFixedSizeClampSpelling() {
        testCompilation(
            shift1Source,
            checkLiteral("global2[__wgslMin(local2, (8u - 1u))] = 2u;"),
            checkLiteral(
                "global0[__wgslMin(unsigned(local3), (__wgslDiv(__global0_ArrayLength, 4u) - 1u))] = global2[__wgslMin(local2, (8u - 1u))];"
            )
        )
    }

    @Test
    func statementHooksFire() {
        let msl = generated(statementsSource, DeviceState(), #_sourceLocation)
        expectFragments(
            msl,
            [
                ("AssignmentStatement", "    local0 = local1;\n"),
                ("CompoundAssignmentStatement", "    local0 = (local0 + local1);\n"),
                ("DecrementIncrementStatement", "    local0++;\n    local1--;\n"),
                ("CompoundStatement, PhonyAssignmentStatement", "    {\n        (void)(local0);\n    }\n"),
                ("IfStatement", "    if ((local0 > 3)) {\n        local1 = 4;\n    } else {\n        local1 = 5;\n    }\n"),
                ("ForStatement", "for (int local2 = 0; (local2 < local0); local2++) {"),
                ("ContinueStatement", "        if ((local2 == 2)) {\n            continue;\n        }\n"),
                ("BreakStatement", "        if ((local2 == 3)) {\n            break;\n        }\n"),
                ("LoopStatement", "while (true) {"),
                (
                    "Continuing",
                    "        {\n            local0 = (local0 + 9);\n            if ((local0 > 50))\n                break;\n        }\n"
                ),
                ("WhileStatement", "while ((local1 < 10)) {"),
                ("SwitchStatement", "    switch (local1) {\n    case 1: {\n        local0 = 6;\n    }\n        break;\n    default: {\n"),
                ("ConstAssertID (prints nothing)", "    (void)(function0((&local0), float(local1)));\n    \n    function1((&local0));\n"),
                ("CallStatement", "    function1((&local0));\n"),
                ("ReturnStatement", "    return ((*parameter0) + __wgslFtoi<int>(parameter1));\n"),
                ("DiscardStatement", "    if ((parameter4.x > 1.)) {\n"),
            ]
        )
        #if arch(x86_64)
        // DEV-11: MetalFunctionWriter.cpp:3313-3317 under CPU(X86_64).
        expectFragments(msl, [("DiscardStatement", "        __asm volatile(\"\"); discard_fragment();\n")])
        #else
        expectFragments(msl, [("DiscardStatement", "        discard_fragment();;\n")])
        #endif
        #expect(!msl.contains("12345"))
    }

    @Test
    func declarationAndAttributeHooksFire() {
        let msl = generated(declarationsSource, DeviceState(), #_sourceLocation)
        expectFragments(
            msl,
            [
                ("StructureID, InterpolateAttribute", "struct type0 {\n    vec<float, 4> field0  ;\n    unsigned field1  [[flat]];\n"),
                ("InterpolateAttribute", "    float field2  [[centroid_no_perspective]];\n"),
                ("SizeAttribute (prints nothing)", "struct type1 {\n    float field3 ;\n"),
                ("AlignAttribute (prints nothing)", "    vec<float, 4> field4 ;\n"),
                ("BuiltinAttribute, InvariantAttribute", "    vec<float, 4> field0 [[position]] [[invariant]];\n"),
                ("LocationAttribute (vertex output)", "    unsigned field1 [[user(loc3)]] [[flat]];\n"),
                ("LocationAttribute (vertex input)", "    vec<float, 4> parameter0 [[attribute(2)]];\n"),
                ("LocationAttribute (fragment output)", "    vec<float, 4> __value [[color(1)]];\n"),
                (
                    "BindingAttribute",
                    "    const device __type1_Packed& global0 [[id(0)]];\n    unsigned __global0_ArrayLength [[id(1)]];\n"
                ),
                (
                    "StageAttribute, ParameterID, GroupAttribute",
                    "[[vertex]] __type0_VertexOutput function0(__function0_inT __function0_in [[stage_in]], "
                        + "constant __ArgumentBufferT_0_0& __ArgumentBuffer_0 [[buffer(7)]])\n"
                ),
                ("VariableID", "    type0 local0 { };\n"),
                ("FieldAccessExpression", "    local0.field0 = (parameter0 + global0.field4);\n"),
                ("StageAttribute", "[[fragment]] __function1_FragmentOutput function1(__function1_inT __function1_in [[stage_in]])\n"),
            ]
        )
        #expect(!msl.contains("4096"))
        #expect(!msl.contains("1024"))
    }

    @Test
    func expressionHooksFire() {
        let msl = generated(statementsSource, DeviceState(), #_sourceLocation)
        expectFragments(
            msl,
            [
                ("ParameterID", "int function0(thread int* parameter0, float parameter1)\n"),
                ("PointerDereferenceExpression", "    (*parameter2) = 8;\n"),
                ("UnaryExpression", "    int local3 = (-local0);\n    bool local4 = (!(local0 > local1));\n"),
                ("BinaryExpression, IdentifierExpression", "(local0 + local1)"),
                (
                    "WorkgroupSizeAttribute (prints nothing)",
                    "[[kernel]]  void function2(unsigned parameter3 [[thread_index_in_threadgroup]])\n"
                ),
            ]
        )
        let clamped = generated(shift1Source, DeviceState(), #_sourceLocation)
        expectFragments(clamped, [("CheckedIndexAccessExpression", "    global2[__wgslMin(local2, (8u - 1u))] = 2u;\n")])
    }

    // A swizzle spelled with letters whose low byte is a component (TypeCheck.cpp:2174) keeps its source text in the MSL, as
    // C++ prints it; Metal then rejects the member name.
    @Test
    func fieldAccessPrintsANonASCIISwizzleAsCxxDoes() {
        let source = """
            @group(0) @binding(0) var<storage, read_write> o: array<vec4f>;
            @compute @workgroup_size(1)
            fn main() {
                var v = o[0];
                o[1].x = v.\u{0178};
                o[2] = v.\u{0178}\u{0178}yx;
                o[3] = vec4f(v.\u{2E078}, v.\u{0161}g);
            }
            """
        let msl = generated(source, DeviceState(), #_sourceLocation)
        expectFragments(
            msl,
            [
                ("FieldAccessExpression", "].x = local0.\u{0178};\n"),
                ("FieldAccessExpression", "] = local0.\u{0178}\u{0178}yx;\n"),
                ("FieldAccessExpression", "] = vec<float, 4>(local0.\u{2E078}, local0.\u{0161}g);\n"),
            ]
        )
    }

    // The literal hooks print a literal that has no constant value (the writer prints a constant-valued one with
    // serializeConstant), as for a node a pass builds.
    @Test
    func literalHooksFire() {
        var outcome = checkedModule("fn f() {}")
        var printed: [String] = []
        ModuleState.withTestScope(&outcome.shaderModule) { module in
            var requests: [MetalTypesTestRequest] = []
            func add<P: PlainExpressionPayload>(_ payload: P, _ type: TypeID) {
                let literal = module.construct(span: .empty, payload)
                module.setInferredType(type, for: literal)
                requests.append(.expression(literal))
            }
            add(BoolLiteral(value: true), module.types.boolType)
            add(BoolLiteral(value: false), module.types.boolType)
            add(AbstractIntegerLiteral(value: -5), module.types.i32Type)
            add(AbstractIntegerLiteral(value: 5), module.types.u32Type)
            add(Signed32Literal(value: Int32.min), module.types.i32Type)
            add(Unsigned32Literal(value: UInt32.max), module.types.u32Type)
            add(AbstractFloatLiteral(value: 2.0), module.types.abstractFloatType)
            add(AbstractFloatLiteral(value: 0.5), module.types.abstractFloatType)
            add(Float32Literal(value: 1e-7), module.types.f32Type)
            add(Float16Literal(value: Half(Float(0.1))), module.types.f16Type)
            for request in requests {
                printed.append(text(writeTypesForTesting([request], &module).body))
            }
        }
        #expect(
            printed == [
                "true", "false", "-5", "5u", "-2147483648", "4294967295u", "2.", "0.5", "1.0000000116860974e-7", "0.0999755859375",
            ]
        )
    }

    // The visitor's declaration dispatch reaches the writer's structure, variable and const_assert hooks.
    @Test
    func declarationHooksFire() {
        var outcome = checkedModule(
            """
            struct S { a: f32, @size(16) b: u32 }
            var<private> v: i32 = 3;
            const_assert 12345 > 0;
            @compute @workgroup_size(1) fn main() { _ = S(); _ = v; }
            """
        )
        var printed: [String] = []
        ModuleState.withTestScope(&outcome.shaderModule) { module in
            for declaration in module.elements(module.declarations) {
                switch declaration {
                case .structure, .variable, .constAssert:
                    printed.append(text(emitDeclarationForTesting(declaration, &module, DeviceState())))
                case .function, .typeAlias:
                    break
                }
            }
        }
        #expect(printed == ["struct type0 {\n    float field0;\n    unsigned field1 ;\n};\n\n", "int global0 = 3", ""])
    }

    // DEV-26: a @builtin(clip_distances) member that is not an array (possible only in a structure that no entry point uses) is
    // written as an ordinary member, and Metal compiles it; C++ has undefined behaviour there.
    @Test
    func DEV_26_aClipDistancesMemberThatIsNotAnArrayIsAnOrdinaryMember() {
        testCompilation(
            """
            enable clip_distances;
            struct S {
              @builtin(clip_distances) value : array<f32,4>,
              @builtin(clip_distances) position : vec4<f32>,
            }
            """,
            checkLiteral("struct type0 {\n    float field0  [4];\n    vec<float, 4> field1 ;\n};\n")
        )
        testCompilation(
            """
            struct S {
              @builtin(clip_distances) value : f32,
            }
            @compute @workgroup_size(1) fn main() { }
            """,
            checkLiteral("struct type0 {\n    float field0 ;\n};\n")
        )
    }

    // DEV-26: the stage output constructor initialises a clip_distances member that is not an array (which IOValidator keeps out of
    // stage outputs) in its initializer list, as any other member, and copies only the arrays in its body.
    @Test
    func DEV_26_theStageOutputConstructorCopiesOnlyClipDistancesArraysInItsBody() {
        var outcome = checkedModule(
            """
            struct S {
              @builtin(clip_distances) a : f32,
              @builtin(clip_distances) b : array<f32, 2>,
              @builtin(position) p : vec4<f32>,
            }
            """
        )
        var printed: [String] = []
        ModuleState.withTestScope(&outcome.shaderModule) { module in
            for declaration in module.elements(module.declarations) {
                if case .structure(let structure) = declaration {
                    module.modify(structure) { $0.role = .vertexOutput }
                    printed.append(text(emitDeclarationForTesting(declaration, &module, DeviceState())))
                }
            }
        }
        #expect(
            printed == [
                "struct type0 {\n    float field0 [[clip_distance]];\n    float field1 [[clip_distance]] [2];\n"
                    + "    vec<float, 4> field2 [[position]];\n\n    template<typename T>\n    type0(const thread T& other)\n"
                    + "        : field0(other.field0)\n        , field2(other.field2)\n    {\n"
                    + "        for (unsigned __i = 0; __i < 2; ++__i) field1[__i] = other.field1[__i];\n    }\n};\n\n"
            ]
        )
    }
}
