// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

/// The writer-side GPU-family decision, C++ `metalAppleGPUFamily() < 9`.
///
/// Made once from `DeviceState.appleGPUFamily`; an unknown family (`0xFF`) is `.apple9OrLater`, as in C++. Every family
/// decision is an exhaustive switch over it.
@_spi(Testing)
public enum WriterGPUClass: Sendable {
    case belowApple9
    case apple9OrLater

    @_spi(Testing)
    public init(appleGPUFamily: UInt32) {
        self = appleGPUFamily < 9 ? .belowApple9 : .apple9OrLater
    }
}

/// A fixed helper body: it may contain internally bounded subscripts and attributes, so only this file can create one.
@_spi(Testing)
public struct MSLHelperText: Sendable {
    private(set) var literal: ByteLiteral

    fileprivate init(_ literal: ByteLiteral) {
        self.literal = literal
    }
}

/// The MTLCompiler and Metal-optimizer workaround spellings, byte-exact with MetalFunctionWriter.cpp.
@_spi(Testing)
public enum MTLWorkaround {
    @_spi(Testing)
    public static func declareForwardProgress(_ gpuClass: WriterGPUClass) -> MSLText {
        switch gpuClass {
        case .belowApple9:
            "uint32_t __wgslEnsureForwardProgress = 0;"
        case .apple9OrLater:
            "volatile uint32_t __wgslEnsureForwardProgress = 0; if (!__wgslEnsureForwardProgress)"
        }
    }

    @_spi(Testing)
    public static func checkForwardProgress(_ gpuClass: WriterGPUClass) -> MSLText {
        switch gpuClass {
        case .belowApple9:
            "if (__wgslEnsureForwardProgress == 4294967295u) break;"
        case .apple9OrLater:
            "if (++__wgslEnsureForwardProgress == 4294967295u) break;"
        }
    }

    @_spi(Testing)
    public static let declareOpaqueScope: MSLText =
        "volatile uint32_t __wgslEnsureSwitchClauseScope = 0; if (!__wgslEnsureSwitchClauseScope)"

    /// The volatile read around an atomic load (C++ `metalAppleGPUFamily() >= 9`); nil below Apple9.
    @_spi(Testing)
    public static func atomicLoadPrefix(_ gpuClass: WriterGPUClass) -> MSLText? {
        switch gpuClass {
        case .belowApple9:
            nil
        case .apple9OrLater:
            "({ volatile auto __wgslAtomicLoadResult = "
        }
    }

    @_spi(Testing)
    public static func atomicLoadSuffix(_ gpuClass: WriterGPUClass) -> MSLText? {
        switch gpuClass {
        case .belowApple9:
            nil
        case .apple9OrLater:
            "; __wgslAtomicLoadResult; })"
        }
    }

    /// The `discard` spelling C++ emits on x86_64 (`CPU(X86_64)`, DEV-11), with no trailing `;`.
    @_spi(Testing)
    public static let discardFragment: MSLText = "__asm volatile(\"\"); discard_fragment()"

    /// C++ `minimumInlinedReturnSize`: from Apple9 on, a function that is not an entry point and returns a struct or an array of
    /// at least this size is forced inline.
    @_spi(Testing)
    public static let minimumInlinedReturnSize = ByteSize(bytes: 128)

    @_spi(Testing)
    public static let forceInlineAttribute: MSLText = "__attribute__((always_inline)) "

    /// On `__workgroup_uniform_load` when shader validation is enabled.
    @_spi(Testing)
    public static let optnoneAttribute = MSLHelperText("[[clang::optnone]] ")

    /// The declaration that starts an outlined array constant, `const constant T __wgslConstN = …;`.
    @_spi(Testing)
    public static let outlinedConstantPrefix: MSLText = "const constant "

    /// The `__wgslMin` helper of every clamped index, at indentation 0: C++ appends its `return` line without `m_indent`.
    @_spi(Testing)
    public static let wgslMinHelper = MSLHelperText(
        """
        static uint __attribute__((always_inline)) __wgslMin(uint a, uint b)
        {
        return min(a, b);
        }


        """
    )

    /// The byte-wise zeroing of a workgroup variable, at indentation 0.
    @_spi(Testing)
    public static let zeroWorkgroupVarHelper = MSLHelperText(
        """
        template<typename T>
        static void __wgslZeroWorkgroupVar(threadgroup T& v)
        {
            threadgroup char* p = (threadgroup char*)(&v);
            for (uint i = 0u; i < sizeof(T); i++)
                p[i] = 0;
        }


        """
    )
}

/// The helpers of C++ `HelperGenerator` in C++ order, as the C++ compiler sees their `DEFINE_*HELPER` bodies after
/// preprocessing (`#__VA_ARGS__` collapses whitespace and turns the macros' `\n` into newlines).
///
/// The identifiers a helper declares are prefixed with underscores so that they cannot collide with a shader's own names,
/// since WGSL rejects an identifier beginning with two underscores.
@_spi(Testing)
public enum MSLHelper: CaseIterable, Sendable {
    case acos
    case asin
    case acosh
    case atanh
    case inverseSqrt
    case log
    case log2
    case sqrt
    case packFloatToSnorm2x16
    case packFloatToUnorm2x16
    case packFloatToSnorm4x8
    case packFloatToUnorm4x8
    case textureSampleBaseClampToEdge
    case textureExternalSampleBaseClampToEdge
    case textureSampleBiasWithOffset2d
    case textureSampleBiasWithOffset2dArray
    case textureSampleBiasWithOffset3d

    /// The C++ `emit<Name>`/`didEmit<Name>` suffix.
    @_spi(Testing)
    public var name: StaticString {
        switch self {
        case .acos:
            "Acos"
        case .asin:
            "Asin"
        case .acosh:
            "Acosh"
        case .atanh:
            "Atanh"
        case .inverseSqrt:
            "InverseSqrt"
        case .log:
            "Log"
        case .log2:
            "Log2"
        case .sqrt:
            "Sqrt"
        case .packFloatToSnorm2x16:
            "PackFloatToSnorm2x16"
        case .packFloatToUnorm2x16:
            "PackFloatToUnorm2x16"
        case .packFloatToSnorm4x8:
            "PackFloatToSnorm4x8"
        case .packFloatToUnorm4x8:
            "PackFloatToUnorm4x8"
        case .textureSampleBaseClampToEdge:
            "TextureSampleBaseClampToEdge"
        case .textureExternalSampleBaseClampToEdge:
            "TextureExternalSampleBaseClampToEdge"
        case .textureSampleBiasWithOffset2d:
            "TextureSampleBiasWithOffset2d"
        case .textureSampleBiasWithOffset2dArray:
            "TextureSampleBiasWithOffset2dArray"
        case .textureSampleBiasWithOffset3d:
            "TextureSampleBiasWithOffset3d"
        }
    }

    @_spi(Testing)
    public var text: MSLHelperText {
        switch self {
        case .acos:
            MSLHelperText(
                "template <typename T> T __wgslAcos(T value) { return acos(select(value, T(0), value < T(-1) || value > T(1))); }"
            )
        case .asin:
            MSLHelperText(
                "template <typename T> T __wgslAsin(T value) { return asin(select(value, T(0), value < T(-1) || value > T(1))); }"
            )
        case .acosh:
            MSLHelperText(
                "template <typename T> T __wgslAcosh(T value) { return acosh(select(value, T(0), value < T(1) || value > T(numeric_limits<T>::max()))); }"
            )
        case .atanh:
            MSLHelperText(
                "template <typename T> T __wgslAtanh(T value) { return atanh(select(value, T(0), value < T(-1) || value > T(1))); }"
            )
        case .inverseSqrt:
            MSLHelperText(
                "template <typename T> T __wgslInverseSqrt(T value) { return rsqrt(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }"
            )
        case .log:
            MSLHelperText(
                "template <typename T> T __wgslLog(T value) { if constexpr(__wgslMetalAppleGPUFamily < 9) { \n volatile auto result = log(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); return result; } else { \n return log(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }\n }"
            )
        case .log2:
            MSLHelperText(
                "template <typename T> T __wgslLog2(T value) { return log2(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }"
            )
        case .sqrt:
            MSLHelperText(
                "template <typename T> T __wgslSqrt(T value) { return sqrt(select(value, T(0), value < T(0) || value > T(numeric_limits<T>::infinity()))); }"
            )
        case .packFloatToSnorm2x16:
            MSLHelperText(
                "template <typename T>\n auto __wgslPackFloatToSnorm2x16(T value)\n {\n if constexpr(__wgslMetalAppleGPUFamily < 9) { \n volatile auto result = pack_float_to_snorm2x16(value);\n return result;\n } else { \n auto result = pack_float_to_snorm2x16(value);\n return result;\n }\n }\n"
            )
        case .packFloatToUnorm2x16:
            MSLHelperText(
                "template <typename T>\n auto __wgslPackFloatToUnorm2x16(T value)\n {\n if constexpr(__wgslMetalAppleGPUFamily < 9) { \n volatile auto result = pack_float_to_unorm2x16(value);\n return result;\n } else { \n auto result = pack_float_to_unorm2x16(value);\n return result;\n }\n }\n"
            )
        case .packFloatToSnorm4x8:
            MSLHelperText(
                "template <typename T>\n auto __wgslPackFloatToSnorm4x8(T value)\n {\n if constexpr(__wgslMetalAppleGPUFamily < 9) { \n volatile auto result = pack_float_to_snorm4x8(value);\n return result;\n } else { \n auto result = pack_float_to_snorm4x8(value);\n return result;\n }\n }\n"
            )
        case .packFloatToUnorm4x8:
            MSLHelperText(
                "template <typename T>\n auto __wgslPackFloatToUnorm4x8(T value)\n {\n if constexpr(__wgslMetalAppleGPUFamily < 9) { \n volatile auto result = pack_float_to_unorm4x8(value);\n return result;\n } else { \n auto result = pack_float_to_unorm4x8(value);\n return result;\n }\n }\n"
            )
        // These helpers take their texture by constant reference, as every function the shader declares does;
        // see FunctionDefinitionWriter::emitTextureReference() for why a texture is never copied.
        case .textureSampleBaseClampToEdge:
            MSLHelperText(
                """
                float4 __wgslTextureSampleBaseClampToEdge(const constant texture2d<float>& __texture, sampler __sampler, float2 __coords)
                {
                    float2 const __bounds = (float2(0.5f) / float2(uint2(__texture.get_width(), __texture.get_height())));
                    return __texture.sample(__sampler, clamp(__coords, __bounds, float2(1.0f) - __bounds));
                }

                """
            )
        // The frame's alpha arrives in the second plane's alpha channel: a single-plane frame's second plane
        // is a swizzled view of its own texture, which puts the frame's alpha there, and a decoded frame's
        // chroma plane has no alpha channel of its own, so sampling it yields 1. Both kinds of frame
        // therefore take this one path. Sampling an external texture produces premultiplied values, and the
        // second plane's blue channel says whether plane 0 already holds premultiplied color: a real chroma
        // plane samples it as 0, and so does a single-plane frame the import path left with straight alpha, so
        // only those get multiplied here. Premultiplying up front matters for a filtering sampler, which has
        // to filter color that was already premultiplied rather than premultiply the filtered result.
        //
        // The coordinate is clamped to half a texel of the frame, which is the first plane's size, since that
        // is what textureDimensions() reports. A subsampled second plane needs a wider bound than that, but
        // applying the wider one to both planes would move the first plane's edge texels inward by up to a
        // whole texel - with a subsampled chroma plane the bound lands exactly on the boundary between the
        // first two texels, so the frame's first row and column are lost. Each plane therefore gets clamped
        // to its own edge, which leaves the first plane spec-exact and still keeps a repeating address mode
        // from wrapping the far edge of the second plane into the near one.
        //
        // An external texture appears to the shader as one 2D texture of the frame's size, so the caller's
        // filter applies to that image and not to the planes it is reconstructed from. A subsampled chroma
        // plane therefore has to be interpolated up to the first plane's grid whatever the caller asked for:
        // sampling it nearest would give every 2x2 block one flat chroma value, which is what made a nearest
        // sampler disagree with copyExternalImageToTexture on the same frame. A second plane that is not
        // subsampled belongs to a single-plane frame, where it is a full-resolution swizzled view carrying the
        // alpha and the premultiplied flag, and filtering those would defeat a nearest sampler, so that case
        // keeps the caller's sampler. Interpolating needs no address mode of its own because the coordinate is
        // already clamped inside the plane's outermost texel centers, so no tap can leave the texture.
        case .textureExternalSampleBaseClampToEdge:
            MSLHelperText(
                """
                float4 __wgslTextureSampleBaseClampToEdge(texture_external __texture, sampler __sampler, float2 __inputCoords)
                {
                    constexpr sampler __reconstructionSampler(coord::normalized, address::clamp_to_edge, filter::linear);
                    uint2 const __firstPlaneSize = uint2(__texture.FirstPlane.get_width(), __texture.FirstPlane.get_height());
                    uint2 const __secondPlaneSize = uint2(__texture.SecondPlane.get_width(), __texture.SecondPlane.get_height());
                    float2 const __lumaBounds = (float2(0.5f) / float2(__firstPlaneSize));
                    float2 const __chromaBounds = (float2(0.5f) / float2(__secondPlaneSize));
                    float2 const __coords = clamp((__texture.UVRemapMatrix * float3(__inputCoords, 1)).xy, __lumaBounds, float2(1.0f) - __lumaBounds);
                    float2 const __secondCoords = clamp(__coords, __chromaBounds, float2(1.0f) - __chromaBounds);
                    float const __y = __texture.FirstPlane.sample(__sampler, __coords).r;
                    float4 const __second = all(__secondPlaneSize == __firstPlaneSize)
                        ? __texture.SecondPlane.sample(__sampler, __secondCoords)
                        : __texture.SecondPlane.sample(__reconstructionSampler, __secondCoords);
                    float3 const __rgb = __texture.ColorSpaceConversionMatrix * float4(float3(__y, __second.rg), 1);
                    return __texture.to_destination_color_space(__rgb, __second.a, __second.b);
                }

                """
            )
        // Apple GPUs drop sample()'s constant offset in the packed mip tail of a non-power-of-two texture, so
        // there it is folded into the normalized coordinate instead, which is exact for every address mode.
        case .textureSampleBiasWithOffset2d:
            MSLHelperText(
                """
                template<int __x, int __y>
                float4 __wgslTextureSampleBiasWithOffset(const constant texture2d<float>& __texture, sampler __sampler, float2 __coords, float __bias)
                {
                    if constexpr(__wgslMetalAppleGPUFamily <= 9) {
                        uint2 const __size = uint2(__texture.get_width(), __texture.get_height());
                        if (!all((__size & (__size - 1u)) == 0u)) {
                            uint const __levels = __texture.get_num_mip_levels();
                            float const __lod = clamp(__texture.calculate_clamped_lod(__sampler, __coords * exp2(__bias)), 0.0f, float(__levels - 1));
                            uint const __low = uint(__lod);
                            uint const __high = min(__low + 1u, __levels - 1u);
                            uint2 const __lowSize = uint2(__texture.get_width(__low), __texture.get_height(__low));
                            uint2 const __highSize = uint2(__texture.get_width(__high), __texture.get_height(__high));
                            if (!all(min(__lowSize, __highSize) >= 8u)) {
                                float2 const __offset = float2(__x, __y);
                                return mix(__texture.sample(__sampler, __coords + __offset / float2(__lowSize), level(float(__low))),
                                    __texture.sample(__sampler, __coords + __offset / float2(__highSize), level(float(__high))), __lod - float(__low));
                            }
                        }
                    }
                    return __texture.sample(__sampler, __coords, bias(__bias), int2(__x, __y));
                }

                """
            )
        case .textureSampleBiasWithOffset2dArray:
            MSLHelperText(
                """
                template<int __x, int __y>
                float4 __wgslTextureSampleBiasWithOffset(const constant texture2d_array<float>& __texture, sampler __sampler, float2 __coords, uint __arrayIndex, float __bias)
                {
                    if constexpr(__wgslMetalAppleGPUFamily <= 9) {
                        uint2 const __size = uint2(__texture.get_width(), __texture.get_height());
                        if (!all((__size & (__size - 1u)) == 0u)) {
                            uint const __levels = __texture.get_num_mip_levels();
                            float const __lod = clamp(__texture.calculate_clamped_lod(__sampler, __coords * exp2(__bias)), 0.0f, float(__levels - 1));
                            uint const __low = uint(__lod);
                            uint const __high = min(__low + 1u, __levels - 1u);
                            uint2 const __lowSize = uint2(__texture.get_width(__low), __texture.get_height(__low));
                            uint2 const __highSize = uint2(__texture.get_width(__high), __texture.get_height(__high));
                            if (!all(min(__lowSize, __highSize) >= 8u)) {
                                float2 const __offset = float2(__x, __y);
                                return mix(__texture.sample(__sampler, __coords + __offset / float2(__lowSize), __arrayIndex, level(float(__low))),
                                    __texture.sample(__sampler, __coords + __offset / float2(__highSize), __arrayIndex, level(float(__high))), __lod - float(__low));
                            }
                        }
                    }
                    return __texture.sample(__sampler, __coords, __arrayIndex, bias(__bias), int2(__x, __y));
                }

                """
            )
        case .textureSampleBiasWithOffset3d:
            MSLHelperText(
                """
                template<int __x, int __y, int __z>
                float4 __wgslTextureSampleBiasWithOffset(const constant texture3d<float>& __texture, sampler __sampler, float3 __coords, float __bias)
                {
                    if constexpr(__wgslMetalAppleGPUFamily <= 9) {
                        uint3 const __size = uint3(__texture.get_width(), __texture.get_height(), __texture.get_depth());
                        if (!all((__size & (__size - 1u)) == 0u)) {
                            uint const __levels = __texture.get_num_mip_levels();
                            float const __lod = clamp(__texture.calculate_clamped_lod(__sampler, __coords * exp2(__bias)), 0.0f, float(__levels - 1));
                            uint const __low = uint(__lod);
                            uint const __high = min(__low + 1u, __levels - 1u);
                            uint3 const __lowSize = uint3(__texture.get_width(__low), __texture.get_height(__low), __texture.get_depth(__low));
                            uint3 const __highSize = uint3(__texture.get_width(__high), __texture.get_height(__high), __texture.get_depth(__high));
                            if (!all(min(__lowSize, __highSize) >= 8u)) {
                                float3 const __offset = float3(__x, __y, __z);
                                return mix(__texture.sample(__sampler, __coords + __offset / float3(__lowSize), level(float(__low))),
                                    __texture.sample(__sampler, __coords + __offset / float3(__highSize), level(float(__high))), __lod - float(__low));
                            }
                        }
                    }
                    return __texture.sample(__sampler, __coords, bias(__bias), int3(__x, __y, __z));
                }

                """
            )
        }
    }
}

/// C++ `HelperGenerator`: writes a helper into the writer's output, which it holds (C++ binds `m_output` at construction), so a
/// helper cannot land in another sink; a caller emits each helper at most once, guarded by its `didEmit` flag.
struct HelperGenerator: ~Copyable {
    var output: MSLWriter

    init(_ output: consuming MSLWriter) {
        self.output = output
    }

    mutating func emitAcos() {
        output.append(MSLHelper.acos.text)
    }

    var didEmitAcos = false

    mutating func emitAsin() {
        output.append(MSLHelper.asin.text)
    }

    var didEmitAsin = false

    mutating func emitAcosh() {
        output.append(MSLHelper.acosh.text)
    }

    var didEmitAcosh = false

    mutating func emitAtanh() {
        output.append(MSLHelper.atanh.text)
    }

    var didEmitAtanh = false

    mutating func emitInverseSqrt() {
        output.append(MSLHelper.inverseSqrt.text)
    }

    var didEmitInverseSqrt = false

    mutating func emitLog() {
        output.append(MSLHelper.log.text)
    }

    var didEmitLog = false

    mutating func emitLog2() {
        output.append(MSLHelper.log2.text)
    }

    var didEmitLog2 = false

    mutating func emitSqrt() {
        output.append(MSLHelper.sqrt.text)
    }

    var didEmitSqrt = false

    mutating func emitPackFloatToSnorm2x16() {
        output.append(MSLHelper.packFloatToSnorm2x16.text)
    }

    var didEmitPackFloatToSnorm2x16 = false

    mutating func emitPackFloatToUnorm2x16() {
        output.append(MSLHelper.packFloatToUnorm2x16.text)
    }

    var didEmitPackFloatToUnorm2x16 = false

    mutating func emitPackFloatToSnorm4x8() {
        output.append(MSLHelper.packFloatToSnorm4x8.text)
    }

    var didEmitPackFloatToSnorm4x8 = false

    mutating func emitPackFloatToUnorm4x8() {
        output.append(MSLHelper.packFloatToUnorm4x8.text)
    }

    var didEmitPackFloatToUnorm4x8 = false

    mutating func emitTextureSampleBaseClampToEdge() {
        output.append(MSLHelper.textureSampleBaseClampToEdge.text)
    }

    var didEmitTextureSampleBaseClampToEdge = false

    mutating func emitTextureExternalSampleBaseClampToEdge() {
        output.append(MSLHelper.textureExternalSampleBaseClampToEdge.text)
    }

    var didEmitTextureExternalSampleBaseClampToEdge = false

    mutating func emitTextureSampleBiasWithOffset2d() {
        output.append(MSLHelper.textureSampleBiasWithOffset2d.text)
    }

    var didEmitTextureSampleBiasWithOffset2d = false

    mutating func emitTextureSampleBiasWithOffset2dArray() {
        output.append(MSLHelper.textureSampleBiasWithOffset2dArray.text)
    }

    var didEmitTextureSampleBiasWithOffset2dArray = false

    mutating func emitTextureSampleBiasWithOffset3d() {
        output.append(MSLHelper.textureSampleBiasWithOffset3d.text)
    }

    var didEmitTextureSampleBiasWithOffset3d = false
}

// The bodies of emitNecessaryHelpers' helpers whose lines hold subscripts or attributes.
extension MSLHelperText {
    static let packedVec3Padding = MSLHelperText("uint8_t __padding[sizeof(T)];\n")
    static let packedVec3Subscript = MSLHelperText("T operator[](int i) const { return i ? i == 2 ? z : y : x; }\n")
    static let packedVec3DeviceSubscript = MSLHelperText("T operator[](int i) const device { return i ? i == 2 ? z : y : x; }\n")
    static let packedVec3DeviceReferenceSubscript = MSLHelperText(
        "device T& operator[](int i) device { return i ? i == 2 ? z : y : x; }\n"
    )
    static let packedVec3ConstantReferenceSubscript = MSLHelperText(
        "constant T& operator[](int i) constant { return i ? i == 2 ? z : y : x; }\n"
    )
    static let packedVec3ThreadReferenceSubscript = MSLHelperText(
        "thread T& operator[](int i) thread { return i ? i == 2 ? z : y : x; }\n"
    )
    static let packedVec3ThreadgroupReferenceSubscript = MSLHelperText(
        "threadgroup T& operator[](int i) threadgroup { return i ? i == 2 ? z : y : x; }\n"
    )
    static let packedMatrixColumns = MSLHelperText("PackedVec3<T> columns[C];\n")
    static let textureExternalPrimariesConversionCheck = MSLHelperText("    if (PrimariesConversionMatrix[0][0] == 0.0f)\n")
    static let packMatrixColumn = MSLHelperText("packed.columns[i] = PackedVec3<T>(packed_vec<T, 3>(unpacked[i]));\n")
    static let unpackMatrixColumn = MSLHelperText("unpacked[i] = vec<T, 3>(packed.columns[i]);\n")
    static let packVec3ArrayElement = MSLHelperText("packed[i] = PackedVec3<T>(unpacked[i]);\n")
    static let packArrayElement = MSLHelperText("packed[i] = __pack(unpacked[i]);\n")
    static let unpackVec3ArrayElement = MSLHelperText("unpacked[i] = vec<T, 3>(packed[i]);\n")
    static let unpackArrayElement = MSLHelperText("unpacked[i] = __unpack(packed[i]);\n")
    static let dotFirstTwoComponents = MSLHelperText("auto result = lhs[0] * rhs[0] + lhs[1] * rhs[1];\n")
    static let dotThirdComponent = MSLHelperText("if constexpr (N > 2) result += lhs[2] * rhs[2];\n")
    static let dotFourthComponent = MSLHelperText("if constexpr (N > 3) result += lhs[3] * rhs[3];\n")
    static let dot4x8PackedSum = MSLHelperText("return vec1[0] * vec2[0] + vec1[1] * vec2[1] + vec1[2] * vec2[2] + vec1[3] * vec2[3];")
}

/// Emits `helper` through its `HelperGenerator` function into an empty writer (WorkaroundGoldenTests).
@_spi(Testing)
public func emitHelperForTesting(_ helper: MSLHelper) -> ContiguousArray<UInt8> {
    var helperGenerator = HelperGenerator(MSLWriter())
    switch helper {
    case .acos:
        helperGenerator.emitAcos()
    case .asin:
        helperGenerator.emitAsin()
    case .acosh:
        helperGenerator.emitAcosh()
    case .atanh:
        helperGenerator.emitAtanh()
    case .inverseSqrt:
        helperGenerator.emitInverseSqrt()
    case .log:
        helperGenerator.emitLog()
    case .log2:
        helperGenerator.emitLog2()
    case .sqrt:
        helperGenerator.emitSqrt()
    case .packFloatToSnorm2x16:
        helperGenerator.emitPackFloatToSnorm2x16()
    case .packFloatToUnorm2x16:
        helperGenerator.emitPackFloatToUnorm2x16()
    case .packFloatToSnorm4x8:
        helperGenerator.emitPackFloatToSnorm4x8()
    case .packFloatToUnorm4x8:
        helperGenerator.emitPackFloatToUnorm4x8()
    case .textureSampleBaseClampToEdge:
        helperGenerator.emitTextureSampleBaseClampToEdge()
    case .textureExternalSampleBaseClampToEdge:
        helperGenerator.emitTextureExternalSampleBaseClampToEdge()
    case .textureSampleBiasWithOffset2d:
        helperGenerator.emitTextureSampleBiasWithOffset2d()
    case .textureSampleBiasWithOffset2dArray:
        helperGenerator.emitTextureSampleBiasWithOffset2dArray()
    case .textureSampleBiasWithOffset3d:
        helperGenerator.emitTextureSampleBiasWithOffset3d()
    }
    return helperGenerator.output.finish()
}
