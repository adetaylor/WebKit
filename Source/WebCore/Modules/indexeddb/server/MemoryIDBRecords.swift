//
// Copyright (C) 2015-2021 Apple Inc. All rights reserved.
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

// The memory store's record keys: a hash map of values by key, the keys in ascending order, and key ranges.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBGetAllResult
internal import WebCore_Private.Core.IDBGetResult
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IDBTransactionMode
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes
internal import WebCore_Private.Core.ThreadSafeDataBuffer

/// A map keyed by IDBKeyData (a transaction's modified records): membership by hash, and the entries in the order they
/// were added (nothing is removed but all at once), so iterating it does not depend on a hash. `add` keeps the first
/// value.
struct MemoryIDBKeyMap<Value> {
    private var table = MemoryIDBKeyTable<Value>()

    /// The keys, in the order they were added; `values` holds their values at the same positions.
    var entries: ContiguousArray<MemoryIDBKeyEntry> {
        table.entries
    }

    var values: ContiguousArray<Value> {
        table.values
    }

    func contains(_ key: MemoryIDBKey, _ hash: UInt64) -> Bool {
        table.find(key, hash) != nil
    }

    /// With `hash` the key's hash.
    mutating func add(_ key: MemoryIDBKey, _ hash: UInt64, _ value: consuming Value) {
        if contains(key, hash) {
            return
        }
        table.insert(key, hash, value)
    }

    mutating func reserve(_ additional: Int) {
        table.reserve(table.count + additional)
    }

    mutating func removeAll() {
        table = MemoryIDBKeyTable()
    }

    var isEmpty: Bool {
        table.count == 0
    }
}

/// The object store's record keys in ascending order, kept up to date until out-of-order writes with no ordered read
/// between them have moved about as many keys as one sort costs; the keys are then left in the record table alone,
/// and the next ordered read sorts them (order(_:)), so random-order writes cost no moves of the whole array each.
struct MemoryIDBOrderedRecords {
    /// Empty while `isOrdered` is false.
    private(set) var keys: ContiguousArray<MemoryIDBKey> = []
    private(set) var isOrdered = true
    private var moves = MemoryIDBSortedArrayMoves()

    /// Called before every read of the order; `entries` are the record table's, which holds the same keys.
    mutating func order(_ entries: ContiguousArray<MemoryIDBKeyEntry>) {
        moves.reset()
        if isOrdered {
            return
        }
        keys.reserveCapacity(entries.count)
        for entry in entries {
            keys.append(entry.key)
        }
        keys.sort { memoryIDBCompare($0, $1) < 0 }
        isOrdered = true
    }

    /// Counts an insertion or removal moving `moved` keys; false when it stops keeping the order instead, which an
    /// open cursor on the store (`mayLeaveUnsorted` false) prevents: a cursor's positions are indices into `keys`.
    ///
    /// Moves made while the order must be kept are not counted.
    private mutating func keepsOrder(moving moved: Int, mayLeaveUnsorted: Bool) -> Bool {
        if !mayLeaveUnsorted || !moves.exceedSortCost(adding: moved, count: keys.count) {
            return true
        }
        keys.removeAll(keepingCapacity: true)
        isOrdered = false
        return false
    }

    /// Inserts a key known to be absent; returns its index, or nil if the keys are not kept in order.
    mutating func insert(_ key: MemoryIDBKey, mayLeaveUnsorted: Bool) -> Int? {
        if !isOrdered {
            return nil
        }
        // Keys arriving in ascending order (the common case) go at the end: one comparison, not a binary search.
        var position = keys.count
        if position > 0 {
            if memoryIDBCompare(keys[position - 1], key) >= 0 {
                position = memoryIDBLowerBound(self, key)
            }
        }
        if position == keys.count {
            keys.append(key)
            return position
        }
        if !keepsOrder(moving: keys.count - position, mayLeaveUnsorted: mayLeaveUnsorted) {
            return nil
        }
        keys.insert(key, at: position)
        return position
    }

    /// Removes a key the record table held.
    mutating func remove(_ key: MemoryIDBKey, mayLeaveUnsorted: Bool) {
        if !isOrdered {
            return
        }
        guard let position = memoryIDBFind(self, key) else {
            return
        }
        if position == keys.count - 1 {
            keys.removeLast()
            return
        }
        if keepsOrder(moving: keys.count - 1 - position, mayLeaveUnsorted: mayLeaveUnsorted) {
            keys.remove(at: position)
        }
    }

    var count: Int {
        keys.count
    }

    var isEmpty: Bool {
        keys.isEmpty
    }

    /// The key of `self[index]`.
    func key(_ index: Int) -> MemoryIDBKey {
        keys[index]
    }

    /// IDBKeyData::compare(self[index], key)'s sign, with `key` as a MemoryIDBKey.
    @inline(always)
    func compare(_ index: Int, _ key: MemoryIDBKey) -> Int {
        memoryIDBCompare(keys[index], key)
    }

    mutating func reserve(_ capacity: Int) {
        if isOrdered {
            keys.reserveCapacity(capacity)
        }
    }
}

/// First index whose element is not less than `key`.
func memoryIDBLowerBound(_ elements: borrowing MemoryIDBOrderedRecords, _ key: MemoryIDBKey) -> Int {
    var low = 0
    var high = elements.count
    while low < high {
        let middle = low + (high - low) / 2
        if elements.compare(middle, key) < 0 {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

/// First index whose element is greater than `key`.
func memoryIDBUpperBound(_ elements: borrowing MemoryIDBOrderedRecords, _ key: MemoryIDBKey) -> Int {
    var low = 0
    var high = elements.count
    while low < high {
        let middle = low + (high - low) / 2
        if elements.compare(middle, key) <= 0 {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

func memoryIDBFind(_ elements: borrowing MemoryIDBOrderedRecords, _ key: MemoryIDBKey) -> Int? {
    let index = memoryIDBLowerBound(elements, key)
    if index < elements.count {
        if elements.compare(index, key) == 0 {
            return index
        }
    }
    return nil
}

/// An IDBKeyRangeData with its bounds as MemoryIDBKeys.
struct MemoryIDBKeyRange {
    var lowerKey: MemoryIDBKey
    var upperKey: MemoryIDBKey
    var lowerOpen: Bool
    var upperOpen: Bool

    init(_ range: borrowing WebCore.IDBKeyRangeData) {
        lowerKey = MemoryIDBKey(range.lowerKey)
        upperKey = MemoryIDBKey(range.upperKey)
        lowerOpen = range.lowerOpen
        upperOpen = range.upperOpen
    }

    /// IDBKeyRangeData::isExactlyOneKey.
    var isExactlyOneKey: Bool {
        if lowerOpen || upperOpen || !upperKey.isValid || !lowerKey.isValid {
            return false
        }
        return lowerKey == upperKey
    }

    /// IDBKeyRangeData::containsKey.
    func contains(_ key: MemoryIDBKey) -> Bool {
        memoryIDBRangeContains(lowerKey, upperKey, lowerOpen, upperOpen, key)
    }
}

func memoryIDBIsTransaction(_ transaction: WebCore.IDBResourceIdentifier?, _ identifier: WebCore.IDBResourceIdentifier) -> Bool {
    guard let transaction else {
        return false
    }
    return WebCore.idbResourceIdentifierEqual(transaction, identifier)
}
