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
import WebGPU_Internal.ComputePassEncoder
import WebGPU_Internal.ComputePipeline
import WebGPU_Internal.Device
import WebGPU_Internal.PipelineLayout
import WebGPU_Private.WebGPUCpp

// The render stages of a bind group's compute resources.
private let computeRenderStage = MTLRenderStages(rawValue: 0)

/// What executePreDispatchCommands last gave the compute command encoder, so that a steady dispatch re-sends only what
/// changed (Metal keeps encoder state until it is changed).
///
/// The pipeline state's identity, and the gpuAddress (0 for none) of the argument buffer at each bind group index it has
/// set. ComputePassEncoderImpl.dispatchPipelineState keeps the pipeline state alive, so its identity cannot be reused.
/// The indirect-dispatch clamp, which sets a pipeline state and buffers of its own, resets it.
private struct DispatchStateCache {
    var pipelineState: ObjectIdentifier?
    private var argumentBufferAddresses = SIMD32<UInt64>()
    private var knownArgumentBuffers: UInt32 = 0

    func holdsArgumentBuffer(_ group: UInt32, _ address: UInt64) -> Bool {
        group < 32 && knownArgumentBuffers & (UInt32(1) << group) != 0 && argumentBufferAddresses[Int(group)] == address
    }

    mutating func recordArgumentBuffer(_ group: UInt32, _ address: UInt64) {
        guard group < 32 else {
            return
        }
        argumentBufferAddresses[Int(group)] = address
        knownArgumentBuffers |= UInt32(1) << group
    }
}

// One per GPUComputePassEncoder, owned by the C++ shell WebGPU::Metal::ComputePassEncoder through an opaque
// box. Owns all of the pass's state, runs the logic of every WebGPU::ComputePassEncoder method and reports its
// errors. A reported error can re-enter it from the device's uncaptured-error callback, so no method holds an access
// to a stored property across one.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_expose(Cxx)
final class ComputePassEncoderImpl {
    // nil once the pass is invalid, has ended or no longer holds its command encoder's current encoder.
    private var backingComputeCommandEncoder: (any MTLComputeCommandEncoder)?
    private let parentEncoder: WebGPU.Metal.CommandEncoder
    private let parentImpl: CommandEncoderImpl
    // The device's, copied at creation: immutable.
    private let limits: EncoderLimits
    // Zero or one element; an Array rather than an Optional FRT, to avoid the null-retain hazard. Hot paths read
    // currentPipelineImpl, which is non-nil exactly when this is not empty.
    private var currentPipeline: [WebGPU.Metal.ComputePipeline] = []
    private var currentPipelineImpl: ComputePipelineImpl?
    private var threadsPerThreadgroup = MTLSize(width: 0, height: 0, depth: 0)
    private var dispatchState = DispatchStateCache()
    private var dispatchPipelineState: (any MTLComputePipelineState)?
    private var debugGroupStackSize: UInt64 = 0
    private var lastErrorString: String?
    private var passEnded = false
    // A pass begun while its command encoder was not open never took the encoder over, so it can
    // never be ended. https://gpuweb.github.io/gpuweb/#dom-gpucomputepassencoder-end
    private var encoderStateWasNotOpen = false

    private var bindGroups = BindGroupTable()
    // The groups set since the last dispatch that tracked them, in their own WTF order. Each is also in bindGroups (both
    // are set and removed together), which is read for it.
    private var bindGroupsToTrack = GroupIndexOrder()
    private var bindGroupDynamicOffsets = GroupIndexedTable<[UInt32]>()
    /// identityKey of the Impl at each index of `bindGroups` (0 for none) and the indices with an entry in
    /// `bindGroupDynamicOffsets`, kept in step with them, so that setting a group's own bind group again without dynamic
    /// offsets reads neither table (both hold class references, so every access to them is checked at run time).
    private var boundGroupIdentities = SIMD32<UInt64>()
    private var groupsWithDynamicOffsets: UInt32 = 0
    private var computeDynamicOffsets: ContiguousArray<UInt32> = []
    private var priorComputeDynamicOffsets: ContiguousArray<UInt32> = []
    private var maxDynamicOffsetAtIndex = SIMD32<UInt32>()
    // The usage maps of one dispatch's tracking, kept between dispatches so that steady-state dispatches allocate
    // nothing.
    private var resourceUsages = DispatchUsageMap()
    private var subresourceUsages = DispatchUsageMap()
    // The parent encoder's device. Declared last, so that it outlives the rest of the pass.
    let device: WebGPU.Metal.Device

    fileprivate init(
        computeCommandEncoder: (any MTLComputeCommandEncoder)?,
        parentEncoder: WebGPU.Metal.CommandEncoder,
        parentImpl: CommandEncoderImpl,
        device: WebGPU.Metal.Device,
        lastErrorString: String?
    ) {
        self.backingComputeCommandEncoder = computeCommandEncoder
        self.parentEncoder = parentEncoder
        self.parentImpl = parentImpl
        self.device = device
        self.limits = parentImpl.deviceImpl.limits
        self.lastErrorString = lastErrorString
        precondition(Int(limits.maxBindGroups) <= maxBindGroupIndexCount)
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        backingComputeCommandEncoder != nil
    }

    // nil once the submit is known to be invalid.
    private func computeCommandEncoder() -> (any MTLComputeCommandEncoder)? {
        parentImpl.submitWillBeInvalid() ? nil : backingComputeCommandEncoder
    }

    // Whether a dispatch may skip a state the encoder already holds (DispatchStateCache). Not on x86_64, as for render
    // passes.
    private static var elidesRedundantStates: Bool {
        #if arch(x86_64)
        false
        #else
        true
        #endif
    }

    @_expose(Cxx)
    func markEncoderStateWasNotOpen() {
        encoderStateWasNotOpen = true
    }

    // Called from ~ComputePassEncoder, which must not pass the dying shell into Swift.
    @_expose(Cxx)
    func passWillBeDestroyed() {
        if backingComputeCommandEncoder != nil {
            parentImpl.makeInvalid("GPUComputePassEncoder.finish was never called")
        }
        backingComputeCommandEncoder = nil
    }

    // Out of line, so that the entry points that can report do no device work unless they report.
    @inline(never)
    private func generateAValidationError(_ message: String) {
        parentImpl.deviceImpl.generateAValidationError(message)
    }

    // When it returns true, the entry point reports its "failed as encoding has finished" error and returns. Those
    // messages name each entry point with its C++ __PRETTY_FUNCTION__ spelling.
    private func encodingHasFinished() -> Bool {
        if !parentImpl.isLocked() || parentImpl.isFinished() {
            backingComputeCommandEncoder = nil
            return true
        }
        return false
    }

    // Whether the pass still holds its command encoder's current encoder; entry points return when it does not.
    private func holdsCurrentEncoder() -> Bool {
        if let encoder = backingComputeCommandEncoder, parentImpl.isValid(), parentImpl.isCurrentEncoder(ObjectIdentifier(encoder)) {
            return true
        }
        backingComputeCommandEncoder = nil
        return false
    }

    private func makeInvalid(_ errorString: String? = nil) {
        lastErrorString = errorString

        guard let encoder = backingComputeCommandEncoder else {
            parentImpl.makeInvalid("RenderPassEncoder.makeInvalid")
            return
        }

        parentImpl.setLastError(errorString)
        parentImpl.endEncoding(encoder)
        backingComputeCommandEncoder = nil
    }

    private func executePreDispatchCommands(indirectBuffer indirectBufferImpl: BufferImpl?) {
        guard let pipelineImpl = currentPipelineImpl else {
            makeInvalid("pipeline is not set prior to dispatch")
            return
        }

        if !pipelineImpl.isValid() {
            makeInvalid("pipeline is not valid prior to dispatch")
            return
        }

        if let error = errorValidatingBindGroupCompatibility(pipelineImpl.pipelineLayoutImpl, { bindGroups[$0] }) {
            makeInvalid(error)
            return
        }
        if let computePipelineState = pipelineImpl.computePipelineState(), let encoder = computeCommandEncoder() {
            let identity = ObjectIdentifier(computePipelineState)
            if !Self.elidesRedundantStates || dispatchState.pipelineState != identity {
                encoder.setComputePipelineState(computePipelineState)
                dispatchState.pipelineState = identity
                dispatchPipelineState = computePipelineState
            }
        }

        if let error = encodeBindGroups(pipelineImpl, indirectBuffer: indirectBufferImpl) {
            makeInvalid(error)
        }
    }

    // The bind-group half of executePreDispatchCommands (encodeBindGroupsForDispatch). Returns the error that
    // invalidates the pass, or nil; also nil after the bind groups made the submit invalid, which leaves the pass valid.
    private func encodeBindGroups(_ pipelineImpl: ComputePipelineImpl, indirectBuffer indirectBufferImpl: BufferImpl?) -> String? {
        let layoutImpl = pipelineImpl.pipelineLayoutImpl
        let pipelineIdentifier = pipelineImpl.uniqueId()
        // Nothing in the walk below changes whether the submit will be invalid, except the early return.
        let encoder = computeCommandEncoder()
        for bindGroupIndex in bindGroups.order {
            guard let group = bindGroups[bindGroupIndex] else {
                continue
            }
            if group.hasSamplers {
                parentImpl.rebindSamplersPreCommit(bindGroups.shell(bindGroupIndex), group)
            }

            let maxOffset = maxDynamicOffsetAtIndex[Int(bindGroupIndex)]
            if !group.previouslyValidated(group: bindGroupIndex, pipelineId: pipelineIdentifier, maxOffset: maxOffset) {
                if group.makeSubmitInvalid(.compute, pipelineLayout: layoutImpl.bindGroupLayout(at: Int(bindGroupIndex))) {
                    parentImpl.makeSubmitInvalid(nil)
                    return nil
                }

                if let validationError = group.errorValidatingBindGroup(
                    pipelineImpl.minimumBufferSizes,
                    group: bindGroupIndex,
                    dynamicOffsets: bindGroupDynamicOffsets[bindGroupIndex]
                ) {
                    return validationError
                }
                group.validatedSuccessfully(group: bindGroupIndex, pipelineId: pipelineIdentifier, maxOffset: maxOffset)
            }
            if let encoder {
                let address = group.argumentBufferAddresses.compute
                if !Self.elidesRedundantStates || !dispatchState.holdsArgumentBuffer(bindGroupIndex, address) {
                    encoder.setBuffer(group.argumentBuffers.compute, offset: 0, index: limits.slots.bindGroupSlot(bindGroupIndex).index)
                    dispatchState.recordArgumentBuffer(bindGroupIndex, address)
                }
            }
        }

        if indirectBufferImpl != nil || !bindGroupsToTrack.isEmpty {
            resourceUsages.reset()
            subresourceUsages.reset()
        }
        if let indirectBufferImpl {
            _ = addResourceUsage(identityKey(ObjectIdentifier(indirectBufferImpl)), .input)
        }

        if !bindGroupsToTrack.isEmpty {
            let pipelineLayoutCount = layoutImpl.numberOfBindGroupLayouts()
            for bindGroupIndex in bindGroupsToTrack {
                guard Int(bindGroupIndex) < pipelineLayoutCount, let group = bindGroups[bindGroupIndex],
                    let bindGroupLayout = layoutImpl.bindGroupLayout(at: Int(bindGroupIndex))
                else {
                    continue
                }
                let resources = group.resources
                let records = resources.records
                for containerIndex in resources.containers.indices {
                    let range = resources.containers[containerIndex].range
                    for index in 0..<min(group.mtlResources[containerIndex].count, range.count) {
                        let record = records[range.lowerBound + index]
                        if !hasBindingAccess(bindGroupLayout, record.binding) {
                            continue
                        }
                        if !addResourceToActiveResources(record, bindGroupIndex) {
                            return "GPUComputePassEncoder.executePreDispatchCommands - could not track resource"
                        }
                    }
                }
            }
        }

        bindGroupsToTrack.removeAll()

        if computeDynamicOffsets.isEmpty {
            return nil
        }

        var dynamicOffsets: ContiguousArray<UInt32> = []
        swap(&dynamicOffsets, &computeDynamicOffsets)
        defer {
            swap(&dynamicOffsets, &computeDynamicOffsets)
        }
        var offsetsAreValid = true
        bindGroupDynamicOffsets.forEachInWTFOrder { bindGroupIndex, groupDynamicOffsets in
            if !offsetsAreValid {
                return
            }
            var destination = dynamicOffsets.mutableSpan
            offsetsAreValid = layoutImpl.updateOffsets(
                .compute,
                group: bindGroupIndex,
                dynamicOffsets: groupDynamicOffsets,
                destination: &destination
            )
        }
        if !offsetsAreValid {
            return "Invalid offset calculation"
        }

        if dynamicOffsets != priorComputeDynamicOffsets {
            WebGPU.Metal.setComputeDynamicOffsets(
                computeCommandEncoder(),
                dynamicOffsets.span,
                UInt(limits.slots.computeDynamicOffsets.rawValue)
            )
            // Element-wise, so that neither array shares the other's storage.
            priorComputeDynamicOffsets.removeAll(keepingCapacity: true)
            priorComputeDynamicOffsets.append(contentsOf: dynamicOffsets)
        }
        return nil
    }

    // Whether any stage of the pipeline's layout has the binding.
    private func hasBindingAccess(_ layout: BindGroupLayoutImpl, _ binding: UInt32) -> Bool {
        guard let entry = layout.entry(binding: binding) else {
            return false
        }
        return entry.bindingAccess(for: .vertex) != nil || entry.bindingAccess(for: .fragment) != nil
            || entry.bindingAccess(for: .compute) != nil
            || entry.bindingAccess(for: nil) != nil
    }

    private func addResourceToActiveResources(_ record: UsageRecord, _ bindGroup: UInt32) -> Bool {
        guard let impl = record.impl, let tracking = record.tracking else {
            return true
        }
        switch impl {
        case .buffer(let buffer):
            if record.usage.contains(.storage) {
                buffer.indirectBufferInvalidated(by: parentImpl)
            }
            return addResourceUsage(tracking.identity, record.usage)
        case .texture:
            return addSubresourceUsage(tracking.identity, record.usage, bindGroup, mipLevel: 0, arrayLayer: 0, aspect: .DepthOnly)
                && addSubresourceUsage(tracking.identity, record.usage, bindGroup, mipLevel: 0, arrayLayer: 0, aspect: .StencilOnly)
        case .textureView:
            if tracking.aspect != .All {
                return addSubresourceUsage(
                    tracking.identity,
                    record.usage,
                    bindGroup,
                    mipLevel: tracking.baseMipLevel,
                    arrayLayer: tracking.baseArrayLayer,
                    aspect: tracking.aspect
                )
            }
            return addSubresourceUsage(
                tracking.identity,
                record.usage,
                bindGroup,
                mipLevel: tracking.baseMipLevel,
                arrayLayer: tracking.baseArrayLayer,
                aspect: .DepthOnly
            )
                && addSubresourceUsage(
                    tracking.identity,
                    record.usage,
                    bindGroup,
                    mipLevel: tracking.baseMipLevel,
                    arrayLayer: tracking.baseArrayLayer,
                    aspect: .StencilOnly
                )
        case .externalTexture:
            return addResourceUsage(tracking.identity, record.usage)
        }
    }

    // The merged usage is stored.
    private func addResourceUsage(_ identity: UInt64, _ initialUsage: EntryUsage) -> Bool {
        resourceUsages.mergeUsage(identity, 0, initialUsage)
    }

    // An existing entry keeps its first usage and bind group. A new entry is inserted only once its usage is allowed;
    // a failed walk discards the map.
    private func addSubresourceUsage(
        _ texture: UInt64,
        _ initialUsage: EntryUsage,
        _ bindGroup: UInt32,
        mipLevel: UInt32,
        arrayLayer: UInt32,
        aspect: WebGPU.TextureAspect
    ) -> Bool {
        let entryKey = makeEntryMapKey(mipLevel, arrayLayer, aspect)
        guard let existing = subresourceUsages.value(texture, entryKey) else {
            if !initialUsage.isAllowed {
                return false
            }
            subresourceUsages.set(texture, entryKey, initialUsage, bindGroup: bindGroup)
            return true
        }
        if existing.bindGroup != bindGroup {
            if (initialUsage == .storageTextureWriteOnly && existing.usage == .storageTextureWriteOnly)
                || (initialUsage == .storageTextureReadWrite && existing.usage == .storageTextureReadWrite)
            {
                return false
            }
        }
        return initialUsage.union(existing.usage).isAllowed
    }

    @_expose(Cxx)
    func dispatch(_ x: UInt32, _ y: UInt32, _ z: UInt32) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::ComputePassEncoder::dispatch(uint32_t, uint32_t, uint32_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        executePreDispatchCommands(indirectBuffer: nil)
        let dimensionMax = limits.maxComputeWorkgroupsPerDimension
        if x > dimensionMax || y > dimensionMax || z > dimensionMax {
            makeInvalid(
                "x(\(x)) > dimensionMax(\(dimensionMax)) || y(\(y)) > dimensionMax(\(dimensionMax)) || z(\(z)) > dimensionMax(\(dimensionMax))"
            )
            return
        }

        // Wrapping: a product that wraps to 0 skips the dispatch.
        if x &* y &* z == 0 {
            return
        }

        computeCommandEncoder()?
            .dispatchThreadgroups(MTLSize(width: Int(x), height: Int(y), depth: Int(z)), threadsPerThreadgroup: threadsPerThreadgroup)
    }

    @_expose(Cxx)
    func dispatchIndirect(_ indirectBufferImpl: BufferImpl, _ indirectOffset: UInt64) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::ComputePassEncoder::dispatchIndirect(const Buffer &, uint64_t): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        if !isValidToUse(indirectBufferImpl.isValid(), indirectBufferImpl.deviceImpl, with: parentImpl.deviceImpl) {
            makeInvalid("GPUComputePassEncoder.dispatchIndirect: indirectBuffer is not valid to use with this GPUComputePassEncoder")
            return
        }

        let (indirectOffsetSum, hasOverflowed) = indirectOffset.addingReportingOverflow(UInt64(3 * MemoryLayout<UInt32>.size))
        let initialSize = indirectBufferImpl.initialSize()
        let usage = indirectBufferImpl.usageRawValue()
        let indirect = WebGPU.BufferUsage.Indirect.rawValue
        if indirectOffset % 4 != 0 || (usage & indirect) == 0 || hasOverflowed || indirectOffsetSum > initialSize {
            makeInvalid(
                "GPUComputePassEncoder.dispatchIndirect: (indirectOffset(\(indirectOffset)) mod 4) || !(indirectBuffer.usage(\(usage)) & BufferUsage::Indirect(\(indirect))) || indirectOffsetSum.hasOverflowed(\(hasOverflowed ? 1 : 0)) || (indirectOffsetSum(\(hasOverflowed ? 0 : indirectOffsetSum)) > indirectBuffer.initialSize(\(initialSize)))"
            )
            return
        }

        indirectBufferImpl.setCommandEncoder(parentImpl, mayModifyBuffer: false)
        if indirectBufferImpl.isDestroyed() {
            return
        }

        let dispatchBuffer = encodeIndirectDispatchClamp(computeCommandEncoder(), indirectBufferImpl.buffer(), indirectOffset)
        // The clamp set its own pipeline state and buffers 0 and 1.
        dispatchState = DispatchStateCache()
        guard let dispatchBuffer else {
            makeInvalid("GPUComputePassEncoder.dispatchWorkgroupsIndirect: Unable to validate dispatch size")
            return
        }
        executePreDispatchCommands(indirectBuffer: indirectBufferImpl)
        computeCommandEncoder()?
            .dispatchThreadgroups(indirectBuffer: dispatchBuffer, indirectBufferOffset: 0, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    // Clamps the indirect dispatch at `indirectOffset` into the device's dispatch-call buffer, which the dispatch then
    // reads, and returns that buffer; nil when the device has no clamp pipeline (or buffer).
    private func encodeIndirectDispatchClamp(
        _ encoder: (any MTLComputeCommandEncoder)?,
        _ indirectBuffer: (any MTLBuffer)?,
        _ indirectOffset: UInt64
    ) -> (any MTLBuffer)? {
        let deviceImpl = parentImpl.deviceImpl
        guard let pipelineState = deviceImpl.ensureDispatchCallPipelineState() else {
            return nil
        }
        let dispatchCallBuffer = deviceImpl.ensureDispatchCallBuffer()
        encoder?.setComputePipelineState(pipelineState)
        encoder?
            .setBuffer(
                indirectBuffer,
                offset: Int(truncatingIfNeeded: indirectOffset),
                index: HelperComputeSlot.indirectArguments.slot.index
            )
        encoder?.setBuffer(dispatchCallBuffer, offset: 0, index: HelperComputeSlot.clampedArguments.slot.index)
        encoder?.dispatchThreads(MTLSize(width: 3, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 3, height: 1, depth: 1))
        return dispatchCallBuffer
    }

    @_expose(Cxx)
    func endPass() {
        if passEnded {
            generateAValidationError("void WebGPU::Metal::ComputePassEncoder::endPass(): failed as pass is already ended")
            return
        }
        passEnded = true

        // https://gpuweb.github.io/gpuweb/#dom-gpucomputepassencoder-end
        // A pass begun while the command encoder was already locked by another pass never took the
        // encoder over. Ending it is a validation error the page can catch, not a silent no-op.
        if encoderStateWasNotOpen {
            generateAValidationError(
                "void WebGPU::Metal::ComputePassEncoder::endPass(): failed as the command encoder was not open when the pass began"
            )
            return
        }

        // Spelled out rather than encodingHasFinished() because ending a pass hands the command encoder
        // back and only then looks at whether the pass ended in a good state, so every path from here
        // unlocks the encoder. A pass that ended badly invalidates its encoder instead of leaving it
        // locked: a later pass can still be begun on an invalid encoder.
        if !parentImpl.isLocked() || parentImpl.isFinished() {
            backingComputeCommandEncoder = nil
            generateAValidationError("void WebGPU::Metal::ComputePassEncoder::endPass(): failed as encoding has finished")
            return
        }

        let passIsValid = isValid()
        if debugGroupStackSize != 0 || !passIsValid {
            // An already-invalidated pass has handed its command encoder back already.
            if let encoder = backingComputeCommandEncoder {
                parentImpl.endEncoding(encoder)
            }
            backingComputeCommandEncoder = nil
            parentImpl.lock(false)
            parentImpl.makeInvalid(
                "ComputePassEncoder.endPass failure, m_debugGroupStackSize = \(debugGroupStackSize), isValid = \(passIsValid ? 1 : 0), error = \(lastErrorString ?? "(null)")"
            )
            return
        }

        guard let encoder = backingComputeCommandEncoder, parentImpl.isValid(), parentImpl.encoderIsCurrent(encoder) else {
            backingComputeCommandEncoder = nil
            parentImpl.lock(false)
            parentImpl.makeInvalid("ComputePassEncoder.endPass: the pass no longer holds the command encoder")
            return
        }

        parentImpl.endEncoding(encoder)
        backingComputeCommandEncoder = nil
        parentImpl.lock(false)
    }

    // No encoder-state check: a pass's own encoder state is always open.
    @_expose(Cxx)
    func insertDebugMarker(_ markerLabel: NSString) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::ComputePassEncoder::insertDebugMarker(String &&): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-insertdebugmarker

        backingComputeCommandEncoder?.insertDebugSignpost(markerLabel as String)
    }

    private func validatePopDebugGroup() -> Bool {
        parentImpl.isLocked() && debugGroupStackSize != 0
    }

    @_expose(Cxx)
    func popDebugGroup() {
        if encodingHasFinished() {
            generateAValidationError("virtual void WebGPU::Metal::ComputePassEncoder::popDebugGroup(): failed as encoding has finished")
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-popdebuggroup

        if !validatePopDebugGroup() {
            makeInvalid()
            return
        }

        debugGroupStackSize -= 1
        backingComputeCommandEncoder?.popDebugGroup()
    }

    @_expose(Cxx)
    func pushDebugGroup(_ groupLabel: NSString) {
        if encodingHasFinished() {
            generateAValidationError(
                "virtual void WebGPU::Metal::ComputePassEncoder::pushDebugGroup(String &&): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder() else {
            return
        }
        // https://gpuweb.github.io/gpuweb/#dom-gpudebugcommandsmixin-pushdebuggroup

        debugGroupStackSize &+= 1
        backingComputeCommandEncoder?.pushDebugGroup(groupLabel as String)
    }

    private func validateGroupIndex(
        _ groupIndex: UInt32,
        expectedDynamicOffsetCount: UInt32,
        _ hasDynamicOffsets: Bool,
        _ dynamicOffsetCount: UInt
    ) -> Bool {
        if groupIndex >= limits.maxBindGroups || (hasDynamicOffsets && UInt(expectedDynamicOffsetCount) != dynamicOffsetCount) {
            makeInvalid("GPUComputePassEncoder.setBindGroup: groupIndex >= limits.maxBindGroups")
            return false
        }
        return true
    }

    // setBindGroup with a null bind group.
    @_expose(Cxx)
    func clearBindGroup(_ groupIndex: UInt32, _ hasDynamicOffsets: Bool, _ dynamicOffsetCount: UInt) {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::ComputePassEncoder::setBindGroup(uint32_t, const BindGroup *, std::optional<std::span<const uint32_t>>): failed as encoding has finished"
            )
            return
        }
        guard holdsCurrentEncoder(), validateGroupIndex(groupIndex, expectedDynamicOffsetCount: 0, hasDynamicOffsets, dynamicOffsetCount)
        else {
            return
        }
        bindGroups.remove(groupIndex)
        bindGroupsToTrack.remove(groupIndex)
        bindGroupDynamicOffsets.remove(groupIndex)
        boundGroupIdentities[Int(groupIndex)] = 0
        groupsWithDynamicOffsets &= ~(UInt32(1) << groupIndex)
        maxDynamicOffsetAtIndex[Int(groupIndex)] = 0
    }

    // Returns whether it stored a new bind group Impl, whose shell the shell then hands to storeBindGroupShell.
    @_expose(Cxx)
    func setBindGroup(
        _ groupIndex: UInt32,
        _ groupImpl: BindGroupImpl,
        _ hasDynamicOffsets: Bool,
        _ dynamicOffsets: borrowing WebGPU.Metal.DynamicOffsetsView
    ) -> Bool {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::ComputePassEncoder::setBindGroup(uint32_t, const BindGroup *, std::optional<std::span<const uint32_t>>): failed as encoding has finished"
            )
            return false
        }
        // The encoder keeps its own copy. Without dynamic offsets the span is empty.
        let offsets = hasDynamicOffsets ? copyDynamicOffsets(dynamicOffsets) : []
        let expectedDynamicOffsetCount = groupImpl.layoutImpl?.counts.dynamicBufferCount ?? 0
        guard holdsCurrentEncoder(),
            validateGroupIndex(groupIndex, expectedDynamicOffsetCount: expectedDynamicOffsetCount, hasDynamicOffsets, UInt(offsets.count))
        else {
            return false
        }

        if !isValidToUse(groupImpl.isValid(), groupImpl.deviceImpl, with: parentImpl.deviceImpl) {
            makeInvalid("GPUComputePassEncoder.setBindGroup: invalid bind group")
            return false
        }

        if groupImpl.layoutImpl == nil {
            makeInvalid("GPUComputePassEncoder.setBindGroup: bind group is nil")
            return false
        }

        // Without dynamic offsets and dynamic buffers there is nothing to check, and maxOffset stays as it is.
        if hasDynamicOffsets || expectedDynamicOffsetCount != 0 {
            var maxOffset = maxDynamicOffsetAtIndex[Int(groupIndex)]
            let error = groupImpl.errorValidatingDynamicOffsets(offsets, maxOffset: &maxOffset)
            maxDynamicOffsetAtIndex[Int(groupIndex)] = maxOffset
            if let error {
                makeInvalid("GPUComputePassEncoder.setBindGroup: \(error)")
                return false
            }
        }

        return commitBindGroup(groupIndex, groupImpl, offsets)
    }

    // The second step of a setBindGroup that returned true: `group` is the shell of the Impl it stored.
    @_expose(Cxx)
    func storeBindGroupShell(_ groupIndex: UInt32, _ group: WebGPU.Metal.BindGroup) {
        bindGroups.storeShell(groupIndex, group)
    }

    // Returns whether the shell has to hand in the group's shell.
    private func commitBindGroup(_ groupIndex: UInt32, _ groupImpl: BindGroupImpl, _ offsets: [UInt32]) -> Bool {
        let groupBit = UInt32(1) << groupIndex
        if !offsets.isEmpty {
            bindGroupDynamicOffsets.set(groupIndex, offsets)
            groupsWithDynamicOffsets |= groupBit
            maxDynamicOffsetAtIndex[Int(groupIndex)] = 0
        } else if groupsWithDynamicOffsets & groupBit != 0 {
            bindGroupDynamicOffsets.remove(groupIndex)
            groupsWithDynamicOffsets &= ~groupBit
            maxDynamicOffsetAtIndex[Int(groupIndex)] = 0
        }

        let resources = groupImpl.resources
        for containerIndex in resources.containers.indices {
            let container = resources.containers[containerIndex]
            guard container.renderStages == computeRenderStage else {
                continue
            }
            let list = groupImpl.mtlResources[containerIndex]
            if !list.isEmpty {
                computeCommandEncoder()?.useResources(list, usage: container.usage)
            }
        }
        resources.forEachDistinctImpl { impl in
            impl.setCommandEncoder(parentImpl)
        }

        if !bindGroupsToTrack.contains(groupIndex) {
            bindGroupsToTrack.add(groupIndex)
        }
        let identity = identityKey(ObjectIdentifier(groupImpl))
        if boundGroupIdentities[Int(groupIndex)] == identity {
            return false
        }
        bindGroups.setImpl(groupIndex, groupImpl)
        boundGroupIdentities[Int(groupIndex)] = identity
        return true
    }

    // Returns whether it stored a new pipeline Impl, whose shell the shell then hands to storePipelineShell.
    @_expose(Cxx)
    func setPipeline(_ pipelineImpl: ComputePipelineImpl) -> Bool {
        if encodingHasFinished() {
            generateAValidationError(
                "void WebGPU::Metal::ComputePassEncoder::setPipeline(const ComputePipeline &): failed as encoding has finished"
            )
            return false
        }
        guard holdsCurrentEncoder() else {
            return false
        }
        if !isValidToUse(pipelineImpl.isValid(), pipelineImpl.deviceImpl, with: parentImpl.deviceImpl) {
            makeInvalid("GPUComputePipeline is invalid to use with this GPUComputePassEncoder")
            return false
        }

        let isNewPipeline = currentPipelineImpl !== pipelineImpl
        if isNewPipeline {
            currentPipelineImpl = pipelineImpl
        }
        resetDynamicOffsets(pipelineImpl)

        assert(pipelineImpl.computePipelineState() != nil)
        threadsPerThreadgroup = pipelineImpl.threadsPerThreadgroup
        return isNewPipeline
    }

    // The second step of a setPipeline that returned true: `pipeline` is currentPipelineImpl's shell.
    @_expose(Cxx)
    func storePipelineShell(_ pipeline: WebGPU.Metal.ComputePipeline) {
        if currentPipeline.isEmpty {
            currentPipeline.append(pipeline)
        } else {
            currentPipeline[0] = pipeline
        }
    }

    // Zeroes the packed offsets, resized to the layout's total, and every group's maximum offset. The prior offsets
    // stay.
    private func resetDynamicOffsets(_ pipelineImpl: ComputePipelineImpl) {
        let size = Int(truncatingIfNeeded: pipelineImpl.pipelineLayoutImpl.dynamicOffsetTotal(.compute))
        if computeDynamicOffsets.count != size {
            computeDynamicOffsets = ContiguousArray<UInt32>(repeating: 0, count: size)
        } else if size != 0 {
            for index in computeDynamicOffsets.indices {
                computeDynamicOffsets[index] = 0
            }
        }
        maxDynamicOffsetAtIndex = SIMD32()
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString) {
        backingComputeCommandEncoder?.label = label as String
    }
}

// The subresource key of a texture's usage entry.
private func makeEntryMapKey(_ baseMipLevel: UInt32, _ baseArrayLayer: UInt32, _ aspect: WebGPU.TextureAspect) -> UInt64 {
    precondition(aspect != .All)
    let aspectBit: UInt64 = aspect == .DepthOnly ? 1 : 0
    return aspectBit | UInt64(baseMipLevel) << 1 | UInt64(baseArrayLayer) << 32
}

// A scratch hash map from (key, subresource) to a usage and bind group, for one dispatch's tracking. Lookups only, so
// its order never shows. reset() empties it in O(1) by moving to a new generation, and its storage is kept.
private struct DispatchUsageMap {
    private struct Slot {
        var generation: UInt32 = 0
        var key: UInt64 = 0
        var subresource: UInt64 = 0
        var usage = EntryUsage()
        var bindGroup: UInt32 = 0
    }

    private var slots: [Slot] = []
    private var generation: UInt32 = 1
    private var count = 0

    mutating func reset() {
        count = 0
        generation &+= 1
        if generation == 0 {
            for index in slots.indices {
                slots[index].generation = 0
            }
            generation = 1
        }
    }

    // The slot holding (key, subresource), or the free slot where it would go. `slots` is never full.
    @inline(__always)
    private func slotIndex(_ key: UInt64, _ subresource: UInt64) -> Int {
        let mask = slots.count - 1
        var index = Int(truncatingIfNeeded: wtfIntHash(key ^ (subresource &* 0x9e37_79b9_7f4a_7c15))) & mask
        while slots[index].generation == generation {
            if slots[index].key == key && slots[index].subresource == subresource {
                return index
            }
            index = (index + 1) & mask
        }
        return index
    }

    func value(_ key: UInt64, _ subresource: UInt64) -> (usage: EntryUsage, bindGroup: UInt32)? {
        if count == 0 {
            return nil
        }
        let slot = slots[slotIndex(key, subresource)]
        guard slot.generation == generation else {
            return nil
        }
        return (slot.usage, slot.bindGroup)
    }

    // value(key, subresource)'s usage merged into `usage`, stored if allowed, with one probe. Returns whether it was.
    mutating func mergeUsage(_ key: UInt64, _ subresource: UInt64, _ usage: EntryUsage) -> Bool {
        if (count + 1) * 2 > slots.count {
            grow()
        }
        let index = slotIndex(key, subresource)
        var merged = usage
        let isNew = slots[index].generation != generation
        if !isNew {
            merged.formUnion(slots[index].usage)
        }
        if !merged.isAllowed {
            return false
        }
        if isNew {
            count += 1
            slots[index] = Slot(generation: generation, key: key, subresource: subresource, usage: merged, bindGroup: 0)
        } else if merged != slots[index].usage {
            slots[index].usage = merged
        }
        return true
    }

    mutating func set(_ key: UInt64, _ subresource: UInt64, _ usage: EntryUsage, bindGroup: UInt32) {
        if (count + 1) * 2 > slots.count {
            grow()
        }
        let index = slotIndex(key, subresource)
        if slots[index].generation != generation {
            count += 1
        }
        slots[index] = Slot(generation: generation, key: key, subresource: subresource, usage: usage, bindGroup: bindGroup)
    }

    private mutating func grow() {
        let live = slots.filter { $0.generation == generation }
        slots = Array(repeating: Slot(), count: max(16, slots.count * 2))
        generation = 1
        for slot in live {
            slots[slotIndex(slot.key, slot.subresource)] = Slot(
                generation: 1,
                key: slot.key,
                subresource: slot.subresource,
                usage: slot.usage,
                bindGroup: slot.bindGroup
            )
        }
    }
}

@_expose(Cxx)
func makeComputePassEncoderImpl(
    _ computeCommandEncoder: (any MTLComputeCommandEncoder)?,
    _ parentEncoder: WebGPU.Metal.CommandEncoder,
    _ parentImpl: CommandEncoderImpl,
    _ device: WebGPU.Metal.Device
) -> ComputePassEncoderImpl {
    let impl = ComputePassEncoderImpl(
        computeCommandEncoder: computeCommandEncoder,
        parentEncoder: parentEncoder,
        parentImpl: parentImpl,
        device: device,
        lastErrorString: nil
    )
    parentImpl.lock(true)
    return impl
}

@_expose(Cxx)
func makeInvalidComputePassEncoderImpl(
    _ parentEncoder: WebGPU.Metal.CommandEncoder,
    _ parentImpl: CommandEncoderImpl,
    _ device: WebGPU.Metal.Device,
    _ errorString: NSString?
) -> ComputePassEncoderImpl {
    let impl = ComputePassEncoderImpl(
        computeCommandEncoder: nil,
        parentEncoder: parentEncoder,
        parentImpl: parentImpl,
        device: device,
        lastErrorString: errorString as String?
    )
    parentImpl.lock(true)
    parentImpl.setLastError(errorString as String?)
    return impl
}
