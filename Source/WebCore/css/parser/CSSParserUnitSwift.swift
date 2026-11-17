// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2021 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSParserToken

// The CSSUnitType of a unit name, which the tokenizer looks up for every dimension token, and
// CSSParserToken::stringToUnitType for the C++ that looks a unit up by name.

/// A unit's table entry: its key, as `cssParserUnitType(packed:length:)` makes it, with the unit in byte 6.
@inline(always)
private func cssParserUnitEntry(_ key: UInt64, _ unit: WebCore.CSSUnitType) -> UInt64 {
    key | UInt64(unit.rawValue) &<< 48
}

private let cssParserUnitHashMultiplier: UInt64 = 0xCF04_1060_30F7_6125

/// Each unit's entry in the slot of its key, `key &* cssParserUnitHashMultiplier &>> 57`; 0 in the other slots.
private let cssParserUnitTable: InlineArray<128, UInt64> = [
    cssParserUnitEntry(0x0300_0000_0069_7163, .Cqi), // 0: cqi
    0,
    cssParserUnitEntry(0x0300_0000_0069_7673, .Svi), // 2: svi
    cssParserUnitEntry(0x0400_0000_7861_6D76, .Vmax), // 3: vmax
    0,
    cssParserUnitEntry(0x0500_006E_696D_7163, .Cqmin), // 5: cqmin
    0,
    cssParserUnitEntry(0x0500_006E_696D_7673, .Svmin), // 7: svmin
    0,
    cssParserUnitEntry(0x0200_0000_0000_6D63, .Cm), // 9: cm
    cssParserUnitEntry(0x0500_006D_6571_5F5F, .QuirkyEm), // 10: __qem
    0,
    0,
    0,
    0,
    0,
    0,
    cssParserUnitEntry(0x0100_0000_0000_0073, .S), // 17: s
    0,
    0,
    cssParserUnitEntry(0x0200_0000_0000_6D6D, .Mm), // 20: mm
    0,
    0,
    cssParserUnitEntry(0x0100_0000_0000_0078, .X), // 23: x
    cssParserUnitEntry(0x0300_0000_0070_6163, .Cap), // 24: cap
    cssParserUnitEntry(0x0300_0000_006D_6572, .Rem), // 25: rem
    0,
    0,
    0,
    0,
    0,
    0,
    cssParserUnitEntry(0x0300_0000_0077_766C, .Lvw), // 32: lvw
    cssParserUnitEntry(0x0200_0000_0000_736D, .Ms), // 33: ms
    cssParserUnitEntry(0x0200_0000_0000_6276, .Vb), // 34: vb
    cssParserUnitEntry(0x0200_0000_0000_686C, .Lh), // 35: lh
    0,
    cssParserUnitEntry(0x0300_0000_0068_766C, .Lvh), // 37: lvh
    cssParserUnitEntry(0x0500_0078_616D_766C, .Lvmax), // 38: lvmax
    0,
    0,
    cssParserUnitEntry(0x0200_0000_0000_7A68, .Hz), // 41: hz
    0,
    0,
    0,
    cssParserUnitEntry(0x0300_0000_0069_766C, .Lvi), // 45: lvi
    cssParserUnitEntry(0x0200_0000_0000_6876, .Vh), // 46: vh
    0,
    cssParserUnitEntry(0x0200_0000_0000_6976, .Vi), // 48: vi
    0,
    cssParserUnitEntry(0x0500_006E_696D_766C, .Lvmin), // 50: lvmin
    0,
    0,
    cssParserUnitEntry(0x0300_0000_007A_686B, .Khz), // 53: khz
    0,
    cssParserUnitEntry(0x0200_0000_0000_6370, .Pc), // 55: pc
    cssParserUnitEntry(0x0300_0000_0062_7664, .Dvb), // 56: dvb
    0,
    cssParserUnitEntry(0x0400_0000_6461_7267, .Grad), // 58: grad
    0,
    cssParserUnitEntry(0x0400_0000_7870_7064, .Dppx), // 60: dppx
    0,
    cssParserUnitEntry(0x0300_0000_0067_6564, .Deg), // 62: deg
    0,
    0,
    cssParserUnitEntry(0x0400_0000_6D63_7064, .Dpcm), // 65: dpcm
    cssParserUnitEntry(0x0100_0000_0000_0071, .Q), // 66: q
    0,
    0,
    0,
    cssParserUnitEntry(0x0300_0000_0062_7163, .Cqb), // 70: cqb
    cssParserUnitEntry(0x0300_0000_0064_6172, .Rad), // 71: rad
    0,
    cssParserUnitEntry(0x0300_0000_0062_7673, .Svb), // 73: svb
    cssParserUnitEntry(0x0200_0000_0000_7266, .Fr), // 74: fr
    0,
    cssParserUnitEntry(0x0200_0000_0000_7776, .Vw), // 76: vw
    0,
    0,
    cssParserUnitEntry(0x0300_0000_0063_6972, .Ric), // 79: ric
    cssParserUnitEntry(0x0400_0000_7061_6372, .Rcap), // 80: rcap
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    cssParserUnitEntry(0x0200_0000_0000_6D65, .Em), // 88: em
    cssParserUnitEntry(0x0200_0000_0000_7470, .Pt), // 89: pt
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    cssParserUnitEntry(0x0200_0000_0000_7870, .Px), // 97: px
    cssParserUnitEntry(0x0200_0000_0000_6369, .Ic), // 98: ic
    cssParserUnitEntry(0x0400_0000_6E69_6D76, .Vmin), // 99: vmin
    cssParserUnitEntry(0x0300_0000_0077_7664, .Dvw), // 100: dvw
    cssParserUnitEntry(0x0300_0000_0069_7064, .Dpi), // 101: dpi
    0,
    0,
    0,
    cssParserUnitEntry(0x0300_0000_0068_7664, .Dvh), // 105: dvh
    cssParserUnitEntry(0x0500_0078_616D_7664, .Dvmax), // 106: dvmax
    0,
    cssParserUnitEntry(0x0300_0000_0068_6372, .Rch), // 108: rch
    0,
    cssParserUnitEntry(0x0400_0000_6E72_7574, .Turn), // 110: turn
    cssParserUnitEntry(0x0200_0000_0000_7865, .Ex), // 111: ex
    0,
    cssParserUnitEntry(0x0300_0000_0069_7664, .Dvi), // 113: dvi
    cssParserUnitEntry(0x0300_0000_0077_7163, .Cqw), // 114: cqw
    cssParserUnitEntry(0x0300_0000_0078_6572, .Rex), // 115: rex
    cssParserUnitEntry(0x0300_0000_0062_766C, .Lvb), // 116: lvb
    cssParserUnitEntry(0x0300_0000_0077_7673, .Svw), // 117: svw
    cssParserUnitEntry(0x0500_006E_696D_7664, .Dvmin), // 118: dvmin
    cssParserUnitEntry(0x0300_0000_0068_7163, .Cqh), // 119: cqh
    cssParserUnitEntry(0x0200_0000_0000_6E69, .In), // 120: in
    cssParserUnitEntry(0x0500_0078_616D_7163, .Cqmax), // 121: cqmax
    cssParserUnitEntry(0x0300_0000_0068_7673, .Svh), // 122: svh
    cssParserUnitEntry(0x0500_0078_616D_7673, .Svmax), // 123: svmax
    0,
    0,
    cssParserUnitEntry(0x0300_0000_0068_6C72, .Rlh), // 126: rlh
    cssParserUnitEntry(0x0200_0000_0000_6863, .Ch), // 127: ch
]

/// The `CSSUnitType` raw value of the unit name packed in `packed`, its first eight code units one per byte from the
/// low byte, a code unit that is not ASCII as 0, and of length `length`; `Unknown` for a name that is not a unit's.
/// Unit names match ASCII case-insensitively.
func cssParserUnitType(packed: UInt64, length: Int) -> UInt8 {
    // No unit name is longer than five characters, so the bytes above the fifth are 0 for every name it matches.
    guard length >= 1 && length <= 5 else { return WebCore.CSSUnitType.Unknown.rawValue }
    // ASCII-lowercases every byte at once. Each byte is below 0x80, so neither sum carries into the next byte, and a
    // byte gets its top bit from the first sum and not from the second exactly when it is `A` to `Z`.
    let ones: UInt64 = 0x0101_0101_0101_0101
    let upper = (packed &+ 0x3F &* ones) & ~(packed &+ 0x25 &* ones) & (0x80 &* ones)
    // The key holds the length in its top byte: a code unit that is not ASCII packs as 0, and only the length tells
    // "q" followed by one from "q".
    let key = packed | upper &>> 2 | UInt64(truncatingIfNeeded: length) &<< 56
    // The table's slot for the key, a multiply-shift hash, holds no other unit's key; any other key fails the compare.
    let slot = Int(truncatingIfNeeded: (key &* cssParserUnitHashMultiplier) &>> 57)
    let difference = cssParserUnitTable[slot] ^ key
    // Equal outside byte 6, which holds the entry's unit and is 0 in every key.
    return difference & 0xFF00_FFFF_FFFF_FFFF == 0 ? UInt8(truncatingIfNeeded: difference &>> 48) : WebCore.CSSUnitType.Unknown.rawValue
}

/// The `CSSUnitType` of a dimension token's unit, as `cssParserUnitType(packed:length:)` finds it.
@inline(always)
func cssParserUnitType<Unit: CSSCodeUnit>(_ name: Span<Unit>) -> UInt8 {
    let length = name.count
    guard length >= 1 && length <= 5 else { return WebCore.CSSUnitType.Unknown.rawValue }
    var packed: UInt64 = 0
    for i in 0..<length {
        let unit = UInt64(truncatingIfNeeded: name[i])
        // The shift is at most 32.
        packed |= (unit < 0x80 ? unit : 0) &<< (i &* 8)
    }
    return cssParserUnitType(packed: packed, length: length)
}

/// CSSParserToken::stringToUnitType: `characters` is the name's first eight code units, packed as for
/// `cssParserUnitType(packed:length:)`, and `length` its length.
@_expose(Cxx)
func cssParserUnitTypeForName(_ characters: UInt64, _ length: UInt32) -> UInt8 {
    cssParserUnitType(packed: characters, length: Int(length))
}
