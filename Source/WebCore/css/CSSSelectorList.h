/*
 * Copyright (C) 2008, 2014 Apple Inc. All rights reserved.
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

#pragma once

#include <WebCore/CSSSelector.h>
#include <iterator>
#include <memory>
#include <wtf/FixedVector.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class MutableCSSSelector;
using MutableCSSSelectorList = Vector<std::unique_ptr<MutableCSSSelector>>;

// The records of a CSSSelectorList, shared by its copies. A list's records are not written once a CSSSelectorList holds
// them. The vector stays private: Swift infers a Vector of records Sendable though their reference counts are not
// atomic. CSSSelector is unsafe to Swift, so safe Swift reads records only through CSSSelectorList's index accessors.
class CSSSelectorListStorage : public RefCounted<CSSSelectorListStorage> {
    WTF_MAKE_TZONE_ALLOCATED(CSSSelectorListStorage);
public:
    static Ref<CSSSelectorListStorage> create() { return adoptRef(*new CSSSelectorListStorage(Vector<CSSSelector> { })); }

    size_t componentCount() const { return m_selectors.size(); }
    CSSSelector selectorAt(size_t index) const { return m_selectors[index]; }
    void append(CSSSelector selector)
    {
        RELEASE_ASSERT(!m_isHeldByList);
        m_selectors.append(WTF::move(selector));
    }

private:
    friend class CSSSelectorList;
    explicit CSSSelectorListStorage(Vector<CSSSelector>&& selectors)
        : m_selectors(WTF::move(selectors))
    { }

    // End of a multipart selector is indicated by m_isLastInComplexSelector bit in the last item.
    Vector<CSSSelector> m_selectors;
    bool m_isHeldByList { false };
};

// A value handle on a CSSSelectorListStorage: copying a list shares its records. An empty list holds none.
class __attribute__((swift_attr("~Sendable"))) CSSSelectorList {
    WTF_MAKE_TZONE_ALLOCATED(CSSSelectorList);
public:
    CSSSelectorList() = default;
    CSSSelectorList(const CSSSelectorList&) = default;
    CSSSelectorList(CSSSelectorList&&) = default;
    explicit CSSSelectorList(Ref<CSSSelectorListStorage>&&);
    explicit CSSSelectorList(MutableCSSSelectorList&&);
    explicit CSSSelectorList(std::span<const CSSSelector* const>);

    static CSSSelectorList makeCopyingSimpleSelector(const CSSSelector&);
    static CSSSelectorList makeCopyingComplexSelector(const CSSSelector&);
    static CSSSelectorList makeJoining(const CSSSelectorList&, const CSSSelectorList&);
    static CSSSelectorList makeJoining(const Vector<const CSSSelectorList*>&);

    bool isEmpty() const { return !componentCount(); }
    const CSSSelector& first() const LIFETIME_BOUND { return selectorAt(0); }
    const CSSSelector& selectorAt(size_t index) const LIFETIME_BOUND
    {
        RELEASE_ASSERT(m_storage);
        return m_storage->m_selectors[index];
    }
    size_t indexOfSelector(const CSSSelector& selector) const
    {
        ASSERT(&selector >= selectors().data());
        ASSERT(&selector < std::to_address(selectors().end()));
        return &selector - selectors().data();
    }

    struct const_iterator {
        friend class CSSSelectorList;
        using value_type = CSSSelector;
        using difference_type = std::ptrdiff_t;
        using pointer = const CSSSelector*;
        using reference = const CSSSelector&;
        using iterator_category = std::forward_iterator_tag;
        reference operator*() const { return *m_ptr; }
        pointer operator->() const { return m_ptr; }
        bool operator==(const const_iterator&) const = default;
        const_iterator() = default;
        const_iterator(pointer ptr)
            : m_ptr(ptr)
        { }

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
        const_iterator& operator++()
        {
            // Skip subparts of compound selectors.
            while (m_ptr->precedingInComplexSelector())
                ++m_ptr;
            ++m_ptr;
            return *this;
        }
WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

        const_iterator operator++(int)
        {
            const_iterator temp = *this;
            ++*this;
            return temp;
        }

    private:
        pointer m_ptr = nullptr;
    };
    const_iterator begin() const LIFETIME_BOUND { return { selectors().data() }; };
    const_iterator end() const LIFETIME_BOUND { return { std::to_address(selectors().end()) }; }

    bool hasExplicitNestingParent() const;

    WEBCORE_EXPORT String selectorsText() const;
    void buildSelectorsText(StringBuilder&) const;

    unsigned componentCount() const { return m_storage ? m_storage->m_selectors.size() : 0; }
    unsigned size() const;

    CSSSelectorList& operator=(CSSSelectorList&&) = default;

    bool operator==(const CSSSelectorList&) const;

    // Swift reads a record in place, by its index, one checked access per call (CSSSelector is unsafe to Swift).
    // Records of one complex selector follow each other up to the one whose isFirstInComplexSelectorAt is true.
    CSSSelector::Match matchAt(size_t index) const { return selectorAt(index).match(); }
    CSSSelector::Relation relationAt(size_t index) const { return selectorAt(index).relation(); }
    CSSSelector::PseudoClass pseudoClassAt(size_t index) const { return selectorAt(index).pseudoClass(); }
    CSSSelector::PseudoElement pseudoElementAt(size_t index) const { return selectorAt(index).pseudoElement(); }
    CSSSelector::PagePseudoClass pagePseudoClassAt(size_t index) const { return selectorAt(index).pagePseudoClass(); }
    AtomString valueAt(size_t index) const { return selectorAt(index).value(); }
    AtomString serializingValueAt(size_t index) const { return selectorAt(index).serializingValue(); }
    QualifiedName tagQNameAt(size_t index) const { return selectorAt(index).tagQName(); }
    QualifiedName attributeAt(size_t index) const { return selectorAt(index).m_name; }
    CSSSelector::AttributeMatchType attributeMatchTypeAt(size_t index) const { return selectorAt(index).attributeMatchType(); }
    AtomString argumentAt(size_t index) const { return selectorAt(index).argument(); }
    int nthAAt(size_t index) const { auto& rareData = selectorAt(index).m_rareData; return rareData ? rareData->a : 0; }
    int nthBAt(size_t index) const { auto& rareData = selectorAt(index).m_rareData; return rareData ? rareData->b : 0; }
    size_t integerListSizeAt(size_t index) const { auto* list = selectorAt(index).integerList(); return list ? list->size() : 0; }
    int integerListItemAt(size_t index, size_t item) const { return checkedItem(checkedRareData(index).integerList, item); }
    size_t stringListSizeAt(size_t index) const { auto* list = selectorAt(index).stringList(); return list ? list->size() : 0; }
    AtomString stringListItemAt(size_t index, size_t item) const { return checkedItem(checkedRareData(index).stringList, item); }
    size_t langListSizeAt(size_t index) const { auto* list = selectorAt(index).langList(); return list ? list->size() : 0; }
    AtomString langListIdentifierAt(size_t index, size_t item) const { return checkedItem(checkedRareData(index).langList, item).identifier; }
    bool langListWasQuotedAt(size_t index, size_t item) const { return checkedItem(checkedRareData(index).langList, item).wasQuoted; }
    // The nested list of :is(), :not(), :has() and the like, sharing its records; empty when there is none.
    CSSSelectorList selectorListAt(size_t index) const { auto* list = selectorAt(index).selectorList(); return list ? *list : CSSSelectorList { }; }
    bool isFirstInComplexSelectorAt(size_t index) const { return selectorAt(index).m_isFirstInComplexSelector; }
    bool isLastInComplexSelectorAt(size_t index) const { return selectorAt(index).m_isLastInComplexSelector; }
    bool isForPageAt(size_t index) const { return selectorAt(index).isForPage(); }
    bool isImplicitAt(size_t index) const { return selectorAt(index).isImplicit(); }
    bool isEquivalentToClassSelectorAt(size_t index) const { return selectorAt(index).isEquivalentToClassSelector(); }
    bool tagIsForNamespaceRuleAt(size_t index) const { return selectorAt(index).m_tagIsForNamespaceRule; }

private:
    explicit CSSSelectorList(Vector<CSSSelector>&&);
    std::span<const CSSSelector> selectors() const LIFETIME_BOUND { return m_storage ? m_storage->m_selectors.span() : std::span<const CSSSelector> { }; }
    const CSSSelector::RareData& checkedRareData(size_t index) const
    {
        auto& rareData = selectorAt(index).m_rareData;
        RELEASE_ASSERT(rareData);
        return *rareData;
    }
    template<typename T> static const T& checkedItem(const FixedVector<T>& list, size_t item)
    {
        RELEASE_ASSERT(item < list.size());
        return list[item];
    }

    RefPtr<CSSSelectorListStorage> m_storage;
};

NODELETE void add(Hasher&, const CSSSelectorList&);

class RefCountedCSSSelectorList : public RefCounted<RefCountedCSSSelectorList> {
public:
    static Ref<RefCountedCSSSelectorList> create(CSSSelectorList&& selectorList) { return adoptRef(*new RefCountedCSSSelectorList(WTF::move(selectorList))); }

    const CSSSelectorList& selectorList() const LIFETIME_BOUND { return m_selectorList; }

private:
    explicit RefCountedCSSSelectorList(CSSSelectorList&& selectorList)
        : m_selectorList(WTF::move(selectorList))
    { }

    CSSSelectorList m_selectorList;
};

} // namespace WebCore
