// Copyright (C) 2017 Apple Inc. All rights reserved.
// Copyright (C) 2022 Apple Inc. All rights reserved.
// Copyright (C) 2024 Apple, Inc. All rights reserved.
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

// MARK: State

private struct CacheStorageCacheState {
    struct VaryHeader {
        var name: [UInt16]
        var value: [UInt16]?
    }

    struct Record {
        enum Vary {
            case star
            case headers([VaryHeader])
        }

        var identifier: UInt64
        var size: UInt64
        var vary: Vary
    }

    var records: [[UInt16]: [Record]] = [:]
}

private let cacheStorageCacheStates = StateTable<CacheStorageCacheState>()
private let currentCacheStorageRecordIdentifier = Atomic<UInt64>(0)

private func nextCacheStorageRecordIdentifier() -> UInt64 {
    currentCacheStorageRecordIdentifier.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
}

private func isASCIIWhitespaceWithoutFF(_ character: UInt16) -> Bool {
    character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D
}

private func computeKeyURL(_ url: WTF.URL) -> [UInt16] {
    precondition(url.isValid())
    precondition(!url.isEmpty())
    let string = url.stringWithoutFragmentIdentifier()
    precondition(!string.isNull())
    return Array(string.utf16Units.prefix(Int(url.pathEnd())))
}

// MARK: Matching

// DOMCacheEngine's queryCacheMatch, for the records of one key URL.
private struct CacheStorageRecordMatcher {
    let requestURL: WTF.URL
    let ignoreSearch: Bool
    let ignoreMethod: Bool
    let ignoreVary: Bool
}

extension WebKit.CacheStorageCache {
    private static let getMethod: [UInt16] = Array("GET".utf16)
    private static let varyStar: [UInt16] = Array("*".utf16)
    private static let varySeparator = UInt16(UInt8(ascii: ","))

    private static func recordMatcher(
        _ requestURL: WTF.URL,
        ignoreSearch: Bool,
        ignoreMethod: Bool,
        ignoreVary: Bool
    ) -> CacheStorageRecordMatcher {
        CacheStorageRecordMatcher(
            requestURL: ignoreSearch ? urlWithoutQuery(requestURL) : requestURL,
            ignoreSearch: ignoreSearch,
            ignoreMethod: ignoreMethod,
            ignoreVary: ignoreVary
        )
    }

    private func matches(
        _ matcher: CacheStorageRecordMatcher,
        _ request: WebCore.ResourceRequest,
        _ record: CacheStorageCacheState.Record
    ) -> Bool {
        assert(matcher.ignoreMethod || Self.requestMethod(request).isEqual(utf16Units: Self.getMethod))
        let cachedURL = recordURL(record.identifier)
        guard WTF.equalIgnoringFragmentIdentifier(matcher.requestURL, matcher.ignoreSearch ? Self.urlWithoutQuery(cachedURL) : cachedURL)
        else {
            return false
        }
        if matcher.ignoreVary {
            return true
        }
        guard case .headers(let varyHeaders) = record.vary else {
            return false
        }
        return varyHeaders.allSatisfy {
            Self.requestHeaderField(request, WTF.String(utf16Units: $0.name)).isEqual(utf16Units: $0.value)
        }
    }

    @cxx
    @implementation
    static func varyHeaders(
        _ varyValue: WTF.String,
        _ tainting: WebCore.ResourceResponse.Tainting,
        _ requestHeaderFields: WebCore.HTTPHeaderMap
    ) -> WebKit.CacheStorageVaryHeaders {
        var varyHeaders = WebKit.CacheStorageVaryHeaders()
        if varyValue.isNull() || tainting == .Opaque || tainting == .Opaqueredirect {
            return varyHeaders
        }

        var addedNames: Set<[UInt16]> = []
        for slice in varyValue.utf16Units.split(separator: varySeparator) {
            let name = Array(slice)
            if !varyHeaders.hasVaryStar && name.lazy.filter({ !isASCIIWhitespaceWithoutFF($0) }).elementsEqual(varyStar) {
                varyHeaders.hasVaryStar = true
            }
            if addedNames.insert(name).inserted {
                var header = WebKit.CacheStorageVaryHeader()
                header.name = WTF.String(utf16Units: name)
                header.value = requestHeaderFields.valueForName(header.name)
                varyHeaders.headers.append(consuming: header)
            }
        }

        if varyHeaders.hasVaryStar {
            var starHeaders = WebKit.CacheStorageVaryHeaders()
            starHeaders.hasVaryStar = true
            return starHeaders
        }
        return varyHeaders
    }
}

// MARK: State and records

extension WebKit.CacheStorageCache {
    @cxx
    @implementation
    func initializeState() {
        cacheStorageCacheStates.insert(for: swiftKey()) { CacheStorageCacheState() }
    }

    @cxx
    @implementation
    func destroyState() {
        _ = cacheStorageCacheStates.take(for: swiftKey())
    }

    @cxx
    @implementation
    func origin() -> WebKit.OptionalClientOrigin {
        guard let manager = manager().get() else {
            return WebKit.OptionalClientOrigin()
        }
        return WebKit.OptionalClientOrigin(manager.clientOrigin)
    }

    private func weakPtr() -> WebKit.WeakPtrCacheStorageCache {
        WebKit.WeakPtrCacheStorageCache(self, .Yes)
    }

    private static func totalSize(_ recordInfos: borrowing WebKit.CacheStorageStore.RecordInformationVector) -> UInt64 {
        var size: UInt64 = 0
        for index in 0..<recordInfos.size() {
            // The sum wraps past UInt64.max.
            size &+= recordInfos[index].size()
        }
        return size
    }

    private func initializeRecords(_ recordInfos: WebKit.CacheStorageStore.RecordInformationVector) {
        let count = recordInfos.size()
        var keyedRecords: [([UInt16], CacheStorageCacheState.Record)] = []
        keyedRecords.reserveCapacity(count)
        for index in 0..<count {
            let identifier = nextCacheStorageRecordIdentifier()
            setRecordInformation(recordInfos[index], identifier)
            keyedRecords.append(
                (computeKeyURL(recordURL(identifier)), CacheStorageCacheState.Record(recordInfos[index], identifier: identifier))
            )
        }
        cacheStorageCacheStates.withState(for: swiftKey()) { state in
            for (keyURL, record) in keyedRecords {
                state.records[keyURL, default: []].append(record)
            }
        }
        m_isInitialized = true
    }

    @cxx
    @implementation
    func findRecords(_ options: WebCore.RetrieveRecordsOptions) -> WebKit.CacheStorageStore.RecordInformationVector {
        assert(m_isInitialized)
        assertIsOnCorrectQueue()

        var recordInfos = WebKit.CacheStorageStore.RecordInformationVector()
        let url = Self.requestURL(options.request)
        if url.isNull() {
            let identifiers = cacheStorageCacheStates.withState(for: swiftKey()) { state in
                state.records.values.flatMap { $0.map(\.identifier) }
            }
            for identifier in identifiers {
                recordInfos.append(consuming: recordInformation(identifier))
            }
            return recordInfos
        }

        if !options.ignoreMethod && !Self.requestMethod(options.request).isEqual(utf16Units: Self.getMethod) {
            return recordInfos
        }

        let keyURL = computeKeyURL(url)
        let records = cacheStorageCacheStates.withState(for: swiftKey()) { $0.records[keyURL] }
        guard let records else {
            return recordInfos
        }

        let matcher = Self.recordMatcher(
            url,
            ignoreSearch: options.ignoreSearch,
            ignoreMethod: options.ignoreMethod,
            ignoreVary: options.ignoreVary
        )
        for record in records where matches(matcher, options.request, record) {
            recordInfos.append(consuming: recordInformation(record.identifier))
        }
        return recordInfos
    }
}

// MARK: Indexed records

extension CacheStorageCacheState.Record {
    init(_ recordInfo: WebKit.CacheStorageRecordInformation, identifier: UInt64) {
        self.identifier = identifier
        size = recordInfo.size()
        let varyHeaders = recordInfo.varyHeaders()
        if varyHeaders.hasVaryStar {
            vary = .star
            return
        }
        var headers: [CacheStorageCacheState.VaryHeader] = []
        for header in varyHeaders.headers {
            headers.append(.init(name: header.name.utf16Units, value: header.value.nullableUTF16Units))
        }
        vary = .headers(headers)
    }
}

extension WebKit.CacheStorageCache {
    private var indexedRecordsSize: UInt64 {
        assertIsOnCorrectQueue()
        return cacheStorageCacheStates.withState(for: swiftKey()) { state in
            var size: UInt64 = 0
            for records in state.records.values {
                for record in records {
                    // The sum wraps past UInt64.max.
                    size &+= record.size
                }
            }
            return size
        }
    }

    private func existingRecord(for request: WebCore.ResourceRequest, identifier: UInt64? = nil) -> CacheStorageCacheState.Record? {
        assertIsOnCorrectQueue()
        let url = Self.requestURL(request)
        let keyURL = computeKeyURL(url)
        guard let records = cacheStorageCacheStates.withState(for: swiftKey(), { $0.records[keyURL] }) else {
            return nil
        }
        let matcher = Self.recordMatcher(url, ignoreSearch: false, ignoreMethod: false, ignoreVary: false)
        return records.first { (identifier == nil || identifier == $0.identifier) && matches(matcher, request, $0) }
    }

    private func insertRecord(_ recordInfo: WebKit.CacheStorageRecordInformation) {
        assertIsOnCorrectQueue()
        let identifier = recordInfo.identifier()
        setRecordInformation(recordInfo, identifier)
        let keyURL = computeKeyURL(recordURL(identifier))
        let record = CacheStorageCacheState.Record(recordInfo, identifier: identifier)
        cacheStorageCacheStates.withState(for: swiftKey()) { state in
            state.records[keyURL, default: []].append(record)
        }
    }

    private func replaceRecord(_ identifier: UInt64, with recordInfo: WebKit.CacheStorageRecordInformation) {
        assertIsOnCorrectQueue()
        let keyURL = computeKeyURL(recordURL(identifier))
        setRecordInformation(recordInfo, identifier)
        let record = CacheStorageCacheState.Record(recordInfo, identifier: identifier)
        cacheStorageCacheStates.withState(for: swiftKey()) { state in
            guard let position = state.records[keyURL]?.firstIndex(where: { $0.identifier == identifier }) else {
                preconditionFailure("The record to replace is in the cache")
            }
            state.records[keyURL]?[position] = record
        }
    }

    private func removeMatchingRecords(
        _ request: WebCore.ResourceRequest,
        _ options: WebCore.CacheQueryOptions
    ) -> [CacheStorageCacheState.Record]? {
        assertIsOnCorrectQueue()
        let url = Self.requestURL(request)
        let keyURL = computeKeyURL(url)
        guard let bucket = cacheStorageCacheStates.withState(for: swiftKey(), { $0.records.removeValue(forKey: keyURL) }) else {
            return nil
        }
        let matcher = Self.recordMatcher(
            url,
            ignoreSearch: options.ignoreSearch,
            ignoreMethod: options.ignoreMethod,
            ignoreVary: options.ignoreVary
        )
        var removed: [CacheStorageCacheState.Record] = []
        var kept: [CacheStorageCacheState.Record] = []
        for record in bucket {
            if matches(matcher, request, record) {
                removed.append(record)
            } else {
                kept.append(record)
            }
        }
        if !kept.isEmpty {
            cacheStorageCacheStates.withState(for: swiftKey()) { $0.records[keyURL] = kept }
        }
        return removed
    }

    private func removeAllIndexedRecords() -> WebKit.CacheStorageStore.RecordInformationVector {
        assertIsOnCorrectQueue()
        let records = cacheStorageCacheStates.withState(for: swiftKey()) { exchange(&$0.records, with: [:]) }
        var recordInfos = WebKit.CacheStorageStore.RecordInformationVector()
        for bucket in records.values {
            for record in bucket {
                recordInfos.append(consuming: recordInformation(record.identifier))
            }
        }
        clearRecordInformations()
        return recordInfos
    }
}

// MARK: Store operations

typealias CacheStorageRecordIdentifiersResult = CacheStorageResult<[UInt64]>

private final class CacheStoragePutRecords {
    var records: WebKit.CacheStorageRecordVector
    let completion: (CacheStorageRecordIdentifiersResult) -> Void

    init(_ records: consuming WebKit.CacheStorageRecordVector, _ completion: @escaping (CacheStorageRecordIdentifiersResult) -> Void) {
        self.records = consume records
        self.completion = completion
    }
}

extension WebKit.CacheStorageCache {
    @cxx
    @implementation
    func readRecordsForPendingOpens() {
        let weakThis = weakPtr()
        m_store.get()
            .readAllRecordInfos(
                consuming: WebKit.CacheStorageStore.ReadAllRecordInfosCallback { recordInfos in
                    guard let cache = weakThis.get() else {
                        return
                    }
                    cache.assertIsOnCorrectQueue()
                    var recordInfos = consume recordInfos
                    Self.sortByInsertionTime(&recordInfos)
                    cache.initializeRecords(recordInfos)
                    cache.answerPendingOpens(true)
                }
            )
    }

    @cxx
    @implementation
    func answerPendingOpens(_ opened: Bool) {
        for index in 0..<m_pendingOpens.size() {
            m_pendingOpens[index](opened)
        }
        m_pendingOpens.clear()
    }

    func getSize(_ completion: @escaping (UInt64) -> Void) {
        assertIsOnCorrectQueue()

        if m_isInitialized {
            completion(indexedRecordsSize)
            return
        }

        m_store.get()
            .readAllRecordInfos(
                consuming: WebKit.CacheStorageStore.ReadAllRecordInfosCallback { recordInfos in
                    completion(Self.totalSize(recordInfos))
                }
            )
    }

    func removeRecords(
        _ request: WebCore.ResourceRequest,
        _ options: WebCore.CacheQueryOptions,
        _ completion: @escaping (CacheStorageRecordIdentifiersResult) -> Void
    ) {
        assert(m_isInitialized)
        assertIsOnCorrectQueue()

        if !options.ignoreMethod && !Self.requestMethod(request).isEqual(utf16Units: Self.getMethod) {
            completion(.success([]))
            return
        }

        guard let removedRecords = removeMatchingRecords(request, options) else {
            completion(.success([]))
            return
        }

        var targetRecordInfos = WebKit.CacheStorageStore.RecordInformationVector()
        for record in removedRecords {
            targetRecordInfos.append(consuming: recordInformation(record.identifier))
            removeRecordInformation(record.identifier)
        }
        let targetIdentifiers = removedRecords.map(\.identifier)
        let sizeDecreased = Self.totalSize(targetRecordInfos)

        if let manager = manager().get(), sizeDecreased != 0 {
            manager.sizeDecreased(sizeDecreased)
        }

        m_store.get()
            .deleteRecords(
                targetRecordInfos,
                consuming: WTF.BoolCompletionHandler { succeeded in
                    completion(succeeded ? .success(targetIdentifiers) : .failure(IPCUnexpected(.writeDisk)))
                }
            )
    }

    private func spaceRequested(for records: borrowing WebKit.CacheStorageRecordVector) -> UInt64? {
        var spaceRequested: UInt64 = 0
        var spaceAvailable: UInt64 = 0
        for index in 0..<records.size() {
            let (requested, requestedOverflowed) = spaceRequested.addingReportingOverflow(records[index].info.size())
            var (available, availableOverflowed) = (spaceAvailable, false)
            if let existingRecord = existingRecord(for: records[index].request) {
                (available, availableOverflowed) = spaceAvailable.addingReportingOverflow(existingRecord.size)
            }
            if requestedOverflowed || availableOverflowed {
                return nil
            }
            let spaceUsed = min(requested, available)
            spaceRequested = requested - spaceUsed
            spaceAvailable = available - spaceUsed
        }
        return spaceRequested
    }

    func putRecords(
        _ records: consuming WebKit.CacheStorageRecordVector,
        _ completion: @escaping (CacheStorageRecordIdentifiersResult) -> Void
    ) {
        assert(m_isInitialized)
        assertIsOnCorrectQueue()

        guard let manager = manager().get() else {
            completion(.failure(IPCUnexpected(.internal)))
            return
        }

        let requested = spaceRequested(for: records)
        let put = CacheStoragePutRecords(records, completion)
        let weakThis = weakPtr()
        // The request still needs to go through quota check to keep ordering.
        manager.requestSpace(
            requested ?? 0,
            consuming: WTF.BoolCompletionHandler { granted in
                guard let cache = weakThis.get() else {
                    put.completion(.failure(IPCUnexpected(.internal)))
                    return
                }
                guard requested != nil else {
                    WebKit.LogChannel.Storage().releaseLog
                        .error("CacheStorageCache::putRecords failed because the amount of space requested is invalid")
                    put.completion(.failure(IPCUnexpected(.internal)))
                    return
                }
                guard granted else {
                    put.completion(.failure(IPCUnexpected(.quotaExceeded)))
                    return
                }
                cache.putRecordsAfterQuotaCheck(put)
            }
        )
    }

    private func putRecordsAfterQuotaCheck(_ put: CacheStoragePutRecords) {
        assert(m_isInitialized)
        assertIsOnCorrectQueue()

        var targetRecordInfos = WebKit.CacheStorageStore.RecordInformationVector()
        for index in 0..<put.records.size() {
            if let existingRecord = existingRecord(for: put.records[index].request) {
                put.records[index].info.setIdentifier(existingRecord.identifier)
                targetRecordInfos.append(consuming: recordInformation(existingRecord.identifier))
            }
        }

        let weakThis = weakPtr()
        m_store.get()
            .readRecords(
                targetRecordInfos,
                consuming: WebKit.CacheStorageStore.ReadRecordsCallback { existingRecords in
                    guard let cache = weakThis.get() else {
                        put.completion(.failure(IPCUnexpected(.internal)))
                        return
                    }
                    cache.putRecordsInStore(put, existingRecords)
                }
            )
    }

    private func putRecordsInStore(_ put: CacheStoragePutRecords, _ existingRecords: borrowing WebKit.CacheStorageStore.ReadRecordsResult) {
        assertIsOnCorrectQueue()

        var records = exchange(&put.records, with: WebKit.CacheStorageRecordVector())
        var targetIdentifiers: [UInt64] = []
        var sizeIncreased: UInt64 = 0
        var sizeDecreased: UInt64 = 0
        for index in 0..<records.size() {
            let identifier = records[index].info.identifier()
            if identifier == 0 {
                records[index].info.setIdentifier(nextCacheStorageRecordIdentifier())
                sizeIncreased &+= records[index].info.size()
                insertRecord(records[index].info)
            } else {
                // Ensure record still exists.
                guard Self.containsRecord(existingRecords, identifier) else {
                    records[index].info.setIdentifier(0)
                    continue
                }

                // Ensure identifier still exists.
                guard existingRecord(for: records[index].request, identifier: identifier) != nil else {
                    records[index].info.setIdentifier(0)
                    continue
                }

                let existingRecordInfo = recordInformation(identifier)
                Self.setKeyAndInsertionTime(&records[index].info, existingRecordInfo)
                sizeIncreased &+= records[index].info.size()
                sizeDecreased &+= existingRecordInfo.size()
                replaceRecord(identifier, with: records[index].info)
            }
            targetIdentifiers.append(records[index].info.identifier())
        }

        Self.removeRecordsWithoutIdentifier(&records)

        if let manager = manager().get() {
            if sizeIncreased > sizeDecreased {
                manager.sizeIncreased(sizeIncreased - sizeDecreased)
            } else if sizeDecreased > sizeIncreased {
                manager.sizeDecreased(sizeDecreased - sizeIncreased)
            }
        }

        m_store.get()
            .writeRecords(
                consuming: records,
                consuming: WTF.BoolCompletionHandler { succeeded in
                    put.completion(succeeded ? .success(targetIdentifiers) : .failure(IPCUnexpected(.writeDisk)))
                }
            )
    }

    func removeAllRecords() {
        assertIsOnCorrectQueue()

        let targetRecordInfos = removeAllIndexedRecords()
        let sizeDecreased = Self.totalSize(targetRecordInfos)

        if let manager = manager().get(), sizeDecreased != 0 {
            manager.sizeDecreased(sizeDecreased)
        }

        m_store.get().deleteRecords(targetRecordInfos, consuming: WTF.BoolCompletionHandler { _ in })
    }

    func close() {
        assertIsOnCorrectQueue()
        cacheStorageCacheStates.withState(for: swiftKey()) { $0.records = [:] }
        m_isInitialized = false
        clearRecordInformations()
    }
}
