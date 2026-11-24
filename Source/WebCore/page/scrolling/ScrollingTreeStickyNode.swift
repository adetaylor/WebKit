/*
 * Copyright (C) 2012 Apple Inc. All rights reserved.
 * Copyright (C) 2019 Igalia S.L.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials provided
 *    with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if ENABLE_ASYNC_SCROLLING

internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.ScrollingConstraints
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateStickyNode
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollingNode
internal import WebCore_Private.Core.ScrollingTreeStickyNode
internal import WebCore_Private.Core.ScrollingTreeViewportConstrainedNode
internal import wtf

#if canImport(QuartzCore)
internal import QuartzCore
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ScrollingThread
internal import WebCore_Private.Core.ScrollingTreeStickyNodeCocoa
internal import WebCore_Private.Core.WebCoreCALayerExtras
#endif

extension WebCore.ScrollingTreeStickyNode {
    @cxx
    @implementation
    public override func commitStateBeforeChildren(_ stateNode: borrowing WebCore.ScrollingStateNode) -> Bool {
        guard let stickyStateNode = WebCore.asScrollingStateStickyNode(stateNode) else {
            return false
        }

        if stickyStateNode.hasChangedProperty(.ViewportConstraints) {
            m_constraints = stickyStateNode.viewportConstraintsCopy()
        }

        return true
    }

    @cxx
    @implementation
    func findConstrainingRect() -> WebCore.OptionalFloatRect {
        var offsetFromStickyAncestors = WebCore.FloatSize()
        var ancestor = unsafe parent().get() // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
        while let current = ancestor {
            defer { ancestor = unsafe current.parent().get() } // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
            if let overflowProxyNode = WebCore.asScrollingTreeOverflowScrollProxyNode(current) {
                guard let overflowNode = unsafe scrollingTree().get()!.nodeForID(overflowProxyNode.overflowScrollingNodeID()) else { // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
                    break
                }

                return .init(constrainingRect(for: overflowNode, offsetFromStickyAncestors))
            }

            if current.isScrollingNode() {
                return .init(constrainingRect(for: current, offsetFromStickyAncestors))
            }

            if let stickyNode = WebCore.asScrollingTreeStickyNode(current) {
                offsetFromStickyAncestors += unsafe stickyNode.scrollDeltaSinceLastCommit() // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
            }

            if current.isFixedNode() {
                // FIXME: Do we need scrolling tree nodes at all for nested cases?
                return .init()
            }
        }
        assertionFailure()
        return .init()
    }

    private func constrainingRect(
        for scrollingNode: WebCore.ScrollingTreeNode,
        _ offsetFromStickyAncestors: WebCore.FloatSize
    ) -> WebCore.FloatRect {
        var constrainingRect = WebCore.FloatRect()
        if let frameScrollingNode = WebCore.asScrollingTreeFrameScrollingNode(scrollingNode) {
            constrainingRect = frameScrollingNode.layoutViewport()
        } else if let overflowScrollingNode = WebCore.asScrollingTreeOverflowScrollingNode(scrollingNode) {
            constrainingRect = m_constraints.constrainingRectAtLastLayout()
            constrainingRect.move(overflowScrollingNode.scrollDeltaSinceLastCommit())
        }
        constrainingRect.move(-offsetFromStickyAncestors.width(), -offsetFromStickyAncestors.height())
        return constrainingRect
    }

    @cxx
    @implementation
    public func scrollDeltaSinceLastCommit() -> WebCore.FloatSize {
        let anchorLayerPosition = unsafe computeConstrainingRectAndAnchorLayerPosition().second // U5(m_treeLock): the caller holds it
        return anchorLayerPosition - m_constraints.anchorLayerPositionAtLastLayout()
    }

    @cxx
    @implementation
    public func isCurrentlySticking() -> Bool {
        guard let constrainingRect = unsafe Optional(fromCxx: findConstrainingRect()) else { // U5(m_treeLock): the caller holds it
            return false
        }
        return isCurrentlySticking(constrainingRect)
    }

    @cxx
    @implementation
    func isCurrentlySticking(_ constrainingRect: WebCore.FloatRect) -> Bool {
        let stickyOffset = m_constraints.computeStickyOffset(constrainingRect)
        let stickyRect = m_constraints.stickyBoxRect()
        let containingRect = m_constraints.containingBlockRect()

        // FIXME: This should also account for horizontal scrolling.
        return stickyOffset.height() > 0 && stickyOffset.height() < containingRect.height() - stickyRect.height()
    }

    @cxx
    @implementation
    func stickyNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.appendUTF8("sticky node".utf8.span)
        writeTreeNodeProperties(to: &ts, behavior)
        ts.writeScrollingProperty("sticky constraints") { $0.append(m_constraints) }
        if behavior.contains(.IncludeLayerPositions) {
            ts.writeScrollingProperty("layer top left") { $0.append(layerTopLeft()) }
        }
        return ts.release()
    }
}

#if canImport(QuartzCore)
// The protected members the Cocoa node reads.
extension WebCore.ScrollingTreeStickyNode {
    fileprivate func constrainingRectAndAnchorLayerPosition() -> (
        constrainingRect: WebCore.FloatRect?, anchorLayerPosition: WebCore.FloatPoint
    ) {
        let result = unsafe computeConstrainingRectAndAnchorLayerPosition() // U5(m_treeLock): the caller holds it
        return (Optional(fromCxx: result.first), result.second)
    }

    fileprivate var clippingLayerPosition: WebCore.FloatPoint { unsafe computeClippingLayerPosition() } // U5(m_treeLock): the caller holds it

    fileprivate var alignmentOffset: WebCore.FloatSize { m_constraints.alignmentOffset() }

    fileprivate func isSticking(at constrainingRect: WebCore.FloatRect) -> Bool { isCurrentlySticking(constrainingRect) }

    fileprivate func logConstraintsAtLastLayout() {
        logScrolling { stream in
            stream.appendUTF8("ScrollingTreeStickyNodeCocoa::applyLayerPositions() ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" constrainingRectAtLastLayout ".utf8.span)
            stream.append(m_constraints.constrainingRectAtLastLayout())
            stream.appendUTF8(" last layer pos ".utf8.span)
            stream.append(m_constraints.layerPositionAtLastLayout())
        }
    }
}

extension WebCore.ScrollingTreeStickyNodeCocoa {
    private var hasSeparateViewportAnchorLayer: Bool {
        guard let viewportAnchorLayer = m_viewportAnchorLayer.get() else {
            return false
        }
        return m_layer.get() !== viewportAnchorLayer
    }

    @cxx
    @implementation
    public override func applyLayerPositions() {
        #if ENABLE_SCROLLING_THREAD
        if WebCore.ScrollingThread.isCurrentThread() {
            // Match the behavior of ScrollingTreeFrameScrollingNodeMac::repositionScrollingLayers().
            guard let scrollingTree = scrollingTree().get() else {
                preconditionFailure("a node applies layer positions only while its tree is alive")
            }
            if !(unsafe scrollingTree.isScrollingSynchronizedWithMainThread()) { // U5(m_treeLock): the caller holds it
                m_layer.get()?._web_setLayerTopLeftPosition(.zero)
                if hasSeparateViewportAnchorLayer {
                    m_viewportAnchorLayer.get()?._web_setLayerTopLeftPosition(.zero)
                }
            }
        }
        #endif

        let (constrainingRect, initialAnchorLayerPosition) = constrainingRectAndAnchorLayerPosition()
        var anchorLayerPosition = initialAnchorLayerPosition

        logConstraintsAtLastLayout()

        if hasSeparateViewportAnchorLayer {
            let clippingLayerPosition = self.clippingLayerPosition
            m_layer.get()?._web_setLayerTopLeftPosition(scrollingTreeLayerTopLeftPosition(clippingLayerPosition, .init()))

            logScrolling { stream in
                stream.appendUTF8("ScrollingTreeStickyNodeCocoa::applyLayerPositions() ".utf8.span)
                stream.append(scrollingNodeID())
                stream.appendUTF8(" clippingLayerPosition ".utf8.span)
                stream.append(clippingLayerPosition)
            }

            anchorLayerPosition = WebCore.FloatPoint(
                anchorLayerPosition.x() - clippingLayerPosition.x(),
                anchorLayerPosition.y() - clippingLayerPosition.y()
            )
        }

        logScrolling { stream in
            stream.appendUTF8("ScrollingTreeStickyNodeCocoa::applyLayerPositions() ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" clippingLayerPosition ".utf8.span)
            stream.append(anchorLayerPosition)
        }

        m_viewportAnchorLayer.get()?._web_setLayerTopLeftPosition(scrollingTreeLayerTopLeftPosition(anchorLayerPosition, alignmentOffset))

        if let constrainingRect {
            unsafe setIsSticking(isSticking(at: constrainingRect)) // U5(m_treeLock): the caller holds it
        }
    }

    @cxx
    @implementation
    public override func hasViewportClippingLayer() -> Bool {
        hasSeparateViewportAnchorLayer
    }

    @cxx
    @implementation
    public override func layerTopLeft() -> WebCore.FloatPoint {
        let layer = m_layer.get()
        let layerBounds = layer?.bounds ?? .zero
        let anchorPoint = layer?.anchorPoint ?? .zero
        let position = layer?.position ?? .zero
        let alignmentOffset = self.alignmentOffset
        let x = Float(position.x) - Float(anchorPoint.x) * Float(layerBounds.size.width) + alignmentOffset.width()
        let y = Float(position.y) - Float(anchorPoint.y) * Float(layerBounds.size.height) + alignmentOffset.height()
        return WebCore.FloatPoint(x, y)
    }
}
#endif

#endif
