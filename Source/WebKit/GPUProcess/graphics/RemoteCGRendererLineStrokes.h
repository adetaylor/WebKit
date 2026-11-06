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

#include <WebCore/PathSegmentData.h>
#include <span>
#include <wtf/Vector.h>

namespace WebKit {

// The lines of RemoteCGRenderer's StrokeLinesWithColorAndThickness. They go as RemoteGraphicsContext's span of them does, and
// the GPU process decodes them into a copy of its own, which is what the Swift handler reads: the web process can still write
// the stream buffer while the message is handled. The web process lends its vector of the lines for the send.
class RemoteCGRendererLineStrokes {
public:
    RemoteCGRendererLineStrokes() = default;
    explicit RemoteCGRendererLineStrokes(std::span<const WebCore::PathDataLineColorThickness> lines)
        : m_lines(lines)
    {
    }
    explicit RemoteCGRendererLineStrokes(Vector<WebCore::PathDataLineColorThickness>&& lines)
        : m_lines(WTF::move(lines))
    {
    }

    std::span<const WebCore::PathDataLineColorThickness> span() const LIFETIME_BOUND { return m_lines.span(); }
    Vector<WebCore::PathDataLineColorThickness> takeLines() { return WTF::move(m_lines); }

private:
    Vector<WebCore::PathDataLineColorThickness> m_lines;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
