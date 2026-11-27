/*
 * Copyright (C) 2014-2017 Apple Inc. All rights reserved.
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
#if ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)

#include <WebCore/ScrollingStateScrollingNode.h>
#include <WebCore/ScrollingStateTree.h>
#include <WebCore/ScrollingTree.h>
#include <wtf/Condition.h>
#include <wtf/RefPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class AsyncScrollingCoordinator;

// A name for Swift, which cannot spell a class template specialization.
using MarkableScrollRequestIdentifier = Markable<ScrollRequestIdentifier>;

// The ThreadedScrollingTree class lives almost exclusively on the scrolling thread and manages the
// hierarchy of scrollable regions on the page. It's also responsible for dispatching events
// to the correct scrolling tree nodes or dispatching events back to the ScrollingCoordinator
// object on the main thread if they can't be handled on the scrolling thread for various reasons.
class SWIFT_PRIVATE_FILEID("WebCore/ThreadedScrollingTree.swift") ThreadedScrollingTree : public ScrollingTree {
    WTF_MAKE_TZONE_ALLOCATED(ThreadedScrollingTree);
public:
    virtual ~ThreadedScrollingTree();

    WheelEventHandlingResult handleWheelEvent(const PlatformWheelEvent&, OptionSet<WheelEventProcessingSteps>) override;

    bool handleWheelEventAfterMainThread(const PlatformWheelEvent&, ScrollingNodeID, std::optional<WheelScrollGestureState>);
    void wheelEventWasProcessedByMainThread(const PlatformWheelEvent&, std::optional<WheelScrollGestureState>);

    NODELETE WEBCORE_EXPORT void willSendEventToMainThread(const PlatformWheelEvent&);
    WEBCORE_EXPORT void waitForEventToBeProcessedByMainThread(const PlatformWheelEvent&);

    SWIFT_UNSAFE void invalidate() override;

    void displayDidRefresh(PlatformDisplayID) override;

    NODELETE void didScheduleRenderingUpdate();
    void willStartRenderingUpdate();
    virtual void didCompleteRenderingUpdate();

    Lock& treeLock() LIFETIME_BOUND WTF_RETURNS_LOCK(m_treeLock) { return m_treeLock; }

    bool scrollAnimatorEnabled() const { return m_scrollAnimatorEnabled; }
    SWIFT_UNSAFE void removePendingScrollAnimationForNode(ScrollingNodeID) WTF_REQUIRES_LOCK(m_treeLock) final;

#if ENABLE(COORDINATED_TOUCH_EVENTS)
    virtual TrackingType eventTrackingTypeForTouchEvent(const PlatformTouchEvent&) { return TrackingType::NotTracking; }
#endif

protected:
    explicit ThreadedScrollingTree(AsyncScrollingCoordinator&);

    void scrollingTreeNodeDidScroll(ScrollingTreeScrollingNode&, ScrollingLayerPositionAction = ScrollingLayerPositionAction::Sync) override;
    void scrollingTreeNodeWillStartAnimatedScroll(ScrollingTreeScrollingNode&) override;
    void scrollingTreeNodeDidStopAnimatedScroll(ScrollingTreeScrollingNode&) override;
    void scrollingTreeNodeWillStartWheelEventScroll(ScrollingTreeScrollingNode&) override;
    void scrollingTreeNodeDidStopWheelEventScroll(ScrollingTreeScrollingNode&) override;
    void didHandleScrollRequestForNode(ScrollingNodeID, ScrollRequestType, FloatPoint, ShouldFireScrollEnd, Markable<ScrollRequestIdentifier>) override;

    SWIFT_UNSAFE RequestsScrollHandling scrollingTreeNodeRequestsScroll(ScrollingNodeID, RequestedScrollData) override WTF_REQUIRES_LOCK(m_treeLock);
    SWIFT_UNSAFE bool scrollingTreeNodeRequestsKeyboardScroll(ScrollingNodeID, RequestedKeyboardScrollData) override WTF_REQUIRES_LOCK(m_treeLock);

    void addPendingScrollUpdateWithDeferReason(ScrollUpdate, WheelEventTestMonitor::DeferReason);

#if PLATFORM(MAC)
    void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) override;
#endif

    void setActiveScrollSnapIndices(ScrollingNodeID, std::optional<unsigned> horizontalIndex, std::optional<unsigned> verticalIndex) override;

#if PLATFORM(COCOA)
    void currentSnapPointIndicesDidChange(ScrollingNodeID, std::optional<unsigned> horizontal, std::optional<unsigned> vertical) override;
#endif

    void renderingUpdateComplete();

    void reportExposedUnfilledArea(MonotonicTime, unsigned unfilledArea) override;
    void reportSynchronousScrollingReasonsChanged(MonotonicTime, OptionSet<SynchronousScrollingReason>) override;

    RefPtr<AsyncScrollingCoordinator> m_scrollingCoordinator;
    SWIFT_UNAVAILABLE_IN_SWIFT mutable Lock m_layerHitTestMutex;

private:
    // ScrollingTree's protected addPendingScrollUpdate is visible only from ScrollingTree.swift's FILEID.
    void addPendingScrollUpdateForSwift(ScrollUpdate update) { addPendingScrollUpdate(WTF::move(update)); }
    bool isThreadedScrollingTree() const override { return true; }
    SWIFT_UNSAFE void propagateSynchronousScrollingReasons(const HashSet<ScrollingNodeID>&) WTF_REQUIRES_LOCK(m_treeLock) override;

    void didCommitTree() final;
    SWIFT_UNSAFE void didCommitTreeOnScrollingThread() WTF_REQUIRES_LOCK(m_treeLock);

    void displayDidRefreshOnScrollingThread();
    SWIFT_UNSAFE void waitForRenderingUpdateCompletionOrTimeout() WTF_REQUIRES_LOCK(m_treeLock);

    NODELETE SWIFT_UNSAFE bool canUpdateLayersOnScrollingThread() const WTF_REQUIRES_LOCK(m_treeLock);

    SWIFT_UNSAFE void scheduleDelayedRenderingUpdateDetectionTimer(Seconds) WTF_REQUIRES_LOCK(m_treeLock);
    void delayedRenderingUpdateDetectionTimerFired();

    void hasNodeWithAnimatedScrollChanged(bool) override;

    NODELETE SWIFT_UNSAFE bool isScrollingSynchronizedWithMainThread() final WTF_REQUIRES_LOCK(m_treeLock);

    void receivedWheelEventWithPhases(PlatformWheelEventPhase, PlatformWheelEventPhase) final;
    void deferWheelEventTestCompletionForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) final;
    void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) final;

    SWIFT_UNSAFE void lockLayersForHitTesting() final WTF_ACQUIRES_LOCK(m_layerHitTestMutex);
    SWIFT_UNSAFE void unlockLayersForHitTesting() final WTF_RELEASES_LOCK(m_layerHitTestMutex);

    void scrollingTreeNodeScrollUpdated(ScrollingTreeScrollingNode&, ScrollUpdateType);
    // Swift cannot construct ScrollUpdate's Variant member.
    static ScrollUpdate scrollUpdate(ScrollingNodeID nodeID, ScrollUpdateType updateType) { return { .nodeID = nodeID, .scrollPosition = { }, .data = ScrollUpdateData { .updateType = updateType } }; }
    static ScrollUpdate scrollRequestResponse(ScrollingNodeID nodeID, FloatPoint scrollPosition, ShouldFireScrollEnd shouldFireScrollEnd, ScrollRequestType requestType) { return { .nodeID = nodeID, .scrollPosition = scrollPosition, .shouldFireScrollEnd = shouldFireScrollEnd, .data = ScrollRequestResponseData { .requestType = requestType } }; }

    void didAddPendingScrollUpdate() override;

#ifdef __BLOCKS__
    // For Swift, whose @Sendable blocks cannot capture the coordinator: runs block on the main run loop with the
    // coordinator this tree has when this is called, as the C++ blocks capture it, or does nothing if it has none.
    void dispatchToScrollingCoordinator(void (^ __attribute__((swift_attr("@Sendable"))) block)(AsyncScrollingCoordinator*)) __attribute__((nonnull(2)));
#endif

    enum class SynchronizationState : uint8_t {
        Idle,
        WaitingForRenderingUpdate,
        InRenderingUpdate,
        Desynchronized,
    };

    SWIFT_UNAVAILABLE_IN_SWIFT SynchronizationState m_state WTF_GUARDED_BY_LOCK(m_treeLock) { SynchronizationState::Idle };
    SWIFT_UNAVAILABLE_IN_SWIFT Condition m_stateCondition;

    SWIFT_UNAVAILABLE_IN_SWIFT bool m_receivedBeganEventFromMainThread WTF_GUARDED_BY_LOCK(m_treeLock) { false };
    SWIFT_UNAVAILABLE_IN_SWIFT Condition m_waitingForBeganEventCondition;
    
    MonotonicTime m_lastDisplayDidRefreshTime;

    // Dynamically allocated because it has to use the ScrollingThread's runloop.
    SWIFT_UNAVAILABLE_IN_SWIFT std::unique_ptr<RunLoop::Timer> m_delayedRenderingUpdateDetectionTimer WTF_GUARDED_BY_LOCK(m_treeLock);

    SWIFT_UNAVAILABLE_IN_SWIFT HashMap<ScrollingNodeID, RequestedScrollData> m_nodesWithPendingScrollAnimations WTF_GUARDED_BY_LOCK(m_treeLock);
    SWIFT_UNAVAILABLE_IN_SWIFT HashMap<ScrollingNodeID, RequestedKeyboardScrollData> m_nodesWithPendingKeyboardScrollAnimations WTF_GUARDED_BY_LOCK(m_treeLock);
    const bool m_scrollAnimatorEnabled { false };
    SWIFT_UNAVAILABLE_IN_SWIFT bool m_hasNodesWithSynchronousScrollingReasons WTF_GUARDED_BY_LOCK(m_treeLock) { false };
    std::atomic<bool> m_renderingUpdateWasScheduled;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_SCROLLING_TREE(WebCore::ThreadedScrollingTree, isThreadedScrollingTree())

#endif // ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)
