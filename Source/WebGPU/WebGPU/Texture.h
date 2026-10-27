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

#import "BindableResource.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/HashSet.h>
#import <wtf/Lock.h>
#import <wtf/Ref.h>
#import <wtf/Seconds.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakHashSet.h>
#import <wtf/TypeCasts.h>
#import <wtf/Vector.h>
#import <wtf/WeakHashSet.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class TextureImpl;
}
#endif

namespace WebGPU::Metal {

class CommandEncoder;
class Device;
class TextureView;

// A WebGPU::TextureDescriptor without its label and view formats, as Texture.swift reads it. The usage OptionSet
// travels as its raw bits.
struct TextureParameters {
    uint32_t width { 0 };
    uint32_t height { 0 };
    uint32_t depthOrArrayLayers { 0 };
    uint32_t mipLevelCount { 0 };
    uint32_t sampleCount { 0 };
    WebGPU::TextureDimension dimension { WebGPU::TextureDimension::_2d };
    WebGPU::TextureFormat format { WebGPU::TextureFormat::Rgba8unorm };
    uint8_t usage { 0 };
};

// A WebGPU::TextureViewDescriptor without its label, as Texture.swift reads it. Each std::nullopt member is a cleared
// has* flag, and the usage OptionSet travels as its raw bits.
struct TextureViewDescriptorParameters {
    WebGPU::TextureFormat format { WebGPU::TextureFormat::Rgba8unorm };
    bool hasFormat { false };
    WebGPU::TextureViewDimension dimension { WebGPU::TextureViewDimension::_2d };
    bool hasDimension { false };
    uint32_t baseMipLevel { 0 };
    uint32_t mipLevelCount { 0 };
    bool hasMipLevelCount { false };
    uint32_t baseArrayLayer { 0 };
    uint32_t arrayLayerCount { 0 };
    bool hasArrayLayerCount { false };
    WebGPU::TextureAspect aspect { WebGPU::TextureAspect::All };
    uint8_t usage { 0 };
    WebGPU::TextureComponentSwizzle swizzle;
};

// View formats borrowed for the duration of a call into Texture.swift, which reads them as a Span.
struct TextureFormatsView {
    std::span<const WebGPU::TextureFormat> formats;
    std::span<const WebGPU::TextureFormat> span() const LIFETIME_BOUND { return formats; }
} SWIFT_VIEW;

// https://gpuweb.github.io/gpuweb/#gputexture
// Swift owns the descriptor, the Metal texture, its state, the encoders that used it, its views, bind groups and
// render bundles, and the Device back-reference.
class Texture final : public WebGPU::Texture {
    WTF_MAKE_TZONE_ALLOCATED(Texture);
public:
    // The texture allows views in the given view formats, not in descriptor.viewFormats.
    static Ref<Texture> create(id<MTLTexture>, const WebGPU::TextureDescriptor&, Vector<WebGPU::TextureFormat>&& viewFormats, Device&);
    static Ref<Texture> createInvalid(Device&);
#if !defined(__swift__)
    // `makeImpl` returns the WebGPU::TextureImpl. Defined in Texture.mm.
    template<typename MakeImpl> static Ref<Texture> create(MakeImpl&&);
#endif

    ~Texture();

    // std::nullopt is a descriptor with all members at their defaults.
    RefPtr<WebGPU::TextureView> createView(const std::optional<WebGPU::TextureViewDescriptor>&) final;
    void destroy() final;
    void undestroy() final;
    void setLabel(String&&) final;

    bool LEGACY_NODELETE isValid() const final;

#if !defined(__swift__)
    WebGPU::TextureImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    // The format rules C++ uses; Swift calls the functions in TextureFormats.swift directly.
    static bool LEGACY_NODELETE isDepthOrStencilFormat(WebGPU::TextureFormat);
    // For Swift, which cannot get the TextureImpl of a WebGPU::TexelCopyTextureInfo's texture.
    static NSString* errorValidatingImageCopyTexture(const WebGPU::TexelCopyTextureInfo&, const WebGPU::Extent3D&);
    static NSString* errorValidatingTextureCopyRange(const WebGPU::TexelCopyTextureInfo&, const WebGPU::Extent3D&);

    WebGPU::Extent3D logicalMiplevelSpecificTextureExtent(uint32_t mipLevel);
    WebGPU::Extent3D physicalMiplevelSpecificTextureExtent(uint32_t mipLevel);

    id<MTLTexture> texture() const;
    // A texture bound directly, rather than through a view, has no swizzle to apply.
    id<MTLTexture> LEGACY_NODELETE sampledTexture() const;
    bool hasSwizzle() const { return false; }

    uint32_t LEGACY_NODELETE width() const;
    uint32_t LEGACY_NODELETE height() const;
    uint32_t LEGACY_NODELETE depthOrArrayLayers() const;
    uint32_t LEGACY_NODELETE mipLevelCount() const;
    uint32_t LEGACY_NODELETE sampleCount() const;
    WebGPU::TextureDimension LEGACY_NODELETE dimension() const;
    // Invalid textures may have no format. format() then reports an arbitrary one, which only the
    // validation that rejects the texture sees.
    WebGPU::TextureFormat LEGACY_NODELETE format() const;
    std::optional<WebGPU::TextureFormat> optionalFormat() const;
    OptionSet<WebGPU::TextureUsage> LEGACY_NODELETE usage() const;

    // Borrowed from the Impl, which holds the reference. Swift reads TextureImpl.device instead.
    Device& device() const;

    bool isDestroyed() const;

    void recreateIfNeeded();
    void LEGACY_NODELETE makeCanvasBacking();
    void setCommandEncoder(CommandEncoder&) const;
    bool isCanvasBacking() const;

    bool waitForCommandBufferCompletion();
    void recordGPUExecutionWindow(double startTime, double endTime) const;
    Seconds gpuFrameCost() const;
    void resetGPUFrameCost() const;
    void LEGACY_NODELETE updateCompletionEvent(const std::pair<id<MTLSharedEvent>, uint64_t>&);
    id<MTLSharedEvent> LEGACY_NODELETE sharedEvent() const;
    uint64_t LEGACY_NODELETE sharedEventSignalValue() const;
    void setRasterizationRateMaps(std::pair<id<MTLRasterizationRateMap>, id<MTLRasterizationRateMap>>&&);
    id<MTLRasterizationRateMap> rasterizationMapForSlice(uint32_t slice) const;
    uint32_t LEGACY_NODELETE arrayLayerCount() const;
    WebGPU::TextureAspect aspect() const { return WebGPU::TextureAspect::All; }
    uint32_t baseArrayLayer() const { return 0; }
    uint32_t baseMipLevel() const { return 0; }
    uint32_t parentRelativeSlice() const { return 0; }
    bool LEGACY_NODELETE is2DTexture() const;
    bool LEGACY_NODELETE is2DArrayTexture() const;
    bool LEGACY_NODELETE is3DTexture() const;
    id<MTLTexture> parentTexture() const;
    const Texture& apiParentTexture() const { return *this; }

private:
#if !defined(__swift__)
    template<typename MakeImpl> explicit Texture(MakeImpl&&);
#endif

    // The Swift object: one generated WebGPU::TextureImpl, a single strong reference. Texture.mm, where the generated
    // header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
} SWIFT_SHARED_REFERENCE(refTexture, derefTexture) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

} // namespace WebGPU::Metal

inline void refTexture(WebGPU::Metal::Texture* obj)
{
    obj->ref();
}

inline void derefTexture(WebGPU::Metal::Texture* obj)
{
    obj->deref();
}

SPECIALIZE_TYPE_TRAITS_BEGIN(WebGPU::Metal::Texture)
    static bool isType(const WGPUTextureImpl&) { return true; }
    static bool isType(const WebGPU::Texture&) { return true; }
SPECIALIZE_TYPE_TRAITS_END()
