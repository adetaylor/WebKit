/*
 * Copyright (C) 2008, 2012, 2013, 2014 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Google Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CSSSelectorList.h"

#include "CommonAtomStrings.h"
#include "MutableCSSSelector.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/ZippedRange.h>
#include <wtf/text/StringBuilder.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CSSSelectorListStorage);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CSSSelectorList);

Ref<CSSSelectorListStorage> CSSSelectorListStorage::createWithCapacity(size_t capacity)
{
    return adoptRef(*new CSSSelectorListStorage(Vector<CSSSelector>(ReserveCapacityTag { }, capacity)));
}

static CSSSelector::PseudoClass storageCheckedPseudoClass(uint8_t pseudo)
{
    RELEASE_ASSERT(pseudo <= std::to_underlying(CSSSelector::PseudoClass::WindowInactive));
    return static_cast<CSSSelector::PseudoClass>(pseudo);
}

static CSSSelector::PseudoElement storageCheckedPseudoElement(uint8_t pseudo)
{
    RELEASE_ASSERT(pseudo <= std::to_underlying(CSSSelector::PseudoElement::WebKitUnknown));
    return static_cast<CSSSelector::PseudoElement>(pseudo);
}

// The relation, the flags, the first and last bits; then the record goes last. Every walk stays in the vector: the first
// record starts a complex selector and the last ends one, whatever the caller passes.
CSSSelector& CSSSelectorListStorage::appendRecord(CSSSelectorFields fields, CSSSelector&& record)
{
    RELEASE_ASSERT(!m_isHeldByList);
    RELEASE_ASSERT(fields.relation <= std::to_underlying(CSSSelector::Relation::ShadowSlotted));
    RELEASE_ASSERT(fields.flags <= (CSSSelectorFields::LastFlag << 1) - 1);
    RELEASE_ASSERT(!(fields.flags & CSSSelectorFields::EquivalentToClass) || record.match() == CSSSelector::Match::List);
    RELEASE_ASSERT(!(fields.flags & CSSSelectorFields::TagIsForNamespaceRule) || record.match() == CSSSelector::Match::Tag);
    if (fields.flags & CSSSelectorFields::ContinuesComplexSelector) {
        RELEASE_ASSERT(!m_selectors.isEmpty());
        m_selectors.last().m_isFirstInComplexSelector = false;
        record.m_isLastInComplexSelector = false;
    }
    if (fields.flags & CSSSelectorFields::Implicit)
        record.setImplicit();
    if (fields.flags & CSSSelectorFields::ForPage)
        record.setForPage();
    record.setRelation(static_cast<CSSSelector::Relation>(fields.relation));
    m_selectors.append(WTF::move(record));
    return m_selectors.last();
}

void CSSSelectorListStorage::appendSimpleSelector(CSSSelectorFields fields, const AtomString& value)
{
    RELEASE_ASSERT(fields.match <= std::to_underlying(CSSSelector::Match::ForgivingUnknownNestContaining) && fields.list == CSSSelectorFields::List::None);
    CSSSelector record;
    auto match = static_cast<CSSSelector::Match>(fields.match);
    switch (match) {
    case CSSSelector::Match::Tag: case CSSSelector::Match::Exact: case CSSSelector::Match::Set: case CSSSelector::Match::List: case CSSSelector::Match::Hyphen: case CSSSelector::Match::Contain: case CSSSelector::Match::Begin: case CSSSelector::Match::End:
        RELEASE_ASSERT_NOT_REACHED(); // appendSelector
    case CSSSelector::Match::Unknown:
        break; // @page's selector with neither a type nor a page pseudo-class
    case CSSSelector::Match::PagePseudoClass:
        RELEASE_ASSERT(fields.pseudoType <= std::to_underlying(CSSSelector::PagePseudoClass::Right));
        record.setMatch(match);
        record.setPagePseudoClass(static_cast<CSSSelector::PagePseudoClass>(fields.pseudoType));
        break;
    case CSSSelector::Match::PseudoClass: {
        // Without an argument: only a pseudo-class that never takes one, or one of the two optional ones whose readers
        // check for a null list (:host: SelectorChecker::matchHostPseudoClass, maxSpecificity, RuleSet; :heading:
        // matchesHeadingPseudoClass, the JIT's generateElementMatchesHeading, RuleSet). A new optional pseudo traps here.
        auto pseudo = storageCheckedPseudoClass(fields.pseudoType);
        RELEASE_ASSERT(!CSSSelector::pseudoClassMayHaveArgument(pseudo) || pseudo == CSSSelector::PseudoClass::Host || pseudo == CSSSelector::PseudoClass::Heading);
        record.setMatch(match);
        record.setPseudoClass(pseudo);
        break;
    }
    case CSSSelector::Match::PseudoElement: {
        // ::cue without a list is dereferenced unchecked (SelectorChecker's PseudoElement::Cue); the parser makes the
        // bare ::cue a UserAgentPart. The part name of a UserAgentPart is hashed (RuleSet's m_userAgentPartRules).
        auto pseudo = storageCheckedPseudoElement(fields.pseudoType);
        RELEASE_ASSERT(!CSSSelector::pseudoElementMayHaveArgument(pseudo));
        RELEASE_ASSERT(!value.isNull() || (pseudo != CSSSelector::PseudoElement::UserAgentPart && pseudo != CSSSelector::PseudoElement::UserAgentPartLegacyAlias));
        record.setMatch(match);
        record.setPseudoElement(pseudo);
        break;
    }
    case CSSSelector::Match::Id: case CSSSelector::Match::Class: case CSSSelector::Match::ClassPrefix:
        // Hashed by RuleSet, RuleFeatureSet and SelectorFilter.
        RELEASE_ASSERT(!value.isNull());
        record.setMatch(match);
        break;
    default:
        record.setMatch(match);
        break;
    }
    if (!value.isNull())
        record.setValue(value, fields.flags & CSSSelectorFields::MatchLowerCase);
    appendRecord(fields, WTF::move(record));
}

void CSSSelectorListStorage::appendSelector(CSSSelectorFields fields, const AtomString& value, const QualifiedName& name, const AtomString& argument, int a, int b, CSSSelectorListStorage* selectorList, uint32_t listSize)
{
    switch (static_cast<CSSSelector::Match>(fields.match)) {
    case CSSSelector::Match::Tag:
        RELEASE_ASSERT(value.isNull() && argument.isNull() && !selectorList && fields.list == CSSSelectorFields::List::None);
        RELEASE_ASSERT(!name.localName().isNull()); // hashed by SelectorFilter and RuleSet
        appendRecord(fields, CSSSelector { name, !!(fields.flags & CSSSelectorFields::TagIsForNamespaceRule) });
        return;
    case CSSSelector::Match::PseudoClass:
    case CSSSelector::Match::PseudoElement:
        appendFunctionalSelector(fields, value, argument, a, b, selectorList, listSize);
        return;
    default:
        RELEASE_ASSERT(argument.isNull() && !selectorList);
        appendAttributeSelector(fields, name, value);
        return;
    }
}

void CSSSelectorListStorage::appendAttributeSelector(CSSSelectorFields fields, const QualifiedName& attribute, const AtomString& value)
{
    auto match = static_cast<CSSSelector::Match>(fields.match);
    RELEASE_ASSERT(match == CSSSelector::Match::Exact || match == CSSSelector::Match::Set || match == CSSSelector::Match::List || match == CSSSelector::Match::Hyphen || match == CSSSelector::Match::Contain || match == CSSSelector::Match::Begin || match == CSSSelector::Match::End);
    RELEASE_ASSERT(fields.attributeMatchType <= std::to_underlying(CSSSelector::AttributeMatchType::CaseSensitive) && fields.list == CSSSelectorFields::List::None);
    RELEASE_ASSERT((match == CSSSelector::Match::Set) == value.isNull());
    RELEASE_ASSERT(!attribute.localName().isNull()); // hashed by SelectorFilter and RuleFeatureSet
    CSSSelector record;
    record.setMatch(match);
    if (!value.isNull())
        record.setValue(value);
    record.setAttribute(attribute, static_cast<CSSSelector::AttributeMatchType>(fields.attributeMatchType));
    appendRecord(fields, WTF::move(record));
}

// The argument each pseudo-class and pseudo-element takes, as the parser gives it (consumePseudo): its readers dereference
// the selector list, the nth data and the lists without a check.
static bool storageArgumentAllowed(CSSSelector::Match match, uint8_t pseudo, bool hasSelectorList, CSSSelectorFields::List list)
{
    using List = CSSSelectorFields::List;
    if (match == CSSSelector::Match::PseudoClass) {
        switch (storageCheckedPseudoClass(pseudo)) {
        case CSSSelector::PseudoClass::Not: case CSSSelector::PseudoClass::Is: case CSSSelector::PseudoClass::Where: case CSSSelector::PseudoClass::WebKitAny: case CSSSelector::PseudoClass::Host: case CSSSelector::PseudoClass::Has:
            return hasSelectorList && list == List::None;
        case CSSSelector::PseudoClass::NthChild: case CSSSelector::PseudoClass::NthLastChild: return list == List::None;
        case CSSSelector::PseudoClass::Heading: return !hasSelectorList && list == List::Integers;
        case CSSSelector::PseudoClass::Lang: return !hasSelectorList && list == List::Identifiers;
        case CSSSelector::PseudoClass::ActiveViewTransitionType: return !hasSelectorList && list == List::Strings;
        case CSSSelector::PseudoClass::NthOfType: case CSSSelector::PseudoClass::NthLastOfType: case CSSSelector::PseudoClass::Dir: case CSSSelector::PseudoClass::State:
            return !hasSelectorList && list == List::None;
        default: return false;
        }
    }
    RELEASE_ASSERT(match == CSSSelector::Match::PseudoElement);
    switch (storageCheckedPseudoElement(pseudo)) {
#if ENABLE(VIDEO)
    case CSSSelector::PseudoElement::Cue:
#endif
    case CSSSelector::PseudoElement::Slotted:
        return hasSelectorList && list == List::None;
    case CSSSelector::PseudoElement::Highlight: case CSSSelector::PseudoElement::Picker: case CSSSelector::PseudoElement::Part:
    case CSSSelector::PseudoElement::ViewTransitionGroup: case CSSSelector::PseudoElement::ViewTransitionImagePair: case CSSSelector::PseudoElement::ViewTransitionOld: case CSSSelector::PseudoElement::ViewTransitionNew:
        return !hasSelectorList && list == List::Strings;
    default: return false;
    }
}

static bool storageIsNthPseudoClass(CSSSelector::Match match, uint8_t pseudo)
{
    return match == CSSSelector::Match::PseudoClass && (pseudo == std::to_underlying(CSSSelector::PseudoClass::NthChild) || pseudo == std::to_underlying(CSSSelector::PseudoClass::NthLastChild)
        || pseudo == std::to_underlying(CSSSelector::PseudoClass::NthOfType) || pseudo == std::to_underlying(CSSSelector::PseudoClass::NthLastOfType));
}

void CSSSelectorListStorage::appendFunctionalSelector(CSSSelectorFields fields, const AtomString& value, const AtomString& argument, int a, int b, CSSSelectorListStorage* selectorList, uint32_t listSize)
{
    auto match = static_cast<CSSSelector::Match>(fields.match);
    RELEASE_ASSERT(storageArgumentAllowed(match, fields.pseudoType, !!selectorList, fields.list));
    RELEASE_ASSERT((fields.list == CSSSelectorFields::List::None) == !listSize);
    // :state's argument is hashed (CustomStateSet); neither it nor :dir's is null from the parser.
    RELEASE_ASSERT(!argument.isNull() || match != CSSSelector::Match::PseudoClass || (fields.pseudoType != std::to_underlying(CSSSelector::PseudoClass::State) && fields.pseudoType != std::to_underlying(CSSSelector::PseudoClass::Dir)));
    CSSSelector record;
    record.setMatch(match);
    if (match == CSSSelector::Match::PseudoClass)
        record.setPseudoClass(storageCheckedPseudoClass(fields.pseudoType));
    else
        record.setPseudoElement(storageCheckedPseudoElement(fields.pseudoType));
    if (!value.isNull())
        record.setValue(value, fields.flags & CSSSelectorFields::MatchLowerCase);
    if (!argument.isNull())
        record.setArgument(argument);
    if (storageIsNthPseudoClass(match, fields.pseudoType))
        record.setNth(a, b);
    if (selectorList) {
        // A list holds `selectorList` from here: it is written no more. This one, if it is `selectorList`, traps below.
        RELEASE_ASSERT(selectorList->componentCount());
        record.setSelectorList(makeUnique<CSSSelectorList>(Ref { *selectorList }));
    }
    switch (fields.list) {
    case CSSSelectorFields::List::None: break;
    // An item setListItem does not set is an empty identifier, which every reader handles; a null one is hashed.
    case CSSSelectorFields::List::Strings: record.setStringList(FixedVector<AtomString>(FillWith { }, listSize, emptyAtom())); break;
    case CSSSelectorFields::List::Identifiers: record.setLangList(FixedVector<PossiblyQuotedIdentifier>(FillWith { }, listSize, PossiblyQuotedIdentifier { emptyAtom(), false })); break;
    case CSSSelectorFields::List::Integers: record.setIntegerList(FixedVector<int>(FillWith { }, listSize, 0)); break;
    }
    appendRecord(fields, WTF::move(record));
}

// The last record's RareData, its own (a C++ copy of the record may share it) so that it can be written.
CSSSelector::RareData& CSSSelectorListStorage::lastRareData()
{
    RELEASE_ASSERT(!m_isHeldByList && !m_selectors.isEmpty() && m_selectors.last().m_rareData);
    m_selectors.last().createRareData();
    return *m_selectors.last().m_rareData;
}

void CSSSelectorListStorage::setListItem(size_t item, const AtomString& atom, int integerOrQuoted)
{
    auto& rareData = lastRareData();
    if (!rareData.langList.isEmpty()) {
        RELEASE_ASSERT(item < rareData.langList.size() && !atom.isNull());
        rareData.langList[item] = { atom, !!integerOrQuoted };
    } else if (!rareData.stringList.isEmpty()) {
        RELEASE_ASSERT(item < rareData.stringList.size() && !integerOrQuoted && !atom.isNull());
        rareData.stringList[item] = atom;
    } else {
        RELEASE_ASSERT(item < rareData.integerList.size() && atom.isNull());
        rareData.integerList[item] = integerOrQuoted;
    }
}

// The way in for a storage the writer filled (and for a nested list it attaches). The leftmost record of each complex
// selector has a relation the parser gives it: DescendantSpace, a relative combinator (a relative selector in a nested
// context with no implicit & or :scope, consumeRelativeNestedSelector), or Subselector where the parser split a compound
// at an implicit shadow combinator (splitCompoundAtImplicitShadowCrossingCombinator), so that the complex has a Shadow*
// relation and the JIT declines it. Never a Shadow* relation. The interpreter ignores this relation; the JIT builds its
// fragments from it (SelectorCompiler's constructFragmentsInternal).
CSSSelectorList::CSSSelectorList(Ref<CSSSelectorListStorage>&& storage)
{
    bool crossesShadow = false;
    for (auto& selector : storage->m_selectors) {
        auto relation = selector.relation();
        if (selector.precedingInComplexSelector()) {
            crossesShadow |= relation == CSSSelector::Relation::ShadowDescendant || relation == CSSSelector::Relation::ShadowPartDescendant || relation == CSSSelector::Relation::ShadowSlotted;
            continue;
        }
        RELEASE_ASSERT(relation == CSSSelector::Relation::Subselector ? crossesShadow : relation <= CSSSelector::Relation::IndirectAdjacent);
        crossesShadow = false;
    }
    storage->m_isHeldByList = true;
    // Walks forward stop at m_isFirstInComplexSelector and back at m_isLastInComplexSelector, so these two keep every
    // walk inside the vector, whoever appended the records.
    auto& selectors = storage->m_selectors;
    RELEASE_ASSERT(selectors.isEmpty() || (selectors.first().m_isLastInComplexSelector && selectors.last().m_isFirstInComplexSelector));
    if (!storage->m_selectors.isEmpty())
        m_storage = WTF::move(storage);
}

// The C++ builders' records (the parser's, and copies and joins of lists made before) skip the relation check.
CSSSelectorList::CSSSelectorList(Vector<CSSSelector>&& selectors)
{
    auto storage = adoptRef(*new CSSSelectorListStorage(WTF::move(selectors)));
    storage->m_isHeldByList = true;
    RELEASE_ASSERT(storage->m_selectors.isEmpty() || (storage->m_selectors.first().m_isLastInComplexSelector && storage->m_selectors.last().m_isFirstInComplexSelector));
    if (!storage->m_selectors.isEmpty())
        m_storage = WTF::move(storage);
}

CSSSelectorList::CSSSelectorList(MutableCSSSelectorList&& selectorVector)
{
    ASSERT_WITH_SECURITY_IMPLICATION(!selectorVector.isEmpty());

    size_t flattenedSize = 0;
    for (size_t i = 0; i < selectorVector.size(); ++i) {
        for (auto* selector = selectorVector[i].get(); selector; selector = selector->precedingInComplexSelector())
            ++flattenedSize;
    }
    ASSERT(flattenedSize);
    Vector<CSSSelector> selectorArray(ReserveCapacityTag { }, flattenedSize);
    for (size_t i = 0; i < selectorVector.size(); ++i) {
        auto* last = selectorVector[i].get();
        auto* current = last;
        while (current) {
            selectorArray.append(current->releaseSelector());
            if (current != last)
                selectorArray.last().m_isLastInComplexSelector = false;
            current = current->precedingInComplexSelector();
            if (current)
                selectorArray.last().m_isFirstInComplexSelector = false;
        }
        ASSERT(!selectorArray.last().precedingInComplexSelector());
    }
    ASSERT(flattenedSize == selectorArray.size());
    *this = CSSSelectorList { WTF::move(selectorArray) };
}

CSSSelectorList::CSSSelectorList(std::span<const CSSSelector* const> selectors)
    : CSSSelectorList(Vector<CSSSelector>::map(selectors, [](auto* selector) {
        return *selector;
    }))
{
}

CSSSelectorList CSSSelectorList::makeCopyingSimpleSelector(const CSSSelector& simpleSelector)
{
    Vector<CSSSelector> selectorArray { simpleSelector };
    auto& firstSelector = selectorArray[0];
    firstSelector.m_isFirstInComplexSelector = true;
    firstSelector.m_isLastInComplexSelector = true;

    return CSSSelectorList { WTF::move(selectorArray) };
}

CSSSelectorList CSSSelectorList::makeCopyingComplexSelector(const CSSSelector& complexSelector)
{
    size_t length = 0;
    for (auto* selector = &complexSelector; selector; selector = selector->precedingInComplexSelector())
        ++length;

    Vector<CSSSelector> selectorArray(ReserveCapacityTag { }, length);
    for (auto* selector = &complexSelector; selector; selector = selector->precedingInComplexSelector())
        selectorArray.append(*selector);
    // complexSelector can be inside a complex selector (RuleFeature's :has() compounds): the copy starts one.
    selectorArray.first().m_isLastInComplexSelector = true;

    return CSSSelectorList { WTF::move(selectorArray) };
}

CSSSelectorList CSSSelectorList::makeJoining(const CSSSelectorList& a, const CSSSelectorList& b)
{
    if (a.isEmpty())
        return b;
    if (b.isEmpty())
        return a;

    auto aComponentCount = a.componentCount();
    auto bComponentCount = b.componentCount();

    Vector<CSSSelector> selectorArray(aComponentCount + bComponentCount, [&](size_t i) {
        return i < aComponentCount ? a.selectorAt(i) : b.selectorAt(i - aComponentCount);
    });

    return CSSSelectorList { WTF::move(selectorArray) };
}

CSSSelectorList CSSSelectorList::makeJoining(const Vector<const CSSSelectorList*>& lists)
{
    size_t totalComponentCount = 0;
    for (auto list : lists)
        totalComponentCount += list->componentCount();

    if (!totalComponentCount)
        return { };

    Vector<CSSSelector> selectorArray(ReserveCapacityTag { }, totalComponentCount);
    for (auto list : lists) {
        auto count = list->componentCount();
        for (size_t i = 0; i < count; ++i)
            selectorArray.append(list->selectorAt(i));
    }

    ASSERT(selectorArray.size() == totalComponentCount);

    return CSSSelectorList { WTF::move(selectorArray) };
}

unsigned CSSSelectorList::size() const
{
    return std::ranges::count_if(selectors(), [](auto& selector) {
        return !selector.precedingInComplexSelector();
    });
}

String CSSSelectorList::selectorsText() const
{
    StringBuilder result;
    buildSelectorsText(result);
    return result.toString();
}

void CSSSelectorList::buildSelectorsText(StringBuilder& stringBuilder) const
{
    stringBuilder.append(interleave(*this, [](auto& subSelector) { return subSelector.selectorText(); }, ", "_s));
}

template <typename Functor>
NODELETE static bool forEachTagSelector(NOESCAPE const Functor& functor, const CSSSelector* selector)
{
    ASSERT(selector);

    do {
        if (functor(selector))
            return true;
        if (const CSSSelectorList* selectorList = selector->selectorList()) {
            for (const auto& subSelector : *selectorList) {
                if (forEachTagSelector(functor, &subSelector))
                    return true;
            }
        }
    } while ((selector = selector->precedingInComplexSelector()));

    return false;
}

template <typename Functor>
NODELETE static bool forEachSelector(NOESCAPE const Functor& functor, const CSSSelectorList& selectorList)
{
    for (const auto& selector : selectorList) {
        if (forEachTagSelector(functor, &selector))
            return true;
    }

    return false;
}

bool CSSSelectorList::hasExplicitNestingParent() const
{
    auto functor = [](auto* selector) {
        return selector->match() == CSSSelector::Match::NestingParent
            || selector->match() == CSSSelector::Match::ForgivingUnknownNestContaining;
    };

    return forEachSelector(functor, *this);
}

bool CSSSelectorList::operator==(const CSSSelectorList& other) const
{
    if (componentCount() != other.componentCount())
        return false;

    for (auto [a, b] : zippedRange(*this, other)) {
        if (!complexSelectorsEqual(a, b))
            return false;
    }
    return true;
}

void add(Hasher& hasher, const CSSSelectorList& list)
{
    for (auto& selector : list)
        addComplexSelector(hasher, selector);
}


} // namespace WebCore
