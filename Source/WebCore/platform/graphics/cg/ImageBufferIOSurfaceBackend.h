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

#pragma once

#if HAVE(IOSURFACE)

#include <WebCore/IOSurface.h>
#include <WebCore/IOSurfacePool.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/ImageBufferCGBackend.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class ImageBufferIOSurfaceDisplayDelegate;

class WEBCORE_EXPORT ImageBufferIOSurfaceBackend : public ImageBufferCGBackend {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(ImageBufferIOSurfaceBackend, WEBCORE_EXPORT);
    WTF_MAKE_NONCOPYABLE(ImageBufferIOSurfaceBackend);
public:
    static IntSize calculateSafeBackendSize(const ImageBufferParameters&);
    static unsigned calculateBytesPerRow(const IntSize& backendSize, PixelFormat);

    static std::unique_ptr<ImageBufferIOSurfaceBackend> create(const ImageBufferParameters&, const ImageBufferCreationContext&);

    ~ImageBufferIOSurfaceBackend();
    
    RenderingMode renderingMode() const override;
    size_t memoryCost() const override;
    bool canMapBackingStore() const final;

    IOSurface* surface() override;
    GraphicsContext& context() override;
    void flushContext() override;
    void submitDrawingCommands() override;

    RefPtr<GraphicsLayerContentsDisplayDelegate> layerContentsDisplayDelegate() override;
    void releaseLayerContentsDisplayDelegate() override;
    void prepareForDisplay() override;

protected:
    // The core is one over the surface.
    ImageBufferIOSurfaceBackend(const ImageBufferParameters&, std::unique_ptr<IOSurface>, ImageBufferSurface&&);
    // Returns true if flush happened.
    bool flushContextDraws();

    RefPtr<NativeImage> copyNativeImage() override;
    RefPtr<NativeImage> createNativeImageReference() override;
    RefPtr<NativeImage> sinkIntoNativeImage() override;

    void getPixelBuffer(const IntRect&, PixelBuffer&) override;
    void putPixelBuffer(const PixelBufferSourceView&, const IntRect& srcRect, const IntPoint& destPoint, AlphaPremultiplication destFormat) override;

    bool isInUse() const override;
    void releaseGraphicsContext() override;

    bool setVolatile() final;
    SetNonVolatileResult setNonVolatile() final;
    VolatilityState volatilityState() const final;
    void setVolatilityState(VolatilityState) final;

    void ensureNativeImagesHaveCopiedBackingStore() final;

    void transferToNewContext(const ImageBufferCreationContext&) final;

    unsigned bytesPerRow() const override;

    void prepareForExternalRead();
    void prepareForExternalWrite();
    bool consumeContextHasDrawn();

    std::unique_ptr<IOSurface> m_surface;
    RefPtr<ImageBufferIOSurfaceDisplayDelegate> m_layerContentsDisplayDelegate;
};

} // namespace WebCore

#endif // HAVE(IOSURFACE)
