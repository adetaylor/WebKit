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
import Metal
import WebGPU_Internal.Device
import WebGPU_Private.WebGPU
import WebGPU_Private.WebGPUCpp

// The texture format tables and the other format-only rules of https://gpuweb.github.io/gpuweb/#texture-formats.

enum TextureCompressFormat {
    case astc
    case bc
    case etc
}

// The usage OptionSet<WebGPU::TextureUsage> travels as its raw bits.
func textureUsageContains(_ usage: UInt8, _ bit: WebGPU.TextureUsage) -> Bool {
    usage & bit.rawValue != 0
}

func textureUsageContainsAll(_ usage: UInt8, _ other: UInt8) -> Bool {
    usage & other == other
}

// toAPI(OptionSet<WebGPU::TextureUsage>), for error messages.
func apiTextureUsage(_ usage: UInt8) -> UInt64 {
    var result: UInt64 = 0
    if textureUsageContains(usage, .CopySource) {
        result |= UInt64(WGPUTextureUsage_CopySrc)
    }
    if textureUsageContains(usage, .CopyDestination) {
        result |= UInt64(WGPUTextureUsage_CopyDst)
    }
    if textureUsageContains(usage, .TextureBinding) {
        result |= UInt64(WGPUTextureUsage_TextureBinding)
    }
    if textureUsageContains(usage, .StorageBinding) {
        result |= UInt64(WGPUTextureUsage_StorageBinding)
    }
    if textureUsageContains(usage, .RenderAttachment) {
        result |= UInt64(WGPUTextureUsage_RenderAttachment)
    }
    if textureUsageContains(usage, .Transient) {
        result |= UInt64(WGPUTextureUsage_TransientAttachment)
    }
    return result
}

func isCompressedFormat(_ format: WebGPU.TextureFormat) -> Bool {
    compressedFormatType(format) != nil
}

func compressedFormatType(_ format: WebGPU.TextureFormat) -> TextureCompressFormat? {
    // https://gpuweb.github.io/gpuweb/#packed-formats
    switch format {
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB:
        return .bc
    case .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm:
        return .etc
    case .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return .astc
    case .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return nil
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func depthSpecificFormat(_ textureFormat: WebGPU.TextureFormat) -> WebGPU.TextureFormat? {
    // https://gpuweb.github.io/gpuweb/#aspect-specific-format
    switch textureFormat {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8:
        return nil
    case .Depth16unorm:
        return .Depth16unorm
    case .Depth24plus:
        return .Depth24plus
    case .Depth24plusStencil8:
        return .Depth24plus
    case .Depth32float:
        return .Depth32float
    case .Depth32floatStencil8:
        return .Depth32float
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return nil
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func stencilSpecificFormat(_ textureFormat: WebGPU.TextureFormat) -> WebGPU.TextureFormat? {
    // https://gpuweb.github.io/gpuweb/#aspect-specific-format
    switch textureFormat {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return nil
    case .Stencil8:
        return .Stencil8
    case .Depth16unorm,
        .Depth24plus:
        return nil
    case .Depth24plusStencil8:
        return .Stencil8
    case .Depth32float:
        return nil
    case .Depth32floatStencil8:
        return .Stencil8
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return nil
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func containsDepthAspect(_ textureFormat: WebGPU.TextureFormat) -> Bool {
    depthSpecificFormat(textureFormat) != nil
}

func containsStencilAspect(_ textureFormat: WebGPU.TextureFormat) -> Bool {
    stencilSpecificFormat(textureFormat) != nil
}

@_expose(Cxx)
func isDepthOrStencilFormat(_ format: WebGPU.TextureFormat) -> Bool {
    // https://gpuweb.github.io/gpuweb/#depth-formats
    containsDepthAspect(format) || containsStencilAspect(format)
}

func texelBlockWidth(_ format: WebGPU.TextureFormat) -> UInt32 {
    // https://gpuweb.github.io/gpuweb/#texel-block-width
    switch format {
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB:
        return 4
    case .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm:
        return 4
    case .Astc4x4Unorm,
        .Astc4x4UnormSRGB:
        return 4
    case .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB:
        return 5
    case .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB:
        return 6
    case .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB:
        return 8
    case .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB:
        return 10
    case .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return 12
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return 1
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func texelBlockHeight(_ format: WebGPU.TextureFormat) -> UInt32 {
    // https://gpuweb.github.io/gpuweb/#texel-block-height
    switch format {
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB:
        return 4
    case .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm:
        return 4
    case .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB:
        return 4
    case .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB:
        return 5
    case .Astc6x6Unorm,
        .Astc6x6UnormSRGB:
        return 6
    case .Astc8x5Unorm,
        .Astc8x5UnormSRGB:
        return 5
    case .Astc8x6Unorm,
        .Astc8x6UnormSRGB:
        return 6
    case .Astc8x8Unorm,
        .Astc8x8UnormSRGB:
        return 8
    case .Astc10x5Unorm,
        .Astc10x5UnormSRGB:
        return 5
    case .Astc10x6Unorm,
        .Astc10x6UnormSRGB:
        return 6
    case .Astc10x8Unorm,
        .Astc10x8UnormSRGB:
        return 8
    case .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB:
        return 10
    case .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return 12
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return 1
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func isColorRenderableFormat(_ format: WebGPU.TextureFormat, _ device: WebGPU.Metal.Device) -> Bool {
    // https://gpuweb.github.io/gpuweb/#renderable-format
    switch format {
    case .R8unorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2uint,
        .Rgb10a2unorm,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return true
    case .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rg11b10ufloat:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1) || device.hasFeature(WebGPU.FeatureName.Rg11b10ufloatRenderable)
    case .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return false
    case .R8snorm,
        .Rg8snorm,
        .Rgba8snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func isDepthStencilRenderableFormat(_ format: WebGPU.TextureFormat) -> Bool {
    // https://gpuweb.github.io/gpuweb/#renderable-format
    switch format {
    case .R8unorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2uint,
        .Rgb10a2unorm,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Rg11b10ufloat,
        .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm:
        return false
    case .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return true
    case .R8snorm,
        .Rg8snorm,
        .Rgba8snorm,
        .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func isRenderableFormat(_ format: WebGPU.TextureFormat, _ device: WebGPU.Metal.Device) -> Bool {
    // https://gpuweb.github.io/gpuweb/#renderable-format
    switch format {
    case .R8unorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2uint,
        .Rgb10a2unorm,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return true
    case .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .R8snorm,
        .Rg8snorm,
        .Rgba8snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rg11b10ufloat:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1) || device.hasFeature(WebGPU.FeatureName.Rg11b10ufloatRenderable)
    case .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func renderTargetPixelByteCost(_ format: WebGPU.TextureFormat) -> UInt32 {
    // https://gpuweb.github.io/gpuweb/#renderable-format
    switch format {
    case .R8unorm,
        .R8uint,
        .R8sint:
        return 1
    case .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8uint,
        .Rg8sint,
        .R16unorm,
        .R16snorm:
        return 2
    case .R32float,
        .R32uint,
        .R32sint,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rg16unorm,
        .Rg16snorm:
        return 4
    case .Rgba8unorm,
        .Rgba8unormSRGB:
        return 8
    case .Rgba8uint,
        .Rgba8sint:
        return 4
    case .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2uint,
        .Rgb10a2unorm,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba16unorm,
        .Rgba16snorm:
        return 8
    case .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return 16
    case .Rg11b10ufloat:
        return 8
    case .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8,
        .R8snorm,
        .Rg8snorm,
        .Rgba8snorm,
        .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return 0
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func renderTargetPixelByteAlignment(_ format: WebGPU.TextureFormat) -> UInt32 {
    // https://gpuweb.github.io/gpuweb/#renderable-format
    switch format {
    case .R8unorm,
        .R8uint,
        .R8sint,
        .Rg8unorm,
        .Rg8uint,
        .Rg8sint,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB:
        return 1
    case .R16uint,
        .R16sint,
        .R16float,
        .R16unorm,
        .R16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba16unorm,
        .Rgba16snorm:
        return 2
    case .R32float,
        .R32uint,
        .R32sint,
        .Rgb10a2uint,
        .Rgb10a2unorm,
        .Rg32float,
        .Rg11b10ufloat,
        .Rg32uint,
        .Rg32sint,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return 4
    case .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8,
        .R8snorm,
        .Rg8snorm,
        .Rgba8snorm,
        .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return 0
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func supportsMultisampling(_ format: WebGPU.TextureFormat, _ device: WebGPU.Metal.Device) -> Bool {
    switch format {
    // https://gpuweb.github.io/gpuweb/#texture-format-caps
    case .R8unorm,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rgb10a2uint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        // https://gpuweb.github.io/gpuweb/#depth-formats
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return true
    case .R8snorm,
        .Rg8snorm,
        .Rgba8snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rg11b10ufloat:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1) || device.hasFeature(WebGPU.FeatureName.Rg11b10ufloatRenderable)
    case .R32uint,
        .R32sint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func supportsResolve(_ format: WebGPU.TextureFormat, _ device: WebGPU.Metal.Device) -> Bool {
    switch format {
    case .R8unorm,
        .R16float,
        .Rg8unorm,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rgba16float:
        return true
    case .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm:
        return false
    case .R8snorm,
        .Rg8snorm,
        .Rgba8snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rg11b10ufloat:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1) || device.hasFeature(WebGPU.FeatureName.Rg11b10ufloatRenderable)
    case .R32float,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8,
        .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .Rg8uint,
        .Rg8sint,
        .Rg16uint,
        .Rg16sint,
        .Rgba8uint,
        .Rgba8sint,
        .Rgb10a2uint,
        .Rgba16uint,
        .Rgba16sint,
        .R32uint,
        .R32sint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func supportsBlending(_ format: WebGPU.TextureFormat, _ device: WebGPU.Metal.Device) -> Bool {
    switch format {
    // https://gpuweb.github.io/gpuweb/#texture-format-caps
    case .R8unorm,
        .Rg8unorm,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .R16float,
        .Rg16float,
        .Rgba16float,
        .Rgb10a2unorm:
        return true
    case .R16unorm,
        .R16snorm,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rg11b10ufloat:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1) || device.hasFeature(WebGPU.FeatureName.Rg11b10ufloatRenderable)
    case .R32float,
        .Rg32float,
        .Rgba32float:
        return device.hasFeature(WebGPU.FeatureName.Float32Blendable)
    case .R8snorm,
        .Rg8snorm,
        .Rgba8snorm:
        return device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .R8uint,
        .R8sint,
        .R16uint,
        .R16sint,
        .Rg8uint,
        .Rg8sint,
        .Rg16uint,
        .Rg16sint,
        .Rgba8uint,
        .Rgba8sint,
        .Rgb10a2uint,
        .Rgba16uint,
        .Rgba16sint,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8,
        .R32uint,
        .R32sint,
        .Rg32uint,
        .Rg32sint,
        .Rgba32uint,
        .Rgba32sint,
        .Rgb9e5ufloat,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func hasStorageBindingCapability(
    _ format: WebGPU.TextureFormat,
    _ device: WebGPU.Metal.Device,
    _ access: WebGPU.StorageTextureAccess? = nil
) -> Bool {
    // https://gpuweb.github.io/gpuweb/#plain-color-formats
    switch format {
    // These formats always support read-only and write-only storage access;
    // texture-formats-tier2 additionally grants read-write storage access.
    case .Rgba8unorm,
        .Rgba8uint,
        .Rgba8sint,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return (access != .ReadWrite) || device.hasFeature(WebGPU.FeatureName.TextureFormatsTier2)
    case .Rgba8snorm,
        .Rg32float,
        .Rg32uint,
        .Rg32sint:
        return access != .ReadWrite
    case .Bgra8unorm:
        return (access == nil || access == .WriteOnly) && device.hasFeature(WebGPU.FeatureName.Bgra8unormStorage)
    case .R32float,
        .R32uint,
        .R32sint:
        return true
    // These formats support storage access only with texture-formats-tier1;
    // texture-formats-tier2 additionally grants read-write storage access.
    case .R8unorm,
        .R8uint,
        .R8sint,
        .R16float,
        .R16uint,
        .R16sint:
        return ((access != .ReadWrite) || device.hasFeature(WebGPU.FeatureName.TextureFormatsTier2))
            && device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .R8snorm,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R16unorm,
        .R16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgb10a2uint,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rg16float:
        return (access != .ReadWrite) && device.hasFeature(WebGPU.FeatureName.TextureFormatsTier1)
    case .Rgba8unormSRGB,
        .Bgra8unormSRGB,
        .Rgb9e5ufloat,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8,
        .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func removeSRGBSuffix(_ format: WebGPU.TextureFormat) -> WebGPU.TextureFormat {
    switch format {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16unorm,
        .R16snorm,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float:
        return format
    case .Rgba8unorm,
        .Rgba8unormSRGB:
        return .Rgba8unorm
    case .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint:
        return format
    case .Bgra8unorm,
        .Bgra8unormSRGB:
        return .Bgra8unorm
    case .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8,
        .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        return format
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB:
        return .Bc1RgbaUnorm
    case .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB:
        return .Bc2RgbaUnorm
    case .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB:
        return .Bc3RgbaUnorm
    case .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat:
        return format
    case .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB:
        return .Bc7RgbaUnorm
    case .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB:
        return .Etc2Rgb8unorm
    case .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB:
        return .Etc2Rgb8a1unorm
    case .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB:
        return .Etc2Rgba8unorm
    case .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm:
        return format
    case .Astc4x4Unorm,
        .Astc4x4UnormSRGB:
        return .Astc4x4Unorm
    case .Astc5x4Unorm,
        .Astc5x4UnormSRGB:
        return .Astc5x4Unorm
    case .Astc5x5Unorm,
        .Astc5x5UnormSRGB:
        return .Astc5x5Unorm
    case .Astc6x5Unorm,
        .Astc6x5UnormSRGB:
        return .Astc6x5Unorm
    case .Astc6x6Unorm,
        .Astc6x6UnormSRGB:
        return .Astc6x6Unorm
    case .Astc8x5Unorm,
        .Astc8x5UnormSRGB:
        return .Astc8x5Unorm
    case .Astc8x6Unorm,
        .Astc8x6UnormSRGB:
        return .Astc8x6Unorm
    case .Astc8x8Unorm,
        .Astc8x8UnormSRGB:
        return .Astc8x8Unorm
    case .Astc10x5Unorm,
        .Astc10x5UnormSRGB:
        return .Astc10x5Unorm
    case .Astc10x6Unorm,
        .Astc10x6UnormSRGB:
        return .Astc10x6Unorm
    case .Astc10x8Unorm,
        .Astc10x8UnormSRGB:
        return .Astc10x8Unorm
    case .Astc10x10Unorm,
        .Astc10x10UnormSRGB:
        return .Astc10x10Unorm
    case .Astc12x10Unorm,
        .Astc12x10UnormSRGB:
        return .Astc12x10Unorm
    case .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return .Astc12x12Unorm
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func textureViewFormatCompatible(_ format1: WebGPU.TextureFormat, _ format2: WebGPU.TextureFormat) -> Bool {
    // https://gpuweb.github.io/gpuweb/#texture-view-format-compatible

    if format1 == format2 {
        return true
    }

    return removeSRGBSuffix(format1) == removeSRGBSuffix(format2)
}

func metalTextureUsage(_ usage: UInt8, _ format: WebGPU.TextureFormat) -> MTLTextureUsage {
    var result: MTLTextureUsage = []
    if textureUsageContains(usage, .TextureBinding) {
        result.insert(.shaderRead)
    }
    if textureUsageContains(usage, .StorageBinding) {
        result.insert(.shaderWrite)
    }
    if textureUsageContains(usage, .RenderAttachment) {
        result.insert(.renderTarget)
    }
    if isDepthOrStencilFormat(format) || isCompressedFormat(format) {
        result.insert(.pixelFormatView)
    }
    return result
}

func texturePixelFormat(_ textureFormat: WebGPU.TextureFormat) -> MTLPixelFormat {
    switch textureFormat {
    case .R8unorm:
        return .r8Unorm
    case .R8snorm:
        return .r8Snorm
    case .R8uint:
        return .r8Uint
    case .R8sint:
        return .r8Sint
    case .R16unorm:
        return .r16Unorm
    case .R16snorm:
        return .r16Snorm
    case .R16uint:
        return .r16Uint
    case .R16sint:
        return .r16Sint
    case .R16float:
        return .r16Float
    case .Rg8unorm:
        return .rg8Unorm
    case .Rg8snorm:
        return .rg8Snorm
    case .Rg8uint:
        return .rg8Uint
    case .Rg8sint:
        return .rg8Sint
    case .R32float:
        return .r32Float
    case .R32uint:
        return .r32Uint
    case .R32sint:
        return .r32Sint
    case .Rg16unorm:
        return .rg16Unorm
    case .Rg16snorm:
        return .rg16Snorm
    case .Rg16uint:
        return .rg16Uint
    case .Rg16sint:
        return .rg16Sint
    case .Rg16float:
        return .rg16Float
    case .Rgba8unorm:
        return .rgba8Unorm
    case .Rgba8unormSRGB:
        return .rgba8Unorm_srgb
    case .Rgba8snorm:
        return .rgba8Snorm
    case .Rgba8uint:
        return .rgba8Uint
    case .Rgba8sint:
        return .rgba8Sint
    case .Bgra8unorm:
        return .bgra8Unorm
    case .Bgra8unormSRGB:
        return .bgra8Unorm_srgb
    case .Rgb10a2unorm:
        return .rgb10a2Unorm
    case .Rg11b10ufloat:
        return .rg11b10Float
    case .Rgb9e5ufloat:
        return .rgb9e5Float
    case .Rgb10a2uint:
        return .rgb10a2Uint
    case .Rg32float:
        return .rg32Float
    case .Rg32uint:
        return .rg32Uint
    case .Rg32sint:
        return .rg32Sint
    case .Rgba16unorm:
        return .rgba16Unorm
    case .Rgba16snorm:
        return .rgba16Snorm
    case .Rgba16uint:
        return .rgba16Uint
    case .Rgba16sint:
        return .rgba16Sint
    case .Rgba16float:
        return .rgba16Float
    case .Rgba32float:
        return .rgba32Float
    case .Rgba32uint:
        return .rgba32Uint
    case .Rgba32sint:
        return .rgba32Sint
    case .Stencil8:
        return .stencil8
    case .Depth16unorm:
        return .depth16Unorm
    case .Depth24plus:
        return .depth32Float
    case .Depth24plusStencil8:
        return .depth32Float_stencil8
    case .Depth32float:
        return .depth32Float
    case .Depth32floatStencil8:
        return .depth32Float_stencil8
    case .Etc2Rgb8unorm:
        return .etc2_rgb8
    case .Etc2Rgb8unormSRGB:
        return .etc2_rgb8_srgb
    case .Etc2Rgb8a1unorm:
        return .etc2_rgb8a1
    case .Etc2Rgb8a1unormSRGB:
        return .etc2_rgb8a1_srgb
    case .Etc2Rgba8unorm:
        return .eac_rgba8
    case .Etc2Rgba8unormSRGB:
        return .eac_rgba8_srgb
    case .EacR11unorm:
        return .eac_r11Unorm
    case .EacR11snorm:
        return .eac_r11Snorm
    case .EacRg11unorm:
        return .eac_rg11Unorm
    case .EacRg11snorm:
        return .eac_rg11Snorm
    case .Astc4x4Unorm:
        return .astc_4x4_ldr
    case .Astc4x4UnormSRGB:
        return .astc_4x4_srgb
    case .Astc5x4Unorm:
        return .astc_5x4_ldr
    case .Astc5x4UnormSRGB:
        return .astc_5x4_srgb
    case .Astc5x5Unorm:
        return .astc_5x5_ldr
    case .Astc5x5UnormSRGB:
        return .astc_5x5_srgb
    case .Astc6x5Unorm:
        return .astc_6x5_ldr
    case .Astc6x5UnormSRGB:
        return .astc_6x5_srgb
    case .Astc6x6Unorm:
        return .astc_6x6_ldr
    case .Astc6x6UnormSRGB:
        return .astc_6x6_srgb
    case .Astc8x5Unorm:
        return .astc_8x5_ldr
    case .Astc8x5UnormSRGB:
        return .astc_8x5_srgb
    case .Astc8x6Unorm:
        return .astc_8x6_ldr
    case .Astc8x6UnormSRGB:
        return .astc_8x6_srgb
    case .Astc8x8Unorm:
        return .astc_8x8_ldr
    case .Astc8x8UnormSRGB:
        return .astc_8x8_srgb
    case .Astc10x5Unorm:
        return .astc_10x5_ldr
    case .Astc10x5UnormSRGB:
        return .astc_10x5_srgb
    case .Astc10x6Unorm:
        return .astc_10x6_ldr
    case .Astc10x6UnormSRGB:
        return .astc_10x6_srgb
    case .Astc10x8Unorm:
        return .astc_10x8_ldr
    case .Astc10x8UnormSRGB:
        return .astc_10x8_srgb
    case .Astc10x10Unorm:
        return .astc_10x10_ldr
    case .Astc10x10UnormSRGB:
        return .astc_10x10_srgb
    case .Astc12x10Unorm:
        return .astc_12x10_ldr
    case .Astc12x10UnormSRGB:
        return .astc_12x10_srgb
    case .Astc12x12Unorm:
        return .astc_12x12_ldr
    case .Astc12x12UnormSRGB:
        return .astc_12x12_srgb
    #if !WTF_PLATFORM_WATCHOS
    case .Bc1RgbaUnorm:
        return .bc1_rgba
    case .Bc1RgbaUnormSRGB:
        return .bc1_rgba_srgb
    case .Bc2RgbaUnorm:
        return .bc2_rgba
    case .Bc2RgbaUnormSRGB:
        return .bc2_rgba_srgb
    case .Bc3RgbaUnorm:
        return .bc3_rgba
    case .Bc3RgbaUnormSRGB:
        return .bc3_rgba_srgb
    case .Bc4RUnorm:
        return .bc4_rUnorm
    case .Bc4RSnorm:
        return .bc4_rSnorm
    case .Bc5RgUnorm:
        return .bc5_rgUnorm
    case .Bc5RgSnorm:
        return .bc5_rgSnorm
    case .Bc6hRgbUfloat:
        return .bc6H_rgbuFloat
    case .Bc6hRgbFloat:
        return .bc6H_rgbFloat
    case .Bc7RgbaUnorm:
        return .bc7_rgbaUnorm
    case .Bc7RgbaUnormSRGB:
        return .bc7_rgbaUnorm_srgb
    #else
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB:
        return .invalid
    #endif
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func textureFormat(_ pixelFormat: MTLPixelFormat) -> WebGPU.TextureFormat? {
    switch pixelFormat {
    case .r8Unorm:
        return .R8unorm
    case .r8Snorm:
        return .R8snorm
    case .r8Uint:
        return .R8uint
    case .r8Sint:
        return .R8sint
    case .r16Uint:
        return .R16uint
    case .r16Sint:
        return .R16sint
    case .r16Float:
        return .R16float
    case .rg8Unorm:
        return .Rg8unorm
    case .rg8Snorm:
        return .Rg8snorm
    case .rg8Uint:
        return .Rg8uint
    case .rg8Sint:
        return .Rg8sint
    case .r32Float:
        return .R32float
    case .r32Uint:
        return .R32uint
    case .r32Sint:
        return .R32sint
    case .rg16Uint:
        return .Rg16uint
    case .rg16Sint:
        return .Rg16sint
    case .rg16Float:
        return .Rg16float
    case .rgba8Unorm:
        return .Rgba8unorm
    case .rgba8Unorm_srgb:
        return .Rgba8unormSRGB
    case .rgba8Snorm:
        return .Rgba8snorm
    case .rgba8Uint:
        return .Rgba8uint
    case .rgba8Sint:
        return .Rgba8sint
    case .bgra8Unorm:
        return .Bgra8unorm
    case .bgra8Unorm_srgb:
        return .Bgra8unormSRGB
    case .rgb10a2Unorm:
        return .Rgb10a2unorm
    case .rg11b10Float:
        return .Rg11b10ufloat
    case .rgb9e5Float:
        return .Rgb9e5ufloat
    case .rgb10a2Uint:
        return .Rgb10a2uint
    case .rg32Float:
        return .Rg32float
    case .rg32Uint:
        return .Rg32uint
    case .rg32Sint:
        return .Rg32sint
    case .rgba16Uint:
        return .Rgba16uint
    case .rgba16Sint:
        return .Rgba16sint
    case .rgba16Float:
        return .Rgba16float
    case .rgba32Float:
        return .Rgba32float
    case .rgba32Uint:
        return .Rgba32uint
    case .rgba32Sint:
        return .Rgba32sint
    case .stencil8:
        return .Stencil8
    case .depth16Unorm:
        return .Depth16unorm
    case .depth32Float:
        return .Depth24plus
    case .depth32Float_stencil8:
        return .Depth24plusStencil8
    case .etc2_rgb8:
        return .Etc2Rgb8unorm
    case .etc2_rgb8_srgb:
        return .Etc2Rgb8unormSRGB
    case .etc2_rgb8a1:
        return .Etc2Rgb8a1unorm
    case .etc2_rgb8a1_srgb:
        return .Etc2Rgb8a1unormSRGB
    case .eac_rgba8:
        return .Etc2Rgba8unorm
    case .eac_rgba8_srgb:
        return .Etc2Rgba8unormSRGB
    case .eac_r11Unorm:
        return .EacR11unorm
    case .eac_r11Snorm:
        return .EacR11snorm
    case .eac_rg11Unorm:
        return .EacRg11unorm
    case .eac_rg11Snorm:
        return .EacRg11snorm
    case .astc_4x4_ldr:
        return .Astc4x4Unorm
    case .astc_4x4_srgb:
        return .Astc4x4UnormSRGB
    case .astc_5x4_ldr:
        return .Astc5x4Unorm
    case .astc_5x4_srgb:
        return .Astc5x4UnormSRGB
    case .astc_5x5_ldr:
        return .Astc5x5Unorm
    case .astc_5x5_srgb:
        return .Astc5x5UnormSRGB
    case .astc_6x5_ldr:
        return .Astc6x5Unorm
    case .astc_6x5_srgb:
        return .Astc6x5UnormSRGB
    case .astc_6x6_ldr:
        return .Astc6x6Unorm
    case .astc_6x6_srgb:
        return .Astc6x6UnormSRGB
    case .astc_8x5_ldr:
        return .Astc8x5Unorm
    case .astc_8x5_srgb:
        return .Astc8x5UnormSRGB
    case .astc_8x6_ldr:
        return .Astc8x6Unorm
    case .astc_8x6_srgb:
        return .Astc8x6UnormSRGB
    case .astc_8x8_ldr:
        return .Astc8x8Unorm
    case .astc_8x8_srgb:
        return .Astc8x8UnormSRGB
    case .astc_10x5_ldr:
        return .Astc10x5Unorm
    case .astc_10x5_srgb:
        return .Astc10x5UnormSRGB
    case .astc_10x6_ldr:
        return .Astc10x6Unorm
    case .astc_10x6_srgb:
        return .Astc10x6UnormSRGB
    case .astc_10x8_ldr:
        return .Astc10x8Unorm
    case .astc_10x8_srgb:
        return .Astc10x8UnormSRGB
    case .astc_10x10_ldr:
        return .Astc10x10Unorm
    case .astc_10x10_srgb:
        return .Astc10x10UnormSRGB
    case .astc_12x10_ldr:
        return .Astc12x10Unorm
    case .astc_12x10_srgb:
        return .Astc12x10UnormSRGB
    case .astc_12x12_ldr:
        return .Astc12x12Unorm
    case .astc_12x12_srgb:
        return .Astc12x12UnormSRGB
    #if !WTF_PLATFORM_WATCHOS
    case .bc1_rgba:
        return .Bc1RgbaUnorm
    case .bc1_rgba_srgb:
        return .Bc1RgbaUnormSRGB
    case .bc2_rgba:
        return .Bc2RgbaUnorm
    case .bc2_rgba_srgb:
        return .Bc2RgbaUnormSRGB
    case .bc3_rgba:
        return .Bc3RgbaUnorm
    case .bc3_rgba_srgb:
        return .Bc3RgbaUnormSRGB
    case .bc4_rUnorm:
        return .Bc4RUnorm
    case .bc4_rSnorm:
        return .Bc4RSnorm
    case .bc5_rgUnorm:
        return .Bc5RgUnorm
    case .bc5_rgSnorm:
        return .Bc5RgSnorm
    case .bc6H_rgbuFloat:
        return .Bc6hRgbUfloat
    case .bc6H_rgbFloat:
        return .Bc6hRgbFloat
    case .bc7_rgbaUnorm:
        return .Bc7RgbaUnorm
    case .bc7_rgbaUnorm_srgb:
        return .Bc7RgbaUnormSRGB
    #endif
    default:
        return nil
    }
}

func textureBytesPerRow(_ format: WebGPU.TextureFormat, _ textureWidth: UInt32, _ sampleCount: UInt32) -> UInt {
    let blockWidth = UInt(texelBlockWidth(format))
    if blockWidth == 0 {
        assertionFailure()
        return UInt.max
    }
    var add: UInt = 0
    if UInt(textureWidth) % blockWidth != 0 {
        add = 1
    }

    let blocksInWidth = UInt(textureWidth) / blockWidth + add
    let (partialProduct, partialOverflow) = UInt(texelBlockSize(format)).multipliedReportingOverflow(by: blocksInWidth)
    let (product, overflow) = partialProduct.multipliedReportingOverflow(by: UInt(sampleCount))
    return partialOverflow || overflow ? UInt.max : product
}

func texelBlockSize(_ format: WebGPU.TextureFormat) -> UInt32 {
    // For depth-stencil textures, the input value to this function
    // needs to be the output of aspectSpecificFormat().
    assert(!containsDepthAspect(format) || !containsStencilAspect(format))
    switch format {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint:
        return 1
    case .R16unorm,
        .R16snorm,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint:
        return 2
    case .R32float,
        .R32uint,
        .R32sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint:
        return 4
    case .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float:
        return 8
    case .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return 16
    case .Stencil8:
        return 1
    case .Depth16unorm:
        return 2
    case .Depth24plus:
        assert(texturePixelFormat(format) == .depth32Float)
        return 4
    case .Depth24plusStencil8:
        assertionFailure()
        return 0
    case .Depth32float:
        return 4
    case .Depth32floatStencil8:
        assertionFailure()
        return 0
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB:
        return 8
    case .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB:
        return 16
    case .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB:
        return 16
    case .Bc4RUnorm,
        .Bc4RSnorm:
        return 8
    case .Bc5RgUnorm,
        .Bc5RgSnorm:
        return 16
    case .Bc6hRgbUfloat,
        .Bc6hRgbFloat:
        return 16
    case .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB:
        return 16
    case .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB:
        return 8
    case .EacR11unorm,
        .EacR11snorm:
        return 8
    case .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacRg11unorm,
        .EacRg11snorm:
        return 16
    case .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return 16
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func aspectSpecificFormat(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> WebGPU.TextureFormat? {
    // https://gpuweb.github.io/gpuweb/#aspect-specific-format

    switch aspect {
    case .All:
        return format
    case .StencilOnly:
        return stencilSpecificFormat(format)
    case .DepthOnly:
        return depthSpecificFormat(format)
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureAspect")
    }
}

func depthOnlyAspectMetalFormat(_ textureFormat: WebGPU.TextureFormat) -> MTLPixelFormat? {
    switch textureFormat {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16unorm,
        .R16snorm,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint,
        .Stencil8:
        return nil
    case .Depth16unorm,
        .Depth24plus,
        .Depth24plusStencil8,
        .Depth32float,
        .Depth32floatStencil8:
        // This is a bit surprising, but it should be correct.
        // When using the view as a render target, we'll bind it to MTLRenderPassDescriptor.depthAttachment, which will ignore the stencil bits.
        // When attaching the view as a shader resource view, only the depth aspect is visible anyway.
        // When copying to/from the texture, we can use MTLBlitOption.MTLBlitOptionDepthFromDepthStencil to ignore the stencil bits.
        return texturePixelFormat(textureFormat)
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return nil
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func stencilOnlyAspectMetalFormat(_ textureFormat: WebGPU.TextureFormat) -> MTLPixelFormat? {
    switch textureFormat {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16unorm,
        .R16snorm,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return nil
    case .Stencil8:
        return texturePixelFormat(textureFormat)
    case .Depth16unorm,
        .Depth24plus:
        return nil
    case .Depth24plusStencil8:
        assert(texturePixelFormat(textureFormat) == .depth32Float_stencil8)
        return .x32_stencil8
    case .Depth32float:
        return nil
    case .Depth32floatStencil8:
        return .x32_stencil8
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return nil
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func resolveTextureFormat(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> WebGPU.TextureFormat? {
    switch aspect {
    case .All:
        return format
    case .DepthOnly:
        return depthSpecificFormat(format)
    case .StencilOnly:
        return stencilSpecificFormat(format)
    @unknown default:
        return nil
    }
}

struct TextureExtent {
    var width: UInt32
    var height: UInt32
    var depthOrArrayLayers: UInt32
}

// WTF::roundUpToMultipleOfNonPowerOfTwo(size_t, T), which wraps. A zero divisor returns x, as x % 0 == x on arm64.
func roundUpToMultipleOfNonPowerOfTwo<T: FixedWidthInteger & UnsignedInteger>(_ divisor: T, _ x: T) -> T {
    let remainder = divisor == 0 ? x : x % divisor
    if remainder == 0 {
        return x
    }
    return x &+ (divisor &- remainder)
}

func physicalTextureExtent(
    _ dimension: WebGPU.TextureDimension,
    _ format: WebGPU.TextureFormat,
    _ logicalExtent: TextureExtent
) -> TextureExtent {
    let blockWidth = texelBlockWidth(format)
    let blockHeight = texelBlockHeight(format)
    if blockWidth == 0 || blockHeight == 0 {
        return TextureExtent(width: 1, height: 1, depthOrArrayLayers: 1)
    }

    switch dimension {
    case ._1d:
        return TextureExtent(
            width: roundUpToMultipleOfNonPowerOfTwo(blockWidth, logicalExtent.width),
            height: 1,
            depthOrArrayLayers: logicalExtent.depthOrArrayLayers
        )
    case ._2d, ._3d:
        return TextureExtent(
            width: roundUpToMultipleOfNonPowerOfTwo(blockWidth, logicalExtent.width),
            height: roundUpToMultipleOfNonPowerOfTwo(blockHeight, logicalExtent.height),
            depthOrArrayLayers: logicalExtent.depthOrArrayLayers
        )
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureDimension")
    }
}

func refersToSingleAspect(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> Bool {
    switch aspect {
    case .All:
        if containsDepthAspect(format) && containsStencilAspect(format) {
            return false
        }
    case .StencilOnly:
        if !containsStencilAspect(format) {
            return false
        }
    case .DepthOnly:
        if !containsDepthAspect(format) {
            return false
        }
    @unknown default:
        break
    }

    return true
}

func isValidDepthStencilCopySource(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> Bool {
    // https://gpuweb.github.io/gpuweb/#depth-formats
    assert(isDepthOrStencilFormat(format))
    switch format {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16unorm,
        .R16snorm,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        assertionFailure()
        return false
    case .Stencil8,
        .Depth16unorm:
        return true
    case .Depth24plus:
        return false
    case .Depth24plusStencil8:
        return aspect == .StencilOnly
    case .Depth32float,
        .Depth32floatStencil8:
        return true
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        assertionFailure()
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

func isValidDepthStencilCopyDestination(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> Bool {
    // https://gpuweb.github.io/gpuweb/#depth-formats
    assert(isDepthOrStencilFormat(format))
    switch format {
    case .R8unorm,
        .R8snorm,
        .R8uint,
        .R8sint,
        .R16unorm,
        .R16snorm,
        .R16uint,
        .R16sint,
        .R16float,
        .Rg8unorm,
        .Rg8snorm,
        .Rg8uint,
        .Rg8sint,
        .R32float,
        .R32uint,
        .R32sint,
        .Rg16unorm,
        .Rg16snorm,
        .Rg16uint,
        .Rg16sint,
        .Rg16float,
        .Rgba8unorm,
        .Rgba8unormSRGB,
        .Rgba8snorm,
        .Rgba8uint,
        .Rgba8sint,
        .Bgra8unorm,
        .Bgra8unormSRGB,
        .Rgb10a2unorm,
        .Rg11b10ufloat,
        .Rgb9e5ufloat,
        .Rgb10a2uint,
        .Rg32float,
        .Rg32uint,
        .Rg32sint,
        .Rgba16unorm,
        .Rgba16snorm,
        .Rgba16uint,
        .Rgba16sint,
        .Rgba16float,
        .Rgba32float,
        .Rgba32uint,
        .Rgba32sint:
        return false
    case .Stencil8,
        .Depth16unorm:
        return true
    case .Depth24plus:
        return false
    case .Depth24plusStencil8:
        return aspect == .StencilOnly
    case .Depth32float:
        return false
    case .Depth32floatStencil8:
        return aspect == .StencilOnly
    case .Bc1RgbaUnorm,
        .Bc1RgbaUnormSRGB,
        .Bc2RgbaUnorm,
        .Bc2RgbaUnormSRGB,
        .Bc3RgbaUnorm,
        .Bc3RgbaUnormSRGB,
        .Bc4RUnorm,
        .Bc4RSnorm,
        .Bc5RgUnorm,
        .Bc5RgSnorm,
        .Bc6hRgbUfloat,
        .Bc6hRgbFloat,
        .Bc7RgbaUnorm,
        .Bc7RgbaUnormSRGB,
        .Etc2Rgb8unorm,
        .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm,
        .Etc2Rgb8a1unormSRGB,
        .Etc2Rgba8unorm,
        .Etc2Rgba8unormSRGB,
        .EacR11unorm,
        .EacR11snorm,
        .EacRg11unorm,
        .EacRg11snorm,
        .Astc4x4Unorm,
        .Astc4x4UnormSRGB,
        .Astc5x4Unorm,
        .Astc5x4UnormSRGB,
        .Astc5x5Unorm,
        .Astc5x5UnormSRGB,
        .Astc6x5Unorm,
        .Astc6x5UnormSRGB,
        .Astc6x6Unorm,
        .Astc6x6UnormSRGB,
        .Astc8x5Unorm,
        .Astc8x5UnormSRGB,
        .Astc8x6Unorm,
        .Astc8x6UnormSRGB,
        .Astc8x8Unorm,
        .Astc8x8UnormSRGB,
        .Astc10x5Unorm,
        .Astc10x5UnormSRGB,
        .Astc10x6Unorm,
        .Astc10x6UnormSRGB,
        .Astc10x8Unorm,
        .Astc10x8UnormSRGB,
        .Astc10x10Unorm,
        .Astc10x10UnormSRGB,
        .Astc12x10Unorm,
        .Astc12x10UnormSRGB,
        .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return false
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

// RecordOverflow-style WTF::Checked<uint64_t>: once an operation overflows, the result stays overflowed.
private struct OverflowRecordingUInt64 {
    var value: UInt64
    var overflowed = false

    init(_ value: UInt64) {
        self.value = value
    }

    func adding(_ other: OverflowRecordingUInt64) -> OverflowRecordingUInt64 {
        var result = OverflowRecordingUInt64(0)
        let (sum, overflow) = value.addingReportingOverflow(other.value)
        result.value = sum
        result.overflowed = overflowed || other.overflowed || overflow
        return result
    }

    func multiplied(by other: UInt64) -> OverflowRecordingUInt64 {
        var result = OverflowRecordingUInt64(0)
        let (product, overflow) = value.multipliedReportingOverflow(by: other)
        result.value = product
        result.overflowed = overflowed || overflow
        return result
    }
}

// A missing bytesPerRow or rowsPerImage is WGPU_COPY_STRIDE_UNDEFINED, which the checks and their messages use.
func errorValidatingLinearTextureData(
    _ layout: WebGPU.TexelCopyBufferLayout,
    _ byteSize: UInt64,
    _ format: WebGPU.TextureFormat,
    _ copyExtent: WebGPU.Extent3D
) -> String? {
    func errorString(_ message: String) -> String {
        "GPUTexture.validateLinearTextureData: " + message
    }
    // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-linear-texture-data
    let blockWidth = texelBlockWidth(format)
    let blockHeight = texelBlockHeight(format)
    let blockSize = texelBlockSize(format)
    let strideUndefined = UInt32(WGPU_COPY_STRIDE_UNDEFINED)
    let offset = layout.offset
    let bytesPerRow = Optional(fromCxx: layout.bytesPerRow) ?? strideUndefined
    let rowsPerImage = Optional(fromCxx: layout.rowsPerImage) ?? strideUndefined

    let widthInBlocks = copyExtent.width / blockWidth
    if copyExtent.width % blockWidth != 0 {
        return errorString("copyExtent.width(\(copyExtent.width)) is not divisible by blockWidth(\(blockWidth))")
    }

    let heightInBlocks = copyExtent.height / blockHeight
    if copyExtent.height % blockHeight != 0 {
        return errorString("copyExtent.height(\(copyExtent.height)) is not divisible by blockHeight(\(blockHeight))")
    }

    let (bytesInLastRow, bytesInLastRowOverflowed) = UInt64(blockSize).multipliedReportingOverflow(by: UInt64(widthInBlocks))
    if bytesInLastRowOverflowed {
        return errorString("bytesInLastRow = blockSize(\(blockSize) + widthInBlocks(\(widthInBlocks)) overflowed")
    }

    if heightInBlocks > 1 {
        if bytesPerRow == strideUndefined {
            return errorString("bytesPerRow is undefined, but heightInBlocks(\(heightInBlocks)) > 1, this is not allowed")
        }
    }

    if copyExtent.depthOrArrayLayers > 1 {
        if bytesPerRow == strideUndefined || rowsPerImage == strideUndefined {
            return errorString(
                "depthOrArrayLayers(\(copyExtent.depthOrArrayLayers)) > 1 but bytesPerRow(\(bytesPerRow)) or rowsPerImage(\(rowsPerImage)) is undefined, this is not allowed"
            )
        }
    }

    if bytesPerRow != strideUndefined {
        if UInt64(bytesPerRow) < bytesInLastRow {
            return errorString("bytesPerRow(\(bytesPerRow)) is less than bytesInLastRow(\(bytesInLastRow))")
        }
    }

    if rowsPerImage != strideUndefined {
        if rowsPerImage < heightInBlocks {
            return errorString("rowsPerImage(\(rowsPerImage)) is less than heightInBlocks(\(heightInBlocks))")
        }
    }

    var requiredBytesInCopy = OverflowRecordingUInt64(0)

    if copyExtent.depthOrArrayLayers > 1 {
        let bytesPerImage = OverflowRecordingUInt64(UInt64(bytesPerRow)).multiplied(by: UInt64(rowsPerImage))
        let bytesBeforeLastImage = bytesPerImage.multiplied(by: UInt64(copyExtent.depthOrArrayLayers) - 1)

        requiredBytesInCopy = requiredBytesInCopy.adding(bytesBeforeLastImage)
    }

    if copyExtent.depthOrArrayLayers > 0 {
        if heightInBlocks > 1 {
            requiredBytesInCopy = requiredBytesInCopy.adding(
                OverflowRecordingUInt64(UInt64(bytesPerRow)).multiplied(by: UInt64(heightInBlocks) - 1)
            )
        }

        if heightInBlocks > 0 {
            requiredBytesInCopy = requiredBytesInCopy.adding(OverflowRecordingUInt64(bytesInLastRow))
        }
    }

    let end = OverflowRecordingUInt64(offset).adding(requiredBytesInCopy)
    if end.overflowed {
        let required = requiredBytesInCopy.overflowed ? UInt64.max : requiredBytesInCopy.value
        return errorString("layout.offset(\(offset)) + requiredBytesInCopy(\(required)) overflows")
    }

    if end.value > byteSize {
        return errorString("(layout.offset + requiredBytesInCopy)(\(end.value)) is less than byteSize(\(byteSize))")
    }

    return nil
}

/// The format's name in the WebGPU API, for error messages.
func textureFormatName(_ format: WebGPU.TextureFormat) -> String {
    switch format {
    case .R8unorm:
        return "r8unorm"
    case .R8snorm:
        return "r8snorm"
    case .R8uint:
        return "r8uint"
    case .R8sint:
        return "r8sint"
    case .R16uint:
        return "r16uint"
    case .R16sint:
        return "r16sint"
    case .R16float:
        return "r16float"
    case .Rg8unorm:
        return "rg8unorm"
    case .Rg8snorm:
        return "rg8snorm"
    case .Rg8uint:
        return "rg8uint"
    case .Rg8sint:
        return "rg8sint"
    case .R32float:
        return "r32float"
    case .R32uint:
        return "r32uint"
    case .R32sint:
        return "r32sint"
    case .Rg16uint:
        return "rg16uint"
    case .Rg16sint:
        return "rg16sint"
    case .Rg16float:
        return "rg16float"
    case .Rgba8unorm:
        return "rgba8unorm"
    case .Rgba8unormSRGB:
        return "rgba8unorm-srgb"
    case .Rgba8snorm:
        return "rgba8snorm"
    case .Rgba8uint:
        return "rgba8uint"
    case .Rgba8sint:
        return "rgba8sint"
    case .Bgra8unorm:
        return "bgra8unorm"
    case .Bgra8unormSRGB:
        return "bgra8unorm-srgb"
    case .Rgb10a2uint:
        return "rgb10a2uint"
    case .Rgb10a2unorm:
        return "rgb10a2unorm"
    case .Rg11b10ufloat:
        return "rg11b10ufloat"
    case .Rgb9e5ufloat:
        return "rgb9e5ufloat"
    case .Rg32float:
        return "rg32float"
    case .Rg32uint:
        return "rg32uint"
    case .Rg32sint:
        return "rg32sint"
    case .Rgba16uint:
        return "rgba16uint"
    case .Rgba16sint:
        return "rgba16sint"
    case .Rgba16float:
        return "rgba16float"
    case .Rgba32float:
        return "rgba32float"
    case .Rgba32uint:
        return "rgba32uint"
    case .Rgba32sint:
        return "rgba32sint"
    case .Stencil8:
        return "stencil8"
    case .Depth16unorm:
        return "depth16unorm"
    case .Depth24plus:
        return "depth24plus"
    case .Depth24plusStencil8:
        return "depth24plus-stencil8"
    case .Depth32float:
        return "depth32float"
    case .Depth32floatStencil8:
        return "depth32float-stencil8"
    case .Bc1RgbaUnorm:
        return "bc1-rgba-unorm"
    case .Bc1RgbaUnormSRGB:
        return "bc1-rgba-unorm-srgb"
    case .Bc2RgbaUnorm:
        return "bc2-rgba-unorm"
    case .Bc2RgbaUnormSRGB:
        return "bc2-rgba-unorm-srgb"
    case .Bc3RgbaUnorm:
        return "bc3-rgba-unorm"
    case .Bc3RgbaUnormSRGB:
        return "bc3-rgba-unorm-srgb"
    case .Bc4RUnorm:
        return "bc4-r-unorm"
    case .Bc4RSnorm:
        return "bc4-r-snorm"
    case .Bc5RgUnorm:
        return "bc5-rg-unorm"
    case .Bc5RgSnorm:
        return "bc5-rg-snorm"
    case .Bc6hRgbUfloat:
        return "bc6h-rgb-ufloat"
    case .Bc6hRgbFloat:
        return "bc6h-rgb-float"
    case .Bc7RgbaUnorm:
        return "bc7-rgba-unorm"
    case .Bc7RgbaUnormSRGB:
        return "bc7-rgba-unorm-srgb"
    case .Etc2Rgb8unorm:
        return "etc2-rgb8unorm"
    case .Etc2Rgb8unormSRGB:
        return "etc2-rgb8unorm-srgb"
    case .Etc2Rgb8a1unorm:
        return "etc2-rgb8a1unorm"
    case .Etc2Rgb8a1unormSRGB:
        return "etc2-rgb8a1unorm-srgb"
    case .Etc2Rgba8unorm:
        return "etc2-rgba8unorm"
    case .Etc2Rgba8unormSRGB:
        return "etc2-rgba8unorm-srgb"
    case .EacR11unorm:
        return "eac-r11unorm"
    case .EacR11snorm:
        return "eac-r11snorm"
    case .EacRg11unorm:
        return "eac-rg11unorm"
    case .EacRg11snorm:
        return "eac-rg11snorm"
    case .Astc4x4Unorm:
        return "astc-4x4-unorm"
    case .Astc4x4UnormSRGB:
        return "astc-4x4-unorm-srgb"
    case .Astc5x4Unorm:
        return "astc-5x4-unorm"
    case .Astc5x4UnormSRGB:
        return "astc-5x4-unorm-srgb"
    case .Astc5x5Unorm:
        return "astc-5x5-unorm"
    case .Astc5x5UnormSRGB:
        return "astc-5x5-unorm-srgb"
    case .Astc6x5Unorm:
        return "astc-6x5-unorm"
    case .Astc6x5UnormSRGB:
        return "astc-6x5-unorm-srgb"
    case .Astc6x6Unorm:
        return "astc-6x6-unorm"
    case .Astc6x6UnormSRGB:
        return "astc-6x6-unorm-srgb"
    case .Astc8x5Unorm:
        return "astc-8x5-unorm"
    case .Astc8x5UnormSRGB:
        return "astc-8x5-unorm-srgb"
    case .Astc8x6Unorm:
        return "astc-8x6-unorm"
    case .Astc8x6UnormSRGB:
        return "astc-8x6-unorm-srgb"
    case .Astc8x8Unorm:
        return "astc-8x8-unorm"
    case .Astc8x8UnormSRGB:
        return "astc-8x8-unorm-srgb"
    case .Astc10x5Unorm:
        return "astc-10x5-unorm"
    case .Astc10x5UnormSRGB:
        return "astc-10x5-unorm-srgb"
    case .Astc10x6Unorm:
        return "astc-10x6-unorm"
    case .Astc10x6UnormSRGB:
        return "astc-10x6-unorm-srgb"
    case .Astc10x8Unorm:
        return "astc-10x8-unorm"
    case .Astc10x8UnormSRGB:
        return "astc-10x8-unorm-srgb"
    case .Astc10x10Unorm:
        return "astc-10x10-unorm"
    case .Astc10x10UnormSRGB:
        return "astc-10x10-unorm-srgb"
    case .Astc12x10Unorm:
        return "astc-12x10-unorm"
    case .Astc12x10UnormSRGB:
        return "astc-12x10-unorm-srgb"
    case .Astc12x12Unorm:
        return "astc-12x12-unorm"
    case .Astc12x12UnormSRGB:
        return "astc-12x12-unorm-srgb"
    case .R16unorm:
        return "r16unorm"
    case .R16snorm:
        return "r16snorm"
    case .Rg16unorm:
        return "rg16unorm"
    case .Rg16snorm:
        return "rg16snorm"
    case .Rgba16unorm:
        return "rgba16unorm"
    case .Rgba16snorm:
        return "rgba16snorm"
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

extension TextureExtent {
    init(_ extent: WebGPU.Extent3D) {
        self.init(width: extent.width, height: extent.height, depthOrArrayLayers: extent.depthOrArrayLayers)
    }
}
