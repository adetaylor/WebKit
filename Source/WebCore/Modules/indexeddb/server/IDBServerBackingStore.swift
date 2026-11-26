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
//

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// those operators take, so they are imported for the operator lookup to resolve (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBGetAllRecordsData
internal import WebCore_Private.Core.IDBGetAllResult
internal import WebCore_Private.Core.IDBGetRecordData
internal import WebCore_Private.Core.IDBGetResult
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBIterateCursorData
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IDBValue
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes

/// A database's backing store: the store in memory, or the SQLite store on disk or in memory.
enum IDBServerBackingStore {
    case memory(SwiftIDBStore)
    case sqlite(SQLiteIDBStore)
}

struct IDBObjectStoreRecord {
    let key: WebCore.IDBKeyData
    let value: WebCore.IDBValue
    let recordID: Int64?
}

enum IDBObjectStoreRecordOrError {
    case record(IDBObjectStoreRecord)
    case error(WebCore.IDBError)
}

// The IDBError the in-memory store returns for each failure.
extension WebCore.MemoryIDBStoreError {
    fileprivate var idbError: WebCore.IDBError {
        switch self {
        case .None:
            WebCore.makeIDBServerNoError()
        case .Constraint:
            WebCore.IDBError(.init(WebCore.ExceptionCode.ConstraintError), WTF.String())
        case .TransactionExists:
            backingStoreError(.InvalidStateError, "Backing store asked to create transaction it already has a record of")
        case .AbortUnknownTransaction:
            backingStoreError(.InvalidStateError, "Backing store asked to abort transaction it didn't have record of")
        case .CommitUnknownTransaction:
            backingStoreError(.InvalidStateError, "Backing store asked to commit transaction it didn't have record of")
        case .NoTransactionToDeleteFrom:
            backingStoreError(.UnknownError, "No backing store transaction found to delete from")
        case .NoObjectStore:
            backingStoreError(.UnknownError, "No backing store object store found")
        case .NoTransactionToPutRecord:
            backingStoreError(.UnknownError, "No backing store transaction found to put record")
        case .NoObjectStoreToPutRecord:
            backingStoreError(.UnknownError, "No backing store object store found to put record")
        case .NoTransactionToGetRecord:
            backingStoreError(.UnknownError, "No backing store transaction found to get record")
        case .NoTransactionToGetAllRecords:
            backingStoreError(.UnknownError, "No backing store transaction found to get all records")
        case .NoIndex:
            backingStoreError(.UnknownError, "No backing store index found")
        case .NoTransactionToGetCount:
            backingStoreError(.UnknownError, "No backing store transaction found to get count")
        case .KeyGeneratorOverflow:
            backingStoreError(.ConstraintError, "Cannot generate new key value over 2^53 for object store operation")
        case .NoTransactionToOpenCursor:
            backingStoreError(.UnknownError, "No backing store transaction found in which to open a cursor")
        case .CannotCreateObjectStoreCursor:
            backingStoreError(.UnknownError, "Could not create object store cursor in backing store")
        case .CannotCreateIndexCursor:
            backingStoreError(.UnknownError, "Could not create index cursor in backing store")
        case .NoTransactionToIterateCursor:
            backingStoreError(.UnknownError, "No backing store transaction found in which to iterate cursor")
        case .NoCursorToIterate:
            backingStoreError(.UnknownError, "No backing store cursor found in which to iterate cursor")
        case .DatabaseInfoInvalid:
            backingStoreError(.UnknownError, "Database info is invalid.")
        case .ObjectStoreNotInDatabaseInfo:
            backingStoreError(.ConstraintError, "Object store does not exist in database info.")
        case .NotVersionChange:
            backingStoreError(.UnknownError, "Transaction is not in version change mode.")
        case .ObjectStoreNotInBackingStore:
            backingStoreError(.ConstraintError, "Object store does not exist in backing store.")
        case .TransactionNotActive:
            backingStoreError(.UnknownError, "Transaction is not active.")
        case .TransactionStateInvalid:
            backingStoreError(.ConstraintError, "Transaction state is invalid.")
        case .IndexIdentifierExists:
            backingStoreError(.ConstraintError, "Index identifier already exists")
        case .IndexDoesNotExist:
            backingStoreError(.ConstraintError, "Index does not exist.")
        case .MissingIndexMetadata:
            backingStoreError(.InvalidStateError, "Missing index metadata")
        case .UniquenessViolation:
            backingStoreError(
                .ConstraintError,
                "Unable to store record in object store because it does not satisfy the uniqueness requirements of an index"
            )
        @unknown default:
            fatalError("A memory store error the server does not know")
        }
    }
}

private func backingStoreError(_ code: WebCore.ExceptionCode, _ message: Swift.String) -> WebCore.IDBError {
    WebCore.IDBError(.init(code), WTF.String(message))
}

extension IDBServerBackingStore {
    init(identifier: WebCore.IDBDatabaseIdentifier, kind: IDBBackingStoreKind) {
        let databaseName = WebCore.idbDatabaseIdentifierDatabaseName(identifier)
        switch kind {
        case .memory:
            self = .memory(SwiftIDBStore(databaseName: databaseName))
        case .sqliteMemory:
            self = .sqlite(SQLiteIDBStore(databaseName: databaseName, databaseDirectory: WTF.String(), isInMemory: true))
        case .sqlite(let databaseDirectory):
            self = .sqlite(SQLiteIDBStore(databaseName: databaseName, databaseDirectory: databaseDirectory, isInMemory: false))
        }
    }

    func getOrEstablishDatabaseInfo() -> (WebCore.IDBError, WebCore.IDBDatabaseInfo) {
        switch self {
        case .memory(let store):
            return (WebCore.makeIDBServerNoError(), store.establishDatabaseInfo())
        case .sqlite(let store):
            let error = store.establishDatabaseInfo()
            guard error.isNull() else {
                return (error, WebCore.IDBDatabaseInfo())
            }
            return (error, store.currentDatabaseInfo())
        }
    }

    func databaseVersion() -> UInt64 {
        switch self {
        case .memory(let store):
            store.databaseVersion()
        case .sqlite(let store):
            store.databaseVersion()
        }
    }

    func beginTransaction(_ info: WebCore.IDBTransactionInfo) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.beginTransaction(
                WebCore.idbTransactionInfoIdentifier(info),
                info.mode(),
                WebCore.idbTransactionInfoObjectStores(info)
            )
            .idbError
        case .sqlite(let store):
            store.beginTransaction(WebCore.idbTransactionInfoIdentifier(info), info.mode(), info.durability(), info.newVersion())
        }
    }

    func abortTransaction(_ transactionIdentifier: WebCore.IDBResourceIdentifier) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.abortTransaction(transactionIdentifier).idbError
        case .sqlite(let store):
            store.abortTransaction(transactionIdentifier)
        }
    }

    func commitTransaction(_ transactionIdentifier: WebCore.IDBResourceIdentifier) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.commitTransaction(transactionIdentifier).idbError
        case .sqlite(let store):
            store.commitTransaction(transactionIdentifier)
        }
    }

    func createObjectStore(_ transactionIdentifier: WebCore.IDBResourceIdentifier, _ info: WebCore.IDBObjectStoreInfo) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.createObjectStore(transactionIdentifier, info).idbError
        case .sqlite(let store):
            store.createObjectStore(transactionIdentifier, info)
        }
    }

    func deleteObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.deleteObjectStore(transactionIdentifier, objectStoreIdentifier).idbError
        case .sqlite(let store):
            store.deleteObjectStore(transactionIdentifier, objectStoreIdentifier)
        }
    }

    func renameObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        newName: WTF.String
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.renameObjectStore(transactionIdentifier, objectStoreIdentifier, newName).idbError
        case .sqlite(let store):
            store.renameObjectStore(transactionIdentifier, objectStoreIdentifier, newName)
        }
    }

    func clearObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.clearObjectStore(transactionIdentifier, objectStoreIdentifier).idbError
        case .sqlite(let store):
            store.clearObjectStore(transactionIdentifier, objectStoreIdentifier)
        }
    }

    func deleteIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier).idbError
        case .sqlite(let store):
            store.deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
        }
    }

    func renameIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        newName: WTF.String
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.renameIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier, newName).idbError
        case .sqlite(let store):
            store.renameIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier, newName)
        }
    }

    func keyExistsInObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ key: WebCore.IDBKeyData
    ) -> (WebCore.IDBError, Bool) {
        switch self {
        case .memory(let store):
            return (WebCore.makeIDBServerNoError(), store.keyExistsInObjectStore(objectStoreIdentifier, key))
        case .sqlite(let store):
            let error = store.keyExistsInObjectStore(transactionIdentifier, objectStoreIdentifier, key)
            return (error, store.takeKeyExists())
        }
    }

    func deleteRange(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ range: WebCore.IDBKeyRangeData
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.deleteRange(transactionIdentifier, objectStoreIdentifier, range).idbError
        case .sqlite(let store):
            store.deleteRange(transactionIdentifier, objectStoreIdentifier, range)
        }
    }

    func overwriteRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreInfo: WebCore.IDBObjectStoreInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ value: WebCore.IDBValue
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.overwriteRecord(
                transactionIdentifier,
                objectStoreInfo.identifier(),
                key,
                WebCore.idbIndexKeyMapEntries(indexKeys),
                WebCore.idbValueData(value)
            )
            .idbError
        case .sqlite(let store):
            store.overwriteRecord(transactionIdentifier, objectStoreInfo, key, WebCore.idbIndexKeyMapEntries(indexKeys), value)
        }
    }

    func getRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ range: WebCore.IDBKeyRangeData,
        _ type: WebCore.IDBGetRecordDataType
    ) -> (WebCore.IDBError, WebCore.IDBGetResult) {
        let isKeyAndValue = type == .KeyAndValue
        switch self {
        case .memory(let store):
            let error = store.getRecordError(transactionIdentifier, objectStoreIdentifier)
            guard error == .None else {
                return (error.idbError, WebCore.makeEmptyIDBGetResult())
            }
            return (WebCore.makeIDBServerNoError(), store.getRecord(objectStoreIdentifier, range, isKeyAndValue))
        case .sqlite(let store):
            let error = store.getRecord(transactionIdentifier, objectStoreIdentifier, range, isKeyAndValue)
            guard error.isNull() else {
                return (error, WebCore.makeEmptyIDBGetResult())
            }
            return (error, store.takeGetResult())
        }
    }

    func getAllRecords(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ data: WebCore.IDBGetAllRecordsData
    ) -> (WebCore.IDBError, WebCore.IDBGetAllResult) {
        let indexIdentifier = data.indexIdentifier.value
        let hasIndex = indexIdentifier != nil
        let indexNumber = indexIdentifier?.toUInt64() ?? 0
        let count = data.count.value ?? 0
        switch self {
        case .memory(let store):
            let error = store.getAllRecordsError(transactionIdentifier, data.objectStoreIdentifier, hasIndex, indexNumber)
            guard error == .None else {
                return (error.idbError, WebCore.IDBGetAllResult())
            }
            let result = store.getAllRecords(data.objectStoreIdentifier, hasIndex, indexNumber, data.keyRangeData, count, data.getAllType)
            return (WebCore.makeIDBServerNoError(), result)
        case .sqlite(let store):
            let error = store.getAllRecords(
                transactionIdentifier,
                data.objectStoreIdentifier,
                hasIndex,
                indexNumber,
                data.keyRangeData,
                count,
                data.getAllType,
                data.cursorDirection
            )
            // A failure leaves the result begun so far (type and key path), or an empty one.
            return (error, store.takeGetAllResult())
        }
    }

    func getIndexRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        _ type: WebCore.IndexedDB.IndexRecordType,
        _ range: WebCore.IDBKeyRangeData
    ) -> (WebCore.IDBError, WebCore.IDBGetResult) {
        let isKey = type == .Key
        switch self {
        case .memory(let store):
            let error = store.getRecordError(transactionIdentifier, objectStoreIdentifier)
            guard error == .None else {
                return (error.idbError, WebCore.makeEmptyIDBGetResult())
            }
            return (WebCore.makeIDBServerNoError(), store.getIndexRecord(objectStoreIdentifier, indexIdentifier, isKey, range))
        case .sqlite(let store):
            let error = store.getIndexRecord(transactionIdentifier, objectStoreIdentifier, indexIdentifier, isKey, range)
            guard error.isNull() else {
                return (error, WebCore.makeEmptyIDBGetResult())
            }
            return (error, store.takeGetResult())
        }
    }

    /// The count is 0 where the store wrote none.
    func getCount(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier?,
        _ range: WebCore.IDBKeyRangeData
    ) -> (WebCore.IDBError, UInt64) {
        let hasIndex = indexIdentifier != nil
        let indexNumber = indexIdentifier?.toUInt64() ?? 0
        switch self {
        case .memory(let store):
            var count: UInt64 = 0
            let error = store.getCount(transactionIdentifier, objectStoreIdentifier, hasIndex, indexNumber, range, &count)
            return (error.idbError, count)
        case .sqlite(let store):
            let error = store.getCount(transactionIdentifier, objectStoreIdentifier, hasIndex, indexNumber, range)
            return (error, store.countWritten() ? store.takeNumber() : 0)
        }
    }

    /// The key number is 0 where the store wrote none.
    func generateKeyNumber(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) -> (WebCore.IDBError, UInt64) {
        switch self {
        case .memory(let store):
            var keyNumber: UInt64 = 0
            let error = store.generateKeyNumber(objectStoreIdentifier, &keyNumber)
            return (error.idbError, keyNumber)
        case .sqlite(let store):
            let error = store.generateKeyNumberEntry(transactionIdentifier, objectStoreIdentifier)
            // The out-parameter is written once the number is generated, whether or not storing it then failed.
            return (error, store.countWritten() ? store.takeNumber() : 0)
        }
    }

    func revertGeneratedKeyNumber(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ keyNumber: UInt64
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.revertGeneratedKeyNumber(objectStoreIdentifier, keyNumber)
            return WebCore.makeIDBServerNoError()
        case .sqlite(let store):
            return store.revertGeneratedKeyNumber(transactionIdentifier, objectStoreIdentifier, keyNumber)
        }
    }

    func maybeUpdateKeyGeneratorNumber(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ newKeyNumber: Double
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.maybeUpdateKeyGeneratorNumber(objectStoreIdentifier, newKeyNumber)
            return WebCore.makeIDBServerNoError()
        case .sqlite(let store):
            return store.maybeUpdateKeyGeneratorNumber(transactionIdentifier, objectStoreIdentifier, newKeyNumber)
        }
    }

    func openCursor(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ info: WebCore.IDBCursorInfo
    ) -> (WebCore.IDBError, WebCore.IDBGetResult) {
        switch self {
        case .memory(let store):
            let error = store.openCursorError(transactionIdentifier, info)
            guard error == .None else {
                return (error.idbError, WebCore.makeEmptyIDBGetResult())
            }
            return (WebCore.makeIDBServerNoError(), store.takeCursorResult())
        case .sqlite(let store):
            let error = store.openCursor(transactionIdentifier, info)
            guard error.isNull() else {
                return (error, WebCore.makeEmptyIDBGetResult())
            }
            return (error, store.takeGetResult())
        }
    }

    func iterateCursor(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ cursorIdentifier: WebCore.IDBResourceIdentifier,
        _ data: WebCore.IDBIterateCursorData
    ) -> (WebCore.IDBError, WebCore.IDBGetResult) {
        switch self {
        case .memory(let store):
            let result = store.iterateCursor(transactionIdentifier, cursorIdentifier, data.keyData, data.primaryKeyData, data.count)
            let error = store.takeIterateCursorError()
            guard error == .None else {
                return (error.idbError, WebCore.makeEmptyIDBGetResult())
            }
            return (WebCore.makeIDBServerNoError(), result)
        case .sqlite(let store):
            let reply = data.option == .Reply
            let error = store.iterateCursor(transactionIdentifier, cursorIdentifier, data.keyData, data.primaryKeyData, data.count, reply)
            guard error.isNull() && reply else {
                return (error, WebCore.makeEmptyIDBGetResult())
            }
            return (error, store.takeGetResult())
        }
    }

    func addIndex(_ transactionIdentifier: WebCore.IDBResourceIdentifier, _ info: WebCore.IDBIndexInfo) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.addIndex(transactionIdentifier, info).idbError
        case .sqlite(let store):
            store.addIndex(transactionIdentifier, info)
        }
    }

    func revertAddIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier
    ) {
        switch self {
        case .memory(let store):
            store.revertAddIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
        case .sqlite(let store):
            store.revertAddIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
        }
    }

    func updateIndexRecordsWithIndexKey(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ info: WebCore.IDBIndexInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IndexKey,
        recordID: Int64?
    ) -> WebCore.IDBError {
        switch self {
        case .memory(let store):
            store.updateIndexRecordsWithIndexKey(transactionIdentifier, info, key, indexKey).idbError
        case .sqlite(let store):
            store.updateIndexRecordsWithIndexKey(transactionIdentifier, info, key, indexKey, recordID != nil, recordID ?? 0)
        }
    }

    func forEachObjectStoreRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ body: (IDBObjectStoreRecordOrError) -> Void
    ) {
        switch self {
        case .memory(let store):
            let error = store.forEachObjectStoreRecordError(transactionIdentifier, objectStoreIdentifier)
            guard error == .None else {
                body(.error(error.idbError))
                return
            }
            let keys = memoryIDBKeyArray(store.objectStoreRecordKeys(objectStoreIdentifier))
            let values = store.objectStoreRecordValues(objectStoreIdentifier)
            for (index, key) in keys.enumerated() {
                body(.record(IDBObjectStoreRecord(key: key, value: WebCore.idbValueAt(values, index), recordID: nil)))
            }
        case .sqlite(let store):
            let error = store.beginForEachObjectStoreRecord(transactionIdentifier, objectStoreIdentifier)
            guard error.isNull() else {
                body(.error(error))
                return
            }
            while store.forEachHasRecord() {
                body(.record(IDBObjectStoreRecord(key: store.forEachKey(), value: store.forEachValue(), recordID: store.forEachRowID())))
                if store.forEachAdvance() {
                    continue
                }
                store.endForEachObjectStoreRecord()
                body(.error(backingStoreError(.UnknownError, "Error advancing cursor when iterating object store records")))
                return
            }
            store.endForEachObjectStoreRecord()
        }
    }

    func infoForObjectStore(_ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier) -> WebCore.IDBObjectStoreInfo? {
        switch self {
        case .memory(let store):
            guard store.hasObjectStoreInfo(objectStoreIdentifier) else {
                return nil
            }
            return store.objectStoreInfo(objectStoreIdentifier)
        case .sqlite(let store):
            return store.objectStoreInfoIfPresent(objectStoreIdentifier)
        }
    }

    func deleteBackingStore() {
        if case .sqlite(let store) = self {
            store.deleteBackingStore()
        }
    }

    var supportsSimultaneousReadWriteTransactions: Bool {
        switch self {
        case .memory:
            true
        case .sqlite:
            false
        }
    }

    var isEphemeral: Bool {
        switch self {
        case .memory:
            true
        case .sqlite(let store):
            store.isInMemory
        }
    }

    var fullDatabasePath: WTF.String {
        switch self {
        case .memory:
            WTF.String()
        case .sqlite(let store):
            store.databasePath()
        }
    }

    func close() {
        if case .sqlite(let store) = self {
            store.close()
        }
    }

    func hasTransaction(_ identifier: WebCore.IDBResourceIdentifier) -> Bool {
        switch self {
        case .memory(let store):
            store.hasTransaction(identifier)
        case .sqlite(let store):
            store.hasTransaction(identifier)
        }
    }

    func handleLowMemoryWarning() {
        if case .sqlite(let store) = self {
            store.handleLowMemoryWarning()
        }
    }
}
