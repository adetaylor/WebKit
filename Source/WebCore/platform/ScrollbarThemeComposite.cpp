/*
 * Copyright (C) 2008 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"
#include "ScrollbarThemeComposite.h"

#include "GraphicsContext.h"
#include "Scrollbar.h"

namespace WebCore {

bool ScrollbarThemeComposite::paint(Scrollbar& scrollbar, GraphicsContext& graphicsContext, const IntRect& damageRect, OptionSet<ScrollbarPaintBehavior>)
{
    // Create the ScrollbarControlPartMask based on the damageRect
    ScrollbarControlPartMask scrollMask = NoPart;

    IntRect backButtonStartPaintRect;
    IntRect backButtonEndPaintRect;
    IntRect forwardButtonStartPaintRect;
    IntRect forwardButtonEndPaintRect;
    if (hasButtons(scrollbar)) {
        backButtonStartPaintRect = backButtonRect(scrollbar, BackButtonStartPart, true);
        if (damageRect.intersects(backButtonStartPaintRect))
            scrollMask |= BackButtonStartPart;
        backButtonEndPaintRect = backButtonRect(scrollbar, BackButtonEndPart, true);
        if (damageRect.intersects(backButtonEndPaintRect))
            scrollMask |= BackButtonEndPart;
        forwardButtonStartPaintRect = forwardButtonRect(scrollbar, ForwardButtonStartPart, true);
        if (damageRect.intersects(forwardButtonStartPaintRect))
            scrollMask |= ForwardButtonStartPart;
        forwardButtonEndPaintRect = forwardButtonRect(scrollbar, ForwardButtonEndPart, true);
        if (damageRect.intersects(forwardButtonEndPaintRect))
            scrollMask |= ForwardButtonEndPart;
    }

    IntRect startTrackRect;
    IntRect thumbRect;
    IntRect endTrackRect;
    IntRect trackPaintRect = trackRect(scrollbar, true);
    if (damageRect.intersects(trackPaintRect))
        scrollMask |= TrackBGPart;
    bool thumbPresent = hasThumb(scrollbar);
    if (thumbPresent) {
        IntRect track = trackRect(scrollbar);
        splitTrack(scrollbar, track, startTrackRect, thumbRect, endTrackRect);
        if (damageRect.intersects(thumbRect))
            scrollMask |= ThumbPart;
        if (damageRect.intersects(startTrackRect))
            scrollMask |= BackTrackPart;
        if (damageRect.intersects(endTrackRect))
            scrollMask |= ForwardTrackPart;
    }

    willPaintScrollbar(graphicsContext, scrollbar);
    
    // Paint the scrollbar background (only used by custom CSS scrollbars).
    paintScrollbarBackground(graphicsContext, scrollbar);

    // Paint the back and forward buttons.
    if (scrollMask & BackButtonStartPart)
        paintButton(graphicsContext, scrollbar, backButtonStartPaintRect, BackButtonStartPart);
    if (scrollMask & BackButtonEndPart)
        paintButton(graphicsContext, scrollbar, backButtonEndPaintRect, BackButtonEndPart);
    if (scrollMask & ForwardButtonStartPart)
        paintButton(graphicsContext, scrollbar, forwardButtonStartPaintRect, ForwardButtonStartPart);
    if (scrollMask & ForwardButtonEndPart)
        paintButton(graphicsContext, scrollbar, forwardButtonEndPaintRect, ForwardButtonEndPart);
    
    if (scrollMask & TrackBGPart)
        paintTrackBackground(graphicsContext, scrollbar, trackPaintRect);
    
    if ((scrollMask & ForwardTrackPart) || (scrollMask & BackTrackPart)) {
        // Paint the track pieces above and below the thumb.
        if (scrollMask & BackTrackPart)
            paintTrackPiece(graphicsContext, scrollbar, startTrackRect, BackTrackPart);
        if (scrollMask & ForwardTrackPart)
            paintTrackPiece(graphicsContext, scrollbar, endTrackRect, ForwardTrackPart);

        paintTickmarks(graphicsContext, scrollbar, trackPaintRect);
    }

    // Paint the thumb.
    if (scrollMask & ThumbPart)
        paintThumb(graphicsContext, scrollbar, thumbRect);

    didPaintScrollbar(graphicsContext, scrollbar);
    return true;
}

void ScrollbarThemeComposite::splitTrack(Scrollbar& scrollbar, const IntRect& unconstrainedTrackRect, IntRect& beforeThumbRect, IntRect& thumbRect, IntRect& afterThumbRect)
{
    // This function won't even get called unless we're big enough to have some combination of these three rects where at least
    // one of them is non-empty.
    IntRect trackRect = constrainTrackRectToTrackPieces(scrollbar, unconstrainedTrackRect);
    int thickness = scrollbar.orientation() == ScrollbarOrientation::Horizontal ? scrollbar.height() : scrollbar.width();
    int thumbPos = thumbPosition(scrollbar);
    if (scrollbar.orientation() == ScrollbarOrientation::Horizontal) {
        thumbRect = IntRect(trackRect.x() + thumbPos, trackRect.y() + (trackRect.height() - thickness) / 2, thumbLength(scrollbar), thickness);
        beforeThumbRect = IntRect(trackRect.x(), trackRect.y(), thumbPos + thumbRect.width() / 2, trackRect.height()); 
        afterThumbRect = IntRect(trackRect.x() + beforeThumbRect.width(), trackRect.y(), trackRect.maxX() - beforeThumbRect.maxX(), trackRect.height());
    } else {
        thumbRect = IntRect(trackRect.x() + (trackRect.width() - thickness) / 2, trackRect.y() + thumbPos, thickness, thumbLength(scrollbar));
        beforeThumbRect = IntRect(trackRect.x(), trackRect.y(), trackRect.width(), thumbPos + thumbRect.height() / 2); 
        afterThumbRect = IntRect(trackRect.x(), trackRect.y() + beforeThumbRect.height(), trackRect.width(), trackRect.maxY() - beforeThumbRect.maxY());
    }
}

int ScrollbarThemeComposite::minimumThumbLength(Scrollbar& scrollbar)
{
    return scrollbarThickness(scrollbar.widthStyle());
}

void ScrollbarThemeComposite::paintOverhangAreas(ScrollView&, GraphicsContext& context, const IntRect& horizontalOverhangRect, const IntRect& verticalOverhangRect, const IntRect& dirtyRect)
{    
    context.setFillColor(Color::white);
    if (!horizontalOverhangRect.isEmpty())
        context.fillRect(intersection(horizontalOverhangRect, dirtyRect));

    context.setFillColor(Color::white);
    if (!verticalOverhangRect.isEmpty())
        context.fillRect(intersection(verticalOverhangRect, dirtyRect));
}

}
