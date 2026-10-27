/*
 * Copyright (c) 2021-2022 Apple Inc. All rights reserved.
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

#import "BindableResource.h"
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/TypeCasts.h>
#import <wtf/WeakHashSet.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class TextureViewImpl;
}
#endif

namespace WebGPU::Metal {

class CommandEncoder;
class Device;
class Texture;

// https://gpuweb.github.io/gpuweb/#gputextureview
// Swift owns the Metal views, the resolved descriptor, the parent Texture and the encoders that used the view.
class TextureView final : public WebGPU::TextureView {
    WTF_MAKE_TZONE_ALLOCATED(TextureView);
public:
#if !defined(__swift__)
    // Texture::createView makes the TextureViewImpl.
    static Ref<TextureView> create(const WebGPU::TextureViewImpl&);
#endif
    static Ref<TextureView> createInvalid(Texture&, Device&);

    ~TextureView();

    void setLabel(String&&) final;

    bool LEGACY_NODELETE isValid() const final;

#if !defined(__swift__)
    WebGPU::TextureViewImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    id<MTLTexture> LEGACY_NODELETE texture() const;
    // The view as a shader reads it: the same texels seen through the swizzle the descriptor asked
    // for, which is the plain texture whenever that swizzle is the identity.
    id<MTLTexture> LEGACY_NODELETE sampledTexture() const;
    id<MTLTexture> LEGACY_NODELETE parentTexture() const;
    // True when the descriptor asked for a swizzle other than "rgba"; the base swizzle the format
    // imposes on top of that one does not count.
    bool hasSwizzle() const;

    // Borrowed from the Impl, which holds the reference.
    Device& device() const;
    uint32_t LEGACY_NODELETE width() const;
    uint32_t LEGACY_NODELETE height() const;
    uint32_t LEGACY_NODELETE depthOrArrayLayers() const;
    OptionSet<WebGPU::TextureUsage> LEGACY_NODELETE usage() const;
    uint32_t LEGACY_NODELETE sampleCount() const;
    WebGPU::TextureFormat LEGACY_NODELETE parentFormat() const;
    // Invalid views may have no format or dimension. format() and dimension() then report arbitrary
    // ones, which only the validation that rejects the view sees.
    WebGPU::TextureFormat LEGACY_NODELETE format() const;
    std::optional<WebGPU::TextureFormat> optionalFormat() const;
    uint32_t LEGACY_NODELETE parentMipLevelCount() const;
    uint32_t LEGACY_NODELETE mipLevelCount() const;
    uint32_t LEGACY_NODELETE baseMipLevel() const;
    WebGPU::TextureAspect LEGACY_NODELETE aspect() const;
    uint32_t LEGACY_NODELETE arrayLayerCount() const;
    uint32_t LEGACY_NODELETE baseArrayLayer() const;
    WebGPU::TextureViewDimension LEGACY_NODELETE dimension() const;
    std::optional<WebGPU::TextureViewDimension> optionalDimension() const;
    bool LEGACY_NODELETE isDestroyed() const;
    void setCommandEncoder(CommandEncoder&) const;
    const Texture& apiParentTexture() const;
    Texture& apiParentTexture();
    uint32_t parentRelativeSlice() const;
    uint32_t parentRelativeMipLevel() const;
    bool is2DTexture() const;
    bool is2DArrayTexture() const;
    bool is3DTexture() const;
    id<MTLRasterizationRateMap> LEGACY_NODELETE rasterizationMapForSlice(uint32_t slice) const;

private:
#if !defined(__swift__)
    explicit TextureView(const WebGPU::TextureViewImpl&);
#endif

    // The Swift object: one generated WebGPU::TextureViewImpl, a single strong reference. TextureView.mm, where the
    // generated header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
} SWIFT_SHARED_REFERENCE(refTextureView, derefTextureView) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

} // namespace WebGPU::Metal

inline void refTextureView(WebGPU::Metal::TextureView* obj)
{
    obj->ref();
}

inline void derefTextureView(WebGPU::Metal::TextureView* obj)
{
    obj->deref();
}

SPECIALIZE_TYPE_TRAITS_BEGIN(WebGPU::Metal::TextureView)
    static bool isType(const WGPUTextureViewImpl&) { return true; }
    static bool isType(const WebGPU::TextureView&) { return true; }
SPECIALIZE_TYPE_TRAITS_END()
