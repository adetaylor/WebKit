// Copyright (C) 2014 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateFrameScrollingNode
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import wtf

extension WebCore.ScrollingTreeFrameScrollingNode {
    @cxx
    @implementation
    func commitFrameScrollingNodeState(
        _ state: borrowing WebCore.ScrollingStateFrameScrollingNode,
        _ changedPropertiesRaw: UInt64
    ) {
        let changedProperties = ScrollingStateChangedProperties(rawValue: changedPropertiesRaw)
        if changedProperties.contains(.FrameScaleFactor) {
            m_frameScaleFactor = state.frameScaleFactorValue
        }

        if changedProperties.contains(.HeaderHeight) {
            m_headerHeight = state.headerHeightValue
        }

        if changedProperties.contains(.FooterHeight) {
            m_footerHeight = state.footerHeightValue
        }

        if changedProperties.contains(.BehaviorForFixedElements) {
            m_behaviorForFixed = state.scrollBehaviorForFixedElementsValue
        }

        if changedProperties.contains(.ObscuredContentInsets) {
            m_obscuredContentInsets = state.obscuredContentInsetsValue
        }

        if changedProperties.contains(.InsetForLeftScrollbarSpace) {
            m_insetForLeftScrollbarSpace = state.insetForLeftScrollbarSpaceValue
        }

        #if HAVE_NSREFRESHCONTROLLER
        if changedProperties.contains(.TopScrollStretchForRefreshController) {
            m_topScrollStretchForRefreshController = state.topScrollStretchForRefreshControllerValue
        }
        #endif

        if changedProperties.contains(.VisualViewportIsSmallerThanLayoutViewport) {
            m_visualViewportIsSmallerThanLayoutViewport = state.visualViewportIsSmallerThanLayoutViewportValue
        }

        if changedProperties.contains(.LayoutViewport) {
            m_layoutViewport = state.layoutViewportValue
        }

        if changedProperties.contains(.SizeForVisibleContent) {
            m_sizeForVisibleContent = state.sizeForVisibleContentValue
        }

        if changedProperties.contains(.MinLayoutViewportOrigin) {
            m_minLayoutViewportOrigin = state.minLayoutViewportOriginValue
        }

        if changedProperties.contains(.MaxLayoutViewportOrigin) {
            m_maxLayoutViewportOrigin = state.maxLayoutViewportOriginValue
        }

        if changedProperties.contains(.OverrideVisualViewportSize) {
            m_overrideVisualViewportSize = state.overrideVisualViewportSizeValue
        }
    }

    @cxx
    @implementation
    public override func scrollPositionAndLayoutViewportMatch(
        _ position: WebCore.FloatPoint,
        _ overrideLayoutViewport: WebCore.OptionalFloatRect
    ) -> Bool {
        guard position == currentScrollPosition() else {
            return false
        }
        guard let overrideLayoutViewport = Optional(fromCxx: overrideLayoutViewport) else {
            return true
        }
        return overrideLayoutViewport == m_layoutViewport
    }

    @cxx
    @implementation
    public override func updateViewportForCurrentScrollPosition(_ overrideLayoutViewport: WebCore.OptionalFloatRect) {
        setLayoutViewportForCurrentScrollPosition(Optional(fromCxx: overrideLayoutViewport))
    }

    fileprivate func setLayoutViewportForCurrentScrollPosition(_ overrideLayoutViewport: WebCore.FloatRect?) {
        if let overrideLayoutViewport {
            setLayoutViewport(overrideLayoutViewport)
        } else {
            setLayoutViewport(layoutViewportForScrollPosition(currentScrollPosition(), frameScaleFactor(), .StickToDocumentBounds))
        }
    }

    @cxx
    @implementation
    public func layoutViewportRespectingRubberBanding() -> WebCore.FloatRect {
        layoutViewportForScrollPosition(currentScrollPosition(), frameScaleFactor(), .StickToViewportBounds)
    }

    @cxx
    @implementation
    public func delegatedPageScaleFactor() -> Float {
        m_delegatedPageScaleFactor
    }

    @cxx
    @implementation
    public func setDelegatedPageScaleFactor(_ scale: Float) {
        m_delegatedPageScaleFactor = scale
    }

    @cxx
    @implementation
    public func insetForLeftScrollbarSpace() -> Int32 {
        m_insetForLeftScrollbarSpace
    }

    @cxx
    @implementation
    public func sizeForVisibleContent() -> WebCore.FloatSize {
        m_sizeForVisibleContent
    }

    // The horizontal and vertical space the left scrollbar, the obscured insets and the header take up in view coordinates.
    private var viewToContentsInsets: WebCore.FloatSize {
        let obscuredContentInsets = self.obscuredContentInsets()
        return WebCore.FloatSize(
            Float(insetForLeftScrollbarSpace()) + obscuredContentInsets[.Left],
            Float(headerHeight()) + obscuredContentInsets[.Top]
        )
    }

    @cxx
    @implementation
    public func viewToContentsOffset(_ scrollPosition: WebCore.FloatPoint) -> WebCore.FloatSize {
        WebCore.toFloatSize(scrollPosition) - viewToContentsInsets
    }

    @cxx
    @implementation
    public func viewToContentsPoint(
        _ pointInViewCoordinates: WebCore.FloatPoint,
        _ scrollPosition: WebCore.FloatPoint
    ) -> WebCore.FloatPoint {
        // The insets and the header aren't zoomed, so they come off before undoing the zoom. The scroll position
        // is already in contents coordinates, so it goes on after. A no-op at scale 1.
        let insets = viewToContentsInsets
        var point = pointInViewCoordinates
        point.move(-insets.width(), -insets.height())
        point.scale(1 / delegatedPageScaleFactor())
        point.moveBy(scrollPosition)
        return point
    }

    @cxx
    @implementation
    func frameScrollingNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.appendUTF8("frame scrolling node".utf8.span)
        writeScrollingNodeProperties(to: &ts, behavior)

        ts.writeScrollingProperty("layout viewport") { $0.append(m_layoutViewport) }

        if !(m_layoutViewport.size() == m_sizeForVisibleContent) {
            ts.writeScrollingProperty("size for visible content") { $0.append(m_sizeForVisibleContent) }
        }

        ts.writeScrollingProperty("min layoutViewport origin") { $0.append(m_minLayoutViewportOrigin) }
        ts.writeScrollingProperty("max layoutViewport origin") { $0.append(m_maxLayoutViewportOrigin) }

        if let overrideVisualViewportSize = Optional(fromCxx: m_overrideVisualViewportSize) {
            ts.writeScrollingProperty("override visual viewport size") { $0.append(overrideVisualViewportSize) }
        }

        if m_frameScaleFactor != 1 {
            ts.writeScrollingProperty("frame scale factor") { $0.append(m_frameScaleFactor) }
        }

        let obscuredContentInsetProperties: [(Swift.String, WebCore.BoxSide)] = [
            ("top content inset", .Top), ("bottom content inset", .Bottom), ("left content inset", .Left),
            ("right content inset", .Right),
        ]
        for (name, side) in obscuredContentInsetProperties where m_obscuredContentInsets[side] != 0 {
            ts.writeScrollingProperty(name) { $0.append(m_obscuredContentInsets[side]) }
        }
        #if HAVE_NSREFRESHCONTROLLER
        if m_topScrollStretchForRefreshController != 0 {
            ts.writeScrollingProperty("top scroll stretch for refresh controller") {
                $0.append(m_topScrollStretchForRefreshController)
            }
        }
        #endif

        if m_headerHeight != 0 {
            ts.writeScrollingProperty("header height") { $0.append(m_headerHeight) }
        }
        if m_footerHeight != 0 {
            ts.writeScrollingProperty("footer height") { $0.append(m_footerHeight) }
        }

        ts.writeScrollingProperty("behavior for fixed") { $0.append(m_behaviorForFixed) }
        if m_visualViewportIsSmallerThanLayoutViewport {
            ts.writeScrollingProperty("visual viewport is smaller than layout viewport") {
                $0.append(m_visualViewportIsSmallerThanLayoutViewport)
            }
        }

        return ts.release()
    }
}

#endif
