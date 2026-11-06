// Copyright (C) 2000-2001 Dawit Alemayehu <adawit@kde.org>
// Copyright (C) 2006 Alexey Proskuryakov <ap@webkit.org>
// Copyright (C) 2007-2024 Apple Inc. All rights reserved.
// Copyright (C) 2010 Patrick Gansterer <paroga@paroga.com>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License (LGPL)
// version 2 as published by the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU Library General Public
// License along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//
// This code is based on the java implementation in HTTPClient
// package by Ronald Tschalär Copyright (C) 1996-1999.

// Copyright (C) 2006 Alexey Proskuryakov <ap@webkit.org>
// Copyright (C) 2010 Patrick Gansterer <paroga@paroga.com>
// Copyright (C) 2013-2024 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Copyright (C) 2007-2026 Apple Inc. All rights reserved.
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

#if ENABLE_ENCRYPTED_MEDIA

public import WebCoreSwiftSupport

/// WTF's base64 and base64url (wtf/text/Base64.cpp), with the same results for every input and option.
public enum WTFBase64 {
    /// OptionSet<WTF::Base64DecodeOption>.
    public struct DecodeOptions: OptionSet, Sendable {
        /// The option bits.
        public let rawValue: UInt32

        /// Base64DecodeOption::URL.
        public static let url = DecodeOptions(rawValue: 1 << 0)
        /// Base64DecodeOption::ValidatePadding.
        public static let validatePadding = DecodeOptions(rawValue: 1 << 1)
        /// Base64DecodeOption::IgnoreWhitespace.
        public static let ignoreWhitespace = DecodeOptions(rawValue: 1 << 2)

        /// Options from their bits.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
    }

    /// OptionSet<WTF::Base64EncodeOption>.
    public struct EncodeOptions: OptionSet, Sendable {
        /// The option bits.
        public let rawValue: UInt32

        /// Base64EncodeOption::URL.
        public static let url = EncodeOptions(rawValue: 1 << 0)
        /// Base64EncodeOption::OmitPadding.
        public static let omitPadding = EncodeOptions(rawValue: 1 << 1)

        /// Options from their bits.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
    }

    /// WTF::maximumBase64EncoderInputBufferSize, beyond which inputs encode to nothing.
    public static let maximumEncoderInputSize: UInt32 = UInt32.max / 77 * 76 / 4 * 3 - 2

    /// WTF::base64Decode() of UTF-16 code units, into a ContiguousArray because Array.span needs macOS 26.
    public static func decode(_ input: Span<UInt16>, options: DecodeOptions = []) -> ContiguousArray<UInt8>? {
        decodeCodeUnits(input, options)
    }

    /// WTF::base64URLDecode() of UTF-16 code units.
    public static func urlDecode(_ input: Span<UInt16>) -> ContiguousArray<UInt8>? {
        decodeCodeUnits(input, .url)
    }

    /// WTF::base64Decode() of UTF-16 code units, inline or not.
    public static func decode(_ input: InlineCodeUnits, options: DecodeOptions = []) -> ContiguousArray<UInt8>? {
        input.withSpan { decodeCodeUnits($0, options) }
    }

    /// WTF::base64URLDecode() of UTF-16 code units, inline or not.
    public static func urlDecode(_ input: InlineCodeUnits) -> ContiguousArray<UInt8>? {
        input.withSpan { decodeCodeUnits($0, .url) }
    }

    /// WTF::base64Encode(), in ASCII.
    public static func encode(_ input: Span<UInt8>, options: EncodeOptions = []) -> ContiguousArray<UInt8> {
        var output: ContiguousArray<UInt8> = []
        encode(input, options: options, appendingTo: &output)
        return output
    }

    /// WTF::base64Encode(), in ASCII, appended to output.
    public static func encode(_ input: Span<UInt8>, options: EncodeOptions = [], appendingTo output: inout ContiguousArray<UInt8>) {
        guard UInt(input.count) <= UInt(maximumEncoderInputSize) else {
            return
        }

        let url = options.contains(.url)
        let padding = !options.contains(.omitPadding)
        let (capacity, capacityOverflow) = (input.count / 3 + 1).multipliedReportingOverflow(by: 4)
        // Grows as appending would, so that appending to a message several times stays linear.
        if !capacityOverflow && output.capacity - output.count < capacity {
            output.reserveCapacity(Swift.max(output.count + capacity, 2 * output.capacity))
        }
        let alphabet = url ? urlAlphabet : standardAlphabet

        let groupCount = input.count / 3
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            // Whole groups are written in place, which is cheaper than appending each character.
            var position = output.count
            output.append(contentsOf: repeatElement(0, count: groupCount * 4))
            var characters = output.mutableSpan
            let table = alphabet.span
            for index in stride(from: 0, to: groupCount * 3, by: 3) {
                let group = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2])
                characters[position] = table[Int(group >> 18 & 0x3F)]
                characters[position + 1] = table[Int(group >> 12 & 0x3F)]
                characters[position + 2] = table[Int(group >> 6 & 0x3F)]
                characters[position + 3] = table[Int(group & 0x3F)]
                position += 4
            }
        } else {
            for index in stride(from: 0, to: groupCount * 3, by: 3) {
                let group = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2])
                output.append(alphabet[Int(group >> 18 & 0x3F)])
                output.append(alphabet[Int(group >> 12 & 0x3F)])
                output.append(alphabet[Int(group >> 6 & 0x3F)])
                output.append(alphabet[Int(group & 0x3F)])
            }
        }
        let index = groupCount * 3

        switch input.count - index {
        case 1:
            let group = UInt32(input[index]) << 16
            output.append(alphabet[Int(group >> 18 & 0x3F)])
            output.append(alphabet[Int(group >> 12 & 0x3F)])
            if padding {
                output.append(equalsSign)
                output.append(equalsSign)
            }
        case 2:
            let group = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8
            output.append(alphabet[Int(group >> 18 & 0x3F)])
            output.append(alphabet[Int(group >> 12 & 0x3F)])
            output.append(alphabet[Int(group >> 6 & 0x3F)])
            if padding {
                output.append(equalsSign)
            }
        default:
            break
        }
    }

    /// WTF::base64URLEncode(), which omits the padding.
    public static func urlEncode(_ input: Span<UInt8>) -> ContiguousArray<UInt8> {
        encode(input, options: [.url, .omitPadding])
    }

    private static let equalsSign: UInt8 = 0x3D

    // Base64.cpp's base64DecodeInternal: '=' may only be followed by more '=' (or ignored whitespace), at most two of them
    // with ValidatePadding; trailing bits that don't make a whole byte are dropped, whatever their value.
    private static func decodeCodeUnits<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<CodeUnit>,
        _ options: DecodeOptions
    ) -> ContiguousArray<UInt8>? {
        if input.isEmpty {
            return []
        }
        guard UInt(input.count) <= UInt(UInt32.max) else {
            return nil
        }

        let sextets = options.contains(.url) ? urlSextets : standardSextets
        let validatePadding = options.contains(.validatePadding)
        let ignoreWhitespace = options.contains(.ignoreWhitespace)

        var output: ContiguousArray<UInt8> = []
        output.reserveCapacity(input.count / 4 * 3 + 2)
        var equalsSignCount = 0
        var sextetCount = 0
        var group: UInt32 = 0
        for index in input.indices {
            let codeUnit = UInt32(input[index])
            if codeUnit == UInt32(equalsSign) {
                equalsSignCount += 1
                if validatePadding && equalsSignCount > 2 {
                    return nil
                }
                continue
            }
            let value = codeUnit < 0x80 ? UInt32(sextets[Int(codeUnit)]) : invalidSextet
            guard value != invalidSextet else {
                if !ignoreWhitespace || !isASCIIWhitespace(codeUnit) {
                    return nil
                }
                continue
            }
            if equalsSignCount > 0 {
                return nil
            }
            group = group << 6 | value
            sextetCount += 1
            if sextetCount % 4 == 0 {
                output.append(UInt8(truncatingIfNeeded: group >> 16))
                output.append(UInt8(truncatingIfNeeded: group >> 8))
                output.append(UInt8(truncatingIfNeeded: group))
                group = 0
            }
        }

        if sextetCount == 0 {
            return equalsSignCount > 0 ? nil : []
        }
        if validatePadding && equalsSignCount > 0 && (sextetCount + equalsSignCount) % 4 != 0 {
            return nil
        }
        switch sextetCount % 4 {
        case 1:
            return nil
        case 2:
            output.append(UInt8(truncatingIfNeeded: group >> 4))
        case 3:
            output.append(UInt8(truncatingIfNeeded: group >> 10))
            output.append(UInt8(truncatingIfNeeded: group >> 2))
        default:
            break
        }
        return output
    }

    private static let standardAlphabet = ContiguousArray("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let urlAlphabet = ContiguousArray("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    // Each ASCII character's sextet in an alphabet, or invalidSextet.
    private static let invalidSextet: UInt32 = 0xFF
    private static let standardSextets = sextets(of: standardAlphabet)
    private static let urlSextets = sextets(of: urlAlphabet)

    private static func sextets(of alphabet: ContiguousArray<UInt8>) -> ContiguousArray<UInt8> {
        var sextets = ContiguousArray<UInt8>(repeating: UInt8(invalidSextet), count: 0x80)
        for (sextet, character) in alphabet.enumerated() {
            sextets[Int(character)] = UInt8(sextet)
        }
        return sextets
    }

    // WTF::isASCIIWhitespace: no '\v'.
    private static func isASCIIWhitespace(_ codeUnit: UInt32) -> Bool {
        codeUnit == 0x20 || codeUnit == 0x0A || codeUnit == 0x09 || codeUnit == 0x0D || codeUnit == 0x0C
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA
