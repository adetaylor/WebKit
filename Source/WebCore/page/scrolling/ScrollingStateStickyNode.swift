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
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.ScrollingConstraints
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateStickyNode
internal import wtf

extension WebCore.ScrollingStateStickyNode {
    @cxx
    @implementation
    public override func applicableProperties() -> WebCore.ScrollingStateNodeProperties {
        var properties = stateNodeApplicableProperties
        properties.add(.init(.ViewportAnchorLayer, .ViewportConstraints))
        return properties
    }

    @cxx
    @implementation
    public override func dumpPropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.appendUTF8("Sticky node".utf8.span)
        ts.append(stateNodePropertiesText(behavior, indent, formattingFlags, containerSizeLimit))

        if m_constraints.anchorEdges() != 0 {
            ts.startGroup()
            ts.appendUTF8("anchor edges: ".utf8.span)
            if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeLeft) {
                ts.appendUTF8("AnchorEdgeLeft ".utf8.span)
            }
            if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeRight) {
                ts.appendUTF8("AnchorEdgeRight ".utf8.span)
            }
            if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeTop) {
                ts.appendUTF8("AnchorEdgeTop ".utf8.span)
            }
            if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeBottom) {
                ts.appendUTF8("AnchorEdgeBottom".utf8.span)
            }
            ts.endGroup()
        }

        if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeLeft) {
            ts.writeScrollingProperty("left offset") { $0.append(m_constraints.leftOffset()) }
        }
        if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeRight) {
            ts.writeScrollingProperty("right offset") { $0.append(m_constraints.rightOffset()) }
        }
        if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeTop) {
            ts.writeScrollingProperty("top offset") { $0.append(m_constraints.topOffset()) }
        }
        if m_constraints.hasAnchorEdge(WebCore.AnchorEdgeBottom) {
            ts.writeScrollingProperty("bottom offset") { $0.append(m_constraints.bottomOffset()) }
        }

        ts.writeScrollingProperty("containing block rect") { $0.append(m_constraints.containingBlockRect()) }

        ts.writeScrollingProperty("sticky box rect") { $0.append(m_constraints.stickyBoxRect()) }

        ts.writeScrollingProperty("constraining rect") { $0.append(m_constraints.constrainingRectAtLastLayout()) }

        ts.writeScrollingProperty("sticky offset at last layout") { $0.append(m_constraints.stickyOffsetAtLastLayout()) }

        ts.writeScrollingProperty("layer position at last layout") {
            $0.append(m_constraints.layerPositionAtLastLayout())
        }

        return ts.release()
    }
}

#endif
