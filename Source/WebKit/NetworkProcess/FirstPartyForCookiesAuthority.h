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

#include "NetworkConnectionToWebProcess.h"
#include "NetworkProcess.h"
#include "Untrusted.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/Site.h>

namespace WebKit {

// Without site isolation one process hosts every site a page pulls in, so neither the
// first-party set nor the hosted-domain set says anything about what it may name.
inline bool canCheckDomainAuthority(NetworkProcess& networkProcess, WebCore::ProcessIdentifier identifier)
{
    CheckedPtr connection = networkProcess.webProcessConnection(identifier);
    if (!connection)
        return true;
    auto preferences = connection->sharedPreferencesForWebProcessValue();
    return preferences.siteIsolationEnabled && !preferences.usesSingleWebProcess;
}

class FirstPartyForCookiesAuthority : public IPC::UntrustedContainerValidation<FirstPartyForCookiesAuthority> {
public:
    using IPC::UntrustedContainerValidation<FirstPartyForCookiesAuthority>::validateUntrusted;

    FirstPartyForCookiesAuthority(NetworkProcess& networkProcess, WebCore::ProcessIdentifier webProcessIdentifier)
        : m_networkProcess(networkProcess)
        , m_webProcessIdentifier(webProcessIdentifier)
    {
    }

    IPC::Validated<WebCore::SecurityOriginData> validateUntrusted(WebCore::SecurityOriginData&& origin) const
    {
        auto domain = WebCore::RegistrableDomain { origin };
        return validated(domain, WTF::move(origin));
    }

    IPC::Validated<WebCore::RegistrableDomain> validateUntrusted(WebCore::RegistrableDomain&& domain) const
    {
        if (auto failure = failureFor(domain))
            return std::unexpected { *failure };
        return IPC::Validated<WebCore::RegistrableDomain> { WTF::move(domain) };
    }

    IPC::Validated<WebCore::Site> validateUntrusted(WebCore::Site&& site) const
    {
        auto domain = site.domain();
        return validated(domain, WTF::move(site));
    }

private:
    std::optional<IPC::ValidationFailure> failureFor(const WebCore::RegistrableDomain& domain) const
    {
        if (!canCheckDomainAuthority(m_networkProcess, m_webProcessIdentifier))
            return std::nullopt;

        switch (m_networkProcess->allowsFirstPartyForCookies(m_webProcessIdentifier, domain)) {
        case NetworkProcess::AllowCookieAccess::Allow:
            return std::nullopt;
        case NetworkProcess::AllowCookieAccess::Disallow:
            return IPC::ValidationFailure::Ignore;
        case NetworkProcess::AllowCookieAccess::Terminate:
            return IPC::ValidationFailure::Terminate;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    template<typename T>
    IPC::Validated<T> validated(const WebCore::RegistrableDomain& domain, T&& value) const
    {
        if (auto failure = failureFor(domain))
            return std::unexpected { *failure };
        return IPC::Validated<T> { WTF::move(value) };
    }

    Ref<NetworkProcess> m_networkProcess;
    WebCore::ProcessIdentifier m_webProcessIdentifier;
};

class HostedDomainAuthority : public IPC::UntrustedContainerValidation<HostedDomainAuthority> {
public:
    using IPC::UntrustedContainerValidation<HostedDomainAuthority>::validateUntrusted;

    HostedDomainAuthority(NetworkProcess& networkProcess, WebCore::ProcessIdentifier webProcessIdentifier)
        : m_networkProcess(networkProcess)
        , m_webProcessIdentifier(webProcessIdentifier)
    {
    }

    IPC::Validated<WebCore::RegistrableDomain> validateUntrusted(WebCore::RegistrableDomain&& domain) const
    {
        if (!hosts(domain))
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<WebCore::RegistrableDomain> { WTF::move(domain) };
    }

    IPC::Validated<WebCore::SecurityOriginData> validateUntrusted(WebCore::SecurityOriginData&& origin) const
    {
        if (!hosts(WebCore::RegistrableDomain { origin }))
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<WebCore::SecurityOriginData> { WTF::move(origin) };
    }

    IPC::Validated<WebCore::ClientOrigin> validateUntrusted(WebCore::ClientOrigin&& origin) const
    {
        if (!hosts(WebCore::RegistrableDomain { origin.clientOrigin }))
            return std::unexpected { IPC::ValidationFailure::Terminate };
        if (auto failure = FirstPartyForCookiesAuthority { m_networkProcess, m_webProcessIdentifier }
            .validateUntrusted(WebCore::SecurityOriginData { origin.topOrigin }); !failure)
            return std::unexpected { failure.error() };
        return IPC::Validated<WebCore::ClientOrigin> { WTF::move(origin) };
    }

private:
    bool hosts(const WebCore::RegistrableDomain& domain) const
    {
        return !canCheckDomainAuthority(m_networkProcess, m_webProcessIdentifier)
            || m_networkProcess->hostsDomain(m_webProcessIdentifier, domain);
    }

    Ref<NetworkProcess> m_networkProcess;
    WebCore::ProcessIdentifier m_webProcessIdentifier;
};

} // namespace WebKit

namespace IPC {

template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, WebCore::SecurityOriginData> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, WebCore::RegistrableDomain> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, WebCore::Site> : std::true_type { };

template<> struct IsPreordainedValidator<WebKit::HostedDomainAuthority, WebCore::RegistrableDomain> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::HostedDomainAuthority, WebCore::SecurityOriginData> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::HostedDomainAuthority, WebCore::ClientOrigin> : std::true_type { };

} // namespace IPC
