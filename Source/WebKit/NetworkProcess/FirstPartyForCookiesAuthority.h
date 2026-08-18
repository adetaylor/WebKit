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

#include "NetworkProcess.h"
#include "Untrusted.h"
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/Site.h>
#include <wtf/URL.h>

namespace WebKit {

// The pre-ordained validation procedure for an origin, site, domain or URL that a web
// content process sent to the network process: the sending process must be one the UI
// process registered as a first party for the domain being named.
//
// Recovers the value from an IPC::Untrusted<T>:
//
//     auto domain = WTF::move(untrustedDomain).validate(FirstPartyForCookiesAuthority { *this });
//     MESSAGE_CHECK(domain);
//
class FirstPartyForCookiesAuthority {
public:
    FirstPartyForCookiesAuthority(NetworkProcess& networkProcess, WebCore::ProcessIdentifier webProcessIdentifier)
        : m_networkProcess(networkProcess)
        , m_webProcessIdentifier(webProcessIdentifier)
    {
    }

    IPC::Validated<WebCore::SecurityOriginData> validateUntrusted(WebCore::SecurityOriginData&& origin) const
    {
        auto domain = WebCore::RegistrableDomain { origin };
        return validateDomain(domain, WTF::move(origin));
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
        return validateDomain(domain, WTF::move(site));
    }

    IPC::Validated<URL> validateUntrusted(URL&& url) const
    {
        auto domain = WebCore::RegistrableDomain { url };
        return validateDomain(domain, WTF::move(url));
    }

private:
    std::optional<IPC::ValidationFailure> failureFor(const WebCore::RegistrableDomain& domain) const
    {
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
    IPC::Validated<T> validateDomain(const WebCore::RegistrableDomain& domain, T&& value) const
    {
        if (auto failure = failureFor(domain))
            return std::unexpected { *failure };
        return IPC::Validated<T> { WTF::move(value) };
    }

    Ref<NetworkProcess> m_networkProcess;
    WebCore::ProcessIdentifier m_webProcessIdentifier;
};

} // namespace WebKit

namespace IPC {

template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, WebCore::SecurityOriginData> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, WebCore::RegistrableDomain> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, WebCore::Site> : std::true_type { };
template<> struct IsPreordainedValidator<WebKit::FirstPartyForCookiesAuthority, URL> : std::true_type { };

} // namespace IPC
