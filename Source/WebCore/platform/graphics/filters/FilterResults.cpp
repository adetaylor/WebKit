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

#include "config.h"
#include "FilterResults.h"

#include "FilterGraphicsBridge.h"
#include <new>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(FilterResults);

FilterResults::FilterResults(std::unique_ptr<ImageBufferAllocator>&& allocator)
    : m_allocator(allocator ? WTF::move(allocator) : makeUnique<ImageBufferAllocator>())
    , m_imageAllocator(FilterImageAllocator::create(*m_allocator))
{
    static_assert(sizeof(FilterResultsImpl) == sizeof(m_impl) && alignof(FilterResultsImpl) == alignof(ImplLayout));
    new (m_impl) FilterResultsImpl(FilterResultsImpl::init());
}

FilterResults::~FilterResults()
{
    std::destroy_at(&swiftImpl());
    m_imageAllocator->revoke();
}

FilterResultsImpl& FilterResults::swiftImpl()
{
    return *std::launder(reinterpret_cast<FilterResultsImpl*>(m_impl));
}

void FilterResults::clearEffectResult(const Filter& filter, unsigned effectIndex)
{
    swiftImpl().clearEffectResult(reinterpret_cast<uintptr_t>(&filter), effectIndex);
}

} // namespace WebCore
