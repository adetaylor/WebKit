/*
 * Copyright (C) 2016-2025 Apple Inc. All rights reserved.
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

#include "Decoder.h"
#include "Encoder.h"
#include "ShouldGrandfatherStatistics.h"
#include "StorageAccessStatus.h"
#include "WebPageProxyIdentifier.h"
#include "WebsiteDataType.h"
#include <WebCore/DocumentStorageAccess.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/IsLoggedIn.h>
#include <WebCore/OrganizationStorageAccessPromptQuirk.h>
#include <WebCore/PermissionState.h>
#include <WebCore/ResourceLoadObserver.h>
#include <WebCore/ThirdPartyCookieBlockingMode.h>
#include <WebCore/TrackingPreventionTypes.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Condition.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/Forward.h>
#include <wtf/Lock.h>
#include <wtf/RunLoop.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class LoginStatus;
class ResourceRequest;
struct ResourceLoadStatistics;
enum class ShouldSample : bool;
enum class IncludeHttpOnlyCookies : bool;
enum class ThirdPartyCookieBlockingMode : uint8_t;
}

namespace WebKit {

class NetworkProcess;
class NetworkSession;
class StorageAccessPermissionChangeObserver;
class ResourceLoadStatisticsStore;
class WebFrameProxy;
class WebProcessProxy;
enum class CanRequestStorageAccessWithoutUserInteraction : bool;
enum class DidFilterKnownLinkDecoration : bool;

enum class ShouldIncludeLocalhost : bool { No, Yes };
enum class EnableResourceLoadStatisticsDebugMode : bool { No, Yes };

using TopFrameDomain = WebCore::RegistrableDomain;
using SubResourceDomain = WebCore::RegistrableDomain;
// Swift cannot spell a std::optional specialization, so it holds the prompt's quirk under this name.
using StorageAccessPromptQuirkForSwift = std::optional<WebCore::OrganizationStorageAccessPromptQuirk>;

struct RegistrableDomainsToBlockCookiesFor {
    Vector<WebCore::RegistrableDomain> domainsToBlockAndDeleteCookiesFor;
    Vector<WebCore::RegistrableDomain> domainsToBlockButKeepCookiesFor;
    Vector<WebCore::RegistrableDomain> domainsWithUserInteractionAsFirstParty;
    HashMap<TopFrameDomain, Vector<SubResourceDomain>> domainsWithStorageAccess;
    bool isEmpty() const { return domainsToBlockAndDeleteCookiesFor.isEmpty() && domainsToBlockButKeepCookiesFor.isEmpty() && domainsWithUserInteractionAsFirstParty.isEmpty() && domainsWithStorageAccess.isEmpty(); }
    RegistrableDomainsToBlockCookiesFor isolatedCopy() const & { return { crossThreadCopy(domainsToBlockAndDeleteCookiesFor), crossThreadCopy(domainsToBlockButKeepCookiesFor), crossThreadCopy(domainsWithUserInteractionAsFirstParty), crossThreadCopy(domainsWithStorageAccess) }; }
    // The map as parallel lists, and back, for the statistics actor's main part (WebResourceLoadStatisticsStore.swift).
    void appendDomainsWithStorageAccessForSwift(Vector<WebCore::RegistrableDomain>& topFrameDomains, Vector<WebCore::RegistrableDomain>& subResourceDomains) const
    {
        for (auto& [topFrameDomain, subResourceDomainsOfTopFrame] : domainsWithStorageAccess) {
            for (auto& subResourceDomain : subResourceDomainsOfTopFrame) {
                topFrameDomains.append(topFrameDomain);
                subResourceDomains.append(subResourceDomain);
            }
        }
    }
    void addDomainWithStorageAccessForSwift(const WebCore::RegistrableDomain& topFrameDomain, const WebCore::RegistrableDomain& subResourceDomain)
    {
        domainsWithStorageAccess.add(topFrameDomain, Vector<WebCore::RegistrableDomain> { }).iterator->value.append(subResourceDomain);
    }
    RegistrableDomainsToBlockCookiesFor isolatedCopy() && { return { crossThreadCopy(WTF::move(domainsToBlockAndDeleteCookiesFor)), crossThreadCopy(WTF::move(domainsToBlockButKeepCookiesFor)), crossThreadCopy(WTF::move(domainsWithUserInteractionAsFirstParty)), crossThreadCopy(WTF::move(domainsWithStorageAccess)) }; }
};
struct RegistrableDomainsToDeleteOrRestrictWebsiteDataFor {
    Vector<WebCore::RegistrableDomain> domainsToDeleteAllCookiesFor;
    Vector<WebCore::RegistrableDomain> domainsToDeleteAllButHttpOnlyCookiesFor;
    Vector<WebCore::RegistrableDomain> domainsToDeleteAllScriptWrittenStorageFor;
    Vector<WebCore::RegistrableDomain> domainsToEnforceSameSiteStrictFor;
    RegistrableDomainsToDeleteOrRestrictWebsiteDataFor isolatedCopy() const & { return { crossThreadCopy(domainsToDeleteAllCookiesFor), crossThreadCopy(domainsToDeleteAllButHttpOnlyCookiesFor), crossThreadCopy(domainsToDeleteAllScriptWrittenStorageFor), crossThreadCopy(domainsToEnforceSameSiteStrictFor) }; }
    RegistrableDomainsToDeleteOrRestrictWebsiteDataFor isolatedCopy() && { return { crossThreadCopy(WTF::move(domainsToDeleteAllCookiesFor)), crossThreadCopy(WTF::move(domainsToDeleteAllButHttpOnlyCookiesFor)), crossThreadCopy(WTF::move(domainsToDeleteAllScriptWrittenStorageFor)), crossThreadCopy(WTF::move(domainsToEnforceSameSiteStrictFor)) }; }
    bool isEmpty() const { return domainsToDeleteAllCookiesFor.isEmpty() && domainsToDeleteAllButHttpOnlyCookiesFor.isEmpty() && domainsToDeleteAllScriptWrittenStorageFor.isEmpty() && domainsToEnforceSameSiteStrictFor.isEmpty(); }
};

// Runs and forgets suspend()'s handler waiting under `identifier`; the statistics inbox calls it once suspended.
SWIFT_MAIN_ACTOR void completeStatisticsSuspendForSwift(uint64_t identifier);

// Runs the statistics actor's main-thread post waiting under `identifier` from the main run loop, behind what is
// already queued there, IPC messages included.
void dispatchOnMainRunLoopForStatistics(uint64_t identifier);

// The completion handlers of the store members the statistics actor calls, named so that Swift can build them
// (WTFCompletionHandler+Extras.swift; WebResourceLoadStatisticsStore.swift, StatisticsActor).
using StorageAccessStatusCompletionHandler = CompletionHandler<void(StorageAccessStatus)>;
using StorageAccessWasGrantedCompletionHandler = CompletionHandler<void(WebCore::StorageAccessWasGranted)>;
using StatisticsStringCompletionHandler = CompletionHandler<void(String)>;
// The domains a main part answers with, move-only so that its handler takes them by rvalue reference and Swift
// conforms it as a consuming handler, which has no continuation initializer to carry the domains to another thread.
struct StatisticsRegistrableDomains {
    explicit StatisticsRegistrableDomains(Vector<WebCore::RegistrableDomain>&& domains)
        : domains(WTF::move(domains))
    {
    }
    StatisticsRegistrableDomains(StatisticsRegistrableDomains&&) = default;
    StatisticsRegistrableDomains(const StatisticsRegistrableDomains&) = delete;
    StatisticsRegistrableDomains& operator=(const StatisticsRegistrableDomains&) = delete;

    Vector<WebCore::RegistrableDomain> domains;
};
using StatisticsTimeVector = Vector<double>;
// Values, not rvalue references: Swift's handler bridge refuses those (CompletionHandler.h static_assert).
using StatisticsDomainListCompletionHandler = CompletionHandler<void(bool hasValue, Vector<WebCore::RegistrableDomain>, StatisticsTimeVector)>;
using RegistrableDomainVectorCompletionHandler = CompletionHandler<void(StatisticsRegistrableDomains&&)>;

class SWIFT_PRIVATE_FILEID("WebKit/WebResourceLoadStatisticsStore.swift") WebResourceLoadStatisticsStore final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<WebResourceLoadStatisticsStore, WTF::DestructionThread::Main>, public CanMakeThreadSafeCheckedPtr<WebResourceLoadStatisticsStore> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(WebResourceLoadStatisticsStore);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(WebResourceLoadStatisticsStore);
public:
    using ResourceLoadStatistics = WebCore::ResourceLoadStatistics;
    using RegistrableDomain = WebCore::RegistrableDomain;
    using TopFrameDomain = WebCore::RegistrableDomain;
    using SubFrameDomain = WebCore::RegistrableDomain;
    using SubResourceDomain = WebCore::RegistrableDomain;
    using RedirectDomain = WebCore::RegistrableDomain;
    using NavigatedFromDomain = WebCore::RegistrableDomain;
    using NavigatedToDomain = WebCore::RegistrableDomain;
    using DomainInNeedOfStorageAccess = WebCore::RegistrableDomain;
    using OpenerDomain = WebCore::RegistrableDomain;
    using StorageAccessWasGranted = WebCore::StorageAccessWasGranted;
    using StorageAccessScope = WebCore::StorageAccessScope;
    using IsLoggedIn = WebCore::IsLoggedIn;
    using LoginStatus = WebCore::LoginStatus;

    static Ref<WebResourceLoadStatisticsStore> create(NetworkSession&, const String& resourceLoadStatisticsDirectory, ShouldIncludeLocalhost, ResourceLoadStatistics::IsEphemeral);

    ~WebResourceLoadStatisticsStore();

    void didDestroyNetworkSession(CompletionHandler<void()>&&);

    static const OptionSet<WebsiteDataType>& monitoredDataTypes();


    // Defined in WebResourceLoadStatisticsStore.swift.
    SWIFT_MAIN_ACTOR void populateMemoryStoreFromDisk();
    void loadWebsitesWithUserInteraction(CompletionHandler<void(std::optional<HashMap<RegistrableDomain, WallTime>>&&)>&&);

    void logCrossSiteLoadWithLinkDecoration(NavigatedFromDomain&&, NavigatedToDomain&&, DidFilterKnownLinkDecoration, CompletionHandler<void()>&&);
    void removeDataForDomain(const RegistrableDomain, CompletionHandler<void()>&&);
    void deleteAndRestrictWebsiteDataForRegistrableDomains(OptionSet<WebsiteDataType>, RegistrableDomainsToDeleteOrRestrictWebsiteDataFor&&, CompletionHandler<void(HashSet<RegistrableDomain>&&)>&&);
    void registrableDomains(CompletionHandler<void(Vector<RegistrableDomain>&&)>&&);
    void registrableDomainsWithLastAccessedTime(CompletionHandler<void(std::optional<HashMap<RegistrableDomain, WallTime>>&&)>&&);
    void registrableDomainsExemptFromWebsiteDataDeletion(CompletionHandler<void(HashSet<RegistrableDomain>&&)>&&);
    void registrableDomainsWithWebsiteData(OptionSet<WebsiteDataType>, CompletionHandler<void(HashSet<RegistrableDomain>&&)>&&);
    StorageAccessWasGranted grantStorageAccessInStorageSession(const SubFrameDomain&, const TopFrameDomain&, std::optional<WebCore::FrameIdentifier>, WebPageProxyIdentifier, StorageAccessScope);
    bool hasStorageAccessForFrame(const SubFrameDomain&, const TopFrameDomain&, WebCore::FrameIdentifier, WebPageProxyIdentifier);
    void setLoginStatus(RegistrableDomain&&, IsLoggedIn, std::optional<LoginStatus>&&);
    bool isLoggedIn(const RegistrableDomain&) const;
    void setMostRecentWebPushInteractionTime(RegistrableDomain&&, CompletionHandler<void()>&&);
    void scheduleCookieBlockingUpdateForDomains(const Vector<RegistrableDomain>&, CompletionHandler<void()>&&);
    void scheduleClearInMemoryAndPersistent(ShouldGrandfatherStatistics, CompletionHandler<void()>&&);
    void scheduleClearInMemoryAndPersistent(WallTime modifiedSince, ShouldGrandfatherStatistics, CompletionHandler<void()>&&);
    void clearInMemoryEphemeral();

    void setCacheMaxAgeCap(Seconds, CompletionHandler<void()>&&);

    // Defined in WebResourceLoadStatisticsStore.swift.
    SWIFT_MAIN_ACTOR void setResourceLoadStatisticsDebugMode(bool);
    void setTrackingPreventionDebugLoggingEnabled(bool);
    // Defined in WebResourceLoadStatisticsStore.swift.
    SWIFT_MAIN_ACTOR void setPrevalentResourceForDebugMode(RegistrableDomain);

    void logTestingEvent(const String&);
    void callGrantStorageAccessHandler(const SubFrameDomain&, const TopFrameDomain&, std::optional<WebCore::FrameIdentifier>, WebPageProxyIdentifier, StorageAccessScope, CompletionHandler<void(StorageAccessWasGranted)>&&);
    void removeAllStorageAccess(CompletionHandler<void()>&&);
    bool needsUserInteractionQuirk(const RegistrableDomain&) const;
    void callUpdatePrevalentDomainsToBlockCookiesForHandler(const RegistrableDomainsToBlockCookiesFor&, CompletionHandler<void()>&&);
    void callHasStorageAccessForFrameHandler(const SubFrameDomain&, const TopFrameDomain&, WebCore::FrameIdentifier, WebPageProxyIdentifier, CompletionHandler<void(bool)>&&);

    void hasCookies(const RegistrableDomain&, CompletionHandler<void(bool)>&&);
    void setThirdPartyCookieBlockingMode(WebCore::ThirdPartyCookieBlockingMode);
    // Defined in WebResourceLoadStatisticsStore.swift.
    SWIFT_MAIN_ACTOR void setSameSiteStrictEnforcementEnabled(WebCore::SameSiteStrictEnforcementEnabled);
    SWIFT_MAIN_ACTOR void setFirstPartyWebsiteDataRemovalMode(WebCore::FirstPartyWebsiteDataRemovalMode);
    SWIFT_MAIN_ACTOR void setStandaloneApplicationDomain(RegistrableDomain);
#if ENABLE(APP_BOUND_DOMAINS)
    void setAppBoundDomains(HashSet<RegistrableDomain>&&, CompletionHandler<void()>&&);
#endif
#if ENABLE(MANAGED_DOMAINS)
    void setManagedDomains(HashSet<RegistrableDomain>&&, CompletionHandler<void()>&&);
#endif
    // Defined in WebResourceLoadStatisticsStore.swift.
    SWIFT_MAIN_ACTOR void setPersistedDomains(Vector<RegistrableDomain>);

    NODELETE NetworkSession* networkSession();
    NODELETE void invalidateAndCancel();

    static void suspend(NetworkProcess&, CompletionHandler<void()>&&);
    static void resume(NetworkProcess&);
    
    bool isEphemeral() const { return m_isEphemeral == WebCore::ResourceLoadStatistics::IsEphemeral::Yes; };
    void recordFrameLoadForStorageAccess(WebPageProxyIdentifier, WebCore::FrameIdentifier, const WebCore::RegistrableDomain&);
    void clearFrameLoadRecordsForStorageAccess(WebCore::FrameIdentifier);
    void clearFrameLoadRecordsForStorageAccess(WebPageProxyIdentifier);

    void wasRevokedStorageAccessPermissionInPage(WebPageProxyIdentifier);

    void startListeningForStorageAccessPermissionChanges(StorageAccessPermissionChangeObserver&, TopFrameDomain&&, SubFrameDomain&&);
    void stopListeningForStorageAccessPermissionChanges(StorageAccessPermissionChangeObserver&, TopFrameDomain&&, SubFrameDomain&&);
    void stopListeningForStorageAccessPermissionChanges(StorageAccessPermissionChangeObserver&);

    // Main-thread members the Swift message handlers call; public because SWIFT_PRIVATE_FILEID names WebResourceLoadStatisticsStore.swift, not the handlers' file.
    SWIFT_MAIN_ACTOR bool hasNetworkSession() const { return !!m_networkSession; }
    SWIFT_MAIN_ACTOR CanRequestStorageAccessWithoutUserInteraction canRequestStorageAccessWithoutUserInteraction(const SubFrameDomain&, const TopFrameDomain&);
    SWIFT_MAIN_ACTOR bool hasEphemeralUserInteraction(const RegistrableDomain& domain) const { return m_domainsWithEphemeralUserInteraction.contains(domain); }
    SWIFT_MAIN_ACTOR StorageAccessPromptQuirkForSwift storageAccessQuirk(const SubFrameDomain&, const TopFrameDomain&);
    // The prompt's answer completes the Swift reply waiting under `replyIdentifier` (completeStatisticsBoolReplyForSwift).
    SWIFT_MAIN_ACTOR void requestStorageAccessConfirm(WebPageProxyIdentifier, WebCore::FrameIdentifier, const SubFrameDomain&, const TopFrameDomain&, StorageAccessPromptQuirkForSwift&&, uint64_t replyIdentifier);
    SWIFT_MAIN_ACTOR StorageAccessWasGranted grantStorageAccessInEphemeralStorageSession(const SubFrameDomain&, const TopFrameDomain&, WebCore::FrameIdentifier, WebPageProxyIdentifier);
    SWIFT_MAIN_ACTOR StorageAccessWasGranted storageAccessWasGrantedValueForFrame(WebCore::FrameIdentifier, const WebCore::RegistrableDomain&);
    SWIFT_MAIN_ACTOR bool isStorageAccessPermissionGrantedInPage(WebPageProxyIdentifier, const TopFrameDomain&, const SubFrameDomain&) const;
    SWIFT_MAIN_ACTOR void wasGrantedStorageAccessPermissionInPage(WebPageProxyIdentifier, const RegistrableDomain& topFrameDomain, const RegistrableDomain& subFrameDomain);
    SWIFT_MAIN_ACTOR bool hasStorageAccessEphemeral(const SubFrameDomain&, const TopFrameDomain&, std::optional<WebCore::FrameIdentifier>, WebPageProxyIdentifier);
    SWIFT_MAIN_ACTOR void requestStorageAccessUnderOpenerEphemeral(DomainInNeedOfStorageAccess&&, WebPageProxyIdentifier openerWebPageProxyID, OpenerDomain&&);
    SWIFT_MAIN_ACTOR void logUserInteractionEphemeral(const TopFrameDomain&);
    SWIFT_MAIN_ACTOR void clearUserInteractionEphemeral(const RegistrableDomain&);
    SWIFT_MAIN_ACTOR void resetStorageSessionDomainsToDefaultValues();

    // The statistics actor's main parts (WebResourceLoadStatisticsStore.swift): the HashSet answers as a Vector,
    // since a HashSet argument imports as unsafe.
    SWIFT_MAIN_ACTOR void deleteAndRestrictWebsiteDataForRegistrableDomainsForSwift(RegistrableDomainsToDeleteOrRestrictWebsiteDataFor&&, RegistrableDomainVectorCompletionHandler&&);
    SWIFT_MAIN_ACTOR void registrableDomainsWithWebsiteDataForSwift(RegistrableDomainVectorCompletionHandler&&);
    SWIFT_MAIN_ACTOR void setAgeCapForClientSideCookiesForSwift(Seconds);
    // A storage-access grant's main part: the quirk's other (top frame, subframe) pairs, as parallel lists in the
    // quirk's order, and whether the pair may ask without prior user interaction.
    SWIFT_MAIN_ACTOR CanRequestStorageAccessWithoutUserInteraction storageAccessQuirkGrantsForSwift(const SubFrameDomain&, const TopFrameDomain&, bool& hasQuirk, Vector<RegistrableDomain>& topFrameDomains, Vector<RegistrableDomain>& subFrameDomains);
    // The key of this store's session in the statistics actor's table.
    SWIFT_MAIN_ACTOR uint64_t statisticsSessionIDForSwift() const { return m_statisticsSessionID; }
    // A console message the store posted (StatisticsStorePost), with JSC::MessageSource and JSC::MessageLevel as their raw values.
    SWIFT_MAIN_ACTOR void broadcastConsoleMessageForSwift(uint8_t source, uint8_t level, const String& message);
    // Hands the measurements the store migrated (StatisticsStorePost) to this session's manager; an unknown or
    // already taken identifier does nothing. Defined beside its table in ResourceLoadStatisticsStore.cpp.
    SWIFT_MAIN_ACTOR void migratePrivateClickMeasurementForSwift(uint64_t identifier);
    // Runs and forgets the statistics actor's main-thread post waiting under `identifier`; an unknown identifier does
    // nothing. Defined in WebResourceLoadStatisticsStore.swift.
    SWIFT_MAIN_ACTOR static void runStatisticsMainPostForSwift(uint64_t identifier);
    // Runs and forgets the Swift reply waiting under `identifier` for a main-side Bool answer (the storage-access
    // prompt, NetworkConnectionToWebProcess::hasCookiesForSwift); an unknown identifier does nothing. Defined in
    // WebResourceLoadStatisticsStore+StorageAccess.swift.
    SWIFT_MAIN_ACTOR static void completeStatisticsBoolReplyForSwift(uint64_t identifier, bool value);
    // The statistics actor's entries, defined in WebResourceLoadStatisticsStore.swift: each enqueues its request. A
    // C++ caller's handler waits in m_pendingCompletions under the identifier an entry takes, until the reply runs it.
    SWIFT_MAIN_ACTOR void createStatisticsStoreForSwift(String directory, bool includeLocalhost);
    SWIFT_MAIN_ACTOR void destroyStatisticsStoreForSwift(uint64_t completionIdentifier);
    // Runs and forgets the handler waiting under `identifier`.
    SWIFT_MAIN_ACTOR void completePendingCompletionForSwift(uint64_t identifier);
    // As that, for a domain-list handler: `times` is empty or parallel to `domains`, in raw seconds.
    SWIFT_MAIN_ACTOR void completePendingDomainListForSwift(uint64_t identifier, bool hasValue, const Vector<WebCore::RegistrableDomain>& domains, const StatisticsTimeVector& times);
    // kind: 0 all domains, 1 with last accessed time, 2 exempt from website data deletion, 3 with user interaction.
    SWIFT_MAIN_ACTOR void domainListForSwift(uint8_t kind, uint64_t completionIdentifier);
    SWIFT_MAIN_ACTOR void scheduleClearInMemoryAndPersistentForSwift(bool shouldGrandfather, uint64_t completionIdentifier);
#if ENABLE(APP_BOUND_DOMAINS)
    SWIFT_MAIN_ACTOR void setAppBoundDomainsOnStatisticsActorForSwift(Vector<WebCore::RegistrableDomain>, uint64_t completionIdentifier);
#endif
#if ENABLE(MANAGED_DOMAINS)
    SWIFT_MAIN_ACTOR void setManagedDomainsOnStatisticsActorForSwift(Vector<WebCore::RegistrableDomain>, uint64_t completionIdentifier);
#endif
    // The C++ callers' requests: the store work of the member of the same name, then, where there is one, the
    // handler waiting under `completionIdentifier`.
    SWIFT_MAIN_ACTOR void setThirdPartyCookieBlockingModeForSwift(WebCore::ThirdPartyCookieBlockingMode);
    SWIFT_MAIN_ACTOR void logCrossSiteLoadWithLinkDecorationForSwift(RegistrableDomain fromDomain, RegistrableDomain toDomain, bool didFilterKnownLinkDecoration, uint64_t completionIdentifier);
    SWIFT_MAIN_ACTOR void setMostRecentWebPushInteractionTimeForSwift(RegistrableDomain, uint64_t completionIdentifier);
    SWIFT_MAIN_ACTOR void removeDataForDomainForSwift(RegistrableDomain, uint64_t completionIdentifier);
    // The IPC handlers' (NetworkProcess+StatisticsDomains.swift): setAppBoundDomains() and setManagedDomains() on the
    // set of the domains, in their order.
#if ENABLE(APP_BOUND_DOMAINS)
    SWIFT_MAIN_ACTOR void setAppBoundDomainsForSwift(Vector<RegistrableDomain>&&, CompletionHandler<void()>&&);
#endif
#if ENABLE(MANAGED_DOMAINS)
    SWIFT_MAIN_ACTOR void setManagedDomainsForSwift(Vector<RegistrableDomain>&&, CompletionHandler<void()>&&);
#endif

private:
    explicit WebResourceLoadStatisticsStore(NetworkSession&, const String&, ShouldIncludeLocalhost, WebCore::ResourceLoadStatistics::IsEphemeral);

    // Defined in WebResourceLoadStatisticsStore.swift; the daily tasks timer's.
    SWIFT_MAIN_ACTOR void performDailyTasks();

    void didGrantPageLevelStorageAccess(WebPageProxyIdentifier, const WebCore::RegistrableDomain& topFrameDomain, const WebCore::RegistrableDomain& subFrameDomain);

    StorageAccessStatus storageAccessStatus(const String& subFramePrimaryDomain, const String& topFramePrimaryDomain);

    void destroyResourceLoadStatisticsStore(CompletionHandler<void()>&&);
    uint64_t addPendingCompletion(CompletionHandler<void()>&&);
    uint64_t addPendingDomainListCompletion(StatisticsDomainListCompletionHandler&&);

    WeakPtr<NetworkSession> m_networkSession;
    const uint64_t m_statisticsSessionID;

    RunLoop::Timer m_dailyTasksTimer;

    HashMap<uint64_t, CompletionHandler<void()>> m_pendingCompletions;
    HashMap<uint64_t, StatisticsDomainListCompletionHandler> m_pendingDomainListCompletions;
    uint64_t m_lastPendingCompletionIdentifier { 0 };

    WebCore::ResourceLoadStatistics::IsEphemeral m_isEphemeral { WebCore::ResourceLoadStatistics::IsEphemeral::No };
    HashSet<RegistrableDomain> m_domainsWithEphemeralUserInteraction;

    HashSet<RegistrableDomain> m_domainsWithUserInteractionQuirk;
    HashMap<TopFrameDomain, Vector<SubResourceDomain>> m_domainsWithCrossPageStorageAccessQuirk;
    HashMap<RegistrableDomain, std::pair<IsLoggedIn, std::optional<WebCore::LoginStatus>>> m_loginStatus;
    HashMap<WebPageProxyIdentifier, HashSet<std::pair<TopFrameDomain, SubFrameDomain>>> m_domainsGrantedStorageAccessPermissionInPage;

    struct StorageAccessRequestRecordValue {
        Markable<WebPageProxyIdentifier> webPageProxyID;
        Markable<WallTime> lastRequestTime;
        WallTime lastLoadTime;
    };
    using StorageAccessRequestRecordKey = std::pair<WebCore::FrameIdentifier, RegistrableDomain>;
    HashMap<StorageAccessRequestRecordKey, StorageAccessRequestRecordValue> m_storageAccessRequestRecords;
    HashMap<std::pair<RegistrableDomain, RegistrableDomain>, WeakHashSet<StorageAccessPermissionChangeObserver>> m_storageAccessPermissionChangeObservers;
};

} // namespace WebKit
