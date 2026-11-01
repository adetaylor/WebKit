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

// The CoreGraphics SPI CGRenderer.swift calls, declared so that Swift manages CGStyle. Only WebCore's Swift sees it: C++
// uses PAL's declarations. WebCore's Swift can't import PAL's SPI module: its headers' forward declaration of
// CVPixelBufferRef changes how the whole Swift module sees CoreVideo's.

#include "CGRendererSwiftBridge.h"
#include <CoreGraphics/CoreGraphics.h>

#if USE(APPLE_INTERNAL_SDK)
#include <CoreGraphics/CGStylePrivate.h>
#include <CoreGraphics/CoreGraphicsPrivate.h>
#else
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CF_BRIDGED_TYPE(id) CGStyle *CGStyleRef;

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
struct CGGaussianBlurStyle {
    unsigned version;
    CGFloat radius;
};
typedef struct CGGaussianBlurStyle CGGaussianBlurStyle;

struct CGColorMatrixStyle {
    unsigned version;
    CGFloat matrix[20];
};
typedef struct CGColorMatrixStyle CGColorMatrixStyle;
#endif

CF_IMPLICIT_BRIDGING_ENABLED
void CGContextSetCTM(CGContextRef, CGAffineTransform);
CGAffineTransform CGContextGetBaseCTM(CGContextRef);
void CGContextSetStyle(CGContextRef, CGStyleRef);
CGStyleRef CGStyleCreateShadow2(CGSize offset, CGFloat radius, CGColorRef);
#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
CGStyleRef CGStyleCreateGaussianBlur(const CGGaussianBlurStyle*);
CGStyleRef CGStyleCreateColorMatrix(const CGColorMatrixStyle*);
#endif
CF_IMPLICIT_BRIDGING_DISABLED

#ifdef __cplusplus
}
#endif
#endif

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
