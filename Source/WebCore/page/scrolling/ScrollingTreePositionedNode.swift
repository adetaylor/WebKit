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

internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.ScrollingConstraints
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollingNode
internal import WebCore_Private.Core.ScrollingTreePositionedNode
internal import wtf

#if canImport(QuartzCore)
internal import QuartzCore
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ScrollingTreePositionedNodeCocoa
internal import WebCore_Private.Core.WebCoreCALayerExtras
#endif

extension WebCore.ScrollingTreePositionedNode {
    @cxx
    @implementation
    public func scrollDeltaSinceLastCommit() -> WebCore.FloatSize {
        var delta = WebCore.FloatSize()
        for index in 0..<m_relatedOverflowScrollingNodes.size() {
            if let node = unsafe scrollingTree().get()!.nodeForID(.init(m_relatedOverflowScrollingNodes[index])), // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
                let overflowNode = WebCore.asScrollingTreeOverflowScrollingNode(node) {
                delta += overflowNode.scrollDeltaSinceLastCommit()
            }
        }

        // Positioned nodes compensate for scrolling, so negate the scroll delta.
        return WebCore.FloatSize(-delta.width(), -delta.height())
    }

    @cxx
    @implementation
    func positionedNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.appendUTF8("positioned node".utf8.span)
        writeTreeNodeProperties(to: &ts, behavior)

        ts.writeScrollingProperty("layout constraints") { $0.append(m_constraints) }
        ts.writeScrollingProperty("related overflow nodes") { $0.append(m_relatedOverflowScrollingNodes.size()) }

        if behavior.contains(.IncludeNodeIDs) {
            if m_relatedOverflowScrollingNodes.size() != 0 {
                ts.startGroup()
                ts.appendUTF8("overflow nodes".utf8.span)
                for index in 0..<m_relatedOverflowScrollingNodes.size() {
                    ts.appendUTF8("\n".utf8.span)
                    ts.writeIndent()
                    ts.appendUTF8("nodeID ".utf8.span)
                    ts.append(m_relatedOverflowScrollingNodes[index])
                }
                ts.endGroup()
            }
        }

        return ts.release()
    }
}

#if canImport(QuartzCore)
// The protected m_constraints, for the Cocoa node.
extension WebCore.ScrollingTreePositionedNode {
    fileprivate var constraintsLayerPositionAtLastLayout: WebCore.FloatPoint { m_constraints.layerPositionAtLastLayout() }

    fileprivate var constraintsAlignmentOffset: WebCore.FloatSize { m_constraints.alignmentOffset() }
}

extension WebCore.ScrollingTreePositionedNodeCocoa {
    @cxx
    @implementation
    public override func applyLayerPositions() {
        let delta = unsafe scrollDeltaSinceLastCommit() // U5(m_treeLock): the caller holds it
        let layerPositionAtLastLayout = constraintsLayerPositionAtLastLayout
        let layerPosition = WebCore.FloatPoint(
            layerPositionAtLastLayout.x() - delta.width(),
            layerPositionAtLastLayout.y() - delta.height()
        )

        logScrolling { stream in
            stream.appendUTF8("ScrollingTreePositionedNode ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" applyLayerPositions: overflow delta ".utf8.span)
            stream.append(delta)
            stream.appendUTF8(" moving layer to ".utf8.span)
            stream.append(layerPosition)
        }

        m_layer.get()?._web_setLayerTopLeftPosition(scrollingTreeLayerTopLeftPosition(layerPosition, constraintsAlignmentOffset))
    }
}
#endif

#endif
