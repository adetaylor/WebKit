// Copyright (c) 2024-2026 Apple Inc. All rights reserved.
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

#if os(macOS)
import IOSurface
#endif
import Metal
@_implementationOnly import WebGPU_Internal.Queue
@_implementationOnly import WebGPU_Internal.XRProjectionLayer
@_spiOnly import WebGPU_Private.WebGPUCpp

// The descriptor values and per-frame state of an XRProjectionLayer: the compositor textures cached per reusable
// texture index, the current color and depth textures, the completion event and the rasterization rate maps. Used only
// on its Instance's API thread.
final class XRProjectionLayerImpl {
    // Read by XRSubImageImpl; C++ enums are not returned to C++.
    let colorFormat: WebGPU.TextureFormat
    let depthStencilFormat: WebGPU.TextureFormat?
    // Raw OptionSet<WebGPU::TextureUsage> bits.
    private let textureUsage: UInt8
    private let scaleFactor: Double

    private var colorTextures: [UInt64: any MTLTexture] = [:]
    private var depthTextures: [UInt64: any MTLTexture] = [:]
    // Read by XRSubImageImpl. Not exposed to C++, which never sets them.
    private(set) var colorTexture: (any MTLTexture)?
    private(set) var depthTexture: (any MTLTexture)?
    private(set) var reusableTextureIndex: UInt64 = 0
    private(set) var completionEvent: (any MTLSharedEvent)?
    private(set) var completionEventSignalValue: UInt64 = 0
    private(set) var leftRasterizationMap: (any MTLRasterizationRateMap)?
    private(set) var rightRasterizationMap: (any MTLRasterizationRateMap)?
    // Declared last, so that the device outlives the rest of the layer.
    private let deviceImpl: DeviceImpl

    fileprivate init(parameters: WebGPU.Metal.XRProjectionLayerParameters, deviceImpl: DeviceImpl) {
        self.deviceImpl = deviceImpl
        colorFormat = parameters.colorFormat
        depthStencilFormat = parameters.hasDepthStencilFormat ? parameters.depthStencilFormat : nil
        textureUsage = parameters.textureUsage
        scaleFactor = parameters.scaleFactor
    }

    // Only called on visionOS, on the Mac from macOS 27, and on the Mac in an opt-in WebXR build for its simulated XR
    // device. The mach ports are the frame's send rights, MACH_PORT_NULL when the compositor did not send that buffer.
    func startFrame(
        _ frameIndex: UInt64,
        _ colorBuffer: UInt32,
        _ depthBuffer: UInt32,
        _ completionSyncEvent: UInt32,
        _ reusableTextureIndex: UInt64,
        _ screenWidth: UInt32,
        _ screenHeight: UInt32,
        _ horizontalSamplesLeft: [Float],
        _ horizontalSamplesRight: [Float],
        _ verticalSamples: [Float]
    ) {
        let device = deviceImpl.device()
        self.reusableTextureIndex = reusableTextureIndex

        // A frame that sent a buffer makes its texture current and caches it at the reusable index; a frame that
        // did not reuses the cached one.
        if colorBuffer != 0 {
            colorTexture = makeXRSharedTexture(device, colorBuffer)
            colorTextures[reusableTextureIndex] = colorTexture
        } else {
            colorTexture = colorTextures[reusableTextureIndex]
        }

        if depthBuffer != 0 {
            depthTexture = makeXRSharedTexture(device, depthBuffer)
            depthTextures[reusableTextureIndex] = depthTexture
        } else {
            depthTexture = depthTextures[reusableTextureIndex]
        }

        // Only a layer without a depthStencilFormat needs this. With one, XRSubImageImpl.update hands the page a view
        // onto this same texture, so the page owns its contents and clearing would both be wrong and cost a command
        // buffer and a render pass per slice every frame.
        if depthStencilFormat == nil {
            clearDepthTexture()
        }

        if completionSyncEvent != 0 {
            completionEvent = makeXRSharedEvent(device, completionSyncEvent)
            completionEventSignalValue = frameIndex
        }

        let screenSize = leftRasterizationMap?.screenSize ?? MTLSize(width: 0, height: 0, depth: 0)
        if screenSize.width != Int(screenWidth) || screenSize.height != Int(screenHeight) {
            let rasterizationRateMaps = makeXRRasterizationRateMaps(
                device,
                screenWidth,
                screenHeight,
                horizontalSamplesLeft,
                horizontalSamplesRight,
                verticalSamples
            )
            leftRasterizationMap = rasterizationRateMaps?.first
            rightRasterizationMap = rasterizationRateMaps?.last
        }
    }

    // Clears every slice of the current depth texture, which the compositor recycles across frames and always reads.
    // The page destroyed the layer, which can be long before the last reference to it goes. The textures are released,
    // not destroyed: every WebXR layer shares the compositor's drawable.
    func destroy() {
        colorTextures = [:]
        depthTextures = [:]
        colorTexture = nil
        depthTexture = nil
        completionEvent = nil
        completionEventSignalValue = 0
        leftRasterizationMap = nil
        rightRasterizationMap = nil

        // The device's one sub-image wraps the textures of the last layer it was updated from; update() wraps them again.
        deviceImpl.xrSubImageImpl?.releaseTextures()
    }

    private func clearDepthTexture() {
        guard let depthTexture else {
            return
        }

        let queueImpl = deviceImpl.defaultQueueImpl
        queueImpl.finalizeBlitCommandEncoder()
        guard let commandBuffer = queueImpl.commandBufferWithDescriptor(MTLCommandBufferDescriptor()) else {
            return
        }

        let hasStencilAspect = depthTexture.pixelFormat == .depth32Float_stencil8
        for slice in 0..<depthTexture.arrayLength {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.depthAttachment.texture = depthTexture
            descriptor.depthAttachment.slice = slice
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .store
            // The compositor renders reverse-Z, so the far plane is 0, not 1. Do not use 0.0 here: CompositorServices
            // skips pixels at depth 0.0 and composites them as transparent, which would punch a hole through the layer.
            // FLT_MIN is the nearest usable far value, and is what CompositorCoordinator::setUpDepthTextures() clears
            // these same textures to at session start.
            descriptor.depthAttachment.clearDepth = Double(Float.leastNormalMagnitude)
            if hasStencilAspect {
                descriptor.stencilAttachment.texture = depthTexture
                descriptor.stencilAttachment.slice = slice
                descriptor.stencilAttachment.loadAction = .load
                descriptor.stencilAttachment.storeAction = .store
            }
            descriptor.renderTargetWidth = depthTexture.width
            descriptor.renderTargetHeight = depthTexture.height
            descriptor.defaultRasterSampleCount = depthTexture.sampleCount

            if let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                queueImpl.setEncoderForBuffer(commandBuffer, clearEncoder)
                queueImpl.endEncoding(clearEncoder, commandBuffer)
            }
        }

        queueImpl.commitMTLCommandBuffer(commandBuffer)
    }
}

// https://immersive-web.github.io/WebXR-WebGPU-Binding/#xrprojectionlayer
@_spi(WebKitGPU)
public final class XRProjectionLayerReference {
    let impl: XRProjectionLayerImpl

    init(_ impl: XRProjectionLayerImpl) {
        self.impl = impl
    }

    // The frame's compositor buffers, as send rights, MACH_PORT_NULL for one the compositor didn't send. Only internal
    // SDK device builds with CompositorServices (visionOS, and the Mac from macOS 27) have compositor textures.
    public func startFrame(
        _ frameIndex: UInt64,
        colorBuffer: UInt32,
        depthBuffer: UInt32,
        completionSyncEvent: UInt32,
        reusableTextureIndex: UInt64,
        screenWidth: UInt32,
        screenHeight: UInt32,
        horizontalSamplesLeft: [Float],
        horizontalSamplesRight: [Float],
        verticalSamples: [Float]
    ) {
        impl.startFrame(
            frameIndex,
            colorBuffer,
            depthBuffer,
            completionSyncEvent,
            reusableTextureIndex,
            screenWidth,
            screenHeight,
            horizontalSamplesLeft,
            horizontalSamplesRight,
            verticalSamples
        )
    }

    public func destroy() {
        impl.destroy()
    }
}

func makeXRProjectionLayerImpl(
    _ parameters: WebGPU.Metal.XRProjectionLayerParameters,
    _ deviceImpl: DeviceImpl
) -> XRProjectionLayerImpl {
    XRProjectionLayerImpl(parameters: parameters, deviceImpl: deviceImpl)
}

// MARK: - Compositor textures, events and rasterization rate maps

// What startFrame makes of a frame's send rights. Only internal SDK device builds with CompositorServices (visionOS, and
// the Mac from macOS 27) have the compositor's; XRProjectionLayer.mm makes those. Other Mac builds, where only the
// simulated XR device of an opt-in WebXR build starts frames, make a texture from the IOSurface that it sends.

#if USE_APPLE_INTERNAL_SDK && HAVE_COMPOSITOR_SERVICES && !targetEnvironment(simulator)

private func makeXRSharedTexture(_ device: (any MTLDevice)?, _ machPort: mach_port_t) -> (any MTLTexture)? {
    WebGPU.Metal.makeXRSharedTexture(device, machPort)
}

private func makeXRSharedEvent(_ device: (any MTLDevice)?, _ machPort: mach_port_t) -> (any MTLSharedEvent)? {
    WebGPU.Metal.makeXRSharedEvent(device, machPort)
}

private func makeXRRasterizationRateMaps(
    _ device: (any MTLDevice)?,
    _ screenWidth: UInt32,
    _ screenHeight: UInt32,
    _ horizontalSamplesLeft: [Float],
    _ horizontalSamplesRight: [Float],
    _ verticalSamples: [Float]
) -> [any MTLRasterizationRateMap]? {
    WebGPU.Metal.makeXRRasterizationRateMaps(
        device,
        screenWidth,
        screenHeight,
        horizontalSamplesLeft.span,
        horizontalSamplesRight.span,
        verticalSamples.span
    )
}

#else

#if os(macOS)
// The Mac has no compositor. There a frame's buffer is an IOSurface, which only WebKit's simulated XR device sends.
private func makeXRSharedTexture(_ device: (any MTLDevice)?, _ machPort: mach_port_t) -> (any MTLTexture)? {
    guard let surface = IOSurfaceLookupFromMachPort(machPort) else {
        return nil
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: IOSurfaceGetWidth(surface),
        height: IOSurfaceGetHeight(surface),
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    return device?.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
}
#else
private func makeXRSharedTexture(_: (any MTLDevice)?, _: mach_port_t) -> (any MTLTexture)? {
    nil
}
#endif

private func makeXRSharedEvent(_: (any MTLDevice)?, _: mach_port_t) -> (any MTLSharedEvent)? {
    nil
}

private func makeXRRasterizationRateMaps(
    _: (any MTLDevice)?,
    _: UInt32,
    _: UInt32,
    _: [Float],
    _: [Float],
    _: [Float]
) -> [any MTLRasterizationRateMap]? {
    nil
}

#endif
