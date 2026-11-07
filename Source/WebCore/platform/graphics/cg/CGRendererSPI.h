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

CF_IMPLICIT_BRIDGING_ENABLED

// An opaque color of a pattern, whose components Swift would pass as a pointer.
inline CGColorRef CGRendererCreatePatternColor(CGColorSpaceRef patternSpace, CGPatternRef pattern)
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
inline void CGRendererDrawGlyphs(const CGRendererGlyphRun& run, const CGRendererGlyphPositions& positions, CGContextRef context)
{
    auto glyphs = run.glyphs();
    auto points = positions.span();
    CTFontDrawGlyphs(run.font(), glyphs.data(), points.data(), std::min(glyphs.size(), points.size()), context);
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

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
CF_IMPLICIT_BRIDGING_ENABLED

// The two styles whose creation takes a pointer, made from values.
inline CGStyleRef CGRendererCreateGaussianBlurStyle(CGFloat radius)
{
    CGGaussianBlurStyle style = { 1, radius };
    return CGStyleCreateGaussianBlur(&style);
}

inline CGStyleRef CGRendererCreateColorMatrixStyle(CGRendererColorMatrix colorMatrix)
{
    CGColorMatrixStyle style = { 1, { 0 } };
    for (unsigned i = 0; i < 20; ++i)
        style.matrix[i] = colorMatrix.values[i];
    return CGStyleCreateColorMatrix(&style);
}

CF_IMPLICIT_BRIDGING_DISABLED
#endif
