// Copyright (C) 2012-2022 Apple Inc. All rights reserved.
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

internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.ScrollingTreeNode
internal import wtf
#if canImport(QuartzCore)
internal import QuartzCore
#endif

extension WebCore.ScrollingTreeNode {
    // scrollingTree() and scrollingNodeID(), read so that neither the node nor the tree is retained twice.
    var scrollingTreeAndNodeID: (tree: WebCore.RefPtrScrollingTree, nodeID: WebCore.ScrollingNodeID) {
        let nodeID = m_nodeID
        return (scrollingTree(), nodeID)
    }

    @cxx
    @implementation
    func removeAllChildren() {
        let tree = scrollingTree()
        precondition(tree.get()!.inCommitTreeState())

        m_children.shrink(0)
    }

    // What dumpProperties() writes for every node.
    func writeTreeNodeProperties(to ts: inout WTF.TextStream, _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors) {
        if behavior.contains(.IncludeNodeIDs) {
            ts.writeScrollingProperty("nodeID") { $0.append(scrollingNodeID()) }
        }
    }

    @cxx
    @implementation
    func treeNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        writeTreeNodeProperties(to: &ts, behavior)
        return ts.release()
    }
}

#if canImport(QuartzCore)
// The top-left position of a node's layer, given its position and its constraints' alignment offset.
func scrollingTreeLayerTopLeftPosition(_ position: WebCore.FloatPoint, _ offset: WebCore.FloatSize) -> CGPoint {
    CGPoint(x: CGFloat(position.x() - offset.width()), y: CGFloat(position.y() - offset.height()))
}
#endif

#endif
