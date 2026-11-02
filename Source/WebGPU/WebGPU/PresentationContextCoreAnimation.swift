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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Metal
import QuartzCore
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.PresentationContext
@_implementationOnly import WebGPU_Internal.Texture
import WebGPU_Private.WebGPUCpp

// The state of a C API surface that presents into a CAMetalLayer (WGPUSurfaceSourceMetalLayer). Used only on its
// Instance's API thread.
@_expose(Cxx)
final class PresentationContextCoreAnimationImpl {
    private struct Configuration {
        let device: WebGPU.Metal.Device
        let deviceImpl: DeviceImpl
        let format: WebGPU.TextureFormat
        let usage: UInt8
        let viewFormats: ContiguousArray<WebGPU.TextureFormat>
        let width: UInt32
        let height: UInt32
    }

    // The drawable of the frame, and its texture, until the frame is presented.
    private struct Frame {
        let drawable: any CAMetalDrawable
        let texture: WebGPU.Metal.Texture
    }

    private let layer: CAMetalLayer
    // Empty or one element: an Optional of a struct holding a foreign reference is avoided.
    private var configuration: [Configuration] = []
    private var currentFrame: [Frame] = []

    fileprivate init(layer: CAMetalLayer) {
        self.layer = layer
    }

    @_expose(Cxx)
    func configure(
        _ configuration: borrowing WebGPU.CanvasConfiguration,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl
    ) {
        self.configuration = []
        currentFrame = []

        let format = configuration.format
        // The formats that a CAMetalLayer can present.
        switch format {
        case WebGPU.TextureFormat.Bgra8unorm, WebGPU.TextureFormat.Bgra8unormSRGB, WebGPU.TextureFormat.Rgba16float:
            break
        case WebGPU.TextureFormat.Rgb10a2unorm where deviceImpl.capabilities.base.canPresentRGB10A2PixelFormats:
            break
        default:
            if configuration.reportValidationErrors {
                deviceImpl.generateAValidationError("Requested texture format cannot be presented")
            }
            return
        }

        let usage = configuration.usage.toRaw()
        let width = configuration.width
        let height = configuration.height
        layer.pixelFormat = texturePixelFormat(format)
        layer.framebufferOnly = usage == WebGPU.TextureUsage.RenderAttachment.rawValue
        layer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        layer.isOpaque = configuration.compositingAlphaMode == WebGPU.CanvasAlphaMode.Opaque
        layer.device = deviceImpl.device()

        let viewFormatsSpan: Span<WebGPU.TextureFormat> = configuration.viewFormatsSpan()
        var viewFormats = ContiguousArray<WebGPU.TextureFormat>()
        viewFormats.reserveCapacity(viewFormatsSpan.count)
        for index in viewFormatsSpan.indices {
            viewFormats.append(viewFormatsSpan[index])
        }
        self.configuration = [
            Configuration(
                device: device,
                deviceImpl: deviceImpl,
                format: format,
                usage: usage,
                viewFormats: viewFormats,
                width: width,
                height: height
            )
        ]
    }

    @_expose(Cxx)
    func unconfigure() {
        configuration = []
        currentFrame = []
    }

    @_expose(Cxx)
    func isConfigured() -> Bool {
        !configuration.isEmpty
    }

    // Starts a frame on the layer's next drawable unless one is current. False when unconfigured, or when the layer has
    // no drawable.
    @_expose(Cxx)
    func acquireCurrentFrame() -> Bool {
        guard let configuration = configuration.first else {
            return false
        }
        if !currentFrame.isEmpty {
            return true
        }
        guard let drawable = layer.nextDrawable() else {
            return false
        }
        let texture = makeTexture(
            drawable.texture,
            twoDimensionalTextureParameters(
                configuration.format,
                usage: configuration.usage,
                width: configuration.width,
                height: configuration.height
            ),
            viewFormats: Array(configuration.viewFormats),
            configuration.device,
            configuration.deviceImpl
        ).shell
        currentFrame = [Frame(drawable: drawable, texture: texture)]
        return true
    }

    // +1 (SWIFT_RETURNS_RETAINED); the shell borrows it. Only after acquireCurrentFrame() returned true.
    @_expose(Cxx)
    func currentFrameTexture() -> WebGPU.Metal.Texture {
        currentFrame[0].texture
    }

    @_expose(Cxx)
    func present() {
        guard acquireCurrentFrame() else {
            return
        }
        currentFrame[0].drawable.present()
        currentFrame = []
    }
}

@_expose(Cxx)
func makePresentationContextCoreAnimationImpl(_ layer: CAMetalLayer) -> PresentationContextCoreAnimationImpl {
    PresentationContextCoreAnimationImpl(layer: layer)
}
