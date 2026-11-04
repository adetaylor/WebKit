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
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.Texture
@_implementationOnly import WebGPU_Internal.XRProjectionLayer
import WebGPU_Private.WebGPUCpp

// The color and depth textures of a device's XR sub-image, per reusable texture index, kept in step with the
// projection layer. The shell holds the Device weakly, because the Device owns the sub-image.
//
// No getter returns an Optional FRT: the shell asks hasCurrent*Texture() first and only then calls the
// non-optional getter.
@_expose(Cxx)
final class XRSubImageImpl {
    private var colorTextures: [UInt64: TextureImpl] = [:]
    private var depthTextures: [UInt64: TextureImpl] = [:]
    private var currentTextureIndex: UInt64 = 0

    fileprivate init() {
    }

    @_expose(Cxx)
    func update(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, _ projectionLayer: XRProjectionLayerImpl) {
        var colorTexture = projectionLayer.colorTexture
        var depthTexture = projectionLayer.depthTexture
        let textureIndex = projectionLayer.reusableTextureIndex
        let completionEvent = projectionLayer.completionEvent
        let completionEventSignalValue = projectionLayer.completionEventSignalValue
        let targetColorFormat = projectionLayer.colorFormat
        let targetDepthStencilFormat = projectionLayer.depthStencilFormat

        currentTextureIndex = textureIndex
        if let texture = colorTextures[textureIndex], texture.impl.texture() === colorTexture {
            texture.impl.updateCompletionEvent(completionEvent, completionEventSignalValue)
        } else {
            guard let colorFormat = textureFormat(colorTexture?.pixelFormat ?? .invalid) else {
                return
            }
            if colorFormat != targetColorFormat {
                colorTexture = colorTexture?.makeTextureView(pixelFormat: texturePixelFormat(colorFormat))
            }
            let newTexture = makeXRTexture(colorTexture, targetColorFormat, colorFormat, device, deviceImpl)
            newTexture.impl.updateCompletionEvent(completionEvent, completionEventSignalValue)
            newTexture.impl.setRasterizationRateMaps(projectionLayer.leftRasterizationMap, projectionLayer.rightRasterizationMap)
            colorTextures[textureIndex] = newTexture
        }

        // A layer without a depthStencilFormat hands the page no depth texture.
        guard let targetDepthStencilFormat else {
            depthTextures[textureIndex] = nil
            return
        }

        if let texture = depthTextures[textureIndex], texture.impl.texture() === depthTexture {
            return
        }
        if textureFormat(depthTexture?.pixelFormat ?? .invalid) != targetDepthStencilFormat {
            depthTexture = depthTexture?.makeTextureView(pixelFormat: texturePixelFormat(targetDepthStencilFormat))
        }
        depthTextures[textureIndex] = makeXRTexture(depthTexture, targetDepthStencilFormat, targetDepthStencilFormat, device, deviceImpl)
    }

    @_expose(!Cxx)
    var currentColorTextureReference: TextureReference? {
        colorTextures[currentTextureIndex]
    }

    @_expose(!Cxx)
    var currentDepthTextureReference: TextureReference? {
        depthTextures[currentTextureIndex]
    }

}

@_expose(Cxx)
func makeXRSubImageImpl() -> XRSubImageImpl {
    XRSubImageImpl()
}

// https://immersive-web.github.io/WebXR-WebGPU-Binding/#gpuxrbinding: a device's binding, which makes its projection
// layers and gives its view's sub-image. It has no state of its own.
@_spi(WebKitGPU)
public final class XRBindingReference {
    private let device: DeviceReference

    init(_ device: DeviceReference) {
        self.device = device
    }

    // https://immersive-web.github.io/WebXR-WebGPU-Binding/#dom-xrgpubinding-createprojectionlayer. `textureUsage` is the
    // bits of OptionSet<WebGPU::TextureUsage>.
    public func createProjectionLayer(
        colorFormat: WebGPU.TextureFormat,
        depthStencilFormat: WebGPU.TextureFormat?,
        textureUsage: UInt8,
        scaleFactor: Double
    ) -> XRProjectionLayerReference {
        var parameters = WebGPU.Metal.XRProjectionLayerParameters()
        parameters.colorFormat = colorFormat
        parameters.hasDepthStencilFormat = depthStencilFormat != nil
        parameters.depthStencilFormat = depthStencilFormat ?? .Bgra8unorm
        parameters.textureUsage = textureUsage
        parameters.scaleFactor = scaleFactor
        return XRProjectionLayerReference(makeXRProjectionLayerImpl(parameters, device.shell, device.impl))
    }

    // https://immersive-web.github.io/WebXR-WebGPU-Binding/#dom-xrgpubinding-getviewsubimage: the device's sub-image,
    // brought up to the layer's frame. nil for a device that has none, which is an invalid one.
    public func getViewSubImage(_ projectionLayer: XRProjectionLayerReference) -> XRSubImageReference? {
        guard let subImage = device.impl.xrSubImageImpl else {
            return nil
        }
        subImage.update(device.shell, device.impl, projectionLayer.impl)
        return XRSubImageReference(subImage)
    }
}

// https://immersive-web.github.io/WebXR-WebGPU-Binding/#gpuxrsubimage
@_spi(WebKitGPU)
public final class XRSubImageReference {
    private let impl: XRSubImageImpl

    init(_ impl: XRSubImageImpl) {
        self.impl = impl
    }

    public var colorTexture: TextureReference? {
        impl.currentColorTextureReference
    }

    public var depthStencilTexture: TextureReference? {
        impl.currentDepthTextureReference
    }
}

// An XR layer texture as a render attachment texture that allows views in `viewFormat`.
private func makeXRTexture(
    _ texture: (any MTLTexture)?,
    _ format: WebGPU.TextureFormat,
    _ viewFormat: WebGPU.TextureFormat,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl
) -> TextureImpl {
    let parameters = twoDimensionalTextureParameters(
        format,
        usage: WebGPU.TextureUsage.RenderAttachment.rawValue,
        width: UInt32(truncatingIfNeeded: texture?.width ?? 0),
        height: UInt32(truncatingIfNeeded: texture?.height ?? 0),
        depthOrArrayLayers: UInt32(truncatingIfNeeded: texture?.arrayLength ?? 0),
        sampleCount: UInt32(truncatingIfNeeded: texture?.sampleCount ?? 0)
    )
    return makeTexture(texture, parameters, viewFormats: [viewFormat], device, deviceImpl)
}
