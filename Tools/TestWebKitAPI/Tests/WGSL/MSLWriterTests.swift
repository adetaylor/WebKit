// swift-format-ignore-file: AlwaysUseLowerCamelCase
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

private func text(_ writer: borrowing MSLWriter) -> String {
    String(decoding: writer.bytes, as: UTF8.self)
}

private func spelling(_ number: MSLNumber) -> String {
    var writer = MSLWriter()
    writer.append(number)
    return text(writer)
}

private func spelling(_ attribute: MSLAttribute) -> String {
    var writer = MSLWriter()
    writer.append(attribute)
    return text(writer)
}

private func spelling(_ literal: MSLText) -> String {
    var writer = MSLWriter()
    writer.append(literal)
    return text(writer)
}

/// The proofs of the checked accesses, in pre-order.
private struct SubscriptProofCollector: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var proofs: [SubscriptProof] = []

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ access: CheckedIndexAccessExpression, _ id: ExpressionID) {
        proofs.append(access.proof)
        visitChildren(access, id)
    }
}

/// The SubscriptProofs insertBoundsChecks gives `source` after the static passes (WGSL.cpp:94-113), or nil if a pass failed.
private func subscriptProofs(_ source: SourceText) -> [SubscriptProof]? {
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
    var proofs: [SubscriptProof] = []
    ModuleState.withTestScope(&module) { module in
        insertBoundsChecks(&module)
        var collector = SubscriptProofCollector(shaderModule: module)
        collector.visitShaderModule()
        module = collector.shaderModule
        proofs = collector.proofs
    }
    return proofs
}

// The shape of FunctionDefinitionWriter: separate sinks sharing one indentation, concatenated as write() does.
private struct WriterShape: ~Copyable {
    var output = MSLWriter()
    var body = MSLWriter()
    var constants = MSLWriter()
    var indent = Indentation()

    mutating func write() -> ContiguousArray<UInt8> {
        body.append(indent)
        body.append("struct type0 {\n")
        indent.increment()
        body.append(indent)
        body.append("uint8_t __padding")
        body.appendDecimal(UInt32(1))
        body.appendArrayExtent(12)
        body.append("; \n")
        indent.decrement()
        body.append(indent)
        body.append("};\n\n")
        output.append(contentsOf: body)
        body.clear()

        body.append("[[kernel]] void function0()\n{\n}\n\n")
        var functions = MSLWriter()
        swap(&body, &functions)
        body.append("helpers\n")
        constants.append("constant float local0 = ")
        constants.append(.f32(2))
        constants.append(";\n")

        output.append(contentsOf: body)
        output.append(contentsOf: constants)
        output.append(contentsOf: functions)
        return output.bytes
    }
}

@Suite
struct WGSLMSLWriterTests {
    @Test
    func literalsAppendTheirBytes() {
        #expect(spelling("float4(") == "float4(")
        #expect(spelling("") == "")
        #expect(spelling("\n{ ") == "\n{ ")
        #expect(spelling("\u{E9}") == "\u{E9}")
        var writer = MSLWriter(reservingCapacity: 4096)
        writer.append("thread ")
        writer.append("float")
        writer.append(" local0")
        #expect(text(writer) == "thread float local0")
        #expect(writer.finish() == ContiguousArray("thread float local0".utf8))
    }

    @Test
    func integersAreSpelledAsStringBuilderAppendsThem() {
        #expect(spelling(.abstractInt(0)) == "0")
        #expect(spelling(.abstractInt(-42)) == "-42")
        #expect(spelling(.abstractInt(.min)) == "-9223372036854775808")
        #expect(spelling(.abstractInt(.max)) == "9223372036854775807")
        #expect(spelling(.i32(7)) == "7")
        #expect(spelling(.i32(.min)) == "-2147483648")
        #expect(spelling(.i32(.max)) == "2147483647")
        #expect(spelling(.u32(0)) == "0u")
        #expect(spelling(.u32(.max)) == "4294967295u")

        var writer = MSLWriter()
        writer.appendDecimal(Int32.min)
        writer.append(" ")
        writer.appendDecimal(UInt32.max)
        writer.append(" ")
        writer.appendDecimal(Int64.min)
        writer.append(" ")
        writer.appendDecimal(UInt64.max)
        writer.append(" ")
        writer.appendDecimal(-1)
        #expect(text(writer) == "-2147483648 4294967295 -9223372036854775808 18446744073709551615 -1")
    }

    @Test
    func floatsAreSpelledWithTheWTFFormatters() {
        #expect(spelling(.abstractFloat(1)) == "1.")
        #expect(spelling(.abstractFloat(0.5)) == "0.5")
        #expect(spelling(.abstractFloat(-0.0)) == "0.")
        #expect(spelling(.abstractFloat(1e21)) == "1e+21")
        #expect(spelling(.abstractFloat(.infinity)) == "Infinity")
        #expect(spelling(.abstractFloat(.nan)) == "NaN")
        #expect(spelling(.f32(0.1)) == "0.10000000149011612")
        #expect(spelling(.f32(3)) == "3.")
        #expect(spelling(.f32(-.infinity)) == "-Infinity")
        #expect(spelling(.f16(Half(Float(1.5)))) == "1.5")
        #expect(spelling(.f16(Half(Float(65_504)))) == "65504.")
        #expect(spelling(.f16(Half(Float(0.1)))) == "0.0999755859375")
        #expect(spelling(.double(180 / Double.pi)) == "57.29577951308232")
        #expect(spelling(.double(Double.pi / 180)) == "0.017453292519943295")
        #expect(spelling(.double(1)) == "1")
    }

    @Test
    func attributesAreSpelledAsTheCxxWriterSpellsThem() {
        let expected: [(MSLAttribute, String)] = [
            (.stageIn, "[[stage_in]]"),
            (.clipDistance, "[[clip_distance]]"),
            (.depthAny, "[[depth(any)]]"),
            (.frontFacing, "[[front_facing]]"),
            (.threadPositionInGrid, "[[thread_position_in_grid]]"),
            (.instanceID, "[[instance_id]]"),
            (.threadPositionInThreadgroup, "[[thread_position_in_threadgroup]]"),
            (.threadIndexInThreadgroup, "[[thread_index_in_threadgroup]]"),
            (.threadgroupsPerGrid, "[[threadgroups_per_grid]]"),
            (.position, "[[position]]"),
            (.primitiveID, "[[primitive_id]]"),
            (.sampleID, "[[sample_id]]"),
            (.sampleMask, "[[sample_mask]]"),
            (.threadIndexInSimdgroup, "[[thread_index_in_simdgroup]]"),
            (.threadsPerSimdgroup, "[[threads_per_simdgroup]]"),
            (.simdgroupIndexInThreadgroup, "[[simdgroup_index_in_threadgroup]]"),
            (.simdgroupsPerThreadgroup, "[[simdgroups_per_threadgroup]]"),
            (.vertexID, "[[vertex_id]]"),
            (.threadgroupPositionInGrid, "[[threadgroup_position_in_grid]]"),
            (.vertex, "[[vertex]]"),
            (.fragment, "[[fragment]]"),
            (.kernel, "[[kernel]]"),
            (.buffer(0), "[[buffer(0)]]"),
            (.buffer(.max), "[[buffer(4294967295)]]"),
            (.id(3), "[[id(3)]]"),
            (.id(-1), "[[id(-1)]]"),
            (.userLocation(5), "[[user(loc5)]]"),
            (.color(1), "[[color(1)]]"),
            (.attribute(15), "[[attribute(15)]]"),
            (.flat, "[[flat]]"),
            (.centerNoPerspective, "[[center_no_perspective]]"),
            (.centroidNoPerspective, "[[centroid_no_perspective]]"),
            (.sampleNoPerspective, "[[sample_no_perspective]]"),
            (.centerPerspective, "[[center_perspective]]"),
            (.centroidPerspective, "[[centroid_perspective]]"),
            (.samplePerspective, "[[sample_perspective]]"),
            (.invariant, "[[invariant]]"),
        ]
        for (attribute, spelled) in expected {
            #expect(spelling(attribute) == spelled)
        }
    }

    @Test
    func arrayExtentsAreDeclarators() {
        var writer = MSLWriter()
        writer.append("uint8_t __padding")
        writer.appendDecimal(UInt32(2))
        writer.appendArrayExtent(12)
        writer.append("; \n")
        writer.append("float local0 ")
        writer.append(.clipDistance)
        writer.append(" ")
        writer.appendArrayExtent(8)
        writer.append(" ")
        writer.appendArrayExtent(nil)
        writer.append(" ")
        writer.appendArrayExtent(.max)
        #expect(text(writer) == "uint8_t __padding2[12]; \nfloat local0 [[clip_distance]] [8] [] [4294967295]")
    }

    @Test
    func indentationIsFourSpacesPerLevel() {
        var indent = Indentation()
        var writer = MSLWriter()
        writer.append(indent)
        writer.append("a\n")
        indent.increment()
        writer.append(indent)
        writer.append("b\n")
        indent.increment()
        indent.increment()
        #expect(indent.value == 3)
        writer.append(indent)
        writer.append("c\n")
        indent.decrement()
        indent.decrement()
        indent.decrement()
        writer.append(indent)
        writer.append("d\n")
        #expect(indent.value == 0)
        #expect(text(writer) == "a\n    b\n            c\nd\n")
    }

    @Test
    func sinksConcatenateInWriteOrder() {
        var shape = WriterShape()
        let bytes = shape.write()
        #expect(
            String(decoding: bytes, as: UTF8.self)
                == "struct type0 {\n    uint8_t __padding1[12]; \n};\n\nhelpers\nconstant float local0 = 2.;\n"
                + "[[kernel]] void function0()\n{\n}\n\n"
        )
    }

    @Test
    func helperTextIsAppendedVerbatim() {
        var writer = MSLWriter()
        writer.append(MTLWorkaround.optnoneAttribute)
        writer.append("static T __workgroup_uniform_load(threadgroup T* const ptr)\n")
        #expect(text(writer) == "[[clang::optnone]] static T __workgroup_uniform_load(threadgroup T* const ptr)\n")
    }

    @Test
    func writerGPUClassSplitsAtApple9() {
        for family: UInt32 in [0, 1, 4, 7, 8] {
            #expect(WriterGPUClass(appleGPUFamily: family) == .belowApple9)
        }
        for family: UInt32 in [9, 10, 11, 0xFF, .max] {
            #expect(WriterGPUClass(appleGPUFamily: family) == .apple9OrLater)
        }
    }

    @Test
    func forwardProgressSpellingsMatchTheCxxMacros() {
        #expect(spelling(MTLWorkaround.declareForwardProgress(.belowApple9)) == "uint32_t __wgslEnsureForwardProgress = 0;")
        #expect(spelling(MTLWorkaround.checkForwardProgress(.belowApple9)) == "if (__wgslEnsureForwardProgress == 4294967295u) break;")
        #expect(
            spelling(MTLWorkaround.declareForwardProgress(.apple9OrLater))
                == "volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress)"
        )
        #expect(
            spelling(MTLWorkaround.checkForwardProgress(.apple9OrLater)) == "if (++__wgslEnsureForwardProgress == 4294967295u) break;"
        )

        var writer = MSLWriter()
        writer.append("\n{ ")
        writer.append(MTLWorkaround.declareOpaqueScope)
        writer.append("\n")
        #expect(text(writer) == "\n{ volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)\n")
    }

    @Test
    func identifiersOfMintedSymbolsAreAppended() {
        var symbols = SymbolTable.predeclared
        let source = symbols.intern(ContiguousArray("userName".utf16))
        var mangler = Mangler.makeForTesting()
        _ = mangler.makeMangledName(source, .local)
        let local1 = symbols.intern(mangler.makeMangledName(source, .local))
        let wgslMin = symbols.intern(ReservedName.fixed(.wgslMin))
        let arrayLength = symbols.intern(ReservedName.arrayLength(of: local1))
        let xyz = symbols.intern(ContiguousArray("xyz".utf16))
        guard case .success(let swizzle) = Swizzle.validate(xyz, symbols, vectorSize: 3) else {
            Issue.record("xyz is a valid swizzle of a vec3")
            return
        }
        symbols.markSwizzle(xyz, swizzle)

        var writer = MSLWriter()
        writer.append(identifier: local1, in: symbols)
        writer.append(" = ")
        writer.append(identifier: wgslMin, in: symbols)
        writer.append("(")
        writer.append(identifier: arrayLength, in: symbols)
        writer.append(".")
        writer.append(identifier: xyz, in: symbols)
        writer.append(")")
        #expect(text(writer) == "local1 = __wgslMin(__local1_ArrayLength.xyz)")

        var index = 0
        while let builtin = Symbol(predeclaredIndex: index) {
            var builtinWriter = MSLWriter()
            builtinWriter.append(identifier: builtin, in: symbols)
            #expect(text(builtinWriter) == String(decoding: symbols.codeUnits(of: builtin), as: UTF16.self))
            index += 1
        }
        #expect(index > 0)
    }

    // A swizzle is validated on the low byte of each code unit (TypeCheck.cpp:2174), and C++ appends its text: U+0178, U+0161
    // and the surrogates of U+2E078 spell x, a and xx, and reach the MSL as UTF-8.
    @Test
    func nonASCIISwizzlesAreAppendedAsUTF8() {
        var symbols = SymbolTable.predeclared
        let spellings: [(units: ContiguousArray<UInt16>, utf8: [UInt8])] = [
            ([0x0178], [0xC5, 0xB8]),
            ([0x0178, 0x0178, 0x79, 0x78], [0xC5, 0xB8, 0xC5, 0xB8, 0x79, 0x78]),
            ([0x0161, 0x67], [0xC5, 0xA1, 0x67]),
            ([0xD878, 0xDC78], [0xF0, 0xAE, 0x81, 0xB8]),
        ]
        for spelling in spellings {
            let symbol = symbols.intern(spelling.units)
            guard case .success(let swizzle) = Swizzle.validate(symbol, symbols, vectorSize: 4) else {
                Issue.record("\(spelling.units) is a valid swizzle of a vec4")
                continue
            }
            symbols.markSwizzle(symbol, swizzle)
            var writer = MSLWriter()
            writer.append(".")
            writer.append(identifier: symbol, in: symbols)
            #expect(Array(writer.bytes) == [0x2E] + spelling.utf8)
            #expect(text(writer) == "." + String(decoding: spelling.units, as: UTF16.self))
        }
    }

    @Test
    func mintingUpgradesSourceTextOfTheSameSpelling() {
        var symbols = SymbolTable.predeclared
        let spelledLikeAMangledName = symbols.intern(ContiguousArray("local0".utf16))
        #expect(symbols.provenance(of: spelledLikeAMangledName) == .source)
        var mangler = Mangler.makeForTesting()
        let local0 = symbols.intern(mangler.makeMangledName(spelledLikeAMangledName, .local))
        #expect(local0 == spelledLikeAMangledName)
        var writer = MSLWriter()
        writer.append(identifier: spelledLikeAMangledName, in: symbols)
        #expect(text(writer) == "local0")
    }

    // The subscript sink brackets a user subscript given the proof BoundsCheck minted for the access. A constant-valued
    // access is printed as its constant (MetalFunctionWriter.cpp:1916-1931), so its proof never reaches the sink.
    @Test
    func subscriptsAreBracketedWithTheirBoundsCheckProofs() {
        let proofs = onCompileThread { _ in
            subscriptProofs(
                SourceText(
                    """
                    override n: u32 = 4;
                    const c = array(1, 2, 3);
                    var<workgroup> w: array<i32, n>;
                    var<private> fixed: array<i32, 4>;
                    @compute @workgroup_size(1)
                    fn main(@builtin(local_invocation_index) li: u32) {
                        var v = vec4f();
                        v[li] = 1;
                        fixed[2] = 2;
                        w[li] = c[1];
                    }

                    """
                )
            )
        }
        guard let proofs else {
            Issue.record("the static passes failed")
            return
        }
        #expect(Set(proofs.map(\.reason)) == [.clamped, .inBoundsConstant, .overrideValidated, .constantValue])

        for proof in proofs where proof.reason != .constantValue {
            var writer = MSLWriter()
            writer.append("global0")
            let openSubscript = writer.emitSubscript(proof)
            writer.append("parameter0")
            writer.closeSubscript(openSubscript)
            #expect(text(writer) == "global0[parameter0]", "\(proof.reason)")
        }
    }
}
