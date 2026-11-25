//  Copyright (C) 1999-2000 Harri Porten (porten@kde.org)
//  Copyright (C) 2006-2024 Apple Inc. All rights reserved.
//  Copyright (C) 2007 Cameron Zwarich (cwzwarich@uwaterloo.ca)
//  Copyright (C) 2010 Zoltan Herczeg (zherczeg@inf.u-szeged.hu)
//  Copyright (C) 2012 Mathias Bynens (mathias@qiwi.be)
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.

internal import JSCSwiftBoundary

enum CharacterType: UInt8, Comparable {
    // The first three types are fixed, and also used for identifying
    // ASCII alpha and alphanumeric characters (see isIdentStart and isIdentPart).
    case latin1IdentifierStart
    case zero
    case number

    // For single-byte characters grandfathered into Other_ID_Continue -- namely just U+00B7 MIDDLE DOT.
    // (http://unicode.org/reports/tr31/#Backward_Compatibility)
    //
    // Character types are divided into two groups depending on whether they can be part of an
    // identifier or not. Those whose type value is less or equal than otherIdentifierPart can be
    // part of an identifier. (See the CharacterType definition for more details.)
    case otherIdentifierPart
    case backSlash // Keep the ordering until this. We use this ordering to detect identifier-part or back-slash quickly.

    case invalid
    case lineTerminator
    case exclamationMark
    case openParen
    case closeParen
    case openBracket
    case closeBracket
    case comma
    case colon
    case question
    case tilde
    case quote
    case backQuote
    case dot
    case slash
    case semicolon
    case openBrace
    case closeBrace

    case add
    case sub
    case multiply
    case modulo
    case and
    case xor
    case or
    case less
    case greater
    case equal

    // Other types (only one so far)
    case whiteSpace
    case hash
    case privateIdentifierStart
    case nonLatin1IdentifierStart

    static func < (a: CharacterType, b: CharacterType) -> Bool { a.rawValue < b.rawValue }
}

// 256 Latin-1 codes
// An index of type UInt8 into an InlineArray of 256 needs no bounds check.
private let typesOfLatin1Characters: InlineArray<256, CharacterType> = [
    .invalid, // 0 - Null
    .invalid, // 1 - Start of Heading
    .invalid, // 2 - Start of Text
    .invalid, // 3 - End of Text
    .invalid, // 4 - End of Transm.
    .invalid, // 5 - Enquiry
    .invalid, // 6 - Acknowledgment
    .invalid, // 7 - Bell
    .invalid, // 8 - Back Space
    .whiteSpace, // 9 - Horizontal Tab
    .lineTerminator, // 10 - Line Feed
    .whiteSpace, // 11 - Vertical Tab
    .whiteSpace, // 12 - Form Feed
    .lineTerminator, // 13 - Carriage Return
    .invalid, // 14 - Shift Out
    .invalid, // 15 - Shift In
    .invalid, // 16 - Data Line Escape
    .invalid, // 17 - Device Control 1
    .invalid, // 18 - Device Control 2
    .invalid, // 19 - Device Control 3
    .invalid, // 20 - Device Control 4
    .invalid, // 21 - Negative Ack.
    .invalid, // 22 - Synchronous Idle
    .invalid, // 23 - End of Transmit
    .invalid, // 24 - Cancel
    .invalid, // 25 - End of Medium
    .invalid, // 26 - Substitute
    .invalid, // 27 - Escape
    .invalid, // 28 - File Separator
    .invalid, // 29 - Group Separator
    .invalid, // 30 - Record Separator
    .invalid, // 31 - Unit Separator
    .whiteSpace, // 32 - Space
    .exclamationMark, // 33 - !
    .quote, // 34 - "
    .hash, // 35 - #
    .latin1IdentifierStart, // 36 - $
    .modulo, // 37 - %
    .and, // 38 - &
    .quote, // 39 - '
    .openParen, // 40 - (
    .closeParen, // 41 - )
    .multiply, // 42 - *
    .add, // 43 - +
    .comma, // 44 - ,
    .sub, // 45 - -
    .dot, // 46 - .
    .slash, // 47 - /
    .zero, // 48 - 0
    .number, // 49 - 1
    .number, // 50 - 2
    .number, // 51 - 3
    .number, // 52 - 4
    .number, // 53 - 5
    .number, // 54 - 6
    .number, // 55 - 7
    .number, // 56 - 8
    .number, // 57 - 9
    .colon, // 58 - :
    .semicolon, // 59 - ;
    .less, // 60 - <
    .equal, // 61 - =
    .greater, // 62 - >
    .question, // 63 - ?
    .privateIdentifierStart, // 64 - @
    .latin1IdentifierStart, // 65 - A
    .latin1IdentifierStart, // 66 - B
    .latin1IdentifierStart, // 67 - C
    .latin1IdentifierStart, // 68 - D
    .latin1IdentifierStart, // 69 - E
    .latin1IdentifierStart, // 70 - F
    .latin1IdentifierStart, // 71 - G
    .latin1IdentifierStart, // 72 - H
    .latin1IdentifierStart, // 73 - I
    .latin1IdentifierStart, // 74 - J
    .latin1IdentifierStart, // 75 - K
    .latin1IdentifierStart, // 76 - L
    .latin1IdentifierStart, // 77 - M
    .latin1IdentifierStart, // 78 - N
    .latin1IdentifierStart, // 79 - O
    .latin1IdentifierStart, // 80 - P
    .latin1IdentifierStart, // 81 - Q
    .latin1IdentifierStart, // 82 - R
    .latin1IdentifierStart, // 83 - S
    .latin1IdentifierStart, // 84 - T
    .latin1IdentifierStart, // 85 - U
    .latin1IdentifierStart, // 86 - V
    .latin1IdentifierStart, // 87 - W
    .latin1IdentifierStart, // 88 - X
    .latin1IdentifierStart, // 89 - Y
    .latin1IdentifierStart, // 90 - Z
    .openBracket, // 91 - [
    .backSlash, // 92 - \
    .closeBracket, // 93 - ]
    .xor, // 94 - ^
    .latin1IdentifierStart, // 95 - _
    .backQuote, // 96 - `
    .latin1IdentifierStart, // 97 - a
    .latin1IdentifierStart, // 98 - b
    .latin1IdentifierStart, // 99 - c
    .latin1IdentifierStart, // 100 - d
    .latin1IdentifierStart, // 101 - e
    .latin1IdentifierStart, // 102 - f
    .latin1IdentifierStart, // 103 - g
    .latin1IdentifierStart, // 104 - h
    .latin1IdentifierStart, // 105 - i
    .latin1IdentifierStart, // 106 - j
    .latin1IdentifierStart, // 107 - k
    .latin1IdentifierStart, // 108 - l
    .latin1IdentifierStart, // 109 - m
    .latin1IdentifierStart, // 110 - n
    .latin1IdentifierStart, // 111 - o
    .latin1IdentifierStart, // 112 - p
    .latin1IdentifierStart, // 113 - q
    .latin1IdentifierStart, // 114 - r
    .latin1IdentifierStart, // 115 - s
    .latin1IdentifierStart, // 116 - t
    .latin1IdentifierStart, // 117 - u
    .latin1IdentifierStart, // 118 - v
    .latin1IdentifierStart, // 119 - w
    .latin1IdentifierStart, // 120 - x
    .latin1IdentifierStart, // 121 - y
    .latin1IdentifierStart, // 122 - z
    .openBrace, // 123 - {
    .or, // 124 - |
    .closeBrace, // 125 - }
    .tilde, // 126 - ~
    .invalid, // 127 - Delete
    .invalid, // 128 - Cc category
    .invalid, // 129 - Cc category
    .invalid, // 130 - Cc category
    .invalid, // 131 - Cc category
    .invalid, // 132 - Cc category
    .invalid, // 133 - Cc category
    .invalid, // 134 - Cc category
    .invalid, // 135 - Cc category
    .invalid, // 136 - Cc category
    .invalid, // 137 - Cc category
    .invalid, // 138 - Cc category
    .invalid, // 139 - Cc category
    .invalid, // 140 - Cc category
    .invalid, // 141 - Cc category
    .invalid, // 142 - Cc category
    .invalid, // 143 - Cc category
    .invalid, // 144 - Cc category
    .invalid, // 145 - Cc category
    .invalid, // 146 - Cc category
    .invalid, // 147 - Cc category
    .invalid, // 148 - Cc category
    .invalid, // 149 - Cc category
    .invalid, // 150 - Cc category
    .invalid, // 151 - Cc category
    .invalid, // 152 - Cc category
    .invalid, // 153 - Cc category
    .invalid, // 154 - Cc category
    .invalid, // 155 - Cc category
    .invalid, // 156 - Cc category
    .invalid, // 157 - Cc category
    .invalid, // 158 - Cc category
    .invalid, // 159 - Cc category
    .whiteSpace, // 160 - Zs category (nbsp)
    .invalid, // 161 - Po category
    .invalid, // 162 - Sc category
    .invalid, // 163 - Sc category
    .invalid, // 164 - Sc category
    .invalid, // 165 - Sc category
    .invalid, // 166 - So category
    .invalid, // 167 - So category
    .invalid, // 168 - Sk category
    .invalid, // 169 - So category
    .latin1IdentifierStart, // 170 - Ll category
    .invalid, // 171 - Pi category
    .invalid, // 172 - Sm category
    .invalid, // 173 - Cf category
    .invalid, // 174 - So category
    .invalid, // 175 - Sk category
    .invalid, // 176 - So category
    .invalid, // 177 - Sm category
    .invalid, // 178 - No category
    .invalid, // 179 - No category
    .invalid, // 180 - Sk category
    .latin1IdentifierStart, // 181 - Ll category
    .invalid, // 182 - So category
    .otherIdentifierPart, // 183 - Po category
    .invalid, // 184 - Sk category
    .invalid, // 185 - No category
    .latin1IdentifierStart, // 186 - Ll category
    .invalid, // 187 - Pf category
    .invalid, // 188 - No category
    .invalid, // 189 - No category
    .invalid, // 190 - No category
    .invalid, // 191 - Po category
    .latin1IdentifierStart, // 192 - Lu category
    .latin1IdentifierStart, // 193 - Lu category
    .latin1IdentifierStart, // 194 - Lu category
    .latin1IdentifierStart, // 195 - Lu category
    .latin1IdentifierStart, // 196 - Lu category
    .latin1IdentifierStart, // 197 - Lu category
    .latin1IdentifierStart, // 198 - Lu category
    .latin1IdentifierStart, // 199 - Lu category
    .latin1IdentifierStart, // 200 - Lu category
    .latin1IdentifierStart, // 201 - Lu category
    .latin1IdentifierStart, // 202 - Lu category
    .latin1IdentifierStart, // 203 - Lu category
    .latin1IdentifierStart, // 204 - Lu category
    .latin1IdentifierStart, // 205 - Lu category
    .latin1IdentifierStart, // 206 - Lu category
    .latin1IdentifierStart, // 207 - Lu category
    .latin1IdentifierStart, // 208 - Lu category
    .latin1IdentifierStart, // 209 - Lu category
    .latin1IdentifierStart, // 210 - Lu category
    .latin1IdentifierStart, // 211 - Lu category
    .latin1IdentifierStart, // 212 - Lu category
    .latin1IdentifierStart, // 213 - Lu category
    .latin1IdentifierStart, // 214 - Lu category
    .invalid, // 215 - Sm category
    .latin1IdentifierStart, // 216 - Lu category
    .latin1IdentifierStart, // 217 - Lu category
    .latin1IdentifierStart, // 218 - Lu category
    .latin1IdentifierStart, // 219 - Lu category
    .latin1IdentifierStart, // 220 - Lu category
    .latin1IdentifierStart, // 221 - Lu category
    .latin1IdentifierStart, // 222 - Lu category
    .latin1IdentifierStart, // 223 - Ll category
    .latin1IdentifierStart, // 224 - Ll category
    .latin1IdentifierStart, // 225 - Ll category
    .latin1IdentifierStart, // 226 - Ll category
    .latin1IdentifierStart, // 227 - Ll category
    .latin1IdentifierStart, // 228 - Ll category
    .latin1IdentifierStart, // 229 - Ll category
    .latin1IdentifierStart, // 230 - Ll category
    .latin1IdentifierStart, // 231 - Ll category
    .latin1IdentifierStart, // 232 - Ll category
    .latin1IdentifierStart, // 233 - Ll category
    .latin1IdentifierStart, // 234 - Ll category
    .latin1IdentifierStart, // 235 - Ll category
    .latin1IdentifierStart, // 236 - Ll category
    .latin1IdentifierStart, // 237 - Ll category
    .latin1IdentifierStart, // 238 - Ll category
    .latin1IdentifierStart, // 239 - Ll category
    .latin1IdentifierStart, // 240 - Ll category
    .latin1IdentifierStart, // 241 - Ll category
    .latin1IdentifierStart, // 242 - Ll category
    .latin1IdentifierStart, // 243 - Ll category
    .latin1IdentifierStart, // 244 - Ll category
    .latin1IdentifierStart, // 245 - Ll category
    .latin1IdentifierStart, // 246 - Ll category
    .invalid, // 247 - Sm category
    .latin1IdentifierStart, // 248 - Ll category
    .latin1IdentifierStart, // 249 - Ll category
    .latin1IdentifierStart, // 250 - Ll category
    .latin1IdentifierStart, // 251 - Ll category
    .latin1IdentifierStart, // 252 - Ll category
    .latin1IdentifierStart, // 253 - Ll category
    .latin1IdentifierStart, // 254 - Ll category
    .latin1IdentifierStart, // 255 - Ll category
]

extension CharacterType {
    @inline(always)
    init(latin1 c: UInt8) {
        self = typesOfLatin1Characters[Int(c)]
    }
}

// This table provides the character that results from \X where X is the index in the table beginning
// with SPACE. A table value of 0 means that more processing needs to be done.
private let singleCharacterEscapeValuesForASCII: InlineArray<128, UInt8> = [
    0x00, // 0 - Null
    0x00, // 1 - Start of Heading
    0x00, // 2 - Start of Text
    0x00, // 3 - End of Text
    0x00, // 4 - End of Transm.
    0x00, // 5 - Enquiry
    0x00, // 6 - Acknowledgment
    0x00, // 7 - Bell
    0x00, // 8 - Back Space
    0x00, // 9 - Horizontal Tab
    0x00, // 10 - Line Feed
    0x00, // 11 - Vertical Tab
    0x00, // 12 - Form Feed
    0x00, // 13 - Carriage Return
    0x00, // 14 - Shift Out
    0x00, // 15 - Shift In
    0x00, // 16 - Data Line Escape
    0x00, // 17 - Device Control 1
    0x00, // 18 - Device Control 2
    0x00, // 19 - Device Control 3
    0x00, // 20 - Device Control 4
    0x00, // 21 - Negative Ack.
    0x00, // 22 - Synchronous Idle
    0x00, // 23 - End of Transmit
    0x00, // 24 - Cancel
    0x00, // 25 - End of Medium
    0x00, // 26 - Substitute
    0x00, // 27 - Escape
    0x00, // 28 - File Separator
    0x00, // 29 - Group Separator
    0x00, // 30 - Record Separator
    0x00, // 31 - Unit Separator
    0x20, // 32 - Space
    0x21, // 33 - !
    0x22, // 34 - "
    0x23, // 35 - #
    0x24, // 36 - $
    0x25, // 37 - %
    0x26, // 38 - &
    0x27, // 39 - '
    0x28, // 40 - (
    0x29, // 41 - )
    0x2A, // 42 - *
    0x2B, // 43 - +
    0x2C, // 44 - ,
    0x2D, // 45 - -
    0x2E, // 46 - .
    0x2F, // 47 - /
    0x00, // 48 - 0
    0x00, // 49 - 1
    0x00, // 50 - 2
    0x00, // 51 - 3
    0x00, // 52 - 4
    0x00, // 53 - 5
    0x00, // 54 - 6
    0x00, // 55 - 7
    0x00, // 56 - 8
    0x00, // 57 - 9
    0x3A, // 58 - :
    0x3B, // 59 - ;
    0x3C, // 60 - <
    0x3D, // 61 - =
    0x3E, // 62 - >
    0x3F, // 63 - ?
    0x40, // 64 - @
    0x41, // 65 - A
    0x42, // 66 - B
    0x43, // 67 - C
    0x44, // 68 - D
    0x45, // 69 - E
    0x46, // 70 - F
    0x47, // 71 - G
    0x48, // 72 - H
    0x49, // 73 - I
    0x4A, // 74 - J
    0x4B, // 75 - K
    0x4C, // 76 - L
    0x4D, // 77 - M
    0x4E, // 78 - N
    0x4F, // 79 - O
    0x50, // 80 - P
    0x51, // 81 - Q
    0x52, // 82 - R
    0x53, // 83 - S
    0x54, // 84 - T
    0x55, // 85 - U
    0x56, // 86 - V
    0x57, // 87 - W
    0x58, // 88 - X
    0x59, // 89 - Y
    0x5A, // 90 - Z
    0x5B, // 91 - [
    0x5C, // 92 - \
    0x5D, // 93 - ]
    0x5E, // 94 - ^
    0x5F, // 95 - _
    0x60, // 96 - `
    0x61, // 97 - a
    0x08, // 98 - b
    0x63, // 99 - c
    0x64, // 100 - d
    0x65, // 101 - e
    0x0C, // 102 - f
    0x67, // 103 - g
    0x68, // 104 - h
    0x69, // 105 - i
    0x6A, // 106 - j
    0x6B, // 107 - k
    0x6C, // 108 - l
    0x6D, // 109 - m
    0x0A, // 110 - n
    0x6F, // 111 - o
    0x70, // 112 - p
    0x71, // 113 - q
    0x0D, // 114 - r
    0x73, // 115 - s
    0x09, // 116 - t
    0x00, // 117 - u
    0x0B, // 118 - v
    0x77, // 119 - w
    0x00, // 120 - x
    0x79, // 121 - y
    0x7A, // 122 - z
    0x7B, // 123 - {
    0x7C, // 124 - |
    0x7D, // 125 - }
    0x7E, // 126 - ~
    0x00, // 127 - Delete
]

/// The unsigned integers a character or code point is read as: a code unit of either width, and a code point (UInt32).
protocol LexerCodePoint: FixedWidthInteger & UnsignedInteger {}
extension UInt32: LexerCodePoint {}

extension LexerCodePoint {
    @inline(always)
    static func ascii(_ scalar: Unicode.Scalar) -> Self {
        Self(truncatingIfNeeded: scalar.value)
    }

    @inline(always)
    var isLatin1: Bool { self <= 0xFF }

    // JavaScript white space does not include the line terminators; those are isLineTerminator below.
    @inline(always)
    var isWhiteSpace: Bool {
        if isLatin1 {
            let c = UInt8(truncatingIfNeeded: self)
            return c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C || c == 0xA0
        }
        // Non-Latin1 Zs category (Space_Separator) + BOM
        return JSC.isNonLatin1WhiteSpace(UInt16(truncatingIfNeeded: self))
    }

    @inline(always)
    var isLineTerminator: Bool {
        // (c & ~1) == 0x2028 covers both LS (U+2028) and PS (U+2029).
        self == 0x0D || self == 0x0A || UInt32(self) & ~1 == 0x2028
    }

    // character < 0xE for Latin-1, in a form that also holds for UTF-16.
    @inline(always)
    var needsLiteralSpecialHandling: Bool {
        (UInt32(self) &- 0xE) & 0x2000 != 0
    }

    @inline(always)
    var isNonLatin1IdentStart: Bool {
        JSC.isNonLatin1IdentifierStart(UInt32(self))
    }

    @inline(always)
    var isIdentStart: Bool {
        if !isLatin1 {
            return isNonLatin1IdentStart
        }
        return CharacterType(latin1: UInt8(truncatingIfNeeded: self)) == .latin1IdentifierStart
    }

    @inline(always)
    var cannotBeIdentStart: Bool {
        if isLatin1 {
            return !isIdentStart && self != 0x5C
        }
        return isWhiteSpace || isLineTerminator
    }

    // Out of line, so the ICU call stays out of the scan loops.
    @inline(never)
    var isNonLatin1IdentPart: Bool {
        JSC.isNonLatin1IdentifierPart(UInt32(self))
    }

    @inline(always)
    var isIdentPart: Bool {
        if !isLatin1 {
            return isNonLatin1IdentPart
        }

        // Character types are divided into two groups depending on whether they can be part of an
        // identifier or not. Those whose type value is less or equal than otherIdentifierPart can be
        // part of an identifier. (See the CharacterType definition for more details.)
        return CharacterType(latin1: UInt8(truncatingIfNeeded: self)) <= .otherIdentifierPart
    }

    @inline(always)
    var isSingleCharacterIdentPart: Bool {
        if isLatin1 {
            return isIdentPart
        }
        return !isSurrogate && isIdentPart
    }

    // NOTE: This may give false negatives (for non-ascii) but won't give false positives.
    // This means it can be used to detect the end of a keyword (all keywords are ascii)
    @inline(always)
    var cannotBeIdentPartOrEscapeStart: Bool {
        if isLatin1 {
            return !isIdentPart && self != 0x5C
        }
        return isWhiteSpace || isLineTerminator
    }

    // ICU's U16_IS_SURROGATE, U16_IS_LEAD and U16_IS_TRAIL. The last two test one bit and are meaningful only for a
    // surrogate.
    @inline(always)
    var isSurrogate: Bool { UInt32(self) & 0xFFFF_F800 == 0xD800 }
    @inline(always)
    var isLeadSurrogate: Bool { UInt32(self) & 0xFFFF_FC00 == 0xD800 }
    @inline(always)
    var isTrailSurrogate: Bool { UInt32(self) & 0xFFFF_FC00 == 0xDC00 }
    @inline(always)
    var surrogateIsLead: Bool { UInt32(self) & 0x400 == 0 }
    @inline(always)
    var surrogateIsTrail: Bool { UInt32(self) & 0x400 != 0 }

    @inline(always)
    var isASCIIDigit: Bool {
        self >= 0x30 && self <= 0x39
    }

    @inline(always)
    var isASCIIHexDigit: Bool {
        isASCIIDigit || (self | 0x20 >= 0x61 && self | 0x20 <= 0x66)
    }

    @inline(always)
    var isASCIIBinaryDigit: Bool {
        self == 0x30 || self == 0x31
    }

    @inline(always)
    var isASCIIOctalDigit: Bool {
        self >= 0x30 && self <= 0x37
    }

    @inline(always)
    var isASCIIDigitOrSeparator: Bool {
        isASCIIDigit || self == 0x5F
    }

    @inline(always)
    var isASCIIHexDigitOrSeparator: Bool {
        isASCIIHexDigit || self == 0x5F
    }

    @inline(always)
    var isASCIIBinaryDigitOrSeparator: Bool {
        isASCIIBinaryDigit || self == 0x5F
    }

    @inline(always)
    var isASCIIOctalDigitOrSeparator: Bool {
        isASCIIOctalDigit || self == 0x5F
    }

    /// `expectedASCIILowercaseLetter` must be an ASCII lowercase letter.
    @inline(always)
    func isASCIIAlphaCaselessEqual(_ expectedASCIILowercaseLetter: UInt8) -> Bool {
        UInt32(truncatingIfNeeded: self) | 0x20 == UInt32(expectedASCIILowercaseLetter)
    }

    /// Valid only for an ASCII hex digit.
    @inline(always)
    var asciiHexValue: UInt8 {
        let value = UInt32(truncatingIfNeeded: self)
        return UInt8(truncatingIfNeeded: value < 0x41 ? value &- 0x30 : (value &- 0x41 &+ 10) & 0xF)
    }

    @inline(always)
    var singleEscapeValue: UInt8 {
        if self < 128 {
            return singleCharacterEscapeValuesForASCII[Int(self)]
        }
        return 0
    }
}

extension LexerCharacter {
    @inline(always)
    static func isCRLFPair(_ first: Self, _ second: Self) -> Bool {
        first == 0x0D && second == 0x0A
    }
}

extension UInt32 {
    /// ICU's U16_GET_SUPPLEMENTARY.
    @inline(always)
    static func supplementaryCodePoint(lead: UInt32, trail: UInt32) -> UInt32 {
        (lead << 10) &+ trail &- ((0xD800 << 10) + 0xDC00 - 0x10000)
    }
}

extension LexerCodePoint {
    @inline(always)
    static func convertHex(_ c1: Self, _ c2: Self) -> UInt8 {
        c1.asciiHexValue << 4 | c2.asciiHexValue
    }

    @inline(always)
    static func convertUnicode(_ c1: Self, _ c2: Self, _ c3: Self, _ c4: Self) -> UInt32 {
        UInt32(convertHex(c1, c2)) << 8 | UInt32(convertHex(c3, c4))
    }
}
