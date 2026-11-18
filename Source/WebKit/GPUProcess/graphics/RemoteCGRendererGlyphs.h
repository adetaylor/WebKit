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
#include "SharedFont.h"
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/GlyphBufferMembers.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <span>
#include <wtf/Ref.h>
#include <wtf/RetainPtr.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>
#include <wtf/ZippedRange.h>

namespace WebKit {

// For RemoteCGRendererFont (RemoteCGRendererResources.swift), which can't pass the font as a FontBase: its CTFont and facts
// (CGRendererGlyphFontFactsOf()), and FontBase::hasAnyComplexColorFormatGlyphs().
inline CTFontRef _Nullable glyphFontFactsOf(const SharedFont& font, CGRendererGlyphFontFacts& facts) CF_RETURNS_NOT_RETAINED
{
    return CGRendererGlyphFontFactsOf(font, facts);
}

inline bool hasAnyComplexColorFormatGlyphs(const SharedFont& font, std::span<const WebCore::GlyphBufferGlyph> glyphs NOESCAPE)
{
    return font.hasAnyComplexColorFormatGlyphs(glyphs);
}

// The glyphs and advances of RemoteCGRenderer's DrawGlyphs, where the sender has them, and in the GPU process where the
// message has them, in the stream buffer: the web process can still write that while the message is handled, so that the
// handler reads them only to copy them (copyInto()). A replay's are a recorded run's, which nothing writes, and which a
// draw uses in place, with the font that the recorder found for the run.
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

    size_t size() const { return m_glyphs.size(); }
    // Copies the glyphs and advances, at the precision the advances have in RemoteGraphicsContext's DrawGlyphs, as far as the
    // copies have room for them: how many it copied.
    size_t copyInto(std::span<WebCore::GlyphBufferGlyph> glyphsCopy NOESCAPE, std::span<WebCore::GlyphBufferAdvance> advancesCopy NOESCAPE) const
    {
        auto count = std::min({ size(), glyphsCopy.size(), advancesCopy.size() });
        memcpySpan(glyphsCopy.first(count), m_glyphs.first(count));
        for (auto [copy, advance] : zippedRange(advancesCopy.first(count), m_advances.first(count)))
            copy = WebCore::GlyphBufferAdvance { static_cast<float>(advance.width), static_cast<float>(advance.height) };
        return count;
    }
    bool isRecorded() const { return m_isRecorded; }
    // A recorded run's facts for the run, and the run in its font, for a run that draws.
    CGRendererGlyphFontFacts recordedFacts() const { return m_recordedFacts; }
    CGRendererGlyphRun recordedRun() const LIFETIME_BOUND
    {
        RELEASE_ASSERT(m_isRecorded && m_recordedFont);
        return { reinterpret_cast<CTFontRef>(m_recordedFont), m_glyphs, m_advances };
    }

private:
    friend class RemoteCGRendererRecordedGlyphs;
    struct RecordedRun { };
    RemoteCGRendererGlyphs(RecordedRun, std::span<const WebCore::GlyphBufferGlyph> glyphs LIFETIME_BOUND, std::span<const WebCore::GlyphBufferAdvance> advances LIFETIME_BOUND, CTFontRef _Nullable font, const CGRendererGlyphFontFacts& facts) __attribute__((availability(swift, unavailable)))
        : m_glyphs(glyphs)
        , m_advances(advances)
        , m_recordedFont(reinterpret_cast<uintptr_t>(font))
        , m_recordedFacts(facts)
        , m_isRecorded(true)
    {
    }

    std::span<const WebCore::GlyphBufferGlyph> m_glyphs;
    std::span<const WebCore::GlyphBufferAdvance> m_advances;
    // The recorded run's CTFont, which the run keeps, as an integer: Swift takes a C++ type with a pointer as unsafe.
    uintptr_t m_recordedFont { 0 };
    CGRendererGlyphFontFacts m_recordedFacts { };
    bool m_isRecorded { false };
};

// The glyphs and advances of a DrawGlyphs that a recording keeps ('RecordedAs='), copied out of the message with the advances
// at the precision they have in RemoteGraphicsContext's DrawGlyphs, and the CTFont of the font that the recorder finds for them
// (setRecordedFont()), which the recording gives the handler as the message's when it is replayed.
class RemoteCGRendererRecordedGlyphs {
public:
    explicit RemoteCGRendererRecordedGlyphs(const RemoteCGRendererGlyphs& glyphs)
        : m_run(Run::create(glyphs.glyphs(), glyphs.advances()))
    {
    }

    RemoteCGRendererGlyphs argument() const LIFETIME_BOUND
    {
        return { RemoteCGRendererGlyphs::RecordedRun { }, m_run->glyphs.span(), m_run->advances.span(), m_run->font.get(), m_run->facts };
    }

    std::span<const WebCore::GlyphBufferGlyph> glyphs() const LIFETIME_BOUND { return m_run->glyphs.span(); }
    // Gives the run the CTFont of the font that the recorder found for it, and the font's facts for the run, once, before
    // anything replays it.
    void setRecordedFont(CTFontRef _Nullable font, const CGRendererGlyphFontFacts& facts) const
    {
        auto& run = m_run.get();
        RELEASE_ASSERT(!run.hasFont);
        run.hasFont = true;
        run.font = font;
        run.facts = facts;
    }

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
        // Set once, as the run is recorded (setRecordedFont()), before anything replays it.
        RetainPtr<CTFontRef> font;
        CGRendererGlyphFontFacts facts { };
        bool hasFont { false };
    };

    Ref<Run> m_run;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
