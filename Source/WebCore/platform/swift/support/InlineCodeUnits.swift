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

/// UTF-16 code units as a WTF::String holds them (unpaired surrogates allowed): inline when there are at most
/// `inlineCapacity` and all are Latin-1, on the heap otherwise.
///
/// The representation is canonical, so equal values are stored alike, and the synthesized Hashable is correct. The hot
/// members are inlinable, so that clients in other modules don't call across the module for each code unit.
@frozen public struct InlineCodeUnits: Hashable, Sendable, RandomAccessCollection {
    /// The most Latin-1 code units stored without allocating.
    public static var inlineCapacity: Int {
        24
    }

    // Latin-1 code units in memory order, eight to a word; the bytes past count are 0.
    @frozen @usableFromInline
    struct Inline: Hashable, Sendable {
        @usableFromInline
        var count: UInt8
        @usableFromInline
        var word0: UInt64
        @usableFromInline
        var word1: UInt64
        @usableFromInline
        var word2: UInt64

        @inlinable
        init() {
            count = 0
            word0 = 0
            word1 = 0
            word2 = 0
        }

        @inlinable
        subscript(position: Int) -> UInt16 {
            let word =
                switch position >> 3 {
                case 0:
                    word0
                case 1:
                    word1
                default:
                    word2
                }
            return UInt16(UInt8(truncatingIfNeeded: word >> UInt64(8 * (position & 7))))
        }

        @inlinable
        mutating func append(_ byte: UInt8) {
            let shifted = UInt64(byte) << UInt64(8 * (Int(count) & 7))
            switch Int(count) >> 3 {
            case 0:
                word0 |= shifted
            case 1:
                word1 |= shifted
            default:
                word2 |= shifted
            }
            count += 1
        }
    }

    @frozen @usableFromInline
    enum Storage: Hashable, Sendable {
        case inline(Inline)
        case heap(ContiguousArray<UInt16>)
    }

    @usableFromInline
    var storage: Storage

    /// No code units.
    @inlinable
    public init() {
        storage = .inline(Inline())
    }

    /// Latin-1 characters, as code units.
    @inlinable
    public init(latin1 characters: Span<UInt8>, _ range: Range<Int>) {
        guard range.count <= Self.inlineCapacity else {
            storage = .heap(Self.widened(characters, range))
            return
        }
        var inline = Inline()
        for index in range {
            inline.append(characters[index])
        }
        storage = .inline(inline)
    }

    /// These code units.
    @inlinable
    public init(_ codeUnits: some Sequence<UInt16>) {
        self.init()
        for codeUnit in codeUnits {
            append(codeUnit)
        }
    }

    /// The first position.
    @inlinable
    public var startIndex: Int {
        0
    }

    /// The position after the last.
    @inlinable
    public var endIndex: Int {
        switch storage {
        case .inline(let inline):
            Int(inline.count)
        case .heap(let heap):
            heap.count
        }
    }

    /// The code unit at a position.
    @inlinable
    public subscript(position: Int) -> UInt16 {
        switch storage {
        case .inline(let inline):
            precondition(position >= 0 && position < Int(inline.count))
            return inline[position]
        case .heap(let heap):
            return heap[position]
        }
    }

    /// Appends a code unit, moving to the heap when it doesn't fit inline.
    @inlinable
    public mutating func append(_ codeUnit: UInt16) {
        switch storage {
        case .inline(var inline):
            guard codeUnit <= 0xFF && Int(inline.count) < Self.inlineCapacity else {
                storage = .heap(Self.spilled(inline, appending: codeUnit))
                return
            }
            inline.append(UInt8(truncatingIfNeeded: codeUnit))
            storage = .inline(inline)
        case .heap(var heap):
            // Dropped from the storage first, so that the array is uniquely referenced and appends in place.
            storage = .inline(Inline())
            heap.append(codeUnit)
            storage = .heap(heap)
        }
    }

    /// The result of `body` on these code units: the heap's own, or a copy of the inline ones (on the stack from macOS 26
    /// and the corresponding OSes, before that on the heap).
    @inlinable
    public func withSpan<Result>(_ body: (Span<UInt16>) -> Result) -> Result {
        switch storage {
        case .heap(let heap):
            return body(heap.span)
        case .inline(let inline):
            if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                // 24: inlineCapacity.
                var codeUnits = InlineArray<24, UInt16>(repeating: 0)
                for position in 0..<Int(inline.count) {
                    codeUnits[position] = inline[position]
                }
                return body(codeUnits.span.extracting(0..<Int(inline.count)))
            }
            let codeUnits = ContiguousArray(self)
            return body(codeUnits.span)
        }
    }

    /// The code units in an array.
    @inlinable
    public var array: ContiguousArray<UInt16> {
        ContiguousArray(self)
    }

    @usableFromInline
    static func widened(_ characters: Span<UInt8>, _ range: Range<Int>) -> ContiguousArray<UInt16> {
        var heap = ContiguousArray<UInt16>(repeating: 0, count: range.count)
        var codeUnits = heap.mutableSpan
        for index in range {
            codeUnits[index - range.lowerBound] = UInt16(characters[index])
        }
        return heap
    }

    @usableFromInline
    static func spilled(_ inline: Inline, appending codeUnit: UInt16) -> ContiguousArray<UInt16> {
        var heap = ContiguousArray<UInt16>()
        heap.reserveCapacity(Swift.max(2 * inlineCapacity, Int(inline.count) + 1))
        for position in 0..<Int(inline.count) {
            heap.append(inline[position])
        }
        heap.append(codeUnit)
        return heap
    }
}
