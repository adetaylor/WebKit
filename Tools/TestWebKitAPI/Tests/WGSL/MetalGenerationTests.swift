// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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
import WGSL

private struct TranslationError: Error {
    let errors: [CompilationMessage]
}

private func translate(_ wgsl: String, _ entryPointName: String) -> Result<String, TranslationError> {
    onCompileThread { compileThread in
        switch compileThread.staticCheck(wtfSource(wgsl), configuration: noFeaturesConfiguration) {
        case .failure(let maybeError):
            return .failure(TranslationError(errors: maybeError.errors))
        case .success(let ast):
            switch ast.prepare(entryPoints: [Name(entryPointName)]) {
            case .failed(let maybeError, _):
                return .failure(TranslationError(errors: [maybeError]))
            case .prepared(let prepareResult):
                switch prepareResult.generate(overrides: [], deviceState: DeviceState(appleGPUFamily: 4, shaderValidationEnabled: false)) {
                case .failed(let maybeError, _):
                    return .failure(TranslationError(errors: [maybeError]))
                case .generated(let generationResult, _):
                    return .success(generationResult.msl.string)
                }
            }
        }
    }
}

private func expectMSL(_ mslSource: Result<String, TranslationError>, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation)
{
    switch mslSource {
    case .failure(let error):
        Issue.record("translate failed: \(error.errors.map(\.dumpDescription))", sourceLocation: sourceLocation)
    case .success(let msl):
        #expect(msl.utf8.elementsEqual(expected.utf8), "\(msl)", sourceLocation: sourceLocation)
    }
}

@Suite
struct WGSLMetalGenerationTests {
    // A predeclared address space, access mode or texel format as the value of a phony assignment: C++ prints its name,
    // which Metal rejects, and so does Swift (the name is `.builtin`).
    @Test
    func PhonyAssignmentOfPredeclaredValue() {
        let mslSource = translate(
            """
            @compute @workgroup_size(1)
            fn main() {
                _ = workgroup;
                _ = (rgba8unorm);
                _ = read_write;
            }
            """,
            "main"
        )

        expectMSL(
            mslSource,
            """
            #include <metal_stdlib>
            #include <metal_types>

            using namespace metal;

            template<typename T>
            struct __UnpackedTypeImpl;

            template<typename T>
            struct __PackedTypeImpl;

            template<typename T>
            using __UnpackedType = typename __UnpackedTypeImpl<T>::Type;

            template<typename T>
            using __PackedType = typename __PackedTypeImpl<T>::Type;

            [[kernel]]  void function0()
            {
                (void)(workgroup);
                (void)(rgba8unorm);
                (void)(read_write);
            }


            """
        )
    }

    @Test
    func RedFrag() {
        let mslSource = translate(
            """
            @fragment
            fn main() -> @location(0) vec4<f32> {
                return vec4<f32>(1.0, 0.0, 0.0, 1.0);
            }
            """,
            "main"
        )

        expectMSL(
            mslSource,
            """
            #include <metal_stdlib>
            #include <metal_types>

            using namespace metal;

            template<typename T>
            struct __UnpackedTypeImpl;

            template<typename T>
            struct __PackedTypeImpl;

            template<typename T>
            using __UnpackedType = typename __UnpackedTypeImpl<T>::Type;

            template<typename T>
            using __PackedType = typename __PackedTypeImpl<T>::Type;

            struct __function0_FragmentOutput {
                vec<float, 4> __value [[color(0)]];

                template<typename T>
                __function0_FragmentOutput(T value)
                    : __value(value)
                { }
            };

            [[fragment]] __function0_FragmentOutput function0()
            {
                return vec<float, 4>(1., 0., 0., 1.);
            }


            """
        )
    }

    @Test
    func BuiltinSampleMask() {
        let mslSource = translate(
            """
            @fragment
            fn main(@builtin(position) position : vec4<f32>,
                    @builtin(sample_index) sample_index : u32,
                    @builtin(sample_mask) sample_mask : u32) {
                let foo : vec4<f32> = position;
                let bar : u32 = (sample_index + sample_mask);
            }
            """,
            "main"
        )

        expectMSL(
            mslSource,
            """
            #include <metal_stdlib>
            #include <metal_types>

            using namespace metal;

            template<typename T>
            struct __UnpackedTypeImpl;

            template<typename T>
            struct __PackedTypeImpl;

            template<typename T>
            using __UnpackedType = typename __UnpackedTypeImpl<T>::Type;

            template<typename T>
            using __PackedType = typename __PackedTypeImpl<T>::Type;

            [[fragment]] void function0(vec<float, 4> parameter0 [[position]], unsigned parameter1 [[sample_id]], \
            unsigned parameter2 [[sample_mask]], const constant unsigned* __DynamicOffsets [[buffer(8)]])
            {
                vec<float, 4> local0 = parameter0;
                unsigned local1 = (parameter1 + parameter2);
            }


            """
        )
    }

    @Test
    func RepeatedGenerationIsDeterministic() {
        // Every pipeline created from a GPUShaderModule prepares and generates from the same AST,
        // so repeated generation must produce the same code for the Metal shader cache to hit.
        let generated = onCompileThread { compileThread -> [String]? in
            let result = compileThread.staticCheck(
                wtfSource(
                    """

                    @vertex
                    fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
                        var positions = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
                        return vec4<f32>(positions[i], 0.0, 1.0);
                    }
                    """
                ),
                configuration: noFeaturesConfiguration
            )
            var ast: CheckedModule
            switch consume result {
            case .failure:
                return nil
            case .success(let successfulCheck):
                ast = successfulCheck
            }

            func generate(_ ast: inout CheckedModule) -> String {
                let rolledBack: CheckedModule
                var generated = ""
                switch (consume ast).prepare(entryPoints: [Name("main")]) {
                case .failed(_, let module):
                    rolledBack = module
                case .prepared(let prepareResult):
                    switch prepareResult.generate(
                        overrides: [],
                        deviceState: DeviceState(appleGPUFamily: 4, shaderValidationEnabled: false)
                    ) {
                    case .failed(_, let module):
                        rolledBack = module
                    case .generated(let generationResult, let module):
                        generated = generationResult.msl.string
                        rolledBack = module
                    }
                }
                ast = rolledBack
                return generated
            }

            return [generate(&ast), generate(&ast), generate(&ast)]
        }
        guard let generated else {
            Issue.record("staticCheck failed")
            return
        }

        let first = generated[0]
        #expect(!first.isEmpty)
        #expect(first.utf8.elementsEqual(generated[1].utf8))
        #expect(first.utf8.elementsEqual(generated[2].utf8))
    }
}
