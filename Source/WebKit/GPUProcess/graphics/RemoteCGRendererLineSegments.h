/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#pragma once

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/Color.h>
#include <WebCore/FloatSegment.h>
#include <span>
#include <wtf/Vector.h>

namespace WebKit {

// The line segments of RemoteCGRenderer's DrawLinesForText. They go as RemoteGraphicsContext's span of them does, and the GPU
// process decodes them into a copy of its own: the web process can still write the stream buffer while the message is handled.
class RemoteCGRendererLineSegments {
public:
    explicit RemoteCGRendererLineSegments(std::span<const WebCore::FloatSegment> segments)
        : m_segments(segments)
    {
    }

    std::span<const WebCore::FloatSegment> span() const LIFETIME_BOUND { return m_segments.span(); }

private:
    Vector<WebCore::FloatSegment> m_segments;
};

// What GraphicsContextCG::drawLinesForText() fills for the segments, in a context of the CTM and stroke color.
class RemoteCGRendererTextLines {
public:
    RemoteCGRendererTextLines(const RemoteCGRendererLineSegments& segments, CGAffineTransform ctm, const CGRendererColorValue& strokeColor, WebCore::FloatPoint origin, float thickness, bool printing, bool doubleLines, WebCore::StrokeStyle strokeStyle)
    {
        CGRendererRectsForLinesForText(WebCore::AffineTransform { ctm }, CGRendererColorFromValue(strokeColor), origin, thickness, segments.span(), printing, doubleLines, strokeStyle, m_rects, m_color);
    }

    bool isEmpty() const { return m_rects.isEmpty(); }
    CGRendererRects rects() const LIFETIME_BOUND { return CGRendererRects { m_rects.span() }; }
    WebCore::Color color() const { return m_color; }

private:
    Vector<CGRect, 4> m_rects;
    WebCore::Color m_color;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
