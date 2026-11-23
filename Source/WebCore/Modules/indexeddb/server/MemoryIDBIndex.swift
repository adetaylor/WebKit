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

// An index of the memory store.

internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
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

struct MemoryIDBIndexState: ~Copyable {
    var info: WebCore.IDBIndexInfo
    let identifier: UInt64
    let objectStoreIdentifier: UInt64
    /// The info's flags, which no rename changes: reading them through `info` copies the whole info.
    let unique: Bool
    let multiEntry: Bool
    var writeTransaction: WebCore.IDBResourceIdentifier?
    var transactionModifiedRecords = MemoryIndexModifiedRecords()
    var records: MemoryIndexValueStore?
    /// The generation the next `records` starts at: above every one the old records had, so no position from them is
    /// current in the new ones.
    var nextRecordsGeneration: UInt64
    /// Unique to this index among every index the database creates: two indexes can share an identifier (one deleted
    /// or no longer registered by identifier, and one added after it), so the object store's `indexesByName` and a
    /// transaction's changes refer to an index by this.
    let serial: UInt64

    init(_ info: WebCore.IDBIndexInfo, _ objectStoreIdentifier: UInt64, generation: UInt64) {
        self.info = info
        nextRecordsGeneration = generation
        serial = generation
        identifier = info.identifier().toUInt64()
        self.objectStoreIdentifier = objectStoreIdentifier
        unique = info.unique()
        multiEntry = info.multiEntry()
    }

    mutating func rename(_ newName: WTF.String) {
        info.rename(newName)
    }

    /// Sorts the records if writes left them unordered; every read of their order (a range, a cursor) comes after it.
    mutating func orderRecords() {
        records?.order()
    }

    mutating func objectStoreCleared(_ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        if let records {
            transactionModifiedRecords.reserve(records.entries.count)
            for entry in records.entries {
                transactionModifiedRecords.add(entry.key, entry.hash, entry.primaryKeys)
            }
            nextRecordsGeneration = records.currentGeneration &+ 1
        }
        records = nil
        memoryIDBNotifyIndexRecordsAllChanged(&cursors, identifier)
    }

    /// The primary key of the first record in the range (nil: no record).
    func lowestPrimaryKey(_ range: WebCore.IDBKeyRangeData) -> MemoryIDBKey? {
        guard let records else {
            return nil
        }
        let lowerKey = MemoryIDBKey(range.lowerKey)
        let keyToLookFor: MemoryIDBKey?
        if range.isExactlyOneKey() {
            keyToLookFor = lowerKey
        } else {
            keyToLookFor = records.lowestKeyWithRecordInRange(
                lowerKey,
                MemoryIDBKey(range.upperKey),
                range.lowerOpen,
                range.upperOpen,
                false
            )
        }
        guard let keyToLookFor, !keyToLookFor.isNull, let lowestValue = records.lowestValueForKey(keyToLookFor), !lowestValue.isNull else {
            return nil
        }
        return lowestValue
    }

    func countForKeyRange(_ range: WebCore.IDBKeyRangeData) -> UInt64 {
        guard let records else {
            return 0
        }
        var count: UInt64 = 0
        var lowerKey = MemoryIDBKey(range.lowerKey)
        let upperKey = MemoryIDBKey(range.upperKey)
        var lowerOpen = range.lowerOpen
        var isExactlyOneKey = range.isExactlyOneKey()
        while let key = records.lowestKeyWithRecordInRange(lowerKey, upperKey, lowerOpen, range.upperOpen, isExactlyOneKey) {
            count += records.countForKey(key)
            lowerKey = key
            lowerOpen = true
            isExactlyOneKey = false
        }
        return count
    }

    func getAllRecords(
        _ result: inout WebCore.IDBGetAllResult,
        _ range: WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ values: Bool,
        _ objectStoreValues: borrowing MemoryIDBKeyTable<WebCore.ThreadSafeDataBuffer>
    ) {
        guard let records else {
            return
        }
        let targetCount = count != 0 ? count : UInt32.max
        var lowerKey = MemoryIDBKey(range.lowerKey)
        let upperKey = MemoryIDBKey(range.upperKey)
        var lowerOpen = range.lowerOpen
        var isExactlyOneKey = range.isExactlyOneKey()
        var currentCount: UInt32 = 0
        while currentCount < targetCount {
            guard let key = records.lowestKeyWithRecordInRange(lowerKey, upperKey, lowerOpen, range.upperOpen, isExactlyOneKey) else {
                return
            }
            lowerKey = key
            lowerOpen = true
            isExactlyOneKey = false
            guard let entry = records.entry(key) else {
                continue
            }
            let valueCount = Swift.min(entry.count, Int(targetCount - currentCount))
            for i in 0..<valueCount {
                let primaryKey = entry[i]
                WebCore.idbGetAllResultAddKey(&result, primaryKey.makeIDBKeyData())
                if values {
                    if let slot = objectStoreValues.find(primaryKey, primaryKey.hash) {
                        WebCore.idbGetAllResultAddValue(&result, objectStoreValues.values[slot])
                    } else {
                        WebCore.idbGetAllResultAddValue(&result, WebCore.ThreadSafeDataBuffer())
                    }
                }
            }
            currentCount += UInt32(valueCount)
        }
    }

    /// The index keys of an IndexKey, converted once.
    private func memoryIDBKeys(_ indexKey: WebCore.IndexKey) -> ContiguousArray<MemoryIDBKey> {
        if !multiEntry {
            return [MemoryIDBKey(indexKey.asOneKey())]
        }
        // The keys read in place from the IndexKey's vector, not copied into an array first.
        let vector = indexKey.multiEntry()
        let keys: Span<WebCore.IDBKeyData> = WebCore.idbKeyVectorElements(vector)
        var result = ContiguousArray<MemoryIDBKey>()
        result.reserveCapacity(keys.count)
        for i in keys.indices {
            keys.withBorrowedElement(i) { key in
                result.append(MemoryIDBKey(key))
            }
        }
        return result
    }

    /// `primaryKey` is the record's key, converted once by the object store for the whole put.
    mutating func putIndexKey(
        _ primaryKey: MemoryIDBKey,
        _ indexKey: WebCore.IndexKey,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) -> WebCore.MemoryIDBStoreError {
        if records == nil {
            records = MemoryIndexValueStore(unique: unique, generation: nextRecordsGeneration)
            memoryIDBNotifyIndexRecordsAllChanged(&cursors, identifier)
        }
        if !multiEntry {
            // One key, with no array.
            let key = MemoryIDBKey(indexKey.asOneKey())
            let result = addIndexRecord(key, primaryKey, aborting: false, mayLeaveUnsorted: !memoryIDBHasIndexCursor(cursors, identifier))
            memoryIDBNotifyIndexValueChanged(&cursors, identifier, key, primaryKey)
            return result
        }
        let keys = memoryIDBKeys(indexKey)
        if unique, let records {
            for key in keys where records.contains(key, key.hash) {
                return .Constraint
            }
        }
        let mayLeaveUnsorted = !memoryIDBHasIndexCursor(cursors, identifier)
        for key in keys {
            _ = addIndexRecord(key, primaryKey, aborting: false, mayLeaveUnsorted: mayLeaveUnsorted)
            memoryIDBNotifyIndexValueChanged(&cursors, identifier, key, primaryKey)
        }
        return .None
    }

    func hasRecordForOtherPrimaryKey(_ indexKey: WebCore.IDBKeyData, _ primaryKey: MemoryIDBKey) -> Bool {
        let key = MemoryIDBKey(indexKey)
        guard let records, let valueKeys = records.primaryKeysForKey(key, key.hash) else {
            return false
        }
        return valueKeys.contains { $0 != primaryKey }
    }

    mutating func removeRecord(_ primaryKey: MemoryIDBKey, _ indexKey: WebCore.IndexKey, _ cursors: inout UniqueArray<MemoryIDBCursorEntry>)
    {
        let mayLeaveUnsorted = !memoryIDBHasIndexCursor(cursors, identifier)
        for key in memoryIDBKeys(indexKey) {
            removeIndexRecord(key, primaryKey, mayLeaveUnsorted: mayLeaveUnsorted)
            memoryIDBNotifyIndexValueChanged(&cursors, identifier, key, primaryKey)
        }
    }

    mutating func removeEntriesWithValueKey(_ primaryKey: MemoryIDBKey, aborting: Bool, _ cursors: inout UniqueArray<MemoryIDBCursorEntry>)
    {
        guard records != nil else {
            return
        }
        if writeTransaction == nil {
            WTFCrash()
        }
        if !aborting, let entries = records?.entries {
            for entry in entries where entry.contains(primaryKey) {
                transactionModifiedRecords.add(entry.key, entry.hash, entry.primaryKeys)
            }
        }
        let changed = records?.removeEntriesWithValueKey(primaryKey, mayLeaveUnsorted: !memoryIDBHasIndexCursor(cursors, identifier)) ?? []
        for key in changed {
            memoryIDBNotifyIndexValueChanged(&cursors, identifier, key, primaryKey)
        }
    }

    /// `aborting`: the writing transaction is aborting, so nothing is recorded for an abort. `mayLeaveUnsorted` false
    /// while a cursor is open on the index.
    private mutating func addIndexRecord(
        _ indexKey: MemoryIDBKey,
        _ valueKey: MemoryIDBKey,
        aborting: Bool,
        mayLeaveUnsorted: Bool
    ) -> WebCore.MemoryIDBStoreError {
        if writeTransaction == nil {
            WTFCrash()
        }
        if records == nil {
            records = MemoryIndexValueStore(unique: unique, generation: nextRecordsGeneration)
        }
        // The key's hash and presence are found once for the lookups below.
        let hash = indexKey.hash
        let isPresent = records?.contains(indexKey, hash) ?? false
        if !aborting && !transactionModifiedRecords.contains(indexKey, hash) {
            // The entry's primary keys, or none when the store has no entry for the key.
            let primaryKeys = isPresent ? records?.primaryKeysForKey(indexKey, hash) : nil
            transactionModifiedRecords.add(indexKey, hash, primaryKeys ?? [])
        }
        let added = records?.addRecord(indexKey, hash, valueKey, isPresent: isPresent, mayLeaveUnsorted: mayLeaveUnsorted) ?? true
        return added ? .None : .Constraint
    }

    private mutating func removeIndexRecord(_ indexKey: MemoryIDBKey, _ valueKey: MemoryIDBKey, mayLeaveUnsorted: Bool) {
        guard records != nil else {
            return
        }
        if writeTransaction == nil {
            WTFCrash()
        }
        let hash = indexKey.hash
        if !transactionModifiedRecords.contains(indexKey, hash) {
            if let valueKeys = records?.primaryKeysForKey(indexKey, hash) {
                transactionModifiedRecords.add(indexKey, hash, valueKeys)
            }
        }
        records?.removeRecord(indexKey, valueKey, mayLeaveUnsorted: mayLeaveUnsorted)
    }

    mutating func writeTransactionFinished() {
        writeTransaction = nil
        transactionModifiedRecords.removeAll()
    }

    /// Undoes the changes the transaction made, if it writes this index.
    mutating func transactionAborted(_ transaction: WebCore.IDBResourceIdentifier, _ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        if !memoryIDBIsTransaction(writeTransaction, transaction) {
            return
        }
        memoryIDBNotifyIndexRecordsAllChanged(&cursors, identifier)
        let modified = transactionModifiedRecords.entries
        transactionModifiedRecords.removeAll()
        let mayLeaveUnsorted = !memoryIDBHasIndexCursor(cursors, identifier)
        for entry in modified {
            // Aborting, with primary keys to put back: the saved keys go back in one step.
            if !entry.primaryKeys.isEmpty {
                if records == nil {
                    records = MemoryIndexValueStore(unique: unique, generation: nextRecordsGeneration)
                }
                records?.restoreRecords(entry.key, entry.hash, entry.primaryKeys, mayLeaveUnsorted: mayLeaveUnsorted)
                continue
            }
            records?.removeAllRecordsForIndexKey(entry.key, mayLeaveUnsorted: mayLeaveUnsorted)
        }
    }
}
