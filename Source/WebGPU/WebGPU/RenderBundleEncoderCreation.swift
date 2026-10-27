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
import WebGPU_Internal.RenderBundleEncoder
import WebGPU_Private.WebGPUCpp

// Forces command replay, for debugging.
private let alwaysUseICBReplay = false

// One color format's step of the bytes-per-sample sum, wrapping in UInt32.
private func addingColorAttachmentBytes(_ bytesPerSample: UInt32, _ format: WebGPU.TextureFormat) -> UInt32 {
    let alignment = UInt64(renderTargetPixelByteAlignment(format))
    let remainder = alignment == 0 ? UInt64(bytesPerSample) : UInt64(bytesPerSample) % alignment
    var result = bytesPerSample
    if remainder != 0 {
        result = result &+ UInt32(truncatingIfNeeded: alignment &- remainder)
    }
    return result &+ renderTargetPixelByteCost(format)
}

// https://gpuweb.github.io/gpuweb/#dom-gpudevice-createrenderbundleencoder
private func errorValidatingRenderBundleEncoderCreation(
    _ colorFormats: [WebGPU.TextureFormat?],
    _ depthStencilFormat: WebGPU.TextureFormat?,
    _ device: WebGPU.Metal.Device
) -> String? {
    let limits = device.limitsCopy()
    if colorFormats.count > Int(limits.maxColorAttachments) {
        return "descriptor.colorFormatCount(\(colorFormats.count)) > limits().maxColorAttachments(\(limits.maxColorAttachments))"
    }

    var bytesPerSample: UInt32 = 0
    for (index, colorFormat) in colorFormats.enumerated() {
        guard let format = colorFormat else {
            continue
        }
        if !isColorRenderableFormat(format, device) {
            return "createRenderBundleEncoder - colorAttachment[\(index)] with format \(textureFormatName(format)) is not renderable"
        }
        bytesPerSample = addingColorAttachmentBytes(bytesPerSample, format)
        if bytesPerSample > limits.maxColorAttachmentBytesPerSample {
            return "createRenderBundleEncoder - bytesPerSample > maxColorAttachmentBytesPerSample"
        }
    }

    if let depthStencilFormat {
        if !isDepthOrStencilFormat(depthStencilFormat) {
            return
                "createRenderBundleEncoder - provided depthStencilFormat \(textureFormatName(depthStencilFormat)) is not a depth or stencil format"
        }
    } else if colorFormats.isEmpty {
        return "createRenderBundleEncoder - zero color and depth-stencil formats provided"
    }
    return nil
}

// A descriptor that fails validation reports the error and gives an invalid encoder that keeps the message for
// finish(); an invalid device gives one without reporting anything.
@_expose(Cxx)
func createRenderBundleEncoderImpl(
    _ descriptor: borrowing WebGPU.RenderBundleEncoderDescriptor,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl
) -> RenderBundleEncoderImpl {
    if !deviceImpl.isValid() {
        return makeInvalidRenderBundleEncoderImpl(device, deviceImpl, "createRenderBundleEncoder: invalid device")
    }

    let descriptorColorFormats: Span<WebGPU.OptionalTextureFormat> = descriptor.colorFormatsSpan()
    var colorFormats: [WebGPU.TextureFormat?] = []
    for index in descriptorColorFormats.indices {
        colorFormats.append(Optional(fromCxx: descriptorColorFormats[index]))
    }
    let depthStencilFormat = Optional(fromCxx: descriptor.depthStencilFormat)

    if let error = errorValidatingRenderBundleEncoderCreation(colorFormats, depthStencilFormat, device) {
        deviceImpl.generateAValidationError(error)
        return makeInvalidRenderBundleEncoderImpl(device, deviceImpl, error as NSString)
    }

    let icbDescriptor = MTLIndirectCommandBufferDescriptor()
    icbDescriptor.inheritBuffers = false
    icbDescriptor.inheritPipelineState = false
    icbDescriptor.maxFragmentBufferBindCount = 1

    var parameters = WebGPU.Metal.RenderBundleEncoderParameters()
    parameters.sampleCount = descriptor.sampleCount
    parameters.depthStencilFormat = depthStencilFormat ?? .R8unorm
    parameters.hasDepthStencilFormat = depthStencilFormat != nil
    parameters.depthReadOnly = descriptor.depthReadOnly
    parameters.stencilReadOnly = descriptor.stencilReadOnly

    // The ICB path stores the ICB in an argument buffer and writes its render_command slots from a shader, both of
    // which need argument buffers tier 2. Tier 1 devices replay the commands into the render pass instead.
    let requiresCommandReplay = !deviceImpl.limits.supportsIndirectCommandBuffersInArgumentBuffers || alwaysUseICBReplay
    let impl = makeRenderBundleEncoderImpl(device, deviceImpl, icbDescriptor, requiresCommandReplay, parameters)
    for colorFormat in colorFormats {
        impl.appendColorFormat(colorFormat != nil, colorFormat ?? .R8unorm)
    }
    return impl
}
