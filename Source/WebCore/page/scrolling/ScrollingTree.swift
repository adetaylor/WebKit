/*
 * Copyright (C) 2012-2015 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.FrameIdentifier
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ProcessQualified
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingNodeID
internal import WebCore_Private.Core.ScrollingStateFrameScrollingNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateTree
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameHostingNode
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import wtf

// LOG_WITH_STREAM(Scrolling, ...): writeMessage runs only while the channel is on.
func logScrolling(_ writeMessage: (inout WTF.TextStream) -> Void) {
    #if !LOG_DISABLED
    guard WebCore.LogChannel.Scrolling().state != .Off else {
        return
    }
    var stream = WTF.TextStream(.SingleLine)
    writeMessage(&stream)
    WTF.logPreformatted(WebCore.LogChannel.Scrolling(), stream.release())
    #endif
}

// LOG_WITH_STREAM(ScrollingTree, ...): writeMessage runs only while the channel is on.
func logScrollingTree(_ writeMessage: (inout WTF.TextStream) -> Void) {
    #if !LOG_DISABLED
    guard WebCore.LogChannel.ScrollingTree().state != .Off else {
        return
    }
    var stream = WTF.TextStream(.SingleLine)
    writeMessage(&stream)
    WTF.logPreformatted(WebCore.LogChannel.ScrollingTree(), stream.release())
    #endif
}

// Duration of a few frames so that we stay active for sequence of wheel events.
private let activityIntervalSeconds = 0.05

// A ScrollingNodeID's two identifiers, ordered so the nodes a commit visits can be sorted.
private struct ScrollingNodeKey: Comparable {
    let object: UInt64
    let process: UInt64

    init(_ nodeID: WebCore.ScrollingNodeID) {
        object = nodeID.objectValue().toUInt64()
        process = nodeID.processIdentifier().toUInt64()
    }

    static func < (lhs: ScrollingNodeKey, rhs: ScrollingNodeKey) -> Bool {
        (lhs.object, lhs.process) < (rhs.object, rhs.process)
    }
}

extension [ScrollingNodeKey] {
    fileprivate func isSorted() -> Bool {
        var index = 1
        while index < count {
            if self[index] < self[index - 1] {
                return false
            }
            index += 1
        }
        return true
    }

    // Whether the array, which is sorted, contains key.
    fileprivate func containsSorted(_ key: ScrollingNodeKey) -> Bool {
        var low = 0
        var high = count
        while low < high {
            let middle = low &+ (high &- low) / 2
            if self[middle] < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < count && self[low] == key
    }
}

/// What the commit of one state tree records while it updates the tree.
private struct ScrollingTreeCommitState: ~Copyable {
    // The nodes the commit visits, sorted at the end to find the frame's nodes it did not visit.
    // We can't use orphanNodes for this, because orphanNodes won't contain descendants of removed nodes.
    var visitedNodes: [ScrollingNodeKey] = []
    // Nodes with non-empty synchronousScrollingReasons.
    var synchronousScrollingNodes: [WebCore.ScrollingNodeID] = []
    // orphanNodes keeps child nodes alive while we rebuild child lists.
    var orphanNodes: [WebCore.ScrollingTreeNode] = []
    // Hosted subtrees needing attaching to scrolling tree after main commit has finished
    var pendingSubtreesNeedingCommit: [WebCore.LayerHostingContextIdentifier] = []

    mutating func didVisitNode(_ nodeID: WebCore.ScrollingNodeID) {
        visitedNodes.append(ScrollingNodeKey(nodeID))
    }

    /// Makes `node`'s children orphans, which are kept alive until the commit ends, and removes them from `node`.
    mutating func orphanChildren(_ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ node: WebCore.ScrollingTreeNode) {
        var index = 0
        while let child = WebCore.scrollingTreeChildAtIndex(node, index) {
            locked.setParent(child, nil)
            orphanNodes.append(child)
            index += 1
        }
        locked.removeAllChildren(node)
    }

    /// Records what the commit needs from `node` once it and its children are committed.
    mutating func didCommitNode(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ node: WebCore.ScrollingTreeNode,
        _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?
    ) {
        #if ENABLE_SCROLLING_THREAD
        if WebCore.scrollingTreeNodeHasSynchronousScrollingReasons(node) {
            synchronousScrollingNodes.append(node.scrollingNodeID())
        }
        #endif

        if node.isFrameHostingNode(), let hostingNode = WebCore.asScrollingTreeFrameHostingNode(node),
            let identifier = Optional(fromCxx: hostingNode.layerHostingContextIdentifier()) {
            pendingSubtreesNeedingCommit.append(identifier)
        }

        if let frameHostingNode {
            locked.addHostedChild(frameHostingNode, node)
        }
    }
}

/// ScrollingTree::commitTreeState() for `stateTree`, called by ScrollingTreeLockedAccess::commitStateTree() with the tree's lock held.
@_expose(Cxx)
nonisolated func commitScrollingTreeState(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ stateTree: WebCore.ScrollingStateTree, _ hostingContextIdentifier: WebCore.OptionalLayerHostingContextIdentifier
) -> WebCore.ScrollingTreeCommitResult {
    let rootStateNodeChanged = stateTree.hasNewRootStateNode()
    locked.captureMainFrameRubberbandingState(rootStateNodeChanged)

    let rootNode = stateTree.rootStateNode().get()
    let frameID = stateTree.rootFrameIdentifier()
    let hostingContextIdentifier = Optional(fromCxx: hostingContextIdentifier)
    var frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?

    if let hostingContextIdentifier {
        logScrolling { stream in
            stream.appendUTF8("ScrollingTree::commitTreeState - starting hosted tree commit for hosting context ID:  ".utf8.span)
            stream.append(hostingContextIdentifier)
        }
        guard let hostingNode = locked.hostingNodeForHostedSubtree(hostingContextIdentifier).get() else {
            logScrolling { stream in
                stream.appendUTF8("ScrollingTree::commitTreeState - parent not present for hosted tree commit".utf8.span)
            }
            return .NeedsHostingNode
        }
        frameHostingNode = hostingNode
        if rootNode == nil {
            locked.removeHostedChildren(hostingNode)
            return .Committed
        }
    }
    if let rootNode, hostingContextIdentifier == nil,
        rootStateNodeChanged
            || rootNode.hasChangedProperty(.EventTrackingRegion)
            || rootNode.hasChangedProperty(.ScrolledContentsLayer)
            || rootNode.hasChangedProperty(.AsyncFrameOrOverflowScrollingEnabled)
            || rootNode.hasChangedProperty(.WheelEventGesturesBecomeNonBlocking)
            || rootNode.hasChangedProperty(.ScrollingPerformanceTestingEnabled)
            || rootNode.hasChangedProperty(.IsMonitoringWheelEvents)
            || rootNode.hasChangedProperty(.OverlayScrollbarsEnabled) {
        locked.updateTreeStateFromRootStateNode(stateTree, rootStateNodeChanged)
    }

    locked.removeActiveNodesForFrame(frameID)

    var state = ScrollingTreeCommitState()
    let nodesForFrame = locked.nodeIDsForFrame(frameID)
    state.visitedNodes.reserveCapacity(nodesForFrame.size())
    state.orphanNodes.reserveCapacity(nodesForFrame.size())

    let rootStateNode = stateTree.rootStateNode().get().flatMap { WebCore.asScrollingStateNode($0) }
    guard updateScrollingTreeFromStateNode(locked, tree, rootStateNode, frameID, frameHostingNode, &state) else {
        // The hosted subtrees the commit took for its frame hosting nodes go with it.
        for hostingID in state.pendingSubtreesNeedingCommit {
            locked.discardHostedSubtreesNeedingPairing(hostingID)
        }
        return .Failed
    }

    if let anySynchronousScrollingNode = state.synchronousScrollingNodes.first {
        locked.propagateSynchronousScrollingReasons(.init(anySynchronousScrollingNode))
    } else {
        let noSynchronousScrollingNode = WebCore.OptionalScrollingNodeID()
        locked.propagateSynchronousScrollingReasons(noSynchronousScrollingNode)
    }
    #if ENABLE_SCROLLING_THREAD
    if locked.propagatesSynchronousScrollingReasonsToAncestors() {
        for nodeID in state.synchronousScrollingNodes {
            if let node = locked.nodeForID(nodeID) {
                propagateSynchronousScrollingReasonsToAncestors(locked, node)
            }
        }
    }
    #endif

    // The nodes are visited in tree order, which is usually their identifiers' order.
    if !state.visitedNodes.isSorted() {
        state.visitedNodes.sort()
    }
    var unvisitedNodes: [(key: ScrollingNodeKey, nodeID: WebCore.ScrollingNodeID)] = []
    for index in 0..<nodesForFrame.size() {
        let nodeID = nodesForFrame[index]
        let key = ScrollingNodeKey(nodeID)
        if !state.visitedNodes.containsSorted(key) {
            // Reserve for the most nodes that can be left.
            if unvisitedNodes.isEmpty {
                unvisitedNodes.reserveCapacity(nodesForFrame.size() - index)
            }
            unvisitedNodes.append((key, nodeID))
        }
    }
    unvisitedNodes.sort { $0.key < $1.key }
    for unvisitedNode in unvisitedNodes {
        let nodeID = unvisitedNode.nodeID
        logScrolling { stream in
            stream.appendUTF8("ScrollingTree::commitTreeState - removing unvisited node ".utf8.span)
            stream.append(nodeID)
        }
        if let frameHostingNode {
            locked.removeNode(nodeID, frameHostingNode)
        } else {
            locked.removeNode(nodeID)
        }
    }

    logScrollingTree { stream in
        stream.appendUTF8("committed ScrollingTree".utf8.span)
        stream.append(unsafe tree.scrollingTreeAsText(WebCore.debugScrollingStateTreeAsTextBehaviors)) // U5(m_treeLock): held by commitTreeState()'s Locker
    }

    // Recursively commit subtrees that can now be attached
    var succeeded = true
    for hostingID in state.pendingSubtreesNeedingCommit {
        succeeded = locked.commitHostedSubtreesNeedingPairing(hostingID) && succeeded
    }
    _ = consume state

    locked.didCommitTree()
    tree.setNeedsApplyLayerPositions()

    return succeeded ? .Committed : .Failed
}

/// Updates `tree` from `stateNode` down; a null `stateNode` removes every node. Returns false when the commit fails.
private func updateScrollingTreeFromStateNode(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ stateNode: WebCore.ScrollingStateNode?, _ frameID: WebCore.FrameIdentifier,
    _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?, _ state: inout ScrollingTreeCommitState
) -> Bool {
    guard let stateNode else {
        locked.removeAllNodes()
        locked.setRootNode(nil)
        return true
    }
    return updateScrollingTreeFromStateNode(locked, tree, stateNode, frameID, frameHostingNode, &state)
}

/// A node of the walk below whose children are being committed: its tree node and state node, and the index of the
/// next state child to commit, or nil when its children are not committed (the root of a hosted subtree).
private struct ScrollingTreeCommitFrame {
    let node: WebCore.ScrollingTreeNode
    let stateNode: WebCore.ScrollingStateNode
    var nextChildIndex: Int?
}

/// What visiting one state node did to the tree.
private enum ScrollingTreeCommitVisit {
    /// The node's commitStateBeforeChildren() failed; the commit stops.
    case failed
    /// The node's parent is not in the tree, so the node was removed and its children are not visited.
    case removed
    /// The node was committed before its children. The index of its first state child to commit, or nil when its
    /// children are not committed.
    case committing(WebCore.ScrollingTreeNode, Int?)
}

/// Creates `stateNode`'s tree node if the tree has none, makes it a child of its parent, and calls its
/// commitStateBeforeChildren().
@inline(always)
private func visitStateNode(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ stateNode: WebCore.ScrollingStateNode, _ frameID: WebCore.FrameIdentifier,
    _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?, _ state: inout ScrollingTreeCommitState
) -> ScrollingTreeCommitVisit {
    let nodeID = stateNode.scrollingNodeID()
    var parentNodeID = Optional(fromCxx: stateNode.parentNodeID())
    if parentNodeID == nil, let frameHostingNode, stateNode.isFrameScrollingNode() {
        parentNodeID = frameHostingNode.scrollingNodeID()
    }

    let node: WebCore.ScrollingTreeNode
    if let existingNode = locked.nodeForID(nodeID) {
        node = existingNode
        state.didVisitNode(nodeID)
    } else {
        node = tree.createScrollingTreeNode(stateNode.nodeType(), nodeID).get()
        if parentNodeID == nil {
            // This is the root node. Clear the node map.
            guard let frameScrollingNode = WebCore.asScrollingTreeFrameScrollingNode(node) else {
                return .failed
            }
            locked.setRootNode(frameScrollingNode)
            locked.removeAllNodes()
        }
        locked.addNode(node, frameID)
    }

    if let parentNodeID {
        if let parent = locked.nodeForID(parentNodeID) {
            let oldParent = unsafe node.parent().get() // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            if let oldParent {
                unsafe oldParent.removeChild(node) // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            }
            // appendChild() sets the parent as well.
            if oldParent == nil || !oldParent!.scrollingNodeID().isEqual(parent.scrollingNodeID()) {
                unsafe node.setParentNode(parent) // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope; both nodes are this tree's: parent from its node map, node from its node map or its createScrollingTreeNode() above
            }
            unsafe parent.appendChild(node) // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope; both nodes are this tree's: parent from its node map, node from its node map or its createScrollingTreeNode() above
        } else {
            if let frameHostingNode {
                locked.removeNode(nodeID, frameHostingNode)
            } else {
                locked.removeNode(nodeID)
            }
            return .removed
        }
    }

    if unsafe !node.commitStateBeforeChildren(stateNode) { // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
        return .failed
    }

    // The children of a hosted subtree's root are not in this state tree.
    if node.isRootOfHostedSubtree() {
        return .committing(node, nil)
    }
    // The children become orphans, which the commit keeps alive; the live ones are added back below.
    state.orphanChildren(locked, node)
    return .committing(node, 0)
}

/// Commits `rootStateNode` and its descendants depth first; `stack` holds the ancestors of the node whose children are being committed.
private func updateScrollingTreeFromStateNode(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ rootStateNode: WebCore.ScrollingStateNode, _ frameID: WebCore.FrameIdentifier,
    _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?, _ state: inout ScrollingTreeCommitState
) -> Bool {
    var currentNode: WebCore.ScrollingTreeNode
    var currentStateNode = rootStateNode
    var currentNextChildIndex: Int?
    switch visitStateNode(locked, tree, rootStateNode, frameID, frameHostingNode, &state) {
    case .failed:
        return false
    case .removed:
        return true
    case .committing(let node, let nextChildIndex):
        currentNode = node
        currentNextChildIndex = nextChildIndex
    }

    var stack = UniqueArray<ScrollingTreeCommitFrame>(capacity: 8)
    while true {
        if let childIndex = currentNextChildIndex,
            let child = WebCore.scrollingStateChildAtIndex(currentStateNode, childIndex) {
            // childIndex is below the state node's child count, so this cannot wrap.
            currentNextChildIndex = childIndex &+ 1
            switch visitStateNode(locked, tree, child, frameID, frameHostingNode, &state) {
            case .failed:
                return false
            case .removed:
                break
            case .committing(let node, let nextChildIndex):
                stack.append(ScrollingTreeCommitFrame(
                    node: currentNode, stateNode: currentStateNode, nextChildIndex: currentNextChildIndex))
                currentNode = node
                currentStateNode = child
                currentNextChildIndex = nextChildIndex
            }
            continue
        }

        if unsafe !currentNode.commitStateAfterChildren(currentStateNode) { // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            return false
        }

        unsafe currentNode.didCompleteCommitForNode() // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope

        state.didCommitNode(locked, currentNode, frameHostingNode)

        if stack.isEmpty {
            return true
        }
        let parentFrame = stack.removeLast()
        currentNode = parentFrame.node
        currentStateNode = parentFrame.stateNode
        currentNextChildIndex = parentFrame.nextChildIndex
    }
}

#if ENABLE_SCROLLING_THREAD
/// Marks the scrolling nodes enclosing `node`, up to its frame scrolling node, as having descendant scrollers with synchronous scrolling.
private func propagateSynchronousScrollingReasonsToAncestors(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ node: WebCore.ScrollingTreeNode
) {
    if node.isFrameScrollingNode() {
        return
    }

    // `node` is the caller's, so `locked` checks that it is this tree's; its ancestors are then this tree's too.
    var currentNode = locked.parent(node).get()
    while let current = currentNode {
        if let scrollingNode = WebCore.asScrollingTreeScrollingNode(current) {
            scrollingNode.addSynchronousScrollingReason(.DescendantScrollersHaveSynchronousScrolling)
        }

        if let proxyNode = WebCore.asScrollingTreeOverflowScrollProxyNode(current) {
            // A proxy node without an overflow scrolling node ends the walk.
            currentNode = locked.nodeForID(proxyNode.overflowScrollingNodeID())
            continue
        }

        if current.isFrameScrollingNode() {
            break
        }

        currentNode = unsafe current.parent().get() // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
    }
}
#endif

/// ScrollingTree::mainFrameViewportChangedViaDelegatedScrolling() with the tree's lock held.
@_expose(Cxx)
nonisolated func scrollingTreeMainFrameViewportChangedViaDelegatedScrolling(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ scrollPosition: WebCore.FloatPoint,
    _ layoutViewport: WebCore.FloatRect, _ scale: Double
) {
    guard let rootNode = locked.rootNode().get() else {
        return
    }

    // wasScrolledByDelegatedScrolling() bails out when the position is unchanged, but the scrolled contents
    // layer's position is scaled by this, so a scale change on its own still needs a reposition.
    let scaleChanged = rootNode.delegatedPageScaleFactor() != Float(scale)
    rootNode.setDelegatedPageScaleFactor(Float(scale))
    unsafe rootNode.wasScrolledByDelegatedScrolling(scrollPosition, .init(layoutViewport), .Sync) // U5(m_treeLock): held by the C++ Locker in mainFrameViewportChangedViaDelegatedScrolling(), which calls in; locked is in scope
    if scaleChanged {
        unsafe rootNode.repositionScrollingLayersForDelegatedScaleChange() // U5(m_treeLock): held by the C++ Locker in mainFrameViewportChangedViaDelegatedScrolling(), which calls in; locked is in scope
    }
}

// Out of line so the optimizer does not retain self around the optional's accessors.
@_effects(readonly)
@inline(never)
private func scrollingTreeQueriedNodeID(_ nodeID: WebCore.OptionalScrollingNodeID) -> WebCore.ScrollingNodeID? {
    Optional(fromCxx: nodeID)
}

extension WebCore.ScrollingTree {
    // MARK: Tree state

    @cxx
    @implementation
    public func setMainFrameScrollPosition(_ position: WebCore.FloatPoint) {
        lockTreeState().setMainFrameScrollPosition(position)
    }

    @cxx
    @implementation
    public func setGestureState(_ gestureState: WebCore.OptionalWheelScrollGestureState) {
        lockTreeState().setGestureState(gestureState)
    }

    @cxx
    @implementation
    public func gestureState() -> WebCore.OptionalWheelScrollGestureState {
        lockTreeState().gestureState()
    }

    @cxx
    @implementation
    public func eventTrackingTypeForPoint(
        _ eventType: WebCore.EventTrackingRegionsEventType,
        _ point: WebCore.IntPoint
    ) -> WebCore.TrackingType {
        lockTreeState().eventTrackingTypeForPoint(eventType, point)
    }

    // Can be called from the main thread.
    @cxx
    @implementation
    public func isRubberBandInProgressForNode(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let nodeID = scrollingTreeQueriedNodeID(nodeID) else {
            return false
        }
        return lockTreeState().contains(.ActiveRubberBanding, nodeID)
    }

    // Can be called from the main thread.
    @cxx
    @implementation
    public func isUserScrollInProgressForNode(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let nodeID = scrollingTreeQueriedNodeID(nodeID) else {
            return false
        }
        return lockTreeState().contains(.ActiveUserScrolls, nodeID)
    }

    @cxx
    @implementation
    public func setUserScrollInProgressForNode(_ nodeID: WebCore.ScrollingNodeID, _ isScrolling: Bool) {
        let state = lockTreeState()
        if isScrolling {
            _ = state.add(.ActiveUserScrolls, nodeID)
            scrollingTreeNodeWillStartScroll(nodeID)
        } else {
            _ = state.remove(.ActiveUserScrolls, nodeID)
            scrollingTreeNodeDidEndScroll(nodeID)
        }
    }

    // Can be called from the main thread.
    @cxx
    @implementation
    public func isScrollSnapInProgressForNode(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let nodeID = scrollingTreeQueriedNodeID(nodeID) else {
            return false
        }
        return lockTreeState().contains(.ActiveScrollSnap, nodeID)
    }

    @cxx
    @implementation
    public func setNodeScrollSnapInProgress(_ nodeID: WebCore.ScrollingNodeID, _ isScrollSnapping: Bool) {
        let state = lockTreeState()
        if isScrollSnapping {
            if state.add(.ActiveScrollSnap, nodeID) {
                scrollingTreeNodeDidBeginScrollSnapping(nodeID)
            }
        } else if state.remove(.ActiveScrollSnap, nodeID) {
            scrollingTreeNodeDidEndScrollSnapping(nodeID)
        }
    }

    @cxx
    @implementation
    public func isScrollAnimationInProgressForNode(_ nodeID: WebCore.OptionalScrollingNodeID) -> Bool {
        guard let nodeID = scrollingTreeQueriedNodeID(nodeID) else {
            return false
        }
        return lockTreeState().contains(.ActiveScrollAnimations, nodeID)
    }

    @cxx
    @implementation
    public func setScrollAnimationInProgressForNode(
        _ nodeID: WebCore.OptionalScrollingNodeID,
        _ isScrollAnimationInProgress: Bool
    ) {
        guard let nodeID = scrollingTreeQueriedNodeID(nodeID) else {
            return
        }

        let state = lockTreeState()
        let hadAnyAnimatedScrollingNodes = !state.isEmpty(.ActiveScrollAnimations)
        if isScrollAnimationInProgress {
            _ = state.add(.ActiveScrollAnimations, nodeID)
        } else {
            _ = state.remove(.ActiveScrollAnimations, nodeID)
        }

        let hasAnyAnimatedScrollingNodes = !state.isEmpty(.ActiveScrollAnimations)
        if hasAnyAnimatedScrollingNodes != hadAnyAnimatedScrollingNodes {
            hasNodeWithAnimatedScrollChanged(hasAnyAnimatedScrollingNodes)
        }
    }

    @cxx
    @implementation
    public func hasNodeWithActiveScrollAnimations() -> Bool {
        !lockTreeState().isEmpty(.ActiveScrollAnimations)
    }

    @cxx
    @implementation
    public func windowScreenDidChange(
        _ displayID: WebCore.PlatformDisplayID,
        _ nominalFramesPerSecond: WebCore.OptionalFramesPerSecond
    ) {
        let state = lockTreeState()
        state.setDisplayID(displayID)
        state.setNominalFramesPerSecond(nominalFramesPerSecond)
    }

    @cxx
    @implementation
    public func displayID() -> WebCore.PlatformDisplayID {
        lockTreeState().displayID()
    }

    @cxx
    @implementation
    public func nominalFramesPerSecond() -> WebCore.OptionalFramesPerSecond {
        lockTreeState().nominalFramesPerSecond()
    }

    // MARK: Swipe state and wheel event time

    @cxx
    @implementation
    public func setMainFramePinnedState(_ edgePinningState: WebCore.RectEdgesBool) {
        updateSwipeState { $0.mainFramePinnedState = edgePinningState }
    }

    @cxx
    @implementation
    public func setClientAllowedMainFrameRubberBandableEdges(
        _ clientAllowedRubberBandableEdges: WebCore.RectEdgesRubberBandingBehavior
    ) {
        updateSwipeState { $0.clientAllowedRubberBandableEdges = clientAllowedRubberBandableEdges }
    }

    // Can be called from the main thread.
    @cxx
    @implementation
    public func setScrollPinningBehavior(_ pinning: WebCore.ScrollPinningBehavior) {
        updateSwipeState { $0.scrollPinningBehavior = pinning }
    }

    private func updateSwipeState(_ body: (inout WebCore.ScrollingTree.SwipeState) -> Void) {
        let swipe = lockSwipeState()
        var state = swipe.get()
        body(&state)
        swipe.set(state)
    }

    @cxx
    @implementation
    public func scrollPinningBehavior() -> WebCore.ScrollPinningBehavior {
        lockSwipeState().get().scrollPinningBehavior
    }

    @cxx
    @implementation
    public func hasProcessedWheelEventsRecently() -> Bool {
        let lastWheelEventTime = lockLastWheelEventTime()
        let now = WTF.MonotonicTime.now().secondsSinceEpoch().value()
        return now - lastWheelEventTime.get().secondsSinceEpoch().value() < activityIntervalSeconds
    }

    @cxx
    @implementation
    public func willProcessWheelEvent() {
        lockLastWheelEventTime().set(WTF.MonotonicTime.now())
    }

    // MARK: Main frame

    @cxx
    @implementation
    public func mainFrameHorizontalOverscrollBehavior() -> WebCore.OverscrollBehavior {
        withRootNode(default: .Auto) { $0.horizontalOverscrollBehavior() }
    }

    @cxx
    @implementation
    public func mainFrameScrollbarWidth() -> WebCore.ScrollbarWidth {
        withRootNode(default: .Auto) { $0.scrollbarWidthStyle() }
    }

    @cxx
    @implementation
    public func mainFrameScrollbarColor() -> WebCore.OptionalScrollbarColor {
        withRootNode(default: .init()) { $0.scrollbarColorStyle() }
    }

    @cxx
    @implementation
    public func mainFrameVerticalOverscrollBehavior() -> WebCore.OverscrollBehavior {
        withRootNode(default: .Auto) { $0.verticalOverscrollBehavior() }
    }

    @cxx
    @implementation
    public func mainFrameScrollOrigin() -> WebCore.IntPoint {
        withRootNode(default: WebCore.IntPoint()) { $0.scrollOrigin() }
    }

    @cxx
    @implementation
    public func mainFrameHeaderHeight() -> Int32 {
        withRootNode(default: 0) { $0.headerHeight() }
    }

    @cxx
    @implementation
    public func mainFrameFooterHeight() -> Int32 {
        withRootNode(default: 0) { $0.footerHeight() }
    }

    @cxx
    @implementation
    public func mainFrameScaleFactor() -> Float {
        withRootNode(default: 1) { $0.frameScaleFactor() }
    }

    @cxx
    @implementation
    public func setMainFrameDelegatedPageScaleFactor(_ scale: Float) {
        let locked = lockTree()
        guard let rootNode = locked.rootNode().get(), rootNode.delegatedPageScaleFactor() != scale else {
            return
        }

        rootNode.setDelegatedPageScaleFactor(scale)
        unsafe rootNode.repositionScrollingLayersForDelegatedScaleChange() // U5(m_treeLock): held by lockTree()'s result, alive to the end of this scope
    }

    @cxx
    @implementation
    public func totalContentsSize() -> WebCore.FloatSize {
        withRootNode(default: WebCore.FloatSize()) { $0.totalContentsSize() }
    }

    @cxx
    @implementation
    public func layoutViewport() -> WebCore.FloatRect {
        withRootNode(default: WebCore.FloatRect()) { $0.layoutViewport() }
    }

    @cxx
    @implementation
    public func mainFrameSizeForVisibleContent() -> WebCore.FloatSize {
        withRootNode(default: WebCore.FloatSize()) { $0.sizeForVisibleContent() }
    }

    @cxx
    @implementation
    public func viewWillStartLiveResize() {
        withRootNode(default: ()) { $0.viewWillStartLiveResize() }
    }

    @cxx
    @implementation
    public func viewWillEndLiveResize() {
        withRootNode(default: ()) { $0.viewWillEndLiveResize() }
    }

    @cxx
    @implementation
    public func viewSizeDidChange() {
        withRootNode(default: ()) { $0.viewSizeDidChange() }
    }

    // Calls body with the root node while the tree lock is held; defaultValue if there is no root node.
    private func withRootNode<T>(default defaultValue: T, _ body: (WebCore.ScrollingTreeFrameScrollingNode) -> T) -> T {
        let locked = lockTree()
        guard let rootNode = locked.rootNode().get() else {
            return defaultValue
        }
        return body(rootNode)
    }

    @cxx
    @implementation
    public func scrollBySimulatingWheelEventForTesting(_ nodeID: WebCore.ScrollingNodeID, _ delta: WebCore.FloatSize) {
        let locked = lockTree()
        if let node = locked.nodeForID(nodeID), let scrollingNode = WebCore.asScrollingTreeScrollingNode(node) {
            locked.scrollBy(scrollingNode, delta, .Clamped)
        }
    }
}
