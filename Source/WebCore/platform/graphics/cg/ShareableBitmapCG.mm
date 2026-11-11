/*
 * Copyright (C) 2010-2026 Apple Inc. All rights reserved.
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
#include "ShareableBitmap.h"

#include "GraphicsContextCG.h"
#include "ImageUtilities.h"
#include "Logging.h"
#include "NativeImage.h"
#include "PlatformScreen.h"
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <wtf/RetainPtr.h>
#include <wtf/StdLibExtras.h>
#include <wtf/cf/VectorCF.h>
#include <wtf/spi/cocoa/IOSurfaceSPI.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

ShareableBitmapConfiguration::ShareableBitmapConfiguration(const NativeImage& image)
    : m_size(image.size())
    , m_colorSpace(image.colorSpace())
    , m_baseImageHeadroom(image.baseImageHeadroom())
    , m_bitsPerComponent(CGImageGetBitsPerComponent(image.platformImage().get()))
    , m_bytesPerPixel(CGImageGetBitsPerPixel(image.platformImage().get()) / 8)
    , m_bytesPerRow(CGImageGetBytesPerRow(image.platformImage().get()))
    , m_bitmapInfo(CGImageGetBitmapInfo(image.platformImage().get()))
    , m_shareableGainMap(ShareableGainMap::create(image.gainMap()))
{
}

ColorSpace ShareableBitmapConfiguration::validateColorSpace(const ColorSpace& colorSpace)
{
    if (auto colorSpaceAsRGB = colorSpace.asRGBModelMayBeExtended())
        return *colorSpaceAsRGB;

    return ColorSpace::ExtendedSRGB();
}

RefPtr<ShareableBitmap> ShareableBitmap::createFromImagePixels(const NativeImage& image)
{
    auto colorSpace = image.colorSpace();
    if (CGColorSpaceGetModel(protect(colorSpace.platformColorSpace()).get()) != kCGColorSpaceModelRGB)
        return nullptr;

    RetainPtr sourceProvider = CGImageGetDataProvider(image.platformImage().get());
    if (!sourceProvider)
        return nullptr;

    auto configuration = ShareableBitmapConfiguration(image);

    RetainPtr<CFDataRef> pixels;
    @try {
        pixels = adoptCF(CGDataProviderCopyData(sourceProvider.get()));
    } @catch (id exception) {
        LOG_WITH_STREAM(Images, stream
            << "ShareableBitmap::createFromImagePixels() failed CGDataProviderCopyData "
            << " CGImage size: " << configuration.size()
            << " CGImage bytesPerRow: " << configuration.bytesPerRow()
            << " CGImage sizeInBytes: " << configuration.sizeInBytes());
        return nullptr;
    }

    if (!pixels)
        return nullptr;

    auto bytes = WTF::span(pixels.get());
    switch (shareableBitmapCheckImagePixels(configuration.layoutGeometry(), bytes.size())) {
    case ShareableBitmapImagePixels::Copyable:
        break;
    case ShareableBitmapImagePixels::Unusable:
        return nullptr;
    case ShareableBitmapImagePixels::SizeMismatch:
        LOG_WITH_STREAM(Images, stream
            << "ShareableBitmap::createFromImagePixels() " << image.platformImage().get()
            << " CGImage size: " << configuration.size()
            << " CGImage bytesPerRow: " << configuration.bytesPerRow()
            << " CGImage sizeInBytes: " << configuration.sizeInBytes()
            << " CGDataProvider sizeInBytes: " << bytes.size()
            << " CGImage and its CGDataProvider disagree about how many bytes are in pixels buffer. CGImage is a sub-image; bailing.");
        return nullptr;
    }

    RefPtr sharedMemory = SharedMemory::allocate(bytes.size());
    if (!sharedMemory)
        return nullptr;

    MutablePixelBytes destination { sharedMemory->mutableSpan() };
    shareableBitmapCopyImagePixels(PixelBytes { bytes }, destination);
    return adoptRef(new ShareableBitmap(configuration, sharedMemory.releaseNonNull()));
}

std::unique_ptr<GraphicsContext> ShareableBitmap::createGraphicsContext()
{
    RetainPtr bitmapContext = adoptCF(swiftCreateCGContext(m_swiftState));
    if (!bitmapContext)
        return nullptr;
    return makeUnique<GraphicsContextCG>(bitmapContext.get());
}

void ShareableBitmap::paint(GraphicsContext& context, const IntPoint& destination, const IntRect& source)
{
    paint(context, 1, destination, source);
}

void ShareableBitmap::paint(GraphicsContext& context, float scaleFactor, const IntPoint& destination, const IntRect& source)
{
    RetainPtr image = createPlatformImage();
    swiftPaint(image.get(), protect(context.platformContext()).get(), scaleFactor, CGPointMake(destination.x(), destination.y()), CGRectMake(source.x(), source.y(), source.width(), source.height()));
}

PlatformImagePtr ShareableBitmap::createBasePlatformImage(BackingStoreCopy copyBehavior, ShouldInterpolate shouldInterpolate)
{
    return adoptCF(swiftCreateBasePlatformImage(m_swiftState, copyBehavior == CopyBackingStore, shouldInterpolate == ShouldInterpolate::Yes));
}

PlatformImagePtr ShareableBitmap::createPlatformImage(BackingStoreCopy copyBehavior, ShouldInterpolate shouldInterpolate)
{
    RetainPtr basePlatformImage = createBasePlatformImage(copyBehavior, shouldInterpolate);
    if (!basePlatformImage)
        return basePlatformImage;

    auto shareableGainMap = m_configuration.shareableGainMap();
    if (!shareableGainMap)
        return basePlatformImage;

    RetainPtr outputPlatformImage = shareableGainMap->applyGainMapToBaseImage(basePlatformImage);
    if (!outputPlatformImage)
        return basePlatformImage;

#if ENABLE(DUMP_GAIN_MAP_IMAGES)
    CGImageDumpToFile(basePlatformImage.get(), "*/base-image.br2");
    CGImageDumpToFile(outputPlatformImage.get(), "*/output-image.br2");
#endif

    return outputPlatformImage;
}

RefPtr<NativeImage> ShareableBitmap::createNativeImage()
{
    return NativeImage::create(createPlatformImage(DontCopyBackingStore));
}

void ShareableBitmap::setOwnershipOfMemory(const ProcessIdentity& identity)
{
    m_ownershipHandle = m_sharedMemory->createHandle(SharedMemory::Protection::ReadWrite);
    if (!m_ownershipHandle)
        return;
    m_ownershipHandle->setOwnershipOfMemory(identity, MemoryLedger::Graphics);
}

} // namespace WebCore
