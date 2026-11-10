/*
 * Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

/*
 * Copyright (C) 2003-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2008 Eric Seidel <eric@webkit.org>
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

// The CoreGraphics calls CGRenderer.swift makes through C: those that take a pointer or a null, which Swift would pass
// unsafely. The SPI itself is PAL's.

#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <WebCore/CGRendererSwiftBridge.h>
#include <algorithm>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <pal/spi/cg/ImageIOSPI.h>

CF_ASSUME_NONNULL_BEGIN

CF_IMPLICIT_BRIDGING_ENABLED

// The platform's focus ring style in the color, its radius scaled, accumulating so that it doesn't overpaint a focus ring
// already drawn (GraphicsContextCG::drawFocusRing()).
WEBCORE_EXPORT CGStyleRef _Nullable CGRendererCreateFocusRingStyle(CGColorRef _Nullable, CGFloat radiusScale);

// An opaque color of a pattern, whose components Swift would pass as a pointer.
inline CGColorRef _Nullable CGRendererCreatePatternColor(CGColorSpaceRef patternSpace, CGPatternRef pattern)
{
    CGFloat alpha = 1;
    return CGColorCreateWithPattern(patternSpace, pattern, &alpha);
}

CF_IMPLICIT_BRIDGING_DISABLED

// A pattern brush's opaque pattern, whose components Swift would pass as a pointer.
inline void CGRendererSetFillPattern(CGContextRef context, CGPatternRef pattern)
{
    CGFloat alpha = 1;
    CGContextSetFillPattern(context, pattern, &alpha);
}

inline void CGRendererSetStrokePattern(CGContextRef context, CGPatternRef pattern)
{
    CGFloat alpha = 1;
    CGContextSetStrokePattern(context, pattern, &alpha);
}

// CTFontDrawGlyphs() of a run's glyphs in its font at the positions Swift computed, which reach C as pointers.
inline void CGRendererDrawGlyphs(const CGRendererGlyphRun& run, std::span<const CGPoint> positions NOESCAPE, CGContextRef context)
{
    auto glyphs = run.glyphs();
    CTFontDrawGlyphs(run.font(), glyphs.data(), positions.data(), std::min(glyphs.size(), positions.size()), context);
}

// CTFontGetVerticalTranslationsForGlyphs() of a run in a vertical font.
inline void CGRendererGetVerticalTranslations(const CGRendererGlyphRun& run, std::span<CGSize> translations NOESCAPE)
{
    auto glyphs = run.glyphs();
    CTFontGetVerticalTranslationsForGlyphs(run.font(), glyphs.data(), translations.data(), std::min(glyphs.size(), translations.size()));
}

// CGPDFContextBeginPage() with a media box, whose dictionary holds the rect's bytes.
inline void CGRendererBeginPDFPage(CGContextRef context, CGRect mediaBox)
{
    CFDataRef mediaBoxData = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&mediaBox), sizeof(CGRect));
    const void* key = kCGPDFContextMediaBox;
    const void* value = mediaBoxData;
    CFDictionaryRef pageInfo = CFDictionaryCreate(kCFAllocatorDefault, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGPDFContextBeginPage(context, pageInfo);
    CFRelease(pageInfo);
    CFRelease(mediaBoxData);
}

// CGContextDrawTiledImage(), which Swift's overlay doesn't let draw a null image; the C++ does when the tile is outside the
// image, and that changes how CG draws next.
inline void CGRendererDrawTiledImage(CGContextRef context, CGRect rect, CGImageRef _Nullable image)
{
    CGContextDrawTiledImage(context, rect, image);
}

// CGContextDrawPathDirect() without a bounding box, which Swift would pass as a pointer.
inline void CGRendererDrawPath(CGContextRef context, CGPathDrawingMode mode, CGPathRef path)
{
    CGContextDrawPathDirect(context, mode, path, nullptr);
}

// PathCG's additions of rects and rounded rects to a CGPath, without a transform: Swift's overlay passes the identity, which
// changes what CG stores for -0, infinities and NaN.
inline void CGRendererAddRect(CGMutablePathRef path, CGRect rect)
{
    CGPathAddRect(path, nullptr, rect);
}

inline void CGRendererAddRoundedRect(CGMutablePathRef path, CGRect rect, CGFloat cornerWidth, CGFloat cornerHeight)
{
    CGPathAddRoundedRect(path, nullptr, rect, cornerWidth, cornerHeight);
}

#if HAVE(CG_PATH_UNEVEN_CORNERS_ROUNDEDRECT)
inline void CGRendererAddUnevenCornersRoundedRect(CGMutablePathRef path, CGRect rect, CGSize bottomLeft, CGSize bottomRight, CGSize topRight, CGSize topLeft)
{
    CGSize corners[4] { bottomLeft, bottomRight, topRight, topLeft };
    CGPathAddUnevenCornersRoundedRect(path, nullptr, rect, corners);
}
#endif

#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
// GraphicsContextCG::drawNativeImage()'s dynamic range limit for an image: its tone mapping to standard or constrained range,
// by the image's average light level, which a dictionary passes to CG.
inline void CGRendererSetDynamicRangeLimitForImage(CGContextRef context, CGImageRef image, float dynamicRangeLimit)
{
    float edrStrength = dynamicRangeLimit == 1.0 ? 1 : 0;
    float cdrStrength = dynamicRangeLimit == 0.5 ? 1 : 0;
    unsigned averageLightLevel = CGImageGetContentAverageLightLevelNits(image);

    CFNumberRef edrStrengthNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &edrStrength);
    CFNumberRef cdrStrengthNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &cdrStrength);
    CFNumberRef averageLightLevelNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &averageLightLevel);

    CFTypeRef toneMappingKeys[] = { kCGContentEDRStrength, kCGContentAverageLightLevel, kCGConstrainedDynamicRange };
    CFTypeRef toneMappingValues[] = { edrStrengthNumber, averageLightLevelNumber, cdrStrengthNumber };

    CFDictionaryRef toneMappingOptions = CFDictionaryCreate(kCFAllocatorDefault, toneMappingKeys, toneMappingValues, sizeof(toneMappingKeys) / sizeof(toneMappingKeys[0]), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CGContentToneMappingInfo toneMappingInfo = { kCGToneMappingReferenceWhiteBased, toneMappingOptions };
    CGContextSetContentToneMappingInfo(context, toneMappingInfo);

    CFRelease(toneMappingOptions);
    CFRelease(averageLightLevelNumber);
    CFRelease(cdrStrengthNumber);
    CFRelease(edrStrengthNumber);
}
#endif

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
CF_IMPLICIT_BRIDGING_ENABLED

// The two styles whose creation takes a pointer, made from values.
inline CGStyleRef _Nullable CGRendererCreateGaussianBlurStyle(CGFloat radius)
{
    CGGaussianBlurStyle style = { 1, radius };
    return CGStyleCreateGaussianBlur(&style);
}

inline CGStyleRef _Nullable CGRendererCreateColorMatrixStyle(CGRendererColorMatrix colorMatrix)
{
    CGColorMatrixStyle style = { 1, { 0 } };
    std::ranges::copy(colorMatrix.values, style.matrix);
    return CGStyleCreateColorMatrix(&style);
}

CF_IMPLICIT_BRIDGING_DISABLED
#endif

CF_ASSUME_NONNULL_END
