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
import WebGPU_Internal.BindableResource
import WebGPU_Internal.Buffer
import WebGPU_Internal.CommandEncoder
import WebGPU_Internal.Device
import WebGPU_Internal.PipelineLayout
import WebGPU_Internal.Queue
import WebGPU_Internal.RenderBundle
import WebGPU_Internal.RenderBundleEncoder
import WebGPU_Internal.RenderPassEncoder
import WebGPU_Internal.RenderPipeline
import WebGPU_Private.WebGPUCpp

private let maxCommandCount: UInt64 = 0x4000
private let defaultSampleMask = UInt32.max
private let startIndexForFragmentDynamicOffsets = 3
private let invalidBindingIndex = UInt32(Int32.max)

/// One recorded command, replayed through the entry point that recorded it.
///
/// Each holds `owner`, a strong reference to the encoder that recorded it, and the objects' shells with their Impls.
enum RecordedCommand {
    case draw(
        owner: WebGPU.Metal.RenderBundleEncoder,
        vertexCount: UInt32,
        instanceCount: UInt32,
        firstVertex: UInt32,
        firstInstance: UInt32
    )
    case drawIndexed(
        owner: WebGPU.Metal.RenderBundleEncoder,
        indexCount: UInt32,
        instanceCount: UInt32,
        firstIndex: UInt32,
        baseVertex: Int32,
        firstInstance: UInt32
    )
    case drawIndirect(owner: WebGPU.Metal.RenderBundleEncoder, buffer: WebGPU.Metal.Buffer, bufferImpl: BufferImpl, offset: UInt64)
    case drawIndexedIndirect(owner: WebGPU.Metal.RenderBundleEncoder, buffer: WebGPU.Metal.Buffer, bufferImpl: BufferImpl, offset: UInt64)
    case setPipeline(owner: WebGPU.Metal.RenderBundleEncoder, pipeline: WebGPU.Metal.RenderPipeline, pipelineImpl: RenderPipelineImpl)
    case setIndexBuffer(
        owner: WebGPU.Metal.RenderBundleEncoder,
        buffer: WebGPU.Metal.Buffer,
        bufferImpl: BufferImpl,
        format: WebGPU.IndexFormat,
        offset: UInt64,
        size: UInt64?
    )
    case setVertexBuffer(
        owner: WebGPU.Metal.RenderBundleEncoder,
        slot: UInt32,
        buffer: WebGPU.Metal.Buffer,
        bufferImpl: BufferImpl,
        offset: UInt64,
        size: UInt64?
    )
    case clearVertexBuffer(owner: WebGPU.Metal.RenderBundleEncoder, slot: UInt32, offset: UInt64, size: UInt64?)
    case setBindGroup(
        owner: WebGPU.Metal.RenderBundleEncoder,
        group: UInt32,
        bindGroup: WebGPU.Metal.BindGroup,
        bindGroupImpl: BindGroupImpl,
        dynamicOffsets: [UInt32]?
    )
    case clearBindGroup(owner: WebGPU.Metal.RenderBundleEncoder, group: UInt32, dynamicOffsets: [UInt32]?)
}

/// One resource the bundle uses, keyed by the MTLResource.
struct BundleResourceEntry {
    let mtlResource: any MTLResource
    var usage: MTLResourceUsage
    var renderStages: MTLRenderStages
    var entryUsage: EntryUsage
    var binding: UInt32
    /// The first-added resource, which merges keep; empty for a resource with no WebGPU object.
    let resource: [BoundResource]
    let tracking: TrackingInfo?
}

private struct BundleBufferBinding {
    var buffer: (any MTLBuffer)?
    var offset: UInt64 = 0
    var size: UInt64 = 0
}

/// Where a draw goes: the current ICB command, or the render pass being replayed into.
private enum DrawTarget {
    case icb(any MTLIndirectRenderCommand)
    case pass(any MTLRenderCommandEncoder)

    func setRenderPipelineState(_ state: any MTLRenderPipelineState) {
        switch self {
        case .icb(let command): command.setRenderPipelineState(state)
        case .pass(let encoder): encoder.setRenderPipelineState(state)
        }
    }

    func setVertexBuffer(_ buffer: any MTLBuffer, offset: Int, index: Int) {
        switch self {
        case .icb(let command): command.setVertexBuffer(buffer, offset: offset, at: index)
        case .pass(let encoder): encoder.setVertexBuffer(buffer, offset: offset, index: index)
        }
    }

    func setFragmentBuffer(_ buffer: any MTLBuffer, offset: Int, index: Int) {
        switch self {
        case .icb(let command): command.setFragmentBuffer(buffer, offset: offset, at: index)
        case .pass(let encoder): encoder.setFragmentBuffer(buffer, offset: offset, index: index)
        }
    }

    func drawPrimitives(_ primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int, baseInstance: Int) {
        switch self {
        case .icb(let command):
            command.drawPrimitives(
                primitiveType,
                vertexStart: vertexStart,
                vertexCount: vertexCount,
                instanceCount: instanceCount,
                baseInstance: baseInstance
            )
        case .pass(let encoder):
            encoder.drawPrimitives(
                type: primitiveType,
                vertexStart: vertexStart,
                vertexCount: vertexCount,
                instanceCount: instanceCount,
                baseInstance: baseInstance
            )
        }
    }

    func drawIndexedPrimitives(
        _ primitiveType: MTLPrimitiveType,
        indexCount: Int,
        indexType: MTLIndexType,
        indexBuffer: any MTLBuffer,
        indexBufferOffset: Int,
        instanceCount: Int,
        baseVertex: Int,
        baseInstance: Int
    ) {
        switch self {
        case .icb(let command):
            command.drawIndexedPrimitives(
                primitiveType,
                indexCount: indexCount,
                indexType: indexType,
                indexBuffer: indexBuffer,
                indexBufferOffset: indexBufferOffset,
                instanceCount: instanceCount,
                baseVertex: baseVertex,
                baseInstance: baseInstance
            )
        case .pass(let encoder):
            encoder.drawIndexedPrimitives(
                type: primitiveType,
                indexCount: indexCount,
                indexType: indexType,
                indexBuffer: indexBuffer,
                indexBufferOffset: indexBufferOffset,
                instanceCount: instanceCount,
                baseVertex: baseVertex,
                baseInstance: baseInstance
            )
        }
    }
}

private enum FinishResult {
    case invalidBeforeEncoding
    case commandReplay
    case indirectCommandBuffers
    case invalidAfterEncoding
}

/// The size, or the rest of the buffer without one; nil when it does not fit.
private func bufferRangeSize(_ buffer: BufferImpl, _ offset: UInt64, _ size: UInt64?) -> UInt64? {
    let bufferSize = buffer.initialSize()
    if offset > bufferSize {
        return nil
    }
    let rangeSize = size ?? (bufferSize - offset)
    if rangeSize > bufferSize - offset {
        return nil
    }
    return rangeSize
}

private func hasUsage(_ buffer: BufferImpl, _ usage: WebGPU.BufferUsage) -> Bool {
    buffer.usageRawValue() & usage.rawValue != 0
}

/// What the pass's usage tracking needs about a buffer the bundle adds outside a bind group.
private func bufferTracking(_ buffer: BufferImpl) -> TrackingInfo {
    TrackingInfo(
        kind: .buffer,
        identity: identityKey(ObjectIdentifier(buffer)),
        baseMipLevel: 0,
        mipLevelCount: 0,
        baseArrayLayer: 0,
        arrayLayerCount: 0,
        aspect: .All
    )
}

/// The number of UInt32 slots copyDynamicOffsetsToBuffer() writes into `buffer`.
private func uint32Count(_ buffer: (any MTLBuffer)?) -> Int {
    (buffer?.length ?? 0) / MemoryLayout<UInt32>.size
}

/// PipelineLayoutImpl.updateOffsets into `contents[start...]`.
///
/// It goes through `window`, a copy of just the slots updateOffsets can reach (the group's base plus the longest run it
/// writes or compares with the space left), so that no MutableSpan is extracted from the middle of the array. Each of
/// its comparisons with the space left then has the same result as with the whole tail.
private func updateDynamicOffsets(
    _ layout: PipelineLayoutImpl,
    _ stage: Stage,
    _ group: UInt32,
    _ offsets: [UInt32],
    _ contents: inout ContiguousArray<UInt32>,
    from start: Int,
    _ window: inout ContiguousArray<UInt32>
) -> Bool {
    precondition(start <= contents.count)
    var reach = 0
    let plan = layout.dynamicOffsetPlan(stage)
    if Int(group) < plan.groups.count, let base = plan.groups[Int(group)].start {
        let offsetGroup = plan.groups[Int(group)]
        reach = Int(base) + max(Int(offsetGroup.linearRange?.count ?? 0), Int(clamping: offsetGroup.count), offsetGroup.sourceIndices.count)
    }
    let end = start + min(contents.count - start, reach)
    window.removeAll(keepingCapacity: true)
    window.append(contentsOf: contents[start..<end])
    var destination = window.mutableSpan
    let result = layout.updateOffsets(stage, group: group, dynamicOffsets: offsets, destination: &destination)
    contents.replaceSubrange(start..<end, with: window)
    return result
}

// The encoders keep a copy of setBindGroup's dynamic offsets.
func copyDynamicOffsets(_ dynamicOffsets: borrowing WebGPU.Metal.DynamicOffsetsView) -> [UInt32] {
    let offsets: Span<UInt32> = dynamicOffsets.span()
    var result: [UInt32] = []
    result.reserveCapacity(offsets.count)
    for index in offsets.indices {
        result.append(offsets[index])
    }
    return result
}

// One per GPURenderBundleEncoder. Owns all of the encoder's state and runs every method's logic in record mode, in ICB
// replay (finish) and in command replay into a render pass (RenderBundleImpl.replayCommands). Replayed commands
// re-enter the entry points, the render pass can invalidate this object, and a reported error can re-enter it from the
// device's uncaptured-error callback, so no method holds an access to a stored property across any of them.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_expose(Cxx)
final class RenderBundleEncoderImpl {
    let deviceImpl: DeviceImpl
    private var limits: EncoderLimits {
        deviceImpl.limits
    }
    // nil once the encoder is invalid.
    private var icbDescriptor: MTLIndirectCommandBufferDescriptor?
    private var indirectCommandBuffer: (any MTLIndirectCommandBuffer)?
    private var currentCommand: (any MTLIndirectRenderCommand)?
    // Zero or one element, paired with currentPipelineImpl.
    private var currentPipeline: [WebGPU.Metal.RenderPipeline] = []
    private var currentPipelineImpl: RenderPipelineImpl?
    private var currentPipelineState: (any MTLRenderPipelineState)?
    private var depthStencilState: (any MTLDepthStencilState)?
    private var cullMode: MTLCullMode = .none
    private var frontFace: MTLWinding = .clockwise
    private var depthClipMode: MTLDepthClipMode = .clip
    private var depthBias: Float = 0
    private var depthBiasSlopeScale: Float = 0
    private var depthBiasClamp: Float = 0
    private var sampleMask = defaultSampleMask
    private var primitiveType: MTLPrimitiveType = .triangle
    // Zero or one element, paired with indexBufferImpl.
    private var indexBuffer: [WebGPU.Metal.Buffer] = []
    private var indexBufferImpl: BufferImpl?
    private var indexType: MTLIndexType = .uint16
    private var indexBufferOffset: UInt = 0
    private var indexBufferSize: UInt = 0
    private var maxVertexBufferSlot: UInt32 = 0
    private var maxBindGroupSlot: UInt32 = 0
    private var debugGroupStackSize: UInt64 = 0
    private var currentCommandIndex: UInt64 = 0
    private var previousCommandCount: UInt64 = 0
    private var vertexDynamicOffset: UInt64 = 0
    private var fragmentDynamicOffset: UInt64 = 0
    private var backingBundleCommandCount: UInt64 = 0
    private var lastErrorString: String?
    private var requiresCommandReplay: Bool
    private var finished = false
    private var submitInvalid = false

    private let sampleCount: UInt32
    private let depthStencilFormat: WebGPU.TextureFormat?
    private let depthReadOnly: Bool
    private let stencilReadOnly: Bool
    private var colorFormats: [WebGPU.TextureFormat?] = []

    private var recordedCommands: [RecordedCommand] = []
    // Insertion-ordered.
    private var resources: [BundleResourceEntry] = []
    private var resourceIndexForMTLResource = WTFHashMap<UInt64, Int32>()
    // Set once the encoder is invalid: nothing is added any more.
    private var resourcesDropped = false
    private var vertexBuffers: [BundleBufferBinding]
    private var fragmentBuffers: [BundleBufferBinding]
    private var utilizedBufferIndices = WTFHashMap<UInt32, UInt64>()
    private var bindGroups = BindGroupTable()
    private var bindGroupDynamicOffsets = GroupIndexedTable<[UInt32]>()
    // Insertion order, one strong reference per distinct group.
    private var allBindGroups: [(shell: WebGPU.Metal.BindGroup, impl: BindGroupImpl)] = []
    private var allBindGroupIdentities = WTFHashSet<UInt64>()
    private var minVertexCountForDrawCommand = WTFHashMap<UInt64, BundleIndexValidation>()
    private var indirectDrawsForSlot = WTFHashMap<UInt64, BundleIndirectDraw>()
    private var icbs: [BundleICB] = []
    // Set once the encoder is invalid: ICBs are still built (the maps move out), but not kept.
    private var icbsDropped = false
    private var dynamicOffsetsVertexBuffer: (any MTLBuffer)?
    private var dynamicOffsetsFragmentBuffer: (any MTLBuffer)?
    // The two buffers' contents, written through by clearDynamicOffsetsBuffers().
    private var dynamicOffsetsVertexContents = ContiguousArray<UInt32>()
    private var dynamicOffsetsFragmentContents = ContiguousArray<UInt32>()
    // Set and cleared within replayCommands, whose caller holds the pass.
    private var replayPassImpl: RenderPassEncoderImpl?
    // Declared last, so that the device outlives the rest of the encoder.
    let device: WebGPU.Metal.Device

    fileprivate init(
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl,
        icbDescriptor: MTLIndirectCommandBufferDescriptor?,
        requiresCommandReplay: Bool,
        parameters: WebGPU.Metal.RenderBundleEncoderParameters,
        lastErrorString: String?
    ) {
        self.deviceImpl = deviceImpl
        self.device = device
        self.icbDescriptor = icbDescriptor
        self.requiresCommandReplay = requiresCommandReplay
        self.lastErrorString = lastErrorString
        sampleCount = parameters.sampleCount
        depthStencilFormat = parameters.hasDepthStencilFormat ? parameters.depthStencilFormat : nil
        depthReadOnly = parameters.depthReadOnly
        stencilReadOnly = parameters.stencilReadOnly
        let isValid = icbDescriptor != nil
        vertexBuffers = Array(repeating: BundleBufferBinding(), count: isValid ? deviceImpl.limits.slots.vertexBindCount : 0)
        fragmentBuffers = Array(repeating: BundleBufferBinding(), count: isValid ? deviceImpl.limits.slots.fragmentBindCount : 0)
    }

    func appendColorFormat(_ hasFormat: Bool, _ format: WebGPU.TextureFormat) {
        colorFormats.append(hasFormat ? format : nil)
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        icbDescriptor != nil
    }

    private func validToEncodeCommand() -> Bool {
        if !deviceImpl.isValid() {
            return false
        }

        if !finished {
            return true
        }
        guard let pass = replayPassImpl else {
            return false
        }
        return pass.renderCommandEncoder() != nil && !submitInvalid
    }

    @_expose(Cxx)
    func makeInvalid(_ errorString: NSString?) {
        invalidate(errorString as String?)
    }

    // Out of line, so that the entry points do no device work unless they report.
    @inline(never)
    private func generateAValidationError(_ message: String) {
        deviceImpl.generateAValidationError(message)
    }

    private func invalidate(_ errorString: String?) {
        indirectCommandBuffer = nil
        icbDescriptor = nil
        lastErrorString = errorString
        resources = []
        resourceIndexForMTLResource.removeAll()
        resourcesDropped = true
        icbs = []
        icbsDropped = true
        replayPassImpl?.invalidate(lastErrorString)
    }

    private func replayingCommands() -> Bool {
        replayPassImpl != nil || currentCommand != nil || indirectCommandBuffer != nil
    }

    private func currentRenderCommand() -> DrawTarget? {
        if let pass = replayPassImpl {
            return pass.renderCommandEncoder().map { .pass($0) }
        }

        if let command = currentCommand {
            return .icb(command)
        }

        if let icb = indirectCommandBuffer, currentCommandIndex < UInt64(icb.size) {
            currentCommand = icb.indirectRenderCommandAt(Int(currentCommandIndex))
        } else {
            currentCommand = nil
        }
        return currentCommand.map { .icb($0) }
    }

    // Reports a failed compile as an out-of-memory error.
    private func icbRenderPipelineState(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ pipelineImpl: RenderPipelineImpl
    ) -> (any MTLRenderPipelineState)? {
        let state = pipelineImpl.icbRenderPipelineState(deviceImpl.device())
        if state == nil {
            deviceImpl.generateAnOutOfMemoryError(
                "Render pipeline failed compilation likely due to being too complex, please reduce its size"
            )
        }
        return state
    }

    private func currentMinimumVertexInstanceCount() -> VertexInstanceBounds {
        minimumVertexInstanceCount(currentPipelineImpl) { bufferIndex in
            Int(bufferIndex) < vertexBuffers.count ? vertexBuffers[Int(bufferIndex)].size : 0
        }
    }

    private func executePreDrawCommands(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        needsValidationLayerWorkaround: Bool,
        passWasSplit: Bool,
        firstInstance: UInt32 = 0,
        instanceCount: UInt32 = 0
    ) -> Bool {
        if !isValid() {
            return false
        }

        if UInt64(instanceCount) + UInt64(firstInstance) > UInt64(UInt32.max) {
            return false
        }

        let drawVertexDynamicOffset = vertexDynamicOffset
        let drawFragmentDynamicOffset = fragmentDynamicOffset
        guard !currentPipeline.isEmpty, let pipelineImpl = currentPipelineImpl else {
            invalidate("Pipeline was not set prior to draw command")
            return false
        }

        if !pipelineImpl.isValid() {
            invalidate("pipeline is not valid prior to draw")
            return false
        }

        // The product wraps; only the sum is checked.
        let layoutImpl = pipelineImpl.pipelineLayoutImpl
        let (vertexDynamicOffsetSum, vertexOverflowed) = vertexDynamicOffset.addingReportingOverflow(
            UInt64(MemoryLayout<UInt32>.size) &* layoutImpl.dynamicOffsetTotal(.vertex)
        )
        if vertexOverflowed {
            invalidate("Invalid vertexDynamicOffset")
            return false
        }
        vertexDynamicOffset = vertexDynamicOffsetSum

        let (fragmentDynamicOffsetSum, fragmentOverflowed) = fragmentDynamicOffset.addingReportingOverflow(
            UInt64(MemoryLayout<UInt32>.size) &* layoutImpl.dynamicOffsetTotal(.fragment)
        )
        if fragmentOverflowed {
            invalidate("Invalid fragmentDynamicOffset")
            return false
        }
        fragmentDynamicOffset = fragmentDynamicOffsetSum

        // The recomputed pipeline shares this one's layout and minimum buffer sizes, so the checks below read this one.
        if needsValidationLayerWorkaround {
            let lastStrideAsStride = pipelineImpl.lastStrideAsStride()
            currentPipelineState = icbRenderPipelineState(shell, lastStrideAsStride.impl)
        }

        if currentPipelineState == nil {
            return false
        }

        guard let drawTarget = currentRenderCommand() else {
            return true
        }

        if let pass = replayPassImpl, passWasSplit {
            let commandEncoder = pass.renderCommandEncoder()
            if let renderPipeline = currentPipelineState {
                commandEncoder?.setRenderPipelineState(renderPipeline)
            }
            if let state = depthStencilState {
                commandEncoder?.setDepthStencilState(state)
            }

            commandEncoder?.setCullMode(cullMode)
            commandEncoder?.setFrontFacing(frontFace)
            commandEncoder?.setDepthClipMode(depthClipMode)
            commandEncoder?.setDepthBias(depthBias, slopeScale: depthBiasSlopeScale, clamp: depthBiasClamp)

            useBindGroupResourcesOnPass(pass)
        }

        if let error = validateBindGroupsForDraw(pipelineImpl) {
            invalidate(error)
            return false
        }

        if let error = errorValidatingBindGroupCompatibility(pipelineImpl.pipelineLayoutImpl, { bindGroups[$0] }) {
            invalidate(error)
            return false
        }

        if let error = errorValidatingDraw(pipelineImpl) {
            invalidate(error)
            return false
        }

        if let renderPipeline = currentPipelineState {
            drawTarget.setRenderPipelineState(renderPipeline)
        }

        if let error = encodeVertexAndFragmentBuffers(drawTarget) {
            invalidate(error)
            return false
        }

        if let error = encodeDynamicOffsets(pipelineImpl, drawTarget, drawVertexDynamicOffset, drawFragmentDynamicOffset) {
            invalidate(error)
            return false
        }

        return true
    }

    private func useBindGroupResourcesOnPass(_ pass: RenderPassEncoderImpl) {
        bindGroups.forEachInWTFOrder { _, group in
            let lists = group.mtlResources
            let containers = group.resources.containers
            for containerIndex in containers.indices {
                let container = containers[containerIndex]
                for index in 0..<container.range.count where container.renderStages.rawValue != 0 {
                    pass.renderCommandEncoder()?
                        .useResource(lists[containerIndex][index], usage: container.usage, stages: container.renderStages)
                }
            }
        }
    }

    private struct DrawValidationError: Error {
        let message: String
    }

    // Walks the bind groups in WTF HashMap order; the first failure picks the message.
    private func validateBindGroupsForDraw(_ pipelineImpl: RenderPipelineImpl) -> String? {
        let pipelineLayoutImpl = pipelineImpl.pipelineLayoutImpl
        do {
            try bindGroups.forEachInWTFOrder { groupIndex, group in
                let pipelineBindGroupLayout = pipelineLayoutImpl.bindGroupLayout(at: Int(groupIndex))
                if let error = group.errorValidatingBindGroup(
                    pipelineImpl.minimumBufferSizes,
                    group: groupIndex,
                    dynamicOffsets: bindGroupDynamicOffsets[groupIndex]
                ) {
                    throw DrawValidationError(message: error)
                }
                if group.makeSubmitInvalid(.vertex, pipelineLayout: pipelineBindGroupLayout)
                    || group.makeSubmitInvalid(.fragment, pipelineLayout: pipelineBindGroupLayout)
                {
                    submitInvalid = true
                }
            }
        } catch let error as DrawValidationError {
            return error.message
        } catch {
            preconditionFailure()
        }
        return nil
    }

    // Walks requiredBufferIndices() in WTF HashMap order; the first missing index picks the message.
    private func errorValidatingRequiredBufferIndices(_ pipelineImpl: RenderPipelineImpl) -> String? {
        for buffer in pipelineImpl.requiredVertexBuffersInWTFOrder where !utilizedBufferIndices.contains(buffer.bufferIndex) {
            return "Buffer index[\(buffer.bufferIndex)] is missing"
        }
        return nil
    }

    private func errorValidatingDraw(_ pipelineImpl: RenderPipelineImpl) -> String? {
        if let error = errorValidatingRequiredBufferIndices(pipelineImpl) {
            return error
        }

        let (withBindGroup, overflow1) = maxBindGroupSlot.addingReportingOverflow(1)
        let (withVertexBuffers, overflow2) = withBindGroup.addingReportingOverflow(maxVertexBufferSlot)
        let (spaceUsed, overflow3) = withVertexBuffers.addingReportingOverflow(1)
        if overflow1 || overflow2 || overflow3 || spaceUsed > limits.maxBindGroupsPlusVertexBuffers {
            return "Too many bind groups and vertex buffers used"
        }

        return nil
    }

    private func encodeVertexAndFragmentBuffers(_ drawTarget: DrawTarget) -> String? {
        for index in vertexBuffers.indices {
            let binding = vertexBuffers[index]
            guard let buffer = binding.buffer else {
                continue
            }
            if binding.offset < UInt64(buffer.length) {
                drawTarget.setVertexBuffer(buffer, offset: Int(binding.offset), index: index)
            } else if binding.size != 0 {
                return "attempting to set non-zero sized buffer"
            } else if let placeholderBuffer = deviceImpl.placeholderBuffer() {
                drawTarget.setVertexBuffer(placeholderBuffer, offset: 0, index: index)
            }
        }

        for index in fragmentBuffers.indices {
            if let buffer = fragmentBuffers[index].buffer {
                drawTarget.setFragmentBuffer(buffer, offset: Int(truncatingIfNeeded: fragmentBuffers[index].offset), index: index)
            }
        }

        return nil
    }

    // Walks the dynamic offsets in WTF HashMap order; the first failure picks the message. `vertexDynamicOffset` and
    // `fragmentDynamicOffset` are the cursors from before this draw advanced them.
    private func encodeDynamicOffsets(
        _ pipelineImpl: RenderPipelineImpl,
        _ drawTarget: DrawTarget,
        _ vertexDynamicOffset: UInt64,
        _ fragmentDynamicOffset: UInt64
    ) -> String? {
        // Moved out for the walk, so that writing them copies nothing and holds no access to a stored property.
        var vertexContents = dynamicOffsetsVertexContents
        var fragmentContents = dynamicOffsetsFragmentContents
        dynamicOffsetsVertexContents = []
        dynamicOffsetsFragmentContents = []
        let error = writeDynamicOffsets(
            pipelineImpl.pipelineLayoutImpl,
            &vertexContents,
            &fragmentContents,
            vertexDynamicOffset,
            fragmentDynamicOffset
        )
        dynamicOffsetsVertexContents = vertexContents
        dynamicOffsetsFragmentContents = fragmentContents
        if let error {
            return error
        }

        if let buffer = dynamicOffsetsVertexBuffer, vertexDynamicOffset < UInt64(buffer.length) {
            drawTarget.setVertexBuffer(buffer, offset: Int(vertexDynamicOffset), index: limits.slots.vertexDynamicOffsets.index)
        }

        if let buffer = dynamicOffsetsFragmentBuffer, fragmentDynamicOffset < UInt64(buffer.length) {
            precondition(!fragmentBuffers.isEmpty)
            drawTarget.setFragmentBuffer(buffer, offset: Int(fragmentDynamicOffset), index: fragmentBuffers.count - 1)
        }

        bindGroupDynamicOffsets.removeAll()

        return nil
    }

    private func writeDynamicOffsets(
        _ pipelineLayoutImpl: PipelineLayoutImpl,
        _ vertexContents: inout ContiguousArray<UInt32>,
        _ fragmentContents: inout ContiguousArray<UInt32>,
        _ vertexDynamicOffset: UInt64,
        _ fragmentDynamicOffset: UInt64
    ) -> String? {
        let vertexStart = Int(vertexDynamicOffset / UInt64(MemoryLayout<UInt32>.size))
        let fragmentStart = Int(fragmentDynamicOffset / UInt64(MemoryLayout<UInt32>.size)) + startIndexForFragmentDynamicOffsets
        let hasVertexBuffer = dynamicOffsetsVertexBuffer != nil
        let hasFragmentBuffer = dynamicOffsetsFragmentBuffer != nil
        var window = ContiguousArray<UInt32>()
        do {
            try bindGroupDynamicOffsets.forEachInWTFOrder { bindGroupIndex, offsets in
                if hasVertexBuffer {
                    if !updateDynamicOffsets(
                        pipelineLayoutImpl,
                        .vertex,
                        bindGroupIndex,
                        offsets,
                        &vertexContents,
                        from: vertexStart,
                        &window
                    ) {
                        throw DrawValidationError(message: "Incorrect data for vertexBuffer")
                    }
                }

                if hasFragmentBuffer {
                    if !updateDynamicOffsets(
                        pipelineLayoutImpl,
                        .fragment,
                        bindGroupIndex,
                        offsets,
                        &fragmentContents,
                        from: fragmentStart,
                        &window
                    ) {
                        throw DrawValidationError(message: "Incorrect data for fragmentBuffer")
                    }
                }
            }
        } catch let error as DrawValidationError {
            return error.message
        } catch {
            preconditionFailure()
        }
        return nil
    }

    private func errorValidatingStripIndexFormat() -> String? {
        guard let pipelineImpl = currentPipelineImpl else {
            return nil
        }

        let topology = pipelineImpl.primitiveTopology
        if topology != WebGPU.PrimitiveTopology.LineStrip && topology != WebGPU.PrimitiveTopology.TriangleStrip {
            return nil
        }

        if pipelineImpl.indexType != indexType {
            return "Primitive topology mismatch with render pipeline"
        }

        return nil
    }

    private func errorValidatingDrawIndexed() -> String? {
        guard let pipelineImpl = currentPipelineImpl else {
            preconditionFailure()
        }
        if pipelineImpl.requiredVertexBuffers.isEmpty {
            return nil
        }

        if indexBufferImpl == nil {
            return "Index buffer is not set"
        }

        return errorValidatingStripIndexFormat()
    }

    // Walks requiredBufferIndices() in WTF HashMap order; the first failure picks the message.
    private func runVertexBufferValidation(
        _ vertexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstVertex: UInt32,
        _ firstInstance: UInt32
    ) -> Bool {
        guard let pipelineImpl = currentPipelineImpl else {
            invalidate("Missing pipeline before draw command")
            return false
        }

        if firstVertex.addingReportingOverflow(vertexCount).overflow {
            invalidate("Overflow in vertex count + firstVertex")
            return false
        }

        for bufferData in pipelineImpl.requiredVertexBuffersInWTFOrder {
            var strideCount: UInt64 = 0
            if bufferData.stepMode == .Vertex {
                let (sum, overflowed) = firstVertex.addingReportingOverflow(vertexCount)
                if overflowed {
                    invalidate("StrideCount invalid")
                    return false
                }
                strideCount = UInt64(sum)
            } else if bufferData.stepMode == .Instance {
                let (sum, overflowed) = firstInstance.addingReportingOverflow(instanceCount)
                if overflowed {
                    invalidate("StrideCount invalid")
                    return false
                }
                strideCount = UInt64(sum)
            }
            if strideCount == 0 {
                continue
            }

            let bufferIndex = bufferData.bufferIndex
            if Int(bufferIndex) >= vertexBuffers.count {
                invalidate("vertex buffer validation failed as vertex buffer \(bufferIndex) was not set")
                return false
            }
            let bufferSize = vertexBuffers[Int(bufferIndex)].size
            let (strideSize, strideOverflowed) = (strideCount - 1).multipliedReportingOverflow(by: bufferData.stride)
            let (requiredSize, requiredOverflowed) = strideSize.addingReportingOverflow(bufferData.lastStride)
            if strideOverflowed || requiredOverflowed || requiredSize > bufferSize {
                invalidate(
                    "Buffer[\(bufferIndex)] fails: (strideCount(\(strideCount)) - 1) * bufferData.stride(\(bufferData.stride)) + bufferData.lastStride(\(bufferData.lastStride)) > bufferSize(\(bufferSize))"
                )
                return false
            }
        }

        return true
    }

    // Walks requiredBufferIndices() in WTF HashMap order; the first failure picks the message.
    private func runIndexBufferValidation(_ firstInstance: UInt32, _ instanceCount: UInt32) -> Bool {
        guard let pipelineImpl = currentPipelineImpl, indexBufferImpl != nil else {
            invalidate("Missing pipeline before draw command")
            return false
        }

        let strideCount = UInt64(firstInstance) + UInt64(instanceCount)
        if strideCount == 0 {
            return true
        }

        for bufferData in pipelineImpl.requiredVertexBuffersInWTFOrder {
            let bufferIndex = bufferData.bufferIndex
            precondition(Int(bufferIndex) < vertexBuffers.count)
            let vertexBuffer = vertexBuffers[Int(bufferIndex)]
            let bufferSize = vertexBuffer.size
            let stride = bufferData.stride
            let lastStride = bufferData.lastStride
            if bufferData.stepMode == .Instance {
                let (product, productOverflowed) = (strideCount - 1).multipliedReportingOverflow(by: stride)
                if productOverflowed {
                    return false
                }
                let (sum, sumOverflowed) = product.addingReportingOverflow(lastStride)
                if sumOverflowed {
                    return false
                }

                if sum > bufferSize {
                    invalidate(
                        "(RenderBundle) Buffer[\(bufferIndex)] fails: (strideCount(\(strideCount)) - 1) * stride(\(stride)) + lastStride(\(lastStride)) > bufferSize(\(bufferSize)), metalBufferLength(\(vertexBuffer.buffer?.length ?? 0))"
                    )
                    return false
                }
            }
        }

        return true
    }

    private func storeIndexDataForValidation(
        _ indexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstIndex: UInt32,
        _ baseVertex: Int32,
        _ firstInstance: UInt32,
        _ indexBufferOffsetInBytes: UInt
    ) -> Bool {
        guard let indexBufferImpl, let mtlIndexBuffer = indexBufferImpl.buffer(), !indexBufferImpl.isDestroyed(), !indexBuffer.isEmpty
        else {
            return false
        }

        let indexSizeInBytes = indexType == .uint16 ? MemoryLayout<UInt16>.size : MemoryLayout<UInt32>.size
        let elementCount = mtlIndexBuffer.length / indexSizeInBytes
        precondition(elementCount != 0)

        let bounds = currentMinimumVertexInstanceCount()
        let commandIndex = currentCommandIndex
        var indexData = WebGPU.Metal.IndexData()
        indexData.renderCommand = commandIndex
        indexData.minVertexCount = bounds.vertices.shaderValue
        indexData.minInstanceCount = bounds.instances.shaderValue
        indexData.bufferGpuAddress = mtlIndexBuffer.gpuAddress
        indexData.indexBufferElementCountMinusOne = UInt32(truncatingIfNeeded: elementCount - 1)
        indexData.indexCount = indexCount
        indexData.instanceCount = instanceCount
        indexData.firstIndex = firstIndex
        indexData.baseVertex = baseVertex
        indexData.firstInstance = firstInstance
        indexData.primitiveType = UInt32(truncatingIfNeeded: primitiveType.rawValue)
        let validation = BundleIndexValidation(
            indexBuffer: indexBuffer[0],
            indexBufferImpl: indexBufferImpl,
            indexType: indexType,
            indexBufferOffsetInBytes: indexBufferOffsetInBytes,
            indexData: indexData,
            vertices: bounds.vertices
        )
        minVertexCountForDrawCommand.add(commandIndex) { validation }
        return true
    }

    private func storeVertexBufferCountsForValidation(
        _ indexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstIndex: UInt32,
        _ baseVertex: Int32,
        _ firstInstance: UInt32,
        _ indexBufferOffsetInBytes: UInt
    ) -> Bool {
        if replayPassImpl != nil {
            return true
        }

        if currentRenderCommand() == nil {
            return false
        }

        return storeIndexDataForValidation(indexCount, instanceCount, firstIndex, baseVertex, firstInstance, indexBufferOffsetInBytes)
    }

    private func finalizeRenderCommand(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, _ commandTypes: MTLIndirectCommandType) {
        icbDescriptor?.commandTypes.formUnion(commandTypes)
        currentCommandIndex &+= 1

        finalizeRenderCommand(shell)
    }

    private func finalizeRenderCommand(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder) {
        currentCommand = nil

        if isValid() && currentCommandIndex >= maxCommandCount && !requiresCommandReplay && indirectCommandBuffer != nil {
            splitICB(shell, needsPipelineReset: true)
        }
    }

    private func recordCommand(_ command: RecordedCommand) {
        if !isValid() {
            return
        }

        precondition(dynamicOffsetsFragmentBuffer == nil)
        recordedCommands.append(command)
    }

    // When this returns true, after finalizing the command slot, the render command entry point reports its error and
    // returns.
    private func encodingHasFinished(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, finalizing: Bool) -> Bool {
        if validToEncodeCommand() {
            return false
        }
        if finalizing {
            finalizeRenderCommand(shell)
        }
        return true
    }

    @_expose(Cxx)
    func draw(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ vertexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstVertex: UInt32,
        _ firstInstance: UInt32
    ) {
        if encodingHasFinished(shell, finalizing: true) {
            generateAValidationError(
                "RenderBundleEncoder::FinalizeRenderCommand WebGPU::Metal::RenderBundleEncoder::encodeDraw(uint32_t, uint32_t, uint32_t, uint32_t): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            finalizeRenderCommand(shell)
            return
        }
        let needsValidationLayerWorkaround = currentMinimumVertexInstanceCount().needsValidationLayerWorkaround
        if !executePreDrawCommands(
            shell,
            needsValidationLayerWorkaround: needsValidationLayerWorkaround,
            passWasSplit: false,
            firstInstance: firstInstance,
            instanceCount: instanceCount
        ) {
            finalizeRenderCommand(shell)
            return
        }
        if let drawTarget = currentRenderCommand() {
            if !submitInvalid && vertexCount != 0 && instanceCount != 0 {
                drawTarget.drawPrimitives(
                    primitiveType,
                    vertexStart: Int(nsUInteger: firstVertex),
                    vertexCount: Int(nsUInteger: vertexCount),
                    instanceCount: Int(nsUInteger: instanceCount),
                    baseInstance: Int(nsUInteger: firstInstance)
                )
            }
        } else {
            if !runVertexBufferValidation(vertexCount, instanceCount, firstVertex, firstInstance) {
                finalizeRenderCommand(shell)
                return
            }

            // A draw with a zero vertex or instance count still has to be validated, so record it like
            // any other draw and skip only the encoded command when it is replayed.
            recordCommand(
                .draw(
                    owner: copy shell,
                    vertexCount: vertexCount,
                    instanceCount: instanceCount,
                    firstVertex: firstVertex,
                    firstInstance: firstInstance
                )
            )
        }

        finalizeRenderCommand(shell, .draw)
    }

    @_expose(Cxx)
    func drawIndexed(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ indexCount: UInt32,
        _ instanceCount: UInt32,
        _ firstIndex: UInt32,
        _ baseVertex: Int32,
        _ firstInstance: UInt32
    ) {
        if encodingHasFinished(shell, finalizing: true) {
            generateAValidationError(
                "RenderBundleEncoder::FinalizeRenderCommand WebGPU::Metal::RenderBundleEncoder::encodeDrawIndexed(uint32_t, uint32_t, uint32_t, int32_t, uint32_t): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            finalizeRenderCommand(shell)
            return
        }

        // Checked here rather than only in errorValidatingDrawIndexed() below, which the ICB path skips.
        if let error = errorValidatingStripIndexFormat() {
            invalidate(error)
            finalizeRenderCommand(shell)
            return
        }

        // The C++ size_t arithmetic, in 64 bits on arm64_32 too, so that the m_indexBufferSize check rejects the draw there.
        let indexSizeInBytes: UInt64 = indexType == .uint16 ? 2 : 4
        let (firstIndexOffsetInBytes, firstIndexOffsetOverflowed) = UInt64(firstIndex).multipliedReportingOverflow(by: indexSizeInBytes)
        let (indexBufferOffsetInBytes, indexBufferOffsetOverflowed) = UInt64(indexBufferOffset)
            .addingReportingOverflow(firstIndexOffsetInBytes)
        if indexBufferOffsetOverflowed || firstIndexOffsetOverflowed {
            finalizeRenderCommand(shell)
            return
        }

        let mtlIndexBuffer = indexBufferImpl?.buffer()
        var clamp = IndexBufferClamp.draw
        var needsValidationLayerWorkaround = false
        var passWasSplit = false
        if let pass = replayPassImpl {
            let counts = currentMinimumVertexInstanceCount()
            needsValidationLayerWorkaround = counts.needsValidationLayerWorkaround
            clamp = pass.clampIndexBufferToValidValues(
                indexCount,
                instanceCount,
                baseVertex,
                firstInstance,
                indexType,
                UInt(truncatingIfNeeded: indexBufferOffsetInBytes),
                indexBuffer,
                indexBufferImpl,
                counts,
                sampleCount,
                primitiveType
            )
            if case .indirectDraw = clamp {
                passWasSplit = splitReplayPass()
            }
        }

        if !executePreDrawCommands(
            shell,
            needsValidationLayerWorkaround: needsValidationLayerWorkaround,
            passWasSplit: passWasSplit,
            firstInstance: firstInstance,
            instanceCount: instanceCount
        ) {
            finalizeRenderCommand(shell)
            return
        }

        let (indexCountTimesSizeInBytes, indexCountTimesSizeOverflowed) = UInt64(indexCount)
            .multipliedReportingOverflow(by: indexSizeInBytes)
        if let drawTarget = currentRenderCommand() {
            if !storeVertexBufferCountsForValidation(
                indexCount,
                instanceCount,
                UInt32(truncatingIfNeeded: indexBufferOffsetInBytes / indexSizeInBytes),
                baseVertex,
                firstInstance,
                UInt(truncatingIfNeeded: indexBufferOffsetInBytes)
            ) {
                finalizeRenderCommand(shell)
                return
            }

            if let pass = replayPassImpl, case .indirectDraw(let clamped) = clamp {
                // Metal takes neither buffer as nil.
                if !submitInvalid, let mtlIndexBuffer, let clamped {
                    pass.renderCommandEncoder()?
                        .drawIndexedPrimitives(
                            primitiveType,
                            indexType: indexType,
                            indexBuffer: mtlIndexBuffer,
                            indexBufferOffset: 0,
                            clamped: clamped
                        )
                }
            } else if case .draw = clamp {
                let (lastByte, lastByteOverflowed) = indexBufferOffsetInBytes.addingReportingOverflow(indexCountTimesSizeInBytes)
                if !indexCountTimesSizeOverflowed && !lastByteOverflowed, let mtlIndexBuffer, lastByte <= UInt64(mtlIndexBuffer.length),
                    !submitInvalid, indexCount != 0, instanceCount != 0
                {
                    drawTarget.drawIndexedPrimitives(
                        primitiveType,
                        indexCount: Int(indexCount),
                        indexType: indexType,
                        indexBuffer: mtlIndexBuffer,
                        indexBufferOffset: Int(indexBufferOffsetInBytes),
                        instanceCount: Int(nsUInteger: instanceCount),
                        baseVertex: Int(baseVertex),
                        baseInstance: Int(nsUInteger: firstInstance)
                    )
                }
            }
        } else {
            if let error = errorValidatingDrawIndexed() {
                invalidate(error)
                finalizeRenderCommand(shell)
                return
            }

            let (lastIndexOffset, lastIndexOffsetOverflowed) = firstIndexOffsetInBytes.addingReportingOverflow(indexCountTimesSizeInBytes)
            if indexCountTimesSizeOverflowed || lastIndexOffsetOverflowed || lastIndexOffset > UInt64(indexBufferSize)
                || UInt64(indexBufferSize) < indexSizeInBytes
            {
                invalidate("firstIndexOffsetInBytes + indexCount * indexSizeInBytes > m_indexBufferSize")
                finalizeRenderCommand(shell)
                return
            }

            if !runIndexBufferValidation(firstInstance, instanceCount) {
                finalizeRenderCommand(shell)
                return
            }

            if mtlIndexBuffer == nil || indexBufferImpl?.isDestroyed() == true {
                finalizeRenderCommand(shell)
                return
            }

            // A draw with a zero index or instance count still has to be validated, so record it like
            // any other draw and skip only the encoded command when it is replayed.
            recordCommand(
                .drawIndexed(
                    owner: copy shell,
                    indexCount: indexCount,
                    instanceCount: instanceCount,
                    firstIndex: firstIndex,
                    baseVertex: baseVertex,
                    firstInstance: firstInstance
                )
            )
        }

        finalizeRenderCommand(shell, .drawIndexed)
    }

    @_expose(Cxx)
    func drawIndexedIndirect(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ indirectBuffer: borrowing WebGPU.Metal.Buffer,
        _ indirectBufferImpl: BufferImpl,
        _ indirectOffset: UInt64
    ) {
        if encodingHasFinished(shell, finalizing: true) {
            generateAValidationError(
                "RenderBundleEncoder::FinalizeRenderCommand WebGPU::Metal::RenderBundleEncoder::encodeDrawIndexedIndirect(Buffer &, uint64_t): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            finalizeRenderCommand(shell)
            return
        }

        if let error = errorValidatingStripIndexFormat() {
            invalidate(error)
            finalizeRenderCommand(shell)
            return
        }

        var splitPass = false
        var clamped: ClampedIndirectArguments?
        var needsValidationLayerWorkaround = false
        if let pass = replayPassImpl {
            let counts = currentMinimumVertexInstanceCount()
            needsValidationLayerWorkaround = counts.needsValidationLayerWorkaround
            let arguments = IndirectArgumentsRange(
                indirectBufferImpl,
                offset: indirectOffset,
                argumentsSize: MemoryLayout<MTLDrawIndexedPrimitivesIndirectArguments>.size
            )
            clamped = pass.clampIndirectIndexBufferToValidValues(
                indexBufferImpl,
                arguments,
                indexType,
                indexBufferOffset,
                counts,
                primitiveType,
                sampleCount
            )
            if clamped != nil {
                splitPass = splitReplayPass()
            }
        }

        if !executePreDrawCommands(shell, needsValidationLayerWorkaround: needsValidationLayerWorkaround, passWasSplit: splitPass) {
            finalizeRenderCommand(shell)
            return
        }
        let mtlIndexBuffer = indexBufferImpl?.buffer()
        let indexBufferLength = mtlIndexBuffer?.length ?? 0
        if currentRenderCommand() != nil {
            if let pass = replayPassImpl {
                if !pass.trackUse(.buffer(indirectBufferImpl)) {
                    finalizeRenderCommand(shell)
                    return
                }
                if !indirectBufferImpl.isDestroyed() && indexBufferLength != 0 && !submitInvalid, let mtlIndexBuffer, let clamped {
                    pass.renderCommandEncoder()?
                        .drawIndexedPrimitives(
                            primitiveType,
                            indexType: indexType,
                            indexBuffer: mtlIndexBuffer,
                            indexBufferOffset: Int(indexBufferOffset),
                            clamped: clamped
                        )
                }
            } else if indexBufferLength != 0 {
                // Record the command; its draw is encoded into this ICB slot on the GPU at executeBundles() time.
                recordIndirectDrawForSlot(indirectBuffer, indirectBufferImpl, indirectOffset, isIndexed: true)
            }
        } else {
            if indexBufferLength == 0 {
                finalizeRenderCommand(shell)
                return
            }

            if !isValidToUse(indirectBufferImpl.isValid(), indirectBufferImpl.deviceImpl, with: deviceImpl) {
                invalidate("drawIndexedIndirect: buffer was invalid")
                finalizeRenderCommand(shell)
                return
            }

            if !hasUsage(indirectBufferImpl, .Indirect) || indirectOffset % 4 != 0 {
                invalidate("drawIndexedIndirect: validation failed")
                finalizeRenderCommand(shell)
                return
            }

            let (indirectOffsetSum, indirectOffsetOverflowed) = indirectOffset.addingReportingOverflow(
                UInt64(MemoryLayout<MTLDrawIndexedPrimitivesIndirectArguments>.size)
            )
            if indirectOffsetOverflowed || indirectBufferImpl.initialSize() < indirectOffsetSum {
                invalidate("drawIndexedIndirect: validation failed")
                finalizeRenderCommand(shell)
                return
            }

            recordCommand(
                .drawIndexedIndirect(owner: copy shell, buffer: copy indirectBuffer, bufferImpl: indirectBufferImpl, offset: indirectOffset)
            )
        }

        finalizeRenderCommand(shell, .drawIndexed)
    }

    @_expose(Cxx)
    func drawIndirect(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ indirectBuffer: borrowing WebGPU.Metal.Buffer,
        _ indirectBufferImpl: BufferImpl,
        _ apiIndirectOffset: UInt64
    ) {
        if encodingHasFinished(shell, finalizing: true) {
            generateAValidationError(
                "RenderBundleEncoder::FinalizeRenderCommand WebGPU::Metal::RenderBundleEncoder::encodeDrawIndirect(Buffer &, uint64_t): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            finalizeRenderCommand(shell)
            return
        }

        // In a pass, the offset into the clamped copy. A pass whose encoder is gone (no draw target) validates and
        // records that offset below.
        var indirectOffset = apiIndirectOffset
        var splitPass = false
        var clamped: ClampedIndirectArguments?
        var needsValidationLayerWorkaround = false
        if let pass = replayPassImpl {
            let counts = currentMinimumVertexInstanceCount()
            needsValidationLayerWorkaround = counts.needsValidationLayerWorkaround
            let arguments = IndirectArgumentsRange(
                indirectBufferImpl,
                offset: indirectOffset,
                argumentsSize: MemoryLayout<MTLDrawPrimitivesIndirectArguments>.size
            )
            clamped = pass.clampIndirectBufferToValidValues(arguments, counts, sampleCount)
            indirectOffset = clamped?.offset ?? 0
            if clamped != nil {
                splitPass = splitReplayPass()
            }
        }

        if !executePreDrawCommands(shell, needsValidationLayerWorkaround: needsValidationLayerWorkaround, passWasSplit: splitPass) {
            finalizeRenderCommand(shell)
            return
        }
        if currentRenderCommand() != nil {
            if let pass = replayPassImpl {
                if !pass.trackUse(.buffer(indirectBufferImpl)) {
                    finalizeRenderCommand(shell)
                    return
                }
                if !indirectBufferImpl.isDestroyed() && !submitInvalid, let clamped {
                    pass.renderCommandEncoder()?.drawPrimitives(primitiveType, clamped: clamped)
                }
            } else {
                // Record the command; its draw is encoded into this ICB slot on the GPU at executeBundles() time.
                recordIndirectDrawForSlot(indirectBuffer, indirectBufferImpl, indirectOffset, isIndexed: false)
            }
        } else {
            if !isValidToUse(indirectBufferImpl.isValid(), indirectBufferImpl.deviceImpl, with: deviceImpl) {
                invalidate("drawIndirect: buffer was invalid")
                finalizeRenderCommand(shell)
                return
            }

            if !hasUsage(indirectBufferImpl, .Indirect) || indirectOffset % 4 != 0 {
                invalidate("drawIndirect: validation failed")
                finalizeRenderCommand(shell)
                return
            }

            let (indirectOffsetSum, indirectOffsetOverflowed) = indirectOffset.addingReportingOverflow(
                UInt64(MemoryLayout<MTLDrawPrimitivesIndirectArguments>.size)
            )
            if indirectOffsetOverflowed || indirectBufferImpl.initialSize() < indirectOffsetSum {
                invalidate("drawIndirect: validation failed")
                finalizeRenderCommand(shell)
                return
            }

            recordCommand(
                .drawIndirect(owner: copy shell, buffer: copy indirectBuffer, bufferImpl: indirectBufferImpl, offset: indirectOffset)
            )
        }

        finalizeRenderCommand(shell, .draw)
    }

    private func splitReplayPass() -> Bool {
        replayPassImpl?.splitRenderPass() ?? false
    }

    private func recordIndirectDrawForSlot(
        _ indirectBuffer: borrowing WebGPU.Metal.Buffer,
        _ indirectBufferImpl: BufferImpl,
        _ indirectOffset: UInt64,
        isIndexed: Bool
    ) {
        let bounds = currentMinimumVertexInstanceCount()
        let commandIndex = currentCommandIndex
        let draw = BundleIndirectDraw(
            renderCommand: commandIndex,
            indirectBuffer: copy indirectBuffer,
            indirectBufferImpl: indirectBufferImpl,
            indirectOffset: indirectOffset,
            bounds: bounds,
            indexBuffer: isIndexed ? indexBuffer : [],
            indexBufferImpl: isIndexed ? indexBufferImpl : nil,
            indexType: isIndexed ? indexType : .uint16,
            indexBufferOffset: isIndexed ? indexBufferOffset : 0,
            primitiveType: primitiveType,
            isIndexed: isIndexed
        )
        indirectDrawsForSlot.set(commandIndex, draw)
        _ = addInputBuffer(indirectBuffer, indirectBufferImpl, stage: .vertex)
        if isIndexed, let indexBufferImpl, !indexBuffer.isEmpty {
            let indexBufferShell = indexBuffer[0]
            _ = addInputBuffer(indexBufferShell, indexBufferImpl, stage: .vertex)
        }
    }

    private func makeICB(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ requestedCommandCount: UInt64
    ) -> (any MTLIndirectCommandBuffer)? {
        guard let descriptor = icbDescriptor, !descriptor.commandTypes.isEmpty else {
            return nil
        }

        let commandCount = min(max(requestedCommandCount, 1), maxCommandCount)
        guard
            let icb = deviceImpl.device()?
                .makeIndirectCommandBuffer(descriptor: descriptor, maxCommandCount: Int(commandCount), options: []),
            UInt64(icb.size) == commandCount
        else {
            invalidate("MTLIndirectCommandBuffer allocation failed, likely tried to encode too many commands")
            return nil
        }

        deviceImpl.setOwnerWithIdentity(icb)
        return icb
    }

    private func cleanup(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, resetPipeline: Bool) {
        currentCommand = nil
        currentPipelineState = nil
        minVertexCountForDrawCommand.removeAll()
        indirectDrawsForSlot.removeAll()
        depthStencilState = nil
        cullMode = .none
        frontFace = .clockwise
        depthClipMode = .clip
        depthBiasSlopeScale = 0
        depthBias = 0
        depthBiasClamp = 0

        if resetPipeline, !currentPipeline.isEmpty, let pipelineImpl = currentPipelineImpl, validToEncodeCommand() {
            let pipeline = currentPipeline[0]
            applyPipeline(shell, pipeline, pipelineImpl)
        }
    }

    // Also the body of replayCommands(), between setting and clearing the render pass.
    private func endCurrentICB(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder) {
        let commandCount = currentCommandIndex
        previousCommandCount = currentCommandIndex
        currentCommandIndex = 0

        precondition(commandCount == 0 || icbDescriptor != nil)
        requiresCommandReplay = requiresCommandReplay || (commandCount == 0 && icbs.isEmpty)
        if (icbDescriptor?.commandTypes.isEmpty ?? true) && !requiresCommandReplay {
            recordedCommands = []
            cleanup(shell, resetPipeline: false)
            return
        }

        icbDescriptor?.maxVertexBufferBindCount = limits.slots.vertexBindCount
        icbDescriptor?.maxFragmentBufferBindCount = limits.slots.fragmentBindCount
        if vertexDynamicOffset != 0 && !ensureVertexDynamicOffsetsBuffer(shell, vertexDynamicOffset) {
            return
        }
        vertexDynamicOffset = 0

        if !ensureFragmentDynamicOffsetsBuffer(shell, fragmentDynamicOffset, sampleMask) {
            return
        }
        fragmentDynamicOffset = 0

        if replayPassImpl == nil && !requiresCommandReplay {
            indirectCommandBuffer = makeICB(shell, commandCount)
        }

        replayRecordedCommands()

        currentPipeline.removeAll()
        currentPipelineImpl = nil
        splitICB(shell, needsPipelineReset: true)
        currentCommandIndex = 0

        indirectCommandBuffer = nil
        clearDynamicOffsetsBuffers()
    }

    // Each command re-enters this object through the entry point that recorded it. A copy is walked, as nothing may
    // hold the stored array across that.
    private func replayRecordedCommands() {
        let commands = recordedCommands
        for command in commands {
            switch command {
            case .draw(let owner, let vertexCount, let instanceCount, let firstVertex, let firstInstance):
                draw(owner, vertexCount, instanceCount, firstVertex, firstInstance)
            case .drawIndexed(let owner, let indexCount, let instanceCount, let firstIndex, let baseVertex, let firstInstance):
                drawIndexed(owner, indexCount, instanceCount, firstIndex, baseVertex, firstInstance)
            case .drawIndirect(let owner, let buffer, let bufferImpl, let offset):
                drawIndirect(owner, buffer, bufferImpl, offset)
            case .drawIndexedIndirect(let owner, let buffer, let bufferImpl, let offset):
                drawIndexedIndirect(owner, buffer, bufferImpl, offset)
            case .setPipeline(let owner, let pipeline, let pipelineImpl):
                setPipeline(owner, pipeline, pipelineImpl)
            case .setIndexBuffer(let owner, let buffer, let bufferImpl, let format, let offset, let size):
                setIndexBuffer(owner, buffer, bufferImpl, format, offset, size != nil, size ?? 0)
            case .setVertexBuffer(let owner, let slot, let buffer, let bufferImpl, let offset, let size):
                setVertexBuffer(owner, slot, buffer, bufferImpl, offset, size != nil, size ?? 0)
            case .clearVertexBuffer(let owner, let slot, let offset, let size):
                clearVertexBuffer(owner, slot, offset, size != nil, size ?? 0)
            case .setBindGroup(let owner, let group, let bindGroup, let bindGroupImpl, let dynamicOffsets):
                setBindGroup(owner, group, bindGroup, bindGroupImpl, offsets: dynamicOffsets)
            case .clearBindGroup(let owner, let group, let dynamicOffsets):
                clearBindGroup(owner, group, offsets: dynamicOffsets)
            }
        }
    }

    // The caller (RenderBundleImpl) holds this encoder's shell, and the pass's caller holds the pass.
    @_expose(!Cxx)
    func replayCommands(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, into passImpl: RenderPassEncoderImpl) {
        if passImpl.renderCommandEncoder() == nil || !isValid() || !deviceImpl.isValid() {
            return
        }

        replayPassImpl = passImpl
        endCurrentICB(shell)
        replayPassImpl = nil
        didReplayCommands()
    }

    private func didReplayCommands() {
        currentPipelineState = nil
        depthStencilState = nil
        bindGroupDynamicOffsets.removeAll()
        resetIndexBuffer()
    }

    private func resetIndexBuffer() {
        indexBuffer = []
        indexBufferImpl = nil
        indexType = .uint16
        indexBufferOffset = 0
        indexBufferSize = 0
    }

    private func finishResult(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder) -> FinishResult {
        if icbDescriptor == nil || debugGroupStackSize != 0 || !deviceImpl.isValid() || finished {
            return .invalidBeforeEncoding
        }

        requiresCommandReplay = requiresCommandReplay || (currentCommandIndex == 0 && icbs.isEmpty)
        resetIndexBuffer()

        if requiresCommandReplay {
            backingBundleCommandCount = currentCommandIndex
            return .commandReplay
        }

        let commandCount = currentCommandIndex
        endCurrentICB(shell)
        if requiresCommandReplay {
            backingBundleCommandCount = currentCommandIndex
            return .commandReplay
        }

        vertexBuffers = []
        fragmentBuffers = []
        recordedCommands = []
        icbDescriptor?.maxVertexBufferBindCount = 0
        icbDescriptor?.maxFragmentBufferBindCount = 0

        precondition(!icbsDropped || lastErrorString != nil)
        if !icbsDropped {
            backingBundleCommandCount = commandCount
            return .indirectCommandBuffers
        }

        return .invalidAfterEncoding
    }

    // The entries grouped by (render stages, usage), each group in insertion order.
    private func makeBundleResourceSet() -> (resources: ResourceSet, mtlResources: ResourceLists) {
        if resourcesDropped || resources.isEmpty {
            return (.empty, [])
        }

        let stageCount = 4
        let usageCount = 3
        var buckets = [[Int]](repeating: [], count: stageCount * usageCount)
        for (index, entry) in resources.enumerated() {
            if entry.renderStages.rawValue == 0 || entry.usage.rawValue == 0 {
                continue
            }
            let stage = Int(entry.renderStages.rawValue) - 1
            let usage = Int(entry.usage.rawValue) - 1
            precondition(stage < stageCount && usage < usageCount)
            buckets[stage * usageCount + usage].append(index)
        }

        var containers = ResourceContainers()
        var lists: ResourceLists = []
        var records: [UsageRecord] = []
        var owners = OwnerList()
        for stage in 0..<stageCount {
            for usage in 0..<usageCount {
                let bucket = buckets[stage * usageCount + usage]
                if bucket.isEmpty {
                    continue
                }
                var mtlResources: [any MTLResource] = []
                mtlResources.reserveCapacity(bucket.count)
                for index in bucket {
                    let entry = resources[index]
                    mtlResources.append(entry.mtlResource)
                    var resourceIndex: Int32 = -1
                    var impl: TrackedImpl?
                    if let owner = entry.resource.first {
                        resourceIndex = Int32(owners.count)
                        owners.append(owner)
                        impl = owner.trackedImpl
                    }
                    records.append(
                        UsageRecord(
                            usage: entry.entryUsage,
                            binding: entry.binding,
                            entryOffset: 0,
                            entrySize: 0,
                            resource: resourceIndex,
                            impl: impl,
                            tracking: entry.tracking
                        )
                    )
                }
                lists.append(mtlResources)
                containers.append(
                    recordCount: bucket.count,
                    usage: MTLResourceUsage(rawValue: UInt(usage + 1)),
                    renderStages: MTLRenderStages(rawValue: UInt(stage + 1))
                )
            }
        }
        return (ResourceSet(containers: containers, records: records, owners: owners), lists)
    }

    // Returns the bundle, valid or not, labelled, for the shell to box. An invalid one reports the encoder's last error.
    @_expose(Cxx)
    func finish(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, _ label: NSString) -> RenderBundleImpl {
        let bundle = finishedBundle(shell)
        if !bundle.isValid() {
            // Without a last error the message is a null string.
            deviceImpl.generateAnError(.Validation, .Validation, lastErrorString.map { WTF.String($0) } ?? WTF.String())
        }
        bundle.setLabel(label)
        return bundle
    }

    private func finishedBundle(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder) -> RenderBundleImpl {
        let bundle: RenderBundleImpl
        switch finishResult(shell) {
        case .invalidBeforeEncoding:
            return RenderBundleImpl(invalid: device, deviceImpl, lastError: lastErrorString)
        case .commandReplay:
            bundle = makeBundle(icbs: [], isICBBundle: false, replay: .encoder(copy shell, self))
        case .indirectCommandBuffers:
            bundle = makeBundle(icbs: icbs, isICBBundle: true, replay: .none(lastError: nil))
        case .invalidAfterEncoding:
            bundle = RenderBundleImpl(invalid: device, deviceImpl, lastError: lastErrorString)
        }
        finished = true
        bundle.registerAsResourceHolder()
        return bundle
    }

    private func makeBundle(icbs: [BundleICB], isICBBundle: Bool, replay: consuming BundleReplay) -> RenderBundleImpl {
        // A new array, not a copy-on-write share: the bundle holds its own reference to each group.
        let bindGroups = allBindGroups.map { $0 }
        let bundleResources = makeBundleResourceSet()
        return RenderBundleImpl(
            device: device,
            deviceImpl: deviceImpl,
            resources: bundleResources.resources,
            mtlResources: bundleResources.mtlResources,
            icbs: icbs,
            isICBBundle: isICBBundle,
            replay: replay,
            bindGroups: bindGroups,
            colorFormats: colorFormats,
            depthStencilFormat: depthStencilFormat,
            sampleCount: sampleCount,
            depthReadOnly: depthReadOnly,
            stencilReadOnly: stencilReadOnly,
            commandCount: backingBundleCommandCount,
            submitInvalid: submitInvalid
        )
    }

    // A bundle encoder's state is always open.
    @_expose(Cxx)
    func insertDebugMarker() {
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-insertdebugmarker
        // MTLIndirectCommandBuffers don't support debug commands.
        if !validToEncodeCommand() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderBundleEncoder::insertDebugMarker(String &&): failed as encoding has finished"
            )
        }
    }

    @_expose(Cxx)
    func popDebugGroup() {
        if !validToEncodeCommand() {
            generateAValidationError("virtual void WebGPU::Metal::RenderBundleEncoder::popDebugGroup(): failed as encoding has finished")
            return
        }
        guard icbDescriptor != nil else {
            return
        }
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-popdebuggroup

        if debugGroupStackSize == 0 {
            invalidate("validatePopDebugGroup failed")
            return
        }

        debugGroupStackSize -= 1
        // MTLIndirectCommandBuffers don't support debug commands.
    }

    @_expose(Cxx)
    func pushDebugGroup() {
        if !validToEncodeCommand() {
            generateAValidationError(
                "virtual void WebGPU::Metal::RenderBundleEncoder::pushDebugGroup(String &&): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            return
        }
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-pushdebuggroup

        debugGroupStackSize &+= 1
        // MTLIndirectCommandBuffers don't support debug commands.
    }

    @_expose(Cxx)
    func setBindGroup(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ groupIndex: UInt32,
        _ group: borrowing WebGPU.Metal.BindGroup,
        _ groupImpl: BindGroupImpl,
        _ hasDynamicOffsets: Bool,
        _ dynamicOffsets: borrowing WebGPU.Metal.DynamicOffsetsView
    ) {
        setBindGroup(shell, groupIndex, group, groupImpl, offsets: hasDynamicOffsets ? copyDynamicOffsets(dynamicOffsets) : nil)
    }

    // A nil list counts as an empty one.
    private func setBindGroup(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ groupIndex: UInt32,
        _ group: borrowing WebGPU.Metal.BindGroup,
        _ groupImpl: BindGroupImpl,
        offsets: [UInt32]?
    ) {
        if !validToEncodeCommand() {
            generateAValidationError(
                "void WebGPU::Metal::RenderBundleEncoder::setBindGroupWithOwnedDynamicOffsets(uint32_t, const BindGroup *, std::optional<Vector<uint32_t>> &&): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            return
        }

        if !isValidToUse(groupImpl.isValid(), groupImpl.deviceImpl, with: deviceImpl) {
            invalidate("setBindGroup: invalid bind group")
            return
        }

        maxBindGroupSlot = max(groupIndex, maxBindGroupSlot)
        if !replayingCommands() {
            addToAllBindGroups(group, groupImpl)

            if groupIndex >= limits.maxBindGroups {
                invalidate("setBindGroup: groupIndex >= limits.maxBindGroups")
                return
            }

            if let offsets {
                if groupImpl.layoutImpl == nil {
                    invalidate("GPURenderBundleEncoder.setBindGroup: bind group is nil")
                    return
                }
                var maxDynamicOffset: UInt32 = 0
                if let error = groupImpl.errorValidatingDynamicOffsets(offsets, maxOffset: &maxDynamicOffset) {
                    invalidate("GPURenderBundleEncoder.setBindGroup: \(error)")
                    return
                }
            }

            if groupImpl.argumentBuffers.fragment != nil {
                icbDescriptor?.maxFragmentBufferBindCount = max(icbDescriptor?.maxFragmentBufferBindCount ?? 0, 2 + Int(groupIndex))
            }

            recordCommand(
                .setBindGroup(
                    owner: copy shell,
                    group: groupIndex,
                    bindGroup: copy group,
                    bindGroupImpl: groupImpl,
                    dynamicOffsets: offsets
                )
            )
            return
        }

        if let offsets, !offsets.isEmpty {
            bindGroupDynamicOffsets.set(groupIndex, offsets)
        }

        if !addBindGroupResources(groupImpl) {
            return
        }

        bindGroups.set(groupIndex, copy group, groupImpl)
        if !bindVertexArgumentBuffer(groupIndex, groupImpl) {
            return
        }
        bindFragmentArgumentBuffer(groupIndex, groupImpl)
    }

    // setBindGroup with a null bind group.
    @_expose(Cxx)
    func clearBindGroup(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ groupIndex: UInt32,
        _ hasDynamicOffsets: Bool,
        _ dynamicOffsets: borrowing WebGPU.Metal.DynamicOffsetsView
    ) {
        clearBindGroup(shell, groupIndex, offsets: hasDynamicOffsets ? copyDynamicOffsets(dynamicOffsets) : nil)
    }

    private func clearBindGroup(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, _ groupIndex: UInt32, offsets: [UInt32]?) {
        if !validToEncodeCommand() {
            generateAValidationError(
                "void WebGPU::Metal::RenderBundleEncoder::setBindGroupWithOwnedDynamicOffsets(uint32_t, const BindGroup *, std::optional<Vector<uint32_t>> &&): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            return
        }

        maxBindGroupSlot = max(groupIndex, maxBindGroupSlot)
        if !replayingCommands() {
            if groupIndex >= limits.maxBindGroups {
                invalidate("setBindGroup: groupIndex >= limits.maxBindGroups")
                return
            }

            recordCommand(.clearBindGroup(owner: copy shell, group: groupIndex, dynamicOffsets: offsets))
            return
        }

        bindGroups.remove(groupIndex)
    }

    private func addToAllBindGroups(_ group: borrowing WebGPU.Metal.BindGroup, _ groupImpl: BindGroupImpl) {
        if allBindGroupIdentities.add(identityKey(ObjectIdentifier(groupImpl))) {
            allBindGroups.append((shell: copy group, impl: groupImpl))
        }
    }

    // When no pass is being replayed into: merges into the entry of the same MTLResource, keeping its first resource.
    private func addResourceToMap(
        _ mtlResource: (any MTLResource)?,
        usage: MTLResourceUsage,
        stages: MTLRenderStages,
        entryUsage: EntryUsage,
        binding: UInt32,
        resource: [BoundResource],
        tracking: TrackingInfo?
    ) {
        guard !resourcesDropped, let mtlResource else {
            return
        }

        let key = identityKey(ObjectIdentifier(mtlResource))
        if let index = resourceIndexForMTLResource.value(forKey: key) {
            resources[Int(index)].usage.formUnion(usage)
            resources[Int(index)].renderStages.formUnion(stages)
            resources[Int(index)].entryUsage.formUnion(entryUsage)
            resources[Int(index)].binding = binding
            return
        }

        resourceIndexForMTLResource.set(key, Int32(resources.count))
        resources.append(
            BundleResourceEntry(
                mtlResource: mtlResource,
                usage: usage,
                renderStages: stages,
                entryUsage: entryUsage,
                binding: binding,
                resource: resource,
                tracking: tracking
            )
        )
    }

    private func addInputBuffer(_ buffer: borrowing WebGPU.Metal.Buffer, _ bufferImpl: BufferImpl, stage: MTLRenderStages) -> Bool {
        let mtlBuffer = bufferImpl.buffer()
        if let pass = replayPassImpl {
            if let mtlBuffer {
                let commandEncoder = pass.renderCommandEncoder()
                commandEncoder?.useResource(mtlBuffer, usage: .read, stages: stage)
                return commandEncoder != nil
            }
            pass.addResourceToActiveResources(bufferTracking(bufferImpl), .input, .buffer(bufferImpl))
            return pass.trackUse(.buffer(bufferImpl))
        }

        addResourceToMap(
            mtlBuffer,
            usage: .read,
            stages: stage,
            entryUsage: .input,
            binding: invalidBindingIndex,
            resource: [.buffer(copy buffer, bufferImpl)],
            tracking: bufferTracking(bufferImpl)
        )
        return true
    }

    // A resource with no WebGPU object (argument and dynamic-offset buffers).
    private func addInputResource(_ mtlResource: (any MTLResource)?, stage: MTLRenderStages) -> Bool {
        if let pass = replayPassImpl {
            let commandEncoder = pass.renderCommandEncoder()
            if let mtlResource {
                commandEncoder?.useResource(mtlResource, usage: .read, stages: stage)
            }
            return commandEncoder != nil
        }

        addResourceToMap(
            mtlResource,
            usage: .read,
            stages: stage,
            entryUsage: .input,
            binding: invalidBindingIndex,
            resource: [],
            tracking: nil
        )
        return true
    }

    // Outside a pass, adds each record to the resource map; in a pass, uses and tracks each record, then tracks each
    // again.
    private func addBindGroupResources(_ groupImpl: BindGroupImpl) -> Bool {
        let groupResources = groupImpl.resources
        let groupRecords = groupResources.records
        let groupLists = groupImpl.mtlResources
        for containerIndex in groupResources.containers.indices {
            let container = groupResources.containers[containerIndex]
            guard let pass = replayPassImpl else {
                for index in 0..<container.range.count {
                    let record = groupRecords[container.range.lowerBound + index]
                    let owner: [BoundResource] = record.resource >= 0 ? [groupResources.owners[Int(record.resource)]] : []
                    addResourceToMap(
                        groupLists[containerIndex][index],
                        usage: container.usage,
                        stages: container.renderStages,
                        entryUsage: record.usage,
                        binding: record.binding,
                        resource: owner,
                        tracking: record.tracking
                    )
                }
                continue
            }

            for index in 0..<container.range.count {
                let record = groupRecords[container.range.lowerBound + index]
                if container.renderStages.rawValue != 0 {
                    pass.renderCommandEncoder()?
                        .useResource(groupLists[containerIndex][index], usage: container.usage, stages: container.renderStages)
                }
                if !trackRecord(pass, record, addingToActiveResources: true) {
                    return false
                }
            }
            for record in groupRecords[container.range] where !trackRecord(pass, record, addingToActiveResources: false) {
                return false
            }
        }
        return true
    }

    // Adds the record to the pass's active resources (optionally) and tracks its use. Returns whether the pass still has
    // an encoder.
    private func trackRecord(_ pass: RenderPassEncoderImpl, _ record: UsageRecord, addingToActiveResources: Bool) -> Bool {
        guard let impl = record.impl else {
            return pass.renderCommandEncoder() != nil
        }
        if addingToActiveResources, let tracking = record.tracking {
            pass.addResourceToActiveResources(tracking, record.usage, impl)
        }
        return pass.trackUse(impl)
    }

    private func bindVertexArgumentBuffer(_ groupIndex: UInt32, _ groupImpl: BindGroupImpl) -> Bool {
        let vertexBindGroupBufferIndex = limits.slots.vertexBindGroupSlot(groupIndex).index
        if let argumentBuffer = groupImpl.argumentBuffers.vertex, vertexBuffers.count > vertexBindGroupBufferIndex {
            if !addInputResource(argumentBuffer, stage: .vertex) {
                return false
            }
            vertexBuffers[vertexBindGroupBufferIndex] = BundleBufferBinding(
                buffer: argumentBuffer,
                offset: 0,
                size: UInt64(argumentBuffer.length)
            )
        }
        return true
    }

    private func bindFragmentArgumentBuffer(_ groupIndex: UInt32, _ groupImpl: BindGroupImpl) {
        if let argumentBuffer = groupImpl.argumentBuffers.fragment, fragmentBuffers.count > Int(groupIndex) {
            if !addInputResource(argumentBuffer, stage: .fragment) {
                return
            }
            fragmentBuffers[Int(groupIndex)] = BundleBufferBinding(buffer: argumentBuffer, offset: 0, size: UInt64(argumentBuffer.length))
        }
    }

    @_expose(Cxx)
    func setIndexBuffer(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ buffer: borrowing WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ format: WebGPU.IndexFormat,
        _ offset: UInt64,
        _ hasSize: Bool,
        _ size: UInt64
    ) {
        if !validToEncodeCommand() {
            generateAValidationError(
                "void WebGPU::Metal::RenderBundleEncoder::setIndexBuffer(Buffer &, WebGPU::IndexFormat, uint64_t, std::optional<uint64_t>): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            return
        }
        let optionalSize: UInt64? = hasSize ? size : nil
        let rangeSize = bufferRangeSize(bufferImpl, offset, optionalSize)
        if indexBuffer.isEmpty {
            indexBuffer.append(copy buffer)
        } else {
            indexBuffer[0] = copy buffer
        }
        indexBufferImpl = bufferImpl
        indexType = format == WebGPU.IndexFormat.Uint32 ? .uint32 : .uint16
        indexBufferOffset = UInt(truncatingIfNeeded: offset)
        indexBufferSize = UInt(truncatingIfNeeded: rangeSize ?? 0)
        if let pass = replayPassImpl, !pass.trackUse(.buffer(bufferImpl)) {
            return
        }

        if !isValidToUse(bufferImpl.isValid(), bufferImpl.deviceImpl, with: deviceImpl) {
            invalidate("setIndexBuffer: invalid index buffer")
            return
        }

        if !replayingCommands() {
            if rangeSize == nil {
                invalidate("setIndexBuffer: computed size overflows")
                return
            }

            let indexSizeInBytes: UInt64 = format == WebGPU.IndexFormat.Uint16 ? 2 : 4
            if !hasUsage(bufferImpl, .Index) || offset % indexSizeInBytes != 0 {
                invalidate("setIndexBuffer: validation failed")
                return
            }

            if !isValidToUse(bufferImpl.isValid(), bufferImpl.deviceImpl, with: deviceImpl) {
                invalidate("setIndexBuffer: buffer is not valid")
                return
            }

            recordCommand(
                .setIndexBuffer(
                    owner: copy shell,
                    buffer: copy buffer,
                    bufferImpl: bufferImpl,
                    format: format,
                    offset: offset,
                    size: optionalSize
                )
            )
            return
        }

        _ = addInputBuffer(buffer, bufferImpl, stage: .vertex)
    }

    private func icbNeedsToBeSplit(_ a: RenderPipelineImpl, _ b: RenderPipelineImpl) -> Bool {
        if requiresCommandReplay || replayPassImpl != nil {
            return false
        }

        if a === b {
            return false
        }

        if a.sampleMask() != b.sampleMask() {
            return true
        }

        if a.parameters.cullMode != b.parameters.cullMode {
            return true
        }

        if a.parameters.frontFace != b.parameters.frontFace {
            return true
        }

        if a.parameters.depthClipMode != b.parameters.depthClipMode {
            return true
        }

        let aDepthStencil: MTLDepthStencilDescriptor? = a.depthStencilDescriptor()
        let bDepthStencil: MTLDepthStencilDescriptor? = b.depthStencilDescriptor()
        if (aDepthStencil != nil || bDepthStencil != nil) && !(aDepthStencil?.isEqual(bDepthStencil) ?? false) {
            return true
        }

        if a.parameters.depthBias != b.parameters.depthBias {
            return true
        }

        if a.parameters.depthBiasSlopeScale != b.parameters.depthBiasSlopeScale {
            return true
        }

        if a.parameters.depthBiasClamp != b.parameters.depthBiasClamp {
            return true
        }

        return false
    }

    private func splitICB(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, needsPipelineReset: Bool) {
        if UInt64(indirectCommandBuffer?.size ?? 0) > currentCommandIndex {
            if currentCommandIndex != 0 {
                let newICB = makeICB(shell, currentCommandIndex)
                indirectCommandBuffer = deviceImpl.defaultQueueImpl.trimICB(
                    deviceImpl.defaultQueue(),
                    newICB,
                    indirectCommandBuffer,
                    UInt(currentCommandIndex)
                )
            } else {
                indirectCommandBuffer = nil
            }
        }
        previousCommandCount &-= currentCommandIndex
        currentCommandIndex = 0

        if let icb = indirectCommandBuffer, icb.size != 0 {
            appendICB(shell, icb)
        }

        if previousCommandCount != 0 {
            indirectCommandBuffer = makeICB(shell, previousCommandCount)
        }
        cleanup(shell, resetPipeline: needsPipelineReset)
    }

    // The draw-validation maps move into the ICB.
    private func appendICB(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, _ icb: any MTLIndirectCommandBuffer) {
        let clampFunction: (any MTLFunction)? = deviceImpl.icbCommandClampFunction(.uint32)
        let argumentEncoder = clampFunction?.makeArgumentEncoder(bufferIndex: Int(deviceImpl.bufferIndexForICBContainer()))
        let container: (any MTLBuffer)? = deviceImpl.safeCreateBuffer(UInt(argumentEncoder?.encodedLength ?? 0))
        let outOfBoundsRead: (any MTLBuffer)? = deviceImpl.safeCreateBuffer(UInt(MemoryLayout<UInt32>.size))
        outOfBoundsRead?.label = "Out of bounds read flag"
        container?.label = "ICB Argument Buffer"
        argumentEncoder?.setArgumentBuffer(container, offset: 0)
        argumentEncoder?.setBuffer(outOfBoundsRead, offset: 0, index: 0)
        argumentEncoder?.setIndirectCommandBuffer(icb, index: 1)

        let bundleICB = BundleICB(
            indirectCommandBuffer: icb,
            indirectCommandBufferContainer: container,
            outOfBoundsReadFlag: outOfBoundsRead,
            renderPipelineState: currentPipelineState,
            depthStencilState: depthStencilState,
            cullMode: cullMode,
            frontFace: frontFace,
            depthClipMode: depthClipMode,
            depthBias: depthBias,
            depthBiasSlopeScale: depthBiasSlopeScale,
            depthBiasClamp: depthBiasClamp,
            fragmentDynamicOffsetsBuffer: dynamicOffsetsFragmentBuffer,
            indexValidations: minVertexCountForDrawCommand,
            indirectDraws: indirectDrawsForSlot
        )
        minVertexCountForDrawCommand.removeAll()
        indirectDrawsForSlot.removeAll()
        if !icbsDropped {
            icbs.append(bundleICB)
        }
    }

    private func ensureVertexDynamicOffsetsBuffer(_ shell: borrowing WebGPU.Metal.RenderBundleEncoder, _ size: UInt64) -> Bool {
        if dynamicOffsetsVertexBuffer != nil {
            return true
        }

        let buffer: (any MTLBuffer)? = deviceImpl.safeCreateBuffer(UInt(size))
        dynamicOffsetsVertexBuffer = buffer
        // A new MTLBuffer's contents are zero.
        dynamicOffsetsVertexContents = ContiguousArray(repeating: 0, count: uint32Count(buffer))
        return addInputResource(buffer, stage: .vertex)
    }

    private func ensureFragmentDynamicOffsetsBuffer(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ size: UInt64,
        _ sampleMask: UInt32
    ) -> Bool {
        if dynamicOffsetsFragmentBuffer != nil {
            return true
        }

        let buffer: (any MTLBuffer)? = deviceImpl.safeCreateBuffer(
            UInt(size &+ UInt64(startIndexForFragmentDynamicOffsets * MemoryLayout<Float>.size))
        )
        dynamicOffsetsFragmentBuffer = buffer
        var contents = ContiguousArray<UInt32>(repeating: 0, count: uint32Count(buffer))
        precondition(!contents.isEmpty)
        contents[0] = Float(0).bitPattern
        contents[1] = Float(1).bitPattern
        contents[2] = sampleMask
        dynamicOffsetsFragmentContents = contents
        return addInputResource(buffer, stage: .fragment)
    }

    private func writeSampleMaskToFragmentDynamicOffsets(_ sampleMask: UInt32) {
        dynamicOffsetsFragmentContents[2] = sampleMask
    }

    // Writes the contents through to the two buffers, before anything reads them on the GPU.
    private func clearDynamicOffsetsBuffers() {
        let vertexContents = dynamicOffsetsVertexContents
        let fragmentContents = dynamicOffsetsFragmentContents
        if let buffer = dynamicOffsetsVertexBuffer {
            WebGPU.Metal.copyDynamicOffsetsToBuffer(buffer, vertexContents.span)
        }
        if let buffer = dynamicOffsetsFragmentBuffer {
            WebGPU.Metal.copyDynamicOffsetsToBuffer(buffer, fragmentContents.span)
        }
        dynamicOffsetsFragmentBuffer = nil
        dynamicOffsetsVertexBuffer = nil
        dynamicOffsetsVertexContents = []
        dynamicOffsetsFragmentContents = []
    }

    @_expose(Cxx)
    func setPipeline(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ pipeline: borrowing WebGPU.Metal.RenderPipeline,
        _ pipelineImpl: RenderPipelineImpl
    ) {
        if !validToEncodeCommand() {
            generateAValidationError(
                "void WebGPU::Metal::RenderBundleEncoder::setPipeline(const RenderPipeline &): failed as encoding has finished"
            )
            return
        }
        applyPipeline(shell, pipeline, pipelineImpl)
    }

    private func applyPipeline(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ pipeline: borrowing WebGPU.Metal.RenderPipeline,
        _ pipelineImpl: RenderPipelineImpl
    ) {
        guard icbDescriptor != nil else {
            return
        }

        if !isValidToUse(pipelineImpl.isValid(), pipelineImpl.deviceImpl, with: deviceImpl) {
            invalidate("setPipeline: invalid index buffer")
            return
        }

        let previousRenderPipelineState = currentPipelineState
        currentPipelineState = icbRenderPipelineState(shell, pipelineImpl)

        if replayingCommands() {
            if let previousPipelineImpl = currentPipelineImpl, currentCommandIndex != 0,
                icbNeedsToBeSplit(previousPipelineImpl, pipelineImpl)
            {
                currentPipelineState = previousRenderPipelineState
                splitICB(shell, needsPipelineReset: false)
                currentPipelineState = icbRenderPipelineState(shell, pipelineImpl)
            }

            let previousDepthStencilState = depthStencilState
            let previousCullMode = cullMode
            let previousFrontFace = frontFace
            let previousDepthClipMode = depthClipMode
            let previousDepthBias = depthBias
            let previousDepthBiasSlopeScale = depthBiasSlopeScale
            let previousDepthBiasClamp = depthBiasClamp

            let parameters = pipelineImpl.parameters
            depthStencilState = pipelineImpl.depthStencilState()
            cullMode = parameters.cullMode
            frontFace = parameters.frontFace
            depthClipMode = parameters.depthClipMode
            primitiveType = parameters.primitiveType
            depthBias = parameters.depthBias
            depthBiasSlopeScale = parameters.depthBiasSlopeScale
            depthBiasClamp = parameters.depthBiasClamp
            sampleMask = parameters.sampleMask
            writeSampleMaskToFragmentDynamicOffsets(sampleMask)

            if let pass = replayPassImpl {
                if let error = pass.errorValidatingPipeline(pipelineImpl) {
                    invalidate(error)
                    return
                }

                let commandEncoder = pass.renderCommandEncoder()
                if let renderPipeline = currentPipelineState, previousRenderPipelineState !== renderPipeline {
                    commandEncoder?.setRenderPipelineState(renderPipeline)
                }
                if let state = depthStencilState, previousDepthStencilState !== state {
                    commandEncoder?.setDepthStencilState(state)
                }

                if previousCullMode != cullMode {
                    commandEncoder?.setCullMode(cullMode)
                }
                if previousFrontFace != frontFace {
                    commandEncoder?.setFrontFacing(frontFace)
                }
                if previousDepthClipMode != depthClipMode {
                    commandEncoder?.setDepthClipMode(depthClipMode)
                }
                if previousDepthBias != depthBias || previousDepthBiasSlopeScale != depthBiasSlopeScale
                    || previousDepthBiasClamp != depthBiasClamp
                {
                    commandEncoder?.setDepthBias(depthBias, slopeScale: depthBiasSlopeScale, clamp: depthBiasClamp)
                }
            }
        } else {
            if icbRenderPipelineState(shell, pipelineImpl) == nil {
                return
            }

            if !pipelineImpl.validateRenderBundle(
                depthReadOnly: depthReadOnly,
                stencilReadOnly: stencilReadOnly,
                sampleCount: sampleCount,
                colorFormats: colorFormats,
                depthStencilFormat: depthStencilFormat
            ) {
                invalidate("setPipeline: validation failed")
                return
            }

            // FIXME: Remove after https://bugs.webkit.org/show_bug.cgi?id=26499 is implemented
            if pipelineImpl.sampleMask() != defaultSampleMask {
                requiresCommandReplay = true
            }

            recordCommand(.setPipeline(owner: copy shell, pipeline: copy pipeline, pipelineImpl: pipelineImpl))
        }

        if currentPipeline.isEmpty {
            currentPipeline.append(copy pipeline)
        } else {
            currentPipeline[0] = copy pipeline
        }
        currentPipelineImpl = pipelineImpl
    }

    @_expose(Cxx)
    func setVertexBuffer(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ slot: UInt32,
        _ buffer: borrowing WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ offset: UInt64,
        _ hasSize: Bool,
        _ size: UInt64
    ) {
        if !validToEncodeCommand() {
            generateAValidationError(
                "void WebGPU::Metal::RenderBundleEncoder::setVertexBuffer(uint32_t, Buffer *, uint64_t, std::optional<uint64_t>): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            return
        }
        let optionalSize: UInt64? = hasSize ? size : nil
        let rangeSize = bufferRangeSize(bufferImpl, offset, optionalSize)
        maxVertexBufferSlot = max(maxVertexBufferSlot, slot)

        if !isValidToUse(bufferImpl.isValid(), bufferImpl.deviceImpl, with: deviceImpl) {
            invalidate("setVertexBuffer: invalid index buffer")
            return
        }

        if !replayingCommands() {
            if !isValidToUse(bufferImpl.isValid(), bufferImpl.deviceImpl, with: deviceImpl) {
                invalidate("setVertexBuffer: buffer is not valid")
                return
            }
            if rangeSize == nil {
                invalidate("setVertexBuffer: size overflowed")
                return
            }
            if slot >= limits.maxVertexBuffers || !hasUsage(bufferImpl, .Vertex) || offset % 4 != 0 {
                invalidate("setVertexBuffer: validation failed")
                return
            }

            recordCommand(
                .setVertexBuffer(
                    owner: copy shell,
                    slot: slot,
                    buffer: copy buffer,
                    bufferImpl: bufferImpl,
                    offset: offset,
                    size: optionalSize
                )
            )
        }

        // Validated when the command was recorded.
        guard let rangeSize else {
            preconditionFailure()
        }
        bindVertexBuffer(slot, buffer, bufferImpl, offset, rangeSize)
    }

    private func bindVertexBuffer(
        _ slot: UInt32,
        _ buffer: borrowing WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ offset: UInt64,
        _ size: UInt64
    ) {
        utilizedBufferIndices.add(slot) { size }
        if !addInputBuffer(buffer, bufferImpl, stage: .vertex) {
            return
        }

        vertexBuffers[Int(slot)] = BundleBufferBinding(buffer: bufferImpl.buffer(), offset: offset, size: size)
        if let pass = replayPassImpl {
            _ = pass.trackUse(.buffer(bufferImpl))
        }
    }

    // setVertexBuffer with a null buffer.
    @_expose(Cxx)
    func clearVertexBuffer(
        _ shell: borrowing WebGPU.Metal.RenderBundleEncoder,
        _ slot: UInt32,
        _ offset: UInt64,
        _ hasSize: Bool,
        _ size: UInt64
    ) {
        if !validToEncodeCommand() {
            generateAValidationError(
                "void WebGPU::Metal::RenderBundleEncoder::setVertexBuffer(uint32_t, Buffer *, uint64_t, std::optional<uint64_t>): failed as encoding has finished"
            )
            return
        }
        guard icbDescriptor != nil else {
            return
        }
        maxVertexBufferSlot = max(maxVertexBufferSlot, slot)

        if !replayingCommands() {
            recordCommand(.clearVertexBuffer(owner: copy shell, slot: slot, offset: offset, size: hasSize ? size : nil))
        }

        if slot < limits.maxVertexBuffers {
            utilizedBufferIndices.remove(slot)
        }
        if slot < vertexBuffers.count {
            vertexBuffers[Int(slot)] = BundleBufferBinding()
        }
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString) {
        indirectCommandBuffer?.label = label as String
    }

    // In replay mode: drops the map entries of destroyed resources.
    @_expose(!Cxx)
    func releaseDestroyedResources() {
        if resourcesDropped {
            return
        }

        let destroyed = resources.map { entry in entry.resource.first.map { $0.trackedImpl.placeholderIfDestroyed != nil } ?? false }
        if !destroyed.contains(true) {
            return
        }
        var kept: [BundleResourceEntry] = []
        kept.reserveCapacity(resources.count)
        for (index, entry) in resources.enumerated() where !destroyed[index] {
            kept.append(entry)
        }
        resources = kept
        resourceIndexForMTLResource.removeAll()
        for (index, entry) in resources.enumerated() {
            resourceIndexForMTLResource.set(identityKey(ObjectIdentifier(entry.mtlResource)), Int32(index))
        }
    }
}

func makeRenderBundleEncoderImpl(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ icbDescriptor: MTLIndirectCommandBufferDescriptor?,
    _ requiresCommandReplay: Bool,
    _ parameters: WebGPU.Metal.RenderBundleEncoderParameters
) -> RenderBundleEncoderImpl {
    RenderBundleEncoderImpl(
        device: device,
        deviceImpl: deviceImpl,
        icbDescriptor: icbDescriptor,
        requiresCommandReplay: requiresCommandReplay,
        parameters: parameters,
        lastErrorString: nil
    )
}

@_expose(Cxx)
func makeInvalidRenderBundleEncoderImpl(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ errorString: NSString?
) -> RenderBundleEncoderImpl {
    RenderBundleEncoderImpl(
        device: device,
        deviceImpl: deviceImpl,
        icbDescriptor: nil,
        requiresCommandReplay: false,
        parameters: WebGPU.Metal.RenderBundleEncoderParameters(),
        lastErrorString: errorString as String?
    )
}
