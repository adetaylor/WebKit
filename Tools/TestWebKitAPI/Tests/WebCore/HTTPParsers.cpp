/*
 * Copyright (C) 2018 Apple Inc. All rights reserved.
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

#include "Helpers/Test.h"
#include <WebCore/CacheValidation.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/HTTPParsers.h>
#include <WebCore/LinkHeader.h>
#include <WebCore/RFC8941.h>
#include <WebCore/ServerTiming.h>
#include <WebCore/ServerTimingParser.h>
#include <wtf/DateMath.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

using namespace WebCore;

namespace TestWebKitAPI {

TEST(HTTPParsers, ParseCrossOriginResourcePolicyHeader)
{
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader(""_s) == CrossOriginResourcePolicy::None);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader(" "_s) == CrossOriginResourcePolicy::None);

    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("same-origin"_s) == CrossOriginResourcePolicy::SameOrigin);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("Same-Origin"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("SAME-ORIGIN"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader(" same-orIGIN "_s) == CrossOriginResourcePolicy::Invalid);

    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("same-site"_s) == CrossOriginResourcePolicy::SameSite);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("Same-Site"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("SAME-SITE"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader(" same-site "_s) == CrossOriginResourcePolicy::SameSite);

    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("SameOrigin"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("zameorigin"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("samesite"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("same site"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader(StringView::fromLatin1("same–site")) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader("SAMESITE"_s) == CrossOriginResourcePolicy::Invalid);
    EXPECT_TRUE(parseCrossOriginResourcePolicyHeader(StringView::fromLatin1("")) == CrossOriginResourcePolicy::Invalid);
}

#if USE(GLIB)
TEST(HTTPParsers, ValidateUserAgentValues)
{
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari WebKit"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari/10.0"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari WebKit/163"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari/10.0 WebKit"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari/10.0 WebKit/163"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari/10.0 WebKit/163 (Mozilla; like Gecko)"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari (comment (nested comment))"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari () (<- Empty comment)"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("Safari (left paren \\( as quoted pair)"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("!#$%&'*+-.^_`|~ (non-alphanumeric token characters)"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("0123456789 (numeric token characters)"_s));
    EXPECT_TRUE(isValidUserAgentHeaderValue("a (single character token)"_s));

    EXPECT_FALSE(isValidUserAgentHeaderValue(" "_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue(" Safari (leading whitespace)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("Safari (trailing whitespace) "_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("\nSafari (leading newline)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("Safari (trailing newline)\n"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("Safari/ (no version token after slash)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("Safari (unterminated comment"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("Safari unopened commanent)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("\x1B (contains control character)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("Safari/\n10.0 (embeded newline)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("WPE\\ WebKit (quoted pair in token)"_s));
    EXPECT_FALSE(isValidUserAgentHeaderValue("/123 (missing product token)"_s));
}
#endif

TEST(RFC8941, ParseItemStructuredFieldValue)
{
    // Simple Token BareItem.
    auto result = RFC8941::parseItemStructuredFieldValue("unsafe-none"_s);
    EXPECT_TRUE(!!result);
    auto* itemString = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!itemString);
    EXPECT_EQ("unsafe-none"_s, itemString->string());

    // Invalid Token BareItem.
    result = RFC8941::parseItemStructuredFieldValue("same-site unsafe-allow-outgoing"_s);
    EXPECT_TRUE(!result);

    // String parameter value.
    result = RFC8941::parseItemStructuredFieldValue("same-origin-allow-popups; report-to=\"http://example.com\""_s);
    EXPECT_TRUE(!!result);
    itemString = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!itemString);
    EXPECT_EQ("same-origin-allow-popups"_s, itemString->string());
    EXPECT_EQ(result->second.map().size(), 1U);
    auto* parameterValueString = result->second.getIf<String>("report-to"_s);
    EXPECT_TRUE(!!parameterValueString);
    EXPECT_EQ("http://example.com"_s, *parameterValueString);

    // Token parameter value.
    result = RFC8941::parseItemStructuredFieldValue("same-origin-allow-popups; report-to=*"_s);
    EXPECT_TRUE(!!result);
    itemString = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!itemString);
    EXPECT_EQ("same-origin-allow-popups"_s, itemString->string());
    EXPECT_EQ(result->second.map().size(), 1U);
    auto* parameterValueToken = result->second.getIf<RFC8941::Token>("report-to"_s);
    EXPECT_TRUE(!!parameterValueToken);
    EXPECT_EQ("*"_s, parameterValueToken->string());

    // True boolean parameter value.
    result = RFC8941::parseItemStructuredFieldValue("same-origin-allow-popups; should-report=?1"_s);
    EXPECT_TRUE(!!result);
    itemString = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!itemString);
    EXPECT_EQ("same-origin-allow-popups"_s, itemString->string());
    EXPECT_EQ(result->second.map().size(), 1U);
    auto* parameterValueBoolean = result->second.getIf<bool>("should-report"_s);
    EXPECT_TRUE(!!parameterValueToken);
    EXPECT_TRUE(*parameterValueBoolean);

    // False boolean parameter value.
    result = RFC8941::parseItemStructuredFieldValue("same-origin-allow-popups; should-report=?0"_s);
    EXPECT_TRUE(!!result);
    itemString = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!itemString);
    EXPECT_EQ("same-origin-allow-popups"_s, itemString->string());
    EXPECT_EQ(result->second.map().size(), 1U);
    parameterValueBoolean = result->second.getIf<bool>("should-report"_s);
    EXPECT_TRUE(!!parameterValueToken);
    EXPECT_FALSE(*parameterValueBoolean);

    // Invalid boolean parameter value.
    result = RFC8941::parseItemStructuredFieldValue("same-origin-allow-popups; should-report=?3"_s);
    EXPECT_TRUE(!result);

    // Multiple parameters.
    result = RFC8941::parseItemStructuredFieldValue("same-origin-allow-popups; should-report=?1; report-to=\"http://example.com\""_s);
    EXPECT_TRUE(!!result);
    itemString = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!itemString);
    EXPECT_EQ("same-origin-allow-popups"_s, itemString->string());
    EXPECT_EQ(result->second.map().size(), 2U);
    parameterValueBoolean = result->second.getIf<bool>("should-report"_s);
    EXPECT_TRUE(!!parameterValueToken);
    EXPECT_TRUE(*parameterValueBoolean);
    parameterValueString = result->second.getIf<String>("report-to"_s);
    EXPECT_TRUE(!!parameterValueString);
    EXPECT_EQ("http://example.com"_s, *parameterValueString);

    // Integer BareItem tests.
    result = RFC8941::parseItemStructuredFieldValue("42"_s);
    EXPECT_TRUE(!!result);
    auto* intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 42);

    result = RFC8941::parseItemStructuredFieldValue("0"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 0);

    result = RFC8941::parseItemStructuredFieldValue("-42"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, -42);

    result = RFC8941::parseItemStructuredFieldValue("-0"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 0);

    result = RFC8941::parseItemStructuredFieldValue("042"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 42);

    result = RFC8941::parseItemStructuredFieldValue("-042"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, -42);

    result = RFC8941::parseItemStructuredFieldValue("999999999999999"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 999999999999999LL);

    result = RFC8941::parseItemStructuredFieldValue("-999999999999999"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, -999999999999999LL);

    result = RFC8941::parseItemStructuredFieldValue("000000000000000"_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 0);

    // Invalid Integer BareItem.
    result = RFC8941::parseItemStructuredFieldValue("0000000000000000"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("9999999999999999"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-9999999999999999"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-."_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("--0"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("- 42"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("2,3"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-a23"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("4-2"_s);
    EXPECT_FALSE(!!result);

    // Decimal BareItem tests.
    result = RFC8941::parseItemStructuredFieldValue("1.5"_s);
    EXPECT_TRUE(!!result);
    auto* decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 1.5);

    result = RFC8941::parseItemStructuredFieldValue("-1.5"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, -1.5);

    result = RFC8941::parseItemStructuredFieldValue("0.0"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 0.0);

    result = RFC8941::parseItemStructuredFieldValue("1.123"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 1.123);

    result = RFC8941::parseItemStructuredFieldValue("-1.123"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, -1.123);

    result = RFC8941::parseItemStructuredFieldValue("1.000"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 1.0);

    result = RFC8941::parseItemStructuredFieldValue("123456789012.123"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 123456789012.123);

    result = RFC8941::parseItemStructuredFieldValue("000000000100.123"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 100.123);

    result = RFC8941::parseItemStructuredFieldValue("-999999999999.999"_s);
    EXPECT_TRUE(!!result);
    decimalValue = std::get_if<double>(&result->first);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, -999999999999.999);

    // Invalid Decimal BareItem.
    result = RFC8941::parseItemStructuredFieldValue("0000000000000.1"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1.0000"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-1.1234"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1."_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-1."_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1.1234"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1234567890123.0"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("-1234567890123.0"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1. 23"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1 .23"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1..4"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("1.5.4"_s);
    EXPECT_FALSE(!!result);

    // Byte sequence BareItem tests.
    result = RFC8941::parseItemStructuredFieldValue("::"_s);
    EXPECT_TRUE(!!result);
    auto* bytes = std::get_if<Vector<uint8_t>>(&result->first);
    EXPECT_TRUE(!!bytes);
    EXPECT_TRUE(bytes->isEmpty());

    result = RFC8941::parseItemStructuredFieldValue(":aGVsbG8=:"_s);
    EXPECT_TRUE(!!result);
    bytes = std::get_if<Vector<uint8_t>>(&result->first);
    EXPECT_TRUE(!!bytes);
    EXPECT_EQ(bytes->size(), 5u);
    EXPECT_EQ((*bytes)[0], 'h');
    EXPECT_EQ((*bytes)[1], 'e');
    EXPECT_EQ((*bytes)[2], 'l');
    EXPECT_EQ((*bytes)[3], 'l');
    EXPECT_EQ((*bytes)[4], 'o');

    result = RFC8941::parseItemStructuredFieldValue(":cHJldGVuZCB0aGlzIGlzIGJpbmFyeSBjb250ZW50Lg==:"_s);
    EXPECT_TRUE(!!result);
    bytes = std::get_if<Vector<uint8_t>>(&result->first);
    EXPECT_TRUE(!!bytes);
    EXPECT_EQ(bytes->size(), 31u);

    result = RFC8941::parseItemStructuredFieldValue(":/+Ah:"_s);
    EXPECT_TRUE(!!result);
    bytes = std::get_if<Vector<uint8_t>>(&result->first);
    EXPECT_TRUE(!!bytes);
    EXPECT_EQ(bytes->size(), 3u);

    // Invalid Byte sequence BareItem.
    result = RFC8941::parseItemStructuredFieldValue("aGVsbG8=:"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":aGVsbG8="_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue("aGVsbG8="_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":=aGVsbG8=:"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":a=GVsbG8=:"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":aGVsbG8.:"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":aGVsb G8=:"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":aGVsbG!8=:"_s);
    EXPECT_FALSE(!!result);

    result = RFC8941::parseItemStructuredFieldValue(":_-Ah:"_s);
    EXPECT_FALSE(!!result);

    // Integer parameter tests.
    result = RFC8941::parseItemStructuredFieldValue("token;count=42"_s);
    EXPECT_TRUE(!!result);
    auto* token = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!token);
    EXPECT_EQ("token"_s, token->string());
    EXPECT_EQ(result->second.map().size(), 1U);
    auto* paramIntValue = result->second.getIf<int64_t>("count"_s);
    EXPECT_TRUE(!!paramIntValue);
    EXPECT_EQ(*paramIntValue, 42);

    // Negative integer parameter tests.
    result = RFC8941::parseItemStructuredFieldValue("token;offset=-10"_s);
    EXPECT_TRUE(!!result);
    token = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!token);
    paramIntValue = result->second.getIf<int64_t>("offset"_s);
    EXPECT_TRUE(!!paramIntValue);
    EXPECT_EQ(*paramIntValue, -10);

    // Decimal parameter tests.
    result = RFC8941::parseItemStructuredFieldValue("token;ratio=1.5"_s);
    EXPECT_TRUE(!!result);
    token = std::get_if<RFC8941::Token>(&result->first);
    EXPECT_TRUE(!!token);
    auto* paramDecimal = result->second.getIf<double>("ratio"_s);
    EXPECT_TRUE(!!paramDecimal);
    EXPECT_DOUBLE_EQ(*paramDecimal, 1.5);

    // String with multiple parameters (token and integer values).
    result = RFC8941::parseItemStructuredFieldValue("\"b\"; a=c; c=2"_s);
    EXPECT_TRUE(!!result);
    auto* stringValue = std::get_if<String>(&result->first);
    EXPECT_TRUE(!!stringValue);
    EXPECT_EQ("b"_s, *stringValue);
    EXPECT_EQ(result->second.map().size(), 2U);
    auto* paramTokenValue = result->second.getIf<RFC8941::Token>("a"_s);
    EXPECT_TRUE(!!paramTokenValue);
    EXPECT_EQ("c"_s, paramTokenValue->string());
    auto* paramIntValue2 = result->second.getIf<int64_t>("c"_s);
    EXPECT_TRUE(!!paramIntValue2);
    EXPECT_EQ(*paramIntValue2, 2);

    // Empty item.
    result = RFC8941::parseItemStructuredFieldValue(""_s);
    EXPECT_FALSE(!!result);

    // Leading and trailing whitespace
    result = RFC8941::parseItemStructuredFieldValue("     1  "_s);
    EXPECT_TRUE(!!result);
    intValue = std::get_if<int64_t>(&result->first);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 1);
}

TEST(RFC8941, ParseDictionaryStructuredFieldValue)
{
    auto result = RFC8941::parseDictionaryStructuredFieldValue("default=\"https://www.example.com/reporting/report.py?reportID=46ecac28-6d27-4763-a692-bcc588054716\""_s);
    EXPECT_TRUE(!!result);
    EXPECT_EQ(result->size(), 1U);
    EXPECT_TRUE(result->contains("default"_s));
    auto valueAndParameters = result->get("default"_s);
    auto* bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    auto* endpointURLString = std::get_if<String>(bareItem);
    EXPECT_TRUE(!!endpointURLString);
    EXPECT_EQ("https://www.example.com/reporting/report.py?reportID=46ecac28-6d27-4763-a692-bcc588054716"_s, *endpointURLString);

    result = RFC8941::parseDictionaryStructuredFieldValue("default=\"https://www.example.com/reporting/report.py?reportID=46ecac28-6d27-4763-a692-bcc588054716\", report-only=\"https://www.example.com/reporting/report.py?reportID=46ecac28-6d27-4763-a692-bcc588054717\""_s);
    EXPECT_TRUE(!!result);
    EXPECT_EQ(result->size(), 2U);
    EXPECT_TRUE(result->contains("default"_s));
    valueAndParameters = result->get("default"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    endpointURLString = std::get_if<String>(bareItem);
    EXPECT_TRUE(!!endpointURLString);
    EXPECT_EQ("https://www.example.com/reporting/report.py?reportID=46ecac28-6d27-4763-a692-bcc588054716"_s, *endpointURLString);
    valueAndParameters = result->get("report-only"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    endpointURLString = std::get_if<String>(bareItem);
    EXPECT_TRUE(!!endpointURLString);
    EXPECT_EQ("https://www.example.com/reporting/report.py?reportID=46ecac28-6d27-4763-a692-bcc588054717"_s, *endpointURLString);

    result = RFC8941::parseDictionaryStructuredFieldValue("geolocation=(self \"https://example.com\"), camera=()"_s);
    EXPECT_TRUE(!!result);
    EXPECT_EQ(result->size(), 2U);
    EXPECT_TRUE(result->contains("geolocation"_s));
    valueAndParameters = result->get("geolocation"_s);
    auto* valueList = std::get_if<RFC8941::InnerList>(&valueAndParameters.first);
    EXPECT_TRUE(!!valueList);
    EXPECT_EQ(valueList->size(), 2U);
    EXPECT_TRUE(valueList->at(0).second.map().isEmpty());
    auto* token = std::get_if<RFC8941::Token>(&valueList->at(0).first);
    EXPECT_TRUE(!!token);
    EXPECT_EQ("self"_s, token->string());
    EXPECT_TRUE(valueList->at(1).second.map().isEmpty());
    auto* urlString = std::get_if<String>(&valueList->at(1).first);
    EXPECT_TRUE(!!urlString);
    EXPECT_EQ("https://example.com"_s, *urlString);
    EXPECT_TRUE(result->contains("camera"_s));
    valueAndParameters = result->get("camera"_s);
    valueList = std::get_if<RFC8941::InnerList>(&valueAndParameters.first);
    EXPECT_TRUE(!!valueList);
    EXPECT_TRUE(valueList->isEmpty());

    result = RFC8941::parseDictionaryStructuredFieldValue("count=42"_s);
    EXPECT_TRUE(!!result);
    EXPECT_EQ(result->size(), 1U);
    EXPECT_TRUE(result->contains("count"_s));
    valueAndParameters = result->get("count"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    auto* intValue = std::get_if<int64_t>(bareItem);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 42);

    result = RFC8941::parseDictionaryStructuredFieldValue("ratio=1.5"_s);
    EXPECT_TRUE(!!result);
    EXPECT_TRUE(result->contains("ratio"_s));
    valueAndParameters = result->get("ratio"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    auto* decimalValue = std::get_if<double>(bareItem);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 1.5);

    result = RFC8941::parseDictionaryStructuredFieldValue("count=42, ratio=1.5, offset=-10"_s);
    EXPECT_TRUE(!!result);
    EXPECT_EQ(result->size(), 3U);
    EXPECT_TRUE(result->contains("count"_s));
    valueAndParameters = result->get("count"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    intValue = std::get_if<int64_t>(bareItem);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 42);
    EXPECT_TRUE(result->contains("ratio"_s));
    valueAndParameters = result->get("ratio"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    decimalValue = std::get_if<double>(bareItem);
    EXPECT_TRUE(!!decimalValue);
    EXPECT_DOUBLE_EQ(*decimalValue, 1.5);
    EXPECT_TRUE(result->contains("offset"_s));
    valueAndParameters = result->get("offset"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    intValue = std::get_if<int64_t>(bareItem);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, -10);

    // A key may begin with "*" per RFC 9651 section 4.2.3.3 (key = ( lcalpha / "*" ) *(...)).
    result = RFC8941::parseDictionaryStructuredFieldValue("*foo=1"_s);
    EXPECT_TRUE(!!result);
    EXPECT_EQ(result->size(), 1U);
    EXPECT_TRUE(result->contains("*foo"_s));
    valueAndParameters = result->get("*foo"_s);
    bareItem = std::get_if<RFC8941::BareItem>(&valueAndParameters.first);
    EXPECT_TRUE(!!bareItem);
    intValue = std::get_if<int64_t>(bareItem);
    EXPECT_TRUE(!!intValue);
    EXPECT_EQ(*intValue, 1);

    // A "*"-initial parameter key must also be accepted.
    result = RFC8941::parseDictionaryStructuredFieldValue("count=42; *note=?1"_s);
    EXPECT_TRUE(!!result);
    EXPECT_TRUE(result->contains("count"_s));
    valueAndParameters = result->get("count"_s);
    EXPECT_EQ(valueAndParameters.second.map().size(), 1U);
    auto* paramBoolean = valueAndParameters.second.getIf<bool>("*note"_s);
    EXPECT_TRUE(!!paramBoolean);
    EXPECT_TRUE(*paramBoolean);
}

static String structuredFieldDictionary(unsigned count, const String& last)
{
    StringBuilder builder;
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(", "_s);
        if (i + 1 == count && !last.isNull())
            builder.append('k', i, '=', last);
        else
            builder.append('k', i, '=', i);
    }
    return builder.toString();
}

static String repeatedLetters(unsigned count)
{
    StringBuilder builder;
    for (unsigned i = 0; i < count; ++i)
        builder.append('a');
    return builder.toString();
}

static String sixteenBitString(const String& string)
{
    Vector<char16_t> characters;
    for (auto character : StringView(string).codeUnits())
        characters.append(character);
    return String(characters.span());
}

TEST(RFC8941, ParseValuesWithManyParametersAndMembers)
{
    for (unsigned count : { 15u, 16u, 30u, 31u, 32u }) {
        StringBuilder builder;
        builder.append('a');
        for (unsigned i = 0; i < count; ++i)
            builder.append(";p"_s, i, '=', i);
        auto result = RFC8941::parseItemStructuredFieldValue(builder.toString());
        ASSERT_TRUE(!!result);
        auto* token = std::get_if<RFC8941::Token>(&result->first);
        ASSERT_TRUE(!!token);
        EXPECT_EQ("a"_s, token->string());
        EXPECT_EQ(result->second.map().size(), count);
        auto last = result->second.map().find(makeString('p', count - 1));
        ASSERT_TRUE(last != result->second.map().end());
        auto* lastValue = std::get_if<int64_t>(&last->value);
        ASSERT_TRUE(!!lastValue);
        EXPECT_EQ(*lastValue, static_cast<int64_t>(count - 1));
    }

    for (unsigned count : { 15u, 16u, 17u, 31u, 32u, 33u }) {
        auto result = RFC8941::parseDictionaryStructuredFieldValue(structuredFieldDictionary(count, { }));
        ASSERT_TRUE(!!result);
        EXPECT_EQ(result->size(), count);
        auto key = makeString('k', count - 1);
        EXPECT_TRUE(result->contains(key));
        auto last = result->get(key);
        auto* bareItem = std::get_if<RFC8941::BareItem>(&last.first);
        ASSERT_TRUE(!!bareItem);
        auto* lastValue = std::get_if<int64_t>(bareItem);
        ASSERT_TRUE(!!lastValue);
        EXPECT_EQ(*lastValue, static_cast<int64_t>(count - 1));
    }

    for (unsigned count : { 29u, 30u, 31u, 32u }) {
        StringBuilder builder;
        builder.append("k0=("_s);
        for (unsigned i = 0; i < count; ++i)
            builder.append(i ? " a"_s : "a"_s, i);
        builder.append(')');
        auto result = RFC8941::parseDictionaryStructuredFieldValue(builder.toString());
        ASSERT_TRUE(!!result);
        EXPECT_EQ(result->size(), 1U);
        auto member = result->get("k0"_s);
        auto* list = std::get_if<RFC8941::InnerList>(&member.first);
        ASSERT_TRUE(!!list);
        EXPECT_EQ(list->size(), count);
    }

    auto bytes = RFC8941::parseDictionaryStructuredFieldValue(structuredFieldDictionary(33, ":AQID:"_s));
    ASSERT_TRUE(!!bytes);
    EXPECT_EQ(bytes->size(), 33U);
    auto bytesMember = bytes->get("k32"_s);
    auto* bytesItem = std::get_if<RFC8941::BareItem>(&bytesMember.first);
    ASSERT_TRUE(!!bytesItem);
    auto* byteSequence = std::get_if<Vector<uint8_t>>(bytesItem);
    ASSERT_TRUE(!!byteSequence);
    EXPECT_EQ(*byteSequence, Vector<uint8_t>({ 1, 2, 3 }));

    // A byte sequence that does not decode fails the value.
    EXPECT_FALSE(!!RFC8941::parseDictionaryStructuredFieldValue(structuredFieldDictionary(33, ":!!:"_s)));
    EXPECT_FALSE(!!RFC8941::parseDictionaryStructuredFieldValue(structuredFieldDictionary(32, ":!!:"_s)));

    auto wide = RFC8941::parseDictionaryStructuredFieldValue(structuredFieldDictionary(33, String(std::span<const char16_t>(u"\"\x0100\"", 3))));
    ASSERT_TRUE(!!wide);
    EXPECT_EQ(wide->size(), 33U);
    auto wideMember = wide->get("k32"_s);
    auto* wideItem = std::get_if<RFC8941::BareItem>(&wideMember.first);
    ASSERT_TRUE(!!wideItem);
    auto* wideString = std::get_if<String>(wideItem);
    ASSERT_TRUE(!!wideString);
    EXPECT_EQ(wideString->length(), 1U);
    EXPECT_FALSE(wideString->is8Bit());
    EXPECT_EQ((*wideString)[0], 0x0100);
}

TEST(RFC8941, ParseStringsWithEscapes)
{
    // Strings of 63, 64 and 65 characters once unescaped. A string is 16-bit only when it has a character above U+00FF.
    for (unsigned length : { 63u, 64u, 65u }) {
        auto letters = makeString(repeatedLetters(length - 1), '"');
        auto escaped = RFC8941::parseItemStructuredFieldValue(makeString('"', repeatedLetters(length - 1), "\\\"\""_s));
        ASSERT_TRUE(!!escaped);
        auto* escapedString = std::get_if<String>(&escaped->first);
        ASSERT_TRUE(!!escapedString);
        EXPECT_EQ(letters, *escapedString);
        EXPECT_TRUE(escapedString->is8Bit());

        auto sixteenBit = RFC8941::parseItemStructuredFieldValue(sixteenBitString(makeString('"', repeatedLetters(length), '"')));
        ASSERT_TRUE(!!sixteenBit);
        auto* sixteenBitItem = std::get_if<String>(&sixteenBit->first);
        ASSERT_TRUE(!!sixteenBitItem);
        EXPECT_EQ(repeatedLetters(length), *sixteenBitItem);
        EXPECT_TRUE(sixteenBitItem->is8Bit());

        auto sixteenBitEscaped = RFC8941::parseItemStructuredFieldValue(sixteenBitString(makeString('"', repeatedLetters(length - 1), "\\\"\""_s)));
        ASSERT_TRUE(!!sixteenBitEscaped);
        auto* sixteenBitEscapedString = std::get_if<String>(&sixteenBitEscaped->first);
        ASSERT_TRUE(!!sixteenBitEscapedString);
        EXPECT_EQ(letters, *sixteenBitEscapedString);
        EXPECT_TRUE(sixteenBitEscapedString->is8Bit());

        auto wideLetters = makeString(repeatedLetters(length - 2), static_cast<char16_t>(0x0100));
        auto wide = RFC8941::parseItemStructuredFieldValue(makeString('"', wideLetters, "\\\\\""_s));
        ASSERT_TRUE(!!wide);
        auto* wideString = std::get_if<String>(&wide->first);
        ASSERT_TRUE(!!wideString);
        EXPECT_EQ(makeString(wideLetters, '\\'), *wideString);
        EXPECT_EQ(wideString->length(), length);
        EXPECT_FALSE(wideString->is8Bit());
    }
}

TEST(RFC8941, EscapeString)
{
    auto plain = RFC8941::escapeString("abc"_s);
    ASSERT_TRUE(!!plain);
    EXPECT_EQ("abc"_s, *plain);
    auto quoted = RFC8941::escapeString("a\"b\\c"_s);
    ASSERT_TRUE(!!quoted);
    EXPECT_EQ("a\\\"b\\\\c"_s, *quoted);
    auto empty = RFC8941::escapeString(emptyString());
    ASSERT_TRUE(!!empty);
    EXPECT_FALSE(empty->isNull());
    EXPECT_TRUE(empty->isEmpty());
    EXPECT_FALSE(!!RFC8941::escapeString("tab\there"_s));
    EXPECT_FALSE(!!RFC8941::escapeString(String(std::span<const char16_t>(u"a\x0100", 2))));

    // Results of 63, 64 and 65 characters, which are 8-bit.
    for (unsigned length : { 63u, 64u, 65u }) {
        auto characters = repeatedLetters(length - 2);
        auto escaped = RFC8941::escapeString(makeString(characters, '"'));
        ASSERT_TRUE(!!escaped);
        EXPECT_EQ(makeString(characters, "\\\""_s), *escaped);

        auto sixteenBitEscaped = RFC8941::escapeString(sixteenBitString(makeString(characters, '"')));
        ASSERT_TRUE(!!sixteenBitEscaped);
        EXPECT_EQ(makeString(characters, "\\\""_s), *sixteenBitEscaped);
        EXPECT_TRUE(sixteenBitEscaped->is8Bit());

        auto sixteenBit = RFC8941::escapeString(sixteenBitString(makeString(characters, "aa"_s)));
        ASSERT_TRUE(!!sixteenBit);
        EXPECT_EQ(makeString(characters, "aa"_s), *sixteenBit);
        EXPECT_TRUE(sixteenBit->is8Bit());
    }
}

TEST(HTTPParsers, RequestHeaderAppendDelimiter)
{
    static constexpr std::pair<ASCIILiteral, ASCIILiteral> appendableHeaders[] {
        { "Accept"_s, ", "_s },
        { "Accept-Encoding"_s, ", "_s },
        { "Accept-Language"_s, ", "_s },
        { "Access-Control-Request-Headers"_s, ", "_s },
        { "Cache-Control"_s, ", "_s },
        { "Connection"_s, ", "_s },
        { "Content-Language"_s, ", "_s },
        { "Cookie"_s, "; "_s },
        { "Forwarded"_s, ", "_s },
        { "If-Match"_s, ", "_s },
        { "If-None-Match"_s, ", "_s },
        { "Keep-Alive"_s, ", "_s },
        { "Range"_s, ", "_s },
        { "TE"_s, ", "_s },
        { "Trailer"_s, ""_s },
        { "Transfer-Encoding"_s, ", "_s },
        { "Upgrade"_s, ", "_s },
        { "User-Agent"_s, " "_s },
        { "Via"_s, ", "_s },
        { "Want-Digest"_s, ", "_s },
        { "X-Forwarded-For"_s, ", "_s }
    };

    for (auto& [name, delimiter] : appendableHeaders) {
        auto result = requestHeaderAppendDelimiter(String { name });
        EXPECT_TRUE(result.has_value());
        EXPECT_STREQ(result.value_or("missing"_s).characters(), delimiter.characters());
    }

    EXPECT_STREQ(requestHeaderAppendDelimiter("accept-language"_s)->characters(), ", ");
    EXPECT_STREQ(requestHeaderAppendDelimiter("X-FORWARDED-FOR"_s)->characters(), ", ");

    EXPECT_FALSE(requestHeaderAppendDelimiter("Content-Type"_s).has_value());
    EXPECT_FALSE(requestHeaderAppendDelimiter("Authorization"_s).has_value());
    EXPECT_FALSE(requestHeaderAppendDelimiter("X-Custom"_s).has_value());
    EXPECT_FALSE(requestHeaderAppendDelimiter(" Accept"_s).has_value());
    EXPECT_FALSE(requestHeaderAppendDelimiter(emptyString()).has_value());
}

TEST(HTTPParsers, RequestHeaderUnsafeToModify)
{
    for (auto name : { "Available-Dictionary"_s, "Content-Length"_s, "Cookie2"_s, "Host"_s, "Keep-Alive"_s, "Set-Cookie"_s, "TE"_s, "Trailer"_s, "Transfer-Encoding"_s, "Upgrade"_s })
        EXPECT_TRUE(isRequestHeaderUnsafeToModify(String { name }, "1"_s));

    EXPECT_TRUE(isRequestHeaderUnsafeToModify("host"_s, "example.com"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("CONTENT-LENGTH"_s, "0"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Proxy-Authorization"_s, "Basic abc"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("proxy-connection"_s, "close"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Proxy-"_s, "1"_s));

    for (auto name : { "Accept"_s, "Authorization"_s, "Cookie"_s, "Origin"_s, "Referer"_s, "User-Agent"_s, "Via"_s, "Sec-GPC"_s, "X-Request-Id"_s, "Proxy"_s, "X-Proxy-Id"_s })
        EXPECT_FALSE(isRequestHeaderUnsafeToModify(String { name }, "1"_s));

    EXPECT_FALSE(isRequestHeaderUnsafeToModify(emptyString(), "1"_s));
}

TEST(HTTPParsers, RequestHeaderUnsafeToModifyValues)
{
    // Connection only allows close and keep-alive.
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Connection"_s, "close"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Connection"_s, "keep-alive"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("connection"_s, "Close, Keep-Alive"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Connection"_s, ""_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Connection"_s, "upgrade"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Connection"_s, "close, X-Secret"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Connection"_s, "Authorization"_s));

    // Accept-Encoding can't use shared dictionary encodings or a wildcard.
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Accept-Encoding"_s, "gzip, deflate, br"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Accept-Encoding"_s, "gzip;q=1.0, identity; q=0.5"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Accept-Encoding"_s, ""_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Accept-Encoding"_s, "*"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Accept-Encoding"_s, "identity;q=1, *;q=0"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("accept-encoding"_s, "gzip, DCB"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("Accept-Encoding"_s, "dcz;q=0.9, gzip"_s));

    // Method override headers can't name a forbidden method.
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("X-HTTP-Method-Override"_s, "PUT"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("X-Method-Override"_s, "patch, delete"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("X-HTTP-Method-Override"_s, "TRACE"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("x-http-method"_s, "get, connect"_s));
    EXPECT_TRUE(isRequestHeaderUnsafeToModify("X-Method-Override"_s, "Track"_s));

    // The same values are fine on other headers.
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("X-Custom"_s, "TRACE"_s));
    EXPECT_FALSE(isRequestHeaderUnsafeToModify("Accept"_s, "*"_s));
}

static Vector<LinkHeader> linkHeaders(const String& header)
{
    Vector<LinkHeader> links;
    for (auto& link : LinkHeaderSet(header))
        links.append(link);
    return links;
}

// Each delimiter the Link parser looks for, from 0 to 16 characters after where it starts looking, in 8-bit and 16-bit
// strings, and after a 16-bit character whose low byte is that delimiter.
TEST(HTTPParsers, LinkHeaderDelimiterOffsets)
{
    for (unsigned length = 0; length <= 16; ++length) {
        auto letters = repeatedLetters(length);
        for (bool is16Bit : { false, true }) {
            auto parse = [&](const String& header) {
                return linkHeaders(is16Bit ? sixteenBitString(header) : header);
            };

            auto links = parse(makeString('<', letters, ">; rel=preload; as=style"_s));
            ASSERT_EQ(links.size(), 1u);
            EXPECT_TRUE(links[0].valid());
            EXPECT_EQ(links[0].url().length(), length);
            EXPECT_EQ(links[0].as(), "style"_s);

            // The URL's '>' ends the header.
            links = parse(makeString('<', letters, '>'));
            ASSERT_EQ(links.size(), 1u);
            EXPECT_TRUE(links[0].valid());
            EXPECT_EQ(links[0].url().length(), length);

            for (auto quote : { '"', '\'' }) {
                links = parse(makeString("<u>; rel="_s, quote, letters, quote, "; as=style"_s));
                ASSERT_EQ(links.size(), 1u);
                EXPECT_EQ(links[0].rel().length(), length);
                EXPECT_EQ(links[0].as(), "style"_s);
            }

            for (auto end : { "\t; rel=next"_s, " ; rel=next"_s, ";rel=next"_s, ", <v>; rel=next"_s }) {
                links = parse(makeString("<u>; as="_s, letters, end));
                ASSERT_EQ(links.size(), end[0] == ',' ? 2u : 1u);
                EXPECT_EQ(links[0].as().length(), length);
                EXPECT_EQ(links.last().rel(), "next"_s);
            }

            links = parse(makeString("<u> "_s, letters, ",<v>; rel=next"_s));
            ASSERT_EQ(links.size(), 2u);
            EXPECT_EQ(links[1].rel(), "next"_s);
        }

        auto links = linkHeaders(makeString('<', letters, char16_t(0x013E), ">; rel=preload"_s));
        ASSERT_EQ(links.size(), 1u);
        EXPECT_EQ(links[0].url(), makeString(letters, char16_t(0x013E)));

        links = linkHeaders(makeString("<u>; rel=\""_s, letters, char16_t(0x0122), "\"; as=style"_s));
        ASSERT_EQ(links.size(), 1u);
        EXPECT_EQ(links[0].rel(), makeString(letters, char16_t(0x0122)));

        for (char16_t lookalike : { char16_t(0x0109), char16_t(0x0120), char16_t(0x013B), char16_t(0x012C) }) {
            links = linkHeaders(makeString("<u>; as="_s, letters, lookalike, "x; rel=next"_s));
            ASSERT_EQ(links.size(), 1u);
            EXPECT_EQ(links[0].as(), makeString(letters, lookalike, 'x'));
            EXPECT_EQ(links[0].rel(), "next"_s);
        }

        links = linkHeaders(makeString("<u> "_s, letters, char16_t(0x012C), "x,<v>; rel=next"_s));
        ASSERT_EQ(links.size(), 2u);
        EXPECT_EQ(links[1].rel(), "next"_s);
    }
}

// parseHTTPDate's result is WTF::parseDate's on the date's UTF-8.
static std::optional<WallTime> parseDateFromUTF8(const String& date)
{
    double milliseconds = WTF::parseDate(byteCast<Latin1Character>(date.utf8().span()));
    if (!std::isfinite(milliseconds))
        return std::nullopt;
    return WallTime::fromRawSeconds(milliseconds / 1000.0);
}

// Dates of 38 to 46 characters, in GMT, with an offset and in local time, valid and not, in 8-bit and 16-bit strings,
// padded with characters that take 1 to 4 bytes in UTF-8.
TEST(HTTPParsers, ParseHTTPDateLengths)
{
    for (unsigned length = 38; length <= 46; ++length) {
        for (auto date : { ", 06 Nov 1994 08:49:37 GMT"_s, ", 06 Nov 1994 08:49:37 +0100"_s, ", 06 Nov 1994 08:49:37"_s, ", 32 Nov 1994 08:49:37 GMT"_s, ", 32 Nov 1994 08:49:37"_s }) {
            for (char16_t pad : { char16_t(' '), char16_t(0x00E9), char16_t(0x4E00), char16_t(0xD800), char16_t(0xD83D) }) {
                StringBuilder builder;
                while (builder.length() + date.length() < length) {
                    if (pad == 0xD83D && builder.length() + date.length() + 2 <= length) {
                        builder.append(char16_t(0xD83D));
                        builder.append(char16_t(0xDE00));
                    } else if (pad <= 0xFF)
                        builder.append(static_cast<char>(pad));
                    else
                        builder.append(pad == 0xD83D ? char16_t('S') : pad);
                }
                builder.append(date);
                auto string = builder.toString();
                ASSERT_EQ(string.length(), length);
                EXPECT_EQ(string.is8Bit(), pad <= 0xFF);
                auto expected = parseDateFromUTF8(string);
                EXPECT_EQ(parseHTTPDate(string), expected);
                if (string.is8Bit())
                    EXPECT_EQ(parseHTTPDate(sixteenBitString(string)), expected);
                if (StringView(date).contains("32 Nov"_s))
                    EXPECT_FALSE(expected);
                else if (StringView(date).endsWith(" GMT"_s))
                    EXPECT_EQ(expected, WallTime::fromRawSeconds(784111777));
                else
                    EXPECT_TRUE(expected);
            }
        }
        StringBuilder threeByteCharacters;
        for (unsigned i = 0; i < length; ++i)
            threeByteCharacters.append(char16_t(0x4E00));
        EXPECT_FALSE(parseHTTPDate(threeByteCharacters.toString()));
    }
}

// Names one character shorter and longer than the forbidden and privileged ones, in 8-bit and 16-bit strings.
TEST(HTTPParsers, ForbiddenNameLengths)
{
    auto check = [](ASCIILiteral name, bool forbiddenResponseHeaderName, bool privilegedNoCORSRequestHeaderName, bool forbiddenMethod) {
        for (auto& string : { String { name }, sixteenBitString(name) }) {
            EXPECT_EQ(isForbiddenResponseHeaderName(string), forbiddenResponseHeaderName) << name.characters();
            EXPECT_EQ(isPriviledgedNoCORSRequestHeaderName(string), privilegedNoCORSRequestHeaderName) << name.characters();
            EXPECT_EQ(isForbiddenMethod(string), forbiddenMethod) << name.characters();
        }
    };
    check("Set-Cooki"_s, false, false, false);
    check("Set-Cookie"_s, true, false, false);
    check("set-cookie2"_s, true, false, false);
    check("Set-Cookies"_s, false, false, false);
    check("Set-Cookie22"_s, false, false, false);
    check("Rang"_s, false, false, false);
    check("RANGE"_s, false, true, false);
    check("Ranges"_s, false, false, false);
    check("Trac"_s, false, false, false);
    check("trace"_s, false, false, true);
    check("TRACK"_s, false, false, true);
    check("Tracks"_s, false, false, false);
    check("Connec"_s, false, false, false);
    check("CONNECT"_s, false, false, true);
    check("Connects"_s, false, false, false);
    check(""_s, false, false, false);
}

// "charset" at each offset from 3 to 40, whole, at the end of the value or one character short, in 8-bit and 16-bit
// strings, and after code units that match 'c' or 'C' in one byte or in their low seven bits.
TEST(HTTPParsers, ExtractCharsetFromMediaTypeOffsets)
{
    for (unsigned offset = 3; offset <= 40; ++offset) {
        auto prefix = makeString("a/"_s, repeatedLetters(offset - 3), ';');
        for (auto& value : { makeString(prefix, "charset=utf-8"_s), sixteenBitString(makeString(prefix, "CHARSET=utf-8"_s)) })
            EXPECT_EQ(extractCharsetFromMediaType(value).toString(), "utf-8"_s) << offset;
        for (auto& value : { makeString(prefix, "charset"_s), makeString(prefix, "charse"_s), sixteenBitString(makeString(prefix, "charse"_s)) })
            EXPECT_TRUE(extractCharsetFromMediaType(value).isEmpty()) << offset;
    }
    for (char16_t character : { 0x00C3, 0x00E3, 0x0143, 0x0163, 0x4300, 0x6300, 0xFF43 }) {
        auto value = makeString("text/html;"_s, character, "harset=x;charset=utf-8"_s);
        EXPECT_EQ(extractCharsetFromMediaType(value).toString(), "utf-8"_s) << static_cast<unsigned>(character);
    }
    EXPECT_EQ(extractCharsetFromMediaType("cccccccccccccccccccc;charset=utf-8"_s).toString(), "utf-8"_s);
}

// A quoted Server-Timing value of 63, 64 and 65 characters between the quotes, with and without escapes.
TEST(HTTPParsers, ServerTimingQuotedValueLengths)
{
    auto parse = [](const String& value) {
        EXPECT_TRUE(value.is8Bit());
        auto entries = ServerTimingParser::parseServerTiming(value);
        EXPECT_EQ(entries.size(), 1u);
        return entries.isEmpty() ? ServerTiming { String() } : entries[0];
    };
    for (unsigned length : { 63u, 64u, 65u }) {
        auto entry = parse(makeString("m;desc=\""_s, repeatedLetters(length), "\";dur="_s, length));
        EXPECT_EQ(entry.description, repeatedLetters(length));
        EXPECT_TRUE(entry.description.is8Bit());
        EXPECT_EQ(entry.duration, static_cast<double>(length));

        entry = parse(makeString("m;desc=\"\\b"_s, repeatedLetters(length - 4), '\\', static_cast<char16_t>(0xE9), '"'));
        EXPECT_EQ(entry.description, makeString('b', repeatedLetters(length - 4), static_cast<char16_t>(0xE9)));
        EXPECT_TRUE(entry.description.is8Bit());
        EXPECT_FALSE(entry.durationSet);

        StringBuilder zeros;
        for (unsigned i = 0; i < length - 4; ++i)
            zeros.append('0');
        entry = parse(makeString("m;dur=\""_s, zeros.toString(), "\\1.5\""_s));
        EXPECT_EQ(entry.duration, 1.5);
        EXPECT_TRUE(entry.durationSet);

        entry = parse(makeString("m;desc=\""_s, repeatedLetters(length - 1), '\\'));
        EXPECT_TRUE(entry.description.isNull());
        EXPECT_TRUE(entry.descriptionSet);
    }

#if !ASSERT_ENABLED
    // parseServerTiming() asserts that the header is 8-bit. Without assertions, a 16-bit header gives the same values,
    // and a quoted value is 8-bit when it is Latin-1.
    auto parse16 = [](const String& value) {
        auto entries = ServerTimingParser::parseServerTiming(sixteenBitString(value));
        EXPECT_EQ(entries.size(), 1u);
        return entries.isEmpty() ? ServerTiming { String() } : entries[0];
    };
    for (unsigned length : { 63u, 64u, 65u }) {
        auto entry = parse16(makeString("m;desc=\""_s, repeatedLetters(length), "\";dur="_s, length));
        EXPECT_EQ(entry.description, repeatedLetters(length));
        EXPECT_TRUE(entry.description.is8Bit());
        EXPECT_EQ(entry.duration, static_cast<double>(length));

        entry = parse16(makeString("m;desc=\"\\b"_s, repeatedLetters(length - 4), '\\', static_cast<char16_t>(0xE9), '"'));
        EXPECT_EQ(entry.description, makeString('b', repeatedLetters(length - 4), static_cast<char16_t>(0xE9)));
        EXPECT_TRUE(entry.description.is8Bit());
        EXPECT_FALSE(entry.durationSet);

        entry = parse16(makeString("m;desc=\"\\"_s, static_cast<char16_t>(0x0100), repeatedLetters(length - 2), "\";dur="_s, length));
        EXPECT_EQ(entry.description, makeString(static_cast<char16_t>(0x0100), repeatedLetters(length - 2)));
        EXPECT_FALSE(entry.description.is8Bit());
        EXPECT_EQ(entry.duration, static_cast<double>(length));

        StringBuilder zeros;
        for (unsigned i = 0; i < length - 4; ++i)
            zeros.append('0');
        entry = parse16(makeString("m;dur=\""_s, zeros.toString(), "\\1.5\""_s));
        EXPECT_EQ(entry.duration, 1.5);
        EXPECT_TRUE(entry.durationSet);

        entry = parse16(makeString("m;desc=\""_s, repeatedLetters(length - 1), '\\'));
        EXPECT_TRUE(entry.description.isNull());
        EXPECT_TRUE(entry.descriptionSet);
    }
#endif
}

// The characters that end a token, a header value, and a header line's name and value, at offsets 0 to 33, and wide
// characters whose low byte is one of them.
TEST(HTTPParsers, CharacterScanOffsets)
{
    auto parse = [](const String& line, bool strict, String& name, String& value) {
        auto bytes = line.utf8();
        String failureReason;
        StringView nameView;
        size_t consumed = parseHTTPHeader(byteCast<uint8_t>(bytes.span()), failureReason, nameView, value, strict);
        name = nameView.toString();
        return consumed;
    };
    for (unsigned offset = 0; offset <= 33; ++offset) {
        auto letters = repeatedLetters(offset);
        for (auto& token : { letters, sixteenBitString(letters) }) {
            EXPECT_EQ(isValidHTTPToken(token), offset > 0) << offset;
            EXPECT_EQ(isValidHTTPToken(StringView(token)), offset > 0) << offset;
            for (char16_t character : { u' ', u'"', u',', u';', u'}', u'\x7F', u'\x80', u'\u0161', u'\u4100' }) {
                EXPECT_FALSE(isValidHTTPToken(makeString(token, character, "abc"_s))) << offset << ' ' << static_cast<unsigned>(character);
                EXPECT_FALSE(isValidHTTPToken(makeString(token, character))) << offset << ' ' << static_cast<unsigned>(character);
            }
            EXPECT_TRUE(isValidHTTPHeaderValue(makeString('a', token, "\x01\x7F,;"_s))) << offset;
            for (char16_t character : { 0x00, 0x0A, 0x0D }) {
                EXPECT_FALSE(isValidHTTPHeaderValue(makeString('a', token, character, 'a'))) << offset << ' ' << static_cast<unsigned>(character);
                EXPECT_FALSE(isValidHTTPHeaderValue(makeString('a', token, character))) << offset << ' ' << static_cast<unsigned>(character);
            }
            for (char16_t character : { 0x0100, 0x010A, 0x010D, 0x0A00, 0x0D00 })
                EXPECT_TRUE(isValidHTTPHeaderValue(makeString('a', token, character, 'a'))) << offset << ' ' << static_cast<unsigned>(character);
        }

        String name, value;
        auto line = makeString('n', letters, ": v"_s, letters, "\r\nnext: line\r\n"_s);
        EXPECT_EQ(parse(line, true, name, value), 2 * offset + 5) << offset;
        EXPECT_EQ(name, makeString('n', letters)) << offset;
        EXPECT_EQ(value, makeString('v', letters)) << offset;
        EXPECT_EQ(parse(makeString('n', letters, ": v"_s, letters, "\nx"_s), true, name, value), 0u) << offset;
        EXPECT_EQ(parse(makeString('n', letters, ": v"_s, letters, "\nx"_s), false, name, value), 2 * offset + 5) << offset;
        EXPECT_EQ(parse(makeString('n', letters, ": v"_s, letters, "\rx"_s), true, name, value), 0u) << offset;
        EXPECT_EQ(parse(makeString('n', letters, '"', ": v\r\n"_s), true, name, value), 0u) << offset;
        EXPECT_EQ(parse(makeString('n', letters, ": v"_s, letters, static_cast<char16_t>(0x010A), "\r\n"_s), true, name, value), 2 * offset + 7) << offset;
        EXPECT_EQ(value, makeString('v', letters, static_cast<char16_t>(0x010A))) << offset;
    }
}

// Each Cache-Control directive in either case, near misses of each, and characters at the edges of the separators.
TEST(HTTPParsers, CacheControlDirectiveNames)
{
    auto parse = [](const String& value) {
        HTTPHeaderMap headers;
        headers.set("Cache-Control"_s, value);
        return parseCacheControlDirectives(headers);
    };
    for (auto value : {
        "no-cache, no-store, public, must-revalidate, max-age=1, max-stale, min-fresh=2, immutable, stale-while-revalidate=3"_s,
        "No-Cache, NO-STORE, PUBLIC, Must-Revalidate, MAX-AGE=1, max-STALE, MIN-fresh=2, IMMUTABLE, STALE-while-REVALIDATE=3"_s }) {
        for (auto& string : { String { value }, sixteenBitString(value) }) {
            auto directives = parse(string);
            EXPECT_TRUE(directives.noCache);
            EXPECT_TRUE(directives.noStore);
            EXPECT_TRUE(directives.isPublic);
            EXPECT_TRUE(directives.mustRevalidate);
            EXPECT_TRUE(directives.immutable);
            EXPECT_TRUE(directives.maxAge == Seconds { 1 });
            EXPECT_TRUE(directives.maxStale == Seconds::infinity());
            EXPECT_TRUE(directives.minFresh == Seconds { 2 });
            EXPECT_TRUE(directives.staleWhileRevalidate == Seconds { 3 });
        }
    }
    for (auto value : {
        "no-cachf, no-stord, publid, must-revalidatf, max-agf=1, max-stalf, min-fresi=2, immutablf, stale-while-revalidatf=3"_s,
        "no-cach, no-storee, publi, max-ag=1, max-stales, min-fres=2, immutables, nax-age=4, mix-age=5, max-stald=6"_s }) {
        for (auto& string : { String { value }, sixteenBitString(value) }) {
            auto directives = parse(string);
            EXPECT_FALSE(directives.noCache || directives.noStore || directives.isPublic || directives.mustRevalidate || directives.immutable);
            EXPECT_FALSE(directives.maxAge || directives.maxStale || directives.minFresh || directives.staleWhileRevalidate);
        }
    }
    // A character whose low 7 or 8 bits are a separator's does not end a name.
    for (char16_t character : { 0x00AC, 0x00BB, 0x00BD, 0x00C0, 0x00FD, 0x012C, 0x013D, 0x017D }) {
        auto directives = parse(makeString("public"_s, character, ", max-age"_s, character, '5'));
        EXPECT_FALSE(directives.isPublic) << static_cast<unsigned>(character);
        EXPECT_FALSE(directives.maxAge) << static_cast<unsigned>(character);
    }
    for (char character : { '?', '@', '}' })
        EXPECT_TRUE(parse(makeString("public"_s, character, 'x')).isPublic) << character;
    EXPECT_FALSE(parse("public~"_s).isPublic);
}

TEST(HTTPParsers, DigitRunLengths)
{
    // Values of 18 and 19 digits and at uint64_t's limit, with and without leading zeros.
    struct Case {
        ASCIILiteral digits;
        std::optional<uint64_t> value;
    };
    const Case cases[] = {
        { "99999999999999999"_s, 99999999999999999ull },
        { "999999999999999999"_s, 999999999999999999ull },
        { "1000000000000000000"_s, 1000000000000000000ull },
        { "9999999999999999999"_s, 9999999999999999999ull },
        { "18446744073709551615"_s, 18446744073709551615ull },
        { "18446744073709551616"_s, std::nullopt },
        { "99999999999999999999"_s, std::nullopt },
        { "000000000000000001"_s, 1 },
        { "0000000000000000001"_s, 1 },
        { "000000000000000000000000000018446744073709551615"_s, 18446744073709551615ull },
        { "000000000000000000000000000018446744073709551616"_s, std::nullopt },
    };
    for (auto& testCase : cases) {
        String eightBit = testCase.digits;
        for (auto& digits : { eightBit, sixteenBitString(eightBit) }) {
            auto start = parseRange(makeString("bytes="_s, digits, '-'), RangeAllowWhitespace::No);
            EXPECT_EQ(!!start, !!testCase.value) << testCase.digits;
            if (start && testCase.value) {
                EXPECT_TRUE(start->start == testCase.value) << testCase.digits;
                EXPECT_FALSE(start->end) << testCase.digits;
            }
            auto end = parseRange(makeString("bytes = 0 - "_s, digits), RangeAllowWhitespace::Yes);
            EXPECT_EQ(!!end, !!testCase.value) << testCase.digits;
            if (end && testCase.value) {
                EXPECT_EQ(end->start, 0u) << testCase.digits;
                EXPECT_TRUE(end->end == testCase.value) << testCase.digits;
            }
            EXPECT_TRUE(parseContentLength(digits) == testCase.value) << testCase.digits;
            EXPECT_TRUE(parseContentLength(makeString(digits, ',', digits)) == testCase.value) << testCase.digits;
            EXPECT_TRUE(parseContentLength(makeString(" +"_s, digits, " ,"_s, digits)) == testCase.value) << testCase.digits;
        }
    }
    // A value that does not parse is skipped before the first one that does, and fails the header after it.
    EXPECT_EQ(parseContentLength("18446744073709551616,5"_s), 5u);
    EXPECT_FALSE(parseContentLength("5,18446744073709551616"_s));
    EXPECT_FALSE(parseContentLength("999999999999999999,1000000000000000000"_s));
}

TEST(HTTPParsers, HeaderLineFailureReasonLengths)
{
    // The longest message that takes a sample, with a sample of 128 bytes, and of 129, which is cut with an ellipsis.
    for (unsigned length : { 128u, 129u }) {
        auto sample = repeatedLetters(length);
        auto line = makeString("a: b\r"_s, sample).utf8();
        String failureReason;
        StringView name;
        String value;
        EXPECT_EQ(parseHTTPHeader(byteCast<uint8_t>(line.span()), failureReason, name, value, true), 0u) << length;
        if (length == 128) {
            EXPECT_EQ(failureReason, makeString("CR doesn't follow LF after header value at "_s, sample));
            EXPECT_EQ(failureReason.length(), 171u);
            EXPECT_TRUE(failureReason.is8Bit());
        } else {
            EXPECT_EQ(failureReason, makeString("CR doesn't follow LF after header value at "_s, repeatedLetters(128), static_cast<char16_t>(0x2026)));
            EXPECT_EQ(failureReason.length(), 172u);
            EXPECT_FALSE(failureReason.is8Bit());
        }
    }
}

} // namespace TestWebKitAPI
