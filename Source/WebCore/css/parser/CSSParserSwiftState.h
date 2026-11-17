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

#pragma once

#include <WebCore/CSSPropertyConsumerSwiftTypes.h>
#include <WebCore/CSSSelectorEnums.h>
#include <WebCore/CSSSelectorList.h>
#include <WebCore/CSSSelectorInlines.h>
#include <cstdint>
#include <span>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

class CSSParserSwiftParse;
class CSSParserSwiftStateData;
class CSSParserToken;

// What a C++ entry asks cssParseWithSwift to do. Each of the parser's entry points passes one.
enum class CSSParserSwiftRequest : uint8_t {
    StyleSheet, // CSSParser::parseStyleSheet
    StyleSheetForInspector, // CSSParser::parseStyleSheetForInspector
    DeclarationListForInspector, // CSSParser::parseDeclarationListForInspector
    Rule, // CSSParser::parseRule
    AtRule, // CSSParser::consumeAtRule
    DeclarationList, // CSSParser::parseDeclarationList and parseInlineStyleDeclaration
    CustomPropertyValue, // CSSParser::parseCustomPropertyValue
    SelectorList, // CSSSelectorParser::parseSelectorList and parseCSSSelectorList
    PseudoElement, // CSSSelectorParser::parsePseudoElement
    QualifiedName, // CSSSelectorParser::consumeQualifiedName
    SupportsCondition, // CSSSupportsParser::supportsCondition
    MarginTrimInlineValue, // CSSSupportsParser::isMarginTrimInlineValue
    ContainsSubstitutionFunctions, // CSSSubstitutionParser::containsSubstitutionFunctions
    DeclarationValue, // CSSSubstitutionParser::parseDeclarationValue and parseInitialValueForUniversalSyntax
    Syntax, // CSSCustomPropertySyntax::parse
    SyntaxType, // CSSCustomPropertySyntax::consumeType
};

// Where placeRule() puts the rule makeStyleRule() or makeAtRule() last made: nowhere, the innermost nesting context's
// rules, the style sheet (as parseStyleSheet or parseStyleSheetForInspector append it) or the request's rule.
enum class CSSParserSwiftRuleTarget : uint8_t { Discard, Context, StyleSheet, StyleSheetForInspector, Result };

// An observe() event: the CSSParserObserver call, or the CSSParserObserverWrapper comment call, it makes.
enum class CSSParserSwiftObserverEvent : uint8_t {
    StartRuleHeader,
    EndRuleHeader,
    ObserveSelector,
    StartRuleBody,
    EndRuleBody,
    SkipCommentsBefore,
    YieldCommentsBefore,
    ObserveProperty,
    MarkRuleBodyContainsImplicitlyNestedProperties,
};

// ruleParserState()'s bits.
enum : uint32_t {
    CSSParserSwiftRuleParserObserving = 1 << 0,
    CSSParserSwiftRuleParserMarginTrimInlineQuirk = 1 << 2,
    CSSParserSwiftRuleParserSpatialPortal = 1 << 3,
    CSSParserSwiftRuleParserScanForEditability = 1 << 4,
};

// The rule parser's id for the keyframe style rule of a qualified rule in @keyframes: no CSSAtRuleID's.
enum : uint8_t { CSSParserSwiftKeyframeStyleRule = 0xFF };

// makeAtRule()'s flags. Bits 8 to 15 are a @font-feature-values block's CSSAtRuleID.
enum : uint32_t {
    // Checks, before the body, the part of the prelude that makeAtRule() parses; makes nothing.
    CSSParserSwiftAtRuleCheck = 1 << 0,
    // Keeps a part for the rule made next: a @font-feature-values tag, an @function parameter, @scope's start.
    CSSParserSwiftAtRulePart = 1 << 1,
    // @import's layer, @scope's start, an @function parameter's default.
    CSSParserSwiftAtRuleFirst = 1 << 2,
    // @import's supports(), @scope's end.
    CSSParserSwiftAtRuleSecond = 1 << 3,
    // The supports() or @supports condition holds.
    CSSParserSwiftAtRuleYes = 1 << 4,
};

// Tokens [start, end) of the parse.
struct CSSParserSwiftTokenRange {
    uint32_t start { 0 };
    uint32_t end { 0 };
};

// What the context enables for the validation of substitution functions (cssParserSubstitutionFlags).
enum : uint32_t {
    CSSParserSwiftInheritFunctionEnabled = 1 << 0,
    CSSParserSwiftRandomItemFunctionEnabled = 1 << 1,
    CSSParserSwiftIfFunctionEnabled = 1 << 2,
    CSSParserSwiftIdentFunctionEnabled = 1 << 3,
    CSSParserSwiftInternalAutoBaseParsingEnabled = 1 << 4,
    CSSParserSwiftFunctionAtRuleEnabled = 1 << 5,
    CSSParserSwiftViewportSegmentsAPIEnabled = 1 << 6,
};

// What a DeclarationValue request's tokens are, in the low byte of its result; for a CSS-wide keyword, its CSSValueID
// is above it.
enum class CSSParserSwiftDeclarationValueKind : uint8_t {
    Invalid,
    CSSWideKeyword,
    Substitution,
    Tokens,
};

// The bits of selectorContextFlags() above its low byte, which is the CSSSelectorParserContext's CSSParserMode.
enum : uint32_t {
    CSSParserSwiftSelectorContextClassPrefixSelectorEnabled = 1 << 8,
    CSSParserSwiftSelectorContextDefaultNamespaceIsStar = 1 << 9, // the request's style sheet's, or no style sheet
};

// How the selector builder makes an atom from a token: none (nullAtom()), its value, its value ASCII-lowercased, a
// fixed atom, or one made from the parts (the serialization of [valueToken, valueEnd), serializeANPlusB(a, b)).
enum class CSSParserSwiftAtom : uint8_t {
    None,
    Value,
    ASCIILowercase,
    Star,
    Empty,
    UserAgentPartLegacyAlias, // CSSSelector::nameForUserAgentPartLegacyAlias(value)
    UserAgentPartCue, // UserAgentParts::cue()
    UniversalPseudoElementName, // universalPseudoElementNameAtom()
    SerializedRange, // CSSParserTokenRange::serialize() of [valueToken, valueEnd), a ForgivingUnknown's value
    ANPlusB, // serializeANPlusB(a, b), an :nth-*() argument
    PickerSelectFunction, // "picker(select)", parsePseudoElement's ::picker(select) name
};

// How a type or attribute selector's namespace prefix was written: not at all (a null prefix), `|` (emptyAtom(), no
// namespace), `*|` (starAtom(), any namespace), or `prefix|`.
enum class CSSParserSwiftNamespace : uint8_t { Default, NoNamespace, Any, Prefix };

// namespaceStatus()'s bits: determineNamespace(prefix) is not null; it is defaultNamespace(); it is starAtom(); and
// defaultNamespace() is starAtom().
enum : uint8_t {
    CSSParserSwiftNamespaceResolves = 1 << 0,
    CSSParserSwiftNamespaceIsDefault = 1 << 1,
    CSSParserSwiftNamespaceIsStar = 1 << 2,
    CSSParserSwiftNamespaceDefaultIsStar = 1 << 3,
};

// The C++ type of CSSSelector::stylePseudoElementTypeFor's result, which Swift implements.
using CSSParserSwiftOptionalPseudoElementType = std::optional<PseudoElementType>;

// pseudoClass()'s kind, in its high byte.
enum : uint16_t {
    CSSParserSwiftPseudoIsClass = 1,
    CSSParserSwiftPseudoIsCompatibilityElement = 2,
};

// CSSSelector::PseudoElement::Cue's value where ENABLE(VIDEO), else CSSParserSwiftNoPseudoElement, which is no
// pseudo-element's (static_assert in the .cpp).
enum : uint8_t {
    CSSParserSwiftNoPseudoElement = 0xFF,
#if ENABLE(VIDEO)
    CSSParserSwiftCuePseudoElement = std::to_underlying(CSSSelectorPseudoElement::Cue),
#else
    CSSParserSwiftCuePseudoElement = CSSParserSwiftNoPseudoElement,
#endif
};

// The facade cssParseWithSwift receives: the tokens of one parse (CSSParserSwiftTokenReader) and the members Swift
// calls back during it. It is the empty base of a CSSParserSwiftStateData, which only CSSParserSwiftParse::runOnTokens
// constructs, on its stack, for one call of cssParseWithSwift. It cannot be copied or made, and its move constructor
// traps; its destructor is user-provided, so Swift never relocates it bitwise. Every member checks its arguments
// against the parse.
struct __attribute__((swift_attr("~Sendable"))) CSSParserSwiftState : CSSParserSwiftTokenReader<CSSParserSwiftStateData> {
    CSSParserSwiftState(const CSSParserSwiftState&) = delete;
    CSSParserSwiftState& operator=(const CSSParserSwiftState&) = delete;
    [[noreturn]] CSSParserSwiftState(CSSParserSwiftState&&);
    ~CSSParserSwiftState();

    // The request's own scalar inputs, packed: the AllowedRules in the low byte, the StyleRuleType in the next, the
    // nested context (0 for none, else 1 + its value) in the third, and the request's mode in the top byte.
    uint32_t requestInputs();
    // Where Swift leaves a request's scalar result.
    void setResult(uint32_t);

    // What the context enables for the validation of substitution functions.
    uint32_t substitutionFlags();
    // The <syntax> text a Syntax or SyntaxType request parses, read one code unit at a time: 0 past its end.
    uint32_t syntaxTextLength();
    uint16_t syntaxTextCharacter(uint32_t offset);
    // Makes the serialization of the tokens [start, end) the text that syntaxTextLength and syntaxTextCharacter read.
    void setSyntaxTextToTokens(uint32_t start, uint32_t end);
    // The value of the one ident token, a valid custom identifier, that the syntax text's code units [start, end)
    // tokenize to, with whitespace around it (CSSCustomPropertySyntax::parseComponent's ident); else the null atom.
    WTF::AtomString syntaxIdent(uint32_t start, uint32_t end);
    // Where Swift leaves the syntax a Syntax or SyntaxType request parsed.
    void setSyntax(const CSSCustomPropertySyntax&);

    // An atom result made from a token (setResult's companion): the qualified name's prefix and local name in slots
    // 0 and 1, the pseudo-element's name argument in slot 0.
    void setResultAtom(uint8_t slot, uint32_t token, CSSParserSwiftAtom);

    // Token readers beyond CSSParserSwiftTokenReader's, for the selector parser. A token's "value" is valueLength's.
    // parseInteger<int>(value.substring(offset)), or INT64_MIN where it gives nullopt.
    int64_t parseIntegerInValue(size_t index, uint32_t offset);
    bool isHashTokenId(size_t index); // a hash token of HashTokenId
    uint8_t numericSign(size_t index); // NumericSign of a number token, else NoSign
    uint32_t selectorContextFlags(); // CSSSelectorParserContext::mode | CSSParserSwiftSelectorContext*
    // MutableCSSSelector::parsePseudoClassSelector's lookup of an ident or function token's value:
    // CSSParserSwiftPseudoIsClass << 8 | an enabled pseudo-class, CSSParserSwiftPseudoIsCompatibilityElement << 8 |
    // a compatibility pseudo-element, or 0.
    uint16_t pseudoClass(size_t index);
    // CSSSelector::parsePseudoElementName of the value: 1 + the pseudo-element, or 0.
    uint16_t pseudoElement(size_t index);
    // CSSSelectorParser::determineNamespace and defaultNamespace(), as CSSParserSwiftNamespace* bits, for a prefix of
    // kind `kind` (CSSParserSwiftNamespace), with m_ignoreDefaultNamespace `ignoreDefaultNamespace`, and the request's
    // style sheet or none.
    uint8_t namespaceStatus(uint8_t kind, uint32_t prefixToken, bool ignoreDefaultNamespace, bool withStyleSheet);
    // The attribute name token is `class` (HTMLNames::classAttr's local name) and the value token's value is not
    // empty and has no ASCII whitespace: the rest of isEquivalentToClassSelector.
    bool isClassSelectorEquivalent(size_t nameToken, size_t valueToken);
    // type(), and a delimiter token's character in the bits above it: one read for the selector parser's dispatch.
    uint32_t typeAndDelimiter(size_t index) const;

    // The selector list's atom of kind `kind` made from token `token`, the tokens [token, end) (SerializedRange) or
    // `a` and `b` (ANPlusB).
    WTF::AtomString selectorAtom(CSSParserSwiftAtom kind, uint32_t token, uint32_t end, int32_t a, int32_t b);
    // A type selector's (`isAttribute` false) or attribute selector's name, its namespace resolved with
    // m_ignoreDefaultNamespace `ignoreDefaultNamespace` and the request's style sheet or none; nullQName() for
    // `nameAtom` None.
    WebCore::QualifiedName selectorQualifiedName(uint32_t nameToken, CSSParserSwiftAtom nameAtom, CSSParserSwiftNamespace, uint32_t prefixToken, bool ignoreDefaultNamespace, bool withStyleSheet, bool isAttribute);
    // Makes the parse's CSSSelectorList of `storage`, which has a complex selector.
    void setSelectorList(CSSSelectorListStorage&);

    // The rule parser, over the CSSParser of the request: its state (CSSParserSwiftRuleParser* bits) and nesting
    // contexts. A context pushed with the selector list keeps the parse's selector list for makeStyleRule(), which pops
    // it; `isStyleNestedContext` is whether the style rule is nested in a rule other than @function.
    uint32_t ruleParserState();
    void pushNestingContext(bool withSelectorList);
    void popNestingContext();
    uint32_t propertyCount();
    // The innermost context's properties as a rule in its rules: 0 a nested declarations rule appended, 1 a function
    // declarations rule appended, 2 a nested declarations rule inserted first.
    void wrapProperties(uint8_t kind);
    void swapInitialDeclarationBlock();
    uint8_t makeStyleRule(bool isStyleNestedContext);
    void placeRule(CSSParserSwiftRuleTarget);
    // The rule of StyleRuleType `type` made from token indices (`token`, `a`, `b`, `c`, read as
    // its case in CSSParser.cpp says) and, for a rule with a body, the innermost nesting context, which it closes:
    // 1 more than `type`, the rule left for placeRule(); or 0 where the part of the prelude it parses does
    // not parse. With CSSParserSwiftAtRuleCheck or CSSParserSwiftAtRulePart it makes no rule and returns whether the part
    // parsed. Each such part is checked before the rule's body; a Part is taken by the next rule made.
    uint8_t makeAtRule(uint8_t type, uint32_t flags, uint32_t token, CSSParserSwiftTokenRange a, CSSParserSwiftTokenRange b, CSSParserSwiftTokenRange c);
    uint16_t propertyID(size_t index);
    bool isPropertyExposed(uint16_t property);
    uint8_t atRuleID(size_t index);
    void parseValue(uint16_t property, uint32_t start, uint32_t end, bool important, uint8_t ruleType);
    // The custom property of the name token (UINT32_MAX: the request's name) whose value is [start, end), of a
    // DeclarationValue request's kind result, appended to the innermost context's properties if valid.
    void appendCustomProperty(uint32_t nameToken, uint32_t start, uint32_t end, uint32_t kind, bool important);
    void observe(CSSParserSwiftObserverEvent, uint32_t start, uint32_t end, uint8_t flags);
    void setUsesStyleBasedEditability();
    // font-format() (technology false) or font-tech() at `start` in @supports: the tokens consumed << 2 | the result.
    uint64_t supportsFontFunction(bool technology, uint32_t start, uint32_t end);

protected:
    CSSParserSwiftState() = default;
};

// The state behind CSSParserSwiftState: the tokens CSSParserSwiftTokenReader reads, and the parse, which holds
// everything else. Only CSSParserSwiftParse makes one.
class CSSParserSwiftStateData final : public CSSParserSwiftState {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    const std::span<const CSSParserToken> tokens;
    CSSParserSwiftParse& parse;

private:
    friend class CSSParserSwiftParse;
    CSSParserSwiftStateData(std::span<const CSSParserToken> tokens, CSSParserSwiftParse& parse)
        : tokens(tokens)
        , parse(parse)
    {
    }
};

inline uint32_t CSSParserSwiftState::typeAndDelimiter(size_t index) const
{
    if (index >= count())
        return EOFToken;
    auto& token = this->token(index);
    uint32_t type = token.type();
    return type == DelimiterToken ? type | static_cast<uint32_t>(token.delimiter()) << 8 : type;
}

} // namespace WebCore
