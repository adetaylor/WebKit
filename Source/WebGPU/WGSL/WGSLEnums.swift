// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

/// WGSL::AddressSpace, in the C++ case order.
@_spi(Testing)
public enum AddressSpace: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case function
    case handle
    case `private`
    case storage
    case uniform
    case workgroup
}

/// WGSL::AccessMode, in the C++ case order.
@_spi(Testing)
public enum AccessMode: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case read = 1
    case readWrite = 3
    case write = 2
}

/// WGSL::TexelFormat: same cases, in the same order.
public enum TexelFormat: UInt8, CaseIterable, Hashable, Sendable {
    case bgra8unorm
    case r16float
    case r16sint
    case r16snorm
    case r16uint
    case r16unorm
    case r32float
    case r32sint
    case r32uint
    case r8sint
    case r8snorm
    case r8uint
    case r8unorm
    case rg11b10ufloat
    case rg16float
    case rg16sint
    case rg16snorm
    case rg16uint
    case rg16unorm
    case rg32float
    case rg32sint
    case rg32uint
    case rg8sint
    case rg8snorm
    case rg8uint
    case rg8unorm
    case rgb10a2uint
    case rgb10a2unorm
    case rgba16float
    case rgba16sint
    case rgba16snorm
    case rgba16uint
    case rgba16unorm
    case rgba32float
    case rgba32sint
    case rgba32uint
    case rgba8sint
    case rgba8snorm
    case rgba8uint
    case rgba8unorm
}

/// WGSL::InterpolationType.
public enum InterpolationType: UInt8, Hashable, Sendable {
    case flat
    case linear
    case perspective
}

/// WGSL::InterpolationSampling.
public enum InterpolationSampling: UInt8, Hashable, Sendable {
    case center
    case centroid
    case either
    case first
    case sample
}

/// WGSL::ShaderStage, in the C++ case order; raw values are the WGPUShaderStage bits.
public enum ShaderStage: UInt8, Hashable, Sendable {
    case compute = 4
    case fragment = 2
    case vertex = 1
}

/// A set of shader stages: a binding's visibility.
public struct ShaderStages: OptionSet, Hashable, Sendable {
    /// The WGPUShaderStage bits.
    public let rawValue: UInt8

    /// Wraps WGPUShaderStage bits.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The set containing only `stage`.
    public init(_ stage: ShaderStage) { rawValue = stage.rawValue }

    /// The vertex stage.
    public static let vertex = ShaderStages(.vertex)
    /// The fragment stage.
    public static let fragment = ShaderStages(.fragment)
    /// The compute stage.
    public static let compute = ShaderStages(.compute)
}

/// WGSL::SeverityControl, in the C++ case order.
@_spi(Testing)
public enum SeverityControl: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case error
    case info
    case off
    case warning
}

/// WGSL::TriggeringRule, in the C++ case order.
@_spi(Testing)
public enum TriggeringRule: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case derivativeUniformity
    case subgroupUniformity
}

/// WGSL::Builtin, in the C++ case order.
@_spi(Testing)
public enum Builtin: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case clipDistances
    case fragDepth
    case frontFacing
    case globalInvocationId
    case instanceIndex
    case localInvocationId
    case localInvocationIndex
    case numSubgroups
    case numWorkgroups
    case position
    case primitiveIndex
    case sampleIndex
    case sampleMask
    case subgroupId
    case subgroupInvocationId
    case subgroupSize
    case vertexIndex
    case workgroupId
}

/// WGSL::Extension, in the C++ case order.
@_spi(Testing)
public enum Extension: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case clipDistances = 1
    case f16 = 2
    case primitiveIndex = 4
    case subgroups = 8
}

/// WTF::OptionSet<Extension>: the extensions a module enables.
@_spi(Testing)
public struct Extensions: OptionSet, BitwiseCopyable, Hashable, Sendable {
    /// The ENUM_Extension bits.
    @_spi(Testing)
    public let rawValue: UInt8

    /// Wraps ENUM_Extension bits.
    @_spi(Testing)
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The set containing only `value`.
    @_spi(Testing)
    public init(_ value: Extension) { rawValue = value.rawValue }

    /// clip_distances.
    @_spi(Testing)
    public static let clipDistances = Extensions(.clipDistances)
    /// f16.
    @_spi(Testing)
    public static let f16 = Extensions(.f16)
    /// primitive_index.
    @_spi(Testing)
    public static let primitiveIndex = Extensions(.primitiveIndex)
    /// subgroups.
    @_spi(Testing)
    public static let subgroups = Extensions(.subgroups)
}

/// WGSL::LanguageFeature, in the C++ case order.
@_spi(Testing)
public enum LanguageFeature: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case packed4x8IntegerDotProduct = 1
    case pointerCompositeAccess = 2
    case readonlyAndReadwriteStorageTextures = 4
    case subgroupId = 32
    case subgroupUniformity = 64
    case textureFormatsTier1 = 8
    case unrestrictedPointerParameters = 16
}

/// WTF::OptionSet<LanguageFeature>: the language features a module requires.
@_spi(Testing)
public struct LanguageFeatures: OptionSet, BitwiseCopyable, Hashable, Sendable {
    /// The ENUM_LanguageFeature bits.
    @_spi(Testing)
    public let rawValue: UInt8

    /// Wraps ENUM_LanguageFeature bits.
    @_spi(Testing)
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The set containing only `value`.
    @_spi(Testing)
    public init(_ value: LanguageFeature) { rawValue = value.rawValue }

    /// packed_4x8_integer_dot_product.
    @_spi(Testing)
    public static let packed4x8IntegerDotProduct = LanguageFeatures(.packed4x8IntegerDotProduct)
    /// pointer_composite_access.
    @_spi(Testing)
    public static let pointerCompositeAccess = LanguageFeatures(.pointerCompositeAccess)
    /// readonly_and_readwrite_storage_textures.
    @_spi(Testing)
    public static let readonlyAndReadwriteStorageTextures = LanguageFeatures(.readonlyAndReadwriteStorageTextures)
    /// subgroup_id.
    @_spi(Testing)
    public static let subgroupId = LanguageFeatures(.subgroupId)
    /// subgroup_uniformity.
    @_spi(Testing)
    public static let subgroupUniformity = LanguageFeatures(.subgroupUniformity)
    /// texture_formats_tier1.
    @_spi(Testing)
    public static let textureFormatsTier1 = LanguageFeatures(.textureFormatsTier1)
    /// unrestricted_pointer_parameters.
    @_spi(Testing)
    public static let unrestrictedPointerParameters = LanguageFeatures(.unrestrictedPointerParameters)
}

/// C++ toString(AddressSpace): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: AddressSpace) -> StaticString {
    switch value {
    case .function: "function"
    case .handle: "handle"
    case .private: "private"
    case .storage: "storage"
    case .uniform: "uniform"
    case .workgroup: "workgroup"
    }
}

/// C++ parseAddressSpace: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseAddressSpace(_ string: some Collection<UInt16>) -> AddressSpace? {
    tryGet(AddressSpace.allCases, string, toString)
}

/// C++ toString(AccessMode): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: AccessMode) -> StaticString {
    switch value {
    case .read: "read"
    case .readWrite: "read_write"
    case .write: "write"
    }
}

/// C++ parseAccessMode: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseAccessMode(_ string: some Collection<UInt16>) -> AccessMode? {
    tryGet(AccessMode.allCases, string, toString)
}

/// C++ toString(TexelFormat): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: TexelFormat) -> StaticString {
    switch value {
    case .bgra8unorm: "bgra8unorm"
    case .r16float: "r16float"
    case .r16sint: "r16sint"
    case .r16snorm: "r16snorm"
    case .r16uint: "r16uint"
    case .r16unorm: "r16unorm"
    case .r32float: "r32float"
    case .r32sint: "r32sint"
    case .r32uint: "r32uint"
    case .r8sint: "r8sint"
    case .r8snorm: "r8snorm"
    case .r8uint: "r8uint"
    case .r8unorm: "r8unorm"
    case .rg11b10ufloat: "rg11b10ufloat"
    case .rg16float: "rg16float"
    case .rg16sint: "rg16sint"
    case .rg16snorm: "rg16snorm"
    case .rg16uint: "rg16uint"
    case .rg16unorm: "rg16unorm"
    case .rg32float: "rg32float"
    case .rg32sint: "rg32sint"
    case .rg32uint: "rg32uint"
    case .rg8sint: "rg8sint"
    case .rg8snorm: "rg8snorm"
    case .rg8uint: "rg8uint"
    case .rg8unorm: "rg8unorm"
    case .rgb10a2uint: "rgb10a2uint"
    case .rgb10a2unorm: "rgb10a2unorm"
    case .rgba16float: "rgba16float"
    case .rgba16sint: "rgba16sint"
    case .rgba16snorm: "rgba16snorm"
    case .rgba16uint: "rgba16uint"
    case .rgba16unorm: "rgba16unorm"
    case .rgba32float: "rgba32float"
    case .rgba32sint: "rgba32sint"
    case .rgba32uint: "rgba32uint"
    case .rgba8sint: "rgba8sint"
    case .rgba8snorm: "rgba8snorm"
    case .rgba8uint: "rgba8uint"
    case .rgba8unorm: "rgba8unorm"
    }
}

/// C++ parseTexelFormat: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseTexelFormat(_ string: some Collection<UInt16>) -> TexelFormat? {
    tryGet(TexelFormat.allCases, string, toString)
}

/// C++ toString(InterpolationType): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: InterpolationType) -> StaticString {
    switch value {
    case .flat: "flat"
    case .linear: "linear"
    case .perspective: "perspective"
    }
}

/// C++ parseInterpolationType: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseInterpolationType(_ string: some Collection<UInt16>) -> InterpolationType? {
    tryGet(interpolationTypeParseTable, string, toString)
}

/// C++ toString(InterpolationSampling): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: InterpolationSampling) -> StaticString {
    switch value {
    case .center: "center"
    case .centroid: "centroid"
    case .either: "either"
    case .first: "first"
    case .sample: "sample"
    }
}

/// C++ parseInterpolationSampling: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseInterpolationSampling(_ string: some Collection<UInt16>) -> InterpolationSampling? {
    tryGet(interpolationSamplingParseTable, string, toString)
}

/// C++ toString(ShaderStage): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: ShaderStage) -> StaticString {
    switch value {
    case .compute: "compute"
    case .fragment: "fragment"
    case .vertex: "vertex"
    }
}

/// C++ parseShaderStage: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseShaderStage(_ string: some Collection<UInt16>) -> ShaderStage? {
    tryGet(shaderStageParseTable, string, toString)
}

/// C++ toString(SeverityControl): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: SeverityControl) -> StaticString {
    switch value {
    case .error: "error"
    case .info: "info"
    case .off: "off"
    case .warning: "warning"
    }
}

/// C++ parseSeverityControl: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseSeverityControl(_ string: some Collection<UInt16>) -> SeverityControl? {
    tryGet(SeverityControl.allCases, string, toString)
}

/// C++ toString(TriggeringRule): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: TriggeringRule) -> StaticString {
    switch value {
    case .derivativeUniformity: "derivative_uniformity"
    case .subgroupUniformity: "subgroup_uniformity"
    }
}

/// C++ parseTriggeringRule: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseTriggeringRule(_ string: some Collection<UInt16>) -> TriggeringRule? {
    tryGet(TriggeringRule.allCases, string, toString)
}

/// C++ toString(Builtin): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: Builtin) -> StaticString {
    switch value {
    case .clipDistances: "clip_distances"
    case .fragDepth: "frag_depth"
    case .frontFacing: "front_facing"
    case .globalInvocationId: "global_invocation_id"
    case .instanceIndex: "instance_index"
    case .localInvocationId: "local_invocation_id"
    case .localInvocationIndex: "local_invocation_index"
    case .numSubgroups: "num_subgroups"
    case .numWorkgroups: "num_workgroups"
    case .position: "position"
    case .primitiveIndex: "primitive_index"
    case .sampleIndex: "sample_index"
    case .sampleMask: "sample_mask"
    case .subgroupId: "subgroup_id"
    case .subgroupInvocationId: "subgroup_invocation_id"
    case .subgroupSize: "subgroup_size"
    case .vertexIndex: "vertex_index"
    case .workgroupId: "workgroup_id"
    }
}

/// C++ parseBuiltin: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseBuiltin(_ string: some Collection<UInt16>) -> Builtin? {
    tryGet(Builtin.allCases, string, toString)
}

/// C++ toString(Extension): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: Extension) -> StaticString {
    switch value {
    case .clipDistances: "clip_distances"
    case .f16: "f16"
    case .primitiveIndex: "primitive_index"
    case .subgroups: "subgroups"
    }
}

/// C++ parseExtension: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseExtension(_ string: some Collection<UInt16>) -> Extension? {
    tryGet(Extension.allCases, string, toString)
}

/// C++ toString(LanguageFeature): the WGSL spelling.
@_spi(Testing)
public func toString(_ value: LanguageFeature) -> StaticString {
    switch value {
    case .packed4x8IntegerDotProduct: "packed_4x8_integer_dot_product"
    case .pointerCompositeAccess: "pointer_composite_access"
    case .readonlyAndReadwriteStorageTextures: "readonly_and_readwrite_storage_textures"
    case .subgroupId: "subgroup_id"
    case .subgroupUniformity: "subgroup_uniformity"
    case .textureFormatsTier1: "texture_formats_tier1"
    case .unrestrictedPointerParameters: "unrestricted_pointer_parameters"
    }
}

/// C++ parseLanguageFeature: the case spelled exactly `string`, or nil.
@_spi(Testing)
public func parseLanguageFeature(_ string: some Collection<UInt16>) -> LanguageFeature? {
    tryGet(LanguageFeature.allCases, string, toString)
}

/// C++ defaultAccessModeForAddressSpace.
@_spi(Testing)
public func defaultAccessModeForAddressSpace(_ addressSpace: AddressSpace) -> AccessMode {
    // Default access mode based on address space
    // https://www.w3.org/TR/WGSL/#address-space
    switch addressSpace {
    case .function, .private, .workgroup:
        .readWrite
    case .uniform, .storage, .handle:
        .read
    }
}

private let interpolationTypeParseTable: [InterpolationType] = [.flat, .linear, .perspective]
private let interpolationSamplingParseTable: [InterpolationSampling] = [.center, .centroid, .either, .first, .sample]
private let shaderStageParseTable: [ShaderStage] = [.compute, .fragment, .vertex]

// SortedArrayMap<ComparableASCIILiteral, Value>::tryGet: exact code-unit equality with one entry's spelling.
private func tryGet<Value>(_ values: [Value], _ string: some Collection<UInt16>, _ toString: (Value) -> StaticString) -> Value? {
    for value in values where equal(string, toString(value)) {
        return value
    }
    return nil
}

private func equal(_ string: some Collection<UInt16>, _ literal: StaticString) -> Bool {
    guard string.count == literal.utf8CodeUnitCount else {
        return false
    }
    var index = string.startIndex
    for byte in literal.description.utf8 {
        guard string[index] == UInt16(byte) else {
            return false
        }
        index = string.index(after: index)
    }
    return true
}

extension TexelFormat: BitwiseCopyable {}
extension InterpolationType: BitwiseCopyable {}
extension InterpolationSampling: BitwiseCopyable {}
extension ShaderStage: BitwiseCopyable {}
extension ShaderStages: BitwiseCopyable {}
