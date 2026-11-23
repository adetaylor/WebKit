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

internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateFrameHostingNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameHostingNode
internal import wtf

extension WebCore.ScrollingTreeFrameHostingNode {
    @cxx
    @implementation
    public override func commitStateBeforeChildren(_ stateNode: borrowing WebCore.ScrollingStateNode) -> Bool {
        guard let state = WebCore.asScrollingStateFrameHostingNode(stateNode) else {
            return false
        }

        if state.hasChangedProperty(.LayerHostingContextIdentifier) {
            unsafe setLayerHostingContextIdentifier(state.layerHostingContextIdentifier()) // U5(m_treeLock): the caller holds it
        }
        return true
    }

    @cxx
    @implementation
    public override func willBeDestroyed() {
        if let hostingContext = Optional(fromCxx: m_hostingContext) {
            unsafe scrollingTree().get()!.removeFrameHostingNode(hostingContext) // U5(m_treeLock): the caller holds it
        }
        unsafe removeHostedChildren() // U5(m_treeLock): the caller holds it
    }

    @cxx
    @implementation
    public override func applyLayerPositions() {
    }

    @cxx
    @implementation
    func frameHostingNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.appendUTF8("frame hosting node".utf8.span)
        if let hostingContextIdentifier = Optional(fromCxx: m_hostingContext) {
            if behavior.contains(.IncludeNodeIDs) {
                ts.writeScrollingProperty("hosting context identifier") { $0.append(hostingContextIdentifier) }
            } else {
                ts.writeScrollingProperty("has hosting context identifier") { _ in }
            }
        }
        writeTreeNodeProperties(to: &ts, behavior)
        return ts.release()
    }
}

#endif
