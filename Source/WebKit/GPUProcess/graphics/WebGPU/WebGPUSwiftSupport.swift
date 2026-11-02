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


#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT

import WebKit_Internal

extension IPCTypes.CxxName {
    // The generator names the Swift forms of the C++ types it describes, not of their aliases, which the WebGPU
    // receivers' messages use.
    typealias WebKit_WebGPU_Color = IPCTypes.Color
}

extension WebGPU.IndexFormat {
    init(_ format: IPCTypes.IndexFormat) {
        switch format {
        case .uint16:
            self = .Uint16
        case .uint32:
            self = .Uint32
        }
    }
}

// The Impls of the objects in a RemoteGPU's object heap that its Swift receivers have looked up by identifier, each with
// its shell where an encoder keeps that too, so that a message naming an object finds it without leaving Swift after
// the first time. Used only on the RemoteGPU's work queue, as the heap is.
//
// The object heap stays the authority on which objects exist and for how long: it removes an identifier here whenever
// it removes its own entry, and empties the table when it's cleared or destroyed, so the table never keeps an Impl alive
// longer than the heap keeps the object. It's a second registry for the transition, which goes, or becomes the only
// one, when the object heap moves to Swift.
@_expose(Cxx)
final class WebGPUImplTable {
    private var entries: [UInt64: AnyObject] = [:]

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
    }

    @used
    func remove(_ identifier: UInt64) {
        entries[identifier] = nil
    }

    @used
    func removeAll() {
        entries.removeAll()
    }

    // The entry for that identifier, which lookUp() finds in the object heap the first time. nil if the heap has no
    // such object, or an object of another kind. Each kind of object is kept as one type, whichever receiver looks it up
    // first: a BufferReference, BindGroupReference, RenderBundleReference or pipeline reference.
    @_expose(!Cxx)
    func entry<Entry: AnyObject>(_ identifier: UInt64, _ lookUp: () -> Entry?) -> Entry? {
        if let entry = entries[identifier] {
            return entry as? Entry
        }
        guard let entry = lookUp() else {
            return nil
        }
        entries[identifier] = entry
        return entry
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
