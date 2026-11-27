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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST

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
internal import wtf
internal import WebCore_Private.Core.WebAuthnSwiftTypes

// Copies between Swift arrays and strings and the C++ `Vector<uint8_t>` and `String`.

extension CBORWriter {
    /// The bytes written, as the `Vector<uint8_t>` C++ takes.
    public consuming func takeVector() -> cbor.Bytes {
        makeByteVector(takeBytes())
    }

    /// A text string of `string.utf8()` (`LenientConversion`), each unpaired surrogate as U+FFFD.
    mutating func writeTextString(_ string: borrowing WTF.String) {
        let length = Int(string.length())
        if length != 0, string.is8Bit() {
            // ASCII Latin-1 characters are their own UTF-8.
            let characters: Span<UInt8> = WTF.bytesOfLatin1Characters(string.span8())
            if isASCII(characters) {
                writeTextString(utf8: characters)
                return
            }
        }
        writeTextString(utf8: utf8Bytes(of: string).span)
    }
}

/// Whether every byte of `bytes` is below 0x80.
private func isASCII(_ bytes: Span<UInt8>) -> Bool {
    var combined: UInt8 = 0
    for index in bytes.indices {
        combined |= bytes[index]
    }
    return combined < 0x80
}

/// The bytes of `span` as an array.
public func makeByteArray(_ span: Span<UInt8>) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: span.count)
    var destination = bytes.mutableSpan
    for index in span.indices {
        destination[index] = span[index]
    }
    return bytes
}

/// The bytes of `vector` as an array.
public func makeByteArray(_ vector: borrowing cbor.Bytes) -> [UInt8] {
    makeByteArray(vector.span())
}

/// A `Vector<uint8_t>` of `bytes`.
public func makeByteVector(_ bytes: [UInt8]) -> cbor.Bytes {
    makeByteVector(bytes.span)
}

/// A `Vector<uint8_t>` of `bytes`.
public func makeByteVector(_ bytes: Span<UInt8>) -> cbor.Bytes {
    var sink = fido.WebAuthnByteSink()
    sink.reserve(bytes.count)
    sink.append(bytes)
    return sink.take()
}

extension fido.WebAuthnByteSink {
    /// Appends `bytes` in one copy.
    ///
    /// An empty span is not passed on: it traps at a std::span parameter.
    @inline(always)
    mutating func append(_ bytes: Span<UInt8>) {
        if bytes.isEmpty {
            return
        }
        add(bytes)
    }
}

/// `string.utf8()` (`LenientConversion`): its characters as UTF-8, each unpaired surrogate as U+FFFD.
func utf8Bytes(of string: borrowing WTF.String) -> [UInt8] {
    var bytes: [UInt8] = []
    let length = Int(string.length())
    if length == 0 {
        return bytes
    }
    bytes.reserveCapacity(length)
    emitUTF8(of: string) { bytes.append($0) }
    return bytes
}

/// Calls `emit` with each byte of `string.utf8()` (`LenientConversion`), each unpaired surrogate as U+FFFD.
@inline(always)
func emitUTF8(of string: borrowing WTF.String, _ emit: (UInt8) -> Void) {
    let length = Int(string.length())
    if length == 0 {
        return
    }
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        for index in characters.indices {
            let character = characters[index].value
            if character < 0x80 {
                emit(character)
            } else {
                emit(0xC0 | character >> 6)
                emit(0x80 | character & 0x3F)
            }
        }
        return
    }
    let units: Span<UInt16> = string.checkedSpan16()
    var index = 0
    while index < units.count {
        var scalar = UInt32(units[index])
        index += 1
        if scalar & 0xF800 == 0xD800 {
            if scalar < 0xDC00 && index < units.count && units[index] & 0xFC00 == 0xDC00 {
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (UInt32(units[index]) - 0xDC00)
                index += 1
            } else {
                scalar = 0xFFFD
            }
        }
        emitUTF8(scalar: scalar, emit)
    }
}

/// Calls `emit` with each byte of the UTF-8 encoding of `scalar`, a Unicode scalar value.
@inline(always)
func emitUTF8(scalar: UInt32, _ emit: (UInt8) -> Void) {
    if scalar < 0x80 {
        emit(UInt8(scalar))
    } else if scalar < 0x800 {
        emit(UInt8(0xC0 | scalar >> 6))
        emit(UInt8(0x80 | scalar & 0x3F))
    } else if scalar < 0x10000 {
        emit(UInt8(0xE0 | scalar >> 12))
        emit(UInt8(0x80 | scalar >> 6 & 0x3F))
        emit(UInt8(0x80 | scalar & 0x3F))
    } else {
        emit(UInt8(0xF0 | scalar >> 18))
        emit(UInt8(0x80 | scalar >> 12 & 0x3F))
        emit(UInt8(0x80 | scalar >> 6 & 0x3F))
        emit(UInt8(0x80 | scalar & 0x3F))
    }
}

/// The UTF-16 code units of `string`, unpaired surrogates kept.
func utf16Units(of string: borrowing WTF.String) -> [UInt16] {
    var units: [UInt16] = []
    units.reserveCapacity(Int(string.length()))
    appendUTF16Units(of: string, to: &units)
    return units
}

/// Appends the UTF-16 code units of `string` to `units`, unpaired surrogates kept.
func appendUTF16Units(of string: borrowing WTF.String, to units: inout [UInt16]) {
    if string.length() == 0 {
        return
    }
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        for index in characters.indices {
            units.append(UInt16(characters[index].value))
        }
    } else {
        let characters: Span<UInt16> = string.checkedSpan16()
        for index in characters.indices {
            units.append(characters[index])
        }
    }
}

/// Whether `string` has exactly the code units of the ASCII `literal`, compared in place with no copy of either.
func webAuthnEqualsASCII(_ string: borrowing WTF.String, _ literal: Swift.String) -> Bool {
    let expected: Span<UInt8> = literal.utf8.span
    let length = Int(string.length())
    guard length == expected.count else {
        return false
    }
    if length == 0 {
        return true
    }
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        for index in expected.indices where characters[index].value != expected[index] {
            return false
        }
    } else {
        let characters: Span<UInt16> = string.checkedSpan16()
        for index in expected.indices where characters[index] != UInt16(expected[index]) {
            return false
        }
    }
    return true
}

/// `equalLettersIgnoringASCIICase`: whether each code unit of `string`, with the 0x20 bit set, is the lowercase letter,
/// digit or punctuation at its place in `lowercaseLetters`, compared in place.
func webAuthnEqualsLettersIgnoringASCIICase(_ string: borrowing WTF.String, _ lowercaseLetters: Swift.String) -> Bool {
    webAuthnEndMatches(string, lowercaseLetters, wholeString: true) { ($0 | 0x20) == $1 }
}

/// Whether the last code units of `string` are the ASCII `suffix`, with A-Z and a-z alike, compared in place.
func webAuthnEndsWithIgnoringASCIICase(_ string: borrowing WTF.String, _ suffix: Swift.String) -> Bool {
    webAuthnEndMatches(string, suffix, wholeString: false) { $0.webAuthnASCIILowercased == $1.webAuthnASCIILowercased }
}

/// Whether the last code units of `string`, all of them when `wholeString`, match the ASCII `literal` by `matches`.
private func webAuthnEndMatches(
    _ string: borrowing WTF.String,
    _ literal: Swift.String,
    wholeString: Bool,
    _ matches: (UInt16, UInt16) -> Bool
) -> Bool {
    let expected: Span<UInt8> = literal.utf8.span
    let length = Int(string.length())
    guard wholeString ? length == expected.count : length >= expected.count else {
        return false
    }
    if expected.isEmpty {
        return true
    }
    let start = length - expected.count
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        for index in expected.indices where !matches(UInt16(characters[start + index].value), UInt16(expected[index])) {
            return false
        }
    } else {
        let characters: Span<UInt16> = string.checkedSpan16()
        for index in expected.indices where !matches(characters[start + index], UInt16(expected[index])) {
            return false
        }
    }
    return true
}

extension UInt16 {
    /// The code unit with A-Z lowercased.
    fileprivate var webAuthnASCIILowercased: UInt16 {
        (0x41...0x5A).contains(self) ? self | 0x20 : self
    }
}

/// `string` as a Swift string, each unpaired surrogate as U+FFFD: the characters the writer encodes for it.
public func makeSwiftString(_ string: borrowing WTF.String) -> Swift.String {
    let length = Int(string.length())
    if length != 0 {
        if string.is8Bit() {
            // ASCII Latin-1 bytes are their own UTF-8: the string is copied from them, with no temporary array.
            let bytes: Span<UInt8> = WTF.bytesOfLatin1Characters(string.span8())
            if isASCII(bytes), let characters = try? UTF8Span(validating: bytes) {
                return Swift.String(copying: characters)
            }
        }
    }
    return Swift.String(decoding: utf8Bytes(of: string), as: Unicode.UTF8.self)
}

/// `string` as a WTF string (`emptyString()` when empty, as `String::fromUTF8` gives).
public func makeWTFString(_ string: Swift.String) -> WTF.String {
    let utf8 = string.utf8
    if utf8.isEmpty {
        return fido.emptyWTFString()
    }
    let bytes: Span<UInt8> = utf8.span
    var isASCII = true
    for index in bytes.indices where bytes[index] >= 0x80 {
        isASCII = false
        break
    }
    if isASCII {
        return WTF.String(WTF.latin1CharactersOfBytes(bytes))
    }
    let units = Array(string.utf16)
    return WTF.String(units.span)
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
