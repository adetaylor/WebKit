// Copyright (C) 2014, 2016 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateFrameScrollingNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import wtf

extension WebCore.ScrollingStateFrameScrollingNode {
    @cxx
    @implementation
    public override func applicableProperties() -> WebCore.ScrollingStateNodeProperties {
        var properties = scrollingNodeApplicableProperties
        properties.add(.init(
            .FrameScaleFactor, .EventTrackingRegion, .RootContentsLayer, .CounterScrollingLayer, .InsetClipLayer,
            .ContentShadowLayer, .HeaderHeight, .FooterHeight, .HeaderLayer, .FooterLayer, .BehaviorForFixedElements,
            .ObscuredContentInsets))
        #if HAVE_NSREFRESHCONTROLLER
        properties.add(.init(.TopScrollStretchForRefreshController))
        #endif
        properties.add(.init(
            .VisualViewportIsSmallerThanLayoutViewport, .AsyncFrameOrOverflowScrollingEnabled,
            .WheelEventGesturesBecomeNonBlocking, .ScrollingPerformanceTestingEnabled, .LayoutViewport,
            .SizeForVisibleContent, .MinLayoutViewportOrigin, .MaxLayoutViewportOrigin, .OverrideVisualViewportSize,
            .OverlayScrollbarsEnabled, .InsetForLeftScrollbarSpace))
        return properties
    }

    @cxx
    @implementation
    public func setFrameScaleFactor(_ scaleFactor: Float) {
        if m_frameScaleFactor == scaleFactor {
            return
        }

        m_frameScaleFactor = scaleFactor

        setPropertyChanged(.FrameScaleFactor)
    }

    @cxx
    @implementation
    public func setScrollBehaviorForFixedElements(_ behaviorForFixed: WebCore.ScrollBehaviorForFixedElements) {
        if m_behaviorForFixed == behaviorForFixed {
            return
        }

        m_behaviorForFixed = behaviorForFixed
        setPropertyChanged(.BehaviorForFixedElements)
    }

    @cxx
    @implementation
    public func setLayoutViewport(_ r: WebCore.FloatRect) {
        if m_layoutViewport == r {
            return
        }

        m_layoutViewport = r
        setPropertyChanged(.LayoutViewport)
    }

    @cxx
    @implementation
    public func setSizeForVisibleContent(_ size: WebCore.FloatSize) {
        if m_sizeForVisibleContent == size {
            return
        }

        m_sizeForVisibleContent = size
        setPropertyChanged(.SizeForVisibleContent)
    }

    @cxx
    @implementation
    public func setMinLayoutViewportOrigin(_ p: WebCore.FloatPoint) {
        if m_minLayoutViewportOrigin == p {
            return
        }

        m_minLayoutViewportOrigin = p
        setPropertyChanged(.MinLayoutViewportOrigin)
    }

    @cxx
    @implementation
    public func setMaxLayoutViewportOrigin(_ p: WebCore.FloatPoint) {
        if m_maxLayoutViewportOrigin == p {
            return
        }

        m_maxLayoutViewportOrigin = p
        setPropertyChanged(.MaxLayoutViewportOrigin)
    }

    @cxx
    @implementation
    public func setOverrideVisualViewportSize(_ viewportSize: WebCore.OptionalFloatSize) {
        let newSize = Optional(fromCxx: viewportSize)
        let oldSize = Optional(fromCxx: m_overrideVisualViewportSize)
        if newSize == nil && oldSize == nil {
            return
        }
        if let newSize, let oldSize, newSize == oldSize {
            return
        }

        m_overrideVisualViewportSize = viewportSize
        setPropertyChanged(.OverrideVisualViewportSize)
    }

    @cxx
    @implementation
    public func setHeaderHeight(_ headerHeight: Int32) {
        if m_headerHeight == headerHeight {
            return
        }

        m_headerHeight = headerHeight
        setPropertyChanged(.HeaderHeight)
    }

    @cxx
    @implementation
    public func setFooterHeight(_ footerHeight: Int32) {
        if m_footerHeight == footerHeight {
            return
        }

        m_footerHeight = footerHeight
        setPropertyChanged(.FooterHeight)
    }

    @cxx
    @implementation
    public func setInsetForLeftScrollbarSpace(_ insetForLeftScrollbarSpace: Int32) {
        if m_insetForLeftScrollbarSpace == insetForLeftScrollbarSpace {
            return
        }

        m_insetForLeftScrollbarSpace = insetForLeftScrollbarSpace
        setPropertyChanged(.InsetForLeftScrollbarSpace)
    }

    #if HAVE_NSREFRESHCONTROLLER
    @cxx
    @implementation
    public func setTopScrollStretchForRefreshController(_ topScrollStretchForRefreshController: Float) {
        if m_topScrollStretchForRefreshController == topScrollStretchForRefreshController {
            return
        }

        m_topScrollStretchForRefreshController = topScrollStretchForRefreshController
        setPropertyChanged(.TopScrollStretchForRefreshController)
    }
    #endif

    @cxx
    @implementation
    public func setVisualViewportIsSmallerThanLayoutViewport(_ visualViewportIsSmallerThanLayoutViewport: Bool) {
        if visualViewportIsSmallerThanLayoutViewport == m_visualViewportIsSmallerThanLayoutViewport {
            return
        }

        m_visualViewportIsSmallerThanLayoutViewport = visualViewportIsSmallerThanLayoutViewport
        setPropertyChanged(.VisualViewportIsSmallerThanLayoutViewport)
    }

    @cxx
    @implementation
    public func setAsyncFrameOrOverflowScrollingEnabled(_ enabled: Bool) {
        if enabled == m_asyncFrameOrOverflowScrollingEnabled {
            return
        }

        m_asyncFrameOrOverflowScrollingEnabled = enabled
        setPropertyChanged(.AsyncFrameOrOverflowScrollingEnabled)
    }

    @cxx
    @implementation
    public func setWheelEventGesturesBecomeNonBlocking(_ enabled: Bool) {
        if enabled == m_wheelEventGesturesBecomeNonBlocking {
            return
        }

        m_wheelEventGesturesBecomeNonBlocking = enabled
        setPropertyChanged(.WheelEventGesturesBecomeNonBlocking)
    }

    @cxx
    @implementation
    public func setScrollingPerformanceTestingEnabled(_ enabled: Bool) {
        if enabled == m_scrollingPerformanceTestingEnabled {
            return
        }

        m_scrollingPerformanceTestingEnabled = enabled
        setPropertyChanged(.ScrollingPerformanceTestingEnabled)
    }

    @cxx
    @implementation
    public func setOverlayScrollbarsEnabled(_ enabled: Bool) {
        if m_overlayScrollbarsEnabled == enabled {
            return
        }
        m_overlayScrollbarsEnabled = enabled
        setPropertyChanged(.OverlayScrollbarsEnabled)
    }

    @cxx
    @implementation
    public func isMainFrame() -> Bool {
        nodeType() == .MainFrame
    }
}

#endif
