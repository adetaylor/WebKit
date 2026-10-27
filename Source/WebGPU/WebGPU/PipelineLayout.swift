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
import WebGPU_Internal.BindGroupLayout
import WebGPU_Internal.Device
import WebGPU_Internal.PipelineLayout
import WebGPU_Private.WebGPUCpp

/// The Impls of a pipeline layout's bind group layouts, in group order.
///
/// Up to four (WebGPU's default maxBindGroups) are stored inline, so the usual layout makes no allocation for them and
/// releases only the Impls it has.
struct BindGroupLayoutImplList: RandomAccessCollection {
    private enum Storage {
        case none
        case one(BindGroupLayoutImpl)
        case two(BindGroupLayoutImpl, BindGroupLayoutImpl)
        case three(BindGroupLayoutImpl, BindGroupLayoutImpl, BindGroupLayoutImpl)
        case four(BindGroupLayoutImpl, BindGroupLayoutImpl, BindGroupLayoutImpl, BindGroupLayoutImpl)
        case spilled(ContiguousArray<BindGroupLayoutImpl>)
    }

    private var storage = Storage.none
    private(set) var count = 0

    init() {
    }

    init(_ impl: BindGroupLayoutImpl) {
        storage = .one(impl)
        count = 1
    }

    var startIndex: Int {
        0
    }

    var endIndex: Int {
        count
    }

    @inline(__always)
    mutating func append(_ impl: BindGroupLayoutImpl) {
        switch storage {
        case .none:
            storage = .one(impl)
        case .one(let first):
            storage = .two(first, impl)
        case .two(let first, let second):
            storage = .three(first, second, impl)
        case .three(let first, let second, let third):
            storage = .four(first, second, third, impl)
        case .four(let first, let second, let third, let fourth):
            storage = .spilled([first, second, third, fourth, impl])
        case .spilled(var impls):
            storage = .none
            impls.append(impl)
            storage = .spilled(impls)
        }
        count += 1
    }

    /// Traps past the end.
    subscript(index: Int) -> BindGroupLayoutImpl {
        switch (storage, index) {
        case (.one(let impl), 0), (.two(let impl, _), 0), (.three(let impl, _, _), 0), (.four(let impl, _, _, _), 0):
            return impl
        case (.two(_, let impl), 1), (.three(_, let impl, _), 1), (.four(_, let impl, _, _), 1):
            return impl
        case (.three(_, _, let impl), 2), (.four(_, _, let impl, _), 2):
            return impl
        case (.four(_, _, _, let impl), 3):
            return impl
        case (.spilled(let impls), _):
            return impls[index]
        default:
            preconditionFailure("bind group layout index out of range")
        }
    }
}

/// The shells of a pipeline layout's bind group layouts, in group order: what it owns and hands back to C++.
///
/// Up to four are stored inline. Every case has a payload (no Optional or empty case next to an FRT): none is an empty
/// `spilled`.
struct BindGroupLayoutShellList {
    private enum Storage {
        case one(WebGPU.Metal.BindGroupLayout)
        case two(WebGPU.Metal.BindGroupLayout, WebGPU.Metal.BindGroupLayout)
        case three(WebGPU.Metal.BindGroupLayout, WebGPU.Metal.BindGroupLayout, WebGPU.Metal.BindGroupLayout)
        case four(WebGPU.Metal.BindGroupLayout, WebGPU.Metal.BindGroupLayout, WebGPU.Metal.BindGroupLayout, WebGPU.Metal.BindGroupLayout)
        case spilled(ContiguousArray<WebGPU.Metal.BindGroupLayout>)
    }

    private var storage = Storage.spilled([])

    init() {
    }

    init(_ shell: WebGPU.Metal.BindGroupLayout) {
        storage = .one(shell)
    }

    @inline(__always)
    mutating func append(_ shell: WebGPU.Metal.BindGroupLayout) {
        switch storage {
        case .spilled(var shells):
            if shells.isEmpty {
                storage = .one(shell)
                return
            }
            storage = .spilled([])
            shells.append(shell)
            storage = .spilled(shells)
        case .one(let first):
            storage = .two(first, shell)
        case .two(let first, let second):
            storage = .three(first, second, shell)
        case .three(let first, let second, let third):
            storage = .four(first, second, third, shell)
        case .four(let first, let second, let third, let fourth):
            storage = .spilled([first, second, third, fourth, shell])
        }
    }

    /// Traps past the end.
    subscript(index: Int) -> WebGPU.Metal.BindGroupLayout {
        switch (storage, index) {
        case (.one(let shell), 0), (.two(let shell, _), 0), (.three(let shell, _, _), 0), (.four(let shell, _, _, _), 0):
            return shell
        case (.two(_, let shell), 1), (.three(_, let shell, _), 1), (.four(_, let shell, _, _), 1):
            return shell
        case (.three(_, _, let shell), 2), (.four(_, _, let shell, _), 2):
            return shell
        case (.four(_, _, _, let shell), 3):
            return shell
        case (.spilled(let shells), _):
            return shells[index]
        default:
            preconditionFailure("bind group layout index out of range")
        }
    }
}

// One per GPUPipelineLayout, owned by the C++ shell WebGPU::Metal::PipelineLayout. Owns the
// bind group layouts (shells, for ownership and for handing back to C++, and their Impls, for reading), the
// per-stage dynamic-offset plans built from them, and creates layouts (Device::createPipelineLayout and the layouts
// pipelines generate), and holds the Device. Used only on its Instance's API thread, so not Sendable.
//
// No bind group layouts is the auto-layout case: the descriptor had no or an empty list of layouts.
@_expose(Cxx)
final class PipelineLayoutImpl {
    /// Empty once makeInvalid() dropped them.
    private var shells: BindGroupLayoutShellList
    private let autogenerated: Bool
    private var valid: Bool
    private let backingUniqueId: UInt64

    /// The Impls of `shells`, same count.
    ///
    /// The Impls stay held after makeInvalid() (they own no shells, so nothing observable lives longer) so that the
    /// encoders' per-draw reads are of a `let`.
    private let allBindGroupLayoutImpls: BindGroupLayoutImplList
    var bindGroupLayoutImpls: BindGroupLayoutImplList {
        valid ? allBindGroupLayoutImpls : BindGroupLayoutImplList()
    }
    /// The dynamic-offset plans, indexed by Stage raw value; nil when no stage has dynamic offsets.
    ///
    /// makeInvalid() leaves them, so `groups.count` is the number of bind group layouts at creation.
    private let dynamicOffsetPlans: ContiguousArray<DynamicOffsetPlan>?
    var dynamicOffsets: PerStage<DynamicOffsetPlan> {
        PerStage(vertex: dynamicOffsetPlan(.vertex), fragment: dynamicOffsetPlan(.fragment), compute: dynamicOffsetPlan(.compute))
    }

    func dynamicOffsetPlan(_ stage: Stage) -> DynamicOffsetPlan {
        dynamicOffsetPlans?[stage.rawValue] ?? DynamicOffsetPlan()
    }

    /// dynamicOffsetPlan(stage).total.
    func dynamicOffsetTotal(_ stage: Stage) -> UInt64 {
        dynamicOffsetPlans?[stage.rawValue].total ?? 0
    }

    // Declared last, so that the device outlives the rest of the layout. No DeviceImpl: creation is handed one, and the
    // only later reader, pipeline creation, compares devices.
    let device: WebGPU.Metal.Device

    init(
        device: consuming DeviceShell,
        bindGroupLayouts: consuming BindGroupLayoutShellList,
        bindGroupLayoutImpls: consuming BindGroupLayoutImplList,
        dynamicOffsetPlans: consuming ContiguousArray<DynamicOffsetPlan>?,
        autogenerated: Bool,
        uniqueId: UInt64
    ) {
        self.dynamicOffsetPlans = dynamicOffsetPlans
        shells = consume bindGroupLayouts
        allBindGroupLayoutImpls = consume bindGroupLayoutImpls
        self.autogenerated = autogenerated
        backingUniqueId = uniqueId
        valid = true
        self.device = device.shell
        if autogenerated {
            for index in 0..<allBindGroupLayoutImpls.count {
                allBindGroupLayoutImpls[index].autogeneratedPipelineLayout = self
            }
        }
    }

    static func invalid(_ device: consuming DeviceShell) -> PipelineLayoutImpl {
        let impl = PipelineLayoutImpl(
            device: device,
            bindGroupLayouts: BindGroupLayoutShellList(),
            bindGroupLayoutImpls: BindGroupLayoutImplList(),
            dynamicOffsetPlans: nil,
            autogenerated: false,
            uniqueId: 0
        )
        impl.makeInvalid()
        return impl
    }

    /// Copies the group's dynamic offsets for `stage` into `destination`, at the group's start.
    ///
    /// Traps when a contiguous run of offsets does not fit; returns false when other offsets do not.
    @_expose(!Cxx)
    @_lifetime(destination: copy destination)
    func updateOffsets(_ stage: Stage, group: UInt32, dynamicOffsets offsets: [UInt32], destination: inout MutableSpan<UInt32>) -> Bool {
        let groupIndex = Int(group)
        let plan = dynamicOffsetPlan(stage)
        guard groupIndex < plan.groups.count, let start = plan.groups[groupIndex].start else {
            return true
        }
        let base = Int(start)
        precondition(base <= destination.count)
        let available = destination.count - base

        let layoutCount = numberOfBindGroupLayouts()
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

    /// nil past the end.
    @_expose(!Cxx)
    func bindGroupLayout(at group: Int) -> BindGroupLayoutImpl? {
        valid && group >= 0 && group < allBindGroupLayoutImpls.count ? allBindGroupLayoutImpls[group] : nil
    }

    func isAutoLayout() -> Bool {
        autogenerated
    }

    func uniqueId() -> UInt64 {
        backingUniqueId
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        valid
    }

    @_expose(!Cxx)
    func numberOfBindGroupLayouts() -> Int {
        valid ? allBindGroupLayoutImpls.count : 0
    }

    // The caller bounds-checks against numberOfBindGroupLayouts() first, so Swift never returns an Optional FRT.
    @_expose(!Cxx)
    func bindGroupLayout(_ i: Int) -> WebGPU.Metal.BindGroupLayout {
        shells[i]
    }

    @_expose(Cxx)
    func makeInvalid() {
        valid = false
        var dropped = BindGroupLayoutShellList()
        swap(&dropped, &shells)
    }
}

/// The dynamic-offset plans of every stage, by Stage raw value; nil when no stage has dynamic offsets.
///
/// Without dynamic offsets in a stage no group would have a start, which every reader treats as it treats a group past
/// the end, so no groups are made.
private func makeDynamicOffsetPlans(_ layouts: borrowing BindGroupLayoutImplList) -> ContiguousArray<DynamicOffsetPlan>? {
    var stagesWithDynamicOffsets = PerStage(repeating: false)
    for index in 0..<layouts.count {
        let sizes = layouts[index].counts.sizeOfDynamicOffsets
        stagesWithDynamicOffsets.vertex = stagesWithDynamicOffsets.vertex || sizes.vertex != 0
        stagesWithDynamicOffsets.fragment = stagesWithDynamicOffsets.fragment || sizes.fragment != 0
        stagesWithDynamicOffsets.compute = stagesWithDynamicOffsets.compute || sizes.compute != 0
    }
    if !stagesWithDynamicOffsets.vertex && !stagesWithDynamicOffsets.fragment && !stagesWithDynamicOffsets.compute {
        return nil
    }
    return [
        stagesWithDynamicOffsets.vertex ? makeDynamicOffsetPlan(layouts, stage: .vertex) : DynamicOffsetPlan(),
        stagesWithDynamicOffsets.fragment ? makeDynamicOffsetPlan(layouts, stage: .fragment) : DynamicOffsetPlan(),
        stagesWithDynamicOffsets.compute ? makeDynamicOffsetPlan(layouts, stage: .compute) : DynamicOffsetPlan(),
    ]
}

/// The dynamic-offset plan of a stage with dynamic offsets.
private func makeDynamicOffsetPlan(_ layouts: borrowing BindGroupLayoutImplList, stage: Stage) -> DynamicOffsetPlan {
    var plan = DynamicOffsetPlan()
    plan.groups.reserveCapacity(layouts.count)
    var offset: UInt32 = 0
    for index in 0..<layouts.count {
        let layout = layouts[index]
        let initialOffset = offset
        offset &+= layout.counts.sizeOfDynamicOffsets[stage]
        var group = DynamicOffsetGroup(start: nil, count: 0, linearRange: nil, sourceIndices: [])
        if initialOffset != offset {
            let difference = offset &- initialOffset
            group.count = UInt64(difference / UInt32(MemoryLayout<UInt32>.size))
            if difference != 0 {
                group.start = initialOffset / UInt32(MemoryLayout<UInt32>.size)
            }
        }

        var hasLinearLayout = true
        var priorDynamicOffsetsIndex: UInt32?
        var firstDynamicOffsetsIndex: UInt32?
        for entry in layout.entries where entry.hasDynamicOffsetInAnyStage && entry.visibility.contains(stage.bit) {
            let dynamicOffsetsIndex = entry.dynamicOffsetsIndex
            if let priorDynamicOffsetsIndex, dynamicOffsetsIndex != priorDynamicOffsetsIndex &+ 1 {
                hasLinearLayout = false
            }
            priorDynamicOffsetsIndex = dynamicOffsetsIndex
            if firstDynamicOffsetsIndex == nil {
                firstDynamicOffsetsIndex = dynamicOffsetsIndex
            }
            group.sourceIndices.append(dynamicOffsetsIndex)
        }
        if hasLinearLayout, let firstDynamicOffsetsIndex, let priorDynamicOffsetsIndex {
            group.linearRange = LinearRange(
                first: firstDynamicOffsetsIndex,
                count: priorDynamicOffsetsIndex &- firstDynamicOffsetsIndex &+ 1
            )
        }

        plan.total &+= group.count
        plan.groups.append(group)
    }
    return plan
}

// MARK: - Creation

/// Collects the descriptor's bind group layouts, which C++ resolves with metal() and swiftImpl(), then creates the layout.
///
/// One per device, reused, and empty between creations: finish() takes the layouts out before anything can re-enter.
final class PipelineLayoutBuilder {
    private struct Pending {
        var shells = BindGroupLayoutShellList()
        var impls = BindGroupLayoutImplList()
    }

    private var pending = Pending()

    init() {
    }

    fileprivate func append(_ bindGroupLayout: WebGPU.Metal.BindGroupLayout, _ impl: BindGroupLayoutImpl) {
        pending.shells.append(bindGroupLayout)
        pending.impls.append(impl)
    }

    fileprivate func finish(_ device: consuming DeviceShell, _ deviceImpl: DeviceImpl, _ isAutogenerated: Bool) -> PipelineLayoutImpl {
        var shells = BindGroupLayoutShellList()
        var impls = BindGroupLayoutImplList()
        swap(&shells, &pending.shells)
        swap(&impls, &pending.impls)
        return createPipelineLayoutImpl(
            device: device,
            deviceImpl: deviceImpl,
            bindGroupLayouts: consume shells,
            bindGroupLayoutImpls: consume impls,
            isAutogenerated: isAutogenerated
        )
    }
}

/// Device::createPipelineLayout with two or more bind group layouts: append each of the descriptor's layouts, then
/// finish.
@_expose(Cxx)
func appendPipelineLayoutBindGroupLayout(
    _ deviceImpl: DeviceImpl,
    _ bindGroupLayout: WebGPU.Metal.BindGroupLayout,
    _ impl: BindGroupLayoutImpl
) {
    deviceImpl.pipelineLayoutBuilder.append(bindGroupLayout, impl)
}

/// Reports errors unless `isAutogenerated`.
@_expose(Cxx)
func finishPipelineLayout(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, _ isAutogenerated: Bool) -> PipelineLayoutImpl {
    deviceImpl.pipelineLayoutBuilder.finish(DeviceShell(shell: device), deviceImpl, isAutogenerated)
}

/// Device::createPipelineLayout with no bind group layouts (the std::nullopt or empty case): no builder.
@_expose(Cxx)
func makePipelineLayoutImplWithoutBindGroupLayouts(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ isAutogenerated: Bool
) -> PipelineLayoutImpl {
    createPipelineLayoutImpl(
        device: DeviceShell(shell: device),
        deviceImpl: deviceImpl,
        bindGroupLayouts: BindGroupLayoutShellList(),
        bindGroupLayoutImpls: BindGroupLayoutImplList(),
        isAutogenerated: isAutogenerated
    )
}

/// Device::createPipelineLayout with one bind group layout: no builder.
@_expose(Cxx)
func makePipelineLayoutImplWithOneBindGroupLayout(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ bindGroupLayout: WebGPU.Metal.BindGroupLayout,
    _ impl: BindGroupLayoutImpl,
    _ isAutogenerated: Bool
) -> PipelineLayoutImpl {
    createPipelineLayoutImpl(
        device: DeviceShell(shell: device),
        deviceImpl: deviceImpl,
        bindGroupLayouts: BindGroupLayoutShellList(bindGroupLayout),
        bindGroupLayoutImpls: BindGroupLayoutImplList(impl),
        isAutogenerated: isAutogenerated
    )
}

@_expose(Cxx)
func makeInvalidPipelineLayoutImpl(_ device: WebGPU.Metal.Device) -> PipelineLayoutImpl {
    .invalid(DeviceShell(shell: device))
}

/// Takes the device reference and the lists, which the layout keeps.
private func createPipelineLayoutImpl(
    device: consuming DeviceShell,
    deviceImpl: DeviceImpl,
    bindGroupLayouts: consuming BindGroupLayoutShellList,
    bindGroupLayoutImpls: consuming BindGroupLayoutImplList,
    isAutogenerated: Bool
) -> PipelineLayoutImpl {
    guard deviceImpl.isValid() else {
        return .invalid(device)
    }

    let validation = validateBindGroupLayouts(bindGroupLayoutImpls, deviceImpl)
    if let message = validation.error {
        if !isAutogenerated {
            deviceImpl.generateAValidationError(message)
        }
        return .invalid(device)
    }

    if deviceImpl.pipelineLayoutIdsExhausted() {
        deviceImpl.loseTheDevice(WebGPU.DeviceLostReason.Unknown)
        return .invalid(device)
    }
    let dynamicOffsetPlans = validation.hasDynamicOffsets ? makeDynamicOffsetPlans(bindGroupLayoutImpls) : nil
    return PipelineLayoutImpl(
        device: device,
        bindGroupLayouts: bindGroupLayouts,
        bindGroupLayoutImpls: bindGroupLayoutImpls,
        dynamicOffsetPlans: dynamicOffsetPlans,
        autogenerated: isAutogenerated,
        uniqueId: deviceImpl.takePipelineLayoutId()
    )
}

/// One stage's running resource counts in Device::createPipelineLayout.
private struct StageResourceCounts {
    var uniformBuffers: UInt32 = 0
    var storageBuffers: UInt32 = 0
    var samplers: UInt32 = 0
    var textures: UInt32 = 0
    var storageTextures: UInt32 = 0

    mutating func add(_ counts: LayoutCounts, _ stage: Stage) {
        uniformBuffers &+= counts.uniformBuffers[stage]
        storageBuffers &+= counts.storageBuffers[stage]
        samplers &+= counts.samplers[stage]
        textures &+= counts.textures[stage]
        storageTextures &+= counts.storageTextures[stage]
    }

    @inline(__always)
    func errorExceeding(_ limits: WebGPU.Limits, _ stage: Stage) -> String? {
        let maxStorageBuffers = stage.layoutStorageBufferLimit(limits)
        let maxStorageTextures = stage.layoutStorageTextureLimit(limits)
        if uniformBuffers > limits.maxUniformBuffersPerShaderStage || storageBuffers > maxStorageBuffers
            || samplers > limits.maxSamplersPerShaderStage
            || textures > limits.maxSampledTexturesPerShaderStage || storageTextures > maxStorageTextures
        {
            return message(limits, maxStorageBuffers: maxStorageBuffers, maxStorageTextures: maxStorageTextures)
        }
        return nil
    }

    @inline(never)
    private func message(_ limits: WebGPU.Limits, maxStorageBuffers: UInt32, maxStorageTextures: UInt32) -> String {
        "Resource usage limits exceeded: uniformBufferCount(\(uniformBuffers)) > deviceLimits.maxUniformBuffersPerShaderStage(\(limits.maxUniformBuffersPerShaderStage)) || storageBufferCount(\(storageBuffers)) > maxStorageBuffers(\(maxStorageBuffers)) || samplerCount(\(samplers)) > deviceLimits.maxSamplersPerShaderStage(\(limits.maxSamplersPerShaderStage)) || textureCount(\(textures)) > deviceLimits.maxSampledTexturesPerShaderStage(\(limits.maxSampledTexturesPerShaderStage)) || storageTextureCount(\(storageTextures)) > maxStorageTextures(\(maxStorageTextures))"
    }
}

/// What validateBindGroupLayouts found: the first failure, or whether any layout has dynamic offsets in any stage.
private struct BindGroupLayoutsValidation {
    var error: String?
    var hasDynamicOffsets = false
}

/// The bind group layout checks of Device::createPipelineLayout, in one walk.
///
/// The first failure is reported in this order: the bind group count; each layout's device, validity and vertex limits,
/// as the walk reaches it; then the fragment limits; then the compute limits; then the dynamic buffer limits.
private func validateBindGroupLayouts(_ layouts: borrowing BindGroupLayoutImplList, _ deviceImpl: DeviceImpl) -> BindGroupLayoutsValidation
{
    if layouts.isEmpty {
        return BindGroupLayoutsValidation()
    }
    var hasDynamicOffsets = false
    if let error = errorValidatingBindGroupLayouts(layouts, deviceImpl, &hasDynamicOffsets) {
        return BindGroupLayoutsValidation(error: error)
    }
    return BindGroupLayoutsValidation(hasDynamicOffsets: hasDynamicOffsets)
}

/// Sets `hasDynamicOffsets` once every layout passed.
@inline(__always)
private func errorValidatingBindGroupLayouts(
    _ layouts: borrowing BindGroupLayoutImplList,
    _ deviceImpl: DeviceImpl,
    _ hasDynamicOffsets: inout Bool
) -> String? {
    let limits = deviceImpl.capabilities.limits
    if layouts.count > Int(limits.maxBindGroups) {
        return "Too many bind groups(\(layouts.count)), limit(\(limits.maxBindGroups))"
    }

    var vertex = StageResourceCounts()
    var fragment = StageResourceCounts()
    var compute = StageResourceCounts()
    var fragmentError: String?
    var computeError: String?
    var dynamicUniformBuffers: UInt32 = 0
    var dynamicStorageBuffers: UInt32 = 0
    for index in 0..<layouts.count {
        let layout = layouts[index]
        if layout.deviceImpl !== deviceImpl {
            return "Device mismatch"
        }
        if !layout.isValid() {
            return "Bind group layout is invalid"
        }
        let counts = layout.counts
        let sizes = counts.sizeOfDynamicOffsets
        hasDynamicOffsets = hasDynamicOffsets || sizes.vertex != 0 || sizes.fragment != 0 || sizes.compute != 0
        vertex.add(counts, .vertex)
        if let error = vertex.errorExceeding(limits, .vertex) {
            return error
        }
        if fragmentError == nil {
            fragment.add(counts, .fragment)
            fragmentError = fragment.errorExceeding(limits, .fragment)
        }
        if computeError == nil {
            compute.add(counts, .compute)
            computeError = compute.errorExceeding(limits, .compute)
        }
        dynamicUniformBuffers &+= counts.dynamicUniformBuffers
        dynamicStorageBuffers &+= counts.dynamicStorageBuffers
    }
    if let error = fragmentError ?? computeError {
        return error
    }
    if dynamicUniformBuffers > limits.maxDynamicUniformBuffersPerPipelineLayout {
        return
            "Too many dynamic uniform buffers: used(\(dynamicUniformBuffers)), limit(\(limits.maxDynamicUniformBuffersPerPipelineLayout))"
    }
    if dynamicStorageBuffers > limits.maxDynamicStorageBuffersPerPipelineLayout {
        return
            "Too many dynamic storage buffers: used(\(dynamicStorageBuffers)), limit(\(limits.maxDynamicStorageBuffersPerPipelineLayout))"
    }
    return nil
}

/// A pipeline layout shell with its Impl (pair invariant).
struct LayoutPair {
    let shell: WebGPU.Metal.PipelineLayout
    let impl: PipelineLayoutImpl
}

/// Wraps an Impl made in Swift in a new shell, through DeviceImpl.stagedPipelineLayoutImpl.
private func makeLayoutPair(_ impl: PipelineLayoutImpl, device: WebGPU.Metal.Device, deviceImpl: DeviceImpl) -> LayoutPair {
    precondition(deviceImpl.stagedPipelineLayoutImpl == nil)
    deviceImpl.stagedPipelineLayoutImpl = impl
    return LayoutPair(shell: WebGPU.Metal.PipelineLayout.createWithStagedImpl(device).ptr(), impl: impl)
}

/// One generated BindGroupLayout per group, then a generated PipelineLayout.
///
/// An invalid layout comes back as an invalid pair.
func makeGeneratedPipelineLayout(device: WebGPU.Metal.Device, deviceImpl: DeviceImpl, entries: [[ResolvedLayoutEntry]]) -> LayoutPair {
    var bindGroupLayouts = BindGroupLayoutShellList()
    var bindGroupLayoutImpls = BindGroupLayoutImplList()
    for groupEntries in entries {
        let impl = makeBindGroupLayoutImpl(
            device: device,
            deviceImpl: deviceImpl,
            label: wtfString("getBindGroup() generated layout"),
            entries: groupEntries,
            isAutoGenerated: true
        )
        guard impl.isValid() else {
            return makeLayoutPair(.invalid(DeviceShell(shell: device)), device: device, deviceImpl: deviceImpl)
        }
        bindGroupLayouts.append(makeBindGroupLayoutShell(impl, device: device, deviceImpl: deviceImpl))
        bindGroupLayoutImpls.append(impl)
    }

    let impl = createPipelineLayoutImpl(
        device: DeviceShell(shell: device),
        deviceImpl: deviceImpl,
        bindGroupLayouts: consume bindGroupLayouts,
        bindGroupLayoutImpls: consume bindGroupLayoutImpls,
        isAutogenerated: true
    )
    return makeLayoutPair(impl, device: device, deviceImpl: deviceImpl)
}
