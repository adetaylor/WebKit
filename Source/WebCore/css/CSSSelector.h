/*
 * Copyright (C) 1999-2003 Lars Knoll (knoll@kde.org)
 *               1999 Waldo Bastian (bastian@kde.org)
 * Copyright (C) 2004-2022 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#pragma once

#include <WebCore/CSSSelectorEnums.h>
#include <WebCore/QualifiedName.h>
#include <WebCore/RenderStyleConstants.h>
#include <wtf/FixedVector.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Variant.h>

namespace WebCore {

class CSSSelectorList;
struct CSSSelectorParserContext;

// The universal pseudo-element argument (::highlight(*), ::view-transition-group(*), etc.)
// is represented by this otherwise-invalid <custom-ident> value (a real name can never be
// empty).
inline const AtomString& universalPseudoElementNameAtom() { return emptyAtom(); }

struct PossiblyQuotedIdentifier {
    AtomString identifier;
    bool wasQuoted { false };

    bool operator==(const PossiblyQuotedIdentifier&) const = default;
    bool isNull() const { return identifier.isNull(); }
};

WTF::TextStream& operator<<(WTF::TextStream&, PossiblyQuotedIdentifier);

enum class SelectorSpecificityIncrement {
    ClassA = 0x10000,
    ClassB = 0x100,
    ClassC = 1
};

// Selector for a StyleRule.
// A record is valid only in its CSSSelectorList's array: the walkers step to this + 1 and this - 1. Swift would hold
// a copy, so the type is unsafe to Swift, which reads records in place through CSSSelectorList's index accessors.
DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSSelectorRareData);
class SWIFT_UNSAFE __attribute__((swift_attr("~Sendable"))) CSSSelector {
    WTF_MAKE_TZONE_ALLOCATED(CSSSelector);
public:
    CSSSelector() = default;
    CSSSelector(const CSSSelector&) = default;
    CSSSelector(CSSSelector&&) = default;
    enum MutableSelectorCopyTag { MutableSelectorCopy };
    CSSSelector(const CSSSelector&, MutableSelectorCopyTag);
    NODELETE explicit CSSSelector(const QualifiedName&, bool tagIsForNamespaceRule = false);

    ~CSSSelector();
    CSSSelector& operator=(CSSSelector&&) = default;

    // Re-create selector text from selector's data.
    WEBCORE_EXPORT String selectorText(StringView separator = { }, StringView rightSide = { }) const;

    WEBCORE_EXPORT unsigned computeSpecificity() const;
    std::array<uint8_t, 3> computeSpecificityTuple() const;
    NODELETE unsigned specificityForPage() const;

    enum class VisitFunctionalPseudoClasses { No, Yes };
    enum class VisitOnlySubject { No, Yes };
    using VisitFunctor = WTF::Function<bool(const CSSSelector&)>;
    bool visitSimpleSelectors(NOESCAPE const VisitFunctor&, VisitFunctionalPseudoClasses = VisitFunctionalPseudoClasses::No, VisitOnlySubject = VisitOnlySubject::No) const;

    bool hasExplicitNestingParent() const;
    bool hasExplicitPseudoClassScope() const;
    bool hasScope() const;

    using PseudoClass = CSSSelectorPseudoClass;
    using PseudoElement = CSSSelectorPseudoElement;

    // How the attribute value has to match. Default is Exact.
    enum class Match : uint8_t {
        Unknown = 0,
        Tag,
        Id,
        Class,
        ClassPrefix, // .foo-*
        Exact,
        Set,
        List,
        Hyphen,
        PseudoClass,
        PseudoElement,
        Contain, // css3: E[foo*="bar"]
        Begin, // css3: E[foo^="bar"]
        End, // css3: E[foo$="bar"]
        PagePseudoClass,
        NestingParent, // &
        HasScope, // matches the :has() scope
        ForgivingUnknown,
        ForgivingUnknownNestContaining
    };

    enum class Relation : uint8_t {
        Subselector,
        DescendantSpace,
        Child,
        DirectAdjacent,
        IndirectAdjacent,
        ShadowDescendant,
        ShadowPartDescendant,
        ShadowSlotted
    };

    enum class PagePseudoClass : uint8_t {
        First,
        Left,
        Right,
    };

    enum class AttributeMatchType : uint8_t { Default, CaseInsensitive, CaseSensitive };

    // Maps from the selector pseudo-element type to the style type. Only pseudo-elements that are not element-backed have a type in style.
    NODELETE static std::optional<PseudoElementType> stylePseudoElementTypeFor(PseudoElement);
    static bool isPseudoClassEnabled(PseudoClass, const CSSSelectorParserContext&);
    static bool isPseudoElementEnabled(PseudoElement, StringView, const CSSSelectorParserContext&);
    static std::optional<PseudoElement> parsePseudoElementName(StringView, const CSSSelectorParserContext&);
    static bool pseudoClassRequiresArgument(PseudoClass);
    static bool pseudoElementRequiresArgument(PseudoElement);
    static bool pseudoClassMayHaveArgument(PseudoClass);
    static bool pseudoElementMayHaveArgument(PseudoElement);

    static const ASCIILiteral selectorTextForPseudoClass(PseudoClass);
    static const ASCIILiteral nameForUserAgentPartLegacyAlias(StringView);

    // Selectors are kept in an array by CSSSelectorList. Compounds are stored right-to-left
    // (subject compound first), but simples within a compound are stored left-to-right.
    // For example, ".a.b > div#id" is stored as [div, #id, .a, .b].
WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
    const CSSSelector* precedingInComplexSelector() const { return m_isFirstInComplexSelector ? nullptr : this + 1; }
WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

    NODELETE const CSSSelector* leftmostInCompound() const;
    NODELETE const CSSSelector* rightmostInCompound() const;
    NODELETE const CSSSelector* followingInCompound() const;

    const QualifiedName& tagQName() const LIFETIME_BOUND;
    const AtomString& tagLowercaseLocalName() const LIFETIME_BOUND;

    const AtomString& value() const LIFETIME_BOUND;
    const AtomString& serializingValue() const LIFETIME_BOUND;
    const QualifiedName& attribute() const LIFETIME_BOUND;
    const AtomString& argument() const LIFETIME_BOUND { return m_rareData ? m_rareData->argument : nullAtom(); }
    AttributeMatchType attributeMatchType() const;
    // A list that was set is never empty (the setters' callers assert it), so empty means not set.
    const FixedVector<int>* integerList() const LIFETIME_BOUND { return m_rareData && !m_rareData->integerList.isEmpty() ? &m_rareData->integerList : nullptr; }
    const FixedVector<AtomString>* stringList() const LIFETIME_BOUND { return m_rareData && !m_rareData->stringList.isEmpty() ? &m_rareData->stringList : nullptr; }
    const FixedVector<PossiblyQuotedIdentifier>* langList() const LIFETIME_BOUND { return m_rareData && !m_rareData->langList.isEmpty() ? &m_rareData->langList : nullptr; }
    const CSSSelectorList* selectorList() const LIFETIME_BOUND { return m_rareData ? m_rareData->selectorList.get() : nullptr; }

    NODELETE bool matchNth(int count) const;
    NODELETE int nthA() const;
    NODELETE int nthB() const;

    bool hasDescendantRelation() const { return relation() == Relation::DescendantSpace; }
    bool hasDescendantOrChildRelation() const { return relation() == Relation::Child || hasDescendantRelation(); }

    PseudoClass pseudoClass() const;
    PseudoElement pseudoElement() const;
    PagePseudoClass pagePseudoClass() const;

    bool matchesPseudoElement() const;
    bool isAttributeSelector() const;

    // True for [class~="foo"] selectors that match exactly like .foo, so matching can test
    // the tokenized ElementData::classNames() instead of searching the attribute value.
    // Set by the parser, which knows the document mode: in quirks mode the class list is
    // ASCII-lowercased while [class~=] stays case-sensitive.
    bool isEquivalentToClassSelector() const { return m_isEquivalentToClassSelector; }
    NODELETE bool isHostPseudoClass() const;
    NODELETE bool isScopePseudoClass() const;
    NODELETE bool isHasPseudoClass() const;

    Relation relation() const { return static_cast<Relation>(m_relation); }
    Match match() const { return static_cast<Match>(m_match); }

    bool isForPage() const { return m_isForPage; }

    // Implicit means that this selector is not author/UA written.
    bool isImplicit() const { return m_isImplicit; }

    // Relation and selector list bits are ignored.
    bool simpleSelectorEqual(const CSSSelector&) const;

#if !ASSERT_WITH_SECURITY_IMPLICATION_DISABLED
    bool destructorHasBeenCalled() const { return m_destructorHasBeenCalled; }
#endif

private:
    friend class CSSSelectorList;
    friend class CSSSelectorListStorage;
    friend class MutableCSSSelector;

    void setValue(const AtomString&, bool matchLowerCase = false);

    void setAttribute(const QualifiedName&, AttributeMatchType);
    void setNth(int a, int b);
    void setArgument(const AtomString&);
    void setIntegerList(FixedVector<int>);
    void setStringList(FixedVector<AtomString>);
    void setLangList(FixedVector<PossiblyQuotedIdentifier>);
    void setSelectorList(std::unique_ptr<CSSSelectorList>);

    void setPseudoClass(PseudoClass);
    void setPseudoElement(PseudoElement);
    void setPagePseudoClass(PagePseudoClass);

    void setRelation(Relation);
    void setMatch(Match);

    void setForPage() { m_isForPage = true; }
    void setImplicit() { m_isImplicit = true; }
    void setIsEquivalentToClassSelector() { m_isEquivalentToClassSelector = true; }

    unsigned m_relation : 4 { std::to_underlying(Relation::DescendantSpace) };
    mutable unsigned m_match : 5 { std::to_underlying(Match::Unknown) };
    mutable unsigned m_pseudoType : 8 { 0 }; // PseudoType.
    // 18 bits

    // These are in logical order, which is reversed from the memory order.
    unsigned m_isFirstInComplexSelector : 1 { true };
    unsigned m_isLastInComplexSelector : 1 { true };

    unsigned m_isForPage : 1 { false };
    unsigned m_tagIsForNamespaceRule : 1 { false };
    unsigned m_attributeMatchType : 2 { std::to_underlying(AttributeMatchType::Default) };
    unsigned m_isImplicit : 1 { false };
    unsigned m_isEquivalentToClassSelector : 1 { false };
    // 26 bits
#if !ASSERT_WITH_SECURITY_IMPLICATION_DISABLED
    unsigned m_destructorHasBeenCalled : 1 { false };
#endif

    CSSSelector& operator=(const CSSSelector&) = delete;

    // Copies of a selector share their RareData; createRareData() copies it before a write when it is shared.
    struct RareData : public RefCounted<RareData> {
        WTF_MAKE_STRUCT_TZONE_ALLOCATED(RareData);
        static Ref<RareData> create(AtomString);
        WEBCORE_EXPORT ~RareData();

        bool equals(const RareData&) const;

        NODELETE bool matchNth(int count);

        // For quirks mode, class and id are case-insensitive. In the case where uppercase
        // letters are used in quirks mode, |m_matchingValue| holds the lowercase class/id
        // and |m_serializingValue| holds the original string.
        AtomString matchingValue;
        AtomString serializingValue;

        int a { 0 }; // Used for :nth-*
        int b { 0 }; // Used for :nth-*
        AtomString argument; // Used for :contains and :nth-*
        // At most one is set: :heading (int), :active-view-transition-type/::highlight/::view-transition-*/::part (AtomString), :lang (PossiblyQuotedIdentifier)
        FixedVector<int> integerList;
        FixedVector<AtomString> stringList;
        FixedVector<PossiblyQuotedIdentifier> langList;
        std::unique_ptr<CSSSelectorList> selectorList; // Used for :is(), :matches(), and :not().

        Ref<RareData> deepCopy() const;

    private:
        RareData(AtomString&& value);
        RareData(const RareData& other);
    };
    // Makes m_rareData exist and be this selector's own, so it can be written.
    void createRareData();

    AtomString m_value; // When there is no RareData; it moves to RareData when one is made.
    QualifiedName m_name { nullQName() }; // The tag (Match::Tag) or the attribute (attribute selectors).
    RefPtr<RareData> m_rareData;
};

NODELETE bool complexSelectorCanMatchPseudoElement(const CSSSelector&);
bool complexSelectorMatchesElementBackedPseudoElement(const CSSSelector&);

// In the AllowNonElementBackedPseudoElements mode `.foo::before` and `.foo` compare equal.
enum class ComplexSelectorsEqualMode : bool { Full, IgnoreNonElementBackedPseudoElements };
bool complexSelectorsEqual(const CSSSelector&, const CSSSelector&, ComplexSelectorsEqualMode = ComplexSelectorsEqualMode::Full);

NODELETE void addComplexSelector(Hasher&, const CSSSelector&, ComplexSelectorsEqualMode = ComplexSelectorsEqualMode::Full);

inline bool operator==(const PossiblyQuotedIdentifier& a, const AtomString& b) { return a.identifier == b; }

inline const QualifiedName& CSSSelector::attribute() const
{
    ASSERT(isAttributeSelector());
    ASSERT_WITH_SECURITY_IMPLICATION(m_rareData);
    return m_name;
}

inline bool CSSSelector::matchesPseudoElement() const
{
    return match() == Match::PseudoElement;
}

static inline bool pseudoClassIsRelativeToSiblings(CSSSelector::PseudoClass type)
{
    return type == CSSSelector::PseudoClass::Empty
        || type == CSSSelector::PseudoClass::FirstChild
        || type == CSSSelector::PseudoClass::FirstOfType
        || type == CSSSelector::PseudoClass::LastChild
        || type == CSSSelector::PseudoClass::LastOfType
        || type == CSSSelector::PseudoClass::OnlyChild
        || type == CSSSelector::PseudoClass::OnlyOfType
        || type == CSSSelector::PseudoClass::NthChild
        || type == CSSSelector::PseudoClass::NthOfType
        || type == CSSSelector::PseudoClass::NthLastChild
        || type == CSSSelector::PseudoClass::NthLastOfType;
}

static inline bool isTreeStructuralPseudoClass(CSSSelector::PseudoClass type)
{
    return pseudoClassIsRelativeToSiblings(type) || type == CSSSelector::PseudoClass::Root;
}

inline bool isLogicalCombinationPseudoClass(CSSSelector::PseudoClass pseudoClass)
{
    switch (pseudoClass) {
    case CSSSelector::PseudoClass::Is:
    case CSSSelector::PseudoClass::Where:
    case CSSSelector::PseudoClass::WebKitAny:
    case CSSSelector::PseudoClass::Not:
    case CSSSelector::PseudoClass::Has:
        return true;
    default:
        return false;
    }
}

NODELETE bool isElementBackedPseudoElement(CSSSelector::PseudoElement);

inline bool CSSSelector::isAttributeSelector() const
{
    return match() == CSSSelector::Match::Exact
        || match() == CSSSelector::Match::Set
        || match() == CSSSelector::Match::List
        || match() == CSSSelector::Match::Hyphen
        || match() == CSSSelector::Match::Contain
        || match() == CSSSelector::Match::Begin
        || match() == CSSSelector::Match::End;
}

inline void CSSSelector::setValue(const AtomString& value, bool matchLowerCase)
{
    ASSERT_WITH_SECURITY_IMPLICATION(match() != Match::Tag);
    auto matchingValue = matchLowerCase ? value.convertToASCIILowercase() : value;
    if (m_rareData || matchingValue != value)
        createRareData();

    if (!m_rareData) {
        m_value = value;
        return;
    }

    m_rareData->matchingValue = WTF::move(matchingValue);
    m_rareData->serializingValue = value;
}

inline CSSSelector::~CSSSelector()
{
    ASSERT_WITH_SECURITY_IMPLICATION(!m_destructorHasBeenCalled);
#if !ASSERT_WITH_SECURITY_IMPLICATION_DISABLED
    m_destructorHasBeenCalled = true;
#endif
}

inline const QualifiedName& CSSSelector::tagQName() const
{
    return m_name;
}

inline const AtomString& CSSSelector::tagLowercaseLocalName() const
{
    return tagQName().localNameLowercase();
}

inline const AtomString& CSSSelector::value() const
{
    ASSERT_WITH_SECURITY_IMPLICATION(match() != Match::Tag);
    if (m_rareData)
        return m_rareData->matchingValue;
    return m_value;
}

inline const AtomString& CSSSelector::serializingValue() const
{
    ASSERT_WITH_SECURITY_IMPLICATION(match() != Match::Tag);
    if (m_rareData)
        return m_rareData->serializingValue;
    return m_value;
}

inline auto CSSSelector::attributeMatchType() const -> AttributeMatchType
{
    return static_cast<AttributeMatchType>(m_attributeMatchType);
}

inline auto CSSSelector::pseudoClass() const -> PseudoClass
{
    ASSERT(match() == Match::PseudoClass);
    return static_cast<PseudoClass>(m_pseudoType);
}

inline void CSSSelector::setPseudoClass(PseudoClass pseudoClass)
{
    m_pseudoType = std::to_underlying(pseudoClass);
    ASSERT(static_cast<PseudoClass>(m_pseudoType) == pseudoClass);
}

inline auto CSSSelector::pseudoElement() const -> PseudoElement
{
    ASSERT(match() == Match::PseudoElement);
    return static_cast<PseudoElement>(m_pseudoType);
}

inline void CSSSelector::setPseudoElement(PseudoElement pseudoElement)
{
    m_pseudoType = std::to_underlying(pseudoElement);
    ASSERT(static_cast<PseudoElement>(m_pseudoType) == pseudoElement);
}

inline auto CSSSelector::pagePseudoClass() const -> PagePseudoClass
{
    ASSERT(match() == Match::PagePseudoClass);
    return static_cast<PagePseudoClass>(m_pseudoType);
}

inline void CSSSelector::setPagePseudoClass(PagePseudoClass pagePseudoClass)
{
    m_pseudoType = std::to_underlying(pagePseudoClass);
    ASSERT(static_cast<PagePseudoClass>(m_pseudoType) == pagePseudoClass);
}

inline void CSSSelector::setRelation(Relation relation)
{
    m_relation = std::to_underlying(relation);
}

inline void CSSSelector::setMatch(Match match)
{
    m_match = std::to_underlying(match);
}

} // namespace WebCore
