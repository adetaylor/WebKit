// Copyright (C) 2008 Apple Inc. All rights reserved.
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

internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.IntRect
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.Scrollbar
internal import WebCore_Private.Core.ScrollbarTheme
internal import WebCore_Private.Core.ScrollbarThemeComposite

// Returns the size represented by track taking into account scrolling past
// the end of the document.
private func usedTotalSize(_ scrollbar: WebCore.Scrollbar) -> Float {
    let overhangAtStart = -scrollbar.currentPos()
    let overhangAtEnd = scrollbar.currentPos() + Float(scrollbar.visibleSize()) - Float(scrollbar.totalSize())
    let overhang = max(0, overhangAtStart, overhangAtEnd)
    return Float(scrollbar.totalSize()) + overhang
}

// Free functions, since a call to a member this file implements does not resolve to its C++ declaration.
private func trackLengthOf(_ theme: WebCore.ScrollbarThemeComposite, _ scrollbar: WebCore.Scrollbar) -> Int32 {
    let constrainedTrackRect = theme.constrainTrackRectToTrackPieces(scrollbar, theme.trackRect(scrollbar, false))
    return scrollbar.orientation() == .Horizontal ? constrainedTrackRect.width() : constrainedTrackRect.height()
}

private func thumbLengthOf(_ theme: WebCore.ScrollbarThemeComposite, _ scrollbar: WebCore.Scrollbar) -> Int32 {
    if !scrollbar.enabled() {
        return 0
    }

    let proportion = Float(scrollbar.visibleSize()) / usedTotalSize(scrollbar)
    let trackLen = trackLengthOf(theme, scrollbar)
    var length = Int32(saturating: (proportion * Float(trackLen)).rounded())
    length = max(length, theme.minimumThumbLength(scrollbar))
    if length > trackLen {
        // Once the thumb is below the track length, it just goes away (to make more room for the track).
        length = 0
    }
    return length
}

extension WebCore.ScrollbarThemeComposite {
    @cxx
    @implementation
    public override func hitTest(
        _ scrollbar: WebCore.Scrollbar,
        _ position: WebCore.IntPoint,
        _ tolerance: WebCore.ScrollbarHitTestTolerance
    ) -> WebCore.ScrollbarPart {
        if !scrollbar.enabled() {
            return WebCore.NoPart
        }

        var testPosition = scrollbar.convertFromContainingWindow(position)
        testPosition.move(scrollbar.x(), scrollbar.y())

        if tolerance == .Expanded {
            // With expanded granularity, a point can land just off the scrollbar and miss it entirely.
            // In this case, it therefore needs to have its cross-axis be mapped to an eligible location on the scrollbar.
            //
            // Note that since maxX()/maxY() are exclusive (frameRect().contains() treats them as outside),
            // the -1 is needed to land on the last position still inside the bar.
            let bar = scrollbar.frameRect()
            if scrollbar.orientation() == .Vertical {
                testPosition.setX(min(max(testPosition.x(), bar.x()), bar.maxX() &- 1))
            } else {
                testPosition.setY(min(max(testPosition.y(), bar.y()), bar.maxY() &- 1))
            }
        }

        if !scrollbar.frameRect().contains(testPosition) {
            return WebCore.NoPart
        }

        let track = trackRect(scrollbar, false)
        if track.contains(testPosition) {
            let pieces = trackPieces(scrollbar, track)
            if pieces.thumb.contains(testPosition) {
                return WebCore.ThumbPart
            }
            if pieces.beforeThumb.contains(testPosition) {
                return WebCore.BackTrackPart
            }
            if pieces.afterThumb.contains(testPosition) {
                return WebCore.ForwardTrackPart
            }
            return WebCore.TrackBGPart
        }
        if backButtonRect(scrollbar, WebCore.BackButtonStartPart, false).contains(testPosition) {
            return WebCore.BackButtonStartPart
        }
        if backButtonRect(scrollbar, WebCore.BackButtonEndPart, false).contains(testPosition) {
            return WebCore.BackButtonEndPart
        }
        if forwardButtonRect(scrollbar, WebCore.ForwardButtonStartPart, false).contains(testPosition) {
            return WebCore.ForwardButtonStartPart
        }
        if forwardButtonRect(scrollbar, WebCore.ForwardButtonEndPart, false).contains(testPosition) {
            return WebCore.ForwardButtonEndPart
        }
        return WebCore.ScrollbarBGPart
    }

    @cxx
    @implementation
    public override func invalidatePart(_ scrollbar: WebCore.Scrollbar, _ part: WebCore.ScrollbarPart) {
        if part == WebCore.NoPart {
            return
        }

        var result: WebCore.IntRect
        switch part {
        case WebCore.BackButtonStartPart:
            result = backButtonRect(scrollbar, WebCore.BackButtonStartPart, true)
        case WebCore.BackButtonEndPart:
            result = backButtonRect(scrollbar, WebCore.BackButtonEndPart, true)
        case WebCore.ForwardButtonStartPart:
            result = forwardButtonRect(scrollbar, WebCore.ForwardButtonStartPart, true)
        case WebCore.ForwardButtonEndPart:
            result = forwardButtonRect(scrollbar, WebCore.ForwardButtonEndPart, true)
        case WebCore.TrackBGPart:
            result = trackRect(scrollbar, true)
        case WebCore.ScrollbarBGPart:
            result = scrollbar.frameRect()
        default:
            let pieces = trackPieces(scrollbar, trackRect(scrollbar, false))
            if part == WebCore.BackTrackPart {
                result = pieces.beforeThumb
            } else if part == WebCore.ForwardTrackPart {
                result = pieces.afterThumb
            } else {
                result = pieces.thumb
            }
        }
        let location = scrollbar.location()
        result.move(0 &- location.x(), 0 &- location.y())
        scrollbar.invalidateRect(result)
    }

    @cxx
    @implementation
    public override func thumbPosition(_ scrollbar: WebCore.Scrollbar) -> Int32 {
        if scrollbar.enabled() {
            let size = usedTotalSize(scrollbar) - Float(scrollbar.visibleSize())
            // Avoid doing a floating point divide by zero and return 1 when usedTotalSize == visibleSize.
            if size == 0 {
                return 1
            }
            let pos = max(0, scrollbar.currentPos()) * Float(trackLengthOf(self, scrollbar) &- thumbLengthOf(self, scrollbar)) / size
            return (pos < 1 && pos > 0) ? 1 : Int32(saturating: pos)
        }
        return 0
    }

    @cxx
    @implementation
    public override func thumbLength(_ scrollbar: WebCore.Scrollbar) -> Int32 {
        thumbLengthOf(self, scrollbar)
    }

    @cxx
    @implementation
    public override func trackPosition(_ scrollbar: WebCore.Scrollbar) -> Int32 {
        let constrainedTrackRect = constrainTrackRectToTrackPieces(scrollbar, trackRect(scrollbar, false))
        return scrollbar.orientation() == .Horizontal
            ? constrainedTrackRect.x() &- scrollbar.x() : constrainedTrackRect.y() &- scrollbar.y()
    }

    @cxx
    @implementation
    public override func trackLength(_ scrollbar: WebCore.Scrollbar) -> Int32 {
        trackLengthOf(self, scrollbar)
    }

    @cxx
    @implementation
    func thumbRect(_ scrollbar: WebCore.Scrollbar) -> WebCore.IntRect {
        if !hasThumb(scrollbar) {
            return WebCore.IntRect()
        }

        return trackPieces(scrollbar, trackRect(scrollbar, false)).thumb
    }
}

extension WebCore.ScrollbarThemeComposite {
    // splitTrack()'s three rects.
    fileprivate func trackPieces(
        _ scrollbar: WebCore.Scrollbar,
        _ track: WebCore.IntRect
    ) -> (beforeThumb: WebCore.IntRect, thumb: WebCore.IntRect, afterThumb: WebCore.IntRect) {
        var beforeThumb = WebCore.IntRect()
        var thumb = WebCore.IntRect()
        var afterThumb = WebCore.IntRect()
        splitTrack(scrollbar, track, &beforeThumb, &thumb, &afterThumb)
        return (beforeThumb, thumb, afterThumb)
    }
}
