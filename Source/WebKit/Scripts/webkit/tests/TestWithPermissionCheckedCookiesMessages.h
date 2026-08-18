/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "ArgumentCoders.h"
#include "Connection.h"
#include "MessageNames.h"
#include "PermissionChecked.h"
#include <wtf/Forward.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>


namespace Messages {
namespace TestWithPermissionCheckedCookies {

static inline IPC::ReceiverName messageReceiverName()
{
#if ASSERT_ENABLED
    static std::once_flag onceFlag;
    std::call_once(
        onceFlag,
        [&] {
            ASSERT(isInWebProcess());
        }
    );
#endif
    return IPC::ReceiverName::TestWithPermissionCheckedCookies;
}

class CookiesAdded {
public:
    using Arguments = std::tuple<String, Vector<WebCore::Cookie>>;

    static IPC::MessageName name() { return IPC::MessageName::TestWithPermissionCheckedCookies_CookiesAdded; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    CookiesAdded(const String& host, IPC::PermissionChecked<Vector<WebCore::Cookie>>&& cookies)
        : m_host(host)
        , m_cookies(WTF::move(cookies))
    {
        ASSERT(isInNetworkProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_host;
        SUPPRESS_FORWARD_DECL_ARG encoder << WTF::move(m_cookies);
    }

private:
    const String& m_host;
    SUPPRESS_FORWARD_DECL_MEMBER IPC::PermissionChecked<Vector<WebCore::Cookie>>&& m_cookies;
};

class CookieHeaderChanged {
public:
    using Arguments = std::tuple<WebCore::CookieHeaderString>;

    static IPC::MessageName name() { return IPC::MessageName::TestWithPermissionCheckedCookies_CookieHeaderChanged; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit CookieHeaderChanged(IPC::PermissionChecked<WebCore::CookieHeaderString>&& cookieString)
        : m_cookieString(WTF::move(cookieString))
    {
        ASSERT(isInNetworkProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << WTF::move(m_cookieString);
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER IPC::PermissionChecked<WebCore::CookieHeaderString>&& m_cookieString;
};

} // namespace TestWithPermissionCheckedCookies
} // namespace Messages
