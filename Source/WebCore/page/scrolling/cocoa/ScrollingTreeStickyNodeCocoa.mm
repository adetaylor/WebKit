/*
 * Copyright (C) 2012 Apple Inc. All rights reserved.
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

#import "config.h"
#import "ScrollingTreeStickyNodeCocoa.h"

#import "ScrollingStateStickyNode.h"
#import "ScrollingTree.h"
#import <wtf/TZoneMalloc.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingTreeStickyNodeCocoa);

Ref<ScrollingTreeStickyNodeCocoa> ScrollingTreeStickyNodeCocoa::create(ScrollingTree& scrollingTree, ScrollingNodeID nodeID)
{
    return adoptRef(*new ScrollingTreeStickyNodeCocoa(scrollingTree, nodeID));
}

ScrollingTreeStickyNodeCocoa::ScrollingTreeStickyNodeCocoa(ScrollingTree& scrollingTree, ScrollingNodeID nodeID)
    : ScrollingTreeStickyNode(scrollingTree, nodeID)
{
}

bool ScrollingTreeStickyNodeCocoa::commitStateBeforeChildren(const ScrollingStateNode& stateNode)
{
    if (stateNode.hasChangedProperty(ScrollingStateNode::Property::Layer))
        m_layer = static_cast<CALayer *>(stateNode.layer());

    if (stateNode.hasChangedProperty(ScrollingStateNode::Property::ViewportAnchorLayer)) {
        if (RefPtr stickyStateNode = dynamicDowncast<ScrollingStateStickyNode>(stateNode))
            m_viewportAnchorLayer = static_cast<CALayer *>(stickyStateNode->viewportAnchorLayer());
    }

    return ScrollingTreeStickyNode::commitStateBeforeChildren(stateNode);
}

#if ENABLE(OVERLAY_REGIONS_REMOTE_EFFECT)
void ScrollingTreeStickyNodeCocoa::willBeDestroyed()
{
    RefPtr scrollingTree = this->scrollingTree();
    if (!scrollingTree)
        return;

    ensureOnMainRunLoop([scrollingTree = WTF::move(scrollingTree), nodeID = scrollingNodeID()] {
        scrollingTree->scrollingTreeNodeWillBeRemoved(nodeID);
    });
}
#endif

void ScrollingTreeStickyNodeCocoa::setIsSticking(bool isSticking)
{
    if (m_isSticking == isSticking)
        return;

    m_isSticking = isSticking;

    RefPtr scrollingTree = this->scrollingTree();
    if (!scrollingTree)
        return;

    ensureOnMainRunLoop([scrollingTree = WTF::move(scrollingTree), nodeID = scrollingNodeID(), isSticking] {
        if (isSticking)
            scrollingTree->stickyScrollingTreeNodeBeganSticking(nodeID);
#if ENABLE(OVERLAY_REGIONS_REMOTE_EFFECT)
        else
            scrollingTree->stickyScrollingTreeNodeEndedSticking(nodeID);
#endif
    });
}

} // namespace WebCore
