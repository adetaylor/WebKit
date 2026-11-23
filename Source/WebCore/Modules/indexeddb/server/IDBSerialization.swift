//
// Copyright (C) 2014, 2016 Apple Inc. All rights reserved.
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

// The IDBKeyData serialization format, written and read here. The key path codec and the legacy (KeyedEncoder) key
// format stay in IDBSerialization.cpp, which forwards the rest to these entries.
//
// The IDBKeyData serialization format is as follows:
// [1 byte version header][Key Buffer]
//
// The Key Buffer serialization format is as follows:
// [1 byte key type][Type specific data]
//
// Type specific serialization formats are as follows for each of the types:
// Min:
// [0 bytes]
//
// Number:
// [8 bytes representing a double encoded in little endian]
//
// Date:
// [8 bytes representing a double encoded in little endian]
//
// String:
// [4 bytes representing string "length" in little endian]["length" number of 2-byte pairs representing ECMAScript 16-bit code units]
//
// Binary:
// [8 bytes representing the "size" of the binary blob]["size" bytes]
//
// Array:
// [8 bytes representing the "length" of the key array]["length" individual Key Buffer entries]
//
// Max:
// [0 bytes]

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes
internal import WebCore_Private.Core.ThreadSafeDataBuffer
internal import wtf.Assertions
internal import wtf.Core.text.WTFString

private let serializedIDBKeyVersion: UInt8 = 0x00

private enum SerializedIDBKeyType: UInt8 {
    case min = 0x00
    case number = 0x20
    case date = 0x40
    case string = 0x60
    case binary = 0x80
    case array = 0xA0
    case max = 0xFF
}

private func serializedIDBKeyType(_ type: WebCore.IndexedDB.KeyType) -> SerializedIDBKeyType {
    switch type {
    case .Min: .min
    case .Number: .number
    case .Date: .date
    case .String: .string
    case .Binary: .binary
    case .Array: .array
    case .Max: .max
    // Traps for Invalid and any other type.
    default: WTFCrash()
    }
}

// Bytes encoded but not yet copied into the vector, in a fixed buffer on the stack: copied in chunks, without a call
// into C++ per byte and without a heap buffer per key.
private struct SerializedIDBKeyWriter {
    static let chunkSize = 128
    var vector = WebCore.IDBSerializedKeyBytes()
    var pending: [128 of UInt8] = .init(repeating: 0) // chunkSize bytes
    var pendingCount = 0

    @inline(never)
    mutating func flush() {
        if pendingCount != 0 {
            WebCore.appendIDBSerializedKeyBytes(&vector, pending.span.extracting(0..<pendingCount))
            pendingCount = 0
        }
    }

    mutating func append(_ byte: UInt8) {
        if pendingCount == SerializedIDBKeyWriter.chunkSize {
            flush()
        }
        pending[pendingCount] = byte
        pendingCount &+= 1
    }

    // Little endian, which is every supported platform's byte order.
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value
        for _ in 0..<4 {
            append(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        var value = value
        for _ in 0..<8 {
            append(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
    }

    mutating func appendDouble(_ value: Double) {
        appendLittleEndian(value.bitPattern)
    }
}

// Recursive for arrays only: every other type is encoded out of line, so a level of nesting costs the stack only what
// the array case needs.
private func encodeKey(_ key: borrowing WebCore.IDBKeyData, into writer: inout SerializedIDBKeyWriter) {
    let type = serializedIDBKeyType(key.type())
    guard type == .array else {
        encodeNonArrayKey(key, type, into: &writer)
        return
    }
    writer.append(type.rawValue)
    let elements: Span<WebCore.IDBKeyData> = WebCore.idbKeyArrayElements(key)
    writer.appendLittleEndian(UInt64(elements.count))
    for i in elements.indices {
        // Not `encodeKey(elements[i], ...)`, which copies the element (variant, vector, string) for the call.
        elements.withBorrowedElement(i) { element in
            encodeKey(element, into: &writer)
        }
    }
}

extension Span where Element: ~Copyable {
    /// Calls `body` with the element in place: passing `self[index]` of a copyable C++ type straight to a `borrowing`
    /// parameter copies it for the call.
    func withBorrowedElement(_ index: Int, _ body: (borrowing Element) -> Void) {
        body(self[index])
    }
}

@inline(never)
private func encodeNonArrayKey(_ key: borrowing WebCore.IDBKeyData, _ type: SerializedIDBKeyType, into writer: inout SerializedIDBKeyWriter)
{
    writer.append(type.rawValue)

    switch type {
    case .number:
        writer.appendDouble(key.number())
    case .date:
        writer.appendDouble(key.date())
    case .string:
        let string = key.string()
        let length = UInt32(string.length())
        writer.appendLittleEndian(length)
        // Each code unit as 16 bits, 8-bit strings included.
        if string.is8Bit() {
            let characters: Span<WTF.Latin1Character> = string.span8()
            for i in characters.indices {
                writer.appendLittleEndian(UInt16(characters[i].value))
            }
        } else {
            let characters: Span<UInt16> = string.checkedSpan16()
            for i in characters.indices {
                writer.appendLittleEndian(characters[i])
            }
        }
    case .binary:
        let size = UInt64(key.binaryValue().size())
        writer.appendLittleEndian(size)
        writer.flush()
        WebCore.appendIDBKeyBinaryBytes(&writer.vector, key)
    case .array:
        preconditionFailure("encodeKey encodes arrays")
    case .min, .max:
        break
    }
}

/// The serialized bytes of a key: the version, then the key.
///
/// `key` is the C++ caller's `const IDBKeyData&`, which it owns for the call. The encoder reads it only through
/// `const` accessors and calls no C++ that could reach it mutably; the only C++ it writes is the new `writer.vector`.
@_expose(Cxx)
func serializeIDBKeyDataBytes(_ key: borrowing WebCore.IDBKeyData) -> WebCore.IDBSerializedKeyBytes {
    var writer = SerializedIDBKeyWriter()
    writer.append(serializedIDBKeyVersion)
    encodeKey(key, into: &writer)
    writer.flush()
    return writer.vector
}

// nil, consuming nothing, when fewer bytes remain than the value has. The value may be at any offset (unaligned).
private func readLittleEndianUInt32(_ data: inout Span<UInt8>) -> UInt32? {
    guard data.count >= 4 else {
        return nil
    }
    var value: UInt32 = 0
    for i in 0..<4 {
        value |= UInt32(data[i]) << (8 * UInt32(i))
    }
    data = data.extracting(4...)
    return value
}

private func readLittleEndianUInt64(_ data: inout Span<UInt8>) -> UInt64? {
    guard data.count >= 8 else {
        return nil
    }
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[i]) << (8 * UInt64(i))
    }
    data = data.extracting(8...)
    return value
}

private func readDouble(_ data: inout Span<UInt8>) -> Double? {
    readLittleEndianUInt64(&data).map { Double(bitPattern: $0) }
}

// Recursive for arrays only, as encodeKey is.
private func decodeKey(_ data: inout Span<UInt8>, _ result: inout WebCore.IDBKeyData) -> Bool {
    if data.isEmpty {
        return false
    }

    let typeByte = data[0]
    data = data.extracting(1...)
    guard let type = SerializedIDBKeyType(rawValue: typeByte) else {
        return false
    }
    guard type == .array else {
        return decodeNonArrayKey(type, &data, &result)
    }
    guard let size64 = readLittleEndianUInt64(&data) else {
        return false
    }
    // The capacity is reserved before any element is read: a count too large to allocate crashes there. size_t imports
    // as Int, so the bits are passed unchanged.
    var array = WebCore.makeIDBKeyDataVector(Int(truncatingIfNeeded: size64))
    var i: UInt64 = 0
    while i < size64 {
        var keyData = WebCore.IDBKeyData()
        if !decodeKey(&data, &keyData) {
            return false
        }
        // Moved in, not copied.
        WebCore.appendIDBKeyData(&array, consume keyData)
        i += 1
    }
    result.setArrayValue(array)
    return true
}

@inline(never)
private func decodeNonArrayKey(_ type: SerializedIDBKeyType, _ data: inout Span<UInt8>, _ result: inout WebCore.IDBKeyData) -> Bool {
    switch type {
    case .min:
        result = WebCore.IDBKeyData.minimum()
        return true
    case .max:
        result = WebCore.IDBKeyData.maximum()
        return true
    case .number:
        guard let d = readDouble(&data) else {
            return false
        }
        result.setNumberValue(d)
        return true
    case .date:
        guard let d = readDouble(&data) else {
            return false
        }
        result.setDateValue(d)
        return true
    case .string:
        guard let length = readLittleEndianUInt32(&data) else {
            return false
        }
        // Widened, so 2 * length cannot overflow.
        let byteCount = 2 * Int(length)
        if data.count < byteCount {
            return false
        }
        if length == 0 {
            result.setStringValue(WebCore.makeEmptyIDBKeyString())
            return true
        }
        result.setStringValue(WebCore.makeIDBKeyStringFromLittleEndianBytes(data.extracting(..<byteCount)))
        data = data.extracting(byteCount...)
        return true
    case .binary:
        guard let size64 = readLittleEndianUInt64(&data) else {
            return false
        }
        if UInt64(data.count) < size64 {
            return false
        }
        // size64 <= data.count, so it fits in Int.
        let size = Int(size64)
        if size == 0 {
            WebCore.setEmptyIDBKeyBinaryValue(&result)
        } else {
            WebCore.setIDBKeyBinaryValue(&result, data.extracting(..<size))
        }
        data = data.extracting(size...)
        return true
    case .array:
        preconditionFailure("decodeKey decodes arrays")
    }
}

/// The key serialized in `data`, after the caller's legacy-format check: the version, then exactly one key and nothing
/// after it.
///
/// `data` is the caller's buffer (a SQLite column's blob or a `Vector`/`SharedBuffer` the caller owns), which stays
/// allocated, at its length, for the call. Nothing writes it during the call: this function calls C++ only to build
/// keys and strings, which never touch it. Its elements are bytes, which have no invalid bit patterns.
///
/// `result` is the caller's `IDBKeyData&`, which it owns for the call; only this function writes it. `data` must
/// not alias storage that `result` owns (the bytes of a Binary key it holds): decoding into `result` would free them
/// while they are read.
///
/// FIXME: Take the bytes as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func deserializeIDBKeyDataBody(_ data: WebCore.IDBSerializedKeySpan, _ result: inout WebCore.IDBKeyData) -> Bool {
    var bytes = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    // Verify this is a SerializedIDBKey version we understand.
    guard !bytes.isEmpty, bytes[0] == serializedIDBKeyVersion else {
        return false
    }
    bytes = bytes.extracting(1...)

    if decodeKey(&bytes, &result) {
        // Even if we successfully decoded a key, the deserialize is only successful if we actually consumed all input
        // data.
        return bytes.isEmpty
    }
    return false
}
