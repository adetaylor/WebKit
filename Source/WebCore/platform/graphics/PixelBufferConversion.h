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

#pragma once

#include <WebCore/PixelBufferFormat.h>
#include <span>
#include <wtf/SwiftBridging.h>

#if USE(SKIA)
// The convertImagePixelsSkia() declarations below get Swift Span overloads only with every parameter type complete.
#include <WebCore/IntSize.h>
#endif

namespace WebCore {

class IntSize;

struct SWIFT_VIEW PixelBufferConversionView {
    PixelBufferFormat format;
    unsigned bytesPerRow;
    std::span<uint8_t> rows;
};

// Imported as ~Escapable, so Swift reads the rows as a lifetime-checked Span, with no `unsafe`.
struct SWIFT_VIEW ConstPixelBufferConversionView {
    PixelBufferFormat format;
    unsigned bytesPerRow;
    std::span<const uint8_t> rows;

    std::span<const uint8_t> span() const LIFETIME_BOUND { return rows; }
};

WEBCORE_EXPORT void convertImagePixels(const ConstPixelBufferConversionView& source, const PixelBufferConversionView& destination, const IntSize&);

WEBCORE_EXPORT void LEGACY_NODELETE copyRowsInternal(unsigned sourceBytesPerRow, std::span<const uint8_t> source, unsigned destinationBytesPerRow, std::span<uint8_t> destination, unsigned rows, unsigned copyBytesPerRow);

inline void copyRows(unsigned sourceBytesPerRow, std::span<const uint8_t> source, unsigned destinationBytesPerRow, std::span<uint8_t> destination, unsigned rows, unsigned copyBytesPerRow)
{
    if (!rows || !copyBytesPerRow)
        return;
    uint64_t requiredSourceBytes = static_cast<uint64_t>(sourceBytesPerRow) * (rows - 1) + copyBytesPerRow;
    if (source.size() < requiredSourceBytes) {
        ASSERT_NOT_REACHED();
        return;
    }
    uint64_t requiredDestinationBytes = static_cast<uint64_t>(destinationBytesPerRow) * (rows - 1) + copyBytesPerRow;
    if (destination.size() < requiredDestinationBytes) {
        ASSERT_NOT_REACHED();
        return;
    }
    if (rows > 1 && (sourceBytesPerRow < copyBytesPerRow || destinationBytesPerRow < copyBytesPerRow)) {
        ASSERT_NOT_REACHED();
        return;
    }
    copyRowsInternal(sourceBytesPerRow, source, destinationBytesPerRow, destination, rows, copyBytesPerRow);
}

#if USE(SKIA)
// SkPixmap::readPixels() conversions for PixelConversion.swift; false if Skia has no color type for a format.
bool convertImagePixelsSkia(const PixelBufferFormat& sourceFormat, unsigned sourceBytesPerRow, NOESCAPE std::span<const uint8_t> source, const PixelBufferFormat& destinationFormat, unsigned destinationBytesPerRow, NOESCAPE std::span<uint8_t> destination, const IntSize&);
bool convertImagePixelsSkiaInPlace(const PixelBufferFormat& sourceFormat, const PixelBufferFormat& destinationFormat, unsigned bytesPerRow, NOESCAPE std::span<uint8_t>, const IntSize&);
#endif

}
