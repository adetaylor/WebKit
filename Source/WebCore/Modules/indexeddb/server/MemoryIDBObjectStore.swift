//
// Copyright (C) 2015-2021 Apple Inc. All rights reserved.
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

// An object store of the memory store: its records, key generator and indexes.

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

struct MemoryIDBObjectStoreState: ~Copyable {
    /// The spec's maximum key generator value, 2^53.
    static let maxGeneratedKeyValue: UInt64 = 0x20_0000_0000_0000

    var info: WebCore.IDBObjectStoreInfo
    let identifier: UInt64
    var writeTransaction: WebCore.IDBResourceIdentifier?
    var keyGeneratorValueBeforeTransaction: UInt64 = 1
    var keyGeneratorValue: UInt64 = 1
    var transactionModifiedRecords = MemoryIDBKeyMap<WebCore.ThreadSafeDataBuffer>()
    /// The records' keys, ascending, and their values by key.
    var keys = MemoryIDBOrderedRecords()
    var values = MemoryIDBKeyTable<WebCore.ThreadSafeDataBuffer>()
    /// Whether the ordered keys exist: false until the first record, and again after a clear.
    var hasOrderedKeys = false
    /// Changes whenever `keys` does, so a cursor's cached index re-seeks by key.
    var generation: UInt64
    /// The indexes registered by identifier (one per identifier), in the order they were registered.
    var indexes = UniqueArray<MemoryIDBIndexState>()
    /// This store's other indexes, which only `indexesByName` or a transaction's changes (`indexes`, `deletedIndexes`,
    /// `originalIndexNames`) reach: an index deleted, or one whose identifier another index has taken.
    var unregisteredIndexes = UniqueArray<MemoryIDBIndexState>()
    /// The indexes by name, by serial: a name gets an entry only if it has none (the first index registered under it
    /// keeps it), and a rename moves the entry under the old name, whichever index it holds, so an entry's name can
    /// differ from its index's. nil: the null reference a rename moves from a name with no entry.
    var indexesByName: [(name: WTF.String, index: UInt64?)] = []

    /// `generation`: from the database's generationSeed, so a store recreated under a reused identifier starts above
    /// every generation of the old one.
    init(_ info: WebCore.IDBObjectStoreInfo, generation: UInt64) {
        self.info = info
        identifier = info.identifier().toUInt64()
        self.generation = generation
    }

    func indexSlot(_ identifier: UInt64) -> Int? {
        for i in 0..<indexes.count where indexes[i].identifier == identifier {
            return i
        }
        return nil
    }

    func registeredIndexSlot(serial: UInt64) -> Int? {
        for i in 0..<indexes.count where indexes[i].serial == serial {
            return i
        }
        return nil
    }

    func unregisteredIndexSlot(serial: UInt64) -> Int? {
        for i in 0..<unregisteredIndexes.count where unregisteredIndexes[i].serial == serial {
            return i
        }
        return nil
    }

    func unregisteredIndexSlot(identifier: UInt64) -> Int? {
        for i in 0..<unregisteredIndexes.count where unregisteredIndexes[i].identifier == identifier {
            return i
        }
        return nil
    }

    func holdsIndex(serial: UInt64) -> Bool {
        registeredIndexSlot(serial: serial) != nil || unregisteredIndexSlot(serial: serial) != nil
    }

    /// The info of an index this store holds.
    func indexInfo(serial: UInt64) -> WebCore.IDBIndexInfo {
        if let x = registeredIndexSlot(serial: serial) {
            return indexes[x].info
        }
        guard let x = unregisteredIndexSlot(serial: serial) else {
            WTFCrash()
        }
        return unregisteredIndexes[x].info
    }

    /// Adds an entry for `index` under `name` unless the name has one.
    private mutating func addIndexName(_ name: WTF.String, _ index: UInt64?) {
        if !indexesByName.contains(where: { WebCore.idbStringEqual($0.name, name) }) {
            indexesByName.append((name: name, index: index))
        }
    }

    /// Removes the entry under `name` and returns the index it holds (nil also for a null entry).
    private mutating func takeIndexName(_ name: WTF.String) -> UInt64? {
        for i in indexesByName.indices where WebCore.idbStringEqual(indexesByName[i].name, name) {
            return indexesByName.remove(at: i).index
        }
        return nil
    }

    /// Takes the index registered under `identifier`, and the `indexesByName` entry under its name, out of the maps.
    ///
    /// Returns the index that entry held, or nil if there is no such index, entry or index in the entry. The index taken
    /// out by identifier stays among the unregistered ones.
    mutating func takeIndexByIdentifier(_ identifier: UInt64) -> UInt64? {
        guard let slot = indexSlot(identifier) else {
            return nil
        }
        let index = indexes.remove(at: slot)
        let name = index.info.copiedName
        unregisteredIndexes.append(index)
        return takeIndexName(name)
    }

    /// Registers an index this store holds by name and by identifier, unless taken.
    mutating func registerIndex(serial: UInt64) {
        addIndexName(indexInfo(serial: serial).copiedName, serial)
        guard let x = unregisteredIndexSlot(serial: serial) else {
            return
        }
        if indexSlot(unregisteredIndexes[x].identifier) == nil {
            let index = unregisteredIndexes.remove(at: x)
            indexes.append(index)
        }
    }

    /// Drops the unregistered indexes that neither `indexesByName` nor `logged` (the serials a transaction's changes
    /// name) reaches, with their cursors unless a registered index has their identifier.
    mutating func dropUnreachedIndexes(_ logged: [UInt64], _ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        var i = 0
        while i < unregisteredIndexes.count {
            let serial = unregisteredIndexes[i].serial
            if logged.contains(serial) || indexesByName.contains(where: { $0.index == serial }) {
                i += 1
                continue
            }
            let index = unregisteredIndexes.remove(at: i)
            if indexSlot(index.identifier) == nil {
                memoryIDBRemoveCursors(&cursors, index: index.identifier)
            }
        }
    }

    func isWriteTransaction(_ transaction: WebCore.IDBResourceIdentifier) -> Bool {
        memoryIDBIsTransaction(writeTransaction, transaction)
    }

    mutating func writeTransactionStarted(_ transaction: WebCore.IDBResourceIdentifier) {
        writeTransaction = transaction
        keyGeneratorValueBeforeTransaction = keyGeneratorValue
        for i in 0..<indexes.count {
            indexes[i].writeTransaction = transaction
        }
    }

    /// Undoes the changes the transaction made, if it writes this store.
    mutating func transactionAborted(_ transaction: WebCore.IDBResourceIdentifier, _ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        if !isWriteTransaction(transaction) {
            return
        }
        let modified = transactionModifiedRecords.entries
        let modifiedValues = transactionModifiedRecords.values
        transactionModifiedRecords.removeAll()
        // Room for every record that may come back (after a clear, all of them), so the table grows once.
        values.reserve(values.count + modified.count)
        keys.reserve(keys.count + modified.count)
        let mayLeaveUnsorted = !memoryIDBHasObjectStoreCursor(cursors, identifier)
        for i in 0..<modified.count {
            let entry = modified[i]
            deleteRecord(entry.key, entry.hash, aborting: true, &cursors)
            if WebCore.threadSafeDataBufferHasData(modifiedValues[i]) {
                if let position = insertRecord(entry.key, entry.hash, modifiedValues[i], mayLeaveUnsorted: mayLeaveUnsorted) {
                    updateCursorsForPutRecord(position, &cursors)
                }
            }
        }
        keyGeneratorValue = keyGeneratorValueBeforeTransaction
        for i in 0..<indexes.count {
            indexes[i].transactionAborted(transaction, &cursors)
        }
    }

    mutating func writeTransactionFinished() {
        writeTransaction = nil
        transactionModifiedRecords.removeAll()
        for i in 0..<indexes.count {
            indexes[i].writeTransactionFinished()
        }
    }

    func isVersionChangeWriter(_ transaction: borrowing MemoryIDBTransactionState) -> Bool {
        // Not `&&`: its right side is an autoclosure, which cannot capture a borrowed parameter.
        if !transaction.isVersionChange {
            return false
        }
        return isWriteTransaction(transaction.identifier)
    }

    mutating func addIndex(
        _ transaction: inout MemoryIDBTransactionState,
        _ indexInfo: WebCore.IDBIndexInfo,
        isNameInUse: Bool,
        generation: UInt64
    ) -> WebCore.MemoryIDBStoreError {
        if !isVersionChangeWriter(transaction) {
            return .TransactionStateInvalid
        }
        var index = MemoryIDBIndexState(indexInfo, identifier, generation: generation)
        if indexSlot(index.identifier) != nil {
            return .IndexIdentifierExists
        }
        // `isNameInUse`: another index has the name in the database info. Traps: the web process guarantees unique names.
        if isNameInUse {
            WTFCrash()
        }
        index.writeTransaction = transaction.identifier
        info.addExistingIndex(indexInfo)
        transaction.indexAdded(index.serial)
        // An index a version change added can stay registered after its abort, unknown to the database info, so its
        // name can have an entry already: this one is then registered by identifier only.
        addIndexName(index.info.copiedName, index.serial)
        indexes.append(index)
        return .None
    }

    mutating func revertAddIndex(
        _ transaction: inout MemoryIDBTransactionState,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) {
        if !isVersionChangeWriter(transaction) {
            return
        }
        info.deleteIndex(indexIdentifier)
        let identifier = indexIdentifier.toUInt64()
        if indexSlot(identifier) == nil {
            return
        }
        // The transaction forgets the index `indexesByName` held under the reverted index's name, which may be another one.
        if let holder = takeIndexByIdentifier(identifier) {
            transaction.indexes.removeAll { $0 == holder }
            transaction.originalIndexNames.removeAll { $0.index == holder }
        }
        memoryIDBRemoveCursors(&cursors, index: identifier)
        dropUnreachedIndexes(transaction.loggedIndexes, &cursors)
    }

    mutating func updateIndexRecordsWithIndexKey(
        _ transaction: borrowing MemoryIDBTransactionState,
        _ indexInfo: WebCore.IDBIndexInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IndexKey,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) -> WebCore.MemoryIDBStoreError {
        if !isVersionChangeWriter(transaction) {
            return .TransactionStateInvalid
        }
        guard let slot = indexSlot(indexInfo.identifier().toUInt64()) else {
            return .IndexDoesNotExist
        }
        if indexKey.isNull() {
            return .None
        }
        return indexes[slot].putIndexKey(MemoryIDBKey(key), indexKey, &cursors)
    }

    /// Registers a deleted index again unless the info has an index of its name.
    mutating func maybeRestoreDeletedIndex(serial: UInt64) {
        let indexInfo = indexInfo(serial: serial)
        if info.hasIndex(indexInfo.copiedName) {
            return
        }
        info.addExistingIndex(indexInfo)
        registerIndex(serial: serial)
    }

    /// Deletes the index registered under `identifier` (takeIndexByIdentifier) and its info.
    ///
    /// Returns the index `indexesByName` held under its name, which the transaction records as deleted, or nil (a
    /// Constraint error) if `transaction` does not write this store or takeIndexByIdentifier finds no index.
    mutating func deleteIndex(_ transaction: WebCore.IDBResourceIdentifier, _ identifier: UInt64) -> UInt64? {
        if !isWriteTransaction(transaction) {
            return nil
        }
        guard let slot = indexSlot(identifier) else {
            return nil
        }
        let indexIdentifier = indexes[slot].info.identifier()
        guard let deleted = takeIndexByIdentifier(identifier) else {
            return nil
        }
        info.deleteIndex(indexIdentifier)
        return deleted
    }

    /// Restores the name an index had before the aborting transaction renamed it.
    ///
    /// Takes out the index registered under its identifier (takeIndexByIdentifier), renames this one and its info, and
    /// registers the index `indexesByName` held under the other's name. Returns false if takeIndexByIdentifier finds no
    /// index.
    mutating func restoreIndexName(serial: UInt64, _ originalName: WTF.String) -> Bool {
        let renamed = indexInfo(serial: serial)
        let identifier = renamed.identifier()
        guard let named = takeIndexByIdentifier(identifier.toUInt64()) else {
            return false
        }
        info.deleteIndex(copy identifier)
        if let x = registeredIndexSlot(serial: serial) {
            indexes[x].rename(originalName)
        } else if let x = unregisteredIndexSlot(serial: serial) {
            unregisteredIndexes[x].rename(originalName)
        }
        info.addExistingIndex(indexInfo(serial: serial))
        registerIndex(serial: named)
        return true
    }

    func containsRecord(_ key: WebCore.IDBKeyData) -> Bool {
        values.find(key) != nil
    }

    mutating func clear(_ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        orderKeys()
        // Every record goes into the map in key order.
        transactionModifiedRecords.reserve(keys.count)
        for key in keys.keys {
            let hash = key.hash
            if let slot = values.find(key, hash) {
                transactionModifiedRecords.add(key, hash, values.values[slot])
            }
        }
        keys = MemoryIDBOrderedRecords()
        values = MemoryIDBKeyTable()
        hasOrderedKeys = false
        generation &+= 1
        for i in 0..<indexes.count {
            indexes[i].objectStoreCleared(&cursors)
        }
        memoryIDBNotifyObjectStoreCleared(&cursors, identifier)
    }

    /// `hash` is the key's hash. `aborting`: an abort is restoring the record, so nothing is saved for it.
    mutating func deleteRecord(
        _ nativeKey: MemoryIDBKey,
        _ hash: UInt64,
        aborting: Bool,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) {
        // The hash map first: an absent key costs no search of the ordered keys.
        guard let removed = values.remove(nativeKey, hash) else {
            return
        }
        if !aborting {
            // The record is saved under the key the delete names, which can differ from the stored one though equal
            // (-0 and +0): an abort restores it under that key.
            transactionModifiedRecords.add(nativeKey, hash, removed.value)
        }
        keys.remove(nativeKey, mayLeaveUnsorted: !memoryIDBHasObjectStoreCursor(cursors, identifier))
        generation &+= 1
        // The record's index entries go too: those of the indexes `indexesByName` holds.
        for entry in indexesByName {
            // Traps on a null entry, which names no index.
            guard let serial = entry.index else {
                WTFCrash()
            }
            if let x = registeredIndexSlot(serial: serial) {
                indexes[x].removeEntriesWithValueKey(nativeKey, aborting: aborting, &cursors)
            } else if let x = unregisteredIndexSlot(serial: serial) {
                unregisteredIndexes[x].removeEntriesWithValueKey(nativeKey, aborting: aborting, &cursors)
            }
        }
        memoryIDBNotifyKeyDeleted(&cursors, identifier, nativeKey)
    }

    mutating func deleteRange(_ inputRange: WebCore.IDBKeyRangeData, _ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        if inputRange.isExactlyOneKey() {
            let nativeKey = MemoryIDBKey(inputRange.lowerKey)
            deleteRecord(nativeKey, nativeKey.hash, aborting: false, &cursors)
            return
        }
        // Found before any is deleted: a delete removes only its own record, so these are the keys a search for the
        // lowest key above the last deleted one would give in turn.
        var deleted: [WebCore.IDBKeyData] = []
        var range = copy inputRange
        while true {
            let key = lowestKeyWithRecordInRange(range)
            if key.isNull() {
                break
            }
            range.lowerKey = key
            range.lowerOpen = true
            deleted.append(key)
        }
        for key in deleted {
            let nativeKey = MemoryIDBKey(key)
            deleteRecord(nativeKey, nativeKey.hash, aborting: false, &cursors)
        }
    }

    /// Sorts the record keys if writes left them unordered; every read of `keys` comes after it.
    mutating func orderKeys() {
        keys.order(values.entries)
    }

    /// Inserts a record known to be absent; returns its index in `keys`, or nil if they are not kept in order.
    ///
    /// With `hash` the key's hash; `mayLeaveUnsorted` false while an object store cursor is open on the store.
    private mutating func insertRecord(
        _ key: MemoryIDBKey,
        _ hash: UInt64,
        _ value: WebCore.ThreadSafeDataBuffer,
        mayLeaveUnsorted: Bool
    ) -> Int? {
        hasOrderedKeys = true
        let position = keys.insert(key, mayLeaveUnsorted: mayLeaveUnsorted)
        values.insert(key, hash, value)
        generation &+= 1
        return position
    }

    // https://w3c.github.io/IndexedDB/#object-store-storage-operation
    // Never called while a transaction aborts, so what it changes is always recorded for an abort.
    mutating func overwriteRecord(
        _ key: WebCore.IDBKeyData,
        _ indexKeys: WebCore.IDBIndexKeyMapEntries,
        _ value: WebCore.ThreadSafeDataBuffer,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) -> WebCore.MemoryIDBStoreError {
        // A put that would violate a unique index changes nothing, so the record it would replace stays.
        // The key's MemoryIDBKey and hash once, for the constraint check, the delete, the transaction's modified records, the
        // insertion and the indexes.
        let nativeKey = MemoryIDBKey(key)
        let error = checkIndexConstraintsForPut(nativeKey, indexKeys)
        if error != .None {
            return error
        }
        // An existing record is deleted as a record is, which removes it from the indexes too.
        let hash = nativeKey.hash
        deleteRecord(nativeKey, hash, aborting: false, &cursors)
        return addRecord(indexKeys, value, hash, nativeKey, &cursors)
    }

    private func checkIndexConstraintsForPut(_ key: MemoryIDBKey, _ indexKeys: WebCore.IDBIndexKeyMapEntries) -> WebCore.MemoryIDBStoreError
    {
        let entries: Span<WebCore.IDBIndexKeyMapEntry> = WebCore.idbIndexKeyMapEntryElements(indexKeys)
        for i in 0..<entries.count {
            guard let slot = indexSlot(entries[i].identifier.toUInt64()) else {
                return .MissingIndexMetadata
            }
            if !indexes[slot].unique {
                continue
            }
            if !indexes[slot].multiEntry {
                // One key, with no array.
                let indexKey = entries[i].key.asOneKey()
                // Nested ifs, not &&: an autoclosure cannot capture a borrowed key.
                if indexKey.isValid() {
                    if indexes[slot].hasRecordForOtherPrimaryKey(indexKey, key) {
                        return .UniquenessViolation
                    }
                }
                continue
            }
            for indexKey in memoryIDBKeyArray(entries[i].key.multiEntry()) {
                if !indexKey.isValid() {
                    continue
                }
                if indexes[slot].hasRecordForOtherPrimaryKey(indexKey, key) {
                    return .UniquenessViolation
                }
            }
        }
        return .None
    }

    private mutating func addRecord(
        _ indexKeys: WebCore.IDBIndexKeyMapEntries,
        _ value: WebCore.ThreadSafeDataBuffer,
        _ hash: UInt64,
        _ nativeKey: MemoryIDBKey,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) -> WebCore.MemoryIDBStoreError {
        // A put in a read-only transaction has no write transaction: trap.
        if writeTransaction == nil {
            WTFCrash()
        }
        // The record is absent here (deleteRecord ran first), so this records "no record" unless the delete already
        // recorded the old one.
        transactionModifiedRecords.add(nativeKey, hash, WebCore.ThreadSafeDataBuffer())
        let insertedAt = insertRecord(nativeKey, hash, value, mayLeaveUnsorted: !memoryIDBHasObjectStoreCursor(cursors, identifier))
        let insertedGeneration = generation
        // An error indexing the addition reverts it.
        let error = updateIndexesForPutRecord(nativeKey, indexKeys, &cursors)
        if error == .None && generation == insertedGeneration {
            // Indexing changed no record, so the record is still where it went in.
            if let insertedAt {
                updateCursorsForPutRecord(insertedAt, &cursors)
            }
        } else if error != .None {
            if values.remove(nativeKey, hash) != nil {
                keys.remove(nativeKey, mayLeaveUnsorted: !memoryIDBHasObjectStoreCursor(cursors, identifier))
                generation &+= 1
            }
        } else if keys.isOrdered, let position = memoryIDBFind(keys, nativeKey) {
            updateCursorsForPutRecord(position, &cursors)
        }
        return error
    }

    private func updateCursorsForPutRecord(_ position: Int, _ cursors: inout UniqueArray<MemoryIDBCursorEntry>) {
        for i in 0..<cursors.count where !cursors[i].isIndexCursor && cursors[i].objectStoreIdentifier == identifier {
            cursors[i].state.keyAdded(self, position)
        }
    }

    private mutating func updateIndexesForPutRecord(
        _ key: MemoryIDBKey,
        _ indexKeys: WebCore.IDBIndexKeyMapEntries,
        _ cursors: inout UniqueArray<MemoryIDBCursorEntry>
    ) -> WebCore.MemoryIDBStoreError {
        var error = WebCore.MemoryIDBStoreError.None
        // The entries before `changed` went through.
        var changed = 0
        let entries: Span<WebCore.IDBIndexKeyMapEntry> = WebCore.idbIndexKeyMapEntryElements(indexKeys)
        for i in 0..<entries.count {
            guard let slot = indexSlot(entries[i].identifier.toUInt64()) else {
                error = .MissingIndexMetadata
                break
            }
            error = indexes[slot].putIndexKey(key, entries[i].key, &cursors)
            if error != .None {
                break
            }
            changed = i + 1
        }
        // A failed index put reverts the ones that went through.
        if error != .None {
            for i in 0..<changed {
                if let slot = indexSlot(entries[i].identifier.toUInt64()) {
                    indexes[slot].removeRecord(key, entries[i].key, &cursors)
                }
            }
        }
        return error
    }

    mutating func countForKeyRange(_ indexIdentifier: UInt64?, _ inputRange: WebCore.IDBKeyRangeData) -> UInt64 {
        if let indexIdentifier {
            // An unknown index is a caller bug: trap.
            guard let slot = indexSlot(indexIdentifier) else {
                WTFCrash()
            }
            indexes[slot].orderRecords()
            return indexes[slot].countForKeyRange(inputRange)
        }
        if values.count == 0 {
            return 0
        }
        var count: UInt64 = 0
        var range = copy inputRange
        while true {
            let key = lowestKeyWithRecordInRange(range)
            if key.isNull() {
                break
            }
            count += 1
            range.lowerKey = key
            range.lowerOpen = true
        }
        return count
    }

    func valueForKey(_ key: WebCore.IDBKeyData) -> WebCore.ThreadSafeDataBuffer {
        guard let slot = values.find(key) else {
            return WebCore.ThreadSafeDataBuffer()
        }
        return values.values[slot]
    }

    /// A cursor's currentData result with a value: the keys are the cursor's, passed in
    /// place, and the value is read in the table, not copied out of it.
    mutating func cursorResult(
        _ key: WebCore.IDBKeyData,
        _ primaryKey: WebCore.IDBKeyData,
        _ recordKey: MemoryIDBKey
    ) -> WebCore.IDBGetResult {
        guard let slot = values.find(recordKey, recordKey.hash) else {
            return WebCore.makeIDBCursorResultValue(key, primaryKey, WebCore.ThreadSafeDataBuffer(), &info)
        }
        return WebCore.makeIDBCursorResultValue(key, primaryKey, values.values[slot], &info)
    }

    /// getRecord's result with a value, the value at `slot` in the table read in place.
    mutating func getResultKeyValue(_ key: WebCore.IDBKeyData, _ slot: Int) -> WebCore.IDBGetResult {
        WebCore.makeIDBGetResultKeyValue(key, values.values[slot], &info)
    }

    mutating func getAllRecords(
        _ inputRange: WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType
    ) -> WebCore.IDBGetAllResult {
        var result = WebCore.makeIDBGetAllResult(type, &info)
        let wantValues = type == .Values
        let targetCount = count != 0 ? count : UInt32.max
        var range = copy inputRange
        var currentCount: UInt32 = 0
        while currentCount < targetCount {
            let key = lowestKeyWithRecordInRange(range)
            if key.isNull() {
                return result
            }
            range.lowerKey = key
            range.lowerOpen = true
            if wantValues {
                WebCore.idbGetAllResultAddValue(&result, valueForKey(key))
            }
            WebCore.idbGetAllResultAddKey(&result, key)
            currentCount += 1
        }
        return result
    }

    mutating func orderIndexRecords(_ slot: Int) {
        indexes[slot].orderRecords()
    }

    mutating func indexGetAllRecords(
        _ slot: Int,
        _ range: WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType
    ) -> WebCore.IDBGetAllResult {
        var result = WebCore.makeIDBGetAllResult(type, &info)
        indexes[slot].orderRecords()
        indexes[slot].getAllRecords(&result, range, count, type == .Values, values)
        return result
    }

    mutating func indexGetRecord(_ slot: Int, _ keyOnly: Bool, _ range: WebCore.IDBKeyRangeData) -> WebCore.IDBGetResult {
        // A get of one key reads no order.
        if !range.isExactlyOneKey() {
            indexes[slot].orderRecords()
        }
        guard let primaryKey = indexes[slot].lowestPrimaryKey(range) else {
            return WebCore.makeEmptyIDBGetResult()
        }
        let key = primaryKey.makeIDBKeyData()
        if keyOnly {
            return WebCore.makeIDBGetResultKey(key)
        }
        guard let valueSlot = values.find(primaryKey, primaryKey.hash) else {
            return WebCore.makeIDBGetResultKeyValue(key, WebCore.ThreadSafeDataBuffer(), &info)
        }
        return WebCore.makeIDBGetResultKeyValue(key, values.values[valueSlot], &info)
    }

    mutating func lowestKeyWithRecordInRange(_ range: WebCore.IDBKeyRangeData) -> WebCore.IDBKeyData {
        guard let (key, rangeKeySlot) = lowestRecordInRange(range) else {
            return WebCore.IDBKeyData()
        }
        return rangeKeySlot != nil ? range.lowerKey : key.makeIDBKeyData()
    }

    /// The key of the record lowestKeyWithRecordInRange answers with, and, when its answer is the range's own key (an
    /// exactly-one-key range whose key is in the table), the record's position in the table.
    mutating func lowestRecordInRange(_ range: WebCore.IDBKeyRangeData) -> (key: MemoryIDBKey, rangeKeySlot: Int?)? {
        if values.count == 0 {
            return nil
        }
        if range.isExactlyOneKey() {
            if let slot = values.find(range.lowerKey) {
                return (key: values.entries[slot].key, rangeKeySlot: slot)
            }
        }
        orderKeys()
        let lowerKey = MemoryIDBKey(range.lowerKey)
        var lowest = memoryIDBLowerBound(keys, lowerKey)
        if lowest == keys.count {
            return nil
        }
        if range.lowerOpen, keys.key(lowest) == lowerKey {
            lowest += 1
        }
        if lowest == keys.count {
            return nil
        }
        if !range.upperKey.isNull() {
            let upperKey = MemoryIDBKey(range.upperKey)
            if keys.compare(lowest, upperKey) > 0 {
                return nil
            }
            if range.upperOpen, keys.key(lowest) == upperKey {
                return nil
            }
        }
        return (key: keys.key(lowest), rangeKeySlot: nil)
    }

    mutating func rename(_ newName: WTF.String) {
        info.rename(newName)
    }

    /// Renames the index at `slot`, and moves the `indexesByName` entry under its old name, whichever index it holds, to
    /// `newName` unless that name has an entry.
    mutating func renameIndex(_ slot: Int, _ newName: WTF.String) {
        let indexIdentifier = indexes[slot].info.identifier()
        // Traps on an index the info does not have: there is no info to rename.
        if !info.hasIndex(copy indexIdentifier) {
            WTFCrash()
        }
        WebCore.idbObjectStoreInfoRenameIndex(&info, indexIdentifier, newName)
        let named = takeIndexName(indexes[slot].info.copiedName)
        addIndexName(newName, named)
        indexes[slot].rename(newName)
    }
}
