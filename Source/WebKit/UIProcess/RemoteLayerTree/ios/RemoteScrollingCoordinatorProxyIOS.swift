// Copyright (C) 2014-2015 Apple Inc. All rights reserved.
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

#if WTF_PLATFORM_IOS_FAMILY

import WebKit_Internal

// Called on the main thread, where iOS commits and scrolls its scrolling tree.
extension WebKit.RemoteScrollingCoordinatorProxyIOS {
    @cxx
    @implementation
    func currentLayoutViewport() -> WebCore.FloatRect {
        // FIXME: does this give a different value to the last value pushed onto us?
        let page = webPageProxy()
        return page.computeLayoutViewportRect(
            page.unobscuredContentRect(),
            page.unobscuredContentRectRespectingInputViewBounds(),
            page.layoutViewportRect(),
            page.displayedContentScale(),
            .Unconstrained
        )
    }

    @cxx
    @implementation
    override func scrollingTreeNodeWillStartPanGesture(_ nodeID: WebCore.ScrollingNodeID) {
        webPageProxy().scrollingNodeScrollViewWillStartPanGesture(nodeID)
    }

    @cxx
    @implementation
    override func displayDidRefresh(_: WebCore.PlatformDisplayID) {
        #if ENABLE_THREADED_ANIMATIONS
        updateTimeDependentAnimationStacks()
        drawingAreaIOS().updateHighImpactMonotonicAnimations()
        #endif
    }
}

#endif // WTF_PLATFORM_IOS_FAMILY
