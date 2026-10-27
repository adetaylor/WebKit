/*
 * Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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
#import "BindGroup.h"

#import "APIConversions.h"
#import "BindGroupLayout.h"
#import "Buffer.h"
#import "Device.h"
#import "ExternalTexture.h"
#import "Sampler.h"
#import "Texture.h"
#import "TextureView.h"
#import <limits>
#import <simd/simd.h>
#import <wtf/HashSet.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPU::BindGroupImpl) == sizeof(void*) && alignof(WebGPU::BindGroupImpl) == alignof(void*));

void writeExternalTextureConstants(id<MTLArgumentEncoder> argumentEncoder, NSUInteger firstIndex, const ExternalTextureConstants& constants)
{
    auto index = firstIndex;
    auto& uv = constants.uvRemapping;
    if (auto* uvRemapAddress = static_cast<simd::float3x2*>([argumentEncoder constantDataAtIndex:index++]))
        *uvRemapAddress = simd::float3x2(simd::make_float2(uv[0], uv[1]), simd::make_float2(uv[2], uv[3]), simd::make_float2(uv[4], uv[5]));

    auto& csc = constants.colorSpaceConversion;
    if (auto* cscMatrixAddress = static_cast<simd::float4x3*>([argumentEncoder constantDataAtIndex:index++]))
        *cscMatrixAddress = simd::float4x3(simd::make_float3(csc[0], csc[1], csc[2]), simd::make_float3(csc[3], csc[4], csc[5]), simd::make_float3(csc[6], csc[7], csc[8]), simd::make_float3(csc[9], csc[10], csc[11]));

    auto& primaries = constants.primariesConversion;
    if (auto* primariesMatrixAddress = static_cast<simd::float3x3*>([argumentEncoder constantDataAtIndex:index++]))
        *primariesMatrixAddress = simd::float3x3(simd::make_float3(primaries[0], primaries[1], primaries[2]), simd::make_float3(primaries[3], primaries[4], primaries[5]), simd::make_float3(primaries[6], primaries[7], primaries[8]));

    if (auto* visibleSizeAddress = static_cast<simd::uint2*>([argumentEncoder constantDataAtIndex:index++]))
        *visibleSizeAddress = simd::uint2 { constants.visibleWidth, constants.visibleHeight };
}

void writeBufferLengthConstant(id<MTLArgumentEncoder> argumentEncoder, NSUInteger index, uint32_t length)
{
    if (auto* lengthAddress = static_cast<uint32_t*>([argumentEncoder constantDataAtIndex:index]))
        *lengthAddress = length;
}

void copyArgumentEncoderLabel(id<MTLArgumentEncoder> argumentEncoder, id<MTLBuffer> buffer)
{
    buffer.label = argumentEncoder.label;
}

size_t wtfHashSetOrderForOperations(std::span<const int64_t> operations NOESCAPE, std::span<uint32_t> keys NOESCAPE)
{
    HashSet<uint32_t, DefaultHash<uint32_t>, WTF::UnsignedWithZeroKeyHashTraits<uint32_t>> table;
    for (auto operation : operations) {
        if (operation == std::numeric_limits<int64_t>::min())
            table.clear();
        else if (operation >= 0)
            table.add(static_cast<uint32_t>(operation));
        else
            table.remove(static_cast<uint32_t>(-(operation + 1)));
    }
    size_t index = 0;
    for (auto key : table) {
        if (index < keys.size())
            keys[index] = key;
        ++index;
    }
    return index;
}

RefPtr<WebGPU::BindGroup> Device::createBindGroup(const WebGPU::BindGroupDescriptor& descriptor)
{
    Ref bindGroupLayout = metal(descriptor.layout.get());
    auto& deviceImpl = swiftImpl();
    beginBindGroup(deviceImpl);
    for (auto& entry : descriptor.entries) {
        if (auto* bufferBinding = std::get_if<WebGPU::BufferBinding>(&entry.resource)) {
            Ref buffer = metal(bufferBinding->buffer.get());
            appendBindGroupBuffer(deviceImpl, entry.binding, buffer.ptr(), buffer->swiftImpl(), bufferBinding->offset, bufferBinding->size.has_value(), bufferBinding->size.value_or(0));
        } else if (auto* samplerResource = std::get_if<Ref<WebGPU::Sampler>>(&entry.resource)) {
            Ref sampler = metal(samplerResource->get());
            appendBindGroupSampler(deviceImpl, entry.binding, sampler.ptr(), sampler->swiftImpl());
        } else if (auto* textureResource = std::get_if<Ref<WebGPU::Texture>>(&entry.resource)) {
            Ref texture = metal(textureResource->get());
            appendBindGroupTexture(deviceImpl, entry.binding, texture.ptr(), texture->swiftImpl());
        } else if (auto* textureViewResource = std::get_if<Ref<WebGPU::TextureView>>(&entry.resource)) {
            Ref textureView = metal(textureViewResource->get());
            appendBindGroupTextureView(deviceImpl, entry.binding, textureView.ptr(), textureView->swiftImpl());
        } else if (auto* externalTextureResource = std::get_if<Ref<WebGPU::ExternalTexture>>(&entry.resource)) {
            Ref externalTexture = metal(externalTextureResource->get());
            appendBindGroupExternalTexture(deviceImpl, entry.binding, externalTexture.ptr(), externalTexture->swiftImpl());
        }
    }
    return BindGroup::create([&] {
        return finishBindGroup(this, deviceImpl, bindGroupLayout.ptr(), bindGroupLayout->swiftImpl());
    });
}

#pragma mark Shell

template<typename MakeImpl>
Ref<BindGroup> BindGroup::create(MakeImpl&& makeImpl)
{
    return adoptRef(*new BindGroup(std::forward<MakeImpl>(makeImpl)));
}

Ref<BindGroup> BindGroup::createInvalid(Device& device)
{
    return create([&] {
        return makeInvalidBindGroupImpl(&device, device.swiftImpl());
    });
}

template<typename MakeImpl>
BindGroup::BindGroup(MakeImpl&& makeImpl)
{
    // Initialized from the prvalue directly: no copy, so no extra retain and release.
    new (m_impl) WebGPU::BindGroupImpl(makeImpl());
    swiftImpl().registerAsResourceHolder(this);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(BindGroup);

BindGroup::~BindGroup()
{
    std::destroy_at(&swiftImpl());
}

bool BindGroup::isValid() const
{
    return swiftImpl().isValid();
}

WebGPU::BindGroupImpl& BindGroup::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::BindGroupImpl*>(const_cast<std::byte*>(m_impl)));
}

Device& BindGroup::device() const
{
    return borrowSwiftRetained(swiftImpl().shellDevice());
}

void BindGroup::setLabel(String&& label)
{
    swiftImpl().setLabel(WTF::move(label));
}

void BindGroup::releaseDestroyedResources()
{
    swiftImpl().releaseDestroyedResources();
}

bool BindGroup::updateExternalTextures(WebGPU::ExternalTexture& apiExternalTexture)
{
    // Every WebGPU::ExternalTexture that reaches a WebGPU::Metal::BindGroup is a WebGPU::Metal::ExternalTexture.
    auto& externalTexture = downcast<ExternalTexture>(apiExternalTexture);
    return swiftImpl().updateExternalTextures(externalTexture.swiftImpl());
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuBindGroupAddRef(WGPUBindGroup bindGroup)
{
    WebGPU::Metal::fromAPI(bindGroup).ref();
}

void wgpuBindGroupRelease(WGPUBindGroup bindGroup)
{
    WebGPU::Metal::fromAPI(bindGroup).deref();
}

void wgpuBindGroupSetLabel(WGPUBindGroup bindGroup, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(bindGroup))->setLabel(WebGPU::Metal::fromAPI(label));
}
