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

// Inputs and passes of the HTTP header parser benchmark. Each test has a generator, which builds the same inputs on
// every run from a fixed seed, and a pass, which runs every input of the test once through the parsers and folds
// their outputs into a sink: a Digest for the checksum, or a Tally for the timed passes.

#include <WebCore/CacheValidation.h>
#include <WebCore/HTTPHeaderField.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/HTTPHeaderNames.h>
#include <WebCore/HTTPParsers.h>
#include <WebCore/LinkHeader.h>
#include <WebCore/ParsedContentRange.h>
#include <WebCore/ParsedContentType.h>
#include <WebCore/RFC8941.h>
#include <WebCore/ReferrerPolicy.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/ServerTiming.h>
#include <WebCore/ServerTimingParser.h>
#include <array>
#include <bit>
#include <limits>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI::HTTPHeaderParsersBench {

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
    void addBytes(std::span<const uint8_t> bytes)
    {
        addInteger(bytes.size());
        for (auto byte : bytes)
            addByte(byte);
    }
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

// The timed passes read each output's scalars and lengths only, so that their time is the parsers'.
class Tally {
public:
    void addInteger(uint64_t value) { m_value += value; }
    void addBoolean(bool value) { m_value += value; }
    void addDouble(double value) { m_value += std::bit_cast<uint64_t>(value); }
    void addBytes(std::span<const uint8_t> bytes) { m_value += bytes.size(); }
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

// Where a returned view starts in the argument, in code units. A view that is not into the argument, or not of its
// width, gives a value no offset can have.
inline uint64_t viewOffset(StringView view, StringView argument)
{
    if (view.isEmpty())
        return 0;
    constexpr uint64_t notInArgument = std::numeric_limits<uint64_t>::max();
    if (view.is8Bit() != argument.is8Bit() || argument.isEmpty())
        return notInArgument;
    uintptr_t viewStart = view.is8Bit() ? reinterpret_cast<uintptr_t>(view.span8().data()) : reinterpret_cast<uintptr_t>(view.span16().data());
    uintptr_t argumentStart = argument.is8Bit() ? reinterpret_cast<uintptr_t>(argument.span8().data()) : reinterpret_cast<uintptr_t>(argument.span16().data());
    if (viewStart < argumentStart)
        return notInArgument;
    uint64_t offset = (viewStart - argumentStart) / (view.is8Bit() ? 1 : 2);
    return offset + view.length() <= argument.length() ? offset : notInArgument;
}

template<typename Sink> void addView(Sink& sink, StringView view, StringView argument)
{
    sink.addString(view);
    sink.addInteger(viewOffset(view, argument));
}

// A hash map's iteration order is not part of a parser's output: each entry is folded on its own, and the sum taken.
template<typename Sink, typename Map, typename Function> void addUnordered(Sink& sink, const Map& map, const Function& addEntry)
{
    uint64_t sum = 0;
    for (auto& entry : map) {
        Sink entrySink;
        addEntry(entrySink, entry);
        sum += entrySink.value();
    }
    sink.addInteger(map.size());
    sink.addInteger(sum);
}

inline std::optional<WebCore::HTTPHeaderName> headerNameFor(const String& name)
{
    WebCore::HTTPHeaderMap map;
    map.set(name, WTF::emptyString());
    auto iterator = map.begin();
    if (iterator == map.end())
        return std::nullopt;
    return iterator->keyAsHTTPHeaderName;
}

template<typename Sink> void addReferrerPolicy(Sink& sink, std::optional<WebCore::ReferrerPolicy> policy)
{
    sink.addBoolean(!!policy);
    if (policy)
        sink.addInteger(static_cast<uint64_t>(*policy));
}

// MIMETypes: Content-Type values through ParsedContentType and the media type extractors.

struct MIMETypeInputs {
    Vector<String> values;
    uint64_t bytes { 0 };
};

inline String breakMIMEType(const String& value, Random& random)
{
    switch (random.below(6)) {
    case 0: {
        size_t slash = value.find('/');
        return slash == WTF::notFound ? value : WTF::makeString(StringView(value).left(slash), StringView(value).substring(slash + 1));
    }
    case 1:
        return WTF::makeString("bad type"_s, value);
    case 2:
        return WTF::makeString(value, "; charset=\"unterminated"_s);
    case 3:
        return WTF::makeString('/', value);
    case 4:
        return WTF::makeString(value, "; ch@rset=utf-8; =x; y"_s);
    default:
        return random.chance(50) ? WTF::emptyString() : String("  \t "_s);
    }
}

inline MIMETypeInputs makeMIMETypeInputs()
{
    static constexpr std::array types {
        "text/html"_s, "text/html"_s, "text/plain"_s, "text/css"_s, "text/javascript"_s, "application/javascript"_s,
        "application/json"_s, "application/x-www-form-urlencoded"_s, "multipart/form-data"_s, "multipart/byteranges"_s,
        "image/png"_s, "image/webp"_s, "image/svg+xml"_s, "image/avif"_s, "font/woff2"_s, "video/mp4"_s, "audio/webm"_s,
        "application/octet-stream"_s, "application/ld+json"_s, "text/event-stream"_s, "application/vnd.api+json"_s,
        "application/xhtml+xml"_s, "text/xml"_s, "TEXT/HTML"_s, "Application/JSON"_s, "message/http"_s,
    };
    static constexpr std::array charsets {
        "utf-8"_s, "UTF-8"_s, "utf-8"_s, "\"utf-8\""_s, "iso-8859-1"_s, "windows-1252"_s, "'utf-8'"_s, "Shift_JIS"_s, "us-ascii"_s,
    };
    static constexpr std::array separators { "; "_s, "; "_s, ";"_s, " ; "_s, ";\t"_s };
    static constexpr std::array parameters {
        "boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"_s, "boundary=3d6b6a416f9b5"_s, "codecs=\"avc1.42E01E, mp4a.40.2\""_s,
        "codecs=opus"_s, "profile=\"https://www.w3.org/ns/activitystreams\""_s, "q=0.9"_s, "version=2"_s, "format=flowed"_s,
        "name=\"a \\\"quoted\\\" value\""_s, "x-unused"_s, "Boundary=\"Mixed-Case\""_s, "msgtype=request"_s, "charset=utf-8"_s,
    };
    static constexpr std::array edgeCases {
        ""_s, "   "_s, "\t"_s, "text/html"_s, "  text/html  ; charset = utf-8"_s, "TEXT/HTML; CHARSET=UTF-8"_s,
        "text/html, text/plain"_s, "text/html;charset=utf-8;charset=iso-8859-1"_s, "text/html; charset"_s,
        "text/html;; charset=utf-8"_s, "text/html; charset=\"unterminated"_s, "text/html; foo=\"bar\\\\baz\"; "_s,
        "text/html; charset=utf-8 ; "_s, "text/"_s, "/html"_s, "text"_s, "te xt/html"_s, "text/html; ch@rset=utf-8"_s,
        "x-charset=utf-8"_s, "text/plain; xcharset=foo; charset=bar"_s, "text/plain;charset =utf-8"_s,
        "text/plain; charset='utf-8'"_s, "charset=utf-8"_s, "text/html; foo=bar\tbaz"_s,
        "application/json; charset=utf-8, text/plain"_s, "text/html;charset=\"utf-8\"; boundary=\"a\\\"b\""_s,
        "multipart/form-data; boundary=\"\""_s, "text/html; =value"_s, "text/html; charset=\x01utf-8"_s, "text/html\x7f"_s,
        "text/html; a=\"\\"_s, "text/html; charset=\"utf-8\" trailing"_s, "text/html ;charset=utf-8"_s, "*/*"_s,
        "text/html; CHARSET=\"Big5\"; charset=gbk"_s, "text/plain;charset=\"x\"y\""_s,
    };

    MIMETypeInputs inputs;
    for (auto& edgeCase : edgeCases)
        inputs.values.append(edgeCase);
    inputs.values.append(String::fromLatin1("text/plain; charset=iso-8859-1; title=caf\xE9"));
    inputs.values.append(String::fromLatin1("text/html; charset=\xE9t\xE9"));
    inputs.values.append(wideString(u"text/html; title=\u0130stanbul"));
    inputs.values.append(wideString(u"text/html; charset=utf\u20118"));
    inputs.values.append(wideString(u"text\u012Fhtml; charset=utf-8"));
    inputs.values.append(wideString(u"text/html\u013B charset=utf-8"));
    inputs.values.append(wideString(u"text/html; charset\u013Dutf-8"));
    inputs.values.append(wideString(u"text/html; name=\"\u0122quoted\u0122\""));
    inputs.values.append(wideString(u"\u3000text/html"));
    inputs.values.append(wideString(u"text/html; charset=\"\u00E9t\u00E9\""));
    inputs.values.append(wideString(u"application/json; charset=utf-8; x=\u65E5\u672C"));
    inputs.values.append(wideString(u"text/html\u012C text/plain"));

    Random random { 0x4D494D4554595045ULL };
    for (unsigned i = 0; i < 2400; ++i) {
        WTF::StringBuilder builder;
        if (random.chance(4))
            builder.append("  "_s);
        builder.append(random.pick(types));
        unsigned parameterCount = random.below(4);
        for (unsigned j = 0; j < parameterCount; ++j) {
            builder.append(random.pick(separators));
            if (!j && random.chance(70)) {
                builder.append("charset="_s);
                builder.append(random.pick(charsets));
            } else
                builder.append(random.pick(parameters));
        }
        if (random.chance(3))
            builder.append(", text/plain"_s);
        String value = builder.toString();
        if (random.chance(6))
            value = breakMIMEType(value, random);
        if (random.chance(35))
            value = copyAs16Bit(value);
        inputs.values.append(WTF::move(value));
    }
    for (auto& value : inputs.values)
        inputs.bytes += byteSize(value);
    return inputs;
}

template<typename Sink> void runMIMETypesPass(const MIMETypeInputs& inputs, Sink& sink)
{
    unsigned index = 0;
    for (auto& value : inputs.values) {
        auto parsed = WebCore::ParsedContentType::create(value);
        sink.addBoolean(!!parsed);
        if (parsed) {
            sink.addString(parsed->mimeType());
            sink.addString(parsed->parameterValueForName("charset"_s));
            sink.addString(parsed->serialize());
        }
        if (!(index++ % 4))
            sink.addBoolean(WebCore::isValidContentType(value));
        sink.addString(WebCore::extractMIMETypeFromMediaType(value));
        addView(sink, WebCore::extractCharsetFromMediaType(value), value);
    }
}

// RequestHeaderChecks: Fetch's guards and the request header checks over the header lists of typical requests.

struct RequestHeader {
    String name;
    String value;
    std::optional<WebCore::HTTPHeaderName> headerName;
};

struct Request {
    String method;
    Vector<RequestHeader> headers;
};

struct RequestHeaderInputs {
    Vector<Request> requests;
    uint64_t bytes { 0 };
};

inline RequestHeaderInputs makeRequestHeaderInputs()
{
    static constexpr std::array methods {
        "GET"_s, "GET"_s, "GET"_s, "POST"_s, "POST"_s, "PUT"_s, "DELETE"_s, "PATCH"_s, "OPTIONS"_s, "HEAD"_s, "get"_s, "post"_s,
        "Put"_s, "delete"_s, "CONNECT"_s, "TRACE"_s, "TRACK"_s, "connect"_s, "trace"_s, "PROPFIND"_s, "M-SEARCH"_s, ""_s, "GE T"_s,
    };
    static constexpr std::array accepts {
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"_s, "*/*"_s, "application/json, text/plain, */*"_s,
        "image/webp,image/avif,image/*,*/*;q=0.8"_s, "text/css,*/*;q=0.1"_s, "application/json"_s, "text/html\""_s,
        "application/signed-exchange;v=b3;q=0.7,*/*;q=0.8"_s, "text/event-stream"_s, "audio/*; q=0.2, audio/basic"_s,
    };
    static constexpr std::array languages {
        "en-US,en;q=0.9"_s, "de-DE,de;q=0.9,en;q=0.8"_s, "fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7, *;q=0.5"_s, "en"_s, "ja"_s,
        "en_US"_s, "zh-Hant-TW"_s, ""_s,
    };
    static constexpr std::array contentTypes {
        "application/json"_s, "text/plain;charset=UTF-8"_s, "application/x-www-form-urlencoded"_s,
        "multipart/form-data; boundary=----WebKitFormBoundaryABC123"_s, "text/plain; charset=\"utf-8\""_s,
        "application/x-www-form-urlencoded;charset=UTF-8"_s, "text/plain; charset=utf-8; foo=(bar)"_s, "TEXT/PLAIN"_s,
        "application/csp-report"_s, "text/plain;"_s, "text/html"_s,
    };
    static constexpr std::array ranges {
        "bytes=0-1023"_s, "bytes=1024-"_s, "bytes=-500"_s, "bytes = 0-10"_s, "bytes=0-1,5-10"_s, "bytes=0-"_s, "items=0-1"_s,
    };
    static constexpr std::array encodings {
        "gzip, deflate, br"_s, "gzip, deflate, br, zstd"_s, "gzip, dcb, *"_s, "br;q=1.0, dcz;q=0.5"_s, "identity"_s,
        "gzip;q=1.0, identity; q=0.5, *;q=0"_s,
    };
    static constexpr std::array connections { "keep-alive"_s, "close"_s, "keep-alive, Upgrade"_s, "Upgrade"_s, " , close"_s };
    static constexpr std::array overrides { "CONNECT"_s, "PUT"_s, "GET, TRACE"_s, "track"_s, "PATCH ,  delete"_s, " connect "_s };
    static constexpr std::array overrideNames { "X-HTTP-Method-Override"_s, "X-Method-Override"_s, "X-HTTP-Method"_s, "x-http-method-override"_s };
    static constexpr std::array forbidden {
        "Proxy-Authorization"_s, "Sec-CH-UA"_s, "Keep-Alive"_s, "Transfer-Encoding"_s, "TE"_s, "Via"_s, "Trailer"_s, "DNT"_s,
        "Expect"_s, "Access-Control-Request-Method"_s, "Access-Control-Request-Headers"_s, "Accept-Charset"_s, "Cookie2"_s,
        "Date"_s, "Host"_s, "Origin"_s, "Set-Cookie"_s, "Set-Cookie2"_s, "proxy-connection"_s, "sec-purpose"_s, "Upgrade"_s,
        "Content-Length"_s, "Referer"_s, "Cookie"_s, "Available-Dictionary"_s,
    };
    static constexpr std::array forbiddenValues {
        "Basic dXNlcjpwYXNzd29yZA=="_s, "\"Chromium\";v=\"124\""_s, "timeout=5, max=100"_s, "chunked"_s, "trailers"_s,
        "1.1 proxy.example"_s, "Expires"_s, "1"_s, "100-continue"_s, "PUT"_s, "content-type,x-custom"_s, "utf-8"_s,
        "$Version=1"_s, "Tue, 15 Nov 1994 08:12:31 GMT"_s, "evil.example"_s, "null"_s, "a=b"_s,
    };
    static constexpr std::array appendable {
        "Forwarded"_s, "X-Forwarded-For"_s, "Want-Digest"_s, "If-None-Match"_s, "If-Match"_s, "Cache-Control"_s, "User-Agent"_s,
        "Content-Language"_s, "Pragma"_s, "X-Custom-Header"_s, "Authorization"_s,
    };
    static constexpr std::array appendableValues {
        "for=192.0.2.60;proto=http;by=203.0.113.43"_s, "203.0.113.195, 70.41.3.18, 150.172.238.178"_s, "sha-256;q=1, sha-512;q=0.5"_s,
        "\"33a64df551425fcc55e4d42a148795d9f25f89d4\""_s, "*"_s, "no-cache"_s, "max-age=0"_s, "en-GB"_s, "no-cache"_s,
        "value with spaces and: colons"_s, "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"_s,
    };
    static constexpr std::array invalidNames { "Bad Header"_s, "X-Colon:Name"_s, ""_s, "X-Paren(s)"_s, "X-Slash/Name"_s, "\x7FName"_s };
    static constexpr std::array invalidValues {
        " leading space"_s, "trailing tab\t"_s, "a\rb"_s, "a\nb"_s, "\t"_s, "x\x01y"_s, "multi\r\n line"_s,
    };

    RequestHeaderInputs inputs;
    Random random { 0x5245515545535453ULL };
    auto addHeader = [&](Request& request, const String& name, const String& value) {
        request.headers.append({ name, value, std::nullopt });
    };
    for (unsigned i = 0; i < 520; ++i) {
        Request request;
        request.method = random.pick(methods);
        unsigned kind = random.below(5);
        auto accept = random.pick(accepts);
        addHeader(request, "Accept"_s, accept);
        if (random.chance(80)) {
            auto language = random.pick(languages);
            addHeader(request, "Accept-Language"_s, language);
        }
        auto encoding = random.pick(encodings);
        addHeader(request, "Accept-Encoding"_s, encoding);
        addHeader(request, "User-Agent"_s, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"_s);
        if (!kind) {
            addHeader(request, "Upgrade-Insecure-Requests"_s, "1"_s);
            addHeader(request, "Sec-Fetch-Dest"_s, "document"_s);
            addHeader(request, "Sec-Fetch-Mode"_s, "navigate"_s);
            addHeader(request, "Sec-Fetch-Site"_s, "none"_s);
            addHeader(request, "Priority"_s, "u=0, i"_s);
            auto session = random.token(24);
            auto analytics = random.token(10);
            addHeader(request, "Cookie"_s, WTF::makeString("session="_s, session, "; theme=dark; _ga=GA1.2."_s, analytics));
        } else if (kind == 1) {
            auto contentType = random.pick(contentTypes);
            addHeader(request, "Content-Type"_s, contentType);
            auto token = random.token(40);
            addHeader(request, "Authorization"_s, WTF::makeString("Bearer "_s, token));
            addHeader(request, "X-Requested-With"_s, "XMLHttpRequest"_s);
            auto csrf = random.token(32);
            addHeader(request, "X-CSRF-Token"_s, csrf);
            addHeader(request, "Origin"_s, "https://app.example.com"_s);
            auto length = random.below(100000);
            addHeader(request, "Content-Length"_s, String::number(length));
        } else if (kind == 2) {
            auto contentType = random.pick(contentTypes);
            addHeader(request, "Content-Type"_s, contentType);
            auto range = random.pick(ranges);
            addHeader(request, "Range"_s, range);
            addHeader(request, "Content-Language"_s, random.chance(50) ? "en"_s : "de-DE, en;q=0.5"_s);
            addHeader(request, "Save-Data"_s, "on"_s);
            if (random.chance(20)) {
                auto padding = random.token(120);
                addHeader(request, "Accept"_s, WTF::makeString("text/plain;q=0.5, "_s, padding));
            }
        } else if (kind == 3) {
            for (unsigned j = 0; j < 3; ++j) {
                auto index = random.below(forbidden.size());
                auto valueIndex = random.below(forbiddenValues.size());
                addHeader(request, forbidden[index], forbiddenValues[valueIndex]);
            }
            auto overrideName = random.pick(overrideNames);
            auto overrideValue = random.pick(overrides);
            addHeader(request, overrideName, overrideValue);
            auto connection = random.pick(connections);
            addHeader(request, "Connection"_s, connection);
        } else {
            for (unsigned j = 0; j < 3; ++j) {
                auto index = random.below(appendable.size());
                auto valueIndex = random.below(appendableValues.size());
                addHeader(request, appendable[index], appendableValues[valueIndex]);
            }
            auto connection = random.pick(connections);
            addHeader(request, "Connection"_s, connection);
        }
        if (random.chance(15)) {
            auto name = random.pick(invalidNames);
            addHeader(request, name, "x"_s);
        }
        if (random.chance(15)) {
            auto value = random.pick(invalidValues);
            addHeader(request, "X-Custom-Header"_s, value);
        }
        if (random.chance(5)) {
            auto first = random.token(4);
            auto second = random.token(4);
            addHeader(request, "X-Nul"_s, WTF::makeString(first, '\0', second));
        }
        if (random.chance(30)) {
            request.method = copyAs16Bit(request.method);
            for (auto& header : request.headers) {
                header.name = copyAs16Bit(header.name);
                header.value = copyAs16Bit(header.value);
            }
            // Characters above U+00FF, where no check assumes Latin-1 (an Accept value does).
            if (random.chance(50)) {
                request.headers.append({ wideString(u"X-Title"), wideString(u"\u65E5\u672C\u8A9E \u0130"), std::nullopt });
                request.headers.append({ wideString(u"Content-Language"), wideString(u"en\u012C de"), std::nullopt });
                request.headers.append({ wideString(u"Content-Type"), wideString(u"text/plain; title=\u0130"), std::nullopt });
                request.headers.append({ wideString(u"X-HTTP-Method-Override"), wideString(u"GET\u012C TRACE"), std::nullopt });
                request.headers.append({ wideString(u"Accept-Encoding"), wideString(u"gzip, dcb\u013B q=1"), std::nullopt });
                request.headers.append({ wideString(u"X-\u0130"), wideString(u"x"), std::nullopt });
            }
        }
        inputs.requests.append(WTF::move(request));
    }
    for (auto& request : inputs.requests) {
        inputs.bytes += byteSize(request.method);
        for (auto& header : request.headers) {
            header.headerName = headerNameFor(header.name);
            inputs.bytes += byteSize(header.name) + byteSize(header.value);
        }
    }
    return inputs;
}

template<typename Sink> void runRequestHeaderChecksPass(const RequestHeaderInputs& inputs, Sink& sink)
{
    for (auto& request : inputs.requests) {
        sink.addBoolean(WebCore::isValidHTTPToken(request.method));
        sink.addBoolean(WebCore::isForbiddenMethod(request.method));
        sink.addString(WebCore::normalizeHTTPMethod(request.method));
        sink.addBoolean(WebCore::isSafeMethod(request.method));
        for (auto& header : request.headers) {
            sink.addBoolean(WebCore::isValidHTTPToken(header.name));
            sink.addBoolean(WebCore::isValidHTTPHeaderValue(header.value));
            sink.addBoolean(WebCore::isForbiddenHeader(header.name, header.value));
            sink.addBoolean(WebCore::isForbiddenHeaderName(header.name));
            sink.addBoolean(WebCore::isNoCORSSafelistedRequestHeaderName(header.name));
            sink.addBoolean(WebCore::isPriviledgedNoCORSRequestHeaderName(header.name));
            sink.addBoolean(WebCore::isSimpleHeader(header.name, header.value));
            if (header.headerName)
                sink.addBoolean(WebCore::isCrossOriginSafeRequestHeader(*header.headerName, header.value));
            sink.addBoolean(WebCore::isForbiddenResponseHeaderName(header.name));
            auto delimiter = WebCore::requestHeaderAppendDelimiter(header.name);
            sink.addString(delimiter ? StringView(*delimiter) : StringView());
            sink.addBoolean(WebCore::isRequestHeaderUnsafeToModify(header.name, header.value));
            auto field = WebCore::HTTPHeaderField::create(String(header.name), String(header.value));
            sink.addBoolean(!!field);
            if (field) {
                sink.addString(field->name());
                sink.addString(field->value());
            }
        }
    }
}

// StructuredFields: RFC 8941 items, lists and dictionaries, from the headers WebCore reads them from, and escapeString.

enum class StructuredFieldKind : uint8_t { Item, List, Dictionary, Escape };

struct StructuredFieldInputs {
    Vector<std::pair<StructuredFieldKind, String>> values;
    uint64_t bytes { 0 };
};

template<typename Sink> void addBareItem(Sink& sink, const RFC8941::BareItem& item)
{
    sink.addInteger(item.index());
    WTF::switchOn(item,
        [&](int64_t value) { sink.addInteger(static_cast<uint64_t>(value)); },
        [&](double value) { sink.addDouble(value); },
        [&](const String& value) { sink.addString(value); },
        [&](const RFC8941::Token& value) { sink.addString(value.string()); },
        [&](const Vector<uint8_t>& value) { sink.addBytes(value.span()); },
        [&](bool value) { sink.addBoolean(value); });
}

template<typename Sink> void addParameters(Sink& sink, const RFC8941::Parameters& parameters)
{
    addUnordered(sink, parameters.map(), [](Sink& entrySink, auto& entry) {
        entrySink.addString(entry.key);
        addBareItem(entrySink, entry.value);
    });
}

template<typename Sink> void addItemOrInnerList(Sink& sink, const RFC8941::ItemOrInnerList& member)
{
    sink.addInteger(member.index());
    WTF::switchOn(member,
        [&](const RFC8941::BareItem& item) {
            addBareItem(sink, item);
        },
        [&](const RFC8941::InnerList& list) {
            sink.addInteger(list.size());
            for (auto& [item, parameters] : list) {
                addBareItem(sink, item);
                addParameters(sink, parameters);
            }
        });
}

inline StructuredFieldInputs makeStructuredFieldInputs()
{
    static constexpr std::array items {
        "same-origin"_s, "same-origin-allow-popups"_s, "unsafe-none"_s, "noopener-allow-popups"_s,
        "same-origin; report-to=\"coop-endpoint\""_s, "same-origin;report-to=\"default\""_s, "require-corp"_s, "credentialless"_s,
        "require-corp; report-to=\"coep\""_s, "unsafe-none; report-to=\"coep-report-only\""_s, "?1"_s, "?0"_s,
        "isolate-and-require-corp"_s, "isolate-and-credentialless; report-to=\"dip\""_s, "\"webtransport-protocol-v1\""_s,
        "42"_s, "-17"_s, "3.141"_s, "-0.5"_s, ":cHJldGVuZCB0aGlzIGlzIGJpbmFyeSBjb250ZW50Lg==:"_s, "::"_s, "*token/with:colon"_s,
        "  same-origin  "_s, "same-origin; report-to=coop"_s, "\"a \\\"quoted\\\" \\\\ string\""_s, "999999999999999"_s,
        "-999999999999.999"_s, "same-origin;a;b=?0;c=1.5;d=:AQID:"_s,
    };
    static constexpr std::array invalidItems {
        ""_s, " "_s, "same-origin;"_s, "same-origin; Report-To=\"x\""_s, "\"unterminated"_s, "\"bad \\q escape\""_s,
        "1234567890123456"_s, "1234567890123.5"_s, "1.2345"_s, "1."_s, "?2"_s, ":not base64!:"_s, "same-origin, unsafe-none"_s,
        "\"\x7F\""_s, "tok@en"_s, "Same-Origin"_s, "-"_s, "(a b)"_s, "\"tab\tinside\""_s, ":YWJj"_s, "same-origin;report-to="_s,
    };
    static constexpr std::array dictionaries {
        "default=\"https://example.com/reports\", csp-endpoint=\"https://example.com/csp-reports\""_s,
        "endpoint-1=\"https://reports.example/main\", endpoint-2=\"https://reports.example/backup\"; a=1"_s,
        "blocked-destinations=(script), endpoints=(integrity-endpoint)"_s,
        "blocked-destinations=(script style), sources=(inline), endpoints=(ep1 ep2)"_s,
        "match=\"/product/*\", match-dest=(\"document\"), id=\"dictionary-12345\", type=raw"_s, "u=1, i"_s, "u=5"_s,
        "a=?0, b, c;foo=bar"_s, "a=(1 2 3);p=?1, b=:aGVsbG8=:"_s, "a=1, a=2"_s, "a=()"_s, "*=1, x.y-z_9=\"v\""_s,
    };
    static constexpr std::array invalidDictionaries {
        "Default=\"x\""_s, "a=1,"_s, "a=(1 2"_s, "a=\"x\" b=\"y\""_s, ",a=1"_s, "a=(1)(2)"_s, "a=1,,b=2"_s, "1a=1"_s,
    };
    static constexpr std::array lists {
        "\"/speculationrules.json\""_s, "\"/rules/prefetch.json\", \"https://cdn.example.com/rules.json\""_s,
        "\"/a.json\", \"/b.json\";x=1, (\"inner\" list)"_s, "sugar, tea, rum"_s, "(1 2), (3 4);q=0.5, 5"_s, "?1, ?0, :AA==:"_s,
    };
    static constexpr std::array invalidLists { "\"/a.json\","_s, "/a.json"_s, "a, , b"_s, "(1 2"_s, "a;"_s };
    static constexpr std::array endpoints {
        "coop-endpoint"_s, "default"_s, "my \"quoted\" \\ endpoint"_s, "webtransport-protocol-v1"_s, "x"_s, ""_s, "tab\there"_s,
    };

    StructuredFieldInputs inputs;
    Random random { 0x5246433839343100ULL };
    for (unsigned i = 0; i < 3200; ++i) {
        unsigned kind = random.below(10);
        std::pair<StructuredFieldKind, String> value;
        if (kind < 4) {
            bool invalid = random.chance(20);
            value = { StructuredFieldKind::Item, invalid ? String(random.pick(invalidItems)) : String(random.pick(items)) };
        } else if (kind < 7) {
            bool invalid = random.chance(20);
            if (invalid)
                value = { StructuredFieldKind::Dictionary, random.pick(invalidDictionaries) };
            else {
                auto path = random.token(8);
                auto id = random.token(6);
                switch (random.below(3)) {
                case 0:
                    value = { StructuredFieldKind::Dictionary, WTF::makeString("default=\"https://reports.example.com/"_s, path, "\", csp-"_s, id, "=\"/csp\", coop=\"https://example.com/coop\""_s) };
                    break;
                case 1:
                    value = { StructuredFieldKind::Dictionary, WTF::makeString("match=\"/assets/"_s, path, "/*\", match-dest=(\"script\" \"style\"), id=\""_s, id, "\", type=raw"_s) };
                    break;
                default:
                    value = { StructuredFieldKind::Dictionary, random.pick(dictionaries) };
                    break;
                }
            }
        } else if (kind < 9) {
            bool invalid = random.chance(20);
            if (invalid)
                value = { StructuredFieldKind::List, random.pick(invalidLists) };
            else if (random.chance(50)) {
                auto path = random.token(10);
                value = { StructuredFieldKind::List, WTF::makeString("\"/speculation/"_s, path, ".json\", \"https://cdn.example.com/rules.json\";tag=1"_s) };
            } else
                value = { StructuredFieldKind::List, random.pick(lists) };
        } else
            value = { StructuredFieldKind::Escape, random.pick(endpoints) };
        if (random.chance(30))
            value.second = copyAs16Bit(value.second);
        inputs.values.append(WTF::move(value));
    }
    inputs.values.append({ StructuredFieldKind::Item, wideString(u"same-origin; report-to=\"\u00E9\"") });
    inputs.values.append({ StructuredFieldKind::Item, wideString(u"same-origin\u013B report-to=\"x\"") });
    inputs.values.append({ StructuredFieldKind::Item, wideString(u"\u0122quoted\u0122") });
    inputs.values.append({ StructuredFieldKind::Dictionary, wideString(u"a\u013D1, b=2") });
    inputs.values.append({ StructuredFieldKind::Dictionary, wideString(u"a=1\u012C b=2") });
    inputs.values.append({ StructuredFieldKind::List, wideString(u"\u0128a b), c") });
    inputs.values.append({ StructuredFieldKind::List, wideString(u"\"\u65E5\u672C\", x") });
    inputs.values.append({ StructuredFieldKind::Escape, wideString(u"endpoint-\u00E9") });
    inputs.values.append({ StructuredFieldKind::Escape, wideString(u"endpoint\u0122") });
    inputs.values.append({ StructuredFieldKind::Escape, String::fromLatin1("caf\xE9") });
    for (auto& value : inputs.values)
        inputs.bytes += byteSize(value.second);
    return inputs;
}

template<typename Sink> void runStructuredFieldsPass(const StructuredFieldInputs& inputs, Sink& sink)
{
    for (auto& [kind, value] : inputs.values) {
        switch (kind) {
        case StructuredFieldKind::Item: {
            auto item = RFC8941::parseItemStructuredFieldValue(value);
            sink.addBoolean(!!item);
            if (item) {
                addBareItem(sink, item->first);
                addParameters(sink, item->second);
            }
            break;
        }
        case StructuredFieldKind::List: {
            auto list = RFC8941::parseListStructuredFieldValue(value);
            sink.addBoolean(!!list);
            if (list) {
                sink.addInteger(list->size());
                for (auto& [member, parameters] : *list) {
                    addItemOrInnerList(sink, member);
                    addParameters(sink, parameters);
                }
            }
            break;
        }
        case StructuredFieldKind::Dictionary: {
            auto dictionary = RFC8941::parseDictionaryStructuredFieldValue(value);
            sink.addBoolean(!!dictionary);
            if (dictionary) {
                addUnordered(sink, *dictionary, [](Sink& entrySink, auto& entry) {
                    entrySink.addString(entry.key);
                    addItemOrInnerList(entrySink, entry.value.first);
                    addParameters(entrySink, entry.value.second);
                });
            }
            break;
        }
        case StructuredFieldKind::Escape: {
            auto escaped = RFC8941::escapeString(value);
            sink.addBoolean(!!escaped);
            if (escaped)
                sink.addString(*escaped);
            break;
        }
        }
    }
}

// LinkHeaders: preload-heavy Link headers, and each link's referrer policy as the link loader reads it.

struct LinkHeaderInputs {
    Vector<String> values;
    uint64_t bytes { 0 };
};

inline LinkHeaderInputs makeLinkHeaderInputs()
{
    static constexpr std::array links {
        "</static/css/main.css>; rel=preload; as=style"_s, "</static/js/runtime.js>; rel=preload; as=script"_s,
        "</fonts/inter-var.woff2>; rel=preload; as=font; type=\"font/woff2\"; crossorigin"_s,
        "<https://cdn.example.com>; rel=preconnect"_s, "<https://fonts.gstatic.com>; rel=preconnect; crossorigin=anonymous"_s,
        "</images/hero-1200.avif>; rel=preload; as=image; imagesrcset=\"/images/hero-600.avif 600w, /images/hero-1200.avif 1200w\"; imagesizes=\"(max-width: 600px) 100vw, 50vw\"; fetchpriority=high"_s,
        "</api/data.json>; rel=\"preload\"; as=\"fetch\"; crossorigin=\"use-credentials\"; nonce=\"r4nd0m\"; referrerpolicy=\"no-referrer\""_s,
        "</next-page>; rel=prefetch"_s, "</style.css>; rel=stylesheet; media=\"screen and (min-width: 768px)\""_s,
        "</module.mjs>; rel=modulepreload"_s, "</worker.js>; rel=preload; as=worker; referrerpolicy=strict-origin"_s,
        "<https://example.com/page>; rel=canonical"_s, "<https://example.com/fr/page>; rel=alternate; hreflang=fr"_s,
        "</api/items?page=2>; rel=\"next\""_s, "</app.js>;rel=preload;as=script;fetchpriority=low"_s,
        "<//static.example.net/a.css>; rel=dns-prefetch"_s, "</video.mp4>; rel=preload; as=video; type=video/mp4; media=\"(min-width: 1024px)\""_s,
    };
    static constexpr std::array oddLinks {
        "<url>; rel=preload; anchor=\"#x\""_s, "<url> rel=preload"_s, "url; rel=preload"_s, "<url; rel=preload"_s,
        "<url>; rel=\"unterminated"_s, "<url>; rel=preload; as=script; as=style"_s, "<url>; rel=preload; rel=prefetch"_s,
        "<url>; =value"_s, "<url>; rel==preload"_s, "<url>; title*=UTF-8''%e2%82%ac%20rates"_s, "<url>; crossorigin; rel=preload"_s,
        "<url>; rel='single'"_s, "<url>; rel=preload; foo=\"bar\\\"baz\""_s, ""_s, "<url>; rel=preload; referrerpolicy=never"_s,
        "<url>; rel=preload; referrerpolicy=\"\""_s, "< spaced url >; rel=preload"_s, "<url>; rel=pre load"_s, "<url>;"_s,
        "<url>; rel=preload; nonce"_s, "<url>; rel=preload; as"_s, "<a>, <b>"_s,
    };
    static constexpr std::array separators { ", "_s, ","_s, " , "_s, ",\t"_s };

    LinkHeaderInputs inputs;
    Random random { 0x4C494E4B48445253ULL };
    for (unsigned i = 0; i < 900; ++i) {
        WTF::StringBuilder builder;
        unsigned count = 1 + random.below(10);
        for (unsigned j = 0; j < count; ++j) {
            if (j)
                builder.append(random.pick(separators));
            if (random.chance(10))
                builder.append(random.pick(oddLinks));
            else if (random.chance(30)) {
                auto hash = random.token(8);
                builder.append("</assets/chunk-"_s, hash, ".js>; rel=preload; as=script; crossorigin"_s);
            } else
                builder.append(random.pick(links));
        }
        String value = builder.toString();
        if (random.chance(30))
            value = copyAs16Bit(value);
        inputs.values.append(WTF::move(value));
    }
    inputs.values.append(String::fromLatin1("</caf\xE9.css>; rel=preload; as=style; title=\"\xE9t\xE9\""));
    inputs.values.append(wideString(u"</caf\u00E9.css>; rel=preload; as=style"));
    inputs.values.append(wideString(u"</\u65E5\u672C.js>; rel=preload; as=script, </b.css>; rel=preload; as=style"));
    inputs.values.append(wideString(u"</a.css>\u013B rel=preload"));
    inputs.values.append(wideString(u"</a.css>; rel\u013Dpreload"));
    inputs.values.append(wideString(u"</a.css>; rel=preload\u012C </b.css>; rel=preload"));
    inputs.values.append(wideString(u"</a.css>; rel=\"pre\u0122load\"; as=style"));
    for (auto& value : inputs.values)
        inputs.bytes += byteSize(value);
    return inputs;
}

template<typename Sink> void runLinkHeadersPass(const LinkHeaderInputs& inputs, Sink& sink)
{
    for (auto& value : inputs.values) {
        WebCore::LinkHeaderSet set(value);
        uint64_t count = 0;
        for (auto& link : set) {
            ++count;
            sink.addBoolean(link.valid());
            sink.addString(link.url());
            sink.addString(link.rel());
            sink.addString(link.as());
            sink.addString(link.mimeType());
            sink.addString(link.media());
            sink.addString(link.crossOrigin());
            sink.addString(link.imageSrcSet());
            sink.addString(link.imageSizes());
            sink.addString(link.nonce());
            sink.addString(link.referrerPolicy());
            sink.addString(link.fetchPriority());
            addReferrerPolicy(sink, WebCore::parseReferrerPolicy(link.referrerPolicy(), WebCore::ReferrerPolicySource::ReferrerPolicyAttribute));
        }
        sink.addInteger(count);
    }
}

// CacheControl: parseCacheControlDirectives over the header maps of typical responses.

struct CacheControlInputs {
    Vector<WebCore::HTTPHeaderMap> maps;
    uint64_t bytes { 0 };
};

template<typename Sink> void addSeconds(Sink& sink, const WTF::Markable<WTF::Seconds>& seconds)
{
    sink.addBoolean(!!seconds);
    if (seconds)
        sink.addDouble(seconds->value());
}

template<typename Sink> void addCacheControlDirectives(Sink& sink, const WebCore::CacheControlDirectives& directives)
{
    addSeconds(sink, directives.maxAge);
    addSeconds(sink, directives.maxStale);
    addSeconds(sink, directives.minFresh);
    addSeconds(sink, directives.staleWhileRevalidate);
    sink.addBoolean(directives.noCache);
    sink.addBoolean(directives.noStore);
    sink.addBoolean(directives.mustRevalidate);
    sink.addBoolean(directives.immutable);
    sink.addBoolean(directives.isPublic);
}

inline CacheControlInputs makeCacheControlInputs()
{
    static constexpr std::array cacheControls {
        "max-age=31536000, immutable"_s, "public, max-age=3600"_s, "private, max-age=0, no-cache"_s,
        "no-cache, no-store, must-revalidate"_s, "no-store"_s, "max-age=600, stale-while-revalidate=30"_s,
        "public, max-age=86400, stale-while-revalidate=604800, stale-if-error=86400"_s, "max-age=0, must-revalidate"_s,
        "s-maxage=300, max-age=60"_s, "max-stale, min-fresh=60"_s, "max-stale=120"_s, "no-cache=\"Set-Cookie, Set-Cookie2\""_s,
        "private=\"x-user\", max-age=10"_s, "max-age=\"3600\""_s, "max-age=abc"_s, "max-age=60, max-age=120"_s,
        "MAX-AGE=10, Public"_s, "max-age = 60"_s, "max-age=1e3"_s, "max-age=-1"_s, ",,max-age=5,,"_s, "\"unterminated"_s,
        "max-age=60; foo"_s, "no-transform, proxy-revalidate"_s, "immutable"_s, "max-age=3600\t, public"_s,
        "public, max-age=31536000"_s, "max-age=2592000"_s, "no-cache"_s, "must-revalidate, max-age=0, stale-while-revalidate"_s,
        "max-age=60, min-fresh=x, min-fresh=5, max-stale=\"7\""_s, "stale-while-revalidate=1.5, stale-while-revalidate=9"_s,
        "max-age=0x10"_s, "max-age=100000000000000000000"_s, "no-cache=, no-store=\"\""_s, "max-age=5,=6,max-stale="_s,
    };
    static constexpr std::array pragmas { "no-cache"_s, "No-Cache"_s, "foo, no-cache"_s, "x-no-cachex"_s, ""_s };
    static constexpr std::array otherHeaders {
        std::pair { "Content-Type"_s, "text/html; charset=utf-8"_s }, std::pair { "Date"_s, "Sun, 08 Nov 2026 23:12:40 GMT"_s },
        std::pair { "ETag"_s, "\"5f2b-1a2b3c\""_s }, std::pair { "Vary"_s, "Accept-Encoding"_s }, std::pair { "Age"_s, "120"_s },
        std::pair { "Content-Length"_s, "18734"_s }, std::pair { "Server"_s, "nginx"_s }, std::pair { "X-Cache"_s, "HIT"_s },
        std::pair { "Last-Modified"_s, "Wed, 21 Oct 2026 07:28:00 GMT"_s }, std::pair { "Expires"_s, "Thu, 01 Dec 2026 16:00:00 GMT"_s },
    };

    CacheControlInputs inputs;
    Random random { 0x4341434845435452ULL };
    for (unsigned i = 0; i < 3600; ++i) {
        WebCore::HTTPHeaderMap map;
        bool wide = random.chance(30);
        unsigned others = 2 + random.below(5);
        for (unsigned j = 0; j < others; ++j) {
            auto& [name, value] = random.pick(otherHeaders);
            map.set(name, value);
        }
        if (random.chance(90)) {
            String value;
            if (random.chance(25)) {
                auto maxAge = random.below(1000000);
                auto staleWhileRevalidate = random.below(1000);
                value = WTF::makeString("public, max-age="_s, maxAge, ", stale-while-revalidate="_s, staleWhileRevalidate);
            } else
                value = random.pick(cacheControls);
            if (wide)
                value = copyAs16Bit(value);
            inputs.bytes += byteSize(value);
            map.set("Cache-Control"_s, value);
        }
        if (random.chance(15)) {
            String value = random.pick(pragmas);
            if (wide)
                value = copyAs16Bit(value);
            inputs.bytes += byteSize(value);
            map.set("Pragma"_s, value);
        }
        inputs.maps.append(WTF::move(map));
    }
    for (auto& value : { wideString(u"max-age=60\u012C public"), wideString(u"max-age\u013D60"), wideString(u"no-cache\u3000"), wideString(u"max-age=\uFF16\uFF10"), wideString(u"no-store, max-age=\u0661") }) {
        WebCore::HTTPHeaderMap map;
        inputs.bytes += byteSize(value);
        map.set("Cache-Control"_s, value);
        inputs.maps.append(WTF::move(map));
    }
    return inputs;
}

template<typename Sink> void runCacheControlPass(const CacheControlInputs& inputs, Sink& sink)
{
    for (auto& map : inputs.maps)
        addCacheControlDirectives(sink, WebCore::parseCacheControlDirectives(map));
}

// RangesAndLengths: Range in both whitespace modes, Content-Range from strings and from values, and Content-Length.

enum class RangeKind : uint8_t { Range, ContentRange, ContentLength };

struct RangeInputs {
    Vector<std::pair<RangeKind, String>> values;
    Vector<std::array<int64_t, 3>> contentRanges;
    uint64_t bytes { 0 };
};

inline RangeInputs makeRangeInputs()
{
    static constexpr std::array ranges {
        "bytes=0-"_s, "bytes=0-1023"_s, "bytes=1024-2047"_s, "bytes=-500"_s, "bytes=500-"_s, "bytes=0-0"_s, "bytes= 0 - 1023"_s,
        "bytes =0-1023"_s, "bytes=\t100-200"_s, "bytes=200-100"_s, "bytes=-"_s, "bytes=18446744073709551615-18446744073709551615"_s,
        "bytes=18446744073709551616-"_s, "bytes=0-1023,2048-4095"_s, "Bytes=0-1"_s, "bytes:0-1"_s, "bytes=1-2x"_s, "bytes=abc"_s,
        "items=0-10"_s, ""_s, "bytes=00000000000000000000000001-2"_s, "bytes=1 -2"_s, "bytes=-0"_s, "bytes"_s, "bytes="_s,
    };
    static constexpr std::array contentRanges {
        "bytes 0-1023/4096"_s, "bytes 1024-2047/4096"_s, "bytes 0-0/1"_s, "bytes 100-199/*"_s, "bytes 0-1023/1024"_s,
        "bytes 0-1024/1024"_s, "bytes 200-100/1000"_s, "bytes */1000"_s, "bytes -1-10/100"_s, "bytes 0-9223372036854775807/*"_s,
        "bytes 0-9223372036854775808/*"_s, "bytes 1-2/3/4"_s, "Bytes 0-1/2"_s, "bytes  0-1/2"_s, "bytes 0-1/"_s, "bytes 5-10/abc"_s,
        "bytes 5-10/9223372036854775807"_s, "bytes 1-2"_s, ""_s, "bytes 01-02/03"_s, "bytes 0-1/+5"_s,
    };
    static constexpr std::array contentLengths {
        "0"_s, "1024"_s, "348573"_s, "  1024"_s, "1024, 1024"_s, "1024,1024,1024"_s, "1024, 2048"_s, "abc, 1024"_s, "1024, abc"_s,
        "-1"_s, "18446744073709551615"_s, "18446744073709551616"_s, "+5"_s, ",,5"_s, ""_s, "5 "_s, "5,"_s, "0x10"_s,
    };

    RangeInputs inputs;
    Random random { 0x52414E4745534C4EULL };
    for (unsigned i = 0; i < 6000; ++i) {
        unsigned kind = random.below(3);
        std::pair<RangeKind, String> value;
        bool generated = random.chance(50);
        if (!kind) {
            if (generated) {
                auto start = random.below(1u << 30);
                auto length = random.below(1u << 20);
                value = { RangeKind::Range, random.chance(20) ? WTF::makeString("bytes="_s, start, '-') : WTF::makeString("bytes="_s, start, '-', start + length) };
            } else
                value = { RangeKind::Range, random.pick(ranges) };
        } else if (kind == 1) {
            if (generated) {
                auto start = random.below(1u << 30);
                auto length = random.below(1u << 20);
                auto total = random.below(1u << 31);
                value = { RangeKind::ContentRange, WTF::makeString("bytes "_s, start, '-', start + length, '/', total) };
            } else
                value = { RangeKind::ContentRange, random.pick(contentRanges) };
        } else {
            if (generated) {
                auto length = random.next() % 100000000000ULL;
                value = { RangeKind::ContentLength, random.chance(10) ? WTF::makeString(length, ", "_s, length) : String::number(length) };
            } else
                value = { RangeKind::ContentLength, random.pick(contentLengths) };
        }
        if (random.chance(30))
            value.second = copyAs16Bit(value.second);
        inputs.values.append(WTF::move(value));
    }
    inputs.values.append({ RangeKind::Range, wideString(u"bytes=0\u20131023") });
    inputs.values.append({ RangeKind::Range, wideString(u"bytes=\uFF11-2") });
    inputs.values.append({ RangeKind::Range, wideString(u"bytes\u013D0-1") });
    inputs.values.append({ RangeKind::Range, wideString(u"bytes=0\u012D1") });
    inputs.values.append({ RangeKind::ContentRange, wideString(u"bytes 0\u012D1/2") });
    inputs.values.append({ RangeKind::ContentRange, wideString(u"bytes 0-1\u012F2") });
    inputs.values.append({ RangeKind::ContentLength, wideString(u"10\u012C 10") });
    inputs.values.append({ RangeKind::ContentLength, wideString(u"\u0661\u0662") });

    constexpr int64_t maximum = std::numeric_limits<int64_t>::max();
    constexpr int64_t unknown = WebCore::ParsedContentRange::unknownLength;
    static constexpr std::array<std::array<int64_t, 3>, 10> valueTriples { {
        { 0, 1023, 4096 }, { 0, 0, 1 }, { 100, 50, 200 }, { -1, 10, 100 }, { 0, 99, unknown }, { 0, 100, 100 },
        { maximum - 1, maximum - 1, maximum }, { 5, 5, 6 }, { 0, -1, 10 }, { 1 << 20, (1 << 21) - 1, 1 << 30 },
    } };
    for (unsigned i = 0; i < 400; ++i) {
        auto& triple = random.pick(valueTriples);
        inputs.contentRanges.append(triple);
    }
    for (auto& value : inputs.values)
        inputs.bytes += byteSize(value.second);
    inputs.bytes += inputs.contentRanges.size() * sizeof(std::array<int64_t, 3>);
    return inputs;
}

template<typename Sink> void addContentRange(Sink& sink, const WebCore::ParsedContentRange& range)
{
    sink.addBoolean(range.isValid());
    sink.addInteger(static_cast<uint64_t>(range.firstBytePosition()));
    sink.addInteger(static_cast<uint64_t>(range.lastBytePosition()));
    sink.addInteger(static_cast<uint64_t>(range.instanceLength()));
    sink.addString(range.headerValue());
}

template<typename Sink> void addRange(Sink& sink, const std::optional<WebCore::HTTPRange>& range)
{
    sink.addBoolean(!!range);
    if (!range)
        return;
    sink.addBoolean(!!range->start);
    sink.addInteger(range->start.value_or(0));
    sink.addBoolean(!!range->end);
    sink.addInteger(range->end.value_or(0));
}

template<typename Sink> void runRangesAndLengthsPass(const RangeInputs& inputs, Sink& sink)
{
    for (auto& [kind, value] : inputs.values) {
        switch (kind) {
        case RangeKind::Range:
            addRange(sink, WebCore::parseRange(value, WebCore::RangeAllowWhitespace::No));
            addRange(sink, WebCore::parseRange(value, WebCore::RangeAllowWhitespace::Yes));
            break;
        case RangeKind::ContentRange:
            addContentRange(sink, WebCore::ParsedContentRange(value));
            break;
        case RangeKind::ContentLength: {
            auto length = WebCore::parseContentLength(value);
            sink.addBoolean(!!length);
            sink.addInteger(length.value_or(0));
            break;
        }
        }
    }
    for (auto& [first, last, instance] : inputs.contentRanges)
        addContentRange(sink, WebCore::ParsedContentRange(first, last, instance));
}

// HeaderLines: parseHTTPHeader over the header blocks of WebSocket handshake responses, strict as the handshake reads
// them and lenient as a multipart part's headers are read.

struct HeaderLineInputs {
    Vector<uint8_t> data;
    Vector<std::pair<size_t, size_t>> blocks;
};

inline HeaderLineInputs makeHeaderLineInputs()
{
    static constexpr std::array lines {
        "Upgrade: websocket"_s, "Connection: Upgrade"_s, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="_s,
        "Sec-WebSocket-Protocol: chat, superchat"_s, "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits=15"_s,
        "Server: nginx/1.25.3"_s, "Date: Sun, 08 Nov 2026 23:12:40 GMT"_s,
        "Set-Cookie: session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax"_s, "Via: 1.1 varnish"_s, "X-Empty:"_s,
        "X-Spaces:      padded value"_s, "Content-Type: multipart/mixed; boundary=frontier"_s, "x-lower-case: value"_s,
        "Strict-Transport-Security: max-age=63072000; includeSubDomains; preload"_s, "X-Colon: a:b:c"_s, "X-Tab:\tvalue"_s,
    };
    static constexpr std::array badLines {
        "Bad Header: value"_s, "Name\rValue: x"_s, "Name\nValue: x"_s, "\rX"_s, "Value-With-LF: abc\ndef"_s, "@start: x"_s,
        "Header: value\rX"_s, "(paren): x"_s, ":no-name"_s, "Name: value\r"_s,
    };

    static constexpr std::array<uint8_t, 2> eAcute { 0xC3, 0xA9 };
    static constexpr std::array<uint8_t, 3> checkMark { 0xE2, 0x9C, 0x93 };
    static constexpr std::array<uint8_t, 3> invalidUTF8 { 0xFF, 0xFE, 0x41 };

    HeaderLineInputs inputs;
    Random random { 0x4844524C494E4553ULL };
    auto appendLiteral = [&](ASCIILiteral literal) {
        inputs.data.append(literal.span8());
    };
    auto appendString = [&](const String& string) {
        auto utf8 = string.utf8();
        inputs.data.append(utf8.span());
    };
    for (unsigned i = 0; i < 420; ++i) {
        size_t start = inputs.data.size();
        bool bareLineFeeds = random.chance(10);
        auto lineEnd = bareLineFeeds ? "\n"_s : "\r\n"_s;
        unsigned count = 3 + random.below(8);
        for (unsigned j = 0; j < count; ++j) {
            unsigned kind = random.below(10);
            if (kind < 8)
                appendLiteral(random.pick(lines));
            else if (kind == 8) {
                auto key = random.token(27);
                appendLiteral("Sec-WebSocket-Accept: "_s);
                appendString(key);
                appendLiteral("="_s);
            } else {
                appendLiteral("X-Utf8: caf"_s);
                inputs.data.append(std::span { eAcute });
                appendLiteral(" "_s);
                inputs.data.append(std::span { checkMark });
            }
            appendLiteral(lineEnd);
        }
        // A line that fails ends its block, so it comes last.
        if (random.chance(25)) {
            unsigned kind = random.below(4);
            if (!kind) {
                appendLiteral("X-Invalid-Utf8: "_s);
                inputs.data.append(std::span { invalidUTF8 });
            } else if (kind == 1) {
                auto name = random.token(140 + random.below(60));
                appendString(name);
                appendLiteral("\x01: x"_s);
            } else
                appendLiteral(random.pick(badLines));
            appendLiteral(lineEnd);
        }
        if (random.chance(95))
            appendLiteral(lineEnd);
        inputs.blocks.append({ start, inputs.data.size() - start });
    }
    return inputs;
}

template<typename Sink> void parseHeaderBlock(std::span<const uint8_t> block, bool strict, Sink& sink)
{
    size_t position = 0;
    while (position < block.size()) {
        String failureReason;
        StringView name;
        String value;
        size_t consumed = WebCore::parseHTTPHeader(block.subspan(position), failureReason, name, value, strict);
        sink.addInteger(consumed);
        sink.addString(failureReason);
        sink.addString(name);
        sink.addInteger(name.isEmpty() || !name.is8Bit() ? 0 : reinterpret_cast<uintptr_t>(name.span8().data()) - reinterpret_cast<uintptr_t>(block.data()));
        sink.addString(value);
        if (!consumed)
            return;
        position += consumed;
        if (name.isEmpty())
            return;
        // Both callers step over the character the returned length points at.
        ++position;
    }
}

template<typename Sink> void runHeaderLinesPass(const HeaderLineInputs& inputs, Sink& sink)
{
    auto data = inputs.data.span();
    for (auto [offset, length] : inputs.blocks) {
        auto block = data.subspan(offset, length);
        parseHeaderBlock(block, true, sink);
        parseHeaderBlock(block, false, sink);
    }
}

// ServerTiming: Server-Timing values, which are always 8-bit.

struct ServerTimingInputs {
    Vector<String> values;
    uint64_t bytes { 0 };
};

inline ServerTimingInputs makeServerTimingInputs()
{
    static constexpr std::array metrics {
        "cache;desc=\"Cache Read\";dur=23.2"_s, "db;dur=53"_s, "app;dur=47.2"_s, "miss"_s, "total;dur=123.4;desc=\"Total time\""_s,
        "cdn-cache;desc=HIT"_s, "edge;dur=4"_s, "cfRequestDuration;dur=21.000052"_s, "origin; dur=110"_s,
        "edge; dur=12; desc=\"edge server\""_s, "sql-1;desc=\"SELECT * FROM users\";dur=12.5"_s, "fastly-cdn;desc=\"Fastly\""_s,
        "render;dur=8.25"_s, "auth;dur=0.4;desc=\"token check\""_s,
    };
    static constexpr std::array oddMetrics {
        "\"quoted-name\";dur=1"_s, "metric;dur=abc"_s, "metric;dur=1;dur=2"_s, "metric;desc=\"a\";desc=\"b\""_s,
        "metric;desc=\"esc\\\"aped\\\\\""_s, "metric;DUR=5;DESC=upper"_s, "metric;dur"_s, "metric;dur="_s, "metric;=5"_s,
        "metric;dur=1 extra garbage"_s, "metric;desc=\"unterminated"_s, ""_s, "metric;dur=1e3"_s, "metric;dur=-0.0"_s,
        "metric;dur=NaN"_s, "metric;dur=Infinity"_s, "metric ; dur = 7 ; desc = \"spaced\""_s, "metric;dur=\"5\""_s,
        "metric;desc=\"trailing backslash\\"_s, "metric;foo=bar;dur=3"_s, "metric;dur=.5"_s, "met@ric;dur=1"_s,
    };
    static constexpr std::array separators { ", "_s, ","_s, " , "_s };

    ServerTimingInputs inputs;
    Random random { 0x5345525654494D45ULL };
    for (unsigned i = 0; i < 2800; ++i) {
        WTF::StringBuilder builder;
        unsigned count = 1 + random.below(6);
        for (unsigned j = 0; j < count; ++j) {
            if (j)
                builder.append(random.pick(separators));
            if (random.chance(12))
                builder.append(random.pick(oddMetrics));
            else if (random.chance(25)) {
                auto name = random.token(6);
                auto whole = random.below(1000);
                auto fraction = random.below(1000);
                builder.append(name, ";dur="_s, whole, '.', fraction);
            } else
                builder.append(random.pick(metrics));
        }
        inputs.values.append(builder.toString());
    }
    inputs.values.append(", leading-comma"_s);
    inputs.values.append("metric,,other"_s);
    inputs.values.append(String::fromLatin1("x;desc=caf\xE9;dur=1"));
    inputs.values.append(String::fromLatin1("caf\xE9;dur=1"));
    for (auto& value : inputs.values)
        inputs.bytes += byteSize(value);
    return inputs;
}

template<typename Sink> void addServerTimings(Sink& sink, const Vector<WebCore::ServerTiming>& entries)
{
    sink.addInteger(entries.size());
    for (auto& entry : entries) {
        sink.addString(entry.name);
        sink.addDouble(entry.duration);
        sink.addString(entry.description);
        sink.addBoolean(entry.durationSet);
        sink.addBoolean(entry.descriptionSet);
    }
}

template<typename Sink> void runServerTimingPass(const ServerTimingInputs& inputs, Sink& sink)
{
    for (auto& value : inputs.values)
        addServerTimings(sink, WebCore::ServerTimingParser::parseServerTiming(value));
}

// ResponseMix: the headers of realistic responses, each through the parsers the loader applies to it.

struct ResponseHeader {
    String name;
    String value;
    std::optional<WebCore::HTTPHeaderName> headerName;
};

struct Response {
    String statusLine;
    String metaReferrer;
    Vector<ResponseHeader> headers;
    WebCore::ResourceResponse response;
};

struct ResponseMixInputs {
    Vector<Response> responses;
    WebCore::HTTPHeaderSet exposedHeaders;
    uint64_t bytes { 0 };
};

template<typename Sink> void addParsedResponseHeader(Sink& sink, WebCore::HTTPHeaderName name, const String& value)
{
    switch (name) {
    case WebCore::HTTPHeaderName::ContentType:
        sink.addString(WebCore::extractMIMETypeFromMediaType(value));
        addView(sink, WebCore::extractCharsetFromMediaType(value), value);
        break;
    case WebCore::HTTPHeaderName::ContentLength: {
        auto length = WebCore::parseContentLength(value);
        sink.addBoolean(!!length);
        sink.addInteger(length.value_or(0));
        break;
    }
    case WebCore::HTTPHeaderName::Date:
    case WebCore::HTTPHeaderName::Expires:
    case WebCore::HTTPHeaderName::LastModified: {
        auto date = WebCore::parseHTTPDate(value);
        sink.addBoolean(!!date);
        if (date)
            sink.addDouble(date->secondsSinceEpoch().value());
        break;
    }
    case WebCore::HTTPHeaderName::XFrameOptions:
        sink.addInteger(static_cast<uint64_t>(WebCore::parseXFrameOptionsHeader(value)));
        break;
    case WebCore::HTTPHeaderName::XContentTypeOptions:
        sink.addInteger(static_cast<uint64_t>(WebCore::parseContentTypeOptionsHeader(value)));
        break;
    case WebCore::HTTPHeaderName::CrossOriginResourcePolicy:
        sink.addInteger(static_cast<uint64_t>(WebCore::parseCrossOriginResourcePolicyHeader(value)));
        break;
    case WebCore::HTTPHeaderName::CrossOriginOpenerPolicy:
    case WebCore::HTTPHeaderName::CrossOriginOpenerPolicyReportOnly:
    case WebCore::HTTPHeaderName::CrossOriginEmbedderPolicy:
    case WebCore::HTTPHeaderName::CrossOriginEmbedderPolicyReportOnly:
    case WebCore::HTTPHeaderName::OriginAgentCluster:
    case WebCore::HTTPHeaderName::DocumentIsolationPolicy: {
        auto item = RFC8941::parseItemStructuredFieldValue(value);
        sink.addBoolean(!!item);
        if (item) {
            addBareItem(sink, item->first);
            addParameters(sink, item->second);
        }
        break;
    }
    case WebCore::HTTPHeaderName::ReportingEndpoints:
    case WebCore::HTTPHeaderName::IntegrityPolicy:
    case WebCore::HTTPHeaderName::UseAsDictionary: {
        auto dictionary = RFC8941::parseDictionaryStructuredFieldValue(value);
        sink.addBoolean(!!dictionary);
        if (dictionary) {
            addUnordered(sink, *dictionary, [](Sink& entrySink, auto& entry) {
                entrySink.addString(entry.key);
                addItemOrInnerList(entrySink, entry.value.first);
                addParameters(entrySink, entry.value.second);
            });
        }
        break;
    }
    case WebCore::HTTPHeaderName::SpeculationRules: {
        auto list = RFC8941::parseListStructuredFieldValue(value);
        sink.addBoolean(!!list);
        if (list) {
            sink.addInteger(list->size());
            for (auto& [member, parameters] : *list) {
                addItemOrInnerList(sink, member);
                addParameters(sink, parameters);
            }
        }
        break;
    }
    case WebCore::HTTPHeaderName::ReferrerPolicy:
        addReferrerPolicy(sink, WebCore::parseReferrerPolicy(value, WebCore::ReferrerPolicySource::HTTPHeader));
        break;
    case WebCore::HTTPHeaderName::Link: {
        WebCore::LinkHeaderSet set(value);
        uint64_t count = 0;
        for (auto& link : set) {
            ++count;
            sink.addBoolean(link.valid());
            sink.addString(link.url());
            sink.addString(link.rel());
            sink.addString(link.as());
            sink.addString(link.crossOrigin());
            sink.addString(link.fetchPriority());
        }
        sink.addInteger(count);
        break;
    }
    case WebCore::HTTPHeaderName::ServerTiming:
        addServerTimings(sink, WebCore::ServerTimingParser::parseServerTiming(value));
        break;
    case WebCore::HTTPHeaderName::ContentRange:
        addContentRange(sink, WebCore::ParsedContentRange(value));
        break;
    case WebCore::HTTPHeaderName::ContentDisposition:
        addView(sink, WebCore::filenameFromHTTPContentDisposition(value), value);
        break;
    case WebCore::HTTPHeaderName::AccessControlAllowMethods: {
        auto methods = WebCore::parseAccessControlAllowList(value);
        sink.addBoolean(!!methods);
        if (methods)
            addUnordered(sink, *methods, [](Sink& entrySink, auto& method) { entrySink.addString(method); });
        break;
    }
    case WebCore::HTTPHeaderName::AccessControlAllowHeaders:
    case WebCore::HTTPHeaderName::AccessControlExposeHeaders: {
        auto headers = WebCore::parseAccessControlAllowList<WTF::ASCIICaseInsensitiveHash>(value);
        sink.addBoolean(!!headers);
        if (headers)
            addUnordered(sink, *headers, [](Sink& entrySink, auto& header) { entrySink.addString(header); });
        break;
    }
    default:
        break;
    }
}

inline ResponseMixInputs makeResponseMixInputs()
{
    using Headers = Vector<std::pair<ASCIILiteral, ASCIILiteral>>;
    struct Template {
        ASCIILiteral url;
        ASCIILiteral statusLine;
        ASCIILiteral metaReferrer;
        Headers headers;
    };
    const std::array templates {
        Template { "https://www.example.com/"_s, "HTTP/1.1 200 OK"_s, "strict-origin-when-cross-origin"_s, {
            { "Content-Type"_s, "text/html; charset=utf-8"_s }, { "Content-Length"_s, "48213"_s },
            { "Cache-Control"_s, "private, max-age=0, no-cache"_s }, { "Date"_s, "Sun, 08 Nov 2026 23:12:40 GMT"_s },
            { "X-Frame-Options"_s, "SAMEORIGIN"_s }, { "X-Content-Type-Options"_s, "nosniff"_s },
            { "Referrer-Policy"_s, "no-referrer, strict-origin-when-cross-origin"_s },
            { "Cross-Origin-Opener-Policy"_s, "same-origin; report-to=\"coop\""_s }, { "Cross-Origin-Embedder-Policy"_s, "require-corp"_s },
            { "Reporting-Endpoints"_s, "coop=\"https://reports.example.com/coop\", default=\"https://reports.example.com/\""_s },
            { "Link"_s, "</static/main.css>; rel=preload; as=style, </static/app.js>; rel=preload; as=script, <https://cdn.example.com>; rel=preconnect"_s },
            { "Server-Timing"_s, "db;dur=53, app;dur=47.2, total;dur=101.3;desc=\"Total\""_s }, { "Origin-Agent-Cluster"_s, "?1"_s },
            { "Speculation-Rules"_s, "\"/speculationrules.json\""_s }, { "Strict-Transport-Security"_s, "max-age=63072000"_s },
            { "Set-Cookie"_s, "session=abc; Path=/; Secure; HttpOnly"_s }, { "Vary"_s, "Accept-Encoding, Cookie"_s },
            { "Content-Security-Policy"_s, "default-src 'self'"_s }, { "Server"_s, "nginx"_s } } },
        Template { "https://static.example.com/app.3f9a1c.js"_s, "HTTP/1.1 200 OK"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "application/javascript"_s }, { "Content-Length"_s, "183402"_s },
            { "Cache-Control"_s, "public, max-age=31536000, immutable"_s }, { "ETag"_s, "\"3f9a1c\""_s },
            { "Last-Modified"_s, "Wed, 21 Oct 2026 07:28:00 GMT"_s }, { "Expires"_s, "Mon, 08 Nov 2027 23:12:40 GMT"_s },
            { "Cross-Origin-Resource-Policy"_s, "cross-origin"_s }, { "Access-Control-Allow-Origin"_s, "*"_s },
            { "Timing-Allow-Origin"_s, "*"_s }, { "Server-Timing"_s, "cdn-cache;desc=HIT, edge;dur=1"_s }, { "Age"_s, "3600"_s } } },
        Template { "https://static.example.com/site.css"_s, "HTTP/1.1 200 OK"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "text/css;charset=UTF-8"_s }, { "Content-Length"_s, "20931"_s },
            { "Cache-Control"_s, "max-age=600, stale-while-revalidate=30"_s }, { "X-Content-Type-Options"_s, "NoSniff, other"_s },
            { "Date"_s, "Sun, 08 Nov 2026 23:12:40 +0000"_s }, { "Cross-Origin-Resource-Policy"_s, "same-site"_s } } },
        Template { "https://img.example.com/hero.webp"_s, "HTTP/2 200"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "image/webp"_s }, { "Content-Length"_s, "1024, 1024"_s }, { "Cache-Control"_s, "max-age=86400"_s },
            { "Age"_s, "17"_s }, { "Cross-Origin-Resource-Policy"_s, "Same-Origin"_s }, { "Expires"_s, "0"_s },
            { "Last-Modified"_s, "Sunday, 06-Nov-94 08:49:37 GMT"_s } } },
        Template { "https://api.example.com/v1/items"_s, "HTTP/1.1 200 OK"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "application/json; charset=utf-8"_s }, { "Cache-Control"_s, "private, no-store"_s },
            { "Pragma"_s, "no-cache"_s }, { "Vary"_s, "Origin"_s }, { "X-Request-Id"_s, "7f3c2a1b-9d8e-4f6a"_s },
            { "Access-Control-Expose-Headers"_s, "X-Request-Id, Server-Timing"_s },
            { "Server-Timing"_s, "sql-1;desc=\"SELECT\";dur=12.5, app;dur=3.25"_s }, { "Expires"_s, "-1"_s },
            { "Clear-Site-Data"_s, "\"cache\", \"cookies\""_s } } },
        Template { "https://api.example.com/v1/items"_s, "HTTP/1.1 204 No Content"_s, ASCIILiteral { }, {
            { "Access-Control-Allow-Origin"_s, "https://app.example.com"_s }, { "Access-Control-Allow-Methods"_s, "GET, POST, PUT, DELETE, OPTIONS"_s },
            { "Access-Control-Allow-Headers"_s, "Content-Type, Authorization, X-Requested-With, x-csrf-token"_s },
            { "Access-Control-Max-Age"_s, "86400"_s }, { "Access-Control-Allow-Credentials"_s, "true"_s }, { "Vary"_s, "Origin"_s } } },
        Template { "https://api.example.com/v2/upload"_s, "HTTP/1.1 204 No Content"_s, ASCIILiteral { }, {
            { "Access-Control-Allow-Methods"_s, " POST ,, PATCH,"_s }, { "Access-Control-Allow-Headers"_s, "*"_s },
            { "Access-Control-Expose-Headers"_s, "X-Request-Id, bad header, Server-Timing"_s } } },
        Template { "https://media.example.com/video.mp4"_s, "HTTP/1.1 206 Partial Content"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "video/mp4"_s }, { "Content-Range"_s, "bytes 0-1048575/52428800"_s },
            { "Content-Length"_s, "1048576"_s }, { "Accept-Ranges"_s, "bytes"_s }, { "Cache-Control"_s, "max-age=3600"_s },
            { "Last-Modified"_s, "Tue, 15 Nov 1994 12:45:26 GMT"_s } } },
        Template { "https://files.example.com/download?id=42"_s, "HTTP/1.1 200 OK"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "application/pdf"_s }, { "Content-Disposition"_s, "attachment; filename=\"report Q3.pdf\""_s },
            { "Content-Length"_s, "734221"_s }, { "Cache-Control"_s, "no-cache"_s }, { "X-Frame-Options"_s, "deny, sameorigin"_s } } },
        Template { "http://insecure.example.com/old"_s, "HTTP/1.1 301 Moved Permanently"_s, ASCIILiteral { }, {
            { "Location"_s, "https://www.example.com/new"_s }, { "Cache-Control"_s, "max-age=3600"_s },
            { "Content-Type"_s, "text/html; charset=iso-8859-1"_s }, { "Clear-Site-Data"_s, "\"*\""_s },
            { "Content-Length"_s, "abc"_s } } },
        Template { "https://www.example.com/logout"_s, "HTTP/1.1 200 OK"_s, "never"_s, {
            { "Content-Type"_s, "text/html"_s }, { "Clear-Site-Data"_s, "\"cache\", \"cookies\", \"storage\", \"executionContexts\", \"prefetchCache\""_s },
            { "Cache-Control"_s, "no-store"_s }, { "X-Frame-Options"_s, "DENY"_s }, { "Referrer-Policy"_s, "no-referrer"_s },
            { "Cross-Origin-Opener-Policy"_s, "same-origin-allow-popups"_s }, { "Integrity-Policy"_s, "blocked-destinations=(script), endpoints=(integrity)"_s } } },
        Template { "https://www.example.com/missing"_s, "HTTP/1.1 404 Not Found"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "text/html; charset=\"utf-8\""_s }, { "X-Frame-Options"_s, "ALLOW-FROM https://example.org"_s },
            { "Date"_s, "not a date"_s }, { "Cache-Control"_s, "max-age=60, must-revalidate"_s },
            { "Referrer-Policy"_s, "unsafe-url, foo"_s }, { "Cross-Origin-Embedder-Policy"_s, "credentialless; report-to=coep"_s } } },
        Template { "https://www.example.com/cached"_s, "HTTP/1.1 304 Not Modified"_s, ASCIILiteral { }, {
            { "ETag"_s, "\"33a64df5\""_s }, { "Date"_s, "Sun, 08 Nov 2026 23:12:41 GMT"_s }, { "Cache-Control"_s, "max-age=120"_s },
            { "Server-Timing"_s, "miss, edge;dur=4"_s } } },
        Template { "https://cdn.example.com/dictionary.dat"_s, "HTTP/1.1 200 OK"_s, ASCIILiteral { }, {
            { "Content-Type"_s, "application/octet-stream"_s }, { "Use-As-Dictionary"_s, "match=\"/assets/*\", match-dest=(\"script\"), id=\"dict-1\""_s },
            { "Cache-Control"_s, "public, max-age=604800"_s }, { "Cross-Origin-Resource-Policy"_s, "cross-origin"_s },
            { "Document-Isolation-Policy"_s, "isolate-and-require-corp"_s }, { "Content-Disposition"_s, "inline; filename=dictionary.dat"_s } } },
        Template { "https://www.example.com/status"_s, "HTTP/1.0 200"_s, "origin"_s, {
            { "Content-Type"_s, "text/plain"_s }, { "X-Frame-Options"_s, ""_s }, { "X-Content-Type-Options"_s, ""_s },
            { "Cross-Origin-Opener-Policy-Report-Only"_s, "same-origin; report-to=\"coop\""_s },
            { "Cross-Origin-Embedder-Policy-Report-Only"_s, "require-corp"_s }, { "Link"_s, "<url>; rel=preload; anchor=\"#x\", <a>"_s } } },
    };

    ResponseMixInputs inputs;
    for (auto name : { "X-Request-Id"_s, "Server-Timing"_s, "Content-Encoding"_s, "X-Trace-Id"_s, "ETag"_s })
        inputs.exposedHeaders.add(name);

    Random random { 0x524553504F4E5345ULL };
    for (unsigned i = 0; i < 640; ++i) {
        auto& responseTemplate = random.pick(templates);
        bool wide = random.chance(25);
        auto convert = [&](const String& string) {
            return wide ? copyAs16Bit(string) : string;
        };
        auto token = random.token(8);
        auto contentLength = random.below(1000000);
        Response response {
            convert(responseTemplate.statusLine),
            responseTemplate.metaReferrer.isNull() ? String() : convert(responseTemplate.metaReferrer),
            { },
            WebCore::ResourceResponse { WTF::URL { String { responseTemplate.url } }, String { }, contentLength, String { } },
        };
        for (auto& [name, value] : responseTemplate.headers) {
            String headerValue = value;
            if (name == "ETag"_s)
                headerValue = WTF::makeString('"', token, '"');
            bool serverTiming = name == "Server-Timing"_s;
            response.headers.append({ convert(name), serverTiming ? headerValue : convert(headerValue), std::nullopt });
        }
        if (wide && random.chance(40)) {
            response.headers.append({ wideString(u"Content-Disposition"), wideString(u"attachment; filename=\"\u65E5\u672C.pdf\""), std::nullopt });
            response.headers.append({ wideString(u"X-Frame-Options"), wideString(u"deny\u012C sameorigin"), std::nullopt });
            response.headers.append({ wideString(u"Link"), wideString(u"</caf\u00E9.css>; rel=preload; as=style"), std::nullopt });
            response.headers.append({ wideString(u"X-\u0130"), wideString(u"v"), std::nullopt });
        }
        for (auto& header : response.headers) {
            header.headerName = headerNameFor(header.name);
            response.response.setHTTPHeaderField(header.name, header.value);
            inputs.bytes += byteSize(header.name) + byteSize(header.value);
        }
        inputs.bytes += byteSize(response.statusLine) + byteSize(response.metaReferrer);
        inputs.responses.append(WTF::move(response));
    }
    return inputs;
}

template<typename Sink> void runResponseMixPass(const ResponseMixInputs& inputs, Sink& sink)
{
    for (auto& response : inputs.responses) {
        auto reason = WebCore::extractReasonPhraseFromHTTPStatusLine(response.statusLine);
        sink.addString(reason.string());
        sink.addBoolean(WebCore::isValidReasonPhrase(reason.string()));
        for (auto& header : response.headers) {
            sink.addBoolean(WebCore::isForbiddenResponseHeaderName(header.name));
            if (header.headerName) {
                sink.addBoolean(WebCore::isCrossOriginSafeHeader(*header.headerName, inputs.exposedHeaders));
                addParsedResponseHeader(sink, *header.headerName, header.value);
            } else
                sink.addBoolean(WebCore::isCrossOriginSafeHeader(header.name, inputs.exposedHeaders));
        }
        addCacheControlDirectives(sink, WebCore::parseCacheControlDirectives(response.response.httpHeaderFields()));
        sink.addInteger(WebCore::parseClearSiteDataHeader(response.response).toRaw());
        if (!response.metaReferrer.isNull())
            addReferrerPolicy(sink, WebCore::parseReferrerPolicy(response.metaReferrer, WebCore::ReferrerPolicySource::MetaTag));
    }
}

} // namespace TestWebKitAPI::HTTPHeaderParsersBench
