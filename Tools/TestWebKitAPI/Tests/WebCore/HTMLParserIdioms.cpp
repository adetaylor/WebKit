/*
 * Copyright (C) 2016-2017 Apple Inc. All rights reserved.
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
#include <WebCore/DateComponents.h>
#include <WebCore/DocumentFragment.h>
#include <WebCore/Element.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/HTMLBodyElement.h>
#include <WebCore/HTMLDivElement.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLDocumentParserFastPath.h>
#include <WebCore/HTMLHtmlElement.h>
#include <WebCore/HTMLInputElement.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/HTMLParserIdioms.h>
#include <WebCore/HTMLSrcsetParser.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/ParserContentPolicy.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/Settings.h>
#include <WebCore/Text.h>
#include <wtf/DateMath.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

using namespace WebCore;

namespace TestWebKitAPI {

static int testParseHTMLInteger(StringView input)
{
    auto optionalResult = parseHTMLInteger(input);
    EXPECT_TRUE(!!optionalResult);
    return optionalResult.value_or(0);
}

static bool parseHTMLIntegerFails(StringView input)
{
    return !parseHTMLInteger(input);
}

TEST(WebCoreHTMLParserIdioms, parseHTMLInteger)
{
    EXPECT_EQ(0, testParseHTMLInteger("0"_s));
    EXPECT_EQ(0, testParseHTMLInteger("-0"_s));
    EXPECT_EQ(0, testParseHTMLInteger("+0"_s));
    EXPECT_EQ(123, testParseHTMLInteger("123"_s));
    EXPECT_EQ(123, testParseHTMLInteger("+123"_s));
    EXPECT_EQ(-123, testParseHTMLInteger("-123"_s));
    EXPECT_EQ(123, testParseHTMLInteger("  123"_s));
    EXPECT_EQ(123, testParseHTMLInteger("123   "_s));
    EXPECT_EQ(123, testParseHTMLInteger("   123   "_s));
    EXPECT_EQ(123, testParseHTMLInteger("123abc"_s));
    EXPECT_EQ(-123, testParseHTMLInteger("-123abc"_s));
    EXPECT_EQ(123, testParseHTMLInteger("  +123"_s));
    EXPECT_EQ(-123, testParseHTMLInteger("  -123"_s));
    EXPECT_EQ(12, testParseHTMLInteger("   12 3"_s));
    EXPECT_EQ(1, testParseHTMLInteger("1.0"_s));
    EXPECT_EQ(1, testParseHTMLInteger("1."_s));
    EXPECT_EQ(1, testParseHTMLInteger("1e1"_s));

    // All HTML whitespaces.
    EXPECT_EQ(123, testParseHTMLInteger(" \t\r\n\f123"_s));

    // Boundaries.
    EXPECT_EQ(-2147483648, testParseHTMLInteger("-2147483648"_s));
    EXPECT_EQ(2147483647, testParseHTMLInteger("2147483647"_s));

    // Failure cases.
    EXPECT_TRUE(parseHTMLIntegerFails("-2147483649"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("2147483648"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("111111111111111111"_s));
    EXPECT_TRUE(parseHTMLIntegerFails(""_s));
    EXPECT_TRUE(parseHTMLIntegerFails(" "_s));
    EXPECT_TRUE(parseHTMLIntegerFails("   "_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+ 123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("- 123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("a"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-a"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+-123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-+123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("++123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("--123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("\v123"_s)); // '\v' is an ASCII space but not an HTML whitespace.
    EXPECT_TRUE(parseHTMLIntegerFails("a123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("+a123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("-a123"_s));
    EXPECT_TRUE(parseHTMLIntegerFails(".1"_s));
    EXPECT_TRUE(parseHTMLIntegerFails("infinity"_s));
}

static unsigned testParseHTMLNonNegativeInteger(StringView input)
{
    auto optionalResult = parseHTMLNonNegativeInteger(input);
    EXPECT_TRUE(!!optionalResult);
    return optionalResult.value_or(0);
}

static bool parseHTMLNonNegativeIntegerFails(StringView input)
{
    return !parseHTMLNonNegativeInteger(input);
}

TEST(WebCoreHTMLParserIdioms, parseHTMLNonNegativeInteger)
{
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("123"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("+123"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("  123"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("123   "_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("   123   "_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("123abc"_s));
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger("  +123"_s));
    EXPECT_EQ(12u, testParseHTMLNonNegativeInteger("   12 3"_s));
    EXPECT_EQ(1u, testParseHTMLNonNegativeInteger("1.0"_s));
    EXPECT_EQ(1u, testParseHTMLNonNegativeInteger("1."_s));
    EXPECT_EQ(1u, testParseHTMLNonNegativeInteger("1e1"_s));

    // All HTML whitespaces.
    EXPECT_EQ(123u, testParseHTMLNonNegativeInteger(" \t\r\n\f123"_s));

    // Boundaries.
    EXPECT_EQ(0u, testParseHTMLNonNegativeInteger("+0"_s));
    EXPECT_EQ(0u, testParseHTMLNonNegativeInteger("0"_s));
    EXPECT_EQ(0u, testParseHTMLNonNegativeInteger("-0"_s));
    EXPECT_EQ(2147483647u, testParseHTMLNonNegativeInteger("2147483647"_s));

    // Failure cases.
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-1"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("2147483648"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("2147483649"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("111111111111111111"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("  -123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-123abc"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails(""_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails(" "_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("   "_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+ 123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("- 123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("a"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-a"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+-123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-+123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("++123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("--123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("\v123"_s)); // '\v' is an ASCII space but not an HTML whitespace.
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("a123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("+a123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("-a123"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails(".1"_s));
    EXPECT_TRUE(parseHTMLNonNegativeIntegerFails("infinity"_s));
}

TEST(WebCoreHTMLParserIdioms, parseHTMLDimensionsList)
{
    auto empty = parseHTMLDimensionsList(""_s);
    EXPECT_TRUE(empty.isEmpty());

    auto whitespaceOnly = parseHTMLDimensionsList("   "_s);
    EXPECT_EQ(1u, whitespaceOnly.size());
    EXPECT_FLOAT_EQ(0, whitespaceOnly[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceOnly[0].unit);

    auto singleIntegralAbsolute = parseHTMLDimensionsList("15"_s);
    EXPECT_EQ(1u, singleIntegralAbsolute.size());
    EXPECT_FLOAT_EQ(15.0, singleIntegralAbsolute[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, singleIntegralAbsolute[0].unit);

    auto singleFloatingAbsolute = parseHTMLDimensionsList("15.05"_s);
    EXPECT_EQ(1u, singleFloatingAbsolute.size());
    EXPECT_FLOAT_EQ(15.05, singleFloatingAbsolute[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, singleFloatingAbsolute[0].unit);

    auto singleIntegralRelative = parseHTMLDimensionsList("15*"_s);
    EXPECT_EQ(1u, singleIntegralRelative.size());
    EXPECT_FLOAT_EQ(15.0, singleIntegralRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, singleIntegralRelative[0].unit);

    auto singleFloatingRelative = parseHTMLDimensionsList("15.05*"_s);
    EXPECT_EQ(1u, singleFloatingRelative.size());
    EXPECT_FLOAT_EQ(15.05, singleFloatingRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, singleFloatingRelative[0].unit);

    auto singleIntegralPercentage = parseHTMLDimensionsList("15%"_s);
    EXPECT_EQ(1u, singleIntegralPercentage.size());
    EXPECT_FLOAT_EQ(15.0, singleIntegralPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, singleIntegralPercentage[0].unit);

    auto singleFloatingPercentage = parseHTMLDimensionsList("15.05%"_s);
    EXPECT_EQ(1u, singleFloatingPercentage.size());
    EXPECT_FLOAT_EQ(15.05, singleFloatingPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, singleFloatingPercentage[0].unit);

    auto whitespaceBeforeIntegralRelative = parseHTMLDimensionsList("15.05  *"_s);
    EXPECT_EQ(1u, whitespaceBeforeIntegralRelative.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceBeforeIntegralRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceBeforeIntegralRelative[0].unit);

    auto whitespaceBeforeFloatingRelative = parseHTMLDimensionsList("15.05  *"_s);
    EXPECT_EQ(1u, whitespaceBeforeFloatingRelative.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceBeforeFloatingRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceBeforeFloatingRelative[0].unit);

    auto whitespaceBeforeIntegralPercentage = parseHTMLDimensionsList("15  %"_s);
    EXPECT_EQ(1u, whitespaceBeforeIntegralPercentage.size());
    EXPECT_FLOAT_EQ(15.0, whitespaceBeforeIntegralPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, whitespaceBeforeIntegralPercentage[0].unit);

    auto whitespaceBeforeFloatingPercentage = parseHTMLDimensionsList("15.05  %"_s);
    EXPECT_EQ(1u, whitespaceBeforeFloatingPercentage.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceBeforeFloatingPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, whitespaceBeforeFloatingPercentage[0].unit);

    auto whitespaceInFractionalAbsolute = parseHTMLDimensionsList("15. 0   5  "_s);
    EXPECT_EQ(1u, whitespaceInFractionalAbsolute.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceInFractionalAbsolute[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, whitespaceInFractionalAbsolute[0].unit);

    auto whitespaceInFractionalRelative = parseHTMLDimensionsList("15. 0   5  *"_s);
    EXPECT_EQ(1u, whitespaceInFractionalRelative.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceInFractionalRelative[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceInFractionalRelative[0].unit);

    auto whitespaceInFractionalPercentage = parseHTMLDimensionsList("15. 0   5  %"_s);
    EXPECT_EQ(1u, whitespaceInFractionalPercentage.size());
    EXPECT_FLOAT_EQ(15.05, whitespaceInFractionalPercentage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, whitespaceInFractionalPercentage[0].unit);

    auto leadingWhitespace = parseHTMLDimensionsList("  15.05 %"_s);
    EXPECT_EQ(1u, leadingWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, leadingWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, leadingWhitespace[0].unit);

    auto trailingWhitespace = parseHTMLDimensionsList("15.05 %  "_s);
    EXPECT_EQ(1u, trailingWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, trailingWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, trailingWhitespace[0].unit);

    auto largeIntegralPart = parseHTMLDimensionsList("8589934592.05%"_s);
    EXPECT_EQ(1u, largeIntegralPart.size());
    EXPECT_FLOAT_EQ(1.0, largeIntegralPart[0].number); // Falls back to "1*"
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, largeIntegralPart[0].unit);

    auto largeFractionalPart = parseHTMLDimensionsList("1.8589934592%"_s);
    EXPECT_EQ(1u, largeFractionalPart.size());
    EXPECT_FLOAT_EQ(1.0, largeFractionalPart[0].number); // Falls back to "1*"
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, largeFractionalPart[0].unit);

    auto twoValuesNoWhitespace = parseHTMLDimensionsList("15.05%,10*"_s);
    EXPECT_EQ(2u, twoValuesNoWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, twoValuesNoWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, twoValuesNoWhitespace[0].unit);
    EXPECT_FLOAT_EQ(10.0, twoValuesNoWhitespace[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, twoValuesNoWhitespace[1].unit);

    auto twoValuesWhitespace = parseHTMLDimensionsList("   15.05%  ,  10*  "_s);
    EXPECT_EQ(2u, twoValuesWhitespace.size());
    EXPECT_FLOAT_EQ(15.05, twoValuesWhitespace[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, twoValuesWhitespace[0].unit);
    EXPECT_FLOAT_EQ(10.0, twoValuesWhitespace[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, twoValuesWhitespace[1].unit);

    auto lastCharacterComma = parseHTMLDimensionsList("15.05%, 10* ,"_s);
    EXPECT_EQ(2u, lastCharacterComma.size());
    EXPECT_FLOAT_EQ(15.05, lastCharacterComma[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, lastCharacterComma[0].unit);
    EXPECT_FLOAT_EQ(10.0, lastCharacterComma[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, lastCharacterComma[1].unit);

    auto trailingGarbage = parseHTMLDimensionsList("15.05 % adfa, 10* +]"_s);
    EXPECT_EQ(2u, trailingGarbage.size());
    EXPECT_FLOAT_EQ(15.05, trailingGarbage[0].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Percentage, trailingGarbage[0].unit);
    EXPECT_FLOAT_EQ(10.0, trailingGarbage[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, trailingGarbage[1].unit);

    auto whitespaceBeforeDot = parseHTMLDimensionsList("15 .05 %, 10*"_s);
    EXPECT_EQ(2u, whitespaceBeforeDot.size());
    EXPECT_FLOAT_EQ(15.0, whitespaceBeforeDot[0].number); // Everything from after 15 to the comma is skipped.
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Absolute, whitespaceBeforeDot[0].unit);
    EXPECT_FLOAT_EQ(10.0, whitespaceBeforeDot[1].number);
    EXPECT_EQ(HTMLDimensionsListValue::Unit::Relative, whitespaceBeforeDot[1].unit);
}

TEST(WebCoreHTMLParserIdioms, parseHTMLFloatingPointNumberValue)
{
    // Each value is the one the same digits give as a C++ literal: correctly rounded.
    EXPECT_EQ(9007199254740992.0, parseHTMLFloatingPointNumberValue("9007199254740992"_s));
    EXPECT_EQ(9007199254740993.0, parseHTMLFloatingPointNumberValue("9007199254740993"_s));
    EXPECT_EQ(-9007199254740993.0, parseHTMLFloatingPointNumberValue("-9007199254740993"_s));
    EXPECT_EQ(1234567890123456789.0, parseHTMLFloatingPointNumberValue("1234567890123456789"_s));
    EXPECT_EQ(12345678901234567890.0, parseHTMLFloatingPointNumberValue("12345678901234567890"_s));
    EXPECT_EQ(1e22, parseHTMLFloatingPointNumberValue("1e22"_s));
    EXPECT_EQ(1e23, parseHTMLFloatingPointNumberValue("1e23"_s));
    EXPECT_EQ(1e-22, parseHTMLFloatingPointNumberValue("1e-22"_s));
    EXPECT_EQ(1e-23, parseHTMLFloatingPointNumberValue("1e-23"_s));
    EXPECT_EQ(3e-22, parseHTMLFloatingPointNumberValue("0.0000000000000000000003"_s));
    EXPECT_EQ(3e-23, parseHTMLFloatingPointNumberValue("0.00000000000000000000003"_s));
    EXPECT_EQ(0.1, parseHTMLFloatingPointNumberValue("0.1"_s));
    EXPECT_EQ(1234.5, parseHTMLFloatingPointNumberValue("1234.5"_s));
    EXPECT_EQ(-12345.25, parseHTMLFloatingPointNumberValue("-12345.25"_s));
    EXPECT_EQ(1.5, parseHTMLFloatingPointNumberValue(" 1.5"_s));
    EXPECT_EQ(0.5, parseHTMLFloatingPointNumberValue("000.5"_s));
    EXPECT_EQ(1e5, parseHTMLFloatingPointNumberValue("1.e5"_s));
    EXPECT_EQ(0.5, parseHTMLFloatingPointNumberValue(".5"_s));
    EXPECT_EQ(-0.5, parseHTMLFloatingPointNumberValue("-.5"_s));
    EXPECT_EQ(5.0, parseHTMLFloatingPointNumberValue("+5"_s));
    EXPECT_EQ(1.0, parseHTMLFloatingPointNumberValue("1e"_s));
    EXPECT_EQ(1.0, parseHTMLFloatingPointNumberValue("1e+"_s));
    EXPECT_EQ(7.5, parseHTMLFloatingPointNumberValue("-"_s, 7.5));
    EXPECT_EQ(7.5, parseHTMLFloatingPointNumberValue("+"_s, 7.5));
    EXPECT_EQ(7.5, parseHTMLFloatingPointNumberValue("."_s, 7.5));
    EXPECT_EQ(7.5, parseHTMLFloatingPointNumberValue("e5"_s, 7.5));
}

TEST(WebCoreHTMLParserIdioms, parseHTMLListOfOfFloatingPointNumberValues)
{
    EXPECT_EQ(Vector<double>(), parseHTMLListOfOfFloatingPointNumberValues(""_s));
    EXPECT_EQ(Vector<double>(), parseHTMLListOfOfFloatingPointNumberValues(" ,;"_s));

    // As many numbers as a list of that length can have.
    EXPECT_EQ(Vector<double>({ 7 }), parseHTMLListOfOfFloatingPointNumberValues("7"_s));
    EXPECT_EQ(Vector<double>({ 1, 2, 3 }), parseHTMLListOfOfFloatingPointNumberValues("1,2;3"_s));
    EXPECT_EQ(Vector<double>({ 1, 2 }), parseHTMLListOfOfFloatingPointNumberValues("1 2,"_s));
    EXPECT_EQ(Vector<double>({ 0, 0, 0 }), parseHTMLListOfOfFloatingPointNumberValues("x;y z"_s));
    static constexpr char16_t sixteenBit[] = { '1', ',', '2', ';', '.', '5' };
    EXPECT_EQ(Vector<double>({ 1, 2, 0.5 }), parseHTMLListOfOfFloatingPointNumberValues(StringView(std::span { sixteenBit })));

    // Fewer numbers than a list of that length can have, by 16 and by 17.
    EXPECT_EQ(Vector<double>({ 7 }), parseHTMLListOfOfFloatingPointNumberValues("                                7"_s));
    EXPECT_EQ(Vector<double>({ 7 }), parseHTMLListOfOfFloatingPointNumberValues("                                  7"_s));
    EXPECT_EQ(Vector<double>({ 1, 0, 2 }), parseHTMLListOfOfFloatingPointNumberValues("1,abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz,2"_s));
}

// The value `parse` finds in `string`, as its toString(), or "invalid"; the same as an 8-bit and as a 16-bit string.
static String parseDateComponents(std::optional<DateComponents> (*parse)(StringView), StringView string)
{
    Vector<char16_t> sixteenBit;
    for (auto character : string.codeUnits())
        sixteenBit.append(character);
    auto eightBitResult = parse(string);
    auto sixteenBitResult = parse(StringView(sixteenBit.span()));
    EXPECT_EQ(!!eightBitResult, !!sixteenBitResult);
    if (!eightBitResult || !sixteenBitResult)
        return "invalid"_s;
    EXPECT_EQ(eightBitResult->toString(), sixteenBitResult->toString());
    return eightBitResult->toString();
}

TEST(WebCoreHTMLParserIdioms, DateComponentsFromParsing)
{
    // Each type at the lengths of a 4-digit year and 2-digit fields, and one character shorter and longer.
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingMonth, "2020-1"_s));
    EXPECT_EQ("2020-01"_s, parseDateComponents(DateComponents::fromParsingMonth, "2020-01"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingMonth, "2020-011"_s));
    EXPECT_EQ("12345-01"_s, parseDateComponents(DateComponents::fromParsingMonth, "12345-01"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingMonth, "0000-01"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingMonth, "2020-13"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDate, "2020-01-1"_s));
    EXPECT_EQ("2020-01-31"_s, parseDateComponents(DateComponents::fromParsingDate, "2020-01-31"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDate, "2020-01-011"_s));
    EXPECT_EQ("10000-01-01"_s, parseDateComponents(DateComponents::fromParsingDate, "10000-01-01"_s));
    EXPECT_EQ("2024-02-29"_s, parseDateComponents(DateComponents::fromParsingDate, "2024-02-29"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDate, "1900-02-29"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDate, "2020-04-31"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDate, "2020-01/01"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingWeek, "2020-W1"_s));
    EXPECT_EQ("2020-W53"_s, parseDateComponents(DateComponents::fromParsingWeek, "2020-W53"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingWeek, "2021-W53"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingWeek, "2020-W011"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingWeek, "2020-w01"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingTime, "1:00"_s));
    EXPECT_EQ("23:59"_s, parseDateComponents(DateComponents::fromParsingTime, "23:59"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingTime, "12:000"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingTime, "12:00:0"_s));
    EXPECT_EQ("23:59:59"_s, parseDateComponents(DateComponents::fromParsingTime, "23:59:59"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingTime, "12:00:000"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingTime, "24:00"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingTime, "23:59:60"_s));
    EXPECT_EQ("12:00:00.5"_s, parseDateComponents(DateComponents::fromParsingTime, "12:00:00.5"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01T10:0"_s));
    EXPECT_EQ("2020-01-01T10:00"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01T10:00"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01T10:000"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01T10:00:0"_s));
    EXPECT_EQ("2020-01-01T23:59:59"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01 23:59:59"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01T10:00:000"_s));
    EXPECT_EQ("invalid"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "2020-01-01t10:00"_s));
    EXPECT_EQ("12345-01-01T10:00"_s, parseDateComponents(DateComponents::fromParsingDateTimeLocal, "12345-01-01T10:00"_s));

    // 16-bit characters whose low byte is a digit, '-', ':', 'T' or 'W'.
    static constexpr char16_t month[] = { '2', '0', '2', '0', '-', '0', 0x0131 };
    EXPECT_FALSE(DateComponents::fromParsingMonth(StringView(std::span { month })));
    static constexpr char16_t date[] = { '2', '0', '2', '0', 0x012D, '0', '1', '-', '0', '1' };
    EXPECT_FALSE(DateComponents::fromParsingDate(StringView(std::span { date })));
    static constexpr char16_t time[] = { '1', '0', 0x013A, '0', '0' };
    EXPECT_FALSE(DateComponents::fromParsingTime(StringView(std::span { time })));
    static constexpr char16_t week[] = { '2', '0', '2', '0', '-', 0x0157, '0', '1' };
    EXPECT_FALSE(DateComponents::fromParsingWeek(StringView(std::span { week })));
    static constexpr char16_t dateTimeLocal[] = { '2', '0', '2', '0', '-', '0', '1', '-', '0', '1', 0x0154, '1', '0', ':', '0', '0' };
    EXPECT_FALSE(DateComponents::fromParsingDateTimeLocal(StringView(std::span { dateTimeLocal })));
}

// The value `convert` finds for `ms`, as its toString(SecondFormat::Millisecond), or "invalid".
static String dateComponentsFromMilliseconds(std::optional<DateComponents> (*convert)(double), double ms)
{
    auto result = convert(ms);
    return result ? result->toString(SecondFormat::Millisecond) : "invalid"_s;
}

TEST(WebCoreHTMLParserIdioms, DateComponentsFromMilliseconds)
{
    // Each side of 2^53 ms, above which not every whole number of milliseconds is a double, and of the day boundaries
    // around it, of 8.64e15 ms and of 2^26 days, after and before the epoch.
    struct Expected {
        double ms;
        ASCIILiteral date;
        ASCIILiteral dateTimeLocal;
        ASCIILiteral month;
        ASCIILiteral week;
        ASCIILiteral time;
        double dateMilliseconds;
    };
    static constexpr Expected cases[] = {
        { 9007199254740991, "287396-10-12"_s, "287396-10-12T08:59:00.991"_s, "invalid"_s, "invalid"_s, "08:59:00.991"_s, 9007199222400000 },
        { 9007199254740992, "287396-10-12"_s, "287396-10-12T08:59:00.992"_s, "invalid"_s, "invalid"_s, "08:59:00.992"_s, 9007199222400000 },
        { 9007199254740994, "287396-10-12"_s, "287396-10-12T08:59:00.994"_s, "invalid"_s, "invalid"_s, "08:59:00.994"_s, 9007199222400000 },
        { 8639999999999999, "275760-09-12"_s, "275760-09-12T23:59:59.999"_s, "275760-09"_s, "275760-W37"_s, "23:59:59.999"_s, 8639999913600000 },
        { 8640000000000000, "275760-09-13"_s, "275760-09-13T00:00:00.0"_s, "275760-09"_s, "275760-W37"_s, "00:00:00.0"_s, 8640000000000000 },
        { 8640000000000001, "275760-09-13"_s, "invalid"_s, "275760-09"_s, "275760-W37"_s, "00:00:00.001"_s, 8640000000000000 },
        { 9007199222399999, "287396-10-11"_s, "287396-10-11T23:59:59.999"_s, "invalid"_s, "invalid"_s, "23:59:59.999"_s, 9007199136000000 },
        { 9007199222400000, "287396-10-12"_s, "287396-10-12T00:00:00.0"_s, "invalid"_s, "invalid"_s, "00:00:00.0"_s, 9007199222400000 },
        { 9007199308799998, "287396-10-12"_s, "287396-10-12T23:59:59.998"_s, "invalid"_s, "invalid"_s, "23:59:59.998"_s, 9007199222400000 },
        { 9007199308800000, "287396-10-13"_s, "287396-10-13T00:00:00.0"_s, "invalid"_s, "invalid"_s, "00:00:00.0"_s, 9007199308800000 },
        { 5798205849599999, "185707-10-30"_s, "185707-10-30T23:59:59.999"_s, "185707-10"_s, "185707-W43"_s, "23:59:59.999"_s, 5798205763200000 },
        { 5798205849600000, "185707-10-31"_s, "185707-10-31T00:00:00.0"_s, "185707-10"_s, "185707-W44"_s, "00:00:00.0"_s, 5798205849600000 },
        { -9007199254740991, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "15:00:59.009"_s, 0 },
        { -9007199254740992, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "15:00:59.008"_s, 0 },
        { -9007199254740994, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "15:00:59.006"_s, 0 },
        { -8639999999999999, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.001"_s, 0 },
        { -8640000000000000, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.0"_s, 0 },
        { -8640000000000001, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "23:59:59.999"_s, 0 },
        { -9007199222399999, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.001"_s, 0 },
        { -9007199222400000, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.0"_s, 0 },
        { -9007199308799998, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.002"_s, 0 },
        { -9007199308800000, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.0"_s, 0 },
        { -5798205849599999, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.001"_s, 0 },
        { -5798205849600000, "invalid"_s, "invalid"_s, "invalid"_s, "invalid"_s, "00:00:00.0"_s, 0 },
    };
    for (auto& expected : cases) {
        EXPECT_EQ(String(expected.date), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDate, expected.ms));
        EXPECT_EQ(String(expected.dateTimeLocal), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDateTimeLocal, expected.ms));
        EXPECT_EQ(String(expected.month), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForMonth, expected.ms));
        EXPECT_EQ(String(expected.week), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForWeek, expected.ms));
        EXPECT_EQ(String(expected.time), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceMidnight, expected.ms));
        if (auto date = DateComponents::fromMillisecondsSinceEpochForDate(expected.ms))
            EXPECT_EQ(expected.dateMilliseconds, date->millisecondsSinceEpoch());
    }

    // The first and last milliseconds of each year from 1 to 1969, and of each of its Februaries.
    for (int year = 1; year < 1970; ++year) {
        double january1 = WTF::dateToDaysFrom1970(year, 0, 1) * WTF::msPerDay;
        double march1 = WTF::dateToDaysFrom1970(year, 2, 1) * WTF::msPerDay;
        EXPECT_EQ(makeString(pad('0', 4, year), "-01-01"_s), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDate, january1));
        EXPECT_EQ(year == 1 ? "invalid"_s : makeString(pad('0', 4, year - 1), "-12-31T23:59:59.999"_s),
            dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDateTimeLocal, january1 - 1));
        EXPECT_EQ(makeString(pad('0', 4, year), "-03-01T00:00:00.001"_s), dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDateTimeLocal, march1 + 1));
        EXPECT_EQ(makeString(pad('0', 4, year), WTF::isLeapYear(year) ? "-02-29"_s : "-02-28"_s),
            dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDate, march1 - 1));
        EXPECT_EQ(january1, DateComponents::fromMillisecondsSinceEpochForMonth(january1 + 1)->millisecondsSinceEpoch());
        EXPECT_EQ(march1 - WTF::msPerDay, DateComponents::fromMillisecondsSinceEpochForDate(march1 - 1)->millisecondsSinceEpoch());
    }
}

TEST(WebCoreHTMLParser, HTMLInputElementCheckedState)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div1 = HTMLDivElement::create(document);
    auto div2 = HTMLDivElement::create(document);
    document->body()->appendChild(div1);
    document->body()->appendChild(div2);

    // Set the state for new controls, which triggers a different code path in
    // HTMLInputElement::parseAttribute.
    div1->setInnerHTML("<select form='ff'></select>"_s);
    auto documentState = document->formController().formElementsState(document.get());
    document->formController().setStateForNewFormElements(documentState);
    EXPECT_TRUE(!document->formController().formElementsState(document.get()).isEmpty());
    div2->setInnerHTML("<input checked='true'>"_s);
    auto inputElement = downcast<HTMLInputElement>(div2->firstChild());
    ASSERT_TRUE(inputElement);
    EXPECT_TRUE(inputElement->checked());
}

TEST(WebCoreHTMLParser, FastPathComplexHTMLEntityParsing)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto testFastParser = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto textChild = dynamicDowncast<Text>(fragment->firstChild());
        EXPECT_TRUE(textChild);
        return textChild ? textChild->data() : String();
    };

    EXPECT_EQ(testFastParser("Price: 12&cent; only"_s), String::fromUTF8("Price: 12¢ only"));
    EXPECT_EQ(testFastParser("Genius Nicer Dicer Plus | 18&nbsp&hellip;"_s), String::fromUTF8("Genius Nicer Dicer Plus | 18 …"));
    EXPECT_EQ(testFastParser("&nbsp&a"_s), String::fromUTF8(" &a"));
    EXPECT_EQ(testFastParser("&nbsp&"_s), String::fromUTF8(" &"));
    EXPECT_EQ(testFastParser("&nbsp-"_s), String::fromUTF8(" -"));
    EXPECT_EQ(testFastParser("food & water"_s), String("food & water"_s));
}

TEST(WebCoreHTMLParser, FastPathHandlesLi)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<div><li></li></div>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_TRUE(result);
    EXPECT_EQ("DIV"_s, fragment->firstChild()->nodeName());
    EXPECT_EQ("LI"_s, fragment->firstChild()->firstChild()->nodeName());
}

TEST(WebCoreHTMLParser, FastPathFailsWithNestedLi)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<li><li></li></li>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_FALSE(result);
}

TEST(WebCoreHTMLParser, FastPathAttributeNameWithUnderscore)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // Underscore is valid in HTML attribute names but isValidAttributeNameChar() rejects it,
    // causing an unnecessary fallback to the slow parser.
    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<span data_value=\"test\"></span>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_TRUE(result);
}

TEST(WebCoreHTMLParser, FastPathEscapedAttributeValues)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto testFastParserAttribute = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            return String();
        auto* element = dynamicDowncast<Element>(fragment->firstChild());
        EXPECT_TRUE(element);
        return element ? element->getAttribute(HTMLNames::titleAttr) : String();
    };

    // Single entity (this works today).
    EXPECT_EQ("&"_s, testFastParserAttribute("<span title=\"&amp;\"></span>"_s));

    // Entity followed by more text — exercises the missing while loop in scanEscapedAttributeValue().
    EXPECT_EQ("&b"_s, testFastParserAttribute("<span title=\"&amp;b\"></span>"_s));

    // Text before and after an entity.
    EXPECT_EQ("a&b"_s, testFastParserAttribute("<span title=\"a&amp;b\"></span>"_s));

    // Multiple entities in a single attribute value.
    EXPECT_EQ("<&>"_s, testFastParserAttribute("<span title=\"&lt;&amp;&gt;\"></span>"_s));

    // Entity with trailing text and single-quote delimiter.
    EXPECT_EQ("a&b"_s, testFastParserAttribute("<span title='a&amp;b'></span>"_s));
}

TEST(WebCoreHTMLParser, FastPathRejectsNullInEscapedAttributeValue)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    // A \0 after an entity reaches scanEscapedAttributeValue's loop body.
    // The entity forces the SIMD fast scan to hand off to the escaped path,
    // and the \0 must be rejected there.
    auto fragment = DocumentFragment::create(document);
    bool result = tryFastParsingHTMLFragment("<span title=\"&amp;\0\"></span>"_s, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
    EXPECT_FALSE(result);
}

TEST(WebCoreHTMLParser, FastPathEntityWithoutSemicolonInAttributeValue)
{
    ProcessWarming::initializeNames();

    auto settings = Settings::create(nullptr);
    auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
    auto documentElement = HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = HTMLBodyElement::create(document);
    documentElement->appendChild(body);

    auto div = HTMLDivElement::create(document);
    document->body()->appendChild(div);

    auto testFastParserAttribute = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            return String();
        auto* element = dynamicDowncast<Element>(fragment->firstChild());
        EXPECT_TRUE(element);
        return element ? element->getAttribute(HTMLNames::titleAttr) : String();
    };

    // Per the HTML spec, named entities without a trailing semicolon followed by
    // an alphanumeric character must NOT be consumed in attribute values.
    // e.g. &ampX in an attribute should remain as literal "&ampX", not become "&X".
    EXPECT_EQ("&ampX"_s, testFastParserAttribute("<span title=\"&ampX\"></span>"_s));
    EXPECT_EQ("&ampX"_s, testFastParserAttribute("<span title='&ampX'></span>"_s));

    // Entity without semicolon followed by '=' should also not be consumed.
    EXPECT_EQ("&amp=1"_s, testFastParserAttribute("<span title=\"&amp=1\"></span>"_s));

    // Entity WITH semicolon followed by alphanumeric should still be consumed.
    EXPECT_EQ("&X"_s, testFastParserAttribute("<span title=\"&amp;X\"></span>"_s));

    // Entity without semicolon NOT followed by alphanumeric should be consumed.
    EXPECT_EQ("& "_s, testFastParserAttribute("<span title=\"&amp \"></span>"_s));

    // Named entity without semicolon (e.g. &AElig followed by alphanumeric).
    EXPECT_EQ("&AEligX"_s, testFastParserAttribute("<span title=\"&AEligX\"></span>"_s));

    // Named entity with semicolon (e.g. &AElig; followed by text).
    EXPECT_EQ(UTF8CString { u8"\xC3\x86X"_span }, testFastParserAttribute("<span title=\"&AElig;X\"></span>"_s).utf8());
}

TEST(WebCoreHTMLParserIdioms, parseImageCandidatesFromSrcsetAttribute)
{
    // A URL ends at its first whitespace character, and any other character up to U+0020 is part of it. Each such
    // character at the start, in the middle and at the end of URLs of 15 to 17 and 31 to 33 characters, either side of
    // a 16-character block.
    for (bool is8Bit : { true, false }) {
        for (unsigned length : { 15u, 16u, 17u, 31u, 32u, 33u }) {
            for (char16_t character = 0; character <= ' '; ++character) {
                for (unsigned position : { 0u, length / 2, length - 1 }) {
                    Vector<char16_t> characters(length, [&](size_t index) {
                        return index == position ? character : u'a';
                    });
                    characters.appendList({ ' ', '2', 'x' });
                    String srcset = is8Bit ? String(characters.map([](char16_t c) {
                        return Latin1Character(c);
                    }).span()) : String(characters.span());
                    auto candidates = parseImageCandidatesFromSrcsetAttribute(srcset);
                    bool endsURL = isASCIIWhitespace(character);
                    if (endsURL && position == length / 2) {
                        // The rest of the URL is a descriptor that is not valid.
                        EXPECT_TRUE(candidates.isEmpty());
                        continue;
                    }
                    ASSERT_EQ(1u, candidates.size());
                    EXPECT_EQ(endsURL ? length - 1 : length, candidates[0].string.view.length());
                    EXPECT_EQ(2.0f, candidates[0].density);
                }
            }
        }
    }
}

static String makeTestString(const Vector<char16_t>& characters, bool is8Bit)
{
    return is8Bit ? String(characters.map([](char16_t c) {
        return Latin1Character(c);
    }).span()) : String(characters.span());
}

TEST(WebCoreHTMLParserIdioms, parseMetaHTTPEquivRefreshQuotedURL)
{
    // A quoted URL ends at the next quote of its kind, or at the end when there is none. The closing quote at every
    // offset up to 33, either side of a 16-character block, with the other quote and, in 16-bit strings, U+0122 and
    // U+0127 before it.
    for (bool is8Bit : { true, false }) {
        for (char16_t quote : { u'\'', u'"' }) {
            for (unsigned offset = 0; offset <= 33; ++offset) {
                for (unsigned tailLength : { 0u, 1u, 17u }) {
                    for (bool isClosed : { true, false }) {
                        Vector<char16_t> characters { '0', ';', 'u', 'r', 'l', '=', quote };
                        for (unsigned i = 0; i < offset; ++i) {
                            char16_t otherQuote = quote == '\'' ? u'"' : u'\'';
                            characters.append(i % 3 ? (i % 3 == 1 || is8Bit ? u'a' : char16_t(quote + 0x100)) : otherQuote);
                        }
                        if (isClosed)
                            characters.append(quote);
                        for (unsigned i = 0; i < tailLength; ++i)
                            characters.append('b');
                        double delay = -1;
                        String url;
                        EXPECT_TRUE(parseMetaHTTPEquivRefresh(makeTestString(characters, is8Bit), delay, url));
                        EXPECT_EQ(0.0, delay);
                        EXPECT_EQ(isClosed ? offset : offset + tailLength, url.length());
                    }
                }
            }
        }
    }
}

TEST(WebCoreHTMLParserIdioms, parseMetaHTTPEquivRefreshURLLetters)
{
    // "url" is matched ignoring ASCII case. With any other character in place of one of its letters, the URL starts at
    // the first of them.
    for (bool is8Bit : { true, false }) {
        for (unsigned position = 0; position < 3; ++position) {
            char16_t lower = "url"[position];
            char16_t upper = "URL"[position];
            Vector<char16_t> replacements { lower, upper, char16_t(lower & ~0x40), char16_t(lower | 0x80), char16_t(upper | 0x80), 'x' };
            if (!is8Bit)
                replacements.appendList({ char16_t(lower + 0x100), char16_t(upper + 0x100), char16_t(lower + 0xFF00) });
            for (char16_t replacement : replacements) {
                Vector<char16_t> characters { '5', ';', 'u', 'r', 'l', '=', '/', 'a' };
                characters[2 + position] = replacement;
                double delay = -1;
                String url;
                EXPECT_TRUE(parseMetaHTTPEquivRefresh(makeTestString(characters, is8Bit), delay, url));
                EXPECT_EQ(5.0, delay);
                bool isLetter = replacement == lower || replacement == upper;
                EXPECT_EQ(isLetter ? 2u : 6u, url.length());
            }
        }
    }
}

TEST(WebCoreHTMLParserIdioms, parseHTMLDimensionsListCommas)
{
    // A list has one value more than its commas, after a last comma is dropped. A comma at each position of lists of
    // 15 to 17 and 31 to 33 characters, either side of a 16-character block, lists of commas only, and in 16-bit lists
    // U+012C, which is not a comma.
    for (bool is8Bit : { true, false }) {
        for (unsigned length : { 15u, 16u, 17u, 31u, 32u, 33u }) {
            for (unsigned position = 0; position < length; ++position) {
                Vector<char16_t> characters(length, [&](size_t index) {
                    return index == position ? u',' : (is8Bit || index % 2 ? u'1' : char16_t(0x012C));
                });
                EXPECT_EQ(position == length - 1 ? 1u : 2u, parseHTMLDimensionsList(makeTestString(characters, is8Bit)).size());
            }
            Vector<char16_t> commas(length, [](size_t) {
                return u',';
            });
            EXPECT_EQ(length, parseHTMLDimensionsList(makeTestString(commas, is8Bit)).size());
        }
    }
}

TEST(WebCoreHTMLParserIdioms, DateComponentsToStringTenDigitYear)
{
    // The conversions from milliseconds accept some years above maximumYear(), so the longest string is a local date
    // and time with milliseconds in a 10-digit year.
    EXPECT_EQ("2000000000-01-15T12:34:26.944"_s, dateComponentsFromMilliseconds(DateComponents::fromMillisecondsSinceEpochForDateTimeLocal, 6.3113841834035667e19));
}

TEST(WebCoreHTMLParserIdioms, bestFitSourceForImageAttributes)
{
    // 16 and 17 candidates (16, the inline capacity of pickBestImageCandidate()'s keys), listed from the highest
    // density down.
    for (unsigned count : { 16u, 17u }) {
        StringBuilder builder;
        for (unsigned density = count; density; --density)
            builder.append(density == count ? ""_s : ", "_s, 'c', density - 1, ".png "_s, density, 'x');
        String srcset = builder.toString();
        auto candidate = bestFitSourceForImageAttributes(1, String(), srcset, std::nullopt);
        EXPECT_EQ("c0.png"_s, candidate.string.view.toString());
        EXPECT_EQ(1.0f, candidate.density);
        candidate = bestFitSourceForImageAttributes(16.5, String(), srcset, std::nullopt);
        EXPECT_EQ(count == 17 ? "c16.png"_s : "c15.png"_s, candidate.string.view.toString());
        EXPECT_EQ(count == 17 ? 17.0f : 16.0f, candidate.density);
    }

    // With a width in the list, src is ignored: the pick steps back from it, then to the earliest candidate of the same
    // density.
    String srcset = "a.png 50w, b.png 50w"_s;
    auto candidate = bestFitSourceForImageAttributes(2, "s.png"_s, srcset, 100);
    EXPECT_EQ("a.png"_s, candidate.string.view.toString());
    EXPECT_EQ(0.5f, candidate.density);

    srcset = "a.png 1x, b.png 1.5x, c.png 1.5x"_s;
    candidate = bestFitSourceForImageAttributes(2, String(), srcset, std::nullopt);
    EXPECT_EQ("b.png"_s, candidate.string.view.toString());
    EXPECT_EQ(1.5f, candidate.density);
}

} // namespace TestWebKitAPI
