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

// The IndexedDB memory backing store. SwiftIDBBackingStore holds one SwiftIDBStore by value, created and destroyed on
// the store's thread. The methods take their C++ arguments by value and return results; an error is a
// MemoryIDBStoreError the caller turns into an IDBError.
//
// Cursors hold positions (keys, and the index they were last found at with the store's generation), never iterators
// or pointers into a container, so a mutation the cursor is not told about can make it re-seek but not dangle.

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

extension WebCore.IDBIndexInfo {
    /// name(), copied (the getter returns `const String&`, which imports as a pointer).
    var copiedName: WTF.String { WebCore.idbIndexInfoName(self) }
}

extension WebCore.IDBObjectStoreInfo {
    /// name(), copied (the getter returns `const String&`, which imports as a pointer).
    var copiedName: WTF.String { WebCore.idbObjectStoreInfoName(self) }
}

// MARK: - Helpers

/// A WTF Vector of keys as a Swift array.
func memoryIDBKeyArray(_ vector: borrowing WebCore.IDBKeyDataVector) -> [WebCore.IDBKeyData] {
    let elements: Span<WebCore.IDBKeyData> = WebCore.idbKeyVectorElements(vector)
    var result: [WebCore.IDBKeyData] = []
    result.reserveCapacity(elements.count)
    for i in 0..<elements.count {
        result.append(elements[i])
    }
    return result
}

// MARK: - The store

@_expose(Cxx)
final class SwiftIDBStore {
    /// Everything the store holds: each entry makes one modify access to it.
    ///
    /// The state is a ~Copyable struct. The object stores, their indexes, the transactions and the cursors are ~Copyable structs or plain values inside it, found by
    /// identifier, never class references, so everything below the entry is statically checked and reference-count
    /// free. A deleted object store or index moves into its transaction, which keeps it until the transaction ends; a
    /// cursor on it finds it there.
    private var state: MemoryIDBDatabaseState

    @_expose(Cxx)
    init(databaseName: consuming WTF.String) {
        state = MemoryIDBDatabaseState(databaseName)
    }

    // MARK: Database info

    /// The info, created (name, version 0) on first use.
    @_expose(Cxx)
    func establishDatabaseInfo() -> WebCore.IDBDatabaseInfo {
        state.establishDatabaseInfo()
    }

    @_expose(Cxx)
    func databaseVersion() -> UInt64 {
        state.hasDatabaseInfo ? state.databaseInfo.version() : 0
    }

    /// Whether infoForObjectStore has an info to return.
    @_expose(Cxx)
    func hasObjectStoreInfo(_ identifier: consuming WebCore.IDBObjectStoreIdentifier) -> Bool {
        state.hasObjectStoreInfo(identifier)
    }

    /// A copy of the object store's info (hasObjectStoreInfo first).
    @_expose(Cxx)
    func objectStoreInfo(_ identifier: consuming WebCore.IDBObjectStoreIdentifier) -> WebCore.IDBObjectStoreInfo {
        WebCore.idbDatabaseInfoObjectStore(&state.databaseInfo, identifier)
    }

    // MARK: Transactions

    @_expose(Cxx)
    func hasTransaction(_ identifier: consuming WebCore.IDBResourceIdentifier) -> Bool {
        state.transactionIndex(identifier) != nil
    }

    /// Takes the transaction info's fields, not the info (its `consuming` form crashes this toolchain's move-only
    /// checker, and only these fields are read).
    @_expose(Cxx)
    func beginTransaction(
        _ identifier: consuming WebCore.IDBResourceIdentifier,
        _ mode: WebCore.IDBTransactionMode,
        _ objectStores: consuming WebCore.IDBTransactionObjectStoreNames
    ) -> WebCore.MemoryIDBStoreError {
        var names: [WTF.String] = []
        for i in 0..<WebCore.idbStringVectorSize(objectStores) {
            names.append(WebCore.idbStringVectorAt(objectStores, i))
        }
        return state.beginTransaction(identifier, mode == .Versionchange, mode != .Readonly, names)
    }

    @_expose(Cxx)
    func abortTransaction(_ identifier: consuming WebCore.IDBResourceIdentifier) -> WebCore.MemoryIDBStoreError {
        state.abortTransaction(identifier)
    }

    @_expose(Cxx)
    func commitTransaction(_ identifier: consuming WebCore.IDBResourceIdentifier) -> WebCore.MemoryIDBStoreError {
        state.commitTransaction(identifier)
    }

    // MARK: Schema

    // `__owned` IDB*Info parameters (here and in the SQLite store): `consuming` crashes the compiler's move-only checker.
    @_expose(Cxx)
    func createObjectStore(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ info: __owned WebCore.IDBObjectStoreInfo
    ) -> WebCore.MemoryIDBStoreError {
        state.createObjectStore(transactionIdentifier, info)
    }

    @_expose(Cxx)
    func deleteObjectStore(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        state.deleteObjectStore(transactionIdentifier, objectStoreIdentifier)
    }

    @_expose(Cxx)
    func renameObjectStore(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ newName: consuming WTF.String
    ) -> WebCore.MemoryIDBStoreError {
        state.renameObjectStore(transactionIdentifier, objectStoreIdentifier, newName)
    }

    @_expose(Cxx)
    func clearObjectStore(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        state.clearObjectStore(objectStoreIdentifier)
    }

    @_expose(Cxx)
    func deleteIndex(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        state.deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
    }

    @_expose(Cxx)
    func renameIndex(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier,
        _ newName: consuming WTF.String
    ) -> WebCore.MemoryIDBStoreError {
        state.renameIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier, newName)
    }

    @_expose(Cxx)
    func addIndex(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ indexInfo: __owned WebCore.IDBIndexInfo
    ) -> WebCore.MemoryIDBStoreError {
        state.addIndex(transactionIdentifier, indexInfo)
    }

    @_expose(Cxx)
    func revertAddIndex(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier
    ) {
        state.revertAddIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
    }

    @_expose(Cxx)
    func updateIndexRecordsWithIndexKey(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ indexInfo: __owned WebCore.IDBIndexInfo,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKey: consuming WebCore.IndexKey
    ) -> WebCore.MemoryIDBStoreError {
        state.updateIndexRecordsWithIndexKey(transactionIdentifier, indexInfo, key, indexKey)
    }

    // MARK: Records

    @_expose(Cxx)
    func keyExistsInObjectStore(
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ key: consuming WebCore.IDBKeyData
    ) -> Bool {
        guard let s = state.objectStoreSlot(objectStoreIdentifier.toUInt64()) else {
            WTFCrash()
        }
        return state.objectStores[s].containsRecord(key)
    }

    @_expose(Cxx)
    func deleteRange(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ range: consuming WebCore.IDBKeyRangeData
    ) -> WebCore.MemoryIDBStoreError {
        state.deleteRange(transactionIdentifier, objectStoreIdentifier.toUInt64(), range)
    }

    @_expose(Cxx)
    func overwriteRecord(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKeys: consuming WebCore.IDBIndexKeyMapEntries,
        _ value: consuming WebCore.ThreadSafeDataBuffer
    ) -> WebCore.MemoryIDBStoreError {
        state.overwriteRecord(transactionIdentifier, objectStoreIdentifier.toUInt64(), key, indexKeys, value)
    }

    /// The error, if any, getRecord and getIndexRecord return; then their result.
    @_expose(Cxx)
    func getRecordError(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        state.recordError(transactionIdentifier, objectStoreIdentifier.toUInt64(), .NoTransactionToGetRecord, .NoObjectStore)
    }

    @_expose(Cxx)
    func getRecord(
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ range: consuming WebCore.IDBKeyRangeData,
        _ keyAndValue: Bool
    ) -> WebCore.IDBGetResult {
        state.getRecord(objectStoreIdentifier.toUInt64(), range, keyAndValue)
    }

    @_expose(Cxx)
    func getAllRecordsError(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64
    ) -> WebCore.MemoryIDBStoreError {
        state.getAllRecordsError(transactionIdentifier, objectStoreIdentifier.toUInt64(), hasIndex, indexIdentifier)
    }

    /// getAllRecords' result (getAllRecordsError first). `count` 0 means no limit, as an absent one does.
    @_expose(Cxx)
    func getAllRecords(
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64,
        _ range: consuming WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType
    ) -> WebCore.IDBGetAllResult {
        state.getAllRecords(objectStoreIdentifier.toUInt64(), hasIndex, indexIdentifier, range, count, type)
    }

    @_expose(Cxx)
    func getIndexRecord(
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier,
        _ keyOnly: Bool,
        _ range: consuming WebCore.IDBKeyRangeData
    ) -> WebCore.IDBGetResult {
        state.getIndexRecord(objectStoreIdentifier.toUInt64(), indexIdentifier.toUInt64(), keyOnly, range)
    }

    @_expose(Cxx)
    func getCount(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64,
        _ range: consuming WebCore.IDBKeyRangeData,
        _ count: inout UInt64
    ) -> WebCore.MemoryIDBStoreError {
        state.getCount(transactionIdentifier, objectStoreIdentifier.toUInt64(), hasIndex, indexIdentifier, range, &count)
    }

    // MARK: Key generator

    /// The memory store's generator: `keyNumber` is written before the cap check, so also with the error.
    @_expose(Cxx)
    func generateKeyNumber(
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ keyNumber: inout UInt64
    ) -> WebCore.MemoryIDBStoreError {
        state.generateKeyNumber(objectStoreIdentifier.toUInt64(), &keyNumber)
    }

    @_expose(Cxx)
    func revertGeneratedKeyNumber(_ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier, _ keyNumber: UInt64) {
        state.revertGeneratedKeyNumber(objectStoreIdentifier.toUInt64(), keyNumber)
    }

    /// Caps at 2^53 + 1 once the new number reaches 2^53; otherwise the next integer above it.
    @_expose(Cxx)
    func maybeUpdateKeyGeneratorNumber(_ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier, _ newKeyNumber: Double) {
        state.maybeUpdateKeyGeneratorNumber(objectStoreIdentifier.toUInt64(), newKeyNumber)
    }

    // MARK: Cursors

    @_expose(Cxx)
    func openCursorError(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ info: consuming WebCore.IDBCursorInfo
    ) -> WebCore.MemoryIDBStoreError {
        state.openCursorError(transactionIdentifier, info)
    }

    @_expose(Cxx)
    func takeCursorResult() -> WebCore.IDBGetResult {
        // Moved out, not copied: a copy of the result copies its keys and value.
        var result = WebCore.makeEmptyIDBGetResult()
        swap(&result, &state.openedCursorResult)
        return result
    }

    @_expose(Cxx)
    func takeIterateCursorError() -> WebCore.MemoryIDBStoreError {
        state.iterateCursorError
    }

    /// The cursor's next result; the error, if any, is takeIterateCursorError's.
    @_expose(Cxx)
    func iterateCursor(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ cursorIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ key: consuming WebCore.IDBKeyData,
        _ primaryKey: consuming WebCore.IDBKeyData,
        _ count: UInt32
    ) -> WebCore.IDBGetResult {
        state.iterateCursor(transactionIdentifier, cursorIdentifier, key, primaryKey, count)
    }

    // MARK: forEachObjectStoreRecord

    @_expose(Cxx)
    func forEachObjectStoreRecordError(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.MemoryIDBStoreError {
        state.recordError(transactionIdentifier, objectStoreIdentifier.toUInt64(), .TransactionNotActive, .ObjectStoreNotInBackingStore)
    }

    @_expose(Cxx)
    func objectStoreRecordKeys(_ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier) -> WebCore.IDBKeyDataVector {
        state.objectStoreRecordKeys(objectStoreIdentifier.toUInt64())
    }

    @_expose(Cxx)
    func objectStoreRecordValues(_ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier) -> WebCore.ThreadSafeDataBufferVector
    {
        state.objectStoreRecordValues(objectStoreIdentifier.toUInt64())
    }
}
