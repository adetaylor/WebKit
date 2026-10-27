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

private import CxxStdlib
import Metal
import WebGPU_Internal.Device
import WebGPU_Internal.Texture
import WebGPU_Internal.XRSubImage
import WebGPU_Private.WebGPUCpp

// The color and depth textures of a device's XR sub-image, per reusable texture index, kept in step with the
// projection layer. The shell holds the Device weakly, because the Device owns the sub-image.
//
// No getter returns an Optional FRT: the shell asks hasCurrent*Texture() first and only then calls the
// non-optional getter.
@_expose(Cxx)
final class XRSubImageImpl {
    private var colorTextures: [UInt64: WebGPU.Metal.Texture] = [:]
    private var depthTextures: [UInt64: WebGPU.Metal.Texture] = [:]
    private var currentTextureIndex: UInt64 = 0

    fileprivate init() {
    }

    @_expose(Cxx)
    func update(_ device: WebGPU.Metal.Device, _ projectionLayer: XRProjectionLayerImpl) {
        var colorTexture = projectionLayer.colorTexture
        var depthTexture = projectionLayer.depthTexture
        let textureIndex = projectionLayer.reusableTextureIndex
        let completionEvent = projectionLayer.completionEvent
        let completionEventSignalValue = projectionLayer.completionEventSignalValue
        let targetColorFormat = projectionLayer.colorFormat
        let targetDepthStencilFormat = projectionLayer.depthStencilFormat

        currentTextureIndex = textureIndex
        if let texture = colorTextures[textureIndex], texture.texture() === colorTexture {
            WebGPU.Metal.updateXRTextureCompletionEvent(texture, completionEvent, completionEventSignalValue)
        } else {
            guard let colorFormat = textureFormat(colorTexture?.pixelFormat ?? .invalid) else {
                return
            }
            if colorFormat != targetColorFormat {
                colorTexture = colorTexture?.makeTextureView(pixelFormat: texturePixelFormat(colorFormat))
            }
            let newTexture = WebGPU.Metal.createXRTexture(colorTexture, false, targetColorFormat, colorFormat, device)
            WebGPU.Metal.updateXRTextureCompletionEvent(newTexture, completionEvent, completionEventSignalValue)
            WebGPU.Metal.setXRTextureRasterizationRateMaps(
                newTexture,
                projectionLayer.leftRasterizationMap,
                projectionLayer.rightRasterizationMap
            )
            colorTextures[textureIndex] = newTexture
        }

        // A layer without a depthStencilFormat hands the page no depth texture.
        guard let targetDepthStencilFormat else {
            depthTextures[textureIndex] = nil
            return
        }

        if let texture = depthTextures[textureIndex], texture.texture() === depthTexture {
            return
        }
        if textureFormat(depthTexture?.pixelFormat ?? .invalid) != targetDepthStencilFormat {
            depthTexture = depthTexture?.makeTextureView(pixelFormat: texturePixelFormat(targetDepthStencilFormat))
        }
        depthTextures[textureIndex] = WebGPU.Metal.createXRTexture(
            depthTexture,
            true,
            targetDepthStencilFormat,
            targetDepthStencilFormat,
            device
        )
    }

    @_expose(Cxx)
    func hasCurrentColorTexture() -> Bool {
        colorTextures[currentTextureIndex] != nil
    }

    @_expose(Cxx)
    func currentColorTexture() -> WebGPU.Metal.Texture {
        guard let texture = colorTextures[currentTextureIndex] else {
            preconditionFailure("Only after hasCurrentColorTexture()")
        }
        return texture
    }

    @_expose(Cxx)
    func hasCurrentDepthTexture() -> Bool {
        depthTextures[currentTextureIndex] != nil
    }

    @_expose(Cxx)
    func currentDepthTexture() -> WebGPU.Metal.Texture {
        guard let texture = depthTextures[currentTextureIndex] else {
            preconditionFailure("Only after hasCurrentDepthTexture()")
        }
        return texture
    }
}

@_expose(Cxx)
func makeXRSubImageImpl() -> XRSubImageImpl {
    XRSubImageImpl()
}
