/*
 * Copyright (C) 2019-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ResourceLoadStatisticsStore.h"

#include "DidFilterKnownLinkDecoration.h"
#include "ITPThirdPartyData.h"
#include "Logging.h"
#include "NetworkProcess.h"
#include "NetworkSession.h"
#include "PrivateClickMeasurementManager.h"
#include "PrivateClickMeasurementManagerProxy.h"
#include "StorageAccessStatus.h"
#include "WebProcessProxy.h"
#include "WebsiteDataStore.h"
#include <JavaScriptCore/ConsoleTypes.h>
#include <WebCore/CookieJar.h>
#include <WebCore/DocumentStorageAccess.h>
#include <WebCore/KeyedCoding.h>
#include <WebCore/OrganizationStorageAccessPromptQuirk.h>
#include <WebCore/ResourceLoadStatistics.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SQLiteStatement.h>
#include <WebCore/SQLiteStatementAutoResetScope.h>
#include <WebCore/StorageAccessQuirks.h>
#include <WebCore/UserGestureIndicator.h>
#include <ranges>
#include <wtf/CallbackAggregator.h>
#include <wtf/CompletionHandler.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/DateMath.h>
#include <wtf/Lock.h>
#include <wtf/MathExtras.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

namespace WebKit {
using namespace WebCore;

#define ITP_DEBUG_MODE_RELEASE_LOG(fmt, ...) RELEASE_LOG_INFO(ITPDebug, "ResourceLoadStatisticsStore: " fmt, ##__VA_ARGS__)
#define ITP_RELEASE_LOG_ERROR(fmt, ...) RELEASE_LOG_ERROR(ResourceLoadStatistics, "%p - [sessionID=%" PRIu64 "] - ResourceLoadStatisticsStore::" fmt, this, m_sessionID.toUInt64(), ##__VA_ARGS__)
#define ITP_RELEASE_LOG_DATABASE_ERROR(fmt, ...) RELEASE_LOG_ERROR(ResourceLoadStatistics, "%p - [sessionID=%" PRIu64 ", error=%d, message=%" PRIVATE_LOG_STRING "] - ResourceLoadStatisticsStore::" fmt, this, m_sessionID.toUInt64(), m_database->lastError(), m_database->lastErrorMsg(), ##__VA_ARGS__)


constexpr Seconds minimumStatisticsProcessingInterval { 5_s };


// SELECT Queries
constexpr auto domainWithUserInteractionQuery = "SELECT registrableDomain, mostRecentUserInteractionTime FROM ObservedDomains WHERE hadUserInteraction = 1"_s;

static constexpr size_t maxAdHocStatements = 1024;

constexpr auto createObservedDomain = "CREATE TABLE ObservedDomains ("
    "domainID INTEGER PRIMARY KEY, registrableDomain TEXT NOT NULL UNIQUE ON CONFLICT FAIL, lastSeen REAL NOT NULL, "
    "hadUserInteraction INTEGER NOT NULL, mostRecentUserInteractionTime REAL NOT NULL, grandfathered INTEGER NOT NULL, "
    "isPrevalent INTEGER NOT NULL, isVeryPrevalent INTEGER NOT NULL, dataRecordsRemoved INTEGER NOT NULL,"
    "timesAccessedAsFirstPartyDueToUserInteraction INTEGER NOT NULL, timesAccessedAsFirstPartyDueToStorageAccessAPI INTEGER NOT NULL,"
    "isScheduledForAllButCookieDataRemoval INTEGER NOT NULL, "
    "mostRecentWebPushInteractionTime REAL NOT NULL)"_s;

constexpr auto createTopLevelDomains = "CREATE TABLE TopLevelDomains ("
    "topLevelDomainID INTEGER PRIMARY KEY, CONSTRAINT fkDomainID FOREIGN KEY(topLevelDomainID) "
    "REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createStorageAccessUnderTopFrameDomains = "CREATE TABLE StorageAccessUnderTopFrameDomains ("
    "domainID INTEGER NOT NULL, topLevelDomainID INTEGER NOT NULL ON CONFLICT FAIL, "
    "CONSTRAINT fkDomainID FOREIGN KEY(domainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(topLevelDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameUniqueRedirectsTo = "CREATE TABLE TopFrameUniqueRedirectsTo ("
    "sourceDomainID INTEGER NOT NULL, toDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(sourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement = "CREATE TABLE TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement ("
    "sourceDomainID INTEGER NOT NULL, toDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(sourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameUniqueRedirectsFrom = "CREATE TABLE TopFrameUniqueRedirectsFrom ("
    "targetDomainID INTEGER NOT NULL, fromDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(targetDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(fromDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameLinkDecorationsFrom = "CREATE TABLE TopFrameLinkDecorationsFrom ("
    "toDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, fromDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(fromDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createTopFrameLoadedThirdPartyScripts = "CREATE TABLE TopFrameLoadedThirdPartyScripts ("
    "topFrameDomainID INTEGER NOT NULL, subresourceDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(topFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubframeUnderTopFrameDomains = "CREATE TABLE SubframeUnderTopFrameDomains ("
    "subFrameDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, topFrameDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(topFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubresourceUnderTopFrameDomains = "CREATE TABLE SubresourceUnderTopFrameDomains ("
    "subresourceDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, topFrameDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(topFrameDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubresourceUniqueRedirectsTo = "CREATE TABLE SubresourceUniqueRedirectsTo ("
    "subresourceDomainID INTEGER NOT NULL, lastUpdated REAL NOT NULL, toDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(toDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createSubresourceUniqueRedirectsFrom = "CREATE TABLE SubresourceUniqueRedirectsFrom ("
    "subresourceDomainID INTEGER NOT NULL, fromDomainID INTEGER NOT NULL, "
    "FOREIGN KEY(subresourceDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE, "
    "FOREIGN KEY(fromDomainID) REFERENCES ObservedDomains(domainID) ON DELETE CASCADE)"_s;

constexpr auto createOperatingDates = "CREATE TABLE OperatingDates ("
    "year INTEGER NOT NULL, month INTEGER NOT NULL, monthDay INTEGER NOT NULL)"_s;

// CREATE UNIQUE INDEX Queries.
constexpr auto createUniqueIndexStorageAccessUnderTopFrameDomains = "CREATE UNIQUE INDEX IF NOT EXISTS StorageAccessUnderTopFrameDomains_domainID_topLevelDomainID on StorageAccessUnderTopFrameDomains ( domainID, topLevelDomainID )"_s;
constexpr auto createUniqueIndexTopFrameUniqueRedirectsTo = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameUniqueRedirectsTo_sourceDomainID_toDomainID on TopFrameUniqueRedirectsTo ( sourceDomainID, toDomainID )"_s;
constexpr auto createUniqueIndexTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement_sourceDomainID_toDomainID on TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement ( sourceDomainID, toDomainID )"_s;
constexpr auto createUniqueIndexTopFrameUniqueRedirectsFrom = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameUniqueRedirectsFrom_targetDomainID_fromDomainID on TopFrameUniqueRedirectsFrom ( targetDomainID, fromDomainID )"_s;
constexpr auto createUniqueIndexTopFrameLinkDecorationsFrom = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameLinkDecorationsFrom_toDomainID_fromDomainID on TopFrameLinkDecorationsFrom ( toDomainID, fromDomainID )"_s;
constexpr auto createUniqueIndexTopFrameLoadedThirdPartyScripts = "CREATE UNIQUE INDEX IF NOT EXISTS TopFrameLoadedThirdPartyScripts_topFrameDomainID_subresourceDomainID on TopFrameLoadedThirdPartyScripts ( topFrameDomainID, subresourceDomainID )"_s;
constexpr auto createUniqueIndexSubframeUnderTopFrameDomains = "CREATE UNIQUE INDEX IF NOT EXISTS SubframeUnderTopFrameDomains_subFrameDomainID_topFrameDomainID on SubframeUnderTopFrameDomains ( subFrameDomainID, topFrameDomainID )"_s;
constexpr auto createUniqueIndexSubresourceUnderTopFrameDomains = "CREATE UNIQUE INDEX IF NOT EXISTS SubresourceUnderTopFrameDomains_subresourceDomainID_topFrameDomainID on SubresourceUnderTopFrameDomains ( subresourceDomainID, topFrameDomainID )"_s;
constexpr auto createUniqueIndexSubresourceUniqueRedirectsTo = "CREATE UNIQUE INDEX IF NOT EXISTS SubresourceUniqueRedirectsTo_subresourceDomainID_toDomainID on SubresourceUniqueRedirectsTo ( subresourceDomainID, toDomainID )"_s;
constexpr auto createUniqueIndexSubresourceUniqueRedirectsFrom = "CREATE UNIQUE INDEX IF NOT EXISTS SubresourceUniqueRedirectsFrom_subresourceDomainID_fromDomainID on SubresourceUniqueRedirectsFrom ( subresourceDomainID, fromDomainID )"_s;
constexpr auto createUniqueIndexOperatingDates = "CREATE UNIQUE INDEX IF NOT EXISTS OperatingDates_year_month_monthDay on OperatingDates ( year, month, monthDay )"_s;

static String domainsToString(const RegistrableDomainsToDeleteOrRestrictWebsiteDataFor& domainsToRemoveOrRestrictWebsiteDataFor)
{
    StringBuilder builder;
    for (auto& domain : borrow(domainsToRemoveOrRestrictWebsiteDataFor.domainsToDeleteAllCookiesFor))
        builder.append(builder.isEmpty() ? ""_s : ", "_s, domain.string(), "(all data)"_s);
    for (auto& domain : borrow(domainsToRemoveOrRestrictWebsiteDataFor.domainsToDeleteAllButHttpOnlyCookiesFor))
        builder.append(builder.isEmpty() ? ""_s : ", "_s, domain.string(), "(all but HttpOnly cookies)"_s);
    for (auto& domain : borrow(domainsToRemoveOrRestrictWebsiteDataFor.domainsToDeleteAllScriptWrittenStorageFor))
        builder.append(builder.isEmpty() ? ""_s : ", "_s, domain.string(), "(all but cookies)"_s);
    return builder.toString();
}

static WallTime nowTime(Seconds timeAdvanceForTesting)
{
    return WallTime::now() + timeAdvanceForTesting;
}

OperatingDate OperatingDate::fromWallTime(WallTime time)
{
    double ms = time.secondsSinceEpoch().milliseconds();
    int year = msToYear(ms);
    int yearDay = dayInYear(ms, year);
    int month = monthFromDayInYear(yearDay, isLeapYear(year));
    int monthDay = dayInMonthFromDayInYear(yearDay, isLeapYear(year));
    return OperatingDate { year, month, monthDay };
}

OperatingDate OperatingDate::today(Seconds timeAdvanceForTesting)
{
    return OperatingDate::fromWallTime(nowTime(timeAdvanceForTesting));
}

Seconds OperatingDate::secondsSinceEpoch() const
{
    return Seconds { dateToDaysFrom1970(m_year, m_month, m_monthDay) * secondsPerDay };
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(ResourceLoadStatisticsStore);

ResourceLoadStatisticsStore::ResourceLoadStatisticsStore(ShouldIncludeLocalhost shouldIncludeLocalhost, const String& storageDirectoryPath, PAL::SessionID sessionID)
    : DatabaseUtilities(FileSystem::pathByAppendingComponent(storageDirectoryPath, "observations.db"_s))
    , m_sessionID(sessionID)
    , m_shouldIncludeLocalhost(shouldIncludeLocalhost)
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());

    openAndUpdateSchemaIfNecessary();
    enableForeignKeys();

    if (!m_database->turnOnIncrementalAutoVacuum())
        ITP_RELEASE_LOG_DATABASE_ERROR("ResourceLoadStatisticsStore: failed to turn on auto vacuum");

    includeTodayAsOperatingDateIfNecessary();
}

ResourceLoadStatisticsStore::~ResourceLoadStatisticsStore()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());
    close();
}

Ref<ResourceLoadStatisticsStore> ResourceLoadStatisticsStore::createForStatisticsActor(bool includeLocalhost, const String& storageDirectoryPath, uint64_t sessionID)
{
    Ref store = adoptRef(*new ResourceLoadStatisticsStore(includeLocalhost ? ShouldIncludeLocalhost::Yes : ShouldIncludeLocalhost::No, storageDirectoryPath, PAL::SessionID { sessionID }));

    auto legacyPlistFilePath = FileSystem::pathByAppendingComponent(storageDirectoryPath, "full_browsing_session_resourceLog.plist"_s);
    if (FileSystem::fileExists(legacyPlistFilePath))
        FileSystem::deleteFile(legacyPlistFilePath);

    return store;
}

std::optional<HashMap<RegistrableDomain, WallTime>> ResourceLoadStatisticsStore::loadWebsitesWithUserInteraction()
{
    ASSERT(!RunLoop::isMain());

    HashMap<RegistrableDomain, WallTime> results;
    auto statement = m_database->prepareStatement(domainWithUserInteractionQuery);
    if (!statement)
        return std::nullopt;

    while (statement->step() == SQLITE_ROW)
        results.set(RegistrableDomain::uncheckedCreateFromRegistrableDomainString(statement->columnText(0)), WallTime::fromRawSeconds(statement->columnDouble(1)));

    return results;
}

void ResourceLoadStatisticsStore::logAboutToRemoveDataRecordsForSwift(const RegistrableDomainsToDeleteOrRestrictWebsiteDataFor& domainsToDeleteOrRestrictWebsiteDataFor)
{
    ITP_DEBUG_MODE_RELEASE_LOG("About to remove data records for %" PUBLIC_LOG_STRING ".", domainsToString(domainsToDeleteOrRestrictWebsiteDataFor).utf8());
    debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, makeString("[ITP] About to remove data records for: ["_s, domainsToString(domainsToDeleteOrRestrictWebsiteDataFor), "]."_s));
}

void ResourceLoadStatisticsStore::grandfatherDataForDomainsForSwift(RegistrableDomainVector&& domains)
{
    grandfatherDataForDomains(registrableDomainHashSetFromVector(WTF::move(domains)));
    m_endOfGrandfatheringTimestamp = nowTime(m_timeAdvanceForTesting) + m_parameters.grandfatheringTime;
}

#if ENABLE(APP_BOUND_DOMAINS)
void ResourceLoadStatisticsStore::setAppBoundDomainsForSwift(Vector<RegistrableDomain>&& domains)
{
    // Only membership is read (contains()), so the set's order is moot.
    m_appBoundDomains = registrableDomainHashSetFromVector(WTF::move(domains), 0);
    setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::AllExceptBetweenAppBoundDomains);
}
#endif

#if ENABLE(MANAGED_DOMAINS)
void ResourceLoadStatisticsStore::setManagedDomainsForSwift(Vector<RegistrableDomain>&& domains)
{
    // Only membership is read (contains()), so the set's order is moot.
    m_managedDomains = registrableDomainHashSetFromVector(WTF::move(domains), 0);
    setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::AllExceptManagedDomains);
}
#endif

void ResourceLoadStatisticsStore::scheduleStatisticsProcessingRequestIfNecessary()
{
    ASSERT(!RunLoop::isMain());

    m_pendingStatisticsProcessingRequestIdentifier = ++m_lastStatisticsProcessingRequestIdentifier;
    m_pendingPosts.append({ .kind = StatisticsStorePost::Kind::StatisticsProcessingRequest, .seconds = minimumStatisticsProcessingInterval, .statisticsProcessingRequestIdentifier = *m_pendingStatisticsProcessingRequestIdentifier });
}

void ResourceLoadStatisticsStore::cancelPendingStatisticsProcessingRequest()
{
    ASSERT(!RunLoop::isMain());

    m_pendingStatisticsProcessingRequestIdentifier = std::nullopt;
}

void ResourceLoadStatisticsStore::updateCacheMaxAgeCap()
{
    ASSERT(!RunLoop::isMain());
    
    m_pendingPosts.append({ .kind = StatisticsStorePost::Kind::CacheMaxAgeCap, .seconds = m_parameters.cacheMaxAgeCapTime });
}

bool ResourceLoadStatisticsStore::checkPromptedStorageAccessGrantForSwift(const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain, CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction)
{
#ifndef NDEBUG
    auto subFrameStatus = ensureResourceStatisticsForRegistrableDomain(subFrameDomain, "grantStorageAccessInternal"_s);
    if (!subFrameStatus.second)
        return false;

    ASSERT(subFrameStatus.first == AddedRecord::No);
#if ASSERT_ENABLED
    if (canRequestStorageAccessWithoutUserInteraction == CanRequestStorageAccessWithoutUserInteraction::No)
        ASSERT(hasHadUserInteraction(subFrameDomain, OperatingDatesWindow::Long));
#endif
    ASSERT(hasUserGrantedStorageAccessThroughPrompt(*subFrameStatus.second, topFrameDomain));
#else
    UNUSED_PARAM(subFrameDomain);
    UNUSED_PARAM(topFrameDomain);
    UNUSED_PARAM(canRequestStorageAccessWithoutUserInteraction);
#endif
    return true;
}

Seconds ResourceLoadStatisticsStore::clientSideCookiesAgeCapForSwift() const
{
#if ENABLE(JS_COOKIE_CHECKING)
    return m_parameters.clientSideCookiesForLinkDecorationTargetPageAgeCapTime;
#else
    return m_parameters.clientSideCookiesAgeCapTime;
#endif
}

void ResourceLoadStatisticsStore::debugBroadcastConsoleMessage(MessageSource source, MessageLevel level, const String& message)
{
    ASSERT(!RunLoop::isMain());

    m_pendingPosts.append({ .kind = StatisticsStorePost::Kind::ConsoleMessage, .consoleMessageSource = static_cast<uint8_t>(source), .consoleMessageLevel = static_cast<uint8_t>(level), .consoleMessage = message.isolatedCopy() });
}

bool ResourceLoadStatisticsStore::shouldExemptFromWebsiteDataDeletion(const RegistrableDomain& domain) const
{
    return !domain.isEmpty() && domainsExemptFromWebsiteDataDeletion().contains(domain);
}

HashSet<RegistrableDomain> ResourceLoadStatisticsStore::domainsExemptFromWebsiteDataDeletion() const
{
    auto result = m_appBoundDomains.unionWith(m_managedDomains);
    result = result.unionWith(m_persistedDomains);

    if (!m_standaloneApplicationDomain.isEmpty())
        result.add(m_standaloneApplicationDomain);

    return result;
}

const MemoryCompactLookupOnlyRobinHoodHashMap<String, TableAndIndexPair>& ResourceLoadStatisticsStore::expectedTableAndIndexQueries()
{
    static NeverDestroyed expectedTableAndIndexQueries = MemoryCompactLookupOnlyRobinHoodHashMap<String, TableAndIndexPair> {
        { "ObservedDomains"_s, std::make_pair<String, std::optional<String>>(createObservedDomain, std::nullopt) },
        { "TopLevelDomains"_s, std::make_pair<String, std::optional<String>>(createTopLevelDomains, std::nullopt) },
        { "StorageAccessUnderTopFrameDomains"_s, std::make_pair<String, std::optional<String>>(createStorageAccessUnderTopFrameDomains, stripIndexQueryToMatchStoredValue(createUniqueIndexStorageAccessUnderTopFrameDomains)) },
        { "TopFrameUniqueRedirectsTo"_s, std::make_pair<String, std::optional<String>>(createTopFrameUniqueRedirectsTo, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameUniqueRedirectsTo)) },
        { "TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement"_s, std::make_pair<String, std::optional<String>>(createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement)) },
        { "TopFrameUniqueRedirectsFrom"_s, std::make_pair<String, std::optional<String>>(createTopFrameUniqueRedirectsFrom, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameUniqueRedirectsFrom)) },
        { "TopFrameLinkDecorationsFrom"_s, std::make_pair<String, std::optional<String>>(createTopFrameLinkDecorationsFrom, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameLinkDecorationsFrom)) },
        { "TopFrameLoadedThirdPartyScripts"_s, std::make_pair<String, std::optional<String>>(createTopFrameLoadedThirdPartyScripts, stripIndexQueryToMatchStoredValue(createUniqueIndexTopFrameLoadedThirdPartyScripts)) },
        { "SubframeUnderTopFrameDomains"_s, std::make_pair<String, std::optional<String>>(createSubframeUnderTopFrameDomains, stripIndexQueryToMatchStoredValue(createUniqueIndexSubframeUnderTopFrameDomains)) },
        { "SubresourceUnderTopFrameDomains"_s, std::make_pair<String, std::optional<String>>(createSubresourceUnderTopFrameDomains, stripIndexQueryToMatchStoredValue(createUniqueIndexSubresourceUnderTopFrameDomains)) },
        { "SubresourceUniqueRedirectsTo"_s, std::make_pair<String, std::optional<String>>(createSubresourceUniqueRedirectsTo, stripIndexQueryToMatchStoredValue(createUniqueIndexSubresourceUniqueRedirectsTo)) },
        { "SubresourceUniqueRedirectsFrom"_s, std::make_pair<String, std::optional<String>>(createSubresourceUniqueRedirectsFrom, stripIndexQueryToMatchStoredValue(createUniqueIndexSubresourceUniqueRedirectsFrom)) },
        { "OperatingDates"_s, std::make_pair<String, std::optional<String>>(createOperatingDates, stripIndexQueryToMatchStoredValue(createUniqueIndexOperatingDates)) },
    };
    return expectedTableAndIndexQueries;
}

std::span<const ASCIILiteral> ResourceLoadStatisticsStore::sortedTables()
{
    static constexpr std::array sortedTables {
        "ObservedDomains"_s,
        "TopLevelDomains"_s,
        "StorageAccessUnderTopFrameDomains"_s,
        "TopFrameUniqueRedirectsTo"_s,
        "TopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement"_s,
        "TopFrameUniqueRedirectsFrom"_s,
        "TopFrameLinkDecorationsFrom"_s,
        "TopFrameLoadedThirdPartyScripts"_s,
        "SubframeUnderTopFrameDomains"_s,
        "SubresourceUnderTopFrameDomains"_s,
        "SubresourceUniqueRedirectsTo"_s,
        "SubresourceUniqueRedirectsFrom"_s,
        "OperatingDates"_s
    };

    return sortedTables;
}

std::optional<Vector<String>> ResourceLoadStatisticsStore::checkForMissingTablesInSchema()
{
    Vector<String> missingTables;
    for (auto& table : expectedTableAndIndexQueries().keys()) {
        if (!this->tableExists(table))
            missingTables.append(String(table));
    }
    if (missingTables.isEmpty())
        return std::nullopt;

    return missingTables;
}

void ResourceLoadStatisticsStore::deleteTable(StringView tableName)
{
    ASSERT(tableExists(tableName.toString()));
    auto dropTableQuery = m_database->prepareStatementSlow(makeString("DROP TABLE "_s, tableName));
    ASSERT(dropTableQuery);
    if (!dropTableQuery || dropTableQuery->step() != SQLITE_DONE)
        ITP_RELEASE_LOG_DATABASE_ERROR("deleteTable: failed to step statement");
}

bool ResourceLoadStatisticsStore::needsUpdatedSchema()
{
    // There are 3 cases where we expect potential schema changes due to upgrades.
    // All other tables should be up-to-date, so we should ASSERT that they are correct.
    if (missingReferenceToObservedDomains() || missingUniqueIndices())
        return true;

    for (auto& table : expectedTableAndIndexQueries().keys()) {
        UNUSED_PARAM(table);
        ASSERT(currentTableAndIndexQueries(table) == expectedTableAndIndexQueries().get(table));
    }

    return false;
}

// The measurements a store migrated, until main takes them: they never enter Swift, which carries only the key.
// Main takes each entry, with or without a network session, and the statistics actor sends a store's posts before
// it releases the store, so no entry outlives its post.
struct PendingPrivateClickMeasurementMigration {
    Vector<WebCore::PrivateClickMeasurement> attributed;
    Vector<WebCore::PrivateClickMeasurement> unattributed;
};

static Lock pendingPrivateClickMeasurementMigrationsLock;
static uint64_t lastPrivateClickMeasurementMigrationIdentifier WTF_GUARDED_BY_LOCK(pendingPrivateClickMeasurementMigrationsLock) { 0 };

static HashMap<uint64_t, PendingPrivateClickMeasurementMigration>& pendingPrivateClickMeasurementMigrations() WTF_REQUIRES_LOCK(pendingPrivateClickMeasurementMigrationsLock)
{
    static NeverDestroyed<HashMap<uint64_t, PendingPrivateClickMeasurementMigration>> migrations;
    return migrations;
}

void WebResourceLoadStatisticsStore::migratePrivateClickMeasurementForSwift(uint64_t identifier)
{
    PendingPrivateClickMeasurementMigration migration;
    {
        Locker locker { pendingPrivateClickMeasurementMigrationsLock };
        migration = pendingPrivateClickMeasurementMigrations().take(identifier);
    }

    CheckedPtr networkSession = this->networkSession();
    if (!networkSession)
        return;

    Ref manager = networkSession->privateClickMeasurement();
    for (auto&& pcm : borrow(migration.attributed))
        manager->migratePrivateClickMeasurementFromLegacyStorage(WTF::move(pcm), PrivateClickMeasurementAttributionType::Attributed);
    for (auto&& pcm : borrow(migration.unattributed))
        manager->migratePrivateClickMeasurementFromLegacyStorage(WTF::move(pcm), PrivateClickMeasurementAttributionType::Unattributed);
}

void ResourceLoadStatisticsStore::migrateDataToPCMDatabaseIfNecessary()
{
    if (!tableExists("UnattributedPrivateClickMeasurement"_s)
        && !tableExists("AttributedPrivateClickMeasurement"_s))
        return;

    Vector<WebCore::PrivateClickMeasurement> unattributed;
    {
        constexpr auto allUnattributedPrivateClickMeasurementAttributionsQuery = "SELECT * FROM UnattributedPrivateClickMeasurement"_s;
        auto unattributedScopedStatement = m_database->prepareStatement(allUnattributedPrivateClickMeasurementAttributionsQuery);
        if (!unattributedScopedStatement) {
            ITP_RELEASE_LOG_DATABASE_ERROR("migrateDataToPCMDatabaseIfNecessary: failed to prepare unattributedScopedStatement");
            return;
        }
        while (unattributedScopedStatement->step() == SQLITE_ROW)
            unattributed.append(buildPrivateClickMeasurementFromDatabase(*unattributedScopedStatement, PrivateClickMeasurementAttributionType::Unattributed));
    }

    Vector<WebCore::PrivateClickMeasurement> attributed;
    {
        constexpr auto allAttributedPrivateClickMeasurementQuery = "SELECT * FROM AttributedPrivateClickMeasurement"_s;
        auto attributedScopedStatement = m_database->prepareStatement(allAttributedPrivateClickMeasurementQuery);
        if (!attributedScopedStatement) {
            ITP_RELEASE_LOG_DATABASE_ERROR("migrateDataToPCMDatabaseIfNecessary: failed to prepare attributedScopedStatement");
            return;
        }
        while (attributedScopedStatement->step() == SQLITE_ROW)
            attributed.append(buildPrivateClickMeasurementFromDatabase(*attributedScopedStatement, PrivateClickMeasurementAttributionType::Attributed));
    }

    if (!unattributed.isEmpty() || !attributed.isEmpty()) {
        uint64_t identifier;
        {
            Locker locker { pendingPrivateClickMeasurementMigrationsLock };
            identifier = ++lastPrivateClickMeasurementMigrationIdentifier;
            pendingPrivateClickMeasurementMigrations().add(identifier, PendingPrivateClickMeasurementMigration { crossThreadCopy(WTF::move(attributed)), crossThreadCopy(WTF::move(unattributed)) });
        }
        m_pendingPosts.append({ .kind = StatisticsStorePost::Kind::PrivateClickMeasurementMigration, .privateClickMeasurementMigrationIdentifier = identifier });
    }

    auto transactionScope = beginTransactionIfNecessary();
    deleteTable("UnattributedPrivateClickMeasurement"_s);
    deleteTable("AttributedPrivateClickMeasurement"_s);
}

void ResourceLoadStatisticsStore::addMissingTablesIfNecessary()
{
    const auto missingTables = checkForMissingTablesInSchema();
    if (!missingTables)
        return;

    auto transaction = beginTransactionIfNecessary();

    for (auto& table : *missingTables) {
        auto createTableQuery = expectedTableAndIndexQueries().get(table).first;
        if (!m_database->executeCommandSlow(createTableQuery))
            ITP_RELEASE_LOG_DATABASE_ERROR("addMissingTablesIfNecessary: failed to execute statement");
    }

    if (!createUniqueIndices())
        ITP_RELEASE_LOG_ERROR("addMissingTablesIfNecessary: failed to create unique indices");
}

bool ResourceLoadStatisticsStore::createUniqueIndices()
{
    static constexpr std::array uniqueIndexQueries {
        createUniqueIndexStorageAccessUnderTopFrameDomains,
        createUniqueIndexTopFrameUniqueRedirectsTo,
        createUniqueIndexTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
        createUniqueIndexTopFrameUniqueRedirectsFrom,
        createUniqueIndexTopFrameLinkDecorationsFrom,
        createUniqueIndexTopFrameLoadedThirdPartyScripts,
        createUniqueIndexSubframeUnderTopFrameDomains,
        createUniqueIndexSubresourceUnderTopFrameDomains,
        createUniqueIndexSubresourceUniqueRedirectsTo,
        createUniqueIndexSubresourceUniqueRedirectsFrom,
        createUniqueIndexSubresourceUnderTopFrameDomains,
        createUniqueIndexOperatingDates,
    };
    static_assert(uniqueIndexQueries.size() + 1 == expectedIndexCount());

    for (auto query : uniqueIndexQueries) {
        if (!m_database->executeCommand(query)) {
            ITP_RELEASE_LOG_DATABASE_ERROR("createUniqueIndices: failed to execute statement");
            return false;
        }
    }
    return true;
}

bool ResourceLoadStatisticsStore::createSchema()
{
    ASSERT(!RunLoop::isMain());

    if (!m_database->executeCommand(createObservedDomain)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createObservedDomain");
        return false;
    }

    // FIXME: drop TopLevelDomains table as it is not used.
    if (!m_database->executeCommand(createTopLevelDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopLevelDomains");
        return false;
    }

    if (!m_database->executeCommand(createStorageAccessUnderTopFrameDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createStorageAccessUnderTopFrameDomains");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameUniqueRedirectsTo)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameUniqueRedirectsTo");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameUniqueRedirectsToSinceSameSiteStrictEnforcement");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameUniqueRedirectsFrom)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameUniqueRedirectsFrom");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameLinkDecorationsFrom)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameLinkDecorationsFrom");
        return false;
    }

    if (!m_database->executeCommand(createTopFrameLoadedThirdPartyScripts)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createTopFrameLoadedThirdPartyScripts");
        return false;
    }

    if (!m_database->executeCommand(createSubframeUnderTopFrameDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubframeUnderTopFrameDomains");
        return false;
    }

    if (!m_database->executeCommand(createSubresourceUnderTopFrameDomains)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubresourceUnderTopFrameDomains");
        return false;
    }

    if (!m_database->executeCommand(createSubresourceUniqueRedirectsTo)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubresourceUniqueRedirectsTo");
        return false;
    }

    if (!m_database->executeCommand(createSubresourceUniqueRedirectsFrom)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createSubresourceUniqueRedirectsFrom");
        return false;
    }

    if (!m_database->executeCommand(createOperatingDates)) {
        ITP_RELEASE_LOG_DATABASE_ERROR("createSchema: failed to execute statement createOperatingDates");
        return false;
    }

    if (!createUniqueIndices())
        return false;

    return true;
}

static void retireGeneration(uint64_t& generation)
{
    RELEASE_ASSERT(generation < std::numeric_limits<uint64_t>::max());
    ++generation;
}

bool ResourceLoadStatisticsStore::beginTransactionIfNecessaryForSwift()
{
    ASSERT(!RunLoop::isMain());
    if (m_transaction.inProgress())
        return false;

    m_transaction.begin();
    return true;
}

void ResourceLoadStatisticsStore::commitTransactionForSwift(bool didBeginTransaction)
{
    if (didBeginTransaction)
        m_transaction.commit();
}

DomainIDVector ResourceLoadStatisticsStore::hashMapIterationOrder(DomainIDVector keys)
{
    HashMap<unsigned, unsigned> indexes;
    for (unsigned index = 0; index < keys.size(); ++index)
        indexes.add(keys[index], index);
    return copyToVector(indexes.values());
}

void ResourceLoadStatisticsStore::destroyStatements()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());

    for (auto& slot : m_statements) {
        slot.statement = nullptr;
        retireGeneration(slot.generation);
    }
}

// No member below keeps a reference to a StatementSlot across a call that can reach these members again, since
// m_statements can grow and move its slots. SQLite calls back only into the database's busy handler and
// unauthorized-function hook, neither of which reaches the store.
static SQLiteStatement& resolveStatement(auto& slots, uint32_t index, uint64_t generation)
{
    RELEASE_ASSERT(index < slots.size());
    auto& slot = slots[index];
    RELEASE_ASSERT(slot.statement && slot.generation == generation);
    return *slot.statement;
}

SQLStatementHandle ResourceLoadStatisticsStore::prepareCachedStatement(uint8_t index, const String& query, const String& logLabel) const
{
    ASSERT(!RunLoop::isMain());
    RELEASE_ASSERT(index < resourceLoadStatisticsCachedStatementCount);
    auto& slot = m_statements[index];
    if (!slot.statement) {
        slot.statement = m_database->prepareStatementSlow(query);
        if (!slot.statement) {
            RELEASE_LOG_ERROR(PrivateClickMeasurement, "%p - DatabaseUtilities::%" PUBLIC_LOG_STRING " failed to prepare statement, error message: %" PUBLIC_LOG_STRING, this, logLabel.utf8(), m_database->lastErrorMsg());
            return { };
        }
        ASSERT(m_database->isOpen());
    }
    return { index, slot.generation };
}

SQLStatementHandle ResourceLoadStatisticsStore::openStatement(String query) const
{
    auto statement = m_database->prepareStatementSlow(query);
    if (!statement)
        return { };
    uint32_t index = resourceLoadStatisticsCachedStatementCount;
    while (index < m_statements.size() && m_statements[index].statement)
        ++index;
    if (index == m_statements.size()) {
        RELEASE_ASSERT(index < resourceLoadStatisticsCachedStatementCount + maxAdHocStatements);
        m_statements.constructAndAppend();
    }
    m_statements[index].statement = WTF::move(statement);
    return { index, m_statements[index].generation };
}

void ResourceLoadStatisticsStore::closeStatement(SQLStatementHandle handle) const
{
    // The bound test comes first: a handle can name any slot.
    if (handle.m_slot >= m_statements.size() || !m_statements[handle.m_slot].statement || m_statements[handle.m_slot].generation != handle.m_generation)
        return;
    auto& slot = m_statements[handle.m_slot];
    if (handle.m_slot < resourceLoadStatisticsCachedStatementCount) {
        slot.statement->reset();
        return;
    }
    slot.statement = nullptr;
    retireGeneration(slot.generation);
}

int ResourceLoadStatisticsStore::bindInt(SQLStatementHandle handle, int index, int value) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).bindInt(index, value);
}

int ResourceLoadStatisticsStore::bindText(SQLStatementHandle handle, int index, String value) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).bindText(index, value);
}

int ResourceLoadStatisticsStore::bindDouble(SQLStatementHandle handle, int index, double value) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).bindDouble(index, value);
}

int ResourceLoadStatisticsStore::step(SQLStatementHandle handle) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).step();
}

int ResourceLoadStatisticsStore::reset(SQLStatementHandle handle) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).reset();
}

int ResourceLoadStatisticsStore::columnInt(SQLStatementHandle handle, int column) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).columnInt(column);
}

String ResourceLoadStatisticsStore::columnText(SQLStatementHandle handle, int column) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).columnText(column);
}

double ResourceLoadStatisticsStore::columnDouble(SQLStatementHandle handle, int column) const
{
    return resolveStatement(m_statements, handle.m_slot, handle.m_generation).columnDouble(column);
}

void ResourceLoadStatisticsStore::incrementRecordsDeletedCountForDomains(HashSet<RegistrableDomain>&& domains)
{
    updateObservedDomainsList("dataRecordsRemoved = dataRecordsRemoved + 1"_s, copyToVector(domains), "incrementRecordsDeletedCountForDomains"_s);
}

void ResourceLoadStatisticsStore::grandfatherDataForDomains(const HashSet<RegistrableDomain>& domains)
{
    ASSERT(!RunLoop::isMain());

    if (domains.isEmpty())
        return;

    auto transactionScope = beginTransactionIfNecessary();

    for (auto& registrableDomain : domains) {
        auto result = ensureResourceStatisticsForRegistrableDomain(registrableDomain, "grandfatherDataForDomains"_s);
        UNUSED_PARAM(result);
    }

    updateObservedDomainsList("grandfathered = 1"_s, copyToVector(domains), "grandfatherDataForDomains"_s);
}

void ResourceLoadStatisticsStore::updateCookieBlockingWithoutCompletion()
{
    ASSERT(!RunLoop::isMain());

    auto domainsToBlock = domainsToBlockCookiesFor();
    if (domainsToBlock.isEmpty())
        return;
    m_pendingPosts.append({ .kind = StatisticsStorePost::Kind::CookieBlocking, .domainsToBlock = WTF::move(domainsToBlock) });
}

String ResourceLoadStatisticsStore::stringFromBuilder(StringBuilder& builder)
{
    return WTF::move(builder).toString();
}

void ResourceLoadStatisticsStore::dumpResourceLoadStatistics(CompletionHandler<void(String)>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(!RunLoop::isMain());
    if (m_dataRecordsBeingRemoved) {
        // AnyThread, here and on the handler it holds: the statistics actor may run them on another of its threads.
        // The handler moves into a new one with the same function, only its call thread differs.
        CompletionHandler<void(String)> anyThreadCompletionHandler { WTF::adopt(completionHandler.leak()), CompletionHandlerCallThread::AnyThread };
        m_dataRecordRemovalCompletionHandlers.append(CompletionHandler<void(ResourceLoadStatisticsStore&)> { [completionHandler = WTF::move(anyThreadCompletionHandler)](ResourceLoadStatisticsStore& store) mutable {
            store.dumpResourceLoadStatistics(WTF::move(completionHandler));
        }, CompletionHandlerCallThread::AnyThread });
        return;
    }

    completionHandler(dumpResourceLoadStatisticsText());
}

HashMap<RegistrableDomain, WallTime> ResourceLoadStatisticsStore::allDomainsWithLastAccessedTime() const
{
    ASSERT(!RunLoop::isMain());

    HashMap<RegistrableDomain, WallTime> result;
    for (auto& domainData : domains()) {
        auto lastAccessedTime = std::max(domainData.mostRecentUserInteractionTime, domainData.mostRecentWebPushInteractionTime);
        result.add(WTF::move(domainData.registrableDomain), lastAccessedTime);
    }

    return result;
}

void ResourceLoadStatisticsStore::domainsWithLastAccessedTimeForSwift(RegistrableDomainVector& domains, StatisticsTimeVector& times) const
{
    auto domainsWithTimes = allDomainsWithLastAccessedTime();
    domains = copyToVector(domainsWithTimes.keys());
    times = WTF::map(domainsWithTimes.values(), [](WallTime time) {
        return time.secondsSinceEpoch().value();
    });
}

bool ResourceLoadStatisticsStore::websitesWithUserInteractionForSwift(RegistrableDomainVector& domains, StatisticsTimeVector& times)
{
    auto websites = loadWebsitesWithUserInteraction();
    if (!websites)
        return false;
    domains = copyToVector(websites->keys());
    times = WTF::map(websites->values(), [](WallTime time) {
        return time.secondsSinceEpoch().value();
    });
    return true;
}

HashMap<TopFrameDomain, Vector<SubResourceDomain>> ResourceLoadStatisticsStore::domainsWithStorageAccess() const
{
    ASSERT(!RunLoop::isMain());

    HashMap<WebCore::RegistrableDomain, Vector<WebCore::RegistrableDomain>> results;
    auto statement = m_database->prepareStatement("SELECT subFrameDomain, registrableDomain FROM (SELECT o.registrableDomain as subFrameDomain, s.topLevelDomainID as topLevelDomainID FROM ObservedDomains as o INNER JOIN StorageAccessUnderTopFrameDomains as s WHERE o.domainID = s.domainID) as z INNER JOIN ObservedDomains ON domainID = z.topLevelDomainID;"_s);
    if (!statement)
        return results;

    while (statement->step() == SQLITE_ROW)
        results.add(RegistrableDomain::uncheckedCreateFromRegistrableDomainString(statement->columnText(1)), Vector<SubResourceDomain> { }).iterator->value.append(RegistrableDomain::uncheckedCreateFromRegistrableDomainString(statement->columnText(0)));

    return results;
}

void ResourceLoadStatisticsStore::logCookieBlockingDoneForSwift()
{
    if (debugLoggingEnabled()) [[unlikely]] {
        ITP_DEBUG_MODE_RELEASE_LOG("Done applying cross-site tracking restrictions.");
        debugBroadcastConsoleMessage(MessageSource::ITPDebug, MessageLevel::Info, "[ITP] Done applying cross-site tracking restrictions."_s);
    }
}

RegistrableDomainsToBlockCookiesFor ResourceLoadStatisticsStore::domainsToBlockCookiesFor()
{
    ASSERT(!RunLoop::isMain());

    RegistrableDomainsToBlockCookiesFor domainsToBlock { domainsToBlockAndDeleteCookiesFor(), domainsToBlockButKeepCookiesFor(), domainsWithUserInteractionAsFirstParty(), domainsWithStorageAccess() };

    if (debugLoggingEnabled() && (!domainsToBlock.domainsToBlockAndDeleteCookiesFor.isEmpty() || !domainsToBlock.domainsToBlockButKeepCookiesFor.isEmpty())) {
        debugLogDomainsInBatches("Applying cross-site tracking restrictions"_s, domainsToBlock.domainsToBlockAndDeleteCookiesFor,
            domainsToBlock.domainsToBlockButKeepCookiesFor);
    }
    return domainsToBlock;
}

} // namespace WebKit

#undef ITP_RELEASE_LOG
#undef ITP_RELEASE_LOG_ERROR
