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
internal import WebCore_Private.Core.IDBConnectionToClientDelegate
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBDatabaseNameAndVersion
internal import WebCore_Private.Core.IDBGetAllRecordsData
internal import WebCore_Private.Core.IDBGetRecordData
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBIterateCursorData
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBOpenRequestData
internal import WebCore_Private.Core.IDBRequestData
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IDBValue
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SQLiteIDBStoreTypes
internal import WebCore_Private.Core.SecurityOriginData
internal import WebCore_Private.Core.SwiftIDBTypes

/// The in-process IndexedDB server of WebKitLegacy: one per InProcessIDBServer, used on its queue only.
///
/// C++ calls the `@_expose(Cxx)` methods below with the requests IDBServer received; results go back through the
/// delegates added with `registerConnection`.
@_expose(Cxx)
public final class SwiftIDBServer {
    private let databaseDirectoryPath: WTF.String
    private let router: IDBServerRouter
    private let core: IDBServerCore

    /// Creates the server of the databases under `databaseDirectoryPath`, which asks `requestSpace` for quota.
    ///
    /// `databaseDirectoryPath` is borrowed: the only caller is the convenience initializer below, which passes its own
    /// consuming parameter, so Swift owns the value for the call. What is kept (the stored path and the store factory's
    /// capture) is copied.
    init(databaseDirectoryPath: WTF.String, requestSpace: @escaping (WebCore.ClientOrigin, UInt64) -> Bool) {
        self.databaseDirectoryPath = databaseDirectoryPath
        router = IDBServerRouter(policy: .overwrite)
        core = IDBServerCore(
            router: router,
            requestSpace: { origin, size, completion in
                completion(requestSpace(origin, size))
            },
            makeStore: { identifier in
                SwiftIDBServer.backingStoreKind(databaseDirectoryPath: databaseDirectoryPath, identifier)
            }
        )
        SwiftIDBServer.upgradeFilesIfNecessary(databaseDirectoryPath)
    }

    /// The C++ space requester, held for the server's life.
    @_expose(Cxx)
    public convenience init(databaseDirectoryPath: consuming WTF.String, spaceRequester: consuming WebCore.IDBSpaceRequesterHolder) {
        let requester = spaceRequester
        self.init(databaseDirectoryPath: databaseDirectoryPath) { origin, size in
            requester.request(origin, size)
        }
    }

    deinit {
        // The in-process server has no closing state: its databases close with the space requester still answering.
        core.close(markingClosing: false)
    }

    /// Adds the connection to a client, whose results go to `delegate`.
    ///
    /// The delegate's identifier names the connection in every later request from that client.
    @_expose(Cxx)
    public func registerConnection(_ delegate: WebCore.IDBServer.IDBConnectionToClientDelegate) {
        router.addConnectionToClient(delegate: delegate)
    }

    /// Closes the client's database connections and forgets its connection, as IDBServer::unregisterConnection does.
    @_expose(Cxx)
    public func unregisterConnection(_ identifier: consuming WebCore.IDBConnectionIdentifier) {
        router.removeConnectionToClient(identifier)
    }

    /// Records that the client is, or is no longer, suspended.
    ///
    /// WebKitLegacy never suspends its clients.
    @_expose(Cxx)
    public func setClientSuspended(_ identifier: consuming WebCore.IDBConnectionIdentifier, _ isSuspended: Bool) {
        router.setClientSuspended(identifier, isSuspended)
    }

    /// Opens or creates the database the request names and answers through the requesting connection.
    ///
    /// A request whose connection to the client is gone is dropped, as there is no way to report failure.
    @_expose(Cxx)
    public func openDatabase(_ requestData: consuming WebCore.IDBOpenRequestData) {
        let database = core.getOrCreateDatabase(requestData.databaseIdentifier())

        guard let connectionIdentifier = Optional(fromCxx: requestData.requestIdentifier().connectionIdentifier()) else {
            return
        }

        guard let connection = router.connectionToClient(connectionIdentifier) else {
            // If the connection back to the client is gone, there's no way to open the database as
            // well as no way to message back failure.
            return
        }

        database.enqueueOpenRequest(connection, requestData)
    }

    /// Deletes the database the request names, and forgets it if no connection keeps it open.
    ///
    /// A request whose connection to the client is gone is dropped, as there is no way to report failure.
    @_expose(Cxx)
    public func deleteDatabase(_ requestData: consuming WebCore.IDBOpenRequestData) {
        guard let connectionIdentifier = Optional(fromCxx: requestData.requestIdentifier().connectionIdentifier()) else {
            return
        }

        guard let connection = router.connectionToClient(connectionIdentifier) else {
            // If the connection back to the client is gone, there's no way to delete the database as
            // well as no way to message back failure.
            return
        }

        let database = core.getOrCreateDatabase(requestData.databaseIdentifier())
        database.enqueueOpenRequest(connection, requestData)
        core.removeDatabaseIfClosed(database)
    }

    /// Aborts the transaction, which must still be running; an unknown identifier is ignored, as nothing can carry the failure back.
    @_expose(Cxx)
    public func abortTransaction(_ transactionIdentifier: consuming WebCore.IDBResourceIdentifier) {
        guard let transaction = router.transaction(transactionIdentifier) else {
            // If there is no transaction there is nothing to abort.
            // We also have no access to a connection over which to message failure-to-abort.
            return
        }

        transaction.abort()
    }

    /// Commits the transaction once `handledRequestResultsCount` results have been handled by the client.
    ///
    /// An unknown identifier is ignored, as nothing can carry the failure back.
    @_expose(Cxx)
    public func commitTransaction(_ transactionIdentifier: consuming WebCore.IDBResourceIdentifier, _ handledRequestResultsCount: UInt64) {
        guard let transaction = router.transaction(transactionIdentifier) else {
            // If there is no transaction there is nothing to commit.
            // We also have no access to a connection over which to message failure-to-commit.
            return
        }

        transaction.commit(handledRequestResultsCount)
    }

    /// Tells the database that the client finished its version change event handlers, so the transaction can complete.
    @_expose(Cxx)
    public func didFinishHandlingVersionChangeTransaction(
        _ connection: consuming WebCore.IDBDatabaseConnectionIdentifier,
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier
    ) {
        router.databaseConnection(connection)?.didFinishHandlingVersionChange(transactionIdentifier)
    }

    /// The transaction a request names, if its database still holds it.
    private func transaction(_ requestData: borrowing WebCore.IDBRequestData) -> IDBTransactionHandle? {
        router.transaction(requestData.transactionIdentifier())
    }

    /// The request's transaction, which must be a version change, if its database still holds it.
    private func versionChangeTransaction(_ requestData: borrowing WebCore.IDBRequestData) -> IDBTransactionHandle? {
        let transaction = transaction(requestData)
        assert(transaction?.isVersionChange ?? true)
        return transaction
    }

    /// Creates an object store in the request's version change transaction.
    ///
    /// `requestData` and `info` are borrowed: `IDBServer::createObjectStore` passes `const&` to the
    /// `InProcessIDBServer` task's isolated copies, on the server's queue. While they are live, Swift calls the
    /// router, the store, the delegate (which posts a reply task) and the quota check (which may complete
    /// synchronously and re-enter Swift); none of them reaches the task's captures. What is kept past the call is
    /// copied.
    @_expose(Cxx)
    public func createObjectStore(_ requestData: WebCore.IDBRequestData, _ info: WebCore.IDBObjectStoreInfo) {
        versionChangeTransaction(requestData)?.createObjectStore(requestData, info)
    }

    /// Renames an object store in the request's version change transaction.
    @_expose(Cxx)
    public func renameObjectStore(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ newName: consuming WTF.String
    ) {
        versionChangeTransaction(requestData)?.renameObjectStore(requestData, objectStoreIdentifier, newName)
    }

    /// Deletes the named object store in the request's version change transaction.
    @_expose(Cxx)
    public func deleteObjectStore(_ requestData: consuming WebCore.IDBRequestData, _ objectStoreName: consuming WTF.String) {
        versionChangeTransaction(requestData)?.deleteObjectStore(requestData, objectStoreName)
    }

    /// Removes every record of an object store in the request's transaction.
    @_expose(Cxx)
    public func clearObjectStore(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) {
        transaction(requestData)?.clearObjectStore(requestData, objectStoreIdentifier)
    }

    /// Creates an index in the request's version change transaction.
    @_expose(Cxx)
    public func createIndex(_ requestData: consuming WebCore.IDBRequestData, _ info: consuming WebCore.IDBIndexInfo) {
        versionChangeTransaction(requestData)?.createIndex(requestData, info)
    }

    /// Deletes the named index of an object store in the request's version change transaction.
    @_expose(Cxx)
    public func deleteIndex(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexName: consuming WTF.String
    ) {
        versionChangeTransaction(requestData)?.deleteIndex(requestData, objectStoreIdentifier, indexName)
    }

    /// Renames an index of an object store in the request's version change transaction.
    @_expose(Cxx)
    public func renameIndex(
        _ requestData: consuming WebCore.IDBRequestData,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier,
        _ newName: consuming WTF.String
    ) {
        versionChangeTransaction(requestData)?.renameIndex(requestData, objectStoreIdentifier, indexIdentifier, newName)
    }

    /// Stores a record, with its index keys, in the request's transaction.
    ///
    /// The overwrite mode decides whether an existing key is replaced or the request fails.
    ///
    /// `indexKeys` is borrowed: `IDBServer::putOrAdd` passes `const&` to the `InProcessIDBServer` task's isolated
    /// copy, on the server's queue. While it is live, Swift calls the router, the store, the delegate (which posts a
    /// reply task) and the quota check (which may complete synchronously and re-enter Swift); none of them reaches
    /// the task's captures. What is kept past the call is copied.
    @_expose(Cxx)
    public func putOrAdd(
        _ requestData: consuming WebCore.IDBRequestData,
        _ key: consuming WebCore.IDBKeyData,
        _ value: consuming WebCore.IDBValue,
        _ indexKeys: WebCore.IndexIDToIndexKeyMap,
        _ overwriteMode: WebCore.IndexedDB.ObjectStoreOverwriteMode
    ) {
        router.putOrAdd(transaction: requestData.transactionIdentifier(), requestData, key, value, indexKeys, overwriteMode)
    }

    /// Reads one record, or its key, in the request's transaction.
    @_expose(Cxx)
    public func getRecord(_ requestData: consuming WebCore.IDBRequestData, _ getRecordData: consuming WebCore.IDBGetRecordData) {
        router.getRecord(transaction: requestData.transactionIdentifier(), requestData, getRecordData)
    }

    /// Reads the records, or the keys, of a range in the request's transaction.
    @_expose(Cxx)
    public func getAllRecords(_ requestData: consuming WebCore.IDBRequestData, _ getAllRecordsData: consuming WebCore.IDBGetAllRecordsData)
    {
        transaction(requestData)?.getAllRecords(requestData, getAllRecordsData)
    }

    /// Counts the records in a key range in the request's transaction.
    @_expose(Cxx)
    public func getCount(_ requestData: consuming WebCore.IDBRequestData, _ range: consuming WebCore.IDBKeyRangeData) {
        transaction(requestData)?.getCount(requestData, range)
    }

    /// Deletes the records in a key range in the request's transaction.
    @_expose(Cxx)
    public func deleteRecord(_ requestData: consuming WebCore.IDBRequestData, _ range: consuming WebCore.IDBKeyRangeData) {
        transaction(requestData)?.deleteRecord(requestData, range)
    }

    /// Opens a cursor on a store or index in the request's transaction.
    @_expose(Cxx)
    public func openCursor(_ requestData: consuming WebCore.IDBRequestData, _ info: consuming WebCore.IDBCursorInfo) {
        transaction(requestData)?.openCursor(requestData, info)
    }

    /// Moves an open cursor on in the request's transaction.
    @_expose(Cxx)
    public func iterateCursor(_ requestData: consuming WebCore.IDBRequestData, _ data: consuming WebCore.IDBIterateCursorData) {
        transaction(requestData)?.iterateCursor(requestData, data)
    }

    /// Starts a transaction on a database connection, and forgets the database if that left it unused.
    @_expose(Cxx)
    public func establishTransaction(
        _ connection: consuming WebCore.IDBDatabaseConnectionIdentifier,
        _ info: __owned WebCore.IDBTransactionInfo
    ) {
        guard let databaseConnection = router.databaseConnection(connection),
            let databaseIdentifier = databaseConnection.databaseIdentifier
        else {
            return
        }

        databaseConnection.establishTransaction(info)
        core.tryCloseDatabase(databaseIdentifier)
    }

    /// Marks the connection as closing, so that blocked open and delete requests can go on once it ends.
    @_expose(Cxx)
    public func databaseConnectionPendingClose(_ connection: consuming WebCore.IDBDatabaseConnectionIdentifier) {
        router.databaseConnection(connection)?.connectionPendingCloseFromClient()
    }

    /// Closes the database connection the client closed, and forgets its database if that left it unused.
    @_expose(Cxx)
    public func databaseConnectionClosed(_ connection: consuming WebCore.IDBDatabaseConnectionIdentifier) {
        guard let databaseConnection = router.databaseConnection(connection),
            let databaseIdentifier = databaseConnection.databaseIdentifier
        else {
            return
        }

        databaseConnection.connectionClosedFromClient()
        core.tryCloseDatabase(databaseIdentifier)
    }

    /// Aborts the version change transaction a client abandoned, if it names one, and closes the connection it was opened on.
    @_expose(Cxx)
    public func abortOpenAndUpgradeNeeded(
        _ connection: consuming WebCore.IDBDatabaseConnectionIdentifier,
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier?
    ) {
        if let transactionIdentifier {
            router.transaction(transactionIdentifier)?.abortWithoutCallback()
        }

        router.databaseConnection(connection)?.connectionClosedFromClient()
    }

    /// Records that the client fired the version change event of a pending request at the connection.
    ///
    /// `connectionClosed` says whether the client closed the connection in answer, so that the server need not wait for it.
    @_expose(Cxx)
    public func didFireVersionChangeEvent(
        _ connection: consuming WebCore.IDBDatabaseConnectionIdentifier,
        _ requestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ connectionClosed: WebCore.IndexedDB.ConnectionClosedOnBehalfOfServer
    ) {
        router.databaseConnection(connection)?.didFireVersionChangeEvent(requestIdentifier, connectionClosed)
    }

    /// Hands the transaction the index key the client computed for a record while an index was being created.
    @_expose(Cxx)
    public func didGenerateIndexKeyForRecord(
        _ transactionIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ requestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ indexInfo: consuming WebCore.IDBIndexInfo,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKey: consuming WebCore.IndexKey,
        _ recordID: Int64?
    ) {
        router.transaction(transactionIdentifier)?.didGenerateIndexKeyForRecord(requestIdentifier, indexInfo, key, indexKey, recordID)
    }

    /// Drops a pending open or delete request the client gave up on, and forgets its database if that left it unused.
    @_expose(Cxx)
    public func openDBRequestCancelled(_ requestData: consuming WebCore.IDBOpenRequestData) {
        guard let database = core.databases[requestData.databaseIdentifier()] else {
            return
        }

        database.openDBRequestCancelled(requestData.requestIdentifier())
        core.removeDatabaseIfClosed(database)
    }

    /// Answers `indexedDB.databases()` for an origin with the open databases and those only on disk.
    ///
    /// The databases of both file versions, `v0` and `v1`, are listed, with the open ones first.
    @_expose(Cxx)
    public func getAllDatabaseNamesAndVersions(
        _ connection: consuming WebCore.IDBConnectionIdentifier,
        _ requestIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ origin: consuming WebCore.ClientOrigin
    ) {
        var (result, visitedDatabasePaths) = core.openDatabaseNamesAndVersions(origin: copy origin)

        let oldDirectory = WebCore.idbOriginDirectoryRelativeToRoot(origin, databaseDirectoryPath, true)
        SwiftIDBServer.databaseNamesAndVersionsInOriginDirectory(oldDirectory, visitedDatabasePaths, &result)

        let directory = WebCore.idbOriginDirectoryRelativeToRoot(origin, databaseDirectoryPath, false)
        SwiftIDBServer.databaseNamesAndVersionsInOriginDirectory(directory, visitedDatabasePaths, &result)

        router.connectionToClient(connection)?.didGetAllDatabaseNamesAndVersions(requestIdentifier, result)
    }

    // MARK: Origins and files

    /// The security origins that have databases on disk, found in both file versions of the database directory.
    @_expose(Cxx)
    public func getOrigins() -> WebCore.SecurityOriginDataVector {
        var securityOrigins = WebCore.SecurityOriginDataVector()
        if databaseDirectoryPath.isEmpty() {
            return securityOrigins
        }

        SwiftIDBServer.collectOrigins(
            inVersionPath: WebCore.sqliteIDBPathByAppendingComponent(databaseDirectoryPath, sqliteIDBString("v0")),
            &securityOrigins
        )
        SwiftIDBServer.collectOrigins(
            inVersionPath: WebCore.sqliteIDBPathByAppendingComponent(databaseDirectoryPath, sqliteIDBString("v1")),
            &securityOrigins
        )
        return securityOrigins
    }

    /// Closes every database and deletes the files modified since `time`.
    ///
    /// A time in the future deletes nothing.
    @_expose(Cxx)
    public func closeAndDeleteDatabasesModifiedSince(_ time: WTF.WallTime) {
        // If the modification time is in the future, don't bother doing anything.
        if WebCore.idbWallTimeIsInFuture(time) {
            return
        }

        core.closeDatabasesForDeletion()

        if !databaseDirectoryPath.isEmpty() {
            removeDatabasesModifiedSince(time, version: "v0")
            removeDatabasesModifiedSince(time, version: "v1")
        }
    }

    /// The bytes the origin's databases take on disk under `rootDirectory`, in both file versions.
    @_expose(Cxx)
    public static func diskUsage(_ rootDirectory: consuming WTF.String, _ origin: consuming WebCore.ClientOrigin) -> UInt64 {
        let oldVersionOriginDirectory = WebCore.idbOriginDirectoryRelativeToRoot(origin, rootDirectory, true)
        let newVersionOriginDirectory = WebCore.idbOriginDirectoryRelativeToRoot(origin, rootDirectory, false)
        return SQLiteIDBStore.databasesSizeForDirectory(oldVersionOriginDirectory)
            + SQLiteIDBStore.databasesSizeForDirectory(newVersionOriginDirectory)
    }

    // MARK: The backing store's directory

    /// Where a database's store lives: in memory without a directory or for a transient database, else in SQLite.
    private static func backingStoreKind(
        databaseDirectoryPath: WTF.String,
        _ identifier: WebCore.IDBDatabaseIdentifier
    ) -> IDBBackingStoreKind {
        if databaseDirectoryPath.isEmpty() || identifier.isTransient() {
            return .memory
        }

        return .sqlite(databaseDirectory: upgradedDatabaseDirectory(databaseDirectoryPath, identifier))
    }

    private static func upgradeFilesIfNecessary(_ databaseDirectoryPath: WTF.String) {
        if databaseDirectoryPath.isEmpty() || !WebCore.sqliteIDBFileExists(databaseDirectoryPath) {
            return
        }

        let newVersionDirectory = WebCore.sqliteIDBPathByAppendingComponent(databaseDirectoryPath, sqliteIDBString("v1"))
        if !WebCore.sqliteIDBFileExists(newVersionDirectory) {
            _ = WebCore.idbMakeAllDirectories(newVersionDirectory)
        }
    }

    private static func upgradedDatabaseDirectory(
        _ databaseDirectoryPath: WTF.String,
        _ identifier: WebCore.IDBDatabaseIdentifier
    ) -> WTF.String {
        let oldOriginDirectory = WebCore.idbDatabaseDirectoryRelativeToRoot(identifier, databaseDirectoryPath, true)
        let oldDatabaseDirectory = WebCore.sqliteIDBPathByAppendingComponent(
            oldOriginDirectory,
            SQLiteIDBStore.encodeDatabaseName(WebCore.idbDatabaseIdentifierDatabaseName(identifier))
        )
        let newOriginDirectory = WebCore.idbDatabaseDirectoryRelativeToRoot(identifier, databaseDirectoryPath, false)
        let fileNameHash = WebCore.idbComputeHashForFileName(WebCore.idbDatabaseIdentifierDatabaseName(identifier))
        let newDatabaseDirectory = WebCore.sqliteIDBPathByAppendingComponent(newOriginDirectory, fileNameHash)
        _ = WebCore.idbMakeAllDirectories(newDatabaseDirectory)

        if WebCore.sqliteIDBFileExists(oldDatabaseDirectory) {
            _ = WebCore.idbMoveFile(oldDatabaseDirectory, newDatabaseDirectory)
            _ = WebCore.idbDeleteEmptyDirectory(oldOriginDirectory)
        }

        return newDatabaseDirectory
    }

    // MARK: Directory walks

    private static func databaseNamesAndVersionsInOriginDirectory(
        _ directory: WTF.String,
        _ excludedDatabasePaths: [WTF.String],
        _ result: inout [WebCore.IDBDatabaseNameAndVersion]
    ) {
        let databaseDirectoryNames = WebCore.sqliteIDBListDirectory(directory)
        for i in 0..<WebCore.idbStringVectorSize(databaseDirectoryNames) {
            let databaseDirectoryName = WebCore.idbStringVectorAt(databaseDirectoryNames, i)
            let fullDatabasePath = SQLiteIDBStore.fullDatabasePathForDirectory(
                WebCore.sqliteIDBPathByAppendingComponent(directory, databaseDirectoryName)
            )
            if excludedDatabasePaths.contains(where: { WebCore.idbStringEqual($0, fullDatabasePath) }) {
                continue
            }

            if let (name, version) = SQLiteIDBStore.databaseNameAndVersionFromFile(fullDatabasePath) {
                result.append(WebCore.makeSQLiteIDBNameAndVersion(name, version))
            }
        }
    }

    private static func collectOrigins(inVersionPath versionPath: WTF.String, _ securityOrigins: inout WebCore.SecurityOriginDataVector) {
        let databaseIdentifiers = WebCore.sqliteIDBListDirectory(versionPath)
        for i in 0..<WebCore.idbStringVectorSize(databaseIdentifiers) {
            let databaseIdentifier = WebCore.idbStringVectorAt(databaseIdentifiers, i)
            guard let securityOrigin = IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: databaseIdentifier) else {
                continue
            }
            WebCore.appendSecurityOriginData(&securityOrigins, securityOrigin)

            let innerIdentifiers = WebCore.sqliteIDBListDirectory(
                WebCore.sqliteIDBPathByAppendingComponent(versionPath, databaseIdentifier)
            )
            for j in 0..<WebCore.idbStringVectorSize(innerIdentifiers) {
                if let innerOrigin = IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: WebCore.idbStringVectorAt(innerIdentifiers, j)) {
                    WebCore.appendSecurityOriginData(&securityOrigins, innerOrigin)
                }
            }
        }
    }

    private func removeDatabasesModifiedSince(_ modifiedSince: WTF.WallTime, version: Swift.String) {
        let versionPath = WebCore.sqliteIDBPathByAppendingComponent(databaseDirectoryPath, sqliteIDBString(version))
        let databaseIdentifiers = WebCore.sqliteIDBListDirectory(versionPath)
        for i in 0..<WebCore.idbStringVectorSize(databaseIdentifiers) {
            let databaseIdentifier = WebCore.idbStringVectorAt(databaseIdentifiers, i)
            if IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: databaseIdentifier) != nil {
                SwiftIDBServer.removeAllDatabases(
                    forOriginPath: WebCore.sqliteIDBPathByAppendingComponent(versionPath, databaseIdentifier),
                    modifiedSince
                )
            }
        }
    }

    private static func removeAllDatabases(forOriginPath originPath: WTF.String, _ modifiedSince: WTF.WallTime) {
        let databaseIdentifier = WebCore.idbLastComponentOfPathIgnoringTrailingSlash(originPath)
        if IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: databaseIdentifier) == nil {
            return
        }

        let directoryNames = WebCore.sqliteIDBListDirectory(originPath)
        for i in 0..<WebCore.idbStringVectorSize(directoryNames) {
            let directoryName = WebCore.idbStringVectorAt(directoryNames, i)
            if IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: directoryName) != nil {
                removeAllDatabases(forFullOriginPath: WebCore.sqliteIDBPathByAppendingComponent(originPath, directoryName), modifiedSince)
            }
        }

        removeAllDatabases(forFullOriginPath: originPath, modifiedSince)
    }

    private static func removeAllDatabases(forFullOriginPath originPath: WTF.String, _ modifiedSince: WTF.WallTime) {
        let databaseNames = WebCore.sqliteIDBListDirectory(originPath)

        for i in 0..<WebCore.idbStringVectorSize(databaseNames) {
            let databaseName = WebCore.idbStringVectorAt(databaseNames, i)
            let databasePath = WebCore.sqliteIDBPathByAppendingComponent(originPath, databaseName)
            let databaseFile = WebCore.sqliteIDBPathByAppendingComponent(databasePath, sqliteIDBString("IndexedDB.sqlite3"))
            if WebCore.idbWallTimeIsAboveNegativeInfinity(modifiedSince) && WebCore.sqliteIDBFileExists(databaseFile) {
                if WebCore.idbFileIsUnmodifiedSince(databaseFile, modifiedSince) {
                    continue
                }
            }

            // Deleting this database means we need to delete all files that represent it.
            // This includes:
            //     - The directory itself, which is named after the database.
            //     - IndexedDB.sqlite3 and related SQLite files.
            //     - Blob files that we stored in the directory.
            //
            // To be conservative, we should *not* try to delete files that are unexpected;
            // We should only delete files we think we put there.
            let fileNames = WebCore.sqliteIDBListDirectory(databasePath)
            for j in 0..<WebCore.idbStringVectorSize(fileNames) {
                let fileName = WebCore.idbStringVectorAt(fileNames, j)
                // IndexedDB blob files are named "N.blob" where N is a decimal integer,
                // so those are the only blob files we should be trying to delete.
                let fileNameLength = WebCore.idbStringLength(fileName)
                if fileNameLength < 6 {
                    continue
                }
                if !WebCore.idbStringEndsWithBlobSuffix(fileName) {
                    continue
                }

                var validFileName = true
                for k in 0..<(fileNameLength - 5) where !WebCore.idbStringHasASCIIDigitAt(fileName, k) {
                    validFileName = false
                    break
                }

                if validFileName {
                    WebCore.sqliteIDBDeleteFile(WebCore.sqliteIDBPathByAppendingComponent(databasePath, fileName))
                }
            }

            // Now delete IndexedDB.sqlite3 and related SQLite files.
            WebCore.idbDeleteSQLiteDatabaseFile(databaseFile)

            // And finally, if we can, delete the empty directory.
            _ = WebCore.idbDeleteEmptyDirectory(databasePath)
        }

        // If no databases remain for this origin, we can delete the origin directory as well.
        _ = WebCore.idbDeleteEmptyDirectory(originPath)
    }
}

/// The file-system functions of the SQLite backing store that the network process's storage manager calls.
@_spi(IDBServer)
public enum IDBDatabaseFiles {
    /// The origin a directory's name encodes, or nil for a name that encodes none.
    public static func securityOrigin(ofDatabaseIdentifier identifier: WTF.String) -> WebCore.SecurityOriginData? {
        Optional(fromCxx: WebCore.idbSecurityOriginFromDatabaseIdentifier(identifier))
    }

    /// The database name that the name of a SQLite store's directory encodes; the storage manager hashes it when it migrates an origin.
    public static func decodeDatabaseName(_ encodedName: WTF.String) -> WTF.String {
        SQLiteIDBStore.decodeDatabaseName(encodedName)
    }

    /// The bytes the databases in an origin's `directory` take on disk, which the storage manager reports as the origin's size.
    public static func databasesSize(forDirectory directory: WTF.String) -> UInt64 {
        SQLiteIDBStore.databasesSizeForDirectory(directory)
    }

    /// The path of the database file in a database's `directory`, whose name the SQLite store fixes.
    public static func fullDatabasePath(forDirectory directory: WTF.String) -> WTF.String {
        SQLiteIDBStore.fullDatabasePathForDirectory(directory)
    }

    /// Nil when the file does not open, has no metadata, or has version 0.
    public static func nameAndVersion(fromFile databasePath: WTF.String) -> (WTF.String, UInt64)? {
        SQLiteIDBStore.databaseNameAndVersionFromFile(databasePath)
    }
}
