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
import WebGPU_Internal.BindGroup
import WebGPU_Internal.Buffer
import WebGPU_Internal.CommandEncoder
import WebGPU_Internal.Device
import WebGPU_Internal.PipelineLayout
import WebGPU_Internal.RenderBundle
import WebGPU_Internal.RenderBundleEncoder
import WebGPU_Internal.RenderPassEncoder
import WebGPU_Internal.RenderPipeline
import WebGPU_Internal.Texture
import WebGPU_Internal.TextureView
import WebGPU_Private.WebGPUCpp

// MARK: Indirect draws: the only arguments Metal's indirect draws take are clamped ones

/// The app's indirect arguments, the only form in which the clamp encoders take them.
///
/// `argumentsSize` bytes inside the MTLBuffer the GPU reads, of a buffer that is not destroyed, at an offset the 32-bit
/// binding helpers keep exactly. Callers have validated the range against the buffer's size; this is the check the GPU
/// read relies on, including for offsets a bundle recorded.
struct IndirectArgumentsRange {
    fileprivate let buffer: any MTLBuffer
    fileprivate let metalOffset: UInt32

    init?(_ indirectBuffer: borrowing BufferImpl, offset: UInt64, argumentsSize: Int) {
        guard !indirectBuffer.isDestroyed(), let buffer = indirectBuffer.buffer(), offset % 4 == 0,
            case (let end, false) = offset.addingReportingOverflow(UInt64(argumentsSize)), end <= UInt64(buffer.length),
            let metalOffset = UInt32(exactly: offset)
        else {
            return nil
        }
        self.buffer = buffer
        self.metalOffset = metalOffset
    }
}

/// Indirect arguments in per-draw scratch that a clamp kernel (vsIndirect, vsIndexedIndirect) writes in this command
/// buffer before the draw reads them.
///
/// Made only by the clamp encoders in this file, and the only arguments the Metal indirect draws below take.
struct ClampedIndirectArguments {
    fileprivate let buffer: any MTLBuffer
    /// Readable anywhere: an offset alone draws nothing.
    let offset: UInt64

    fileprivate init(_ buffer: any MTLBuffer, _ offset: UInt64) {
        self.buffer = buffer
        self.offset = offset
    }

    // Whether `size` bytes of arguments at `offset` are inside the scratch buffer.
    fileprivate func fits(_ size: UInt64) -> Bool {
        let (end, overflowed) = offset.addingReportingOverflow(size)
        return !overflowed && end <= UInt64(buffer.length)
    }
}

/// clampIndexBufferToValidValues' result.
enum IndexBufferClamp {
    /// Nothing may be drawn.
    case skip
    /// The draw's indices are known to be in range: a direct draw.
    case draw
    /// The draw reads its arguments from what the index clamp wrote; nil when their scratch could not be allocated,
    /// and then nothing is drawn.
    case indirectDraw(ClampedIndirectArguments?)
}

extension MTLRenderCommandEncoder {
    func drawPrimitives(_ primitiveType: MTLPrimitiveType, clamped arguments: ClampedIndirectArguments) {
        drawPrimitives(
            type: primitiveType,
            indirectBuffer: arguments.buffer,
            indirectBufferOffset: Int(truncatingIfNeeded: arguments.offset)
        )
    }

    func drawIndexedPrimitives(
        _ primitiveType: MTLPrimitiveType,
        indexType: MTLIndexType,
        indexBuffer: any MTLBuffer,
        indexBufferOffset: Int,
        clamped arguments: ClampedIndirectArguments
    ) {
        drawIndexedPrimitives(
            type: primitiveType,
            indexType: indexType,
            indexBuffer: indexBuffer,
            indexBufferOffset: indexBufferOffset,
            indirectBuffer: arguments.buffer,
            indirectBufferOffset: Int(truncatingIfNeeded: arguments.offset)
        )
    }
}

/// The fragment dynamic offsets start after minDepth, maxDepth and the sample mask.
private let startIndexForFragmentDynamicOffsets = 3

/// The size of the vertex-buffer tables.
private let maxBufferSlots = 31

/// What was last bound at a buffer index.
private struct ExistingBufferKey: Equatable {
    var gpuAddress: UInt64 = 0
    var offset: UInt32 = 0
}

/// An ExistingBufferKey per buffer index below maxBufferSlots, in inline storage, so that every access is a plain load
/// or store with no runtime exclusivity check.
///
/// A 0 address is both "unknown" and "no buffer", so the slots known to hold no buffer are kept apart: a nil binding is
/// sent once.
private struct ExistingBufferCache {
    private var gpuAddresses = SIMD32<UInt64>()
    private var offsets = SIMD32<UInt32>()
    private var nilSlots: UInt32 = 0

    subscript(slot: MetalBufferSlot) -> ExistingBufferKey {
        get {
            ExistingBufferKey(gpuAddress: gpuAddresses[slot.index], offset: offsets[slot.index])
        }
        set {
            gpuAddresses[slot.index] = newValue.gpuAddress
            offsets[slot.index] = newValue.offset
            nilSlots &= ~(UInt32(1) << UInt32(slot.index))
        }
    }

    /// Whether the encoder may hold something other than `key` at `slot`.
    func needsBinding(_ slot: MetalBufferSlot, _ key: ExistingBufferKey) -> Bool {
        if key.gpuAddress == 0 {
            #if arch(x86_64)
            return true
            #else
            return nilSlots & (UInt32(1) << UInt32(slot.index)) == 0 || self[slot] != key
            #endif
        }
        return self[slot] != key
    }

    mutating func recordBinding(_ slot: MetalBufferSlot, _ key: ExistingBufferKey) {
        self[slot] = key
        if key.gpuAddress == 0 {
            nilSlots |= UInt32(1) << UInt32(slot.index)
        }
    }

    /// The dynamic offsets were just sent to `slot`: no buffer binding there is known.
    mutating func forget(_ slot: DynamicOffsetsSlot) {
        gpuAddresses[slot.index] = 0
        offsets[slot.index] = 0
        nilSlots &= ~(UInt32(1) << UInt32(slot.index))
    }

    mutating func removeAll() {
        self = ExistingBufferCache()
    }
}

/// The raster states a draw sets from its pipeline, compared bit for bit.
private struct DrawRasterState: Equatable {
    var cullMode: UInt = 0
    var frontFace: UInt = 0
    var depthClipMode: UInt = 0
    var depthBias: UInt32 = 0
    var depthBiasSlopeScale: UInt32 = 0
    var depthBiasClamp: UInt32 = 0
}

/// What executePreDrawCommands last gave the current render command encoder, so that a steady draw re-sends only what
/// changed (Metal keeps encoder state until it is changed).
///
/// RenderPassEncoderImpl.drawStateObjects keeps the identified objects alive, so an identity cannot be reused by a new
/// object. Reset by a new encoder and by every other writer of these states: the clamps' pipeline states and bundle
/// replay.
private struct DrawStateCache {
    var pipelineState: ObjectIdentifier?
    var depthStencilState: ObjectIdentifier?
    var raster: DrawRasterState?
}

/// A vertex buffer binding, with the MTLBuffer's length and gpuAddress read once when it is bound: a bound MTLBuffer
/// never changes either.
private struct VertexBufferBinding {
    var buffer: (any MTLBuffer)?
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var length: UInt64 = 0
    var gpuAddress: UInt64 = 0

    init() {
    }

    init(buffer: (any MTLBuffer)?, offset: UInt64, size: UInt64) {
        self.buffer = buffer
        self.offset = offset
        self.size = size
        length = UInt64(buffer?.length ?? 0)
        gpuAddress = buffer?.gpuAddress ?? 0
    }
}

/// The key of a texture subresource's usage: the parent texture's identity and entryMapKey, for lookups only.
private struct TextureSubresourceKey: WTFHashKey {
    let texture: UInt64
    let entry: UInt64

    var wtfHash: UInt32 {
        wtfIntHash(texture) ^ (wtfIntHash(entry) &* 31)
    }
}

private func entryMapKey(_ mipLevel: UInt32, _ arrayLayer: UInt32, _ aspect: WebGPU.TextureAspect) -> UInt64 {
    precondition(aspect != .All)
    let aspectBit: UInt64 = aspect == .DepthOnly ? 1 : 0
    return aspectBit | UInt64(mipLevel) << 1 | UInt64(arrayLayer) << 32
}

/// The Impl half of an attachment (TextureOrTextureView), for the logic that never needs the shell.
private enum AttachmentImpl {
    case texture(TextureImpl)
    case textureView(TextureViewImpl)

    var isDestroyed: Bool {
        switch self {
        case .texture(let impl): impl.isDestroyed()
        case .textureView(let impl): impl.isDestroyed()
        }
    }

    var sampleCount: UInt32 {
        switch self {
        case .texture(let impl): impl.sampleCount()
        case .textureView(let impl): impl.sampleCount()
        }
    }

    var width: UInt32 {
        switch self {
        case .texture(let impl): impl.width()
        case .textureView(let impl): impl.width()
        }
    }

    var format: WebGPU.TextureFormat {
        switch self {
        case .texture(let impl): impl.formatOrDefault
        case .textureView(let impl): impl.formatOrDefault
        }
    }

    var texture: (any MTLTexture)? {
        switch self {
        case .texture(let impl): impl.texture()
        case .textureView(let impl): impl.texture()
        }
    }

    /// The texture itself, or the view's parent.
    var parentTexture: TextureImpl {
        switch self {
        case .texture(let impl): impl
        case .textureView(let impl): impl.parentTextureImpl
        }
    }

    var subresources: (baseMipLevel: UInt32, mipLevelCount: UInt32, baseArrayLayer: UInt32, arrayLayerCount: UInt32) {
        switch self {
        case .texture(let impl): (0, impl.mipLevelCount(), 0, impl.arrayLayerCount())
        case .textureView(let impl): (impl.baseMipLevel(), impl.mipLevelCount(), impl.baseArrayLayer(), impl.arrayLayerCount())
        }
    }

    /// The regions of the attached subresource that `aspect` selects; .All selects every aspect of the attachment.
    func initRegions(aspect: WebGPU.TextureAspect) -> InitRegions {
        switch self {
        case .texture(let impl): impl.initRegions(mipLevel: 0, layer: 0, aspect: aspect)
        case .textureView(let impl): impl.initRegions(selecting: aspect)
        }
    }

    /// A 3D attachment writes one depth plane of a mip level that is initialized as a whole.
    var isVolume: Bool {
        parentTexture.backingDimension == ._3d
    }

    /// Memoryless: never stored, so never zero-filled.
    var isTransient: Bool {
        parentTexture.isTransient
    }

    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        switch self {
        case .texture(let impl): impl.setCommandEncoder(encoder)
        case .textureView(let impl): impl.setCommandEncoder(encoder)
        }
    }
}

/// The scratch records of the clamping indirect draws, whose lostOrOOBRead flag one completion handler per pass checks.
///
/// registerIndirectDeviceLostChecks captures this object in a block that only runs, and is released, on the API thread
/// (the Metal thread only retains it), so it is deliberately not Sendable.
private final class IndirectDeviceLostChecks {
    var entries: [(scratch: any MTLBuffer, offset: UInt64, alsoRetain: (any MTLBuffer)?)] = []

    func takeLostOrOOBRead() -> Bool {
        defer {
            entries = []
        }
        for entry in entries where WebGPU.Metal.drawIndirectArgumentsLostOrOOBRead(entry.scratch, entry.offset) {
            return true
        }
        return false
    }
}

/// One indirect draw of a bundle that executeBundles GPU-encodes into its ICB slot (IndirectEncodeWork).
private struct IndirectEncodeWork {
    let icb: BundleICB
    let slotIndex: UInt64
    let indirectBuffer: BufferImpl
    let indexBuffer: BufferImpl?
    let indirectOffset: UInt64
    let bounds: VertexInstanceBounds
    let indexType: MTLIndexType
    let indexBufferOffset: UInt
    let primitiveType: MTLPrimitiveType
    let isIndexed: Bool
    let indirectGeneration: UInt64
    let indexGeneration: UInt64
    /// Indexed draws: the clamp's second dispatch also checks every index value (VertexInstanceBounds.clampsIndexValues).
    let clampsIndexValues: Bool
    /// The final scratch: the arguments the ICB encode reads.
    var clamped: ClampedIndirectArguments?
    /// Indexed draws: the thread count of the second dispatch, which dispatch 1 writes.
    var intermediate: ClampedIndirectArguments?
    var indexBufferCount: UInt32 = 0
}

// One per GPURenderPassEncoder, owned by the C++ shell WebGPU::Metal::RenderPassEncoder through an opaque box. Owns all
// of the pass's state, runs the logic of every WebGPU::RenderPassEncoder method and reports its errors. The shell hands
// in the attachments and the bundles of executeBundles, whose shells Swift cannot downcast.
// The Metal completion handlers of the clamps are registered by C++ helpers in RenderPassEncoder.mm.
//
// Bundle replay re-enters this object, splitRenderPass re-enters setPipeline, and a reported error can re-enter it
// from the device's uncaptured-error callback, so no method holds an access to a stored property across such a call.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_expose(Cxx)
final class RenderPassEncoderImpl {
    // nil while the pass is deferred, and once it is invalid, has ended or no longer holds its command
    // encoder's current encoder.
    private var backingRenderCommandEncoder: (any MTLRenderCommandEncoder)?
    // Non-nil only while the pass is deferred: cleared when the encoder is materialized, when the pass ends
    // and when the pass is invalidated.
    private var deferredDescriptor: MTLRenderPassDescriptor?
    private let parentEncoder: WebGPU.Metal.CommandEncoder
    @_expose(!Cxx)
    let parentImpl: CommandEncoderImpl
    private let deviceImpl: DeviceImpl
    private let limits: EncoderLimits
    private let maxVerticesPerDrawCall: UInt32
    // What splitRenderPass makes the replacement encoder from. nil when the device's memory barrier limit
    // exceeds the pass's maximum draw count.
    private let metalDescriptor: MTLRenderPassDescriptor?
    private let rasterizationRateMap: (any MTLRasterizationRateMap)?
    private let visibilityResultBuffer: (any MTLBuffer)?
    // UInt.max when the occlusion query set had been destroyed.
    private let visibilityResultBufferSize: UInt
    private let maxDrawCount: UInt64
    // Zero or one element, the shell of currentPipelineImpl; an Array rather than an Optional FRT.
    private var currentPipeline: [WebGPU.Metal.RenderPipeline] = []
    private var currentPipelineImpl: RenderPipelineImpl?
    // Kept for the lifetime of the pass rather than cleared once applied: every draw reads the depth range back
    // out to tell the fragment shader what to clamp frag_depth to, and splitting the pass reapplies it.
    private var viewport: MTLViewport?
    private var viewportNeedsApplying = false
    private var scissorRect: MTLScissorRect?
    private var blendColor: WebGPU.Color?
    private var stencilReferenceValue: UInt32?
    private var occlusionQueryActive = false
    private var visibilityResultBufferOffset: UInt = 0
    // Byte offsets into the visibility result buffer. endPass zeroes those no draw wrote; the order it does so
    // in is unobservable.
    private var queryBufferIndicesToClear = Set<UInt64>()
    /// queryBufferIndicesToClear.count, so that a draw outside occlusion queries does not touch the set.
    private var queryBufferIndicesToClearCount = 0
    private var queryBufferUtilizedIndices = Set<UInt64>()
    private var drawCount: UInt64 = 0
    private var indexType: MTLIndexType = .uint16
    private var indexBufferOffset: UInt = 0
    private var indexBufferSize: UInt = 0
    private var maxVertexBufferSlot: UInt32 = 0
    private var debugGroupStackSize: UInt64 = 0
    private var lastErrorString: String?
    private var passEnded = false
    // A pass begun while its command encoder was not open never took the encoder over, so it can
    // never be ended. https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-end
    private var encoderStateWasNotOpen = false

    private var attachments = PassAttachments()
    // The color attachment between appendColorAttachment* and endColorAttachment.
    private var pendingColorAttachment: AttachmentImpl?
    private var renderTargetWidth: UInt32 = 0
    private var renderTargetHeight: UInt32 = 0
    private var rasterSampleCount: UInt32 = 1
    // Color attachment slot -> the attachment that endPass clears with CommandEncoder.runClearEncoder.
    private var attachmentsToClear: [Int: TextureAndClearColor] = [:]
    private var depthStencilAttachmentToClear: (any MTLTexture)?
    private var depthClearValue: Float = 0
    private var stencilClearValue: UInt32 = 0
    private var clearDepthAttachment = false
    private var clearStencilAttachment = false

    private var bindGroups = BindGroupTable()
    private var bindGroupDynamicOffsets = GroupIndexedTable<[UInt32]>()
    /// identityKey of the Impl at each index of `bindGroups` (0 for none) and the indices with an entry in
    /// `bindGroupDynamicOffsets`, kept in step with them, so that setting a group's own bind group again without dynamic
    /// offsets reads neither table (both hold class references, so every access to them is checked at run time).
    private var boundGroupIdentities = SIMD32<UInt64>()
    private var groupsWithDynamicOffsets: UInt32 = 0
    // Bit i for group i, below maxBindGroups.
    private var bindGroupDynamicOffsetsChanged: UInt32 = 0
    private let allBindGroupsMask: UInt32
    private var maxDynamicOffsetAtIndex = SIMD32<UInt32>()
    private var maxBindGroupSlot: UInt32 = 0
    // ContiguousArrays for their back-deployed span.
    private var vertexDynamicOffsets: ContiguousArray<UInt32> = []
    private var priorVertexDynamicOffsets: ContiguousArray<UInt32> = []
    private var fragmentDynamicOffsets: ContiguousArray<UInt32> = []
    private var priorFragmentDynamicOffsets: ContiguousArray<UInt32> = []
    private var vertexBuffers = [VertexBufferBinding](repeating: VertexBufferBinding(), count: maxBufferSlots)
    private var existingVertexBuffers = ExistingBufferCache()
    private var existingFragmentBuffers = ExistingBufferCache()
    private var drawState = DrawStateCache()
    private var drawStateObjects: (pipelineState: (any MTLRenderPipelineState)?, depthStencilState: (any MTLDepthStencilState)?) = (
        nil, nil
    )
    private var ignoreBufferCache = false
    // Zero or one element, with its Impl.
    private var indexBuffer: [WebGPU.Metal.Buffer] = []
    private var indexBufferImpl: BufferImpl?
    // The usages of buffers and external textures (keyed by Impl identity), and of texture subresources.
    private var usagesForBuffer = WTFHashMap<UInt64, EntryUsage>()
    private var usagesForTexture = WTFHashMap<TextureSubresourceKey, EntryUsage>()
    private var memoryBarrierCount: UInt32 = 0
    private var indirectDeviceLostChecks: IndirectDeviceLostChecks?
    // The bundles of the executeBundles call in progress, appended by the shell just before it.
    private var pendingBundles: [(shell: WebGPU.Metal.RenderBundle, impl: RenderBundleImpl)] = []
    // The parent encoder's device. Declared last, so that it outlives the rest of the pass.
    let device: WebGPU.Metal.Device

    fileprivate init(
        renderCommandEncoder: (any MTLRenderCommandEncoder)?,
        metalDescriptor: MTLRenderPassDescriptor?,
        rasterizationRateMap: (any MTLRasterizationRateMap)?,
        visibilityResultBuffer: (any MTLBuffer)?,
        parameters: WebGPU.Metal.RenderPassEncoderParameters,
        parentEncoder: WebGPU.Metal.CommandEncoder,
        parentImpl: CommandEncoderImpl,
        device: WebGPU.Metal.Device,
        lastErrorString: String?
    ) {
        self.device = device
        self.backingRenderCommandEncoder = renderCommandEncoder
        self.metalDescriptor = metalDescriptor
        self.rasterizationRateMap = rasterizationRateMap
        self.visibilityResultBuffer = visibilityResultBuffer
        self.visibilityResultBufferSize = parameters.visibilityResultBufferSize
        self.maxDrawCount = parameters.maxDrawCount
        self.parentEncoder = parentEncoder
        self.parentImpl = parentImpl
        self.lastErrorString = lastErrorString
        let deviceImpl = parentImpl.deviceImpl
        let limits = deviceImpl.limits
        precondition(maxBindGroupIndexCount >= Int(limits.maxBindGroups))
        self.deviceImpl = deviceImpl
        self.limits = limits
        self.maxVerticesPerDrawCall = deviceImpl.maxVerticesPerDrawCall()
        self.allBindGroupsMask = limits.maxBindGroups >= 32 ? UInt32.max : (1 << limits.maxBindGroups) &- 1
        attachments.depthReadOnly = parameters.depthReadOnly
        attachments.stencilReadOnly = parameters.stencilReadOnly
    }

    // MARK: State machine

    @_expose(Cxx)
    func isValid() -> Bool {
        backingRenderCommandEncoder != nil || deferredDescriptor != nil
    }

    @_expose(Cxx)
    func markEncoderStateWasNotOpen() {
        encoderStateWasNotOpen = true
    }

    @_expose(Cxx)
    func deferRenderCommandEncoder(_ descriptor: MTLRenderPassDescriptor?) {
        deferredDescriptor = descriptor
    }

    private func materializeRenderCommandEncoder() -> (any MTLRenderCommandEncoder)? {
        guard backingRenderCommandEncoder == nil, let descriptor = deferredDescriptor else {
            return backingRenderCommandEncoder
        }

        // No render pass state can have been recorded yet: every entry point that records state
        // materializes the encoder first, so there is nothing to replay here the way splitRenderPass does.
        deferredDescriptor = nil
        backingRenderCommandEncoder = parentImpl.makeRenderCommandEncoder(descriptor)
        drawState = DrawStateCache()
        return backingRenderCommandEncoder
    }

    @_expose(!Cxx)
    func renderCommandEncoder() -> (any MTLRenderCommandEncoder)? {
        if parentImpl.submitWillBeInvalid() {
            return nil
        }
        if let encoder = backingRenderCommandEncoder {
            return encoder
        }
        return materializeRenderCommandEncoder()
    }

    // Called from ~RenderPassEncoder, which must not pass the dying shell into Swift.
    @_expose(Cxx)
    func passWillBeDestroyed() {
        if isValid() {
            parentImpl.makeInvalid("GPURenderPassEncoder.finish was never called")
        }
        backingRenderCommandEncoder = nil
        deferredDescriptor = nil
    }

    // Out of line, so that the entry points that can report do no device work unless they report.
    @inline(never)
    private func generateAValidationError(_ message: String) {
        deviceImpl.generateAValidationError(message)
    }

    // When it returns true, the entry point reports its "failed as encoding has finished" error and returns.
    private func encodingHasFinished() -> Bool {
        if !parentImpl.isLocked() || parentImpl.isFinished() {
            backingRenderCommandEncoder = nil
            deferredDescriptor = nil
            return true
        }
        return false
    }

    // Whether the pass still holds its command encoder's current encoder; entry points return when it does not.
    private func holdsCurrentEncoder() -> Bool {
        if backingRenderCommandEncoder == nil {
            _ = materializeRenderCommandEncoder()
        }
        if let encoder = backingRenderCommandEncoder, parentImpl.isValid(), parentImpl.isCurrentEncoder(ObjectIdentifier(encoder)) {
            return true
        }
        backingRenderCommandEncoder = nil
        deferredDescriptor = nil
        return false
    }

    private func makeInvalid(_ errorString: String? = nil) {
        lastErrorString = errorString

        guard let encoder = backingRenderCommandEncoder else {
            // A deferred pass has no encoder to hand back, but it is still holding the parent encoder, so
            // drop the descriptor to keep the destructor from reporting it as never finished.
            deferredDescriptor = nil
            parentImpl.makeInvalid("RenderPassEncoder.makeInvalid, rason = \(errorString ?? "(null)")")
            return
        }

        parentImpl.setLastError(errorString)
        parentImpl.endEncoding(encoder)
        backingRenderCommandEncoder = nil
    }

    // For RenderBundleEncoderImpl while it replays into this pass.
    @_expose(!Cxx)
    func invalidate(_ errorString: String?) {
        makeInvalid(errorString)
    }

    // For the shell's makeInvalid().
    @_expose(Cxx)
    func invalidateFromCxx(_ errorString: NSString?) {
        makeInvalid(errorString as String?)
    }

    // MARK: Attachments, handed in by the shell's constructor in descriptor order

    @_expose(Cxx)
    func appendEmptyColorAttachment() {
        attachments.colorViewIndices.append(-1)
    }

    @_expose(Cxx)
    func appendColorAttachmentTexture(_ texture: borrowing WebGPU.Metal.Texture, _ impl: TextureImpl) {
        attachments.colorViewIndices.append(Int32(attachments.views.count))
        attachments.appendView(.texture(copy texture, impl))
        beginColorAttachment(.texture(impl))
    }

    @_expose(Cxx)
    func appendColorAttachmentView(_ view: borrowing WebGPU.Metal.TextureView, _ impl: TextureViewImpl) {
        attachments.colorViewIndices.append(Int32(attachments.views.count))
        attachments.appendView(.textureView(copy view, impl))
        beginColorAttachment(.textureView(impl))
    }

    private func beginColorAttachment(_ view: AttachmentImpl) {
        if view.isDestroyed {
            parentImpl.makeSubmitInvalid(nil)
        }
        addAttachmentUsage(view, .attachment)
        rasterSampleCount = view.sampleCount
        pendingColorAttachment = view
    }

    @_expose(Cxx)
    func resolveColorAttachmentTexture(_ impl: TextureImpl) {
        resolveColorAttachment(.texture(impl))
    }

    @_expose(Cxx)
    func resolveColorAttachmentView(_ impl: TextureViewImpl) {
        resolveColorAttachment(.textureView(impl))
    }

    private func resolveColorAttachment(_ resolveTarget: AttachmentImpl) {
        resolveTarget.setCommandEncoder(parentImpl)
        noteAttachment(
            resolveTarget,
            aspect: .All,
            AttachmentInitPlan(before: resolveTarget.isVolume ? .requireInitialized : .nothing, after: .written)
        )
        addAttachmentUsage(resolveTarget, .attachment)
    }

    // Records, in the command encoder's InitializationLedger, what the pass needs from and leaves in the aspects of an
    // attachment.
    private func noteAttachment(_ view: AttachmentImpl, aspect: WebGPU.TextureAspect, _ plan: AttachmentInitPlan) {
        let texture = view.parentTexture
        for region in view.initRegions(aspect: aspect) {
            parentImpl.noteAttachment(texture, region, plan)
        }
    }

    @_expose(Cxx)
    func endColorAttachment(_ slot: UInt32, _ loadOp: WebGPU.LoadOp, _ storeOp: WebGPU.StoreOp, _ hasDepthSlice: Bool, _ depthSlice: UInt32)
    {
        guard let view = pendingColorAttachment else {
            return
        }
        pendingColorAttachment = nil

        view.setCommandEncoder(parentImpl)
        let plan = attachmentInitPlan(load: loadOp, store: storeOp, readOnly: false, isVolume: view.isVolume, isTransient: view.isTransient)
        noteAttachment(view, aspect: .All, plan)
        let textureToClear = view.texture
        renderTargetWidth = UInt32(truncatingIfNeeded: textureToClear?.width ?? 0)
        renderTargetHeight = UInt32(truncatingIfNeeded: textureToClear?.height ?? 0)
        guard let textureToClear else {
            return
        }
        // A discarded attachment that the pass loaded, or a discarded 3D one, is cleared to zero once the pass ends.
        if plan.after == .zeroedAfterPass {
            attachmentsToClear[Int(slot)] = TextureAndClearColor(
                texture: textureToClear,
                depthPlane: view.isDestroyed || !hasDepthSlice ? 0 : Int(depthSlice)
            )
        }
    }

    @_expose(Cxx)
    func setDepthStencilAttachmentTexture(
        _ texture: borrowing WebGPU.Metal.Texture,
        _ impl: TextureImpl,
        _ parameters: WebGPU.Metal.RenderPassDepthStencilParameters
    ) {
        attachments.hasDepthStencil = true
        attachments.depthStencilViewIndex = Int32(attachments.views.count)
        attachments.appendView(.texture(copy texture, impl))
        setDepthStencilAttachment(.texture(impl), parameters)
    }

    @_expose(Cxx)
    func setDepthStencilAttachmentView(
        _ view: borrowing WebGPU.Metal.TextureView,
        _ impl: TextureViewImpl,
        _ parameters: WebGPU.Metal.RenderPassDepthStencilParameters
    ) {
        attachments.hasDepthStencil = true
        attachments.depthStencilViewIndex = Int32(attachments.views.count)
        attachments.appendView(.textureView(copy view, impl))
        setDepthStencilAttachment(.textureView(impl), parameters)
    }

    private func setDepthStencilAttachment(_ view: AttachmentImpl, _ parameters: WebGPU.Metal.RenderPassDepthStencilParameters) {
        view.setCommandEncoder(parentImpl)
        let depthTexture = view.isDestroyed ? nil : view.texture
        if view.width != 0 && renderTargetWidth == 0 {
            renderTargetWidth = UInt32(truncatingIfNeeded: depthTexture?.width ?? 0)
            renderTargetHeight = UInt32(truncatingIfNeeded: depthTexture?.height ?? 0)
            rasterSampleCount = view.sampleCount
        }

        depthClearValue = parameters.depthStoreOpIsDiscard ? 0 : Float(quantizedDepthValue(Double(parameters.depthClearValue), view.format))
        if !isStencilOnlyFormat(depthTexture?.pixelFormat ?? .invalid) {
            let plan = attachmentInitPlan(
                load: parameters.depthLoadOpIsLoad ? .Load : .Clear,
                store: parameters.depthStoreOpIsDiscard ? .Discard : .Store,
                readOnly: parameters.depthReadOnly,
                isVolume: false,
                isTransient: view.isTransient
            )
            noteAttachment(view, aspect: .DepthOnly, plan)
            clearDepthAttachment = depthTexture != nil && plan.after == .zeroedAfterPass
            depthStencilAttachmentToClear = depthTexture
            addAttachmentUsage(view, parameters.depthReadOnly ? .attachmentRead : .attachment, aspect: .DepthOnly)
        }

        stencilClearValue = parameters.stencilStoreOpIsDiscard ? 0 : parameters.stencilClearValue
        if stencilOnlyAspectMetalFormat(view.format) != nil {
            let plan = attachmentInitPlan(
                load: parameters.stencilLoadOpIsLoad ? .Load : .Clear,
                store: parameters.stencilStoreOpIsDiscard ? .Discard : .Store,
                readOnly: parameters.stencilReadOnly,
                isVolume: false,
                isTransient: view.isTransient
            )
            noteAttachment(view, aspect: .StencilOnly, plan)
            clearStencilAttachment = depthTexture != nil && plan.after == .zeroedAfterPass
            depthStencilAttachmentToClear = depthTexture
            addAttachmentUsage(view, parameters.stencilReadOnly ? .attachmentRead : .attachment, aspect: .StencilOnly)
        }
    }

    private func clearAttachmentsAfterEndEncoding() {
        let hasTexturesToClear =
            !attachmentsToClear.isEmpty || (depthStencilAttachmentToClear != nil && (clearDepthAttachment || clearStencilAttachment))
        if hasTexturesToClear {
            // runClearEncoder may clear its copy of the depth-stencil texture, not this pass's.
            var depthStencilTexture = depthStencilAttachmentToClear
            parentImpl.runClearEncoder(
                attachmentsToClear: attachmentsToClear,
                depthStencilAttachmentToClear: &depthStencilTexture,
                depthAttachmentToClear: clearDepthAttachment,
                stencilAttachmentToClear: clearStencilAttachment,
                depthClearValue: Double(depthClearValue),
                stencilClearValue: stencilClearValue,
                existingEncoder: nil
            )
        }
    }

    // MARK: Usage tracking

    // Without an aspect, the whole range is tracked as both DepthOnly and StencilOnly, whatever the view's own aspect.
    private func addAttachmentUsage(_ view: AttachmentImpl, _ usage: EntryUsage, aspect: WebGPU.TextureAspect? = nil) {
        let texture = view.parentTexture
        let identity = identityKey(ObjectIdentifier(texture))
        let range = view.subresources
        if let aspect {
            addTextureUsage(
                identity,
                texture,
                usage,
                range.baseMipLevel,
                range.mipLevelCount,
                range.baseArrayLayer,
                range.arrayLayerCount,
                aspect
            )
            return
        }
        addTextureUsage(
            identity,
            texture,
            usage,
            range.baseMipLevel,
            range.mipLevelCount,
            range.baseArrayLayer,
            range.arrayLayerCount,
            .DepthOnly
        )
        addTextureUsage(
            identity,
            texture,
            usage,
            range.baseMipLevel,
            range.mipLevelCount,
            range.baseArrayLayer,
            range.arrayLayerCount,
            .StencilOnly
        )
    }

    // Every subresource of the range takes on the usage, and the first conflict invalidates the pass and stops this
    // range.
    private func addTextureUsage(
        _ identity: UInt64,
        _ texture: TextureImpl,
        _ initialUsage: EntryUsage,
        _ baseMipLevel: UInt32,
        _ mipLevelCount: UInt32,
        _ baseArrayLayer: UInt32,
        _ arrayLayerCount: UInt32,
        _ aspect: WebGPU.TextureAspect
    ) {
        if texture.texture() == nil {
            return
        }

        let lastMipLevel = baseMipLevel &+ mipLevelCount
        let lastArrayLayer = baseArrayLayer &+ arrayLayerCount
        var mipLevel = baseMipLevel
        while mipLevel < lastMipLevel {
            var arrayLayer = baseArrayLayer
            while arrayLayer < lastArrayLayer {
                let key = TextureSubresourceKey(texture: identity, entry: entryMapKey(mipLevel, arrayLayer, aspect))
                let existingIndex = usagesForTexture.valueIndex(forKey: key)
                let existingUsage = existingIndex.map { usagesForTexture.values[$0] }
                var usage = initialUsage
                if let existingUsage {
                    usage.formUnion(existingUsage)
                }
                if !usage.isAllowed {
                    makeInvalid("Bind group has incompatible usage list: \(usage.name)")
                    return
                }
                if let existingIndex {
                    if usage != existingUsage {
                        usagesForTexture.replaceValue(at: existingIndex, with: usage)
                    }
                } else {
                    usagesForTexture.insertAbsent(key, usage)
                }
                arrayLayer += 1
            }
            mipLevel += 1
        }
    }

    // Buffers and external textures.
    private func addBufferUsage(_ identity: UInt64, _ initialUsage: EntryUsage) {
        let existingIndex = usagesForBuffer.valueIndex(forKey: identity)
        let existingUsage = existingIndex.map { usagesForBuffer.values[$0] }
        var usage = initialUsage
        if let existingUsage {
            usage.formUnion(existingUsage)
        }
        if !usage.isAllowed {
            makeInvalid("Bind group has incompatible usage list: \(usage.name)")
            return
        }
        if let existingIndex {
            if usage != existingUsage {
                usagesForBuffer.replaceValue(at: existingIndex, with: usage)
            }
        } else {
            usagesForBuffer.insertAbsent(identity, usage)
        }
    }

    // For bind-group and bundle records.
    @_expose(!Cxx)
    func addResourceToActiveResources(_ tracking: TrackingInfo, _ usage: EntryUsage, _ impl: TrackedImpl) {
        switch impl {
        case .buffer(let buffer):
            if usage.contains(.storage) {
                buffer.indirectBufferInvalidated(by: parentImpl)
            }
            addBufferUsage(tracking.identity, usage)
        case .externalTexture:
            addBufferUsage(tracking.identity, usage)
        case .texture(let texture):
            addTextureUsage(tracking.identity, texture, usage, 0, tracking.mipLevelCount, 0, tracking.arrayLayerCount, .DepthOnly)
            addTextureUsage(tracking.identity, texture, usage, 0, tracking.mipLevelCount, 0, tracking.arrayLayerCount, .StencilOnly)
        case .textureView(let view):
            let texture = view.parentTextureImpl
            if tracking.aspect != .All {
                addTextureUsage(
                    tracking.identity,
                    texture,
                    usage,
                    tracking.baseMipLevel,
                    tracking.mipLevelCount,
                    tracking.baseArrayLayer,
                    tracking.arrayLayerCount,
                    tracking.aspect
                )
                return
            }
            addTextureUsage(
                tracking.identity,
                texture,
                usage,
                tracking.baseMipLevel,
                tracking.mipLevelCount,
                tracking.baseArrayLayer,
                tracking.arrayLayerCount,
                .DepthOnly
            )
            addTextureUsage(
                tracking.identity,
                texture,
                usage,
                tracking.baseMipLevel,
                tracking.mipLevelCount,
                tracking.baseArrayLayer,
                tracking.arrayLayerCount,
                .StencilOnly
            )
        }
    }

    // Records the parent encoder on the resource; returns whether the pass has an encoder.
    @_expose(!Cxx)
    func trackUse(_ impl: TrackedImpl) -> Bool {
        impl.setCommandEncoder(parentImpl)
        return renderCommandEncoder() != nil
    }

    private func addInputBufferUsage(_ buffer: BufferImpl) {
        addBufferUsage(identityKey(ObjectIdentifier(buffer)), .input)
    }

    // The per-resource loop of setBindGroup, of a draw after a split, and of bundle replay.
    // `list` returns a container's MTLResources, read from its owner's mtlResources one at a time.
    @inline(__always)
    private func useAndTrack(_ resources: ResourceSet, _ list: (Int) -> [any MTLResource]) {
        resources.forEachDistinctImpl { impl in
            impl.setCommandEncoder(parentImpl)
        }
        let records = resources.records
        for containerIndex in resources.containers.indices {
            let container = resources.containers[containerIndex]
            let list = list(containerIndex)
            if !container.renderStages.isDisjoint(with: [.vertex, .fragment]) && !list.isEmpty {
                renderCommandEncoder()?.useResources(list, usage: container.usage, stages: container.renderStages)
            }
            for index in 0..<list.count {
                let record = records[container.range.lowerBound + index]
                guard let impl = record.impl, let tracking = record.tracking else {
                    continue
                }
                addResourceToActiveResources(tracking, record.usage, impl)
            }
        }
    }

    // MARK: Buffer bindings

    // Every buffer binding goes through these, at a slot only the device's MetalSlotLayout or a helper slot can name: the
    // dynamic-offsets slot is not one.
    private func setVertexBuffer(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ buffer: (any MTLBuffer)?,
        _ offset: UInt64,
        _ slot: MetalBufferSlot
    ) {
        setVertexBuffer(commandEncoder, buffer, address: buffer?.gpuAddress ?? 0, offset, slot)
    }

    /// The address is the gpuAddress of `buffer`, or 0 without a buffer.
    private func setVertexBuffer(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ buffer: (any MTLBuffer)?,
        address: UInt64,
        _ offset: UInt64,
        _ slot: MetalBufferSlot
    ) {
        // Truncated to the 32 bits the binding cache keeps.
        let offset = UInt32(truncatingIfNeeded: offset)
        if ignoreBufferCache {
            commandEncoder?.setVertexBuffer(buffer, offset: Int(offset), index: slot.index)
            return
        }

        let key = ExistingBufferKey(gpuAddress: address, offset: offset)
        if existingVertexBuffers.needsBinding(slot, key) {
            commandEncoder?.setVertexBuffer(buffer, offset: Int(offset), index: slot.index)
            existingVertexBuffers.recordBinding(slot, key)
        }
    }

    private func setVertexBuffer(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ buffer: (any MTLBuffer)?,
        _ offset: UInt64,
        _ slot: HelperVertexSlot
    ) {
        setVertexBuffer(commandEncoder, buffer, offset, slot.slot)
    }

    private func setFragmentBuffer(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ buffer: (any MTLBuffer)?,
        address: UInt64,
        _ offset: UInt64,
        _ slot: MetalBufferSlot
    ) {
        let offset = UInt32(truncatingIfNeeded: offset)
        if ignoreBufferCache {
            commandEncoder?.setFragmentBuffer(buffer, offset: Int(offset), index: slot.index)
            return
        }

        let key = ExistingBufferKey(gpuAddress: address, offset: offset)
        if existingFragmentBuffers.needsBinding(slot, key) {
            commandEncoder?.setFragmentBuffer(buffer, offset: Int(offset), index: slot.index)
            existingFragmentBuffers.recordBinding(slot, key)
        }
    }

    // A helper kernel's constants: only at a helper slot.
    private func setVertexBytes(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ first: UInt32,
        _ second: UInt32,
        _ slot: HelperVertexSlot
    ) {
        WebGPU.Metal.setVertexUInt32Pair(commandEncoder, first, second, slot.rawValue)
        existingVertexBuffers[slot.slot] = ExistingBufferKey()
    }

    private func setVertexBytes(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ first: UInt32,
        _ second: UInt32,
        _ third: UInt32,
        _ slot: HelperVertexSlot
    ) {
        WebGPU.Metal.setVertexUInt32Triple(commandEncoder, first, second, third, slot.rawValue)
        existingVertexBuffers[slot.slot] = ExistingBufferKey()
    }

    private func setVertexBytes(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ indexData: WebGPU.Metal.IndexData,
        _ slot: HelperVertexSlot
    ) {
        WebGPU.Metal.setVertexIndexData(commandEncoder, indexData, slot.rawValue)
        existingVertexBuffers[slot.slot] = ExistingBufferKey()
    }

    // MARK: Draw validation

    // The pipeline's, which is what setPipeline recorded; every draw that reads it has checked for a pipeline.
    private var primitiveType: MTLPrimitiveType {
        currentPipelineImpl?.parameters.primitiveType ?? .triangle
    }

    // The depth range the fragment shader clamps frag_depth to.
    private var viewportMinDepth: Float {
        viewport.map { Float($0.znear) } ?? 0
    }

    private var viewportMaxDepth: Float {
        viewport.map { Float($0.zfar) } ?? 1
    }

    // A draw is about to write the visibility result of the current query, so endPass need not zero it.
    private func visibilityResultWillBeWritten() {
        if queryBufferIndicesToClearCount != 0 {
            queryBufferIndicesToClear.remove(UInt64(visibilityResultBufferOffset))
            queryBufferIndicesToClearCount = queryBufferIndicesToClear.count
        }
    }

    private func incrementDrawCount(_ drawCalls: UInt32) {
        let (newDrawCount, overflowed) = drawCount.addingReportingOverflow(UInt64(drawCalls))
        if overflowed || newDrawCount > maxDrawCount {
            makeInvalid("m_drawCount > m_maxDrawCount")
            return
        }

        drawCount = newDrawCount
    }

    private func applyCachedRenderPassState(_ commandEncoder: (any MTLRenderCommandEncoder)?) {
        if let viewport, viewportNeedsApplying {
            commandEncoder?.setViewport(viewport)
            #if !arch(x86_64)
            viewportNeedsApplying = false
            #endif
        }
        if let blendColor {
            commandEncoder?
                .setBlendColor(red: Float(blendColor.r), green: Float(blendColor.g), blue: Float(blendColor.b), alpha: Float(blendColor.a))
        }
        if let stencilReferenceValue {
            commandEncoder?.setStencilReferenceValue(stencilReferenceValue)
            self.stencilReferenceValue = nil
        }
        if let scissorRect {
            commandEncoder?.setScissorRect(scissorRect)
            self.scissorRect = nil
        }
    }

    private func vertexBufferSize(_ bufferIndex: UInt32) -> UInt64 {
        let binding = vertexBuffers[Int(bufferIndex)]
        guard binding.buffer != nil else {
            return 0
        }
        let length = binding.length
        return length < binding.offset ? 0 : length - binding.offset
    }

    @inline(__always)
    private func minimumVertexInstanceCounts(_ pipelineImpl: RenderPipelineImpl) -> VertexInstanceBounds {
        minimumVertexInstanceCount(pipelineImpl, bufferSize: vertexBufferSize)
    }

    // The pipeline with each vertex stride replaced by its last stride: shares the pipeline's layout, unique identifier
    // and minimum buffer sizes; only its Metal pipeline state differs.
    private func lastStrideAsStrideImpl(_ pipelineImpl: RenderPipelineImpl) -> RenderPipelineImpl {
        pipelineImpl.lastStrideAsStride().impl
    }

    // A state that is not compiled yet: a failed compile is reported on the pipeline's device. Out of line: only the first
    // draw with a pipeline, and draws after a failed compile, get here.
    @inline(never)
    private func compileRenderPipelineState(lastStrideAsStride: Bool) -> (any MTLRenderPipelineState)? {
        guard let pipelineImpl = currentPipelineImpl, !currentPipeline.isEmpty else {
            return nil
        }
        if lastStrideAsStride {
            return pipelineImpl.lastStrideAsStride().impl.compiledRenderPipelineState()
        }
        return pipelineImpl.compiledRenderPipelineState()
    }

    // The loop of runVertexBufferValidation, in WTF order.
    private func errorValidatingVertexBufferSizes(
        _ pipelineImpl: RenderPipelineImpl,
        _ vertexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstVertex: UInt32,
        _ firstInstance: UInt32
    ) -> String? {
        for required in pipelineImpl.requiredVertexBuffersInWTFOrder {
            var strideCount: UInt64 = 0
            if required.stepMode == .Vertex {
                let (sum, overflowed) = firstVertex.addingReportingOverflow(vertexCount)
                if overflowed {
                    return "StrideCount invalid"
                }
                strideCount = UInt64(sum)
            } else if required.stepMode == .Instance {
                let (sum, overflowed) = firstInstance.addingReportingOverflow(instanceCount)
                if overflowed {
                    return "StrideCount invalid"
                }
                strideCount = UInt64(sum)
            }

            if strideCount == 0 {
                continue
            }

            let bufferSize = vertexBuffers[Int(required.bufferIndex)].size
            // Cannot overflow: a 32-bit count times a stride.
            let strideSize = (strideCount - 1) * required.stride
            let (requiredSize, overflowed) = strideSize.addingReportingOverflow(required.lastStride)
            if overflowed || requiredSize > bufferSize {
                return
                    "Buffer[\(required.bufferIndex)] fails: (strideCount(\(strideCount)) - 1) * bufferData.stride(\(required.stride)) + bufferData.lastStride(\(required.lastStride)) > bufferSize(\(bufferSize))"
            }
        }

        return nil
    }

    // The loop of runIndexBufferValidation.
    private func validateInstanceStepVertexBuffers(_ pipelineImpl: RenderPipelineImpl, _ strideCount: UInt64) -> Bool {
        for required in pipelineImpl.requiredVertexBuffersInWTFOrder {
            let binding = vertexBuffers[Int(required.bufferIndex)]
            guard binding.buffer != nil else {
                continue
            }
            if required.stepMode != .Instance {
                continue
            }
            let (product, productOverflowed) = (strideCount - 1).multipliedReportingOverflow(by: required.stride)
            if productOverflowed {
                return false
            }
            let (sum, sumOverflowed) = product.addingReportingOverflow(required.lastStride)
            if sumOverflowed {
                return false
            }
            if sum > binding.size {
                makeInvalid(
                    "Buffer[\(required.bufferIndex)] fails: (strideCount(\(strideCount)) - 1) * stride(\(required.stride)) + lastStride(\(required.lastStride)) > bufferSize(\(binding.size)) / mtlBufferSize(\(binding.length))"
                )
                return false
            }
        }

        return true
    }

    // The loop of errorValidatingAndBindingBuffers. A bound buffer whose offset is past its end both invalidates the
    // pass and returns the message, which is reported again.
    private func errorBindingRequiredVertexBuffers(
        _ pipelineImpl: RenderPipelineImpl,
        _ commandEncoder: (any MTLRenderCommandEncoder)?
    ) -> String? {
        for required in pipelineImpl.requiredVertexBuffersInWTFOrder {
            let binding = vertexBuffers[Int(required.bufferIndex)]
            guard let buffer = binding.buffer else {
                return "Buffer1 index[\(required.bufferIndex)] is missing"
            }
            // Pipeline creation keeps its buffers below maxVertexBuffers.
            guard let slot = limits.slots.vertexBufferSlot(required.bufferIndex) else {
                preconditionFailure("a pipeline's vertex buffer index is below maxVertexBuffers")
            }

            if binding.offset < binding.length {
                setVertexBuffer(commandEncoder, buffer, address: binding.gpuAddress, binding.offset, slot)
            } else if binding.size != 0 {
                makeInvalid("offset >= buffer.length && buffer.size")
                return "offset >= buffer.length && buffer.size"
            } else {
                setVertexBuffer(commandEncoder, deviceImpl.placeholderBuffer(), 0, slot)
            }
        }

        return nil
    }

    private func errorValidatingAndBindingBuffers(
        _ pipelineImpl: RenderPipelineImpl,
        _ commandEncoder: (any MTLRenderCommandEncoder)?
    ) -> String? {
        if let error = errorBindingRequiredVertexBuffers(pipelineImpl, commandEncoder) {
            return error
        }

        let (withBindGroups, overflow1) = maxBindGroupSlot.addingReportingOverflow(1)
        let (withVertexBuffers, overflow2) = withBindGroups.addingReportingOverflow(maxVertexBufferSlot)
        let (spaceUsed, overflow3) = withVertexBuffers.addingReportingOverflow(1)
        if overflow1 || overflow2 || overflow3 || spaceUsed > limits.maxBindGroupsPlusVertexBuffers {
            return "Too many bind groups and vertex buffers used"
        }

        return nil
    }

    private func errorValidatingDrawIndexed() -> String? {
        if indexBufferImpl == nil {
            return "Index buffer is not set"
        }

        guard let pipelineImpl = currentPipelineImpl else {
            return "Pipeline is not set"
        }

        let topology = pipelineImpl.primitiveTopology
        if topology != .LineStrip && topology != .TriangleStrip {
            return nil
        }

        if indexType != pipelineImpl.indexType {
            return "Primitive topology mismatch with render pipeline"
        }

        return nil
    }

    private func runIndexBufferValidation(_ firstInstance: UInt32, _ instanceCount: UInt32) -> Bool {
        guard let pipelineImpl = currentPipelineImpl, indexBufferImpl != nil else {
            makeInvalid("Missing pipeline before draw command")
            return false
        }

        // The sum of two UInt32 values cannot overflow UInt64 (UInt is 32 bits on arm64_32).
        let strideCount = UInt64(firstInstance) + UInt64(instanceCount)
        if strideCount == 0 {
            return true
        }

        return validateInstanceStepVertexBuffers(pipelineImpl, strideCount)
    }

    private func runVertexBufferValidation(
        _ currentPipelineImpl: RenderPipelineImpl?,
        _ vertexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstVertex: UInt32,
        _ firstInstance: UInt32
    ) {
        guard let pipelineImpl = currentPipelineImpl else {
            makeInvalid("Missing pipeline before draw command")
            return
        }

        if firstVertex.addingReportingOverflow(vertexCount).overflow {
            makeInvalid("Overflow in vertex count + firstVertex")
            return
        }

        if let error = errorValidatingVertexBufferSizes(pipelineImpl, vertexCount, instanceCount, firstVertex, firstInstance) {
            makeInvalid(error)
        }
    }

    // MARK: Encoding a draw

    // The bind-group loop of executePreDrawCommands, in WTF order. On false, a group that failed validation has
    // invalidated the pass, and one that made the submit invalid has not.
    private func encodeBindGroupsForDraw(
        _ pipelineImpl: RenderPipelineImpl,
        passWasSplit: Bool,
        _ commandEncoder: (any MTLRenderCommandEncoder)?
    ) -> Bool {
        let layoutImpl = pipelineImpl.pipelineLayoutImpl
        let pipelineId = pipelineImpl.parameters.uniqueId
        for groupIndex in bindGroups.order {
            guard let group = bindGroups[groupIndex] else {
                continue
            }
            if passWasSplit {
                useAndTrack(group.resources) { group.mtlResources[$0] }
            }

            if group.hasSamplers {
                parentImpl.rebindSamplersPreCommit(bindGroups.shell(groupIndex), group)
            }

            let index = Int(groupIndex)
            if !group.previouslyValidated(group: groupIndex, pipelineId: pipelineId, maxOffset: maxDynamicOffsetAtIndex[index]) {
                if let error = group.errorValidatingBindGroup(
                    pipelineImpl.minimumBufferSizes,
                    group: groupIndex,
                    dynamicOffsets: bindGroupDynamicOffsets[groupIndex]
                ) {
                    makeInvalid(error)
                    return false
                }
                let pipelineGroupLayout = layoutImpl.bindGroupLayout(at: index)
                if group.makeSubmitInvalid(.vertex, pipelineLayout: pipelineGroupLayout)
                    || group.makeSubmitInvalid(.fragment, pipelineLayout: pipelineGroupLayout)
                {
                    parentImpl.makeSubmitInvalid(nil)
                    return false
                }
                group.validatedSuccessfully(group: groupIndex, pipelineId: pipelineId, maxOffset: maxDynamicOffsetAtIndex[index])
            }
            setVertexBuffer(
                commandEncoder,
                group.argumentBuffers.vertex,
                address: group.argumentBufferAddresses.vertex,
                0,
                limits.slots.vertexBindGroupSlot(groupIndex)
            )
            setFragmentBuffer(
                commandEncoder,
                group.argumentBuffers.fragment,
                address: group.argumentBufferAddresses.fragment,
                0,
                limits.slots.bindGroupSlot(groupIndex)
            )
        }
        return true
    }

    // PipelineLayoutImpl.updateOffsets, writing into `destination` from `start`. Traps when the plan writes outside
    // `destination`.
    private static func updateDynamicOffsets(
        _ layoutImpl: PipelineLayoutImpl,
        _ stage: Stage,
        _ group: UInt32,
        _ offsets: [UInt32],
        _ destination: inout ContiguousArray<UInt32>,
        from start: Int
    ) -> Bool {
        precondition(start <= destination.count)
        let groupIndex = Int(group)
        let plan = layoutImpl.dynamicOffsetPlan(stage)
        guard groupIndex < plan.groups.count, let groupStart = plan.groups[groupIndex].start else {
            return true
        }
        let base = start + Int(groupStart)
        precondition(base <= destination.count)
        let available = destination.count - base

        let layoutCount = layoutImpl.numberOfBindGroupLayouts()
        if layoutCount == 0 {
            return true
        }

        let offsetGroup = plan.groups[groupIndex]
        if let linearRange = offsetGroup.linearRange {
            let first = Int(linearRange.first)
            let count = Int(linearRange.count)
            precondition(first <= offsets.count && count <= offsets.count - first)
            precondition(available >= count)
            for index in 0..<count {
                destination[base + index] = offsets[first + index]
            }
            return true
        }

        if groupIndex >= layoutCount || offsetGroup.count > UInt64(available) {
            return false
        }
        for (index, sourceIndex) in offsetGroup.sourceIndices.enumerated() {
            if index >= available || Int(sourceIndex) >= offsets.count {
                return false
            }
            destination[base + index] = offsets[Int(sourceIndex)]
        }
        return true
    }

    // Copies without sharing storage, so the next draw's in-place writes do not copy.
    private static func assign(_ destination: inout ContiguousArray<UInt32>, _ source: ContiguousArray<UInt32>) {
        destination.removeAll(keepingCapacity: true)
        destination.append(contentsOf: source)
    }

    private static func fill(_ offsets: inout ContiguousArray<UInt32>, count: Int) {
        if offsets.count > count {
            offsets.removeLast(offsets.count - count)
        }
        for index in offsets.indices {
            offsets[index] = 0
        }
        if offsets.count < count {
            offsets.append(contentsOf: repeatElement(0, count: count - offsets.count))
        }
    }

    private func setViewportMinMaxDepthIntoFragmentDynamicOffsets() {
        if fragmentDynamicOffsets.count < startIndexForFragmentDynamicOffsets {
            fragmentDynamicOffsets.append(
                contentsOf: repeatElement(0, count: startIndexForFragmentDynamicOffsets - fragmentDynamicOffsets.count)
            )
        }
        // Written only when they change, so that a steady draw only reads the array.
        let minDepth = viewportMinDepth.bitPattern
        let maxDepth = viewportMaxDepth.bitPattern
        if fragmentDynamicOffsets[0] != minDepth {
            fragmentDynamicOffsets[0] = minDepth
        }
        if fragmentDynamicOffsets[1] != maxDepth {
            fragmentDynamicOffsets[1] = maxDepth
        }
    }

    // The walk over the changed groups' dynamic offsets, in WTF order.
    private func updateChangedDynamicOffsets(_ layoutImpl: PipelineLayoutImpl) -> Bool {
        var succeeded = true
        bindGroupDynamicOffsets.forEachInWTFOrder { groupIndex, offsets in
            guard succeeded, bindGroupDynamicOffsetsChanged & (1 << groupIndex) != 0 else {
                return
            }
            if !Self.updateDynamicOffsets(layoutImpl, .vertex, groupIndex, offsets, &vertexDynamicOffsets, from: 0) {
                succeeded = false
                return
            }
            if !Self.updateDynamicOffsets(
                layoutImpl,
                .fragment,
                groupIndex,
                offsets,
                &fragmentDynamicOffsets,
                from: startIndexForFragmentDynamicOffsets
            ) {
                succeeded = false
                return
            }
            bindGroupDynamicOffsetsChanged &= ~(1 << groupIndex)
        }
        return succeeded
    }

    // The dynamic-offset tail of executePreDrawCommands. Returns false where it reported "Invalid offset calculation".
    private func encodeDynamicOffsetsForDraw(_ layoutImpl: PipelineLayoutImpl, _ commandEncoder: (any MTLRenderCommandEncoder)?) -> Bool {
        if !bindGroupDynamicOffsets.isEmpty && !updateChangedDynamicOffsets(layoutImpl) {
            return false
        }

        if !vertexDynamicOffsets.isEmpty && priorVertexDynamicOffsets != vertexDynamicOffsets {
            let offsets = vertexDynamicOffsets
            let slot = limits.slots.vertexDynamicOffsets
            WebGPU.Metal.setVertexUInt32s(commandEncoder, offsets.span, slot.rawValue)
            existingVertexBuffers.forget(slot)
            Self.assign(&priorVertexDynamicOffsets, offsets)
        }

        setViewportMinMaxDepthIntoFragmentDynamicOffsets()
        if priorFragmentDynamicOffsets != fragmentDynamicOffsets {
            let offsets = fragmentDynamicOffsets
            let slot = limits.slots.fragmentDynamicOffsets
            WebGPU.Metal.setFragmentUInt32s(commandEncoder, offsets.span, slot.rawValue)
            existingFragmentBuffers.forget(slot)
            Self.assign(&priorFragmentDynamicOffsets, offsets)
        }

        return true
    }

    // `indirectBuffer` is tracked as an input of the draw. It returns true even when incrementDrawCount() invalidates
    // the pass; the draw then encodes on a nil encoder.
    private func executePreDrawCommands(
        passWasSplit: Bool,
        indirectBuffer: BufferImpl?,
        needsValidationLayerWorkaround: Bool,
        firstInstance: UInt32 = 0,
        instanceCount: UInt32 = 0
    ) -> Bool {
        guard let currentImpl = currentPipelineImpl else {
            makeInvalid("Missing pipeline before draw command")
            return false
        }
        let pipelineImpl = needsValidationLayerWorkaround ? lastStrideAsStrideImpl(currentImpl) : currentImpl

        if !pipelineImpl.isValid() {
            makeInvalid("pipeline is not valid prior to draw")
            return false
        }

        if UInt64(instanceCount) + UInt64(firstInstance) > UInt64(UInt32.max) {
            return false
        }

        if let error = errorValidatingBindGroupCompatibility(pipelineImpl.pipelineLayoutImpl, { bindGroups[$0] }) {
            makeInvalid(error)
            return false
        }

        if let indirectBuffer {
            addInputBufferUsage(indirectBuffer)
        }
        // Nothing from here to the bind groups changes the encoder unless it also returns.
        let commandEncoder = renderCommandEncoder()
        if let error = errorValidatingAndBindingBuffers(currentImpl, commandEncoder) {
            makeInvalid(error)
            return false
        }

        if !encodeBindGroupsForDraw(pipelineImpl, passWasSplit: passWasSplit, commandEncoder) {
            return false
        }

        // A failed compile was reported as an out-of-memory error; the draw is skipped.
        guard
            let renderPipelineState = pipelineImpl.cachedRenderPipelineState()
                ?? compileRenderPipelineState(lastStrideAsStride: needsValidationLayerWorkaround)
        else {
            return false
        }
        encodePipelineStates(commandEncoder, renderPipelineState, pipelineImpl)
        applyCachedRenderPassState(commandEncoder)

        visibilityResultWillBeWritten()

        if !encodeDynamicOffsetsForDraw(pipelineImpl.pipelineLayoutImpl, commandEncoder) {
            makeInvalid("Invalid offset calculation")
            return false
        }

        incrementDrawCount(1)

        return true
    }

    // MARK: Clamps

    private func emitMemoryBarrier(_ commandEncoder: (any MTLRenderCommandEncoder)?) {
        memoryBarrierCount &+= 1
        if memoryBarrierCount < limits.memoryBarrierLimit {
            commandEncoder?.memoryBarrier(scope: .buffers, after: .vertex, before: .vertex)
        }
    }

    // The pipeline's states, each sent only when it differs from what the encoder holds (DrawStateCache).
    private func encodePipelineStates(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ renderPipelineState: any MTLRenderPipelineState,
        _ pipelineImpl: RenderPipelineImpl
    ) {
        guard let commandEncoder else {
            return
        }
        let pipelineStateIdentity = ObjectIdentifier(renderPipelineState)
        if !Self.elidesRedundantStates || drawState.pipelineState != pipelineStateIdentity {
            commandEncoder.setRenderPipelineState(renderPipelineState)
            drawState.pipelineState = pipelineStateIdentity
            drawStateObjects.pipelineState = renderPipelineState
        }
        if let depthStencilState = pipelineImpl.depthStencilState() {
            let depthStencilIdentity = ObjectIdentifier(depthStencilState)
            if !Self.elidesRedundantStates || drawState.depthStencilState != depthStencilIdentity {
                commandEncoder.setDepthStencilState(depthStencilState)
                drawState.depthStencilState = depthStencilIdentity
                drawStateObjects.depthStencilState = depthStencilState
            }
        }
        let parameters = pipelineImpl.parameters
        let depthClipMode = parameters.depthClipMode
        let raster = DrawRasterState(
            cullMode: parameters.cullMode.rawValue,
            frontFace: parameters.frontFace.rawValue,
            depthClipMode: depthClipMode.rawValue,
            depthBias: parameters.depthBias.bitPattern,
            depthBiasSlopeScale: parameters.depthBiasSlopeScale.bitPattern,
            depthBiasClamp: parameters.depthBiasClamp.bitPattern
        )
        if !Self.elidesRedundantStates || drawState.raster != raster {
            commandEncoder.setCullMode(parameters.cullMode)
            commandEncoder.setFrontFacing(parameters.frontFace)
            commandEncoder.setDepthClipMode(depthClipMode)
            commandEncoder.setDepthBias(parameters.depthBias, slopeScale: parameters.depthBiasSlopeScale, clamp: parameters.depthBiasClamp)
            drawState.raster = raster
        }
    }

    // Whether a draw may skip a state the encoder already holds. Not on x86_64, which re-applies the viewport on every
    // draw too.
    private static var elidesRedundantStates: Bool {
        #if arch(x86_64)
        false
        #else
        true
        #endif
    }

    // A clamp's pipeline state, which the next draw replaces.
    private func setClampPipelineState(_ commandEncoder: (any MTLRenderCommandEncoder)?, _ pipelineState: any MTLRenderPipelineState) {
        commandEncoder?.setRenderPipelineState(pipelineState)
        drawState.pipelineState = nil
    }

    // A missing clamp pipeline loses the device.
    private func setClampPipeline(
        _ commandEncoder: (any MTLRenderCommandEncoder)?,
        _ device: borrowing WebGPU.Metal.Device,
        _ pipelineState: (any MTLRenderPipelineState)?
    ) -> Bool {
        guard let pipelineState else {
            deviceImpl.loseTheDevice(.Unknown)
            return false
        }
        setClampPipelineState(commandEncoder, pipelineState)
        return true
    }

    // Records one clamp's scratch for a deferred lostOrOOBRead check. The first call in a pass registers the
    // completion handler; later calls only append, so N clamping draws cost one handler, not N.
    private func trackIndirectDeviceLostCheck(_ scratch: any MTLBuffer, _ scratchOffset: UInt64, _ alsoRetain: (any MTLBuffer)?) {
        let checks: IndirectDeviceLostChecks
        if let existing = indirectDeviceLostChecks {
            checks = existing
        } else {
            checks = IndirectDeviceLostChecks()
            indirectDeviceLostChecks = checks
            WebGPU.Metal.registerIndirectDeviceLostChecks(parentEncoder, device) {
                checks.takeLostOrOOBRead()
            }
        }
        // alsoRetain has no flag of its own; it is held so a companion scratch outlives the GPU work.
        checks.entries.append((scratch: scratch, offset: scratchOffset, alsoRetain: alsoRetain))
    }

    private static func primitiveOffset(_ primitiveType: MTLPrimitiveType) -> UInt32 {
        primitiveType == .lineStrip || primitiveType == .triangleStrip ? 1 : 0
    }

    // `indexBufferShell` holds the shell of `indexBuffer`, which the completion handler of the GPU validation keeps
    // alive.
    @_expose(!Cxx)
    func clampIndexBufferToValidValues(
        _ indexCount: UInt32,
        _ instanceCount: UInt32,
        _ baseVertex: Int32,
        _ firstInstance: UInt32,
        _ indexType: MTLIndexType,
        _ indexBufferOffsetInBytes: UInt,
        _ indexBufferShell: borrowing [WebGPU.Metal.Buffer],
        _ indexBuffer: BufferImpl?,
        _ bounds: VertexInstanceBounds,
        _ rasterSampleCount: UInt32,
        _ primitiveType: MTLPrimitiveType
    ) -> IndexBufferClamp {
        guard let indexBuffer, let mtlIndexBuffer = indexBuffer.buffer(), indexCount != 0, !indexBuffer.isDestroyed() else {
            return .skip
        }

        if !bounds.clampsIndexValues {
            return .draw
        }

        let indexSizeInBytes: UInt32 = indexType == .uint16 ? 2 : 4
        let firstIndex = UInt32(truncatingIfNeeded: indexBufferOffsetInBytes / UInt(indexSizeInBytes))
        if bounds.vertices.isZero || bounds.instances.isZero || indexBufferOffsetInBytes >= UInt(mtlIndexBuffer.length)
            || bounds.vertices.excludesBaseVertex(baseVertex)
        {
            return .skip
        }

        let primitiveOffset = Self.primitiveOffset(primitiveType)
        let effectiveMinVertexCount = bounds.vertices.effectiveVertexCount(baseVertex: baseVertex)
        let key = BufferImpl.drawIndexKey(
            firstIndex: firstIndex,
            indexCount: indexCount,
            indexType: indexType,
            primitiveOffset: primitiveOffset,
            icbResourceID: 0
        )
        if let entry = indexBuffer.canSkipDrawIndexedValidation(key, vertexCount: effectiveMinVertexCount) {
            if indexBuffer.didReadOOB(0) {
                return .skip
            }

            indexBuffer.skippedDrawIndexedValidation(parentImpl, key, vertexCount: entry.vertexCount)
            return .draw
        }

        if !indexBuffer.didReadOOB(0) && indexBuffer.allIndexValuesBelow(indexType == .uint16, effectiveMinVertexCount) {
            indexBuffer.drawIndexedValidated(
                key,
                vertexCount: effectiveMinVertexCount,
                validationGeneration: indexBuffer.indexContentsGeneration()
            )
            if let entry = indexBuffer.canSkipDrawIndexedValidation(key, vertexCount: effectiveMinVertexCount) {
                indexBuffer.skippedDrawIndexedValidation(parentImpl, key, vertexCount: entry.vertexCount)
                return .draw
            }
        }

        let (indexCountInBytes, indexCountOverflowed) = UInt(indexSizeInBytes).multipliedReportingOverflow(by: UInt(indexCount))
        let (indexCountPlusOffsetInBytes, offsetOverflowed) = indexCountInBytes.addingReportingOverflow(indexBufferOffsetInBytes)
        if indexCountOverflowed || offsetOverflowed || indexCountPlusOffsetInBytes > UInt(mtlIndexBuffer.length) {
            return .skip
        }

        let (baseInstancePlusInstanceCount, instanceOverflowed) = UInt(firstInstance).addingReportingOverflow(UInt(instanceCount))
        let instanceLimit = bounds.instances.shaderValue
        let failedCondition = instanceOverflowed || baseInstancePlusInstanceCount > UInt(instanceLimit) || firstInstance >= instanceLimit

        let renderCommandEncoder = self.renderCommandEncoder()
        var indexedIndirectBufferOffset: UInt64 = 0
        let indexedIndirectBuffer = WebGPU.Metal.newDrawIndexedIndirectArgumentsBuffer(
            device,
            failedCondition ? 0 : indexCount,
            failedCondition ? 0 : instanceCount,
            firstIndex,
            baseVertex,
            firstInstance,
            &indexedIndirectBufferOffset
        )
        if !setClampPipeline(renderCommandEncoder, device, deviceImpl.indexBufferClampPipeline(indexType, UInt(rasterSampleCount))) {
            return .skip
        }
        setVertexBuffer(renderCommandEncoder, mtlIndexBuffer, UInt64(indexBufferOffsetInBytes), .zero)
        setVertexBuffer(renderCommandEncoder, indexedIndirectBuffer, indexedIndirectBufferOffset, .one)
        setVertexBytes(
            renderCommandEncoder,
            bounds.vertices.indexClampVertexCount(primitiveOffset: primitiveOffset),
            primitiveOffset,
            indexCount &- 1,
            .two
        )
        renderCommandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(indexCount))

        emitMemoryBarrier(renderCommandEncoder)

        WebGPU.Metal.registerIndexValidationCompletion(
            parentEncoder,
            device,
            indexBufferShell[0],
            firstIndex,
            indexCount,
            effectiveMinVertexCount,
            indexType,
            primitiveOffset,
            indexBuffer.indexContentsGeneration(),
            indexedIndirectBuffer,
            indexedIndirectBufferOffset
        )

        return .indirectDraw(indexedIndirectBuffer.map { ClampedIndirectArguments($0, indexedIndirectBufferOffset) })
    }

    // nil when nothing may be drawn; otherwise the caller splits the pass and draws with the result.
    @_expose(!Cxx)
    func clampIndirectIndexBufferToValidValues(
        _ indexBuffer: BufferImpl?,
        _ arguments: IndirectArgumentsRange?,
        _ indexType: MTLIndexType,
        _ indexBufferOffsetInBytes: UInt,
        _ bounds: VertexInstanceBounds,
        _ primitiveType: MTLPrimitiveType,
        _ rasterSampleCount: UInt32
    ) -> ClampedIndirectArguments? {
        guard let indexBuffer, let mtlIndexBuffer = indexBuffer.buffer(), !indexBuffer.isDestroyed(), let arguments else {
            return nil
        }

        let indexSize: UInt32 = indexType == .uint16 ? 2 : 4
        // An offset beyond 32 bits counts as an overflow.
        var offsetPlusSizeOverflowed = indexBufferOffsetInBytes > UInt(UInt32.max)
        var offsetPlusSize: UInt32 = 0
        if !offsetPlusSizeOverflowed {
            (offsetPlusSize, offsetPlusSizeOverflowed) = UInt32(indexBufferOffsetInBytes).addingReportingOverflow(indexSize)
        }
        // '>' not '>=': offset + indexSize == length is a valid single-element index buffer
        if bounds.vertices.isZero || bounds.instances.isZero || offsetPlusSizeOverflowed
            || UInt(offsetPlusSize) > UInt(mtlIndexBuffer.length)
        {
            return nil
        }

        // Per-draw for the reason in clampIndirectBufferToValidValues; both records are fetched as arguments.
        var finalScratchOffset: UInt64 = 0
        var intermediateScratchOffset: UInt64 = 0
        let finalScratch = WebGPU.Metal.newZeroedDrawIndexedIndirectScratch(device, &finalScratchOffset)
        let intermediateScratch = WebGPU.Metal.newZeroedDrawIndirectScratch(device, &intermediateScratchOffset)
        guard let finalScratch, let intermediateScratch else {
            return nil
        }

        var renderCommandEncoder = self.renderCommandEncoder()
        if !setClampPipeline(renderCommandEncoder, device, deviceImpl.indexedIndirectBufferClampPipeline(UInt(rasterSampleCount))) {
            return nil
        }
        let indexBufferCount = UInt32(truncatingIfNeeded: (UInt(mtlIndexBuffer.length) &- indexBufferOffsetInBytes) / UInt(indexSize))
        setVertexBuffer(renderCommandEncoder, arguments.buffer, UInt64(arguments.metalOffset), .zero)
        setVertexBuffer(renderCommandEncoder, finalScratch, finalScratchOffset, .one)
        setVertexBuffer(renderCommandEncoder, intermediateScratch, intermediateScratchOffset, .two)
        setVertexBytes(renderCommandEncoder, indexBufferCount, bounds.instances.shaderValue, .three)
        renderCommandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        emitMemoryBarrier(renderCommandEncoder)

        if bounds.clampsIndexValues {
            if splitRenderPass() {
                renderCommandEncoder = self.renderCommandEncoder()
            }
            if !setClampPipeline(renderCommandEncoder, device, deviceImpl.indexBufferClampPipeline(indexType, UInt(rasterSampleCount))) {
                return nil
            }
            setVertexBuffer(renderCommandEncoder, mtlIndexBuffer, UInt64(indexBufferOffsetInBytes), .zero)
            setVertexBuffer(renderCommandEncoder, finalScratch, finalScratchOffset, .one)
            let primitiveOffset = Self.primitiveOffset(primitiveType)
            setVertexBytes(
                renderCommandEncoder,
                bounds.vertices.indexClampVertexCount(primitiveOffset: primitiveOffset),
                primitiveOffset,
                indexBufferCount &- 1,
                .two
            )
            renderCommandEncoder?.drawPrimitives(.point, clamped: ClampedIndirectArguments(intermediateScratch, intermediateScratchOffset))
            emitMemoryBarrier(renderCommandEncoder)
        }

        parentImpl.addBuffer(finalScratch)
        parentImpl.addBuffer(intermediateScratch)
        // Device-loss flag lives in intermediateScratch; also retain finalScratch until GPU completion.
        trackIndirectDeviceLostCheck(intermediateScratch, intermediateScratchOffset, finalScratch)

        return ClampedIndirectArguments(finalScratch, finalScratchOffset)
    }

    // nil when nothing may be drawn; otherwise the caller splits the pass and draws with the result.
    @_expose(!Cxx)
    func clampIndirectBufferToValidValues(
        _ arguments: IndirectArgumentsRange?,
        _ bounds: VertexInstanceBounds,
        _ rasterSampleCount: UInt32
    ) -> ClampedIndirectArguments? {
        guard !bounds.vertices.isZero, !bounds.instances.isZero, let arguments else {
            return nil
        }

        // Scratch must be per-draw, not one slot shared by every draw against this Buffer. emitMemoryBarrier()
        // below orders the clamp against its own draw, but MTLRenderStages cannot name an indirect argument fetch,
        // so nothing can order draw N's fetch against draw N+1's clamp store into the same slot.
        var scratchOffset: UInt64 = 0
        guard let scratch = WebGPU.Metal.newZeroedDrawIndirectScratch(device, &scratchOffset) else {
            return nil
        }

        let renderCommandEncoder = self.renderCommandEncoder()
        if !setClampPipeline(renderCommandEncoder, device, deviceImpl.indirectBufferClampPipeline(UInt(rasterSampleCount))) {
            return nil
        }
        setVertexBuffer(renderCommandEncoder, arguments.buffer, UInt64(arguments.metalOffset), .zero)
        setVertexBuffer(renderCommandEncoder, scratch, scratchOffset, .one)
        setVertexBytes(renderCommandEncoder, bounds.vertices.shaderValue, bounds.instances.shaderValue, .two)
        renderCommandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        emitMemoryBarrier(renderCommandEncoder)

        parentImpl.addBuffer(scratch)
        trackIndirectDeviceLostCheck(scratch, scratchOffset, nil)

        return ClampedIndirectArguments(scratch, scratchOffset)
    }

    // The batched clamps of executeBundles mirror the ones above, but write caller-supplied per-draw scratch and
    // emit no internal memory barrier, so executeBundles can put one barrier around all draws.

    // One dispatch; writes the clamped MTLDrawPrimitivesIndirectArguments (+lostOrOOBRead) into the final scratch.
    private func clampIndirectBufferDispatchBatched(
        _ device: borrowing WebGPU.Metal.Device,
        _ work: IndirectEncodeWork,
        _ finalScratch: any MTLBuffer,
        _ finalScratchOffset: UInt64
    ) -> Bool {
        guard
            let arguments = IndirectArgumentsRange(
                work.indirectBuffer,
                offset: work.indirectOffset,
                argumentsSize: MemoryLayout<MTLDrawPrimitivesIndirectArguments>.size
            )
        else {
            return false
        }
        let renderCommandEncoder = self.renderCommandEncoder()
        guard let pipelineState = deviceImpl.indirectBufferClampPipeline(UInt(rasterSampleCount)) else {
            return false
        }
        setClampPipelineState(renderCommandEncoder, pipelineState)
        setVertexBuffer(renderCommandEncoder, arguments.buffer, UInt64(arguments.metalOffset), .zero)
        setVertexBuffer(renderCommandEncoder, finalScratch, finalScratchOffset, .one)
        setVertexBytes(renderCommandEncoder, work.bounds.vertices.shaderValue, work.bounds.instances.shaderValue, .two)
        renderCommandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        trackIndirectDeviceLostCheck(finalScratch, finalScratchOffset, nil)
        return true
    }

    // Indexed dispatch 1: clamps the arguments into the final scratch and writes a thread-count record into the
    // intermediate scratch, which dispatch 2 consumes. Returns the index buffer's element count, or nil.
    private func clampIndirectIndexBufferDispatch1Batched(
        _ device: borrowing WebGPU.Metal.Device,
        _ work: IndirectEncodeWork,
        _ finalScratch: any MTLBuffer,
        _ finalScratchOffset: UInt64,
        _ intermediateScratch: any MTLBuffer,
        _ intermediateScratchOffset: UInt64
    ) -> UInt32? {
        guard let mtlIndexBuffer = work.indexBuffer?.buffer(),
            let arguments = IndirectArgumentsRange(
                work.indirectBuffer,
                offset: work.indirectOffset,
                argumentsSize: MemoryLayout<MTLDrawIndexedPrimitivesIndirectArguments>.size
            )
        else {
            return nil
        }
        let indexSize: UInt32 = work.indexType == .uint16 ? 2 : 4
        var offsetPlusSizeOverflowed = work.indexBufferOffset > UInt(UInt32.max)
        var offsetPlusSize: UInt32 = 0
        if !offsetPlusSizeOverflowed {
            (offsetPlusSize, offsetPlusSizeOverflowed) = UInt32(work.indexBufferOffset).addingReportingOverflow(indexSize)
        }
        // The bound is '>' not '>=': offset + indexSize == length is a valid single-element buffer.
        if work.bounds.instances.isZero || offsetPlusSizeOverflowed || UInt(offsetPlusSize) > UInt(mtlIndexBuffer.length) {
            return nil
        }
        let renderCommandEncoder = self.renderCommandEncoder()
        guard let pipelineState = deviceImpl.indexedIndirectBufferClampPipeline(UInt(rasterSampleCount)) else {
            return nil
        }
        setClampPipelineState(renderCommandEncoder, pipelineState)
        let indexBufferCount = UInt32(truncatingIfNeeded: (UInt(mtlIndexBuffer.length) &- work.indexBufferOffset) / UInt(indexSize))
        setVertexBuffer(renderCommandEncoder, arguments.buffer, UInt64(arguments.metalOffset), .zero)
        setVertexBuffer(renderCommandEncoder, finalScratch, finalScratchOffset, .one)
        setVertexBuffer(renderCommandEncoder, intermediateScratch, intermediateScratchOffset, .two)
        setVertexBytes(renderCommandEncoder, indexBufferCount, work.bounds.instances.shaderValue, .three)
        renderCommandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        // Device-loss flag lives in intermediateScratch; also retain finalScratch until GPU completion.
        trackIndirectDeviceLostCheck(intermediateScratch, intermediateScratchOffset, finalScratch)
        return indexBufferCount
    }

    // Indexed dispatch 2: read-clamps the final scratch against the index buffer's contents.
    private func clampIndirectIndexBufferDispatch2Batched(_ device: borrowing WebGPU.Metal.Device, _ work: IndirectEncodeWork) {
        guard let mtlIndexBuffer = work.indexBuffer?.buffer(), let clamped = work.clamped, let intermediate = work.intermediate else {
            return
        }
        let renderCommandEncoder = self.renderCommandEncoder()
        guard let pipelineState = deviceImpl.indexBufferClampPipeline(work.indexType, UInt(rasterSampleCount)) else {
            return
        }
        setClampPipelineState(renderCommandEncoder, pipelineState)
        setVertexBuffer(renderCommandEncoder, mtlIndexBuffer, UInt64(work.indexBufferOffset), .zero)
        setVertexBuffer(renderCommandEncoder, clamped.buffer, clamped.offset, .one)
        let primitiveOffset = Self.primitiveOffset(work.primitiveType)
        setVertexBytes(
            renderCommandEncoder,
            work.bounds.vertices.indexClampVertexCount(primitiveOffset: primitiveOffset),
            primitiveOffset,
            work.indexBufferCount &- 1,
            .two
        )
        renderCommandEncoder?.drawPrimitives(.point, clamped: intermediate)
    }

    // MARK: Bundles

    // The validation and ICB-encoding half of executeBundles. Returns false where it returned early.
    private func encodeBundles(_ bundles: [(shell: WebGPU.Metal.RenderBundle, impl: RenderBundleImpl)]) -> Bool {
        var commandEncoder = renderCommandEncoder()
        let minDepth = viewportMinDepth
        let maxDepth = viewportMaxDepth

        // Run in two phases across ALL bundles so the whole call needs at most one memory barrier: first
        // validate every bundle and GPU-encode its ICB slots, then a single barrier, then execute every
        // bundle's ICB. Per-bundle encode→barrier→execute would emit one barrier per bundle.
        var needsBarrierBeforeExecute = false
        // Indirect draws across all bundles are collected here and processed in phases after the bundle loop
        // (all dispatch-1s → barrier → all dispatch-2s → barrier → all ICB encodes). Each draw uses its own
        // scratch, so draws never conflict and need no per-draw barrier.
        var indirectWork: [IndirectEncodeWork] = []
        for bundle in bundles {
            let bundleImpl = bundle.impl
            if !isValidToUse(bundleImpl.isValid(), bundleImpl.deviceImpl, with: deviceImpl) {
                let reason = bundleImpl.lastError().map { "\($0)" } ?? "(null)"
                makeInvalid("executeBundles: render bundle is not valid, reason = \(reason)")
                return false
            }

            if bundleImpl.makeSubmitInvalid() {
                parentImpl.makeSubmitInvalid(nil)
                return false
            }

            bundleImpl.updateMinMaxDepths(device, minDepth, maxDepth)

            if !bundleImpl.validateRenderPass(attachments) {
                makeInvalid("executeBundles: validation failed")
                return false
            }

            commandEncoder = renderCommandEncoder()
            parentImpl.addCommitAction(.rebindBundleSamplers(bundle.shell, bundleImpl))
            if bundleImpl.requiresCommandReplay() {
                continue
            }

            var lostTheDevice = false
            for icb in bundleImpl.icbs {
                let icbIdentifier = icb.indirectCommandBuffer.gpuResourceID._impl
                icb.indexValidations.forEachInWTFOrder { _, data in
                    guard !lostTheDevice else {
                        return
                    }
                    let indexBuffer = data.indexBufferImpl
                    let indexData = data.indexData
                    let primitiveOffset: UInt32 =
                        indexData.primitiveType == UInt32(MTLPrimitiveType.lineStrip.rawValue)
                            || indexData.primitiveType == UInt32(MTLPrimitiveType.triangleStrip.rawValue) ? 1 : 0
                    let effectiveMinVertexCount = data.vertices.effectiveVertexCount(baseVertex: indexData.baseVertex)
                    let key = BufferImpl.drawIndexKey(
                        firstIndex: indexData.firstIndex,
                        indexCount: indexData.indexCount,
                        indexType: data.indexType,
                        primitiveOffset: primitiveOffset,
                        icbResourceID: icbIdentifier
                    )
                    if let entry = indexBuffer.canSkipDrawIndexedValidation(key, vertexCount: effectiveMinVertexCount),
                        !indexBuffer.didReadOOB(icbIdentifier)
                    {
                        indexBuffer.skippedDrawIndexedValidation(parentImpl, key, vertexCount: entry.vertexCount)
                        return
                    }

                    let indirectCommandBufferContainer = icb.indirectCommandBufferContainer
                    if !setClampPipeline(
                        commandEncoder,
                        device,
                        deviceImpl.icbCommandClampPipeline(data.indexType, UInt(rasterSampleCount))
                    ) {
                        lostTheDevice = true
                        return
                    }
                    setVertexBytes(commandEncoder, indexData, .zero)
                    parentImpl.addBuffer(indirectCommandBufferContainer)
                    setVertexBuffer(commandEncoder, indirectCommandBufferContainer, 0, .one)
                    let mtlIndexBuffer = indexBuffer.buffer()
                    parentImpl.addBuffer(mtlIndexBuffer)
                    if let mtlIndexBuffer {
                        commandEncoder?.useResource(mtlIndexBuffer, usage: .read, stages: .vertex)
                    }
                    parentImpl.addICB(icb.indirectCommandBuffer)
                    commandEncoder?.useResource(icb.indirectCommandBuffer, usage: [.read, .write], stages: .vertex)
                    parentImpl.addBuffer(icb.outOfBoundsReadFlag)
                    if let outOfBoundsReadFlag = icb.outOfBoundsReadFlag {
                        commandEncoder?.useResource(outOfBoundsReadFlag, usage: .write, stages: .vertex)
                    }
                    commandEncoder?.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(indexData.indexCount))

                    WebGPU.Metal.registerICBIndexValidationCompletion(
                        parentEncoder,
                        device,
                        data.indexBuffer,
                        indexData.firstIndex,
                        indexData.indexCount,
                        effectiveMinVertexCount,
                        data.indexType,
                        primitiveOffset,
                        indexBuffer.indexContentsGeneration(),
                        icb.indirectCommandBuffer,
                        icb.outOfBoundsReadFlag
                    )
                    needsBarrierBeforeExecute = true
                }
                if lostTheDevice {
                    return false
                }
            }

            // Collect this bundle's indirect draws for phased processing. A draw whose indirect+index
            // buffers are unchanged since it was last encoded is skipped wholesale (contentsGeneration cache).
            for icb in bundleImpl.icbs {
                icb.indirectDraws.forEachInWTFOrder { slotIndex, data in
                    let indirectBuffer = data.indirectBufferImpl
                    if indirectBuffer.isDestroyed() {
                        return
                    }
                    let indexBuffer = data.indexBufferImpl
                    if data.isIndexed, let indexBuffer, indexBuffer.isDestroyed() {
                        return
                    }

                    let indirectGeneration = indirectBuffer.contentsGeneration()
                    let indexGeneration = indexBuffer?.indexContentsGeneration() ?? 0
                    if data.encodedAtLeastOnce && data.lastIndirectGeneration == indirectGeneration
                        && data.lastIndexGeneration == indexGeneration
                    {
                        return
                    }

                    indirectWork.append(
                        IndirectEncodeWork(
                            icb: icb,
                            slotIndex: slotIndex,
                            indirectBuffer: indirectBuffer,
                            indexBuffer: indexBuffer,
                            indirectOffset: data.indirectOffset,
                            bounds: data.bounds,
                            indexType: data.indexType,
                            indexBufferOffset: data.indexBufferOffset,
                            primitiveType: data.primitiveType,
                            isIndexed: data.isIndexed,
                            indirectGeneration: indirectGeneration,
                            indexGeneration: indexGeneration,
                            clampsIndexValues: data.isIndexed && data.bounds.clampsIndexValues
                        )
                    )
                }
            }
        }

        // Phase A: run every draw's dispatch-1 (indexed) / single dispatch (non-indexed) into its own per-draw scratch.
        // No barriers here.
        var anyClampDispatched = false
        for index in indirectWork.indices {
            commandEncoder = renderCommandEncoder()
            if commandEncoder == nil {
                break
            }
            let work = indirectWork[index]
            if work.isIndexed {
                var finalScratchOffset: UInt64 = 0
                var intermediateScratchOffset: UInt64 = 0
                let finalScratch = WebGPU.Metal.newZeroedDrawIndexedIndirectScratch(device, &finalScratchOffset)
                let intermediateScratch = WebGPU.Metal.newZeroedDrawIndirectScratch(device, &intermediateScratchOffset)
                guard let finalScratch, let intermediateScratch else {
                    continue
                }
                guard
                    let indexBufferCount = clampIndirectIndexBufferDispatch1Batched(
                        device,
                        work,
                        finalScratch,
                        finalScratchOffset,
                        intermediateScratch,
                        intermediateScratchOffset
                    )
                else {
                    continue
                }
                indirectWork[index].clamped = ClampedIndirectArguments(finalScratch, finalScratchOffset)
                indirectWork[index].intermediate = ClampedIndirectArguments(intermediateScratch, intermediateScratchOffset)
                indirectWork[index].indexBufferCount = indexBufferCount
                parentImpl.addBuffer(finalScratch)
                parentImpl.addBuffer(intermediateScratch)
            } else {
                var finalScratchOffset: UInt64 = 0
                guard let finalScratch = WebGPU.Metal.newZeroedDrawIndirectScratch(device, &finalScratchOffset) else {
                    continue
                }
                if !clampIndirectBufferDispatchBatched(device, work, finalScratch, finalScratchOffset) {
                    continue
                }
                indirectWork[index].clamped = ClampedIndirectArguments(finalScratch, finalScratchOffset)
                parentImpl.addBuffer(finalScratch)
            }
            anyClampDispatched = true
            needsBarrierBeforeExecute = true
        }

        // Barrier between all dispatch-1s and all indexed dispatch-2s (dispatch-2 reads dispatch-1's output).
        if indirectWork.contains(where: { $0.clampsIndexValues && $0.intermediate != nil }) {
            emitMemoryBarrier(commandEncoder)
            if splitRenderPass() {
                commandEncoder = renderCommandEncoder()
            }
        }

        // Phase B: run every indexed draw's dispatch-2 (per-index bounds clamp). No barriers.
        for work in indirectWork where work.clampsIndexValues && work.intermediate != nil {
            commandEncoder = renderCommandEncoder()
            if commandEncoder == nil {
                break
            }
            clampIndirectIndexBufferDispatch2Batched(device, work)
        }

        // Barrier between the clamp dispatches and the ICB encode kernels that read their clamped output.
        if anyClampDispatched {
            emitMemoryBarrier(commandEncoder)
            if splitRenderPass() {
                commandEncoder = renderCommandEncoder()
            }
        }

        // Phase C: GPU-encode each indirect draw into its ICB slot from its clamped scratch. No barriers between
        // encodes — each writes a distinct ICB slot.
        for work in indirectWork {
            commandEncoder = renderCommandEncoder()
            guard let commandEncoder else {
                break
            }
            guard let clamped = work.clamped else {
                continue
            }
            let clampedArgs = clamped.buffer
            let clampedArgsOffset = clamped.offset

            if !setClampPipeline(
                commandEncoder,
                device,
                deviceImpl.icbIndirectEncodePipeline(work.isIndexed, work.indexType, UInt(rasterSampleCount))
            ) {
                return false
            }

            parentImpl.addBuffer(clampedArgs)
            setVertexBuffer(commandEncoder, clampedArgs, clampedArgsOffset, .zero)
            commandEncoder.useResource(clampedArgs, usage: .read, stages: .vertex)

            let icb = work.icb
            let indirectCommandBufferContainer = icb.indirectCommandBufferContainer
            parentImpl.addBuffer(indirectCommandBufferContainer)
            setVertexBuffer(commandEncoder, indirectCommandBufferContainer, 0, .one)

            if work.isIndexed {
                guard let mtlIndexBuffer = work.indexBuffer?.buffer() else {
                    continue
                }
                let indexSizeInBytes: UInt = work.indexType == .uint16 ? 2 : 4
                parentImpl.addBuffer(mtlIndexBuffer)
                setVertexBuffer(commandEncoder, mtlIndexBuffer, 0, .two)
                commandEncoder.useResource(mtlIndexBuffer, usage: .read, stages: .vertex)
                setVertexBytes(
                    commandEncoder,
                    UInt32(truncatingIfNeeded: work.slotIndex),
                    UInt32(truncatingIfNeeded: work.primitiveType.rawValue),
                    UInt32(truncatingIfNeeded: work.indexBufferOffset / indexSizeInBytes),
                    .three
                )
            } else {
                setVertexBytes(
                    commandEncoder,
                    UInt32(truncatingIfNeeded: work.slotIndex),
                    UInt32(truncatingIfNeeded: work.primitiveType.rawValue),
                    .two
                )
            }

            parentImpl.addICB(icb.indirectCommandBuffer)
            commandEncoder.useResource(icb.indirectCommandBuffer, usage: [.read, .write], stages: .vertex)
            parentImpl.addBuffer(icb.outOfBoundsReadFlag)
            if let outOfBoundsReadFlag = icb.outOfBoundsReadFlag {
                commandEncoder.useResource(outOfBoundsReadFlag, usage: .write, stages: .vertex)
            }

            commandEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            icb.indirectDraws.modifyValue(forKey: work.slotIndex) { data in
                data.encodedAtLeastOnce = true
                data.lastIndirectGeneration = work.indirectGeneration
                data.lastIndexGeneration = work.indexGeneration
            }
            needsBarrierBeforeExecute = true
        }

        // Single barrier: order every ICB write before every executeCommandsInBuffer: in replayBundle().
        if needsBarrierBeforeExecute {
            emitMemoryBarrier(commandEncoder)
            if splitRenderPass() {
                commandEncoder = renderCommandEncoder()
            }
        }

        return true
    }

    // The per-bundle replay half of executeBundles.
    private func replayBundle(_ bundle: (shell: WebGPU.Metal.RenderBundle, impl: RenderBundleImpl)) {
        useAndTrack(bundle.impl.resources) { bundle.impl.mtlResources[$0] }

        for icb in bundle.impl.icbs {
            let commandEncoder = renderCommandEncoder()

            if let depthStencilState = icb.depthStencilState {
                commandEncoder?.setDepthStencilState(depthStencilState)
            }
            commandEncoder?.setCullMode(icb.cullMode)
            commandEncoder?.setFrontFacing(icb.frontFace)
            commandEncoder?.setDepthClipMode(icb.depthClipMode)
            commandEncoder?.setDepthBias(icb.depthBias, slopeScale: icb.depthBiasSlopeScale, clamp: icb.depthBiasClamp)

            let indirectCommandBuffer = icb.indirectCommandBuffer
            renderCommandEncoder()?.executeCommandsInBuffer(indirectCommandBuffer, range: 0..<indirectCommandBuffer.size)
        }

        ignoreBufferCache = true
        bundle.impl.replayCommands(into: self)
        ignoreBufferCache = false
        // The bundle's commands set states of their own.
        drawState = DrawStateCache()
    }

    // The closing reset of executeBundles.
    private func resetBindingsAfterBundles() {
        currentPipeline.removeAll()
        currentPipelineImpl = nil
        maxVertexBufferSlot = 0
        for index in vertexBuffers.indices {
            vertexBuffers[index] = VertexBufferBinding()
        }
        bindGroups.removeAll()
        bindGroupDynamicOffsets.removeAll()
        boundGroupIdentities = SIMD32()
        groupsWithDynamicOffsets = 0
        bindGroupDynamicOffsetsChanged = allBindGroupsMask
        vertexDynamicOffsets.removeAll(keepingCapacity: true)
        priorVertexDynamicOffsets.removeAll(keepingCapacity: true)
        fragmentDynamicOffsets.removeAll(keepingCapacity: true)
        priorFragmentDynamicOffsets.removeAll(keepingCapacity: true)
        indexBuffer.removeAll()
        indexBufferImpl = nil
        maxBindGroupSlot = 0
        existingVertexBuffers.removeAll()
        existingFragmentBuffers.removeAll()
        maxDynamicOffsetAtIndex = SIMD32()
    }

    @_expose(Cxx)
    func appendPendingBundle(_ bundle: borrowing WebGPU.Metal.RenderBundle, _ bundleImpl: RenderBundleImpl) {
        pendingBundles.append((shell: copy bundle, impl: bundleImpl))
    }

    @_expose(Cxx)
    func executeBundles() {
        let bundles = pendingBundles
        pendingBundles = []
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::executeBundles(std::span<const Ref<WebGPU::RenderBundle>>): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        // Metal only writes the visibility result of an active occlusion query when a draw call runs
        // inside it, so a bundle that issues one makes the explicit zero fill in endPass unnecessary.
        // Bundles that issue no draw call have to keep it: without the fill the query would resolve to
        // whatever an earlier pass wrote to that slot rather than to zero.
        if bundles.contains(where: { $0.impl.drawCount() != 0 || !$0.impl.icbs.isEmpty }) {
            visibilityResultWillBeWritten()
        }
        applyCachedRenderPassState(renderCommandEncoder())

        if !encodeBundles(bundles) {
            return
        }

        for bundle in bundles {
            // Truncates the bundle's 64-bit draw count.
            incrementDrawCount(UInt32(truncatingIfNeeded: bundle.impl.drawCount()))
            replayBundle(bundle)
        }

        resetBindingsAfterBundles()
    }

    // MARK: WebGPU::RenderPassEncoder
    // Each "failed as encoding has finished" message names the entry point with its C++ __PRETTY_FUNCTION__ spelling.

    @_expose(Cxx)
    func draw(_ vertexCount: UInt32, _ instanceCount: UInt32, _ firstVertex: UInt32, _ firstInstance: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::draw(uint32_t, uint32_t, uint32_t, uint32_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        let (vertices, verticesOverflowed) = vertexCount.multipliedReportingOverflow(by: instanceCount)
        if verticesOverflowed || vertices > maxVerticesPerDrawCall {
            deviceImpl.loseTheDevice(.Unknown)
            return
        }

        let pipelineImpl = currentPipelineImpl
        let needsValidationLayerWorkaround = pipelineImpl.map { minimumVertexInstanceCounts($0).needsValidationLayerWorkaround } ?? false
        if !executePreDrawCommands(passWasSplit: false, indirectBuffer: nil, needsValidationLayerWorkaround: needsValidationLayerWorkaround)
        {
            return
        }
        runVertexBufferValidation(pipelineImpl, vertexCount, instanceCount, firstVertex, firstInstance)
        // Nothing to draw, or first + count overflows.
        if instanceCount == 0 || vertexCount == 0 || instanceCount &+ firstInstance < firstInstance
            || vertexCount &+ firstVertex < firstVertex
        {
            return
        }

        renderCommandEncoder()?
            .drawPrimitives(
                type: pipelineImpl?.parameters.primitiveType ?? .triangle,
                vertexStart: Int(nsUInteger: firstVertex),
                vertexCount: Int(nsUInteger: vertexCount),
                instanceCount: Int(nsUInteger: instanceCount),
                baseInstance: Int(nsUInteger: firstInstance)
            )
    }

    @_expose(Cxx)
    func drawIndexed(_ indexCount: UInt32, _ instanceCount: UInt32, _ firstIndex: UInt32, _ baseVertex: Int32, _ firstInstance: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::drawIndexed(uint32_t, uint32_t, uint32_t, int32_t, uint32_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        let indexSizeInBytes: UInt = indexType == .uint16 ? 2 : 4
        let (firstIndexOffsetInBytes, firstIndexOffsetOverflowed) = UInt(firstIndex).multipliedReportingOverflow(by: indexSizeInBytes)
        let (indexBufferOffsetInBytes, indexBufferOffsetOverflowed) = indexBufferOffset.addingReportingOverflow(firstIndexOffsetInBytes)
        if firstIndexOffsetOverflowed || indexBufferOffsetOverflowed {
            makeInvalid("Invalid offset to drawIndexed")
            return
        }

        if let error = errorValidatingDrawIndexed() {
            makeInvalid(error)
            return
        }

        let (indexCountInBytes, indexCountInBytesOverflowed) = indexSizeInBytes.multipliedReportingOverflow(by: UInt(indexCount))
        let (lastIndexOffset, lastIndexOffsetOverflowed) = firstIndexOffsetInBytes.addingReportingOverflow(indexCountInBytes)
        if indexCountInBytesOverflowed || lastIndexOffsetOverflowed || lastIndexOffset > indexBufferSize {
            makeInvalid("Values to drawIndexed are invalid")
            return
        }

        // Checked only once the draw is otherwise valid: an out-of-range indexCount is a validation
        // error the page can catch, and must not be escalated to losing the device.
        let (vertices, verticesOverflowed) = indexCount.multipliedReportingOverflow(by: instanceCount)
        if verticesOverflowed || vertices > maxVerticesPerDrawCall {
            deviceImpl.loseTheDevice(.Unknown)
            return
        }

        if !runIndexBufferValidation(firstInstance, instanceCount) {
            return
        }

        // errorValidatingDrawIndexed() has checked that there is a pipeline and an index buffer.
        guard let pipelineImpl = currentPipelineImpl else {
            return
        }
        let counts = minimumVertexInstanceCounts(pipelineImpl)
        let clamp = clampIndexBufferToValidValues(
            indexCount,
            instanceCount,
            baseVertex,
            firstInstance,
            indexType,
            indexBufferOffsetInBytes,
            indexBuffer,
            indexBufferImpl,
            counts,
            rasterSampleCount,
            primitiveType
        )
        var passWasSplit = false
        if case .indirectDraw = clamp {
            passWasSplit = splitRenderPass()
        }

        if !executePreDrawCommands(
            passWasSplit: passWasSplit,
            indirectBuffer: nil,
            needsValidationLayerWorkaround: counts.needsValidationLayerWorkaround
        ) {
            return
        }

        if instanceCount == 0 || indexCount == 0 || indexBufferImpl?.isDestroyed() == true {
            return
        }

        let mtlIndexBuffer = indexBufferImpl?.buffer()
        switch clamp {
        case .indirectDraw(let arguments):
            if UInt(mtlIndexBuffer?.length ?? 0) / indexSizeInBytes < verticesPerPrimitive(primitiveType) {
                return
            }
            // The clamp's scratch buffer is nil only if its allocation failed.
            guard let mtlIndexBuffer, let arguments else {
                return
            }
            renderCommandEncoder()?
                .drawIndexedPrimitives(
                    primitiveType,
                    indexType: indexType,
                    indexBuffer: mtlIndexBuffer,
                    indexBufferOffset: 0,
                    clamped: arguments
                )
        case .draw:
            // The clamp skips the draw when the index buffer has no MTLBuffer.
            guard let mtlIndexBuffer else {
                return
            }
            renderCommandEncoder()?
                .drawIndexedPrimitives(
                    type: primitiveType,
                    indexCount: Int(indexCount),
                    indexType: indexType,
                    indexBuffer: mtlIndexBuffer,
                    indexBufferOffset: Int(truncatingIfNeeded: indexBufferOffsetInBytes),
                    instanceCount: Int(nsUInteger: instanceCount),
                    baseVertex: Int(baseVertex),
                    baseInstance: Int(nsUInteger: firstInstance)
                )
        case .skip:
            break
        }
    }

    @_expose(Cxx)
    func drawIndexedIndirect(_ indirectBuffer: BufferImpl, _ indirectOffset: UInt64) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::drawIndexedIndirect(Buffer &, uint64_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        if !isValidToUse(indirectBuffer.isValid(), indirectBuffer.deviceImpl, with: deviceImpl) {
            makeInvalid("drawIndexedIndirect: buffer was invalid")
            return
        }
        indirectBuffer.setCommandEncoder(parentImpl, mayModifyBuffer: false)
        if indirectBuffer.isDestroyed() {
            return
        }

        if indexBufferImpl == nil {
            makeInvalid("drawIndexedIndirect: index buffer is nil")
            return
        }

        if let error = errorValidatingDrawIndexed() {
            makeInvalid(error)
            return
        }

        let mtlIndexBuffer = indexBufferImpl?.buffer()
        let indexBufferLength = UInt(mtlIndexBuffer?.length ?? 0)
        if indexBufferLength == 0 {
            return
        }

        if !bufferUsage(indirectBuffer, contains: .Indirect) || indirectOffset % 4 != 0 {
            makeInvalid("drawIndexedIndirect: validation failed")
            return
        }

        let argumentsSize = UInt64(MemoryLayout<MTLDrawIndexedPrimitivesIndirectArguments>.size)
        let (indirectOffsetSum, indirectOffsetOverflowed) = indirectOffset.addingReportingOverflow(argumentsSize)
        if indirectOffsetOverflowed || indirectBuffer.initialSize() < indirectOffsetSum {
            makeInvalid("drawIndexedIndirect: validation failed")
            return
        }

        // errorValidatingDrawIndexed() has checked that there is a pipeline.
        guard let pipelineImpl = currentPipelineImpl else {
            return
        }
        let counts = minimumVertexInstanceCounts(pipelineImpl)
        let arguments = IndirectArgumentsRange(indirectBuffer, offset: indirectOffset, argumentsSize: Int(argumentsSize))
        let clamped = clampIndirectIndexBufferToValidValues(
            indexBufferImpl,
            arguments,
            indexType,
            indexBufferOffset,
            counts,
            primitiveType,
            rasterSampleCount
        )
        let splitEncoder = clamped != nil && splitRenderPass()

        // Range-check offset + size, not size alone: the args now sit at a non-zero offset in pooled scratch.
        // Also rejects a failed clamp.
        if !executePreDrawCommands(
            passWasSplit: splitEncoder,
            indirectBuffer: indirectBuffer,
            needsValidationLayerWorkaround: counts.needsValidationLayerWorkaround
        ) || indexBufferImpl?.isDestroyed() == true || !(clamped?.fits(argumentsSize) ?? false) {
            return
        }

        let indexSizeInBytes: UInt = indexType == .uint16 ? 2 : 4
        if indexBufferOffset > indexBufferLength
            || (indexBufferLength - indexBufferOffset) / indexSizeInBytes < verticesPerPrimitive(primitiveType)
        {
            return
        }
        guard let mtlIndexBuffer, let clamped else {
            return
        }
        renderCommandEncoder()?
            .drawIndexedPrimitives(
                primitiveType,
                indexType: indexType,
                indexBuffer: mtlIndexBuffer,
                indexBufferOffset: Int(truncatingIfNeeded: indexBufferOffset),
                clamped: clamped
            )
    }

    @_expose(Cxx)
    func drawIndirect(_ indirectBuffer: BufferImpl, _ indirectOffset: UInt64) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::drawIndirect(Buffer &, uint64_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        if !isValidToUse(indirectBuffer.isValid(), indirectBuffer.deviceImpl, with: deviceImpl) {
            makeInvalid("drawIndirect: buffer was invalid")
            return
        }
        indirectBuffer.setCommandEncoder(parentImpl, mayModifyBuffer: false)
        if indirectBuffer.isDestroyed() {
            return
        }
        if !bufferUsage(indirectBuffer, contains: .Indirect) || indirectOffset % 4 != 0 {
            makeInvalid("drawIndirect: validation failed")
            return
        }

        let argumentsSize = UInt64(MemoryLayout<MTLDrawPrimitivesIndirectArguments>.size)
        let (indirectOffsetSum, indirectOffsetOverflowed) = indirectOffset.addingReportingOverflow(argumentsSize)
        if indirectOffsetOverflowed || indirectBuffer.initialSize() < indirectOffsetSum {
            makeInvalid("drawIndirect: validation failed")
            return
        }

        // Without a pipeline nothing is clamped, and executePreDrawCommands fails.
        var needsValidationLayerWorkaround = false
        var clamped: ClampedIndirectArguments?
        if let pipelineImpl = currentPipelineImpl {
            let counts = minimumVertexInstanceCounts(pipelineImpl)
            needsValidationLayerWorkaround = counts.needsValidationLayerWorkaround
            clamped = clampIndirectBufferToValidValues(
                IndirectArgumentsRange(indirectBuffer, offset: indirectOffset, argumentsSize: Int(argumentsSize)),
                counts,
                rasterSampleCount
            )
        }
        let splitEncoder = clamped != nil && splitRenderPass()

        // See drawIndexedIndirect.
        if !executePreDrawCommands(
            passWasSplit: splitEncoder,
            indirectBuffer: indirectBuffer,
            needsValidationLayerWorkaround: needsValidationLayerWorkaround
        ) || !(clamped?.fits(argumentsSize) ?? false) || indirectBuffer.isDestroyed() {
            return
        }
        guard let clamped else {
            return
        }

        renderCommandEncoder()?.drawPrimitives(primitiveType, clamped: clamped)
    }

    private func occlusionQueryIsDestroyed() -> Bool {
        visibilityResultBufferSize == UInt.max
    }

    @_expose(Cxx)
    func beginOcclusionQuery(_ initialQueryIndex: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::beginOcclusionQuery(uint32_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        // Wrapping: the byte offset is kept in 32 bits.
        let queryIndex = initialQueryIndex &* UInt32(MemoryLayout<UInt64>.size)
        if occlusionQueryActive || queryBufferIndicesToClear.contains(UInt64(queryIndex)) {
            makeInvalid("beginOcclusionQuery validation failure")
            return
        }
        if UInt(initialQueryIndex) >= visibilityResultBufferSize / UInt(MemoryLayout<UInt64>.size) {
            makeInvalid("beginOcclusionQuery validation failure")
            return
        }

        occlusionQueryActive = true
        visibilityResultBufferOffset = UInt(queryIndex)
        queryBufferIndicesToClear.insert(UInt64(visibilityResultBufferOffset))
        queryBufferIndicesToClearCount = queryBufferIndicesToClear.count

        if occlusionQueryIsDestroyed() {
            return
        }

        if queryBufferUtilizedIndices.contains(UInt64(queryIndex)) {
            return
        }
        renderCommandEncoder()?.setVisibilityResultMode(.counting, offset: Int(queryIndex))
        queryBufferUtilizedIndices.insert(UInt64(queryIndex))
    }

    @_expose(Cxx)
    func endOcclusionQuery() {
        if encodingHasFinished() {
            generateAValidationError("virtual void WebGPU::Metal::RenderPassEncoder::endOcclusionQuery(): failed as encoding has finished")
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        if !occlusionQueryActive {
            makeInvalid("endOcclusionQuery - occlusion query was not active")
            return
        }
        occlusionQueryActive = false

        if occlusionQueryIsDestroyed() {
            return
        }
        renderCommandEncoder()?.setVisibilityResultMode(.disabled, offset: Int(visibilityResultBufferOffset))
    }

    @_expose(Cxx)
    func endPass() {
        if passEnded {
            generateAValidationError("void WebGPU::Metal::RenderPassEncoder::endPass(): failed as pass is already ended")
            return
        }
        passEnded = true

        // https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-end
        // A pass begun while the command encoder was already locked by another pass never took the
        // encoder over. Ending it is a validation error the page can catch, not a silent no-op.
        if encoderStateWasNotOpen {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::endPass(): failed as the command encoder was not open when the pass began"
            )
            return
        }

        // Spelled out rather than encodingHasFinished() because ending a pass hands the command encoder
        // back and only then looks at whether the pass ended in a good state, so every path from here
        // unlocks the encoder. A pass that ended badly invalidates its encoder instead of leaving it
        // locked: a later pass can still be begun on an invalid encoder.
        if !parentImpl.isLocked() || parentImpl.isFinished() {
            backingRenderCommandEncoder = nil
            deferredDescriptor = nil
            generateAValidationError("void WebGPU::Metal::RenderPassEncoder::endPass(): failed as encoding has finished")
            return
        }

        let passIsValid = isValid()
        if debugGroupStackSize != 0 || occlusionQueryActive || !passIsValid {
            // An already-invalidated pass has handed its command encoder back already.
            if let encoder = backingRenderCommandEncoder {
                parentImpl.endEncoding(encoder)
            }
            backingRenderCommandEncoder = nil
            deferredDescriptor = nil
            parentImpl.lock(false)
            parentImpl.makeInvalid(
                "RenderPassEncoder.endPass failure, m_debugGroupStackSize = \(debugGroupStackSize), m_occlusionQueryActive = \(occlusionQueryActive ? 1 : 0), isValid = \(passIsValid ? 1 : 0), error = \(lastErrorString ?? "(null)")"
            )
            return
        }

        // A deferred pass has no encoder, so this compares nil with the command encoder's current one.
        if !parentImpl.isValid() || !parentImpl.encoderIsCurrent(backingRenderCommandEncoder) {
            backingRenderCommandEncoder = nil
            deferredDescriptor = nil
            parentImpl.lock(false)
            parentImpl.makeInvalid("RenderPassEncoder.endPass: the pass no longer holds the command encoder")
            return
        }

        // A pass that never materialized its encoder encoded nothing, so there is no encoder to end. It
        // still owes its timestampWrites a pair of values. CommandEncoder only defers passes whose
        // attachments all load and store and which have no occlusion query, so there is nothing to clear
        // either.
        if let descriptor = deferredDescriptor {
            assert(attachmentsToClear.isEmpty && !clearDepthAttachment && !clearStencilAttachment && queryBufferIndicesToClear.isEmpty)
            deferredDescriptor = nil
            parentImpl.encodeDeferredRenderPassTimestamps(descriptor)
            parentImpl.lock(false)
            return
        }

        if let encoder = backingRenderCommandEncoder {
            parentImpl.endEncoding(encoder)
        }
        clearAttachmentsAfterEndEncoding()

        backingRenderCommandEncoder = nil
        parentImpl.lock(false)

        if !queryBufferIndicesToClear.isEmpty && !occlusionQueryIsDestroyed() {
            let blitCommandEncoder: (any MTLBlitCommandEncoder)? = parentImpl.ensureBlitCommandEncoder()
            if let visibilityResultBuffer {
                for offset in queryBufferIndicesToClear {
                    let start = Int(offset)
                    blitCommandEncoder?.fill(buffer: visibilityResultBuffer, range: start..<(start + MemoryLayout<UInt64>.size), value: 0)
                }
            }

            queryBufferIndicesToClear.removeAll()
            queryBufferIndicesToClearCount = 0
            parentImpl.finalizeBlitCommandEncoder()
        }
    }

    @_expose(Cxx)
    func insertDebugMarker(_ markerLabel: NSString) {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-insertdebugmarker
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::insertDebugMarker(String &&): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        backingRenderCommandEncoder?.insertDebugSignpost(markerLabel as String)
    }

    private func validatePopDebugGroup() -> Bool {
        parentImpl.isLocked() && debugGroupStackSize != 0
    }

    @_expose(Cxx)
    func popDebugGroup() {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-popdebuggroup
        if encodingHasFinished() {
            generateAValidationError("virtual void WebGPU::Metal::RenderPassEncoder::popDebugGroup(): failed as encoding has finished")
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        if !validatePopDebugGroup() {
            makeInvalid("popDebugGroup: validation failed")
            return
        }

        debugGroupStackSize -= 1
        backingRenderCommandEncoder?.popDebugGroup()
    }

    @_expose(Cxx)
    func pushDebugGroup(_ groupLabel: NSString) {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-pushdebuggroup
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::pushDebugGroup(String &&): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        debugGroupStackSize &+= 1
        backingRenderCommandEncoder?.pushDebugGroup(groupLabel as String)
    }

    private func validateGroupIndex(_ groupIndex: UInt32, expectedDynamicOffsetCount: UInt32, _ dynamicOffsetCount: Int?) -> Bool {
        if groupIndex >= limits.maxBindGroups || (dynamicOffsetCount.map { $0 != Int(expectedDynamicOffsetCount) } ?? false) {
            makeInvalid("setBindGroup: groupIndex >= limits.maxBindGroups")
            return false
        }
        return true
    }

    private func markDynamicOffsetsChanged(_ groupIndex: UInt32) {
        precondition(allBindGroupsMask & (1 << groupIndex) != 0)
        bindGroupDynamicOffsetsChanged |= 1 << groupIndex
        maxDynamicOffsetAtIndex[Int(groupIndex)] = 0
    }

    // Returns whether it stored a new bind group Impl, whose shell the shell then hands to storeBindGroupShell.
    @_expose(Cxx)
    func setBindGroup(
        _ groupIndex: UInt32,
        _ groupImpl: BindGroupImpl,
        _ hasDynamicOffsets: Bool,
        _ dynamicOffsetsView: borrowing WebGPU.Metal.DynamicOffsetsView
    ) -> Bool {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::setBindGroup(uint32_t, const BindGroup *, std::optional<std::span<const uint32_t>>): failed as encoding has finished"
            )
            return false
        }
        guard holdsCurrentEncoder() else {
            return false
        }

        let dynamicOffsets = hasDynamicOffsets ? copyDynamicOffsets(dynamicOffsetsView) : nil
        if !validateGroupIndex(
            groupIndex,
            expectedDynamicOffsetCount: groupImpl.layoutImpl?.counts.dynamicBufferCount ?? 0,
            dynamicOffsets?.count
        ) {
            return false
        }

        if !isValidToUse(groupImpl.isValid(), groupImpl.deviceImpl, with: deviceImpl) {
            makeInvalid("setBindGroup: invalid bind group")
            return false
        }

        if groupImpl.layoutImpl == nil {
            makeInvalid("GPURenderPassEncoder.setBindGroup: bind group is nil")
            return false
        }
        // Without dynamic offsets and dynamic buffers there is nothing to check, and maxOffset stays as it is.
        if dynamicOffsets != nil || groupImpl.dynamicBufferCount != 0 {
            var maxOffset = maxDynamicOffsetAtIndex[Int(groupIndex)]
            let error = groupImpl.errorValidatingDynamicOffsets(dynamicOffsets ?? [], maxOffset: &maxOffset)
            maxDynamicOffsetAtIndex[Int(groupIndex)] = maxOffset
            if let error {
                makeInvalid("GPURenderPassEncoder.setBindGroup: \(error)")
                return false
            }
        }

        maxBindGroupSlot = max(groupIndex, maxBindGroupSlot)
        let groupBit = UInt32(1) << groupIndex
        if let dynamicOffsets, !dynamicOffsets.isEmpty {
            bindGroupDynamicOffsets.set(groupIndex, dynamicOffsets)
            groupsWithDynamicOffsets |= groupBit
            markDynamicOffsetsChanged(groupIndex)
        } else if groupsWithDynamicOffsets & groupBit != 0 {
            bindGroupDynamicOffsets.remove(groupIndex)
            groupsWithDynamicOffsets &= ~groupBit
            markDynamicOffsetsChanged(groupIndex)
        }

        useAndTrack(groupImpl.resources) { groupImpl.mtlResources[$0] }

        for binding in groupImpl.samplerBindings {
            parentImpl.addSampler(binding.shell, binding.impl)
        }

        let identity = identityKey(ObjectIdentifier(groupImpl))
        if boundGroupIdentities[Int(groupIndex)] == identity {
            return false
        }
        bindGroups.setImpl(groupIndex, groupImpl)
        boundGroupIdentities[Int(groupIndex)] = identity
        return true
    }

    // The second step of a setBindGroup that returned true: `group` is the shell of the Impl it stored.
    @_expose(Cxx)
    func storeBindGroupShell(_ groupIndex: UInt32, _ group: WebGPU.Metal.BindGroup) {
        bindGroups.storeShell(groupIndex, group)
    }

    // setBindGroup with a null bind group.
    @_expose(Cxx)
    func clearBindGroup(_ groupIndex: UInt32, _ hasDynamicOffsets: Bool, _ dynamicOffsetCount: UInt) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::setBindGroup(uint32_t, const BindGroup *, std::optional<std::span<const uint32_t>>): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        if !validateGroupIndex(groupIndex, expectedDynamicOffsetCount: 0, hasDynamicOffsets ? Int(dynamicOffsetCount) : nil) {
            return
        }

        bindGroups.remove(groupIndex)
        bindGroupDynamicOffsets.remove(groupIndex)
        boundGroupIdentities[Int(groupIndex)] = 0
        groupsWithDynamicOffsets &= ~(UInt32(1) << groupIndex)
        markDynamicOffsetsChanged(groupIndex)
    }

    @_expose(Cxx)
    func setBlendConstant(_ color: WebGPU.Color) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::setBlendConstant(const WebGPU::Color &): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        blendColor = color
    }

    @_expose(!Cxx)
    func errorValidatingPipeline(_ pipelineImpl: RenderPipelineImpl) -> String? {
        if !isValidToUse(pipelineImpl.isValid(), pipelineImpl.deviceImpl, with: deviceImpl) {
            return "setPipeline: invalid RenderPipeline"
        }

        if !pipelineImpl.validateDepthStencilState(depthReadOnly: attachments.depthReadOnly, stencilReadOnly: attachments.stencilReadOnly) {
            return "setPipeline: invalid depth stencil state"
        }

        if let error = pipelineImpl.errorValidatingColorDepthStencilTargets(attachments) {
            return "setPipeline: color and depth targets from pass do not match pipeline - \(error)"
        }

        if pipelineImpl.pipelineLayoutImpl.dynamicOffsetTotal(.fragment)
            .addingReportingOverflow(UInt64(startIndexForFragmentDynamicOffsets)).overflow
        {
            return "setPipeline: invalid size of fragmentDynamicOffsets"
        }

        return nil
    }

    private func resetDynamicOffsets(_ pipelineImpl: RenderPipelineImpl) {
        bindGroupDynamicOffsetsChanged = allBindGroupsMask
        maxDynamicOffsetAtIndex = SIMD32()

        let layoutImpl = pipelineImpl.pipelineLayoutImpl
        Self.fill(&vertexDynamicOffsets, count: Int(layoutImpl.dynamicOffsetTotal(.vertex)))
        Self.fill(&fragmentDynamicOffsets, count: Int(layoutImpl.dynamicOffsetTotal(.fragment)) + startIndexForFragmentDynamicOffsets)
        fragmentDynamicOffsets[2] = pipelineImpl.sampleMask()
    }

    // Returns whether it stored a new pipeline Impl, whose shell the shell then hands to storePipelineShell.
    @_expose(Cxx)
    func setPipeline(_ pipelineImpl: RenderPipelineImpl) -> Bool {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::setPipeline(const RenderPipeline &): failed as encoding has finished"
            )
            return false
        }
        guard holdsCurrentEncoder() else {
            return false
        }

        if let error = errorValidatingPipeline(pipelineImpl) {
            makeInvalid(error)
            return false
        }

        if currentPipelineImpl === pipelineImpl {
            return false
        }

        currentPipelineImpl = pipelineImpl
        resetDynamicOffsets(pipelineImpl)
        return true
    }

    // The second step of a setPipeline that returned true: `pipeline` is currentPipelineImpl's shell.
    @_expose(Cxx)
    func storePipelineShell(_ pipeline: WebGPU.Metal.RenderPipeline) {
        if currentPipeline.isEmpty {
            currentPipeline.append(pipeline)
        } else {
            currentPipeline[0] = pipeline
        }
    }

    @_expose(Cxx)
    func setScissorRect(_ x: UInt32, _ y: UInt32, _ width: UInt32, _ height: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::setScissorRect(uint32_t, uint32_t, uint32_t, uint32_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        if x.addingReportingOverflow(width).overflow || x &+ width > renderTargetWidth || y.addingReportingOverflow(height).overflow
            || y &+ height > renderTargetHeight
        {
            makeInvalid()
            return
        }

        if let map = rasterizationRateMap {
            let physicalSize = map.physicalSize(layer: 0)
            let scissorStart = map.screenCoordinates(physicalCoordinates: MTLCoordinate2DMake(Float(x), Float(y)), layer: 0)
            let scissorEnd = map.screenCoordinates(
                physicalCoordinates: MTLCoordinate2DMake(
                    min(Float(physicalSize.width), Float(x &+ width)),
                    min(Float(physicalSize.height), Float(y &+ height))
                ),
                layer: 0
            )
            let screenSize = map.screenSize
            scissorRect = MTLScissorRect(
                x: Int(truncatingIfNeeded: convertToNSUInteger(scissorStart.x.rounded())),
                y: Int(truncatingIfNeeded: convertToNSUInteger(scissorStart.y.rounded())),
                width: Int(
                    truncatingIfNeeded: min(
                        UInt(truncatingIfNeeded: screenSize.width),
                        convertToNSUInteger((scissorEnd.x - scissorStart.x).rounded())
                    )
                ),
                height: Int(
                    truncatingIfNeeded: min(
                        UInt(truncatingIfNeeded: screenSize.height),
                        convertToNSUInteger((scissorEnd.y - scissorStart.y).rounded())
                    )
                )
            )

            return
        }

        scissorRect = MTLScissorRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    }

    @_expose(Cxx)
    func setStencilReference(_ reference: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::setStencilReference(uint32_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        stencilReferenceValue = reference & 0xFF
    }

    @_expose(Cxx)
    func setViewport(_ x: Float, _ y: Float, _ width: Float, _ height: Float, _ minDepth: Float, _ maxDepth: Float) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderPassEncoder::setViewport(float, float, float, float, float, float): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        // https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-setviewport
        // The viewport is bounded by the device's maximum viewport size, not by the attachment: a viewport
        // larger than the render target is legal, and the origin may be negative. Only rasterization is
        // clipped to the attachment. A NaN passes every comparison.
        let maxViewportSize = Float(limits.maxTextureDimension2D)
        if width < 0 || height < 0 || width > maxViewportSize || height > maxViewportSize
            || x < -2 * maxViewportSize || y < -2 * maxViewportSize
            || x + width > 2 * maxViewportSize - 1 || y + height > 2 * maxViewportSize - 1
            || minDepth < 0 || maxDepth > 1 || minDepth > maxDepth
        {
            makeInvalid("GPURenderPassEncoder.setViewport: viewport is out of bounds")
            return
        }
        viewport = MTLViewport(
            originX: Double(x),
            originY: Double(y),
            width: Double(width),
            height: Double(height),
            znear: Double(minDepth),
            zfar: Double(maxDepth)
        )
        viewportNeedsApplying = true
    }

    // The size, or the rest of the buffer without one; nil when it does not fit.
    private func bufferRangeSize(_ buffer: BufferImpl, _ offset: UInt64, _ hasSize: Bool, _ size: UInt64) -> UInt64? {
        let bufferSize = buffer.initialSize()
        if offset > bufferSize {
            return nil
        }
        let rangeSize = hasSize ? size : bufferSize - offset
        if rangeSize > bufferSize - offset {
            return nil
        }
        return rangeSize
    }

    private func bufferUsage(_ buffer: BufferImpl, contains usage: WebGPU.BufferUsage) -> Bool {
        buffer.usageRawValue() & usage.rawValue != 0
    }

    @_expose(Cxx)
    func setIndexBuffer(
        _ buffer: borrowing WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ format: WebGPU.IndexFormat,
        _ offset: UInt64,
        _ hasSize: Bool,
        _ size: UInt64
    ) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::setIndexBuffer(Buffer &, WebGPU::IndexFormat, uint64_t, std::optional<uint64_t>): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        if !isValidToUse(bufferImpl.isValid(), bufferImpl.deviceImpl, with: deviceImpl) {
            makeInvalid("setIndexBuffer: invalid buffer")
            return
        }

        bufferImpl.setCommandEncoder(parentImpl, mayModifyBuffer: false)
        if bufferImpl.isDestroyed() {
            return
        }

        let indexSizeInBytes: UInt64 = format == .Uint16 ? 2 : 4
        if !bufferUsage(bufferImpl, contains: .Index) || offset % indexSizeInBytes != 0 {
            makeInvalid("setIndexBuffer: validation failed")
            return
        }

        guard let rangeSize = bufferRangeSize(bufferImpl, offset, hasSize, size) else {
            makeInvalid("setIndexBuffer: computed size overflows")
            return
        }

        if indexBuffer.isEmpty {
            indexBuffer.append(copy buffer)
        } else {
            indexBuffer[0] = copy buffer
        }
        indexBufferImpl = bufferImpl
        indexBufferSize = UInt(truncatingIfNeeded: rangeSize)
        indexType = format == .Uint32 ? .uint32 : .uint16
        indexBufferOffset = UInt(truncatingIfNeeded: offset)
        addInputBufferUsage(bufferImpl)
    }

    @_expose(Cxx)
    func setVertexBuffer(_ slot: UInt32, _ bufferImpl: BufferImpl, _ offset: UInt64, _ hasSize: Bool, _ size: UInt64) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::setVertexBuffer(uint32_t, const Buffer *, uint64_t, std::optional<uint64_t>): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        bufferImpl.setCommandEncoder(parentImpl, mayModifyBuffer: false)
        if !isValidToUse(bufferImpl.isValid(), bufferImpl.deviceImpl, with: deviceImpl) {
            makeInvalid("setVertexBuffer: invalid buffer")
            return
        }

        if bufferImpl.isDestroyed() {
            return
        }

        guard let rangeSize = bufferRangeSize(bufferImpl, offset, hasSize, size) else {
            makeInvalid("setVertexBuffer: size overflowed")
            return
        }

        if slot >= limits.maxVertexBuffers || !bufferUsage(bufferImpl, contains: .Vertex) || offset % 4 != 0 {
            makeInvalid("setVertexBuffer: validation failed")
            return
        }

        maxVertexBufferSlot = max(slot, maxVertexBufferSlot)
        let mtlBuffer = bufferImpl.buffer()
        let bufferLength = UInt64(mtlBuffer?.length ?? 0)
        vertexBuffers[Int(slot)] = VertexBufferBinding(buffer: mtlBuffer, offset: offset, size: rangeSize)
        if offset == bufferLength && rangeSize == 0 {
            return
        }
        if offset >= bufferLength {
            makeInvalid("setVertexBuffer: buffer length is invalid")
            return
        }
        addInputBufferUsage(bufferImpl)
    }

    // setVertexBuffer with a null buffer.
    @_expose(Cxx)
    func clearVertexBuffer(_ slot: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::RenderPassEncoder::setVertexBuffer(uint32_t, const Buffer *, uint64_t, std::optional<uint64_t>): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }

        // maxBindGroupsPlusVertexBuffers is below metalBufferSlotCount, so the slot is inside the table.
        if slot <= limits.maxBindGroupsPlusVertexBuffers {
            vertexBuffers[Int(slot)] = VertexBufferBinding()
        }
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString) {
        backingRenderCommandEncoder?.label = label as String
    }

    // MARK: Splitting the pass

    // Ends the MTLRenderCommandEncoder and continues the pass in a new one once the memory barriers run out,
    // carrying the pass state over. Called by the clamping draws and by RenderBundleEncoderImpl.
    @_expose(!Cxx)
    func splitRenderPass() -> Bool {
        guard memoryBarrierCount >= limits.memoryBarrierLimit, let encoder = backingRenderCommandEncoder else {
            return false
        }

        memoryBarrierCount = 0
        WebGPU.Metal.logRenderPassSplit()
        priorVertexDynamicOffsets.removeAll(keepingCapacity: true)
        priorFragmentDynamicOffsets.removeAll(keepingCapacity: true)

        parentImpl.endEncoding(encoder)
        if drawCount != 0 {
            for i in 0..<attachments.colorViewIndices.count {
                metalDescriptor?.colorAttachments[i].loadAction = .load
            }
            metalDescriptor?.depthAttachment.loadAction = .load
            metalDescriptor?.stencilAttachment.loadAction = .load
        }

        backingRenderCommandEncoder = parentImpl.makeRenderCommandEncoder(metalDescriptor)
        drawState = DrawStateCache()
        if let viewport {
            backingRenderCommandEncoder?.setViewport(viewport)
        }
        if let blendColor {
            backingRenderCommandEncoder?
                .setBlendColor(red: Float(blendColor.r), green: Float(blendColor.g), blue: Float(blendColor.b), alpha: Float(blendColor.a))
        }
        if let stencilReferenceValue {
            backingRenderCommandEncoder?.setStencilReferenceValue(stencilReferenceValue)
        }
        if let scissorRect {
            backingRenderCommandEncoder?.setScissorRect(scissorRect)
        }
        if !currentPipeline.isEmpty, let pipelineImpl = currentPipelineImpl {
            let pipeline = currentPipeline[0]
            currentPipeline.removeAll()
            currentPipelineImpl = nil
            if setPipeline(pipelineImpl) {
                storePipelineShell(pipeline)
            }
        }

        existingVertexBuffers.removeAll()
        existingFragmentBuffers.removeAll()
        bindGroupDynamicOffsetsChanged = allBindGroupsMask
        maxDynamicOffsetAtIndex = SIMD32()

        return true
    }
}

// A depth16unorm clear value, nudged so that it quantizes as Metal expects.
func quantizedDepthValue(_ depthClearValue: Double, _ format: WebGPU.TextureFormat) -> Double {
    if depthClearValue < 0 || depthClearValue > 1 || format != .Depth16unorm {
        return depthClearValue
    }
    let value = Float(depthClearValue + 0.5 / Double(UInt16.max))
    if value < 1 {
        return Double(value.nextUp)
    }
    if value > 1 {
        return Double(value.nextDown)
    }
    return Double(value)
}

private func verticesPerPrimitive(_ primitiveType: MTLPrimitiveType) -> UInt {
    switch primitiveType {
    case .point:
        return 1
    case .line, .lineStrip:
        return 2
    case .triangle, .triangleStrip:
        return 3
    @unknown default:
        fatalError("Unexpected primitive type value")
    }
}

// Converts without trapping, as arm64 does: NaN and negative values become 0, too-large values saturate.
private func convertToNSUInteger(_ value: Float) -> UInt {
    if value.isNaN || value <= 0 {
        return 0
    }
    if value >= Float(UInt.max) {
        return UInt.max
    }
    return UInt(value)
}

@_expose(Cxx)
func makeRenderPassEncoderImpl(
    _ renderCommandEncoder: (any MTLRenderCommandEncoder)?,
    _ metalDescriptor: MTLRenderPassDescriptor?,
    _ rasterizationRateMap: (any MTLRasterizationRateMap)?,
    _ visibilityResultBuffer: (any MTLBuffer)?,
    _ parameters: WebGPU.Metal.RenderPassEncoderParameters,
    _ parentEncoder: WebGPU.Metal.CommandEncoder,
    _ parentImpl: CommandEncoderImpl,
    _ device: WebGPU.Metal.Device
) -> RenderPassEncoderImpl {
    let impl = RenderPassEncoderImpl(
        renderCommandEncoder: renderCommandEncoder,
        metalDescriptor: metalDescriptor,
        rasterizationRateMap: rasterizationRateMap,
        visibilityResultBuffer: visibilityResultBuffer,
        parameters: parameters,
        parentEncoder: parentEncoder,
        parentImpl: parentImpl,
        device: device,
        lastErrorString: nil
    )
    parentImpl.lock(true)
    return impl
}

@_expose(Cxx)
func makeInvalidRenderPassEncoderImpl(
    _ parentEncoder: WebGPU.Metal.CommandEncoder,
    _ parentImpl: CommandEncoderImpl,
    _ device: WebGPU.Metal.Device,
    _ errorString: NSString?
) -> RenderPassEncoderImpl {
    let impl = RenderPassEncoderImpl(
        renderCommandEncoder: nil,
        metalDescriptor: nil,
        rasterizationRateMap: nil,
        visibilityResultBuffer: nil,
        parameters: WebGPU.Metal.RenderPassEncoderParameters(),
        parentEncoder: parentEncoder,
        parentImpl: parentImpl,
        device: device,
        lastErrorString: errorString as String?
    )
    parentImpl.lock(true)
    parentImpl.setLastError(errorString as String?)
    return impl
}
