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
import WebGPU_Internal.Queue
import WebGPU_Internal.XRProjectionLayer
import WebGPU_Private.WebGPUCpp

// The descriptor values and per-frame state of an XRProjectionLayer: the compositor textures cached per reusable
// texture index, the current color and depth textures, the completion event and the rasterization rate maps. Used only
// on its Instance's API thread.
@_expose(Cxx)
final class XRProjectionLayerImpl {
    // Read by XRSubImageImpl; C++ enums are not returned to C++.
    @_expose(!Cxx)
    let colorFormat: WebGPU.TextureFormat
    @_expose(!Cxx)
    let depthStencilFormat: WebGPU.TextureFormat?
    // Raw OptionSet<WebGPU::TextureUsage> bits.
    private let textureUsage: UInt8
    private let scaleFactor: Double

    private var colorTextures: [UInt64: any MTLTexture] = [:]
    private var depthTextures: [UInt64: any MTLTexture] = [:]
    private(set) var colorTexture: (any MTLTexture)?
    private(set) var depthTexture: (any MTLTexture)?
    private(set) var reusableTextureIndex: UInt64 = 0
    private(set) var completionEvent: (any MTLSharedEvent)?
    private(set) var completionEventSignalValue: UInt64 = 0
    private(set) var leftRasterizationMap: (any MTLRasterizationRateMap)?
    private(set) var rightRasterizationMap: (any MTLRasterizationRateMap)?
    // Declared last, so that the device outlives the rest of the layer.
    private let deviceImpl: DeviceImpl
    private let device: WebGPU.Metal.Device

    fileprivate init(parameters: WebGPU.Metal.XRProjectionLayerParameters, device: WebGPU.Metal.Device, deviceImpl: DeviceImpl) {
        self.deviceImpl = deviceImpl
        self.device = device
        colorFormat = parameters.colorFormat
        depthStencilFormat = parameters.hasDepthStencilFormat ? parameters.depthStencilFormat : nil
        textureUsage = parameters.textureUsage
        scaleFactor = parameters.scaleFactor
    }

    // Only called on visionOS with the internal SDK. The mach ports are the frame's send rights, MACH_PORT_NULL
    // when the compositor did not send that buffer.
    @_expose(Cxx)
    func startFrame(
        _ frameIndex: UInt64,
        _ colorBuffer: UInt32,
        _ depthBuffer: UInt32,
        _ completionSyncEvent: UInt32,
        _ reusableTextureIndex: UInt64,
        _ screenWidth: UInt32,
        _ screenHeight: UInt32,
        _ horizontalSamplesLeft: borrowing WebGPU.Metal.XRRasterizationSamples,
        _ horizontalSamplesRight: borrowing WebGPU.Metal.XRRasterizationSamples,
        _ verticalSamples: borrowing WebGPU.Metal.XRRasterizationSamples
    ) {
        let device = deviceImpl.device()
        self.reusableTextureIndex = reusableTextureIndex

        // A frame that sent a buffer makes its texture current and caches it at the reusable index; a frame that
        // did not reuses the cached one.
        if colorBuffer != 0 {
            colorTexture = WebGPU.Metal.makeXRSharedTexture(device, colorBuffer)
            colorTextures[reusableTextureIndex] = colorTexture
        } else {
            colorTexture = colorTextures[reusableTextureIndex]
        }

        if depthBuffer != 0 {
            depthTexture = WebGPU.Metal.makeXRSharedTexture(device, depthBuffer)
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
            completionEvent = WebGPU.Metal.makeXRSharedEvent(device, completionSyncEvent)
            completionEventSignalValue = frameIndex
        }

        let screenSize = leftRasterizationMap?.screenSize ?? MTLSize(width: 0, height: 0, depth: 0)
        if screenSize.width != Int(screenWidth) || screenSize.height != Int(screenHeight) {
            let rasterizationRateMaps: [any MTLRasterizationRateMap]? = WebGPU.Metal.makeXRRasterizationRateMaps(
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
    private func clearDepthTexture() {
        guard let depthTexture else {
            return
        }

        let queue = deviceImpl.defaultQueue()
        let queueImpl = deviceImpl.defaultQueueImpl
        queueImpl.finalizeBlitCommandEncoder(queue)
        guard let commandBuffer = queueImpl.commandBufferWithDescriptor(queue, MTLCommandBufferDescriptor()) else {
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
                queueImpl.setEncoderForBuffer(queue, commandBuffer, clearEncoder)
                queue.endEncoding(clearEncoder, commandBuffer)
            }
        }

        queueImpl.commitMTLCommandBuffer(queue, commandBuffer)
    }
}

@_expose(Cxx)
func makeXRProjectionLayerImpl(
    _ parameters: WebGPU.Metal.XRProjectionLayerParameters,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl
) -> XRProjectionLayerImpl {
    XRProjectionLayerImpl(parameters: parameters, device: device, deviceImpl: deviceImpl)
}
