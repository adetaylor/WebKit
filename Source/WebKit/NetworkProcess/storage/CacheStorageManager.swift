// Copyright (C) 2022-2025 Apple Inc. All rights reserved.
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

import Synchronization
import WebKit_Internal

private let cacheStorageUpdateNumber = Atomic<UInt64>(0)

// DOMCacheIdentifier is not Hashable in Swift.
private struct CacheKey: Hashable {
    let object: UInt64
    let process: UInt64

    init(_ identifier: WebCore.DOMCacheIdentifier) {
        object = identifier.objectValue().toUInt64()
        process = identifier.processIdentifier().toUInt64()
    }
}

private struct CacheStorageManagerState {
    enum Size {
        case unknown
        case computing(total: UInt64, remaining: Set<CacheKey>)
        case known(UInt64)

        var isKnown: Bool {
            if case .known = self {
                return true
            }
            return false
        }
    }

    struct CacheReferences {
        let identifier: WebCore.DOMCacheIdentifier
        var connections: [UInt64]
    }

    var updateCounter: UInt64
    var size = Size.unknown
    var cacheRefConnections: [CacheKey: CacheReferences] = [:]
    var activeConnections: Set<UInt64> = []
}

private let cacheStorageManagerStates = StateTable<CacheStorageManagerState>()

typealias CacheStorageResult<Success> = Result<Success, IPCUnexpected<IPCTypes.DOMCacheEngineError>>

private func nextCacheStorageUpdateNumber() -> UInt64 {
    cacheStorageUpdateNumber.add(1, ordering: .relaxed).newValue
}

// MARK: State and connections

extension WebKit.CacheStorageManager {
    @cxx
    @implementation
    func initializeState() {
        cacheStorageManagerStates.insert(for: swiftKey()) {
            CacheStorageManagerState(updateCounter: nextCacheStorageUpdateNumber())
        }
    }

    @cxx
    @implementation
    func destroyState() {
        _ = cacheStorageManagerStates.take(for: swiftKey())
    }

    @cxx
    @implementation
    func resetState() {
        cacheStorageManagerStates.withState(for: swiftKey()) { state in
            state.size = .unknown
            state.cacheRefConnections = [:]
        }
        makeDirty()
    }

    var clientOrigin: WebCore.ClientOrigin {
        m_origin
    }

    private func makeDirty() {
        let updateCounter = nextCacheStorageUpdateNumber()
        cacheStorageManagerStates.withState(for: swiftKey()) { $0.updateCounter = updateCounter }
    }

    @cxx
    @implementation
    static func copySaltFileToOriginDirectory(_ rootDirectory: WTF.String, _ originDirectory: WTF.String) {
        guard WTF.FileSystemImpl.fileExists(originDirectory) else {
            return
        }
        let targetFilePath = saltFilePath(originDirectory)
        guard !WTF.FileSystemImpl.fileExists(targetFilePath) else {
            return
        }
        _ = WTF.FileSystemImpl.hardLinkOrCopyFile(saltFilePath(rootDirectory), targetFilePath)
    }

    @cxx
    @implementation
    func reference(_ connection: IPC.Connection.UniqueID, _ cacheIdentifier: WebCore.DOMCacheIdentifier) {
        let cacheKey = CacheKey(cacheIdentifier)
        let connectionKey = connection.toUInt64()
        let references = CacheStorageManagerState.CacheReferences(identifier: cacheIdentifier, connections: [])
        cacheStorageManagerStates.withState(for: swiftKey()) { state in
            state.cacheRefConnections[cacheKey, default: references].connections.append(connectionKey)
        }
    }

    @cxx
    @implementation
    func dereference(_ connection: IPC.Connection.UniqueID, _ cacheIdentifier: WebCore.DOMCacheIdentifier) {
        let cacheKey = CacheKey(cacheIdentifier)
        let connectionKey = connection.toUInt64()
        let isUnused = cacheStorageManagerStates.withState(for: swiftKey()) { state in
            guard let keyIndex = state.cacheRefConnections.index(forKey: cacheKey),
                let index = state.cacheRefConnections.values[keyIndex].connections.firstIndex(of: connectionKey)
            else {
                return false
            }
            state.cacheRefConnections.values[keyIndex].connections.remove(at: index)
            return state.cacheRefConnections.values[keyIndex].connections.isEmpty
        }
        if isUnused {
            removeUnusedCache(cacheIdentifier)
        }
    }

    func lockStorage(_ connection: IPC.Connection.UniqueID) {
        let connectionKey = connection.toUInt64()
        let inserted = cacheStorageManagerStates.withState(for: swiftKey()) { $0.activeConnections.insert(connectionKey).inserted }
        assert(inserted)
    }

    func unlockStorage(_ connection: IPC.Connection.UniqueID) {
        let connectionKey = connection.toUInt64()
        let removed = cacheStorageManagerStates.withState(for: swiftKey()) { $0.activeConnections.remove(connectionKey) }
        assert(removed != nil)
    }

    @cxx
    @implementation
    func connectionClosed(_ connection: IPC.Connection.UniqueID) {
        let connectionKey = connection.toUInt64()
        let unusedCacheIdentifiers = cacheStorageManagerStates.withState(for: swiftKey()) { state -> [WebCore.DOMCacheIdentifier] in
            state.activeConnections.remove(connectionKey)
            var unusedCacheIdentifiers: [WebCore.DOMCacheIdentifier] = []
            for cacheKey in Array(state.cacheRefConnections.keys) {
                state.cacheRefConnections[cacheKey]?.connections.removeAll { $0 == connectionKey }
                if let references = state.cacheRefConnections[cacheKey], references.connections.isEmpty {
                    state.cacheRefConnections[cacheKey] = nil
                    unusedCacheIdentifiers.append(references.identifier)
                }
            }
            return unusedCacheIdentifiers
        }
        for cacheIdentifier in unusedCacheIdentifiers {
            removeUnusedCache(cacheIdentifier)
        }
    }

    private func removeUnusedCache(_ identifier: WebCore.DOMCacheIdentifier) {
        if let removedCache = m_removedCaches.take(identifier).get() {
            removedCache.removeAllRecords()
            m_registry.get().unregisterCache(identifier)
            return
        }

        for cache in caches where cache.cacheIdentifier().isEqual(identifier) {
            cache.close()
            return
        }
    }

    @cxx
    @implementation
    func isActive() -> Bool {
        cacheStorageManagerStates.withState(for: swiftKey()) { !$0.cacheRefConnections.isEmpty || !$0.activeConnections.isEmpty }
    }
}

// MARK: Caches

extension WebKit.CacheStorageCache {
    fileprivate func openForIdentifier(_ completion: @escaping (CacheStorageResult<WebCore.DOMCacheIdentifier>) -> Void) {
        let identifier = cacheIdentifier()
        open(
            consuming: WTF.BoolCompletionHandler { opened in
                completion(opened ? .success(identifier) : .failure(IPCUnexpected(.internal)))
            }
        )
    }
}

private final class CacheStorageOpensAggregator {
    private let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    deinit {
        completion()
    }
}

extension WebKit.CacheStorageManager {
    private var caches: [WebKit.CacheStorageCache] {
        (0..<m_caches.size()).map { m_caches[$0].get() }
    }

    private func findCache(named name: WTF.String) -> WebKit.CacheStorageCache? {
        let units = name.nullableUTF16Units
        for index in 0..<m_caches.size() {
            let cache = m_caches[index].get()
            if cache.copiedName().isEqual(utf16Units: units) {
                return cache
            }
        }
        return nil
    }

    private func cacheIndex(for identifier: WebCore.DOMCacheIdentifier) -> Int? {
        for index in 0..<m_caches.size() where m_caches[index].get().cacheIdentifier().isEqual(identifier) {
            return index
        }
        return nil
    }

    private func appendCache(_ name: WTF.String, _ uniqueName: WTF.String) -> WebKit.CacheStorageCache {
        let cache = WebKit.CacheStorageCache.create(self, name, uniqueName, m_path, consuming: m_queue.copyRef())
        let appendedCache: WebKit.CacheStorageCache = cache.ptr()
        m_caches.append(consuming: cache)
        return appendedCache
    }

    private func cacheInfos() -> WebCore.DOMCacheEngine.CacheInfos {
        var cacheInfos = WebCore.DOMCacheEngine.CacheInfos()
        for cache in caches {
            let info = WebCore.DOMCacheEngine.CacheInfo(identifier: cache.cacheIdentifier(), name: cache.copiedName())
            cacheInfos.infos.append(consuming: info)
        }
        cacheInfos.updateCounter = cacheStorageManagerStates.withState(for: swiftKey()) { $0.updateCounter }
        return cacheInfos
    }

    @cxx
    @implementation
    func initializeCaches() -> Bool {
        if m_isInitialized {
            return true
        }
        guard let cachesList = cachesList().value else {
            return false
        }

        m_isInitialized = true
        for entry in cachesList {
            let cache = appendCache(entry.first, entry.second)
            m_registry.get().registerCache(cache.cacheIdentifier(), cache)
        }
        return true
    }

    func openCache(_ name: WTF.String, _ completion: @escaping (CacheStorageResult<WebCore.DOMCacheIdentifier>) -> Void) {
        guard initializeCaches() else {
            completion(.failure(IPCUnexpected(.readDisk)))
            return
        }

        if let cache = findCache(named: name) {
            cache.openForIdentifier(completion)
            return
        }

        let cache = appendCache(name, WTF.createVersion4UUIDString())
        guard writeCachesList(WebKit.OptionalSize()) else {
            m_caches.removeLast()
            completion(.failure(IPCUnexpected(.writeDisk)))
            return
        }

        makeDirty()
        m_registry.get().registerCache(cache.cacheIdentifier(), cache)
        cache.openForIdentifier(completion)
    }

    func removeCache(_ cacheIdentifier: WebCore.DOMCacheIdentifier) -> CacheStorageResult<Bool> {
        guard let index = cacheIndex(for: cacheIdentifier) else {
            return .success(false)
        }
        guard writeCachesList(WebKit.OptionalSize(UInt(index))) else {
            return .failure(IPCUnexpected(.writeDisk))
        }

        makeDirty()
        moveCacheToRemoved(index)
        return .success(true)
    }

    func allCaches(_ completion: @escaping (CacheStorageResult<WebCore.DOMCacheEngine.CacheInfos>) -> Void) {
        guard initializeCaches() else {
            completion(.failure(IPCUnexpected(.readDisk)))
            return
        }

        let cacheInfos = self.cacheInfos()
        let aggregator = CacheStorageOpensAggregator {
            completion(.success(cacheInfos))
        }
        withExtendedLifetime(aggregator) {
            for cache in caches {
                cache.open(
                    consuming: WTF.BoolCompletionHandler { _ in
                        withExtendedLifetime(aggregator) {}
                    }
                )
            }
        }
    }

    @cxx
    @implementation
    func hasDataInMemory() -> Bool {
        // Cache data is stored on disk.
        if !m_path.isEmpty() {
            return false
        }
        return !m_caches.isEmpty() || !removedCacheIdentifiers().isEmpty()
    }

    @cxx
    @implementation
    func representationString() -> WTF.String {
        func quotedNames(_ names: [WTF.String]) -> [UInt16] {
            Array(names.map { Array("\"".utf16) + $0.utf16Units + Array("\"".utf16) }.joined(separator: Array(", ".utf16)))
        }
        let removedCacheIdentifiers = self.removedCacheIdentifiers()
        let removedNames = Array(removedCacheIdentifiers).compactMap { m_removedCaches.get($0)?.copiedName() }
        let units =
            Array("{ \"persistent\": [".utf16) + quotedNames(caches.map { $0.copiedName() })
            + Array("], \"removed\": [".utf16) + quotedNames(removedNames) + Array("]}\n".utf16)
        return WTF.String(utf16Units: units)
    }
}

// MARK: Size

extension WebKit.CacheStorageManager {
    fileprivate static let sizeFileName = Array("estimatedsize".utf16)
    fileprivate static let blobsDirectoryName = Array("Blobs".utf16)
}

private func sizeFilePath(_ sizeDirectoryPath: WTF.String) -> WTF.String {
    WebKit.fileSystemPathByAppendingComponent(sizeDirectoryPath, WTF.String(utf16Units: WebKit.CacheStorageManager.sizeFileName))
}

private func readSizeFile(_ sizeDirectoryPath: WTF.String) -> UInt64? {
    if sizeDirectoryPath.isEmpty() {
        return nil
    }
    let path = sizeFilePath(sizeDirectoryPath)
    guard WTF.FileSystemImpl.fileExists(path), let buffer = WTF.FileSystemImpl.readEntireFile(path).value else {
        return nil
    }
    return (0..<buffer.size()).map { buffer[$0] }.parseUnsignedInteger()
}

private func writeSizeFile(_ sizeDirectoryPath: WTF.String, _ size: UInt64) {
    if sizeDirectoryPath.isEmpty() {
        return
    }
    let value = Array(String(size).utf8)
    _ = WebKit.fileSystemOverwriteEntireFile(sizeFilePath(sizeDirectoryPath), value.span)
}

private func getDirectorySize(_ originDirectory: WTF.String) -> UInt64 {
    var directorySize: UInt64 = 0
    var paths = [originDirectory]
    while let path = paths.popLast() {
        if WTF.FileSystemImpl.fileType(path).value == .Directory {
            let fileNames = WTF.FileSystemImpl.listDirectory(path)
            for fileName in fileNames {
                // Files in /Blobs directory are hard link.
                if fileName.utf16Units == WebKit.CacheStorageManager.blobsDirectoryName {
                    continue
                }
                paths.append(WebKit.fileSystemPathByAppendingComponent(path, fileName))
            }
            continue
        }
        directorySize &+= WTF.FileSystemImpl.fileSize(path).value ?? 0
    }
    return directorySize
}

extension WebKit.CacheStorageManager {
    @cxx
    @implementation
    static func cacheStorageSize(_ originDirectory: WTF.String) -> UInt64 {
        readSizeFile(originDirectory) ?? getDirectorySize(originDirectory)
    }

    func requestSpace(_ spaceRequested: UInt64, consuming completion: consuming WTF.BoolCompletionHandler) {
        let isSizeKnown = cacheStorageManagerStates.withState(for: swiftKey()) { $0.size.isKnown }
        if isSizeKnown {
            m_quotaCheckFunction(spaceRequested, consuming: completion)
            return
        }

        let isFirstPendingRequest = appendPendingSpaceRequest(spaceRequested, consuming: completion)
        guard isFirstPendingRequest else {
            return
        }

        let caches = self.caches
        let removedCacheIdentifiers = self.removedCacheIdentifiers()
        var removedCaches: [WebKit.CacheStorageCache] = []
        var pendingSizeCaches = Set(caches.map { CacheKey($0.cacheIdentifier()) })
        for identifier in removedCacheIdentifiers {
            pendingSizeCaches.insert(CacheKey(identifier))
            if let cache = m_removedCaches.get(identifier) {
                removedCaches.append(cache)
            }
        }
        cacheStorageManagerStates.withState(for: swiftKey()) { $0.size = .computing(total: 0, remaining: pendingSizeCaches) }

        for cache in caches + removedCaches {
            initializeCacheSize(cache)
        }
    }

    private func initializeCacheSize(_ cache: WebKit.CacheStorageCache) {
        let weakThis = WebKit.WeakPtrCacheStorageManager(self, .Yes)
        let cacheKey = CacheKey(cache.cacheIdentifier())
        cache.getSize { size in
            guard let manager = weakThis.get() else {
                return
            }
            let finishedSize = cacheStorageManagerStates.withState(for: manager.swiftKey()) { state -> UInt64? in
                guard case .computing(var total, var remaining) = state.size, remaining.remove(cacheKey) != nil else {
                    return nil
                }
                total &+= size
                guard remaining.isEmpty else {
                    state.size = .computing(total: total, remaining: remaining)
                    return nil
                }
                state.size = .known(total)
                return total
            }
            if let finishedSize {
                manager.finishInitializingSize(finishedSize)
            }
        }
    }

    private func finishInitializingSize(_ size: UInt64) {
        writeSizeFile(m_path, size)
        checkPendingSpaceRequests()
    }

    func sizeIncreased(_ amount: UInt64) {
        updateSize(ifNonzero: amount) { $0 &+ amount }
    }

    func sizeDecreased(_ amount: UInt64) {
        updateSize(ifNonzero: amount) { $0 > amount ? $0 - amount : 0 }
    }

    private func updateSize(ifNonzero amount: UInt64, _ newSize: (UInt64) -> UInt64) {
        guard amount != 0 else {
            return
        }
        let size = cacheStorageManagerStates.withState(for: swiftKey()) { state -> UInt64? in
            guard case .known(let size) = state.size else {
                return nil
            }
            let updatedSize = newSize(size)
            state.size = .known(updatedSize)
            return updatedSize
        }
        if let size {
            writeSizeFile(m_path, size)
        }
    }
}
