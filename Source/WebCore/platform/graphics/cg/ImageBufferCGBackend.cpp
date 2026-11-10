/*
 * Copyright (C) 2020-2024 Apple Inc. All rights reserved.
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
#include "ImageBufferCGBackend.h"

#if USE(CG)

#include "IOSurfacePool.h"
#include "IntRect.h"
#include "PixelBuffer.h"
#include "ShareableBitmap.h"
#include <CoreGraphics/CoreGraphics.h>
#include <wtf/MachSendRight.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

class ThreadSafeImageBufferFlusherCG : public ThreadSafeImageBufferFlusher {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(ThreadSafeImageBufferFlusherCG);
public:
    ThreadSafeImageBufferFlusherCG(CGContextRef context)
        : m_context(context)
    {
    }

    void flush() override
    {
        CGContextFlush(m_context.get());
    }

private:
    const RetainPtr<CGContextRef> m_context;
};

ImageBufferCGBackend::ImageBufferCGBackend(const ImageBufferParameters& parameters, std::unique_ptr<GraphicsContextCG>&& context, ImageBufferSurface&& core)
    : ImageBufferBackend(parameters)
    , m_context(WTF::move(context))
    , m_core(WTF::move(core))
{
}

ImageBufferCGBackend::~ImageBufferCGBackend() = default;

unsigned ImageBufferCGBackend::calculateBytesPerRow(const IntSize& backendSize, PixelFormat pixelFormat)
{
    ASSERT(!backendSize.isEmpty());
    return CheckedUint32(backendSize.width()) * PixelBuffer::bytesPerPixel(pixelFormat);
}

std::unique_ptr<ThreadSafeImageBufferFlusher> ImageBufferCGBackend::createFlusher()
{
    return makeUnique<ThreadSafeImageBufferFlusherCG>(context().platformContext());
}

void ImageBufferCGBackend::applyBaseTransform(GraphicsContextCG& context) const
{
    context.applyDeviceScaleFactor(resolutionScale());
    context.setCTM(baseTransform());
}

String ImageBufferCGBackend::debugDescription() const
{
    TextStream stream;
    stream << "ImageBufferCGBackend " << this;
    return stream.release();
}

#if HAVE(IOSURFACE)
ImageBufferSurface ImageBufferSurface::create(IOSurface& surface, IOSurfacePool* pool, IOSurface::Format format, UseLosslessCompression useLosslessCompression, PlatformDisplayID displayID, bool useWebKitBehavior, bool shouldClear)
{
    return ImageBufferSurface { createIOSurfaceSwiftState(surface.m_swiftState, pool ? pool->m_swiftState : 0, format, useLosslessCompression, displayID, useWebKitBehavior, shouldClear) };
}

ImageBufferSurface ImageBufferSurface::createForMappedBitmap(IOSurface& surface, IOSurfacePool* pool)
{
    return ImageBufferSurface { createMappedIOSurfaceBitmapSwiftState(surface.m_swiftState, pool ? pool->m_swiftState : 0) };
}
#endif

ImageBufferSurface ImageBufferSurface::create(ShareableBitmap& bitmap)
{
    if (bitmap.m_configuration.shareableGainMap())
        return { };
    return ImageBufferSurface { createShareableBitmapSwiftState(bitmap.m_swiftState) };
}

ImageBufferSurface ImageBufferSurface::create(CGContextRef context, CGDataProviderRef dataProvider, CGColorSpaceRef colorSpace, IntSize size, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow, CGBitmapInfo bitmapInfo)
{
    return ImageBufferSurface { createBitmapSwiftState(context, dataProvider, colorSpace, size.width(), size.height(), bitsPerComponent, bitsPerPixel, bytesPerRow, bitmapInfo) };
}

ImageBufferSurface::ImageBufferSurface(ImageBufferSurface&& other)
    : m_swiftState(std::exchange(other.m_swiftState, 0))
{
}

ImageBufferSurface& ImageBufferSurface::operator=(ImageBufferSurface&& other)
{
    if (this != &other) {
        if (m_swiftState)
            destroySwiftState(m_swiftState);
        m_swiftState = std::exchange(other.m_swiftState, 0);
    }
    return *this;
}

ImageBufferSurface::~ImageBufferSurface()
{
    if (m_swiftState)
        destroySwiftState(m_swiftState);
}

RetainPtr<CGContextRef> ImageBufferSurface::platformContext()
{
    return adoptCF(swiftPlatformContext(m_swiftState));
}

RetainPtr<CGImageRef> ImageBufferSurface::createImage()
{
    return adoptCF(swiftCreateImage(m_swiftState));
}

RetainPtr<CGImageRef> ImageBufferSurface::createImageReference()
{
    return adoptCF(swiftCreateImageReference(m_swiftState));
}

#if HAVE(IOSURFACE)
bool ImageBufferSurface::flushContextDraws(bool contextHasDrawn)
{
    return swiftFlushContextDraws(m_swiftState, contextHasDrawn);
}

void ImageBufferSurface::prepareForExternalWrite(bool contextHasDrawn)
{
    swiftPrepareForExternalWrite(m_swiftState, contextHasDrawn);
}

bool ImageBufferSurface::mayHaveOutstandingBackingStoreReferences() const
{
    return swiftMayHaveOutstandingBackingStoreReferences(m_swiftState);
}

void ImageBufferSurface::submitDrawingCommands()
{
    swiftSubmitDrawingCommands(m_swiftState);
}

RetainPtr<CGImageRef> ImageBufferSurface::sinkIntoImage()
{
    return adoptCF(swiftSinkIntoImage(m_swiftState));
}

void ImageBufferSurface::releasePlatformContext()
{
    swiftReleasePlatformContext(m_swiftState);
}

bool ImageBufferSurface::setVolatile()
{
    return swiftSetVolatile(m_swiftState);
}

SetNonVolatileResult ImageBufferSurface::setNonVolatile()
{
    return swiftSetNonVolatile(m_swiftState);
}

VolatilityState ImageBufferSurface::volatilityState() const
{
    return swiftVolatilityState(m_swiftState);
}

void ImageBufferSurface::setVolatilityState(VolatilityState state)
{
    swiftSetVolatilityState(m_swiftState, state);
}

void ImageBufferSurface::setSurfacePool(IOSurfacePool* pool)
{
    swiftSetSurfacePool(m_swiftState, pool ? pool->m_swiftState : 0);
}

void ImageBufferSurface::moveSurfaceToPool()
{
    swiftMoveSurfaceToPool(m_swiftState);
}

RetainPtr<CGContextRef> ImageBufferSurface::createDisplayCopy(MachSendRight& sendRight)
{
    RetainPtr context = adoptCF(swiftCreateDisplayCopy(m_swiftState));
    sendRight = MachSendRight::adopt(swiftTakeDisplayCopySendRight(m_swiftState));
    return context;
}
#endif

ImageBufferSurfaceCountsForTesting ImageBufferSurface::countsForTesting()
{
    return {
        swiftCountForTesting(0),
        swiftCountForTesting(1),
        swiftCountForTesting(2),
        swiftCountForTesting(3),
        swiftCountForTesting(4),
        swiftCountForTesting(5),
        swiftCountForTesting(6),
    };
}

ImageBufferSurfaceCountsForTesting imageBufferSurfaceCountsForTesting()
{
    return ImageBufferSurface::countsForTesting();
}

} // namespace WebCore

#endif // USE(CG)
