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

import Synchronization
import Testing
import WGSL

// The minBindingSize write-back of prepare. The expected layouts are what the C++ left in the caller's
// WGSL::PipelineLayout after WGSL::prepare returned, success or failure: a probe built each layout as `layout(_:)` does,
// called the C++ WGSL::prepare with it and printed every buffer entry's minBindingSize.

private let arrayOfFourVec4f = """
    @group(0) @binding(0) var<storage> a: array<vec4f, 4>;
    @compute @workgroup_size(1) fn main() { _ = a[0]; }
    """

private let manyBuffers = """
    struct S { x: f32, y: vec2f }
    @group(0) @binding(0) var<storage> a: array<vec4f, 4>;
    @group(0) @binding(1) var<uniform> u: vec3f;
    @group(0) @binding(2) var<storage, read_write> s: S;
    @group(0) @binding(4) var<uniform> v: vec4f;
    @group(1) @binding(3) var<storage> r: array<f32>;
    @compute @workgroup_size(1) fn main() { _ = a[0]; _ = u; s.x = 1; _ = r[0]; }
    @compute @workgroup_size(1) fn other() { _ = v; }
    """

private let secondBufferMissing = """
    @group(0) @binding(0) var<storage> a: array<vec4f, 4>;
    @group(0) @binding(1) var<storage> b: array<vec4f, 8>;
    @compute @workgroup_size(1) fn main() { _ = a[0]; _ = b[0]; }
    """

private let oneBindingTwoVariables = """
    @group(0) @binding(0) var<storage> a: array<vec4f, 4>;
    @group(0) @binding(0) var<storage> c: array<vec4f, 2>;
    @compute @workgroup_size(1) fn main() { _ = a[0]; }
    @compute @workgroup_size(1) fn other() { _ = c[0]; }
    """

private struct BufferEntry {
    var group: Int
    var binding: UInt32
    var type: BufferBindingType
    var minBindingSize: UInt64
    var sizeIndex: UInt32?
}

/// Every entry visible in every stage, with `binding` as its argument buffer index in each stage.
private func layout(_ entries: [BufferEntry]) -> PipelineLayout {
    var layout = PipelineLayout()
    for entry in entries {
        while layout.bindGroupLayouts.count <= entry.group {
            layout.bindGroupLayouts.append(BindGroupLayout(group: UInt32(layout.bindGroupLayouts.count), entries: []))
        }
        let slots = StageSlots(argumentBufferIndex: entry.binding, argumentBufferSizeIndex: entry.sizeIndex)
        layout.bindGroupLayouts[entry.group].entries
            .append(
                BindGroupLayoutEntry(
                    binding: entry.binding,
                    webBinding: entry.binding,
                    visibility: [.vertex, .fragment, .compute],
                    bindingMember: .buffer(
                        BufferBindingLayout(type: entry.type, hasDynamicOffset: false, minBindingSize: entry.minBindingSize)
                    ),
                    name: "",
                    vertex: slots,
                    fragment: slots,
                    compute: slots
                )
            )
    }
    return layout
}

private func entry(_ group: Int, _ binding: UInt32, _ type: BufferBindingType, _ min: UInt64, sizeIndex: UInt32? = nil) -> BufferEntry {
    BufferEntry(group: group, binding: binding, type: type, minBindingSize: min, sizeIndex: sizeIndex)
}

/// The minBindingSize of every buffer entry as (bind group layout index, entry index, size), in layout order.
private func minBindingSizes(_ layout: PipelineLayout) -> [[UInt64]] {
    layout.bindGroupLayouts.map { bindGroupLayout in
        bindGroupLayout.entries.map { entry in
            guard case .buffer(let buffer) = entry.bindingMember else {
                return UInt64.max
            }
            return buffer.minBindingSize
        }
    }
}

private struct EntryAddress: Hashable, Comparable, Sendable {
    var group: Int
    var index: Int

    static func < (lhs: EntryAddress, rhs: EntryAddress) -> Bool {
        (lhs.group, lhs.index) < (rhs.group, rhs.index)
    }
}

private struct Write: Hashable, Sendable {
    var address: EntryAddress
    var size: UInt64
}

/// A PipelineLayout that logs every access prepare makes through its witness.
private struct RecordingLayout: Sendable {
    var layout: PipelineLayout
    var reads: [EntryAddress] = []
    var writes: [Write] = []
}

private enum RecordingAccess: PipelineLayoutAccess {
    static func bindGroupLayoutCount(of layout: borrowing RecordingLayout) -> Int {
        PipelineLayout.Access.bindGroupLayoutCount(of: layout.layout)
    }

    static func entryCount(of layout: borrowing RecordingLayout, bindGroupLayout group: Int) -> Int {
        PipelineLayout.Access.entryCount(of: layout.layout, bindGroupLayout: group)
    }

    static func entry(of layout: borrowing RecordingLayout, bindGroupLayout group: Int, index: Int) -> ExplicitBindGroupLayoutEntry {
        PipelineLayout.Access.entry(of: layout.layout, bindGroupLayout: group, index: index)
    }

    static func setMinBindingSize(_ size: UInt64, in layout: inout RecordingLayout, bindGroupLayout group: Int, index: Int) {
        layout.writes.append(Write(address: EntryAddress(group: group, index: index), size: size))
        PipelineLayout.Access.setMinBindingSize(size, in: &layout.layout, bindGroupLayout: group, index: index)
    }
}

private enum Outcome: Equatable, Sendable {
    case prepared
    case failed(String)
    case notChecked
}

private struct Prepared: Sendable {
    var outcome: Outcome
    var layout: RecordingLayout
}

/// Runs `body` on the module staticCheck makes of `source`, or returns `failed`.
private func withCheckedModule<R: Sendable>(
    _ source: String,
    failed: R,
    _ body: @escaping @Sendable (consuming CheckedModule) -> R
) -> R {
    onCompileThread { compileThread in
        switch compileThread.staticCheck(wtfSource(source)) {
        case .failure:
            return failed
        case .success(let module):
            return body(module)
        }
    }
}

private func prepare(_ source: String, _ entryPoint: String, _ entries: [BufferEntry]) -> Prepared {
    let initial = RecordingLayout(layout: layout(entries))
    return withCheckedModule(source, failed: Prepared(outcome: .notChecked, layout: initial)) { module in
        var recording = initial
        switch module.prepare(entryPoint: Name(entryPoint), layout: &recording, access: RecordingAccess.self) {
        case .prepared:
            return Prepared(outcome: .prepared, layout: recording)
        case .failed(let error, _):
            return Prepared(outcome: .failed(error.message), layout: recording)
        }
    }
}

private func writes(_ writes: [Write]) -> [Write] {
    writes.sorted { $0.address < $1.address }
}

private func write(_ group: Int, _ index: Int, _ size: UInt64) -> Write {
    Write(address: EntryAddress(group: group, index: index), size: size)
}

@Suite
struct WGSLMinBindingSizeWriteBackTests {
    // The bridge's write-back test, on a value layout.
    @Test
    func valueLayoutComesBackWith64() {
        let result = withCheckedModule(arrayOfFourVec4f, failed: nil) { module -> [[UInt64]]? in
            var pipelineLayout = layout([entry(0, 0, .readOnlyStorage, 0)])
            switch module.prepare(entryPoint: Name("main"), layout: &pipelineLayout) {
            case .prepared:
                return minBindingSizes(pipelineLayout)
            case .failed:
                return nil
            }
        }
        #expect(result == [[64]])
    }

    @Test
    func assignmentNotMax() {
        let result = prepare(arrayOfFourVec4f, "main", [entry(0, 0, .readOnlyStorage, 1000)])
        #expect(result.outcome == .prepared)
        #expect(result.layout.writes == [write(0, 0, 64)])
        #expect(minBindingSizes(result.layout.layout) == [[64]])
    }

    @Test
    func recordingWitnessOnSuccess() {
        let result = prepare(
            manyBuffers,
            "main",
            [
                entry(0, 0, .readOnlyStorage, 0), entry(0, 1, .uniform, 0), entry(0, 2, .storage, 0), entry(0, 4, .uniform, 0),
                entry(0, 5, .uniform, 7), entry(1, 3, .readOnlyStorage, 0, sizeIndex: 6),
            ]
        )
        #expect(result.outcome == .prepared)
        #expect(writes(result.layout.writes) == [write(0, 0, 64), write(0, 1, 12), write(0, 2, 16), write(1, 0, 4)])
        #expect(Set(result.layout.writes.map(\.address)).count == result.layout.writes.count)
        #expect(minBindingSizes(result.layout.layout) == [[64, 12, 16, 0, 7], [4]])
    }

    @Test
    func recordingWitnessOnAnotherEntryPoint() {
        let result = prepare(
            manyBuffers,
            "other",
            [
                entry(0, 0, .readOnlyStorage, 0), entry(0, 1, .uniform, 0), entry(0, 2, .storage, 0), entry(0, 4, .uniform, 0),
                entry(0, 5, .uniform, 7), entry(1, 3, .readOnlyStorage, 0, sizeIndex: 6),
            ]
        )
        #expect(result.outcome == .prepared)
        #expect(result.layout.writes == [write(0, 3, 16)])
        #expect(minBindingSizes(result.layout.layout) == [[0, 0, 0, 16, 7], [0]])
    }

    // The runtime array's length has no argument buffer size index, so prepare fails after assigning every used buffer.
    @Test
    func recordingWitnessOnIncompatibleLayout() {
        let result = prepare(
            manyBuffers,
            "main",
            [
                entry(0, 0, .readOnlyStorage, 0), entry(0, 1, .uniform, 0), entry(0, 2, .storage, 0), entry(0, 4, .uniform, 0),
                entry(0, 5, .uniform, 7), entry(1, 3, .readOnlyStorage, 0),
            ]
        )
        #expect(result.outcome == .failed("Shader is incompatible with layout pipeline"))
        #expect(writes(result.layout.writes) == [write(0, 0, 64), write(0, 1, 12), write(0, 2, 16), write(1, 0, 4)])
        #expect(minBindingSizes(result.layout.layout) == [[64, 12, 16, 0, 7], [4]])
    }

    @Test
    func recordingWitnessWhenALaterBufferIsMissing() {
        let result = prepare(secondBufferMissing, "main", [entry(0, 0, .readOnlyStorage, 0)])
        #expect(result.outcome == .failed("Shader is incompatible with layout pipeline"))
        #expect(result.layout.writes == [write(0, 0, 64)])
        #expect(minBindingSizes(result.layout.layout) == [[64]])
    }

    @Test
    func recordingWitnessWhenAnEarlierBufferIsMissing() {
        let result = prepare(secondBufferMissing, "main", [entry(0, 1, .readOnlyStorage, 0)])
        #expect(result.outcome == .failed("Shader is incompatible with layout pipeline"))
        #expect(result.layout.writes.isEmpty)
        #expect(minBindingSizes(result.layout.layout) == [[0]])
    }

    @Test
    func recordingWitnessOnAMismatchedEntry() {
        let result = prepare(secondBufferMissing, "main", [entry(0, 0, .readOnlyStorage, 0), entry(0, 1, .uniform, 0)])
        #expect(result.outcome == .failed("Shader is incompatible with layout pipeline: variableAddressSpace != entryAddressSpace"))
        #expect(result.layout.writes == [write(0, 0, 64)])
        #expect(minBindingSizes(result.layout.layout) == [[64, 0]])
    }

    // Every entry is read once before the passes, and each write is read back once.
    @Test
    func readsEachEntryOnceAndEachWriteBack() {
        let log = ReadLog()
        let result = withCheckedModule(arrayOfFourVec4f, failed: []) { module -> [EntryAddress] in
            var recording = LoggedLayout(
                layout: layout([entry(0, 0, .readOnlyStorage, 0), entry(0, 1, .uniform, 5), entry(1, 0, .uniform, 0)]),
                log: log
            )
            switch module.prepare(entryPoint: Name("main"), layout: &recording, access: LoggedAccess.self) {
            case .prepared:
                return log.reads.withLock { $0 }
            case .failed:
                return []
            }
        }
        #expect(
            result == [
                EntryAddress(group: 0, index: 0), EntryAddress(group: 0, index: 1), EntryAddress(group: 1, index: 0),
                EntryAddress(group: 0, index: 0),
            ]
        )
    }

    // Two variables at one binding, used by different entry points that share a layout: C++ assigns 64, then 32.
    @Test
    func sharedLayoutGetsTheLastAssignment() {
        let result = withCheckedModule(oneBindingTwoVariables, failed: nil) { module -> [[UInt64]]? in
            var layouts = [layout([entry(0, 0, .readOnlyStorage, 0)])]
            let requests = [EntryPointRequest(name: Name("main"), layout: 0), EntryPointRequest(name: Name("other"), layout: 0)]
            switch module.prepare(requests, layouts: &layouts) {
            case .prepared:
                return minBindingSizes(layouts[0])
            case .failed:
                return nil
            }
        }
        #expect(result == [[32]])
    }

    @Test
    func eachLayoutGetsItsEntryPointsSizes() {
        let result = withCheckedModule(manyBuffers, failed: nil) { module -> [[[UInt64]]]? in
            let entries = [
                entry(0, 0, .readOnlyStorage, 0), entry(0, 1, .uniform, 0), entry(0, 2, .storage, 0), entry(0, 4, .uniform, 0),
                entry(0, 5, .uniform, 7), entry(1, 3, .readOnlyStorage, 0, sizeIndex: 6),
            ]
            var layouts = [layout(entries), layout(entries), layout(entries)]
            // HashMap::add: the second request for "main" is ignored, so layouts[2] is not touched.
            let requests = [
                EntryPointRequest(name: Name("main"), layout: 0), EntryPointRequest(name: Name("other"), layout: 1),
                EntryPointRequest(name: Name("main"), layout: 2),
            ]
            switch module.prepare(requests, layouts: &layouts) {
            case .prepared:
                return layouts.map(minBindingSizes)
            case .failed:
                return nil
            }
        }
        #expect(result == [[[64, 12, 16, 0, 7], [4]], [[0, 0, 0, 16, 7], [0]], [[0, 0, 0, 0, 7], [0]]])
    }

    @Test
    func defaultLayoutsWriteNothing() {
        let result = withCheckedModule(manyBuffers, failed: false) { module -> Bool in
            switch module.prepare(entryPoints: [Name("main"), Name("other")]) {
            case .prepared(let prepared):
                return prepared.entryPoints.allSatisfy { $0.defaultLayout != nil }
            case .failed:
                return false
            }
        }
        #expect(result)
    }
}

/// The entry reads of a witness, which gets the layout borrowed.
private final class ReadLog: Sendable {
    let reads = Mutex<[EntryAddress]>([])
}

/// A layout whose witness logs entry reads in a shared box (a borrowed layout cannot be written).
private struct LoggedLayout {
    var layout: PipelineLayout
    let log: ReadLog
}

private enum LoggedAccess: PipelineLayoutAccess {
    static func bindGroupLayoutCount(of layout: borrowing LoggedLayout) -> Int {
        PipelineLayout.Access.bindGroupLayoutCount(of: layout.layout)
    }

    static func entryCount(of layout: borrowing LoggedLayout, bindGroupLayout group: Int) -> Int {
        PipelineLayout.Access.entryCount(of: layout.layout, bindGroupLayout: group)
    }

    static func entry(of layout: borrowing LoggedLayout, bindGroupLayout group: Int, index: Int) -> ExplicitBindGroupLayoutEntry {
        layout.log.reads.withLock { $0.append(EntryAddress(group: group, index: index)) }
        return PipelineLayout.Access.entry(of: layout.layout, bindGroupLayout: group, index: index)
    }

    static func setMinBindingSize(_ size: UInt64, in layout: inout LoggedLayout, bindGroupLayout group: Int, index: Int) {
        PipelineLayout.Access.setMinBindingSize(size, in: &layout.layout, bindGroupLayout: group, index: index)
    }
}
