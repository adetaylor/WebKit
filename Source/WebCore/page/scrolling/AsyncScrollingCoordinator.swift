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

#if ENABLE_ASYNC_SCROLLING

internal import WebCore_Private.Core.AsyncScrollingCoordinator
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.Frame
internal import WebCore_Private.Core.GraphicsLayer
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.IntSize
internal import WebCore_Private.Core.LayoutRect
internal import WebCore_Private.Core.LayoutUnit
internal import WebCore_Private.Core.LocalFrame
internal import WebCore_Private.Core.LocalFrameView
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.Page
internal import WebCore_Private.Core.ProcessQualified
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.Settings
internal import WebCore_Private.Core.ScrollingCoordinator
internal import WebCore_Private.Core.ScrollingConstraints
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingNodeID
internal import WebCore_Private.Core.ScrollingStateFrameHostingNode
internal import WebCore_Private.Core.ScrollingStateFrameScrollingNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStatePositionedNode
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import WebCore_Private.Core.ScrollingStateTree
internal import WebCore_Private.Core.ScrollingTree
internal import wtf

extension WebCore.AsyncScrollingCoordinator {
    @cxx
    @implementation
    public override func createNode(
        _ rootFrameID: WebCore.FrameIdentifier,
        _ nodeType: WebCore.ScrollingNodeType,
        _ newNodeID: WebCore.ScrollingNodeID
    ) -> WebCore.OptionalScrollingNodeID {
        logScrollingTree { stream in
            stream.appendUTF8("AsyncScrollingCoordinator::createNode ".utf8.span)
            stream.append(nodeType)
            stream.appendUTF8(" node ".utf8.span)
            stream.append(newNodeID)
        }

        let noParent = WebCore.OptionalScrollingNodeID()
        let scrollingStateTree = ensureScrollingStateTreeForRootFrameID(rootFrameID)
        // TODO: rdar://123052250 Need a better way to fix scrolling tree in iframe process
        let rootStateNode = scrollingStateTree.rootStateNode()
        if let rootNode = rootStateNode.get() {
            if rootNode.scrollingNodeID().isEqual(newNodeID) {
                return scrollingStateTree.insertNode(nodeType, newNodeID, noParent, 0)
            }
        } else if nodeType == .Subframe {
            return scrollingStateTree.insertNode(nodeType, newNodeID, noParent, 0)
        }
        return .init(scrollingStateTree.createUnparentedNode(nodeType, newNodeID))
    }

    @cxx
    @implementation
    public override func insertNode(
        _ rootFrameID: WebCore.FrameIdentifier,
        _ nodeType: WebCore.ScrollingNodeType,
        _ newNodeID: WebCore.ScrollingNodeID,
        _ parentID: WebCore.OptionalScrollingNodeID,
        _ childIndex: Int
    ) -> WebCore.OptionalScrollingNodeID {
        logScrollingTree { stream in
            stream.appendUTF8("AsyncScrollingCoordinator::insertNode ".utf8.span)
            stream.append(nodeType)
            stream.appendUTF8(" node ".utf8.span)
            stream.append(newNodeID)
            stream.appendUTF8(" parent ".utf8.span)
            stream.append(parentID)
            stream.appendUTF8(" index ".utf8.span)
            stream.append(UInt(childIndex))
        }

        return ensureScrollingStateTreeForRootFrameID(rootFrameID).insertNode(nodeType, newNodeID, parentID, childIndex)
    }

    @cxx
    @implementation
    public override func unparentNode(_ nodeID: WebCore.ScrollingNodeID) {
        if let stateTree = stateTreeForNodeID(.init(nodeID)) {
            stateTree.unparentNode(.init(nodeID))
        }
    }

    @cxx
    @implementation
    public override func unparentChildrenAndDestroyNode(_ nodeID: WebCore.OptionalScrollingNodeID) {
        if let stateTree = stateTreeForNodeID(nodeID) {
            stateTree.unparentChildrenAndDestroyNode(nodeID)
        }
    }

    @cxx
    @implementation
    public override func detachAndDestroySubtree(_ nodeID: WebCore.ScrollingNodeID) {
        if let stateTree = stateTreeForNodeID(.init(nodeID)) {
            stateTree.detachAndDestroySubtree(.init(nodeID))
        }
    }

    @cxx
    @implementation
    public override func clearAllNodes(_ rootFrameID: WebCore.FrameIdentifier) {
        ensureScrollingStateTreeForRootFrameID(rootFrameID).clear()
    }

    @cxx
    @implementation
    public override func parentOfNode(_ nodeID: WebCore.ScrollingNodeID) -> WebCore.OptionalScrollingNodeID {
        guard let scrollingNode = stateNodeForNodeID(.init(nodeID)).get() else {
            return .init()
        }

        return scrollingNode.parentNodeID()
    }

    @cxx
    @implementation
    public override func setLayerHostingContextIdentifierForFrameHostingNode(
        _ scrollingNodeID: WebCore.ScrollingNodeID,
        _ identifier: WebCore.OptionalLayerHostingContextIdentifier
    ) {
        let stateNode = stateNodeForNodeID(.init(scrollingNodeID)).get().flatMap { WebCore.asScrollingStateFrameHostingNode($0) }
        assert(stateNode != nil)
        guard let stateNode else {
            return
        }

        stateNode.setLayerHostingContextIdentifier(identifier)
    }

    @cxx
    @implementation
    public override func setSynchronousScrollingReasons(
        _ nodeID: WebCore.OptionalScrollingNodeID,
        _ reasons: WebCore.SynchronousScrollingReasons
    ) {
        guard let stateNode = stateNodeForNodeID(nodeID).get(),
            let scrollingStateNode = WebCore.asScrollingStateScrollingNode(stateNode)
        else {
            return
        }

        if !reasons.isEmpty() && scrollingStateNode.isFrameScrollingNode() {
            // The LocalFrameView's GraphicsLayer is likely to be out-of-synch with the PlatformLayer
            // at this point. So we'll update it before we switch back to main thread scrolling
            // in order to avoid layer positioning bugs.
            if let frameView = frameViewForScrollingNode(nodeID) {
                reconcileScrollPosition(frameView, .Set)
            }
        }

        // FIXME: Ideally all the "synchronousScrollingReasons" functions should be #ifdeffed.
        #if ENABLE_SCROLLING_THREAD
        scrollingStateNode.setSynchronousScrollingReasons(reasons)
        #endif
    }

    @cxx
    @implementation
    public override func synchronousScrollingReasons(
        _ nodeID: WebCore.OptionalScrollingNodeID
    ) -> WebCore.SynchronousScrollingReasons {
        #if ENABLE_SCROLLING_THREAD
        guard let stateNode = stateNodeForNodeID(nodeID).get(),
            let scrollingStateNode = WebCore.asScrollingStateScrollingNode(stateNode)
        else {
            return .init()
        }

        return scrollingStateNode.synchronousScrollingReasons()
        #else
        return .init()
        #endif
    }

    @cxx
    @implementation
    public func scrollingStateTreePropertiesChanged() {
        scheduleTreeStateCommit()
    }

    @cxx
    @implementation
    public func scrollingThreadAddedPendingUpdate() {
        scheduleRenderingUpdate()
    }

    @cxx
    @implementation
    public func setAllScrollingStatePropertiesChangedForRootFrameID(_ rootFrameID: WebCore.FrameIdentifier) {
        guard let stateTree = existingScrollingStateTreeForRootFrameID(.init(rootFrameID)) else {
            return
        }

        stateTree.setAllPropertiesChanged()
        scheduleTreeStateCommit()
    }

    @cxx
    @implementation
    public override func willCommitTree(_ rootFrameID: WebCore.FrameIdentifier) {
        updateEventTrackingRegions(rootFrameID)
    }

    @cxx
    @implementation
    public override func frameViewLayoutUpdated(_ frameView: WebCore.LocalFrameView) {
        assertIsMainThreadWithPage()

        m_eventTrackingRegionsDirty = true

        // If there isn't a root node yet, don't do anything. We'll be called again after creating one.
        guard stateNodeForNodeID(frameView.scrollingNodeID()).get() != nil else {
            return
        }

        // We have to schedule a commit, but the computed non-fast region may not have actually changed.
        // FIXME: This needs to disambiguate between event regions in the scrolling tree, and those in GraphicsLayers.
        scheduleTreeStateCommit()

        #if canImport(Darwin) // PLATFORM(COCOA)
        if !coordinatesScrollingForFrameView(frameView) {
            return
        }

        if let page = frameView.frame().page(), page.isMonitoringWheelEvents() {
            guard let frameScrollingNode = frameScrollingStateNode(for: frameView) else {
                return
            }

            frameScrollingNode.setIsMonitoringWheelEvents(page.isMonitoringWheelEvents())
        }
        #endif
    }

    @cxx
    @implementation
    public override func frameViewVisualViewportChanged(_ frameView: WebCore.LocalFrameView) {
        assertIsMainThreadWithPage()

        if !coordinatesScrollingForFrameView(frameView) {
            return
        }

        // If the root layer does not have a ScrollingStateNode, then we should create one.
        guard let frameScrollingNode = frameScrollingStateNode(for: frameView) else {
            return
        }

        frameScrollingNode.setVisualViewportIsSmallerThanLayoutViewport(frameView.visualViewportIsSmallerThanLayoutViewport)

        // visibleSize() shrinks as the page zooms in, but a stale scale size leaves the zoomed-in page
        // nowhere to scroll, so the tree clamps away the position the zoom anchored to
        frameScrollingNode.setScrollableAreaSize(WebCore.FloatSize(frameView.visibleSize()))
    }

    @cxx
    @implementation
    public override func updateIsMonitoringWheelEventsForFrameView(_ frameView: borrowing WebCore.LocalFrameView) {
        guard let page = frameView.frame().page() else {
            return
        }

        guard let frameScrollingNode = frameScrollingStateNode(for: frameView) else {
            return
        }

        frameScrollingNode.setIsMonitoringWheelEvents(page.isMonitoringWheelEvents())
    }

    @cxx
    @implementation
    public override func applyScrollingTreeLayerPositions() {
        // swift-format-ignore: NeverForceUnwrap
        scrollingTree()!.applyLayerPositions()
    }

    @cxx
    @implementation
    public func reconcileScrollPosition(
        _ frameView: WebCore.LocalFrameView,
        _ scrollingLayerPositionAction: WebCore.ScrollingLayerPositionAction
    ) {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) // PLATFORM(IOS_FAMILY)
        // Doing all scrolling like this (UIScrollView style) would simplify code.
        guard let scrollContainerLayer = scrollContainerLayer(for: frameView) else {
            return
        }

        let boundsOrigin = WebCore.FloatPoint(frameView.scrollPosition())
        if scrollingLayerPositionAction == .Set {
            scrollContainerLayer.setBoundsOrigin(boundsOrigin)
        } else {
            scrollContainerLayer.syncBoundsOrigin(boundsOrigin)
        }
        #else
        // This uses scrollPosition because the root content layer accounts for scrollOrigin (see LocalFrameView::positionForRootContentLayer()).
        guard let scrolledContentsLayer = scrolledContentsLayer(for: frameView) else {
            return
        }

        let scrollPosition = frameView.scrollPosition()
        let position = WebCore.FloatPoint(WebCore.IntPoint(-scrollPosition.x(), -scrollPosition.y()))
        if scrollingLayerPositionAction == .Set {
            scrolledContentsLayer.setPosition(position)
        } else {
            scrolledContentsLayer.syncPosition(position)
        }
        #endif
    }

    @cxx
    @implementation
    public override func scrollBySimulatingWheelEventForTesting(_ nodeID: WebCore.ScrollingNodeID, _ delta: WebCore.FloatSize) {
        if let scrollingTree = scrollingTree() {
            scrollingTree.scrollBySimulatingWheelEventForTesting(nodeID, delta)
        }
    }

    @cxx
    @implementation
    public override func isUserScrollInProgress(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let scrollingTree = scrollingTree() else {
            return false
        }

        return scrollingTree.isUserScrollInProgressForNode(nodeID)
    }

    @cxx
    @implementation
    public override func isRubberBandInProgress(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let scrollingTree = scrollingTree() else {
            return false
        }

        return scrollingTree.isRubberBandInProgressForNode(nodeID)
    }

    @cxx
    @implementation
    public override func isScrollSnapInProgress(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let scrollingTree = scrollingTree() else {
            return false
        }

        return scrollingTree.isScrollSnapInProgressForNode(nodeID)
    }

    @cxx
    @implementation
    public override func setScrollPinningBehavior(_ pinning: WebCore.ScrollPinningBehavior) {
        // swift-format-ignore: NeverForceUnwrap
        scrollingTree()!.setScrollPinningBehavior(pinning)
    }

    @cxx
    @implementation
    public override func haveScrollingTree() -> Bool {
        scrollingTree() != nil
    }

    @cxx
    @implementation
    public override func hasSubscrollers(_ rootFrameID: WebCore.FrameIdentifier) -> Bool {
        guard let scrollingStateTree = existingScrollingStateTreeForRootFrameID(.init(rootFrameID)) else {
            return false
        }

        return scrollingStateTree.scrollingNodeCount() > 1
    }

    @cxx
    @implementation
    public func scrollAnimatorEnabled() -> Bool {
        assert(WTF.isMainThread())
        // swift-format-ignore: NeverForceUnwrap
        guard let localMainFrame = scrollingPage!.localMainFrame() else {
            return false
        }

        return localMainFrame.settings().scrollAnimatorEnabled()
    }

    @cxx
    @implementation
    public func scheduleRenderingUpdate() {
        if let page = scrollingPage {
            page.scheduleRenderingUpdate(.init(WebCore.RenderingUpdateStep.ScrollingTreeUpdate))
        }
    }

    @cxx
    @implementation
    public override func windowScreenDidChange(
        _ displayID: WebCore.PlatformDisplayID,
        _ nominalFramesPerSecond: WebCore.OptionalFramesPerSecond
    ) {
        scrollingTree()?.windowScreenDidChange(displayID, nominalFramesPerSecond)
    }

    @cxx
    @implementation
    public override func setPositionedNodeConstraints(
        _ nodeID: WebCore.ScrollingNodeID,
        _ constraints: WebCore.AbsolutePositionConstraints
    ) {
        guard let node = stateNodeForNodeID(.init(nodeID)).get() else {
            return
        }

        let positionedNode = WebCore.asScrollingStatePositionedNode(node)
        assert(positionedNode != nil)
        positionedNode?.updateConstraints(constraints)
    }

    @cxx
    @implementation
    public override func reconcileViewportConstrainedLayerPositions(
        _ scrollingNodeID: WebCore.OptionalScrollingNodeID,
        _ viewportRect: WebCore.LayoutRect,
        _ action: WebCore.ScrollingLayerPositionAction
    ) {
        logScrollingTree { stream in
            stream.appendUTF8("AsyncScrollingCoordinator::reconcileViewportConstrainedLayerPositions for node ".utf8.span)
            stream.append(scrollingNodeID)
        }

        if let stateTree = stateTreeForNodeID(scrollingNodeID) {
            stateTree.reconcileViewportConstrainedLayerPositions(scrollingNodeID, viewportRect, action)
        }
    }
}

extension WebCore.AsyncScrollingCoordinator {
    @cxx
    @implementation
    public override func frameViewWillBeDetached(_ frameView: WebCore.LocalFrameView) {
        assertIsMainThreadWithPage()

        guard coordinatesScrollingForFrameView(frameView) else {
            return
        }

        scrollableAreaWillBeDetached(stateNode(for: frameView), frameView.scrollPosition())
    }

    @cxx
    @implementation
    public func scrollableAreaWillBeDetached(_ stateNode: WebCore.ScrollingStateNode?, _ scrollPosition: WebCore.IntPoint) {
        assertIsMainThreadWithPage()

        guard let node = scrollingStateScrollingNode(stateNode) else {
            return
        }

        node.setScrollPosition(WebCore.FloatPoint(scrollPosition))
    }

    @cxx
    @implementation
    public func requestStartKeyboardScrollAnimation(
        _ stateNode: WebCore.ScrollingStateNode?,
        _ scrollData: WebCore.KeyboardScroll
    ) -> Bool {
        assertIsMainThreadWithPage()

        guard let stateNode = scrollingStateScrollingNode(stateNode) else {
            return false
        }

        var keyboardScrollData = WebCore.RequestedKeyboardScrollData()
        keyboardScrollData.action = .StartAnimation
        keyboardScrollData.keyboardScroll = .init(scrollData)
        stateNode.setKeyboardScrollData(keyboardScrollData)
        // FIXME: This should schedule a rendering update
        commitTreeStateIfNeeded()
        return true
    }

    @cxx
    @implementation
    public func requestStopKeyboardScrollAnimation(_ stateNode: WebCore.ScrollingStateNode?, _ immediate: Bool) -> Bool {
        assertIsMainThreadWithPage()

        guard let stateNode = scrollingStateScrollingNode(stateNode) else {
            return false
        }

        var keyboardScrollData = WebCore.RequestedKeyboardScrollData()
        keyboardScrollData.action = immediate ? .StopImmediately : .StopWithAnimation
        stateNode.setKeyboardScrollData(keyboardScrollData)
        // FIXME: This should schedule a rendering update
        commitTreeStateIfNeeded()
        return true
    }

    @cxx
    @implementation
    public func stopAnimatedScroll(_ nodeID: WebCore.OptionalScrollingNodeID, _ stateNode: WebCore.ScrollingStateNode?) {
        assertIsMainThreadWithPage()

        guard let scrollingNodeID = Optional(fromCxx: nodeID) else {
            return
        }

        guard let frameView = frameViewForScrollingNode(nodeID), coordinatesScrollingForFrameView(frameView) else {
            return
        }

        guard let stateNode = scrollingStateScrollingNode(stateNode) else {
            return
        }

        var requestedScrollData = WebCore.RequestedScrollData()
        requestedScrollData.requestType = .CancelAnimatedScroll

        willSendScrollPositionRequest(scrollingNodeID, &requestedScrollData)
        stateNode.setRequestedScrollData(consuming: requestedScrollData)

        // FIXME: This should schedule a rendering update
        commitTreeStateIfNeeded()
    }

    @cxx
    @implementation
    public func setScrollbarLayoutDirection(
        _ stateNode: WebCore.ScrollingStateNode?,
        _ scrollbarLayoutDirection: WebCore.UserInterfaceLayoutDirection
    ) {
        assertIsMainThreadWithPage()

        scrollingStateScrollingNode(stateNode)?.setScrollbarLayoutDirection(scrollbarLayoutDirection)
    }

    @cxx
    @implementation
    public func setScrollbarColor(_ stateNode: WebCore.ScrollingStateNode?, _ scrollbarColor: WebCore.OptionalScrollbarColor) {
        assertIsMainThreadWithPage()

        scrollingStateScrollingNode(stateNode)?.setScrollbarColor(scrollbarColor)
    }

    @cxx
    @implementation
    public func setMouseIsOverContentArea(_ stateNode: WebCore.ScrollingStateNode?, _ isOverContentArea: Bool) {
        assertIsMainThreadWithPage()

        scrollingStateScrollingNode(stateNode)?.setMouseIsOverContentArea(isOverContentArea)
    }

    @cxx
    @implementation
    public func setScrollbarEnabled(
        _ stateNode: WebCore.ScrollingStateNode?,
        _ orientation: WebCore.ScrollbarOrientation,
        _ enabled: Bool
    ) {
        assertIsMainThreadWithPage()

        scrollingStateScrollingNode(stateNode)?.setScrollbarEnabledState(orientation, enabled)
    }

    @cxx
    @implementation
    public func setMouseMovedInContentArea(
        _ stateNode: WebCore.ScrollingStateNode?,
        _ locationInHorizontalScrollbar: WebCore.IntPoint,
        _ locationInVerticalScrollbar: WebCore.IntPoint
    ) {
        assertIsMainThreadWithPage()

        guard let stateNode = scrollingStateScrollingNode(stateNode) else {
            return
        }

        var state = WebCore.MouseLocationState()
        state.locationInHorizontalScrollbar = locationInHorizontalScrollbar
        state.locationInVerticalScrollbar = locationInVerticalScrollbar
        stateNode.setMouseMovedInContentArea(state)
    }

    #if !USE_COORDINATED_GRAPHICS_ASYNC_SCROLLBAR
    @cxx
    @implementation
    public func setMouseIsOverScrollbar(
        _ stateNode: WebCore.ScrollingStateNode?,
        _ orientation: WebCore.ScrollbarOrientation,
        _ isOverScrollbar: Bool
    ) {
        assertIsMainThreadWithPage()

        guard let stateNode = scrollingStateScrollingNode(stateNode) else {
            return
        }

        var hoverState = WebCore.ScrollbarHoverState()
        hoverState.mouseIsOverHorizontalScrollbar = orientation != .Vertical && isOverScrollbar
        hoverState.mouseIsOverVerticalScrollbar = orientation == .Vertical && isOverScrollbar
        stateNode.setScrollbarHoverState(hoverState)
    }
    #endif

    @cxx
    @implementation
    public func scrollbarLayerDidChange(
        _ stateNode: WebCore.ScrollingStateNode?,
        _ orientation: WebCore.ScrollbarOrientation,
        _ scrollbarLayer: WebCore.GraphicsLayer?,
        _ scrollbarLayoutDirection: WebCore.UserInterfaceLayoutDirection
    ) {
        assertIsMainThreadWithPage()

        guard let scrollingNode = scrollingStateScrollingNode(stateNode) else {
            return
        }

        if orientation == .Vertical {
            scrollingNode.setVerticalScrollbarLayer(WebCore.LayerRepresentation(scrollbarLayer))
        } else {
            scrollingNode.setHorizontalScrollbarLayer(WebCore.LayerRepresentation(scrollbarLayer))
        }
        scrollingNode.setScrollbarLayoutDirection(scrollbarLayoutDirection)
    }

    @cxx
    @implementation
    public func setScrollbarWidth(_ stateNode: WebCore.ScrollingStateNode?, _ scrollbarWidth: WebCore.ScrollbarWidth) {
        assertIsMainThreadWithPage()

        scrollingStateScrollingNode(stateNode)?.setScrollbarWidth(scrollbarWidth)
    }
}

extension WebCore.AsyncScrollingCoordinator {
    #if canImport(Darwin) // PLATFORM(COCOA)
    @cxx
    @implementation
    public override func handleWheelEventPhase(_ nodeID: WebCore.ScrollingNodeID, _ phase: WebCore.PlatformWheelEventPhase) {
        assert(WTF.isMainThread())

        guard scrollingPage != nil, let frameView = frameViewForScrollingNode(.init(nodeID)) else {
            return
        }

        WebCore.AsyncScrollingCoordinator.handleWheelEventPhase(frameView, nodeID, phase)
    }
    #endif

    @cxx
    @implementation
    public func notifyScrollableAreasForScrollEnd(_ scrollingNodeID: WebCore.ScrollingNodeID) {
        assert(WTF.isMainThread())

        guard scrollingPage != nil, let frameView = frameViewForScrollingNode(.init(scrollingNodeID)) else {
            return
        }

        WebCore.AsyncScrollingCoordinator.scrollDidEnd(frameView, scrollingNodeID)
    }

    @cxx
    @implementation
    public func setActiveScrollSnapIndices(
        _ scrollingNodeID: WebCore.ScrollingNodeID,
        _ horizontalIndex: WebCore.OptionalSnapPointIndex,
        _ verticalIndex: WebCore.OptionalSnapPointIndex
    ) {
        assert(WTF.isMainThread())

        guard scrollingPage != nil, let frameView = frameViewForScrollingNode(.init(scrollingNodeID)) else {
            return
        }

        WebCore.AsyncScrollingCoordinator.setActiveScrollSnapIndices(frameView, scrollingNodeID, horizontalIndex, verticalIndex)
    }
}

extension WebCore.AsyncScrollingCoordinator {
    @cxx
    @implementation
    public override func applyScrollUpdate(
        _ update: WebCore.ScrollUpdate,
        _ scrollType: WebCore.ScrollType,
        _ viewportStability: WebCore.ViewportRectStability
    ) {
        applyPendingScrollUpdates()
        applyScrollPositionUpdate(update, scrollType, viewportStability)
    }
}

extension WebCore.AsyncScrollingCoordinator {
    fileprivate func assertIsMainThreadWithPage() {
        assert(WTF.isMainThread())
        assert(scrollingPage != nil)
    }

    fileprivate func scrollingStateScrollingNode(_ stateNode: WebCore.ScrollingStateNode?) -> WebCore.ScrollingStateScrollingNode? {
        stateNode.flatMap(WebCore.asScrollingStateScrollingNode)
    }

    // stateNodeForScrollableArea() for a frame view.
    fileprivate func stateNode(for frameView: WebCore.LocalFrameView) -> WebCore.ScrollingStateNode? {
        let scrollingNodeID = frameView.scrollingNodeID()
        guard Optional(fromCxx: scrollingNodeID) != nil,
            let scrollingStateTree = existingScrollingStateTreeForRootFrameID(frameView.rootFrameID())
        else {
            return nil
        }

        return scrollingStateTree.stateNodeForID(scrollingNodeID).get()
    }

    // stateNodeForScrollableArea() for a frame view, as a frame scrolling node.
    fileprivate func frameScrollingStateNode(for frameView: WebCore.LocalFrameView) -> WebCore.ScrollingStateFrameScrollingNode? {
        stateNode(for: frameView).flatMap(WebCore.asScrollingStateFrameScrollingNode)
    }
}

extension WebCore.LocalFrameView {
    fileprivate var visualViewportIsSmallerThanLayoutViewport: Bool {
        let layoutViewport = layoutViewportRect()
        let visualViewport = visualViewportRect()
        return visualViewport.width().rawValue() < layoutViewport.width().rawValue()
            || visualViewport.height().rawValue() < layoutViewport.height().rawValue()
    }
}

// For ThreadedScrollingCoordinator, which cannot reach this protected member from its own file.
extension WebCore.AsyncScrollingCoordinator {
    func scheduleRenderingUpdateFromSwift() {
        scheduleRenderingUpdate()
    }
}

#endif // ENABLE_ASYNC_SCROLLING
