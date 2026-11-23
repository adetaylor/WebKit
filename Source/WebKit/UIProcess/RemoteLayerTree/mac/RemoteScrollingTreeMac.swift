// Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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

#if os(macOS)

import WebKit_Internal
internal import wtf.Core.cocoa.MainThreadBlocks

// The tree calls these on the scrolling thread or the main thread, and they hand on to the coordinator proxy, which
// lives on the main thread.
extension WebKit.RemoteScrollingTreeMac {
    private static func withScrollingCoordinatorProxy(
        _ handle: WebKit.RemoteScrollingTreeMacHandle,
        _ body: @escaping @Sendable @MainActor (WebKit.RemoteScrollingCoordinatorProxy) -> Void
    ) {
        WTF.callOnMainRunLoopWithBlock {
            MainActor.assumeIsolated {
                if let scrollingCoordinatorProxy = Self.scrollingCoordinatorProxyOnMainRunLoop(handle) {
                    body(scrollingCoordinatorProxy)
                }
            }
        }
    }

    @cxx
    @implementation
    override func scrollingTreeNodeWillStartScroll(_ nodeID: WebCore.ScrollingNodeID) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.scrollingTreeNodeWillStartScroll(nodeID) }
    }

    @cxx
    @implementation
    override func scrollingTreeNodeDidEndScroll(_ nodeID: WebCore.ScrollingNodeID) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.scrollingTreeNodeDidEndScroll(nodeID) }
    }

    @cxx
    @implementation
    override func scrollingTreeNodeDidBeginScrollSnapping(_ nodeID: WebCore.ScrollingNodeID) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.scrollingTreeNodeDidBeginScrollSnapping(nodeID) }
    }

    @cxx
    @implementation
    override func scrollingTreeNodeDidEndScrollSnapping(_ nodeID: WebCore.ScrollingNodeID) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.scrollingTreeNodeDidEndScrollSnapping(nodeID) }
    }

    @cxx
    @implementation
    override func hasNodeWithAnimatedScrollChanged(_ hasNodeWithAnimatedScroll: Bool) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.hasNodeWithAnimatedScrollChanged(hasNodeWithAnimatedScroll) }
    }

    @cxx
    @implementation
    override func didAddPendingScrollUpdate() {
        // Runs at once when already on the main run loop, so it does not use withScrollingCoordinatorProxy().
        let handle = WebKit.RemoteScrollingTreeMacHandle(self)
        WTF.ensureOnMainRunLoopWithBlock {
            MainActor.assumeIsolated {
                Self.scrollingCoordinatorProxyOnMainRunLoop(handle)?.scrollingThreadAddedPendingUpdate()
            }
        }
    }

    @cxx
    @implementation
    override func currentSnapPointIndicesDidChange(
        _ nodeID: WebCore.ScrollingNodeID,
        _ horizontal: WebCore.OptionalSnapPointIndex,
        _ vertical: WebCore.OptionalSnapPointIndex
    ) {
        Self.withScrollingCoordinatorProxy(.init(self)) {
            $0.currentSnapPointIndicesDidChange(nodeID, horizontal, vertical)
        }
    }

    @cxx
    @implementation
    override func reportExposedUnfilledArea(_ time: WTF.MonotonicTime, _ unfilledArea: CUnsignedInt) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.reportExposedUnfilledArea(time, unfilledArea) }
    }

    @cxx
    @implementation
    override func reportSynchronousScrollingReasonsChanged(
        _ timestamp: WTF.MonotonicTime,
        _ reasons: WebCore.SynchronousScrollingReasons
    ) {
        Self.withScrollingCoordinatorProxy(.init(self)) {
            $0.reportSynchronousScrollingReasonsChanged(timestamp, reasons)
        }
    }

    @cxx
    @implementation
    override func receivedWheelEventWithPhases(
        _ phase: WebCore.PlatformWheelEventPhase,
        _ momentumPhase: WebCore.PlatformWheelEventPhase
    ) {
        Self.withScrollingCoordinatorProxy(.init(self)) { $0.receivedWheelEventWithPhases(phase, momentumPhase) }
    }

    @cxx
    @implementation
    override func deferWheelEventTestCompletionForReason(
        _ nodeID: WebCore.ScrollingNodeID,
        _ reason: WebCore.WheelEventTestMonitor.DeferReason
    ) {
        guard isMonitoringWheelEvents() else {
            return
        }
        Self.withScrollingCoordinatorProxy(.init(self)) {
            $0.deferWheelEventTestCompletionForReason(.init(nodeID), reason)
        }
    }

    @cxx
    @implementation
    override func removeWheelEventTestCompletionDeferralForReason(
        _ nodeID: WebCore.ScrollingNodeID,
        _ reason: WebCore.WheelEventTestMonitor.DeferReason
    ) {
        guard isMonitoringWheelEvents() else {
            return
        }
        Self.withScrollingCoordinatorProxy(.init(self)) {
            $0.removeWheelEventTestCompletionDeferralForReason(.init(nodeID), reason)
        }
    }

    @cxx
    @implementation
    override func scrollingTreeNodeScrollbarVisibilityDidChange(
        _ nodeID: WebCore.ScrollingNodeID,
        _ orientation: WebCore.ScrollbarOrientation,
        _ isVisible: Bool
    ) {
        Self.withScrollingCoordinatorProxy(.init(self)) {
            $0.scrollingTreeNodeScrollbarVisibilityDidChange(nodeID, orientation, isVisible)
        }
    }

    @cxx
    @implementation
    override func scrollingTreeNodeScrollbarMinimumThumbLengthDidChange(
        _ nodeID: WebCore.ScrollingNodeID,
        _ orientation: WebCore.ScrollbarOrientation,
        _ minimumThumbLength: Int32
    ) {
        Self.withScrollingCoordinatorProxy(.init(self)) {
            $0.scrollingTreeNodeScrollbarMinimumThumbLengthDidChange(nodeID, orientation, minimumThumbLength)
        }
    }
}

#endif // os(macOS)
