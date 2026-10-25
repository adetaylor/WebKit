// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

/// The text of a compilation message (in C++, a String built with makeString or StringBuilder), as UTF-16 code units: source
/// text quoted in a message is kept exactly, lone surrogates included.
///
/// Interpolation accepts only literals, other `MessageText`s (symbol text, type strings, constant dumps), `StaticString`s
/// (`toString` of an enum), integers (decimal, as StringBuilder appends them) and, labelled `number:`, floating-point values
/// through the WTF formatters. There is deliberately no generic and no unlabelled floating-point `appendInterpolation`, so
/// `"\(someDouble)"` does not compile. Literals are `StaticString`s, so an explicit `init(stringLiteral:)` cannot take
/// runtime text either.
@_spi(Testing)
public struct MessageText: ExpressibleByStringInterpolation, Hashable, Sendable {
    @_spi(Testing)
    public typealias StringLiteralType = StaticString

    @_spi(Testing)
    public var codeUnits: ContiguousArray<UInt16>

    @_spi(Testing)
    public init(codeUnits: ContiguousArray<UInt16>) {
        self.codeUnits = codeUnits
    }

    /// The code units of `range` of `source`.
    @_spi(Testing)
    public init(_ source: SourceText, _ range: Range<Int>) {
        codeUnits = []
        source.appendCodeUnits(range, to: &codeUnits)
    }

    @_spi(Testing)
    public init(stringLiteral value: StaticString) {
        codeUnits = []
        appendStatic(value, to: &codeUnits)
    }

    @_spi(Testing)
    public init(stringInterpolation: StringInterpolation) {
        codeUnits = stringInterpolation.codeUnits
    }

    @_spi(Testing)
    public var isEmpty: Bool { codeUnits.isEmpty }

    @_spi(Testing)
    public mutating func append(_ text: MessageText) {
        codeUnits.append(contentsOf: text.codeUnits)
    }

    @_spi(Testing)
    public struct StringInterpolation: StringInterpolationProtocol {
        @_spi(Testing)
        public typealias StringLiteralType = StaticString

        fileprivate var codeUnits: ContiguousArray<UInt16> = []

        @_spi(Testing)
        public init(literalCapacity: Int, interpolationCount: Int) {
            codeUnits.reserveCapacity(literalCapacity + 16 * interpolationCount)
        }

        @_spi(Testing)
        public mutating func appendLiteral(_ literal: StaticString) {
            appendStatic(literal, to: &codeUnits)
        }

        @_spi(Testing)
        public mutating func appendInterpolation(_ text: MessageText) {
            codeUnits.append(contentsOf: text.codeUnits)
        }

        @_spi(Testing)
        public mutating func appendInterpolation(_ text: StaticString) {
            appendStatic(text, to: &codeUnits)
        }

        /// The text of `symbol`, without the copy `SymbolTable.text(of:)` makes.
        @_spi(Testing)
        public mutating func appendInterpolation(_ symbol: Symbol, in symbols: borrowing SymbolTable) {
            symbols.appendCodeUnits(of: symbol, to: &codeUnits)
        }

        @_spi(Testing)
        public mutating func appendInterpolation(_ value: Int8) { appendDecimal(Int64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: Int16) { appendDecimal(Int64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: Int32) { appendDecimal(Int64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: Int64) { appendDecimal(value) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: Int) { appendDecimal(Int64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: UInt8) { appendDecimal(UInt64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: UInt16) { appendDecimal(UInt64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: UInt32) { appendDecimal(UInt64(value)) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: UInt64) { appendDecimal(value) }
        @_spi(Testing)
        public mutating func appendInterpolation(_ value: UInt) { appendDecimal(UInt64(value)) }

        /// String::number(double).
        @_spi(Testing)
        public mutating func appendInterpolation(number value: Double) { appendASCII(WTFNumberFormat.number(value)) }
        /// String::number(float).
        @_spi(Testing)
        public mutating func appendInterpolation(number value: Float) { appendASCII(WTFNumberFormat.number(value)) }
        /// String::number of the half widened to float.
        @_spi(Testing)
        public mutating func appendInterpolation(number value: Half) { appendASCII(WTFNumberFormat.number(value)) }

        private mutating func appendASCII(_ bytes: ContiguousArray<UInt8>) {
            var index = 0
            while index < bytes.count {
                codeUnits.append(UInt16(bytes[index]))
                index += 1
            }
        }

        private mutating func appendDecimal(_ value: Int64) {
            guard value < 0 else {
                appendDecimal(UInt64(value))
                return
            }
            codeUnits.append(0x2D)
            appendDecimal(0 &- UInt64(bitPattern: value))
        }

        private mutating func appendDecimal(_ value: UInt64) {
            let digitCount = decimalDigitCount(value)
            var index = codeUnits.count + digitCount
            var padding = 0
            while padding < digitCount {
                codeUnits.append(0x30)
                padding += 1
            }
            var remaining = value
            repeat {
                index -= 1
                codeUnits[index] = 0x30 &+ UInt16(truncatingIfNeeded: remaining % 10)
                remaining /= 10
            } while remaining != 0
        }
    }
}

// The UTF-16 of a literal: ASCII widened from its bytes, which is much faster than transcoding through `String.UTF16View`.
private func appendStatic(_ text: StaticString, to codeUnits: inout ContiguousArray<UInt16>) {
    guard text.isASCII else {
        codeUnits.append(contentsOf: text.description.utf16)
        return
    }
    codeUnits.append(contentsOf: WidenedASCII(utf8: text.description.utf8))
}

// ASCII bytes as code units: one append of them checks the array once, not once per code unit.
private struct WidenedASCII: Sequence {
    struct Iterator: IteratorProtocol {
        var bytes: String.UTF8View.Iterator

        @inline(__always)
        mutating func next() -> UInt16? {
            guard let byte = bytes.next() else {
                return nil
            }
            return UInt16(byte)
        }
    }

    let utf8: String.UTF8View

    var underestimatedCount: Int { utf8.count }

    func makeIterator() -> Iterator {
        Iterator(bytes: utf8.makeIterator())
    }
}
