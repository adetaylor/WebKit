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
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ScrollingStateFixedNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingConstraints
internal import WebCore_Private.Core.ScrollingTreeFixedNode
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollingNode
internal import WebCore_Private.Core.ScrollingTreePositionedNode
internal import WebCore_Private.Core.ScrollingTreeStickyNode
internal import WebCore_Private.Core.ScrollingTreeViewportConstrainedNode
#if canImport(QuartzCore)
internal import QuartzCore
internal import WebCore_Private.Core.ScrollingThread
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFixedNodeCocoa
internal import WebCore_Private.Core.WebCoreCALayerExtras
#endif
internal import wtf

extension WebCore.ScrollingTreeFixedNode {
    @cxx
    @implementation
    public override func commitStateBeforeChildren(_ stateNode: borrowing WebCore.ScrollingStateNode) -> Bool {
        guard let fixedStateNode = WebCore.asScrollingStateFixedNode(stateNode) else {
            return false
        }

        if stateNode.hasChangedProperty(.ViewportConstraints) {
            m_constraints = fixedStateNode.viewportConstraintsCopy()
        }

        return true
    }
}

extension WebCore.ScrollingTreeViewportConstrainedNode {
    @cxx
    @implementation
    func computeLayerPosition() -> WebCore.FloatPoint {
        var overflowScrollDelta = WebCore.FloatSize()
        var lastStickyNode: WebCore.ScrollingTreeStickyNode?
        var ancestor = unsafe parent().get() // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
        while let current = ancestor {
            defer { ancestor = unsafe current.parent().get() } // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
            if let scrollingNode = WebCore.asScrollingTreeFrameScrollingNode(current) {
                // Fixed nodes are positioned relative to the containing frame scrolling node.
                // We bail out after finding one.
                let layoutViewport = scrollingNode.layoutViewport()
                return viewportRelativeLayerPosition(layoutViewport) - overflowScrollDelta
            }

            if let overflowNode = WebCore.asScrollingTreeOverflowScrollingNode(current) {
                // To keep the layer still during async scrolling we adjust by how much the position has changed since layout.
                overflowScrollDelta -= overflowNode.scrollDeltaSinceLastCommit()
                continue
            }

            if let overflowNode = WebCore.asScrollingTreeOverflowScrollProxyNode(current) {
                // To keep the layer still during async scrolling we adjust by how much the position has changed since layout.
                overflowScrollDelta -= unsafe overflowNode.scrollDeltaSinceLastCommit() // U5(m_treeLock): the caller holds it
                continue
            }

            if let positioningAncestor = WebCore.asScrollingTreePositionedNode(current) {
                // See if sticky node already handled this positioning node.
                // FIXME: Include positioning node information to sticky/fixed node to avoid these tests.
                if let lastStickyNode, WebCore.scrollingPlatformLayersAreSame(lastStickyNode.layer(), positioningAncestor.layer()) {
                    continue
                }
                if !WebCore.scrollingPlatformLayersAreSame(positioningAncestor.layer(), layer()) {
                    overflowScrollDelta -= unsafe positioningAncestor.scrollDeltaSinceLastCommit() // U5(m_treeLock): the caller holds it
                }
                continue
            }

            if let stickyNode = WebCore.asScrollingTreeStickyNode(current) {
                overflowScrollDelta += unsafe stickyNode.scrollDeltaSinceLastCommit() // U5(m_treeLock): the caller holds it
                lastStickyNode = stickyNode
                continue
            }

            if current.isFixedNode() {
                // The ancestor fixed node has already applied the needed corrections to say put.
                return layerPositionAtLastLayout() - overflowScrollDelta
            }
        }
        assertionFailure()
        return .init()
    }
}

// The protected computeLayerPosition(), for the Cocoa node; it requires the tree lock, as it reads other nodes.
extension WebCore.ScrollingTreeViewportConstrainedNode {
    fileprivate var layerPosition: WebCore.FloatPoint { unsafe computeLayerPosition() } // U5(m_treeLock): the caller holds it
}

extension WebCore.ScrollingTreeFixedNode {
    fileprivate var alignmentOffset: WebCore.FloatSize { m_constraints.alignmentOffset() }

    fileprivate func logLayerPosition(_ layerPosition: WebCore.FloatPoint) {
        logScrolling { stream in
            stream.appendUTF8("ScrollingTreeFixedNode ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" relatedNodeScrollPositionDidChange: viewportRectAtLastLayout ".utf8.span)
            stream.append(m_constraints.viewportRectAtLastLayout())
            stream.appendUTF8(" last layer pos ".utf8.span)
            stream.append(m_constraints.layerPositionAtLastLayout())
            stream.appendUTF8(" layerPosition ".utf8.span)
            stream.append(layerPosition)
        }
    }
}

#if canImport(QuartzCore)
extension WebCore.ScrollingTreeFixedNodeCocoa {
    @cxx
    @implementation
    public override func applyLayerPositions() {
        let layerPosition = self.layerPosition

        logLayerPosition(layerPosition)

        #if ENABLE_SCROLLING_THREAD
        if WebCore.ScrollingThread.isCurrentThread() {
            // Match the behavior of ScrollingTreeFrameScrollingNodeMac::repositionScrollingLayers().
            guard let scrollingTree = scrollingTree().get() else {
                preconditionFailure("a node applies layer positions only while its tree is alive")
            }
            if !(unsafe scrollingTree.isScrollingSynchronizedWithMainThread()) { // U5(m_treeLock): the caller holds it
                m_layer.get()?._web_setLayerTopLeftPosition(.zero)
            }
        }
        #endif

        m_layer.get()?._web_setLayerTopLeftPosition(scrollingTreeLayerTopLeftPosition(layerPosition, alignmentOffset))
    }
}
#endif

#endif
