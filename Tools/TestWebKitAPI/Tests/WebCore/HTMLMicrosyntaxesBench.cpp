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

#include "config.h"

#include "Helpers/Test.h"
#include <WebCore/DateComponents.h>
#include <WebCore/Decimal.h>
#include <WebCore/HTMLMetaCharsetParser.h>
#include <WebCore/HTMLParserIdioms.h>
#include <WebCore/HTMLSrcsetParser.h>
#include <WebCore/ProcessWarming.h>
#include <array>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <optional>
#include <pal/text/TextCodec.h>
#include <wtf/FixedVector.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test runs its inputs once through WebCore's parsers for the HTML microsyntaxes (integers, dimensions,
// floating-point numbers and lists, number input values, meta refresh, srcset, the meta charset prescan) and the
// date and time values of <input>, and checks a checksum of every result. With WEBKIT_RUN_BENCHMARKS set, it then
// runs them a fixed number of times and prints the time taken.

namespace TestWebKitAPI {

namespace HTMLMicrosyntaxesBenchmark {

// Callers draw from it in separate statements, never twice in one expression, so the inputs do not depend on the
// compiler's order of evaluation.
class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

    unsigned between(unsigned minimum, unsigned maximum) { return minimum + below(maximum - minimum + 1); }

    bool percent(unsigned chance) { return below(100) < chance; }

    template<typename T, size_t size>
    const T& pick(const std::array<T, size>& values) { return values[below(static_cast<unsigned>(size))]; }

private:
    uint64_t m_state;
};

enum class Kind : uint8_t {
    Integer,
    NonNegativeInteger,
    ClampedInteger,
    IntegerGreaterThanZero,
    LimitedNonNegativeInteger,
    Dimension,
    MultiLength,
    DimensionsList,
    FloatingPointValue,
    FloatingPointValueWithFallback,
    FloatingPointList,
    NumberInput,
    MetaRefresh,
    CORSSettings,
    HashNameReference,
    Srcset,
    SrcsetCandidates,
    MetaCharset,
    ParseMonth,
    ParseDate,
    ParseWeek,
    ParseTime,
    ParseDateTimeLocal,
    Serialize,
    FromMillisecondsForDate,
    FromMillisecondsForDateTimeLocal,
    FromMillisecondsForMonth,
    FromMillisecondsForWeek,
    FromMillisecondsSinceMidnight,
    FromMonths,
};

struct Input {
    Kind kind { Kind::Integer };
    String value;
    AtomString atom;
    String src;
    float deviceScaleFactor { 1 };
    std::optional<float> sourceSize;
    bool withCallback { false };
    Vector<uint8_t> bytes;
    unsigned chunkSize { 0 };
    double number { 0 };
    WebCore::DateComponents components;
    WebCore::SecondFormat format { WebCore::SecondFormat::None };
};

static Input stringInput(Kind kind, String value)
{
    Input input;
    input.kind = kind;
    input.value = WTF::move(value);
    return input;
}

static Input numberInput(Kind kind, double number)
{
    Input input;
    input.kind = kind;
    input.number = number;
    return input;
}

static String make16Bit(const String& string)
{
    Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return String(characters.span());
}

// Every fourth string input is a 16-bit copy, so each test parses both widths.
static Vector<Input> finish(Vector<Input>&& inputs)
{
    for (size_t i = 0; i < inputs.size(); ++i) {
        if (i % 4 != 3)
            continue;
        auto& input = inputs[i];
        if (!input.value.isNull())
            input.value = make16Bit(input.value);
    }
    return WTF::move(inputs);
}

static size_t stringBytes(const String& string)
{
    return string.length() * (string.is8Bit() ? 1 : 2);
}

static String serializeForBytes(const WebCore::DateComponents& components, WebCore::SecondFormat format)
{
    return components.toString(format);
}

static size_t inputBytes(const Input& input)
{
    switch (input.kind) {
    case Kind::CORSSettings:
        return input.atom.length();
    case Kind::Srcset:
    case Kind::SrcsetCandidates:
        return stringBytes(input.value) + stringBytes(input.src);
    case Kind::MetaCharset:
        return input.bytes.size();
    case Kind::Serialize:
        return serializeForBytes(input.components, input.format).length();
    case Kind::FromMillisecondsForDate:
    case Kind::FromMillisecondsForDateTimeLocal:
    case Kind::FromMillisecondsForMonth:
    case Kind::FromMillisecondsForWeek:
    case Kind::FromMillisecondsSinceMidnight:
    case Kind::FromMonths:
        return sizeof(double);
    default:
        return stringBytes(input.value);
    }
}

// FNV-1a over the results, one 64-bit value at a time.
class ResultHash {
public:
    void add(uint64_t value) { m_value = (m_value ^ value) * 0x100000001b3ULL; }

    void addDouble(double value)
    {
        if (std::isnan(value)) {
            add(0x7ff8000000000000ULL);
            return;
        }
        add(std::bit_cast<uint64_t>(value));
    }

    void addFloat(float value) { add(std::bit_cast<uint32_t>(value)); }

    void addString(StringView string)
    {
        add(string.length());
        for (auto character : string.codeUnits())
            add(character);
    }

    // For the results whose null and empty values differ to their callers.
    void addNullableString(StringView string)
    {
        add(string.isNull());
        addString(string);
    }

    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0xcbf29ce484222325ULL };
};

static constexpr uint64_t missing = 1ULL << 40;

template<typename T>
static void addInteger(ResultHash& hash, const std::expected<T, WebCore::HTMLIntegerParsingError>& result)
{
    if (result)
        hash.add(static_cast<uint32_t>(result.value()));
    else
        hash.add(missing | static_cast<uint64_t>(result.error()));
}

static void addDimension(ResultHash& hash, const std::optional<WebCore::HTMLDimension>& dimension)
{
    if (!dimension) {
        hash.add(missing);
        return;
    }
    hash.addDouble(dimension->number);
    hash.add(static_cast<uint64_t>(dimension->type));
}

static void addCandidate(ResultHash& hash, const WebCore::ImageCandidate& candidate)
{
    hash.addString(candidate.string.view);
    hash.addFloat(candidate.density);
    hash.add(static_cast<uint32_t>(candidate.resourceWidth));
    hash.add(static_cast<uint64_t>(candidate.originAttribute));
}

static void addComponents(ResultHash& hash, const std::optional<WebCore::DateComponents>& components)
{
    if (!components) {
        hash.add(missing);
        return;
    }
    hash.add(static_cast<uint64_t>(components->type()));
    hash.add(static_cast<uint32_t>(components->fullYear()));
    hash.add(static_cast<uint32_t>(components->month()));
    hash.add(static_cast<uint32_t>(components->monthDay()));
    hash.add(static_cast<uint32_t>(components->week()));
    hash.add(static_cast<uint32_t>(components->hour()));
    hash.add(static_cast<uint32_t>(components->minute()));
    hash.add(static_cast<uint32_t>(components->second()));
    hash.add(static_cast<uint32_t>(components->millisecond()));
    hash.addDouble(components->millisecondsSinceEpoch());
    if (components->type() == WebCore::DateComponentsType::Month)
        hash.addDouble(components->monthsSinceEpoch());
}

// The image element passes a callback, which ignores candidates only when loading from an archive. The preload
// scanner passes none.
static WebCore::ImageCandidate bestFitSource(const Input& input)
{
    if (input.withCallback) {
        return WebCore::bestFitSourceForImageAttributes(input.deviceScaleFactor, input.src, input.value, input.sourceSize, [](auto&) {
            return false;
        });
    }
    return WebCore::bestFitSourceForImageAttributes(input.deviceScaleFactor, input.src, input.value, input.sourceSize);
}

static void addMetaCharset(ResultHash& hash, const Input& input)
{
    WebCore::HTMLMetaCharsetParser parser;
    auto data = input.bytes.span();
    unsigned chunks = 0;
    bool done = false;
    while (!data.empty() && !done) {
        auto chunk = data.first(std::min<size_t>(input.chunkSize, data.size()));
        data = data.subspan(chunk.size());
        ++chunks;
        done = parser.checkForMetaCharset(chunk);
    }
    hash.add(done);
    hash.add(chunks);
    auto& encoding = parser.encoding();
    hash.add(encoding.isValid());
    if (encoding.isValid())
        hash.addString(StringView { encoding.name() });
}

static void addInput(ResultHash& hash, const Input& input)
{
    switch (input.kind) {
    case Kind::Integer:
        addInteger(hash, WebCore::parseHTMLInteger(input.value));
        return;
    case Kind::NonNegativeInteger:
        addInteger(hash, WebCore::parseHTMLNonNegativeInteger(input.value));
        return;
    case Kind::ClampedInteger:
        // A table cell's colspan.
        hash.add(WebCore::clampHTMLNonNegativeIntegerToRange(input.value, 1, 1000, 1));
        return;
    case Kind::IntegerGreaterThanZero:
        // An input's size.
        hash.add(WebCore::limitToOnlyHTMLNonNegativeNumbersGreaterThanZero(StringView { input.value }, 20));
        return;
    case Kind::LimitedNonNegativeInteger:
        hash.add(WebCore::limitToOnlyHTMLNonNegative(StringView { input.value }, 0));
        return;
    case Kind::Dimension:
        addDimension(hash, WebCore::parseHTMLDimension(input.value));
        return;
    case Kind::MultiLength:
        addDimension(hash, WebCore::parseHTMLMultiLength(input.value));
        return;
    case Kind::DimensionsList: {
        auto list = WebCore::parseHTMLDimensionsList(input.value);
        hash.add(list.size());
        for (auto& value : list) {
            hash.addDouble(value.number);
            hash.add(static_cast<uint64_t>(value.unit));
        }
        return;
    }
    case Kind::FloatingPointValue:
        hash.addDouble(WebCore::parseHTMLFloatingPointNumberValue(input.value));
        return;
    case Kind::FloatingPointValueWithFallback:
        hash.addDouble(WebCore::parseHTMLFloatingPointNumberValue(input.value, input.number));
        return;
    case Kind::FloatingPointList: {
        auto list = WebCore::parseHTMLListOfOfFloatingPointNumberValues(input.value);
        hash.add(list.size());
        for (double value : list)
            hash.addDouble(value);
        return;
    }
    case Kind::NumberInput: {
        double number = WebCore::parseToDoubleForNumberType(input.value);
        hash.addDouble(number);
        if (std::isfinite(number))
            hash.addString(WebCore::serializeForNumberType(number));
        auto decimal = WebCore::parseToDecimalForNumberType(input.value);
        if (decimal.isFinite())
            hash.addString(WebCore::serializeForNumberType(decimal));
        else
            hash.add(missing);
        return;
    }
    case Kind::MetaRefresh: {
        double delay = -1;
        String url;
        bool parsed = WebCore::parseMetaHTTPEquivRefresh(input.value, delay, url);
        hash.add(parsed);
        if (parsed) {
            hash.addDouble(delay);
            hash.addString(url);
        }
        return;
    }
    case Kind::CORSSettings:
        hash.addNullableString(WebCore::parseCORSSettingsAttribute(input.atom));
        return;
    case Kind::HashNameReference:
        hash.addNullableString(WebCore::parseHTMLHashNameReference(input.value));
        return;
    case Kind::Srcset:
        addCandidate(hash, bestFitSource(input));
        return;
    case Kind::SrcsetCandidates: {
        auto candidates = WebCore::parseImageCandidatesFromSrcsetAttribute(input.value);
        hash.add(candidates.size());
        for (auto& candidate : candidates)
            addCandidate(hash, candidate);
        addCandidate(hash, bestFitSource(input));
        return;
    }
    case Kind::MetaCharset:
        addMetaCharset(hash, input);
        return;
    case Kind::ParseMonth:
        addComponents(hash, WebCore::DateComponents::fromParsingMonth(input.value));
        return;
    case Kind::ParseDate:
        addComponents(hash, WebCore::DateComponents::fromParsingDate(input.value));
        return;
    case Kind::ParseWeek:
        addComponents(hash, WebCore::DateComponents::fromParsingWeek(input.value));
        return;
    case Kind::ParseTime:
        addComponents(hash, WebCore::DateComponents::fromParsingTime(input.value));
        return;
    case Kind::ParseDateTimeLocal:
        addComponents(hash, WebCore::DateComponents::fromParsingDateTimeLocal(input.value));
        return;
    case Kind::Serialize:
        hash.addString(input.components.toString(input.format));
        return;
    case Kind::FromMillisecondsForDate:
        addComponents(hash, WebCore::DateComponents::fromMillisecondsSinceEpochForDate(input.number));
        return;
    case Kind::FromMillisecondsForDateTimeLocal:
        addComponents(hash, WebCore::DateComponents::fromMillisecondsSinceEpochForDateTimeLocal(input.number));
        return;
    case Kind::FromMillisecondsForMonth:
        addComponents(hash, WebCore::DateComponents::fromMillisecondsSinceEpochForMonth(input.number));
        return;
    case Kind::FromMillisecondsForWeek:
        addComponents(hash, WebCore::DateComponents::fromMillisecondsSinceEpochForWeek(input.number));
        return;
    case Kind::FromMillisecondsSinceMidnight:
        addComponents(hash, WebCore::DateComponents::fromMillisecondsSinceMidnight(input.number));
        return;
    case Kind::FromMonths:
        addComponents(hash, WebCore::DateComponents::fromMonthsSinceEpoch(input.number));
        return;
    }
}

static uint64_t checksum(const Vector<Input>& inputs)
{
    ResultHash hash;
    for (auto& input : inputs)
        addInput(hash, input);
    return hash.value();
}

// String building.

static void appendDigits(StringBuilder& builder, Random& random, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        builder.append(static_cast<char>('0' + random.below(10)));
}

static void appendPadded(StringBuilder& builder, unsigned value, unsigned width)
{
    unsigned digits = 1;
    for (unsigned rest = value; rest >= 10; rest /= 10)
        ++digits;
    for (; digits < width; ++digits)
        builder.append('0');
    builder.append(value);
}

static void appendWhitespace(StringBuilder& builder, Random& random)
{
    static constexpr std::array whitespace { ' ', '\t', '\n', '\f', '\r' };
    unsigned count = random.between(1, 3);
    for (unsigned i = 0; i < count; ++i)
        builder.append(random.pick(whitespace));
}

// Integers.

static String realisticInteger(Random& random, Kind& kind)
{
    static constexpr std::array tabIndexes { "0"_s, "-1"_s, "0"_s, "-1"_s, "1"_s, "2"_s, "3"_s, "10"_s, "100"_s };
    static constexpr std::array spans { "1"_s, "2"_s, "2"_s, "3"_s, "4"_s, "6"_s, "12"_s };
    static constexpr std::array sizes { "1"_s, "10"_s, "20"_s, "30"_s, "40"_s, "60"_s };
    static constexpr std::array maximumLengths { "255"_s, "100"_s, "50"_s, "10"_s, "524288"_s, "2048"_s, "4"_s };
    static constexpr std::array widths { "100"_s, "640"_s, "480"_s, "1"_s, "88"_s, "300"_s, "1920"_s, "16"_s, "24"_s };

    unsigned which = random.below(100);
    String value;
    if (which < 30) {
        kind = Kind::Integer;
        value = random.pick(tabIndexes);
    } else if (which < 50) {
        kind = Kind::ClampedInteger;
        value = random.pick(spans);
    } else if (which < 60) {
        kind = Kind::IntegerGreaterThanZero;
        value = random.pick(sizes);
    } else if (which < 75) {
        kind = Kind::NonNegativeInteger;
        value = random.pick(maximumLengths);
    } else {
        kind = Kind::LimitedNonNegativeInteger;
        value = random.pick(widths);
    }
    if (random.percent(5)) {
        StringBuilder builder;
        if (random.percent(50))
            appendWhitespace(builder, random);
        builder.append(value);
        if (random.percent(50))
            builder.append(random.percent(50) ? " "_s : "px"_s);
        value = builder.toString();
    }
    return value;
}

static Vector<Input> integerAttributesInputs()
{
    Random random(1);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        Kind kind = Kind::Integer;
        auto value = realisticInteger(random, kind);
        inputs.append(stringInput(kind, WTF::move(value)));
    }
    return finish(WTF::move(inputs));
}

static String integerError(Random& random)
{
    static constexpr std::array fixed {
        "2147483647"_s, "2147483648"_s, "-2147483648"_s, "-2147483649"_s, "4294967295"_s, "4294967296"_s,
        "-0"_s, "+0"_s, "+"_s, "-"_s, "+-1"_s, "--1"_s, "-+1"_s, ""_s, " "_s, "\v5"_s, "abc"_s, "1abc"_s,
        "0x10"_s, "1e3"_s, "1.5"_s, ".5"_s, "\t\n\f\r 42"_s, " -7 "_s, "00000000000000000000012"_s,
    };
    unsigned which = random.below(100);
    if (which < 40)
        return random.pick(fixed);
    StringBuilder builder;
    if (which < 50)
        appendWhitespace(builder, random);
    if (which < 70) {
        // A run of digits long enough to overflow.
        if (random.percent(50))
            builder.append(random.percent(50) ? '-' : '+');
        builder.append(static_cast<char>('1' + random.below(9)));
        appendDigits(builder, random, random.between(9, 40));
    } else if (which < 85) {
        // Signs and junk.
        static constexpr std::array junk { "+"_s, "-"_s, "x"_s, "%"_s, "."_s, "e"_s, ","_s, "#"_s };
        unsigned count = random.between(1, 3);
        for (unsigned i = 0; i < count; ++i)
            builder.append(random.pick(junk));
        if (random.percent(50))
            appendDigits(builder, random, random.between(1, 5));
    } else if (which < 92) {
        // Spaces and digits that are not ASCII, and characters whose low byte is a digit or a space.
        static constexpr std::array<char16_t, 7> characters { 0x00A0, 0x3000, 0xFEFF, 0x0663, 0xFF11, 0x0131, 0x0120 };
        builder.append(random.pick(characters));
        appendDigits(builder, random, random.between(1, 4));
    } else {
        appendDigits(builder, random, random.between(1, 9));
        builder.append(random.percent(50) ? "abc"_s : "\v"_s);
    }
    return builder.toString();
}

static Vector<Input> integerErrorsInputs()
{
    // An odd number of kinds, so that each kind also parses the 16-bit copies.
    static constexpr std::array kinds { Kind::Integer, Kind::NonNegativeInteger, Kind::ClampedInteger, Kind::IntegerGreaterThanZero, Kind::LimitedNonNegativeInteger };
    Random random(2);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i)
        inputs.append(stringInput(kinds[i % kinds.size()], integerError(random)));
    return finish(WTF::move(inputs));
}

// Dimensions.

static String dimension(Random& random)
{
    static constexpr std::array errors { ""_s, ".5"_s, "-5"_s, "+5"_s, "abc"_s, "%"_s, " "_s, "*"_s, "px"_s };
    if (random.percent(8))
        return random.pick(errors);
    StringBuilder builder;
    if (random.percent(10))
        appendWhitespace(builder, random);
    builder.append(static_cast<char>('1' + random.below(9)));
    appendDigits(builder, random, random.below(4));
    if (random.percent(25)) {
        builder.append('.');
        appendDigits(builder, random, random.between(random.percent(10) ? 0 : 1, 3));
    }
    unsigned suffix = random.below(100);
    if (suffix < 25)
        builder.append('%');
    else if (suffix < 35)
        builder.append("px"_s);
    else if (suffix < 42)
        builder.append('*');
    else if (suffix < 47)
        builder.append(' ');
    else if (suffix < 50)
        builder.append("em"_s);
    return builder.toString();
}

static Vector<Input> dimensionsInputs()
{
    Random random(3);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        if (random.percent(1)) {
            inputs.append(stringInput(Kind::Dimension, String()));
            continue;
        }
        auto kind = random.percent(75) ? Kind::Dimension : Kind::MultiLength;
        inputs.append(stringInput(kind, dimension(random)));
    }
    return finish(WTF::move(inputs));
}

static void appendDimensionsListEntry(StringBuilder& builder, Random& random)
{
    unsigned which = random.below(100);
    if (which < 30) {
        builder.append('*');
        return;
    }
    if (which < 33)
        return;
    if (which < 35) {
        // An integer or a fraction too long for unsigned.
        if (which == 34)
            builder.append("1."_s);
        builder.append("99999999999"_s);
        appendDigits(builder, random, random.below(4));
        return;
    }
    builder.append(random.between(1, 999));
    if (which < 40) {
        builder.append('.');
        if (random.percent(30))
            builder.append(' ');
        appendDigits(builder, random, random.between(1, 3));
    }
    if (which < 50)
        builder.append('*');
    else if (which < 70)
        builder.append('%');
    else if (which < 73)
        builder.append(" px"_s);
}

static Vector<Input> dimensionListsInputs()
{
    Random random(4);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 4096; ++i) {
        StringBuilder builder;
        if (random.percent(5))
            builder.append(' ');
        unsigned count = random.percent(90) ? random.between(1, 6) : random.between(10, 40);
        for (unsigned entry = 0; entry < count; ++entry) {
            if (entry)
                builder.append(random.percent(70) ? ","_s : ", "_s);
            appendDimensionsListEntry(builder, random);
        }
        if (random.percent(10))
            builder.append(',');
        inputs.append(stringInput(Kind::DimensionsList, builder.toString()));
    }
    return finish(WTF::move(inputs));
}

// Floating-point numbers.

static void appendDecimalNumber(StringBuilder& builder, Random& random, unsigned maximumIntegerDigits, unsigned maximumFractionDigits)
{
    unsigned integerDigits = random.below(maximumIntegerDigits + 1);
    if (integerDigits) {
        builder.append(static_cast<char>('1' + random.below(9)));
        appendDigits(builder, random, integerDigits - 1);
    } else
        builder.append('0');
    unsigned fractionDigits = random.below(maximumFractionDigits + 1);
    if (fractionDigits) {
        builder.append('.');
        appendDigits(builder, random, fractionDigits);
    }
}

static String floatingPointValue(Random& random)
{
    static constexpr std::array fixed {
        "0"_s, "1"_s, "0.5"_s, "-0"_s, "+3"_s, ".25"_s, "1e3"_s, "1.5e-3"_s, "2E+2"_s, " 42"_s, "abc"_s, ""_s,
        "Infinity"_s, "NaN"_s, "1e400"_s, "-1e400"_s, "12abc"_s, "5."_s, "."_s, "-.5"_s, "1e"_s, "0x1A"_s,
    };
    if (random.percent(20))
        return random.pick(fixed);
    StringBuilder builder;
    if (random.percent(5))
        appendWhitespace(builder, random);
    if (random.percent(10))
        builder.append('-');
    appendDecimalNumber(builder, random, 3, 4);
    if (random.percent(5)) {
        builder.append(random.percent(50) ? 'e' : 'E');
        if (random.percent(50))
            builder.append('-');
        appendDigits(builder, random, random.between(1, 2));
    }
    if (random.percent(3))
        builder.append("px"_s);
    return builder.toString();
}

static Vector<Input> floatValuesInputs()
{
    Random random(5);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        if (random.percent(75)) {
            inputs.append(stringInput(Kind::FloatingPointValue, floatingPointValue(random)));
            continue;
        }
        // A meter's or a video's attributes, which fall back to 0 or 1.
        auto input = stringInput(Kind::FloatingPointValueWithFallback, floatingPointValue(random));
        input.number = random.below(2);
        inputs.append(WTF::move(input));
    }
    return finish(WTF::move(inputs));
}

static String coordinates(Random& random)
{
    unsigned shape = random.below(100);
    unsigned count = shape < 45 ? 4 : shape < 75 ? 3 : random.between(6, 40);
    StringBuilder builder;
    for (unsigned i = 0; i < count; ++i) {
        if (i) {
            unsigned separator = random.below(100);
            if (separator < 70)
                builder.append(',');
            else if (separator < 85)
                builder.append(", "_s);
            else if (separator < 95)
                builder.append(' ');
            else
                builder.append(';');
        }
        if (random.percent(3))
            builder.append(random.percent(50) ? "a"_s : "x="_s);
        if (random.percent(5))
            builder.append('-');
        builder.append(random.below(2000));
        if (random.percent(10)) {
            builder.append('.');
            appendDigits(builder, random, random.between(1, 2));
        }
    }
    if (random.percent(3))
        builder.append(',');
    return builder.toString();
}

static Vector<Input> floatListsInputs()
{
    Random random(6);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 4096; ++i)
        inputs.append(stringInput(Kind::FloatingPointList, coordinates(random)));
    return finish(WTF::move(inputs));
}

static String numberInputValue(Random& random)
{
    static constexpr std::array fixed {
        "0"_s, "1"_s, "-1"_s, "100"_s, "0.1"_s, "0.01"_s, "3.14159"_s, "1e3"_s, "1E-7"_s, "2.5e+10"_s, "-0"_s, ".5"_s,
        "5."_s, "+1"_s, " 1"_s, "1 "_s, "abc"_s, ""_s, "1e400"_s, "-1e400"_s, "1,5"_s, "123456789.123456789"_s,
        "123456789012345678901234567890"_s, "0.000001"_s, "-.25"_s, "1e-400"_s,
    };
    if (random.percent(30))
        return random.pick(fixed);
    StringBuilder builder;
    if (random.percent(15))
        builder.append('-');
    unsigned maximumIntegerDigits = random.percent(10) ? 12 : 4;
    unsigned maximumFractionDigits = random.percent(50) ? 0 : 6;
    appendDecimalNumber(builder, random, maximumIntegerDigits, maximumFractionDigits);
    if (random.percent(5)) {
        builder.append('e');
        if (random.percent(50))
            builder.append('-');
        appendDigits(builder, random, random.between(1, 3));
    }
    return builder.toString();
}

static Vector<Input> numberInputsInputs()
{
    Random random(7);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 4096; ++i)
        inputs.append(stringInput(Kind::NumberInput, numberInputValue(random)));
    return finish(WTF::move(inputs));
}

// Meta refresh.

static String refreshURL(Random& random)
{
    static constexpr std::array urls {
        "https://www.example.com/"_s, "/next.html"_s, "page.html?id=12&ref=home"_s, "http://example.org/a b"_s,
        "https://example.com/login?return=%2Fhome"_s, "#top"_s,
    };
    return random.pick(urls);
}

static String metaRefresh(Random& random)
{
    static constexpr std::array fixed {
        "0"_s, "5"_s, "30"_s, ""_s, "abc"_s, "."_s, ".5;url=x"_s, "5x"_s, "2147483648"_s, "-1"_s, "1.5.6;URL=y"_s,
        "0; u"_s, "0; ural"_s, "0; URL"_s, "0;url='a"_s, "0,url=\"b\"c\""_s, "0 https://example.com/"_s, "0;;url=z"_s,
    };
    if (random.percent(20))
        return random.pick(fixed);
    StringBuilder builder;
    if (random.percent(2)) {
        // Characters outside Latin-1 whose low byte is ';' or 'u'.
        builder.append(random.below(60));
        if (random.percent(50))
            builder.append(static_cast<char16_t>(0x013B), "url=/next.html"_s);
        else
            builder.append("; "_s, static_cast<char16_t>(0x0175), "rl=/next.html"_s);
        return builder.toString();
    }
    if (random.percent(10))
        appendWhitespace(builder, random);
    builder.append(random.below(60));
    if (random.percent(10)) {
        builder.append('.');
        appendDigits(builder, random, random.between(0, 2));
    }
    if (random.percent(15))
        return builder.toString();
    unsigned separator = random.below(100);
    builder.append(separator < 70 ? "; "_s : separator < 85 ? ";"_s : separator < 95 ? ", "_s : " "_s);
    unsigned url = random.below(100);
    if (url < 80) {
        static constexpr std::array keywords { "url="_s, "URL="_s, "Url = "_s, "url ="_s };
        builder.append(random.pick(keywords));
    }
    unsigned quote = random.below(100);
    if (quote < 20)
        builder.append('\'');
    else if (quote < 30)
        builder.append('"');
    builder.append(refreshURL(random));
    if (quote < 18)
        builder.append('\'');
    else if (quote < 28)
        builder.append('"');
    return builder.toString();
}

static Vector<Input> metaRefreshInputs()
{
    Random random(8);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 4096; ++i)
        inputs.append(stringInput(Kind::MetaRefresh, metaRefresh(random)));
    return finish(WTF::move(inputs));
}

// srcset.

static void appendImageURL(StringBuilder& builder, Random& random, unsigned width = 0)
{
    static constexpr std::array words { "photo"_s, "hero"_s, "thumb"_s, "banner"_s, "avatar"_s, "product"_s };
    static constexpr std::array extensions { ".jpg"_s, ".png"_s, ".webp"_s, ".avif"_s };
    if (random.percent(30))
        builder.append("https://cdn.example.com/assets/"_s);
    else
        builder.append("/images/"_s);
    builder.append(random.pick(words));
    builder.append('-', random.below(10000));
    if (random.percent(2)) {
        // Characters outside Latin-1 whose low bytes are a space and a comma.
        builder.append(static_cast<char16_t>(0x0120), static_cast<char16_t>(0x012C));
    }
    if (width)
        builder.append('-', width);
    builder.append(random.pick(extensions));
    if (random.percent(15))
        builder.append("?w="_s, random.between(100, 4000), "&q=80"_s);
}

static void appendSeparator(StringBuilder& builder, Random& random)
{
    unsigned which = random.below(100);
    if (which < 60)
        builder.append(", "_s);
    else if (which < 85)
        builder.append(',');
    else
        builder.append(",\n    "_s);
}

static String imageSource(Random& random)
{
    if (!random.percent(70))
        return { };
    StringBuilder builder;
    appendImageURL(builder, random);
    return builder.toString();
}

static Input srcsetInput(Kind kind, String srcset, String src, float deviceScaleFactor, std::optional<float> sourceSize, Random& random)
{
    auto input = stringInput(kind, WTF::move(srcset));
    input.src = WTF::move(src);
    input.deviceScaleFactor = deviceScaleFactor;
    input.sourceSize = sourceSize;
    input.withCallback = random.percent(50);
    return input;
}

static String densitySrcset(Random& random)
{
    static constexpr std::array densities { "1x"_s, "1.5x"_s, "2x"_s, "3x"_s, "4x"_s, ""_s, "0.5x"_s, "2.625x"_s };
    // Invalid descriptors, and valid ones at the edges of the floating-point number syntax.
    static constexpr std::array edgeCases {
        " 2x 2x"_s, " 1x 100w"_s, " 50h"_s, " -1x"_s, " abc"_s, " 1e1x"_s, " 2X"_s, " +2x"_s, " 2.x"_s, " 0x"_s,
        " -0x"_s, " .5x"_s, " 1.5e-3x"_s, " 2E+2x"_s, " 1e39x"_s, " 1e400x"_s, " 1ex"_s, " 0x1Ax"_s, " NaNx"_s,
        " Infinityx"_s, " x"_s,
    };
    StringBuilder builder;
    unsigned count = random.between(1, 4);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            appendSeparator(builder, random);
        appendImageURL(builder, random);
        if (random.percent(8)) {
            if (random.percent(10)) {
                // Characters outside Latin-1 whose low bytes are "2x".
                builder.append(' ', static_cast<char16_t>(0x0132), static_cast<char16_t>(0x0178));
            } else
                builder.append(random.pick(edgeCases));
            continue;
        }
        if (random.percent(3)) {
            // A URL that ends in commas has no descriptors.
            builder.append(",,"_s);
            continue;
        }
        auto density = random.pick(densities);
        if (!density.isEmpty())
            builder.append(' ', density);
    }
    return builder.toString();
}

static Vector<Input> srcsetDensitiesInputs()
{
    static constexpr std::array<float, 3> scaleFactors { 1, 2, 3 };
    Random random(9);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 4096; ++i) {
        auto srcset = densitySrcset(random);
        auto src = imageSource(random);
        float deviceScaleFactor = random.pick(scaleFactors);
        inputs.append(srcsetInput(Kind::Srcset, WTF::move(srcset), WTF::move(src), deviceScaleFactor, std::nullopt, random));
    }
    return finish(WTF::move(inputs));
}

static String widthSrcset(Random& random)
{
    static constexpr std::array<unsigned, 11> widths { 160, 320, 480, 640, 750, 828, 1080, 1200, 1920, 2048, 3840 };
    // Invalid descriptors, and valid ones at the edges of the integer syntax.
    static constexpr std::array edgeCases {
        " 0w"_s, " 100.5w"_s, " 100w 200w"_s, " 100w 2x"_s, " 100w 50h"_s, " 50h 100w"_s, " 100W"_s,
        " (max-width: 600px) 100w"_s, " 100w (a, b)"_s, " w"_s, " +100w"_s, " -100w"_s, " 0100w"_s, " 2147483647w"_s,
        " 2147483648w"_s, " 99999999999w"_s, " 1e3w"_s, " 100w 0h"_s,
    };
    StringBuilder builder;
    unsigned count = random.between(2, 8);
    unsigned start = random.below(static_cast<unsigned>(widths.size() - 1));
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            appendSeparator(builder, random);
        unsigned width = widths[(start + i) % widths.size()];
        appendImageURL(builder, random, width);
        if (random.percent(6)) {
            if (random.percent(10)) {
                // Characters outside Latin-1 whose low bytes are "100".
                builder.append(' ', static_cast<char16_t>(0x0131), static_cast<char16_t>(0x0130), static_cast<char16_t>(0x0130), 'w');
            } else
                builder.append(random.pick(edgeCases));
            continue;
        }
        builder.append(' ', width, 'w');
    }
    return builder.toString();
}

static Vector<Input> srcsetWidthsInputs()
{
    static constexpr std::array<float, 3> scaleFactors { 1, 2, 3 };
    static constexpr std::array<float, 7> sourceSizes { 0, 100, 333.3f, 375, 414, 768, 1024 };
    Random random(10);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 4096; ++i) {
        auto srcset = widthSrcset(random);
        float sourceSize = random.pick(sourceSizes);
        auto src = imageSource(random);
        float deviceScaleFactor = random.pick(scaleFactors);
        inputs.append(srcsetInput(Kind::Srcset, WTF::move(srcset), WTF::move(src), deviceScaleFactor,
            sourceSize > 0 ? std::optional<float> { sourceSize } : std::nullopt, random));
    }
    return finish(WTF::move(inputs));
}

static void appendDataURL(StringBuilder& builder, Random& random)
{
    static constexpr std::array<char, 64> base64 {
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V',
        'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r',
        's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/',
    };
    if (random.percent(60)) {
        builder.append("data:image/png;base64,iVBORw0KGgo"_s);
        unsigned length = random.between(200, 4000);
        for (unsigned i = 0; i < length; ++i)
            builder.append(random.pick(base64));
        builder.append("=="_s);
        return;
    }
    // Commas inside the URL belong to it.
    unsigned viewBoxWidth = random.between(1, 100);
    unsigned viewBoxHeight = random.between(1, 100);
    builder.append("data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0,0,"_s, viewBoxWidth, ',', viewBoxHeight, "'%3E"_s);
    unsigned shapes = random.between(5, 60);
    for (unsigned i = 0; i < shapes; ++i) {
        unsigned x1 = random.below(100);
        unsigned y1 = random.below(100);
        unsigned x2 = random.below(100);
        unsigned y2 = random.below(100);
        builder.append("%3Cpath%20d='M"_s, x1, ',', y1, "L"_s, x2, ',', y2, "'/%3E"_s);
    }
    builder.append("%3C/svg%3E"_s);
}

static Vector<Input> srcsetLongInputs()
{
    static constexpr std::array densities { " 1x"_s, " 1.5x"_s, " 2x"_s, " 3x"_s, ""_s };
    Random random(11);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 256; ++i) {
        StringBuilder builder;
        unsigned count = random.between(10, 40);
        bool widths = random.percent(50);
        for (unsigned candidate = 0; candidate < count; ++candidate) {
            if (candidate)
                appendSeparator(builder, random);
            if (random.percent(25))
                appendDataURL(builder, random);
            else
                appendImageURL(builder, random);
            if (widths)
                builder.append(' ', random.between(100, 4000), 'w');
            else
                builder.append(random.pick(densities));
        }
        auto src = imageSource(random);
        inputs.append(srcsetInput(Kind::SrcsetCandidates, builder.toString(), WTF::move(src), 2, widths ? std::optional<float> { 400 } : std::nullopt, random));
    }
    return finish(WTF::move(inputs));
}

// The meta charset prescan.

static String generatedHead(Random& random)
{
    static constexpr std::array before {
        "<title>Page &amp; <b>not a tag</b> </title>\n"_s,
        "<script>if (a < b) document.write('<meta charset=koi8-r>');</script>\n"_s,
        "<style>body { color: red; } /* <meta charset=big5> */</style>\n"_s,
        "<link rel=\"stylesheet\" href=\"/static/site.css\">\n"_s,
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"_s,
        "<!-- <meta charset=\"big5\"> -->\n"_s,
        "<base href=\"/\">\n"_s,
        "<noscript><img src=\"/pixel.gif\"></noscript>\n"_s,
        "<meta property=\"og:title\" content=\"A title with charset=words in it\">\n"_s,
        "<textarea><meta charset=gbk></textarea>\n"_s,
    };
    static constexpr std::array declarations {
        "<meta charset=\"utf-8\">"_s,
        "<meta charset=UTF-8>"_s,
        "<meta charset=\"windows-1252\">"_s,
        "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=ISO-8859-1\">"_s,
        "<meta content=\"text/html; charset='shift_jis'\" http-equiv=\"content-type\">"_s,
        "<META CHARSET=\" utf-8 \">"_s,
        "<meta content=\"charset=gbk\">"_s,
        "<meta charset=\"bogus-encoding\">"_s,
        "<meta http-equiv=content-type content=\"text/html;charset = euc-jp\">"_s,
        "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=\"utf-8\">"_s,
    };

    StringBuilder builder;
    builder.append("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"_s);
    if (random.percent(30))
        builder.append("<title>Caf"_s, static_cast<char16_t>(0xE9), "</title>\n"_s);
    unsigned prefix = random.below(6);
    for (unsigned i = 0; i < prefix; ++i)
        builder.append(random.pick(before));
    unsigned placement = random.below(100);
    if (placement < 80)
        builder.append(random.pick(declarations), '\n');
    else if (placement < 88)
        builder.append("</head>\n<body>\n"_s, random.pick(declarations), '\n');
    unsigned suffix = random.below(4);
    for (unsigned i = 0; i < suffix; ++i)
        builder.append(random.pick(before));
    builder.append("</head>\n<body>\n"_s);
    unsigned paragraphs = random.between(2, 30);
    for (unsigned i = 0; i < paragraphs; ++i)
        builder.append("<p class=\"text\">Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>\n"_s);
    if (random.percent(10))
        builder.append(random.pick(declarations));
    builder.append("</body>\n</html>\n"_s);
    return builder.toString();
}

static Vector<Input> metaCharsetHeadsInputs()
{
    static constexpr std::array<unsigned, 8> chunkSizes { 1, 7, 64, 256, 512, 1024, 4096, 65536 };
    Random random(12);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 1024; ++i) {
        auto latin1 = generatedHead(random).latin1();
        auto input = stringInput(Kind::MetaCharset, { });
        input.bytes.append(byteCast<uint8_t>(latin1.span()));
        input.chunkSize = random.percent(5) ? chunkSizes[random.below(2)] : chunkSizes[random.between(2, static_cast<unsigned>(chunkSizes.size() - 1))];
        inputs.append(WTF::move(input));
    }
    return inputs;
}

// Dates and times.

static bool isGregorianLeapYear(unsigned year)
{
    return !(year % 4) && ((year % 100) || !(year % 400));
}

static unsigned daysInGregorianMonth(unsigned year, unsigned month)
{
    static constexpr std::array<unsigned, 12> days { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return month == 2 && isGregorianLeapYear(year) ? 29 : days[month - 1];
}

// Days from 1970-01-01 to the given proleptic Gregorian date.
static int64_t daysFromCivil(int64_t year, unsigned month, unsigned day)
{
    year -= month <= 2;
    int64_t era = (year >= 0 ? year : year - 399) / 400;
    int64_t yearOfEra = year - era * 400;
    int64_t dayOfYear = (153 * (static_cast<int64_t>(month) + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    int64_t dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}

static constexpr double millisecondsPerDay = 86400000;

static unsigned randomYear(Random& random)
{
    unsigned which = random.below(100);
    if (which < 75)
        return random.between(1950, 2049);
    if (which < 90)
        return random.between(1, 9999);
    if (which < 97)
        return random.between(10000, 275759);
    return 275760;
}

struct DateFields {
    unsigned year;
    unsigned month;
    unsigned day;
    unsigned hour;
    unsigned minute;
    unsigned second;
    unsigned millisecond;
    unsigned fractionDigits;
};

static DateFields randomDateFields(Random& random)
{
    DateFields fields;
    fields.year = randomYear(random);
    fields.month = random.between(1, 12);
    fields.day = random.between(1, daysInGregorianMonth(fields.year, fields.month));
    fields.hour = random.below(24);
    fields.minute = random.below(60);
    unsigned precision = random.below(100);
    fields.second = precision < 50 ? 0 : random.below(60);
    fields.fractionDigits = precision < 75 ? 0 : random.between(1, 3);
    fields.millisecond = random.below(1000);
    return fields;
}

static void appendYear(StringBuilder& builder, unsigned year)
{
    appendPadded(builder, year, 4);
}

static void appendDate(StringBuilder& builder, const DateFields& fields)
{
    appendYear(builder, fields.year);
    builder.append('-');
    appendPadded(builder, fields.month, 2);
    builder.append('-');
    appendPadded(builder, fields.day, 2);
}

static void appendTime(StringBuilder& builder, const DateFields& fields, bool withSeconds)
{
    appendPadded(builder, fields.hour, 2);
    builder.append(':');
    appendPadded(builder, fields.minute, 2);
    if (!withSeconds)
        return;
    builder.append(':');
    appendPadded(builder, fields.second, 2);
    if (!fields.fractionDigits)
        return;
    builder.append('.');
    unsigned fraction = fields.millisecond;
    for (unsigned digits = 3; digits > fields.fractionDigits; --digits)
        fraction /= 10;
    appendPadded(builder, fraction, fields.fractionDigits);
}

// Errors a date or time string can have; most inputs have none.
static void corrupt(DateFields& fields, Random& random, String& suffix, bool& badYear)
{
    switch (random.below(12)) {
    case 0:
        fields.month = random.percent(50) ? 0 : 13;
        break;
    case 1:
        fields.day = random.percent(50) ? 0 : daysInGregorianMonth(fields.year, fields.month) + 1;
        break;
    case 2:
        fields.year = 2023;
        fields.month = 2;
        fields.day = 29;
        break;
    case 3:
        fields.hour = 24;
        break;
    case 4:
        fields.minute = 60;
        break;
    case 5:
        fields.second = 60;
        break;
    case 6:
        fields.fractionDigits = 0;
        suffix = ".1234"_s;
        break;
    case 7:
        suffix = "Z"_s;
        break;
    case 8:
        suffix = " "_s;
        break;
    case 9:
        badYear = true;
        break;
    case 10:
        fields.year = 275760;
        fields.month = 9;
        fields.day = 14;
        break;
    default:
        suffix = "."_s;
        break;
    }
}

static String dateString(Random& random, Kind kind, bool allowErrors)
{
    auto fields = randomDateFields(random);
    String suffix;
    bool badYear = false;
    if (allowErrors && random.percent(12))
        corrupt(fields, random, suffix, badYear);
    StringBuilder builder;
    bool withSeconds = fields.second || fields.fractionDigits || random.percent(30);
    switch (kind) {
    case Kind::ParseMonth:
        if (badYear)
            builder.append(fields.year % 1000);
        else
            appendYear(builder, fields.year);
        builder.append('-');
        appendPadded(builder, fields.month, 2);
        break;
    case Kind::ParseDate:
        if (badYear)
            builder.append("0000-"_s);
        appendDate(builder, fields);
        break;
    case Kind::ParseTime:
        if (badYear)
            builder.append(fields.hour, ':', fields.minute);
        else
            appendTime(builder, fields, withSeconds);
        break;
    case Kind::ParseDateTimeLocal:
        appendDate(builder, fields);
        builder.append(badYear ? '/' : random.percent(90) ? 'T' : ' ');
        appendTime(builder, fields, withSeconds);
        break;
    default:
        ASSERT_NOT_REACHED();
        break;
    }
    builder.append(suffix);
    return builder.toString();
}

static Vector<Input> parseDatesInputs()
{
    static constexpr std::array kinds { Kind::ParseDate, Kind::ParseDate, Kind::ParseTime, Kind::ParseDateTimeLocal, Kind::ParseMonth };
    Random random(13);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        auto kind = random.pick(kinds);
        inputs.append(stringInput(kind, dateString(random, kind, true)));
    }
    return finish(WTF::move(inputs));
}

static String weekString(Random& random)
{
    StringBuilder builder;
    unsigned year = randomYear(random);
    unsigned week = random.between(1, 53);
    unsigned which = random.below(100);
    if (which < 3)
        year = 1;
    else if (which < 6) {
        year = 275760;
        week = random.between(35, 39);
    } else if (which < 9)
        week = random.percent(50) ? 0 : 54;
    appendYear(builder, year);
    builder.append(which == 10 ? "-w"_s : "-W"_s);
    if (which == 11)
        builder.append(week);
    else
        appendPadded(builder, week, 2);
    if (which == 12)
        builder.append('-');
    return builder.toString();
}

static double millisecondsNearNewYear(Random& random)
{
    unsigned year = random.percent(5) ? random.between(1, 3) : randomYear(random);
    int64_t day = daysFromCivil(year, 1, 1) + static_cast<int>(random.below(21)) - 10;
    return static_cast<double>(day) * millisecondsPerDay + random.below(86400000);
}

static WebCore::DateComponents parsedWeek(Random& random)
{
    while (true) {
        if (auto components = WebCore::DateComponents::fromParsingWeek(weekString(random)))
            return *components;
    }
}

static Vector<Input> weeksInputs()
{
    Random random(14);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        unsigned which = random.below(100);
        if (which < 50)
            inputs.append(stringInput(Kind::ParseWeek, weekString(random)));
        else if (which < 90)
            inputs.append(numberInput(Kind::FromMillisecondsForWeek, millisecondsNearNewYear(random)));
        else {
            auto input = stringInput(Kind::Serialize, { });
            input.components = parsedWeek(random);
            inputs.append(WTF::move(input));
        }
    }
    return finish(WTF::move(inputs));
}

static double randomMilliseconds(Random& random)
{
    static constexpr std::array<double, 7> boundaryOffsets { 0, -1, 1, -0.5, 0.5, -0.4999, 0.4999 };
    unsigned which = random.below(100);
    if (which < 60) {
        int64_t day = static_cast<int64_t>(random.below(47482 + 25567)) - 25567;
        double milliseconds = static_cast<double>(day) * millisecondsPerDay + random.below(86400000);
        if (random.percent(10))
            milliseconds += random.percent(50) ? 0.5 : random.below(1000) / 1000.0;
        return milliseconds;
    }
    if (which < 80) {
        int64_t day = static_cast<int64_t>(random.below(100000000 + 719162)) - 719162;
        return static_cast<double>(day) * millisecondsPerDay + random.pick(boundaryOffsets);
    }
    if (which < 90) {
        double limit = random.percent(50) ? WebCore::DateComponents::minimumDate() : WebCore::DateComponents::maximumDate();
        double offset = random.pick(boundaryOffsets);
        double days = static_cast<double>(random.below(5)) - 2;
        return limit + offset + days * millisecondsPerDay;
    }
    if (which < 95) {
        double milliseconds = random.below(1000000) * 1e10;
        return random.percent(50) ? -milliseconds : milliseconds;
    }
    static constexpr std::array<double, 4> special { std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(), -0.0 };
    return random.pick(special);
}

static Vector<Input> datesFromMillisecondsInputs()
{
    Random random(15);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        unsigned which = random.below(100);
        if (which < 35)
            inputs.append(numberInput(Kind::FromMillisecondsForDate, randomMilliseconds(random)));
        else if (which < 70)
            inputs.append(numberInput(Kind::FromMillisecondsForDateTimeLocal, randomMilliseconds(random)));
        else if (which < 80)
            inputs.append(numberInput(Kind::FromMillisecondsForMonth, randomMilliseconds(random)));
        else if (which < 92) {
            double milliseconds = static_cast<double>(random.below(5 * 86400000)) - 2 * millisecondsPerDay;
            if (random.percent(10))
                milliseconds += 0.5;
            inputs.append(numberInput(Kind::FromMillisecondsSinceMidnight, milliseconds));
        } else {
            double months = static_cast<double>(random.below(3291231 + 23628 + 20)) - 23628 - 10;
            if (random.percent(10))
                months += random.percent(50) ? 0.5 : -0.5;
            inputs.append(numberInput(Kind::FromMonths, months));
        }
    }
    return inputs;
}

static std::optional<WebCore::DateComponents> componentsToSerialize(Random& random)
{
    unsigned which = random.below(100);
    if (which < 25)
        return WebCore::DateComponents::fromParsingDate(dateString(random, Kind::ParseDate, false));
    if (which < 35)
        return WebCore::DateComponents::fromParsingMonth(dateString(random, Kind::ParseMonth, false));
    if (which < 45)
        return WebCore::DateComponents::fromParsingWeek(weekString(random));
    if (which < 65)
        return WebCore::DateComponents::fromParsingTime(dateString(random, Kind::ParseTime, false));
    if (which < 85)
        return WebCore::DateComponents::fromParsingDateTimeLocal(dateString(random, Kind::ParseDateTimeLocal, false));
    if (which < 95)
        return WebCore::DateComponents::fromMillisecondsSinceEpochForDateTimeLocal(randomMilliseconds(random));
    return WebCore::DateComponents::fromMillisecondsSinceMidnight(static_cast<double>(random.below(86400000)));
}

static Vector<Input> serializeDatesInputs()
{
    static constexpr std::array formats { WebCore::SecondFormat::None, WebCore::SecondFormat::Second, WebCore::SecondFormat::Millisecond };
    Random random(16);
    Vector<Input> inputs;
    while (inputs.size() < 8192) {
        auto components = componentsToSerialize(random);
        if (!components)
            continue;
        auto input = stringInput(Kind::Serialize, { });
        input.components = *components;
        input.format = random.pick(formats);
        inputs.append(WTF::move(input));
    }
    return inputs;
}

// A page's attributes, in roughly the proportions a page load parses them.

static Vector<Input> attributeMixInputs()
{
    static constexpr std::array corsValues { "anonymous"_s, "use-credentials"_s, ""_s, "USE-CREDENTIALS"_s, "Anonymous"_s, "true"_s };
    static constexpr std::array usemaps { "#map"_s, "#nav-map-2"_s, "map"_s, "#"_s, "a#b"_s };
    static constexpr std::array<float, 3> scaleFactors { 1, 2, 3 };
    Random random(17);
    Vector<Input> inputs;
    for (unsigned i = 0; i < 8192; ++i) {
        unsigned which = random.below(100);
        if (which < 45) {
            Kind kind = Kind::Integer;
            auto value = realisticInteger(random, kind);
            inputs.append(stringInput(kind, WTF::move(value)));
        } else if (which < 60) {
            auto kind = random.percent(90) ? Kind::Dimension : Kind::MultiLength;
            inputs.append(stringInput(kind, dimension(random)));
        } else if (which < 68) {
            bool widths = random.percent(50);
            auto srcset = widths ? widthSrcset(random) : densitySrcset(random);
            auto src = imageSource(random);
            float deviceScaleFactor = random.pick(scaleFactors);
            inputs.append(srcsetInput(Kind::Srcset, WTF::move(srcset), WTF::move(src), deviceScaleFactor,
                widths ? std::optional<float> { 375 } : std::nullopt, random));
        } else if (which < 74) {
            auto input = stringInput(Kind::CORSSettings, { });
            if (!random.percent(10))
                input.atom = AtomString { random.pick(corsValues) };
            inputs.append(WTF::move(input));
        } else if (which < 76)
            inputs.append(stringInput(Kind::HashNameReference, random.pick(usemaps)));
        else if (which < 81)
            inputs.append(stringInput(Kind::FloatingPointValue, floatingPointValue(random)));
        else if (which < 84)
            inputs.append(stringInput(Kind::FloatingPointList, coordinates(random)));
        else if (which < 89)
            inputs.append(stringInput(Kind::NumberInput, numberInputValue(random)));
        else if (which < 94) {
            static constexpr std::array kinds { Kind::ParseDate, Kind::ParseTime, Kind::ParseDateTimeLocal, Kind::ParseMonth };
            auto kind = random.pick(kinds);
            inputs.append(stringInput(kind, dateString(random, kind, true)));
        } else if (which < 95)
            inputs.append(stringInput(Kind::ParseWeek, weekString(random)));
        else if (which < 97) {
            StringBuilder builder;
            unsigned count = random.between(1, 4);
            for (unsigned entry = 0; entry < count; ++entry) {
                if (entry)
                    builder.append(',');
                appendDimensionsListEntry(builder, random);
            }
            inputs.append(stringInput(Kind::DimensionsList, builder.toString()));
        } else if (which < 98)
            inputs.append(stringInput(Kind::MetaRefresh, metaRefresh(random)));
        else {
            // Integer attributes whose values are not valid integers.
            inputs.append(stringInput(Kind::NonNegativeInteger, integerError(random)));
        }
    }
    return finish(WTF::move(inputs));
}

// The benchmark.

static void run(ASCIILiteral name, Vector<Input>&& inputs, uint64_t expectedChecksum, unsigned passes)
{
    WebCore::ProcessWarming::initializeNames();

    size_t bytes = 0;
    for (auto& input : inputs)
        bytes += inputBytes(input);
    ASSERT_GT(bytes, 0u);

    auto result = checksum(inputs);
    EXPECT_EQ(expectedChecksum, result);
    if (expectedChecksum != result)
        SAFE_PRINTF("%s: checksum=%016llx (expected %016llx)\n", name, static_cast<unsigned long long>(result), static_cast<unsigned long long>(expectedChecksum));
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    unsigned matching = 0;
    auto start = WTF::MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass)
        matching += checksum(inputs) == result;
    auto elapsed = WTF::MonotonicTime::now() - start;
    EXPECT_EQ(passes, matching);
    SAFE_PRINTF("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, elapsed.milliseconds(),
        static_cast<double>(bytes) * passes / elapsed.microseconds(), static_cast<unsigned long long>(result));
}

} // namespace HTMLMicrosyntaxesBenchmark

TEST(HTMLMicrosyntaxesBench, IntegerAttributes) { HTMLMicrosyntaxesBenchmark::run("IntegerAttributes"_s, HTMLMicrosyntaxesBenchmark::integerAttributesInputs(), 0x7b1c6627aed3bab8ULL, 12000); }
TEST(HTMLMicrosyntaxesBench, IntegerErrors) { HTMLMicrosyntaxesBenchmark::run("IntegerErrors"_s, HTMLMicrosyntaxesBenchmark::integerErrorsInputs(), 0x0c0e0c10162cf63bULL, 14000); }
TEST(HTMLMicrosyntaxesBench, Dimensions) { HTMLMicrosyntaxesBenchmark::run("Dimensions"_s, HTMLMicrosyntaxesBenchmark::dimensionsInputs(), 0x3f4991a0b284b0beULL, 10000); }
TEST(HTMLMicrosyntaxesBench, DimensionLists) { HTMLMicrosyntaxesBenchmark::run("DimensionLists"_s, HTMLMicrosyntaxesBenchmark::dimensionListsInputs(), 0xe18f4964beaab212ULL, 4000); }
TEST(HTMLMicrosyntaxesBench, FloatValues) { HTMLMicrosyntaxesBenchmark::run("FloatValues"_s, HTMLMicrosyntaxesBenchmark::floatValuesInputs(), 0x32b577d01aeab906ULL, 12000); }
TEST(HTMLMicrosyntaxesBench, FloatLists) { HTMLMicrosyntaxesBenchmark::run("FloatLists"_s, HTMLMicrosyntaxesBenchmark::floatListsInputs(), 0xc7a31084a543b693ULL, 2000); }
TEST(HTMLMicrosyntaxesBench, NumberInputs) { HTMLMicrosyntaxesBenchmark::run("NumberInputs"_s, HTMLMicrosyntaxesBenchmark::numberInputsInputs(), 0x91b6f2d5e188cc66ULL, 2300); }
TEST(HTMLMicrosyntaxesBench, MetaRefresh) { HTMLMicrosyntaxesBenchmark::run("MetaRefresh"_s, HTMLMicrosyntaxesBenchmark::metaRefreshInputs(), 0x7938e1ed829267e9ULL, 7300); }
TEST(HTMLMicrosyntaxesBench, SrcsetDensities) { HTMLMicrosyntaxesBenchmark::run("SrcsetDensities"_s, HTMLMicrosyntaxesBenchmark::srcsetDensitiesInputs(), 0xf4d6ec0fe5acfc5eULL, 1200); }
TEST(HTMLMicrosyntaxesBench, SrcsetWidths) { HTMLMicrosyntaxesBenchmark::run("SrcsetWidths"_s, HTMLMicrosyntaxesBenchmark::srcsetWidthsInputs(), 0x98671b94c17657c5ULL, 720); }
TEST(HTMLMicrosyntaxesBench, SrcsetLong) { HTMLMicrosyntaxesBenchmark::run("SrcsetLong"_s, HTMLMicrosyntaxesBenchmark::srcsetLongInputs(), 0xc1bae0b84b654846ULL, 160); }
TEST(HTMLMicrosyntaxesBench, MetaCharsetHeads) { HTMLMicrosyntaxesBenchmark::run("MetaCharsetHeads"_s, HTMLMicrosyntaxesBenchmark::metaCharsetHeadsInputs(), 0x0203a7aab1be7ed9ULL, 530); }
TEST(HTMLMicrosyntaxesBench, ParseDates) { HTMLMicrosyntaxesBenchmark::run("ParseDates"_s, HTMLMicrosyntaxesBenchmark::parseDatesInputs(), 0x1637cb7961dcbd3eULL, 6300); }
TEST(HTMLMicrosyntaxesBench, SerializeDates) { HTMLMicrosyntaxesBenchmark::run("SerializeDates"_s, HTMLMicrosyntaxesBenchmark::serializeDatesInputs(), 0xbcd57f483dcc6799ULL, 1900); }
TEST(HTMLMicrosyntaxesBench, DatesFromMilliseconds) { HTMLMicrosyntaxesBenchmark::run("DatesFromMilliseconds"_s, HTMLMicrosyntaxesBenchmark::datesFromMillisecondsInputs(), 0xc9bf14bddc5edacbULL, 3000); }
TEST(HTMLMicrosyntaxesBench, Weeks) { HTMLMicrosyntaxesBenchmark::run("Weeks"_s, HTMLMicrosyntaxesBenchmark::weeksInputs(), 0x18eba02958494f64ULL, 5100); }
TEST(HTMLMicrosyntaxesBench, AttributeMix) { HTMLMicrosyntaxesBenchmark::run("AttributeMix"_s, HTMLMicrosyntaxesBenchmark::attributeMixInputs(), 0x14aa8c73ff0c8f64ULL, 2800); }

} // namespace TestWebKitAPI
