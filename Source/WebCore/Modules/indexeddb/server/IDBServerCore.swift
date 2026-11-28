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
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBDatabaseNameAndVersion
internal import WebCore_Private.Core.IDBOpenRequestData
internal import WebCore_Private.Core.SQLiteIDBStoreTypes
internal import WebCore_Private.Core.SwiftIDBTypes

/// Owns the databases of one server, and takes its space and backing store decisions from its C++ owner.
///
/// `requestSpace` asks the owner's quota for space, and `makeStore` picks the memory or SQLite backing store of each
/// database by its identifier. The in-process server and the network process's storage manager both build one, so
/// neither re-implements database lifetime.
@_spi(IDBServer)
public final class IDBServerCore {
    let router: IDBServerRouter
    let requester: IDBSpaceRequester
    let makeStore: IDBBackingStoreFactory
    var databases = IDBDatabaseRegistry()
    private(set) var isClosing = false
    /// What its databases hold instead of a weak reference to the core.
    private(set) lazy var reference = IDBServerCoreReference(self)

    /// Creates a core with no databases, whose databases register themselves with `router`.
    public init(
        router: IDBServerRouter,
        requestSpace: @escaping IDBSpaceRequester,
        makeStore: @escaping IDBBackingStoreFactory
    ) {
        self.router = router
        self.requester = requestSpace
        self.makeStore = makeStore
    }

    deinit {
        reference.coreWillDeinitialize()
    }

    /// Stops the databases; with `markingClosing`, every later space request is granted for 0 bytes and denied otherwise.
    public func close(markingClosing: Bool) {
        if markingClosing {
            isClosing = true
        }
        closeDatabases()
    }
}

extension IDBServerCore {
    /// Asks the owner for space, unless the core is closing.
    func requestSpace(origin: WebCore.ClientOrigin, size: UInt64, _ completion: @escaping (Bool) -> Void) {
        if isClosing {
            completion(size == 0)
            return
        }
        requester(origin, size, completion)
    }

    func getOrCreateDatabase(_ identifier: WebCore.IDBDatabaseIdentifier) -> UniqueIDBDatabase {
        if let database = databases[identifier] {
            return database
        }
        let database = UniqueIDBDatabase(identifier: identifier, core: self, router: router)
        databases[identifier] = database
        return database
    }

    func createBackingStore(_ identifier: WebCore.IDBDatabaseIdentifier) -> IDBServerBackingStore {
        IDBServerBackingStore(identifier: identifier, kind: makeStore(identifier))
    }

    /// Opens the database the request names, creating it first, on behalf of `connection`.
    ///
    /// The network process's storage manager calls this once it has found the connection to the client.
    public func openDatabase(connection: IDBConnectionToClient, _ requestData: consuming WebCore.IDBOpenRequestData) {
        getOrCreateDatabase(requestData.databaseIdentifier()).enqueueOpenRequest(connection, requestData)
    }

    /// Deletes the database the request names, creating its entry first so that a database that is not open is deleted from disk
    /// too, and forgets the entry if the deletion left it closed.
    public func deleteDatabase(connection: IDBConnectionToClient, _ requestData: consuming WebCore.IDBOpenRequestData) {
        let database = getOrCreateDatabase(requestData.databaseIdentifier())
        database.enqueueOpenRequest(connection, requestData)
        // This database is created for deletion.
        removeDatabaseIfClosed(database)
    }

    /// Cancels a pending open or delete request, and forgets its database if that leaves it idle.
    ///
    /// A request for a database the core no longer holds is ignored.
    public func openDBRequestCancelled(_ requestData: consuming WebCore.IDBOpenRequestData) {
        guard let database = databases[requestData.databaseIdentifier()] else {
            return
        }
        database.openDBRequestCancelled(requestData.requestIdentifier())
        // Database becomes idle after request is cancelled.
        removeDatabaseIfClosed(database)
    }

    /// Forgets the database if it can close now.
    func removeDatabaseIfClosed(_ database: UniqueIDBDatabase) {
        if database.tryClose() {
            databases[database.identifier] = nil
        }
    }

    /// Forgets the database if it can close now, and says whether it did.
    @discardableResult
    public func tryCloseDatabase(_ identifier: WebCore.IDBDatabaseIdentifier) -> Bool {
        guard let database = databases[identifier], database.tryClose() else {
            return false
        }
        databases[identifier] = nil
        return true
    }

    /// Closes every database at once, as the owner's destruction does.
    func closeDatabases() {
        for database in databases.values {
            database.immediateClose()
        }
    }

    /// Closes every database and forgets them, so that a caller can delete their files.
    ///
    /// The core stays open for space requests, unlike `close(markingClosing:)` with `true`.
    public func closeDatabasesForDeletion() {
        close(markingClosing: false)
        databases.removeAll()
    }

    /// Aborts the active transactions of every database whose store is not transient.
    public func stopDatabaseActivitiesForSuspend() {
        // Only stop databases with non-ephemeral backing store that can hold database file lock.
        for database in databases.values where !database.identifier.isTransient() {
            database.abortActiveTransactions()
        }
    }

    /// Asks every database to release what it holds in memory.
    public func handleLowMemoryWarning() {
        for database in databases.values {
            database.handleLowMemoryWarning()
        }
    }

    /// Whether any database holds data that a low memory warning can release.
    public var hasDataInMemory: Bool {
        databases.values.contains { $0.hasDataInMemory }
    }

    /// Whether the core holds any database, which keeps its owner from being treated as idle.
    public var isActive: Bool {
        !databases.isEmpty
    }

    /// The names and versions of the open databases, then those of the databases in the directories of `path` that are not open.
    public func allDatabaseNamesAndVersions(inDirectory path: WTF.String) -> [WebCore.IDBDatabaseNameAndVersion] {
        let opened = openDatabaseNamesAndVersions(origin: nil)
        var result = opened.namesAndVersions
        let visitedDatabasePaths = opened.filePaths
        let databaseIdentifiers = WebCore.sqliteIDBListDirectory(path)
        for i in 0..<WebCore.idbStringVectorSize(databaseIdentifiers) {
            let databaseDirectory = WebCore.sqliteIDBPathByAppendingComponent(path, WebCore.idbStringVectorAt(databaseIdentifiers, i))
            let databasePath = IDBDatabaseFiles.fullDatabasePath(forDirectory: databaseDirectory)
            if visitedDatabasePaths.contains(where: { WebCore.idbStringEqual($0, databasePath) }) {
                continue
            }

            if let (name, version) = IDBDatabaseFiles.nameAndVersion(fromFile: databasePath) {
                result.append(WebCore.makeSQLiteIDBNameAndVersion(name, version))
            }
        }
        return result
    }

    /// The names and versions of the open databases, of `origin` only if it is given, and their files.
    func openDatabaseNamesAndVersions(
        origin: WebCore.ClientOrigin?
    ) -> (namesAndVersions: [WebCore.IDBDatabaseNameAndVersion], filePaths: [WTF.String]) {
        var namesAndVersions: [WebCore.IDBDatabaseNameAndVersion] = []
        var filePaths: [WTF.String] = []
        for database in databases.values {
            if let origin, !(WebCore.idbDatabaseIdentifierOrigin(database.identifier) == origin) {
                continue
            }
            let path = database.filePath
            if !path.isEmpty() {
                filePaths.append(path)
            }
            if let nameAndVersion = database.nameAndVersion {
                namesAndVersions.append(nameAndVersion)
            }
        }
        return (namesAndVersions, filePaths)
    }
}
