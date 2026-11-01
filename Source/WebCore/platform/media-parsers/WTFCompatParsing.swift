// Copyright (C) 2007-2021 Apple Inc. All rights reserved.
// Copyright (C) 2014-2019 Apple Inc. All rights reserved.
// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
// Copyright (C) 2018-2021 Apple Inc. All rights reserved.
// Copyright (C) 2022 Jarred Sumner. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

private import Cxx
import WebCore_Internal.MediaParsersCxxBridging

// WTF's string parsing semantics over the code units of a Latin-1 (UInt8) or UTF-16 (UInt16) string, leniencies
// included, so that ports of StringView-based parsers accept exactly what they accepted in C++.
protocol WTFCodeUnit: FixedWidthInteger, UnsignedInteger {}

extension UInt8: WTFCodeUnit {}
extension UInt16: WTFCodeUnit {}

func isASCIIDigit<CodeUnit: WTFCodeUnit>(_ character: CodeUnit) -> Bool {
    character >= 0x30 && character <= 0x39
}

func isASCIIHexDigit<CodeUnit: WTFCodeUnit>(_ character: CodeUnit) -> Bool {
    let lowered = toASCIILowerUnchecked(character)
    return isASCIIDigit(character) || (lowered >= 0x61 && lowered <= 0x66)
}

// Only sets the 0x20 bit, so it also maps 0x11 to '1', '@' to '`', and so on.
func toASCIILowerUnchecked<CodeUnit: WTFCodeUnit>(_ character: CodeUnit) -> CodeUnit {
    character | 0x20
}

// Space, \t, \n, \r, \f and \v.
func isUnicodeCompatibleASCIIWhitespace<CodeUnit: WTFCodeUnit>(_ character: CodeUnit) -> Bool {
    character == 0x20 || (character >= 0x09 && character <= 0x0D)
}

extension Span where Element: WTFCodeUnit {
    // parseInteger<T>(StringView, base): optional leading and trailing isUnicodeCompatibleASCIIWhitespace, one leading
    // '+' (or '-' when T is signed), any number of leading zeros, then digits; nil on overflow or on anything else.
    func parseInteger<T: FixedWidthInteger>(_ type: T.Type = T.self, base: Int = 10) -> T? {
        parseInteger(type, base: base, allowingTrailingJunk: false)
    }

    // parseIntegerAllowingTrailingJunk<T>: as parseInteger, but ignores whatever follows the digits.
    func parseIntegerAllowingTrailingJunk<T: FixedWidthInteger>(_ type: T.Type = T.self, base: Int = 10) -> T? {
        parseInteger(type, base: base, allowingTrailingJunk: true)
    }

    private func parseInteger<T: FixedWidthInteger>(_: T.Type, base: Int, allowingTrailingJunk: Bool) -> T? {
        var position = skippingWhitespace(from: 0)
        var isNegative = false
        if T.isSigned && position < count && self[position] == 0x2D {
            isNegative = true
            position += 1
        } else if position < count && self[position] == 0x2B {
            position += 1
        }

        guard position < count, digitValue(self[position], base: base) != nil else {
            return nil
        }

        let radix = T(truncatingIfNeeded: base)
        var value: T = 0
        var overflowed = false
        while position < count, let digit = digitValue(self[position], base: base) {
            let (product, productOverflowed) = value.multipliedReportingOverflow(by: radix)
            let (sum, sumOverflowed) =
                isNegative
                ? product.subtractingReportingOverflow(T(truncatingIfNeeded: digit))
                : product.addingReportingOverflow(T(truncatingIfNeeded: digit))
            overflowed = overflowed || productOverflowed || sumOverflowed
            value = sum
            position += 1
        }

        if overflowed {
            return nil
        }
        if !allowingTrailingJunk && skippingWhitespace(from: position) != count {
            return nil
        }
        return value
    }

    private func skippingWhitespace(from start: Int) -> Int {
        var position = start
        while position < count && isUnicodeCompatibleASCIIWhitespace(self[position]) {
            position += 1
        }
        return position
    }

    // Digits, then the letters for bases above 10, matched with toASCIILowerUnchecked like WTF does.
    private func digitValue(_ character: Element, base: Int) -> Int? {
        if isASCIIDigit(character) {
            let value = Int(character) - 0x30
            return value < base ? value : nil
        }
        let lowered = Int(toASCIILowerUnchecked(character))
        guard lowered >= 0x61 && lowered < 0x61 + min(base - 10, 26) else {
            return nil
        }
        return lowered - 0x61 + 10
    }

    // StringView::split(separator): the pieces between separators, skipping empty ones (also at either end).
    @_lifetime(copy self)
    func split(separator: Unicode.Scalar) -> WTFSplitIterator<Element> {
        WTFSplitIterator(self, separator: separator)
    }

    // StringView::find(character, start); nil for notFound.
    func find(_ character: Unicode.Scalar, from start: Int = 0) -> Int? {
        guard start >= 0 else {
            return nil
        }
        var position = start
        while position < count {
            if UInt32(self[position]) == character.value {
                return position
            }
            position += 1
        }
        return nil
    }

    // StringView::substring(start, length): an empty span when start is past the end; length is clamped. Negative
    // arguments behave like the huge unsigned values they would be in C++.
    @_lifetime(copy self)
    func substring(_ start: Int, _ length: Int = Int.max) -> Span<Element> {
        guard start >= 0 && start < count else {
            return extracting(0..<0)
        }
        let maximumLength = count - start
        let clampedLength = length < 0 || length >= maximumLength ? maximumLength : length
        return extracting(start..<(start + clampedLength))
    }

    // StringView::left(length).
    @_lifetime(copy self)
    func left(_ length: Int) -> Span<Element> {
        substring(0, length)
    }

    // StringView == ASCIILiteral: same length and the same code units.
    @inline(__always)
    func equals(_ literal: Swift.String) -> Bool {
        literal.utf8.count == count && hasPrefix(literal)
    }

    // StringView::startsWith(ASCIILiteral).
    @inline(__always)
    func startsWith(_ literal: Swift.String) -> Bool {
        literal.utf8.count <= count && hasPrefix(literal)
    }

    // equalLettersIgnoringASCIICase(StringView, ASCIILiteral): same length, and each code unit equal to the literal's
    // after toASCIILowerUnchecked. This is also how a SortedArrayMap keyed by PackedLettersLiteral matches a key.
    @inline(__always)
    func equalLettersIgnoringASCIICase(_ lowercaseLetters: Swift.String) -> Bool {
        guard lowercaseLetters.utf8.count == count else {
            return false
        }
        var position = 0
        for letter in lowercaseLetters.utf8 {
            if toASCIILowerUnchecked(self[position]) != Element(letter) {
                return false
            }
            position += 1
        }
        return true
    }

    @inline(__always)
    private func hasPrefix(_ literal: Swift.String) -> Bool {
        var position = 0
        for character in literal.utf8 {
            if self[position] != Element(character) {
                return false
            }
            position += 1
        }
        return true
    }
}

// Iterates the pieces of StringView::split(separator).
struct WTFSplitIterator<CodeUnit: WTFCodeUnit>: ~Escapable {
    private let string: Span<CodeUnit>
    private let separator: UInt32
    private var position = 0

    @_lifetime(copy string)
    init(_ string: Span<CodeUnit>, separator: Unicode.Scalar) {
        self.string = string
        self.separator = separator.value
    }

    // Whether next() would return nil.
    var isAtEnd: Bool {
        var position = self.position
        while position < string.count && UInt32(string[position]) == separator {
            position += 1
        }
        return position == string.count
    }

    // The range of the next piece in the string, or nil after the last one.
    mutating func nextRange() -> Range<Int>? {
        while position < string.count && UInt32(string[position]) == separator {
            position += 1
        }
        guard position < string.count else {
            return nil
        }
        let start = position
        while position < string.count && UInt32(string[position]) != separator {
            position += 1
        }
        return start..<position
    }

    // The next piece, or nil after the last one.
    @_lifetime(copy self)
    mutating func next() -> Span<CodeUnit>? {
        guard let range = nextRange() else {
            return nil
        }
        return string.extracting(range)
    }
}

// MARK: Building Latin-1 Strings

// Where a string-building function writes its characters: makeLatin1String() runs it once into a Latin1Length to size
// the String, then into the String's own characters, so the String is the only allocation.
protocol Latin1Output: ~Copyable, ~Escapable {
    mutating func append(_ character: UInt8)
    mutating func append(_ literal: Swift.String)
}

extension Latin1Output where Self: ~Copyable, Self: ~Escapable {
    mutating func append(_ literal: Swift.String) {
        for character in literal.utf8 {
            append(character)
        }
    }

    // makeString()'s integers: decimal, no padding.
    @inline(__always)
    mutating func appendDecimal<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        var divisor: T = 1
        while value / divisor >= 10 {
            divisor *= 10
        }
        while divisor > 0 {
            append(0x30 + UInt8(truncatingIfNeeded: value / divisor % 10))
            divisor /= 10
        }
    }

    // hex(value, minimumDigits): uppercase, as many digits as value needs and at least minimumDigits.
    @inline(__always)
    mutating func appendHex<T: FixedWidthInteger & UnsignedInteger>(_ value: T, minimumDigits: Int = 1) {
        var digitCount = max(minimumDigits, 1)
        while digitCount < T.bitWidth / 4 && value >> (4 * digitCount) != 0 {
            digitCount += 1
        }
        for position in (0..<digitCount).reversed() {
            let digit = UInt8(truncatingIfNeeded: value >> (4 * position)) & 0xF
            append(digit < 10 ? 0x30 + digit : 0x37 + digit)
        }
    }
}

protocol Latin1StringFormat: ~Escapable {
    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output)
}

struct Latin1Length: Latin1Output {
    private(set) var count = 0

    mutating func append(_ character: UInt8) {
        count += 1
    }

    mutating func append(_ literal: Swift.String) {
        count += literal.utf8.count
    }
}

struct Latin1Writer: Latin1Output, ~Copyable, ~Escapable {
    private var characters: MutableSpan<UInt8>
    private var position = 0

    @_lifetime(copy characters)
    init(_ characters: consuming MutableSpan<UInt8>) {
        self.characters = characters
    }

    mutating func append(_ character: UInt8) {
        characters[position] = character
        position += 1
    }
}

func makeLatin1String<Format: Latin1StringFormat & ~Escapable>(_ format: borrowing Format) -> WTF.String {
    var length = Latin1Length()
    format.write(to: &length)
    var buffer = WebCore.MediaParserLatin1StringBuffer(UInt32(length.count))
    do {
        var writer = Latin1Writer(buffer.mutableSpan())
        format.write(to: &writer)
    }
    return buffer.takeString()
}

// MARK: Short strings

// A name of at most 16 characters that Swift compares with MediaParserShortNames, packed the way they are, so that a
// comparison is a few word operations. A MediaParserShortName holds its characters in memory order, which is the
// little-endian order of each word's value.
struct MediaParserName: Sendable {
    let length: UInt8
    let words: (UInt64, UInt64)
    // 0x20 in each byte that holds a character: what toASCIILowerUnchecked() ORs in.
    let lowercasingMasks: (UInt64, UInt64)

    init(_ name: Swift.String) {
        precondition(name.utf8.count <= 16)
        var words: (UInt64, UInt64) = (0, 0)
        var masks: (UInt64, UInt64) = (0, 0)
        for (index, character) in name.utf8.enumerated() {
            let shift = UInt64(8 * (index & 7))
            if index < 8 {
                words.0 |= UInt64(character) << shift
                masks.0 |= 0x20 << shift
            } else {
                words.1 |= UInt64(character) << shift
                masks.1 |= 0x20 << shift
            }
        }
        length = UInt8(name.utf8.count)
        self.words = (words.0.littleEndian, words.1.littleEndian)
        lowercasingMasks = (masks.0.littleEndian, masks.1.littleEndian)
    }

    // As Span's equals. The bytes of a MediaParserShortName past its length are 0.
    func matches(_ string: WebCore.MediaParserShortName) -> Bool {
        string.length == length && string.words.0 == words.0 && string.words.1 == words.1
    }

    // As Span's equalLettersIgnoringASCIICase, for a name whose characters are their own toASCIILowerUnchecked().
    func matchesIgnoringASCIICase(_ string: WebCore.MediaParserShortName) -> Bool {
        string.length == length && string.words.0 | lowercasingMasks.0 == words.0 && string.words.1 | lowercasingMasks.1 == words.1
    }
}

// Writes into a MediaParserShortString, which has room for every string that is written into one, a word at a time.
struct Latin1ShortStringWriter: Latin1Output {
    var string = WebCore.MediaParserShortString()
    var word: UInt64 = 0
    var count = 0

    @inline(__always)
    mutating func append(_ character: UInt8) {
        word |= UInt64(character) << UInt64(8 * (count & 7))
        count += 1
        if count & 7 == 0 {
            store(word, at: (count >> 3) - 1)
            word = 0
        }
    }

    @inline(__always)
    mutating func finish() -> WebCore.MediaParserShortString {
        if count & 7 != 0 {
            store(word, at: count >> 3)
        }
        string.length = UInt8(count)
        return string
    }

    // Each word's value has its characters in little-endian order; the string holds them in memory order.
    @inline(never)
    mutating func store(_ word: UInt64, at index: Int) {
        let word = word.littleEndian
        switch index {
        case 0: string.words.0 = word
        case 1: string.words.1 = word
        case 2: string.words.2 = word
        case 3: string.words.3 = word
        case 4: string.words.4 = word
        case 5: string.words.5 = word
        default: preconditionFailure("A MediaParserShortString holds 48 characters")
        }
    }
}

func makeShortString<Format: Latin1StringFormat & ~Escapable>(_ format: borrowing Format) -> WebCore.MediaParserShortString {
    var writer = Latin1ShortStringWriter()
    format.write(to: &writer)
    return writer.finish()
}

#endif // ENABLE_WEBCORE_SWIFT
