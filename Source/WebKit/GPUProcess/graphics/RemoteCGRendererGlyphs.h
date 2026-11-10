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

#include "ArrayReferenceTuple.h"
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/GlyphBufferMembers.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <optional>
#include <span>
#include <wtf/Noncopyable.h>
#include <wtf/Ref.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>

namespace WebKit {

class RemoteCGRendererResources;

// Whether a DrawGlyphs's font identifier names a font, and whether its run draws anything.
struct RemoteCGRendererGlyphPreparationResult {
    bool found;
    bool draws;
};

// The glyphs and advances of RemoteCGRenderer's DrawGlyphs, where the sender has them, and in the GPU process where the
// message has them, in the stream buffer: the web process can still write that while the message is handled, so that the
// handler reads them only to copy them (RemoteCGRendererGlyphDraw::prepare()). A replay's are a recorded run's, which nothing
// writes, and which a draw uses in place.
class SWIFT_NONESCAPABLE RemoteCGRendererGlyphs {
public:
    RemoteCGRendererGlyphs(std::span<const WebCore::GlyphBufferGlyph> glyphs LIFETIME_BOUND, std::span<const WebCore::GlyphBufferAdvance> advances LIFETIME_BOUND) __attribute__((availability(swift, unavailable)))
        : m_glyphs(glyphs.first(std::min(glyphs.size(), advances.size())))
        , m_advances(advances.first(m_glyphs.size()))
    {
    }

    explicit RemoteCGRendererGlyphs(const IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance>& glyphsAdvances) __attribute__((availability(swift, unavailable)))
        : m_glyphs(glyphsAdvances.span<0>())
        , m_advances(glyphsAdvances.span<1>())
    {
    }

    IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance> glyphsAdvances() const __attribute__((availability(swift, unavailable))) { return { m_glyphs.data(), m_advances.data(), m_glyphs.size() }; }
    std::span<const WebCore::GlyphBufferGlyph> glyphs() const __attribute__((availability(swift, unavailable))) { return m_glyphs; }
    std::span<const WebCore::GlyphBufferAdvance> advances() const __attribute__((availability(swift, unavailable))) { return m_advances; }
    bool isRecorded() const __attribute__((availability(swift, unavailable))) { return m_isRecorded; }

private:
    friend class RemoteCGRendererRecordedGlyphs;
    struct RecordedRun { };
    RemoteCGRendererGlyphs(RecordedRun, std::span<const WebCore::GlyphBufferGlyph> glyphs LIFETIME_BOUND, std::span<const WebCore::GlyphBufferAdvance> advances LIFETIME_BOUND) __attribute__((availability(swift, unavailable)))
        : m_glyphs(glyphs)
        , m_advances(advances)
        , m_isRecorded(true)
    {
    }

    std::span<const WebCore::GlyphBufferGlyph> m_glyphs;
    std::span<const WebCore::GlyphBufferAdvance> m_advances;
    bool m_isRecorded { false };
};

// The glyphs and advances of a DrawGlyphs that a recording keeps ('RecordedAs='), copied out of the message with the advances
// at the precision they have in RemoteGraphicsContext's DrawGlyphs, which the recording gives the handler as the message's
// when it is replayed.
class RemoteCGRendererRecordedGlyphs {
public:
    explicit RemoteCGRendererRecordedGlyphs(const RemoteCGRendererGlyphs& glyphs)
        : m_run(Run::create(glyphs.glyphs(), glyphs.advances()))
    {
    }

    RemoteCGRendererGlyphs argument() const LIFETIME_BOUND { return { RemoteCGRendererGlyphs::RecordedRun { }, m_run->glyphs.span(), m_run->advances.span() }; }

private:
    // Shared, so that a replay's copy of the message only counts a reference to the run.
    struct Run : ThreadSafeRefCounted<Run> {
        static Ref<Run> create(std::span<const WebCore::GlyphBufferGlyph> glyphs, std::span<const WebCore::GlyphBufferAdvance> advances) { return adoptRef(*new Run(glyphs, advances)); }

        Run(std::span<const WebCore::GlyphBufferGlyph> glyphs, std::span<const WebCore::GlyphBufferAdvance> advances)
            : glyphs(glyphs)
            , advances(WTF::map(advances, [](auto& advance) {
                return WebCore::GlyphBufferAdvance { static_cast<float>(advance.width), static_cast<float>(advance.height) };
            }))
        {
        }

        const Vector<WebCore::GlyphBufferGlyph> glyphs;
        const Vector<WebCore::GlyphBufferAdvance> advances;
    };

    Ref<Run> m_run;
};

// What a Swift receiver's draw of a DrawGlyphs's run works in, which it keeps in place for the draw. prepare() is
// RemoteGraphicsContext::drawGlyphs()'s copy of the glyphs and advances, with the precision the advances have there (a
// recorded run's are used in place, as the replay keeps them), and lookup of the font, then GraphicsContextCG::drawGlyphsImmediate()'s preparation of the run, in the renderer's state; the
// draw then takes the run, which has the font this keeps, its facts and the storage for the positions the renderer works
// out.
class RemoteCGRendererGlyphDraw {
    WTF_MAKE_NONCOPYABLE(RemoteCGRendererGlyphDraw);
public:
    // User-provided, so that its value-initialization doesn't zero its storage first.
    RemoteCGRendererGlyphDraw() { }
    RemoteCGRendererGlyphDraw(RemoteCGRendererGlyphDraw&&) = default;
    ~RemoteCGRendererGlyphDraw();

    RemoteCGRendererGlyphPreparationResult prepare(const RemoteCGRendererGlyphs&, const RemoteCGRendererResources&, WebCore::RenderingResourceIdentifier fontIdentifier, WebCore::FontSmoothingMode, const CGRendererGlyphContext&);
    // The run this prepared to draw, with the glyphs it was prepared with.
    CGRendererGlyphRun run(const RemoteCGRendererGlyphs& glyphs LIFETIME_BOUND) const LIFETIME_BOUND
    {
        RELEASE_ASSERT(m_preparation && m_preparation->font());
        if (m_drawsRecordedRun) {
            RELEASE_ASSERT(glyphs.isRecorded() && glyphs.glyphs().size() == m_positions.size());
            return { m_preparation->font(), glyphs.glyphs(), glyphs.advances(), m_preparation->translations() };
        }
        return { m_preparation->font(), m_glyphs.span(), m_advances.span(), m_preparation->translations() };
    }
    CGRendererGlyphDrawFacts facts() const { return m_preparation ? m_preparation->facts() : CGRendererGlyphDrawFacts { }; }
    CGRendererGlyphPositions positions() const LIFETIME_BOUND { return CGRendererGlyphPositions { m_positions.mutableSpan() }; }

    CGColorRef _Nullable shadowFillColor() const __attribute__((availability(swift, unavailable))) { return m_preparation ? m_preparation->shadowFillColor() : nullptr; }

private:
    Vector<WebCore::GlyphBufferGlyph, 128> m_glyphs;
    Vector<WebCore::GlyphBufferAdvance, 128> m_advances;
    std::optional<CGRendererGlyphPreparation> m_preparation;
    mutable Vector<CGPoint, 256> m_positions;
    bool m_drawsRecordedRun { false };
};

// A draw's storage, constructed where Swift keeps it: Swift zeroes the storage of what it constructs itself first.
RemoteCGRendererGlyphDraw makeRemoteCGRendererGlyphDraw();

// The run's shadow fill color. A function, since Swift takes what a C++ method returns as unretained whatever its annotation.
CGColorRef _Nullable copyGlyphShadowFillColor(const RemoteCGRendererGlyphDraw&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
