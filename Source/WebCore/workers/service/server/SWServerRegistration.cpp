/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
#include "SWServerRegistration.h"

#include "HTTPParsers.h"
#include "Logging.h"
#include "SWServer.h"
#include "SWServerToContextConnection.h"
#include "SWServerWorker.h"
#include "ServiceWorkerTypes.h"
#include "ServiceWorkerUpdateViaCache.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Vector.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(SWServerRegistration);

Ref<SWServerRegistration> SWServerRegistration::create(SWServer& server, const ServiceWorkerRegistrationKey& key, ServiceWorkerUpdateViaCache updateViaCache, const URL& scopeURL, const URL& scriptURL, std::optional<ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier, NavigationPreloadState&& navigationPreloadState)
{
    return adoptRef(*new SWServerRegistration(server, key, updateViaCache, scopeURL, scriptURL, serviceWorkerPageIdentifier, WTF::move(navigationPreloadState)));
}

SWServerRegistration::SWServerRegistration(SWServer& server, const ServiceWorkerRegistrationKey& key, ServiceWorkerUpdateViaCache updateViaCache, const URL& scopeURL, const URL& scriptURL, std::optional<ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier, NavigationPreloadState&& navigationPreloadState)
    : m_registrationKey(key)
    , m_updateViaCache(updateViaCache)
    , m_scopeURL(scopeURL)
    , m_scriptURL(scriptURL)
    , m_serviceWorkerPageIdentifier(serviceWorkerPageIdentifier)
    , m_server(server)
    , m_creationTime(MonotonicTime::now())
    , m_softUpdateTimer { *this, &SWServerRegistration::softUpdate }
    , m_preloadState(WTF::move(navigationPreloadState))
{
    m_scopeURL.removeFragmentIdentifier();
}

SWServerRegistration::~SWServerRegistration()
{
    ASSERT(!m_preInstallationWorker || !m_preInstallationWorker->isRunning());
    ASSERT(!m_installingWorker || !m_installingWorker->isRunning());
    ASSERT(!m_waitingWorker || !m_waitingWorker->isRunning());
    ASSERT(!m_activeWorker || !m_activeWorker->isRunning());
}

void SWServerRegistration::setPreInstallationWorker(SWServerWorker* worker)
{
    m_preInstallationWorker = worker;
}

void SWServerRegistration::updateRegistrationState(ServiceWorkerRegistrationState state, SWServerWorker* worker)
{
    LOG(ServiceWorker, "(%p) Updating registration state to %i with worker %p", this, (int)state, worker);
    
    switch (state) {
    case ServiceWorkerRegistrationState::Installing:
        ASSERT(!m_installingWorker || !m_installingWorker->isRunning() || m_waitingWorker == m_installingWorker);
        m_installingWorker = worker;
        break;
    case ServiceWorkerRegistrationState::Waiting:
        ASSERT(!m_waitingWorker || !m_waitingWorker->isRunning() || m_activeWorker == m_waitingWorker);
        m_waitingWorker = worker;
        break;
    case ServiceWorkerRegistrationState::Active:
        ASSERT(!m_activeWorker || !m_activeWorker->isRunning());
        m_activeWorker = worker;
        break;
    };

    std::optional<ServiceWorkerData> serviceWorkerData;
    if (worker)
        serviceWorkerData = worker->data();

    forEachConnection([&](auto& connection) {
        connection.updateRegistrationStateInClient(this->identifier(), state, serviceWorkerData);
    });
}

void SWServerRegistration::updateWorkerState(SWServerWorker& worker, ServiceWorkerState state)
{
    LOG(ServiceWorker, "Updating worker %p state to %i (%p)", &worker, (int)state, this);

    worker.setState(state);
}

void SWServerRegistration::setUpdateViaCache(ServiceWorkerUpdateViaCache updateViaCache)
{
    m_updateViaCache = updateViaCache;
    forEachConnection([&](auto& connection) {
        connection.setRegistrationUpdateViaCache(this->identifier(), updateViaCache);
    });
}

void SWServerRegistration::setLastUpdateTime(WallTime time)
{
    m_lastUpdateTime = time;
    forEachConnection([&](auto& connection) {
        connection.setRegistrationLastUpdateTime(this->identifier(), time);
    });
}

void SWServerRegistration::fireUpdateFoundEvent()
{
    forEachConnection([&](auto& connection) {
        connection.fireUpdateFoundEvent(this->identifier());
    });
}

void SWServerRegistration::forEachConnection(NOESCAPE const Function<void(SWServer::Connection&)>& apply)
{
    for (auto connectionIdentifierWithClients : m_connectionsWithClientRegistrations.values()) {
        if (RefPtr connection = protect(server())->connection(connectionIdentifierWithClients))
            apply(*connection);
    }
}

ServiceWorkerRegistrationData SWServerRegistration::data() const
{
    std::optional<ServiceWorkerData> installingWorkerData;
    if (m_installingWorker)
        installingWorkerData = m_installingWorker->data();

    std::optional<ServiceWorkerData> waitingWorkerData;
    if (m_waitingWorker)
        waitingWorkerData = m_waitingWorker->data();

    std::optional<ServiceWorkerData> activeWorkerData;
    if (m_activeWorker)
        activeWorkerData = m_activeWorker->data();

    return { m_registrationKey, identifier(), m_scopeURL, m_updateViaCache, m_lastUpdateTime, WTF::move(installingWorkerData), WTF::move(waitingWorkerData), WTF::move(activeWorkerData) };
}

void SWServerRegistration::addClientUsingRegistration(ScriptExecutionContextIdentifier clientIdentifier)
{
    auto addResult = m_clientsUsingRegistration.add(clientIdentifier.processIdentifier(), HashSet<ScriptExecutionContextIdentifier> { }).iterator->value.add(clientIdentifier);
    ASSERT_UNUSED(addResult, addResult.isNewEntry);
}

void SWServerRegistration::removeClientUsingRegistration(ScriptExecutionContextIdentifier clientIdentifier)
{
    auto iterator = m_clientsUsingRegistration.find(clientIdentifier.processIdentifier());
    ASSERT(iterator != m_clientsUsingRegistration.end());
    if (iterator == m_clientsUsingRegistration.end())
        return;

    bool wasRemoved = iterator->value.remove(clientIdentifier);
    ASSERT_UNUSED(wasRemoved, wasRemoved);

    if (iterator->value.isEmpty())
        m_clientsUsingRegistration.remove(iterator);

    handleClientUnload();
}

// https://w3c.github.io/ServiceWorker/#notify-controller-change
void SWServerRegistration::notifyClientsOfControllerChange()
{
    std::optional<ServiceWorkerData> newController = activeWorker() ? std::optional { activeWorker()->data() } : std::nullopt;
    for (auto& item : m_clientsUsingRegistration) {
        if (RefPtr connection = protect(server())->connection(item.key))
            connection->notifyClientsOfControllerChange(item.value, newController);
    }
}

void SWServerRegistration::unregisterServerConnection(SWServerConnectionIdentifier serverConnectionIdentifier)
{
    m_connectionsWithClientRegistrations.removeAll(serverConnectionIdentifier);
    m_clientsUsingRegistration.remove(serverConnectionIdentifier);
}

// https://w3c.github.io/ServiceWorker/#clear-registration
void SWServerRegistration::clear()
{
    RELEASE_LOG(ServiceWorker, "SWServerRegistration::clear %" PRIu64, identifier().toUInt64());

    terminateWorkersForServiceWorkerPageDisconnect();
    notifyClientsOfControllerChange();

    // Remove scope to registration map[scopeString].
    protect(server())->removeRegistration(identifier());
}

void SWServerRegistration::terminateWorkersForServiceWorkerPageDisconnect()
{
    if (RefPtr preInstallationWorker = m_preInstallationWorker) {
        ASSERT(preInstallationWorker->state() == ServiceWorkerState::Parsed);
        preInstallationWorker->terminate();
        m_preInstallationWorker = nullptr;
    }

    RefPtr installingWorker = this->installingWorker();
    if (installingWorker) {
        installingWorker->terminate();
        updateRegistrationState(ServiceWorkerRegistrationState::Installing, nullptr);
    }
    RefPtr waitingWorker = this->waitingWorker();
    if (waitingWorker) {
        waitingWorker->terminate();
        updateRegistrationState(ServiceWorkerRegistrationState::Waiting, nullptr);
    }
    RefPtr activeWorker = this->activeWorker();
    if (activeWorker) {
        activeWorker->terminate();
        updateRegistrationState(ServiceWorkerRegistrationState::Active, nullptr);
    }

    if (installingWorker)
        updateWorkerState(*installingWorker, ServiceWorkerState::Redundant);
    if (waitingWorker)
        updateWorkerState(*waitingWorker, ServiceWorkerState::Redundant);
    if (activeWorker)
        updateWorkerState(*activeWorker, ServiceWorkerState::Redundant);
}

bool SWServerRegistration::isUnregistered() const
{
    return protect(server())->getRegistration(key()) != this;
}

void SWServerRegistration::controlClient(ScriptExecutionContextIdentifier identifier)
{
    RefPtr activeWorker = this->activeWorker();
    ASSERT(activeWorker);

    addClientUsingRegistration(identifier);

    HashSet<ScriptExecutionContextIdentifier> identifiers;
    identifiers.add(identifier);
    protect(protect(server())->connection(identifier.processIdentifier()))->notifyClientsOfControllerChange(identifiers, activeWorker->data());
}

void SWServerRegistration::scheduleSoftUpdate(IsAppInitiated isAppInitiated)
{
    // To avoid scheduling many updates during a single page load, we do soft updates on a 1 second delay and keep delaying
    // as long as soft update requests keep coming. This seems to match Chrome's behavior.
    if (m_softUpdateTimer.isActive())
        return;

    m_isAppInitiated = isAppInitiated == IsAppInitiated::Yes;

    RELEASE_LOG(ServiceWorker, "SWServerRegistration::softUpdateIfNeeded");
    m_softUpdateTimer.startOneShot(softUpdateDelay);
}

// https://w3c.github.io/ServiceWorker/#dom-navigationpreloadmanager-enable, steps run in parallel.
std::optional<ExceptionData> SWServerRegistration::enableNavigationPreload()
{
    RefPtr activeWorker = this->activeWorker();
    if (!activeWorker)
        return ExceptionData { ExceptionCode::InvalidStateError, "No active worker"_s };

    m_preloadState.enabled = true;
    protect(server())->storeRegistrationForWorkerIfNecessary(*activeWorker);
    return { };
}

// https://w3c.github.io/ServiceWorker/#dom-navigationpreloadmanager-disable, steps run in parallel.
std::optional<ExceptionData> SWServerRegistration::disableNavigationPreload()
{
    RefPtr activeWorker = this->activeWorker();
    if (!activeWorker)
        return ExceptionData { ExceptionCode::InvalidStateError, "No active worker"_s };

    m_preloadState.enabled = false;
    protect(server())->storeRegistrationForWorkerIfNecessary(*activeWorker);
    return { };
}

// https://w3c.github.io/ServiceWorker/#dom-navigationpreloadmanager-setheadervalue, steps run in parallel.
std::optional<ExceptionData> SWServerRegistration::setNavigationPreloadHeaderValue(String headerValue)
{
    if (!isValidHTTPHeaderValue(headerValue))
        return ExceptionData { ExceptionCode::TypeError, "Invalid header value"_s };

    RefPtr activeWorker = this->activeWorker();
    if (!activeWorker)
        return ExceptionData { ExceptionCode::InvalidStateError, "No active worker"_s };

    m_preloadState.headerValue = WTF::move(headerValue);
    protect(server())->storeRegistrationForWorkerIfNecessary(*activeWorker);
    return { };
}

void SWServerRegistration::addCookieChangeSubscriptions(Vector<CookieChangeSubscription> subscriptions)
{
    for (auto& subscription : subscriptions)
        m_cookieChangeSubscriptions.add(WTF::move(subscription));
}

void SWServerRegistration::removeCookieChangeSubscriptions(Vector<CookieChangeSubscription> subscriptions)
{
    for (auto& subscription : subscriptions)
        m_cookieChangeSubscriptions.remove(subscription);
}

Vector<CookieChangeSubscription> SWServerRegistration::cookieChangeSubscriptions() const
{
    return copyToVector(m_cookieChangeSubscriptions);
}

} // namespace WebCore
