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

#include "Logging.h"
#include "NetworkConnectionToWebProcess.h"
#include "NetworkProcess.h"
#include "PermissionChecked.h"
#include <WebCore/Cookie.h>
#include <WebCore/CookieHeaderString.h>
#include <WebCore/RegistrableDomain.h>

namespace WebKit {

// The pre-ordained permission check for cookies about to be sent to a web content process.
// Under site isolation a web content process is entitled to the cookies of the sites it
// hosts and no others, so a cookie may only be sent to it once the network process has
// established that this process may have this cookie.
//
// The authority evaluates that question once, on construction, from inputs it looks up
// itself; it cannot be handed a verdict. Its decision is then both what the handler uses
// to decide whether to answer at all, and what mints the token:
//
//     auto authority = CookieRecipientAuthority::forDocumentCookieAccess(*this, "getRawCookies"_s, firstParty, url, &sameSiteInfo);
//     MESSAGE_CHECK_COMPLETION(authority.access() != CookieRecipientAuthority::Access::Terminate, completionHandler(PermissionCheckedCookies::empty()));
//     if (authority.access() != CookieRecipientAuthority::Access::Permitted)
//         return completionHandler(PermissionCheckedCookies::empty());
//     ...
//     auto permitted = PermissionCheckedCookies::check(authority, WTF::move(cookies));
//     if (!permitted)
//         return completionHandler(PermissionCheckedCookies::empty());
//     completionHandler(WTF::move(*permitted));
//
class CookieRecipientAuthority {
public:
    enum class Access : uint8_t { Permitted, Denied, Terminate };

    // Cookies read on behalf of a document. Two independent things must hold: the process must
    // have authority over the first party the read was made against, and it must be entitled to
    // the cookies of the host being read.
    //
    // The second is the part the first-party check cannot answer. A process legitimately hosting
    // example.com may name example.com as a first party while asking for the cookies of any
    // unrelated url, so without checking the host as well, authority over one site buys the
    // cookies of every site.
    static CookieRecipientAuthority forDocumentCookieAccess(NetworkConnectionToWebProcess& connection, ASCIILiteral messageName, const URL& firstParty, const URL& url, const WebCore::SameSiteInfo* sameSiteInfo = nullptr)
    {
        auto access = [&] {
            switch (connection.validateCookieAccess(messageName, firstParty, url, sameSiteInfo)) {
            case NetworkConnectionToWebProcess::CookieAccess::Allow:
                return Access::Permitted;
            case NetworkConnectionToWebProcess::CookieAccess::Disallow:
                return Access::Denied;
            case NetworkConnectionToWebProcess::CookieAccess::Terminate:
                return Access::Terminate;
            }
            RELEASE_ASSERT_NOT_REACHED();
        }();

        if (access == Access::Permitted && !isEntitledToDomain(connection, WebCore::RegistrableDomain { url })) {
            RELEASE_LOG_ERROR(Network, "%" PUBLIC_LOG_STRING ": denying cookies for a host this web process is not entitled to", messageName.characters());
            access = Access::Denied;
        }

        return CookieRecipientAuthority { access };
    }

    // Cookie change notifications. The process must still be entitled to the host, and must have
    // subscribed to it. The subscription alone is not enough: it only records that a request was
    // made and accepted, not that it should have been.
    //
    // Both failures are races rather than attacks - an unsubscribe or a process being reused can
    // both get here legitimately - so they are denied, not fatal.
    static CookieRecipientAuthority forSubscribedCookieChangeHost(NetworkConnectionToWebProcess& connection, const String& host)
    {
#if HAVE(COOKIE_CHANGE_LISTENER_API)
        if (!connection.m_hostsWithCookieListeners.contains(host))
            return CookieRecipientAuthority { Access::Denied };
        if (!isEntitledToDomain(connection, WebCore::RegistrableDomain::uncheckedCreateFromHost(host)))
            return CookieRecipientAuthority { Access::Denied };
        return CookieRecipientAuthority { Access::Permitted };
#else
        UNUSED_PARAM(connection);
        UNUSED_PARAM(host);
        return CookieRecipientAuthority { Access::Denied };
#endif
    }

    Access access() const { return m_access; }

    template<typename T>
    Expected<T, IPC::PermissionFailure> checkPermissionToReceive(T&& value) const
    {
        switch (m_access) {
        case Access::Permitted:
            return Expected<T, IPC::PermissionFailure> { WTF::move(value) };
        case Access::Denied:
            return std::unexpected { IPC::PermissionFailure::Deny };
        case Access::Terminate:
            return std::unexpected { IPC::PermissionFailure::Terminate };
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

private:
    // A process is entitled to a domain's cookies if it hosts content for that domain, or if it
    // may name that domain as a first party - which it can only do if it was navigated to that
    // domain as a first party, so this does not widen authority beyond sites the process has
    // legitimately been.
    //
    // Without site isolation there is no per-host authority to check: one process hosts every
    // site a page pulls in, including its cross-site subframes, and WebProcessProxy only records
    // the main frame's site as hosted. Asking the question there could only produce false
    // denials, so it is not asked.
    //
    // usesSingleWebProcess is deliberately NOT part of this gate. A single process still records
    // every site it commits, so the question remains answerable, and gating on it would disable
    // the check in configurations that do enable site isolation.
    static bool isEntitledToDomain(NetworkConnectionToWebProcess& connection, const WebCore::RegistrableDomain& domain)
    {
        if (!connection.siteIsolationEnabled())
            return true;

        Ref networkProcess = connection.networkProcess();
        if (networkProcess->hostsDomain(connection.webProcessIdentifier(), domain))
            return true;
        return networkProcess->allowsFirstPartyForCookies(connection.webProcessIdentifier(), domain) == NetworkProcess::AllowCookieAccess::Allow;
    }

    explicit CookieRecipientAuthority(Access access)
        : m_access(access)
    {
    }

    Access m_access;
};

using PermissionCheckedCookies = IPC::PermissionChecked<Vector<WebCore::Cookie>>;
using PermissionCheckedOptionalCookies = IPC::PermissionChecked<std::optional<Vector<WebCore::Cookie>>>;
using PermissionCheckedCookieHeader = IPC::PermissionChecked<WebCore::CookieHeaderString>;

} // namespace WebKit

namespace IPC {

template<> struct IsPreordainedPermissionChecker<WebKit::CookieRecipientAuthority, Vector<WebCore::Cookie>> : std::true_type { };
template<> struct IsPreordainedPermissionChecker<WebKit::CookieRecipientAuthority, std::optional<Vector<WebCore::Cookie>>> : std::true_type { };
template<> struct IsPreordainedPermissionChecker<WebKit::CookieRecipientAuthority, WebCore::CookieHeaderString> : std::true_type { };

} // namespace IPC
