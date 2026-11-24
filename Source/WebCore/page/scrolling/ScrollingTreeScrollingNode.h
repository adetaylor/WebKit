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

#pragma once

#include <wtf/Platform.h>
#if ENABLE(ASYNC_SCROLLING)

#include <WebCore/IntRect.h>
#include <WebCore/RubberbandingState.h>
#include <WebCore/ScrollSnapOffsetsInfo.h>
#include <WebCore/ScrollableArea.h>
#include <WebCore/ScrollingPlatformLayer.h>
#include <WebCore/ScrollingTree.h>
#include <WebCore/ScrollingTreeNode.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class ScrollingTree;
class ScrollingStateScrollingNode;
class ScrollingTreeScrollingNodeDelegate;
struct WheelEventHandlingResult;

struct ScrollPropagationInfo {
    bool shouldBlockScrollPropagation { false };
    bool isHandled { false };
};

// For Swift, which cannot name std::optional<FloatRect>.
using OptionalFloatRect = std::optional<FloatRect>;

enum class AnimatedScrollType : uint8_t {
    User,
    Programmatic
};

class WEBCORE_EXPORT SWIFT_PRIVATE_FILEID("WebCore/ScrollingTreeScrollingNode.swift") ScrollingTreeScrollingNode : public ScrollingTreeNode {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(ScrollingTreeScrollingNode, WEBCORE_EXPORT);
    friend class ScrollingTreeScrollingNodeDelegate;
#if PLATFORM(MAC)
    friend class ScrollingTreeScrollingNodeDelegateMac;
#endif
#if ENABLE(SCROLLING_THREAD)
    friend class ThreadedScrollingTreeScrollingNodeDelegate;
#endif
    friend class ScrollingTree;
    friend class ThreadedScrollingTree;

public:
    virtual ~ScrollingTreeScrollingNode();

    SWIFT_UNSAFE bool commitStateBeforeChildren(const ScrollingStateNode&) override;
    SWIFT_UNSAFE bool commitStateAfterChildren(const ScrollingStateNode&) override;
    // What commitStateBeforeChildren() commits of a scrolling state node; its overrides cast the state node, since Swift
    // can cast it only through a call that retains the node and the result. The caller passes the node's
    // changedProperties().toRaw(): Swift reads the bits on a derived node, and tests them in an OptionSet, only through
    // calls, and retains both nodes around them.
    SWIFT_UNSAFE void commitScrollingNodeState(const ScrollingStateScrollingNode&, uint64_t changedProperties);
    NODELETE SWIFT_UNSAFE void didCompleteCommitForNode() final;

    virtual bool canHandleWheelEvent(PlatformWheelEvent, EventTargeting) const;
    // As minimumScrollPositionForSwift() does.
    bool canHandleWheelEventForSwift(PlatformWheelEvent wheelEvent, EventTargeting eventTargeting) const { return canHandleWheelEvent(wheelEvent, eventTargeting); }
    SWIFT_UNSAFE virtual WheelEventHandlingResult handleWheelEvent(PlatformWheelEvent, EventTargeting = EventTargeting::Propagate);
    virtual void handleWheelEventPhase(const PlatformWheelEventPhase) { }
    
    FloatPoint currentScrollPosition() const { return m_currentScrollPosition; }
    FloatPoint currentScrollOffset() const { return ScrollableArea::scrollOffsetFromPosition(m_currentScrollPosition, toFloatSize(m_scrollOrigin)); }
    FloatPoint clampedCurrentScrollOffset() const;
    FloatPoint lastCommittedScrollPosition() const { return m_lastCommittedScrollPosition; }
    FloatSize scrollDeltaSinceLastCommit() const { return m_currentScrollPosition - m_lastCommittedScrollPosition; }

    IntPoint scrollOrigin() const { return m_scrollOrigin; }

    RectEdges<bool> edgePinnedState() const;

    bool isUserScrollInProgress() const;
    void setUserScrollInProgress(bool);

    bool isScrollSnapInProgress() const;
    void setScrollSnapInProgress(bool);

#if HAVE(RUBBER_BANDING)
    SWIFT_UNSAFE std::optional<RubberbandingState> captureRubberbandingState() const;
    void setRestoredRubberbandingInProgress(bool inProgress) { m_restoredRubberbandingInProgress = inProgress; }
    bool restoredRubberbandingInProgress() const { return m_restoredRubberbandingInProgress; }
#endif

    SWIFT_UNSAFE virtual bool startAnimatedScrollToPosition(FloatPoint, ScrollAnimationCurve);
    SWIFT_UNSAFE virtual void stopAnimatedScroll(EnumSet<AnimatedScrollType>);
    SWIFT_UNSAFE void stopSpringAnimation();

    SWIFT_UNSAFE virtual void serviceScrollAnimation(MonotonicTime);

    // These are imperative; they adjust the scrolling layers.
    SWIFT_UNSAFE void scrollTo(FloatPoint, ScrollType = ScrollType::User, ScrollClamping = ScrollClamping::Clamped);
    SWIFT_UNSAFE void scrollBy(FloatSize, ScrollClamping = ScrollClamping::Clamped);

    SWIFT_UNSAFE void handleScrollPositionRequests(const ScrollRequestData&);

    SWIFT_UNSAFE void handleKeyboardScrollRequest(RequestedKeyboardScrollData);
    SWIFT_UNSAFE void requestKeyboardScroll(RequestedKeyboardScrollData);

    SWIFT_UNSAFE void wasScrolledByDelegatedScrolling(FloatPoint position, std::optional<FloatRect> overrideLayoutViewport = { }, ScrollingLayerPositionAction = ScrollingLayerPositionAction::Sync);
    
#if ENABLE(SCROLLING_THREAD)
    OptionSet<SynchronousScrollingReason> synchronousScrollingReasons() const { return m_synchronousScrollingReasons; }
    void addSynchronousScrollingReason(SynchronousScrollingReason reason) { m_synchronousScrollingReasons.add(reason); }
    void removeSynchronousScrollingReason(SynchronousScrollingReason reason) { m_synchronousScrollingReasons.remove(reason); }
    bool hasSynchronousScrollingReasons() const { return !m_synchronousScrollingReasons.isEmpty(); }
    bool hasNonRepaintSynchronousScrollingReasons() const { return !(m_synchronousScrollingReasons - SynchronousScrollingReason::HasSlowRepaintObjects).isEmpty(); }
#endif

    FloatSize scrollableAreaSize() const { return m_scrollableAreaSize; }
    FloatSize totalContentsSize() const { return m_totalContentsSize; }

    NativeScrollbarVisibility horizontalNativeScrollbarVisibility() const { return m_scrollableAreaParameters.horizontalNativeScrollbarVisibility; }
    NativeScrollbarVisibility verticalNativeScrollbarVisibility() const { return m_scrollableAreaParameters.verticalNativeScrollbarVisibility; }
    bool canHaveHorizontalScrollbar() const { return m_scrollableAreaParameters.horizontalScrollbarMode != ScrollbarMode::AlwaysOff; }
    bool canHaveVerticalScrollbar() const { return m_scrollableAreaParameters.verticalScrollbarMode != ScrollbarMode::AlwaysOff; }
    bool canHaveScrollbars() const { return m_scrollableAreaParameters.horizontalScrollbarMode != ScrollbarMode::AlwaysOff || m_scrollableAreaParameters.verticalScrollbarMode != ScrollbarMode::AlwaysOff; }
    bool allowsHorizontalScrolling() const;
    bool allowsVerticalScrolling() const;

    NODELETE const FloatScrollSnapOffsetsInfo& snapOffsetsInfo() const LIFETIME_BOUND;
    NODELETE std::optional<unsigned> currentHorizontalSnapPointIndex() const;
    NODELETE std::optional<unsigned> currentVerticalSnapPointIndex() const;
    NODELETE void setCurrentHorizontalSnapPointIndex(std::optional<unsigned>);
    NODELETE void setCurrentVerticalSnapPointIndex(std::optional<unsigned>);

    bool eventCanScrollContents(PlatformWheelEvent) const;
    
    bool scrolledSinceLastCommit() const { return m_scrolledSinceLastCommit; }

    const LayerRepresentation& scrollContainerLayer() const LIFETIME_BOUND { return m_scrollContainerLayer; }
    const LayerRepresentation& scrolledContentsLayer() const LIFETIME_BOUND { return m_scrolledContentsLayer; }
    // By value, for Swift, which imports neither the references above nor LayerRepresentation's explicit conversion.
    // Out of line: Swift compiles an inline body again under ARC, and ThinLTO then miscompiles it into an over-release.
    ScrollingPlatformLayer* scrollContainerPlatformLayer() const;
    
    OverscrollBehavior horizontalOverscrollBehavior() const { return m_scrollableAreaParameters.horizontalOverscrollBehavior; }
    OverscrollBehavior verticalOverscrollBehavior() const { return m_scrollableAreaParameters.verticalOverscrollBehavior; }

    ScrollbarWidth scrollbarWidthStyle() const { return m_scrollableAreaParameters.scrollbarWidthStyle; }
    std::optional<ScrollbarColor> scrollbarColorStyle() const { return m_scrollableAreaParameters.scrollbarColorStyle; }

    virtual String scrollbarStateForOrientation(ScrollbarOrientation) const { return ""_s; }

    Vector<PlatformLayerContainer, 2> hitTestableScrollbarLayers() const;

    void scrollbarVisibilityDidChange(ScrollbarOrientation, bool);
    void scrollbarMinimumThumbLengthDidChange(ScrollbarOrientation, int);

    NODELETE ScrollbarRevealBehavior takeScrollbarRevealBehaviorForNextScrollbarUpdate();

    virtual FloatPoint minimumScrollPosition() const;
    virtual FloatPoint maximumScrollPosition() const;
    // For Swift, which cannot call a virtual function that is defined in Swift: calls it through the vtable.
    FloatPoint minimumScrollPositionForSwift() const { return minimumScrollPosition(); }
    FloatPoint maximumScrollPositionForSwift() const { return maximumScrollPosition(); }

    void willStartAnimatedScroll();
    void didStopAnimatedScroll();
    void willStartWheelEventScroll();
    void didStopWheelEventScroll();

    void setScrollAnimationInProgress(bool);
    void setTotalContentsSizeForRubberBand(const FloatSize& totalContentsSizeForRubberBand) { m_totalContentsSizeForRubberBand = totalContentsSizeForRubberBand; }

    ScrollElasticity horizontalScrollElasticity() const { return m_scrollableAreaParameters.horizontalScrollElasticity; }
    ScrollElasticity verticalScrollElasticity() const { return m_scrollableAreaParameters.verticalScrollElasticity; }

    bool shouldRubberBandOnSide(BoxSide, RectEdges<bool> pinnedEdges) const;

protected:
    ScrollingTreeScrollingNode(ScrollingTree&, ScrollingNodeType, ScrollingNodeID);

    FloatPoint clampScrollPosition(FloatPoint) const;
    
    virtual void willDoProgrammaticScroll(const FloatPoint&) { }
    
    FloatPoint adjustedScrollPosition(FloatPoint, ScrollClamping = ScrollClamping::Clamped) const;

    void didStopProgrammaticScroll();

    virtual void currentScrollPositionChanged(ScrollType, ScrollingLayerPositionAction = ScrollingLayerPositionAction::Sync);
    virtual void updateViewportForCurrentScrollPosition(std::optional<FloatRect> = { }) { }
    virtual bool scrollPositionAndLayoutViewportMatch(FloatPoint position, std::optional<FloatRect> overrideLayoutViewport);
    // As minimumScrollPositionForSwift() does.
    void updateViewportForCurrentScrollPositionForSwift(std::optional<FloatRect> overrideLayoutViewport) { updateViewportForCurrentScrollPosition(overrideLayoutViewport); }
    void currentScrollPositionChangedForSwift(ScrollType scrollType, ScrollingLayerPositionAction action) { currentScrollPositionChanged(scrollType, action); }
    bool scrollPositionAndLayoutViewportMatchForSwift(FloatPoint position, std::optional<FloatRect> overrideLayoutViewport) { return scrollPositionAndLayoutViewportMatch(position, overrideLayoutViewport); }

    // Overrides read the tree's lock-guarded layers and state: callers hold the tree lock.
    SWIFT_UNSAFE virtual void repositionScrollingLayers() { }
    SWIFT_UNSAFE virtual void repositionRelatedLayers() { }

    SWIFT_UNSAFE void applyLayerPositions() override;

    FloatSize reachableContentsSize() const { return m_reachableContentsSize; }
    
    bool isLatchedNode() const;

    // Public for the tree's wheel event handling in Swift (ScrollingTreeLatchingController.swift).
public:
    // If the totalContentsSize changes in the middle of a rubber-band, we still want to use the old totalContentsSize for the sake of
    // computing the stretchAmount(). Using the old value will keep the animation smooth. When there is no rubber-band in progress at
    // all, m_totalContentsSizeForRubberBand should be equivalent to m_totalContentsSize.
    // Public for the iOS frame node's maximumScrollPosition() in WebKit's Swift, which cannot reach a protected member.
    FloatSize totalContentsSizeForRubberBand() const { return m_totalContentsSizeForRubberBand; }

    bool horizontalOverscrollBehaviorPreventsPropagation() const { return m_scrollableAreaParameters.horizontalOverscrollBehavior != OverscrollBehavior::Auto; }
    bool verticalOverscrollBehaviorPreventsPropagation() const { return m_scrollableAreaParameters.verticalOverscrollBehavior != OverscrollBehavior::Auto; }

    bool overscrollBehaviorAllowsHorizontalRubberBand() const { return m_scrollableAreaParameters.horizontalOverscrollBehavior != OverscrollBehavior::None; }
    bool overscrollBehaviorAllowsVerticalRubberBand() const { return m_scrollableAreaParameters.verticalOverscrollBehavior != OverscrollBehavior::None; }

    NODELETE PlatformWheelEvent eventForPropagation(PlatformWheelEvent) const;
protected:
    bool overscrollBehaviorAllowsRubberBand() const { return m_scrollableAreaParameters.horizontalOverscrollBehavior != OverscrollBehavior::None ||  m_scrollableAreaParameters.verticalOverscrollBehavior != OverscrollBehavior::None; }

    bool shouldRubberBand(PlatformWheelEvent, EventTargeting) const;

    void handleScrollPositionRequest(RequestedScrollData);

    // What commitStateAfterChildren() commits of a scrolling state node. The overrides cast the state node, since
    // Swift can cast it only through a call that retains the node and the result; the caller passes its
    // changedProperties().toRaw(), as for commitScrollingNodeState().
    SWIFT_UNSAFE void commitScrollingNodeStateAfterChildren(const ScrollingStateScrollingNode&, uint64_t changedProperties);

    // For Swift, which reads the state node's non-trivial members only as unsafe pointers (their getters return
    // references): what commitStateBeforeChildren() copies of the snap offsets, the scrollable area parameters and
    // the layers, when the state node changed them.
    SWIFT_UNSAFE void commitNonTrivialStateProperties(const ScrollingStateScrollingNode&);
    // For Swift, which reads requestedScrollData() only as an unsafe pointer (it returns a reference to a non-trivial
    // value): what commitStateAfterChildren() does with the state node's scroll requests.
    SWIFT_UNSAFE void handleRequestedScrollPositions(const ScrollingStateScrollingNode&);

    float rubberbandHyperbolicCoefficientForTesting() const;

    void dumpProperties(WTF::TextStream&, OptionSet<ScrollingStateTreeAsTextBehavior>) const override;
    String scrollingNodePropertiesText(ScrollingStateTreeAsTextBehaviors, int indent, TextStreamFormattingFlags, unsigned containerSizeLimit) const;
    // The snap offsets part of it, for Swift, which reaches the snap offset vectors only through unsafe API.
    String snapOffsetsPropertiesText(int indent, TextStreamFormattingFlags, unsigned containerSizeLimit) const;

    std::unique_ptr<ScrollingTreeScrollingNodeDelegate> m_delegate;

private:
    FloatSize m_scrollableAreaSize;
    FloatSize m_totalContentsSize;
    FloatSize m_totalContentsSizeForRubberBand;
    FloatSize m_reachableContentsSize;
    FloatPoint m_lastCommittedScrollPosition;
    FloatPoint m_currentScrollPosition;
    IntPoint m_scrollOrigin;
    FloatScrollSnapOffsetsInfo m_snapOffsetsInfo;
    std::optional<unsigned> m_currentHorizontalSnapPointIndex;
    std::optional<unsigned> m_currentVerticalSnapPointIndex;
    ScrollableAreaParameters m_scrollableAreaParameters;
#if ENABLE(SCROLLING_THREAD)
    OptionSet<SynchronousScrollingReason> m_synchronousScrollingReasons;
#endif
    bool m_isFirstCommit { true };
    bool m_scrolledSinceLastCommit { false };
#if HAVE(RUBBER_BANDING)
    bool m_restoredRubberbandingInProgress { false };
#endif
    ScrollbarRevealBehavior m_scrollbarRevealBehaviorForNextScrollbarUpdate { ScrollbarRevealBehavior::Default };

    LayerRepresentation m_scrollContainerLayer;
    LayerRepresentation m_scrolledContentsLayer;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_SCROLLING_NODE(ScrollingTreeScrollingNode, isScrollingNode())

namespace WebCore {
#if ENABLE(SCROLLING_THREAD)
// For Swift, which can cast a node only through a call that retains the node and the result: whether the node is a
// scrolling node with synchronous scrolling reasons.
inline bool scrollingTreeNodeHasSynchronousScrollingReasons(const ScrollingTreeNode& node)
{
    auto* scrollingNode = dynamicDowncast<ScrollingTreeScrollingNode>(node);
    return scrollingNode && scrollingNode->hasSynchronousScrollingReasons();
}
#endif

// For Swift: offers the event to the tree's node with the ID if it is a scrolling node, and returns whether it is.
inline bool handleWheelEventOnScrollingNodeForID(const ScrollingTreeLockedAccess& locked, ScrollingNodeID nodeID, const PlatformWheelEvent& wheelEvent, WheelEventHandlingResult& result)
{
    RefPtr node = dynamicDowncast<ScrollingTreeScrollingNode>(locked.nodeForID(nodeID));
    if (!node)
        return false;
    result = locked.handleWheelEvent(*node, wheelEvent, EventTargeting::Propagate);
    return true;
}
}

#endif // ENABLE(ASYNC_SCROLLING)
