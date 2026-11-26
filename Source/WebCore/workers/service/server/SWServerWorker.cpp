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
#include "SWServerWorker.h"

#include "Logging.h"
#include "SWServer.h"
#include "SWServerRegistration.h"
#include "SWServerToContextConnection.h"
#include "ServiceWorkerRoute.h"
#include <cstdint>
#include <wtf/CompletionHandler.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

HashMap<ServiceWorkerIdentifier, WeakRef<SWServerWorker>>& SWServerWorker::allWorkers()
{
    static NeverDestroyed<HashMap<ServiceWorkerIdentifier, WeakRef<SWServerWorker>>> workers;
    return workers;
}

SWServerWorker* SWServerWorker::existingWorkerForIdentifier(ServiceWorkerIdentifier identifier)
{
    return allWorkers().get(identifier);
}

// FIXME: Use r-value references for script and contentSecurityPolicy
SWServerWorker::SWServerWorker(SWServer& server, SWServerRegistration& registration, const URL& scriptURL, const ScriptBuffer& script, const CertificateInfo& certificateInfo, const ContentSecurityPolicyResponseHeaders& contentSecurityPolicy, const CrossOriginEmbedderPolicy& crossOriginEmbedderPolicy, String&& referrerPolicy, WorkerType type, ServiceWorkerIdentifier identifier, MemoryCompactRobinHoodHashMap<URL, ServiceWorkerContextData::ImportedScript>&& scriptResourceMap, Vector<ServiceWorkerRoute>&& routes)
    : m_server(server)
    , m_registrationKey(registration.key())
    , m_registration(registration)
    , m_data { identifier, registration.identifier(), scriptURL, ServiceWorkerState::Parsed, type }
    , m_script(script)
    , m_certificateInfo(certificateInfo)
    , m_contentSecurityPolicy(contentSecurityPolicy)
    , m_crossOriginEmbedderPolicy(crossOriginEmbedderPolicy)
    , m_referrerPolicy(WTF::move(referrerPolicy))
    , m_topSite(m_registrationKey.topOrigin())
    , m_scriptResourceMap(WTF::move(scriptResourceMap))
    , m_terminationTimer(*this, &SWServerWorker::terminationTimerFired)
    , m_terminationIfPossibleTimer(*this, &SWServerWorker::terminationIfPossibleTimerFired)
    , m_lastNavigationWasAppInitiated(server.clientIsAppInitiatedForRegistrableDomain(m_topSite.domain()))
    , m_routes(WTF::move(routes))
{
    m_data.scriptURL.removeFragmentIdentifier();

    auto result = allWorkers().add(identifier, *this);
    ASSERT_UNUSED(result, result.isNewEntry);

    ASSERT(server.getRegistration(m_registrationKey) == &registration);
}

SWServerWorker::~SWServerWorker()
{
    ASSERT(m_whenActivatedHandlers.isEmpty());
    callWhenActivatedHandler(false);

    auto taken = allWorkers().take(identifier());
    ASSERT_UNUSED(taken, taken == this);

    callTerminationCallbacks();
}

ServiceWorkerContextData SWServerWorker::contextData() const
{
    RefPtr registration = m_registration.get();
    ASSERT(registration);

    return {
        std::nullopt, registration->data(), m_data.identifier, script(), m_certificateInfo, m_contentSecurityPolicy, m_crossOriginEmbedderPolicy, m_referrerPolicy, m_data.scriptURL, m_data.type, false, m_lastNavigationWasAppInitiated, m_scriptResourceMap, registration->serviceWorkerPageIdentifier(), registration->navigationPreloadState(),
        WTF::map(m_routes, [](auto& route) { return route.copy(); }),
        std::nullopt
    };
}

void SWServerWorker::terminate()
{
    terminate([] { });
}

void SWServerWorker::terminate(CompletionHandler<void()>&& callback)
{
    if (!m_server)
        return callback();

    switch (m_state) {
    case State::Running:
        startTermination(WTF::move(callback));
        return;
    case State::Terminating:
        m_terminationCallbacks.append(WTF::move(callback));
        return;
    case State::NotRunning:
        return callback();
    }
}

void SWServerWorker::whenTerminated(CompletionHandler<void()>&& callback)
{
    ASSERT(isRunning() || isTerminating());
    m_terminationCallbacks.append(WTF::move(callback));
}

void SWServerWorker::startTermination(CompletionHandler<void()>&& callback)
{
    RefPtr contextConnection = this->contextConnection();
    ASSERT(contextConnection);
    if (!contextConnection) {
        RELEASE_LOG_ERROR(ServiceWorker, "Request to terminate a worker %" PRIu64 " whose context connection does not exist", identifier().toUInt64());
        setState(State::NotRunning);
        callback();
        protect(*server())->workerContextTerminated(*this);
        return;
    }

    setState(State::Terminating);

    m_terminationCallbacks.append(WTF::move(callback));

    constexpr Seconds terminationDelayForTesting = 1_s;
    RefPtr server = m_server;
    m_terminationTimer.startOneShot(server && server->isProcessTerminationDelayEnabled() ? SWServer::defaultTerminationDelay : terminationDelayForTesting);

    m_terminationIfPossibleTimer.stop();

    contextConnection->terminateWorker(identifier());
}

void SWServerWorker::terminationCompleted()
{
    m_terminationTimer.stop();
    callTerminationCallbacks();
}

void SWServerWorker::callTerminationCallbacks()
{
    auto callbacks = WTF::move(m_terminationCallbacks);
    for (auto& callback : callbacks)
        callback();
}

void SWServerWorker::terminationTimerFired()
{
    RELEASE_LOG_ERROR(ServiceWorker, "Terminating service worker %" PRIu64 " due to unresponsiveness", identifier().toUInt64());

    ASSERT(isTerminating());
    if (RefPtr contextConnection = this->contextConnection())
        contextConnection->terminateDueToUnresponsiveness();
}

const ClientOrigin& SWServerWorker::origin() const
{
    ASSERT(!SecurityOriginData::shouldTreatAsOpaqueOrigin(m_data.scriptURL) || !m_registration || !!m_registration->serviceWorkerPageIdentifier());

    if (!m_origin)
        m_origin = ClientOrigin { m_registrationKey.topOrigin(), SecurityOriginData::fromURLWithoutStrictOpaqueness(m_data.scriptURL) };

    return *m_origin;
}

SWServerToContextConnection* SWServerWorker::contextConnection()
{
    RefPtr server = m_server;
    return server ? server->contextConnectionForRegistrableDomain(topRegistrableDomain(), m_crossOriginEmbedderPolicy.value) : nullptr;
}

std::optional<ServiceWorkerClientData> SWServerWorker::findClientByIdentifier(ScriptExecutionContextIdentifier clientId) const
{
    ASSERT(m_server);
    if (!m_server)
        return { };
    return protect(*server())->serviceWorkerClientWithOriginByID(origin(), clientId);
}

void SWServerWorker::findClientByVisibleIdentifier(const String& clientIdentifier, CompletionHandler<void(std::optional<WebCore::ServiceWorkerClientData>&&)>&& callback)
{
    if (!m_server) {
        callback({ });
        return;
    }

    auto internalIdentifier = protect(*server())->clientIdFromVisibleClientId(clientIdentifier);
    if (!internalIdentifier) {
        callback({ });
        return;
    }

    callback(findClientByIdentifier(internalIdentifier));
}

void SWServerWorker::matchAll(const ServiceWorkerClientQueryOptions& options, ServiceWorkerClientsMatchAllCallback&& callback)
{
    ASSERT(m_server);
    if (!m_server)
        return callback({ });
    return protect(*server())->matchAll(*this, options, WTF::move(callback));
}

String SWServerWorker::userAgent() const
{
    ASSERT(m_server);
    if (!m_server)
        return { };
    return protect(server())->serviceWorkerClientUserAgent(origin());
}

void SWServerWorker::setScriptResource(URL&& url, ServiceWorkerContextData::ImportedScript&& script)
{
    m_scriptResourceMap.set(WTF::move(url), WTF::move(script));
}

void SWServerWorker::didSaveScriptsToDisk(ScriptBuffer mainScript, MemoryCompactRobinHoodHashMap<URL, ScriptBuffer> importedScripts)
{
    // Send mmap'd version of the scripts to the ServiceWorker process so we can save dirty memory.
    if (RefPtr contextConnection = this->contextConnection())
        contextConnection->didSaveScriptsToDisk(identifier(), mainScript, importedScripts);

    // The scripts were saved to disk, replace our scripts with the mmap'd version to save dirty memory.
    ASSERT(mainScript == m_script); // Do a memcmp to make sure the scripts are identical.
    m_script = WTF::move(mainScript);
    for (auto& pair : importedScripts) {
        auto it = m_scriptResourceMap.find(pair.key);
        ASSERT(it != m_scriptResourceMap.end());
        if (it == m_scriptResourceMap.end())
            continue;
        ASSERT(it->value.script == pair.value); // Do a memcmp to make sure the scripts are identical.
        it->value.script = WTF::move(pair.value);
    }
}

void SWServerWorker::setWorkerScripts(ScriptBuffer mainScript, MemoryCompactRobinHoodHashMap<URL, ScriptBuffer> importedScripts)
{
    ASSERT(m_needsScriptLoading);
    m_script = WTF::move(mainScript);
    for (auto& [url, script] : importedScripts) {
        auto it = m_scriptResourceMap.find(url);
        if (it != m_scriptResourceMap.end())
            it->value.script = WTF::move(script);
    }
    m_needsScriptLoading = false;
}

bool SWServerWorker::isIdle(Seconds idleTime) const
{
    return !m_hasPendingEvents && (ApproximateTime::now() - m_lastNeedRunningTime) > idleTime;
}

void SWServerWorker::whenActivated(CompletionHandler<void(bool)>&& handler)
{
    if (state() == ServiceWorkerState::Activating) {
        m_whenActivatedHandlers.append(WTF::move(handler));
        return;
    }
    ASSERT(state() == ServiceWorkerState::Activated);
    handler(state() == ServiceWorkerState::Activated);
}

void SWServerWorker::setState(ServiceWorkerState state)
{
    if (state == ServiceWorkerState::Redundant)
        terminate();

    m_data.state = state;

    HashSet<SWServerConnectionIdentifier> connectionIdentifiers;

    ASSERT(m_registration || state == ServiceWorkerState::Redundant);
    if (RefPtr registration = m_registration.get()) {
        registration->forEachConnection([&](auto& connection) {
            connectionIdentifiers.add(connection.identifier());
        });
    }
    for (auto connectionIdentifierWithServiceWorker : m_connectionsWithServiceWorker.values())
        connectionIdentifiers.add(connectionIdentifierWithServiceWorker);

    for (auto connectionIdentifier : connectionIdentifiers) {
        if (RefPtr connection = protect(server())->connection(connectionIdentifier))
            connection->updateWorkerStateInClient(this->identifier(), state);
    }

    if (state == ServiceWorkerState::Activated || state == ServiceWorkerState::Redundant)
        callWhenActivatedHandler(state == ServiceWorkerState::Activated);
}

void SWServerWorker::callWhenActivatedHandler(bool success)
{
    auto whenActivatedHandlers = WTF::move(m_whenActivatedHandlers);
    for (auto& handler : whenActivatedHandlers)
        handler(success);
}

SWServerRegistration* SWServerWorker::registration() const
{
    return m_registration.get();
}

bool SWServerWorker::shouldBeTerminated() const
{
    return !m_functionalEventCounter && !m_isInspected && m_server && !protect(server())->hasClientsWithOrigin(origin());
}

void SWServerWorker::terminateIfPossible()
{
    if (!shouldBeTerminated()) {
        m_terminationIfPossibleTimer.stop();
        return;
    }

    m_terminationIfPossibleTimer.startOneShot(SWServer::defaultFunctionalEventDuration);
}

void SWServerWorker::terminationIfPossibleTimerFired()
{
    if (!shouldBeTerminated())
        return;

    terminate();
    protect(server())->removeContextConnectionIfPossible(topRegistrableDomain());
}

Vector<URL> SWServerWorker::importedScriptURLs() const
{
    return copyToVector(m_scriptResourceMap.keys());
}

bool SWServerWorker::matchingImportedScripts(Vector<std::pair<URL, ScriptBuffer>> scripts) const
{
    for (auto& script : scripts) {
        auto iterator = m_scriptResourceMap.find(script.first);
        if (iterator == m_scriptResourceMap.end() || iterator->value.script != script.second)
            return false;
    }
    return true;
}

// https://w3c.github.io/ServiceWorker/#check-router-registration-limit-algorithm
NODELETE static bool checkRouterRegistrationLimit(const Vector<ServiceWorkerRoute>& currentRoutes, const Vector<ServiceWorkerRoute>& newRoutes)
{
    size_t result = 1024;
    for (auto& route : currentRoutes) {
        auto countResult = countRouterInnerConditions(route.condition, result, 10);
        if (!countResult)
            return false;
        result = *countResult;
    }
    for (auto& route : newRoutes) {
        auto countResult = countRouterInnerConditions(route.condition, result, 10);
        if (!countResult)
            return false;
        result = *countResult;
    }
    return true;
}

std::optional<ExceptionData> SWServerWorker::addRoutes(Vector<ServiceWorkerRoute>&& routes)
{
    for (auto& route : routes) {
        if (auto exception = validateServiceWorkerRoute(route))
            return exception;
    }

    if (!checkRouterRegistrationLimit(m_routes, routes))
        return ExceptionData { ExceptionCode::TypeError, "Router registration limit is hit"_s };

    m_routes.appendVector(WTF::move(routes));

    return { };
}

} // namespace WebCore
