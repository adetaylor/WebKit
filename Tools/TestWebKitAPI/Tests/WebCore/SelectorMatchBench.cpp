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
#include "TestPageHarness.h"
#include <WebCore/CSSSelectorList.h>
#include <WebCore/CSSStyleDeclaration.h>
#include <WebCore/CSSStyleSheet.h>
#include <WebCore/Document.h>
#include <WebCore/Element.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/LocalDOMWindow.h>
#include <WebCore/StyleRule.h>
#include <WebCore/StyleSheetContents.h>
#include <WebCore/StyleSheetList.h>
#include <cstdlib>
#include <optional>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test builds the style rule sets for one generated style sheet in a page's <style> element once, and checks a
// checksum of the result: the selectors of the sheet's style rules as rule set building leaves them (a nested rule's
// selectors resolved against its parents) and the computed style of every element. With WEBKIT_RUN_BENCHMARKS set, it
// then builds them a fixed number of times and prints the time taken.
//
// A pass sets the <style> element's text, which parses the sheet, and updates the document's style, which builds the
// rule sets (nesting resolved, @scope's bounds resolved) and resolves every element; it then changes an element's class,
// which invalidates through the rule sets' features (each :has() scope selector included).
//
// The generators make every random draw in its own statement, so the inputs do not depend on the order in which a
// compiler evaluates function arguments.

namespace TestWebKitAPI {

using namespace WebCore;

namespace SelectorMatchBenchmark {

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

private:
    uint64_t m_state;
};

class Checksum {
public:
    void add(uint64_t value) { m_value = (m_value ^ value) * 0x100000001b3ULL; }

    void add(StringView string)
    {
        if (string.isNull()) {
            add(1ULL << 40);
            return;
        }
        add(string.length());
        for (auto character : string.codeUnits())
            add(character);
    }

    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0xcbf29ce484222325ULL };
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static void printResult(ASCIILiteral name, Seconds elapsed, double bytes, uint64_t checksum)
{
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(), bytes / elapsed.microseconds(),
        static_cast<unsigned long long>(checksum));
}

// MARK: - BuildRuleSetNested.

static constexpr unsigned ruleCount = 2000;
static constexpr unsigned elementCount = 128;
static constexpr unsigned classCount = 32;
// More components than one rule's selector list may have (RuleData::maximumSelectorComponentCount, 8,192), so the
// parser splits the rule.
static constexpr unsigned longListComponents = 8200;

static void appendDeclarations(StringBuilder& builder, Random& random, unsigned& value)
{
    unsigned order = random.below(50);
    builder.append(" z-index: "_s, ++value % 997, "; order: "_s, order, "; "_s);
}

// Nested style rules (an explicit and an implicit &, a relative selector, & in a compound and after a combinator,
// declarations after a nested group rule), @scope with both bounds, inside a style rule and with & and :scope in its
// rules, :has() with each kind of combinator, inside :is() and in nested rules, and two lists longer than a rule may
// hold.
static String nestedSheet()
{
    Random random(4096);
    StringBuilder builder;
    unsigned value = 0;
    for (unsigned rule = 0; rule < ruleCount; ++rule) {
        unsigned kind = random.below(6);
        unsigned a = random.below(classCount);
        unsigned b = random.below(classCount / 2);
        switch (kind) {
        case 0:
            builder.append(".c"_s, a, " {"_s);
            appendDeclarations(builder, random, value);
            builder.append("& > .d"_s, b, " {"_s);
            appendDeclarations(builder, random, value);
            builder.append(".e & {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} } &:hover, .f"_s, b, " & {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} }\n"_s);
            break;
        case 1:
            builder.append(".p"_s, a, " .q"_s, b, " {"_s);
            appendDeclarations(builder, random, value);
            builder.append(".r {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} @media (min-width: 1px) { & .e {"_s);
            appendDeclarations(builder, random, value);
            builder.append("}"_s);
            appendDeclarations(builder, random, value);
            builder.append("} + .z {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} }\n"_s);
            break;
        case 2:
            builder.append("@scope (.s"_s, a, ") to (.t"_s, b, ") { .u {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} & .v {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} :scope > .t"_s, b, " .w {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} }\n"_s);
            break;
        case 3:
            builder.append(".x"_s, a, " {"_s);
            appendDeclarations(builder, random, value);
            builder.append("@scope (& > .y"_s, b, ") to (.z) { .r {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} & .e {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} } }\n"_s);
            break;
        case 4: {
            unsigned form = random.below(3);
            if (!form)
                builder.append(".a"_s, a, ":has(> .b"_s, b, ") {"_s);
            else if (form == 1)
                builder.append(".x"_s, a, " :is(.y"_s, b, ":has(+ .z, ~ .f"_s, b, ")) {"_s);
            else
                builder.append("div.h"_s, a, ":not(.k"_s, b, ":has(.e .w)) > .q"_s, b, " {"_s);
            appendDeclarations(builder, random, value);
            builder.append("}\n"_s);
            break;
        }
        default:
            builder.append(".h"_s, a, " {"_s);
            appendDeclarations(builder, random, value);
            builder.append("&:has(.k"_s, b, ") {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} :has(> &) .u {"_s);
            appendDeclarations(builder, random, value);
            builder.append("} }\n"_s);
            break;
        }
    }
    for (unsigned i = 0; i < longListComponents; ++i)
        builder.append(i ? ", .l"_s : ".l"_s, i);
    builder.append(" {"_s);
    appendDeclarations(builder, random, value);
    builder.append("}\n:is("_s);
    for (unsigned i = 0; i < longListComponents; ++i)
        builder.append(i ? ", .m"_s : ".m"_s, i);
    builder.append(") .w {"_s);
    appendDeclarations(builder, random, value);
    builder.append("}\n"_s);
    return builder.toString();
}

// Elements carrying the classes the sheet's selectors name, two levels deep, each with an id.
static String nestedDocument()
{
    StringBuilder html;
    html.append("<!DOCTYPE html><html><head><style id='sheet'></style></head><body>"_s);
    for (unsigned i = 0; i < elementCount; ++i) {
        unsigned a = i % classCount;
        unsigned b = i % (classCount / 2);
        html.append("<div id='e"_s, i, "' class='c"_s, a, " p"_s, a, " s"_s, a, " x"_s, a, " a"_s, a, " h"_s, a, " l"_s, i, " m"_s, i, "'>"_s);
        html.append("<div id='f"_s, i, "' class='d"_s, b, " q"_s, b, " t"_s, b, " y"_s, b, " b"_s, b, " k"_s, b, " f"_s, b, "'>"_s);
        html.append("<span id='g"_s, i, "' class='e r u v w'></span></div><span id='h"_s, i, "' class='z f"_s, b, "'></span></div>"_s);
    }
    html.append("</body></html>"_s);
    return html.toString();
}

struct RuleCounts {
    unsigned styleRules { 0 };
    unsigned nestedRules { 0 };
    unsigned splitRules { 0 };
    unsigned scopeRules { 0 };
    unsigned hasSelectors { 0 };
};

// A style rule's selectors as rule set building left them, then its nested style rules'.
static void addStyleRule(Checksum& checksum, const StyleRule& rule, RuleCounts& counts)
{
    ++counts.styleRules;
    counts.splitRules += rule.isSplitRule();
    auto text = rule.selectorList().selectorsText();
    counts.hasSelectors += text.contains(":has("_s);
    checksum.add(rule.selectorList().componentCount());
    checksum.add(text);
    auto* withNesting = dynamicDowncast<StyleRuleWithNesting>(rule);
    if (!withNesting)
        return;
    for (auto& nested : withNesting->nestedRules()) {
        checksum.add(static_cast<uint64_t>(nested->type()));
        if (auto* nestedStyleRule = dynamicDowncast<StyleRule>(nested.get())) {
            ++counts.nestedRules;
            addStyleRule(checksum, *nestedStyleRule, counts);
        }
    }
}

class NestedPage {
public:
    NestedPage()
        : m_page(TestPageHarness::create())
    {
        m_page.loadHTML(nestedDocument());
        m_style = m_page.getElementById("sheet"_s);
        m_toggled = m_page.getElementById("f0"_s);
        RELEASE_ASSERT(m_style && m_toggled);
    }

    // A different text each pass: an inline sheet's parsed contents are cached by text, and a cached sheet's nested
    // rules keep the selectors they were resolved to.
    void build(const String& sheet, unsigned pass)
    {
        auto setText = m_style->setTextContent(makeString(sheet, "/* "_s, pass, " */"_s));
        RELEASE_ASSERT(!setText.hasException());
        m_page.document().updateStyleIfNeeded();
        auto setClass = m_toggled->setAttribute(AtomString { "class"_s }, AtomString { pass % 2 ? "d1 q1 k2"_s : "d1 q1 k1"_s });
        RELEASE_ASSERT(!setClass.hasException());
        m_page.document().updateStyleIfNeeded();
    }

    uint64_t checksum(RuleCounts& counts)
    {
        Checksum checksum;
        Ref sheets = m_page.document().styleSheets();
        RefPtr styleSheet = sheets->item(0);
        RefPtr sheet = dynamicDowncast<CSSStyleSheet>(styleSheet.get());
        EXPECT_TRUE(!!sheet);
        if (!sheet)
            return 0;
        auto& rules = sheet->contents().childRules();
        checksum.add(rules.size());
        for (auto& rule : rules) {
            checksum.add(static_cast<uint64_t>(rule->type()));
            counts.scopeRules += rule->isScopeRule();
            if (auto* styleRule = dynamicDowncast<StyleRule>(rule.get()))
                addStyleRule(checksum, *styleRule, counts);
        }
        RefPtr window = m_page.document().window();
        for (unsigned i = 0; i < elementCount; ++i) {
            for (auto prefix : { 'e', 'f', 'g', 'h' }) {
                RefPtr element = m_page.getElementById(makeString(prefix, i));
                checksum.add(!!element);
                if (!element)
                    continue;
                Ref style = window->getComputedStyle(*element, String { });
                checksum.add(style->getPropertyValue("z-index"_s));
                checksum.add(style->getPropertyValue("order"_s));
            }
        }
        return checksum.value();
    }

private:
    TestPageHarness m_page;
    RefPtr<Element> m_style;
    RefPtr<Element> m_toggled;
};

static void runBuildRuleSetNested(ASCIILiteral name, std::optional<uint64_t> expectedChecksum, unsigned passes)
{
    auto sheet = nestedSheet();
    NestedPage page;
    page.build(sheet, 0);
    RuleCounts counts;
    auto checksum = page.checksum(counts);
    EXPECT_GT(counts.nestedRules, 0u);
    EXPECT_GT(counts.scopeRules, 0u);
    EXPECT_GT(counts.hasSelectors, 0u);
    EXPECT_EQ(counts.splitRules, 2u);
    EXPECT_GT(counts.styleRules, ruleCount);
    if (expectedChecksum)
        EXPECT_EQ(*expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    auto start = MonotonicTime::now();
    for (unsigned pass = 1; pass <= passes; ++pass)
        page.build(sheet, pass);
    auto elapsed = MonotonicTime::now() - start;
    printResult(name, elapsed, static_cast<double>(sheet.length()) * passes, checksum);
}

} // namespace SelectorMatchBenchmark

using namespace SelectorMatchBenchmark;

// Each platform records its own checksum, because the computed values depend on what the platform's ENABLE() and HAVE()
// features leave out of the generated property and pseudo-class tables (CSSRulesBench.cpp). Ports other than Cocoa and
// Windows have no recorded checksum and check only the counts. The pass count makes a full run about a second.
static constexpr std::optional<uint64_t> platformChecksum(uint64_t cocoa, uint64_t windows)
{
#if PLATFORM(COCOA)
    UNUSED_PARAM(windows);
    return cocoa;
#elif OS(WINDOWS)
    UNUSED_PARAM(cocoa);
    return windows;
#else
    UNUSED_PARAM(cocoa);
    UNUSED_PARAM(windows);
    return std::nullopt;
#endif
}

TEST(SelectorMatchBench, BuildRuleSetNested) { runBuildRuleSetNested("BuildRuleSetNested"_s, platformChecksum(0, 0x3723969911b4b5afULL), 20); }

} // namespace TestWebKitAPI
