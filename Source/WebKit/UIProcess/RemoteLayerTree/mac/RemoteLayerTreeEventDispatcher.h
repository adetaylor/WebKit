/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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

#if PLATFORM(MAC)

#include "DisplayLinkObserverID.h"
#include "MomentumEventDispatcher.h"
#include "NativeWebWheelEvent.h"
#include <WebCore/PlatformLayerIdentifier.h>
#include <WebCore/ProcessQualified.h>
#include <WebCore/ScrollingLockedAccess.h>
#include <pal/HysteresisActivity.h>
#include <wtf/Condition.h>
#include <wtf/Deque.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/threads/BinarySemaphore.h>

#if ENABLE(THREADED_ANIMATIONS)
#include "RemoteAnimationStack.h"
#include "RemoteMonotonicTimelineRegistry.h"
#endif
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
#include "RemoteScrollingTree.h"
#endif

namespace WebCore {
#if ENABLE(THREADED_ANIMATIONS)
class AcceleratedTimeline;
#endif
class PlatformWheelEvent;
class WheelEventDeltaFilter;
struct FrameIdentifierType;
struct WheelEventHandlingResult;
struct ScrollingNodeIDType;
using FrameIdentifier = ObjectIdentifier<FrameIdentifierType>;
using ScrollingNodeID = ProcessQualified<ObjectIdentifier<ScrollingNodeIDType>>;
enum class WheelScrollGestureState : uint8_t;
enum class WheelEventProcessingSteps : uint8_t;
};

namespace WebKit {

class DisplayLink;
class NativeWebWheelEvent;
#if ENABLE(THREADED_ANIMATIONS)
class RemoteAnimationTimeline;
class RemoteProgressBasedTimeline;
#endif
class RemoteScrollingCoordinatorProxyMac;
class RemoteLayerTreeDrawingAreaProxyMac;
class RemoteLayerTreeNode;
class RemoteScrollingTree;
class RemoteLayerTreeEventDispatcherDisplayLinkClient;
class RemoteLayerTreeEventDispatcherSignpostState;
class RemoteLayerTreeEventDispatcherState;
#if ENABLE(THREADED_ANIMATIONS)
class RemoteLayerTreeAnimationsAccess;
#endif
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
class RemoteLayerTreeMomentumEventDispatcherAccess;
#endif
class WebProcessPool;

// This class exists to act as a threadsafe DisplayLink::Client client, allowing RemoteScrollingCoordinatorProxyMac to
// be main-thread only. It's the UI-process analogue of WebPage/EventDispatcher.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteLayerTreeEventDispatcher.swift") RemoteLayerTreeEventDispatcher
    : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<RemoteLayerTreeEventDispatcher, WTF::DestructionThread::MainRunLoop>
    , public MomentumEventDispatcher::Client {
    WTF_MAKE_TZONE_ALLOCATED(RemoteLayerTreeEventDispatcher);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RemoteLayerTreeEventDispatcher);
    friend class RemoteLayerTreeEventDispatcherDisplayLinkClient;
#if ENABLE(THREADED_ANIMATIONS)
    friend class RemoteLayerTreeAnimationsAccess;
#endif
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    friend class RemoteLayerTreeMomentumEventDispatcherAccess;
#endif
public:
    static Ref<RemoteLayerTreeEventDispatcher> create(RemoteScrollingCoordinatorProxyMac&, WebCore::PageIdentifier);

    explicit RemoteLayerTreeEventDispatcher(RemoteScrollingCoordinatorProxyMac&, WebCore::PageIdentifier);
    ~RemoteLayerTreeEventDispatcher();
    
    void invalidate();
    
    void cacheWheelEventScrollingAccelerationCurve(const NativeWebWheelEvent&);

    void handleWheelEvent(Ref<WebWheelEvent>, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges);
    void wheelEventHandlingCompleted(const WebCore::PlatformWheelEvent&, std::optional<WebCore::FrameIdentifier> defaultHandlingFrameID, std::optional<WebCore::ScrollingNodeID>, std::optional<WebCore::WheelScrollGestureState>, bool wasHandled);

    void setScrollingTree(RefPtr<RemoteScrollingTree>&&);

    void didRefreshDisplay(WebCore::PlatformDisplayID);
    void mainThreadDisplayDidRefresh(WebCore::PlatformDisplayID);

    void hasNodeWithAnimatedScrollChanged(bool hasAnimatedScrolls);

    void windowScreenWillChange();
    void windowScreenDidChange(WebCore::PlatformDisplayID, std::optional<WebCore::FramesPerSecond>);

    void renderingUpdateComplete();
    void flushMainThreadTransactionIfNeeded();

#if ENABLE(THREADED_ANIMATIONS)
    SWIFT_UNSAFE void lockForAnimationChanges() WTF_ACQUIRES_LOCK(m_animationLock);
    SWIFT_UNSAFE void unlockForAnimationChanges() WTF_RELEASES_LOCK(m_animationLock);
    void animationsWereAddedToNode(RemoteLayerTreeNode&);
    void animationsWereRemovedFromNode(RemoteLayerTreeNode&);
    void updateTimelinesRegistration(WebCore::ProcessIdentifier, const WebCore::AcceleratedTimelinesUpdate&, MonotonicTime);
    void removeTimelines(WebCore::ProcessIdentifier);
    RefPtr<const RemoteAnimationTimeline> timeline(const TimelineID&);
    RefPtr<const RemoteAnimationStack> animationStackForNodeWithIDForTesting(WebCore::PlatformLayerIdentifier) const;
    HashSet<Ref<RemoteProgressBasedTimeline>> timelinesForScrollingNodeIDForTesting(WebCore::ScrollingNodeID);
    HashSet<Ref<RemoteMonotonicTimeline>> monotonicTimelinesForProcessForTesting(WebCore::ProcessIdentifier) const;
#endif

private:
    // hitTest proves the tree's layers are held; handleSyntheticWheelEvent() passes none, its callers hold them.
    OptionSet<WebCore::WheelEventProcessingSteps> determineWheelEventProcessing(const WebCore::ScrollingTree::HitTestLocker& hitTest, const WebCore::PlatformWheelEvent& wheelEvent, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges) { return determineWheelEventProcessing(wheelEvent, rubberBandableEdges, &hitTest); }
    SWIFT_UNSAFE OptionSet<WebCore::WheelEventProcessingSteps> determineWheelEventProcessing(const WebCore::PlatformWheelEvent&, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges, const WebCore::ScrollingTree::HitTestLocker*);

    void scrollingThreadHandleWheelEvent(const WebWheelEvent&, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges);
    WebCore::WheelEventHandlingResult internalHandleWheelEvent(const WebCore::ScrollingTree::HitTestLocker& hitTest, const WebCore::PlatformWheelEvent& wheelEvent, OptionSet<WebCore::WheelEventProcessingSteps> processingSteps) { return internalHandleWheelEvent(wheelEvent, processingSteps, &hitTest); }
    SWIFT_UNSAFE WebCore::WheelEventHandlingResult internalHandleWheelEvent(const WebCore::PlatformWheelEvent&, OptionSet<WebCore::WheelEventProcessingSteps>, const WebCore::ScrollingTree::HitTestLocker*);

    WebCore::PlatformWheelEvent filteredWheelEvent(const WebCore::PlatformWheelEvent&);

    void wheelEventHysteresisUpdated(PAL::HysteresisState);
    // For Swift: PAL::HysteresisActivity is an unsafe type in Swift.
    bool wheelEventActivityStarted() const { return m_wheelEventActivityHysteresis.state() == PAL::HysteresisState::Started; }

    void willHandleWheelEvent(Ref<WebWheelEvent>);
    void continueWheelEventHandling(WebCore::WheelEventHandlingResult);
    // For Swift, which cannot pass a closure to callOnMainRunLoop() safely.
    void wheelEventWasHandledByScrollingThread(WebCore::WheelEventHandlingResult);

    DisplayLink* displayLink() const;
    DisplayLink* existingDisplayLink() const;
    NODELETE RemoteLayerTreeDrawingAreaProxyMac& drawingAreaMac() const;

    void startDisplayLinkObserver();
    void stopDisplayLinkObserver();

    void startOrStopDisplayLink();
    void startOrStopDisplayLinkOnMainThread();
    void removeDisplayLinkClient();

    void scheduleDelayedRenderingUpdateDetectionTimer(Seconds delay);
    void delayedRenderingUpdateDetectionTimerFired();

    bool scrollingThreadNeedsDisplayDidRefresh();
    bool scrollingTreeWasRecentlyActive();
    bool haveLayersWithAnimations();

    SWIFT_UNSAFE void waitForRenderingUpdateCompletionOrTimeout() WTF_REQUIRES_LOCK(m_scrollingTreeLock);

    void startFingerDownSignpostInterval();
    void endFingerDownSignpostInterval();
    void startMomentumSignpostInterval();
    void endMomentumSignpostInterval();

    void didStartRubberbanding();

    void updateLayerPositionsAndAnimations();
#if ENABLE(THREADED_ANIMATIONS)
    enum class AnimationStacksToUpdate : bool { All, ProgressBasedOnly };
    bool updateAnimations(AnimationStacksToUpdate = AnimationStacksToUpdate::All);
#endif

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    SWIFT_UNSAFE void handleSyntheticWheelEvent(WebCore::PageIdentifier, const WebWheelEvent&, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges);
    SWIFT_UNSAFE void startDisplayDidRefreshCallbacks(WebCore::PlatformDisplayID);
    SWIFT_UNSAFE void stopDisplayDidRefreshCallbacks(WebCore::PlatformDisplayID);
#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)
    void flushMomentumEventLoggingSoon();
#endif
#endif

    RefPtr<RemoteScrollingTree> scrollingTree();

    // For Swift: each takes its lock and holds it until the returned object goes out of scope.
#if ENABLE(THREADED_ANIMATIONS)
    SCROLLING_UNAVAILABLE_FROM_ASYNC inline RemoteLayerTreeAnimationsAccess lockAnimations();
#endif
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    SCROLLING_UNAVAILABLE_FROM_ASYNC inline RemoteLayerTreeMomentumEventDispatcherAccess lockMomentumEventDispatcher();
#endif

    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_scrollingTreeLock;
    SWIFT_UNAVAILABLE_IN_SWIFT RefPtr<RemoteScrollingTree> m_scrollingTree WTF_GUARDED_BY_LOCK(m_scrollingTreeLock);

    SWIFT_UNAVAILABLE_IN_SWIFT Deque<Ref<WebWheelEvent>, 2> m_wheelEventsBeingProcessed; // FIXME: Remove

    const WeakPtr<RemoteScrollingCoordinatorProxyMac> m_scrollingCoordinator;
    WebCore::PageIdentifier m_pageIdentifier;
    const WeakPtr<WebProcessPool> m_processPool;

    const std::unique_ptr<WebCore::WheelEventDeltaFilter> m_wheelEventDeltaFilter;
    SWIFT_UNAVAILABLE_IN_SWIFT std::unique_ptr<RemoteLayerTreeEventDispatcherDisplayLinkClient> m_displayLinkClient;
    std::optional<DisplayLinkObserverID> m_displayRefreshObserverID;
    PAL::HysteresisActivity m_wheelEventActivityHysteresis;

    const std::unique_ptr<RemoteLayerTreeEventDispatcherSignpostState> m_signpostState;

    SWIFT_UNAVAILABLE_IN_SWIFT const std::unique_ptr<RemoteLayerTreeEventDispatcherState> m_synchronizationState WTF_POINTEE_GUARDED_BY_LOCK(m_scrollingTreeLock);
    SWIFT_UNAVAILABLE_IN_SWIFT Condition m_stateCondition;

    SWIFT_UNAVAILABLE_IN_SWIFT std::unique_ptr<RunLoop::Timer> m_delayedRenderingUpdateDetectionTimer;

#if ENABLE(THREADED_ANIMATIONS)
    // For WTF_ACQUIRES_LOCK
    friend class RemoteScrollingCoordinatorProxyMac;
    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_animationLock;
    SWIFT_UNAVAILABLE_IN_SWIFT HashMap<WebCore::PlatformLayerIdentifier, Ref<RemoteAnimationStack>> m_animationStacks WTF_GUARDED_BY_LOCK(m_animationLock);
    SWIFT_UNAVAILABLE_IN_SWIFT std::unique_ptr<RemoteMonotonicTimelineRegistry> m_monotonicTimelineRegistry WTF_GUARDED_BY_LOCK(m_animationLock);
#endif

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    bool m_momentumEventDispatcherNeedsDisplayLink { false };
    SWIFT_UNAVAILABLE_IN_SWIFT Lock m_momentumEventDispatcherLock;
    SWIFT_UNAVAILABLE_IN_SWIFT std::unique_ptr<MomentumEventDispatcher> m_momentumEventDispatcher WTF_GUARDED_BY_LOCK(m_momentumEventDispatcherLock);
#endif
};

#if ENABLE(THREADED_ANIMATIONS)
// Holds m_animationLock for its lifetime, for Swift
// (WebCore/ScrollingLockedAccess.h): whether it has animations, by value.
class SCROLLING_LOCK_HOLDER_ATTRIBUTES RemoteLayerTreeAnimationsAccess {
    using AnimationStacks = HashMap<WebCore::PlatformLayerIdentifier, Ref<RemoteAnimationStack>>;
    SCROLLING_LOCK_HOLDER(RemoteLayerTreeAnimationsAccess, RemoteLayerTreeEventDispatcher, &RemoteLayerTreeEventDispatcher::m_animationLock, AnimationStacks, &RemoteLayerTreeEventDispatcher::m_animationStacks, stacks);
public:
    bool hasAnimationStacks() const { return !stacks().isEmpty(); }
    bool monotonicTimelinesNonEmpty() const { return registry() && !registry()->isEmpty(); }

private:
    std::unique_ptr<RemoteMonotonicTimelineRegistry>& registry() const WTF_IGNORES_THREAD_SAFETY_ANALYSIS { return m_owner->m_monotonicTimelineRegistry; }
};

inline RemoteLayerTreeAnimationsAccess RemoteLayerTreeEventDispatcher::lockAnimations() { return RemoteLayerTreeAnimationsAccess { *this }; }
#endif

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
// Holds m_momentumEventDispatcherLock for its lifetime, for Swift (WebCore/ScrollingLockedAccess.h). The
// momentum event dispatcher is reached only through these members, each a call the C++ makes under the lock, for the
// dispatcher's page; each does nothing (or returns false) once invalidate() has dropped it.
class SCROLLING_LOCK_HOLDER_ATTRIBUTES RemoteLayerTreeMomentumEventDispatcherAccess {
    SCROLLING_LOCK_HOLDER(RemoteLayerTreeMomentumEventDispatcherAccess, RemoteLayerTreeEventDispatcher, &RemoteLayerTreeEventDispatcher::m_momentumEventDispatcherLock, std::unique_ptr<MomentumEventDispatcher>, &RemoteLayerTreeEventDispatcher::m_momentumEventDispatcher, dispatcher);
public:
    // Whether the momentum event dispatcher took the event. Its synthetic events hit test the dispatcher's tree, so
    // hitTest must hold that tree's layers (taken before this lock, as the C++ does).
    bool handleWheelEvent(const WebCore::ScrollingTree::HitTestLocker& hitTest, const WebWheelEvent& event, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges) const
    {
        RefPtr tree = m_owner->scrollingTree();
        RELEASE_ASSERT(!tree || hitTest.holdsLayersOf(*tree));
        return dispatcher() && dispatcher()->handleWheelEvent(m_owner->m_pageIdentifier, event, rubberBandableEdges);
    }
    void pageScreenDidChange(WebCore::PlatformDisplayID displayID, std::optional<WebCore::FramesPerSecond> nominalFramesPerSecond) const
    {
        if (dispatcher())
            dispatcher()->pageScreenDidChange(m_owner->m_pageIdentifier, displayID, nominalFramesPerSecond);
    }
};

inline RemoteLayerTreeMomentumEventDispatcherAccess RemoteLayerTreeEventDispatcher::lockMomentumEventDispatcher() { return RemoteLayerTreeMomentumEventDispatcherAccess { *this }; }
#endif

} // namespace WebKit

#endif // PLATFORM(MAC)
