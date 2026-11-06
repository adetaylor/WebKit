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
#include <WebCore/Path.h>
#include <WebCore/PathImpl.h>
#include <wtf/RetainPtr.h>
#include <wtf/SwiftBridging.h>

namespace WebKit {

// The path of RemoteCGRenderer's path messages. It goes as RemoteGraphicsContext's Path does. The GPU process keeps a path of
// one segment as the segment's plain values, as RemoteCGRendererPathSegment does and for the same reason, and one of more
// segments as the PathImpl a Path of them has; a cached path is its PathImpl.
class RemoteCGRendererPath {
public:
    // A missing cached path.
    RemoteCGRendererPath() = default;
    explicit RemoteCGRendererPath(const WebCore::Path& path)
        : m_kind(path.isEmpty() ? Kind::Empty : Kind::Single)
    {
        if (auto* segment = path.singleSegmentIfExists()) {
            m_segment = CGRendererPathSegmentValues(*segment);
            return;
        }
        if (auto* impl = path.asImpl()) {
            m_kind = Kind::Impl;
            m_impl = impl;
        }
    }
    explicit RemoteCGRendererPath(Vector<WebCore::PathSegment>&& segments)
        : RemoteCGRendererPath(WebCore::Path { WTF::move(segments) })
    {
    }
    explicit RemoteCGRendererPath(Ref<WebCore::PathImpl>&& impl)
        : m_kind(Kind::Impl)
        , m_impl(WTF::move(impl))
    {
    }

    Vector<WebCore::PathSegment> segments() const { return path().segments(); }

    // Whether a cached path was there to be found.
    bool isValid() const { return m_kind != Kind::Missing; }
    bool isEmpty() const { return m_kind == Kind::Empty || m_kind == Kind::Missing; }
    // GraphicsContextCG::strokePath() strokes a single line (Path::singleDataLine()) as a line segment.
    bool isSingleDataLine() const
    {
        if (m_kind == Kind::Impl) {
            auto segment = m_impl->singleSegment();
            return segment && std::get_if<WebCore::PathDataLine>(&segment->data());
        }
        return m_kind == Kind::Single && m_segment.kind == CGRendererPathSegmentKind::DataLine;
    }
    CGRendererPathSegment singleSegmentValues() const
    {
        if (m_kind == Kind::Impl) {
            if (auto segment = m_impl->singleSegment())
                return CGRendererPathSegmentValues(*segment);
        }
        return m_segment;
    }

    CGPathRef _Nonnull platformPath() const CF_RETURNS_RETAINED SWIFT_RETURNS_INDEPENDENT_VALUE
    {
        switch (m_kind) {
        case Kind::Missing:
        case Kind::Empty:
            break;
        case Kind::Single:
            return CGRendererCreatePath(m_segment);
        case Kind::Impl:
            return CGRendererCopyPlatformPath(*m_impl);
        }
        return RetainPtr<CGPathRef> { WebCore::Path { }.platformPath() }.leakRef();
    }
    void clip(CGContextRef context, WebCore::WindRule rule) const { CGRendererClipToPath(context, path(), rule); }
    void clipOut(CGContextRef context) const { CGRendererClipOutToPath(context, path()); }

    WebCore::Path path() const
    {
        switch (m_kind) {
        case Kind::Missing:
        case Kind::Empty:
            break;
        case Kind::Single:
            return WebCore::Path { CGRendererPathSegmentFromValues(m_segment) };
        case Kind::Impl:
            // The PathImpl is only read: a Path writes to a copy of a PathImpl it shares.
            return WebCore::Path { Ref { const_cast<WebCore::PathImpl&>(*m_impl) } };
        }
        return { };
    }

private:
    enum class Kind : uint8_t { Missing, Empty, Single, Impl };
    Kind m_kind { Kind::Missing };
    CGRendererPathSegment m_segment { };
    RefPtr<const WebCore::PathImpl> m_impl;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
