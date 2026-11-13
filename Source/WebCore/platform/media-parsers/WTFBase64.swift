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

#if ENABLE_WEBCORE_SWIFT

// Swift builds the safe Span overloads of the views' span() with the Cxx module, which Xcode builds only find if this file
// imports it.
private import Cxx
import WebCore_Private.Core.MediaParsersCxxBridging
import wtf

// WTF's base64 and base64url (wtf/text/Base64.cpp), with the same results for every input and option.
enum WTFBase64 {
    // Bits of OptionSet<WTF::Base64DecodeOption>.
    struct DecodeOptions: OptionSet {
        let rawValue: UInt32

        static let url = DecodeOptions(.URL)
        static let validatePadding = DecodeOptions(.ValidatePadding)
        static let ignoreWhitespace = DecodeOptions(.IgnoreWhitespace)

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        private init(_ option: WTF.Base64DecodeOption) {
            rawValue = UInt32(bitPattern: option.rawValue)
        }
    }

    // Bits of OptionSet<WTF::Base64EncodeOption>.
    struct EncodeOptions: OptionSet {
        let rawValue: UInt32

        static let url = EncodeOptions(.URL)
        static let omitPadding = EncodeOptions(.OmitPadding)

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        private init(_ option: WTF.Base64EncodeOption) {
            rawValue = UInt32(bitPattern: option.rawValue)
        }
    }

    // WTF::maximumBase64EncoderInputBufferSize. Longer inputs encode to nothing.
    static let maximumEncoderInputSize: UInt32 = UInt32.max / 77 * 76 / 4 * 3 - 2

    // The results are ContiguousArrays because Array.span needs macOS 26.
    static func decode(_ input: Span<UInt8>, options: DecodeOptions = []) -> ContiguousArray<UInt8>? {
        decodeCodeUnits(input, options)
    }

    static func decode(_ input: Span<UInt16>, options: DecodeOptions = []) -> ContiguousArray<UInt8>? {
        decodeCodeUnits(input, options)
    }

    static func urlDecode(_ input: Span<UInt8>) -> ContiguousArray<UInt8>? {
        decodeCodeUnits(input, .url)
    }

    static func urlDecode(_ input: Span<UInt16>) -> ContiguousArray<UInt8>? {
        decodeCodeUnits(input, .url)
    }

    // Returns ASCII.
    static func encode(_ input: Span<UInt8>, options: EncodeOptions = []) -> ContiguousArray<UInt8> {
        guard UInt(input.count) <= UInt(maximumEncoderInputSize) else {
            return []
        }

        let url = options.contains(.url)
        let padding = !options.contains(.omitPadding)
        var output: ContiguousArray<UInt8> = []
        let (capacity, capacityOverflow) = (input.count / 3 + 1).multipliedReportingOverflow(by: 4)
        if !capacityOverflow {
            output.reserveCapacity(capacity)
        }

        var index = 0
        while input.count - index >= 3 {
            let group = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2])
            output.append(character(group >> 18, url: url))
            output.append(character(group >> 12, url: url))
            output.append(character(group >> 6, url: url))
            output.append(character(group, url: url))
            index += 3
        }

        switch input.count - index {
        case 1:
            let group = UInt32(input[index]) << 16
            output.append(character(group >> 18, url: url))
            output.append(character(group >> 12, url: url))
            if padding {
                output.append(equalsSign)
                output.append(equalsSign)
            }
        case 2:
            let group = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8
            output.append(character(group >> 18, url: url))
            output.append(character(group >> 12, url: url))
            output.append(character(group >> 6, url: url))
            if padding {
                output.append(equalsSign)
            }
        default:
            break
        }
        return output
    }

    static func urlEncode(_ input: Span<UInt8>) -> ContiguousArray<UInt8> {
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

        let url = options.contains(.url)
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
            guard let value = sextet(codeUnit, url: url) else {
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

    private static func sextet(_ codeUnit: UInt32, url: Bool) -> UInt32? {
        switch codeUnit {
        case 0x41...0x5A:
            codeUnit - 0x41
        case 0x61...0x7A:
            codeUnit - 0x61 + 26
        case 0x30...0x39:
            codeUnit - 0x30 + 52
        case 0x2B:
            url ? nil : 62
        case 0x2F:
            url ? nil : 63
        case 0x2D:
            url ? 62 : nil
        case 0x5F:
            url ? 63 : nil
        default:
            nil
        }
    }

    private static func character(_ group: UInt32, url: Bool) -> UInt8 {
        let value = UInt8(truncatingIfNeeded: group & 0x3F)
        return switch value {
        case 0..<26:
            value + 0x41
        case 26..<52:
            value - 26 + 0x61
        case 52..<62:
            value - 52 + 0x30
        case 62:
            url ? 0x2D : 0x2B
        default:
            url ? 0x5F : 0x2F
        }
    }

    // WTF::isASCIIWhitespace: no '\v'.
    private static func isASCIIWhitespace(_ codeUnit: UInt32) -> Bool {
        codeUnit == 0x20 || codeUnit == 0x0A || codeUnit == 0x09 || codeUnit == 0x0D || codeUnit == 0x0C
    }
}

// Appends the decoded bytes to output, and leaves it unchanged if the input isn't valid. options are
// OptionSet<WTF::Base64DecodeOption>::toRaw().
@_expose(Cxx)
func base64DecodeLatin1Impl(
    _ input: borrowing WebCore.MediaParserLatin1,
    _ options: UInt32,
    _ output: inout WebCore.MediaParserByteVector
) -> Bool {
    let characters: Span<UInt8> = input.span()
    return appendDecoded(WTFBase64.decode(characters, options: WTFBase64.DecodeOptions(rawValue: options)), to: &output)
}

@_expose(Cxx)
func base64DecodeUTF16Impl(
    _ input: borrowing WebCore.MediaParserUTF16,
    _ options: UInt32,
    _ output: inout WebCore.MediaParserByteVector
) -> Bool {
    let characters: Span<UInt16> = input.span()
    return appendDecoded(WTFBase64.decode(characters, options: WTFBase64.DecodeOptions(rawValue: options)), to: &output)
}

// options are OptionSet<WTF::Base64EncodeOption>::toRaw(). Never returns a null String.
@_expose(Cxx)
func base64EncodeToStringImpl(_ input: borrowing WebCore.MediaParserBytes, _ options: UInt32) -> WTF.String {
    let bytes: Span<UInt8> = input.span()
    let encoded = WTFBase64.encode(bytes, options: WTFBase64.EncodeOptions(rawValue: options))
    return WebCore.makeStringFromLatin1(encoded.span)
}

private func appendDecoded(_ decoded: ContiguousArray<UInt8>?, to output: inout WebCore.MediaParserByteVector) -> Bool {
    guard let decoded else {
        return false
    }
    if !decoded.isEmpty {
        WebCore.appendBytes(&output, decoded.span)
    }
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
