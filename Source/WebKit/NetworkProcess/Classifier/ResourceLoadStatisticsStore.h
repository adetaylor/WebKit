/*
 * Copyright (C) 2019-2023 Apple Inc. All rights reserved.
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

#pragma once

#include "DatabaseUtilities.h"
#include "DidFilterKnownLinkDecoration.h"
#include "ITPThirdPartyData.h"
#include "ResourceLoadStatisticsClassifier.h"
#include "WebResourceLoadStatisticsStore.h"
#include <JavaScriptCore/ConsoleTypes.h>
#include <WebCore/FrameIdentifier.h>
#include <pal/SessionID.h>
#include <wtf/FileSystem.h>
#include <wtf/Forward.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/StdSet.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

#if HAVE(CORE_PREDICTION)
#include "ResourceLoadStatisticsClassifierCocoa.h"
#endif

namespace WebCore {
class KeyedDecoder;
class KeyedEncoder;
class SQLiteStatement;
enum class StorageAccessPromptWasShown : bool;
enum class StorageAccessWasGranted : uint8_t;
struct ResourceLoadStatistics;
}

namespace WebKit {

// Names for Swift, which cannot spell a class template specialization.
using OptionalDomainID = std::optional<unsigned>;
using RegistrableDomainVector = Vector<WebCore::RegistrableDomain>;
using DomainIDVector = Vector<unsigned>;
using ITPThirdPartyDataVector = Vector<ITPThirdPartyData>;
using ITPThirdPartyDataForSpecificFirstPartyVector = Vector<ITPThirdPartyDataForSpecificFirstParty>;

// A Vector from Swift made a HashSet again: the size reserved when under reserveLimit (no limit,
// ArgumentCoder<HashSet>'s cap for a decoded set, or 0), then each domain added in order.
inline HashSet<WebCore::RegistrableDomain> registrableDomainHashSetFromVector(RegistrableDomainVector&& domains, size_t reserveLimit = std::numeric_limits<size_t>::max())
{
    HashSet<WebCore::RegistrableDomain> set;
    if (domains.size() < reserveLimit) [[likely]]
        set.reserveInitialCapacity(domains.size());
    for (auto& domain : domains)
        set.add(WTF::move(domain));
    return set;
}

// A main-thread post the store's C++ or its `@cxx` Swift members make inside a statistics actor job. The actor takes
// them in order and sends them on before its own next main hop for the store and at the end of the job, so they keep their
// order relative to the actor's replies. It holds only values Swift converts, never the main side.
struct StatisticsStorePost {
    enum class Kind : uint8_t { ConsoleMessage, CacheMaxAgeCap, CookieBlocking, StatisticsProcessingRequest, PrivateClickMeasurementMigration };
    Kind kind { Kind::ConsoleMessage };
    uint8_t consoleMessageSource { 0 };
    uint8_t consoleMessageLevel { 0 };
    String consoleMessage;
    Seconds seconds;
    uint64_t statisticsProcessingRequestIdentifier { 0 };
    // The migrated measurements stay in ResourceLoadStatisticsStore.cpp's table; only their key crosses.
    uint64_t privateClickMeasurementMigrationIdentifier { 0 };
    RegistrableDomainsToBlockCookiesFor domainsToBlock;
};
using StatisticsStorePostVector = Vector<StatisticsStorePost>;

class ResourceLoadStatisticsStore;

// The dumpResourceLoadStatistics calls a data-record removal held back, taken when the removal ends and run after its
// own completion, on the store that holds them (ResourceLoadStatisticsStore.swift, removeDataRecords(on:then:)).
class StatisticsDataRecordRemovalWaiters {
    WTF_MAKE_NONCOPYABLE(StatisticsDataRecordRemovalWaiters);
public:
    explicit StatisticsDataRecordRemovalWaiters(Vector<CompletionHandler<void(ResourceLoadStatisticsStore&)>>&& handlers)
        : m_handlers(WTF::move(handlers))
    {
    }
    StatisticsDataRecordRemovalWaiters(StatisticsDataRecordRemovalWaiters&&) = default;

    void run(ResourceLoadStatisticsStore& store)
    {
        for (auto& handler : std::exchange(m_handlers, { }))
            handler(store);
    }

private:
    Vector<CompletionHandler<void(ResourceLoadStatisticsStore&)>> m_handlers;
};

// Any value is safe to pass: the store checks the slot and its generation on every use, so a stale or made-up handle
// traps or names a live statement of the same store.
struct SQLStatementHandle {
    bool isValid() const { return m_generation; }
    uint32_t m_slot { 0 };
    uint64_t m_generation { 0 };
};

// CachedStatement.allCases.count in ResourceLoadStatisticsStore.swift, which asserts it.
static constexpr size_t resourceLoadStatisticsCachedStatementCount = 34;

class OperatingDate {
public:
    OperatingDate() = default;
    
    static OperatingDate fromWallTime(WallTime);
    static OperatingDate today(Seconds timeAdvanceForTesting);
    Seconds secondsSinceEpoch() const;
    int year() const { return m_year; }
    int month() const { return m_month; }
    int monthDay() const { return m_monthDay; }

    friend bool operator==(const OperatingDate&, const OperatingDate&) = default;
    friend auto operator<=>(const OperatingDate& a, const OperatingDate& b) { return a.secondsSinceEpoch() <=> b.secondsSinceEpoch(); }
    
    OperatingDate(int year, int month, int monthDay)
        : m_year(year)
        , m_month(month)
        , m_monthDay(monthDay)
    { }

private:
    int m_year { 0 };
    int m_month { 0 }; // [0, 11].
    int m_monthDay { 0 }; // [1, 31].
};

enum class OperatingDatesWindow : uint8_t { Long, Short, ForLiveOnTesting, ForReproTesting };
enum class CookieAccess : uint8_t { CannotRequest, BasedOnCookiePolicy, OnlyIfGranted };
enum class CanRequestStorageAccessWithoutUserInteraction : bool { No, Yes };
enum class DataRemovalFrequency : uint8_t { Never, Short, Long };

// This is always constructed / used / destroyed on the statistics actor (WebResourceLoadStatisticsStore.swift).
class SWIFT_PRIVATE_FILEID("WebKit/ResourceLoadStatisticsStore.swift") ResourceLoadStatisticsStore final : public RefCountedAndCanMakeWeakPtr<ResourceLoadStatisticsStore>,  public DatabaseUtilities {
    WTF_MAKE_TZONE_ALLOCATED(ResourceLoadStatisticsStore);
public:
    using ResourceLoadStatistics = WebCore::ResourceLoadStatistics;
    using RegistrableDomain = WebCore::RegistrableDomain;
    using TopFrameDomain = WebCore::RegistrableDomain;
    using SubFrameDomain = WebCore::RegistrableDomain;
    using SubResourceDomain = WebCore::RegistrableDomain;
    using RedirectDomain = WebCore::RegistrableDomain;
    using RedirectedFromDomain = WebCore::RegistrableDomain;
    using RedirectedToDomain = WebCore::RegistrableDomain;
    using NavigatedFromDomain = WebCore::RegistrableDomain;
    using NavigatedToDomain = WebCore::RegistrableDomain;
    using DomainInNeedOfStorageAccess = WebCore::RegistrableDomain;
    using OpenerDomain = WebCore::RegistrableDomain;
    
    // The store, made by the statistics actor (WebResourceLoadStatisticsStore.swift), whose alone it is.
    static Ref<ResourceLoadStatisticsStore> createForStatisticsActor(bool includeLocalhost, const String& storageDirectoryPath, uint64_t sessionID);

    ~ResourceLoadStatisticsStore();

    bool isEmpty() const;
    ITPThirdPartyDataVector aggregatedThirdPartyData() const;

    // The statistics actor's side of the posts above, and whether a delayed processing request is still the pending
    // one (a later request or cancelPendingStatisticsProcessingRequest() replaces it).
    StatisticsStorePostVector takePendingPostsForSwift() { return std::exchange(m_pendingPosts, { }); }
    bool isPendingStatisticsProcessingRequestForSwift(uint64_t identifier) const { return m_pendingStatisticsProcessingRequestIdentifier == identifier; }
    // The second part of updateCookieBlocking's round trip, once its main part is done.
    void logCookieBlockingDoneForSwift();
    // The lists a cookie-blocking update sends, logged as the update logs them; all empty when there is none to send.
    RegistrableDomainsToBlockCookiesFor domainsToBlockCookiesFor();
    // The round trips' C++ parts, for the store's Swift on the statistics actor. Each Vector is the main part's
    // HashSet in its order, made a HashSet again in that order.
    void logAboutToRemoveDataRecordsForSwift(const RegistrableDomainsToDeleteOrRestrictWebsiteDataFor&);
    void incrementRecordsDeletedCountForDomainsForSwift(RegistrableDomainVector&& domains) { incrementRecordsDeletedCountForDomains(registrableDomainHashSetFromVector(WTF::move(domains))); }
    StatisticsDataRecordRemovalWaiters takeDataRecordRemovalWaitersForSwift() { return StatisticsDataRecordRemovalWaiters { std::exchange(m_dataRecordRemovalCompletionHandlers, { }) }; }
    void grandfatherDataForDomainsForSwift(RegistrableDomainVector&&);
    Seconds clientSideCookiesAgeCapForSwift() const;
    // The statistics actor interrupts each store it holds when it suspends.
    void interruptDatabaseForSwift() { interrupt(); }
    // grantStorageAccessInternal's checks of a prompted grant, in builds without NDEBUG; false when they stop it.
    bool checkPromptedStorageAccessGrantForSwift(const SubFrameDomain&, const TopFrameDomain&, CanRequestStorageAccessWithoutUserInteraction);
    NODELETE void cancelPendingStatisticsProcessingRequest();
    void runIncrementalVacuumCommand();
    void dumpResourceLoadStatistics(CompletionHandler<void(String)>&&);
    bool isNewResourceLoadStatisticsDatabaseFile() const { return m_isNewResourceLoadStatisticsDatabaseFile; }
    void setIsNewResourceLoadStatisticsDatabaseFile(bool isNewResourceLoadStatisticsDatabaseFile) { m_isNewResourceLoadStatisticsDatabaseFile = isNewResourceLoadStatisticsDatabaseFile; }


    std::optional<HashMap<RegistrableDomain, WallTime>> loadWebsitesWithUserInteraction();

    void setGrandfathered(RegistrableDomain, bool value);
    bool isGrandfathered(RegistrableDomain) const;
    NODELETE void setGrandfatheringTime(Seconds);

    bool isRegisteredAsSubresourceUnder(SubResourceDomain, TopFrameDomain) const;
    bool isRegisteredAsSubFrameUnder(SubFrameDomain, TopFrameDomain) const;
    bool isRegisteredAsRedirectingTo(RedirectedFromDomain, RedirectedToDomain) const;

    void clearPrevalentResource(RegistrableDomain);
    bool isPrevalentResource(RegistrableDomain) const;
    bool isVeryPrevalentResource(RegistrableDomain) const;
    void setPrevalentResource(RegistrableDomain);
    void setVeryPrevalentResource(RegistrableDomain);
    void setMostRecentWebPushInteractionTime(RegistrableDomain);

    void setSubframeUnderTopFrameDomain(SubFrameDomain, TopFrameDomain);
    void setSubresourceUnderTopFrameDomain(SubResourceDomain, TopFrameDomain);
    void setSubresourceUniqueRedirectTo(SubResourceDomain, RedirectDomain);
    void setSubresourceUniqueRedirectFrom(SubResourceDomain, RedirectDomain);
    void setTopFrameUniqueRedirectTo(TopFrameDomain, RedirectDomain);
    void setTopFrameUniqueRedirectFrom(TopFrameDomain, RedirectDomain);

    NODELETE void setIsRunningTest(bool);
    void setTimeAdvanceForTesting(Seconds);

    NODELETE void setMaxStatisticsEntries(size_t maximumEntryCount);
    NODELETE void setPruneEntriesDownTo(size_t pruneTargetCount);
    void resetParametersToDefaultValues();

    bool shouldSkip(RegistrableDomain) const;
    NODELETE void setShouldClassifyResourcesBeforeDataRecordsRemoval(bool);
    NODELETE void setTimeToLiveUserInteraction(Seconds);
    NODELETE void setMinimumTimeBetweenDataRecordsRemoval(Seconds);
    void setResourceLoadStatisticsDebugMode(bool);
    bool isDebugModeEnabled() const { return m_debugModeEnabled; };
    void setPrevalentResourceForDebugMode(RegistrableDomain);
    void setThirdPartyCookieBlockingMode(WebCore::ThirdPartyCookieBlockingMode mode) { m_thirdPartyCookieBlockingMode = mode; };
    WebCore::ThirdPartyCookieBlockingMode thirdPartyCookieBlockingMode() const { return m_thirdPartyCookieBlockingMode; };
    void setSameSiteStrictEnforcementEnabled(WebCore::SameSiteStrictEnforcementEnabled enabled) { m_sameSiteStrictEnforcementEnabled = enabled; };
    bool isSameSiteStrictEnforcementEnabled() const { return m_sameSiteStrictEnforcementEnabled == WebCore::SameSiteStrictEnforcementEnabled::Yes; };
    void setFirstPartyWebsiteDataRemovalMode(WebCore::FirstPartyWebsiteDataRemovalMode mode) { m_firstPartyWebsiteDataRemovalMode = mode; }
    WebCore::FirstPartyWebsiteDataRemovalMode firstPartyWebsiteDataRemovalMode() const { return m_firstPartyWebsiteDataRemovalMode; }
    void setPersistedDomains(HashSet<RegistrableDomain>&& domains) { m_persistedDomains = WTF::move(domains); }
    void setPersistedDomainsForSwift(RegistrableDomainVector&& domains) { setPersistedDomains(registrableDomainHashSetFromVector(WTF::move(domains))); }
    void setStandaloneApplicationDomain(RegistrableDomain&& domain) { m_standaloneApplicationDomain = WTF::move(domain); }
#if ENABLE(APP_BOUND_DOMAINS)
    void setAppBoundDomainsForSwift(Vector<RegistrableDomain>&&);
#endif
#if ENABLE(MANAGED_DOMAINS)
    void setManagedDomainsForSwift(Vector<RegistrableDomain>&&);
#endif

    enum class AddedRecord : bool { No, Yes };
    using AddedRecordAndDomainID = std::pair<AddedRecord, std::optional<unsigned>>;
    AddedRecordAndDomainID grantStorageAccessPermission(RegistrableDomain topFrameDomain, RegistrableDomain subFrameDomain);
    void revokeStorageAccessPermission(RegistrableDomain);

    void logFrameNavigation(NavigatedToDomain, TopFrameDomain, NavigatedFromDomain, bool isRedirect, bool isMainFrame, Seconds delayAfterMainFrameDocumentLoad, bool wasPotentiallyInitiatedByUser);
    void logCrossSiteLoadWithLinkDecoration(NavigatedFromDomain, NavigatedToDomain, DidFilterKnownLinkDecoration);

    bool hasHadUserInteraction(RegistrableDomain, OperatingDatesWindow);

    void setLastSeen(RegistrableDomain primaryDomain, Seconds);
    bool isCorrectSubStatisticsCount(RegistrableDomain, TopFrameDomain);

    void removeDataForDomain(RegistrableDomain);

    RegistrableDomainVector allDomains() const;
    HashMap<RegistrableDomain, WallTime> allDomainsWithLastAccessedTime() const;
    HashSet<RegistrableDomain> domainsExemptFromWebsiteDataDeletion() const;
    // The three above flattened for the actor's domain-list answers: domains, and their times in raw seconds, in the
    // map's or set's iteration order.
    void domainsWithLastAccessedTimeForSwift(RegistrableDomainVector& domains, StatisticsTimeVector& times) const;
    RegistrableDomainVector domainsExemptFromWebsiteDataDeletionForSwift() const { return copyToVector(domainsExemptFromWebsiteDataDeletion()); }
    // false where loadWebsitesWithUserInteraction() gives std::nullopt.
    bool websitesWithUserInteractionForSwift(RegistrableDomainVector& domains, StatisticsTimeVector& times);



    bool domainIDExistsInDatabase(int);
    bool observedDomainNavigationWithLinkDecoration(int);
    std::optional<Vector<String>> checkForMissingTablesInSchema();

    void includeTodayAsOperatingDateIfNecessary();
    void insertExpiredStatisticForTesting(RegistrableDomain, unsigned numberOfOperatingDaysPassed, bool hasUserInteraction,
        bool isScheduledForAllButCookieDataRemoval, bool);

    // Public: when DomainData is private, the Swift compiler crashes while serializing the module (in SerializeSILPass).
    struct DomainData {
        unsigned domainID;
        RegistrableDomain registrableDomain;
        WallTime mostRecentUserInteractionTime;
        WallTime mostRecentWebPushInteractionTime;
        bool hadUserInteraction;
        bool grandfathered;
        DataRemovalFrequency dataRemovalFrequency;
        unsigned topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement;
    };
    using DomainDataVector = Vector<DomainData>;
    DomainDataVector domains() const;

    // For Swift, which imports a returned reference as a pointer.
    static String string(const RegistrableDomain& domain) { return domain.string(); }
    // Domains a message carried, in wire order, in the order the C++ decoder's HashSet of them iterates.
    // An element equal to an earlier one (two lone-surrogate domains Swift made equal) is not added again.
    static RegistrableDomainVector inDecodedHashSetOrderForSwift(RegistrableDomainVector&& domains) { return copyToVector(registrableDomainHashSetFromVector(WTF::move(domains), 1024 * 1024 / sizeof(RegistrableDomain))); }

private:
    ResourceLoadStatisticsStore(ShouldIncludeLocalhost, const String& storageDirectoryPath, PAL::SessionID);


    struct Parameters {
        size_t pruneEntriesDownTo { 800 };
        size_t maxStatisticsEntries { 1000 };
        std::optional<Seconds> timeToLiveUserInteraction;
        Seconds minimumTimeBetweenDataRecordsRemoval { 1_h };
        Seconds grandfatheringTime { 24_h * 7 };
        Seconds cacheMaxAgeCapTime { 24_h * 7 };
        Seconds clientSideCookiesAgeCapTime { 24_h * 7 };
        Seconds clientSideCookiesForLinkDecorationTargetPageAgeCapTime { 24_h };
        Seconds minDelayAfterMainFrameDocumentLoadToNotBeARedirect { 5_s };
        size_t minimumTopFrameRedirectsForSameSiteStrictEnforcement { 10 };
        bool shouldClassifyResourcesBeforeDataRecordsRemoval { true };
        bool isRunningTest { false };
    };
    static String emptyString() { return WTF::emptyString(); }
    // For Swift, which does not accept a call named unchecked*.
    static RegistrableDomain registrableDomainFromHost(const String& host) { return RegistrableDomain::uncheckedCreateFromHost(host); }
    // For Swift, which sees StringBuilder::toString()'s reference result as a pointer: the builder's text, moved out.
    static String stringFromBuilder(StringBuilder&);
    static Seconds reduceTimeResolution(Seconds t) { return ResourceLoadStatistics::reduceTimeResolution(WallTime { } + t) - WallTime { }; }
    void clearEndOfGrandfatheringTimeStamp() { m_endOfGrandfatheringTimestamp = { }; }
    void debugBroadcastConsoleMessage(MessageSource, MessageLevel, const String& message);
    void debugLogDomainsInBatches(String action, RegistrableDomainVector, RegistrableDomainVector);
    bool debugLoggingEnabled() const { return m_debugLoggingEnabled; }
    bool debugModeEnabled() const { return m_debugModeEnabled; }
    bool shouldExemptFromWebsiteDataDeletion(const RegistrableDomain&) const;

    String getDomainStringFromDomainID(unsigned) const final;
    String dumpResourceLoadStatisticsText() const;
    void mergeStatistic(RegistrableDomain, WallTime lastSeen, bool hadUserInteraction, WallTime mostRecentUserInteractionTime, bool grandfathered, bool isPrevalentResource, bool isVeryPrevalentResource, unsigned dataRecordsRemoved, bool gotLinkDecorationFromPrevalentResource);
    void incrementRecordsDeletedCountForDomains(HashSet<RegistrableDomain>&&);
    [[nodiscard]] bool insertObservedDomainRecord(RegistrableDomain, double lastSeen, bool hadUserInteraction, double mostRecentUserInteractionTime, bool grandfathered, bool isPrevalent, bool isVeryPrevalent, unsigned dataRecordsRemoved, unsigned timesAccessedAsFirstPartyDueToUserInteraction, unsigned timesAccessedAsFirstPartyDueToStorageAccessAPI, bool gotLinkDecorationFromPrevalentResource);
    void insertDomainRelationshipsRecord(RegistrableDomain, RegistrableDomainVector storageAccessUnderTopFrameDomains,
        RegistrableDomainVector topFrameUniqueRedirectsTo, RegistrableDomainVector topFrameUniqueRedirectsToSinceSameSiteStrictEnforcement,
        RegistrableDomainVector topFrameUniqueRedirectsFrom, RegistrableDomainVector subframeUnderTopFrameDomains,
        RegistrableDomainVector subresourceUnderTopFrameDomains, RegistrableDomainVector subresourceUniqueRedirectsTo,
        RegistrableDomainVector subresourceUniqueRedirectsFrom, RegistrableDomainVector topFrameLinkDecorationsFrom,
        RegistrableDomainVector topFrameLoadedThirdPartyScripts);
    OptionalDomainID domainID(RegistrableDomain) const;
    bool domainExists(const RegistrableDomain&) const;
    void setUserInteraction(RegistrableDomain, bool hadUserInteraction, WallTime);
    bool logUserInteractionRecord(TopFrameDomain);
    void clearUserInteractionRecords(RegistrableDomain);
    void updateCookieBlockingWithoutCompletion();
    Vector<RegistrableDomain> domainsToBlockAndDeleteCookiesFor() const;
    Vector<RegistrableDomain> domainsToBlockButKeepCookiesFor() const;
    Vector<RegistrableDomain> domainsWithUserInteractionAsFirstParty() const;
    HashMap<TopFrameDomain, Vector<SubResourceDomain>> domainsWithStorageAccess() const;
    void updateObservedDomainsList(String updateClause, RegistrableDomainVector, String logContext);

    bool hasUserGrantedStorageAccessThroughPrompt(unsigned domainID, RegistrableDomain);

    // For Swift, which cannot spell a HashMap: the indexes of keys in the order a HashMap<unsigned, T> filled from them visits them.
    static DomainIDVector hashMapIterationOrder(DomainIDVector keys);

    CookieAccess cookieAccess(SubResourceDomain, TopFrameDomain, CanRequestStorageAccessWithoutUserInteraction);

    void classifyPrevalentResources();
    
    // reason is used for logging purpose.
    [[nodiscard]] AddedRecordAndDomainID ensureResourceStatisticsForRegistrableDomain(RegistrableDomain, String reason);
    RegistrableDomainsToDeleteOrRestrictWebsiteDataFor registrableDomainsToDeleteOrRestrictWebsiteDataFor();

    bool shouldRemoveDataRecords() const;
    void setDebugLogggingEnabled(bool enabled) { m_debugLoggingEnabled  = enabled; }
    Vector<RegistrableDomain> ensurePrevalentResourcesForDebugMode();
    void setDataRecordsBeingRemoved(bool);
    void setCacheMaxAgeCap(Seconds);
    void updateCacheMaxAgeCap();
    const MemoryCompactLookupOnlyRobinHoodHashMap<String, TableAndIndexPair>& expectedTableAndIndexQueries() final;
    std::span<const ASCIILiteral> sortedTables() final;
    void grandfatherDataForDomains(const HashSet<RegistrableDomain>&);
    void scheduleStatisticsProcessingRequestIfNecessary();
    void pruneStatisticsIfNeeded();

    void clearDatabaseContents();
    bool createUniqueIndices() final;
    bool createSchema() final;
    void addMissingTablesIfNecessary();
    bool missingUniqueIndices();
    bool needsUpdatedSchema() final;
    bool missingReferenceToObservedDomains();
    void migrateDataToPCMDatabaseIfNecessary();
    void openAndUpdateSchemaIfNecessary();
    bool tableExists(String);
    void deleteTable(StringView);
    void destroyStatements() final;

    // commitTransactionForSwift(true) commits what beginTransactionIfNecessaryForSwift() started.
    bool beginTransactionIfNecessaryForSwift();
    void commitTransactionForSwift(bool didBeginTransaction);
    void clearAppBoundDomainsForSwift() { m_appBoundDomains.clear(); }

    // DatabaseUtilities' members Swift calls: Swift imports none of a base class it cannot copy or move.
    bool openDatabaseAndCreateSchemaIfNecessaryForSwift() { return openDatabaseAndCreateSchemaIfNecessary() == CreatedNewFile::Yes; }
    // columnsForTable() and addMissingColumnToTable() take ASCIILiteral, which Swift cannot make.
    Vector<String> observedDomainsColumnsForSwift() { return columnsForTable("ObservedDomains"_s); }
    bool addMostRecentWebPushInteractionTimeColumnForSwift() { return addMissingColumnToTable("ObservedDomains"_s, "mostRecentWebPushInteractionTime REAL DEFAULT 0.0 NOT NULL"_s); }
    void migrateDataToNewTablesIfNecessaryForSwift() { migrateDataToNewTablesIfNecessary(); }
    void closeForSwift() { close(); }
    void deleteStorageFileForSwift() { FileSystem::deleteFile(m_storageFilePath); }
    String currentTableQueryForSwift(const String& table) { return currentTableAndIndexQueries(table).first; }

    // The columns of ObservedDomains, in the order of its CREATE TABLE and of CachedStatement.insertObservedDomain in Swift.
    enum class ObservedDomainsColumn : int {
        RegistrableDomain = 1,
        LastSeen = 2,
        HadUserInteraction = 3,
        MostRecentUserInteractionTime = 4,
        Grandfathered = 5,
        IsPrevalent = 6,
        IsVeryPrevalent = 7,
        DataRecordsRemoved = 8,
        TimesAccessedAsFirstPartyDueToUserInteraction = 9,
        TimesAccessedAsFirstPartyDueToStorageAccessAPI = 10,
        IsScheduledForAllButCookieDataRemoval = 11,
        MostRecentWebPushInteractionTime = 12,
    };
    // For missingUniqueIndices(): createUniqueIndices()'s 12 commands, plus the index SQLite makes for ObservedDomains.
    static constexpr int expectedIndexCount() { return 13; }

    // The SQLite access of ResourceLoadStatisticsStore.swift, through handles that the .cpp checks on every use.
    // The statement cached in slot index, prepared from query on its first use.
    SQLStatementHandle prepareCachedStatement(uint8_t index, const String& query, const String& logLabel) const;
    SQLStatementHandle openStatement(String query) const;
    void closeStatement(SQLStatementHandle) const;
    int bindInt(SQLStatementHandle, int index, int value) const;
    int bindText(SQLStatementHandle, int index, String value) const;
    int bindDouble(SQLStatementHandle, int index, double value) const;
    int step(SQLStatementHandle) const;
    int reset(SQLStatementHandle) const;
    int columnInt(SQLStatementHandle, int column) const;
    String columnText(SQLStatementHandle, int column) const;
    double columnDouble(SQLStatementHandle, int column) const;
    int databaseLastError() const { return m_database->lastError(); }
    String databaseLastErrorMsg() const { return String::fromLatin1(m_database->lastErrorMsg()); }
    int databaseRunIncrementalVacuumCommand() const { return m_database->runIncrementalVacuumCommand(); }
    void databaseClearAllTables() const { m_database->clearAllTables(); }

#if HAVE(CORE_PREDICTION)
    ResourceLoadStatisticsClassifierCocoa m_resourceLoadStatisticsClassifier;
#else
    ResourceLoadStatisticsClassifier m_resourceLoadStatisticsClassifier;
#endif
    Parameters m_parameters;
    WallTime m_endOfGrandfatheringTimestamp;
    RegistrableDomain m_debugManualPrevalentResource;
    MonotonicTime m_lastTimeDataRecordsWereRemoved;
    uint64_t m_lastStatisticsProcessingRequestIdentifier { 0 };
    std::optional<uint64_t> m_pendingStatisticsProcessingRequestIdentifier;
    const RegistrableDomain m_debugStaticPrevalentResource { URL { "https://3rdpartytestwebkit.org"_str } };
    RegistrableDomain m_standaloneApplicationDomain;
    HashSet<RegistrableDomain> m_appBoundDomains;
    HashSet<RegistrableDomain> m_managedDomains;
    HashSet<RegistrableDomain> m_persistedDomains;
    struct __attribute__((availability(swift, unavailable))) StatementSlot {
        std::unique_ptr<WebCore::SQLiteStatement> statement;
        uint64_t generation { 1 };
    };
    mutable Vector<StatementSlot> m_statements __attribute__((availability(swift, unavailable))) { Vector<StatementSlot>(resourceLoadStatisticsCachedStatementCount) };

    Vector<CompletionHandler<void(ResourceLoadStatisticsStore&)>> m_dataRecordRemovalCompletionHandlers;
    StatisticsStorePostVector m_pendingPosts;
    Seconds m_timeAdvanceForTesting;

    PAL::SessionID m_sessionID;
    unsigned m_operatingDatesSize { 0 };
    std::optional<OperatingDate> m_longWindowOperatingDate;
    std::optional<OperatingDate> m_shortWindowOperatingDate;
    OperatingDate m_mostRecentOperatingDate;
    WebCore::ThirdPartyCookieBlockingMode m_thirdPartyCookieBlockingMode { WebCore::ThirdPartyCookieBlockingMode::All };
    WebCore::SameSiteStrictEnforcementEnabled m_sameSiteStrictEnforcementEnabled { WebCore::SameSiteStrictEnforcementEnabled::No };
    WebCore::FirstPartyWebsiteDataRemovalMode m_firstPartyWebsiteDataRemovalMode { WebCore::FirstPartyWebsiteDataRemovalMode::AllButCookies };
    ShouldIncludeLocalhost m_shouldIncludeLocalhost { ShouldIncludeLocalhost::Yes };
    bool m_debugLoggingEnabled { false };
    bool m_debugModeEnabled { false };
    bool m_dataRecordsBeingRemoved { false };
    bool m_isNewResourceLoadStatisticsDatabaseFile { false };
};

} // namespace WebKit
