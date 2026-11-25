// Copyright (C) 2021 Apple Inc. All rights reserved.
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

private struct FileSystemStorageHandleState {
    final class WritableFile {
        var handle: WTF.FileSystemImpl.FileHandle
        let temporaryPath: [UInt16]

        init(handle: consuming WTF.FileSystemImpl.FileHandle, temporaryPath: [UInt16]) {
            self.handle = handle
            self.temporaryPath = temporaryPath
        }
    }

    struct SyncAccessHandleInfo {
        let identifier: IPCTypes.FileSystemSyncAccessHandleIdentifier
        var capacity: UInt64
    }

    var path: [UInt16]
    var globalIdentifier: FileSystemHandleGlobalIdentifier?
    var activeSyncAccessHandle: SyncAccessHandleInfo?
    var writables: [IPCTypes.FileSystemWritableFileStreamIdentifier: WritableFile] = [:]
}

private let fileSystemStorageHandleStates = StateTable<FileSystemStorageHandleState>()

extension WebKit.FileSystemStorageHandle {
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let dot = UInt16(UInt8(ascii: "."))
    static let pathSeparator = UInt16(UInt8(bitPattern: WTF.FileSystemImpl.pathSeparator))

    // https://fs.spec.whatwg.org/#valid-file-name
    private static func isValidFileName(directory: [UInt16], name: borrowing WTF.String) -> Bool {
        let units = name.utf16Units
        if units.isEmpty || units == [dot] || units == [dot, dot] || units.contains(slash) || units.contains(pathSeparator) {
            return false
        }
        let path = WebKit.fileSystemPathByAppendingComponent(WTF.String(utf16Units: directory), copy name)
        return WTF.FileSystemImpl.pathFileName(path).utf16Units == units
    }
}

private func fileSystemPath(_ directory: [UInt16], appending name: borrowing WTF.String) -> [UInt16] {
    WebKit.fileSystemPathByAppendingComponent(WTF.String(utf16Units: directory), copy name).utf16Units
}

extension WebKit.FileSystemStorageHandle {
    @cxx
    @implementation
    func initializeState(_ path: WTF.String) {
        fileSystemStorageHandleStates.insert(for: swiftKey()) { FileSystemStorageHandleState(path: path.utf16Units) }
    }

    @cxx
    @implementation
    func destroyState() {
        fileSystemStorageHandleStates.remove(for: swiftKey())
    }

    var pathUnits: [UInt16] {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { $0.path }
    }

    @cxx
    @implementation
    func path() -> WTF.String {
        WTF.String(utf16Units: pathUnits)
    }

    @cxx
    @implementation
    func origin() -> WebKit.OptionalClientOrigin {
        guard let manager = m_manager.get() else {
            return WebKit.OptionalClientOrigin()
        }
        return WebKit.OptionalClientOrigin(manager.clientOrigin)
    }

    var ipcIdentifier: IPCTypes.FileSystemHandleIdentifier {
        IPCTypes.FileSystemHandleIdentifier(generated: handleIdentifier().toUInt64())
    }

    var globalIdentifier: FileSystemHandleGlobalIdentifier? {
        get { fileSystemStorageHandleStates.withState(for: swiftKey()) { $0.globalIdentifier } }
        set { fileSystemStorageHandleStates.withState(for: swiftKey()) { $0.globalIdentifier = newValue } }
    }

    func close() {
        guard let manager = m_manager.get() else {
            return
        }

        if let identifier = activeSyncAccessHandleIdentifier {
            _ = closeSyncAccessHandle(identifier)
        }

        for identifier in writables {
            _ = closeWritable(identifier, reason: .aborted)
        }
        assert(writables.isEmpty)

        manager.closeHandle(self)
    }

    func isSameEntry(_ identifier: IPCTypes.FileSystemHandleIdentifier) -> Bool {
        guard let manager = m_manager.get() else {
            return false
        }

        let path = manager.getPath(identifier)
        if path.isEmpty {
            return false
        }

        return pathUnits == path
    }

    private func requestCreateHandle(
        connection: IPC.Connection.UniqueID,
        type: WebKit.FileSystemStorageHandle.`Type`,
        name: borrowing WTF.String,
        createIfNecessary: Bool
    ) -> FileSystemStorageResult<FileSystemStorageHandleCreated> {
        if self.type() != .Directory {
            return .failure(IPCUnexpected(.typeMismatch))
        }

        guard let manager = m_manager.get() else {
            return .failure(IPCUnexpected(.unknown))
        }

        let directory = pathUnits
        if !Self.isValidFileName(directory: directory, name: name) {
            return .failure(IPCUnexpected(.invalidName))
        }

        let path = fileSystemPath(directory, appending: name)
        return manager.createHandle(
            connection: connection,
            type: type,
            path: path,
            name: name.utf16Units,
            createIfNecessary: createIfNecessary
        )
    }

    func getFileHandle(
        connection: IPC.Connection.UniqueID,
        name: borrowing WTF.String,
        createIfNecessary: Bool
    ) -> FileSystemStorageResult<FileSystemStorageHandleCreated> {
        requestCreateHandle(connection: connection, type: .File, name: name, createIfNecessary: createIfNecessary)
    }

    func getDirectoryHandle(
        connection: IPC.Connection.UniqueID,
        name: borrowing WTF.String,
        createIfNecessary: Bool
    ) -> FileSystemStorageResult<FileSystemStorageHandleCreated> {
        requestCreateHandle(connection: connection, type: .Directory, name: name, createIfNecessary: createIfNecessary)
    }

    func removeEntry(name: borrowing WTF.String, deleteRecursively: Bool) -> IPCTypes.FileSystemStorageError? {
        if type() != .Directory {
            return .typeMismatch
        }

        let directory = pathUnits
        if !Self.isValidFileName(directory: directory, name: name) {
            return .invalidName
        }

        let entryPathUnits = fileSystemPath(directory, appending: name)
        let path = WTF.String(utf16Units: entryPathUnits)
        if !WTF.FileSystemImpl.fileExists(path) {
            return .fileNotFound
        }

        guard let manager = m_manager.get() else {
            return .unknown
        }

        if manager.hasActiveLock(entryPathUnits) {
            return .noModificationAllowed
        }

        guard let type = WTF.FileSystemImpl.fileType(path).value else {
            return .typeMismatch
        }

        switch type {
        case .Regular:
            if !WTF.FileSystemImpl.deleteFile(path) {
                return .unknown
            }
        case .Directory:
            if !deleteRecursively {
                if !WTF.FileSystemImpl.deleteEmptyDirectory(path) {
                    return WTF.FileSystemImpl.listDirectory(path).isEmpty() ? .unknown : .invalidModification
                }
            } else if !WTF.FileSystemImpl.deleteNonEmptyDirectory(path) {
                return .unknown
            }
        case .SymbolicLink:
            fatalError("A handle's entry is never a symbolic link")
        @unknown default:
            fatalError()
        }
        return nil
    }

    func resolve(_ identifier: IPCTypes.FileSystemHandleIdentifier) -> FileSystemStorageResult<[[UInt16]]?> {
        guard let manager = m_manager.get() else {
            return .failure(IPCUnexpected(.unknown))
        }

        let path = manager.getPath(identifier)
        if path.isEmpty {
            return .failure(IPCUnexpected(.unknown))
        }

        let directory = pathUnits
        if !path.starts(with: directory) {
            return .success(nil)
        }

        let restPath = path[directory.count...]
        if let first = restPath.first, first != Self.pathSeparator {
            return .success(nil)
        }

        return .success(restPath.split(separator: Self.pathSeparator).map { Array($0) })
    }

    func getHandleNames() -> FileSystemStorageResult<[WTF.String]> {
        if type() != .Directory {
            return .failure(IPCUnexpected(.typeMismatch))
        }

        let names = WTF.FileSystemImpl.listDirectory(path())
        return .success(Array(names))
    }

    func getHandle(
        connection: IPC.Connection.UniqueID,
        name: borrowing WTF.String
    ) -> FileSystemStorageResult<IPCTypes.FileSystemHandleInfo> {
        let result = requestCreateHandle(connection: connection, type: .Any, name: name, createIfNecessary: false)
        return result.map {
            IPCTypes.FileSystemHandleInfo(globalIdentifier: $0.globalIdentifier, identifier: $0.identifier, kind: $0.kind)
        }
    }

    func move(
        _ destinationIdentifier: IPCTypes.FileSystemHandleIdentifier,
        newName: borrowing WTF.String
    ) -> IPCTypes.FileSystemStorageError? {
        guard let manager = m_manager.get() else {
            return .unknown
        }

        // Do not move file if there is ongoing operation.
        if activeSyncAccessHandleIdentifier != nil {
            return .accessHandleActive
        }

        if manager.getType(destinationIdentifier) != .Directory {
            return .typeMismatch
        }

        let path = manager.getPath(destinationIdentifier)
        if path.isEmpty {
            return .unknown
        }

        if !Self.isValidFileName(directory: path, name: newName) {
            return .invalidName
        }

        let destinationPath = fileSystemPath(path, appending: newName)
        if !WTF.FileSystemImpl.moveFile(WTF.String(utf16Units: pathUnits), WTF.String(utf16Units: destinationPath)) {
            return .unknown
        }

        fileSystemStorageHandleStates.withState(for: swiftKey()) { $0.path = destinationPath }
        return nil
    }
}

// MARK: Sync access handles

extension WebKit.FileSystemStorageHandle {
    private static let defaultInitialCapacity = 1 * UInt64(WTF.MB)
    private static let defaultMaxCapacityForExponentialGrowth = 256 * UInt64(WTF.MB)
    private static let defaultCapacityStep = 128 * UInt64(WTF.MB)

    var activeSyncAccessHandleIdentifier: IPCTypes.FileSystemSyncAccessHandleIdentifier? {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { $0.activeSyncAccessHandle?.identifier }
    }

    private func isActiveSyncAccessHandle(_ identifier: IPCTypes.FileSystemSyncAccessHandleIdentifier) -> Bool {
        activeSyncAccessHandleIdentifier == identifier
    }

    private func syncAccessHandleCapacity(for identifier: IPCTypes.FileSystemSyncAccessHandleIdentifier) -> UInt64? {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { state in
            guard let active = state.activeSyncAccessHandle, active.identifier == identifier else {
                return nil
            }
            return active.capacity
        }
    }

    private func grantSyncAccessHandleCapacity(
        _ newCapacity: UInt64,
        for identifier: IPCTypes.FileSystemSyncAccessHandleIdentifier
    ) -> UInt64? {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { state in
            guard var active = state.activeSyncAccessHandle, active.identifier == identifier else {
                return nil
            }
            active.capacity = newCapacity
            state.activeSyncAccessHandle = active
            return newCapacity
        }
    }

    @cxx
    @implementation
    func lockForSyncAccessHandle() -> WebKit.OptionalFileSystemStorageError {
        guard let manager = m_manager.get() else {
            return WebKit.OptionalFileSystemStorageError(WebKit.FileSystemStorageError.Unknown)
        }
        if !manager.acquireLockForFile(pathUnits, .exclusive) {
            return WebKit.OptionalFileSystemStorageError(WebKit.FileSystemStorageError.InvalidState)
        }
        return WebKit.OptionalFileSystemStorageError()
    }

    @cxx
    @implementation
    func unlockForSyncAccessHandle() {
        m_manager.get()?.releaseLockForFile(pathUnits)
    }

    @cxx
    @implementation
    func activateSyncAccessHandle() -> WebCore.FileSystemSyncAccessHandleIdentifier {
        let identifier = WebCore.FileSystemSyncAccessHandleIdentifier.generate()
        let value = IPCTypes.FileSystemSyncAccessHandleIdentifier(generated: identifier.toUInt64())
        fileSystemStorageHandleStates.withState(for: swiftKey()) { state in
            assert(state.activeSyncAccessHandle == nil)
            state.activeSyncAccessHandle = .init(identifier: value, capacity: 0)
        }
        return identifier
    }

    func closeSyncAccessHandle(_ identifier: IPCTypes.FileSystemSyncAccessHandleIdentifier) -> IPCTypes.FileSystemStorageError? {
        if !isActiveSyncAccessHandle(identifier) {
            return .unknown
        }

        guard let manager = m_manager.get() else {
            return .unknown
        }

        manager.releaseLockForFile(pathUnits)
        fileSystemStorageHandleStates.withState(for: swiftKey()) { $0.activeSyncAccessHandle = nil }
        return nil
    }

    func requestNewCapacityForSyncAccessHandle(
        _ identifier: IPCTypes.FileSystemSyncAccessHandleIdentifier,
        newCapacity requestedCapacity: UInt64,
        completionHandler: @escaping (UInt64?) -> Void
    ) {
        guard let currentCapacity = syncAccessHandleCapacity(for: identifier) else {
            completionHandler(nil)
            return
        }
        if requestedCapacity <= currentCapacity {
            completionHandler(currentCapacity)
            return
        }

        guard let manager = m_manager.get() else {
            completionHandler(nil)
            return
        }

        let newCapacity: UInt64
        if requestedCapacity < Self.defaultInitialCapacity {
            newCapacity = Self.defaultInitialCapacity
        } else if requestedCapacity < Self.defaultMaxCapacityForExponentialGrowth {
            newCapacity = 1 << UInt64(UInt64.bitWidth - requestedCapacity.leadingZeroBitCount)
        } else {
            // Wraps to 0 for a request within 128 MB of UInt64.max.
            newCapacity = Self.defaultCapacityStep &* ((requestedCapacity / Self.defaultCapacityStep) + 1)
        }

        let weakThis = WebKit.WeakPtrFileSystemStorageHandle(self, .Yes)
        // Wraps when newCapacity wrapped to 0 and currentCapacity is not 0.
        manager.requestSpace(newCapacity &- currentCapacity) { granted in
            guard let handle = weakThis.get() else {
                completionHandler(nil)
                return
            }

            if granted {
                completionHandler(handle.grantSyncAccessHandleCapacity(newCapacity, for: identifier))
            } else {
                completionHandler(handle.syncAccessHandleCapacity(for: identifier))
            }
        }
    }

    func allocatedUnusedCapacity() -> UInt64 {
        guard let capacity = fileSystemStorageHandleStates.withState(for: swiftKey(), { $0.activeSyncAccessHandle?.capacity }) else {
            return 0
        }

        let actualSize = WTF.FileSystemImpl.fileSize(path()).value ?? 0
        return actualSize > capacity ? 0 : capacity - actualSize
    }
}

// MARK: Writable file streams

extension WebKit.FileSystemStorageHandle {
    private static let writableStreamFilePrefix: [UInt16] = Array("FileSystemWritableStream".utf16)

    func createWritable(keepExistingData: Bool) -> FileSystemStorageResult<IPCTypes.FileSystemWritableFileStreamIdentifier> {
        guard let manager = m_manager.get() else {
            return .failure(IPCUnexpected(.unknown))
        }

        let pathUnits = self.pathUnits
        let path = WTF.String(utf16Units: pathUnits)
        if !WTF.FileSystemImpl.fileExists(path) {
            return .failure(IPCUnexpected(.fileNotFound))
        }

        if !manager.acquireLockForFile(pathUnits, .shared) {
            return .failure(IPCUnexpected(.invalidState))
        }

        let temporaryPath = WebKit.fileSystemCreateTemporaryFile(WTF.String(utf16Units: Self.writableStreamFilePrefix))
        if keepExistingData {
            _ = WTF.FileSystemImpl.copyFile(temporaryPath, path)
        }

        let streamIdentifier = IPCTypes.FileSystemWritableFileStreamIdentifier(
            generated: WebCore.FileSystemWritableFileStreamIdentifier.generate().toUInt64()
        )
        let temporaryPathUnits = temporaryPath.utf16Units
        // Opened inside withState: a FileHandle made outside it is not Sendable and cannot move into the state.
        let isOpened = fileSystemStorageHandleStates.withState(for: swiftKey()) { state -> Bool in
            assert(state.writables[streamIdentifier] == nil)
            let handle = WTF.FileSystemImpl.openFile(WTF.String(utf16Units: temporaryPathUnits), .ReadWrite)
            guard handle.isValid() else {
                return false
            }
            state.writables[streamIdentifier] = FileSystemStorageHandleState.WritableFile(
                handle: handle,
                temporaryPath: temporaryPathUnits
            )
            return true
        }
        guard isOpened else {
            manager.releaseLockForFile(pathUnits)
            return .failure(IPCUnexpected(.unknown))
        }
        return .success(streamIdentifier)
    }

    func closeWritable(
        _ streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier,
        reason: IPCTypes.FileSystemWriteCloseReason
    ) -> IPCTypes.FileSystemStorageError? {
        let paths = fileSystemStorageHandleStates.withState(for: swiftKey()) { state -> (path: [UInt16], temporaryPath: [UInt16])? in
            guard let file = state.writables[streamIdentifier] else {
                return nil
            }
            return (path: state.path, temporaryPath: file.temporaryPath)
        }
        guard let paths else {
            return .invalidState
        }

        guard let manager = m_manager.get() else {
            removeWritable(streamIdentifier)
            return .unknown
        }

        manager.releaseLockForFile(paths.path)

        if reason == .aborted {
            removeWritable(streamIdentifier)
            _ = WTF.FileSystemImpl.deleteFile(WTF.String(utf16Units: paths.temporaryPath))
            return nil
        }

        assert(!paths.temporaryPath.isEmpty)
        let copied = WTF.FileSystemImpl.copyFile(WTF.String(utf16Units: paths.path), WTF.String(utf16Units: paths.temporaryPath))
        removeWritable(streamIdentifier)
        return copied ? nil : .unknown
    }

    private func removeWritable(_ streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier) {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { _ = $0.writables.removeValue(forKey: streamIdentifier) }
    }

    private func executeWriteCommand(
        _ streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier,
        type: IPCTypes.FileSystemWriteCommandType,
        position: UInt64?,
        size: UInt64?,
        dataBytes: [UInt8]
    ) -> IPCTypes.FileSystemStorageError? {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { state -> IPCTypes.FileSystemStorageError? in
            guard let file = state.writables[streamIdentifier] else {
                return .invalidState
            }

            switch type {
            case .write:
                if let position {
                    if file.handle.seek(Int64(bitPattern: position), .Beginning).value == nil {
                        return .unknown
                    }
                }

                if WebKit.fileHandleWrite(&file.handle, dataBytes.span).value == nil {
                    return .unknown
                }

                return nil
            case .seek:
                guard let position else {
                    return .missingArgument
                }

                if file.handle.seek(Int64(bitPattern: position), .Beginning).value == nil {
                    return .unknown
                }

                return nil
            case .truncate:
                guard let size else {
                    return .missingArgument
                }

                if !file.handle.truncate(Int64(bitPattern: size)) {
                    return .unknown
                }

                if let currentOffset = file.handle.seek(0, .Current).value, currentOffset <= size {
                    return nil
                }
                _ = file.handle.seek(Int64(bitPattern: size), .Beginning)
                return nil
            }
        }
    }

    private func computeCommandSpace(
        _ streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier,
        type: IPCTypes.FileSystemWriteCommandType,
        position: UInt64?,
        size: UInt64?,
        dataBytes: [UInt8],
        hasDataError: Bool
    ) -> UInt64? {
        if hasDataError {
            return 0
        }
        if type != .write && type != .truncate {
            return 0
        }

        return fileSystemStorageHandleStates.withState(for: swiftKey()) { state -> UInt64? in
            guard let file = state.writables[streamIdentifier] else {
                return nil
            }

            guard let fileSize = WTF.FileSystemImpl.fileSize(WTF.String(utf16Units: state.path)).value else {
                return nil
            }

            if type == .truncate {
                guard let size else {
                    fatalError("Truncate command without a size")
                }
                return size > fileSize ? size - fileSize : 0
            }

            let writeStart: UInt64
            if let position {
                writeStart = position
            } else {
                guard let currentOffset = file.handle.seek(0, .Current).value else {
                    return nil
                }
                writeStart = currentOffset
            }

            let (finalSize, overflow) = writeStart.addingReportingOverflow(UInt64(dataBytes.count))
            if overflow {
                return nil
            }

            return finalSize > fileSize ? finalSize - fileSize : 0
        }
    }

    func executeCommandForWritable(
        _ streamIdentifier: IPCTypes.FileSystemWritableFileStreamIdentifier,
        type: IPCTypes.FileSystemWriteCommandType,
        position: UInt64?,
        size: UInt64?,
        dataBytes: [UInt8],
        hasDataError: Bool,
        completionHandler: @escaping (IPCTypes.FileSystemStorageError?) -> Void
    ) {
        let spaceRequired = computeCommandSpace(
            streamIdentifier,
            type: type,
            position: position,
            size: size,
            dataBytes: dataBytes,
            hasDataError: hasDataError
        )
        guard let spaceRequired, let manager = m_manager.get() else {
            _ = closeWritable(streamIdentifier, reason: .aborted)
            completionHandler(.unknown)
            return
        }

        let weakThis = WebKit.WeakPtrFileSystemStorageHandle(self, .Yes)
        manager.requestSpace(spaceRequired) { granted in
            guard let handle = weakThis.get() else {
                completionHandler(.unknown)
                return
            }

            if !granted {
                _ = handle.closeWritable(streamIdentifier, reason: .aborted)
                completionHandler(.quotaError)
                return
            }

            let error = handle.executeWriteCommand(
                streamIdentifier,
                type: type,
                position: position,
                size: size,
                dataBytes: dataBytes
            )
            if error != nil {
                _ = handle.closeWritable(streamIdentifier, reason: .aborted)
            }
            completionHandler(error)
        }
    }

    var writables: [IPCTypes.FileSystemWritableFileStreamIdentifier] {
        fileSystemStorageHandleStates.withState(for: swiftKey()) { Array($0.writables.keys) }
    }
}
