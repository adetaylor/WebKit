// Copyright (C) 2023-2025 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if os(macOS)

import WebKit_Internal
internal import QuartzCore
internal import Synchronization

private let maxStartRenderingUpdateDelay = 0.001
private let maximumRenderingUpdateTimeoutDelay = 0.032

private enum SynchronizationState {
    case idle
    case waitingForRenderingUpdate
    case inRenderingUpdate
    case desynchronized
}

/// What RemoteLayerTreeEventDispatcher::didRefreshDisplay() does after the scrolling tree has seen the refresh: start
/// the delayed rendering update detection timer, and update layer positions and animations once the lock is dropped.
@_expose(Cxx)
struct RemoteEventDispatcherDisplayRefreshAction {
    // @used ensures these, and the type metadata, are retained even under -O -wmo: rdar://179098545
    @used
    static let cxxTypeMetadata: Any.Type = Self.self

    fileprivate var needsUpdateLayerPositions = false
    fileprivate var renderingUpdateDetectionDelaySeconds: Double?

    fileprivate init() {
    }

    @used
    func needsUpdateLayerPositionsAndAnimations() -> Bool { needsUpdateLayerPositions }
    @used
    func schedulesRenderingUpdateDetection() -> Bool { renderingUpdateDetectionDelaySeconds != nil }
    @used
    func renderingUpdateDetectionDelay() -> Double { renderingUpdateDetectionDelaySeconds ?? .nan }
}

/// When the scrolling thread stops waiting for the main thread's rendering update, and whether that time was cut
/// back to the longest wait allowed from the time it would otherwise have been.
@_expose(Cxx)
struct RemoteEventDispatcherRenderingUpdateTimeout {
    // @used ensures these, and the type metadata, are retained even under -O -wmo: rdar://179098545
    @used
    static let cxxTypeMetadata: Any.Type = Self.self

    fileprivate var timeoutTimeValue = 0.0
    fileprivate var unclampedTimeoutTimeValue = 0.0
    fileprivate var wasClampedValue = false

    fileprivate init() {
    }

    @used
    func timeoutTime() -> Double { timeoutTimeValue }
    @used
    func unclampedTimeoutTime() -> Double { unclampedTimeoutTimeValue }
    @used
    func wasClamped() -> Bool { wasClampedValue }
}

/// The synchronization between the UI process's scrolling thread and its main thread's rendering update, for one
/// RemoteLayerTreeEventDispatcher. Its entries are called with the dispatcher's m_scrollingTreeLock held, on the
/// scrolling thread or the main thread; that lock serializes them, and the dispatcher's m_stateCondition waits on it.
@_expose(Cxx)
final class RemoteLayerTreeEventDispatcherState {
    private var state = SynchronizationState.idle
    // MonotonicTime's seconds.
    private var lastDisplayDidRefreshTime = 0.0
    // Whether the main thread must flush its transaction after the layer tree commit is applied, because the scrolling
    // thread deferred a scroll step to the rendering update or the main thread updated scroll-driven animations.
    private var needsMainThreadFlush = false

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
    }

    fileprivate func displayDidRefresh(_ now: Double) -> RemoteEventDispatcherDisplayRefreshAction {
        lastDisplayDidRefreshTime = now

        var action = RemoteEventDispatcherDisplayRefreshAction()
        action.needsUpdateLayerPositions = state != .idle

        switch state {
        case .idle:
            state = .waitingForRenderingUpdate
            action.renderingUpdateDetectionDelaySeconds = maxStartRenderingUpdateDelay
        case .waitingForRenderingUpdate, .inRenderingUpdate, .desynchronized:
            break
        }
        return action
    }

    fileprivate func willWaitForRenderingUpdate(_ renderingUpdateDetectionTimerIsActive: Bool) {
        needsMainThreadFlush = renderingUpdateDetectionTimerIsActive
    }

    fileprivate func renderingUpdateTimeout(
        _ currentTime: Double,
        _ frameDuration: Double,
        _ maxAllowableRenderingUpdateDuration: Double
    ) -> RemoteEventDispatcherRenderingUpdateTimeout {
        // std::max() and std::min() over MonotonicTime, which return their first argument when the two are equal or
        // unordered.
        let nextRefreshTime = lastDisplayDidRefreshTime + frameDuration
        let estimatedNextDisplayRefreshTime = nextRefreshTime < currentTime ? currentTime : nextRefreshTime
        let maxAllowableTime = currentTime + maxAllowableRenderingUpdateDuration
        var result = RemoteEventDispatcherRenderingUpdateTimeout()
        // std::min(maxAllowableTime, estimatedNextDisplayRefreshTime).
        result.timeoutTimeValue =
            estimatedNextDisplayRefreshTime < maxAllowableTime ? estimatedNextDisplayRefreshTime : maxAllowableTime
        result.unclampedTimeoutTimeValue = result.timeoutTimeValue

        let maximumTimeoutTime = currentTime + maximumRenderingUpdateTimeoutDelay
        if result.timeoutTimeValue > maximumTimeoutTime {
            result.timeoutTimeValue = maximumTimeoutTime
            result.wasClampedValue = true
        }
        return result
    }

    fileprivate var isIdle: Bool { state == .idle }

    fileprivate func renderingUpdateWaitTimedOut() {
        state = .desynchronized
        needsMainThreadFlush = false
    }

    fileprivate func mainThreadWillStartRenderingUpdate() -> Bool {
        // The state can be desynchronized if CommitDelayState is Delayed, since DisplayDidRefresh is then not sent to the
        // web process. There's no point trying to synchronize in that case.
        state != .desynchronized
    }

    fileprivate func mainThreadDidStartRenderingUpdate() {
        state = .inRenderingUpdate
    }

    fileprivate func renderingUpdateComplete(_ appliedAnimatedValues: Bool) -> Bool {
        let wasInRenderingUpdate = state == .inRenderingUpdate
        if appliedAnimatedValues {
            needsMainThreadFlush = true
        }
        state = .idle
        return wasInRenderingUpdate
    }

    fileprivate func takeNeedsMainThreadFlush() -> Bool {
        let result = needsMainThreadFlush
        needsMainThreadFlush = false
        return result
    }
}

/// The scrolling performance test signpost intervals of one RemoteLayerTreeEventDispatcher. Its entries are called
/// on the main thread and the scrolling thread, without a lock.
@_expose(Cxx)
final class RemoteLayerTreeEventDispatcherSignpostState: Sendable {
    fileprivate let fingerDownIntervalIsActive = Atomic(false)
    fileprivate let momentumIntervalIsActive = Atomic(false)
    fileprivate let momentumIntervalHasSeenNonZeroDeltaEvent = Atomic(false)

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
    }

    // Each interval flag is loaded, then stored, as two separate atomic operations.

    fileprivate func startFingerDownInterval() -> Bool {
        if fingerDownIntervalIsActive.load(ordering: .sequentiallyConsistent) {
            return false
        }
        fingerDownIntervalIsActive.store(true, ordering: .sequentiallyConsistent)
        return true
    }

    fileprivate func endFingerDownInterval() -> Bool {
        if !fingerDownIntervalIsActive.load(ordering: .sequentiallyConsistent) {
            return false
        }
        fingerDownIntervalIsActive.store(false, ordering: .sequentiallyConsistent)
        return true
    }

    fileprivate func startMomentumInterval() -> Bool {
        if momentumIntervalIsActive.load(ordering: .sequentiallyConsistent) {
            return false
        }
        momentumIntervalIsActive.store(true, ordering: .sequentiallyConsistent)
        momentumIntervalHasSeenNonZeroDeltaEvent.store(false, ordering: .sequentiallyConsistent)
        return true
    }

    fileprivate func endMomentumInterval() -> Bool {
        if !momentumIntervalIsActive.load(ordering: .sequentiallyConsistent) {
            return false
        }
        momentumIntervalIsActive.store(false, ordering: .sequentiallyConsistent)
        return true
    }

    fileprivate func syntheticEventEndsMomentumInterval(_ deltaHeight: Float, _ momentumPhaseEnded: Bool) -> Bool {
        let eventHasNonZeroDelta = abs(deltaHeight) > 0
        if eventHasNonZeroDelta {
            momentumIntervalHasSeenNonZeroDeltaEvent.store(true, ordering: .sequentiallyConsistent)
        }

        // FIXME: <rdar://184036413> Momentum intervals should only start with non-zero deltas.
        guard momentumIntervalIsActive.load(ordering: .sequentiallyConsistent) else {
            return false
        }
        return (!eventHasNonZeroDelta && momentumIntervalHasSeenNonZeroDeltaEvent.load(ordering: .sequentiallyConsistent))
            || momentumPhaseEnded
    }
}

/// Called on the scrolling thread with m_scrollingTreeLock held, after the scrolling tree has handled the display
/// refresh, with MonotonicTime::now()'s seconds.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherDisplayDidRefresh(
    _ state: RemoteLayerTreeEventDispatcherState,
    _ now: Double
) -> RemoteEventDispatcherDisplayRefreshAction {
    state.displayDidRefresh(now)
}

/// Called on the scrolling thread with m_scrollingTreeLock held, before it waits for the main thread's rendering
/// update, with whether the delayed rendering update detection timer is still pending: the scroll step it would have
/// committed is deferred to the rendering update, so the main thread must flush after the commit.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherWillWaitForRenderingUpdate(
    _ state: RemoteLayerTreeEventDispatcherState,
    _ renderingUpdateDetectionTimerIsActive: Bool
) {
    state.willWaitForRenderingUpdate(renderingUpdateDetectionTimerIsActive)
}

/// Called on the scrolling thread with m_scrollingTreeLock held, before it waits for the main thread's rendering
/// update. Times are MonotonicTime's seconds and durations Seconds' value.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherRenderingUpdateTimeout(
    _ state: RemoteLayerTreeEventDispatcherState,
    _ currentTime: Double,
    _ frameDuration: Double,
    _ maxAllowableRenderingUpdateDuration: Double
) -> RemoteEventDispatcherRenderingUpdateTimeout {
    state.renderingUpdateTimeout(currentTime, frameDuration, maxAllowableRenderingUpdateDuration)
}

/// Called on the scrolling thread with m_scrollingTreeLock held, from m_stateCondition's wait.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherIsIdle(_ state: RemoteLayerTreeEventDispatcherState) -> Bool {
    state.isIdle
}

/// Called on the scrolling thread with m_scrollingTreeLock held, when the main thread's rendering update did not
/// complete before the timeout.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherRenderingUpdateWaitTimedOut(_ state: RemoteLayerTreeEventDispatcherState) {
    state.renderingUpdateWaitTimedOut()
}

/// Called on the main thread with m_scrollingTreeLock held, at a display refresh while the scrolling tree is active.
/// Returns whether to wait for the scrolling thread before the rendering update.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherMainThreadWillStartRenderingUpdate(
    _ state: RemoteLayerTreeEventDispatcherState
) -> Bool {
    state.mainThreadWillStartRenderingUpdate()
}

/// Called on the main thread with m_scrollingTreeLock held, once the scrolling thread waits for the rendering update.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherMainThreadDidStartRenderingUpdate(_ state: RemoteLayerTreeEventDispatcherState) {
    state.mainThreadDidStartRenderingUpdate()
}

/// Called on the main thread with m_scrollingTreeLock held, when the rendering update is complete, with whether it
/// applied scroll-driven animation values. Returns whether the scrolling thread is waiting for it and must be woken.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherRenderingUpdateComplete(
    _ state: RemoteLayerTreeEventDispatcherState,
    _ appliedAnimatedValues: Bool
) -> Bool {
    state.renderingUpdateComplete(appliedAnimatedValues)
}

/// Called on the main thread with m_scrollingTreeLock held, after a layer tree commit is applied. Returns whether the
/// main thread must flush its transaction, and clears that need.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherTakeNeedsMainThreadFlush(_ state: RemoteLayerTreeEventDispatcherState) -> Bool {
    state.takeNeedsMainThreadFlush()
}

/// Called on the main thread or the scrolling thread. Returns whether the finger-down signpost interval begins.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherStartFingerDownInterval(_ state: RemoteLayerTreeEventDispatcherSignpostState) -> Bool {
    state.startFingerDownInterval()
}

/// Called on the main thread or the scrolling thread. Returns whether the finger-down signpost interval ends.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherEndFingerDownInterval(_ state: RemoteLayerTreeEventDispatcherSignpostState) -> Bool {
    state.endFingerDownInterval()
}

/// Called on the main thread or the scrolling thread. Returns whether the momentum signpost interval begins.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherStartMomentumInterval(_ state: RemoteLayerTreeEventDispatcherSignpostState) -> Bool {
    state.startMomentumInterval()
}

/// Called on the main thread or the scrolling thread. Returns whether the momentum signpost interval ends.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherEndMomentumInterval(_ state: RemoteLayerTreeEventDispatcherSignpostState) -> Bool {
    state.endMomentumInterval()
}

/// Called on the scrolling thread, from the momentum event dispatcher's display refresh, for each synthetic wheel event
/// while scrolling performance testing is enabled, after the interval has been started if the event's momentum phase
/// began. Returns whether the momentum signpost interval should end.
@_expose(Cxx)
@used
nonisolated func remoteEventDispatcherSyntheticEventEndsMomentumInterval(
    _ state: RemoteLayerTreeEventDispatcherSignpostState,
    _ deltaHeight: Float,
    _ momentumPhaseEnded: Bool
) -> Bool {
    state.syntheticEventEndsMomentumInterval(deltaHeight, momentumPhaseEnded)
}

// The RemoteLayerTreeEventDispatcher members below take none of its locks.
extension WebKit.RemoteLayerTreeEventDispatcher {
    /// Called on the main thread when the wheel event activity hysteresis starts or stops.
    @cxx
    @implementation
    func wheelEventHysteresisUpdated(_: PAL.HysteresisState) {
        startOrStopDisplayLink()
    }

    /// Called on the main thread or the scrolling thread.
    @cxx
    @implementation
    func hasNodeWithAnimatedScrollChanged(_: Bool) {
        startOrStopDisplayLink()
    }

    /// Called on the main thread.
    @cxx
    @implementation
    func windowScreenWillChange() {
        removeDisplayLinkClient()
    }

    /// Called on the scrolling thread, by the timer scheduleDelayedRenderingUpdateDetectionTimer() starts.
    @cxx
    @implementation
    func delayedRenderingUpdateDetectionTimerFired() {
        assert(WebCore.ScrollingThread.isCurrentThread())
        updateLayerPositionsAndAnimations()
    }

    #if ENABLE_MOMENTUM_EVENT_DISPATCHER
    /// Called on the main thread when a scrolling node starts rubber-banding.
    @cxx
    @implementation
    func didStartRubberbanding() {
        endFingerDownSignpostInterval()
        endMomentumSignpostInterval()
    }

    /// Called by the momentum event dispatcher on the scrolling thread.
    @cxx
    @implementation
    func startDisplayDidRefreshCallbacks(_: WebCore.PlatformDisplayID) {
        assert(!m_momentumEventDispatcherNeedsDisplayLink)
        m_momentumEventDispatcherNeedsDisplayLink = true
        startOrStopDisplayLink()
    }
    #endif
}

// MARK: Wheel events

extension WebKit.RemoteLayerTreeEventDispatcher {
    @cxx
    @implementation
    func scrollingThreadHandleWheelEvent(
        _ webWheelEvent: borrowing WebKit.WebWheelEvent,
        _ rubberBandableEdges: WebCore.RectEdgesRubberBandingBehavior
    ) {
        assert(WebCore.ScrollingThread.isCurrentThread())

        guard let scrollingTree = scrollingTree().get() else {
            return
        }

        let hitTest = WebCore.ScrollingTree.HitTestLocker(scrollingTree)

        let platformWheelEvent = WebKit.platform(webWheelEvent)
        let processingSteps = determineWheelEventProcessing(hitTest, platformWheelEvent, rubberBandableEdges)

        // Do this before the event is handled here or in the web process, so that it stops springs whichever scroller handles it.
        scrollingTree.stopSpringAnimationsForWheelEvent(hitTest, platformWheelEvent)

        if processingSteps.contains(.SynchronousScrolling) {
            scrollingTree.willSendEventForDefaultHandling(platformWheelEvent)
            wheelEventWasHandledByScrollingThread(.unhandled(processingSteps))
            // Wait for the web process to respond to the event, preventing the next event from being handled until we get a response or time out,
            // allowing us to know if this gesture should be come non-blocking.
            scrollingTree.waitForEventDefaultHandlingCompletion(platformWheelEvent)
            CATransaction.flush()
            return
        }

        #if ENABLE_MOMENTUM_EVENT_DISPATCHER
        do {
            let momentumEventDispatcher = lockMomentumEventDispatcher()
            if momentumEventDispatcher.handleWheelEvent(hitTest, webWheelEvent, rubberBandableEdges) {
                wheelEventWasHandledByScrollingThread(.handled(processingSteps))
                CATransaction.flush()
                return
            }
        }
        #endif

        wheelEventWasHandledByScrollingThread(internalHandleWheelEvent(hitTest, platformWheelEvent, processingSteps))
        CATransaction.flush()
    }
}

// MARK: Display link

extension WebKit.RemoteLayerTreeEventDispatcher {
    @cxx
    @implementation
    func startOrStopDisplayLinkOnMainThread() {
        assert(WTF.isMainRunLoop())

        if needsDisplayLink {
            startDisplayLinkObserver()
        } else {
            stopDisplayLinkObserver()
        }
    }

    @cxx
    @implementation
    func haveLayersWithAnimations() -> Bool {
        #if ENABLE_THREADED_ANIMATIONS
        return lockAnimations().hasAnimationStacks()
        #else
        return false
        #endif
    }

    private var needsDisplayLink: Bool {
        #if ENABLE_MOMENTUM_EVENT_DISPATCHER
        if m_momentumEventDispatcherNeedsDisplayLink {
            return true
        }
        #endif
        if wheelEventActivityStarted() {
            return true
        }

        #if ENABLE_THREADED_ANIMATIONS
        do {
            let animations = lockAnimations()
            if animations.monotonicTimelinesNonEmpty() {
                return true
            }
        }
        #endif

        guard let scrollingTree = scrollingTree().get() else {
            return false
        }
        return scrollingTree.hasNodeWithActiveScrollAnimations()
    }

    @cxx
    @implementation
    func windowScreenDidChange(
        _ displayID: WebCore.PlatformDisplayID,
        _ nominalFramesPerSecond: WebCore.OptionalFramesPerSecond
    ) {
        #if ENABLE_MOMENTUM_EVENT_DISPATCHER
        do {
            let momentumEventDispatcher = lockMomentumEventDispatcher()
            momentumEventDispatcher.pageScreenDidChange(displayID, nominalFramesPerSecond)
        }
        #endif
        if let scrollingTree = scrollingTree().get() {
            scrollingTree.windowScreenDidChange(displayID, nominalFramesPerSecond)
        }

        // FIXME: Restart the displayLink if necessary.
    }
}

#endif // os(macOS)
