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

// The iOS frame scrolling node's bodies.

#if WTF_PLATFORM_IOS_FAMILY

import WebKit_Internal

extension WebKit.ScrollingTreeFrameScrollingNodeRemoteIOS {
    @cxx
    @implementation
    override func minimumScrollPosition() -> WebCore.FloatPoint {
        var position = WebCore.FloatPoint() - scrollOriginSize

        if isRootNode() && liveScrollingTree.scrollPinningBehavior() == .PinToBottom {
            position.setY(maximumScrollPositionForSwift().y())
        }

        return position
    }

    @cxx
    @implementation
    override func maximumScrollPosition() -> WebCore.FloatPoint {
        let contentSizePoint = WebCore.FloatPoint(totalContentsSizeForRubberBand() - scrollableAreaSize())
        var position = (contentSizePoint - scrollOriginSize).expandedTo(WebCore.FloatPoint())

        if isRootNode() && liveScrollingTree.scrollPinningBehavior() == .PinToTop {
            position.setY(minimumScrollPositionForSwift().y())
        }

        return position
    }

    private var liveScrollingTree: WebCore.ScrollingTree {
        guard let scrollingTree = scrollingTree().get() else {
            preconditionFailure("a node is used only while its tree is alive")
        }
        return scrollingTree
    }

    private var scrollOriginSize: WebCore.FloatSize { WebCore.toFloatSize(WebCore.FloatPoint(scrollOrigin())) }
}

#endif // WTF_PLATFORM_IOS_FAMILY
