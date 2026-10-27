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

import Metal
import WebGPU_Private.WebGPUCpp

// The conversions and tables of render pipeline creation. An out-of-range enum value traps.

/// The component type of a vertex format.
enum VertexFormatType {
    case float
    case unsignedInteger
    case signedInteger
}

func mtlBlendOperation(_ operation: WebGPU.BlendOperation) -> MTLBlendOperation {
    switch operation {
    case .Add: .add
    case .Max: .max
    case .Min: .min
    case .ReverseSubtract: .reverseSubtract
    case .Subtract: .subtract
    @unknown default: preconditionFailure("unknown WebGPU::BlendOperation")
    }
}

func mtlBlendFactor(_ factor: WebGPU.BlendFactor) -> MTLBlendFactor {
    switch factor {
    case .Constant: .blendColor
    case .Dst: .destinationColor
    case .DstAlpha: .destinationAlpha
    case .One: .one
    case .OneMinusConstant: .oneMinusBlendColor
    case .OneMinusDst: .oneMinusDestinationColor
    case .OneMinusDstAlpha: .oneMinusDestinationAlpha
    case .OneMinusSrc: .oneMinusSourceColor
    case .Src: .sourceColor
    case .OneMinusSrcAlpha: .oneMinusSourceAlpha
    case .Zero: .zero
    case .SrcAlpha: .sourceAlpha
    case .SrcAlphaSaturated: .sourceAlphaSaturated
    @unknown default: preconditionFailure("unknown WebGPU::BlendFactor")
    }
}

/// Maps the four channel bits of `rawWriteMask`, an OptionSet<WebGPU::ColorWrite>::toRaw(); Invalid is ignored.
func mtlColorWriteMask(rawWriteMask: UInt32) -> MTLColorWriteMask {
    var mask: MTLColorWriteMask = []
    if rawWriteMask & UInt32(WebGPU.ColorWrite.Red.rawValue) != 0 {
        mask.insert(.red)
    }
    if rawWriteMask & UInt32(WebGPU.ColorWrite.Green.rawValue) != 0 {
        mask.insert(.green)
    }
    if rawWriteMask & UInt32(WebGPU.ColorWrite.Blue.rawValue) != 0 {
        mask.insert(.blue)
    }
    if rawWriteMask & UInt32(WebGPU.ColorWrite.Alpha.rawValue) != 0 {
        mask.insert(.alpha)
    }
    return mask
}

func mtlWinding(_ frontFace: WebGPU.FrontFace) -> MTLWinding {
    switch frontFace {
    case .CW: .clockwise
    case .CCW: .counterClockwise
    @unknown default: preconditionFailure("unknown WebGPU::FrontFace")
    }
}

func mtlCullMode(_ cullMode: WebGPU.CullMode) -> MTLCullMode {
    switch cullMode {
    case .None: .none
    case .Front: .front
    case .Back: .back
    @unknown default: preconditionFailure("unknown WebGPU::CullMode")
    }
}

func mtlPrimitiveType(_ topology: WebGPU.PrimitiveTopology) -> MTLPrimitiveType {
    switch topology {
    case .PointList: .point
    case .LineStrip: .lineStrip
    case .TriangleList: .triangle
    case .LineList: .line
    case .TriangleStrip: .triangleStrip
    @unknown default: preconditionFailure("unknown WebGPU::PrimitiveTopology")
    }
}

func mtlPrimitiveTopologyClass(_ topology: WebGPU.PrimitiveTopology) -> MTLPrimitiveTopologyClass {
    switch topology {
    case .PointList: .point
    case .LineStrip, .LineList: .line
    case .TriangleList, .TriangleStrip: .triangle
    @unknown default: preconditionFailure("unknown WebGPU::PrimitiveTopology")
    }
}

/// Never nil for a valid format.
func mtlIndexType(_ format: WebGPU.IndexFormat) -> MTLIndexType? {
    switch format {
    case .Uint16: .uint16
    case .Uint32: .uint32
    @unknown default: preconditionFailure("unknown WebGPU::IndexFormat")
    }
}

func mtlStencilOperation(_ operation: WebGPU.StencilOperation) -> MTLStencilOperation {
    switch operation {
    case .Keep: .keep
    case .Zero: .zero
    case .Replace: .replace
    case .Invert: .invert
    case .IncrementClamp: .incrementClamp
    case .DecrementClamp: .decrementClamp
    case .IncrementWrap: .incrementWrap
    case .DecrementWrap: .decrementWrap
    @unknown default: preconditionFailure("unknown WebGPU::StencilOperation")
    }
}

func mtlCompareFunction(_ comparison: WebGPU.CompareFunction) -> MTLCompareFunction {
    switch comparison {
    case .Never: .never
    case .Less: .less
    case .LessEqual: .lessEqual
    case .Greater: .greater
    case .GreaterEqual: .greaterEqual
    case .Equal: .equal
    case .NotEqual: .notEqual
    case .Always: .always
    @unknown default: preconditionFailure("unknown WebGPU::CompareFunction")
    }
}

func mtlVertexFormat(_ format: WebGPU.VertexFormat) -> MTLVertexFormat {
    switch format {
    case .Uint8: .uchar
    case .Uint8x2: .uchar2
    case .Uint8x4: .uchar4
    case .Sint8: .char
    case .Sint8x2: .char2
    case .Sint8x4: .char4
    case .Unorm8: .ucharNormalized
    case .Unorm8x2: .uchar2Normalized
    case .Unorm8x4: .uchar4Normalized
    case .Snorm8: .charNormalized
    case .Snorm8x2: .char2Normalized
    case .Snorm8x4: .char4Normalized
    case .Uint16: .ushort
    case .Uint16x2: .ushort2
    case .Uint16x4: .ushort4
    case .Sint16: .short
    case .Sint16x2: .short2
    case .Sint16x4: .short4
    case .Unorm16: .ushortNormalized
    case .Unorm16x2: .ushort2Normalized
    case .Unorm16x4: .ushort4Normalized
    case .Snorm16: .shortNormalized
    case .Snorm16x2: .short2Normalized
    case .Snorm16x4: .short4Normalized
    case .Float16: .half
    case .Float16x2: .half2
    case .Float16x4: .half4
    case .Float32: .float
    case .Float32x2: .float2
    case .Float32x3: .float3
    case .Float32x4: .float4
    case .Uint32: .uint
    case .Uint32x2: .uint2
    case .Uint32x3: .uint3
    case .Uint32x4: .uint4
    case .Sint32: .int
    case .Sint32x2: .int2
    case .Sint32x3: .int3
    case .Sint32x4: .int4
    case .Snorm1010102: .int1010102Normalized
    case .Unorm1010102: .uint1010102Normalized
    case .Unorm8x4Bgra: .uchar4Normalized_bgra
    @unknown default: preconditionFailure("unknown WebGPU::VertexFormat")
    }
}

func vertexFormatSize(_ format: WebGPU.VertexFormat) -> Int {
    switch format {
    case .Uint8, .Sint8, .Unorm8, .Snorm8:
        1
    case .Uint8x2, .Sint8x2, .Unorm8x2, .Snorm8x2, .Uint16, .Sint16, .Unorm16, .Snorm16, .Float16:
        2
    case .Uint8x4, .Sint8x4, .Unorm8x4, .Snorm8x4, .Uint16x2, .Sint16x2, .Unorm16x2, .Snorm16x2, .Float16x2, .Float32, .Uint32, .Sint32,
        .Snorm1010102, .Unorm1010102, .Unorm8x4Bgra:
        4
    case .Uint16x4, .Sint16x4, .Unorm16x4, .Snorm16x4, .Float16x4, .Float32x2, .Uint32x2, .Sint32x2:
        8
    case .Float32x3, .Uint32x3, .Sint32x3:
        12
    case .Float32x4, .Uint32x4, .Sint32x4:
        16
    @unknown default:
        preconditionFailure("unknown WebGPU::VertexFormat")
    }
}

func mtlVertexStepFunction(_ stepMode: WebGPU.VertexStepMode, arrayStride: UInt64) -> MTLVertexStepFunction {
    if arrayStride == 0 {
        return .constant
    }
    switch stepMode {
    case .Vertex: return .perVertex
    case .Instance: return .perInstance
    @unknown default: preconditionFailure("unknown WebGPU::VertexStepMode")
    }
}

/// The vertex format names that error messages print.
func vertexFormatName(_ format: WebGPU.VertexFormat) -> String {
    switch format {
    case .Uint8: "UChar"
    case .Uint8x2: "UChar2"
    case .Uint8x4: "UChar4"
    case .Sint8: "Char"
    case .Sint8x2: "Char2"
    case .Sint8x4: "Char4"
    case .Unorm8: "UCharNormalized"
    case .Unorm8x2: "UChar2Normalized"
    case .Unorm8x4: "UChar4Normalized"
    case .Snorm8: "CharNormalized"
    case .Snorm8x2: "Char2Normalized"
    case .Snorm8x4: "Char4Normalized"
    case .Uint16: "UShort"
    case .Uint16x2: "UShort2"
    case .Uint16x4: "UShort4"
    case .Sint16: "Short"
    case .Sint16x2: "Short2"
    case .Sint16x4: "Short4"
    case .Unorm16: "UShortNormalized"
    case .Unorm16x2: "UShort2Normalized"
    case .Unorm16x4: "UShort4Normalized"
    case .Snorm16: "ShortNormalized"
    case .Snorm16x2: "Short2Normalized"
    case .Snorm16x4: "Short4Normalized"
    case .Float16: "Half"
    case .Float16x2: "Half2"
    case .Float16x4: "Half4"
    case .Float32: "Float"
    case .Float32x2: "Float2"
    case .Float32x3: "Float3"
    case .Float32x4: "Float4"
    case .Uint32: "UInt"
    case .Uint32x2: "UInt2"
    case .Uint32x3: "UInt3"
    case .Uint32x4: "UInt4"
    case .Sint32: "Int"
    case .Sint32x2: "Int2"
    case .Sint32x3: "Int3"
    case .Sint32x4: "Int4"
    case .Snorm1010102: "SInt1010102Normalized"
    case .Unorm1010102: "UInt1010102Normalized"
    case .Unorm8x4Bgra: "Unorm8x4Bgra"
    @unknown default: preconditionFailure("unknown WebGPU::VertexFormat")
    }
}

func vertexFormatType(_ format: WebGPU.VertexFormat) -> VertexFormatType {
    switch format {
    case .Uint8, .Uint8x2, .Uint8x4, .Uint16, .Uint16x2, .Uint16x4, .Uint32, .Uint32x2, .Uint32x3, .Uint32x4:
        .unsignedInteger
    case .Sint8, .Sint8x2, .Sint8x4, .Sint16, .Sint16x2, .Sint16x4, .Sint32, .Sint32x2, .Sint32x3, .Sint32x4:
        .signedInteger
    case .Unorm8, .Unorm8x2, .Unorm8x4, .Snorm8, .Snorm8x2, .Snorm8x4, .Unorm16, .Unorm16x2, .Unorm16x4, .Snorm16, .Snorm16x2, .Snorm16x4,
        .Float16, .Float16x2, .Float16x4, .Float32, .Float32x2, .Float32x3, .Float32x4, .Snorm1010102, .Unorm1010102, .Unorm8x4Bgra:
        .float
    @unknown default:
        preconditionFailure("unknown WebGPU::VertexFormat")
    }
}

func compareFunctionName(_ compare: WebGPU.CompareFunction) -> String {
    switch compare {
    case .Never: "never"
    case .Less: "less"
    case .LessEqual: "less-equal"
    case .Greater: "greater"
    case .GreaterEqual: "greater-equal"
    case .Equal: "equal"
    case .NotEqual: "not-equal"
    case .Always: "always"
    @unknown default: preconditionFailure("unknown WebGPU::CompareFunction")
    }
}

func stencilOperationName(_ operation: WebGPU.StencilOperation) -> String {
    switch operation {
    case .Keep: "keep"
    case .Zero: "zero"
    case .Replace: "replace"
    case .Invert: "invert"
    case .IncrementClamp: "increment-clamp"
    case .DecrementClamp: "decrement-clamp"
    case .IncrementWrap: "increment-wrap"
    case .DecrementWrap: "decrement-wrap"
    @unknown default: preconditionFailure("unknown WebGPU::StencilOperation")
    }
}

func hasAlphaChannel(_ format: WebGPU.TextureFormat) -> Bool {
    switch format {
    case .R8unorm, .R8snorm, .R8uint, .R8sint, .R16uint, .R16sint, .R16unorm, .R16snorm, .Rg16unorm, .Rg16snorm, .R16float, .Rg8unorm,
        .Rg8snorm, .Rg8uint, .Rg8sint, .R32float, .R32uint, .R32sint, .Rg16uint, .Rg16sint, .Rg16float:
        false
    case .Rgba8unorm, .Rgba8unormSRGB, .Rgba8snorm, .Rgba8uint, .Rgba8sint, .Bgra8unorm, .Bgra8unormSRGB, .Rgb10a2uint, .Rgb10a2unorm,
        .Rgba16unorm, .Rgba16snorm:
        true
    case .Rg11b10ufloat, .Rgb9e5ufloat, .Rg32float, .Rg32uint, .Rg32sint:
        false
    case .Rgba16uint, .Rgba16sint, .Rgba16float, .Rgba32float, .Rgba32uint, .Rgba32sint:
        true
    case .Stencil8, .Depth16unorm, .Depth24plus, .Depth24plusStencil8, .Depth32float, .Depth32floatStencil8:
        false
    case .Bc1RgbaUnorm, .Bc1RgbaUnormSRGB, .Bc2RgbaUnorm, .Bc2RgbaUnormSRGB, .Bc3RgbaUnorm, .Bc3RgbaUnormSRGB:
        true
    case .Bc4RUnorm, .Bc4RSnorm, .Bc5RgUnorm, .Bc5RgSnorm, .Bc6hRgbUfloat, .Bc6hRgbFloat:
        false
    case .Bc7RgbaUnorm, .Bc7RgbaUnormSRGB:
        true
    case .Etc2Rgb8unorm, .Etc2Rgb8unormSRGB:
        false
    case .Etc2Rgb8a1unorm, .Etc2Rgb8a1unormSRGB, .Etc2Rgba8unorm, .Etc2Rgba8unormSRGB:
        true
    case .EacR11unorm, .EacR11snorm, .EacRg11unorm, .EacRg11snorm, .Astc4x4Unorm, .Astc4x4UnormSRGB, .Astc5x4Unorm, .Astc5x4UnormSRGB,
        .Astc5x5Unorm, .Astc5x5UnormSRGB, .Astc6x5Unorm, .Astc6x5UnormSRGB, .Astc6x6Unorm, .Astc6x6UnormSRGB, .Astc8x5Unorm,
        .Astc8x5UnormSRGB, .Astc8x6Unorm, .Astc8x6UnormSRGB, .Astc8x8Unorm, .Astc8x8UnormSRGB, .Astc10x5Unorm, .Astc10x5UnormSRGB,
        .Astc10x6Unorm, .Astc10x6UnormSRGB, .Astc10x8Unorm, .Astc10x8UnormSRGB, .Astc10x10Unorm, .Astc10x10UnormSRGB, .Astc12x10Unorm,
        .Astc12x10UnormSRGB, .Astc12x12Unorm, .Astc12x12UnormSRGB:
        false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func textureFormatAllowedForReturnType(_ format: WebGPU.TextureFormat, dataType: MTLDataType, readsAlpha: Bool) -> Bool {
    if dataType == .none {
        return true
    }

    if readsAlpha && !(dataType == .float4 || dataType == .int4 || dataType == .uint4) {
        return false
    }

    switch format {
    case .R8snorm, .R8unorm, .R16snorm, .R16unorm, .R16float, .R32float:
        return dataType == .float || dataType == .float2 || dataType == .float3 || dataType == .float4
    case .Rg8snorm, .Rg8unorm, .Rg16snorm, .Rg16unorm, .Rg16float, .Rg32float:
        return dataType == .float2 || dataType == .float3 || dataType == .float4
    case .Rgba8snorm, .Rgba8unorm, .Rgba8unormSRGB, .Bgra8unorm, .Bgra8unormSRGB, .Rgb10a2unorm, .Rgba16snorm, .Rgba16unorm, .Rgba16float,
        .Rgba32float:
        return dataType == .float4
    case .R8uint, .R16uint, .R32uint:
        return dataType == .uint || dataType == .uint2 || dataType == .uint3 || dataType == .uint4
    case .R8sint, .R16sint, .R32sint:
        return dataType == .int || dataType == .int2 || dataType == .int3 || dataType == .int4
    case .Rg8uint, .Rg16uint, .Rg32uint:
        return dataType == .uint2 || dataType == .uint3 || dataType == .uint4
    case .Rg8sint, .Rg16sint, .Rg32sint:
        return dataType == .int2 || dataType == .int3 || dataType == .int4
    case .Rgba8uint, .Rgb10a2uint, .Rgba16uint, .Rgba32uint:
        return dataType == .uint4
    case .Rgba8sint, .Rgba16sint, .Rgba32sint:
        return dataType == .int4
    case .Rg11b10ufloat:
        return dataType == .float3 || dataType == .float4
    default:
        return false
    }
}

/// 0, and an assertion failure in debug builds, for a type that is not a scalar or a vector.
func componentsForDataType(_ dataType: MTLDataType) -> UInt32 {
    switch dataType {
    case .bool, .int, .uint, .half, .float:
        return 1
    case .bool2, .int2, .uint2, .half2, .float2:
        return 2
    case .bool3, .int3, .uint3, .half3, .float3:
        return 3
    case .bool4, .int4, .uint4, .half4, .float4:
        return 4
    default:
        assertionFailure("componentsForDataType: not a scalar or vector type")
        return 0
    }
}
