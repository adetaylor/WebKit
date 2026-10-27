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
import WebGPU_Internal.HardwareCapabilities
import WebGPU_Private.WebGPUCpp

// FIXME: these two limits should be 30 and 30, but they fail the tests
// due to https://github.com/gpuweb/cts/issues/3376
private let maxVertexBuffers: UInt32 = 12
private let maxBindGroups: UInt32 = 11

private let tier2LimitForBuffersAndTextures: UInt32 = 4
private let tier2LimitForSamplers: UInt32 = 2

private let largeReasonableLimit = UInt32(UInt16.max)

private let gigabyte: UInt64 = 1 << 30

// Swift's HardwareCapabilities::BaseCapabilities.
struct GPUBaseCapabilities: Sendable {
    var argumentBuffersTier: MTLArgumentBuffersTier
    var timestampCounterSet: (any MTLCounterSet)?
    var statisticCounterSet: (any MTLCounterSet)?
    var memoryBarrierLimit: UInt32
    var supportsNonPrivateDepthStencilTextures: Bool
    var supportsMemorylessTextures: Bool
    var canPresentRGB10A2PixelFormats: Bool
}

extension GPUBaseCapabilities {
    init(_ base: borrowing WebGPU.Metal.HardwareCapabilities.BaseCapabilities) {
        self.init(
            argumentBuffersTier: base.argumentBuffersTier,
            timestampCounterSet: base.timestampCounterSet,
            statisticCounterSet: base.statisticCounterSet,
            memoryBarrierLimit: base.memoryBarrierLimit,
            supportsNonPrivateDepthStencilTextures: base.supportsNonPrivateDepthStencilTextures,
            supportsMemorylessTextures: base.supportsMemorylessTextures,
            canPresentRGB10A2PixelFormats: base.canPresentRGB10A2PixelFormats
        )
    }

    func copy(to base: inout WebGPU.Metal.HardwareCapabilities.BaseCapabilities) {
        base.argumentBuffersTier = argumentBuffersTier
        base.timestampCounterSet = timestampCounterSet
        base.statisticCounterSet = statisticCounterSet
        base.memoryBarrierLimit = memoryBarrierLimit
        base.supportsNonPrivateDepthStencilTextures = supportsNonPrivateDepthStencilTextures
        base.supportsMemorylessTextures = supportsMemorylessTextures
        base.canPresentRGB10A2PixelFormats = canPresentRGB10A2PixelFormats
    }
}

// Swift's HardwareCapabilities, with the features sorted by raw value.
struct GPUCapabilities {
    var limits: WebGPU.Limits
    var features: [WebGPU.FeatureName]
    var baseCapabilities: GPUBaseCapabilities

    func copy(to result: inout WebGPU.Metal.HardwareCapabilities) {
        result.limits = limits
        for feature in features {
            result.features.append(consuming: feature)
        }
        baseCapabilities.copy(to: &result.baseCapabilities)
    }
}

// A device's capabilities, fixed when the device is created. An invalid device's are all zero.
struct DeviceCapabilities: Sendable {
    let limits: WebGPU.Limits
    // As requested: order and duplicates are kept, and features() returns them as is.
    let features: [WebGPU.FeatureName]
    let base: GPUBaseCapabilities

    init(_ capabilities: borrowing WebGPU.Metal.HardwareCapabilities) {
        limits = capabilities.limits
        features = featureArray(capabilities.features)
        base = GPUBaseCapabilities(capabilities.baseCapabilities)
    }

    func hasFeature(_ feature: WebGPU.FeatureName) -> Bool {
        features.contains(feature)
    }

    // Encoding an ICB into an argument buffer, and dereferencing that argument buffer from a shader in order to write
    // render_command slots, both require argument buffers tier 2. Tier 1 devices (Apple4/Apple5, e.g. A12) must replay
    // render bundle commands into the render pass instead.
    var supportsIndirectCommandBuffersInArgumentBuffers: Bool {
        base.argumentBuffersTier.rawValue >= MTLArgumentBuffersTier.tier2.rawValue
    }

    /// The limits a valid device's encoders read.
    ///
    /// Its limits passed requestDevice (ValidatedLimits); anything else reaching a valid device is a bug, and stops
    /// here.
    var validDeviceEncoderLimits: EncoderLimits {
        let validated = ValidatedLimits(installed: limits)
        return EncoderLimits(
            maxBindGroups: limits.maxBindGroups,
            maxBindGroupsPlusVertexBuffers: limits.maxBindGroupsPlusVertexBuffers,
            maxVertexBuffers: limits.maxVertexBuffers,
            maxComputeWorkgroupsPerDimension: limits.maxComputeWorkgroupsPerDimension,
            maxTextureDimension2D: limits.maxTextureDimension2D,
            minUniformBufferOffsetAlignment: limits.minUniformBufferOffsetAlignment,
            minStorageBufferOffsetAlignment: limits.minStorageBufferOffsetAlignment,
            memoryBarrierLimit: base.memoryBarrierLimit,
            maxUniformBufferBindingSize: limits.maxUniformBufferBindingSize,
            maxStorageBufferBindingSize: limits.maxStorageBufferBindingSize,
            supportsIndirectCommandBuffersInArgumentBuffers: supportsIndirectCommandBuffersInArgumentBuffers,
            slots: validated.slots,
            uniformAlignment: validated.minUniformBufferOffsetAlignment,
            storageAlignment: validated.minStorageBufferOffsetAlignment
        )
    }
}

/// The limits and capabilities the encoders read, fixed when the device is made.
///
/// The raw values print in validation messages; the typed ones are what binding and alignment checks use.
struct EncoderLimits: Sendable {
    let maxBindGroups: UInt32
    let maxBindGroupsPlusVertexBuffers: UInt32
    let maxVertexBuffers: UInt32
    let maxComputeWorkgroupsPerDimension: UInt32
    let maxTextureDimension2D: UInt32
    let minUniformBufferOffsetAlignment: UInt32
    let minStorageBufferOffsetAlignment: UInt32
    let memoryBarrierLimit: UInt32
    let maxUniformBufferBindingSize: UInt64
    let maxStorageBufferBindingSize: UInt64
    let supportsIndirectCommandBuffersInArgumentBuffers: Bool
    /// Where the encoders and the shaders put each buffer.
    let slots: MetalSlotLayout
    let uniformAlignment: PowerOfTwo
    let storageAlignment: PowerOfTwo

    /// An invalid device's: the raw values are zero; the typed ones are the defaults', which nothing reaches (its
    /// encoders, passes, bundles and bind groups are all invalid).
    static let invalidDevice = EncoderLimits(
        maxBindGroups: 0,
        maxBindGroupsPlusVertexBuffers: 0,
        maxVertexBuffers: 0,
        maxComputeWorkgroupsPerDimension: 0,
        maxTextureDimension2D: 0,
        minUniformBufferOffsetAlignment: 0,
        minStorageBufferOffsetAlignment: 0,
        memoryBarrierLimit: 0,
        maxUniformBufferBindingSize: 0,
        maxStorageBufferBindingSize: 0,
        supportsIndirectCommandBuffersInArgumentBuffers: false,
        slots: ValidatedLimits.defaults.slots,
        uniformAlignment: ValidatedLimits.defaults.minUniformBufferOffsetAlignment,
        storageAlignment: ValidatedLimits.defaults.minStorageBufferOffsetAlignment
    )
}

func featureArray(_ features: borrowing WebGPU.Metal.FeatureNames) -> [WebGPU.FeatureName] {
    let entries: Span<WebGPU.FeatureName> = features.span()
    var result: [WebGPU.FeatureName] = []
    result.reserveCapacity(entries.count)
    for index in entries.indices {
        result.append(entries[index])
    }
    return result
}

private func multipleOf4<T: FixedWidthInteger>(_ input: T) -> T {
    input & ~3
}

private func maxBufferSize(_ device: any MTLDevice) -> UInt64 {
    let maxBuffersToAllow: UInt64 = 3
    // An NSUInteger, zero-extended: on arm64_32 the Int it imports as is 32 bits, and converting that would sign-extend.
    let maxBufferLength = UInt64(UInt(bitPattern: device.maxBufferLength))
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    let result = max(min(maxBufferLength, gigabyte), min(UInt64(Int32.max), maxBufferLength / maxBuffersToAllow))
    #else
    let result = max(WebGPU.defaultLimits().maxBufferSize, min(gigabyte, maxBufferLength / maxBuffersToAllow))
    #endif
    return multipleOf4(result)
}

private func workaroundCTSBindGroupLimit(_ valueToClamp: UInt32) -> UInt32 {
    valueToClamp > 1000 ? 1000 : valueToClamp
}

// std::bit_ceil.
private func roundUpToPowerOfTwo(_ value: UInt32) -> UInt32 {
    value <= 1 ? 1 : 1 << (32 - (value - 1).leadingZeroBitCount)
}

private func sortedFeatures(_ features: [WebGPU.FeatureName]) -> [WebGPU.FeatureName] {
    features.sorted { $0.rawValue < $1.rawValue }
}

private func isSorted(_ features: [WebGPU.FeatureName]) -> Bool {
    zip(features, features.dropFirst()).allSatisfy { $0.rawValue <= $1.rawValue }
}

#if arch(x86_64)
private func isIntel(_ device: any MTLDevice) -> Bool {
    device.name.localizedCaseInsensitiveContains("intel")
}
#endif

// https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

private func commonCounterSets(_ device: any MTLDevice) -> (timestamp: (any MTLCounterSet)?, statistic: (any MTLCounterSet)?) {
    var timestamp: (any MTLCounterSet)?
    var statistic: (any MTLCounterSet)?
    if device.supportsCounterSampling(.atStageBoundary) {
        for counterSet in device.counterSets ?? [] {
            if counterSet.name == MTLCommonCounterSet.timestamp.rawValue {
                timestamp = counterSet
            } else if counterSet.name == MTLCommonCounterSet.statistic.rawValue {
                statistic = counterSet
            }
        }
    }
    return (timestamp, statistic)
}

private func baseCapabilities(_ device: any MTLDevice) -> GPUBaseCapabilities {
    #if arch(x86_64)
    let counterSets = isIntel(device) ? (timestamp: nil, statistic: nil) : commonCounterSets(device)
    #else
    let counterSets = commonCounterSets(device)
    #endif

    return GPUBaseCapabilities(
        argumentBuffersTier: device.argumentBuffersSupport,
        timestampCounterSet: counterSets.timestamp,
        statisticCounterSet: counterSets.statistic,
        memoryBarrierLimit: .max,
        supportsNonPrivateDepthStencilTextures: false, // To be filled in by the caller.
        // MTLStorageModeMemoryless needs tile memory, which only Apple-family GPUs have, so a
        // transient attachment has to fall back to a private texture on an Intel or AMD GPU.
        supportsMemorylessTextures: device.supportsFamily(.apple1),
        canPresentRGB10A2PixelFormats: false // To be filled in by the caller.
    )
}

private func baseFeatures(_ device: any MTLDevice, _ baseCapabilities: GPUBaseCapabilities) -> [WebGPU.FeatureName] {
    var features: [WebGPU.FeatureName] = [
        .CoreFeaturesAndLimits,
        .Float16Renderable,
        .Float32Renderable,
        .Float32Blendable,
        .ClipDistances,
        .DepthClipControl,
        .Depth32floatStencil8,
    ]

    #if !WTF_PLATFORM_WATCHOS
    if device.supportsBCTextureCompression {
        features.append(.TextureCompressionBc)
        features.append(.TextureCompressionBcSliced3d)
    }
    #endif

    // TextureCompressionEtc2 and TextureCompressionAstc are to be filled in by the caller.

    features.append(.IndirectFirstInstance)
    features.append(.Rg11b10ufloatRenderable)
    features.append(.ShaderF16)
    features.append(.Bgra8unormStorage)
    features.append(.TextureComponentSwizzle)
    #if arch(arm64) || arch(arm64_32)
    features.append(.TextureFormatsTier1)
    features.append(.TextureFormatsTier2)
    #endif
    if device.supportsShaderBarycentricCoordinates {
        features.append(.PrimitiveIndex)
    }

    // Subgroup (SIMD-group) built-in functions are guaranteed across GPU vendors by the
    // Metal 3 feature set, which provides the full reduction, prefix-scan, shuffle, ballot,
    // and quad operation set that the WGSL 'subgroups' extension requires.
    if device.supportsFamily(.metal3) {
        features.append(.Subgroups)
    }

    #if !WTF_PLATFORM_WATCHOS
    if device.supports32BitFloatFiltering {
        features.append(.Float32Filterable)
    }
    #endif

    if baseCapabilities.timestampCounterSet != nil {
        features.append(.TimestampQuery)
    }

    return features
}

// The Apple6, Apple7 and Mac2 limits, which differ only in maxBindingsPerBindGroup and the offset alignments.
private func tier2Limits(_ device: any MTLDevice, maxBindingsPerBindGroup: UInt32, minOffsetAlignment: UInt32) -> WebGPU.Limits {
    let perStageLimit = maxBindGroups * tier2LimitForBuffersAndTextures
    return WebGPU.Limits(
        maxTextureDimension1D: 16384,
        maxTextureDimension2D: 16384,
        maxTextureDimension3D: 2048,
        maxTextureArrayLayers: 2048,
        maxBindGroups: maxBindGroups,
        maxBindGroupsPlusVertexBuffers: 30,
        maxBindingsPerBindGroup: maxBindingsPerBindGroup,
        // A dynamic uniform buffer is still a uniform buffer binding, so advertising more of them
        // than a single stage can hold would let the two limits contradict each other.
        maxDynamicUniformBuffersPerPipelineLayout: perStageLimit,
        maxDynamicStorageBuffersPerPipelineLayout: largeReasonableLimit,
        maxSampledTexturesPerShaderStage: perStageLimit,
        maxSamplersPerShaderStage: maxBindGroups * tier2LimitForSamplers,
        maxStorageBuffersPerShaderStage: perStageLimit,
        maxStorageTexturesPerShaderStage: perStageLimit,
        maxUniformBuffersPerShaderStage: perStageLimit,
        maxUniformBufferBindingSize: 0, // To be filled in by the caller.
        maxStorageBufferBindingSize: 0, // To be filled in by the caller.
        minUniformBufferOffsetAlignment: minOffsetAlignment,
        minStorageBufferOffsetAlignment: minOffsetAlignment,
        maxVertexBuffers: maxVertexBuffers,
        maxBufferSize: maxBufferSize(device),
        maxVertexAttributes: 30,
        maxVertexBufferArrayStride: multipleOf4(largeReasonableLimit),
        maxInterStageShaderVariables: 31,
        maxColorAttachments: 8,
        maxColorAttachmentBytesPerSample: 64,
        maxComputeWorkgroupStorageSize: 32 * 1024,
        maxComputeInvocationsPerWorkgroup: 1024,
        maxComputeWorkgroupSizeX: 1024,
        maxComputeWorkgroupSizeY: 1024,
        maxComputeWorkgroupSizeZ: 1024,
        maxComputeWorkgroupsPerDimension: largeReasonableLimit,
        maxStorageBuffersInFragmentStage: perStageLimit,
        maxStorageTexturesInFragmentStage: perStageLimit,
        maxStorageBuffersInVertexStage: perStageLimit,
        maxStorageTexturesInVertexStage: perStageLimit
    )
}

// Apple4 through Apple7.
private func appleCapabilities(_ device: any MTLDevice, _ limits: WebGPU.Limits, memoryBarrierLimit: UInt32? = nil) -> GPUCapabilities {
    var base = baseCapabilities(device)
    base.supportsNonPrivateDepthStencilTextures = true
    base.canPresentRGB10A2PixelFormats = false
    if let memoryBarrierLimit {
        base.memoryBarrierLimit = memoryBarrierLimit
    }

    var features = baseFeatures(device, base)
    features.append(.TextureCompressionEtc2)
    features.append(.TextureCompressionAstc)
    features.append(.TextureCompressionAstcSliced3d)

    return GPUCapabilities(limits: limits, features: sortedFeatures(features), baseCapabilities: base)
}

private func mac2(_ device: any MTLDevice) -> GPUCapabilities {
    var base = baseCapabilities(device)
    base.supportsNonPrivateDepthStencilTextures = false
    base.canPresentRGB10A2PixelFormats = true
    if !device.supportsFamily(.apple4) {
        base.memoryBarrierLimit = 0
    } else if !device.supportsFamily(.apple8) {
        base.memoryBarrierLimit = 512
    }

    return GPUCapabilities(
        limits: tier2Limits(device, maxBindingsPerBindGroup: 1000, minOffsetAlignment: 256),
        features: sortedFeatures(baseFeatures(device, base)),
        baseCapabilities: base
    )
}

// https://gpuweb.github.io/gpuweb/#limit-class-maximum
private func mergeMaximum<T: Comparable>(_ previous: T, _ next: T) -> T {
    max(previous, next)
}

// https://gpuweb.github.io/gpuweb/#limit-class-alignment
private func mergeAlignment(_ previous: UInt32, _ next: UInt32) -> UInt32 {
    min(roundUpToPowerOfTwo(previous), roundUpToPowerOfTwo(next))
}

private func mergeLimits(_ previous: WebGPU.Limits, _ next: WebGPU.Limits) -> WebGPU.Limits {
    WebGPU.Limits(
        maxTextureDimension1D: mergeMaximum(previous.maxTextureDimension1D, next.maxTextureDimension1D),
        maxTextureDimension2D: mergeMaximum(previous.maxTextureDimension2D, next.maxTextureDimension2D),
        maxTextureDimension3D: mergeMaximum(previous.maxTextureDimension3D, next.maxTextureDimension3D),
        maxTextureArrayLayers: mergeMaximum(previous.maxTextureArrayLayers, next.maxTextureArrayLayers),
        maxBindGroups: mergeMaximum(previous.maxBindGroups, next.maxBindGroups),
        maxBindGroupsPlusVertexBuffers: mergeMaximum(previous.maxBindGroupsPlusVertexBuffers, next.maxBindGroupsPlusVertexBuffers),
        maxBindingsPerBindGroup: mergeMaximum(previous.maxBindingsPerBindGroup, next.maxBindingsPerBindGroup),
        maxDynamicUniformBuffersPerPipelineLayout: mergeMaximum(
            previous.maxDynamicUniformBuffersPerPipelineLayout,
            next.maxDynamicUniformBuffersPerPipelineLayout
        ),
        maxDynamicStorageBuffersPerPipelineLayout: mergeMaximum(
            previous.maxDynamicStorageBuffersPerPipelineLayout,
            next.maxDynamicStorageBuffersPerPipelineLayout
        ),
        maxSampledTexturesPerShaderStage: workaroundCTSBindGroupLimit(
            mergeMaximum(previous.maxSampledTexturesPerShaderStage, next.maxSampledTexturesPerShaderStage)
        ),
        maxSamplersPerShaderStage: workaroundCTSBindGroupLimit(
            mergeMaximum(previous.maxSamplersPerShaderStage, next.maxSamplersPerShaderStage)
        ),
        maxStorageBuffersPerShaderStage: workaroundCTSBindGroupLimit(
            mergeMaximum(previous.maxStorageBuffersPerShaderStage, next.maxStorageBuffersPerShaderStage)
        ),
        maxStorageTexturesPerShaderStage: workaroundCTSBindGroupLimit(
            mergeMaximum(previous.maxStorageTexturesPerShaderStage, next.maxStorageTexturesPerShaderStage)
        ),
        maxUniformBuffersPerShaderStage: workaroundCTSBindGroupLimit(
            mergeMaximum(previous.maxUniformBuffersPerShaderStage, next.maxUniformBuffersPerShaderStage)
        ),
        maxUniformBufferBindingSize: mergeMaximum(previous.maxUniformBufferBindingSize, next.maxUniformBufferBindingSize),
        maxStorageBufferBindingSize: mergeMaximum(previous.maxStorageBufferBindingSize, next.maxStorageBufferBindingSize),
        minUniformBufferOffsetAlignment: mergeAlignment(previous.minUniformBufferOffsetAlignment, next.minUniformBufferOffsetAlignment),
        minStorageBufferOffsetAlignment: mergeAlignment(previous.minStorageBufferOffsetAlignment, next.minStorageBufferOffsetAlignment),
        maxVertexBuffers: mergeMaximum(previous.maxVertexBuffers, next.maxVertexBuffers),
        maxBufferSize: mergeMaximum(previous.maxBufferSize, next.maxBufferSize),
        maxVertexAttributes: mergeMaximum(previous.maxVertexAttributes, next.maxVertexAttributes),
        maxVertexBufferArrayStride: mergeMaximum(previous.maxVertexBufferArrayStride, next.maxVertexBufferArrayStride),
        maxInterStageShaderVariables: mergeMaximum(previous.maxInterStageShaderVariables, next.maxInterStageShaderVariables),
        maxColorAttachments: mergeMaximum(previous.maxColorAttachments, next.maxColorAttachments),
        maxColorAttachmentBytesPerSample: mergeMaximum(previous.maxColorAttachmentBytesPerSample, next.maxColorAttachmentBytesPerSample),
        maxComputeWorkgroupStorageSize: mergeMaximum(previous.maxComputeWorkgroupStorageSize, next.maxComputeWorkgroupStorageSize),
        maxComputeInvocationsPerWorkgroup: mergeMaximum(previous.maxComputeInvocationsPerWorkgroup, next.maxComputeInvocationsPerWorkgroup),
        maxComputeWorkgroupSizeX: mergeMaximum(previous.maxComputeWorkgroupSizeX, next.maxComputeWorkgroupSizeX),
        maxComputeWorkgroupSizeY: mergeMaximum(previous.maxComputeWorkgroupSizeY, next.maxComputeWorkgroupSizeY),
        maxComputeWorkgroupSizeZ: mergeMaximum(previous.maxComputeWorkgroupSizeZ, next.maxComputeWorkgroupSizeZ),
        maxComputeWorkgroupsPerDimension: mergeMaximum(previous.maxComputeWorkgroupsPerDimension, next.maxComputeWorkgroupsPerDimension),
        maxStorageBuffersInFragmentStage: mergeMaximum(previous.maxStorageBuffersInFragmentStage, next.maxStorageBuffersInFragmentStage),
        maxStorageTexturesInFragmentStage: mergeMaximum(previous.maxStorageTexturesInFragmentStage, next.maxStorageTexturesInFragmentStage),
        maxStorageBuffersInVertexStage: mergeMaximum(previous.maxStorageBuffersInVertexStage, next.maxStorageBuffersInVertexStage),
        maxStorageTexturesInVertexStage: mergeMaximum(previous.maxStorageTexturesInVertexStage, next.maxStorageTexturesInVertexStage)
    )
}

// WTF::mergeDeduplicatedSorted.
private func mergeFeatures(_ previous: [WebGPU.FeatureName], _ next: [WebGPU.FeatureName]) -> [WebGPU.FeatureName] {
    assert(isSorted(previous))
    assert(isSorted(next))

    var result: [WebGPU.FeatureName] = []
    result.reserveCapacity(previous.count + next.count)
    var left = 0
    var right = 0
    while left < previous.count && right < next.count {
        if previous[left].rawValue < next[right].rawValue {
            result.append(previous[left])
            left += 1
        } else if previous[left] == next[right] {
            result.append(previous[left])
            left += 1
            right += 1
        } else {
            result.append(next[right])
            right += 1
        }
    }
    result.append(contentsOf: previous[left...])
    result.append(contentsOf: next[right...])
    return result
}

private func mergeBaseCapabilities(_ previous: GPUBaseCapabilities, _ next: GPUBaseCapabilities) -> GPUBaseCapabilities {
    assert(previous.argumentBuffersTier == next.argumentBuffersTier)
    assert(
        (previous.timestampCounterSet == nil && next.timestampCounterSet == nil)
            || previous.timestampCounterSet?.isEqual(next.timestampCounterSet) == true
    )
    assert(previous.statisticCounterSet == nil || previous.statisticCounterSet?.isEqual(next.statisticCounterSet) == true)
    return GPUBaseCapabilities(
        argumentBuffersTier: previous.argumentBuffersTier,
        timestampCounterSet: previous.timestampCounterSet,
        statisticCounterSet: previous.statisticCounterSet,
        memoryBarrierLimit: min(previous.memoryBarrierLimit, next.memoryBarrierLimit),
        supportsNonPrivateDepthStencilTextures: previous.supportsNonPrivateDepthStencilTextures
            || next.supportsNonPrivateDepthStencilTextures,
        supportsMemorylessTextures: previous.supportsMemorylessTextures || next.supportsMemorylessTextures,
        canPresentRGB10A2PixelFormats: previous.canPresentRGB10A2PixelFormats || next.canPresentRGB10A2PixelFormats
    )
}

// MTLGPUFamilyMac2 is deprecated; its raw value avoids the warning. An imported Objective-C enum accepts any raw value.
// swift-format-ignore: NeverForceUnwrap
let mac2Family = MTLGPUFamily(rawValue: 2002)!

private func rawHardwareCapabilities(_ device: any MTLDevice) -> GPUCapabilities? {
    if !WebGPU.Metal.isPhysicalHardware() {
        return nil
    }

    var result: GPUCapabilities?
    func merge(_ capabilities: GPUCapabilities) {
        guard let previous = result else {
            result = capabilities
            return
        }
        result = GPUCapabilities(
            limits: mergeLimits(previous.limits, capabilities.limits),
            features: mergeFeatures(previous.features, capabilities.features),
            baseCapabilities: mergeBaseCapabilities(previous.baseCapabilities, capabilities.baseCapabilities)
        )
    }

    if device.supportsFamily(.apple4) {
        merge(
            appleCapabilities(device, WebGPU.defaultLimits(), memoryBarrierLimit: WebGPU.Metal.isShaderValidationEnabled(device) ? 0 : .max)
        )
    }
    if device.supportsFamily(.apple5) {
        merge(appleCapabilities(device, WebGPU.defaultLimits()))
    }
    #if !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_APPLETV
    if device.supportsFamily(.apple6) {
        merge(appleCapabilities(device, tier2Limits(device, maxBindingsPerBindGroup: largeReasonableLimit, minOffsetAlignment: 32)))
    }
    if device.supportsFamily(.apple7) {
        merge(appleCapabilities(device, tier2Limits(device, maxBindingsPerBindGroup: largeReasonableLimit, minOffsetAlignment: 32)))
    }
    #endif
    // MTLGPUFamilyMac1 is not supported (yet?).
    if device.supportsFamily(mac2Family) {
        merge(mac2(device))
    }

    guard var capabilities = result else {
        return nil
    }
    let maxBufferLength = maxBufferSize(device)
    capabilities.limits.maxUniformBufferBindingSize = maxBufferLength
    capabilities.limits.maxStorageBufferBindingSize = maxBufferLength
    return capabilities
}

/// Metal's buffer argument table: indices 0...30 per stage.
let metalBufferSlotCount: UInt32 = 31

// MARK: Validated limits and the Metal buffer slots they imply

/// A nonzero power of two, so that an alignment check is a mask and cannot divide by zero.
struct PowerOfTwo: Sendable, Equatable {
    let value: UInt32

    init?(_ value: UInt32) {
        guard value.nonzeroBitCount == 1 else {
            return nil
        }
        self.value = value
    }

    func isMultiple<T: FixedWidthInteger & UnsignedInteger>(_ offset: T) -> Bool {
        offset & T(value &- 1) == 0
    }
}

/// An index into one stage's Metal buffer argument table (0...30).
///
/// Made only in this file: from a helper slot, or from a MetalSlotLayout, which proved that the limits fit.
struct MetalBufferSlot: Sendable, Equatable {
    let index: Int

    fileprivate init(_ index: UInt32) {
        assert(index < metalBufferSlotCount)
        self.index = Int(index)
    }

    var rawValue: UInt32 {
        UInt32(truncatingIfNeeded: index)
    }
}

/// The vertex-stage slots the helper kernels bind inside a render pass.
///
/// The index and indirect clamps and the ICB encode kernels of executeBundles use them. A MetalSlotLayout puts no bind
/// group, vertex buffer or dynamic offsets on one.
enum HelperVertexSlot: UInt32 {
    case zero = 0
    case one
    case two
    case three

    var slot: MetalBufferSlot {
        MetalBufferSlot(rawValue)
    }
}

/// The compute-stage slots of the indirect dispatch clamp.
enum HelperComputeSlot: UInt32 {
    case indirectArguments = 0
    case clampedArguments = 1

    var slot: MetalBufferSlot {
        MetalBufferSlot(rawValue)
    }
}

/// The slot a stage's dynamic offsets go in.
///
/// Not a MetalBufferSlot, so nothing that binds a buffer can name it: only the dynamic-offset sends, which read its
/// index, take one.
struct DynamicOffsetsSlot: Sendable, Equatable {
    fileprivate let slot: MetalBufferSlot

    var index: Int {
        slot.index
    }

    var rawValue: UInt32 {
        slot.rawValue
    }
}

/// Where a device's encoders and its shaders put each buffer, fixed when the device is made from validated limits.
struct MetalSlotLayout: Sendable {
    let vertexDynamicOffsets: DynamicOffsetsSlot
    let fragmentDynamicOffsets: DynamicOffsetsSlot
    let computeDynamicOffsets: DynamicOffsetsSlot
    /// The vertex-stage slot of each bind group below maxBindGroups (WGSL's vertexBufferIndexForBindGroup).
    private let vertexBindGroups: [MetalBufferSlot]
    private let maxBindGroups: UInt32
    private let maxVertexBuffers: UInt32

    init?(_ limits: WebGPU.Limits) {
        guard limitsFitMetalSlots(limits) else {
            return nil
        }
        vertexDynamicOffsets = DynamicOffsetsSlot(slot: MetalBufferSlot(limits.maxBindGroupsPlusVertexBuffers))
        fragmentDynamicOffsets = DynamicOffsetsSlot(slot: MetalBufferSlot(limits.maxBindGroups))
        computeDynamicOffsets = DynamicOffsetsSlot(slot: MetalBufferSlot(limits.maxBindGroups))
        let maxIndex = limits.maxBindGroupsPlusVertexBuffers - 1
        vertexBindGroups = (0..<limits.maxBindGroups).map { MetalBufferSlot(wgslVertexBufferIndexForBindGroup($0, maxIndex)) }
        maxBindGroups = limits.maxBindGroups
        maxVertexBuffers = limits.maxVertexBuffers
    }

    /// A bind group's vertex-stage slot. setBindGroup keeps groups below maxBindGroups.
    func vertexBindGroupSlot(_ group: UInt32) -> MetalBufferSlot {
        vertexBindGroups[Int(group)]
    }

    /// A bind group's fragment- or compute-stage slot: its index. setBindGroup keeps groups below maxBindGroups.
    func bindGroupSlot(_ group: UInt32) -> MetalBufferSlot {
        assert(group < maxBindGroups)
        return MetalBufferSlot(group)
    }

    /// The slot of the app's vertex buffer `slot`, which validation keeps below maxVertexBuffers.
    func vertexBufferSlot(_ slot: UInt32) -> MetalBufferSlot? {
        slot < maxVertexBuffers ? MetalBufferSlot(slot) : nil
    }

    /// An ICB command's vertex buffer bind count: every slot up to the dynamic offsets.
    var vertexBindCount: Int {
        vertexDynamicOffsets.index + 1
    }

    var fragmentBindCount: Int {
        fragmentDynamicOffsets.index + 1
    }
}

/// A device's limits as requestDevice accepted them, with what follows from them.
struct ValidatedLimits: Sendable {
    /// What limits() reports.
    let limits: WebGPU.Limits
    let slots: MetalSlotLayout
    let minUniformBufferOffsetAlignment: PowerOfTwo
    let minStorageBufferOffsetAlignment: PowerOfTwo

    private init?(accepted limits: WebGPU.Limits) {
        guard let slots = MetalSlotLayout(limits),
            let uniformAlignment = PowerOfTwo(limits.minUniformBufferOffsetAlignment),
            let storageAlignment = PowerOfTwo(limits.minStorageBufferOffsetAlignment)
        else {
            return nil
        }
        self.limits = limits
        self.slots = slots
        minUniformBufferOffsetAlignment = uniformAlignment
        minStorageBufferOffsetAlignment = storageAlignment
    }

    /// GPUAdapter.requestDevice: nil rejects the request.
    init?(requested: WebGPU.Limits, adapter: WebGPU.Limits) {
        guard let limits = requestedDeviceLimits(requested, adapter: adapter) else {
            return nil
        }
        self.init(accepted: limits)
    }

    // swift-format-ignore: NeverForceUnwrap
    static let defaults = ValidatedLimits(accepted: WebGPU.defaultLimits())!

    /// Device creation, from the limits errorRequestingDevice put in the capabilities.
    init(installed limits: WebGPU.Limits) {
        guard let validated = ValidatedLimits(accepted: limits) else {
            preconditionFailure("device limits were not validated by requestDevice")
        }
        self = validated
    }
}

/// Whether the buffer slots the limits imply fit Metal's table and stay clear of the helper kernels' slots.
///
/// The vertex stage's dynamic offsets go at maxBindGroupsPlusVertexBuffers and its bind groups just below; the
/// fragment and compute stages' dynamic offsets go at maxBindGroups.
func limitsFitMetalSlots(_ limits: WebGPU.Limits) -> Bool {
    limits.maxBindGroupsPlusVertexBuffers < metalBufferSlotCount
        && limits.maxBindGroupsPlusVertexBuffers > HelperVertexSlot.three.rawValue
        && limits.maxBindGroups <= limits.maxBindGroupsPlusVertexBuffers
        && limits.maxBindGroups < metalBufferSlotCount
        && limits.maxBindGroups <= UInt32(maxBindGroupIndexCount)
        && limits.maxBindGroups > HelperComputeSlot.clampedArguments.rawValue
        && limits.maxVertexBuffers <= metalBufferSlotCount
}

/// The limits of a device asked for with `requested` (https://gpuweb.github.io/gpuweb/#dom-gpuadapter-requestdevice).
///
/// nil when any limit is better than the adapter's or an alignment is not a power of two; otherwise every limit is the
/// better of the requested one and the default. Built with the memberwise initializer, so a new WebGPU::Limits field
/// does not compile until it is listed here.
func requestedDeviceLimits(_ requested: WebGPU.Limits, adapter: WebGPU.Limits) -> WebGPU.Limits? {
    let defaults = WebGPU.defaultLimits()
    var rejected = false
    func maximum<T: FixedWidthInteger>(_ field: KeyPath<WebGPU.Limits, T>) -> T {
        let value = requested[keyPath: field]
        if value > adapter[keyPath: field] {
            rejected = true
        }
        return max(value, defaults[keyPath: field])
    }
    func alignment(_ field: KeyPath<WebGPU.Limits, UInt32>) -> UInt32 {
        let value = requested[keyPath: field]
        if value.nonzeroBitCount != 1 || value < adapter[keyPath: field] {
            rejected = true
        }
        return min(value, defaults[keyPath: field])
    }
    let limits = WebGPU.Limits(
        maxTextureDimension1D: maximum(\.maxTextureDimension1D),
        maxTextureDimension2D: maximum(\.maxTextureDimension2D),
        maxTextureDimension3D: maximum(\.maxTextureDimension3D),
        maxTextureArrayLayers: maximum(\.maxTextureArrayLayers),
        maxBindGroups: maximum(\.maxBindGroups),
        maxBindGroupsPlusVertexBuffers: maximum(\.maxBindGroupsPlusVertexBuffers),
        maxBindingsPerBindGroup: maximum(\.maxBindingsPerBindGroup),
        maxDynamicUniformBuffersPerPipelineLayout: maximum(\.maxDynamicUniformBuffersPerPipelineLayout),
        maxDynamicStorageBuffersPerPipelineLayout: maximum(\.maxDynamicStorageBuffersPerPipelineLayout),
        maxSampledTexturesPerShaderStage: maximum(\.maxSampledTexturesPerShaderStage),
        maxSamplersPerShaderStage: maximum(\.maxSamplersPerShaderStage),
        maxStorageBuffersPerShaderStage: maximum(\.maxStorageBuffersPerShaderStage),
        maxStorageTexturesPerShaderStage: maximum(\.maxStorageTexturesPerShaderStage),
        maxUniformBuffersPerShaderStage: maximum(\.maxUniformBuffersPerShaderStage),
        maxUniformBufferBindingSize: maximum(\.maxUniformBufferBindingSize),
        maxStorageBufferBindingSize: maximum(\.maxStorageBufferBindingSize),
        minUniformBufferOffsetAlignment: alignment(\.minUniformBufferOffsetAlignment),
        minStorageBufferOffsetAlignment: alignment(\.minStorageBufferOffsetAlignment),
        maxVertexBuffers: maximum(\.maxVertexBuffers),
        maxBufferSize: maximum(\.maxBufferSize),
        maxVertexAttributes: maximum(\.maxVertexAttributes),
        maxVertexBufferArrayStride: maximum(\.maxVertexBufferArrayStride),
        maxInterStageShaderVariables: maximum(\.maxInterStageShaderVariables),
        maxColorAttachments: maximum(\.maxColorAttachments),
        maxColorAttachmentBytesPerSample: maximum(\.maxColorAttachmentBytesPerSample),
        maxComputeWorkgroupStorageSize: maximum(\.maxComputeWorkgroupStorageSize),
        maxComputeInvocationsPerWorkgroup: maximum(\.maxComputeInvocationsPerWorkgroup),
        maxComputeWorkgroupSizeX: maximum(\.maxComputeWorkgroupSizeX),
        maxComputeWorkgroupSizeY: maximum(\.maxComputeWorkgroupSizeY),
        maxComputeWorkgroupSizeZ: maximum(\.maxComputeWorkgroupSizeZ),
        maxComputeWorkgroupsPerDimension: maximum(\.maxComputeWorkgroupsPerDimension),
        maxStorageBuffersInFragmentStage: maximum(\.maxStorageBuffersInFragmentStage),
        maxStorageTexturesInFragmentStage: maximum(\.maxStorageTexturesInFragmentStage),
        maxStorageBuffersInVertexStage: maximum(\.maxStorageBuffersInVertexStage),
        maxStorageTexturesInVertexStage: maximum(\.maxStorageTexturesInVertexStage)
    )
    guard !rejected, limitsFitMetalSlots(limits) else {
        return nil
    }
    return limits
}

func includesUnsupportedFeatures(_ target: borrowing WebGPU.Metal.FeatureNames, _ reference: [WebGPU.FeatureName]) -> Bool {
    assert(isSorted(reference))
    let entries: Span<WebGPU.FeatureName> = target.span()
    for index in entries.indices where !reference.contains(entries[index]) {
        return true
    }
    return false
}

// Fills in `result` for hardwareCapabilities(id<MTLDevice>). False when WebGPU is unsupported.
@_expose(Cxx)
func computeHardwareCapabilities(_ device: (any MTLDevice)?, _ result: inout WebGPU.Metal.HardwareCapabilities) -> Bool {
    guard let device, let capabilities = rawHardwareCapabilities(device),
        requestedDeviceLimits(WebGPU.defaultLimits(), adapter: capabilities.limits) != nil
    else {
        return false
    }
    assert(limitsFitMetalSlots(capabilities.limits))
    capabilities.copy(to: &result)
    return true
}
