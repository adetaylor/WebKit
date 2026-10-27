// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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
import Synchronization
import WebGPU_Internal.Adapter
import WebGPU_Internal.BindGroup
import WebGPU_Internal.BindGroupLayout
import WebGPU_Internal.Buffer
import WebGPU_Internal.CommandEncoder
import WebGPU_Internal.ComputePipeline
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.ExternalTexture
import WebGPU_Internal.PipelineLayout
import WebGPU_Internal.PresentationContext
import WebGPU_Internal.QuerySet
import WebGPU_Internal.RenderBundle
import WebGPU_Internal.RenderBundleEncoder
import WebGPU_Internal.RenderPipeline
import WebGPU_Internal.Sampler
import WebGPU_Internal.ShaderModule
import WebGPU_Internal.TextureOrTextureView
import WebGPU_Internal.XRBinding
import WebGPU_Internal.XRProjectionLayer
import WebGPU_Internal.XRSubImage
import WebGPU_Internal.XRView
import WebGPU_Private.WebGPU

typealias String = Swift.String

// Device::createCommandEncoder: the encoder, +1, which the C++ caller adopts.
// https://gpuweb.github.io/gpuweb/#dom-gpudevice-createcommandencoder
@_expose(Cxx)
func deviceCreateCommandEncoder(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, _ label: NSString) -> WebGPU.Metal.CommandEncoder {
    if !deviceImpl.isValid() {
        return WebGPU.Metal.CommandEncoder.createInvalid(device).ptr()
    }

    captureSingleFrameIfNeeded(deviceImpl.device())
    guard let commandBuffer = deviceImpl.defaultQueue().commandBufferWithDescriptor(MTLCommandBufferDescriptor()) else {
        return WebGPU.Metal.CommandEncoder.createInvalid(device).ptr()
    }

    commandBuffer.label = label as String

    return WebGPU.Metal.CommandEncoder.create(commandBuffer, device, deviceImpl.takeCommandEncoderId()).ptr()
}

// How a copy uses a texture subresource, for lazy zero-initialization (CommandEncoderImpl.noteTextureInit).
enum TextureInitUse {
    case read
    case partialWrite
    case fullWrite
}

func isStencilOnlyFormat(_ format: MTLPixelFormat) -> Bool {
    format == .stencil8 || format == .x32_stencil8
}

// A copy's bytes per image for an NSUInteger parameter. Only the rowsPerImage of a copy of one image, which Metal does
// not step by, can make it exceed a 32-bit NSUInteger (arm64_32), so there it saturates.
private func nsUIntegerBytesPerImage(_ bytesPerImage: UInt64) -> Int {
    Int(bitPattern: UInt(clamping: bytesPerImage))
}

// Whether a copy decides how it initializes its destination, or is one row of a copy that already did.
private enum CopyInitialization {
    case decide
    case handledByCaller
}

// One color attachment that a clearing render pass clears (runClearEncoder).
struct TextureAndClearColor {
    let texture: any MTLTexture
    let clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    let depthPlane: Int

    init(texture: any MTLTexture, depthPlane: Int = 0) {
        self.texture = texture
        self.depthPlane = depthPlane
    }
}

extension CommandEncoderImpl {
    // https://gpuweb.github.io/gpuweb/#abstract-opdef-valid-to-use-with
    private func isValidToUseWith(_ buffer: BufferImpl) -> Bool {
        isValidToUse(buffer.isValid(), buffer.deviceImpl, with: deviceImpl)
    }

    private func isValidToUseWith(_ texture: TextureImpl) -> Bool {
        isValidToUse(texture.isValid(), texture.deviceImpl, with: deviceImpl)
    }

    private func isValidToUseWith(_ querySet: QuerySetImpl) -> Bool {
        isValidToUse(querySet.isValid(), querySet.deviceImpl, with: deviceImpl)
    }

    private func hasUsage(_ buffer: BufferImpl, _ usage: WebGPU.BufferUsage) -> Bool {
        buffer.usageRawValue() & usage.rawValue != 0
    }

    private func hasUsage(_ texture: TextureImpl, _ usage: WebGPU.TextureUsage) -> Bool {
        texture.backingUsage & usage.rawValue != 0
    }

    private func hasType(_ querySet: QuerySetImpl, _ type: WebGPU.QueryType) -> Bool {
        querySet.hasType() && querySet.typeRawValue() == type.rawValue
    }

    func makeInvalid(_ errorString: String) {
        makeInvalid(errorString as NSString)
    }

    private func encoderStateName() -> String {
        if isFinished() {
            return "Ended"
        }
        if isLocked() {
            return "Locked"
        }
        return "Open"
    }

    private func validateFinishError() -> String? {
        if !isValid() {
            return "GPUCommandEncoder.finish: encoder is not valid"
        }

        if !prepareTheEncoderState() {
            return "GPUCommandEncoder.finish: encoder state is '\(encoderStateName())', expected 'Open'"
        }

        if debugGroupStackSize != 0 {
            return "GPUCommandEncoder.finish: encoder stack size '\(debugGroupStackSize)'"
        }

        // FIXME: "Every usage scope contained in this must satisfy the usage scope validation."

        return nil
    }

    // `shell` is this encoder's, which the CommandBuffer holds.
    fileprivate func finish(shell: WebGPU.Metal.CommandEncoder, descriptor: WebGPU.CommandBufferDescriptor) -> CxxBridging.RefCommandBuffer
    {
        if !isValid() || (existingCommandEncoder != nil && existingCommandEncoder !== backingBlitCommandEncoder) {
            setEncoderStateEnded()
            discardCommandBuffer()
            deviceImpl.generateAValidationError(lastErrorString.map { $0 as String } ?? "Invalid CommandEncoder")
            return WebGPU.Metal.CommandBuffer.createInvalid(device)
        }

        // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-finish
        let validationFailedError = validateFinishError()

        setEncoderStateEnded()
        if let validationFailedError {
            discardCommandBuffer()
            deviceImpl.generateAValidationError(lastErrorString.map { $0 as String } ?? validationFailedError)
            return WebGPU.Metal.CommandBuffer.createInvalid(device)
        }

        finalizeBlitCommandEncoder()

        let commandBuffer = takeCommandBufferForFinish()

        commandBuffer?.label = CxxBridging.convertWTFStringToNSString(descriptor.label)

        #if arch(x86_64) && (WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST)
        if (backingManagedBuffers?.count ?? 0) != 0 || (backingManagedTextures?.count ?? 0) != 0 {
            let blitCommandEncoder = commandBuffer?.makeBlitCommandEncoder()

            if let managedBuffers = backingManagedBuffers {
                for buffer in managedBuffers {
                    // FIXME: `NSSet` should not be used, and then this cast will not be needed.
                    // This is safe because `managedBuffers` is a `NSMutableSet<id<MTLBuffer>>`.
                    // swift-format-ignore: NeverForceUnwrap
                    blitCommandEncoder?.synchronize(resource: buffer as! any MTLBuffer)
                }
            }

            if let managedTextures = backingManagedTextures {
                for texture in managedTextures {
                    // FIXME: `NSSet` should not be used, and then this cast will not be needed.
                    // This is safe because `managedTextures` is a `NSMutableSet<id<MTLTexture>>`.
                    // swift-format-ignore: NeverForceUnwrap
                    blitCommandEncoder?.synchronize(resource: texture as! any MTLTexture)
                }
            }

            blitCommandEncoder?.endEncoding()
        }
        #endif // arch(x86_64) && (WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST)

        let result = WebGPU.Metal.CommandBuffer.create(commandBuffer, device, backingSharedEvent, backingSharedEventSignalValue, shell)
        setCachedCommandBuffer(result.ptr())
        clearSharedEvent()
        result.ptr().setBufferMapCount(backingBufferMapCount)
        if submitIsInvalid {
            result.ptr().makeInvalid(lastErrorString.map { $0 as String } ?? "Invalid CommandEncoder")
        }

        return result
    }

    func runClearEncoder(
        attachmentsToClear: [Int: TextureAndClearColor],
        depthStencilAttachmentToClear: inout (any MTLTexture)?,
        depthAttachmentToClear: Bool,
        stencilAttachmentToClear: Bool,
        depthClearValue: Double,
        stencilClearValue: UInt32,
        existingEncoder: (any MTLRenderCommandEncoder)?
    ) {
        func createSimplePso(
            attachmentsToClear: [Int: TextureAndClearColor],
            depthStencilAttachmentToClear: (any MTLTexture)?,
            depthAttachmentToClear: Bool,
            stencilAttachmentToClear: Bool,
            deviceImpl: DeviceImpl
        ) -> ((any MTLRenderPipelineState)?, (any MTLDepthStencilState)?) {
            let mtlRenderPipelineDescriptor = MTLRenderPipelineDescriptor()

            var sampleCount: UInt = 0
            var depthStencilDescriptor: MTLDepthStencilDescriptor? = nil
            for (key, textureAndClearColor) in attachmentsToClear {
                let t = textureAndClearColor.texture
                sampleCount = UInt(t.sampleCount)

                let mtlColorAttachment = mtlRenderPipelineDescriptor.colorAttachments[key]
                mtlColorAttachment?.pixelFormat = t.pixelFormat
                mtlColorAttachment?.isBlendingEnabled = false
            }

            if let depthStencilAttachmentToClear {
                depthStencilDescriptor = MTLDepthStencilDescriptor()
                sampleCount = UInt(depthStencilAttachmentToClear.sampleCount)
                mtlRenderPipelineDescriptor.depthAttachmentPixelFormat =
                    (!depthAttachmentToClear || isStencilOnlyFormat(depthStencilAttachmentToClear.pixelFormat))
                    ? .invalid : depthStencilAttachmentToClear.pixelFormat
                depthStencilDescriptor?.isDepthWriteEnabled = false

                if stencilAttachmentToClear
                    && (depthStencilAttachmentToClear.pixelFormat == .depth32Float_stencil8
                        || depthStencilAttachmentToClear.pixelFormat == .stencil8
                        || depthStencilAttachmentToClear.pixelFormat == .x32_stencil8)
                {
                    mtlRenderPipelineDescriptor.stencilAttachmentPixelFormat = depthStencilAttachmentToClear.pixelFormat
                }
            }

            mtlRenderPipelineDescriptor.vertexFunction = deviceImpl.nopVertexFunction()
            mtlRenderPipelineDescriptor.fragmentFunction = nil

            precondition(sampleCount != 0, "sampleCount must be non-zero")
            mtlRenderPipelineDescriptor.rasterSampleCount = Int(sampleCount)
            mtlRenderPipelineDescriptor.inputPrimitiveTopology = .point

            guard let deviceMetal = deviceImpl.device() else {
                fatalError()
            }

            var pso: (any MTLRenderPipelineState)? = nil
            var depthStencil: (any MTLDepthStencilState)? = nil
            do {
                pso = try deviceMetal.makeRenderPipelineState(descriptor: mtlRenderPipelineDescriptor)
                depthStencil = depthStencilDescriptor.flatMap { deviceMetal.makeDepthStencilState(descriptor: $0) }
            } catch {
                fatalError(error.localizedDescription)
            }

            return (pso, depthStencil)
        }

        if attachmentsToClear.isEmpty && !depthAttachmentToClear && !stencilAttachmentToClear {
            return endEncoding(existingEncoder)
        }
        if !stencilAttachmentToClear && !depthAttachmentToClear {
            depthStencilAttachmentToClear = nil
        }

        guard deviceImpl.device() != nil else {
            return endEncoding(existingEncoder)
        }
        var clearRenderCommandEncoder = existingEncoder
        if clearRenderCommandEncoder == nil {
            let clearDescriptor = MTLRenderPassDescriptor()
            if depthAttachmentToClear {
                clearDescriptor.depthAttachment.loadAction = .clear
                clearDescriptor.depthAttachment.storeAction = .store
                clearDescriptor.depthAttachment.clearDepth = depthClearValue
                clearDescriptor.depthAttachment.texture = depthStencilAttachmentToClear
            }

            if stencilAttachmentToClear {
                clearDescriptor.stencilAttachment.loadAction = .clear
                clearDescriptor.stencilAttachment.storeAction = .store
                clearDescriptor.stencilAttachment.clearStencil = stencilClearValue
                clearDescriptor.stencilAttachment.texture = depthStencilAttachmentToClear
            } else if depthAttachmentToClear, let dsTexture = depthStencilAttachmentToClear {
                // Depth is being pre-cleared but stencil has valid data (previously cleared).
                // Load the stencil to preserve it — without this, the pre-clear pass uses
                // MTLLoadActionDontCare for stencil, silently discarding what was written.
                let fmt = dsTexture.pixelFormat
                let hasStencil =
                    (fmt == .depth32Float_stencil8
                        || fmt == .x32_stencil8
                        || fmt == .stencil8)
                if hasStencil {
                    clearDescriptor.stencilAttachment.loadAction = .load
                    clearDescriptor.stencilAttachment.storeAction = .store
                    clearDescriptor.stencilAttachment.texture = depthStencilAttachmentToClear
                }
            }

            if attachmentsToClear.count == 0 {
                guard let depthStencilAttachmentToClear else {
                    fatalError()
                }
                clearDescriptor.defaultRasterSampleCount = depthStencilAttachmentToClear.sampleCount
                clearDescriptor.renderTargetWidth = depthStencilAttachmentToClear.width
                clearDescriptor.renderTargetHeight = depthStencilAttachmentToClear.height
            }
            for (key, textureAndClearColor) in attachmentsToClear {
                let t = textureAndClearColor.texture
                let mtlAttachment = clearDescriptor.colorAttachments[key]
                mtlAttachment?.loadAction = .clear
                mtlAttachment?.storeAction = .store
                mtlAttachment?.clearColor = textureAndClearColor.clearColor
                mtlAttachment?.texture = t
                mtlAttachment?.level = 0
                mtlAttachment?.slice = 0
                mtlAttachment?.depthPlane = textureAndClearColor.depthPlane
            }
            clearRenderCommandEncoder = backingCommandBuffer?.makeRenderCommandEncoder(descriptor: clearDescriptor)
            setExistingEncoder(clearRenderCommandEncoder)
            didCreateRenderCommandEncoder()
        }

        let (pso, depthStencil) = createSimplePso(
            attachmentsToClear: attachmentsToClear,
            depthStencilAttachmentToClear: depthStencilAttachmentToClear,
            depthAttachmentToClear: depthAttachmentToClear,
            stencilAttachmentToClear: stencilAttachmentToClear,
            deviceImpl: deviceImpl
        )

        guard let pso else {
            fatalError("pso should not be nil")
        }

        clearRenderCommandEncoder?.setRenderPipelineState(pso)
        if let depthStencil {
            clearRenderCommandEncoder?.setDepthStencilState(depthStencil)
        }
        clearRenderCommandEncoder?.setCullMode(.none)
        clearRenderCommandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1, instanceCount: 1, baseInstance: 0)
        deviceImpl.defaultQueue().endEncoding(clearRenderCommandEncoder, backingCommandBuffer)
        setExistingEncoder(nil)
    }

    // Metal declares `#define MTLCounterDontSample ((NSUInteger)-1)`. Swift maps
    // NSUInteger to Int, so the macro imports as an Int-typed constant whose
    // value (UInt.max) does not fit in Int; every reference to it is therefore
    // an "integer literal overflows when stored into 'Int'" error. Spell the
    // same bit pattern directly instead.
    private static let counterDontSample = Int(bitPattern: UInt.max)

    private func timestampWriteIndex(writeIndex: UInt32) -> UInt32 {
        writeIndex == WGPU_QUERY_SET_INDEX_UNDEFINED ? 0 : writeIndex
    }

    private func timestampWriteIndex(
        writeIndex: UInt32,
        defaultValue: Int,
        offset: UInt32
    ) -> Int {
        writeIndex == WGPU_QUERY_SET_INDEX_UNDEFINED ? defaultValue : Int(UInt(writeIndex + offset))
    }

    private func errorValidatingCopyBufferToBuffer(
        source: BufferImpl,
        sourceOffset: UInt64,
        destination: BufferImpl,
        destinationOffset: UInt64,
        size: UInt64
    ) -> String? {
        func errorString(_ format: String) -> String {
            "GPUCommandEncoder.copyBufferToBuffer: \(format)"
        }
        if !source.isDestroyed() && !isValidToUseWith(source) {
            return errorString("source buffer is not valid")
        }

        if !destination.isDestroyed() && !isValidToUseWith(destination) {
            return errorString("destination buffer is not valid")
        }

        if !hasUsage(source, .CopySource) {
            return errorString("source usage does not have COPY_SRC")
        }

        if !hasUsage(destination, .CopyDestination) {
            return errorString("destination usage does not have COPY_DST")
        }

        let mappingPending = WebGPU.Metal.Buffer.State.MappingPending.rawValue
        if destination.stateRawValue() == mappingPending || source.stateRawValue() == mappingPending {
            return errorString("destination state is not unmapped or source state is not unmapped")
        }

        if size % 4 != 0 {
            return errorString("size is not a multiple of 4")
        }

        if sourceOffset % 4 != 0 {
            return errorString("source offset is not a multiple of 4")
        }

        if destinationOffset % 4 != 0 {
            return errorString("destination offset is not a multiple of 4")
        }
        var sourceEnd = sourceOffset
        var didOverflow = false
        (sourceEnd, didOverflow) = sourceEnd.addingReportingOverflow(size)
        if didOverflow {
            return errorString("source size + offset overflows")
        }
        var destinationEnd = destinationOffset
        (destinationEnd, didOverflow) = destinationEnd.addingReportingOverflow(size)
        if didOverflow {
            return errorString("destination size + offset overflows")
        }

        if source.initialSize() < sourceEnd {
            return errorString("source size + offset overflows")
        }

        if destination.initialSize() < destinationEnd {
            return errorString("destination size + offset overflows")
        }
        if source === destination {
            return errorString("source equals destination not valid")
        }

        return nil
    }

    private func areCopyCompatible(format1: WebGPU.TextureFormat, format2: WebGPU.TextureFormat) -> Bool {
        // https://gpuweb.github.io/gpuweb/#copy-compatible
        format1 == format2 ? true : removeSRGBSuffix(format1) == removeSRGBSuffix(format2)
    }

    private func errorValidatingCopyTextureToTexture(
        source: WebGPU.TexelCopyTextureInfo,
        sourceTexture: TextureImpl,
        destination: WebGPU.TexelCopyTextureInfo,
        destinationTexture: TextureImpl,
        copySize: WebGPU.Extent3D
    ) -> String? {
        func refersToAllAspects(format: WebGPU.TextureFormat, aspect: WebGPU.TextureAspect) -> Bool {
            switch aspect {
            case WebGPU.TextureAspect.All:
                return true
            case WebGPU.TextureAspect.StencilOnly:
                return containsStencilAspect(format) && !containsDepthAspect(format)
            case WebGPU.TextureAspect.DepthOnly:
                return containsDepthAspect(format) && !containsStencilAspect(format)
            default:
                assertionFailure()
                return false
            }
        }
        func errorString(_ error: String) -> String {
            "GPUCommandEncoder.copyTextureToTexture: \(error)"
        }
        if !isValidToUseWith(sourceTexture) {
            return errorString("source texture is not valid to use with this GPUCommandEncoder")
        }

        if !isValidToUseWith(destinationTexture) {
            return errorString("destination texture is not valid to use with this GPUCommandEncoder")
        }

        if let error = errorValidatingImageCopyTexture(sourceTexture, source.mipLevel, source.origin, copySize) {
            return errorString(error)
        }

        if !hasUsage(sourceTexture, .CopySource) {
            return errorString("source texture usage does not contain CopySrc")
        }

        if let error = errorValidatingImageCopyTexture(destinationTexture, destination.mipLevel, destination.origin, copySize) {
            return errorString(error)
        }

        if !hasUsage(destinationTexture, .CopyDestination) {
            return errorString("destination texture usage does not contain CopyDst")
        }

        if sourceTexture.sampleCount() != destinationTexture.sampleCount() {
            return errorString("destination texture sample count does not equal source texture sample count")
        }

        if !areCopyCompatible(format1: sourceTexture.formatOrDefault, format2: destinationTexture.formatOrDefault) {
            return errorString("destination texture and source texture are not copy compatible")
        }

        let srcIsDepthOrStencil = isDepthOrStencilFormat(sourceTexture.formatOrDefault)
        let dstIsDepthOrStencil = isDepthOrStencilFormat(destinationTexture.formatOrDefault)

        if srcIsDepthOrStencil {
            if !refersToAllAspects(format: sourceTexture.formatOrDefault, aspect: source.aspect)
                || !refersToAllAspects(format: destinationTexture.formatOrDefault, aspect: destination.aspect)
            {
                return errorString("source or destination do not refer to a single copy aspect")
            }
        } else {
            if source.aspect != WebGPU.TextureAspect.All {
                return errorString("source aspect is not All")
            }
            if !dstIsDepthOrStencil {
                if destination.aspect != WebGPU.TextureAspect.All {
                    return errorString("destination aspect is not All")
                }
            }
        }

        if let error = errorValidatingTextureCopyRange(sourceTexture, source.mipLevel, source.origin, copySize) {
            return errorString(error)
        }

        if let error = errorValidatingTextureCopyRange(destinationTexture, destination.mipLevel, destination.origin, copySize) {
            return errorString(error)
        }

        // https://gpuweb.github.io/gpuweb/#abstract-opdef-set-of-subresources-for-texture-copy
        if sourceTexture === destinationTexture {
            // Mip levels are never ranges.
            if source.mipLevel == destination.mipLevel {
                switch sourceTexture.backingDimension {
                case WebGPU.TextureDimension._1d:
                    return errorString("can't copy 1D texture to itself")
                case WebGPU.TextureDimension._2d:
                    let sourceRange = source.origin.z..<(source.origin.z + copySize.depthOrArrayLayers)
                    let destinationRange = destination.origin.z..<(destination.origin.z + copySize.depthOrArrayLayers)
                    if sourceRange.overlaps(destinationRange) {
                        return errorString("can't copy 2D texture to itself with overlapping array range")
                    }
                case WebGPU.TextureDimension._3d:
                    return errorString("can't copy 3D texture to itself")
                default:
                    assertionFailure()
                    return errorString("Default. Should not be reached")
                }
            }
        }

        return nil
    }

    private func errorValidatingCopyTextureToBuffer(
        source: WebGPU.TexelCopyTextureInfo,
        sourceTexture: TextureImpl,
        destination: WebGPU.TexelCopyBufferInfo,
        destinationBuffer: BufferImpl,
        copySize: WebGPU.Extent3D
    ) -> String? {
        func errorString(_ error: String) -> String {
            "GPUCommandEncoder.copyTextureToBuffer: \(error)"
        }
        if !isValidToUseWith(sourceTexture) {
            return errorString("source texture is not valid to use with this GPUCommandEncoder")
        }

        if let error = errorValidatingImageCopyTexture(sourceTexture, source.mipLevel, source.origin, copySize) {
            return errorString(error)
        }

        if !hasUsage(sourceTexture, .CopySource) {
            return errorString("sourceTexture usage does not contain CopySrc")
        }

        if sourceTexture.sampleCount() != 1 {
            return errorString("sourceTexture sample count != 1")
        }

        var copyFormat = sourceTexture.formatOrDefault

        if isDepthOrStencilFormat(sourceTexture.formatOrDefault) {
            if !refersToSingleAspect(sourceTexture.formatOrDefault, source.aspect) {
                return errorString("copying to depth stencil texture with more than one aspect")
            }

            if !isValidDepthStencilCopySource(sourceTexture.formatOrDefault, source.aspect) {
                return errorString("copying to depth stencil texture, validDepthStencilCopySource fails")
            }

            guard let format = aspectSpecificFormat(sourceTexture.formatOrDefault, source.aspect) else {
                return errorString("source aspect has no aspect-specific format")
            }
            copyFormat = format
        }

        if let error = errorValidatingImageCopyBuffer(imageCopyBuffer: destination, buffer: destinationBuffer) {
            return errorString(error)
        }

        if !hasUsage(destinationBuffer, .CopyDestination) {
            return errorString("destination buffer usage does not contain CopyDst")
        }

        if let error = errorValidatingTextureCopyRange(sourceTexture, source.mipLevel, source.origin, copySize) {
            return errorString(error)
        }

        if !isDepthOrStencilFormat(sourceTexture.formatOrDefault) {
            let texelBlockSize = texelBlockSize(sourceTexture.formatOrDefault)
            if destination.layout.offset % UInt64(texelBlockSize) != 0 {
                return errorString("destination.layout.offset is not a multiple of texelBlockSize")
            }
        }

        if isDepthOrStencilFormat(sourceTexture.formatOrDefault) {
            if destination.layout.offset % 4 != 0 {
                return errorString("destination.layout.offset is not a multiple of 4")
            }
        }

        if let error = errorValidatingLinearTextureData(
            destination.layout,
            destinationBuffer.initialSize(),
            copyFormat,
            copySize
        ) {
            return errorString(error)
        }
        return nil
    }

    private func errorValidatingImageCopyBuffer(imageCopyBuffer: WebGPU.TexelCopyBufferInfo, buffer: BufferImpl) -> String? {
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpuimagecopybuffer
        if !isValidToUseWith(buffer) {
            return "buffer is not valid"
        }

        if let bytesPerRow = Optional(fromCxx: imageCopyBuffer.layout.bytesPerRow), bytesPerRow % 256 != 0 {
            return "imageCopyBuffer.layout.bytesPerRow is not a multiple of 256"
        }

        return nil
    }

    private func errorValidatingCopyBufferToTexture(
        source: WebGPU.TexelCopyBufferInfo,
        sourceBuffer: BufferImpl,
        destination: WebGPU.TexelCopyTextureInfo,
        destinationTexture: TextureImpl,
        copySize: WebGPU.Extent3D
    ) -> String? {
        func errorString(_ error: String) -> String {
            "GPUCommandEncoder.copyBufferToTexture: \(error)"
        }
        if let error = errorValidatingImageCopyBuffer(imageCopyBuffer: source, buffer: sourceBuffer) {
            return errorString(error)
        }

        if !hasUsage(sourceBuffer, .CopySource) {
            return errorString("source usage does not contain CopySrc")
        }

        if !isValidToUseWith(destinationTexture) {
            return errorString("destination texture is not valid to use with this GPUCommandEncoder")
        }

        if let error = errorValidatingImageCopyTexture(destinationTexture, destination.mipLevel, destination.origin, copySize) {
            return errorString(error)
        }

        if !hasUsage(destinationTexture, .CopyDestination) {
            return errorString("destination usage does not contain CopyDst")
        }

        if destinationTexture.sampleCount() != 1 {
            return errorString("destination sample count is not one")
        }

        var copyFormat = destinationTexture.formatOrDefault

        if isDepthOrStencilFormat(destinationTexture.formatOrDefault) {
            if !refersToSingleAspect(destinationTexture.formatOrDefault, destination.aspect) {
                return errorString("destination aspect refers to more than one asepct")
            }

            if !isValidDepthStencilCopyDestination(destinationTexture.formatOrDefault, destination.aspect) {
                return errorString("destination is not valid depthStencilCopyDestination")
            }

            guard let format = aspectSpecificFormat(destinationTexture.formatOrDefault, destination.aspect)
            else {
                return errorString("destination aspect has no aspect-specific format")
            }
            copyFormat = format
        }

        if let error = errorValidatingTextureCopyRange(destinationTexture, destination.mipLevel, destination.origin, copySize) {
            return errorString(error)
        }

        if !isDepthOrStencilFormat(destinationTexture.formatOrDefault) {
            let texelBlockSize = texelBlockSize(destinationTexture.formatOrDefault)
            if source.layout.offset % UInt64(texelBlockSize) != 0 {
                return errorString("source.layout.offset is not a multiple of texelBlockSize")
            }
        }

        if isDepthOrStencilFormat(destinationTexture.formatOrDefault) {
            if source.layout.offset % 4 != 0 {
                return errorString("source.layout.offset is not a multiple of four for depth stencil format")
            }
        }

        if let error = errorValidatingLinearTextureData(
            source.layout,
            sourceBuffer.initialSize(),
            copyFormat,
            copySize
        ) {
            return errorString(error)
        }
        return nil
    }

    private func errorValidatingRenderPassDescriptor(descriptor: borrowing WebGPU.RenderPassDescriptor) -> String? {
        if let occlusionQuery = WebGPU.Metal.metalOrNull(descriptor.occlusionQuerySet) {
            if !CxxBridging.isValidToUseWithQuerySet(occlusionQuery, device) {
                return "occlusion query does not match the device"
            }
            if Optional(fromCxx: occlusionQuery.type()) != WebGPU.QueryType.Occlusion {
                return "occlusion query type is not occlusion"
            }
        }
        if let timestampWrites = Optional(fromCxx: descriptor.timestampWrites) {
            return errorValidatingTimestampWrites(timestampWrites: timestampWrites)
        }
        return nil
    }

    // WGPU_QUERY_SET_INDEX_UNDEFINED for std::nullopt.
    private func writeIndex(_ timestampWrites: WebGPU.PassTimestampWrites, beginning: Bool) -> UInt32 {
        let index = beginning ? timestampWrites.beginningOfPassWriteIndex : timestampWrites.endOfPassWriteIndex
        return Optional(fromCxx: index) ?? UInt32(WGPU_QUERY_SET_INDEX_UNDEFINED)
    }

    private func errorValidatingTimestampWrites(timestampWrites: WebGPU.PassTimestampWrites) -> String? {
        if !deviceImpl.hasFeature(WebGPU.FeatureName.TimestampQuery) {
            return "device does not have timestamp query feature"
        }

        let querySet = WebGPU.Metal.metal(timestampWrites.querySet)
        if Optional(fromCxx: querySet.type()) != WebGPU.QueryType.Timestamp {
            return "query type is not timestamp but \(querySet.type())"
        }

        if !CxxBridging.isValidToUseWithQuerySet(querySet, device) {
            return "device mismatch"
        }

        let querySetCount = querySet.count()
        let rawBeginningOfPassWriteIndex = writeIndex(timestampWrites, beginning: true)
        let rawEndOfPassWriteIndex = writeIndex(timestampWrites, beginning: false)
        let beginningOfPassWriteIndex = timestampWriteIndex(writeIndex: rawBeginningOfPassWriteIndex)
        let endOfPassWriteIndex = timestampWriteIndex(writeIndex: rawEndOfPassWriteIndex)
        if beginningOfPassWriteIndex >= querySetCount || endOfPassWriteIndex >= querySetCount
            || rawBeginningOfPassWriteIndex == rawEndOfPassWriteIndex
        {
            return
                "writeIndices mismatch: beginningOfPassWriteIndex(\(beginningOfPassWriteIndex) >= querySetCount(\(querySetCount) || endOfPassWriteIndex(\(endOfPassWriteIndex)) >= querySetCount(\(querySetCount)) || timestampWrite.beginningOfPassWriteIndex(\(rawBeginningOfPassWriteIndex) == timestampWrite.endOfPassWriteIndex(\(rawEndOfPassWriteIndex))"
        }

        return nil
    }

    private func errorValidatingComputePassDescriptor(descriptor: WebGPU.ComputePassDescriptor) -> String? {
        if let timestampWrites = Optional(fromCxx: descriptor.timestampWrites) {
            return errorValidatingTimestampWrites(timestampWrites: timestampWrites)
        }
        return nil
    }

    private func loadAction(loadOp: WebGPU.LoadOp?, readOnly: Bool = false) -> MTLLoadAction {
        guard let loadOp else {
            return readOnly ? .load : .dontCare
        }
        switch loadOp {
        case WebGPU.LoadOp.Load:
            return .load
        case WebGPU.LoadOp.Clear:
            return .clear
        default:
            assertionFailure()
            return .dontCare
        }
    }

    private func storeAction(storeOp: WebGPU.StoreOp?, hasResolveTarget: Bool = false) -> MTLStoreAction {
        guard let storeOp else {
            return hasResolveTarget ? .multisampleResolve : .dontCare
        }
        switch storeOp {
        case WebGPU.StoreOp.Store:
            return hasResolveTarget ? .storeAndMultisampleResolve : .store
        case WebGPU.StoreOp.Discard:
            return hasResolveTarget ? .multisampleResolve : .dontCare
        default:
            assertionFailure()
            return .dontCare
        }
    }

    private func isMultisampleTexture(texture: any MTLTexture) -> Bool {
        texture.textureType == .type2DMultisample || texture.textureType == .type2DMultisampleArray
    }

    // `shell` is this encoder's, which the pass holds.
    fileprivate func beginRenderPass(
        shell: WebGPU.Metal.CommandEncoder,
        descriptor: borrowing WebGPU.RenderPassDescriptor
    ) -> CxxBridging.RefRenderPassEncoder {
        let maxDrawCount = Optional(fromCxx: descriptor.maxDrawCount) ?? UInt64.max

        guard prepareTheEncoderState() else {
            self.generateInvalidEncoderStateError()
            // https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-end
            // A pass begun while the command encoder was already locked by another pass never took
            // the encoder over. Ending it is a validation error the page can catch, not a no-op.
            return WebGPU.Metal.RenderPassEncoder.createInvalidWithEncoderStateNotOpen(shell, device, "encoder state is not valid")
        }

        if let error = errorValidatingRenderPassDescriptor(descriptor: descriptor) {
            return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, error)
        }

        if let commandBuffer = self.commandBuffer(), commandBuffer.status.rawValue >= MTLCommandBufferStatus.enqueued.rawValue {
            return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "command buffer has already been committed")
        }

        // Before anything in this pass is attached to the command buffer, including the timestamps buffer
        // tracked below.
        rotateCommandBufferIfNeeded()

        let mtlDescriptor = MTLRenderPassDescriptor()
        var counterSampleBuffer = WebGPU.Metal.QuerySet.CounterSampleBuffer()
        let optionalTimestampWrites = Optional(fromCxx: descriptor.timestampWrites)
        if let timestampWrites = optionalTimestampWrites {
            let timestampsWrites = WebGPU.Metal.metal(timestampWrites.querySet)
            counterSampleBuffer = timestampsWrites.counterSampleBufferWithOffset()
            timestampsWrites.setCommandEncoder(shell)
        }

        if enableEncoderTimestamps() || counterSampleBuffer.buffer != nil {
            if let buffer = counterSampleBuffer.buffer {
                // FIXME: (rdar://170907276) Prove that `optionalTimestampWrites` can never be nil.
                // swift-format-ignore: NeverForceUnwrap
                let timestampWrites = optionalTimestampWrites!
                mtlDescriptor.sampleBufferAttachments[0].sampleBuffer = buffer
                mtlDescriptor.sampleBufferAttachments[0].startOfVertexSampleIndex = timestampWriteIndex(
                    writeIndex: writeIndex(timestampWrites, beginning: true),
                    defaultValue: Self.counterDontSample,
                    offset: counterSampleBuffer.offset
                )
                mtlDescriptor.sampleBufferAttachments[0].endOfVertexSampleIndex = timestampWriteIndex(
                    writeIndex: writeIndex(timestampWrites, beginning: false),
                    defaultValue: Self.counterDontSample,
                    offset: counterSampleBuffer.offset
                )
                mtlDescriptor.sampleBufferAttachments[0].startOfFragmentSampleIndex =
                    mtlDescriptor.sampleBufferAttachments[0].endOfVertexSampleIndex
                mtlDescriptor.sampleBufferAttachments[0].endOfFragmentSampleIndex =
                    mtlDescriptor.sampleBufferAttachments[0].endOfVertexSampleIndex
                device.trackTimestampsBuffer(commandBuffer(), buffer)
            } else {
                mtlDescriptor.sampleBufferAttachments[0].sampleBuffer =
                    counterSampleBuffer.buffer ?? device.timestampsBuffer(commandBuffer(), 4)
                mtlDescriptor.sampleBufferAttachments[0].startOfVertexSampleIndex = 0
                mtlDescriptor.sampleBufferAttachments[0].endOfVertexSampleIndex = 1
                mtlDescriptor.sampleBufferAttachments[0].startOfFragmentSampleIndex = 2
                mtlDescriptor.sampleBufferAttachments[0].endOfFragmentSampleIndex = 3
            }
        }

        guard descriptor.colorAttachmentCount() <= 8 else {
            return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "color attachment count is > 8")
        }

        finalizeBlitCommandEncoder()

        var zeroColorTargets = true
        var bytesPerSample: UInt32 = 0
        let maxColorAttachmentBytesPerSample = deviceImpl.deviceLimits().maxColorAttachmentBytesPerSample
        var textureWidth: UInt32 = 0
        var textureHeight: UInt32 = 0
        var sampleCount: UInt32 = 0

        var depthSlices: [UInt64: Set<UInt64>] = [:]
        // FIXME: it shouldn't be necessary to pass colorAttachmentCount here
        var compositorTextureSlice: UInt32 = 0
        if descriptor.colorAttachmentCount() != 0 {
            for i in 0..<descriptor.colorAttachmentCount() {
                // An empty slot has no attachment.
                guard let attachment = Optional(fromCxx: WebGPU.Metal.resolvedColorAttachment(descriptor, i)) else {
                    continue
                }
                let optionalResolveTarget = Optional(fromCxx: attachment.resolveTarget)

                // MTLRenderPassColorAttachmentDescriptorArray is bounds-checked internally, so this is guaranteed to be non-nil.
                // swift-format-ignore: NeverForceUnwrap
                let mtlAttachment = mtlDescriptor.colorAttachments[i]!

                mtlAttachment.clearColor = MTLClearColor(
                    red: attachment.clearValue.r,
                    green: attachment.clearValue.g,
                    blue: attachment.clearValue.b,
                    alpha: attachment.clearValue.a
                )

                var texture = attachment.view
                if !CxxBridging.isValidToUseWith(texture, device) {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "device mismatch")
                }

                if textureWidth != 0
                    && (texture.width() != textureWidth || texture.height() != textureHeight || sampleCount != texture.sampleCount())
                {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "texture size does not match")
                }

                textureWidth = texture.width()
                textureHeight = texture.height()
                sampleCount = texture.sampleCount()
                let textureFormat = texture.format()
                bytesPerSample = roundUpToMultipleOfNonPowerOfTwoUInt32UInt32(
                    renderTargetPixelByteAlignment(textureFormat),
                    bytesPerSample
                )
                bytesPerSample += renderTargetPixelByteCost(textureFormat)
                if bytesPerSample > maxColorAttachmentBytesPerSample {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "total bytes per sample exceeds limit")
                }

                let textureIsDestroyed = texture.isDestroyed()
                if !textureIsDestroyed {
                    if !texture.usage().contains(WebGPU.TextureUsage.RenderAttachment)
                        || !isColorRenderableFormat(textureFormat, device)
                    {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "color attachment is not renderable")
                    }

                    if !isRenderableTextureView(texture, attachment.loadOp, attachment.storeOp) {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "texture view is not renderable")
                    }
                }
                texture.setCommandEncoder(shell)

                let mtlTexture = texture.texture()
                mtlAttachment.texture = mtlTexture
                if mtlAttachment.texture == nil {
                    if !textureIsDestroyed {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "color attachment's texture is nil")
                    }
                    continue
                }
                mtlAttachment.level = 0
                mtlAttachment.slice = 0
                var depthSliceOrArrayLayer: UInt64 = 0
                #if compiler(>=6.4)
                if let depthSlice = Optional(fromCxx: attachment.depthSlice) {
                    if !texture.is3DTexture() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depthSlice specified on 2D texture")
                    }
                    depthSliceOrArrayLayer = textureIsDestroyed ? 0 : UInt64(depthSlice)
                    if depthSliceOrArrayLayer >= texture.depthOrArrayLayers() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "depthSlice is greater than texture's depth or array layers"
                        )
                    }
                } else {
                    if texture.is3DTexture() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "textureDimension is 3D and no depth slice is specified"
                        )
                    }
                    depthSliceOrArrayLayer = UInt64(textureIsDestroyed ? 0 : texture.baseArrayLayer())
                }
                #else
                // FIXME: (rdar://170907318) Remove this branch once the minimum supported compiler is Swift 6.4.
                if var depthSlice = Optional(fromCxx: attachment.depthSlice) {
                    if !texture.is3DTexture() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depthSlice specified on 2D texture")
                    }
                    depthSliceOrArrayLayer = textureIsDestroyed ? 0 : UInt64(depthSlice)
                    if depthSliceOrArrayLayer >= texture.depthOrArrayLayers() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "depthSlice is greater than texture's depth or array layers"
                        )
                    }
                } else {
                    if texture.is3DTexture() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "textureDimension is 3D and no depth slice is specified"
                        )
                    }
                    depthSliceOrArrayLayer = UInt64(textureIsDestroyed ? 0 : texture.baseArrayLayer())
                }
                #endif
                let bridgedTexture = texture.parentTexture().gpuResourceID._impl
                let baseMipLevel = textureIsDestroyed ? 0 : texture.baseMipLevel()
                let depthAndMipLevel: UInt64 = depthSliceOrArrayLayer | (UInt64(baseMipLevel) << 32)

                guard depthSlices[bridgedTexture, default: []].insert(depthAndMipLevel).inserted else {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(
                        shell,
                        device,
                        "attempting to render to overlapping color attachment"
                    )
                }

                mtlAttachment.depthPlane = texture.is3DTexture() ? Int(depthSliceOrArrayLayer) : 0
                mtlAttachment.slice = 0
                mtlAttachment.loadAction = loadAction(loadOp: attachment.loadOp)
                mtlAttachment.storeAction = storeAction(
                    storeOp: attachment.storeOp,
                    hasResolveTarget: optionalResolveTarget != nil
                )

                zeroColorTargets = false

                var compositorTexture = texture
                // FIXME: (rdar://170907318) This should be changed to `if let` when possible.
                if var resolveTarget = optionalResolveTarget {
                    compositorTexture = resolveTarget

                    if !CxxBridging.isValidToUseWith(resolveTarget, device) {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "resolve target created from different device"
                        )
                    }
                    resolveTarget.setCommandEncoder(shell)
                    let resolveTexture = resolveTarget.texture()
                    #if compiler(>=6.4)
                    guard let resolveTexture, let mtlTexture else {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "resolveTexture/mtlTexture is nil")
                    }
                    #else
                    // FIXME: (rdar://170907318) Remove this branch once the minimum supported compiler is Swift 6.4.
                    guard var resolveTexture, var mtlTexture else {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "resolveTexture/mtlTexture is nil")
                    }
                    #endif

                    if mtlTexture.sampleCount == 1
                        || resolveTexture.sampleCount != 1
                        || isMultisampleTexture(texture: resolveTexture)
                        || !isMultisampleTexture(texture: mtlTexture)
                        || !isRenderableTextureView(resolveTarget, attachment.loadOp, attachment.storeOp)
                        || mtlTexture.pixelFormat != resolveTexture.pixelFormat
                        || !supportsResolve(resolveTarget.format(), device)
                    {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "resolve target is invalid")
                    }

                    mtlAttachment.resolveTexture = resolveTexture
                    mtlAttachment.resolveLevel = 0
                    mtlAttachment.resolveSlice = 0
                    mtlAttachment.resolveDepthPlane = 0
                    if resolveTarget.width() != texture.width() || resolveTarget.height() != texture.height() {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "resolve target dimensions are invalid")
                    }
                }

                if let rateMap = compositorTexture.rasterizationMapForSlice(compositorTexture.parentRelativeSlice()) {
                    mtlDescriptor.rasterizationRateMap = rateMap
                    compositorTextureSlice = compositorTexture.parentRelativeSlice()
                }
            }
        }

        var depthReadOnly = false
        var stencilReadOnly = false
        var hasStencilComponent = false
        var hasDepthComponent = false
        let optionalDepthStencilAttachment = Optional(fromCxx: WebGPU.Metal.resolvedDepthStencilAttachment(descriptor))
        if let attachment = optionalDepthStencilAttachment {
            let textureView = attachment.view
            if !CxxBridging.isValidToUseWith(textureView, device) {
                return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depth stencil texture device mismatch")
            }
            let metalDepthStencilTexture = textureView.texture()
            let textureFormat = textureView.format()
            hasStencilComponent = containsStencilAspect(textureFormat)
            hasDepthComponent = containsDepthAspect(textureFormat)
            let isDestroyed = textureView.isDestroyed()
            if !isDestroyed {
                if textureWidth != 0
                    && (textureView.width() != textureWidth || textureView.height() != textureHeight
                        || sampleCount != textureView.sampleCount())
                {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depth stencil texture dimensions mismatch")
                }
                if textureView.arrayLayerCount() > 1 || textureView.mipLevelCount() > 1 {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(
                        shell,
                        device,
                        "depth stencil texture has more than one array layer or mip level"
                    )
                }
            }

            if !isRenderableDepthStencilTextureView(
                textureView,
                isDestroyed,
                hasDepthComponent,
                Optional(fromCxx: attachment.depthLoadOp),
                Optional(fromCxx: attachment.depthStoreOp),
                hasStencilComponent,
                Optional(fromCxx: attachment.stencilLoadOp),
                Optional(fromCxx: attachment.stencilStoreOp)
            ) {
                return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depth stencil texture is not renderable")
            }

            depthReadOnly = attachment.depthReadOnly
            if hasDepthComponent {
                // This is safe because the `depthAttachment` property is `null_resettable` in Objective C.
                // swift-format-ignore: NeverForceUnwrap
                let mtlAttachment = mtlDescriptor.depthAttachment!

                let clearDepth = quantizedDepthValue(Double(attachment.depthClearValue), textureView.format())
                    .clamped(to: 0...1)

                mtlAttachment.clearDepth = Optional(fromCxx: attachment.depthLoadOp) == WebGPU.LoadOp.Clear ? clearDepth : 1.0
                mtlAttachment.texture = metalDepthStencilTexture
                mtlAttachment.level = 0
                mtlAttachment.loadAction = loadAction(loadOp: Optional(fromCxx: attachment.depthLoadOp), readOnly: attachment.depthReadOnly)
                mtlAttachment.storeAction = storeAction(storeOp: Optional(fromCxx: attachment.depthStoreOp))

                if mtlDescriptor.rasterizationRateMap != nil && metalDepthStencilTexture?.sampleCount ?? 1 > 1 {
                    if let depthTexture = device.getXRViewSubImageDepthTexture() {
                        mtlAttachment.resolveTexture = depthTexture
                        mtlAttachment.storeAction = storeAction(storeOp: Optional(fromCxx: attachment.depthStoreOp), hasResolveTarget: true)
                        mtlAttachment.resolveSlice = Int(compositorTextureSlice)
                    }
                }
            }

            if !isDestroyed {
                if hasDepthComponent && !depthReadOnly {
                    if Optional(fromCxx: attachment.depthLoadOp) == nil || Optional(fromCxx: attachment.depthStoreOp) == nil {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "depth load and store op were not specified"
                        )
                    }
                } else if Optional(fromCxx: attachment.depthLoadOp) != nil || Optional(fromCxx: attachment.depthStoreOp) != nil {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depth load and store op were specified")
                }
            }

            if Optional(fromCxx: attachment.depthLoadOp) == WebGPU.LoadOp.Clear
                && (attachment.depthClearValue < 0 || attachment.depthClearValue > 1)
            {
                return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "depth clear value is invalid")
            }

            if zeroColorTargets {
                if isDestroyed {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(
                        shell,
                        device,
                        "no color targets and depth-stencil texture is destroyed"
                    )
                }
                #if compiler(>=6.4)
                guard let metalDepthStencilTexture, metalDepthStencilTexture.sampleCount > 0 else {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(
                        shell,
                        device,
                        "no color targets and depth-stencil texture is nil"
                    )
                }
                #else
                // FIXME: (rdar://170907318) Remove this branch once the minimum supported compiler is Swift 6.4.
                guard var metalDepthStencilTexture, metalDepthStencilTexture.sampleCount > 0 else {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(
                        shell,
                        device,
                        "no color targets and depth-stencil texture is nil"
                    )
                }
                #endif

                mtlDescriptor.defaultRasterSampleCount = metalDepthStencilTexture.sampleCount
                mtlDescriptor.renderTargetWidth = metalDepthStencilTexture.width
                mtlDescriptor.renderTargetHeight = metalDepthStencilTexture.height
            }
        }

        if let attachment = optionalDepthStencilAttachment {
            // This is safe because the `stencilAttachment` property is `null_resettable` in Objective C.
            // swift-format-ignore: NeverForceUnwrap
            let mtlAttachment = mtlDescriptor.stencilAttachment!
            stencilReadOnly = attachment.stencilReadOnly
            var textureView = attachment.view
            if hasStencilComponent {
                mtlAttachment.texture = textureView.texture()
            }
            mtlAttachment.clearStencil = attachment.stencilClearValue
            mtlAttachment.loadAction = loadAction(loadOp: Optional(fromCxx: attachment.stencilLoadOp), readOnly: attachment.stencilReadOnly)
            mtlAttachment.storeAction = storeAction(storeOp: Optional(fromCxx: attachment.stencilStoreOp))
            let isDestroyed = textureView.isDestroyed()
            if !isDestroyed {
                if hasStencilComponent && !stencilReadOnly {
                    if Optional(fromCxx: attachment.stencilLoadOp) == nil || Optional(fromCxx: attachment.stencilStoreOp) == nil {
                        return WebGPU.Metal.RenderPassEncoder.createInvalid(
                            shell,
                            device,
                            "stencil load and store op were not specified"
                        )
                    }
                } else if Optional(fromCxx: attachment.stencilLoadOp) != nil || Optional(fromCxx: attachment.stencilStoreOp) != nil {
                    return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "stencil load and store op were specified")
                }
            }

            textureView.setCommandEncoder(shell)
        }

        if zeroColorTargets && mtlDescriptor.renderTargetWidth == 0 {
            return WebGPU.Metal.RenderPassEncoder.createInvalid(shell, device, "zero color and depth targets")
        }

        var visibilityResultBufferSize: UInt = 0
        var visibilityResultBuffer: (any MTLBuffer)? = nil
        if let occlusionQuery = WebGPU.Metal.metalOrNull(descriptor.occlusionQuerySet) {
            occlusionQuery.setCommandEncoder(shell)
            if Optional(fromCxx: occlusionQuery.type()) != WebGPU.QueryType.Occlusion {
                return WebGPU.Metal.RenderPassEncoder.createInvalid(
                    shell,
                    device,
                    "querySet for occlusion query was not of type occlusion"
                )
            }
            mtlDescriptor.visibilityResultBuffer = occlusionQuery.visibilityBuffer()
            visibilityResultBuffer = mtlDescriptor.visibilityResultBuffer
            visibilityResultBufferSize = occlusionQuery.isDestroyed() ? UInt.max : UInt(occlusionQuery.visibilityBuffer().length)
        }

        if !deviceImpl.isValid() {
            return WebGPU.Metal.RenderPassEncoder.createInvalid(
                shell,
                device,
                "GPUDevice was invalid, this will be an error submitting the command buffer"
            )
        }

        return createRenderPassEncoder(
            shell,
            descriptor,
            visibilityResultBufferSize,
            depthReadOnly,
            stencilReadOnly,
            visibilityResultBuffer,
            maxDrawCount,
            mtlDescriptor
        )
    }

    // A render pass that loads and stores every attachment and has no occlusion query cannot change anything unless it
    // encodes a command, so its render command encoder is not created until the pass actually encodes one. This keeps
    // the (common) empty-pass case off the budget of rotateCommandBufferIfNeeded().
    private func canDeferRenderCommandEncoder(_ descriptor: MTLRenderPassDescriptor) -> Bool {
        if enableEncoderTimestamps() {
            return false
        }

        if descriptor.visibilityResultBuffer != nil || descriptor.rasterizationRateMap != nil {
            return false
        }

        for i in 0..<8 {
            // MTLRenderPassColorAttachmentDescriptorArray is bounds-checked internally.
            guard let attachment = descriptor.colorAttachments[i], attachment.texture != nil else {
                continue
            }
            if attachment.loadAction != .load || attachment.storeAction != .store || attachment.resolveTexture != nil {
                return false
            }
        }

        if let depthAttachment = descriptor.depthAttachment, depthAttachment.texture != nil,
            depthAttachment.loadAction != .load || depthAttachment.storeAction != .store
        {
            return false
        }

        if let stencilAttachment = descriptor.stencilAttachment, stencilAttachment.texture != nil,
            stencilAttachment.loadAction != .load || stencilAttachment.storeAction != .store
        {
            return false
        }

        return true
    }

    // Creates the MTLRenderCommandEncoder, or defers it if the pass cannot change anything without encoding a command.
    private func createRenderPassEncoder(
        _ shell: WebGPU.Metal.CommandEncoder,
        _ descriptor: borrowing WebGPU.RenderPassDescriptor,
        _ visibilityResultBufferSize: UInt,
        _ depthReadOnly: Bool,
        _ stencilReadOnly: Bool,
        _ visibilityResultBuffer: (any MTLBuffer)?,
        _ maxDrawCount: UInt64,
        _ mtlDescriptor: MTLRenderPassDescriptor
    ) -> CxxBridging.RefRenderPassEncoder {
        if canDeferRenderCommandEncoder(mtlDescriptor) {
            let renderPassEncoder = WebGPU.Metal.RenderPassEncoder.create(
                nil,
                descriptor,
                visibilityResultBufferSize,
                depthReadOnly,
                stencilReadOnly,
                shell,
                visibilityResultBuffer,
                maxDrawCount,
                device,
                mtlDescriptor
            )
            renderPassEncoder.ptr().deferRenderCommandEncoder(mtlDescriptor)
            return renderPassEncoder
        }

        let mtlRenderCommandEncoder = makeRenderCommandEncoder(mtlDescriptor)
        return WebGPU.Metal.RenderPassEncoder.create(
            mtlRenderCommandEncoder,
            descriptor,
            visibilityResultBufferSize,
            depthReadOnly,
            stencilReadOnly,
            shell,
            visibilityResultBuffer,
            maxDrawCount,
            device,
            mtlDescriptor
        )
    }

    static func hasValidDimensions(dimension: WebGPU.TextureDimension, width: UInt, height: UInt, depth: UInt) -> Bool {
        switch dimension {
        case WebGPU.TextureDimension._1d:
            width != 0
        case WebGPU.TextureDimension._2d:
            width != 0 && height != 0
        case WebGPU.TextureDimension._3d:
            width != 0 && height != 0 && depth != 0
        default:
            true
        }
    }

    fileprivate func copyBufferToBuffer(
        source: BufferImpl,
        sourceOffset: UInt64,
        destination: BufferImpl,
        destinationOffset: UInt64,
        size: UInt64,
    ) {
        // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-copybuffertobuffer
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError()
            return
        }

        if let error = self.errorValidatingCopyBufferToBuffer(
            source: source,
            sourceOffset: sourceOffset,
            destination: destination,
            destinationOffset: destinationOffset,
            size: size
        ) {
            makeInvalid(error)
            return
        }

        source.setCommandEncoder(self, mayModifyBuffer: false)
        destination.setCommandEncoder(self, mayModifyBuffer: false)
        destination.indirectBufferInvalidated(by: self)
        guard size != 0, !source.isDestroyed() && !destination.isDestroyed() else {
            return
        }

        guard let blitCommandEncoder = ensureBlitCommandEncoder(), let sourceBuffer = source.buffer(),
            let destinationBuffer = destination.buffer()
        else {
            return
        }
        blitCommandEncoder.copy(
            from: sourceBuffer,
            sourceOffset: Int(sourceOffset),
            to: destinationBuffer,
            destinationOffset: Int(destinationOffset),
            size: Int(size)
        )
    }

    fileprivate func copyTextureToBuffer(
        source: WebGPU.TexelCopyTextureInfo,
        sourceTexture: TextureImpl,
        destination: WebGPU.TexelCopyBufferInfo,
        destinationBuffer apiDestinationBuffer: BufferImpl,
        copySize: WebGPU.Extent3D
    ) {
        // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-copytexturetobuffer

        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError()
            return
        }

        if let error = errorValidatingCopyTextureToBuffer(
            source: source,
            sourceTexture: sourceTexture,
            destination: destination,
            destinationBuffer: apiDestinationBuffer,
            copySize: copySize
        ) {
            makeInvalid(error)
            return
        }

        sourceTexture.setCommandEncoder(self)
        apiDestinationBuffer.setCommandEncoder(self, mayModifyBuffer: false)
        apiDestinationBuffer.indirectBufferInvalidated(by: self)
        guard !sourceTexture.isDestroyed() && !apiDestinationBuffer.isDestroyed() else {
            return
        }

        var options: MTLBlitOption = []
        switch source.aspect {
        case WebGPU.TextureAspect.All:
            break
        case WebGPU.TextureAspect.StencilOnly:
            options = .stencilFromDepthStencil
        case WebGPU.TextureAspect.DepthOnly:
            options = .depthFromDepthStencil
        default:
            return
        }

        let logicalSize = sourceTexture.logicalMiplevelSpecificTextureExtent(source.mipLevel)
        let widthForMetal = logicalSize.width < source.origin.x ? 0 : min(copySize.width, logicalSize.width - source.origin.x)
        let heightForMetal = logicalSize.height < source.origin.y ? 0 : min(copySize.height, logicalSize.height - source.origin.y)
        let depthForMetal =
            logicalSize.depthOrArrayLayers < source.origin.z
            ? 0 : min(copySize.depthOrArrayLayers, logicalSize.depthOrArrayLayers - source.origin.z)

        guard let destinationBuffer = apiDestinationBuffer.buffer() else {
            return
        }
        var destinationBytesPerRow = UInt(Optional(fromCxx: destination.layout.bytesPerRow) ?? UInt32(WGPU_COPY_STRIDE_UNDEFINED))
        if destinationBytesPerRow == WGPU_COPY_STRIDE_UNDEFINED {
            destinationBytesPerRow = UInt(destinationBuffer.length)
        }

        let sourceTextureFormat = sourceTexture.formatOrDefault
        guard let aspectSpecificFormat = aspectSpecificFormat(sourceTextureFormat, source.aspect)
        else {
            return
        }
        let blockSize = texelBlockSize(aspectSpecificFormat)
        let textureDimension = sourceTexture.backingDimension
        var didOverflow: Bool
        switch textureDimension {
        case WebGPU.TextureDimension._1d:
            var product = blockSize
            (product, didOverflow) = product.multipliedReportingOverflow(by: deviceImpl.deviceLimits().maxTextureDimension1D)
            if !didOverflow {
                destinationBytesPerRow = min(destinationBytesPerRow, UInt(product))
            }
        case WebGPU.TextureDimension._2d, WebGPU.TextureDimension._3d:
            var product = blockSize
            (product, didOverflow) = product.multipliedReportingOverflow(by: deviceImpl.deviceLimits().maxTextureDimension2D)
            if !didOverflow {
                destinationBytesPerRow = min(destinationBytesPerRow, UInt(product))
            }
        default:
            break
        }

        destinationBytesPerRow = roundUpToMultipleOfNonPowerOfTwo(UInt(blockSize), destinationBytesPerRow)
        let blockHeight = texelBlockHeight(aspectSpecificFormat)
        guard blockHeight != 0 else {
            return
        }
        if textureDimension == WebGPU.TextureDimension._3d && copySize.depthOrArrayLayers <= 1 && copySize.height <= blockHeight {
            destinationBytesPerRow = 0
        }

        var rowsPerImage = Optional(fromCxx: destination.layout.rowsPerImage) ?? UInt32(WGPU_COPY_STRIDE_UNDEFINED)
        if rowsPerImage == WGPU_COPY_STRIDE_UNDEFINED {
            rowsPerImage = heightForMetal != 0 ? heightForMetal : 1
        }
        var destinationBytesPerImage = UInt64(rowsPerImage)
        (destinationBytesPerImage, didOverflow) = destinationBytesPerImage.multipliedReportingOverflow(by: UInt64(destinationBytesPerRow))
        guard !didOverflow else {
            return
        }

        let maxDestinationBytesPerRow =
            textureDimension == WebGPU.TextureDimension._3d ? (2048 * UInt(blockSize)) : destinationBytesPerRow
        if destinationBytesPerRow > maxDestinationBytesPerRow {
            // Each copy below is one row of blocks.
            var rowCopySize = copySize
            rowCopySize.height = blockHeight
            rowCopySize.depthOrArrayLayers = 1
            for z in 0..<copySize.depthOrArrayLayers {
                var zPlusOriginZ = z
                (zPlusOriginZ, didOverflow) = zPlusOriginZ.addingReportingOverflow(source.origin.z)
                guard !didOverflow else {
                    return
                }
                var zTimesDestinationBytesPerImage = z
                guard destinationBytesPerImage <= UInt32.max else {
                    return
                }
                (zTimesDestinationBytesPerImage, didOverflow) = zTimesDestinationBytesPerImage.multipliedReportingOverflow(
                    by: UInt32(destinationBytesPerImage)
                )
                guard !didOverflow else {
                    return
                }
                for y in stride(from: 0, to: copySize.height, by: Int(blockHeight)) {
                    var yPlusOriginY = source.origin.y
                    (yPlusOriginY, didOverflow) = yPlusOriginY.addingReportingOverflow(y)
                    guard !didOverflow else {
                        return
                    }
                    var blockRowTimesDestinationBytesPerRow = y / blockHeight
                    guard destinationBytesPerRow <= UInt32.max else {
                        return
                    }
                    (blockRowTimesDestinationBytesPerRow, didOverflow) = blockRowTimesDestinationBytesPerRow.multipliedReportingOverflow(
                        by: UInt32(destinationBytesPerRow)
                    )
                    guard !didOverflow else {
                        return
                    }
                    var newSource = source
                    newSource.origin.y = yPlusOriginY
                    newSource.origin.z = zPlusOriginZ
                    var tripleSum = UInt64(destination.layout.offset)
                    (tripleSum, didOverflow) = tripleSum.addingReportingOverflow(UInt64(zTimesDestinationBytesPerImage))
                    guard !didOverflow else {
                        return
                    }
                    (tripleSum, didOverflow) = tripleSum.addingReportingOverflow(UInt64(blockRowTimesDestinationBytesPerRow))
                    guard !didOverflow else {
                        return
                    }
                    // The rows are copied one at a time, so the layout has no strides.
                    var newDestination = destination
                    newDestination.layout = WebGPU.TexelCopyBufferLayout()
                    newDestination.layout.offset = tripleSum
                    self.copyTextureToBuffer(
                        source: newSource,
                        sourceTexture: sourceTexture,
                        destination: newDestination,
                        destinationBuffer: apiDestinationBuffer,
                        copySize: rowCopySize
                    )
                }
            }
            return
        }

        guard let blitCommandEncoder = ensureBlitCommandEncoder() else {
            return
        }

        for layer in 0..<copySize.depthOrArrayLayers {
            var originZPlusLayer = UInt(source.origin.z)
            (originZPlusLayer, didOverflow) = originZPlusLayer.addingReportingOverflow(UInt(layer))
            guard !didOverflow else {
                return
            }
            let sourceSlice = sourceTexture.backingDimension == WebGPU.TextureDimension._3d ? 0 : originZPlusLayer
            noteTextureInit(sourceTexture, source.mipLevel, UInt32(sourceSlice), source.aspect, .read)
        }

        guard
            Self.hasValidDimensions(
                dimension: sourceTexture.backingDimension,
                width: UInt(widthForMetal),
                height: UInt(heightForMetal),
                depth: UInt(depthForMetal)
            )
        else {
            return
        }

        guard destinationBuffer.length >= textureBytesPerRow(aspectSpecificFormat, widthForMetal, sourceTexture.sampleCount())
        else {
            return
        }

        guard let mtlSourceTexture = sourceTexture.texture() else {
            return
        }

        switch sourceTexture.backingDimension {
        case WebGPU.TextureDimension._1d:
            // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400756-copyfromtexture?language=objc
            // "When you copy to a 1D texture, height and depth must be 1."
            let sourceSize = MTLSize(width: Int(widthForMetal), height: 1, depth: 1)
            let sourceOrigin = MTLOrigin(x: Int(source.origin.x), y: 0, z: 0)
            for layer in 0..<copySize.depthOrArrayLayers {
                var layerTimesDestinationBytesPerImage = UInt64(layer)
                (layerTimesDestinationBytesPerImage, didOverflow) = layerTimesDestinationBytesPerImage.multipliedReportingOverflow(
                    by: destinationBytesPerImage
                )
                guard !didOverflow else {
                    return
                }
                var destinationOffset = destination.layout.offset
                (destinationOffset, didOverflow) = destinationOffset.addingReportingOverflow(layerTimesDestinationBytesPerImage)
                guard !didOverflow else {
                    return
                }
                var sourceSlice = UInt(source.origin.z)
                (sourceSlice, didOverflow) = sourceSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return
                }
                var widthTimesBlockSize = UInt(widthForMetal)
                (widthTimesBlockSize, didOverflow) = widthTimesBlockSize.multipliedReportingOverflow(by: UInt(blockSize))
                guard !didOverflow else {
                    return
                }
                var sum = destinationOffset
                (sum, didOverflow) = sum.addingReportingOverflow(UInt64(widthTimesBlockSize))
                guard !didOverflow else {
                    return
                }
                if sum > destinationBuffer.length {
                    continue
                }
                blitCommandEncoder
                    .copy(
                        from: mtlSourceTexture,
                        sourceSlice: Int(sourceSlice),
                        sourceLevel: Int(source.mipLevel),
                        sourceOrigin: sourceOrigin,
                        sourceSize: sourceSize,
                        to: destinationBuffer,
                        destinationOffset: Int(destinationOffset),
                        destinationBytesPerRow: Int(destinationBytesPerRow),
                        destinationBytesPerImage: nsUIntegerBytesPerImage(destinationBytesPerImage),
                        options: options
                    )
            }
        case WebGPU.TextureDimension._2d:
            // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400756-copyfromtexture?language=objc
            // "When you copy to a 2D texture, depth must be 1."
            let sourceSize = MTLSizeMake(Int(widthForMetal), Int(heightForMetal), 1)
            let sourceOrigin = MTLOriginMake(Int(source.origin.x), Int(source.origin.y), 0)
            for layer in 0..<copySize.depthOrArrayLayers {
                var layerTimesBytesPerImage = UInt64(layer)
                (layerTimesBytesPerImage, didOverflow) = layerTimesBytesPerImage.multipliedReportingOverflow(by: destinationBytesPerImage)
                guard !didOverflow else {
                    return
                }
                var destinationOffset = destination.layout.offset
                (destinationOffset, didOverflow) = destinationOffset.addingReportingOverflow(layerTimesBytesPerImage)
                guard !didOverflow else {
                    return
                }
                var sourceSlice = UInt(source.origin.z)
                (sourceSlice, didOverflow) = sourceSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return
                }
                blitCommandEncoder.copy(
                    from: mtlSourceTexture,
                    sourceSlice: Int(sourceSlice),
                    sourceLevel: Int(source.mipLevel),
                    sourceOrigin: sourceOrigin,
                    sourceSize: sourceSize,
                    to: destinationBuffer,
                    destinationOffset: Int(destinationOffset),
                    destinationBytesPerRow: Int(destinationBytesPerRow),
                    destinationBytesPerImage: nsUIntegerBytesPerImage(destinationBytesPerImage),
                    options: options
                )
            }
        case WebGPU.TextureDimension._3d:
            let sourceSize = MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: Int(depthForMetal))
            let sourceOrigin = MTLOrigin(x: Int(source.origin.x), y: Int(source.origin.y), z: Int(source.origin.z))
            let destinationOffset = UInt(destination.layout.offset)
            blitCommandEncoder
                .copy(
                    from: mtlSourceTexture,
                    sourceSlice: 0,
                    sourceLevel: Int(source.mipLevel),
                    sourceOrigin: sourceOrigin,
                    sourceSize: sourceSize,
                    to: destinationBuffer,
                    destinationOffset: Int(destinationOffset),
                    destinationBytesPerRow: Int(destinationBytesPerRow),
                    destinationBytesPerImage: nsUIntegerBytesPerImage(destinationBytesPerImage),
                    options: options,
                )
        default:
            return
        }
    }

    fileprivate func copyBufferToTexture(
        source: WebGPU.TexelCopyBufferInfo,
        sourceBuffer: BufferImpl,
        destination: WebGPU.TexelCopyTextureInfo,
        destinationTexture: TextureImpl,
        copySize: WebGPU.Extent3D
    ) {
        _ = copyBufferToTexture(
            source: source,
            apiBuffer: sourceBuffer,
            destination: destination,
            destinationTexture: destinationTexture,
            copySize: copySize,
            initialization: .decide
        )
    }

    // False when not every write of the copy was encoded, so that its full writes are not recorded.
    private func copyBufferToTexture(
        source: WebGPU.TexelCopyBufferInfo,
        apiBuffer: BufferImpl,
        destination: WebGPU.TexelCopyTextureInfo,
        destinationTexture: TextureImpl,
        copySize: WebGPU.Extent3D,
        initialization: CopyInitialization
    ) -> Bool {
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError()
            return false
        }
        if let error = errorValidatingCopyBufferToTexture(
            source: source,
            sourceBuffer: apiBuffer,
            destination: destination,
            destinationTexture: destinationTexture,
            copySize: copySize
        ) {
            makeInvalid(error)
            return false
        }
        apiBuffer.setCommandEncoder(self, mayModifyBuffer: false)
        destinationTexture.setCommandEncoder(self)

        guard
            copySize.width != 0 || copySize.height != 0 || copySize.depthOrArrayLayers != 0,
            !apiBuffer.isDestroyed(),
            !destinationTexture.isDestroyed()
        else {
            return false
        }

        guard let blitCommandEncoder = ensureBlitCommandEncoder() else {
            return false
        }
        var sourceBytesPerRow = UInt(Optional(fromCxx: source.layout.bytesPerRow) ?? UInt32(WGPU_COPY_STRIDE_UNDEFINED))
        guard let sourceBuffer = apiBuffer.buffer() else {
            return false
        }
        if sourceBytesPerRow == WGPU_COPY_STRIDE_UNDEFINED {
            sourceBytesPerRow = UInt(sourceBuffer.length)
        }
        guard
            let aspectSpecificFormat = aspectSpecificFormat(destinationTexture.formatOrDefault, destination.aspect)
        else {
            return false
        }
        let blockSize = texelBlockSize(aspectSpecificFormat)
        let limits = deviceImpl.deviceLimits()
        switch destinationTexture.backingDimension {
        case WebGPU.TextureDimension._1d:
            let (result, didOverflow) = blockSize.multipliedReportingOverflow(by: limits.maxTextureDimension1D)
            if !didOverflow {
                sourceBytesPerRow = min(sourceBytesPerRow, UInt(result))
            }
        case WebGPU.TextureDimension._2d, WebGPU.TextureDimension._3d:
            let (result, didOverflow) = blockSize.multipliedReportingOverflow(by: limits.maxTextureDimension2D)
            if !didOverflow {
                sourceBytesPerRow = min(sourceBytesPerRow, UInt(result))
            }
        default:
            break
        }

        var options: MTLBlitOption = []
        switch destination.aspect {
        case WebGPU.TextureAspect.StencilOnly:
            options = .stencilFromDepthStencil
        case WebGPU.TextureAspect.DepthOnly:
            options = .depthFromDepthStencil
        case WebGPU.TextureAspect.All:
            break
        default:
            return false
        }
        let logicalSize = destinationTexture.logicalMiplevelSpecificTextureExtent(destination.mipLevel)
        let widthForMetal = logicalSize.width < destination.origin.x ? 0 : min(copySize.width, logicalSize.width - destination.origin.x)
        let heightForMetal = logicalSize.height < destination.origin.y ? 0 : min(copySize.height, logicalSize.height - destination.origin.y)
        let depthForMetal =
            logicalSize.depthOrArrayLayers < destination.origin.z
            ? 0 : min(copySize.depthOrArrayLayers, logicalSize.depthOrArrayLayers - destination.origin.z)
        var rowsPerImage = Optional(fromCxx: source.layout.rowsPerImage) ?? UInt32(WGPU_COPY_STRIDE_UNDEFINED)
        if rowsPerImage == WGPU_COPY_STRIDE_UNDEFINED {
            rowsPerImage = heightForMetal != 0 ? heightForMetal : 1
        }
        var sourceBytesPerImage: UInt64
        var didOverflow: Bool
        (sourceBytesPerImage, didOverflow) = UInt64(rowsPerImage).multipliedReportingOverflow(by: UInt64(sourceBytesPerRow))
        guard !didOverflow else {
            return false
        }
        let mtlDestinationTexture = destinationTexture.texture()
        let textureDimension = destinationTexture.backingDimension

        let sliceCount = textureDimension == WebGPU.TextureDimension._3d ? 1 : copySize.depthOrArrayLayers
        // A full write is recorded once all of the copy has been encoded.
        let writesAll =
            initialization == .decide
            && writeWillCompletelyClear(
                textureDimension,
                widthForMetal,
                logicalSize.width,
                heightForMetal,
                logicalSize.height,
                depthForMetal,
                logicalSize.depthOrArrayLayers
            )
        for layer in 0..<sliceCount {
            var originPlusLayer = destination.origin.z
            (originPlusLayer, didOverflow) = originPlusLayer.addingReportingOverflow(layer)
            if didOverflow {
                return false
            }
            let destinationSlice = destinationTexture.backingDimension == WebGPU.TextureDimension._3d ? 0 : originPlusLayer

            guard let mtlDestinationTexture else {
                fatalError("mtlDestinationTexture is nil")
            }

            precondition(mtlDestinationTexture.parent == nil, "mtlDestinationTexture.parentTexture is not nil")

            if initialization == .decide && !writesAll {
                noteTextureInit(destinationTexture, destination.mipLevel, destinationSlice, destination.aspect, .partialWrite)
            }
        }
        let maxSourceBytesPerRow =
            textureDimension == WebGPU.TextureDimension._3d ? (2048 * UInt(blockSize)) : sourceBytesPerRow
        let blockHeight = texelBlockHeight(aspectSpecificFormat)
        guard blockHeight != 0 else {
            return false
        }
        if textureDimension == WebGPU.TextureDimension._3d && copySize.depthOrArrayLayers <= 1 && copySize.height <= blockHeight {
            sourceBytesPerRow = 0
        }
        if sourceBytesPerRow > maxSourceBytesPerRow {
            // Each copy below is one row of blocks.
            var rowCopySize = copySize
            rowCopySize.height = blockHeight
            rowCopySize.depthOrArrayLayers = 1
            for z in 0..<copySize.depthOrArrayLayers {
                var destinationOriginPlusZ = destination.origin.z
                (destinationOriginPlusZ, didOverflow) = destinationOriginPlusZ.addingReportingOverflow(z)
                guard !didOverflow else {
                    return false
                }
                var zTimesSourceBytesPerImage = z
                guard let sourceBytesPerImageU32 = UInt32(exactly: sourceBytesPerImage) else {
                    return false
                }
                (zTimesSourceBytesPerImage, didOverflow) = zTimesSourceBytesPerImage.multipliedReportingOverflow(by: sourceBytesPerImageU32)
                guard !didOverflow else {
                    return false
                }
                guard let sourceBytesPerRowU32 = UInt32(exactly: sourceBytesPerRow) else {
                    return false
                }
                for y in stride(from: 0, to: copySize.height, by: Int(blockHeight)) {
                    var blockRowTimesSourceBytesPerRow = y / blockHeight
                    (blockRowTimesSourceBytesPerRow, didOverflow) = blockRowTimesSourceBytesPerRow.multipliedReportingOverflow(
                        by: sourceBytesPerRowU32
                    )
                    guard !didOverflow else {
                        return false
                    }
                    var tripleSum = UInt64(zTimesSourceBytesPerImage)
                    (tripleSum, didOverflow) = tripleSum.addingReportingOverflow(UInt64(blockRowTimesSourceBytesPerRow))
                    guard !didOverflow else {
                        return false
                    }
                    (tripleSum, didOverflow) = tripleSum.addingReportingOverflow(UInt64(source.layout.offset))
                    guard !didOverflow else {
                        return false
                    }
                    // The rows are copied one at a time, so the layout has no strides.
                    var newSource = source
                    newSource.layout = WebGPU.TexelCopyBufferLayout()
                    newSource.layout.offset = tripleSum
                    var destinationOriginPlusY = y
                    (destinationOriginPlusY, didOverflow) = destinationOriginPlusY.addingReportingOverflow(destination.origin.y)
                    guard !didOverflow else {
                        return false
                    }
                    var newDestination = destination
                    newDestination.origin.y = destinationOriginPlusY
                    newDestination.origin.z = destinationOriginPlusZ
                    guard
                        copyBufferToTexture(
                            source: newSource,
                            apiBuffer: apiBuffer,
                            destination: newDestination,
                            destinationTexture: destinationTexture,
                            copySize: rowCopySize,
                            initialization: .handledByCaller
                        )
                    else {
                        return false
                    }
                }
            }
            if writesAll {
                noteFullWrites(destinationTexture, destination, sliceCount)
            }
            return true
        }

        guard sourceBuffer.length >= textureBytesPerRow(aspectSpecificFormat, widthForMetal, destinationTexture.sampleCount())
        else {
            return false
        }

        var skippedLayer = false
        switch destinationTexture.backingDimension {
        case WebGPU.TextureDimension._1d:
            // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400771-copyfrombuffer?language=objc
            // "When you copy to a 1D texture, height and depth must be 1."
            let sourceSize = MTLSize(width: Int(widthForMetal), height: 1, depth: 1)
            guard widthForMetal != 0 else {
                return false
            }

            let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: 0, z: 0)
            var widthTimesBlockSize = widthForMetal
            (widthTimesBlockSize, didOverflow) = widthTimesBlockSize.multipliedReportingOverflow(by: blockSize)
            guard !didOverflow else {
                return false
            }
            sourceBytesPerRow = min(sourceBytesPerRow, UInt(widthTimesBlockSize))
            for layer in 0..<copySize.depthOrArrayLayers {
                var layerTimesSourceBytesPerImage = UInt64(layer)
                (layerTimesSourceBytesPerImage, didOverflow) = layerTimesSourceBytesPerImage.multipliedReportingOverflow(
                    by: sourceBytesPerImage
                )
                guard !didOverflow else {
                    return false
                }

                var sourceOffset = source.layout.offset
                (sourceOffset, didOverflow) = sourceOffset.addingReportingOverflow(layerTimesSourceBytesPerImage)
                guard !didOverflow else {
                    return false
                }
                var destinationSlice = UInt(destination.origin.z)
                (destinationSlice, didOverflow) = destinationSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return false
                }
                var sourceOffsetPlusSourceBytesPerRow = sourceOffset
                (sourceOffsetPlusSourceBytesPerRow, didOverflow) = sourceOffsetPlusSourceBytesPerRow.addingReportingOverflow(
                    UInt64(sourceBytesPerRow)
                )
                guard !didOverflow else {
                    return false
                }
                if sourceOffsetPlusSourceBytesPerRow > sourceBuffer.length {
                    skippedLayer = true
                    continue
                }

                // FIXME: (rdar://170907276) Prove that `mtlDestinationTexture` can never be nil.
                // swift-format-ignore: NeverForceUnwrap
                blitCommandEncoder
                    .copy(
                        from: sourceBuffer,
                        sourceOffset: Int(sourceOffset),
                        sourceBytesPerRow: Int(sourceBytesPerRow),
                        sourceBytesPerImage: nsUIntegerBytesPerImage(sourceBytesPerImage),
                        sourceSize: sourceSize,
                        to: mtlDestinationTexture!,
                        destinationSlice: Int(destinationSlice),
                        destinationLevel: Int(destination.mipLevel),
                        destinationOrigin: destinationOrigin,
                        options: options
                    )
            }
        case WebGPU.TextureDimension._2d:
            // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400771-copyfrombuffer?language=objc
            // "When you copy to a 2D texture, depth must be 1."
            let sourceSize = MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: 1)
            guard widthForMetal != 0 && heightForMetal != 0 else {
                return false
            }

            let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: 0)
            for layer in 0..<copySize.depthOrArrayLayers {
                var layerTimesSourceBytesPerImage = UInt64(layer)
                (layerTimesSourceBytesPerImage, didOverflow) = layerTimesSourceBytesPerImage.multipliedReportingOverflow(
                    by: sourceBytesPerImage
                )
                guard !didOverflow else {
                    return false
                }
                var sourceOffset = source.layout.offset
                (sourceOffset, didOverflow) = sourceOffset.addingReportingOverflow(layerTimesSourceBytesPerImage)
                guard !didOverflow else {
                    return false
                }
                var destinationSlice = UInt(destination.origin.z)
                (destinationSlice, didOverflow) = destinationSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return false
                }

                // FIXME: (rdar://170907276) Prove that `mtlDestinationTexture` can never be nil.
                // swift-format-ignore: NeverForceUnwrap
                blitCommandEncoder
                    .copy(
                        from: sourceBuffer,
                        sourceOffset: Int(sourceOffset),
                        sourceBytesPerRow: Int(sourceBytesPerRow),
                        sourceBytesPerImage: nsUIntegerBytesPerImage(sourceBytesPerImage),
                        sourceSize: sourceSize,
                        to: mtlDestinationTexture!,
                        destinationSlice: Int(destinationSlice),
                        destinationLevel: Int(destination.mipLevel),
                        destinationOrigin: destinationOrigin,
                        options: options
                    )
            }

        case WebGPU.TextureDimension._3d:
            let sourceSize = MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: Int(depthForMetal))
            guard widthForMetal != 0 && heightForMetal != 0 && depthForMetal != 0 else {
                return false
            }

            let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: Int(destination.origin.z))
            let sourceOffset = UInt(source.layout.offset)

            // FIXME: (rdar://170907276) Prove that `mtlDestinationTexture` can never be nil.
            // swift-format-ignore: NeverForceUnwrap
            blitCommandEncoder.copy(
                from: sourceBuffer,
                sourceOffset: Int(sourceOffset),
                sourceBytesPerRow: Int(sourceBytesPerRow),
                sourceBytesPerImage: nsUIntegerBytesPerImage(sourceBytesPerImage),
                sourceSize: sourceSize,
                to: mtlDestinationTexture!,
                destinationSlice: 0,
                destinationLevel: Int(destination.mipLevel),
                destinationOrigin: destinationOrigin,
                options: options
            )
        default:
            assertionFailure()
            return false
        }
        if writesAll && !skippedLayer {
            noteFullWrites(destinationTexture, destination, sliceCount)
        }
        return !skippedLayer
    }

    fileprivate func resolveQuerySet(
        _ querySet: QuerySetImpl,
        firstQuery: UInt32,
        queryCount: UInt32,
        destination: BufferImpl,
        destinationOffset: UInt64
    ) {
        guard self.prepareTheEncoderState() else {
            self.generateInvalidEncoderStateError()
            return
        }

        let isValid = validateResolveQuerySet(
            querySet: querySet,
            firstQuery: firstQuery,
            queryCount: queryCount,
            destination: destination,
            destinationOffset: destinationOffset
        )

        guard
            isValid,
            isValidToUseWith(querySet),
            isValidToUseWith(destination)
        else {
            makeInvalid("GPUCommandEncoder.resolveQuerySet validation failed")
            return
        }

        querySet.setCommandEncoder(self)
        destination.setCommandEncoder(self, mayModifyBuffer: false)
        destination.indirectBufferInvalidated(by: self)

        if querySet.isDestroyed() || destination.isDestroyed() || queryCount == 0 {
            return
        }

        if hasType(querySet, .Occlusion) {
            guard let blitCommandEncoder = ensureBlitCommandEncoder() else {
                return
            }
            guard
                let sourceOffset = Int(exactly: 8 * firstQuery),
                let destinationOffsetChecked = Int(exactly: destinationOffset),
                let size = Int(exactly: 8 * queryCount),
                let visibilityBuffer = querySet.visibilityBuffer(),
                let destinationBuffer = destination.buffer()
            else {
                return
            }
            blitCommandEncoder.copy(
                from: visibilityBuffer,
                sourceOffset: sourceOffset,
                to: destinationBuffer,
                destinationOffset: destinationOffsetChecked,
                size: size
            )
        }

        if hasType(querySet, .Timestamp) {
            // FIXME: https://bugs.webkit.org/show_bug.cgi?id=283385 - https://bugs.webkit.org/show_bug.cgi?id=283088 should be reverted when the blocking issue is resolved
            finalizeBlitCommandEncoder()
            // The signal value does not matter, the event alone prevents reordering. A lost device has no event.
            if let workaround = deviceImpl.resolveTimestampsSharedEvent() {
                commandBuffer()?.encodeSignalEvent(workaround, value: 1)
                commandBuffer()?.encodeWaitForEvent(workaround, value: 1)
            }
            guard ensureBlitCommandEncoder() != nil else {
                return
            }
            guard let buffer = querySet.counterSampleBuffer(), let destinationBuffer = destination.buffer() else {
                return
            }
            let counterSampleBufferOffset = querySet.counterSampleBufferOffset()

            blitCommandEncoder()?
                .resolveCounters(
                    buffer,
                    range: Int(firstQuery + counterSampleBufferOffset)..<Int(firstQuery + counterSampleBufferOffset + queryCount),
                    destinationBuffer: destinationBuffer,
                    destinationOffset: Int(destinationOffset)
                )
        }
    }

    private func validateResolveQuerySet(
        querySet: QuerySetImpl,
        firstQuery: UInt32,
        queryCount: UInt32,
        destination: BufferImpl,
        destinationOffset: UInt64
    ) -> Bool {
        if !querySet.isDestroyed() && !querySet.isValid() {
            return false
        }
        if !destination.isDestroyed() && !destination.isValid() {
            return false
        }
        if !hasUsage(destination, .QueryResolve) {
            return false
        }

        if firstQuery >= querySet.count() {
            return false
        }

        let (countEnd, didOverflow) = firstQuery.addingReportingOverflow(queryCount)
        if didOverflow || countEnd > querySet.count() {
            return false
        }

        if (destinationOffset % 256) != 0 {
            return false
        }

        let (queryCountTimes8, didOverflowMul) = UInt64(queryCount).multipliedReportingOverflow(by: 8)
        if didOverflowMul {
            return false
        }

        let (countTimes8PlusOffset, didOverflowSum) = destinationOffset.addingReportingOverflow(UInt64(queryCountTimes8))
        if didOverflowSum || countTimes8PlusOffset > destination.initialSize() {
            return false
        }

        return true
    }

    fileprivate func copyTextureToTexture(
        source: WebGPU.TexelCopyTextureInfo,
        sourceTexture: TextureImpl,
        destination: WebGPU.TexelCopyTextureInfo,
        destinationTexture: TextureImpl,
        copySize: WebGPU.Extent3D
    ) {
        // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-copytexturetotexture

        guard self.prepareTheEncoderState() else {
            self.generateInvalidEncoderStateError()
            return
        }
        if let error = self.errorValidatingCopyTextureToTexture(
            source: source,
            sourceTexture: sourceTexture,
            destination: destination,
            destinationTexture: destinationTexture,
            copySize: copySize
        ) {
            self.makeInvalid(error)
            return
        }

        sourceTexture.setCommandEncoder(self)
        destinationTexture.setCommandEncoder(self)

        guard !sourceTexture.isDestroyed(), !destinationTexture.isDestroyed() else {
            return
        }

        guard let blitCommandEncoder = ensureBlitCommandEncoder() else {
            return
        }

        let destinationTextureDimension = destinationTexture.backingDimension
        let sliceCount = destinationTextureDimension == WebGPU.TextureDimension._3d ? 1 : copySize.depthOrArrayLayers
        let destinationLogicalSize = destinationTexture.logicalMiplevelSpecificTextureExtent(destination.mipLevel)
        // A full write is recorded once all of the copy has been encoded.
        let writesAll = writeWillCompletelyClear(
            destinationTextureDimension,
            copySize.width,
            destinationLogicalSize.width,
            copySize.height,
            destinationLogicalSize.height,
            copySize.depthOrArrayLayers,
            destinationLogicalSize.depthOrArrayLayers
        )
        var didOverflow: Bool
        for layer in 0..<sliceCount {
            var sourceOriginPlusLayer = UInt(source.origin.z)
            (sourceOriginPlusLayer, didOverflow) = sourceOriginPlusLayer.addingReportingOverflow(UInt(layer))
            guard !didOverflow else {
                return
            }
            let sourceSlice = sourceTexture.backingDimension == WebGPU.TextureDimension._3d ? 0 : sourceOriginPlusLayer
            noteTextureInit(sourceTexture, source.mipLevel, UInt32(truncatingIfNeeded: sourceSlice), source.aspect, .read)
            var destinationOriginPlusLayer = UInt(destination.origin.z)
            (destinationOriginPlusLayer, didOverflow) = destinationOriginPlusLayer.addingReportingOverflow(UInt(layer))
            guard !didOverflow else {
                return
            }
            let destinationSlice: UInt = destinationTexture.backingDimension == WebGPU.TextureDimension._3d ? 0 : destinationOriginPlusLayer
            guard let destinationSliceUInt32 = UInt32(exactly: destinationSlice) else {
                return
            }
            if !writesAll {
                noteTextureInit(destinationTexture, destination.mipLevel, destinationSliceUInt32, destination.aspect, .partialWrite)
            }
        }
        guard
            let mtlDestinationTexture = destinationTexture.texture(),
            let mtlSourceTexture = sourceTexture.texture()
        else {
            return
        }

        // FIXME(PERFORMANCE): Is it actually faster to use the -[MTLBlitCommandEncoder copyFromTexture:...toTexture:...levelCount:]
        // variant, where possible, rather than calling the other variant in a loop?
        var skippedLayer = false
        switch sourceTexture.backingDimension {
        case WebGPU.TextureDimension._1d:
            // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400756-copyfromtexture?language=objc
            // "When you copy to a 1D texture, height and depth must be 1."
            let sourceSize = MTLSize(width: Int(copySize.width), height: 1, depth: 1)
            guard sourceSize.width != 0 else {
                return
            }

            let sourceOrigin = MTLOrigin(x: Int(source.origin.x), y: 0, z: 0)
            let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: 0, z: 0)
            for layer in 0..<copySize.depthOrArrayLayers {
                var sourceSlice = UInt(source.origin.z)
                (sourceSlice, didOverflow) = sourceSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return
                }
                var destinationSlice = UInt(destination.origin.z)
                (destinationSlice, didOverflow) = destinationSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return
                }
                if destinationSlice >= mtlDestinationTexture.arrayLength || sourceSlice >= mtlSourceTexture.arrayLength {
                    skippedLayer = true
                    continue
                }
                blitCommandEncoder.copy(
                    from: mtlSourceTexture,
                    sourceSlice: Int(sourceSlice),
                    sourceLevel: Int(source.mipLevel),
                    sourceOrigin: sourceOrigin,
                    sourceSize: sourceSize,
                    to: mtlDestinationTexture,
                    destinationSlice: Int(destinationSlice),
                    destinationLevel: Int(destination.mipLevel),
                    destinationOrigin: destinationOrigin
                )
            }
        case WebGPU.TextureDimension._2d:
            // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400756-copyfromtexture?language=objc
            // "When you copy to a 2D texture, depth must be 1."
            let sourceSize = MTLSize(width: Int(copySize.width), height: Int(copySize.height), depth: 1)
            guard sourceSize.width != 0, sourceSize.height != 0 else {
                return
            }

            let sourceOrigin = MTLOrigin(x: Int(source.origin.x), y: Int(source.origin.y), z: 0)
            let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: 0)

            for layer in 0..<copySize.depthOrArrayLayers {
                var sourceSlice = UInt(source.origin.z)
                (sourceSlice, didOverflow) = sourceSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return
                }
                var destinationSlice = UInt(destination.origin.z)
                (destinationSlice, didOverflow) = destinationSlice.addingReportingOverflow(UInt(layer))
                guard !didOverflow else {
                    return
                }
                if destinationSlice >= mtlDestinationTexture.arrayLength || sourceSlice >= mtlSourceTexture.arrayLength {
                    skippedLayer = true
                    continue
                }
                blitCommandEncoder.copy(
                    from: mtlSourceTexture,
                    sourceSlice: Int(sourceSlice),
                    sourceLevel: Int(source.mipLevel),
                    sourceOrigin: sourceOrigin,
                    sourceSize: (sourceSize),
                    to: mtlDestinationTexture,
                    destinationSlice: Int(destinationSlice),
                    destinationLevel: Int(destination.mipLevel),
                    destinationOrigin: destinationOrigin
                )
            }
        case WebGPU.TextureDimension._3d:
            let sourceSize = MTLSize(width: Int(copySize.width), height: Int(copySize.height), depth: Int(copySize.depthOrArrayLayers))
            guard sourceSize.width != 0, sourceSize.height != 0, sourceSize.depth != 0 else {
                return
            }
            var originPlusSourceSize = UInt32(destination.origin.z)
            guard let sourceSizeDepthUInt32 = UInt32(exactly: sourceSize.depth) else {
                return
            }
            (originPlusSourceSize, didOverflow) = originPlusSourceSize.addingReportingOverflow(sourceSizeDepthUInt32)
            guard !didOverflow else {
                return
            }
            guard let mtlDestinationTextureDepthUInt32 = UInt32(exactly: mtlDestinationTexture.depth) else {
                return
            }
            guard originPlusSourceSize <= min(destinationLogicalSize.depthOrArrayLayers, mtlDestinationTextureDepthUInt32) else {
                makeInvalid(
                    "GPUCommandEncoder.copyTextureToTexture: destination.origin.z + sourceSize.depth > destinationLogicalSize.depthOrArrayLayers"
                )
                return
            }

            let sourceOrigin = MTLOrigin(x: Int(source.origin.x), y: Int(source.origin.y), z: Int(source.origin.z))
            let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: Int(destination.origin.z))
            blitCommandEncoder.copy(
                from: mtlSourceTexture,
                sourceSlice: 0,
                sourceLevel: Int(source.mipLevel),
                sourceOrigin: sourceOrigin,
                sourceSize: (sourceSize),
                to: mtlDestinationTexture,
                destinationSlice: 0,
                destinationLevel: Int(destination.mipLevel),
                destinationOrigin: destinationOrigin
            )
        default:
            assertionFailure()
            return
        }
        if writesAll && !skippedLayer {
            noteFullWrites(destinationTexture, destination, sliceCount)
        }
    }

    // Records the full writes of a copy into `texture`, once all of the copy has been encoded.
    private func noteFullWrites(_ texture: TextureImpl, _ destination: WebGPU.TexelCopyTextureInfo, _ sliceCount: UInt32) {
        let isVolume = texture.backingDimension == WebGPU.TextureDimension._3d
        for layer in 0..<sliceCount {
            noteTextureInit(texture, destination.mipLevel, isVolume ? 0 : destination.origin.z &+ layer, destination.aspect, .fullWrite)
        }
    }

    // `shell` is this encoder's, which the pass holds.
    fileprivate func beginComputePass(
        shell: WebGPU.Metal.CommandEncoder,
        descriptor: WebGPU.ComputePassDescriptor
    ) -> CxxBridging.RefComputePassEncoder {
        let optionalTimestampWrites = Optional(fromCxx: descriptor.timestampWrites)

        guard prepareTheEncoderState() else {
            self.generateInvalidEncoderStateError()
            // https://gpuweb.github.io/gpuweb/#dom-gpucomputepassencoder-end
            // A pass begun while the command encoder was already locked by another pass never took
            // the encoder over. Ending it is a validation error the page can catch, not a no-op.
            return WebGPU.Metal.ComputePassEncoder.createInvalidWithEncoderStateNotOpen(shell, device, "encoder state is invalid")
        }

        if let error = self.errorValidatingComputePassDescriptor(descriptor: descriptor) {
            return WebGPU.Metal.ComputePassEncoder.createInvalid(shell, device, String(error))
        }

        if let commandBuffer = self.commandBuffer(), commandBuffer.status.rawValue >= MTLCommandBufferStatus.enqueued.rawValue {
            return WebGPU.Metal.ComputePassEncoder.createInvalid(shell, device, "command buffer has already been committed")
        }

        self.finalizeBlitCommandEncoder()

        guard deviceImpl.isValid() else {
            return WebGPU.Metal.ComputePassEncoder.createInvalid(
                shell,
                device,
                "GPUDevice was invalid, this will be an error submitting the command buffer"
            )
        }
        let computePassDescriptor = MTLComputePassDescriptor()
        computePassDescriptor.dispatchType = .serial
        var counterSampleBuffer = WebGPU.Metal.QuerySet.CounterSampleBuffer()
        if let timestampWrites = optionalTimestampWrites {
            let timestampsWrites = WebGPU.Metal.metal(timestampWrites.querySet)
            counterSampleBuffer = timestampsWrites.counterSampleBufferWithOffset()
            timestampsWrites.setCommandEncoder(shell)
        }

        if enableEncoderTimestamps() || counterSampleBuffer.buffer != nil {
            // FIXME: (rdar://170907276) Prove that `optionalTimestampWrites` can never be nil.
            // swift-format-ignore: NeverForceUnwrap
            let timestampWrites = optionalTimestampWrites!
            computePassDescriptor.sampleBufferAttachments[0].sampleBuffer =
                counterSampleBuffer.buffer ?? device.timestampsBuffer(commandBuffer(), 2)

            computePassDescriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = timestampWriteIndex(
                writeIndex: writeIndex(timestampWrites, beginning: true),
                defaultValue: Self.counterDontSample,
                offset: counterSampleBuffer.offset
            )

            computePassDescriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = timestampWriteIndex(
                writeIndex: writeIndex(timestampWrites, beginning: false),
                defaultValue: Self.counterDontSample,
                offset: counterSampleBuffer.offset
            )

            if let buffer = counterSampleBuffer.buffer {
                device.trackTimestampsBuffer(commandBuffer(), buffer)
            }
        }
        guard let computeCommandEncoder = commandBuffer()?.makeComputeCommandEncoder(descriptor: computePassDescriptor) else {
            return WebGPU.Metal.ComputePassEncoder.createInvalid(shell, device, "computeCommandEncoder is null")
        }

        self.setExistingEncoder(computeCommandEncoder)
        // FIXME: Figure out a way so that WTFString does not override String in the global
        //        namespace. At the moment it is and that's why we need this.
        computeCommandEncoder.label = CxxBridging.convertWTFStringToNSString(descriptor.label)

        return WebGPU.Metal.ComputePassEncoder.create(computeCommandEncoder, descriptor, shell, device)
    }
}

// MARK: - Resource tracking model

/// The source of CommandEncoderImpl.serial, shared by the encoders of every Instance on their own API threads.
private let commandEncoderSerials = Atomic<UInt64>(0)

// https://gpuweb.github.io/gpuweb/#gpucommandsmixin
enum EncoderState: UInt8 {
    case open
    case locked
    case ended
}

/// The encoders that used a resource, each held weakly.
///
/// Usually 1-3 entries. Entries of encoders that died are pruned lazily.
struct EncoderTracking {
    private struct Entry {
        /// The encoder's CommandEncoderImpl.serial: an entry with the serial of a live encoder is that encoder's, so
        /// matching needs no weak load.
        let serial: UInt64
        weak var encoder: CommandEncoderImpl?
    }

    /// Dead entries are dropped when the array is full, before it grows.
    private var entries: [Entry] = []

    /// Whether add(encoder) would find it.
    ///
    /// A read, so the common repeat costs no modify access.
    func contains(_ encoder: CommandEncoderImpl) -> Bool {
        let serial = encoder.serial
        var index = entries.count
        while index > 0 {
            index -= 1
            if entries[index].serial == serial {
                return true
            }
        }
        return false
    }

    /// Adds `encoder` unless it is present, and returns whether it added it.
    ///
    /// Matches by serial, not by uniqueId, which every invalid encoder shares.
    mutating func add(_ encoder: CommandEncoderImpl) -> Bool {
        let serial = encoder.serial
        var index = entries.count
        while index > 0 {
            index -= 1
            if entries[index].serial == serial {
                return false
            }
        }
        if entries.count >= 8 && entries.count == entries.capacity {
            entries.removeAll { $0.encoder == nil }
        }
        entries.append(Entry(serial: serial, encoder: encoder))
        return true
    }

    /// Matches the serial, as add() and contains() do.
    mutating func remove(_ encoder: CommandEncoderImpl) {
        let serial = encoder.serial
        entries.removeAll { $0.serial == serial }
    }

    /// Drops the encoders that died, then counts.
    mutating func liveCount() -> Int {
        entries.removeAll { $0.encoder == nil }
        return entries.count
    }

    /// The first live encoder: the only one when liveCount() is 1.
    var firstLive: CommandEncoderImpl? {
        for entry in entries {
            if let encoder = entry.encoder {
                return encoder
            }
        }
        return nil
    }

    /// Empties the set and returns the live encoders.
    mutating func takeLive() -> [CommandEncoderImpl] {
        let live = entries.compactMap(\.encoder)
        removeAll()
        return live
    }

    /// The body must not mutate the set it walks: walk a copy where it could.
    func forEachLive(_ body: (CommandEncoderImpl) -> Void) {
        for entry in entries {
            if let encoder = entry.encoder {
                body(encoder)
            }
        }
    }

    mutating func removeAll() {
        entries = []
    }
}

struct WeakBufferAndEncoder {
    weak var buffer: BufferImpl?
    weak var encoder: CommandEncoderImpl?
}

/// A commit action other than the constructor's, which runCommitActions runs first.
enum CommitAction {
    case indirectBufferInvalidated(WeakBufferAndEncoder)
    case rebindBundleSamplers(WebGPU.Metal.RenderBundle, RenderBundleImpl)
}

/// The skipped draw-indexed validations of one buffer.
struct SkippedDrawIndexedValidation {
    weak var buffer: BufferImpl?
    var keys: [(key: DrawIndexKey, vertexCount: UInt32)]
}

// One per GPUCommandEncoder, owned by the C++ CommandEncoder. Runs every WebGPU method; the copies, the passes, finish()
// and resolveQuerySet are in the extension above, behind the entry points the shell calls.
//
// Only the methods that create objects holding the encoder take the shell. The rest use the Device rather than the
// shell, so ~CommandEncoder can call them without passing the dying shell into Swift, and a reported error can re-enter
// this object from the device's uncaptured-error callback.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_expose(Cxx)
final class CommandEncoderImpl {
    private var backingCommandBuffer: (any MTLCommandBuffer)?
    // Filled by rotateCommandBufferIfNeeded, in the order they have to be committed in.
    private var priorCommandBuffers: [any MTLCommandBuffer] = []
    private var renderCommandEncoderCount: UInt32 = 0
    private var existingCommandEncoder: (any MTLCommandEncoder)?
    private var backingBlitCommandEncoder: (any MTLBlitCommandEncoder)?
    // An NSString, not a String, so nil and the object identity reach CommandBuffer::makeInvalid.
    private var lastErrorString: NSString?
    private var debugGroupStackSize: UInt64 = 0
    // The sets are lets: nil off Intel Macs (managed), unless shader validation is on (retained, which makes adding to
    // them a no-op), and on invalid encoders.
    private let backingManagedTextures: NSMutableSet?
    private let backingManagedBuffers: NSMutableSet?
    private let retainedICBs: NSMutableSet?
    private let retainedTextures: NSMutableSet?
    private let retainedBuffers: NSMutableSet?
    // Handed out by identity (timestampBuffers()) to CommandBuffer and Queue, which see later additions.
    private let retainedTimestampBuffers: NSMutableSet?
    private var backingBufferMapCount: Int32 = 0
    private var submitIsInvalid = false
    private var backingSharedEvent: (any MTLSharedEvent)?
    private var backingSharedEventSignalValue: UInt64 = 0
    let deviceImpl: DeviceImpl
    /// Unique per device; UInt64.max for an invalid encoder.
    let uniqueId: UInt64
    /// Unique per process and never reused, unlike uniqueId and the object's address (EncoderTracking).
    @_expose(!Cxx)
    let serial = commandEncoderSerials.wrappingAdd(1, ordering: .relaxed).newValue
    @_expose(!Cxx)
    private(set) var state: EncoderState = .open

    // The buffers and textures this encoder used, held until clearTracking(). Views, external textures and query sets
    // only record the encoder.
    private var trackedBuffers: [(WebGPU.Metal.Buffer, BufferImpl)] = []
    private var trackedTextures: [(WebGPU.Metal.Texture, TextureImpl)] = []
    // The external textures that recorded this encoder in pendingUsers, and the planes it used, until clearTracking().
    // Weak, so that an external texture's Impl, which holds its Device, dies with its shell.
    private var trackedExternalTextures = WeakImplList<ExternalTextureImpl>()
    private var retainedExternalTexturePlanes: [any MTLTexture] = []
    // One strong reference per distinct sampler, keyed by its Impl.
    private var retainedSamplers = WTFHashMap<UInt64, WebGPU.Metal.Sampler>()
    // Appended on every draw and dispatch with a sampler-bearing group, never deduplicated.
    private var bindGroupsToRebind: [(WebGPU.Metal.BindGroup, BindGroupImpl)] = []
    // The skipped draw-indexed validations, keyed by the BufferImpl's identity.
    private var skippedDrawIndexedValidations = WTFHashMap<UInt64, SkippedDrawIndexedValidation>()
    // Whether the constructor's commit action is still to run.
    private var constructorCommitActionPending: Bool
    // The other commit actions. After finish() they are the CommandBuffer's.
    private var commitActions: [CommitAction] = []
    // Set by finish(). A ThreadSafeWeakPtr: the CommandBuffer can die on a Metal thread.
    private var cachedCommandBuffer = CxxBridging.CommandBufferWeakPtr()
    // What this encoder did to lazily initialized texture regions. Moved into the CommandBuffer finish() makes, and
    // dropped with the encoder's work when that is discarded or made invalid.
    private var initializationLedger: InitializationLedger? = InitializationLedger()
    // Declared last, so that the device outlives the rest of the encoder.
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    // An invalid encoder: no command buffer and no sets.
    fileprivate init(device: WebGPU.Metal.Device, deviceImpl: DeviceImpl) {
        self.deviceImpl = deviceImpl
        self.device = device
        self.uniqueId = UInt64.max
        self.constructorCommitActionPending = false
        self.backingManagedTextures = nil
        self.backingManagedBuffers = nil
        self.retainedICBs = nil
        self.retainedTextures = nil
        self.retainedBuffers = nil
        self.retainedTimestampBuffers = nil
        self.initializationLedger = nil
    }

    fileprivate init(
        commandBuffer: (any MTLCommandBuffer)?,
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl,
        shaderValidationEnabled: Bool,
        uniqueId: UInt64
    ) {
        self.backingCommandBuffer = commandBuffer
        self.deviceImpl = deviceImpl
        self.device = device
        self.uniqueId = uniqueId
        // An invalid encoder has no commit action.
        self.constructorCommitActionPending = commandBuffer != nil
        #if arch(x86_64) && (WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST)
        self.backingManagedTextures = NSMutableSet()
        self.backingManagedBuffers = NSMutableSet()
        #else
        self.backingManagedTextures = nil
        self.backingManagedBuffers = nil
        #endif
        self.retainedBuffers = shaderValidationEnabled ? NSMutableSet() : nil
        self.retainedTextures = shaderValidationEnabled ? NSMutableSet() : nil
        self.retainedICBs = shaderValidationEnabled ? NSMutableSet() : nil
        self.retainedTimestampBuffers = NSMutableSet()
    }

    // A message to a nil MTLCommandBuffer returns 0, which is MTLCommandBufferStatusNotEnqueued.
    private func commandBufferStatus() -> UInt {
        backingCommandBuffer?.status.rawValue ?? MTLCommandBufferStatus.notEnqueued.rawValue
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        backingCommandBuffer != nil
    }

    @_expose(Cxx)
    func commandBuffer() -> (any MTLCommandBuffer)? {
        backingCommandBuffer
    }

    @_expose(!Cxx)
    func blitCommandEncoder() -> (any MTLBlitCommandEncoder)? {
        backingBlitCommandEncoder
    }

    @_expose(!Cxx)
    func setLastError(_ errorString: String?) {
        lastErrorString = errorString.map { $0 as NSString }
    }

    @_expose(!Cxx)
    func timestampBuffers() -> NSMutableSet? {
        retainedTimestampBuffers
    }

    @_expose(!Cxx)
    func submitWillBeInvalid() -> Bool {
        submitIsInvalid
    }

    // A nil error passes the last error to the command buffer.
    @_expose(!Cxx)
    func makeSubmitInvalidWithError(_ errorString: NSString?) {
        submitIsInvalid = true
        CxxBridging.makeCommandBufferInvalid(cachedCommandBuffer, (errorString ?? lastErrorString) as String?)
    }

    @_expose(!Cxx)
    func makeSubmitInvalid(_ errorString: String?) {
        makeSubmitInvalidWithError(errorString.map { $0 as NSString })
    }

    @_expose(!Cxx)
    func incrementBufferMapCount() {
        backingBufferMapCount &+= 1
        CxxBridging.setCommandBufferMapCount(cachedCommandBuffer, backingBufferMapCount)
    }

    // Does nothing when the count is already zero.
    @_expose(!Cxx)
    func decrementBufferMapCount() {
        if backingBufferMapCount <= 0 {
            return
        }
        backingBufferMapCount -= 1
        CxxBridging.setCommandBufferMapCount(cachedCommandBuffer, backingBufferMapCount)
    }

    @_expose(!Cxx)
    func setSharedEvent(_ event: (any MTLSharedEvent)?, _ signalValue: UInt64) {
        backingSharedEvent = event
        backingSharedEventSignalValue = signalValue
    }

    @_expose(!Cxx)
    func clearSharedEvent() {
        backingSharedEvent = nil
    }

    @_expose(!Cxx)
    func didCreateRenderCommandEncoder() {
        renderCommandEncoderCount &+= 1
    }

    // Unlike setExistingEncoder(nil), this does not tell the queue.
    @_expose(!Cxx)
    func takeCommandBufferForFinish() -> (any MTLCommandBuffer)? {
        let commandBuffer = backingCommandBuffer
        backingCommandBuffer = nil
        existingCommandEncoder = nil
        return commandBuffer
    }

    // For the CommandBuffer finish() creates.
    @_expose(!Cxx)
    func takePriorCommandBuffers() -> [any MTLCommandBuffer] {
        let commandBuffers = priorCommandBuffers
        priorCommandBuffers = []
        return commandBuffers
    }

    // MARK: Lazy zero-initialization

    @_expose(!Cxx)
    func takeInitializationLedger() -> InitializationLedger? {
        initializationLedger.take()
    }

    private func dropInitializationLedger() {
        initializationLedger = nil
    }

    /// Records how a copy uses one subresource of `texture`, zero-filling it first where it has to.
    @_expose(!Cxx)
    func noteTextureInit(
        _ texture: TextureImpl,
        _ mipLevel: UInt32,
        _ arrayLayer: UInt32,
        _ aspect: WebGPU.TextureAspect,
        _ use: TextureInitUse
    ) {
        for region in texture.initRegions(mipLevel: mipLevel, layer: arrayLayer, aspect: aspect)
        where initializationLedger?.noteCopy(texture, region, reads: use != .fullWrite, writes: use != .read) == .zeroFillHere {
            // After this encoder's own discard of the region: only a zero fill at this point is right.
            guard let blit = ensureBlitCommandEncoder(),
                encodeBlitZeroFill(texture, region, blit, zeroBuffer: { deviceImpl.safeCreateBuffer($0) })
            else {
                makeSubmitInvalid("GPUCommandEncoder: lazy zero-initialization failed")
                continue
            }
            initializationLedger?.noteWritten(texture, region)
        }
    }

    /// RenderPassEncoderImpl, for one aspect of an attachment.
    @_expose(!Cxx)
    func noteAttachment(_ texture: TextureImpl, _ region: InitRegion, _ plan: AttachmentInitPlan) {
        initializationLedger?.noteAttachment(texture, region, plan)
    }

    /// encoderIsCurrent(encoder) for a non-nil encoder, without passing (and so retaining) it.
    @_expose(!Cxx)
    func isCurrentEncoder(_ encoder: ObjectIdentifier) -> Bool {
        guard deviceImpl.isValid(), let existing = existingCommandEncoder else {
            return false
        }
        return ObjectIdentifier(existing) == encoder
    }

    @_expose(!Cxx)
    func encoderIsCurrent(_ commandEncoder: (any MTLCommandEncoder)?) -> Bool {
        deviceImpl.isValid() && existingCommandEncoder === commandEncoder
    }

    @_expose(!Cxx)
    func setExistingEncoder(_ encoder: (any MTLCommandEncoder)?) {
        assert(existingCommandEncoder == nil || encoder == nil)
        existingCommandEncoder = encoder
        deviceImpl.defaultQueue().setEncoderForBuffer(backingCommandBuffer, encoder)
    }

    @_expose(!Cxx)
    func ensureBlitCommandEncoder() -> (any MTLBlitCommandEncoder)? {
        if commandBufferStatus() >= MTLCommandBufferStatus.enqueued.rawValue {
            backingBlitCommandEncoder = nil
            return nil
        }

        if let blitCommandEncoder = backingBlitCommandEncoder {
            if encoderIsCurrent(blitCommandEncoder) {
                return blitCommandEncoder
            }

            finalizeBlitCommandEncoder()
        }

        if !device.isValid() {
            return nil
        }

        let descriptor = MTLBlitPassDescriptor()
        let blitCommandEncoder = backingCommandBuffer?.makeBlitCommandEncoder(descriptor: descriptor)
        backingBlitCommandEncoder = blitCommandEncoder
        setExistingEncoder(blitCommandEncoder)

        return blitCommandEncoder
    }

    @_expose(!Cxx)
    func finalizeBlitCommandEncoder() {
        let blitCommandEncoder = backingBlitCommandEncoder
        if !encoderIsCurrent(blitCommandEncoder) {
            return
        }

        endEncoding(blitCommandEncoder)
        backingBlitCommandEncoder = nil
        setExistingEncoder(nil)
    }

    @_expose(!Cxx)
    func endEncoding(_ encoder: (any MTLCommandEncoder)?) {
        let queue = deviceImpl.defaultQueue()
        let existingEncoder = queue.encoderForBuffer(backingCommandBuffer)
        if existingEncoder !== encoder {
            queue.endEncoding(existingEncoder, backingCommandBuffer)
            setExistingEncoder(nil)
            if lastErrorString != nil {
                discardCommandBuffer()
            }
            return
        }

        queue.endEncoding(existingCommandEncoder, backingCommandBuffer)
        setExistingEncoder(nil)
        backingBlitCommandEncoder = nil
        if lastErrorString != nil {
            discardCommandBuffer()
        }
    }

    @_expose(!Cxx)
    func discardCommandBuffer() {
        dropInitializationLedger()
        releasePriorCommandBuffers()

        if backingCommandBuffer == nil || commandBufferStatus() >= MTLCommandBufferStatus.committed.rawValue {
            retainTimestampsForOneUpdateLoop()
            backingCommandBuffer = nil
            return
        }

        let queue = deviceImpl.defaultQueue()
        let existingEncoder = queue.encoderForBuffer(backingCommandBuffer)
        queue.endEncoding(existingEncoder, backingCommandBuffer)
        queue.removeMTLCommandBuffer(backingCommandBuffer)
        retainTimestampsForOneUpdateLoop()
        backingCommandBuffer = nil
    }

    private func releasePriorCommandBuffers() {
        let commandBuffers = priorCommandBuffers
        priorCommandBuffers = []
        let queue = deviceImpl.defaultQueue()
        for commandBuffer in commandBuffers {
            queue.removeMTLCommandBuffer(commandBuffer)
        }
    }

    private func retainTimestampsForOneUpdateLoop() {
        // Workaround for rdar://143905417
        deviceImpl.defaultQueue().retainTimestampsForOneUpdate(retainedTimestampBuffers)
    }

    @_expose(!Cxx)
    func rotateCommandBufferIfNeeded() {
        let maxRenderCommandEncodersPerCommandBuffer: UInt32 = 4096
        if renderCommandEncoderCount < maxRenderCommandEncodersPerCommandBuffer {
            return
        }

        // The blit encoder belongs to the buffer being retired, so it has to be ended before the swap:
        // afterwards finalizeBlitCommandEncoder() would look it up against the new buffer and find
        // nothing, leaving the retired buffer with an open encoder.
        finalizeBlitCommandEncoder()

        guard
            let commandBuffer = backingCommandBuffer,
            existingCommandEncoder == nil,
            commandBuffer.status.rawValue < MTLCommandBufferStatus.enqueued.rawValue
        else {
            return
        }

        guard let nextCommandBuffer = deviceImpl.defaultQueue().commandBufferWithDescriptor(MTLCommandBufferDescriptor()) else {
            return
        }

        nextCommandBuffer.label = commandBuffer.label
        priorCommandBuffers.append(commandBuffer)
        backingCommandBuffer = nextCommandBuffer
        renderCommandEncoderCount = 0
    }

    @_expose(!Cxx)
    func makeRenderCommandEncoder(_ descriptor: MTLRenderPassDescriptor?) -> (any MTLRenderCommandEncoder)? {
        assert(existingCommandEncoder == nil)
        guard let descriptor, let renderCommandEncoder = backingCommandBuffer?.makeRenderCommandEncoder(descriptor: descriptor) else {
            return nil
        }

        setExistingEncoder(renderCommandEncoder)
        didCreateRenderCommandEncoder()
        return renderCommandEncoder
    }

    @_expose(!Cxx)
    func encodeDeferredRenderPassTimestamps(_ descriptor: MTLRenderPassDescriptor?) {
        guard
            let descriptor,
            let sampleBuffer = descriptor.sampleBufferAttachments[0].sampleBuffer,
            let commandBuffer = backingCommandBuffer,
            existingCommandEncoder == nil,
            commandBuffer.status.rawValue < MTLCommandBufferStatus.enqueued.rawValue
        else {
            return
        }

        let computePassDescriptor = MTLComputePassDescriptor()
        computePassDescriptor.dispatchType = .serial
        computePassDescriptor.sampleBufferAttachments[0].sampleBuffer = sampleBuffer
        computePassDescriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex =
            descriptor.sampleBufferAttachments[0].startOfVertexSampleIndex
        computePassDescriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex =
            descriptor.sampleBufferAttachments[0].endOfFragmentSampleIndex

        let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder(descriptor: computePassDescriptor)
        setExistingEncoder(computeCommandEncoder)
        endEncoding(computeCommandEncoder)
    }

    // Returns false when the encoder was already invalid or its command buffer committed, and nothing changed.
    @_expose(Cxx)
    @discardableResult
    func makeInvalid(_ errorString: NSString?) -> Bool {
        if backingCommandBuffer == nil || commandBufferStatus() >= MTLCommandBufferStatus.committed.rawValue {
            return false
        }

        endEncoding(existingCommandEncoder)
        backingBlitCommandEncoder = nil
        existingCommandEncoder = nil
        releasePriorCommandBuffers()
        deviceImpl.defaultQueue().removeMTLCommandBuffer(backingCommandBuffer)

        backingCommandBuffer = nil
        dropInitializationLedger()
        lastErrorString = errorString
        CxxBridging.makeCommandBufferInvalid(cachedCommandBuffer, errorString as String?)
        return true
    }

    @_expose(!Cxx)
    func addICB(_ icb: (any MTLIndirectCommandBuffer)?) {
        guard let icb else {
            return
        }
        retainedICBs?.add(icb)
    }

    @_expose(!Cxx)
    func addCounterSampleBuffer(_ buffer: (any MTLCounterSampleBuffer)?) {
        guard let buffer else {
            return
        }
        retainedTimestampBuffers?.add(buffer)
    }

    @_expose(!Cxx)
    func addBuffer(_ buffer: (any MTLBuffer)?) {
        guard let buffer else {
            return
        }

        #if arch(x86_64) && (WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST)
        if buffer.storageMode == .managed {
            backingManagedBuffers?.add(buffer)
            return
        }
        #endif
        retainedBuffers?.add(buffer)
    }

    @_expose(!Cxx)
    func addTexture(_ texture: (any MTLTexture)?) {
        guard let texture else {
            return
        }

        #if arch(x86_64) && (WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST)
        if texture.storageMode == .managed {
            backingManagedTextures?.add(texture)
            return
        }
        #endif
        retainedTextures?.add(texture)
    }

    // The error of a command on an encoder whose state is not open: `endedMessage` once it has ended, otherwise the
    // encoder becomes invalid. The messages are the C++ method signatures that __PRETTY_FUNCTION__ produces.
    private func generateInvalidEncoderStateError(endedMessage: String) {
        if isFinished() {
            deviceImpl.generateAValidationError(endedMessage)
        } else {
            makeInvalid(lastErrorString ?? "Encoder state is locked")
        }
    }

    // For the commands in the extension above.
    @_expose(!Cxx)
    func generateInvalidEncoderStateError() {
        generateInvalidEncoderStateError(
            endedMessage: "void WebGPU::Metal::CommandEncoder::generateInvalidEncoderStateError(): encoder state is Ended"
        )
    }

    @_expose(Cxx)
    func pushDebugGroup(_ groupLabel: NSString) {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-pushdebuggroup
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError(
                endedMessage: "virtual void WebGPU::Metal::CommandEncoder::pushDebugGroup(String &&): encoder state is Ended"
            )
            return
        }

        finalizeBlitCommandEncoder()

        debugGroupStackSize &+= 1
        backingCommandBuffer?.pushDebugGroup(groupLabel as String)
    }

    @_expose(Cxx)
    func popDebugGroup() {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-popdebuggroup
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError(
                endedMessage: "virtual void WebGPU::Metal::CommandEncoder::popDebugGroup(): encoder state is Ended"
            )
            return
        }

        if debugGroupStackSize == 0 {
            makeInvalid("validatePopDebugGroup failed")
            return
        }

        finalizeBlitCommandEncoder()

        debugGroupStackSize -= 1
        backingCommandBuffer?.popDebugGroup()
    }

    @_expose(Cxx)
    func insertDebugMarker(_ markerLabel: NSString) {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-insertdebugmarker
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError(
                endedMessage: "virtual void WebGPU::Metal::CommandEncoder::insertDebugMarker(String &&): encoder state is Ended"
            )
            return
        }

        finalizeBlitCommandEncoder()

        // There's no direct way of doing this, so we just push/pop an empty debug group.
        backingCommandBuffer?.pushDebugGroup(markerLabel as String)
        backingCommandBuffer?.popDebugGroup()
    }

    @_expose(Cxx)
    func writeTimestamp(_ querySet: QuerySetImpl, _ queryIndex: UInt32) {
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError(
                endedMessage: "void WebGPU::Metal::CommandEncoder::writeTimestamp(QuerySet &, uint32_t): encoder state is Ended"
            )
            return
        }

        if !deviceImpl.hasFeature(.TimestampQuery) {
            return
        }

        let isTimestampQuerySet = querySet.hasType() && querySet.typeRawValue() == WebGPU.QueryType.Timestamp.rawValue
        if !isTimestampQuerySet || queryIndex >= querySet.count()
            || !isValidToUse(querySet.isValid(), querySet.deviceImpl, with: deviceImpl)
        {
            makeInvalid("GPUCommandEncoder.writeTimestamp validation failed")
            return
        }

        querySet.setCommandEncoder(self)
    }

    private func validateClearBuffer(_ buffer: BufferImpl, _ offset: UInt64, _ size: UInt64) -> Bool {
        if !isValidToUse(buffer.isValid(), buffer.deviceImpl, with: deviceImpl) {
            return false
        }

        if buffer.usageRawValue() & WebGPU.BufferUsage.CopyDestination.rawValue == 0 {
            return false
        }

        if size % 4 != 0 || offset % 4 != 0 {
            return false
        }

        let (end, overflowed) = offset.addingReportingOverflow(size)
        return !overflowed && buffer.initialSize() >= end
    }

    // `size` is UInt64.max for the rest of the buffer after the offset.
    @_expose(Cxx)
    func clearBuffer(_ buffer: BufferImpl, _ offset: UInt64, _ requestedSize: UInt64) {
        // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-clearbuffer
        guard prepareTheEncoderState() else {
            generateInvalidEncoderStateError()
            return
        }

        var size = requestedSize
        if size == .max {
            let (rest, overflowed) = buffer.initialSize().subtractingReportingOverflow(offset)
            if overflowed {
                deviceImpl.generateAValidationError("CommandEncoder::clearBuffer(): offset > buffer.size")
                return
            }
            size = rest
        }

        if !validateClearBuffer(buffer, offset, size) {
            makeInvalid("GPUCommandEncoder.clearBuffer validation failed")
            return
        }

        buffer.setCommandEncoder(self, mayModifyBuffer: false)
        buffer.indirectBufferInvalidated(by: self)
        guard let offsetInt = Int(exactly: offset), let sizeInt = Int(exactly: size) else {
            return
        }
        let range = offsetInt..<(offsetInt + sizeInt)
        guard !buffer.isDestroyed(), sizeInt != 0, let mtlBuffer = buffer.buffer(), range.upperBound <= mtlBuffer.length else {
            return
        }
        guard let blitCommandEncoder = ensureBlitCommandEncoder() else {
            return
        }
        blitCommandEncoder.fill(buffer: mtlBuffer, range: range, value: 0)
    }

    // The WebGPU::CommandEncoder methods whose logic is in the extension above. `shell` is this encoder's: the command
    // buffer and the passes they make hold it.
    @_expose(Cxx)
    func finish(_ shell: WebGPU.Metal.CommandEncoder, _ descriptor: WebGPU.CommandBufferDescriptor) -> CxxBridging.RefCommandBuffer {
        finish(shell: shell, descriptor: descriptor)
    }

    @_expose(Cxx)
    func beginRenderPass(
        _ shell: WebGPU.Metal.CommandEncoder,
        _ descriptor: borrowing WebGPU.RenderPassDescriptor
    ) -> CxxBridging.RefRenderPassEncoder {
        beginRenderPass(shell: shell, descriptor: descriptor)
    }

    @_expose(Cxx)
    func beginComputePass(
        _ shell: WebGPU.Metal.CommandEncoder,
        _ descriptor: WebGPU.ComputePassDescriptor
    ) -> CxxBridging.RefComputePassEncoder {
        beginComputePass(shell: shell, descriptor: descriptor)
    }

    @_expose(Cxx)
    func copyBufferToBuffer(
        _ source: BufferImpl,
        _ sourceOffset: UInt64,
        _ destination: BufferImpl,
        _ destinationOffset: UInt64,
        _ size: UInt64
    ) {
        copyBufferToBuffer(
            source: source,
            sourceOffset: sourceOffset,
            destination: destination,
            destinationOffset: destinationOffset,
            size: size
        )
    }

    @_expose(Cxx)
    func copyBufferToTexture(
        _ source: WebGPU.TexelCopyBufferInfo,
        _ sourceBuffer: BufferImpl,
        _ destination: WebGPU.TexelCopyTextureInfo,
        _ destinationTexture: TextureImpl,
        _ copySize: WebGPU.Extent3D
    ) {
        copyBufferToTexture(
            source: source,
            sourceBuffer: sourceBuffer,
            destination: destination,
            destinationTexture: destinationTexture,
            copySize: copySize
        )
    }

    @_expose(Cxx)
    func copyTextureToBuffer(
        _ source: WebGPU.TexelCopyTextureInfo,
        _ sourceTexture: TextureImpl,
        _ destination: WebGPU.TexelCopyBufferInfo,
        _ destinationBuffer: BufferImpl,
        _ copySize: WebGPU.Extent3D
    ) {
        copyTextureToBuffer(
            source: source,
            sourceTexture: sourceTexture,
            destination: destination,
            destinationBuffer: destinationBuffer,
            copySize: copySize
        )
    }

    @_expose(Cxx)
    func copyTextureToTexture(
        _ source: WebGPU.TexelCopyTextureInfo,
        _ sourceTexture: TextureImpl,
        _ destination: WebGPU.TexelCopyTextureInfo,
        _ destinationTexture: TextureImpl,
        _ copySize: WebGPU.Extent3D
    ) {
        copyTextureToTexture(
            source: source,
            sourceTexture: sourceTexture,
            destination: destination,
            destinationTexture: destinationTexture,
            copySize: copySize
        )
    }

    @_expose(Cxx)
    func resolveQuerySet(
        _ querySet: QuerySetImpl,
        _ firstQuery: UInt32,
        _ queryCount: UInt32,
        _ destination: BufferImpl,
        _ destinationOffset: UInt64
    ) {
        resolveQuerySet(
            querySet,
            firstQuery: firstQuery,
            queryCount: queryCount,
            destination: destination,
            destinationOffset: destinationOffset
        )
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString) {
        backingCommandBuffer?.label = label as String
    }

    // The Swift half of ~CommandEncoder, which must not pass the dying shell into Swift.
    @_expose(Cxx)
    func encoderWillBeDestroyed() {
        finalizeBlitCommandEncoder()
        releasePriorCommandBuffers()
        deviceImpl.defaultQueue().removeMTLCommandBuffer(backingCommandBuffer)
        retainTimestampsForOneUpdateLoop()
        backingCommandBuffer = nil // Do not remove, this is needed to workaround rdar://143905417
        dropInitializationLedger()
        clearTracking()
    }

    // MARK: Encoder state

    @_expose(!Cxx)
    func isLocked() -> Bool {
        state == .locked
    }

    @_expose(!Cxx)
    func isFinished() -> Bool {
        state == .ended
    }

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-prepare-the-encoder-state
    @_expose(!Cxx)
    func prepareTheEncoderState() -> Bool {
        state == .open
    }

    @_expose(!Cxx)
    func setEncoderStateEnded() {
        state = .ended
    }

    @_expose(!Cxx)
    func lock(_ shouldLock: Bool) {
        if state == .ended {
            return
        }

        state = shouldLock ? .locked : .open
        if !shouldLock {
            setExistingEncoder(nil)
        }
    }

    // MARK: The command buffer finish() made

    @_expose(!Cxx)
    func setCachedCommandBuffer(_ commandBuffer: WebGPU.Metal.CommandBuffer) {
        cachedCommandBuffer = CxxBridging.commandBufferThreadSafeWeakPtr(commandBuffer)
    }

    // Texture::waitForCommandBufferCompletion's per-encoder part.
    @_expose(!Cxx)
    func waitForCommandBufferCompletion() -> Bool {
        var gpuExecutionDurationSeconds = 0.0
        let completed = CxxBridging.waitForCommandBufferCompletion(cachedCommandBuffer, &gpuExecutionDurationSeconds)
        if gpuExecutionDurationSeconds != 0 {
            recordGPUExecutionWindowOnCanvasTextures(0, gpuExecutionDurationSeconds)
        }
        return completed
    }

    @_expose(!Cxx)
    func recordGPUExecutionWindowOnCanvasTextures(_ startTime: Double, _ endTime: Double) {
        let textures = trackedTextures
        for (_, texture) in textures where texture.isCanvasBacking() {
            texture.recordGPUExecutionWindow(startTime, endTime)
        }
    }

    // MARK: Resource tracking

    // For a buffer that newly recorded this encoder.
    @_expose(!Cxx)
    func trackBuffer(_ buffer: WebGPU.Metal.Buffer, _ impl: BufferImpl) {
        trackedBuffers.append((buffer, impl))
    }

    @_expose(!Cxx)
    func trackTexture(_ texture: WebGPU.Metal.Texture, _ impl: TextureImpl) {
        trackedTextures.append((texture, impl))
    }

    @_expose(!Cxx)
    func trackExternalTexture(_ impl: ExternalTextureImpl) {
        trackedExternalTextures.add(impl)
    }

    @_expose(!Cxx)
    func retainExternalTexturePlanes(_ texture0: (any MTLTexture)?, _ texture1: (any MTLTexture)?) {
        retainExternalTexturePlane(texture0)
        retainExternalTexturePlane(texture1)
    }

    private func retainExternalTexturePlane(_ plane: (any MTLTexture)?) {
        guard let plane, !retainedExternalTexturePlanes.contains(where: { $0 === plane }) else {
            return
        }
        retainedExternalTexturePlanes.append(plane)
    }

    // Forgets this encoder in every resource it holds, then releases them.
    @_expose(!Cxx)
    func clearTracking() {
        let buffers = trackedBuffers
        let textures = trackedTextures
        let externalTextures = trackedExternalTextures.values
        let planes = retainedExternalTexturePlanes
        trackedBuffers = []
        trackedTextures = []
        trackedExternalTextures.removeAll()
        retainedExternalTexturePlanes = []
        for (_, impl) in buffers {
            impl.tracking.remove(self)
        }
        for (_, impl) in textures {
            impl.tracking.remove(self)
        }
        for impl in externalTextures {
            impl.pendingUsers.remove(self)
        }
        withExtendedLifetime((buffers, textures, externalTextures, planes)) {}
    }

    @_expose(!Cxx)
    func addSampler(_ sampler: WebGPU.Metal.Sampler, _ impl: SamplerImpl) {
        retainedSamplers.add(identityKey(ObjectIdentifier(impl))) { sampler }
    }

    @_expose(!Cxx)
    func rebindSamplersPreCommit(_ group: WebGPU.Metal.BindGroup, _ impl: BindGroupImpl) {
        bindGroupsToRebind.append((group, impl))
    }

    // `vertexCount` is the cached entry's.
    @_expose(!Cxx)
    func recordSkippedDrawIndexedValidation(_ buffer: BufferImpl, _ key: DrawIndexKey, vertexCount: UInt32) {
        let identity = identityKey(ObjectIdentifier(buffer))
        // Another BufferImpl at the address of one that died starts a new list.
        if skippedDrawIndexedValidations.value(forKey: identity)?.buffer !== buffer {
            skippedDrawIndexedValidations.set(identity, SkippedDrawIndexedValidation(buffer: buffer, keys: []))
        }
        skippedDrawIndexedValidations.modifyValue(forKey: identity) { skipped in
            skipped.keys.append((key: key, vertexCount: vertexCount))
        }
    }

    // MARK: Commit actions

    // Dropped when the encoder is invalid, which it is from finish() on.
    @_expose(!Cxx)
    func addCommitAction(_ action: consuming CommitAction) {
        if !isValid() {
            return
        }
        commitActions.append(action)
    }

    // Runs the constructor's action (the skipped index validations, then the sampler rebinds), then the other actions in
    // order, and clears them. Every action runs even after a false.
    @_expose(!Cxx)
    func runCommitActions(_ commandBuffer: WebGPU.Metal.CommandBuffer, _ commandBufferImpl: CommandBufferImpl) -> Bool {
        var result = true
        if constructorCommitActionPending {
            constructorCommitActionPending = false
            runSkippedDrawIndexedValidations(commandBuffer, commandBufferImpl)
            let groups = bindGroupsToRebind
            for (_, group) in groups {
                _ = group.rebindSamplersIfNeeded()
            }
        }

        let actions = commitActions
        commitActions = []
        for action in actions {
            switch action {
            case .indirectBufferInvalidated(let pair):
                if let buffer = pair.buffer, let encoder = pair.encoder {
                    buffer.clearPendingIndexMaxima()
                    buffer.indirectBufferInvalidated(encoder)
                }
            case .rebindBundleSamplers(_, let bundleImpl):
                result = bundleImpl.rebindSamplersIfNeeded() && result
            }
        }
        withExtendedLifetime(actions) {}
        return result
    }

    // CommandBuffer::clearCommitHandlers and the CommandBuffer's destruction, for the handlers it had taken.
    @_expose(!Cxx)
    func clearCommitActions() {
        constructorCommitActionPending = false
        let actions = commitActions
        commitActions = []
        withExtendedLifetime(actions) {}
    }

    // The constructor's action's first walk, in WTF::HashMap order. A buffer destroyed since is skipped.
    private func runSkippedDrawIndexedValidations(_ commandBuffer: WebGPU.Metal.CommandBuffer, _ commandBufferImpl: CommandBufferImpl) {
        let skippedValidations = skippedDrawIndexedValidations
        skippedValidations.forEachInWTFOrder { _, skipped in
            guard let buffer = skipped.buffer, !buffer.isDestroyed() else {
                return
            }
            buffer.removeSkippedValidationCommandEncoder(self)
            if !buffer.mustTakeSlowIndexValidationPath() {
                return
            }
            for (key, vertexCount) in skipped.keys {
                buffer.takeSlowIndexValidationPath(commandBufferImpl, key, vertexCount: vertexCount)
                commandBufferImpl.addPostCommitAction(
                    .clearMustTakeSlowIndexValidationPath(commandBufferImpl.device, WeakBufferAndEncoder(buffer: buffer, encoder: nil))
                )
            }
        }
    }
}

@_expose(Cxx)
func makeCommandEncoderImpl(
    _ commandBuffer: (any MTLCommandBuffer)?,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ shaderValidationEnabled: Bool,
    _ uniqueId: UInt64
) -> CommandEncoderImpl {
    CommandEncoderImpl(
        commandBuffer: commandBuffer,
        device: device,
        deviceImpl: deviceImpl,
        shaderValidationEnabled: shaderValidationEnabled,
        uniqueId: uniqueId
    )
}

@_expose(Cxx)
func makeInvalidCommandEncoderImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> CommandEncoderImpl {
    CommandEncoderImpl(device: device, deviceImpl: deviceImpl)
}
