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
import WebGPU_Internal.BindGroupLayout
import WebGPU_Internal.Buffer
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Internal.ExternalTexture
import WebGPU_Internal.PresentationContext
import WebGPU_Internal.Queue
import WebGPU_Internal.Sampler
import WebGPU_Internal.Texture
import WebGPU_Internal.TextureView
import WebGPU_Private.WebGPU
import WebGPU_Private.WebGPUCpp

/// A buffer bound with a dynamic offset; a group keeps them sorted by bindingIndex.
struct DynamicBufferRecord {
    let type: LayoutBufferType
    let bindingSize: UInt64
    let bufferSize: UInt64
    let bindingIndex: UInt32
}

/// A sampler a bind group holds: one strong reference per distinct sampler, with its Impl (pair invariant) and the
/// argument-buffer slot it has in each stage.
struct SamplerBinding {
    let shell: WebGPU.Metal.Sampler
    let impl: SamplerImpl
    var slots: PerStage<UInt32?>
}

/// A bind group's layout shell, held for ownership only.
///
/// Every case has a payload, so the FRT never sits next to an empty case: an invalid group holds its device's Impl
/// instead.
private enum BindGroupLayoutShell {
    case layout(WebGPU.Metal.BindGroupLayout)
    case none(DeviceImpl)
}

// One per GPUBindGroup, owned by the C++ shell WebGPU::Metal::BindGroup. Owns the bound
// resources, the argument buffers, the layout, the samplers and their argument-buffer slots, the dynamic buffers and
// the per-pipeline validation cache, and runs every check the encoders make on a group. Used only on its Instance's API
// thread, so not Sendable.
@_expose(Cxx)
final class BindGroupImpl {
    /// Paired with layoutImpl: `.none` exactly when the group is invalid.
    private let layoutShell: BindGroupLayoutShell
    let layoutImpl: BindGroupLayoutImpl?
    /// nil when the stage has no arguments, or when a resource bound in it was destroyed before creation.
    let argumentBuffers: PerStage<(any MTLBuffer)?>
    /// The gpuAddress of each argument buffer (0 for none), which never changes: the encoders' binding caches key on it.
    let argumentBufferAddresses: PerStage<UInt64>
    /// The bound resources; `mtlResources` holds their MTLResources.
    let resources: ResourceSet
    @_expose(!Cxx)
    private(set) var mtlResources: ResourceLists
    /// In first-use order.
    @_expose(!Cxx)
    let samplerBindings: [SamplerBinding]
    let dynamicBuffers: [DynamicBufferRecord]
    private let externalTextureIndices: PerStage<WebGPU.Metal.ExternalTextureIndices>
    let uniqueId: UInt32
    // Pipelines this group already validated against, keyed by (group index, pipeline). A group is usually used with a
    // handful of pipelines, so a short array beats hashing on every draw; the rest spill over.
    private var recentValidations: [(key: UInt64, maxOffset: UInt32)] = []
    private var otherValidations: [UInt64: UInt32] = [:]
    // Declared last, so that the device outlives the rest of the group.
    let deviceImpl: DeviceImpl
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    fileprivate init(
        device: consuming DeviceShell,
        deviceImpl: DeviceImpl,
        layout: consuming ShellReference<WebGPU.Metal.BindGroupLayout>,
        layoutImpl: BindGroupLayoutImpl,
        argumentBuffers: consuming PerStage<(any MTLBuffer)?>,
        resources: consuming ResourceSet,
        mtlResources: consuming ResourceLists,
        samplerBindings: consuming [SamplerBinding],
        dynamicBuffers: consuming [DynamicBufferRecord],
        externalTextureIndices: PerStage<WebGPU.Metal.ExternalTextureIndices>,
        uniqueId: UInt32
    ) {
        layoutShell = .layout(layout.shell)
        self.layoutImpl = layoutImpl
        self.argumentBuffers = argumentBuffers
        argumentBufferAddresses = PerStage(
            vertex: argumentBuffers.vertex?.gpuAddress ?? 0,
            fragment: argumentBuffers.fragment?.gpuAddress ?? 0,
            compute: argumentBuffers.compute?.gpuAddress ?? 0
        )
        self.resources = resources
        self.mtlResources = mtlResources
        self.samplerBindings = samplerBindings
        self.dynamicBuffers = dynamicBuffers
        self.externalTextureIndices = externalTextureIndices
        self.uniqueId = uniqueId
        self.deviceImpl = deviceImpl
        self.device = device.shell
    }

    private init(invalidFor device: consuming DeviceShell, _ deviceImpl: DeviceImpl) {
        layoutShell = .none(deviceImpl)
        layoutImpl = nil
        argumentBuffers = PerStage(repeating: nil)
        argumentBufferAddresses = PerStage(repeating: 0)
        resources = .empty
        mtlResources = []
        samplerBindings = []
        dynamicBuffers = []
        externalTextureIndices = noExternalTextureIndices
        uniqueId = 0
        self.deviceImpl = deviceImpl
        self.device = device.shell
    }

    fileprivate static func invalid(_ device: consuming DeviceShell, _ deviceImpl: DeviceImpl) -> BindGroupImpl {
        BindGroupImpl(invalidFor: device, deviceImpl)
    }

    var hasSamplers: Bool {
        !samplerBindings.isEmpty
    }

    /// The layout's dynamic buffer count; 0 for an invalid group.
    var dynamicBufferCount: UInt32 {
        layoutImpl?.counts.dynamicBufferCount ?? 0
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        layoutImpl != nil
    }

    @_expose(Cxx)
    func setLabel(_ label: WTF.String) {
        let nsLabel = CxxBridging.convertWTFStringToNSString(label)
        argumentBuffers.vertex?.label = nsLabel as String?
        argumentBuffers.fragment?.label = nsLabel as String?
        argumentBuffers.compute?.label = nsLabel as String?
    }

    /// `minimumBufferSizes` is the pipeline's; `dynamicOffsets` the encoder's offsets for this group.
    func errorValidatingBindGroup(_ minimumBufferSizes: MinimumBufferSizes, group: UInt32, dynamicOffsets: [UInt32]?) -> String? {
        guard let layoutImpl else {
            return nil
        }
        // In container order: the first failure picks the message.
        for record in resources.records {
            guard case .buffer(let buffer) = record.impl else {
                continue
            }
            // nil when the layout has no entry for the binding; 0 for a non-buffer entry.
            let layoutMinBindingSize: UInt64? =
                switch layoutImpl.entry(binding: record.binding)?.layout {
                case .none: nil
                case .some(.buffer(let layoutBuffer)): layoutBuffer.minBindingSize
                case .some: 0
                }
            guard var bufferSize = layoutMinBindingSize else {
                return "Buffer size is missing for binding at index \(record.binding) bind group"
            }
            if let shaderSize = minimumBufferSizes.size(group: group, binding: record.binding) {
                if bufferSize != 0 && shaderSize > bufferSize {
                    return "buffer size from WGSL shader(\(shaderSize)) is less than the binding buffer size(\(bufferSize))"
                }
                bufferSize = max(bufferSize, shaderSize)
            }
            if bufferSize == 0 {
                continue
            }
            // The first dynamic buffer of the binding.
            var dynamicOffset: UInt32 = 0
            if let dynamicOffsets, let dynamicOffsetIndex = dynamicBuffers.firstIndex(where: { $0.bindingIndex == record.binding }),
                dynamicOffsetIndex < dynamicOffsets.count
            {
                dynamicOffset = dynamicOffsets[dynamicOffsetIndex]
            }
            let (totalOffset, overflowed) = record.entryOffset.addingReportingOverflow(UInt64(dynamicOffset))
            if overflowed {
                return "resourceOffset(\(record.entryOffset)) + dynamicOffset(\(dynamicOffset)) overflows uint64_t"
            }
            let bufferLength = buffer.currentSize()
            if totalOffset > bufferLength || bufferLength - totalOffset < bufferSize || bufferSize > record.entrySize {
                return
                    "buffer length(\(bufferLength)) minus offset(\(totalOffset)), (resourceOffset(\(record.entryOffset)) + dynamicOffset(\(dynamicOffset))), is less than required bufferSize(\(bufferSize))"
            }
        }
        return nil
    }

    /// For a valid group only: the encoders check that the group has a layout first.
    func errorValidatingDynamicOffsets(_ dynamicOffsets: [UInt32], maxOffset: inout UInt32) -> String? {
        guard let layoutImpl else {
            preconditionFailure("errorValidatingDynamicOffsets on an invalid bind group")
        }
        let bufferCount = layoutImpl.counts.dynamicBufferCount
        if dynamicOffsets.count != Int(bufferCount) {
            return
                "dynamicOffsetCount(\(dynamicOffsets.count)) in setBindGroupCall does not equal the dynamicBufferCount(\(bufferCount)) in bind group layout"
        }

        let uniformAlignment = deviceImpl.limits.uniformAlignment
        let storageAlignment = deviceImpl.limits.storageAlignment
        for (index, dynamicOffset) in dynamicOffsets.enumerated() {
            maxOffset = max(maxOffset, dynamicOffset)
            guard index < dynamicBuffers.count else {
                return "dynamicBuffer(\(index)) is nil"
            }
            let buffer = dynamicBuffers[index]
            let (dynamicOffsetPlusBindingSize, overflowed) = UInt64(dynamicOffset).addingReportingOverflow(buffer.bindingSize)
            if overflowed || dynamicOffsetPlusBindingSize > buffer.bufferSize {
                return
                    "dynamicBuffer(\(index)): dynamicOffset(\(dynamicOffset)) + buffer->bindingSize(\(buffer.bindingSize)) > buffer->bufferSize(\(buffer.bufferSize))"
            }

            let isUniform = buffer.type == .uniform
            if !(isUniform ? uniformAlignment : storageAlignment).isMultiple(dynamicOffset) {
                let alignment =
                    isUniform ? deviceImpl.limits.minUniformBufferOffsetAlignment : deviceImpl.limits.minStorageBufferOffsetAlignment
                return
                    "dynamicBuffer(\(index)): dynamicOffset(\(dynamicOffset)) is not divisible by the \(isUniform ? "uniform" : "storage") buffer alignment(\(alignment))"
            }
        }
        return nil
    }

    /// `pipelineLayout` is the pipeline's layout at the group's index.
    func makeSubmitInvalid(_ stage: Stage, pipelineLayout: BindGroupLayoutImpl?) -> Bool {
        guard let pipelineLayout, !pipelineLayout.entries.isEmpty else {
            return false
        }
        if !isValid() {
            return true
        }
        return UInt(argumentBuffers[stage]?.length ?? 0) != pipelineLayout.encodedLength(UInt8(stage.rawValue))
    }

    private static func validationKey(group: UInt32, pipelineId: UInt64) -> UInt64 {
        UInt64(group) | (pipelineId << 32)
    }

    func previouslyValidated(group: UInt32, pipelineId: UInt64, maxOffset: UInt32) -> Bool {
        let key = Self.validationKey(group: group, pipelineId: pipelineId)
        for validation in recentValidations where validation.key == key {
            return validation.maxOffset >= maxOffset
        }
        guard !otherValidations.isEmpty, let validatedOffset = otherValidations[key] else {
            return false
        }
        return validatedOffset >= maxOffset
    }

    func validatedSuccessfully(group: UInt32, pipelineId: UInt64, maxOffset: UInt32) {
        let key = Self.validationKey(group: group, pipelineId: pipelineId)
        if let index = recentValidations.firstIndex(where: { $0.key == key }) {
            recentValidations[index].maxOffset = max(recentValidations[index].maxOffset, maxOffset)
        } else if let existing = otherValidations[key] {
            otherValidations[key] = max(existing, maxOffset)
        } else if recentValidations.count < 8 {
            recentValidations.append((key: key, maxOffset: maxOffset))
        } else {
            otherValidations[key] = maxOffset
        }
    }

    func rebindSamplersIfNeeded() -> Bool {
        guard let layoutImpl else {
            return true
        }
        for binding in samplerBindings {
            let sampler = binding.impl
            if sampler.cachedSamplerState() != nil {
                continue
            }
            WebGPU.Metal.logAlways(
                "Rebinding of samplers required, if this occurs frequently the application is using too many unique samplers"
            )
            guard let samplerState = sampler.tryCacheSamplerState() else {
                return false
            }
            for stage in Stage.allCases {
                guard let slot = binding.slots[stage], let encoder = layoutImpl.argumentEncoder(stage), let buffer = argumentBuffers[stage]
                else {
                    continue
                }
                encoder.setArgumentBuffer(buffer, offset: 0)
                encoder.setSamplerState(samplerState, index: Int(slot))
            }
        }
        return true
    }

    /// Called from the shell's constructor: each resource keeps a weak reference to the shell
    /// (CxxBridging.BindGroupHolders).
    @_expose(Cxx)
    func registerAsResourceHolder(_ shell: WebGPU.Metal.BindGroup) {
        resources.registerBindGroupHolder(shell)
    }

    @_expose(Cxx)
    func releaseDestroyedResources() {
        modifyMTLResources { lists in
            _ = resources.replaceDestroyedResourcesWithPlaceholders(&lists)
        }
    }

    /// Mutates `mtlResources` outside any access to it: it is moved out and back, so that no release happens during an
    /// access and the per-setBindGroup reads need no runtime exclusivity check.
    private func modifyMTLResources(_ body: (inout ResourceLists) -> Void) {
        var lists: ResourceLists = []
        swap(&lists, &mtlResources)
        body(&lists)
        swap(&lists, &mtlResources)
    }

    @_expose(Cxx)
    func updateExternalTextures(_ externalTexture: ExternalTextureImpl) -> Bool {
        guard let layoutImpl, externalTexture.openCommandEncoderCount() == 0, !externalTexture.hasPendingUsers() else {
            return false
        }

        let imported = importBoundExternalTexture(device, deviceImpl, externalTexture)
        let placeholder = deviceImpl.placeholderTexture(false)
        let texture0 = imported.texture0 ?? placeholder
        let texture1 = imported.texture1 ?? placeholder
        externalTexture.updateExternalTextures(texture0, texture1)
        guard let texture0, let texture1 else {
            return false
        }
        var constants = imported.constants
        constants.visibleWidth = externalTexture.visibleWidth()
        constants.visibleHeight = externalTexture.visibleHeight()

        let notFound = UInt(bitPattern: NSNotFound)
        for stage in Stage.allCases {
            let indices = externalTextureIndices[stage]
            let index = indices.argumentBufferIndex
            let resourceIndex = indices.resourceIndex
            let containerIndex = indices.containerIndex
            if index == notFound || containerIndex >= UInt(mtlResources.count) {
                continue
            }
            let resourceCount = UInt(mtlResources[Int(containerIndex)].count)
            if resourceIndex >= resourceCount || resourceIndex &+ 1 >= resourceCount {
                continue
            }

            modifyMTLResources { lists in
                lists[Int(containerIndex)][Int(resourceIndex)] = texture0
                lists[Int(containerIndex)][Int(resourceIndex) + 1] = texture1
            }

            guard let encoder = layoutImpl.argumentEncoder(stage), let buffer = argumentBuffers[stage] else {
                continue
            }
            encoder.setArgumentBuffer(buffer, offset: 0)
            encoder.setTexture(texture0, index: Int(truncatingIfNeeded: index))
            encoder.setTexture(texture1, index: Int(truncatingIfNeeded: index &+ 1))
            WebGPU.Metal.writeExternalTextureConstants(encoder, index &+ 2, constants)
        }
        return true
    }
}

@_expose(Cxx)
func makeInvalidBindGroupImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> BindGroupImpl {
    .invalid(DeviceShell(shell: device), deviceImpl)
}

extension BindGroupLayoutImpl {
    fileprivate func argumentEncoder(_ stage: Stage) -> (any MTLArgumentEncoder)? {
        switch stage {
        case .vertex: vertexArgumentEncoder()
        case .fragment: fragmentArgumentEncoder()
        case .compute: computeArgumentEncoder()
        }
    }
}

/// Imports the external texture's pixel buffer as premultiplied; a destroyed external texture imports nothing.
private func importBoundExternalTexture(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ externalTexture: ExternalTextureImpl
) -> (texture0: (any MTLTexture)?, texture1: (any MTLTexture)?, constants: WebGPU.Metal.ExternalTextureConstants) {
    guard let pixelBuffer = externalTexture.pixelBuffer() else {
        return (nil, nil, WebGPU.Metal.ExternalTextureConstants())
    }
    let colorSpace = WebGPU.PredefinedColorSpace(rawValue: externalTexture.colorSpaceRawValue()) ?? .SRGB
    let imported = deviceImpl.externalTextureImporter.importPixelBuffer(device, deviceImpl, pixelBuffer, colorSpace, premultiplyAlpha: true)
    return (imported.texture0, imported.texture1, imported.constants)
}

// MARK: - Creation (Device::createBindGroup)

/// Buffer and sampler shells as ShellReferences, so that the add functions borrow them instead of retaining them around
/// their calls.
private enum DescriptorResource {
    case buffer(ShellReference<WebGPU.Metal.Buffer>, BufferImpl, sameDevice: Bool, offset: UInt64, size: UInt64?)
    case sampler(ShellReference<WebGPU.Metal.Sampler>, SamplerImpl, sameDevice: Bool)
    case texture(WebGPU.Metal.Texture, TextureImpl, sameDevice: Bool)
    case textureView(WebGPU.Metal.TextureView, TextureViewImpl, sameDevice: Bool)
    case externalTexture(WebGPU.Metal.ExternalTexture, ExternalTextureImpl)
}

private struct DescriptorEntry {
    let binding: UInt32
    let resource: DescriptorResource
}

/// Creates the bind groups of Device::createBindGroup.
///
/// The C++ shell appends the descriptor's entries in order, then finish() validates them (the first failure is reported
/// and gives an invalid Impl) and builds the Impl. One per device (DeviceImpl.bindGroupBuilder), reused: finish() takes
/// its scratch arrays out before anything can re-enter, and puts them back emptied only if no nested createBindGroup
/// took over.
final class BindGroupBuilder {
    private var entries: [DescriptorEntry] = []

    init() {
    }

    /// Clears the entries of a creation that never finished.
    ///
    /// Checked with a read first, so the usual case makes no modify access.
    fileprivate func begin() {
        if !entries.isEmpty {
            entries.removeAll(keepingCapacity: true)
        }
    }

    /// Built by the caller from its own parameters, so that the entry's references are the only ones made.
    fileprivate func append(_ entry: consuming DescriptorEntry) {
        entries.append(entry)
    }

    fileprivate func finish(
        _ device: consuming DeviceShell,
        _ deviceImpl: DeviceImpl,
        _ layout: consuming ShellReference<WebGPU.Metal.BindGroupLayout>,
        _ layoutImpl: BindGroupLayoutImpl
    ) -> BindGroupImpl {
        var entries: [DescriptorEntry] = []
        swap(&entries, &self.entries)
        let impl = makeBindGroupImpl(device, deviceImpl, layout, layoutImpl, &entries)
        entries.removeAll(keepingCapacity: true)
        if self.entries.capacity == 0 {
            swap(&entries, &self.entries)
        }
        return impl
    }
}

/// Takes the device and layout references the group keeps; an invalid group drops the layout's.
///
/// Takes the entries out of `entries`, in order, leaving its buffer for the builder to reuse.
private func makeBindGroupImpl(
    _ device: consuming DeviceShell,
    _ deviceImpl: DeviceImpl,
    _ layout: consuming ShellReference<WebGPU.Metal.BindGroupLayout>,
    _ layoutImpl: BindGroupLayoutImpl,
    _ entries: inout [DescriptorEntry]
) -> BindGroupImpl {
    guard deviceImpl.isValid() else {
        return .invalid(device, deviceImpl)
    }

    let isAutoGenerated = layoutImpl.counts.isAutoGenerated
    if !layoutImpl.isValid() || (!isAutoGenerated && entries.count != layoutImpl.entries.count) || layoutImpl.deviceImpl !== deviceImpl {
        reportBindGroupError(device.shell, "invalid BindGroupLayout createBindGroup")
        return .invalid(device, deviceImpl)
    }

    var creation = BindGroupCreation(deviceImpl: deviceImpl, layoutImpl: layoutImpl)
    if creation.argumentBufferAllocationFailed {
        deviceImpl.generateAnOutOfMemoryError("GPUDevice.createBindGroup: the argument buffer could not be allocated")
        return .invalid(device, deviceImpl)
    }
    var usedBindingSlots = SmallIndexSet()
    // Popped from the reversed list rather than read in place, which would copy each entry's references.
    entries.reverse()
    while let entry = entries.popLast() {
        if !usedBindingSlots.insert(entry.binding) {
            reportBindGroupError(device.shell, "Binding \(entry.binding) is duplicated in the bind group descriptor")
            return .invalid(device, deviceImpl)
        }
        if !creation.add(entry, device: device) {
            if let message = creation.error {
                reportBindGroupError(device.shell, message)
            }
            return .invalid(device, deviceImpl)
        }
    }

    for stage in Stage.allCases where !creation.argumentIndices[stage].isEmpty {
        return .invalid(device, deviceImpl)
    }

    // Sorted before the resources are built; nothing between reads it.
    if creation.dynamicBuffers.count > 1 {
        creation.dynamicBuffers.sort { $0.bindingIndex < $1.bindingIndex }
    }
    let (resources, mtlResources) = creation.buildResources()
    for stage in Stage.allCases {
        if let buffer = creation.argumentBuffers[stage] {
            WebGPU.Metal.copyArgumentEncoderLabel(layoutImpl.argumentEncoder(stage), buffer)
        }
    }

    if deviceImpl.bindGroupIdsExhausted() {
        deviceImpl.loseTheDevice(WebGPU.DeviceLostReason.Unknown)
        return .invalid(device, deviceImpl)
    }

    // The shell registers the group as a holder of its resources once it exists (registerAsResourceHolder).
    return creation.makeImpl(
        device: device,
        layout: layout,
        resources: consume resources,
        mtlResources: consume mtlResources,
        uniqueId: deviceImpl.takeBindGroupId()
    )
}

/// Device::createBindGroup calls beginBindGroup, then an append function for each descriptor entry in order, then
/// finishBindGroup.
///
/// The builder is DeviceImpl's, reached through it so that C++ holds no reference to it.
@_expose(Cxx)
func beginBindGroup(_ deviceImpl: DeviceImpl) {
    assert(wtfHashReplicaMatchesWTF, "EncoderModel.swift's WTFHashMap no longer iterates in WTF::HashTable order")
    deviceImpl.bindGroupBuilder.begin()
}

@_expose(Cxx)
func appendBindGroupBuffer(
    _ deviceImpl: DeviceImpl,
    _ binding: UInt32,
    _ buffer: WebGPU.Metal.Buffer,
    _ impl: BufferImpl,
    _ offset: UInt64,
    _ hasSize: Bool,
    _ size: UInt64
) {
    deviceImpl.bindGroupBuilder.append(
        DescriptorEntry(
            binding: binding,
            resource: .buffer(
                ShellReference(shell: buffer),
                impl,
                sameDevice: impl.deviceImpl === deviceImpl,
                offset: offset,
                size: hasSize ? size : nil
            )
        )
    )
}

@_expose(Cxx)
func appendBindGroupSampler(_ deviceImpl: DeviceImpl, _ binding: UInt32, _ sampler: WebGPU.Metal.Sampler, _ impl: SamplerImpl) {
    deviceImpl.bindGroupBuilder.append(
        DescriptorEntry(
            binding: binding,
            resource: .sampler(ShellReference(shell: sampler), impl, sameDevice: impl.deviceImpl === deviceImpl)
        )
    )
}

@_expose(Cxx)
func appendBindGroupTexture(_ deviceImpl: DeviceImpl, _ binding: UInt32, _ texture: WebGPU.Metal.Texture, _ impl: TextureImpl) {
    deviceImpl.bindGroupBuilder.append(
        DescriptorEntry(binding: binding, resource: .texture(texture, impl, sameDevice: impl.deviceImpl === deviceImpl))
    )
}

@_expose(Cxx)
func appendBindGroupTextureView(_ deviceImpl: DeviceImpl, _ binding: UInt32, _ view: WebGPU.Metal.TextureView, _ impl: TextureViewImpl) {
    deviceImpl.bindGroupBuilder.append(
        DescriptorEntry(binding: binding, resource: .textureView(view, impl, sameDevice: impl.deviceImpl === deviceImpl))
    )
}

@_expose(Cxx)
func appendBindGroupExternalTexture(
    _ deviceImpl: DeviceImpl,
    _ binding: UInt32,
    _ texture: WebGPU.Metal.ExternalTexture,
    _ impl: ExternalTextureImpl
) {
    deviceImpl.bindGroupBuilder.append(DescriptorEntry(binding: binding, resource: .externalTexture(texture, impl)))
}

@_expose(Cxx)
func finishBindGroup(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ layout: WebGPU.Metal.BindGroupLayout,
    _ layoutImpl: BindGroupLayoutImpl
) -> BindGroupImpl {
    deviceImpl.bindGroupBuilder.finish(DeviceShell(shell: device), deviceImpl, ShellReference(shell: layout), layoutImpl)
}

/// A Set<UInt32> that keeps values below 64 in a bit mask, so that the usual binding and argument indices allocate
/// nothing.
private struct SmallIndexSet {
    private var mask: UInt64 = 0
    private var others = Set<UInt32>()

    init() {
    }

    init(_ values: [UInt32]) {
        for value in values {
            _ = insert(value)
        }
    }

    /// The set of the values below 64 whose bits are set.
    init(bits: UInt64) {
        mask = bits
    }

    var isEmpty: Bool {
        mask == 0 && others.isEmpty
    }

    /// Set.insert(_:).inserted.
    mutating func insert(_ value: UInt32) -> Bool {
        guard value < 64 else {
            return others.insert(value).inserted
        }
        let bit = UInt64(1) << value
        if mask & bit != 0 {
            return false
        }
        mask |= bit
        return true
    }

    mutating func remove(_ value: UInt32) {
        if value < 64 {
            mask &= ~(UInt64(1) << value)
        } else {
            others.remove(value)
        }
    }
}

private func reportBindGroupError(_ device: WebGPU.Metal.Device, _ message: String) {
    device.generateAValidationError("GPUDevice.createBindGroup: \(message)")
}

/// The stage slots: vertex, fragment, compute, then one for entries visible to no stage.
///
/// Slots 0-2 are Stage raw values. Containers are built in slot order.
private let stageSlotCount = 4

/// The MTLRenderStages raw value of each stage slot: 0 for compute and 3 for the slot of no stage.
private func renderStagesRawValue(forSlot slot: Int) -> UInt {
    switch slot {
    case 0: 1
    case 1: 2
    case 2: 0
    default: 3
    }
}

/// Every stage's ExternalTextureIndices, all NSNotFound.
private var noExternalTextureIndices: PerStage<WebGPU.Metal.ExternalTextureIndices> {
    PerStage(
        repeating: WebGPU.Metal.ExternalTextureIndices(
            containerIndex: UInt(NSNotFound),
            resourceIndex: UInt(NSNotFound),
            argumentBufferIndex: UInt(NSNotFound)
        )
    )
}

/// Resources are bucketed by MTLResourceUsage (Read, Write, ReadWrite), at index usage - 1.
private let resourceUsageCount = 3

/// What the bind group checks read from a Texture or TextureView, after clearing it.
private struct BoundTexture {
    let owner: BoundResource
    let tracking: TrackingInfo
    let sameDevice: Bool
    let isDestroyed: Bool
    let isValid: Bool
    let usage: UInt8
    let sampleCount: UInt32
    let format: WebGPU.TextureFormat
    let aspect: WebGPU.TextureAspect
    let texture: (any MTLTexture)?
    let sampledTexture: (any MTLTexture)?
    let hasSwizzle: Bool
    let is2DTexture: Bool
    let mipLevelCount: UInt32
}

/// The state of one bind group creation.
///
/// Holds no Device reference: the caller reports `error` with its own.
private struct BindGroupCreation {
    let deviceImpl: DeviceImpl
    let layoutImpl: BindGroupLayoutImpl
    let uniformAlignment: PowerOfTwo
    let storageAlignment: PowerOfTwo
    // Printed in the alignment error, whichever alignment failed.
    let minStorageBufferOffsetAlignment: UInt32
    let maxUniformBufferBindingSize: UInt64
    let maxStorageBufferBindingSize: UInt64
    var float32Filterable: Bool {
        deviceImpl.hasFeature(WebGPU.FeatureName.Float32Filterable)
    }
    var encoders: PerStage<(any MTLArgumentEncoder)?>
    var argumentBuffers = PerStage<(any MTLBuffer)?>(repeating: nil)
    var argumentIndices = PerStage<SmallIndexSet>(repeating: SmallIndexSet())
    /// Every resource's record, owner and MTLResource, in the order they were added.
    ///
    /// A record's `resource` is its own index (one owner per record) until buildResources orders them by bucket
    /// (stage slot * resourceUsageCount + MTLResourceUsage - 1).
    var records: [UsageRecord] = []
    var owners = OwnerList()
    var mtlResources: [any MTLResource] = []
    /// The number of resources in each bucket.
    var bucketCounts = SIMD16<UInt32>()
    /// Each record's bucket, kept only once a record arrives in a lower bucket than the one before it; until then the
    /// records are already in bucket order.
    var recordBuckets: [UInt8]?
    var lastBucket = 0
    var dynamicBuffers: [DynamicBufferRecord] = []
    var samplerBindings: [SamplerBinding] = []
    var externalTextureIndices = noExternalTextureIndices
    /// A stage with arguments has no argument buffer: nothing may be encoded, since the argument encoders' writes
    /// (constantDataAtIndex: among them) would have no buffer to go to.
    private(set) var argumentBufferAllocationFailed = false
    /// The validation error that made add() fail, for the caller to report.
    private(set) var error: String?

    init(deviceImpl: DeviceImpl, layoutImpl: BindGroupLayoutImpl) {
        self.deviceImpl = deviceImpl
        self.layoutImpl = layoutImpl
        uniformAlignment = deviceImpl.limits.uniformAlignment
        storageAlignment = deviceImpl.limits.storageAlignment
        minStorageBufferOffsetAlignment = deviceImpl.capabilities.limits.minStorageBufferOffsetAlignment
        maxUniformBufferBindingSize = deviceImpl.capabilities.limits.maxUniformBufferBindingSize
        maxStorageBufferBindingSize = deviceImpl.capabilities.limits.maxStorageBufferBindingSize
        encoders = PerStage(
            vertex: layoutImpl.vertexArgumentEncoder(),
            fragment: layoutImpl.fragmentArgumentEncoder(),
            compute: layoutImpl.computeArgumentEncoder()
        )
        for stage in Stage.allCases {
            let encodedLength = layoutImpl.encodedLength(UInt8(stage.rawValue))
            if encodedLength != 0 {
                argumentBuffers[stage] = deviceImpl.safeCreateBuffer(encodedLength, .shared)
                if argumentBuffers[stage] == nil {
                    argumentBufferAllocationFailed = true
                }
            }
            encoders[stage]?.setArgumentBuffer(argumentBuffers[stage], offset: 0)
            argumentIndices[stage] =
                layoutImpl.argumentIndexBits[stage].map { SmallIndexSet(bits: $0) } ?? SmallIndexSet(layoutImpl.argumentIndices[stage])
        }
    }

    /// Every caller returns false at once, and add() returns that straight to makeBindGroupImpl, which reports it.
    mutating func reportError(_ message: String) {
        error = message
    }

    /// Appends one MTLResource and its usage record to bucket `bucket`.
    @inline(__always)
    mutating func append(
        bucket: Int,
        mtlResource: any MTLResource,
        usage: EntryUsage,
        binding: UInt32,
        entryOffset: UInt64,
        entrySize: UInt64,
        owner: BoundResource,
        tracking: TrackingInfo
    ) {
        if recordBuckets == nil && bucket < lastBucket {
            var buckets: [UInt8] = []
            buckets.reserveCapacity(records.count + 1)
            for earlierBucket in 0..<(stageSlotCount * resourceUsageCount) {
                buckets.append(contentsOf: repeatElement(UInt8(earlierBucket), count: Int(bucketCounts[earlierBucket])))
            }
            recordBuckets = buckets
        }
        recordBuckets?.append(UInt8(bucket))
        lastBucket = bucket
        bucketCounts[bucket] &+= 1
        records.append(
            UsageRecord(
                usage: usage,
                binding: binding,
                entryOffset: entryOffset,
                entrySize: entrySize,
                resource: Int32(records.count),
                impl: owner.trackedImpl,
                tracking: tracking
            )
        )
        owners.append(owner)
        mtlResources.append(mtlResource)
    }

    mutating func removeArgumentIndices(_ stage: Stage, from first: UInt32, count: UInt32) {
        for offset in 0..<count {
            argumentIndices[stage].remove(first &+ offset)
        }
    }

    /// Adds one descriptor entry in every stage slot; false when the group is invalid.
    @inline(__always)
    mutating func add(_ entry: borrowing DescriptorEntry, device: borrowing DeviceShell) -> Bool {
        let layoutEntry = layoutImpl.entry(binding: entry.binding)
        var bindingContainedInStage = false
        var appendedBufferToDynamicBuffers = false
        for slot in 0..<stageSlotCount {
            let stage = Stage(rawValue: slot)
            guard let layoutEntry, let index = argumentBufferIndexForEntry(layoutEntry, stage) else {
                continue
            }
            bindingContainedInStage = true
            guard let access = layoutEntry.bindingAccess(for: stage) else {
                preconditionFailure("A bind group layout entry without an access for a stage it has an argument in")
            }
            let usageIndex = resourceUsageIndex(access)

            let succeeded: Bool
            switch entry.resource {
            case .buffer(let shell, let impl, let sameDevice, let offset, let size):
                succeeded = addBuffer(
                    entry.binding,
                    shell,
                    impl,
                    sameDevice: sameDevice,
                    offset: offset,
                    size: size,
                    layoutEntry: layoutEntry,
                    stage: stage,
                    slot: slot,
                    index: index,
                    usageIndex: usageIndex,
                    appendedToDynamicBuffers: &appendedBufferToDynamicBuffers
                )
            case .sampler(let shell, let impl, let sameDevice):
                succeeded = addSampler(shell, impl, sameDevice: sameDevice, layoutEntry: layoutEntry, stage: stage, index: index)
            case .texture(let shell, let impl, let sameDevice):
                succeeded = addTexture(
                    entry.binding,
                    .texture(shell, impl, sameDevice: sameDevice),
                    layoutEntry: layoutEntry,
                    stage: stage,
                    slot: slot,
                    index: index,
                    usageIndex: usageIndex
                )
            case .textureView(let shell, let impl, let sameDevice):
                succeeded = addTexture(
                    entry.binding,
                    .textureView(shell, impl, sameDevice: sameDevice),
                    layoutEntry: layoutEntry,
                    stage: stage,
                    slot: slot,
                    index: index,
                    usageIndex: usageIndex
                )
            case .externalTexture(let shell, let impl):
                succeeded = addExternalTexture(
                    entry.binding,
                    shell,
                    impl,
                    device: device,
                    layoutEntry: layoutEntry,
                    stage: stage,
                    slot: slot,
                    index: index,
                    usageIndex: usageIndex
                )
            }
            if !succeeded {
                return false
            }
        }

        if !bindingContainedInStage && !layoutImpl.counts.isAutoGenerated {
            reportError("Binding \(Int32(bitPattern: entry.binding)) was not contained in the bind group")
            return false
        }
        return true
    }

    @inline(__always)
    mutating func addBuffer(
        _ binding: UInt32,
        _ shell: borrowing ShellReference<WebGPU.Metal.Buffer>,
        _ buffer: BufferImpl,
        sameDevice: Bool,
        offset: UInt64,
        size: UInt64?,
        layoutEntry: LayoutEntry,
        stage: Stage?,
        slot: Int,
        index: UInt32,
        usageIndex: Int,
        appendedToDynamicBuffers: inout Bool
    ) -> Bool {
        guard case .buffer(let layoutBinding) = layoutEntry.layout else {
            reportError("Expected buffer but it was not present in the bind group layout")
            return false
        }
        let mtlBuffer = buffer.buffer()
        let isDestroyed = buffer.isDestroyed()
        if isDestroyed, let stage {
            encoders[stage] = nil
            argumentBuffers[stage] = nil
        }

        let bufferLength = UInt64(mtlBuffer?.length ?? 0)
        let entryOffset = isDestroyed ? 0 : offset
        let bufferLengthMinusOffset = bufferLength > entryOffset ? bufferLength - entryOffset : 0
        let entrySize = size ?? bufferLengthMinusOffset
        if layoutBinding.hasDynamicOffset && !appendedToDynamicBuffers {
            dynamicBuffers.append(
                DynamicBufferRecord(
                    type: layoutBinding.type,
                    bindingSize: entrySize,
                    bufferSize: bufferLengthMinusOffset,
                    bindingIndex: binding
                )
            )
            appendedToDynamicBuffers = true
        }

        if !buffer.isValid() || !sameDevice {
            if !isDestroyed {
                reportError("Buffer is invalid or created from a different device")
            }
            return false
        }

        let isUniformBuffer = layoutBinding.type == .uniform
        let isStorageBuffer = layoutBinding.type == .storage || layoutBinding.type == .readOnlyStorage
        if !buffer.isDestroyed() {
            if offset >= bufferLength {
                reportError("Unexpected entry.offset(\(offset)) >= buffer length(\(bufferLength))")
                return false
            }

            if !hasProperUsageFlags(layoutBinding.type, buffer.usageRawValue()) {
                reportError("Unexpected type(\(layoutBinding.type.rawValue)), buffer.usage(\(apiBufferUsage(buffer.usageRawValue())))")
                return false
            }

            if (isUniformBuffer && !uniformAlignment.isMultiple(offset)) || (isStorageBuffer && !storageAlignment.isMultiple(offset)) {
                reportError("Buffer offset(\(offset)) is not a multiple of the device buffer alignment(\(minStorageBufferOffsetAlignment))")
                return false
            }

            if (isUniformBuffer && entrySize > maxUniformBufferBindingSize) || (isStorageBuffer && entrySize > maxStorageBufferBindingSize)
            {
                reportError(
                    "Buffer size(\(entrySize)) is larger than the device limits(\(isUniformBuffer ? maxUniformBufferBindingSize : maxStorageBufferBindingSize))"
                )
                return false
            }
            if isStorageBuffer && entrySize % 4 != 0 {
                reportError("Storage buffer size(\(entrySize)) is not multiple of 4")
                return false
            }
            if entrySize == 0 || entrySize &+ entryOffset > bufferLength
                || (layoutBinding.minBindingSize != 0 && layoutBinding.minBindingSize > entrySize)
            {
                reportError(
                    "entrySize == 0 or entrySize(\(entrySize)) + entryOffset(\(entryOffset)) > buffer size(\(bufferLength)) or layoutBinding->minBindingSize(\(layoutBinding.minBindingSize)) > entrySize(\(entrySize))"
                )
                return false
            }
        }

        if let stage, bufferLength != 0 {
            argumentIndices[stage].remove(index)
            encoders[stage]?.setBuffer(mtlBuffer, offset: Int(truncatingIfNeeded: entryOffset), index: Int(index))
            if let bufferSizeIndex = layoutEntry.bufferSizeArgumentBufferIndices[stage] {
                argumentIndices[stage].remove(bufferSizeIndex)
                WebGPU.Metal.writeBufferLengthConstant(
                    encoders[stage],
                    UInt(bufferSizeIndex),
                    min(UInt32(truncatingIfNeeded: entrySize), UInt32(truncatingIfNeeded: bufferLength))
                )
            }
        }
        if let mtlBuffer {
            let tracking = TrackingInfo(
                kind: .buffer,
                identity: identityKey(ObjectIdentifier(buffer)),
                baseMipLevel: 0,
                mipLevelCount: 0,
                baseArrayLayer: 0,
                arrayLayerCount: 0,
                aspect: .All
            )
            append(
                bucket: slot * resourceUsageCount + usageIndex,
                mtlResource: mtlBuffer,
                usage: entryUsage(layoutBinding.type),
                binding: binding,
                entryOffset: entryOffset,
                entrySize: entrySize,
                owner: .buffer(shell.shell, buffer),
                tracking: tracking
            )
        }
        return true
    }

    mutating func addSampler(
        _ shell: borrowing ShellReference<WebGPU.Metal.Sampler>,
        _ sampler: SamplerImpl,
        sameDevice: Bool,
        layoutEntry: LayoutEntry,
        stage: Stage?,
        index: UInt32
    ) -> Bool {
        guard case .sampler(let layoutBinding) = layoutEntry.layout else {
            reportError("Expected sampler but it was not present in the bind group layout")
            return false
        }
        if !sampler.isValid() || !sameDevice {
            reportError("Underlying sampler is not valid or created from a different device")
            return false
        }
        if !samplerTypeMatches(layoutBinding.type, sampler) {
            reportError("Expected sampler type(\(layoutBinding.type.rawValue)) has wrong comparison or filtering modes")
            return false
        }

        let samplerState = sampler.tryCacheSamplerState()
        guard let stage else {
            return true
        }
        argumentIndices[stage].remove(index)
        encoders[stage]?.setSamplerState(samplerState, index: Int(index))
        // A group holds a few samplers at most, so a walk finds a repeat.
        let samplerIndex: Int
        if let existing = samplerBindings.firstIndex(where: { $0.impl === sampler }) {
            samplerIndex = existing
        } else {
            samplerIndex = samplerBindings.count
            samplerBindings.append(SamplerBinding(shell: shell.shell, impl: sampler, slots: PerStage(repeating: nil)))
        }
        samplerBindings[samplerIndex].slots[stage] = index
        return true
    }

    enum TextureResource {
        case texture(WebGPU.Metal.Texture, TextureImpl, sameDevice: Bool)
        case textureView(WebGPU.Metal.TextureView, TextureViewImpl, sameDevice: Bool)
    }

    /// Clears the texture if it needs it, then reads the state the checks use.
    ///
    /// nil when the texture could not be zero-filled: nothing may read it uninitialized. A texture of another device is
    /// rejected later, so it is not touched.
    func clearAndRead(_ resource: TextureResource) -> BoundTexture? {
        switch resource {
        case .texture(let shell, let impl, let sameDevice):
            if sameDevice && !deviceImpl.defaultQueue().clearTextureViewIfNeeded(shell) {
                return nil
            }
            let texture = impl.texture()
            return BoundTexture(
                owner: .texture(shell, impl),
                tracking: TrackingInfo(
                    kind: .texture,
                    identity: identityKey(ObjectIdentifier(impl)),
                    baseMipLevel: 0,
                    mipLevelCount: impl.mipLevelCount(),
                    baseArrayLayer: 0,
                    arrayLayerCount: impl.arrayLayerCount(),
                    aspect: .All
                ),
                sameDevice: sameDevice,
                isDestroyed: impl.isDestroyed(),
                isValid: impl.isValid(),
                usage: impl.usage(),
                sampleCount: impl.sampleCount(),
                format: impl.formatOrDefault,
                aspect: .All,
                texture: texture,
                sampledTexture: texture,
                hasSwizzle: false,
                is2DTexture: impl.is2DTexture(),
                mipLevelCount: impl.mipLevelCount()
            )
        case .textureView(let shell, let impl, let sameDevice):
            if sameDevice && !deviceImpl.defaultQueue().clearTextureViewIfNeeded(shell) {
                return nil
            }
            let aspect = WebGPU.TextureAspect(rawValue: impl.aspect()) ?? .All
            return BoundTexture(
                owner: .textureView(shell, impl),
                tracking: TrackingInfo(
                    kind: .textureView,
                    identity: identityKey(ObjectIdentifier(impl.parentTextureImpl)),
                    baseMipLevel: impl.baseMipLevel(),
                    mipLevelCount: impl.mipLevelCount(),
                    baseArrayLayer: impl.baseArrayLayer(),
                    arrayLayerCount: impl.arrayLayerCount(),
                    aspect: aspect
                ),
                sameDevice: sameDevice,
                isDestroyed: impl.isDestroyed(),
                isValid: impl.isValid(),
                usage: impl.usage(),
                sampleCount: impl.sampleCount(),
                format: impl.formatOrDefault,
                aspect: aspect,
                texture: impl.texture(),
                sampledTexture: impl.sampledTexture(),
                hasSwizzle: impl.hasSwizzle(),
                is2DTexture: impl.is2DTexture(),
                mipLevelCount: impl.mipLevelCount()
            )
        }
    }

    mutating func addTexture(
        _ binding: UInt32,
        _ resource: TextureResource,
        layoutEntry: LayoutEntry,
        stage: Stage?,
        slot: Int,
        index: UInt32,
        usageIndex: Int
    ) -> Bool {
        let textureEntry: TextureLayout?
        let storageTextureEntry: StorageTextureLayout?
        let isExternalTextureEntry: Bool
        switch layoutEntry.layout {
        case .texture(let layout):
            (textureEntry, storageTextureEntry, isExternalTextureEntry) = (layout, nil, false)
        case .storageTexture(let layout):
            (textureEntry, storageTextureEntry, isExternalTextureEntry) = (nil, layout, false)
        case .externalTexture:
            (textureEntry, storageTextureEntry, isExternalTextureEntry) = (nil, nil, true)
        case .buffer, .sampler:
            reportError("Expected texture or storage texture but it was not present in the bind group layout")
            return false
        }

        guard let bound = clearAndRead(resource) else {
            reportError("Lazy zero-initialization of the texture failed")
            return false
        }
        let texture = textureEntry != nil && !isExternalTextureEntry ? bound.sampledTexture : bound.texture
        if !bound.isDestroyed {
            if !bound.isValid {
                reportError("Underlying texture is not valid")
                return false
            }
            if !bound.sameDevice {
                reportError("Underlying texture was created from a different device")
                return false
            }
            if (textureEntry != nil && !textureUsageContains(bound.usage, .TextureBinding))
                || (storageTextureEntry != nil && !textureUsageContains(bound.usage, .StorageBinding))
            {
                reportError(
                    "Storage texture usage(\(apiTextureUsage(bound.usage))) did not have storage usage or storage texture entry did not have storage binding"
                )
                return false
            }
            if let textureEntry, (textureEntry.multisampled ? 4 : 1) != bound.sampleCount {
                reportError(
                    "Bind group entry multisampled(\(textureEntry.multisampled ? 1 : 0)) state does not match underlying texture sample count(\(Int32(bitPattern: bound.sampleCount)))"
                )
                return false
            }
            if !layoutImpl.counts.isAutoGenerated, let textureEntry, !sampleTypeMatches(textureEntry.sampleType, bound.format, bound.aspect)
            {
                reportError(
                    "Bind group entry sampleType(\(sampleTypeName(textureEntry.sampleType))) does not match TextureView sampleType(\(formatSampleTypeNames(bound.format, bound.aspect))) for texture format(\(textureFormatName(bound.format)))"
                )
                return false
            }
            let textureType = bound.texture?.textureType ?? .type1D
            if !viewDimensionMatches(textureEntry?.viewDimension, textureType)
                || !viewDimensionMatches(storageTextureEntry?.viewDimension, textureType)
            {
                reportError("Bind group entry viewDimension does not match TextureView viewDimension")
                return false
            }
            if let storageTextureEntry, storageTextureEntry.format != bound.format {
                reportError("Bind group storage texture entry format does not match TextureView format")
                return false
            }
            if storageTextureEntry != nil && bound.hasSwizzle {
                reportError("Storage textures must be bound through a view whose swizzle is \"rgba\"")
                return false
            }
            if storageTextureEntry != nil, (bound.texture?.mipmapLevelCount ?? 0) != 1 {
                reportError("Storage textures must have a single mip level(\(bound.texture?.mipmapLevelCount ?? 0))")
                return false
            }

            if let textureEntry, isFloat32Format(texture),
                !isValidFloat32SampleType(textureEntry.sampleType) || (textureEntry.sampleType == .Float && !float32Filterable)
            {
                reportError(
                    "Can not create bind group with filterable 32bpp floating point texture as float32-filterable feature is not enabled"
                )
                return false
            }
            if isExternalTextureEntry {
                if !textureUsageContains(bound.usage, .TextureBinding) {
                    reportError(
                        "Can not create bind group with a texture view set to an external texture slot which does not have usage containing texture binding."
                    )
                    return false
                }
                if !bound.is2DTexture {
                    reportError(
                        "Can not create bind group with a texture view set to an external texture slot when the texture view is not a 2D texture."
                    )
                    return false
                }
                if bound.mipLevelCount != 1 {
                    reportError(
                        "Can not create bind group with a texture view set to an external texture slot when the texture view has more than 1 mip level"
                    )
                    return false
                }
                if !isAllowedExternalTextureFormat(bound.format) {
                    reportError(
                        "Can not create bind group with a texture view set to an external texture which is not an allowed external texture format"
                    )
                    return false
                }
                if bound.sampleCount != 1 {
                    reportError(
                        "Can not create bind group with a texture view set to an external texture which has a sample count greater than 1"
                    )
                    return false
                }
            }
        } else if let stage {
            encoders[stage] = nil
            argumentBuffers[stage] = nil
        }

        // An external texture slot is six arguments wide and every one has to be written, or an argument index stays
        // unconsumed and the group is invalid. A plain view is one plane already in its color space: identity uv and
        // color conversions, and the all-zero primaries matrix that means "no conversion". Its texels are taken as
        // premultiplied.
        if isExternalTextureEntry {
            let secondPlane = chromaPlaneFromRGB(texture, alphaFirst: false, premultiplied: true)
            if let stage {
                removeArgumentIndices(stage, from: index, count: 6)
                encoders[stage]?.setTexture(texture, index: Int(index))
                encoders[stage]?.setTexture(secondPlane, index: Int(index) + 1)
                var constants = WebGPU.Metal.ExternalTextureConstants()
                constants.uvRemapping = (1, 0, 0, 1, 0, 0)
                constants.colorSpaceConversion = (1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)
                constants.visibleWidth = UInt32(truncatingIfNeeded: texture?.width ?? 0)
                constants.visibleHeight = UInt32(truncatingIfNeeded: texture?.height ?? 0)
                WebGPU.Metal.writeExternalTextureConstants(encoders[stage], UInt(index) + 2, constants)
            }
            for plane in [texture, secondPlane] {
                guard let plane else {
                    continue
                }
                append(
                    bucket: slot * resourceUsageCount + usageIndex,
                    mtlResource: plane,
                    usage: .constantTexture,
                    binding: binding,
                    entryOffset: 0,
                    entrySize: 0,
                    owner: bound.owner,
                    tracking: bound.tracking
                )
            }
            return true
        }

        if let stage {
            argumentIndices[stage].remove(index)
            encoders[stage]?.setTexture(texture, index: Int(index))
        }
        if let texture {
            let usage = storageTextureEntry.map { entryUsage($0.access) } ?? .constantTexture
            append(
                bucket: slot * resourceUsageCount + usageIndex,
                mtlResource: texture,
                usage: usage,
                binding: binding,
                entryOffset: 0,
                entrySize: 0,
                owner: bound.owner,
                tracking: bound.tracking
            )
        }
        return true
    }

    mutating func addExternalTexture(
        _ binding: UInt32,
        _ shell: WebGPU.Metal.ExternalTexture,
        _ externalTexture: ExternalTextureImpl,
        device: borrowing DeviceShell,
        layoutEntry: LayoutEntry,
        stage: Stage?,
        slot: Int,
        index: UInt32,
        usageIndex: Int
    ) -> Bool {
        guard case .externalTexture = layoutEntry.layout else {
            reportError("Expected external texture but it was not present in the bind group layout")
            return false
        }

        let imported = importBoundExternalTexture(device.shell, deviceImpl, externalTexture)
        let placeholder = deviceImpl.placeholderTexture(false)
        let texture0 = imported.texture0 ?? placeholder
        if let stage {
            externalTextureIndices[stage].argumentBufferIndex = UInt(index)
            externalTextureIndices[stage].resourceIndex = UInt(bucketCounts[slot * resourceUsageCount + usageIndex])
        }
        let tracking = TrackingInfo(
            kind: .externalTexture,
            identity: identityKey(ObjectIdentifier(externalTexture)),
            baseMipLevel: 0,
            mipLevelCount: 0,
            baseArrayLayer: 0,
            arrayLayerCount: 0,
            aspect: .All
        )
        if let texture0 {
            append(
                bucket: slot * resourceUsageCount + usageIndex,
                mtlResource: texture0,
                usage: .constantTexture,
                binding: binding,
                entryOffset: 0,
                entrySize: 0,
                owner: .externalTexture(shell, externalTexture),
                tracking: tracking
            )
        }
        let texture1 = imported.texture1 ?? placeholder
        if let texture1 {
            append(
                bucket: slot * resourceUsageCount + usageIndex,
                mtlResource: texture1,
                usage: .constantTexture,
                binding: binding,
                entryOffset: 0,
                entrySize: 0,
                owner: .externalTexture(shell, externalTexture),
                tracking: tracking
            )
        }

        if let stage {
            removeArgumentIndices(stage, from: index, count: 6)
            externalTexture.updateExternalTextures(texture0, texture1)
            encoders[stage]?.setTexture(texture0, index: Int(index))
            encoders[stage]?.setTexture(texture1, index: Int(index) + 1)
            var constants = imported.constants
            constants.visibleWidth = externalTexture.visibleWidth()
            constants.visibleHeight = externalTexture.visibleHeight()
            WebGPU.Metal.writeExternalTextureConstants(encoders[stage], UInt(index) + 2, constants)
        }
        return true
    }

    /// One container per non-empty (stage slot, usage) bucket, in slot order.
    ///
    /// Each stage records its read-only container for the external texture refresh.
    @inline(__always)
    mutating func buildResources() -> (resources: ResourceSet, mtlResources: ResourceLists) {
        if let recordBuckets {
            orderByBucket(recordBuckets)
        }
        var containerCount = 0
        for bucket in 0..<stageSlotCount * resourceUsageCount where bucketCounts[bucket] != 0 {
            containerCount += 1
        }
        var containers = ResourceContainers()
        var lists: ResourceLists = []
        var allResources: [any MTLResource] = []
        swap(&allResources, &mtlResources)
        if containerCount == 1, let bucket = (0..<stageSlotCount * resourceUsageCount).first(where: { bucketCounts[$0] != 0 }) {
            // The usual group: one container, whose list is every resource.
            let slot = bucket / resourceUsageCount
            let usageIndex = bucket % resourceUsageCount
            if let stage = Stage(rawValue: slot), usageIndex == 0 {
                externalTextureIndices[stage].containerIndex = 0
            }
            containers.append(
                recordCount: Int(bucketCounts[bucket]),
                usage: MTLResourceUsage(rawValue: UInt(usageIndex + 1)),
                renderStages: MTLRenderStages(rawValue: renderStagesRawValue(forSlot: slot))
            )
            lists.append(consume allResources)
            return (ResourceSet(containers: containers, records: takeRecords(), owners: takeOwners()), lists)
        }
        lists.reserveCapacity(containerCount)
        var start = 0
        for slot in 0..<stageSlotCount {
            for usageIndex in 0..<resourceUsageCount {
                let bucket = slot * resourceUsageCount + usageIndex
                let resourceCount = Int(bucketCounts[bucket])
                if resourceCount == 0 {
                    continue
                }
                if let stage = Stage(rawValue: slot), usageIndex == 0 {
                    externalTextureIndices[stage].containerIndex = UInt(containers.count)
                }
                lists.append(containerCount == 1 ? allResources : Array(allResources[start..<(start + resourceCount)]))
                containers.append(
                    recordCount: resourceCount,
                    usage: MTLResourceUsage(rawValue: UInt(usageIndex + 1)),
                    renderStages: MTLRenderStages(rawValue: renderStagesRawValue(forSlot: slot))
                )
                start += resourceCount
            }
        }
        return (ResourceSet(containers: containers, records: takeRecords(), owners: takeOwners()), lists)
    }

    // Moved out: the group keeps them, and creation is done with them.
    @inline(__always)
    private mutating func takeRecords() -> [UsageRecord] {
        var builtRecords: [UsageRecord] = []
        swap(&builtRecords, &records)
        return builtRecords
    }

    @inline(__always)
    private mutating func takeOwners() -> OwnerList {
        var builtOwners = OwnerList()
        swap(&builtOwners, &owners)
        return builtOwners
    }

    /// Puts the records, owners and MTLResources in bucket order, each bucket in the order its resources were added.
    private mutating func orderByBucket(_ buckets: [UInt8]) {
        var orderedRecords: [UsageRecord] = []
        var orderedOwners = OwnerList()
        var orderedResources: [any MTLResource] = []
        orderedRecords.reserveCapacity(records.count)
        orderedResources.reserveCapacity(records.count)
        for bucket in 0..<(stageSlotCount * resourceUsageCount) where bucketCounts[bucket] != 0 {
            for index in buckets.indices where Int(buckets[index]) == bucket {
                let record = records[index]
                orderedRecords.append(
                    UsageRecord(
                        usage: record.usage,
                        binding: record.binding,
                        entryOffset: record.entryOffset,
                        entrySize: record.entrySize,
                        resource: Int32(orderedRecords.count),
                        impl: record.impl,
                        tracking: record.tracking
                    )
                )
                orderedOwners.append(owners[index])
                orderedResources.append(mtlResources[index])
            }
        }
        records = orderedRecords
        owners = orderedOwners
        mtlResources = orderedResources
    }

    /// Moves the group's state out of creation into the Impl.
    @inline(__always)
    mutating func makeImpl(
        device: consuming DeviceShell,
        layout: consuming ShellReference<WebGPU.Metal.BindGroupLayout>,
        resources: consuming ResourceSet,
        mtlResources: consuming ResourceLists,
        uniqueId: UInt32
    ) -> BindGroupImpl {
        var builtArgumentBuffers = PerStage<(any MTLBuffer)?>(repeating: nil)
        var builtSamplerBindings: [SamplerBinding] = []
        var builtDynamicBuffers: [DynamicBufferRecord] = []
        swap(&builtArgumentBuffers, &argumentBuffers)
        swap(&builtSamplerBindings, &samplerBindings)
        swap(&builtDynamicBuffers, &dynamicBuffers)
        return BindGroupImpl(
            device: device,
            deviceImpl: deviceImpl,
            layout: layout,
            layoutImpl: layoutImpl,
            argumentBuffers: builtArgumentBuffers,
            resources: resources,
            mtlResources: mtlResources,
            samplerBindings: builtSamplerBindings,
            dynamicBuffers: builtDynamicBuffers,
            externalTextureIndices: externalTextureIndices,
            uniqueId: uniqueId
        )
    }
}

/// The entry's argument index in `stage`, or nil.
///
/// For the slot of no stage (nil `stage`), an entry visible to no stage has index 0.
private func argumentBufferIndexForEntry(_ entry: LayoutEntry, _ stage: Stage?) -> UInt32? {
    guard let stage else {
        return entry.bindingAccess(for: nil) != nil ? 0 : nil
    }
    return entry.argumentBufferIndices[stage]
}

/// The MTLResourceUsage of an access, minus one.
private func resourceUsageIndex(_ access: MTLBindingAccess) -> Int {
    switch access {
    case .readOnly: 0
    case .writeOnly: 1
    case .readWrite: 2
    @unknown default: preconditionFailure("unknown MTLBindingAccess")
    }
}

private func entryUsage(_ type: LayoutBufferType) -> EntryUsage {
    switch type {
    case .uniform: .constant
    case .storage: .storage
    case .readOnlyStorage: .storageRead
    case .float3x2, .float4x3, .float3x3, .uint2, .arrayLength: []
    }
}

private func entryUsage(_ access: WebGPU.StorageTextureAccess) -> EntryUsage {
    switch access {
    case .ReadOnly: .storageTextureRead
    case .ReadWrite: .storageTextureReadWrite
    case .WriteOnly: .storageTextureWriteOnly
    @unknown default: preconditionFailure("unknown WebGPU::StorageTextureAccess")
    }
}

private func bufferUsageContains(_ usage: UInt16, _ bit: WebGPU.BufferUsage) -> Bool {
    usage & bit.rawValue != 0
}

private func hasProperUsageFlags(_ type: LayoutBufferType, _ usage: UInt16) -> Bool {
    switch type {
    case .uniform: bufferUsageContains(usage, .Uniform)
    case .storage, .readOnlyStorage: bufferUsageContains(usage, .Storage)
    case .float3x2, .float4x3, .float3x3, .uint2, .arrayLength: false
    }
}

/// The WGPUBufferUsage bits of `usage`, for error messages.
private func apiBufferUsage(_ usage: UInt16) -> UInt64 {
    let bits: [(WebGPU.BufferUsage, WGPUBufferUsage)] = [
        (.MapRead, WGPUBufferUsage_MapRead), (.MapWrite, WGPUBufferUsage_MapWrite), (.CopySource, WGPUBufferUsage_CopySrc),
        (.CopyDestination, WGPUBufferUsage_CopyDst), (.Index, WGPUBufferUsage_Index), (.Vertex, WGPUBufferUsage_Vertex),
        (.Uniform, WGPUBufferUsage_Uniform), (.Storage, WGPUBufferUsage_Storage), (.Indirect, WGPUBufferUsage_Indirect),
        (.QueryResolve, WGPUBufferUsage_QueryResolve),
    ]
    var result: UInt64 = 0
    for (bit, apiBit) in bits where bufferUsageContains(usage, bit) {
        result |= UInt64(apiBit)
    }
    return result
}

private func samplerTypeMatches(_ type: WebGPU.SamplerBindingType, _ sampler: SamplerImpl) -> Bool {
    switch type {
    case .Filtering: !sampler.isComparison()
    case .NonFiltering: !sampler.isComparison() && !sampler.isFiltering()
    case .Comparison: sampler.isComparison()
    @unknown default: preconditionFailure("unknown WebGPU::SamplerBindingType")
    }
}

private struct FormatTypes: OptionSet {
    let rawValue: UInt8

    static let float = FormatTypes(rawValue: 1 << 0)
    static let unfilterableFloat = FormatTypes(rawValue: 1 << 1)
    static let depth = FormatTypes(rawValue: 1 << 2)
    static let signedInt = FormatTypes(rawValue: 1 << 3)
    static let unsignedInt = FormatTypes(rawValue: 1 << 4)
}

private func formatTypes(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect, float32Filterable: Bool) -> FormatTypes {
    let filterableFloat: FormatTypes = [.float, .unfilterableFloat]
    let float32: FormatTypes = float32Filterable ? [.unfilterableFloat, .float] : .unfilterableFloat
    switch format {
    case .R8unorm, .R8snorm:
        return filterableFloat
    case .R8uint, .R16uint, .Rg8uint, .R32uint, .Rg16uint, .Rgba8uint, .Rgb10a2uint, .Rg32uint, .Rgba16uint, .Rgba32uint, .Stencil8:
        return .unsignedInt
    case .R8sint, .R16sint, .Rg8sint, .R32sint, .Rg16sint, .Rgba8sint, .Rg32sint, .Rgba16sint, .Rgba32sint:
        return .signedInt
    case .R16unorm, .R16snorm, .Rg16unorm, .Rg16snorm, .Rgba16unorm, .Rgba16snorm, .R16float, .Rg8unorm, .Rg8snorm:
        return filterableFloat
    case .R32float, .Rg32float, .Rgba32float:
        return float32
    case .Rg16float, .Rgba8unorm, .Rgba8unormSRGB, .Rgba8snorm, .Bgra8unorm, .Bgra8unormSRGB, .Rgb10a2unorm, .Rg11b10ufloat, .Rgb9e5ufloat,
        .Rgba16float:
        return filterableFloat
    case .Depth16unorm, .Depth24plus, .Depth32float:
        return [.depth, .unfilterableFloat]
    case .Depth24plusStencil8, .Depth32floatStencil8:
        switch aspect {
        case .All: return [.depth, .unfilterableFloat, .unsignedInt]
        case .StencilOnly: return .unsignedInt
        case .DepthOnly: return [.depth, .unfilterableFloat]
        // Any other aspect is treated as DepthOnly.
        @unknown default: return [.depth, .unfilterableFloat]
        }
    case .Bc1RgbaUnorm, .Bc1RgbaUnormSRGB, .Bc2RgbaUnorm, .Bc2RgbaUnormSRGB, .Bc3RgbaUnorm, .Bc3RgbaUnormSRGB, .Bc4RUnorm, .Bc4RSnorm,
        .Bc5RgUnorm, .Bc5RgSnorm, .Bc6hRgbUfloat, .Bc6hRgbFloat, .Bc7RgbaUnorm, .Bc7RgbaUnormSRGB, .Etc2Rgb8unorm, .Etc2Rgb8unormSRGB,
        .Etc2Rgb8a1unorm, .Etc2Rgb8a1unormSRGB, .Etc2Rgba8unorm, .Etc2Rgba8unormSRGB, .EacR11unorm, .EacR11snorm, .EacRg11unorm,
        .EacRg11snorm, .Astc4x4Unorm, .Astc4x4UnormSRGB, .Astc5x4Unorm, .Astc5x4UnormSRGB, .Astc5x5Unorm, .Astc5x5UnormSRGB, .Astc6x5Unorm,
        .Astc6x5UnormSRGB, .Astc6x6Unorm, .Astc6x6UnormSRGB, .Astc8x5Unorm, .Astc8x5UnormSRGB, .Astc8x6Unorm, .Astc8x6UnormSRGB,
        .Astc8x8Unorm, .Astc8x8UnormSRGB, .Astc10x5Unorm, .Astc10x5UnormSRGB, .Astc10x6Unorm, .Astc10x6UnormSRGB, .Astc10x8Unorm,
        .Astc10x8UnormSRGB, .Astc10x10Unorm, .Astc10x10UnormSRGB, .Astc12x10Unorm, .Astc12x10UnormSRGB, .Astc12x12Unorm,
        .Astc12x12UnormSRGB:
        return filterableFloat
    @unknown default:
        preconditionFailure("unknown WebGPU::TextureFormat")
    }
}

extension BindGroupCreation {
    func sampleTypeMatches(_ sampleType: WebGPU.TextureSampleType, _ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> Bool {
        let types = formatTypes(format, aspect, float32Filterable: float32Filterable)
        switch sampleType {
        case .Float: return types.contains(.float)
        case .UnfilterableFloat: return types.contains(.unfilterableFloat)
        case .Depth: return types.contains(.depth)
        case .Sint: return types.contains(.signedInt)
        case .Uint: return types.contains(.unsignedInt)
        @unknown default: preconditionFailure("unknown WebGPU::TextureSampleType")
        }
    }

    /// The names of the sample types the format allows, for error messages.
    func formatSampleTypeNames(_ format: WebGPU.TextureFormat, _ aspect: WebGPU.TextureAspect) -> String {
        let types = formatTypes(format, aspect, float32Filterable: float32Filterable)
        let names: [(FormatTypes, String)] = [
            (.float, "float"), (.unfilterableFloat, "unfilterable-float"), (.depth, "depth"), (.signedInt, "sint"), (.unsignedInt, "uint"),
        ]
        return names.filter { types.contains($0.0) }.map(\.1).joined(separator: " + ")
    }
}

private func sampleTypeName(_ sampleType: WebGPU.TextureSampleType) -> String {
    switch sampleType {
    case .Float: "float"
    case .UnfilterableFloat: "unfilterable-float"
    case .Depth: "depth"
    case .Sint: "sint"
    case .Uint: "uint"
    @unknown default: preconditionFailure("unknown WebGPU::TextureSampleType")
    }
}

/// True when there is no entry.
private func viewDimensionMatches(_ viewDimension: WebGPU.TextureViewDimension?, _ textureType: MTLTextureType) -> Bool {
    guard let viewDimension else {
        return true
    }
    switch viewDimension {
    case ._1d: return textureType == .type1D
    case ._2d: return textureType == .type2D || textureType == .type2DMultisample
    case ._2dArray: return textureType == .type2DArray || textureType == .type2DMultisampleArray
    case .Cube: return textureType == .typeCube
    case .CubeArray: return textureType == .typeCubeArray
    case ._3d: return textureType == .type3D
    @unknown default: preconditionFailure("unknown WebGPU::TextureViewDimension")
    }
}

private func isFloat32Format(_ texture: (any MTLTexture)?) -> Bool {
    guard let pixelFormat = texture?.pixelFormat else {
        return false
    }
    return pixelFormat == .r32Float || pixelFormat == .rg32Float || pixelFormat == .rgba32Float
}

private func isValidFloat32SampleType(_ sampleType: WebGPU.TextureSampleType) -> Bool {
    sampleType == .Float || sampleType == .UnfilterableFloat
}

private func isAllowedExternalTextureFormat(_ format: WebGPU.TextureFormat) -> Bool {
    format == .Rgba8unorm || format == .Bgra8unorm || format == .Rgba16float
}

/// A single-plane frame's stand-in for a chroma plane.
///
/// It holds the two channels the shader reads from a second plane, plus alpha where a real chroma plane leaves 1. Its
/// blue channel, which a real chroma plane samples as 0, says whether plane 0 is already premultiplied.
private func chromaPlaneFromRGB(_ texture: (any MTLTexture)?, alphaFirst: Bool, premultiplied: Bool) -> (any MTLTexture)? {
    guard let texture else {
        return nil
    }
    let premultipliedChannel: MTLTextureSwizzle = premultiplied ? .one : .zero
    let swizzle =
        alphaFirst
        ? MTLTextureSwizzleChannels(red: .blue, green: .alpha, blue: premultipliedChannel, alpha: .red)
        : MTLTextureSwizzleChannels(red: .green, green: .blue, blue: premultipliedChannel, alpha: .alpha)
    return texture.makeTextureView(
        pixelFormat: texture.pixelFormat,
        textureType: texture.textureType,
        levels: 0..<texture.mipmapLevelCount,
        slices: 0..<texture.arrayLength,
        swizzle: swizzle
    )
}

// MARK: - WTFHashMap replica check

/// Whether EncoderModel.swift's WTFHashMap and GroupIndexOrder iterate in WTF::HashTable order, which picks error
/// messages.
///
/// Checked once per process in builds with assertions, against the real HashSet (wtfHashSetOrderForOperations in
/// BindGroup.mm), over seeded random add/remove/clear sequences with keys below 32 (bind group indices, both replicas)
/// and below 4096 (WTFHashMap).
private let wtfHashReplicaMatchesWTF = wtfHashReplicaMatchesWTFHashSet()

private func wtfHashReplicaMatchesWTFHashSet() -> Bool {
    var state: UInt64 = 0x5EED_0F_C0FFEE
    func nextRandom() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    // The last 100 sequences remove rarely, so that nearly all 32 bind group indices are live and the table reaches 128.
    for sequence in 0..<300 {
        let keyLimit: UInt64 = sequence >= 200 || sequence.isMultiple(of: 2) ? 32 : 4096
        let removeThreshold: UInt64 = sequence >= 200 ? 10 : 35
        let operationCount = 1 + Int(nextRandom() % 400)
        var replica = WTFHashSet<UInt32>()
        var groupReplica = GroupIndexOrder()
        var operations: ContiguousArray<Int64> = []
        operations.reserveCapacity(operationCount)
        for _ in 0..<operationCount {
            let roll = nextRandom() % 100
            let key = nextRandom() % keyLimit
            if roll < 2 {
                operations.append(Int64.min)
                replica.removeAll()
                groupReplica.removeAll()
            } else if roll < removeThreshold {
                operations.append(-Int64(key) - 1)
                replica.remove(UInt32(key))
                if keyLimit == 32 {
                    groupReplica.remove(UInt32(key))
                }
            } else {
                operations.append(Int64(key))
                replica.add(UInt32(key))
                if keyLimit == 32 {
                    groupReplica.add(UInt32(key))
                }
            }
        }

        var expected = ContiguousArray<UInt32>(repeating: 0, count: replica.count)
        var destination = expected.mutableSpan
        let count = WebGPU.Metal.wtfHashSetOrderForOperations(operations.span, &destination)
        var actual: [UInt32] = []
        replica.forEachKeyInWTFOrder { actual.append($0) }
        if count != replica.count || !actual.elementsEqual(expected) {
            return false
        }
        if keyLimit == 32 && (groupReplica.count != replica.count || !groupReplica.elementsEqual(expected)) {
            return false
        }
    }
    return true
}
