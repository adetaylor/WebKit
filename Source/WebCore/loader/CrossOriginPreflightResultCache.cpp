/*
 * Copyright (C) 2008, 2009 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 *
 */

#include "config.h"
#include "CrossOriginPreflightResultCache.h"

#include "HTTPHeaderNames.h"
#include "ResourceResponse.h"
#include "WebCore-Swift.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

CrossOriginPreflightResultCache::CrossOriginPreflightResultCache() = default;

std::expected<UniqueRef<CrossOriginPreflightResultCacheItem>, String> CrossOriginPreflightResultCacheItem::create(StoredCredentialsPolicy policy, const ResourceResponse& response)
{
    auto allowMethods = response.httpHeaderField(HTTPHeaderName::AccessControlAllowMethods);
    auto allowHeaders = response.httpHeaderField(HTTPHeaderName::AccessControlAllowHeaders);
    double expiryDelta = 0;
    if (auto message = crossOriginPreflightResultCacheItemFailure(allowMethods, allowHeaders, response.httpHeaderField(HTTPHeaderName::AccessControlMaxAge), expiryDelta); !message.isNull())
        return makeUnexpected(WTF::move(message));

    return makeUniqueRef<CrossOriginPreflightResultCacheItem>(MonotonicTime::now() + Seconds { expiryDelta }, policy, WTF::move(allowMethods), WTF::move(allowHeaders));
}

std::optional<String> CrossOriginPreflightResultCacheItem::validateMethodAndHeaders(const String& method, const HTTPHeaderMap& requestHeaders) const
{
    return crossOriginPreflightResultCacheItemValidate(m_allowMethods, m_allowHeaders, m_storedCredentialsPolicy, method, requestHeaders);
}

bool CrossOriginPreflightResultCacheItem::allowsRequest(StoredCredentialsPolicy storedCredentialsPolicy, const String& method, const HTTPHeaderMap& requestHeaders) const
{
    if (m_absoluteExpiryTime < MonotonicTime::now())
        return false;
    return crossOriginPreflightResultCacheItemAllowsRequest(m_allowMethods, m_allowHeaders, m_storedCredentialsPolicy, storedCredentialsPolicy, method, requestHeaders);
}

CrossOriginPreflightResultCache& CrossOriginPreflightResultCache::singleton()
{
    ASSERT(isMainThread());

    static NeverDestroyed<CrossOriginPreflightResultCache> cache;
    return cache;
}

void CrossOriginPreflightResultCache::appendEntry(PAL::SessionID sessionID, const ClientOrigin& origin, const URL& url, std::unique_ptr<CrossOriginPreflightResultCacheItem> preflightResult)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    m_preflightHashMap.set(std::make_tuple(sessionID, origin, url), WTF::move(preflightResult));
}

bool CrossOriginPreflightResultCache::canSkipPreflight(PAL::SessionID sessionID, const ClientOrigin& origin, const URL& url, StoredCredentialsPolicy storedCredentialsPolicy, const String& method, const HTTPHeaderMap& requestHeaders)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    auto it = m_preflightHashMap.find(std::make_tuple(sessionID, origin, url));
    if (it == m_preflightHashMap.end())
        return false;

    if (it->value->allowsRequest(storedCredentialsPolicy, method, requestHeaders))
        return true;

    m_preflightHashMap.remove(it);
    return false;
}

void CrossOriginPreflightResultCache::clear()
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    m_preflightHashMap.clear();
}

} // namespace WebCore
