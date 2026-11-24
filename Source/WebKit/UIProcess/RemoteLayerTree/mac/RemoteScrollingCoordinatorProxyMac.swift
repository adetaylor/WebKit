// Copyright (C) 2022-2025 Apple Inc. All rights reserved.
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

// RemoteScrollingCoordinatorProxyMac's members are called on the main thread. The ones that hand on to the event
// dispatcher call one of its members; the dispatcher takes its own locks.
extension WebKit.RemoteScrollingCoordinatorProxyMac {
    @cxx
    @implementation
    override func scrollingTreeNodeRequestsScroll(
        _: WebCore.ScrollingNodeID,
        _: WebCore.RequestedScrollData
    ) -> WebCore.RequestsScrollHandling {
        // Unlike iOS, we handle scrolling requests for the main frame in the same way we handle them for subscrollers.
        .Unhandled
    }

    @cxx
    @implementation
    override func scrollingTreeNodeRequestsKeyboardScroll(
        _: WebCore.ScrollingNodeID,
        _: WebCore.RequestedKeyboardScrollData
    ) -> Bool {
        // Unlike iOS, we handle scrolling requests for the main frame in the same way we handle them for subscrollers.
        false
    }

    @cxx
    @implementation
    override func hasNodeWithAnimatedScrollChanged(_ hasAnimatedScrolls: Bool) {
        m_eventDispatcher.ptr().hasNodeWithAnimatedScrollChanged(hasAnimatedScrolls)
    }

    @cxx
    @implementation
    override func displayDidRefresh(_ displayID: WebCore.PlatformDisplayID) {
        m_eventDispatcher.ptr().mainThreadDisplayDidRefresh(displayID)
    }

    @cxx
    @implementation
    override func windowScreenWillChange() {
        m_eventDispatcher.ptr().windowScreenWillChange()
    }

    @cxx
    @implementation
    override func windowScreenDidChange(
        _ displayID: WebCore.PlatformDisplayID,
        _ nominalFramesPerSecond: WebCore.OptionalFramesPerSecond
    ) {
        m_eventDispatcher.ptr().windowScreenDidChange(displayID, nominalFramesPerSecond)
    }

    @cxx
    @implementation
    override func flushMainThreadTransactionIfNeeded() {
        m_eventDispatcher.ptr().flushMainThreadTransactionIfNeeded()
    }
}

#endif // os(macOS)
