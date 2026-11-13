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

private enum CheckResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(FailedCheck)
}

/// The entry points staticCheck reflects, or nil (with an issue) if the check failed.
private func checkedEntryPoints(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) -> [EntryPointIO]? {
    let result: CheckResult<[EntryPointIO]> = onCompileThread { compileThread in
        switch compileThread.staticCheck(wtfSource(source)) {
        case .success(let module):
            return .success(module.entryPoints)
        case .failure(let failedCheck):
            return .failure(failedCheck)
        }
    }
    switch result {
    case .success(let entryPoints):
        return entryPoints
    case .failure(let failedCheck):
        logCompilationError(failedCheck, sourceLocation: sourceLocation)
        return nil
    }
}

@Suite
struct WGSLReflectionTests {
    @Test
    func entryPointsAreInCallGraphOrderWithTheirStages() throws {
        let entryPoints = try #require(
            checkedEntryPoints(
                "@compute @workgroup_size(1) fn c() { }"
                    + "@fragment fn f() { }"
                    + "@vertex fn v() -> @builtin(position) vec4f { return vec4f(); }"
            )
        )
        #expect(entryPoints.map(\.name) == [Name("c"), Name("f"), Name("v")])
        #expect(entryPoints.map(\.stage) == [.compute, .fragment, .vertex])
        #expect(entryPoints[0] == EntryPointIO(name: Name("c"), stage: .compute))
        #expect(entryPoints[1] == EntryPointIO(name: Name("f"), stage: .fragment))
    }

    @Test
    func vertexReturningAValueUsesLocationZero() throws {
        // ShaderModule.mm:420-436: location 0, not the return type's location; even for @builtin(position).
        let entryPoints = try #require(checkedEntryPoints("@vertex fn v() -> @builtin(position) vec4f { return vec4f(); }"))
        #expect(entryPoints[0].vertexOutputs == [IOLocation(location: 0, type: .vector(.f32, size: 4))])
        #expect(entryPoints[0].stageIn.isEmpty)
    }

    @Test
    func vertexStageInAndOutputs() throws {
        let entryPoints = try #require(
            checkedEntryPoints(
                "enable clip_distances;"
                    + "enable f16;"
                    + "struct In { @location(2) a: vec2u, @builtin(instance_index) i: u32, @location(0) b: f32 }"
                    + "struct Out {"
                    + "    @builtin(position) p: vec4f,"
                    + "    @location(3) @interpolate(flat) c: i32,"
                    + "    @builtin(clip_distances) d: array<f32, 3>,"
                    + "    @location(1) e: vec3h,"
                    + "}"
                    + "@vertex fn v(input: In, @location(5) x: vec4i, @builtin(vertex_index) y: u32) -> Out {"
                    + "    return Out();"
                    + "}"
            )
        )
        let entryPoint = entryPoints[0]
        #expect(
            entryPoint.stageIn == [
                IOLocation(location: 2, type: .vector(.u32, size: 2)),
                IOLocation(location: 0, type: .scalar(.f32)),
                IOLocation(location: 5, type: .vector(.i32, size: 4)),
            ]
        )
        #expect(
            entryPoint.vertexOutputs == [
                IOLocation(location: 3, type: .scalar(.i32), interpolation: Interpolation(type: .flat, sampling: .first)),
                IOLocation(location: 1, type: .vector(.f16, size: 3)),
            ]
        )
        #expect(entryPoint.clipDistancesCount == 3)
        #expect(entryPoint.fragmentInputs.isEmpty)
        #expect(entryPoint.fragmentOutputs == nil)
    }

    @Test
    func fragmentInputsComeOnlyFromStructParameters() throws {
        // ShaderModule.mm:548-611: a non-struct parameter's @location is not recorded; struct members' builtins set the flags.
        let entryPoints = try #require(
            checkedEntryPoints(
                "enable primitive_index;"
                    + "struct In {"
                    + "    @builtin(front_facing) f: bool,"
                    + "    @location(1) @interpolate(linear, sample) a: vec2f,"
                    + "    @builtin(sample_index) s: u32,"
                    + "    @builtin(sample_mask) m: u32,"
                    + "    @builtin(primitive_index) p: u32,"
                    + "}"
                    + "@fragment fn f(@location(0) x: f32, input: In, @builtin(position) position: vec4f) -> @location(2) vec4f {"
                    + "    return vec4f();"
                    + "}"
            )
        )
        var expected = EntryPointIO(name: Name("f"), stage: .fragment)
        expected.fragmentInputs = [
            IOLocation(location: 1, type: .vector(.f32, size: 2), interpolation: Interpolation(type: .linear, sampling: .sample))
        ]
        expected.fragmentOutputs = [IOLocation(location: 2, type: .vector(.f32, size: 4))]
        expected.usesFrontFacingInInput = true
        expected.usesSampleIndexInInput = true
        expected.usesSampleMaskInInput = true
        expected.usesPrimitiveIndexInInput = true
        #expect(entryPoints == [expected])
    }

    @Test
    func fragmentStructOutputs() throws {
        let entryPoints = try #require(
            checkedEntryPoints(
                "struct Out { @location(0) a: vec4f, @builtin(frag_depth) d: f32, @builtin(sample_mask) m: u32, @location(1) b: u32 }"
                    + "@fragment fn f() -> Out { return Out(); }"
            )
        )
        var expected = EntryPointIO(name: Name("f"), stage: .fragment)
        expected.fragmentOutputs = [
            IOLocation(location: 0, type: .vector(.f32, size: 4)),
            IOLocation(location: 1, type: .scalar(.u32)),
        ]
        expected.usesFragDepth = true
        expected.usesSampleMaskInOutput = true
        #expect(entryPoints == [expected])
    }

    @Test
    func fragmentWithoutReturnTypeHasNoOutputs() throws {
        let entryPoints = try #require(checkedEntryPoints("@fragment fn f() { }"))
        #expect(entryPoints[0].fragmentOutputs == nil)
    }
}

@Suite
struct WGSLStaticCheckTests {
    private static let derivativeInNonUniformControlFlow =
        "diagnostic(warning, derivative_uniformity);"
        + "@group(0) @binding(0) var t: texture_2d<f32>;"
        + "@group(0) @binding(1) var s: sampler;"
        + "@group(0) @binding(2) var<storage, read_write> b: f32;"
        + "@fragment fn main() { if (b > 0) { _ = textureSample(t, s, vec2f(0)); } }"

    private func check(_ source: String, _ configuration: Configuration) -> CheckResult<[CompilationMessage]> {
        onCompileThread { compileThread in
            switch compileThread.staticCheck(wtfSource(source), configuration: configuration) {
            case .success(let module):
                return .success(module.warnings)
            case .failure(let failedCheck):
                return .failure(failedCheck)
            }
        }
    }

    @Test
    func extensionWithoutTheFeatureFails() {
        // WGSL.cpp:115-119: the first enabled extension in bit order whose feature is missing, with an empty span and no warnings.
        let result = check("enable subgroups; enable f16; enable clip_distances;", Configuration(supportedFeatures: [.clipDistances]))
        guard case .failure(let failedCheck) = result else {
            Issue.record("staticCheck succeeded")
            return
        }
        #expect(failedCheck.errors.count == 1)
        expectMessage(failedCheck.errors.first, "Extension 'f16' requires feature 'shader-f16' which is not enabled on this device")
        #expect(failedCheck.errors.first?.span == SourceSpan(line: 0, lineOffset: 0, offset: 0, length: 0))
        #expect(failedCheck.warnings.isEmpty)
    }

    @Test
    func everyExtensionMapsToItsFeature() {
        let cases: [(String, Features, String)] = [
            ("clip_distances", .clipDistances, "clip-distances"),
            ("f16", .shaderF16, "shader-f16"),
            ("primitive_index", .primitiveIndex, "primitive-index"),
            ("subgroups", .subgroups, "subgroups"),
        ]
        for (name, feature, featureName) in cases {
            guard case .success = check("enable \(name);", Configuration(supportedFeatures: feature)) else {
                Issue.record("enable \(name) failed with \(featureName)")
                continue
            }
            guard case .failure(let failedCheck) = check("enable \(name);", Configuration()) else {
                Issue.record("enable \(name) succeeded without \(featureName)")
                continue
            }
            expectMessage(
                failedCheck.errors.first,
                "Extension '\(name)' requires feature '\(featureName)' which is not enabled on this device"
            )
        }
    }

    @Test
    func warningsSurviveOnlyASuccessfulCheck() {
        guard case .success(let warnings) = check(Self.derivativeInNonUniformControlFlow, noFeaturesConfiguration) else {
            Issue.record("staticCheck failed")
            return
        }
        #expect(warnings.count == 1)
        guard case .failure(let failedCheck) = check("enable f16;" + Self.derivativeInNonUniformControlFlow, noFeaturesConfiguration) else {
            Issue.record("staticCheck succeeded")
            return
        }
        #expect(failedCheck.errors.count == 1)
        #expect(failedCheck.warnings.isEmpty)
    }

    @Test
    func staticCheckForTestingStopsAfterThePass() {
        func outcome(_ source: String, _ stopAfter: StaticCheckPass) -> (errors: Int, warnings: Int) {
            onCompileThread { _ in
                let outcome = staticCheckForTesting(wtfSource(source), configuration: noFeaturesConfiguration, stopAfter: stopAfter)
                return (outcome.failure?.errors.count ?? 0, outcome.failure?.warnings.count ?? outcome.warnings.count)
            }
        }
        let typeError = "fn f() { let x: i32 = 1u; }"
        #expect(outcome(typeError, .reorderGlobals) == (0, 0))
        #expect(outcome(typeError, .typeCheck) == (1, 0))
        #expect(outcome(typeError, .uniformityAnalysis) == (1, 0))
        // The extension check is not a pass: stopping after the last pass reports the uniformity warning.
        #expect(outcome("enable f16;" + Self.derivativeInNonUniformControlFlow, .aliasAnalysis) == (0, 0))
        #expect(outcome("enable f16;" + Self.derivativeInNonUniformControlFlow, .uniformityAnalysis) == (0, 1))
    }

    @Test
    func containsOverrideComparesIDsAndNames() {
        let found = onCompileThread { compileThread -> [Bool]? in
            switch compileThread.staticCheck(wtfSource("@id(5) override a: i32; override b: f32;")) {
            case .success(let module):
                return [Name("5"), Name("a"), Name("b"), Name("c")].map { module.containsOverride($0) }
            case .failure:
                return nil
            }
        }
        #expect(found == [true, false, true, false])
    }
}
