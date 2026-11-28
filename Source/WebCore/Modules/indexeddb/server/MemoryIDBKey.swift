//
// Copyright (C) 2015 Apple Inc. All rights reserved.
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

// A key as the memory store keeps it, with IDBKeyData's order, equality and hash.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes
internal import WebCore_Private.Core.ThreadSafeDataBuffer
internal import wtf.Assertions
internal import wtf.Core.text.WTFString

/// A key as the memory backing store keeps it: IDBKeyData's value with Swift payloads, so that a container moves it by
/// copying its bits and a number or date key has no reference count.
///
/// Converted from and to IDBKeyData where C++ calls the store. A placeholder key never reaches a backing store
/// (UniqueIDBDatabase replaces it with the record's key first), so the flag is not kept.
enum MemoryIDBKey {
    /// IDBKeyData() (std::nullptr_t).
    case null
    /// IDBKeyData::Invalid.
    case invalid
    case array(ContiguousArray<MemoryIDBKey>)
    /// nil: a ThreadSafeDataBuffer with no data, which is less than, and unequal to, an empty one.
    case binary(ContiguousArray<UInt8>?)
    /// UTF-16 code units, an 8-bit string's widened. nil: the null String, which is less than, and unequal to, the empty
    /// one.
    case string(ContiguousArray<UInt16>?)
    case date(Double)
    /// The bits as stored: -0 stays -0 (and compares equal to +0).
    case number(Double)
    case min
    case max

    init(_ key: borrowing WebCore.IDBKeyData) {
        switch key.type() {
        case .Number:
            self = .number(key.number())
        case .Date:
            self = .date(key.date())
        case .String:
            self = .string(memoryIDBKeyCodeUnits(key.string()))
        case .Binary:
            if !WebCore.threadSafeDataBufferHasData(key.binaryValue()) {
                self = .binary(nil)
                return
            }
            let bytes: Span<UInt8> = WebCore.idbKeyBinaryBytes(key)
            var copy = ContiguousArray<UInt8>()
            copy.reserveCapacity(bytes.count)
            for i in bytes.indices {
                copy.append(bytes[i])
            }
            self = .binary(copy)
        case .Array:
            let elements: Span<WebCore.IDBKeyData> = WebCore.idbKeyArrayElements(key)
            var array = ContiguousArray<MemoryIDBKey>()
            array.reserveCapacity(elements.count)
            for i in elements.indices {
                elements.withBorrowedElement(i) { element in
                    array.append(MemoryIDBKey(element))
                }
            }
            self = .array(array)
        case .Min:
            self = .min
        case .Max:
            self = .max
        default:
            self = key.isNull() ? .null : .invalid
        }
    }

    func makeIDBKeyData() -> WebCore.IDBKeyData {
        var result = WebCore.IDBKeyData()
        switch self {
        case .null:
            break
        case .invalid:
            result = WebCore.makeInvalidIDBKeyData()
        case .number(let value):
            result.setNumberValue(value)
        case .date(let value):
            result.setDateValue(value)
        case .string(let units):
            guard let units else {
                result.setStringValue(WTF.String())
                break
            }
            // Swift traps when it passes C++ an empty Span with a null base.
            if units.isEmpty {
                result.setStringValue(WebCore.makeEmptyIDBKeyString())
            } else {
                result.setStringValue(WTF.String(units.span))
            }
        case .binary(let bytes):
            guard let bytes else {
                result.setBinaryValue(WebCore.ThreadSafeDataBuffer())
                break
            }
            if bytes.isEmpty {
                WebCore.setEmptyIDBKeyBinaryValue(&result)
            } else {
                WebCore.setIDBKeyBinaryValue(&result, bytes.span)
            }
        case .array(let elements):
            var vector = WebCore.makeIDBKeyDataVector(elements.count)
            for element in elements {
                WebCore.appendIDBKeyData(&vector, element.makeIDBKeyData())
            }
            result.setArrayValue(vector)
        case .min:
            result = WebCore.IDBKeyData.minimum()
        case .max:
            result = WebCore.IDBKeyData.maximum()
        }
        return result
    }

    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    /// IDBKeyData::isValid(): not null and not Invalid.
    var isValid: Bool {
        switch self {
        case .null, .invalid:
            false
        default:
            true
        }
    }

    /// The position of the key's type in the order: IndexedDB::KeyType reversed, Invalid (and null) lowest.
    fileprivate var typeRank: Int {
        switch self {
        case .null, .invalid: 0
        case .min: 1
        case .number: 2
        case .date: 3
        case .string: 4
        case .binary: 5
        case .array: 6
        case .max: 7
        }
    }
}

func memoryIDBKeyCodeUnits(_ string: borrowing WTF.String) -> ContiguousArray<UInt16>? {
    if string.isNull() {
        return nil
    }
    var units = ContiguousArray<UInt16>()
    units.reserveCapacity(Int(string.length()))
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        for i in characters.indices {
            units.append(UInt16(characters[i].value))
        }
    } else {
        let characters: Span<UInt16> = string.checkedSpan16()
        for i in characters.indices {
            units.append(characters[i])
        }
    }
    return units
}

func memoryIDBCompareBytes<T: FixedWidthInteger & UnsignedInteger>(_ a: ContiguousArray<T>, _ b: ContiguousArray<T>) -> Int {
    let count = Swift.min(a.count, b.count)
    for i in 0..<count where a[i] != b[i] {
        return a[i] < b[i] ? -1 : 1
    }
    return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
}

/// IDBKeyData's operator<=> as -1, 0 or 1.
///
/// Two numbers or two dates that are unordered (a NaN) stop the process, as IDBKeyData's weakOrderingCast does.
func memoryIDBCompare(_ a: MemoryIDBKey, _ b: MemoryIDBKey) -> Int {
    // One key's case, then the other's: a `switch (a, b)` forms a tuple, copying both keys (a retain and a release of
    // each payload) on every comparison of the index scans.
    switch a {
    case .number(let x):
        if case .number(let y) = b {
            return memoryIDBCompareOrdered(x, y)
        }
    case .date(let x):
        if case .date(let y) = b {
            return memoryIDBCompareOrdered(x, y)
        }
    case .null:
        switch b {
        case .null:
            return 0
        case .invalid:
            return -1
        default:
            break
        }
    case .invalid:
        switch b {
        case .invalid:
            return 0
        case .null:
            return 1
        default:
            break
        }
    case .min:
        if case .min = b {
            return 0
        }
    case .max:
        if case .max = b {
            return 0
        }
    case .string(let x):
        if case .string(let y) = b {
            return memoryIDBCompareOptionalBytes(x, y)
        }
    case .binary(let x):
        if case .binary(let y) = b {
            return memoryIDBCompareOptionalBytes(x, y)
        }
    case .array(let x):
        if case .array(let y) = b {
            let count = Swift.min(x.count, y.count)
            for i in 0..<count {
                let result = memoryIDBCompare(x[i], y[i])
                if result != 0 {
                    return result
                }
            }
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        }
    }
    return a.typeRank < b.typeRank ? -1 : 1
}

/// Two numbers or two dates as -1, 0 or 1; unordered ones (a NaN) stop the process.
private func memoryIDBCompareOrdered(_ x: Double, _ y: Double) -> Int {
    if x < y {
        return -1
    }
    if x > y {
        return 1
    }
    // WTFCrash, not precondition: the process stops as a RELEASE_ASSERT does (the crash handler's SIGKILL),
    // where a Swift trap would end it with SIGTRAP.
    if x != y {
        WTFCrash()
    }
    return 0
}

/// Two strings' or buffers' units; the null one is less than, and unequal to, any other.
private func memoryIDBCompareOptionalBytes<T: FixedWidthInteger & UnsignedInteger>(
    _ x: ContiguousArray<T>?,
    _ y: ContiguousArray<T>?
) -> Int {
    guard let x else {
        return y == nil ? 0 : -1
    }
    guard let y else {
        return 1
    }
    return memoryIDBCompareBytes(x, y)
}

extension MemoryIDBKey: Equatable {
    /// IDBKeyData's operator==: the same case and value, numbers and dates by `==` (NaN is unequal to itself, -0 equals
    /// +0), null strings and buffers unequal to empty ones.
    static func == (a: MemoryIDBKey, b: MemoryIDBKey) -> Bool {
        // One key's case, then the other's, as memoryIDBCompare: no tuple copy of the two keys.
        switch a {
        case .number(let x):
            if case .number(let y) = b {
                return x == y
            }
        case .date(let x):
            if case .date(let y) = b {
                return x == y
            }
        case .null:
            if case .null = b {
                return true
            }
        case .invalid:
            if case .invalid = b {
                return true
            }
        case .min:
            if case .min = b {
                return true
            }
        case .max:
            if case .max = b {
                return true
            }
        case .string(let x):
            if case .string(let y) = b {
                return x == y
            }
        case .binary(let x):
            if case .binary(let y) = b {
                return x == y
            }
        case .array(let x):
            if case .array(let y) = b {
                return x == y
            }
        }
        return false
    }
}

/// The 64-bit finaliser of MurmurHash3: every input bit reaches every output bit, so a Double's bits (whose low bits
/// are zero for small integers) spread over a table's low bits.
func memoryIDBMixHash(_ value: UInt64) -> UInt64 {
    var h = value
    h ^= h >> 33
    h &*= 0xff51_afd7_ed55_8ccd
    h ^= h >> 33
    h &*= 0xc4ce_b9fe_1a85_ec53
    h ^= h >> 33
    return h
}

extension MemoryIDBKey {
    /// The 64-bit FNV prime, by which each string unit, byte and array element is mixed into the hash.
    private static let fnvPrime: UInt64 = 0x100_0000_01b3

    /// A hash consistent with ==, from a fixed seed (no output depends on it: the tables iterate in insertion order).
    /// -0 hashes as +0, as IDBKeyData's add(Hasher&) does.
    var hash: UInt64 {
        switch self {
        case .number(let value):
            return memoryIDBMixHash((value == 0 ? 0 : value.bitPattern) &+ 2)
        case .date(let value):
            return memoryIDBMixHash((value == 0 ? 0 : value.bitPattern) &+ 3)
        case .string(let units):
            guard let units else {
                return memoryIDBMixHash(0x40)
            }
            var h: UInt64 = 0x41 &+ UInt64(units.count)
            for unit in units {
                h = (h ^ UInt64(unit)) &* Self.fnvPrime
            }
            return memoryIDBMixHash(h)
        case .binary(let bytes):
            guard let bytes else {
                return memoryIDBMixHash(0x50)
            }
            var h: UInt64 = 0x51 &+ UInt64(bytes.count)
            for byte in bytes {
                h = (h ^ UInt64(byte)) &* Self.fnvPrime
            }
            return memoryIDBMixHash(h)
        case .array(let elements):
            var h: UInt64 = 0x61 &+ UInt64(elements.count)
            for element in elements {
                h = (h ^ element.hash) &* Self.fnvPrime
            }
            return memoryIDBMixHash(h)
        case .null:
            return memoryIDBMixHash(0x10)
        case .invalid:
            return memoryIDBMixHash(0x11)
        case .min:
            return memoryIDBMixHash(0x12)
        case .max:
            return memoryIDBMixHash(0x13)
        }
    }
}

/// IDBKeyData::operator== for two keys the memory store holds or is given, without a C++ call: a number or date by
/// the doubles' == (so -0 == +0 and a NaN equals nothing, with no trap), a null or invalid key by which of the two it
/// is, a string or binary by IDBKeyData::compare (which compares no double), an array through MemoryIDBKey's ==.
func memoryIDBKeyDataEqual(_ a: borrowing WebCore.IDBKeyData, _ b: borrowing WebCore.IDBKeyData) -> Bool {
    let type = a.type()
    if type != b.type() {
        return false
    }
    switch type {
    case .Number:
        return a.number() == b.number()
    case .Date:
        return a.date() == b.date()
    case .String, .Binary, .Min, .Max:
        return a.compare(b) == 0
    case .Array:
        return MemoryIDBKey(a) == MemoryIDBKey(b)
    default:
        return a.isNull() == b.isNull()
    }
}

/// MemoryIDBKey(key).hash, consistent with memoryIDBKeyDataEqual, converting no number or date key.
func memoryIDBKeyDataHash(_ key: borrowing WebCore.IDBKeyData) -> UInt64 {
    switch key.type() {
    case .Number:
        return MemoryIDBKey.number(key.number()).hash
    case .Date:
        return MemoryIDBKey.date(key.date()).hash
    default:
        return MemoryIDBKey(key).hash
    }
}
