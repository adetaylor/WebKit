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

// FIXME (rdar://164119356): Move parts of this file into WTF (those parts
// which are not specific to WebKit-level types) — and enable irrespective
// of ENABLE_GPU_PROCESS_SWIFT. Until that move happens, we duplicate the
// minimal helpers needed by GPUProcess.swift here. The sibling copy of
// these helpers lives in Source/WebKit/UIProcess/StdlibExtras.swift gated on
// ENABLE_BACK_FORWARD_LIST_SWIFT; both files are compiled into the same Swift
// module. To avoid name clashes (Swift doesn't scope an extension
// member to its file even when the file's other declarations are
// `fileprivate`), this file uses GPU-prefixed helper names
// (`GPUCxxVector`, `GPUCxxVectorIterator`, `withCStringForGPU`,
// `withCStringPointersForGPU`) instead of the unprefixed names from
// StdlibExtras.swift. Once the helpers move into WTF the prefix can drop.

#if ENABLE_GPU_PROCESS_SWIFT

import WebKit_Internal
import wtf

// MARK: - WTF::Vector iteration

// Conform any WTF::Vector<T> to this protocol to get useful iteration.
// Mirrors the `CxxVector` protocol in Source/WebKit/UIProcess/StdlibExtras.swift.
fileprivate protocol GPUCxxVector {
    associatedtype Element // you only need to specify this in your conformance
    func size() -> Int
    // swift-format-ignore: AlwaysUseLowerCamelCase, NoLeadingUnderscores
    func __atUnsafe(_ index: Int) -> UnsafePointer<Element>
}

// Iterator for WTF::Vectors. rdar://169297366 when fixed will conform
// WTF::Vector directly to Sequence, but until then we have to roll a wrapper
// since C++ interop types must remain non-public.
fileprivate struct GPUCxxVectorIterator<Vec: GPUCxxVector>: Sequence, IteratorProtocol {
    typealias Element = Vec.Element
    var vec: Vec
    var pos: Int

    init(vec: Vec) {
        self.vec = vec
        self.pos = 0
    }

    mutating func next() -> Vec.Element? {
        if pos >= vec.size() {
            return nil
        }
        // Safety: we make a copy of the referent before the vector goes out
        // of scope. It's guaranteed to have a valid lifetime, be initialized,
        // and be within the vector bounds.
        let item = unsafe vec.__atUnsafe(pos)
        pos += 1
        return unsafe item.pointee
    }
}

// Conform WTF::Vector<WTF::String> so we can iterate it via GPUCxxVectorIterator.
extension WebKit.VectorString: GPUCxxVector {
    typealias Element = WTF.String
}

// MARK: - WTF::String <-> Swift.String bridging

extension WTF.String {
    /// Calls `body` with an `UnsafePointer<CChar>?` valid for the duration of
    /// the closure. Used by GPUProcess.swift handlers that forward a WTF::String
    /// argument to a `const char*`-taking C bridge (see
    /// WebKitGPUProcessMockMediaCenter* family in GPUProcess.cpp).
    ///
    /// Implementation note: rather than reach into WTF::String's own utf8 path
    /// (which would require a stable Swift binding for CString::data() through
    /// the C++ interop), we round-trip through a Swift.String via
    /// `utf8(WTF.LenientConversion).toStdString()` — the same shape as the
    /// `description` property in StdlibExtras.swift but kept here for the GPU
    /// process side. The C-string lifetime is then handled by Swift's own
    /// `withCString` on the temporary Swift.String. The cost is one allocation
    /// per call; the C bridge bodies (e.g. WebKitGPUProcessMockMediaCenter…)
    /// also do `String::fromUTF8(persistentId)` on the C++ side, so a transient
    /// Swift-side allocation here is consistent with the existing trampoline cost.
    ///
    /// Named `withCStringForGPU` (rather than `withCString`) so the extension
    /// member doesn't clash with potential future overloads added to WTF.String
    /// elsewhere in WebKit's Swift module — Swift extension members cross file
    /// boundaries within a module regardless of the file declaring them being
    /// `fileprivate`. Once these helpers move into WTF (rdar://164119356) the
    /// rename can be reverted.
    borrowing func withCStringForGPU<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        // utf8(WTF.LenientConversion) returns a CString; .toStdString() gives
        // us the std::string the Swift.String initializer can consume. We then
        // hand the resulting Swift.String to its withCString to obtain a
        // pointer with a well-defined lifetime tied to the closure.
        let swiftString = Swift.String(utf8(WTF.LenientConversion).toStdString())
        return swiftString.withCString { cStr in body(cStr) }
    }
}

// MARK: - WTF::Vector<WTF::String> -> parallel C-string buffers

extension WebKit.VectorString {
    /// Calls `body` with a contiguous `(UnsafePointer<UnsafePointer<CChar>?>?, Int)`
    /// buffer covering every element of this WTF::Vector<WTF::String>, with
    /// each element converted to a UTF-8 `const char*`. Pointers and array
    /// remain valid only for the duration of the closure. The pointer parameter
    /// is optional because an empty vector calls `body(nil, 0)`.
    ///
    /// Used by `userPreferredLanguagesChanged` to forward Vector<String> to the
    /// existing `WebKitGPUProcessOverrideUserPreferredLanguages` C bridge,
    /// which takes `(const char* const* languages, size_t count)`.
    ///
    /// The implementation mirrors the `Array where Element == [CChar]`
    /// extension in SwiftGPUProcess.swift (used by callIntoCxxBridge to forward
    /// extraInitializationData): we hold a `[[CChar]]` of UTF-8 bytes for the
    /// closure's lifetime, then build a parallel `[UnsafePointer<CChar>?]` and
    /// call body with its base address.
    ///
    /// Named `withCStringPointersForGPU` for the same reason as
    /// `withCStringForGPU` above: extension members are visible across files
    /// in the same module regardless of `fileprivate`-style scoping on
    /// surrounding declarations, so a unique name avoids clashes with any
    /// future overload elsewhere.
    ///
    /// `consuming` rather than `borrowing` because `GPUCxxVectorIterator`
    /// takes its underlying vector by value (the iterator stores it), and the
    /// only call site in GPUProcess.swift already owns the vector via the
    /// autogen forwarder's `consuming WebKit.VectorString` argument. Going
    /// through `borrowing` would require an explicit copy/move at the iterator
    /// boundary.
    consuming func withCStringPointersForGPU<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> R) -> R {
        let count = self.size()
        if count == 0 {
            return body(nil, 0)
        }

        // Step 1: copy each WTF::String element into a Swift.String -> [CChar]
        // buffer. We don't keep the WTF::String elements around and call
        // `withCStringForGPU` recursively per element because the consuming
        // shape on the autogen handler makes nesting awkward and because
        // realising the bytes up-front matches the
        // SwiftGPUProcess.swift extraInitializationData pattern.
        var byteBuffers: [[CChar]] = []
        byteBuffers.reserveCapacity(count)
        var iterator = GPUCxxVectorIterator(vec: self)
        while let element = iterator.next() {
            let elementAsSwiftString = Swift.String(element.utf8(WTF.LenientConversion).toStdString())
            byteBuffers.append(Array(elementAsSwiftString.utf8CString))
        }

        // Step 2: walk the byteBuffers and pull out the base address of each
        // contiguous storage, into a parallel pointer array. Recursive shape
        // ensures every withUnsafeBufferPointer scope nests over the body
        // call so the pointers stay live.
        var pointers: [UnsafePointer<CChar>?] = []
        pointers.reserveCapacity(count)
        return byteBuffers.withGPUUnsafeCStringPointers(index: 0, pointers: &pointers, body: body, count: count)
    }
}

private extension Array where Element == [CChar] {
    // Helper that walks `self` recursively, holding each [CChar]'s
    // withUnsafeBufferPointer scope open while it appends the base address to
    // `pointers`. When all elements have been visited the final scope calls
    // `body` with the concatenated pointer buffer, guaranteeing all
    // UnsafePointer<CChar>? entries remain valid for the duration of `body`.
    func withGPUUnsafeCStringPointers<R>(index: Int,
                                         pointers: inout [UnsafePointer<CChar>?],
                                         body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> R,
                                         count: Int) -> R {
        if index == count {
            return pointers.withUnsafeBufferPointer { buf in body(buf.baseAddress, count) }
        }
        return self[index].withUnsafeBufferPointer { buf in
            pointers.append(buf.baseAddress)
            return withGPUUnsafeCStringPointers(index: index + 1, pointers: &pointers, body: body, count: count)
        }
    }
}

#endif // ENABLE_GPU_PROCESS_SWIFT
