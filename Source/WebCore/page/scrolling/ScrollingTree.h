/*
 * Copyright (C) 2012-2025 Apple Inc. All rights reserved.
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

#include <WebCore/BoxExtents.h>
#include <WebCore/EventTrackingRegions.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/LayerHostingContextIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/RectEdges.h>
#include <WebCore/Region.h>
#include <WebCore/RubberbandingState.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollingCoordinatorTypes.h>
#include <WebCore/ScrollingLockedAccess.h>
#include <WebCore/ScrollingTreeLatchingController.h>
#include <WebCore/ScrollingTreeNode.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/MonotonicTime.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakHashSet.h>
#include <wtf/TypeCasts.h>
#include <array>
#include <wtf/Markable.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {

class IntPoint;
class ScrollingStateTree;
class ScrollingStateNode;
class ScrollingTreeFrameScrollingNode;
class ScrollingTreeNode;
class ScrollingTreeOverflowScrollProxyNode;
class ScrollingTreePositionedNode;
class ScrollingTreeScrollingNode;
class ScrollingTreeFrameHostingNode;
class ScrollingTreeLockedAccess;
class ScrollingTreeStateAccess;

// The node sets of a scrolling tree's tree state, which ScrollingTreeStateAccess reaches one operation at a time.
enum class ScrollingTreeNodeSet : uint8_t { ActiveRubberBanding, ActiveScrollSnap, ActiveUserScrolls, ActiveScrollAnimations };

// Whether a ScrollingTreeLockedAccess was made for the commit of tree state, which may change the tree's structure.
enum class ScrollingTreeAccessMode : bool { Event, Commit };

// What the commit of one scrolling state tree did: failed, committed it, or found no hosting node for the hosted
// subtree it holds, which the caller keeps until that node is committed.
enum class ScrollingTreeCommitResult : uint8_t { Failed, Committed, NeedsHostingNode };

// Names for Swift, which cannot spell a class template specialization.
using OptionalLayerHostingContextIdentifier = std::optional<LayerHostingContextIdentifier>;
using OptionalWheelScrollGestureState = std::optional<WheelScrollGestureState>;
using RectEdgesBool = RectEdges<bool>;
using RectEdgesRubberBandingBehavior = RectEdges<RubberBandingBehavior>;

enum class EventListenerRegionType : uint64_t;

using FramesPerSecond = unsigned;
using PlatformDisplayID = uint32_t;

enum class EventTargeting : uint8_t { NodeOnly, Propagate };

enum class RequestsScrollHandling : uint8_t {
    Unhandled,
    Handled,
    Delayed
};

class SWIFT_PRIVATE_FILEID("WebCore/ScrollingTree.swift") ScrollingTree : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<ScrollingTree> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(ScrollingTree, WEBCORE_EXPORT);
    friend class ScrollingTreeLatchingController;
    friend class ScrollingTreeLockedAccess;
    friend class ScrollingTreeStateAccess;
    template<typename, typename> friend class ScrollingLockedValue;
public:
    WEBCORE_EXPORT ScrollingTree();
    WEBCORE_EXPORT virtual ~ScrollingTree();

    virtual bool isThreadedScrollingTree() const { return false; }
    virtual bool isScrollingTreeMac() const { return false; }
    virtual bool isRemoteScrollingTree() const { return false; }
    virtual bool isScrollingTreeIOS() const { return false; }
    virtual bool isScrollingTreeCoordinated() const { return false; }

    // This implies that we'll do hit-testing in the scrolling tree.
    bool asyncFrameOrOverflowScrollingEnabled() const { return m_asyncFrameOrOverflowScrollingEnabled; }
    void setAsyncFrameOrOverflowScrollingEnabled(bool value) { m_asyncFrameOrOverflowScrollingEnabled = value; }

    bool wheelEventGesturesBecomeNonBlocking() const { return m_wheelEventGesturesBecomeNonBlocking; }
    void setWheelEventGesturesBecomeNonBlocking(bool value) { m_wheelEventGesturesBecomeNonBlocking = value; }

    bool scrollingPerformanceTestingEnabled() const { return m_scrollingPerformanceTestingEnabled; }
    void setScrollingPerformanceTestingEnabled(bool value) { m_scrollingPerformanceTestingEnabled = value; }

    SWIFT_UNSAFE WEBCORE_EXPORT bool isUserScrollInProgressAtEventLocation(const PlatformWheelEvent&);
    SWIFT_UNSAFE WEBCORE_EXPORT OptionSet<WheelEventProcessingSteps> determineWheelEventProcessing(const PlatformWheelEvent&);
    SWIFT_UNSAFE WEBCORE_EXPORT virtual WheelEventHandlingResult handleWheelEvent(const PlatformWheelEvent&, OptionSet<WheelEventProcessingSteps> = { });
#if PLATFORM(MAC)
    // Stops spring animations in the scroller under the wheel event and in the scrollers that enclose it. This hit tests the
    // same way as handleWheelEvent(), so call it with the same locks held. Swift calls the overload below.
    SWIFT_UNSAFE WEBCORE_EXPORT void stopSpringAnimationsForWheelEvent(const PlatformWheelEvent&);
#endif

    NODELETE bool isRubberBandInProgressForNode(std::optional<ScrollingNodeID>);
    WEBCORE_EXPORT virtual void setRubberBandingInProgressForNode(ScrollingNodeID, bool);

#if HAVE(RUBBER_BANDING)
    NODELETE SWIFT_UNSAFE void setPendingMainFrameRubberbandingState(std::optional<RubberbandingState>&&) WTF_REQUIRES_LOCK(m_treeLock);
    NODELETE SWIFT_UNSAFE std::optional<RubberbandingState> takePendingMainFrameRubberbandingState() WTF_REQUIRES_LOCK(m_treeLock);
#endif

    NODELETE bool isUserScrollInProgressForNode(std::optional<ScrollingNodeID>);
    void setUserScrollInProgressForNode(ScrollingNodeID, bool);
    WEBCORE_EXPORT virtual void clearNodesWithUserScrollInProgress();

    NODELETE bool isScrollSnapInProgressForNode(std::optional<ScrollingNodeID>);
    void setNodeScrollSnapInProgress(ScrollingNodeID, bool);

    NODELETE bool isScrollAnimationInProgressForNode(std::optional<ScrollingNodeID>);
    void setScrollAnimationInProgressForNode(std::optional<ScrollingNodeID>, bool);

    NODELETE WEBCORE_EXPORT bool hasNodeWithActiveScrollAnimations();

    SWIFT_UNSAFE virtual void invalidate() { }
    WEBCORE_EXPORT bool commitTreeState(std::unique_ptr<ScrollingStateTree>&&, std::optional<LayerHostingContextIdentifier> = std::nullopt);

    WEBCORE_EXPORT virtual void applyLayerPositions();
    void setNeedsApplyLayerPositions() { m_needsApplyLayerPositions = true; }

    virtual Ref<ScrollingTreeNode> createScrollingTreeNode(ScrollingNodeType, ScrollingNodeID) = 0;
    
    // Inline, so that the lookups ScrollingTreeLockedAccess makes for Swift are inlined too.
    SWIFT_UNSAFE ScrollingTreeNode* nodeForID(std::optional<ScrollingNodeID> nodeID) const
    {
        if (!nodeID)
            return nullptr;

        return m_nodeMap.get(*nodeID);
    }

    using VisitorFunction = Function<void(ScrollingNodeID, ScrollingNodeType, std::optional<FloatPoint> scrollPosition, std::optional<FloatPoint> layoutViewportOrigin, bool scrolledSinceLastCommit)>;
    void traverseScrollingTree(NOESCAPE const VisitorFunction&);

    // Called after a scrolling tree node has handled a scroll and updated its layers.
    // Updates FrameView/RenderLayer scrolling state and GraphicsLayers.
    WEBCORE_EXPORT virtual void scrollingTreeNodeDidScroll(ScrollingTreeScrollingNode&, ScrollingLayerPositionAction = ScrollingLayerPositionAction::Sync);
    virtual void scrollingTreeNodeWillStartAnimatedScroll(ScrollingTreeScrollingNode&) { }
    virtual void scrollingTreeNodeDidStopAnimatedScroll(ScrollingTreeScrollingNode&) { }
    virtual void scrollingTreeNodeWillStartWheelEventScroll(ScrollingTreeScrollingNode&) { }
    virtual void scrollingTreeNodeDidStopWheelEventScroll(ScrollingTreeScrollingNode&) { }

    // Called for requested scroll position updates. Returns true if handled.
    SWIFT_UNSAFE virtual RequestsScrollHandling scrollingTreeNodeRequestsScroll(ScrollingNodeID, RequestedScrollData) { return RequestsScrollHandling::Unhandled; }
    SWIFT_UNSAFE virtual bool scrollingTreeNodeRequestsKeyboardScroll(ScrollingNodeID, RequestedKeyboardScrollData) { return false; }

    virtual void didHandleScrollRequestForNode(ScrollingNodeID, ScrollRequestType, FloatPoint, ShouldFireScrollEnd, Markable<ScrollRequestIdentifier>) { }

    // Delegated scrolling/zooming has caused the viewport to change, so update viewport-constrained layers
    WEBCORE_EXPORT void mainFrameViewportChangedViaDelegatedScrolling(const FloatPoint& scrollPosition, const WebCore::FloatRect& layoutViewport, double scale);

    SWIFT_UNSAFE void notifyRelatedNodesAfterScrollPositionChange(ScrollingTreeScrollingNode& changedNode);

    virtual void reportSynchronousScrollingReasonsChanged(MonotonicTime, OptionSet<SynchronousScrollingReason>) { }
    virtual void reportExposedUnfilledArea(MonotonicTime, unsigned /* unfilledArea */) { }

#if PLATFORM(IOS_FAMILY)
    virtual void scrollingTreeNodeWillStartPanGesture(ScrollingNodeID) { }
#endif
    virtual void scrollingTreeNodeWillStartScroll(ScrollingNodeID) { }
    virtual void scrollingTreeNodeDidEndScroll(ScrollingNodeID) { }

    virtual void scrollingTreeNodeDidBeginScrollSnapping(ScrollingNodeID) { }
    virtual void scrollingTreeNodeDidEndScrollSnapping(ScrollingNodeID) { }

    virtual void stickyScrollingTreeNodeBeganSticking(ScrollingNodeID) { }
#if ENABLE(OVERLAY_REGIONS_REMOTE_EFFECT)
    virtual void stickyScrollingTreeNodeEndedSticking(ScrollingNodeID) { }
    virtual void scrollingTreeNodeWillBeRemoved(ScrollingNodeID) { }
#endif

    NODELETE WEBCORE_EXPORT TrackingType eventTrackingTypeForPoint(EventTrackingRegions::EventType, IntPoint);

    SWIFT_UNSAFE WEBCORE_EXPORT WebCore::RectEdges<bool> pinnedStateIncludingAncestorsAtPoint(FloatPoint);

    virtual void receivedWheelEventWithPhases(PlatformWheelEventPhase /* phase */, PlatformWheelEventPhase /* momentumPhase */) { }
    virtual void deferWheelEventTestCompletionForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) { }
    virtual void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) { }

#if PLATFORM(MAC)
    SWIFT_UNSAFE virtual void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) = 0;
#else
    SWIFT_UNSAFE void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) { }
#endif

    virtual void setActiveScrollSnapIndices(ScrollingNodeID, std::optional<unsigned> /*horizontalIndex*/, std::optional<unsigned> /*verticalIndex*/) { }

#if PLATFORM(COCOA)
    WEBCORE_EXPORT virtual void currentSnapPointIndicesDidChange(ScrollingNodeID, std::optional<unsigned> horizontal, std::optional<unsigned> vertical) = 0;
#endif

    NODELETE void setMainFramePinnedState(RectEdges<bool>);

    // Can be called from any thread. Will update what edges allow rubber-banding.
    NODELETE WEBCORE_EXPORT void setClientAllowedMainFrameRubberBandableEdges(RectEdges<RubberBandingBehavior>);
    NODELETE RubberBandingBehavior clientAllowsMainFrameRubberBandingOnSide(BoxSide);

    bool isHandlingProgrammaticScroll() const { return m_isHandlingProgrammaticScroll; }
    void setIsHandlingProgrammaticScroll(bool isHandlingProgrammaticScroll) { m_isHandlingProgrammaticScroll = isHandlingProgrammaticScroll; }

    void setIsApplyingDeltaScroll(bool isApplyingDeltaScroll) { m_isApplyingDeltaScroll = isApplyingDeltaScroll; }
    std::optional<ScrollRelativity> relativityForScrollUpdate() const
    {
        if (!m_isApplyingDeltaScroll)
            return std::nullopt;
        return ScrollRelativity::Delta;
    }

    NODELETE void setScrollPinningBehavior(ScrollPinningBehavior);
    NODELETE WEBCORE_EXPORT ScrollPinningBehavior scrollPinningBehavior();

    NODELETE WEBCORE_EXPORT bool willWheelEventStartSwipeGesture(const PlatformWheelEvent&);

    SWIFT_UNSAFE ScrollingTreeFrameScrollingNode* rootNode() const { return m_rootNode.get(); }
    NODELETE std::optional<ScrollingNodeID> latchedNodeID() const;
    NODELETE bool isLatchedToUnscrollableRoot() const;
    NODELETE WEBCORE_EXPORT void clearLatchedNode();

    WEBCORE_EXPORT bool hasFixedOrSticky() const;
    void fixedOrStickyNodeAdded(ScrollingTreeNode&);

    // A map of overflow scrolling nodes to positioned nodes which need to be updated
    // when the scroller changes, but are not descendants.
    using RelatedNodesMap = HashMap<ScrollingNodeID, Vector<ScrollingNodeID>>;
    SWIFT_UNAVAILABLE_IN_SWIFT RelatedNodesMap& overflowRelatedNodes() LIFETIME_BOUND { return m_overflowRelatedNodesMap; }

    SWIFT_UNAVAILABLE_IN_SWIFT HashSet<Ref<ScrollingTreeOverflowScrollProxyNode>>& activeOverflowScrollProxyNodes() LIFETIME_BOUND { return m_activeOverflowScrollProxyNodes; }
    SWIFT_UNAVAILABLE_IN_SWIFT HashSet<Ref<ScrollingTreePositionedNode>>& activePositionedNodes() LIFETIME_BOUND { return m_activePositionedNodes; }

    SWIFT_UNSAFE WEBCORE_EXPORT String scrollingTreeAsText(OptionSet<ScrollingStateTreeAsTextBehavior> = { });

    SWIFT_UNSAFE WEBCORE_EXPORT float rubberbandHyperbolicCoefficientForTesting();

    bool isMonitoringWheelEvents() const { return m_isMonitoringWheelEvents; }
    void setIsMonitoringWheelEvents(bool b) { m_isMonitoringWheelEvents = b; }
    bool inCommitTreeState() const { return m_inCommitTreeState; }

    WEBCORE_EXPORT bool hasRecentActivity();

    void scrollBySimulatingWheelEventForTesting(ScrollingNodeID, FloatSize);

    SWIFT_UNSAFE virtual void lockLayersForHitTesting() { }
    SWIFT_UNSAFE virtual void unlockLayersForHitTesting() { }

    // Holds the tree's layers for hit testing while it lives. Swift constructs one, and the members that hit test for
    // Swift take one as their proof, so a Swift body that hit tests holds the layers for the whole of its scope
    // (ScrollingLockedAccess.h).
    // It holds the tree, so the hold outlives no tree.
    class SCROLLING_LOCK_HOLDER_ATTRIBUTES HitTestLocker {
        WTF_MAKE_NONCOPYABLE(HitTestLocker);
        WTF_FORBID_HEAP_ALLOCATION;
    public:
        SCROLLING_UNAVAILABLE_FROM_ASYNC HitTestLocker(ScrollingTree& tree)
            : m_tree(tree)
        {
            m_tree->lockLayersForHitTesting();
        }
        // Swift imports a noncopyable class only if it has a move constructor, so one is declared; it traps.
        [[noreturn]] HitTestLocker(HitTestLocker&& other)
            : m_tree(other.m_tree)
        {
            RELEASE_ASSERT_NOT_REACHED();
        }
        HitTestLocker& operator=(HitTestLocker&&) = delete;
        HitTestLocker() = delete;
        ~HitTestLocker()
        {
            m_tree->unlockLayersForHitTesting();
        }

        // Whether this holds tree's layers, for a member that takes one as its proof.
        bool holdsLayersOf(const ScrollingTree& tree) const { return m_tree.ptr() == &tree; }
    private:
        const Ref<ScrollingTree> m_tree;
    };

#if PLATFORM(MAC)
    // For Swift: stopSpringAnimationsForWheelEvent() with the hold of this tree's layers as its proof.
    void stopSpringAnimationsForWheelEvent(const HitTestLocker& hitTest, const PlatformWheelEvent& wheelEvent)
    {
        RELEASE_ASSERT(hitTest.holdsLayersOf(*this));
        stopSpringAnimationsForWheelEvent(wheelEvent);
    }
#endif

    struct SwipeState {
        RectEdges<RubberBandingBehavior> clientAllowedRubberBandableEdges  { RubberBandingBehavior::Always, RubberBandingBehavior::Always, RubberBandingBehavior::Always, RubberBandingBehavior::Always };
        RectEdges<bool> mainFramePinnedState { true, true, true, true };
        ScrollPinningBehavior scrollPinningBehavior { ScrollPinningBehavior::DoNotPin };
    };
    // Take the tree's state, swipe state and last wheel event time locks for Swift; each is held until the returned
    // object is destroyed.
    SCROLLING_UNAVAILABLE_FROM_ASYNC inline ScrollingTreeStateAccess lockTreeState();
    SCROLLING_UNAVAILABLE_FROM_ASYNC inline ScrollingLockedValue<ScrollingTree, SwipeState> lockSwipeState();
    SCROLLING_UNAVAILABLE_FROM_ASYNC inline ScrollingLockedValue<ScrollingTree, MonotonicTime> lockLastWheelEventTime();
    // Takes m_treeLock for a ScrollingTreeLockedAccess of mode Event. The holder must not be alive across a call that
    // waits on one of m_treeLock's Conditions.
    SCROLLING_UNAVAILABLE_FROM_ASYNC inline ScrollingTreeLockedAccess lockTree();

    SWIFT_UNSAFE virtual bool isScrollingSynchronizedWithMainThread() WTF_REQUIRES_LOCK(m_treeLock) { return true; }

    Lock& treeLock() LIFETIME_BOUND WTF_RETURNS_LOCK(m_treeLock) { return m_treeLock; }

    NODELETE WEBCORE_EXPORT void windowScreenDidChange(PlatformDisplayID, std::optional<FramesPerSecond> nominalFramesPerSecond);
    NODELETE PlatformDisplayID displayID();
    WEBCORE_EXPORT virtual void displayDidRefresh(PlatformDisplayID) { }

    WEBCORE_EXPORT void willProcessWheelEvent();

    WEBCORE_EXPORT Vector<ScrollUpdate> takePendingScrollUpdates();
    NODELETE WEBCORE_EXPORT bool hasPendingScrollUpdates();

    SWIFT_UNSAFE virtual void removePendingScrollAnimationForNode(ScrollingNodeID) { }

    NODELETE SWIFT_UNSAFE WEBCORE_EXPORT FloatBoxExtent mainFrameObscuredContentInsets() const;

#if HAVE(NSREFRESHCONTROLLER)
    virtual float topScrollStretchForRefreshController() const { return 0; }
    virtual float refreshControllerSnappingThreshold() const { return 0; }
    virtual bool hasRefreshController() const { return false; }
#endif

    virtual void triggerMainFrameRubberBandSnapBack() { }
    virtual void mainFrameRubberBandTargetOffsetDidChange() { }

    NODELETE SWIFT_UNSAFE WEBCORE_EXPORT FloatPoint mainFrameScrollPosition() const;

    NODELETE WEBCORE_EXPORT ScrollbarWidth mainFrameScrollbarWidth() const;
    NODELETE WEBCORE_EXPORT std::optional<ScrollbarColor> mainFrameScrollbarColor() const;

    NODELETE WEBCORE_EXPORT OverscrollBehavior mainFrameHorizontalOverscrollBehavior() const;
    NODELETE WEBCORE_EXPORT OverscrollBehavior mainFrameVerticalOverscrollBehavior() const;
    
    NODELETE WEBCORE_EXPORT IntPoint mainFrameScrollOrigin() const;
    NODELETE WEBCORE_EXPORT int mainFrameHeaderHeight() const;
    NODELETE WEBCORE_EXPORT int mainFrameFooterHeight() const;
    NODELETE WEBCORE_EXPORT float mainFrameScaleFactor() const;
    // Used when the UI process owns the page scale but isn't sending a delegated viewport update.
    WEBCORE_EXPORT void setMainFrameDelegatedPageScaleFactor(float);
    NODELETE WEBCORE_EXPORT FloatSize totalContentsSize() const;
    NODELETE WEBCORE_EXPORT FloatRect layoutViewport() const;
    // The view size less the space the scrollbars take, in view coordinates, so it doesn't track the zoom.
    // See ScrollView::sizeForVisibleContent().
    WEBCORE_EXPORT FloatSize mainFrameSizeForVisibleContent() const;

    WEBCORE_EXPORT void viewWillStartLiveResize();
    WEBCORE_EXPORT void viewWillEndLiveResize();
    WEBCORE_EXPORT void viewSizeDidChange();
    NODELETE WEBCORE_EXPORT bool overlayScrollbarsEnabled();

    NODELETE WEBCORE_EXPORT Seconds frameDuration();
    NODELETE WEBCORE_EXPORT Seconds maxAllowableRenderingUpdateDurationForSynchronization();
    WEBCORE_EXPORT virtual void scrollingTreeNodeScrollbarVisibilityDidChange(ScrollingNodeID, ScrollbarOrientation, bool) { };
    WEBCORE_EXPORT virtual void scrollingTreeNodeScrollbarMinimumThumbLengthDidChange(WebCore::ScrollingNodeID, ScrollbarOrientation, int) { };

    SWIFT_UNSAFE void addScrollingNodeToHostedSubtreeMap(WebCore::LayerHostingContextIdentifier, Ref<ScrollingTreeFrameHostingNode>);
    SWIFT_UNSAFE void removeNode(ScrollingNodeID, ScrollingTreeFrameHostingNode* = nullptr);
    SWIFT_UNSAFE void removeFrameHostingNode(LayerHostingContextIdentifier);

    virtual void hostedSubtreeNeedsFullCommit(FrameIdentifier) { }

    NODELETE WEBCORE_EXPORT std::optional<FrameIdentifier> frameIDForScrollingNodeID(ScrollingNodeID);

protected:
    SWIFT_UNSAFE WEBCORE_EXPORT WheelEventHandlingResult handleWheelEventWithNode(const PlatformWheelEvent&, OptionSet<WheelEventProcessingSteps>, ScrollingTreeNode*, EventTargeting = EventTargeting::Propagate);

    NODELETE void setMainFrameScrollPosition(FloatPoint);

    NODELETE WEBCORE_EXPORT void setGestureState(std::optional<WheelScrollGestureState>);
    NODELETE WEBCORE_EXPORT std::optional<WheelScrollGestureState> gestureState();
    SWIFT_UNSAFE WEBCORE_EXPORT RefPtr<ScrollingTreeFrameScrollingNode> hostedRootNodeForFrame(FrameIdentifier) const WTF_REQUIRES_LOCK(m_treeLock);

    NODELETE std::optional<FramesPerSecond> nominalFramesPerSecond();

    SWIFT_UNSAFE WEBCORE_EXPORT virtual void applyLayerPositionsInternal() WTF_REQUIRES_LOCK(m_treeLock);
    SWIFT_UNSAFE WEBCORE_EXPORT void removeAllNodes() WTF_REQUIRES_LOCK(m_treeLock);
    SWIFT_UNSAFE void removeFromActiveNodes(ScrollingTreeNode&);

    virtual void hasNodeWithAnimatedScrollChanged(bool /* hasNodeWithAnimatedScroll */) { }

    bool hasProcessedWheelEventsRecently();

    HashSet<ScrollingNodeID> nodesWithActiveScrollAnimations();
    SWIFT_UNSAFE WEBCORE_EXPORT void serviceScrollAnimations(MonotonicTime) WTF_REQUIRES_LOCK(m_treeLock);

#if ENABLE(COORDINATED_TOUCH_EVENTS)
    std::optional<FloatSize> mainFrameScrollOffset() const;
#endif

    SWIFT_UNSAFE void addPendingScrollUpdateInternal(ScrollUpdate);
    WEBCORE_EXPORT void addPendingScrollUpdate(ScrollUpdate);
    virtual void didAddPendingScrollUpdate() { }

    SWIFT_UNAVAILABLE_IN_SWIFT mutable Lock m_treeLock; // Protects the scrolling tree.

private:
    SWIFT_UNSAFE virtual void propagateSynchronousScrollingReasons(const HashSet<ScrollingNodeID>&) WTF_REQUIRES_LOCK(m_treeLock) { }
    SWIFT_UNSAFE void captureMainFrameRubberbandingState(bool rootStateNodeChanged) WTF_REQUIRES_LOCK(m_treeLock);
    SWIFT_UNSAFE void updateTreeStateFromRootStateNode(const ScrollingStateTree*, bool rootStateNodeChanged);

    SWIFT_UNSAFE void applyLayerPositionsRecursive(ScrollingTreeNode&) WTF_REQUIRES_LOCK(m_treeLock);
    SWIFT_UNSAFE void notifyRelatedNodesRecursive(ScrollingTreeNode&);
    SWIFT_UNSAFE void traverseScrollingTreeRecursive(ScrollingTreeNode&, NOESCAPE const VisitorFunction&) WTF_REQUIRES_LOCK(m_treeLock);
    
    NODELETE void setOverlayScrollbarsEnabled(bool);

    SWIFT_UNSAFE virtual void didCommitTree() { }

    SWIFT_UNSAFE WEBCORE_EXPORT virtual RefPtr<ScrollingTreeNode> scrollingNodeForPoint(FloatPoint);
#if ENABLE(WHEEL_EVENT_REGIONS)
    SWIFT_UNSAFE WEBCORE_EXPORT virtual OptionSet<EventListenerRegionType> eventListenerRegionTypesForPoint(FloatPoint) const;
#endif

    SWIFT_UNSAFE OptionSet<WheelEventProcessingSteps> computeWheelProcessingSteps(const PlatformWheelEvent&) WTF_REQUIRES_LOCK(m_treeStateLock);

    SWIFT_UNAVAILABLE_IN_SWIFT RefPtr<ScrollingTreeFrameScrollingNode> m_rootNode;

    using ScrollingTreeNodeMap = HashMap<ScrollingNodeID, Ref<ScrollingTreeNode>>;
    SWIFT_UNAVAILABLE_IN_SWIFT ScrollingTreeNodeMap m_nodeMap;

    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_frameIDMapLock;
    SWIFT_UNAVAILABLE_IN_SWIFT HashMap<FrameIdentifier, HashSet<ScrollingNodeID>> m_nodeMapPerFrame WTF_GUARDED_BY_LOCK(m_frameIDMapLock);

    ScrollingTreeLatchingController m_latchingController;
    // The gesture state is kept with the latching state (ScrollingTreeLatchingController.swift). This storage keeps
    // ScrollingTree's layout the same with either setting, so a TestWebKitAPI build can run against a WebCore built with
    // the other. It mirrors ScrollingTreeGestureState's private members (ScrollingTreeGestureState.h): keep the two in step.
    struct GestureStateLayout {
        ThreadSafeWeakRef<ScrollingTree> scrollingTree;
        Markable<ScrollingNodeID> mayBeginNodeID;
        Markable<ScrollingNodeID> activeNodeID;
    };
    [[maybe_unused]] SWIFT_UNAVAILABLE_IN_SWIFT alignas(GestureStateLayout) std::array<std::byte, sizeof(GestureStateLayout)> m_gestureStateStorage { };

    SWIFT_UNAVAILABLE_IN_SWIFT RelatedNodesMap m_overflowRelatedNodesMap;

    SWIFT_UNAVAILABLE_IN_SWIFT HashSet<Ref<ScrollingTreeOverflowScrollProxyNode>> m_activeOverflowScrollProxyNodes;
    SWIFT_UNAVAILABLE_IN_SWIFT HashSet<Ref<ScrollingTreePositionedNode>> m_activePositionedNodes;

    struct TreeState {
        EventTrackingRegions eventTrackingRegions;
        FloatPoint mainFrameScrollPosition;
        PlatformDisplayID displayID { 0 };
        std::optional<FramesPerSecond> nominalFramesPerSecond;
        std::optional<WheelScrollGestureState> gestureState;
        HashSet<ScrollingNodeID> nodesWithActiveRubberBanding;
        HashSet<ScrollingNodeID> nodesWithActiveScrollSnap;
        HashSet<ScrollingNodeID> nodesWithActiveUserScrolls;
        HashSet<ScrollingNodeID> nodesWithActiveScrollAnimations;
    };
    
    SWIFT_UNAVAILABLE_IN_SWIFT mutable Lock m_treeStateLock;
    SWIFT_UNAVAILABLE_IN_SWIFT TreeState m_treeState WTF_GUARDED_BY_LOCK(m_treeStateLock);

    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_swipeStateLock;
    SWIFT_UNAVAILABLE_IN_SWIFT SwipeState m_swipeState WTF_GUARDED_BY_LOCK(m_swipeStateLock);

    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_pendingScrollUpdatesLock;
    SWIFT_UNAVAILABLE_IN_SWIFT Vector<ScrollUpdate> m_pendingScrollUpdates WTF_GUARDED_BY_LOCK(m_pendingScrollUpdatesLock);

#if HAVE(RUBBER_BANDING)
    SWIFT_UNAVAILABLE_IN_SWIFT std::optional<RubberbandingState> m_pendingMainFrameRubberbandingState WTF_GUARDED_BY_LOCK(m_treeLock);
#endif

    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_lastWheelEventTimeLock;
    SWIFT_UNAVAILABLE_IN_SWIFT MonotonicTime m_lastWheelEventTime WTF_GUARDED_BY_LOCK(m_lastWheelEventTimeLock);

    SWIFT_UNAVAILABLE_IN_SWIFT HashMap<LayerHostingContextIdentifier, Vector<std::unique_ptr<ScrollingStateTree>>> m_hostedSubtreesNeedingPairing;
    SWIFT_UNAVAILABLE_IN_SWIFT HashMap<LayerHostingContextIdentifier, Ref<ScrollingTreeFrameHostingNode>> m_hostedSubtrees;

protected:
    // Read on the event handling thread while the scrolling thread changes it.
    std::atomic<bool> m_allowLatching { true };
    static_assert(sizeof(std::atomic<bool>) == sizeof(bool) && alignof(std::atomic<bool>) == alignof(bool));

private:
    SWIFT_UNAVAILABLE_IN_SWIFT bool m_hasLockedAccess WTF_GUARDED_BY_LOCK(m_treeLock) { false }; // Whether a ScrollingTreeLockedAccess for this tree exists.
    ThreadSafeWeakHashSet<ScrollingTreeNode> m_fixedOrStickyNodes;
    std::atomic<bool> m_isHandlingProgrammaticScroll { false };
    std::atomic<bool> m_isApplyingDeltaScroll { false };
    std::atomic<bool> m_needsApplyLayerPositions { false };
    bool m_isMonitoringWheelEvents { false };
    bool m_scrollingPerformanceTestingEnabled { false };
    bool m_overlayScrollbarsEnabled { false };
    bool m_asyncFrameOrOverflowScrollingEnabled { false };
    bool m_wheelEventGesturesBecomeNonBlocking { false };
    bool m_inCommitTreeState { false };
};

// Swift cannot name the unspecialized RefPtr; ScrollingTreeNode.swift holds scrollingTree()'s result as this one.
using RefPtrScrollingTree = RefPtr<ScrollingTree>;

// Holder that proves m_treeLock is held, for Swift: its members check the lock and that the nodes given belong to the
// tree. Only code that holds the lock constructs one, or lockTree(), which takes it for the holder's life; it must not
// live across a Condition wait on m_treeLock. It cannot be copied, moved or put on the heap.
// ScrollingTreeAccessMode::Commit is for commitTreeState() and what it calls; the members that change the tree's
// structure and the node commit members crash on mode Event.
class SWIFT_NONCOPYABLE __attribute__((swift_attr("~Sendable"))) WEBCORE_EXPORT ScrollingTreeLockedAccess {
    WTF_MAKE_NONCOPYABLE(ScrollingTreeLockedAccess);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    SWIFT_UNSAFE ScrollingTreeLockedAccess(ScrollingTree& tree, ScrollingTreeAccessMode) WTF_REQUIRES_LOCK(tree.treeLock());
    // Swift imports a noncopyable class only if it has a move constructor, so one is declared; it traps.
    [[noreturn]] ScrollingTreeLockedAccess(ScrollingTreeLockedAccess&&);
    ScrollingTreeLockedAccess& operator=(ScrollingTreeLockedAccess&&) = delete;
    // Swift would otherwise give the class an init() that zero-fills it.
    ScrollingTreeLockedAccess() = delete;
    ~ScrollingTreeLockedAccess() WTF_IGNORES_THREAD_SAFETY_ANALYSIS;

    // Unretained: the node map keeps the node while the lock is held.
    ALWAYS_INLINE ScrollingTreeNode* nodeForID(ScrollingNodeID nodeID) const { return tree().nodeForID(nodeID); }
    // Null when nodeID is.
    ALWAYS_INLINE ScrollingTreeNode* nodeForID(std::optional<ScrollingNodeID> nodeID) const { return tree().nodeForID(nodeID); }
    RefPtr<ScrollingTreeFrameScrollingNode> rootNode() const;
    void removeNode(ScrollingNodeID) const;
    void removeNode(ScrollingNodeID, ScrollingTreeFrameHostingNode&) const;

    bool commitStateBeforeChildren(ScrollingTreeNode&, const ScrollingStateNode&) const;
    bool commitStateAfterChildren(ScrollingTreeNode&, const ScrollingStateNode&) const;
    void didCompleteCommitForNode(ScrollingTreeNode&) const;
    void willBeDestroyed(ScrollingTreeNode&) const;
    RefPtr<ScrollingTreeNode> parent(ScrollingTreeNode&) const;
    void setParent(ScrollingTreeNode&, ScrollingTreeNode* parent) const;
    void appendChild(ScrollingTreeNode& parent, ScrollingTreeNode& child) const;
    void removeChild(ScrollingTreeNode& parent, ScrollingTreeNode& child) const;
    void removeAllChildren(ScrollingTreeNode&) const;

    // The tree's root node; null is allowed. The node must belong to the tree.
    void setRootNode(ScrollingTreeFrameScrollingNode*) const;
    void removeAllNodes() const;
    // Adds node to the node map under its ID, replacing any node with that ID, and to the nodes of frameID.
    void addNode(ScrollingTreeNode&, FrameIdentifier) const;

    // Commits stateTree, or keeps it for its hosting node when it is a hosted subtree whose hosting node is not in
    // the tree yet.
    bool commitStateTree(std::unique_ptr<ScrollingStateTree>&&, std::optional<LayerHostingContextIdentifier>) const;
    // Commits the hosted subtrees kept for the hosting node of hostingContextIdentifier.
    bool commitHostedSubtreesNeedingPairing(LayerHostingContextIdentifier) const;
    void discardHostedSubtreesNeedingPairing(LayerHostingContextIdentifier) const;
    RefPtr<ScrollingTreeFrameHostingNode> hostingNodeForHostedSubtree(LayerHostingContextIdentifier) const;
    void addHostedChild(ScrollingTreeFrameHostingNode&, ScrollingTreeNode&) const;
    void removeHostedChildren(ScrollingTreeFrameHostingNode&) const;
    // When a commit replaces the root node: keeps the root node's rubber banding for the new one.
    void captureMainFrameRubberbandingState(bool rootStateNodeChanged) const;
    // Takes the tree's flags and its tree state from the root state node, under the tree state lock.
    void updateTreeStateFromRootStateNode(const ScrollingStateTree&, bool rootStateNodeChanged) const;
    // Removes the overflow related nodes and the active nodes of frameID; the commit adds them back.
    void removeActiveNodesForFrame(FrameIdentifier) const;
    Vector<ScrollingNodeID> nodeIDsForFrame(FrameIdentifier) const;
    // Swift has no HashSet to pass, and every override reads only whether the set is empty: the commit
    // passes one of its nodes with synchronous scrolling reasons, if it has any, and marks the ancestors itself.
    void propagateSynchronousScrollingReasons(std::optional<ScrollingNodeID> anySynchronousScrollingNode) const;
    // Whether the commit marks the scrolling nodes enclosing a node with synchronous scrolling reasons.
    bool propagatesSynchronousScrollingReasonsToAncestors() const;
    void didCommitTree() const;

    WheelEventHandlingResult handleWheelEvent(ScrollingTreeScrollingNode&, const PlatformWheelEvent&, EventTargeting) const;
    void stopSpringAnimation(ScrollingTreeScrollingNode&) const;
    void serviceScrollAnimation(ScrollingTreeScrollingNode&, MonotonicTime) const;
    void scrollTo(ScrollingTreeScrollingNode&, const FloatPoint&, ScrollType, ScrollClamping) const;
    void scrollBy(ScrollingTreeScrollingNode&, const FloatSize&, ScrollClamping) const;
    void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) const;

private:
    friend class ScrollingTree;
    // For ScrollingTree::lockTree(): takes the tree's lock, which the destructor releases.
    explicit ScrollingTreeLockedAccess(ScrollingTree&) WTF_IGNORES_THREAD_SAFETY_ANALYSIS;

    // The thread safety analysis does not follow this check to the returned tree, so callers that need its lock assert it again.
    ALWAYS_INLINE ScrollingTree& tree() const
    {
        RELEASE_ASSERT(m_tree->m_treeLock.isLocked());
        assertIsHeld(m_tree->m_treeLock);
        return m_tree.get();
    }
    void checkNode(const ScrollingTreeNode&) const;
    void checkCommit() const;

    const Ref<ScrollingTree> m_tree;
    const ScrollingTreeAccessMode m_mode;
    const bool m_holdsTreeLock { false };
};

inline ScrollingTreeLockedAccess ScrollingTree::lockTree() { return ScrollingTreeLockedAccess { *this }; }

// Holder of a scrolling tree's m_treeStateLock, for Swift (ScrollingLockedAccess.h): the tree state one
// operation at a time, by value.
class SCROLLING_LOCK_HOLDER_ATTRIBUTES ScrollingTreeStateAccess {
    SCROLLING_LOCK_HOLDER(ScrollingTreeStateAccess, ScrollingTree, &ScrollingTree::m_treeStateLock, ScrollingTree::TreeState, &ScrollingTree::m_treeState, state);
public:
    void setMainFrameScrollPosition(FloatPoint position) const { state().mainFrameScrollPosition = position; }
    TrackingType eventTrackingTypeForPoint(EventTrackingRegionsEventType eventType, IntPoint point) const { return state().eventTrackingRegions.trackingTypeForPoint(eventType, point); }
    PlatformDisplayID displayID() const { return state().displayID; }
    void setDisplayID(PlatformDisplayID displayID) const { state().displayID = displayID; }
    std::optional<FramesPerSecond> nominalFramesPerSecond() const { return state().nominalFramesPerSecond; }
    void setNominalFramesPerSecond(std::optional<FramesPerSecond> value) const { state().nominalFramesPerSecond = value; }
    std::optional<WheelScrollGestureState> gestureState() const { return state().gestureState; }
    void setGestureState(std::optional<WheelScrollGestureState> value) const { state().gestureState = value; }

    bool contains(ScrollingTreeNodeSet set, ScrollingNodeID nodeID) const { return nodes(set).contains(nodeID); }
    // Whether nodeID was not in the set.
    bool add(ScrollingTreeNodeSet set, ScrollingNodeID nodeID) const { return nodes(set).add(nodeID).isNewEntry; }
    // Whether nodeID was in the set.
    bool remove(ScrollingTreeNodeSet set, ScrollingNodeID nodeID) const { return nodes(set).remove(nodeID); }
    bool isEmpty(ScrollingTreeNodeSet set) const { return nodes(set).isEmpty(); }

private:
    HashSet<ScrollingNodeID>& nodes(ScrollingTreeNodeSet set) const
    {
        // In ScrollingTreeNodeSet's order. Swift can make a ScrollingTreeNodeSet of any raw value, so the index is checked.
        static constexpr std::array sets { &ScrollingTree::TreeState::nodesWithActiveRubberBanding, &ScrollingTree::TreeState::nodesWithActiveScrollSnap, &ScrollingTree::TreeState::nodesWithActiveUserScrolls, &ScrollingTree::TreeState::nodesWithActiveScrollAnimations };
        RELEASE_ASSERT(std::to_underlying(set) < sets.size());
        return state().*sets[std::to_underlying(set)];
    }
};

// Names for Swift, which cannot spell a class template specialization.
using ScrollingTreeSwipeStateAccess = ScrollingLockedValue<ScrollingTree, ScrollingTree::SwipeState>;
using ScrollingTreeLastWheelEventTimeAccess = ScrollingLockedValue<ScrollingTree, MonotonicTime>;

template<> inline Lock ScrollingTree::* const ScrollingTreeSwipeStateAccess::s_lock = &ScrollingTree::m_swipeStateLock;
template<> inline ScrollingTree::SwipeState ScrollingTree::* const ScrollingTreeSwipeStateAccess::s_value = &ScrollingTree::m_swipeState;
template<> inline Lock ScrollingTree::* const ScrollingTreeLastWheelEventTimeAccess::s_lock = &ScrollingTree::m_lastWheelEventTimeLock;
template<> inline MonotonicTime ScrollingTree::* const ScrollingTreeLastWheelEventTimeAccess::s_value = &ScrollingTree::m_lastWheelEventTime;

inline ScrollingTreeStateAccess ScrollingTree::lockTreeState() { return ScrollingTreeStateAccess { *this }; }
inline ScrollingTreeSwipeStateAccess ScrollingTree::lockSwipeState() { return ScrollingTreeSwipeStateAccess { *this }; }
inline ScrollingTreeLastWheelEventTimeAccess ScrollingTree::lockLastWheelEventTime() { return ScrollingTreeLastWheelEventTimeAccess { *this }; }

class ScrollingTreeWheelEventTestMonitorCompletionDeferrer {
public:
    ScrollingTreeWheelEventTestMonitorCompletionDeferrer(ScrollingTree& scrollingTree, ScrollingNodeID nodeID, WheelEventTestMonitor::DeferReason reason)
        : m_scrollingTree(scrollingTree)
        , m_scrollingNodeID(nodeID)
        , m_deferReason(reason)
    {
        m_scrollingTree->deferWheelEventTestCompletionForReason(m_scrollingNodeID, m_deferReason);
    }
    
    ~ScrollingTreeWheelEventTestMonitorCompletionDeferrer()
    {
        m_scrollingTree->removeWheelEventTestCompletionDeferralForReason(m_scrollingNodeID, m_deferReason);
    }

private:
    const Ref<ScrollingTree> m_scrollingTree;
    ScrollingNodeID m_scrollingNodeID;
    WheelEventTestMonitor::DeferReason m_deferReason;
};

} // namespace WebCore

#define SPECIALIZE_TYPE_TRAITS_SCROLLING_TREE(ToValueTypeName, predicate) \
SPECIALIZE_TYPE_TRAITS_BEGIN(ToValueTypeName) \
    static bool isType(const WebCore::ScrollingTree& tree) { return tree.predicate; } \
SPECIALIZE_TYPE_TRAITS_END()
#endif // ENABLE(ASYNC_SCROLLING)
