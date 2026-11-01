/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#include <WebCore/ImageBufferAllocator.h>
#include <memory>
#include <wtf/Noncopyable.h>
#include <wtf/TZoneMalloc.h>

#if !defined(__swift__)
namespace WebCore {
class FilterResultsImpl;
}
#endif

namespace WebCore {

class Filter;

// The results of the effects of filters applied with it, which later applies reuse until an effect changes, and the
// allocator of the filters' images. Its state is in FilterResultsImpl (FilterEngine.swift), a Swift struct that it stores
// inline.
class FilterResults {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(FilterResults, WEBCORE_EXPORT);
    WTF_MAKE_NONCOPYABLE(FilterResults);
public:
    WEBCORE_EXPORT FilterResults(std::unique_ptr<ImageBufferAllocator>&& = nullptr);
    WEBCORE_EXPORT ~FilterResults();

    ImageBufferAllocator& allocator() const { return *m_allocator; }

    // Forgets the result of the effect at `effectIndex` of `filter` (its function in a CSS filter, its effect in an SVG
    // filter), and the results made from it.
    void clearEffectResult(const Filter&, unsigned effectIndex);

#if !defined(__swift__)
    FilterResultsImpl& swiftImpl() LIFETIME_BOUND;
#endif

private:
    // The stored properties of FilterResultsImpl, for the size and alignment of its storage, which FilterResults.cpp
    // checks against the Swift struct.
    struct ImplLayout {
        void* results;
        void* references;
    };

    // The FilterResultsImpl, which FilterResults.cpp builds in place in the constructor and destroys in the destructor.
    alignas(ImplLayout) std::byte m_impl[sizeof(ImplLayout)];
    const std::unique_ptr<ImageBufferAllocator> m_allocator;
};

using FilterResultsCreator = Function<std::unique_ptr<FilterResults>()>;

} // namespace WebCore
