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

// The black-box WGSLDUMP 1 dumper: the WGSLJOB 1 plan parser, the dump writer, and the check, reflect and units layers through the
// public API, except for the Testing SPI's generate, which also gives the override map after a failed generate. The goldens'
// expected dumps were written in the same grammar by a C++ dumper over the C++ compiler. A job asking for any other layer, or
// for a `stop-after`, is a tool error.

import Foundation
@_spi(Testing) import WGSL

// MARK: - Job (WGSLJOB 1)

/// A layer name of the `layers` job line.
enum WGSLDumpLayer: CaseIterable, Hashable, Sendable {
    case tokens
    case astParse
    case check
    case reflect
    case units
    case astCheck
    case astPrepare
    case wgExpr
    case specDefault
    case irAnnot

    var name: String {
        switch self {
        case .tokens: "tokens"
        case .astParse: "ast.parse"
        case .check: "check"
        case .reflect: "reflect"
        case .units: "units"
        case .astCheck: "ast.check"
        case .astPrepare: "ast.prepare"
        case .wgExpr: "wg.expr"
        case .specDefault: "spec.default"
        case .irAnnot: "ir.annot"
        }
    }
}

/// A `stop-after` pass: the WGSL::StaticCheckPass names, then the prepare passes.
enum WGSLDumpPass: CaseIterable, Hashable, Sendable {
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
    case insertBoundsChecks
    case rewriteEntryPoints
    case rewriteGlobalVariables

    var name: String {
        switch self {
        case .parse: "parse"
        case .reorderGlobals: "reorderGlobals"
        case .typeCheck: "typeCheck"
        case .validateAttributes: "validateAttributes"
        case .buildCallGraph: "buildCallGraph"
        case .validateIO: "validateIO"
        case .validateVisibility: "validateVisibility"
        case .mangleNames: "mangleNames"
        case .rewriteEvaluationOrder: "rewriteEvaluationOrder"
        case .rewritePointers: "rewritePointers"
        case .aliasAnalysis: "aliasAnalysis"
        case .uniformityAnalysis: "uniformityAnalysis"
        case .insertBoundsChecks: "insertBoundsChecks"
        case .rewriteEntryPoints: "rewriteEntryPoints"
        case .rewriteGlobalVariables: "rewriteGlobalVariables"
        }
    }

    var isPreparePass: Bool {
        switch self {
        case .insertBoundsChecks, .rewriteEntryPoints, .rewriteGlobalVariables: true
        case .parse, .reorderGlobals, .typeCheck, .validateAttributes, .buildCallGraph, .validateIO, .validateVisibility, .mangleNames,
            .rewriteEvaluationOrder, .rewritePointers, .aliasAnalysis, .uniformityAnalysis:
            false
        }
    }
}

/// Why a job text is not a WGSLJOB 1.
struct WGSLDumpJobError: Error {
    let reason: String
}

/// A parsed WGSLJOB 1, kept as written so that `serialized()` reproduces the text.
struct WGSLDumpJob: Hashable, Sendable {
    enum Encoding: CaseIterable, Hashable, Sendable {
        case wtfUTF8Latin1
        case latin1
        case utf16LE
        case force16
        case wtfUTF8Strict

        var name: String {
            switch self {
            case .wtfUTF8Latin1: "wtf-utf8-latin1"
            case .latin1: "latin1"
            case .utf16LE: "utf16le"
            case .force16: "force16"
            case .wtfUTF8Strict: "wtf-utf8-strict"
            }
        }
    }

    enum Source: Hashable, Sendable {
        case file(path: [UInt16])
        case inline([UInt8])
    }

    struct ConfigSpec: Hashable, Sendable {
        var vtx: UInt32 = 8
        var frag: UInt32 = 8
        var comp: UInt32 = 8
        var wgmem: UInt32 = 16_384
        var features: [[UInt8]] = []
    }

    enum MSLMode: Hashable, Sendable {
        case full
        case hash
        case none
    }

    struct ConstantRequest: Hashable, Sendable {
        var key: [UInt16]
        var bits: UInt64

        var value: Double { Double(bitPattern: bits) }
    }

    struct GenerateRequest: Hashable, Sendable {
        var family: UInt32 = 4
        var validation = false
        var msl = MSLMode.full
        var constants: [ConstantRequest] = []
    }

    enum EntryPointKind: Hashable, Sendable {
        case named([UInt16])
        case all
        case defaultEntryPoint(ShaderStage)
    }

    struct EntryPointRequest: Hashable, Sendable {
        var kind: EntryPointKind
        /// An index into `layouts`; nil is `auto`.
        var layout: Int?
    }

    struct UnitRequest: Hashable, Sendable {
        var entryPoints: [EntryPointRequest] = []
        var generates: [GenerateRequest] = []
        /// Nil when the unit has no `evaluate` line.
        var evaluate: Bool?
    }

    struct Layout: Hashable, Sendable {
        var id: [UInt8]
        var layout: PipelineLayout
    }

    var id: [UInt16] = []
    var source = Source.inline([])
    var encoding = Encoding.wtfUTF8Latin1
    /// The text after `config `, as written.
    var configText: [UInt8] = []
    var config = ConfigSpec()
    /// As written, duplicates included.
    var layers: [WGSLDumpLayer] = []
    var stopAfter: WGSLDumpPass?
    var layouts: [Layout] = []
    var units: [UnitRequest] = []

    func has(_ layer: WGSLDumpLayer) -> Bool { layers.contains(layer) }

    func layoutIndex(_ id: some Collection<UInt8>) -> Int? { layouts.firstIndex { $0.id.elementsEqual(id) } }
}

private let webgpuFeatures: [String] = [
    "shader-f16", "clip-distances", "subgroups", "primitive-index", "depth-clip-control", "depth32float-stencil8",
    "texture-compression-bc", "texture-compression-etc2", "texture-compression-astc", "timestamp-query",
    "indirect-first-instance", "rg11b10ufloat-renderable", "bgra8unorm-storage", "float32-filterable",
    "float32-blendable", "dual-source-blending", "texture-formats-tier1", "texture-formats-tier2",
    "core-features-and-limits",
]

private func features(_ names: [String]) -> [[UInt8]] { names.map { Array($0.utf8) } }

private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

private func asciiBytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// A configuration preset, or `custom k=v ...`.
private func parsePresetOrCustomConfig(_ value: [UInt8]) -> WGSLDumpJob.ConfigSpec? {
    var config = WGSLDumpJob.ConfigSpec()
    switch String(decoding: value, as: UTF8.self) {
    case "tests":
        config.features = features(["shader-f16", "clip-distances", "primitive-index"])
        return config
    case "tests-nofeatures", "default":
        return config
    case "wgslc":
        config.features = features(["shader-f16", "clip-distances", "subgroups"])
        return config
    case "webgpu":
        config = WGSLDumpJob.ConfigSpec(vtx: 30, frag: 11, comp: 11, wgmem: 32_768, features: features(webgpuFeatures))
        return config
    case "small":
        config = WGSLDumpJob.ConfigSpec(vtx: 4, frag: 4, comp: 4, wgmem: 1024, features: features(["shader-f16"]))
        return config
    default:
        break
    }
    guard value.starts(with: asciiBytes("custom")) else {
        return nil
    }
    var rest = value.dropFirst(6)
    var sawAny = false
    while !rest.isEmpty {
        guard rest.first == 0x20 else {
            return nil
        }
        rest = rest.dropFirst()
        let item = rest.prefix { $0 != 0x20 }
        rest = rest.dropFirst(item.count)
        guard let eq = item.firstIndex(of: 0x3D) else {
            return nil
        }
        let key = String(decoding: item[item.startIndex..<eq], as: UTF8.self)
        let val = item[item.index(after: eq)...]
        func number() -> UInt32? {
            guard !val.isEmpty, val.count <= 10, val.allSatisfy(isDigit) else {
                return nil
            }
            var n: UInt64 = 0
            for c in val {
                n = n * 10 + UInt64(c - 0x30)
            }
            return UInt32(exactly: n)
        }
        switch key {
        case "vtx":
            guard let n = number() else {
                return nil
            }
            config.vtx = n
        case "frag":
            guard let n = number() else {
                return nil
            }
            config.frag = n
        case "comp":
            guard let n = number() else {
                return nil
            }
            config.comp = n
        case "wgmem":
            guard let n = number() else {
                return nil
            }
            config.wgmem = n
        case "features":
            config.features = []
            if !val.elementsEqual([0x2D]) && !val.isEmpty {
                config.features = val.split(separator: 0x2C, omittingEmptySubsequences: false).map { Array($0) }
            }
        default:
            return nil
        }
        sawAny = true
    }
    return sawAny ? config : nil
}

// MARK: - Enum spellings

private func bufferTypeName(_ type: BufferBindingType) -> String {
    switch type {
    case .uniform: "Uniform"
    case .storage: "Storage"
    case .readOnlyStorage: "ReadOnlyStorage"
    }
}

private func samplerTypeName(_ type: SamplerBindingType) -> String {
    switch type {
    case .filtering: "Filtering"
    case .nonFiltering: "NonFiltering"
    case .comparison: "Comparison"
    }
}

private func sampleTypeName(_ type: TextureSampleType) -> String {
    switch type {
    case .float: "Float"
    case .unfilterableFloat: "UnfilterableFloat"
    case .depth: "Depth"
    case .signedInt: "SignedInt"
    case .unsignedInt: "UnsignedInt"
    }
}

private func viewDimensionName(_ dimension: TextureViewDimension) -> String {
    switch dimension {
    case .oneDimensional: "OneDimensional"
    case .twoDimensional: "TwoDimensional"
    case .twoDimensionalArray: "TwoDimensionalArray"
    case .cube: "Cube"
    case .cubeArray: "CubeArray"
    case .threeDimensional: "ThreeDimensional"
    }
}

private func accessName(_ access: StorageTextureAccess) -> String {
    switch access {
    case .writeOnly: "WriteOnly"
    case .readOnly: "ReadOnly"
    case .readWrite: "ReadWrite"
    }
}

private func texelFormatName(_ format: TexelFormat) -> String {
    switch format {
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

private func stageName(_ stage: ShaderStage) -> String {
    switch stage {
    case .vertex: "vertex"
    case .fragment: "fragment"
    case .compute: "compute"
    }
}

private func interpolationTypeName(_ type: InterpolationType) -> String {
    switch type {
    case .flat: "flat"
    case .linear: "linear"
    case .perspective: "perspective"
    }
}

private func interpolationSamplingName(_ sampling: InterpolationSampling) -> String {
    switch sampling {
    case .center: "center"
    case .centroid: "centroid"
    case .either: "either"
    case .first: "first"
    case .sample: "sample"
    }
}

func specializationTypeName(_ type: SpecializationConstantType) -> String {
    switch type {
    case .boolean: "Boolean"
    case .float: "Float"
    case .int: "Int"
    case .unsigned: "Unsigned"
    case .half: "Half"
    }
}

private let bufferTypes: [BufferBindingType] = [.uniform, .storage, .readOnlyStorage]
private let samplerTypes: [SamplerBindingType] = [.filtering, .nonFiltering, .comparison]
private let sampleTypes: [TextureSampleType] = [.float, .unfilterableFloat, .depth, .signedInt, .unsignedInt]
private let viewDimensions: [TextureViewDimension] = [
    .oneDimensional, .twoDimensional, .twoDimensionalArray, .cube, .cubeArray, .threeDimensional,
]
private let accesses: [StorageTextureAccess] = [.writeOnly, .readOnly, .readWrite]
private let stages: [ShaderStage] = [.vertex, .fragment, .compute]

private func lookupEnum<E>(_ word: some Collection<UInt8>, _ table: [E], _ name: (E) -> String) -> E? {
    table.first { name($0).utf8.elementsEqual(word) }
}

// MARK: - Writer

let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// The body of a STR (no quotes) over UTF-16 code units.
private func appendEscaped(_ out: inout [UInt8], _ units: some Sequence<UInt16>) {
    for unit in units {
        switch unit {
        case 0x22:
            out.append(contentsOf: [0x5C, 0x22])
            continue
        case 0x5C:
            out.append(contentsOf: [0x5C, 0x5C])
            continue
        case 0x0A:
            out.append(contentsOf: [0x5C, 0x6E])
            continue
        case 0x09:
            out.append(contentsOf: [0x5C, 0x74])
            continue
        case 0x0D:
            out.append(contentsOf: [0x5C, 0x72])
            continue
        default:
            break
        }
        if unit >= 0x20 && unit <= 0x7E {
            out.append(UInt8(unit))
            continue
        }
        out.append(contentsOf: [0x5C, 0x75])
        out.append(hexDigits[Int((unit >> 12) & 0xF)])
        out.append(hexDigits[Int((unit >> 8) & 0xF)])
        out.append(hexDigits[Int((unit >> 4) & 0xF)])
        out.append(hexDigits[Int(unit & 0xF)])
    }
}

/// The UTF-8 encoding when the units are well-formed UTF-16.
private func wellFormedUTF8(_ units: some Collection<UInt16>) -> [UInt8]? {
    var out: [UInt8] = []
    out.reserveCapacity(units.count)
    var index = units.startIndex
    while index != units.endIndex {
        var c = UInt32(units[index])
        if c >= 0xD800 && c <= 0xDBFF {
            let next = units.index(after: index)
            guard next != units.endIndex else {
                return nil
            }
            let d = UInt32(units[next])
            guard d >= 0xDC00 && d <= 0xDFFF else {
                return nil
            }
            c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)
            index = next
        } else if c >= 0xDC00 && c <= 0xDFFF {
            return nil
        }
        if c < 0x80 {
            out.append(UInt8(c))
        } else if c < 0x800 {
            out.append(UInt8(0xC0 | (c >> 6)))
            out.append(UInt8(0x80 | (c & 0x3F)))
        } else if c < 0x10000 {
            out.append(UInt8(0xE0 | (c >> 12)))
            out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (c & 0x3F)))
        } else {
            out.append(UInt8(0xF0 | (c >> 18)))
            out.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (c & 0x3F)))
        }
        index = units.index(after: index)
    }
    return out
}

/// The bytes a BLOCK carries for these units, and whether its encoding is `utf8`.
func blockPayload(_ units: some Collection<UInt16>) -> (isUTF8: Bool, bytes: [UInt8]) {
    if let utf8 = wellFormedUTF8(units) {
        return (true, utf8)
    }
    var escaped: [UInt8] = []
    appendEscaped(&escaped, units)
    return (false, escaped)
}

/// The BLOCK payload of UTF-8 bytes (generated MSL): the bytes themselves when they are valid UTF-8.
func blockPayload(utf8 bytes: some Collection<UInt8>) -> (isUTF8: Bool, bytes: [UInt8]) {
    guard let string = String(validating: bytes, as: UTF8.self) else {
        return blockPayload(String(decoding: bytes, as: UTF8.self).utf16)
    }
    return blockPayload(string.utf16)
}

/// A dump being written: the WGSLDUMP 1 spellings, the layers the job asked for, and the in-flight section hook.
struct WGSLDumpOutput {
    private(set) var bytes: [UInt8] = []
    let layers: [WGSLDumpLayer]
    /// Called with the dump so far each time a section completes.
    var sectionCompleted: (([UInt8]) -> Void)?

    init(layers: [WGSLDumpLayer], sectionCompleted: (([UInt8]) -> Void)? = nil) {
        self.layers = layers
        self.sectionCompleted = sectionCompleted
    }

    func has(_ layer: WGSLDumpLayer) -> Bool { layers.contains(layer) }

    mutating func section() { sectionCompleted?(bytes) }

    mutating func raw(_ text: String) { bytes.append(contentsOf: text.utf8) }

    mutating func raw(bytes text: some Sequence<UInt8>) { bytes.append(contentsOf: text) }

    mutating func ch(_ c: UInt8) { bytes.append(c) }

    mutating func nl() { bytes.append(0x0A) }

    mutating func u(_ value: some UnsignedInteger) { bytes.append(contentsOf: String(value).utf8) }

    mutating func i(_ value: Int64) { bytes.append(contentsOf: String(value).utf8) }

    mutating func b(_ value: Bool) { bytes.append(value ? 0x31 : 0x30) }

    mutating func opt(_ value: UInt32?) {
        guard let value else {
            ch(0x2D)
            return
        }
        u(value)
    }

    mutating func quoted(_ units: some Sequence<UInt16>) {
        ch(0x22)
        appendEscaped(&bytes, units)
        ch(0x22)
    }

    mutating func quoted(_ name: Name) { quoted(name.utf16) }

    mutating func quoted(_ string: String) { quoted(string.utf16) }

    mutating func span(_ s: SourceSpan) {
        u(s.line)
        ch(0x3A)
        u(s.lineOffset)
        ch(0x3A)
        u(s.offset)
        ch(0x3A)
        u(s.length)
    }

    /// "utf8 N\n<bytes>\n" or "esc N\n<bytes>\n".
    mutating func block(_ units: some Collection<UInt16>) { block(payload: blockPayload(units)) }

    mutating func block(payload: (isUTF8: Bool, bytes: [UInt8])) {
        raw(payload.isUTF8 ? "utf8 " : "esc ")
        u(UInt(payload.bytes.count))
        nl()
        bytes.append(contentsOf: payload.bytes)
        nl()
    }

    mutating func hex(_ value: UInt64, digits: Int) {
        raw("0x")
        var shift = (digits - 1) * 4
        while shift >= 0 {
            ch(hexDigits[Int((value >> UInt64(shift)) & 0xF)])
            shift -= 4
        }
    }

    /// CV of a scalar.
    mutating func constant(_ value: ScalarValue) {
        switch value {
        case .f32(let v):
            raw("f32:")
            hex(UInt64(v.bitPattern), digits: 8)
        case .f16(let bits):
            raw("f16:")
            hex(UInt64(bits), digits: 4)
        case .abstractFloat(let v):
            raw("f64:")
            hex(v.bitPattern, digits: 16)
        case .i32(let v):
            raw("i32:")
            i(Int64(v))
        case .u32(let v):
            raw("u32:")
            u(v)
        case .abstractInt(let v):
            raw("i64:")
            i(v)
        case .bool(let v):
            raw(v ? "bool:true" : "bool:false")
        }
    }
}

// MARK: - Layout text (ENTIN/ENTOUT)

private func writeMember(_ w: inout WGSLDumpOutput, _ member: BindingMember) {
    switch member {
    case .buffer(let buffer):
        w.raw("buffer type=")
        w.raw(bufferTypeName(buffer.type))
        w.raw(" dyn=")
        w.b(buffer.hasDynamicOffset)
        w.raw(" min=")
        w.u(buffer.minBindingSize)
    case .sampler(let type):
        w.raw("sampler type=")
        w.raw(samplerTypeName(type))
    case .texture(let texture):
        w.raw("texture sample=")
        w.raw(sampleTypeName(texture.sampleType))
        w.raw(" dim=")
        w.raw(viewDimensionName(texture.viewDimension))
        w.raw(" ms=")
        w.b(texture.multisampled)
    case .storageTexture(let texture):
        w.raw("storage-texture access=")
        w.raw(accessName(texture.access))
        w.raw(" format=")
        w.raw(texelFormatName(texture.format))
        w.raw(" dim=")
        w.raw(viewDimensionName(texture.viewDimension))
    case .externalTexture:
        w.raw("external-texture")
    }
}

private func writeIndices(_ w: inout WGSLDumpOutput, vertex: StageSlots, fragment: StageSlots, compute: StageSlots) {
    w.raw("vab=")
    w.opt(vertex.argumentBufferIndex)
    w.raw(" vabs=")
    w.opt(vertex.argumentBufferSizeIndex)
    w.raw(" vdo=")
    w.opt(vertex.bufferDynamicOffset)
    w.raw(" fab=")
    w.opt(fragment.argumentBufferIndex)
    w.raw(" fabs=")
    w.opt(fragment.argumentBufferSizeIndex)
    w.raw(" fdo=")
    w.opt(fragment.bufferDynamicOffset)
    w.raw(" cab=")
    w.opt(compute.argumentBufferIndex)
    w.raw(" cabs=")
    w.opt(compute.argumentBufferSizeIndex)
    w.raw(" cdo=")
    w.opt(compute.bufferDynamicOffset)
}

private func writeLayoutBlock(_ w: inout WGSLDumpOutput, _ id: [UInt8], _ layout: PipelineLayout) {
    w.raw("layout ")
    w.raw(bytes: id)
    w.nl()
    for bgl in layout.bindGroupLayouts {
        w.raw("  bgl")
        w.nl()
        for entry in bgl.entries {
            w.raw("    ent binding=")
            w.u(entry.binding)
            w.raw(" vis=")
            w.u(entry.visibility.rawValue)
            w.ch(0x20)
            writeMember(&w, entry.bindingMember)
            w.ch(0x20)
            writeIndices(&w, vertex: entry.vertex, fragment: entry.fragment, compute: entry.compute)
            w.nl()
        }
    }
}

// MARK: - Parser

/// A cursor over one line of plan text.
private struct Cursor {
    var rest: ArraySlice<UInt8>

    init(_ line: ArraySlice<UInt8>) { rest = line }

    var atEnd: Bool { rest.isEmpty }

    mutating func literal(_ text: String) -> Bool {
        guard rest.starts(with: text.utf8) else {
            return false
        }
        rest = rest.dropFirst(text.utf8.count)
        return true
    }

    /// Up to the next space (or end).
    mutating func word() -> ArraySlice<UInt8> {
        let result = rest.prefix { $0 != 0x20 }
        rest = rest.dropFirst(result.count)
        return result
    }

    mutating func number() -> UInt64? {
        var value: UInt64 = 0
        var n = 0
        for c in rest {
            guard isDigit(c) else {
                break
            }
            guard value <= (UInt64.max - 9) / 10 else {
                return nil
            }
            value = value * 10 + UInt64(c - 0x30)
            n += 1
        }
        guard n > 0 else {
            return nil
        }
        rest = rest.dropFirst(n)
        return value
    }

    mutating func number32() -> UInt32? {
        guard let value = number() else {
            return nil
        }
        return UInt32(exactly: value)
    }

    mutating func boolean() -> Bool? {
        if literal("0") {
            return false
        }
        if literal("1") {
            return true
        }
        return nil
    }

    mutating func optional32() -> UInt32?? {
        if literal("-") {
            return .some(nil)
        }
        guard let value = number32() else {
            return nil
        }
        return .some(value)
    }

    mutating func hex64() -> UInt64? {
        guard literal("0x"), rest.count >= 16 else {
            return nil
        }
        var value: UInt64 = 0
        for c in rest.prefix(16) {
            guard let digit = hexDigitValue(c, uppercase: false) else {
                return nil
            }
            value = (value << 4) | UInt64(digit)
        }
        rest = rest.dropFirst(16)
        return value
    }

    mutating func quoted() -> [UInt16]? {
        guard literal("\"") else {
            return nil
        }
        var units: [UInt16] = []
        while true {
            guard let c = rest.first else {
                return nil
            }
            rest = rest.dropFirst()
            if c == 0x22 {
                break
            }
            if c != 0x5C {
                guard c >= 0x20 && c <= 0x7E else {
                    return nil
                }
                units.append(UInt16(c))
                continue
            }
            guard let e = rest.first else {
                return nil
            }
            rest = rest.dropFirst()
            switch e {
            case 0x22: units.append(0x22)
            case 0x5C: units.append(0x5C)
            case 0x6E: units.append(0x0A)
            case 0x74: units.append(0x09)
            case 0x72: units.append(0x0D)
            case 0x75:
                guard rest.count >= 4 else {
                    return nil
                }
                var value: UInt16 = 0
                for h in rest.prefix(4) {
                    guard let digit = hexDigitValue(h, uppercase: true) else {
                        return nil
                    }
                    value = (value << 4) | UInt16(digit)
                }
                rest = rest.dropFirst(4)
                units.append(value)
            default:
                return nil
            }
        }
        return units
    }
}

private func hexDigitValue(_ c: UInt8, uppercase: Bool) -> UInt8? {
    if c >= 0x30 && c <= 0x39 {
        return c - 0x30
    }
    if c >= 0x61 && c <= 0x66 {
        return c - 0x61 + 10
    }
    if uppercase && c >= 0x41 && c <= 0x46 {
        return c - 0x41 + 10
    }
    return nil
}

private func parseMember(_ cursor: inout Cursor) -> BindingMember? {
    if cursor.literal("buffer type=") {
        guard let type = lookupEnum(cursor.word(), bufferTypes, bufferTypeName),
            cursor.literal(" dyn="), let dynamic = cursor.boolean(), cursor.literal(" min="), let min = cursor.number()
        else {
            return nil
        }
        return .buffer(BufferBindingLayout(type: type, hasDynamicOffset: dynamic, minBindingSize: min))
    }
    if cursor.literal("sampler type=") {
        guard let type = lookupEnum(cursor.word(), samplerTypes, samplerTypeName) else {
            return nil
        }
        return .sampler(type)
    }
    if cursor.literal("texture sample=") {
        guard let sampleType = lookupEnum(cursor.word(), sampleTypes, sampleTypeName),
            cursor.literal(" dim="), let dimension = lookupEnum(cursor.word(), viewDimensions, viewDimensionName),
            cursor.literal(" ms="), let multisampled = cursor.boolean()
        else {
            return nil
        }
        return .texture(TextureBindingLayout(sampleType: sampleType, viewDimension: dimension, multisampled: multisampled))
    }
    if cursor.literal("storage-texture access=") {
        guard let access = lookupEnum(cursor.word(), accesses, accessName),
            cursor.literal(" format="), let format = lookupEnum(cursor.word(), TexelFormat.allCases, texelFormatName),
            cursor.literal(" dim="), let dimension = lookupEnum(cursor.word(), viewDimensions, viewDimensionName)
        else {
            return nil
        }
        return .storageTexture(StorageTextureBindingLayout(access: access, format: format, viewDimension: dimension))
    }
    if cursor.literal("external-texture") {
        return .externalTexture
    }
    return nil
}

private func parseIndices(_ cursor: inout Cursor) -> (vertex: StageSlots, fragment: StageSlots, compute: StageSlots)? {
    func slots(_ prefix: String) -> StageSlots? {
        guard cursor.literal(" \(prefix)ab="), let index = cursor.optional32(),
            cursor.literal(" \(prefix)abs="), let sizeIndex = cursor.optional32(),
            cursor.literal(" \(prefix)do="), let dynamicOffset = cursor.optional32()
        else {
            return nil
        }
        return StageSlots(argumentBufferIndex: index, argumentBufferSizeIndex: sizeIndex, bufferDynamicOffset: dynamicOffset)
    }
    guard let vertex = slots("v"), let fragment = slots("f"), let compute = slots("c") else {
        return nil
    }
    return (vertex, fragment, compute)
}

private func validLayoutID(_ id: some Collection<UInt8>) -> Bool {
    !id.isEmpty && id.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || isDigit($0) || $0 == 0x5F }
}

extension WGSLDumpJob {
    /// Parses a WGSLJOB 1 job.
    static func parse(_ text: [UInt8]) throws(WGSLDumpJobError) -> WGSLDumpJob {
        var job = WGSLDumpJob()
        var position = 0
        var lineNumber = 0
        func fail(_ reason: String) -> WGSLDumpJobError { WGSLDumpJobError(reason: "line \(lineNumber): \(reason)") }
        func nextLine() -> ArraySlice<UInt8>? {
            guard position < text.count, let end = text[position...].firstIndex(of: 0x0A) else {
                return nil
            }
            let line = text[position..<end]
            position = end + 1
            lineNumber += 1
            return line
        }

        guard let header = nextLine(), header.elementsEqual("WGSLJOB 1".utf8) else {
            throw fail("expected 'WGSLJOB 1'")
        }

        guard let idLine = nextLine() else {
            throw fail("expected id")
        }
        var c = Cursor(idLine)
        guard c.literal("id "), let id = c.quoted(), c.atEnd else {
            throw fail("bad id line")
        }
        job.id = id

        guard let sourceLine = nextLine() else {
            throw fail("expected source")
        }
        c = Cursor(sourceLine)
        if c.literal("source-file ") {
            guard let path = c.quoted(), c.atEnd else {
                throw fail("bad source-file line")
            }
            job.source = .file(path: path)
        } else if c.literal("source-inline ") {
            guard let length = c.number(), c.atEnd else {
                throw fail("bad source-inline line")
            }
            guard let count = Int(exactly: length), count < text.count - position, text[position + count] == 0x0A else {
                throw fail("source-inline length mismatch")
            }
            job.source = .inline(Array(text[position..<position + count]))
            position += count + 1
        } else {
            throw fail("expected source-file or source-inline")
        }

        guard let encodingLine = nextLine() else {
            throw fail("expected encoding")
        }
        c = Cursor(encodingLine)
        guard c.literal("encoding ") else {
            throw fail("expected encoding")
        }
        guard let encoding = lookupEnum(c.word(), Encoding.allCases, \.name) else {
            throw fail("unknown encoding")
        }
        guard c.atEnd else {
            throw fail("trailing text after encoding")
        }
        job.encoding = encoding

        guard let configLine = nextLine(), configLine.starts(with: "config ".utf8) else {
            throw fail("expected config")
        }
        job.configText = Array(configLine.dropFirst(7))
        guard let config = parsePresetOrCustomConfig(job.configText) else {
            throw fail("bad config")
        }
        job.config = config

        guard let layersLine = nextLine(), layersLine.starts(with: "layers ".utf8) else {
            throw fail("expected layers")
        }
        for layer in layersLine.dropFirst(7).split(separator: 0x2C, omittingEmptySubsequences: false) {
            guard let known = lookupEnum(layer, WGSLDumpLayer.allCases, \.name) else {
                throw fail("unknown layer \(String(decoding: layer, as: UTF8.self))")
            }
            job.layers.append(known)
        }

        enum State {
            case header
            case layouts
            case units
        }
        var state = State.header
        var unitHasEvaluate = false
        var sawEnd = false
        while let line = nextLine() {
            if line.elementsEqual("end".utf8) {
                sawEnd = true
                break
            }
            c = Cursor(line)
            if c.literal("stop-after ") {
                guard state == .header, job.stopAfter == nil else {
                    throw fail("stop-after must follow layers")
                }
                guard let pass = lookupEnum(c.word(), WGSLDumpPass.allCases, \.name), c.atEnd else {
                    throw fail("unknown stop-after pass")
                }
                job.stopAfter = pass
                continue
            }
            if c.literal("layout ") {
                guard state != .units else {
                    throw fail("layout after unit")
                }
                state = .layouts
                let id = c.word()
                guard validLayoutID(id), c.atEnd else {
                    throw fail("bad layout id")
                }
                guard job.layoutIndex(id) == nil else {
                    throw fail("duplicate layout id")
                }
                job.layouts.append(Layout(id: Array(id), layout: PipelineLayout()))
                continue
            }
            if line.elementsEqual("  bgl".utf8) {
                guard state == .layouts, !job.layouts.isEmpty else {
                    throw fail("bgl outside layout")
                }
                let last = job.layouts.count - 1
                let group = UInt32(job.layouts[last].layout.bindGroupLayouts.count)
                job.layouts[last].layout.bindGroupLayouts.append(BindGroupLayout(group: group, entries: []))
                continue
            }
            if c.literal("    ent binding=") {
                guard state == .layouts, let last = job.layouts.indices.last,
                    !job.layouts[last].layout.bindGroupLayouts.isEmpty
                else {
                    throw fail("ent outside bgl")
                }
                guard let binding = c.number32(), c.literal(" vis="), let visibility = c.number32(), visibility <= 7, c.literal(" ") else {
                    throw fail("bad ent")
                }
                guard let member = parseMember(&c), let indices = parseIndices(&c), c.atEnd else {
                    throw fail("bad ent member/indices")
                }
                let entry = BindGroupLayoutEntry(
                    binding: binding,
                    webBinding: 0,
                    visibility: ShaderStages(rawValue: UInt8(visibility)),
                    bindingMember: member,
                    name: "",
                    vertex: indices.vertex,
                    fragment: indices.fragment,
                    compute: indices.compute
                )
                let group = job.layouts[last].layout.bindGroupLayouts.count - 1
                job.layouts[last].layout.bindGroupLayouts[group].entries.append(entry)
                continue
            }
            if line.elementsEqual("unit".utf8) {
                state = .units
                job.units.append(UnitRequest())
                unitHasEvaluate = false
                continue
            }
            if c.literal("  ep ") {
                guard let unit = job.units.indices.last, job.units[unit].generates.isEmpty, !unitHasEvaluate else {
                    throw fail("ep outside unit or after generate")
                }
                let kind: EntryPointKind
                if c.literal("@all") {
                    kind = .all
                } else if c.literal("@default:") {
                    guard let stage = lookupEnum(c.word(), stages, stageName) else {
                        throw fail("bad @default stage")
                    }
                    kind = .defaultEntryPoint(stage)
                } else if let name = c.quoted() {
                    kind = .named(name)
                } else {
                    throw fail("bad ep name")
                }
                guard c.literal(" layout=") else {
                    throw fail("expected layout=")
                }
                let layoutName = c.word()
                var layout: Int?
                if !layoutName.elementsEqual("auto".utf8) {
                    guard let index = job.layoutIndex(layoutName) else {
                        throw fail("unknown layout \(String(decoding: layoutName, as: UTF8.self))")
                    }
                    layout = index
                }
                guard c.atEnd else {
                    throw fail("trailing text after ep")
                }
                job.units[unit].entryPoints.append(EntryPointRequest(kind: kind, layout: layout))
                continue
            }
            if c.literal("  generate family=") {
                guard let unit = job.units.indices.last, !job.units[unit].entryPoints.isEmpty, !unitHasEvaluate else {
                    throw fail("generate outside unit")
                }
                guard let family = c.number32(), c.literal(" validation="), let validation = c.boolean(), c.literal(" msl=") else {
                    throw fail("bad generate")
                }
                let mode: MSLMode
                switch String(decoding: c.word(), as: UTF8.self) {
                case "full": mode = .full
                case "hash": mode = .hash
                case "none": mode = .none
                default: throw fail("bad msl mode")
                }
                guard c.atEnd else {
                    throw fail("trailing text after generate")
                }
                job.units[unit].generates.append(GenerateRequest(family: family, validation: validation, msl: mode))
                continue
            }
            if c.literal("    const ") {
                guard let unit = job.units.indices.last, let generate = job.units[unit].generates.indices.last else {
                    throw fail("const outside generate")
                }
                guard let key = c.quoted(), c.literal(" "), let bits = c.hex64(), c.atEnd else {
                    throw fail("bad const")
                }
                job.units[unit].generates[generate].constants.append(ConstantRequest(key: key, bits: bits))
                continue
            }
            if c.literal("  evaluate ") {
                guard let unit = job.units.indices.last, !job.units[unit].entryPoints.isEmpty, !unitHasEvaluate else {
                    throw fail("evaluate outside unit")
                }
                guard let evaluate = c.boolean(), c.atEnd else {
                    throw fail("bad evaluate")
                }
                job.units[unit].evaluate = evaluate
                unitHasEvaluate = true
                continue
            }
            throw fail("unexpected line")
        }
        guard sawEnd else {
            throw fail("missing end")
        }
        guard position == text.count else {
            throw fail("trailing bytes after end")
        }
        for unit in job.units {
            guard !unit.entryPoints.isEmpty else {
                throw fail("unit without ep")
            }
            let hasConstants = unit.generates.contains { !$0.constants.isEmpty }
            if hasConstants && (unit.entryPoints.count != 1 || unit.entryPoints[0].kind == .all) {
                throw fail("const lines are only legal in single-entry-point units")
            }
        }
        return job
    }

    /// The job text: `parse(serialized())` gives `self` back, and a job written in the canonical spelling serializes to its own text.
    func serialized() -> [UInt8] {
        var w = WGSLDumpOutput(layers: layers)
        w.raw("WGSLJOB 1\nid ")
        w.quoted(id)
        w.nl()
        switch source {
        case .file(let path):
            w.raw("source-file ")
            w.quoted(path)
            w.nl()
        case .inline(let bytes):
            w.raw("source-inline ")
            w.u(UInt(bytes.count))
            w.nl()
            w.raw(bytes: bytes)
            w.nl()
        }
        w.raw("encoding ")
        w.raw(encoding.name)
        w.raw("\nconfig ")
        w.raw(bytes: configText)
        w.raw("\nlayers ")
        w.raw(layers.map(\.name).joined(separator: ","))
        w.nl()
        if let stopAfter {
            w.raw("stop-after ")
            w.raw(stopAfter.name)
            w.nl()
        }
        for layout in layouts {
            writeLayoutBlock(&w, layout.id, layout.layout)
        }
        for unit in units {
            w.raw("unit\n")
            for entryPoint in unit.entryPoints {
                w.raw("  ep ")
                switch entryPoint.kind {
                case .named(let name): w.quoted(name)
                case .all: w.raw("@all")
                case .defaultEntryPoint(let stage):
                    w.raw("@default:")
                    w.raw(stageName(stage))
                }
                w.raw(" layout=")
                if let layout = entryPoint.layout {
                    w.raw(bytes: layouts[layout].id)
                } else {
                    w.raw("auto")
                }
                w.nl()
            }
            for generate in unit.generates {
                w.raw("  generate family=")
                w.u(generate.family)
                w.raw(" validation=")
                w.b(generate.validation)
                switch generate.msl {
                case .full: w.raw(" msl=full\n")
                case .hash: w.raw(" msl=hash\n")
                case .none: w.raw(" msl=none\n")
                }
                for constant in generate.constants {
                    w.raw("    const ")
                    w.quoted(constant.key)
                    w.ch(0x20)
                    w.hex(constant.bits, digits: 16)
                    w.nl()
                }
            }
            if let evaluate = unit.evaluate {
                w.raw("  evaluate ")
                w.b(evaluate)
                w.nl()
            }
        }
        w.raw("end\n")
        return w.bytes
    }

    /// The job's source in the job's encoding: nil for wtf-utf8-strict on invalid UTF-8.
    static func makeSource(_ bytes: [UInt8], _ encoding: Encoding) -> SourceText? {
        let isASCII = bytes.allSatisfy { $0 < 0x80 }
        switch encoding {
        case .wtfUTF8Latin1:
            return SourceText(decodingUTF8WithLatin1Fallback: bytes)
        case .latin1:
            return SourceText(latin1: ContiguousArray(bytes))
        case .utf16LE:
            guard bytes.count >= 2 else {
                return SourceText(latin1: [])
            }
            var units = ContiguousArray<UInt16>()
            units.reserveCapacity(bytes.count / 2)
            var index = 0
            while index + 1 < bytes.count {
                units.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                index += 2
            }
            return SourceText(utf16: units)
        case .force16:
            guard !bytes.isEmpty else {
                return SourceText(latin1: [])
            }
            if !isASCII, let decoded = String(validating: bytes, as: UTF8.self) {
                return SourceText(utf16: ContiguousArray(decoded.utf16))
            }
            return SourceText(utf16: ContiguousArray(bytes.lazy.map { UInt16($0) }))
        case .wtfUTF8Strict:
            if isASCII {
                return SourceText(latin1: ContiguousArray(bytes))
            }
            guard let decoded = String(validating: bytes, as: UTF8.self) else {
                return nil
            }
            return SourceText(utf16: ContiguousArray(decoded.utf16))
        }
    }

    /// The job's source bytes; nil when a source-file cannot be read.
    func sourceBytes() -> [UInt8]? {
        switch source {
        case .inline(let bytes):
            return bytes
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: String(decoding: path, as: UTF16.self)) else {
                return nil
            }
            return [UInt8](data)
        }
    }

    /// The WGSL::Configuration of the job's `config` line.
    func configuration(identifierCharacterClasses: IdentifierCharacterClasses) -> Configuration {
        Configuration(
            maxBuffersPlusVertexBuffersForVertexStage: config.vtx,
            maxBuffersForFragmentStage: config.frag,
            maxBuffersForComputeStage: config.comp,
            maximumCombinedWorkgroupVariablesSize: config.wgmem,
            supportedFeatures: Features(names: config.features.map { String(decoding: $0, as: UTF8.self) }),
            identifierCharacterClasses: identifierCharacterClasses
        )
    }
}

// MARK: - Running

/// The outcome of a job: the dump, and a tool error when the job could not be run.
struct WGSLDumpResult {
    var dump: [UInt8]
    var toolError: String?
}

/// The layers `wgslDumpRun` produces.
let wgslDumpBlackBoxLayers: [WGSLDumpLayer] = [.check, .reflect, .units]

/// Runs a job; `sha256` gives the digest of `msl=hash`, which needs it.
func wgslDumpRun(
    _ job: WGSLDumpJob,
    identifierCharacterClasses: IdentifierCharacterClasses = .standardLibrary,
    sha256: (([UInt8]) -> [UInt8])? = nil,
    sectionCompleted: (([UInt8]) -> Void)? = nil
) -> WGSLDumpResult {
    if job.has(.units) && job.units.contains(where: { $0.generates.count > 1 }) {
        // generate consumes the prepared module.
        return WGSLDumpResult(dump: [], toolError: "unsupported-plan")
    }
    if sha256 == nil && job.units.contains(where: { $0.generates.contains { $0.msl == .hash } }) {
        return WGSLDumpResult(dump: [], toolError: "unsupported-plan")
    }
    guard job.stopAfter == nil, job.layers.allSatisfy(wgslDumpBlackBoxLayers.contains) else {
        return WGSLDumpResult(dump: [], toolError: "unsupported-layer")
    }
    var runner = Runner(
        job: job,
        identifierCharacterClasses: identifierCharacterClasses,
        sha256: sha256,
        out: WGSLDumpOutput(layers: job.layers, sectionCompleted: sectionCompleted)
    )
    if let toolError = runner.run() {
        return WGSLDumpResult(dump: [], toolError: toolError)
    }
    return WGSLDumpResult(dump: runner.out.bytes)
}

private func writeMessage(_ w: inout WGSLDumpOutput, _ prefix: String, _ message: CompilationMessage) {
    w.raw(prefix)
    w.span(message.span)
    w.ch(0x20)
    w.quoted(message.utf16)
    w.nl()
}

func writeCheck(_ w: inout WGSLDumpOutput, _ ok: Bool, _ errors: [CompilationMessage], _ warnings: [CompilationMessage]) {
    w.raw(ok ? "check ok errors=" : "check fail errors=")
    w.u(UInt(errors.count))
    w.raw(" warnings=")
    w.u(UInt(warnings.count))
    w.nl()
    for error in errors {
        writeMessage(&w, "error ", error)
    }
    for warning in warnings {
        writeMessage(&w, "warning ", warning)
    }
}

func codeUnitsPrecede(_ a: Name, _ b: Name) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

func writeLayoutEntry(_ w: inout WGSLDumpOutput, _ entry: BindGroupLayoutEntry) {
    w.raw("binding=")
    w.u(entry.binding)
    w.raw(" web=")
    w.u(entry.webBinding)
    w.raw(" vis=")
    w.u(entry.visibility.rawValue)
    w.raw(" name=")
    w.quoted(entry.name)
    w.ch(0x20)
    writeMember(&w, entry.bindingMember)
    w.ch(0x20)
    writeIndices(&w, vertex: entry.vertex, fragment: entry.fragment, compute: entry.compute)
}

func typedStage(_ information: EntryPointInformation) -> String {
    switch information.typedEntryPoint {
    case .vertex: "vertex"
    case .fragment: "fragment"
    case .compute: "compute"
    }
}

// MARK: - Reflection (ReflectionWalker.cpp over the public EntryPointIO)

private func scalarName(_ scalar: IOScalar) -> String {
    switch scalar {
    case .i32: "i32"
    case .u32: "u32"
    case .f16: "f16"
    case .f32: "f32"
    case .bool: "bool"
    case .other: "other"
    }
}

private func shapeOf(_ type: IOType) -> String {
    switch type {
    case .missing, .other: "none"
    case .scalar(let scalar): scalarName(scalar) + "x1"
    case .vector(let scalar, let size): scalarName(scalar) + "x" + String(size)
    }
}

private func interpolationOf(_ interpolation: Interpolation?) -> String {
    guard let interpolation else {
        return "-"
    }
    return interpolationTypeName(interpolation.type) + "/" + interpolationSamplingName(interpolation.sampling)
}

/// HashMap::add keeps the first entry per location.
private func firstPerLocation(_ locations: [IOLocation]?) -> [IOLocation] {
    var seen: [UInt32] = []
    var result: [IOLocation] = []
    for location in locations ?? [] where !seen.contains(location.location) {
        seen.append(location.location)
        result.append(location)
    }
    return result
}

func dumpReflection(_ w: inout WGSLDumpOutput, _ entryPoints: [EntryPointIO]) {
    w.raw("entrypoints count=")
    w.u(UInt(entryPoints.count))
    w.nl()
    for entryPoint in entryPoints {
        w.raw("ep ")
        w.raw(stageName(entryPoint.stage))
        w.ch(0x20)
        w.quoted(entryPoint.name)
        w.nl()
    }
    w.raw("defaults vertex=")
    w.quoted(defaultEntryPoint(entryPoints, .vertex))
    w.raw(" fragment=")
    w.quoted(defaultEntryPoint(entryPoints, .fragment))
    w.raw(" compute=")
    w.quoted(defaultEntryPoint(entryPoints, .compute))
    w.nl()
    for entryPoint in entryPoints {
        w.raw("io ")
        w.quoted(entryPoint.name)
        w.raw(" stage=")
        w.raw(stageName(entryPoint.stage))
        w.nl()
        for location in firstPerLocation(entryPoint.stageIn) {
            w.raw("  stagein ")
            w.u(location.location)
            w.raw(" " + shapeOf(location.type))
            w.nl()
        }
        for location in firstPerLocation(entryPoint.vertexOutputs) {
            w.raw("  vout ")
            w.u(location.location)
            w.raw(" " + shapeOf(location.type) + " " + interpolationOf(location.interpolation))
            w.nl()
        }
        for location in firstPerLocation(entryPoint.fragmentInputs) {
            w.raw("  fin ")
            w.u(location.location)
            w.raw(" " + shapeOf(location.type) + " " + interpolationOf(location.interpolation))
            w.nl()
        }
        for location in firstPerLocation(entryPoint.fragmentOutputs) {
            w.raw("  fout ")
            w.u(location.location)
            w.raw(" " + shapeOf(location.type))
            w.nl()
        }
        w.raw("  flags fragdepth=")
        w.b(entryPoint.usesFragDepth)
        w.raw(" frontfacing=")
        w.b(entryPoint.usesFrontFacingInInput)
        w.raw(" primitiveindex=")
        w.b(entryPoint.usesPrimitiveIndexInInput)
        w.raw(" sampleindex=")
        w.b(entryPoint.usesSampleIndexInInput)
        w.raw(" samplemaskin=")
        w.b(entryPoint.usesSampleMaskInInput)
        w.raw(" samplemaskout=")
        w.b(entryPoint.usesSampleMaskInOutput)
        w.raw(" subgroupinvocationid=")
        w.b(entryPoint.usesSubgroupInvocationIdInInput)
        w.raw(" subgroupsize=")
        w.b(entryPoint.usesSubgroupSizeInInput)
        w.raw(" clipdistances=")
        w.u(entryPoint.clipDistancesCount)
        w.nl()
    }
}

/// The default entry point for a stage as ShaderModule.mm computes it (empty when absent or ambiguous).
private func defaultEntryPoint(_ entryPoints: [EntryPointIO], _ stage: ShaderStage) -> Name {
    var result = Name(utf16: [])
    var allow = true
    for entryPoint in entryPoints where entryPoint.stage == stage {
        if !allow || !result.utf16.isEmpty {
            allow = false
            result = Name(utf16: [])
            continue
        }
        result = entryPoint.name
    }
    return result
}

// MARK: - Runner

enum ConstantConversion {
    case value(ScalarValue)
    case skip
    case errorUnknown
    case errorRange
}

/// Pipeline.mm:89-140 for one WebGPU constant, through the public conversion: nil is an unknown key unless the entry point has the key.
func convertPipelineConstant(
    _ information: EntryPointInformation?,
    _ module: borrowing PreparedModule,
    _ key: Name,
    _ value: Double
) -> ConstantConversion {
    guard let converted = module.convertPipelineConstants([PipelineConstant(key: key, value: value)]) else {
        let known = information?.specializationConstants.contains { $0.key == key } ?? false
        return known ? .errorRange : .errorUnknown
    }
    guard let assignment = converted.first else {
        return .skip
    }
    return .value(assignment.value)
}

private struct Runner {
    let job: WGSLDumpJob
    let identifierCharacterClasses: IdentifierCharacterClasses
    let sha256: (([UInt8]) -> [UInt8])?
    var out: WGSLDumpOutput

    private enum LastGenerate {
        case none
        case ok
        case failed
    }

    private struct Expanded {
        var name: Name
        var layout: Int?
    }

    /// Nil, or a tool error.
    mutating func run() -> String? {
        out.raw("WGSLDUMP 1\n")
        guard let bytes = job.sourceBytes() else {
            return "unreadable-source"
        }
        guard let source = WGSLDumpJob.makeSource(bytes, job.encoding) else {
            out.raw("input id=")
            out.quoted(job.id)
            out.raw(" bytes=")
            out.u(UInt(bytes.count))
            out.raw(" invalid-utf8\nend\n")
            return nil
        }
        out.raw("input id=")
        out.quoted(job.id)
        out.raw(" bytes=")
        out.u(UInt(bytes.count))
        out.raw(" units=")
        out.u(UInt(source.count))
        out.raw(" is8bit=")
        out.b(source.isLatin1)
        out.nl()

        let features = job.config.features.sorted { $0.lexicographicallyPrecedes($1) }
        out.raw("config vtx=")
        out.u(job.config.vtx)
        out.raw(" frag=")
        out.u(job.config.frag)
        out.raw(" comp=")
        out.u(job.config.comp)
        out.raw(" wgmem=")
        out.u(job.config.wgmem)
        out.raw(" features=")
        if features.isEmpty {
            out.ch(0x2D)
        }
        for (index, feature) in features.enumerated() {
            if index > 0 {
                out.ch(0x2C)
            }
            out.raw(bytes: feature)
        }
        out.nl()
        out.section()

        let configuration = job.configuration(identifierCharacterClasses: identifierCharacterClasses)
        switch staticCheck(source, configuration: configuration) {
        case .failure(let failed):
            writeCheck(&out, false, failed.errors, failed.warnings)
            out.section()
            out.raw("end\n")
            return nil
        case .success(let module):
            writeCheck(&out, true, [], module.warnings)
            out.section()
            runChecked(module)
            out.raw("end\n")
            return nil
        }
    }

    private mutating func runChecked(_ module: consuming CheckedModule) {
        let entryPoints = module.entryPoints
        if job.has(.reflect) {
            dumpReflection(&out, entryPoints)
            out.section()
        }
        guard job.has(.units), !job.units.isEmpty else {
            return
        }
        for (index, unit) in job.units.enumerated() {
            module = runUnit(module, index, unit, entryPoints)
        }
    }

    private mutating func writeEntryPointInformation(_ name: Name, _ information: EntryPointInformation?) {
        out.raw("  epi ")
        out.quoted(name)
        guard let information else {
            out.raw(" missing\n")
            return
        }
        var invariantPresent = false
        if case .vertex(let present) = information.typedEntryPoint {
            invariantPresent = present
        }
        out.raw(" mangled=")
        out.quoted(information.mangledName)
        out.raw(" stage=")
        out.raw(typedStage(information))
        out.raw(" invariantPresent=")
        out.b(invariantPresent)
        out.raw(" usesInvariant=")
        out.b(information.usesInvariant)
        out.raw(" wgvarsize=")
        out.u(information.sizeForWorkgroupVariables)
        out.raw(" bindingcount=")
        out.u(information.bindingCount)
        out.nl()

        for constant in information.specializationConstants.sorted(by: { codeUnitsPrecede($0.key, $1.key) }) {
            out.raw("    spec ")
            out.quoted(constant.key)
            out.raw(" mangled=")
            out.quoted(constant.mangledName)
            out.raw(" type=")
            out.raw(specializationTypeName(constant.type))
            out.nl()
        }

        guard let layout = information.defaultLayout else {
            out.raw("    layout.default none\n")
            return
        }
        out.raw("    layout.default groups=")
        out.u(UInt(layout.bindGroupLayouts.count))
        out.nl()
        for bgl in layout.bindGroupLayouts {
            out.raw("    bgl group=")
            out.u(bgl.group)
            out.raw(" entries=")
            out.u(UInt(bgl.entries.count))
            out.nl()
            for entry in bgl.entries {
                out.raw("      ent ")
                writeLayoutEntry(&out, entry)
                out.nl()
            }
        }
    }

    private mutating func runUnit(
        _ module: consuming CheckedModule,
        _ index: Int,
        _ unit: WGSLDumpJob.UnitRequest,
        _ entryPoints: [EntryPointIO]
    ) -> CheckedModule {
        out.raw("unit ")
        out.u(UInt(index))
        out.nl()

        let layoutIDs = job.layouts.map(\.id)
        var expanded: [Expanded] = []
        var noEntryPoint = false
        func writeLayoutName(_ w: inout WGSLDumpOutput, _ layout: Int?) {
            w.raw(" layout=")
            if let layout {
                w.raw(bytes: layoutIDs[layout])
            } else {
                w.raw("auto")
            }
            w.nl()
        }
        for request in unit.entryPoints {
            switch request.kind {
            case .named(let name):
                out.raw("  req ")
                out.quoted(name)
                writeLayoutName(&out, request.layout)
                expanded.append(Expanded(name: Name(utf16: ContiguousArray(name)), layout: request.layout))
            case .all:
                out.raw("  req @all")
                writeLayoutName(&out, request.layout)
                for entryPoint in entryPoints {
                    expanded.append(Expanded(name: entryPoint.name, layout: request.layout))
                }
            case .defaultEntryPoint(let stage):
                let name = defaultEntryPoint(entryPoints, stage)
                out.raw("  req ")
                out.quoted(name)
                writeLayoutName(&out, request.layout)
                if name.utf16.isEmpty {
                    noEntryPoint = true
                }
                expanded.append(Expanded(name: name, layout: request.layout))
            }
        }
        if noEntryPoint {
            out.raw("  no-entry-point\n")
            out.section()
            return module
        }

        // One fresh copy per distinct layout id, in order of first use; entry points naming the same id share it.
        let jobLayouts = job.layouts
        var copyIDs: [Int] = []
        var copies: [PipelineLayout] = []
        func copyFor(_ id: Int) -> Int {
            if let index = copyIDs.firstIndex(of: id) {
                return index
            }
            copyIDs.append(id)
            copies.append(jobLayouts[id].layout)
            return copies.count - 1
        }
        var requests: [EntryPointRequest] = []
        var names: [Name] = []
        for entry in expanded {
            requests.append(EntryPointRequest(name: entry.name, layout: entry.layout.map(copyFor)))
            if !names.contains(entry.name) {
                names.append(entry.name)
            }
        }

        switch module.prepare(requests, layouts: &copies) {
        case .failed(let error, let rolledBack):
            out.raw("  prepare fail ")
            out.span(error.span)
            out.ch(0x20)
            out.quoted(error.utf16)
            out.nl()
            out.section()
            return rolledBack
        case .prepared(let prepared):
            return runPrepared(prepared, unit, expanded, names, copyIDs, &copies)
        }
    }

    private mutating func runPrepared(
        _ prepared: consuming PreparedModule,
        _ unit: WGSLDumpJob.UnitRequest,
        _ expanded: [Expanded],
        _ names: [Name],
        _ copyIDs: [Int],
        _ copies: inout [PipelineLayout]
    ) -> CheckedModule {
        out.raw("  prepare ok\n")
        out.section()

        var informations: [EntryPointInformation?] = []
        for name in names {
            let information = prepared.entryPoint(named: name)
            writeEntryPointInformation(name, information)
            informations.append(information)
        }
        for (copy, id) in copyIDs.enumerated() {
            out.raw("  writeback layout=")
            out.raw(bytes: job.layouts[id].id)
            out.nl()
            for (i, bgl) in copies[copy].bindGroupLayouts.enumerated() {
                for (j, entry) in bgl.entries.enumerated() {
                    guard case .buffer(let buffer) = entry.bindingMember else {
                        continue
                    }
                    out.raw("    wb bgl=")
                    out.u(UInt(i))
                    out.raw(" ent=")
                    out.u(UInt(j))
                    out.raw(" binding=")
                    out.u(entry.binding)
                    out.raw(" min=")
                    out.u(buffer.minBindingSize)
                    out.nl()
                }
            }
        }
        out.section()

        var last = LastGenerate.none
        var lastValues = ResolvedOverrides([])
        let module: CheckedModule
        if let generate = unit.generates.first {
            out.raw("  generate 0 family=")
            out.u(generate.family)
            out.raw(" validation=")
            out.b(generate.validation)
            out.nl()
            var values: [OverrideAssignment] = []
            var constantError = false
            if !generate.constants.isEmpty {
                let information = prepared.entryPoint(named: expanded[0].name)
                for constant in generate.constants {
                    let key = Name(utf16: ContiguousArray(constant.key))
                    out.raw("    const ")
                    out.quoted(constant.key)
                    out.raw(" in=")
                    out.hex(constant.bits, digits: 16)
                    out.raw(" -> ")
                    switch convertPipelineConstant(information, prepared, key, constant.value) {
                    case .value(let converted):
                        out.constant(converted)
                        if let existing = values.firstIndex(where: { $0.key == key }) {
                            values[existing].value = converted
                        } else {
                            values.append(OverrideAssignment(key: key, value: converted))
                        }
                    case .skip:
                        out.raw("skip")
                    case .errorUnknown:
                        out.raw("error:unknown")
                        constantError = true
                    case .errorRange:
                        out.raw("error:range")
                        constantError = true
                    }
                    out.nl()
                    if constantError {
                        break
                    }
                }
            }
            if constantError {
                out.raw("    generate-skipped constant-error\n")
                last = .failed
                out.section()
                module = prepared.abandon()
            } else {
                let deviceState = DeviceState(appleGPUFamily: generate.family, shaderValidationEnabled: generate.validation)
                var resolvedOverrides = ResolvedOverrides([])
                switch prepared.generate(overrides: values, deviceState: deviceState, resolvedOverrides: &resolvedOverrides) {
                case .generated(let library, let rolledBack):
                    out.raw("    generate ok\n")
                    last = .ok
                    writeConstantsOut(resolvedOverrides)
                    switch generate.msl {
                    case .full:
                        out.raw("    msl ")
                        out.block(payload: blockPayload(utf8: library.msl.utf8))
                    case .hash:
                        let payload = blockPayload(utf8: library.msl.utf8).bytes
                        // Only a job run with a sha256 asks for msl=hash.
                        let digest = sha256?(payload) ?? []
                        out.raw("    msl-hash sha256=")
                        for byte in digest {
                            out.ch(hexDigits[Int(byte >> 4)])
                            out.ch(hexDigits[Int(byte & 0xF)])
                        }
                        out.raw(" bytes=")
                        out.u(UInt(payload.count))
                        out.nl()
                    case .none:
                        break
                    }
                    lastValues = library.resolvedOverrides
                    module = rolledBack
                case .failed(let error, let rolledBack):
                    out.raw("    generate fail ")
                    out.span(error.span)
                    out.ch(0x20)
                    out.quoted(error.utf16)
                    out.nl()
                    writeConstantsOut(resolvedOverrides)
                    last = .failed
                    module = rolledBack
                }
                out.section()
            }
        } else {
            module = prepared.abandon()
        }

        out.raw("  end-prepare\n")
        out.section()

        guard unit.evaluate == true else {
            return module
        }
        var evaluated = module
        for (name, information) in zip(names, informations) {
            guard let information else {
                continue
            }
            out.raw("  evaluate ")
            out.quoted(name)
            if last == .failed {
                out.raw(" skipped=generate-failed\n")
                continue
            }
            guard case .compute = information.typedEntryPoint else {
                out.raw(" skipped=not-compute\n")
                continue
            }
            if information.specializationConstants.count != lastValues.count {
                out.raw(" skipped=size-mismatch\n")
                continue
            }
            // ComputePipeline.mm:59-68: all three dimensions are evaluated, even after a failure.
            let size = evaluated.evaluateWorkgroupSize(entryPoint: name, overrides: lastValues)
            out.raw(" x=")
            writeValue(size.width)
            out.raw(" y=")
            writeValue(size.height)
            out.raw(" z=")
            writeValue(size.depth)
            out.raw(" int=")
            if size.width == .failed || size.height == .failed || size.depth == .failed {
                out.raw("fail")
            } else if let extent = size.size {
                out.i(extent.width)
                out.ch(0x2C)
                out.i(extent.height)
                out.ch(0x2C)
                out.i(extent.depth)
            }
            out.nl()
            out.section()
        }
        return evaluated
    }

    /// The `const.out` lines of the map validateOverrides left behind, sorted by key.
    private mutating func writeConstantsOut(_ resolvedOverrides: ResolvedOverrides) {
        for value in resolvedOverrides.entries.sorted(by: { codeUnitsPrecede($0.name, $1.name) }) {
            out.raw("    const.out ")
            out.quoted(value.name)
            out.ch(0x20)
            out.constant(value.value)
            out.nl()
        }
    }

    private mutating func writeValue(_ value: EvaluatedDimension) {
        switch value {
        case .absent: out.ch(0x2D)
        case .failed: out.raw("fail")
        case .value(let constant): out.constant(constant)
        }
    }
}
