/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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

#include "RenderBox.h"
#include <wtf/CheckedPtr.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

enum class ItemLayoutRequirement : uint8_t {
    NeedsColumnAxisStretchAlignment = 1 << 0,
    MinContentContributionForSecondColumnPass = 1 << 1,
};
using ItemsLayoutRequirements = SingleThreadWeakHashMap<RenderBox, OptionSet<ItemLayoutRequirement>>;

class GridLayoutState {
    WTF_MAKE_TZONE_ALLOCATED(GridLayoutState);
public:
    bool containsLayoutRequirementForGridItem(const RenderBox& gridItem, ItemLayoutRequirement) const;
    void setLayoutRequirementForGridItem(const RenderBox& gridItem, ItemLayoutRequirement);

    bool needsSecondTrackSizingPass() const { return m_needsSecondTrackSizingPass; }
    void setNeedsSecondTrackSizingPass() { m_needsSecondTrackSizingPass = true; }

    void setHasAspectRatioBlockSizeDependentItem() { m_hasAspectRatioBlockSizeDependentItem = true; }
    bool hasAspectRatioBlockSizeDependentItem() const { return m_hasAspectRatioBlockSizeDependentItem; }

private:
    ItemsLayoutRequirements m_itemsLayoutRequirements;
    bool m_needsSecondTrackSizingPass { false };
    bool m_hasAspectRatioBlockSizeDependentItem { false };
};

} // namespace WebCore
