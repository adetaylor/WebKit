/*
 * Copyright (C) 2010-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2014 Google Inc. All rights reserved.
 * Copyright (C) 2025 Samuel Weinig <sam@webkit.org>
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "HTMLParserIdioms.h"

#include "Decimal.h"
#include "QualifiedName.h"
#include <limits>
#include <wtf/CheckedArithmetic.h>
#include <wtf/FixedVector.h>
#include <wtf/MathExtras.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/dtoa.h>
#include <wtf/text/ParsingUtilities.h>

#if PLATFORM(COCOA)
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#endif

#include "HTMLMicrosyntaxesSwiftTypes.h"
#include "WebCore-Swift.h"

namespace WebCore {

String serializeForNumberType(const Decimal& number)
{
    if (number.isZero()) {
        // Decimal::toString appends exponent, e.g. "0e-18"
        return number.isNegative() ? "-0"_s : "0"_s;
    }
    return number.toString();
}

String serializeForNumberType(double number)
{
    // According to HTML5, "the best representation of the number n as a floating
    // point number" is a string produced by applying ToString() to n.
    return String::number(number);
}

Decimal parseToDecimalForNumberType(StringView string, const Decimal& fallbackValue)
{
    // https://html.spec.whatwg.org/#floating-point-numbers and parseToDoubleForNumberType
    if (string.isEmpty())
        return fallbackValue;

    // String::toDouble() accepts leading + and whitespace characters, which are not valid here.
    const char16_t firstCharacter = string[0];
    if (firstCharacter != '-' && firstCharacter != '.' && !isASCIIDigit(firstCharacter))
        return fallbackValue;

    const Decimal value = Decimal::fromString(string);
    if (!value.isFinite())
        return fallbackValue;

    // Numbers are considered finite IEEE 754 Double-precision floating point values.
    const Decimal doubleMax = Decimal::doubleMax();
    if (value < -doubleMax || value > doubleMax)
        return fallbackValue;

    // We return +0 for -0 case.
    return value.isZero() ? Decimal(0) : value;
}

Decimal parseToDecimalForNumberType(StringView string)
{
    return parseToDecimalForNumberType(string, Decimal::nan());
}

double parseToDoubleForNumberType(StringView string, double fallbackValue)
{
    return string.is8Bit() ? htmlMicrosyntaxParseFloatingPointNumberValue8(string.span8(), fallbackValue, true) : htmlMicrosyntaxParseFloatingPointNumberValue16(string.span16(), fallbackValue, true);
}

double parseToDoubleForNumberType(StringView string)
{
    return parseToDoubleForNumberType(string, std::numeric_limits<double>::quiet_NaN());
}

// https://html.spec.whatwg.org/multipage/infrastructure.html#rules-for-parsing-integers
std::expected<int, HTMLIntegerParsingError> parseHTMLInteger(StringView input)
{
    auto result = input.is8Bit() ? htmlMicrosyntaxParseInteger8(input.span8()) : htmlMicrosyntaxParseInteger16(input.span16());
    return result.isValid ? std::expected<int, HTMLIntegerParsingError> { result.value } : makeUnexpected(result.error);
}

// https://html.spec.whatwg.org/multipage/infrastructure.html#rules-for-parsing-non-negative-integers
std::expected<unsigned, HTMLIntegerParsingError> parseHTMLNonNegativeInteger(StringView input)
{
    auto optionalSignedResult = parseHTMLInteger(input);
    if (!optionalSignedResult)
        return makeUnexpected(WTF::move(optionalSignedResult.error()));

    if (optionalSignedResult.value() < 0)
        return makeUnexpected(HTMLIntegerParsingError::NegativeOverflow);

    return static_cast<unsigned>(optionalSignedResult.value());
}

// https://html.spec.whatwg.org/#rules-for-parsing-floating-point-number-values
double parseHTMLFloatingPointNumberValue(StringView input, double fallbackValue)
{
    return input.is8Bit() ? htmlMicrosyntaxParseFloatingPointNumberValue8(input.span8(), fallbackValue, false) : htmlMicrosyntaxParseFloatingPointNumberValue16(input.span16(), fallbackValue, false);
}

Vector<double> parseHTMLListOfOfFloatingPointNumberValues(StringView input)
{
    // Each number takes at least one character, and the next one starts after at least one delimiter.
    Vector<double> numbers((input.length() + 1) / 2);
    unsigned count = input.is8Bit() ? htmlMicrosyntaxParseListOfFloatingPointNumbers8(input.span8(), numbers.mutableSpan()) : htmlMicrosyntaxParseListOfFloatingPointNumbers16(input.span16(), numbers.mutableSpan());
    RELEASE_ASSERT(count <= numbers.size());
    numbers.shrink(count);
    // A list keeps at most 16 unused elements.
    if (numbers.capacity() - numbers.size() > 16)
        numbers.shrinkToFit();
    return numbers;
}

String parseCORSSettingsAttribute(const AtomString& value)
{
    if (value.isNull())
        return String();
    if (equalLettersIgnoringASCIICase(value, "use-credentials"_s))
        return "use-credentials"_s;
    return "anonymous"_s;
}

bool parseMetaHTTPEquivRefresh(StringView input, double& delay, String& url)
{
    auto result = input.is8Bit() ? htmlMicrosyntaxParseMetaRefresh8(input.span8(), delay) : htmlMicrosyntaxParseMetaRefresh16(input.span16(), delay);
    if (result.hasURL)
        url = input.substring(result.urlStart, result.urlLength).toString();
    return result.isValid;
}

// https://html.spec.whatwg.org/#rules-for-parsing-a-hash-name-reference
AtomString parseHTMLHashNameReference(StringView usemap)
{
    size_t numberSignIndex = usemap.find('#');
    if (numberSignIndex == notFound)
        return nullAtom();
    auto result = usemap.substring(numberSignIndex + 1);
    if (result.isEmpty())
        return nullAtom();
    return result.toAtomString();
}

enum class IsMultiLength : bool { No, Yes };
static std::optional<HTMLDimension> parseHTMLDimensionInternal(StringView dimensionString, IsMultiLength isMultiLength)
{
    auto dimension = dimensionString.is8Bit() ? htmlMicrosyntaxParseDimension8(dimensionString.span8(), isMultiLength == IsMultiLength::Yes) : htmlMicrosyntaxParseDimension16(dimensionString.span16(), isMultiLength == IsMultiLength::Yes);
    return std::isnan(dimension.number) ? std::nullopt : std::optional { dimension };
}

std::optional<HTMLDimension> parseHTMLDimension(StringView dimensionString)
{
    return parseHTMLDimensionInternal(dimensionString, IsMultiLength::No);
}

std::optional<HTMLDimension> parseHTMLMultiLength(StringView multiLengthString)
{
    return parseHTMLDimensionInternal(multiLengthString, IsMultiLength::Yes);
}

FixedVector<HTMLDimensionsListValue> parseHTMLDimensionsList(StringView listOfDimensionsString)
{
    FixedVector<HTMLDimensionsListValue> result(listOfDimensionsString.is8Bit() ? htmlMicrosyntaxCountDimensions8(listOfDimensionsString.span8()) : htmlMicrosyntaxCountDimensions16(listOfDimensionsString.span16()));
    if (listOfDimensionsString.is8Bit())
        htmlMicrosyntaxParseDimensionsList8(listOfDimensionsString.span8(), result.mutableSpan());
    else
        htmlMicrosyntaxParseDimensionsList16(listOfDimensionsString.span16(), result.mutableSpan());
    return result;
}

} // namespace WebCore
