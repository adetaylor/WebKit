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
#include "SWServerToContextConnection.h"

#include "SWServer.h"
#include "SWServerWorker.h"
#include <wtf/CompletionHandler.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(SWServerToContextConnection);

SWServerToContextConnection::SWServerToContextConnection(SWServer& server, Site&& site, std::optional<ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier)
    : m_server(server)
    , m_site(WTF::move(site))
    , m_serviceWorkerPageIdentifier(serviceWorkerPageIdentifier)
{
}

SWServerToContextConnection::~SWServerToContextConnection() = default;

SWServer* SWServerToContextConnection::server() const
{
    return m_server.get();
}

void SWServerToContextConnection::matchAll(ServiceWorkerIdentifier serviceWorkerIdentifier, const ServiceWorkerClientQueryOptions& options, CompletionHandler<void(Vector<WebCore::ServiceWorkerClientData>&&)>&& callback)
{
    RefPtr worker = SWServerWorker::existingWorkerForIdentifier(serviceWorkerIdentifier);
    if (!worker) {
        callback({ });
        return;
    }

    worker->matchAll(options, WTF::move(callback));
}

void SWServerToContextConnection::findClientByVisibleIdentifier(ServiceWorkerIdentifier serviceWorkerIdentifier, const String& clientIdentifier, CompletionHandler<void(std::optional<WebCore::ServiceWorkerClientData>&&)>&& callback)
{
    if (RefPtr worker = SWServerWorker::existingWorkerForIdentifier(serviceWorkerIdentifier))
        worker->findClientByVisibleIdentifier(clientIdentifier, WTF::move(callback));
    else
        callback({ });
}

void SWServerToContextConnection::claim(ServiceWorkerIdentifier serviceWorkerIdentifier, CompletionHandler<void(std::optional<ExceptionData>&&)>&& callback)
{
    RefPtr worker = SWServerWorker::existingWorkerForIdentifier(serviceWorkerIdentifier);
    RefPtr server = worker ? worker->server() : nullptr;
    callback(server ? server->claim(*worker) : std::nullopt);
}

bool SWServerToContextConnection::terminateWhenPossible()
{
    m_shouldTerminateWhenPossible = true;

    bool hasServiceWorkerWithPendingEvents = false;
    protect(server())->forEachServiceWorker([&](auto& worker) {
        if (worker.isRunning() && worker.topRegistrableDomain() == m_site.domain() && worker.hasPendingEvents()) {
            hasServiceWorkerWithPendingEvents = true;
            return false;
        }
        return true;
    });

    // FIXME: If there is a service worker with pending events and we don't close the connection right away, we'd ideally keep
    // track of this and close the connection once it becomes idle.
    return !hasServiceWorkerWithPendingEvents;
}

} // namespace WebCore
