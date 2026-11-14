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

// Inputs and passes of the security policy benchmark. Each test has a generator, which builds the same inputs on every
// run from a fixed seed, and a pass, which runs every input of the test once through the policies and folds their
// outputs into a sink: a Digest for the checksum, or a Tally for the timed passes.

#include <WebCore/CacheValidation.h>
#include <WebCore/CachedRawResource.h>
#include <WebCore/CachedResourceRequest.h>
#include <WebCore/ClientOrigin.h>
#include <WebCore/CrossOriginAccessControl.h>
#include <WebCore/CrossOriginEmbedderPolicy.h>
#include <WebCore/CrossOriginOpenerPolicy.h>
#include <WebCore/CrossOriginPreflightResultCache.h>
#include <WebCore/DocumentIsolationPolicy.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/FetchHeaders.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLIFrameElement.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/HTTPHeaderNames.h>
#include <WebCore/IntegrityPolicy.h>
#include <WebCore/NetworkLoadMetrics.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/OriginAccessPatterns.h>
#include <WebCore/OriginAgentClusterPolicy.h>
#include <WebCore/ParsedContentRange.h>
#include <WebCore/PermissionsPolicy.h>
#include <WebCore/PolicyContainer.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceLoaderOptions.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityContext.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/SecurityPolicy.h>
#include <WebCore/Settings.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/SubresourceIntegrity.h>
#include <WebCore/TimingAllowOrigin.h>
#include <array>
#include <bit>
#include <cmath>
#include <pal/SessionID.h>
#include <pal/crypto/CryptoDigest.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/Base64.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI::SecurityPoliciesBench {

using WebCore::HTTPHeaderName;
using WebCore::ResourceResponse;
using WebCore::StoredCredentialsPolicy;
using Tainting = WebCore::ResourceResponse::Tainting;

// FNV-1a over every output, in a fixed order.
class Digest {
public:
    void addInteger(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte(static_cast<uint8_t>(value >> (8 * i)));
    }
    void addBoolean(bool value) { addByte(value ? 1 : 2); }
    void addDouble(double value) { addInteger(std::bit_cast<uint64_t>(value)); }
    void addString(StringView string)
    {
        if (string.isNull()) {
            addByte(0xFF);
            return;
        }
        addInteger(string.length());
        for (char16_t character : string.codeUnits()) {
            addByte(static_cast<uint8_t>(character));
            addByte(static_cast<uint8_t>(character >> 8));
        }
    }
    uint64_t value() const { return m_hash; }

private:
    void addByte(uint8_t byte) { m_hash = (m_hash ^ byte) * 0x100000001B3ULL; }

    uint64_t m_hash { 0xCBF29CE484222325ULL };
};

// The timed passes read each output's scalars and lengths only, so that their time is the policies'.
class Tally {
public:
    void addInteger(uint64_t value) { m_value += value; }
    void addBoolean(bool value) { m_value += value; }
    void addDouble(double value) { m_value += std::bit_cast<uint64_t>(value); }
    void addString(StringView string) { m_value += string.length() + string.isNull(); }
    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0 };
};

// splitmix64. Each draw is its own statement, so that the inputs do not depend on the order in which a compiler
// evaluates arguments.
class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    uint64_t next()
    {
        m_state += 0x9E3779B97F4A7C15ULL;
        uint64_t z = m_state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        return z ^ (z >> 31);
    }
    unsigned below(unsigned bound) { return static_cast<unsigned>(next() % bound); }
    bool chance(unsigned percent) { return below(100) < percent; }
    template<typename T, size_t size> const T& pick(const std::array<T, size>& choices) { return choices[below(size)]; }
    String token(unsigned length)
    {
        static constexpr auto alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"_s;
        WTF::StringBuilder builder;
        for (unsigned i = 0; i < length; ++i)
            builder.append(alphabet[below(alphabet.length())]);
        return builder.toString();
    }

private:
    uint64_t m_state;
};

inline String copyAs16Bit(const String& string)
{
    if (string.isEmpty())
        return string;
    Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    for (char16_t character : StringView(string).codeUnits())
        characters.append(character);
    return String(characters.span());
}

template<size_t size> String wideString(const char16_t (&characters)[size])
{
    return String(std::span<const char16_t> { characters }.first(size - 1));
}

inline uint64_t byteSize(const String& string)
{
    return string.isNull() ? 0 : string.length() * (string.is8Bit() ? 1 : 2);
}

inline uint64_t byteSize(const WebCore::HTTPHeaderMap& map)
{
    uint64_t bytes = 0;
    for (auto& header : map)
        bytes += byteSize(header.key) + byteSize(header.value);
    return bytes;
}

// A hash table's iteration order is not part of a policy's output: each entry is folded on its own, and the sum taken.
template<typename Sink, typename Collection, typename Function> void addUnordered(Sink& sink, const Collection& collection, const Function& addEntry)
{
    uint64_t sum = 0;
    for (auto& entry : collection) {
        Sink entrySink;
        addEntry(entrySink, entry);
        sum += entrySink.value();
    }
    sink.addInteger(collection.size());
    sink.addInteger(sum);
}

template<typename Sink> void addHeaderMap(Sink& sink, const WebCore::HTTPHeaderMap& map)
{
    sink.addInteger(map.size());
    for (auto& header : map) {
        sink.addString(header.key);
        sink.addInteger(header.keyAsHTTPHeaderName ? static_cast<uint64_t>(*header.keyAsHTTPHeaderName) + 1 : 0);
        sink.addString(header.value);
    }
}

template<typename Sink> void addResponse(Sink& sink, const ResourceResponse& response)
{
    sink.addBoolean(response.isNull());
    sink.addInteger(static_cast<uint64_t>(response.type()));
    sink.addInteger(static_cast<uint64_t>(response.tainting()));
    sink.addInteger(static_cast<uint64_t>(static_cast<int64_t>(response.httpStatusCode())));
    sink.addString(response.url().string());
    addHeaderMap(sink, response.httpHeaderFields());
}

template<typename Sink> void addRequest(Sink& sink, const WebCore::ResourceRequest& request)
{
    sink.addString(request.url().string());
    sink.addString(request.httpMethod());
    sink.addBoolean(request.allowCookies());
    sink.addDouble(request.timeoutInterval());
    addHeaderMap(sink, request.httpHeaderFields());
}

template<typename Sink> void addExpected(Sink& sink, const std::expected<void, String>& result)
{
    sink.addBoolean(result.has_value());
    if (!result)
        sink.addString(result.error());
}

template<typename Sink> void addSeconds(Sink& sink, std::optional<Seconds> seconds)
{
    sink.addBoolean(!!seconds);
    if (seconds)
        sink.addDouble(seconds->value());
}

template<typename Sink> void addWallTime(Sink& sink, std::optional<WallTime> time)
{
    sink.addBoolean(!!time);
    if (time)
        sink.addDouble(time->secondsSinceEpoch().value());
}

// Rounds to the nearest second a value that differs from a whole number of seconds only by the time between two
// reads of the clock.
template<typename Sink> void addWholeSeconds(Sink& sink, double seconds)
{
    if (!std::isfinite(seconds)) {
        sink.addDouble(seconds);
        return;
    }
    sink.addInteger(static_cast<uint64_t>(std::llround(seconds)));
}

template<typename Sink, typename T> void addException(Sink& sink, const WebCore::ExceptionOr<T>& result)
{
    sink.addBoolean(result.hasException());
    if (result.hasException()) {
        sink.addInteger(static_cast<uint64_t>(result.exception().code()));
        sink.addString(result.exception().message());
    }
}

inline WebCore::HTTPHeaderMap makeHeaderMap(Vector<std::pair<String, String>>&& headers)
{
    WebCore::HTTPHeaderMap::CommonHeadersVector common;
    WebCore::HTTPHeaderMap::UncommonHeadersVector uncommon;
    // set() on a map of its own classifies each header as common or uncommon; set() on one map would replace a repeated name.
    for (auto& [name, value] : headers) {
        WebCore::HTTPHeaderMap header;
        header.set(name, value);
        common.appendVector(header.commonHeaders());
        uncommon.appendVector(header.uncommonHeaders());
    }
    return WebCore::HTTPHeaderMap { WTF::move(common), WTF::move(uncommon) };
}

// A response whose header map holds a name more than once, as a decoded one can.
inline ResourceResponse makeResponse(const String& url, int statusCode, WebCore::HTTPHeaderMap&& headers, Tainting tainting = Tainting::Basic)
{
    WebCore::ResourceResponseData data { };
    data.url = WTF::URL { url };
    data.mimeType = "text/plain"_s;
    data.httpStatusCode = statusCode;
    data.httpHeaderFields = WTF::move(headers);
    data.source = WebCore::ResourceResponse::Source::Network;
    data.type = WebCore::ResourceResponse::Type::Default;
    data.tainting = tainting;
    return ResourceResponse { WebCore::ResourceResponseBase { std::optional<WebCore::ResourceResponseData> { WTF::move(data) } } };
}

inline String maybe16Bit(Random& random, unsigned percent, const String& string)
{
    return random.chance(percent) ? copyAs16Bit(string) : string;
}

// CORSChecks: the access control check, preflight responses and preflight requests of typical cross-origin loads.

struct AccessCheck {
    ResourceResponse response;
    unsigned origin;
    StoredCredentialsPolicy policy;
    unsigned disabler;
};

struct PreflightValidation {
    WebCore::ResourceRequest request;
    ResourceResponse response;
    unsigned topOrigin;
    unsigned origin;
    StoredCredentialsPolicy policy;
    unsigned disabler;
};

struct PreflightRequest {
    WebCore::ResourceRequest request;
    unsigned origin;
    String referrer;
    bool includeFetchMetadata;
};

struct CORSInputs {
    Vector<Ref<WebCore::SecurityOrigin>> origins;
    Vector<AccessCheck> checks;
    Vector<PreflightValidation> validations;
    Vector<PreflightRequest> requests;
    uint64_t bytes { 0 };
};

inline Vector<Ref<WebCore::SecurityOrigin>> makeOrigins()
{
    static constexpr std::array urls {
        "https://app.example.com/"_s, "https://www.example.com/"_s, "http://app.example.com/"_s, "https://app.example.com:8443/"_s,
        "https://cdn.example.org/"_s, "http://localhost:8000/"_s, "https://api.example.com/"_s,
    };
    Vector<Ref<WebCore::SecurityOrigin>> origins;
    for (auto url : urls)
        origins.append(WebCore::SecurityOrigin::create(WTF::URL { String { url } }));
    origins.append(WebCore::SecurityOrigin::createOpaque());
    return origins;
}

inline StoredCredentialsPolicy pickPolicy(Random& random)
{
    static constexpr std::array policies { StoredCredentialsPolicy::DoNotUse, StoredCredentialsPolicy::DoNotUse, StoredCredentialsPolicy::Use, StoredCredentialsPolicy::Use, StoredCredentialsPolicy::EphemeralStateless };
    return random.pick(policies);
}

inline String allowOriginValue(Random& random, const String& origin)
{
    switch (random.below(12)) {
    case 0:
        return { };
    case 1:
    case 2:
        return "*"_s;
    case 3:
        return WTF::makeString(origin, '/');
    case 4:
        return WTF::makeString(origin, ' ');
    case 5:
        return WTF::makeString(origin, ", https://other.example"_s);
    case 6:
        return "null"_s;
    case 7:
        return origin.convertToASCIIUppercase();
    case 8:
        return copyAs16Bit(origin);
    case 9:
        return WTF::makeString(origin, wideString(u"\u0130"));
    default:
        return origin;
    }
}

inline WebCore::HTTPHeaderMap requestHeaders(Random& random, unsigned maximumCount)
{
    static constexpr std::array safe {
        std::pair { "Accept"_s, "*/*"_s }, std::pair { "Content-Type"_s, "text/plain"_s }, std::pair { "Accept-Language"_s, "en-US,en;q=0.9"_s },
        std::pair { "Range"_s, "bytes=0-1023"_s }, std::pair { "Content-Language"_s, "en"_s },
    };
    static constexpr std::array unsafe {
        std::pair { "Content-Type"_s, "application/json"_s }, std::pair { "Cache-Control"_s, "no-cache"_s }, std::pair { "Origin"_s, "https://app.example.com"_s },
        std::pair { "Authorization"_s, "Bearer eyJhbGciOiJIUzI1NiJ9"_s }, std::pair { "X-Requested-With"_s, "XMLHttpRequest"_s },
        std::pair { "x-csrf-token"_s, "a8f5f167f44f4964e6c998dee827110c"_s }, std::pair { "X-Mixed-Case"_s, "1"_s }, std::pair { "Range"_s, "bytes=0-1,5-10"_s },
        std::pair { "Accept"_s, "text/html\""_s }, std::pair { "X-A"_s, "a"_s }, std::pair { "x-b"_s, "b"_s },
    };
    Vector<std::pair<String, String>> headers;
    unsigned count = random.below(maximumCount + 1);
    for (unsigned i = 0; i < count; ++i) {
        unsigned kind = random.below(10);
        if (kind < 4) {
            auto& [name, value] = random.pick(safe);
            headers.append({ name, value });
        } else if (kind < 8) {
            auto& [name, value] = random.pick(unsafe);
            headers.append({ name, value });
        } else if (kind < 9) {
            auto suffix = random.token(4);
            headers.append({ WTF::makeString("X-Custom-"_s, suffix), "v"_s });
        } else {
            switch (random.below(9)) {
            case 0:
                headers.append({ emptyString(), "empty name"_s });
                break;
            case 1:
                headers.append({ String::fromLatin1("x-caf\xE9"), "1"_s });
                break;
            case 2:
                headers.append({ wideString(u"X-\u0130"), "1"_s });
                break;
            case 3:
                headers.append({ String::fromLatin1("x-\x7F"), "1"_s });
                break;
            case 4:
                headers.append({ String::fromLatin1("x-\x80"), "1"_s });
                break;
            case 5:
                headers.append({ String::fromLatin1("x-\xFF"), "1"_s });
                break;
            case 6:
                headers.append({ wideString(u"x-\u0100"), "1"_s });
                break;
            case 7:
                headers.append({ wideString(u"x-\xD800"), "1"_s });
                break;
            default:
                headers.append({ wideString(u"x-\xE000"), "1"_s });
                break;
            }
        }
    }
    if (random.chance(10))
        headers.append({ "x-a"_s, "duplicate"_s });
    if (random.chance(15)) {
        for (auto& [name, value] : headers) {
            name = copyAs16Bit(name);
            value = copyAs16Bit(value);
        }
    }
    return makeHeaderMap(WTF::move(headers));
}

inline String allowMethodsValue(Random& random)
{
    static constexpr std::array values {
        ""_s, "GET, POST, PUT"_s, "PUT, DELETE, *"_s, "*"_s, " POST ,, PATCH,"_s, "PUT DELETE"_s, "GET, (bad)"_s, "put"_s,
        "GET, POST, PUT, DELETE, OPTIONS"_s, "PATCH"_s,
    };
    auto& value = random.pick(values);
    return value.isEmpty() ? String { } : maybe16Bit(random, 15, value);
}

inline String allowHeadersValue(Random& random)
{
    static constexpr std::array values {
        ""_s, "X-A, x-b, *, Content-Type"_s, "x-custom-header, content-type"_s, "*"_s, "Content-Type, Authorization, X-Requested-With, x-csrf-token"_s,
        "bad header"_s, "X-A,"_s, "x-a, X-B, x-mixed-case"_s, "authorization"_s, "X-A, x-b"_s,
    };
    auto& value = random.pick(values);
    return value.isEmpty() ? String { } : maybe16Bit(random, 15, value);
}

inline String maxAgeValue(Random& random)
{
    static constexpr std::array values {
        ""_s, "0"_s, "5"_s, "599"_s, "600"_s, "601"_s, "-1"_s, "+10"_s, " 10 "_s, "9223372036854775808"_s, "junk"_s, "86400"_s,
    };
    auto& value = random.pick(values);
    return value.isEmpty() ? String { } : String { value };
}

inline ResourceResponse corsResponse(const String& url, int statusCode, const String& allowOrigin, const String& allowCredentials, const String& allowMethods = { }, const String& allowHeaders = { }, const String& maxAge = { })
{
    Vector<std::pair<String, String>> headers;
    headers.append({ "Content-Type"_s, "application/json"_s });
    if (!allowOrigin.isNull())
        headers.append({ "Access-Control-Allow-Origin"_s, allowOrigin });
    if (!allowCredentials.isNull())
        headers.append({ "Access-Control-Allow-Credentials"_s, allowCredentials });
    if (!allowMethods.isNull())
        headers.append({ "Access-Control-Allow-Methods"_s, allowMethods });
    if (!allowHeaders.isNull())
        headers.append({ "Access-Control-Allow-Headers"_s, allowHeaders });
    if (!maxAge.isNull())
        headers.append({ "Access-Control-Max-Age"_s, maxAge });
    headers.append({ "Vary"_s, "Origin"_s });
    return makeResponse(url, statusCode, makeHeaderMap(WTF::move(headers)), Tainting::Cors);
}

inline String allowCredentialsValue(Random& random)
{
    static constexpr std::array values { ""_s, "true"_s, "true"_s, "TRUE"_s, " true"_s, "false"_s };
    auto& value = random.pick(values);
    return value.isEmpty() ? String { } : String { value };
}

inline WebCore::ResourceRequest makeRequest(const String& url, const String& method, WebCore::HTTPHeaderMap&& headers)
{
    WebCore::ResourceRequest request { WTF::URL { url } };
    request.setHTTPMethod(method);
    request.setHTTPHeaderFields(WTF::move(headers));
    return request;
}

inline CORSInputs makeCORSInputs()
{
    static constexpr std::array statusCodes { 200, 200, 200, 204, 301, 404, 0, 500, -7 };
    static constexpr std::array methods { "GET"_s, "GET"_s, "POST"_s, "PUT"_s, "DELETE"_s, "PATCH"_s, "put"_s, "HEAD"_s };
    static constexpr std::array targets {
        "https://api.example.com/v1/items"_s, "http://api.example.com/v1/items"_s, "https://app.example.com/data.json"_s,
        "https://cdn.example.org/fonts/a.woff2"_s, "https://api.example.com:8443/upload?x=1"_s,
    };

    CORSInputs inputs;
    inputs.origins = makeOrigins();
    Random random { 0x434F525343484B53ULL };
    for (unsigned i = 0; i < 1500; ++i) {
        unsigned origin = random.below(inputs.origins.size());
        auto originString = inputs.origins[origin]->toString();
        auto allowOrigin = allowOriginValue(random, originString);
        auto allowCredentials = allowCredentialsValue(random);
        int statusCode = random.pick(statusCodes);
        auto policy = pickPolicy(random);
        unsigned disabler = random.below(3);
        auto& target = random.pick(targets);
        inputs.bytes += byteSize(allowOrigin) + byteSize(allowCredentials);
        inputs.checks.append({ corsResponse(target, statusCode, allowOrigin, allowCredentials), origin, policy, disabler });
    }
    for (unsigned i = 0; i < 400; ++i) {
        unsigned topOrigin = random.below(inputs.origins.size());
        unsigned origin = random.below(inputs.origins.size());
        auto originString = inputs.origins[origin]->toString();
        String allowOrigin = random.chance(80) ? originString : allowOriginValue(random, originString);
        auto allowCredentials = allowCredentialsValue(random);
        int statusCode = random.chance(85) ? 204 : random.pick(statusCodes);
        auto allowMethods = allowMethodsValue(random);
        auto allowHeaders = allowHeadersValue(random);
        auto maxAge = maxAgeValue(random);
        auto& target = random.pick(targets);
        auto& method = random.pick(methods);
        auto headers = requestHeaders(random, 6);
        auto policy = pickPolicy(random);
        unsigned disabler = random.below(3);
        inputs.bytes += byteSize(allowOrigin) + byteSize(allowCredentials) + byteSize(allowMethods) + byteSize(allowHeaders) + byteSize(maxAge) + byteSize(headers);
        inputs.validations.append({ makeRequest(target, method, WTF::move(headers)), corsResponse(target, statusCode, allowOrigin, allowCredentials, allowMethods, allowHeaders, maxAge), topOrigin, origin, policy, disabler });
    }
    for (unsigned i = 0; i < 600; ++i) {
        auto& target = random.pick(targets);
        auto& method = random.pick(methods);
        auto headers = requestHeaders(random, 12);
        unsigned origin = random.below(inputs.origins.size());
        String referrer = random.chance(50) ? String { "https://app.example.com/page?id=7"_s } : String { };
        bool includeFetchMetadata = random.chance(60);
        inputs.bytes += byteSize(headers) + byteSize(referrer);
        inputs.requests.append({ makeRequest(target, method, WTF::move(headers)), origin, WTF::move(referrer), includeFetchMetadata });
    }
    return inputs;
}

// The check disablers a caller can pass: none, one whose check is on, and one whose check is off.
struct CheckDisablers {
    CheckDisablers()
    {
        disabled.setCrossOriginAccessControlCheckEnabled(false);
    }

    const WebCore::CrossOriginAccessControlCheckDisabler* select(unsigned index) const
    {
        if (!index)
            return nullptr;
        return index == 1 ? &enabled : &disabled;
    }

    WebCore::CrossOriginAccessControlCheckDisabler enabled;
    WebCore::CrossOriginAccessControlCheckDisabler disabled;
};

template<typename Sink> void runCORSChecksPass(const CORSInputs& inputs, const CheckDisablers& disablers, Sink& sink)
{
    auto& cache = WebCore::CrossOriginPreflightResultCache::singleton();
    cache.clear();
    for (auto& check : inputs.checks)
        addExpected(sink, WebCore::passesAccessControlCheck(check.response, check.policy, inputs.origins[check.origin], disablers.select(check.disabler)));
    for (auto& validation : inputs.validations) {
        addExpected(sink, WebCore::validatePreflightResponse(PAL::SessionID::defaultSessionID(), validation.request, validation.response, validation.policy,
            inputs.origins[validation.topOrigin], inputs.origins[validation.origin], disablers.select(validation.disabler)));
    }
    for (auto& request : inputs.requests) {
        auto& headers = request.request.httpHeaderFields();
        sink.addBoolean(WebCore::isSimpleCrossOriginAccessRequest(request.request.httpMethod(), headers));
        sink.addInteger(WebCore::httpHeadersToKeepFromCleaning(headers).toRaw());
        addRequest(sink, WebCore::createAccessControlPreflightRequest(request.request, inputs.origins[request.origin].get(), request.referrer, request.includeFetchMetadata));
    }
    cache.clear();
}

// PreflightCache: entries made from preflight responses, then requests checked against them. A check that fails
// removes its entry, so the checks after it see none.

struct CacheCheck {
    unsigned urlOffset;
    StoredCredentialsPolicy policy;
    String method;
    WebCore::HTTPHeaderMap headers;
};

struct CacheEntry {
    String url;
    bool secondSession;
    unsigned topOrigin;
    unsigned origin;
    PreflightValidation validation;
    Vector<CacheCheck> checks;
};

struct PreflightCacheInputs {
    Vector<Ref<WebCore::SecurityOrigin>> origins;
    Vector<CacheEntry> entries;
    uint64_t bytes { 0 };
};

inline WebCore::HTTPHeaderMap cacheCheckHeaders(Random& random)
{
    static constexpr std::array headers {
        std::pair { "X-A"_s, "1"_s }, std::pair { "x-b"_s, "2"_s }, std::pair { "X-C"_s, "3"_s }, std::pair { "Content-Type"_s, "application/json"_s },
        std::pair { "Content-Type"_s, "text/plain"_s }, std::pair { "Accept"_s, "*/*"_s }, std::pair { "x-a"_s, "4"_s }, std::pair { "Authorization"_s, "Basic YTpi"_s },
    };
    Vector<std::pair<String, String>> list;
    unsigned count = random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        auto& [name, value] = random.pick(headers);
        list.append({ name, value });
    }
    if (random.chance(10)) {
        for (auto& [name, value] : list)
            name = copyAs16Bit(name);
    }
    return makeHeaderMap(WTF::move(list));
}

inline PreflightCacheInputs makePreflightCacheInputs()
{
    static constexpr std::array entryMethods { "PUT, DELETE, *"_s, "PUT, DELETE"_s, "*"_s, "PATCH"_s, ""_s, "GET, (bad)"_s };
    static constexpr std::array entryHeaders { "X-A, x-b, *, Content-Type"_s, "X-A, x-b"_s, "*"_s, "content-type"_s, ""_s, "bad header"_s };
    static constexpr std::array maxAges { ""_s, "0"_s, "5"_s, "599"_s, "600"_s, "601"_s, "-1"_s, "+10"_s, " 10 "_s, "9223372036854775808"_s, "junk"_s };
    static constexpr std::array checkMethods { "GET"_s, "POST"_s, "PUT"_s, "DELETE"_s, "PATCH"_s, "put"_s, "OPTIONS"_s, "HEAD"_s };
    static constexpr std::array statusCodes { 200, 204, 204, 204, 404 };

    PreflightCacheInputs inputs;
    inputs.origins = makeOrigins();
    Random random { 0x505245464C495445ULL };
    for (unsigned i = 0; i < 300; ++i) {
        auto url = WTF::makeString("https://api.example.com/resource/"_s, i);
        unsigned topOrigin = random.below(inputs.origins.size());
        unsigned origin = random.below(inputs.origins.size());
        auto policy = pickPolicy(random);
        String allowOrigin = random.chance(85) ? inputs.origins[origin]->toString() : String { "*"_s };
        String allowCredentials = random.chance(80) ? String { "true"_s } : String { };
        auto& methods = random.pick(entryMethods);
        auto& headers = random.pick(entryHeaders);
        auto& maxAge = random.pick(maxAges);
        int statusCode = random.pick(statusCodes);
        auto& firstMethod = random.pick(checkMethods);
        auto firstHeaders = cacheCheckHeaders(random);
        String methodsValue = methods.isEmpty() ? String { } : maybe16Bit(random, 10, methods);
        String headersValue = headers.isEmpty() ? String { } : maybe16Bit(random, 10, headers);
        String maxAgeValue = maxAge.isEmpty() ? String { } : String { maxAge };
        inputs.bytes += byteSize(methodsValue) + byteSize(headersValue) + byteSize(maxAgeValue) + byteSize(firstHeaders);
        CacheEntry entry {
            url, random.chance(20), topOrigin, origin,
            { makeRequest(url, firstMethod, WTF::move(firstHeaders)), corsResponse(url, statusCode, allowOrigin, allowCredentials, methodsValue, headersValue, maxAgeValue), topOrigin, origin, policy, 0 },
            { },
        };
        // Whether an entry with a max age of 0 has expired depends on the clock, so no request is checked against it.
        if (maxAge != "0"_s) {
            unsigned checkCount = 2 + random.below(5);
            for (unsigned j = 0; j < checkCount; ++j) {
                unsigned urlOffset = random.chance(5) ? 1 : 0;
                auto checkPolicy = random.chance(70) ? policy : pickPolicy(random);
                auto& method = random.pick(checkMethods);
                auto checkHeaders = cacheCheckHeaders(random);
                inputs.bytes += byteSize(checkHeaders);
                entry.checks.append({ urlOffset, checkPolicy, method, WTF::move(checkHeaders) });
            }
        }
        inputs.entries.append(WTF::move(entry));
    }
    return inputs;
}

template<typename Sink> void runPreflightCachePass(const PreflightCacheInputs& inputs, Sink& sink)
{
    auto& cache = WebCore::CrossOriginPreflightResultCache::singleton();
    cache.clear();
    PAL::SessionID sessions[] = { PAL::SessionID::defaultSessionID(), PAL::SessionID { 2 } };
    for (auto& entry : inputs.entries) {
        auto& topOrigin = inputs.origins[entry.topOrigin].get();
        auto& origin = inputs.origins[entry.origin].get();
        auto session = sessions[entry.secondSession];
        auto& validation = entry.validation;
        addExpected(sink, WebCore::validatePreflightResponse(session, validation.request, validation.response, validation.policy, topOrigin, origin, nullptr));
        WebCore::ClientOrigin clientOrigin { topOrigin.data(), origin.data() };
        WTF::URL url { entry.url };
        WTF::URL otherURL { WTF::makeString(entry.url, "/other"_s) };
        for (auto& check : entry.checks)
            sink.addBoolean(cache.canSkipPreflight(session, clientOrigin, check.urlOffset ? otherURL : url, check.policy, check.method, check.headers));
    }
    cache.clear();
}

// ResponseFiltering: the filtered responses of basic, CORS, opaque and opaque redirect loads, and the sanitized headers
// of each.

struct FilterCase {
    ResourceResponse response;
    bool primeParsedHeaders;
};

struct ResponseFilteringInputs {
    Vector<FilterCase> cases;
    uint64_t bytes { 0 };
};

inline ResponseFilteringInputs makeResponseFilteringInputs()
{
    static constexpr std::array commonHeaders {
        std::pair { "Content-Type"_s, "text/html; charset=utf-8"_s }, std::pair { "Content-Length"_s, "18734"_s }, std::pair { "Cache-Control"_s, "max-age=600"_s },
        std::pair { "Expires"_s, "Thu, 01 Dec 2026 16:00:00 GMT"_s }, std::pair { "Last-Modified"_s, "Wed, 21 Oct 2026 07:28:00 GMT"_s }, std::pair { "Pragma"_s, "no-cache"_s },
        std::pair { "Content-Language"_s, "en"_s }, std::pair { "Accept"_s, "*/*"_s }, std::pair { "ETag"_s, "\"5f2b-1a2b3c\""_s }, std::pair { "Server"_s, "nginx"_s },
        std::pair { "Vary"_s, "Accept-Encoding"_s }, std::pair { "Date"_s, "Sun, 08 Nov 2026 23:12:40 GMT"_s }, std::pair { "Access-Control-Allow-Origin"_s, "*"_s },
        std::pair { "Location"_s, "https://www.example.com/next"_s }, std::pair { "X-Frame-Options"_s, "DENY"_s }, std::pair { "Content-Security-Policy"_s, "default-src 'self'"_s },
        std::pair { "Timing-Allow-Origin"_s, "*"_s }, std::pair { "Range"_s, "bytes=0-1"_s }, std::pair { "Icy-MetaInt"_s, "16000"_s }, std::pair { "Refresh"_s, "5"_s },
        std::pair { "Content-Disposition"_s, "attachment; filename=a.pdf"_s }, std::pair { "Content-Range"_s, "bytes 0-1023/4096"_s }, std::pair { "Age"_s, "120"_s },
        std::pair { "Link"_s, "</a.css>; rel=preload"_s }, std::pair { "Server-Timing"_s, "db;dur=53"_s }, std::pair { "Access-Control-Request-Method"_s, "PUT"_s },
        std::pair { "Content-Encoding"_s, "gzip"_s }, std::pair { "Strict-Transport-Security"_s, "max-age=63072000"_s },
    };
    static constexpr std::array uncommonHeaders { "X-Request-Id"_s, "X-Trace-Id"_s, "x-a"_s, "X-B"_s, "*"_s, "X-Powered-By"_s };
    static constexpr std::array exposeValues {
        ""_s, "*"_s, "*, x-a"_s, "X-A, x-b"_s, "x a"_s, ",,"_s, "x-a,"_s, "X-Request-Id, Server-Timing"_s, "ETag, Content-Encoding, x-trace-id"_s,
        "Set-Cookie, Server"_s, "*,*"_s,
    };
    static constexpr std::array taintings { Tainting::Basic, Tainting::Cors, Tainting::Cors, Tainting::Cors, Tainting::Opaque, Tainting::Opaqueredirect };
    static constexpr std::array urls { "https://api.example.com/v1/items"_s, "https://cdn.example.org/app.js"_s, "http://www.example.com/redirect"_s };
    static constexpr std::array statusCodes { 200, 200, 204, 301, 302, 404 };

    ResponseFilteringInputs inputs;
    Random random { 0x46494C5445524544ULL };
    for (unsigned i = 0; i < 800; ++i) {
        bool wide = random.chance(15);
        Vector<std::pair<String, String>> headers;
        unsigned commonCount = 3 + random.below(10);
        for (unsigned j = 0; j < commonCount; ++j) {
            auto& [name, value] = random.pick(commonHeaders);
            headers.append({ name, value });
        }
        unsigned uncommonCount = random.below(4);
        for (unsigned j = 0; j < uncommonCount; ++j) {
            auto& name = random.pick(uncommonHeaders);
            auto value = random.token(6);
            headers.append({ name, WTF::move(value) });
        }
        unsigned cookies = random.below(3);
        for (unsigned j = 0; j < cookies; ++j) {
            auto session = random.token(12);
            headers.append({ "Set-Cookie"_s, WTF::makeString("session="_s, session, "; Path=/; Secure"_s) });
        }
        if (random.chance(15))
            headers.append({ "Set-Cookie2"_s, "a=b"_s });
        auto& expose = random.pick(exposeValues);
        if (!expose.isEmpty())
            headers.append({ "Access-Control-Expose-Headers"_s, expose });
        if (wide) {
            for (auto& [name, value] : headers)
                value = copyAs16Bit(value);
            headers.append({ "Access-Control-Expose-Headers"_s, wideString(u"X-A, x-\u0130") });
            headers.append({ wideString(u"X-\u0130"), "v"_s });
        }
        auto tainting = random.pick(taintings);
        auto& url = random.pick(urls);
        int statusCode = random.pick(statusCodes);
        bool prime = random.chance(30);
        auto map = makeHeaderMap(WTF::move(headers));
        inputs.bytes += byteSize(map);
        inputs.cases.append({ makeResponse(url, statusCode, WTF::move(map), tainting), prime });
    }
    return inputs;
}

template<typename Sink> void runResponseFilteringPass(const ResponseFilteringInputs& inputs, Sink& sink)
{
    using WebCore::ResourceResponseBase;
    for (auto& filterCase : inputs.cases) {
        auto source = filterCase.response;
        if (filterCase.primeParsedHeaders) {
            addSeconds(sink, source.cacheControlMaxAge());
            addWallTime(sink, source.date());
        }
        for (auto check : { ResourceResponseBase::PerformExposeAllHeadersCheck::Yes, ResourceResponseBase::PerformExposeAllHeadersCheck::No }) {
            auto filtered = ResourceResponseBase::filter(source, check);
            addResponse(sink, filtered);
            addSeconds(sink, filtered.cacheControlMaxAge());
            addWallTime(sink, filtered.date());
        }
        for (auto type : { ResourceResponseBase::SanitizationType::Redirection, ResourceResponseBase::SanitizationType::RemoveCookies, ResourceResponseBase::SanitizationType::CrossOriginSafe }) {
            auto sanitized = filterCase.response;
            sanitized.sanitizeHTTPHeaderFields(type);
            addHeaderMap(sink, sanitized.httpHeaderFields());
        }
    }
}

// PolicyHeaders: Cross-Origin-Opener-Policy, Cross-Origin-Embedder-Policy, Document-Isolation-Policy and
// Origin-Agent-Cluster obtained from typical responses, and the headers a policy container writes back.

struct PolicyHeadersInputs {
    Vector<ResourceResponse> responses;
    uint64_t bytes { 0 };
};

inline String withReportTo(Random& random, ASCIILiteral value)
{
    static constexpr std::array endpoints { "coop"_s, "default"_s, "my-endpoint"_s, "a\\\"b"_s, ""_s, "x\\\\y"_s };
    if (!random.chance(30))
        return value;
    auto& endpoint = random.pick(endpoints);
    return WTF::makeString(value, "; report-to=\""_s, endpoint, '"');
}

inline PolicyHeadersInputs makePolicyHeadersInputs()
{
    static constexpr std::array urls {
        "https://www.example.com/"_s, "https://www.example.com/"_s, "https://app.example.com/page"_s, "http://www.example.com/"_s, "http://localhost:8080/"_s,
        "http://127.0.0.1/"_s, "file:///home/test/index.html"_s, "data:text/html,hello"_s, "about:blank"_s,
    };
    static constexpr std::array openerValues {
        "same-origin"_s, "same-origin"_s, "same-origin"_s, "same-origin-allow-popups"_s, "noopener-allow-popups"_s, "unsafe-none"_s, "Same-Origin"_s,
        "\"same-origin\""_s, "?1"_s, "same-origin;"_s, "same-origin ;report-to=\"e\""_s, " same-origin "_s, "\tsame-origin"_s,
        "same-origin; report-to=e"_s, "same-origin; x=:!!:"_s, "same-origin; x=:YQ:"_s, "same-origin-allow-popup"_s, "same-originx"_s, ""_s,
        "same-origin; report-to=\"a\"; report-to=\"b\""_s, "same-origin; report-to=?1"_s,
    };
    static constexpr std::array embedderValues {
        "require-corp"_s, "require-corp"_s, "require-corp"_s, "credentialless"_s, "unsafe-none"_s, "Require-Corp"_s, "require-corp; x=:!!:"_s, "?0"_s, ""_s,
        "credentialless; report-to=coep"_s, "require-corp; report-to=\"\""_s,
    };
    static constexpr std::array isolationValues {
        "isolate-and-require-corp"_s, "isolate-and-require-corp"_s, "isolate-and-credentialless"_s, "isolate-and-require-corp; report-to=\"\""_s,
        "isolate-and-require-corp; report-to=\"0123456789012345678901234567890123456789012345678901234567890123\""_s, "\"isolate-and-require-corp\""_s, ""_s,
    };
    static constexpr std::array agentClusterValues {
        "?1"_s, "?1"_s, "?1"_s, "?0"_s, ""_s, "true"_s, "\"?1\""_s, "1"_s, "?2"_s, "(?1)"_s, "?1;param1;param2=value2"_s, "?1;a=:!!:"_s, " ?1 "_s,
    };

    PolicyHeadersInputs inputs;
    Random random { 0x504F4C4943494553ULL };
    for (unsigned i = 0; i < 1200; ++i) {
        Vector<std::pair<String, String>> headers;
        headers.append({ "Content-Type"_s, "text/html"_s });
        auto add = [&](ASCIILiteral name, String&& value) {
            headers.append({ name, WTF::move(value) });
        };
        if (random.chance(55)) {
            auto& value = random.pick(openerValues);
            add("Cross-Origin-Opener-Policy"_s, withReportTo(random, value));
        }
        if (random.chance(20)) {
            auto& value = random.pick(openerValues);
            add("Cross-Origin-Opener-Policy-Report-Only"_s, withReportTo(random, value));
        }
        if (random.chance(40)) {
            auto& value = random.pick(embedderValues);
            add("Cross-Origin-Embedder-Policy"_s, withReportTo(random, value));
        }
        if (random.chance(20)) {
            auto& value = random.pick(embedderValues);
            add("Cross-Origin-Embedder-Policy-Report-Only"_s, withReportTo(random, value));
        }
        if (random.chance(20)) {
            auto& value = random.pick(isolationValues);
            add("Document-Isolation-Policy"_s, withReportTo(random, value));
        }
        if (random.chance(10)) {
            auto& value = random.pick(isolationValues);
            add("Document-Isolation-Policy-Report-Only"_s, withReportTo(random, value));
        }
        if (random.chance(30)) {
            auto& value = random.pick(agentClusterValues);
            add("Origin-Agent-Cluster"_s, value);
        }
        if (random.chance(12)) {
            for (auto& [name, value] : headers)
                value = copyAs16Bit(value);
        }
        if (random.chance(4)) {
            add("Cross-Origin-Opener-Policy"_s, wideString(u"same-origin; report-to=\"\u0100\""));
            add("Document-Isolation-Policy"_s, wideString(u"isolate-and-require-corp; report-to=\"x\u0100\""));
            add("Cross-Origin-Embedder-Policy"_s, wideString(u"require-corp\u013B report-to=\"e\""));
            add("Origin-Agent-Cluster"_s, wideString(u"?1\u0120"));
        }
        auto& url = random.pick(urls);
        auto map = makeHeaderMap(WTF::move(headers));
        inputs.bytes += byteSize(map);
        inputs.responses.append(makeResponse(url, 200, WTF::move(map)));
    }
    return inputs;
}

template<typename Sink> void addEmbedderPolicy(Sink& sink, const WebCore::CrossOriginEmbedderPolicy& policy)
{
    sink.addInteger(static_cast<uint64_t>(policy.value));
    sink.addInteger(static_cast<uint64_t>(policy.reportOnlyValue));
    sink.addString(policy.reportingEndpoint);
    sink.addString(policy.reportOnlyReportingEndpoint);
}

template<typename Sink> void addOpenerPolicy(Sink& sink, const WebCore::CrossOriginOpenerPolicy& policy)
{
    sink.addInteger(static_cast<uint64_t>(policy.value));
    sink.addInteger(static_cast<uint64_t>(policy.reportOnlyValue));
    sink.addString(policy.reportingEndpoint);
    sink.addString(policy.reportOnlyReportingEndpoint);
}

template<typename Sink> void addIsolationPolicy(Sink& sink, const WebCore::DocumentIsolationPolicy& policy)
{
    sink.addInteger(static_cast<uint64_t>(policy.value));
    sink.addInteger(static_cast<uint64_t>(policy.reportOnlyValue));
    sink.addString(policy.reportingEndpoint);
    sink.addString(policy.reportOnlyReportingEndpoint);
}

template<typename Sink> void runPolicyHeadersPass(const PolicyHeadersInputs& inputs, Sink& sink)
{
    using WebCore::IsSecureContext;
    static constexpr std::array policyHeaderNames {
        HTTPHeaderName::CrossOriginOpenerPolicy, HTTPHeaderName::CrossOriginOpenerPolicyReportOnly, HTTPHeaderName::CrossOriginEmbedderPolicy,
        HTTPHeaderName::CrossOriginEmbedderPolicyReportOnly, HTTPHeaderName::DocumentIsolationPolicy, HTTPHeaderName::DocumentIsolationPolicyReportOnly,
    };
    for (auto& response : inputs.responses) {
        auto openerPolicy = WebCore::obtainCrossOriginOpenerPolicy(response, WebCore::CredentiallessSupport::No);
        addOpenerPolicy(sink, openerPolicy);
        auto embedderPolicy = WebCore::obtainCrossOriginEmbedderPolicy(response, IsSecureContext::Yes, WebCore::CredentiallessSupport::No, nullptr);
        addEmbedderPolicy(sink, embedderPolicy);
        addEmbedderPolicy(sink, WebCore::obtainCrossOriginEmbedderPolicy(response, IsSecureContext::No, WebCore::CredentiallessSupport::No, nullptr));
        auto isolationPolicy = WebCore::parseDocumentIsolationPolicy(response);
        addIsolationPolicy(sink, isolationPolicy);
        addIsolationPolicy(sink, WebCore::obtainDocumentIsolationPolicy(response, IsSecureContext::No, WebCore::CredentiallessSupport::No));
        sink.addBoolean(WebCore::obtainOriginAgentClusterPolicy(response, IsSecureContext::Yes, nullptr) == WebCore::OriginKeyed::Yes);
        sink.addBoolean(WebCore::obtainOriginAgentClusterPolicy(response, IsSecureContext::No, nullptr) == WebCore::OriginKeyed::Yes);

        WebCore::PolicyContainer container;
        container.crossOriginOpenerPolicy = WTF::move(openerPolicy);
        container.crossOriginEmbedderPolicy = WTF::move(embedderPolicy);
        container.documentIsolationPolicy = WTF::move(isolationPolicy);
        ResourceResponse written { WTF::URL { response.url() }, String { }, 0, String { } };
        WebCore::addPolicyContainerHeaders(written, container);
        for (auto name : policyHeaderNames)
            sink.addString(written.httpHeaderField(name));
    }
}

// IntegrityMetadata: integrity attributes checked against loaded resources, whose digests the resource keeps once
// computed. Each value is checked against three contents, each loaded same-origin and cross-origin without CORS.

struct IntegrityMetadataInputs {
    Vector<Ref<WebCore::CachedRawResource>> resources;
    Vector<String> values;
    uint64_t bytes { 0 };
};

inline Ref<WebCore::CachedRawResource> makeLoadedResource(const String& url, bool sameOrigin, std::span<const uint8_t> content)
{
    WebCore::ResourceLoaderOptions options;
    options.mode = WebCore::FetchOptions::Mode::NoCors;
    WebCore::CachedResourceRequest request { WebCore::ResourceRequest { WTF::URL { url } }, options };
    request.setOrigin(WebCore::SecurityOrigin::create(WTF::URL { sameOrigin ? url : String { "https://other.example/"_s } }));
    Ref resource = adoptRef(*new WebCore::CachedRawResource(WTF::move(request), WebCore::CachedResource::Type::RawResource, PAL::SessionID::defaultSessionID(), nullptr));
    Ref buffer = WebCore::SharedBuffer::create(content);
    // Through the base, so the call stays virtual: CachedRawResource's final override is not exported.
    WebCore::CachedResource& loadedResource = resource.get();
    loadedResource.finishLoading(buffer.ptr(), WebCore::NetworkLoadMetrics { });
    return resource;
}

inline String integrityValue(PAL::Crypto::CryptoDigest::Algorithm algorithm, std::span<const uint8_t> content, bool urlSafe)
{
    auto digest = PAL::Crypto::CryptoDigest::create(algorithm);
    digest->addBytes(content);
    auto hash = digest->computeHash();
    auto options = urlSafe ? OptionSet<WTF::Base64EncodeOption> { WTF::Base64EncodeOption::URL, WTF::Base64EncodeOption::OmitPadding } : OptionSet<WTF::Base64EncodeOption> { };
    return WTF::base64EncodeToString(hash.span(), options);
}

inline IntegrityMetadataInputs makeIntegrityMetadataInputs()
{
    using Algorithm = PAL::Crypto::CryptoDigest::Algorithm;
    static constexpr std::array algorithms { Algorithm::SHA_256, Algorithm::SHA_384, Algorithm::SHA_384, Algorithm::SHA_384, Algorithm::SHA_512 };
    static constexpr std::array malformed {
        "ed25519-YWJj"_s, "foo666-YWJj"_s, "sha256"_s, "sha256-"_s, "sha384-abc!def"_s, "sha256-==="_s, "md5-1B2M2Y8AsgTpgAmY7PhCfg=="_s,
        "sha2566-YWJj"_s, "sha25-YWJj"_s, "sha384-YWJj?"_s, "sha512-A"_s, "sha256-AB=="_s, "sha256-+/-_"_s,
    };
    static constexpr std::array options { "?foo=bar"_s, "?"_s, "?a?b"_s, "?ct=application/javascript"_s, "?foo=bar?spam=eggs"_s };
    static constexpr std::array separators { " "_s, " "_s, "  "_s, "\t"_s, "\n "_s };

    IntegrityMetadataInputs inputs;
    Vector<Vector<uint8_t>> contents;
    for (unsigned i = 0; i < 3; ++i) {
        Vector<uint8_t> content;
        Random contentRandom { 0x434F4E54454E5400ULL + i };
        unsigned length = i == 2 ? 1 : 900 + 700 * i;
        for (unsigned j = 0; j < length; ++j)
            content.append(static_cast<uint8_t>(' ' + contentRandom.below(95)));
        contents.append(WTF::move(content));
    }
    for (auto& content : contents) {
        auto index = inputs.resources.size();
        auto url = WTF::makeString("https://www.example.com/script"_s, index, ".js"_s);
        inputs.resources.append(makeLoadedResource(url, true, content.span()));
        inputs.resources.append(makeLoadedResource(url, false, content.span()));
    }

    auto prefix = [](Algorithm algorithm) {
        return algorithm == Algorithm::SHA_256 ? "sha256-"_s : algorithm == Algorithm::SHA_384 ? "sha384-"_s : "sha512-"_s;
    };
    auto digestToken = [&](Random& random, bool urlSafe) {
        auto algorithm = random.pick(algorithms);
        auto& content = contents[random.below(contents.size())];
        return WTF::makeString(prefix(algorithm), integrityValue(algorithm, content.span(), urlSafe));
    };

    for (auto edgeCase : { ""_s, " "_s, "\t\n"_s, "\v"_s, "sha256-"_s, "sha256-\vsha384-"_s, "sha256-YWJj sha256-YWJj"_s })
        inputs.values.append(edgeCase);
    inputs.values.append(WTF::makeString("sha\x12\x15\x16-"_s, integrityValue(Algorithm::SHA_256, contents[0].span(), false)));
    inputs.values.append(WTF::makeString("SHA384-"_s, integrityValue(Algorithm::SHA_384, contents[1].span(), false)));
    inputs.values.append(WTF::makeString(integrityValue(Algorithm::SHA_256, contents[0].span(), false), String::fromLatin1("\xA0"), "sha256-YWJj"_s));
    inputs.values.append(wideString(u"sha256-\u0130 sha384-YWJj"));

    Random random { 0x494E544547524954ULL };
    for (unsigned i = 0; i < 4096; ++i) {
        unsigned kind = random.below(100);
        WTF::StringBuilder builder;
        unsigned count = 1 + random.below(3);
        for (unsigned j = 0; j < count; ++j) {
            if (j)
                builder.append(random.pick(separators));
            if (kind >= 75 && kind < 85 && random.chance(50))
                builder.append(random.pick(malformed));
            else
                builder.append(digestToken(random, kind >= 85 && kind < 90));
            if (kind >= 60 && kind < 75)
                builder.append(random.pick(options));
        }
        String value = builder.toString();
        if (kind >= 90 && kind < 95) {
            auto prefix = random.chance(50) ? "  "_s : "\t"_s;
            auto suffix = random.chance(50) ? " "_s : "\v"_s;
            value = WTF::makeString(prefix, value, suffix);
        } else if (kind >= 95)
            value = random.chance(70) ? copyAs16Bit(value) : WTF::makeString(value, wideString(u" sha384-\u0130"));
        inputs.values.append(WTF::move(value));
    }
    for (auto& value : inputs.values)
        inputs.bytes += byteSize(value) * inputs.resources.size();
    return inputs;
}

template<typename Sink> void runIntegrityMetadataPass(const IntegrityMetadataInputs& inputs, Sink& sink)
{
    for (auto& value : inputs.values) {
        uint64_t decisions = 0;
        for (auto& resource : inputs.resources)
            decisions = (decisions << 1) | WebCore::matchIntegrityMetadataWithoutReportingHashes(resource.get(), value);
        sink.addInteger(decisions);
    }
}

// SandboxTokens: iframe sandbox attributes, and each of their tokens as the attribute's token list checks it.

struct SandboxAttribute {
    String value;
    Vector<String> tokens;
};

struct SandboxTokensInputs {
    Vector<SandboxAttribute> attributes;
    uint64_t bytes { 0 };
};

inline SandboxTokensInputs makeSandboxTokensInputs()
{
    static constexpr std::array tokens {
        "allow-scripts"_s, "allow-same-origin"_s, "allow-forms"_s, "allow-popups"_s, "allow-modals"_s, "allow-top-navigation"_s,
        "allow-top-navigation-by-user-activation"_s, "allow-top-navigation-to-custom-protocols"_s, "allow-pointer-lock"_s,
        "allow-popups-to-escape-sandbox"_s, "allow-storage-access-by-user-activation"_s, "allow-downloads"_s,
    };
    static constexpr std::array invalidTokens {
        "allow-script"_s, "allow-scriptss"_s, "allow-top-navigation-by-user-activatio"_s, "deny-scripts"_s, "allow-same-origin'"_s,
        "allow-presentation"_s, "allow-orientation-lock"_s, "'allow-forms'"_s, "allow_forms"_s, "allow-popups,"_s,
    };
    static constexpr std::array separators { " "_s, "\t"_s, "\n"_s, "\r"_s, "\f"_s };

    SandboxTokensInputs inputs;
    for (auto edgeCase : { ""_s, " "_s, "\v"_s, "allow-scripts\vallow-forms"_s, "allow\rscripts"_s, "allow-scripts allow-scripts"_s, " \t\n\r\f"_s })
        inputs.attributes.append({ edgeCase, { } });
    inputs.attributes.append({ String::fromLatin1("allow-\xA0" "forms allow-scripts"), { } });
    inputs.attributes.append({ wideString(u"allow-scr\u0130pts allow-\u212Aeys allow-same-origin"), { } });
    inputs.attributes.append({ wideString(u"allow-scripts\u3000allow-forms"), { } });

    Random random { 0x53414E44424F5853ULL };
    for (unsigned i = 0; i < 4000; ++i) {
        WTF::StringBuilder builder;
        if (random.chance(10))
            builder.append(random.pick(separators));
        unsigned count = random.below(13);
        for (unsigned j = 0; j < count; ++j) {
            if (j) {
                unsigned separatorCount = 1 + random.below(3);
                for (unsigned k = 0; k < separatorCount; ++k)
                    builder.append(random.chance(80) ? " "_s : random.pick(separators));
            }
            if (random.chance(10)) {
                builder.append(random.pick(invalidTokens));
                continue;
            }
            String token = random.pick(tokens);
            if (random.chance(25)) {
                WTF::StringBuilder flipped;
                for (char16_t character : StringView(token).codeUnits())
                    flipped.append(random.chance(30) ? toASCIIUpper(character) : character);
                token = flipped.toString();
            }
            builder.append(token);
        }
        if (random.chance(10))
            builder.append(random.pick(separators));
        String value = builder.toString();
        if (random.chance(12)) {
            value = copyAs16Bit(value);
            if (random.chance(50))
                value = WTF::makeString(value, wideString(u" allow-\u0130nvalid"));
        }
        inputs.attributes.append({ WTF::move(value), { } });
    }
    for (auto& attribute : inputs.attributes) {
        StringView value { attribute.value };
        unsigned start = 0;
        while (start < value.length()) {
            while (start < value.length() && isASCIIWhitespace(value[start]))
                ++start;
            unsigned end = start;
            while (end < value.length() && !isASCIIWhitespace(value[end]))
                ++end;
            if (end > start)
                attribute.tokens.append(value.substring(start, end - start).toString());
            start = end;
        }
        inputs.bytes += 2 * byteSize(attribute.value);
    }
    return inputs;
}

template<typename Sink> void runSandboxTokensPass(const SandboxTokensInputs& inputs, Sink& sink)
{
    for (auto& attribute : inputs.attributes) {
        String message;
        auto flags = WebCore::SecurityContext::parseSandboxPolicy(attribute.value, message);
        sink.addInteger(flags.toRaw());
        sink.addString(message);
        sink.addBoolean(WebCore::SecurityContext::isSupportedSandboxPolicy(attribute.value));
        for (auto& token : attribute.tokens)
            sink.addBoolean(WebCore::SecurityContext::isSupportedSandboxPolicy(token));
    }
}

// PermissionsPolicy: iframe allow attributes, with and without allowfullscreen and a src origin.

struct PermissionsPolicyInputs {
    RefPtr<WebCore::Settings> settings;
    RefPtr<WebCore::HTMLDocument> document;
    Vector<Ref<WebCore::HTMLIFrameElement>> iframes;
    uint64_t bytes { 0 };
};

inline PermissionsPolicyInputs makePermissionsPolicyInputs()
{
    static constexpr std::array features {
        "camera"_s, "microphone"_s, "speaker-selection"_s, "display-capture"_s, "gamepad"_s, "geolocation"_s, "payment"_s, "screen-wake-lock"_s,
        "sync-xhr"_s, "fullscreen"_s, "web-share"_s, "gyroscope"_s, "accelerometer"_s, "magnetometer"_s, "publickey-credentials-get"_s,
        "digital-credentials-get"_s, "xr-spatial-tracking"_s, "private-token"_s, "storage-access"_s, "local-network"_s, "loopback-network"_s,
        "cross-origin-isolated"_s,
    };
    static constexpr std::array otherFeatures { "vibrate"_s, "interest-cohort"_s, "battery"_s, "cameras"_s, "camera*"_s, "camera'self'"_s, "Camera"_s, "autoplay"_s };
    static constexpr std::array origins {
        "https://a.example"_s, "https://b.example:8443"_s, "http://c.example"_s, "https://d.example/path?q"_s, "data:text/plain,x"_s, "https://*.e.example"_s,
        "invalid url"_s, "https://xn--nxasmq6b.example"_s, "file:///x"_s, "blob:https://a.example/0b1c"_s, "javascript:alert(1)"_s, "https://A.EXAMPLE"_s,
        "http://127.0.0.1:8000"_s, "https://f.example."_s, "wss://g.example"_s, "about:blank"_s,
    };
    static constexpr std::array keywords { "*"_s, "'self'"_s, "'src'"_s, "'none'"_s, "'NONE'"_s, "'Self'"_s, "self"_s, "'self"_s, "**"_s, "'*'"_s };
    static constexpr std::array itemSeparators { "; "_s, ";"_s, " ; "_s, ";;"_s };
    static constexpr std::array sources { ""_s, "https://a.example/frame.html"_s, "https://b.example:8443/"_s, "http://c.example/"_s, "about:blank"_s, "https://www.example.com/same"_s };

    PermissionsPolicyInputs inputs;
    WebCore::ProcessWarming::initializeNames();
    inputs.settings = WebCore::Settings::create(nullptr);
    inputs.document = WebCore::HTMLDocument::create(nullptr, *inputs.settings, WTF::URL { "https://www.example.com/"_s });

    Random random { 0x5045524D49535349ULL };
    auto allowlist = [&](WTF::StringBuilder& builder) {
        unsigned kind = random.below(10);
        if (kind < 2)
            return;
        builder.append(' ');
        unsigned count = 1 + random.below(4);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                builder.append(random.chance(80) ? " "_s : "\t"_s);
            builder.append(random.chance(40) ? random.pick(keywords) : random.pick(origins));
        }
    };
    auto item = [&](WTF::StringBuilder& builder, bool legacy) {
        builder.append(random.chance(92) ? random.pick(features) : random.pick(otherFeatures));
        if (legacy)
            builder.append(random.chance(50) ? ":"_s : "::"_s);
        allowlist(builder);
    };
    Vector<String> values { ""_s, ";;;"_s, "   "_s, "camera :*"_s, "camera:"_s };
    for (unsigned i = 0; i < 2000; ++i) {
        unsigned kind = random.below(100);
        WTF::StringBuilder builder;
        unsigned count = kind < 5 ? 50 : 1 + random.below(6);
        for (unsigned j = 0; j < count; ++j) {
            if (j)
                builder.append(random.pick(itemSeparators));
            item(builder, kind >= 5 && kind < 15);
        }
        String value = builder.toString();
        if (kind >= 95)
            value = WTF::makeString(value, wideString(u"; camera https://\u0130.example"));
        values.append(WTF::move(value));
    }
    for (unsigned i = 0; i < values.size(); ++i) {
        Ref element = inputs.document->createElement(WebCore::HTMLNames::iframeTag, false);
        Ref iframe = downcast<WebCore::HTMLIFrameElement>(element);
        auto& source = sources[i % sources.size()];
        if (!source.isEmpty())
            iframe->setAttributeWithoutSynchronization(WebCore::HTMLNames::srcAttr, AtomString { source });
        if (!(i % 7))
            iframe->setAttributeWithoutSynchronization(WebCore::HTMLNames::srcdocAttr, "<p>"_s);
        if (i % 2)
            iframe->setAttributeWithoutSynchronization(i % 4 == 1 ? WebCore::HTMLNames::allowfullscreenAttr : WebCore::HTMLNames::webkitallowfullscreenAttr, emptyAtom());
        iframe->setAttributeWithoutSynchronization(WebCore::HTMLNames::allowAttr, AtomString { values[i] });
        inputs.bytes += byteSize(values[i]);
        inputs.iframes.append(WTF::move(iframe));
    }
    return inputs;
}

template<typename Sink> void runPermissionsPolicyPass(const PermissionsPolicyInputs& inputs, Sink& sink)
{
    for (auto& iframe : inputs.iframes) {
        auto directive = WebCore::PermissionsPolicy::processPermissionsPolicyAttribute(iframe.get());
        addUnordered(sink, directive, [](Sink& entrySink, auto& entry) {
            entrySink.addInteger(static_cast<uint64_t>(entry.key));
            auto& origins = entry.value.origins();
            entrySink.addInteger(origins.index());
            if (auto* set = std::get_if<HashSet<WebCore::SecurityOriginData>>(&origins)) {
                addUnordered(entrySink, *set, [](Sink& originSink, auto& origin) {
                    originSink.addString(origin.toString());
                });
            }
        });
    }
}

// FetchHeaders: Headers objects filled, appended to, set, removed from, read and iterated under each guard.

enum class FetchOperationKind : uint8_t { Append, Set, Remove, Get, Has, GetSetCookie, Fill, FillFromHeaders, FilterAndFill, Next };

struct FetchOperation {
    FetchOperationKind kind;
    String name;
    String value;
    std::optional<WebCore::FetchHeaders::Init> init;
    WebCore::HTTPHeaderMap map;
    Vector<String> setCookieValues;
    WebCore::FetchHeaders::Guard guard { WebCore::FetchHeaders::Guard::None };
};

struct FetchHeadersCase {
    WebCore::FetchHeaders::Guard guard;
    bool fromInit;
    std::optional<WebCore::FetchHeaders::Init> init;
    WebCore::HTTPHeaderMap map;
    Vector<FetchOperation> operations;
};

struct FetchHeadersInputs {
    Vector<FetchHeadersCase> cases;
    uint64_t bytes { 0 };
};

inline FetchHeadersInputs makeFetchHeadersInputs()
{
    using Guard = WebCore::FetchHeaders::Guard;
    static constexpr std::array guards { Guard::None, Guard::None, Guard::Request, Guard::RequestNoCors, Guard::Response, Guard::Immutable };
    static constexpr std::array names {
        "Content-Type"_s, "content-type"_s, "CONTENT-TYPE"_s, "Accept"_s, "accept-language"_s, "Cache-Control"_s, "Range"_s, "Content-Language"_s,
        "X-Custom"_s, "x-custom"_s, "X-Request-Id"_s, "Set-Cookie"_s, "set-cookie"_s, "SET-COOKIE"_s, "Cookie"_s, "Host"_s, "Sec-Fetch-Mode"_s,
        "Proxy-Authorization"_s, "Access-Control-Allow-Origin"_s, "Set-Cookie2"_s, "Authorization"_s, "DPR"_s, "Width"_s, "x-a"_s, "X-B"_s,
    };
    static constexpr std::array values {
        "text/plain"_s, "application/json"_s, " padded \t"_s, "a\fb"_s, "\fx"_s, "bytes=0-1023"_s, "en-US"_s, "session=abc; Path=/"_s, ""_s,
        "multipart/form-data; boundary=x"_s, "no-cache"_s, "1"_s,
    };
    static constexpr std::array invalidNames { "Bad Header"_s, ""_s, "x\x7F"_s, "x(y)"_s };
    static constexpr std::array invalidValues { "a\rb"_s, "a\nb"_s, "x\x01y"_s };

    FetchHeadersInputs inputs;
    Random random { 0x4645544348484452ULL };
    // Headers' bindings pass ByteStrings, so no name or value has a code unit above U+00FF.
    auto pickName = [&] -> String {
        unsigned kind = random.below(100);
        if (kind < 4)
            return random.pick(invalidNames);
        if (kind < 6)
            return String::fromLatin1(random.chance(50) ? "x\x80" : "x\xFF");
        if (kind < 7)
            return wideString(u"x\u00E9");
        auto& name = random.pick(names);
        return random.chance(10) ? copyAs16Bit(name) : String { name };
    };
    auto pickValue = [&] -> String {
        unsigned kind = random.below(100);
        if (kind < 3)
            return random.pick(invalidValues);
        if (kind < 4)
            return WTF::makeString('a', '\0', 'b');
        if (kind < 7)
            return random.token(200);
        if (kind < 10)
            return wideString(u"valu\u00E9");
        auto& value = random.pick(values);
        return random.chance(10) ? copyAs16Bit(value) : String { value };
    };
    auto pickPairs = [&](unsigned maximum) {
        Vector<std::pair<String, String>> pairs;
        unsigned count = random.below(maximum + 1);
        for (unsigned i = 0; i < count; ++i) {
            auto name = pickName();
            auto value = pickValue();
            pairs.append({ WTF::move(name), WTF::move(value) });
        }
        return pairs;
    };
    auto pickInit = [&] -> WebCore::FetchHeaders::Init {
        auto pairs = pickPairs(5);
        if (random.chance(50)) {
            Vector<KeyValuePair<String, String>> record;
            for (auto& [name, value] : pairs)
                record.append({ name, value });
            return record;
        }
        Vector<Vector<String>> sequence;
        for (auto& [name, value] : pairs)
            sequence.append({ name, value });
        if (random.chance(10))
            sequence.append(random.chance(50) ? Vector<String> { "X-One"_s } : Vector<String> { "X-Three"_s, "a"_s, "b"_s });
        return sequence;
    };
    // A map without Set-Cookie, whose entries a Headers object keeps apart from the other headers.
    auto pickMap = [&] {
        auto pairs = pickPairs(5);
        pairs.removeAllMatching([](auto& pair) {
            return equalLettersIgnoringASCIICase(pair.first, "set-cookie"_s);
        });
        return makeHeaderMap(WTF::move(pairs));
    };

    for (unsigned i = 0; i < 600; ++i) {
        FetchHeadersCase headersCase;
        headersCase.guard = random.pick(guards);
        headersCase.fromInit = headersCase.guard == Guard::None && random.chance(60);
        if (headersCase.fromInit) {
            if (random.chance(85))
                headersCase.init = pickInit();
        } else
            headersCase.map = pickMap();
        unsigned operationCount = 10 + random.below(31);
        for (unsigned j = 0; j < operationCount; ++j) {
            FetchOperation operation { FetchOperationKind::Next, { }, { }, std::nullopt, { }, { }, Guard::None };
            unsigned kind = random.below(100);
            if (kind < 22) {
                operation.kind = FetchOperationKind::Append;
                operation.name = pickName();
                operation.value = pickValue();
            } else if (kind < 34) {
                operation.kind = FetchOperationKind::Set;
                operation.name = pickName();
                operation.value = pickValue();
            } else if (kind < 42) {
                operation.kind = FetchOperationKind::Remove;
                operation.name = pickName();
            } else if (kind < 52) {
                operation.kind = FetchOperationKind::Get;
                operation.name = pickName();
            } else if (kind < 58) {
                operation.kind = FetchOperationKind::Has;
                operation.name = pickName();
            } else if (kind < 61)
                operation.kind = FetchOperationKind::GetSetCookie;
            else if (kind < 65) {
                operation.kind = FetchOperationKind::Fill;
                operation.init = pickInit();
            } else if (kind < 68) {
                operation.kind = FetchOperationKind::FillFromHeaders;
                operation.map = pickMap();
                if (random.chance(50))
                    operation.setCookieValues = { "a=b"_s, "c=d; Secure"_s };
            } else if (kind < 71) {
                operation.kind = FetchOperationKind::FilterAndFill;
                operation.map = pickMap();
                operation.guard = random.pick(guards);
            } else
                operation.kind = FetchOperationKind::Next;
            inputs.bytes += byteSize(operation.name) + byteSize(operation.value) + byteSize(operation.map);
            headersCase.operations.append(WTF::move(operation));
        }
        inputs.bytes += byteSize(headersCase.map);
        inputs.cases.append(WTF::move(headersCase));
    }
    return inputs;
}

template<typename Sink> void addFetchHeaders(Sink& sink, const WebCore::FetchHeaders& headers)
{
    addHeaderMap(sink, headers.internalHeaders());
    auto& setCookieValues = headers.getSetCookie();
    sink.addInteger(setCookieValues.size());
    for (auto& value : setCookieValues)
        sink.addString(value);
}

template<typename Sink> void runFetchHeadersPass(const FetchHeadersInputs& inputs, Sink& sink)
{
    using WebCore::FetchHeaders;
    for (auto& headersCase : inputs.cases) {
        RefPtr<FetchHeaders> created;
        if (headersCase.fromInit) {
            auto init = headersCase.init;
            auto result = FetchHeaders::create(WTF::move(init));
            addException(sink, result);
            if (result.hasException())
                continue;
            created = result.releaseReturnValue();
        } else
            created = FetchHeaders::create(headersCase.guard, WebCore::HTTPHeaderMap { headersCase.map });
        Ref headers = created.releaseNonNull();
        auto iterator = headers->createIterator(nullptr);
        for (auto& operation : headersCase.operations) {
            switch (operation.kind) {
            case FetchOperationKind::Append:
                addException(sink, headers->append(operation.name, operation.value));
                break;
            case FetchOperationKind::Set:
                addException(sink, headers->set(operation.name, operation.value));
                break;
            case FetchOperationKind::Remove:
                addException(sink, headers->remove(operation.name));
                break;
            case FetchOperationKind::Get: {
                auto result = headers->get(operation.name);
                addException(sink, result);
                if (!result.hasException())
                    sink.addString(result.returnValue());
                break;
            }
            case FetchOperationKind::Has: {
                auto result = headers->has(operation.name);
                addException(sink, result);
                if (!result.hasException())
                    sink.addBoolean(result.returnValue());
                break;
            }
            case FetchOperationKind::GetSetCookie:
                sink.addInteger(headers->getSetCookie().size());
                break;
            case FetchOperationKind::Fill:
                addException(sink, headers->fill(*operation.init));
                break;
            case FetchOperationKind::FillFromHeaders: {
                Ref other = FetchHeaders::create(FetchHeaders::Guard::None, WebCore::HTTPHeaderMap { operation.map }, Vector<String> { operation.setCookieValues });
                addException(sink, headers->fill(other.get()));
                break;
            }
            case FetchOperationKind::FilterAndFill:
                headers->filterAndFill(operation.map, operation.guard);
                break;
            case FetchOperationKind::Next: {
                auto next = iterator.next();
                sink.addBoolean(!!next);
                if (next) {
                    sink.addString(next->key);
                    sink.addString(next->value);
                }
                break;
            }
            }
        }
        addFetchHeaders(sink, headers.get());
    }
}

// CacheFreshness: the parsed-header getters, freshness lifetimes and ages of typical responses, revalidation, Vary,
// and the cache status of redirect chains. The clock is read only where a result does not depend on it.

struct FreshnessCase {
    ResourceResponse response;
    int statusCode; // As drawn: the response keeps a short, so 65837 is 301 there.
    unsigned validatingResponse;
    WebCore::HTTPHeaderMap requestHeaders;
    WebCore::HTTPHeaderMap laterRequestHeaders;
};

struct RedirectChain {
    Vector<ResourceResponse> steps;
    WebCore::CachingPolicy cachingPolicy;
};

struct CacheFreshnessInputs {
    Vector<FreshnessCase> cases;
    Vector<ResourceResponse> validatingResponses;
    Vector<RedirectChain> chains;
    uint64_t bytes { 0 };
};

// The response time of every freshness and age computation: one minute after the Date of most responses.
inline WallTime responseTime()
{
    return WallTime::fromRawSeconds(1794179620);
}

inline CacheFreshnessInputs makeCacheFreshnessInputs()
{
    static constexpr std::array schemes { "https://www.example.com/a"_s, "https://www.example.com/a"_s, "http://www.example.com/b"_s, "file:///c"_s, "data:text/plain,d"_s, "about:blank"_s };
    static constexpr std::array statusCodes { 200, 200, 200, 203, 204, 206, 300, 301, 302, 304, 404, 410, 500, 65837, -1 };
    static constexpr std::array cacheControls {
        "max-age=31536000, immutable"_s, "public, max-age=3600"_s, "private, max-age=0, no-cache"_s, "no-cache, no-store, must-revalidate"_s, "no-store"_s,
        "max-age=600, stale-while-revalidate=30"_s, "max-age=0, must-revalidate"_s, "s-maxage=300, max-age=60"_s, "max-age=\"3600\""_s, "max-age=abc"_s,
        "max-age=60, max-age=120"_s, "MAX-AGE=10, Public"_s, "max-age=-1"_s, "max-age=0"_s, "max-age=1e400"_s, "max-age=1.5"_s, "immutable"_s,
        "no-cache=\"Set-Cookie\""_s, "max-age=3600\t, public"_s, ",,max-age=5,,"_s,
    };
    static constexpr std::array dates {
        "Sun, 08 Nov 2026 23:12:40 GMT"_s, "Sun, 08 Nov 2026 23:12:40 GMT"_s, "Sunday, 08-Nov-26 23:12:40 GMT"_s, "Sun Nov  8 23:12:40 2026"_s, "not a date"_s, ""_s,
        "Thu, 01 Jan 1970 00:00:00 GMT"_s, "Thu, 01 Jan 1970 00:00:01 GMT"_s, "Fri, 31 Dec 9999 23:59:59 GMT"_s, "Mon, 01 Jan 1601 00:00:00 GMT"_s,
        "Sun, 08 Nov 2026 23:13:40 GMT"_s, "Wed, 21 Oct 2026 07:28:00 GMT"_s,
    };
    static constexpr std::array ages { "0"_s, "10"_s, "-5"_s, "+3"_s, "1e400"_s, "\v7"_s, "7 "_s, "abc"_s, ""_s, "3600"_s };
    static constexpr std::array pragmas { "no-cache"_s, "No-Cache"_s, "foo, no-cache"_s, "x-no-cachex"_s, ""_s };
    static constexpr std::array varies { "Accept-Encoding"_s, "Origin"_s, "Accept-Encoding, Cookie"_s, "*"_s, "cookie"_s, ",,Accept"_s, "Accept-Language, "_s, "X-A,  ,x-b"_s };
    static constexpr std::array chainCacheControls { ""_s, "max-age=60"_s, "max-age=3600"_s, "max-age=0"_s, "no-store"_s, "no-cache"_s, "must-revalidate"_s, "public, max-age=86400"_s };
    static constexpr std::array chainStatusCodes { 301, 302, 307, 308, 410 };
    static constexpr std::array chainAges { ""_s, ""_s, "10"_s, "100000000"_s, "-5"_s };

    CacheFreshnessInputs inputs;
    Random random { 0x4652455348455353ULL };
    auto maybePick = [&](unsigned percent, const auto& choices) -> String {
        if (!random.chance(percent))
            return { };
        return random.pick(choices);
    };

    for (auto& [cacheControl, extra] : std::array {
        std::pair { "max-age=0"_s, "X-Content-Type-Options"_s }, std::pair { "no-cache"_s, "Content-Security-Policy"_s }, std::pair { "max-age=120"_s, "X-Webkit-Thing"_s } }) {
        Vector<std::pair<String, String>> headers {
            { "Cache-Control"_s, cacheControl }, { "ETag"_s, "\"33a64df5\""_s }, { "Date"_s, "Sun, 08 Nov 2026 23:12:41 GMT"_s }, { "Content-Length"_s, "0"_s },
            { "Content-Type"_s, "text/html"_s }, { "Content-Security-Policy-Report-Only"_s, "default-src 'none'"_s }, { "X-Content-Type"_s, "a"_s },
            { extra, "v"_s }, { "Expires"_s, "Mon, 09 Nov 2026 23:12:41 GMT"_s }, { "Keep-Alive"_s, "timeout=5"_s }, { "X-Request-Id"_s, "7f3c"_s },
        };
        inputs.validatingResponses.append(makeResponse("https://www.example.com/a"_s, 304, makeHeaderMap(WTF::move(headers))));
    }

    for (unsigned i = 0; i < 1500; ++i) {
        bool wide = random.chance(15);
        Vector<std::pair<String, String>> headers;
        auto add = [&](ASCIILiteral name, const String& value) {
            if (!value.isNull())
                headers.append({ name, wide ? copyAs16Bit(value) : value });
        };
        add("Content-Type"_s, "text/html"_s);
        add("Cache-Control"_s, maybePick(75, cacheControls));
        if (random.chance(10))
            add("Cache-Control"_s, random.pick(cacheControls));
        add("Date"_s, maybePick(70, dates));
        add("Expires"_s, maybePick(30, dates));
        add("Last-Modified"_s, maybePick(40, dates));
        add("Age"_s, maybePick(35, ages));
        add("Pragma"_s, maybePick(10, pragmas));
        add("Vary"_s, maybePick(40, varies));
        add("ETag"_s, maybePick(30, std::array { "\"a1\""_s, "W/\"b2\""_s }));
        if (wide && random.chance(30))
            headers.append({ "Cache-Control"_s, wideString(u"max-age=60\u012C public") });
        auto& url = random.pick(schemes);
        int statusCode = random.pick(statusCodes);
        auto map = makeHeaderMap(WTF::move(headers));
        inputs.bytes += byteSize(map);
        auto requestHeaders = makeHeaderMap({ { "Accept-Encoding"_s, "gzip, br"_s }, { "Origin"_s, "https://app.example.com"_s }, { "Accept-Language"_s, "en"_s }, { "X-A"_s, "1"_s } });
        auto laterRequestHeaders = makeHeaderMap({ { "Accept-Encoding"_s, random.chance(50) ? "gzip, br"_s : "identity"_s }, { "Origin"_s, "https://app.example.com"_s } });
        inputs.cases.append({ makeResponse(url, statusCode, WTF::move(map)), statusCode, random.below(inputs.validatingResponses.size()), WTF::move(requestHeaders), WTF::move(laterRequestHeaders) });
    }

    // Redirects with no Date, Expires or Last-Modified, whose validity is a whole number of seconds from the clock.
    for (unsigned i = 0; i < 400; ++i) {
        RedirectChain chain;
        chain.cachingPolicy = random.chance(85) ? WebCore::CachingPolicy::AllowCaching : WebCore::CachingPolicy::AllowCachingMainResourcePrefetch;
        unsigned stepCount = 1 + random.below(4);
        for (unsigned j = 0; j < stepCount; ++j) {
            Vector<std::pair<String, String>> headers;
            headers.append({ "Location"_s, WTF::makeString("https://www.example.com/step"_s, j + 1) });
            auto& cacheControl = random.pick(chainCacheControls);
            if (!cacheControl.isEmpty())
                headers.append({ "Cache-Control"_s, cacheControl });
            auto& age = random.pick(chainAges);
            if (!age.isEmpty())
                headers.append({ "Age"_s, age });
            int statusCode = random.pick(chainStatusCodes);
            auto map = makeHeaderMap(WTF::move(headers));
            inputs.bytes += byteSize(map);
            chain.steps.append(makeResponse(random.chance(90) ? "https://www.example.com/r"_s : "file:///r"_s, statusCode, WTF::move(map)));
        }
        inputs.chains.append(WTF::move(chain));
    }
    return inputs;
}

template<typename Sink> void addCacheControlDirectives(Sink& sink, const WebCore::CacheControlDirectives& directives)
{
    for (auto& seconds : { directives.maxAge, directives.maxStale, directives.minFresh, directives.staleWhileRevalidate }) {
        sink.addBoolean(!!seconds);
        if (seconds)
            sink.addDouble(seconds->value());
    }
    sink.addBoolean(directives.noCache);
    sink.addBoolean(directives.noStore);
    sink.addBoolean(directives.mustRevalidate);
    sink.addBoolean(directives.immutable);
    sink.addBoolean(directives.isPublic);
}

template<typename Sink> void addParsedHeaders(Sink& sink, const ResourceResponse& response)
{
    sink.addBoolean(response.cacheControlContainsNoCache());
    sink.addBoolean(response.cacheControlContainsNoStore());
    sink.addBoolean(response.cacheControlContainsPublic());
    sink.addBoolean(response.cacheControlContainsMustRevalidate());
    sink.addBoolean(response.cacheControlContainsImmutable());
    sink.addBoolean(response.hasCacheValidatorFields());
    addSeconds(sink, response.cacheControlMaxAge());
    addSeconds(sink, response.cacheControlStaleWhileRevalidate());
    addWallTime(sink, response.date());
    addSeconds(sink, response.age());
    addWallTime(sink, response.expires());
    addWallTime(sink, response.lastModified());
}

template<typename Sink> void runCacheFreshnessPass(const CacheFreshnessInputs& inputs, Sink& sink)
{
    for (auto& freshnessCase : inputs.cases) {
        auto response = freshnessCase.response;
        addParsedHeaders(sink, response);
        sink.addDouble(WebCore::computeFreshnessLifetimeForHTTPFamily(response, responseTime()).value());
        auto currentAge = WebCore::computeCurrentAge(response, responseTime());
        addWholeSeconds(sink, (currentAge - (WallTime::now() - responseTime())).value());
        addCacheControlDirectives(sink, WebCore::parseCacheControlDirectives(response.httpHeaderFields()));
        sink.addBoolean(WebCore::isStatusCodeCacheableByDefault(freshnessCase.statusCode));

        auto requestValue = [](const WebCore::HTTPHeaderMap& headers) {
            return [&headers](StringView name) {
                return headers.get(name);
            };
        };
        auto varyingHeaders = WebCore::collectVaryingRequestHeaders(response, requestValue(freshnessCase.requestHeaders));
        sink.addInteger(varyingHeaders.size());
        for (auto& [name, value] : varyingHeaders) {
            sink.addString(name);
            sink.addString(value);
        }
        sink.addBoolean(WebCore::verifyVaryingRequestHeaders(varyingHeaders, [&](const String& name) {
            return freshnessCase.requestHeaders.get(name);
        }));
        sink.addBoolean(WebCore::verifyVaryingRequestHeaders(varyingHeaders, [&](const String& name) {
            return freshnessCase.laterRequestHeaders.get(name);
        }));

        // Setting a header parses it again; Age keeps its last valid value.
        response.setHTTPHeaderField(HTTPHeaderName::Age, "7"_s);
        addSeconds(sink, response.age());
        response.setHTTPHeaderField(HTTPHeaderName::Age, "abc"_s);
        addSeconds(sink, response.age());
        response.setHTTPHeaderField(HTTPHeaderName::Pragma, "no-cache"_s);
        sink.addBoolean(response.cacheControlContainsNoCache());

        WebCore::updateResponseHeadersAfterRevalidation(response, inputs.validatingResponses[freshnessCase.validatingResponse]);
        addHeaderMap(sink, response.httpHeaderFields());
        addParsedHeaders(sink, response);
    }

    for (auto& chain : inputs.chains) {
        WebCore::ResourceLoaderOptions options;
        options.cachingPolicy = chain.cachingPolicy;
        WebCore::RedirectChainCacheStatus status;
        for (auto& step : chain.steps) {
            WebCore::updateRedirectChainStatus(status, step, options);
            sink.addInteger(static_cast<uint64_t>(status.status));
            double validity = (status.endOfValidity - WallTime::now()).value();
            addWholeSeconds(sink, validity);
            sink.addBoolean(WebCore::redirectChainAllowsReuse(status, WebCore::ReuseExpiredRedirection));
            // Whether a validity that rounds to zero has ended depends on the clock, so it is not checked.
            if (!std::isfinite(validity) || std::llround(validity))
                sink.addBoolean(WebCore::redirectChainAllowsReuse(status, WebCore::DoNotReuseExpiredRedirection));
        }
    }
}

// ReferrerHeaders: the Referer and Origin headers of requests under each referrer policy.

struct ReferrerCase {
    WebCore::ReferrerPolicy policy;
    WTF::URL url;
    WTF::URL referrer;
    unsigned origin;
};

struct ReferrerHeadersInputs {
    Vector<Ref<WebCore::SecurityOrigin>> origins;
    Vector<ReferrerCase> cases;
    uint64_t bytes { 0 };
};

inline ReferrerHeadersInputs makeReferrerHeadersInputs()
{
    using WebCore::ReferrerPolicy;
    static constexpr std::array policies {
        ReferrerPolicy::EmptyString, ReferrerPolicy::NoReferrer, ReferrerPolicy::NoReferrerWhenDowngrade, ReferrerPolicy::SameOrigin, ReferrerPolicy::Origin,
        ReferrerPolicy::StrictOrigin, ReferrerPolicy::OriginWhenCrossOrigin, ReferrerPolicy::StrictOriginWhenCrossOrigin, ReferrerPolicy::StrictOriginWhenCrossOrigin,
        ReferrerPolicy::UnsafeUrl,
    };
    static constexpr std::array referrers {
        "https://www.example.com/page?q=1"_s, "https://www.example.com/"_s, "http://www.example.com/article/42"_s, "file:///home/test/index.html"_s, ""_s,
        "data:text/html,hi"_s, "HTTPS://WWW.EXAMPLE.COM/Upper"_s, "https://www.example.com:8443/x"_s, "https://sub.example.com/"_s, "https://caf%C3%A9.example/p"_s,
        "http://localhost:8000/dev"_s, "about:blank"_s,
    };
    static constexpr std::array urls {
        "https://www.example.com/next"_s, "https://cdn.example.com/x.js"_s, "https://other.org/"_s, "http://www.example.com/insecure"_s, "file:///x"_s,
        "data:image/png;base64,iVBORw0KGgo="_s, "blob:https://www.example.com/0b1c"_s, "not a url"_s, "HTTPS://WWW.EXAMPLE.COM:443/"_s, "wss://www.example.com/socket"_s,
    };
    static constexpr std::array originURLs { "https://www.example.com/"_s, "http://www.example.com/"_s, "https://other.org/"_s, "https://www.example.com:8443/"_s };

    ReferrerHeadersInputs inputs;
    for (auto url : originURLs)
        inputs.origins.append(WebCore::SecurityOrigin::create(WTF::URL { String { url } }));
    inputs.origins.append(WebCore::SecurityOrigin::createOpaque());

    Random random { 0x5245464552524552ULL };
    for (unsigned i = 0; i < 3000; ++i) {
        auto policy = random.pick(policies);
        auto& referrer = random.pick(referrers);
        auto& url = random.pick(urls);
        WTF::URL referrerURL { String { referrer } };
        // A request never has the empty string policy with a referrer it could send.
        if (policy == ReferrerPolicy::EmptyString && referrerURL.protocolIsInHTTPFamily())
            policy = ReferrerPolicy::Default;
        unsigned origin = random.below(inputs.origins.size());
        WTF::URL requestURL { String { url } };
        inputs.bytes += byteSize(requestURL.string()) + byteSize(referrerURL.string());
        inputs.cases.append({ policy, WTF::move(requestURL), WTF::move(referrerURL), origin });
    }
    return inputs;
}

template<typename Sink> void runReferrerHeadersPass(const ReferrerHeadersInputs& inputs, Sink& sink)
{
    auto& patterns = WebCore::EmptyOriginAccessPatterns::singleton();
    for (auto& referrerCase : inputs.cases) {
        sink.addString(WebCore::SecurityPolicy::generateReferrerHeader(referrerCase.policy, referrerCase.url, referrerCase.referrer, patterns));
        sink.addString(WebCore::SecurityPolicy::generateOriginHeader(referrerCase.policy, referrerCase.url, inputs.origins[referrerCase.origin], patterns));
    }
}

// ResponseMix: realistic responses, each through the policies a load applies to it.

struct MixedResponse {
    ResourceResponse response;
    Ref<WebCore::SecurityOrigin> responseOrigin;
    WTF::URL requestURL;
    StoredCredentialsPolicy policy;
    WebCore::CrossOriginEmbedderPolicy embedderPolicy;
    WebCore::DocumentIsolationPolicy isolationPolicy;
    WebCore::ForNavigation forNavigation;
    Vector<String> timingAllowOrigins;
};

struct ResponseMixInputs {
    Ref<WebCore::SecurityOrigin> initiator;
    Vector<MixedResponse> responses;
    uint64_t bytes { 0 };
};

inline ResponseMixInputs makeResponseMixInputs()
{
    using Headers = Vector<std::pair<ASCIILiteral, ASCIILiteral>>;
    struct Template {
        ASCIILiteral url;
        int statusCode;
        Tainting tainting;
        Headers headers;
    };
    const std::array templates {
        Template { "https://www.example.com/"_s, 200, Tainting::Basic, {
            { "Content-Type"_s, "text/html; charset=utf-8"_s }, { "Content-Length"_s, "48213"_s }, { "Cache-Control"_s, "private, max-age=0, no-cache"_s },
            { "Date"_s, "Sun, 08 Nov 2026 23:12:40 GMT"_s }, { "X-Content-Type-Options"_s, "nosniff"_s }, { "Cross-Origin-Opener-Policy"_s, "same-origin; report-to=\"coop\""_s },
            { "Cross-Origin-Embedder-Policy"_s, "require-corp"_s }, { "Origin-Agent-Cluster"_s, "?1"_s }, { "Set-Cookie"_s, "session=abc; Path=/; Secure; HttpOnly"_s },
            { "Integrity-Policy"_s, "blocked-destinations=(script), endpoints=(integrity-endpoint)"_s }, { "Vary"_s, "Accept-Encoding, Cookie"_s } } },
        Template { "https://static.example.com/app.3f9a1c.js"_s, 200, Tainting::Cors, {
            { "Content-Type"_s, "application/javascript"_s }, { "Content-Length"_s, "183402"_s }, { "Cache-Control"_s, "public, max-age=31536000, immutable"_s },
            { "ETag"_s, "\"3f9a1c\""_s }, { "Last-Modified"_s, "Wed, 21 Oct 2026 07:28:00 GMT"_s }, { "Cross-Origin-Resource-Policy"_s, "cross-origin"_s },
            { "Access-Control-Allow-Origin"_s, "*"_s }, { "Timing-Allow-Origin"_s, "*"_s }, { "Age"_s, "3600"_s }, { "X-Content-Type-Options"_s, "nosniff"_s } } },
        Template { "https://static.example.com/site.css"_s, 200, Tainting::Opaque, {
            { "Content-Type"_s, "text/css;charset=UTF-8"_s }, { "Cache-Control"_s, "max-age=600, stale-while-revalidate=30"_s },
            { "X-Content-Type-Options"_s, "NoSniff, other"_s }, { "Cross-Origin-Resource-Policy"_s, "same-site"_s }, { "Timing-Allow-Origin"_s, "https://www.example.com, https://other.org"_s } } },
        Template { "https://img.example.org/hero.webp"_s, 200, Tainting::Opaque, {
            { "Content-Type"_s, "image/webp"_s }, { "Cache-Control"_s, "max-age=86400"_s }, { "Cross-Origin-Resource-Policy"_s, "Same-Origin"_s },
            { "Expires"_s, "0"_s }, { "Timing-Allow-Origin"_s, " null ,, *\f"_s } } },
        Template { "https://api.example.com/v1/items"_s, 200, Tainting::Cors, {
            { "Content-Type"_s, "application/json; charset=utf-8"_s }, { "Cache-Control"_s, "private, no-store"_s }, { "Access-Control-Allow-Origin"_s, "https://www.example.com"_s },
            { "Access-Control-Allow-Credentials"_s, "true"_s }, { "Access-Control-Expose-Headers"_s, "X-Request-Id, Server-Timing"_s }, { "X-Request-Id"_s, "7f3c2a1b"_s },
            { "Pragma"_s, "no-cache"_s } } },
        Template { "https://media.example.com/video.mp4"_s, 206, Tainting::Cors, {
            { "Content-Type"_s, "video/mp4"_s }, { "Content-Range"_s, "bytes 0-1048575/52428800"_s }, { "Access-Control-Allow-Origin"_s, "https://www.example.com, https://a.example"_s },
            { "Cache-Control"_s, "max-age=3600"_s }, { "Cross-Origin-Resource-Policy"_s, "same-origin"_s } } },
        Template { "https://files.example.com/download?id=42"_s, 200, Tainting::Basic, {
            { "Content-Type"_s, "application/pdf"_s }, { "Content-Disposition"_s, "attachment; filename=\"report Q3.pdf\""_s }, { "Cache-Control"_s, "no-cache"_s },
            { "Content-Range"_s, "bytes */734221"_s } } },
        Template { "http://insecure.example.com/old"_s, 301, Tainting::Basic, {
            { "Location"_s, "https://www.example.com/new"_s }, { "Cache-Control"_s, "max-age=3600"_s }, { "Content-Type"_s, "text/html; charset=iso-8859-1"_s },
            { "X-Bad"_s, " leading space"_s } } },
        Template { "https://www.example.com/logout"_s, 200, Tainting::Basic, {
            { "Content-Type"_s, "text/javascript"_s }, { "Cache-Control"_s, "no-store"_s }, { "X-Content-Type-Options"_s, "nosniff"_s },
            { "Cross-Origin-Opener-Policy"_s, "same-origin-allow-popups"_s }, { "Integrity-Policy-Report-Only"_s, "blocked-destinations=(script script), sources=(inline), endpoints=(a b)"_s },
            { "Document-Isolation-Policy"_s, "isolate-and-require-corp; report-to=\"dip\""_s } } },
        Template { "https://cdn.example.com/dictionary.dat"_s, 200, Tainting::Cors, {
            { "Content-Type"_s, "application/octet-stream"_s }, { "Access-Control-Allow-Origin"_s, "null"_s }, { "Content-Disposition"_s, "inline; filename=dictionary.dat"_s },
            { "Cross-Origin-Resource-Policy"_s, "cross-origin"_s }, { "Integrity-Policy"_s, "sources=?1, blocked-destinations=(\"script\")"_s } } },
        Template { "https://www.example.com/status"_s, 200, Tainting::Basic, {
            { "Content-Type"_s, "text/plain"_s }, { "X-Content-Type-Options"_s, ""_s }, { "Cross-Origin-Opener-Policy-Report-Only"_s, "same-origin; report-to=\"coop\""_s },
            { "Cross-Origin-Embedder-Policy-Report-Only"_s, "require-corp"_s }, { "Content-Disposition"_s, "Attachment ; filename=x"_s } } },
        Template { "https://www.example.org/missing"_s, 404, Tainting::Opaque, {
            { "Content-Type"_s, "text/html; charset=\"utf-8\""_s }, { "Date"_s, "not a date"_s }, { "Cache-Control"_s, "max-age=60, must-revalidate"_s },
            { "Cross-Origin-Embedder-Policy"_s, "credentialless; report-to=coep"_s }, { "Timing-Allow-Origin"_s, "https://www.example.com/"_s } } },
    };
    static constexpr std::array policies { StoredCredentialsPolicy::DoNotUse, StoredCredentialsPolicy::Use };
    using WebCore::CrossOriginEmbedderPolicyValue;
    using WebCore::DocumentIsolationPolicyValue;

    ResponseMixInputs inputs { WebCore::SecurityOrigin::create(WTF::URL { "https://www.example.com/"_s }), { }, 0 };
    Random random { 0x524553504D495853ULL };
    for (unsigned i = 0; i < 640; ++i) {
        auto& responseTemplate = random.pick(templates);
        bool wide = random.chance(20);
        Vector<std::pair<String, String>> headers;
        for (auto& [name, value] : responseTemplate.headers)
            headers.append({ name, wide ? copyAs16Bit(value) : String { value } });
        if (wide && random.chance(40)) {
            headers.append({ "Content-Disposition"_s, wideString(u"attachment; filename=\"\u65E5\u672C.pdf\"") });
            headers.append({ "Timing-Allow-Origin"_s, wideString(u"https://www.example.com\u012C *") });
            headers.append({ wideString(u"X-\u0130"), "v"_s });
        }
        auto map = makeHeaderMap(WTF::move(headers));
        inputs.bytes += byteSize(map);
        Vector<String> timingAllowOrigins;
        for (auto& header : map) {
            if (header.keyAsHTTPHeaderName != HTTPHeaderName::TimingAllowOrigin)
                continue;
            for (auto piece : StringView(header.value).split(','))
                timingAllowOrigins.append(piece.trim(isASCIIWhitespaceWithoutFF<char16_t>).toString());
        }
        auto response = makeResponse(responseTemplate.url, responseTemplate.statusCode, WTF::move(map), responseTemplate.tainting);
        auto responseOrigin = WebCore::SecurityOrigin::create(response.url());
        auto embedderValue = random.chance(30) ? CrossOriginEmbedderPolicyValue::RequireCORP : CrossOriginEmbedderPolicyValue::UnsafeNone;
        auto embedderReportOnlyValue = random.chance(15) ? CrossOriginEmbedderPolicyValue::RequireCORP : CrossOriginEmbedderPolicyValue::UnsafeNone;
        auto isolationValue = random.chance(15) ? DocumentIsolationPolicyValue::IsolateAndRequireCORP : DocumentIsolationPolicyValue::None;
        auto policy = random.pick(policies);
        auto forNavigation = random.chance(20) ? WebCore::ForNavigation::Yes : WebCore::ForNavigation::No;
        inputs.responses.append({
            WTF::move(response), WTF::move(responseOrigin), WTF::URL { String { responseTemplate.url } }, policy,
            { embedderValue, embedderReportOnlyValue, { }, { } }, { isolationValue, DocumentIsolationPolicyValue::None, { }, { } }, forNavigation,
            WTF::move(timingAllowOrigins),
        });
    }
    return inputs;
}

template<typename Sink> void runResponseMixPass(const ResponseMixInputs& inputs, Sink& sink)
{
    using WebCore::IsSecureContext;
    using WebCore::ResourceResponseBase;
    auto& patterns = WebCore::EmptyOriginAccessPatterns::singleton();
    auto& initiator = inputs.initiator.get();
    const MixedResponse* previous = nullptr;
    Vector<Vector<String>> navigationTimingAllowOrigins;
    unsigned index = 0;
    for (auto& mixed : inputs.responses) {
        auto& response = mixed.response;
        if (response.tainting() == Tainting::Cors)
            addExpected(sink, WebCore::passesAccessControlCheck(response, mixed.policy, initiator, nullptr));
        auto error = WebCore::performCrossOriginResourcePolicyCheck(mixed.embedderPolicy, mixed.isolationPolicy, initiator, mixed.requestURL, response, mixed.forNavigation, patterns, nullptr);
        sink.addBoolean(!!error);
        if (error)
            sink.addString(error->localizedDescription());
        sink.addBoolean(WebCore::passesTimingAllowOriginCheck(response, initiator));

        auto openerPolicy = WebCore::obtainCrossOriginOpenerPolicy(response, WebCore::CredentiallessSupport::No);
        addOpenerPolicy(sink, openerPolicy);
        addEmbedderPolicy(sink, WebCore::obtainCrossOriginEmbedderPolicy(response, IsSecureContext::Yes, WebCore::CredentiallessSupport::No, nullptr));
        addIsolationPolicy(sink, WebCore::parseDocumentIsolationPolicy(response));
        sink.addBoolean(WebCore::obtainOriginAgentClusterPolicy(response, IsSecureContext::Yes, nullptr) == WebCore::OriginKeyed::Yes);
        if (previous) {
            auto previousOpenerPolicy = WebCore::obtainCrossOriginOpenerPolicy(previous->response, WebCore::CredentiallessSupport::No);
            auto isInitialAboutBlank = index % 3 ? WebCore::IsInitialAboutBlank::No : WebCore::IsInitialAboutBlank::Yes;
            sink.addBoolean(WebCore::coopValuesRequireBrowsingContextGroupSwitch(isInitialAboutBlank, previousOpenerPolicy.value, previous->responseOrigin, openerPolicy.value, mixed.responseOrigin));
        }

        for (auto name : { HTTPHeaderName::IntegrityPolicy, HTTPHeaderName::IntegrityPolicyReportOnly }) {
            auto integrityPolicy = WebCore::processIntegrityPolicy(response, name);
            sink.addBoolean(!!integrityPolicy);
            if (integrityPolicy) {
                for (auto* list : { &integrityPolicy->blockedDestinations, &integrityPolicy->sources, &integrityPolicy->endpoints }) {
                    sink.addInteger(list->size());
                    for (auto& value : *list)
                        sink.addString(value);
                }
            }
        }

        if (response.tainting() == Tainting::Basic) {
            auto sanitized = response;
            sanitized.sanitizeHTTPHeaderFields(ResourceResponseBase::SanitizationType::CrossOriginSafe);
            addHeaderMap(sink, sanitized.httpHeaderFields());
        } else
            addResponse(sink, ResourceResponseBase::filter(response, ResourceResponseBase::PerformExposeAllHeadersCheck::Yes));

        sink.addBoolean(WebCore::isScriptAllowedByNosniff(response));
        sink.addBoolean(response.containsInvalidHTTPHeaders());
        sink.addBoolean(response.isAttachment());
        sink.addBoolean(response.isAttachmentWithFilename());

        auto copy = response;
        addParsedHeaders(sink, copy);
        sink.addDouble(WebCore::computeFreshnessLifetimeForHTTPFamily(copy, responseTime()).value());
        auto& contentRange = copy.contentRange();
        sink.addBoolean(contentRange.isValid());
        sink.addInteger(static_cast<uint64_t>(contentRange.firstBytePosition()));
        sink.addInteger(static_cast<uint64_t>(contentRange.lastBytePosition()));
        sink.addInteger(static_cast<uint64_t>(contentRange.instanceLength()));
        copy.setHTTPHeaderField(HTTPHeaderName::CacheControl, "no-store"_s);
        sink.addBoolean(copy.cacheControlContainsNoStore());

        navigationTimingAllowOrigins.append(mixed.timingAllowOrigins);
        if (navigationTimingAllowOrigins.size() > 3)
            navigationTimingAllowOrigins.removeAt(0);
        sink.addBoolean(WebCore::passesNavigationTAOCheck(navigationTimingAllowOrigins, initiator));

        previous = &mixed;
        ++index;
    }
}

} // namespace TestWebKitAPI::SecurityPoliciesBench
