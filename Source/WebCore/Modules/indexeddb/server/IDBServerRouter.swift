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
internal import WebCore_Private.Core.ClientOrigin
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.IDBConnectionToClientDelegate
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
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

/// Finds the connections to clients, the database connections and the transactions that IPC and C++ callers name by
/// identifier, and holds the databases of the last two weakly so that a stale identifier finds nothing instead of keeping a
/// database alive. `policy` says what registering an identifier twice does: the in-process server overwrites, the network process keeps the first.
@_spi(IDBServer)
public final class IDBServerRouter {
    let policy: IDBRegistrationPolicy
    var connectionsToClient: IDBIdentifierDictionary<WebCore.IDBConnectionIdentifier, IDBConnectionToClient> = [:]
    var databaseConnections: IDBIdentifierDictionary<WebCore.IDBDatabaseConnectionIdentifier, IDBDatabaseLivenessReference> = [:]
    var transactions: [WebCore.IDBResourceIdentifier: IDBTransactionLivenessReference] = [:]

    /// Creates a router with no connections, which handles a second registration of an identifier as `policy` says.
    public init(policy: IDBRegistrationPolicy) {
        self.policy = policy
    }
}

extension IDBServerRouter {
    /// Makes the connection to the client the delegate names, and keeps it until the client goes away.
    @discardableResult
    public func addConnectionToClient(delegate: WebCore.IDBServer.IDBConnectionToClientDelegate) -> IDBConnectionToClient {
        // A delegate registered with the server always has an identifier.
        guard let identifier = delegate.identifier().value else {
            fatalError("A connection to a client registered without an identifier")
        }
        let connection = IDBConnectionToClient(identifier: identifier, delegate: delegate)
        assert(connectionsToClient[identifier] == nil)
        connectionsToClient[identifier] = connection
        return connection
    }

    /// The connection to the client with this identifier, unless the client went away or was never added.
    public func connectionToClient(_ identifier: WebCore.IDBConnectionIdentifier) -> IDBConnectionToClient? {
        connectionsToClient[identifier]
    }

    /// The client went away: closes each of its database connections.
    public func connectionToClientClosed(_ identifier: WebCore.IDBConnectionIdentifier) {
        guard let connection = connectionsToClient[identifier] else {
            return
        }
        connection.isClosed = true
        for databaseConnection in connection.databaseConnections {
            assert(connection.databaseConnections.contains(databaseConnection))
            self.databaseConnection(databaseConnection)?.connectionClosedFromClient()
        }
        assert(connection.databaseConnections.isEmpty)
    }

    /// Records whether the client is suspended, and when that changes, lets each database the client has connections to
    /// settle the transactions of suspended clients.
    public func setClientSuspended(_ identifier: WebCore.IDBConnectionIdentifier, _ isSuspended: Bool) {
        guard let connection = connectionsToClient[identifier], connection.isClientSuspended != isSuspended else {
            return
        }
        connection.isClientSuspended = isSuspended

        var databases: [UniqueIDBDatabase] = []
        for databaseConnection in connection.databaseConnections {
            guard let database = databaseConnections[databaseConnection]?.database else {
                continue
            }
            if !databases.contains(where: { $0 === database }) {
                databases.append(database)
            }
        }
        for database in databases {
            database.handleTransactionsAfterAbortingSuspendedClientTransactions()
        }
    }

    /// Closes the connection to the client, drops its delegate and forgets it, in that order.
    public func removeConnectionToClient(_ identifier: WebCore.IDBConnectionIdentifier) {
        assert(connectionsToClient[identifier] != nil)
        connectionToClientClosed(identifier)
        connectionsToClient[identifier]?.clearDelegate()
        connectionsToClient[identifier] = nil
    }

    func registerConnection(_ identifier: WebCore.IDBDatabaseConnectionIdentifier, database: UniqueIDBDatabase) {
        assert(databaseConnections[identifier] == nil)
        if policy == .keepFirst, databaseConnections[identifier] != nil {
            return
        }
        databaseConnections[identifier] = IDBDatabaseLivenessReference(database: database)
    }

    func unregisterConnection(_ identifier: WebCore.IDBDatabaseConnectionIdentifier) {
        assert(databaseConnections[identifier] != nil)
        databaseConnections[identifier] = nil
    }

    func registerTransaction(_ identifier: WebCore.IDBResourceIdentifier, database: UniqueIDBDatabase, serial: IDBEntitySerial) {
        assert(transactions[identifier] == nil)
        if policy == .keepFirst, transactions[identifier] != nil {
            return
        }
        transactions[identifier] = IDBTransactionLivenessReference(database: database, serial: serial)
    }

    func unregisterTransaction(_ identifier: WebCore.IDBResourceIdentifier) {
        assert(transactions[identifier] != nil)
        transactions[identifier] = nil
    }

    /// The transaction with this identifier, if its database still holds it.
    public func transaction(_ identifier: WebCore.IDBResourceIdentifier) -> IDBTransactionHandle? {
        guard let entry = transactions[identifier], let database = entry.database, database.transactions.keys.contains(entry.serial) else {
            return nil
        }
        return IDBTransactionHandle(database: database, serial: entry.serial, identifier: identifier)
    }

    /// The database connection with this identifier, if its database still holds it.
    public func databaseConnection(_ identifier: WebCore.IDBDatabaseConnectionIdentifier) -> IDBDatabaseConnectionHandle? {
        guard let database = databaseConnections[identifier]?.database, database.connections[identifier] != nil else {
            return nil
        }
        return IDBDatabaseConnectionHandle(database: database, identifier: identifier)
    }
}

/// A transaction named by a client, for the routing entries: every member looks the transaction up first and does
/// nothing if its database no longer holds it.
@_spi(IDBServer)
extension IDBServerRouter {
    /// The database the router has for a transaction, and the transaction's serial in it, for a request that runs
    /// at once: the database's own lookup of the transaction (its connection) then decides, where a handle would check
    /// that the database still holds it twice more first.
    private func databaseAndSerial(ofTransaction identifier: WebCore.IDBResourceIdentifier) -> (UniqueIDBDatabase, IDBEntitySerial)? {
        guard let entry = transactions[identifier], let database = entry.database else {
            return nil
        }
        return (database, entry.serial)
    }

    /// The transaction's putOrAdd, if its database still holds it.
    ///
    /// The entry points call this directly rather than through a transaction handle, which would take one more lookup per
    /// request.
    func putOrAdd(
        transaction identifier: WebCore.IDBResourceIdentifier,
        _ requestData: consuming WebCore.IDBRequestData,
        _ key: consuming WebCore.IDBKeyData,
        _ value: consuming WebCore.IDBValue,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        guard let (database, serial) = databaseAndSerial(ofTransaction: identifier) else {
            return
        }
        database.transactionPutOrAdd(serial: serial, requestData, key, value, indexKeys, overwriteMode)
    }

    /// The transaction's getRecord, if its database still holds it, called directly as putOrAdd is.
    func getRecord(
        transaction identifier: WebCore.IDBResourceIdentifier,
        _ requestData: consuming WebCore.IDBRequestData,
        _ data: consuming WebCore.IDBGetRecordData
    ) {
        guard let (database, serial) = databaseAndSerial(ofTransaction: identifier) else {
            return
        }
        database.transactionGetRecord(serial: serial, requestData, data)
    }
}

/// A transaction as a caller outside its database names it: the database, held weakly, and the transaction's serial in it.
///
/// Every operation re-checks that the database still holds the transaction, so a request that arrives after the transaction
/// finished is dropped instead of reaching a freed one.
public struct IDBTransactionHandle {
    let reference: IDBDatabaseReference
    var database: UniqueIDBDatabase? {
        reference.database
    }
    let serial: IDBEntitySerial
    /// The transaction's identifier, which the client chose.
    public let identifier: WebCore.IDBResourceIdentifier

    init(database: UniqueIDBDatabase, serial: IDBEntitySerial, identifier: WebCore.IDBResourceIdentifier) {
        reference = database.reference
        self.serial = serial
        self.identifier = identifier
    }

    /// The database holding the transaction, or nil if either is gone.
    private var holdingDatabase: UniqueIDBDatabase? {
        guard let database, database.transactions.keys.contains(serial) else {
            return nil
        }
        return database
    }

    /// The client of the transaction's database connection, or nil if the transaction or its connection is gone.
    public var connectionToClientIdentifier: WebCore.IDBConnectionIdentifier? {
        guard let database = holdingDatabase, let databaseConnection = database.transactions[serial]?.databaseConnection else {
            return nil
        }
        return database.connections[databaseConnection]?.connectionToClient.identifier
    }

    /// The identifier of the transaction's database, or nil if the transaction or its connection is gone.
    public func databaseIdentifier() -> WebCore.IDBDatabaseIdentifier? {
        guard let database = holdingDatabase, let databaseConnection = database.transactions[serial]?.databaseConnection,
            database.connections[databaseConnection] != nil
        else {
            return nil
        }
        return database.identifier
    }

    /// Whether the transaction is its database's version change one; false once it is gone.
    public var isVersionChange: Bool {
        holdingDatabase?.transactions[serial]?.isVersionChange == true
    }

    /// Runs the client's createObjectStore request in the transaction.
    public func createObjectStore(_ requestData: WebCore.IDBRequestData, _ info: WebCore.IDBObjectStoreInfo) {
        holdingDatabase?.transactionCreateObjectStore(serial: serial, requestData, info)
    }

    /// Runs the client's deleteObjectStore request in the transaction.
    public func deleteObjectStore(_ requestData: consuming WebCore.IDBRequestData, _ objectStoreName: consuming WTF.String) {
        holdingDatabase?.transactionDeleteObjectStore(serial: serial, requestData, objectStoreName)
    }

    /// Runs the client's renameObjectStore request in the transaction.
    public func renameObjectStore(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ newName: consuming WTF.String
    ) {
        holdingDatabase?.transactionRenameObjectStore(serial: serial, requestData, objectStoreIdentifier, newName)
    }

    /// Runs the client's clearObjectStore request in the transaction.
    public func clearObjectStore(_ requestData: consuming WebCore.IDBRequestData, _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier)
    {
        holdingDatabase?.transactionClearObjectStore(serial: serial, requestData, objectStoreIdentifier)
    }

    /// Runs the client's createIndex request in the transaction.
    public func createIndex(_ requestData: consuming WebCore.IDBRequestData, _ info: consuming WebCore.IDBIndexInfo) {
        holdingDatabase?.transactionCreateIndex(serial: serial, requestData, info)
    }

    /// Runs the client's deleteIndex request in the transaction.
    public func deleteIndex(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexName: consuming WTF.String
    ) {
        holdingDatabase?.transactionDeleteIndex(serial: serial, requestData, objectStoreIdentifier, indexName)
    }

    /// Runs the client's renameIndex request in the transaction.
    public func renameIndex(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        _ newName: consuming WTF.String
    ) {
        holdingDatabase?.transactionRenameIndex(serial: serial, requestData, objectStoreIdentifier, indexIdentifier, newName)
    }

    /// Runs the client's putOrAdd request in the transaction.
    public func putOrAdd(
        _ requestData: consuming WebCore.IDBRequestData,
        _ key: consuming WebCore.IDBKeyData,
        _ value: consuming WebCore.IDBValue,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        holdingDatabase?.transactionPutOrAdd(serial: serial, requestData, key, value, indexKeys, overwriteMode)
    }

    /// Runs the client's getRecord request in the transaction.
    public func getRecord(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBGetRecordData) {
        holdingDatabase?.transactionGetRecord(serial: serial, requestData, data)
    }

    /// Runs the client's getAllRecords request in the transaction.
    public func getAllRecords(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBGetAllRecordsData) {
        holdingDatabase?.transactionGetAllRecords(serial: serial, requestData, data)
    }

    /// Runs the client's getCount request in the transaction.
    public func getCount(_ requestData: consuming WebCore.IDBRequestData, _ range: consuming WebCore.IDBKeyRangeData) {
        holdingDatabase?.transactionGetCount(serial: serial, requestData, range)
    }

    /// Runs the client's deleteRecord request in the transaction.
    public func deleteRecord(_ requestData: consuming WebCore.IDBRequestData, _ range: consuming WebCore.IDBKeyRangeData) {
        holdingDatabase?.transactionDeleteRecord(serial: serial, requestData, range)
    }

    /// Runs the client's openCursor request in the transaction.
    public func openCursor(_ requestData: consuming WebCore.IDBRequestData, _ info: consuming WebCore.IDBCursorInfo) {
        holdingDatabase?.transactionOpenCursor(serial: serial, requestData, info)
    }

    /// Runs the client's iterateCursor request in the transaction.
    public func iterateCursor(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBIterateCursorData) {
        holdingDatabase?.transactionIterateCursor(serial: serial, requestData, data)
    }

    /// Aborts the transaction and tells the client when done.
    public func abort() {
        holdingDatabase?.abort(serial: serial)
    }

    /// Aborts the transaction without telling the client, whose connection is going away.
    public func abortWithoutCallback() {
        holdingDatabase?.abortWithoutCallback(serial: serial)
    }

    /// Commits the transaction, or aborts it if a request the client has not handled yet failed.
    public func commit(_ handledRequestResultsCount: UInt64) {
        holdingDatabase?.commit(serial: serial, handledRequestResultsCount: handledRequestResultsCount)
    }

    /// Adds the index key the client generated for a record to the index being created.
    public func didGenerateIndexKeyForRecord(
        _ createIndexRequestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ info: consuming WebCore.IDBIndexInfo,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKey: consuming WebCore.IndexKey,
        _ recordID: Int64?
    ) {
        holdingDatabase?
            .transactionDidGenerateIndexKeyForRecord(
                serial: serial,
                createIndexRequestIdentifier: createIndexRequestIdentifier,
                info,
                key,
                indexKey,
                recordID: recordID
            )
    }
}
