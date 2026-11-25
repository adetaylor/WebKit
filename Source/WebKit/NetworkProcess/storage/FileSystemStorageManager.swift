// Copyright (C) 2021 Apple Inc. All rights reserved.
// Copyright (C) 2025 Apple Inc. All rights reserved.
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

typealias FileSystemHandleGlobalIdentifier = UUIDHalves

typealias FileSystemStorageHandleCreated = (
    globalIdentifier: FileSystemHandleGlobalIdentifier, identifier: IPCTypes.FileSystemHandleIdentifier,
    kind: IPCTypes.FileSystemHandleKind
)
typealias FileSystemStorageResult<Success> = Result<Success, IPCUnexpected<IPCTypes.FileSystemStorageError>>

private struct FileSystemStorageManagerState {
    enum Lock {
        case exclusive
        case shared(count: Int)
    }

    struct GlobalIdentifierEntry {
        enum ReferenceCount {
            case count(UInt32)
            case overflowed
        }

        var kind: IPCTypes.FileSystemHandleKind
        var path: [UInt16]?
        var name: [UInt16]?
        var refcount: ReferenceCount
    }

    var handlesByConnection: [UInt64: Set<IPCTypes.FileSystemHandleIdentifier>] = [:]
    var lockMap: [[UInt16]: Lock] = [:]
    var globalIdentifierRegistry: [FileSystemHandleGlobalIdentifier: GlobalIdentifierEntry] = [:]

    mutating func addReference(_ globalIdentifier: FileSystemHandleGlobalIdentifier) {
        guard case .count(let count) = globalIdentifierRegistry[globalIdentifier]?.refcount else {
            return
        }
        globalIdentifierRegistry[globalIdentifier]?.refcount = count == UInt32.max ? .overflowed : .count(count + 1)
    }

    mutating func removeReference(_ globalIdentifier: FileSystemHandleGlobalIdentifier) {
        guard case .count(let count) = globalIdentifierRegistry[globalIdentifier]?.refcount, count != 0 else {
            return
        }
        if count == 1 {
            globalIdentifierRegistry[globalIdentifier] = nil
        } else {
            globalIdentifierRegistry[globalIdentifier]?.refcount = .count(count - 1)
        }
    }
}

private let fileSystemStorageManagerStates = StateTable<FileSystemStorageManagerState>()

extension IPCTypes.FileSystemHandleKind {
    fileprivate init(_ kind: WebCore.FileSystemHandleKind) {
        self = kind == .Directory ? .directory : .file
    }

    fileprivate init(_ type: WebKit.FileSystemStorageHandle.`Type`) {
        self = type == .Directory ? .directory : .file
    }

    fileprivate var webCoreKind: WebCore.FileSystemHandleKind {
        self == .directory ? .Directory : .File
    }

    fileprivate var handleType: WebKit.FileSystemStorageHandle.`Type` {
        self == .directory ? .Directory : .File
    }
}

extension WebKit.FileSystemStorageManager {
    enum LockType {
        case exclusive
        case shared
    }

    @cxx
    @implementation
    func initializeState() {
        fileSystemStorageManagerStates.insert(for: swiftKey()) { FileSystemStorageManagerState() }
    }

    @cxx
    @implementation
    func destroyState() {
        _ = fileSystemStorageManagerStates.take(for: swiftKey())
    }

    var clientOrigin: WebCore.ClientOrigin {
        m_origin
    }

    @cxx
    @implementation
    func allocatedUnusedCapacity() -> UInt64 {
        let handlesByConnection = fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.handlesByConnection }
        var result: UInt64 = 0
        for identifiers in handlesByConnection.values {
            for identifier in identifiers {
                guard let handle = findHandle(identifier) else {
                    continue
                }
                let (sum, overflow) = result.addingReportingOverflow(handle.allocatedUnusedCapacity())
                if overflow {
                    return 0
                }
                result = sum
            }
        }
        return result
    }

    func createHandle(
        connection: IPC.Connection.UniqueID,
        type requestedType: WebKit.FileSystemStorageHandle.`Type`,
        path: [UInt16]?,
        name: [UInt16]?,
        createIfNecessary: Bool
    ) -> FileSystemStorageResult<FileSystemStorageHandleCreated> {
        assert(!WTF.RunLoop.isMain())

        guard let path, !path.isEmpty else {
            return .failure(IPCUnexpected(.unknown))
        }
        let pathString = WTF.String(utf16Units: path)
        let fileExists = WTF.FileSystemImpl.fileExists(pathString)
        if !createIfNecessary && !fileExists {
            return .failure(IPCUnexpected(.fileNotFound))
        }

        var type = requestedType
        if fileExists {
            guard let existingFileType = WTF.FileSystemImpl.fileType(pathString).value else {
                return .failure(IPCUnexpected(.unknown))
            }
            let existingHandleType: WebKit.FileSystemStorageHandle.`Type` = existingFileType == .Regular ? .File : .Directory
            if type == .Any {
                type = existingHandleType
            } else if existingHandleType != type {
                // Requesting type and existing type should be a match.
                return .failure(IPCUnexpected(.typeMismatch))
            }
        }

        let newHandle = WebKit.FileSystemStorageHandle.create(self, type, consuming: pathString)
        return withExtendedLifetime(newHandle) {
            guard let handle = newHandle.get() else {
                return .failure(IPCUnexpected(.unknown))
            }

            let globalIdentifier = FileSystemHandleGlobalIdentifier(WTF.UUID.createVersion4())
            handle.globalIdentifier = globalIdentifier

            let identifier = handle.ipcIdentifier
            let kind = IPCTypes.FileSystemHandleKind(handle.type())
            let connectionKey = connection.toUInt64()
            addHandle(handle)
            fileSystemStorageManagerStates.withState(for: swiftKey()) { state in
                _ = state.handlesByConnection[connectionKey, default: []].insert(identifier)
                if state.globalIdentifierRegistry[globalIdentifier] == nil {
                    state.globalIdentifierRegistry[globalIdentifier] = FileSystemStorageManagerState.GlobalIdentifierEntry(
                        kind: kind,
                        path: path,
                        name: name,
                        refcount: .count(1)
                    )
                }
            }
            return .success((globalIdentifier: globalIdentifier, identifier: identifier, kind: kind))
        }
    }

    private func findHandle(_ identifier: IPCTypes.FileSystemHandleIdentifier) -> WebKit.FileSystemStorageHandle? {
        m_handles.get(WebCore.FileSystemHandleIdentifier(identifier.rawValue))
    }

    private func takeHandle(_ identifier: IPCTypes.FileSystemHandleIdentifier) -> WebKit.FileSystemStorageHandle? {
        let handleIdentifier = WebCore.FileSystemHandleIdentifier(identifier.rawValue)
        let handle = m_handles.take(handleIdentifier).get()
        m_registry.get()?.unregisterHandle(handleIdentifier)
        return handle
    }

    func getPath(_ identifier: IPCTypes.FileSystemHandleIdentifier) -> [UInt16] {
        findHandle(identifier)?.pathUnits ?? []
    }

    func getType(_ identifier: IPCTypes.FileSystemHandleIdentifier) -> WebKit.FileSystemStorageHandle.`Type` {
        findHandle(identifier)?.type() ?? .Any
    }

    func closeHandle(_ handle: WebKit.FileSystemStorageHandle) {
        let identifier = handle.ipcIdentifier
        if let globalIdentifier = handle.globalIdentifier {
            removeGlobalIdentifierReference(globalIdentifier)
        }
        let takenHandle = takeHandle(identifier)
        // Swift cannot compare C++ objects' identities, and a handle's identifier is its own.
        assert(takenHandle?.ipcIdentifier == identifier)
        fileSystemStorageManagerStates.withState(for: swiftKey()) { state in
            if let connection = state.handlesByConnection.first(where: { $0.value.contains(identifier) })?.key {
                _ = state.handlesByConnection[connection]?.remove(identifier)
            }
        }
    }

    @cxx
    @implementation
    func connectionClosed(_ connection: IPC.Connection.UniqueID) {
        assert(!WTF.RunLoop.isMain())

        let connectionKey = connection.toUInt64()
        let identifiers = fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.handlesByConnection[connectionKey] }
        guard let identifiers else {
            return
        }
        for identifier in identifiers {
            let handle = findHandle(identifier)
            withExtendedLifetime(handle) {
                handle?.close()
            }
        }
        _ = fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.handlesByConnection.removeValue(forKey: connectionKey) }
    }

    func getDirectory(connection: IPC.Connection.UniqueID) -> FileSystemStorageResult<FileSystemStorageHandleCreated> {
        assert(!WTF.RunLoop.isMain())

        return createHandle(connection: connection, type: .Directory, path: m_path.nullableUTF16Units, name: nil, createIfNecessary: true)
    }

    // https://fs.spec.whatwg.org/#file-entry-lock-take
    func acquireLockForFile(_ path: [UInt16], _ lockType: LockType) -> Bool {
        fileSystemStorageManagerStates.withState(for: swiftKey()) { state in
            switch (state.lockMap[path], lockType) {
            case (nil, .exclusive):
                state.lockMap[path] = .exclusive
            case (nil, .shared):
                state.lockMap[path] = .shared(count: 1)
            case (.shared(let count), .shared):
                state.lockMap[path] = .shared(count: count + 1)
            default:
                return false
            }
            return true
        }
    }

    // https://fs.spec.whatwg.org/#file-entry-lock-release
    @discardableResult
    func releaseLockForFile(_ path: [UInt16]) -> Bool {
        fileSystemStorageManagerStates.withState(for: swiftKey()) { state in
            switch state.lockMap[path] {
            case nil:
                return false
            case .shared(let count) where count > 1:
                state.lockMap[path] = .shared(count: count - 1)
                return false
            case .exclusive, .shared:
                state.lockMap[path] = nil
                return true
            }
        }
    }

    func hasActiveLock(_ path: [UInt16]) -> Bool {
        let prefix = path + [WebKit.FileSystemStorageHandle.pathSeparator]
        return fileSystemStorageManagerStates.withState(for: swiftKey()) { state in
            state.lockMap.keys.contains { $0 == path || $0.starts(with: prefix) }
        }
    }

    @cxx
    @implementation
    func close() {
        assert(!WTF.RunLoop.isMain())

        let handlesByConnection = fileSystemStorageManagerStates.withState(for: swiftKey()) {
            exchange(&$0.handlesByConnection, with: [:])
        }
        for (connection, identifiers) in handlesByConnection {
            for identifier in identifiers {
                let takenHandle = takeHandle(identifier)
                withExtendedLifetime(takenHandle) {
                    guard let handle = takenHandle else {
                        return
                    }

                    // Send messages to web process to invalidate active sync access handle and writables.
                    if let accessHandleIdentifier = handle.activeSyncAccessHandleIdentifier {
                        WebKit.FileSystemStorageManager.sendInvalidateAccessHandle(
                            IPC.Connection.UniqueID(connection),
                            WebCore.FileSystemSyncAccessHandleIdentifier(accessHandleIdentifier.rawValue)
                        )
                    }
                    for writableIdentifier in handle.writables {
                        WebKit.FileSystemStorageManager.sendInvalidateWritable(
                            IPC.Connection.UniqueID(connection),
                            WebCore.FileSystemWritableFileStreamIdentifier(writableIdentifier.rawValue)
                        )
                    }
                }
            }
        }
        assert(!isActive())
        fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.lockMap = [:] }
    }

    func requestSpace(_ size: UInt64, _ completionHandler: @escaping (Bool) -> Void) {
        m_quotaCheckFunction(size, consuming: WTF.BoolCompletionHandler(completionHandler))
    }

    func addGlobalIdentifierReference(_ globalIdentifier: FileSystemHandleGlobalIdentifier) {
        assert(!WTF.RunLoop.isMain())

        fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.addReference(globalIdentifier) }
    }

    private func removeGlobalIdentifierReference(_ globalIdentifier: FileSystemHandleGlobalIdentifier) {
        assert(!WTF.RunLoop.isMain())

        fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.removeReference(globalIdentifier) }
    }

    func removeGlobalIdentifierReferences(_ globalIdentifiers: [FileSystemHandleGlobalIdentifier]) {
        assert(!WTF.RunLoop.isMain())

        for globalIdentifier in globalIdentifiers {
            removeGlobalIdentifierReference(globalIdentifier)
        }
    }

    func resolveGlobalIdentifier(
        connection: IPC.Connection.UniqueID,
        _ globalIdentifier: FileSystemHandleGlobalIdentifier
    ) -> FileSystemStorageResult<IPCTypes.FileSystemHandleIdentifier> {
        assert(!WTF.RunLoop.isMain())

        let entry = fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.globalIdentifierRegistry[globalIdentifier] }
        guard let entry else {
            return .failure(IPCUnexpected(.unknown))
        }
        let result = createHandle(
            connection: connection,
            type: entry.kind.handleType,
            path: entry.path,
            name: entry.name,
            createIfNecessary: false
        )
        guard case .success(let created) = result else {
            return result.map { $0.identifier }
        }

        // Replace the auto-generated global identifier with the existing one being resolved.
        fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.globalIdentifierRegistry[created.globalIdentifier] = nil }
        findHandle(created.identifier)?.globalIdentifier = globalIdentifier
        addGlobalIdentifierReference(globalIdentifier)
        return .success(created.identifier)
    }

    func lookupHandle(_ globalIdentifier: FileSystemHandleGlobalIdentifier) -> WebCore.FileSystemHandleRecord? {
        assert(!WTF.RunLoop.isMain())

        let entry = fileSystemStorageManagerStates.withState(for: swiftKey()) { $0.globalIdentifierRegistry[globalIdentifier] }
        guard let entry, let uuid = globalIdentifier.uuid else {
            return nil
        }
        return WebCore.FileSystemHandleRecord(
            identifier: uuid,
            kind: entry.kind.webCoreKind,
            path: WTF.String(nullableUTF16Units: entry.path),
            name: WTF.String(nullableUTF16Units: entry.name)
        )
    }

    @cxx
    @implementation
    func lookupHandles(_ identifiers: WebKit.FileSystemHandleGlobalIdentifierVector) -> WebKit.OptionalFileSystemHandleRecordVector {
        assert(!WTF.RunLoop.isMain())

        var records = WebKit.FileSystemHandleRecordVector()
        records.reserveCapacity(identifiers.size())
        for index in 0..<identifiers.size() {
            guard let record = lookupHandle(FileSystemHandleGlobalIdentifier(identifiers[index])) else {
                return WebKit.OptionalFileSystemHandleRecordVector()
            }
            records.append(consuming: record)
        }
        return WebKit.OptionalFileSystemHandleRecordVector(records)
    }

    private func registerPersistedHandleAndAddReference(
        _ globalIdentifier: FileSystemHandleGlobalIdentifier,
        kind: IPCTypes.FileSystemHandleKind,
        path: [UInt16]?,
        name: [UInt16]?
    ) {
        assert(!WTF.RunLoop.isMain())

        fileSystemStorageManagerStates.withState(for: swiftKey()) { state in
            if state.globalIdentifierRegistry[globalIdentifier] == nil {
                state.globalIdentifierRegistry[globalIdentifier] = FileSystemStorageManagerState.GlobalIdentifierEntry(
                    kind: kind,
                    path: path,
                    name: name,
                    refcount: .count(0)
                )
            }
            state.addReference(globalIdentifier)
        }
    }

    @cxx
    @implementation
    func registerPersistedHandlesAndAddReferences(_ records: WebKit.FileSystemHandleRecordVector) {
        assert(!WTF.RunLoop.isMain())

        for index in 0..<records.size() {
            let record = records[index]
            let globalIdentifier = FileSystemHandleGlobalIdentifier(record.identifier)
            registerPersistedHandleAndAddReference(
                globalIdentifier,
                kind: IPCTypes.FileSystemHandleKind(record.kind),
                path: record.path.nullableUTF16Units,
                name: record.name.nullableUTF16Units
            )
        }
    }
}
