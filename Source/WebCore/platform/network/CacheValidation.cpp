/*
 * Copyright (C) 2014-2017 Apple Inc. All rights reserved.
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
#include "CacheValidation.h"

#include "CookieJar.h"
#include "HTTPHeaderMap.h"
#include "ResourceLoaderOptions.h"
#include "ResourceRequest.h"
#include "ResourceResponse.h"
#include "SameSiteInfo.h"
#include "WebCore-Swift.h"
#include <wtf/SHA1.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/Base64.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

void updateResponseHeadersAfterRevalidation(ResourceResponse& response, const ResourceResponse& validatingResponse)
{
    // Freshening stored response upon validation:
    // http://tools.ietf.org/html/rfc7234#section-4.3.4
    for (const auto& header : validatingResponse.httpHeaderFields()) {
        // Entity headers should not be sent by servers when generating a 304
        // response; misconfigured servers send them anyway. We shouldn't allow
        // such headers to update the original request. We'll base this on the
        // list defined by RFC2616 7.1, with a few additions for extension headers
        // we care about.
        if (!shouldUpdateHeaderAfterRevalidation(header.key))
            continue;
        if (header.keyAsHTTPHeaderName)
            response.setHTTPHeaderField(*header.keyAsHTTPHeaderName, header.value);
        else
            response.setUncommonHTTPHeaderField(header.key, header.value);
    }
}

Seconds computeCurrentAge(const ResourceResponse& response, WallTime responseTime)
{
    return cacheCurrentAge(response.date(), response.age(), responseTime);
}

Seconds computeFreshnessLifetimeForHTTPFamily(const ResourceResponse& response, WallTime responseTime)
{
    return cacheFreshnessLifetime(response, responseTime);
}

bool cacheResponseHasExpiresHeader(const ResourceResponse& response)
{
    return response.httpHeaderFields().contains(HTTPHeaderName::Expires);
}

void updateRedirectChainStatus(RedirectChainCacheStatus& redirectChainCacheStatus, const ResourceResponse& response, const ResourceLoaderOptions& options)
{
    updateCacheRedirectChainStatus(redirectChainCacheStatus, response, options.cachingPolicy == CachingPolicy::AllowCachingMainResourcePrefetch);
}

CacheControlDirectives parseCacheControlDirectives(const HTTPHeaderMap& headers)
{
    String cacheControlValue = headers.get(HTTPHeaderName::CacheControl);
    String pragmaValue = headers.get(HTTPHeaderName::Pragma);
    if (cacheControlValue.isEmpty() && pragmaValue.isEmpty())
        return { };
    return cacheControlDirectives(cacheControlValue, pragmaValue);
}

std::optional<SHA1::Digest> computeCookieHeaderDigestForVary(const String& cookieHeader, uint64_t salt)
{
    if (cookieHeader.isNull())
        return std::nullopt;

    SHA1 sha1;
    if (salt)
        sha1.addBytes(asByteSpan(salt));
    sha1.addUTF8Bytes(cookieHeader);

    SHA1::Digest digest;
    sha1.computeHash(digest);
    return digest;
}

// Varying header values are stored and compared as strings.
String encodeCookieHeaderDigestForVary(const std::optional<SHA1::Digest>& digest)
{
    if (!digest)
        return { };
    return base64EncodeToString(*digest);
}

static String cookieRequestHeaderFieldValueForVary(const CookieJar* cookieJar, const ResourceRequest& request)
{
    if (!cookieJar)
        return { };

    return encodeCookieHeaderDigestForVary(cookieJar->cookieRequestHeaderFieldValueDigest(request.firstPartyForCookies(), SameSiteInfo::create(request), request.url(), CookieJar::shouldIncludeSecureCookies(request.url())));
}

String headerValueForVary(const ResourceRequest& request, StringView headerName, NOESCAPE const Function<String()>& cookieRequestHeaderFieldValueFunction)
{
    // Explicit handling for cookies is needed because they are added magically by the networking layer.
    // FIXME: The value might have changed between making the request and retrieving the cookie here.
    // We could fetch the cookie when making the request but that seems overkill as the case is very rare and it
    // is a blocking operation. This should be sufficient to cover reasonable cases.
    if (headerName == httpHeaderNameString(HTTPHeaderName::Cookie))
        return cookieRequestHeaderFieldValueFunction();
    return request.httpHeaderField(headerName);
}

Vector<std::pair<String, String>> collectVaryingRequestHeaders(const ResourceResponse& response, NOESCAPE const Function<String(StringView headerName)>& headerValueForVaryFunction)
{
    auto varyValue = response.httpHeaderField(HTTPHeaderName::Vary);
    if (varyValue.isEmpty())
        return { };

    Vector<std::pair<String, String>> headers;
    for (auto varyHeaderName : StringView(varyValue).split(',')) {
        auto headerName = varyHeaderName.trim(isUnicodeCompatibleASCIIWhitespace<char16_t>);
        headers.append(std::pair { headerName.toString(), headerValueForVaryFunction(headerName) });
    }
    return headers;
}

Vector<std::pair<String, String>> collectVaryingRequestHeaders(const CookieJar* cookieJar, const ResourceRequest& request, const ResourceResponse& response)
{
    return collectVaryingRequestHeaders(response, [&] (StringView headerName) {
        return headerValueForVary(request, headerName, [&] {
            return cookieRequestHeaderFieldValueForVary(cookieJar, request);
        });
    });
}

bool verifyVaryingRequestHeaders(const Vector<std::pair<String, String>>& varyingRequestHeaders, NOESCAPE const Function<String(const String&)>& headerValueForVary)
{
    return cacheVaryingRequestHeadersMatch(varyingRequestHeaders, headerValueForVary);
}

bool verifyVaryingRequestHeaders(const CookieJar* cookieJar, const Vector<std::pair<String, String>>& varyingRequestHeaders, const ResourceRequest& request)
{
    return verifyVaryingRequestHeaders(varyingRequestHeaders, [&] (const String& headerName) {
        return headerValueForVary(request, headerName, [&] {
            return cookieRequestHeaderFieldValueForVary(cookieJar, request);
        });
    });
}

}
