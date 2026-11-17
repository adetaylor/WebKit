// Copyright 2014-2017 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2020 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"
#include "CSSSelectorParser.h"

#include "CSSParserEnum.h"
#include "CSSParserSwiftParse.h"
#include "CSSParserTokenRange.h"
#include "CSSSelector.h"
#include "CSSSelectorInlines.h"
#include "CSSTokenizer.h"
#include "CommonAtomStrings.h"
#include "Document.h"
#include "HTMLNames.h"
#include "MutableCSSSelector.h"
#include "PseudoElementIdentifier.h"
#include "SelectorPseudoTypeMap.h"
#include "UserAgentParts.h"
#include <memory>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebCore {

// <an+b> token sequences have special serialization rules: https://www.w3.org/TR/css-syntax-3/#serializing-anb
static AtomString serializeANPlusB(const std::pair<int, int>& ab)
{
    if (!ab.first)
        return AtomString::number(ab.second);

    StringBuilder builder;

    if (ab.first == -1)
        builder.append('-');
    else if (ab.first != 1)
        builder.append(ab.first);
    builder.append('n');

    if (ab.second) {
        if (ab.second > 0)
            builder.append('+');
        builder.append(ab.second);
    }

    return builder.toAtomString();
}

static_assert(CSSParserSwiftNoPseudoElement > std::to_underlying(CSSSelector::PseudoElement::WebKitUnknown)); // the last

static CSSParserSwiftStateData& selectorParserData(CSSParserSwiftState& state) { return static_cast<CSSParserSwiftStateData&>(state); }
static CSSParserSwiftParse& selectorParserParse(CSSParserSwiftState& state) { return selectorParserData(state).parse; }

// The token at `index`, which must be one of the parse's.
static const CSSParserToken& selectorParserToken(CSSParserSwiftState& state, size_t index)
{
    auto tokens = selectorParserData(state).tokens;
    RELEASE_ASSERT(index < tokens.size());
    return tokens[index];
}

int64_t CSSParserSwiftState::parseIntegerInValue(size_t index, uint32_t offset)
{
    auto text = valueText(selectorParserToken(*this, index));
    RELEASE_ASSERT(offset <= text.length());
    auto parsed = parseInteger<int>(text.substring(offset));
    return parsed ? *parsed : std::numeric_limits<int64_t>::min();
}

bool CSSParserSwiftState::isHashTokenId(size_t index)
{
    return type(index) == HashToken && selectorParserToken(*this, index).getHashTokenType() == HashTokenId;
}

uint8_t CSSParserSwiftState::numericSign(size_t index)
{
    return type(index) == NumberToken ? selectorParserToken(*this, index).numericSign() : NoSign;
}

uint32_t CSSParserSwiftState::selectorContextFlags()
{
    auto& parse = selectorParserParse(*this);
    auto& context = parse.selectorContext;
    auto& styleSheet = parse.inputs.styleSheet;
    return std::to_underlying(context.mode) | (context.cssClassPrefixSelectorEnabled ? CSSParserSwiftSelectorContextClassPrefixSelectorEnabled : 0)
        | (!styleSheet || styleSheet->defaultNamespace() == starAtom() ? CSSParserSwiftSelectorContextDefaultNamespaceIsStar : 0);
}

uint16_t CSSParserSwiftState::pseudoClass(size_t index)
{
    auto found = findPseudoClassAndCompatibilityElementName(selectorParserToken(*this, index).value());
    if (found.pseudoClass)
        return CSSSelector::isPseudoClassEnabled(*found.pseudoClass, selectorParserParse(*this).selectorContext) ? CSSParserSwiftPseudoIsClass << 8 | std::to_underlying(*found.pseudoClass) : 0;
    if (found.compatibilityPseudoElement) {
        ASSERT(CSSSelector::isPseudoElementEnabled(*found.compatibilityPseudoElement, selectorParserToken(*this, index).value(), selectorParserParse(*this).selectorContext));
        return CSSParserSwiftPseudoIsCompatibilityElement << 8 | std::to_underlying(*found.compatibilityPseudoElement);
    }
    return 0;
}

uint16_t CSSParserSwiftState::pseudoElement(size_t index)
{
    auto found = CSSSelector::parsePseudoElementName(selectorParserToken(*this, index).value(), selectorParserParse(*this).selectorContext);
    return found ? 1 + std::to_underlying(*found) : 0;
}

// CSSSelectorParser's namespace resolution, with its style sheet and m_ignoreDefaultNamespace as the parse had them.
struct SelectorNamespaceResolver {
    const RefPtr<StyleSheetContents> m_styleSheet;
    bool m_ignoreDefaultNamespace { false };

    const AtomString& defaultNamespace() const
    {
        if (!m_styleSheet || m_ignoreDefaultNamespace)
            return starAtom();
        return m_styleSheet->defaultNamespace();
    }

    const AtomString& determineNamespace(const AtomString& prefix)
    {
        if (prefix.isNull())
            return defaultNamespace();
        if (prefix.isEmpty())
            return emptyAtom(); // No namespace. If an element/attribute has a namespace, we won't match it.
        if (prefix == starAtom())
            return starAtom(); // We'll match any namespace.
        if (!m_styleSheet)
            return nullAtom(); // Cannot resolve prefix to namespace without a stylesheet, syntax error.
        return m_styleSheet->namespaceURIFromPrefix(prefix);
    }
};

static SelectorNamespaceResolver namespaceResolver(CSSParserSwiftState& state, bool ignoreDefaultNamespace, bool withStyleSheet)
{
    return { withStyleSheet ? selectorParserParse(state).inputs.styleSheet : nullptr, ignoreDefaultNamespace };
}

static AtomString namespacePrefix(CSSParserSwiftState& state, CSSParserSwiftNamespace kind, uint32_t prefixToken)
{
    switch (kind) {
    case CSSParserSwiftNamespace::Default: return nullAtom();
    case CSSParserSwiftNamespace::NoNamespace: return emptyAtom();
    case CSSParserSwiftNamespace::Any: return starAtom();
    case CSSParserSwiftNamespace::Prefix: return selectorParserToken(state, prefixToken).value().toAtomString();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static CSSParserSwiftNamespace checkedNamespaceKind(uint8_t kind)
{
    RELEASE_ASSERT(kind <= std::to_underlying(CSSParserSwiftNamespace::Prefix));
    return static_cast<CSSParserSwiftNamespace>(kind);
}

uint8_t CSSParserSwiftState::namespaceStatus(uint8_t kind, uint32_t prefixToken, bool ignoreDefaultNamespace, bool withStyleSheet)
{
    auto prefix = namespacePrefix(*this, checkedNamespaceKind(kind), prefixToken);
    auto resolver = namespaceResolver(*this, ignoreDefaultNamespace, withStyleSheet);
    auto& namespaceURI = resolver.determineNamespace(prefix);
    auto& defaultURI = resolver.defaultNamespace();
    return (namespaceURI.isNull() ? 0 : CSSParserSwiftNamespaceResolves)
        | (namespaceURI == defaultURI ? CSSParserSwiftNamespaceIsDefault : 0)
        | (namespaceURI == starAtom() ? CSSParserSwiftNamespaceIsStar : 0)
        | (defaultURI == starAtom() ? CSSParserSwiftNamespaceDefaultIsStar : 0);
}

bool CSSParserSwiftState::isClassSelectorEquivalent(size_t nameToken, size_t valueToken)
{
    if (selectorParserToken(*this, nameToken).value() != HTMLNames::classAttr->localName())
        return false;
    auto value = selectorParserToken(*this, valueToken).value();
    return !value.isEmpty() && value.find(isASCIIWhitespace<char16_t>) == notFound;
}

void CSSParserSwiftState::setResultAtom(uint8_t slot, uint32_t token, CSSParserSwiftAtom kind)
{
    RELEASE_ASSERT(slot < 2);
    selectorParserParse(*this).resultAtoms[slot] = selectorAtom(kind, token, token, 0, 0);
}

AtomString CSSParserSwiftState::selectorAtom(CSSParserSwiftAtom kind, uint32_t token, uint32_t end, int32_t a, int32_t b)
{
    switch (kind) {
    case CSSParserSwiftAtom::None: return nullAtom();
    case CSSParserSwiftAtom::Value: return selectorParserToken(*this, token).value().toAtomString();
    case CSSParserSwiftAtom::ASCIILowercase: return selectorParserToken(*this, token).value().convertToASCIILowercaseAtom();
    case CSSParserSwiftAtom::Star: return starAtom();
    case CSSParserSwiftAtom::Empty: return emptyAtom();
    case CSSParserSwiftAtom::UserAgentPartLegacyAlias: return CSSSelector::nameForUserAgentPartLegacyAlias(selectorParserToken(*this, token).value());
    case CSSParserSwiftAtom::UserAgentPartCue: return UserAgentParts::cue();
    case CSSParserSwiftAtom::UniversalPseudoElementName: return universalPseudoElementNameAtom();
    case CSSParserSwiftAtom::SerializedRange: {
        // We store the complete range content for serialization.
        RELEASE_ASSERT(token <= end && end <= selectorParserData(*this).tokens.size());
        auto tokens = selectorParserData(*this).tokens.subspan(token, end - token);
        return AtomString { CSSParserTokenRange { tokens }.serialize() };
    }
    case CSSParserSwiftAtom::ANPlusB:
        return serializeANPlusB({ a, b });
    case CSSParserSwiftAtom::PickerSelectFunction: return AtomString { makeString("picker("_s, "select"_s, ')') };
    }
    RELEASE_ASSERT_NOT_REACHED();
}

// The type or attribute selector's QualifiedName, made from the parsed name and namespace prefix; nullQName() for no name.
QualifiedName CSSParserSwiftState::selectorQualifiedName(uint32_t nameToken, CSSParserSwiftAtom nameAtom, CSSParserSwiftNamespace namespaceKind, uint32_t prefixToken, bool ignoreDefaultNamespace, bool withStyleSheet, bool isAttribute)
{
    if (nameAtom == CSSParserSwiftAtom::None)
        return nullQName();
    RELEASE_ASSERT(nameAtom == CSSParserSwiftAtom::Value || nameAtom == CSSParserSwiftAtom::Star);
    auto name = selectorAtom(nameAtom, nameToken, nameToken, 0, 0);
    auto prefix = namespacePrefix(*this, checkedNamespaceKind(std::to_underlying(namespaceKind)), prefixToken);
    auto resolver = namespaceResolver(*this, ignoreDefaultNamespace, withStyleSheet);
    AtomString namespaceURI = resolver.determineNamespace(prefix);
    RELEASE_ASSERT(!namespaceURI.isNull()); // Swift fails the selector where it is null.
    if (isAttribute)
        return prefix.isNull() ? QualifiedName(nullAtom(), name, nullAtom()) : QualifiedName(prefix, name, namespaceURI);
    if (namespaceURI == resolver.defaultNamespace())
        prefix = nullAtom();
    return QualifiedName(prefix, name, namespaceURI);
}

void CSSParserSwiftState::setSelectorList(CSSSelectorListStorage& storage)
{
    // Every list the parser hands over has a complex selector.
    RELEASE_ASSERT(storage.componentCount());
    selectorParserParse(*this).selectorList = CSSSelectorList { Ref { storage } };
}

std::optional<CSSSelectorList> parseCSSSelectorList(CSSParserTokenRange range, const CSSSelectorParserContext& context, StyleSheetContents* styleSheet, CSSParserEnum::NestedContext nestedContext)
{
    CSSParserSwiftParse parse { context, { .styleSheet = styleSheet, .nestedContext = nestedContext } };
    parse.run(range, CSSParserSwiftRequest::SelectorList);
    return WTF::move(parse.selectorList);
}

std::optional<CSSSelectorList> CSSSelectorParser::parseSelectorList(const String& string, const CSSParserContext& context, StyleSheetContents* styleSheet, CSSParserEnum::NestedContext nestedContext)
{
    return parseCSSSelectorList(CSSTokenizer(string).tokenRange(), context, styleSheet, nestedContext);
}

std::optional<ParsedQualifiedName> consumeQualifiedName(CSSParserTokenRange& range)
{
    CSSParserSwiftParse parse { CSSSelectorParserContext { } };
    parse.run(range, CSSParserSwiftRequest::QualifiedName);
    // The tokens consumed in the low 31 bits, and whether there is a name in the top bit.
    auto consumed = parse.result & 0x7FFFFFFF;
    RELEASE_ASSERT(consumed <= range.size());
    range = range.span().subspan(consumed);
    if (!(parse.result & 0x80000000))
        return std::nullopt;
    return ParsedQualifiedName { parse.resultAtoms[1], parse.resultAtoms[0] };
}

CSSSelectorList CSSSelectorParser::resolveNestingParent(const CSSSelectorList& nestedSelectorList, const CSSSelectorList* parentResolvedSelectorList, bool parentRuleIsScope)
{
    MutableCSSSelectorList result;

    auto canInline = [](const CSSSelector& nestingSelector, const CSSSelectorList& list) {
        auto hasTagInCompound = [](const CSSSelector& simpleSelector) {
            // A compound is organized so that any tag selector is always leftmost.
            return simpleSelector.leftmostInCompound()->match() == CSSSelector::Match::Tag;
        };

        if (list.size() != 1) {
            // .foo, .bar { & .baz {...} } -> :is(.foo, .bar) .baz {...}
            return false;
        }
        if (complexSelectorCanMatchPseudoElement(list.first())) {
            // .foo::before { & {...} } -> :is(.foo::before) {...} (which matches nothing)
            return false;
        }
        if (hasTagInCompound(list.first()) && hasTagInCompound(nestingSelector)) {
            // foo { bar& {...} } -> bar:is(foo) {...}
            return false;
        }
        if (!nestingSelector.precedingInComplexSelector()) {
            // .foo .bar { & .baz {...} } -> .foo .bar .baz {...}
            return true;
        }
        bool hasSingleCompound = !list.first().rightmostInCompound()->precedingInComplexSelector();
        if (hasSingleCompound) {
            // .foo.bar { .baz & {...} } -> .baz .foo.bar {...}
            return true;
        }
        // .foo .bar { .baz & {...} } -> .baz :is(.foo .bar) {...}
        return false;
    };

    auto resolveNestingSelector = [&](const CSSSelector& nestingSelector) {
        ASSERT(nestingSelector.match() == CSSSelector::Match::NestingParent);

        if (parentResolvedSelectorList && !parentRuleIsScope) {
            if (canInline(nestingSelector, *parentResolvedSelectorList)) {
                // :is() not needed.
                return makeUnique<MutableCSSSelector>(parentResolvedSelectorList->first());
            }
            // General case where we wrap with :is().
            auto isSelector = makeUnique<MutableCSSSelector>();
            isSelector->setMatch(CSSSelector::Match::PseudoClass);
            isSelector->setPseudoClass(CSSSelector::PseudoClass::Is);
            isSelector->setSelectorList(makeUnique<CSSSelectorList>(*parentResolvedSelectorList));
            return isSelector;
        }

        // Top-level nesting parent selector acts like :scope with zero specificity thanks to :where
        // https://github.com/w3c/csswg-drafts/issues/10196#issuecomment-2161119978
        // Replace by :where(:scope)
        auto scopeSelector = makeUnique<MutableCSSSelector>();
        scopeSelector->setMatch(CSSSelector::Match::PseudoClass);
        scopeSelector->setPseudoClass(CSSSelector::PseudoClass::Scope);
        auto scopeSelectorList = MutableCSSSelectorList::from(WTF::move(scopeSelector));

        auto whereSelector = makeUnique<MutableCSSSelector>();
        whereSelector->setMatch(CSSSelector::Match::PseudoClass);
        whereSelector->setPseudoClass(CSSSelector::PseudoClass::Where);
        whereSelector->setSelectorList(makeUnique<CSSSelectorList>(WTF::move(scopeSelectorList)));
        return whereSelector;
    };

    auto resolveSimpleSelector = [&](const CSSSelector& simpleSelector) {
        if (simpleSelector.match() == CSSSelector::Match::NestingParent)
            return resolveNestingSelector(simpleSelector);

        auto resolvedSelector = makeUnique<MutableCSSSelector>(simpleSelector, MutableCSSSelector::SimpleSelector);

        if (auto* subselectorList = simpleSelector.selectorList(); subselectorList && subselectorList->hasExplicitNestingParent()) {
            // Resolve nested selector lists like :has(&).
            auto resolvedSubselectorList = resolveNestingParent(*subselectorList, parentResolvedSelectorList, parentRuleIsScope);
            resolvedSelector->setSelectorList(makeUnique<CSSSelectorList>(WTF::move(resolvedSubselectorList)));
        }
        return resolvedSelector;
    };

    for (auto& complexSelector : nestedSelectorList) {
        MutableCSSSelector* leftmost = nullptr;
        for (const auto* simpleSelector = &complexSelector; simpleSelector; simpleSelector = simpleSelector->precedingInComplexSelector()) {
            auto resolvedSimpleSelector = resolveSimpleSelector(*simpleSelector);

            if (!leftmost) {
                result.append(WTF::move(resolvedSimpleSelector));
                leftmost = result.last().get();
            } else
                leftmost->setPrecedingInComplexSelector(WTF::move(resolvedSimpleSelector));

            // A nesting selector may resolve to multiple selectors. Find the leftmost one to continue.
            leftmost = leftmost->leftmostSimpleSelector();
            leftmost->setRelation(simpleSelector->relation());
        }
    }

    return CSSSelectorList { WTF::move(result) };
}

std::optional<Style::PseudoElementIdentifier> CSSSelectorParser::parsePseudoElement(StringView input, const CSSSelectorParserContext& context)
{
    CSSParserSwiftParse parse { context };
    parse.run(CSSTokenizer { input }.tokenRange(), CSSParserSwiftRequest::PseudoElement);
    // 1 + the PseudoElementType in the low byte, 0 for none; bit 8 when result atom 0 is the name argument.
    if (!(parse.result & 0xFF))
        return std::nullopt;
    auto type = (parse.result & 0xFF) - 1;
    RELEASE_ASSERT(type <= std::to_underlying(PseudoElementType::HighestEnumValue));
    if (parse.result & 0x100)
        return Style::PseudoElementIdentifier { static_cast<PseudoElementType>(type), parse.resultAtoms[0] };
    return Style::PseudoElementIdentifier { static_cast<PseudoElementType>(type) };
}

struct HasCompoundContext {
    Vector<const CSSSelector*> compoundPeers;
    CSSSelector::Relation compoundRelation;
    const CSSSelector* leftStart { nullptr };
};

static std::optional<HasCompoundContext> collectHasCompoundContext(const CSSSelector& hasPseudoClass)
{
    HasCompoundContext context;
    for (auto* selector = hasPseudoClass.leftmostInCompound(); selector; selector = selector->followingInCompound()) {
        if (selector == &hasPseudoClass)
            continue;
        // Skip pseudo-elements (e.g. `.foo:has(...)::before`); the scope is the has-bearer element.
        if (selector->match() == CSSSelector::Match::PseudoElement)
            continue;
        context.compoundPeers.append(selector);
    }
    if (context.compoundPeers.isEmpty())
        return { };

    auto* rightmostInCompound = hasPseudoClass.rightmostInCompound();
    context.compoundRelation = rightmostInCompound->relation();
    context.leftStart = rightmostInCompound->precedingInComplexSelector();
    return context;
}

static void appendSelector(MutableCSSSelectorList& result, MutableCSSSelector*& leftmost, std::unique_ptr<MutableCSSSelector> selector)
{
    if (!leftmost) {
        result.append(WTF::move(selector));
        leftmost = result.last().get();
    } else {
        leftmost->setPrecedingInComplexSelector(WTF::move(selector));
        leftmost = leftmost->precedingInComplexSelector();
    }
}

static CSSSelectorList buildScopeSelector(const HasCompoundContext& context)
{
    MutableCSSSelector* leftmost = nullptr;
    MutableCSSSelectorList result;

    for (auto* peer : context.compoundPeers) {
        auto mutableSelector = makeUnique<MutableCSSSelector>(*peer, MutableCSSSelector::SimpleSelector);
        mutableSelector->setRelation(peer->relation());
        appendSelector(result, leftmost, WTF::move(mutableSelector));
    }

    leftmost->setRelation(context.compoundRelation);

    for (auto* selector = context.leftStart; selector; selector = selector->precedingInComplexSelector()) {
        auto mutableSelector = makeUnique<MutableCSSSelector>(*selector, MutableCSSSelector::SimpleSelector);
        mutableSelector->setRelation(selector->relation());
        appendSelector(result, leftmost, WTF::move(mutableSelector));
    }

    return CSSSelectorList { WTF::move(result) };
}

// Returns a selector for the :has() scope element. Encodes two cases:
//   - Specific selectors: strong scope (e.g. `.c1` for `.c1:has(> .trigger)`).
//   - Universal `*`: weak scope. No compound peer at any level.
// Scope-breaking is signalled by the caller passing an empty list.
// `compoundSelectors` lists the compounds contributing to the scope, from outermost
// (an enclosing :is()/:not()) to innermost (the :has() itself). For `.foo:is(.bar:has(.x))`
// the outermost contributes `.foo` and the innermost contributes `.bar`, giving scope `.foo.bar`.
// Only the outermost's left context (combinator + ancestor chain) is relevant; inner compounds
// live inside :is()/:not() arguments. Inner compounds containing a type selector are skipped
// to avoid synthesizing an invalid two-type compound.
CSSSelectorList CSSSelectorParser::makeHasScopeSelector(const Vector<const CSSSelector*>& compoundSelectors)
{
    ASSERT(!compoundSelectors.isEmpty());

    auto* outermost = compoundSelectors.first()->rightmostInCompound();

    Vector<const CSSSelector*> mergedPeers;
    for (size_t i = 0; i < compoundSelectors.size(); ++i) {
        auto context = collectHasCompoundContext(*compoundSelectors[i]);
        if (!context)
            continue;

        if (i > 0) {
            auto containsTypeSelector = std::ranges::any_of(context->compoundPeers, [](auto* peer) {
                return peer->match() == CSSSelector::Match::Tag;
            });
            if (containsTypeSelector)
                continue;
        }

        mergedPeers.appendVector(context->compoundPeers);
    }

    if (mergedPeers.isEmpty()) {
        MutableCSSSelectorList result;
        result.append(makeUnique<MutableCSSSelector>(anyQName()));
        return CSSSelectorList { WTF::move(result) };
    }

    HasCompoundContext merged { WTF::move(mergedPeers), outermost->relation(), outermost->precedingInComplexSelector() };
    return buildScopeSelector(merged);
}

CSSSelectorList CSSSelectorParser::makeHasArgumentWithScope(const CSSSelector& hasArgument, const CSSSelector& scopeSelector)
{
    MutableCSSSelector* leftmost = nullptr;
    MutableCSSSelectorList result;

    // Copy :has() argument selectors, stopping at HasScope.
    for (auto* selector = &hasArgument; selector; selector = selector->precedingInComplexSelector()) {
        if (selector->match() == CSSSelector::Match::HasScope)
            break;
        auto mutableSelector = makeUnique<MutableCSSSelector>(*selector, MutableCSSSelector::SimpleSelector);
        mutableSelector->setRelation(selector->relation());
        appendSelector(result, leftmost, WTF::move(mutableSelector));
    }

    // Append scope selector.
    for (auto* selector = &scopeSelector; selector; selector = selector->precedingInComplexSelector()) {
        auto mutableSelector = makeUnique<MutableCSSSelector>(*selector, MutableCSSSelector::SimpleSelector);
        mutableSelector->setRelation(selector->relation());
        appendSelector(result, leftmost, WTF::move(mutableSelector));
    }

    return CSSSelectorList { WTF::move(result) };
}

} // namespace WebCore
