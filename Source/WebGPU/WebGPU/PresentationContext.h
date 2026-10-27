/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/RetainPtr.h>
#import <wtf/Seconds.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/TypeCasts.h>



namespace WebGPU::Metal {

class Device;
class Instance;
class Texture;

class PresentationContext : public WebGPU::PresentationContext {
    WTF_MAKE_TZONE_ALLOCATED(PresentationContext);
public:
    static Ref<PresentationContext> create(const WebGPU::PresentationContextDescriptor&, const Instance&);

    virtual ~PresentationContext();

    void configure(const WebGPU::CanvasConfiguration&) override;
    void unconfigure() override;

    void present(uint32_t) override;
    // The texture is owned by the presentation context.
    virtual Texture* currentTexture(uint32_t);
    RefPtr<WebGPU::Texture> getCurrentTexture(uint32_t) final;

    Seconds lastFrameGPUCost() const override { return 0_s; }
    Seconds lastFramePresentStall() const override { return 0_s; }

    RetainPtr<CGImageRef> getTextureAsNativeImage(uint32_t, bool&) override { return nullptr; }

    void setLabel(String&&) override { }
    bool isValid() const override { return false; }
protected:
    explicit PresentationContext();
};

// For PresentationContextIOSurface.swift, which cannot build a WebGPU::TextureDescriptor, copy raw bytes, set the
// deprecated fastMathEnabled or call the variadic WTFLogAlways. Declared here because PresentationContextIOSurface.h is
// not a Swift module header; defined in PresentationContextIOSurface.mm.
NSString *errorValidatingCanvasTextureCreation(Device&, const WebGPU::CanvasConfiguration&, WebGPU::TextureFormat effectiveFormat, uint32_t width, uint32_t height);
// The texture's descriptor has the given format, and effectiveFormat as its only view format when the
// configuration lists none.
Ref<Texture> createCanvasTexture(id<MTLTexture>, const WebGPU::CanvasConfiguration&, WebGPU::TextureFormat, WebGPU::TextureFormat effectiveFormat, uint32_t width, uint32_t height, Device&);
// nil, logged, when Metal reports any error, including warnings alongside a library.
id<MTLLibrary> compileLibraryWithFastMath(id<MTLDevice>, NSString *source);
// nullptr when the bytes cannot be allocated.
CGImageRef createImageWithTextureBytes(id<MTLTexture>, size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow, CGColorSpaceRef, CGBitmapInfo) CF_RETURNS_RETAINED;

} // namespace WebGPU::Metal
