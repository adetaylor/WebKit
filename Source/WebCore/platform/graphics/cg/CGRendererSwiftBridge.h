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

// The values GraphicsContextCG passes to CGRenderer.swift.

#include <CoreGraphics/CoreGraphics.h>
#include <span>
#include <stdint.h>
#include <wtf/SwiftBridging.h>

// A GraphicsDropShadow, with its color passed separately when it isn't sRGBA8.
struct CGRendererShadowValues {
    float width;
    float height;
    float radius;
    float opacity;
    uint32_t packedColor;
    bool isValid;
    bool isVisible;
};

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
struct CGRendererColorMatrix {
    float values[20];
};
#endif

// A Gradient's geometry (Gradient::LinearData, RadialData or ConicData) and spread method.
struct CGRendererGradientGeometry {
    uint8_t kind; // 0 linear, 1 radial, 2 conic.
    uint8_t spreadMethod; // GradientSpreadMethod.
    float x0;
    float y0;
    float x1;
    float y1;
    float startRadius;
    float endRadius;
    float aspectRatio;
    float angleRadians;
};

// A sub-image of an image, from WebCore's cache of them unless the image is transient (CGImageCreateWithImageInRect()).
CGImageRef _Nullable CGRendererCopySubimage(CGImageRef _Nonnull, CGRect) CF_RETURNS_RETAINED;

// drawPattern()'s pattern of an image: CGPatternCreateWithImageTransformStep() where CoreGraphics has it, otherwise
// CGPatternCreate() with callbacks that draw the image, aligned to device pixels.
CGPatternRef _Nullable CGRendererCreateImagePattern(CGImageRef _Nullable, CGRect tileBounds, CGAffineTransform, CGFloat xStep, CGFloat yStep) CF_RETURNS_RETAINED;

// What GraphicsContextCG knows about a run of glyphs' font that the renderer draws with (FontCascade::drawGlyphs()).
struct CGRendererGlyphDrawFacts {
    CGAffineTransform textMatrix; // computeTextMatrix().
    CGAffineTransform verticalTranslationMatrix; // The text matrix without synthetic oblique, for vertical glyph translations.
    float fontSize;
    float syntheticBoldOffset;
    float ascentDelta; // From the alphabetic to the ideographic baseline, for vertical text.
    uint8_t smoothingMode; // FontSmoothingMode, None when the font doesn't allow antialiasing.
    bool isColorBitmapFont;
    bool isInTransparencyLayer;
};

// A run of glyphs lent to CGRenderer.swift for one call: their advances, and for vertical text their translations.
class SWIFT_NONESCAPABLE SWIFT_SAFE CGRendererGlyphRun {
public:
    CGRendererGlyphRun(std::span<const CGGlyph> glyphs LIFETIME_BOUND, std::span<const CGSize> advances LIFETIME_BOUND, std::span<const CGSize> translations LIFETIME_BOUND)
        : m_glyphs(glyphs)
        , m_advances(advances)
        , m_translations(translations)
    {
    }

    size_t size() const { return m_glyphs.size(); }
    CGSize advance(size_t index) const { return m_advances[index]; }
    bool isVertical() const { return !m_translations.empty(); }
    CGSize translation(size_t index) const { return m_translations[index]; }
    std::span<const CGGlyph> glyphs() const LIFETIME_BOUND { return m_glyphs; }

private:
    std::span<const CGGlyph> m_glyphs;
    std::span<const CGSize> m_advances;
    std::span<const CGSize> m_translations;
};

// Storage for a run's glyph positions, which CGRenderer.swift computes, lent for one call.
class SWIFT_NONESCAPABLE SWIFT_SAFE CGRendererGlyphPositions {
public:
    explicit CGRendererGlyphPositions(std::span<CGPoint> positions LIFETIME_BOUND)
        : m_positions(positions)
    {
    }

    std::span<CGPoint> mutableSpan() LIFETIME_BOUND { return m_positions; }
    std::span<const CGPoint> span() const LIFETIME_BOUND { return m_positions; }

private:
    std::span<CGPoint> m_positions;
};

namespace WebCore {
class ImageBuffer;
}

// The image of an ImageBuffer ShadowBlur drew a shadow into, as GraphicsContext::drawImageBuffer() and
// GraphicsContextCG::clipToImageBuffer() take it, and the image's headroom.
CGImageRef _Nullable CGRendererCopyImageBufferImage(WebCore::ImageBuffer&, float& headroom) CF_RETURNS_RETAINED;

// Rects lent to CGRenderer.swift for one call.
class SWIFT_NONESCAPABLE SWIFT_SAFE CGRendererRects {
public:
    explicit CGRendererRects(std::span<const CGRect> rects LIFETIME_BOUND)
        : m_rects(rects)
    {
    }

    size_t size() const { return m_rects.size(); }
    CGRect at(size_t index) const { return m_rects[index]; }

private:
    std::span<const CGRect> m_rects;
};
