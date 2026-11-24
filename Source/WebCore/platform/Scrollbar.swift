// Copyright (C) 2004, 2006, 2008, 2015 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

internal import WebCore_Private.Core.DeprecatedGlobalSettings
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.Scrollbar
internal import WebCore_Private.Core.ScrollbarTheme

private let themeMaxOverlapBetweenPages = WebCore.ScrollbarTheme.theme().maxOverlapBetweenPages()

extension WebCore.Scrollbar {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    @cxx
    @implementation
    public static func maxOverlapBetweenPages() -> Int32 {
        themeMaxOverlapBetweenPages
    }

    @cxx
    @implementation
    func occupiedWidth() -> Int32 {
        isOverlayScrollbar() ? 0 : width()
    }

    @cxx
    @implementation
    func occupiedHeight() -> Int32 {
        isOverlayScrollbar() ? 0 : height()
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    @cxx
    @implementation
    public func setProportion(_ visibleSize: Int32, _ totalSize: Int32) {
        if visibleSize == m_visibleSize && totalSize == m_totalSize {
            return
        }

        m_visibleSize = visibleSize
        m_totalSize = totalSize

        updateThumbProportion()
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    @cxx
    @implementation
    public func setSteps(_ lineStep: Int32, _ pageStep: Int32, _ pixelsPerStep: Int32) {
        m_lineStep = lineStep
        m_pageStep = pageStep
        m_pixelStep = 1 / Float(pixelsPerStep)
    }

    @cxx
    @implementation
    func updateThumbPosition() {
        updateThumb()
    }

    @cxx
    @implementation
    func autoscrollTimerFired() {
        autoscrollPressedPart(theme().autoscrollTimerDelay())
    }

    private var pressedPartIsBackward: Bool {
        m_pressedPart == WebCore.BackButtonStartPart || m_pressedPart == WebCore.BackButtonEndPart
            || m_pressedPart == WebCore.BackTrackPart
    }

    @cxx
    @implementation
    func pressedPartScrollDirection() -> WebCore.ScrollDirection {
        if m_orientation == .Horizontal {
            return pressedPartIsBackward ? .left : .right
        }
        return pressedPartIsBackward ? .up : .down
    }

    @cxx
    @implementation
    func pressedPartScrollGranularity() -> WebCore.ScrollGranularity {
        switch m_pressedPart {
        case WebCore.BackButtonStartPart, WebCore.BackButtonEndPart, WebCore.ForwardButtonStartPart,
            WebCore.ForwardButtonEndPart:
            return .Line
        default:
            return .Page
        }
    }

    @cxx
    @implementation
    func moveThumb(_ pos: Int32, _ draggingDocument: Bool) {
        // Pixel offsets, far from Int32's range.
        var delta = pos &- m_pressedPos

        if draggingDocument {
            if m_draggingDocument {
                delta = pos &- m_documentDragPos
            }
            m_draggingDocument = true
            let currentPosition = scrollAnimatorCurrentPosition()
            let axisPosition = m_orientation == .Horizontal ? currentPosition.x() : currentPosition.y()
            var destinationPosition = Int32(saturating: axisPosition + Float(delta))
            if delta > 0 {
                destinationPosition = min(destinationPosition &+ delta, maximum())
            } else if delta < 0 {
                destinationPosition = max(destinationPosition &+ delta, 0)
            }
            scrollScrollableAreaToOffsetWithoutAnimation(Float(destinationPosition))
            m_documentDragPos = pos
            return
        }

        if m_draggingDocument {
            delta = delta &+ (m_pressedPos &- m_documentDragPos)
            m_draggingDocument = false
        }

        // Drag the thumb.
        let theme = self.theme()
        let thumbPos = theme.thumbPosition(self)
        let thumbLen = theme.thumbLength(self)
        let trackLen = theme.trackLength(self)
        let maxPos = trackLen &- thumbLen
        if delta > 0 {
            delta = min(maxPos &- thumbPos, delta)
        } else if delta < 0 {
            delta = max(0 &- thumbPos, delta)
        }

        if delta != 0 {
            let newOffset = Float(thumbPos &+ delta) * Float(maximum()) / Float(trackLen &- thumbLen)
            scrollScrollableAreaToOffsetWithoutAnimation(newOffset)
        }
    }

    @cxx
    @implementation
    func setEnabled(_ e: Bool) {
        if m_enabled == e {
            return
        }
        m_enabled = e
        theme().updateEnabledState(self)
        updateScrollbarsControllerEnabledState()
        invalidate()
    }

    @cxx
    @implementation
    func expandedHitTestToleranceThreshold() -> Int32 {
        #if os(macOS)
        // Match AppKit.
        return isOverlayScrollbar() ? 20 : 10
        #else
        return 0
        #endif
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    @cxx
    @implementation
    public func isMockScrollbar() -> Bool {
        theme().isMockTheme()
    }

    @cxx
    @implementation
    func shouldParticipateInHitTesting() -> Bool {
        // Non-overlay scrollbars should always participate in hit testing.
        if !isOverlayScrollbar() {
            return true
        }
        return scrollbarsControllerShouldParticipateInHitTesting()
    }

    @cxx
    @implementation
    func isHiddenByStyle() -> Bool {
        m_widthStyle == .None
    }

    @cxx
    @implementation
    static func nativeScrollbarVisibility(_ scrollbar: WebCore.Scrollbar?) -> WebCore.NativeScrollbarVisibility {
        if let scrollbar, scrollbar.isHiddenByStyle() {
            return .HiddenByStyle
        }
        if WebCore.DeprecatedGlobalSettings.mockScrollbarsEnabled() || scrollbar?.isCustomScrollbar() == true {
            return .ReplacedByCustomScrollbar
        }
        return .Visible
    }
}

extension Int32 {
    // The value a C++ float-to-int conversion gives on the platforms WebKit targets: truncated toward zero, saturated
    // at the type's bounds, and 0 for NaN.
    init(saturating value: Float) {
        if value.isNaN {
            self = 0
        } else if value >= 2_147_483_648 {
            self = .max
        } else if value <= -2_147_483_648 {
            self = .min
        } else {
            self.init(value)
        }
    }
}
