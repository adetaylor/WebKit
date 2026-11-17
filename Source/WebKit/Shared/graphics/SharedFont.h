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

#include <WebCore/FontBase.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/GlyphBufferMembers.h>
#include <span>
#endif

namespace WebKit {

// This immutable Font is safe to share across threads (or RemoteRenderingBackends) and
// is meant for display purposes only, e.g. calls to FontCascade::drawGlyphs(). It does
// not store glyph tables, so it can't be used for shaping or measuring glyphs.
class SharedFont : public WebCore::FontBase, public ThreadSafeRefCounted<SharedFont> {
public:
    static Ref<SharedFont> create(const WebCore::FontPlatformData&, Origin, IsInterstitial, Visibility, IsOrientationFallback, IsSmallCapsFace, std::optional<WebCore::RenderingResourceIdentifier>);

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

private:
    SharedFont(const WebCore::FontPlatformData&, Origin, IsInterstitial, Visibility, IsOrientationFallback, IsSmallCapsFace, std::optional<WebCore::RenderingResourceIdentifier>);
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
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
#endif

} // namespace WebKit
