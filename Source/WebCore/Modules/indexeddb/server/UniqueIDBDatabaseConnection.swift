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
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBResultData
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes

/// A reference type, as `UniqueIDBDatabaseTransaction` is, so reading a connection out of the database's dictionary
/// copies one reference, not its client connection and its dictionary of transactions.
final class UniqueIDBDatabaseConnection {
    /// The database's references to the connection; it is removed when none is left.
    struct Holders: OptionSet {
        let rawValue: UInt8
        static let open = Holders(rawValue: 1 << 0)
        static let versionChange = Holders(rawValue: 1 << 1)
        /// The reference a call holds to the connection until it returns.
        static let call = Holders(rawValue: 1 << 2)
    }

    let identifier: WebCore.IDBDatabaseConnectionIdentifier
    let connectionToClient: IDBConnectionToClient
    let openRequestIdentifier: WebCore.IDBResourceIdentifier
    var closePending = false
    var transactionSerials: [WebCore.IDBResourceIdentifier: IDBEntitySerial] = [:]
    var holders: Holders = []

    init(
        identifier: WebCore.IDBDatabaseConnectionIdentifier,
        connectionToClient: IDBConnectionToClient,
        openRequestIdentifier: WebCore.IDBResourceIdentifier,
        holders: Holders
    ) {
        self.identifier = identifier
        self.connectionToClient = connectionToClient
        self.openRequestIdentifier = openRequestIdentifier
        self.holders = holders
    }
}

extension UniqueIDBDatabaseConnection {
    func fireVersionChangeEvent(_ requestIdentifier: WebCore.IDBResourceIdentifier, requestedVersion: UInt64) {
        assert(!closePending)
        connectionToClient.fireVersionChangeEvent(identifier, requestIdentifier: requestIdentifier, requestedVersion: requestedVersion)
    }
}

// What a database connection does that changes its database: each looks the connection up by identifier.
extension UniqueIDBDatabase {
    /// Makes a connection for the open request and registers it, the connection held as `holders` says.
    func makeConnection(
        openRequest serial: IDBEntitySerial,
        holders: UniqueIDBDatabaseConnection.Holders
    ) -> WebCore.IDBDatabaseConnectionIdentifier {
        guard let request = openRequests[serial] else {
            preconditionFailure()
        }

        let identifier = WebCore.IDBDatabaseConnectionIdentifier.generate()
        connections[identifier] = UniqueIDBDatabaseConnection(
            identifier: identifier,
            connectionToClient: request.connectionToClient,
            openRequestIdentifier: request.requestData.requestIdentifier(),
            holders: holders
        )
        router.registerConnection(identifier, database: self)
        request.connectionToClient.registerDatabaseConnection(identifier)
        return identifier
    }

    func createVersionChangeTransaction(connection: WebCore.IDBDatabaseConnectionIdentifier, newVersion: UInt64) -> IDBEntitySerial {
        guard let connectionToClient = connections[connection]?.connectionToClient else {
            preconditionFailure()
        }

        assert(connections[connection]?.closePending == false)
        // The transaction info and the transaction each hold a copy of the info: aborting the version change restores
        // the transaction's.
        let transactionInfo = withInfo { WebCore.IDBTransactionInfo.versionChange(connectionToClient.identifier, $0, newVersion) }
        return makeTransaction(connection: connection, transactionInfo, originalDatabaseInfo: databaseInfo)
    }

    func establishTransaction(connection: WebCore.IDBDatabaseConnectionIdentifier, _ info: __owned WebCore.IDBTransactionInfo) {
        assert(info.mode() != .Versionchange)
        // No transactions should ever come from the client after the client has already told us
        // the connection is closing.
        assert(connections[connection]?.closePending == false)
        let serial = makeTransaction(connection: connection, info, originalDatabaseInfo: .none)
        enqueueTransaction(serial: serial)
    }

    /// Makes a transaction on the connection and registers it; the connection holds it.
    private func makeTransaction(
        connection: WebCore.IDBDatabaseConnectionIdentifier,
        _ info: __owned WebCore.IDBTransactionInfo,
        originalDatabaseInfo: __owned WebCore.IDBDatabaseInfo?
    ) -> IDBEntitySerial {
        let serial = mintSerial()
        let transactionIdentifier = WebCore.idbTransactionInfoIdentifier(info)
        transactions[serial] = UniqueIDBDatabaseTransaction(
            serial: serial,
            info: info,
            originalDatabaseInfo: originalDatabaseInfo,
            databaseConnection: connection,
            holders: .connection
        )
        router.registerTransaction(transactionIdentifier, database: self, serial: serial)

        let replaced = connections[connection]?.transactionSerials.updateValue(serial, forKey: transactionIdentifier)
        if let replaced {
            release(transaction: replaced, from: .connection)
        }
        return serial
    }

    /// Takes the transaction out of the connection's transaction map, returning what the map held for its identifier.
    private func takeTransaction(connection: WebCore.IDBDatabaseConnectionIdentifier, serial: IDBEntitySerial) -> IDBEntitySerial? {
        guard let transactionIdentifier = transactions[serial]?.identifier,
            let taken = connections[connection]?.transactionSerials.removeValue(forKey: transactionIdentifier)
        else {
            return nil
        }
        return taken
    }

    func connectionPendingCloseFromClient(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        connections[connection]?.closePending = true
    }

    func didAbortTransaction(serial: IDBEntitySerial, error: WebCore.IDBError) {
        guard let transaction = transactions[serial],
            let connectionToClient = connections[transaction.databaseConnection]?.connectionToClient
        else {
            return
        }

        let taken = takeTransaction(connection: transaction.databaseConnection, serial: serial)
        assert(taken != nil)
        connectionToClient.didAbortTransaction(transaction.identifier, error: error)
        if let taken {
            release(transaction: taken, from: .connection)
        }
    }

    func didCommitTransaction(serial: IDBEntitySerial, error: WebCore.IDBError) {
        guard let transaction = transactions[serial],
            let connectionToClient = connections[transaction.databaseConnection]?.connectionToClient
        else {
            return
        }

        let taken = takeTransaction(connection: transaction.databaseConnection, serial: serial)
        assert(taken != nil || !error.isNull())
        if let taken {
            release(transaction: taken, from: .connection)
        }
        connectionToClient.didCommitTransaction(transaction.identifier, error: error)
    }

    func abortTransactionWithoutCallback(connection: WebCore.IDBDatabaseConnectionIdentifier, serial: IDBEntitySerial) {
        guard let transactionIdentifier = transactions[serial]?.identifier else {
            return
        }

        assert(connections[connection]?.transactionSerials[transactionIdentifier] != nil)
        abortTransaction(serial: serial) { [reference = self.reference] _ in
            guard let self = reference.database, self.connections[connection] != nil else {
                return
            }

            assert(self.connections[connection]?.transactionSerials[transactionIdentifier] != nil)
            if let taken = self.connections[connection]?.transactionSerials.removeValue(forKey: transactionIdentifier) {
                self.release(transaction: taken, from: .connection)
            }
        }
    }

    func deleteTransaction(connection: WebCore.IDBDatabaseConnectionIdentifier, serial: IDBEntitySerial) {
        let taken = takeTransaction(connection: connection, serial: serial)
        assert(taken != nil)
        if let taken {
            release(transaction: taken, from: .connection)
        }
    }

    func deleteTransactionsAbortedForClientSuspension(connection: WebCore.IDBDatabaseConnectionIdentifier) {
        guard let transactionSerials = connections[connection]?.transactionSerials else {
            return
        }

        // Transactions aborted on the server while this connection's client was suspended are kept
        // in the map so the client can learn about the abort if it resumes; on connection close
        // there is no client left to tell.
        for (transactionIdentifier, serial) in transactionSerials where transactions[serial]?.suspensionAbortResult != nil {
            connections[connection]?.transactionSerials[transactionIdentifier] = nil
            release(transaction: serial, from: .connection)
        }
    }
}

/// A database connection named by a client, for the routing entries: every member looks the connection up first and
/// does nothing if its database no longer holds it.
@_spi(IDBServer)
public struct IDBDatabaseConnectionHandle {
    let reference: IDBDatabaseReference
    var database: UniqueIDBDatabase? {
        reference.database
    }
    /// The connection this handle names.
    public let identifier: WebCore.IDBDatabaseConnectionIdentifier

    init(database: UniqueIDBDatabase, identifier: WebCore.IDBDatabaseConnectionIdentifier) {
        reference = database.reference
        self.identifier = identifier
    }

    /// The database, if it still holds the connection.
    private var holdingDatabase: UniqueIDBDatabase? {
        guard let database, database.connections[identifier] != nil else {
            return nil
        }
        return database
    }

    /// The client the connection belongs to, or nil if the connection is gone.
    public var connectionToClientIdentifier: WebCore.IDBConnectionIdentifier? {
        database?.connections[identifier]?.connectionToClient.identifier
    }

    /// Starts a transaction the client asked for on the connection.
    public func establishTransaction(_ info: __owned WebCore.IDBTransactionInfo) {
        holdingDatabase?.establishTransaction(connection: identifier, info)
    }

    /// Marks the connection as closing, as the client asked.
    public func connectionPendingCloseFromClient() {
        holdingDatabase?.connectionPendingCloseFromClient(identifier)
    }

    /// Closes the connection, as the client asked.
    public func connectionClosedFromClient() {
        holdingDatabase?.connectionClosedFromClient(identifier)
    }

    /// The client fired the version change event of the request on the connection.
    public func didFireVersionChangeEvent(
        _ requestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ connectionClosed: WebCore.IndexedDB.ConnectionClosedOnBehalfOfServer
    ) {
        holdingDatabase?.didFireVersionChangeEvent(identifier, requestIdentifier: requestIdentifier, connectionClosed: connectionClosed)
    }

    /// The client finished handling the connection's version change transaction.
    public func didFinishHandlingVersionChange(_ transactionIdentifier: consuming WebCore.IDBResourceIdentifier) {
        holdingDatabase?.didFinishHandlingVersionChange(identifier, transactionIdentifier: transactionIdentifier)
    }

    /// False if the connection is gone.
    public var isVersionChangeTransactionActive: Bool {
        holdingDatabase?.isVersionChangeTransactionActive(identifier) ?? false
    }

    /// True if the connection is gone: there is no version change transaction of it left to wait for.
    public func isVersionChangeTransactionFinishingOrFinished(_ transactionIdentifier: consuming WebCore.IDBResourceIdentifier) -> Bool {
        holdingDatabase?.isVersionChangeTransactionFinishingOrFinished(transactionIdentifier) ?? true
    }

    /// The identifier of the connection's database.
    public var databaseIdentifier: WebCore.IDBDatabaseIdentifier? {
        holdingDatabase?.identifier
    }
}
