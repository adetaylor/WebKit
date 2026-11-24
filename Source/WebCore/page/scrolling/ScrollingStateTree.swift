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

internal import WebCore_Private.Core.LayoutRect
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateFrameScrollingNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingStatePositionedNode
internal import WebCore_Private.Core.ScrollingStateTree
internal import wtf

extension WebCore.ScrollingStateTree {
    @cxx
    @implementation
    func willRemoveNode(_ node: WebCore.ScrollingStateNode) {
        _ = m_stateNodeMap.remove(node.scrollingNodeID())
        setHasChangedProperties(true)
    }

    @cxx
    @implementation
    public func rootStateNode() -> WebCore.RefPtrScrollingStateFrameScrollingNode {
        m_rootStateNode
    }

    @cxx
    @implementation
    func reconcileViewportConstrainedLayerPositions(
        _ scrollingNodeID: WebCore.OptionalScrollingNodeID,
        _ layoutViewport: WebCore.LayoutRect,
        _ action: WebCore.ScrollingLayerPositionAction
    ) {
        if let scrollingNode = stateNodeForID(scrollingNodeID).get() {
            reconcileLayerPositionsRecursive(scrollingNode, layoutViewport, action)
        }
    }

    // Never needs to cross frame boundaries, since viewport rect reconciliation is per frame.
    private func reconcileLayerPositionsRecursive(
        _ currentNode: WebCore.ScrollingStateNode,
        _ layoutViewport: WebCore.LayoutRect,
        _ action: WebCore.ScrollingLayerPositionAction
    ) {
        currentNode.reconcileLayerPositionForViewportRect(layoutViewport, action)

        var index = 0
        while let child = WebCore.scrollingStateChildAtIndex(currentNode, index) {
            index += 1
            if child.isFrameScrollingNode() {
                continue
            }
            reconcileLayerPositionsRecursive(child, layoutViewport, action)
        }
    }

    @cxx
    @implementation
    func clear() {
        if let node = m_rootStateNode.get() {
            removeNodeAndAllDescendants(node)
        }

        m_stateNodeMap.clear()
        m_unparentedNodes.clear()
    }

    @cxx
    @implementation
    func recursiveNodeWillBeRemoved(_ currentNode: WebCore.ScrollingStateNode) {
        currentNode.setParent(consuming: WebCore.RefPtrScrollingStateNode())
        willRemoveNode(currentNode)

        var index = 0
        while let child = WebCore.scrollingStateChildAtIndex(currentNode, index) {
            recursiveNodeWillBeRemoved(child)
            index += 1
        }
    }

    @cxx
    @implementation
    func isValid() -> Bool {
        guard let rootStateNode = m_rootStateNode.get() else {
            return true
        }

        return isSubtreeValid(rootStateNode)
    }

    private func isSubtreeValid(_ node: WebCore.ScrollingStateNode) -> Bool {
        var isValid = true
        switch node.nodeType() {
        case .OverflowProxy:
            let proxyNode = WebCore.asScrollingStateOverflowScrollProxyNode(node)!
            let overflowNodeID = proxyNode.overflowScrollingNode()
            if !overflowNodeID.hasValue || !m_stateNodeMap.contains(overflowNodeID.value!) {
                logScrollingTree { stream in
                    stream.appendUTF8("ScrollingStateOverflowScrollProxyNode ".utf8.span)
                    stream.append(node.scrollingNodeID())
                    stream.appendUTF8(" refers to non-existant overflow node ".utf8.span)
                    if overflowNodeID.hasValue {
                        stream.append(overflowNodeID.value!)
                    } else {
                        stream.appendUTF8("nullopt".utf8.span)
                    }
                }
                isValid = false
            }
        case .Positioned:
            let positionedNode = WebCore.asScrollingStatePositionedNode(node)!
            positionedNode.forEachRelatedOverflowScrollingNode { relatedNodeID in
                if !m_stateNodeMap.contains(relatedNodeID) {
                    logScrollingTree { stream in
                        stream.appendUTF8("ScrollingStatePositionedNode ".utf8.span)
                        stream.append(node.scrollingNodeID())
                        stream.appendUTF8(" refers to non-existant overflow node ".utf8.span)
                        stream.append(relatedNodeID)
                    }
                    isValid = false
                }
            }
        default:
            break
        }

        var index = 0
        while let child = WebCore.scrollingStateChildAtIndex(node, index) {
            if !isSubtreeValid(child) {
                isValid = false
            }
            index += 1
        }
        return isValid
    }

    @cxx
    @implementation
    public func attachDeserializedNodes() {
        guard let rootStateNode = m_rootStateNode.get() else {
            return
        }

        rootStateNode.attachAfterDeserialization(self)
    }

    @cxx
    @implementation
    public func scrollingStateTreeAsText(_ behavior: WebCore.ScrollingStateTreeAsTextBehaviors) -> WTF.String {
        var stateTreeAsString = WTF.TextStream(.SingleLine)
        guard let rootStateNode = m_rootStateNode.get() else {
            return stateTreeAsString.release()
        }

        stateTreeAsString.append(rootStateNode.scrollingStateTreeAsText(behavior))

        if !m_unparentedNodes.isEmpty() {
            stateTreeAsString.appendUTF8("\nunparented node count: ".utf8.span)
            stateTreeAsString.append(m_unparentedNodes.size())
        }

        return stateTreeAsString.release()
    }
}

#endif
