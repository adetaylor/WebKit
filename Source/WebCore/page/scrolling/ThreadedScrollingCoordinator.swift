// Copyright (C) 2014-2015 Apple Inc. All rights reserved.
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

#if ENABLE_ASYNC_SCROLLING && ENABLE_SCROLLING_THREAD

internal import WebCore_Private.Core.AsyncScrollingCoordinator
internal import WebCore_Private.Core.ScrollingCoordinator
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ThreadedScrollingCoordinator
internal import wtf

extension WebCore.ThreadedScrollingCoordinator {
    @cxx
    @implementation
    public override func scheduleTreeStateCommit() {
        scheduleRenderingUpdateFromSwift()
    }

    @cxx
    @implementation
    public override func hasNodeWithAnimatedScrollChanged(_ hasAnimatingNode: Bool) {
        // This is necessary to trigger a rendering update, after which the code in
        // AsyncScrollingCoordinator::didCompleteRenderingUpdate() triggers the rest.
        if hasAnimatingNode {
            scheduleRenderingUpdateFromSwift()
        }
    }

    @cxx
    @implementation
    public override func startMonitoringWheelEvents(_ clearLatchingState: Bool) {
        // setIsMonitoringWheelEvents() is called on the root node via AsyncScrollingCoordinator::frameViewLayoutUpdated().
        if clearLatchingState {
            scrollingTree()?.clearLatchedNode()
        }
    }
}

#endif
