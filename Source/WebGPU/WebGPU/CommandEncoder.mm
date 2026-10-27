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
#import "CommandEncoder.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "Buffer.h"
#import "CommandBuffer.h"
#import "ComputePassEncoder.h"
#import "Device.h"
#import "QuerySet.h"
#import "RenderPassEncoder.h"
#import "Sampler.h"
#import "Texture.h"
#import "TextureOrTextureView.h"
#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif
#import <wtf/IndexedRange.h>
#import <wtf/TZoneMallocInlines.h>

namespace WebGPU::Metal {

// The Swift object, wrapped so CommandEncoder.h can forward-declare it without the generated header.
struct CommandEncoderImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(CommandEncoderImplBox);
    WebGPU::CommandEncoderImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(CommandEncoderImplBox);

RefPtr<WebGPU::CommandEncoder> Device::createCommandEncoder(const WebGPU::CommandEncoderDescriptor& descriptor)
{
    return adoptRef(*deviceCreateCommandEncoder(this, swiftImpl(), descriptor.label.createNSString().get()));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(CommandEncoder);

CommandEncoder::CommandEncoder(id<MTLCommandBuffer> commandBuffer, Device& device, uint64_t uniqueId)
    : m_impl(makeUnique<CommandEncoderImplBox>(CommandEncoderImplBox { .impl = makeCommandEncoderImpl(commandBuffer, &device, device.swiftImpl(), device.isShaderValidationEnabled(), uniqueId) }))
{
}

CommandEncoder::CommandEncoder(Device& device)
    : m_impl(makeUnique<CommandEncoderImplBox>(CommandEncoderImplBox { .impl = makeInvalidCommandEncoderImpl(&device, device.swiftImpl()) }))
{
}

CommandEncoder::~CommandEncoder()
{
    // Never passes the dying shell into Swift.
    m_impl->impl.encoderWillBeDestroyed();
}

bool CommandEncoder::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPU::CommandEncoderImpl& CommandEncoder::swiftImpl() const
{
    return m_impl->impl;
}

RefPtr<WebGPU::ComputePassEncoder> CommandEncoder::beginComputePass(const std::optional<WebGPU::ComputePassDescriptor>& descriptor)
{
    return m_impl->impl.beginComputePass(this, descriptor ? *descriptor : WebGPU::ComputePassDescriptor { });
}

RefPtr<WebGPU::RenderPassEncoder> CommandEncoder::beginRenderPass(const WebGPU::RenderPassDescriptor& descriptor)
{
    return m_impl->impl.beginRenderPass(this, descriptor);
}

void CommandEncoder::copyBufferToBuffer(const WebGPU::Buffer& source, uint64_t sourceOffset, WebGPU::Buffer& destination, uint64_t destinationOffset, uint64_t size)
{
    m_impl->impl.copyBufferToBuffer(downcast<Buffer>(source).swiftImpl(), sourceOffset, downcast<Buffer>(destination).swiftImpl(), destinationOffset, size);
}

void CommandEncoder::copyBufferToTexture(const WebGPU::TexelCopyBufferInfo& source, const WebGPU::TexelCopyTextureInfo& destination, const WebGPU::Extent3D& copySize)
{
    m_impl->impl.copyBufferToTexture(source, metal(source.buffer).swiftImpl(), destination, metal(destination.texture).swiftImpl(), copySize);
}

void CommandEncoder::copyTextureToBuffer(const WebGPU::TexelCopyTextureInfo& source, const WebGPU::TexelCopyBufferInfo& destination, const WebGPU::Extent3D& copySize)
{
    m_impl->impl.copyTextureToBuffer(source, metal(source.texture).swiftImpl(), destination, metal(destination.buffer).swiftImpl(), copySize);
}

void CommandEncoder::copyTextureToTexture(const WebGPU::TexelCopyTextureInfo& source, const WebGPU::TexelCopyTextureInfo& destination, const WebGPU::Extent3D& copySize)
{
    m_impl->impl.copyTextureToTexture(source, metal(source.texture).swiftImpl(), destination, metal(destination.texture).swiftImpl(), copySize);
}

void CommandEncoder::clearBuffer(WebGPU::Buffer& buffer, uint64_t offset, std::optional<uint64_t> size)
{
    // https://gpuweb.github.io/gpuweb/#dom-gpucommandencoder-clearbuffer
    // The Swift implementation takes UINT64_MAX for the rest of the buffer after the offset.
    m_impl->impl.clearBuffer(downcast<Buffer>(buffer).swiftImpl(), offset, size.value_or(std::numeric_limits<uint64_t>::max()));
}

RefPtr<WebGPU::CommandBuffer> CommandEncoder::finish(const WebGPU::CommandBufferDescriptor& descriptor)
{
    return m_impl->impl.finish(this, descriptor);
}

void CommandEncoder::insertDebugMarker(String&& markerLabel)
{
    m_impl->impl.insertDebugMarker(markerLabel.createNSString().get());
}

void CommandEncoder::popDebugGroup()
{
    m_impl->impl.popDebugGroup();
}

void CommandEncoder::pushDebugGroup(String&& groupLabel)
{
    m_impl->impl.pushDebugGroup(groupLabel.createNSString().get());
}

void CommandEncoder::resolveQuerySet(const WebGPU::QuerySet& querySet, uint32_t firstQuery, uint32_t queryCount, WebGPU::Buffer& destination, uint64_t destinationOffset)
{
    m_impl->impl.resolveQuerySet(downcast<QuerySet>(querySet).swiftImpl(), firstQuery, queryCount, downcast<Buffer>(destination).swiftImpl(), destinationOffset);
}

void CommandEncoder::writeTimestamp(WebGPU::QuerySet& querySet, uint32_t queryIndex)
{
    m_impl->impl.writeTimestamp(downcast<QuerySet>(querySet).swiftImpl(), queryIndex);
}

void CommandEncoder::setLabel(String&& label)
{
    m_impl->impl.setLabel(label.createNSString().get());
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuCommandEncoderAddRef(WGPUCommandEncoder commandEncoder)
{
    WebGPU::Metal::fromAPI(commandEncoder).ref();
}

void wgpuCommandEncoderRelease(WGPUCommandEncoder commandEncoder)
{
    WebGPU::Metal::fromAPI(commandEncoder).deref();
}

WGPUComputePassEncoder wgpuCommandEncoderBeginComputePass(WGPUCommandEncoder commandEncoder, const WGPUComputePassDescriptor* descriptor)
{
    Ref protectedCommandEncoder = WebGPU::Metal::fromAPI(commandEncoder);
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor);
    if (!apiDescriptor) {
        Ref device = adoptRef(*protectedCommandEncoder->swiftImpl().shellDevice());
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::ComputePassEncoder::createInvalid(protectedCommandEncoder, device, @"GPUComputePassDescriptor has timestamp writes without a query set"));
    }
    // Every WebGPU::ComputePassEncoder that a WebGPU::Metal::CommandEncoder creates is a WebGPU::Metal::ComputePassEncoder.
    Ref computePassEncoder = downcast<WebGPU::Metal::ComputePassEncoder>(*protectedCommandEncoder->beginComputePass(apiDescriptor));
    return WebGPU::Metal::releaseToAPI(WTF::move(computePassEncoder));
}

WGPURenderPassEncoder wgpuCommandEncoderBeginRenderPass(WGPUCommandEncoder commandEncoder, const WGPURenderPassDescriptor* descriptor)
{
    Ref protectedCommandEncoder = WebGPU::Metal::fromAPI(commandEncoder);
    WebGPU::Metal::RenderPassDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        Ref device = adoptRef(*protectedCommandEncoder->swiftImpl().shellDevice());
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::RenderPassEncoder::createInvalid(protectedCommandEncoder, device, @"GPURenderPassDescriptor has an invalid enum value, a depth stencil attachment without a view or timestamp writes without a query set"));
    }
    // Every WebGPU::RenderPassEncoder that a WebGPU::Metal::CommandEncoder creates is a WebGPU::Metal::RenderPassEncoder.
    Ref renderPassEncoder = downcast<WebGPU::Metal::RenderPassEncoder>(*protectedCommandEncoder->beginRenderPass(*apiDescriptor));
    return WebGPU::Metal::releaseToAPI(WTF::move(renderPassEncoder));
}

void wgpuCommandEncoderCopyBufferToBuffer(WGPUCommandEncoder commandEncoder, WGPUBuffer source, uint64_t sourceOffset, WGPUBuffer destination, uint64_t destinationOffset, uint64_t size)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->copyBufferToBuffer(protect(WebGPU::Metal::fromAPI(source)), sourceOffset, protect(WebGPU::Metal::fromAPI(destination)), destinationOffset, size);
}

// A copy whose source or destination does not convert invalidates the encoder, as a failed copy
// validation does.
static constexpr auto invalidTexelCopyMessage = @"GPUCommandEncoder copy has a null buffer or texture or an invalid aspect";

void wgpuCommandEncoderCopyBufferToTexture(WGPUCommandEncoder commandEncoder, const WGPUTexelCopyBufferInfo* source, const WGPUTexelCopyTextureInfo* destination, const WGPUExtent3D* copySize)
{
    Ref protectedCommandEncoder = WebGPU::Metal::fromAPI(commandEncoder);
    auto apiSource = WebGPU::Metal::fromAPI(*source);
    auto apiDestination = WebGPU::Metal::fromAPI(*destination);
    if (!apiSource || !apiDestination)
        return (void)protectedCommandEncoder->swiftImpl().makeInvalid(invalidTexelCopyMessage);
    protectedCommandEncoder->copyBufferToTexture(*apiSource, *apiDestination, WebGPU::Metal::fromAPI(*copySize));
}

void wgpuCommandEncoderCopyTextureToBuffer(WGPUCommandEncoder commandEncoder, const WGPUTexelCopyTextureInfo* source, const WGPUTexelCopyBufferInfo* destination, const WGPUExtent3D* copySize)
{
    Ref protectedCommandEncoder = WebGPU::Metal::fromAPI(commandEncoder);
    auto apiSource = WebGPU::Metal::fromAPI(*source);
    auto apiDestination = WebGPU::Metal::fromAPI(*destination);
    if (!apiSource || !apiDestination)
        return (void)protectedCommandEncoder->swiftImpl().makeInvalid(invalidTexelCopyMessage);
    protectedCommandEncoder->copyTextureToBuffer(*apiSource, *apiDestination, WebGPU::Metal::fromAPI(*copySize));
}

void wgpuCommandEncoderCopyTextureToTexture(WGPUCommandEncoder commandEncoder, const WGPUTexelCopyTextureInfo* source, const WGPUTexelCopyTextureInfo* destination, const WGPUExtent3D* copySize)
{
    Ref protectedCommandEncoder = WebGPU::Metal::fromAPI(commandEncoder);
    auto apiSource = WebGPU::Metal::fromAPI(*source);
    auto apiDestination = WebGPU::Metal::fromAPI(*destination);
    if (!apiSource || !apiDestination)
        return (void)protectedCommandEncoder->swiftImpl().makeInvalid(invalidTexelCopyMessage);
    protectedCommandEncoder->copyTextureToTexture(*apiSource, *apiDestination, WebGPU::Metal::fromAPI(*copySize));
}

void wgpuCommandEncoderClearBuffer(WGPUCommandEncoder commandEncoder, WGPUBuffer buffer, uint64_t offset, uint64_t size)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->clearBuffer(protect(WebGPU::Metal::fromAPI(buffer)), offset, size == WGPU_WHOLE_SIZE ? std::nullopt : std::optional { size });
}

WGPUCommandBuffer wgpuCommandEncoderFinish(WGPUCommandEncoder commandEncoder, const WGPUCommandBufferDescriptor* descriptor)
{
    // Every WebGPU::CommandBuffer that a WebGPU::Metal::CommandEncoder creates is a WebGPU::Metal::CommandBuffer.
    Ref commandBuffer = downcast<WebGPU::Metal::CommandBuffer>(*protect(WebGPU::Metal::fromAPI(commandEncoder))->finish({ .label = descriptor ? WebGPU::Metal::fromAPI(descriptor->label) : String() }));
    return WebGPU::Metal::releaseToAPI(WTF::move(commandBuffer));
}

void wgpuCommandEncoderInsertDebugMarker(WGPUCommandEncoder commandEncoder, WGPUStringView markerLabel)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->insertDebugMarker(WebGPU::Metal::fromAPI(markerLabel));
}

void wgpuCommandEncoderPopDebugGroup(WGPUCommandEncoder commandEncoder)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->popDebugGroup();
}

void wgpuCommandEncoderPushDebugGroup(WGPUCommandEncoder commandEncoder, WGPUStringView groupLabel)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->pushDebugGroup(WebGPU::Metal::fromAPI(groupLabel));
}

void wgpuCommandEncoderResolveQuerySet(WGPUCommandEncoder commandEncoder, WGPUQuerySet querySet, uint32_t firstQuery, uint32_t queryCount, WGPUBuffer destination, uint64_t destinationOffset)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->resolveQuerySet(protect(WebGPU::Metal::fromAPI(querySet)), firstQuery, queryCount, protect(WebGPU::Metal::fromAPI(destination)), destinationOffset);
}

void wgpuCommandEncoderWriteTimestamp(WGPUCommandEncoder commandEncoder, WGPUQuerySet querySet, uint32_t queryIndex)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->writeTimestamp(protect(WebGPU::Metal::fromAPI(querySet)), queryIndex);
}

void wgpuCommandEncoderSetLabel(WGPUCommandEncoder commandEncoder, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(commandEncoder))->setLabel(WebGPU::Metal::fromAPI(label));
}
