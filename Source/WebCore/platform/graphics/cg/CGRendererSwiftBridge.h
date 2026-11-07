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
#include <WebCore/PathSegment.h>
#include <WebCore/PlatformExportMacros.h>
#include <WebCore/RasterDrawingOptions.h>
#include <WebCore/WindRule.h>
#include <algorithm>
#include <span>
#include <stdint.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
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
    bool legacyRadius; // ShadowRadiusMode::Legacy.
};

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
struct CGRendererColorMatrix {
    float values[20];
};
// GraphicsColorMatrix's ==.
inline bool CGRendererColorMatricesAreEqual(const CGRendererColorMatrix& a, const CGRendererColorMatrix& b)
{
    return std::ranges::equal(a.values, b.values);
}
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
class CGRendererCore;
class Color;
class FloatRoundedRect;
class Gradient;
class GraphicsContextCG;
class ImageBuffer;
class Path;
class PathImpl;
class Pattern;
class SourceBrush;
struct GraphicsDropShadow;
}

class CGRendererBrushSource;

// A pattern brush's CGPattern for one draw, as GraphicsContextCG::applyFillPattern() makes it: null when the pattern has no
// image.
CGPatternRef _Nullable CGRendererCreateBrushPattern(const CGRendererBrushSource&, CGContextRef _Nonnull) CF_RETURNS_RETAINED;

// A brush's gradient or pattern, which CGRenderer.swift keeps for the C++ that draws the gradient or makes the pattern's
// CGPattern.
class SWIFT_ESCAPABLE CGRendererBrushSource {
public:
    CGRendererBrushSource();
    explicit CGRendererBrushSource(const WebCore::SourceBrush&);
    CGRendererBrushSource(const CGRendererBrushSource&);
    CGRendererBrushSource& operator=(const CGRendererBrushSource&);
    ~CGRendererBrushSource();

private:
    friend CGPatternRef _Nullable CGRendererCreateBrushPattern(const CGRendererBrushSource&, CGContextRef _Nonnull);
    friend class WebCore::GraphicsContextCG;

    void applyTo(WebCore::SourceBrush&) const;

    RefPtr<WebCore::Gradient> m_gradient;
    CGAffineTransform m_gradientSpaceTransform;
    RefPtr<WebCore::Pattern> m_pattern;
};

// A Color as plain values: Color::data(), its IPC form.
struct CGRendererColorData {
    float c1;
    float c2;
    float c3;
    float alpha;
    uint32_t packedColor;
    uint8_t colorSpace; // ColorSpaceName, for the components.
    uint8_t form; // 0 invalid, 1 packedColor, 2 the components.
    bool isSemantic;
    bool usesFunctionSerialization;
};

// CGRenderer's state as plain values, for GraphicsContextCG to rebuild GraphicsContext's from. Colors that aren't sRGBA8,
// gradients, patterns and color matrices are by slot, which CGRenderer's copyPlatformColor(), copyBrushSource() and
// copyColorMatrix() look up.
struct CGRendererBrushSnapshot {
    uint32_t packedColor;
    uint32_t platformColorSlot;
    uint32_t sourceSlot;
    uint8_t kind; // 0 color, 1 gradient, 2 pattern.
};

struct CGRendererShadowSnapshot {
    CGRendererShadowValues values;
    uint32_t platformColorSlot;
};

struct CGRendererStateSnapshot {
    CGRendererBrushSnapshot fill;
    CGRendererBrushSnapshot stroke;
    CGRendererShadowSnapshot dropShadow;
    CGRendererShadowSnapshot styleDropShadow;
    float strokeThickness;
    float alpha;
    float gaussianBlurWidth;
    float gaussianBlurHeight;
    float maxEDRHeadroom;
    uint32_t colorMatrixSlot;
    uint8_t style; // 0 none, 1 drop shadow, 2 Gaussian blur, 3 color matrix.
    uint8_t fillRule; // WindRule.
    uint8_t strokeStyle;
    uint8_t compositeOperator;
    uint8_t blendMode;
    uint8_t textDrawingMode; // TextDrawingModeFlags.
    uint8_t imageInterpolationQuality;
    bool hasDropShadow;
    bool hasMaxEDRHeadroom;
    bool shouldAntialias;
    bool shouldSmoothFonts;
    bool shouldSubpixelQuantizeFonts;
    bool shadowsIgnoreTransforms;
    // CGRendererCore::takeStaleStateForCxx(): what a Swift receiver changed (GraphicsContextState::Change's bits), and how
    // many levels of GraphicsContext's stack it restored.
    uint32_t staleProperties;
    uint32_t pendingCxxRestores;
};

// The alternatives of PathSegment::Data, in its order (PathCG.cpp checks).
enum class CGRendererPathSegmentKind : uint8_t {
    MoveTo, LineTo, QuadCurveTo, BezierCurveTo, ArcTo, Arc, ClosedArc, Ellipse, EllipseInRect, Rect, RoundedRect,
    ContinuousRoundedRect, DataLine, DataQuadCurve, DataBezierCurve, DataArc, CloseSubpath
};

// A path's single segment as plain values, since Swift can't switch on PathSegment's variant: the floats of the segment's
// members in the order they are declared (a FloatRoundedRect is its rect, then its radii from the top left, each width then
// height). flag is an arc's or an ellipse's counterclockwise direction, or a rounded rect's PreferBezier strategy.
struct CGRendererPathSegment {
    float values[12];
    CGRendererPathSegmentKind kind;
    bool flag;
};

// The plain values of a message's PathSegment, for a Swift receiver, and the PathSegment of them.
WEBCORE_EXPORT CGRendererPathSegment CGRendererPathSegmentValues(WebCore::PathSegment);
WEBCORE_EXPORT WebCore::PathSegment CGRendererPathSegmentFromValues(CGRendererPathSegment) __attribute__((availability(swift, unavailable)));

// GraphicsContextCG's clipPath() and clipOut(const Path&), for the C++ of a Swift receiver's path clips too.
WEBCORE_EXPORT void CGRendererClipToPath(CGContextRef _Nonnull, const WebCore::Path&, WebCore::WindRule) __attribute__((availability(swift, unavailable)));
WEBCORE_EXPORT void CGRendererClipOutToPath(CGContextRef _Nonnull, const WebCore::Path&) __attribute__((availability(swift, unavailable)));

// GraphicsContext's clipRoundedRect() and clipOutRoundedRect() of a rounded rect with radii, which clip to and out of its
// path as GraphicsContextCG's clipPath() and clipOut(const Path&) do.
WEBCORE_EXPORT void CGRendererClipToRoundedRect(CGContextRef _Nonnull, const WebCore::FloatRoundedRect&);
WEBCORE_EXPORT void CGRendererClipOutToRoundedRect(CGContextRef _Nonnull, const WebCore::FloatRoundedRect&);

// The CGPath that Path makes (PathCG) for a path of just the segment. Swift's CGMutablePath methods add with an identity
// transform rather than none, which changes what CG stores for -0, infinities and NaN.
WEBCORE_EXPORT CGMutablePathRef _Nonnull CGRendererCreatePath(CGRendererPathSegment) CF_RETURNS_RETAINED;
// The CGPath that a Path of the PathImpl draws (Path::platformPath()), without the copy of the PathImpl that a Path sharing it
// would make first.
WEBCORE_EXPORT CGPathRef _Nonnull CGRendererCopyPlatformPath(const WebCore::PathImpl&) CF_RETURNS_RETAINED __attribute__((availability(swift, unavailable)));

// What the renderer's drawNativeImage() takes of an image draw's options, and whether the renderer draws the image at all: it
// doesn't do the iOS family's pixel alignment of images yet, nor limit an image's dynamic range (tone mapping) or invert it
// (AX), which GraphicsContextCG::drawNativeImage() draws in C++.
struct CGRendererImageOptions {
    WebCore::CompositeOperator compositeOperator;
    WebCore::BlendMode blendMode;
    WebCore::InterpolationQuality interpolationQuality;
    uint8_t orientation;
    float headroom;
    bool rendererDraws;
};
WEBCORE_EXPORT CGRendererImageOptions CGRendererImageOptionsFor(WebCore::RasterDrawingOptions);

// The image of a Swift receiver's image draw, as its C++ finds it: whether the identifier names an image (found), whether the
// receiver leaves the draw to C++ (declines: an image buffer drawn into itself), the image's size and headroom, and for an
// image buffer its resolution scale, which scales the source rect.
struct CGRendererImageFacts {
    float width;
    float height;
    float headroom;
    float resolutionScale;
    bool found;
    bool declines;
};

// A Color as the renderer takes it, as GraphicsContextCG converts its state's (didUpdateStateForSwiftRenderer()): an sRGBA8
// color packed, any other as plain values with its CGColor, which CGRendererCopyColor() returns.
struct CGRendererColorValue {
    CGRendererColorData data;
    uint32_t packedColor;
    bool isPacked;
    bool isVisible;
};
WEBCORE_EXPORT CGColorRef _Nullable CGRendererCopyColor(const WebCore::GraphicsContextCG&, const WebCore::Color&, CGRendererColorValue&) CF_RETURNS_RETAINED __attribute__((availability(swift, unavailable)));
// A drop shadow as the renderer takes it (setDropShadow()), with the CGColor of a valid color that isn't sRGBA8.
WEBCORE_EXPORT CGColorRef _Nullable CGRendererCopyShadow(const WebCore::GraphicsContextCG&, const WebCore::GraphicsDropShadow&, CGRendererShadowValues&, CGRendererColorData&) CF_RETURNS_RETAINED __attribute__((availability(swift, unavailable)));

// Testing only: a message of RemoteCGRenderer's and its arguments (GraphicsContextCG::applyReceiverMessageForTesting()).
struct CGRendererReceiverTestMessage {
    uint8_t message; // GraphicsContextCG::ReceiverMessageForTesting.
    float values[6]; // A rect is x, y, width, height; a transform a, b, c, d, tx, ty; a line x1, y1, x2, y2.
    uint32_t integers[2]; // A packed colour, an enum's raw value, a Boolean.
    CGRendererPathSegment segment; // A single-segment path's; an image draw's destination and source or tile rects, then a
                                   // pattern's transform a and d.
    CGRendererImageFacts imageFacts; // An image draw's.
    CGRendererImageOptions imageOptions;
};

// WebCore's process-wide CGColor for an sRGBA8 color (cachedCGColor()).
CGColorRef _Nonnull CGRendererCopyCachedColor(uint32_t packedColor) CF_RETURNS_RETAINED;

// The image of an ImageBuffer ShadowBlur drew a shadow into, as GraphicsContext::drawImageBuffer() and
// ShadowBlur clips to it, and the image's headroom.
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

