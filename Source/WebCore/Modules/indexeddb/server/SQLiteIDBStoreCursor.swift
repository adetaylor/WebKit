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
//

// The SQLite IndexedDB store's cursors: a statement over Records (object store cursors) or IndexRecords (index cursors)
// from the current position to the end of the range, the records fetched ahead of the current one, and the restart
// after the object store changes. The statements are owned here and reached through get() for one use.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBGetResult
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBValue
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SQLiteDatabase
internal import WebCore_Private.Core.SQLiteIDBStoreTypes
internal import WebCore_Private.Core.SQLiteStatement
internal import WebCore_Private.Core.SwiftIDBTypes

/// The most records a cursor fetches ahead, and the most bytes.
private let sqliteIDBPrefetchLimit = 256
private let sqliteIDBPrefetchSizeLimit = 1 * 1024 * 1024

/// A fetched record, or the terminal one (completed or errored).
///
/// The key, primary key and value stay one IDBCursorRecord so C++ helpers can take it by reference without a copy.
struct SQLiteIDBStoreCursorRecord {
    var cursorRecord = WebCore.IDBCursorRecord()
    var completed = false
    var errored = false
    var rowID: Int64 = 0
    /// IDBCursorRecord::size, read once when the record is fetched.
    var size = 0

    var isTerminalRecord: Bool { completed || errored }

    /// The record in place (self is inout here): a const method of a stored C++ value read through the array is a copy.
    mutating func measure() {
        size = cursorRecord.size()
    }
}

private enum SQLiteIDBFetchResult {
    case success
    case failure
    case shouldFetchAgain
}

/// The cursor's statements, in one value so that a fetch steps them through one access.
private struct SQLiteIDBStoreCursorStatements: ~Copyable {
    var preIndex: WebCore.SQLiteStatementOwner? = nil
    var main: WebCore.SQLiteStatementOwner? = nil
    var cachedObjectStore: WebCore.SQLiteStatementOwner? = nil
}

final class SQLiteIDBStoreCursor {
    unowned let store: SQLiteIDBStore
    /// The transaction that owns this cursor and closes it before it goes away.
    unowned let transaction: SQLiteIDBStoreTransaction
    let identifier: WebCore.IDBResourceIdentifier
    let objectStoreID: UInt64
    private let indexID: UInt64?
    private let cursorDirection: WebCore.IndexedDB.CursorDirection
    private let isKeyAndValue: Bool
    let isBackingStoreCursor: Bool

    private var keyRange: WebCore.IDBKeyRangeData
    private var currentLowerKey = WebCore.IDBKeyData()
    private var currentUpperKey = WebCore.IDBKeyData()
    private var currentIndexRecordValue = WebCore.IDBKeyData()
    /// The records from `fetchedHead` on (the current one first).
    ///
    /// Dropped by advancing `fetchedHead`: Array.removeFirst would move every later record through its value witnesses.
    private var fetchedRecords: [SQLiteIDBStoreCursorRecord] = []
    private var fetchedHead = 0
    private var fetchedRecordsSize = 0
    private var currentKeyForUniqueness = WebCore.IDBKeyData()
    private var statements = SQLiteIDBStoreCursorStatements()
    private var statementNeedsReset = true
    private var boundID: UInt64
    private var prefetchCount: UInt32 = 0

    /// A cursor the page opened (IDBCursorInfo).
    init(
        store: SQLiteIDBStore,
        transaction: SQLiteIDBStoreTransaction,
        identifier: WebCore.IDBResourceIdentifier,
        objectStoreID: UInt64,
        indexID: UInt64?,
        direction: WebCore.IndexedDB.CursorDirection,
        isKeyAndValue: Bool,
        range: WebCore.IDBKeyRangeData,
        isBackingStoreCursor: Bool
    ) {
        self.store = store
        self.transaction = transaction
        self.identifier = identifier
        self.objectStoreID = objectStoreID
        self.indexID = indexID
        self.cursorDirection = direction
        self.isKeyAndValue = isKeyAndValue
        self.keyRange = range
        self.boundID = objectStoreID
        self.isBackingStoreCursor = isBackingStoreCursor
    }

    /// maybeCreate and maybeCreateBackingStoreCursor after construction: nil when the statement does not prepare or
    /// the first fetch fails.
    func establish() -> Bool {
        establishStatement() && advance(1)
    }

    /// Drops the statements; the store closes the database after this.
    func dropStatements() {
        statements.preIndex = nil
        statements.main = nil
        statements.cachedObjectStore = nil
    }

    private var isDirectionNext: Bool {
        cursorDirection == .Next || cursorDirection == .Nextunique
    }

    // MARK: The current record

    private var fetchedCount: Int { fetchedRecords.count &- fetchedHead }
    private var hasFetchedRecords: Bool { fetchedHead < fetchedRecords.count }

    /// Drops the current record at once, then moves the head; the array is emptied when the head reaches its end, or
    /// compacted when the dropped half is at least 64 records, so it stays within twice the records held and each
    /// record is moved at most once per compaction.
    private func dropFirstFetchedRecord() {
        fetchedRecords[fetchedHead] = SQLiteIDBStoreCursorRecord()
        fetchedHead += 1
        if fetchedHead == fetchedRecords.count {
            fetchedRecords.removeAll(keepingCapacity: true)
            fetchedHead = 0
        } else if fetchedHead >= 64 && fetchedHead &* 2 >= fetchedRecords.count {
            fetchedRecords.removeFirst(fetchedHead)
            fetchedHead = 0
        }
    }

    /// The array keeps its buffer: a cursor whose object store changes under it fetches again at once.
    private func removeAllFetchedRecords() {
        fetchedRecords.removeAll(keepingCapacity: true)
        fetchedHead = 0
    }

    private func fetchedRecordSize(_ index: Int) -> Int {
        fetchedRecords[index].size
    }

    var currentKey: WebCore.IDBKeyData { fetchedRecords[fetchedHead].cursorRecord.key }
    var currentPrimaryKey: WebCore.IDBKeyData { fetchedRecords[fetchedHead].cursorRecord.primaryKey }
    var currentValue: WebCore.IDBValue { fetchedRecords[fetchedHead].cursorRecord.value }
    var currentRecordRowID: Int64 { fetchedRecords[fetchedHead].rowID }
    var didComplete: Bool { fetchedRecords[fetchedHead].completed }
    var didError: Bool { fetchedRecords[fetchedHead].errored }

    /// Moves the current record's primary key and value into `result`; the key is copied because advance(1) reads the
    /// last fetched record's key.
    func addCurrentRecord(to result: inout WebCore.IDBGetAllResult, _ type: WebCore.IndexedDB.GetAllType) {
        let head = fetchedHead
        switch type {
        case .Keys:
            WebCore.sqliteIDBGetAllResultTakeKey(&result, &fetchedRecords[head].cursorRecord.primaryKey)
        case .Values:
            WebCore.sqliteIDBGetAllResultTakeKey(&result, &fetchedRecords[head].cursorRecord.primaryKey)
            WebCore.sqliteIDBGetAllResultTakeValue(&result, &fetchedRecords[head].cursorRecord.value)
        case .Records:
            var key = fetchedRecords[head].cursorRecord.key
            WebCore.sqliteIDBGetAllResultTakeKey(&result, &key)
            WebCore.sqliteIDBGetAllResultTakePrimaryKey(&result, &fetchedRecords[head].cursorRecord.primaryKey)
            WebCore.sqliteIDBGetAllResultTakeValue(&result, &fetchedRecords[head].cursorRecord.value)
        @unknown default:
            break
        }
    }

    func currentData(_ databaseInfo: inout WebCore.IDBDatabaseInfo, includePrefetchedRecords: Bool) -> WebCore.IDBGetResult {
        let head = fetchedHead
        if fetchedRecords[head].completed {
            return WebCore.makeEmptyIDBGetResult()
        }
        if !includePrefetchedRecords {
            var noPrefetchedRecords = WebCore.makeSQLiteIDBCursorRecords(0)
            return WebCore.makeSQLiteIDBGetResultFromCursorRecord(
                &fetchedRecords[head].cursorRecord,
                &databaseInfo,
                WebCore.makeSQLiteIDBObjectStoreIdentifier(objectStoreID),
                &noPrefetchedRecords
            )
        }
        var prefetchedRecords = WebCore.makeSQLiteIDBCursorRecords(fetchedCount - 1)
        var i = head + 1
        while i < fetchedRecords.count {
            if fetchedRecords[i].isTerminalRecord {
                break
            }
            WebCore.sqliteIDBAppendCursorRecordInPlace(&prefetchedRecords, &fetchedRecords[i].cursorRecord)
            i += 1
        }
        return WebCore.makeSQLiteIDBGetResultFromCursorRecord(
            &fetchedRecords[head].cursorRecord,
            &databaseInfo,
            WebCore.makeSQLiteIDBObjectStoreIdentifier(objectStoreID),
            &prefetchedRecords
        )
    }

    // MARK: Statements

    private static func preIndexStatementText(_ isDirectionNext: Bool) -> Swift.String {
        "SELECT rowid, key, value FROM IndexRecords WHERE indexID = ? AND key = CAST(? AS TEXT) AND value "
            + (isDirectionNext ? ">" : "<") + " CAST(? AS TEXT) ORDER BY value" + (isDirectionNext ? "" : " DESC") + ";"
    }

    private static func rangeText(_ keyRange: WebCore.IDBKeyRangeData) -> Swift.String {
        (!keyRange.lowerKey.isNull() && !keyRange.lowerOpen ? ">=" : ">") + " CAST(? AS TEXT) AND key "
            + (!keyRange.upperKey.isNull() && !keyRange.upperOpen ? "<=" : "<") + " CAST(? AS TEXT) ORDER BY key"
    }

    private func indexStatementText() -> Swift.String {
        "SELECT rowid, key, value FROM IndexRecords WHERE indexID = ? AND key " + SQLiteIDBStoreCursor.rangeText(keyRange)
            + (cursorDirection == .Prev || cursorDirection == .Prevunique ? " DESC" : "") + ", value"
            + (cursorDirection == .Prev ? " DESC" : "") + ";"
    }

    private func objectStoreStatementText() -> Swift.String {
        "SELECT rowid, key, value FROM Records WHERE objectStoreID = ? AND key " + SQLiteIDBStoreCursor.rangeText(keyRange)
            + (cursorDirection == .Prev || cursorDirection == .Prevunique ? " DESC" : "") + ";"
    }

    private func establishStatement() -> Bool {
        let text: Swift.String
        if let indexID {
            text = indexStatementText()
            boundID = indexID
        } else {
            text = objectStoreStatementText()
            boundID = objectStoreID
        }
        currentLowerKey = keyRange.lowerKey.isNull() ? WebCore.IDBKeyData.minimum() : keyRange.lowerKey
        currentUpperKey = keyRange.upperKey.isNull() ? WebCore.IDBKeyData.maximum() : keyRange.upperKey
        return createSQLiteStatement(text)
    }

    private func createSQLiteStatement(_ text: Swift.String) -> Bool {
        guard let database = store.currentDatabase() else {
            WTFCrash()
        }
        let owner = database.prepareStatementForString(sqliteIDBString(text))
        if owner.get() == nil {
            return false
        }
        statements.main = consume owner
        return bindArguments()
    }

    func objectStoreRecordsChanged() {
        if statementNeedsReset {
            return
        }
        currentKeyForUniqueness = fetchedRecords[fetchedHead].cursorRecord.key
        if indexID != nil {
            currentIndexRecordValue = fetchedRecords[fetchedHead].cursorRecord.primaryKey
        }
        // The statement is reset and bound again to pick up the changes.
        statementNeedsReset = true
        if isDirectionNext {
            currentLowerKey = currentKeyForUniqueness
            if !keyRange.lowerOpen {
                keyRange.lowerOpen = true
                keyRange.lowerKey = currentLowerKey
                statements.main = nil
            }
        } else {
            currentUpperKey = currentKeyForUniqueness
            if !keyRange.upperOpen {
                keyRange.upperOpen = true
                keyRange.upperKey = currentUpperKey
                statements.main = nil
            }
        }
        // The fetched records may no longer be valid.
        removeAllFetchedRecords()
        fetchedRecordsSize = 0
        prefetchCount = 0
    }

    private func resetAndRebindStatement() {
        statementNeedsReset = false
        if statements.main == nil && !establishStatement() {
            return
        }
        guard let current = statements.main?.get() else {
            WTFCrash()
        }
        if current.reset() != sqliteIDBResultOK {
            return
        }
        _ = bindArguments()
    }

    private func bindArguments() -> Bool {
        guard let current = statements.main?.get() else {
            WTFCrash()
        }
        if current.bindInt64(1, Int64(bitPattern: boundID)) != sqliteIDBResultOK {
            return false
        }
        if WebCore.sqliteIDBBindBytes(current, 2, serializeIDBKeyDataBytes(currentLowerKey)) != sqliteIDBResultOK {
            return false
        }
        if WebCore.sqliteIDBBindBytes(current, 3, serializeIDBKeyDataBytes(currentUpperKey)) != sqliteIDBResultOK {
            return false
        }
        return true
    }

    private func resetAndRebindPreIndexStatementIfNecessary() -> Bool {
        if indexID == nil {
            return true
        }
        if currentIndexRecordValue.isNull() {
            return true
        }
        if statements.preIndex == nil {
            guard let database = store.currentDatabase() else {
                WTFCrash()
            }
            let owner = database.prepareStatementForString(
                sqliteIDBString(SQLiteIDBStoreCursor.preIndexStatementText(isDirectionNext))
            )
            if owner.get() == nil {
                return false
            }
            statements.preIndex = consume owner
        }
        guard let preIndex = statements.preIndex?.get() else {
            WTFCrash()
        }
        if preIndex.reset() != sqliteIDBResultOK {
            return false
        }
        let key = isDirectionNext ? currentLowerKey : currentUpperKey
        if preIndex.bindInt64(1, Int64(bitPattern: boundID)) != sqliteIDBResultOK {
            return false
        }
        if WebCore.sqliteIDBBindBytes(preIndex, 2, serializeIDBKeyDataBytes(key)) != sqliteIDBResultOK {
            return false
        }
        if WebCore.sqliteIDBBindBytes(preIndex, 3, serializeIDBKeyDataBytes(currentIndexRecordValue)) != sqliteIDBResultOK {
            return false
        }
        return true
    }

    // MARK: Fetching

    func prefetchOneRecord() -> Bool {
        if fetchedRecordsSize >= sqliteIDBPrefetchSizeLimit || !hasFetchedRecords || fetchedCount >= sqliteIDBPrefetchLimit
            || fetchedRecords[fetchedRecords.count - 1].isTerminalRecord
        {
            return false
        }
        currentKeyForUniqueness = fetchedRecords[fetchedRecords.count - 1].cursorRecord.key
        return fetch() && fetchedCount < sqliteIDBPrefetchLimit && fetchedRecordsSize < sqliteIDBPrefetchSizeLimit
    }

    private func increaseCountToPrefetch() {
        // The count doubles from 1 and prefetching stops at 256 records, so it cannot overflow; `&*` is only to
        // not trap.
        prefetchCount = prefetchCount != 0 ? prefetchCount &* 2 : 1
    }

    func prefetch() -> Bool {
        var i: UInt32 = 0
        while i < prefetchCount {
            if !prefetchOneRecord() {
                return false
            }
            i += 1
        }
        increaseCountToPrefetch()
        return true
    }

    func advance(_ requestedCount: UInt64) -> Bool {
        var count = requestedCount
        if hasFetchedRecords && fetchedRecords[fetchedHead].isTerminalRecord {
            return false
        }
        if hasFetchedRecords {
            currentKeyForUniqueness = fetchedRecords[fetchedRecords.count - 1].cursorRecord.key
        }

        // Already fetched records count first.
        let hadCurrentRecord = hasFetchedRecords
        while count != 0 && hasFetchedRecords {
            if fetchedRecords[fetchedHead].isTerminalRecord {
                break
            }
            fetchedRecordsSize &-= fetchedRecordSize(fetchedHead)
            dropFirstFetchedRecord()
            count -= 1
        }
        if hasFetchedRecords {
            return true
        }

        // Removing the current record used up one count; give it back.
        if hadCurrentRecord {
            // count <= requestedCount - 1 here, since the current record was removed.
            count += 1
        }

        while count != 0 {
            if hasFetchedRecords {
                currentKeyForUniqueness = fetchedRecords[fetchedHead].cursorRecord.key
                fetchedRecordsSize &-= fetchedRecordSize(fetchedHead)
                dropFirstFetchedRecord()
            }
            if !fetch() {
                return false
            }
            if fetchedRecords[fetchedHead].completed {
                break
            }
            count -= 1
        }
        return true
    }

    private func fetch() -> Bool {
        var record = SQLiteIDBStoreCursorRecord()
        let fetchSucceeded = fetchUnique(&record)
        if fetchSucceeded {
            fetchedRecordsSize &+= record.size
        }
        fetchedRecords.append(record)
        return fetchSucceeded
    }

    private func fetchUnique(_ record: inout SQLiteIDBStoreCursorRecord) -> Bool {
        let isUnique = cursorDirection == .Nextunique || cursorDirection == .Prevunique
        if !isUnique {
            return fetchNextRecord(&record)
        }
        while fetchNextRecord(&record) {
            if record.completed {
                return true
            }
            if !WebCore.sqliteIDBKeyDataEqualInPlace(&currentKeyForUniqueness, &record.cursorRecord.key) {
                return true
            }
        }
        return false
    }

    private func fetchNextRecord(_ record: inout SQLiteIDBStoreCursorRecord) -> Bool {
        if statementNeedsReset {
            _ = resetAndRebindPreIndexStatementIfNecessary()
            resetAndRebindStatement()
        }
        let store = self.store
        var result = SQLiteIDBFetchResult.shouldFetchAgain
        while result == .shouldFetchAgain {
            result = internalFetchNextRecord(&record, &statements, store)
        }
        record.measure()
        return result == .success
    }

    @inline(never)
    private static func markAsErrored(_ record: inout SQLiteIDBStoreCursorRecord) {
        record = SQLiteIDBStoreCursorRecord()
        record.completed = true
        record.errored = true
    }

    private func internalFetchNextRecord(
        _ record: inout SQLiteIDBStoreCursorRecord,
        _ statements: inout SQLiteIDBStoreCursorStatements,
        _ store: SQLiteIDBStore
    ) -> SQLiteIDBFetchResult {
        record.cursorRecord.value = WebCore.IDBValue()

        var current: WebCore.SQLiteStatement? = nil
        if let preIndex = statements.preIndex?.get() {
            if preIndex.step() == sqliteIDBResultRow {
                current = preIndex
            }
        }
        if current == nil {
            guard let main = statements.main?.get() else {
                WTFCrash()
            }
            let result = main.step()
            if result == sqliteIDBResultDone {
                record = SQLiteIDBStoreCursorRecord()
                record.completed = true
                return .success
            }
            if result != sqliteIDBResultRow {
                SQLiteIDBStoreCursor.markAsErrored(&record)
                return .failure
            }
            current = main
        }
        guard let row = current else {
            WTFCrash()
        }

        record.rowID = row.columnInt64(0)
        if !WebCore.sqliteIDBColumnKey(row, 1, &record.cursorRecord.key) {
            SQLiteIDBStoreCursor.markAsErrored(&record)
            return .failure
        }
        let valueBytes = row.columnBlob(2)

        // An object store cursor's primary key is its key.
        if indexID == nil {
            record.cursorRecord.primaryKey = record.cursorRecord.key
            let (error, blobURLs, blobFilePaths) = store.getBlobRecordsForObjectStoreRecord(record.rowID)
            if !error.isNull() {
                SQLiteIDBStoreCursor.markAsErrored(&record)
                return .failure
            }
            if isKeyAndValue {
                let (valueError, value) = store.buildIDBValueForRecord(
                    record.rowID,
                    WebCore.sqliteIDBMakeBuffer(valueBytes),
                    blobURLs,
                    blobFilePaths
                )
                if !valueError.isNull() {
                    SQLiteIDBStoreCursor.markAsErrored(&record)
                    return .failure
                }
                record.cursorRecord.value = value
            }
            return .success
        }

        if !WebCore.sqliteIDBDeserializeKeyBytes(valueBytes, &record.cursorRecord.primaryKey) {
            SQLiteIDBStoreCursor.markAsErrored(&record)
            return .failure
        }

        if statements.cachedObjectStore?.get() == nil || statements.cachedObjectStore?.get()?.reset() != sqliteIDBResultOK {
            if let database = store.currentDatabase() {
                let owner = database.prepareStatementForString(
                    sqliteIDBString("SELECT rowid, value FROM Records WHERE key = CAST(? AS TEXT) and objectStoreID = ?;")
                )
                if owner.get() != nil {
                    statements.cachedObjectStore = consume owner
                }
            }
        }
        guard let objectStoreStatement = statements.cachedObjectStore?.get(),
            WebCore.sqliteIDBBindBytes(objectStoreStatement, 1, valueBytes) == sqliteIDBResultOK,
            objectStoreStatement.bindInt64(2, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
        else {
            SQLiteIDBStoreCursor.markAsErrored(&record)
            return .failure
        }
        let result = objectStoreStatement.step()
        if result == sqliteIDBResultRow {
            let recordsRowID = objectStoreStatement.columnInt64(0)
            let (error, blobURLs, blobFilePaths) = store.getBlobRecordsForObjectStoreRecord(recordsRowID)
            if !error.isNull() {
                SQLiteIDBStoreCursor.markAsErrored(&record)
                return .failure
            }
            let (valueError, value) = store.buildIDBValueForRecord(
                recordsRowID,
                WebCore.sqliteIDBColumnBuffer(objectStoreStatement, 1),
                blobURLs,
                blobFilePaths
            )
            if !valueError.isNull() {
                SQLiteIDBStoreCursor.markAsErrored(&record)
                return .failure
            }
            record.cursorRecord.value = value
            return .success
        }
        if result == sqliteIDBResultDone {
            // The record was removed from the object store: skip it.
            return .shouldFetchAgain
        }
        SQLiteIDBStoreCursor.markAsErrored(&record)
        return .failure
    }

    func iterate(_ targetKey: inout WebCore.IDBKeyData, _ targetPrimaryKey: inout WebCore.IDBKeyData) -> Bool {
        var result = advance(1)
        // Unreachable: advance leaves a record fetched, the next one or the terminal one. The C++ asserts it with security implication.
        if !hasFetchedRecords {
            WTFCrash()
        }

        // Iterating with no key is advancing one step.
        if targetKey.isNull() || !result {
            return result
        }

        while !fetchedRecords[fetchedHead].isTerminalRecord {
            if !result {
                return false
            }
            // The next key >= the target for a next cursor, <= for a previous one.
            if cursorDirection == .Next || cursorDirection == .Nextunique {
                if WebCore.sqliteIDBKeyDataCompareInPlace(&fetchedRecords[fetchedHead].cursorRecord.key, &targetKey) >= 0 {
                    break
                }
            } else if WebCore.sqliteIDBKeyDataCompareInPlace(&fetchedRecords[fetchedHead].cursorRecord.key, &targetKey) <= 0 {
                break
            }
            result = advance(1)
        }

        if targetPrimaryKey.isValid() {
            while !fetchedRecords[fetchedHead].isTerminalRecord
                && WebCore.sqliteIDBKeyDataEqualInPlace(&fetchedRecords[fetchedHead].cursorRecord.key, &targetKey)
            {
                if !result {
                    return false
                }
                if cursorDirection == .Next || cursorDirection == .Nextunique {
                    if WebCore.sqliteIDBKeyDataCompareInPlace(&fetchedRecords[fetchedHead].cursorRecord.primaryKey, &targetPrimaryKey) >= 0
                    {
                        break
                    }
                } else if WebCore.sqliteIDBKeyDataCompareInPlace(&fetchedRecords[fetchedHead].cursorRecord.primaryKey, &targetPrimaryKey)
                    <= 0
                {
                    break
                }
                result = advance(1)
            }
        }
        return result
    }
}
