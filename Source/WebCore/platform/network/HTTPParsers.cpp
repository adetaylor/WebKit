/*
 * Copyright (C) 2006 Alexey Proskuryakov (ap@webkit.org)
 * Copyright (C) 2006-2017 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Torch Mobile Inc. http://www.torchmobile.com/
 * Copyright (C) 2009 Google Inc. All rights reserved.
 * Copyright (C) 2011 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Apple Inc. ("Apple") nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "HTTPParsers.h"

#include "CommonAtomStrings.h"
#include "HTTPHeaderField.h"
#include "HTTPHeaderNames.h"
#include "RFC7230.h"
#include "ResourceResponse.h"
#include "SecurityOrigin.h"
#include "WebCore-Swift.h"
#include <wtf/OptionSet.h>

namespace WebCore {

#if USE(GLIB)
// True if characters which satisfy the predicate are present, incrementing
// "pos" to the next character which does not satisfy the predicate.
// Note: might return pos == str.length().
static inline bool skipWhile(const String& str, unsigned& pos, NOESCAPE const Function<bool(const char16_t)>& predicate)
{
    const unsigned start = pos;
    const unsigned len = str.length();
    while (pos < len && predicate(str[pos]))
        ++pos;
    return pos != start;
}

// true if there is more to parse, after incrementing pos past whitespace.
// Note: Might return pos == str.length()
static inline bool skipWhiteSpace(const String& str, unsigned& pos)
{
    skipWhile(str, pos, isTabOrSpace<char16_t>);
    return pos < str.length();
}
#endif

// See RFC 7230, Section 3.1.2.
bool isValidReasonPhrase(const String& value)
{
    return value.is8Bit() ? isValidReasonPhrase8(value.span8()) : isValidReasonPhrase16(value.span16());
}

// See https://fetch.spec.whatwg.org/#concept-header
bool isValidHTTPHeaderValue(const String& value)
{
    return value.is8Bit() ? isValidHTTPHeaderValue8(value.span8()) : isValidHTTPHeaderValue16(value.span16());
}

// See RFC 7231, Section 5.3.2.
bool isValidAcceptHeaderValue(const String& value)
{
    return value.is8Bit() ? isValidAcceptHeaderValue8(value.span8()) : isValidAcceptHeaderValue16(value.span16());
}

// See RFC 7231, Section 5.3.5 and 3.1.3.2.
// https://fetch.spec.whatwg.org/#cors-safelisted-request-header
bool isValidLanguageHeaderValue(const String& value)
{
    return value.is8Bit() ? isValidLanguageHeaderValue8(value.span8()) : isValidLanguageHeaderValue16(value.span16());
}

// See RFC 7230, Section 3.2.6.
bool isValidHTTPToken(StringView value)
{
    return value.is8Bit() ? isValidHTTPToken8(value.span8()) : isValidHTTPToken16(value.span16());
}

bool isValidHTTPToken(const String& value)
{
    return isValidHTTPToken(StringView(value));
}

#if USE(GLIB)
// True if the character at the given position satisifies a predicate, incrementing "pos" by one.
// Note: Might return pos == str.length()
static inline bool skipCharacter(const String& value, unsigned& pos, NOESCAPE const Function<bool(const char16_t)>& predicate)
{
    if (pos < value.length() && predicate(value[pos])) {
        ++pos;
        return true;
    }
    return false;
}

// True if the "expected" character is at the given position, incrementing "pos" by one.
// Note: Might return pos == str.length()
static inline bool skipCharacter(const String& value, unsigned& pos, const char16_t expected)
{
    return skipCharacter(value, pos, [expected](const char16_t c) {
        return c == expected;
    });
}

// True if a quoted pair is present, incrementing "pos" to the position after the quoted pair.
// Note: Might return pos == str.length()
// See RFC 7230, Section 3.2.6.
static constexpr auto QuotedPairStartCharacter = '\\';
static bool skipQuotedPair(const String& value, unsigned& pos)
{
    // quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text )
    return skipCharacter(value, pos, QuotedPairStartCharacter)
        && skipCharacter(value, pos, RFC7230::isQuotedPairSecondOctet);
}

// True if a comment is present, incrementing "pos" to the position after the comment.
// Note: Might return pos == str.length()
// See RFC 7230, Section 3.2.6.
static constexpr auto CommentStartCharacter = '(';
static constexpr auto CommentEndCharacter = ')';
static bool skipComment(const String& value, unsigned& pos)
{
    // comment = "(" *( ctext / quoted-pair / comment ) ")"
    // ctext   = HTAB / SP / %x21-27 / %x2A-5B / %x5D-7E / obs-text
    if (!skipCharacter(value, pos, CommentStartCharacter))
        return false;

    const unsigned end = value.length();
    while (pos < end && value[pos] != CommentEndCharacter) {
        switch (value[pos]) {
        case CommentStartCharacter:
            if (!skipComment(value, pos))
                return false;
            break;
        case QuotedPairStartCharacter:
            if (!skipQuotedPair(value, pos))
                return false;
            break;
        default:
            if (!skipWhile(value, pos, RFC7230::isCommentText))
                return false;
        }
    }
    return skipCharacter(value, pos, CommentEndCharacter);
}

// True if an HTTP header token is present, incrementing "pos" to the position after it.
// Note: Might return pos == str.length()
// See RFC 7230, Section 3.2.6.
static bool skipHTTPToken(const String& value, unsigned& pos)
{
    return skipWhile(value, pos, RFC7230::isTokenCharacter);
}

// True if a product specifier (as in an User-Agent header) is present, incrementing "pos" to the position after it.
// Note: Might return pos == str.length()
// See RFC 7231, Section 5.5.3.
static bool skipUserAgentProduct(const String& value, unsigned& pos)
{
    // product         = token ["/" product-version]
    // product-version = token
    if (!skipHTTPToken(value, pos))
        return false;
    if (skipCharacter(value, pos, '/'))
        return skipHTTPToken(value, pos);
    return true;
}

// See RFC 7231, Section 5.5.3
bool isValidUserAgentHeaderValue(const String& value)
{
    // User-Agent = product *( RWS ( product / comment ) )
    unsigned pos = 0;
    if (!skipUserAgentProduct(value, pos))
        return false;

    while (pos < value.length()) {
        if (!skipWhiteSpace(value, pos))
            return false;
        if (value[pos] == CommentStartCharacter) {
            if (!skipComment(value, pos))
                return false;
        } else {
            if (!skipUserAgentProduct(value, pos))
                return false;
        }
    }

    return pos == value.length();
}
#endif

std::optional<WallTime> parseHTTPDate(const String& value)
{
    double dateInMillisecondsSinceEpoch = value.is8Bit() ? parseHTTPDate8(value.span8()) : parseHTTPDate16(value.span16());
    if (!std::isfinite(dateInMillisecondsSinceEpoch))
        return std::nullopt;
    // This assumes system_clock epoch equals Unix epoch which is true for all implementations but unspecified.
    // FIXME: The parsing function should be switched to WallTime too.
    return WallTime::fromRawSeconds(dateInMillisecondsSinceEpoch / 1000.0);
}

// FIXME: This function doesn't comply with RFC 6266.
// For example, this function doesn't handle the interaction between " and ;
// that arises from quoted-string, nor does this function properly unquote
// attribute values. Further this function appears to process parameter names
// in a case-sensitive manner. (There are likely other bugs as well.)
StringView filenameFromHTTPContentDisposition(StringView value LIFETIME_BOUND)
{
    auto filename = value.is8Bit() ? filenameFromHTTPContentDisposition8(value.span8()) : filenameFromHTTPContentDisposition16(value.span16());
    if (filename.isNull)
        return { };
    return value.substring(filename.start, filename.length);
}

String extractMIMETypeFromMediaType(const String& mediaType)
{
    auto mimeType = mediaType.is8Bit() ? extractMIMETypeFromMediaType8(mediaType.span8()) : extractMIMETypeFromMediaType16(mediaType.span16());
    return mediaType.substring(mimeType.start, mimeType.length).convertToASCIILowercase();
}

StringView extractCharsetFromMediaType(StringView mediaType LIFETIME_BOUND)
{
    auto charset = mediaType.is8Bit() ? extractCharsetFromMediaType8(mediaType.span8()) : extractCharsetFromMediaType16(mediaType.span16());
    return mediaType.substring(charset.start, charset.length);
}

ContentTypeOptionsDisposition parseContentTypeOptionsHeader(StringView header)
{
    return header.is8Bit() ? parseContentTypeOptionsHeader8(header.span8()) : parseContentTypeOptionsHeader16(header.span16());
}

// For example: "HTTP/1.1 200 OK" => "OK".
// Note that HTTP/2 does not include a reason phrase, so we return the empty atom.
AtomString extractReasonPhraseFromHTTPStatusLine(const String& statusLine)
{
    auto reasonPhrase = statusLine.is8Bit() ? extractReasonPhraseFromHTTPStatusLine8(statusLine.span8()) : extractReasonPhraseFromHTTPStatusLine16(statusLine.span16());
    if (reasonPhrase.isNull)
        return emptyAtom();
    return StringView(statusLine).substring(reasonPhrase.start, reasonPhrase.length).toAtomString();
}

XFrameOptionsDisposition parseXFrameOptionsHeader(StringView header)
{
    return header.is8Bit() ? parseXFrameOptionsHeader8(header.span8()) : parseXFrameOptionsHeader16(header.span16());
}

OptionSet<ClearSiteDataValue> parseClearSiteDataHeader(const ResourceResponse& response)
{
    auto headerValue = response.httpHeaderField(HTTPHeaderName::ClearSiteData);
    if (headerValue.isEmpty() || !WebCore::shouldTreatAsPotentiallyTrustworthy(response.url()))
        return { };
    return OptionSet<ClearSiteDataValue>::fromRaw(headerValue.is8Bit() ? parseClearSiteDataHeader8(headerValue.span8()) : parseClearSiteDataHeader16(headerValue.span16()));
}

// Implements <https://fetch.spec.whatwg.org/#simple-range-header-value>.
std::optional<HTTPRange> parseRange(StringView range, RangeAllowWhitespace allowWhitespace)
{
    auto result = range.is8Bit() ? parseRange8(range.span8(), allowWhitespace == RangeAllowWhitespace::Yes) : parseRange16(range.span16(), allowWhitespace == RangeAllowWhitespace::Yes);
    if (!result.isValid)
        return std::nullopt;
    return HTTPRange { result.hasStart ? std::optional { result.start } : std::nullopt, result.hasEnd ? std::optional { result.end } : std::nullopt };
}

size_t parseHTTPHeader(std::span<const uint8_t> data, String& failureReason, StringView& nameStr, String& valueStr, bool strict)
{
    nameStr = StringView();
    valueStr = String();
    auto line = parseHTTPHeaderLine(data, strict);
    if (!line.field.name.isNull)
        nameStr = byteCast<Latin1Character>(data.subspan(line.field.name.start, line.field.name.length));
    if (!line.failureReason.isNull()) {
        failureReason = WTF::move(line.failureReason);
        return 0;
    }
    if (line.field.value.isNull)
        return line.length;
    valueStr = String::fromUTF8(data.subspan(line.field.value.start, line.field.value.length));
    if (valueStr.isNull()) {
        failureReason = "Invalid UTF-8 sequence in header value"_s;
        return 0;
    }
    return line.length;
}

std::optional<uint64_t> parseContentLength(StringView contentLengthValue)
{
    auto length = contentLengthValue.is8Bit() ? parseContentLength8(contentLengthValue.span8()) : parseContentLength16(contentLengthValue.span16());
    if (!length.hasValue)
        return std::nullopt;
    return length.value;
}

// Implements <https://fetch.spec.whatwg.org/#forbidden-header-name>.
bool isForbiddenHeaderName(const String& name)
{
    HTTPHeaderName headerName { };
    bool isKnownName = findHTTPHeaderName(name, headerName);
    return name.is8Bit() ? isForbiddenHeaderName8(name.span8(), isKnownName, headerName) : isForbiddenHeaderName16(name.span16(), isKnownName, headerName);
}

bool isForbiddenHeader(const String& name, StringView value)
{
    HTTPHeaderName headerName { };
    bool isKnownName = findHTTPHeaderName(name, headerName);
    return name.is8Bit()
        ? (value.is8Bit() ? isForbiddenHeader8And8(name.span8(), isKnownName, headerName, value.span8()) : isForbiddenHeader8And16(name.span8(), isKnownName, headerName, value.span16()))
        : (value.is8Bit() ? isForbiddenHeader16And8(name.span16(), isKnownName, headerName, value.span8()) : isForbiddenHeader16And16(name.span16(), isKnownName, headerName, value.span16()));
}

// Implements <https://fetch.spec.whatwg.org/#no-cors-safelisted-request-header-name>.
bool isNoCORSSafelistedRequestHeaderName(const String& name)
{
    HTTPHeaderName headerName { };
    bool isKnownName = findHTTPHeaderName(name, headerName);
    return name.is8Bit() ? isNoCORSSafelistedRequestHeaderName8(name.span8(), isKnownName, headerName) : isNoCORSSafelistedRequestHeaderName16(name.span16(), isKnownName, headerName);
}

// Implements <https://fetch.spec.whatwg.org/#privileged-no-cors-request-header-name>.
bool isPriviledgedNoCORSRequestHeaderName(const String& name)
{
    return name.is8Bit() ? isPriviledgedNoCORSRequestHeaderName8(name.span8(), name.length()) : isPriviledgedNoCORSRequestHeaderName16(name.span16(), name.length());
}

// Implements <https://fetch.spec.whatwg.org/#forbidden-response-header-name>.
bool isForbiddenResponseHeaderName(const String& name)
{
    return name.is8Bit() ? isForbiddenResponseHeaderName8(name.span8(), name.length()) : isForbiddenResponseHeaderName16(name.span16(), name.length());
}

// Implements <https://fetch.spec.whatwg.org/#forbidden-method>.
bool isForbiddenMethod(StringView name)
{
    return name.is8Bit() ? isForbiddenMethod8(name.span8(), name.length()) : isForbiddenMethod16(name.span16(), name.length());
}

bool isSimpleHeader(const String& name, const String& value)
{
    HTTPHeaderName headerName;
    if (!findHTTPHeaderName(name, headerName))
        return false;
    return isCrossOriginSafeRequestHeader(headerName, value);
}

bool isCrossOriginSafeHeader(HTTPHeaderName name, const HTTPHeaderSet& accessControlExposeHeaderSet)
{
    if (auto safety = crossOriginHeaderSafety(name); safety != HTTPHeaderCrossOriginSafety::Exposed)
        return safety == HTTPHeaderCrossOriginSafety::Safe;
    return accessControlExposeHeaderSet.contains<HashTranslatorASCIILiteralCaseInsensitive>(httpHeaderNameString(name));
}

bool isCrossOriginSafeHeader(const String& name, const HTTPHeaderSet& accessControlExposeHeaderSet)
{
#if ASSERT_ENABLED
    HTTPHeaderName headerName;
    ASSERT(!findHTTPHeaderName(name, headerName));
#endif
    return accessControlExposeHeaderSet.contains(name);
}

// Implements https://fetch.spec.whatwg.org/#cors-safelisted-request-header
bool isCrossOriginSafeRequestHeader(HTTPHeaderName name, const String& value)
{
    return value.is8Bit() ? isCrossOriginSafeRequestHeader8(name, value.span8()) : isCrossOriginSafeRequestHeader16(name, value.span16());
}

// Implements <https://fetch.spec.whatwg.org/#concept-method-normalize>.
String normalizeHTTPMethod(const String& method)
{
    auto normalized = method.is8Bit() ? normalizedHTTPMethod8(method.span8()) : normalizedHTTPMethod16(method.span16());
    return normalized.isNull() ? method : normalized;
}

// Defined by https://tools.ietf.org/html/rfc7231#section-4.2.1
bool isSafeMethod(const String& method)
{
    return method.is8Bit() ? isSafeMethod8(method.span8()) : isSafeMethod16(method.span16());
}

CrossOriginResourcePolicy parseCrossOriginResourcePolicyHeader(StringView header)
{
    return header.is8Bit() ? parseCrossOriginResourcePolicyHeader8(header.span8()) : parseCrossOriginResourcePolicyHeader16(header.span16());
}

// Request headers that can be appended to, and the delimiter placed between values.
std::optional<ASCIILiteral> requestHeaderAppendDelimiter(const String& header)
{
    // Indexed by the raw value of AppendDelimiter in HTTPParsers.swift, so in the order of its cases.
    static constexpr std::array delimiters { ", "_s, "; "_s, ""_s, " "_s };
    auto index = header.is8Bit() ? requestHeaderAppendDelimiterIndex8(header.span8()) : requestHeaderAppendDelimiterIndex16(header.span16());
    if (!index)
        return std::nullopt;
    return delimiters[index - 1];
}

bool isRequestHeaderUnsafeToModify(const String& header, StringView value)
{
    return header.is8Bit()
        ? (value.is8Bit() ? isRequestHeaderUnsafeToModify8And8(header.span8(), value.span8()) : isRequestHeaderUnsafeToModify8And16(header.span8(), value.span16()))
        : (value.is8Bit() ? isRequestHeaderUnsafeToModify16And8(header.span16(), value.span8()) : isRequestHeaderUnsafeToModify16And16(header.span16(), value.span16()));
}

template<class HashType>
static std::optional<HashSet<String, HashType>> parseAccessControlAllowListWithHash(const String& string)
{
    HashSet<String, HashType> set;
    for (unsigned start = 0; start < string.length();) {
        auto token = string.is8Bit() ? accessControlAllowListToken8(string.span8(), start) : accessControlAllowListToken16(string.span16(), start);
        if (!token.isValid)
            return { };
        if (!token.item.isNull)
            set.add(string.substring(token.item.start, token.item.length));
        start = token.next;
    }
    return set;
}

template<> std::optional<HashSet<String>> parseAccessControlAllowList<DefaultHash<String>>(const String& string)
{
    return parseAccessControlAllowListWithHash<DefaultHash<String>>(string);
}

template<> std::optional<HTTPHeaderSet> parseAccessControlAllowList<ASCIICaseInsensitiveHash>(const String& string)
{
    return parseAccessControlAllowListWithHash<ASCIICaseInsensitiveHash>(string);
}

}
