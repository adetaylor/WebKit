/*
 * Copyright (c) 2024-2026 Apple Inc. All rights reserved.
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
#import "XRSubImage.h"

#import "APIConversions.h"
#import "Device.h"
#import "Texture.h"
#import "XRProjectionLayer.h"

#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct XRSubImageImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(XRSubImageImplBox);
    WebGPU::XRSubImageImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(XRSubImageImplBox);

Texture& createXRTexture(id<MTLTexture> texture, bool isDepthTexture, WebGPU::TextureFormat format, WebGPU::TextureFormat viewFormat, Device& device)
{
    Vector<WebGPU::TextureFormat> viewFormats { viewFormat };

    WebGPU::TextureDescriptor descriptor {
        .label = isDepthTexture ? "depth texture"_s : "color texture"_s,
        .usage = WebGPU::TextureUsage::RenderAttachment,
        .dimension = WebGPU::TextureDimension::_2d,
        .size = {
            .width = static_cast<uint32_t>(texture.width),
            .height = static_cast<uint32_t>(texture.height),
            .depthOrArrayLayers = static_cast<uint32_t>(texture.arrayLength),
        },
        .format = format,
        .mipLevelCount = 1,
        .sampleCount = static_cast<uint32_t>(texture.sampleCount),
        .viewFormats = singleElementSpan(format),
    };
    return Texture::create(texture, descriptor, WTF::move(viewFormats), device).leakRef();
}

void updateXRTextureCompletionEvent(Texture& texture, id<MTLSharedEvent> event, uint64_t signalValue)
{
    texture.updateCompletionEvent(std::make_pair(event, signalValue));
}

void setXRTextureRasterizationRateMaps(Texture& texture, id<MTLRasterizationRateMap> left, id<MTLRasterizationRateMap> right)
{
    texture.setRasterizationRateMaps(std::make_pair(left, right));
}

Ref<XRSubImage> XRSubImage::create(Device& device)
{
    auto box = makeUnique<XRSubImageImplBox>(XRSubImageImplBox { .impl = makeXRSubImageImpl() });
    return adoptRef(*new XRSubImage(WTF::move(box), device));
}

XRSubImage::XRSubImage(std::unique_ptr<XRSubImageImplBox>&& impl, Device& device)
    : m_impl(WTF::move(impl))
    , m_device(device)
{
}

XRSubImage::~XRSubImage() = default;

void XRSubImage::setLabel(String&&)
{
}

bool XRSubImage::isValid() const
{
    return true;
}

void XRSubImage::update(const XRProjectionLayer& projectionLayer)
{
    RefPtr device = m_device;
    if (!device)
        return;

    m_impl->impl.update(device.get(), projectionLayer.swiftImpl());
}

RefPtr<WebGPU::Texture> XRSubImage::colorTexture()
{
    if (!m_impl->impl.hasCurrentColorTexture())
        return nullptr;
    return adoptRef(m_impl->impl.currentColorTexture());
}

RefPtr<WebGPU::Texture> XRSubImage::depthStencilTexture()
{
    if (!m_impl->impl.hasCurrentDepthTexture())
        return nullptr;
    return adoptRef(m_impl->impl.currentDepthTexture());
}

Texture* XRSubImage::depthTexture()
{
    if (!m_impl->impl.hasCurrentDepthTexture())
        return nullptr;
    return &borrowSwiftRetained(m_impl->impl.currentDepthTexture());
}

RefPtr<XRSubImage> XRBinding::getViewSubImage(XRProjectionLayer& projectionLayer)
{
    return device().getXRViewSubImage(projectionLayer);
}

RefPtr<WebGPU::XRSubImage> XRBinding::getViewSubImage(WebGPU::XRProjectionLayer& projectionLayer)
{
    return getViewSubImage(downcast<XRProjectionLayer>(projectionLayer));
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs
