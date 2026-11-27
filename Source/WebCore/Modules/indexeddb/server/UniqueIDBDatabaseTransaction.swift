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
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.ClientOrigin
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBGetAllRecordsData
internal import WebCore_Private.Core.IDBGetRecordData
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBIterateCursorData
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyPath
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBRequestData
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBResultData
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IDBTransactionMode
internal import WebCore_Private.Core.IDBValue
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes
#if canImport(os)
import os

private let indexedDBLog = os.Logger(subsystem: "com.apple.WebKit", category: "IndexedDB")
#endif

/// A reference type, so reading a field out of the database's dictionary of transactions copies one reference, not the
/// whole record (its arrays, its identifiers and a version change's copy of the schema).
final class UniqueIDBDatabaseTransaction {
    /// The references to the transaction from its database, its connection and an open request; it is removed when
    /// none is left.
    struct Holders: OptionSet {
        let rawValue: UInt8
        static let connection = Holders(rawValue: 1 << 0)
        static let pending = Holders(rawValue: 1 << 1)
        static let inProgress = Holders(rawValue: 1 << 2)
        static let versionChange = Holders(rawValue: 1 << 3)
        static let openRequest = Holders(rawValue: 1 << 4)
    }

    let serial: IDBEntitySerial
    let info: WebCore.IDBTransactionInfo
    let originalDatabaseInfo: WebCore.IDBDatabaseInfo?
    let databaseConnection: WebCore.IDBDatabaseConnectionIdentifier
    var objectStoreIdentifiers: [WebCore.IDBObjectStoreIdentifier]?
    var suspensionAbortResult: WebCore.IDBError?
    // What C++'s `Vector<IDBError> m_requestResults` is read for: its size, and whether any result from an index on is an
    // error. The count and the index of the last error answer both, without keeping one IDBError per request.
    private(set) var requestResultsCount: UInt64 = 0
    private(set) var lastErrorResultIndex: UInt64?
    var pendingGenerateIndexKeyRequests: UInt64 = 0
    var createIndexRequestIdentifier: WebCore.IDBResourceIdentifier?
    var isFinishingOrFinished = false
    var holders: Holders

    init(
        serial: IDBEntitySerial,
        info: __owned WebCore.IDBTransactionInfo,
        originalDatabaseInfo: __owned WebCore.IDBDatabaseInfo?,
        databaseConnection: WebCore.IDBDatabaseConnectionIdentifier,
        holders: Holders
    ) {
        self.serial = serial
        self.info = info
        self.originalDatabaseInfo = originalDatabaseInfo
        self.databaseConnection = databaseConnection
        self.holders = holders
    }
}

extension UniqueIDBDatabaseTransaction {
    var isVersionChange: Bool {
        info.mode() == .Versionchange
    }

    var isReadOnly: Bool {
        info.mode() == .Readonly
    }

    var identifier: WebCore.IDBResourceIdentifier {
        WebCore.idbTransactionInfoIdentifier(info)
    }

    func shouldAbortDueToUnhandledRequestError(handledRequestResultsCount: UInt64) -> Bool {
        guard handledRequestResultsCount <= requestResultsCount else {
            #if canImport(os)
            indexedDBLog.error(
                "\(self.serial.value) - UniqueIDBDatabaseTransaction.shouldAbortDueToUnhandledRequestError: finished request count (\(handledRequestResultsCount)) is bigger than total request count \(self.requestResultsCount)"
            )
            #endif
            return false
        }

        guard let lastErrorResultIndex else {
            return false
        }
        return lastErrorResultIndex >= handledRequestResultsCount
    }

    func addOpenRequestResult(_ error: WebCore.IDBError) {
        addRequestResult(error)
    }

    /// Counts a request's result, and remembers its index if it is an error (C++ appends it to `m_requestResults`).
    func addRequestResult(_ error: WebCore.IDBError) {
        if !error.isNull() {
            lastErrorResultIndex = requestResultsCount
        }
        requestResultsCount += 1
    }

    func setSuspensionAbortResult(_ error: WebCore.IDBError) {
        suspensionAbortResult = error
    }

    /// The object stores the transaction's scope names, computed from the database's info on first use.
    ///
    /// The info is inout only because the C++ lookup takes it by reference; it is read, not copied or changed.
    func objectStoreIdentifiers(in info: inout WebCore.IDBDatabaseInfo) -> [WebCore.IDBObjectStoreIdentifier] {
        if let objectStoreIdentifiers, !objectStoreIdentifiers.isEmpty {
            return objectStoreIdentifiers
        }

        let scope = WebCore.idbTransactionInfoObjectStores(self.info)
        let objectStoreNames = info.objectStoreNames()
        var identifiers: [WebCore.IDBObjectStoreIdentifier] = []
        for i in 0..<WebCore.idbStringVectorSize(objectStoreNames) {
            let objectStoreName = WebCore.idbStringVectorAt(objectStoreNames, i)
            guard let objectStoreIdentifier = WebCore.idbDatabaseInfoObjectStoreIdentifierNamed(&info, objectStoreName).value else {
                assertionFailure()
                continue
            }

            if (0..<WebCore.idbStringVectorSize(scope))
                .contains(where: { WebCore.idbStringEqual(WebCore.idbStringVectorAt(scope, $0), objectStoreName) })
            {
                identifiers.append(objectStoreIdentifier)
            }
        }

        objectStoreIdentifiers = identifiers
        return identifiers
    }

    /// The request of the index creation in progress; nil when there is none.
    fileprivate var activeCreateIndexRequestIdentifier: WebCore.IDBResourceIdentifier? {
        guard let createIndexRequestIdentifier, !createIndexRequestIdentifier.isEmpty() else {
            return nil
        }
        return createIndexRequestIdentifier
    }

    fileprivate func isCreateIndexRequest(_ requestIdentifier: WebCore.IDBResourceIdentifier) -> Bool {
        guard let createIndexRequestIdentifier else {
            return requestIdentifier.isEmpty()
        }
        return createIndexRequestIdentifier == requestIdentifier
    }
}

extension UniqueIDBDatabase {
    /// The transaction's database connection, if both are still in this database.
    private func connection(ofTransaction serial: IDBEntitySerial) -> UniqueIDBDatabaseConnection? {
        guard let databaseConnection = transactions[serial]?.databaseConnection else {
            return nil
        }
        return connections[databaseConnection]
    }

    func abort(serial: IDBEntitySerial) {
        transactions[serial]?.isFinishingOrFinished = true
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        abortTransaction(serial: serial) { [reference = self.reference] error in
            guard let self = reference.database, self.transactions.keys.contains(serial) else {
                return
            }
            if self.connection(ofTransaction: serial) != nil {
                self.didAbortTransaction(serial: serial, error: error)
            }
        }
    }

    func abortWithoutCallback(serial: IDBEntitySerial) {
        transactions[serial]?.isFinishingOrFinished = true
        if let connection = connection(ofTransaction: serial) {
            abortTransactionWithoutCallback(connection: connection.identifier, serial: serial)
        }
    }

    func commit(serial: IDBEntitySerial, handledRequestResultsCount: UInt64) {
        transactions[serial]?.isFinishingOrFinished = true
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        commitTransaction(serial: serial, handledRequestResultsCount: handledRequestResultsCount) {
            [reference = self.reference] error in
            guard let self = reference.database, self.transactions.keys.contains(serial) else {
                return
            }

            if self.connection(ofTransaction: serial) != nil {
                self.didCommitTransaction(serial: serial, error: error)
            }
        }
    }

    func didActivateInBackingStore(serial: IDBEntitySerial, error: WebCore.IDBError) {
        guard let transactionIdentifier = transactions[serial]?.identifier, let connection = connection(ofTransaction: serial) else {
            return
        }
        connection.connectionToClient.didStartTransaction(transactionIdentifier, error: error)
    }

    func didCreateIndexAsync(serial: IDBEntitySerial, error: WebCore.IDBError) {
        guard let requestIdentifier = transactions[serial]?.createIndexRequestIdentifier.take(), !requestIdentifier.isEmpty() else {
            return
        }

        guard let connection = connection(ofTransaction: serial) else {
            return
        }

        let result =
            error.isNull()
            ? WebCore.IDBResultData.createIndexSuccess(requestIdentifier) : WebCore.IDBResultData.error(requestIdentifier, error)
        connection.connectionToClient.didCreateIndex(result)
    }

    func generateIndexKeyForRecord(
        serial: IDBEntitySerial,
        _ info: WebCore.IDBIndexInfo,
        keyPath: WebCore.IDBKeyPath?,
        _ key: WebCore.IDBKeyData,
        _ value: WebCore.IDBValue,
        recordID: Int64?
    ) -> Bool {
        guard let connection = connection(ofTransaction: serial),
            let requestIdentifier = transactions[serial]?.activeCreateIndexRequestIdentifier
        else {
            return false
        }

        transactions[serial]?.pendingGenerateIndexKeyRequests &+= 1
        connection.connectionToClient.generateIndexKeyForRecord(
            requestIdentifier,
            indexInfo: info,
            keyPath: keyPath,
            key: key,
            value: value,
            recordID: recordID
        )
        return true
    }

    func transactionDidGenerateIndexKeyForRecord(
        serial: IDBEntitySerial,
        createIndexRequestIdentifier: WebCore.IDBResourceIdentifier,
        _ info: WebCore.IDBIndexInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IndexKey,
        recordID: Int64?
    ) {
        guard let transaction = transactions[serial] else {
            return
        }
        assert(transaction.isVersionChange)

        if !transaction.isCreateIndexRequest(createIndexRequestIdentifier) {
            return
        }

        transactions[serial]?.pendingGenerateIndexKeyRequests &-= 1
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        didGenerateIndexKeyForRecord(serial: serial, info, key, indexKey, recordID: recordID)
    }
}

extension UniqueIDBDatabase {
    /// Records a request's result in the transaction, then returns the connection to report it to.
    ///
    /// Handlers other than createObjectStore, renameObjectStore, createIndex, deleteIndex and renameIndex also record
    /// their result; those five report through `connection(ofTransaction:)`.
    private func recordRequestResult(ofTransaction serial: IDBEntitySerial, _ error: WebCore.IDBError) -> UniqueIDBDatabaseConnection? {
        // One lookup of each record: the transaction is shared, so the result is added through the reference.
        guard let transaction = transactions[serial], let connection = connections[transaction.databaseConnection] else {
            return nil
        }
        transaction.addRequestResult(error)
        return connection
    }

    private var clientOrigin: WebCore.ClientOrigin {
        WebCore.idbDatabaseIdentifierOrigin(identifier)
    }

    func transactionCreateObjectStore(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ info: WebCore.IDBObjectStoreInfo
    ) {
        precondition(transactions[serial]?.isVersionChange == true)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        createObjectStore(serial: serial, info) { [reference = self.reference] error in
            guard let connection = reference.database?.connection(ofTransaction: serial) else {
                return
            }

            connection.connectionToClient.didCreateObjectStore(
                error.isNull() ? .createObjectStoreSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionDeleteObjectStore(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ objectStoreName: WTF.String
    ) {
        precondition(transactions[serial]?.isVersionChange == true)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        deleteObjectStore(serial: serial, objectStoreName) { [reference = self.reference] error in
            guard let connection = reference.database?.recordRequestResult(ofTransaction: serial, error) else {
                return
            }

            connection.connectionToClient.didDeleteObjectStore(
                error.isNull() ? .deleteObjectStoreSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionRenameObjectStore(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ newName: WTF.String
    ) {
        precondition(transactions[serial]?.isVersionChange == true)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        renameObjectStore(serial: serial, objectStoreIdentifier, newName: newName) {
            [reference = self.reference] error in
            guard let connection = reference.database?.connection(ofTransaction: serial) else {
                return
            }

            connection.connectionToClient.didRenameObjectStore(
                error.isNull() ? .renameObjectStoreSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionClearObjectStore(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        clearObjectStore(serial: serial, objectStoreIdentifier) { [reference = self.reference] error in
            guard let connection = reference.database?.recordRequestResult(ofTransaction: serial, error) else {
                return
            }

            connection.connectionToClient.didClearObjectStore(
                error.isNull() ? .clearObjectStoreSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionCreateIndex(serial: IDBEntitySerial, _ requestData: WebCore.IDBRequestData, _ info: WebCore.IDBIndexInfo) {
        guard let transaction = transactions[serial] else {
            return
        }
        assert(transaction.isVersionChange)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        if transaction.activeCreateIndexRequestIdentifier != nil {
            #if canImport(os)
            indexedDBLog.error(
                "\(serial.value) - UniqueIDBDatabaseTransaction.createIndex: ignored create index request since there is one in progress"
            )
            #endif
            return
        }

        transactions[serial]?.createIndexRequestIdentifier = requestData.requestIdentifier()
        createIndexAsync(serial: serial, info)
    }

    func transactionDeleteIndex(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexName: WTF.String
    ) {
        precondition(transactions[serial]?.isVersionChange == true)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        deleteIndex(serial: serial, objectStoreIdentifier, indexName: indexName) {
            [reference = self.reference] error in
            guard let connection = reference.database?.connection(ofTransaction: serial) else {
                return
            }

            connection.connectionToClient.didDeleteIndex(
                error.isNull() ? .deleteIndexSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionRenameIndex(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        _ newName: WTF.String
    ) {
        precondition(transactions[serial]?.isVersionChange == true)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        renameIndex(serial: serial, objectStoreIdentifier, indexIdentifier, newName: newName) {
            [reference = self.reference] error in
            guard let connection = reference.database?.connection(ofTransaction: serial) else {
                return
            }

            connection.connectionToClient.didRenameIndex(
                error.isNull() ? .renameIndexSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionPutOrAdd(
        serial: IDBEntitySerial,
        _ requestData: consuming WebCore.IDBRequestData,
        _ key: consuming WebCore.IDBKeyData,
        _ value: consuming WebCore.IDBValue,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        assert(transactions[serial]?.isReadOnly == false)
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        putOrAdd(serial: serial, requestData, key, value, indexKeys, overwriteMode)
    }

    /// Records a putOrAdd's result in the transaction and reports it to the transaction's connection.
    func reportPutOrAdd(
        ofTransaction serial: IDBEntitySerial,
        _ requestIdentifier: WebCore.IDBResourceIdentifier,
        _ error: WebCore.IDBError,
        _ key: WebCore.IDBKeyData
    ) {
        guard let connection = recordRequestResult(ofTransaction: serial, error) else {
            return
        }

        connection.connectionToClient.didPutOrAdd(
            error.isNull() ? .putOrAddSuccess(requestIdentifier, key) : .error(requestIdentifier, error)
        )
    }

    func transactionGetRecord(serial: IDBEntitySerial, _ requestData: WebCore.IDBRequestData, _ data: WebCore.IDBGetRecordData) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        getRecord(requestData, data) { [reference = self.reference] error, result in
            guard let self = reference.database,
                let connection = self.recordRequestResult(ofTransaction: serial, error)
            else {
                return
            }

            connection.connectionToClient.didGetRecord(
                error.isNull()
                    ? .getRecordSuccess(requestIdentifier, result, consuming: self.clientOrigin) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionGetAllRecords(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ data: WebCore.IDBGetAllRecordsData
    ) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        getAllRecords(requestData, data) { [reference = self.reference] error, result in
            guard let self = reference.database,
                let connection = self.recordRequestResult(ofTransaction: serial, error)
            else {
                return
            }

            connection.connectionToClient.didGetAllRecords(
                error.isNull()
                    ? .getAllRecordsSuccess(requestIdentifier, result, consuming: self.clientOrigin) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionGetCount(serial: IDBEntitySerial, _ requestData: WebCore.IDBRequestData, _ range: WebCore.IDBKeyRangeData) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        getCount(requestData, range) { [reference = self.reference] error, count in
            guard let connection = reference.database?.recordRequestResult(ofTransaction: serial, error) else {
                return
            }

            connection.connectionToClient.didGetCount(
                error.isNull() ? .getCountSuccess(requestIdentifier, count) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionDeleteRecord(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ range: WebCore.IDBKeyRangeData
    ) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        deleteRecord(requestData, range) { [reference = self.reference] error in
            guard let connection = reference.database?.recordRequestResult(ofTransaction: serial, error) else {
                return
            }

            connection.connectionToClient.didDeleteRecord(
                error.isNull() ? .deleteRecordSuccess(requestIdentifier) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionOpenCursor(serial: IDBEntitySerial, _ requestData: WebCore.IDBRequestData, _ info: WebCore.IDBCursorInfo) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        openCursor(requestData, info) { [reference = self.reference] error, result in
            guard let self = reference.database,
                let connection = self.recordRequestResult(ofTransaction: serial, error)
            else {
                return
            }

            connection.connectionToClient.didOpenCursor(
                error.isNull()
                    ? .openCursorSuccess(requestIdentifier, result, consuming: self.clientOrigin) : .error(requestIdentifier, error)
            )
        }
    }

    func transactionIterateCursor(
        serial: IDBEntitySerial,
        _ requestData: WebCore.IDBRequestData,
        _ data: WebCore.IDBIterateCursorData
    ) {
        guard connection(ofTransaction: serial) != nil else {
            return
        }

        let requestIdentifier = requestData.requestIdentifier()
        let option = data.option
        iterateCursor(requestData, data) { [reference = self.reference] error, result in
            if option == .DoNotReply {
                return
            }

            guard let self = reference.database,
                let connection = self.recordRequestResult(ofTransaction: serial, error)
            else {
                return
            }

            connection.connectionToClient.didIterateCursor(
                error.isNull()
                    ? .iterateCursorSuccess(requestIdentifier, result, consuming: self.clientOrigin) : .error(requestIdentifier, error)
            )
        }
    }
}
