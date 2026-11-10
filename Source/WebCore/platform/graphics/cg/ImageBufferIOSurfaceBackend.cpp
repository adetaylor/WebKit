/*
 * Copyright (C) 2020-2023 Apple Inc. All rights reserved.
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
#include "ImageBufferIOSurfaceBackend.h"

#if HAVE(IOSURFACE)

#include "GraphicsClient.h"
#include "GraphicsContextCG.h"
#include "GraphicsLayerContentsDisplayDelegate.h"
#include "IOSurface.h"
#include "IOSurfacePool.h"
#include "IntRect.h"
#include "NativeImage.h"
#include "PixelBuffer.h"
#include "PlatformCALayer.h"
#include "PlatformCALayerDelegatedContents.h"
#include <CoreGraphics/CoreGraphics.h>
#include <wtf/MachSendRight.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

class ImageBufferIOSurfaceDisplayFence final : public PlatformCALayerDelegatedContentsFence {
public:
    static Ref<ImageBufferIOSurfaceDisplayFence> create(RetainPtr<CGContextRef>&& context)
    {
        return adoptRef(*new ImageBufferIOSurfaceDisplayFence(WTF::move(context)));
    }

    bool waitFor(Seconds) final
    {
        Locker locker { m_lock };
        if (RetainPtr context = std::exchange(m_context, nullptr))
            CGContextFlush(context.get());
        return true;
    }

private:
    explicit ImageBufferIOSurfaceDisplayFence(RetainPtr<CGContextRef>&& context)
        : m_context(WTF::move(context))
    {
    }

    Lock m_lock;
    RetainPtr<CGContextRef> m_context WTF_GUARDED_BY_LOCK(m_lock);
};

class ImageBufferIOSurfaceDisplayDelegate final : public GraphicsLayerContentsDisplayDelegate {
public:
    NODELETE static Ref<ImageBufferIOSurfaceDisplayDelegate> create(ContentsFormat contentsFormat)
    {
        return adoptRef(*new ImageBufferIOSurfaceDisplayDelegate(contentsFormat));
    }

    void setContents(std::optional<PlatformCALayerDelegatedContents>&& contents)
    {
        m_contents = WTF::move(contents);
    }

    void display(PlatformCALayer& layer) final
    {
        if (!m_contents) {
            layer.clearContents();
            return;
        }
        layer.setContentsFormat(m_contentsFormat);
        layer.setDelegatedContents({ MachSendRight { m_contents->surface }, m_contents->finishedFence });
    }

    std::optional<PlatformCALayerDelegatedContents> delegatedContents() const final
    {
        return m_contents;
    }

private:
    explicit ImageBufferIOSurfaceDisplayDelegate(ContentsFormat contentsFormat)
        : m_contentsFormat(contentsFormat)
    {
    }

    std::optional<PlatformCALayerDelegatedContents> m_contents;
    const ContentsFormat m_contentsFormat;
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(ImageBufferIOSurfaceBackend);

IntSize ImageBufferIOSurfaceBackend::calculateSafeBackendSize(const ImageBufferParameters& parameters)
{
    IntSize backendSize = parameters.backendSize();
    if (backendSize.isEmpty())
        return { };

    IntSize maxSize = IOSurface::maximumSize();
    if (backendSize.width() > maxSize.width() || backendSize.height() > maxSize.height())
        return { };

    return backendSize;
}

unsigned ImageBufferIOSurfaceBackend::calculateBytesPerRow(const IntSize& backendSize, PixelFormat imageBufferPixelFormat)
{
    unsigned bytesPerRow = ImageBufferCGBackend::calculateBytesPerRow(backendSize, imageBufferPixelFormat);
    size_t alignmentMask = IOSurface::bytesPerRowAlignment() - 1;
    return (bytesPerRow + alignmentMask) & ~alignmentMask;
}

std::unique_ptr<ImageBufferIOSurfaceBackend> ImageBufferIOSurfaceBackend::create(const ImageBufferParameters& parameters, const ImageBufferCreationContext& creationContext)
{
    IntSize backendSize = calculateSafeBackendSize(parameters);
    if (backendSize.isEmpty())
        return nullptr;

    RefPtr surfacePool = creationContext.surfacePool;
    auto format = convertToIOSurfaceFormat(parameters.bufferFormat.pixelFormat);
    auto surface = IOSurface::create(surfacePool.get(), backendSize, parameters.colorSpace, IOSurface::Name::ImageBuffer, format, parameters.bufferFormat.useLosslessCompression);
    if (!surface)
        return nullptr;

    auto core = ImageBufferSurface::create(*surface, surfacePool.get(), format, parameters.bufferFormat.useLosslessCompression, creationContext.displayID, creationContext.useIOSurfaceWebKitBehavior, true);
    if (!core)
        return nullptr;

    return std::unique_ptr<ImageBufferIOSurfaceBackend> { new ImageBufferIOSurfaceBackend { parameters, WTF::move(surface), WTF::move(core) } };
}

ImageBufferIOSurfaceBackend::ImageBufferIOSurfaceBackend(const ImageBufferParameters& parameters, std::unique_ptr<IOSurface> surface, ImageBufferSurface&& core)
    : ImageBufferCGBackend(parameters, nullptr, WTF::move(core))
    , m_surface(WTF::move(surface))
{
    ASSERT(m_surface);
    ASSERT(m_core);
    ASSERT(!m_surface->isVolatile());
}

RefPtr<GraphicsLayerContentsDisplayDelegate> ImageBufferIOSurfaceBackend::layerContentsDisplayDelegate()
{
    if (!m_layerContentsDisplayDelegate) {
        m_layerContentsDisplayDelegate = ImageBufferIOSurfaceDisplayDelegate::create(convertToContentsFormat(pixelFormat()));
        prepareForDisplay();
    }
    return m_layerContentsDisplayDelegate;
}

void ImageBufferIOSurfaceBackend::releaseLayerContentsDisplayDelegate()
{
    m_layerContentsDisplayDelegate = nullptr;
}

void ImageBufferIOSurfaceBackend::prepareForDisplay()
{
    RefPtr displayDelegate = m_layerContentsDisplayDelegate;
    if (!displayDelegate)
        return;

    std::optional<PlatformCALayerDelegatedContents> contents;
    MachSendRight sendRight;
    if (RetainPtr context = m_core.createDisplayCopy(sendRight))
        contents = PlatformCALayerDelegatedContents { WTF::move(sendRight), ImageBufferIOSurfaceDisplayFence::create(WTF::move(context)) };
    displayDelegate->setContents(WTF::move(contents));
}

ImageBufferIOSurfaceBackend::~ImageBufferIOSurfaceBackend()
{
    // sinkIntoNativeImage() moves the surface into the image.
    if (!m_surface)
        return;
    ensureNativeImagesHaveCopiedBackingStore();
    releaseGraphicsContext();
    m_surface = nullptr;
    m_core.moveSurfaceToPool();
}

RenderingMode ImageBufferIOSurfaceBackend::renderingMode() const
{
    return RenderingMode::Accelerated;
}

size_t ImageBufferIOSurfaceBackend::memoryCost() const
{
    return ImageBufferBackend::calculateMemoryCost(size(), calculateBytesPerRow(size(), pixelFormat()));
}

GraphicsContext& ImageBufferIOSurfaceBackend::context()
{
    if (!m_context) {
        m_context = makeUnique<GraphicsContextCG>(m_core.platformContext().get());
        applyBaseTransform(*m_context);
    }
    return *m_context;
}

void ImageBufferIOSurfaceBackend::flushContext()
{
    flushContextDraws();
}

void ImageBufferIOSurfaceBackend::submitDrawingCommands()
{
    m_core.submitDrawingCommands();
}

bool ImageBufferIOSurfaceBackend::consumeContextHasDrawn()
{
    return m_context && m_context->consumeHasDrawn();
}

bool ImageBufferIOSurfaceBackend::flushContextDraws()
{
    return m_core.flushContextDraws(consumeContextHasDrawn());
}

unsigned ImageBufferIOSurfaceBackend::bytesPerRow() const
{
    return m_surface->bytesPerRow();
}

void ImageBufferIOSurfaceBackend::transferToNewContext(const ImageBufferCreationContext& creationContext)
{
    m_core.setSurfacePool(RefPtr { creationContext.surfacePool }.get());
    if (creationContext.resourceOwner)
        m_surface->setOwnershipIdentity(creationContext.resourceOwner);
}

RefPtr<NativeImage> ImageBufferIOSurfaceBackend::copyNativeImage()
{
    return NativeImage::create(m_core.createImage());
}

RefPtr<NativeImage> ImageBufferIOSurfaceBackend::createNativeImageReference()
{
    // The destination backend needs to read the actual pixels. Returning non-refence will
    // copy the pixels and but still cache the image to the context. This means we must
    // return the reference or cleanup later if we return the non-reference.
    return NativeImage::create(m_core.createImageReference());
}

RefPtr<NativeImage> ImageBufferIOSurfaceBackend::sinkIntoNativeImage()
{
    auto image = m_core.sinkIntoImage();
    m_surface = nullptr;
    return NativeImage::create(WTF::move(image));
}

void ImageBufferIOSurfaceBackend::getPixelBuffer(const IntRect& srcRect, PixelBuffer& destination)
{
    prepareForExternalRead();
    if (auto lock = m_surface->lock<IOSurface::AccessMode::ReadOnly>())
        ImageBufferBackend::getPixelBuffer(srcRect, lock->surfaceSpan(), destination);
}

void ImageBufferIOSurfaceBackend::putPixelBuffer(const PixelBufferSourceView& pixelBuffer, const IntRect& srcRect, const IntPoint& destPoint, AlphaPremultiplication destFormat)
{
    prepareForExternalWrite();
    if (auto lock = m_surface->lock<IOSurface::AccessMode::ReadWrite>())
        ImageBufferBackend::putPixelBuffer(pixelBuffer, srcRect, destPoint, destFormat, lock->surfaceSpan());
}

bool ImageBufferIOSurfaceBackend::canMapBackingStore() const
{
    return true;
}

IOSurface* ImageBufferIOSurfaceBackend::surface()
{
    prepareForExternalWrite(); // This is conservative. At the time of writing this is not used.
    return m_surface.get();
}

bool ImageBufferIOSurfaceBackend::isInUse() const
{
    return m_surface->isInUse();
}

void ImageBufferIOSurfaceBackend::releaseGraphicsContext()
{
    m_context = nullptr;
    m_core.releasePlatformContext();
}

bool ImageBufferIOSurfaceBackend::setVolatile()
{
    return m_core.setVolatile();
}

SetNonVolatileResult ImageBufferIOSurfaceBackend::setNonVolatile()
{
    return m_core.setNonVolatile();
}

VolatilityState ImageBufferIOSurfaceBackend::volatilityState() const
{
    return m_core.volatilityState();
}

void ImageBufferIOSurfaceBackend::setVolatilityState(VolatilityState volatilityState)
{
    m_core.setVolatilityState(volatilityState);
}

void ImageBufferIOSurfaceBackend::ensureNativeImagesHaveCopiedBackingStore()
{
    // FIXME: This will be removed. This was needed when putImageData was not properly accounting
    // for outstanding reads.
    if (!m_core.mayHaveOutstandingBackingStoreReferences())
        return;
    prepareForExternalWrite();
}

void ImageBufferIOSurfaceBackend::prepareForExternalRead()
{
    // Ensure that there are no pending draws to this surface. This is ensured by flushing the context
    // through which the draws may have come.
    flushContextDraws();
}

void ImageBufferIOSurfaceBackend::prepareForExternalWrite()
{
    m_core.prepareForExternalWrite(consumeContextHasDrawn());
}

} // namespace WebCore

#endif // HAVE(IOSURFACE)
