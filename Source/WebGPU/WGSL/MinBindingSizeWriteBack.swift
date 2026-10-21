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

/// Proof that prepare() wrote every minBindingSize GlobalVariableRewriter assigned back into the caller's layout.
///
/// Only the flush in this file mints it.
struct MinBindingSizesWrittenBack: ~Copyable {
    fileprivate init() {}
}

/// An explicit layout of prepare(), read once through `PipelineLayoutAccess` (each entry exactly once), which GlobalVariableRewriter
/// reads as it read the C++ `PipelineLayout&`.
///
/// Where C++ assigned minBindingSize into the caller's layout (GlobalVariableRewriter.cpp:2422-2423), the rewriter records the
/// assignment here, and prepare() writes every recorded entry back into the caller's layout before it returns.
@_spi(Testing)
public struct ExplicitPipelineLayout: Sendable {
    /// The position of an entry: C++ `BindGroupLayoutEntry*` into the caller's layout.
    @_spi(Testing)
    public struct EntryAddress: Hashable, Sendable {
        /// The index of the bind group layout, which is its group.
        @_spi(Testing)
        public let bindGroupLayout: Int

        /// The index of the entry in its bind group layout.
        @_spi(Testing)
        public let entry: Int

        /// Memberwise.
        @_spi(Testing)
        public init(bindGroupLayout: Int, entry: Int) {
            self.bindGroupLayout = bindGroupLayout
            self.entry = entry
        }
    }

    /// The entries of each bind group layout, with the recorded minBindingSizes.
    @_spi(Testing)
    public private(set) var bindGroupLayouts: [[ExplicitBindGroupLayoutEntry]]

    /// The buffer entries assigned a minBindingSize, in the order of their first assignment; the final value is in the entry.
    @_spi(Testing)
    public private(set) var minBindingSizeAssignments = OrderedSet<EntryAddress>()

    /// Reads every entry of `layout` once.
    @_spi(Testing)
    public init<Access: PipelineLayoutAccess>(reading layout: borrowing Access.Layout, access: Access.Type) {
        var bindGroupLayouts: [[ExplicitBindGroupLayoutEntry]] = []
        let bindGroupLayoutCount = Access.bindGroupLayoutCount(of: layout)
        var group = 0
        while group < bindGroupLayoutCount {
            var entries: [ExplicitBindGroupLayoutEntry] = []
            let entryCount = Access.entryCount(of: layout, bindGroupLayout: group)
            var index = 0
            while index < entryCount {
                entries.append(Access.entry(of: layout, bindGroupLayout: group, index: index))
                index &+= 1
            }
            bindGroupLayouts.append(entries)
            group &+= 1
        }
        self.bindGroupLayouts = bindGroupLayouts
    }

    /// `layout.bindGroupLayouts[address.bindGroupLayout].entries[address.entry]`.
    @_spi(Testing)
    public subscript(address: EntryAddress) -> ExplicitBindGroupLayoutEntry {
        bindGroupLayouts[address.bindGroupLayout][address.entry]
    }

    /// GlobalVariableRewriter.cpp:2422-2423, `bufferBindingLayout->minBindingSize = size` for a buffer entry.
    ///
    /// Assignment, not max: WebGPU takes the max over the stages (Pipeline.mm:153).
    mutating func recordMinBindingSize(_ size: UInt64, at address: EntryAddress) {
        guard case .buffer(var buffer) = bindGroupLayouts[address.bindGroupLayout][address.entry].bindingMember else {
            wgslFatal("minBindingSize recorded for a non-buffer entry", cppSite: "GlobalVariableRewriter.cpp:2422")
        }
        buffer.minBindingSize = size
        bindGroupLayouts[address.bindGroupLayout][address.entry].bindingMember = .buffer(buffer)
        minBindingSizeAssignments.add(address)
    }
}

/// The write-back of prepare(): every minBindingSize GlobalVariableRewriter recorded is assigned into the caller's own layout
/// through its `PipelineLayoutAccess` witness, and read back.
enum MinBindingSizeWriteBack {
    /// A prepare with only default layouts: nothing to write back.
    static func flush() -> MinBindingSizesWrittenBack {
        MinBindingSizesWrittenBack()
    }

    static func flush<Access: PipelineLayoutAccess>(
        _ explicitLayout: ExplicitPipelineLayout,
        into layout: inout Access.Layout,
        access: Access.Type
    ) -> MinBindingSizesWrittenBack {
        writeBack(explicitLayout, into: &layout, access: access)
        return MinBindingSizesWrittenBack()
    }

    /// `explicitLayouts[i]` was read from `layouts[i]`.
    static func flush(_ explicitLayouts: [ExplicitPipelineLayout], into layouts: inout [PipelineLayout]) -> MinBindingSizesWrittenBack {
        guard explicitLayouts.count == layouts.count else {
            wgslFatal("minBindingSize write-back into a different list of layouts", cppSite: "GlobalVariableRewriter.cpp:2423")
        }
        var index = 0
        while index < explicitLayouts.count {
            writeBack(explicitLayouts[index], into: &layouts[index], access: PipelineLayout.Access.self)
            index &+= 1
        }
        return MinBindingSizesWrittenBack()
    }

    /// One `setMinBindingSize` per recorded entry, with its final value (assignment, as GlobalVariableRewriter.cpp:2423).
    ///
    /// The entries go in the order of their first assignment. Each write is read back, so a witness that drops or misplaces it traps
    /// here, before prepare returns.
    private static func writeBack<Access: PipelineLayoutAccess>(
        _ explicitLayout: ExplicitPipelineLayout,
        into layout: inout Access.Layout,
        access: Access.Type
    ) {
        for address in explicitLayout.minBindingSizeAssignments {
            guard case .buffer(let buffer) = explicitLayout[address].bindingMember else {
                wgslFatal("minBindingSize recorded for a non-buffer entry", cppSite: "GlobalVariableRewriter.cpp:2422")
            }
            let size = buffer.minBindingSize
            Access.setMinBindingSize(size, in: &layout, bindGroupLayout: address.bindGroupLayout, index: address.entry)
            let written = Access.entry(of: layout, bindGroupLayout: address.bindGroupLayout, index: address.entry)
            guard case .buffer(let writtenBuffer) = written.bindingMember, writtenBuffer.minBindingSize == size else {
                wgslFatal("minBindingSize write-back did not reach the caller's layout", cppSite: "GlobalVariableRewriter.cpp:2423")
            }
        }
    }
}
