// Copyright (C) 2019 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollingNode
internal import wtf

#if canImport(QuartzCore)
internal import QuartzCore
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNodeCocoa
internal import WebCore_Private.Core.WebCoreCALayerExtras
#endif

extension WebCore.ScrollingTreeOverflowScrollProxyNode {
    /// The overflow scrolling node this node proxies, when the tree has it.
    private var overflowScrollingNode: WebCore.ScrollingTreeOverflowScrollingNode? {
        guard let node = unsafe scrollingTree().get()!.nodeForID(m_overflowScrollingNodeID.asOptional()) else { // U5(m_treeLock): the caller holds it, or runs on the tree's only thread
            return nil
        }
        return WebCore.asScrollingTreeOverflowScrollingNode(node)
    }

    @cxx
    @implementation
    public func scrollDeltaSinceLastCommit() -> WebCore.FloatSize {
        if let node = overflowScrollingNode {
            return node.scrollDeltaSinceLastCommit()
        }

        return .init()
    }

    @cxx
    @implementation
    func computeLayerPosition() -> WebCore.FloatPoint {
        guard let node = overflowScrollingNode else {
            return .init()
        }
        return node.currentScrollOffset()
    }

    @cxx
    @implementation
    func overflowScrollProxyNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.appendUTF8("overflow scroll proxy node".utf8.span)
        writeTreeNodeProperties(to: &ts, behavior)

        if let scrollingNode = overflowScrollingNode {
            ts.writeScrollingProperty("related overflow scrolling node scroll position") {
                $0.append(scrollingNode.currentScrollPosition())
            }
        }

        if behavior.contains(.IncludeNodeIDs) {
            ts.writeScrollingProperty("overflow scrolling node") { stream in
                if let nodeID = Optional(fromCxx: m_overflowScrollingNodeID.asOptional()) {
                    stream.append(nodeID)
                } else {
                    stream.appendUTF8("unset".utf8.span)
                }
            }
        }
        return ts.release()
    }
}

#if canImport(QuartzCore)
// The protected computeLayerPosition(), for the Cocoa node.
extension WebCore.ScrollingTreeOverflowScrollProxyNode {
    fileprivate var proxiedLayerPosition: WebCore.FloatPoint { unsafe computeLayerPosition() } // U5(m_treeLock): the caller holds it
}

extension WebCore.ScrollingTreeOverflowScrollProxyNodeCocoa {
    @cxx
    @implementation
    public override func applyLayerPositions() {
        let scrollOffset = proxiedLayerPosition

        logScrollingTree { stream in
            stream.appendUTF8("ScrollingTreeOverflowScrollProxyNodeCocoa ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" applyLayerPositions: setting bounds origin to ".utf8.span)
            stream.append(scrollOffset)
        }

        m_layer.get()?._web_setLayerBoundsOrigin(CGPoint(x: CGFloat(scrollOffset.x()), y: CGFloat(scrollOffset.y())))
    }
}
#endif

#endif
