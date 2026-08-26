/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include "Untrusted.h"
#include "WebSWServerConnection.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/Site.h>
#include <wtf/URL.h>

namespace WebKit {

class ServiceWorkerClientOriginAuthority : public IPC::UntrustedContainerValidation<ServiceWorkerClientOriginAuthority> {
public:
    using IPC::UntrustedContainerValidation<ServiceWorkerClientOriginAuthority>::validateUntrusted;

    explicit ServiceWorkerClientOriginAuthority(WebSWServerConnection& connection)
        : m_connection(connection)
    {
    }

    IPC::Validated<WebCore::SecurityOriginData> validateUntrusted(WebCore::SecurityOriginData&& origin) const
    {
        if (!m_connection->checkTopOrigin(origin))
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<WebCore::SecurityOriginData> { WTF::move(origin) };
    }

    IPC::Validated<URL> validateUntrusted(URL&& url) const
    {
        if (!m_connection->checkTopOrigin(WebCore::SecurityOriginData::fromURL(url)))
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<URL> { WTF::move(url) };
    }

    IPC::Validated<WebCore::ClientOrigin> validateUntrusted(WebCore::ClientOrigin&& origin) const
    {
        if (!m_connection->checkTopOrigin(origin.topOrigin))
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<WebCore::ClientOrigin> { WTF::move(origin) };
    }

private:
    Ref<WebSWServerConnection> m_connection;
};

// clients.openWindow() and WindowClient.navigate() both require a same-origin URL, so a
// service worker process may only name URLs within the site its workers were created for.
class ServiceWorkerSiteAuthority : public IPC::UntrustedContainerValidation<ServiceWorkerSiteAuthority> {
public:
    using IPC::UntrustedContainerValidation<ServiceWorkerSiteAuthority>::validateUntrusted;

    explicit ServiceWorkerSiteAuthority(const WebCore::Site& site)
        : m_domain(site.domain())
    {
    }

    IPC::Validated<URL> validateUntrusted(URL&& url) const
    {
        if (WebCore::RegistrableDomain { url } != m_domain)
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<URL> { WTF::move(url) };
    }

private:
    WebCore::RegistrableDomain m_domain;
};

} // namespace WebKit

namespace IPC {

template<> struct IsPreordainedValidator<WebKit::ServiceWorkerClientOriginAuthority, WebCore::SecurityOriginData> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::ServiceWorkerClientOriginAuthority, WebCore::ClientOrigin> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::ServiceWorkerClientOriginAuthority, URL> : std::true_type { };

template<> struct IsPreordainedValidator<WebKit::ServiceWorkerSiteAuthority, URL> : std::true_type { };

} // namespace IPC
