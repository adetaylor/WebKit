/*
 * Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

#import "config.h"
#import "ExternalTexture.h"

#import "APIConversions.h"
#import "Device.h"
#import "TextureView.h"
#import <wtf/CheckedArithmetic.h>
#import <wtf/MathExtras.h>
#import <wtf/RetainPtr.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct ExternalTextureImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(ExternalTextureImplBox);
    WebGPU::ExternalTextureImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ExternalTextureImplBox);

#pragma mark Device factory

RefPtr<WebGPU::ExternalTexture> Device::importExternalTexture(const WebGPU::ExternalTextureDescriptor& descriptor)
{
    if (!isValid())
        return ExternalTexture::createInvalid(*this);

    // The external texture keeps the C API color space, which the pixel buffer conversions take.
    return ExternalTexture::create(descriptor.pixelBuffer.get(), descriptor.colorSpace, descriptor.visibleSize, *this);
}

#pragma mark Shell

WTF_MAKE_TZONE_ALLOCATED_IMPL(ExternalTexture);

Ref<ExternalTexture> ExternalTexture::create(CVPixelBufferRef pixelBuffer, WebGPU::PredefinedColorSpace colorSpace, const WebGPU::Extent2D& visibleSize, Device& device)
{
    auto box = makeUnique<ExternalTextureImplBox>(ExternalTextureImplBox {
        .impl = makeExternalTextureImpl(colorSpace, visibleSize.width, visibleSize.height, &device, device.swiftImpl())
    });
    Ref externalTexture = adoptRef(*new ExternalTexture(WTF::move(box)));
    externalTexture->update(pixelBuffer);
    return externalTexture;
}

Ref<ExternalTexture> ExternalTexture::createInvalid(Device& device)
{
    auto box = makeUnique<ExternalTextureImplBox>(ExternalTextureImplBox { .impl = makeInvalidExternalTextureImpl(&device, device.swiftImpl()) });
    return adoptRef(*new ExternalTexture(WTF::move(box)));
}

ExternalTexture::ExternalTexture(std::unique_ptr<ExternalTextureImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

ExternalTexture::~ExternalTexture() = default;

WebGPU::ExternalTextureImpl& ExternalTexture::swiftImpl() const
{
    return m_impl->impl;
}

bool ExternalTexture::isValid() const
{
    return m_impl->impl.isValid();
}

void ExternalTexture::destroy()
{
    m_impl->impl.destroy();
}

void ExternalTexture::undestroy()
{
    m_impl->impl.undestroy();
}

void ExternalTexture::update(CVPixelBufferRef pixelBuffer)
{
    if (pixelBuffer)
        m_impl->impl.update(pixelBuffer);
    else
        m_impl->impl.updateWithoutPixelBuffer();
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuExternalTextureAddRef(WGPUExternalTexture externalTexture)
{
    WebGPU::Metal::fromAPI(externalTexture).ref();
}

void wgpuExternalTextureRelease(WGPUExternalTexture externalTexture)
{
    WebGPU::Metal::fromAPI(externalTexture).deref();
}

void wgpuExternalTextureDestroy(WGPUExternalTexture externalTexture)
{
    protect(WebGPU::Metal::fromAPI(externalTexture))->destroy();
}
