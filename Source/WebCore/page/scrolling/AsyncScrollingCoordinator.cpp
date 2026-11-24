/*
 * Copyright (C) 2014-2015 Apple Inc. All rights reserved.
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

#if ENABLE(ASYNC_SCROLLING)
#include "AsyncScrollingCoordinator.h"

#include "ContainerNodeInlines.h"
#include "DebugPageOverlays.h"
#include "DeprecatedGlobalSettings.h"
#include "DocumentQuirks.h"
#include "DocumentView.h"
#include "EditorClient.h"
#include "GraphicsLayer.h"
#include "LocalFrameInlines.h"
#include "LocalFrameView.h"
#include "Logging.h"
#include "Page.h"
#include "PerformanceLoggingClient.h"
#include "Quirks.h"
#include "RemoteFrame.h"
#include "RenderLayerCompositor.h"
#include "RenderObjectInlines.h"
#include "RenderView.h"
#include "ScrollAnimator.h"
#include "ScrollbarInlines.h"
#include "ScrollbarsController.h"
#include "ScrollingConstraints.h"
#include "ScrollingStateFixedNode.h"
#include "ScrollingStateFrameHostingNode.h"
#include "ScrollingStateFrameScrollingNode.h"
#include "ScrollingStateOverflowScrollProxyNode.h"
#include "ScrollingStateOverflowScrollingNode.h"
#include "ScrollingStatePositionedNode.h"
#include "ScrollingStateStickyNode.h"
#include "ScrollingStateTree.h"
#include "Settings.h"
#include "WheelEventTestMonitor.h"
#include "pal/HysteresisActivity.h"
#include <wtf/ProcessID.h>
#include <wtf/SystemTracing.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AsyncScrollingCoordinator);

AsyncScrollingCoordinator::AsyncScrollingCoordinator(Page* page)
    : ScrollingCoordinator(page)
    , m_hysterisisActivity([this](auto state) { hysterisisTimerFired(state); }, 200_ms)
{
}

void AsyncScrollingCoordinator::hysterisisTimerFired(PAL::HysteresisState state)
{
    if (auto* page = this->page(); page && state == PAL::HysteresisState::Stopped)
        page->didFinishScrolling();
}

AsyncScrollingCoordinator::~AsyncScrollingCoordinator() = default;

#if PLATFORM(COCOA)
void AsyncScrollingCoordinator::handleWheelEventPhase(LocalFrameView& frameView, ScrollingNodeID nodeID, PlatformWheelEventPhase phase)
{
    CheckedPtr<ScrollableArea> scrollableArea = nodeID == frameView.scrollingNodeID() ? &frameView : frameView.scrollableAreaForScrollingNodeID(nodeID);
    if (scrollableArea)
        scrollableArea->scrollAnimator().handleWheelEventPhase(phase);
}
#endif

RefPtr<ScrollingStateNode> AsyncScrollingCoordinator::stateNodeForNodeID(std::optional<ScrollingNodeID> nodeID) const
{
    return WTF::switchOn(m_scrollingStateTrees.rawStorage(), [] (const std::monostate&) -> RefPtr<ScrollingStateNode> {
        return nullptr;
    }, [&] (const KeyValuePair<FrameIdentifier, UniqueRef<ScrollingStateTree>>& pair) {
        return protect(pair.value)->stateNodeForID(nodeID);
    }, [&] (const HashMap<FrameIdentifier, UniqueRef<ScrollingStateTree>>& map) -> RefPtr<ScrollingStateNode> {
        for (auto& tree : map.values()) {
            if (RefPtr scrollingNode = tree->stateNodeForID(nodeID))
                return scrollingNode;
        }
        return nullptr;
    });
}

RefPtr<ScrollingStateNode> AsyncScrollingCoordinator::stateNodeForScrollableArea(const ScrollableArea& scrollableArea) const
{
    auto scrollingNodeID = scrollableArea.scrollingNodeID();
    if (!scrollingNodeID)
        return nullptr;
    if (CheckedPtr scrollingStateTree = existingScrollingStateTreeForRootFrameID(scrollableArea.rootFrameID()))
        return scrollingStateTree->stateNodeForID(scrollingNodeID);
    return nullptr;
}

ScrollingStateTree& AsyncScrollingCoordinator::ensureScrollingStateTreeForRootFrameID(FrameIdentifier rootFrameID)
{
    ASSERT(Frame::isRootFrameIdentifier(rootFrameID));
    return m_scrollingStateTrees.ensure(rootFrameID, [&] {
        return ScrollingStateTree::create(this);
    });
}

const ScrollingStateTree* AsyncScrollingCoordinator::existingScrollingStateTreeForRootFrameID(std::optional<FrameIdentifier> rootFrameID) const
{
    auto* result = rootFrameID ? m_scrollingStateTrees.get(*rootFrameID) : nullptr;
    if (!result)
        return nullptr;
    return &result->get();
}

void AsyncScrollingCoordinator::rootFrameWasRemoved(FrameIdentifier rootFrameID)
{
    m_scrollingStateTrees.remove(rootFrameID);
}

ScrollingStateTree* AsyncScrollingCoordinator::stateTreeForNodeID(std::optional<ScrollingNodeID> nodeID) const
{
    return WTF::switchOn(m_scrollingStateTrees.rawStorage(), [] (const std::monostate&) -> ScrollingStateTree* {
        return nullptr;
    }, [&] (const KeyValuePair<FrameIdentifier, UniqueRef<ScrollingStateTree>>& pair) -> ScrollingStateTree* {
        if (RefPtr scrollingNode = protect(pair.value)->stateNodeForID(nodeID))
            return pair.value.ptr();
        return nullptr;
    }, [&] (const HashMap<FrameIdentifier, UniqueRef<ScrollingStateTree>>& map) -> ScrollingStateTree* {
        for (auto& tree : map.values()) {
            if (RefPtr scrollingNode = tree->stateNodeForID(nodeID))
                return tree.ptr();
        }
        return nullptr;
    });
}

static inline void setStateScrollingNodeSnapOffsetsAsFloat(ScrollingStateScrollingNode& node, const LayoutScrollSnapOffsetsInfo* offsetInfo, float deviceScaleFactor)
{
    if (!offsetInfo) {
        node.setSnapOffsetsInfo(FloatScrollSnapOffsetsInfo());
        return;
    }

    // FIXME: Incorporate current page scale factor in snapping to device pixel. Perhaps we should just convert to float here and let UI process do the pixel snapping?
    node.setSnapOffsetsInfo(offsetInfo->convertUnits<FloatScrollSnapOffsetsInfo>(deviceScaleFactor));
}

void AsyncScrollingCoordinator::updateEventTrackingRegions(FrameIdentifier rootFrameID)
{
    if (!m_eventTrackingRegionsDirty)
        return;

    CheckedPtr scrollingStateTree = existingScrollingStateTreeForRootFrameID(rootFrameID);
    if (!scrollingStateTree || !scrollingStateTree->rootStateNode())
        return;

    scrollingStateTree->rootStateNode()->setEventTrackingRegions(absoluteEventTrackingRegions());
    m_eventTrackingRegionsDirty = false;
}

void AsyncScrollingCoordinator::scrollableAreaWillBeDetached(ScrollableArea& area)
{
    scrollableAreaWillBeDetached(stateNodeForScrollableArea(area).get(), area.scrollPosition());
}

void AsyncScrollingCoordinator::frameViewEventTrackingRegionsChanged(LocalFrameView& frameView)
{
    m_eventTrackingRegionsDirty = true;
    if (!ensureScrollingStateTreeForRootFrameID(frameView.frame().rootFrame().frameID()).rootStateNode())
        return;

    // We have to schedule a commit, but the computed non-fast region may not have actually changed.
    // FIXME: This needs to disambiguate between event regions in the scrolling tree, and those in GraphicsLayers.
    scheduleTreeStateCommit();

    DebugPageOverlays::didChangeEventHandlers(protect(frameView.frame()));
}

void AsyncScrollingCoordinator::frameViewRootLayerDidChange(LocalFrameView& frameView)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    ASSERT(page());

    if (!coordinatesScrollingForFrameView(frameView))
        return;
    
    // FIXME: In some navigation scenarios, the FrameView has no RenderView or that RenderView has not been composited.
    // This needs cleaning up: https://bugs.webkit.org/show_bug.cgi?id=132724
    if (!frameView.scrollingNodeID())
        return;
    
    // If the root layer does not have a ScrollingStateNode, then we should create one.
    ensureRootStateNodeForFrameView(frameView);
    ASSERT(stateNodeForScrollableArea(frameView));

    ScrollingCoordinator::frameViewRootLayerDidChange(frameView);

    RefPtr node = dynamicDowncast<ScrollingStateFrameScrollingNode>(stateNodeForScrollableArea(frameView));
    if (!node)
        return;
    node->setScrollContainerLayer(protect(scrollContainerLayerForFrameView(frameView)).get());
    node->setScrolledContentsLayer(protect(scrolledContentsLayerForFrameView(frameView)).get());
    node->setRootContentsLayer(protect(rootContentsLayerForFrameView(frameView)).get());
    node->setCounterScrollingLayer(protect(counterScrollingLayerForFrameView(frameView)).get());
    node->setInsetClipLayer(protect(insetClipLayerForFrameView(frameView)).get());
    node->setContentShadowLayer(protect(contentShadowLayerForFrameView(frameView)).get());
    node->setHeaderLayer(protect(headerLayerForFrameView(frameView)).get());
    node->setFooterLayer(protect(footerLayerForFrameView(frameView)).get());
    node->setScrollBehaviorForFixedElements(frameView.scrollBehaviorForFixedElements());
    node->setVerticalScrollbarLayer(protect(frameView.layerForVerticalScrollbar()).get());
    node->setHorizontalScrollbarLayer(protect(frameView.layerForHorizontalScrollbar()).get());
    node->setScrollbarLayoutDirection(frameView.shouldPlaceVerticalScrollbarOnLeft() ? UserInterfaceLayoutDirection::RTL : UserInterfaceLayoutDirection::LTR);
}

bool AsyncScrollingCoordinator::requestStartKeyboardScrollAnimation(ScrollableArea& area, const KeyboardScroll& scrollData)
{
    return requestStartKeyboardScrollAnimation(stateNodeForScrollableArea(area).get(), scrollData);
}

bool AsyncScrollingCoordinator::requestStopKeyboardScrollAnimation(ScrollableArea& area, bool immediate)
{
    return requestStopKeyboardScrollAnimation(stateNodeForScrollableArea(area).get(), immediate);
}

bool AsyncScrollingCoordinator::requestScrollToPosition(ScrollableArea& scrollableArea, const ScrollPosition& scrollPosition, const ScrollPositionChangeOptions& options)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    ASSERT(page());
    auto scrollingNodeID = scrollableArea.scrollingNodeID();
    if (!scrollingNodeID)
        return false;

    RefPtr frameView = frameViewForScrollingNode(*scrollingNodeID);
    if (!frameView)
        return false;

    if (!coordinatesScrollingForFrameView(*frameView))
        return false;

    setScrollingNodeScrollableAreaGeometry(*scrollingNodeID, scrollableArea);

    bool inBackForwardCache = frameView->frame().document()->backForwardCacheState() != Document::NotInBackForwardCache;
    bool isSnapshotting = page()->isTakingSnapshotsForApplicationSuspension();
    bool inProgrammaticScroll = scrollableArea.currentScrollType() == ScrollType::Programmatic;

    if ((inProgrammaticScroll && options.animated == ScrollIsAnimated::No) || inBackForwardCache) {
        auto adjustedScrollPosition = scrollPosition;
        if (options.clamping == ScrollClamping::Clamped && !protect(frameView->frame().document())->quirks().shouldAvoidProgrammaticScrollClamping())
            adjustedScrollPosition = scrollableArea.adjustScrollPositionWithinRange(scrollPosition);

        auto scrollUpdate = ScrollUpdate {
            .nodeID = *scrollingNodeID,
            .scrollPosition = adjustedScrollPosition,
            .data = ScrollUpdateData {
                .updateType = ScrollUpdateType::PositionUpdate,
                .updateLayerPositionAction = ScrollingLayerPositionAction::Set,
            },
        };

        if (scrollingNodeID == frameView->scrollingNodeID())
            frameView->adjustExposedContentRectForProgrammaticScroll(adjustedScrollPosition);

        applyScrollUpdate(WTF::move(scrollUpdate), ScrollType::Programmatic);
    }

    ASSERT(inProgrammaticScroll == (options.type == ScrollType::Programmatic));

    // If this frame view's document is being put into the back/forward cache, we don't want to update our
    // main frame scroll position. Just let the FrameView think that we did.
    if (isSnapshotting)
        return true;

    auto stateNode = dynamicDowncast<ScrollingStateScrollingNode>(stateNodeForScrollableArea(scrollableArea));
    if (!stateNode)
        return false;

    tracePoint(ProgrammaticScroll, scrollPosition.y(), frameView->frame().isMainFrame());

    auto requestedScrollData = RequestedScrollData {
        .requestType = (options.animated == ScrollIsAnimated::Yes) ? ScrollRequestType::AnimatedPositionUpdate : ScrollRequestType::PositionUpdate,
        .scrollPositionOrDelta = scrollPosition,
        .identifier = { },
        .scrollType = options.type,
        .clamping = options.clamping,
        .scrollbarRevealBehavior = scrollableArea.scrollbarRevealBehavior(),
        .animationCurve = options.animationCurve,
    };

    if (options.originalScrollDelta) {
        if (options.animated == ScrollIsAnimated::Yes)
            requestedScrollData.requestType = ScrollRequestType::AnimatedDeltaUpdate;
        else if (options.interruptsAnimation == ScrollInterruptsAnimation::No)
            requestedScrollData.requestType = ScrollRequestType::ImplicitDeltaUpdate;
        else
            requestedScrollData.requestType = ScrollRequestType::DeltaUpdate;

        requestedScrollData.scrollPositionOrDelta = *options.originalScrollDelta;
    }

    willSendScrollPositionRequest(*scrollingNodeID, requestedScrollData);
    stateNode->setRequestedScrollData(WTF::move(requestedScrollData));
    stateNode->setScrollPosition(scrollableArea.scrollPosition()); // applyScrollUpdate() above may have modified the scroll position after the call to setScrollingNodeScrollableAreaGeometry().

    LOG_WITH_STREAM(Scrolling, stream << "AsyncScrollingCoordinator::requestScrollToPosition " << scrollPosition << " for nodeID " << scrollingNodeID << " requestedScrollData " << stateNode->requestedScrollData());

    // FIXME: This should schedule a rendering update
    commitTreeStateIfNeeded();
    return true;
}

void AsyncScrollingCoordinator::stopAnimatedScroll(ScrollableArea& area)
{
    stopAnimatedScroll(area.scrollingNodeID(), stateNodeForScrollableArea(area).get());
}

void AsyncScrollingCoordinator::setScrollbarLayoutDirection(ScrollableArea& area, UserInterfaceLayoutDirection direction)
{
    setScrollbarLayoutDirection(stateNodeForScrollableArea(area).get(), direction);
}

void AsyncScrollingCoordinator::setScrollbarColor(ScrollableArea& area, std::optional<ScrollbarColor> color)
{
    setScrollbarColor(stateNodeForScrollableArea(area).get(), color);
}

#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
void AsyncScrollingCoordinator::setHoveredAndPressedScrollbarParts(ScrollableArea& scrollableArea)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    ASSERT(page());
    auto stateNode = dynamicDowncast<ScrollingStateScrollingNode>(stateNodeForScrollableArea(scrollableArea));
    if (!stateNode)
        return;
    ScrollbarHoverState state;
    if (RefPtr scrollbar = scrollableArea.verticalScrollbar()) {
        state.hoveredPartInVerticalScrollbar = scrollbar->hoveredPart();
        state.pressedPartInVerticalScrollbar = scrollbar->pressedPart();
    }
    if (RefPtr scrollbar = scrollableArea.horizontalScrollbar()) {
        state.hoveredPartInHorizontalScrollbar = scrollbar->hoveredPart();
        state.pressedPartInHorizontalScrollbar = scrollbar->pressedPart();
    }
    stateNode->setScrollbarHoverState(WTF::move(state));
}
#else
void AsyncScrollingCoordinator::setMouseIsOverScrollbar(Scrollbar* scrollbar, bool isOverScrollbar)
{
    setMouseIsOverScrollbar(stateNodeForScrollableArea(protect(scrollbar->scrollableArea())).get(), scrollbar->orientation(), isOverScrollbar);
}
#endif

void AsyncScrollingCoordinator::setMouseIsOverContentArea(ScrollableArea& area, bool isOverContentArea)
{
    setMouseIsOverContentArea(stateNodeForScrollableArea(area).get(), isOverContentArea);
}

void AsyncScrollingCoordinator::setScrollbarEnabled(Scrollbar& scrollbar)
{
    setScrollbarEnabled(stateNodeForScrollableArea(protect(scrollbar.scrollableArea())).get(), scrollbar.orientation(), scrollbar.enabled());
}

void AsyncScrollingCoordinator::setMouseMovedInContentArea(ScrollableArea& scrollableArea)
{
    auto mousePosition = scrollableArea.lastKnownMousePositionInView();
    RefPtr horizontalScrollbar = scrollableArea.horizontalScrollbar();
    RefPtr verticalScrollbar = scrollableArea.verticalScrollbar();
    setMouseMovedInContentArea(stateNodeForScrollableArea(scrollableArea).get(), horizontalScrollbar ? horizontalScrollbar->convertFromContainingView(mousePosition) : IntPoint(), verticalScrollbar ? verticalScrollbar->convertFromContainingView(mousePosition) : IntPoint());
}

#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
void AsyncScrollingCoordinator::setScrollbarOpacity(ScrollableArea& scrollableArea)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    ASSERT(page());
    auto stateNode = dynamicDowncast<ScrollingStateScrollingNode>(stateNodeForScrollableArea(scrollableArea));
    if (!stateNode)
        return;
    stateNode->setScrollbarOpacity(scrollableArea.scrollbarOpacity());
}
#endif

void AsyncScrollingCoordinator::setScrollbarWidth(ScrollableArea& area, ScrollbarWidth width)
{
    setScrollbarWidth(stateNodeForScrollableArea(area).get(), width);
}

void AsyncScrollingCoordinator::synchronizeStateFromScrollingTree()
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    applyPendingScrollUpdates();

    protect(m_scrollingTree)->traverseScrollingTree([&](ScrollingNodeID nodeID, ScrollingNodeType, std::optional<FloatPoint> scrollPosition, std::optional<FloatPoint> layoutViewportOrigin, bool scrolledSinceLastCommit) {
        if (scrollPosition && scrolledSinceLastCommit) {
            LOG_WITH_STREAM(Scrolling, stream << "AsyncScrollingCoordinator::synchronizeStateFromScrollingTree - node " << nodeID << " scroll position " << scrollPosition);
            updateScrollPositionAfterAsyncScroll(nodeID, *scrollPosition, layoutViewportOrigin, ScrollingLayerPositionAction::Set, ScrollType::User, ViewportRectStability::Stable, std::nullopt);
        }
    });
}

void AsyncScrollingCoordinator::applyPendingScrollUpdates()
{
    if (!m_scrollingTree)
        return;

    auto scrollUpdates = protect(m_scrollingTree)->takePendingScrollUpdates();
    for (auto& update : scrollUpdates) {
        LOG_WITH_STREAM(Scrolling, stream << "AsyncScrollingCoordinator::applyPendingScrollUpdates - node " << update.nodeID << " scroll position " << update.scrollPosition);
        applyScrollPositionUpdate(WTF::move(update), ScrollType::User, ViewportRectStability::Stable);
    }
}

LocalFrameView* AsyncScrollingCoordinator::frameViewForScrollingNode(LocalFrame& rootFrame, std::optional<ScrollingNodeID> scrollingNodeID) const
{
    ASSERT(rootFrame.isRootFrame());
    CheckedPtr scrollingStateTree = existingScrollingStateTreeForRootFrameID(rootFrame.frameID());
    if (!scrollingStateTree || !scrollingStateTree->rootStateNode())
        return nullptr;
    if (scrollingNodeID == scrollingStateTree->rootStateNode()->scrollingNodeID()) {
        if (rootFrame.view() && rootFrame.view()->scrollingNodeID() == scrollingNodeID)
            return rootFrame.view();
    }

    RefPtr stateNode = stateNodeForNodeID(scrollingNodeID);
    if (!stateNode)
        return nullptr;

    // Find the enclosing frame scrolling node.
    RefPtr parentNode = stateNode;
    while (parentNode && !parentNode->isFrameScrollingNode())
        parentNode = parentNode->parent();
    
    if (!parentNode)
        return nullptr;

    // Walk the frame tree to find the matching LocalFrameView. This is not ideal, but avoids back pointers to LocalFrameViews
    // from ScrollingTreeStateNodes.
    for (Frame* frame = &rootFrame; frame; frame = frame->tree().traverseNext()) {
        auto* localFrame = dynamicDowncast<LocalFrame>(frame);
        if (!localFrame)
            continue;
        if (SUPPRESS_UNCOUNTED_LOCAL auto* view = localFrame->view()) {
            if (view->scrollingNodeID() == parentNode->scrollingNodeID())
                return view;
        }
    }

    return nullptr;
}

LocalFrameView* AsyncScrollingCoordinator::frameViewForScrollingNode(std::optional<ScrollingNodeID> scrollingNodeID) const
{
    if (!page())
        return nullptr;
    for (const auto& rootFrame : page()->rootFrames()) {
        if (auto* frameView = frameViewForScrollingNode(protect(rootFrame.get()), scrollingNodeID))
            return frameView;
    }
    return nullptr;
}

void AsyncScrollingCoordinator::applyScrollPositionUpdate(ScrollUpdate update, ScrollType scrollType, ViewportRectStability viewportStability)
{
    LOG_WITH_STREAM(Scrolling, stream << "AsyncScrollingCoordinator::applyScrollPositionUpdate " << update);

    if (std::holds_alternative<ScrollUpdateData>(update.data)) {
        auto& data = std::get<ScrollUpdateData>(update.data);
        switch (data.updateType) {
        case ScrollUpdateType::PositionUpdate:
            updateScrollPositionAfterAsyncScroll(update.nodeID, update.scrollPosition, data.layoutViewportOriginOrOverrideRect, data.updateLayerPositionAction, scrollType, viewportStability, data.scrollRelativity);
            break;

        case ScrollUpdateType::AnimatedScrollWillStart:
            animatedScrollWillStartForNode(update.nodeID);
            break;

        case ScrollUpdateType::AnimatedScrollDidEnd:
            animatedScrollDidEndForNode(update.nodeID);
            break;

        case ScrollUpdateType::WheelEventScrollWillStart:
            wheelEventScrollWillStartForNode(update.nodeID);
            break;

        case ScrollUpdateType::WheelEventScrollDidEnd:
            wheelEventScrollDidEndForNode(update.nodeID);
            break;
        }
    }

    if (update.shouldFireScrollEnd == ShouldFireScrollEnd::Yes)
        notifyScrollableAreasForScrollEnd(update.nodeID);
}

void AsyncScrollingCoordinator::animatedScrollWillStartForNode(ScrollingNodeID scrollingNodeID)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());

    RefPtr page = this->page();
    if (!page)
        return;

    RefPtr frameView = frameViewForScrollingNode(scrollingNodeID);
    if (!frameView)
        return;

    m_hysterisisActivity.start();
    page->willBeginScrolling();
}

void AsyncScrollingCoordinator::animatedScrollDidEndForNode(ScrollingNodeID scrollingNodeID)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());

    if (!page())
        return;

    RefPtr frameView = frameViewForScrollingNode(scrollingNodeID);
    if (!frameView)
        return;

    LOG_WITH_STREAM(Scrolling, stream << "AsyncScrollingCoordinator::animatedScrollDidEndForNode node " << scrollingNodeID);

    m_hysterisisActivity.stop();

    if (scrollingNodeID == frameView->scrollingNodeID())
        frameView->setScrollAnimationStatus(ScrollAnimationStatus::NotAnimating);
    else if (CheckedPtr scrollableArea = frameView->scrollableAreaForScrollingNodeID(scrollingNodeID)) {
        scrollableArea->setScrollAnimationStatus(ScrollAnimationStatus::NotAnimating);
        scrollableArea->animatedScrollDidEnd();
    }

    notifyScrollableAreasForScrollEnd(scrollingNodeID);
}

void AsyncScrollingCoordinator::wheelEventScrollWillStartForNode(ScrollingNodeID scrollingNodeID)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());

    RefPtr page = this->page();
    if (!page)
        return;

    RefPtr frameView = frameViewForScrollingNode(scrollingNodeID);
    if (!frameView)
        return;

    m_hysterisisActivity.start();
    page->willBeginScrolling();
}

void AsyncScrollingCoordinator::wheelEventScrollDidEndForNode(ScrollingNodeID scrollingNodeID)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    RefPtr page = this->page();
    if (!page)
        return;

    RefPtr frameView = frameViewForScrollingNode(scrollingNodeID);
    if (!frameView)
        return;

    m_hysterisisActivity.stop();
    notifyScrollableAreasForScrollEnd(scrollingNodeID);
}

void AsyncScrollingCoordinator::scrollDidEnd(LocalFrameView& frameView, ScrollingNodeID scrollingNodeID)
{
    CheckedPtr<ScrollableArea> scrollableArea = scrollingNodeID == frameView.scrollingNodeID() ? &frameView : frameView.scrollableAreaForScrollingNodeID(scrollingNodeID);
    if (scrollableArea)
        scrollableArea->scrollDidEnd();
}

void AsyncScrollingCoordinator::updateScrollPositionAfterAsyncScroll(ScrollingNodeID nodeID, FloatPoint scrollPosition, const std::optional<LayoutViewportOriginOrOverrideRect>& layoutViewportOriginOrOverrideRect, ScrollingLayerPositionAction updateLayerPositionAction, ScrollType scrollType, ViewportRectStability viewportRectStability, std::optional<ScrollRelativity> relativity)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());

    RefPtr page = this->page();
    if (!page)
        return;

    RefPtr frameView = frameViewForScrollingNode(nodeID);
    if (!frameView)
        return;

    LOG_WITH_STREAM(Scrolling, stream << "AsyncScrollingCoordinator::updateScrollPositionAfterAsyncScroll node " << nodeID << " " << scrollType << " scrollPosition " << scrollPosition << " action " << updateLayerPositionAction);

    if (!frameView->frame().isMainFrame()) {
        if (updateLayerPositionAction == ScrollingLayerPositionAction::Set)
            page->editorClient().subFrameScrollPositionChanged();
    }

    if (nodeID == frameView->scrollingNodeID()) {
        if (relativity)
            frameView->setCurrentScrollRelativity(*relativity);
        reconcileScrollingState(*frameView, scrollPosition, layoutViewportOriginOrOverrideRect, scrollType, viewportRectStability, updateLayerPositionAction);
        return;
    }

    // Overflow-scroll area.
    if (CheckedPtr scrollableArea = frameView->scrollableAreaForScrollingNodeID(nodeID)) {
        {
            auto scope = ScrollTypeScope(*scrollableArea, scrollType);
            if (relativity)
                scrollableArea->setCurrentScrollRelativity(*relativity);
            scrollableArea->notifyScrollPositionChanged(roundedIntPoint(scrollPosition));
        }

        if (updateLayerPositionAction == ScrollingLayerPositionAction::Set)
            page->editorClient().overflowScrollPositionChanged();
    }
}

void AsyncScrollingCoordinator::reconcileScrollingState(LocalFrameView& frameView, const FloatPoint& scrollPosition, const std::optional<LayoutViewportOriginOrOverrideRect>& layoutViewportOriginOrOverrideRect, ScrollType scrollType, ViewportRectStability viewportRectStability, ScrollingLayerPositionAction scrollingLayerPositionAction)
{
    LOG_WITH_STREAM(Scrolling, stream << getCurrentProcessID() << " AsyncScrollingCoordinator " << this << " reconcileScrollingState scrollPosition " << scrollPosition << " type " << scrollType << " stability " << viewportRectStability << " " << scrollingLayerPositionAction);

    auto scrollTypeScope = ScrollTypeScope(frameView, scrollType);

    std::optional<FloatRect> layoutViewportRect;

    if (layoutViewportOriginOrOverrideRect) {
        WTF::switchOn(*layoutViewportOriginOrOverrideRect,
            [&frameView](FloatPoint origin) {
                frameView.setBaseLayoutViewportOrigin(LayoutPoint(origin), LocalFrameView::TriggerLayoutOrNot::No);
            }, [&layoutViewportRect](FloatRect overrideRect) {
                layoutViewportRect = overrideRect;
            }
        );
    }

    frameView.setScrollClamping(ScrollClamping::Unclamped);
    frameView.notifyScrollPositionChanged(roundedIntPoint(scrollPosition));
    frameView.setScrollClamping(ScrollClamping::Clamped);

    scrollTypeScope.restore();

    if (scrollType == ScrollType::User && scrollingLayerPositionAction != ScrollingLayerPositionAction::Set) {
        auto scrollingNodeID = frameView.scrollingNodeID();
        if (viewportRectStability == ViewportRectStability::Stable)
            reconcileViewportConstrainedLayerPositions(scrollingNodeID, frameView.rectForFixedPositionLayout(), scrollingLayerPositionAction);
        else if (layoutViewportRect)
            reconcileViewportConstrainedLayerPositions(scrollingNodeID, LayoutRect(layoutViewportRect.value()), scrollingLayerPositionAction);
    }

    if (!scrolledContentsLayerForFrameView(frameView))
        return;

    RefPtr counterScrollingLayer = counterScrollingLayerForFrameView(frameView);
    RefPtr insetClipLayer = insetClipLayerForFrameView(frameView);
    RefPtr contentShadowLayer = contentShadowLayerForFrameView(frameView);
    RefPtr rootContentsLayer = rootContentsLayerForFrameView(frameView);
    RefPtr headerLayer = headerLayerForFrameView(frameView);
    RefPtr footerLayer = footerLayerForFrameView(frameView);

    ASSERT(frameView.scrollPosition() == roundedIntPoint(scrollPosition));
    LayoutPoint scrollPositionForFixed = frameView.scrollPositionForFixedPosition();
    auto obscuredContentInsets = frameView.obscuredContentInsets();

    FloatRect insetClipLayerRect;
    if (insetClipLayer) {
        insetClipLayerRect = LocalFrameView::insetClipLayerRect(scrollPosition, frameView.totalContentsSize(), obscuredContentInsets, frameView.sizeForVisibleContent());
        insetClipLayerRect.move(frameView.insetForLeftScrollbarSpace(), 0);
        insetClipLayer->setSize(insetClipLayerRect.size());
    }
    FloatPoint positionForContentsLayer = frameView.positionForRootContentLayer();
    
    FloatPoint positionForHeaderLayer = FloatPoint(scrollPositionForFixed.x(), LocalFrameView::yPositionForHeaderLayer(scrollPosition, obscuredContentInsets.top()));
    FloatPoint positionForFooterLayer = FloatPoint(scrollPositionForFixed.x(),
        LocalFrameView::yPositionForFooterLayer(scrollPosition, obscuredContentInsets.top(), frameView.totalContentsSize().height(), frameView.footerHeight()));

    if (scrollType == ScrollType::Programmatic || scrollingLayerPositionAction == ScrollingLayerPositionAction::Set) {
        reconcileScrollPosition(frameView, ScrollingLayerPositionAction::Set);

        if (counterScrollingLayer)
            counterScrollingLayer->setPosition(scrollPositionForFixed);
        if (insetClipLayer)
            insetClipLayer->setPosition(insetClipLayerRect.location());
        if (contentShadowLayer)
            contentShadowLayer->setPosition(positionForContentsLayer);
        if (rootContentsLayer)
            rootContentsLayer->setPosition(positionForContentsLayer);
        if (headerLayer)
            headerLayer->setPosition(positionForHeaderLayer);
        if (footerLayer)
            footerLayer->setPosition(positionForFooterLayer);
    } else {
        reconcileScrollPosition(frameView, ScrollingLayerPositionAction::Sync);

        if (counterScrollingLayer)
            counterScrollingLayer->syncPosition(scrollPositionForFixed);
        if (insetClipLayer)
            insetClipLayer->syncPosition(insetClipLayerRect.location());
        if (contentShadowLayer)
            contentShadowLayer->syncPosition(positionForContentsLayer);
        if (rootContentsLayer)
            rootContentsLayer->syncPosition(positionForContentsLayer);
        if (headerLayer)
            headerLayer->syncPosition(positionForHeaderLayer);
        if (footerLayer)
            footerLayer->syncPosition(positionForFooterLayer);
    }
}

void AsyncScrollingCoordinator::scrollableAreaScrollbarLayerDidChange(ScrollableArea& scrollableArea, ScrollbarOrientation orientation)
{
    RefPtr layer = orientation == ScrollbarOrientation::Vertical ? scrollableArea.layerForVerticalScrollbar() : scrollableArea.layerForHorizontalScrollbar();
    scrollbarLayerDidChange(stateNodeForScrollableArea(scrollableArea).get(), orientation, layer.get(), scrollableArea.shouldPlaceVerticalScrollbarOnLeft() ? UserInterfaceLayoutDirection::RTL : UserInterfaceLayoutDirection::LTR);

    if (orientation == ScrollbarOrientation::Vertical)
        scrollableArea.verticalScrollbarLayerDidChange();
    else
        scrollableArea.horizontalScrollbarLayerDidChange();
}

Vector<ScrollingNodeID> AsyncScrollingCoordinator::childrenOfNode(ScrollingNodeID nodeID) const
{
    auto scrollingNode = stateNodeForNodeID(nodeID);
    if (!scrollingNode)
        return { };

    return scrollingNode->children().map([](auto& child) {
        return child->scrollingNodeID();
    });
}

void AsyncScrollingCoordinator::ensureRootStateNodeForFrameView(LocalFrameView& frameView)
{
    ASSERT(frameView.scrollingNodeID());
    if (stateNodeForScrollableArea(frameView))
        return;

    // For non-main frames, it is only possible to arrive in this function from
    // RenderLayerCompositor::updateBacking where the node has already been created.
    ASSERT(frameView.frame().isMainFrame());
    insertNode(frameView.frame().rootFrame().frameID(), ScrollingNodeType::MainFrame, *frameView.scrollingNodeID(), { }, 0);
}

void AsyncScrollingCoordinator::setNodeLayers(ScrollingNodeID nodeID, const NodeLayers& nodeLayers)
{
    RefPtr node = stateNodeForNodeID(nodeID);
    ASSERT(node);
    if (!node)
        return;

    node->setLayer(nodeLayers.layer.get());

    if (RefPtr scrollingNode = dynamicDowncast<ScrollingStateScrollingNode>(*node)) {
        scrollingNode->setScrollContainerLayer(nodeLayers.scrollContainerLayer.get());
        scrollingNode->setScrolledContentsLayer(nodeLayers.scrolledContentsLayer.get());
        scrollingNode->setHorizontalScrollbarLayer(nodeLayers.horizontalScrollbarLayer.get());
        scrollingNode->setVerticalScrollbarLayer(nodeLayers.verticalScrollbarLayer.get());
        if (RefPtr frameView = frameViewForScrollingNode(nodeID)) {
            if (CheckedPtr scrollableArea = frameView->scrollableAreaForScrollingNodeID(nodeID))
                scrollingNode->setScrollbarLayoutDirection(scrollableArea->shouldPlaceVerticalScrollbarOnLeft() ? UserInterfaceLayoutDirection::RTL : UserInterfaceLayoutDirection::LTR);
        }

        if (RefPtr frameScrollingNode = dynamicDowncast<ScrollingStateFrameScrollingNode>(*scrollingNode)) {
            frameScrollingNode->setInsetClipLayer(nodeLayers.insetClipLayer.get());
            frameScrollingNode->setCounterScrollingLayer(nodeLayers.counterScrollingLayer.get());
            frameScrollingNode->setRootContentsLayer(nodeLayers.rootContentsLayer.get());
        }
    }

    if (RefPtr stickyNode = dynamicDowncast<ScrollingStateStickyNode>(*node))
        stickyNode->setViewportAnchorLayer(nodeLayers.viewportAnchorLayer.get());
}

void AsyncScrollingCoordinator::setFrameScrollingNodeState(ScrollingNodeID nodeID, const LocalFrameView& frameView)
{
    RefPtr stateNode = stateNodeForNodeID(nodeID);
    ASSERT(stateNode);
    RefPtr frameScrollingNode = dynamicDowncast<ScrollingStateFrameScrollingNode>(stateNode);
    if (!frameScrollingNode)
        return;

    auto& settings = page()->mainFrame().settings();

    frameScrollingNode->setFrameScaleFactor(protect(frameView.frame())->frameScaleFactor());
    frameScrollingNode->setHeaderHeight(frameView.headerHeight());
    frameScrollingNode->setFooterHeight(frameView.footerHeight());
    frameScrollingNode->setObscuredContentInsets(frameView.obscuredContentInsets());
    frameScrollingNode->setInsetForLeftScrollbarSpace(frameView.insetForLeftScrollbarSpace());
    frameScrollingNode->setLayoutViewport(frameView.layoutViewportRect());
    frameScrollingNode->setAsyncFrameOrOverflowScrollingEnabled(settings.asyncFrameScrollingEnabled() || settings.asyncOverflowScrollingEnabled());
    frameScrollingNode->setScrollingPerformanceTestingEnabled(settings.scrollingPerformanceTestingEnabled());
    frameScrollingNode->setOverlayScrollbarsEnabled(ScrollbarTheme::theme().usesOverlayScrollbars());
    frameScrollingNode->setScrollbarWidth(frameView.scrollbarWidthStyle());
    frameScrollingNode->setScrollbarColor(frameView.scrollbarColorStyle());
    frameScrollingNode->setWheelEventGesturesBecomeNonBlocking(settings.wheelEventGesturesBecomeNonBlocking());

    frameScrollingNode->setSizeForVisibleContent(frameView.sizeForVisibleContent());
    frameScrollingNode->setMinLayoutViewportOrigin(frameView.minStableLayoutViewportOrigin());
    frameScrollingNode->setMaxLayoutViewportOrigin(frameView.maxStableLayoutViewportOrigin());

    if (auto visualOverrideRect = frameView.visualViewportOverrideRect()) {
        frameScrollingNode->setOverrideVisualViewportSize(FloatSize(visualOverrideRect.value().size()));
    } else {
        frameScrollingNode->setOverrideVisualViewportSize(std::nullopt);
    }

    auto visualViewportIsSmallerThanLayoutViewport = [](const LocalFrameView& frameView) {
        auto layoutViewport = frameView.layoutViewportRect();
        auto visualViewport = frameView.visualViewportRect();
        return visualViewport.width() < layoutViewport.width() || visualViewport.height() < layoutViewport.height();
    };
    frameScrollingNode->setVisualViewportIsSmallerThanLayoutViewport(visualViewportIsSmallerThanLayoutViewport(frameView));
    
    frameScrollingNode->setScrollBehaviorForFixedElements(frameView.scrollBehaviorForFixedElements());
}

void AsyncScrollingCoordinator::setScrollingNodeScrollableAreaGeometry(std::optional<ScrollingNodeID> nodeID, ScrollableArea& scrollableArea)
{
    auto scrollingNode = dynamicDowncast<ScrollingStateScrollingNode>(stateNodeForNodeID(nodeID));
    if (!scrollingNode)
        return;

    RefPtr verticalScrollbar = scrollableArea.verticalScrollbar();
    RefPtr horizontalScrollbar = scrollableArea.horizontalScrollbar();
    scrollingNode->setScrollerImpsFromScrollbars(verticalScrollbar, horizontalScrollbar);
    if (horizontalScrollbar)
        scrollingNode->setScrollbarEnabledState(ScrollbarOrientation::Horizontal, horizontalScrollbar->enabled());
    if (verticalScrollbar)
        scrollingNode->setScrollbarEnabledState(ScrollbarOrientation::Vertical, verticalScrollbar->enabled());
    scrollingNode->setScrollbarWidth(scrollableArea.scrollbarWidthStyle());
    scrollingNode->setScrollbarColor(scrollableArea.scrollbarColorStyle());

    scrollingNode->setScrollOrigin(scrollableArea.scrollOrigin());
    scrollingNode->setScrollPosition(scrollableArea.scrollPosition());
    scrollingNode->setTotalContentsSize(scrollableArea.totalContentsSize());
    scrollingNode->setReachableContentsSize(scrollableArea.reachableTotalContentsSize());
    scrollingNode->setScrollableAreaSize(scrollableArea.visibleSize());

    scrollingNode->setUseDarkAppearanceForScrollbars(scrollableArea.useDarkAppearanceForScrollbars());
#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
    scrollingNode->setScrollbarOpacity(scrollableArea.scrollbarOpacity());
#endif

    ScrollableAreaParameters scrollParameters;
    scrollParameters.horizontalScrollElasticity = scrollableArea.horizontalOverscrollBehavior() == OverscrollBehavior::None ? ScrollElasticity::None : scrollableArea.horizontalScrollElasticity();
    scrollParameters.verticalScrollElasticity = scrollableArea.verticalOverscrollBehavior() == OverscrollBehavior::None ? ScrollElasticity::None : scrollableArea.verticalScrollElasticity();
    scrollParameters.allowsHorizontalScrolling = scrollableArea.allowsHorizontalScrolling();
    scrollParameters.allowsVerticalScrolling = scrollableArea.allowsVerticalScrolling();
    scrollParameters.horizontalOverscrollBehavior = scrollableArea.horizontalOverscrollBehavior();
    scrollParameters.verticalOverscrollBehavior = scrollableArea.verticalOverscrollBehavior();
    scrollParameters.horizontalScrollbarMode = scrollableArea.horizontalScrollbarMode();
    scrollParameters.verticalScrollbarMode = scrollableArea.verticalScrollbarMode();
    scrollParameters.horizontalNativeScrollbarVisibility = scrollableArea.horizontalNativeScrollbarVisibility();
    scrollParameters.verticalNativeScrollbarVisibility = scrollableArea.verticalNativeScrollbarVisibility();
    scrollParameters.scrollbarWidthStyle = scrollableArea.scrollbarWidthStyle();
    scrollParameters.scrollbarColorStyle = scrollableArea.scrollbarColorStyle();

    scrollingNode->setScrollableAreaParameters(scrollParameters);

    scrollableArea.updateSnapOffsets();
    setStateScrollingNodeSnapOffsetsAsFloat(*scrollingNode, scrollableArea.snapOffsetsInfo(), page()->deviceScaleFactor());
    scrollingNode->setCurrentHorizontalSnapPointIndex(scrollableArea.currentHorizontalSnapPointIndex());
    scrollingNode->setCurrentVerticalSnapPointIndex(scrollableArea.currentVerticalSnapPointIndex());
}

void AsyncScrollingCoordinator::setViewportConstraintedNodeConstraints(ScrollingNodeID nodeID, const ViewportConstraints& constraints)
{
    RefPtr node = stateNodeForNodeID(nodeID);
    if (!node)
        return;

    switch (constraints.constraintType()) {
    case ViewportConstraints::FixedPositionConstraint: {
        if (RefPtr fixedNode = dynamicDowncast<ScrollingStateFixedNode>(node))
            fixedNode->updateConstraints(downcast<FixedPositionViewportConstraints>(constraints));
        break;
    }
    case ViewportConstraints::StickyPositionConstraint: {
        if (RefPtr stickyNode = dynamicDowncast<ScrollingStateStickyNode>(node))
            stickyNode->updateConstraints(downcast<StickyPositionViewportConstraints>(constraints));
        break;
    }
    }
}

void AsyncScrollingCoordinator::setRelatedOverflowScrollingNodes(ScrollingNodeID nodeID, Vector<ScrollingNodeID> relatedNodes)
{
    RefPtr node = stateNodeForNodeID(nodeID);
    if (!node)
        return;

    if (RefPtr positionedNode = dynamicDowncast<ScrollingStatePositionedNode>(*node))
        positionedNode->setRelatedOverflowScrollingNodes(WTF::move(relatedNodes));
    else if (RefPtr overflowScrollProxyNode = dynamicDowncast<ScrollingStateOverflowScrollProxyNode>(*node)) {
        if (!relatedNodes.isEmpty())
            overflowScrollProxyNode->setOverflowScrollingNode(relatedNodes[0]);
        else
            overflowScrollProxyNode->setOverflowScrollingNode(std::nullopt);
    } else
        ASSERT_NOT_REACHED();
}

std::optional<ScrollingNodeID> AsyncScrollingCoordinator::scrollableContainerNodeID(const RenderObject& renderer) const
{
    if (auto overflowScrollingNodeID = protect(protect(renderer.view())->compositor())->asyncScrollableContainerNodeID(renderer))
        return overflowScrollingNodeID;

    // If we're in a scrollable frame, return that.
    RefPtr frameView = renderer.frame().view();
    if (!frameView)
        return std::nullopt;

    if (auto scrollingNodeID = frameView->scrollingNodeID())
        return scrollingNodeID;

    // Otherwise, look for a scrollable element in the containing frame.
    if (RefPtr ownerElement = renderer.document().ownerElement()) {
        if (CheckedPtr frameRenderer = ownerElement->renderer())
            return scrollableContainerNodeID(*frameRenderer);
    }

    return std::nullopt;
}

String AsyncScrollingCoordinator::scrollingStateTreeAsText(OptionSet<ScrollingStateTreeAsTextBehavior> behavior) const
{
    StringBuilder stateTree;
    m_scrollingStateTrees.forEach([&](auto& key, auto& tree) {
        if (tree->rootStateNode()) {
            if (m_eventTrackingRegionsDirty)
                tree->rootStateNode()->setEventTrackingRegions(absoluteEventTrackingRegions());
            if (m_scrollingStateTrees.size() > 1)
                stateTree.append(makeString("Tree-for-root-frameID: "_s, key.toUInt64()));
            stateTree.append(tree->scrollingStateTreeAsText(behavior));
        }
    });

    return stateTree.toString();
}

String AsyncScrollingCoordinator::scrollingTreeAsText(OptionSet<ScrollingStateTreeAsTextBehavior> behavior) const
{
    if (!m_scrollingTree)
        return emptyString();

    return protect(m_scrollingTree)->scrollingTreeAsText(behavior);
}

void AsyncScrollingCoordinator::setActiveScrollSnapIndices(LocalFrameView& frameView, ScrollingNodeID scrollingNodeID, std::optional<unsigned> horizontalIndex, std::optional<unsigned> verticalIndex)
{
    if (CheckedPtr scrollableArea = frameView.scrollableAreaForScrollingNodeID(scrollingNodeID)) {
        scrollableArea->setCurrentHorizontalSnapPointIndex(horizontalIndex);
        scrollableArea->setCurrentVerticalSnapPointIndex(verticalIndex);
    }
}

void AsyncScrollingCoordinator::reportExposedUnfilledArea(MonotonicTime timestamp, unsigned unfilledArea)
{
    if (RefPtr page = this->page(); page && page->performanceLoggingClient())
        page->performanceLoggingClient()->logScrollingEvent(PerformanceLoggingClient::ScrollingEvent::ExposedTilelessArea, timestamp, unfilledArea);
}

void AsyncScrollingCoordinator::reportSynchronousScrollingReasonsChanged(MonotonicTime timestamp, OptionSet<SynchronousScrollingReason> reasons)
{
    if (RefPtr page = this->page(); page && page->performanceLoggingClient())
        page->performanceLoggingClient()->logScrollingEvent(PerformanceLoggingClient::ScrollingEvent::SwitchedScrollingMode, timestamp, reasons.toRaw());
}

std::unique_ptr<ScrollingStateTree> AsyncScrollingCoordinator::commitTreeStateForRootFrameID(FrameIdentifier rootFrameID, LayerRepresentation::Type type)
{
    CheckedRef scrollingStateTree = ensureScrollingStateTreeForRootFrameID(rootFrameID);
    return scrollingStateTree->commit(type);
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
