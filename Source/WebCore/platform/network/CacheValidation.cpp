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

// These response headers are not copied from a revalidated response to the
// cached response headers. For compatibility, this list is based on Chromium's
// net/http/http_response_headers.cc.
static constexpr std::array headersToIgnoreAfterRevalidation {
    "allow"_s,
    "connection"_s,
    "content-disposition"_s,
    "content-encoding"_s,
    "content-language"_s,
    "content-length"_s,
    "content-location"_s,
    "content-range"_s,
    "content-type"_s,
    "etag"_s,
    "keep-alive"_s,
    "last-modified"_s,
    "proxy-authenticate"_s,
    "proxy-connection"_s,
    "trailer"_s,
    "transfer-encoding"_s,
    "upgrade"_s,
    "www-authenticate"_s,
    "x-frame-options"_s,
    "x-xss-protection"_s,
};

// Some header prefixes mean "Don't copy this header from a 304 response.".
// Rather than listing all the relevant headers, we can consolidate them into
// this list, also grabbed from Chromium's net/http/http_response_headers.cc.
static constexpr std::array headerPrefixesToIgnoreAfterRevalidation {
    "x-content-"_s,
    "x-webkit-"_s
};

static inline bool shouldUpdateHeaderAfterRevalidation(const String& header)
{
    if (header.startsWithIgnoringASCIICase("content-security-"_s))
        return true;

    for (auto& headerToIgnore : headersToIgnoreAfterRevalidation) {
        if (equalIgnoringASCIICase(header, headerToIgnore))
            return false;
    }
    for (auto& prefixToIgnore : headerPrefixesToIgnoreAfterRevalidation) {
        // FIXME: Would be more efficient if we added an overload of
        // startsWithIgnoringASCIICase that takes a const char*.
        if (header.startsWithIgnoringASCIICase(prefixToIgnore))
            return false;
    }
    return true;
}

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
    // Age calculation:
    // http://tools.ietf.org/html/rfc7234#section-4.2.3
    // No compensation for latency as that is not terribly important in practice.
    auto dateValue = response.date();
    auto apparentAge = dateValue ? std::max(0_us, responseTime - *dateValue) : 0_us;
    auto ageValue = response.age().value_or(0_us);
    auto correctedInitialAge = std::max(apparentAge, ageValue);
    auto residentTime = WallTime::now() - responseTime;
    return correctedInitialAge + residentTime;
}

Seconds computeFreshnessLifetimeForHTTPFamily(const ResourceResponse& response, WallTime responseTime)
{
    if (!response.url().protocolIsInHTTPFamily())
        return 0_us;

    // Freshness Lifetime:
    // http://tools.ietf.org/html/rfc7234#section-4.2.1
    auto maxAge = response.cacheControlMaxAge();
    if (maxAge)
        return *maxAge;

    auto date = response.date();
    auto effectiveDate = date.value_or(responseTime);
    if (auto expires = response.expires())
        return *expires - effectiveDate;

    // Check if the expires header is present but invalid.
    if (response.httpHeaderFields().contains(HTTPHeaderName::Expires))
        return 0_us;

    // Implicit lifetime.
    switch (response.httpStatusCode()) {
    case 301: // Moved Permanently
    case 410: // Gone
        // These are semantically permanent and so get long implicit lifetime.
        return 24_h * 365;
    default:
        // Heuristic Freshness:
        // http://tools.ietf.org/html/rfc7234#section-4.2.2
        if (auto lastModified = response.lastModified())
            return (effectiveDate - *lastModified) * 0.1;
        return 0_us;
    }
}

void updateRedirectChainStatus(RedirectChainCacheStatus& redirectChainCacheStatus, const ResourceResponse& response, const ResourceLoaderOptions& options)
{
    if (redirectChainCacheStatus.status == RedirectChainCacheStatus::Status::NotCachedRedirection)
        return;
    if (options.cachingPolicy != CachingPolicy::AllowCachingMainResourcePrefetch && (response.cacheControlContainsNoStore() || response.cacheControlContainsNoCache() || response.cacheControlContainsMustRevalidate())) {
        redirectChainCacheStatus.status = RedirectChainCacheStatus::Status::NotCachedRedirection;
        return;
    }

    redirectChainCacheStatus.status = RedirectChainCacheStatus::Status::CachedRedirection;
    auto responseTimestamp = WallTime::now();
    // Store the nearest end of cache validity date
    auto endOfValidity = responseTimestamp + computeFreshnessLifetimeForHTTPFamily(response, responseTimestamp) - computeCurrentAge(response, responseTimestamp);
    redirectChainCacheStatus.endOfValidity = std::min(redirectChainCacheStatus.endOfValidity, endOfValidity);
}

bool redirectChainAllowsReuse(RedirectChainCacheStatus redirectChainCacheStatus, ReuseExpiredRedirectionOrNot reuseExpiredRedirection)
{
    switch (redirectChainCacheStatus.status) {
    case RedirectChainCacheStatus::Status::NoRedirection:
        return true;
    case RedirectChainCacheStatus::Status::NotCachedRedirection:
        return false;
    case RedirectChainCacheStatus::Status::CachedRedirection:
        return reuseExpiredRedirection || WallTime::now() <= redirectChainCacheStatus.endOfValidity;
    }
    ASSERT_NOT_REACHED();
    return false;
}

NODELETE inline bool isControlCharacterOrSpace(char16_t character)
{
    return character <= ' ' || character == 127;
}

CacheControlDirectives parseCacheControlDirectives(const HTTPHeaderMap& headers)
{
    CacheControlDirectives result;

    String cacheControlValue = headers.get(HTTPHeaderName::CacheControl);
    if (!cacheControlValue.isEmpty()) {
        auto safeHeaderString = cacheControlValue.removeCharacters([](auto character) {
            return isControlCharacterOrSpace(character);
        });
        result = safeHeaderString.is8Bit() ? parseCacheControlHeader8(safeHeaderString.span8()) : parseCacheControlHeader16(safeHeaderString.span16());
    }

    if (!result.noCache) {
        // Handle Pragma: no-cache
        // This is deprecated and equivalent to Cache-control: no-cache
        // Don't bother tokenizing the value; handling that exactly right is not important.
        result.noCache = headers.get(HTTPHeaderName::Pragma).containsIgnoringASCIICase("no-cache"_s);
    }

    return result;
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
    for (auto& varyingRequestHeader : varyingRequestHeaders) {
        // FIXME: Vary: * in response would ideally trigger a cache delete instead of a store.
        if (varyingRequestHeader.first == "*"_s)
            return false;
        if (headerValueForVary(varyingRequestHeader.first) != varyingRequestHeader.second)
            return false;
    }
    return true;
}

bool verifyVaryingRequestHeaders(const CookieJar* cookieJar, const Vector<std::pair<String, String>>& varyingRequestHeaders, const ResourceRequest& request)
{
    return verifyVaryingRequestHeaders(varyingRequestHeaders, [&] (const String& headerName) {
        return headerValueForVary(request, headerName, [&] {
            return cookieRequestHeaderFieldValueForVary(cookieJar, request);
        });
    });
}

// http://tools.ietf.org/html/rfc7231#page-48
bool isStatusCodeCacheableByDefault(int statusCode)
{
    switch (statusCode) {
    case 200: // OK
    case 203: // Non-Authoritative Information
    case 204: // No Content
    case 206: // Partial Content
    case 300: // Multiple Choices
    case 301: // Moved Permanently
    case 404: // Not Found
    case 405: // Method Not Allowed
    case 410: // Gone
    case 414: // URI Too Long
    case 501: // Not Implemented
        return true;
    default:
        return false;
    }
}

}
