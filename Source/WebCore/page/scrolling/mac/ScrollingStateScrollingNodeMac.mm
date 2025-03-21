/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "ScrollingStateScrollingNode.h"

#if ENABLE(ASYNC_SCROLLING) && PLATFORM(MAC)

#import "GraphicsLayer.h"
#import "Scrollbar.h"
#import "ScrollbarThemeMac.h"
#import "ScrollingStateTree.h"

namespace WebCore {

void ScrollingStateScrollingNode::setScrollerImpsFromScrollbars(Scrollbar* verticalScrollbar, Scrollbar* horizontalScrollbar)
{
    ScrollbarTheme& scrollbarTheme = ScrollbarTheme::theme();
    if (scrollbarTheme.isMockTheme())
        return;
    ScrollbarThemeMac& macTheme = downcast<ScrollbarThemeMac>(scrollbarTheme);

    NSScrollerImp *verticalPainter = verticalScrollbar && verticalScrollbar->supportsUpdateOnSecondaryThread()
        ? macTheme.scrollerImpForScrollbar(*verticalScrollbar) : nullptr;
    NSScrollerImp *horizontalPainter = horizontalScrollbar && horizontalScrollbar->supportsUpdateOnSecondaryThread()
        ? macTheme.scrollerImpForScrollbar(*horizontalScrollbar) : nullptr;

    if (m_verticalScrollerImp == verticalPainter && m_horizontalScrollerImp == horizontalPainter)
        return;

    m_verticalScrollerImp = verticalPainter;
    m_horizontalScrollerImp = horizontalPainter;

    setPropertyChanged(Property::PainterForScrollbar);
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING) && PLATFORM(MAC)
