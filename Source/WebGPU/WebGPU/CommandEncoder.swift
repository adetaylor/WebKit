// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
//
// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

private import CxxStdlib
import Metal
import Synchronization
@_implementationOnly import WebGPU_Internal.BindGroup
@_implementationOnly import WebGPU_Internal.Buffer
@_implementationOnly import WebGPU_Internal.CommandEncoder
@_implementationOnly import WebGPU_Internal.ComputePipeline
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.PresentationContext
@_implementationOnly import WebGPU_Internal.RenderBundleEncoder
@_implementationOnly import WebGPU_Internal.RenderPipeline
@_implementationOnly import WebGPU_Internal.XRProjectionLayer
import WebGPU_Private.WebGPU

typealias String = Swift.String

// Device::createCommandEncoder.
// https://gpuweb.github.io/gpuweb/#dom-gpudevice-createcommandencoder
func deviceCreateCommandEncoder(_ deviceImpl: DeviceImpl, _ label: NSString) -> CommandEncoderImpl {
    if !deviceImpl.isValid() {
        return makeInvalidCommandEncoderImpl(deviceImpl)
    }

    captureSingleFrameIfNeeded(deviceImpl.device())
    guard let commandBuffer = deviceImpl.defaultQueueImpl.commandBufferWithDescriptor(MTLCommandBufferDescriptor()) else {
        return makeInvalidCommandEncoderImpl(deviceImpl)
    }

    commandBuffer.label = label as String

    return makeCommandEncoderImpl(commandBuffer, deviceImpl, deviceImpl.isShaderValidationEnabled(), deviceImpl.takeCommandEncoderId())
}

// What a render pass attachment's view member names: a texture, as its default view, or a texture view.
@_spi(WebKitGPU)
public enum GPURenderPassAttachmentView {
    case texture(TextureReference)
    case textureView(TextureViewReference)

    var impl: AttachmentImpl {
        switch self {
        case .texture(let texture): .texture(texture)
        case .textureView(let view): .textureView(view)
        }
    }

    var attachmentView: AttachmentView {
        switch self {
        case .texture(let texture): .texture(texture)
        case .textureView(let view): .textureView(view)
        }
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gpurenderpasscolorattachment
@_spi(WebKitGPU)
public struct GPURenderPassColorAttachment {
    public var view: GPURenderPassAttachmentView
    public var depthSlice: UInt32?
    public var resolveTarget: GPURenderPassAttachmentView?
    public var clearValue = WebGPU.Color(r: 0, g: 0, b: 0, a: 0)
    public var loadOp = WebGPU.LoadOp.Load
    public var storeOp = WebGPU.StoreOp.Store

    public init(view: GPURenderPassAttachmentView) {
        self.view = view
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gpurenderpassdepthstencilattachment
@_spi(WebKitGPU)
public struct GPURenderPassDepthStencilAttachment {
    public var view: GPURenderPassAttachmentView
    public var depthClearValue: Float = 0
    public var depthLoadOp: WebGPU.LoadOp?
    public var depthStoreOp: WebGPU.StoreOp?
    public var depthReadOnly = false
    public var stencilClearValue: UInt32 = 0
    public var stencilLoadOp: WebGPU.LoadOp?
    public var stencilStoreOp: WebGPU.StoreOp?
    public var stencilReadOnly = false

    public init(view: GPURenderPassAttachmentView) {
        self.view = view
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gpurenderpasstimestampwrites, and GPUComputePassTimestampWrites, which has
// the same members.
@_spi(WebKitGPU)
public struct GPUPassTimestampWrites {
    public var querySet: QuerySetReference
    public var beginningOfPassWriteIndex: UInt32?
    public var endOfPassWriteIndex: UInt32?

    public init(querySet: QuerySetReference) {
        self.querySet = querySet
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gpurenderpassdescriptor, without its label.
@_spi(WebKitGPU)
public struct GPURenderPassDescriptor {
    // nil for an empty slot.
    public var colorAttachments: [GPURenderPassColorAttachment?] = []
    public var depthStencilAttachment: GPURenderPassDepthStencilAttachment?
    public var occlusionQuerySet: QuerySetReference?
    public var timestampWrites: GPUPassTimestampWrites?
    public var maxDrawCount: UInt64?

    public init() {
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gpucomputepassdescriptor, without its label.
@_spi(WebKitGPU)
public struct GPUComputePassDescriptor {
    public var timestampWrites: GPUPassTimestampWrites?

    public init() {
    }
}

@_spi(WebKitGPU)
public typealias CommandEncoderReference = CommandEncoderImpl

// The operations of a command encoder that create nothing.
@_spi(WebKitGPU)
extension CommandEncoderImpl {
    public func copyBufferToTexture(
        _ source: BufferReference,
        _ sourceLocation: BufferCopyLocation,
        _ destination: TextureReference,
        _ destinationLocation: TextureCopyLocation,
        _ copySize: WebGPU.Extent3D
    ) {
        copyBufferToTexture(
            source: sourceLocation,
            sourceBuffer: source,
            destination: destinationLocation,
            destinationTexture: destination,
            copySize: copySize
        )
    }

    public func copyTextureToBuffer(
        _ source: TextureReference,
        _ sourceLocation: TextureCopyLocation,
        _ destination: BufferReference,
        _ destinationLocation: BufferCopyLocation,
        _ copySize: WebGPU.Extent3D
    ) {
        copyTextureToBuffer(
            source: sourceLocation,
            sourceTexture: source,
            destination: destinationLocation,
            destinationBuffer: destination,
            copySize: copySize
        )
    }

    public func copyTextureToTexture(
        _ source: TextureReference,
        _ sourceLocation: TextureCopyLocation,
        _ destination: TextureReference,
        _ destinationLocation: TextureCopyLocation,
        _ copySize: WebGPU.Extent3D
    ) {
        copyTextureToTexture(
            source: sourceLocation,
            sourceTexture: source,
            destination: destinationLocation,
            destinationTexture: destination,
            copySize: copySize
        )
    }

    // nil size: the rest of the buffer after the offset.
    public func clearBuffer(_ buffer: BufferReference, _ offset: UInt64, _ size: UInt64?) {
        clearBuffer(buffer, offset, size ?? UInt64.max)
    }

    // A null label is empty.
    public func pushDebugGroup(_ groupLabel: Swift.String?) {
        pushDebugGroup((groupLabel ?? "") as NSString)
    }

    public func insertDebugMarker(_ markerLabel: Swift.String?) {
        insertDebugMarker((markerLabel ?? "") as NSString)
    }

    public func setLabel(_ label: Swift.String?) {
        setLabel((label ?? "") as NSString)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-beginrenderpass. A render pass has no use for its
    // descriptor's label.
    public func beginRenderPass(_ descriptor: GPURenderPassDescriptor) -> RenderPassEncoderReference {
        beginRenderPass(descriptor: descriptor)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-begincomputepass
    public func beginComputePass(_ descriptor: GPUComputePassDescriptor, label: Swift.String?) -> ComputePassEncoderReference {
        beginComputePass(descriptor: descriptor, label: label)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-finish
    public func finish(label: Swift.String?) -> CommandBufferReference {
        finish(label: WTF.String(label ?? ""))
    }
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createcommandencoder. A null label is empty.
    public func createCommandEncoder(label: Swift.String?) -> CommandEncoderReference {
        deviceCreateCommandEncoder(self, (label ?? "") as NSString)
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gputexelcopybufferinfo without its buffer, which a copy takes as its Impl.
@_spi(WebKitGPU)
public struct BufferCopyLocation {
    public var layout = WebGPU.TexelCopyBufferLayout()

    public init() {
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gputexelcopytextureinfo without its texture, which a copy takes as its Impl.
@_spi(WebKitGPU)
public struct TextureCopyLocation {
    public var mipLevel: UInt32 = 0
    public var origin = WebGPU.Origin3D()
    public var aspect = WebGPU.TextureAspect.All

    public init() {
    }
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

extension GPUPassTimestampWrites {
    init(_ timestampWrites: WebGPU.PassTimestampWrites, _ querySet: QuerySetReference) {
        self.init(querySet: querySet)
        beginningOfPassWriteIndex = Optional(fromCxx: timestampWrites.beginningOfPassWriteIndex)
        endOfPassWriteIndex = Optional(fromCxx: timestampWrites.endOfPassWriteIndex)
    }
}

extension GPURenderPassDescriptor {
}

extension GPUComputePassDescriptor {
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

    private func isValidToUseWith(_ attachment: AttachmentImpl) -> Bool {
        isValidToUse(attachment.isValid, attachment.deviceImpl, with: deviceImpl)
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

    fileprivate func finish(label: WTF.String) -> CommandBufferImpl {
        if !isValid() || (existingCommandEncoder != nil && existingCommandEncoder !== backingBlitCommandEncoder) {
            setEncoderStateEnded()
            discardCommandBuffer()
            deviceImpl.generateAValidationError(lastErrorString.map { $0 as String } ?? "Invalid CommandEncoder")
            return makeInvalidCommandBufferImpl(deviceImpl)
        }

        // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-finish
        let validationFailedError = validateFinishError()

        setEncoderStateEnded()
        if let validationFailedError {
            discardCommandBuffer()
            deviceImpl.generateAValidationError(lastErrorString.map { $0 as String } ?? validationFailedError)
            return makeInvalidCommandBufferImpl(deviceImpl)
        }

        finalizeBlitCommandEncoder()

        let commandBuffer = takeCommandBufferForFinish()

        commandBuffer?.label = stringNilIfEmpty(label)

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

        let result = makeCommandBufferImpl(commandBuffer, backingSharedEvent, backingSharedEventSignalValue, self, deviceImpl)
        cachedCommandBuffer = result
        clearSharedEvent()
        result.setBufferMapCount(backingBufferMapCount)
        if submitIsInvalid {
            result.makeInvalid(lastErrorString ?? "Invalid CommandEncoder")
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

                // The clear pass has the stencil attachment also when it clears only the depth: it loads the stencil.
                if (stencilAttachmentToClear || depthAttachmentToClear)
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
        deviceImpl.defaultQueueImpl.endEncoding(clearRenderCommandEncoder, backingCommandBuffer)
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

        if destination.isMappingPending || source.isMappingPending {
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
        source: TextureCopyLocation,
        sourceTexture: TextureImpl,
        destination: TextureCopyLocation,
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
        source: TextureCopyLocation,
        sourceTexture: TextureImpl,
        destination: BufferCopyLocation,
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

    private func errorValidatingImageCopyBuffer(imageCopyBuffer: BufferCopyLocation, buffer: BufferImpl) -> String? {
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
        source: BufferCopyLocation,
        sourceBuffer: BufferImpl,
        destination: TextureCopyLocation,
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

    private func errorValidatingRenderPassDescriptor(descriptor: GPURenderPassDescriptor) -> String? {
        if let occlusionQuery = descriptor.occlusionQuerySet {
            if !isValidToUseWith(occlusionQuery) {
                return "occlusion query does not match the device"
            }
            if occlusionQuery.queryType != WebGPU.QueryType.Occlusion {
                return "occlusion query type is not occlusion"
            }
        }
        if let timestampWrites = descriptor.timestampWrites {
            return errorValidatingTimestampWrites(timestampWrites: timestampWrites)
        }
        return nil
    }

    // WGPU_QUERY_SET_INDEX_UNDEFINED for nil.
    private func writeIndex(_ timestampWrites: GPUPassTimestampWrites, beginning: Bool) -> UInt32 {
        let index = beginning ? timestampWrites.beginningOfPassWriteIndex : timestampWrites.endOfPassWriteIndex
        return index ?? UInt32(WGPU_QUERY_SET_INDEX_UNDEFINED)
    }

    private func errorValidatingTimestampWrites(timestampWrites: GPUPassTimestampWrites) -> String? {
        let querySet = timestampWrites.querySet
        if !deviceImpl.hasFeature(WebGPU.FeatureName.TimestampQuery) {
            return "device does not have timestamp query feature"
        }

        if querySet.queryType != WebGPU.QueryType.Timestamp {
            // main prints the C++ optional, whose description does not depend on its value.
            return "query type is not timestamp but \(WebGPU.Metal.OptionalQueryType())"
        }

        if !isValidToUseWith(querySet) {
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

    private func errorValidatingComputePassDescriptor(descriptor: GPUComputePassDescriptor) -> String? {
        if let timestampWrites = descriptor.timestampWrites {
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

    fileprivate func beginRenderPass(
        descriptor: GPURenderPassDescriptor
    ) -> RenderPassEncoderImpl {
        let maxDrawCount = descriptor.maxDrawCount ?? UInt64.max

        guard prepareTheEncoderState() else {
            self.generateInvalidEncoderStateError()
            // https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-end
            // A pass begun while the command encoder was already locked by another pass never took
            // the encoder over. Ending it is a validation error the page can catch, not a no-op.
            return makeInvalidRenderPassWithEncoderStateNotOpen("encoder state is not valid")
        }

        if let error = errorValidatingRenderPassDescriptor(descriptor: descriptor) {
            return makeInvalidRenderPass(error)
        }

        if let commandBuffer = self.commandBuffer(), commandBuffer.status.rawValue >= MTLCommandBufferStatus.enqueued.rawValue {
            return makeInvalidRenderPass("command buffer has already been committed")
        }

        // Before anything in this pass is attached to the command buffer, including the timestamps buffer
        // tracked below.
        rotateCommandBufferIfNeeded()

        let mtlDescriptor = MTLRenderPassDescriptor()
        var counterSampleBuffer: (buffer: (any MTLCounterSampleBuffer)?, offset: UInt32) = (nil, 0)
        let optionalTimestampWrites = descriptor.timestampWrites
        if let timestampWrites = optionalTimestampWrites {
            let timestampsWrites = timestampWrites.querySet
            counterSampleBuffer = (timestampsWrites.counterSampleBuffer(), timestampsWrites.counterSampleBufferOffset())
            timestampsWrites.setCommandEncoder(self)
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
                deviceImpl.trackTimestampsBuffer(commandBuffer(), buffer)
            } else {
                mtlDescriptor.sampleBufferAttachments[0].sampleBuffer =
                    counterSampleBuffer.buffer ?? deviceImpl.timestampsBuffer(commandBuffer(), 4)
                mtlDescriptor.sampleBufferAttachments[0].startOfVertexSampleIndex = 0
                mtlDescriptor.sampleBufferAttachments[0].endOfVertexSampleIndex = 1
                mtlDescriptor.sampleBufferAttachments[0].startOfFragmentSampleIndex = 2
                mtlDescriptor.sampleBufferAttachments[0].endOfFragmentSampleIndex = 3
            }
        }

        guard descriptor.colorAttachments.count <= 8 else {
            return makeInvalidRenderPass("color attachment count is > 8")
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
        if !descriptor.colorAttachments.isEmpty {
            for i in 0..<descriptor.colorAttachments.count {
                // An empty slot has no attachment.
                guard let attachment = descriptor.colorAttachments[i] else {
                    continue
                }
                let optionalResolveTarget = attachment.resolveTarget?.impl

                // MTLRenderPassColorAttachmentDescriptorArray is bounds-checked internally, so this is guaranteed to be non-nil.
                // swift-format-ignore: NeverForceUnwrap
                let mtlAttachment = mtlDescriptor.colorAttachments[i]!

                mtlAttachment.clearColor = MTLClearColor(
                    red: attachment.clearValue.r,
                    green: attachment.clearValue.g,
                    blue: attachment.clearValue.b,
                    alpha: attachment.clearValue.a
                )

                let texture = attachment.view.impl
                if !isValidToUseWith(texture) {
                    return makeInvalidRenderPass("device mismatch")
                }

                if textureWidth != 0
                    && (texture.width != textureWidth || texture.height != textureHeight || sampleCount != texture.sampleCount)
                {
                    return makeInvalidRenderPass("texture size does not match")
                }

                textureWidth = texture.width
                textureHeight = texture.height
                sampleCount = texture.sampleCount
                let textureFormat = texture.format
                bytesPerSample = roundUpToMultipleOfNonPowerOfTwoUInt32UInt32(
                    renderTargetPixelByteAlignment(textureFormat),
                    bytesPerSample
                )
                bytesPerSample += renderTargetPixelByteCost(textureFormat)
                if bytesPerSample > maxColorAttachmentBytesPerSample {
                    return makeInvalidRenderPass("total bytes per sample exceeds limit")
                }

                let textureIsDestroyed = texture.isDestroyed
                if !textureIsDestroyed {
                    if !texture.usageContains(.RenderAttachment)
                        || !isColorRenderableFormat(textureFormat, deviceImpl)
                    {
                        return makeInvalidRenderPass("color attachment is not renderable")
                    }

                    if !isRenderableTextureView(texture, attachment.loadOp, attachment.storeOp) {
                        return makeInvalidRenderPass("texture view is not renderable")
                    }
                }
                texture.setCommandEncoder(self)

                let mtlTexture = texture.texture
                mtlAttachment.texture = mtlTexture
                if mtlAttachment.texture == nil {
                    if !textureIsDestroyed {
                        return makeInvalidRenderPass("color attachment's texture is nil")
                    }
                    continue
                }
                mtlAttachment.level = 0
                mtlAttachment.slice = 0
                var depthSliceOrArrayLayer: UInt64 = 0
                #if compiler(>=6.4)
                if let depthSlice = attachment.depthSlice {
                    if !texture.is3DTexture {
                        return makeInvalidRenderPass("depthSlice specified on 2D texture")
                    }
                    depthSliceOrArrayLayer = textureIsDestroyed ? 0 : UInt64(depthSlice)
                    if depthSliceOrArrayLayer >= texture.depthOrArrayLayers {
                        return makeInvalidRenderPass("depthSlice is greater than texture's depth or array layers")
                    }
                } else {
                    if texture.is3DTexture {
                        return makeInvalidRenderPass("textureDimension is 3D and no depth slice is specified")
                    }
                    depthSliceOrArrayLayer = UInt64(textureIsDestroyed ? 0 : texture.baseArrayLayer)
                }
                #else
                // FIXME: (rdar://170907318) Remove this branch once the minimum supported compiler is Swift 6.4.
                if var depthSlice = attachment.depthSlice {
                    if !texture.is3DTexture {
                        return makeInvalidRenderPass("depthSlice specified on 2D texture")
                    }
                    depthSliceOrArrayLayer = textureIsDestroyed ? 0 : UInt64(depthSlice)
                    if depthSliceOrArrayLayer >= texture.depthOrArrayLayers {
                        return makeInvalidRenderPass("depthSlice is greater than texture's depth or array layers")
                    }
                } else {
                    if texture.is3DTexture {
                        return makeInvalidRenderPass("textureDimension is 3D and no depth slice is specified")
                    }
                    depthSliceOrArrayLayer = UInt64(textureIsDestroyed ? 0 : texture.baseArrayLayer)
                }
                #endif
                guard let parentMetalTexture = texture.parentMetalTexture else {
                    preconditionFailure("an attachment with a texture has a parent texture")
                }
                let bridgedTexture = parentMetalTexture.gpuResourceID._impl
                let baseMipLevel = textureIsDestroyed ? 0 : texture.baseMipLevel
                let depthAndMipLevel: UInt64 = depthSliceOrArrayLayer | (UInt64(baseMipLevel) << 32)

                guard depthSlices[bridgedTexture, default: []].insert(depthAndMipLevel).inserted else {
                    return makeInvalidRenderPass("attempting to render to overlapping color attachment")
                }

                mtlAttachment.depthPlane = texture.is3DTexture ? Int(depthSliceOrArrayLayer) : 0
                mtlAttachment.slice = 0
                mtlAttachment.loadAction = loadAction(loadOp: attachment.loadOp)
                mtlAttachment.storeAction = storeAction(
                    storeOp: attachment.storeOp,
                    hasResolveTarget: optionalResolveTarget != nil
                )

                zeroColorTargets = false

                var compositorTexture = texture
                if let resolveTarget = optionalResolveTarget {
                    compositorTexture = resolveTarget

                    if !isValidToUseWith(resolveTarget) {
                        return makeInvalidRenderPass("resolve target created from different device")
                    }
                    resolveTarget.setCommandEncoder(self)
                    let resolveTexture = resolveTarget.texture
                    #if compiler(>=6.4)
                    guard let resolveTexture, let mtlTexture else {
                        return makeInvalidRenderPass("resolveTexture/mtlTexture is nil")
                    }
                    #else
                    // FIXME: (rdar://170907318) Remove this branch once the minimum supported compiler is Swift 6.4.
                    guard var resolveTexture, var mtlTexture else {
                        return makeInvalidRenderPass("resolveTexture/mtlTexture is nil")
                    }
                    #endif

                    if mtlTexture.sampleCount == 1
                        || resolveTexture.sampleCount != 1
                        || isMultisampleTexture(texture: resolveTexture)
                        || !isMultisampleTexture(texture: mtlTexture)
                        || !isRenderableTextureView(resolveTarget, attachment.loadOp, attachment.storeOp)
                        || mtlTexture.pixelFormat != resolveTexture.pixelFormat
                        || !supportsResolve(resolveTarget.format, deviceImpl)
                    {
                        return makeInvalidRenderPass("resolve target is invalid")
                    }

                    mtlAttachment.resolveTexture = resolveTexture
                    mtlAttachment.resolveLevel = 0
                    mtlAttachment.resolveSlice = 0
                    mtlAttachment.resolveDepthPlane = 0
                    if resolveTarget.width != texture.width || resolveTarget.height != texture.height {
                        return makeInvalidRenderPass("resolve target dimensions are invalid")
                    }
                }

                if let rateMap = compositorTexture.rasterizationMapForSlice(compositorTexture.parentRelativeSlice) {
                    mtlDescriptor.rasterizationRateMap = rateMap
                    compositorTextureSlice = compositorTexture.parentRelativeSlice
                }
            }
        }

        var depthReadOnly = false
        var stencilReadOnly = false
        var hasStencilComponent = false
        var hasDepthComponent = false
        let optionalDepthStencilAttachment = descriptor.depthStencilAttachment
        if let attachment = optionalDepthStencilAttachment {
            let textureView = attachment.view.impl
            if !isValidToUseWith(textureView) {
                return makeInvalidRenderPass("depth stencil texture device mismatch")
            }
            let metalDepthStencilTexture = textureView.texture
            let textureFormat = textureView.format
            hasStencilComponent = containsStencilAspect(textureFormat)
            hasDepthComponent = containsDepthAspect(textureFormat)
            let isDestroyed = textureView.isDestroyed
            if !isDestroyed {
                if textureWidth != 0
                    && (textureView.width != textureWidth || textureView.height != textureHeight
                        || sampleCount != textureView.sampleCount)
                {
                    return makeInvalidRenderPass("depth stencil texture dimensions mismatch")
                }
                if textureView.arrayLayerCount > 1 || textureView.mipLevelCount > 1 {
                    return makeInvalidRenderPass("depth stencil texture has more than one array layer or mip level")
                }
            }

            if !isRenderableDepthStencilTextureView(
                textureView,
                isDestroyed,
                hasDepthComponent,
                attachment.depthLoadOp,
                attachment.depthStoreOp,
                hasStencilComponent,
                attachment.stencilLoadOp,
                attachment.stencilStoreOp
            ) {
                return makeInvalidRenderPass("depth stencil texture is not renderable")
            }

            depthReadOnly = attachment.depthReadOnly
            if hasDepthComponent {
                // This is safe because the `depthAttachment` property is `null_resettable` in Objective C.
                // swift-format-ignore: NeverForceUnwrap
                let mtlAttachment = mtlDescriptor.depthAttachment!

                let clearDepth = quantizedDepthValue(Double(attachment.depthClearValue), textureView.format)
                    .clamped(to: 0...1)

                mtlAttachment.clearDepth = attachment.depthLoadOp == WebGPU.LoadOp.Clear ? clearDepth : 1.0
                mtlAttachment.texture = metalDepthStencilTexture
                mtlAttachment.level = 0
                mtlAttachment.loadAction = loadAction(loadOp: attachment.depthLoadOp, readOnly: attachment.depthReadOnly)
                mtlAttachment.storeAction = storeAction(storeOp: attachment.depthStoreOp)

                if mtlDescriptor.rasterizationRateMap != nil && metalDepthStencilTexture?.sampleCount ?? 1 > 1 {
                    if let depthTexture = deviceImpl.xrSubImageImpl?.currentDepthTextureReference?.texture() {
                        mtlAttachment.resolveTexture = depthTexture
                        mtlAttachment.storeAction = storeAction(storeOp: attachment.depthStoreOp, hasResolveTarget: true)
                        mtlAttachment.resolveSlice = Int(compositorTextureSlice)
                    }
                }
            }

            if !isDestroyed {
                if hasDepthComponent && !depthReadOnly {
                    if attachment.depthLoadOp == nil || attachment.depthStoreOp == nil {
                        return makeInvalidRenderPass("depth load and store op were not specified")
                    }
                } else if attachment.depthLoadOp != nil || attachment.depthStoreOp != nil {
                    return makeInvalidRenderPass("depth load and store op were specified")
                }
            }

            if attachment.depthLoadOp == WebGPU.LoadOp.Clear
                && (attachment.depthClearValue < 0 || attachment.depthClearValue > 1)
            {
                return makeInvalidRenderPass("depth clear value is invalid")
            }

            if zeroColorTargets {
                if isDestroyed {
                    return makeInvalidRenderPass("no color targets and depth-stencil texture is destroyed")
                }
                #if compiler(>=6.4)
                guard let metalDepthStencilTexture, metalDepthStencilTexture.sampleCount > 0 else {
                    return makeInvalidRenderPass("no color targets and depth-stencil texture is nil")
                }
                #else
                // FIXME: (rdar://170907318) Remove this branch once the minimum supported compiler is Swift 6.4.
                guard var metalDepthStencilTexture, metalDepthStencilTexture.sampleCount > 0 else {
                    return makeInvalidRenderPass("no color targets and depth-stencil texture is nil")
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
            let textureView = attachment.view.impl
            if hasStencilComponent {
                mtlAttachment.texture = textureView.texture
            }
            mtlAttachment.clearStencil = attachment.stencilClearValue
            mtlAttachment.loadAction = loadAction(loadOp: attachment.stencilLoadOp, readOnly: attachment.stencilReadOnly)
            mtlAttachment.storeAction = storeAction(storeOp: attachment.stencilStoreOp)
            let isDestroyed = textureView.isDestroyed
            if !isDestroyed {
                if hasStencilComponent && !stencilReadOnly {
                    if attachment.stencilLoadOp == nil || attachment.stencilStoreOp == nil {
                        return makeInvalidRenderPass("stencil load and store op were not specified")
                    }
                } else if attachment.stencilLoadOp != nil || attachment.stencilStoreOp != nil {
                    return makeInvalidRenderPass("stencil load and store op were specified")
                }
            }

            textureView.setCommandEncoder(self)
        }

        if zeroColorTargets && mtlDescriptor.renderTargetWidth == 0 {
            return makeInvalidRenderPass("zero color and depth targets")
        }

        var visibilityResultBufferSize: UInt = 0
        var visibilityResultBuffer: (any MTLBuffer)? = nil
        if let occlusionQuery = descriptor.occlusionQuerySet {
            occlusionQuery.setCommandEncoder(self)
            if occlusionQuery.queryType != WebGPU.QueryType.Occlusion {
                return makeInvalidRenderPass("querySet for occlusion query was not of type occlusion")
            }
            mtlDescriptor.visibilityResultBuffer = occlusionQuery.visibilityBuffer()
            visibilityResultBuffer = mtlDescriptor.visibilityResultBuffer
            visibilityResultBufferSize = occlusionQuery.isDestroyed() ? UInt.max : UInt(occlusionQuery.visibilityBuffer()?.length ?? 0)
        }

        if !deviceImpl.isValid() {
            return makeInvalidRenderPass("GPUDevice was invalid, this will be an error submitting the command buffer")
        }

        return createRenderPassEncoder(descriptor,
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
        _ descriptor: GPURenderPassDescriptor,
        _ visibilityResultBufferSize: UInt,
        _ depthReadOnly: Bool,
        _ stencilReadOnly: Bool,
        _ visibilityResultBuffer: (any MTLBuffer)?,
        _ maxDrawCount: UInt64,
        _ mtlDescriptor: MTLRenderPassDescriptor
    ) -> RenderPassEncoderImpl {
        var parameters = WebGPU.Metal.RenderPassEncoderParameters()
        parameters.visibilityResultBufferSize = visibilityResultBufferSize
        parameters.maxDrawCount = maxDrawCount
        parameters.depthReadOnly = depthReadOnly
        parameters.stencilReadOnly = stencilReadOnly
        let deferred = canDeferRenderCommandEncoder(mtlDescriptor)
        let renderPassEncoderImpl = makeRenderPassEncoderImpl(
            deferred ? nil : makeRenderCommandEncoder(mtlDescriptor),
            UInt64(deviceImpl.memoryBarrierLimit()) > maxDrawCount ? nil : mtlDescriptor,
            mtlDescriptor.rasterizationRateMap,
            visibilityResultBuffer,
            parameters,
            self
        )
        if deferred {
            renderPassEncoderImpl.deferRenderCommandEncoder(mtlDescriptor)
        }
        renderPassEncoderImpl.appendAttachments(descriptor)
        return renderPassEncoderImpl
    }

    // An invalid pass, which still locks this encoder.
    private func makeInvalidRenderPass(_ errorString: String) -> RenderPassEncoderImpl {
        makeInvalidRenderPassEncoderImpl(self, errorString as NSString)
    }

    // A pass begun while this encoder was not open never took the encoder over, so it can never be ended.
    // https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-end
    private func makeInvalidRenderPassWithEncoderStateNotOpen(_ errorString: String) -> RenderPassEncoderImpl {
        let pass = makeInvalidRenderPass(errorString)
        pass.markEncoderStateWasNotOpen()
        return pass
    }

    // An invalid pass, which still locks this encoder.
    private func makeInvalidComputePass(_ errorString: String) -> ComputePassEncoderImpl {
        makeInvalidComputePassEncoderImpl(self, errorString as NSString)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpucomputepassencoder-end
    private func makeInvalidComputePassWithEncoderStateNotOpen(_ errorString: String) -> ComputePassEncoderImpl {
        let pass = makeInvalidComputePass(errorString)
        pass.markEncoderStateWasNotOpen()
        return pass
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
        source: TextureCopyLocation,
        sourceTexture: TextureImpl,
        destination: BufferCopyLocation,
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
        source: BufferCopyLocation,
        sourceBuffer: BufferImpl,
        destination: TextureCopyLocation,
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
        source: BufferCopyLocation,
        apiBuffer: BufferImpl,
        destination: TextureCopyLocation,
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
        source: TextureCopyLocation,
        sourceTexture: TextureImpl,
        destination: TextureCopyLocation,
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
    private func noteFullWrites(_ texture: TextureImpl, _ destination: TextureCopyLocation, _ sliceCount: UInt32) {
        let isVolume = texture.backingDimension == WebGPU.TextureDimension._3d
        for layer in 0..<sliceCount {
            noteTextureInit(texture, destination.mipLevel, isVolume ? 0 : destination.origin.z &+ layer, destination.aspect, .fullWrite)
        }
    }

    fileprivate func beginComputePass(
        descriptor: GPUComputePassDescriptor,
        label: String?
    ) -> ComputePassEncoderImpl {
        let optionalTimestampWrites = descriptor.timestampWrites

        guard prepareTheEncoderState() else {
            self.generateInvalidEncoderStateError()
            // https://gpuweb.github.io/gpuweb/#dom-gpucomputepassencoder-end
            // A pass begun while the command encoder was already locked by another pass never took
            // the encoder over. Ending it is a validation error the page can catch, not a no-op.
            return makeInvalidComputePassWithEncoderStateNotOpen("encoder state is invalid")
        }

        if let error = self.errorValidatingComputePassDescriptor(descriptor: descriptor) {
            return makeInvalidComputePass(String(error))
        }

        if let commandBuffer = self.commandBuffer(), commandBuffer.status.rawValue >= MTLCommandBufferStatus.enqueued.rawValue {
            return makeInvalidComputePass("command buffer has already been committed")
        }

        self.finalizeBlitCommandEncoder()

        guard deviceImpl.isValid() else {
            return makeInvalidComputePass("GPUDevice was invalid, this will be an error submitting the command buffer")
        }
        let computePassDescriptor = MTLComputePassDescriptor()
        computePassDescriptor.dispatchType = .serial
        var counterSampleBuffer: (buffer: (any MTLCounterSampleBuffer)?, offset: UInt32) = (nil, 0)
        if let timestampWrites = optionalTimestampWrites {
            let timestampsWrites = timestampWrites.querySet
            counterSampleBuffer = (timestampsWrites.counterSampleBuffer(), timestampsWrites.counterSampleBufferOffset())
            timestampsWrites.setCommandEncoder(self)
        }

        if enableEncoderTimestamps() || counterSampleBuffer.buffer != nil {
            // FIXME: (rdar://170907276) Prove that `optionalTimestampWrites` can never be nil.
            // swift-format-ignore: NeverForceUnwrap
            let timestampWrites = optionalTimestampWrites!
            computePassDescriptor.sampleBufferAttachments[0].sampleBuffer =
                counterSampleBuffer.buffer ?? deviceImpl.timestampsBuffer(commandBuffer(), 2)

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
                deviceImpl.trackTimestampsBuffer(commandBuffer(), buffer)
            }
        }
        guard let computeCommandEncoder = commandBuffer()?.makeComputeCommandEncoder(descriptor: computePassDescriptor) else {
            return makeInvalidComputePass("computeCommandEncoder is null")
        }

        self.setExistingEncoder(computeCommandEncoder)
        computeCommandEncoder.label = label?.isEmpty == false ? label : nil

        return makeComputePassEncoderImpl(computeCommandEncoder, self)
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

/// The encoders that used a resource, each through its link.
///
/// Usually 1-3 entries. Entries of encoders that died are pruned lazily.
struct EncoderTracking {
    private struct Entry {
        /// The encoder's CommandEncoderImpl.serial: an entry with the serial of a live encoder is that encoder's, so
        /// matching needs no load of the link.
        let serial: UInt64
        let link: ImplLink<CommandEncoderImpl>

        var encoder: CommandEncoderImpl? {
            link.impl
        }
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
    /// Matches by serial, which unlike uniqueId is unique per process.
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
            entries.removeAll { $0.link.isEnded }
        }
        entries.append(Entry(serial: serial, link: encoder.link))
        return true
    }

    /// Matches the serial, as add() and contains() do.
    mutating func remove(_ encoder: CommandEncoderImpl) {
        let serial = encoder.serial
        entries.removeAll { $0.serial == serial }
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    /// Drops the encoders that died, then counts.
    mutating func liveCount() -> Int {
        entries.removeAll { $0.link.isEnded }
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

/// A buffer, and the encoder that invalidated it if any, without keeping either alive.
struct BufferAndEncoderLinks {
    let bufferLink: ImplLink<BufferImpl>
    let encoderLink: ImplLink<CommandEncoderImpl>?

    init(buffer: BufferImpl, encoder: CommandEncoderImpl?) {
        bufferLink = buffer.link
        encoderLink = encoder?.link
    }

    var buffer: BufferImpl? {
        bufferLink.impl
    }

    var encoder: CommandEncoderImpl? {
        encoderLink?.impl
    }
}

/// A commit action other than the constructor's, which runCommitActions runs first.
enum CommitAction {
    case indirectBufferInvalidated(BufferAndEncoderLinks)
    case rebindBundleSamplers(RenderBundleImpl)
}

/// The skipped draw-indexed validations of one buffer.
struct SkippedDrawIndexedValidation {
    let bufferLink: ImplLink<BufferImpl>
    var keys: [(key: DrawIndexKey, vertexCount: UInt32)]

    var buffer: BufferImpl? {
        bufferLink.impl
    }
}

/// An indexed indirect draw whose baked ICB slot was reused rather than re-encoded, retained until commit so its index
/// buffer can be revalidated if those indices changed after the slot was baked.
struct ReusedIndirectIndexedDraw: Equatable {
    let indirectBufferImpl: BufferImpl
    let indirectOffset: UInt64
    let indexBufferOffset: UInt64
    let indirectGeneration: UInt64
    let indexGeneration: UInt64
    let minVertexCount: CountBound
    let indexType: MTLIndexType
    let primitiveType: MTLPrimitiveType

    static func == (lhs: ReusedIndirectIndexedDraw, rhs: ReusedIndirectIndexedDraw) -> Bool {
        lhs.indirectBufferImpl === rhs.indirectBufferImpl && lhs.indirectOffset == rhs.indirectOffset
            && lhs.indexBufferOffset == rhs.indexBufferOffset && lhs.indirectGeneration == rhs.indirectGeneration
            && lhs.indexGeneration == rhs.indexGeneration && lhs.minVertexCount == rhs.minVertexCount
            && lhs.indexType == rhs.indexType && lhs.primitiveType == rhs.primitiveType
    }
}

/// The reused indirect indexed draws of one index buffer.
struct ReusedIndirectIndexedDraws {
    let bufferLink: ImplLink<BufferImpl>
    var draws: [ReusedIndirectIndexedDraw]

    var buffer: BufferImpl? {
        bufferLink.impl
    }
}

// One per GPUCommandEncoder, held by its Swift callers and the passes and command buffer it makes. Runs every WebGPU
// method; the copies, the passes, finish() and resolveQuerySet are in the extension above. A reported error can re-enter this object from the
// device's uncaptured-error callback.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_spi(WebKitGPU)
public final class CommandEncoderImpl: GPUObjectReference, LinkedImpl {
    private var linkSlot = ImplLinkSlot<CommandEncoderImpl>()
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
    /// Unique per device; invalid encoders take one from the same counter as valid ones, so that they never alias a live
    /// encoder.
    let uniqueId: UInt64
    /// Unique per process and never reused, unlike uniqueId and the object's address (EncoderTracking).
    let serial = commandEncoderSerials.wrappingAdd(1, ordering: .relaxed).newValue
    private(set) var state: EncoderState = .open

    // The buffers, textures, views and query sets this encoder used, held until clearTracking().
    private var trackedBuffers: [BufferImpl] = []
    private var trackedTextures: [TextureImpl] = []
    private var trackedTextureViews: [TextureViewImpl] = []
    private var trackedQuerySets: [QuerySetImpl] = []
    // The external textures that recorded this encoder in pendingUsers, and the planes it used, until clearTracking().
    // Not held, so that an external texture's Impl, which holds its Device, dies when its callers let go of it.
    private var trackedExternalTextures = ImplLinkList<ExternalTextureImpl>()
    private var retainedExternalTexturePlanes: [any MTLTexture] = []
    // One strong reference per distinct sampler, keyed by its Impl.
    private var retainedSamplers = WTFHashMap<UInt64, SamplerImpl>()
    // Appended on every draw and dispatch with a sampler-bearing group, never deduplicated.
    private var bindGroupsToRebind: [BindGroupImpl] = []
    // The skipped draw-indexed validations, keyed by the BufferImpl's identity.
    private var skippedDrawIndexedValidations = WTFHashMap<UInt64, SkippedDrawIndexedValidation>()
    // The reused indirect indexed draws of executeBundles, keyed by the index buffer's BufferImpl identity.
    private var reusedIndirectIndexedDraws = WTFHashMap<UInt64, ReusedIndirectIndexedDraws>()
    // Whether the constructor's commit action is still to run.
    private var constructorCommitActionPending: Bool
    // The other commit actions. After finish() they are the CommandBuffer's.
    private var commitActions: [CommitAction] = []
    // Set by finish(). Not held: the command buffer holds the encoder, and its last reference goes on the API thread.
    private var cachedCommandBufferLink: ImplLink<CommandBufferImpl>?
    private var cachedCommandBuffer: CommandBufferImpl? {
        get {
            cachedCommandBufferLink?.impl
        }
        set {
            cachedCommandBufferLink = newValue?.link
        }
    }
    // What this encoder did to lazily initialized texture regions. Moved into the CommandBuffer finish() makes, and
    // dropped with the encoder's work when that is discarded or made invalid.
    private var initializationLedger: InitializationLedger? = InitializationLedger()
    // Declared last, so that the device outlives the rest of the encoder.
    let deviceImpl: DeviceImpl

    // An invalid encoder: no command buffer and no sets.
    fileprivate init(deviceImpl: DeviceImpl) {
        self.deviceImpl = deviceImpl
        self.uniqueId = deviceImpl.takeCommandEncoderId()
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
        deviceImpl: DeviceImpl,
        shaderValidationEnabled: Bool,
        uniqueId: UInt64
    ) {
        self.backingCommandBuffer = commandBuffer
        self.deviceImpl = deviceImpl
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

    public func isValid() -> Bool {
        backingCommandBuffer != nil
    }

    func commandBuffer() -> (any MTLCommandBuffer)? {
        backingCommandBuffer
    }

    func blitCommandEncoder() -> (any MTLBlitCommandEncoder)? {
        backingBlitCommandEncoder
    }

    func setLastError(_ errorString: String?) {
        lastErrorString = errorString.map { $0 as NSString }
    }

    func timestampBuffers() -> NSMutableSet? {
        retainedTimestampBuffers
    }

    func submitWillBeInvalid() -> Bool {
        submitIsInvalid
    }

    // A nil error passes the last error to the command buffer.
    func makeSubmitInvalidWithError(_ errorString: NSString?) {
        submitIsInvalid = true
        cachedCommandBuffer?.makeInvalid(errorString ?? lastErrorString)
    }

    func makeSubmitInvalid(_ errorString: String?) {
        makeSubmitInvalidWithError(errorString.map { $0 as NSString })
    }

    func incrementBufferMapCount() {
        backingBufferMapCount &+= 1
        cachedCommandBuffer?.setBufferMapCount(backingBufferMapCount)
    }

    // Does nothing when the count is already zero.
    func decrementBufferMapCount() {
        if backingBufferMapCount <= 0 {
            return
        }
        backingBufferMapCount -= 1
        cachedCommandBuffer?.setBufferMapCount(backingBufferMapCount)
    }

    func setSharedEvent(_ event: (any MTLSharedEvent)?, _ signalValue: UInt64) {
        backingSharedEvent = event
        backingSharedEventSignalValue = signalValue
    }

    func clearSharedEvent() {
        backingSharedEvent = nil
    }

    func didCreateRenderCommandEncoder() {
        renderCommandEncoderCount &+= 1
    }

    // Unlike setExistingEncoder(nil), this does not tell the queue.
    func takeCommandBufferForFinish() -> (any MTLCommandBuffer)? {
        let commandBuffer = backingCommandBuffer
        backingCommandBuffer = nil
        existingCommandEncoder = nil
        return commandBuffer
    }

    // For the CommandBuffer finish() creates.
    func takePriorCommandBuffers() -> [any MTLCommandBuffer] {
        let commandBuffers = priorCommandBuffers
        priorCommandBuffers = []
        return commandBuffers
    }

    // MARK: Lazy zero-initialization

    func takeInitializationLedger() -> InitializationLedger? {
        initializationLedger.take()
    }

    private func dropInitializationLedger() {
        initializationLedger = nil
    }

    /// Records how a copy uses one subresource of `texture`, zero-filling it first where it has to.
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
    func noteAttachment(_ texture: TextureImpl, _ region: InitRegion, _ plan: AttachmentInitPlan) {
        initializationLedger?.noteAttachment(texture, region, plan)
    }

    /// encoderIsCurrent(encoder) for a non-nil encoder, without passing (and so retaining) it.
    func isCurrentEncoder(_ encoder: ObjectIdentifier) -> Bool {
        guard deviceImpl.isValid(), let existing = existingCommandEncoder else {
            return false
        }
        return ObjectIdentifier(existing) == encoder
    }

    func encoderIsCurrent(_ commandEncoder: (any MTLCommandEncoder)?) -> Bool {
        deviceImpl.isValid() && existingCommandEncoder === commandEncoder
    }

    func setExistingEncoder(_ encoder: (any MTLCommandEncoder)?) {
        assert(existingCommandEncoder == nil || encoder == nil)
        existingCommandEncoder = encoder
        deviceImpl.defaultQueueImpl.setEncoderForBuffer(backingCommandBuffer, encoder)
    }

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

        if !deviceImpl.isValid() {
            return nil
        }

        let descriptor = MTLBlitPassDescriptor()
        let blitCommandEncoder = backingCommandBuffer?.makeBlitCommandEncoder(descriptor: descriptor)
        backingBlitCommandEncoder = blitCommandEncoder
        setExistingEncoder(blitCommandEncoder)

        return blitCommandEncoder
    }

    func finalizeBlitCommandEncoder() {
        let blitCommandEncoder = backingBlitCommandEncoder
        if !encoderIsCurrent(blitCommandEncoder) {
            return
        }

        endEncoding(blitCommandEncoder)
        backingBlitCommandEncoder = nil
        setExistingEncoder(nil)
    }

    func endEncoding(_ encoder: (any MTLCommandEncoder)?) {
        let existingEncoder = deviceImpl.defaultQueueImpl.encoderForBuffer(backingCommandBuffer)
        if existingEncoder !== encoder {
            deviceImpl.defaultQueueImpl.endEncoding(existingEncoder, backingCommandBuffer)
            setExistingEncoder(nil)
            if lastErrorString != nil {
                discardCommandBuffer()
            }
            return
        }

        deviceImpl.defaultQueueImpl.endEncoding(existingCommandEncoder, backingCommandBuffer)
        setExistingEncoder(nil)
        backingBlitCommandEncoder = nil
        if lastErrorString != nil {
            discardCommandBuffer()
        }
    }

    func discardCommandBuffer() {
        dropInitializationLedger()
        releasePriorCommandBuffers()

        if backingCommandBuffer == nil || commandBufferStatus() >= MTLCommandBufferStatus.committed.rawValue {
            retainTimestampsForOneUpdateLoop()
            backingCommandBuffer = nil
            return
        }

        let existingEncoder = deviceImpl.defaultQueueImpl.encoderForBuffer(backingCommandBuffer)
        deviceImpl.defaultQueueImpl.endEncoding(existingEncoder, backingCommandBuffer)
        deviceImpl.defaultQueueImpl.removeMTLCommandBuffer(backingCommandBuffer)
        retainTimestampsForOneUpdateLoop()
        backingCommandBuffer = nil
    }

    private func releasePriorCommandBuffers() {
        let commandBuffers = priorCommandBuffers
        priorCommandBuffers = []
        for commandBuffer in commandBuffers {
            deviceImpl.defaultQueueImpl.removeMTLCommandBuffer(commandBuffer)
        }
    }

    private func retainTimestampsForOneUpdateLoop() {
        // Workaround for rdar://143905417
        deviceImpl.defaultQueueImpl.retainTimestampsForOneUpdate(retainedTimestampBuffers)
    }

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

        guard let nextCommandBuffer = deviceImpl.defaultQueueImpl.commandBufferWithDescriptor(MTLCommandBufferDescriptor()) else {
            return
        }

        nextCommandBuffer.label = commandBuffer.label
        priorCommandBuffers.append(commandBuffer)
        backingCommandBuffer = nextCommandBuffer
        renderCommandEncoderCount = 0
    }

    func makeRenderCommandEncoder(_ descriptor: MTLRenderPassDescriptor?) -> (any MTLRenderCommandEncoder)? {
        assert(existingCommandEncoder == nil)
        guard let descriptor, let renderCommandEncoder = backingCommandBuffer?.makeRenderCommandEncoder(descriptor: descriptor) else {
            return nil
        }

        setExistingEncoder(renderCommandEncoder)
        didCreateRenderCommandEncoder()
        return renderCommandEncoder
    }

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
    @discardableResult
    func makeInvalid(_ errorString: NSString?) -> Bool {
        if backingCommandBuffer == nil || commandBufferStatus() >= MTLCommandBufferStatus.committed.rawValue {
            return false
        }

        endEncoding(existingCommandEncoder)
        backingBlitCommandEncoder = nil
        existingCommandEncoder = nil
        releasePriorCommandBuffers()
        deviceImpl.defaultQueueImpl.removeMTLCommandBuffer(backingCommandBuffer)

        backingCommandBuffer = nil
        dropInitializationLedger()
        lastErrorString = errorString
        cachedCommandBuffer?.makeInvalid(errorString)
        return true
    }

    func addICB(_ icb: (any MTLIndirectCommandBuffer)?) {
        guard let icb else {
            return
        }
        retainedICBs?.add(icb)
    }

    func addCounterSampleBuffer(_ buffer: (any MTLCounterSampleBuffer)?) {
        guard let buffer else {
            return
        }
        retainedTimestampBuffers?.add(buffer)
    }

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

    /// Whether addResidentResource(_:) keeps anything, which it does only with shader validation.
    var retainsResidentResources: Bool {
        retainedTextures != nil || retainedBuffers != nil
    }

    /// Keeps a bind group's or bundle's resource alive with the command buffer.
    func addResidentResource(_ resource: any MTLResource) {
        if !retainsResidentResources {
            return
        }
        if let texture = resource as? any MTLTexture {
            addTexture(texture)
        } else if let buffer = resource as? any MTLBuffer {
            addBuffer(buffer)
        }
    }

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
    func generateInvalidEncoderStateError() {
        generateInvalidEncoderStateError(
            endedMessage: "void WebGPU::Metal::CommandEncoder::generateInvalidEncoderStateError(): encoder state is Ended"
        )
    }

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

    @_spi(WebKitGPU)
    public func popDebugGroup() {
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

    @_spi(WebKitGPU)
    public func writeTimestamp(_ querySet: QuerySetImpl, _ queryIndex: UInt32) {
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

    @_spi(WebKitGPU)
    public func copyBufferToBuffer(
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

    @_spi(WebKitGPU)
    public func resolveQuerySet(
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

    func setLabel(_ label: NSString) {
        backingCommandBuffer?.label = label as String
    }

    var link: ImplLink<CommandEncoderImpl> {
        linkSlot.link(for: self)
    }

    deinit {
        linkSlot.end()
        finalizeBlitCommandEncoder()
        releasePriorCommandBuffers()
        deviceImpl.defaultQueueImpl.removeMTLCommandBuffer(backingCommandBuffer)
        retainTimestampsForOneUpdateLoop()
        backingCommandBuffer = nil // Do not remove, this is needed to workaround rdar://143905417
        dropInitializationLedger()
        clearTracking()
    }

    // `body` runs on the API thread once this encoder's command buffer completed, with whether it completed without an
    // error. Until then, the queue keeps the encoder's counter sample buffers and the work keeps the device.
    func onCommandBufferCompletion(_ body: @escaping (Bool) -> Void) {
        let deviceImpl = self.deviceImpl
        let queueImpl = deviceImpl.defaultQueueImpl
        let encoderHandle = queueImpl.retainCounterSampleBuffers(self)
        let completion = APIThreadWork<Bool> { completed in
            queueImpl.releaseCounterSampleBuffers(encoderHandle)
            withExtendedLifetime(deviceImpl) {
                body(completed)
            }
        }
        let scheduler = deviceImpl.schedulerHandle()
        commandBuffer()?.addCompletedHandler { completedCommandBuffer in
            completion.schedule(completedCommandBuffer.status == .completed, on: scheduler)
        }
    }

    // MARK: Encoder state

    func isLocked() -> Bool {
        state == .locked
    }

    func isFinished() -> Bool {
        state == .ended
    }

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-prepare-the-encoder-state
    func prepareTheEncoderState() -> Bool {
        state == .open
    }

    func setEncoderStateEnded() {
        state = .ended
    }

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

    // Texture::waitForCommandBufferCompletion's per-encoder part.
    func waitForCommandBufferCompletion() -> Bool {
        guard let commandBuffer = cachedCommandBuffer else {
            return true
        }
        let completed = commandBuffer.waitForCompletion()
        let gpuExecutionDurationSeconds = commandBuffer.gpuExecutionDurationSeconds()
        if gpuExecutionDurationSeconds != 0 {
            recordGPUExecutionWindowOnCanvasTextures(0, gpuExecutionDurationSeconds)
        }
        return completed
    }

    func recordGPUExecutionWindowOnCanvasTextures(_ startTime: Double, _ endTime: Double) {
        let textures = trackedTextures
        for texture in textures where texture.isCanvasBacking() {
            texture.recordGPUExecutionWindow(startTime, endTime)
        }
    }

    // MARK: Resource tracking

    // For a buffer that newly recorded this encoder.
    func trackBuffer(_ impl: BufferImpl) {
        trackedBuffers.append(impl)
    }

    func trackTexture(_ impl: TextureImpl) {
        trackedTextures.append(impl)
    }

    func trackTextureView(_ impl: TextureViewImpl) {
        trackedTextureViews.append(impl)
    }

    func trackQuerySet(_ impl: QuerySetImpl) {
        trackedQuerySets.append(impl)
    }

    func trackExternalTexture(_ impl: ExternalTextureImpl) {
        trackedExternalTextures.add(impl)
    }

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
    func clearTracking() {
        let buffers = trackedBuffers
        let textures = trackedTextures
        let textureViews = trackedTextureViews
        let querySets = trackedQuerySets
        let externalTextures = trackedExternalTextures.values
        let planes = retainedExternalTexturePlanes
        trackedBuffers = []
        trackedTextures = []
        trackedTextureViews = []
        trackedQuerySets = []
        trackedExternalTextures.removeAll()
        retainedExternalTexturePlanes = []
        for impl in buffers {
            impl.tracking.remove(self)
        }
        for impl in textures {
            impl.tracking.remove(self)
        }
        for impl in textureViews {
            impl.tracking.remove(self)
        }
        for impl in querySets {
            impl.tracking.remove(self)
        }
        for impl in externalTextures {
            impl.pendingUsers.remove(self)
        }
        withExtendedLifetime((buffers, textures, textureViews, querySets, externalTextures, planes)) {}
    }

    func addSampler(_ sampler: SamplerImpl) {
        retainedSamplers.add(identityKey(ObjectIdentifier(sampler))) { sampler }
    }

    func rebindSamplersPreCommit(_ group: BindGroupImpl) {
        bindGroupsToRebind.append(group)
    }

    // `vertexCount` is the cached entry's.
    func recordSkippedDrawIndexedValidation(_ buffer: BufferImpl, _ key: DrawIndexKey, vertexCount: UInt32) {
        let identity = identityKey(ObjectIdentifier(buffer))
        let bufferLink = buffer.link
        // The first skip starts the buffer's list. An entry's link keeps its buffer's address, so no other buffer has
        // the same key while it exists.
        if skippedDrawIndexedValidations.value(forKey: identity)?.bufferLink !== bufferLink {
            skippedDrawIndexedValidations.set(identity, SkippedDrawIndexedValidation(bufferLink: bufferLink, keys: []))
        }
        skippedDrawIndexedValidations.modifyValue(forKey: identity) { skipped in
            skipped.keys.append((key: key, vertexCount: vertexCount))
        }
    }

    func recordReusedIndirectIndexedDraw(_ buffer: BufferImpl, _ draw: ReusedIndirectIndexedDraw) {
        let identity = identityKey(ObjectIdentifier(buffer))
        let bufferLink = buffer.link
        // As recordSkippedDrawIndexedValidation.
        if reusedIndirectIndexedDraws.value(forKey: identity)?.bufferLink !== bufferLink {
            reusedIndirectIndexedDraws.set(identity, ReusedIndirectIndexedDraws(bufferLink: bufferLink, draws: []))
        }
        reusedIndirectIndexedDraws.modifyValue(forKey: identity) { reused in
            if !reused.draws.contains(draw) {
                reused.draws.append(draw)
            }
        }
    }

    // MARK: Commit actions

    // Dropped when the encoder is invalid, which it is from finish() on.
    func addCommitAction(_ action: consuming CommitAction) {
        if !isValid() {
            return
        }
        commitActions.append(action)
    }

    // Runs the constructor's action (the skipped index validations, then the sampler rebinds), then the other actions in
    // order, and clears them. Every action runs even after a false.
    func runCommitActions(_ commandBufferImpl: CommandBufferImpl) -> Bool {
        var result = true
        if constructorCommitActionPending {
            constructorCommitActionPending = false
            runSkippedDrawIndexedValidations(commandBufferImpl)
            runReusedIndirectIndexedDrawValidations(commandBufferImpl)
            let groups = bindGroupsToRebind
            for group in groups {
                _ = group.rebindSamplersIfNeeded()
            }
        }

        let actions = commitActions
        commitActions = []
        for action in actions {
            switch action {
            case .indirectBufferInvalidated(let pair):
                if let buffer = pair.buffer, let encoder = pair.encoder {
                    buffer.indirectBufferInvalidatedAtCommit(by: encoder)
                }
            case .rebindBundleSamplers(let bundleImpl):
                result = bundleImpl.rebindSamplersIfNeeded() && result
            }
        }
        withExtendedLifetime(actions) {}
        return result
    }

    // CommandBuffer::clearCommitHandlers and the CommandBuffer's destruction, for the handlers it had taken.
    func clearCommitActions() {
        constructorCommitActionPending = false
        let actions = commitActions
        commitActions = []
        withExtendedLifetime(actions) {}
    }

    // The constructor's action's first walk, in WTF::HashMap order. A buffer destroyed since is skipped.
    private func runSkippedDrawIndexedValidations(_ commandBufferImpl: CommandBufferImpl) {
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
                    .clearMustTakeSlowIndexValidationPath(commandBufferImpl.deviceImpl, BufferAndEncoderLinks(buffer: buffer, encoder: nil))
                )
            }
        }
    }

    // The constructor's action's second walk, in WTF::HashMap order: the reused draws whose index buffer's contents
    // changed since their slot was baked. A buffer destroyed since is skipped.
    private func runReusedIndirectIndexedDrawValidations(_ commandBufferImpl: CommandBufferImpl) {
        let reusedDraws = reusedIndirectIndexedDraws
        reusedDraws.forEachInWTFOrder { _, reused in
            guard let buffer = reused.buffer, !buffer.isDestroyed() else {
                return
            }
            for draw in reused.draws where draw.indexGeneration != buffer.indexContentsGeneration() {
                buffer.takeSlowBundleIndirectDrawValidationPath(commandBufferImpl, draw)
            }
        }
    }
}

func makeCommandEncoderImpl(
    _ commandBuffer: (any MTLCommandBuffer)?,
    _ deviceImpl: DeviceImpl,
    _ shaderValidationEnabled: Bool,
    _ uniqueId: UInt64
) -> CommandEncoderImpl {
    CommandEncoderImpl(
        commandBuffer: commandBuffer,
        deviceImpl: deviceImpl,
        shaderValidationEnabled: shaderValidationEnabled,
        uniqueId: uniqueId
    )
}

func makeInvalidCommandEncoderImpl(_ deviceImpl: DeviceImpl) -> CommandEncoderImpl {
    CommandEncoderImpl(deviceImpl: deviceImpl)
}
