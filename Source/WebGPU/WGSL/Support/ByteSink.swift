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

/// Compile-time text for a `ByteSink`: only a literal converts to it (lint L-MSL-4 bans calling its initialisers explicitly).
///
/// `String`-literal-backed: a literal's storage is immortal and contiguous, so appending it is one bulk copy with no
/// allocation. `@_transparent` removes the wrapper's calls in `-Onone` builds too.
@_spi(Testing)
public struct ByteLiteral: ExpressibleByStringLiteral, Sendable {
    @_spi(Testing)
    public typealias StringLiteralType = String

    @usableFromInline
    let text: String

    @_spi(Testing)
    @_transparent
    public init(stringLiteral value: String) {
        text = value
    }
}

/// The byte sink of the Metal writer and the AST dumper (C++ StringBuilder): one `ContiguousArray<UInt8>`, reserved up front,
/// with literal and decimal appends; the WTF number formatters append through their `inout ByteSink` overloads below.
///
/// Short appends (a literal or a decimal of up to eight bytes, an identifier, a few spaces) are staged in two words that
/// follow the array and are flushed into it sixteen bytes at a time: every array append checks uniqueness and capacity,
/// which costs more than the bytes for the usual 1-5 byte literal. -Onone builds append a literal in bulk.
@_spi(Testing)
public struct ByteSink: Sendable {
    /// Only this file may write it (lint L-MSL-4); it is not `fileprivate` because the `@_transparent` literal append inlines.
    @usableFromInline
    var sinkBytes: ContiguousArray<UInt8> = []
    // The bytes after `sinkBytes`, lowest first: `stagedCount` (0-16) of them, the first eight in `stagedLow`.
    @usableFromInline
    var stagedLow: UInt64 = 0
    @usableFromInline
    var stagedHigh: UInt64 = 0
    @usableFromInline
    var stagedCount = 0

    @_spi(Testing)
    public var bytes: ContiguousArray<UInt8> {
        guard stagedCount > 0 else {
            return sinkBytes
        }
        var bytes = sinkBytes
        bytes.append(contentsOf: StagedBytes(low: stagedLow, high: stagedHigh, endIndex: stagedCount))
        return bytes
    }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public init(reservingCapacity capacity: Int) {
        sinkBytes.reserveCapacity(capacity)
    }

    /// The text, without a copy.
    @_spi(Testing)
    public consuming func finish() -> ContiguousArray<UInt8> {
        flushStaged()
        return sinkBytes
    }

    @_spi(Testing)
    @_transparent
    public mutating func append(_ literal: ByteLiteral) {
        let utf8 = literal.text.utf8
        #if WGSL_UNOPTIMIZED
        flushStaged()
        sinkBytes.append(contentsOf: utf8)
        #else
        if utf8.count > 8 {
            flushStaged()
            sinkBytes.append(contentsOf: utf8)
        } else {
            // A literal's bytes fold into a constant word.
            var packed: UInt64 = 0
            var shift: UInt64 = 0
            for byte in utf8 {
                packed |= UInt64(byte) &<< shift
                shift &+= 8
            }
            stage(packed, utf8.count)
        }
        #endif
    }

    /// Appends the low `count` (1-8) bytes of `packed`, lowest first; its other bytes are zero.
    @usableFromInline
    @inline(__always)
    mutating func stage(_ packed: UInt64, _ count: Int) {
        let room = 16 &- stagedCount
        guard count > room else {
            insert(packed, count)
            return
        }
        // Fill the sixteen bytes, move them into the array, and stage the rest.
        if room > 0 {
            insert(packed & (~UInt64(0) &>> UInt64(truncatingIfNeeded: 64 &- room &* 8)), room)
        }
        flushFullStage()
        insert(packed &>> UInt64(truncatingIfNeeded: room &* 8), count &- room)
    }

    // Stages the low `count` bytes of `packed`, which fit; its other bytes are zero.
    @usableFromInline
    @inline(__always)
    mutating func insert(_ packed: UInt64, _ count: Int) {
        let shift = UInt64(truncatingIfNeeded: stagedCount &* 8)
        if stagedCount < 8 {
            stagedLow |= packed &<< shift
            if stagedCount != 0 {
                stagedHigh |= packed &>> (64 &- shift)
            }
        } else {
            stagedHigh |= packed &<< (shift &- 64)
        }
        stagedCount &+= count
    }

    /// Moves the sixteen staged bytes into the array.
    @usableFromInline
    @inline(never)
    mutating func flushFullStage() {
        sinkBytes.append(contentsOf: FullStage(low: stagedLow, high: stagedHigh))
        stagedLow = 0
        stagedHigh = 0
        stagedCount = 0
    }

    /// Moves the staged bytes into the array.
    @usableFromInline
    @inline(never)
    mutating func flushStaged() {
        guard stagedCount > 0 else {
            return
        }
        sinkBytes.append(contentsOf: StagedBytes(low: stagedLow, high: stagedHigh, endIndex: stagedCount))
        stagedLow = 0
        stagedHigh = 0
        stagedCount = 0
    }

    /// Concatenates another builder (the C++ swaps and appends whole StringBuilders).
    @_spi(Testing)
    public mutating func append(contentsOf other: ByteSink) {
        flushStaged()
        sinkBytes.append(contentsOf: other.sinkBytes)
        if other.stagedCount > 0 {
            sinkBytes.append(contentsOf: StagedBytes(low: other.stagedLow, high: other.stagedHigh, endIndex: other.stagedCount))
        }
    }

    @_spi(Testing)
    public mutating func clear() {
        sinkBytes = []
        stagedLow = 0
        stagedHigh = 0
        stagedCount = 0
    }

    /// `count` spaces in one append (WTF `Indentation`).
    @_spi(Testing)
    @inline(__always)
    public mutating func appendSpaces(_ count: Int) {
        if count <= 8 {
            if count > 0 {
                stage(0x2020_2020_2020_2020 &>> UInt64(truncatingIfNeeded: (8 &- count) &* 8), count)
            }
            return
        }
        appendManySpaces(count)
    }

    @usableFromInline
    @inline(never)
    mutating func appendManySpaces(_ count: Int) {
        flushStaged()
        sinkBytes.append(contentsOf: repeatElement(0x20, count: count))
    }

    /// The text of an identifier the Metal writer emits (C++ `StringBuilder::append(const String&)`): the sink's only append of
    /// runtime text, so it makes the identifier provenance check itself and text of the source traps whichever caller reaches it.
    ///
    /// Mangled, reserved and builtin spellings are ASCII by construction. A swizzle is validated on the low byte of each code
    /// unit, which C++ truncates to `char` (TypeCheck.cpp:2174), so its text may spell the components with other letters
    /// (`v.Ÿ` is `v.x`); C++ appends that text (MetalFunctionWriter.cpp:3162), which the MSL carries as UTF-8.
    mutating func appendIdentifier(_ symbol: Symbol, in symbols: borrowing SymbolTable) {
        let provenance = symbols.provenance(of: symbol)
        switch provenance {
        case .source:
            wgslFatal("an identifier of the source reached the writer", cppSite: "MangleNames.cpp invariant")
        case .mangled, .reserved, .builtin, .swizzle:
            break
        }
        if symbols.stageASCII(of: symbol, into: &self) {
            return
        }
        guard provenance == .swizzle else {
            wgslFatal("non-ASCII identifier text reached the writer", cppSite: "MangleNames.cpp invariant")
        }
        flushStaged()
        appendUTF8(symbols.codeUnits(of: symbol))
    }

    /// The UTF-8 of UTF-16 code units.
    ///
    /// An identifier holds no lone surrogate (Lexer.cpp:40-64); one would become U+FFFD.
    private mutating func appendUTF8(_ codeUnits: ContiguousArray<UInt16>) {
        var index = 0
        while index < codeUnits.count {
            var scalar = UInt32(codeUnits[index])
            index += 1
            if scalar & 0xF800 == 0xD800 {
                if scalar < 0xDC00 && index < codeUnits.count && codeUnits[index] & 0xFC00 == 0xDC00 {
                    scalar = 0x1_0000 + (((scalar & 0x3FF) << 10) | (UInt32(codeUnits[index]) & 0x3FF))
                    index += 1
                } else {
                    scalar = 0xFFFD
                }
            }
            if scalar < 0x80 {
                sinkBytes.append(UInt8(truncatingIfNeeded: scalar))
            } else if scalar < 0x800 {
                sinkBytes.append(UInt8(truncatingIfNeeded: 0xC0 | (scalar >> 6)))
                sinkBytes.append(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)))
            } else if scalar < 0x1_0000 {
                sinkBytes.append(UInt8(truncatingIfNeeded: 0xE0 | (scalar >> 12)))
                sinkBytes.append(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 6) & 0x3F)))
                sinkBytes.append(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)))
            } else {
                sinkBytes.append(UInt8(truncatingIfNeeded: 0xF0 | (scalar >> 18)))
                sinkBytes.append(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 12) & 0x3F)))
                sinkBytes.append(UInt8(truncatingIfNeeded: 0x80 | ((scalar >> 6) & 0x3F)))
                sinkBytes.append(UInt8(truncatingIfNeeded: 0x80 | (scalar & 0x3F)))
            }
        }
    }

    // Decimal, as StringBuilder appends integers: a leading "-", no grouping; INT64_MIN is exact.
    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int8) { appendDecimal(Int64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int16) { appendDecimal(Int64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int32) { appendDecimal(Int64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int) { appendDecimal(Int64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt8) { appendDecimal(UInt64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt16) { appendDecimal(UInt64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt32) { appendDecimal(UInt64(value)) }
    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt) { appendDecimal(UInt64(value)) }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int64) {
        guard value < 0 else {
            appendDecimal(UInt64(value))
            return
        }
        stage(0x2D, 1)
        appendDecimal(0 &- UInt64(bitPattern: value))
    }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt64) {
        guard value < 100_000_000 else {
            appendLongDecimal(value)
            return
        }
        // Up to eight digits, the most significant in the lowest byte.
        var packed: UInt64 = 0
        var digitCount = 0
        var remaining = value
        repeat {
            packed = packed << 8 | (0x30 &+ remaining % 10)
            remaining /= 10
            digitCount += 1
        } while remaining != 0
        stage(packed, digitCount)
    }

    private mutating func appendLongDecimal(_ value: UInt64) {
        flushStaged()
        let digitCount = decimalDigitCount(value)
        var index = sinkBytes.count + digitCount
        var padding = 0
        while padding < digitCount {
            sinkBytes.append(0x30)
            padding += 1
        }
        var remaining = value
        repeat {
            index -= 1
            sinkBytes[index] = 0x30 &+ UInt8(truncatingIfNeeded: remaining % 10)
            remaining /= 10
        } while remaining != 0
    }
}

// The staged bytes as a collection: an append of it makes one uniqueness and capacity check.
@usableFromInline
struct StagedBytes: RandomAccessCollection {
    @usableFromInline
    let low: UInt64
    @usableFromInline
    let high: UInt64
    @usableFromInline
    let endIndex: Int

    @usableFromInline
    init(low: UInt64, high: UInt64, endIndex: Int) {
        self.low = low
        self.high = high
        self.endIndex = endIndex
    }

    @usableFromInline
    var startIndex: Int { 0 }

    @usableFromInline
    @inline(__always)
    subscript(position: Int) -> UInt8 {
        let word = position < 8 ? low : high
        return UInt8(truncatingIfNeeded: word &>> UInt64(truncatingIfNeeded: (position & 7) &* 8))
    }
}

// Sixteen staged bytes as a collection of a constant count, whose copy the optimiser unrolls into two word stores.
@usableFromInline
struct FullStage: RandomAccessCollection {
    @usableFromInline
    let low: UInt64
    @usableFromInline
    let high: UInt64

    @usableFromInline
    init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    @usableFromInline
    var startIndex: Int { 0 }

    @usableFromInline
    var endIndex: Int { 16 }

    @usableFromInline
    @inline(__always)
    subscript(position: Int) -> UInt8 {
        let word = position < 8 ? low : high
        return UInt8(truncatingIfNeeded: word &>> UInt64(truncatingIfNeeded: (position & 7) &* 8))
    }
}

extension WTFNumberFormat {
    @_spi(Testing)
    public static func appendNumber(_ number: Double, to sink: inout ByteSink) {
        sink.flushStaged()
        appendNumber(number, to: &sink.sinkBytes)
    }

    @_spi(Testing)
    public static func appendNumber(_ number: Float, to sink: inout ByteSink) {
        sink.flushStaged()
        appendNumber(number, to: &sink.sinkBytes)
    }

    @_spi(Testing)
    public static func appendNumber(_ number: Half, to sink: inout ByteSink) {
        sink.flushStaged()
        appendNumber(number, to: &sink.sinkBytes)
    }

    @_spi(Testing)
    public static func appendWithTrailingPoint(_ number: Double, to sink: inout ByteSink) {
        sink.flushStaged()
        appendWithTrailingPoint(number, to: &sink.sinkBytes)
    }

    @_spi(Testing)
    public static func appendPrintfF(_ number: Double, to sink: inout ByteSink) {
        sink.flushStaged()
        appendPrintfF(number, to: &sink.sinkBytes)
    }
}

/// The number of decimal digits of `value` (1 for 0).
func decimalDigitCount(_ value: UInt64) -> Int {
    var count = 1
    var threshold: UInt64 = 10
    while count < 20 && value >= threshold {
        count += 1
        threshold = threshold &* 10
    }
    return count
}
