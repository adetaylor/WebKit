/*
 * Copyright (C) 2014 Apple Inc. All rights reserved.
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

#include "config.h"
#include "ScrollingTreeFrameScrollingNode.h"

#if ENABLE(ASYNC_SCROLLING)

#include "LocalFrameView.h"
#include "Logging.h"
#include "ScrollingStateFrameScrollingNode.h"
#include "ScrollingStateTree.h"
#include "ScrollingTree.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingTreeFrameScrollingNode);

ScrollingTreeFrameScrollingNode::ScrollingTreeFrameScrollingNode(ScrollingTree& scrollingTree, ScrollingNodeType nodeType, ScrollingNodeID nodeID)
    : ScrollingTreeScrollingNode(scrollingTree, nodeType, nodeID)
{
    ASSERT(isFrameScrollingNode());
}

ScrollingTreeFrameScrollingNode::~ScrollingTreeFrameScrollingNode() = default;

FloatRect ScrollingTreeFrameScrollingNode::layoutViewportForScrollPosition(FloatPoint visibleContentOrigin, float scale, ScrollBehaviorForFixedElements fixedBehavior) const
{
    FloatSize visualViewportSize = m_overrideVisualViewportSize.value_or(scrollableAreaSize());
    FloatRect visibleContentRect(visibleContentOrigin, visualViewportSize);
    LayoutRect visualViewport(LocalFrameView::visibleDocumentRect(visibleContentRect, headerHeight(), footerHeight(), totalContentsSize(), scale));
    LayoutRect layoutViewport(m_layoutViewport);

    LOG_WITH_STREAM(Scrolling, stream << "ScrollingTreeFrameScrollingNode " << scrollingNodeID() << " layoutViewportForScrollPosition: " << "(visibleContentOrigin " << visibleContentOrigin << ", visualViewportSize " << visualViewportSize << ") fixed behavior " << m_behaviorForFixed);
    LOG_WITH_STREAM(Scrolling, stream << "  layoutViewport: " << layoutViewport);
    LOG_WITH_STREAM(Scrolling, stream << "  visualViewport: " << visualViewport);
    LOG_WITH_STREAM(Scrolling, stream << "  scroll positions: min: " << minLayoutViewportOrigin() << " max: "<< maxLayoutViewportOrigin());

    LayoutPoint newLocation = LocalFrameView::computeLayoutViewportOrigin(LayoutRect(visualViewport), LayoutPoint(minLayoutViewportOrigin()), LayoutPoint(maxLayoutViewportOrigin()), layoutViewport, fixedBehavior);

    if (layoutViewport.location() != newLocation) {
        layoutViewport.setLocation(newLocation);
        LOG_WITH_STREAM(Scrolling, stream << " new layoutViewport " << layoutViewport);
    }

    return layoutViewport;
}

void ScrollingTreeFrameScrollingNode::repositionScrollingLayersForDelegatedScaleChange()
{
    repositionScrollingLayers();
}

void ScrollingTreeFrameScrollingNode::dumpProperties(TextStream& ts, OptionSet<ScrollingStateTreeAsTextBehavior> behavior) const
{
    ts << frameScrollingNodePropertiesText(behavior, ts.indent(), ts.formattingFlags(), ts.containerSizeLimit());
}


} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
