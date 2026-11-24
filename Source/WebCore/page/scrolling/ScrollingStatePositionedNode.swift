// Copyright (C) 2019 Apple Inc. All rights reserved.
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

internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.ScrollingConstraints
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStatePositionedNode
internal import wtf

extension WebCore.ScrollingStatePositionedNode {
    @cxx
    @implementation
    public override func applicableProperties() -> WebCore.ScrollingStateNodeProperties {
        var properties = stateNodeApplicableProperties
        properties.add(.init(.RelatedOverflowScrollingNodes, .LayoutConstraintData))
        return properties
    }

    @cxx
    @implementation
    public func updateConstraints(_ constraints: WebCore.AbsolutePositionConstraints) {
        if m_constraints == constraints {
            return
        }

        logScrolling { stream in
            stream.appendUTF8("ScrollingStatePositionedNode ".utf8.span)
            stream.append(scrollingNodeID())
            stream.appendUTF8(" updateConstraints ".utf8.span)
            stream.append(constraints)
        }

        m_constraints = constraints
        setPropertyChanged(.LayoutConstraintData)
    }

    // Reads the related nodes for ScrollingStateTree::isValid().
    func forEachRelatedOverflowScrollingNode(_ body: (WebCore.ScrollingNodeID) -> Void) {
        for index in 0..<m_relatedOverflowScrollingNodes.size() {
            body(m_relatedOverflowScrollingNodes[index])
        }
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
        ts.appendUTF8("Positioned node".utf8.span)
        ts.append(stateNodePropertiesText(behavior, indent, formattingFlags, containerSizeLimit))

        ts.writeScrollingProperty("layout constraints") { $0.append(m_constraints) }
        ts.writeScrollingProperty("related overflow nodes") { $0.append(m_relatedOverflowScrollingNodes.size()) }

        if behavior.contains(.IncludeNodeIDs) && !m_relatedOverflowScrollingNodes.isEmpty() {
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

        return ts.release()
    }
}

#endif
