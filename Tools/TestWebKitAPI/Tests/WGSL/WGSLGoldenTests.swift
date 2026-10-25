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

// The byte-exact goldens: each case of goldens/*.golden is a WGSLDUMP 1 job and the dump the C++ compiler produced for it
// (Tools/Scripts/update-wgsl-goldens documents the file format and regenerates the files).

import Foundation
import Testing
import WGSL

#if arch(arm64)
private let isARM64 = true
#else
private let isARM64 = false
#endif

@Suite(.enabled(if: isARM64, "C++ goldens are captured on arm64 (FMA contraction, CPU(X86_64) discard spelling)"))
struct WGSLGoldenTests {
    @Test(arguments: GoldenFile.cases("shaders"))
    func shaders(_ goldenCase: GoldenCase) throws {
        try verify(goldenCase)
    }

    @Test(arguments: GoldenFile.cases("inline"))
    func inlineSnippets(_ goldenCase: GoldenCase) throws {
        try verify(goldenCase)
    }

    @Test(arguments: GoldenFile.cases("corpus"))
    func corpus(_ goldenCase: GoldenCase) throws {
        try verify(goldenCase)
    }
}

// MARK: - Cases

struct GoldenFormatError: Error, CustomStringConvertible {
    let description: String
}

/// One case of a golden file, with its plan and expected dump expanded.
struct GoldenCase: Sendable, CustomTestStringConvertible {
    enum Source: Sendable {
        /// A file of the shaders directory.
        case file(String)
        case inline([UInt8])
    }

    let file: String
    let name: String
    let source: Source
    let plan: [UInt8]
    let expected: [UInt8]
    /// A new case of a record-mode `<file>.pending` list: its plan is derived (golden-v1 files) and its dump recorded.
    let isPending: Bool
    /// Why the golden file could not be read; the case then only reports it.
    let loadError: String?

    var testDescription: String { name }

    /// The case's WGSLJOB 1: `id`, the source, then the plan.
    func job() throws(GoldenFormatError) -> WGSLDumpJob {
        var text = WGSLDumpOutput(layers: [])
        text.raw("WGSLJOB 1\nid ")
        text.quoted(name)
        text.nl()
        switch source {
        case .file(let relativePath):
            guard let directory = GoldenFile.shadersDirectory else {
                throw GoldenFormatError(description: "no shaders directory")
            }
            text.raw("source-file ")
            text.quoted((directory as NSString).appendingPathComponent(relativePath))
            text.nl()
        case .inline(let bytes):
            text.raw("source-inline ")
            text.u(UInt(bytes.count))
            text.nl()
            text.raw(bytes: bytes)
            text.nl()
        }
        text.raw(bytes: plan)
        do {
            return try WGSLDumpJob.parse(text.bytes)
        } catch {
            throw GoldenFormatError(description: "bad plan: \(error.reason)")
        }
    }
}

enum GoldenFile {
    /// The files whose plans are golden-v1 (derived from the module's reflection); inline.golden's are fixed.
    static let derivedPlanFiles: Set<String> = ["shaders", "corpus"]

    private static let environment = ProcessInfo.processInfo.environment

    private static func resourceDirectory(_ name: String) -> String? {
        Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent(name) }
    }

    static let goldensDirectory = environment["WGSL_GOLDEN_DIR"] ?? resourceDirectory("goldens")

    static let shadersDirectory = environment["WGSL_GOLDEN_SHADERS_DIR"] ?? resourceDirectory("shaders")

    /// update-wgsl-goldens' record mode: write each case's dump here instead of comparing it.
    static let recordDirectory = environment["WGSL_GOLDEN_RECORD_DIR"]

    /// The cases of goldens/<file>.golden, then in record mode those of <record directory>/<file>.pending.
    static func cases(_ file: String) -> [GoldenCase] {
        var cases: [GoldenCase]
        do {
            cases = try read(
                file,
                path: goldensDirectory.map { ($0 as NSString).appendingPathComponent(file + ".golden") },
                isPending: false
            )
            if let recordDirectory {
                let pending = (recordDirectory as NSString).appendingPathComponent(file + ".pending")
                if FileManager.default.fileExists(atPath: pending) {
                    cases += try read(file, path: pending, isPending: true)
                }
            }
        } catch {
            cases = [
                GoldenCase(
                    file: file,
                    name: "\(file).golden",
                    source: .inline([]),
                    plan: [],
                    expected: [],
                    isPending: false,
                    loadError: error.description
                )
            ]
        }
        return cases
    }

    private static func read(_ file: String, path: String?, isPending: Bool) throws(GoldenFormatError) -> [GoldenCase] {
        guard let path, let data = FileManager.default.contents(atPath: path) else {
            throw GoldenFormatError(description: "cannot read \(path ?? file + ".golden")")
        }
        do {
            return try parse([UInt8](data), file: file, isPending: isPending)
        } catch {
            throw GoldenFormatError(description: "\(path): \(error.description)")
        }
    }

    static func parse(_ bytes: [UInt8], file: String, isPending: Bool) throws(GoldenFormatError) -> [GoldenCase] {
        var reader = GoldenReader(bytes: bytes)
        guard try reader.line().elementsEqual("WGSLGOLDEN 1".utf8) else {
            throw GoldenFormatError(description: "not a WGSLGOLDEN 1 file")
        }
        var cases: [GoldenCase] = []
        var previousPlan: [[UInt8]] = []
        var previousDump: [[UInt8]] = []
        while !reader.isAtEnd {
            let line = try reader.line()
            if line.first == 0x23 {
                continue
            }
            guard line.starts(with: "case ".utf8) else {
                throw GoldenFormatError(description: "expected \"case\" at byte \(reader.position)")
            }
            let name = try goldenUnquote(line.dropFirst(5))
            let sourceLine = try reader.line()
            let source: GoldenCase.Source
            if sourceLine.starts(with: "source-file ".utf8) {
                source = .file(try goldenUnquote(sourceLine.dropFirst(12)))
            } else if sourceLine.starts(with: "source-inline ".utf8) {
                source = .inline(Array(try reader.payload(try goldenNumber(sourceLine.dropFirst(14)))))
            } else {
                throw GoldenFormatError(description: "case \(name): bad source line")
            }
            let planLines = try expandGoldenText(try reader.counted("plan"), previous: previousPlan)
            let dumpLines = try expandGoldenText(try reader.counted("expect"), previous: previousDump)
            guard try reader.line().elementsEqual("endcase".utf8) else {
                throw GoldenFormatError(description: "case \(name) does not end with \"endcase\"")
            }
            cases.append(
                GoldenCase(
                    file: file,
                    name: name,
                    source: source,
                    plan: goldenJoined(planLines),
                    expected: goldenJoined(dumpLines),
                    isPending: isPending,
                    loadError: nil
                )
            )
            previousPlan = planLines
            previousDump = dumpLines
        }
        return cases
    }
}

private struct GoldenReader {
    let bytes: [UInt8]
    var position = 0

    var isAtEnd: Bool { position >= bytes.count }

    mutating func line() throws(GoldenFormatError) -> ArraySlice<UInt8> {
        guard let end = bytes[position...].firstIndex(of: 0x0A) else {
            throw GoldenFormatError(description: "missing LF at byte \(position)")
        }
        let line = bytes[position..<end]
        position = end + 1
        return line
    }

    mutating func payload(_ count: Int) throws(GoldenFormatError) -> ArraySlice<UInt8> {
        guard count < bytes.count - position, bytes[position + count] == 0x0A else {
            throw GoldenFormatError(description: "a payload of \(count) bytes at byte \(position) is not followed by LF")
        }
        let payload = bytes[position..<position + count]
        position += count + 1
        return payload
    }

    mutating func counted(_ keyword: String) throws(GoldenFormatError) -> ArraySlice<UInt8> {
        let line = try line()
        let prefix = Array((keyword + " ").utf8)
        guard line.starts(with: prefix) else {
            throw GoldenFormatError(description: "expected \"\(keyword) N\" at byte \(position)")
        }
        return try payload(try goldenNumber(line.dropFirst(prefix.count)))
    }
}

private func goldenNumber(_ digits: ArraySlice<UInt8>) throws(GoldenFormatError) -> Int {
    guard !digits.isEmpty, digits.count < 10, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
        throw GoldenFormatError(description: "bad number")
    }
    return digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
}

/// The text of a STR of the dump grammar.
private func goldenUnquote(_ quoted: ArraySlice<UInt8>) throws(GoldenFormatError) -> String {
    guard quoted.count >= 2, quoted.first == 0x22, quoted.last == 0x22 else {
        throw GoldenFormatError(description: "bad string")
    }
    var units: [UInt16] = []
    var index = quoted.startIndex + 1
    let end = quoted.endIndex - 1
    while index < end {
        let c = quoted[index]
        guard c == 0x5C else {
            units.append(UInt16(c))
            index += 1
            continue
        }
        guard index + 1 < end else {
            throw GoldenFormatError(description: "bad escape")
        }
        switch quoted[index + 1] {
        case 0x22: units.append(0x22)
        case 0x5C: units.append(0x5C)
        case 0x6E: units.append(0x0A)
        case 0x74: units.append(0x09)
        case 0x72: units.append(0x0D)
        case 0x75:
            guard index + 6 <= end, let unit = UInt16(String(decoding: quoted[index + 2..<index + 6], as: UTF8.self), radix: 16) else {
                throw GoldenFormatError(description: "bad \\u escape")
            }
            units.append(unit)
            index += 4
        default:
            throw GoldenFormatError(description: "bad escape")
        }
        index += 2
    }
    return String(decoding: units, as: UTF16.self)
}

/// The lines (without LF) a compressed plan or expect text stands for: `=copy prev|this FIRST COUNT` repeats lines of the previous case's
/// text or of this one, a leading backslash escapes a literal line.
private func expandGoldenText(_ text: ArraySlice<UInt8>, previous: [[UInt8]]) throws(GoldenFormatError) -> [[UInt8]] {
    guard text.last == 0x0A else {
        throw GoldenFormatError(description: "a plan or expect text does not end with LF")
    }
    var lines: [[UInt8]] = []
    for line in text.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false) {
        switch line.first {
        case 0x3D:
            let fields = line.split(separator: 0x20)
            guard fields.count == 4, fields[0].elementsEqual("=copy".utf8) else {
                throw GoldenFormatError(description: "bad directive \(String(decoding: line, as: UTF8.self))")
            }
            let fromPrevious = fields[1].elementsEqual("prev".utf8)
            guard fromPrevious || fields[1].elementsEqual("this".utf8) else {
                throw GoldenFormatError(description: "bad directive \(String(decoding: line, as: UTF8.self))")
            }
            let first = try goldenNumber(fields[2])
            let count = try goldenNumber(fields[3])
            let available = fromPrevious ? previous.count : lines.count
            guard first + count <= available else {
                throw GoldenFormatError(description: "\(String(decoding: line, as: UTF8.self)) is out of range")
            }
            let copied = fromPrevious ? previous[first..<first + count] : lines[first..<first + count]
            lines += copied
        case 0x5C:
            lines.append(Array(line.dropFirst()))
        default:
            lines.append(Array(line))
        }
    }
    return lines
}

private func goldenJoined(_ lines: [[UInt8]]) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })
    for line in lines {
        bytes += line
        bytes.append(0x0A)
    }
    return bytes
}

// MARK: - Running a case

private struct GoldenRun: Sendable {
    var dump: [UInt8]
    var toolError: String?
    /// The plan text the golden-v1 derivation produced, when it ran.
    var derivedPlan: [UInt8]?
}

private func verify(_ goldenCase: GoldenCase) throws {
    if let loadError = goldenCase.loadError {
        Issue.record(Comment(rawValue: loadError))
        return
    }
    let job = try goldenCase.job()
    let recordDirectory = GoldenFile.recordDirectory
    let derives = recordDirectory != nil && GoldenFile.derivedPlanFiles.contains(goldenCase.file)
    let isPending = goldenCase.isPending
    let run = onCompileThread { _ in
        var derivedPlan: [UInt8]?
        var runJob = job
        if derives {
            let derived = deriveGoldenV1(job)
            derivedPlan = goldenPlanText(derived)
            if isPending {
                runJob = derived
            }
        }
        let result = wgslDumpRun(runJob, sha256: GoldenSHA256.hash)
        return GoldenRun(dump: result.dump, toolError: result.toolError, derivedPlan: derivedPlan)
    }
    if let recordDirectory {
        try record(goldenCase, run, in: recordDirectory)
        return
    }
    if let toolError = run.toolError {
        Issue.record(Comment(rawValue: "\(goldenCase.file).golden \(goldenCase.name): tool error \(toolError)"))
        return
    }
    guard run.dump != goldenCase.expected else {
        return
    }
    Issue.record(Comment(rawValue: goldenDifference(goldenCase, expected: goldenCase.expected, actual: run.dump)))
}

private func record(_ goldenCase: GoldenCase, _ run: GoldenRun, in recordDirectory: String) throws {
    let directory = (recordDirectory as NSString).appendingPathComponent(goldenCase.file)
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let stem = (directory as NSString).appendingPathComponent(goldenRecordFileName(goldenCase.name))
    if let toolError = run.toolError {
        try Data(toolError.utf8).write(to: URL(fileURLWithPath: stem + ".error"))
        return
    }
    try Data(run.dump).write(to: URL(fileURLWithPath: stem + ".dump"))
    if let derivedPlan = run.derivedPlan {
        try Data(derivedPlan).write(to: URL(fileURLWithPath: stem + ".plan"))
    } else if goldenCase.isPending {
        try Data(goldenCase.plan).write(to: URL(fileURLWithPath: stem + ".plan"))
    }
}

/// update-wgsl-goldens' record_file_name: the name's UTF-8 bytes, each outside [A-Za-z0-9._-] as %XX.
private func goldenRecordFileName(_ name: String) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    var bytes: [UInt8] = []
    for byte in name.utf8 {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x5F, 0x2D:
            bytes.append(byte)
        default:
            bytes += [0x25, digits[Int(byte >> 4)], digits[Int(byte & 0xF)]]
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// The first differing line, with three lines of context on both sides.
private func goldenDifference(_ goldenCase: GoldenCase, expected: [UInt8], actual: [UInt8]) -> String {
    let expectedLines = goldenLines(expected)
    let actualLines = goldenLines(actual)
    var first = 0
    while first < expectedLines.count, first < actualLines.count, expectedLines[first] == actualLines[first] {
        first += 1
    }
    func excerpt(_ lines: [ArraySlice<UInt8>]) -> String {
        var text = ""
        for index in max(0, first - 3)..<min(lines.count, first + 4) {
            text += (index == first ? "\n> " : "\n  ") + String(decoding: lines[index], as: UTF8.self)
        }
        return text
    }
    return "\(goldenCase.file).golden \(goldenCase.name): the dump differs from line \(first + 1) on\n"
        + "expected:\(excerpt(expectedLines))\nactual:\(excerpt(actualLines))"
}

private func goldenLines(_ text: [UInt8]) -> [ArraySlice<UInt8>] {
    var lines = text.split(separator: 0x0A, omittingEmptySubsequences: false)
    if text.last == 0x0A {
        lines.removeLast()
    }
    return lines
}

// MARK: - The golden-v1 plan

private struct GoldenEntryPointFacts {
    var name: Name
    var prepared = false
    var defaultLayout: PipelineLayout?
    /// Sorted by key code units.
    var constants: [SpecializationConstant] = []
}

/// `job` with the golden-v1 layouts and units for its source in place of its own: U1-U4 = every entry point with default layouts and
/// device states {4,0}, {4,1}, {9,0}, {9,1}, full MSL; then for each entry point in call-graph order a {9,0} unit with its default
/// layout, one with its V1 explicit layout if the default layout has a buffer, and three with the override sets A, B, A if it has
/// overrides (MSL hashes, workgroup size evaluated).
private func deriveGoldenV1(_ job: WGSLDumpJob) -> WGSLDumpJob {
    var derived = job
    derived.layouts = []
    derived.units = []
    guard let bytes = job.sourceBytes(), let source = WGSLDumpJob.makeSource(bytes, job.encoding) else {
        return derived
    }
    let facts: [GoldenEntryPointFacts]
    switch staticCheck(source, configuration: job.configuration(identifierCharacterClasses: .standardLibrary)) {
    case .failure:
        return derived
    case .success(let module):
        facts = goldenEntryPointFacts(module)
    }

    func unit(
        _ kind: WGSLDumpJob.EntryPointKind,
        layout: Int? = nil,
        family: UInt32,
        validation: Bool,
        msl: WGSLDumpJob.MSLMode,
        evaluate: Bool,
        constants: [WGSLDumpJob.ConstantRequest] = []
    ) {
        derived.units.append(
            WGSLDumpJob.UnitRequest(
                entryPoints: [WGSLDumpJob.EntryPointRequest(kind: kind, layout: layout)],
                generates: [WGSLDumpJob.GenerateRequest(family: family, validation: validation, msl: msl, constants: constants)],
                evaluate: evaluate ? true : nil
            )
        )
    }

    for (family, validation) in [(UInt32(4), false), (4, true), (9, false), (9, true)] {
        unit(.all, family: family, validation: validation, msl: .full, evaluate: false)
    }
    for (index, fact) in facts.enumerated() {
        let name = WGSLDumpJob.EntryPointKind.named(Array(fact.name.utf16))
        unit(name, family: 9, validation: false, msl: .hash, evaluate: true)
        guard fact.prepared else {
            continue
        }
        if let defaultLayout = fact.defaultLayout, goldenHasBuffer(defaultLayout) {
            derived.layouts.append(WGSLDumpJob.Layout(id: Array("g1_e\(index)".utf8), layout: goldenDeriveV1(defaultLayout)))
            unit(name, layout: derived.layouts.count - 1, family: 9, validation: false, msl: .hash, evaluate: true)
        }
        if !fact.constants.isEmpty {
            let a = goldenConstantSet(fact, index, friendly: true)
            let b = goldenConstantSet(fact, index, friendly: false)
            for constants in [a, b, a] {
                unit(name, family: 9, validation: false, msl: .hash, evaluate: true, constants: constants)
            }
        }
    }
    return derived
}

/// Prepares each entry point alone with a default layout, on a fresh module, as the goldens' plans were derived.
private func goldenEntryPointFacts(_ module: consuming CheckedModule) -> [GoldenEntryPointFacts] {
    var facts = module.entryPoints.map { GoldenEntryPointFacts(name: $0.name) }
    for index in facts.indices {
        let name = facts[index].name
        let outcome = (consume module).prepare(entryPoints: [name])
        switch consume outcome {
        case .failed(_, let rolledBack):
            module = rolledBack
        case .prepared(let prepared):
            let information = prepared.entryPoint(named: name)
            module = prepared.abandon()
            guard let information else {
                continue
            }
            facts[index].prepared = true
            facts[index].defaultLayout = information.defaultLayout
            facts[index].constants = information.specializationConstants.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
        }
    }
    return facts
}

/// The plan text of `job`: from its `encoding` line to its `end` line.
private func goldenPlanText(_ job: WGSLDumpJob) -> [UInt8] {
    var planOnly = job
    planOnly.id = []
    planOnly.source = .inline([])
    let prefixLength = "WGSLJOB 1\nid \"\"\nsource-inline 0\n\n".utf8.count
    return Array(planOnly.serialized().dropFirst(prefixLength))
}

private func goldenIsArrayLengthName(_ name: String) -> Bool {
    let units = Array(name.utf16)
    return units.count > 14 && units.starts(with: "__".utf16) && units.reversed().starts(with: "_ArrayLength".utf16.reversed())
}

private func goldenHasBuffer(_ layout: PipelineLayout) -> Bool {
    layout.bindGroupLayouts.contains { group in
        group.entries.contains { entry in
            guard case .buffer = entry.bindingMember else {
                return false
            }
            return !goldenIsArrayLengthName(entry.name)
        }
    }
}

private let goldenStages: [ShaderStage] = [.vertex, .fragment, .compute]

private func goldenSlots(_ entry: inout BindGroupLayoutEntry, _ stage: ShaderStage, _ update: (inout StageSlots) -> Void) {
    switch stage {
    case .vertex: update(&entry.vertex)
    case .fragment: update(&entry.fragment)
    case .compute: update(&entry.compute)
    }
}

/// V1: the layout getBindGroupLayout() of an auto pipeline gives.
private func goldenDeriveV1(_ defaultLayout: PipelineLayout) -> PipelineLayout {
    var groupCount: UInt32 = 0
    for group in defaultLayout.bindGroupLayouts {
        groupCount = max(groupCount, group.group &+ 1)
    }
    var result = PipelineLayout(bindGroupLayouts: (0..<groupCount).map { BindGroupLayout(group: $0, entries: []) })
    for group in defaultLayout.bindGroupLayouts {
        var entries = result.bindGroupLayouts[Int(group.group)].entries
        let firstNew = entries.count
        for entry in group.entries where !goldenIsArrayLengthName(entry.name) {
            var bindingMember = entry.bindingMember
            if case .buffer(var buffer) = bindingMember {
                buffer.minBindingSize = 0
                bindingMember = .buffer(buffer)
            }
            var derived = BindGroupLayoutEntry(
                binding: entry.webBinding,
                webBinding: 0,
                visibility: entry.visibility,
                bindingMember: bindingMember,
                name: entry.name
            )
            for stage in goldenStages where entry.visibility.contains(ShaderStages(stage)) {
                goldenSlots(&derived, stage) { $0.argumentBufferIndex = entry.binding }
            }
            entries.append(derived)
        }
        for length in group.entries where goldenIsArrayLengthName(length.name) {
            let units = Array(length.name.utf16)
            let owner = units[2..<units.count - 12]
            guard let ownerIndex = entries[firstNew...].firstIndex(where: { $0.name.utf16.elementsEqual(owner) }) else {
                continue
            }
            for stage in goldenStages where length.visibility.contains(ShaderStages(stage)) {
                goldenSlots(&entries[ownerIndex], stage) { $0.argumentBufferSizeIndex = length.binding }
            }
        }
        result.bindGroupLayouts[Int(group.group)].entries = entries
    }
    for groupIndex in result.bindGroupLayouts.indices {
        for entryIndex in result.bindGroupLayouts[groupIndex].entries.indices {
            result.bindGroupLayouts[groupIndex].entries[entryIndex].name = ""
        }
    }
    return result
}

private let goldenConstantTable: [Double] = [
    0, 1, -1, 7, 2_147_483_647, -2_147_483_648, 4_294_967_295, 0.5, -0.0, 1e10, 65_504, 65_520, .nan, 1e39,
]

/// Pipeline.mm's range checks (NaN passes all of them).
private func goldenInRange(_ type: SpecializationConstantType, _ value: Double) -> Bool {
    switch type {
    case .boolean: true
    case .float: !(value < -Double(Float.greatestFiniteMagnitude) || value > Double(Float.greatestFiniteMagnitude))
    case .int: !(value < Double(Int32.min) || value > Double(Int32.max))
    case .unsigned: !(value < 0 || value > Double(UInt32.max))
    case .half: !(value < -65_504 || value > 65_504)
    }
}

/// Override set A (`friendly`) or B of entry point `index`.
private func goldenConstantSet(_ fact: GoldenEntryPointFacts, _ index: Int, friendly: Bool) -> [WGSLDumpJob.ConstantRequest] {
    fact.constants.enumerated()
        .map { j, constant in
            let value: Double
            if friendly {
                switch constant.type {
                case .boolean, .half: value = 1
                case .float: value = 0.5
                case .int, .unsigned: value = 7
                }
            } else {
                let candidates = goldenConstantTable.filter { goldenInRange(constant.type, $0) }
                value = candidates[(index + j + 1) % candidates.count]
            }
            return WGSLDumpJob.ConstantRequest(key: Array(constant.key.utf16), bits: value.bitPattern)
        }
}

// MARK: - SHA-256

/// FIPS 180-4 SHA-256 for `msl=hash` (no CryptoKit: modules with C++ interop crash in it).
private enum GoldenSHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    private static let initialState: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    private static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private static func compress(_ state: inout [UInt32], _ block: ArraySlice<UInt8>, _ schedule: inout [UInt32]) {
        var index = block.startIndex
        for t in 0..<16 {
            schedule[t] =
                (UInt32(block[index]) << 24) | (UInt32(block[index + 1]) << 16) | (UInt32(block[index + 2]) << 8) | UInt32(block[index + 3])
            index += 4
        }
        for t in 16..<64 {
            let s0 = rotateRight(schedule[t - 15], 7) ^ rotateRight(schedule[t - 15], 18) ^ (schedule[t - 15] >> 3)
            let s1 = rotateRight(schedule[t - 2], 17) ^ rotateRight(schedule[t - 2], 19) ^ (schedule[t - 2] >> 10)
            schedule[t] = schedule[t - 16] &+ s0 &+ schedule[t - 7] &+ s1
        }
        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for t in 0..<64 {
            let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sum1 &+ choose &+ roundConstants[t] &+ schedule[t]
            let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var state = initialState
        var schedule = [UInt32](repeating: 0, count: 64)
        let fullBlocks = bytes.count / 64
        for block in 0..<fullBlocks {
            compress(&state, bytes[block * 64..<block * 64 + 64], &schedule)
        }
        var tail = Array(bytes[(fullBlocks * 64)...])
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        let bitLength = UInt64(bytes.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var offset = 0
        while offset < tail.count {
            compress(&state, tail[offset..<offset + 64], &schedule)
            offset += 64
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }
}
