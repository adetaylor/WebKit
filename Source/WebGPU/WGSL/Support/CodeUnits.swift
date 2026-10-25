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

// Code-unit access to the source as stored (Latin-1 or UTF-16). Every offset and range counts code units; Latin-1 is
// zero-extended, so comparisons are WTF::equal across representations, with no normalisation.
extension SourceText {
    @_spi(Testing)
    public func codeUnit(at index: Int) -> UInt16 {
        switch storage {
        case .latin1(let codeUnits): UInt16(codeUnits[index])
        case .utf16(let codeUnits): codeUnits[index]
        }
    }

    @_spi(Testing)
    public func appendCodeUnits(_ range: Range<Int>, to units: inout ContiguousArray<UInt16>) {
        // Geometric growth: an exact reservation per call would copy the whole buffer on every append.
        if units.count + range.count > units.capacity {
            units.reserveCapacity(Swift.max(units.count + range.count, 2 * units.capacity))
        }
        switch storage {
        case .latin1(let codeUnits):
            // A long identifier is widened in bulk (vectorised); filling the room costs more than it saves for a short one.
            if range.count > 32 {
                widen(codeUnits, range, to: &units)
            } else {
                for codeUnit in codeUnits[range] {
                    units.append(UInt16(codeUnit))
                }
            }
        case .utf16(let codeUnits):
            units.append(contentsOf: codeUnits[range])
        }
    }

    @_spi(Testing)
    public func codeUnitsEqual(_ range: Range<Int>, _ other: ContiguousArray<UInt16>, _ otherRange: Range<Int>) -> Bool {
        guard range.count == otherRange.count else {
            return false
        }
        switch storage {
        case .latin1(let codeUnits): return equal(codeUnits, range.lowerBound, other, otherRange.lowerBound, range.count)
        case .utf16(let codeUnits): return equal(codeUnits, range.lowerBound, other, otherRange.lowerBound, range.count)
        }
    }

    @_spi(Testing)
    public func codeUnitsEqual(_ range: Range<Int>, _ other: SourceText, _ otherRange: Range<Int>) -> Bool {
        guard range.count == otherRange.count else {
            return false
        }
        switch (storage, other.storage) {
        case (.latin1(let a), .latin1(let b)): return equal(a, range.lowerBound, b, otherRange.lowerBound, range.count)
        case (.latin1(let a), .utf16(let b)): return equal(a, range.lowerBound, b, otherRange.lowerBound, range.count)
        case (.utf16(let a), .latin1(let b)): return equal(b, otherRange.lowerBound, a, range.lowerBound, range.count)
        case (.utf16(let a), .utf16(let b)): return equal(a, range.lowerBound, b, otherRange.lowerBound, range.count)
        }
    }
}

// Out of line, so that the store loop keeps the array's uniqueness check out of the loop and vectorises.
@inline(never)
private func widen(_ codeUnits: ContiguousArray<UInt8>, _ range: Range<Int>, to units: inout ContiguousArray<UInt16>) {
    var index = units.count
    units.append(contentsOf: repeatElement(0, count: range.count))
    for codeUnit in codeUnits[range] {
        units[index] = UInt16(codeUnit)
        index &+= 1
    }
}

// The loops below go over array slices with `for`, which the optimiser compiles without bounds checks and vectorises:
// identifiers can be long (Lexer.cpp sets no limit). The comparisons test a block of code units at a time.
private var comparisonBlock: Int { 256 }

private func equal(_ a: ContiguousArray<UInt8>, _ aStart: Int, _ b: ContiguousArray<UInt8>, _ bStart: Int, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let blockEnd = count &- offset > comparisonBlock ? offset &+ comparisonBlock : count
        var difference: UInt8 = 0
        var other = bStart &+ offset
        for codeUnit in a[(aStart &+ offset)..<(aStart &+ blockEnd)] {
            difference |= codeUnit ^ b[other]
            other &+= 1
        }
        guard difference == 0 else {
            return false
        }
        offset = blockEnd
    }
    return true
}

private func equal(_ a: ContiguousArray<UInt8>, _ aStart: Int, _ b: ContiguousArray<UInt16>, _ bStart: Int, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let blockEnd = count &- offset > comparisonBlock ? offset &+ comparisonBlock : count
        var difference: UInt16 = 0
        var other = bStart &+ offset
        for codeUnit in a[(aStart &+ offset)..<(aStart &+ blockEnd)] {
            difference |= UInt16(codeUnit) ^ b[other]
            other &+= 1
        }
        guard difference == 0 else {
            return false
        }
        offset = blockEnd
    }
    return true
}

private func equal(_ a: ContiguousArray<UInt16>, _ aStart: Int, _ b: ContiguousArray<UInt16>, _ bStart: Int, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let blockEnd = count &- offset > comparisonBlock ? offset &+ comparisonBlock : count
        var difference: UInt16 = 0
        var other = bStart &+ offset
        for codeUnit in a[(aStart &+ offset)..<(aStart &+ blockEnd)] {
            difference |= codeUnit ^ b[other]
            other &+= 1
        }
        guard difference == 0 else {
            return false
        }
        offset = blockEnd
    }
    return true
}

// The end of the run of ASCII letters, digits and "_" in `code` from `start` (the Lexer's identifier fast path), sixteen
// code units at a time.
func asciiIdentifierRunEnd(_ code: borrowing ContiguousArray<UInt8>, _ start: Int) -> Int {
    var index = start
    while code.count &- index >= 16 {
        var outside: UInt8 = 0
        for codeUnit in code[index..<(index &+ 16)] {
            outside |= asciiIdentifierBit(codeUnit) ^ 1
        }
        guard outside == 0 else {
            break
        }
        index &+= 16
    }
    while index < code.count && isASCIIIdentifierCharacter(UInt16(code[index])) {
        index &+= 1
    }
    return index
}

func asciiIdentifierRunEnd(_ code: borrowing ContiguousArray<UInt16>, _ start: Int) -> Int {
    var index = start
    while code.count &- index >= 16 {
        var outside: UInt8 = 0
        for codeUnit in code[index..<(index &+ 16)] {
            outside |= asciiIdentifierBit(codeUnit) ^ 1
        }
        guard outside == 0 else {
            break
        }
        index &+= 16
    }
    while index < code.count && isASCIIIdentifierCharacter(code[index]) {
        index &+= 1
    }
    return index
}

@inline(__always)
private func isASCIIIdentifierCharacter(_ codeUnit: UInt16) -> Bool {
    (codeUnit | 0x20) &- 0x61 < 26 || codeUnit &- 0x30 < 10 || codeUnit == 0x5F
}

// 1 for an ASCII letter, digit or "_", without branches.
@inline(__always)
private func asciiIdentifierBit(_ codeUnit: UInt8) -> UInt8 {
    let letter: UInt8 = (codeUnit | 0x20) &- 0x61 < 26 ? 1 : 0
    let digit: UInt8 = codeUnit &- 0x30 < 10 ? 1 : 0
    let underscore: UInt8 = codeUnit == 0x5F ? 1 : 0
    return letter | digit | underscore
}

@inline(__always)
private func asciiIdentifierBit(_ codeUnit: UInt16) -> UInt8 {
    let letter: UInt8 = (codeUnit | 0x20) &- 0x61 < 26 ? 1 : 0
    let digit: UInt8 = codeUnit &- 0x30 < 10 ? 1 : 0
    let underscore: UInt8 = codeUnit == 0x5F ? 1 : 0
    return letter | digit | underscore
}
