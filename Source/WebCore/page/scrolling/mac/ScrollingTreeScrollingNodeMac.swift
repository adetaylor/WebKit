// Copyright (C) 2012, 2014-2015 Apple Inc. All rights reserved.
// Copyright (C) 2019 Apple Inc. All rights reserved.
// Copyright (C) 2019-2023 Apple Inc. All rights reserved.
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

// The Mac frame, overflow and plugin scrolling nodes' bodies.

#if os(macOS)

internal import QuartzCore
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNodeMac
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollingNodeMac
internal import WebCore_Private.Core.ScrollingTreePluginScrollingNodeMac
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import WebCore_Private.Core.WebCoreCALayerExtras
internal import wtf

extension WebCore.ScrollingTreeFrameScrollingNodeMac {
    @cxx
    @implementation
    public override func minimumScrollPosition() -> WebCore.FloatPoint {
        var position = WebCore.FloatPoint() - scrollOriginSize

        if isRootNode() && liveScrollingTree.scrollPinningBehavior() == .PinToBottom {
            position.setY(maximumScrollPositionForSwift().y())
        }

        return position
    }

    @cxx
    @implementation
    public override func maximumScrollPosition() -> WebCore.FloatPoint {
        let contentSizePoint = WebCore.FloatPoint(rubberBandTotalContentsSize) - scrollableAreaSize()
        var position = (contentSizePoint - scrollOriginSize).expandedTo(WebCore.FloatPoint())

        if isRootNode() && liveScrollingTree.scrollPinningBehavior() == .PinToTop {
            position.setY(minimumScrollPositionForSwift().y())
        }

        return position
    }

    /// Tells the tree whether the main frame is pinned to each edge.
    @cxx
    @implementation
    public func updateMainFramePinAndRubberbandState() {
        assert(isRootNode())
        liveScrollingTree.setMainFramePinnedState(edgePinnedState())
    }

    /// Starts the rubber-band animation back to the edge.
    @cxx
    @implementation
    public func startRubberBandSnapBack() {
        delegate().startRubberBandSnapBack()
    }

    /// Retargets a running rubber-band animation.
    @cxx
    @implementation
    public func rubberBandTargetOffsetDidChange() {
        delegate().rubberBandTargetOffsetDidChange()
    }

    @cxx
    @implementation
    public override func willBeDestroyed() {
        delegate().nodeWillBeDestroyed()
    }

    @cxx
    @implementation
    public override func handleWheelEvent(
        _ wheelEvent: WebCore.PlatformWheelEvent,
        _ eventTargeting: WebCore.EventTargeting
    ) -> WebCore.WheelEventHandlingResult {
        if !canHandleWheelEventForSwift(wheelEvent, eventTargeting) {
            return .unhandled(.init())
        }

        // FIXME: <https://webkit.org/b/310912> Stale momentum events from scroll gestures continue
        // to dispatch across page reloads. Until this problem is solved, absorb wheel events during
        // rubberband restoration to prevent interference.
        if restoredRubberbandingInProgress() {
            return .handled(.init())
        }

        // The event deltas are in view pixels but this tree scrolls in unscaled content coordinates, so without
        // this a tick would cover scale times too much content.
        let scale = delegatedPageScaleFactor()
        let handled = delegate().handleWheelEvent(scale == 1 ? wheelEvent : wheelEvent.copyScalingDeltas(scale))
        delegate().updateSnapScrollState()
        return .result(handled)
    }

    private var liveScrollingTree: WebCore.ScrollingTree {
        guard let scrollingTree = scrollingTree().get() else {
            preconditionFailure("a node is used only while its tree is alive")
        }
        return scrollingTree
    }

    private var scrollOriginSize: WebCore.FloatSize { WebCore.toFloatSize(WebCore.FloatPoint(scrollOrigin())) }
}

extension WebCore.ScrollingTreeScrollingNode {
    // repositionScrollingLayers() of the overflow and plugin scrolling nodes.
    fileprivate func moveScrollContainerLayerToScrollOffset() {
        let scrollOffset = currentScrollOffset()
        let origin = CGPoint(x: CGFloat(scrollOffset.x()), y: CGFloat(scrollOffset.y()))
        scrollContainerPlatformLayer()?._web_setLayerBoundsOrigin(origin)
    }
}

extension WebCore.ScrollingTreeOverflowScrollingNodeMac {
    @cxx
    @implementation
    public override func willBeDestroyed() {
        delegate().nodeWillBeDestroyed()
    }

    @cxx
    @implementation
    public override func handleWheelEvent(
        _ wheelEvent: WebCore.PlatformWheelEvent,
        _ eventTargeting: WebCore.EventTargeting
    ) -> WebCore.WheelEventHandlingResult {
        if hasNonRepaintSynchronousScrollingReasons() && eventTargeting != .NodeOnly {
            var result = WebCore.WheelEventHandlingResult()
            result.steps = .fromRaw(
                WebCore.WheelEventProcessingSteps.SynchronousScrolling.rawValue
                    | WebCore.WheelEventProcessingSteps.NonBlockingDOMEventDispatch.rawValue)
            return result
        }

        if !canHandleWheelEventForSwift(wheelEvent, eventTargeting) {
            return .unhandled(.init())
        }

        return .result(delegate().handleWheelEvent(wheelEvent))
    }

    @cxx
    @implementation
    public override func repositionRelatedLayers() {
        delegate().updateScrollbarPainters()
    }

    @cxx
    @implementation
    public override func repositionScrollingLayers() {
        moveScrollContainerLayerToScrollOffset()
    }
}

extension WebCore.ScrollingTreePluginScrollingNodeMac {
    @cxx
    @implementation
    public override func willBeDestroyed() {
        delegate().nodeWillBeDestroyed()
    }

    @cxx
    @implementation
    public override func repositionRelatedLayers() {
        delegate().updateScrollbarPainters()
    }

    @cxx
    @implementation
    public override func repositionScrollingLayers() {
        moveScrollContainerLayerToScrollOffset()
    }
}

#endif // os(macOS)
