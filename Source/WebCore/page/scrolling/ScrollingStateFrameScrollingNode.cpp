/*
 * Copyright (C) 2014, 2016 Apple Inc. All rights reserved.
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
#include "ScrollingStateFrameScrollingNode.h"

#if ENABLE(ASYNC_SCROLLING)

#include "ScrollingStateTree.h"
#include <ranges>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingStateFrameScrollingNode);

ScrollingStateFrameScrollingNode::ScrollingStateFrameScrollingNode(
    bool isMainFrame,
    ScrollingNodeID scrollingNodeID,
    Vector<Ref<WebCore::ScrollingStateNode>>&& children,
    OptionSet<ScrollingStateNodeProperty> changedProperties,
    std::optional<WebCore::PlatformLayerIdentifier> layerID,
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
    RequestedKeyboardScrollData&& keyboardScrollData,
    float frameScaleFactor,
    EventTrackingRegions&& eventTrackingRegions,
    std::optional<PlatformLayerIdentifier> rootContentsLayer,
    std::optional<PlatformLayerIdentifier> counterScrollingLayer,
    std::optional<PlatformLayerIdentifier> insetClipLayer,
    std::optional<PlatformLayerIdentifier> contentShadowLayer,
    int headerHeight,
    int footerHeight,
    ScrollBehaviorForFixedElements&& scrollBehaviorForFixedElements,
    FloatBoxExtent&& obscuredContentInsets,
#if HAVE(NSREFRESHCONTROLLER)
    float topScrollStretchForRefreshController,
#endif
    bool visualViewportIsSmallerThanLayoutViewport,
    bool asyncFrameOrOverflowScrollingEnabled,
    bool wheelEventGesturesBecomeNonBlocking,
    bool scrollingPerformanceTestingEnabled,
    FloatRect layoutViewport,
    FloatSize sizeForVisibleContent,
    FloatPoint minLayoutViewportOrigin,
    FloatPoint maxLayoutViewportOrigin,
    std::optional<FloatSize> overrideVisualViewportSize,
    bool overlayScrollbarsEnabled,
    int insetForLeftScrollbarSpace
) : ScrollingStateScrollingNode(
    isMainFrame ? ScrollingNodeType::MainFrame : ScrollingNodeType::Subframe,
    scrollingNodeID,
    WTF::move(children),
    changedProperties,
    layerID,
    scrollableAreaSize,
    totalContentsSize,
    reachableContentsSize,
    scrollPosition,
    scrollOrigin,
    WTF::move(scrollableAreaParameters),
#if ENABLE(SCROLLING_THREAD)
    synchronousScrollingReasons,
#endif
    WTF::move(requestedScrollData),
    WTF::move(snapOffsetsInfo),
    currentHorizontalSnapPointIndex,
    currentVerticalSnapPointIndex,
    isMonitoringWheelEvents,
    scrollContainerLayer,
    scrolledContentsLayer,
    horizontalScrollbarLayer,
    verticalScrollbarLayer,
    mouseIsOverContentArea,
    WTF::move(mouseLocationState),
    WTF::move(scrollbarHoverState),
    WTF::move(scrollbarEnabledState),
    WTF::move(scrollbarColor),
    scrollbarLayoutDirection,
    scrollbarWidth,
    useDarkAppearanceForScrollbars,
    WTF::move(keyboardScrollData))
    , m_rootContentsLayer(rootContentsLayer)
    , m_counterScrollingLayer(counterScrollingLayer)
    , m_insetClipLayer(insetClipLayer)
    , m_contentShadowLayer(contentShadowLayer)
    , m_eventTrackingRegions(WTF::move(eventTrackingRegions))
    , m_layoutViewport(layoutViewport)
    , m_sizeForVisibleContent(sizeForVisibleContent)
    , m_minLayoutViewportOrigin(minLayoutViewportOrigin)
    , m_maxLayoutViewportOrigin(maxLayoutViewportOrigin)
    , m_overrideVisualViewportSize(overrideVisualViewportSize)
    , m_frameScaleFactor(frameScaleFactor)
    , m_obscuredContentInsets(obscuredContentInsets)
#if HAVE(NSREFRESHCONTROLLER)
    , m_topScrollStretchForRefreshController(topScrollStretchForRefreshController)
#endif
    , m_headerHeight(headerHeight)
    , m_footerHeight(footerHeight)
    , m_insetForLeftScrollbarSpace(insetForLeftScrollbarSpace)
    , m_behaviorForFixed(WTF::move(scrollBehaviorForFixedElements))

    , m_visualViewportIsSmallerThanLayoutViewport(visualViewportIsSmallerThanLayoutViewport)
    , m_asyncFrameOrOverflowScrollingEnabled(asyncFrameOrOverflowScrollingEnabled)
    , m_wheelEventGesturesBecomeNonBlocking(wheelEventGesturesBecomeNonBlocking)
    , m_scrollingPerformanceTestingEnabled(scrollingPerformanceTestingEnabled)
    , m_overlayScrollbarsEnabled(overlayScrollbarsEnabled)
{
    ASSERT(isFrameScrollingNode());
}

ScrollingStateFrameScrollingNode::ScrollingStateFrameScrollingNode(ScrollingStateTree& stateTree, ScrollingNodeType nodeType, ScrollingNodeID nodeID)
    : ScrollingStateScrollingNode(stateTree, nodeType, nodeID)
{
    ASSERT(isFrameScrollingNode());
}

ScrollingStateFrameScrollingNode::ScrollingStateFrameScrollingNode(const ScrollingStateFrameScrollingNode& stateNode, ScrollingStateTree& adoptiveTree)
    : ScrollingStateScrollingNode(stateNode, adoptiveTree)
    , m_eventTrackingRegions(stateNode.eventTrackingRegions())
    , m_layoutViewport(stateNode.layoutViewport())
    , m_sizeForVisibleContent(stateNode.sizeForVisibleContent())
    , m_minLayoutViewportOrigin(stateNode.minLayoutViewportOrigin())
    , m_maxLayoutViewportOrigin(stateNode.maxLayoutViewportOrigin())
    , m_overrideVisualViewportSize(stateNode.overrideVisualViewportSize())
    , m_frameScaleFactor(stateNode.frameScaleFactor())
    , m_obscuredContentInsets(stateNode.obscuredContentInsets())
#if HAVE(NSREFRESHCONTROLLER)
    , m_topScrollStretchForRefreshController(stateNode.topScrollStretchForRefreshController())
#endif
    , m_headerHeight(stateNode.headerHeight())
    , m_footerHeight(stateNode.footerHeight())
    , m_insetForLeftScrollbarSpace(stateNode.insetForLeftScrollbarSpace())
    , m_behaviorForFixed(stateNode.scrollBehaviorForFixedElements())
    , m_visualViewportIsSmallerThanLayoutViewport(stateNode.visualViewportIsSmallerThanLayoutViewport())
    , m_asyncFrameOrOverflowScrollingEnabled(stateNode.asyncFrameOrOverflowScrollingEnabled())
    , m_wheelEventGesturesBecomeNonBlocking(stateNode.wheelEventGesturesBecomeNonBlocking())
    , m_scrollingPerformanceTestingEnabled(stateNode.scrollingPerformanceTestingEnabled())
    , m_overlayScrollbarsEnabled(stateNode.overlayScrollbarsEnabled())
{
    if (hasChangedProperty(Property::RootContentsLayer))
        setRootContentsLayer(stateNode.rootContentsLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::CounterScrollingLayer))
        setCounterScrollingLayer(stateNode.counterScrollingLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::InsetClipLayer))
        setInsetClipLayer(stateNode.insetClipLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::ContentShadowLayer))
        setContentShadowLayer(stateNode.contentShadowLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::HeaderLayer))
        setHeaderLayer(stateNode.headerLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));

    if (hasChangedProperty(Property::FooterLayer))
        setFooterLayer(stateNode.footerLayer().toRepresentation(adoptiveTree.preferredLayerRepresentation()));
}

ScrollingStateFrameScrollingNode::~ScrollingStateFrameScrollingNode() = default;

Ref<ScrollingStateNode> ScrollingStateFrameScrollingNode::clone(ScrollingStateTree& adoptiveTree)
{
    return adoptRef(*new ScrollingStateFrameScrollingNode(*this, adoptiveTree));
}

void ScrollingStateFrameScrollingNode::setEventTrackingRegions(const EventTrackingRegions& eventTrackingRegions)
{
    if (m_eventTrackingRegions == eventTrackingRegions)
        return;

    m_eventTrackingRegions = eventTrackingRegions;
    setPropertyChanged(Property::EventTrackingRegion);
}

void ScrollingStateFrameScrollingNode::setObscuredContentInsets(FloatBoxExtent obscuredContentInsets)
{
    if (m_obscuredContentInsets == obscuredContentInsets)
        return;

    m_obscuredContentInsets = obscuredContentInsets;
    setPropertyChanged(Property::ObscuredContentInsets);
}

void ScrollingStateFrameScrollingNode::setRootContentsLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_rootContentsLayer)
        return;

    m_rootContentsLayer = layerRepresentation;
    setPropertyChanged(Property::RootContentsLayer);
}

void ScrollingStateFrameScrollingNode::setCounterScrollingLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_counterScrollingLayer)
        return;
    
    m_counterScrollingLayer = layerRepresentation;
    setPropertyChanged(Property::CounterScrollingLayer);
}

void ScrollingStateFrameScrollingNode::setInsetClipLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_insetClipLayer)
        return;
    
    m_insetClipLayer = layerRepresentation;
    setPropertyChanged(Property::InsetClipLayer);
}

void ScrollingStateFrameScrollingNode::setContentShadowLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_contentShadowLayer)
        return;
    
    m_contentShadowLayer = layerRepresentation;
    setPropertyChanged(Property::ContentShadowLayer);
}

void ScrollingStateFrameScrollingNode::setHeaderLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_headerLayer)
        return;
    
    m_headerLayer = layerRepresentation;
    setPropertyChanged(Property::HeaderLayer);
}

void ScrollingStateFrameScrollingNode::setFooterLayer(const LayerRepresentation& layerRepresentation)
{
    if (layerRepresentation == m_footerLayer)
        return;
    
    m_footerLayer = layerRepresentation;
    setPropertyChanged(Property::FooterLayer);
}

String ScrollingStateFrameScrollingNode::dumpPropertiesText(ScrollingStateTreeAsTextBehaviors behavior, int indent, TextStreamFormattingFlags formattingFlags, unsigned containerSizeLimit) const
{
    TextStream ts(TextStream::LineMode::MultipleLine, formattingFlags, containerSizeLimit);
    ts.setIndent(indent);
    ts << "Frame scrolling node"_s;
    
    ts << ScrollingStateScrollingNode::dumpPropertiesText(behavior, indent, formattingFlags, containerSizeLimit);
    
    if (behavior & ScrollingStateTreeAsTextBehavior::IncludeLayerIDs) {
        ts.dumpProperty("root contents layer ID"_s, m_rootContentsLayer.layerID());
        if (m_counterScrollingLayer.layerID())
            ts.dumpProperty("counter scrolling layer ID"_s, m_counterScrollingLayer.layerID());
        if (m_insetClipLayer.layerID())
            ts.dumpProperty("inset clip layer ID"_s, m_insetClipLayer.layerID());
        if (m_contentShadowLayer.layerID())
            ts.dumpProperty("content shadow layer ID"_s, m_contentShadowLayer.layerID());
        if (m_headerLayer.layerID())
            ts.dumpProperty("header layer ID"_s, m_headerLayer.layerID());
        if (m_footerLayer.layerID())
            ts.dumpProperty("footer layer ID"_s, m_footerLayer.layerID());
    }

    if (m_frameScaleFactor != 1)
        ts.dumpProperty("frame scale factor"_s, m_frameScaleFactor);
    if (m_obscuredContentInsets.top())
        ts.dumpProperty("top content inset"_s, m_obscuredContentInsets.top());
    if (m_obscuredContentInsets.bottom())
        ts.dumpProperty("bottom content inset"_s, m_obscuredContentInsets.bottom());
    if (m_obscuredContentInsets.left())
        ts.dumpProperty("left content inset"_s, m_obscuredContentInsets.left());
    if (m_obscuredContentInsets.right())
        ts.dumpProperty("right content inset"_s, m_obscuredContentInsets.right());
#if HAVE(NSREFRESHCONTROLLER)
    if (m_topScrollStretchForRefreshController)
        ts.dumpProperty("top scroll stretch for refresh controller"_s, m_topScrollStretchForRefreshController);
#endif
    if (m_headerHeight)
        ts.dumpProperty("header height"_s, m_headerHeight);
    if (m_footerHeight)
        ts.dumpProperty("footer height"_s, m_footerHeight);
    
    ts.dumpProperty("layout viewport"_s, m_layoutViewport);

    if (m_layoutViewport.size() != m_sizeForVisibleContent)
        ts.dumpProperty("size for visible content"_s, m_sizeForVisibleContent);

    ts.dumpProperty("min layout viewport origin"_s, m_minLayoutViewportOrigin);
    ts.dumpProperty("max layout viewport origin"_s, m_maxLayoutViewportOrigin);
    
    if (m_overrideVisualViewportSize)
        ts.dumpProperty("override visual viewport size"_s, m_overrideVisualViewportSize.value());

    if (!m_eventTrackingRegions.asynchronousDispatchRegion.isEmpty()) {
        TextStream::GroupScope scope(ts);
        ts << "asynchronous event dispatch region"_s;
        for (auto rect : m_eventTrackingRegions.asynchronousDispatchRegion.rects()) {
            ts << '\n';
            ts.writeIndent();
            ts << rect;
        }
    }

    auto& synchronousDispatchRegionMap = m_eventTrackingRegions.eventSpecificSynchronousDispatchRegions;
    if (!synchronousDispatchRegionMap.isEmpty()) {
        auto eventRegionNames = copyToVector(synchronousDispatchRegionMap.keys());
        std::ranges::sort(eventRegionNames);
        for (const auto& name : eventRegionNames) {
            const auto& region = synchronousDispatchRegionMap.get(name);
            TextStream::GroupScope scope(ts);
            ts << "synchronous event dispatch region for event "_s << EventTrackingRegions::eventName(name);
            for (auto rect : region.rects()) {
                ts << '\n';
                ts.writeIndent();
                ts << rect;
            }
        }
    }

    ts.dumpProperty("behavior for fixed"_s, m_behaviorForFixed);

    if (m_visualViewportIsSmallerThanLayoutViewport)
        ts.dumpProperty("visual viewport smaller than layout viewport"_s, m_visualViewportIsSmallerThanLayoutViewport);

    return ts.release();
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
