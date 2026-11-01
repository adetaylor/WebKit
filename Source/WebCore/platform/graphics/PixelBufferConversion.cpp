/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#include "config.h"
#include "PixelBufferConversion.h"

#include "IntSize.h"
#include "PixelBuffer.h"
#include "PixelBufferSwiftBridge.h"
#include <wtf/Vector.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

#if USE(SKIA)
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN
#include <skia/core/SkPixmap.h>
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END
#endif

namespace WebCore {

// The conversions themselves are in PixelConversion.swift. Swift assumes that the bytes it reads don't
// overlap the bytes it writes, so these forwarders route overlapping views.

static bool spansOverlap(std::span<const uint8_t> a, std::span<const uint8_t> b)
{
    if (a.empty() || b.empty())
        return false;
    auto aStart = reinterpret_cast<uintptr_t>(a.data());
    auto bStart = reinterpret_cast<uintptr_t>(b.data());
    return aStart < bStart + b.size() && bStart < aStart + a.size();
}

void convertImagePixels(const ConstPixelBufferConversionView& source, const PixelBufferConversionView& destination, const IntSize& destinationSize)
{
    MutablePixelBytes destinationBytes { destination.rows };
    if (!spansOverlap(source.rows, destination.rows)) {
        PixelBytes sourceBytes { source.rows };
        pixelConversionConvert(source.format, source.bytesPerRow, sourceBytes, destination.format, destination.bytesPerRow, destinationBytes, destinationSize.width(), destinationSize.height());
        return;
    }

    if (source.rows.data() == destination.rows.data() && source.bytesPerRow == destination.bytesPerRow
        && PixelBuffer::bytesPerPixel(source.format.pixelFormat) == PixelBuffer::bytesPerPixel(destination.format.pixelFormat)) {
        MutablePixelBytes bytes { destination.rows.first(std::min(source.rows.size(), destination.rows.size())) };
        pixelConversionConvertInPlace(source.format, destination.format, destination.bytesPerRow, bytes, destinationSize.width(), destinationSize.height());
        return;
    }

    Vector<uint8_t> sourceCopy(source.rows);
    PixelBytes sourceBytes { sourceCopy.span() };
    pixelConversionConvert(source.format, source.bytesPerRow, sourceBytes, destination.format, destination.bytesPerRow, destinationBytes, destinationSize.width(), destinationSize.height());
}

void copyRowsInternal(unsigned sourceBytesPerRow, std::span<const uint8_t> source, unsigned destinationBytesPerRow, std::span<uint8_t> destination, unsigned rows, unsigned copyBytesPerRow)
{
    MutablePixelBytes destinationBytes { destination };
    if (spansOverlap(source, destination)) {
        Vector<uint8_t> sourceCopy(source);
        PixelBytes sourceBytes { sourceCopy.span() };
        pixelConversionCopyRows(sourceBytesPerRow, sourceBytes, destinationBytesPerRow, destinationBytes, rows, copyBytesPerRow);
        return;
    }
    PixelBytes sourceBytes { source };
    pixelConversionCopyRows(sourceBytesPerRow, sourceBytes, destinationBytesPerRow, destinationBytes, rows, copyBytesPerRow);
}

#if USE(SKIA)

static std::optional<SkColorType> toSkiaColorType(PixelFormat pixelFormat)
{
    switch (pixelFormat) {
    case PixelFormat::RGBA8:
        return SkColorType::kRGBA_8888_SkColorType;
    case PixelFormat::BGRA8:
        return SkColorType::kBGRA_8888_SkColorType;
    default:
        break;
    }
    return std::nullopt;
}

static SkAlphaType toSkiaAlphaType(AlphaPremultiplication alphaFormat)
{
    switch (alphaFormat) {
    case AlphaPremultiplication::Premultiplied:
        return SkAlphaType::kPremul_SkAlphaType;
    case AlphaPremultiplication::Unpremultiplied:
        return SkAlphaType::kUnpremul_SkAlphaType;
    }
    ASSERT_NOT_REACHED();
    return SkAlphaType::kUnknown_SkAlphaType;
}

static bool convertImagePixelsSkia(const PixelBufferFormat& sourceFormat, unsigned sourceBytesPerRow, const uint8_t* source, const PixelBufferFormat& destinationFormat, unsigned destinationBytesPerRow, uint8_t* destination, const IntSize& destinationSize)
{
    auto sourceSkiaColorType = toSkiaColorType(sourceFormat.pixelFormat);
    if (!sourceSkiaColorType)
        return false;
    SkImageInfo sourceImageInfo = SkImageInfo::Make(
        destinationSize.width(),
        destinationSize.height(),
        *sourceSkiaColorType,
        toSkiaAlphaType(sourceFormat.alphaFormat),
        sourceFormat.colorSpace.platformColorSpace()
    );
    auto destinationSkiaColorType = toSkiaColorType(destinationFormat.pixelFormat);
    if (!destinationSkiaColorType)
        return false;
    // Utilize SkPixmap which is a raw bytes wrapper capable of performing conversions.
    SkPixmap sourcePixmap(sourceImageInfo, source, sourceBytesPerRow);
    SkImageInfo destinationImageInfo = SkImageInfo::Make(
        destinationSize.width(),
        destinationSize.height(),
        *destinationSkiaColorType,
        toSkiaAlphaType(destinationFormat.alphaFormat),
        destinationFormat.colorSpace.platformColorSpace()
    );
    // Read pixels from source to destination and convert pixels if necessary.
    sourcePixmap.readPixels(destinationImageInfo, destination, destinationBytesPerRow);
    return true;
}

bool convertImagePixelsSkia(const PixelBufferFormat& sourceFormat, unsigned sourceBytesPerRow, NOESCAPE std::span<const uint8_t> source, const PixelBufferFormat& destinationFormat, unsigned destinationBytesPerRow, NOESCAPE std::span<uint8_t> destination, const IntSize& destinationSize)
{
    return convertImagePixelsSkia(sourceFormat, sourceBytesPerRow, source.data(), destinationFormat, destinationBytesPerRow, destination.data(), destinationSize);
}

bool convertImagePixelsSkiaInPlace(const PixelBufferFormat& sourceFormat, const PixelBufferFormat& destinationFormat, unsigned bytesPerRow, NOESCAPE std::span<uint8_t> bytes, const IntSize& destinationSize)
{
    return convertImagePixelsSkia(sourceFormat, bytesPerRow, bytes.data(), destinationFormat, bytesPerRow, bytes.data(), destinationSize);
}

#endif // USE(SKIA)

}
