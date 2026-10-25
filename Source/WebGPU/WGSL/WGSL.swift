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

// MARK: - Source text and names

/// A shader's source as code units, exactly as WebKit stores it: Latin-1 when the WTF::String is 8-bit, UTF-16 otherwise.
///
/// The representation is preserved because the C++ lexer is instantiated per representation (Parser.cpp:331-351). Diagnostics count these
/// code units.
public struct SourceText: Sendable {
    enum Storage: Sendable {
        case latin1(ContiguousArray<UInt8>)
        case utf16(ContiguousArray<UInt16>)
    }
    let storage: Storage

    /// Takes ownership; no copy.
    ///
    /// WebGPU's bridge fills the array from the WTF::String with one memcpy.
    public init(latin1 codeUnits: ContiguousArray<UInt8>) { storage = .latin1(codeUnits) }

    /// Takes ownership of 16-bit code units; no copy.
    public init(utf16 codeUnits: ContiguousArray<UInt16>) { storage = .utf16(codeUnits) }

    /// The WTF::String::fromUTF8 representation of `string`: 8-bit iff all ASCII.
    public init(_ string: String) {
        if string.utf8.allSatisfy({ $0 < 0x80 }) {
            storage = .latin1(ContiguousArray(string.utf8))
        } else {
            storage = .utf16(ContiguousArray(string.utf16))
        }
    }

    /// WTF::String::fromUTF8WithLatin1Fallback: all ASCII becomes 8-bit, other valid UTF-8 becomes
    /// 16-bit (never down-converted), invalid UTF-8 becomes the bytes as Latin-1. wgslc, wgslfuzz and
    /// the tests read shader files with this.
    public init(decodingUTF8WithLatin1Fallback bytes: [UInt8]) {
        if bytes.allSatisfy({ $0 < 0x80 }) {
            storage = .latin1(ContiguousArray(bytes))
        } else if let decoded = String(validating: bytes, as: UTF8.self) {
            storage = .utf16(ContiguousArray(decoded.utf16))
        } else {
            storage = .latin1(ContiguousArray(bytes))
        }
    }

    /// Whether the source is held as 8-bit (Latin-1) code units.
    public var isLatin1: Bool {
        if case .latin1 = storage {
            return true
        }
        return false
    }

    /// The number of code units.
    public var count: Int {
        switch storage {
        case .latin1(let codeUnits): codeUnits.count
        case .utf16(let codeUnits): codeUnits.count
        }
    }
}

/// A name crossing the API: an entry point, an override key, a specialization constant key.
///
/// Compares and hashes by UTF-16 code unit, as WTF::String does (8-bit and 16-bit alike), never by Unicode canonical equivalence like
/// Swift.String.
public struct Name: Hashable, Sendable, CustomStringConvertible {
    /// The name's UTF-16 code units.
    public let utf16: ContiguousArray<UInt16>

    /// Wraps UTF-16 code units.
    public init(utf16: ContiguousArray<UInt16>) { self.utf16 = utf16 }

    /// Widens Latin-1 code units.
    public init(latin1: ContiguousArray<UInt8>) { utf16 = ContiguousArray(latin1.lazy.map { UInt16($0) }) }

    /// The UTF-16 code units of `string`.
    public init(_ string: String) { utf16 = ContiguousArray(string.utf16) }

    /// The name decoded for tools and tests; a lone surrogate decodes as U+FFFD.
    public var description: String { String(decoding: utf16, as: UTF16.self) }

    /// Hashes the length and the code units, four to a word (the prepare passes look each entry point up by name).
    public func hash(into hasher: inout Hasher) {
        let count = utf16.count
        hasher.combine(count)
        var index = 0
        while count &- index >= 4 {
            hasher.combine(
                UInt64(utf16[index]) | UInt64(utf16[index &+ 1]) &<< 16 | UInt64(utf16[index &+ 2]) &<< 32
                    | UInt64(utf16[index &+ 3]) &<< 48
            )
            index &+= 4
        }
        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while index < count {
            tail |= UInt64(utf16[index]) &<< shift
            shift &+= 16
            index &+= 1
        }
        hasher.combine(tail)
    }
}

// MARK: - Configuration

/// The device features the compiler consults; raw values match WGSL::Feature in WGSLAPI.h.
public struct Features: OptionSet, Hashable, Sendable {
    /// The feature bits (ENUM_Extension values).
    public let rawValue: UInt8

    /// Wraps feature bits.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The clip-distances feature.
    public static let clipDistances = Features(rawValue: 1 << 0)
    /// The shader-f16 feature.
    public static let shaderF16 = Features(rawValue: 1 << 1)
    /// The primitive-index feature.
    public static let primitiveIndex = Features(rawValue: 1 << 2)
    /// The subgroups feature.
    public static let subgroups = Features(rawValue: 1 << 3)

    /// The features among WebGPU feature names: the compiler consults only these four.
    public init(names: some Sequence<String>) {
        var features: Features = []
        for name in names {
            let key = Name(name)
            if key == Name("clip-distances") {
                features.insert(.clipDistances)
            } else if key == Name("shader-f16") {
                features.insert(.shaderF16)
            } else if key == Name("primitive-index") {
                features.insert(.primitiveIndex)
            } else if key == Name("subgroups") {
                features.insert(.subgroups)
            }
        }
        self = features
    }
}

/// The device limits and features a shader module is checked against (WGSL.h Configuration).
public struct Configuration: Sendable {
    /// Limit on buffers plus vertex buffers for the vertex stage.
    public var maxBuffersPlusVertexBuffersForVertexStage: UInt32
    /// Limit on buffers for the fragment stage.
    public var maxBuffersForFragmentStage: UInt32
    /// Limit on buffers for the compute stage.
    public var maxBuffersForComputeStage: UInt32
    /// Limit on the combined size of workgroup variables.
    public var maximumCombinedWorkgroupVariablesSize: UInt32
    /// The features the device supports.
    public var supportedFeatures: Features
    /// The XID classification the lexer uses for non-ASCII scalars.
    public var identifierCharacterClasses: IdentifierCharacterClasses

    /// The C++ defaults, and the standard library's XID tables.
    public init(
        maxBuffersPlusVertexBuffersForVertexStage: UInt32 = 8,
        maxBuffersForFragmentStage: UInt32 = 8,
        maxBuffersForComputeStage: UInt32 = 8,
        maximumCombinedWorkgroupVariablesSize: UInt32 = 16_384,
        supportedFeatures: Features = [],
        identifierCharacterClasses: IdentifierCharacterClasses = .standardLibrary
    ) {
        self.maxBuffersPlusVertexBuffersForVertexStage = maxBuffersPlusVertexBuffersForVertexStage
        self.maxBuffersForFragmentStage = maxBuffersForFragmentStage
        self.maxBuffersForComputeStage = maxBuffersForComputeStage
        self.maximumCombinedWorkgroupVariablesSize = maximumCombinedWorkgroupVariablesSize
        self.supportedFeatures = supportedFeatures
        self.identifierCharacterClasses = identifierCharacterClasses
    }
}

/// XID_Start / XID_Continue classification of non-ASCII scalars for the lexer (DEV-20).
///
/// WebGPU passes ICU's (identical to the C++ on every OS); tools and tests without ICU use the Swift runtime's tables.
public struct IdentifierCharacterClasses: Sendable {
    enum Tables: Sendable {
        case standardLibrary
        case ranges(xidStart: [UInt32], xidContinue: [UInt32])
    }
    let tables: Tables

    /// Sorted, disjoint, half-open [start, end) scalar ranges, flattened; wgslFatal if malformed.
    public init(xidStartRanges: [UInt32], xidContinueRanges: [UInt32]) {
        guard Self.isWellFormed(xidStartRanges), Self.isWellFormed(xidContinueRanges) else {
            wgslFatal("malformed identifier character class ranges", cppSite: "Lexer.cpp:49")
        }
        tables = .ranges(xidStart: xidStartRanges, xidContinue: xidContinueRanges)
    }

    private init(tables: Tables) { self.tables = tables }

    /// Unicode.Scalar.Properties per scalar.
    public static let standardLibrary = IdentifierCharacterClasses(tables: .standardLibrary)

    func isXIDStart(_ scalar: UInt32) -> Bool {
        switch tables {
        case .standardLibrary:
            Self.standardLibraryIsXIDStart(scalar)
        case .ranges(let xidStart, _):
            Self.ranges(xidStart, contain: scalar)
        }
    }

    func isXIDContinue(_ scalar: UInt32) -> Bool {
        switch tables {
        case .standardLibrary:
            Self.standardLibraryIsXIDContinue(scalar)
        case .ranges(_, let xidContinue):
            Self.ranges(xidContinue, contain: scalar)
        }
    }

    // Not inlined: Unicode.Scalar.Properties is resilient, and a frame that holds one is sized at run time on every call
    // (inlined into the lexer, it cost a metadata lookup per token).
    @inline(never)
    private static func standardLibraryIsXIDStart(_ scalar: UInt32) -> Bool {
        // DEV-20: the Swift runtime's XID_Start table stands in for ICU's.
        Unicode.Scalar(scalar)?.properties.isXIDStart ?? false
    }

    @inline(never)
    private static func standardLibraryIsXIDContinue(_ scalar: UInt32) -> Bool {
        // DEV-20: the Swift runtime's XID_Continue table stands in for ICU's.
        Unicode.Scalar(scalar)?.properties.isXIDContinue ?? false
    }

    /// Whether `ranges` is what the initializer accepts.
    @_spi(Testing)
    public static func isWellFormed(_ ranges: [UInt32]) -> Bool {
        guard ranges.count % 2 == 0 else {
            return false
        }
        var index = 0
        while index < ranges.count {
            guard ranges[index] < ranges[index + 1] else {
                return false
            }
            if index > 0 {
                guard ranges[index - 1] <= ranges[index] else {
                    return false
                }
            }
            index += 2
        }
        return true
    }

    private static func ranges(_ ranges: [UInt32], contain scalar: UInt32) -> Bool {
        var low = 0
        var high = ranges.count / 2
        while low < high {
            let middle = low + (high - low) / 2
            if scalar < ranges[2 * middle] {
                high = middle
            } else if scalar >= ranges[2 * middle + 1] {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}

/// What code generation depends on besides the module and the layout.
public struct DeviceState: Hashable, Sendable {
    /// The Apple GPU family the MSL targets.
    public var appleGPUFamily: UInt32
    /// Whether Metal shader validation is enabled.
    public var shaderValidationEnabled: Bool

    /// The C++ defaults.
    public init(appleGPUFamily: UInt32 = 4, shaderValidationEnabled: Bool = false) {
        self.appleGPUFamily = appleGPUFamily
        self.shaderValidationEnabled = shaderValidationEnabled
    }
}

// MARK: - Binding layouts

/// WGSL::BufferBindingType.
public enum BufferBindingType: UInt8, Hashable, Sendable {
    case uniform
    case storage
    case readOnlyStorage
}

/// WGSL::SamplerBindingType.
public enum SamplerBindingType: UInt8, Hashable, Sendable {
    case filtering
    case nonFiltering
    case comparison
}

/// WGSL::TextureSampleType.
public enum TextureSampleType: UInt8, Hashable, Sendable {
    case float
    case unfilterableFloat
    case depth
    case signedInt
    case unsignedInt
}

/// WGSL::TextureViewDimension.
public enum TextureViewDimension: UInt8, Hashable, Sendable {
    case oneDimensional
    case twoDimensional
    case twoDimensionalArray
    case cube
    case cubeArray
    case threeDimensional
}

/// WGSL::StorageTextureAccess.
public enum StorageTextureAccess: UInt8, Hashable, Sendable {
    case writeOnly
    case readOnly
    case readWrite
}

/// WGSL::BufferBindingLayout.
public struct BufferBindingLayout: Hashable, Sendable {
    /// The buffer binding type.
    public var type: BufferBindingType
    /// Whether the binding has a dynamic offset.
    public var hasDynamicOffset: Bool
    /// The minimum binding size; prepare() writes it back for explicit layouts.
    public var minBindingSize: UInt64

    /// Memberwise.
    public init(type: BufferBindingType, hasDynamicOffset: Bool, minBindingSize: UInt64) {
        self.type = type
        self.hasDynamicOffset = hasDynamicOffset
        self.minBindingSize = minBindingSize
    }
}

/// WGSL::TextureBindingLayout.
public struct TextureBindingLayout: Hashable, Sendable {
    /// The sample type.
    public var sampleType: TextureSampleType
    /// The view dimension.
    public var viewDimension: TextureViewDimension
    /// Whether the texture is multisampled.
    public var multisampled: Bool

    /// Memberwise.
    public init(sampleType: TextureSampleType, viewDimension: TextureViewDimension, multisampled: Bool) {
        self.sampleType = sampleType
        self.viewDimension = viewDimension
        self.multisampled = multisampled
    }
}

/// WGSL::StorageTextureBindingLayout.
public struct StorageTextureBindingLayout: Hashable, Sendable {
    /// The access mode.
    public var access: StorageTextureAccess
    /// The texel format.
    public var format: TexelFormat
    /// The view dimension.
    public var viewDimension: TextureViewDimension

    /// Memberwise.
    public init(access: StorageTextureAccess, format: TexelFormat, viewDimension: TextureViewDimension) {
        self.access = access
        self.format = format
        self.viewDimension = viewDimension
    }
}

/// WGSL::BindingMember.
public enum BindingMember: Hashable, Sendable {
    case buffer(BufferBindingLayout)
    case sampler(SamplerBindingType)
    case texture(TextureBindingLayout)
    case storageTexture(StorageTextureBindingLayout)
    case externalTexture
}

/// The per-stage argument-buffer slots WebGPU assigned to an entry of an explicit layout.
public struct StageSlots: Hashable, Sendable {
    /// The argument buffer index.
    public var argumentBufferIndex: UInt32?
    /// The argument buffer index of the size.
    public var argumentBufferSizeIndex: UInt32?
    /// The dynamic offset slot.
    public var bufferDynamicOffset: UInt32?

    /// Memberwise; every slot defaults to absent.
    public init(argumentBufferIndex: UInt32? = nil, argumentBufferSizeIndex: UInt32? = nil, bufferDynamicOffset: UInt32? = nil) {
        self.argumentBufferIndex = argumentBufferIndex
        self.argumentBufferSizeIndex = argumentBufferSizeIndex
        self.bufferDynamicOffset = bufferDynamicOffset
    }
}

/// An entry of an explicit layout as the compiler reads it.
///
/// There is deliberately no group, web binding or name: WebGPU leaves those uninitialized in an input layout.
public struct ExplicitBindGroupLayoutEntry: Hashable, Sendable {
    /// The binding number.
    public var binding: UInt32
    /// The stages that see the binding.
    public var visibility: ShaderStages
    /// The kind of resource and its layout.
    public var bindingMember: BindingMember
    /// The vertex stage slots.
    public var vertex: StageSlots
    /// The fragment stage slots.
    public var fragment: StageSlots
    /// The compute stage slots.
    public var compute: StageSlots

    /// Memberwise.
    public init(
        binding: UInt32,
        visibility: ShaderStages,
        bindingMember: BindingMember,
        vertex: StageSlots = StageSlots(),
        fragment: StageSlots = StageSlots(),
        compute: StageSlots = StageSlots()
    ) {
        self.binding = binding
        self.visibility = visibility
        self.bindingMember = bindingMember
        self.vertex = vertex
        self.fragment = fragment
        self.compute = compute
    }
}

/// How prepare() reads an explicit pipeline layout and writes minBindingSize back into it.
///
/// A stateless witness rather than a protocol on the layout itself, so that WebGPU's bridge can let the compiler work directly on the C++
/// WGSL::PipelineLayout (a public type) from a file that imports this module internally.
public protocol PipelineLayoutAccess {
    /// The layout type the witness reads and writes.
    associatedtype Layout

    /// The number of bind group layouts.
    static func bindGroupLayoutCount(of layout: borrowing Layout) -> Int

    /// The number of entries of bind group layout `group`.
    static func entryCount(of layout: borrowing Layout, bindGroupLayout group: Int) -> Int

    /// Entry `index` of bind group layout `group`.
    static func entry(of layout: borrowing Layout, bindGroupLayout group: Int, index: Int) -> ExplicitBindGroupLayoutEntry

    /// Must store `size` as that entry's minBindingSize. prepare() reads the entry back and traps if it did not.
    static func setMinBindingSize(_ size: UInt64, in layout: inout Layout, bindGroupLayout group: Int, index: Int)
}

/// An entry of a complete layout as a value: a default layout the compiler computed, or an explicit
/// layout supplied by a tool or a test.
public struct BindGroupLayoutEntry: Hashable, Sendable {
    /// The binding number.
    public var binding: UInt32
    /// The binding number WebGPU exposes.
    public var webBinding: UInt32
    /// The stages that see the binding.
    public var visibility: ShaderStages
    /// The kind of resource and its layout.
    public var bindingMember: BindingMember
    /// The variable's name.
    public var name: String
    /// The vertex stage slots.
    public var vertex: StageSlots
    /// The fragment stage slots.
    public var fragment: StageSlots
    /// The compute stage slots.
    public var compute: StageSlots

    /// Memberwise.
    public init(
        binding: UInt32,
        webBinding: UInt32,
        visibility: ShaderStages,
        bindingMember: BindingMember,
        name: String,
        vertex: StageSlots = StageSlots(),
        fragment: StageSlots = StageSlots(),
        compute: StageSlots = StageSlots()
    ) {
        self.binding = binding
        self.webBinding = webBinding
        self.visibility = visibility
        self.bindingMember = bindingMember
        self.name = name
        self.vertex = vertex
        self.fragment = fragment
        self.compute = compute
    }
}

/// WGSL::BindGroupLayout.
public struct BindGroupLayout: Hashable, Sendable {
    /// The group number.
    public var group: UInt32
    /// The entries.
    public var entries: [BindGroupLayoutEntry]

    /// Memberwise.
    public init(group: UInt32, entries: [BindGroupLayoutEntry]) {
        self.group = group
        self.entries = entries
    }
}

/// WGSL::PipelineLayout.
public struct PipelineLayout: Hashable, Sendable {
    /// The bind group layouts.
    public var bindGroupLayouts: [BindGroupLayout]

    /// Memberwise.
    public init(bindGroupLayouts: [BindGroupLayout] = []) { self.bindGroupLayouts = bindGroupLayouts }

    /// The value-layout witness (tools, tests).
    public enum Access: PipelineLayoutAccess {
        /// The number of bind group layouts.
        public static func bindGroupLayoutCount(of layout: borrowing PipelineLayout) -> Int { layout.bindGroupLayouts.count }

        /// The number of entries of bind group layout `group`.
        public static func entryCount(of layout: borrowing PipelineLayout, bindGroupLayout group: Int) -> Int {
            layout.bindGroupLayouts[group].entries.count
        }

        /// Entry `index` of bind group layout `group`, without its group, web binding and name.
        public static func entry(
            of layout: borrowing PipelineLayout,
            bindGroupLayout group: Int,
            index: Int
        ) -> ExplicitBindGroupLayoutEntry {
            let entry = layout.bindGroupLayouts[group].entries[index]
            return ExplicitBindGroupLayoutEntry(
                binding: entry.binding,
                visibility: entry.visibility,
                bindingMember: entry.bindingMember,
                vertex: entry.vertex,
                fragment: entry.fragment,
                compute: entry.compute
            )
        }

        /// Stores `size` into a buffer entry; wgslFatal on a non-buffer entry.
        public static func setMinBindingSize(_ size: UInt64, in layout: inout PipelineLayout, bindGroupLayout group: Int, index: Int) {
            guard case .buffer(var buffer) = layout.bindGroupLayouts[group].entries[index].bindingMember else {
                wgslFatal("minBindingSize written back to a non-buffer entry", cppSite: "GlobalVariableRewriter.cpp:2422")
            }
            buffer.minBindingSize = size
            layout.bindGroupLayouts[group].entries[index].bindingMember = .buffer(buffer)
        }
    }
}

// MARK: - Reflection computed at check time

/// The scalar of an IO location's type.
public enum IOScalar: Hashable, Sendable {
    case i32, u32, f16, f32, bool, other
}

/// `missing`: no inferred type.
///
/// `other`: neither a scalar nor a vector.
public enum IOType: Hashable, Sendable {
    case missing
    case other
    case scalar(IOScalar)
    case vector(IOScalar, size: UInt8)
}

/// AST::Interpolation.
public struct Interpolation: Hashable, Sendable {
    /// The interpolation type.
    public var type: InterpolationType
    /// The interpolation sampling.
    public var sampling: InterpolationSampling

    /// Memberwise.
    public init(type: InterpolationType, sampling: InterpolationSampling) {
        self.type = type
        self.sampling = sampling
    }
}

/// A user-defined IO location of an entry point.
public struct IOLocation: Hashable, Sendable {
    /// The @location value.
    public var location: UInt32
    /// The location's type.
    public var type: IOType
    /// The @interpolate attribute, if any.
    public var interpolation: Interpolation?

    /// Memberwise.
    public init(location: UInt32, type: IOType, interpolation: Interpolation? = nil) {
        self.location = location
        self.type = type
        self.interpolation = interpolation
    }
}

/// The IO reflection of an entry point that ShaderModule.mm reads, each list in the order ShaderModule.mm inserts it into its maps.
public struct EntryPointIO: Hashable, Sendable {
    /// The entry point's source name.
    public var name: Name
    /// The entry point's stage.
    public var stage: ShaderStage
    /// The vertex stage inputs.
    public var stageIn: [IOLocation]
    /// The vertex stage outputs.
    public var vertexOutputs: [IOLocation]?
    /// The fragment stage inputs.
    public var fragmentInputs: [IOLocation]
    /// The fragment stage outputs.
    public var fragmentOutputs: [IOLocation]?
    /// Whether @builtin(front_facing) is an input.
    public var usesFrontFacingInInput: Bool
    /// Whether @builtin(sample_index) is an input.
    public var usesSampleIndexInInput: Bool
    /// Whether @builtin(sample_mask) is an input.
    public var usesSampleMaskInInput: Bool
    /// Whether @builtin(sample_mask) is an output.
    public var usesSampleMaskInOutput: Bool
    /// Whether @builtin(frag_depth) is an output.
    public var usesFragDepth: Bool
    /// Whether @builtin(primitive_index) is an input.
    public var usesPrimitiveIndexInInput: Bool
    /// Whether @builtin(subgroup_invocation_id) is an input.
    public var usesSubgroupInvocationIdInInput: Bool
    /// Whether @builtin(subgroup_size) is an input.
    public var usesSubgroupSizeInInput: Bool
    /// The size of the @builtin(clip_distances) array.
    public var clipDistancesCount: UInt32

    /// An entry point with no IO.
    public init(name: Name, stage: ShaderStage) {
        self.name = name
        self.stage = stage
        stageIn = []
        vertexOutputs = nil
        fragmentInputs = []
        fragmentOutputs = nil
        usesFrontFacingInInput = false
        usesSampleIndexInInput = false
        usesSampleMaskInInput = false
        usesSampleMaskInOutput = false
        usesFragDepth = false
        usesPrimitiveIndexInInput = false
        usesSubgroupInvocationIdInInput = false
        usesSubgroupSizeInInput = false
        clipDistancesCount = 0
    }
}

// MARK: - Pipeline-time reflection

/// Reflection::SpecializationConstantType.
public enum SpecializationConstantType: UInt8, Hashable, Sendable {
    case boolean
    case float
    case int
    case unsigned
    case half
}

/// An override the prepared entry point uses.
public struct SpecializationConstant: Hashable, Sendable {
    /// The override's @id as a decimal string, else its source name.
    public let key: Name
    /// The override's mangled name.
    public let mangledName: String
    /// The override's type.
    public let type: SpecializationConstantType
}

/// The stage-specific part of an entry point's information (C++ `Reflection::EntryPointInformation::typedEntryPoint`).
///
/// A compute function without @workgroup_size (which staticCheck accepts) is `.vertex(invariantIsPresent: false)`, the default-constructed
/// Variant; ComputePipeline.mm rejects it.
public enum TypedEntryPoint: Hashable, Sendable {
    case vertex(invariantIsPresent: Bool)
    case fragment
    case compute
}

/// Reflection::EntryPointInformation; it cannot be forged outside the module.
public struct EntryPointInformation: Hashable, Sendable {
    /// The entry point's source name.
    public let originalName: Name
    /// The entry point's mangled name.
    public let mangledName: String
    /// The entry point's stage.
    public let stage: ShaderStage
    /// The stage-specific information.
    public let typedEntryPoint: TypedEntryPoint
    /// Present iff the entry point was prepared without an explicit layout.
    public let defaultLayout: PipelineLayout?
    /// In the order prepare() first saw each override used.
    public let specializationConstants: [SpecializationConstant]
    /// The total size of the workgroup variables.
    public let sizeForWorkgroupVariables: UInt64
    /// The number of bindings.
    public let bindingCount: UInt64
    /// Whether @invariant is used.
    public let usesInvariant: Bool
}

/// A GPUProgrammableStage constant before conversion.
public struct PipelineConstant: Hashable, Sendable {
    /// The override key.
    public var key: Name
    /// The value as WebGPU passes it.
    public var value: Double

    /// Memberwise.
    public init(key: Name, value: Double) {
        self.key = key
        self.value = value
    }
}

/// A scalar ConstantValue, bit-exact. f16 is its binary16 bit pattern (no Swift Float16: it does not
/// exist on x86_64 macOS).
public enum ScalarValue: Hashable, Sendable {
    case bool(Bool)
    case f32(Float)
    case f16(bits: UInt16)
    case i32(Int32)
    case u32(UInt32)
    case abstractInt(Int64)
    case abstractFloat(Double)
}

/// A user-keyed, already-typed override value: one entry of the HashMap<String, ConstantValue> that C++ generate() received.
///
/// For duplicate keys the last one wins (HashMap::set).
public struct OverrideAssignment: Hashable, Sendable {
    /// The override key.
    public var key: Name
    /// The typed value.
    public var value: ScalarValue

    /// Memberwise.
    public init(key: Name, value: ScalarValue) {
        self.key = key
        self.value = value
    }
}

/// An override value keyed by mangled name.
public struct ResolvedOverride: Hashable, Sendable {
    /// The override's mangled name.
    public var name: Name
    /// The value.
    public var value: ScalarValue

    /// Memberwise.
    public init(name: Name, value: ScalarValue) {
        self.name = name
        self.value = value
    }
}

/// The override values generate() used, keyed by mangled name (C++: the re-keyed HashMap<String, ConstantValue>).
///
/// Only looked up by name; `entries` is in insertion order.
public struct ResolvedOverrides: Hashable, Sendable {
    /// The values in insertion order.
    public let entries: [ResolvedOverride]

    /// Wraps the values.
    public init(_ entries: [ResolvedOverride]) { self.entries = entries }

    /// The number of values.
    public var count: Int { entries.count }
}

/// Generated MSL.
public struct MetalSource: Sendable {
    /// ASCII in practice; UTF-8 in general.
    ///
    /// A ContiguousArray so that WebGPU's bridge can lend it to C++ as a Span on every deployment target (Array.span needs macOS 26).
    public let utf8: ContiguousArray<UInt8>

    /// Wraps UTF-8 bytes.
    public init(utf8: ContiguousArray<UInt8>) { self.utf8 = utf8 }

    /// The source decoded for tools and tests.
    public var string: String { String(decoding: utf8, as: UTF8.self) }
}

/// What generate() produces.
public struct GeneratedLibrary: Sendable {
    /// The MSL.
    public let msl: MetalSource
    /// The override values the MSL was specialised with.
    public let resolvedOverrides: ResolvedOverrides
}

/// One evaluated @workgroup_size argument.
public enum EvaluatedDimension: Hashable, Sendable {
    /// The attribute has no such argument: the dimension is 1.
    case absent
    case failed
    case value(ScalarValue)
}

/// ComputePipeline.mm metalSize.
///
/// All three dimensions are always evaluated (each may memoize), even when an earlier one fails.
public struct WorkgroupSizeEvaluation: Hashable, Sendable {
    /// The first dimension.
    public let width: EvaluatedDimension
    /// The second dimension.
    public let height: EvaluatedDimension
    /// The third dimension.
    public let depth: EvaluatedDimension

    /// Nil if a dimension failed.
    ///
    /// Traps on a non-integer value, as ConstantValue::integerValue()'s RELEASE_ASSERT does, once all three dimensions are known to
    /// be present, as metalSize checks them.
    public var size: WorkgroupExtent? {
        if width == .failed || height == .failed || depth == .failed {
            return nil
        }
        func integer(_ dimension: EvaluatedDimension) -> Int64 {
            switch dimension {
            case .absent: 1
            case .value(.i32(let value)): Int64(value)
            case .value(.u32(let value)): Int64(value)
            case .value(.abstractInt(let value)): value
            case .failed, .value(.bool), .value(.f32), .value(.f16), .value(.abstractFloat):
                wgslFatal("workgroup size dimension is not an integer", cppSite: "ConstantValue.h:174")
            }
        }
        return WorkgroupExtent(width: integer(width), height: integer(height), depth: integer(depth))
    }
}

/// A workgroup size as three integers.
public struct WorkgroupExtent: Hashable, Sendable {
    /// The first dimension.
    public var width: Int64
    /// The second dimension.
    public var height: Int64
    /// The third dimension.
    public var depth: Int64

    /// Memberwise.
    public init(width: Int64, height: Int64, depth: Int64) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

// MARK: - Typestate

/// The messages of a module that failed staticCheck.
public struct FailedCheck: Hashable, Sendable {
    /// The errors.
    public let errors: [CompilationMessage]
    /// The warnings.
    public let warnings: [CompilationMessage]
}

/// The result of staticCheck.
public enum StaticCheckOutcome: ~Copyable {
    case success(CheckedModule)
    case failure(FailedCheck)
}

/// WGSL::staticCheck: lexes, parses and checks `source`.
public func staticCheck(_ source: SourceText, configuration: Configuration) -> StaticCheckOutcome {
    Compiler.staticCheck(source, configuration)
}

/// The passes of staticCheck, in order (WGSL.cpp:99-112).
@_spi(Testing)
public enum StaticCheckPass: CaseIterable, Hashable, Sendable {
    case parse
    case reorderGlobals
    case typeCheck
    case validateAttributes
    case buildCallGraph
    case validateIO
    case validateVisibility
    case mangleNames
    case rewriteEvaluationOrder
    case rewritePointers
    case aliasAnalysis
    case uniformityAnalysis
}

/// The module as the staticCheck passes up to a stop leave it.
@_spi(Testing)
public struct StaticCheckTestingOutcome: ~Copyable {
    /// The module after the last pass that ran.
    @_spi(Testing)
    public var shaderModule: ShaderModule
    /// The FailedCheck of the pass that failed, with only that pass's warnings (CHECK_PASS); nil if none failed.
    @_spi(Testing)
    public let failure: FailedCheck?
    /// The warnings of the passes that ran, if none failed.
    @_spi(Testing)
    public let warnings: [CompilationMessage]
}

/// The staticCheck passes up to and including `stopAfter`, with CHECK_PASS/RUN_PASS semantics; no extension check, no reflection.
@_spi(Testing)
public func staticCheckForTesting(
    _ source: SourceText,
    configuration: Configuration,
    stopAfter: StaticCheckPass
) -> StaticCheckTestingOutcome {
    Compiler.staticCheckForTesting(source, configuration, stopAfter: stopAfter)
}

/// An entry point to prepare, with its explicit layout if any.
public struct EntryPointRequest: Hashable, Sendable {
    /// The entry point's source name.
    public var name: Name
    /// An index into the `layouts` argument of prepare(_:layouts:), or nil to compute a default layout.
    public var layout: Int?

    /// Memberwise.
    public init(name: Name, layout: Int? = nil) {
        self.name = name
        self.layout = layout
    }
}

/// A module that passed staticCheck.
///
/// Owned by exactly one GPUShaderModule; prepare consumes it and every outcome hands it back, rolled back, so two prepared states can never
/// overlap.
public struct CheckedModule: ~Copyable {
    var state: ModuleState
    /// The override map of the generate that handed this module back, with the ResolvedOverrides made from it (C++ `lastValues`).
    var lastOverrideValues: (resolved: ResolvedOverrides, values: OverrideValues)?

    init(state: consuming ModuleState) {
        self.state = state
        lastOverrideValues = nil
    }

    /// The warnings staticCheck reported.
    public var warnings: [CompilationMessage] { state.warnings }

    /// The entry points in call-graph order, with the IO reflection ShaderModule.mm reads.
    public var entryPoints: [EntryPointIO] { state.entryPoints }

    /// ShaderModule::containsOverride: does any override's key (decimal @id, else name) equal `key`?
    public func containsOverride(_ key: Name) -> Bool { Compiler.containsOverride(self, key) }

    /// C++ prepare(module, name, &layout).
    ///
    /// Before returning, on every path, the minBindingSize of each buffer binding the entry point uses is assigned through
    /// `Access.setMinBindingSize` into the caller's own `layout` (GlobalVariableRewriter.cpp:2423); other entries are not touched.
    public consuming func prepare<Access: PipelineLayoutAccess>(
        entryPoint: Name,
        layout: inout Access.Layout,
        access: Access.Type
    ) -> PrepareOutcome {
        Compiler.prepare(self, entryPoint: entryPoint, layout: &layout, access: access)
    }

    /// C++ prepare(module, name, &layout) with a value layout.
    public consuming func prepare(entryPoint: Name, layout: inout PipelineLayout) -> PrepareOutcome {
        prepare(entryPoint: entryPoint, layout: &layout, access: PipelineLayout.Access.self)
    }

    /// C++ prepare(module, map-with-null-layouts): every entry point gets a computed default layout.
    public consuming func prepare(entryPoints: [Name]) -> PrepareOutcome {
        Compiler.prepare(self, entryPoints: entryPoints)
    }

    /// The general C++ prepare(module, HashMap<String, PipelineLayout*>).
    ///
    /// The first request for a name wins, as HashMap::add does.
    public consuming func prepare(_ requests: [EntryPointRequest], layouts: inout [PipelineLayout]) -> PrepareOutcome {
        Compiler.prepare(self, requests: requests, layouts: &layouts)
    }

    /// Pipeline.mm prepareLibrary: prepare one entry point, convert the pipeline constants, generate, roll back.
    ///
    /// The module is left exactly as the three-step sequence leaves it. The compiler checks that `self` is reinitialized on every path.
    public mutating func compileEntryPoint<Access: PipelineLayoutAccess>(
        _ name: Name,
        layout: inout Access.Layout,
        access: Access.Type,
        constants: [PipelineConstant],
        deviceState: DeviceState
    ) -> EntryPointCompilation {
        let finished = Self.finish(
            (consume self).prepare(entryPoint: name, layout: &layout, access: access),
            name: name,
            constants: constants,
            deviceState: deviceState
        )
        self = finished.module
        return finished.compilation
    }

    /// compileEntryPoint with a default layout.
    public mutating func compileEntryPoint(_ name: Name, constants: [PipelineConstant], deviceState: DeviceState) -> EntryPointCompilation {
        let finished = Self.finish((consume self).prepare(entryPoints: [name]), name: name, constants: constants, deviceState: deviceState)
        self = finished.module
        return finished.compilation
    }

    private struct Finished: ~Copyable {
        var module: CheckedModule
        let compilation: EntryPointCompilation
    }

    private static func finish(
        _ outcome: consuming PrepareOutcome,
        name: Name,
        constants: [PipelineConstant],
        deviceState: DeviceState
    ) -> Finished {
        switch consume outcome {
        case .failed(let error, let rolledBack):
            return Finished(module: rolledBack, compilation: .prepareFailed(error))
        case .prepared(let prepared):
            guard let information = prepared.entryPoint(named: name) else {
                return Finished(module: prepared.abandon(), compilation: .entryPointNotFound)
            }
            guard let overrides = prepared.convertPipelineConstants(constants) else {
                return Finished(module: prepared.abandon(), compilation: .invalidPipelineConstant)
            }
            switch prepared.generate(overrides: overrides, deviceState: deviceState) {
            case .generated(let library, let rolledBack):
                return Finished(module: rolledBack, compilation: .compiled(information, library))
            case .failed(let error, let rolledBack):
                return Finished(module: rolledBack, compilation: .generateFailed(error))
            }
        }
    }

    /// ComputePipeline.mm metalSize: evaluates the entry point's @workgroup_size on the rolled-back module with the overrides generate()
    /// resolved.
    ///
    /// Mutating because evaluation memoizes constant values in the module (the C++ cross-pipeline cache, which is replicated). Only call it
    /// for an entry point whose typedEntryPoint is `.compute`, as ComputePipeline.mm does.
    public mutating func evaluateWorkgroupSize(entryPoint: Name, overrides: ResolvedOverrides) -> WorkgroupSizeEvaluation {
        Compiler.evaluateWorkgroupSize(&self, entryPoint: entryPoint, overrides: overrides)
    }

    /// AST::dumpAST, for wgslc --dump-ast-after-checking and the tests.
    @_spi(Testing)
    public func dumpAST() -> String { Compiler.dumpAST(self) }

    /// Everything a rollback restores, for the rollback tests.
    @_spi(Testing)
    public func snapshot() -> ShaderModuleSnapshot { state.shaderModule.snapshot() }
}

/// The result of prepare.
public enum PrepareOutcome: ~Copyable {
    case prepared(PreparedModule)
    case failed(CompilationMessage, CheckedModule)
}

/// A module inside its prepare CompilationScope.
///
/// Only one can exist per CheckedModule.
public struct PreparedModule: ~Copyable {
    var state: PreparedState
    let information: [EntryPointInformation]
    /// C++ `PrepareResult::entryPoints`, which generate reads.
    let reflection: Reflection.EntryPointInformations

    init(
        state: consuming PreparedState,
        information: [EntryPointInformation],
        reflection: Reflection.EntryPointInformations,
        writeBack: borrowing MinBindingSizesWrittenBack
    ) {
        self.state = state
        self.information = information
        self.reflection = reflection
    }

    /// In the module's entry point order.
    public var entryPoints: [EntryPointInformation] { information }

    /// The information of the prepared entry point named `name`.
    public func entryPoint(named name: Name) -> EntryPointInformation? {
        information.first { $0.originalName == name }
    }

    /// Pipeline.mm:89-140, in order: a key no prepared entry point uses is skipped if some override of the module has it and makes the
    /// result nil otherwise; a value outside its override's type range makes the result nil.
    ///
    /// Nil carries no message (no NSError is set).
    public func convertPipelineConstants(_ constants: [PipelineConstant]) -> [OverrideAssignment]? {
        Compiler.convertPipelineConstants(self, constants)
    }

    /// C++ generate: validates overrides (re-keying them by mangled name), writes the MSL, then rolls
    /// back the generation scope and the prepare scope.
    public consuming func generate(overrides: [OverrideAssignment] = [], deviceState: DeviceState = DeviceState()) -> GenerateOutcome {
        var resolvedOverrides = ResolvedOverrides([])
        return Compiler.generate(self, overrides: overrides, deviceState: deviceState, resolvedOverrides: &resolvedOverrides)
    }

    /// generate, storing the override map validateOverrides leaves behind into `resolvedOverrides`, on failure too.
    @_spi(Testing)
    public consuming func generate(
        overrides: [OverrideAssignment],
        deviceState: DeviceState,
        resolvedOverrides: inout ResolvedOverrides
    ) -> GenerateOutcome {
        Compiler.generate(self, overrides: overrides, deviceState: deviceState, resolvedOverrides: &resolvedOverrides)
    }

    /// Rolls back without generating.
    public consuming func abandon() -> CheckedModule {
        Compiler.rollBack(self)
    }

    /// AST::dumpAST of the prepared module, for wgslc --dump-ast-at-end and the tests.
    @_spi(Testing)
    public func dumpAST() -> String { Compiler.dumpAST(self) }

    /// C++ `PrepareResult::entryPoints` as prepare computed it, with the expressions it refers to (the workgroup size and the
    /// specialization constants' default values).
    @_spi(Testing)
    public var reflectionForTesting: Reflection.EntryPointInformations { reflection }

    /// AST::StringDumper of one expression of the prepared module.
    @_spi(Testing)
    public func dumpAST(_ expression: ExpressionID) -> String { Compiler.dumpAST(self, expression) }
}

/// The result of generate.
public enum GenerateOutcome: ~Copyable {
    case generated(GeneratedLibrary, CheckedModule)
    case failed(CompilationMessage, CheckedModule)
}

/// The result of compileEntryPoint.
public enum EntryPointCompilation: Sendable {
    case compiled(EntryPointInformation, GeneratedLibrary)
    case prepareFailed(CompilationMessage)
    case entryPointNotFound
    case invalidPipelineConstant
    case generateFailed(CompilationMessage)
}

// MARK: - Shared with WebGPU's encoders, and execution context

/// The [[buffer(n)]] of a vertex-stage bind group.
///
/// WebGPU's encoders call this same function through the bridge, so codegen and encoding cannot disagree.
public func vertexBufferIndexForBindGroup(_ groupIndex: UInt32, maxIndex: UInt32) -> UInt32 {
    groupIndex > maxIndex ? groupIndex : maxIndex - groupIndex
}

/// The execution context compilations need.
public enum CompileThread {
    /// 16 MiB when the module is compiled with -Onone (WGSL_UNOPTIMIZED), nil otherwise.
    ///
    /// 16 MiB is several times the deepest -Onone compile of the stack sweep. At -O every compile that the C++ completed
    /// fits the 512 KiB WebGPU work queue, so nil means compiling on the caller's thread.
    public static var recommendedStackSize: Int? {
        #if WGSL_UNOPTIMIZED
        16 << 20
        #else
        nil
        #endif
    }
}

// MARK: - Driver (WGSL.cpp)

private func wgslExtensionToWebGPUFeatureName(_ extension: Extension) -> StaticString {
    // Map WGSL extension names to WebGPU feature names
    // WGSL uses underscores, WebGPU uses hyphens
    switch `extension` {
    case .clipDistances:
        "clip-distances"
    case .f16:
        "shader-f16"
    case .primitiveIndex:
        "primitive-index"
    case .subgroups:
        "subgroups"
    }
}

/// The Features bit of the WebGPU feature named by wgslExtensionToWebGPUFeatureName.
private func wgslExtensionToWebGPUFeature(_ extension: Extension) -> Features {
    switch `extension` {
    case .clipDistances:
        .clipDistances
    case .f16:
        .shaderF16
    case .primitiveIndex:
        .primitiveIndex
    case .subgroups:
        .subgroups
    }
}

enum Compiler {
    static func staticCheck(_ source: SourceText, _ configuration: Configuration) -> StaticCheckOutcome {
        let shaderModule = ShaderModule(source: source, configuration: configuration)
        let step = ModuleState.staticCheck(shaderModule) { shaderModule in
            var passes = StaticCheckPasses(stopAfter: nil)
            passes.run(&shaderModule)
            if let failure = passes.failure {
                return .failure(failure)
            }

            // Validate that all enabled extensions are supported by the device
            for `extension` in Extension.allCases where shaderModule.enabledExtensions.contains(Extensions(`extension`)) {
                let featureName = wgslExtensionToWebGPUFeatureName(`extension`)
                if !shaderModule.hasFeature(wgslExtensionToWebGPUFeature(`extension`)) {
                    let message = CompilationMessage(
                        text: "Extension '\(toString(`extension`))' requires feature '\(featureName)' which is not enabled on this device",
                        span: .empty
                    )
                    return .failure(FailedCheck(errors: [message], warnings: []))
                }
            }

            return .success(warnings: passes.warnings, entryPoints: computeEntryPointIO(shaderModule))
        }
        switch consume step {
        case .checked(let state):
            return .success(CheckedModule(state: state))
        case .failed(let failedCheck):
            return .failure(failedCheck)
        }
    }

    static func staticCheckForTesting(
        _ source: SourceText,
        _ configuration: Configuration,
        stopAfter: StaticCheckPass
    ) -> StaticCheckTestingOutcome {
        var shaderModule = ShaderModule(source: source, configuration: configuration)
        var passes = StaticCheckPasses(stopAfter: stopAfter)
        passes.run(&shaderModule)
        return StaticCheckTestingOutcome(shaderModule: shaderModule, failure: passes.failure, warnings: passes.warnings)
    }

    /// prepareImpl (WGSL.cpp:135-157): `pipelineLayouts` maps each entry point to prepare to its explicit layout (an index into
    /// `explicitLayouts`), or to nil for a default layout.
    private static func prepareImpl(
        _ module: consuming CheckedModule,
        _ pipelineLayouts: LookupMap<Name, Int?>,
        _ explicitLayouts: inout [ExplicitPipelineLayout]
    ) -> PrepareStep<Reflection.EntryPointInformations> {
        module.state.prepare { shaderModule -> Result<Reflection.EntryPointInformations, CompilationMessage> in
            var entryPoints = Reflection.EntryPointInformations()

            insertBoundsChecks(&shaderModule)
            rewriteEntryPoints(&shaderModule, pipelineLayouts)
            if let error = rewriteGlobalVariables(&shaderModule, pipelineLayouts, &explicitLayouts, &entryPoints) {
                return .failure(error)
            }

            return .success(entryPoints)
        }
    }

    /// generate (WGSL.cpp:160-174) on the caller's override map, built from `overrides` with HashMap::set; the generation
    /// scope and then the prepare scope are rolled back on both paths.
    static func generate(
        _ module: consuming PreparedModule,
        overrides: [OverrideAssignment],
        deviceState: DeviceState,
        resolvedOverrides: inout ResolvedOverrides
    ) -> GenerateOutcome {
        let information = module.information
        let reflection = module.reflection
        var constantValues = OverrideValues()
        var keys: [Name] = []
        keys.reserveCapacity(overrides.count)
        for assignment in overrides {
            let isNewEntry = constantValues.set(assignment.key, constantValue(assignment.value))
            if isNewEntry {
                keys.append(assignment.key)
            }
        }

        let step = module.state.generate { shaderModule -> Result<MetalSource, CompilationMessage> in
            let maybeError = shaderModule.validateOverrides(information, &constantValues)
            resolvedOverrides = Self.resolvedOverrides(&shaderModule, keys, constantValues)
            if let maybeError {
                return .failure(maybeError)
            }
            return .success(generateMetalCode(&shaderModule, reflection, constantValues, deviceState))
        }
        let result = step.result
        var rolledBack = CheckedModule(state: step.takeModule())
        rolledBack.lastOverrideValues = (resolvedOverrides, constantValues)
        switch result {
        case .success(let msl):
            return .generated(GeneratedLibrary(msl: msl, resolvedOverrides: resolvedOverrides), rolledBack)
        case .failure(let error):
            return .failed(error, rolledBack)
        }
    }

    /// The map validateOverrides left behind (WGSLShaderModule.cpp:46-89), whose keys are the caller's keys it did not re-key followed
    /// by the mangled names it added, in the order it added them.
    private static func resolvedOverrides(
        _ shaderModule: inout ShaderModule,
        _ keys: [Name],
        _ constantValues: OverrideValues
    ) -> ResolvedOverrides {
        var entries: [ResolvedOverride] = []
        entries.reserveCapacity(constantValues.count)
        var seen = LookupSet<Name>()
        if !constantValues.isEmpty {
            seen.reserveInitialCapacity(constantValues.count)
        }
        func append(_ name: Name) {
            guard seen.add(name), let value = constantValues.find(name) else {
                return
            }
            entries.append(ResolvedOverride(name: name, value: scalarValue(value, cppSite: "WGSLShaderModule.cpp:46")))
        }
        for key in keys {
            append(key)
        }
        var overrideIndex = 0
        while overrideIndex < shaderModule.overrides.count {
            let symbol = shaderModule.symbol(of: shaderModule[shaderModule.overrides[overrideIndex]].name)
            append(shaderModule.symbols.cachedName(of: symbol))
            overrideIndex &+= 1
        }
        guard entries.count == constantValues.count else {
            wgslFatal("an override value has neither a caller's key nor a mangled name", cppSite: "WGSLShaderModule.cpp:46")
        }
        return ResolvedOverrides(entries)
    }

    /// C++ prepare(ast, pipelineLayouts) with only null layouts (WGSL.cpp:176-179).
    static func prepare(_ module: consuming CheckedModule, entryPoints: [Name]) -> PrepareOutcome {
        var pipelineLayouts = LookupMap<Name, Int?>()
        for name in entryPoints {
            pipelineLayouts.add(name, nil)
        }
        var explicitLayouts: [ExplicitPipelineLayout] = []
        let step = prepareImpl(module, pipelineLayouts, &explicitLayouts)
        return prepare(step, writtenBack: MinBindingSizeWriteBack.flush())
    }

    /// C++ prepare(ast, pipelineLayouts) (WGSL.cpp:176-179): HashMap::add, so the first request for a name wins.
    static func prepare(_ module: consuming CheckedModule, requests: [EntryPointRequest], layouts: inout [PipelineLayout]) -> PrepareOutcome
    {
        var pipelineLayouts = LookupMap<Name, Int?>()
        for request in requests {
            if let layout = request.layout, !layouts.indices.contains(layout) {
                wgslFatal("an EntryPointRequest names a layout that prepare was not given", cppSite: "WGSL.cpp:176")
            }
            pipelineLayouts.add(request.name, request.layout)
        }
        var explicitLayouts: [ExplicitPipelineLayout] = []
        explicitLayouts.reserveCapacity(layouts.count)
        for layout in layouts {
            explicitLayouts.append(ExplicitPipelineLayout(reading: layout, access: PipelineLayout.Access.self))
        }
        let step = prepareImpl(module, pipelineLayouts, &explicitLayouts)
        return prepare(step, writtenBack: MinBindingSizeWriteBack.flush(explicitLayouts, into: &layouts))
    }

    /// C++ prepare(ast, entryPointName, &pipelineLayout) (WGSL.cpp:181-186).
    static func prepare<Access: PipelineLayoutAccess>(
        _ module: consuming CheckedModule,
        entryPoint: Name,
        layout: inout Access.Layout,
        access: Access.Type
    ) -> PrepareOutcome {
        var pipelineLayouts = LookupMap<Name, Int?>()
        pipelineLayouts.add(entryPoint, 0)
        var explicitLayouts = [ExplicitPipelineLayout(reading: layout, access: access)]
        let step = prepareImpl(module, pipelineLayouts, &explicitLayouts)
        return prepare(step, writtenBack: MinBindingSizeWriteBack.flush(explicitLayouts[0], into: &layout, access: access))
    }

    /// The end of every prepare: the write-back has run whatever the outcome, since both outcomes are built here and only from its
    /// token.
    private static func prepare(
        _ step: consuming PrepareStep<Reflection.EntryPointInformations>,
        writtenBack: consuming MinBindingSizesWrittenBack
    ) -> PrepareOutcome {
        switch consume step {
        case .prepared(let state, let entryPoints):
            let information = entryPointInformation(entryPoints, state.shaderModule.symbols)
            return .prepared(PreparedModule(state: state, information: information, reflection: entryPoints, writeBack: writtenBack))
        case .failed(let state, let error):
            return .failed(error, CheckedModule(state: state))
        }
    }

    /// The public form of C++ `PrepareResult::entryPoints`, in the same order.
    private static func entryPointInformation(
        _ entryPoints: Reflection.EntryPointInformations,
        _ symbols: borrowing SymbolTable
    ) -> [EntryPointInformation] {
        var result: [EntryPointInformation] = []
        result.reserveCapacity(entryPoints.entries.count)
        var scratch = ContiguousArray<UInt8>()
        for information in entryPoints.entries {
            guard information.initialized != nil else {
                wgslFatal("a prepared entry point has no zero-initialization proof", cppSite: "GlobalVariableRewriter.cpp:1133")
            }
            let typedEntryPoint: TypedEntryPoint =
                switch information.typedEntryPoint {
                case .vertex(let invariantIsPresent): .vertex(invariantIsPresent: invariantIsPresent)
                case .fragment: .fragment
                case .compute: .compute
                }
            var specializationConstants: [SpecializationConstant] = []
            specializationConstants.reserveCapacity(information.specializationConstants.count)
            for constant in information.specializationConstants {
                specializationConstants.append(
                    SpecializationConstant(
                        key: constant.key,
                        mangledName: symbols.string(of: constant.mangledName, scratch: &scratch),
                        type: constant.type
                    )
                )
            }
            result.append(
                EntryPointInformation(
                    originalName: information.originalName,
                    mangledName: symbols.string(of: information.mangledName, scratch: &scratch),
                    stage: information.stage,
                    typedEntryPoint: typedEntryPoint,
                    defaultLayout: information.defaultLayout,
                    specializationConstants: specializationConstants,
                    sizeForWorkgroupVariables: information.sizeForWorkgroupVariables,
                    bindingCount: information.bindingCount,
                    usesInvariant: information.usesInvariant
                )
            )
        }
        return result
    }

    static func convertPipelineConstants(_ module: borrowing PreparedModule, _ constants: [PipelineConstant]) -> [OverrideAssignment]? {
        WGSL.convertPipelineConstants(module.reflection, module.state.shaderModule, constants)
    }

    static func rollBack(_ module: consuming PreparedModule) -> CheckedModule {
        CheckedModule(state: module.state.rollBack())
    }

    static func containsOverride(_ module: borrowing CheckedModule, _ key: Name) -> Bool {
        module.state.shaderModule.containsOverride(key)
    }

    /// ComputePipeline.mm metalSize (ComputePipeline.mm:59-68) on the expressions GlobalVariableRewriter.cpp:1155-1161 reflects: the
    /// first @workgroup_size of the entry point's function.
    static func evaluateWorkgroupSize(
        _ module: inout CheckedModule,
        entryPoint: Name,
        overrides: ResolvedOverrides
    ) -> WorkgroupSizeEvaluation {
        guard let workgroupSize = workgroupSize(of: entryPoint, module.state.shaderModule) else {
            wgslFatal("evaluateWorkgroupSize of an entry point that is not a compute entry point", cppSite: "ComputePipeline.mm:117")
        }
        var wgslConstantValues = OverrideValues()
        if let last = module.lastOverrideValues, sameBits(last.resolved, overrides) {
            wgslConstantValues = last.values
        } else {
            if !overrides.entries.isEmpty {
                wgslConstantValues.reserveInitialCapacity(overrides.entries.count)
            }
            for resolved in overrides.entries {
                wgslConstantValues.set(resolved.name, constantValue(resolved.value))
            }
        }

        let width = evaluatedDimension(module.state.evaluate(workgroupSize.x, overrides: wgslConstantValues))
        var height = EvaluatedDimension.absent
        if let y = workgroupSize.y {
            height = evaluatedDimension(module.state.evaluate(y, overrides: wgslConstantValues))
        }
        var depth = EvaluatedDimension.absent
        if let z = workgroupSize.z {
            depth = evaluatedDimension(module.state.evaluate(z, overrides: wgslConstantValues))
        }
        return WorkgroupSizeEvaluation(width: width, height: height, depth: depth)
    }

    /// The same names and value bits in the same order: the map one was made from is the map the other one makes.
    private static func sameBits(_ a: ResolvedOverrides, _ b: ResolvedOverrides) -> Bool {
        guard a.entries.count == b.entries.count else {
            return false
        }
        var index = 0
        while index < a.entries.count {
            guard a.entries[index].name == b.entries[index].name, sameBits(a.entries[index].value, b.entries[index].value) else {
                return false
            }
            index &+= 1
        }
        return true
    }

    private static func sameBits(_ a: ScalarValue, _ b: ScalarValue) -> Bool {
        switch (a, b) {
        case (.bool(let x), .bool(let y)): x == y
        case (.f32(let x), .f32(let y)): x.bitPattern == y.bitPattern
        case (.f16(let x), .f16(let y)): x == y
        case (.i32(let x), .i32(let y)): x == y
        case (.u32(let x), .u32(let y)): x == y
        case (.abstractInt(let x), .abstractInt(let y)): x == y
        case (.abstractFloat(let x), .abstractFloat(let y)): x.bitPattern == y.bitPattern
        case (.bool, _), (.f32, _), (.f16, _), (.i32, _), (.u32, _), (.abstractInt, _), (.abstractFloat, _): false
        }
    }

    private static func workgroupSize(of entryPoint: Name, _ shaderModule: borrowing ShaderModule) -> WorkgroupSize? {
        let entryPoints = shaderModule.callGraph.entrypoints
        var index = 0
        while index < entryPoints.count {
            let candidate = entryPoints[index]
            index &+= 1
            guard candidate.stage == .compute, candidate.apiName == entryPoint else {
                continue
            }
            var attributes = shaderModule.cursor(shaderModule[candidate.function].attributes)
            while let attribute = shaderModule.next(&attributes) {
                if let workgroupSize = shaderModule.dynamicDowncast(WorkgroupSizeAttribute.self, attribute) {
                    return workgroupSize.workgroupSize
                }
            }
            return nil
        }
        return nil
    }

    private static func evaluatedDimension(_ value: ConstantValue?) -> EvaluatedDimension {
        guard let value else {
            return .failed
        }
        return .value(scalarValue(value, cppSite: "ConstantValue.h:174"))
    }

    static func dumpAST(_ module: borrowing CheckedModule) -> String {
        ASTStringDumper.dump(module.state.shaderModule)
    }

    static func dumpAST(_ module: borrowing PreparedModule) -> String {
        ASTStringDumper.dump(module.state.shaderModule)
    }

    static func dumpAST(_ module: borrowing PreparedModule, _ expression: ExpressionID) -> String {
        ASTStringDumper.dump(module.state.shaderModule, expression)
    }
}

/// The pass sequence of staticCheck (WGSL.cpp:99-112) with the CHECK_PASS and RUN_PASS semantics (WGSL.cpp:52-67), optionally
/// stopping after one pass.
struct StaticCheckPasses {
    let stopAfter: StaticCheckPass?
    /// The FailedCheck of the pass that failed: CHECK_PASS returns it as is, dropping the earlier passes' warnings.
    private(set) var failure: FailedCheck?
    private(set) var warnings: [CompilationMessage] = []

    init(stopAfter: StaticCheckPass?) { self.stopAfter = stopAfter }

    /// CHECK_PASS; false when the sequence ends here.
    private mutating func checkPass(_ pass: StaticCheckPass, _ result: FailedCheck?) -> Bool {
        if let result {
            if !result.errors.isEmpty {
                failure = result
                return false
            }
            warnings.append(contentsOf: result.warnings)
        }
        return pass != stopAfter
    }

    /// RUN_PASS; false when the sequence ends here.
    private func runPass(_ pass: StaticCheckPass) -> Bool { pass != stopAfter }

    mutating func run(_ shaderModule: inout ShaderModule) {
        guard checkPass(.parse, parse(&shaderModule)) else {
            return
        }
        guard checkPass(.reorderGlobals, reorderGlobals(&shaderModule)) else {
            return
        }
        guard checkPass(.typeCheck, typeCheck(&shaderModule)) else {
            return
        }
        guard checkPass(.validateAttributes, validateAttributes(&shaderModule)) else {
            return
        }
        buildCallGraph(&shaderModule)
        guard runPass(.buildCallGraph) else {
            return
        }
        guard checkPass(.validateIO, validateIO(&shaderModule)) else {
            return
        }
        guard checkPass(.validateVisibility, validateVisibility(&shaderModule)) else {
            return
        }
        mangleNames(&shaderModule)
        guard runPass(.mangleNames) else {
            return
        }
        // Must run before the pointer rewriter, which inlines a pointer's initializer into each of its
        // uses and would carry any side effect in that initializer along with it.
        rewriteEvaluationOrder(&shaderModule)
        guard runPass(.rewriteEvaluationOrder) else {
            return
        }
        rewritePointers(&shaderModule)
        guard runPass(.rewritePointers) else {
            return
        }
        guard checkPass(.aliasAnalysis, aliasAnalysis(&shaderModule)) else {
            return
        }
        _ = checkPass(.uniformityAnalysis, uniformityAnalysis(&shaderModule))
    }
}

// MARK: - Override values across the API

/// The ConstantValue of a typed override value.
private func constantValue(_ value: ScalarValue) -> ConstantValue {
    switch value {
    case .bool(let value): .bool(value)
    case .f32(let value): .float(value)
    case .f16(let bits): .half(Half(bitPattern: bits))
    case .i32(let value): .int32(value)
    case .u32(let value): .uint32(value)
    case .abstractInt(let value): .int64(value)
    case .abstractFloat(let value): .double(value)
    }
}

/// An override value or a workgroup size dimension, which the type checker makes a scalar.
private func scalarValue(_ value: ConstantValue, cppSite: StaticString) -> ScalarValue {
    switch value {
    case .bool(let value): .bool(value)
    case .float(let value): .f32(value)
    case .half(let value): .f16(bits: value.bitPattern)
    case .int32(let value): .i32(value)
    case .uint32(let value): .u32(value)
    case .int64(let value): .abstractInt(value)
    case .double(let value): .abstractFloat(value)
    case .array, .vector, .matrix, .struct:
        wgslFatal("an override value or a workgroup size dimension is not a scalar", cppSite: cppSite)
    }
}
