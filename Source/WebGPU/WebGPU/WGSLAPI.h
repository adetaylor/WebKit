/*
 * Copyright (c) 2021-2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <optional>
#include <span>
#include <wtf/OptionSet.h>
#include <wtf/PrintStream.h>
#include <wtf/StdLibExtras.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Variant.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

// Plain data exchanged between WebGPU's Objective-C++ and the Swift WGSL compiler. The compiler
// itself is the Swift module WGSL; WGSLBridge.swift (in WebGPU's Swift module) converts between it
// and these types. Nothing here refers to the compiler's AST.

// Every struct is SWIFT_SELF_CONTAINED: it owns all its data, and Swift 6.3 otherwise imports one that holds a String or
// a Vector as an unsafe type.

// Never test HAVE_WGSL_COMPILER in this or any other header Swift imports: CMake does not pass it to Swift's clang importer, so Swift and Objective-C++ would disagree on layouts.

namespace WGSL {

enum class ShaderStage : uint8_t {
    Compute = 1 << 2,
    Fragment = 1 << 1,
    Vertex = 1 << 0,
};

// The device features the compiler consults. Bit values match ENUM_Extension.
enum class Feature : uint8_t {
    ClipDistances = 1 << 0,
    ShaderF16 = 1 << 1,
    PrimitiveIndex = 1 << 2,
    Subgroups = 1 << 3,
};

enum class TexelFormat : uint8_t {
    BGRA8unorm,
    R16float,
    R16sint,
    R16snorm,
    R16uint,
    R16unorm,
    R32float,
    R32sint,
    R32uint,
    R8sint,
    R8snorm,
    R8uint,
    R8unorm,
    RG11B10ufloat,
    RG16float,
    RG16sint,
    RG16snorm,
    RG16uint,
    RG16unorm,
    RG32float,
    RG32sint,
    RG32uint,
    RG8sint,
    RG8snorm,
    RG8uint,
    RG8unorm,
    RGB10A2uint,
    RGB10A2unorm,
    RGBA16float,
    RGBA16sint,
    RGBA16snorm,
    RGBA16uint,
    RGBA16unorm,
    RGBA32float,
    RGBA32sint,
    RGBA32uint,
    RGBA8sint,
    RGBA8snorm,
    RGBA8uint,
    RGBA8unorm,
};

enum class InterpolationType : uint8_t {
    Flat,
    Linear,
    Perspective,
};

enum class InterpolationSampling : uint8_t {
    Center,
    Centroid,
    Either,
    First,
    Sample,
};

struct Interpolation {
    InterpolationType type;
    InterpolationSampling sampling;
} SWIFT_SELF_CONTAINED;

// A diagnostic. Offsets and lengths count UTF-16 code units of the shader source.
class CompilationMessage {
public:
    CompilationMessage(const String& message, unsigned lineNumber, unsigned lineOffset, unsigned offset, unsigned length)
        : m_message(message)
        , m_lineNumber(lineNumber)
        , m_lineOffset(lineOffset)
        , m_offset(offset)
        , m_length(length)
    {
    }

    void dump(PrintStream& out) const { out.print(m_lineNumber, ":", m_lineOffset, ": ", m_message); }

    const String& message() const LIFETIME_BOUND { return m_message; }
    unsigned lineNumber() const { return m_lineNumber; }
    unsigned lineOffset() const { return m_lineOffset; }
    unsigned offset() const { return m_offset; }
    unsigned length() const { return m_length; }

private:
    String m_message;
    unsigned m_lineNumber;
    unsigned m_lineOffset;
    unsigned m_offset;
    unsigned m_length;
} SWIFT_SELF_CONTAINED;

struct Configuration {
    uint32_t maxBuffersPlusVertexBuffersForVertexStage { 8 };
    uint32_t maxBuffersForFragmentStage { 8 };
    uint32_t maxBuffersForComputeStage { 8 };
    uint32_t maximumCombinedWorkgroupVariablesSize { 16384 };
    OptionSet<Feature> supportedFeatures;
} SWIFT_SELF_CONTAINED;

// The shape of an inter-stage or stage-in value, as WebGPU needs it to pick an MTLDataType or a
// WebGPU::VertexFormat. `Missing` is a value without an inferred type, `Other` is any type that is
// neither a scalar nor a vector.
struct IOType {
    enum class Shape : uint8_t { Missing, Other, Scalar, Vector };
    enum class Scalar : uint8_t { I32, U32, F16, F32, Bool, Other };

    Shape shape { Shape::Missing };
    Scalar scalar { Scalar::Other };
    uint8_t vectorSize { 0 };
} SWIFT_SELF_CONTAINED;

struct IOLocation {
    uint32_t location { 0 };
    IOType type;
    std::optional<Interpolation> interpolation;
} SWIFT_SELF_CONTAINED;

// Per entry point, in the order the compiler lists entry points. ShaderModule.mm adds each list to a
// HashMap in list order, so the first entry for a location wins.
struct EntryPointIO {
    String name;
    ShaderStage stage { ShaderStage::Compute };
    Vector<IOLocation> stageIn;
    std::optional<Vector<IOLocation>> vertexOutputs;
    Vector<IOLocation> fragmentInputs;
    std::optional<Vector<IOLocation>> fragmentOutputs;
    bool usesFrontFacingInInput { false };
    bool usesSampleIndexInInput { false };
    bool usesSampleMaskInInput { false };
    bool usesSampleMaskInOutput { false };
    bool usesFragDepth { false };
    bool usesPrimitiveIndexInInput { false };
    bool usesSubgroupInvocationIdInInput { false };
    bool usesSubgroupSizeInInput { false };
    uint32_t clipDistancesCount { 0 };
} SWIFT_SELF_CONTAINED;

struct StaticCheckResult {
    Vector<CompilationMessage> errors;
    Vector<CompilationMessage> warnings;
    Vector<EntryPointIO> entryPoints;
} SWIFT_SELF_CONTAINED;

enum class BufferBindingType : uint8_t {
    Uniform,
    Storage,
    ReadOnlyStorage
};

struct BufferBindingLayout {
    BufferBindingType type;
    bool hasDynamicOffset;
    uint64_t minBindingSize;
} SWIFT_SELF_CONTAINED;

enum class SamplerBindingType : uint8_t {
    Filtering,
    NonFiltering,
    Comparison
};

struct SamplerBindingLayout {
    SamplerBindingType type;
} SWIFT_SELF_CONTAINED;

enum class TextureSampleType : uint8_t {
    Float,
    UnfilterableFloat,
    Depth,
    SignedInt,
    UnsignedInt
};

enum class TextureViewDimension : uint8_t {
    OneDimensional,
    TwoDimensional,
    TwoDimensionalArray,
    Cube,
    CubeArray,
    ThreeDimensional
};

struct TextureBindingLayout {
    TextureSampleType sampleType;
    TextureViewDimension viewDimension;
    bool multisampled;
} SWIFT_SELF_CONTAINED;

enum class StorageTextureAccess : uint8_t {
    WriteOnly,
    ReadOnly,
    ReadWrite,
};

struct StorageTextureBindingLayout {
    StorageTextureAccess access { StorageTextureAccess::WriteOnly };
    TexelFormat format;
    TextureViewDimension viewDimension;
} SWIFT_SELF_CONTAINED;

struct ExternalTextureBindingLayout {
} SWIFT_SELF_CONTAINED;

// As an input (an explicit layout), `webBinding` and `name` are ignored. As an output (a default
// layout), `binding` is the Metal [[id(n)]] and `name` is the mangled global, or
// "__<mangled global>_ArrayLength" for an array-length entry.
struct BindGroupLayoutEntry {
    uint32_t binding;
    uint32_t webBinding;
    OptionSet<ShaderStage> visibility;
    using BindingMember = Variant<BufferBindingLayout, SamplerBindingLayout, TextureBindingLayout, StorageTextureBindingLayout, ExternalTextureBindingLayout>;
    BindingMember bindingMember;
    String name;
    std::optional<uint32_t> vertexArgumentBufferIndex;
    std::optional<uint32_t> vertexArgumentBufferSizeIndex;
    std::optional<uint32_t> vertexBufferDynamicOffset;

    std::optional<uint32_t> fragmentArgumentBufferIndex;
    std::optional<uint32_t> fragmentArgumentBufferSizeIndex;
    std::optional<uint32_t> fragmentBufferDynamicOffset;

    std::optional<uint32_t> computeArgumentBufferIndex;
    std::optional<uint32_t> computeArgumentBufferSizeIndex;
    std::optional<uint32_t> computeBufferDynamicOffset;
} SWIFT_SELF_CONTAINED;

struct BindGroupLayout {
    // Metal's [[id(n)]] indices are equal to the index into this vector. As an input, `group` is ignored.
    uint32_t group;
    Vector<BindGroupLayoutEntry> entries;
} SWIFT_SELF_CONTAINED;

struct PipelineLayout {
    // Metal's [[buffer(n)]] indices are equal to the index into this vector.
    Vector<BindGroupLayout> bindGroupLayouts;
} SWIFT_SELF_CONTAINED;

struct DeviceState {
    unsigned appleGPUFamily { 4 };
    bool shaderValidationEnabled { false };
    bool usesInvariant { false };
} SWIFT_SELF_CONTAINED;

// A GPUProgrammableStage constant, before conversion to the override's type.
struct PipelineConstant {
    String key;
    double value { 0 };
} SWIFT_SELF_CONTAINED;

enum class SpecializationConstantType : uint8_t {
    Boolean,
    Float,
    Int,
    Unsigned,
    Half
};

struct SpecializationConstant {
    // The override's @id as a decimal string, or else its name in the source.
    String key;
    SpecializationConstantType type;
} SWIFT_SELF_CONTAINED;

struct CompiledEntryPoint {
    String originalName;
    String mangledName;
    ShaderStage stage { ShaderStage::Compute };
    // False for a compute function without @workgroup_size, which a compute pipeline rejects.
    bool hasWorkgroupSize { false };
    // Present iff the compiler was asked to compute the layout (no explicit layout was given).
    std::optional<PipelineLayout> defaultLayout;
    Vector<SpecializationConstant> specializationConstants;
    uint64_t sizeForWorkgroupVariables { 0 };
    uint64_t bindingCount { 0 };
    bool usesInvariant { false };
} SWIFT_SELF_CONTAINED;

// One entry of the override values generate() resolved, keyed by the override's mangled name.
// Only the bridge interprets `kind` and `bits`; WebGPU keeps the list to count it and to hand it back
// for workgroup size evaluation.
struct ResolvedOverride {
    enum class Kind : uint8_t { Bool, F32, F16, I32, U32, AbstractInt, AbstractFloat };
    String name;
    Kind kind { Kind::Bool };
    uint64_t bits { 0 };
} SWIFT_SELF_CONTAINED;
using ResolvedOverrides = Vector<ResolvedOverride>;

enum class CompilationFailure : uint8_t {
    None,
    // `errorMessage` is set; it becomes the NSError description.
    PrepareFailed,
    // The shader has no entry point with that name. No message.
    EntryPointNotFound,
    // A pipeline constant names no override of the module, or does not fit the override's type. No message.
    InvalidPipelineConstant,
    // `errorMessage` is set; it becomes the NSError description.
    GenerateFailed,
};

struct CompilationResult {
    CompilationFailure failure { CompilationFailure::None };
    String errorMessage;
    CompiledEntryPoint entryPoint;
    String msl;
    ResolvedOverrides resolvedOverrides;
} SWIFT_SELF_CONTAINED;

struct WorkgroupSize {
    int64_t width { 1 };
    int64_t height { 1 };
    int64_t depth { 1 };
} SWIFT_SELF_CONTAINED;

// Accessors for WGSLBridge.swift. Swift cannot reach a Variant alternative, an OptionSet's raw value,
// or a Vector element by reference without them.
namespace Interop {

enum class BindingMemberKind : uint8_t { Buffer, Sampler, Texture, StorageTexture, ExternalTexture };

// Swift cannot spell a class template specialization, only a typedef of one.
using CompilationMessages = Vector<CompilationMessage>;
using IOLocations = Vector<IOLocation>;
using EntryPointIOs = Vector<EntryPointIO>;
using BindGroupLayoutEntries = Vector<BindGroupLayoutEntry>;
using BindGroupLayouts = Vector<BindGroupLayout>;
using SpecializationConstants = Vector<SpecializationConstant>;
using PipelineConstants = Vector<PipelineConstant>;
using OptionalWorkgroupSize = std::optional<WorkgroupSize>;

// Copy a String's code units into storage Swift lends as a MutableSpan of exactly length() elements.
inline void copyLatin1CodeUnits(const String& string, std::span<uint8_t> destination NOESCAPE) { memcpySpan(destination, byteCast<uint8_t>(string.span8())); }
inline void copyUTF16CodeUnits(const String& string, std::span<char16_t> destination NOESCAPE) { memcpySpan(destination, string.span16()); }
inline uint8_t rawFeatures(const Configuration& configuration) { return configuration.supportedFeatures.toRaw(); }

// XID_Start (false) or XID_Continue (true) of the running OS's ICU, as the sorted, disjoint, half-open
// [start, end) scalar ranges the lexer classifies identifiers with, flattened. Defined in ShaderModule.mm,
// so that ICU stays in C++.
using IdentifierRanges = Vector<uint32_t>;
IdentifierRanges icuIdentifierRanges(bool xidContinue);
inline void copyIdentifierRanges(const IdentifierRanges& ranges, std::span<uint32_t> destination NOESCAPE) { memcpySpan(destination, ranges.span()); }

inline size_t bindGroupLayoutCount(const PipelineLayout& layout) { return layout.bindGroupLayouts.size(); }
inline size_t entryCount(const PipelineLayout& layout, size_t group) { return layout.bindGroupLayouts[group].entries.size(); }
inline uint32_t entryBinding(const PipelineLayout& layout, size_t group, size_t entry) { return layout.bindGroupLayouts[group].entries[entry].binding; }
inline uint8_t entryVisibility(const PipelineLayout& layout, size_t group, size_t entry) { return layout.bindGroupLayouts[group].entries[entry].visibility.toRaw(); }
inline BindingMemberKind entryBindingMemberKind(const PipelineLayout& layout, size_t group, size_t entry) { return static_cast<BindingMemberKind>(layout.bindGroupLayouts[group].entries[entry].bindingMember.index()); }
inline BufferBindingLayout entryBufferBinding(const PipelineLayout& layout, size_t group, size_t entry) { return std::get<BufferBindingLayout>(layout.bindGroupLayouts[group].entries[entry].bindingMember); }
inline SamplerBindingLayout entrySamplerBinding(const PipelineLayout& layout, size_t group, size_t entry) { return std::get<SamplerBindingLayout>(layout.bindGroupLayouts[group].entries[entry].bindingMember); }
inline TextureBindingLayout entryTextureBinding(const PipelineLayout& layout, size_t group, size_t entry) { return std::get<TextureBindingLayout>(layout.bindGroupLayouts[group].entries[entry].bindingMember); }
inline StorageTextureBindingLayout entryStorageTextureBinding(const PipelineLayout& layout, size_t group, size_t entry) { return std::get<StorageTextureBindingLayout>(layout.bindGroupLayouts[group].entries[entry].bindingMember); }

struct StageSlots {
    std::optional<uint32_t> argumentBufferIndex;
    std::optional<uint32_t> argumentBufferSizeIndex;
    std::optional<uint32_t> bufferDynamicOffset;
} SWIFT_SELF_CONTAINED;

inline StageSlots entryStageSlots(const PipelineLayout& layout, size_t group, size_t entry, ShaderStage stage)
{
    auto& e = layout.bindGroupLayouts[group].entries[entry];
    switch (stage) {
    case ShaderStage::Vertex:
        return { e.vertexArgumentBufferIndex, e.vertexArgumentBufferSizeIndex, e.vertexBufferDynamicOffset };
    case ShaderStage::Fragment:
        return { e.fragmentArgumentBufferIndex, e.fragmentArgumentBufferSizeIndex, e.fragmentBufferDynamicOffset };
    case ShaderStage::Compute:
        return { e.computeArgumentBufferIndex, e.computeArgumentBufferSizeIndex, e.computeBufferDynamicOffset };
    }
    RELEASE_ASSERT_NOT_REACHED();
}

inline void setStageSlots(BindGroupLayoutEntry& e, ShaderStage stage, const StageSlots& slots)
{
    switch (stage) {
    case ShaderStage::Vertex:
        e.vertexArgumentBufferIndex = slots.argumentBufferIndex;
        e.vertexArgumentBufferSizeIndex = slots.argumentBufferSizeIndex;
        e.vertexBufferDynamicOffset = slots.bufferDynamicOffset;
        return;
    case ShaderStage::Fragment:
        e.fragmentArgumentBufferIndex = slots.argumentBufferIndex;
        e.fragmentArgumentBufferSizeIndex = slots.argumentBufferSizeIndex;
        e.fragmentBufferDynamicOffset = slots.bufferDynamicOffset;
        return;
    case ShaderStage::Compute:
        e.computeArgumentBufferIndex = slots.argumentBufferIndex;
        e.computeArgumentBufferSizeIndex = slots.argumentBufferSizeIndex;
        e.computeBufferDynamicOffset = slots.bufferDynamicOffset;
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

// The minBindingSize write-back (the shader-derived minimum size the bind group checks enforce).
inline void setMinBindingSize(PipelineLayout& layout, size_t group, size_t entry, uint64_t size) { std::get<BufferBindingLayout>(layout.bindGroupLayouts[group].entries[entry].bindingMember).minBindingSize = size; }

inline void setVisibility(BindGroupLayoutEntry& entry, uint8_t rawStages) { entry.visibility = OptionSet<ShaderStage>::fromRaw(rawStages); }
inline void setBindingMember(BindGroupLayoutEntry& entry, const BufferBindingLayout& member) { entry.bindingMember = member; }
inline void setBindingMember(BindGroupLayoutEntry& entry, const SamplerBindingLayout& member) { entry.bindingMember = member; }
inline void setBindingMember(BindGroupLayoutEntry& entry, const TextureBindingLayout& member) { entry.bindingMember = member; }
inline void setBindingMember(BindGroupLayoutEntry& entry, const StorageTextureBindingLayout& member) { entry.bindingMember = member; }
inline void setBindingMember(BindGroupLayoutEntry& entry, const ExternalTextureBindingLayout& member) { entry.bindingMember = member; }

// Swift lends these spans from ContiguousArray storage (ContiguousArray.span back-deploys; Array.span
// needs macOS 26). Each is one copy; ASCII UTF-8 becomes an 8-bit String.
inline String makeStringFromUTF8(std::span<const uint8_t> utf8 NOESCAPE) { return String::fromUTF8(byteCast<char8_t>(utf8)); }
inline String makeStringFromUTF16(std::span<const char16_t> utf16 NOESCAPE) { return String(utf16); }

} // namespace Interop

} // namespace WGSL
