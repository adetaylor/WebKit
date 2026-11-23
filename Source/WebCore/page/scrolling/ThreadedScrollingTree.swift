// Copyright (C) 2014-2015 Apple Inc. All rights reserved.
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

#if ENABLE_ASYNC_SCROLLING && ENABLE_SCROLLING_THREAD

internal import WebCore_Private.Core.AsyncScrollingCoordinator
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.ProcessQualified
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollingCoordinator
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import WebCore_Private.Core.ThreadedScrollingTree
internal import WebCore_Private.ScrollPhysicsTypes
internal import wtf.Core.MonotonicTime
internal import wtf

extension WebCore.ThreadedScrollingTree {
    @cxx
    @implementation
    public override func scrollingTreeNodeWillStartAnimatedScroll(_ node: WebCore.ScrollingTreeScrollingNode) {
        scrollingTreeNodeScrollUpdated(node, .AnimatedScrollWillStart)
    }

    @cxx
    @implementation
    public override func scrollingTreeNodeDidStopAnimatedScroll(_ node: WebCore.ScrollingTreeScrollingNode) {
        scrollingTreeNodeScrollUpdated(node, .AnimatedScrollDidEnd)
    }

    @cxx
    @implementation
    public override func scrollingTreeNodeWillStartWheelEventScroll(_ node: WebCore.ScrollingTreeScrollingNode) {
        scrollingTreeNodeScrollUpdated(node, .WheelEventScrollWillStart)
    }

    @cxx
    @implementation
    public override func scrollingTreeNodeDidStopWheelEventScroll(_ node: WebCore.ScrollingTreeScrollingNode) {
        scrollingTreeNodeScrollUpdated(node, .WheelEventScrollDidEnd)
    }

    @cxx
    @implementation
    public func didCompleteRenderingUpdate() {
        renderingUpdateComplete()
    }
}

// MARK: Scroll updates

extension WebCore.ThreadedScrollingTree {
    @cxx
    @implementation
    public override func didHandleScrollRequestForNode(
        _ nodeID: WebCore.ScrollingNodeID,
        _ requestType: WebCore.ScrollRequestType,
        _ scrollPosition: WebCore.FloatPoint,
        _ shouldFireScrollEnd: WebCore.ShouldFireScrollEnd,
        _: WebCore.MarkableScrollRequestIdentifier
    ) {
        guard let scrollingCoordinator = m_scrollingCoordinator.get() else {
            return
        }
        apply(Self.scrollRequestResponse(nodeID, scrollPosition, shouldFireScrollEnd, requestType), to: scrollingCoordinator)
    }

    @cxx
    @implementation
    func scrollingTreeNodeScrollUpdated(_ node: WebCore.ScrollingTreeScrollingNode, _ scrollUpdateType: WebCore.ScrollUpdateType) {
        guard let scrollingCoordinator = m_scrollingCoordinator.get() else {
            return
        }
        logScrolling { stream in
            stream.appendUTF8("ThreadedScrollingTree::scrollingTreeNodeScrollUpdated ".utf8.span)
            stream.append(node.scrollingNodeID())
            stream.appendUTF8(" update type ".utf8.span)
            stream.append(scrollUpdateType)
        }
        apply(Self.scrollUpdate(node.scrollingNodeID(), scrollUpdateType), to: scrollingCoordinator)
    }

    private func apply(_ update: consuming WebCore.ScrollUpdate, to scrollingCoordinator: WebCore.AsyncScrollingCoordinator) {
        if WTF.RunLoop.isMain() {
            let scrollType = WebCore.ScrollType.User
            let viewportRectStability = WebCore.ViewportRectStability.Stable
            scrollingCoordinator.applyScrollUpdate(consume update, scrollType, viewportRectStability)
            return
        }
        addPendingScrollUpdateForSwift(consume update)
    }
}

// MARK: Main thread notifications

extension WebCore.ThreadedScrollingTree {
    @cxx
    @implementation
    public override func reportSynchronousScrollingReasonsChanged(
        _ timestamp: WTF.MonotonicTime,
        _ reasons: WebCore.SynchronousScrollingReasons
    ) {
        dispatchToScrollingCoordinator { $0?.reportSynchronousScrollingReasonsChanged(timestamp, reasons) }
    }

    @cxx
    @implementation
    public override func reportExposedUnfilledArea(_ timestamp: WTF.MonotonicTime, _ unfilledArea: UInt32) {
        dispatchToScrollingCoordinator { $0?.reportExposedUnfilledArea(timestamp, unfilledArea) }
    }

    #if canImport(Darwin)
    @cxx
    @implementation
    public override func currentSnapPointIndicesDidChange(
        _ nodeID: WebCore.ScrollingNodeID,
        _ horizontal: WebCore.OptionalSnapPointIndex,
        _ vertical: WebCore.OptionalSnapPointIndex
    ) {
        dispatchToScrollingCoordinator { $0?.setActiveScrollSnapIndices(nodeID, horizontal, vertical) }
    }
    #endif

    #if os(macOS)
    @cxx
    @implementation
    public override func handleWheelEventPhase(_ nodeID: WebCore.ScrollingNodeID, _ phase: WebCore.PlatformWheelEventPhase) {
        dispatchToScrollingCoordinator { $0?.handleWheelEventPhase(nodeID, phase) }
    }
    #endif

    @cxx
    @implementation
    public override func setActiveScrollSnapIndices(
        _ nodeID: WebCore.ScrollingNodeID,
        _ horizontalIndex: WebCore.OptionalSnapPointIndex,
        _ verticalIndex: WebCore.OptionalSnapPointIndex
    ) {
        dispatchToScrollingCoordinator { $0?.setActiveScrollSnapIndices(nodeID, horizontalIndex, verticalIndex) }
    }

    @cxx
    @implementation
    public override func hasNodeWithAnimatedScrollChanged(_ hasNodeWithAnimatedScroll: Bool) {
        dispatchToScrollingCoordinator { $0?.hasNodeWithAnimatedScrollChanged(hasNodeWithAnimatedScroll) }
    }

    @cxx
    @implementation
    public override func receivedWheelEventWithPhases(
        _ phase: WebCore.PlatformWheelEventPhase,
        _ momentumPhase: WebCore.PlatformWheelEventPhase
    ) {
        dispatchToScrollingCoordinator { $0?.receivedWheelEventWithPhases(phase, momentumPhase) }
    }

    @cxx
    @implementation
    public override func deferWheelEventTestCompletionForReason(
        _ nodeID: WebCore.ScrollingNodeID,
        _ reason: WebCore.WheelEventTestMonitorDeferReason
    ) {
        guard isMonitoringWheelEvents() else {
            return
        }
        dispatchToScrollingCoordinator { $0?.deferWheelEventTestCompletionForReason(nodeID, reason) }
    }

    @cxx
    @implementation
    public override func removeWheelEventTestCompletionDeferralForReason(
        _ nodeID: WebCore.ScrollingNodeID,
        _ reason: WebCore.WheelEventTestMonitorDeferReason
    ) {
        guard isMonitoringWheelEvents() else {
            return
        }
        dispatchToScrollingCoordinator { $0?.removeWheelEventTestCompletionDeferralForReason(nodeID, reason) }
    }
}

#endif
