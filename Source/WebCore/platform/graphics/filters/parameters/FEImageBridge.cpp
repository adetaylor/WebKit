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
#include "FEImageParameters.h"

#include "GraphicsContext.h"
#include "NativeImage.h"
#include "SourceImage.h"

#if USE(CORE_IMAGE)
#include "IOSurface.h"
#endif

namespace WebCore {

static FEImageSourceKind sourceKind(const SourceImage& sourceImage)
{
    if (sourceImage.nativeImageIfExists())
        return FEImageSourceKind::NativeImage;
    if (sourceImage.imageBufferIfExists())
        return FEImageSourceKind::ImageBuffer;
    return FEImageSourceKind::None;
}

FEImageSource::FEImageSource(const SourceImage& sourceImage)
    : kind(sourceKind(sourceImage))
    , m_sourceImage(sourceImage)
{
}

void FEImageSource::drawNativeImage(ImageBuffer& destination, const IntRect& destinationRect) const
{
    RefPtr nativeImage = m_sourceImage.nativeImageIfExists();
    if (!nativeImage)
        return;
    destination.context().drawNativeImage(*nativeImage, destinationRect, FloatRect { { }, nativeImage->size() });
}

RefPtr<ImageBuffer> FEImageSource::imageBuffer() const
{
    return m_sourceImage.imageBufferIfExists();
}

#if USE(CORE_IMAGE)
IntSize FEImageSource::nativeImageSize() const
{
    RefPtr nativeImage = m_sourceImage.nativeImageIfExists();
    return nativeImage ? nativeImage->size() : IntSize();
}

CGImageRef FEImageSource::copyNativeImagePlatformImage() const
{
    RefPtr nativeImage = m_sourceImage.nativeImageIfExists();
    if (!nativeImage)
        return nullptr;
    return nativeImage->platformImage().leakRef();
}

IOSurfaceRef FEImageSource::imageBufferSurface() const
{
    RefPtr imageBuffer = m_sourceImage.imageBufferIfExists();
    if (!imageBuffer)
        return nullptr;
    auto* surface = imageBuffer->surface();
    return surface ? surface->surface() : nullptr;
}
#endif

} // namespace WebCore
