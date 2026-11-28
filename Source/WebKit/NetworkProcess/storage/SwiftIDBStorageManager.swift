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
#if canImport(os)
import os

private let indexedDBLog = os.Logger(subsystem: "com.apple.WebKit", category: "IndexedDB")
#endif

// One origin's IndexedDB databases in the network process.
@_expose(Cxx)
final class IDBStorageManager {
    private let path: WTF.String
    private let router: IDBServerRouter
    private let core: IDBServerCore

    @used
    init(
        path: consuming WTF.String,
        registry: IDBStorageRegistry,
        quotaCheck: consuming WebKit.IDBQuotaCheckHolder,
        useSQLiteMemoryBackingStore: Bool
    ) {
        let managerPath = path
        let quota = quotaCheck
        self.path = managerPath
        router = registry.router
        core = IDBServerCore(
            router: registry.router,
            requestSpace: { _, size, completion in
                quota.request(size, consuming: WTF.BoolCompletionHandler(completion))
            },
            makeStore: { identifier in
                IDBStorageManager.backingStoreKind(managerPath, useSQLiteMemoryBackingStore, identifier)
            }
        )
    }

    deinit {
        // The destructor marks the manager closing, then closes every database while it is alive.
        core.close(markingClosing: true)
    }

    private static func backingStoreKind(
        _ path: WTF.String,
        _ useSQLiteMemoryBackingStore: Bool,
        _ identifier: WebCore.IDBDatabaseIdentifier
    ) -> IDBBackingStoreKind {
        if path.isEmpty() || identifier.isTransient() {
            if useSQLiteMemoryBackingStore {
                return .sqliteMemory
            }
            return .memory
        }

        let name = WebCore.idbComputeHashForFileName(WebCore.idbDatabaseIdentifierDatabaseName(identifier))
        return .sqlite(databaseDirectory: WebCore.sqliteIDBPathByAppendingComponent(path, name))
    }

    // MARK: Directories

    private static func migrateOriginData(
        _ oldOriginDirectory: WTF.String,
        _ newOriginDirectory: WTF.String,
        _ createFileName: (WTF.String) -> WTF.String
    ) -> Bool {
        if oldOriginDirectory.isEmpty() || !WebCore.sqliteIDBFileExists(oldOriginDirectory) {
            return true
        }

        let fileNames = WebCore.sqliteIDBListDirectory(oldOriginDirectory)
        if WebCore.idbStringVectorSize(fileNames) == 0 {
            _ = WebCore.idbDeleteEmptyDirectory(oldOriginDirectory)
            return true
        }

        _ = WebCore.idbMakeAllDirectories(newOriginDirectory)
        var allMoved = true
        for i in 0..<WebCore.idbStringVectorSize(fileNames) {
            let name = WebCore.idbStringVectorAt(fileNames, i)
            // This is an origin directory for third-party data.
            if IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: name) != nil {
                continue
            }

            // Do not overwrite existing files.
            let newPath = WebCore.sqliteIDBPathByAppendingComponent(newOriginDirectory, createFileName(name))
            if WebCore.sqliteIDBFileExists(newPath) {
                continue
            }

            let oldPath = WebCore.sqliteIDBPathByAppendingComponent(oldOriginDirectory, name)
            if !WebCore.idbMoveFile(oldPath, newPath) {
                allMoved = false
            }
        }

        _ = WebCore.idbDeleteEmptyDirectory(oldOriginDirectory)
        return allMoved
    }

    @used
    static func createVersionDirectoryIfNeeded(_ rootDirectory: WTF.String) {
        if rootDirectory.isEmpty() {
            return
        }

        var oldVersionDirectoryExists = false
        var oldVersionNames: [WTF.String] = []
        let fileNames = WebCore.sqliteIDBListDirectory(rootDirectory)
        for i in 0..<WebCore.idbStringVectorSize(fileNames) {
            let name = WebCore.idbStringVectorAt(fileNames, i)
            let isV0 = WebCore.idbStringEqual(name, WebCore.idbOldVersionDirectoryName())
            if isV0 {
                oldVersionDirectoryExists = true
            }
            if !isV0 && !WebCore.idbStringEqual(name, WebCore.idbCurrentVersionDirectoryName()) {
                if IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: name) != nil {
                    oldVersionNames.append(name)
                }
            }
        }

        if oldVersionNames.isEmpty && !oldVersionDirectoryExists {
            return
        }

        // Delete file or symlink named v0.
        let oldVersionDirectory = WebCore.sqliteIDBPathByAppendingComponent(rootDirectory, WebCore.idbOldVersionDirectoryName())
        switch WebCore.idbFileType(oldVersionDirectory).value {
        case .Regular:
            // v0 should not be a file in normal case.
            _ = WebCore.idbDeleteFile(oldVersionDirectory)
            oldVersionDirectoryExists = false
        case .SymbolicLink:
            _ = WebCore.idbDeleteNonEmptyDirectory(oldVersionDirectory)
            oldVersionDirectoryExists = false
        case .Directory, nil:
            break
        @unknown default:
            break
        }

        if oldVersionNames.isEmpty {
            if oldVersionDirectoryExists {
                _ = WebCore.idbDeleteEmptyDirectory(oldVersionDirectory)
            }
            return
        }

        // Migrate data to v0 directory.
        if !oldVersionDirectoryExists {
            _ = WebCore.idbMakeAllDirectories(oldVersionDirectory)
        }

        for name in oldVersionNames {
            let oldPath = WebCore.sqliteIDBPathByAppendingComponent(rootDirectory, name)
            let newPath = WebCore.sqliteIDBPathByAppendingComponent(oldVersionDirectory, name)
            _ = WebCore.idbMoveFile(oldPath, newPath)
        }
    }

    @used
    static func idbStorageOriginDirectory(_ rootDirectory: WTF.String, _ origin: WebCore.ClientOrigin) -> WTF.String {
        if rootDirectory.isEmpty() {
            return WebCore.sqliteIDBEmptyString()
        }

        let originDirectory = WebCore.idbOptionalOriginDirectoryRelativeToRoot(origin, rootDirectory, false)
        if originDirectory.isEmpty() {
            return WebCore.sqliteIDBEmptyString()
        }

        let oldOriginDirectory = WebCore.idbOptionalOriginDirectoryRelativeToRoot(origin, rootDirectory, true)
        if oldOriginDirectory.isEmpty() {
            return WebCore.sqliteIDBEmptyString()
        }

        _ = migrateOriginData(oldOriginDirectory, originDirectory) { name in
            WebCore.idbComputeHashForFileName(IDBDatabaseFiles.decodeDatabaseName(name))
        }

        return originDirectory
    }

    @used
    static func idbStorageSize(_ originDirectory: WTF.String) -> UInt64 {
        if originDirectory.isEmpty() {
            return 0
        }

        return IDBDatabaseFiles.databasesSize(forDirectory: originDirectory)
    }

    @used
    static func originsOfIDBStorageData(_ rootDirectory: WTF.String) -> WebCore.ClientOriginVector {
        var origins = WebCore.ClientOriginVector()
        if rootDirectory.isEmpty() {
            return origins
        }

        originsForVersion(WebCore.sqliteIDBPathByAppendingComponent(rootDirectory, WebCore.idbOldVersionDirectoryName()), &origins)
        originsForVersion(WebCore.sqliteIDBPathByAppendingComponent(rootDirectory, WebCore.idbCurrentVersionDirectoryName()), &origins)
        return origins
    }

    private static func originsForVersion(_ versionPath: WTF.String, _ origins: inout WebCore.ClientOriginVector) {
        let topDatabaseIdentifiers = WebCore.sqliteIDBListDirectory(versionPath)
        for i in 0..<WebCore.idbStringVectorSize(topDatabaseIdentifiers) {
            let topDatabaseIdentifier = WebCore.idbStringVectorAt(topDatabaseIdentifiers, i)
            guard let topOrigin = IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: topDatabaseIdentifier) else {
                continue
            }

            let topOriginDirectory = WebCore.sqliteIDBPathByAppendingComponent(versionPath, topDatabaseIdentifier)
            let databaseIdentifiers = WebCore.sqliteIDBListDirectory(topOriginDirectory)
            for j in 0..<WebCore.idbStringVectorSize(databaseIdentifiers) {
                let databaseIdentifier = WebCore.idbStringVectorAt(databaseIdentifiers, j)
                let originDirectory = WebCore.sqliteIDBPathByAppendingComponent(topOriginDirectory, databaseIdentifier)
                if WebCore.idbDeleteEmptyDirectory(originDirectory) {
                    continue
                }

                // This is not origin directory, but may be database directory.
                guard let clientOrigin = IDBDatabaseFiles.securityOrigin(ofDatabaseIdentifier: databaseIdentifier) else {
                    WebCore.appendClientOrigin(&origins, WebCore.idbMakeClientOrigin(topOrigin, topOrigin))
                    continue
                }

                WebCore.appendClientOrigin(&origins, WebCore.idbMakeClientOrigin(topOrigin, clientOrigin))
            }

            // We may have deleted empty children directories above, which make this directory empty.
            _ = WebCore.idbDeleteEmptyDirectory(topOriginDirectory)
        }
    }

    @used
    static func migrateOriginData(_ oldOriginDirectory: WTF.String, _ newOriginDirectory: WTF.String) -> Bool {
        migrateOriginData(oldOriginDirectory, newOriginDirectory) { name in name }
    }

    // MARK: The manager

    @used
    func isActive() -> Bool {
        core.isActive
    }

    @used
    func hasDataInMemory() -> Bool {
        core.hasDataInMemory
    }

    @used
    func closeDatabasesForDeletion() {
        core.closeDatabasesForDeletion()
    }

    @used
    func stopDatabaseActivitiesForSuspend() {
        if path.isEmpty() {
            return
        }

        core.stopDatabaseActivitiesForSuspend()
    }

    @used
    func handleLowMemoryWarning() {
        core.handleLowMemoryWarning()
    }

    @used
    func openDatabase(_ connection: WebCore.IDBConnectionIdentifier, _ requestData: consuming WebCore.IDBOpenRequestData) {
        // The registry made the connection to the client before it forwarded the request.
        guard let connectionToClient = router.connectionToClient(connection) else {
            assertionFailure("A request from a client with no connection")
            return
        }
        core.openDatabase(connection: connectionToClient, requestData)
    }

    @used
    func openDBRequestCancelled(_ requestData: consuming WebCore.IDBOpenRequestData) {
        core.openDBRequestCancelled(requestData)
    }

    @used
    func deleteDatabase(_ connection: WebCore.IDBConnectionIdentifier, _ requestData: consuming WebCore.IDBOpenRequestData) {
        // The registry made the connection to the client before it forwarded the request.
        guard let connectionToClient = router.connectionToClient(connection) else {
            assertionFailure("A request from a client with no connection")
            return
        }
        core.deleteDatabase(connection: connectionToClient, requestData)
    }

    /// Sends the names and versions of the databases in this origin's directory to the client connection.
    @used
    func getAllDatabaseNamesAndVersions(
        _ connection: WebCore.IDBConnectionIdentifier,
        _ requestIdentifier: consuming WebCore.IDBResourceIdentifier
    ) {
        let result = core.allDatabaseNamesAndVersions(inDirectory: path)
        router.connectionToClient(connection)?.didGetAllDatabaseNamesAndVersions(requestIdentifier, result)
    }

    @used
    func tryCloseDatabase(_ identifier: WebCore.IDBDatabaseIdentifier) {
        if core.tryCloseDatabase(identifier) {
            #if canImport(os)
            indexedDBLog.log("Closed database")
            #endif
        }
    }
}
