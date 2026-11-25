// Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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

import WebKit_Internal

extension WebKit.NetworkStorageManager {
    private func isSiteAllowed(for connection: IPC.Connection, _ origin: WebCore.ClientOrigin) -> Bool {
        isSiteAllowedForConnection(connection.uniqueID(), WebCore.RegistrableDomain(origin.topOrigin))
    }

    // FIXME: Replace with MESSAGE_CHECK / MESSAGE_CHECK_COMPLETION after validating no false positives.
    private func storageSiteCheck(
        _ connection: IPC.Connection,
        _ origin: WebCore.ClientOrigin?,
        function: StaticString = #function
    ) -> Bool {
        guard let origin, isSiteAllowed(for: connection, origin) else {
            WebKit.LogChannel.Storage().releaseLog.fault("\(function.description): storage site validation failed")
            return false
        }
        return true
    }
}

// Each message's C++-decoded String argument is an IPC::CxxDecodedArgument<String>, GetFileHandleName's alias being one of them.
private typealias DecodedName = CxxDecodedArguments.NetworkStorageManager.GetFileHandleName

private func takeName(_ argument: DecodedName) -> WTF.String? {
    var name = WTF.String()
    return IPC.takeCxxDecodedString(argument, &name) ? name : nil
}

// A reply that a completion handler sends later, taken out of it once.
private final class PendingReply<Reply: ~Copyable> {
    private var reply: Reply?

    init(_ reply: consuming Reply) {
        self.reply = consume reply
    }

    func take() -> Reply? {
        reply.take()
    }
}

// MARK: The origin private file system

private typealias FileSystemHandleResult = Result<
    (FileSystemHandleGlobalIdentifier, IPCTypes.FileSystemHandleIdentifier), IPCUnexpected<IPCTypes.FileSystemStorageError>
>

private func handleResult(_ result: FileSystemStorageResult<FileSystemStorageHandleCreated>) -> FileSystemHandleResult {
    result.map { ($0.globalIdentifier, $0.identifier) }
}

// A path can hold lone surrogates, which a Swift String cannot, so these replies encode its WTF::Strings.
extension NetworkStorageManagerResolveReply {
    private typealias PathComponents = IPCCoding.StdOptional<IPCCoding.Vector<IPCCoding.CxxDecoded.String>>

    consuming func send(_ reply: FileSystemStorageResult<[WTF.String]?>) {
        send(encodedBy: {
            IPCCoding.Expected<PathComponents, IPCTypes.CxxName.WebKit_FileSystemStorageError>.encode(reply, to: $0)
        })
    }
}

extension NetworkStorageManagerGetFileReply {
    consuming func send(_ reply: FileSystemStorageResult<WTF.String>) {
        send(encodedBy: {
            IPCCoding.Expected<IPCCoding.CxxDecoded.String, IPCTypes.CxxName.WebKit_FileSystemStorageError>.encode(reply, to: $0)
        })
    }
}

extension WebKit.NetworkStorageManager {
    private func accessibleFileSystemHandle(
        _ connection: IPC.Connection,
        _ identifier: IPCTypes.FileSystemHandleIdentifier,
        function: StaticString = #function
    ) -> WebKit.FileSystemStorageHandle? {
        guard let handle = m_fileSystemStorageHandleRegistry.get().getHandle(WebCore.FileSystemHandleIdentifier(identifier.rawValue)) else {
            return nil
        }
        do throws(InvalidMessage) {
            try messageCheck("the connection may use the file system handle", function: function) {
                canConnectionAccessFileSystemHandle(connection.uniqueID(), handle)
            }
        } catch {
            markMessageInvalid(error, on: connection)
            return nil
        }
        return handle
    }

    func fileSystemGetDirectory(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        reply: consuming NetworkStorageManagerFileSystemGetDirectoryReply
    ) {
        assert(!WTF.RunLoop.isMain())
        guard storageSiteCheck(connection, origin) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        let manager = fileSystemStorageManager(origin, .Yes).get()
        reply.send(handleResult(manager.getDirectory(connection: connection.uniqueID())))
    }

    func closeHandle(connection: IPC.Connection, identifier: IPCTypes.FileSystemHandleIdentifier) {
        assert(!WTF.RunLoop.isMain())

        accessibleFileSystemHandle(connection, identifier)?.close()
    }

    func isSameEntry(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        targetIdentifier: IPCTypes.FileSystemHandleIdentifier,
        reply: consuming NetworkStorageManagerIsSameEntryReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(false)
            return
        }

        reply.send(handle.isSameEntry(targetIdentifier))
    }

    func getFileHandle(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        name: CxxDecodedArguments.NetworkStorageManager.GetFileHandleName,
        createIfNecessary: Bool,
        reply: consuming NetworkStorageManagerGetFileHandleReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier), let name = takeName(name) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        reply.send(
            handleResult(handle.getFileHandle(connection: connection.uniqueID(), name: name, createIfNecessary: createIfNecessary))
        )
    }

    func getDirectoryHandle(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        name: CxxDecodedArguments.NetworkStorageManager.GetDirectoryHandleName,
        createIfNecessary: Bool,
        reply: consuming NetworkStorageManagerGetDirectoryHandleReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier), let name = takeName(name) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        reply.send(
            handleResult(
                handle.getDirectoryHandle(connection: connection.uniqueID(), name: name, createIfNecessary: createIfNecessary)
            )
        )
    }

    func removeEntry(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        name: CxxDecodedArguments.NetworkStorageManager.RemoveEntryName,
        deleteRecursively: Bool,
        reply: consuming NetworkStorageManagerRemoveEntryReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier), let name = takeName(name) else {
            reply.send(.unknown)
            return
        }

        reply.send(handle.removeEntry(name: name, deleteRecursively: deleteRecursively))
    }

    func resolve(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        targetIdentifier: IPCTypes.FileSystemHandleIdentifier,
        reply: consuming NetworkStorageManagerResolveReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        reply.send(handle.resolve(targetIdentifier).map { components in components?.map { WTF.String(utf16Units: $0) } })
    }

    func move(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        destinationIdentifier: IPCTypes.FileSystemHandleIdentifier,
        newName: CxxDecodedArguments.NetworkStorageManager.MoveNewName,
        reply: consuming NetworkStorageManagerMoveReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier), let newName = takeName(newName) else {
            reply.send(.unknown)
            return
        }

        reply.send(handle.move(destinationIdentifier, newName: newName))
    }

    func getFile(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        reply: consuming NetworkStorageManagerGetFileReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        let path = handle.path()
        if !WTF.FileSystemImpl.fileExists(path) {
            reply.send(.failure(IPCUnexpected(.fileNotFound)))
            return
        }

        let pending = PendingReply(reply)
        allowAccessToFile(
            connection,
            consuming: path,
            consuming: WTF.VoidCompletionHandler { [path = path.isolatedCopy()] in
                if let reply = pending.take() {
                    reply.send(.success(path))
                }
            }
        )
    }

    func closeSyncAccessHandle(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        accessHandleIdentifier: IPCTypes.FileSystemSyncAccessHandleIdentifier,
        reply: consuming NetworkStorageManagerCloseSyncAccessHandleReply
    ) {
        assert(!WTF.RunLoop.isMain())

        if let handle = accessibleFileSystemHandle(connection, identifier) {
            _ = handle.closeSyncAccessHandle(accessHandleIdentifier)
        }
        reply.send()
    }

    func requestNewCapacityForSyncAccessHandle(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        accessHandleIdentifier: IPCTypes.FileSystemSyncAccessHandleIdentifier,
        newCapacity: UInt64,
        reply: consuming NetworkStorageManagerRequestNewCapacityForSyncAccessHandleReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(nil)
            return
        }

        let pending = PendingReply(reply)
        handle.requestNewCapacityForSyncAccessHandle(accessHandleIdentifier, newCapacity: newCapacity) {
            capacity in
            if let reply = pending.take() {
                reply.send(capacity)
            }
        }
    }

    func createWritable(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        keepExistingData: Bool,
        reply: consuming NetworkStorageManagerCreateWritableReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        reply.send(handle.createWritable(keepExistingData: keepExistingData))
    }

    func closeWritable(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier,
        reason: IPCTypes.FileSystemWriteCloseReason,
        reply: consuming NetworkStorageManagerCloseWritableReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(.unknown)
            return
        }

        reply.send(handle.closeWritable(streamIdentifier, reason: reason))
    }

    func executeCommandForWritable(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier,
        type: IPCTypes.FileSystemWriteCommandType,
        position: UInt64?,
        size: UInt64?,
        dataBytes: [UInt8],
        hasDataError: Bool,
        reply: consuming NetworkStorageManagerExecuteCommandForWritableReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(.unknown)
            return
        }

        let pending = PendingReply(reply)
        handle.executeCommandForWritable(
            streamIdentifier,
            type: type,
            position: position,
            size: size,
            dataBytes: dataBytes,
            hasDataError: hasDataError
        ) { error in
            if let reply = pending.take() {
                reply.send(error)
            }
        }
    }

    func getHandleNames(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        reply: consuming NetworkStorageManagerGetHandleNamesReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        reply.send(handle.getHandleNames().map { names in names.map { IPCCoding.WTFString.swiftString($0) } })
    }

    func getHandle(
        connection: IPC.Connection,
        identifier: IPCTypes.FileSystemHandleIdentifier,
        name: CxxDecodedArguments.NetworkStorageManager.GetHandleName,
        reply: consuming NetworkStorageManagerGetHandleReply
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let handle = accessibleFileSystemHandle(connection, identifier), let name = takeName(name) else {
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        reply.send(handle.getHandle(connection: connection.uniqueID(), name: name).map(Optional.some))
    }

    func addGlobalIdentifierReference(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        globalIdentifier: FileSystemHandleGlobalIdentifier
    ) throws(InvalidMessage) {
        assert(workQueue().isCurrent())

        try messageCheck("the connection may use the origin's site") {
            isSiteAllowed(for: connection, origin)
        }

        fileSystemStorageManager(origin, .No).get().addGlobalIdentifierReference(globalIdentifier)
    }

    func removeGlobalIdentifierReferences(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        globalIdentifiers: [FileSystemHandleGlobalIdentifier]
    ) throws(InvalidMessage) {
        assert(workQueue().isCurrent())

        try messageCheck("the connection may use the origin's site") {
            isSiteAllowed(for: connection, origin)
        }

        fileSystemStorageManager(origin, .No).get().removeGlobalIdentifierReferences(globalIdentifiers)
    }

    func resolveGlobalIdentifier(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        globalIdentifier: FileSystemHandleGlobalIdentifier,
        reply: consuming NetworkStorageManagerResolveGlobalIdentifierReply
    ) {
        assert(workQueue().isCurrent())

        do throws(InvalidMessage) {
            try messageCheck("the connection may use the origin's site") {
                isSiteAllowed(for: connection, origin)
            }
        } catch {
            markMessageInvalid(error, on: connection)
            reply.send(.failure(IPCUnexpected(.unknown)))
            return
        }

        let manager = fileSystemStorageManager(origin, .No).get()
        reply.send(manager.resolveGlobalIdentifier(connection: connection.uniqueID(), globalIdentifier))
    }
}

// MARK: Cache Storage

extension WebKit.NetworkStorageManager {
    private func accessibleCacheStorageCache(
        _ connection: IPC.Connection,
        _ cacheIdentifier: WebCore.DOMCacheIdentifier,
        function: StaticString = #function
    ) -> WebKit.CacheStorageCache? {
        guard let cache = m_cacheStorageRegistry.get().cache(cacheIdentifier),
            storageSiteCheck(connection, cache.origin().value, function: function)
        else {
            return nil
        }
        return cache
    }

    private func accessibleCacheStorageManager(
        _ connection: IPC.Connection,
        _ cacheIdentifier: WebCore.DOMCacheIdentifier,
        function: StaticString = #function
    ) -> WebKit.CacheStorageManager? {
        accessibleCacheStorageCache(connection, cacheIdentifier, function: function)?.manager().get()
    }

    func cacheStorageRemoveCache(
        connection: IPC.Connection,
        cacheIdentifier: WebCore.DOMCacheIdentifier,
        reply: consuming NetworkStorageManagerCacheStorageRemoveCacheReply
    ) {
        guard let manager = accessibleCacheStorageManager(connection, cacheIdentifier) else {
            reply.send(.failure(IPCUnexpected(.internal)))
            return
        }

        reply.send(manager.removeCache(cacheIdentifier))
    }

    func cacheStorageOpenCache(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        cacheName: CxxDecodedArguments.NetworkStorageManager.CacheStorageOpenCacheCacheName,
        reply: consuming NetworkStorageManagerCacheStorageOpenCacheReply
    ) {
        guard storageSiteCheck(connection, origin), let name = takeName(cacheName) else {
            reply.send(.failure(IPCUnexpected(.internal)))
            return
        }

        let manager = cacheStorageManager(origin, .Yes).get()
        let pending = PendingReply(reply)
        manager.openCache(name) { result in
            if let reply = pending.take() {
                reply.send(result.map { IPCTypes.CacheIdentifierOperationResult(identifier: $0, hadStorageError: false) })
            }
        }
    }

    func cacheStorageAllCaches(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        updateCounter: UInt64,
        reply: consuming NetworkStorageManagerCacheStorageAllCachesReply
    ) {
        guard storageSiteCheck(connection, origin) else {
            reply.send(.failure(IPCUnexpected(.internal)))
            return
        }

        let manager = cacheStorageManager(origin, .No).get()
        let pending = PendingReply(reply)
        manager.allCaches { result in
            if let reply = pending.take() {
                reply.send(result)
            }
        }
    }

    func cacheStorageReference(connection: IPC.Connection, cacheIdentifier: WebCore.DOMCacheIdentifier) {
        guard let manager = accessibleCacheStorageManager(connection, cacheIdentifier) else {
            return
        }
        manager.reference(connection.uniqueID(), cacheIdentifier)
    }

    func cacheStorageDereference(connection: IPC.Connection, cacheIdentifier: WebCore.DOMCacheIdentifier) {
        guard let manager = accessibleCacheStorageManager(connection, cacheIdentifier) else {
            return
        }
        manager.dereference(connection.uniqueID(), cacheIdentifier)
    }

    func lockCacheStorage(connection: IPC.Connection, origin: WebCore.ClientOrigin) {
        guard storageSiteCheck(connection, origin) else {
            return
        }
        cacheStorageManager(origin, .No).get().lockStorage(connection.uniqueID())
    }

    func unlockCacheStorage(connection: IPC.Connection, origin: WebCore.ClientOrigin) {
        guard storageSiteCheck(connection, origin) else {
            return
        }
        existingCacheStorageManager(origin).get()?.unlockStorage(connection.uniqueID())
    }

    func cacheStorageRemoveRecords(
        connection: IPC.Connection,
        cacheIdentifier: WebCore.DOMCacheIdentifier,
        request: CxxDecodedArguments.NetworkStorageManager.CacheStorageRemoveRecordsRequest,
        options: IPCTypes.CacheQueryOptions,
        reply: consuming NetworkStorageManagerCacheStorageRemoveRecordsReply
    ) {
        guard let cache = accessibleCacheStorageCache(connection, cacheIdentifier) else {
            reply.send(.failure(IPCUnexpected(.internal)))
            return
        }

        var queryOptions = WebCore.CacheQueryOptions()
        queryOptions.ignoreSearch = options.ignoreSearch
        queryOptions.ignoreMethod = options.ignoreMethod
        queryOptions.ignoreVary = options.ignoreVary
        let pending = PendingReply(reply)
        cache.removeRecords(WebKit.cacheStorageTakeRequest(request), queryOptions) { result in
            if let reply = pending.take() {
                reply.send(result)
            }
        }
    }

    func cacheStoragePutRecords(
        connection: IPC.Connection,
        cacheIdentifier: WebCore.DOMCacheIdentifier,
        records: CxxDecodedArguments.NetworkStorageManager.CacheStoragePutRecordsRecords,
        reply: consuming NetworkStorageManagerCacheStoragePutRecordsReply
    ) {
        guard let cache = accessibleCacheStorageCache(connection, cacheIdentifier) else {
            reply.send(.failure(IPCUnexpected(.internal)))
            return
        }
        var sizesAreValid = true
        let cacheStorageRecords = WebKit.cacheStorageTakeRecords(records, cache, &sizesAreValid)
        do throws(InvalidMessage) {
            try messageCheck("each record's response body size is at least its size in storage") { sizesAreValid }
        } catch {
            markMessageInvalid(error, on: connection)
            reply.send(.failure(IPCUnexpected(.internal)))
            return
        }

        let pending = PendingReply(reply)
        cache.putRecords(cacheStorageRecords) { result in
            if let reply = pending.take() {
                reply.send(result)
            }
        }
    }

    func cacheStorageClearMemoryRepresentation(
        connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        reply: consuming NetworkStorageManagerCacheStorageClearMemoryRepresentationReply
    ) {
        guard storageSiteCheck(connection, origin) else {
            reply.send()
            return
        }
        closeCacheStorageManager(origin)
        reply.send()
    }
}
