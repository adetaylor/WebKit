// Copyright (C) 2012 Apple Inc. All rights reserved.
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

internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.RenderLayerCompositor
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollingCoordinator
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import WebCore_Private.ScrollPhysicsTypes
internal import wtf

// The bits scrollingNodeEdgePinnedState() returns.
private struct ScrollingNodePinnedEdges: OptionSet {
    let rawValue: UInt8

    static let top = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let left = Self(rawValue: 1 << 3)
}

extension WebCore.ScrollingTreeScrollingNode {
    // The commit callbacks below read the state node through its Swift accessors and test its changed properties as
    // raw bits the C++ caller passes, and each keeps its cold calls in an @inline(never) function, so that on the common
    // path a callback's only opaque call is its last. Swift retains a foreign reference it holds (self, the state node)
    // around an opaque call, an imported getter or an OptionSet member included, after which it uses the reference
    // again, and takes that retain at entry for any path that needs it (docs/interop-limitations.md 56). The bits come
    // from the caller because they are the base class's private field, which Swift reaches on a derived node only
    // through a call or an upcast that copies the node.
    @cxx
    @implementation
    func commitScrollingNodeState(
        _ state: borrowing WebCore.ScrollingStateScrollingNode,
        _ changedProperties: UInt64
    ) {
        commitScrollingNodeProperties(state, .init(rawValue: changedProperties))
    }

    // What commitStateBeforeChildren() commits for every scrolling node, which the frame node's override commits after
    // its own fields; inlined into commitScrollingNodeState(), its only caller, on the commit path.
    @inline(always)
    private func commitScrollingNodeProperties(
        _ state: borrowing WebCore.ScrollingStateScrollingNode,
        _ changedProperties: ScrollingStateChangedProperties
    ) {
        if changedProperties.contains(.ScrollableAreaSize) {
            m_scrollableAreaSize = state.scrollableAreaSizeValue
        }

        let previousTotalContentsSize = m_totalContentsSize
        let totalContentsSizeChanged = changedProperties.contains(.TotalContentsSize)
        if totalContentsSizeChanged {
            m_totalContentsSize = state.totalContentsSizeValue
        }

        if changedProperties.contains(.ReachableContentsSize) {
            m_reachableContentsSize = state.reachableContentsSizeValue
        }

        let scrollPositionChanged = changedProperties.contains(.ScrollPosition)
        if scrollPositionChanged {
            m_lastCommittedScrollPosition = state.scrollPositionValue
        }

        if changedProperties.contains(.ScrollOrigin) {
            m_scrollOrigin = state.scrollOriginValue
        }

        if changedProperties.contains(.CurrentHorizontalSnapOffsetIndex) {
            m_currentHorizontalSnapPointIndex = state.currentHorizontalSnapPointIndexValue
        }

        if changedProperties.contains(.CurrentVerticalSnapOffsetIndex) {
            m_currentVerticalSnapPointIndex = state.currentVerticalSnapPointIndexValue
        }

        #if ENABLE_SCROLLING_THREAD
        if changedProperties.contains(.ReasonsForSynchronousScrolling) {
            m_synchronousScrollingReasons = state.synchronousScrollingReasonsValue
        }
        #endif

        let primesFirstCommitScrollPosition = scrollPositionChanged && m_isFirstCommit
        if primesFirstCommitScrollPosition || totalContentsSizeChanged {
            commitFirstCommitAndRubberBandProperties(
                state, primesFirstCommitScrollPosition, totalContentsSizeChanged, previousTotalContentsSize)
        } else {
            unsafe commitNonTrivialStateProperties(state) // U5(m_treeLock): held by commitTreeState()'s Locker, which commits this node
        }
    }

    // The rest of commitScrollingNodeProperties() on a first commit that scrolls or a commit that changes the contents
    // size, in the same order: the calls these make before the last one would make the common path retain both nodes.
    @inline(never)
    private func commitFirstCommitAndRubberBandProperties(
        _ state: borrowing WebCore.ScrollingStateScrollingNode,
        _ primesFirstCommitScrollPosition: Bool,
        _ totalContentsSizeChanged: Bool,
        _ previousTotalContentsSize: WebCore.FloatSize
    ) {
        if primesFirstCommitScrollPosition {
            // If the first commit contains a scroll delta, prime m_currentScrollPosition so we apply
            // the delta relative to it later (otherwise we'll apply the delta relative to (0,0) and
            // end up with the wrong scroll position). For an absolute position request, leave
            // m_currentScrollPosition untouched so that handleScrollPositionRequests() actually scrolls;
            // scrollTo() early-returns when the destination equals m_currentScrollPosition, which would
            // skip the layer/viewport update for the initial programmatic scroll.
            if let deltaForFirstCommit = state.firstRequestedScrollDelta {
                m_currentScrollPosition = m_lastCommittedScrollPosition - deltaForFirstCommit
            } else if !state.hasScrollPositionRequest() {
                m_currentScrollPosition = m_lastCommittedScrollPosition
            }
        }

        if totalContentsSizeChanged {
            let optionalNodeID = WebCore.OptionalScrollingNodeID(scrollingNodeID())
            let isRubberBandInProgress = withScrollingTree { $0.isRubberBandInProgressForNode(optionalNodeID) }
            m_totalContentsSizeForRubberBand = isRubberBandInProgress ? previousTotalContentsSize : m_totalContentsSize
        }

        unsafe commitNonTrivialStateProperties(state) // U5(m_treeLock): held by commitTreeState()'s Locker, which commits this node
    }

    @cxx
    @implementation
    func commitScrollingNodeStateAfterChildren(
        _ scrollingStateNode: borrowing WebCore.ScrollingStateScrollingNode,
        _ changedPropertiesRaw: UInt64
    ) {
        let changedProperties = ScrollingStateChangedProperties(rawValue: changedPropertiesRaw)
        // Only commitStateBeforeChildren() reads it.
        m_isFirstCommit = false

        if changedProperties.contains(.RequestedScrollPosition) || changedProperties.contains(.KeyboardScrollData) {
            commitRequestedScrolls(scrollingStateNode, changedProperties)
        } else {
            clearDescendantSynchronousScrollingReason()
        }
    }

    // The rest of commitScrollingNodeStateAfterChildren() when the state node requests a scroll, in the same order: the
    // requests' calls would make the common path retain both nodes.
    @inline(never)
    private func commitRequestedScrolls(
        _ scrollingStateNode: borrowing WebCore.ScrollingStateScrollingNode,
        _ changedProperties: ScrollingStateChangedProperties
    ) {
        if changedProperties.contains(.RequestedScrollPosition) {
            unsafe handleRequestedScrollPositions(scrollingStateNode) // U5(m_treeLock): the caller holds it
        }

        if changedProperties.contains(.KeyboardScrollData) {
            unsafe requestKeyboardScroll(scrollingStateNode.keyboardScrollData()) // U5(m_treeLock): the caller holds it
        }

        clearDescendantSynchronousScrollingReason()
    }

    // This synthetic bit is added back in ScrollingTree::propagateSynchronousScrollingReasons().
    @inline(always)
    private func clearDescendantSynchronousScrollingReason() {
        #if ENABLE_SCROLLING_THREAD
        // One C++ call, the body's last: building the OptionSet in Swift is a call of its own, after which Swift
        // retains self for the remove (docs/interop-limitations.md 56).
        removeSynchronousScrollingReason(.DescendantScrollersHaveSynchronousScrolling)
        #endif
    }

    @cxx
    @implementation
    public func requestKeyboardScroll(_ scrollData: WebCore.RequestedKeyboardScrollData) {
        _ = withScrollingTree { unsafe $0.scrollingTreeNodeRequestsKeyboardScroll(scrollingNodeID(), scrollData) } // U5(m_treeLock): the caller holds it
    }

    @cxx
    @implementation
    public func minimumScrollPosition() -> WebCore.FloatPoint {
        WebCore.FloatPoint() - scrollOriginSize
    }

    @cxx
    @implementation
    public func maximumScrollPosition() -> WebCore.FloatPoint {
        let contentSizePoint = WebCore.FloatPoint(totalContentsSize())
        let maximumScrollOffset = (contentSizePoint - scrollableAreaSize()).expandedTo(WebCore.FloatPoint())
        return maximumScrollOffset - scrollOriginSize
    }

    @cxx
    @implementation
    public func currentScrollPositionChanged(_ scrollType: WebCore.ScrollType, _ action: WebCore.ScrollingLayerPositionAction) {
        m_scrolledSinceLastCommit = true
        withScrollingTree { $0.scrollingTreeNodeDidScroll(self, action) }
    }

    @cxx
    @implementation
    public func scrollPositionAndLayoutViewportMatch(
        _ position: WebCore.FloatPoint,
        _ overrideLayoutViewport: WebCore.OptionalFloatRect
    ) -> Bool {
        position == m_currentScrollPosition
    }

    @cxx
    @implementation
    public override func didCompleteCommitForNode() {
        m_scrolledSinceLastCommit = false
    }

    @cxx
    @implementation
    public func clampScrollPosition(_ scrollPosition: WebCore.FloatPoint) -> WebCore.FloatPoint {
        scrollPosition.constrainedBetween(minimumScrollPositionForSwift(), maximumScrollPositionForSwift())
    }

    // Calls body with the node's tree, which the RefPtr keeps alive for the call.
    private func withScrollingTree<Result>(_ body: (WebCore.ScrollingTree) -> Result) -> Result {
        let tree = scrollingTree()
        return body(tree.get()!)
    }

    private var scrollOriginSize: WebCore.FloatSize { WebCore.toFloatSize(WebCore.FloatPoint(scrollOrigin())) }

    // The protected totalContentsSizeForRubberBand(), for the platform subclasses.
    var rubberBandTotalContentsSize: WebCore.FloatSize { totalContentsSizeForRubberBand() }

    @cxx
    @implementation
    public func clampedCurrentScrollOffset() -> WebCore.FloatPoint {
        let unconstrainedScrollPosition = currentScrollPosition()
        let clampedScrollPosition = clampScrollPosition(unconstrainedScrollPosition)
        return clampedScrollPosition + scrollOriginSize
    }

    @cxx
    @implementation
    public func isUserScrollInProgress() -> Bool {
        let (tree, nodeID) = scrollingTreeAndNodeID
        let optionalNodeID = WebCore.OptionalScrollingNodeID(nodeID)
        return tree.get()!.isUserScrollInProgressForNode(optionalNodeID)
    }

    @cxx
    @implementation
    public func setUserScrollInProgress(_ isUserScrolling: Bool) {
        let (tree, nodeID) = scrollingTreeAndNodeID
        tree.get()!.setUserScrollInProgressForNode(nodeID, isUserScrolling)
    }

    @cxx
    @implementation
    public func isScrollSnapInProgress() -> Bool {
        let (tree, nodeID) = scrollingTreeAndNodeID
        let optionalNodeID = WebCore.OptionalScrollingNodeID(nodeID)
        return tree.get()!.isScrollSnapInProgressForNode(optionalNodeID)
    }

    @cxx
    @implementation
    public func setScrollSnapInProgress(_ isSnapping: Bool) {
        let (tree, nodeID) = scrollingTreeAndNodeID
        tree.get()!.setNodeScrollSnapInProgress(nodeID, isSnapping)
    }

    @cxx
    @implementation
    public func willStartAnimatedScroll() {
        withScrollingTree { $0.scrollingTreeNodeWillStartAnimatedScroll(self) }
    }

    @cxx
    @implementation
    public func didStopAnimatedScroll() {
        if !isScrollSnapInProgress() {
            logScrolling { stream in
                stream.appendUTF8("ScrollingTreeScrollingNode ".utf8.span)
                stream.append(scrollingNodeID())
                stream.appendUTF8(" didStopAnimatedScroll".utf8.span)
            }
            withScrollingTree { $0.scrollingTreeNodeDidStopAnimatedScroll(self) }
        }
    }

    @cxx
    @implementation
    public func willStartWheelEventScroll() {
        withScrollingTree { $0.scrollingTreeNodeWillStartWheelEventScroll(self) }
    }

    @cxx
    @implementation
    public func didStopWheelEventScroll() {
        if !isScrollSnapInProgress() {
            withScrollingTree { $0.scrollingTreeNodeDidStopWheelEventScroll(self) }
        }
    }

    @cxx
    @implementation
    public func setScrollAnimationInProgress(_ animationInProgress: Bool) {
        withScrollingTree { $0.setScrollAnimationInProgressForNode(.init(scrollingNodeID()), animationInProgress) }
    }

    @cxx
    @implementation
    public func scrollBy(_ delta: WebCore.FloatSize, _ clamp: WebCore.ScrollClamping) {
        unsafe scrollTo(currentScrollPosition() + delta, .User, clamp) // U5(m_treeLock): the caller holds it
    }

    @cxx
    @implementation
    public func scrollTo(_ position: WebCore.FloatPoint, _ scrollType: WebCore.ScrollType, _ clamp: WebCore.ScrollClamping) {
        if position == m_currentScrollPosition {
            return
        }

        let tree = scrollingTree()
        tree.get()!.setIsHandlingProgrammaticScroll(scrollType == .Programmatic)

        if scrollType == .Programmatic {
            willDoProgrammaticScroll(position)
        }

        m_currentScrollPosition = adjustedScrollPosition(position, clamp)

        logScrolling { stream in
            stream.appendUTF8("ScrollingTreeScrollingNode ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" scrollTo ".utf8.span)
            stream.append(position)
            stream.appendUTF8(" adjusted to ".utf8.span)
            stream.append(m_currentScrollPosition)
            stream.appendUTF8(" (".utf8.span)
            stream.append(scrollType)
            stream.appendUTF8(", ".utf8.span)
            stream.append(clamp)
            stream.appendUTF8(") (delta from last committed position ".utf8.span)
            stream.append(m_lastCommittedScrollPosition - m_currentScrollPosition)
            stream.appendUTF8(")".utf8.span)
            stream.appendUTF8(" rubberbanding ".utf8.span)
            stream.append(tree.get()!.isRubberBandInProgressForNode(.init(scrollingNodeID())))
        }

        let noOverrideLayoutViewport = WebCore.OptionalFloatRect()
        updateViewportForCurrentScrollPositionForSwift(noOverrideLayoutViewport)
        currentScrollPositionChangedForSwift(scrollType, .Sync)

        tree.get()!.setIsHandlingProgrammaticScroll(false)
    }

    @cxx
    @implementation
    public override func applyLayerPositions() {
        unsafe repositionScrollingLayers() // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
        unsafe repositionRelatedLayers() // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
    }

    @cxx
    @implementation
    public func wasScrolledByDelegatedScrolling(
        _ position: WebCore.FloatPoint,
        _ overrideLayoutViewport: WebCore.OptionalFloatRect,
        _ scrollingLayerPositionAction: WebCore.ScrollingLayerPositionAction
    ) {
        let scrollPositionChanged = !scrollPositionAndLayoutViewportMatchForSwift(position, overrideLayoutViewport)
        if !scrollPositionChanged && scrollingLayerPositionAction != .Set {
            return
        }

        m_currentScrollPosition = adjustedScrollPosition(position, .Unclamped)
        updateViewportForCurrentScrollPositionForSwift(overrideLayoutViewport)

        unsafe repositionRelatedLayers() // U5(m_treeLock): the caller holds it, or runs on the tree's only thread

        let tree = scrollingTree()
        unsafe tree.get()!.notifyRelatedNodesAfterScrollPositionChange(self) // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
        tree.get()!.scrollingTreeNodeDidScroll(self, scrollingLayerPositionAction)
    }

    @cxx
    @implementation
    public func currentHorizontalSnapPointIndex() -> WebCore.OptionalSnapPointIndex {
        m_currentHorizontalSnapPointIndex
    }

    @cxx
    @implementation
    public func currentVerticalSnapPointIndex() -> WebCore.OptionalSnapPointIndex {
        m_currentVerticalSnapPointIndex
    }

    @cxx
    @implementation
    public func setCurrentHorizontalSnapPointIndex(_ index: WebCore.OptionalSnapPointIndex) {
        m_currentHorizontalSnapPointIndex = index
    }

    @cxx
    @implementation
    public func setCurrentVerticalSnapPointIndex(_ index: WebCore.OptionalSnapPointIndex) {
        m_currentVerticalSnapPointIndex = index
    }

    @cxx
    @implementation
    public func takeScrollbarRevealBehaviorForNextScrollbarUpdate() -> WebCore.ScrollbarRevealBehavior {
        exchange(&m_scrollbarRevealBehaviorForNextScrollbarUpdate, with: .Default)
    }

    @cxx
    @implementation
    public func scrollbarVisibilityDidChange(_ orientation: WebCore.ScrollbarOrientation, _ isVisible: Bool) {
        if let scrollingTree = scrollingTree().get() {
            scrollingTree.scrollingTreeNodeScrollbarVisibilityDidChange(scrollingNodeID(), orientation, isVisible)
        }
    }

    @cxx
    @implementation
    public func scrollbarMinimumThumbLengthDidChange(_ orientation: WebCore.ScrollbarOrientation, _ minimumThumbLength: Int32) {
        if let scrollingTree = scrollingTree().get() {
            scrollingTree.scrollingTreeNodeScrollbarMinimumThumbLengthDidChange(scrollingNodeID(), orientation, minimumThumbLength)
        }
    }

    @cxx
    @implementation
    public func allowsHorizontalScrolling() -> Bool {
        m_scrollableAreaParameters.allowsHorizontalScrolling
    }

    @cxx
    @implementation
    public func allowsVerticalScrolling() -> Bool {
        m_scrollableAreaParameters.allowsVerticalScrolling
    }

    @cxx
    @implementation
    public func edgePinnedState() -> WebCore.RubberBandingEdges {
        let pinnedEdges = scrollingNodeEdgePinnedState(
            currentScrollPosition(),
            minimumScrollPositionForSwift(),
            maximumScrollPositionForSwift(),
            allowsHorizontalScrolling(),
            allowsVerticalScrolling()
        )
        let edges = ScrollingNodePinnedEdges(rawValue: pinnedEdges)
        return .init(edges.contains(.top), edges.contains(.right), edges.contains(.bottom), edges.contains(.left))
    }

    @cxx
    @implementation
    public func isLatchedNode() -> Bool {
        guard let latchedNodeID = Optional(fromCxx: withScrollingTree { $0.latchedNodeID() }) else {
            return false
        }
        return latchedNodeID.isEqual(scrollingNodeID())
    }

    @cxx
    @implementation
    public func shouldRubberBandOnSide(_ side: WebCore.BoxSide, _ pinnedEdges: WebCore.RubberBandingEdges) -> Bool {
        pinnedEdges[side]
            && scrollingNodeShouldRubberBandOnSide(
                side,
                isRootNode(),
                withScrollingTree { $0.clientAllowsMainFrameRubberBandingOnSide(side) },
                overscrollBehaviorAllowsHorizontalRubberBand(),
                overscrollBehaviorAllowsVerticalRubberBand(),
                canHaveHorizontalScrollbar(),
                canHaveVerticalScrollbar(),
                allowsHorizontalScrolling(),
                allowsVerticalScrolling(),
                horizontalOverscrollBehaviorPreventsPropagation(),
                verticalOverscrollBehaviorPreventsPropagation()
            )
    }

    @cxx
    @implementation
    public func shouldRubberBand(_ wheelEvent: WebCore.PlatformWheelEvent, _ eventTargeting: WebCore.EventTargeting) -> Bool {
        // A root latched while it couldn't scroll rubber-bands as if it weren't latched. Check that first: in the web process, the
        // EventDispatcher queue clears the latch when the next gesture starts while the scrolling thread may be here, and checking
        // isLatchedNode() first could then see the latch but miss, by the second check, that it was this kind of latch.
        if !withScrollingTree({ $0.isLatchedToUnscrollableRoot() }) && isLatchedNode() {
            return true
        }

        if eventTargeting == .NodeOnly {
            return true
        }

        if wheelEvent.isNonGestureEvent() {
            return false
        }

        let pinnedEdges = edgePinnedState()

        if let horizontalSide = targetSideForScrollDelta(-ScrollSize(wheelEvent.delta()), .Horizontal),
            shouldRubberBandOnSide(horizontalSide, pinnedEdges)
        {
            return true
        }

        if let verticalSide = targetSideForScrollDelta(-ScrollSize(wheelEvent.delta()), .Vertical),
            shouldRubberBandOnSide(verticalSide, pinnedEdges)
        {
            return true
        }

        return false
    }

    @cxx
    @implementation
    public func canHandleWheelEvent(_ wheelEvent: WebCore.PlatformWheelEvent, _ eventTargeting: WebCore.EventTargeting) -> Bool {
        if !canHaveScrollbars() {
            return false
        }

        // MayBegin and End are used to update scrollbars; if this node is scrollable, it can handle it.
        if wheelEvent.phase() == .MayBegin || wheelEvent.phase() == .Ended || wheelEvent.momentumPhase() == .Ended {
            return true
        }

        if shouldRubberBand(wheelEvent, eventTargeting) {
            return true
        }

        return eventCanScrollContents(wheelEvent)
    }

    // What dumpProperties() writes for every scrolling node, after what every node writes.
    func writeScrollingNodeProperties(to ts: inout WTF.TextStream, _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors) {
        writeTreeNodeProperties(to: &ts, behavior)
        ts.writeScrollingProperty("scrollable area size") { $0.append(m_scrollableAreaSize) }
        ts.writeScrollingProperty("total content size") { $0.append(m_totalContentsSize) }
        if !(m_totalContentsSizeForRubberBand == m_totalContentsSize) {
            ts.writeScrollingProperty("total content size for rubber band") { $0.append(m_totalContentsSizeForRubberBand) }
        }
        if !(m_reachableContentsSize == m_totalContentsSize) {
            ts.writeScrollingProperty("reachable content size") { $0.append(m_reachableContentsSize) }
        }
        ts.writeScrollingProperty("last committed scroll position") { $0.append(m_lastCommittedScrollPosition) }

        if !m_currentScrollPosition.isZero() {
            ts.writeScrollingProperty("scroll position") { $0.append(m_currentScrollPosition) }
        }

        if !m_scrollOrigin.isZero() {
            ts.writeScrollingProperty("scroll origin") { $0.append(m_scrollOrigin) }
        }

        ts.append(snapOffsetsPropertiesText(ts.indent(), ts.formattingFlags(), ts.containerSizeLimit()))

        if Optional(fromCxx: m_currentHorizontalSnapPointIndex) != nil {
            ts.writeScrollingProperty("current horizontal snap point index") { $0.append(m_currentHorizontalSnapPointIndex) }
        }

        if Optional(fromCxx: m_currentVerticalSnapPointIndex) != nil {
            ts.writeScrollingProperty("current vertical snap point index") { $0.append(m_currentVerticalSnapPointIndex) }
        }

        ts.writeScrollingProperty("scrollable area parameters") { $0.append(m_scrollableAreaParameters) }

        #if ENABLE_SCROLLING_THREAD
        if !m_synchronousScrollingReasons.isEmpty() {
            ts.writeScrollingProperty("synchronous scrolling reasons") {
                $0.append(WebCore.ScrollingCoordinator.synchronousScrollingReasonsAsText(m_synchronousScrollingReasons))
            }
        }
        #endif
    }

    @cxx
    @implementation
    func scrollingNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        writeScrollingNodeProperties(to: &ts, behavior)
        return ts.release()
    }
}

#endif
