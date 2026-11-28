//
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

// A hash table of the memory store's values by key.

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

/// A record's key in a key table, with its hash.
///
/// Held inline: MemoryIDBKey is bitwise-takable, so a table of these moves by memcpy and a number key has no reference
/// count. The values are a parallel array.
struct MemoryIDBKeyEntry {
    /// The key's hash (IDBKeyData's computeHash), mixed for the table's power-of-two buckets.
    let hash: UInt64
    /// The key, which the tables compare and hash without a C++ call; makeIDBKeyData() gives it back as an IDBKeyData.
    let key: MemoryIDBKey
}

/// A hash table of values by key, with IDBKeyData's hash and operator== (a NaN key is found nowhere); with `Value`
/// `Void`, a set of keys.
///
/// Keys are held densely in `entries`, values at the same positions in `values`; `buckets` is
/// open addressing with linear probing, at most half full, removal by backward shift. A bucket is an integer: the high
/// half of the key's hash, and the entry's index plus one (0 is empty). Removing an entry moves the last one into its
/// place.
struct MemoryIDBKeyTable<Value> {
    private(set) var entries: ContiguousArray<MemoryIDBKeyEntry> = []
    private(set) var values: ContiguousArray<Value> = []
    private var buckets: [UInt64] = []

    var count: Int {
        entries.count
    }

    private static func home(_ hash: UInt64, _ mask: Int) -> Int {
        Int(truncatingIfNeeded: hash >> 32) & mask
    }

    private static func bucket(_ hash: UInt64, _ index: Int) -> UInt64 {
        (hash & 0xFFFF_FFFF_0000_0000) | UInt64(truncatingIfNeeded: index + 1)
    }

    private static func entryIndex(_ bucket: UInt64) -> Int {
        Int(truncatingIfNeeded: bucket & 0xFFFF_FFFF) - 1
    }

    /// The bucket holding the entry for `key`, with `hash` the key's hash.
    private func slot(_ hash: UInt64, _ key: MemoryIDBKey) -> Int? {
        if entries.isEmpty {
            return nil
        }
        let high = hash & 0xFFFF_FFFF_0000_0000
        let mask = buckets.count - 1
        var i = Self.home(hash, mask)
        while true {
            let bucket = buckets[i]
            if bucket == 0 {
                return nil
            }
            if bucket & 0xFFFF_FFFF_0000_0000 == high {
                let entry = entries[Self.entryIndex(bucket)]
                // operator==, through the native keys: a NaN equals nothing and does not trap.
                if entry.hash == hash && entry.key == key {
                    return i
                }
            }
            i = (i + 1) & mask
        }
    }

    func contains(_ key: MemoryIDBKey, _ hash: UInt64) -> Bool {
        slot(hash, key) != nil
    }

    /// The position of the entry for `key` in `entries` and `values`.
    func find(_ key: borrowing WebCore.IDBKeyData) -> Int? {
        let nativeKey = MemoryIDBKey(key)
        return find(nativeKey, nativeKey.hash)
    }

    /// The position of the entry for `key` in `entries` and `values`, with `hash` the key's hash.
    func find(_ key: MemoryIDBKey, _ hash: UInt64) -> Int? {
        guard let i = slot(hash, key) else {
            return nil
        }
        return Self.entryIndex(buckets[i])
    }

    mutating func reserve(_ capacity: Int) {
        var size = buckets.isEmpty ? 16 : buckets.count
        while size < capacity * 2 {
            size *= 2
        }
        if size > buckets.count {
            rehash(size)
        }
        entries.reserveCapacity(capacity)
        values.reserveCapacity(capacity)
    }

    private mutating func rehash(_ size: Int) {
        let old = buckets
        buckets = Array(repeating: 0, count: size)
        let mask = size - 1
        for bucket in old where bucket != 0 {
            var i = Self.home(bucket, mask)
            while buckets[i] != 0 {
                i = (i + 1) & mask
            }
            buckets[i] = bucket
        }
    }

    /// Adds an entry whose key is absent, with `hash` the key's hash.
    mutating func insert(_ key: MemoryIDBKey, _ hash: UInt64, _ value: consuming Value) {
        if (entries.count + 1) * 2 > buckets.count {
            rehash(buckets.isEmpty ? 16 : buckets.count * 2)
        }
        let mask = buckets.count - 1
        var i = Self.home(hash, mask)
        while buckets[i] != 0 {
            i = (i + 1) & mask
        }
        buckets[i] = Self.bucket(hash, entries.count)
        entries.append(MemoryIDBKeyEntry(hash: hash, key: key))
        values.append(value)
    }

    /// Removes the entry for `key`; returns its stored key and its value.
    @discardableResult
    mutating func remove(_ key: MemoryIDBKey, _ hash: UInt64) -> (key: MemoryIDBKey, value: Value)? {
        guard var hole = slot(hash, key) else {
            return nil
        }
        let removedIndex = Self.entryIndex(buckets[hole])
        let mask = buckets.count - 1
        var j = hole
        while true {
            j = (j + 1) & mask
            let bucket = buckets[j]
            if bucket == 0 {
                break
            }
            // The entry may fill the hole unless its home lies cyclically after the hole, up to j.
            if (j - Self.home(bucket, mask)) & mask >= (j - hole) & mask {
                buckets[hole] = bucket
                hole = j
            }
        }
        buckets[hole] = 0
        // The last entry takes the removed one's place; its bucket is found by its hash and index.
        let lastIndex = entries.count - 1
        if removedIndex != lastIndex {
            let lastHash = entries[lastIndex].hash
            let lastBucket = Self.bucket(lastHash, lastIndex)
            var i = Self.home(lastHash, mask)
            while buckets[i] != lastBucket {
                i = (i + 1) & mask
            }
            buckets[i] = Self.bucket(lastHash, removedIndex)
            entries.swapAt(removedIndex, lastIndex)
            values.swapAt(removedIndex, lastIndex)
        }
        let removedKey = entries.removeLast().key
        return (key: removedKey, value: values.removeLast())
    }
}
