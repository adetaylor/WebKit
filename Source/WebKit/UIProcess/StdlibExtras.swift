// Copyright (C) 2018-2021 Apple Inc. All rights reserved.
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

import WebKit_Internal
import wtf

extension WTF.String {
    /// Return a `Swift.String` from this `WTF.String`.
    var description: Swift.String {
        // We could possibly make this quicker by treating a C++ span as
        // a Sequence. For now, we want to avoid unsafe as much as possible.
        Swift.String(utf8().toStdString())
    }
}

// FIXME (rdar://164119356): Move parts of StdLibExtras.swift into WTF
// (those parts which are not specific to WebKit-level types) - and enable
// irrespective of BACK_FORWARD_LIST_SWIFT

/// Conform any WTF::Ref<T> to this protocol to get useful extensions.
protocol CxxRef {
    associatedtype Pointee // you only need to specify this in your conformance
    init(_ object: Pointee)
    func copyRef() -> Self
}

/// Conform any WTF::Vector<T> to this protocol to get useful extensions and iterators.
protocol CxxVector {
    associatedtype Element // you only need to specify this in your conformance
    init()
    mutating func append(consuming: Element)
    mutating func reserveCapacity(_ newCapacity: Int)
    func size() -> Int
    // swift-format-ignore: AlwaysUseLowerCamelCase, NoLeadingUnderscores
    func __atUnsafe(_ index: Int) -> UnsafePointer<Element>
}

/// Conform any WTF::Vector<WTF::Ref<T>> to this protocol to get useful extensions and iterators.
protocol CxxRefVector: CxxVector where Element: CxxRef {
}

// FIXME(rdar://164119356): conform to LosslessStringConvertible
// when this moves to WTF (requires members to be public)
extension WTF.String {
    /// Construct a `WTF.String` from a `Swift.String`.
    init(_ string: Swift.String) {
        // rdar://167712240 prevents us from simply writing
        // self = WTF.String.fromUTF8(swiftString.utf8CString.span);
        // Safety - we are guaranteed to get a valid buffer from the Swift
        // string for the duration that we're using it to construct the WTF::String.
        // The WTF::String will take a copy.
        #if compiler(>=6.4)
        self = string.utf8CString.span.withUnsafeBufferPointer { ptr in
            // swift-format-ignore: NeverForceUnwrap
            let cppspan = unsafe SpanConstChar(UnsafeBufferPointer(start: ptr.baseAddress!, count: string.utf8CString.count))
            return unsafe WTF.String.fromUTF8(cppspan)
        }
        #else
        self = unsafe string.utf8CString.span.withUnsafeBufferPointer { ptr in
            // swift-format-ignore: NeverForceUnwrap
            let cppspan = unsafe SpanConstChar(UnsafeBufferPointer(start: ptr.baseAddress!, count: ptr.count - 1))
            return unsafe WTF.String.fromUTF8(cppspan)
        }
        #endif
    }
}

extension WTF.String {
    /// The UTF-16 code units of this string, exactly as stored: nothing is decoded, so a lone surrogate stays itself.
    var utf16Units: [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(Int(length()))
        if is8Bit() {
            let characters: Span<WTF.Latin1Character> = span8()
            for index in characters.indices {
                units.append(UInt16(characters[index].value))
            }
        } else {
            let characters: Span<UInt16> = checkedSpan16()
            for index in characters.indices {
                units.append(characters[index])
            }
        }
        return units
    }

    /// Construct a `WTF.String` from UTF-16 code units, exactly.
    init(utf16Units units: [UInt16]) {
        self = WTF.makeStringFromUTF16Characters(units.span)
    }

    /// The UTF-16 code units of this string, or nil for the null string.
    var nullableUTF16Units: [UInt16]? {
        isNull() ? nil : utf16Units
    }

    /// Construct a `WTF.String` from UTF-16 code units, or the null string from nil.
    init(nullableUTF16Units units: [UInt16]?) {
        self = units.map { WTF.String(utf16Units: $0) } ?? WTF.String()
    }

    /// Whether this string's UTF-16 code units start with `prefix`.
    func hasPrefix(utf16Units prefix: [UInt16]) -> Bool {
        utf16Units.starts(with: prefix)
    }

    /// Whether this string's UTF-16 code units end with `suffix`.
    func hasSuffix(utf16Units suffix: [UInt16]) -> Bool {
        utf16Units.suffix(suffix.count).elementsEqual(suffix)
    }

    /// WTF's String ==, with nil for the null string, which equals only itself.
    func isEqual(utf16Units units: [UInt16]?) -> Bool {
        guard let units else {
            return isNull()
        }
        guard !isNull() && Int(length()) == units.count else {
            return false
        }
        if is8Bit() {
            let characters: Span<WTF.Latin1Character> = span8()
            for index in characters.indices where UInt16(characters[index].value) != units[index] {
                return false
            }
            return true
        }
        let characters: Span<UInt16> = checkedSpan16()
        for index in characters.indices where characters[index] != units[index] {
            return false
        }
        return true
    }
}

extension Collection where Element: UnsignedInteger {
    /// WTF's `parseInteger` for an unsigned type.
    func parseUnsignedInteger<Value: FixedWidthInteger & UnsignedInteger>() -> Value? {
        func isUnicodeCompatibleASCIIWhitespace(_ unit: some UnsignedInteger) -> Bool {
            unit == 0x20 || (unit >= 0x09 && unit <= 0x0D)
        }
        func isDigit(_ unit: some UnsignedInteger) -> Bool {
            unit >= 0x30 && unit <= 0x39
        }
        var index = startIndex
        while index < endIndex && isUnicodeCompatibleASCIIWhitespace(self[index]) {
            formIndex(after: &index)
        }
        if index < endIndex && self[index] == 0x2B {
            formIndex(after: &index)
        }
        guard index < endIndex && isDigit(self[index]) else {
            return nil
        }
        var value: Value = 0
        while index < endIndex && isDigit(self[index]) {
            let (product, productOverflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflow) = product.addingReportingOverflow(Value(self[index] - 0x30))
            if productOverflow || sumOverflow {
                return nil
            }
            value = sum
            formIndex(after: &index)
        }
        while index < endIndex && isUnicodeCompatibleASCIIWhitespace(self[index]) {
            formIndex(after: &index)
        }
        return index == endIndex ? value : nil
    }
}

// FIXME(rdar://164119356)): conform to ExpressibleByStringLiteral
// when this moves to WTF (requires members to be public)
extension WTF.String {
    /// Construct a `WTF.String` from a string literal.
    init(stringLiteral: Swift.String) {
        self.init(stringLiteral)
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

