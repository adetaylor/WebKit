// Copyright (C) 2008-2017 Apple Inc. All rights reserved.
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

#if os(macOS)

internal import AppKit
internal import Carbon
internal import WebCore_Private.Core.IntRect
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.Scrollbar
internal import WebCore_Private.Core.ScrollbarTheme
internal import WebCore_Private.Core.ScrollbarThemeComposite
internal import WebCore_Private.Core.ScrollbarThemeMac
internal import pal.spi.mac.NSScrollerImpSPI

// FIXME: Get these numbers from CoreUI.
private let cRealButtonLength: [Int32] = [28, 21]
private let cButtonHitInset: [Int32] = [3, 2]
// cRealButtonLength - cButtonInset
private let cButtonLength: [Int32] = [14, 10]

private let cOuterButtonLength: [Int32] = [16, 14] // The outer button in a double button pair is a bit bigger.
private let cOuterButtonOverlap: Int32 = 2

private func scrollbarWidthToIndex(_ scrollbarWidth: WebCore.ScrollbarWidth) -> Int {
    switch scrollbarWidth {
    case .Auto, .None:
        return 0
    case .Thin:
        return 1
    @unknown default:
        return 0
    }
}

extension NSScrollerImp {
    fileprivate var minimumLengthForThumb: CGFloat {
        knobMinLength + trackOverlapEndInset + knobOverlapEndInset + 2 * (trackEndInset + knobEndInset)
    }
}

// A free function, since hasButtons is protected on ScrollbarThemeMac and a call to it from trackRect does not resolve.
// No class derives from ScrollbarThemeMac, so nothing is lost to dispatch.
private func themeHasButtons(_ theme: WebCore.ScrollbarThemeMac, _ scrollbar: WebCore.Scrollbar) -> Bool {
    if scrollbar.enabled() && theme.buttonsPlacement() != WebCore.ScrollbarButtonsNone
        && scrollbar.orientation() == .Horizontal
    {
        return scrollbar.width() != 0
    }
    let index = scrollbarWidthToIndex(scrollbar.widthStyle())
    // Pixel lengths, far from Int32's range.
    return scrollbar.height() >= 2 &* (cRealButtonLength[index] &- cButtonHitInset[index])
}

extension WebCore.ScrollbarThemeMac {
    @cxx
    @implementation
    public override func hasButtons(_ scrollbar: WebCore.Scrollbar) -> Bool {
        themeHasButtons(self, scrollbar)
    }

    @cxx
    @implementation
    public override func hasThumb(_ scrollbar: WebCore.Scrollbar) -> Bool {
        let scrollerImp: NSScrollerImp? = WebCore.ScrollbarThemeMac.scrollerImpForScrollbar(scrollbar)
        let minLengthForThumb = (scrollerImp?.minimumLengthForThumb ?? 0).rounded(.towardZero)

        let length = scrollbar.orientation() == .Horizontal ? scrollbar.width() : scrollbar.height()
        return scrollbar.enabled() && CGFloat(length) >= minLengthForThumb
    }

    private func buttonRepaintRect(
        for buttonRect: WebCore.IntRect,
        orientation: WebCore.ScrollbarOrientation,
        widthStyle: WebCore.ScrollbarWidth,
        isStart: Bool
    ) -> WebCore.IntRect {
        assert(buttonsPlacement() != WebCore.ScrollbarButtonsNone)

        let realButtonLength = cRealButtonLength[scrollbarWidthToIndex(widthStyle)]
        var paintRect = buttonRect
        if orientation == .Horizontal {
            paintRect.setWidth(realButtonLength)
            if !isStart {
                paintRect.setX(buttonRect.x() &- (realButtonLength &- buttonRect.width()))
            }
        } else {
            paintRect.setHeight(realButtonLength)
            if !isStart {
                paintRect.setY(buttonRect.y() &- (realButtonLength &- buttonRect.height()))
            }
        }

        return paintRect
    }

    @cxx
    @implementation
    public override func backButtonRect(
        _ scrollbar: WebCore.Scrollbar,
        _ part: WebCore.ScrollbarPart,
        _ painting: Bool
    ) -> WebCore.IntRect {
        let placement = buttonsPlacement()

        if part == WebCore.BackButtonStartPart
            && (placement == WebCore.ScrollbarButtonsNone || placement == WebCore.ScrollbarButtonsDoubleEnd)
        {
            return WebCore.IntRect()
        }

        if part == WebCore.BackButtonEndPart
            && (placement == WebCore.ScrollbarButtonsNone || placement == WebCore.ScrollbarButtonsDoubleStart
                || placement == WebCore.ScrollbarButtonsSingle)
        {
            return WebCore.IntRect()
        }

        let thickness = scrollbarThickness(scrollbar.widthStyle(), .IncludeOverlayScrollbarSize)
        let index = scrollbarWidthToIndex(scrollbar.widthStyle())
        let outerButton =
            part == WebCore.BackButtonStartPart
            && (placement == WebCore.ScrollbarButtonsDoubleStart || placement == WebCore.ScrollbarButtonsDoubleBoth)
        if outerButton {
            let outerButtonLength = cOuterButtonLength[index] &+ (painting ? cOuterButtonOverlap : 0)
            if scrollbar.orientation() == .Horizontal {
                return WebCore.IntRect(scrollbar.x(), scrollbar.y(), outerButtonLength, thickness)
            }
            return WebCore.IntRect(scrollbar.x(), scrollbar.y(), thickness, outerButtonLength)
        }

        // Our repaint rect is slightly larger, since we are a button that is adjacent to the track.
        let result: WebCore.IntRect
        if scrollbar.orientation() == .Horizontal {
            let start =
                part == WebCore.BackButtonStartPart
                ? scrollbar.x() : scrollbar.x() &+ scrollbar.width() &- cOuterButtonLength[index] &- cButtonLength[index]
            result = WebCore.IntRect(start, scrollbar.y(), cButtonLength[index], thickness)
        } else {
            let start =
                part == WebCore.BackButtonStartPart
                ? scrollbar.y() : scrollbar.y() &+ scrollbar.height() &- cOuterButtonLength[index] &- cButtonLength[index]
            result = WebCore.IntRect(scrollbar.x(), start, thickness, cButtonLength[index])
        }

        if painting {
            return buttonRepaintRect(
                for: result,
                orientation: scrollbar.orientation(),
                widthStyle: scrollbar.widthStyle(),
                isStart: part == WebCore.BackButtonStartPart
            )
        }
        return result
    }

    @cxx
    @implementation
    public override func forwardButtonRect(
        _ scrollbar: WebCore.Scrollbar,
        _ part: WebCore.ScrollbarPart,
        _ painting: Bool
    ) -> WebCore.IntRect {
        let placement = buttonsPlacement()

        if part == WebCore.ForwardButtonEndPart
            && (placement == WebCore.ScrollbarButtonsNone || placement == WebCore.ScrollbarButtonsDoubleStart)
        {
            return WebCore.IntRect()
        }

        if part == WebCore.ForwardButtonStartPart
            && (placement == WebCore.ScrollbarButtonsNone || placement == WebCore.ScrollbarButtonsDoubleEnd
                || placement == WebCore.ScrollbarButtonsSingle)
        {
            return WebCore.IntRect()
        }

        let thickness = scrollbarThickness(scrollbar.widthStyle(), .IncludeOverlayScrollbarSize)
        let outerButtonLength = cOuterButtonLength[scrollbarWidthToIndex(scrollbar.widthStyle())]
        let buttonLength = cButtonLength[scrollbarWidthToIndex(scrollbar.widthStyle())]

        let outerButton =
            part == WebCore.ForwardButtonEndPart
            && (placement == WebCore.ScrollbarButtonsDoubleEnd || placement == WebCore.ScrollbarButtonsDoubleBoth)
        if outerButton {
            var result: WebCore.IntRect
            if scrollbar.orientation() == .Horizontal {
                result = WebCore.IntRect(
                    scrollbar.x() &+ scrollbar.width() &- outerButtonLength,
                    scrollbar.y(),
                    outerButtonLength,
                    thickness
                )
                if painting {
                    result.inflateX(cOuterButtonOverlap)
                }
            } else {
                result = WebCore.IntRect(
                    scrollbar.x(),
                    scrollbar.y() &+ scrollbar.height() &- outerButtonLength,
                    thickness,
                    outerButtonLength
                )
                if painting {
                    result.inflateY(cOuterButtonOverlap)
                }
            }
            return result
        }

        let result: WebCore.IntRect
        if scrollbar.orientation() == .Horizontal {
            let start =
                part == WebCore.ForwardButtonEndPart
                ? scrollbar.x() &+ scrollbar.width() &- buttonLength : scrollbar.x() &+ outerButtonLength
            result = WebCore.IntRect(start, scrollbar.y(), buttonLength, thickness)
        } else {
            let start =
                part == WebCore.ForwardButtonEndPart
                ? scrollbar.y() &+ scrollbar.height() &- buttonLength : scrollbar.y() &+ outerButtonLength
            result = WebCore.IntRect(scrollbar.x(), start, thickness, buttonLength)
        }
        if painting {
            return buttonRepaintRect(
                for: result,
                orientation: scrollbar.orientation(),
                widthStyle: scrollbar.widthStyle(),
                isStart: part == WebCore.ForwardButtonStartPart
            )
        }
        return result
    }

    @cxx
    @implementation
    public override func trackRect(_ scrollbar: WebCore.Scrollbar, _ painting: Bool) -> WebCore.IntRect {
        if painting || !themeHasButtons(self, scrollbar) {
            return scrollbar.frameRect()
        }

        let thickness = scrollbarThickness(scrollbar.widthStyle(), .IncludeOverlayScrollbarSize)
        let outerButtonLength = cOuterButtonLength[scrollbarWidthToIndex(scrollbar.widthStyle())]
        let buttonLength = cButtonLength[scrollbarWidthToIndex(scrollbar.widthStyle())]
        let doubleButtonLength = outerButtonLength &+ buttonLength
        let (startWidth, endWidth): (Int32, Int32)
        switch buttonsPlacement() {
        case WebCore.ScrollbarButtonsSingle:
            (startWidth, endWidth) = (buttonLength, buttonLength)
        case WebCore.ScrollbarButtonsDoubleStart:
            (startWidth, endWidth) = (doubleButtonLength, 0)
        case WebCore.ScrollbarButtonsDoubleEnd:
            (startWidth, endWidth) = (0, doubleButtonLength)
        case WebCore.ScrollbarButtonsDoubleBoth:
            (startWidth, endWidth) = (doubleButtonLength, doubleButtonLength)
        default:
            (startWidth, endWidth) = (0, 0)
        }

        let totalWidth = startWidth &+ endWidth
        if scrollbar.orientation() == .Horizontal {
            return WebCore.IntRect(
                scrollbar.x() &+ startWidth,
                scrollbar.y(),
                scrollbar.width() &- totalWidth,
                thickness
            )
        }
        return WebCore.IntRect(
            scrollbar.x(),
            scrollbar.y() &+ startWidth,
            thickness,
            scrollbar.height() &- totalWidth
        )
    }

    @cxx
    @implementation
    func scrollbarPartToHIPressedState(_ part: WebCore.ScrollbarPart) -> Int32 {
        switch part {
        case WebCore.BackButtonStartPart:
            return Int32(kThemeTopOutsideArrowPressed)
        case WebCore.BackButtonEndPart:
            return Int32(kThemeTopOutsideArrowPressed) // This does not make much sense.  For some reason the outside constant is required.
        case WebCore.ForwardButtonStartPart:
            return Int32(kThemeTopInsideArrowPressed)
        case WebCore.ForwardButtonEndPart:
            return Int32(kThemeBottomOutsideArrowPressed)
        case WebCore.ThumbPart:
            return Int32(kThemeThumbPressed)
        default:
            return 0
        }
    }
}

#endif
