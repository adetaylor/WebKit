/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
#include "ScrollingStateOverflowScrollProxyNode.h"

#if ENABLE(ASYNC_SCROLLING)

#include "ScrollingStateOverflowScrollingNode.h"
#include "ScrollingStateTree.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingStateOverflowScrollProxyNode);

ScrollingStateOverflowScrollProxyNode::ScrollingStateOverflowScrollProxyNode(ScrollingNodeID nodeID, Vector<Ref<ScrollingStateNode>>&& children, OptionSet<ScrollingStateNodeProperty> changedProperties, std::optional<PlatformLayerIdentifier> layerID, std::optional<ScrollingNodeID> overflowScrollingNode)
    : ScrollingStateNode(ScrollingNodeType::OverflowProxy, nodeID, WTFMove(children), changedProperties, layerID)
    , m_overflowScrollingNodeID(overflowScrollingNode)
{
}

ScrollingStateOverflowScrollProxyNode::ScrollingStateOverflowScrollProxyNode(ScrollingStateTree& stateTree, ScrollingNodeID nodeID)
    : ScrollingStateNode(ScrollingNodeType::OverflowProxy, stateTree, nodeID)
{
}

ScrollingStateOverflowScrollProxyNode::ScrollingStateOverflowScrollProxyNode(const ScrollingStateOverflowScrollProxyNode& stateNode, ScrollingStateTree& adoptiveTree)
    : ScrollingStateNode(stateNode, adoptiveTree)
    , m_overflowScrollingNodeID(stateNode.overflowScrollingNode())
{
}

ScrollingStateOverflowScrollProxyNode::~ScrollingStateOverflowScrollProxyNode() = default;

Ref<ScrollingStateNode> ScrollingStateOverflowScrollProxyNode::clone(ScrollingStateTree& adoptiveTree)
{
    return adoptRef(*new ScrollingStateOverflowScrollProxyNode(*this, adoptiveTree));
}

OptionSet<ScrollingStateNode::Property> ScrollingStateOverflowScrollProxyNode::applicableProperties() const
{
    constexpr OptionSet<Property> nodeProperties = { Property::OverflowScrollingNode };

    auto properties = ScrollingStateNode::applicableProperties();
    properties.add(nodeProperties);
    return properties;
}


void ScrollingStateOverflowScrollProxyNode::setOverflowScrollingNode(std::optional<ScrollingNodeID> nodeID)
{
    if (nodeID == m_overflowScrollingNodeID)
        return;
    
    m_overflowScrollingNodeID = nodeID;
    setPropertyChanged(Property::OverflowScrollingNode);
}

void ScrollingStateOverflowScrollProxyNode::dumpProperties(TextStream& ts, OptionSet<ScrollingStateTreeAsTextBehavior> behavior) const
{
    ts << "Overflow scroll proxy node"_s;
    
    ScrollingStateNode::dumpProperties(ts, behavior);

    if (auto relatedOverflowNode = scrollingStateTree().stateNodeForID(m_overflowScrollingNodeID)) {
        if (RefPtr overflowScrollingNode = dynamicDowncast<ScrollingStateOverflowScrollingNode>(relatedOverflowNode))
            ts.dumpProperty("related overflow scrolling node scroll position"_s, overflowScrollingNode->scrollPosition());
    }

    if (behavior & ScrollingStateTreeAsTextBehavior::IncludeNodeIDs)
        ts.dumpProperty("overflow scrolling node"_s, overflowScrollingNode());
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
