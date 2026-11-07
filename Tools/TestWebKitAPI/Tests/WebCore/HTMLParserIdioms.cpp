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
#include "TestPlatformStrategies.h"
#include <WebCore/DateComponents.h>
#include <WebCore/DocumentFragment.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/DocumentParser.h>
#include <WebCore/Element.h>
#include <WebCore/ElementInlines.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/HTMLBodyElement.h>
#include <WebCore/HTMLDivElement.h>
#include <WebCore/HTMLDocument.h>
#include <WebCore/HTMLDocumentParserFastPath.h>
#include <WebCore/HTMLHtmlElement.h>
#include <WebCore/HTMLInputElement.h>
#include <WebCore/HTMLNames.h>
#include <WebCore/HTMLParserIdioms.h>
#include <WebCore/HTMLToken.h>
#include <WebCore/HTMLTokenizer.h>
#include <WebCore/HTMLSrcsetParser.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/ParserContentPolicy.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/SegmentedString.h>
#include <WebCore/Settings.h>
#include <WebCore/Text.h>
#include <wtf/text/OrdinalNumber.h>
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

TEST(WebCoreHTMLParser, FastPathMixedCaseAttributeNames)
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

    // Names of 15, 16 and 17 characters, in 8-bit and 16-bit input. The 16-bit input ends with U+0141, whose low
    // byte is 'A'.
    for (bool is8Bit : { true, false }) {
        auto attributeNames = [&](ASCIILiteral markup) -> String {
            StringBuilder builder;
            builder.append(markup);
            if (!is8Bit)
                builder.append(static_cast<char16_t>(0x0141));
            auto input = builder.toString();
            EXPECT_EQ(is8Bit, input.is8Bit());
            auto fragment = DocumentFragment::create(document);
            bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
            EXPECT_TRUE(result);
            auto* element = result ? dynamicDowncast<Element>(fragment->firstChild()) : nullptr;
            EXPECT_TRUE(element);
            if (!element || !element->hasAttributes())
                return String();
            StringBuilder names;
            for (unsigned i = 0; i < element->attributeCount(); ++i) {
                if (i)
                    names.append(' ');
                names.append(element->attributeAt(i).localName());
            }
            return names.toString();
        };

        EXPECT_EQ("abcdefghijklmno"_s, attributeNames("<div ABCDEFGHIJKLMNo=1></div>"_s));
        EXPECT_EQ("abcdefghijklmnop"_s, attributeNames("<div aBcDeFgHiJkLmNoP=1></div>"_s));
        EXPECT_EQ("abcdefghijklmnopq"_s, attributeNames("<div ABCDEFGHIJKLMNOPQ=1></div>"_s));
        EXPECT_EQ("abcdefghijklmnopq abcdefghijklmnopr"_s, attributeNames("<div ABCDEFGHIJKLMNOPQ=1 abcdefghijklmnopR=2></div>"_s));
        EXPECT_EQ("abcdefghijklmnop abcdefghijklmnopq"_s, attributeNames("<div ABCDEFGHIJKLMNOP=1 ABCDEFGHIJKLMNOPQ=2></div>"_s));
        EXPECT_EQ("abcdefghijklmnop"_s, attributeNames("<div abcdefghijklmnop=1 ABCDEFGHIJKLMNOP=2></div>"_s));
        EXPECT_EQ("abcdefghijklmno-z"_s, attributeNames("<div Abcdefghijklmno-Z=1></div>"_s));
    }
}

TEST(WebCoreHTMLParser, FastPathNewlineThenSpaces)
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

    auto firstText = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto* text = result ? dynamicDowncast<Text>(fragment->firstChild()) : nullptr;
        EXPECT_TRUE(text);
        return text ? text->data() : String();
    };

    // Indents of 32, 33 and 40 spaces, in 8-bit and 16-bit input. The 16-bit input has U+0141 after it.
    for (unsigned spaces : { 32u, 33u, 40u }) {
        StringBuilder indent;
        indent.append('\n');
        for (unsigned i = 0; i < spaces; ++i)
            indent.append(' ');
        auto indentString = indent.toString();
        for (bool is8Bit : { true, false }) {
            StringBuilder builder;
            builder.append(indentString, "<b>"_s);
            if (!is8Bit)
                builder.append(static_cast<char16_t>(0x0141));
            builder.append("</b>"_s);
            auto input = builder.toString();
            EXPECT_EQ(is8Bit, input.is8Bit());
            EXPECT_EQ(indentString, firstText(input));
        }
    }

    // U+0120, whose low byte is a space, after 1, 16 and 20 spaces.
    for (unsigned spaces : { 1u, 16u, 20u }) {
        StringBuilder text;
        text.append('\n');
        for (unsigned i = 0; i < spaces; ++i)
            text.append(' ');
        text.append(static_cast<char16_t>(0x0120));
        for (unsigned i = 0; i < 19; ++i)
            text.append(' ');
        auto textString = text.toString();
        EXPECT_FALSE(textString.is8Bit());
        EXPECT_EQ(textString, firstText(makeString(textString, "<b></b>"_s)));
    }
}

TEST(WebCoreHTMLParser, FastPathDeeplyNestedElements)
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

    // 40 nested <span>s, each followed by a <b> after its end tag, in 8-bit and 16-bit input. The 16-bit input has
    // U+0141 in the innermost text.
    for (bool is8Bit : { true, false }) {
        StringBuilder builder;
        for (unsigned i = 0; i < 40; ++i)
            builder.append("<span>"_s);
        builder.append('x');
        if (!is8Bit)
            builder.append(static_cast<char16_t>(0x0141));
        for (unsigned i = 0; i < 40; ++i)
            builder.append("</span><b></b>"_s);
        auto input = builder.toString();
        EXPECT_EQ(is8Bit, input.is8Bit());

        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            continue;
        Node* node = fragment.ptr();
        for (unsigned depth = 0; depth < 40; ++depth) {
            node = node->firstChild();
            ASSERT_TRUE(node);
            EXPECT_EQ("SPAN"_s, node->nodeName());
            auto* next = node->nextSibling();
            ASSERT_TRUE(next);
            EXPECT_EQ("B"_s, next->nodeName());
            EXPECT_FALSE(next->nextSibling());
        }
        auto* text = dynamicDowncast<Text>(node->firstChild());
        ASSERT_TRUE(text);
        EXPECT_EQ(is8Bit ? 1u : 2u, text->length());
        EXPECT_FALSE(text->nextSibling());
    }
}

static String sixteenBitString(const String& string)
{
    Vector<char16_t> characters;
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return String(characters.span());
}

// The attributes of the first element in the body, after a document parse of `markup` appended in chunks of
// `chunkLength` characters.
static String parseFirstElementAttributes(const Settings& settings, const String& markup, unsigned chunkLength)
{
    auto document = HTMLDocument::create(nullptr, settings, aboutBlankURL());
    EXPECT_FALSE(document->open().hasException());
    for (unsigned i = 0; i < markup.length(); i += chunkLength) {
        RefPtr parser = document->parser();
        if (!parser)
            break;
        parser->appendSynchronously(RefPtr { markup.substring(i, chunkLength).impl() });
    }
    document->close();
    RefPtr body = document->body();
    RefPtr element = body ? dynamicDowncast<Element>(body->firstChild()) : nullptr;
    EXPECT_TRUE(element);
    if (!element)
        return String();
    StringBuilder builder;
    for (unsigned i = 0; i < element->attributeCount(); ++i) {
        if (i)
            builder.append(' ');
        builder.append(element->attributeAt(i).localName(), '=', element->attributeAt(i).value());
    }
    return builder.toString();
}

static String repeatedCharacter(char character, unsigned count)
{
    StringBuilder builder;
    for (unsigned i = 0; i < count; ++i)
        builder.append(character);
    return builder.toString();
}

TEST(WebCoreHTMLParser, FastPathLongEscapedText)
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

    auto parse = [&](const String& input) -> RefPtr<DocumentFragment> {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        return result ? RefPtr { fragment.ptr() } : nullptr;
    };

    // Text and attribute values that decode to 255, 256, 257 and 513 characters, with the character reference first
    // or last, in 8-bit and 16-bit input.
    for (unsigned length : { 255u, 256u, 257u, 513u }) {
        auto letters = repeatedCharacter('a', length - 1);
        for (bool referenceFirst : { true, false }) {
            auto escaped = referenceFirst ? makeString("&amp;"_s, letters) : makeString(letters, "&amp;"_s);
            auto decoded = referenceFirst ? makeString('&', letters) : makeString(letters, '&');
            for (bool is8Bit : { true, false }) {
                auto text = makeString(escaped, "<b></b>"_s);
                auto fragment = parse(is8Bit ? text : sixteenBitString(text));
                auto* textNode = fragment ? dynamicDowncast<Text>(fragment->firstChild()) : nullptr;
                EXPECT_TRUE(textNode);
                if (textNode)
                    EXPECT_EQ(decoded, textNode->data());

                auto attribute = makeString("<span title=\""_s, escaped, "\"></span>"_s);
                fragment = parse(is8Bit ? attribute : sixteenBitString(attribute));
                auto* element = fragment ? dynamicDowncast<Element>(fragment->firstChild()) : nullptr;
                EXPECT_TRUE(element);
                if (element)
                    EXPECT_EQ(decoded, element->getAttribute(HTMLNames::titleAttr));
            }
        }
    }
}

TEST(WebCoreHTMLParser, FastPathManyAttributes)
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

    auto attributes = [](const Node* node) -> String {
        auto* element = dynamicDowncast<Element>(node);
        EXPECT_TRUE(element);
        if (!element || !element->hasAttributes())
            return String();
        StringBuilder builder;
        for (unsigned i = 0; i < element->attributeCount(); ++i) {
            if (i)
                builder.append(' ');
            builder.append(element->attributeAt(i).localName(), '=', element->attributeAt(i).value());
        }
        return builder.toString();
    };

    // An element with 11 attributes, then one with 2, then one with a name that the first element has, in 8-bit and
    // 16-bit input.
    for (bool is8Bit : { true, false }) {
        auto markup = "<div a0=0 a1=1 a2=2 a3=3 a4=4 a5=5 a6=6 a7=7 a8=8 a9=9 a10=10></div><span x=1 y=2></span><b x=3 a5=4 y=5></b>"_s;
        auto input = is8Bit ? String(markup) : sixteenBitString(markup);
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        if (!result)
            continue;
        auto* first = fragment->firstChild();
        EXPECT_EQ("a0=0 a1=1 a2=2 a3=3 a4=4 a5=5 a6=6 a7=7 a8=8 a9=9 a10=10"_s, attributes(first));
        auto* second = first ? first->nextSibling() : nullptr;
        EXPECT_EQ("x=1 y=2"_s, attributes(second));
        auto* third = second ? second->nextSibling() : nullptr;
        EXPECT_EQ("x=3 a5=4 y=5"_s, attributes(third));
    }
}

TEST(WebCoreHTMLParser, FastPathAttributeValueAtWindowEnd)
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

    auto attributeValue = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto* element = result ? dynamicDowncast<Element>(fragment->firstChild()) : nullptr;
        EXPECT_TRUE(element);
        if (!element || !element->hasAttributes())
            return String();
        return element->attributeAt(0).value();
    };

    // Values that start 15, 16 and 17 characters after the attribute name does, quoted with either quote and
    // containing the other, in 8-bit and 16-bit input. In 16-bit input, also values containing U+0122 and U+0127,
    // whose low bytes are the quotes.
    auto wideValue = makeString('a', static_cast<char16_t>(0x0122), static_cast<char16_t>(0x0127), 'b');
    for (auto name : { "abcdefghijklm"_s, "abcdefghijklmn"_s, "abcdefghijklmno"_s }) {
        for (bool is8Bit : { true, false }) {
            auto input = [&](char quote, const String& value) {
                auto markup = makeString("<span "_s, name, '=', quote, value, quote, "></span>"_s);
                return is8Bit ? markup : sixteenBitString(markup);
            };
            EXPECT_EQ("it's"_s, attributeValue(input('"', "it's"_s)));
            EXPECT_EQ("say \"hi\" to everyone"_s, attributeValue(input('\'', "say \"hi\" to everyone"_s)));
            EXPECT_EQ(emptyString(), attributeValue(input('"', emptyString())));
            EXPECT_EQ(emptyString(), attributeValue(input('\'', emptyString())));
            if (!is8Bit) {
                EXPECT_EQ(wideValue, attributeValue(input('"', wideValue)));
                EXPECT_EQ(wideValue, attributeValue(input('\'', wideValue)));
            }
        }
    }
}

TEST(WebCoreHTMLParser, FastPathTagNameLengths)
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

    // The names of the fragment's top-level nodes, or "fail" if the fast path does not parse it.
    auto topLevelNames = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        if (!tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent }))
            return "fail"_s;
        StringBuilder builder;
        for (auto* child = fragment->firstChild(); child; child = child->nextSibling()) {
            if (child != fragment->firstChild())
                builder.append(' ');
            builder.append(child->nodeName());
        }
        return builder.toString();
    };

    // Start tags of 6 to 9 letters, and end tags with fewer than 8 characters after them, in 8-bit and 16-bit input.
    for (bool is8Bit : { true, false }) {
        auto names = [&](ASCIILiteral markup) {
            return topLevelNames(is8Bit ? String(markup) : sixteenBitString(markup));
        };
        EXPECT_EQ("BUTTON"_s, names("<button>x</button>"_s));
        EXPECT_EQ("BUTTON"_s, names("<BUTTON>x</BUTTON>"_s));
        EXPECT_EQ("BUTTON"_s, names("<button >x</button >"_s));
        EXPECT_EQ("STRONG #text"_s, names("<strong>x</strong>y"_s));
        EXPECT_EQ("fail"_s, names("<abcdefg>x</abcdefg>"_s));
        EXPECT_EQ("fail"_s, names("<abcdefgh>x</abcdefgh>"_s));
        EXPECT_EQ("fail"_s, names("<abcdefghi>x</abcdefghi>"_s));
        EXPECT_EQ("SPAN BR"_s, names("<span>x</span><br>"_s));
        EXPECT_EQ("B"_s, names("<b>x</b>"_s));
        EXPECT_EQ("B"_s, names("<b>x</B>"_s));
        EXPECT_EQ("fail"_s, names("<span>x</spa>"_s));
        EXPECT_EQ("fail"_s, names("<span>x</span"_s));
        EXPECT_EQ("fail"_s, names("<button>x</butto"_s));
    }

    // U+0162 and U+0142, whose low bytes are 'b' and 'B', in tag names.
    auto wide = [&](char16_t character, ASCIILiteral before, ASCIILiteral after) {
        return topLevelNames(makeString(before, character, after));
    };
    EXPECT_EQ("fail"_s, wide(0x0162, "<"_s, ">x</b>"_s));
    EXPECT_EQ("fail"_s, wide(0x0142, "<b>x</"_s, ">"_s));
    EXPECT_EQ("fail"_s, wide(0x0162, "<b>x</"_s, ">0123456789"_s));
}

TEST(WebCoreHTMLParser, FastPathTextRunLengths)
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

    auto firstText = [&](const String& input) -> String {
        auto fragment = DocumentFragment::create(document);
        bool result = tryFastParsingHTMLFragment(input, document, fragment, div, { ParserContentPolicy::AllowScriptingContent });
        EXPECT_TRUE(result);
        auto* text = result ? dynamicDowncast<Text>(fragment->firstChild()) : nullptr;
        EXPECT_TRUE(text);
        EXPECT_TRUE(text && text->nextSibling());
        return text ? text->data() : String();
    };

    // Runs of 15, 16, 17, 31, 32 and 33 characters before a tag, in 8-bit and 16-bit input. In 16-bit input, also runs
    // containing U+0126 and U+013C, whose low bytes are '&' and '<'.
    for (unsigned length : { 15u, 16u, 17u, 31u, 32u, 33u }) {
        auto run = repeatedCharacter('t', length);
        EXPECT_EQ(run, firstText(makeString(run, "<b></b>"_s)));
        EXPECT_EQ(run, firstText(sixteenBitString(makeString(run, "<b></b>"_s))));

        StringBuilder wideRun;
        for (unsigned i = 0; i < length; ++i)
            wideRun.append(i == length / 2 ? u'\u0126' : i == length - 1 ? u'\u013C' : u't');
        auto wideRunString = wideRun.toString();
        EXPECT_EQ(wideRunString, firstText(makeString(wideRunString, "<b></b>"_s)));
    }
}

TEST(WebCoreHTMLParser, TokenizerLongNumericCharacterReference)
{
    // Returns the characters and attribute values of the tokens, appending the input whole or one character at a time.
    auto tokenize = [](const String& input, bool oneCharacterAtATime) {
        HTMLTokenizer tokenizer;
        SegmentedString source;
        StringBuilder result;
        auto takeTokens = [&] {
            while (auto token = tokenizer.nextToken(source)) {
                if (token->type() == HTMLToken::Type::Character)
                    result.append(token->characters().span());
                else if (token->type() == HTMLToken::Type::StartTag) {
                    for (auto& attribute : token->attributes())
                        result.append(attribute.value.span());
                }
            }
        };
        if (oneCharacterAtATime) {
            for (unsigned i = 0; i < input.length(); ++i) {
                source.append(input.substring(i, 1));
                takeTokens();
            }
        } else {
            source.append(input);
            takeTokens();
        }
        return result.toString();
    };

    // References of 63 to 68 characters after the '&', in text and in an attribute value.
    for (unsigned length = 63; length <= 68; ++length) {
        auto reference = makeString("&#"_s, repeatedCharacter('0', length - 4), "65;"_s);
        auto input = makeString('x', reference, "y<b title=\""_s, reference, "\">"_s);
        EXPECT_EQ(String("xAyA"_s), tokenize(input, false));
        EXPECT_EQ(String("xAyA"_s), tokenize(input, true));
    }
}

TEST(WebCoreHTMLParser, TokenizerPlainTextRuns)
{
    // Returns the characters and attribute values of the tokens, each comment as "<!--comment-->" followed by '8' if it
    // is all 8-bit data, and each DOCTYPE's identifiers as "[public|system]", appending the input in chunks of
    // `chunkLength` characters. With `withAttributeNames`, each attribute as "name=value;". The start tags of title,
    // style, script and svg switch to the states the tree builder would.
    // For an input with no '\r' and no character reference, also checks the source's line and column after each token:
    // the line is the number of '\n's consumed, and the column the number of characters consumed after the last of
    // them, plus one when that '\n' was read from a 16-bit string or was the last character of a chunk, where
    // SegmentedString starts the new line before it advances past the '\n'.
    auto tokenize = [](const String& input, unsigned chunkLength, bool checkLinesAndColumns, bool withAttributeNames) {
        HTMLTokenizer tokenizer;
        SegmentedString source;
        StringBuilder result;
        auto expectLineAndColumn = [&] {
            unsigned consumed = source.numberOfCharactersConsumed();
            int line = 0;
            std::optional<unsigned> lastNewline;
            for (unsigned i = 0; i < consumed; ++i) {
                if (input[i] == '\n') {
                    ++line;
                    lastNewline = i;
                }
            }
            int column = consumed;
            if (lastNewline) {
                bool lastInChunk = !((*lastNewline + 1) % chunkLength) || *lastNewline + 1 == input.length();
                column = consumed - *lastNewline - 1 + (!input.is8Bit() || lastInChunk ? 1 : 0);
            }
            EXPECT_EQ(line, source.currentLine().zeroBasedInt());
            EXPECT_EQ(column, source.currentColumn().zeroBasedInt());
        };
        auto takeTokens = [&] {
            while (auto token = tokenizer.nextToken(source)) {
                if (checkLinesAndColumns)
                    expectLineAndColumn();
                if (token->type() == HTMLToken::Type::Character)
                    result.append(token->characters().span());
                else if (token->type() == HTMLToken::Type::Comment) {
                    result.append("<!--"_s, token->comment().span(), "-->"_s);
                    if (token->commentIsAll8BitData())
                        result.append('8');
                } else if (token->type() == HTMLToken::Type::DOCTYPE) {
                    auto doctypeData = token->releaseDoctypeData();
                    result.append('[', doctypeData->publicIdentifier.span(), '|', doctypeData->systemIdentifier.span(), ']');
                } else if (token->type() == HTMLToken::Type::StartTag) {
                    for (auto& attribute : token->attributes()) {
                        if (withAttributeNames)
                            result.append(attribute.name.span(), '=', attribute.value.span(), ';');
                        else
                            result.append(attribute.value.span());
                    }
                    String name { token->name().span() };
                    if (name == "title"_s)
                        tokenizer.setRCDATAState();
                    else if (name == "style"_s)
                        tokenizer.setRAWTEXTState();
                    else if (name == "script"_s)
                        tokenizer.setScriptDataState();
                    else if (name == "svg"_s)
                        tokenizer.setShouldAllowCDATA(true);
                }
            }
        };
        for (unsigned i = 0; i < input.length(); i += chunkLength) {
            source.append(input.substring(i, chunkLength));
            takeTokens();
            if (checkLinesAndColumns)
                expectLineAndColumn();
        }
        return result.toString();
    };
    // Whole, in chunks of one to three characters, and in chunks of 16 to 18 and 32 to 34 characters; as an 8-bit and
    // as a 16-bit string.
    auto expectTokens = [&](const String& expected, const String& input, bool checkLinesAndColumns = false, bool withAttributeNames = false) {
        Vector<char16_t> wideCharacters;
        for (unsigned i = 0; i < input.length(); ++i)
            wideCharacters.append(input[i]);
        String wideInput { wideCharacters.span() };
        EXPECT_FALSE(wideInput.is8Bit());
        for (unsigned chunkLength : { std::numeric_limits<unsigned>::max(), 1u, 2u, 3u, 16u, 17u, 18u, 32u, 33u, 34u }) {
            EXPECT_EQ(expected, tokenize(input, chunkLength, checkLinesAndColumns, withAttributeNames));
            EXPECT_EQ(expected, tokenize(wideInput, chunkLength, checkLinesAndColumns, withAttributeNames));
        }
    };

    // Runs of 1 to 50 characters ended by each character that ends a run, in text, in all three attribute value
    // quotings, in RCDATA, in RAWTEXT, in script data, escaped and double escaped, in comments, bogus comments, both
    // quotings of DOCTYPE identifiers, CDATA sections and attribute names. The Latin-1 runs include characters whose low
    // four bits are those of NUL, ' ', '\t', '"', '&', '\'', '-', '/', '\n', '\f', '<', '=', '>', ']' and '\r', and upper
    // case letters, ASCII and not; the 16-bit runs include characters whose low byte is one of those, and U+3C00, whose
    // high byte is '<'.
    constexpr std::array<Latin1Character, 17> runCharacters { 'a', 0x80, 0xA2, 0xA6, 0xA7, 0xAA, 0xBC, 0xAD, 0xFF, 0xA0, 0xA9, 0xAC,
        0xBE, 'Q', 0xC9, 0xDE, 0xAF };
    constexpr std::array<char16_t, 20> wideRunCharacters { 'a', 0x0100, 0x0122, 0x0126, 0x0127, 0x012D, 0x010A, 0x013C, 0x010D,
        0x3C00, 0x4E2D, 0x0120, 0x0109, 0x010C, 0x013E, 0x015D, 0x013D, 0x012F, 0x0141, 'Z' };
    auto expectRunTokens = [&](const String& run) {
        auto input = makeString('x', run, "&amp;"_s, run, "\r\n"_s, run, '\n', run, "<b title=\""_s, run, "&amp;"_s, run, '\'', run,
            "\" alt='"_s, run, '"', run, "'>"_s);
        auto expected = makeString('x', run, '&', run, '\n', run, '\n', run, run, '&', run, '\'', run, run, '"', run);
        expectTokens(expected, input);

        auto unquotedInput = makeString("<b title="_s, run, "&amp;"_s, run, " alt="_s, run, "\r\nc="_s, run, "\td="_s, run, "\fe="_s, run,
            "\"'<=`"_s, run, "\nf="_s, run, '>', run);
        auto unquotedExpected = makeString(run, '&', run, run, run, run, run, "\"'<=`"_s, run, run, run);
        expectTokens(unquotedExpected, unquotedInput);

        auto rcdata = [&](ASCIILiteral newline, ASCIILiteral ampersand) {
            return makeString(run, ampersand, run, newline, run, "<b>"_s, run);
        };
        auto rcdataInput = makeString("<title>"_s, rcdata("\r\n"_s, "&amp;"_s), "</title>"_s);
        expectTokens(rcdata("\n"_s, "&"_s), rcdataInput);

        auto rawText = [&](ASCIILiteral newline) {
            return makeString(run, "&amp;"_s, run, newline, run, "<b>"_s, run);
        };
        auto rawTextInput = makeString("<style>"_s, rawText("\r\n"_s), "</style>"_s);
        expectTokens(rawText("\n"_s), rawTextInput);

        auto scriptData = [&](ASCIILiteral newline) {
            return makeString(rawText(newline), "<!--"_s, run, '-', run, "<b>"_s, run, newline, run, "<script>"_s, run, '-', run,
                "<b>"_s, run, newline, run, "</script>"_s, run, "-->"_s, run);
        };
        auto scriptDataInput = makeString("<script>"_s, scriptData("\r\n"_s), "</script>"_s);
        expectTokens(scriptData("\n"_s), scriptDataInput);

        bool is8Bit = run.containsOnlyLatin1();
        auto comment = [&](ASCIILiteral before, const String& text) {
            return makeString("<!--"_s, before, text, "-->"_s, is8Bit ? "8"_s : ""_s);
        };
        auto markupInput = makeString("<!--"_s, run, '-', run, "\r\n"_s, run, ">"_s, run, "--><?"_s, run, '\n', run, "]-><!DOCTYPE html PUBLIC \""_s,
            run, "'"_s, run, "\r\n"_s, run, "\" '"_s, run, '"', run, "'><!DOCTYPE html SYSTEM \""_s, run, '\n', run, "\"><svg><![CDATA["_s,
            run, ']', run, "\r\n"_s, run, "]]"_s, run, "-->]]>"_s, run, "</svg>"_s);
        auto markupExpected = makeString(comment(""_s, makeString(run, '-', run, '\n', run, '>', run)), comment("?"_s, makeString(run, '\n', run, "]-"_s)),
            '[', run, '\'', run, '\n', run, '|', run, '"', run, ']', '[', '|', run, '\n', run, ']', run, ']', run, '\n', run, "]]"_s, run, "-->"_s, run);
        expectTokens(markupExpected, markupInput);

        // Lines of runs, '\n' after '\n' and a '\n' at the start, the end and the second-to-last character of a chunk,
        // in each state that keeps a '\n' as text.
        auto lines = makeString(run, '\n', run, "\n\n"_s, run, '\n', '\n', run, '\n');
        auto linesInput = makeString('x', lines, "<b title=\""_s, lines, "\" alt='"_s, lines, "'>"_s, lines, "<title>"_s, lines,
            "</title><style>"_s, lines, "</style><script>"_s, lines, "<!--"_s, lines, "<script>"_s, lines, "</script>"_s, lines,
            "--></script><!--"_s, lines, "--><?"_s, lines, "><!DOCTYPE html PUBLIC \""_s, lines, "\" '"_s, lines,
            "'><svg><![CDATA["_s, lines, "]]></svg>"_s, lines);
        auto linesExpected = makeString('x', lines, lines, lines, lines, lines, lines, lines, "<!--"_s, lines, "<script>"_s,
            lines, "</script>"_s, lines, "-->"_s, comment(""_s, lines), comment("?"_s, lines), '[', lines, '|', lines, ']',
            lines, lines);
        expectTokens(linesExpected, linesInput, true);

        // Attribute names ended by each character that ends one, with '\v', which does not, and with the parse errors
        // '"', '\'' and '<' and a NUL inside, after the first attribute and after a value.
        auto name = run.convertToASCIILowercase();
        Vector<char16_t> nullCharacter { 0 };
        auto namesInput = makeString("<b "_s, run, "=v "_s, run, '\t', run, '\n', run, '\f', run, '\v', run, "\r\n"_s, run, '/', run, "\"'<"_s, run,
            String { nullCharacter.span() }, run, " =w "_s, run, "\t/"_s, run, "='x'"_s, run, '>', run);
        auto namesExpected = makeString(name, "=v;"_s, name, "=;"_s, name, "=;"_s, name, "=;"_s, name, '\v', name, "=;"_s, name, "=;"_s, name, "\"'<"_s,
            name, static_cast<char16_t>(0xFFFD), name, "=w;"_s, name, "=;"_s, name, "=x;"_s, name, "=;"_s, run);
        expectTokens(namesExpected, namesInput, false, true);
    };
    for (unsigned length = 1; length <= 50; ++length) {
        Vector<Latin1Character> runBuffer;
        Vector<char16_t> wideRunBuffer;
        for (unsigned i = 0; i < length; ++i) {
            runBuffer.append(runCharacters[i % runCharacters.size()]);
            wideRunBuffer.append(wideRunCharacters[(i + length) % wideRunCharacters.size()]);
        }
        String run { runBuffer.span() };
        EXPECT_TRUE(run.is8Bit());
        expectRunTokens(run);
        String wideRun { wideRunBuffer.span() };
        EXPECT_FALSE(wideRun.is8Bit());
        expectRunTokens(wideRun);
    }
}

TEST(WebCoreHTMLParser, TokenizerEndTagsInText)
{
    // Returns the characters of the tokens, with each end tag as "[/name]", appending the input in chunks of
    // `chunkLength` characters. The start tags of title, style and script switch to the states the tree builder would.
    auto tokenize = [](const String& input, unsigned chunkLength) {
        HTMLTokenizer tokenizer;
        SegmentedString source;
        StringBuilder result;
        auto takeTokens = [&] {
            while (auto token = tokenizer.nextToken(source)) {
                if (token->type() == HTMLToken::Type::Character)
                    result.append(token->characters().span());
                else if (token->type() == HTMLToken::Type::EndTag)
                    result.append("[/"_s, String { token->name().span() }, ']');
                else if (token->type() == HTMLToken::Type::StartTag) {
                    String name { token->name().span() };
                    if (name == "title"_s)
                        tokenizer.setRCDATAState();
                    else if (name == "style"_s)
                        tokenizer.setRAWTEXTState();
                    else if (name == "script"_s)
                        tokenizer.setScriptDataState();
                }
            }
        };
        for (unsigned i = 0; i < input.length(); i += chunkLength) {
            source.append(input.substring(i, chunkLength));
            takeTokens();
        }
        return result.toString();
    };
    // Whole, one character at a time, and in chunks that end inside and just after the end tag's name; as an 8-bit
    // and as a 16-bit string.
    auto expectTokens = [&](const String& expected, const String& input) {
        Vector<char16_t> wideCharacters;
        for (unsigned i = 0; i < input.length(); ++i)
            wideCharacters.append(input[i]);
        String wideInput { wideCharacters.span() };
        EXPECT_FALSE(wideInput.is8Bit());
        for (unsigned chunkLength : { std::numeric_limits<unsigned>::max(), 1u, 2u, 3u, 16u, 17u, 18u, 32u, 33u }) {
            EXPECT_EQ(expected, tokenize(input, chunkLength));
            EXPECT_EQ(expected, tokenize(wideInput, chunkLength));
        }
    };

    // Names that are, and are not, the appropriate end tag, after text of lengths that place them on both sides of
    // the end of a chunk, in RCDATA, RAWTEXT, script data and escaped script data.
    struct Context {
        ASCIILiteral start;
        ASCIILiteral text;
        ASCIILiteral name;
        ASCIILiteral uppercaseName;
    };
    const std::array contexts { Context { "<title>"_s, ""_s, "title"_s, "TiTlE"_s }, Context { "<style>"_s, ""_s, "style"_s, "STYLE"_s },
        Context { "<script>"_s, ""_s, "script"_s, "sCrIpT"_s }, Context { "<script>"_s, "<!--"_s, "script"_s, "SCRIPT"_s } };
    for (auto& context : contexts) {
        String name { context.name };
        for (unsigned length : { 0u, 1u, 9u, 13u, 14u, 15u, 16u, 31u }) {
            auto text = makeString(context.text, repeatedCharacter('a', length));
            for (auto& endTagName : { name, String { context.uppercaseName } }) {
                auto input = makeString(context.start, text, "</"_s, endTagName, ">z</"_s, name, ">q"_s);
                expectTokens(makeString(text, "[/"_s, name, "]z[/"_s, name, "]q"_s), input);
                // The rest of the end tag is attributes, which end tags drop.
                for (auto follower : { " "_s, "/"_s }) {
                    auto input = makeString(context.start, text, "</"_s, endTagName, follower, "z</"_s, name, ">q"_s);
                    expectTokens(makeString(text, "[/"_s, name, "]q"_s), input);
                }
            }
            auto uppercaseInput = makeString(context.start, text, "</"_s, context.uppercaseName, "1z</"_s, name, ">q"_s);
            expectTokens(makeString(text, "</"_s, context.uppercaseName, "1z[/"_s, name, "]q"_s), uppercaseInput);
            for (auto& falseName : { name.left(name.length() - 1), makeString(name, 'x'), String { "b"_s }, repeatedCharacter('Q', 33) }) {
                for (auto follower : { ">"_s, " "_s, "/"_s, "\t"_s, "\n"_s, "1"_s, "-"_s }) {
                    auto input = makeString(context.start, text, "</"_s, falseName, follower, "z</"_s, name, ">q"_s);
                    expectTokens(makeString(text, "</"_s, falseName, follower, "z[/"_s, name, "]q"_s), input);
                }
                auto input = makeString(context.start, text, "</"_s, falseName, "\r\nz</"_s, name, ">q"_s);
                expectTokens(makeString(text, "</"_s, falseName, "\nz[/"_s, name, "]q"_s), input);
            }
        }
    }
}

TEST(WebCoreHTMLParser, DocumentParserAttributeCountsAndNameLengths)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();
    auto settings = Settings::create(nullptr);

    auto expectAttributes = [&](const String& expected, const String& markup) {
        for (unsigned chunkLength : { std::numeric_limits<unsigned>::max(), 1u, 7u }) {
            EXPECT_EQ(expected, parseFirstElementAttributes(settings.get(), markup, chunkLength));
            EXPECT_EQ(expected, parseFirstElementAttributes(settings.get(), sixteenBitString(markup), chunkLength));
        }
    };

    // 16 and 17 attributes, and 17 whose last is a duplicate of the first.
    StringBuilder sixteenAttributes;
    StringBuilder sixteenAttributesExpected;
    for (unsigned i = 0; i < 16; ++i) {
        sixteenAttributes.append(" a"_s, i, '=', i);
        sixteenAttributesExpected.append(i ? " a"_s : "a"_s, i, '=', i);
    }
    expectAttributes(sixteenAttributesExpected.toString(), makeString("<div"_s, sixteenAttributes.toString(), "></div>"_s));
    expectAttributes(makeString(sixteenAttributesExpected.toString(), " a16=16"_s), makeString("<div"_s, sixteenAttributes.toString(), " a16=16></div>"_s));
    expectAttributes(sixteenAttributesExpected.toString(), makeString("<div"_s, sixteenAttributes.toString(), " A0=x></div>"_s));

    // Names with upper case letters, of 15 to 17 and 31 to 33 characters, first and as a duplicate of a lower case
    // name.
    for (unsigned length : { 15u, 16u, 17u, 31u, 32u, 33u }) {
        auto lowercaseName = repeatedCharacter('q', length);
        for (auto& name : { makeString('Q', repeatedCharacter('q', length - 1)), makeString(repeatedCharacter('q', length - 1), 'Q'), repeatedCharacter('Q', length) }) {
            expectAttributes(makeString(lowercaseName, "=1"_s), makeString("<p "_s, name, "=1></p>"_s));
            expectAttributes(makeString(lowercaseName, "=1 b=2"_s), makeString("<p "_s, lowercaseName, "=1 "_s, name, "=3 b=2></p>"_s));
        }
    }
}

TEST(WebCoreHTMLParser, DocumentParserQuotedAttributeValueLengths)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();
    auto settings = Settings::create(nullptr);

    // Values of 15, 16, 17, 31, 32 and 33 characters in each quoting, plain and with a character that the quoted
    // attribute value states handle, or that only ends an unquoted value, at each position.
    struct Special {
        String markup;
        String value;
    };
    const std::array specials { Special { "\n"_s, "\n"_s }, Special { "\r"_s, "\n"_s }, Special { "\r\n"_s, "\n"_s },
        Special { "&amp;"_s, "&"_s }, Special { String { "\0"_span8 }, String::fromCodePoint(replacementCharacter) },
        Special { "\""_s, "\""_s }, Special { "'"_s, "'"_s }, Special { ">"_s, ">"_s }, Special { "<"_s, "<"_s }, Special { "="_s, "="_s },
        Special { " "_s, " "_s } };
    for (unsigned length : { 15u, 16u, 17u, 31u, 32u, 33u }) {
        StringBuilder valueBuilder;
        for (unsigned i = 0; i < length; ++i)
            valueBuilder.append(static_cast<Latin1Character>('a' + i % 26));
        auto value = valueBuilder.toString();
        for (char quote : { '"', '\'' }) {
            auto expect = [&](const String& expected, const String& markupValue) {
                auto markup = makeString("<p a="_s, quote, markupValue, quote, " b=1></p>"_s);
                EXPECT_TRUE(markup.is8Bit());
                auto expectedAttributes = makeString("a="_s, expected, " b=1"_s);
                for (unsigned chunkLength : { std::numeric_limits<unsigned>::max(), 7u }) {
                    EXPECT_EQ(expectedAttributes, parseFirstElementAttributes(settings.get(), markup, chunkLength));
                    EXPECT_EQ(expectedAttributes, parseFirstElementAttributes(settings.get(), sixteenBitString(markup), chunkLength));
                }
            };
            expect(value, value);
            for (unsigned position = 0; position < length; ++position) {
                for (auto& special : specials) {
                    if (special.markup.length() == 1 && special.markup[0] == quote)
                        continue;
                    expect(makeString(value.left(position), special.value, value.substring(position + 1)),
                        makeString(value.left(position), special.markup, value.substring(position + 1)));
                }
            }
        }
    }
}

TEST(WebCoreHTMLParser, DocumentParserTagsAtChunkEnds)
{
    ensureTestPlatformStrategiesInstalled();
    ProcessWarming::initializeNames();
    auto settings = Settings::create(nullptr);

    // The body's markup after a document parse of `chunks`, appended in order.
    auto parseBody = [&](std::initializer_list<String> chunks) -> String {
        auto document = HTMLDocument::create(nullptr, settings.get(), aboutBlankURL());
        EXPECT_FALSE(document->open().hasException());
        for (auto& chunk : chunks) {
            RefPtr parser = document->parser();
            if (!parser)
                break;
            parser->appendSynchronously(RefPtr { chunk.impl() });
        }
        document->close();
        RefPtr body = document->body();
        EXPECT_TRUE(body);
        return body ? body->innerHTML() : String();
    };
    auto expectBody = [&](ASCIILiteral expected, ASCIILiteral first, ASCIILiteral second) {
        EXPECT_EQ(String { expected }, parseBody({ String { first }, String { second } }));
        EXPECT_EQ(String { expected }, parseBody({ sixteenBitString(String { first }), sixteenBitString(String { second }) }));
    };

    // A chunk that ends two and three characters after a '<': one short of the shortest tag, and the shortest tag.
    expectBody("<b>x</b>"_s, "<b"_s, ">x"_s);
    expectBody("<b>x</b>"_s, "<b>"_s, "x"_s);
    expectBody("y<b>x</b>"_s, "y<b"_s, ">x"_s);
    expectBody("y<b>x</b>"_s, "y<b>"_s, "x"_s);
    expectBody("<b c=\"1\">x</b>"_s, "<b"_s, " c=1>x"_s);
    expectBody("<b>x</b>y"_s, "<b>x</"_s, "b>y"_s);
    expectBody("<b>x</b>y"_s, "<b>x</b"_s, ">y"_s);
    expectBody("<b>x</b>y"_s, "<b>x</b>"_s, "y"_s);
    expectBody("y&lt;&gt;x"_s, "y<"_s, ">x"_s);
    expectBody("y&lt;&gt;x"_s, "y<>"_s, "x"_s);
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
