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
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBDatabaseNameAndVersion
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBOpenRequestData
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBResultData
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes

final class UniqueIDBDatabase {
    let identifier: WebCore.IDBDatabaseIdentifier
    private let coreReference: IDBServerCoreReference
    var core: IDBServerCore? {
        coreReference.core
    }
    let router: IDBServerRouter
    /// What its continuations and routing entries hold instead of a weak reference to the database.
    ///
    /// A constant, not a lazy property: reading a lazy property is a mutating access, an exclusivity check and a retain per read.
    let reference = IDBDatabaseReference()
    var nextSerial = IDBEntitySerial(0)

    var pendingOpenRequestOrder: [IDBEntitySerial] = []
    var openRequests: [IDBEntitySerial: ServerOpenDBRequest] = [:]
    var currentOpenRequest: IDBEntitySerial?
    var openRequestsForSpaceCheck: Set<WebCore.IDBResourceIdentifier> = []

    var openConnectionOrder: [WebCore.IDBDatabaseConnectionIdentifier] = []
    var connections: IDBIdentifierDictionary<WebCore.IDBDatabaseConnectionIdentifier, UniqueIDBDatabaseConnection> = [:]
    var versionChangeConnection: WebCore.IDBDatabaseConnectionIdentifier?
    var versionChangeTransaction: IDBEntitySerial?

    var store: IDBServerBackingStore?
    // Spelled out, not `T?`: a C++ value with a destructor in `T?` turns the initialization into an assignment (rdar://192229155).
    var databaseInfo: Optional<WebCore.IDBDatabaseInfo>
    var mostRecentDeletedDatabaseInfo: Optional<WebCore.IDBDatabaseInfo>

    var pendingTransactions: IDBPendingTransactionQueue = []
    var inProgressTransactions = IDBInProgressTransactions()
    var transactions: [IDBEntitySerial: UniqueIDBDatabaseTransaction] = [:]

    // Keyed by object store: which transactions can start and which must wait.
    var objectStoreTransactionCounts: IDBIdentifierDictionary<WebCore.IDBObjectStoreIdentifier, Int> = [:]
    var objectStoreWriteTransactions: IDBIdentifierSet<WebCore.IDBObjectStoreIdentifier> = []

    var isAbortingTransactionsOfSuspendedClients = false

    init(identifier: WebCore.IDBDatabaseIdentifier, core: IDBServerCore, router: IDBServerRouter) {
        self.identifier = identifier
        coreReference = core.reference
        self.router = router
        databaseInfo = .none
        mostRecentDeletedDatabaseInfo = .none
        reference.databaseDidInitialize(self)
    }

    deinit {
        reference.databaseWillDeinitialize()
        unregisterRemainingEntities()
    }
}

// The database's lifecycle: open and delete requests, version changes, scheduling of transactions, and closing.
extension UniqueIDBDatabase {
    func mintSerial() -> IDBEntitySerial {
        nextSerial = IDBEntitySerial(nextSerial.value + 1)
        return nextSerial
    }

    /// What the database still has registered in its router when it goes away.
    func unregisterRemainingEntities() {
        for transaction in transactions.values where connections[transaction.databaseConnection] != nil {
            router.unregisterTransaction(transaction.identifier)
        }
        transactions = [:]
        for (identifier, connection) in connections {
            router.unregisterConnection(identifier)
            connection.connectionToClient.unregisterDatabaseConnection(identifier)
        }
        connections = [:]
    }

    /// Calls `body` with the database's info in place, trapping if there is none rather than reading a missing info.
    ///
    /// A read of the optional copies the whole schema, `databaseInfo != nil` and the payload of `databaseInfo!` included;
    /// a mutating access through the force unwrap does not. `body` must not reach `databaseInfo` again.
    func withInfo<Result>(_ body: (inout WebCore.IDBDatabaseInfo) -> Result) -> Result {
        // swift-format-ignore: NeverForceUnwrap
        body(&databaseInfo!)
    }

    /// The database's version, read in place.
    var infoVersion: UInt64 {
        withInfo { $0.version() }
    }

    /// Whether the database has its info, read in place: `databaseInfo != nil` copies the whole schema to read its tag.
    var hasInfo: Bool {
        Self.holdsValue(&databaseInfo)
    }

    /// Whether `value` holds a value, read through a mutating access: reading a C++ value's optional copies it.
    private static func holdsValue<Wrapped>(_ value: inout Wrapped?) -> Bool {
        if case .none = value {
            return false
        }
        return true
    }

    /// An open or a delete: the request's data says which.
    func enqueueOpenRequest(_ connectionToClient: IDBConnectionToClient, _ requestData: consuming WebCore.IDBOpenRequestData) {
        addPendingOpenRequest(connectionToClient, requestData)
        handleDatabaseOperations()
    }

    private func addPendingOpenRequest(_ connectionToClient: IDBConnectionToClient, _ requestData: consuming WebCore.IDBOpenRequestData) {
        let serial = mintSerial()
        openRequests[serial] = ServerOpenDBRequest(
            serial: serial,
            connectionToClient: connectionToClient,
            requestData: requestData,
            holders: .pending
        )
        pendingOpenRequestOrder.append(serial)
    }

    private func performCurrentOpenOperation() {
        guard let serial = currentOpenRequest, let requestIdentifier = openRequests[serial]?.requestData.requestIdentifier() else {
            preconditionFailure()
        }
        assert(openRequests[serial]?.isOpenRequest == true)

        // We don't need to create the file so no need to do space check.
        if store != nil {
            performCurrentOpenOperationAfterSpaceCheck(isGranted: true)
            return
        }

        guard let core else {
            performCurrentOpenOperationAfterSpaceCheck(isGranted: false)
            return
        }

        if openRequestsForSpaceCheck.contains(requestIdentifier) {
            return
        }

        openRequestsForSpaceCheck.insert(requestIdentifier)
        core.requestSpace(origin: WebCore.idbDatabaseIdentifierOrigin(identifier), size: Self.defaultWriteOperationCost) {
            [reference = self.reference] isGranted in
            guard let self = reference.database else {
                return
            }

            self.openRequestsForSpaceCheck.remove(requestIdentifier)
            guard let current = self.currentOpenRequest,
                self.openRequests[current]?.requestData.requestIdentifier() == requestIdentifier
            else {
                return
            }

            self.performCurrentOpenOperationAfterSpaceCheck(isGranted: isGranted)
        }
    }

    private func performCurrentOpenOperationAfterSpaceCheck(isGranted: Bool) {
        var backingStoreOpenError = WebCore.makeIDBServerNoError()
        if store == nil {
            if let core {
                if !isGranted {
                    backingStoreOpenError = Self.quotaError("OpenBackingStore")
                } else {
                    let backingStore = core.createBackingStore(identifier)
                    store = backingStore
                    let (error, databaseInfo) = backingStore.getOrEstablishDatabaseInfo()
                    backingStoreOpenError = error
                    if error.isNull() {
                        self.databaseInfo = databaseInfo
                    } else {
                        store = nil
                    }
                }
            } else {
                backingStoreOpenError = Self.idbError(.InvalidStateError)
            }
        }

        guard let serial = currentOpenRequest, let requestData = openRequests[serial]?.requestData else {
            preconditionFailure()
        }

        if !backingStoreOpenError.isNull() {
            let result = WebCore.IDBResultData.error(requestData.requestIdentifier(), backingStoreOpenError)
            didOpenDatabase(openRequest: serial, result, error: backingStoreOpenError)
            replaceCurrentOpenRequest(with: nil)
            return
        }

        // If we previously started a version change operation but were blocked by having open connections,
        // we might now be unblocked.
        if versionChangeConnection != nil {
            if versionChangeTransaction == nil && !hasAnyOpenConnections {
                startVersionChangeTransaction()
            }
            return
        }

        // 3.3.1 Opening a database
        // If requested version is undefined, then let requested version be 1 if db was created in the previous step,
        // or the current version of db otherwise.
        var requestedVersion = requestData.requestedVersion()
        let databaseVersion = infoVersion
        if requestedVersion == 0 {
            requestedVersion = databaseVersion != 0 ? databaseVersion : 1
        }

        // 3.3.1 Opening a database
        // If the database version higher than the requested version, abort these steps and return a VersionError.
        if requestedVersion < databaseVersion {
            let error = Self.idbError(.VersionError)
            let result = WebCore.IDBResultData.error(requestData.requestIdentifier(), error)
            didOpenDatabase(openRequest: serial, result, error: error)
            replaceCurrentOpenRequest(with: nil)
            return
        }

        if requestedVersion == databaseVersion {
            let connection = makeConnection(openRequest: serial, holders: [])
            addOpenConnection(connection)
            let result = withInfo { WebCore.IDBResultData.openDatabaseSuccess(requestData.requestIdentifier(), connection, $0) }
            didOpenDatabase(openRequest: serial, result, error: WebCore.makeIDBServerNoError())
            replaceCurrentOpenRequest(with: nil)
            return
        }

        assert(versionChangeConnection == nil)
        let connection = makeConnection(openRequest: serial, holders: .versionChange)
        if let previous = versionChangeConnection {
            release(connection: previous, from: .versionChange)
        }
        versionChangeConnection = connection

        // 3.3.7 "versionchange" transaction steps
        // If there's no other open connections to this database, the version change process can begin immediately.
        if !hasAnyOpenConnections {
            startVersionChangeTransaction()
            return
        }

        // Otherwise we have to notify all those open connections and wait for them to close.
        maybeNotifyConnectionsOfVersionChange()
    }

    private func performCurrentDeleteOperation() {
        assert(currentOpenRequest.flatMap { openRequests[$0]?.isDeleteRequest } == true)

        if hasAnyOpenConnections {
            maybeNotifyConnectionsOfVersionChange()
            return
        }

        // It's possible to have multiple delete requests queued up in a row.
        // In that scenario only the first request will actually have to delete the database.
        // Subsequent requests can immediately notify their completion.
        if !hasInfo && Self.holdsValue(&mostRecentDeletedDatabaseInfo) {
            didDeleteBackingStore(deletedVersion: 0)
            return
        }

        deleteBackingStore()
    }

    private func deleteBackingStore() {
        let backingStore: IDBServerBackingStore
        if let existing = store.take() {
            backingStore = existing
        } else {
            guard let core else {
                preconditionFailure()
            }
            backingStore = core.createBackingStore(identifier)
        }

        let deletedVersion = backingStore.databaseVersion()
        backingStore.deleteBackingStore()
        withExtendedLifetime(backingStore) {
            didDeleteBackingStore(deletedVersion: deletedVersion)
        }
    }

    private func didDeleteBackingStore(deletedVersion: UInt64) {
        assert(currentOpenRequest != nil)
        assert(store == nil)

        if hasInfo {
            mostRecentDeletedDatabaseInfo = databaseInfo.take()
        }

        // If this UniqueIDBDatabase was brought into existence for the purpose of deleting the file on disk,
        // we won't have a mostRecentDeletedDatabaseInfo. In that case, we'll manufacture one using the
        // passed in deletedVersion argument.
        if !Self.holdsValue(&mostRecentDeletedDatabaseInfo) {
            var deletedDatabaseInfo = WebCore.makeMemoryIDBDatabaseInfo(WebCore.idbDatabaseIdentifierDatabaseName(identifier))
            deletedDatabaseInfo.setVersion(deletedVersion)
            mostRecentDeletedDatabaseInfo = deletedDatabaseInfo
        }

        guard let serial = currentOpenRequest.take() else {
            return
        }

        if let request = openRequests[serial] {
            // swift-format-ignore: NeverForceUnwrap
            // The force unwrap is the in-place access (see `withInfo`); the info was set above.
            request.connectionToClient.didDeleteDatabase(Self.deleteDatabaseSuccess(request, &mostRecentDeletedDatabaseInfo!))
        }
        release(openRequest: serial, from: .current)
    }

    /// The delete request's success result, made from the deleted database's info in place.
    private static func deleteDatabaseSuccess(
        _ request: ServerOpenDBRequest,
        _ deletedDatabaseInfo: inout WebCore.IDBDatabaseInfo
    ) -> WebCore.IDBResultData {
        WebCore.IDBResultData.deleteDatabaseSuccess(request.requestData.requestIdentifier(), deletedDatabaseInfo)
    }

    private func clearStalePendingOpenRequests() {
        while let first = pendingOpenRequestOrder.first, openRequests[first]?.connectionToClient.isClosed == true {
            pendingOpenRequestOrder.removeFirst()
            release(openRequest: first, from: .pending)
        }
    }

    private func handleDatabaseOperations() {
        if currentOpenRequest == nil && (versionChangeConnection != nil || versionChangeTransaction != nil) {
            return
        }

        if currentOpenRequestIsAbsentOrClosed {
            replaceCurrentOpenRequest(with: takeNextRunnableRequest())
        }

        while currentOpenRequest != nil {
            handleCurrentOperation()

            if versionChangeTransaction != nil || currentOpenRequest != nil {
                break
            }

            replaceCurrentOpenRequest(with: takeNextRunnableRequest())
        }
    }

    private func handleCurrentOperation() {
        guard let serial = currentOpenRequest, let request = openRequests[serial] else {
            preconditionFailure()
        }

        if request.isOpenRequest {
            performCurrentOpenOperation()
        } else if request.isDeleteRequest {
            performCurrentDeleteOperation()
        }
    }

    /// Takes the first pending request whose client is still there; the request is still held as pending.
    private func takeNextRunnableRequest() -> IDBEntitySerial? {
        // Connection of request may be closed or lost.
        clearStalePendingOpenRequests()

        guard !pendingOpenRequestOrder.isEmpty else {
            return nil
        }
        return pendingOpenRequestOrder.removeFirst()
    }

    /// Makes a request taken from the pending ones the current one, dropping the request current before.
    private func replaceCurrentOpenRequest(with serial: IDBEntitySerial?) {
        if let serial {
            openRequests[serial]?.holders.insert(.current)
            release(openRequest: serial, from: .pending)
        }
        let previous = currentOpenRequest
        currentOpenRequest = serial
        if let previous {
            release(openRequest: previous, from: .current)
        }
    }

    /// No current open request, or its connection to the client is closed.
    private var currentOpenRequestIsAbsentOrClosed: Bool {
        guard let currentOpenRequest else {
            return true
        }
        return openRequests[currentOpenRequest]?.connectionToClient.isClosed ?? true
    }

    private var hasAnyOpenConnections: Bool {
        !openConnectionOrder.isEmpty
    }

    private var allConnectionsAreClosedOrClosing: Bool {
        openConnectionOrder.allSatisfy { connections[$0]?.closePending != false }
    }

    /// Whether the connection is one of the database's open connections.
    func isOpenConnection(_ connection: WebCore.IDBDatabaseConnectionIdentifier) -> Bool {
        openConnectionOrder.contains(where: { $0 == connection })
    }

    private func addOpenConnection(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        guard !isOpenConnection(connection) else {
            return
        }
        openConnectionOrder.append(connection)
        connections[connection]?.holders.insert(.open)
    }

    /// Removes the connection from the open ones; false if it was not one of them.
    private func removeOpenConnection(_ connection: WebCore.IDBDatabaseConnectionIdentifier) -> Bool {
        guard let index = openConnectionOrder.firstIndex(where: { $0 == connection }) else {
            return false
        }
        openConnectionOrder.remove(at: index)
        release(connection: connection, from: .open)
        return true
    }

    /// Runs `body` with the connection held, so it stays until `body` returns.
    private func withConnectionHeld(_ connection: WebCore.IDBDatabaseConnectionIdentifier, _ body: () -> Void) {
        let held = connections[connection]?.holders.insert(.call).inserted == true
        body()
        if held {
            release(connection: connection, from: .call)
        }
    }

    private func replaceVersionChangeTransaction(with serial: IDBEntitySerial?) {
        if let serial {
            transactions[serial]?.holders.insert(.versionChange)
        }
        let previous = versionChangeTransaction
        versionChangeTransaction = serial
        if let previous, previous != serial {
            release(transaction: previous, from: .versionChange)
        }
    }

    private func setVersionChangeConnectionToNil() {
        if let previous = versionChangeConnection {
            versionChangeConnection = nil
            release(connection: previous, from: .versionChange)
        }
    }

    /// Sets the in-progress transaction for the identifier, dropping one the identifier named before.
    private func setInProgressTransaction(_ transactionIdentifier: WebCore.IDBResourceIdentifier, _ serial: IDBEntitySerial) {
        transactions[serial]?.holders.insert(.inProgress)
        if let previous = inProgressTransactions.updateValue(serial, forKey: transactionIdentifier), previous != serial {
            release(transaction: previous, from: .inProgress)
        }
    }

    private func startVersionChangeTransaction() {
        assert(versionChangeTransaction == nil)
        guard let serial = currentOpenRequest, let request = openRequests[serial], let connection = versionChangeConnection else {
            preconditionFailure()
        }
        assert(request.isOpenRequest)

        withConnectionHeld(connection) {
            var requestedVersion = request.requestData.requestedVersion()
            if requestedVersion == 0 {
                let databaseVersion = infoVersion
                requestedVersion = databaseVersion != 0 ? databaseVersion : 1
            }

            let transaction = createVersionChangeTransaction(connection: connection, newVersion: requestedVersion)
            replaceVersionChangeTransaction(with: transaction)
            // The transaction is a shared record: its info is read in place, not copied with its schema.
            guard let versionChange = transactions[transaction] else {
                preconditionFailure()
            }
            setInProgressTransaction(versionChange.identifier, transaction)

            guard let store else {
                preconditionFailure()
            }
            let error = store.beginTransaction(versionChange.info)
            currentOpenRequest = nil
            holdVersionChangeTransaction(transaction, inOpenRequest: serial)

            if error.isNull() {
                addOpenConnection(connection)
                withInfo { $0.setVersion(versionChange.info.newVersion()) }
                let result = withInfo {
                    WebCore.IDBResultData.openDatabaseUpgradeNeeded(
                        request.requestData.requestIdentifier(),
                        connection,
                        $0,
                        versionChange.info
                    )
                }
                didOpenDatabase(openRequest: serial, result, error: WebCore.makeIDBServerNoError())
            } else {
                abortTransactionWithoutCallback(connection: connection, serial: transaction)
                setVersionChangeConnectionToNil()
                let result = WebCore.IDBResultData.error(request.requestData.requestIdentifier(), error)
                didOpenDatabase(openRequest: serial, result, error: error)
            }
            release(openRequest: serial, from: .current)
        }
    }

    private func maybeNotifyConnectionsOfVersionChange() {
        guard let serial = currentOpenRequest, let request = openRequests[serial] else {
            preconditionFailure()
        }

        if request.notifiedConnectionsOfVersionChange {
            return
        }

        let newVersion = request.isOpenRequest ? request.requestData.requestedVersion() : 0
        let requestIdentifier = request.requestData.requestIdentifier()

        // 3.3.7 "versionchange" transaction steps
        // Fire a versionchange event at each connection in openConnectionOrder that is open.
        // The event must not be fired on connections which has the closePending flag set.
        var connectionIdentifiers: IDBIdentifierSet<WebCore.IDBDatabaseConnectionIdentifier> = []
        for identifier in openConnectionOrder {
            guard let connection = connections[identifier], !connection.closePending else {
                continue
            }

            connection.fireVersionChangeEvent(requestIdentifier, requestedVersion: newVersion)
            connectionIdentifiers.insert(identifier)
        }

        if !connectionIdentifiers.isEmpty {
            openRequests[serial]?.setConnectionsPendingVersionChangeEvent(connectionIdentifiers)
        } else {
            maybeNotifyRequestBlocked(openRequest: serial, currentVersion: infoVersion)
        }
    }

    private func notifyCurrentRequestConnectionClosedOrFiredVersionChangeEvent(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        guard let serial = currentOpenRequest else {
            return
        }

        openRequests[serial]?.connectionClosedOrFiredVersionChangeEvent(connection)
        if openRequests[serial]?.hasConnectionsPendingVersionChangeEvent == true {
            return
        }

        if !hasAnyOpenConnections || allConnectionsAreClosedOrClosing {
            handleDatabaseOperations()
            return
        }

        // Since all open connections have fired their version change events but not all of them have closed,
        // this request is officially blocked.
        maybeNotifyRequestBlocked(openRequest: serial, currentVersion: infoVersion)
    }

    private func clearTransactionsOnConnection(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        var remainingPendingTransactions: IDBPendingTransactionQueue = []
        while let serial = pendingTransactions.takeFirst() {
            if transactions[serial].map({ $0.databaseConnection != connection }) ?? true {
                remainingPendingTransactions.append(serial)
            } else {
                deleteTransaction(connection: connection, serial: serial)
                release(transaction: serial, from: .pending)
            }
        }
        if !remainingPendingTransactions.isEmpty {
            pendingTransactions = remainingPendingTransactions
        }

        let transactionsToAbort = inProgressTransactions.values.filter { serial in
            transactions[serial].map { $0.databaseConnection == connection } ?? false
        }
        for serial in transactionsToAbort {
            abortWithoutCallback(serial: serial)
        }

        deleteTransactionsAbortedForClientSuspension(connection: connection)
    }

    func openDBRequestCancelled(_ requestIdentifier: WebCore.IDBResourceIdentifier) {
        if let current = currentOpenRequest, openRequests[current]?.requestData.requestIdentifier() == requestIdentifier {
            replaceCurrentOpenRequest(with: nil)
        }

        if let connection = versionChangeConnection, connections[connection]?.openRequestIdentifier == requestIdentifier {
            withConnectionHeld(connection) {
                connectionClosedFromClient(connection)
            }
        }

        if let index = pendingOpenRequestOrder.firstIndex(where: { openRequests[$0]?.requestData.requestIdentifier() == requestIdentifier })
        {
            let serial = pendingOpenRequestOrder.remove(at: index)
            release(openRequest: serial, from: .pending)
        }
    }

    private func errorOpenDBRequestForUserDelete(_ serial: IDBEntitySerial) {
        guard let request = openRequests[serial] else {
            return
        }

        let error = WebCore.IDBError.userDeleteError()
        let result = WebCore.IDBResultData.error(request.requestData.requestIdentifier(), error)
        if request.isOpenRequest {
            didOpenDatabase(openRequest: serial, result, error: error)
        } else {
            request.connectionToClient.didDeleteDatabase(result)
        }
    }

    func immediateClose() {
        // Error out all transactions.
        // Pending transactions must be cleared before in-progress transactions,
        // or they may get started right away after aborting in-progress transactions.
        for serial in pendingTransactions {
            if let connection = transactions[serial]?.databaseConnection, connections[connection] != nil {
                deleteTransaction(connection: connection, serial: serial)
            }
        }
        let clearedPendingTransactions = pendingTransactions
        pendingTransactions = []
        for serial in clearedPendingTransactions {
            release(transaction: serial, from: .pending)
        }

        for serial in Array(inProgressTransactions.values) {
            abortWithoutCallback(serial: serial)
        }

        assert(inProgressTransactions.isEmpty)

        objectStoreTransactionCounts = [:]
        objectStoreWriteTransactions = []

        // Error out all IDBOpenDBRequests
        if let serial = currentOpenRequest.take() {
            errorOpenDBRequestForUserDelete(serial)
            release(openRequest: serial, from: .current)
        }

        for serial in pendingOpenRequestOrder {
            errorOpenDBRequestForUserDelete(serial)
        }

        let clearedPendingOpenRequests = pendingOpenRequestOrder
        pendingOpenRequestOrder = []
        for serial in clearedPendingOpenRequests {
            release(openRequest: serial, from: .pending)
        }

        // Close all open connections
        let openDatabaseConnections = openConnectionOrder
        for connection in openDatabaseConnections {
            connections[connection]?.holders.insert(.call)
        }
        for connection in openDatabaseConnections {
            connectionClosedFromServer(connection)
        }

        if let connection = versionChangeConnection {
            withConnectionHeld(connection) {
                if !openDatabaseConnections.contains(where: { $0 == connection }) {
                    connectionClosedFromServer(connection)
                }
                setVersionChangeConnectionToNil()
            }
        }

        assert(!hasAnyOpenConnections)

        close()

        for connection in openDatabaseConnections {
            release(connection: connection, from: .call)
        }
    }

    private func connectionClosedFromServer(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        connections[connection]?.connectionToClient.didCloseFromServer(connection, error: WebCore.IDBError.userDeleteError())

        _ = removeOpenConnection(connection)
    }

    func abortActiveTransactions() {
        for transactionIdentifier in Array(inProgressTransactions.keys) {
            guard let serial = inProgressTransactions[transactionIdentifier], let transaction = transactions[serial], let store else {
                preconditionFailure()
            }
            transactions[serial]?.setSuspensionAbortResult(store.abortTransaction(transaction.identifier))
        }
    }

    private func close() {
        if let store {
            store.close()
            self.store = nil
        }
    }

    func tryClose() -> Bool {
        if hasDataInMemory {
            return false
        }

        if hasAnyOpenConnections || versionChangeConnection != nil {
            return false
        }

        close()
        return true
    }

    var hasDataInMemory: Bool {
        store?.isEphemeral == true
    }

    var filePath: WTF.String {
        guard let store else {
            return WTF.String()
        }
        return store.fullDatabasePath
    }

    var nameAndVersion: WebCore.IDBDatabaseNameAndVersion? {
        guard store != nil else {
            return .none
        }

        if let versionChangeTransaction {
            guard let originalDatabaseInfo = transactions[versionChangeTransaction]?.originalDatabaseInfo else {
                return .none
            }

            // The database is newly created.
            if originalDatabaseInfo.version() == 0 {
                return .none
            }

            return WebCore.IDBDatabaseNameAndVersion(
                name: WebCore.idbDatabaseInfoName(originalDatabaseInfo),
                version: originalDatabaseInfo.version()
            )
        }

        return withInfo { info -> WebCore.IDBDatabaseNameAndVersion? in
            if info.version() == 0 {
                return .none
            }
            return WebCore.IDBDatabaseNameAndVersion(name: WebCore.idbDatabaseInfoName(info), version: info.version())
        }
    }

    func handleLowMemoryWarning() {
        store?.handleLowMemoryWarning()
    }

    func connectionClosedFromClient(_ connection: WebCore.IDBDatabaseConnectionIdentifier) {
        withConnectionHeld(connection) {
            _ = removeOpenConnection(connection)

            if versionChangeConnection == connection {
                setVersionChangeConnectionToNil()
                if let transaction = versionChangeTransaction {
                    abortTransactionWithoutCallback(connection: connection, serial: transaction)
                    assert(connections[connection]?.transactionSerials.isEmpty ?? true)

                    // Previous blocked operations or transactions may be runnable.
                    handleDatabaseOperations()
                    handleTransactions()

                    return
                }
            }

            // Remove all pending transactions on the connection.
            clearTransactionsOnConnection(connection)
            assert(connections[connection]?.transactionSerials.isEmpty ?? true)

            if currentOpenRequest != nil {
                notifyCurrentRequestConnectionClosedOrFiredVersionChangeEvent(connection)
            }

            // Now that a database connection has closed, previously blocked operations might be runnable.
            handleDatabaseOperations()
            handleTransactions()
        }
    }

    func didFinishHandlingVersionChange(
        _ connection: WebCore.IDBDatabaseConnectionIdentifier,
        transactionIdentifier: WebCore.IDBResourceIdentifier
    ) {
        replaceVersionChangeTransaction(with: nil)
        setVersionChangeConnectionToNil()

        handleDatabaseOperations()
        handleTransactions()
    }

    func didFireVersionChangeEvent(
        _ connection: WebCore.IDBDatabaseConnectionIdentifier,
        requestIdentifier: WebCore.IDBResourceIdentifier,
        connectionClosed: WebCore.IndexedDB.ConnectionClosedOnBehalfOfServer
    ) {
        guard currentOpenRequest != nil else {
            return
        }

        if connectionClosed == .Yes && isOpenConnection(connection) {
            clearTransactionsOnConnection(connection)
            _ = removeOpenConnection(connection)
        }

        notifyCurrentRequestConnectionClosedOrFiredVersionChangeEvent(connection)
    }

    func isVersionChangeTransactionActive(_ connection: WebCore.IDBDatabaseConnectionIdentifier) -> Bool {
        versionChangeConnection == connection && versionChangeTransaction != nil
    }

    func isVersionChangeTransactionFinishingOrFinished(_ transactionIdentifier: WebCore.IDBResourceIdentifier) -> Bool {
        guard let versionChangeTransaction, let transaction = transactions[versionChangeTransaction],
            transaction.identifier == transactionIdentifier
        else {
            return true
        }

        return transaction.isFinishingOrFinished
    }

    func enqueueTransaction(serial: IDBEntitySerial) {
        assert(transactions[serial]?.isVersionChange != true)

        pendingTransactions.append(serial)
        transactions[serial]?.holders.insert(.pending)
        handleTransactionsAfterAbortingSuspendedClientTransactions()
    }

    /// The object stores in the transaction's scope; none if its connection is gone and they were never computed.
    ///
    /// A non-empty list computed earlier is returned before the database's info is read, which may be gone by then.
    private func objectStoreIdentifiers(ofTransaction serial: IDBEntitySerial) -> [WebCore.IDBObjectStoreIdentifier] {
        guard let transaction = transactions[serial] else {
            return []
        }

        if let objectStoreIdentifiers = transaction.objectStoreIdentifiers, !objectStoreIdentifiers.isEmpty {
            return objectStoreIdentifiers
        }

        if connections[transaction.databaseConnection] == nil {
            return transaction.objectStoreIdentifiers ?? []
        }

        return withInfo { transaction.objectStoreIdentifiers(in: &$0) }
    }

    func handleTransactions() {
        var (next, hadDeferredTransactions) = takeNextRunnableTransaction()

        while let serial = next {
            guard let transaction = transactions[serial] else {
                preconditionFailure()
            }

            setInProgressTransaction(transaction.identifier, serial)
            release(transaction: serial, from: .pending)
            for objectStore in objectStoreIdentifiers(ofTransaction: serial) {
                objectStoreTransactionCounts[objectStore, default: 0] += 1
                if !transaction.isReadOnly {
                    objectStoreWriteTransactions.insert(objectStore)
                    assert(objectStoreTransactionCounts[objectStore] == 1)
                }
            }

            activateTransactionInBackingStore(serial)
            if hadDeferredTransactions {
                break
            }
            (next, hadDeferredTransactions) = takeNextRunnableTransaction()
        }
    }

    private func activateTransactionInBackingStore(_ serial: IDBEntitySerial) {
        guard let store, let transaction = transactions[serial] else {
            preconditionFailure()
        }

        let error = store.beginTransaction(transaction.info)

        didActivateInBackingStore(serial: serial, error: error)
    }

    private func isTransactionOfSuspendedClient(_ serial: IDBEntitySerial) -> Bool {
        guard let connection = transactions[serial]?.databaseConnection, let databaseConnection = connections[connection] else {
            return false
        }
        return databaseConnection.connectionToClient.isClientSuspended
    }

    /// The next transaction that can run, still held as pending, and whether any was deferred to find it.
    private func takeNextRunnableTransaction() -> (IDBEntitySerial?, hadDeferredTransactions: Bool) {
        var hadDeferredTransactions = false

        // Version change transaction should have exclusive access to database.
        if versionChangeTransaction != nil {
            return (nil, hadDeferredTransactions)
        }

        if pendingTransactions.isEmpty {
            return (nil, hadDeferredTransactions)
        }

        let hasReadWriteTransactionInProgress = inProgressTransactions.contains { serial in
            transactions[serial]?.isReadOnly == false
        }

        var deferredTransactions: [IDBEntitySerial] = []
        var currentTransaction: IDBEntitySerial?

        var deferredReadWriteScopes: IDBIdentifierSet<WebCore.IDBObjectStoreIdentifier> = []

        while let candidate = pendingTransactions.takeFirst() {
            currentTransaction = candidate

            // Avoid starting transaction of suspended client since they cannot make any progress on it.
            if isTransactionOfSuspendedClient(candidate) {
                deferredTransactions.append(candidate)
                currentTransaction = nil
                continue
            }

            guard let mode = transactions[candidate]?.info.mode() else {
                preconditionFailure()
            }

            let transactionScopes = objectStoreIdentifiers(ofTransaction: candidate)
            switch mode {
            case .Readonly:
                let hasOverlappingScopes =
                    transactionScopes.contains(where: deferredReadWriteScopes.contains)
                    || transactionScopes.contains(where: objectStoreWriteTransactions.contains)

                if hasOverlappingScopes {
                    deferredTransactions.append(candidate)
                    currentTransaction = nil
                    hadDeferredTransactions = true
                }
            case .Readwrite:
                let hasOverlappingScopes =
                    transactionScopes.contains { objectStoreTransactionCounts[$0] != nil }
                    || transactionScopes.contains(where: deferredReadWriteScopes.contains)
                guard let store else {
                    preconditionFailure()
                }
                let hasBackingStoreSupport = store.supportsSimultaneousReadWriteTransactions || !hasReadWriteTransactionInProgress

                if hasOverlappingScopes || !hasBackingStoreSupport {
                    deferredReadWriteScopes.formUnion(transactionScopes)
                    deferredTransactions.append(candidate)
                    currentTransaction = nil
                    hadDeferredTransactions = true
                }
            case .Versionchange:
                fatalError("A version change transaction is never scheduled as a normal one")
            @unknown default:
                fatalError("A transaction mode the scheduler does not know")
            }

            // If we didn't defer the currentTransaction above, it can be run now.
            if currentTransaction != nil {
                break
            }
        }

        // Prepend the deferred transactions back on the beginning of the deque for future scheduling passes.
        pendingTransactions.prepend(contentsOf: deferredTransactions)

        return (currentTransaction, hadDeferredTransactions)
    }

    func transactionCompleted(serial: IDBEntitySerial, startRunnableWork: Bool = true) {
        assert(transactions[serial].map { inProgressTransactions[$0.identifier] != serial } ?? true)

        let isReadOnly = transactions[serial]?.isReadOnly == true
        for objectStore in objectStoreIdentifiers(ofTransaction: serial) {
            if !isReadOnly {
                objectStoreWriteTransactions.remove(objectStore)
                assert(objectStoreTransactionCounts[objectStore] == 1)
            }
            if let count = objectStoreTransactionCounts[objectStore] {
                objectStoreTransactionCounts[objectStore] = count > 1 ? count - 1 : nil
            }
        }

        if versionChangeTransaction == serial {
            replaceVersionChangeTransaction(with: nil)
        }

        if !startRunnableWork {
            return
        }

        // Previously blocked operations might be runnable.
        handleDatabaseOperations()
        handleTransactions()
    }

    private func transactionBlocksPendingTransactions(_ inProgressTransaction: IDBEntitySerial) -> Bool {
        let inProgressScopes = IDBIdentifierSet(objectStoreIdentifiers(ofTransaction: inProgressTransaction))

        let inProgressIsReadOnly = transactions[inProgressTransaction]?.isReadOnly == true
        let serializesReadWrites = store.map { !$0.supportsSimultaneousReadWriteTransactions } ?? false

        for pendingTransaction in pendingTransactions {
            if isTransactionOfSuspendedClient(pendingTransaction) {
                continue
            }

            if transactions[pendingTransaction]?.isReadOnly == true {
                // A pending read-only transaction is only blocked by an overlapping in-progress write.
                if !inProgressIsReadOnly
                    && objectStoreIdentifiers(ofTransaction: pendingTransaction).contains(where: inProgressScopes.contains)
                {
                    return true
                }
                continue
            }
            // A pending read-write transaction is blocked by any overlapping in-progress transaction,
            // or by any in-progress read-write transaction if the backing store serializes writes.
            if objectStoreIdentifiers(ofTransaction: pendingTransaction).contains(where: inProgressScopes.contains) {
                return true
            }
            if !inProgressIsReadOnly && serializesReadWrites {
                return true
            }
        }

        return false
    }

    func handleTransactionsAfterAbortingSuspendedClientTransactions() {
        if abortInProgressTransactionsOfSuspendedClientsIfNeeded() {
            // Previously blocked requests might be able to run now.
            handleDatabaseOperations()
        }

        handleTransactions()
    }

    /// Whether any transaction was aborted.
    private func abortInProgressTransactionsOfSuspendedClientsIfNeeded() -> Bool {
        assert(!isAbortingTransactionsOfSuspendedClients)
        isAbortingTransactionsOfSuspendedClients = true
        defer {
            isAbortingTransactionsOfSuspendedClients = false
        }

        if pendingTransactions.isEmpty || inProgressTransactions.isEmpty {
            return false
        }

        let transactionsToAbort = inProgressTransactions.values.filter {
            isTransactionOfSuspendedClient($0) && transactionBlocksPendingTransactions($0)
        }

        var abortedAnyTransaction = false
        for serial in transactionsToAbort {
            guard let transactionIdentifier = transactions[serial]?.identifier,
                let takenTransaction = inProgressTransactions.removeValue(forKey: transactionIdentifier)
            else {
                continue
            }

            // Aborting a versionchange transaction must roll back the in-memory schema and clear the
            // version-change connection, matching the standard abort path, so an interrupted upgrade
            // doesn't leave the database in an inconsistent state. transactionCompleted() below clears
            // versionChangeTransaction.
            if let versionChangeTransaction, let versionChange = transactions[versionChangeTransaction],
                versionChange.identifier == transactionIdentifier
            {
                guard let originalDatabaseInfo = versionChange.originalDatabaseInfo else {
                    preconditionFailure()
                }
                databaseInfo = originalDatabaseInfo
                setVersionChangeConnectionToNil()
            }

            // A null error means the abort succeeded. If
            // the backing store is already gone there is nothing left to abort, so don't surface an
            // internal error to the page when the client later learns about the suspension abort.
            var error = WebCore.makeIDBServerNoError()
            if let store {
                error = store.abortTransaction(transactionIdentifier)
            }
            transactions[serial]?.setSuspensionAbortResult(error)

            // The transaction object stays in its connection's transaction map so a client that
            // later resumes can still abort or commit it and learn about the suspension abort.
            transactionCompleted(serial: takenTransaction, startRunnableWork: false)
            release(transaction: takenTransaction, from: .inProgress)
            abortedAnyTransaction = true
        }

        return abortedAnyTransaction
    }

    /// Removes the transaction once nothing holds it, unregistering it first.
    func release(transaction serial: IDBEntitySerial, from holder: UniqueIDBDatabaseTransaction.Holders) {
        guard let holders = transactions[serial]?.holders.subtracting(holder) else {
            return
        }

        transactions[serial]?.holders = holders
        guard holders.isEmpty, let transaction = transactions.removeValue(forKey: serial) else {
            return
        }

        if connections[transaction.databaseConnection] != nil {
            router.unregisterTransaction(transaction.identifier)
        }
    }

    /// Removes the connection once nothing holds it, unregistering it first.
    func release(connection identifier: WebCore.IDBDatabaseConnectionIdentifier, from holder: UniqueIDBDatabaseConnection.Holders) {
        guard let holders = connections[identifier]?.holders.subtracting(holder) else {
            return
        }

        connections[identifier]?.holders = holders
        guard holders.isEmpty, let connection = connections[identifier] else {
            return
        }

        assert(connection.transactionSerials.isEmpty)
        router.unregisterConnection(identifier)
        connection.connectionToClient.unregisterDatabaseConnection(identifier)
        let transactionSerials = connection.transactionSerials
        connection.transactionSerials = [:]
        for serial in transactionSerials.values {
            release(transaction: serial, from: .connection)
        }
        connections[identifier] = nil
    }

    func release(openRequest serial: IDBEntitySerial, from holder: ServerOpenDBRequest.Holders) {
        guard let holders = openRequests[serial]?.holders.subtracting(holder) else {
            return
        }

        openRequests[serial]?.holders = holders
        guard holders.isEmpty, let request = openRequests.removeValue(forKey: serial) else {
            return
        }

        if let versionChangeTransaction = request.versionChangeTransaction {
            release(transaction: versionChangeTransaction, from: .openRequest)
        }
    }
}
