/*
 * Copyright (C) 2003 Lars Knoll (knoll@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2008, 2014 Apple Inc. All rights reserved.
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

#include "config.h"
#include "MutableCSSSelector.h"

#include "CSSSelector.h"
#include "CSSSelectorList.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(MutableCSSSelector);

MutableCSSSelector::MutableCSSSelector() = default;

MutableCSSSelector::MutableCSSSelector(const QualifiedName& tagQName)
    : m_selector(tagQName)
{
}

MutableCSSSelector::MutableCSSSelector(const CSSSelector& selector)
    : m_selector(selector, CSSSelector::MutableSelectorCopy)
{
    if (auto preceding = selector.precedingInComplexSelector())
        m_precedingInComplexSelector = makeUnique<MutableCSSSelector>(*preceding);
}

MutableCSSSelector::MutableCSSSelector(const CSSSelector& selector, SimpleSelectorTag)
    : m_selector(selector, CSSSelector::MutableSelectorCopy)
{
}

MutableCSSSelector::~MutableCSSSelector()
{
    if (!m_precedingInComplexSelector)
        return;
    Vector<std::unique_ptr<MutableCSSSelector>, 16> toDelete;
    std::unique_ptr<MutableCSSSelector> selector = WTF::move(m_precedingInComplexSelector);
    while (true) {
        std::unique_ptr<MutableCSSSelector> next = WTF::move(selector->m_precedingInComplexSelector);
        toDelete.append(WTF::move(selector));
        if (!next)
            break;
        selector = WTF::move(next);
    }
}

void MutableCSSSelector::setStringList(FixedVector<AtomString> list)
{
    ASSERT(!list.isEmpty());
    m_selector.setStringList(WTF::move(list));
}

void MutableCSSSelector::setSelectorList(std::unique_ptr<CSSSelectorList> selectorList)
{
    m_selector.setSelectorList(WTF::move(selectorList));
}

const MutableCSSSelector* MutableCSSSelector::leftmostSimpleSelector() const
{
    auto selector = this;
    while (auto next = selector->precedingInComplexSelector())
        selector = next;
    return selector;
}

MutableCSSSelector* MutableCSSSelector::leftmostSimpleSelector()
{
    auto selector = this;
    while (auto next = selector->precedingInComplexSelector())
        selector = next;
    return selector;
}

void MutableCSSSelector::prependInComplexSelector(CSSSelector::Relation relation, std::unique_ptr<MutableCSSSelector> selector)
{
    auto* first = this;
    while (first->precedingInComplexSelector())
        first = first->precedingInComplexSelector();

    first->setRelation(relation);
    first->setPrecedingInComplexSelector(WTF::move(selector));
}

}
