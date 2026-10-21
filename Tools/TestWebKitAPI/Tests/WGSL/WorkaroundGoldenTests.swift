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

import Foundation
import Testing
@_spi(Testing) import WGSL

private func text(_ bytes: ContiguousArray<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
}

private func text(_ literal: MSLText) -> String {
    var writer = MSLWriter()
    writer.append(literal)
    return text(writer.bytes)
}

private func text(_ helper: MSLHelperText) -> String {
    var writer = MSLWriter()
    writer.append(helper)
    return text(writer.bytes)
}

private func cxxSpelling(_ name: String) throws -> String {
    try #require(CxxWorkaroundGolden.spellings[name], "no C++ spelling \(name)")
}

private func cxxNecessaryHelpers(_ name: String) throws -> String {
    try #require(CxxWorkaroundGolden.necessaryHelpers.first { $0.name == name }, "no C++ case \(name)").helpers
}

/// Every workaround spelling and helper body, against the bytes the C++ emits (the generated block at the end of the file).
@Suite
struct WGSLWorkaroundGoldenTests {
    @Test
    func helperTextsMatchTheCxxGolden() {
        #expect(MSLHelper.allCases.map { "\($0.name)" } == CxxWorkaroundGolden.helpers.map(\.name))
        for (helper, golden) in zip(MSLHelper.allCases, CxxWorkaroundGolden.helpers) {
            #expect(text(helper.text) == golden.text, "helper \(golden.name)")
        }
    }

    @Test
    func helperGeneratorEmitsItsOwnHelper() {
        for (helper, golden) in zip(MSLHelper.allCases, CxxWorkaroundGolden.helpers) {
            #expect(text(emitHelperForTesting(helper)) == golden.text, "emit\(golden.name)")
        }
    }

    @Test
    func forwardProgressSpellingsForBothGPUClasses() throws {
        #expect(text(MTLWorkaround.declareForwardProgress(.belowApple9)) == (try cxxSpelling("DECLARE_FORWARD_PROGRESS_VOLATILE_ACCESS")))
        #expect(text(MTLWorkaround.checkForwardProgress(.belowApple9)) == (try cxxSpelling("CHECK_FORWARD_PROGRESS_VOLATILE_ACCESS")))
        #expect(
            text(MTLWorkaround.declareForwardProgress(.apple9OrLater)) == (try cxxSpelling("DECLARE_FORWARD_PROGRESS_VOLATILE_COUNTER"))
        )
        #expect(text(MTLWorkaround.checkForwardProgress(.apple9OrLater)) == (try cxxSpelling("CHECK_FORWARD_PROGRESS_VOLATILE_COUNTER")))
    }

    @Test
    func writerGPUClassSplitsAtApple9() {
        #expect(WriterGPUClass(appleGPUFamily: 8) == .belowApple9)
        #expect(WriterGPUClass(appleGPUFamily: 9) == .apple9OrLater)
        #expect(WriterGPUClass(appleGPUFamily: 0xFF) == .apple9OrLater)
    }

    @Test
    func opaqueSwitchClauseScope() throws {
        #expect(text(MTLWorkaround.declareOpaqueScope) == (try cxxSpelling("DECLARE_OPAQUE_SCOPE")))
    }

    @Test
    func volatileAtomicLoadFromApple9() throws {
        #expect(MTLWorkaround.atomicLoadPrefix(.belowApple9) == nil)
        #expect(MTLWorkaround.atomicLoadSuffix(.belowApple9) == nil)
        let prefix = try #require(MTLWorkaround.atomicLoadPrefix(.apple9OrLater))
        let suffix = try #require(MTLWorkaround.atomicLoadSuffix(.apple9OrLater))
        #expect(text(prefix) == (try cxxSpelling("atomicLoadPrefix")))
        #expect(text(suffix) == (try cxxSpelling("atomicLoadSuffix")))
    }

    @Test
    func x86_64DiscardSpelling() throws {
        #expect(text(MTLWorkaround.discardFragment) == (try cxxSpelling("x86_64Discard")))
    }

    @Test
    func forcedInliningThreshold() throws {
        let threshold = try #require(UInt32(try cxxSpelling("minimumInlinedReturnSize")))
        #expect(MTLWorkaround.minimumInlinedReturnSize == ByteSize(bytes: threshold))
        #expect(text(MTLWorkaround.forceInlineAttribute) == (try cxxSpelling("forceInlineAttribute")))
    }

    @Test
    func optnoneOnWorkgroupUniformLoad() throws {
        #expect(text(MTLWorkaround.optnoneAttribute) == (try cxxSpelling("optnoneAttribute")))
    }

    @Test
    func outlinedConstantPrefix() throws {
        #expect(text(MTLWorkaround.outlinedConstantPrefix) == (try cxxSpelling("outlinedConstantPrefix")))
    }

    /// The `__wgslMin` body of every clamp, with the `return` line C++ appends without indentation.
    @Test
    func wgslMinHelperBody() throws {
        let expected = try cxxNecessaryHelpers("min")
        #expect(text(MTLWorkaround.wgslMinHelper) == expected)
        #expect(expected.contains("\nreturn min(a, b);\n"))
    }

    @Test
    func zeroWorkgroupVarHelperBody() throws {
        #expect(text(MTLWorkaround.zeroWorkgroupVarHelper) == (try cxxNecessaryHelpers("zeroWorkgroupVar")))
    }

    /// emitNecessaryHelpers: the helpers it emits for each flag set, in C++ order, and the flags it clears, for every GPU family
    /// (the helpers do not depend on it).
    @Test
    func necessaryHelpersMatchTheCxx() {
        for golden in CxxWorkaroundGolden.necessaryHelpers {
            for family: UInt32 in [4, 9, 0xFF] {
                var shaderModule = ShaderModule(source: SourceText(""))
                shaderModule.uses = golden.uses
                let output = emitNecessaryHelpersForTesting(
                    &shaderModule,
                    deviceState: DeviceState(appleGPUFamily: family, shaderValidationEnabled: golden.shaderValidationEnabled)
                )
                #expect(text(output) == CxxWorkaroundGolden.necessaryHelpersHeader + golden.helpers, "\(golden.name), family \(family)")
                #expect(shaderModule.uses == golden.usesAfter, "\(golden.name), family \(family)")
            }
        }
    }
}

// BEGIN the C++ goldens: the helper bodies of MetalFunctionWriter.cpp:49-257 (captured text sha1 e6c33c5830f497eba1bf6268f9ace110cfcf6867) and emitNecessaryHelpers (MetalFunctionWriter.cpp sha1 194a6bcb07f11da379d1903733522e11512cac88, lines 449-969); do not edit.
enum CxxWorkaroundGolden {
    /// The helper bodies, in C++ order.
    static let helpers: [(name: String, text: String)] = [
        (
            "Acos",
            [
                "template <typename T> T __wgslAcos(T value) { return acos(select(value, T(0), value < T(-1) || value > T(1))); }"
            ]
            .joined()
        ),
        (
            "Asin",
            [
                "template <typename T> T __wgslAsin(T value) { return asin(select(value, T(0), value < T(-1) || value > T(1))); }"
            ]
            .joined()
        ),
        (
            "Acosh",
            [
                "template <typename T> T __wgslAcosh(T value) { return acosh(select(value, T(0), value < T(1) || value > T(numeric_limits<T>::max()))); }"
            ]
            .joined()
        ),
        (
            "Atanh",
            [
                "template <typename T> T __wgslAtanh(T value) { return atanh(select(value, T(0), value < T(-1) || value > T(1))); }"
            ]
            .joined()
        ),
        (
            "InverseSqrt",
            [
                "template <typename T> T __wgslInverseSqrt(T value) { return rsqrt(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }"
            ]
            .joined()
        ),
        (
            "Log",
            [
                "template <typename T> T __wgslLog(T value) { if constexpr(__wgslMetalAppleGPUFamily < 9) { \n",
                " volatile auto result = log(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); return result; } else { \n",
                " return log(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }\n",
                " }",
            ]
            .joined()
        ),
        (
            "Log2",
            [
                "template <typename T> T __wgslLog2(T value) { return log2(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }"
            ]
            .joined()
        ),
        (
            "Sqrt",
            [
                "template <typename T> T __wgslSqrt(T value) { return sqrt(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }"
            ]
            .joined()
        ),
        (
            "PackFloatToSnorm2x16",
            [
                "template <typename T>\n",
                " auto __wgslPackFloatToSnorm2x16(T value)\n",
                " {\n",
                " if constexpr(__wgslMetalAppleGPUFamily < 9) { \n",
                " volatile auto result = pack_float_to_snorm2x16(value);\n",
                " return result;\n",
                " } else { \n",
                " auto result = pack_float_to_snorm2x16(value);\n",
                " return result;\n",
                " }\n",
                " }\n",
            ]
            .joined()
        ),
        (
            "PackFloatToUnorm2x16",
            [
                "template <typename T>\n",
                " auto __wgslPackFloatToUnorm2x16(T value)\n",
                " {\n",
                " if constexpr(__wgslMetalAppleGPUFamily < 9) { \n",
                " volatile auto result = pack_float_to_unorm2x16(value);\n",
                " return result;\n",
                " } else { \n",
                " auto result = pack_float_to_unorm2x16(value);\n",
                " return result;\n",
                " }\n",
                " }\n",
            ]
            .joined()
        ),
        (
            "PackFloatToSnorm4x8",
            [
                "template <typename T>\n",
                " auto __wgslPackFloatToSnorm4x8(T value)\n",
                " {\n",
                " if constexpr(__wgslMetalAppleGPUFamily < 9) { \n",
                " volatile auto result = pack_float_to_snorm4x8(value);\n",
                " return result;\n",
                " } else { \n",
                " auto result = pack_float_to_snorm4x8(value);\n",
                " return result;\n",
                " }\n",
                " }\n",
            ]
            .joined()
        ),
        (
            "PackFloatToUnorm4x8",
            [
                "template <typename T>\n",
                " auto __wgslPackFloatToUnorm4x8(T value)\n",
                " {\n",
                " if constexpr(__wgslMetalAppleGPUFamily < 9) { \n",
                " volatile auto result = pack_float_to_unorm4x8(value);\n",
                " return result;\n",
                " } else { \n",
                " auto result = pack_float_to_unorm4x8(value);\n",
                " return result;\n",
                " }\n",
                " }\n",
            ]
            .joined()
        ),
        (
            "TextureSampleBaseClampToEdge",
            [
                "float4 __wgslTextureSampleBaseClampToEdge(const constant texture2d<float>& __texture, sampler __sampler, float2 __coords)\n",
                "{\n",
                "    float2 const __bounds = (float2(0.5f) / float2(uint2(__texture.get_width(), __texture.get_height())));\n",
                "    return __texture.sample(__sampler, clamp(__coords, __bounds, float2(1.0f) - __bounds));\n",
                "}\n",
            ]
            .joined()
        ),
        (
            "TextureExternalSampleBaseClampToEdge",
            [
                "float4 __wgslTextureSampleBaseClampToEdge(texture_external __texture, sampler __sampler, float2 __inputCoords)\n",
                "{\n",
                "    constexpr sampler __reconstructionSampler(coord::normalized, address::clamp_to_edge, filter::linear);\n",
                "    uint2 const __firstPlaneSize = uint2(__texture.FirstPlane.get_width(), __texture.FirstPlane.get_height());\n",
                "    uint2 const __secondPlaneSize = uint2(__texture.SecondPlane.get_width(), __texture.SecondPlane.get_height());\n",
                "    float2 const __lumaBounds = (float2(0.5f) / float2(__firstPlaneSize));\n",
                "    float2 const __chromaBounds = (float2(0.5f) / float2(__secondPlaneSize));\n",
                "    float2 const __coords = clamp((__texture.UVRemapMatrix * float3(__inputCoords, 1)).xy, __lumaBounds, float2(1.0f) - __lumaBounds);\n",
                "    float2 const __secondCoords = clamp(__coords, __chromaBounds, float2(1.0f) - __chromaBounds);\n",
                "    float const __y = __texture.FirstPlane.sample(__sampler, __coords).r;\n",
                "    float4 const __second = all(__secondPlaneSize == __firstPlaneSize)\n",
                "        ? __texture.SecondPlane.sample(__sampler, __secondCoords)\n",
                "        : __texture.SecondPlane.sample(__reconstructionSampler, __secondCoords);\n",
                "    float3 const __rgb = __texture.ColorSpaceConversionMatrix * float4(float3(__y, __second.rg), 1);\n",
                "    return __texture.to_destination_color_space(__rgb, __second.a, __second.b);\n",
                "}\n",
            ]
            .joined()
        ),
        (
            "TextureSampleBiasWithOffset2d",
            [
                "template<int __x, int __y>\n",
                "float4 __wgslTextureSampleBiasWithOffset(const constant texture2d<float>& __texture, sampler __sampler, float2 __coords, float __bias)\n",
                "{\n",
                "    if constexpr(__wgslMetalAppleGPUFamily <= 9) {\n",
                "        uint2 const __size = uint2(__texture.get_width(), __texture.get_height());\n",
                "        if (!all((__size & (__size - 1u)) == 0u)) {\n",
                "            uint const __levels = __texture.get_num_mip_levels();\n",
                "            float const __lod = clamp(__texture.calculate_clamped_lod(__sampler, __coords * exp2(__bias)), 0.0f, float(__levels - 1));\n",
                "            uint const __low = uint(__lod);\n",
                "            uint const __high = min(__low + 1u, __levels - 1u);\n",
                "            uint2 const __lowSize = uint2(__texture.get_width(__low), __texture.get_height(__low));\n",
                "            uint2 const __highSize = uint2(__texture.get_width(__high), __texture.get_height(__high));\n",
                "            if (!all(min(__lowSize, __highSize) >= 8u)) {\n",
                "                float2 const __offset = float2(__x, __y);\n",
                "                return mix(__texture.sample(__sampler, __coords + __offset / float2(__lowSize), level(float(__low))),\n",
                "                    __texture.sample(__sampler, __coords + __offset / float2(__highSize), level(float(__high))), __lod - float(__low));\n",
                "            }\n",
                "        }\n",
                "    }\n",
                "    return __texture.sample(__sampler, __coords, bias(__bias), int2(__x, __y));\n",
                "}\n",
            ]
            .joined()
        ),
        (
            "TextureSampleBiasWithOffset2dArray",
            [
                "template<int __x, int __y>\n",
                "float4 __wgslTextureSampleBiasWithOffset(const constant texture2d_array<float>& __texture, sampler __sampler, float2 __coords, uint __arrayIndex, float __bias)\n",
                "{\n",
                "    if constexpr(__wgslMetalAppleGPUFamily <= 9) {\n",
                "        uint2 const __size = uint2(__texture.get_width(), __texture.get_height());\n",
                "        if (!all((__size & (__size - 1u)) == 0u)) {\n",
                "            uint const __levels = __texture.get_num_mip_levels();\n",
                "            float const __lod = clamp(__texture.calculate_clamped_lod(__sampler, __coords * exp2(__bias)), 0.0f, float(__levels - 1));\n",
                "            uint const __low = uint(__lod);\n",
                "            uint const __high = min(__low + 1u, __levels - 1u);\n",
                "            uint2 const __lowSize = uint2(__texture.get_width(__low), __texture.get_height(__low));\n",
                "            uint2 const __highSize = uint2(__texture.get_width(__high), __texture.get_height(__high));\n",
                "            if (!all(min(__lowSize, __highSize) >= 8u)) {\n",
                "                float2 const __offset = float2(__x, __y);\n",
                "                return mix(__texture.sample(__sampler, __coords + __offset / float2(__lowSize), __arrayIndex, level(float(__low))),\n",
                "                    __texture.sample(__sampler, __coords + __offset / float2(__highSize), __arrayIndex, level(float(__high))), __lod - float(__low));\n",
                "            }\n",
                "        }\n",
                "    }\n",
                "    return __texture.sample(__sampler, __coords, __arrayIndex, bias(__bias), int2(__x, __y));\n",
                "}\n",
            ]
            .joined()
        ),
        (
            "TextureSampleBiasWithOffset3d",
            [
                "template<int __x, int __y, int __z>\n",
                "float4 __wgslTextureSampleBiasWithOffset(const constant texture3d<float>& __texture, sampler __sampler, float3 __coords, float __bias)\n",
                "{\n",
                "    if constexpr(__wgslMetalAppleGPUFamily <= 9) {\n",
                "        uint3 const __size = uint3(__texture.get_width(), __texture.get_height(), __texture.get_depth());\n",
                "        if (!all((__size & (__size - 1u)) == 0u)) {\n",
                "            uint const __levels = __texture.get_num_mip_levels();\n",
                "            float const __lod = clamp(__texture.calculate_clamped_lod(__sampler, __coords * exp2(__bias)), 0.0f, float(__levels - 1));\n",
                "            uint const __low = uint(__lod);\n",
                "            uint const __high = min(__low + 1u, __levels - 1u);\n",
                "            uint3 const __lowSize = uint3(__texture.get_width(__low), __texture.get_height(__low), __texture.get_depth(__low));\n",
                "            uint3 const __highSize = uint3(__texture.get_width(__high), __texture.get_height(__high), __texture.get_depth(__high));\n",
                "            if (!all(min(__lowSize, __highSize) >= 8u)) {\n",
                "                float3 const __offset = float3(__x, __y, __z);\n",
                "                return mix(__texture.sample(__sampler, __coords + __offset / float3(__lowSize), level(float(__low))),\n",
                "                    __texture.sample(__sampler, __coords + __offset / float3(__highSize), level(float(__high))), __lod - float(__low));\n",
                "            }\n",
                "        }\n",
                "    }\n",
                "    return __texture.sample(__sampler, __coords, bias(__bias), int3(__x, __y, __z));\n",
                "}\n",
            ]
            .joined()
        ),
    ]

    /// The workaround spellings outside the helpers, each from the C++ construct that spells it.
    static let spellings: [String: String] = [
        "DECLARE_FORWARD_PROGRESS_VOLATILE_ACCESS": "uint32_t __wgslEnsureForwardProgress = 0;",
        "CHECK_FORWARD_PROGRESS_VOLATILE_ACCESS": "if (__wgslEnsureForwardProgress == 4294967295u) break;",
        "DECLARE_FORWARD_PROGRESS_VOLATILE_COUNTER": "volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress)",
        "CHECK_FORWARD_PROGRESS_VOLATILE_COUNTER": "if (++__wgslEnsureForwardProgress == 4294967295u) break;",
        "DECLARE_OPAQUE_SCOPE": "volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)",
        "atomicLoadPrefix": "({ volatile auto __wgslAtomicLoadResult = ",
        "atomicLoadSuffix": "; __wgslAtomicLoadResult; })",
        "x86_64Discard": "__asm volatile(\"\"); discard_fragment()",
        "minimumInlinedReturnSize": "128",
        "forceInlineAttribute": "__attribute__((always_inline)) ",
        "outlinedConstantPrefix": "const constant ",
        "optnoneAttribute": "[[clang::optnone]] ",
    ]

    /// What emitNecessaryHelpers() appends first whatever the flags.
    static let necessaryHelpersHeader = [
        "template<typename T>\n",
        "struct __UnpackedTypeImpl;\n",
        "\n",
        "template<typename T>\n",
        "struct __PackedTypeImpl;\n",
        "\n",
        "template<typename T>\n",
        "using __UnpackedType = typename __UnpackedTypeImpl<T>::Type;\n",
        "\n",
        "template<typename T>\n",
        "using __PackedType = typename __PackedTypeImpl<T>::Type;\n",
        "\n",
    ]
    .joined()

    /// emitNecessaryHelpers() as the C++ runs it: the flags set before, shader validation, the bytes appended after
    /// `necessaryHelpersHeader` and the flags left set.
    static let necessaryHelpers: [(name: String, uses: UsesFlags, shaderValidationEnabled: Bool, helpers: String, usesAfter: UsesFlags)] = [
        (
            name: "none",
            uses: [],
            shaderValidationEnabled: false,
            helpers: "",
            usesAfter: []
        ),
        (
            name: "every helper flag",
            uses: [
                .externalTextures, .packArray, .unpackArray, .packVector, .unpackVector, .workgroupUniformLoad, .workgroupUniformLoadAtomic,
                .division, .modulo, .frexp, .modf, .atomicCompareExchange, .dot, .firstLeadingBit, .firstTrailingBit, .sign, .dot4I8Packed,
                .dot4U8Packed, .extractBits, .packedVec3, .min, .ftoi, .insertBits, .zeroWorkgroupVar,
            ],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "struct PackedVec3 {\n",
                "    union { T x; T r; };\n",
                "    union { T y; T g; };\n",
                "    union { T z; T b; };\n",
                "    uint8_t __padding[sizeof(T)];\n",
                "    \n",
                "    PackedVec3() { }\n",
                "    \n",
                "    PackedVec3(packed_vec<T, 3> v) : x(v.x), y(v.y), z(v.z) { }\n",
                "    \n",
                "    operator vec<T, 3>() const thread { return vec<T, 3>(x, y, z); }\n",
                "    operator vec<T, 3>() const device { return vec<T, 3>(x, y, z); }\n",
                "    operator vec<T, 3>() const constant { return vec<T, 3>(x, y, z); }\n",
                "    operator vec<T, 3>() const threadgroup { return vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const thread { return packed_vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const device { return packed_vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const constant { return packed_vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const threadgroup { return packed_vec<T, 3>(x, y, z); }\n",
                "    \n",
                "    T operator[](int i) const { return i ? i == 2 ? z : y : x; }\n",
                "    T operator[](int i) const device { return i ? i == 2 ? z : y : x; }\n",
                "    device T& operator[](int i) device { return i ? i == 2 ? z : y : x; }\n",
                "    constant T& operator[](int i) constant { return i ? i == 2 ? z : y : x; }\n",
                "    thread T& operator[](int i) thread { return i ? i == 2 ? z : y : x; }\n",
                "    threadgroup T& operator[](int i) threadgroup { return i ? i == 2 ? z : y : x; }\n",
                "};\n",
                "\n",
                "template<typename T, int C>\n",
                "struct PackedMatrix {\n",
                "    PackedVec3<T> columns[C];\n",
                "};\n",
                "\n",
                "struct texture_external {\n",
                "    texture2d<float> FirstPlane;\n",
                "    texture2d<float> SecondPlane;\n",
                "    float3x2 UVRemapMatrix;\n",
                "    float4x3 ColorSpaceConversionMatrix;\n",
                "    float3x3 PrimariesConversionMatrix;\n",
                "    uint2 VisibleSize;\n",
                "    uint get_width(uint lod = 0) const { return VisibleSize.x ? VisibleSize.x : FirstPlane.get_width(lod); }\n",
                "    uint get_height(uint lod = 0) const { return VisibleSize.y ? VisibleSize.y : FirstPlane.get_height(lod); }\n",
                "    float4 to_destination_color_space(float3 rgb, float alpha, float premultiplied) const\n",
                "    {\n",
                "        if (PrimariesConversionMatrix[0][0] == 0.0f)\n",
                "            return float4(rgb * mix(alpha, 1.0f, premultiplied), alpha);\n",
                "        float3 const straight = (premultiplied != 0.0f && alpha > 0.0f) ? rgb / alpha : rgb;\n",
                "        float3 const magnitude = abs(straight);\n",
                "        float3 const linearLight = sign(straight) * select(pow((magnitude + 0.055f) / 1.055f, 2.4f), magnitude / 12.92f, magnitude <= 0.04045f);\n",
                "        float3 const converted = PrimariesConversionMatrix * linearLight;\n",
                "        float3 const convertedMagnitude = abs(converted);\n",
                "        float3 const encoded = sign(converted) * select(1.055f * pow(convertedMagnitude, 1.0f / 2.4f) - 0.055f, convertedMagnitude * 12.92f, convertedMagnitude <= 0.0031308f);\n",
                "        return float4(encoded * alpha, alpha);\n",
                "    }\n",
                "};\n",
                "\n",
                "template<typename T>\n",
                "static __attribute__((always_inline)) packed_vec<T, 3> __pack(vec<T, 3> unpacked) { return unpacked; }\n",
                "\n",
                "template<typename T, int C>\n",
                "static __attribute__((always_inline)) PackedMatrix<T, C> __pack(matrix<T, C, 3> unpacked)\n",
                "{\n",
                "    PackedMatrix<T, C> packed;\n",
                "    for (int i = 0; i < C; i++)\n",
                "        packed.columns[i] = PackedVec3<T>(packed_vec<T, 3>(unpacked[i]));\n",
                "    return packed;\n",
                "}\n",
                "\n",
                "template<typename T>\n",
                "static __attribute__((always_inline)) vec<T, 3> __unpack(packed_vec<T, 3> packed) { return packed; }\n",
                "\n",
                "template<typename T>\n",
                "static vec<T, 3> __unpack(PackedVec3<T> packed) { return packed; }\n",
                "\n",
                "template<typename T, int C>\n",
                "static __attribute__((always_inline)) matrix<T, C, 3> __unpack(PackedMatrix<T, C> packed)\n",
                "{\n",
                "    matrix<T, C, 3> unpacked;\n",
                "    for (int i = 0; i < C; i++)\n",
                "        unpacked[i] = vec<T, 3>(packed.columns[i]);\n",
                "    return unpacked;\n",
                "}\n",
                "\n",
                "template<typename T, size_t N>\n",
                "struct __PackedTypeImpl<array<T, N>> {\n",
                "using Type = array<__PackedType<T>, N>;\n",
                "};\n",
                "\n",
                "template<typename T, size_t N>\n",
                "struct __PackedTypeImpl<array<vec<T, 3>, N>> {using Type = array<PackedVec3<T>, N>;};\n",
                "\n",
                "template<typename T, int C>\n",
                "struct __PackedTypeImpl<matrix<T, C, 3>> {using Type = PackedMatrix<T, C>;};\n",
                "\n",
                "template<typename T, size_t N>\n",
                "static __attribute__((always_inline)) array<PackedVec3<T>, N> __pack(array<vec<T, 3>, N> unpacked)\n",
                "{\n",
                "    array<PackedVec3<T>, N> packed;\n",
                "    for (size_t i = 0; i < N; ++i)\n",
                "        packed[i] = PackedVec3<T>(unpacked[i]);\n",
                "    return packed;\n",
                "}\n",
                "\n",
                "template<typename T, size_t N>\n",
                "static __attribute__((always_inline)) array<__PackedType<T>, N> __pack(array<T, N> unpacked)\n",
                "{\n",
                "    array<__PackedType<T>, N> packed;\n",
                "    for (size_t i = 0; i < N; ++i)\n",
                "        packed[i] = __pack(unpacked[i]);\n",
                "    return packed;\n",
                "}\n",
                "\n",
                "template<typename T, size_t N>\n",
                "struct __UnpackedTypeImpl<array<T, N>> {\n",
                "using Type = array<__UnpackedType<T>, N>;\n",
                "};\n",
                "\n",
                "template<typename T, size_t N>\n",
                "struct __UnpackedTypeImpl<array<PackedVec3<T>, N>> {using Type = array<vec<T, 3>, N>;};\n",
                "\n",
                "template<typename T, int C>\n",
                "struct __UnpackedTypeImpl<PackedMatrix<T, C>> {using Type = matrix<T, C, 3>;};\n",
                "\n",
                "template<typename T, size_t N>\n",
                "static __attribute__((always_inline)) array<vec<T, 3>, N> __unpack(array<PackedVec3<T>, N> packed)\n",
                "{\n",
                "    array<vec<T, 3>, N> unpacked;\n",
                "    for (size_t i = 0; i < N; ++i)\n",
                "        unpacked[i] = vec<T, 3>(packed[i]);\n",
                "    return unpacked;\n",
                "}\n",
                "\n",
                "template<typename T, size_t N>\n",
                "static __attribute__((always_inline)) array<__UnpackedType<T>, N> __unpack(array<T, N> packed)\n",
                "{\n",
                "    array<__UnpackedType<T>, N> unpacked;\n",
                "    for (size_t i = 0; i < N; ++i)\n",
                "        unpacked[i] = __unpack(packed[i]);\n",
                "    return unpacked;\n",
                "}\n",
                "\n",
                "template<typename T>\n",
                "static T __workgroup_uniform_load(threadgroup T* const ptr)\n",
                "{\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    auto result = *ptr;\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    return result;\n",
                "}\n",
                "\n",
                "template<typename T>\n",
                "static T __workgroup_uniform_load(threadgroup atomic<T>* const ptr)\n",
                "{\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    auto result = atomic_load_explicit(ptr, memory_order_relaxed);\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    return result;\n",
                "}\n",
                "\n",
                "template<typename T, typename U, typename V = conditional_t<is_scalar_v<U>, T, U>>\n",
                "static V __wgslDiv(T lhs, U rhs)\n",
                "{\n",
                "    auto predicate = V(rhs) == V(0);\n",
                "    if constexpr (is_signed_v<U>)\n",
                "        predicate = predicate || (V(lhs) == V(numeric_limits<T>::lowest()) && V(rhs) == V(-1));\n",
                "    return lhs / select(V(rhs), V(1), predicate);\n",
                "}\n",
                "\n",
                "template<typename T, typename U, typename V = conditional_t<is_scalar_v<U>, T, U>>\n",
                "static V __wgslMod(T lhs, U rhs)\n",
                "{\n",
                "    auto predicate = V(rhs) == V(0);\n",
                "    if constexpr (is_signed_v<U>)\n",
                "        predicate = predicate || (V(lhs) == V(numeric_limits<T>::lowest()) && V(rhs) == V(-1));\n",
                "    return select(lhs % V(rhs), V(0), predicate);\n",
                "}\n",
                "\n",
                "template<typename T, typename U>\n",
                "struct __frexp_result {\n",
                "    T fract;\n",
                "    U exp;\n",
                "};\n",
                "\n",
                "template<typename T, typename U = conditional_t<is_vector_v<T>, vec<int, vec_elements<T>::value ?: 2>, int>>\n",
                "static __frexp_result<T, U> __wgslFrexp(T value)\n",
                "{\n",
                "    __frexp_result<T, U> result;\n",
                "    result.fract = frexp(value, result.exp);\n",
                "    return result;\n",
                "}\n",
                "\n",
                "template<typename T, typename U>\n",
                "struct __modf_result {\n",
                "    T fract;\n",
                "    U whole;\n",
                "};\n",
                "\n",
                "template<typename T>\n",
                "static __modf_result<T, T> __wgslModf(T value)\n",
                "{\n",
                "    __modf_result<T, T> result;\n",
                "    result.fract = modf(value, result.whole);\n",
                "    return result;\n",
                "}\n",
                "\n",
                "template<typename T, typename U = bool>\n",
                "struct __atomic_compare_exchange_result {\n",
                "    T old_value;\n",
                "    U exchanged;\n",
                "};\n",
                "\n",
                "template<typename T, typename S, typename V> __atomic_compare_exchange_result<S> __wgslAtomicCompareExchangeWeak(T atomic1, S compare, V value) {\n",
                "    auto innerCompare = compare;\n",
                "    bool exchanged = atomic_compare_exchange_weak_explicit(atomic1, &innerCompare, value, memory_order_relaxed, memory_order_relaxed);\n",
                "    return __atomic_compare_exchange_result<S> { innerCompare, exchanged };\n",
                "}\n",
                "template<typename T, unsigned N>\n",
                "static T __wgslDot(vec<T, N> lhs, vec<T, N> rhs)\n",
                "{\n",
                "    auto result = lhs[0] * rhs[0] + lhs[1] * rhs[1];\n",
                "    if constexpr (N > 2) result += lhs[2] * rhs[2];\n",
                "    if constexpr (N > 3) result += lhs[3] * rhs[3];\n",
                "    return result;\n",
                "}\n",
                "static int __wgslDot4I8Packed(uint lhs, uint rhs)\n",
                "{\n",
                "    auto vec1 = as_type<packed_char4>(lhs);    auto vec2 = as_type<packed_char4>(rhs);    return vec1[0] * vec2[0] + vec1[1] * vec2[1] + vec1[2] * vec2[2] + vec1[3] * vec2[3];}\n",
                "static uint __wgslDot4U8Packed(uint lhs, uint rhs)\n",
                "{\n",
                "    auto vec1 = as_type<packed_uchar4>(lhs);    auto vec2 = as_type<packed_uchar4>(rhs);    return vec1[0] * vec2[0] + vec1[1] * vec2[1] + vec1[2] * vec2[2] + vec1[3] * vec2[3];}\n",
                "template<typename T>\n",
                "static T __wgslFirstLeadingBit(T e)\n",
                "{\n",
                "    if constexpr (is_signed_v<T>)\n",
                "        return select(T(31 - select(clz(e), clz(~e), e < T(0))), T(-1), e == T(0) || e == T(-1));\n",
                "    else\n",
                "        return select(T(31 - clz(e)), T(-1), e == T(0));\n",
                "}\n",
                "template<typename T>\n",
                "static T __wgslFirstTrailingBit(T e)\n",
                "{\n",
                "    return select(ctz(e), T(-1), e == T(0));\n",
                "}\n",
                "template<typename T>\n",
                "static T __wgslSign(T e)\n",
                "{\n",
                "    return select(select(T(-1), T(1), e > 0), T(0), e == 0);\n",
                "}\n",
                "template<typename T>\n",
                "static T __wgslExtractBits(T e, uint offset, uint count)\n",
                "{\n",
                "    auto o = min(offset, 32u);\n",
                "    auto c = min(count, 32u - o);\n",
                "    return select((T)0, extract_bits(e, min(o, 31u), c), c);\n",
                "}\n",
                "static uint __attribute__((always_inline)) __wgslMin(uint a, uint b)\n",
                "{\n",
                "return min(a, b);\n",
                "}\n",
                "\n",
                "template <typename T, typename S>\n",
                "static T __wgslFtoi(S value)\n",
                "{\n",
                "    if constexpr (is_same_v<make_scalar_t<S>, half>)\n",
                "    return T(select(clamp(value, max(S(numeric_limits<T>::min()), numeric_limits<S>::lowest()), numeric_limits<S>::max()), S(0), isnan(value)));\n",
                "    else\n",
                "    return T(select(clamp(value, S(numeric_limits<T>::min()), S(numeric_limits<T>::max() - ((128 << (!is_signed_v<T>)) - 1))), S(0), isnan(value)));\n",
                "}\n",
                "\n",
                "template <typename T>\n",
                "static T __wgslInsertBits(T e, T newBits, unsigned offset, unsigned count)\n",
                "{\n",
                "    constexpr unsigned w = 8 * static_cast<unsigned>(sizeof(make_scalar_t<T>));\n",
                "    const unsigned o = min(offset, w);\n",
                "    const unsigned c = min(count, w - o);\n",
                "    return insert_bits(e, newBits, min(o, w - 1), c);\n",
                "}\n",
                "\n",
                "template<typename T>\n",
                "static void __wgslZeroWorkgroupVar(threadgroup T& v)\n",
                "{\n",
                "    threadgroup char* p = (threadgroup char*)(&v);\n",
                "    for (uint i = 0u; i < sizeof(T); i++)\n",
                "        p[i] = 0;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [
                .workgroupUniformLoad, .workgroupUniformLoadAtomic, .division, .modulo, .frexp, .modf, .atomicCompareExchange, .dot,
                .firstLeadingBit, .firstTrailingBit, .sign, .dot4I8Packed, .dot4U8Packed, .extractBits, .min, .ftoi, .insertBits,
                .zeroWorkgroupVar,
            ]
        ),
        (
            name: "workgroupUniformLoad with shader validation",
            uses: [.workgroupUniformLoad, .workgroupUniformLoadAtomic],
            shaderValidationEnabled: true,
            helpers: [
                "template<typename T>\n",
                "[[clang::optnone]] static T __workgroup_uniform_load(threadgroup T* const ptr)\n",
                "{\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    auto result = *ptr;\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    return result;\n",
                "}\n",
                "\n",
                "template<typename T>\n",
                "[[clang::optnone]] static T __workgroup_uniform_load(threadgroup atomic<T>* const ptr)\n",
                "{\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    auto result = atomic_load_explicit(ptr, memory_order_relaxed);\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    return result;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.workgroupUniformLoad, .workgroupUniformLoadAtomic]
        ),
        (
            name: "externalTextures",
            uses: [.externalTextures],
            shaderValidationEnabled: false,
            helpers: [
                "struct texture_external {\n",
                "    texture2d<float> FirstPlane;\n",
                "    texture2d<float> SecondPlane;\n",
                "    float3x2 UVRemapMatrix;\n",
                "    float4x3 ColorSpaceConversionMatrix;\n",
                "    float3x3 PrimariesConversionMatrix;\n",
                "    uint2 VisibleSize;\n",
                "    uint get_width(uint lod = 0) const { return VisibleSize.x ? VisibleSize.x : FirstPlane.get_width(lod); }\n",
                "    uint get_height(uint lod = 0) const { return VisibleSize.y ? VisibleSize.y : FirstPlane.get_height(lod); }\n",
                "    float4 to_destination_color_space(float3 rgb, float alpha, float premultiplied) const\n",
                "    {\n",
                "        if (PrimariesConversionMatrix[0][0] == 0.0f)\n",
                "            return float4(rgb * mix(alpha, 1.0f, premultiplied), alpha);\n",
                "        float3 const straight = (premultiplied != 0.0f && alpha > 0.0f) ? rgb / alpha : rgb;\n",
                "        float3 const magnitude = abs(straight);\n",
                "        float3 const linearLight = sign(straight) * select(pow((magnitude + 0.055f) / 1.055f, 2.4f), magnitude / 12.92f, magnitude <= 0.04045f);\n",
                "        float3 const converted = PrimariesConversionMatrix * linearLight;\n",
                "        float3 const convertedMagnitude = abs(converted);\n",
                "        float3 const encoded = sign(converted) * select(1.055f * pow(convertedMagnitude, 1.0f / 2.4f) - 0.055f, convertedMagnitude * 12.92f, convertedMagnitude <= 0.0031308f);\n",
                "        return float4(encoded * alpha, alpha);\n",
                "    }\n",
                "};\n",
                "\n",
            ]
            .joined(),
            usesAfter: []
        ),
        (
            name: "packArray",
            uses: [.packArray],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, size_t N>\n",
                "struct __PackedTypeImpl<array<T, N>> {\n",
                "using Type = array<__PackedType<T>, N>;\n",
                "};\n",
                "\n",
                "template<typename T, size_t N>\n",
                "static __attribute__((always_inline)) array<__PackedType<T>, N> __pack(array<T, N> unpacked)\n",
                "{\n",
                "    array<__PackedType<T>, N> packed;\n",
                "    for (size_t i = 0; i < N; ++i)\n",
                "        packed[i] = __pack(unpacked[i]);\n",
                "    return packed;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: []
        ),
        (
            name: "unpackArray",
            uses: [.unpackArray],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, size_t N>\n",
                "struct __UnpackedTypeImpl<array<T, N>> {\n",
                "using Type = array<__UnpackedType<T>, N>;\n",
                "};\n",
                "\n",
                "template<typename T, size_t N>\n",
                "static __attribute__((always_inline)) array<__UnpackedType<T>, N> __unpack(array<T, N> packed)\n",
                "{\n",
                "    array<__UnpackedType<T>, N> unpacked;\n",
                "    for (size_t i = 0; i < N; ++i)\n",
                "        unpacked[i] = __unpack(packed[i]);\n",
                "    return unpacked;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: []
        ),
        (
            name: "packVector",
            uses: [.packVector],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static __attribute__((always_inline)) packed_vec<T, 3> __pack(vec<T, 3> unpacked) { return unpacked; }\n",
                "\n",
            ]
            .joined(),
            usesAfter: []
        ),
        (
            name: "unpackVector",
            uses: [.unpackVector],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static __attribute__((always_inline)) vec<T, 3> __unpack(packed_vec<T, 3> packed) { return packed; }\n",
                "\n",
            ]
            .joined(),
            usesAfter: []
        ),
        (
            name: "workgroupUniformLoad",
            uses: [.workgroupUniformLoad],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static T __workgroup_uniform_load(threadgroup T* const ptr)\n",
                "{\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    auto result = *ptr;\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    return result;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.workgroupUniformLoad]
        ),
        (
            name: "workgroupUniformLoadAtomic",
            uses: [.workgroupUniformLoadAtomic],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static T __workgroup_uniform_load(threadgroup atomic<T>* const ptr)\n",
                "{\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    auto result = atomic_load_explicit(ptr, memory_order_relaxed);\n",
                "    threadgroup_barrier(mem_flags::mem_threadgroup);\n",
                "    return result;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.workgroupUniformLoadAtomic]
        ),
        (
            name: "division",
            uses: [.division],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, typename U, typename V = conditional_t<is_scalar_v<U>, T, U>>\n",
                "static V __wgslDiv(T lhs, U rhs)\n",
                "{\n",
                "    auto predicate = V(rhs) == V(0);\n",
                "    if constexpr (is_signed_v<U>)\n",
                "        predicate = predicate || (V(lhs) == V(numeric_limits<T>::lowest()) && V(rhs) == V(-1));\n",
                "    return lhs / select(V(rhs), V(1), predicate);\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.division]
        ),
        (
            name: "modulo",
            uses: [.modulo],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, typename U, typename V = conditional_t<is_scalar_v<U>, T, U>>\n",
                "static V __wgslMod(T lhs, U rhs)\n",
                "{\n",
                "    auto predicate = V(rhs) == V(0);\n",
                "    if constexpr (is_signed_v<U>)\n",
                "        predicate = predicate || (V(lhs) == V(numeric_limits<T>::lowest()) && V(rhs) == V(-1));\n",
                "    return select(lhs % V(rhs), V(0), predicate);\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.modulo]
        ),
        (
            name: "frexp",
            uses: [.frexp],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, typename U>\n",
                "struct __frexp_result {\n",
                "    T fract;\n",
                "    U exp;\n",
                "};\n",
                "\n",
                "template<typename T, typename U = conditional_t<is_vector_v<T>, vec<int, vec_elements<T>::value ?: 2>, int>>\n",
                "static __frexp_result<T, U> __wgslFrexp(T value)\n",
                "{\n",
                "    __frexp_result<T, U> result;\n",
                "    result.fract = frexp(value, result.exp);\n",
                "    return result;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.frexp]
        ),
        (
            name: "modf",
            uses: [.modf],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, typename U>\n",
                "struct __modf_result {\n",
                "    T fract;\n",
                "    U whole;\n",
                "};\n",
                "\n",
                "template<typename T>\n",
                "static __modf_result<T, T> __wgslModf(T value)\n",
                "{\n",
                "    __modf_result<T, T> result;\n",
                "    result.fract = modf(value, result.whole);\n",
                "    return result;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.modf]
        ),
        (
            name: "atomicCompareExchange",
            uses: [.atomicCompareExchange],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, typename U = bool>\n",
                "struct __atomic_compare_exchange_result {\n",
                "    T old_value;\n",
                "    U exchanged;\n",
                "};\n",
                "\n",
                "template<typename T, typename S, typename V> __atomic_compare_exchange_result<S> __wgslAtomicCompareExchangeWeak(T atomic1, S compare, V value) {\n",
                "    auto innerCompare = compare;\n",
                "    bool exchanged = atomic_compare_exchange_weak_explicit(atomic1, &innerCompare, value, memory_order_relaxed, memory_order_relaxed);\n",
                "    return __atomic_compare_exchange_result<S> { innerCompare, exchanged };\n",
                "}\n",
            ]
            .joined(),
            usesAfter: [.atomicCompareExchange]
        ),
        (
            name: "fragDepth",
            uses: [.fragDepth],
            shaderValidationEnabled: false,
            helpers: "",
            usesAfter: [.fragDepth]
        ),
        (
            name: "dot",
            uses: [.dot],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T, unsigned N>\n",
                "static T __wgslDot(vec<T, N> lhs, vec<T, N> rhs)\n",
                "{\n",
                "    auto result = lhs[0] * rhs[0] + lhs[1] * rhs[1];\n",
                "    if constexpr (N > 2) result += lhs[2] * rhs[2];\n",
                "    if constexpr (N > 3) result += lhs[3] * rhs[3];\n",
                "    return result;\n",
                "}\n",
            ]
            .joined(),
            usesAfter: [.dot]
        ),
        (
            name: "firstLeadingBit",
            uses: [.firstLeadingBit],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static T __wgslFirstLeadingBit(T e)\n",
                "{\n",
                "    if constexpr (is_signed_v<T>)\n",
                "        return select(T(31 - select(clz(e), clz(~e), e < T(0))), T(-1), e == T(0) || e == T(-1));\n",
                "    else\n",
                "        return select(T(31 - clz(e)), T(-1), e == T(0));\n",
                "}\n",
            ]
            .joined(),
            usesAfter: [.firstLeadingBit]
        ),
        (
            name: "firstTrailingBit",
            uses: [.firstTrailingBit],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static T __wgslFirstTrailingBit(T e)\n",
                "{\n",
                "    return select(ctz(e), T(-1), e == T(0));\n",
                "}\n",
            ]
            .joined(),
            usesAfter: [.firstTrailingBit]
        ),
        (
            name: "sign",
            uses: [.sign],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static T __wgslSign(T e)\n",
                "{\n",
                "    return select(select(T(-1), T(1), e > 0), T(0), e == 0);\n",
                "}\n",
            ]
            .joined(),
            usesAfter: [.sign]
        ),
        (
            name: "sampleMask",
            uses: [.sampleMask],
            shaderValidationEnabled: false,
            helpers: "",
            usesAfter: [.sampleMask]
        ),
        (
            name: "frontFacing",
            uses: [.frontFacing],
            shaderValidationEnabled: false,
            helpers: "",
            usesAfter: [.frontFacing]
        ),
        (
            name: "sampleIndex",
            uses: [.sampleIndex],
            shaderValidationEnabled: false,
            helpers: "",
            usesAfter: [.sampleIndex]
        ),
        (
            name: "dot4I8Packed",
            uses: [.dot4I8Packed],
            shaderValidationEnabled: false,
            helpers: [
                "static int __wgslDot4I8Packed(uint lhs, uint rhs)\n",
                "{\n",
                "    auto vec1 = as_type<packed_char4>(lhs);    auto vec2 = as_type<packed_char4>(rhs);    return vec1[0] * vec2[0] + vec1[1] * vec2[1] + vec1[2] * vec2[2] + vec1[3] * vec2[3];}\n",
            ]
            .joined(),
            usesAfter: [.dot4I8Packed]
        ),
        (
            name: "dot4U8Packed",
            uses: [.dot4U8Packed],
            shaderValidationEnabled: false,
            helpers: [
                "static uint __wgslDot4U8Packed(uint lhs, uint rhs)\n",
                "{\n",
                "    auto vec1 = as_type<packed_uchar4>(lhs);    auto vec2 = as_type<packed_uchar4>(rhs);    return vec1[0] * vec2[0] + vec1[1] * vec2[1] + vec1[2] * vec2[2] + vec1[3] * vec2[3];}\n",
            ]
            .joined(),
            usesAfter: [.dot4U8Packed]
        ),
        (
            name: "extractBits",
            uses: [.extractBits],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static T __wgslExtractBits(T e, uint offset, uint count)\n",
                "{\n",
                "    auto o = min(offset, 32u);\n",
                "    auto c = min(count, 32u - o);\n",
                "    return select((T)0, extract_bits(e, min(o, 31u), c), c);\n",
                "}\n",
            ]
            .joined(),
            usesAfter: [.extractBits]
        ),
        (
            name: "packedVec3",
            uses: [.packedVec3],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "struct PackedVec3 {\n",
                "    union { T x; T r; };\n",
                "    union { T y; T g; };\n",
                "    union { T z; T b; };\n",
                "    uint8_t __padding[sizeof(T)];\n",
                "    \n",
                "    PackedVec3() { }\n",
                "    \n",
                "    PackedVec3(packed_vec<T, 3> v) : x(v.x), y(v.y), z(v.z) { }\n",
                "    \n",
                "    operator vec<T, 3>() const thread { return vec<T, 3>(x, y, z); }\n",
                "    operator vec<T, 3>() const device { return vec<T, 3>(x, y, z); }\n",
                "    operator vec<T, 3>() const constant { return vec<T, 3>(x, y, z); }\n",
                "    operator vec<T, 3>() const threadgroup { return vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const thread { return packed_vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const device { return packed_vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const constant { return packed_vec<T, 3>(x, y, z); }\n",
                "    operator packed_vec<T, 3>() const threadgroup { return packed_vec<T, 3>(x, y, z); }\n",
                "    \n",
                "    T operator[](int i) const { return i ? i == 2 ? z : y : x; }\n",
                "    T operator[](int i) const device { return i ? i == 2 ? z : y : x; }\n",
                "    device T& operator[](int i) device { return i ? i == 2 ? z : y : x; }\n",
                "    constant T& operator[](int i) constant { return i ? i == 2 ? z : y : x; }\n",
                "    thread T& operator[](int i) thread { return i ? i == 2 ? z : y : x; }\n",
                "    threadgroup T& operator[](int i) threadgroup { return i ? i == 2 ? z : y : x; }\n",
                "};\n",
                "\n",
                "template<typename T, int C>\n",
                "struct PackedMatrix {\n",
                "    PackedVec3<T> columns[C];\n",
                "};\n",
                "\n",
            ]
            .joined(),
            usesAfter: []
        ),
        (
            name: "min",
            uses: [.min],
            shaderValidationEnabled: false,
            helpers: [
                "static uint __attribute__((always_inline)) __wgslMin(uint a, uint b)\n",
                "{\n",
                "return min(a, b);\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.min]
        ),
        (
            name: "ftoi",
            uses: [.ftoi],
            shaderValidationEnabled: false,
            helpers: [
                "template <typename T, typename S>\n",
                "static T __wgslFtoi(S value)\n",
                "{\n",
                "    if constexpr (is_same_v<make_scalar_t<S>, half>)\n",
                "    return T(select(clamp(value, max(S(numeric_limits<T>::min()), numeric_limits<S>::lowest()), numeric_limits<S>::max()), S(0), isnan(value)));\n",
                "    else\n",
                "    return T(select(clamp(value, S(numeric_limits<T>::min()), S(numeric_limits<T>::max() - ((128 << (!is_signed_v<T>)) - 1))), S(0), isnan(value)));\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.ftoi]
        ),
        (
            name: "insertBits",
            uses: [.insertBits],
            shaderValidationEnabled: false,
            helpers: [
                "template <typename T>\n",
                "static T __wgslInsertBits(T e, T newBits, unsigned offset, unsigned count)\n",
                "{\n",
                "    constexpr unsigned w = 8 * static_cast<unsigned>(sizeof(make_scalar_t<T>));\n",
                "    const unsigned o = min(offset, w);\n",
                "    const unsigned c = min(count, w - o);\n",
                "    return insert_bits(e, newBits, min(o, w - 1), c);\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.insertBits]
        ),
        (
            name: "zeroWorkgroupVar",
            uses: [.zeroWorkgroupVar],
            shaderValidationEnabled: false,
            helpers: [
                "template<typename T>\n",
                "static void __wgslZeroWorkgroupVar(threadgroup T& v)\n",
                "{\n",
                "    threadgroup char* p = (threadgroup char*)(&v);\n",
                "    for (uint i = 0u; i < sizeof(T); i++)\n",
                "        p[i] = 0;\n",
                "}\n",
                "\n",
            ]
            .joined(),
            usesAfter: [.zeroWorkgroupVar]
        ),
    ]
}
// END the C++ goldens
