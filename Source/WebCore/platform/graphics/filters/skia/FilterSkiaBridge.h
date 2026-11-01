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

#include <wtf/Platform.h>

#if USE(SKIA)

#include <WebCore/FEDropShadowParameters.h>
#include <WebCore/FloatSize.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/IntPoint.h>
#include <span>
#include <wtf/Compiler.h>

// What the filter effects' Skia code (in their software applier .swift files) needs from C++: Skia's paints, filters
// and images can't be imported into Swift. Each function draws `source` into `result` at `inputOffsetWithinResult`
// through one paint, and returns false, drawing nothing, if `source` has no image to draw.
namespace WebCore::FilterSkiaBridge {

// `matrix` is the 5 x 4 row-major color matrix (20 floats); false for any other size.
bool drawColorMatrix(ImageBuffer& result, ImageBuffer& source, std::span<const float> matrix NOESCAPE, const IntPoint& inputOffsetWithinResult);

// `tables` are the red, green, blue and alpha lookup tables, 256 bytes each, in that order; false for any other size.
bool drawTables(ImageBuffer& result, ImageBuffer& source, std::span<const uint8_t> tables NOESCAPE, const IntPoint& inputOffsetWithinResult);

bool drawBlur(ImageBuffer& result, ImageBuffer& source, const FloatSize& sigma, const IntPoint& inputOffsetWithinResult);

// The shadow has the parameters' color with their opacity applied.
bool drawDropShadow(ImageBuffer& result, ImageBuffer& source, const FloatSize& offset, const FloatSize& sigma, const FEDropShadowParameters&, const IntPoint& inputOffsetWithinResult);

} // namespace WebCore::FilterSkiaBridge

#endif // USE(SKIA)
