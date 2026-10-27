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
#import "Texture.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "RenderBundle.h"
#import "TextureView.h"
#import <wtf/CheckedArithmetic.h>
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

static_assert(sizeof(WebGPU::TextureImpl) == sizeof(void*) && alignof(WebGPU::TextureImpl) == alignof(void*));

WTF_MAKE_TZONE_ALLOCATED_IMPL(Texture);

static TextureParameters textureParameters(const WebGPU::TextureDescriptor& descriptor)
{
    return {
        .width = descriptor.size.width,
        .height = descriptor.size.height,
        .depthOrArrayLayers = descriptor.size.depthOrArrayLayers,
        .mipLevelCount = descriptor.mipLevelCount,
        .sampleCount = descriptor.sampleCount,
        .dimension = descriptor.dimension,
        .format = descriptor.format,
        .usage = descriptor.usage.toRaw(),
    };
}

static TextureViewDescriptorParameters textureViewDescriptorParameters(const WebGPU::TextureViewDescriptor& descriptor)
{
    return {
        .format = descriptor.format.value_or(WebGPU::TextureFormat::Rgba8unorm),
        .hasFormat = descriptor.format.has_value(),
        .dimension = descriptor.dimension.value_or(WebGPU::TextureViewDimension::_2d),
        .hasDimension = descriptor.dimension.has_value(),
        .baseMipLevel = descriptor.baseMipLevel,
        .mipLevelCount = descriptor.mipLevelCount.value_or(0),
        .hasMipLevelCount = descriptor.mipLevelCount.has_value(),
        .baseArrayLayer = descriptor.baseArrayLayer,
        .arrayLayerCount = descriptor.arrayLayerCount.value_or(0),
        .hasArrayLayerCount = descriptor.arrayLayerCount.has_value(),
        .aspect = descriptor.aspect,
        .usage = descriptor.usage.toRaw(),
        .swizzle = descriptor.swizzle,
    };
}

// The format tables live in TextureFormats.swift. The static member functions below forward to them for C++ callers.

bool Texture::isDepthOrStencilFormat(WebGPU::TextureFormat format)
{
    return WebGPU::isDepthOrStencilFormat(format);
}

NSString *Device::errorValidatingTextureCreation(const WebGPU::TextureDescriptor& descriptor)
{
    return WebGPU::errorValidatingTextureCreationRaw(this, swiftImpl(), textureParameters(descriptor), TextureFormatsView { descriptor.viewFormats });
}

NSString* Texture::errorValidatingImageCopyTexture(const WebGPU::TexelCopyTextureInfo& imageCopyTexture, const WebGPU::Extent3D& copySize)
{
    return WebGPU::errorValidatingImageCopyTextureRaw(metal(imageCopyTexture.texture).swiftImpl(), imageCopyTexture.mipLevel, imageCopyTexture.origin, copySize);
}

NSString* Texture::errorValidatingTextureCopyRange(const WebGPU::TexelCopyTextureInfo& imageCopyTexture, const WebGPU::Extent3D& copySize)
{
    return WebGPU::errorValidatingTextureCopyRangeRaw(metal(imageCopyTexture.texture).swiftImpl(), imageCopyTexture.mipLevel, imageCopyTexture.origin, copySize);
}

// Swift records the valid textures in DeviceImpl, for destroy().
RefPtr<WebGPU::Texture> Device::createTexture(const WebGPU::TextureDescriptor& descriptor)
{
    return Texture::create([&] {
        return WebGPU::createTextureImpl(this, swiftImpl(), textureParameters(descriptor), TextureFormatsView { descriptor.viewFormats }, descriptor.label, hasUnifiedMemory(), supportsNonPrivateDepthStencilTextures(), supportsMemorylessTextures());
    });
}

Ref<Texture> Texture::create(id<MTLTexture> texture, const WebGPU::TextureDescriptor& descriptor, Vector<WebGPU::TextureFormat>&& viewFormats, Device& device)
{
    return create([&] {
        return makeTextureImpl(texture, textureParameters(descriptor), TextureFormatsView { viewFormats.span() }, &device, device.swiftImpl());
    });
}

template<typename MakeImpl>
Ref<Texture> Texture::create(MakeImpl&& makeImpl)
{
    Ref result = adoptRef(*new Texture(std::forward<MakeImpl>(makeImpl)));
    result->swiftImpl().setShell(result.ptr());
    return result;
}

Ref<Texture> Texture::createInvalid(Device& device)
{
    return create([&] {
        return makeInvalidTextureImpl(&device, device.swiftImpl());
    });
}

template<typename MakeImpl>
Texture::Texture(MakeImpl&& makeImpl)
{
    // Initialized from the prvalue directly: no copy, so no extra retain and release.
    new (m_impl) WebGPU::TextureImpl(makeImpl());
}

Texture::~Texture()
{
    std::destroy_at(&swiftImpl());
}

WebGPU::TextureImpl& Texture::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::TextureImpl*>(const_cast<std::byte*>(m_impl)));
}

Device& Texture::device() const
{
    return borrowSwiftRetained(swiftImpl().shellDevice());
}

uint32_t Texture::width() const
{
    return swiftImpl().width();
}

uint32_t Texture::height() const
{
    return swiftImpl().height();
}

uint32_t Texture::depthOrArrayLayers() const
{
    return swiftImpl().depthOrArrayLayers();
}

uint32_t Texture::mipLevelCount() const
{
    return swiftImpl().mipLevelCount();
}

uint32_t Texture::sampleCount() const
{
    return swiftImpl().sampleCount();
}

uint32_t Texture::arrayLayerCount() const
{
    return swiftImpl().arrayLayerCount();
}

WebGPU::TextureDimension Texture::dimension() const
{
    return static_cast<WebGPU::TextureDimension>(swiftImpl().dimension());
}

WebGPU::TextureFormat Texture::format() const
{
    return static_cast<WebGPU::TextureFormat>(swiftImpl().format());
}

std::optional<WebGPU::TextureFormat> Texture::optionalFormat() const
{
    if (!swiftImpl().hasFormat())
        return std::nullopt;
    return format();
}

OptionSet<WebGPU::TextureUsage> Texture::usage() const
{
    return OptionSet<WebGPU::TextureUsage>::fromRaw(swiftImpl().usage());
}

bool Texture::is2DTexture() const
{
    return swiftImpl().is2DTexture();
}

bool Texture::is2DArrayTexture() const
{
    return swiftImpl().is2DArrayTexture();
}

bool Texture::is3DTexture() const
{
    return swiftImpl().is3DTexture();
}

RefPtr<WebGPU::TextureView> Texture::createView(const std::optional<WebGPU::TextureViewDescriptor>& optionalDescriptor)
{
    const WebGPU::TextureViewDescriptor defaultDescriptor;
    const auto& descriptor = optionalDescriptor ? *optionalDescriptor : defaultDescriptor;
    auto impl = swiftImpl().createView(this, textureViewDescriptorParameters(descriptor), descriptor.label);
    return TextureView::create(impl);
}

void Texture::recreateIfNeeded()
{
    swiftImpl().recreateIfNeeded();
}

void Texture::makeCanvasBacking()
{
    swiftImpl().makeCanvasBacking();
}

bool Texture::isCanvasBacking() const
{
    return swiftImpl().isCanvasBacking();
}

bool Texture::isDestroyed() const
{
    return swiftImpl().isDestroyed();
}

id<MTLTexture> Texture::texture() const
{
    return swiftImpl().texture();
}

id<MTLTexture> Texture::sampledTexture() const
{
    return swiftImpl().texture();
}

id<MTLTexture> Texture::parentTexture() const
{
    return swiftImpl().texture();
}

bool Texture::waitForCommandBufferCompletion()
{
    return swiftImpl().waitForCommandBufferCompletion();
}

void Texture::recordGPUExecutionWindow(double startTime, double endTime) const
{
    swiftImpl().recordGPUExecutionWindow(startTime, endTime);
}

Seconds Texture::gpuFrameCost() const
{
    double seconds = swiftImpl().gpuFrameCostSeconds();
    return seconds > 0 ? Seconds { seconds } : 0_s;
}

void Texture::resetGPUFrameCost() const
{
    swiftImpl().resetGPUFrameCost();
}

void Texture::setCommandEncoder(CommandEncoder& commandEncoder) const
{
    swiftImpl().setCommandEncoder(commandEncoder.swiftImpl());
}

void Texture::undestroy()
{
    recreateIfNeeded();
}

void Texture::destroy()
{
    swiftImpl().destroyAndReleaseHolders();
}

void Texture::setLabel(String&& label)
{
    swiftImpl().setLabel(WTF::move(label));
}

WebGPU::Extent3D Texture::logicalMiplevelSpecificTextureExtent(uint32_t mipLevel)
{
    return {
        .width = swiftImpl().logicalMiplevelSpecificTextureWidth(mipLevel),
        .height = swiftImpl().logicalMiplevelSpecificTextureHeight(mipLevel),
        .depthOrArrayLayers = swiftImpl().logicalMiplevelSpecificTextureDepthOrArrayLayers(mipLevel),
    };
}

WebGPU::Extent3D Texture::physicalMiplevelSpecificTextureExtent(uint32_t mipLevel)
{
    return {
        .width = swiftImpl().physicalMiplevelSpecificTextureWidth(mipLevel),
        .height = swiftImpl().physicalMiplevelSpecificTextureHeight(mipLevel),
        .depthOrArrayLayers = swiftImpl().physicalMiplevelSpecificTextureDepthOrArrayLayers(mipLevel),
    };
}

bool Texture::isValid() const
{
    return swiftImpl().isValid();
}

id<MTLSharedEvent> Texture::sharedEvent() const
{
    return swiftImpl().sharedEvent();
}

uint64_t Texture::sharedEventSignalValue() const
{
    return swiftImpl().sharedEventSignalValue();
}

void Texture::updateCompletionEvent(const std::pair<id<MTLSharedEvent>, uint64_t>& completionEvent)
{
    swiftImpl().updateCompletionEvent(completionEvent.first, completionEvent.second);
}

void Texture::setRasterizationRateMaps(std::pair<id<MTLRasterizationRateMap>, id<MTLRasterizationRateMap>>&& rateMaps)
{
    swiftImpl().setRasterizationRateMaps(rateMaps.first, rateMaps.second);
}

id<MTLRasterizationRateMap> Texture::rasterizationMapForSlice(uint32_t slice) const
{
    return swiftImpl().rasterizationMapForSlice(slice);
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuTextureAddRef(WGPUTexture texture)
{
    WebGPU::Metal::fromAPI(texture).ref();
}

void wgpuTextureRelease(WGPUTexture texture)
{
    WebGPU::Metal::fromAPI(texture).deref();
}

WGPUTextureView wgpuTextureCreateView(WGPUTexture texture, const WGPUTextureViewDescriptor* descriptor)
{
    Ref protectedTexture = WebGPU::Metal::fromAPI(texture);
    // A null descriptor is a descriptor with all members at their defaults.
    std::optional<WebGPU::TextureViewDescriptor> apiDescriptor;
    if (descriptor) {
        apiDescriptor = WebGPU::Metal::fromAPI(*descriptor);
        if (!apiDescriptor) {
            Ref device = protectedTexture->device();
            device->generateAValidationError("GPUTextureViewDescriptor has an invalid enum value or usage bit"_s);
            return WebGPU::Metal::releaseToAPI(WebGPU::Metal::TextureView::createInvalid(protectedTexture, device));
        }
    }
    // Every WebGPU::TextureView that a WebGPU::Metal::Texture creates is a WebGPU::Metal::TextureView.
    Ref view = downcast<WebGPU::Metal::TextureView>(*protectedTexture->createView(apiDescriptor));
    return WebGPU::Metal::releaseToAPI(WTF::move(view));
}

void wgpuTextureDestroy(WGPUTexture texture)
{
    protect(WebGPU::Metal::fromAPI(texture))->destroy();
}

void wgpuTextureSetLabel(WGPUTexture texture, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(texture))->setLabel(WebGPU::Metal::fromAPI(label));
}

uint32_t wgpuTextureGetDepthOrArrayLayers(WGPUTexture texture)
{
    return protect(WebGPU::Metal::fromAPI(texture))->depthOrArrayLayers();
}

WGPUTextureDimension wgpuTextureGetDimension(WGPUTexture texture)
{
    return WebGPU::Metal::toAPI(protect(WebGPU::Metal::fromAPI(texture))->dimension());
}

WGPUTextureFormat wgpuTextureGetFormat(WGPUTexture texture)
{
    auto format = protect(WebGPU::Metal::fromAPI(texture))->optionalFormat();
    return format ? WebGPU::Metal::toAPI(*format) : WGPUTextureFormat_Undefined;
}

uint32_t wgpuTextureGetHeight(WGPUTexture texture)
{
    return protect(WebGPU::Metal::fromAPI(texture))->height();
}

uint32_t wgpuTextureGetWidth(WGPUTexture texture)
{
    return protect(WebGPU::Metal::fromAPI(texture))->width();
}

uint32_t wgpuTextureGetMipLevelCount(WGPUTexture texture)
{
    return protect(WebGPU::Metal::fromAPI(texture))->mipLevelCount();
}

uint32_t wgpuTextureGetSampleCount(WGPUTexture texture)
{
    return protect(WebGPU::Metal::fromAPI(texture))->sampleCount();
}

WGPUTextureUsage wgpuTextureGetUsage(WGPUTexture texture)
{
    return WebGPU::Metal::toAPI(protect(WebGPU::Metal::fromAPI(texture))->usage());
}
