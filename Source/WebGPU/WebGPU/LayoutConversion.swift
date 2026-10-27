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

// Bind group layouts between WebGPU's model (PipelineModel.swift) and the WGSL compiler's PipelineLayout, both ways.
// WGSL module types are used unqualified (WGSLBridge.swift explains why).

internal import WGSL
import WebGPU_Private.WebGPUCpp

// RenderBundleEncoder::startIndexForFragmentDynamicOffsets.
private let startIndexForFragmentDynamicOffsets: UInt64 = 3

// MARK: - Explicit layouts

// The explicit layout handed to the compiler. Entries go in ascending binding order; the order is not observable, as the
// compiler sorts each group's argument buffer members by index and the dynamic offset slots depend on per-group maxima.
func makeExplicitWGSLLayout(_ layout: PipelineLayoutImpl) -> PipelineLayout {
    var bindGroupLayouts: [BindGroupLayout] = []
    bindGroupLayouts.reserveCapacity(layout.bindGroupLayoutImpls.count)
    var maxOffsets = PerStage<UInt32>(repeating: 0)
    for (group, bindGroupLayout) in layout.bindGroupLayoutImpls.enumerated() {
        let groupOffsets = maxOffsets
        var entries: [BindGroupLayoutEntry] = []
        entries.reserveCapacity(bindGroupLayout.entries.count)
        for entry in bindGroupLayout.entries {
            var slots = PerStage(repeating: StageSlots())
            for stage in Stage.allCases {
                slots[stage].argumentBufferIndex = entry.argumentBufferIndices[stage]
                slots[stage].argumentBufferSizeIndex = entry.bufferSizeArgumentBufferIndices[stage]
                guard let dynamicOffset = entry.dynamicOffsets[stage] else {
                    continue
                }
                precondition(dynamicOffset % 4 == 0, "a dynamic offset is not a multiple of 4")
                // The sum wraps at 32 bits; the slot and the maximum are computed in 64 bits, then truncated.
                var slot = UInt64((groupOffsets[stage] &+ dynamicOffset) / 4)
                if stage == .fragment {
                    slot &+= startIndexForFragmentDynamicOffsets
                }
                slots[stage].bufferDynamicOffset = UInt32(truncatingIfNeeded: slot)
                let end = UInt64(dynamicOffset) &+ 4 &+ UInt64(groupOffsets[stage])
                maxOffsets[stage] = UInt32(truncatingIfNeeded: max(UInt64(maxOffsets[stage]), end))
            }
            entries.append(
                BindGroupLayoutEntry(
                    binding: entry.binding,
                    webBinding: entry.binding,
                    visibility: ShaderStages(rawValue: entry.visibility.rawValue),
                    bindingMember: wgslBindingMember(entry.layout),
                    name: "",
                    vertex: slots.vertex,
                    fragment: slots.fragment,
                    compute: slots.compute
                )
            )
        }
        bindGroupLayouts.append(BindGroupLayout(group: UInt32(truncatingIfNeeded: group), entries: entries))
    }
    return PipelineLayout(bindGroupLayouts: bindGroupLayouts)
}

private func wgslBindingMember(_ layout: LayoutBinding) -> BindingMember {
    switch layout {
    case .buffer(let buffer):
        .buffer(
            BufferBindingLayout(
                type: wgslBufferType(buffer.type),
                hasDynamicOffset: buffer.hasDynamicOffset,
                minBindingSize: buffer.minBindingSize
            )
        )
    case .sampler(let sampler):
        .sampler(wgslSamplerType(sampler.type))
    case .texture(let texture):
        .texture(
            TextureBindingLayout(
                sampleType: wgslSampleType(texture.sampleType),
                viewDimension: wgslViewDimension(texture.viewDimension),
                multisampled: texture.multisampled
            )
        )
    case .storageTexture(let storageTexture):
        .storageTexture(
            StorageTextureBindingLayout(
                access: wgslAccess(storageTexture.access),
                format: wgslTexelFormat(storageTexture.format),
                viewDimension: wgslViewDimension(storageTexture.viewDimension)
            )
        )
    case .externalTexture:
        .externalTexture
    }
}

private func wgslBufferType(_ type: LayoutBufferType) -> BufferBindingType {
    switch type {
    case .uniform:
        return .uniform
    case .storage:
        return .storage
    case .readOnlyStorage:
        return .readOnlyStorage
    case .float3x2, .float4x3, .float3x3, .uint2, .arrayLength:
        assertionFailure("Unexpected buffer bindingType")
        return .uniform
    }
}

private func wgslSamplerType(_ type: WebGPU.SamplerBindingType) -> SamplerBindingType {
    switch type {
    case .Filtering: .filtering
    case .Comparison: .comparison
    case .NonFiltering: .nonFiltering
    @unknown default: preconditionFailure("unknown WebGPU::SamplerBindingType")
    }
}

private func wgslSampleType(_ sampleType: WebGPU.TextureSampleType) -> TextureSampleType {
    switch sampleType {
    case .Sint: .signedInt
    case .Uint: .unsignedInt
    case .Depth: .depth
    case .Float: .float
    case .UnfilterableFloat: .unfilterableFloat
    @unknown default: preconditionFailure("unknown WebGPU::TextureSampleType")
    }
}

private func wgslViewDimension(_ viewDimension: WebGPU.TextureViewDimension) -> TextureViewDimension {
    switch viewDimension {
    case .Cube: .cube
    case ._1d: .oneDimensional
    case ._2d: .twoDimensional
    case ._3d: .threeDimensional
    case .CubeArray: .cubeArray
    case ._2dArray: .twoDimensionalArray
    @unknown default: preconditionFailure("unknown WebGPU::TextureViewDimension")
    }
}

private func wgslAccess(_ access: WebGPU.StorageTextureAccess) -> StorageTextureAccess {
    switch access {
    case .WriteOnly: .writeOnly
    case .ReadOnly: .readOnly
    case .ReadWrite: .readWrite
    @unknown default: preconditionFailure("unknown WebGPU::StorageTextureAccess")
    }
}

private func wgslTexelFormat(_ format: WebGPU.TextureFormat) -> TexelFormat {
    switch format {
    case .Bgra8unorm: return .bgra8unorm
    case .R16float: return .r16float
    case .R16sint: return .r16sint
    case .R16snorm: return .r16snorm
    case .R16uint: return .r16uint
    case .R16unorm: return .r16unorm
    case .R32float: return .r32float
    case .R32sint: return .r32sint
    case .R32uint: return .r32uint
    case .R8sint: return .r8sint
    case .R8snorm: return .r8snorm
    case .R8uint: return .r8uint
    case .R8unorm: return .r8unorm
    case .Rg11b10ufloat: return .rg11b10ufloat
    case .Rg16float: return .rg16float
    case .Rg16sint: return .rg16sint
    case .Rg16snorm: return .rg16snorm
    case .Rg16uint: return .rg16uint
    case .Rg16unorm: return .rg16unorm
    case .Rg32float: return .rg32float
    case .Rg32sint: return .rg32sint
    case .Rg32uint: return .rg32uint
    case .Rg8sint: return .rg8sint
    case .Rg8snorm: return .rg8snorm
    case .Rg8uint: return .rg8uint
    case .Rg8unorm: return .rg8unorm
    case .Rgb10a2uint: return .rgb10a2uint
    case .Rgb10a2unorm: return .rgb10a2unorm
    case .Rgba16float: return .rgba16float
    case .Rgba16sint: return .rgba16sint
    case .Rgba16snorm: return .rgba16snorm
    case .Rgba16uint: return .rgba16uint
    case .Rgba16unorm: return .rgba16unorm
    case .Rgba32float: return .rgba32float
    case .Rgba32sint: return .rgba32sint
    case .Rgba32uint: return .rgba32uint
    case .Rgba8sint: return .rgba8sint
    case .Rgba8snorm: return .rgba8snorm
    case .Rgba8uint: return .rgba8uint
    case .Rgba8unorm: return .rgba8unorm
    default:
        assertionFailure("not a storage texture format")
        return .bgra8unorm
    }
}

// MARK: - Default layouts

private let arrayLengthSuffix = Array("_ArrayLength".utf16)

// Merges the default layout the compiler computed for one stage into `pipelineEntries`.
// Returns the error message, or nil.
func appendDefaultLayout(
    _ pipelineEntries: inout [[ResolvedLayoutEntry]],
    from defaultLayout: PipelineLayout?,
    limits: WebGPU.Limits
) -> String? {
    guard let defaultLayout, !defaultLayout.bindGroupLayouts.isEmpty else {
        return nil
    }

    var maxGroupIndex: UInt32 = 0
    for bindGroupLayout in defaultLayout.bindGroupLayouts {
        maxGroupIndex = max(maxGroupIndex, bindGroupLayout.group)
    }
    let bindGroupLayoutCount = UInt64(maxGroupIndex) + 1
    if bindGroupLayoutCount > UInt64(limits.maxBindGroups) {
        return "too many bind groups, limit \(limits.maxBindGroups), attempted \(bindGroupLayoutCount)"
    }
    while pipelineEntries.count < Int(bindGroupLayoutCount) {
        pipelineEntries.append([])
    }

    // Wrapping the bump would let the array-length entry alias a user binding and defeat the bounds check.
    func bumpForArrayLength(_ webBinding: UInt32) -> UInt32? {
        let (bumped, overflow) = webBinding.addingReportingOverflow(limits.maxBindingsPerBindGroup)
        return overflow ? nil : bumped
    }

    for bindGroupLayout in defaultLayout.bindGroupLayouts {
        let group = Int(bindGroupLayout.group)
        // HashMap<String, uint64_t>, keyed by UTF-16 code units as WTF::String compares; lookups only.
        var entryMap: [[UInt16]: UInt64] = [:]
        for entry in bindGroupLayout.entries {
            let visibility = stageMask(entry.visibility)
            // The entries of a shader have the visibility of its stage.
            let stage = singleStage(visibility)
            // FIXME: https://bugs.webkit.org/show_bug.cgi?id=265204 - use a set instead
            var isArrayLength = false
            var webBinding = entry.webBinding
            let entryName = Array(entry.name.utf16)
            if !entryName.isEmpty, hasArrayLengthSuffix(entryName) {
                guard let bumped = bumpForArrayLength(webBinding) else {
                    return "Binding index overflow in auto-generated layouts"
                }
                webBinding = bumped
                isArrayLength = true
            }

            if let existing = pipelineEntries[group].firstIndex(where: { $0.binding == webBinding }) {
                pipelineEntries[group][existing].visibility.formUnion(visibility)
                guard let stage else {
                    preconditionFailure("a default layout entry is visible in no single stage")
                }
                pipelineEntries[group][existing].metalBinding[stage] = entry.binding
                if !pipelineEntries[group][existing].layout.layoutEquals(makeLayoutBinding(entry.bindingMember)) {
                    return "Binding mismatch in auto-generated layouts"
                }
                entryMap[entryName] = UInt64(webBinding)
                continue
            }

            var bufferSizeForBinding: UInt64 = 0
            var bufferTypeOverride: LayoutBufferType?
            if !entryName.isEmpty {
                if isArrayLength {
                    guard let bumped = bumpForArrayLength(webBinding) else {
                        return "Binding index overflow in auto-generated layouts"
                    }
                    webBinding = bumped
                    bufferTypeOverride = .arrayLength
                    if let size = entryMap[arrayLengthShortName(entryName)] {
                        bufferSizeForBinding = size
                    }
                } else {
                    entryMap[entryName] = UInt64(webBinding)
                }
            }

            guard let stage else {
                preconditionFailure("a default layout entry is visible in no single stage")
            }
            var metalBinding = PerStage<UInt32>(repeating: 0)
            metalBinding[stage] = entry.binding
            pipelineEntries[group]
                .append(
                    ResolvedLayoutEntry(
                        binding: webBinding,
                        metalBinding: metalBinding,
                        visibility: visibility,
                        layout: makeLayoutBinding(
                            entry.bindingMember,
                            bufferTypeOverride: bufferTypeOverride,
                            bufferSizeForBinding: bufferSizeForBinding
                        )
                    )
                )
        }
    }

    return nil
}

private func hasArrayLengthSuffix(_ name: [UInt16]) -> Bool {
    name.count >= arrayLengthSuffix.count && name.suffix(arrayLengthSuffix.count).elementsEqual(arrayLengthSuffix)
}

// The name without its first two characters and its last twelve ("_ArrayLength"). A name shorter than fourteen
// characters keeps everything after the first two.
private func arrayLengthShortName(_ name: [UInt16]) -> [UInt16] {
    let start = 2
    guard start < name.count else {
        return []
    }
    let requested = UInt32(truncatingIfNeeded: UInt64(name.count) &- 14)
    let length = Int(min(UInt64(requested), UInt64(name.count - start)))
    return Array(name[start..<(start + length)])
}

private func stageMask(_ stages: ShaderStages) -> StageMask {
    var mask: StageMask = []
    if stages.contains(.vertex) {
        mask.insert(.vertex)
    }
    if stages.contains(.fragment) {
        mask.insert(.fragment)
    }
    if stages.contains(.compute) {
        mask.insert(.compute)
    }
    return mask
}

// The only stage in `visibility`, or nil.
private func singleStage(_ visibility: StageMask) -> Stage? {
    switch visibility {
    case .vertex: .vertex
    case .fragment: .fragment
    case .compute: .compute
    default: nil
    }
}

private func makeLayoutBinding(
    _ member: BindingMember,
    bufferTypeOverride: LayoutBufferType? = nil,
    bufferSizeForBinding: UInt64 = 0
) -> LayoutBinding {
    switch member {
    case .buffer(let buffer):
        .buffer(
            BufferLayout(
                type: bufferTypeOverride ?? layoutBufferType(buffer.type),
                hasDynamicOffset: buffer.hasDynamicOffset,
                minBindingSize: buffer.minBindingSize,
                bufferSizeForBinding: bufferSizeForBinding
            )
        )
    case .sampler(let type):
        .sampler(SamplerLayout(type: webGPUSamplerType(type)))
    case .texture(let texture):
        .texture(
            TextureLayout(
                sampleType: webGPUSampleType(texture.sampleType),
                viewDimension: webGPUViewDimension(texture.viewDimension),
                multisampled: texture.multisampled
            )
        )
    case .storageTexture(let storageTexture):
        .storageTexture(
            StorageTextureLayout(
                access: webGPUAccess(storageTexture.access),
                format: webGPUTextureFormat(storageTexture.format),
                viewDimension: webGPUViewDimension(storageTexture.viewDimension)
            )
        )
    case .externalTexture:
        .externalTexture
    }
}

private func layoutBufferType(_ type: BufferBindingType) -> LayoutBufferType {
    switch type {
    case .uniform: .uniform
    case .storage: .storage
    case .readOnlyStorage: .readOnlyStorage
    }
}

private func webGPUSamplerType(_ type: SamplerBindingType) -> WebGPU.SamplerBindingType {
    switch type {
    case .filtering: .Filtering
    case .nonFiltering: .NonFiltering
    case .comparison: .Comparison
    }
}

private func webGPUSampleType(_ sampleType: TextureSampleType) -> WebGPU.TextureSampleType {
    switch sampleType {
    case .float: .Float
    case .unfilterableFloat: .UnfilterableFloat
    case .depth: .Depth
    case .signedInt: .Sint
    case .unsignedInt: .Uint
    }
}

private func webGPUViewDimension(_ viewDimension: TextureViewDimension) -> WebGPU.TextureViewDimension {
    switch viewDimension {
    case .oneDimensional: ._1d
    case .twoDimensional: ._2d
    case .twoDimensionalArray: ._2dArray
    case .cube: .Cube
    case .cubeArray: .CubeArray
    case .threeDimensional: ._3d
    }
}

private func webGPUAccess(_ access: StorageTextureAccess) -> WebGPU.StorageTextureAccess {
    switch access {
    case .writeOnly: .WriteOnly
    case .readOnly: .ReadOnly
    case .readWrite: .ReadWrite
    }
}

private func webGPUTextureFormat(_ format: TexelFormat) -> WebGPU.TextureFormat {
    switch format {
    case .bgra8unorm: .Bgra8unorm
    case .r32float: .R32float
    case .r32sint: .R32sint
    case .r32uint: .R32uint
    case .rg32float: .Rg32float
    case .rg32sint: .Rg32sint
    case .rg32uint: .Rg32uint
    case .rgba16float: .Rgba16float
    case .rgba16sint: .Rgba16sint
    case .rgba16uint: .Rgba16uint
    case .rgba32float: .Rgba32float
    case .rgba32sint: .Rgba32sint
    case .rgba32uint: .Rgba32uint
    case .rgba8sint: .Rgba8sint
    case .rgba8snorm: .Rgba8snorm
    case .rgba8uint: .Rgba8uint
    case .rgba8unorm: .Rgba8unorm
    case .rg16unorm: .Rg16unorm
    case .rg16snorm: .Rg16snorm
    case .rgba16unorm: .Rgba16unorm
    case .rgba16snorm: .Rgba16snorm
    case .r16unorm: .R16unorm
    case .r16snorm: .R16snorm
    case .r16float: .R16float
    case .rg16float: .Rg16float
    case .rgb10a2uint: .Rgb10a2uint
    case .rgb10a2unorm: .Rgb10a2unorm
    case .r16uint: .R16uint
    case .r16sint: .R16sint
    case .r8sint: .R8sint
    case .r8snorm: .R8snorm
    case .r8uint: .R8uint
    case .r8unorm: .R8unorm
    case .rg8sint: .Rg8sint
    case .rg8snorm: .Rg8snorm
    case .rg8uint: .Rg8uint
    case .rg8unorm: .Rg8unorm
    case .rg16uint: .Rg16uint
    case .rg16sint: .Rg16sint
    case .rg11b10ufloat: .Rg11b10ufloat
    }
}
