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

@_spi(IDBServer) internal import WebCore
internal import WebCore_Private
internal import WebKit_Internal

// The network process's IndexedDB registry: one router, shared by every origin's IDBStorageManager, and the endpoints
// that send a web process connection's results. A second registration of an identifier keeps the first entry.

/// A web process connection's endpoint: the C++ IDBStorageConnectionToClient, held by its holder, and the IPC connection
/// it sends on.
final class IDBStorageEndpoint {
    let holder: WebKit.IDBStorageEndpointHolder
    let ipcConnection: UInt64
    let identifier: WebCore.IDBConnectionIdentifier

    init(holder: WebKit.IDBStorageEndpointHolder, ipcConnection: UInt64, identifier: WebCore.IDBConnectionIdentifier) {
        self.identifier = identifier
        self.holder = holder
        self.ipcConnection = ipcConnection
    }
}

// The C++ lookups of IDBStorageRegistryLookups.h need the metadata accessors of these types, which nothing else in the module
// references, so -O -wmo would drop them: rdar://179098545.
@used
@_expose(!Cxx)
func idbStorageMetadataKeptForCxx() -> [Any.Type] {
    [IDBTransactionLookup.self, IDBDatabaseConnectionLookup.self, WebCore.IDBDatabaseIdentifier.self]
}

/// What a lookup of an identifier from IPC found.
///
/// A case has one payload, as C++ can represent it.
@_expose(Cxx)
enum IDBTransactionLookup {
    case found(IDBTransactionRoute)
    case notFound
    case invalidMessage
}

@_expose(Cxx)
enum IDBDatabaseConnectionLookup {
    case found(IDBDatabaseConnectionRoute)
    case notFound
    case invalidMessage
}

@_expose(Cxx)
struct IDBTransactionRoute {
    fileprivate let handle: IDBTransactionHandle

    @used
    func isVersionChange() -> Bool {
        handle.isVersionChange
    }

    /// Creates an object store in the transaction.
    ///
    /// `requestData` and `info` are borrowed: `NetworkStorageManager::createObjectStore` passes `const&` to the
    /// decoded IPC message's arguments, on the work queue. While they are live, Swift calls the router, the store,
    /// the delegate (which sends IPC) and the quota check (`OriginQuotaManager`, which may complete synchronously and
    /// re-enter Swift); none of them reaches the message. What is kept past the call is copied.
    @used
    func createObjectStore(_ requestData: WebCore.IDBRequestData, _ info: WebCore.IDBObjectStoreInfo) {
        handle.createObjectStore(requestData, info)
    }

    @used
    func deleteObjectStore(_ requestData: consuming WebCore.IDBRequestData, _ objectStoreName: consuming WTF.String) {
        handle.deleteObjectStore(requestData, objectStoreName)
    }

    @used
    func renameObjectStore(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ newName: consuming WTF.String
    ) {
        handle.renameObjectStore(requestData, objectStoreIdentifier, newName)
    }

    @used
    func clearObjectStore(_ requestData: consuming WebCore.IDBRequestData, _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier) {
        handle.clearObjectStore(requestData, objectStoreIdentifier)
    }

    @used
    func createIndex(_ requestData: consuming WebCore.IDBRequestData, _ info: consuming WebCore.IDBIndexInfo) {
        handle.createIndex(requestData, info)
    }

    @used
    func deleteIndex(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexName: consuming WTF.String
    ) {
        handle.deleteIndex(requestData, objectStoreIdentifier, indexName)
    }

    @used
    func renameIndex(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: WebCore.IDBIndexIdentifier,
        _ newName: consuming WTF.String
    ) {
        handle.renameIndex(requestData, objectStoreIdentifier, indexIdentifier, newName)
    }

    /// Stores a record, with its index keys, in the transaction.
    ///
    /// `indexKeys` is borrowed: `NetworkStorageManager::putOrAdd` passes `const&` to the decoded IPC message's
    /// argument, on the work queue. While it is live, Swift calls the router, the store, the delegate (which sends
    /// IPC) and the quota check (`OriginQuotaManager`, which may complete synchronously and re-enter Swift); none of
    /// them reaches the message. What is kept past the call is copied.
    @used
    func putOrAdd(
        _ requestData: consuming WebCore.IDBRequestData,
        _ key: consuming WebCore.IDBKeyData,
        _ value: consuming WebCore.IDBValue,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        handle.putOrAdd(requestData, key, value, indexKeys, overwriteMode)
    }

    @used
    func getRecord(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBGetRecordData) {
        handle.getRecord(requestData, data)
    }

    @used
    func getAllRecords(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBGetAllRecordsData) {
        handle.getAllRecords(requestData, data)
    }

    @used
    func getCount(_ requestData: consuming WebCore.IDBRequestData, _ range: consuming WebCore.IDBKeyRangeData) {
        handle.getCount(requestData, range)
    }

    @used
    func deleteRecord(_ requestData: consuming WebCore.IDBRequestData, _ range: consuming WebCore.IDBKeyRangeData) {
        handle.deleteRecord(requestData, range)
    }

    @used
    func openCursor(_ requestData: consuming WebCore.IDBRequestData, _ info: consuming WebCore.IDBCursorInfo) {
        handle.openCursor(requestData, info)
    }

    @used
    func iterateCursor(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBIterateCursorData) {
        handle.iterateCursor(requestData, data)
    }

    @used
    func databaseIdentifier() -> WebCore.IDBDatabaseIdentifier? {
        handle.databaseIdentifier()
    }

    @used
    func abort() {
        handle.abort()
    }

    @used
    func abortWithoutCallback() {
        handle.abortWithoutCallback()
    }

    @used
    func commit(_ handledRequestResultsCount: UInt64) {
        handle.commit(handledRequestResultsCount)
    }

    @used
    func didGenerateIndexKeyForRecord(
        _ createIndexRequestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ info: consuming WebCore.IDBIndexInfo,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKey: consuming WebCore.IndexKey,
        _ recordID: Int64?
    ) {
        handle.didGenerateIndexKeyForRecord(createIndexRequestIdentifier, info, key, indexKey, recordID)
    }
}

@_expose(Cxx)
struct IDBDatabaseConnectionRoute {
    fileprivate let handle: IDBDatabaseConnectionHandle

    @used
    func establishTransaction(_ info: __owned WebCore.IDBTransactionInfo) {
        handle.establishTransaction(info)
    }

    @used
    func connectionPendingCloseFromClient() {
        handle.connectionPendingCloseFromClient()
    }

    @used
    func connectionClosedFromClient() {
        handle.connectionClosedFromClient()
    }

    @used
    func didFireVersionChangeEvent(
        _ requestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ connectionClosed: WebCore.IndexedDB.ConnectionClosedOnBehalfOfServer
    ) {
        handle.didFireVersionChangeEvent(requestIdentifier, connectionClosed)
    }

    @used
    func didFinishHandlingVersionChange(_ transactionIdentifier: consuming WebCore.IDBResourceIdentifier) {
        handle.didFinishHandlingVersionChange(transactionIdentifier)
    }

    @used
    func isVersionChangeTransactionActive() -> Bool {
        handle.isVersionChangeTransactionActive
    }

    @used
    func isVersionChangeTransactionFinishingOrFinished(_ transactionIdentifier: consuming WebCore.IDBResourceIdentifier) -> Bool {
        handle.isVersionChangeTransactionFinishingOrFinished(transactionIdentifier)
    }

    @used
    func databaseIdentifier() -> WebCore.IDBDatabaseIdentifier? {
        handle.databaseIdentifier
    }
}

@_expose(Cxx)
final class IDBStorageRegistry {
    @_expose(!Cxx) // WebCore's router is not declared to C++.
    let router = IDBServerRouter(policy: .keepFirst)
    // Keyed by the identifier's integer: the identifier type is a C++ template specialization with no Hashable conformance.
    private var endpoints: [UInt64: IDBStorageEndpoint] = [:]

    @used
    init() {}

    deinit {
        // The endpoints go with the registry, each clearing its delegate first, as the endpoint's destructor does.
        for endpoint in endpoints.values {
            router.connectionToClient(endpoint.identifier)?.clearDelegate()
        }
    }

    /// The IPC connection of the endpoint for this client connection, if there is one.
    @used
    func endpointIPCConnection(_ identifier: WebCore.IDBConnectionIdentifier) -> UInt64? {
        endpoints[identifier.toUInt64()]?.ipcConnection
    }

    /// Registers the endpoint of a client connection that has none, and the connection to client its delegate backs.
    @used
    func addEndpoint(
        _ holder: WebKit.IDBStorageEndpointHolder,
        ipcConnection: UInt64,
        identifier: WebCore.IDBConnectionIdentifier
    ) {
        assert(endpoints[identifier.toUInt64()] == nil)
        router.addConnectionToClient(delegate: holder.delegate())
        endpoints[identifier.toUInt64()] = IDBStorageEndpoint(holder: holder, ipcConnection: ipcConnection, identifier: identifier)
    }

    @_expose(!Cxx)
    func existingConnectionToClient(_ identifier: WebCore.IDBConnectionIdentifier) -> IDBConnectionToClient? {
        guard endpoints[identifier.toUInt64()] != nil else {
            return nil
        }
        return router.connectionToClient(identifier)
    }

    @used
    func setClientSuspended(_ identifier: WebCore.IDBConnectionIdentifier, _ isSuspended: Bool) {
        router.setClientSuspended(identifier, isSuspended)
    }

    /// Closes and forgets every connection to a client that sends on this IPC connection.
    @used
    func removeConnectionToClient(_ ipcConnection: UInt64) {
        let identifiers = endpoints.values.filter { $0.ipcConnection == ipcConnection }.map(\.identifier)
        for identifier in identifiers {
            // Closed, then the delegate dropped, then the endpoint freed: the order the delegate's checked count needs.
            router.removeConnectionToClient(identifier)
            endpoints[identifier.toUInt64()] = nil
        }
    }

    /// True when the endpoint is gone, or sends on this IPC connection.
    private func isValidConnectionForIPC(_ connectionToClient: WebCore.IDBConnectionIdentifier?, _ ipcConnection: UInt64) -> Bool {
        guard let connectionToClient, let endpoint = endpoints[connectionToClient.toUInt64()] else {
            return true
        }
        return endpoint.ipcConnection == ipcConnection
    }

    @used
    func connection(_ identifier: WebCore.IDBDatabaseConnectionIdentifier, ipc ipcConnection: UInt64) -> IDBDatabaseConnectionLookup {
        guard let handle = router.databaseConnection(identifier) else {
            return .notFound
        }

        if !isValidConnectionForIPC(handle.connectionToClientIdentifier, ipcConnection) {
            return .invalidMessage
        }

        return .found(IDBDatabaseConnectionRoute(handle: handle))
    }

    @used
    func transaction(_ identifier: consuming WebCore.IDBResourceIdentifier, ipc ipcConnection: UInt64) -> IDBTransactionLookup {
        if Optional(fromCxx: identifier.connectionIdentifier()) == nil {
            return .invalidMessage
        }
        if identifier.isEmpty() {
            return .notFound
        }
        guard let handle = router.transaction(identifier) else {
            return .notFound
        }

        // The transaction's database connection, if it still has one.
        if !isValidConnectionForIPC(handle.connectionToClientIdentifier, ipcConnection) {
            return .invalidMessage
        }

        return .found(IDBTransactionRoute(handle: handle))
    }
}
