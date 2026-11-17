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
#include <WebCore/CSSCustomPropertyValue.h>
#include <WebCore/CSSGroupingRule.h>
#include <WebCore/CSSParser.h>
#include <WebCore/CSSParserContext.h>
#include <WebCore/CSSParserToken.h>
#include <WebCore/CSSParserTokenRange.h>
#include <WebCore/CSSProperty.h>
#include <WebCore/CSSPropertyNames.h>
#include <WebCore/CSSRule.h>
#include <WebCore/CSSRuleList.h>
#include <WebCore/CSSSelector.h>
#include <WebCore/CSSSelectorList.h>
#include <WebCore/CSSSelectorParser.h>
#include <WebCore/CSSSerializationContext.h>
#include <WebCore/CSSStyleRule.h>
#include <WebCore/CSSStyleSheet.h>
#include <WebCore/CSSSupportsParser.h>
#include <WebCore/CSSTokenizer.h>
#include <WebCore/CSSValue.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/MutableStyleProperties.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/StyleProperties.h>
#include <WebCore/StylePropertiesInlines.h>
#include <WebCore/StyleRule.h>
#include <WebCore/StyleSheetContents.h>
#include <algorithm>
#include <array>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <span>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test parses its inputs once through one of the CSS parser's public entry points and checks a checksum of what
// was parsed: the rule tree (each rule's kind, its CSSOM text, each style rule's selector components, specificities
// and selector text, its declarations' properties and values), the @supports results, the CSSOM insertRule results
// and the tokens' unit types. With WEBKIT_RUN_BENCHMARKS set, it then parses them a fixed number of times and prints
// the time taken; the timed passes only parse.
//
// The entry points are the ones WebCore's own callers use: style sheets through StyleSheetContents::parseString,
// declaration blocks through CSSParser::parseDeclarationList, selector strings through
// CSSSelectorParser::parseSelectorList (as querySelector parses them), @supports conditions through
// CSSSupportsParser::supportsCondition in both of its modes (as @supports and CSS.supports() parse them), rules
// through CSSStyleSheet::insertRule on one sheet and the CSSOM's insertRule on a style rule, and dimensions through
// CSSTokenizer.
//
// The generators make every random draw in its own statement, so the inputs do not depend on the order in which a
// compiler evaluates function arguments.

namespace TestWebKitAPI {

using namespace WebCore;

namespace CSSRulesBenchmark {

static constexpr unsigned generatedLength = 1 << 20;

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

    bool percent(unsigned chance) { return below(100) < chance; }

    template<typename T, size_t size>
    const T& pick(const T (&values)[size]) { return values[below(size)]; }

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

static size_t stringBytes(const Vector<String>& strings)
{
    size_t bytes = 0;
    for (auto& string : strings)
        bytes += string.length();
    return bytes;
}

// MARK: - Source files.

static String sourceRoot()
{
    // __FILE__ is written with the platform's path separators.
    StringView file = StringView::fromLatin1(__FILE__);
    for (auto directory : { "/Tools/TestWebKitAPI/"_s, "\\Tools\\TestWebKitAPI\\"_s }) {
        if (auto end = file.find(directory); end != notFound)
            return file.left(end).toString();
    }
    return { };
}

static String readFile(const String& path)
{
    auto contents = FileSystem::readEntireFile(path);
    if (!contents)
        return { };
    return String::fromUTF8ReplacingInvalidSequences(contents->span());
}

static String readSourceFile(ASCIILiteral relativePath)
{
    return readFile(makeString(sourceRoot(), '/', relativePath));
}

// MARK: - Contexts.

// The user agent sheets are parsed in UASheetMode, with the features WebCore turns on for them (the context
// CSSParserContext(UASheetMode) makes, built here from the strict context, whose constructor a test cannot call).
static const CSSParserContext& userAgentSheetContext()
{
    static NeverDestroyed<CSSParserContext> context = [] {
        CSSParserContext context = strictCSSParserContext();
        context.mode = UASheetMode;
        context.cssAppearanceBaseEnabled = true;
        context.cssRubyDisplayTypesEnabled = true;
        context.cssTextTransformMathAutoEnabled = true;
        context.popoverAttributeEnabled = true;
        context.propertySettings.cssInputSecurityEnabled = true;
        context.propertySettings.supportHDRDisplayEnabled = true;
        context.propertySettings.cssFieldSizingEnabled = true;
        context.cssMathDepthEnabled = true;
        context.propertySettings.cssMathDepthEnabled = true;
#if HAVE(CORE_MATERIAL)
        context.propertySettings.useSystemAppearance = true;
#endif
        context.cssInternalAutoBaseParsingEnabled = true;
        context.htmlEnhancedSelectEnabled = true;
        context.openPseudoClassEnabled = true;
        return context;
    }();
    return context.get();
}

// Every shape's checksum reads serializations that use the names table, which a process fills only when it makes a
// Document or warms up: without this, a shape's checksum would depend on which shapes ran before it.
static const CSSParserContext& setUp()
{
    ProcessWarming::initializeNames();
    return strictCSSParserContext();
}

// MARK: - Digests.

static void addSelectorList(Checksum&, const CSSSelectorList&);

// One simple selector: its match, relation and flags, and the parts of it that its match uses.
static void addSimpleSelector(Checksum& checksum, const CSSSelector& selector)
{
    auto match = selector.match();
    checksum.add(static_cast<uint64_t>(match) | static_cast<uint64_t>(selector.relation()) << 8
        | static_cast<uint64_t>(!selector.precedingInComplexSelector()) << 16 | static_cast<uint64_t>(selector.isImplicit()) << 17
        | static_cast<uint64_t>(selector.isForPage()) << 18 | static_cast<uint64_t>(selector.isEquivalentToClassSelector()) << 19
        | static_cast<uint64_t>(selector.attributeMatchType()) << 20);
    switch (match) {
    case CSSSelector::Match::Tag:
        checksum.add(selector.tagQName().prefix());
        checksum.add(selector.tagQName().localName());
        checksum.add(selector.tagQName().namespaceURI());
        return;
    case CSSSelector::Match::PseudoClass:
        checksum.add(static_cast<uint64_t>(selector.pseudoClass()));
        break;
    case CSSSelector::Match::PseudoElement:
        checksum.add(static_cast<uint64_t>(selector.pseudoElement()));
        break;
    case CSSSelector::Match::PagePseudoClass:
        checksum.add(static_cast<uint64_t>(selector.pagePseudoClass()));
        break;
    default:
        break;
    }
    checksum.add(selector.value());
    checksum.add(selector.serializingValue());
    if (selector.isAttributeSelector()) {
        checksum.add(selector.attribute().prefix());
        checksum.add(selector.attribute().localName());
        checksum.add(selector.attribute().namespaceURI());
    }
    checksum.add(selector.argument());
    if (auto* integers = selector.integerList()) {
        checksum.add(integers->size());
        for (int integer : *integers)
            checksum.add(static_cast<uint64_t>(static_cast<int64_t>(integer)));
    }
    if (auto* strings = selector.stringList()) {
        checksum.add(strings->size());
        for (auto& string : *strings)
            checksum.add(string);
    }
    if (auto* languages = selector.langList()) {
        checksum.add(languages->size());
        for (auto& language : *languages) {
            checksum.add(language.identifier);
            checksum.add(language.wasQuoted);
        }
    }
    auto* list = selector.selectorList();
    checksum.add(!!list);
    if (list)
        addSelectorList(checksum, *list);
}

// A selector list: its component and complex-selector counts, each complex selector's specificity, then every
// component in order.
static void addSelectorList(Checksum& checksum, const CSSSelectorList& list)
{
    checksum.add(list.componentCount());
    uint64_t complexSelectors = 0;
    for (auto& complexSelector : list) {
        checksum.add(complexSelector.computeSpecificity());
        ++complexSelectors;
    }
    checksum.add(complexSelectors);
    for (unsigned i = 0; i < list.componentCount(); ++i)
        addSimpleSelector(checksum, list.selectorAt(i));
}

// Each declaration's property, flags, the shorthand that set it and its value's text (a custom property's name too).
static void addProperties(Checksum& checksum, const StyleProperties& properties)
{
    auto& serialization = CSS::defaultSerializationContext();
    unsigned count = properties.propertyCount();
    checksum.add(count);
    for (unsigned i = 0; i < count; ++i) {
        auto reference = properties.propertyAt(i);
        auto property = reference.toCSSProperty();
        auto& metadata = property.metadata();
        checksum.add(static_cast<uint64_t>(reference.id()) | static_cast<uint64_t>(reference.isImportant()) << 16
            | static_cast<uint64_t>(reference.isImplicit()) << 17 | static_cast<uint64_t>(metadata.m_isSetFromShorthand) << 18
            | static_cast<uint64_t>(metadata.m_indexInShorthandsVector) << 20);
        auto* value = reference.value();
        checksum.add(!!value);
        if (!value)
            continue;
        if (auto* custom = dynamicDowncast<CSSCustomPropertyValue>(*value))
            checksum.add(custom->name());
        checksum.add(value->cssText(serialization));
    }
}

struct RuleCounts {
    unsigned rules { 0 };
    unsigned styleRules { 0 };
};

// A rule through its CSSOM wrapper: its kind, and for a style rule its selector text, its selector components and
// its declarations; then its child rules, recursively, for a style rule or a grouping rule.
static void addCSSOMRule(Checksum& checksum, CSSRule& rule, RuleCounts& counts)
{
    ++counts.rules;
    checksum.add(static_cast<uint64_t>(rule.styleRuleType()));
    CSSRuleList* children = nullptr;
    if (auto* styleRule = dynamicDowncast<CSSStyleRule>(rule)) {
        ++counts.styleRules;
        checksum.add(styleRule->selectorText());
        addSelectorList(checksum, styleRule->styleRule().selectorList());
        addProperties(checksum, styleRule->styleRule().properties());
        children = &styleRule->cssRules();
    } else if (auto* groupingRule = dynamicDowncast<CSSGroupingRule>(rule))
        children = &groupingRule->cssRules();
    checksum.add(!!children);
    if (!children)
        return;
    unsigned length = children->length();
    checksum.add(length);
    for (unsigned i = 0; i < length; ++i) {
        RefPtr child = children->item(i);
        checksum.add(!!child);
        if (child)
            addCSSOMRule(checksum, *child, counts);
    }
}

// A top-level rule: its kind, its @supports result if it is one, its whole CSSOM text and its CSSOM tree.
static void addRule(Checksum& checksum, const StyleRuleBase& rule, RuleCounts& counts)
{
    checksum.add(static_cast<uint64_t>(rule.type()));
    if (auto* supports = dynamicDowncast<StyleRuleSupports>(rule)) {
        checksum.add(supports->conditionText());
        checksum.add(supports->conditionIsSupported());
    }
    Ref wrapper = rule.createCSSOMWrapper();
    checksum.add(wrapper->cssText());
    addCSSOMRule(checksum, wrapper.get(), counts);
}

static uint64_t checksumOfSheets(const Vector<String>& sheets, const CSSParserContext& context, RuleCounts& counts)
{
    Checksum checksum;
    for (auto& text : sheets) {
        Ref sheet = StyleSheetContents::create(context);
        checksum.add(sheet->parseString(text));
        checksum.add(sheet->importRules().size());
        checksum.add(sheet->namespaceRules().size());
        for (auto& rule : sheet->namespaceRules())
            addRule(checksum, rule.get(), counts);
        auto& rules = sheet->childRules();
        checksum.add(rules.size());
        for (auto& rule : rules)
            addRule(checksum, rule.get(), counts);
    }
    return checksum.value();
}

// MARK: - Pieces of CSS.

static constexpr ASCIILiteral tagNames[] = {
    "div"_s, "div"_s, "span"_s, "p"_s, "a"_s, "a"_s, "ul"_s, "li"_s, "img"_s, "input"_s, "button"_s, "section"_s,
    "article"_s, "nav"_s, "header"_s, "footer"_s, "main"_s, "h1"_s, "h2"_s, "h3"_s, "table"_s, "tr"_s, "td"_s,
    "label"_s, "form"_s, "svg"_s, "DIV"_s, "Span"_s, "custom-element"_s,
};

static constexpr ASCIILiteral classWords[] = {
    "btn"_s, "nav"_s, "item"_s, "active"_s, "card"_s, "header"_s, "title"_s, "content"_s, "row"_s, "col"_s,
    "container"_s, "list"_s, "link"_s, "icon"_s, "menu"_s, "footer"_s, "is-open"_s, "has-error"_s, "x"_s,
    "md:flex"_s, "_private"_s, "-webkit-thing"_s, "a1"_s,
};

static constexpr ASCIILiteral attributeSelectors[] = {
    "[type]"_s, "[type=\"text\"]"_s, "[type=checkbox]"_s, "[href^=\"http\"]"_s, "[href$=\".pdf\"]"_s,
    "[class*=\"col-\"]"_s, "[lang|=\"en\"]"_s, "[data-state~=\"open\"]"_s, "[title=\"Hello\" i]"_s,
    "[title=\"b\" s]"_s, "[aria-hidden=\"true\"]"_s, "[data-x]"_s, "[*|href]"_s, "[|foo=bar]"_s, "[ data-y = 'z' ]"_s,
};

static constexpr ASCIILiteral simplePseudoClasses[] = {
    ":hover"_s, ":focus"_s, ":active"_s, ":first-child"_s, ":last-child"_s, ":checked"_s, ":disabled"_s,
    ":visited"_s, ":link"_s, ":focus-visible"_s, ":focus-within"_s, ":empty"_s, ":root"_s, ":target"_s,
    ":only-child"_s, ":enabled"_s, ":read-only"_s, ":placeholder-shown"_s, ":default"_s, ":required"_s,
    ":invalid"_s, ":first-of-type"_s, ":any-link"_s, ":defined"_s, ":scope"_s, ":HOVER"_s,
};

static constexpr ASCIILiteral pseudoElements[] = {
    "::before"_s, "::after"_s, "::placeholder"_s, "::selection"_s, "::first-line"_s, "::first-letter"_s,
    "::marker"_s, "::backdrop"_s, "::file-selector-button"_s, ":before"_s, ":after"_s, "::-webkit-scrollbar"_s,
    "::part(label)"_s, "::slotted(span)"_s, "::slotted(.a)"_s,
};

static constexpr ASCIILiteral combinators[] = { " "_s, " "_s, " "_s, " > "_s, ">"_s, " + "_s, " ~ "_s };

static constexpr ASCIILiteral anPlusBs[] = {
    "odd"_s, "even"_s, "n"_s, "-n+3"_s, "2n+1"_s, "2n"_s, "+5"_s, "-3"_s, "3n-2"_s, "2n + 1"_s, "N"_s, "-N+1"_s,
    "0n+0"_s, "1000n-999"_s, "+n"_s, "n- 1"_s, "-n- 2"_s, "2147483647n"_s, "-2147483648"_s, "2147483648n+1"_s,
    "ODD"_s, "5n+-1"_s, "n-"_s, "2n+"_s, "1.5n"_s,
};

static void appendClass(StringBuilder& builder, Random& random)
{
    builder.append('.', random.pick(classWords));
    if (random.percent(40)) {
        unsigned number = random.below(100);
        builder.append('-', number);
    }
}

static void appendCompound(StringBuilder& builder, Random& random, unsigned extraChance)
{
    bool empty = true;
    if (random.percent(55)) {
        if (random.percent(8))
            builder.append(random.percent(50) ? "*"_s : "svg|rect"_s);
        else
            builder.append(random.pick(tagNames));
        empty = false;
    }
    while (empty || random.percent(extraChance)) {
        empty = false;
        unsigned kind = random.below(10);
        if (kind < 5)
            appendClass(builder, random);
        else if (kind < 6) {
            unsigned number = random.below(500);
            builder.append(number < 450 ? "#id"_s : "#\\31 x"_s, number);
        } else if (kind < 8)
            builder.append(random.pick(attributeSelectors));
        else
            builder.append(random.pick(simplePseudoClasses));
    }
}

static void appendComplex(StringBuilder& builder, Random& random, unsigned maximumCompounds, unsigned extraChance)
{
    unsigned compounds = 1 + random.below(maximumCompounds);
    for (unsigned i = 0; i < compounds; ++i) {
        if (i)
            builder.append(random.pick(combinators));
        appendCompound(builder, random, extraChance);
    }
    if (random.percent(10))
        builder.append(random.pick(pseudoElements));
}

static void appendSelectorList(StringBuilder& builder, Random& random, unsigned maximumSelectors, unsigned maximumCompounds)
{
    unsigned count = 1 + random.below(maximumSelectors);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(random.percent(70) ? ", "_s : ","_s);
        appendComplex(builder, random, maximumCompounds, 35);
    }
}

static void appendHexColor(StringBuilder& builder, Random& random)
{
    static constexpr char digits[] = "0123456789abcdefABCDEF";
    builder.append('#');
    unsigned length = random.percent(30) ? 3 : 6;
    for (unsigned i = 0; i < length; ++i) {
        unsigned digit = random.below(sizeof(digits) - 1);
        builder.append(digits[digit]);
    }
}

static void appendNumber(StringBuilder& builder, Random& random, unsigned maximum)
{
    unsigned integer = random.below(maximum + 1);
    builder.append(integer);
    if (random.percent(25)) {
        unsigned fraction = random.below(100);
        builder.append('.', fraction);
    }
}

static constexpr ASCIILiteral keywordDeclarations[] = {
    "display: flex"_s, "display: grid"_s, "display: block"_s, "display: none"_s, "display: inline-block"_s,
    "position: absolute"_s, "position: relative"_s, "position: sticky"_s, "text-align: center"_s,
    "overflow: hidden"_s, "cursor: pointer"_s, "white-space: nowrap"_s, "box-sizing: border-box"_s,
    "font-family: -apple-system, \"Helvetica Neue\", Arial, sans-serif"_s, "font-weight: bold"_s,
    "transition: opacity 0.3s ease-in-out, transform 0.2s"_s, "flex: 1 1 auto"_s, "align-items: center"_s,
    "justify-content: space-between"_s, "grid-template-columns: repeat(3, minmax(0, 1fr))"_s,
    "background: url(images/bg.png) no-repeat center / cover"_s, "content: \"\\201C\""_s,
    "text-decoration: underline dotted"_s, "list-style: none"_s, "visibility: hidden"_s, "float: left"_s,
    "-webkit-appearance: none"_s, "outline: 2px solid -webkit-focus-ring-color"_s, "user-select: none"_s,
    "animation: spin 1s linear infinite"_s, "font: 12px/1.5 system-ui"_s, "border-collapse: collapse"_s,
};

static constexpr ASCIILiteral invalidDeclarations[] = {
    "colr: red"_s, "width: 10qq"_s, "margin: auto auto auto auto auto"_s, "color: #ggg"_s, "display: flexx"_s,
    "width:"_s, ": red"_s, "height: calc(10px +)"_s, "z-index: 1.5"_s, "opacity: red"_s, "@foo"_s, "{ color: red }"_s,
};

static void appendDeclaration(StringBuilder& builder, Random& random)
{
    if (random.percent(5)) {
        builder.append(random.pick(invalidDeclarations));
        return;
    }
    unsigned kind = random.below(16);
    switch (kind) {
    case 0:
        builder.append("color: "_s);
        appendHexColor(builder, random);
        break;
    case 1: {
        unsigned red = random.below(256);
        unsigned green = random.below(256);
        unsigned blue = random.below(256);
        builder.append("background-color: rgb("_s, red, ", "_s, green, ", "_s, blue, ')');
        break;
    }
    case 2:
        builder.append("margin: "_s);
        appendNumber(builder, random, 40);
        builder.append("px "_s);
        builder.append(random.percent(50) ? "auto"_s : "0"_s);
        break;
    case 3:
        builder.append("padding: "_s);
        appendNumber(builder, random, 4);
        builder.append("em"_s);
        break;
    case 4:
        builder.append("width: "_s);
        appendNumber(builder, random, 100);
        builder.append('%');
        break;
    case 5:
        builder.append("height: calc(100% - "_s);
        appendNumber(builder, random, 200);
        builder.append("px)"_s);
        break;
    case 6:
        builder.append("font-size: "_s);
        appendNumber(builder, random, 48);
        builder.append(random.percent(50) ? "px"_s : "rem"_s);
        break;
    case 7:
        builder.append("border: 1px solid "_s);
        appendHexColor(builder, random);
        break;
    case 8: {
        unsigned radius = random.below(20);
        builder.append("border-radius: "_s, radius, "px"_s);
        break;
    }
    case 9: {
        unsigned opacity = random.below(10);
        builder.append("opacity: 0."_s, opacity);
        break;
    }
    case 10: {
        unsigned x = random.below(100);
        unsigned angle = random.below(360);
        builder.append("transform: translate("_s, x, "px, -50%) rotate("_s, angle, "deg)"_s);
        break;
    }
    case 11: {
        unsigned alpha = random.below(10);
        builder.append("box-shadow: 0 1px 2px rgba(0, 0, 0, 0."_s, alpha, ')');
        break;
    }
    case 12: {
        unsigned index = random.below(1000);
        builder.append("z-index: "_s, index);
        break;
    }
    case 13:
        builder.append("line-height: 1."_s);
        appendNumber(builder, random, 9);
        break;
    default:
        builder.append(random.pick(keywordDeclarations));
        break;
    }
    if (random.percent(4))
        builder.append(" !important"_s);
}

static void appendDeclarations(StringBuilder& builder, Random& random, unsigned maximum)
{
    unsigned count = 1 + random.below(maximum);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(random.percent(80) ? "; "_s : ";"_s);
        appendDeclaration(builder, random);
    }
    if (random.percent(60))
        builder.append(';');
}

static void appendStyleRule(StringBuilder& builder, Random& random)
{
    appendSelectorList(builder, random, 3, 3);
    builder.append(" { "_s);
    appendDeclarations(builder, random, 8);
    builder.append(" }\n"_s);
}

// MARK: - ParseUserAgentSheets.

// The user agent sheets as the build embeds them, with the preprocessor's lines removed and every branch kept.
static Vector<String> userAgentSheets()
{
    static constexpr ASCIILiteral names[] = {
        "html.css"_s, "quirks.css"_s, "svg.css"_s, "mathml.css"_s, "mathmlCoreExtras.css"_s,
        "mathmlCoreMathvariant.css"_s, "mathmlFontSizeMath.css"_s, "mathmlLegacyFontSizeMath.css"_s, "popover.css"_s,
        "counterStyles.css"_s, "fullscreen.css"_s, "horizontalFormControls.css"_s, "htmlSwitchControl.css"_s,
        "selectMultipleAndListBox.css"_s, "selectMultipleSelectedContent.css"_s, "viewTransitions.css"_s,
    };
    Vector<String> sheets;
    for (auto name : names) {
        auto text = readFile(makeString(sourceRoot(), "/Source/WebCore/css/"_s, name));
        EXPECT_FALSE(text.isEmpty()) << name.characters();
        StringBuilder builder;
        for (auto line : StringView(text).splitAllowingEmptyEntries('\n')) {
            if (line.startsWith('#'))
                continue;
            builder.append(line, '\n');
        }
        sheets.append(builder.toString());
    }
    return sheets;
}

// MARK: - ParseRealisticSheet.

static void appendMixedSheet(StringBuilder& builder, Random& random, size_t length)
{
    unsigned keyframes = 0;
    while (builder.length() < length) {
        unsigned kind = random.below(20);
        if (kind < 13) {
            appendStyleRule(builder, random);
            continue;
        }
        if (kind < 16) {
            unsigned width = 320 + random.below(1600);
            builder.append(random.percent(70) ? "@media screen and (max-width: "_s : "@media (min-width: "_s, width, "px) {\n"_s);
            unsigned rules = 1 + random.below(6);
            for (unsigned i = 0; i < rules; ++i)
                appendStyleRule(builder, random);
            builder.append("}\n"_s);
            continue;
        }
        if (kind < 18) {
            builder.append(random.percent(50) ? "@supports (display: grid) and (gap: 1em) {\n"_s : "@supports not (backdrop-filter: blur(4px)) {\n"_s);
            unsigned rules = 1 + random.below(4);
            for (unsigned i = 0; i < rules; ++i)
                appendStyleRule(builder, random);
            builder.append("}\n"_s);
            continue;
        }
        if (kind < 19) {
            builder.append("@keyframes fade"_s, keyframes++, " {\n  from { opacity: 0; transform: translateY(10px) }\n  50% { opacity: 0.5 }\n  to { opacity: 1; transform: none }\n}\n"_s);
            continue;
        }
        unsigned weight = 100 * (1 + random.below(9));
        builder.append("@font-face { font-family: \"Site Sans\"; src: url(fonts/site-"_s, weight, ".woff2) format(\"woff2\"), local(\"Site Sans\"); font-weight: "_s, weight, "; font-display: swap }\n"_s);
    }
}

static Vector<String> realisticSheets()
{
    Vector<String> sheets;
    sheets.append(readSourceFile("PerformanceTests/Speedometer2.1/resources/flightjs-example-app/components/bootstrap/css/bootstrap.css"_s));
    auto directory = makeString(sourceRoot(), "/Source/WebInspectorUI/UserInterface/Views"_s);
    auto names = FileSystem::listDirectory(directory);
    std::ranges::sort(names, codePointCompareLessThan);
    for (auto& name : names) {
        if (name.endsWith(".css"_s))
            sheets.append(readFile(FileSystem::pathByAppendingComponent(directory, name)));
    }
    Random random(101);
    StringBuilder builder;
    appendMixedSheet(builder, random, generatedLength);
    sheets.append(builder.toString());
    return sheets;
}

// MARK: - ParseSelectors and ParseComplexSelectors.

// Selectors of the kind scripts pass to querySelector.
static Vector<String> selectorLists()
{
    Random random(202);
    Vector<String> selectors;
    size_t total = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        appendSelectorList(builder, random, 2, 4);
        total += builder.length();
        selectors.append(builder.toString());
    }
    return selectors;
}

static constexpr ASCIILiteral invalidSelectors[] = {
    ":is(.a, ::before)"_s, ":nth-child(2n+)"_s, ":not()"_s, "a >"_s, "::slotted(a b)"_s, "[x=]"_s, ":has(:has(a))"_s,
    ":unknown-pseudo"_s, "a::before.b"_s, "::part()"_s, ":nth-child(of .a)"_s, ".1a"_s, "#"_s, "a,,b"_s, ":host(a b)"_s,
    ":dir()"_s, ":lang()"_s, "[foo|=]"_s, ":where("_s,
};

static void appendFunctionalSelector(StringBuilder&, Random&, unsigned depth);

static void appendArgumentList(StringBuilder& builder, Random& random, unsigned depth, bool relative)
{
    unsigned count = 1 + random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(", "_s);
        if (relative && random.percent(50))
            builder.append(random.pick(combinators));
        if (depth && random.percent(40))
            appendFunctionalSelector(builder, random, depth - 1);
        else
            appendComplex(builder, random, 2, 30);
    }
}

static void appendFunctionalSelector(StringBuilder& builder, Random& random, unsigned depth)
{
    unsigned kind = random.below(14);
    switch (kind) {
    case 0:
    case 1:
        builder.append(":is("_s);
        appendArgumentList(builder, random, depth, false);
        break;
    case 2:
        builder.append(":where("_s);
        appendArgumentList(builder, random, depth, false);
        break;
    case 3:
    case 4:
        builder.append(":not("_s);
        appendArgumentList(builder, random, depth, false);
        break;
    case 5:
    case 6:
        builder.append(":has("_s);
        appendArgumentList(builder, random, 0, true);
        break;
    case 7: {
        static constexpr ASCIILiteral functions[] = { ":nth-child("_s, ":nth-last-child("_s, ":nth-of-type("_s, ":nth-last-of-type("_s };
        builder.append(random.pick(functions), random.pick(anPlusBs));
        break;
    }
    case 8:
        builder.append(":nth-child("_s, random.pick(anPlusBs), " of "_s);
        appendArgumentList(builder, random, 0, false);
        break;
    case 9:
        builder.append(random.percent(50) ? ":lang(en, \"fr-*\""_s : ":lang(de-DE"_s);
        break;
    case 10:
        builder.append(random.percent(50) ? ":dir(rtl"_s : ":dir(ltr"_s);
        break;
    case 11:
        builder.append(":host("_s);
        appendCompound(builder, random, 20);
        break;
    case 12:
        builder.append("::part(label icon"_s);
        break;
    default:
        builder.append(random.pick(invalidSelectors));
        return;
    }
    builder.append(')');
}

static Vector<String> complexSelectorLists()
{
    Random random(303);
    Vector<String> selectors;
    size_t total = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        unsigned count = 1 + random.below(2);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                builder.append(", "_s);
            unsigned compounds = 1 + random.below(3);
            for (unsigned j = 0; j < compounds; ++j) {
                if (j)
                    builder.append(random.pick(combinators));
                if (random.percent(50))
                    appendCompound(builder, random, 20);
                unsigned depth = random.below(4);
                appendFunctionalSelector(builder, random, depth);
            }
        }
        total += builder.length();
        selectors.append(builder.toString());
    }
    return selectors;
}

// MARK: - ParseNestedRules.

static constexpr ASCIILiteral nestedSelectors[] = {
    "&"_s, "& > .child"_s, ".parent &"_s, "&:hover"_s, "&.active"_s, "> .direct"_s, "+ .next"_s, "~ .sibling"_s,
    ".plain"_s, "& + &"_s, ":is(&, .x) span"_s, "&::before"_s, "& .a, & .b"_s, "div &"_s,
};

static void appendNestedRule(StringBuilder& builder, Random& random, unsigned depth, bool topLevel)
{
    if (topLevel)
        appendSelectorList(builder, random, 2, 3);
    else
        builder.append(random.pick(nestedSelectors));
    builder.append(" {\n"_s);
    appendDeclarations(builder, random, 4);
    builder.append('\n');
    unsigned children = depth ? random.below(4) : 0;
    for (unsigned i = 0; i < children; ++i) {
        unsigned kind = random.below(10);
        if (kind < 6)
            appendNestedRule(builder, random, depth - 1, false);
        else if (kind < 8) {
            unsigned width = 400 + random.below(800);
            builder.append("@media (min-width: "_s, width, "px) { "_s);
            appendDeclarations(builder, random, 3);
            if (random.percent(50))
                appendNestedRule(builder, random, depth - 1, false);
            builder.append(" }\n"_s);
        } else if (kind < 9) {
            builder.append("@supports (display: grid) { "_s);
            appendDeclarations(builder, random, 2);
            builder.append(" }\n"_s);
        } else {
            static constexpr ASCIILiteral groups[] = { "@layer nested { "_s, "@container (width > 30em) { "_s, "@scope (.card) { "_s, "@starting-style { "_s };
            builder.append(random.pick(groups));
            appendDeclarations(builder, random, 2);
            builder.append(" }\n"_s);
        }
        // Declarations after a nested rule become a nested declarations rule.
        if (random.percent(40)) {
            appendDeclarations(builder, random, 3);
            builder.append('\n');
        }
    }
    builder.append("}\n"_s);
}

static Vector<String> nestedRuleSheets()
{
    Random random(404);
    Vector<String> sheets;
    size_t total = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        while (builder.length() < 16384) {
            unsigned depth = 1 + random.below(4);
            appendNestedRule(builder, random, depth, true);
        }
        total += builder.length();
        sheets.append(builder.toString());
    }
    return sheets;
}

// MARK: - ParseAtRules.

static void appendAtRule(StringBuilder& builder, Random& random, unsigned serial)
{
    unsigned kind = random.below(19);
    switch (kind) {
    case 0:
        builder.append("@layer reset, base.components, utilities"_s, serial % 7, ";\n"_s);
        break;
    case 1:
        builder.append("@layer base"_s, serial % 5, " {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    case 2: {
        unsigned width = 200 + random.below(800);
        builder.append("@container card (min-width: "_s, width, "px) and (orientation: landscape) {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    }
    case 3:
        builder.append(random.percent(50) ? "@container style(--theme: dark) {\n"_s : "@container sidebar (inline-size > 30em) or (height < 10vh) {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    case 4:
        builder.append(random.percent(50) ? "@scope (.card) to (.content) {\n:scope { color: red }\n"_s : "@scope {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    case 5: {
        static constexpr ASCIILiteral syntaxes[] = {
            "syntax: '<length>'; inherits: false; initial-value: 0px"_s, "syntax: '<color>'; inherits: true; initial-value: red"_s,
            "syntax: '*'; inherits: false"_s, "syntax: '<number>+'; inherits: false; initial-value: 1 2"_s,
            "syntax: '<length> | auto'; inherits: false; initial-value: auto"_s, "syntax: '<length>'; inherits: false"_s,
            "syntax: 'bogus'; inherits: false"_s, "syntax: '<custom-ident>#'; inherits: true; initial-value: a, b"_s,
        };
        builder.append("@property --p"_s, serial, " { "_s, random.pick(syntaxes), " }\n"_s);
        break;
    }
    case 6:
        builder.append("@font-face { font-family: \"Face "_s, serial, "\"; src: url(f"_s, serial, ".woff2) format(\"woff2\") tech(variations), local(Foo); font-weight: 100 900; unicode-range: U+0000-00FF, U+0131, U+4??; font-display: swap }\n"_s);
        break;
    case 7: {
        unsigned width = 300 + random.below(1500);
        builder.append("@media screen and (max-width: "_s, width, "px), print and (orientation: portrait) {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    }
    case 8:
        builder.append(random.percent(50) ? "@media (prefers-color-scheme: dark) and (400px <= width <= 700px) {\n"_s : "@media not all and (hover: hover) {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    case 9:
        builder.append("@keyframes k"_s, serial, " { from { opacity: 0 } 33.3% { opacity: 0.4; color: red } to { opacity: 1 } }\n"_s);
        break;
    case 10:
        builder.append("@counter-style c"_s, serial, " { system: cyclic; symbols: \"*\" \"+\" \"\\2020\"; suffix: \" \" }\n"_s);
        break;
    case 11:
        builder.append("@font-feature-values Font"_s, serial, " { @styleset { nice: 1 2; } @swash { fancy: 3 } }\n"_s);
        break;
    case 12:
        builder.append("@font-palette-values --pal"_s, serial, " { font-family: Bixa; base-palette: 1; override-colors: 0 red, 1 #00f }\n"_s);
        break;
    case 13:
        builder.append("@page :first { margin: 1in; @top-center { content: \"Title\" } }\n"_s);
        break;
    case 14:
        builder.append("@starting-style {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    case 15:
        builder.append("@view-transition { navigation: auto }\n"_s);
        break;
    case 16:
        builder.append("@position-try --pt"_s, serial, " { top: anchor(bottom); left: anchor(center) }\n"_s);
        break;
    case 17:
        builder.append("@supports (display: grid) {\n"_s);
        appendStyleRule(builder, random);
        builder.append("}\n"_s);
        break;
    default:
        // An unknown at-rule, dropped, and a media rule with no queries.
        builder.append(random.percent(50) ? "@unknown-rule foo { bar }\n"_s : "@media {\n}\n"_s);
        break;
    }
}

static Vector<String> atRuleSheets()
{
    Random random(505);
    Vector<String> sheets;
    size_t total = 0;
    unsigned serial = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        builder.append("@charset \"utf-8\";\n@import url(missing.css) layer(imported);\n@namespace svg url(http://www.w3.org/2000/svg);\n"_s);
        while (builder.length() < 8192)
            appendAtRule(builder, random, serial++);
        total += builder.length();
        sheets.append(builder.toString());
    }
    return sheets;
}

// MARK: - ParseDeclarationLists and ParseCustomProperties.

// Declaration blocks of the kind style attributes and CSSOM cssText setters hold.
static Vector<String> declarationLists()
{
    Random random(606);
    Vector<String> blocks;
    size_t total = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        appendDeclarations(builder, random, 12);
        if (random.percent(5))
            builder.append(" /* comment */ "_s);
        total += builder.length();
        blocks.append(builder.toString());
    }
    return blocks;
}

static constexpr ASCIILiteral customValues[] = {
    "10px"_s, "red"_s, "{ a: b }"_s, " "_s, "calc(1px + 2px)"_s, "var(--other)"_s, "[x]"_s, "1fr 2fr"_s,
    "url(x.png)"_s, "\"string\""_s, "0"_s, "rgb(0 0 0 / 50%)"_s, "var(--a, var(--b, 4px))"_s, "!"_s,
    "foo(bar) baz"_s, "1e3"_s, "-webkit-thing"_s, "attr(data-x)"_s, "env(safe-area-inset-top, 0px)"_s,
};

static constexpr ASCIILiteral substitutionDeclarations[] = {
    "width: var(--w)"_s, "margin: var(--a) var(--b, 4px)"_s, "color: var(--c, var(--d, blue))"_s,
    "padding: calc(var(--x) * 2)"_s, "font: var(--font)"_s, "background: var(--bg) url(a.png)"_s,
    "padding-top: env(safe-area-inset-top, 10px)"_s, "transition: var(--t) ease"_s, "width: var(--)"_s,
    "color: var(--x,)"_s, "border: var(--width) solid var(--color)"_s, "grid-template-areas: var(--areas)"_s,
    "inset: var(--i) !important"_s, "translate: var(--tx) var(--ty)"_s, "color: var(foo)"_s,
    "box-shadow: 0 0 var(--blur, 2px) var(--shadow-color, rgb(0 0 0 / 0.2))"_s,
};

static Vector<String> customPropertyLists()
{
    Random random(707);
    Vector<String> blocks;
    size_t total = 0;
    while (total < generatedLength) {
        StringBuilder builder;
        unsigned count = 1 + random.below(10);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                builder.append("; "_s);
            if (random.percent(50)) {
                unsigned name = random.below(50);
                builder.append("--var-"_s, name, ':');
                unsigned parts = random.below(3);
                for (unsigned j = 0; j <= parts; ++j) {
                    if (j)
                        builder.append(' ');
                    builder.append(random.pick(customValues));
                }
                if (random.percent(5))
                    builder.append(" !important"_s);
            } else if (random.percent(85))
                builder.append(random.pick(substitutionDeclarations));
            else
                appendDeclaration(builder, random);
        }
        total += builder.length();
        blocks.append(builder.toString());
    }
    return blocks;
}

// MARK: - SupportsConditions.

static constexpr ASCIILiteral supportsFeatures[] = {
    "(display: grid)"_s, "(display: nonsense)"_s, "(color: rgb(0 0 0 / 50%))"_s, "(--custom: x)"_s, "(foo: bar)"_s,
    "(width: calc(1px + 2px))"_s, "selector(:has(> img))"_s, "selector(a:hover)"_s, "selector(:unknown)"_s,
    "selector(::before)"_s, "font-tech(color-COLRv1)"_s, "font-tech(variations)"_s, "font-format(woff2)"_s,
    "font-format(xyz)"_s, "(transform-style: preserve-3d)"_s, "foo(bar)"_s, "(not a declaration)"_s,
    "(display:grid)"_s, "( display : flex )"_s, "(color: red !important)"_s, "(width: 10qq)"_s,
    "selector(:is(a, b) > c)"_s, "(aspect-ratio: 16 / 9)"_s, "(gap: 1em)"_s,
};

static void appendSupportsCondition(StringBuilder& builder, Random& random, unsigned depth)
{
    unsigned kind = depth ? random.below(10) : 0;
    if (kind < 4) {
        builder.append(random.pick(supportsFeatures));
        return;
    }
    if (kind < 6) {
        builder.append("not "_s);
        appendSupportsCondition(builder, random, depth - 1);
        return;
    }
    if (kind < 9) {
        auto combinator = random.percent(50) ? " and "_s : " or "_s;
        unsigned operands = 2 + random.below(2);
        for (unsigned i = 0; i < operands; ++i) {
            if (i)
                builder.append(random.percent(95) ? combinator : (combinator == " and "_s ? " or "_s : " and "_s));
            builder.append('(');
            appendSupportsCondition(builder, random, depth - 1);
            builder.append(')');
        }
        return;
    }
    builder.append('(');
    appendSupportsCondition(builder, random, depth - 1);
    builder.append(')');
}

// Bare declarations and general enclosed text: what CSS.supports(conditionText) accepts and @supports does not.
static constexpr ASCIILiteral bareConditions[] = {
    "display: grid"_s, "display: nonsense"_s, "--custom: x"_s, "color: red !important"_s, "foo: bar"_s,
    "width:calc(1px + 2px)"_s, "display: grid) or (color: red"_s, "foo(bar) or (display: grid)"_s, ""_s, "  "_s,
};

// Conditions as @supports preludes and CSS.supports() arguments hold them.
static Vector<String> supportsConditions()
{
    Random random(808);
    Vector<String> conditions;
    size_t total = 0;
    while (total < generatedLength / 2) {
        StringBuilder builder;
        if (random.percent(10))
            builder.append(random.pick(bareConditions));
        else {
            unsigned depth = random.below(4);
            appendSupportsCondition(builder, random, depth);
        }
        total += builder.length();
        conditions.append(builder.toString());
    }
    return conditions;
}

// MARK: - DimensionTokens.

static constexpr ASCIILiteral unitNames[] = {
    "px"_s, "em"_s, "rem"_s, "ex"_s, "rex"_s, "ch"_s, "rch"_s, "cap"_s, "rcap"_s, "ic"_s, "ric"_s, "lh"_s, "rlh"_s,
    "vw"_s, "vh"_s, "vi"_s, "vb"_s, "vmin"_s, "vmax"_s, "svw"_s, "svh"_s, "svi"_s, "svb"_s, "svmin"_s, "svmax"_s,
    "lvw"_s, "lvh"_s, "lvi"_s, "lvb"_s, "lvmin"_s, "lvmax"_s, "dvw"_s, "dvh"_s, "dvi"_s, "dvb"_s, "dvmin"_s,
    "dvmax"_s, "cqw"_s, "cqh"_s, "cqi"_s, "cqb"_s, "cqmin"_s, "cqmax"_s, "cm"_s, "mm"_s, "q"_s, "in"_s, "pt"_s,
    "pc"_s, "deg"_s, "rad"_s, "grad"_s, "turn"_s, "s"_s, "ms"_s, "hz"_s, "khz"_s, "dpi"_s, "dpcm"_s, "dppx"_s, "x"_s,
    "fr"_s, "__qem"_s,
    // Other spellings: case, near misses on both sides of each name's length, and names no unit has.
    "PX"_s, "Em"_s, "VMax"_s, "DPPX"_s, "kHz"_s, "Q"_s, "pxx"_s, "p"_s, "dvma"_s, "dvmaxx"_s, "cqmi"_s, "e"_s,
    "foo"_s, "abcdef"_s, "n"_s, "n-"_s, "px-1"_s, "_"_s, "vmaz"_s, "grads"_s, "__qe"_s, "\\70x"_s, "p\\78"_s,
};

static String dimensionTokens(Random& random, bool wide)
{
    StringBuilder builder;
    if (wide)
        builder.append(static_cast<char16_t>(0x4E00), ' ');
    while (builder.length() < generatedLength / 2) {
        unsigned kind = random.below(20);
        if (kind < 2) {
            unsigned number = random.below(1000);
            builder.append(number, "% "_s);
            continue;
        }
        if (random.percent(10))
            builder.append(random.percent(50) ? '-' : '+');
        unsigned integer = random.below(2000);
        builder.append(integer);
        if (random.percent(30)) {
            unsigned fraction = random.below(1000);
            builder.append('.', fraction);
        }
        if (random.percent(5)) {
            unsigned exponent = random.below(10);
            builder.append("e-"_s, exponent);
        }
        if (wide && kind < 4) {
            // Characters that fold to ASCII letters under Unicode's case rules, but not under ASCII's.
            static constexpr char16_t foldingCharacters[] = { 0x017F, 0x0130, 0x212A };
            auto character = random.pick(foldingCharacters);
            builder.append(character == 0x017F ? "m"_s : "k"_s, character, character == 0x212A ? "hz"_s : ""_s);
        } else
            builder.append(random.pick(unitNames));
        builder.append(random.percent(80) ? " "_s : ", "_s);
    }
    return builder.toString();
}

static Vector<String> dimensionTokenInputs()
{
    Random random(909);
    Vector<String> inputs;
    inputs.append(dimensionTokens(random, false));
    inputs.append(dimensionTokens(random, true));
    return inputs;
}

static uint64_t checksumOfTokens(const Vector<String>& inputs, unsigned& dimensions, unsigned& unknownUnits)
{
    Checksum checksum;
    for (auto& input : inputs) {
        CSSTokenizer tokenizer(input);
        auto range = tokenizer.tokenRange();
        auto tokens = range.span();
        checksum.add(tokens.size());
        for (auto& token : tokens) {
            checksum.add(static_cast<uint64_t>(token.type()) | static_cast<uint64_t>(token.unitType()) << 8);
            if (token.type() != DimensionToken && token.type() != NumberToken && token.type() != PercentageToken)
                continue;
            checksum.add(std::bit_cast<uint64_t>(token.numericValue()));
            if (token.type() != DimensionToken)
                continue;
            ++dimensions;
            unknownUnits += token.unitType() == CSSUnitType::Unknown;
            checksum.add(token.unitString());
        }
    }
    return checksum.value();
}

// MARK: - InsertRule.

// A rule for the sheet's insertRule, at the index its position picks among the sheet's rule count at the time, or a
// nested rule for a style rule's insertRule.
struct InsertedRule {
    String text;
    bool nested;
    unsigned position;
};

// The sheet that receives the rules is replaced with an empty one after this many insertions.
static constexpr unsigned insertionsPerSheet = 1000;

static constexpr ASCIILiteral insertedAtRules[] = {
    "@media (min-width: 500px) { .m { color: red } }"_s, "@supports (display: grid) { .s { display: grid } }"_s,
    "@keyframes inserted { from { opacity: 0 } to { opacity: 1 } }"_s, "@font-face { font-family: Inserted; src: local(Inserted) }"_s,
    "@layer inserted { .l { color: blue } }"_s, "@import url(inserted.css);"_s, "@namespace x url(x);"_s,
    "@container (width > 10px) { .c { color: green } }"_s, "@scope (.a) { .b { color: red } }"_s,
    "a {} b {}"_s, ""_s, "}"_s, "@media screen {"_s,
};

static constexpr ASCIILiteral insertedNestedRules[] = {
    "& .child { color: red }"_s, ".plain { margin: 0 }"_s, "> .direct { padding: 1px }"_s, "color: red; margin: 0"_s,
    "@media (min-width: 500px) { color: blue }"_s, "@font-face { font-family: X }"_s, "&:hover { opacity: 0.5 }"_s,
    "@supports (display: grid) { & { display: grid } }"_s, "width: 10qq"_s,
};

static Vector<InsertedRule> insertedRules()
{
    Random random(1010);
    Vector<InsertedRule> rules;
    size_t total = 0;
    while (total < generatedLength / 4) {
        StringBuilder builder;
        bool nested = random.percent(30);
        if (nested)
            builder.append(random.pick(insertedNestedRules));
        else if (random.percent(25))
            builder.append(random.pick(insertedAtRules));
        else {
            appendSelectorList(builder, random, 2, 3);
            builder.append(" { "_s);
            appendDeclarations(builder, random, 6);
            builder.append(" }"_s);
        }
        unsigned position = random.below(1 << 16);
        total += builder.length();
        rules.append({ builder.toString(), nested, position });
    }
    return rules;
}

static Ref<CSSStyleSheet> createStyleSheet(const CSSParserContext& context)
{
    return CSSStyleSheet::create(StyleSheetContents::create(context), nullptr, true);
}

// Inserts the rule at the start of the style rule's rules, and removes it again if it was inserted.
static ExceptionOr<unsigned> insertAndRemove(CSSStyleRule& target, const String& text, Checksum* checksum, RuleCounts& counts)
{
    auto result = target.insertRule(text, 0);
    if (result.hasException())
        return result;
    if (checksum) {
        RefPtr inserted = target.cssRules().item(0);
        checksum->add(!!inserted);
        if (inserted) {
            checksum->add(inserted->cssText());
            addCSSOMRule(*checksum, *inserted, counts);
        }
        checksum->add(target.cssRules().length());
    }
    auto removed = target.deleteRule(0);
    EXPECT_FALSE(removed.hasException());
    return result;
}

// One CSSStyleSheet that the rules go into, one after another, so each insertion sees the rules before it (an
// @import or @namespace after other rules is refused), and a style rule in another sheet for the nested rules.
class InsertionTargets {
public:
    explicit InsertionTargets(const CSSParserContext& context)
        : m_context(context)
        , m_sheet(createStyleSheet(context))
        , m_hostSheet(createStyleSheet(context))
    {
        auto result = m_hostSheet->insertRule(".host { color: red; & .seed { color: blue } }"_s, 0);
        RELEASE_ASSERT(!result.hasException());
        RefPtr rules = m_hostSheet->cssRules();
        RELEASE_ASSERT(rules && rules->length() == 1);
        m_host = downcast<CSSStyleRule>(rules->item(0));
    }

    ExceptionOr<unsigned> insertRule(const InsertedRule& rule, Checksum* checksum, RuleCounts& counts)
    {
        if (rule.nested)
            return insertAndRemove(*m_host, rule.text, checksum, counts);
        auto result = m_sheet->insertRule(rule.text, rule.position % (m_length + 1));
        m_length += !result.hasException();
        if (++m_insertions == insertionsPerSheet)
            finishSheet(checksum, counts);
        return result;
    }

    // Adds the sheet's rules to the checksum, and replaces the sheet with an empty one.
    void finishSheet(Checksum* checksum, RuleCounts& counts)
    {
        if (checksum) {
            RefPtr rules = m_sheet->cssRules();
            checksum->add(!!rules);
            if (rules) {
                unsigned length = rules->length();
                EXPECT_EQ(m_length, length);
                checksum->add(length);
                for (unsigned i = 0; i < length; ++i) {
                    RefPtr rule = rules->item(i);
                    checksum->add(!!rule);
                    if (!rule)
                        continue;
                    checksum->add(rule->cssText());
                    addCSSOMRule(*checksum, *rule, counts);
                }
            }
        }
        m_sheet = createStyleSheet(m_context);
        m_length = 0;
        m_insertions = 0;
    }

private:
    const CSSParserContext& m_context;
    Ref<CSSStyleSheet> m_sheet;
    Ref<CSSStyleSheet> m_hostSheet;
    RefPtr<CSSStyleRule> m_host;
    unsigned m_length { 0 };
    unsigned m_insertions { 0 };
};

static uint64_t checksumOfInsertions(InsertionTargets& targets, const Vector<InsertedRule>& rules, RuleCounts& counts, unsigned& inserted)
{
    Checksum checksum;
    for (auto& rule : rules) {
        checksum.add(rule.nested);
        auto result = targets.insertRule(rule, &checksum, counts);
        checksum.add(result.hasException());
        if (result.hasException()) {
            checksum.add(static_cast<uint64_t>(result.exception().code()));
            continue;
        }
        ++inserted;
        checksum.add(result.releaseReturnValue());
    }
    targets.finishSheet(&checksum, counts);
    return checksum.value();
}

// MARK: - Running.

enum class Mode : uint8_t { Authored, UserAgent };

static void runSheets(ASCIILiteral name, const Vector<String>& sheets, Mode mode, std::optional<uint64_t> expectedChecksum, unsigned passes, NOESCAPE const Function<void(const RuleCounts&)>& checkCounts)
{
    auto& strictContext = setUp();
    auto& context = mode == Mode::UserAgent ? userAgentSheetContext() : strictContext;
    auto bytes = stringBytes(sheets);
    ASSERT_GT(bytes, 0u);
    RuleCounts counts;
    auto checksum = checksumOfSheets(sheets, context, counts);
    EXPECT_GT(counts.rules, 0u);
    checkCounts(counts);
    if (expectedChecksum)
        EXPECT_EQ(*expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    size_t rules = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& text : sheets) {
            Ref sheet = StyleSheetContents::create(context);
            sheet->parseString(text);
            rules += sheet->childRules().size();
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_GT(rules, 0u);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

static void runSheets(ASCIILiteral name, const Vector<String>& sheets, Mode mode, std::optional<uint64_t> expectedChecksum, unsigned passes)
{
    runSheets(name, sheets, mode, expectedChecksum, passes, [](const RuleCounts&) { });
}

// Whether each block changed the declarations, and the declarations it left.
static uint64_t checksumOfDeclarationLists(const Vector<String>& blocks, const CSSParserContext& context, unsigned& changedBlocks)
{
    Checksum checksum;
    for (auto& block : blocks) {
        Ref properties = MutableStyleProperties::create();
        bool changed = CSSParser::parseDeclarationList(properties, block, context);
        changedBlocks += changed;
        checksum.add(changed);
        addProperties(checksum, properties.get());
    }
    return checksum.value();
}

static void runDeclarationLists(ASCIILiteral name, const Vector<String>& blocks, std::optional<uint64_t> expectedChecksum, unsigned passes)
{
    auto& context = setUp();
    auto bytes = stringBytes(blocks);
    ASSERT_GT(bytes, 0u);
    unsigned changedBlocks = 0;
    auto checksum = checksumOfDeclarationLists(blocks, context, changedBlocks);
    EXPECT_GT(changedBlocks, 0u);
    if (expectedChecksum)
        EXPECT_EQ(*expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    unsigned changed = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& block : blocks) {
            Ref properties = MutableStyleProperties::create();
            changed += CSSParser::parseDeclarationList(properties, block, context);
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(changedBlocks * passes, changed);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

enum class Invalid : bool { Absent, Present };

// Whether each string parsed, and the selector list it made: its components, specificities and text.
static uint64_t checksumOfSelectorLists(const Vector<String>& selectors, const CSSParserContext& context, unsigned& validLists)
{
    Checksum checksum;
    for (auto& text : selectors) {
        auto list = CSSSelectorParser::parseSelectorList(text, context);
        checksum.add(!!list);
        if (!list)
            continue;
        ++validLists;
        addSelectorList(checksum, *list);
        checksum.add(list->selectorsText());
    }
    return checksum.value();
}

static void runSelectorLists(ASCIILiteral name, const Vector<String>& selectors, Invalid invalid, std::optional<uint64_t> expectedChecksum, unsigned passes)
{
    auto& context = setUp();
    auto bytes = stringBytes(selectors);
    ASSERT_GT(bytes, 0u);
    unsigned validLists = 0;
    auto checksum = checksumOfSelectorLists(selectors, context, validLists);
    EXPECT_GT(validLists, 0u);
    if (invalid == Invalid::Present)
        EXPECT_GT(selectors.size(), validLists);
    if (expectedChecksum)
        EXPECT_EQ(*expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    unsigned valid = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& text : selectors)
            valid += !!CSSSelectorParser::parseSelectorList(text, context);
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(validLists * passes, valid);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

static constexpr CSSSupportsParser::ParsingMode supportsModes[] = {
    CSSSupportsParser::ParsingMode::ForAtRuleSupports,
    CSSSupportsParser::ParsingMode::AllowBareDeclarationAndGeneralEnclosed,
};

// Each condition's result in each mode: supported, unsupported or invalid.
static uint64_t checksumOfSupportsConditions(const Vector<String>& conditions, const CSSParserContext& context, std::array<unsigned, 3>& results)
{
    Checksum checksum;
    for (auto& condition : conditions) {
        for (auto mode : supportsModes) {
            auto result = CSSSupportsParser::supportsCondition(condition, context, mode);
            checksum.add(static_cast<uint64_t>(result));
            ++results[std::min<unsigned>(result, 2)];
        }
    }
    return checksum.value();
}

static void runSupportsConditions(ASCIILiteral name, std::optional<uint64_t> expectedChecksum, unsigned passes)
{
    auto& context = setUp();
    auto conditions = supportsConditions();
    auto bytes = stringBytes(conditions);
    ASSERT_GT(bytes, 0u);
    std::array<unsigned, 3> results { };
    auto checksum = checksumOfSupportsConditions(conditions, context, results);
    // Every result occurs.
    EXPECT_GT(results[CSSSupportsParser::Supported], 0u);
    EXPECT_GT(results[CSSSupportsParser::Unsupported], 0u);
    EXPECT_GT(results[CSSSupportsParser::Invalid], 0u);
    if (expectedChecksum)
        EXPECT_EQ(*expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    unsigned supported = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& condition : conditions) {
            for (auto mode : supportsModes)
                supported += CSSSupportsParser::supportsCondition(condition, context, mode) == CSSSupportsParser::Supported;
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(results[CSSSupportsParser::Supported] * passes, supported);
    printResult(name, elapsed, static_cast<double>(bytes) * std::size(supportsModes) * passes, checksum);
}

static void runDimensionTokens(ASCIILiteral name, uint64_t expectedChecksum, unsigned passes)
{
    auto inputs = dimensionTokenInputs();
    auto bytes = stringBytes(inputs);
    ASSERT_GT(bytes, 0u);
    unsigned dimensions = 0;
    unsigned unknownUnits = 0;
    auto checksum = checksumOfTokens(inputs, dimensions, unknownUnits);
    EXPECT_GT(dimensions, 0u);
    EXPECT_GT(unknownUnits, 0u);
    EXPECT_GT(dimensions, unknownUnits);
    EXPECT_EQ(expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    size_t tokens = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& input : inputs) {
            CSSTokenizer tokenizer(input);
            tokens += tokenizer.tokenRange().size();
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_GT(tokens, 0u);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

static void runInsertRule(ASCIILiteral name, std::optional<uint64_t> expectedChecksum, unsigned passes)
{
    auto& context = setUp();
    auto rules = insertedRules();
    size_t bytes = 0;
    for (auto& rule : rules)
        bytes += rule.text.length();
    ASSERT_GT(bytes, 0u);
    InsertionTargets targets(context);
    RuleCounts counts;
    unsigned inserted = 0;
    auto checksum = checksumOfInsertions(targets, rules, counts, inserted);
    EXPECT_GT(inserted, 0u);
    EXPECT_GT(rules.size(), inserted);
    if (expectedChecksum)
        EXPECT_EQ(*expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    unsigned insertions = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& rule : rules)
            insertions += !targets.insertRule(rule, nullptr, counts).hasException();
        targets.finishSheet(nullptr, counts);
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(inserted * passes, insertions);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

} // namespace CSSRulesBenchmark

using namespace CSSRulesBenchmark;

// The pass counts make each full run about a second. Each platform records its own checksums, because what they hash
// differs by platform:
// - CSSPropertyID and the CSSSelector pseudo-class and pseudo-element values are numbered by generators that leave out
//   what the platform's ENABLE() and HAVE() features leave out, so every value after one left out moves: on Windows,
//   -apple-pay-button-style and -apple-pay-button-type (ENABLE(APPLE_PAY)) and -apple-visual-effect
//   (HAVE(CORE_MATERIAL)) are not properties, and :picture-in-picture (ENABLE(PICTURE_IN_PICTURE_API)) is not a
//   pseudo-class.
// - @supports font-tech() answers from the font back end: Skia's FontCustomPlatformData::supportsTechnology accepts
//   every technology, Core Text's not color-COLRv1.
// Ports other than Cocoa and Windows have no recorded checksums and check only the counts. DimensionTokens hashes token
// types, unit types and numbers only, which are the same everywhere.
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

TEST(CSSRulesBench, ParseUserAgentSheets) { runSheets("ParseUserAgentSheets"_s, userAgentSheets(), Mode::UserAgent, platformChecksum(0x1805f4d266cc3443ULL, 0x089f844ff5a49f62ULL), 2000); }
TEST(CSSRulesBench, ParseRealisticSheet) { runSheets("ParseRealisticSheet"_s, realisticSheets(), Mode::Authored, platformChecksum(0xe844dc36eb4ebf9bULL, 0x30a401b2ceb7ff44ULL), 66); }
TEST(CSSRulesBench, ParseSelectors) { runSelectorLists("ParseSelectors"_s, selectorLists(), Invalid::Absent, platformChecksum(0x74746ef21715cbf7ULL, 0xa03f951a83eba916ULL), 75); }
TEST(CSSRulesBench, ParseComplexSelectors) { runSelectorLists("ParseComplexSelectors"_s, complexSelectorLists(), Invalid::Present, platformChecksum(0xe4e60e81001e3febULL, 0x3dd6b55451b9cf08ULL), 80); }
TEST(CSSRulesBench, ParseNestedRules) { runSheets("ParseNestedRules"_s, nestedRuleSheets(), Mode::Authored, platformChecksum(0x218ca0d3c979574eULL, 0xc098ebc5aab33798ULL), 100); }
TEST(CSSRulesBench, ParseAtRules)
{
    runSheets("ParseAtRules"_s, atRuleSheets(), Mode::Authored, platformChecksum(0x19e95d2c16e8a33dULL, 0xa0f08cc344873b2eULL), 85, [](const RuleCounts& counts) {
        EXPECT_GT(counts.styleRules, 0u);
    });
}
TEST(CSSRulesBench, ParseDeclarationLists) { runDeclarationLists("ParseDeclarationLists"_s, declarationLists(), platformChecksum(0xa82bec9c3900a115ULL, 0x1cfe616cf97afc25ULL), 100); }
TEST(CSSRulesBench, ParseCustomProperties) { runDeclarationLists("ParseCustomProperties"_s, customPropertyLists(), platformChecksum(0x31930e96b6245ae1ULL, 0x5eebbd996636c4d9ULL), 70); }
TEST(CSSRulesBench, SupportsConditions) { runSupportsConditions("SupportsConditions"_s, platformChecksum(0x7886ca5ac40f0332ULL, 0x42f4ecc13096a330ULL), 110); }
TEST(CSSRulesBench, DimensionTokens) { runDimensionTokens("DimensionTokens"_s, 0xccf7fa029310e0a8ULL, 300); }
TEST(CSSRulesBench, InsertRule) { runInsertRule("InsertRule"_s, platformChecksum(0x910205021ee1f434ULL, 0xc213b0427ba65cefULL), 270); }

} // namespace TestWebKitAPI
