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

import CoreGraphics
import IOSurface
import Metal
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Internal.PresentationContext
import WebGPU_Internal.Queue
import WebGPU_Internal.Texture
import WebGPU_Private.WebGPUCpp

// The state of a canvas context that presents through the compositor's IOSurfaces. Used only on its Instance's API
// thread: the compositor calls back on the work queue.
@_expose(Cxx)
final class PresentationContextIOSurfaceImpl {
    private struct RenderBuffer {
        let texture: WebGPU.Metal.Texture
        // The rgba16float texture the canvas draws into under standard tone mapping; `texture` then holds the
        // clamped copy. Empty or one element: an Optional of a foreign reference is avoided.
        let luminanceClampTexture: [WebGPU.Metal.Texture]

        var presentedTexture: WebGPU.Metal.Texture {
            luminanceClampTexture.first ?? texture
        }
    }

    private struct ConfiguredDevice {
        let device: WebGPU.Metal.Device
        let impl: DeviceImpl
    }

    // The device of the last configure(), kept even when that configure failed, until unconfigure(). Empty or
    // one element.
    private var configuredDevice: [ConfiguredDevice] = []
    private var ioSurfaces: [IOSurfaceRef] = []
    private var renderBuffers: [RenderBuffer] = []
    // The buffers of the surfaces the compositor just replaced, copied into the new ones by the next configure.
    private var existingRenderBuffers: [RenderBuffer] = []
    // Empty until the first configure, then one element.
    private var invalidTextures: [WebGPU.Metal.Texture] = []
    private var luminanceClampFunction: (any MTLFunction)?
    private var luminanceClampPipeline: (any MTLComputePipelineState)?
    private var resizePipeline: (any MTLComputePipelineState)?
    // Oldest first.
    private var inFlightFrames: [WebGPU.Metal.Texture] = []
    private var maximumInFlightFrames = 0
    private var lastDrainedFrameGPUCost: Double = 0
    private var lastFramePresentStall: Double = 0
    // Premultiplied alpha until configured, unlike CanvasConfiguration's default.
    private var colorSpace = WebGPU.PredefinedColorSpace.SRGB
    private var toneMappingMode = WebGPU.CanvasToneMappingMode.Standard
    private var alphaMode = WebGPU.CanvasAlphaMode.Premultiplied
    // The compositor's IOSurfaces are attributed to it. Empty without one.
    private let webProcessID: WTF.MachSendRight

    fileprivate init(webProcessIDPort: mach_port_t) {
        webProcessID = WTF.MachSendRight.create(webProcessIDPort)
    }

    @_expose(Cxx)
    func renderBuffersWereRecreated() {
        existingRenderBuffers = renderBuffers
        renderBuffers = []
        ioSurfaces = []
    }

    @_expose(Cxx)
    func appendIOSurface(_ surface: IOSurfaceRef) {
        ioSurfaces.append(surface)
        #if HAVE_IOSURFACE_SET_OWNERSHIP_IDENTITY && HAVE_TASK_IDENTITY_TOKEN
        let port = webProcessID.sendRight()
        if port != MACH_PORT_NULL {
            _ = IOSurfaceSetOwnershipIdentity(surface, port, IOSurfaceMemoryLedgerTags.graphics.rawValue, 0)
        }
        #endif
    }

    private static func isAllowedFormat(_ format: WebGPU.TextureFormat) -> Bool {
        format == WebGPU.TextureFormat.Bgra8unorm || format == WebGPU.TextureFormat.Rgba8unorm
            || format == WebGPU.TextureFormat.Rgba16float
    }

    @_expose(Cxx)
    func configure(
        _ configuration: borrowing WebGPU.CanvasConfiguration,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl
    ) {
        let storageMode = canvasStorageMode(deviceImpl)
        let invalidTexture = WebGPU.Metal.Texture.createInvalid(device).ptr()
        renderBuffers = []
        inFlightFrames = []
        maximumInFlightFrames = 0
        lastDrainedFrameGPUCost = 0
        lastFramePresentStall = 0
        invalidTextures = [invalidTexture]

        let reportValidationErrors = configuration.reportValidationErrors
        configuredDevice = [ConfiguredDevice(device: device, impl: deviceImpl)]
        func generateAValidationError(_ message: Swift.String) {
            if reportValidationErrors {
                deviceImpl.generateAValidationError(message)
            }
        }

        let format = configuration.format
        let maxTextureDimension2D = deviceImpl.capabilities.limits.maxTextureDimension2D
        let width = min(maxTextureDimension2D, configuration.width)
        let height = min(maxTextureDimension2D, configuration.height)
        let effectiveFormat = Self.isAllowedFormat(format) ? format : WebGPU.TextureFormat.Bgra8unorm
        colorSpace = configuration.colorSpace
        toneMappingMode = configuration.toneMappingMode
        alphaMode = configuration.compositingAlphaMode

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texturePixelFormat(effectiveFormat),
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        textureDescriptor.usage = metalTextureUsage(configuration.usage.toRaw(), effectiveFormat)
        textureDescriptor.storageMode = storageMode

        if let mismatched = ioSurfaces.first(where: { IOSurfaceGetWidth($0) != Int(width) || IOSurfaceGetHeight($0) != Int(height) }) {
            let surfaceWidth = Int32(truncatingIfNeeded: IOSurfaceGetWidth(mismatched))
            let surfaceHeight = Int32(truncatingIfNeeded: IOSurfaceGetHeight(mismatched))
            generateAValidationError(
                "Invalid surface size. Backing surface has size (\(surfaceWidth), \(surfaceHeight)) but attempting to configure a size of (\(width), \(height))"
            )
            return
        }

        if !Self.isAllowedFormat(format) {
            generateAValidationError("Requested texture format \(textureFormatName(format)) is not a valid context format")
            return
        }

        if width == 0 || height == 0 {
            generateAValidationError("Width or height is zero")
            return
        }

        let requestedWidth = configuration.width
        let requestedHeight = configuration.height
        if requestedWidth > maxTextureDimension2D || requestedHeight > maxTextureDimension2D {
            generateAValidationError("Requested canvas width and/or height are too large")
            return
        }

        let viewFormats: Span<WebGPU.TextureFormat> = configuration.viewFormatsSpan()
        for index in viewFormats.indices {
            let viewFormat = viewFormats[index]
            if !Self.isAllowedFormat(removeSRGBSuffix(viewFormat)) {
                generateAValidationError("Requested texture view format BGRA8UnormStorage is not enabled")
                return
            }
        }

        if let error = WebGPU.Metal.errorValidatingCanvasTextureCreation(device, configuration, effectiveFormat, width, height) {
            generateAValidationError(error)
            return
        }

        var requestsStorage = false
        if format == WebGPU.TextureFormat.Bgra8unorm {
            requestsStorage = textureUsageContains(configuration.usage.toRaw(), .StorageBinding)
        }
        if requestsStorage && !deviceImpl.hasFeature(WebGPU.FeatureName.Bgra8unormStorage) {
            generateAValidationError("Requested storage format but BGRA8UnormStorage is not enabled")
            return
        }

        textureDescriptor.usage.formUnion([.renderTarget, .shaderRead])
        let needsLuminanceClampFunction =
            textureDescriptor.pixelFormat == .rgba16Float && toneMappingMode == WebGPU.CanvasToneMappingMode.Standard
        let existingUsage = textureDescriptor.usage
        let deviceQueue = deviceImpl.defaultQueue()
        let metalDevice = deviceImpl.device()
        var apiFormat = effectiveFormat
        var resizeCommandBuffer: (any MTLCommandBuffer)?
        for ioSurface in ioSurfaces {
            var luminanceClampTexture: [WebGPU.Metal.Texture] = []
            var luminanceClampDescriptor: MTLTextureDescriptor?
            if needsLuminanceClampFunction {
                textureDescriptor.pixelFormat = .rgba16Float
                apiFormat = WebGPU.TextureFormat.Rgba16float
                textureDescriptor.usage = existingUsage
                textureDescriptor.usage.insert(.shaderRead)
                luminanceClampDescriptor = textureDescriptor
                let texture = WebGPU.Metal
                    .createCanvasTexture(
                        deviceImpl.newTextureWithDescriptor(textureDescriptor, nil, 0),
                        configuration,
                        apiFormat,
                        effectiveFormat,
                        width,
                        height,
                        device
                    )
                    .ptr()
                texture.makeCanvasBacking()
                luminanceClampTexture = [texture]
                textureDescriptor.pixelFormat = .bgra8Unorm
                apiFormat = WebGPU.TextureFormat.Bgra8unorm
                textureDescriptor.usage = existingUsage.union(.shaderWrite)
            }

            let parentTexture = WebGPU.Metal
                .createCanvasTexture(
                    deviceImpl.newTextureWithDescriptor(textureDescriptor, ioSurface, 0),
                    configuration,
                    apiFormat,
                    effectiveFormat,
                    width,
                    height,
                    device
                )
                .ptr()
            parentTexture.makeCanvasBacking()
            renderBuffers.append(RenderBuffer(texture: parentTexture, luminanceClampTexture: luminanceClampTexture))
            if existingRenderBuffers.count >= renderBuffers.count {
                if resizeCommandBuffer == nil {
                    resizeCommandBuffer = deviceQueue.commandBufferWithDescriptor(MTLCommandBufferDescriptor())
                }

                let existing = existingRenderBuffers[renderBuffers.count - 1]
                textureDescriptor.usage.insert(.shaderWrite)
                copyTextureToTexture(
                    deviceImpl.newTextureWithDescriptor(textureDescriptor, parentTexture.texture()?.iosurface, 0),
                    existing.texture.texture(),
                    resizeCommandBuffer,
                    metalDevice,
                    deviceQueue
                )
                if let luminanceClampParent = luminanceClampTexture.first, let luminanceClampDescriptor,
                    !existing.luminanceClampTexture.isEmpty
                {
                    // FIXME: luminanceClampDescriptor is textureDescriptor itself, so this copies into a new BGRA
                    // texture rather than into luminanceClampParent.
                    luminanceClampDescriptor.usage.insert(.shaderWrite)
                    copyTextureToTexture(
                        deviceImpl.newTextureWithDescriptor(luminanceClampDescriptor, luminanceClampParent.texture()?.iosurface, 0),
                        existing.luminanceClampTexture.first?.texture(),
                        resizeCommandBuffer,
                        metalDevice,
                        deviceQueue
                    )
                }
            }
        }

        if let resizeCommandBuffer {
            deviceQueue.commitMTLCommandBuffer(resizeCommandBuffer)
        }
        assert(ioSurfaces.count == renderBuffers.count)
        maximumInFlightFrames = renderBuffers.count > 1 ? renderBuffers.count - 1 : 1
        // The committed resize consumed the existing buffers.
        if resizeCommandBuffer != nil {
            existingRenderBuffers = []
        }

        if needsLuminanceClampFunction {
            buildLuminanceClampPipeline(metalDevice)
        }
    }

    private func buildLuminanceClampPipeline(_ metalDevice: (any MTLDevice)?) {
        guard let metalDevice else {
            luminanceClampFunction = nil
            luminanceClampPipeline = nil
            return
        }
        // A library that fails to compile keeps the previous pipeline.
        guard let library = WebGPU.Metal.compileLibraryWithFastMath(metalDevice, luminanceClampKernelSource) else {
            return
        }
        let function = library.makeFunction(name: "luminanceClamp")
        luminanceClampFunction = function
        luminanceClampPipeline = function.flatMap { try? metalDevice.makeComputePipelineState(function: $0) }
    }

    private func resizePipelineState(_ metalDevice: (any MTLDevice)?) -> (any MTLComputePipelineState)? {
        if let resizePipeline {
            return resizePipeline
        }

        guard let metalDevice,
            let library = WebGPU.Metal.compileLibraryWithFastMath(metalDevice, resizeKernelSource),
            let function = library.makeFunction(name: "resize")
        else {
            return nil
        }
        do {
            let pipeline = try metalDevice.makeComputePipelineState(function: function)
            resizePipeline = pipeline
            return pipeline
        } catch {
            WebGPU.Metal.logAlways("\(error as NSError)")
            return nil
        }
    }

    private func copyTextureToTexture(
        _ destination: (any MTLTexture)?,
        _ source: (any MTLTexture)?,
        _ commandBuffer: (any MTLCommandBuffer)?,
        _ metalDevice: (any MTLDevice)?,
        _ deviceQueue: WebGPU.Metal.Queue
    ) {
        guard let source, let destination, let pipelineState = resizePipelineState(metalDevice) else {
            return
        }

        let computeDescriptor = MTLComputePassDescriptor()
        computeDescriptor.dispatchType = .serial

        let computeEncoder = commandBuffer?.makeComputeCommandEncoder(descriptor: computeDescriptor)
        deviceQueue.setEncoderForBuffer(commandBuffer, computeEncoder)
        computeEncoder?.setComputePipelineState(pipelineState)

        computeEncoder?.setTexture(source, index: 0)
        computeEncoder?.setTexture(destination, index: 1)
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (destination.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (destination.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        computeEncoder?.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        deviceQueue.endEncoding(computeEncoder, commandBuffer)
    }

    @_expose(Cxx)
    func unconfigure() {
        ioSurfaces = []
        renderBuffers = []
        inFlightFrames = []
        maximumInFlightFrames = 0
        lastDrainedFrameGPUCost = 0
        lastFramePresentStall = 0
        configuredDevice = []
    }

    private func isValidFrameIndex(_ index: UInt32) -> Bool {
        ioSurfaces.count == renderBuffers.count && index < renderBuffers.count
    }

    private func waitForInFlightFrameSlot() {
        if maximumInFlightFrames == 0 {
            return
        }

        let clock = SuspendingClock()
        var stall = Duration.zero
        while inFlightFrames.count >= maximumInFlightFrames {
            let oldestFrame = inFlightFrames.removeFirst()
            // Blocking here is what tells the frame pacer the canvas is presenting faster than the GPU retires frames.
            let waitStartTime = clock.now
            let completed = oldestFrame.waitForCommandBufferCompletion()
            stall += waitStartTime.duration(to: clock.now)
            lastDrainedFrameGPUCost = completed ? oldestFrame.gpuFrameCost().value() : 0
        }
        let (seconds, attoseconds) = stall.components
        lastFramePresentStall = Double(seconds) + Double(attoseconds) * 1e-18
    }

    @_expose(Cxx)
    func present(_ currentIndex: UInt32) {
        guard isValidFrameIndex(currentIndex), let configured = configuredDevice.first else {
            return
        }

        waitForInFlightFrameSlot()

        let deviceQueue = configured.device.getQueue().ptr()
        let renderBuffer = renderBuffers[Int(currentIndex)]
        if let computePipelineState = luminanceClampPipeline, let luminanceClampTexture = renderBuffer.luminanceClampTexture.first {
            let commandBuffer = deviceQueue.commandBufferWithDescriptor(MTLCommandBufferDescriptor())
            let computeDescriptor = MTLComputePassDescriptor()
            computeDescriptor.dispatchType = .serial

            let computeEncoder = commandBuffer?.makeComputeCommandEncoder(descriptor: computeDescriptor)
            deviceQueue.setEncoderForBuffer(commandBuffer, computeEncoder)
            computeEncoder?.setComputePipelineState(computePipelineState)
            let inputTexture = luminanceClampTexture.texture()
            computeEncoder?.setTexture(inputTexture, index: 0)
            computeEncoder?.setTexture(renderBuffer.texture.texture(), index: 1)
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: ((inputTexture?.width ?? 0) + threadgroupSize.width - 1) / threadgroupSize.width,
                height: ((inputTexture?.height ?? 0) + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            computeEncoder?.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            deviceQueue.endEncoding(computeEncoder, commandBuffer)
            deviceQueue.commitMTLCommandBuffer(commandBuffer)
        }

        inFlightFrames.append(renderBuffer.presentedTexture)
        precondition(inFlightFrames.count <= maximumInFlightFrames)
    }

    // Generates the configured device's validation error when the index is not a configured frame.
    @_expose(Cxx)
    func validateCurrentTextureIndex(_ index: UInt32) -> Bool {
        if isValidFrameIndex(index) {
            return true
        }
        configuredDevice.first?.device.generateAValidationError("GPUCanvasContext is not configured correctly")
        return false
    }

    @_expose(Cxx)
    func hasInvalidTexture() -> Bool {
        !invalidTextures.isEmpty
    }

    // +1 (SWIFT_RETURNS_RETAINED); the shell borrows it. Only after hasInvalidTexture().
    @_expose(Cxx)
    func invalidTexture() -> WebGPU.Metal.Texture {
        invalidTextures[0]
    }

    // The texture the canvas draws into for this frame, which starts a new frame on it. +1; the shell
    // borrows it. Only after validateCurrentTextureIndex() returned true.
    @_expose(Cxx)
    func currentFrameTexture(_ index: UInt32) -> WebGPU.Metal.Texture {
        let texture = renderBuffers[Int(index)].presentedTexture
        texture.recreateIfNeeded()
        return texture
    }

    // CF_RETURNS_RETAINED; the shell adopts it. Null, with isIOSurfaceSupportedFormat set, when the compositor
    // can read the IOSurface directly.
    @_expose(Cxx)
    func textureAsNativeImage(_ bufferIndex: UInt32, _ isIOSurfaceSupportedFormat: inout Bool) -> CGImage? {
        isIOSurfaceSupportedFormat = false
        guard !configuredDevice.isEmpty, bufferIndex < renderBuffers.count else {
            return nil
        }

        let texture = renderBuffers[Int(bufferIndex)].presentedTexture
        guard texture.waitForCommandBufferCompletion() else {
            return nil
        }

        guard let mtlTexture = texture.texture(),
            mtlTexture.pixelFormat != .bgra8Unorm && mtlTexture.pixelFormat != .bgra8Unorm_srgb
                && mtlTexture.pixelFormat != .rgba16Float
        else {
            isIOSurfaceSupportedFormat = true
            return nil
        }

        let fp16 = mtlTexture.pixelFormat == .rgba16Float
        var colorSpaceName = CGColorSpace.sRGB
        switch colorSpace {
        case WebGPU.PredefinedColorSpace.SRGB:
            colorSpaceName = CGColorSpace.sRGB
        case WebGPU.PredefinedColorSpace.SRGBLinear:
            colorSpaceName = CGColorSpace.linearSRGB
        case WebGPU.PredefinedColorSpace.DisplayP3:
            colorSpaceName = CGColorSpace.displayP3
        case WebGPU.PredefinedColorSpace.DisplayP3Linear:
            colorSpaceName = CGColorSpace.linearDisplayP3
        @unknown default:
            break
        }

        let imageColorSpace = CGColorSpace(name: colorSpaceName)
        let bytesPerPixel = fp16 ? 8 : 4
        let width = mtlTexture.width
        let height = mtlTexture.height
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = bytesPerPixel * 2
        let bitsPerPixel = bitsPerComponent * 4
        let alphaInfo = alphaMode == WebGPU.CanvasAlphaMode.Opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        var bitmapInfo = alphaInfo.rawValue | CGImageByteOrderInfo.order32Big.rawValue
        if fp16 {
            bitmapInfo = alphaInfo.rawValue | CGImageByteOrderInfo.order16Host.rawValue | CGBitmapInfo.floatComponents.rawValue
        }

        return WebGPU.Metal.createImageWithTextureBytes(
            mtlTexture,
            width,
            height,
            bitsPerComponent,
            bitsPerPixel,
            bytesPerRow,
            imageColorSpace,
            CGBitmapInfo(rawValue: bitmapInfo)
        )
    }

    @_expose(Cxx)
    func hasDevice() -> Bool {
        !configuredDevice.isEmpty
    }

    // +1 (SWIFT_RETURNS_RETAINED); the shell borrows it. Only after hasDevice().
    @_expose(Cxx)
    func device() -> WebGPU.Metal.Device {
        configuredDevice[0].device
    }

    @_expose(Cxx)
    func lastDrainedFrameGPUCostSeconds() -> Double {
        lastDrainedFrameGPUCost
    }

    @_expose(Cxx)
    func lastFramePresentStallSeconds() -> Double {
        lastFramePresentStall
    }
}

// `webProcessIDPort` is MACH_PORT_NULL without a web process identity; the Impl keeps its own send right.
@_expose(Cxx)
func makePresentationContextIOSurfaceImpl(_ webProcessIDPort: mach_port_t) -> PresentationContextIOSurfaceImpl {
    PresentationContextIOSurfaceImpl(webProcessIDPort: webProcessIDPort)
}

private func canvasStorageMode(_ deviceImpl: DeviceImpl) -> MTLStorageMode {
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    #if ENABLE_WEBGPU_BY_DEFAULT
    hasUnifiedMemory(deviceImpl) ? .shared : deprecatedManagedStorageMode
    #else
    deprecatedManagedStorageMode
    #endif
    #else
    .shared
    #endif
}

private let resizeKernelSource = """

    using namespace metal;
    kernel void resize(texture2d<float, access::read>  inTexture  [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height())
            return;

        float2 remappedGid = float2(static_cast<float>(gid.x), static_cast<float>(gid.y)) * float2(static_cast<float>(inTexture.get_width()) / outTexture.get_width(), static_cast<float>(inTexture.get_height()) / outTexture.get_height());
        float4 color = inTexture.read(uint2((uint)remappedGid.x, (uint)remappedGid.y));
        outTexture.write(color, gid);
    }
    """

private let luminanceClampKernelSource = """

        using namespace metal;
        // A float3x3 is built from its columns, so each float3 below is one column of the BT.709
        // matrix: the luma coefficients run down the first column, not across the first row. Writing
        // these as rows transposes both matrices, and while a transposed pair still round trips
        // exactly, the value clamped in between is then no longer luma, so any color whose first
        // component goes negative comes back a different color.
        constant float3x3 rgbToYCbCr = float3x3(
            float3(0.2126, -0.1146, 0.5),
            float3(0.7152, -0.3854, -0.4542),
            float3(0.0722, 0.5, -0.0458));
        constant float3x3 yCbCrToRGB = float3x3(
            float3(1, 1, 1),
            float3(0, -0.1873, 1.8556),
            float3(1.5748, -0.4681, 0));
        kernel void luminanceClamp(texture2d<float, access::read>  inTexture  [[texture(0)]],
            texture2d<float, access::write> outTexture [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height())
                return;

            float4 inColor  = inTexture.read(gid);
            float3 yCbCr = rgbToYCbCr * inColor.rgb;
            yCbCr.x = clamp(yCbCr.x, 0., 1.);
            float3 outColor = yCbCrToRGB * yCbCr;
            // Clamping luminance says nothing about how opaque the frame is, so the alpha the canvas
            // was drawn with has to survive. An opaque canvas is presented through a surface with no
            // alpha channel at all, which is what makes it opaque.
            outTexture.write(float4(outColor, inColor.a), gid);
        }
    """
