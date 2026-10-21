// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
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

import Testing
@_spi(Testing) import WGSL

// The ENUM_* lists of WGSLEnums.h, in C++ order: each case, its C++ spelling and its C++ underlying value.

private let addressSpaceSpellings: [(AddressSpace, String, UInt8)] = [
    (.function, "function", 0),
    (.handle, "handle", 1),
    (.private, "private", 2),
    (.storage, "storage", 3),
    (.uniform, "uniform", 4),
    (.workgroup, "workgroup", 5),
]

private let accessModeSpellings: [(AccessMode, String, UInt8)] = [
    (.read, "read", 1),
    (.readWrite, "read_write", 3),
    (.write, "write", 2),
]

private let texelFormatSpellings: [(TexelFormat, String, UInt8)] = [
    (.bgra8unorm, "bgra8unorm", 0),
    (.r16float, "r16float", 1),
    (.r16sint, "r16sint", 2),
    (.r16snorm, "r16snorm", 3),
    (.r16uint, "r16uint", 4),
    (.r16unorm, "r16unorm", 5),
    (.r32float, "r32float", 6),
    (.r32sint, "r32sint", 7),
    (.r32uint, "r32uint", 8),
    (.r8sint, "r8sint", 9),
    (.r8snorm, "r8snorm", 10),
    (.r8uint, "r8uint", 11),
    (.r8unorm, "r8unorm", 12),
    (.rg11b10ufloat, "rg11b10ufloat", 13),
    (.rg16float, "rg16float", 14),
    (.rg16sint, "rg16sint", 15),
    (.rg16snorm, "rg16snorm", 16),
    (.rg16uint, "rg16uint", 17),
    (.rg16unorm, "rg16unorm", 18),
    (.rg32float, "rg32float", 19),
    (.rg32sint, "rg32sint", 20),
    (.rg32uint, "rg32uint", 21),
    (.rg8sint, "rg8sint", 22),
    (.rg8snorm, "rg8snorm", 23),
    (.rg8uint, "rg8uint", 24),
    (.rg8unorm, "rg8unorm", 25),
    (.rgb10a2uint, "rgb10a2uint", 26),
    (.rgb10a2unorm, "rgb10a2unorm", 27),
    (.rgba16float, "rgba16float", 28),
    (.rgba16sint, "rgba16sint", 29),
    (.rgba16snorm, "rgba16snorm", 30),
    (.rgba16uint, "rgba16uint", 31),
    (.rgba16unorm, "rgba16unorm", 32),
    (.rgba32float, "rgba32float", 33),
    (.rgba32sint, "rgba32sint", 34),
    (.rgba32uint, "rgba32uint", 35),
    (.rgba8sint, "rgba8sint", 36),
    (.rgba8snorm, "rgba8snorm", 37),
    (.rgba8uint, "rgba8uint", 38),
    (.rgba8unorm, "rgba8unorm", 39),
]

private let interpolationTypeSpellings: [(InterpolationType, String, UInt8)] = [
    (.flat, "flat", 0),
    (.linear, "linear", 1),
    (.perspective, "perspective", 2),
]

private let interpolationSamplingSpellings: [(InterpolationSampling, String, UInt8)] = [
    (.center, "center", 0),
    (.centroid, "centroid", 1),
    (.either, "either", 2),
    (.first, "first", 3),
    (.sample, "sample", 4),
]

private let shaderStageSpellings: [(ShaderStage, String, UInt8)] = [
    (.compute, "compute", 4),
    (.fragment, "fragment", 2),
    (.vertex, "vertex", 1),
]

private let severityControlSpellings: [(SeverityControl, String, UInt8)] = [
    (.error, "error", 0),
    (.info, "info", 1),
    (.off, "off", 2),
    (.warning, "warning", 3),
]

private let triggeringRuleSpellings: [(TriggeringRule, String, UInt8)] = [
    (.derivativeUniformity, "derivative_uniformity", 0),
    (.subgroupUniformity, "subgroup_uniformity", 1),
]

private let builtinSpellings: [(Builtin, String, UInt8)] = [
    (.clipDistances, "clip_distances", 0),
    (.fragDepth, "frag_depth", 1),
    (.frontFacing, "front_facing", 2),
    (.globalInvocationId, "global_invocation_id", 3),
    (.instanceIndex, "instance_index", 4),
    (.localInvocationId, "local_invocation_id", 5),
    (.localInvocationIndex, "local_invocation_index", 6),
    (.numSubgroups, "num_subgroups", 7),
    (.numWorkgroups, "num_workgroups", 8),
    (.position, "position", 9),
    (.primitiveIndex, "primitive_index", 10),
    (.sampleIndex, "sample_index", 11),
    (.sampleMask, "sample_mask", 12),
    (.subgroupId, "subgroup_id", 13),
    (.subgroupInvocationId, "subgroup_invocation_id", 14),
    (.subgroupSize, "subgroup_size", 15),
    (.vertexIndex, "vertex_index", 16),
    (.workgroupId, "workgroup_id", 17),
]

private let extensionSpellings: [(Extension, String, UInt8)] = [
    (.clipDistances, "clip_distances", 1),
    (.f16, "f16", 2),
    (.primitiveIndex, "primitive_index", 4),
    (.subgroups, "subgroups", 8),
]

private let languageFeatureSpellings: [(LanguageFeature, String, UInt8)] = [
    (.packed4x8IntegerDotProduct, "packed_4x8_integer_dot_product", 1),
    (.pointerCompositeAccess, "pointer_composite_access", 2),
    (.readonlyAndReadwriteStorageTextures, "readonly_and_readwrite_storage_textures", 4),
    (.subgroupId, "subgroup_id", 32),
    (.subgroupUniformity, "subgroup_uniformity", 64),
    (.textureFormatsTier1, "texture_formats_tier1", 8),
    (.unrestrictedPointerParameters, "unrestricted_pointer_parameters", 16),
]

private func checkSpellings<Value: RawRepresentable & Equatable>(
    _ spellings: [(Value, String, UInt8)],
    _ toString: (Value) -> StaticString,
    _ parse: ([UInt16]) -> Value?,
    sourceLocation: SourceLocation = #_sourceLocation
) where Value.RawValue == UInt8 {
    for (value, spelling, rawValue) in spellings {
        #expect(toString(value).description == spelling, sourceLocation: sourceLocation)
        #expect(parse(Array(spelling.utf16)) == value, sourceLocation: sourceLocation)
        #expect(value.rawValue == rawValue, sourceLocation: sourceLocation)

        let codeUnits = Array(spelling.utf16)
        #expect(parse([]) == nil, sourceLocation: sourceLocation)
        #expect(parse(Array(codeUnits.dropLast())) == nil, sourceLocation: sourceLocation)
        #expect(parse(codeUnits + [UInt16(0)]) == nil, sourceLocation: sourceLocation)
        #expect(parse(codeUnits + Array("_".utf16)) == nil, sourceLocation: sourceLocation)
        #expect(parse(Array(spelling.uppercased().utf16)) == nil, sourceLocation: sourceLocation)
        // A 16-bit code unit whose low byte is the spelling's first character must not match.
        #expect(parse([codeUnits[0] | 0x100] + codeUnits.dropFirst()) == nil, sourceLocation: sourceLocation)
    }
}

@Suite
struct WGSLEnumsTests {
    @Test
    func addressSpace() {
        checkSpellings(addressSpaceSpellings, toString, { parseAddressSpace($0) })
        #expect(AddressSpace.allCases == addressSpaceSpellings.map(\.0))
    }

    @Test
    func accessMode() {
        checkSpellings(accessModeSpellings, toString, { parseAccessMode($0) })
        #expect(AccessMode.allCases == accessModeSpellings.map(\.0))
    }

    @Test
    func texelFormat() {
        checkSpellings(texelFormatSpellings, toString, { parseTexelFormat($0) })
        #expect(TexelFormat.allCases == texelFormatSpellings.map(\.0))
    }

    @Test
    func interpolationType() {
        checkSpellings(interpolationTypeSpellings, toString, { parseInterpolationType($0) })
    }

    @Test
    func interpolationSampling() {
        checkSpellings(interpolationSamplingSpellings, toString, { parseInterpolationSampling($0) })
    }

    @Test
    func shaderStage() {
        checkSpellings(shaderStageSpellings, toString, { parseShaderStage($0) })
        #expect(ShaderStages(.compute).rawValue == 4)
        #expect(ShaderStages(.fragment).rawValue == 2)
        #expect(ShaderStages(.vertex).rawValue == 1)
    }

    @Test
    func severityControl() {
        checkSpellings(severityControlSpellings, toString, { parseSeverityControl($0) })
        #expect(SeverityControl.allCases == severityControlSpellings.map(\.0))
    }

    @Test
    func triggeringRule() {
        checkSpellings(triggeringRuleSpellings, toString, { parseTriggeringRule($0) })
        #expect(TriggeringRule.allCases == triggeringRuleSpellings.map(\.0))
    }

    @Test
    func builtin() {
        checkSpellings(builtinSpellings, toString, { parseBuiltin($0) })
        #expect(Builtin.allCases == builtinSpellings.map(\.0))
    }

    @Test
    func extensions() {
        checkSpellings(extensionSpellings, toString, { parseExtension($0) })
        #expect(Extension.allCases == extensionSpellings.map(\.0))
        // WTF::OptionSet iterates in ascending bit order, which is the declaration order here.
        #expect(Extension.allCases.map(\.rawValue) == Extension.allCases.map(\.rawValue).sorted())
        var extensions = Extensions()
        extensions.insert(.subgroups)
        extensions.insert(Extensions(.f16))
        #expect(extensions.rawValue == 0b1010)
        #expect(extensions.contains(.f16))
        #expect(!extensions.contains(.clipDistances))
    }

    @Test
    func languageFeature() {
        checkSpellings(languageFeatureSpellings, toString, { parseLanguageFeature($0) })
        #expect(LanguageFeature.allCases == languageFeatureSpellings.map(\.0))
        var features = LanguageFeatures()
        for feature in LanguageFeature.allCases {
            features.insert(LanguageFeatures(feature))
        }
        #expect(features.rawValue == 0x7F)
        #expect(LanguageFeatures.textureFormatsTier1.rawValue == 1 << 3)
    }

    @Test
    func parseAcceptsAnyCodeUnitCollection() {
        #expect(parseAccessMode("read_write".utf16) == .readWrite)
        #expect(parseAccessMode(ContiguousArray("read_write".utf16)) == .readWrite)
        #expect(parseAccessMode(Array("xread_writex".utf16)[1..<11]) == .readWrite)
        #expect(parseAccessMode(Array("xread_writex".utf16)[1..<5]) == .read)
        #expect(parseAccessMode("ReadWrite".utf16) == nil)
        #expect(parseTexelFormat("BGRA8unorm".utf16) == nil)
        #expect(parseAddressSpace("Function".utf16) == nil)
    }

    @Test
    func defaultAccessModeForAddressSpaceMatchesCpp() {
        #expect(defaultAccessModeForAddressSpace(.function) == .readWrite)
        #expect(defaultAccessModeForAddressSpace(.private) == .readWrite)
        #expect(defaultAccessModeForAddressSpace(.workgroup) == .readWrite)
        #expect(defaultAccessModeForAddressSpace(.uniform) == .read)
        #expect(defaultAccessModeForAddressSpace(.storage) == .read)
        #expect(defaultAccessModeForAddressSpace(.handle) == .read)
    }
}
