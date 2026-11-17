/*
 * Copyright (C) 2003 Lars Knoll (knoll@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2008, 2009, 2010, 2014 Apple Inc. All rights reserved.
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

#include <WebCore/CSSSelector.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/text/AtomStringHash.h>

namespace WebCore {

class MutableCSSSelector;
using MutableCSSSelectorList = Vector<std::unique_ptr<MutableCSSSelector>>;

class MutableCSSSelector {
    WTF_MAKE_TZONE_ALLOCATED(MutableCSSSelector);
public:
    MutableCSSSelector();

    // Recursively copy the selector chain.
    MutableCSSSelector(const CSSSelector&);

    // Only copy the simple selector.
    enum SimpleSelectorTag { SimpleSelector };
    MutableCSSSelector(const CSSSelector&, SimpleSelectorTag);

    explicit MutableCSSSelector(const QualifiedName&);

    ~MutableCSSSelector();

    CSSSelector releaseSelector() { return WTF::move(m_selector); }
    const CSSSelector& selector() const LIFETIME_BOUND { return m_selector; };
    CSSSelector& selector() LIFETIME_BOUND { return m_selector; }

    void setValue(const AtomString& value, bool matchLowerCase = false) { m_selector.setValue(value, matchLowerCase); }

    void setMatch(CSSSelector::Match value) { m_selector.setMatch(value); }
    void setRelation(CSSSelector::Relation value) { m_selector.setRelation(value); }

    void setPseudoElement(CSSSelector::PseudoElement type) { m_selector.setPseudoElement(type); }
    void setPseudoClass(CSSSelector::PseudoClass type) { m_selector.setPseudoClass(type); }

    void setStringList(FixedVector<AtomString>);
    void setSelectorList(std::unique_ptr<CSSSelectorList>);

    MutableCSSSelector* precedingInComplexSelector() const LIFETIME_BOUND { return m_precedingInComplexSelector.get(); }
    NODELETE MutableCSSSelector* leftmostSimpleSelector();
    NODELETE const MutableCSSSelector* leftmostSimpleSelector() const;
    void setPrecedingInComplexSelector(std::unique_ptr<MutableCSSSelector> selector) { m_precedingInComplexSelector = WTF::move(selector); }
    void prependInComplexSelector(CSSSelector::Relation, std::unique_ptr<MutableCSSSelector>);

private:
    CSSSelector m_selector;
    std::unique_ptr<MutableCSSSelector> m_precedingInComplexSelector;
};

} // namespace WebCore
