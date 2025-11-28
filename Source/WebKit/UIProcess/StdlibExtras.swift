/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// FIXME (rdar://164119356): Move parts of StdLibExtras.swift into WTF
// (those parts which are specific to WebKit-level types)

internal import WebKit_Internal
internal import wtf

// Conform any WTF::Ref<T> to this protocol to get useful extensions
internal protocol CxxRef {
    associatedtype Pointee // you only need to specify this in your conformance
    init(_ object: Pointee)
    func copyRef() -> Self
}

// Conform any WTF::Vector<WTF::Ref<T>> to this protocol to get useful extensions and iterators
internal protocol CxxRefVector {
    associatedtype Element: CxxRef // you only need to specify this in your conformance
    init()
    mutating func append(consuming: Element)
    func size() -> Int
    func __atUnsafe(_ index: Int) -> UnsafePointer<Element>
}

extension String {
    init(wtfString: WTF.String) {
        self = String(wtfString.utf8(WTF.LenientConversion).toStdString())
    }
}

extension WTF.String {
    init(swiftString: String) {
        // rdar://162517354 prevents us from simply writing
        // self = WTF.String.fromUTF8(swiftString.utf8CString.span);
        // Safety - we are guaranteed to get a valid buffer from the Swift
        // string for the duration that we're using it to construct the WTF::String.
        // The WTF::String will take a copy.
        var wtfString: WTF.String?;
        let span = swiftString.utf8CString.span;
        unsafe span.withUnsafeBufferPointer { ptr in
            // Warning here is rdar://163018821
            let cppspan = unsafe SpanConstChar(ptr.baseAddress!, span.count);
            wtfString = unsafe WTF.String.fromUTF8(cppspan);
        }
        self = wtfString!
    }
}

extension API.Array {
    // Can't be a designated initializer because we can't see private fields.
    static func create(list: [API.Object]) -> API.Array {
        var vec = VectorAPIObject();
        vec.reserveCapacity(list.count);
        for item in list {
            vec.append(consuming: RefPtrAPIObject(item));
        }
        let array = API.Array.create(consuming: vec);
        return array.ptr();
    }
}

extension CxxRefVector {
    init(array: [Element.Pointee]) {
        var vec = Self.init()
        for item in array {
            vec.append(consuming: Element(item))
        }
        self = vec
    }
}

// Ierator for WTF::Vectors of Ref types
// We do not attempt to conform the Vector itself to Sequence since this would
// require C++ interop types to be public
struct CxxRefVectorIterator<Vec: CxxRefVector>: Sequence, IteratorProtocol {
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
        // Safety: we'll make a copy of the referent
        // before the vector goes out of scope. It's guaranteed
        // to have a valid lifetime, be initialized, and be
        // within the vector bounds.
        let item = vec.__atUnsafe(pos)
        pos += 1
        return item.pointee.copyRef()
    }
}
