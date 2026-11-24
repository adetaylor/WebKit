/*
 * Copyright (C) 2012, 2015 Apple Inc. All rights reserved.
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
#include "ScrollingStateScrollingNode.h"

#if ENABLE(ASYNC_SCROLLING)

#include "ScrollingStateTree.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
#include "ScrollerImpAdwaita.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingStateScrollingNode);

ScrollingStateScrollingNode::ScrollingStateScrollingNode(ScrollingStateTree& stateTree, ScrollingNodeType nodeType, ScrollingNodeID nodeID)
    : ScrollingStateNode(nodeType, stateTree, nodeID)
{
    scrollingStateTree().scrollingNodeAdded();
}

ScrollingStateScrollingNode::ScrollingStateScrollingNode(
    ScrollingNodeType nodeType,
    ScrollingNodeID nodeID,
    Vector<Ref<ScrollingStateNode>>&& children,
    OptionSet<ScrollingStateNodeProperty> changedProperties,
    std::optional<PlatformLayerIdentifier> layerID,
    FloatSize scrollableAreaSize,
    FloatSize totalContentsSize,
    FloatSize reachableContentsSize,
    FloatPoint scrollPosition,
    IntPoint scrollOrigin,
    ScrollableAreaParameters&& scrollableAreaParameters,
#if ENABLE(SCROLLING_THREAD)
    OptionSet<SynchronousScrollingReason> synchronousScrollingReasons,
#endif
    ScrollRequestData&& requestedScrollData,
    FloatScrollSnapOffsetsInfo&& snapOffsetsInfo,
    std::optional<unsigned> currentHorizontalSnapPointIndex,
    std::optional<unsigned> currentVerticalSnapPointIndex,
    bool isMonitoringWheelEvents,
    std::optional<PlatformLayerIdentifier> scrollContainerLayer,
    std::optional<PlatformLayerIdentifier> scrolledContentsLayer,
    std::optional<PlatformLayerIdentifier> horizontalScrollbarLayer,
    std::optional<PlatformLayerIdentifier> verticalScrollbarLayer,
    bool mouseIsOverContentArea,
    MouseLocationState&& mouseLocationState,
    ScrollbarHoverState&& scrollbarHoverState,
    ScrollbarEnabledState&& scrollbarEnabledState,
    std::optional<ScrollbarColor>&& scrollbarColor,
    UserInterfaceLayoutDirection scrollbarLayoutDirection,
    ScrollbarWidth scrollbarWidth,
    bool useDarkAppearanceForScrollbars,
    RequestedKeyboardScrollData&& keyboardScrollData
) : ScrollingStateNode(nodeType, nodeID, WTF::move(children), changedProperties, layerID)
    , m_scrollableAreaSize(scrollableAreaSize)
    , m_totalContentsSize(totalContentsSize)
    , m_reachableContentsSize(reachableContentsSize)
    , m_scrollPosition(scrollPosition)
    , m_scrollOrigin(scrollOrigin)
    , m_snapOffsetsInfo(WTF::move(snapOffsetsInfo))
    , m_currentHorizontalSnapPointIndex(currentHorizontalSnapPointIndex)
    , m_currentVerticalSnapPointIndex(currentVerticalSnapPointIndex)
    , m_scrollContainerLayer(scrollContainerLayer)
    , m_scrolledContentsLayer(scrolledContentsLayer)
    , m_horizontalScrollbarLayer(horizontalScrollbarLayer)
    , m_verticalScrollbarLayer(verticalScrollbarLayer)
    , m_scrollbarHoverState(WTF::move(scrollbarHoverState))
    , m_mouseLocationState(WTF::move(mouseLocationState))
    , m_scrollbarEnabledState(WTF::move(scrollbarEnabledState))
    , m_scrollbarColor(WTF::move(scrollbarColor))
    , m_scrollableAreaParameters(WTF::move(scrollableAreaParameters))
    , m_requestedScrollData(WTF::move(requestedScrollData))
    , m_keyboardScrollData(WTF::move(keyboardScrollData))
#if ENABLE(SCROLLING_THREAD)
    , m_synchronousScrollingReasons(synchronousScrollingReasons)
#endif
    , m_scrollbarLayoutDirection(scrollbarLayoutDirection)
    , m_scrollbarWidth(scrollbarWidth)
    , m_useDarkAppearanceForScrollbars(useDarkAppearanceForScrollbars)
    , m_isMonitoringWheelEvents(isMonitoringWheelEvents)
    , m_mouseIsOverContentArea(mouseIsOverContentArea)
{
    // scrollingNodeAdded will be called in attachAfterDeserialization.
}

ScrollingStateScrollingNode::ScrollingStateScrollingNode(const ScrollingStateScrollingNode& stateNode, ScrollingStateTree& adoptiveTree)
    : ScrollingStateNode(stateNode, adoptiveTree)
    , m_scrollableAreaSize(stateNode.scrollableAreaSize())
    , m_totalContentsSize(stateNode.totalContentsSize())
    , m_reachableContentsSize(stateNode.reachableContentsSize())
    , m_scrollPosition(stateNode.scrollPosition())
    , m_scrollOrigin(stateNode.scrollOrigin())
    , m_snapOffsetsInfo(stateNode.m_snapOffsetsInfo)
    // m_currentHorizontalSnapPointIndex is not currently copied.
    // m_currentVerticalSnapPointIndex is not currently copied.
#if PLATFORM(MAC) || USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
    , m_scrollbarHoverState(stateNode.scrollbarHoverState())
#endif
#if PLATFORM(MAC)
    , m_mouseLocationState(stateNode.mouseLocationState())
#endif
#if PLATFORM(MAC) || USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
    , m_scrollbarEnabledState(stateNode.scrollbarEnabledState())
    , m_verticalScrollerImp(stateNode.m_verticalScrollerImp)
    , m_horizontalScrollerImp(stateNode.m_horizontalScrollerImp)
#endif
    , m_scrollbarColor(stateNode.scrollbarColor())
    , m_scrollableAreaParameters(stateNode.scrollableAreaParameters())
    , m_requestedScrollData(stateNode.requestedScrollData())
    , m_keyboardScrollData(stateNode.keyboardScrollData())
#if ENABLE(SCROLLING_THREAD)
    , m_synchronousScrollingReasons(stateNode.synchronousScrollingReasons())
#endif
    , m_scrollbarLayoutDirection(stateNode.scrollbarLayoutDirection())
    , m_scrollbarWidth(stateNode.scrollbarWidth())
    , m_useDarkAppearanceForScrollbars(stateNode.useDarkAppearanceForScrollbars())
    , m_isMonitoringWheelEvents(stateNode.isMonitoringWheelEvents())
    , m_mouseIsOverContentArea(stateNode.mouseIsOverContentArea())
#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
    , m_scrollbarOpacity(stateNode.scrollbarOpacity())
#endif
{
    scrollingStateTree().scrollingNodeAdded();

    if (hasChangedProperty(Property::ScrollContainerLayer))
        setScrollContainerLayer(stateNode.scrollContainerLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::ScrolledContentsLayer))
        setScrolledContentsLayer(stateNode.scrolledContentsLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::VerticalScrollbarLayer))
        setVerticalScrollbarLayer(stateNode.verticalScrollbarLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::HorizontalScrollbarLayer))
        setHorizontalScrollbarLayer(stateNode.horizontalScrollbarLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));
}

ScrollingStateScrollingNode::~ScrollingStateScrollingNode()
{
    if (isAttachedToScrollingStateTree())
        scrollingStateTree().scrollingNodeRemoved();
}

void ScrollingStateScrollingNode::setSnapOffsetsInfo(const FloatScrollSnapOffsetsInfo& info)
{
    if (m_snapOffsetsInfo.isEqual(info))
        return;

    m_snapOffsetsInfo = info;
    setPropertyChanged(Property::SnapOffsetsInfo);
}

void ScrollingStateScrollingNode::setScrollableAreaParameters(const ScrollableAreaParameters& parameters)
{
    if (m_scrollableAreaParameters == parameters)
        return;

    m_scrollableAreaParameters = parameters;
    setPropertyChanged(Property::ScrollableAreaParams);
}

void ScrollingStateScrollingNode::setKeyboardScrollData(RequestedKeyboardScrollData scrollData)
{
    m_keyboardScrollData = scrollData;
    setPropertyChanged(Property::KeyboardScrollData);
}

void ScrollingStateScrollingNode::setRequestedScrollData(RequestedScrollData&& scrollData)
{
    if (hasChangedProperty(Property::RequestedScrollPosition)) {
        ASSERT(m_requestedScrollData.size());
        mergeOrAppendScrollRequest(WTF::move(scrollData));
        return;
    }

    m_requestedScrollData.resize(1);
    m_requestedScrollData[0] = WTF::move(scrollData);

    setPropertyChanged(Property::RequestedScrollPosition);
}

void ScrollingStateScrollingNode::setScrollContainerLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_scrollContainerLayer)
        return;

    m_scrollContainerLayer = layerRepresentation;
    setPropertyChanged(Property::ScrollContainerLayer);
}

void ScrollingStateScrollingNode::setScrolledContentsLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_scrolledContentsLayer)
        return;

    m_scrolledContentsLayer = layerRepresentation;
    setPropertyChanged(Property::ScrolledContentsLayer);
}

void ScrollingStateScrollingNode::setHorizontalScrollbarLayer(const LayerRepresentation& layer)
{
    if (layer == m_horizontalScrollbarLayer)
        return;

    m_horizontalScrollbarLayer = layer;
    setPropertyChanged(Property::HorizontalScrollbarLayer);
}

void ScrollingStateScrollingNode::setVerticalScrollbarLayer(const LayerRepresentation& layer)
{
    if (layer == m_verticalScrollbarLayer)
        return;
    m_verticalScrollbarLayer = layer;
    setPropertyChanged(Property::VerticalScrollbarLayer);
}

String ScrollingStateScrollingNode::snapOffsetsPropertiesText(int indent, TextStreamFormattingFlags formattingFlags, unsigned containerSizeLimit) const
{
    TextStream ts(TextStream::LineMode::MultipleLine, formattingFlags, containerSizeLimit);
    ts.setIndent(indent);

    if (m_snapOffsetsInfo.horizontalSnapOffsets.size())
        ts.dumpProperty("horizontal snap offsets"_s, m_snapOffsetsInfo.horizontalSnapOffsets);

    if (m_snapOffsetsInfo.verticalSnapOffsets.size())
        ts.dumpProperty("vertical snap offsets"_s, m_snapOffsetsInfo.verticalSnapOffsets);

    return ts.release();
}

#if !PLATFORM(MAC) && !USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
void ScrollingStateScrollingNode::setScrollerImpsFromScrollbars(Scrollbar*, Scrollbar*)
{
}
#endif
    
void ScrollingStateScrollingNode::setScrollbarColor(std::optional<ScrollbarColor> state)
{
    if (state == m_scrollbarColor)
        return;

    m_scrollbarColor = state;
    setPropertyChanged(Property::ScrollbarColor);
}

#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
void ScrollingStateScrollingNode::setScrollbarOpacity(float scrollbarOpacity)
{
    if (scrollbarOpacity == m_scrollbarOpacity)
        return;
    m_scrollbarOpacity = scrollbarOpacity;
    setPropertyChanged(Property::ScrollbarOpacity);
}
#endif

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
