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

// Value types shared by the layout, shader module and pipeline Impls.
//
// WGSL module types are used unqualified: the C++ namespace WGSL shadows the module name wherever WGSLAPI.h
// is imported. No type here reuses a WGSL module type name.

import Metal
internal import WGSL
import WebGPU_Private.WebGPUCpp

enum Stage: Int, CaseIterable {
    case vertex = 0
    case fragment = 1
    case compute = 2

    init?(metalRawValue: UInt8) {
        self.init(rawValue: Int(metalRawValue))
    }

    /// The bit of this stage in a StageMask.
    var bit: StageMask {
        StageMask(rawValue: UInt8(1) << UInt8(rawValue))
    }
}

/// OptionSet<WebGPU::ShaderStage> as its toRaw() bits: vertex 1, fragment 2, compute 4.
struct StageMask: OptionSet, Hashable {
    let rawValue: UInt8

    static let vertex = StageMask(rawValue: 1)
    static let fragment = StageMask(rawValue: 2)
    static let compute = StageMask(rawValue: 4)
}

/// One value per shader stage.
struct PerStage<T> {
    var vertex: T
    var fragment: T
    var compute: T

    init(vertex: T, fragment: T, compute: T) {
        self.vertex = vertex
        self.fragment = fragment
        self.compute = compute
    }

    init(repeating value: T) {
        self.init(vertex: value, fragment: value, compute: value)
    }

    subscript(stage: Stage) -> T {
        get {
            switch stage {
            case .vertex: vertex
            case .fragment: fragment
            case .compute: compute
            }
        }
        set {
            switch stage {
            case .vertex: vertex = newValue
            case .fragment: fragment = newValue
            case .compute: compute = newValue
            }
        }
    }
}

/// The buffer types of bind group layout entries, including the argument types the implementation adds.
///
/// Error messages print the raw values, and LayoutBinding.layoutEquals(_:) treats every type after readOnlyStorage as
/// implementation-added.
enum LayoutBufferType: UInt8 {
    case uniform = 0
    case storage
    case readOnlyStorage
    case float3x2
    case float4x3
    case float3x3
    case uint2
    case arrayLength
}

struct BufferLayout {
    var type: LayoutBufferType
    var hasDynamicOffset: Bool
    var minBindingSize: UInt64
    var bufferSizeForBinding: UInt64
}

struct SamplerLayout {
    var type: WebGPU.SamplerBindingType
}

struct TextureLayout {
    var sampleType: WebGPU.TextureSampleType
    var viewDimension: WebGPU.TextureViewDimension
    var multisampled: Bool
}

struct StorageTextureLayout {
    var access: WebGPU.StorageTextureAccess
    var format: WebGPU.TextureFormat
    var viewDimension: WebGPU.TextureViewDimension
}

enum LayoutBinding {
    case buffer(BufferLayout)
    case sampler(SamplerLayout)
    case texture(TextureLayout)
    case storageTexture(StorageTextureLayout)
    case externalTexture

    var bufferLayout: BufferLayout? {
        if case .buffer(let buffer) = self {
            return buffer
        }
        return nil
    }

    var isArrayLength: Bool {
        bufferLayout?.type == .arrayLength
    }

    var hasDynamicOffset: Bool {
        bufferLayout?.hasDynamicOffset ?? false
    }

    /// Whether the two binding layouts match.
    ///
    /// Deliberately not `==`: a buffer of an implementation-added type equals any buffer.
    func layoutEquals(_ other: LayoutBinding) -> Bool {
        switch (self, other) {
        case (.buffer(let a), .buffer(let b)):
            let lastAPIType = LayoutBufferType.readOnlyStorage.rawValue
            if a.type.rawValue > lastAPIType || b.type.rawValue > lastAPIType {
                return true
            }
            return a.type == b.type && a.hasDynamicOffset == b.hasDynamicOffset && a.minBindingSize == b.minBindingSize
                && a.bufferSizeForBinding == b.bufferSizeForBinding
        case (.sampler(let a), .sampler(let b)):
            return a.type == b.type
        case (.texture(let a), .texture(let b)):
            return a.multisampled == b.multisampled && a.sampleType == b.sampleType && a.viewDimension == b.viewDimension
        case (.storageTexture(let a), .storageTexture(let b)):
            return a.format == b.format && a.access == b.access && a.viewDimension == b.viewDimension
        case (.externalTexture, .externalTexture):
            return true
        default:
            return false
        }
    }
}

/// A bind group layout entry, with its argument buffer indices in each stage.
struct LayoutEntry {
    static let noDynamicOffsetsIndex = UInt32.max

    let binding: UInt32
    let visibility: StageMask
    let layout: LayoutBinding
    var argumentBufferIndices: PerStage<UInt32?>
    var bufferSizeArgumentBufferIndices: PerStage<UInt32?>
    /// vertex/fragment/computeDynamicOffset: byte offsets into the stage's dynamic-offset block.
    let dynamicOffsets: PerStage<UInt32?>
    var dynamicOffsetsIndex: UInt32
    /// The access of the entry's argument in every stage in `visibility`, or in no stage when `visibility` is empty.
    let access: MTLBindingAccess

    var hasDynamicOffsetInAnyStage: Bool {
        dynamicOffsets.vertex != nil || dynamicOffsets.fragment != nil || dynamicOffsets.compute != nil
    }

    /// nil `stage` stands for no stage.
    func bindingAccess(for stage: Stage?) -> MTLBindingAccess? {
        guard let stage else {
            return visibility.isEmpty ? access : nil
        }
        return visibility.contains(stage.bit) ? access : nil
    }
}

/// An entry of a bind group layout to create.
struct ResolvedLayoutEntry {
    var binding: UInt32
    var metalBinding: PerStage<UInt32>
    var visibility: StageMask
    var layout: LayoutBinding
}

/// A bind group layout's per-stage resource counts and identifier.
struct LayoutCounts {
    var uniformBuffers = PerStage<UInt32>(repeating: 0)
    var storageBuffers = PerStage<UInt32>(repeating: 0)
    var samplers = PerStage<UInt32>(repeating: 0)
    var textures = PerStage<UInt32>(repeating: 0)
    var storageTextures = PerStage<UInt32>(repeating: 0)
    /// Bytes, truncated to 32 bits.
    var sizeOfDynamicOffsets = PerStage<UInt32>(repeating: 0)
    var dynamicUniformBuffers: UInt32 = 0
    var dynamicStorageBuffers: UInt32 = 0
    var identifier: UInt32 = 0
    var isAutoGenerated = false

    var dynamicBufferCount: UInt32 {
        dynamicStorageBuffers &+ dynamicUniformBuffers
    }
}

/// A contiguous run of dynamic offsets: the first dynamicOffsetsIndex and the count.
struct LinearRange {
    let first: UInt32
    let count: UInt32
}

/// One bind group of one stage of PipelineLayout's dynamic-offset maps.
struct DynamicOffsetGroup {
    /// The group's first slot in the stage's dynamic-offset block (its byte offset / 4); nil when the group has none.
    var start: UInt32?
    /// The number of the group's dynamic offsets in the stage; 0 exactly when `start` is nil.
    var count: UInt64
    /// Set when the group's offsets are one contiguous run of dynamicOffsetsIndex values.
    var linearRange: LinearRange?
    /// The dynamicOffsetsIndex of each entry with a dynamic offset visible in the stage, in binding order.
    var sourceIndices: [UInt32]
}

/// All bind groups of one stage. `groups.count` == numberOfBindGroupLayouts().
struct DynamicOffsetPlan {
    var groups: [DynamicOffsetGroup] = []
    /// The sum of the groups' counts.
    var total: UInt64 = 0
}

/// The minimum buffer binding sizes a pipeline's shaders need, by group and binding.
///
/// Lookups only, so iteration order is unobservable.
struct MinimumBufferSizes {
    private(set) var groups: [UInt32: [UInt32: UInt64]] = [:]

    /// Never replaces an existing group.
    mutating func addGroup(_ group: UInt32) {
        if groups[group] == nil {
            groups[group] = [:]
        }
    }

    /// Only non-zero sizes are recorded; the max over the stages wins.
    mutating func merge(group: UInt32, binding: UInt32, size: UInt64) {
        guard size != 0 else {
            return
        }
        addGroup(group)
        let existing = groups[group]?[binding] ?? 0
        groups[group]?[binding] = max(size, existing)
    }

    func containsGroup(_ group: UInt32) -> Bool {
        groups[group] != nil
    }

    /// nil when no size is recorded; never 0.
    func size(group: UInt32, binding: UInt32) -> UInt64? {
        groups[group]?[binding]
    }

    /// Ascending.
    var sortedGroups: [UInt32] {
        groups.keys.sorted()
    }

    func sortedBindings(of group: UInt32) -> [(binding: UInt32, size: UInt64)] {
        (groups[group] ?? [:]).sorted { $0.key < $1.key }.map { (binding: $0.key, size: $0.value) }
    }
}

/// A vertex buffer a render pipeline requires.
struct RequiredVertexBuffer {
    let bufferIndex: UInt32
    var stride: UInt64
    let lastStride: UInt64
    let stepMode: WebGPU.VertexStepMode
}

/// A vertex stage input.
struct StageInLocation {
    let location: UInt32
    let format: WebGPU.VertexFormat
}

/// A vertex stage output or fragment stage input.
struct InterStageVariable {
    let location: UInt32
    let dataType: MTLDataType
    let interpolation: Interpolation?
}

/// A fragment stage output.
struct FragmentOutput {
    let location: UInt32
    let dataType: MTLDataType
}

/// The reflection of one entry point: its inputs and outputs by location, and the builtins it uses.
///
/// Each list holds the first entry per location, in WTF::HashTable iteration order (see inWTFHashTableOrder in
/// ShaderModule.swift); lookups are linear because the lists are tiny.
struct EntryPointReflection {
    let name: Name
    let stage: ShaderStage
    /// Non-nil for every vertex entry point, possibly empty (stageInTypesForEntryPoint).
    let stageIn: [StageInLocation]?
    let vertexOutputs: [InterStageVariable]?
    /// Non-nil for every fragment entry point.
    let fragmentInputs: [InterStageVariable]?
    let fragmentOutputs: [FragmentOutput]?
    let usesFrontFacingInInput: Bool
    let usesSampleIndexInInput: Bool
    let usesSampleMaskInInput: Bool
    let usesSampleMaskInOutput: Bool
    let usesFragDepth: Bool
    let usesPrimitiveIndexInInput: Bool
    let usesSubgroupInvocationIdInInput: Bool
    let usesSubgroupSizeInInput: Bool
    let clipDistancesCount: UInt32

    func stageInFormat(at location: UInt32) -> WebGPU.VertexFormat? {
        stageIn?.first { $0.location == location }?.format
    }

    func vertexOutput(at location: UInt32) -> InterStageVariable? {
        vertexOutputs?.first { $0.location == location }
    }

    func fragmentOutputType(at location: UInt32) -> MTLDataType? {
        fragmentOutputs?.first { $0.location == location }?.dataType
    }
}
