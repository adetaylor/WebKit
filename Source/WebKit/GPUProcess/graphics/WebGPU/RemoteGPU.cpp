/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
#include "RemoteGPU.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteRenderingBackend.h"
#include <WebCore/ColorSpace.h>
#include <WebCore/GraphicsContext.h>
#include <WebCore/IOSurface.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/NativeImage.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <wtf/threads/BinarySemaphore.h>

namespace WebKit {

static void paintToCanvas(WebCore::NativeImage& image, const WebCore::IntSize& canvasSize, WebCore::GraphicsContext& context)
{
    auto imageSize = image.size();
    WebCore::FloatRect canvasRect(WebCore::FloatPoint(), canvasSize);
    WebCore::GraphicsContextStateSaver stateSaver(context);
    context.setImageInterpolationQuality(WebCore::InterpolationQuality::DoNotInterpolate);
    context.drawNativeImage(image, canvasRect, WebCore::FloatRect(WebCore::FloatPoint(), imageSize), { WebCore::CompositeOperator::Copy });
}

void paintNativeImageToImageBuffer(RemoteRenderingBackend& backend, WebCore::NativeImage& nativeImage, WebCore::RenderingResourceIdentifier imageBufferIdentifier)
{
    BinarySemaphore semaphore;

    Ref renderingBackend = backend;
    Ref protectedNativeImage = nativeImage;
    renderingBackend->dispatch([&]() mutable {
        if (auto imageBuffer = renderingBackend->imageBuffer(imageBufferIdentifier)) {
            paintToCanvas(protectedNativeImage, imageBuffer->backendSize(), imageBuffer->context());
            imageBuffer->flushDrawingContext();
        }
        semaphore.signal();
    });
    semaphore.wait();
}

void paintToImageBuffer(RemoteRenderingBackend& renderingBackend, CGImageRef image, IOSurfaceRef surface, bool forceOpaque, uint64_t imageBufferIdentifier)
{
    WebCore::RenderingResourceIdentifier identifier { imageBufferIdentifier };
    if (image) {
        if (RefPtr nativeImage = WebCore::NativeImage::create(RetainPtr { image })) {
            CGImageSetCachingFlags(nativeImage->platformImage().get(), kCGImageCachingTransient);
            paintNativeImageToImageBuffer(renderingBackend, *nativeImage, identifier);
        }
        return;
    }

    auto ioSurface = WebCore::IOSurface::createFromSurface(surface, std::nullopt);
    if (!ioSurface)
        return;
    // A surface made with an opaque format (BGRX, RGBX) reads back as its alpha format's, so the alpha channel to ignore
    // is chosen here, as the opaque format's bitmap configuration and IOSurface::withNativeImage() would.
    std::optional<CGImageAlphaInfo> alphaInfo;
    if (forceOpaque) {
        switch (ioSurface->pixelFormat().value_or(WebCore::IOSurface::Format::BGRA)) {
        case WebCore::IOSurface::Format::BGRA:
        case WebCore::IOSurface::Format::RGBA:
            alphaInfo = kCGImageAlphaNoneSkipFirst;
            break;
#if ENABLE(PIXEL_FORMAT_RGBA16F)
        case WebCore::IOSurface::Format::RGBA16F:
            alphaInfo = kCGImageAlphaNoneSkipLast;
            break;
#endif
        default:
            break;
        }
    }
    RetainPtr context = ioSurface->createPlatformContext(0, alphaInfo);
    if (!context)
        return;
    RefPtr nativeImage = WebCore::NativeImage::create(ioSurface->createImage(context.get()));
    if (!nativeImage)
        return;
    CGImageSetCachingFlags(nativeImage->platformImage().get(), kCGImageCachingTransient);
    paintNativeImageToImageBuffer(renderingBackend, *nativeImage, identifier);
}

static RefPtr<WebCore::ImageBuffer> flushedImageBuffer(RemoteRenderingBackend& backend, WebCore::RenderingResourceIdentifier imageBufferIdentifier)
{
    BinarySemaphore semaphore;

    RefPtr<WebCore::ImageBuffer> result;
    Ref renderingBackend = backend;
    renderingBackend->dispatch([&] mutable {
        if (RefPtr imageBuffer = renderingBackend->imageBuffer(imageBufferIdentifier)) {
            imageBuffer->flushDrawingContext();
            result = WTF::move(imageBuffer);
        }
        semaphore.signal();
    });
    semaphore.wait();

    return result;
}

IOSurfaceRef copyImageBufferSurface(RemoteRenderingBackend& renderingBackend, uint64_t imageBufferIdentifier, RemoteGPUImageBufferSurface& description)
{
    RefPtr imageBuffer = flushedImageBuffer(renderingBackend, WebCore::RenderingResourceIdentifier { imageBufferIdentifier });
    if (!imageBuffer)
        return nullptr;

    // Only accelerated ImageBuffers have an IOSurface to wrap in an MTLTexture. GPUQueue rejects
    // unaccelerated sources before we get here, but the backing may have been dropped since.
    auto* surface = imageBuffer->surface();
    if (!surface)
        return nullptr;

    auto size = imageBuffer->truncatedLogicalSize();
    if (!size.width() || !size.height())
        return nullptr;

    description = {
        .pixelFormat = imageBuffer->pixelFormat(),
        .width = static_cast<uint32_t>(size.width()),
        .height = static_cast<uint32_t>(size.height()),
        .isDisplayP3 = imageBuffer->colorSpace() == WebCore::ColorSpace::DisplayP3(),
    };
    return RetainPtr { surface->surface() }.leakRef();
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
