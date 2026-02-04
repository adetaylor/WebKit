// Copyright (C) 2025-2026 Apple Inc. All rights reserved.
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

#if compiler(>=6.2)

// FIXME (rdar://164119356): Move parts of StdLibExtras.swift into WTF
// (those parts which are not specific to WebKit-level types) - and enable
// irrespective of BACK_FORWARD_LIST_SWIFT
#if ENABLE_BACK_FORWARD_LIST_SWIFT

internal import WebKit_Internal
internal import wtf

// Conform any WTF::Ref<T> to this protocol to get useful extensions
protocol CxxRef {
    associatedtype Pointee // you only need to specify this in your conformance
    init(_ object: Pointee)
    func copyRef() -> Self
}

// Conform any WTF::Vector<WTF::Ref<T>> to this protocol to get useful extensions and iterators
protocol CxxRefVector {
    associatedtype Element: CxxRef // you only need to specify this in your conformance
    init()
    mutating func append(consuming: Element)
    mutating func reserveCapacity(_ newCapacity: Int)
    func size() -> Int
    // swift-format-ignore: AlwaysUseLowerCamelCase, NoLeadingUnderscores
    func __atUnsafe(_ index: Int) -> UnsafePointer<Element>
}

extension WTF.String: LosslessStringConvertible {
    public init(_ string: Swift.String) {
        let ns = string as NSString
        let cf: CFString = ns as CFString
        self = WTF.String(cf)
    }

    public var description: Swift.String {
        // Safety: `createNSString()` returns a
        // RetainPtr which is guaranteed to keep
        // the NSString alive while we construct a Swift string from its
        // raw pointer.
        let ns = unsafe createNSString()
        return unsafe ns.get()
    }
}

extension WTF.String: ExpressibleByStringLiteral {
    public init(stringLiteral: Swift.String) {
        self.init(stringLiteral)
    }
}

extension WTF.String: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        // Safety: nullString returns a reference to some static data
        // which is guaranteed to be interpretable as a WTF::String, and as it's
        // static data, has no lifetime concerns.
        self = unsafe WTF.nullString().pointee
    }
}

extension API.Array {
    // Can't be a designated initializer because we can't see private fields.
    static func create(list: [API.Object]) -> API.RefAPIArray {
        var vec = API.VectorRefPtrAPIObject()
        vec.reserveCapacity(list.count)
        for item in list {
            vec.append(consuming: API.RefPtrAPIObject(item))
        }
        return API.Array.create(consuming: vec)
    }
}

extension CxxRefVector {
    init(array: [Element.Pointee]) {
        var vec = Self()
        vec.reserveCapacity(array.count)
        for item in array {
            vec.append(consuming: Element(item))
        }
        self = vec
    }
}

#endif // ENABLE_BACK_FORWARD_LIST_SWIFT

#endif // compiler(>=6.2)
