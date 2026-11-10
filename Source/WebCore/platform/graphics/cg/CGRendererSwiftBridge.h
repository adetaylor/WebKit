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
#include <CoreText/CoreText.h>
#include <WebCore/ColorSpace.h>
#include <WebCore/GraphicsTypes.h>
#include <WebCore/PathSegment.h>
#include <WebCore/PlatformExportMacros.h>
#include <WebCore/RasterDrawingOptions.h>
#include <WebCore/ShadowBlurSwiftBridge.h>
#include <WebCore/TextFlags.h>
#include <WebCore/WindRule.h>
#include <algorithm>
#include <optional>
#include <span>
#include <stdint.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

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

// What the renderer draws a run of glyphs in a font with (FontCascade::drawGlyphs()), which is the font's alone, so that
// whoever keeps the font can work it out once (CGRendererGlyphFontFactsOf()).
struct CGRendererGlyphFontFacts {
    CGAffineTransform textMatrix; // computeTextMatrix().
    CGAffineTransform verticalTranslationMatrix; // The text matrix without synthetic oblique, for vertical glyph translations.
    float fontSize;
    float syntheticBoldOffset;
    float ascentDelta; // From the alphabetic to the ideographic baseline, for vertical text.
    bool isVertical;
    bool isColorBitmapFont;
    bool allowsAntialiasing;
    bool hasComplexColorFormatTables; // Whether a glyph may have complex color, which the GPU process doesn't draw.
    bool draws; // False for a font of no size, and for a run that the GPU process doesn't draw.
};

// A run of glyphs lent to CGRenderer.swift for one call: their font, which whoever lends the run keeps, and their advances.
class SWIFT_NONESCAPABLE SWIFT_SAFE CGRendererGlyphRun {
public:
    CGRendererGlyphRun(CTFontRef _Nonnull font, std::span<const CGGlyph> glyphs LIFETIME_BOUND, std::span<const CGSize> advances LIFETIME_BOUND) __attribute__((availability(swift, unavailable)))
        : m_font(font)
        , m_glyphs(glyphs.first(std::min(glyphs.size(), advances.size())))
        , m_advances(advances.first(m_glyphs.size()))
    {
    }

    std::span<const CGGlyph> glyphs() const LIFETIME_BOUND { return m_glyphs; }
    std::span<const CGSize> advances() const LIFETIME_BOUND { return m_advances; }
    CTFontRef _Nonnull font() const __attribute__((availability(swift, unavailable))) { return m_font; }

private:
    CTFontRef _Nonnull m_font;
    std::span<const CGGlyph> m_glyphs;
    std::span<const CGSize> m_advances;
};

// A run of glyphs that Swift keeps, in a font that it keeps.
inline CGRendererGlyphRun CGRendererMakeGlyphRun(CTFontRef _Nonnull font LIFETIME_BOUND, std::span<const CGGlyph> glyphs LIFETIME_BOUND, std::span<const CGSize> advances LIFETIME_BOUND)
{
    return { font, glyphs, advances };
}

namespace WebCore {
class AffineTransform;
class CGRendererCore;
class Color;
class FloatPoint;
class FloatRect;
class FontBase;
class FloatRoundedRect;
class GraphicsContext;
struct FloatSegment;
class Gradient;
class GraphicsContextCG;
class ImageBuffer;
class NativeImage;
class Path;
class PathImpl;
class Pattern;
struct PatternParameters;
class SourceBrush;
struct GraphicsDropShadow;
}

class CGRendererBrushSource;
class CGRendererGradientColorSpace;

// A pattern brush's CGPattern for one draw, as GraphicsContextCG::applyFillPattern() makes it: null when the pattern has no
// image.
CGPatternRef _Nullable CGRendererCreateBrushPattern(const CGRendererBrushSource&, CGContextRef _Nonnull) CF_RETURNS_RETAINED;

// A brush's gradient or pattern, which CGRenderer.swift keeps for the C++ that draws the gradient or makes the pattern's
// CGPattern.
class SWIFT_ESCAPABLE CGRendererBrushSource {
public:
    WEBCORE_EXPORT CGRendererBrushSource();
    explicit CGRendererBrushSource(const WebCore::SourceBrush&);
    // A gradient brush and a pattern brush, as GraphicsContextState::setFillGradient() and setFillPattern() set them.
    WEBCORE_EXPORT CGRendererBrushSource(Ref<const WebCore::Gradient>&&, const WebCore::AffineTransform& spaceTransform) __attribute__((availability(swift, unavailable)));
    WEBCORE_EXPORT explicit CGRendererBrushSource(Ref<const WebCore::Pattern>&&) __attribute__((availability(swift, unavailable)));
    WEBCORE_EXPORT CGRendererBrushSource(const CGRendererBrushSource&);
    WEBCORE_EXPORT CGRendererBrushSource& operator=(const CGRendererBrushSource&);
    WEBCORE_EXPORT ~CGRendererBrushSource();

private:
    friend CGPatternRef _Nullable CGRendererCreateBrushPattern(const CGRendererBrushSource&, CGContextRef _Nonnull);
    friend CGGradientRef _Nullable CGRendererCopyBrushGradient(const CGRendererBrushSource&, const CGRendererGradientColorSpace&, CGRendererGradientGeometry&, CGAffineTransform&);
    friend class WebCore::GraphicsContextCG;

    void applyTo(WebCore::SourceBrush&) const;

    RefPtr<const WebCore::Gradient> m_gradient;
    CGAffineTransform m_gradientSpaceTransform;
    RefPtr<const WebCore::Pattern> m_pattern;
};

// The facts of a font (CGRendererGlyphFontFacts), and its CTFont, which the font keeps: null for a font without one.
WEBCORE_EXPORT CTFontRef _Nullable CGRendererGlyphFontFactsOf(const WebCore::FontBase&, CGRendererGlyphFontFacts&) __attribute__((availability(swift, unavailable)));

// The color space a context paints gradients in (Gradient::paintColorSpace()), which GraphicsContextCG gives its renderer for
// a Swift receiver's gradients.
class SWIFT_ESCAPABLE CGRendererGradientColorSpace {
public:
    CGRendererGradientColorSpace() = default;
    explicit CGRendererGradientColorSpace(std::optional<WebCore::ColorSpace> colorSpace) __attribute__((availability(swift, unavailable)))
        : m_colorSpace(WTF::move(colorSpace))
    {
    }

private:
    friend CGGradientRef _Nullable CGRendererCopyBrushGradient(const CGRendererBrushSource&, const CGRendererGradientColorSpace&, CGRendererGradientGeometry&, CGAffineTransform&);
    std::optional<WebCore::ColorSpace> m_colorSpace;
};

// A gradient brush's CGGradient in the color space, with its geometry and space transform; null for a brush without a gradient.
WEBCORE_EXPORT CGGradientRef _Nullable CGRendererCopyBrushGradient(const CGRendererBrushSource&, const CGRendererGradientColorSpace&, CGRendererGradientGeometry&, CGAffineTransform& spaceTransform) CF_RETURNS_RETAINED;

// GraphicsContextCG::paintGradientInClip()'s pieces, for a Swift receiver's gradients. Without CGStyle's fix for shadow blurs,
// a gradient with a drop shadow paints in a CGLayer, which only C++ does (CGRendererPaintsGradientShadowsInLayer()).
WEBCORE_EXPORT bool CGRendererPaintsGradientShadowsInLayer();
// GraphicsContextCG::boundsIncludingDropShadow() of a drop shadow of the offset and radius.
WEBCORE_EXPORT CGRect CGRendererBoundsIncludingDropShadow(CGContextRef _Nonnull, float offsetWidth, float offsetHeight, float radius, bool shadowsIgnoreTransforms, CGRect bounds);
// The transparency layer that bounds a gradient's paint with a drop shadow, and its end.
WEBCORE_EXPORT void CGRendererBeginGradientShadowLayer(CGContextRef _Nonnull, CGRect layerBounds);
WEBCORE_EXPORT void CGRendererEndGradientShadowLayer(CGContextRef _Nonnull);
// GraphicsContextCG::strokePath()'s bounds and clip of a path stroked with a gradient.
WEBCORE_EXPORT CGRect CGRendererStrokedPathBounds(CGContextRef _Nonnull, const WebCore::Path&) __attribute__((availability(swift, unavailable)));
WEBCORE_EXPORT void CGRendererClipToStrokedPath(CGContextRef _Nonnull, const WebCore::Path&, float thickness) __attribute__((availability(swift, unavailable)));

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
// A Swift receiver's gradient fills and strokes of a path of one segment (GraphicsContextCG's fillPath() and strokePath() of a
// Path of it), and of strokeRect()'s rect, and the bounds of a rounded rect's path: the bounds of their content, and their
// clips.
WEBCORE_EXPORT CGRect CGRendererPathSegmentBounds(CGRendererPathSegment);
WEBCORE_EXPORT void CGRendererClipToPathSegment(CGContextRef _Nonnull, CGRendererPathSegment, WebCore::WindRule);
WEBCORE_EXPORT CGRect CGRendererStrokedPathSegmentBounds(CGContextRef _Nonnull, CGRendererPathSegment);
WEBCORE_EXPORT void CGRendererClipToStrokedPathSegment(CGContextRef _Nonnull, CGRendererPathSegment, float thickness);
WEBCORE_EXPORT CGRect CGRendererRoundedRectBounds(const WebCore::FloatRoundedRect&);
WEBCORE_EXPORT CGRect CGRendererStrokedRectBounds(CGContextRef _Nonnull, CGRect, float lineWidth);
WEBCORE_EXPORT void CGRendererClipToStrokedRect(CGContextRef _Nonnull, CGRect, float lineWidth);

// GraphicsContextCG's clipPath() and clipOut(const Path&), for the C++ of a Swift receiver's path clips too.
WEBCORE_EXPORT void CGRendererClipToPath(CGContextRef _Nonnull, const WebCore::Path&, WebCore::WindRule) __attribute__((availability(swift, unavailable)));
WEBCORE_EXPORT void CGRendererClipOutToPath(CGContextRef _Nonnull, const WebCore::Path&) __attribute__((availability(swift, unavailable)));
// The same for a Path of the PathImpl, without the Path, whose reference to it a decoded path would otherwise take.
WEBCORE_EXPORT void CGRendererClipToPathImpl(CGContextRef _Nonnull, const WebCore::PathImpl&, WebCore::WindRule) __attribute__((availability(swift, unavailable)));
WEBCORE_EXPORT void CGRendererClipOutToPathImpl(CGContextRef _Nonnull, const WebCore::PathImpl&) __attribute__((availability(swift, unavailable)));
// The same for a CGPath, which it adds as addToCGContextPath() adds a rounded rect's, after the clip's bounds.
WEBCORE_EXPORT void CGRendererClipOutToPlatformPath(CGContextRef _Nonnull, CGPathRef _Nonnull);


// A rounded rect's rect and radii as plain values, for CGRenderer.swift, which ShadowBlur::drawRectShadow() and
// drawInsetShadow() take as they are.
struct CGRendererRoundedRect {
    WebCore::ShadowBlurRect rect;
    WebCore::ShadowBlurCornerRadii radii;
};
WEBCORE_EXPORT CGRendererRoundedRect CGRendererRoundedRectOf(WebCore::FloatRoundedRect);

// The CGPath that Path makes (PathCG) for a path of just the segment. Swift's CGMutablePath methods add with an identity
// transform rather than none, which changes what CG stores for -0, infinities and NaN.
WEBCORE_EXPORT CGMutablePathRef _Nonnull CGRendererCreatePath(CGRendererPathSegment) CF_RETURNS_RETAINED;
// What a Swift receiver asks of a message's path besides its CGPath: how many segments it has; its segment, if it has one,
// which it draws without a CGPath; the arc of a pie wedge (Path::pieWedgeArc()) as an Arc segment, or a CloseSubpath segment
// for any other path; and Path::fastBoundingRect() of a path of more than one segment, where it was asked for.
struct CGRendererPathFacts {
    size_t segmentCount;
    CGRendererPathSegment segment;
    CGRendererPathSegment pieWedgeArc;
    CGRect fastBoundingRect;
    bool hasFastBoundingRect;
};
// The CGPath that Path makes (PathCG) of a PathStream of the segments, as CGRendererCopyPlatformPath() does, and the path's
// facts, whose bounds, if computesFastBoundingRect, are PathStream::computeFastBoundingRect()'s, in the same pass over the
// segments. Null for a path of no segment or one.
WEBCORE_EXPORT CGMutablePathRef _Nullable CGRendererCreatePathOfSegments(std::span<const WebCore::PathSegment> segments NOESCAPE, CGRendererPathFacts&, bool computesFastBoundingRect) CF_RETURNS_RETAINED __attribute__((availability(swift, unavailable)));
// The Path of such a CGPath, as a Path of a PathCG, which C++ encodes as the segments of the CGPath's elements.
WEBCORE_EXPORT WebCore::Path CGRendererPathOfPlatformPath(CGPathRef _Nonnull) __attribute__((availability(swift, unavailable)));
// The CGPath that a Path of the PathImpl draws (Path::platformPath()), without the copy of the PathImpl that a Path sharing it
// would make first.
WEBCORE_EXPORT CGPathRef _Nonnull CGRendererCopyPlatformPath(const WebCore::PathImpl&) CF_RETURNS_RETAINED __attribute__((availability(swift, unavailable)));

// What the renderer's drawNativeImage() takes of an image draw's options: the dynamic range limit, which tone maps an image
// that draws HDR content to standard range, is in limitsDynamicRange.
struct CGRendererImageOptions {
    WebCore::CompositeOperator compositeOperator;
    WebCore::BlendMode blendMode;
    WebCore::InterpolationQuality interpolationQuality;
    uint8_t orientation;
    float headroom;
    float dynamicRangeLimit;
    bool limitsDynamicRange;
};
WEBCORE_EXPORT CGRendererImageOptions CGRendererImageOptionsFor(WebCore::RasterDrawingOptions);

// The image of an image draw: for a Swift receiver's, whether the identifier names an image (found), and whether it is a
// copy of the image buffer the receiver draws into (isSelfCopy), which the receiver flushes after the draw; the image's size
// and headroom; for an image buffer, its resolution scale, which scales the source rect; and the color matrix that inverts
// an image drawn for an accessibility color mode.
struct CGRendererImageFacts {
    float width;
    float height;
    float headroom;
    float resolutionScale;
    bool found;
    bool isSelfCopy;
#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
    bool invertsContent;
    CGRendererColorMatrix invertColorMatrix;
#endif
};
// GraphicsContextCG::drawNativeImage()'s inversion of an image for an accessibility color mode: the color matrix, in the
// facts, for options that invert the image (InvertContent::Yes or Forced) where the platform has the mode.
WEBCORE_EXPORT void CGRendererSetInvertColorMatrix(const WebCore::NativeImage&, const WebCore::FloatRect& sourceRect, WebCore::RasterDrawingOptions, CGRendererImageFacts&) __attribute__((availability(swift, unavailable)));

// A Color as the renderer takes it, as GraphicsContextCG converts its state's (didUpdateStateForSwiftRenderer()): an sRGBA8
// color packed, any other as plain values with its CGColor, which CGRendererCopyColor() returns.
struct CGRendererColorValue {
    CGRendererColorData data;
    uint32_t packedColor;
    bool isPacked;
    bool isVisible;
};
// The value of a color without its CGColor, as RemoteCGRenderer's messages carry one: the renderer makes the CGColor itself
// (CGRendererCopyCGColorForData()), and CGRendererColorFromValue() gives back the same Color.
WEBCORE_EXPORT void CGRendererColorValueOf(const WebCore::Color&, CGRendererColorValue&) __attribute__((availability(swift, unavailable)));

// The color space a context draws colors in (GraphicsContextCG::colorSpace()), which GraphicsContextCG gives a renderer it
// lends, for the CGColors of a Swift receiver's colors that aren't sRGBA8.
class SWIFT_ESCAPABLE CGRendererDestinationColorSpace {
public:
    CGRendererDestinationColorSpace() = default;
    explicit CGRendererDestinationColorSpace(const WebCore::ColorSpace& colorSpace) __attribute__((availability(swift, unavailable)))
        : m_colorSpace(colorSpace)
    {
    }

    const std::optional<WebCore::ColorSpace>& colorSpace() const __attribute__((availability(swift, unavailable))) { return m_colorSpace; }

private:
    std::optional<WebCore::ColorSpace> m_colorSpace;
};

// cachedCGColorInDestinationStandardRange() of a color's data, in sRGB without a color space, and cachedCGColor() of it.
#if ENABLE(APPLE_PAY)
// ApplePayButtonCocoa's draw: PassKit's Apple Pay button of the ApplePayButtonType and ApplePayButtonStyle, in the locale, in the
// rect of a flipped context, with the largest radius of its corners.
WEBCORE_EXPORT void CGRendererDrawApplePayButton(CGContextRef _Nonnull, CGRect, CGFloat largestCornerRadius, uint8_t buttonType, uint8_t buttonStyle, CFStringRef _Nullable locale);
#endif

WEBCORE_EXPORT CGColorRef _Nullable CGRendererCopyCGColorForData(const CGRendererColorData&, const CGRendererDestinationColorSpace&) CF_RETURNS_RETAINED;
WEBCORE_EXPORT CGColorRef _Nullable CGRendererCopyCachedCGColorForData(const CGRendererColorData&) CF_RETURNS_RETAINED;
// The color that a drop shadow without blur draws a run of glyphs in: the shadow's, with its alpha multiplied by the fill's.
CGColorRef _Nullable CGRendererCopyGlyphShadowColor(const CGRendererColorValue& shadowColor, const CGRendererColorValue& fillColor, const CGRendererDestinationColorSpace&) CF_RETURNS_RETAINED;
// A drop shadow as the renderer takes it (setDropShadow()), with the CGColor of a valid color that isn't sRGBA8.
WEBCORE_EXPORT CGColorRef _Nullable CGRendererCopyShadow(const WebCore::GraphicsContextCG&, const WebCore::GraphicsDropShadow&, CGRendererShadowValues&, CGRendererColorData&) CF_RETURNS_RETAINED __attribute__((availability(swift, unavailable)));
// A drop shadow's values and its color's data, as RemoteCGRenderer's messages carry them, and the same shadow back.
WEBCORE_EXPORT void CGRendererShadowValuesOf(const WebCore::GraphicsDropShadow&, CGRendererShadowValues&, CGRendererColorData&) __attribute__((availability(swift, unavailable)));
WEBCORE_EXPORT WebCore::GraphicsDropShadow CGRendererDropShadowFromValues(const CGRendererShadowValues&, const CGRendererColorData&) __attribute__((availability(swift, unavailable)));

// The Color of a value of the renderer's, as GraphicsContextCG takes the renderer's state (updateStateFromSwiftRenderer()),
// and as the renderer gives ShadowBlur a drop shadow's color.
WEBCORE_EXPORT WebCore::Color CGRendererColorFromValue(const CGRendererColorValue&);

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

