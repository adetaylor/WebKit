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

#import "config.h"
#import "TextureView.h"

#import "APIConversions.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Texture.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPU::TextureViewImpl) == sizeof(void*) && alignof(WebGPU::TextureViewImpl) == alignof(void*));

WTF_MAKE_TZONE_ALLOCATED_IMPL(TextureView);

Ref<TextureView> TextureView::create(const WebGPU::TextureViewImpl& impl)
{
    return adoptRef(*new TextureView(impl));
}

Ref<TextureView> TextureView::createInvalid(Texture& texture, Device& device)
{
    return create(makeInvalidTextureViewImpl(&texture, texture.swiftImpl(), &device));
}

TextureView::TextureView(const WebGPU::TextureViewImpl& impl)
{
    new (m_impl) WebGPU::TextureViewImpl(impl);
}

TextureView::~TextureView()
{
    std::destroy_at(&swiftImpl());
}

WebGPU::TextureViewImpl& TextureView::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::TextureViewImpl*>(const_cast<std::byte*>(m_impl)));
}

Device& TextureView::device() const
{
    return borrowSwiftRetained(swiftImpl().shellDevice());
}

void TextureView::setLabel(String&& label)
{
    swiftImpl().setLabel(WTF::move(label));
}

id<MTLTexture> TextureView::parentTexture() const
{
    return swiftImpl().parentTexture();
}

uint32_t TextureView::width() const
{
    return swiftImpl().width();
}

uint32_t TextureView::height() const
{
    return swiftImpl().height();
}

uint32_t TextureView::depthOrArrayLayers() const
{
    return swiftImpl().depthOrArrayLayers();
}

uint32_t TextureView::sampleCount() const
{
    return swiftImpl().sampleCount();
}

WebGPU::TextureFormat TextureView::parentFormat() const
{
    return static_cast<WebGPU::TextureFormat>(swiftImpl().parentFormat());
}

uint32_t TextureView::parentMipLevelCount() const
{
    return swiftImpl().parentMipLevelCount();
}

uint32_t TextureView::parentRelativeMipLevel() const
{
    uint32_t level = swiftImpl().parentRelativeMipLevel();
    RELEASE_ASSERT(baseMipLevel() == level);
    return level;
}

uint32_t TextureView::parentRelativeSlice() const
{
    return swiftImpl().parentRelativeSlice();
}

OptionSet<WebGPU::TextureUsage> TextureView::usage() const
{
    return OptionSet<WebGPU::TextureUsage>::fromRaw(swiftImpl().usage());
}

id<MTLTexture> TextureView::texture() const
{
    return swiftImpl().texture();
}

id<MTLTexture> TextureView::sampledTexture() const
{
    return swiftImpl().sampledTexture();
}

bool TextureView::hasSwizzle() const
{
    return swiftImpl().hasSwizzle();
}

WebGPU::TextureFormat TextureView::format() const
{
    return static_cast<WebGPU::TextureFormat>(swiftImpl().format());
}

std::optional<WebGPU::TextureFormat> TextureView::optionalFormat() const
{
    if (!swiftImpl().hasDescriptor())
        return std::nullopt;
    return format();
}

uint32_t TextureView::mipLevelCount() const
{
    return swiftImpl().mipLevelCount();
}

uint32_t TextureView::baseMipLevel() const
{
    return swiftImpl().baseMipLevel();
}

WebGPU::TextureAspect TextureView::aspect() const
{
    return static_cast<WebGPU::TextureAspect>(swiftImpl().aspect());
}

uint32_t TextureView::arrayLayerCount() const
{
    return swiftImpl().arrayLayerCount();
}

uint32_t TextureView::baseArrayLayer() const
{
    return swiftImpl().baseArrayLayer();
}

WebGPU::TextureViewDimension TextureView::dimension() const
{
    return static_cast<WebGPU::TextureViewDimension>(swiftImpl().dimension());
}

std::optional<WebGPU::TextureViewDimension> TextureView::optionalDimension() const
{
    if (!swiftImpl().hasDescriptor())
        return std::nullopt;
    return dimension();
}

bool TextureView::is2DTexture() const
{
    return swiftImpl().is2DTexture();
}

bool TextureView::is2DArrayTexture() const
{
    return swiftImpl().is2DArrayTexture();
}

bool TextureView::is3DTexture() const
{
    return swiftImpl().is3DTexture();
}

bool TextureView::isDestroyed() const
{
    return swiftImpl().isDestroyed();
}

bool TextureView::isValid() const
{
    return swiftImpl().isValid();
}

void TextureView::setCommandEncoder(CommandEncoder& commandEncoder) const
{
    swiftImpl().setCommandEncoder(commandEncoder.swiftImpl());
}

const Texture& TextureView::apiParentTexture() const
{
    return borrowSwiftRetained(swiftImpl().apiParentTexture());
}

Texture& TextureView::apiParentTexture()
{
    return borrowSwiftRetained(swiftImpl().apiParentTexture());
}

id<MTLRasterizationRateMap> TextureView::rasterizationMapForSlice(uint32_t slice) const
{
    return swiftImpl().rasterizationMapForSlice(slice);
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuTextureViewAddRef(WGPUTextureView textureView)
{
    WebGPU::Metal::fromAPI(textureView).ref();
}

void wgpuTextureViewRelease(WGPUTextureView textureView)
{
    WebGPU::Metal::fromAPI(textureView).deref();
}

void wgpuTextureViewSetLabel(WGPUTextureView textureView, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(textureView))->setLabel(WebGPU::Metal::fromAPI(label));
}
