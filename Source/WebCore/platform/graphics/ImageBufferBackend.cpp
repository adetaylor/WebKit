/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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
#include "ImageBufferBackend.h"

#include "GraphicsContext.h"
#include "ImageBuffer.h"
#include "Logging.h"
#include "NativeImage.h"
#include "PixelBuffer.h"
#include "PixelBufferSwiftBridge.h"
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ThreadSafeImageBufferFlusher);

IntSize ImageBufferBackend::calculateSafeBackendSize(const ImageBufferParameters& parameters)
{
    IntSize backendSize = parameters.backendSize();
    if (backendSize.isEmpty())
        return backendSize;

    auto bytesPerRow = PixelBuffer::bytesPerPixel(parameters.bufferFormat.pixelFormat) * CheckedUint32(backendSize.width());
    if (bytesPerRow.hasOverflowed())
        return { };

    CheckedSize numBytes = CheckedUint32(backendSize.height()) * bytesPerRow;
    if (numBytes.hasOverflowed())
        return { };

    return backendSize;
}

size_t ImageBufferBackend::calculateMemoryCost(const IntSize& backendSize, unsigned bytesPerRow)
{
    ASSERT(!backendSize.isEmpty());
    return CheckedUint32(backendSize.height()) * bytesPerRow;
}

ImageBufferBackend::ImageBufferBackend(const ImageBufferParameters& parameters)
    : m_backendSize(parameters.backendSize())
    , m_resolutionScale(parameters.resolutionScale)
    , m_colorSpace(parameters.colorSpace)
    , m_bufferFormat(parameters.bufferFormat)
    , m_purpose(parameters.purpose)
{
}

ImageBufferBackend::~ImageBufferBackend() = default;

RefPtr<NativeImage> ImageBufferBackend::sinkIntoNativeImage()
{
    return createNativeImageReference();
}

#if ENABLE(PIXEL_FORMAT_RGBA16F)
void ImageBufferBackend::convertToLuminanceMaskFloat16()
{
    LOG(Images, "convertToLuminanceMask() is not implemented for Float16 ImageBuffers.");
}
#endif

void ImageBufferBackend::convertToLuminanceMaskUint8()
{
    IntRect sourceRect { { }, size() };
    PixelBufferFormat format { AlphaPremultiplication::Unpremultiplied, PixelFormat::RGBA8, colorSpace() };
    auto pixelBuffer = ImageBufferAllocator().createPixelBuffer(format, sourceRect.size());
    if (!pixelBuffer)
        return;
    getPixelBuffer(sourceRect, *pixelBuffer);

    MutablePixelBytes pixels { pixelBuffer->bytes() };
    luminanceMaskApply(pixels);

    putPixelBuffer(*pixelBuffer, sourceRect, IntPoint::zero(), AlphaPremultiplication::Premultiplied);
}

void ImageBufferBackend::convertToLuminanceMask()
{
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    if (pixelFormat() == PixelFormat::RGBA16F)
        convertToLuminanceMaskFloat16();
    else
#endif
        convertToLuminanceMaskUint8();
}

// The transfers themselves are in PixelTransfer.swift. Swift assumes that the bytes it reads don't overlap the bytes
// it writes, so overlapping sources are copied first.

static bool transferBytesOverlap(std::span<const uint8_t> source, std::span<const uint8_t> destination)
{
    return !source.empty() && !destination.empty() && spansOverlap(source, destination);
}

static PixelTransferGeometry pixelTransferGeometry(const IntRect& sourceRect, const IntPoint& destinationPoint, const IntSize& pixelBufferSize, const IntSize& backendSize, unsigned backendBytesPerRow)
{
    return {
        sourceRect.x(), sourceRect.y(), sourceRect.width(), sourceRect.height(),
        destinationPoint.x(), destinationPoint.y(),
        pixelBufferSize.width(), pixelBufferSize.height(),
        backendSize.width(), backendSize.height(),
        backendBytesPerRow
    };
}

void ImageBufferBackend::getPixelBuffer(const IntRect& sourceRect, std::span<const uint8_t> sourceData, PixelBuffer& destinationPixelBuffer)
{
    auto geometry = pixelTransferGeometry(sourceRect, { }, { }, m_backendSize, bytesPerRow());
    PixelBufferFormat sourceFormat { AlphaPremultiplication::Premultiplied, pixelFormat(), colorSpace() };
    auto destinationData = destinationPixelBuffer.bytes();
    MutablePixelBytes destination { destinationData };
    if (transferBytesOverlap(sourceData, destinationData)) {
        Vector<uint8_t> sourceCopy(sourceData);
        pixelTransferGetPixelBuffer(geometry, sourceFormat, PixelBytes { sourceCopy.span() }, destinationPixelBuffer.format(), destination);
        return;
    }
    pixelTransferGetPixelBuffer(geometry, sourceFormat, PixelBytes { sourceData }, destinationPixelBuffer.format(), destination);
}

void ImageBufferBackend::putPixelBuffer(const PixelBufferSourceView& sourcePixelBuffer, const IntRect& sourceRect, const IntPoint& destinationPoint, AlphaPremultiplication destinationAlphaFormat, std::span<uint8_t> destinationData)
{
    auto geometry = pixelTransferGeometry(sourceRect, destinationPoint, sourcePixelBuffer.size(), m_backendSize, bytesPerRow());
    PixelBufferFormat destinationFormat { destinationAlphaFormat, pixelFormat(), colorSpace() };
    auto sourceData = sourcePixelBuffer.bytes();
    MutablePixelBytes destination { destinationData };
    if (transferBytesOverlap(sourceData, destinationData)) {
        Vector<uint8_t> sourceCopy(sourceData);
        pixelTransferPutPixelBuffer(geometry, sourcePixelBuffer.format(), PixelBytes { sourceCopy.span() }, destinationFormat, destination);
        return;
    }
    pixelTransferPutPixelBuffer(geometry, sourcePixelBuffer.format(), PixelBytes { sourceData }, destinationFormat, destination);
}

RefPtr<SharedBuffer> ImageBufferBackend::sinkIntoPDFDocument()
{
    return nullptr;
}

static AffineTransform LEGACY_NODELETE baseTransformForBackingStore(const IntSize& backendSize, float resolutionScale)
{
    AffineTransform baseTransform;
#if USE(CG)
    // CoreGraphics origin is at bottom left corner. GraphicsContext origin is at top left corner. Flip the drawing with GraphicsContext base
    // transform.
    baseTransform.scale(1, -1);
    baseTransform.translate(0, -backendSize.height());
#else
    UNUSED_PARAM(backendSize);
#endif
    baseTransform.scale(resolutionScale);
    return baseTransform;
}

AffineTransform ImageBufferBackend::calculateBaseTransform(const ImageBufferParameters& parameters)
{
    return baseTransformForBackingStore(parameters.backendSize(), parameters.resolutionScale);
}

AffineTransform ImageBufferBackend::baseTransform() const
{
    return baseTransformForBackingStore(m_backendSize, m_resolutionScale);
}

TextStream& operator<<(TextStream& ts, SetNonVolatileResult state)
{
    switch (state) {
    case SetNonVolatileResult::Valid: ts << "valid"_s; break;
    case SetNonVolatileResult::Empty: ts << "empty"_s; break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, VolatilityState state)
{
    switch (state) {
    case VolatilityState::NonVolatile: ts << "non-volatile"_s; break;
    case VolatilityState::Volatile: ts << "volatile"_s; break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, const ImageBufferBackend& imageBufferBackend)
{
    ts << imageBufferBackend.debugDescription();
    return ts;
}

} // namespace WebCore
