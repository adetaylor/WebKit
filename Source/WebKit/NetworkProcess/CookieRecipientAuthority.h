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
#include "PermissionChecked.h"
#include <WebCore/Cookie.h>
#include <WebCore/CookieHeaderString.h>

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

    // Cookies read on behalf of a document: the receiving process must have authority over
    // the first party the read was made against, and the read must be a plausible same-site
    // request.
    static CookieRecipientAuthority forDocumentCookieAccess(NetworkConnectionToWebProcess& connection, ASCIILiteral messageName, const URL& firstParty, const URL& url, const WebCore::SameSiteInfo* sameSiteInfo = nullptr)
    {
        switch (connection.validateCookieAccess(messageName, firstParty, url, sameSiteInfo)) {
        case NetworkConnectionToWebProcess::CookieAccess::Allow:
            return CookieRecipientAuthority { Access::Permitted };
        case NetworkConnectionToWebProcess::CookieAccess::Disallow:
            return CookieRecipientAuthority { Access::Denied };
        case NetworkConnectionToWebProcess::CookieAccess::Terminate:
            return CookieRecipientAuthority { Access::Terminate };
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    // Cookie change notifications: the receiving process is entitled to notifications for a
    // host only if it subscribed to that host, which required a cookie access check for the
    // document making the subscription. A host it never subscribed to - or has since
    // unsubscribed from - is a race rather than an attack, so it is denied, not fatal.
    static CookieRecipientAuthority forSubscribedCookieChangeHost(const NetworkConnectionToWebProcess& connection, const String& host)
    {
#if HAVE(COOKIE_CHANGE_LISTENER_API)
        if (connection.m_hostsWithCookieListeners.contains(host))
            return CookieRecipientAuthority { Access::Permitted };
#else
        UNUSED_PARAM(connection);
        UNUSED_PARAM(host);
#endif
        return CookieRecipientAuthority { Access::Denied };
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
