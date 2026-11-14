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

CSSSelectorList::CSSSelectorList(Ref<CSSSelectorListStorage>&& storage)
{
    storage->m_isHeldByList = true;
    // Walks forward stop at m_isFirstInComplexSelector and back at m_isLastInComplexSelector, so these two keep every
    // walk inside the vector, whoever appended the records.
    auto& selectors = storage->m_selectors;
    RELEASE_ASSERT(selectors.isEmpty() || (selectors.first().m_isLastInComplexSelector && selectors.last().m_isFirstInComplexSelector));
    if (!storage->m_selectors.isEmpty())
        m_storage = WTF::move(storage);
}

CSSSelectorList::CSSSelectorList(Vector<CSSSelector>&& selectors)
    : CSSSelectorList(adoptRef(*new CSSSelectorListStorage(WTF::move(selectors))))
{
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
