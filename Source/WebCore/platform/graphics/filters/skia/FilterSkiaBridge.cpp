/*
 * Copyright (C) 2024 Igalia S.L.
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

#include "config.h"
#include "FilterSkiaBridge.h"

#if USE(SKIA)

#include "GraphicsContext.h"
#include "NativeImage.h"
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN // GLib/Win ports
#include <skia/core/SkCanvas.h>
#include <skia/core/SkColorFilter.h>
#include <skia/effects/SkImageFilters.h>
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END

namespace WebCore::FilterSkiaBridge {

static constexpr size_t colorMatrixSize = 20;
static constexpr size_t lookupTableSize = 256;

static bool drawImageBufferWithPaint(ImageBuffer& result, ImageBuffer& source, const IntPoint& inputOffsetWithinResult, const SkPaint& paint)
{
    auto nativeImage = source.createNativeImageReference();
    if (!nativeImage)
        return false;
    auto platformImage = nativeImage->platformImage();
    if (!platformImage)
        return false;

    result.context().platformContext()->drawImage(platformImage, inputOffsetWithinResult.x(), inputOffsetWithinResult.y(), { }, &paint);
    return true;
}

bool drawColorMatrix(ImageBuffer& result, ImageBuffer& source, std::span<const float> matrix NOESCAPE, const IntPoint& inputOffsetWithinResult)
{
    if (matrix.size() != colorMatrixSize)
        return false;

    SkPaint paint;
    paint.setColorFilter(SkColorFilters::Matrix(matrix.data()));
    return drawImageBufferWithPaint(result, source, inputOffsetWithinResult, paint);
}

bool drawTables(ImageBuffer& result, ImageBuffer& source, std::span<const uint8_t> tables NOESCAPE, const IntPoint& inputOffsetWithinResult)
{
    if (tables.size() != 4 * lookupTableSize)
        return false;

    auto redTable = tables.subspan(0, lookupTableSize);
    auto greenTable = tables.subspan(lookupTableSize, lookupTableSize);
    auto blueTable = tables.subspan(2 * lookupTableSize, lookupTableSize);
    auto alphaTable = tables.subspan(3 * lookupTableSize, lookupTableSize);

    SkPaint paint;
    paint.setColorFilter(SkColorFilters::TableARGB(alphaTable.data(), redTable.data(), greenTable.data(), blueTable.data()));
    return drawImageBufferWithPaint(result, source, inputOffsetWithinResult, paint);
}

bool drawBlur(ImageBuffer& result, ImageBuffer& source, const FloatSize& sigma, const IntPoint& inputOffsetWithinResult)
{
    SkPaint paint;
    paint.setImageFilter(SkImageFilters::Blur(sigma.width(), sigma.height(), nullptr));
    return drawImageBufferWithPaint(result, source, inputOffsetWithinResult, paint);
}

bool drawDropShadow(ImageBuffer& result, ImageBuffer& source, const FloatSize& offset, const FloatSize& sigma, const FEDropShadowParameters& parameters, const IntPoint& inputOffsetWithinResult)
{
    auto shadowColorWithAlpha = parameters.shadowColor.colorWithAlphaMultipliedBy(parameters.shadowOpacity);

    SkPaint paint;
    paint.setImageFilter(SkImageFilters::DropShadow(offset.width(), offset.height(), sigma.width(), sigma.height(), shadowColorWithAlpha, nullptr));
    return drawImageBufferWithPaint(result, source, inputOffsetWithinResult, paint);
}

} // namespace WebCore::FilterSkiaBridge

#endif // USE(SKIA)
