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

#include "config.h"
#include "WebResourceLoadStatisticsStore.h"

#include "APIDictionary.h"
#include "Logging.h"
#include "NetworkProcess.h"
#include "NetworkProcessProxyMessages.h"
#include "NetworkSession.h"
#include "PrivateClickMeasurementManager.h"
#include "ResourceLoadStatisticsStore.h"
#include "ShouldGrandfatherStatistics.h"
#include "StorageAccessPermissionChangeObserver.h"
#include "StorageAccessStatus.h"
#include "WebFrameProxy.h"
#include "WebPageProxy.h"
#include "WebProcessMessages.h"
#include "WebProcessPool.h"
#include "WebProcessProxy.h"
#include "WebsiteDataFetchOption.h"
#include <WebCore/CookieJar.h>
#include <WebCore/DiagnosticLoggingClient.h>
#include <WebCore/DiagnosticLoggingKeys.h>
#include <WebCore/IsLoggedIn.h>
#include <WebCore/LoginStatus.h>
#include <WebCore/ResourceLoadStatistics.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SQLiteFileSystem.h>
#include <WebCore/SQLiteStatement.h>
#include <WebCore/StorageAccessQuirks.h>
#include <wtf/Borrow.h>
#include <wtf/CallbackAggregator.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/threads/BinarySemaphore.h>

namespace WebKit {
using namespace WebCore;

const OptionSet<WebsiteDataType>& WebResourceLoadStatisticsStore::monitoredDataTypes()
{
    static NeverDestroyed<OptionSet<WebsiteDataType>> dataTypes(std::initializer_list<WebsiteDataType>({
        WebsiteDataType::Cookies,
        WebsiteDataType::DOMCache,
        WebsiteDataType::IndexedDBDatabases,
        WebsiteDataType::LocalStorage,
        WebsiteDataType::MediaKeys,
        WebsiteDataType::SearchFieldRecentSearches,
        WebsiteDataType::SessionStorage,
        WebsiteDataType::ServiceWorkerRegistrations,
        WebsiteDataType::FileSystem,
#if ENABLE(SCREEN_TIME)
        WebsiteDataType::ScreenTime,
#endif
        WebsiteDataType::EnhancedSecurityRecord
    }));

    ASSERT(RunLoop::isMain());

    return dataTypes;
}

// suspend()'s handlers, waiting for the statistics inbox to suspend (WebResourceLoadStatisticsStore.swift).
static HashMap<uint64_t, CompletionHandler<void()>>& pendingSuspendCompletions() WTF_REQUIRES_CAPABILITY(mainRunLoop)
{
    static NeverDestroyed<HashMap<uint64_t, CompletionHandler<void()>>> completions;
    return completions.get();
}

static uint64_t lastPendingSuspendCompletionIdentifier WTF_GUARDED_BY_CAPABILITY(mainRunLoop);

void completeStatisticsSuspendForSwift(uint64_t identifier)
{
    assertIsMainRunLoop();

    if (auto completionHandler = pendingSuspendCompletions().take(identifier))
        completionHandler();
}

void dispatchOnMainRunLoopForStatistics(uint64_t identifier)
{
    RunLoop::mainSingleton().dispatch([identifier] {
        WebResourceLoadStatisticsStore::runStatisticsMainPostForSwift(identifier);
    });
}

WebResourceLoadStatisticsStore::WebResourceLoadStatisticsStore(NetworkSession& networkSession, const String& resourceLoadStatisticsDirectory, ShouldIncludeLocalhost shouldIncludeLocalhost, ResourceLoadStatistics::IsEphemeral isEphemeral)
    : m_networkSession(networkSession)
    , m_statisticsSessionID(networkSession.sessionID().toUInt64())
    , m_dailyTasksTimer(RunLoop::mainSingleton(), "WebResourceLoadStatisticsStore::DailyTasksTimer"_s, this, &WebResourceLoadStatisticsStore::performDailyTasks)
    , m_isEphemeral(isEphemeral)
{
    RELEASE_ASSERT(RunLoop::isMain());

    // No daily tasks needed for ephemeral sessions since no resource load statistics are collected.
    if (isEphemeral == ResourceLoadStatistics::IsEphemeral::Yes)
        return;

    if (!resourceLoadStatisticsDirectory.isEmpty()) {
        createStatisticsStoreForSwift(resourceLoadStatisticsDirectory, shouldIncludeLocalhost == ShouldIncludeLocalhost::Yes);
        m_dailyTasksTimer.startRepeating(24_h);
    }
}

WebResourceLoadStatisticsStore::~WebResourceLoadStatisticsStore()
{
    RELEASE_ASSERT(RunLoop::isMain());
}

Ref<WebResourceLoadStatisticsStore> WebResourceLoadStatisticsStore::create(NetworkSession& networkSession, const String& resourceLoadStatisticsDirectory, ShouldIncludeLocalhost shouldIncludeLocalhost, WebCore::ResourceLoadStatistics::IsEphemeral isEphemeral)
{
    return adoptRef(*new WebResourceLoadStatisticsStore(networkSession, resourceLoadStatisticsDirectory, shouldIncludeLocalhost, isEphemeral));
}

void WebResourceLoadStatisticsStore::didDestroyNetworkSession(CompletionHandler<void()>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    auto callbackAggregator = CallbackAggregator::create([completionHandler = WTF::move(completionHandler)] () mutable {
        completionHandler();
    });

    m_networkSession = nullptr;
    destroyResourceLoadStatisticsStore([callbackAggregator] { });
}

void WebResourceLoadStatisticsStore::deleteAndRestrictWebsiteDataForRegistrableDomainsForSwift(RegistrableDomainsToDeleteOrRestrictWebsiteDataFor&& domains, RegistrableDomainVectorCompletionHandler&& completionHandler)
{
    deleteAndRestrictWebsiteDataForRegistrableDomains(monitoredDataTypes(), WTF::move(domains), [completionHandler = WTF::move(completionHandler)](HashSet<RegistrableDomain>&& removed) mutable {
        completionHandler(StatisticsRegistrableDomains { copyToVector(removed) });
    });
}

void WebResourceLoadStatisticsStore::setAgeCapForClientSideCookiesForSwift(Seconds seconds)
{
    if (CheckedPtr networkSession = this->networkSession()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->setAgeCapForClientSideCookies(seconds);
    }
}

CanRequestStorageAccessWithoutUserInteraction WebResourceLoadStatisticsStore::storageAccessQuirkGrantsForSwift(const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain, bool& hasQuirk, Vector<RegistrableDomain>& topFrameDomains, Vector<RegistrableDomain>& subFrameDomains)
{
    hasQuirk = false;
    CheckedPtr networkSession = this->networkSession();
    if (!networkSession || !networkSession->networkStorageSession())
        return CanRequestStorageAccessWithoutUserInteraction::No;

    if (auto quirk = WebCore::storageAccessQuirkForDomainPair(subFrameDomain, topFrameDomain)) {
        hasQuirk = true;
        for (auto& [quirkTopFrameDomain, quirkSubFrameDomains] : quirk->quirkDomains) {
            for (auto& quirkSubFrameDomain : quirkSubFrameDomains) {
                topFrameDomains.append(quirkTopFrameDomain);
                subFrameDomains.append(quirkSubFrameDomain);
            }
        }
    }
    return WebCore::canRequestStorageAccessForLoginOrCompatibilityPurposesWithoutPriorUserInteraction(subFrameDomain, topFrameDomain) ? CanRequestStorageAccessWithoutUserInteraction::Yes : CanRequestStorageAccessWithoutUserInteraction::No;
}

void WebResourceLoadStatisticsStore::broadcastConsoleMessageForSwift(uint8_t source, uint8_t level, const String& message)
{
    if (CheckedPtr networkSession = this->networkSession())
        protect(NetworkProcess::singleton())->broadcastConsoleMessage(networkSession->sessionID(), static_cast<MessageSource>(source), static_cast<MessageLevel>(level), message);
}

void WebResourceLoadStatisticsStore::registrableDomainsWithWebsiteDataForSwift(RegistrableDomainVectorCompletionHandler&& completionHandler)
{
    registrableDomainsWithWebsiteData(monitoredDataTypes(), [completionHandler = WTF::move(completionHandler)](HashSet<RegistrableDomain>&& domains) mutable {
        completionHandler(StatisticsRegistrableDomains { copyToVector(domains) });
    });
}

#if ENABLE(APP_BOUND_DOMAINS)
void WebResourceLoadStatisticsStore::setAppBoundDomainsForSwift(Vector<RegistrableDomain>&& domains, CompletionHandler<void()>&& completionHandler)
{
    setAppBoundDomains(registrableDomainHashSetFromVector(WTF::move(domains), 0), WTF::move(completionHandler));
}
#endif

#if ENABLE(MANAGED_DOMAINS)
void WebResourceLoadStatisticsStore::setManagedDomainsForSwift(Vector<RegistrableDomain>&& domains, CompletionHandler<void()>&& completionHandler)
{
    setManagedDomains(registrableDomainHashSetFromVector(WTF::move(domains), 0), WTF::move(completionHandler));
}
#endif

void WebResourceLoadStatisticsStore::destroyResourceLoadStatisticsStore(CompletionHandler<void()>&& completionHandler)
{
    RELEASE_ASSERT(RunLoop::isMain());

    if (isEphemeral()) {
        completionHandler();
        return;
    }

    destroyStatisticsStoreForSwift(addPendingCompletion(WTF::move(completionHandler)));
}

// A domain-list handler for a caller that wants a domain-to-time map, std::nullopt where the answer has no value.
static StatisticsDomainListCompletionHandler domainTimesCompletion(CompletionHandler<void(std::optional<HashMap<RegistrableDomain, WallTime>>&&)>&& completionHandler)
{
    return [completionHandler = WTF::move(completionHandler)](bool hasValue, Vector<RegistrableDomain> domains, StatisticsTimeVector times) mutable {
        if (!hasValue) {
            completionHandler(std::nullopt);
            return;
        }
        ASSERT(domains.size() == times.size());
        HashMap<RegistrableDomain, WallTime> result;
        result.reserveInitialCapacity(domains.size());
        for (size_t index = 0; index < domains.size() && index < times.size(); ++index)
            result.set(WTF::move(domains[index]), WallTime::fromRawSeconds(times[index]));
        completionHandler(WTF::move(result));
    };
}

uint64_t WebResourceLoadStatisticsStore::addPendingDomainListCompletion(StatisticsDomainListCompletionHandler&& completionHandler)
{
    ASSERT(RunLoop::isMain());

    auto identifier = ++m_lastPendingCompletionIdentifier;
    m_pendingDomainListCompletions.add(identifier, WTF::move(completionHandler));
    return identifier;
}

void WebResourceLoadStatisticsStore::completePendingDomainListForSwift(uint64_t identifier, bool hasValue, const Vector<RegistrableDomain>& domains, const StatisticsTimeVector& times)
{
    ASSERT(RunLoop::isMain());

    if (auto completionHandler = m_pendingDomainListCompletions.take(identifier))
        completionHandler(hasValue, Vector<RegistrableDomain> { domains }, StatisticsTimeVector { times });
}

uint64_t WebResourceLoadStatisticsStore::addPendingCompletion(CompletionHandler<void()>&& completionHandler)
{
    ASSERT(RunLoop::isMain());

    auto identifier = ++m_lastPendingCompletionIdentifier;
    m_pendingCompletions.add(identifier, WTF::move(completionHandler));
    return identifier;
}

void WebResourceLoadStatisticsStore::completePendingCompletionForSwift(uint64_t identifier)
{
    ASSERT(RunLoop::isMain());

    if (auto completionHandler = m_pendingCompletions.take(identifier))
        completionHandler();
}

void WebResourceLoadStatisticsStore::loadWebsitesWithUserInteraction(CompletionHandler<void(std::optional<HashMap<RegistrableDomain, WallTime>>&&)>&& completionHandler)
{
    if (isEphemeral())
        return completionHandler(std::nullopt);

    ASSERT(RunLoop::isMain());
    domainListForSwift(3, addPendingDomainListCompletion(domainTimesCompletion(WTF::move(completionHandler))));
}

void WebResourceLoadStatisticsStore::setTrackingPreventionDebugLoggingEnabled(bool value)
{
    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->setTrackingPreventionDebugLoggingEnabled(value);
    }
}

bool WebResourceLoadStatisticsStore::hasStorageAccessEphemeral(const RegistrableDomain& subFrameDomain, const RegistrableDomain& topFrameDomain, std::optional<FrameIdentifier> frameID, WebPageProxyIdentifier webPageProxyID)
{
    ASSERT(isEphemeral());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            return storageSession->hasStorageAccess(subFrameDomain, topFrameDomain, frameID, webPageProxyID);
    }
    return false;
}

bool WebResourceLoadStatisticsStore::hasStorageAccessForFrame(const RegistrableDomain& resourceDomain, const RegistrableDomain& firstPartyDomain, FrameIdentifier frameID, WebPageProxyIdentifier webPageProxyID)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            return storageSession->hasStorageAccess(resourceDomain, firstPartyDomain, frameID, webPageProxyID);
    }

    return false;
}

void WebResourceLoadStatisticsStore::callHasStorageAccessForFrameHandler(const RegistrableDomain& resourceDomain, const RegistrableDomain& firstPartyDomain, FrameIdentifier frameID, WebPageProxyIdentifier webPageProxyID, CompletionHandler<void(bool hasAccess)>&& callback)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            callback(storageSession->hasStorageAccess(resourceDomain, firstPartyDomain, frameID, webPageProxyID));
            return;
        }
    }

    callback(false);
}

void WebResourceLoadStatisticsStore::startListeningForStorageAccessPermissionChanges(StorageAccessPermissionChangeObserver& observer, TopFrameDomain&& topFrameDomain, SubFrameDomain&& subFrameDomain)
{
    m_storageAccessPermissionChangeObservers.ensure({ WTF::move(topFrameDomain), WTF::move(subFrameDomain) }, [] {
        return WeakHashSet<StorageAccessPermissionChangeObserver> { };
    }).iterator->value.add(observer);
}

void WebResourceLoadStatisticsStore::stopListeningForStorageAccessPermissionChanges(StorageAccessPermissionChangeObserver& observer, TopFrameDomain&& topFrameDomain, SubFrameDomain&& subFrameDomain)
{
    if (auto it = m_storageAccessPermissionChangeObservers.find({ WTF::move(topFrameDomain), WTF::move(subFrameDomain) }); it != m_storageAccessPermissionChangeObservers.end())
        it->value.remove(observer);
}

void WebResourceLoadStatisticsStore::stopListeningForStorageAccessPermissionChanges(StorageAccessPermissionChangeObserver& observer)
{
    m_storageAccessPermissionChangeObservers.removeIf([&](auto& entry) {
        entry.value.remove(observer);
        return entry.value.computeIsEmpty();
    });
}

void WebResourceLoadStatisticsStore::setLoginStatus(RegistrableDomain&& domain, IsLoggedIn loggedInStatus, std::optional<LoginStatus>&& lastAuthentication)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (loggedInStatus == IsLoggedIn::LoggedIn) {
        auto loginStatusToSet = lastAuthentication && lastAuthentication->hasExpired() ? std::nullopt : std::optional(WTF::move(lastAuthentication));
        if (loginStatusToSet)
            loginStatusToSet->setTimeToLive(WebCore::LoginStatus::TimeToLiveLong);
        auto pair = std::make_pair(loggedInStatus, loginStatusToSet);
        m_loginStatus.set(domain, WTF::move(pair));
    } else
        m_loginStatus.remove(domain);
}

bool WebResourceLoadStatisticsStore::isLoggedIn(const RegistrableDomain& domain) const
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    auto it = m_loginStatus.find(domain);
    return it != m_loginStatus.end() && it->value.first == IsLoggedIn::LoggedIn;
}

void WebResourceLoadStatisticsStore::requestStorageAccessUnderOpenerEphemeral(RegistrableDomain&& domainInNeedOfStorageAccess, WebPageProxyIdentifier openerWebPageProxyID, RegistrableDomain&& openerDomain)
{
    ASSERT(isEphemeral());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->grantStorageAccess(domainInNeedOfStorageAccess, openerDomain, std::nullopt, openerWebPageProxyID);
            didGrantPageLevelStorageAccess(openerWebPageProxyID, openerDomain, domainInNeedOfStorageAccess);
        }
    }
}

void WebResourceLoadStatisticsStore::didGrantPageLevelStorageAccess(WebPageProxyIdentifier webPageProxyID, const RegistrableDomain& topFrameDomain, const RegistrableDomain& subFrameDomain)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession)
        protect(protect(NetworkProcess::singleton())->parentProcessConnection())->send(Messages::NetworkProcessProxy::DidGrantPageLevelStorageAccess(webPageProxyID, topFrameDomain, subFrameDomain), 0);
}

StorageAccessWasGranted WebResourceLoadStatisticsStore::grantStorageAccessInEphemeralStorageSession(const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain, FrameIdentifier frameID, WebPageProxyIdentifier webPageProxyID)
{
    ASSERT(isEphemeral());

    if (CheckedPtr networkSession = m_networkSession) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->grantStorageAccess(subFrameDomain, topFrameDomain, frameID, webPageProxyID);
            return storageAccessWasGrantedValueForFrame(frameID, subFrameDomain);
        }
    }
    return StorageAccessWasGranted::No;
}

StorageAccessWasGranted WebResourceLoadStatisticsStore::grantStorageAccessInStorageSession(const RegistrableDomain& resourceDomain, const RegistrableDomain& firstPartyDomain, std::optional<FrameIdentifier> frameID, WebPageProxyIdentifier webPageProxyID, StorageAccessScope scope)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    bool isStorageGranted = false;

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->grantStorageAccess(resourceDomain, firstPartyDomain, (scope == StorageAccessScope::PerFrame ? frameID : std::nullopt), webPageProxyID);
            ASSERT(storageSession->hasStorageAccess(resourceDomain, firstPartyDomain, frameID, webPageProxyID));
            if (scope == StorageAccessScope::PerPage)
                didGrantPageLevelStorageAccess(webPageProxyID, firstPartyDomain, resourceDomain);
            isStorageGranted = true;
        }
    }

    if (!isStorageGranted)
        return StorageAccessWasGranted::No;

    if (!frameID)
        return StorageAccessWasGranted::Yes;

    return storageAccessWasGrantedValueForFrame(*frameID, resourceDomain);
}

void WebResourceLoadStatisticsStore::callGrantStorageAccessHandler(const RegistrableDomain& subFrameDomain, const RegistrableDomain& topFrameDomain, std::optional<FrameIdentifier> frameID, WebPageProxyIdentifier webPageProxyID, StorageAccessScope scope, CompletionHandler<void(StorageAccessWasGranted)>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    completionHandler(grantStorageAccessInStorageSession(subFrameDomain, topFrameDomain, frameID, webPageProxyID, scope));
}

void WebResourceLoadStatisticsStore::hasCookies(const RegistrableDomain& domain, CompletionHandler<void(bool)>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->hasCookies(domain, WTF::move(completionHandler));
            return;
        }
    }
    
    completionHandler(false);
}

void WebResourceLoadStatisticsStore::setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode blockingMode)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->setThirdPartyCookieBlockingMode(blockingMode);
        else
            ASSERT_NOT_REACHED();
    }

    if (isEphemeral())
        return;

    setThirdPartyCookieBlockingModeForSwift(blockingMode);
}

#if ENABLE(APP_BOUND_DOMAINS)
void WebResourceLoadStatisticsStore::setAppBoundDomains(HashSet<RegistrableDomain>&& domains, CompletionHandler<void()>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (isEphemeral() || domains.isEmpty()) {
        completionHandler();
        return;
    }

    auto domainsCopy = copyToVector(domains);

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->setAppBoundDomains(WTF::move(domains));
            storageSession->setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::AllExceptBetweenAppBoundDomains);
        }
    }

    setAppBoundDomainsOnStatisticsActorForSwift(domainsCopy, addPendingCompletion(WTF::move(completionHandler)));
}
#endif

#if ENABLE(MANAGED_DOMAINS)
void WebResourceLoadStatisticsStore::setManagedDomains(HashSet<RegistrableDomain>&& domains, CompletionHandler<void()>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (isEphemeral() || domains.isEmpty()) {
        completionHandler();
        return;
    }

    auto domainsCopy = copyToVector(domains);

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->setManagedDomains(WTF::move(domains));
            storageSession->setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::AllExceptManagedDomains);
        }
    }

    setManagedDomainsOnStatisticsActorForSwift(domainsCopy, addPendingCompletion(WTF::move(completionHandler)));
}
#endif

void WebResourceLoadStatisticsStore::removeAllStorageAccess(CompletionHandler<void()>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->removeAllStorageAccess();
    }

    completionHandler();
}

void WebResourceLoadStatisticsStore::logUserInteractionEphemeral(const RegistrableDomain& domain)
{
    ASSERT(isEphemeral());

    m_domainsWithEphemeralUserInteraction.add(domain);
}

void WebResourceLoadStatisticsStore::logCrossSiteLoadWithLinkDecoration(RegistrableDomain&& fromDomain, RegistrableDomain&& toDomain, DidFilterKnownLinkDecoration didFilterKnownLinkDecoration, CompletionHandler<void()>&& completionHandler)
{
    ASSERT(RunLoop::isMain());
    ASSERT(fromDomain != toDomain);
    
    logCrossSiteLoadWithLinkDecorationForSwift(WTF::move(fromDomain), WTF::move(toDomain), didFilterKnownLinkDecoration == DidFilterKnownLinkDecoration::Yes, addPendingCompletion(WTF::move(completionHandler)));
}

void WebResourceLoadStatisticsStore::clearUserInteractionEphemeral(const RegistrableDomain& domain)
{
    ASSERT(isEphemeral());

    m_domainsWithEphemeralUserInteraction.remove(domain);
}

void WebResourceLoadStatisticsStore::setMostRecentWebPushInteractionTime(RegistrableDomain&& domain, CompletionHandler<void()>&& completionHandler)
{
    ASSERT(RunLoop::isMain());

    setMostRecentWebPushInteractionTimeForSwift(WTF::move(domain), addPendingCompletion(WTF::move(completionHandler)));
}

void WebResourceLoadStatisticsStore::scheduleClearInMemoryAndPersistent(ShouldGrandfatherStatistics shouldGrandfather, CompletionHandler<void()>&& completionHandler)
{
    if (isEphemeral()) {
        clearInMemoryEphemeral();
        completionHandler();
        return;
    }

    ASSERT(RunLoop::isMain());
    scheduleClearInMemoryAndPersistentForSwift(shouldGrandfather == ShouldGrandfatherStatistics::Yes, addPendingCompletion(WTF::move(completionHandler)));
}

void WebResourceLoadStatisticsStore::scheduleClearInMemoryAndPersistent(WallTime modifiedSince, ShouldGrandfatherStatistics shouldGrandfather, CompletionHandler<void()>&& callback)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    // For now, be conservative and clear everything regardless of modifiedSince.
    UNUSED_PARAM(modifiedSince);
    scheduleClearInMemoryAndPersistent(shouldGrandfather, WTF::move(callback));
}

void WebResourceLoadStatisticsStore::clearInMemoryEphemeral()
{
    m_domainsWithEphemeralUserInteraction.clear();

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->removeAllStorageAccess();
    }
}

void WebResourceLoadStatisticsStore::setCacheMaxAgeCap(Seconds seconds, CompletionHandler<void()>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    ASSERT(seconds >= 0_s);
    
    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->setCacheMaxAgeCapForPrevalentResources(seconds);
    }

    completionHandler();
}

bool WebResourceLoadStatisticsStore::needsUserInteractionQuirk(const RegistrableDomain& domain) const
{
    static NeverDestroyed<HashSet<RegistrableDomain>> quirks = [] {
        HashSet<RegistrableDomain> set;
        set.add(RegistrableDomain::uncheckedCreateFromRegistrableDomainString("kinja.com"_s));
        set.add(RegistrableDomain::uncheckedCreateFromRegistrableDomainString("youtube.com"_s));
        return set;
    }();

    return quirks.get().contains(domain);
}

void WebResourceLoadStatisticsStore::callUpdatePrevalentDomainsToBlockCookiesForHandler(const RegistrableDomainsToBlockCookiesFor& domainsToBlock, CompletionHandler<void()>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession()) {
            storageSession->setPrevalentDomainsToBlockAndDeleteCookiesFor(domainsToBlock.domainsToBlockAndDeleteCookiesFor);
            storageSession->setPrevalentDomainsToBlockButKeepCookiesFor(domainsToBlock.domainsToBlockButKeepCookiesFor);
            storageSession->setDomainsWithUserInteractionAsFirstParty(domainsToBlock.domainsWithUserInteractionAsFirstParty);
        }

        HashSet<RegistrableDomain> domainsWithUserInteractionQuirk;
        for (auto& domain : borrow(domainsToBlock.domainsWithUserInteractionAsFirstParty)) {
            if (needsUserInteractionQuirk(domain))
                domainsWithUserInteractionQuirk.add(domain);
        }

        if (m_domainsWithUserInteractionQuirk != domainsWithUserInteractionQuirk) {
            m_domainsWithUserInteractionQuirk = domainsWithUserInteractionQuirk;
            protect(protect(NetworkProcess::singleton())->parentProcessConnection())->send(Messages::NetworkProcessProxy::SetDomainsWithUserInteraction(domainsWithUserInteractionQuirk), 0);
        }

        HashMap<TopFrameDomain, Vector<SubResourceDomain>> domainsWithStorageAccessQuirk;
        for (auto& [firstPartyDomain, requestingDomains] : domainsToBlock.domainsWithStorageAccess) {
            for (auto& requestingDomain : borrow(requestingDomains)) {
                if (WebCore::loginDomainMatchesRequestingDomain(firstPartyDomain, requestingDomain))
                    domainsWithStorageAccessQuirk.add(firstPartyDomain, Vector<SubResourceDomain> { }).iterator->value.append(requestingDomain);
            }
        }

        if (m_domainsWithCrossPageStorageAccessQuirk != domainsWithStorageAccessQuirk) {
            if (CheckedPtr storageSession = networkSession->networkStorageSession())
                storageSession->setDomainsWithCrossPageStorageAccess(domainsWithStorageAccessQuirk);
            protect(protect(NetworkProcess::singleton())->parentProcessConnection())->sendWithAsyncReply(Messages::NetworkProcessProxy::SetDomainsWithCrossPageStorageAccess(domainsWithStorageAccessQuirk), [this, protectedThis = Ref { *this }, domainsWithStorageAccessQuirk] mutable {
                m_domainsWithCrossPageStorageAccessQuirk = domainsWithStorageAccessQuirk;
            });
        }
    }

    completionHandler();
}

void WebResourceLoadStatisticsStore::resetStorageSessionDomainsToDefaultValues()
{
    ASSERT(RunLoop::isMain());

#if ENABLE(APP_BOUND_DOMAINS)
    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->resetAppBoundDomains();
    }
#endif

#if ENABLE(MANAGED_DOMAINS)
    if (CheckedPtr networkSession = m_networkSession.get()) {
        if (CheckedPtr storageSession = networkSession->networkStorageSession())
            storageSession->resetManagedDomains();
    }
#endif
}

void WebResourceLoadStatisticsStore::logTestingEvent(const String& event)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());

    CheckedPtr networkSession = m_networkSession.get();
    if (networkSession && networkSession->enableResourceLoadStatisticsLogTestingEvent())
        protect(protect(NetworkProcess::singleton())->parentProcessConnection())->send(Messages::NetworkProcessProxy::LogTestingEvent(m_networkSession->sessionID(), event), 0);
}

NetworkSession* WebResourceLoadStatisticsStore::networkSession()
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    return m_networkSession.get();
}

void WebResourceLoadStatisticsStore::invalidateAndCancel()
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    m_networkSession = nullptr;
}

void WebResourceLoadStatisticsStore::removeDataForDomain(RegistrableDomain domain, CompletionHandler<void()>&& completionHandler)
{
    for (auto it = m_domainsGrantedStorageAccessPermissionInPage.begin(); it != m_domainsGrantedStorageAccessPermissionInPage.end(); ++it) {
        it->value.removeIf([&domain](const auto& pair) {
            return pair.first == domain;
        });
    }

    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    removeDataForDomainForSwift(WTF::move(domain), addPendingCompletion(WTF::move(completionHandler)));
}

void WebResourceLoadStatisticsStore::registrableDomains(CompletionHandler<void(Vector<RegistrableDomain>&&)>&& completionHandler)
{
    ASSERT(RunLoop::isMain());

    if (isEphemeral()) {
        completionHandler({ });
        return;
    }

    domainListForSwift(0, addPendingDomainListCompletion([completionHandler = WTF::move(completionHandler)](bool, Vector<RegistrableDomain> domains, StatisticsTimeVector) mutable {
        completionHandler(WTF::move(domains));
    }));
}

void WebResourceLoadStatisticsStore::registrableDomainsWithLastAccessedTime(CompletionHandler<void(std::optional<HashMap<RegistrableDomain, WallTime>>&&)>&& completionHandler)
{
    ASSERT(RunLoop::isMain());

    if (isEphemeral()) {
        completionHandler(std::nullopt);
        return;
    }

    domainListForSwift(1, addPendingDomainListCompletion(domainTimesCompletion(WTF::move(completionHandler))));
}

void WebResourceLoadStatisticsStore::registrableDomainsExemptFromWebsiteDataDeletion(CompletionHandler<void(HashSet<RegistrableDomain>&&)>&& completionHandler)
{
    ASSERT(RunLoop::isMain());

    if (isEphemeral()) {
        completionHandler({ });
        return;
    }

    domainListForSwift(2, addPendingDomainListCompletion([completionHandler = WTF::move(completionHandler)](bool, Vector<RegistrableDomain> domains, StatisticsTimeVector) mutable {
        HashSet<RegistrableDomain> result;
        result.reserveInitialCapacity(domains.size());
        for (auto& domain : domains)
            result.add(WTF::move(domain));
        completionHandler(WTF::move(result));
    }));
}

void WebResourceLoadStatisticsStore::deleteAndRestrictWebsiteDataForRegistrableDomains(OptionSet<WebsiteDataType> dataTypes, RegistrableDomainsToDeleteOrRestrictWebsiteDataFor&& domainsToDeleteAndRestrictWebsiteDataFor, CompletionHandler<void(HashSet<RegistrableDomain>&&)>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    
    if (CheckedPtr networkSession = m_networkSession.get()) {
        networkSession->deleteAndRestrictWebsiteDataForRegistrableDomains(dataTypes, WTF::move(domainsToDeleteAndRestrictWebsiteDataFor), WTF::move(completionHandler));
        return;
    }

    completionHandler({ });
}

void WebResourceLoadStatisticsStore::registrableDomainsWithWebsiteData(OptionSet<WebsiteDataType> dataTypes, CompletionHandler<void(HashSet<RegistrableDomain>&&)>&& completionHandler)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    
    if (CheckedPtr networkSession = m_networkSession.get()) {
        networkSession->registrableDomainsWithWebsiteData(dataTypes, WTF::move(completionHandler));
        return;
    }

    completionHandler({ });
}

void WebResourceLoadStatisticsStore::suspend(NetworkProcess& networkProcess, CompletionHandler<void()>&& completionHandler)
{
    assertIsMainRunLoop();
    auto identifier = ++lastPendingSuspendCompletionIdentifier;
    pendingSuspendCompletions().add(identifier, WTF::move(completionHandler));
    networkProcess.suspendStatisticsInboxForSwift(identifier);
}

void WebResourceLoadStatisticsStore::resume(NetworkProcess& networkProcess)
{
    ASSERT(RunLoop::isMain());

    networkProcess.resumeStatisticsInboxForSwift();
}

void WebResourceLoadStatisticsStore::recordFrameLoadForStorageAccess(WebPageProxyIdentifier webPageProxyID, WebCore::FrameIdentifier frameID, const WebCore::RegistrableDomain& domain)
{
    auto currentTime = WallTime::now();
    StorageAccessRequestRecordKey key { frameID, domain };
    auto& recordValue = m_storageAccessRequestRecords.ensure(key, [&]() {
        return StorageAccessRequestRecordValue { webPageProxyID, { }, currentTime };
    }).iterator->value;
    ASSERT(recordValue.webPageProxyID == webPageProxyID);
    recordValue.lastLoadTime = currentTime;
}

void WebResourceLoadStatisticsStore::clearFrameLoadRecordsForStorageAccess(WebCore::FrameIdentifier frameID)
{
    m_storageAccessRequestRecords.removeIf([&](auto& record) {
        return record.key.first == frameID;
    });
}

void WebResourceLoadStatisticsStore::clearFrameLoadRecordsForStorageAccess(WebPageProxyIdentifier webPageProxyID)
{
    m_storageAccessRequestRecords.removeIf([&](auto& record) {
        return record.value.webPageProxyID == webPageProxyID;
    });
}

StorageAccessWasGranted WebResourceLoadStatisticsStore::storageAccessWasGrantedValueForFrame(WebCore::FrameIdentifier frameID, const WebCore::RegistrableDomain& domain)
{
    StorageAccessRequestRecordKey key { frameID, domain };
    auto iter = m_storageAccessRequestRecords.find(key);
    if (iter == m_storageAccessRequestRecords.end())
        return StorageAccessWasGranted::Yes;

    auto& value = iter->value;
    if (!value.lastRequestTime)
        value.lastRequestTime = WallTime::now();

    return value.lastRequestTime.value() < value.lastLoadTime ? StorageAccessWasGranted::Yes : StorageAccessWasGranted::YesWithException;
}

void WebResourceLoadStatisticsStore::wasGrantedStorageAccessPermissionInPage(WebPageProxyIdentifier webPageProxyID, const RegistrableDomain& topFrameDomain, const RegistrableDomain& subFrameDomain)
{
    auto result = m_domainsGrantedStorageAccessPermissionInPage.ensure(webPageProxyID, [] {
        return HashSet<std::pair<TopFrameDomain, SubFrameDomain>>();
    }).iterator->value.add({ topFrameDomain, subFrameDomain });

    if (result.isNewEntry) {
        if (auto it = m_storageAccessPermissionChangeObservers.find({ topFrameDomain, subFrameDomain }); it != m_storageAccessPermissionChangeObservers.end()) {
            for (Ref observer : it->value)
                observer->storageAccessPermissionChanged(topFrameDomain, subFrameDomain);
        }
    }
}

bool WebResourceLoadStatisticsStore::isStorageAccessPermissionGrantedInPage(WebPageProxyIdentifier webPageProxyID, const TopFrameDomain& topFrameDomain, const SubFrameDomain& subFrameDomain) const
{
    auto it = m_domainsGrantedStorageAccessPermissionInPage.find(webPageProxyID);
    return it != m_domainsGrantedStorageAccessPermissionInPage.end() && it->value.contains({ topFrameDomain, subFrameDomain });
}

StorageAccessPromptQuirkForSwift WebResourceLoadStatisticsStore::storageAccessQuirk(const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain)
{
    if (CheckedPtr networkSession = m_networkSession; networkSession && networkSession->networkStorageSession())
        return WebCore::storageAccessQuirkForDomainPair(topFrameDomain, subFrameDomain);
    return std::nullopt;
}

void WebResourceLoadStatisticsStore::requestStorageAccessConfirm(WebPageProxyIdentifier webPageProxyID, FrameIdentifier frameID, const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain, StorageAccessPromptQuirkForSwift&& storageAccessQuirk, uint64_t replyIdentifier)
{
    protect(protect(NetworkProcess::singleton())->parentProcessConnection())->sendWithAsyncReply(Messages::NetworkProcessProxy::RequestStorageAccessConfirm(webPageProxyID, frameID, subFrameDomain, topFrameDomain, WTF::move(storageAccessQuirk)), [replyIdentifier](bool userDidGrantAccess) {
        completeStatisticsBoolReplyForSwift(replyIdentifier, userDidGrantAccess);
    });
}

CanRequestStorageAccessWithoutUserInteraction WebResourceLoadStatisticsStore::canRequestStorageAccessWithoutUserInteraction(const SubFrameDomain& subFrameDomain, const TopFrameDomain& topFrameDomain)
{
    if (CheckedPtr networkSession = m_networkSession) {
        if (networkSession->networkStorageSession())
            return WebCore::canRequestStorageAccessForLoginOrCompatibilityPurposesWithoutPriorUserInteraction(subFrameDomain, topFrameDomain) ? CanRequestStorageAccessWithoutUserInteraction::Yes : CanRequestStorageAccessWithoutUserInteraction::No;
    }
    return CanRequestStorageAccessWithoutUserInteraction::No;
}

void WebResourceLoadStatisticsStore::wasRevokedStorageAccessPermissionInPage(WebPageProxyIdentifier webPageProxyID)
{
    m_domainsGrantedStorageAccessPermissionInPage.remove(webPageProxyID);
}

} // namespace WebKit
