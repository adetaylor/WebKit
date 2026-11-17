// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2025 Apple Inc. All rights reserved.
// Copyright (C) 2025-2026 Samuel Weinig <sam@webkit.org>
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
#include "CSSParser.h"

#include "CSSAtRuleID.h"
#include "CSSCounterStyleRule.h"
#include "CSSCustomPropertySyntax.h"
#include "CSSCustomPropertyValue.h"
#include "CSSEnvironmentMapRule.h"
#include "CSSFontFamilyNameValue.h"
#include "CSSFontFeatureValuesRule.h"
#include "CSSKeywordValueInlines.h"
#include "CSSKeyframeRule.h"
#include "CSSKeyframesRule.h"
#include "CSSParserEnum.h"
#include "CSSParserFastPaths.h"
#include "CSSParserIdioms.h"
#include "CSSParserObserver.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserSwiftParse.h"
#include "CSSParserToken.h"
#include "CSSPositionTryRule.h"
#include "CSSPropertyParser.h"
#include "CSSPropertyParserConsumer+Animations.h"
#include "CSSPropertyParserConsumer+CounterStyles.h"
#include "CSSPropertyParserConsumer+Font.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+IntegerDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+Timeline.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSSelectorParser.h"
#include "CSSStringValue.h"
#include "CSSStyleSheet.h"
#include "CSSSubstitutionParser.h"
#include "CSSSupportsParser.h"
#include "CSSTokenizer.h"
#include "CSSURL.h"
#include "CSSValueList.h"
#include "CSSValuePair.h"
#include "CSSViewTransitionRule.h"
#include "ComputedStyleDependencies.h"
#include "ContainerQueryParser.h"
#include "Document.h"
#include "Element.h"
#include "FontPaletteValues.h"
#include "MediaList.h"
#include "MediaQueryParser.h"
#include "NodeDocument.h"
#include "StyleColor.h"
#include "StylePrimitiveNumericTypes+DeprecatedCSSValueConversion.h"
#include "StylePrimitiveNumericTypes+DeprecatedConversions.h"
#include "StylePropertiesInlines.h"
#include "StyleRule.h"
#include "StyleRuleFunction.h"
#include "StyleRuleImport.h"
#include "StyleSheetContents.h"
#include <bitset>
#include <memory>
#include <optional>
#include <wtf/SetForScope.h>
#include <wtf/StdLibExtras.h>

namespace WebCore {

CSSParser::~CSSParser() = default;

CSSParser::CSSParser(const CSSParserContext& context, StringView string, StyleSheetContents* styleSheet, CSSParserObserverWrapper* wrapper)
    : m_context(context)
    , m_styleSheet(styleSheet)
    , m_tokenizer(wrapper ? CSSTokenizer::tryCreate(string, *wrapper) : CSSTokenizer::tryCreate(string))
    , m_observerWrapper(wrapper)
{
}

static void consumeDeclarationValue(ParsedPropertyVector& properties, CSSParserTokenRange range, CSSPropertyID propertyID, IsImportant important, StyleRuleType ruleType, const CSSParserContext& context, StyleSheetContents* styleSheet)
{
    auto namespaceMap = styleSheet ? styleSheet->namespacePrefixMap() : CSSNamespacePrefixMap { };
    CSSPropertyParser::parseValue(propertyID, important, range, context, properties, ruleType, namespaceMap);
}

auto CSSParser::parseValue(MutableStyleProperties& declaration, CSSPropertyID propertyID, StringView string, IsImportant important, const CSSParserContext& context) -> ParseResult
{
    auto ruleType = context.enclosingRuleType.value_or(StyleRuleType::Style);

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = ruleType,
        .currentProperty = propertyID,
        .important = important,
    };
    if (RefPtr value = CSSParserFastPaths::maybeParseValue(propertyID, string, state))
        return declaration.addParsedProperty(CSSProperty(propertyID, value.releaseNonNull(), important)) ? ParseResult::Changed : ParseResult::Unchanged;

    CSSParser parser(context, string);
    consumeDeclarationValue(parser.topContext().m_parsedProperties, parser.tokenizer()->tokenRange(), propertyID, important, ruleType, context, nullptr);
    if (parser.topContext().m_parsedProperties.isEmpty())
        return ParseResult::Error;
    return declaration.addParsedProperties(parser.topContext().m_parsedProperties) ? ParseResult::Changed : ParseResult::Unchanged;
}

auto CSSParser::parseCustomPropertyValue(MutableStyleProperties& declaration, const AtomString& propertyName, StringView string, IsImportant important, const CSSParserContext& context) -> ParseResult
{
    CSSParser parser(context, string);

    parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::CustomPropertyValue, { .customPropertyName = propertyName, .mode = static_cast<uint8_t>(important == IsImportant::Yes) });

    if (parser.topContext().m_parsedProperties.isEmpty())
        return ParseResult::Error;
    return declaration.addParsedProperties(parser.topContext().m_parsedProperties) ? ParseResult::Changed : ParseResult::Unchanged;
}

static inline void filterProperties(IsImportant important, const ParsedPropertyVector& input, ParsedPropertyVector& output, size_t& unusedEntries, std::bitset<numCSSProperties>& seenProperties, HashSet<AtomString>& seenCustomProperties)
{
    // Add properties in reverse order so that highest priority definitions are reached first. Duplicate definitions can then be ignored when found.
    for (size_t i = input.size(); i--;) {
        const CSSProperty& property = input[i];
        if ((property.isImportant() && important == IsImportant::No) || (!property.isImportant() && important == IsImportant::Yes))
            continue;
        const unsigned propertyIDIndex = std::to_underlying(property.id()) - firstCSSProperty;

        if (property.id() == CSSPropertyID::Custom) {
            auto& name = downcast<CSSCustomPropertyValue>(*property.value()).name();
            if (!seenCustomProperties.add(name).isNewEntry)
                continue;
            output[--unusedEntries] = property;
            continue;
        }

        auto seenPropertyBit = seenProperties[propertyIDIndex];
        if (seenPropertyBit)
            continue;
        seenPropertyBit = true;

        output[--unusedEntries] = property;
    }
}

static Ref<ImmutableStyleProperties> createStyleProperties(ParsedPropertyVector& parsedProperties, CSSParserMode mode)
{
    std::bitset<numCSSProperties> seenProperties;
    size_t unusedEntries = parsedProperties.size();
    ParsedPropertyVector results(unusedEntries);
    HashSet<AtomString> seenCustomProperties;

    filterProperties(IsImportant::Yes, parsedProperties, results, unusedEntries, seenProperties, seenCustomProperties);
    filterProperties(IsImportant::No, parsedProperties, results, unusedEntries, seenProperties, seenCustomProperties);

    Ref result = ImmutableStyleProperties::createDeduplicating(results.subspan(unusedEntries), mode);
    parsedProperties.clear();
    return result;
}

Ref<ImmutableStyleProperties> CSSParser::parseInlineStyleDeclaration(StringView string, const Element& element)
{
    CSSParserContext context(protect(element.document()));
    context.mode = strictToCSSParserMode(element.isHTMLElement() && !element.document().inQuirksMode());

    CSSParser parser(context, string);
    parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::DeclarationList, { .ruleType = StyleRuleType::Style });
    return createStyleProperties(parser.topContext().m_parsedProperties, context.mode);
}

bool CSSParser::parseDeclarationList(MutableStyleProperties& declaration, StringView string, const CSSParserContext& context)
{
    CSSParser parser(context, string);
    auto ruleType = context.enclosingRuleType.value_or(StyleRuleType::Style);
    parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::DeclarationList, { .ruleType = ruleType });
    if (parser.topContext().m_parsedProperties.isEmpty())
        return false;

    std::bitset<numCSSProperties> seenProperties;
    size_t unusedEntries = parser.topContext().m_parsedProperties.size();
    ParsedPropertyVector results(unusedEntries);
    HashSet<AtomString> seenCustomProperties;
    filterProperties(IsImportant::Yes, parser.topContext().m_parsedProperties, results, unusedEntries, seenProperties, seenCustomProperties);
    filterProperties(IsImportant::No, parser.topContext().m_parsedProperties, results, unusedEntries, seenProperties, seenCustomProperties);
    if (unusedEntries)
        results.removeAt(0, unusedEntries);
    return declaration.addParsedProperties(results);
}

RefPtr<StyleRuleBase> CSSParser::parseRule(StringView string, const CSSParserContext& context, StyleSheetContents* styleSheet, AllowedRules allowedRules, CSSParserEnum::NestedContext nestedContext)
{
    CSSParser parser(context, string, styleSheet, nullptr);
    RefPtr<StyleRuleBase> rule;
    // With CSSOM, we might want the parser to start in an already nested state.
    parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::Rule, { .nestedContext = nestedContext, .allowedRules = allowedRules }, &rule);
    return rule;
}

RefPtr<StyleRuleKeyframe> CSSParser::parseKeyframeRule(StringView string, const CSSParserContext& context)
{
    RefPtr keyframe = parseRule(string, context, nullptr, CSSParser::AllowedRules::KeyframeRules);
    return downcast<StyleRuleKeyframe>(keyframe.get());
}

RefPtr<StyleRuleNestedDeclarations> CSSParser::parseNestedDeclarations(StringView string, const CSSParserContext& context)
{
    auto properties = MutableStyleProperties::createEmpty();
    if (!parseDeclarationList(properties, string , context))
        return { };

    return StyleRuleNestedDeclarations::create(WTF::move(properties));
}

void CSSParser::parseStyleSheet(StringView string, const CSSParserContext& context, StyleSheetContents& styleSheet)
{
    CSSParser parser(context, string, &styleSheet, nullptr);
    bool firstRuleValid = parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::StyleSheet, { });
    styleSheet.setHasSyntacticallyValidCSSHeader(firstRuleValid);
    styleSheet.shrinkToFit();
}

void CSSParser::parseDeclarationListForInspector(StringView declaration, const CSSParserContext& context, CSSParserObserver& observer)
{
    Ref wrapper = CSSParserObserverWrapper::create(observer);
    CSSParser parser(context, declaration, nullptr, wrapper.ptr());
    observer.startRuleHeader(StyleRuleType::Style, 0);
    observer.endRuleHeader(1);
    parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::DeclarationListForInspector, { .ruleType = StyleRuleType::Style });
}

void CSSParser::parseStyleSheetForInspector(StringView string, const CSSParserContext& context, StyleSheetContents& styleSheet, CSSParserObserver& observer)
{
    Ref wrapper = CSSParserObserverWrapper::create(observer);
    CSSParser parser(context, string, &styleSheet, wrapper.ptr());
    bool firstRuleValid = parser.runWithSwift(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::StyleSheetForInspector, { });
    styleSheet.setHasSyntacticallyValidCSSHeader(firstRuleValid);
}

// The rule parser in CSSParserRulesSwift.swift reads these values from requestInputs().
static_assert(std::to_underlying(CSSParser::AllowedRules::CharsetRules) == 0);
static_assert(std::to_underlying(CSSParser::AllowedRules::LayerStatementRules) == 1);
static_assert(std::to_underlying(CSSParser::AllowedRules::ImportRules) == 2);
static_assert(std::to_underlying(CSSParser::AllowedRules::NamespaceRules) == 3);
static_assert(std::to_underlying(CSSParser::AllowedRules::RegularRules) == 4);
static_assert(std::to_underlying(CSSParser::AllowedRules::KeyframeRules) == 5);
static_assert(std::to_underlying(CSSParser::AllowedRules::FontFeatureValuesRules) == 6);
static_assert(std::to_underlying(CSSParser::AllowedRules::ConditionalGroupRules) == 7);
static_assert(std::to_underlying(CSSParser::AllowedRules::NoRules) == 8);

uint32_t CSSParser::runWithSwift(CSSParserTokenRange range, CSSParserSwiftRequest request, CSSParserSwiftParseInputs&& inputs, RefPtr<StyleRuleBase>* rule)
{
    inputs.styleSheet = m_styleSheet;
    inputs.parser = this;
    inputs.context = &m_context;
    CSSParserSwiftParse parse { m_context, WTF::move(inputs) };
    parse.run(range, request);
    if (rule)
        *rule = WTF::move(parse.resultRule);
    return parse.result;
}

RefPtr<StyleRuleBase> CSSParser::consumeAtRule(CSSParserTokenRange& range, AllowedRules allowedRules)
{
    RefPtr<StyleRuleBase> rule;
    auto consumed = runWithSwift(range, CSSParserSwiftRequest::AtRule, { .allowedRules = allowedRules }, &rule);
    RELEASE_ASSERT(consumed <= range.size());
    range = range.span().subspan(consumed);
    return rule;
}

// The associated number represents the maximum number of allowed values for this font-feature-values type.
// No value means unlimited (for styleset).
NODELETE static std::pair<FontFeatureValuesType, std::optional<unsigned>> fontFeatureValuesTypeMappings(CSSAtRuleID id)
{
    switch (id) {
    case CSSAtRuleStyleset:
        return { FontFeatureValuesType::Styleset, { } };
    case CSSAtRuleStylistic:
        return { FontFeatureValuesType::Stylistic, 1 };
    case CSSAtRuleCharacterVariant:
        return { FontFeatureValuesType::CharacterVariant, 2 };
    case CSSAtRuleSwash:
        return { FontFeatureValuesType::Swash, 1 };
    case CSSAtRuleOrnaments:
        return { FontFeatureValuesType::Ornaments, 1 };
    case CSSAtRuleAnnotation:
        return { FontFeatureValuesType::Annotation, 1 };
    default:
        ASSERT_NOT_REACHED();
        return { };
    }
}

// A @font-feature-values block's tag <ident> : <integer [0,∞]>+, with its name read and `range` after the colon.
static std::optional<FontFeatureValuesTag> consumeFontFeatureValuesTag(StringView name, CSSParserTokenRange range, std::optional<unsigned> maxValues, const CSSParserContext& context)
{
    auto state = CSS::PropertyParserState { .context = context };
    Vector<unsigned> values;
    while (!range.atEnd()) {
        auto value = CSSPropertyParserHelpers::MetaConsumer<CSS::Integer<CSS::Nonnegative>>::consume(range, state);
        if (!value)
            return { };
        auto tagInteger = Style::deprecatedToStyle(*value).value;
        ASSERT(tagInteger >= 0);
        values.append(unsignedCast(tagInteger));
        if (maxValues && values.size() > *maxValues)
            return { };
    }
    if (values.isEmpty())
        return { };

    return { FontFeatureValuesTag { name.toString(), values } };
}

// @font-palette-values' descriptors.
static Ref<StyleRuleFontPaletteValues> makeFontPaletteValuesRule(StringView name, Ref<ImmutableStyleProperties>&& properties)
{
    auto fontFamilies = [&] {
        Vector<AtomString> fontFamilies;
        auto append = [&](auto& value) {
            if (RefPtr fontFamilyNameValue = dynamicDowncast<CSSFontFamilyNameValue>(value))
                fontFamilies.append(fontFamilyNameValue->fontFamilyName().value);
        };
        RefPtr cssFontFamily = properties->getPropertyCSSValue(CSSPropertyID::FontFamily);
        if (!cssFontFamily)
            return fontFamilies;
        if (RefPtr families = dynamicDowncast<CSSValueList>(*cssFontFamily)) {
            for (Ref item : *families)
                append(item.get());
            return fontFamilies;
        }
        append(*cssFontFamily);
        return fontFamilies;
    }();

    std::optional<FontPaletteIndex> basePalette;
    if (auto basePaletteValue = properties->getPropertyCSSValue(CSSPropertyID::BasePalette)) {
        if (auto* primitiveValue = dynamicDowncast<CSSPrimitiveValue>(*basePaletteValue)) {
            // FIXME: This should not be using `deprecatedToStyleFromCSSValue`. CSS Fonts 4 specifies how @font-palette-value descriptors with numeric types should be resolved, stating:
            //   "Math functions, such as calc(), and also var(), and env(), are valid within
            //    descriptor values in a @font-palette-values rule. They are evaluated within
            //    the context of the root element. Relative units are also evaluated within the
            //    context of the root element."
            //   (https://drafts.csswg.org/css-fonts/#font-palette-values)
            if (auto resolvedInteger = Style::deprecatedToStyleFromCSSValue<Style::Integer<CSS::Nonnegative, unsigned>>(*primitiveValue))
                basePalette = FontPaletteIndex(resolvedInteger->value);
        } else if (auto* keywordValue = dynamicDowncast<CSSKeywordValue>(*basePaletteValue)) {
            switch (keywordValue->valueID()) {
            case CSSValueID::Light:
                basePalette = FontPaletteIndex(FontPaletteIndex::Type::Light);
                break;
            case CSSValueID::Dark:
                basePalette = FontPaletteIndex(FontPaletteIndex::Type::Dark);
                break;
            default:
                break;
            }
        }
    }

    Vector<FontPaletteValues::OverriddenColor> overrideColors;
    if (auto overrideColorsValue = properties->getPropertyCSSValue(CSSPropertyID::OverrideColors)) {
        overrideColors = WTF::compactMap(downcast<CSSValueList>(*overrideColorsValue), [](const auto& item) -> std::optional<FontPaletteValues::OverriddenColor> {
            Ref pair = downcast<CSSValuePair>(item);
            Ref first = pair->first();
            Ref second = pair->second();

            // FIXME: This should not be using `deprecatedToStyleFromCSSValue`. CSS Fonts 4 specifies how @font-palette-value descriptors with numeric types should be resolved, stating:
            //   "Math functions, such as calc(), and also var(), and env(), are valid within
            //    descriptor values in a @font-palette-values rule. They are evaluated within
            //    the context of the root element. Relative units are also evaluated within the
            //    context of the root element."
            //   (https://drafts.csswg.org/css-fonts/#font-palette-values)
            auto key = Style::deprecatedToStyleFromCSSValue<Style::Integer<CSS::Nonnegative, unsigned>>(downcast<CSSPrimitiveValue>(first))->value;
            auto color = CSSColorValue::absoluteColor(second);
            if (!color.isValid())
                return { };

            return { { key, WTF::move(color) } };
        });
    }

    return StyleRuleFontPaletteValues::create(name.toAtomString(), WTF::move(fontFamilies), WTF::move(basePalette), WTF::move(overrideColors));
}

// @property's descriptors, or null where they are not valid.
static RefPtr<StyleRuleProperty> makePropertyRule(const AtomString& name, const ParsedPropertyVector& declarations, const CSSParserContext& context)
{
    auto descriptor = StyleRuleProperty::Descriptor { name };

    for (auto& property : declarations) {
        switch (property.id()) {
        case CSSPropertyID::Syntax:
            descriptor.syntax = protect(downcast<CSSStringValue>(*property.value()))->string().value;
            continue;
        case CSSPropertyID::Inherits:
            descriptor.inherits = isValueID(property.value(), CSSValueID::True);
            break;
        case CSSPropertyID::InitialValue:
            descriptor.initialValue = protect(downcast<CSSCustomPropertyValue>(*property.value()))->asVariableData();
            break;
        default:
            break;
        };
    };

    // "The inherits descriptor is required for the @property rule to be valid; if it’s missing, the @property rule is invalid."
    // https://drafts.css-houdini.org/css-properties-values-api/#inherits-descriptor
    if (!descriptor.inherits)
        return nullptr;

    // "If the provided string is not a valid syntax string, the descriptor is invalid and must be ignored."
    // https://drafts.css-houdini.org/css-properties-values-api/#the-syntax-descriptor
    if (descriptor.syntax.isNull())
        return nullptr;
    auto syntax = CSSCustomPropertySyntax::parse(descriptor.syntax);
    if (!syntax)
        return nullptr;

    // "The initial-value descriptor is optional only if the syntax is the universal syntax definition,
    // otherwise the descriptor is required; if it's missing, the entire rule is invalid and must be ignored."
    if (!syntax->isUniversal()) {
        if (!descriptor.initialValue)
            return nullptr;
    }

    auto initialValueIsValid = [&] {
        auto tokenRange = descriptor.initialValue->tokenRange();
        auto dependencies = CSSPropertyParser::collectParsedCustomPropertyValueDependencies(*syntax, tokenRange, context);
        if (!dependencies.isComputationallyIndependent())
            return false;
        auto containsVariable = CSSSubstitutionParser::containsSubstitutionFunctions(descriptor.initialValue->tokenRange(), context);
        if (containsVariable)
            return false;
        return true;
    };
    if (descriptor.initialValue && !initialValueIsValid())
        return nullptr;

    return StyleRuleProperty::create(WTF::move(descriptor));
}

#if ASSERT_ENABLED
// Use this function for asserting that that the user-agent stylesheets don't contain rules that are inefficient or otherwise bad.
static void validateUserAgentSheetSelector(const CSSSelectorList& selectorList)
{
    auto validateRightmostCompound = [](const CSSSelector& complexSelector) {
        bool hasBucketedSelector = false;
        bool hasLogicalCombination = false;
        for (auto* simpleSelector = &complexSelector; simpleSelector; simpleSelector = simpleSelector->followingInCompound()) {
            if (simpleSelector->match() == CSSSelector::Match::Tag && simpleSelector->tagQName().localName() != starAtom())
                hasBucketedSelector = true;
            if (simpleSelector->match() == CSSSelector::Match::Id)
                hasBucketedSelector = true;
            if (simpleSelector->match() == CSSSelector::Match::Class)
                hasBucketedSelector = true;
            if (simpleSelector->match() == CSSSelector::Match::PseudoClass) {
                if (isLogicalCombinationPseudoClass(simpleSelector->pseudoClass()) && simpleSelector->pseudoClass() != CSSSelector::PseudoClass::Not)
                    hasLogicalCombination = true;
            }
        }
        // Don't use subject position :is(foo, bar) and similar on UA sheet before we have good optimizations for them.
        // Selectors like this should be expanded manually.
        ASSERT_WITH_MESSAGE(hasBucketedSelector || !hasLogicalCombination, "Subject position selector list in '%s' not allowed in user-agent stylesheet", complexSelector.selectorText().utf8());
    };

    for (auto& complexSelector : selectorList)
        validateRightmostCompound(complexSelector);
}
#endif

IsImportant CSSParser::consumeTrailingImportantAndWhitespace(CSSParserTokenRange& range)
{
    range.trimTrailingWhitespace();
    if (range.size() < 2)
        return IsImportant::No;

    auto removeImportantRange = range;
    if (auto& last = removeImportantRange.consumeLast(); last.type() != IdentToken || !equalLettersIgnoringASCIICase(last.value(), "important"_s))
        return IsImportant::No;

    removeImportantRange.trimTrailingWhitespace();
    if (auto& last = removeImportantRange.consumeLast(); last.type() != DelimiterToken || last.delimiter() != '!')
        return IsImportant::No;

    removeImportantRange.trimTrailingWhitespace();
    range = removeImportantRange;
    return IsImportant::Yes;
}

// The rule parser's members of CSSParserSwiftState, over the CSSParser of the request.

static CSSParserSwiftParse& swiftParse(CSSParserSwiftState& state)
{
    return static_cast<CSSParserSwiftStateData&>(state).parse;
}

static CSSParserTokenRange swiftTokenRange(CSSParserSwiftState& state, uint32_t start, uint32_t end)
{
    auto tokens = static_cast<CSSParserSwiftStateData&>(state).tokens;
    RELEASE_ASSERT(start <= end && end <= tokens.size());
    return tokens.subspan(start, end - start);
}

uint32_t CSSParserSwiftState::ruleParserState()
{
    auto& parser = swiftParse(*this).parser();
    uint32_t state = 0;
    if (parser.m_observerWrapper)
        state |= CSSParserSwiftRuleParserObserving;
    if (parser.m_context.marginTrimInlineSupportsQuirkEnabled)
        state |= CSSParserSwiftRuleParserMarginTrimInlineQuirk;
#if ENABLE(SPATIAL_PORTAL)
    if (parser.m_context.propertySettings.spatialPortalEnabled)
        state |= CSSParserSwiftRuleParserSpatialPortal;
#endif
    if (parser.m_styleSheet && !parser.m_styleSheet->usesStyleBasedEditability())
        state |= CSSParserSwiftRuleParserScanForEditability;
    return state;
}

void CSSParserSwiftState::pushNestingContext(bool withSelectorList)
{
    auto& parse = swiftParse(*this);
    if (withSelectorList) {
        RELEASE_ASSERT(parse.selectorList);
        auto selectorList = *std::exchange(parse.selectorList, std::nullopt);
        ASSERT(!selectorList.isEmpty());
#if ASSERT_ENABLED
        if (isUASheetBehavior(parse.context().mode))
            validateUserAgentSheetSelector(selectorList);
#endif
        parse.styleRuleSelectorLists.append(WTF::move(selectorList));
    }
    parse.parser().m_nestingContextStack.constructAndAppend();
}

void CSSParserSwiftState::popNestingContext()
{
    auto& stack = swiftParse(*this).parser().m_nestingContextStack;
    RELEASE_ASSERT(stack.size() > 1);
    stack.removeLast();
}

uint32_t CSSParserSwiftState::propertyCount()
{
    return swiftParse(*this).parser().topContext().m_parsedProperties.size();
}

void CSSParserSwiftState::wrapProperties(uint8_t kind)
{
    auto& parser = swiftParse(*this).parser();
    auto& context = parser.topContext();
    ParsedPropertyVector properties;
    std::swap(properties, context.m_parsedProperties);
    Ref styleProperties = createStyleProperties(properties, parser.m_context.mode);
    switch (kind) {
    case 0:
        context.m_parsedRules.append(StyleRuleNestedDeclarations::create(WTF::move(styleProperties)));
        return;
    case 1:
        context.m_parsedRules.append(StyleRuleFunctionDeclarations::create(WTF::move(styleProperties)));
        return;
    case 2:
        context.m_parsedRules.insert(0, StyleRuleNestedDeclarations::create(WTF::move(styleProperties)));
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void CSSParserSwiftState::swapInitialDeclarationBlock()
{
    auto& context = swiftParse(*this).parser().topContext();
    if (!context.m_initialDeclarationBlock)
        context.m_initialDeclarationBlock = makeUnique<ParsedPropertyVector>();
    std::swap(*context.m_initialDeclarationBlock, context.m_parsedProperties);
}

uint8_t CSSParserSwiftState::makeStyleRule(bool isStyleNestedContext)
{
    auto& parse = swiftParse(*this);
    auto& parser = parse.parser();
    RELEASE_ASSERT(parser.m_nestingContextStack.size() > 1);
    RELEASE_ASSERT(!parse.styleRuleSelectorLists.isEmpty());
    auto selectorList = parse.styleRuleSelectorLists.takeLast();
    auto& context = parser.topContext();
    auto nestedRules = WTF::move(context.m_parsedRules);
    Ref properties = createStyleProperties(context.m_parsedProperties, parser.m_context.mode);

    // We save memory by creating a simple StyleRule instead of a heavier StyleRuleWithNesting when we don't need the CSS Nesting features.
    RefPtr<StyleRuleBase> rule;
    if (nestedRules.isEmpty() && !selectorList.hasExplicitNestingParent() && !isStyleNestedContext)
        rule = StyleRule::create(WTF::move(properties), parser.m_context.hasDocumentSecurityOrigin, WTF::move(selectorList));
    else
        rule = StyleRuleWithNesting::create(WTF::move(properties), parser.m_context.hasDocumentSecurityOrigin, WTF::move(selectorList), WTF::move(nestedRules));
    parser.m_nestingContextStack.removeLast();
    parse.rule = rule;
    return 1 + std::to_underlying(rule->type());
}

void CSSParserSwiftState::placeRule(CSSParserSwiftRuleTarget target)
{
    auto& parse = swiftParse(*this);
    auto& parser = parse.parser();
    RefPtr rule = std::exchange(parse.rule, nullptr);
    RELEASE_ASSERT(rule);
    switch (target) {
    case CSSParserSwiftRuleTarget::Discard:
        return;
    case CSSParserSwiftRuleTarget::Context:
        parser.topContext().m_parsedRules.append(rule.releaseNonNull());
        return;
    case CSSParserSwiftRuleTarget::StyleSheet:
    case CSSParserSwiftRuleTarget::StyleSheetForInspector:
        if (rule->isCharsetRule())
            return;
        if (target == CSSParserSwiftRuleTarget::StyleSheet && parser.m_context.shouldIgnoreImportRules && rule->isImportRule())
            return;
        RELEASE_ASSERT(parser.m_styleSheet);
        parser.m_styleSheet->parserAppendRule(rule.releaseNonNull());
        return;
    case CSSParserSwiftRuleTarget::Result:
        parse.resultRule = WTF::move(rule);
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

// The value of token `token` as an atom; null past the tokens, as the EOF token's.
static AtomString swiftTokenAtom(CSSParserSwiftState& state, uint32_t token)
{
    auto tokens = static_cast<CSSParserSwiftStateData&>(state).tokens;
    return token < tokens.size() ? tokens[token].value().toAtomString() : nullAtom();
}

static CSSParserTokenRange swiftTokenRange(CSSParserSwiftState& state, CSSParserSwiftTokenRange range)
{
    return swiftTokenRange(state, range.start, range.end);
}

// The cascade layer names of tokens Swift parsed as names (idents, `.`) separated by commas and whitespace: one per
// comma more than none. An empty range is the anonymous name.
static Vector<CascadeLayerName> cascadeLayerNames(CSSParserTokenRange range)
{
    Vector<CascadeLayerName> names(1);
    for (auto& token : range.span()) {
        if (token.type() == CommaToken)
            names.append({ });
        else if (token.type() == IdentToken)
            names.last().append(token.value().toAtomString());
    }
    return names;
}

uint8_t CSSParserSwiftState::makeAtRule(uint8_t type, uint32_t flags, uint32_t token, CSSParserSwiftTokenRange a, CSSParserSwiftTokenRange b, CSSParserSwiftTokenRange c)
{
    auto& parse = swiftParse(*this);
    auto& parser = parse.parser();
    auto& context = parser.m_context;
    bool check = flags & CSSParserSwiftAtRuleCheck;
    bool part = flags & CSSParserSwiftAtRulePart;
    // The innermost nesting context, which the rule's body filled, closed: its rules or its properties.
    auto takeContext = [&] {
        RELEASE_ASSERT(parser.m_nestingContextStack.size() > 1);
        return parser.m_nestingContextStack.takeLast();
    };
    auto rules = [&] {
        auto rules = takeContext().m_parsedRules;
        rules.shrinkToFit();
        return rules;
    };
    auto properties = [&] {
        auto nestingContext = takeContext();
        return createStyleProperties(nestingContext.m_parsedProperties, context.mode);
    };
    auto takeSelectorList = [&] {
        RELEASE_ASSERT(parse.selectorList);
        return *std::exchange(parse.selectorList, std::nullopt);
    };
    auto takeSyntax = [&] {
        return std::exchange(parse.syntax, std::nullopt).value_or(CSSCustomPropertySyntax::universal());
    };
    auto made = [&](RefPtr<StyleRuleBase>&& rule) -> uint8_t {
        parse.rule = WTF::move(rule);
        return parse.rule ? 1 + std::to_underlying(parse.rule->type()) : 0;
    };

    switch (static_cast<StyleRuleType>(type)) {
    case StyleRuleType::Charset:
        return made(StyleRuleCharset::create());
    case StyleRuleType::Import: {
        // `token` starts the URL, a string token or a <url> with its request modifiers, which the prelude's rest
        // follows; `a` the media queries, whose end is the prelude's, `b` the layer name (First), `c` the supports()
        // condition (Second, Yes where it holds).
        auto url = [&] -> std::optional<CSS::URL> {
            auto range = swiftTokenRange(*this, token, a.end);
            if (range.peek().type() == StringToken)
                return CSS::URL { .specified = range.peek().value().toString(), .resolved = { }, .modifiers = { } };

            auto state = CSS::PropertyParserState { .context = context };
            return CSSPropertyParserHelpers::consumeURLRaw(range, state, {
                CSSPropertyParserHelpers::AllowedURLModifiers::CrossOrigin,
                CSSPropertyParserHelpers::AllowedURLModifiers::Integrity,
                CSSPropertyParserHelpers::AllowedURLModifiers::ReferrerPolicy,
            });
        }();
        if (!url)
            return 0;
        if (check)
            return 1;
        auto layer = flags & CSSParserSwiftAtRuleFirst ? std::optional { WTF::move(cascadeLayerNames(swiftTokenRange(*this, b))[0]) } : std::nullopt;
        auto supports = flags & CSSParserSwiftAtRuleSecond ? StyleRuleImport::SupportsCondition { swiftTokenRange(*this, c).serialize(), !!(flags & CSSParserSwiftAtRuleYes) } : StyleRuleImport::SupportsCondition { };
        return made(StyleRuleImport::create(WTF::move(*url), MQ::MediaQueryParser::parse(swiftTokenRange(*this, a), context), WTF::move(layer), WTF::move(supports)));
    }
    case StyleRuleType::Namespace: {
        // `token`'s value is the URI; `a` the prefix token, if not empty.
        auto uri = swiftTokenAtom(*this, token);
        if (uri.isNull())
            return 0; // Parse error, expected string or URI
        return made(StyleRuleNamespace::create(a.start == a.end ? nullAtom() : swiftTokenAtom(*this, a.start), uri));
    }
    case StyleRuleType::LayerStatement: // `a`: the names
        return made(StyleRuleLayer::createStatement(cascadeLayerNames(swiftTokenRange(*this, a))));
    case StyleRuleType::LayerBlock: // `a`: the name
        return made(StyleRuleLayer::createBlock(WTF::move(cascadeLayerNames(swiftTokenRange(*this, a))[0]), rules()));
    case StyleRuleType::Media: // `a`: the media queries
        return made(StyleRuleMedia::create(MQ::MediaQueryParser::parse(swiftTokenRange(*this, a), context), rules()));
    case StyleRuleType::Supports: // `a`: the condition, Yes where it holds
        return made(StyleRuleSupports::create(swiftTokenRange(*this, a).serialize().trim(deprecatedIsSpaceOrNewline), flags & CSSParserSwiftAtRuleYes, rules()));
    case StyleRuleType::Container: {
        // `a`: the query, parsed and kept before the body.
        if (check) {
            auto prelude = swiftTokenRange(*this, a);
            auto query = CQ::ContainerQueryParser::consumeContainerQuery(prelude, context);
            if (!query)
                return 0;
            parse.containerQueries.append(WTF::move(*query));
            return 1;
        }
        RELEASE_ASSERT(!parse.containerQueries.isEmpty());
        return made(StyleRuleContainer::create(parse.containerQueries.takeLast(), rules()));
    }
    case StyleRuleType::Scope: {
        // The parse's selector list: the start with Part, kept for the rule; else the end, if Second. First: a start
        // was kept.
        if (part) {
            parse.scopeStart = takeSelectorList();
            return 1;
        }
        auto scopeEnd = flags & CSSParserSwiftAtRuleSecond ? takeSelectorList() : CSSSelectorList { };
        auto scopeStart = flags & CSSParserSwiftAtRuleFirst ? std::exchange(parse.scopeStart, { }) : CSSSelectorList { };
        Ref rule = StyleRuleScope::create(WTF::move(scopeStart), WTF::move(scopeEnd), rules());
        if (RefPtr styleSheet = parser.m_styleSheet)
            rule->setStyleSheetContents(*styleSheet);
        return made(WTF::move(rule));
    }
    case StyleRuleType::StartingStyle:
        return made(StyleRuleStartingStyle::create(rules()));
    case StyleRuleType::FontFace:
        return made(StyleRuleFontFace::create(properties()));
    case StyleRuleType::ViewTransition:
        return made(StyleRuleViewTransition::create(properties()));
#if ENABLE(SPATIAL_PORTAL)
    case StyleRuleType::EnvironmentMap:
        return made(StyleRuleEnvironmentMap::create(properties()));
#endif
    case StyleRuleType::PositionTry: // `token`: the name
        return made(StyleRulePositionTry::create(swiftTokenAtom(*this, token), properties()));
    case StyleRuleType::FontPaletteValues: // `token`: the name
        return made(makeFontPaletteValuesRule(swiftTokenRange(*this, token, token + 1).peek().value(), properties()));
    case StyleRuleType::Property: // `token`: the name
        return made(makePropertyRule(swiftTokenAtom(*this, token), takeContext().m_parsedProperties, context));
    case StyleRuleType::CounterStyle: {
        // `a`: the prelude, the name checked before the body and read again for the rule. None where the
        // descriptors are not valid.
        auto prelude = swiftTokenRange(*this, a);
        auto name = CSSPropertyParserHelpers::consumeCounterStyleNameInPrelude(prelude, context.mode);
        if (check)
            return !name.isNull();
        auto descriptors = CSSCounterStyleDescriptors::create(name, properties());
        if (!descriptors.isValid())
            return 0;
        return made(StyleRuleCounterStyle::create(WTF::move(descriptors)));
    }
    case StyleRuleType::Page: // The parse's selector list.
        return made(StyleRulePage::create(properties(), takeSelectorList()));
    case StyleRuleType::Keyframe:
        // `a`: the key list, parsed and kept before the body.
        if (check) {
            auto prelude = swiftTokenRange(*this, a);
            auto state = CSS::PropertyParserState { .context = context };
            parse.keyframeKeys = CSSPropertyParserHelpers::consumeKeyframeKeyList(prelude, state);
            return !parse.keyframeKeys.isEmpty();
        }
        return made(StyleRuleKeyframe::create(std::exchange(parse.keyframeKeys, { }), properties()));
    case StyleRuleType::Keyframes: {
        // `token`: the name. The context's rules are its keyframes.
        auto keyframeRule = StyleRuleKeyframes::create(swiftTokenAtom(*this, token));
        for (auto& keyframe : rules())
            keyframeRule->parserAppendKeyframe(downcast<const StyleRuleKeyframe>(keyframe.ptr()));
        keyframeRule->shrinkToFit();
        return made(WTF::move(keyframeRule));
    }
    case StyleRuleType::FontFeatureValues: {
        // `a`: the family names, checked before the body and parsed again for the rule. The context's rules hold
        // its blocks.
        auto prelude = swiftTokenRange(*this, a);
        auto fontFamilies = CSSPropertyParserHelpers::consumeFontFeatureValuesPreludeFamilyNameList(prelude, context);
        if (check)
            return !fontFamilies.isEmpty() && prelude.atEnd();
        // Convert block rules to value (remove duplicate...etc)
        auto fontFeatureValues = FontFeatureValues::create();
        for (auto& block : rules()) {
            if (RefPtr fontFeatureValuesBlockRule = dynamicDowncast<StyleRuleFontFeatureValuesBlock>(block.get()))
                fontFeatureValues->updateOrInsertForType(fontFeatureValuesBlockRule->fontFeatureValuesType(), fontFeatureValuesBlockRule->tags());
        }
        return made(StyleRuleFontFeatureValues::create(fontFamilies, WTF::move(fontFeatureValues)));
    }
    case StyleRuleType::FontFeatureValuesBlock: {
        // The block's CSSAtRuleID in flags' second byte. With Part, a tag: `token` its name, `a` its values.
        auto blockID = static_cast<CSSAtRuleID>(flags >> 8 & 0xFF);
        RELEASE_ASSERT(blockID == CSSAtRuleStyleset || blockID == CSSAtRuleStylistic || blockID == CSSAtRuleCharacterVariant
            || blockID == CSSAtRuleSwash || blockID == CSSAtRuleOrnaments || blockID == CSSAtRuleAnnotation);
        auto [valuesType, maxValues] = fontFeatureValuesTypeMappings(blockID);
        if (part) {
            auto tag = consumeFontFeatureValuesTag(swiftTokenRange(*this, token, token + 1).peek().value(), swiftTokenRange(*this, a), maxValues, context);
            if (!tag)
                return 0;
            parse.fontFeatureValuesTags.append(WTF::move(*tag));
            return 1;
        }
        return made(StyleRuleFontFeatureValuesBlock::create(valuesType, std::exchange(parse.fontFeatureValuesTags, { })));
    }
    case StyleRuleType::Function:
        // With Check: whether `a`, a parameter's default, parses as the parse's syntax. With Part, a parameter:
        // `token` its name, the parse's syntax its type, `a` its default (First). Else `token` is the function, the
        // parse's syntax its return type.
        if (check)
            return CSSPropertyParser::isValidCustomPropertyValueForSyntax(takeSyntax(), swiftTokenRange(*this, a), context);
        if (part) {
            auto parameter = StyleRuleFunction::Parameter { swiftTokenAtom(*this, token), takeSyntax(), nullptr };
            if (flags & CSSParserSwiftAtRuleFirst)
                parameter.defaultValue = CSSVariableData::create(swiftTokenRange(*this, a));
            parse.functionParameters.append(WTF::move(parameter));
            return 1;
        }
        return made(StyleRuleFunction::create(swiftTokenAtom(*this, token), std::exchange(parse.functionParameters, { }), takeSyntax(), rules()));
    default:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED(); // Swift makes no other at-rule.
}

uint16_t CSSParserSwiftState::propertyID(size_t index)
{
    return type(index) == IdentToken ? std::to_underlying(token(index).parseAsCSSPropertyID()) : std::to_underlying(CSSPropertyID::Invalid);
}

bool CSSParserSwiftState::isPropertyExposed(uint16_t property)
{
    RELEASE_ASSERT(property < cssPropertyIDEnumValueCount);
    return isExposed(static_cast<CSSPropertyID>(property), &swiftParse(*this).context().propertySettings);
}

uint8_t CSSParserSwiftState::atRuleID(size_t index)
{
    return type(index) == AtKeywordToken ? cssAtRuleID(token(index).value()) : CSSAtRuleInvalid;
}

void CSSParserSwiftState::parseValue(uint16_t property, uint32_t start, uint32_t end, bool important, uint8_t ruleType)
{
    RELEASE_ASSERT(property < cssPropertyIDEnumValueCount && ruleType <= std::to_underlying(StyleRuleType::EnvironmentMap));
    auto& parser = swiftParse(*this).parser();
    consumeDeclarationValue(parser.topContext().m_parsedProperties, swiftTokenRange(*this, start, end), static_cast<CSSPropertyID>(property), important ? IsImportant::Yes : IsImportant::No, static_cast<StyleRuleType>(ruleType), parser.m_context, parser.m_styleSheet.get());
}

void CSSParserSwiftState::appendCustomProperty(uint32_t nameToken, uint32_t start, uint32_t end, uint32_t kind, bool isImportant)
{
    auto& parse = swiftParse(*this);
    auto& parser = parse.parser();
    auto name = nameToken == std::numeric_limits<uint32_t>::max() ? parse.inputs.customPropertyName : swiftTokenRange(*this, nameToken, nameToken + 1).peek().value().toAtomString();
    auto range = swiftTokenRange(*this, start, end);
    auto important = isImportant ? IsImportant::Yes : IsImportant::No;
    if (range.atEnd()) {
        parser.topContext().m_parsedProperties.append(CSSProperty(CSSPropertyID::Custom, CSSCustomPropertyValue::createEmpty(name), important));
        return;
    }
    auto namespaceMap = parser.m_styleSheet ? parser.m_styleSheet->namespacePrefixMap() : CSSNamespacePrefixMap { };
    if (auto value = cssCustomPropertyValueOfKind(kind, name, range, parser.m_context, namespaceMap))
        parser.topContext().m_parsedProperties.append(CSSProperty(CSSPropertyID::Custom, value.releaseNonNull(), important));
}

void CSSParserSwiftState::observe(CSSParserSwiftObserverEvent event, uint32_t start, uint32_t end, uint8_t flags)
{
    RefPtr wrapper = swiftParse(*this).parser().m_observerWrapper.get();
    if (!wrapper)
        return;
    // Observing parses are the inspector entries', on the tokenizer's whole token vector, so a token index here is the
    // tokenizer's; its offsets are one per token and one for EOF, or none for an empty string.
    RELEASE_ASSERT(start <= end && (!wrapper->tokenOffsetCount() || count() + 1 == wrapper->tokenOffsetCount()));
    auto& observer = wrapper->observer();
    switch (event) {
    case CSSParserSwiftObserverEvent::StartRuleHeader:
        RELEASE_ASSERT(flags <= std::to_underlying(StyleRuleType::EnvironmentMap));
        observer.startRuleHeader(static_cast<StyleRuleType>(flags), wrapper->tokenOffset(start));
        return;
    case CSSParserSwiftObserverEvent::EndRuleHeader:
        observer.endRuleHeader(wrapper->tokenOffset(end));
        return;
    case CSSParserSwiftObserverEvent::ObserveSelector:
        observer.observeSelector(wrapper->tokenOffset(start), wrapper->tokenOffset(end));
        return;
    case CSSParserSwiftObserverEvent::StartRuleBody:
        // flags 1: a rule whose body the observer is not shown starts it at the header's end. Else the start of the token
        // before `start`, 0 for the first.
        observer.startRuleBody(flags ? wrapper->tokenOffset(end) : start ? wrapper->tokenOffset(start - 1) : 0);
        return;
    case CSSParserSwiftObserverEvent::EndRuleBody:
        observer.endRuleBody(wrapper->tokenOffset(end));
        return;
    case CSSParserSwiftObserverEvent::SkipCommentsBefore:
        wrapper->skipCommentsBefore(start, flags);
        return;
    case CSSParserSwiftObserverEvent::YieldCommentsBefore:
        wrapper->yieldCommentsBefore(start);
        return;
    case CSSParserSwiftObserverEvent::ObserveProperty:
        observer.observeProperty(wrapper->tokenOffset(start), wrapper->tokenOffset(end), flags & 1, flags & 2);
        return;
    case CSSParserSwiftObserverEvent::MarkRuleBodyContainsImplicitlyNestedProperties:
        observer.markRuleBodyContainsImplicitlyNestedProperties();
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void CSSParserSwiftState::setUsesStyleBasedEditability()
{
    RefPtr styleSheet = swiftParse(*this).parser().m_styleSheet;
    RELEASE_ASSERT(styleSheet);
    styleSheet->parserSetUsesStyleBasedEditability();
}

} // namespace WebCore
