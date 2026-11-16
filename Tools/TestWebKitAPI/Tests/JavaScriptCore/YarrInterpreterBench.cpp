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
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/RegularExpression.h>
#include <JavaScriptCore/YarrFlags.h>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Throughput of the regular expression bytecode compiler and interpreter, one TEST per kind of pattern, through
// JSC::Yarr::RegularExpression, which always compiles to bytecode and interprets it. Each TEST runs its patterns over
// generated subjects, in 8-bit and 16-bit form where the matcher's reads differ, and finds every match from left to
// right. By default it does this once and checks a checksum of the match positions and lengths. With
// WEBKIT_RUN_BENCHMARKS=1 in the environment it then repeats the pass a fixed number of times and prints
// "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>", with the same checksum. Nothing asserts on time.

namespace TestWebKitAPI {

namespace {

using JSC::Yarr::Flags;
using JSC::Yarr::MatchMode;
using JSC::Yarr::RegularExpression;

class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned n)
    {
        m_state = m_state * 1664525u + 1013904223u;
        return (m_state >> 8) % n;
    }

private:
    uint32_t m_state;
};

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= (word >> (8 * i)) & 0xff;
            value *= 1099511628211ull;
        }
    }
};

struct PatternSpec {
    ASCIILiteral pattern;
    OptionSet<Flags> flags;
    MatchMode mode { MatchMode::Partial };
};

struct Shape {
    Vector<PatternSpec> patterns;
    Vector<String> subjects;
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static size_t byteLength(const String& string)
{
    return string.length() * (string.is8Bit() ? 1 : 2);
}

// The same text in 16-bit form: a character outside Latin-1 at its end makes the string 16-bit and is not part of any
// pattern's matches.
static String sixteenBit(const String& string)
{
    StringBuilder builder;
    builder.append(string);
    builder.append(static_cast<char16_t>(0x2603));
    String result = builder.toString();
    EXPECT_FALSE(result.is8Bit());
    return result;
}

static const std::array<ASCIILiteral, 24> words { {
    "the"_s, "quick"_s, "brown"_s, "fox"_s, "jumps"_s, "over"_s, "lazy"_s, "dog"_s, "function"_s, "return"_s, "value"_s,
    "string"_s, "number"_s, "object"_s, "array"_s, "length"_s, "index"_s, "match"_s, "pattern"_s, "regular"_s,
    "expression"_s, "running"_s, "unhappy"_s, "happy"_s
} };

static String proseText(uint32_t seed, unsigned wordCount)
{
    Generator generator(seed);
    StringBuilder builder;
    for (unsigned i = 0; i < wordCount; ++i) {
        if (i)
            builder.append(generator.below(12) ? " "_s : (generator.below(2) ? ".\n"_s : ", "_s));
        switch (generator.below(16)) {
        case 0:
            builder.append(generator.below(100000));
            break;
        case 1:
            builder.append('$', generator.below(1000), '.', generator.below(100));
            break;
        case 2:
            builder.append("needle"_s);
            break;
        case 3: {
            auto word = words[generator.below(words.size())];
            builder.append(word, ' ', word);
            break;
        }
        case 4:
            builder.append('"', words[generator.below(words.size())], '"');
            break;
        case 5:
            builder.append("Hello World"_s);
            break;
        default:
            builder.append(words[generator.below(words.size())]);
            break;
        }
    }
    return builder.toString();
}

static String codeText(uint32_t seed, unsigned statementCount)
{
    static const std::array<ASCIILiteral, 12> statements { {
        "function f(a, b) {"_s, "return a + b;"_s, "var x = 10;"_s, "let y = \"str\";"_s, "const z = [1, 2, 3];"_s,
        "if (x < y) {"_s, "} else {"_s, "while (i--) {"_s, "for (let i = 0; i < n; ++i) {"_s, "}"_s,
        "obj.property = value;"_s, "// comment about returning"_s
    } };
    Generator generator(seed);
    StringBuilder builder;
    for (unsigned i = 0; i < statementCount; ++i) {
        builder.append(statements[generator.below(statements.size())]);
        builder.append('\n');
    }
    return builder.toString();
}

static uint64_t runPass(const Vector<RegularExpression>& expressions, const Shape& shape, Checksum* checksum)
{
    uint64_t matches = 0;
    for (auto& expression : expressions) {
        for (auto& subject : shape.subjects) {
            unsigned start = 0;
            while (start <= subject.length()) {
                int matchLength = 0;
                int position = expression.match(subject, start, &matchLength);
                if (checksum) {
                    checksum->add(static_cast<uint32_t>(position));
                    checksum->add(static_cast<uint32_t>(matchLength));
                }
                if (position < 0)
                    break;
                ++matches;
                start = static_cast<unsigned>(position) + std::max(matchLength, 1);
            }
        }
    }
    return matches;
}

static Vector<RegularExpression> compile(const Shape& shape)
{
    Vector<RegularExpression> expressions;
    for (auto& spec : shape.patterns) {
        expressions.append(RegularExpression(StringView(spec.pattern), spec.flags, spec.mode));
        EXPECT_TRUE(expressions.last().isValid()) << spec.pattern.characters();
    }
    return expressions;
}

static void report(ASCIILiteral name, double seconds, double bytes, uint64_t checksum)
{
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum));
}

static void runMatchBenchmark(ASCIILiteral name, Shape&& shape, unsigned iterations, uint64_t expectedChecksum)
{
    JSC::initialize();
    auto expressions = compile(shape);

    Checksum checksum;
    runPass(expressions, shape, &checksum);
    EXPECT_EQ(checksum.value, expectedChecksum) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;

    if (!runsBenchmarks())
        return;

    size_t bytesPerPass = 0;
    for (auto& subject : shape.subjects)
        bytesPerPass += byteLength(subject);
    bytesPerPass *= expressions.size();

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i)
        runPass(expressions, shape, nullptr);
    double seconds = (MonotonicTime::now() - start).seconds();
    report(name, seconds, static_cast<double>(bytesPerPass) * iterations, checksum.value);
}

static Shape withBothWidths(Vector<PatternSpec>&& patterns, Vector<String>&& subjects)
{
    Shape shape { WTF::move(patterns), { } };
    for (auto& subject : subjects) {
        shape.subjects.append(subject);
        shape.subjects.append(sixteenBit(subject));
    }
    return shape;
}

} // namespace

// A literal, matched by its characters with no class lookup.
TEST(YarrInterpreterBench, LiteralSearch)
{
    runMatchBenchmark("LiteralSearch"_s, withBothWidths({
        { "needle"_s, { } },
        { "quick brown"_s, { } },
    }, { proseText(1, 8000) }), 700, 0xea5897f63f0a601full);
}

// Greedy character classes: digits, and identifiers.
TEST(YarrInterpreterBench, CharacterClassScan)
{
    runMatchBenchmark("CharacterClassScan"_s, withBothWidths({
        { "\\d+"_s, { } },
        { "[a-z_]\\w*"_s, { } },
    }, { proseText(2, 6000) }), 900, 0x5bfc7924b90d0d1bull);
}

// Case-insensitive literals, Latin-1 and not, without and with the UnicodeSets flag.
TEST(YarrInterpreterBench, CaseInsensitive)
{
    StringBuilder greek;
    Generator generator(3);
    for (unsigned i = 0; i < 4000; ++i) {
        static const std::array<const char*, 4> parts { { "\xCE\xA3\xCE\xBF\xCF\x86\xCE\xAF\xCE\xB1 ", "stra\xC3\x9F" "e ", "HELLO world ", "\xCF\x83\xCE\xBF\xCF\x86\xCE\xAF\xCE\xB1 " } };
        greek.append(String::fromUTF8(parts[generator.below(parts.size())]));
    }
    Shape shape = withBothWidths({
        { "hello world"_s, { Flags::IgnoreCase } },
        { "stra\\u00dfe|\\u03c3\\u03bf\\u03c6\\u03af\\u03b1"_s, { Flags::IgnoreCase, Flags::UnicodeSets } },
    }, { proseText(3, 6000) });
    shape.subjects.append(greek.toString());
    runMatchBenchmark("CaseInsensitive"_s, WTF::move(shape), 420, 0x0c3b250831f0459aull);
}

// Keyword alternation with word boundaries.
TEST(YarrInterpreterBench, Alternation)
{
    runMatchBenchmark("Alternation"_s, withBothWidths({
        { "\\b(?:function|return|var|let|const|if|else|while|for)\\b"_s, { } },
    }, { codeText(4, 3000) }), 390, 0xde918686ea28bd63ull);
}

// Back references to a captured word and to a quote.
TEST(YarrInterpreterBench, BackReference)
{
    runMatchBenchmark("BackReference"_s, withBothWidths({
        { "\\b(\\w+) \\1\\b"_s, { } },
        { "(['\"])[^'\"]*\\1"_s, { } },
    }, { proseText(5, 4000) }), 700, 0x25ea2f7bf6f4d7afull);
}

// Nested quantified groups that backtrack heavily on subjects that almost match.
TEST(YarrInterpreterBench, Backtracking)
{
    auto repeated = [](char character, unsigned length, ASCIILiteral suffix) {
        StringBuilder builder;
        for (unsigned i = 0; i < length; ++i)
            builder.append(character);
        builder.append(suffix);
        return builder.toString();
    };
    Vector<String> subjects;
    for (unsigned length = 8; length <= 14; ++length)
        subjects.append(repeated('x', length, "z"_s));
    for (unsigned length = 4; length <= 40; length += 4)
        subjects.append(repeated('a', length, "ab"_s));
    runMatchBenchmark("Backtracking"_s, withBothWidths({
        { "(x+x+)+y"_s, { } },
        { "^(?:a|ab|aab)*c"_s, { } },
    }, WTF::move(subjects)), 750, 0x51aafa96f503e5f3ull);
}

// Lookahead and lookbehind, positive and negative.
TEST(YarrInterpreterBench, Lookaround)
{
    runMatchBenchmark("Lookaround"_s, withBothWidths({
        { "(?<=\\$)\\d+(?=\\.)"_s, { } },
        { "\\b\\w+(?=ing\\b)"_s, { } },
        { "(?<!un)happy"_s, { } },
    }, { proseText(7, 3000) }), 600, 0x8d3d78eef81d942full);
}

// Class set operations under the v flag.
TEST(YarrInterpreterBench, UnicodeSets)
{
    runMatchBenchmark("UnicodeSets"_s, withBothWidths({
        { "[\\p{L}--[a-z]]+"_s, { Flags::UnicodeSets } },
        { "[[a-z]&&[^aeiou]]+"_s, { Flags::UnicodeSets } },
        { "[\\p{Nd}\\q{needle|fox}]+"_s, { Flags::UnicodeSets } },
    }, { proseText(8, 3000) }), 520, 0x23ddb4a2ba5ae90bull);
}

// Named groups, and duplicate names in alternatives.
TEST(YarrInterpreterBench, NamedGroups)
{
    Generator generator(9);
    StringBuilder builder;
    for (unsigned i = 0; i < 3000; ++i) {
        unsigned year = 1900 + generator.below(200);
        unsigned month = 1 + generator.below(12);
        unsigned day = 1 + generator.below(28);
        if (generator.below(2))
            builder.append(year, '-', month < 10 ? "0"_s : ""_s, month, '-', day < 10 ? "0"_s : ""_s, day, ' ');
        else
            builder.append(month < 10 ? "0"_s : ""_s, month, '/', day < 10 ? "0"_s : ""_s, day, '/', year, ' ');
        builder.append(words[generator.below(words.size())], ' ');
    }
    runMatchBenchmark("NamedGroups"_s, withBothWidths({
        { "(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})"_s, { } },
        { "(?<year>\\d{4})-(?<month>\\d{2})-\\d{2}|(?<month>\\d{2})/\\d{2}/(?<year>\\d{4})"_s, { Flags::UnicodeSets } },
    }, { builder.toString() }), 420, 0x4ebab26cfd3f6bc3ull);
}

// Every match of a short pattern over a long text, as a global scan does.
TEST(YarrInterpreterBench, GlobalIteration)
{
    runMatchBenchmark("GlobalIteration"_s, withBothWidths({
        { "\\w+"_s, { } },
        { "[,.]"_s, { } },
    }, { proseText(10, 10000) }), 520, 0x041c89ac215dc097ull);
}

// Patterns of <input pattern> and of an email check, matched against the whole of many short values.
TEST(YarrInterpreterBench, InputPattern)
{
    Generator generator(11);
    Vector<String> values;
    for (unsigned i = 0; i < 2000; ++i) {
        switch (generator.below(4)) {
        case 0:
            values.append(makeString(words[generator.below(words.size())], '.', words[generator.below(words.size())], '@', words[generator.below(words.size())], ".com"_s));
            break;
        case 1:
            values.append(makeString(100 + generator.below(900), '-', 100 + generator.below(900), '-', 1000 + generator.below(9000)));
            break;
        case 2:
            values.append(makeString(words[generator.below(words.size())], generator.below(1000)));
            break;
        default:
            values.append(makeString(words[generator.below(words.size())], " @ "_s, generator.below(100)));
            break;
        }
    }
    runMatchBenchmark("InputPattern"_s, withBothWidths({
        { "[a-zA-Z0-9.!#$%&'*+\\/=?^_`\\{\\|\\}~\\-]+@[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?)*"_s, { Flags::UnicodeSets }, MatchMode::EntireInput },
        { "\\d{3}-\\d{3}-\\d{4}"_s, { Flags::UnicodeSets }, MatchMode::EntireInput },
        { "[a-z]+[0-9]*"_s, { Flags::UnicodeSets }, MatchMode::EntireInput },
    }, WTF::move(values)), 1400, 0x021660f070b3670eull);
}

// The regular expressions URLPattern compiles for path patterns, against many paths.
TEST(YarrInterpreterBench, URLPatternMatch)
{
    Generator generator(12);
    Vector<String> paths;
    for (unsigned i = 0; i < 2000; ++i) {
        switch (generator.below(3)) {
        case 0:
            paths.append(makeString('/', words[generator.below(words.size())], "/books/"_s, generator.below(10000)));
            break;
        case 1:
            paths.append(makeString("/api/v"_s, generator.below(3), '/', words[generator.below(words.size())], '/', words[generator.below(words.size())]));
            break;
        default:
            paths.append(makeString('/', words[generator.below(words.size())], ".html"_s));
            break;
        }
    }
    runMatchBenchmark("URLPatternMatch"_s, withBothWidths({
        { "^(?:\\/(?:([^\\/#\\?]+?))\\/books\\/(?:([^\\/#\\?]+?)))[\\/#\\?]?$"_s, { Flags::UnicodeSets } },
        { "^(?:\\/api\\/v(?:(\\d+))\\/(?:([^\\/#\\?]+?))(?:\\/(.*))?)[\\/#\\?]?$"_s, { Flags::UnicodeSets, Flags::IgnoreCase } },
        { "^(?:\\/(?:([^\\/#\\?]+?))\\.html)[\\/#\\?]?$"_s, { Flags::UnicodeSets } },
    }, WTF::move(paths)), 1000, 0x72096ad2242fa95cull);
}

// Compiling: the parse and the bytecode compile of larger patterns, each then matched once against a short subject.
TEST(YarrInterpreterBench, ByteCompile)
{
    JSC::initialize();
    static const std::array<PatternSpec, 8> specs { {
        { "^(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)$"_s, { } },
        { "^(([^<>()\\[\\]\\\\.,;:\\s@\"]+(\\.[^<>()\\[\\]\\\\.,;:\\s@\"]+)*)|(\".+\"))@((\\[[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}])|(([a-zA-Z\\-0-9]+\\.)+[a-zA-Z]{2,}))$"_s, { } },
        { "(?<scheme>[a-z][a-z0-9+.-]*):\\/\\/(?<host>[^\\/:?#]+)(?::(?<port>\\d+))?(?<path>\\/[^?#]*)?(?:\\?(?<query>[^#]*))?(?:#(?<fragment>.*))?"_s, { Flags::IgnoreCase } },
        { "\\b(?:abstract|arguments|await|boolean|break|byte|case|catch|char|class|const|continue|debugger|default|delete|do|double|else|enum|eval|export|extends|false|final|finally|float|for|function|goto|if|implements|import|in|instanceof|int|interface|let|long|native|new|null|package|private|protected|public|return|short|static|super|switch|synchronized|this|throw|throws|transient|true|try|typeof|var|void|volatile|while|with|yield)\\b"_s, { } },
        { "[\\p{Script=Greek}\\p{Script=Cyrillic}]+(?:\\s+[\\p{L}\\p{M}]+)*"_s, { Flags::UnicodeSets } },
        { "(?<=\\b(?:Mr|Mrs|Ms|Dr)\\.\\s)(?<name>[A-Z][a-z]+)(?:\\s(?<last>[A-Z][a-z]+))?(?!\\w)"_s, { } },
        { "^\\s*(?:(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:e[+-]?\\d+)?\\s*(?:px|em|rem|%|vh|vw)?\\s*,?\\s*){1,4}$"_s, { Flags::IgnoreCase } },
        { "[[\\p{L}\\p{N}]--[\\p{Script=Latin}]]+|\\q{abc|def|ghi}"_s, { Flags::UnicodeSets } },
    } };
    String subject = "Dr. Smith http://example.com:8080/a/b?c#d 192.168.0.1 return 1.5em"_s;

    auto runOnce = [&](Checksum* checksum) {
        for (auto& spec : specs) {
            RegularExpression expression(StringView(spec.pattern), spec.flags, spec.mode);
            int matchLength = 0;
            int position = expression.match(subject, 0, &matchLength);
            if (checksum) {
                checksum->add(expression.isValid());
                checksum->add(static_cast<uint32_t>(position));
                checksum->add(static_cast<uint32_t>(matchLength));
            }
        }
    };

    Checksum checksum;
    runOnce(&checksum);
    EXPECT_EQ(checksum.value, 0xa3c125a640143e0dull) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;

    if (!runsBenchmarks())
        return;

    size_t bytesPerPass = 0;
    for (auto& spec : specs)
        bytesPerPass += spec.pattern.length();
    constexpr unsigned iterations = 700;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i)
        runOnce(nullptr);
    double seconds = (MonotonicTime::now() - start).seconds();
    report("ByteCompile"_s, seconds, static_cast<double>(bytesPerPass) * iterations, checksum.value);
}

// Patterns of the kind JavaScript programs use on text, over prose and code.
TEST(YarrInterpreterBench, RealisticMix)
{
    runMatchBenchmark("RealisticMix"_s, withBothWidths({
        { "\\s+$"_s, { Flags::Multiline } },
        { "^\\s+|\\s+$"_s, { } },
        { "[\"\\\\\\n\\r\\u2028\\u2029]"_s, { } },
        { "\\b[A-Z][a-z]+\\b"_s, { } },
        { "(\\d+)\\.(\\d+)"_s, { } },
        { "[^\\w\\s]"_s, { } },
        { "function\\s*\\(([^)]*)\\)"_s, { } },
        { "[\\s\\S]*?ing"_s, { } },
    }, { proseText(14, 3000), codeText(14, 1000) }), 120, 0xec2e992ceaa57138ull);
}

} // namespace TestWebKitAPI
