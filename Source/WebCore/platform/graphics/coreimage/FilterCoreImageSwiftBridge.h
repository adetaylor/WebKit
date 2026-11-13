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

#include <WebCore/ColorSpace.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/IntRect.h>
#include <wtf/Platform.h>

#if USE(CORE_IMAGE)

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>

// What FilterImageCoreImage.swift needs from C++ to render a Core Image filter result.
namespace WebCore::FilterCoreImageSwiftBridge {

// ColorSpace::SRGB() and LinearSRGB() return references, which Swift can't use safely.
inline ColorSpace sRGBColorSpace()
{
    return ColorSpace::SRGB();
}

inline ColorSpace linearSRGBColorSpace()
{
    return ColorSpace::LinearSRGB();
}

// The CGColorSpace of a ColorSpace, which Swift retains when it receives it.
CF_RETURNS_NOT_RETAINED inline CGColorSpaceRef platformColorSpace(const ColorSpace& colorSpace)
{
    return colorSpace.platformColorSpace();
}

// The IOSurface of an accelerated image buffer, which Swift retains when it receives it, or null if the image buffer
// has none.
CF_RETURNS_NOT_RETAINED inline IOSurfaceRef ioSurface(ImageBuffer& imageBuffer)
{
    auto* surface = imageBuffer.surface();
    return surface ? surface->surface() : nullptr;
}

void logFilterResultImageBuffer(const IntRect& absoluteImageRect, ImageBuffer&);

// The trace points around the rendering of a filter's result (CoreImageRenderStart and CoreImageRenderEnd).
void beginFilterResultRender();
void endFilterResultRender();

} // namespace WebCore::FilterCoreImageSwiftBridge

#endif // USE(CORE_IMAGE)
