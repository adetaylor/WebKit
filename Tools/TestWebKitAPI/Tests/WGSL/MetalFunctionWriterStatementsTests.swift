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
import Synchronization
import Testing
@_spi(Testing) import WGSL

// The statement emitter (MetalFunctionWriter.cpp:3206-3540) on modules after the static passes, which leave these bodies as
// the writer sees them (fragDepthReturn also runs rewriteEntryPoints). Each expected body is the C++ MSL of the same source
// (for the family and validation named by the test): the body of `function0`, from its
// `{` to its `}`.

#if arch(x86_64)
// DEV-11: MetalFunctionWriter.cpp:3313-3317 under CPU(X86_64).
private let discardStatement = "__asm volatile(\"\"); discard_fragment()"
#else
private let discardStatement = "discard_fragment();"
#endif

/// The MSL the writer emits for the body of the module's first entry point, or for its first statement.
///
/// `transform` changes the module first, inside a CompilationScope.
private func emitted(
    _ source: String,
    family: UInt32 = 4,
    shaderValidation: Bool = false,
    firstStatementOnly: Bool = false,
    function name: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    transform: @escaping @Sendable (inout ShaderModule, FunctionID) -> Void = { _, _ in }
) -> String {
    onCompileThread { _ in
        var outcome = staticCheckForTesting(SourceText(source), configuration: testsConfiguration, stopAfter: .uniformityAnalysis)
        if let failure = outcome.failure {
            logCompilationError(failure, sourceLocation: sourceLocation)
            return ""
        }
        let function = selectedFunction(outcome.shaderModule, named: name)
        let deviceState = DeviceState(appleGPUFamily: family, shaderValidationEnabled: shaderValidation)
        var bytes = ContiguousArray<UInt8>()
        ModuleState.withTestScope(&outcome.shaderModule) { module in
            transform(&module, function)
            var statement = module[function].body
            if firstStatementOnly {
                statement = firstStatement(module, statement)
            }
            bytes = emitStatementForTesting(statement, of: function, &module, deviceState)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The function whose source name is `name`, or the first entry point.
private func selectedFunction(_ module: borrowing ShaderModule, named name: String?) -> FunctionID {
    if let name {
        for declaration in module.elements(module.declarations) {
            if case .function(let function) = declaration, module.symbols.name(of: module[function].originalName) == Name(name) {
                return function
            }
        }
    }
    return module.callGraph.entrypoints[0].function
}

/// The rewriteEntryPoints of prepare, for `main`.
private func rewriteMain(_ module: inout ShaderModule, _ function: FunctionID) {
    var layouts = LookupMap<Name, Int?>()
    layouts.add(Name("main"), nil)
    rewriteEntryPoints(&module, layouts)
}

private func firstStatement(_ module: borrowing ShaderModule, _ compound: StatementID) -> StatementID {
    module[module.downcast(CompoundStatement.self, compound).statements, 0]
}

struct WGSLMetalFunctionWriterStatementsTests {
    @Test
    func DEV_11_DiscardSpelling() {
        let source = "@fragment fn main() { discard; }"
        #if arch(x86_64)
        #expect(emitted(source, firstStatementOnly: true) == "__asm volatile(\"\"); discard_fragment()")
        #else
        #expect(emitted(source, firstStatementOnly: true) == "discard_fragment();")
        #endif
        let expected =
            [
                "{\n",
                "    " + discardStatement + ";\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
    }

    @Test
    func loopForwardProgress() {
        let source = "@compute @workgroup_size(1) fn main() { loop { break; } }"
        let expected4 =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "        break;\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 4) == expected4)
        let expected9 =
            [
                "{\n",
                "    { volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress)",
                " while (true) { if (++__wgslEnsureForwardProgress == 4294967295u) break; \n",
                "        break;\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 9) == expected9)
        #expect(emitted(source, family: 0xFF) == expected9)
    }

    @Test
    func forLoopForwardProgress() {
        let source = "@compute @workgroup_size(1) fn main() { for (;;) { break; } }"
        let expected4 =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; for (;;) { if (__wgslEnsureForwardProgress ==",
                " 4294967295u) break; {\n",
                "        break;\n",
                "    }}}\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 4) == expected4)
        let expected9 =
            [
                "{\n",
                "    { volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress) for",
                " (;;) { if (++__wgslEnsureForwardProgress == 4294967295u) break; {\n",
                "        break;\n",
                "    }}}\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 9) == expected9)
    }

    // MetalFunctionWriter.cpp:3389-3418: an internally generated for loop gets no forward-progress guard.
    @Test
    func internallyGeneratedForLoopHasNoForwardProgressGuard() {
        let source = "@compute @workgroup_size(1) fn main() { for (;;) { break; } }"
        for family: UInt32 in [4, 9] {
            let body = emitted(source, family: family) { module, function in
                let loop = firstStatement(module, module[function].body)
                module.modify(ForStatement.self, loop) { $0.isInternallyGenerated = true }
            }
            #expect(body == "{\n    for (;;){\n        break;\n    }\n}")
        }
    }

    @Test
    func compoundStatements() {
        let source = "@fragment fn main() { { { discard; } return; } }"
        let expected =
            [
                "{\n",
                "    {\n",
                "        {\n",
                "            " + discardStatement + ";\n",
                "        }\n",
                "        return;\n",
                "    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
    }

    @Test
    func continuingBlock() {
        let source = "@fragment fn main() { loop { break; continuing { discard; } } }"
        let expected =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "        break;\n",
                "        {\n",
                "            " + discardStatement + ";\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
    }

    @Test
    func returnStatement() {
        let source = "@compute @workgroup_size(1) fn main() { return; }"
        let expected =
            [
                "{\n",
                "    return;\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
    }

    @Test
    func assignmentStatements() {
        let source = """
            fn f(p: ptr<function, i32>) {
              *p = 1;
              *p += 2;
              (*p)++;
              (*p)--;
              *p <<= 3u;
              _ = 4;
            }
            @compute @workgroup_size(1) fn main() { var x: i32; f(&x); }
            """
        let expected =
            [
                "{\n",
                "    (*parameter0) = 1;\n",
                "    (*parameter0) = ((*parameter0) + 2);\n",
                "    (*parameter0)++;\n",
                "    (*parameter0)--;\n",
                "    (*parameter0) = ((*parameter0) << 3u);\n",
                "    (void)(4);\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, function: "f") == expected)
    }

    @Test
    func whileLoopForwardProgress() {
        let source = "@compute @workgroup_size(1) fn main() { while true { break; } }"
        let expected4 =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; {\n",
                "        break;\n",
                "    }}}\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 4) == expected4)
        let expected9 =
            [
                "{\n",
                "    { volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress)",
                " while (true) { if (++__wgslEnsureForwardProgress == 4294967295u) break; {\n",
                "        break;\n",
                "    }}}\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 9) == expected9)
    }

    @Test
    func switchOutsideLoop() {
        let source = "@compute @workgroup_size(1) fn main() { switch 1 { case 1: { } default: { } } }"
        let expected =
            [
                "{\n",
                "    switch (1) {\n",
                "    case 1: {\n",
                "    }\n",
                "        break;\n",
                "    default: {\n",
                "    }\n",
                "        break;\n",
                "    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
    }

    @Test
    func switchInsideLoopEmulatesContinue() {
        let source = """
            @compute @workgroup_size(1) fn main() {
              loop {
                switch 1 {
                  case 1: { continue; }
                  default: { }
                }
                break;
                continuing { }
              }
            }
            """
        let expected =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "bool __continuing = false;\n",
                "            switch (1) {\n",
                "        case 1: {\n",
                "            __continuing = true;\n",
                "            break;\n",
                "        }\n",
                "            break;\n",
                "        default: {\n",
                "        }\n",
                "            break;\n",
                "        }\n",
                "        if (__continuing) {{\n",
                "            }\n",
                "\n",
                "        }\n",
                "        break;\n",
                "        {\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
        let expectedWithValidation =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "bool __continuing = false;\n",
                "            switch (1) {\n",
                "        case 1:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "            __continuing = true;\n",
                "            break;\n",
                "        }\n",
                "            \n",
                "}\n",
                "break;\n",
                "        default:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "        }\n",
                "            \n",
                "}\n",
                "break;\n",
                "        }\n",
                "        if (__continuing) {{\n",
                "            }\n",
                "\n",
                "        }\n",
                "        break;\n",
                "        {\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, shaderValidation: true) == expectedWithValidation)
        let expected9WithValidation =
            [
                "{\n",
                "    { volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress)",
                " while (true) { if (++__wgslEnsureForwardProgress == 4294967295u) break; \n",
                "bool __continuing = false;\n",
                "            switch (1) {\n",
                "        case 1:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "            __continuing = true;\n",
                "            break;\n",
                "        }\n",
                "            \n",
                "}\n",
                "break;\n",
                "        default:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "        }\n",
                "            \n",
                "}\n",
                "break;\n",
                "        }\n",
                "        if (__continuing) {{\n",
                "            }\n",
                "\n",
                "        }\n",
                "        break;\n",
                "        {\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, family: 9, shaderValidation: true) == expected9WithValidation)
    }

    @Test
    func switchNestedInsideLoopBreaksOut() {
        let source = """
            @compute @workgroup_size(1) fn main() {
              loop {
                switch 1 {
                  case 3, 4: { }
                  default: {
                    switch 2 {
                      case 2: { continue; }
                      default: { }
                    }
                  }
                }
                break;
                continuing { }
              }
            }
            """
        let expected =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "bool __continuing = false;\n",
                "            switch (1) {\n",
                "        case 3:\n",
                "        case 4: {\n",
                "        }\n",
                "            break;\n",
                "        default: {\n",
                "            switch (2) {\n",
                "            case 2: {\n",
                "                __continuing = true;\n",
                "                break;\n",
                "            }\n",
                "                break;\n",
                "            default: {\n",
                "            }\n",
                "                break;\n",
                "            }\n",
                "            if (__continuing) {\n",
                "                break;\n",
                "            }\n",
                "        }\n",
                "            break;\n",
                "        }\n",
                "        if (__continuing) {{\n",
                "            }\n",
                "\n",
                "        }\n",
                "        break;\n",
                "        {\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
        let expectedWithValidation =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "bool __continuing = false;\n",
                "            switch (1) {\n",
                "        case 3:\n",
                "        case 4:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "        }\n",
                "            \n",
                "}\n",
                "break;\n",
                "        default:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "            switch (2) {\n",
                "            case 2:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "                __continuing = true;\n",
                "                break;\n",
                "            }\n",
                "                \n",
                "}\n",
                "break;\n",
                "            default:\n",
                "{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n",
                "{\n",
                "            }\n",
                "                \n",
                "}\n",
                "break;\n",
                "            }\n",
                "            if (__continuing) {\n",
                "                break;\n",
                "            }\n",
                "        }\n",
                "            \n",
                "}\n",
                "break;\n",
                "        }\n",
                "        if (__continuing) {{\n",
                "            }\n",
                "\n",
                "        }\n",
                "        break;\n",
                "        {\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, shaderValidation: true) == expectedWithValidation)
    }

    @Test
    func continueCopiesTheContinuingBlock() {
        let source = """
            @fragment fn main() {
              loop {
                if true { continue; }
                break;
                continuing {
                  loop {
                    if false { continue; } else { discard; }
                    break;
                    continuing { break if true; }
                  }
                }
              }
            }
            """
        let expected =
            [
                "{\n",
                "    { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if (__wgslEnsureForwardProgress",
                " == 4294967295u) break; \n",
                "        if (true) {\n",
                "            {\n",
                "                { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if",
                " (__wgslEnsureForwardProgress == 4294967295u) break; \n",
                "                    if (false) {\n",
                "                        {\n",
                "                            if (true)\n",
                "                                break;\n",
                "                        }\n",
                "                        continue;\n",
                "                    } else {\n",
                "                        " + discardStatement + ";\n",
                "                    }\n",
                "                    break;\n",
                "                    {\n",
                "                        if (true)\n",
                "                            break;\n",
                "                    }\n",
                "                }                }\n",
                "            }\n",
                "            continue;\n",
                "        }\n",
                "        break;\n",
                "        {\n",
                "            { uint32_t __wgslEnsureForwardProgress = 0; while (true) { if",
                " (__wgslEnsureForwardProgress == 4294967295u) break; \n",
                "                if (false) {\n",
                "                    {\n",
                "                        if (true)\n",
                "                            break;\n",
                "                    }\n",
                "                    continue;\n",
                "                } else {\n",
                "                    " + discardStatement + ";\n",
                "                }\n",
                "                break;\n",
                "                {\n",
                "                    if (true)\n",
                "                        break;\n",
                "                }\n",
                "            }            }\n",
                "        }\n",
                "    }    }\n",
                "}",
            ]
            .joined()
        #expect(emitted(source) == expected)
    }

    @Test
    func fragDepthReturn() {
        let source = "@fragment fn main() -> @builtin(frag_depth) f32 { return 0.5; }"
        let expected =
            [
                "{\n",
                "    __function0_FragmentOutput __wgslFragmentReturnResult =  0.5;\n",
                "__wgslFragmentReturnResult.__value = clamp(__wgslFragmentReturnResult.__value,",
                " as_type<float>(__DynamicOffsets[0]), as_type<float>(__DynamicOffsets[1]));\n",
                "return __wgslFragmentReturnResult;\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, transform: rewriteMain) == expected)
    }

    @Test
    func sampleMaskReturn() {
        let source = "@fragment fn main() -> @builtin(sample_mask) u32 { return 1u; }"
        let expected =
            [
                "{\n",
                "    __function0_FragmentOutput __wgslFragmentReturnResult =  1u;\n",
                "__wgslFragmentReturnResult.__value = (__wgslFragmentReturnResult.__value &",
                " __DynamicOffsets[2]);\n",
                "return __wgslFragmentReturnResult;\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, transform: rewriteMain) == expected)
    }

    @Test
    func fragDepthAndSampleMaskReturnAfterCallStatement() {
        let source = """
            struct FragOut { @builtin(frag_depth) depth: f32, @builtin(sample_mask) mask: u32 }
            fn g() -> FragOut { return FragOut(0.5, 1); }
            fn h() { }
            @fragment fn main() -> FragOut { h(); return g(); }
            """
        let expected =
            [
                "{\n",
                "    function1();\n",
                "    __type0_FragmentOutput __wgslFragmentReturnResult =  function0();\n",
                "__wgslFragmentReturnResult.field0 = clamp(__wgslFragmentReturnResult.field0,",
                " as_type<float>(__DynamicOffsets[0]), as_type<float>(__DynamicOffsets[1]));\n",
                ";\n",
                "__wgslFragmentReturnResult.field1 = (__wgslFragmentReturnResult.field1 & __DynamicOffsets[2]);\n",
                "return __wgslFragmentReturnResult;\n",
                "}",
            ]
            .joined()
        #expect(emitted(source, function: "main", transform: rewriteMain) == expected)
    }

    // GlobalVariableRewriter's zero-initialization of a 2000-deep nested workgroup array is a 2000-deep for statement nest around
    // a 2000-deep access chain, which overflows the GPU process's 512 KiB stack in release C++ (and an 8 MiB one at -Onone in a
    // recursive Swift writer).
    @Test
    func DEV_03_aTwoThousandDeepZeroInitializationNestIsWrittenOnTheProductionStack() {
        let depth = 2000
        var source = "alias A0 = array<u32, 1>;\n"
        for level in 1..<depth {
            source += "alias A\(level) = array<A\(level - 1), 1>;\n"
        }
        source += "var<workgroup> w: A\(depth - 1);\n@compute @workgroup_size(1) fn main() { _ = w; }\n"
        let stackSize = CompileThread.recommendedStackSize == nil ? 512 * 1024 : 8 << 20
        let compiled = onThread(stackSize: stackSize) { [source] () -> String? in
            switch staticCheck(SourceText(source), configuration: testsConfiguration) {
            case .success(var module):
                switch module.compileEntryPoint(Name("main"), constants: [], deviceState: DeviceState()) {
                case .compiled(_, let library):
                    return library.msl.string
                case .prepareFailed, .entryPointNotFound, .invalidPipelineConstant, .generateFailed:
                    return nil
                }
            case .failure:
                return nil
            }
        }

        guard let msl = compiled ?? nil else {
            Issue.record("the compilation failed")
            return
        }

        var expected = "    if ((__localInvocationIndex == 0u)) {\n"
        var access = "global0"
        for level in 0..<depth {
            expected += String(repeating: "    ", count: level + 2)
            expected += "for (unsigned __i\(level) = 0u; (__i\(level) < 1u); __i\(level) = (__i\(level) + 1u)){\n"
            access += "[__i\(level)]"
        }
        expected += String(repeating: "    ", count: depth + 2) + "__wgslZeroWorkgroupVar(\(access));\n"
        for level in stride(from: depth - 1, through: 0, by: -1) {
            expected += String(repeating: "    ", count: level + 2) + "}\n"
        }
        expected += "    }\n    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
        #expect(msl.contains(expected))
    }
}

private final class ThreadResult<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func complete(_ result: Value) {
        value.withLock { $0 = result }
        done.signal()
    }

    func wait() -> Value? {
        done.wait()
        return value.withLock { $0 }
    }
}

/// Runs `body` on a thread with a `stackSize`-byte stack.
private func onThread<Value: Sendable>(stackSize: Int, _ body: @escaping @Sendable () -> Value) -> Value? {
    let result = ThreadResult<Value>()
    let thread = Thread {
        result.complete(body())
    }
    thread.stackSize = stackSize
    thread.start()
    return result.wait()
}
