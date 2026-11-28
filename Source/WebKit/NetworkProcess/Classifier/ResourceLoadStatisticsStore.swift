// Copyright (C) 2019-2025 Apple Inc. All rights reserved.
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

#if canImport(SQLite3)
import SQLite3
#endif
import WebKit_Internal

// MARK: SQLite access

// Statements are freed when the database closes; a handle names a slot and generation the store checks on every use.
extension WebKit.ResourceLoadStatisticsStore {
    struct SQLStatement: ~Copyable {
        private let store: WebKit.ResourceLoadStatisticsStore
        private let handle: WebKit.SQLStatementHandle

        fileprivate init?(_ store: WebKit.ResourceLoadStatisticsStore, _ handle: WebKit.SQLStatementHandle) {
            guard handle.isValid() else {
                return nil
            }
            self.store = store
            self.handle = handle
        }

        deinit {
            store.closeStatement(handle)
        }

        func bindInt(_ index: Int32, _ value: Int32) -> Int32 { store.bindInt(handle, index, value) }
        func bindText(_ index: Int32, _ value: WTF.String) -> Int32 { store.bindText(handle, index, value) }
        func bindDouble(_ index: Int32, _ value: Double) -> Int32 { store.bindDouble(handle, index, value) }
        func step() -> Int32 { store.step(handle) }
        func reset() -> Int32 { store.reset(handle) }
        func columnInt(_ column: Int32) -> Int32 { store.columnInt(handle, column) }
        func columnText(_ column: Int32) -> WTF.String { store.columnText(handle, column) }
        func columnDouble(_ column: Int32) -> Double { store.columnDouble(handle, column) }
    }

    struct Database {
        fileprivate let store: WebKit.ResourceLoadStatisticsStore

        func prepareStatement(_ query: WTF.String) -> SQLStatement? { SQLStatement(store, store.openStatement(query)) }
        fileprivate func prepareRelationshipStatement(_ query: RelationshipQuery, _ domainCount: UInt32) -> SQLStatement? {
            let placeholders = Array(repeating: "?", count: Int(domainCount)).joined(separator: ", ")
            return prepareStatement(WTF.String(query.prefix + placeholders + " );"))
        }
        func lastError() -> Int32 { store.databaseLastError() }
        func lastErrorMsg() -> WTF.String { store.databaseLastErrorMsg() }
        func runIncrementalVacuumCommand() -> Int32 { store.databaseRunIncrementalVacuumCommand() }
        func clearAllTables() { store.databaseClearAllTables() }
    }

    var database: Database { Database(store: self) }

    fileprivate func scopedStatement(_ statement: CachedStatement, _ logLabel: StaticString) -> SQLStatement? {
        SQLStatement(self, prepareCachedStatement(statement.rawValue, WTF.String(statement.query), WTF.String(logLabel.description)))
    }

    // A case's raw value is its slot in the store's statement cache, which has resourceLoadStatisticsCachedStatementCount
    // slots: openAndUpdateSchemaIfNecessary() asserts that there are as many cases.
    fileprivate enum CachedStatement: UInt8, CaseIterable {
        case observedDomainCount
        case insertObservedDomain
        case domainIDFromString
        case subframeUnderTopFrameDomainExists
        case subresourceUnderTopFrameDomainExists
        case subresourceUniqueRedirectsToExists
        case mostRecentUserInteraction
        case updateLastSeen
        case updateDataRecordsRemoved
        case updatePrevalentResource
        case isPrevalentResource
        case updateVeryPrevalentResource
        case isVeryPrevalentResource
        case clearPrevalentResource
        case hadUserInteraction
        case updateGrandfathered
        case isScheduledForAllButCookieDataRemoval
        case updateIsScheduledForAllButCookieDataRemoval
        case updateMostRecentWebPushInteractionTime
        case isGrandfathered
        case getResourceDataByDomainName
        case getAllDomains
        case domainStringFromDomainID
        case getAllSubStatistics
        case storageAccessExists
        case getMostRecentlyUpdatedTimestamp
        case linkDecorationExists
        case scriptLoadExists
        case subFrameExists
        case subResourceExists
        case uniqueRedirectExists
        case observedDomainsExists
        case removeAllData
        case checkIfTableExists

        var query: Swift.String {
            switch self {
            case .observedDomainCount:
                "SELECT COUNT(*) FROM ObservedDomains"
            case .insertObservedDomain:
                "INSERT INTO ObservedDomains (registrableDomain, lastSeen, hadUserInteraction,"
                    + "mostRecentUserInteractionTime, grandfathered, isPrevalent, isVeryPrevalent, dataRecordsRemoved,"
                    + " timesAccessedAsFirstPartyDueToUserInteraction,"
                    + "timesAccessedAsFirstPartyDueToStorageAccessAPI, isScheduledForAllButCookieDataRemoval,"
                    + " mostRecentWebPushInteractionTime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            case .domainIDFromString:
                "SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?"
            case .subframeUnderTopFrameDomainExists:
                "SELECT EXISTS (SELECT 1 FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ? "
                    + "AND topFrameDomainID = (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"
            case .subresourceUnderTopFrameDomainExists:
                "SELECT EXISTS (SELECT 1 FROM SubresourceUnderTopFrameDomains "
                    + "WHERE subresourceDomainID = ? AND topFrameDomainID = (SELECT domainID FROM ObservedDomains"
                    + " WHERE registrableDomain = ?))"
            case .subresourceUniqueRedirectsToExists:
                "SELECT EXISTS (SELECT 1 FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? "
                    + "AND toDomainID = (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"
            case .mostRecentUserInteraction:
                "UPDATE ObservedDomains SET hadUserInteraction = ?, mostRecentUserInteractionTime = ? WHERE registrableDomain = ?"
            case .updateLastSeen:
                "UPDATE ObservedDomains SET lastSeen = ? WHERE registrableDomain = ?"
            case .updateDataRecordsRemoved:
                "UPDATE ObservedDomains SET dataRecordsRemoved = ? WHERE registrableDomain = ?"
            case .updatePrevalentResource:
                "UPDATE ObservedDomains SET isPrevalent = ? WHERE registrableDomain = ?"
            case .isPrevalentResource:
                "SELECT isPrevalent FROM ObservedDomains WHERE registrableDomain = ?"
            case .updateVeryPrevalentResource:
                "UPDATE ObservedDomains SET isVeryPrevalent = ? WHERE registrableDomain = ?"
            case .isVeryPrevalentResource:
                "SELECT isVeryPrevalent FROM ObservedDomains WHERE registrableDomain = ?"
            case .clearPrevalentResource:
                "UPDATE ObservedDomains SET isPrevalent = 0, isVeryPrevalent = 0 WHERE registrableDomain = ?"
            case .hadUserInteraction:
                "SELECT hadUserInteraction, mostRecentUserInteractionTime FROM ObservedDomains WHERE registrableDomain = ?"
            case .updateGrandfathered:
                "UPDATE ObservedDomains SET grandfathered = ? WHERE registrableDomain = ?"
            case .isScheduledForAllButCookieDataRemoval:
                "SELECT isScheduledForAllButCookieDataRemoval FROM ObservedDomains WHERE registrableDomain = ?"
            case .updateIsScheduledForAllButCookieDataRemoval:
                "UPDATE ObservedDomains SET isScheduledForAllButCookieDataRemoval = ? WHERE registrableDomain = ?"
            case .updateMostRecentWebPushInteractionTime:
                "UPDATE ObservedDomains SET mostRecentWebPushInteractionTime = ? WHERE registrableDomain = ?"
            case .isGrandfathered:
                "SELECT grandfathered FROM ObservedDomains WHERE registrableDomain = ?"
            case .getResourceDataByDomainName:
                "SELECT * FROM ObservedDomains WHERE registrableDomain = ?"
            case .getAllDomains:
                "SELECT registrableDomain FROM ObservedDomains"
            case .domainStringFromDomainID:
                "SELECT registrableDomain FROM ObservedDomains WHERE domainID = ?"
            case .getAllSubStatistics:
                "SELECT topFrameDomainID FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ?"
                    + "UNION ALL SELECT topFrameDomainID FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ?"
                    + "UNION ALL SELECT toDomainID FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ?"
            case .storageAccessExists:
                "SELECT EXISTS (SELECT 1 FROM StorageAccessUnderTopFrameDomains WHERE domainID = ? AND topLevelDomainID ="
                    + " (SELECT domainID FROM ObservedDomains WHERE registrableDomain = ?))"
            case .getMostRecentlyUpdatedTimestamp:
                "SELECT MAX(lastUpdated) FROM (SELECT lastUpdated FROM SubframeUnderTopFrameDomains"
                    + " WHERE subFrameDomainID = ? and topFrameDomainID = ?"
                    + "UNION ALL SELECT lastUpdated FROM TopFrameLinkDecorationsFrom WHERE toDomainID = ? and fromDomainID = ?"
                    + "UNION ALL SELECT lastUpdated FROM SubresourceUnderTopFrameDomains"
                    + " WHERE subresourceDomainID = ? and topFrameDomainID = ?"
                    + "UNION ALL SELECT lastUpdated FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? and toDomainID = ?)"
            case .linkDecorationExists:
                "SELECT EXISTS (SELECT * FROM TopFrameLinkDecorationsFrom WHERE toDomainID = ? OR fromDomainID = ?)"
            case .scriptLoadExists:
                "SELECT EXISTS (SELECT * FROM TopFrameLoadedThirdPartyScripts WHERE topFrameDomainID = ? OR subresourceDomainID = ?)"
            case .subFrameExists:
                "SELECT EXISTS (SELECT * FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ? OR topFrameDomainID = ?)"
            case .subResourceExists:
                "SELECT EXISTS (SELECT * FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ? OR topFrameDomainID = ?)"
            case .uniqueRedirectExists:
                "SELECT EXISTS (SELECT * FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? OR toDomainID = ?)"
            case .observedDomainsExists:
                "SELECT EXISTS (SELECT * FROM ObservedDomains WHERE domainID = ?)"
            case .removeAllData:
                "DELETE FROM ObservedDomains WHERE domainID = ?"
            case .checkIfTableExists:
                "SELECT 1 from sqlite_master WHERE type='table' and tbl_name=?"
            }
        }
    }

    // The relationship inserts' query prefixes, which prepareRelationshipStatement completes with one placeholder per domain.
    fileprivate enum RelationshipQuery {
        case storageAccessUnderTopFrameDomains
        case topFrameUniqueRedirectsTo
        case topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement
        case topFrameUniqueRedirectsFrom
        case topFrameLoadedThirdPartyScripts
        case subresourceUniqueRedirectsFrom
        case subframeUnderTopFrameDomains
        case topFrameLinkDecorationsFrom
        case subresourceUnderTopFrameDomains
        case subresourceUniqueRedirectsTo

        var prefix: Swift.String {
            switch self {
            case .storageAccessUnderTopFrameDomains:
                "INSERT OR IGNORE INTO StorageAccessUnderTopFrameDomains (domainID, topLevelDomainID) SELECT ?,"
                    + " domainID FROM ObservedDomains WHERE registrableDomain in ( "
            case .topFrameUniqueRedirectsTo:
                "INSERT OR IGNORE into TopFrameUniqueRedirectsTo (sourceDomainID, toDomainID) SELECT ?, domainID"
                    + " FROM ObservedDomains where registrableDomain in ( "
            case .topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement:
                "INSERT OR IGNORE into TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement (sourceDomainID,"
                    + " toDomainID) SELECT ?, domainID FROM ObservedDomains where registrableDomain in ( "
            case .topFrameUniqueRedirectsFrom:
                "INSERT OR IGNORE INTO TopFrameUniqueRedirectsFrom (targetDomainID, fromDomainID) SELECT ?,"
                    + " domainID FROM ObservedDomains WHERE registrableDomain in ( "
            case .topFrameLoadedThirdPartyScripts:
                "INSERT OR IGNORE into TopFrameLoadedThirdPartyScripts (topFrameDomainID, subresourceDomainID)"
                    + " SELECT ?, domainID FROM ObservedDomains where registrableDomain in ( "
            case .subresourceUniqueRedirectsFrom:
                "INSERT OR IGNORE INTO SubresourceUniqueRedirectsFrom (subresourceDomainID, fromDomainID) SELECT"
                    + " ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "
            case .subframeUnderTopFrameDomains:
                "INSERT OR REPLACE into SubframeUnderTopFrameDomains (subFrameDomainID, lastUpdated,"
                    + " topFrameDomainID) SELECT ?, ?, domainID FROM ObservedDomains where registrableDomain in ( "
            case .topFrameLinkDecorationsFrom:
                "INSERT OR REPLACE INTO TopFrameLinkDecorationsFrom (toDomainID, lastUpdated, fromDomainID)"
                    + " SELECT ?, ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "
            case .subresourceUnderTopFrameDomains:
                "INSERT OR REPLACE INTO SubresourceUnderTopFrameDomains (subresourceDomainID, lastUpdated,"
                    + " topFrameDomainID) SELECT ?, ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "
            case .subresourceUniqueRedirectsTo:
                "INSERT OR REPLACE INTO SubresourceUniqueRedirectsTo (subresourceDomainID, lastUpdated,"
                    + " toDomainID) SELECT ?, ?, domainID FROM ObservedDomains WHERE registrableDomain in ( "
            }
        }

        // The INSERT OR REPLACE queries, which bind lastUpdated as their second parameter.
        var bindsLastUpdated: Bool {
            switch self {
            case .subframeUnderTopFrameDomains, .topFrameLinkDecorationsFrom, .subresourceUnderTopFrameDomains,
                .subresourceUniqueRedirectsTo:
                true
            default:
                false
            }
        }
    }
}

private func toDataRemovalFrequency(_ value: Int32) -> WebKit.DataRemovalFrequency {
    switch value {
    case 0:
        return .Never
    case 1:
        return .Short
    case 2:
        return .Long
    default:
        assertionFailure()
        return .Short
    }
}

extension WebKit.ResourceLoadStatisticsStore {
    private func releaseLogDatabaseError(_ message: Swift.String) {
        WebKit.LogChannel.ResourceLoadStatistics().releaseLog
            .error(
                "[sessionID=\(self.m_sessionID.toUInt64()), error=\(self.database.lastError()), message=\(self.database.lastErrorMsg().description, privacy: .private)] - ResourceLoadStatisticsStore::\(message, privacy: .public)"
            )
    }

    @cxx
    @implementation
    func shouldSkip(_ domain: WebCore.RegistrableDomain) -> Bool {
        assert(!WTF.RunLoop.isMain())
        return !m_parameters.isRunningTest && m_shouldIncludeLocalhost == .No
            && Self.string(domain).description.utf8.elementsEqual("localhost".utf8)
    }

    @cxx
    @implementation
    func setIsRunningTest(_ value: Bool) {
        assert(!WTF.RunLoop.isMain())
        m_parameters.isRunningTest = value
    }

    @cxx
    @implementation
    func setShouldClassifyResourcesBeforeDataRecordsRemoval(_ value: Bool) {
        assert(!WTF.RunLoop.isMain())
        m_parameters.shouldClassifyResourcesBeforeDataRecordsRemoval = value
    }

    @cxx
    @implementation
    func setMinimumTimeBetweenDataRecordsRemoval(_ seconds: WTF.Seconds) {
        assert(!WTF.RunLoop.isMain())
        assert(seconds.value() >= 0)

        m_parameters.minimumTimeBetweenDataRecordsRemoval = seconds
    }

    @cxx
    @implementation
    func setGrandfatheringTime(_ seconds: WTF.Seconds) {
        assert(!WTF.RunLoop.isMain())
        assert(seconds.value() >= 0)

        m_parameters.grandfatheringTime = seconds
    }

    @cxx
    @implementation
    func setMaxStatisticsEntries(_ maximumEntryCount: Int) {
        assert(!WTF.RunLoop.isMain())

        m_parameters.maxStatisticsEntries = maximumEntryCount
    }

    @cxx
    @implementation
    func setPruneEntriesDownTo(_ pruneTargetCount: Int) {
        assert(!WTF.RunLoop.isMain())

        m_parameters.pruneEntriesDownTo = pruneTargetCount
    }

    @cxx
    @implementation
    func resetParametersToDefaultValues() {
        assert(!WTF.RunLoop.isMain())

        m_parameters = .init()
        clearAppBoundDomainsForSwift()
        m_timeAdvanceForTesting = .init()
        m_operatingDatesSize = 0
        m_shortWindowOperatingDate = .init()
        m_longWindowOperatingDate = .init()
        m_lastTimeDataRecordsWereRemoved = .init()
    }

    @cxx
    @implementation
    func setTimeToLiveUserInteraction(_ seconds: WTF.Seconds) {
        assert(!WTF.RunLoop.isMain())
        assert(seconds.value() >= 0)

        m_parameters.timeToLiveUserInteraction = .init(seconds)
    }

    private func openITPDatabase() {
        m_isNewResourceLoadStatisticsDatabaseFile = openDatabaseAndCreateSchemaIfNecessaryForSwift()
    }

    // Check a table for a reference to TopLevelDomains, a sign of the old schema.
    @cxx
    @implementation
    func missingReferenceToObservedDomains() -> Bool {
        currentTableQueryForSwift(WTF.String("TopFrameUniqueRedirectsTo")).description.utf8
            .firstRange(of: "REFERENCES TopLevelDomains".utf8) != nil
    }

    @cxx
    @implementation
    func openAndUpdateSchemaIfNecessary() {
        assert(CachedStatement.allCases.count == WebKit.resourceLoadStatisticsCachedStatementCount)
        assert(
            CachedStatement.insertObservedDomain.query.utf8.count(where: { $0 == UInt8(ascii: "?") })
                == Int(ObservedDomainsColumn.MostRecentWebPushInteractionTime.rawValue)
        )

        openITPDatabase()
        addMissingTablesIfNecessary()

        let observedDomainsColumns = observedDomainsColumnsForSwift()
        var columns = (0..<observedDomainsColumns.size()).map { observedDomainsColumns[$0].description }

        if Self.columnsMatch(columns, Self.currentSchemaColumns.dropLast())
            && addMostRecentWebPushInteractionTimeColumnForSwift()
        {
            columns.append("mostRecentWebPushInteractionTime")
        }

        guard Self.columnsMatch(columns, Self.currentSchemaColumns) else {
            closeForSwift()
            releaseLogError("openAndUpdateSchemaIfNecessary: failed at scheme check, will create new database")
            deleteStorageFileForSwift()
            openITPDatabase()
            return
        }

        migrateDataToPCMDatabaseIfNecessary()
        migrateDataToNewTablesIfNecessaryForSwift()
    }

    private static let currentSchemaColumns: [Swift.String] = [
        "domainID",
        "registrableDomain",
        "lastSeen",
        "hadUserInteraction",
        "mostRecentUserInteractionTime",
        "grandfathered",
        "isPrevalent",
        "isVeryPrevalent",
        "dataRecordsRemoved",
        "timesAccessedAsFirstPartyDueToUserInteraction",
        "timesAccessedAsFirstPartyDueToStorageAccessAPI",
        "isScheduledForAllButCookieDataRemoval",
        "mostRecentWebPushInteractionTime",
    ]

    // Compares code units, as a String compares with an ASCIILiteral.
    private static func columnsMatch(_ columns: [Swift.String], _ names: some Collection<Swift.String>) -> Bool {
        columns.count == names.count && zip(columns, names).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    @cxx
    @implementation
    func tableExists(_ tableName: WTF.String) -> Bool {
        guard let statement = scopedStatement(.checkIfTableExists, "tableExists") else {
            releaseLogDatabaseError("tableExists: failed to prepare statement")
            return false
        }
        guard statement.bindText(1, tableName) == SQLITE_OK else {
            releaseLogDatabaseError("tableExists: failed to bind parameter")
            return false
        }
        return statement.step() == SQLITE_ROW
    }

    @cxx
    @implementation
    func isEmpty() -> Bool {
        assert(!WTF.RunLoop.isMain())

        guard let statement = scopedStatement(.observedDomainCount, "isEmpty"), statement.step() == SQLITE_ROW else {
            releaseLogDatabaseError("isEmpty: failed to step statement")
            return false
        }
        return statement.columnInt(0) == 0
    }

    private func relationshipExists(
        _ statement: consuming SQLStatement?,
        _ firstDomainID: UInt32?,
        _ secondDomain: WebCore.RegistrableDomain
    ) -> Bool {
        guard let firstDomainID else {
            return false
        }

        assert(!WTF.RunLoop.isMain())

        guard let statement,
            statement.bindInt(1, Int32(truncatingIfNeeded: firstDomainID)) == SQLITE_OK,
            statement.bindText(2, Self.string(secondDomain)) == SQLITE_OK,
            statement.step() == SQLITE_ROW
        else {
            releaseLogDatabaseError("relationshipExists: failed to step statement")
            return false
        }
        return statement.columnInt(0) != 0
    }

    @cxx
    @implementation
    func domainID(_ domain: WebCore.RegistrableDomain) -> WebKit.OptionalDomainID {
        assert(!WTF.RunLoop.isMain())

        guard let statement = scopedStatement(.domainIDFromString, "domainID"), statement.bindText(1, Self.string(domain)) == SQLITE_OK
        else {
            releaseLogDatabaseError("domainID: failed to bind parameter")
            return WebKit.OptionalDomainID()
        }

        guard statement.step() == SQLITE_ROW else {
            releaseLogDatabaseError("domainID: failed to step statement")
            return WebKit.OptionalDomainID()
        }

        return WebKit.OptionalDomainID(UInt32(truncatingIfNeeded: statement.columnInt(0)))
    }

    @cxx
    @implementation
    func runIncrementalVacuumCommand() {
        assert(!WTF.RunLoop.isMain())
        _ = database.runIncrementalVacuumCommand()
    }

    private func predicateValueForDomain(_ predicateStatement: consuming SQLStatement?, _ domain: WebCore.RegistrableDomain) -> Int32 {
        assert(!WTF.RunLoop.isMain())

        guard let predicateStatement,
            predicateStatement.bindText(1, Self.string(domain)) == SQLITE_OK,
            predicateStatement.step() == SQLITE_ROW
        else {
            releaseLogDatabaseError("predicateValueForDomain: failed to step statement")
            return 0
        }
        return predicateStatement.columnInt(0)
    }

    @cxx
    @implementation
    func isPrevalentResource(_ domain: WebCore.RegistrableDomain) -> Bool {
        assert(!WTF.RunLoop.isMain())

        if shouldSkip(domain) {
            return false
        }

        let statement = scopedStatement(.isPrevalentResource, "isPrevalentResource")
        return predicateValueForDomain(statement, domain) != 0
    }

    @cxx
    @implementation
    func isVeryPrevalentResource(_ domain: WebCore.RegistrableDomain) -> Bool {
        assert(!WTF.RunLoop.isMain())

        if shouldSkip(domain) {
            return false
        }

        let statement = scopedStatement(.isVeryPrevalentResource, "isVeryPrevalentResource")
        return predicateValueForDomain(statement, domain) != 0
    }

    private func dataRemovalFrequency(_ domain: WebCore.RegistrableDomain) -> WebKit.DataRemovalFrequency {
        assert(!WTF.RunLoop.isMain())

        if shouldSkip(domain) {
            return .Never
        }

        let statement = scopedStatement(.isScheduledForAllButCookieDataRemoval, "isScheduledForAllButCookieDataRemoval")

        return toDataRemovalFrequency(predicateValueForDomain(statement, domain))
    }

    @cxx
    @implementation
    func isRegisteredAsSubresourceUnder(
        _ subresourceDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain
    ) -> Bool {
        assert(!WTF.RunLoop.isMain())

        let statement = scopedStatement(.subresourceUnderTopFrameDomainExists, "isRegisteredAsSubresourceUnder")
        return relationshipExists(statement, existingDomainID(subresourceDomain), topFrameDomain)
    }

    @cxx
    @implementation
    func isRegisteredAsSubFrameUnder(_ subFrameDomain: WebCore.RegistrableDomain, _ topFrameDomain: WebCore.RegistrableDomain) -> Bool {
        assert(!WTF.RunLoop.isMain())

        let statement = scopedStatement(.subframeUnderTopFrameDomainExists, "isRegisteredAsSubFrameUnder")
        return relationshipExists(statement, existingDomainID(subFrameDomain), topFrameDomain)
    }

    @cxx
    @implementation
    func isRegisteredAsRedirectingTo(
        _ redirectedFromDomain: WebCore.RegistrableDomain,
        _ redirectedToDomain: WebCore.RegistrableDomain
    ) -> Bool {
        assert(!WTF.RunLoop.isMain())

        let statement = scopedStatement(.subresourceUniqueRedirectsToExists, "isRegisteredAsRedirectingTo")
        return relationshipExists(statement, existingDomainID(redirectedFromDomain), redirectedToDomain)
    }

    @cxx
    @implementation
    func isGrandfathered(_ domain: WebCore.RegistrableDomain) -> Bool {
        assert(!WTF.RunLoop.isMain())

        let statement = scopedStatement(.isGrandfathered, "isGrandfathered")
        return predicateValueForDomain(statement, domain) != 0
    }

    @cxx
    @implementation
    func removeDataForDomain(_ domain: WebCore.RegistrableDomain) {
        guard let domainIDToRemove = existingDomainID(domain) else {
            return
        }

        guard let statement = scopedStatement(.removeAllData, "removeDataForDomain"),
            statement.bindInt(1, Int32(truncatingIfNeeded: domainIDToRemove)) == SQLITE_OK,
            statement.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("removeDataForDomain: failed to step statement")
            return
        }
    }

    @cxx
    @implementation
    func allDomains() -> WebKit.RegistrableDomainVector {
        assert(!WTF.RunLoop.isMain())

        var domains = WebKit.RegistrableDomainVector()
        guard let statement = scopedStatement(.getAllDomains, "allDomains") else {
            return domains
        }

        while statement.step() == SQLITE_ROW {
            domains.append(consuming: WebCore.RegistrableDomain.fromRawString(consuming: statement.columnText(0)))
        }
        return domains
    }

    // Swift cannot call this override of DatabaseUtilities' pure virtual function, so its body is domainString(_:).
    @cxx
    @implementation
    func getDomainStringFromDomainID(_ domainID: UInt32) -> WTF.String {
        domainString(domainID)
    }

    private func domainString(_ domainID: UInt32) -> WTF.String {
        guard let statement = scopedStatement(.domainStringFromDomainID, "getDomainStringFromDomainID"),
            statement.bindInt(1, Int32(truncatingIfNeeded: domainID)) == SQLITE_OK
        else {
            releaseLogDatabaseError("getDomainStringFromDomainID: failed to bind parameter")
            return Self.emptyString()
        }

        guard statement.step() == SQLITE_ROW else {
            return Self.emptyString()
        }
        return statement.columnText(0)
    }

    @cxx
    @implementation
    func domainIDExistsInDatabase(_ domainID: Int32) -> Bool {
        let linkDecorationExistsStatement = scopedStatement(.linkDecorationExists, "domainIDExistsInDatabase")
        let scriptLoadExistsStatement = scopedStatement(.scriptLoadExists, "domainIDExistsInDatabase linkDecorationExistsStatement")
        let subFrameExistsStatement = scopedStatement(.subFrameExists, "domainIDExistsInDatabase subFrameExistsStatement")
        let subResourceExistsStatement = scopedStatement(.subResourceExists, "domainIDExistsInDatabase subResourceExistsStatement")
        let uniqueRedirectExistsStatement = scopedStatement(.uniqueRedirectExists, "domainIDExistsInDatabase uniqueRedirectExistsStatement")
        let observedDomainsExistsStatement = scopedStatement(
            .observedDomainsExists,
            "domainIDExistsInDatabase observedDomainsExistsStatement"
        )

        guard let linkDecorationExistsStatement,
            let scriptLoadExistsStatement,
            let subFrameExistsStatement,
            let subResourceExistsStatement,
            let uniqueRedirectExistsStatement,
            let observedDomainsExistsStatement,
            linkDecorationExistsStatement.bindInt(1, domainID) == SQLITE_OK,
            linkDecorationExistsStatement.bindInt(2, domainID) == SQLITE_OK,
            scriptLoadExistsStatement.bindInt(1, domainID) == SQLITE_OK,
            scriptLoadExistsStatement.bindInt(2, domainID) == SQLITE_OK,
            subFrameExistsStatement.bindInt(1, domainID) == SQLITE_OK,
            subFrameExistsStatement.bindInt(2, domainID) == SQLITE_OK,
            subResourceExistsStatement.bindInt(1, domainID) == SQLITE_OK,
            subResourceExistsStatement.bindInt(2, domainID) == SQLITE_OK,
            uniqueRedirectExistsStatement.bindInt(1, domainID) == SQLITE_OK,
            uniqueRedirectExistsStatement.bindInt(2, domainID) == SQLITE_OK,
            observedDomainsExistsStatement.bindInt(1, domainID) == SQLITE_OK
        else {
            releaseLogDatabaseError("domainIDExistsInDatabase: failed to bind parameters")
            return false
        }

        guard linkDecorationExistsStatement.step() == SQLITE_ROW,
            scriptLoadExistsStatement.step() == SQLITE_ROW,
            subFrameExistsStatement.step() == SQLITE_ROW,
            subResourceExistsStatement.step() == SQLITE_ROW,
            uniqueRedirectExistsStatement.step() == SQLITE_ROW,
            observedDomainsExistsStatement.step() == SQLITE_ROW
        else {
            releaseLogDatabaseError("domainIDExistsInDatabase: failed to step statement")
            return false
        }

        return linkDecorationExistsStatement.columnInt(0) != 0
            || scriptLoadExistsStatement.columnInt(0) != 0
            || subFrameExistsStatement.columnInt(0) != 0
            || subResourceExistsStatement.columnInt(0) != 0
            || uniqueRedirectExistsStatement.columnInt(0) != 0
            || observedDomainsExistsStatement.columnInt(0) != 0
    }
}

// The reason ensureResourceStatisticsForRegistrableDomain logs: Swift callers pass a literal, so they build no String.
private enum EnsureResourceStatisticsReason {
    case literal(StaticString)
    case string(WTF.String)

    var text: Swift.String {
        switch self {
        case .literal(let reason):
            return reason.description
        case .string(let reason):
            return reason.description
        }
    }
}

extension WebCore.RegistrableDomain {
    /// The domain's string, for `StatisticsDomain` (WebResourceLoadStatisticsStore.swift).
    var statisticsString: WTF.String {
        WebKit.ResourceLoadStatisticsStore.string(self)
    }
}

extension WebKit.ResourceLoadStatisticsStore {
    private func releaseLogError(_ message: Swift.String) {
        WebKit.LogChannel.ResourceLoadStatistics().releaseLog
            .error(
                "[sessionID=\(self.m_sessionID.toUInt64())] - ResourceLoadStatisticsStore::\(message, privacy: .public)"
            )
    }

    // Now plus the testing time advance, in seconds since the epoch.
    private func nowTime() -> Double {
        WTF.WallTime.now().secondsSinceEpoch().value() + m_timeAdvanceForTesting.value()
    }

    @cxx
    @implementation
    func insertObservedDomainRecord(
        _ domain: WebCore.RegistrableDomain,
        _ lastSeen: Double,
        _ hadUserInteraction: Bool,
        _ mostRecentUserInteractionTime: Double,
        _ grandfathered: Bool,
        _ isPrevalent: Bool,
        _ isVeryPrevalent: Bool,
        _ dataRecordsRemoved: UInt32,
        _ timesAccessedAsFirstPartyDueToUserInteraction: UInt32,
        _ timesAccessedAsFirstPartyDueToStorageAccessAPI: UInt32,
        _ gotLinkDecorationFromPrevalentResource: Bool
    ) -> Bool {
        assert(!WTF.RunLoop.isMain())

        if existingDomainID(domain) != nil {
            releaseLogError("insertObservedDomain: domain already exists")
            return false
        }
        // The web push time is bound only when gotLinkDecorationFromPrevalentResource is false.
        guard let statement = scopedStatement(.insertObservedDomain, "insertObservedDomain"),
            statement.bindText(ObservedDomainsColumn.RegistrableDomain.rawValue, Self.string(domain)) == SQLITE_OK,
            statement.bindDouble(ObservedDomainsColumn.LastSeen.rawValue, lastSeen) == SQLITE_OK,
            statement.bindInt(ObservedDomainsColumn.HadUserInteraction.rawValue, hadUserInteraction ? 1 : 0) == SQLITE_OK,
            statement.bindDouble(ObservedDomainsColumn.MostRecentUserInteractionTime.rawValue, mostRecentUserInteractionTime) == SQLITE_OK,
            statement.bindInt(ObservedDomainsColumn.Grandfathered.rawValue, grandfathered ? 1 : 0) == SQLITE_OK,
            statement.bindInt(ObservedDomainsColumn.IsPrevalent.rawValue, isPrevalent ? 1 : 0) == SQLITE_OK,
            statement.bindInt(ObservedDomainsColumn.IsVeryPrevalent.rawValue, isVeryPrevalent ? 1 : 0) == SQLITE_OK,
            statement.bindInt(
                ObservedDomainsColumn.DataRecordsRemoved.rawValue,
                Int32(truncatingIfNeeded: dataRecordsRemoved)
            ) == SQLITE_OK,
            statement.bindInt(
                ObservedDomainsColumn.TimesAccessedAsFirstPartyDueToUserInteraction.rawValue,
                Int32(truncatingIfNeeded: timesAccessedAsFirstPartyDueToUserInteraction)
            ) == SQLITE_OK,
            statement.bindInt(
                ObservedDomainsColumn.TimesAccessedAsFirstPartyDueToStorageAccessAPI.rawValue,
                Int32(truncatingIfNeeded: timesAccessedAsFirstPartyDueToStorageAccessAPI)
            ) == SQLITE_OK,
            statement.bindInt(
                ObservedDomainsColumn.IsScheduledForAllButCookieDataRemoval.rawValue,
                gotLinkDecorationFromPrevalentResource
                    || statement.bindDouble(ObservedDomainsColumn.MostRecentWebPushInteractionTime.rawValue, 0.0) != 0 ? 1 : 0
            ) == SQLITE_OK
        else {
            releaseLogDatabaseError("insertObservedDomain: failed to bind parameters")
            return false
        }

        guard statement.step() == SQLITE_DONE else {
            releaseLogDatabaseError("insertObservedDomain: failed to step statement")
            return false
        }
        return true
    }

    private func ensureAndMakeDomainList(_ domainList: WebKit.RegistrableDomainVector) -> WebKit.RegistrableDomainVector {
        var ensuredDomains = WebKit.RegistrableDomainVector()
        for index in 0..<domainList.size() {
            let topFrameResource = domainList[index]
            // Insert query will fail if top frame domain is not already in the database
            if ensureDomainID(topFrameResource, .literal("ensureAndMakeDomainList")) != nil {
                ensuredDomains.append(consuming: topFrameResource)
            }
        }
        return ensuredDomains
    }

    // The relationships of one merged statistic: mergeStatistics passes its ten HashSets as copyToVector Vectors.
    @cxx
    @implementation
    func insertDomainRelationshipsRecord(
        _ domain: WebCore.RegistrableDomain,
        _ storageAccessUnderTopFrameDomains: WebKit.RegistrableDomainVector,
        _ topFrameUniqueRedirectsTo: WebKit.RegistrableDomainVector,
        _ topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement: WebKit.RegistrableDomainVector,
        _ topFrameUniqueRedirectsFrom: WebKit.RegistrableDomainVector,
        _ subframeUnderTopFrameDomains: WebKit.RegistrableDomainVector,
        _ subresourceUnderTopFrameDomains: WebKit.RegistrableDomainVector,
        _ subresourceUniqueRedirectsTo: WebKit.RegistrableDomainVector,
        _ subresourceUniqueRedirectsFrom: WebKit.RegistrableDomainVector,
        _ topFrameLinkDecorationsFrom: WebKit.RegistrableDomainVector,
        _ topFrameLoadedThirdPartyScripts: WebKit.RegistrableDomainVector
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            guard let registrableDomainID = existingDomainID(domain) else {
                return
            }

            insertDomainRelationshipList(.storageAccessUnderTopFrameDomains, storageAccessUnderTopFrameDomains, registrableDomainID)
            insertDomainRelationshipList(.topFrameUniqueRedirectsTo, topFrameUniqueRedirectsTo, registrableDomainID)
            insertDomainRelationshipList(
                .topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
                topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
                registrableDomainID
            )
            insertDomainRelationshipList(.topFrameUniqueRedirectsFrom, topFrameUniqueRedirectsFrom, registrableDomainID)
            insertDomainRelationshipList(.subframeUnderTopFrameDomains, subframeUnderTopFrameDomains, registrableDomainID)
            insertDomainRelationshipList(.subresourceUnderTopFrameDomains, subresourceUnderTopFrameDomains, registrableDomainID)
            insertDomainRelationshipList(.subresourceUniqueRedirectsTo, subresourceUniqueRedirectsTo, registrableDomainID)
            insertDomainRelationshipList(.subresourceUniqueRedirectsFrom, subresourceUniqueRedirectsFrom, registrableDomainID)
            insertDomainRelationshipList(.topFrameLinkDecorationsFrom, topFrameLinkDecorationsFrom, registrableDomainID)
            insertDomainRelationshipList(.topFrameLoadedThirdPartyScripts, topFrameLoadedThirdPartyScripts, registrableDomainID)
        }
    }

    private func insertDomainRelationshipList(
        _ query: RelationshipQuery,
        _ domainList: WebKit.RegistrableDomainVector,
        _ domainID: UInt32
    ) {
        let ensuredDomains = ensureAndMakeDomainList(domainList)
        if ensuredDomains.isEmpty() {
            return
        }

        guard
            let insertRelationshipStatement = database.prepareRelationshipStatement(
                query,
                UInt32(truncatingIfNeeded: ensuredDomains.size())
            ),
            insertRelationshipStatement.bindInt(1, Int32(truncatingIfNeeded: domainID)) == SQLITE_OK
        else {
            releaseLogDatabaseError("insertDomainRelationshipList: failed to bind first parameter")
            return
        }

        var domainBindStart: Int32 = 2
        if query.bindsLastUpdated {
            guard insertRelationshipStatement.bindDouble(2, nowTime()) == SQLITE_OK else {
                releaseLogDatabaseError("insertDomainRelationshipList: failed to bind second parameter")
                return
            }
            domainBindStart = 3
        }

        for index in 0..<ensuredDomains.size() {
            let bindIndex = domainBindStart &+ Int32(truncatingIfNeeded: index)
            guard insertRelationshipStatement.bindText(bindIndex, Self.string(ensuredDomains[index])) == SQLITE_OK else {
                releaseLogDatabaseError("insertDomainRelationshipList: failed to bind domain")
                return
            }
        }

        if insertRelationshipStatement.step() != SQLITE_DONE {
            releaseLogDatabaseError("insertDomainRelationshipList: failed to step statement")
        }
    }

    private func insertDomainRelationshipList(
        _ query: RelationshipQuery,
        _ domain: WebCore.RegistrableDomain,
        _ domainID: UInt32
    ) {
        var domainList = WebKit.RegistrableDomainVector()
        domainList.append(consuming: domain)
        insertDomainRelationshipList(query, domainList, domainID)
    }

    @cxx
    @implementation
    func setUserInteraction(_ domain: WebCore.RegistrableDomain, _ hadUserInteraction: Bool, _ mostRecentInteraction: WTF.WallTime) {
        setUserInteractionRecord(domain, hadUserInteraction, mostRecentInteraction.secondsSinceEpoch().value())
    }

    private func setUserInteractionRecord(
        _ domain: WebCore.RegistrableDomain,
        _ hadUserInteraction: Bool,
        _ mostRecentInteraction: Double
    ) {
        assert(!WTF.RunLoop.isMain())

        guard let statement = scopedStatement(.mostRecentUserInteraction, "setUserInteraction"),
            statement.bindInt(1, hadUserInteraction ? 1 : 0) == SQLITE_OK,
            statement.bindDouble(2, mostRecentInteraction) == SQLITE_OK,
            statement.bindText(3, Self.string(domain)) == SQLITE_OK,
            statement.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("setUserInteraction: failed to step statement")
            return
        }
    }

    @cxx
    @implementation
    func clearPrevalentResource(_ domain: WebCore.RegistrableDomain) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            if ensureDomainID(domain, .literal("clearPrevalentResource")) == nil {
                return
            }

            do {
                guard let statement = scopedStatement(.clearPrevalentResource, "clearPrevalentResource"),
                    statement.bindText(1, Self.string(domain)) == SQLITE_OK,
                    statement.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError("clearPrevalentResource: failed to step statement")
                    return
                }
            }
        }
    }

    @cxx
    @implementation
    func setGrandfathered(_ domain: WebCore.RegistrableDomain, _ value: Bool) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            if ensureDomainID(domain, .literal("setGrandfathered")) == nil {
                return
            }

            do {
                guard let statement = scopedStatement(.updateGrandfathered, "setGrandfathered"),
                    statement.bindInt(1, value ? 1 : 0) == SQLITE_OK,
                    statement.bindText(2, Self.string(domain)) == SQLITE_OK,
                    statement.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError("setGrandfathered: failed to step statement")
                    return
                }
            }
        }
    }

    private func setIsScheduledForAllScriptWrittenStorageRemoval(
        _ domain: WebCore.RegistrableDomain,
        _ dataRemovalFrequency: WebKit.DataRemovalFrequency
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            if ensureDomainID(domain, .literal("setIsScheduledForAllScriptWrittenStorageRemoval")) == nil {
                return
            }

            do {
                guard
                    let statement = scopedStatement(
                        .updateIsScheduledForAllButCookieDataRemoval,
                        "setIsScheduledForAllScriptWrittenStorageRemoval"
                    ),
                    statement.bindInt(1, Int32(dataRemovalFrequency.rawValue)) == SQLITE_OK,
                    statement.bindText(2, Self.string(domain)) == SQLITE_OK,
                    statement.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError("setIsScheduledForAllScriptWrittenStorageRemoval: failed to step statement")
                    return
                }
            }
        }
    }

    @cxx
    @implementation
    func setMostRecentWebPushInteractionTime(_ domain: WebCore.RegistrableDomain) {
        assert(!WTF.RunLoop.isMain())

        let time = nowTime()

        withTransaction {
            if ensureDomainID(domain, .literal("setMostRecentWebPushInteractionTime")) == nil {
                return
            }

            do {
                guard let statement = scopedStatement(.updateMostRecentWebPushInteractionTime, "setMostRecentWebPushInteractionTime"),
                    statement.bindDouble(1, time) == SQLITE_OK,
                    statement.bindText(2, Self.string(domain)) == SQLITE_OK,
                    statement.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError("setMostRecentWebPushInteractionTime: failed to step statement")
                    return
                }
            }
        }
    }

    // The relationship setters below: ensure the first domain, then insert the relationship, in one transaction.
    private func setRelationship(
        _ domain: WebCore.RegistrableDomain,
        _ reason: StaticString,
        _ query: RelationshipQuery,
        _ otherDomain: WebCore.RegistrableDomain
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            guard let domainID = ensureDomainID(domain, .literal(reason)) else {
                return
            }

            // For consistency, make sure we also have a statistics entry for the other domain.
            insertDomainRelationshipList(query, otherDomain, domainID)
        }
    }

    @cxx
    @implementation
    func setSubframeUnderTopFrameDomain(_ subFrameDomain: WebCore.RegistrableDomain, _ topFrameDomain: WebCore.RegistrableDomain) {
        setRelationship(subFrameDomain, "setSubframeUnderTopFrameDomain", .subframeUnderTopFrameDomains, topFrameDomain)
    }

    @cxx
    @implementation
    func setSubresourceUnderTopFrameDomain(_ subresourceDomain: WebCore.RegistrableDomain, _ topFrameDomain: WebCore.RegistrableDomain) {
        setRelationship(subresourceDomain, "setSubresourceUnderTopFrameDomain", .subresourceUnderTopFrameDomains, topFrameDomain)
    }

    @cxx
    @implementation
    func setSubresourceUniqueRedirectTo(_ subresourceDomain: WebCore.RegistrableDomain, _ redirectDomain: WebCore.RegistrableDomain) {
        setRelationship(subresourceDomain, "setSubresourceUniqueRedirectTo", .subresourceUniqueRedirectsTo, redirectDomain)
    }

    @cxx
    @implementation
    func setSubresourceUniqueRedirectFrom(_ subresourceDomain: WebCore.RegistrableDomain, _ redirectDomain: WebCore.RegistrableDomain) {
        setRelationship(subresourceDomain, "setSubresourceUniqueRedirectFrom", .subresourceUniqueRedirectsFrom, redirectDomain)
    }

    @cxx
    @implementation
    func setTopFrameUniqueRedirectTo(_ topFrameDomain: WebCore.RegistrableDomain, _ redirectDomain: WebCore.RegistrableDomain) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            guard let domainID = ensureDomainID(topFrameDomain, .literal("setTopFrameUniqueRedirectTo"))
            else {
                return
            }

            insertDomainRelationshipList(.topFrameUniqueRedirectsTo, redirectDomain, domainID)
            insertDomainRelationshipList(.topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement, redirectDomain, domainID)
        }
    }

    @cxx
    @implementation
    func setTopFrameUniqueRedirectFrom(_ topFrameDomain: WebCore.RegistrableDomain, _ redirectDomain: WebCore.RegistrableDomain) {
        setRelationship(topFrameDomain, "setTopFrameUniqueRedirectFrom", .topFrameUniqueRedirectsFrom, redirectDomain)
    }

    @cxx
    @implementation
    func ensureResourceStatisticsForRegistrableDomain(
        _ domain: WebCore.RegistrableDomain,
        _ reason: WTF.String
    ) -> WebKit.ResourceLoadStatisticsStore.AddedRecordAndDomainID {
        ensureResourceStatistics(domain, .string(reason))
    }

    private func ensureResourceStatistics(
        _ domain: WebCore.RegistrableDomain,
        _ reason: EnsureResourceStatisticsReason
    ) -> WebKit.ResourceLoadStatisticsStore.AddedRecordAndDomainID {
        assert(!WTF.RunLoop.isMain())

        do {
            guard let statement = scopedStatement(.domainIDFromString, "ensureResourceStatisticsForRegistrableDomain"),
                statement.bindText(1, Self.string(domain)) == SQLITE_OK
            else {
                releaseLogDatabaseError("ensureResourceStatisticsForRegistrableDomain: reason \(reason.text), failed to bind parameter")
                return AddedRecordAndDomainID(first: .No, second: WebKit.OptionalDomainID())
            }

            if statement.step() == SQLITE_ROW {
                let domainID = UInt32(truncatingIfNeeded: statement.columnInt(0))
                return AddedRecordAndDomainID(first: .No, second: WebKit.OptionalDomainID(domainID))
            }
        }

        // -1 and 0 are the defaults of a new statistic.
        let result = insertObservedDomainRecord(domain, 0, false, -1, false, false, false, 0, 0, 0, false)

        if !result {
            releaseLogError("ensureResourceStatisticsForRegistrableDomain: reason \(reason.text), failed to insert observed domain")
            return AddedRecordAndDomainID(first: .No, second: WebKit.OptionalDomainID())
        }

        guard let domainID = existingDomainID(domain) else {
            releaseLogError(
                "ensureResourceStatisticsForRegistrableDomain: reason \(reason.text), failed to retrieve domain ID after successful insertion"
            )
            return AddedRecordAndDomainID(first: .No, second: WebKit.OptionalDomainID())
        }
        return AddedRecordAndDomainID(first: .Yes, second: WebKit.OptionalDomainID(domainID))
    }

    // Runs body inside the transaction beginTransactionIfNecessaryForSwift() begins, if it begins one.
    private func withTransaction<T>(_ body: () -> T) -> T {
        let didBeginTransaction = beginTransactionIfNecessaryForSwift()
        defer { commitTransactionForSwift(didBeginTransaction) }
        return body()
    }

    private func ensureDomainID(_ domain: WebCore.RegistrableDomain, _ reason: EnsureResourceStatisticsReason) -> UInt32? {
        Optional(fromCxx: ensureResourceStatistics(domain, reason).second)
    }

    private func existingDomainID(_ domain: WebCore.RegistrableDomain) -> UInt32? {
        Optional(fromCxx: domainID(domain))
    }

    private func updateLastSeenRecord(_ domain: WebCore.RegistrableDomain, _ lastSeen: Double) {
        assert(!WTF.RunLoop.isMain())

        guard let statement = scopedStatement(.updateLastSeen, "updateLastSeen"),
            statement.bindDouble(1, lastSeen) == SQLITE_OK,
            statement.bindText(2, Self.string(domain)) == SQLITE_OK,
            statement.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("updateLastSeen: failed to step statement")
            return
        }
    }

    @cxx
    @implementation
    func setLastSeen(_ domain: WebCore.RegistrableDomain, _ seconds: WTF.Seconds) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            if ensureDomainID(domain, .literal("setLastSeen")) == nil {
                return
            }

            updateLastSeenRecord(domain, seconds.value())
        }
    }

    private func updateDataRecordsRemoved(_ domain: WebCore.RegistrableDomain, _ value: Int32) {
        assert(!WTF.RunLoop.isMain())

        guard let statement = scopedStatement(.updateDataRecordsRemoved, "updateDataRecordsRemoved"),
            statement.bindInt(1, value) == SQLITE_OK,
            statement.bindText(2, Self.string(domain)) == SQLITE_OK,
            statement.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("updateDataRecordsRemoved: failed to step statement")
            return
        }
    }
}

// MARK: Statistics merge

extension WebKit.ResourceLoadStatisticsStore {
    /// Merges the statistics a web process sends, in one transaction: each domain's record first, then, once every
    /// domain has a record, its relationships.
    ///
    /// A domain whose record cannot be inserted ends the merge, keeping what was merged before it.
    func mergeStatistics(_ statistics: [IPCTypes.ResourceLoadStatistics]) {
        merge(
            statistics.map { statistic in
                MergedStatistic(
                    domain: .fromIPC(statistic.registrableDomain),
                    lastSeen: statistic.lastSeen,
                    hadUserInteraction: statistic.hadUserInteraction,
                    mostRecentUserInteractionTime: statistic.mostRecentUserInteractionTime,
                    grandfathered: statistic.grandfathered,
                    isPrevalentResource: statistic.isPrevalentResource,
                    isVeryPrevalentResource: statistic.isVeryPrevalentResource,
                    dataRecordsRemoved: statistic.dataRecordsRemoved,
                    timesAccessedAsFirstPartyDueToUserInteraction: statistic.timesAccessedAsFirstPartyDueToUserInteraction,
                    timesAccessedAsFirstPartyDueToStorageAccessAPI: statistic.timesAccessedAsFirstPartyDueToStorageAccessAPI,
                    gotLinkDecorationFromPrevalentResource: statistic.gotLinkDecorationFromPrevalentResource,
                    storageAccessUnderTopFrameDomains: Self.registrableDomainVector(statistic.storageAccessUnderTopFrameDomains),
                    topFrameUniqueRedirectsTo: Self.registrableDomainVector(statistic.topFrameUniqueRedirectsTo),
                    topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement: Self.registrableDomainVector(
                        statistic.topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement
                    ),
                    topFrameUniqueRedirectsFrom: Self.registrableDomainVector(statistic.topFrameUniqueRedirectsFrom),
                    subframeUnderTopFrameDomains: Self.registrableDomainVector(statistic.subframeUnderTopFrameDomains),
                    subresourceUnderTopFrameDomains: Self.registrableDomainVector(statistic.subresourceUnderTopFrameDomains),
                    subresourceUniqueRedirectsTo: Self.registrableDomainVector(statistic.subresourceUniqueRedirectsTo),
                    subresourceUniqueRedirectsFrom: Self.registrableDomainVector(statistic.subresourceUniqueRedirectsFrom),
                    topFrameLinkDecorationsFrom: Self.registrableDomainVector(statistic.topFrameLinkDecorationsFrom),
                    topFrameLoadedThirdPartyScripts: Self.registrableDomainVector(statistic.topFrameLoadedThirdPartyScripts)
                )
            }
        )
    }

    /// Merges one statistic with at most two top frames it was a subframe under, as a test asks.
    func mergeStatisticForTesting(
        _ domain: WebCore.RegistrableDomain,
        _ topFrameDomain1: WebCore.RegistrableDomain,
        _ topFrameDomain2: WebCore.RegistrableDomain,
        _ lastSeen: WTF.Seconds,
        _ hadUserInteraction: Bool,
        _ mostRecentUserInteraction: WTF.Seconds,
        _ isGrandfathered: Bool,
        _ isPrevalent: Bool,
        _ isVeryPrevalent: Bool,
        _ dataRecordsRemoved: UInt32
    ) {
        var topFrameDomains = WebKit.RegistrableDomainVector()
        if !topFrameDomain1.isEmpty() {
            topFrameDomains.append(consuming: topFrameDomain1)
        }
        if !topFrameDomain2.isEmpty() {
            topFrameDomains.append(consuming: topFrameDomain2)
        }
        // A set with no reserve has the reserve's minimum table for two elements or fewer, so the order is the same.
        merge([
            MergedStatistic(
                domain: domain,
                lastSeen: lastSeen.value(),
                hadUserInteraction: hadUserInteraction,
                mostRecentUserInteractionTime: mostRecentUserInteraction.value(),
                grandfathered: isGrandfathered,
                isPrevalentResource: isPrevalent,
                isVeryPrevalentResource: isVeryPrevalent,
                dataRecordsRemoved: dataRecordsRemoved,
                subframeUnderTopFrameDomains: Self.inDecodedHashSetOrderForSwift(consuming: topFrameDomains)
            )
        ])
    }

    /// A statistic as the merge reads it, its relationship sets as Vectors in the C++ sets' order.
    private struct MergedStatistic {
        var domain: WebCore.RegistrableDomain
        var lastSeen: Double
        var hadUserInteraction: Bool
        var mostRecentUserInteractionTime: Double
        var grandfathered: Bool
        var isPrevalentResource: Bool
        var isVeryPrevalentResource: Bool
        var dataRecordsRemoved: UInt32
        var timesAccessedAsFirstPartyDueToUserInteraction: UInt32 = 0
        var timesAccessedAsFirstPartyDueToStorageAccessAPI: UInt32 = 0
        var gotLinkDecorationFromPrevalentResource = false
        var storageAccessUnderTopFrameDomains = WebKit.RegistrableDomainVector()
        var topFrameUniqueRedirectsTo = WebKit.RegistrableDomainVector()
        var topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement = WebKit.RegistrableDomainVector()
        var topFrameUniqueRedirectsFrom = WebKit.RegistrableDomainVector()
        var subframeUnderTopFrameDomains = WebKit.RegistrableDomainVector()
        var subresourceUnderTopFrameDomains = WebKit.RegistrableDomainVector()
        var subresourceUniqueRedirectsTo = WebKit.RegistrableDomainVector()
        var subresourceUniqueRedirectsFrom = WebKit.RegistrableDomainVector()
        var topFrameLinkDecorationsFrom = WebKit.RegistrableDomainVector()
        var topFrameLoadedThirdPartyScripts = WebKit.RegistrableDomainVector()
    }

    /// Merges statistics in one transaction.
    ///
    /// Each domain's record goes first, then, once every domain has a record, its relationships. A domain whose record
    /// cannot be inserted ends the merge, keeping what was merged before it.
    private func merge(_ statistics: [MergedStatistic]) {
        assert(!WTF.RunLoop.isMain())
        if statistics.isEmpty {
            return
        }

        withTransaction {
            for statistic in statistics {
                if existingDomainID(statistic.domain) == nil {
                    let inserted = insertObservedDomainRecord(
                        statistic.domain,
                        statistic.lastSeen,
                        statistic.hadUserInteraction,
                        statistic.mostRecentUserInteractionTime,
                        statistic.grandfathered,
                        statistic.isPrevalentResource,
                        statistic.isVeryPrevalentResource,
                        statistic.dataRecordsRemoved,
                        statistic.timesAccessedAsFirstPartyDueToUserInteraction,
                        statistic.timesAccessedAsFirstPartyDueToStorageAccessAPI,
                        statistic.gotLinkDecorationFromPrevalentResource
                    )
                    guard inserted else {
                        releaseLogError("mergeStatistics: failed to insert observed domain")
                        return
                    }
                } else {
                    mergeStatistic(
                        statistic.domain,
                        WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(statistic.lastSeen)),
                        statistic.hadUserInteraction,
                        WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(statistic.mostRecentUserInteractionTime)),
                        statistic.grandfathered,
                        statistic.isPrevalentResource,
                        statistic.isVeryPrevalentResource,
                        statistic.dataRecordsRemoved,
                        statistic.gotLinkDecorationFromPrevalentResource
                    )
                }
            }

            for statistic in statistics {
                insertDomainRelationshipsRecord(
                    statistic.domain,
                    statistic.storageAccessUnderTopFrameDomains,
                    statistic.topFrameUniqueRedirectsTo,
                    statistic.topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
                    statistic.topFrameUniqueRedirectsFrom,
                    statistic.subframeUnderTopFrameDomains,
                    statistic.subresourceUnderTopFrameDomains,
                    statistic.subresourceUniqueRedirectsTo,
                    statistic.subresourceUniqueRedirectsFrom,
                    statistic.topFrameLinkDecorationsFrom,
                    statistic.topFrameLoadedThirdPartyScripts
                )
            }
        }
    }

    /// The C++ vector of a relationship set, in the order the C++ decoder's HashSet would have given it.
    private static func registrableDomainVector(
        _ domains: IPCTypes.HashSetInWireOrder<IPCTypes.RegistrableDomain>
    ) -> WebKit.RegistrableDomainVector {
        var vector = WebKit.RegistrableDomainVector()
        for domain in domains.elementsInWireOrder {
            vector.append(consuming: .fromIPC(domain))
        }
        return inDecodedHashSetOrderForSwift(consuming: vector)
    }

    // The ResourceLoadStatistics fields that merging reads: Swift cannot take the struct itself, since its HashSet
    // members import as unsafe.
    @cxx
    @implementation
    func mergeStatistic(
        _ registrableDomain: WebCore.RegistrableDomain,
        _ lastSeen: WTF.WallTime,
        _ hadUserInteraction: Bool,
        _ mostRecentUserInteractionTime: WTF.WallTime,
        _ grandfathered: Bool,
        _ isPrevalentResource: Bool,
        _ isVeryPrevalentResource: Bool,
        _ dataRecordsRemoved: UInt32,
        _ gotLinkDecorationFromPrevalentResource: Bool
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            guard let current = scopedStatement(.getResourceDataByDomainName, "mergeStatistic"),
                current.bindText(1, Self.string(registrableDomain)) == SQLITE_OK,
                current.step() == SQLITE_ROW
            else {
                releaseLogDatabaseError("mergeStatistic: failed to step statement")
                return
            }

            assert(!WTF.RunLoop.isMain())
            WebKit.LogChannel.ResourceLoadStatistics().releaseLog
                .log("ResourceLoadStatisticsStore::merge: sessionID=\(self.m_sessionID.toUInt64())")

            withTransaction {
                let currentLastSeen = current.columnDouble(ObservedDomainsColumn.LastSeen.rawValue)
                let currentMostRecentUserInteraction = current.columnDouble(ObservedDomainsColumn.MostRecentUserInteractionTime.rawValue)
                let currentGrandfathered = current.columnInt(ObservedDomainsColumn.Grandfathered.rawValue) != 0
                let currentIsPrevalent = current.columnInt(ObservedDomainsColumn.IsPrevalent.rawValue) != 0
                let currentIsVeryPrevalent = current.columnInt(ObservedDomainsColumn.IsVeryPrevalent.rawValue) != 0
                let currentDataRecordsRemoved =
                    UInt32(truncatingIfNeeded: current.columnInt(ObservedDomainsColumn.DataRecordsRemoved.rawValue))
                let currentIsScheduledForAllButCookieDataRemoval =
                    current.columnInt(ObservedDomainsColumn.IsScheduledForAllButCookieDataRemoval.rawValue) != 0

                assert(current.columnText(ObservedDomainsColumn.RegistrableDomain.rawValue) == Self.string(registrableDomain))

                if currentLastSeen < lastSeen.secondsSinceEpoch().value() {
                    updateLastSeenRecord(registrableDomain, lastSeen.secondsSinceEpoch().value())
                }

                let otherMostRecentUserInteraction = mostRecentUserInteractionTime.secondsSinceEpoch().value()
                if !hadUserInteraction {
                    // If most recent user interaction time has been reset do so here too.
                    if otherMostRecentUserInteraction == 0 {
                        setUserInteractionRecord(registrableDomain, false, 0)
                    }
                } else {
                    let mostRecentUserInteraction =
                        currentMostRecentUserInteraction < otherMostRecentUserInteraction
                        ? otherMostRecentUserInteraction : currentMostRecentUserInteraction
                    setUserInteractionRecord(registrableDomain, true, mostRecentUserInteraction)
                }

                if grandfathered && !currentGrandfathered {
                    setGrandfathered(registrableDomain, true)
                }
                if isPrevalentResource && !currentIsPrevalent {
                    setPrevalentResource(registrableDomain)
                }
                if isVeryPrevalentResource && !currentIsVeryPrevalent {
                    setVeryPrevalentResource(registrableDomain)
                }
                if dataRecordsRemoved > currentDataRecordsRemoved {
                    updateDataRecordsRemoved(registrableDomain, Int32(truncatingIfNeeded: dataRecordsRemoved))
                }
                if gotLinkDecorationFromPrevalentResource && !currentIsScheduledForAllButCookieDataRemoval {
                    setIsScheduledForAllScriptWrittenStorageRemoval(registrableDomain, .Short)
                }
            }
        }
    }

    @cxx
    @implementation
    func updateObservedDomainsList(_ updateClause: WTF.String, _ domains: WebKit.RegistrableDomainVector, _ logContext: WTF.String) {
        assert(!WTF.RunLoop.isMain())

        if domains.isEmpty() {
            return
        }

        var placeholders = ""
        for index in 0..<domains.size() {
            placeholders += index != 0 ? ", ?" : "?"
        }

        guard
            let statement = database.prepareStatement(
                WTF.String("UPDATE ObservedDomains SET " + updateClause.description + " WHERE registrableDomain IN (" + placeholders + ")")
            )
        else {
            releaseLogDatabaseError("\(logContext.description): failed to prepare statement")
            return
        }

        for index in 0..<domains.size() {
            // Cannot overflow: SQLite allows far fewer bound parameters than Int32.max.
            let bindIndex = 1 &+ Int32(truncatingIfNeeded: index)
            guard statement.bindText(bindIndex, Self.string(domains[index])) == SQLITE_OK else {
                releaseLogDatabaseError("\(logContext.description): failed to bind domain")
                return
            }
        }

        if statement.step() != SQLITE_DONE {
            releaseLogDatabaseError("\(logContext.description): failed to step statement")
        }
    }
}

// MARK: Prevalence classification

// Domain IDs, each once, visited in ascending order.
private struct DomainIDSet {
    private(set) var domainIDs: [UInt32] = []

    var isEmpty: Bool { domainIDs.isEmpty }

    mutating func insert(_ domainID: UInt32) -> Bool {
        var low = 0
        var high = domainIDs.count
        while low < high {
            let middle = (low + high) / 2
            if domainIDs[middle] < domainID {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < domainIDs.count && domainIDs[low] == domainID {
            return false
        }
        domainIDs.insert(domainID, at: low)
        return true
    }
}

private func integerList(_ values: some Sequence<UInt32>) -> Swift.String {
    var list = ""
    for value in values {
        list += list.isEmpty ? Swift.String(value) : ", \(value)"
    }
    return list
}

private struct NotVeryPrevalentResources {
    let registrableDomain: WebCore.RegistrableDomain
    let prevalence: WebKit.ResourceLoadPrevalence
    var subresourceUnderTopFrameDomainsCount: UInt32 = 0
    var subresourceUniqueRedirectsToCount: UInt32 = 0
    var subframeUnderTopFrameDomainsCount: UInt32 = 0
    var topFrameUniqueRedirectsToCount: UInt32 = 0
}

extension WebKit.ResourceLoadStatisticsStore {
    private static let maxNumberOfRecursiveCallsInRedirectTraceBack: UInt32 = 50

    private func recursivelyFindNonPrevalentDomainsThatRedirectedToThisDomain(
        _ primaryDomainID: UInt32,
        _ nonPrevalentRedirectionSources: inout DomainIDSet,
        _ numberOfRecursiveCalls: UInt32
    ) -> UInt32 {
        assert(!WTF.RunLoop.isMain())

        if numberOfRecursiveCalls >= Self.maxNumberOfRecursiveCallsInRedirectTraceBack {
            releaseLogError(
                "recursivelyFindNonPrevalentDomainsThatRedirectedToThisDomain: hit \(Self.maxNumberOfRecursiveCallsInRedirectTraceBack) recursive calls in redirect backtrace"
            )
            return numberOfRecursiveCalls
        }

        var numberOfRecursiveCalls = numberOfRecursiveCalls + 1

        var newlyIdentifiedDomains = DomainIDSet()
        guard
            let findSubresources = database.prepareStatement(
                WTF.String(
                    "SELECT SubresourceUniqueRedirectsFrom.fromDomainID from SubresourceUniqueRedirectsFrom INNER JOIN ObservedDomains ON ObservedDomains.domainID = SubresourceUniqueRedirectsFrom.fromDomainID WHERE subresourceDomainID = ? AND ObservedDomains.isPrevalent = 0"
                )
            ),
            findSubresources.bindInt(1, Int32(truncatingIfNeeded: primaryDomainID)) == SQLITE_OK
        else {
            releaseLogDatabaseError(
                "recursivelyFindNonPrevalentDomainsThatRedirectedToThisDomain: failed to bind parameter for findSubresources"
            )
            return 0
        }

        while findSubresources.step() == SQLITE_ROW {
            let newDomainID = UInt32(truncatingIfNeeded: findSubresources.columnInt(0))
            if nonPrevalentRedirectionSources.insert(newDomainID) {
                _ = newlyIdentifiedDomains.insert(newDomainID)
            }
        }

        guard
            let findTopFrames = database.prepareStatement(
                WTF.String(
                    "SELECT TopFrameUniqueRedirectsFrom.fromDomainID from TopFrameUniqueRedirectsFrom INNER JOIN ObservedDomains ON ObservedDomains.domainID = TopFrameUniqueRedirectsFrom.fromDomainID WHERE targetDomainID = ? AND ObservedDomains.isPrevalent = 0"
                )
            ),
            findTopFrames.bindInt(1, Int32(truncatingIfNeeded: primaryDomainID)) == SQLITE_OK
        else {
            releaseLogDatabaseError(
                "recursivelyFindNonPrevalentDomainsThatRedirectedToThisDomain: failed to bind parameter for findTopFrames"
            )
            return 0
        }

        while findTopFrames.step() == SQLITE_ROW {
            let newDomainID = UInt32(truncatingIfNeeded: findTopFrames.columnInt(0))
            if nonPrevalentRedirectionSources.insert(newDomainID) {
                _ = newlyIdentifiedDomains.insert(newDomainID)
            }
        }

        if newlyIdentifiedDomains.isEmpty {
            return numberOfRecursiveCalls
        }

        for domainID in newlyIdentifiedDomains.domainIDs {
            numberOfRecursiveCalls = recursivelyFindNonPrevalentDomainsThatRedirectedToThisDomain(
                domainID,
                &nonPrevalentRedirectionSources,
                numberOfRecursiveCalls
            )
        }

        return numberOfRecursiveCalls
    }

    private func markAsPrevalentIfHasRedirectedToPrevalent() {
        assert(!WTF.RunLoop.isMain())

        var prevalentDueToRedirect = DomainIDSet()
        if let subresourceRedirectStatement = database.prepareStatement(
            WTF.String(
                "SELECT DISTINCT SubresourceUniqueRedirectsTo.subresourceDomainID FROM SubresourceUniqueRedirectsTo JOIN ObservedDomains ON ObservedDomains.domainID = SubresourceUniqueRedirectsTo.toDomainID AND ObservedDomains.isPrevalent = 1"
            )
        ) {
            while subresourceRedirectStatement.step() == SQLITE_ROW {
                _ = prevalentDueToRedirect.insert(UInt32(truncatingIfNeeded: subresourceRedirectStatement.columnInt(0)))
            }
        }

        if let topFrameRedirectStatement = database.prepareStatement(
            WTF.String(
                "SELECT DISTINCT TopFrameUniqueRedirectsTo.sourceDomainID FROM TopFrameUniqueRedirectsTo JOIN ObservedDomains ON ObservedDomains.domainID = TopFrameUniqueRedirectsTo.toDomainID AND ObservedDomains.isPrevalent = 1"
            )
        ) {
            while topFrameRedirectStatement.step() == SQLITE_ROW {
                _ = prevalentDueToRedirect.insert(UInt32(truncatingIfNeeded: topFrameRedirectStatement.columnInt(0)))
            }
        }

        guard
            let markPrevalentStatement = database.prepareStatement(
                WTF.String(
                    "UPDATE ObservedDomains SET isPrevalent = 1 WHERE domainID IN (" + integerList(prevalentDueToRedirect.domainIDs) + ")"
                )
            ),
            markPrevalentStatement.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("markAsPrevalentIfHasRedirectedToPrevalent: failed to step statement")
            return
        }
    }

    private func addSubStatisticCounts(
        _ query: Swift.String,
        _ resources: inout [NotVeryPrevalentResources],
        _ indexes: [UInt32: Int],
        _ count: WritableKeyPath<NotVeryPrevalentResources, UInt32>
    ) {
        guard let statement = database.prepareStatement(WTF.String(query)) else {
            return
        }
        while statement.step() == SQLITE_ROW {
            let domainID = UInt32(truncatingIfNeeded: statement.columnInt(0))
            assert(domainID != 0)
            if domainID == 0 {
                continue
            }
            if let index = indexes[domainID] {
                resources[index][keyPath: count] = UInt32(truncatingIfNeeded: statement.columnInt(1))
            }
        }
    }

    // The resources in the iteration order of a HashMap<unsigned, NotVeryPrevalentResources>, the order the classifier visits them.
    private func findNotVeryPrevalentResources() -> [NotVeryPrevalentResources] {
        assert(!WTF.RunLoop.isMain())

        var resources: [NotVeryPrevalentResources] = []
        var keys = WebKit.DomainIDVector()
        if let notVeryPrevalentResourcesStatement = database.prepareStatement(
            WTF.String("SELECT domainID, registrableDomain, isPrevalent FROM ObservedDomains WHERE isVeryPrevalent = 0")
        ) {
            while notVeryPrevalentResourcesStatement.step() == SQLITE_ROW {
                let key = UInt32(truncatingIfNeeded: notVeryPrevalentResourcesStatement.columnInt(0))
                assert(key != 0)
                if key == 0 {
                    continue
                }
                keys.append(consuming: key)
                resources.append(
                    NotVeryPrevalentResources(
                        registrableDomain: WebCore.RegistrableDomain.fromRawString(
                            consuming: notVeryPrevalentResourcesStatement.columnText(1)
                        ),
                        prevalence: notVeryPrevalentResourcesStatement.columnInt(2) != 0 ? WebKit.High : WebKit.Low
                    )
                )
            }
        }

        let order = Self.hashMapIterationOrder(keys)
        var orderedResources: [NotVeryPrevalentResources] = []
        var domainIDs: [UInt32] = []
        var indexes: [UInt32: Int] = [:]
        orderedResources.reserveCapacity(order.size())
        for position in 0..<order.size() {
            let index = Int(order[position])
            indexes[keys[index]] = orderedResources.count
            domainIDs.append(keys[index])
            orderedResources.append(resources[index])
        }
        let domainIDsOfInterest = integerList(domainIDs)

        addSubStatisticCounts(
            "SELECT subresourceDomainID, COUNT(topFrameDomainID) FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID IN ("
                + domainIDsOfInterest + ") GROUP BY subresourceDomainID",
            &orderedResources,
            indexes,
            \.subresourceUnderTopFrameDomainsCount
        )
        addSubStatisticCounts(
            "SELECT subresourceDomainID, COUNT(toDomainID) FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID IN ("
                + domainIDsOfInterest + ") GROUP BY subresourceDomainID",
            &orderedResources,
            indexes,
            \.subresourceUniqueRedirectsToCount
        )
        addSubStatisticCounts(
            "SELECT subframeDomainID, COUNT(topFrameDomainID) FROM SubframeUnderTopFrameDomains WHERE subframeDomainID IN ("
                + domainIDsOfInterest + ") GROUP BY subframeDomainID",
            &orderedResources,
            indexes,
            \.subframeUnderTopFrameDomainsCount
        )
        addSubStatisticCounts(
            "SELECT sourceDomainID, COUNT(toDomainID) FROM TopFrameUniqueRedirectsTo WHERE sourceDomainID IN ("
                + domainIDsOfInterest + ") GROUP BY sourceDomainID",
            &orderedResources,
            indexes,
            \.topFrameUniqueRedirectsToCount
        )

        return orderedResources
    }

    private func reclassifyResources() {
        assert(!WTF.RunLoop.isMain())

        let notVeryPrevalentResources = findNotVeryPrevalentResources()
        if notVeryPrevalentResources.isEmpty {
            return
        }

        withTransaction {
            for resourceStatistic in notVeryPrevalentResources {
                if shouldSkip(resourceStatistic.registrableDomain) {
                    continue
                }

                let newPrevalence = m_resourceLoadStatisticsClassifier.calculateResourcePrevalence(
                    resourceStatistic.subresourceUnderTopFrameDomainsCount,
                    resourceStatistic.subresourceUniqueRedirectsToCount,
                    resourceStatistic.subframeUnderTopFrameDomainsCount,
                    resourceStatistic.topFrameUniqueRedirectsToCount,
                    resourceStatistic.prevalence
                )
                if newPrevalence != resourceStatistic.prevalence {
                    setPrevalentResource(resourceStatistic.registrableDomain, newPrevalence)
                }
            }
        }
    }

    @cxx
    @implementation
    func classifyPrevalentResources() {
        assert(!WTF.RunLoop.isMain())
        _ = ensurePrevalentResourcesForDebugMode()
        markAsPrevalentIfHasRedirectedToPrevalent()
        reclassifyResources()
    }

    private func setPrevalentResource(_ domain: WebCore.RegistrableDomain, _ newPrevalence: WebKit.ResourceLoadPrevalence) {
        assert(!WTF.RunLoop.isMain())

        if shouldSkip(domain) {
            return
        }

        withTransaction {
            do {
                guard let registrableDomainID = existingDomainID(domain) else {
                    releaseLogError("setPrevalentResource: failed to find domain")
                    return
                }

                guard let updatePrevalentResourceStatement = scopedStatement(.updatePrevalentResource, "setPrevalentResource"),
                    updatePrevalentResourceStatement.bindInt(1, 1) == SQLITE_OK,
                    updatePrevalentResourceStatement.bindText(2, Self.string(domain)) == SQLITE_OK,
                    updatePrevalentResourceStatement.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError("setPrevalentResource: failed at to step scopedUpdatePrevalentResourceStatement")
                    return
                }

                let updateVeryPrevalentResourceStatement = scopedStatement(
                    .updateVeryPrevalentResource,
                    "setPrevalentResource updateVeryPrevalentResource"
                )
                if newPrevalence == WebKit.VeryHigh {
                    guard let updateVeryPrevalentResourceStatement,
                        updateVeryPrevalentResourceStatement.bindInt(1, 1) == SQLITE_OK,
                        updateVeryPrevalentResourceStatement.bindText(2, Self.string(domain)) == SQLITE_OK,
                        updateVeryPrevalentResourceStatement.step() == SQLITE_DONE
                    else {
                        releaseLogDatabaseError("setPrevalentResource: failed at to step scopedUpdateVeryPrevalentResourceStatement")
                        return
                    }
                }

                var nonPrevalentRedirectionSources = DomainIDSet()
                _ = recursivelyFindNonPrevalentDomainsThatRedirectedToThisDomain(registrableDomainID, &nonPrevalentRedirectionSources, 0)
                setDomainsAsPrevalent(nonPrevalentRedirectionSources)
            }
        }
    }

    private func setDomainsAsPrevalent(_ domains: DomainIDSet) {
        assert(!WTF.RunLoop.isMain())

        guard
            let domainsToUpdateStatement = database.prepareStatement(
                WTF.String("UPDATE ObservedDomains SET isPrevalent = 1 WHERE domainID IN (" + integerList(domains.domainIDs) + ")")
            ),
            domainsToUpdateStatement.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("setDomainsAsPrevalent: failed to step statement")
            return
        }
    }

    private func ensureAndSetPrevalentResource(
        _ domain: WebCore.RegistrableDomain,
        _ prevalence: WebKit.ResourceLoadPrevalence,
        _ reason: StaticString
    ) {
        assert(!WTF.RunLoop.isMain())

        if shouldSkip(domain) {
            return
        }

        withTransaction {
            if ensureDomainID(domain, .literal(reason)) == nil {
                return
            }

            setPrevalentResource(domain, prevalence)
        }
    }

    @cxx
    @implementation
    func setPrevalentResource(_ domain: WebCore.RegistrableDomain) {
        ensureAndSetPrevalentResource(domain, WebKit.High, "setPrevalentResource")
    }

    @cxx
    @implementation
    func setVeryPrevalentResource(_ domain: WebCore.RegistrableDomain) {
        ensureAndSetPrevalentResource(domain, WebKit.VeryHigh, "setVeryPrevalentResource")
    }

    private func clearGrandfathering(_ domainIDsToClear: WebKit.DomainIDVector) {
        assert(!WTF.RunLoop.isMain())

        if domainIDsToClear.isEmpty() {
            return
        }

        let listToClear = integerList((0..<domainIDsToClear.size()).map { domainIDsToClear[$0] })

        guard
            let clearGrandfatheringStatement = database.prepareStatement(
                WTF.String("UPDATE ObservedDomains SET grandfathered = 0 WHERE domainID IN (" + listToClear + ")")
            )
        else {
            return
        }

        if clearGrandfatheringStatement.step() != SQLITE_DONE {
            releaseLogDatabaseError("clearGrandfathering: failed to step statement")
        }
    }

    @cxx
    @implementation
    func pruneStatisticsIfNeeded() {
        assert(!WTF.RunLoop.isMain())

        guard let statement = scopedStatement(.observedDomainCount, "pruneStatisticsIfNeeded") else {
            return
        }

        let count = statement.step() == SQLITE_ROW ? UInt32(truncatingIfNeeded: statement.columnInt(0)) : 0

        if Int(count) <= m_parameters.maxStatisticsEntries {
            return
        }

        assert(m_parameters.pruneEntriesDownTo <= m_parameters.maxStatisticsEntries)

        let countLeftToPrune = Int(count) &- m_parameters.pruneEntriesDownTo
        assert(countLeftToPrune != 0)

        guard
            let recordsToPrune = database.prepareStatement(
                WTF.String("SELECT domainID FROM ObservedDomains ORDER BY hadUserInteraction, isPrevalent, lastSeen LIMIT ?")
            ),
            recordsToPrune.bindInt(1, Int32(truncatingIfNeeded: countLeftToPrune)) == SQLITE_OK
        else {
            releaseLogDatabaseError("pruneStatisticsIfNeeded: failed to bind parameter")
            return
        }

        var entriesToPrune: [UInt32] = []
        while recordsToPrune.step() == SQLITE_ROW {
            entriesToPrune.append(UInt32(truncatingIfNeeded: recordsToPrune.columnInt(0)))
        }

        guard
            let pruneCommand = database.prepareStatement(
                WTF.String("DELETE from ObservedDomains WHERE domainID IN (" + integerList(entriesToPrune) + ")")
            ),
            pruneCommand.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("pruneStatisticsIfNeeded: failed to step statement")
            return
        }
    }
}

// MARK: Storage access decisions

extension WebKit.ResourceLoadStatisticsStore {
    private func areAllUnpartitionedThirdPartyCookiesBlockedUnder(_ topFrameDomain: WebCore.RegistrableDomain) -> Bool {
        #if ENABLE_OPT_IN_PARTITIONED_COOKIES
        if thirdPartyCookieBlockingMode() == .All || thirdPartyCookieBlockingMode() == .AllExceptPartitioned {
            return true
        }
        #else
        if thirdPartyCookieBlockingMode() == .All {
            return true
        }
        #endif

        if thirdPartyCookieBlockingMode() == .AllOnSitesWithoutUserInteraction && !hasHadUserInteraction(topFrameDomain, .Long) {
            return true
        }

        return false
    }

    @cxx
    @implementation
    func cookieAccess(
        _ subresourceDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction
    ) -> WebKit.CookieAccess {
        assert(!WTF.RunLoop.isMain())

        guard
            let statement = database.prepareStatement(
                WTF.String("SELECT isPrevalent, hadUserInteraction FROM ObservedDomains WHERE registrableDomain = ?")
            ),
            statement.bindText(1, Self.string(subresourceDomain)) == SQLITE_OK
        else {
            releaseLogDatabaseError("cookieAccess: failed to bind parameter")
            return .CannotRequest
        }

        let hasNoEntry = statement.step() != SQLITE_ROW
        let isPrevalent = !hasNoEntry && statement.columnInt(0) != 0
        let hadUserInteraction = !hasNoEntry && statement.columnInt(1) != 0

        if !areAllUnpartitionedThirdPartyCookiesBlockedUnder(topFrameDomain) && !isPrevalent {
            return .BasedOnCookiePolicy
        }

        if canRequestStorageAccessWithoutUserInteraction == .No && !hadUserInteraction {
            return .CannotRequest
        }

        return .OnlyIfGranted
    }

    func storageAccessPermission(
        _ subFrameDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain
    ) -> WebCore.PermissionState {
        assert(!WTF.RunLoop.isMain())

        guard let subFrameDomainID = Optional(fromCxx: domainID(subFrameDomain)),
            hasUserGrantedStorageAccessThroughPrompt(subFrameDomainID, topFrameDomain)
        else {
            return .Prompt
        }

        return .Granted
    }

    // StorageAccessPromptWasShown::Yes as true.
    @cxx
    @implementation
    func hasUserGrantedStorageAccessThroughPrompt(_ requestingDomainID: UInt32, _ firstPartyDomain: WebCore.RegistrableDomain) -> Bool {
        assert(!WTF.RunLoop.isMain())

        let result = ensureResourceStatistics(firstPartyDomain, .literal("hasUserGrantedStorageAccessThroughPrompt"))
        guard let firstPartyPrimaryDomainID = Optional(fromCxx: result.second) else {
            return false
        }

        guard
            let statement = database.prepareStatement(
                WTF.String("SELECT COUNT(*) FROM StorageAccessUnderTopFrameDomains WHERE domainID = ? AND topLevelDomainID = ?")
            ),
            statement.bindInt(1, Int32(truncatingIfNeeded: requestingDomainID)) == SQLITE_OK,
            statement.bindInt(2, Int32(truncatingIfNeeded: firstPartyPrimaryDomainID)) == SQLITE_OK,
            statement.step() == SQLITE_ROW
        else {
            return false
        }

        return statement.columnInt(0) != 0
    }

    @cxx
    @implementation
    func grantStorageAccessPermission(
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ subFrameDomain: WebCore.RegistrableDomain
    ) -> WebKit.ResourceLoadStatisticsStore.AddedRecordAndDomainID {
        assert(!WTF.RunLoop.isMain())

        let subFrameStatus = ensureResourceStatistics(subFrameDomain, .literal("grantStorageAccessPermission"))
        guard let subFrameDomainID = Optional(fromCxx: subFrameStatus.second) else {
            return subFrameStatus
        }

        insertDomainRelationshipList(.storageAccessUnderTopFrameDomains, topFrameDomain, subFrameDomainID)
        return subFrameStatus
    }

    @cxx
    @implementation
    func revokeStorageAccessPermission(_ domain: WebCore.RegistrableDomain) {
        assert(!WTF.RunLoop.isMain())

        guard let domainID = ensureDomainID(domain, .literal("revokeStorageAccessPermission")) else {
            return
        }

        guard
            let removeStorageAccess = database.prepareStatement(
                WTF.String("DELETE FROM StorageAccessUnderTopFrameDomains WHERE domainID = ?")
            ),
            removeStorageAccess.bindInt(1, Int32(truncatingIfNeeded: domainID)) == SQLITE_OK,
            removeStorageAccess.step() == SQLITE_DONE
        else {
            releaseLogDatabaseError("revokeStorageAccessPermission: failed to step statement")
            return
        }
    }
}

// MARK: Interaction and navigation logging, and debug mode

extension WebKit.ResourceLoadStatisticsStore {
    private func debugModeReleaseLog(_ message: Swift.String) {
        WebKit.LogChannel.ITPDebug().releaseLog.info("ResourceLoadStatisticsStore: \(message, privacy: .public)")
    }

    @cxx
    @implementation
    func setResourceLoadStatisticsDebugMode(_ enable: Bool) {
        assert(!WTF.RunLoop.isMain())

        if m_debugModeEnabled == enable {
            return
        }

        m_debugModeEnabled = enable
        m_debugLoggingEnabled = enable

        if m_debugLoggingEnabled {
            debugModeReleaseLog("Turned ITP Debug Mode on.")
            debugBroadcastConsoleMessage(.ITPDebug, .Info, WTF.String("[ITP] Turned Debug Mode on."))
        } else {
            debugModeReleaseLog("Turned ITP Debug Mode off.")
            debugBroadcastConsoleMessage(.ITPDebug, .Info, WTF.String("[ITP] Turned Debug Mode off."))
        }

        _ = ensurePrevalentResourcesForDebugMode()
        // This will log the current cookie blocking state.
        if enable {
            updateCookieBlockingWithoutCompletion()
        }
    }

    @cxx
    @implementation
    func setPrevalentResourceForDebugMode(_ domain: WebCore.RegistrableDomain) {
        m_debugManualPrevalentResource = domain
    }

    @cxx
    @implementation
    func ensurePrevalentResourcesForDebugMode() -> WebKit.RegistrableDomainVector {
        assert(!WTF.RunLoop.isMain())

        if !debugModeEnabled() {
            return WebKit.RegistrableDomainVector()
        }

        var primaryDomainsToBlock = WebKit.RegistrableDomainVector()

        let didBeginTransaction = beginTransactionIfNecessaryForSwift()
        defer { commitTransactionForSwift(didBeginTransaction) }

        let reason = EnsureResourceStatisticsReason.literal("ensurePrevalentResourcesForDebugMode")
        let staticPrevalentResource = m_debugStaticPrevalentResource
        if ensureDomainID(staticPrevalentResource, reason) == nil {
            return WebKit.RegistrableDomainVector()
        }

        setPrevalentResource(staticPrevalentResource, WebKit.High)
        primaryDomainsToBlock.append(consuming: staticPrevalentResource)

        let manualPrevalentResource = m_debugManualPrevalentResource
        if !manualPrevalentResource.isEmpty() {
            if ensureDomainID(manualPrevalentResource, reason) == nil {
                return WebKit.RegistrableDomainVector()
            }
            setPrevalentResource(manualPrevalentResource, WebKit.High)
            primaryDomainsToBlock.append(consuming: manualPrevalentResource)

            if debugLoggingEnabled() {
                let domain = Self.string(m_debugManualPrevalentResource).description
                WebKit.LogChannel.ITPDebug().releaseLog
                    .info(
                        """
                        ResourceLoadStatisticsStore: Did set \(domain, privacy: .private) as prevalent resource \
                        for the purposes of ITP Debug Mode.
                        """
                    )
                debugBroadcastConsoleMessage(
                    .ITPDebug,
                    .Info,
                    WTF.String(
                        "[ITP] Did set '" + domain + "' as prevalent resource for the purposes of ITP Debug Mode."
                    )
                )
            }
        }

        return primaryDomainsToBlock
    }

    @cxx
    @implementation
    func logFrameNavigation(
        _ targetDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ sourceDomain: WebCore.RegistrableDomain,
        _ isRedirect: Bool,
        _ isMainFrame: Bool,
        _ delayAfterMainFrameDocumentLoad: WTF.Seconds,
        _ wasPotentiallyInitiatedByUser: Bool
    ) {
        assert(!WTF.RunLoop.isMain())

        let areTargetAndTopFrameDomainsSameSite = Self.string(targetDomain) == Self.string(topFrameDomain)
        let areTargetAndSourceDomainsSameSite = Self.string(targetDomain) == Self.string(sourceDomain)

        withTransaction {
            var statisticsWereUpdated = false
            if !isMainFrame && !(areTargetAndTopFrameDomainsSameSite || areTargetAndSourceDomainsSameSite) {
                let targetResult = ensureResourceStatistics(targetDomain, .literal("logFrameNavigation"))
                guard let targetDomainID = Optional(fromCxx: targetResult.second) else {
                    return
                }

                updateLastSeenRecord(targetDomain, Self.reduceTimeResolution(WTF.Seconds(nowTime())).value())
                insertDomainRelationshipList(.subframeUnderTopFrameDomains, topFrameDomain, targetDomainID)
                statisticsWereUpdated = true
            }

            if !areTargetAndSourceDomainsSameSite {
                if isMainFrame {
                    let wasNavigatedAfterShortDelayWithoutUserInteraction =
                        !wasPotentiallyInitiatedByUser
                        && delayAfterMainFrameDocumentLoad.value() < m_parameters.minDelayAfterMainFrameDocumentLoadToNotBeARedirect.value()
                    if isRedirect || wasNavigatedAfterShortDelayWithoutUserInteraction {
                        let redirectingDomainResult = ensureResourceStatistics(sourceDomain, .literal("logFrameNavigation"))
                        let targetResult = ensureResourceStatistics(targetDomain, .literal("logFrameNavigation"))
                        guard let targetDomainID = Optional(fromCxx: targetResult.second),
                            let redirectingDomainID = Optional(fromCxx: redirectingDomainResult.second)
                        else {
                            return
                        }

                        insertDomainRelationshipList(.topFrameUniqueRedirectsTo, targetDomain, redirectingDomainID)
                        if isRedirect {
                            insertDomainRelationshipList(
                                .topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
                                targetDomain,
                                redirectingDomainID
                            )

                            if debugLoggingEnabled() {
                                let source = Self.string(sourceDomain).description
                                let target = Self.string(targetDomain).description
                                debugModeReleaseLog("Did set \(source) as making a top frame redirect to \(target).")
                                debugBroadcastConsoleMessage(
                                    .ITPDebug,
                                    .Info,
                                    WTF.String(
                                        "Did set '" + source + "' as making a top frame redirect to '" + target + "'."
                                    )
                                )
                            }
                        }
                        insertDomainRelationshipList(.topFrameUniqueRedirectsFrom, sourceDomain, targetDomainID)
                        statisticsWereUpdated = true
                    }
                } else if isRedirect {
                    let redirectingDomainResult = ensureResourceStatistics(sourceDomain, .literal("logFrameNavigation"))
                    let targetResult = ensureResourceStatistics(targetDomain, .literal("logFrameNavigation"))
                    guard let targetDomainID = Optional(fromCxx: targetResult.second),
                        let redirectingDomainID = Optional(fromCxx: redirectingDomainResult.second)
                    else {
                        return
                    }

                    insertDomainRelationshipList(.subresourceUniqueRedirectsTo, targetDomain, redirectingDomainID)
                    insertDomainRelationshipList(.subresourceUniqueRedirectsFrom, sourceDomain, targetDomainID)
                    statisticsWereUpdated = true
                }
            }

            if statisticsWereUpdated {
                scheduleStatisticsProcessingRequestIfNecessary()
            }
        }
    }

    @cxx
    @implementation
    func logCrossSiteLoadWithLinkDecoration(
        _ fromDomain: WebCore.RegistrableDomain,
        _ toDomain: WebCore.RegistrableDomain,
        _ didFilterKnownLinkDecoration: WebKit.DidFilterKnownLinkDecoration
    ) {
        assert(!WTF.RunLoop.isMain())
        assert(!(Self.string(fromDomain) == Self.string(toDomain)))

        withTransaction {
            let toDomainResult = ensureResourceStatistics(toDomain, .literal("logCrossSiteLoadWithLinkDecoration"))
            guard let toDomainID = Optional(fromCxx: toDomainResult.second) else {
                return
            }

            insertDomainRelationshipList(.topFrameLinkDecorationsFrom, fromDomain, toDomainID)

            let currentDataRemovalFrequency = dataRemovalFrequency(toDomain)
            if currentDataRemovalFrequency == .Short {
                return
            }

            let newDataRemovalFrequency: WebKit.DataRemovalFrequency = didFilterKnownLinkDecoration == .Yes ? .Long : .Short
            if currentDataRemovalFrequency == newDataRemovalFrequency {
                return
            }

            if isPrevalentResource(fromDomain) {
                setIsScheduledForAllScriptWrittenStorageRemoval(toDomain, newDataRemovalFrequency)
            }
        }
    }

    // logUserInteraction's records, inside its transaction: whether cookie blocking needs an update.
    @cxx
    @implementation
    func logUserInteractionRecord(_ domain: WebCore.RegistrableDomain) -> Bool {
        if ensureDomainID(domain, .literal("logUserInteraction")) == nil {
            return false
        }

        let didHavePreviousUserInteraction = hasHadUserInteraction(domain, .Long)
        setUserInteractionRecord(domain, true, nowTime())

        return !didHavePreviousUserInteraction
    }

    // clearUserInteraction's records, inside its transaction.
    @cxx
    @implementation
    func clearUserInteractionRecords(_ domain: WebCore.RegistrableDomain) {
        setUserInteractionRecord(domain, false, 0)

        revokeStorageAccessPermission(domain)
    }

    @cxx
    @implementation
    func hasHadUserInteraction(_ domain: WebCore.RegistrableDomain, _ operatingDatesWindow: WebKit.OperatingDatesWindow) -> Bool {
        assert(!WTF.RunLoop.isMain())

        return withTransaction {
            let mostRecentUserInteractionTime: Double
            do {
                guard let statement = scopedStatement(.hadUserInteraction, "hasHadUserInteraction"),
                    statement.bindText(1, Self.string(domain)) == SQLITE_OK,
                    statement.step() == SQLITE_ROW
                else {
                    releaseLogDatabaseError("hasHadUserInteraction: failed to step statement")
                    return false
                }

                if statement.columnInt(0) == 0 {
                    return false
                }
                mostRecentUserInteractionTime = statement.columnDouble(1)
            }

            if hasStatisticsExpired(WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(mostRecentUserInteractionTime)), operatingDatesWindow) {
                // Drop privacy sensitive data because we no longer need it.
                // Set timestamp to 0 so that statistics merge will know
                // it has been reset as opposed to its default -1.
                // This transaction covers the clear.
                clearUserInteractionRecords(domain)
                updateCookieBlockingWithoutCompletion()
                return false
            }
            return true
        }
    }
}

// MARK: Cookie blocking, the website-data-removal classifier, and clear

extension WebKit.ResourceLoadStatisticsStore {
    @cxx
    @implementation
    func setCacheMaxAgeCap(_ seconds: WTF.Seconds) {
        assert(!WTF.RunLoop.isMain())
        assert(seconds.value() >= 0)

        m_parameters.cacheMaxAgeCapTime = seconds
        updateCacheMaxAgeCap()
    }

    @cxx
    @implementation
    func shouldRemoveDataRecords() -> Bool {
        assert(!WTF.RunLoop.isMain())

        if m_dataRecordsBeingRemoved {
            return false
        }

        let lastTimeDataRecordsWereRemoved = m_lastTimeDataRecordsWereRemoved.secondsSinceEpoch().value()
        return lastTimeDataRecordsWereRemoved == 0
            || WTF.MonotonicTime.now().secondsSinceEpoch().value()
                >= lastTimeDataRecordsWereRemoved + m_parameters.minimumTimeBetweenDataRecordsRemoval.value()
            || m_parameters.isRunningTest
    }

    @cxx
    @implementation
    func setDataRecordsBeingRemoved(_ value: Bool) {
        assert(!WTF.RunLoop.isMain())

        m_dataRecordsBeingRemoved = value
        if m_dataRecordsBeingRemoved {
            m_lastTimeDataRecordsWereRemoved = WTF.MonotonicTime.now()
        }
    }

    private func shouldEnforceSameSiteStrictForSpecificDomain(_ domain: WebCore.RegistrableDomain) -> Bool {
        // We currently know of no domains that need this protection.
        false
    }

    @cxx
    @implementation
    func debugLogDomainsInBatches(
        _ action: WTF.String,
        _ domainsToBlockAndDeleteCookiesFor: WebKit.RegistrableDomainVector,
        _ domainsToBlockButKeepCookiesFor: WebKit.RegistrableDomainVector
    ) {
        assert(debugLoggingEnabled())

        var domains: [Swift.String] = []
        for index in 0..<domainsToBlockAndDeleteCookiesFor.size() {
            domains.append(Self.string(domainsToBlockAndDeleteCookiesFor[index]).description)
        }
        for index in 0..<domainsToBlockButKeepCookiesFor.size() {
            domains.append(Self.string(domainsToBlockButKeepCookiesFor[index]).description)
        }
        if domains.isEmpty {
            return
        }

        let actionText = action.description
        let allDomains = domains.joined(separator: ", ")
        debugBroadcastConsoleMessage(.ITPDebug, .Info, WTF.String("[ITP] " + actionText + " to: [" + allDomains + "]."))

        let maxNumberOfDomainsInOneLogStatement = 50

        if domains.count <= maxNumberOfDomainsInOneLogStatement {
            debugModeReleaseLog("\(actionText) to: \(allDomains).")
            return
        }

        let numberOfBatches = UInt32((Float(domains.count) / Float(maxNumberOfDomainsInOneLogStatement)).rounded(.up))
        var batchNumber = 1
        var batchStart = 0
        while batchStart < domains.count {
            let batchEnd = min(batchStart + maxNumberOfDomainsInOneLogStatement, domains.count)
            let batch = domains[batchStart..<batchEnd].joined(separator: ", ")
            debugModeReleaseLog("\(actionText) to (\(batchNumber) of \(numberOfBatches)): \(batch).")
            batchNumber += 1
            batchStart = batchEnd
        }
    }

    private func clearTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement(_ domain: WebCore.RegistrableDomain) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            let targetResult = ensureResourceStatistics(domain, .literal("clearTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement"))
            guard let targetDomainID = Optional(fromCxx: targetResult.second) else {
                return
            }

            do {
                guard
                    let removeRedirectsToSinceSameSite = database.prepareStatement(
                        WTF.String("DELETE FROM TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement WHERE sourceDomainID = ?")
                    ),
                    removeRedirectsToSinceSameSite.bindInt(1, Int32(truncatingIfNeeded: targetDomainID)) == SQLITE_OK,
                    removeRedirectsToSinceSameSite.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError("clearTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement: failed to step statement")
                    return
                }
            }
        }
    }

    @cxx
    @implementation
    func clearDatabaseContents() {
        withTransaction {
            database.clearAllTables()

            if !createSchema() {
                releaseLogError("clearDatabaseContents: failed to create schema")
            }
        }
    }

    private func registrableDomains(_ query: Swift.String) -> WebKit.RegistrableDomainVector {
        var results = WebKit.RegistrableDomainVector()
        guard let statement = database.prepareStatement(WTF.String(query)) else {
            return results
        }

        while statement.step() == SQLITE_ROW {
            results.append(consuming: WebCore.RegistrableDomain.fromRawString(consuming: statement.columnText(0)))
        }
        return results
    }

    @cxx
    @implementation
    func domainsToBlockAndDeleteCookiesFor() -> WebKit.RegistrableDomainVector {
        assert(!WTF.RunLoop.isMain())

        return registrableDomains("SELECT registrableDomain FROM ObservedDomains WHERE isPrevalent = 1 AND hadUserInteraction = 0")
    }

    @cxx
    @implementation
    func domainsToBlockButKeepCookiesFor() -> WebKit.RegistrableDomainVector {
        assert(!WTF.RunLoop.isMain())

        return registrableDomains("SELECT registrableDomain FROM ObservedDomains WHERE isPrevalent = 1 AND hadUserInteraction = 1")
    }

    @cxx
    @implementation
    func domainsWithUserInteractionAsFirstParty() -> WebKit.RegistrableDomainVector {
        assert(!WTF.RunLoop.isMain())

        return registrableDomains("SELECT registrableDomain FROM ObservedDomains WHERE hadUserInteraction = 1")
    }

    @cxx
    @implementation
    func domains() -> WebKit.ResourceLoadStatisticsStore.DomainDataVector {
        assert(!WTF.RunLoop.isMain())

        var results = DomainDataVector()
        guard
            let statement = database.prepareStatement(
                WTF.String(
                    """
                    SELECT domainID, registrableDomain, mostRecentUserInteractionTime, mostRecentWebPushInteractionTime, \
                    hadUserInteraction, grandfathered, isScheduledForAllButCookieDataRemoval, countOfTopFrameRedirects \
                    FROM ObservedDomains LEFT JOIN (SELECT sourceDomainID, COUNT(*) as countOfTopFrameRedirects \
                    from TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement GROUP BY sourceDomainID) as z \
                    ON z.sourceDomainID = domainID
                    """
                )
            )
        else {
            return results
        }

        while statement.step() == SQLITE_ROW {
            var domainData = DomainData()
            domainData.domainID = UInt32(truncatingIfNeeded: statement.columnInt(0))
            domainData.registrableDomain = WebCore.RegistrableDomain.fromRawString(consuming: statement.columnText(1))
            domainData.mostRecentUserInteractionTime = WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(statement.columnDouble(2)))
            domainData.mostRecentWebPushInteractionTime = WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(statement.columnDouble(3)))
            domainData.hadUserInteraction = statement.columnInt(4) != 0
            domainData.grandfathered = statement.columnInt(5) != 0
            domainData.dataRemovalFrequency = toDataRemovalFrequency(statement.columnInt(6))
            domainData.topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement = UInt32(truncatingIfNeeded: statement.columnInt(7))
            results.append(consuming: domainData)
        }

        return results
    }

    private func hasHadRecentWebPushInteraction(_ resourceStatistic: DomainData) -> Bool {
        resourceStatistic.mostRecentWebPushInteractionTime.secondsSinceEpoch().value() != 0
            && !hasStatisticsExpired(resourceStatistic.mostRecentWebPushInteractionTime, .Long)
    }

    private func hasHadUnexpiredRecentUserInteraction(
        _ resourceStatistic: DomainData,
        _ operatingDatesWindow: WebKit.OperatingDatesWindow
    ) -> Bool {
        if resourceStatistic.hadUserInteraction
            && hasStatisticsExpired(resourceStatistic.mostRecentUserInteractionTime, operatingDatesWindow)
        {
            // Drop privacy sensitive data if we no longer need it.
            if operatingDatesWindow == .Long {
                // The caller's transaction covers the clear.
                clearUserInteractionRecords(resourceStatistic.registrableDomain)
                updateCookieBlockingWithoutCompletion()
            }

            return false
        }

        return resourceStatistic.hadUserInteraction
    }

    private func shouldRemoveAllWebsiteDataFor(_ resourceStatistic: DomainData, _ shouldCheckForGrandfathering: Bool) -> Bool {
        isPrevalentResource(resourceStatistic.registrableDomain)
            && !hasHadUnexpiredRecentUserInteraction(resourceStatistic, .Long)
            && (!shouldCheckForGrandfathering || !resourceStatistic.grandfathered)
    }

    private func shouldRemoveAllButCookiesFor(_ resourceStatistic: DomainData, _ shouldCheckForGrandfathering: Bool) -> Bool {
        let removalMode = firstPartyWebsiteDataRemovalMode()
        let isRemovalEnabled = removalMode != .None || resourceStatistic.dataRemovalFrequency != .Never
        let isResourceGrandfathered = shouldCheckForGrandfathering && resourceStatistic.grandfathered

        var window: WebKit.OperatingDatesWindow = .Long
        if removalMode == .AllButCookies || removalMode == .None {
            window = resourceStatistic.dataRemovalFrequency == .Short ? .Short : .Long
        } else if removalMode == .AllButCookiesLiveOnTestingTimeout {
            window = .ForLiveOnTesting
        } else if removalMode == .AllButCookiesReproTestingTimeout {
            window = .ForReproTesting
        }

        return isRemovalEnabled && !isResourceGrandfathered && !hasHadUnexpiredRecentUserInteraction(resourceStatistic, window)
    }

    private func shouldEnforceSameSiteStrictFor(_ resourceStatistic: DomainData, _ shouldCheckForGrandfathering: Bool) -> Bool {
        if (!isSameSiteStrictEnforcementEnabled() && !shouldEnforceSameSiteStrictForSpecificDomain(resourceStatistic.registrableDomain))
            || (shouldCheckForGrandfathering && resourceStatistic.grandfathered)
        {
            return false
        }

        if Int(resourceStatistic.topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement)
            > m_parameters.minimumTopFrameRedirectsForSameSiteStrictEnforcement
        {
            clearTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement(resourceStatistic.registrableDomain)
            return true
        }

        return false
    }

    // mostRecentUserInteractionTime(statistic), in seconds since the epoch.
    private func mostRecentUserInteractionTime(_ statistic: DomainData) -> Double? {
        let seconds = statistic.mostRecentUserInteractionTime.secondsSinceEpoch().value()
        if seconds <= 0 {
            return nil
        }

        return seconds
    }

    @cxx
    @implementation
    func registrableDomainsToDeleteOrRestrictWebsiteDataFor() -> WebKit.RegistrableDomainsToDeleteOrRestrictWebsiteDataFor {
        assert(!WTF.RunLoop.isMain())

        let now = nowTime()
        let endOfGrandfatheringTimestamp = m_endOfGrandfatheringTimestamp.secondsSinceEpoch().value()
        let shouldCheckForGrandfathering = endOfGrandfatheringTimestamp > now
        let shouldClearGrandfathering = !shouldCheckForGrandfathering && endOfGrandfatheringTimestamp != 0

        if shouldClearGrandfathering {
            clearEndOfGrandfatheringTimeStamp()
        }

        var oldestUserInteraction = now
        var toDeleteOrRestrictFor = WebKit.RegistrableDomainsToDeleteOrRestrictWebsiteDataFor()

        let didBeginTransaction = beginTransactionIfNecessaryForSwift()
        defer { commitTransactionForSwift(didBeginTransaction) }

        let domains = self.domains()
        var domainIDsToClearGrandfathering = WebKit.DomainIDVector()
        for index in 0..<domains.size() {
            let statistic = domains[index]

            // Domains permanently configured to be exempt. This can be home screen web applications, app-bound domains, or similar.
            if shouldExemptFromWebsiteDataDeletion(statistic.registrableDomain) {
                continue
            }

            // Domains with WebPush that the user interacts with continuously should keep their data.
            if hasHadRecentWebPushInteraction(statistic) {
                continue
            }

            if let mostRecentUserInteractionTime = mostRecentUserInteractionTime(statistic),
                mostRecentUserInteractionTime < oldestUserInteraction
            {
                oldestUserInteraction = mostRecentUserInteractionTime
            }

            if shouldRemoveAllWebsiteDataFor(statistic, shouldCheckForGrandfathering) {
                toDeleteOrRestrictFor.domainsToDeleteAllCookiesFor.append(consuming: statistic.registrableDomain)
                toDeleteOrRestrictFor.domainsToDeleteAllScriptWrittenStorageFor.append(consuming: statistic.registrableDomain)
            } else {
                if shouldRemoveAllButCookiesFor(statistic, shouldCheckForGrandfathering) {
                    toDeleteOrRestrictFor.domainsToDeleteAllScriptWrittenStorageFor.append(consuming: statistic.registrableDomain)
                    setIsScheduledForAllScriptWrittenStorageRemoval(statistic.registrableDomain, .Never)
                }
                if shouldEnforceSameSiteStrictFor(statistic, shouldCheckForGrandfathering) {
                    toDeleteOrRestrictFor.domainsToEnforceSameSiteStrictFor.append(consuming: statistic.registrableDomain)

                    if debugLoggingEnabled() {
                        let domain = Self.string(statistic.registrableDomain).description
                        debugModeReleaseLog("Scheduled \(domain) to have its cookies set to SameSite=strict.")
                        debugBroadcastConsoleMessage(
                            .ITPDebug,
                            .Info,
                            WTF.String("Scheduled '" + domain + "' to have its cookies set to SameSite=strict'.")
                        )
                    }
                }
            }
            if shouldClearGrandfathering && statistic.grandfathered {
                domainIDsToClearGrandfathering.append(consuming: statistic.domainID)
            }
        }

        // Give the user enough time to interact with websites until we remove non-cookie website data.
        if !m_parameters.isRunningTest && now - oldestUserInteraction < m_parameters.minimumTimeBetweenDataRecordsRemoval.value() {
            toDeleteOrRestrictFor.domainsToDeleteAllScriptWrittenStorageFor.clear()
        }

        clearGrandfathering(domainIDsToClearGrandfathering)

        return toDeleteOrRestrictFor
    }
}

// MARK: The dump and third-party data

private func hasBeenThirdParty(_ timesUnderFirstParty: UInt32) -> Bool {
    timesUnderFirstParty > 0
}

private func hasHadRecentUserInteraction(_ interactionTimeSeconds: Double, _ now: Double) -> Bool {
    interactionTimeSeconds > 0 && now - interactionTimeSeconds < 24 * 60 * 60
}

// The dump's related-domain tables, in the order the dump prints them, with the query each reads (none for
// TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement, which prints nothing).
private enum SubStatisticTable: Int, CaseIterable {
    case storageAccessUnderTopFrameDomains
    case topFrameUniqueRedirectsTo
    case topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement
    case topFrameUniqueRedirectsFrom
    case topFrameLinkDecorationsFrom
    case topFrameLoadedThirdPartyScripts
    case subframeUnderTopFrameDomains
    case subresourceUnderTopFrameDomains
    case subresourceUniqueRedirectsTo
    case subresourceUniqueRedirectsFrom

    var name: Swift.String {
        switch self {
        case .storageAccessUnderTopFrameDomains: "StorageAccessUnderTopFrameDomains"
        case .topFrameUniqueRedirectsTo: "TopFrameUniqueRedirectsTo"
        case .topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement: "TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement"
        case .topFrameUniqueRedirectsFrom: "TopFrameUniqueRedirectsFrom"
        case .topFrameLinkDecorationsFrom: "TopFrameLinkDecorationsFrom"
        case .topFrameLoadedThirdPartyScripts: "TopFrameLoadedThirdPartyScripts"
        case .subframeUnderTopFrameDomains: "SubframeUnderTopFrameDomains"
        case .subresourceUnderTopFrameDomains: "SubresourceUnderTopFrameDomains"
        case .subresourceUniqueRedirectsTo: "SubresourceUniqueRedirectsTo"
        case .subresourceUniqueRedirectsFrom: "SubresourceUniqueRedirectsFrom"
        }
    }

    var query: Swift.String? {
        switch self {
        case .storageAccessUnderTopFrameDomains:
            "SELECT topLevelDomainID from StorageAccessUnderTopFrameDomains WHERE domainID = ?"
        case .topFrameUniqueRedirectsTo:
            "SELECT toDomainID from TopFrameUniqueRedirectsTo WHERE sourceDomainID = ?"
        case .topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement:
            nil
        case .topFrameUniqueRedirectsFrom:
            "SELECT fromDomainID from TopFrameUniqueRedirectsFrom WHERE targetDomainID = ?"
        case .topFrameLinkDecorationsFrom:
            "SELECT fromDomainID from TopFrameLinkDecorationsFrom WHERE toDomainID = ?"
        case .topFrameLoadedThirdPartyScripts:
            "SELECT subresourceDomainID from TopFrameLoadedThirdPartyScripts WHERE topFrameDomainID = ?"
        case .subframeUnderTopFrameDomains:
            "SELECT topFrameDomainID from SubframeUnderTopFrameDomains WHERE subFrameDomainID = ?"
        case .subresourceUnderTopFrameDomains:
            "SELECT topFrameDomainID from SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ?"
        case .subresourceUniqueRedirectsTo:
            "SELECT toDomainID from SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ?"
        case .subresourceUniqueRedirectsFrom:
            "SELECT fromDomainID from SubresourceUniqueRedirectsFrom WHERE subresourceDomainID = ?"
        }
    }
}

// The dump's fixed text as WTF::Strings, made once per dump.
private struct DumpPieces {
    let header = WTF.String("Resource load statistics:\n\n")
    let registrableDomain = WTF.String("Registrable domain: ")
    let newline = WTF.String("\n")
    let yes = WTF.String("Yes")
    let no = WTF.String("No")
    let hadUserInteraction = WTF.String("    hadUserInteraction: ")
    let mostRecentUserInteraction = WTF.String("    mostRecentUserInteraction: ")
    let withinDay = WTF.String("within 24 hours")
    let noRecentInteraction = WTF.String("-1")
    let grandfathered = WTF.String("    grandfathered: ")
    let dataRemovalFrequency = WTF.String("    DataRemovalFrequency: ")
    let never = WTF.String("Never")
    let short = WTF.String("Short")
    let long = WTF.String("Long")
    let unknown = WTF.String("Unknown")
    let isPrevalentResource = WTF.String("    isPrevalentResource: ")
    let isVeryPrevalentResource = WTF.String("    isVeryPrevalentResource: ")
    let dataRecordsRemoved = WTF.String("    dataRecordsRemoved: ")
    let entryIndent = WTF.String("        ")
    let thirdPartyHeader = WTF.String("\nITP Data:\n")
    // By SubStatisticTable.rawValue: "    <name>:\n", and the query as SQL.
    let tableHeaders = SubStatisticTable.allCases.map { WTF.String("    " + $0.name + ":\n") }
    let tableQueries = SubStatisticTable.allCases.map { table -> WTF.String? in
        guard let query = table.query else {
            return nil
        }
        return WTF.String(query)
    }

    func boolean(_ flag: Bool) -> WTF.String {
        flag ? yes : no
    }

    func query(_ table: SubStatisticTable) -> WTF.String? {
        tableQueries[table.rawValue]
    }

    func dataRemovalFrequencyText(_ dataRemovalFrequency: WebKit.DataRemovalFrequency) -> WTF.String {
        switch dataRemovalFrequency {
        case .Never:
            return never
        case .Short:
            return short
        case .Long:
            return long
        default:
            assertionFailure()
            return unknown
        }
    }
}

// The dump's per-domain statements, reset and bound again for each domain.
private struct DumpStatements: ~Copyable {
    let storageAccessUnderTopFrameDomains: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let topFrameUniqueRedirectsTo: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let topFrameUniqueRedirectsFrom: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let topFrameLinkDecorationsFrom: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let topFrameLoadedThirdPartyScripts: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let subframeUnderTopFrameDomains: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let subresourceUnderTopFrameDomains: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let subresourceUniqueRedirectsTo: WebKit.ResourceLoadStatisticsStore.SQLStatement?
    let subresourceUniqueRedirectsFrom: WebKit.ResourceLoadStatisticsStore.SQLStatement?

    init(_ database: WebKit.ResourceLoadStatisticsStore.Database, _ pieces: DumpPieces) {
        func prepare(_ table: SubStatisticTable) -> WebKit.ResourceLoadStatisticsStore.SQLStatement? {
            guard let query = pieces.query(table) else {
                return nil
            }
            return database.prepareStatement(query)
        }
        storageAccessUnderTopFrameDomains = prepare(.storageAccessUnderTopFrameDomains)
        topFrameUniqueRedirectsTo = prepare(.topFrameUniqueRedirectsTo)
        topFrameUniqueRedirectsFrom = prepare(.topFrameUniqueRedirectsFrom)
        topFrameLinkDecorationsFrom = prepare(.topFrameLinkDecorationsFrom)
        topFrameLoadedThirdPartyScripts = prepare(.topFrameLoadedThirdPartyScripts)
        subframeUnderTopFrameDomains = prepare(.subframeUnderTopFrameDomains)
        subresourceUnderTopFrameDomains = prepare(.subresourceUnderTopFrameDomains)
        subresourceUniqueRedirectsTo = prepare(.subresourceUniqueRedirectsTo)
        subresourceUniqueRedirectsFrom = prepare(.subresourceUniqueRedirectsFrom)
    }
}

private let joinSubStatisticsForSorting = """
    SELECT domainID,\
    (countSubFrameUnderTopFrame + countSubResourceUnderTopFrame + countUniqueRedirectTo) as sum  \
    FROM ( \
    SELECT \
    domainID, \
    COUNT(DISTINCT f.topFrameDomainID) as countSubFrameUnderTopFrame, \
    COUNT(DISTINCT r.topFrameDomainID) as countSubResourceUnderTopFrame, \
    COUNT(DISTINCT toDomainID) as countUniqueRedirectTo \
    FROM \
    ObservedDomains o \
    LEFT JOIN SubframeUnderTopFrameDomains f ON o.domainID = f.subFrameDomainID \
    LEFT JOIN SubresourceUnderTopFrameDomains r ON o.domainID = r.subresourceDomainID \
    LEFT JOIN SubresourceUniqueRedirectsTo u ON o.domainID = u.subresourceDomainID \
    WHERE isPrevalent LIKE ? \
    and hadUserInteraction LIKE ? \
    GROUP BY domainID) ORDER BY sum DESC;
    """

extension WebKit.ResourceLoadStatisticsStore {
    private static var noExistingTimestamp: WTF.Seconds { WTF.Seconds(-1) }

    private func hasStorageAccess(_ topFrameDomain: WebCore.RegistrableDomain, _ subFrameDomain: WebCore.RegistrableDomain) -> Bool {
        let statement = scopedStatement(.storageAccessExists, "hasStorageAccess")
        return relationshipExists(statement, existingDomainID(subFrameDomain), topFrameDomain)
    }

    private func getThirdPartyDataForSpecificFirstPartyDomains(
        _ thirdPartyDomainID: UInt32,
        _ thirdPartyDomain: WebCore.RegistrableDomain
    ) -> WebKit.ITPThirdPartyDataForSpecificFirstPartyVector {
        var thirdPartyDataForSpecificFirstPartyDomains = WebKit.ITPThirdPartyDataForSpecificFirstPartyVector()
        let domainIDValue = Int32(truncatingIfNeeded: thirdPartyDomainID)
        guard let statement = scopedStatement(.getAllSubStatistics, "getThirdPartyDataForSpecificFirstPartyDomains"),
            statement.bindInt(1, domainIDValue) == SQLITE_OK,
            statement.bindInt(2, domainIDValue) == SQLITE_OK,
            statement.bindInt(3, domainIDValue) == SQLITE_OK
        else {
            releaseLogDatabaseError("getThirdPartyDataForSpecificFirstPartyDomains: failed to bind parameters")
            return thirdPartyDataForSpecificFirstPartyDomains
        }

        // ITPThirdPartyDataForSpecificFirstParty's operator==: the first party and whether it was granted storage access.
        // The domain is compared by UTF-16 code units, as WTF::String's == does (Swift's String == is canonical equivalence).
        var firstParties: [(domain: [UInt16], storageAccessGranted: Bool)] = []
        while statement.step() == SQLITE_ROW {
            let firstPartyDomain = WebCore.RegistrableDomain.fromRawString(
                consuming: domainString(UInt32(truncatingIfNeeded: statement.columnInt(0)))
            )
            var thirdPartyData = WebKit.ITPThirdPartyDataForSpecificFirstParty()
            thirdPartyData.firstPartyDomain = firstPartyDomain
            thirdPartyData.storageAccessGranted = hasStorageAccess(firstPartyDomain, thirdPartyDomain)
            thirdPartyData.timeLastUpdated = getMostRecentlyUpdatedTimestamp(thirdPartyDomain, firstPartyDomain)

            let firstParty = (domain: Array(Self.string(firstPartyDomain).description.utf16), granted: thirdPartyData.storageAccessGranted)
            if !firstParties.contains(where: { $0.domain == firstParty.domain && $0.storageAccessGranted == firstParty.granted }) {
                firstParties.append((domain: firstParty.domain, storageAccessGranted: firstParty.granted))
                thirdPartyDataForSpecificFirstPartyDomains.append(consuming: thirdPartyData)
            }
        }
        return thirdPartyDataForSpecificFirstPartyDomains
    }

    @cxx
    @implementation
    func aggregatedThirdPartyData() -> WebKit.ITPThirdPartyDataVector {
        assert(!WTF.RunLoop.isMain())

        var thirdPartyDataList = WebKit.ITPThirdPartyDataVector()
        let mode = thirdPartyCookieBlockingMode()
        var isBlockAll = mode == .All
        #if ENABLE_OPT_IN_PARTITIONED_COOKIES
        isBlockAll = isBlockAll || mode == .AllExceptPartitioned
        #endif
        let prevalentDomainsBindParameter = isBlockAll ? "%" : "1"
        guard let sortedStatistics = database.prepareStatement(WTF.String(joinSubStatisticsForSorting)),
            sortedStatistics.bindText(1, WTF.String(prevalentDomainsBindParameter)) == SQLITE_OK,
            sortedStatistics.bindText(2, WTF.String("%")) == SQLITE_OK
        else {
            releaseLogDatabaseError("aggregatedThirdPartyData: failed to bind parameters")
            return thirdPartyDataList
        }
        while sortedStatistics.step() == SQLITE_ROW {
            if hasBeenThirdParty(UInt32(truncatingIfNeeded: sortedStatistics.columnInt(1))) {
                let thirdPartyDomainID = UInt32(truncatingIfNeeded: sortedStatistics.columnInt(0))
                let thirdPartyDomain = WebCore.RegistrableDomain.fromRawString(consuming: domainString(thirdPartyDomainID))
                var thirdPartyData = WebKit.ITPThirdPartyData()
                thirdPartyData.thirdPartyDomain = thirdPartyDomain
                thirdPartyData.underFirstParties = getThirdPartyDataForSpecificFirstPartyDomains(thirdPartyDomainID, thirdPartyDomain)
                thirdPartyDataList.append(consuming: thirdPartyData)
            }
        }
        return thirdPartyDataList
    }

    private func getMostRecentlyUpdatedTimestamp(
        _ subDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain
    ) -> WTF.Seconds {
        assert(!WTF.RunLoop.isMain())

        let subFrameDomainID = existingDomainID(subDomain)
        let topFrameDomainID = existingDomainID(topFrameDomain)

        guard let subFrameDomainID, let topFrameDomainID else {
            return Self.noExistingTimestamp
        }

        let subFrameDomainIDValue = Int32(truncatingIfNeeded: subFrameDomainID)
        let topFrameDomainIDValue = Int32(truncatingIfNeeded: topFrameDomainID)
        guard let statement = scopedStatement(.getMostRecentlyUpdatedTimestamp, "getMostRecentlyUpdatedTimestamp"),
            statement.bindInt(1, subFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(2, topFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(3, subFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(4, topFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(5, subFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(6, topFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(7, subFrameDomainIDValue) == SQLITE_OK,
            statement.bindInt(8, topFrameDomainIDValue) == SQLITE_OK
        else {
            releaseLogDatabaseError("getMostRecentlyUpdatedTimestamp: failed to step statement")
            return Self.noExistingTimestamp
        }
        guard statement.step() == SQLITE_ROW else {
            return Self.noExistingTimestamp
        }

        return WTF.Seconds(statement.columnDouble(0))
    }

    @cxx
    @implementation
    func isCorrectSubStatisticsCount(_ subframeDomain: WebCore.RegistrableDomain, _ topFrameDomain: WebCore.RegistrableDomain) -> Bool {
        let subFrameUnderTopFrameCount = database.prepareStatement(
            WTF.String("SELECT COUNT(*) FROM SubframeUnderTopFrameDomains WHERE subFrameDomainID = ? AND topFrameDomainID = ?;")
        )
        let subresourceUnderTopFrameCount = database.prepareStatement(
            WTF.String("SELECT COUNT(*) FROM SubresourceUnderTopFrameDomains WHERE subresourceDomainID = ? AND topFrameDomainID = ?;")
        )
        let subresourceUniqueRedirectsTo = database.prepareStatement(
            WTF.String("SELECT COUNT(*) FROM SubresourceUniqueRedirectsTo WHERE subresourceDomainID = ? AND toDomainID = ?;")
        )

        guard let subFrameUnderTopFrameCount, let subresourceUnderTopFrameCount, let subresourceUniqueRedirectsTo else {
            releaseLogDatabaseError("isCorrectSubStatisticsCount: failed to prepare statement")
            return false
        }

        guard subFrameUnderTopFrameCount.bindInt(1, domainIDForBinding(subframeDomain)) == SQLITE_OK,
            subFrameUnderTopFrameCount.bindInt(2, domainIDForBinding(topFrameDomain)) == SQLITE_OK,
            subresourceUnderTopFrameCount.bindInt(1, domainIDForBinding(subframeDomain)) == SQLITE_OK,
            subresourceUnderTopFrameCount.bindInt(2, domainIDForBinding(topFrameDomain)) == SQLITE_OK,
            subresourceUniqueRedirectsTo.bindInt(1, domainIDForBinding(subframeDomain)) == SQLITE_OK,
            subresourceUniqueRedirectsTo.bindInt(2, domainIDForBinding(topFrameDomain)) == SQLITE_OK
        else {
            releaseLogDatabaseError("isCorrectSubStatisticsCount: failed to bind parameters")
            return false
        }

        guard subFrameUnderTopFrameCount.step() == SQLITE_ROW,
            subresourceUnderTopFrameCount.step() == SQLITE_ROW,
            subresourceUniqueRedirectsTo.step() == SQLITE_ROW
        else {
            releaseLogDatabaseError("isCorrectSubStatisticsCount: failed to step statement")
            return false
        }

        return subFrameUnderTopFrameCount.columnInt(0) == 1 && subresourceUnderTopFrameCount.columnInt(0) == 1
            && subresourceUniqueRedirectsTo.columnInt(0) == 1
    }

    // The domain's ID as a bind value: a domain missing from ObservedDomains traps.
    private func domainIDForBinding(_ domain: WebCore.RegistrableDomain) -> Int32 {
        guard let id = existingDomainID(domain) else {
            fatalError()
        }
        return Int32(truncatingIfNeeded: id)
    }

    private func appendSubStatisticList(
        _ builder: inout WTF.StringBuilder,
        _ pieces: DumpPieces,
        _ table: SubStatisticTable,
        _ statement: borrowing SQLStatement?,
        _ domain: WTF.String
    ) {
        guard pieces.tableQueries[table.rawValue] != nil else {
            return
        }

        switch statement {
        case .none:
            releaseLogDatabaseError("appendSubStatisticList: failed to bind parameter")
        case .some(let data):
            appendSubStatisticRows(&builder, pieces, table, data, domain)
        }
    }

    private func appendSubStatisticRows(
        _ builder: inout WTF.StringBuilder,
        _ pieces: DumpPieces,
        _ table: SubStatisticTable,
        _ data: borrowing SQLStatement,
        _ domain: WTF.String
    ) {
        // The statement is the dump's, used once per domain: reset it before binding this domain.
        _ = data.reset()
        guard data.bindInt(1, domainIDForBinding(Self.registrableDomainFromHost(domain))) == SQLITE_OK else {
            releaseLogDatabaseError("appendSubStatisticList: failed to bind parameter")
            return
        }

        if data.step() != SQLITE_ROW {
            return
        }

        builder.append(pieces.tableHeaders[table.rawValue])

        repeat {
            builder.append(pieces.entryIndent)
            builder.append(domainString(UInt32(truncatingIfNeeded: data.columnInt(0))))
            builder.append(pieces.newline)
        } while data.step() == SQLITE_ROW
    }

    private func resourceToString(
        _ builder: inout WTF.StringBuilder,
        _ pieces: DumpPieces,
        _ statements: borrowing DumpStatements,
        _ domain: WTF.String
    ) {
        guard let statement = scopedStatement(.getResourceDataByDomainName, "resourceToString"),
            statement.bindText(1, domain) == SQLITE_OK,
            statement.step() == SQLITE_ROW
        else {
            releaseLogDatabaseError("resourceToString: failed to step statement")
            return
        }

        builder.append(pieces.registrableDomain)
        builder.append(domain)
        builder.append(pieces.newline)

        // User interaction
        builder.append(pieces.hadUserInteraction)
        builder.append(pieces.boolean(statement.columnInt(ObservedDomainsColumn.HadUserInteraction.rawValue) != 0))
        builder.append(pieces.newline)
        builder.append(pieces.mostRecentUserInteraction)
        if hasHadRecentUserInteraction(statement.columnDouble(ObservedDomainsColumn.MostRecentUserInteractionTime.rawValue), nowTime()) {
            builder.append(pieces.withinDay)
        } else {
            builder.append(pieces.noRecentInteraction)
        }
        builder.append(pieces.newline)
        builder.append(pieces.grandfathered)
        builder.append(pieces.boolean(statement.columnInt(ObservedDomainsColumn.Grandfathered.rawValue) != 0))
        builder.append(pieces.newline)

        // Storage access
        appendSubStatisticList(&builder, pieces, .storageAccessUnderTopFrameDomains, statements.storageAccessUnderTopFrameDomains, domain)

        // Top frame stats
        appendSubStatisticList(&builder, pieces, .topFrameUniqueRedirectsTo, statements.topFrameUniqueRedirectsTo, domain)
        appendSubStatisticList(&builder, pieces, .topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement, nil, domain)
        appendSubStatisticList(&builder, pieces, .topFrameUniqueRedirectsFrom, statements.topFrameUniqueRedirectsFrom, domain)
        appendSubStatisticList(&builder, pieces, .topFrameLinkDecorationsFrom, statements.topFrameLinkDecorationsFrom, domain)
        appendSubStatisticList(&builder, pieces, .topFrameLoadedThirdPartyScripts, statements.topFrameLoadedThirdPartyScripts, domain)

        let dataRemovalFrequencyValue = statement.columnInt(ObservedDomainsColumn.IsScheduledForAllButCookieDataRemoval.rawValue)
        builder.append(pieces.dataRemovalFrequency)
        builder.append(pieces.dataRemovalFrequencyText(toDataRemovalFrequency(dataRemovalFrequencyValue)))
        builder.append(pieces.newline)

        // Subframe stats
        appendSubStatisticList(&builder, pieces, .subframeUnderTopFrameDomains, statements.subframeUnderTopFrameDomains, domain)

        // Subresource stats
        appendSubStatisticList(&builder, pieces, .subresourceUnderTopFrameDomains, statements.subresourceUnderTopFrameDomains, domain)
        appendSubStatisticList(&builder, pieces, .subresourceUniqueRedirectsTo, statements.subresourceUniqueRedirectsTo, domain)
        appendSubStatisticList(&builder, pieces, .subresourceUniqueRedirectsFrom, statements.subresourceUniqueRedirectsFrom, domain)

        // Prevalent Resource
        builder.append(pieces.isPrevalentResource)
        builder.append(pieces.boolean(statement.columnInt(ObservedDomainsColumn.IsPrevalent.rawValue) != 0))
        builder.append(pieces.newline)
        builder.append(pieces.isVeryPrevalentResource)
        builder.append(pieces.boolean(statement.columnInt(ObservedDomainsColumn.IsVeryPrevalent.rawValue) != 0))
        builder.append(pieces.newline)
        builder.append(pieces.dataRecordsRemoved)
        builder.append(WTF.String.number(statement.columnInt(ObservedDomainsColumn.DataRecordsRemoved.rawValue)))
        builder.append(pieces.newline)
    }

    @cxx
    @implementation
    func dumpResourceLoadStatisticsText() -> WTF.String {
        var domains: [(text: Swift.String, domain: WTF.String)] = []
        do {
            guard let statement = scopedStatement(.getAllDomains, "dumpResourceLoadStatistics") else {
                return WTF.String()
            }
            while statement.step() == SQLITE_ROW {
                let domain = statement.columnText(0)
                domains.append((text: domain.description, domain: domain))
            }
        }
        // WTF::codePointCompareLessThan: by code unit.
        domains.sort { $0.text.utf16.lexicographicallyPrecedes($1.text.utf16) }

        let pieces = DumpPieces()
        var builder = WTF.StringBuilder()
        builder.append(pieces.header)
        do {
            let statements = DumpStatements(database, pieces)
            for entry in domains {
                resourceToString(&builder, pieces, statements, entry.domain)
            }
        }

        let thirdPartyData = aggregatedThirdPartyData()
        if !thirdPartyData.isEmpty() {
            builder.append(pieces.thirdPartyHeader)
            for index in 0..<thirdPartyData.size() {
                builder.append(thirdPartyData[index].toString())
                builder.append(pieces.newline)
            }
        }
        return Self.stringFromBuilder(&builder)
    }
}

// MARK: Operating dates, statistic expiry and the schema's index count

private let operatingDatesWindowLong: UInt32 = 30 // days
private let operatingDatesWindowShort: UInt32 = 7 // days
private let operatingTimeWindowForLiveOnTesting: Double = 3600 // seconds
private let secondsPerDay: Double = 3600 * 24

// One window's row of OperatingDates, for updateOperatingDatesParameters.
private enum OperatingDatesWindowRow {
    case notEnoughDates
    case date(WebKit.OperatingDate)
    case failed
}

private func isEarlier(_ date: WebKit.OperatingDate, than other: WebKit.OperatingDate) -> Bool {
    // OperatingDate's operator<=> compares secondsSinceEpoch().
    date.secondsSinceEpoch().value() < other.secondsSinceEpoch().value()
}

extension WebKit.ResourceLoadStatisticsStore {
    @cxx
    @implementation
    func missingUniqueIndices() -> Bool {
        guard let statement = database.prepareStatement(WTF.String("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'")) else {
            releaseLogDatabaseError("missingUniqueIndices: failed to prepare statement")
            return false
        }

        guard statement.step() == SQLITE_ROW else {
            releaseLogDatabaseError("missingUniqueIndices: failed to step statement")
            return false
        }

        return statement.columnInt(0) < Self.expectedIndexCount()
    }

    private func operatingDatesWindowRow(_ statement: borrowing SQLStatement, _ window: UInt32) -> OperatingDatesWindowRow {
        if m_operatingDatesSize <= window &- 1 {
            return .notEnoughDates
        }
        _ = statement.reset()
        guard statement.bindInt(1, Int32(truncatingIfNeeded: window &- 1)) == SQLITE_OK, statement.step() == SQLITE_ROW else {
            releaseLogDatabaseError("updateOperatingDatesParameters: failed to step getOperatingDateWindowStatement")
            return .failed
        }
        let memberOperatingDate = WebKit.OperatingDate(statement.columnInt(0), statement.columnInt(1), statement.columnInt(2))
        WebKit.LogChannel.ResourceLoadStatistics().releaseLog
            .log(
                """
                ResourceLoadStatisticsStore::updateOperatingDatesParameters: sessionID=\(self.m_sessionID.toUInt64()), \
                memberOperatingDate: \(memberOperatingDate.secondsSinceEpoch().value())
                """
            )
        return .date(memberOperatingDate)
    }

    private func updateOperatingDatesParameters() {
        let countOperatingDatesStatement = database.prepareStatement(WTF.String("SELECT COUNT(*) FROM OperatingDates;"))
        let getMostRecentOperatingDateStatement = database.prepareStatement(
            WTF.String("SELECT * FROM OperatingDates ORDER BY year DESC, month DESC, monthDay DESC LIMIT 1;")
        )
        let getOperatingDateWindowStatement = database.prepareStatement(
            WTF.String("SELECT * FROM OperatingDates ORDER BY year DESC, month DESC, monthDay DESC LIMIT 1 OFFSET ?;")
        )

        guard let countOperatingDatesStatement, countOperatingDatesStatement.step() == SQLITE_ROW else {
            releaseLogDatabaseError("updateOperatingDatesParameters: failed to step countOperatingDatesStatement")
            return
        }

        m_operatingDatesSize = UInt32(truncatingIfNeeded: countOperatingDatesStatement.columnInt(0))

        guard let getMostRecentOperatingDateStatement, getMostRecentOperatingDateStatement.step() == SQLITE_ROW else {
            releaseLogDatabaseError("updateOperatingDatesParameters: failed to step getMostRecentOperatingDateStatement")
            return
        }
        m_mostRecentOperatingDate = WebKit.OperatingDate(
            getMostRecentOperatingDateStatement.columnInt(0),
            getMostRecentOperatingDateStatement.columnInt(1),
            getMostRecentOperatingDateStatement.columnInt(2)
        )

        guard let getOperatingDateWindowStatement else {
            releaseLogDatabaseError("updateOperatingDatesParameters: failed to prepare getOperatingDateWindowStatement")
            return
        }

        // A failed window keeps its date, and the other window is still updated.
        switch operatingDatesWindowRow(getOperatingDateWindowStatement, operatingDatesWindowShort) {
        case .notEnoughDates:
            m_shortWindowOperatingDate = .init()
        case .date(let date):
            m_shortWindowOperatingDate = .init(date)
        case .failed:
            break
        }
        switch operatingDatesWindowRow(getOperatingDateWindowStatement, operatingDatesWindowLong) {
        case .notEnoughDates:
            m_longWindowOperatingDate = .init()
        case .date(let date):
            m_longWindowOperatingDate = .init(date)
        case .failed:
            break
        }
    }

    @cxx
    @implementation
    func includeTodayAsOperatingDateIfNecessary() {
        assert(!WTF.RunLoop.isMain())
        WebKit.LogChannel.ResourceLoadStatistics().releaseLog
            .log("ResourceLoadStatisticsStore::includeTodayAsOperatingDateIfNecessary: sessionID=\(self.m_sessionID.toUInt64())")

        let today = WebKit.OperatingDate.today(m_timeAdvanceForTesting)
        if m_operatingDatesSize > 0 && !isEarlier(m_mostRecentOperatingDate, than: today) {
            return
        }

        withTransaction {
            let rowsToPrune = Int32(truncatingIfNeeded: m_operatingDatesSize &- operatingDatesWindowLong &+ 1)
            if rowsToPrune > 0 {
                guard
                    let deleteLeastRecentOperatingDateStatement = database.prepareStatement(
                        WTF.String("DELETE FROM OperatingDates ORDER BY year, month, monthDay LIMIT ?;")
                    ),
                    deleteLeastRecentOperatingDateStatement.bindInt(1, rowsToPrune) == SQLITE_OK,
                    deleteLeastRecentOperatingDateStatement.step() == SQLITE_DONE
                else {
                    releaseLogDatabaseError(
                        "includeTodayAsOperatingDateIfNecessary: failed to step deleteLeastRecentOperatingDateStatement"
                    )
                    return
                }
            }

            guard insertOperatingDate(today) else {
                releaseLogDatabaseError("includeTodayAsOperatingDateIfNecessary: failed to step insertOperatingDateStatement")
                return
            }

            updateOperatingDatesParameters()
        }
    }

    private func insertOperatingDate(_ date: WebKit.OperatingDate) -> Bool {
        guard
            let insertOperatingDateStatement = database.prepareStatement(
                WTF.String("INSERT OR IGNORE INTO OperatingDates (year, month, monthDay) SELECT ?, ?, ?;")
            ),
            insertOperatingDateStatement.bindInt(1, date.year()) == SQLITE_OK,
            insertOperatingDateStatement.bindInt(2, date.month()) == SQLITE_OK,
            insertOperatingDateStatement.bindInt(3, date.monthDay()) == SQLITE_OK,
            insertOperatingDateStatement.step() == SQLITE_DONE
        else {
            return false
        }
        _ = insertOperatingDateStatement.reset()
        return true
    }

    @cxx
    @implementation
    func setTimeAdvanceForTesting(_ time: WTF.Seconds) {
        assert(!WTF.RunLoop.isMain())
        var advance = m_timeAdvanceForTesting.value()
        while advance <= time.value() {
            m_timeAdvanceForTesting = WTF.Seconds(advance)
            includeTodayAsOperatingDateIfNecessary()
            advance += secondsPerDay
        }
    }

    private func hasStatisticsExpired(
        _ mostRecentUserInteractionTime: WTF.WallTime,
        _ operatingDatesWindow: WebKit.OperatingDatesWindow
    ) -> Bool {
        assert(!WTF.RunLoop.isMain())

        let interactionTime = mostRecentUserInteractionTime.secondsSinceEpoch().value()
        switch operatingDatesWindow {
        case .Long:
            if let longWindowOperatingDate = Optional(fromCxx: m_longWindowOperatingDate),
                isEarlier(WebKit.OperatingDate.fromWallTime(mostRecentUserInteractionTime), than: longWindowOperatingDate)
            {
                return true
            }
        case .Short:
            if let shortWindowOperatingDate = Optional(fromCxx: m_shortWindowOperatingDate),
                isEarlier(WebKit.OperatingDate.fromWallTime(mostRecentUserInteractionTime), than: shortWindowOperatingDate)
            {
                return true
            }
        case .ForLiveOnTesting:
            return nowTime() > interactionTime + operatingTimeWindowForLiveOnTesting
        case .ForReproTesting:
            return true
        default:
            break
        }

        // If we don't meet the real criteria for an expired statistic, check the user setting for a tighter restriction
        // (mainly for testing).
        if let timeToLiveUserInteraction = Optional(fromCxx: m_parameters.timeToLiveUserInteraction) {
            if nowTime() > interactionTime + timeToLiveUserInteraction.value() {
                return true
            }
        }
        return false
    }

    @cxx
    @implementation
    func insertExpiredStatisticForTesting(
        _ domain: WebCore.RegistrableDomain,
        _ numberOfOperatingDaysPassed: UInt32,
        _ hasUserInteraction: Bool,
        _ isScheduledForAllButCookieDataRemoval: Bool,
        _ isPrevalent: Bool
    ) {
        // Populate the Operating Dates table with enough days to require pruning.
        var daysAgoInSeconds: Double = 0

        withTransaction {
            var day: UInt32 = 1
            while day <= numberOfOperatingDaysPassed {
                let daysToSubtract = Double(24 &* day) * 3600
                daysAgoInSeconds = nowTime() - daysToSubtract
                let dateToInsert = WebKit.OperatingDate.fromWallTime(WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(daysAgoInSeconds)))

                guard insertOperatingDate(dateToInsert) else {
                    releaseLogDatabaseError("insertExpiredStatisticForTesting: failed to step insertOperatingDateStatement")
                    return
                }
                day &+= 1
            }

            updateOperatingDatesParameters()

            // Make sure mostRecentUserInteractionTime is the least recent of all entries.
            daysAgoInSeconds -= secondsPerDay
            guard let statement = scopedStatement(.insertObservedDomain, "insertExpiredStatisticForTesting"),
                statement.bindText(ObservedDomainsColumn.RegistrableDomain.rawValue, Self.string(domain)) == SQLITE_OK,
                statement.bindDouble(ObservedDomainsColumn.LastSeen.rawValue, daysAgoInSeconds) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.HadUserInteraction.rawValue, hasUserInteraction ? 1 : 0) == SQLITE_OK,
                statement.bindDouble(ObservedDomainsColumn.MostRecentUserInteractionTime.rawValue, daysAgoInSeconds) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.Grandfathered.rawValue, 0) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.IsPrevalent.rawValue, isPrevalent ? 1 : 0) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.IsVeryPrevalent.rawValue, 0) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.DataRecordsRemoved.rawValue, 0) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.TimesAccessedAsFirstPartyDueToUserInteraction.rawValue, 0) == SQLITE_OK,
                statement.bindInt(ObservedDomainsColumn.TimesAccessedAsFirstPartyDueToStorageAccessAPI.rawValue, 0) == SQLITE_OK,
                statement.bindInt(
                    ObservedDomainsColumn.IsScheduledForAllButCookieDataRemoval.rawValue,
                    isScheduledForAllButCookieDataRemoval ? 1 : 0
                ) == SQLITE_OK,
                statement.bindDouble(ObservedDomainsColumn.MostRecentWebPushInteractionTime.rawValue, 0.0) == SQLITE_OK
            else {
                releaseLogDatabaseError("insertExpiredStatisticForTesting: failed to step scopedInsertObservedDomainStatement")
                return
            }

            if statement.step() != SQLITE_DONE {
                releaseLogDatabaseError("insertExpiredStatisticForTesting: failed to step statement")
            }
        }
    }
}

// MARK: Completion handlers

#if compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN

// The function objects the store's members are called with on the statistics actor (WebResourceLoadStatisticsStore.h),
// so that Swift can build them from closures. `CxxCompletionHandler` also gives each one a continuation initializer
// whose `Argument: Sendable` bound is only a warning for a C++ type: for an argument that is not `Sendable` it would
// carry the actor's value to the continuation's thread. Those conformances declare an `@unsafe` initializer of the same
// shape, which overload resolution prefers, so that such a call does not compile without `unsafe`.

extension WebKit.StorageAccessStatusCompletionHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebKit.StorageAccessStatus
}

extension WebKit.StorageAccessWasGrantedCompletionHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebCore.StorageAccessWasGranted
}

extension WebKit.StatisticsStringCompletionHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WTF.String

    /// Do not use: a `WTF.String` made on the statistics actor would reach the continuation's thread, and its reference
    /// count is not atomic.
    @unsafe
    init(_ continuation: CheckedContinuation<WTF.String, some Error>) {
        preconditionFailure("A WTF.String must not cross threads")
    }
}

#endif // compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN

// MARK: Main posts and round trips, on the statistics actor

/// A completion run once every holder has let go of it: `CallbackAggregator`, on the statistics actor.
private final class StatisticsCallbackAggregator {
    private let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    deinit {
        completion()
    }
}

/// The store's members that post to main or wait on main, run on the statistics actor. Each main part goes through the
/// actor after the posts made before it, and each second part runs there with the store, or with none when the store
/// is gone.
extension WebKit.ResourceLoadStatisticsStore {
    private var actorSessionID: UInt64 {
        m_sessionID.toUInt64()
    }

    private static func cxxDomains(_ domains: [StatisticsDomain]) -> WebKit.RegistrableDomainVector {
        var vector = WebKit.RegistrableDomainVector()
        for domain in domains {
            vector.append(consuming: domain.cxxDomain)
        }
        return vector
    }

    /// A C++ caller's domain list (WebResourceLoadStatisticsStore::registrableDomains() and its siblings).
    func answer(_ query: StatisticsDomainListRequest, on actor: isolated StatisticsActor) -> StatisticsDomainList {
        assert(!WTF.RunLoop.isMain())
        var domains = WebKit.RegistrableDomainVector()
        var times = WebKit.StatisticsTimeVector()
        var hasValue = true
        switch query {
        case .allDomains:
            domains = allDomains()
        case .allDomainsWithLastAccessedTime:
            domainsWithLastAccessedTimeForSwift(&domains, &times)
        case .domainsExemptFromWebsiteDataDeletion:
            domains = domainsExemptFromWebsiteDataDeletionForSwift()
        case .websitesWithUserInteraction:
            hasValue = websitesWithUserInteractionForSwift(&domains, &times)
        }
        return StatisticsDomainList(
            hasValue: hasValue,
            domains: StatisticsDomain.list(domains),
            times: (0..<times.size()).map { times[$0] }
        )
    }

    /// A C++ caller's request whose work completes later; `completion` runs on the actor when it does.
    func run(
        _ request: StatisticsCompletingRequest,
        on actor: isolated StatisticsActor,
        currentStore: @escaping () -> WebKit.ResourceLoadStatisticsStore?,
        then completion: @escaping () -> Void
    ) {
        assert(!WTF.RunLoop.isMain())
        switch request {
        case .populateMemoryStoreFromDisk:
            if isNewResourceLoadStatisticsDatabaseFile() {
                grandfatherExistingWebsiteData(on: actor) { _ in completion() }
                setIsNewResourceLoadStatisticsDatabaseFile(false)
            } else {
                logTestingEvent("PopulatedWithoutGrandfathering", on: actor)
                completion()
            }
        case .clearInMemoryAndPersistent(let shouldGrandfather):
            let callbackAggregator = StatisticsCallbackAggregator(completion)
            clear(on: actor) {
                guard shouldGrandfather else {
                    _ = callbackAggregator
                    return
                }
                guard let store = currentStore() else {
                    Self.releaseLogClear("After being cleared, m_statisticsStore is null when trying to grandfather data.")
                    _ = callbackAggregator
                    return
                }
                store.grandfatherExistingWebsiteData(on: actor) { _ in _ = callbackAggregator }
                store.setIsNewResourceLoadStatisticsDatabaseFile(true)
            }
            cancelPendingStatisticsProcessingRequest()
        }
    }

    private static func releaseLogClear(_ message: Swift.String) {
        WebKit.LogChannel.ResourceLoadStatistics().releaseLog
            .log("WebResourceLoadStatisticsStore::scheduleClearInMemoryAndPersistent \(message, privacy: .public)")
    }

    /// The statistics processing the delayed request runs, once it is known to be the store's pending one.
    func processStatisticsRequest(on actor: isolated StatisticsActor) {
        updateCookieBlocking(on: actor) {}
        processStatisticsAndDataRecords(on: actor) {}
    }

    func updateCookieBlocking(on actor: isolated StatisticsActor, then completion: @escaping () -> Void) {
        assert(!WTF.RunLoop.isMain())

        let domainsToBlock = domainsToBlockCookiesFor()
        if domainsToBlock.isEmpty() {
            completion()
            return
        }
        let domains = StatisticsDomainsToBlockCookiesFor(statistics: domainsToBlock)
        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in mainSide.updateCookieBlocking(domains, inbox, id, generation) },
            then: { store, _ in
                completion()
                store?.logCookieBlockingDoneForSwift()
            }
        )
    }

    func updateCookieBlockingForDomains(
        _ domainsToBlock: borrowing WebKit.RegistrableDomainsToBlockCookiesFor,
        on actor: isolated StatisticsActor,
        then completion: @escaping () -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        let domains = StatisticsDomainsToBlockCookiesFor(statistics: domainsToBlock)
        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in mainSide.updateCookieBlocking(domains, inbox, id, generation) },
            then: { _, _ in
                completion()
            }
        )
    }

    /// Removes the website data of the domains the store classified, then counts the removals; `completion` gets the
    /// store, or nil when it went away meanwhile.
    func removeDataRecords(
        on actor: isolated StatisticsActor,
        then completion: @escaping (WebKit.ResourceLoadStatisticsStore?) -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        if !shouldRemoveDataRecords() {
            completion(self)
            return
        }

        let domainsToDeleteOrRestrictWebsiteDataFor = registrableDomainsToDeleteOrRestrictWebsiteDataFor()
        if domainsToDeleteOrRestrictWebsiteDataFor.isEmpty() {
            completion(self)
            return
        }

        if m_debugLoggingEnabled {
            logAboutToRemoveDataRecordsForSwift(domainsToDeleteOrRestrictWebsiteDataFor)
        }

        setDataRecordsBeingRemoved(true)

        let domains = StatisticsDomainsToDeleteOrRestrictWebsiteDataFor(statistics: domainsToDeleteOrRestrictWebsiteDataFor)
        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in
                mainSide.deleteAndRestrictWebsiteData(domains, inbox, id, generation)
            },
            then: { store, outcome in
                guard let store else {
                    completion(nil)
                    return
                }
                store.incrementRecordsDeletedCountForDomainsForSwift(consuming: Self.cxxDomains(outcome.domains))
                store.setDataRecordsBeingRemoved(false)

                var waiters = store.takeDataRecordRemovalWaitersForSwift()
                completion(store)
                waiters.run(store)

                if store.m_debugLoggingEnabled {
                    store.debugModeReleaseLog("Done removing data records.")
                    store.debugBroadcastConsoleMessage(.ITPDebug, .Info, WTF.String("[ITP] Done removing data records"))
                }
            }
        )
    }

    func processStatisticsAndDataRecords(on actor: isolated StatisticsActor, then completion: @escaping () -> Void) {
        assert(!WTF.RunLoop.isMain())

        if m_parameters.shouldClassifyResourcesBeforeDataRecordsRemoval {
            classifyPrevalentResources()
        }

        removeDataRecords(on: actor) { store in
            guard let store else {
                completion()
                return
            }
            store.pruneStatisticsIfNeeded()
            store.logTestingEvent("Storage Synced", on: actor)
            completion()
        }
    }

    /// Marks the domains that have website data now as grandfathered; `completion` gets the store, or nil when it went
    /// away meanwhile.
    func grandfatherExistingWebsiteData(
        on actor: isolated StatisticsActor,
        then completion: @escaping (WebKit.ResourceLoadStatisticsStore?) -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in mainSide.registrableDomainsWithWebsiteData(inbox, id, generation) },
            then: { store, outcome in
                guard let store else {
                    completion(nil)
                    return
                }
                store.grandfatherDataForDomainsForSwift(consuming: Self.cxxDomains(outcome.domains))
                completion(store)
                store.logTestingEvent("Grandfathered", on: actor)
            }
        )
    }

    func logTestingEvent(_ event: Swift.String, on actor: isolated StatisticsActor) {
        assert(!WTF.RunLoop.isMain())

        actor.post(actorSessionID) { mainSide in mainSide.logTestingEvent(event) }
    }

    func updateClientSideCookiesAgeCap(on actor: isolated StatisticsActor) {
        assert(!WTF.RunLoop.isMain())

        let seconds = clientSideCookiesAgeCapForSwift().value()
        actor.post(actorSessionID) { mainSide in mainSide.setAgeCapForClientSideCookies(seconds) }
    }

    func removeAllStorageAccess(on actor: isolated StatisticsActor, then completion: @escaping () -> Void) {
        assert(!WTF.RunLoop.isMain())

        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in mainSide.removeAllStorageAccess(inbox, id, generation) },
            then: { _, _ in
                completion()
            }
        )
    }

    func didCreateNetworkProcess(on actor: isolated StatisticsActor) {
        assert(!WTF.RunLoop.isMain())

        updateCookieBlocking(on: actor) {}
        updateCacheMaxAgeCap()
        updateClientSideCookiesAgeCap(on: actor)
    }

    func clear(on actor: isolated StatisticsActor, then completion: @escaping () -> Void) {
        assert(!WTF.RunLoop.isMain())

        clearDatabaseContents()

        let callbackAggregator = StatisticsCallbackAggregator(completion)

        removeAllStorageAccess(on: actor) { _ = callbackAggregator }

        var domainsToBlock = WebKit.RegistrableDomainsToBlockCookiesFor()
        domainsToBlock.domainsToBlockAndDeleteCookiesFor = ensurePrevalentResourcesForDebugMode()
        updateCookieBlockingForDomains(domainsToBlock, on: actor) { _ = callbackAggregator }
    }

    func logUserInteraction(
        _ domain: WebCore.RegistrableDomain,
        on actor: isolated StatisticsActor,
        then completion: @escaping () -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            if !logUserInteractionRecord(domain) {
                completion()
                return
            }
            updateCookieBlocking(on: actor, then: completion)
        }
    }

    func clearUserInteraction(
        _ domain: WebCore.RegistrableDomain,
        on actor: isolated StatisticsActor,
        then completion: @escaping () -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            clearUserInteractionRecords(domain)

            // Update cookie blocking unconditionally since a call to hasHadUserInteraction() to check the previous user
            // interaction status could call clearUserInteraction(), blowing the call stack.
            updateCookieBlocking(on: actor, then: completion)
        }
    }
}

// MARK: Storage access, on the statistics actor

extension WebKit.ResourceLoadStatisticsStore {
    private func debugModeReleaseLogPrivate(_ message: Swift.String) {
        WebKit.LogChannel.ITPDebug().releaseLog.info("ResourceLoadStatisticsStore: \(message, privacy: .private)")
    }

    func hasStorageAccess(
        _ subFrameDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier?,
        _ webPageProxyID: UInt64,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        on actor: isolated StatisticsActor,
        then completion: @escaping (Bool) -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        let result = ensureResourceStatisticsForRegistrableDomain(subFrameDomain, WTF.String("hasStorageAccess"))
        if Optional(fromCxx: result.second) == nil {
            completion(false)
            return
        }

        let subFrame = StatisticsDomain(subFrameDomain)
        switch cookieAccess(subFrameDomain, topFrameDomain, canRequestStorageAccessWithoutUserInteraction) {
        case .CannotRequest:
            completion(false)
            return
        case .BasedOnCookiePolicy:
            actor.roundTrip(
                actorSessionID,
                mainPart: { mainSide, inbox, id, generation in mainSide.hasCookies(subFrame, inbox, id, generation) },
                then: { _, outcome in
                    completion(outcome.answer)
                }
            )
            return
        case .OnlyIfGranted:
            break
        @unknown default:
            break
        }

        // As the C++'s `frameID.value()`, which ends the process with no frame.
        guard let frameID else {
            preconditionFailure("hasStorageAccess: a grant-only check needs a frame")
        }
        let topFrame = StatisticsDomain(topFrameDomain)
        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in
                mainSide.hasStorageAccessForFrame(subFrame, topFrame, frameID, webPageProxyID, inbox, id, generation)
            },
            then: { _, outcome in
                completion(outcome.answer)
            }
        )
    }

    func requestStorageAccess(
        _ subFrameDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: UInt64,
        _ scope: IPCTypes.StorageAccessScope,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        on actor: isolated StatisticsActor,
        then completion: @escaping (WebKit.StorageAccessStatus) -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        let subFrameStatus = ensureResourceStatisticsForRegistrableDomain(subFrameDomain, WTF.String("requestStorageAccess"))
        guard let subFrameDomainID = Optional(fromCxx: subFrameStatus.second) else {
            completion(.CannotRequestAccess)
            return
        }

        let subFrame = Self.string(subFrameDomain).description
        let topFrame = Self.string(topFrameDomain).description
        switch cookieAccess(subFrameDomain, topFrameDomain, canRequestStorageAccessWithoutUserInteraction) {
        case .CannotRequest:
            if debugLoggingEnabled() {
                debugModeReleaseLogPrivate(
                    "Cannot grant storage access to \(subFrame) since its cookies are blocked in third-party contexts and it has not received user interaction as first-party."
                )
                debugBroadcastConsoleMessage(
                    .ITPDebug,
                    .Error,
                    WTF.String(
                        "[ITP] Cannot grant storage access to '" + subFrame
                            + "' since its cookies are blocked in third-party contexts and it has not received user interaction as first-party."
                    )
                )
            }
            completion(.CannotRequestAccess)
            return
        case .BasedOnCookiePolicy:
            if debugLoggingEnabled() {
                debugModeReleaseLogPrivate(
                    "No need to grant storage access to \(subFrame) since its cookies are not blocked in third-party contexts. Note that the underlying cookie policy may still block this third-party from setting cookies."
                )
                debugBroadcastConsoleMessage(
                    .ITPDebug,
                    .Info,
                    WTF.String(
                        "[ITP] No need to grant storage access to '" + subFrame
                            + "' since its cookies are not blocked in third-party contexts. Note that the underlying cookie policy may still block this third-party from setting cookies."
                    )
                )
            }
            completion(.HasAccess)
            return
        case .OnlyIfGranted:
            break
        @unknown default:
            break
        }

        guard hasUserGrantedStorageAccessThroughPrompt(subFrameDomainID, topFrameDomain) else {
            if debugLoggingEnabled() {
                debugModeReleaseLogPrivate(
                    "About to ask the user whether they want to grant storage access to \(subFrame) under \(topFrame) or not."
                )
                debugBroadcastConsoleMessage(
                    .ITPDebug,
                    .Info,
                    WTF.String(
                        "[ITP] About to ask the user whether they want to grant storage access to '" + subFrame + "' under '"
                            + topFrame + "' or not."
                    )
                )
            }
            completion(.RequiresUserPrompt)
            return
        }

        if debugLoggingEnabled() {
            debugModeReleaseLogPrivate("Storage access was granted to \(subFrame) under \(topFrame).")
            debugBroadcastConsoleMessage(
                .ITPDebug,
                .Info,
                WTF.String("[ITP] Storage access was granted to '" + subFrame + "' under '" + topFrame + "'.")
            )
        }

        withTransaction {
            guard
                let incrementStorageAccess = database.prepareStatement(
                    WTF.String(
                        "UPDATE ObservedDomains SET timesAccessedAsFirstPartyDueToStorageAccessAPI = timesAccessedAsFirstPartyDueToStorageAccessAPI + 1 WHERE domainID = ?"
                    )
                ),
                incrementStorageAccess.bindInt(1, Int32(truncatingIfNeeded: subFrameDomainID)) == SQLITE_OK,
                incrementStorageAccess.step() == SQLITE_DONE
            else {
                releaseLogDatabaseError("requestStorageAccess: failed to step statement")
                completion(.CannotRequestAccess)
                return
            }

            grantStorageAccessInternal(
                subFrameDomain,
                topFrameDomain,
                frameID,
                webPageProxyID,
                .Yes,
                scope,
                canRequestStorageAccessWithoutUserInteraction,
                on: actor
            ) { wasGranted in
                completion(wasGranted == .yes ? .HasAccess : .CannotRequestAccess)
            }
        }
    }

    func requestStorageAccessUnderOpener(
        _ domainInNeedOfStorageAccess: WebCore.RegistrableDomain,
        _ openerWebPageProxyID: UInt64,
        _ openerDomain: WebCore.RegistrableDomain,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        on actor: isolated StatisticsActor
    ) {
        assert(!WTF.RunLoop.isMain())

        assert(!(domainInNeedOfStorageAccess == openerDomain))
        if domainInNeedOfStorageAccess == openerDomain {
            return
        }

        let domainInNeed = Self.string(domainInNeedOfStorageAccess).description
        let opener = Self.string(openerDomain).description

        if debugLoggingEnabled() {
            debugModeReleaseLogPrivate(
                "[Temporary combatibility fix] Storage access was granted for \(domainInNeed) under opener page from \(opener), with user interaction in the opened window."
            )
            debugBroadcastConsoleMessage(
                .ITPDebug,
                .Info,
                WTF.String(
                    "[ITP] Storage access was granted for '" + domainInNeed + "' under opener page from '"
                        + opener + "', with user interaction in the opened window."
                )
            )
        }

        grantStorageAccessInternal(
            domainInNeedOfStorageAccess,
            openerDomain,
            nil,
            openerWebPageProxyID,
            .No,
            .perPage,
            canRequestStorageAccessWithoutUserInteraction,
            on: actor
        ) { _ in }
    }

    func grantStorageAccess(
        _ subFrameDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: UInt64,
        _ promptWasShown: WebCore.StorageAccessPromptWasShown,
        _ scope: IPCTypes.StorageAccessScope,
        on actor: isolated StatisticsActor,
        then completion: @escaping (IPCTypes.StorageAccessWasGranted) -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        withTransaction {
            let addGrant:
                (
                    WebKit.ResourceLoadStatisticsStore?, WebCore.RegistrableDomain, WebCore.RegistrableDomain,
                    WebKit.CanRequestStorageAccessWithoutUserInteraction, @escaping (IPCTypes.StorageAccessWasGranted) -> Void
                ) -> Void = { store, subFrameDomain, topFrameDomain, canRequest, completion in
                    guard let store else {
                        completion(.no)
                        return
                    }
                    if promptWasShown == .Yes {
                        let subFrameStatus = store.grantStorageAccessPermission(topFrameDomain, subFrameDomain)
                        if Optional(fromCxx: subFrameStatus.second) == nil {
                            completion(.no)
                            return
                        }
                        assert(subFrameStatus.first == .No)
                        assert(canRequest == .Yes || store.hasHadUserInteraction(subFrameDomain, .Long))
                    }
                    store.grantStorageAccessInternal(
                        subFrameDomain,
                        topFrameDomain,
                        frameID,
                        webPageProxyID,
                        promptWasShown,
                        scope,
                        canRequest,
                        on: actor,
                        then: completion
                    )
                }

            let subFrame = StatisticsDomain(subFrameDomain)
            let topFrame = StatisticsDomain(topFrameDomain)
            actor.roundTrip(
                actorSessionID,
                mainPart: { mainSide, inbox, id, generation in
                    mainSide.storageAccessQuirkGrants(subFrame, topFrame, inbox, id, generation)
                },
                then: { store, outcome in
                    guard let store else {
                        completion(.no)
                        return
                    }
                    let canRequestStorageAccessWithoutUserInteraction = outcome.canRequestWithoutUserInteraction
                    for pair in outcome.quirkGrants {
                        let quirkTopFrameDomain = pair.topFrame.cxxDomain
                        let quirkSubFrameDomain = pair.subFrame.cxxDomain
                        if quirkTopFrameDomain == topFrameDomain && quirkSubFrameDomain == subFrameDomain {
                            continue
                        }
                        addGrant(store, quirkSubFrameDomain, quirkTopFrameDomain, canRequestStorageAccessWithoutUserInteraction) { _ in }
                    }
                    addGrant(store, subFrameDomain, topFrameDomain, canRequestStorageAccessWithoutUserInteraction, completion)
                }
            )
        }
    }

    func grantStorageAccessInternal(
        _ subFrameDomain: WebCore.RegistrableDomain,
        _ topFrameDomain: WebCore.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier?,
        _ webPageProxyID: UInt64,
        _ promptWasShownNowOrEarlier: WebCore.StorageAccessPromptWasShown,
        _ scope: IPCTypes.StorageAccessScope,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        on actor: isolated StatisticsActor,
        then completion: @escaping (IPCTypes.StorageAccessWasGranted) -> Void
    ) {
        assert(!WTF.RunLoop.isMain())

        if subFrameDomain == topFrameDomain {
            completion(.yes)
            return
        }

        if promptWasShownNowOrEarlier == .Yes {
            let checked = withTransaction {
                guard
                    checkPromptedStorageAccessGrantForSwift(subFrameDomain, topFrameDomain, canRequestStorageAccessWithoutUserInteraction)
                else {
                    return false
                }
                setUserInteraction(subFrameDomain, true, WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(nowTime())))
                return true
            }
            // As the C++ in builds without NDEBUG: a domain with no record stops the grant, uncompleted.
            if !checked {
                return
            }
        }

        let subFrame = StatisticsDomain(subFrameDomain)
        let topFrame = StatisticsDomain(topFrameDomain)
        actor.roundTrip(
            actorSessionID,
            mainPart: { mainSide, inbox, id, generation in
                mainSide.grantStorageAccess(subFrame, topFrame, frameID, webPageProxyID, scope, inbox, id, generation)
            },
            then: { _, outcome in
                completion(outcome.wasGranted)
            }
        )
    }
}

// MARK: Messages, on the statistics actor

/// The store's side of the messages that only query or set its state.
extension WebKit.ResourceLoadStatisticsStore {
    func answer(_ query: StatisticsQueryRequest, on actor: isolated StatisticsActor) -> Bool {
        switch query {
        case .isPrevalentResource(let domain):
            return isPrevalentResource(.fromIPC(domain))
        case .isVeryPrevalentResource(let domain):
            return isVeryPrevalentResource(.fromIPC(domain))
        case .hasHadUserInteraction(let domain):
            return hasHadUserInteraction(.fromIPC(domain), .Long)
        case .isGrandfathered(let domain):
            return isGrandfathered(.fromIPC(domain))
        case .isRelationshipOnlyInDatabaseOnce(let subDomain, let topDomain):
            return isCorrectSubStatisticsCount(.fromIPC(subDomain), .fromIPC(topDomain))
        case .isRegisteredAsSubresourceUnder(let subresourceDomain, let topFrameDomain):
            return isRegisteredAsSubresourceUnder(.fromIPC(subresourceDomain), .fromIPC(topFrameDomain))
        case .isRegisteredAsSubFrameUnder(let subFrameDomain, let topFrameDomain):
            return isRegisteredAsSubFrameUnder(.fromIPC(subFrameDomain), .fromIPC(topFrameDomain))
        case .isRegisteredAsRedirectingTo(let domainRedirectedFrom, let domainRedirectedTo):
            return isRegisteredAsRedirectingTo(.fromIPC(domainRedirectedFrom), .fromIPC(domainRedirectedTo))
        case .domainIDExistsInDatabase(let domainID):
            return domainIDExistsInDatabase(domainID)
        case .databaseHasAllTables:
            return !checkForMissingTablesInSchema().hasValue
        }
    }

    func perform(_ command: StatisticsCommandRequest, on actor: isolated StatisticsActor) {
        switch command {
        case .logFrameNavigation(
            let targetDomain,
            let topFrameDomain,
            let sourceDomain,
            let isRedirect,
            let isMainFrame,
            let delayAfterMainFrameDocumentLoad,
            let wasPotentiallyInitiatedByUser
        ):
            logFrameNavigation(
                .fromIPC(targetDomain),
                .fromIPC(topFrameDomain),
                .fromIPC(sourceDomain),
                isRedirect,
                isMainFrame,
                WTF.Seconds(delayAfterMainFrameDocumentLoad),
                wasPotentiallyInitiatedByUser
            )
        case .setLastSeen(let domain, let seconds):
            setLastSeen(.fromIPC(domain), WTF.Seconds(seconds))
        case .setPrevalentResource(let domain):
            setPrevalentResource(.fromIPC(domain))
        case .setVeryPrevalentResource(let domain):
            setVeryPrevalentResource(.fromIPC(domain))
        case .clearPrevalentResource(let domain):
            clearPrevalentResource(.fromIPC(domain))
        case .setGrandfathered(let domain, let value):
            setGrandfathered(.fromIPC(domain), value)
        case .setSubframeUnderTopFrameDomain(let subFrameDomain, let topFrameDomain):
            setSubframeUnderTopFrameDomain(.fromIPC(subFrameDomain), .fromIPC(topFrameDomain))
        case .setSubresourceUnderTopFrameDomain(let subresourceDomain, let topFrameDomain):
            setSubresourceUnderTopFrameDomain(.fromIPC(subresourceDomain), .fromIPC(topFrameDomain))
        case .setSubresourceUniqueRedirectTo(let subresourceDomain, let domainRedirectedTo):
            setSubresourceUniqueRedirectTo(.fromIPC(subresourceDomain), .fromIPC(domainRedirectedTo))
        case .setSubresourceUniqueRedirectFrom(let subresourceDomain, let domainRedirectedFrom):
            setSubresourceUniqueRedirectFrom(.fromIPC(subresourceDomain), .fromIPC(domainRedirectedFrom))
        case .setTopFrameUniqueRedirectTo(let topFrameDomain, let domainRedirectedTo):
            setTopFrameUniqueRedirectTo(.fromIPC(topFrameDomain), .fromIPC(domainRedirectedTo))
        case .setTopFrameUniqueRedirectFrom(let topFrameDomain, let domainRedirectedFrom):
            setTopFrameUniqueRedirectFrom(.fromIPC(topFrameDomain), .fromIPC(domainRedirectedFrom))
        case .resetParametersToDefaultValues:
            resetParametersToDefaultValues()
        case .setTimeAdvanceForTesting(let time):
            setTimeAdvanceForTesting(WTF.Seconds(time))
        case .setIsRunningTest(let value):
            setIsRunningTest(value)
        case .mergeStatisticForTesting(
            let domain,
            let topFrameDomain1,
            let topFrameDomain2,
            let lastSeen,
            let hadUserInteraction,
            let mostRecentUserInteraction,
            let isGrandfathered,
            let isPrevalent,
            let isVeryPrevalent,
            let dataRecordsRemoved
        ):
            mergeStatisticForTesting(
                .fromIPC(domain),
                .fromIPC(topFrameDomain1),
                .fromIPC(topFrameDomain2),
                WTF.Seconds(lastSeen),
                hadUserInteraction,
                WTF.Seconds(mostRecentUserInteraction),
                isGrandfathered,
                isPrevalent,
                isVeryPrevalent,
                UInt32(truncatingIfNeeded: dataRecordsRemoved)
            )
        case .insertExpiredStatisticForTesting(
            let domain,
            let numberOfOperatingDaysPassed,
            let hadUserInteraction,
            let isScheduledForAllButCookieDataRemoval,
            let isPrevalent
        ):
            insertExpiredStatisticForTesting(
                .fromIPC(domain),
                UInt32(truncatingIfNeeded: numberOfOperatingDaysPassed),
                hadUserInteraction,
                isScheduledForAllButCookieDataRemoval,
                isPrevalent
            )
        case .setGrandfatheringTime(let seconds):
            setGrandfatheringTime(WTF.Seconds(seconds))
        case .setMaxStatisticsEntries(let maximumEntryCount):
            setMaxStatisticsEntries(Int(truncatingIfNeeded: maximumEntryCount))
        case .setMinimumTimeBetweenDataRecordsRemoval(let seconds):
            setMinimumTimeBetweenDataRecordsRemoval(WTF.Seconds(seconds))
        case .setPruneEntriesDownTo(let pruneTargetCount):
            setPruneEntriesDownTo(Int(truncatingIfNeeded: pruneTargetCount))
        case .setTimeToLiveUserInteraction(let seconds):
            setTimeToLiveUserInteraction(WTF.Seconds(seconds))
        case .setShouldClassifyResourcesBeforeDataRecordsRemoval(let value):
            setShouldClassifyResourcesBeforeDataRecordsRemoval(value)
        case .requestStorageAccessUnderOpener(let domainInNeedOfStorageAccess, let openerPage, let openerDomain, let canRequest):
            requestStorageAccessUnderOpener(
                .fromIPC(domainInNeedOfStorageAccess),
                openerPage,
                .fromIPC(openerDomain),
                canRequest,
                on: actor
            )
        case .setResourceLoadStatisticsDebugMode(let value):
            setResourceLoadStatisticsDebugMode(value)
        case .setPrevalentResourceForDebugMode(let domain):
            setPrevalentResourceForDebugMode(domain.cxxDomain)
        case .setThirdPartyCookieBlockingMode(let mode):
            setThirdPartyCookieBlockingMode(mode)
        case .setSameSiteStrictEnforcementEnabled(let enabled):
            setSameSiteStrictEnforcementEnabled(enabled)
        case .setFirstPartyWebsiteDataRemovalMode(let mode):
            setFirstPartyWebsiteDataRemovalMode(mode)
            if mode == .AllButCookiesReproTestingTimeout {
                setIsRunningTest(true)
            }
        case .setStandaloneApplicationDomain(let domain):
            setStandaloneApplicationDomain(consuming: domain.cxxDomain)
        case .performDailyTasks:
            includeTodayAsOperatingDateIfNecessary()
            runIncrementalVacuumCommand()
        case .logCrossSiteLoadWithLinkDecoration(let fromDomain, let toDomain, let didFilterKnownLinkDecoration):
            logCrossSiteLoadWithLinkDecoration(fromDomain.cxxDomain, toDomain.cxxDomain, didFilterKnownLinkDecoration ? .Yes : .No)
        case .setMostRecentWebPushInteractionTime(let domain):
            setMostRecentWebPushInteractionTime(domain.cxxDomain)
        case .removeDataForDomain(let domain):
            removeDataForDomain(domain.cxxDomain)
        case .setPersistedDomains(let domains):
            setPersistedDomainsForSwift(consuming: Self.cxxDomains(domains))
        #if ENABLE_APP_BOUND_DOMAINS
        case .setAppBoundStatisticsDomains(let domains):
            setAppBoundDomainsForSwift(consuming: Self.cxxDomains(domains))
        #endif
        #if ENABLE_MANAGED_DOMAINS
        case .setManagedStatisticsDomains(let domains):
            setManagedDomainsForSwift(consuming: Self.cxxDomains(domains))
        #endif
        }
    }

    func answer(_ query: StatisticsThirdPartyDataRequest, on actor: isolated StatisticsActor) -> [IPCTypes.ITPThirdPartyData] {
        switch query {
        case .aggregatedThirdPartyData:
            let thirdPartyData = aggregatedThirdPartyData()
            return (0..<thirdPartyData.size()).map { IPCTypes.ITPThirdPartyData(thirdPartyData[$0]) }
        }
    }

    func storageAccessPermission(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        on actor: isolated StatisticsActor
    ) -> IPCTypes.PermissionState {
        .init(storageAccessPermission(.fromIPC(subFrameDomain), .fromIPC(topFrameDomain)))
    }
}

extension IPCTypes.RegistrableDomain {
    fileprivate init(_ domain: borrowing WebCore.RegistrableDomain) {
        self.init(string: IPCCoding.WTFString.swiftString(WebKit.ResourceLoadStatisticsStore.string(domain)))
    }
}

extension IPCTypes.ITPThirdPartyDataForSpecificFirstParty {
    fileprivate init(_ data: borrowing WebKit.ITPThirdPartyDataForSpecificFirstParty) {
        self.init(
            firstPartyDomain: .init(data.firstPartyDomain),
            storageAccessGranted: data.storageAccessGranted,
            timeLastUpdated: data.timeLastUpdated.seconds()
        )
    }
}

extension IPCTypes.ITPThirdPartyData {
    fileprivate init(_ data: borrowing WebKit.ITPThirdPartyData) {
        let underFirstParties = data.underFirstParties
        self.init(
            thirdPartyDomain: .init(data.thirdPartyDomain),
            underFirstParties: (0..<underFirstParties.size()).map { .init(underFirstParties[$0]) }
        )
    }
}

extension IPCTypes.PermissionState {
    fileprivate init(_ state: WebCore.PermissionState) {
        switch state {
        case .Granted: self = .granted
        case .Denied: self = .denied
        case .Prompt: self = .prompt
        @unknown default: fatalError("WebCore.PermissionState has no other value")
        }
    }
}

extension WebKit.ResourceLoadStatisticsStore {
    func perform(
        _ command: StatisticsDeferredCommandRequest,
        on actor: isolated StatisticsActor,
        then completion: @escaping () -> Void
    ) {
        switch command {
        case .logUserInteraction(let domain):
            logUserInteraction(.fromIPC(domain), on: actor, then: completion)
        case .clearUserInteraction(let domain):
            clearUserInteraction(.fromIPC(domain), on: actor, then: completion)
        case .updateCookieBlocking:
            updateCookieBlocking(on: actor, then: completion)
        case .processStatisticsAndDataRecords:
            processStatisticsAndDataRecords(on: actor, then: completion)
        case .setStorageAccessPermissionForTesting(let granted, let topFrameDomain, let subFrameDomain):
            // The reply can go before the grant or revoke below; later reads are later requests on this actor, so they
            // see it either way.
            if granted {
                logUserInteraction(.fromIPC(subFrameDomain), on: actor, then: completion)
                _ = grantStorageAccessPermission(.fromIPC(topFrameDomain), .fromIPC(subFrameDomain))
            } else {
                clearUserInteraction(.fromIPC(subFrameDomain), on: actor, then: completion)
                revokeStorageAccessPermission(.fromIPC(subFrameDomain))
            }
        }
    }
}
