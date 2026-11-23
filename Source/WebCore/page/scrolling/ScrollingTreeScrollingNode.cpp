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

#include "config.h"
#include "ScrollingTreeScrollingNode.h"

#if ENABLE(ASYNC_SCROLLING)

#include "Logging.h"
#if ENABLE(SCROLLING_THREAD)
#include "ScrollingStateFrameScrollingNode.h"
#endif
#include "ScrollingEffectsController.h"
#include "ScrollingStateScrollingNode.h"
#include "ScrollingStateTree.h"
#include "ScrollingTree.h"
#include "ScrollingTreeScrollingNodeDelegate.h"
#include <wtf/Scope.h>
#include <wtf/SetForScope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>
#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingTreeScrollingNode);

ScrollingTreeScrollingNode::ScrollingTreeScrollingNode(ScrollingTree& scrollingTree, ScrollingNodeType nodeType, ScrollingNodeID nodeID)
    : ScrollingTreeNode(scrollingTree, nodeType, nodeID)
{
}

ScrollingTreeScrollingNode::~ScrollingTreeScrollingNode() = default;

bool ScrollingTreeScrollingNode::commitStateBeforeChildren(const ScrollingStateNode& stateNode)
{
    auto* scrollingStateNode = dynamicDowncast<ScrollingStateScrollingNode>(stateNode);
    if (!scrollingStateNode)
        return false;

    commitScrollingNodeState(*scrollingStateNode);
    return true;
}

bool ScrollingTreeScrollingNode::commitStateAfterChildren(const ScrollingStateNode& stateNode)
{
    auto* scrollingStateNode = dynamicDowncast<ScrollingStateScrollingNode>(stateNode);
    if (!scrollingStateNode)
        return false;

    commitScrollingNodeStateAfterChildren(*scrollingStateNode);
    return true;
}

void ScrollingTreeScrollingNode::commitNonTrivialStateProperties(const ScrollingStateScrollingNode& state)
{
    if (state.hasChangedProperty(ScrollingStateNode::Property::SnapOffsetsInfo))
        m_snapOffsetsInfo = state.snapOffsetsInfo();

    if (state.hasChangedProperty(ScrollingStateNode::Property::ScrollableAreaParams))
        m_scrollableAreaParameters = state.scrollableAreaParameters();

    if (state.hasChangedProperty(ScrollingStateNode::Property::ScrollContainerLayer))
        m_scrollContainerLayer = state.scrollContainerLayer();

    if (state.hasChangedProperty(ScrollingStateNode::Property::ScrolledContentsLayer))
        m_scrolledContentsLayer = state.scrolledContentsLayer();
}

void ScrollingTreeScrollingNode::handleRequestedScrollPositions(const ScrollingStateScrollingNode& state)
{
    handleScrollPositionRequests(state.requestedScrollData());
}

WheelEventHandlingResult ScrollingTreeScrollingNode::handleWheelEvent(PlatformWheelEvent, EventTargeting)
{
    return WheelEventHandlingResult::unhandled();
}

bool ScrollingTreeScrollingNode::eventCanScrollContents(PlatformWheelEvent wheelEvent) const
{
#if PLATFORM(WPE) || PLATFORM(GTK)
    // In case of GTK and WPE the end of momentum scroll events always have a delta of 0.
    if (wheelEvent.isEndOfNonMomentumScroll())
        return true;
#endif

    return !wheelEvent.delta().isZero() && scrollingNodeEventCanScrollContents(wheelEvent.delta(), allowsHorizontalScrolling(), allowsVerticalScrolling(),
        currentScrollPosition(), minimumScrollPosition(), maximumScrollPosition());
}

#if HAVE(RUBBER_BANDING)
std::optional<RubberbandingState> ScrollingTreeScrollingNode::captureRubberbandingState() const
{
    if (m_delegate)
        return m_delegate->captureRubberbandingState();
    return std::nullopt;
}
#endif

Vector<PlatformLayerContainer, 2> ScrollingTreeScrollingNode::hitTestableScrollbarLayers() const
{
    if (m_delegate)
        return m_delegate->hitTestableScrollbarLayers();
    return { };
}

bool ScrollingTreeScrollingNode::startAnimatedScrollToPosition(FloatPoint destinationPosition, ScrollAnimationCurve curve)
{
    return m_delegate ? m_delegate->startAnimatedScrollToPosition(destinationPosition, curve) : false;
}

void ScrollingTreeScrollingNode::stopAnimatedScroll(EnumSet<AnimatedScrollType> scrollTypesToStop)
{
    if (m_delegate)
        m_delegate->stopAnimatedScroll(scrollTypesToStop);
}

void ScrollingTreeScrollingNode::stopSpringAnimation()
{
    if (m_delegate)
        m_delegate->stopSpringAnimation();
}

void ScrollingTreeScrollingNode::serviceScrollAnimation(MonotonicTime currentTime)
{
    if (m_delegate)
        m_delegate->serviceScrollAnimation(currentTime);
}

void ScrollingTreeScrollingNode::handleKeyboardScrollRequest(RequestedKeyboardScrollData scrollData)
{
    if (m_delegate)
        m_delegate->handleKeyboardScrollRequest(scrollData);
}

void ScrollingTreeScrollingNode::handleScrollPositionRequests(const ScrollRequestData& requestedScrollData)
{
    for (auto& request : requestedScrollData)
        handleScrollPositionRequest(request);
}

void ScrollingTreeScrollingNode::handleScrollPositionRequest(RequestedScrollData requestedScrollData)
{
    RefPtr tree = scrollingTree();
    Ref node = *this;
    auto shouldFireScrollEnd = ShouldFireScrollEnd::No;

    auto scopeExit = WTF::makeScopeExit([&] {
        if (tree)
            tree->didHandleScrollRequestForNode(node->scrollingNodeID(), requestedScrollData.requestType, node->currentScrollPosition(), shouldFireScrollEnd, requestedScrollData.identifier);
    });

#if HAVE(RUBBER_BANDING)
    LOG_WITH_STREAM(ScrollAnimations, stream << "ScrollingTreeScrollingNode::handleScrollPositionRequest nodeID=" << scrollingNodeID() << " requestType=" << static_cast<unsigned>(requestedScrollData.requestType) << " isRubberBanding=" << tree->isRubberBandInProgressForNode(scrollingNodeID()) << " restoredRubberbandingInProgress=" << restoredRubberbandingInProgress());

    if (restoredRubberbandingInProgress()) {
        LOG_WITH_STREAM(ScrollAnimations, stream << "ScrollingTreeScrollingNode::handleScrollPositionRequest - skipping because restored rubberbanding is in progress");
        return;
    }
#endif

    if (requestedScrollData.requestType != ScrollRequestType::ImplicitDeltaUpdate)
        stopAnimatedScroll(AnimatedScrollType::Programmatic);

    if (requestedScrollData.requestType == ScrollRequestType::CancelAnimatedScroll) {
        LOG_WITH_STREAM(Scrolling, stream << "ScrollingTreeScrollingNode " << scrollingNodeID() << " handleScrollPositionRequest() - cancel animated scroll");
        tree->removePendingScrollAnimationForNode(scrollingNodeID());
        return;
    }

    auto handledByScrollingTree = scrollingTree()->scrollingTreeNodeRequestsScroll(scrollingNodeID(), requestedScrollData);
    if (handledByScrollingTree != RequestsScrollHandling::Unhandled) {
        LOG_WITH_STREAM(Scrolling, stream << "ScrollingTreeScrollingNode " << scrollingNodeID() << " handleScrollPositionRequest() with data " << requestedScrollData << " handled for delegated scrolling");
        if (handledByScrollingTree == RequestsScrollHandling::Delayed)
            scopeExit.release(); // The didHandleScrollRequestForNode() happens in RemoteScrollingCoordinatorProxy::adjustMainFrameDelegatedScrollPosition().
        return;
    }

    LOG_WITH_STREAM(Scrolling, stream << "ScrollingTreeScrollingNode " << scrollingNodeID() << " handleScrollPositionRequest() with data " << requestedScrollData);

    auto destinationPosition = requestedScrollData.destinationPosition(currentScrollPosition());
    if (isAnimatedUpdate(requestedScrollData.requestType)) {
        // The animation can complete synchronously (e.g. UIScrollView may not animate). Respond first, because
        // the web process ignores scroll updates that arrive before the response to its latest request.
        scopeExit.release();
        if (tree)
            tree->didHandleScrollRequestForNode(scrollingNodeID(), requestedScrollData.requestType, currentScrollPosition(), shouldFireScrollEnd, requestedScrollData.identifier);
        startAnimatedScrollToPosition(destinationPosition, requestedScrollData.animationCurve);
        return;
    }

    m_scrollbarRevealBehaviorForNextScrollbarUpdate = requestedScrollData.scrollbarRevealBehavior;
    if (!isScrollSnapInProgress())
        shouldFireScrollEnd = ShouldFireScrollEnd::Yes;

    scrollTo(destinationPosition, requestedScrollData.scrollType, requestedScrollData.clamping);
}

FloatPoint ScrollingTreeScrollingNode::adjustedScrollPosition(FloatPoint scrollPosition, ScrollClamping clamping) const
{
    auto adjustedPosition = m_delegate ? m_delegate->adjustedScrollPosition(scrollPosition) : scrollPosition;
    if (clamping == ScrollClamping::Clamped)
        return clampScrollPosition(adjustedPosition);

    return adjustedPosition;
}

float ScrollingTreeScrollingNode::rubberbandHyperbolicCoefficientForTesting() const
{
    return m_delegate ? m_delegate->rubberbandHyperbolicCoefficientForTesting() : 0;
}

void ScrollingTreeScrollingNode::dumpProperties(TextStream& ts, OptionSet<ScrollingStateTreeAsTextBehavior> behavior) const
{
    ts << scrollingNodePropertiesText(behavior, ts.indent(), ts.formattingFlags(), ts.containerSizeLimit());
}

String ScrollingTreeScrollingNode::snapOffsetsPropertiesText(int indent, TextStreamFormattingFlags formattingFlags, unsigned containerSizeLimit) const
{
    TextStream ts(TextStream::LineMode::MultipleLine, formattingFlags, containerSizeLimit);
    ts.setIndent(indent);

    if (m_snapOffsetsInfo.horizontalSnapOffsets.size())
        ts.dumpProperty("horizontal snap offsets"_s, m_snapOffsetsInfo.horizontalSnapOffsets);

    if (m_snapOffsetsInfo.verticalSnapOffsets.size())
        ts.dumpProperty("vertical snap offsets"_s, m_snapOffsetsInfo.verticalSnapOffsets);

    return ts.release();
}

const FloatScrollSnapOffsetsInfo& ScrollingTreeScrollingNode::snapOffsetsInfo() const
{
    return m_snapOffsetsInfo;
}

PlatformWheelEvent ScrollingTreeScrollingNode::eventForPropagation(PlatformWheelEvent wheelEvent) const
{
    auto filteredDelta = wheelEvent.delta();
#if PLATFORM(MAC)
    auto biasedDelta = ScrollingEffectsController::wheelDeltaBiasingTowardsVertical(wheelEvent.delta());
#else
    auto biasedDelta = wheelEvent.delta();
#endif
    if (horizontalOverscrollBehaviorPreventsPropagation() || verticalOverscrollBehaviorPreventsPropagation()) {
        if(horizontalOverscrollBehaviorPreventsPropagation() || (verticalOverscrollBehaviorPreventsPropagation() && !biasedDelta.width()))
           filteredDelta.setWidth(0);
        if(verticalOverscrollBehaviorPreventsPropagation() || (horizontalOverscrollBehaviorPreventsPropagation() && !biasedDelta.height()))
           filteredDelta.setHeight(0);
        return wheelEvent.copyWithDeltaAndVelocity(filteredDelta, wheelEvent.scrollingVelocity());
    }
    return wheelEvent;
}

ScrollingPlatformLayer* ScrollingTreeScrollingNode::scrollContainerPlatformLayer() const
{
    return static_cast<ScrollingPlatformLayer*>(m_scrollContainerLayer);
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
