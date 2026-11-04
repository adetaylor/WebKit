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
    WebGPUSwift::CommandEncoderImpl impl;
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

WebGPUSwift::CommandEncoderImpl& CommandEncoder::swiftImpl() const
{
    return m_impl->impl;
}

RefPtr<WebGPU::ComputePassEncoder> CommandEncoder::beginComputePass(const std::optional<WebGPU::ComputePassDescriptor>& descriptor)
{
    if (descriptor && descriptor->timestampWrites) {
        Ref querySet = metal(descriptor->timestampWrites->querySet);
        m_impl->impl.stageTimestampWritesQuerySet(querySet->swiftImpl());
    }
    return ComputePassEncoder::create(m_impl->impl.beginComputePass(this, descriptor ? *descriptor : WebGPU::ComputePassDescriptor { }));
}

RefPtr<WebGPU::RenderPassEncoder> CommandEncoder::beginRenderPass(const WebGPU::RenderPassDescriptor& descriptor)
{
    auto& impl = m_impl->impl;
    for (auto& attachment : descriptor.colorAttachments) {
        if (!attachment) {
            impl.stageEmptyColorAttachment();
            continue;
        }
        std::visit(WTF::makeVisitor([&](const Ref<WebGPU::TextureView>& view) {
            impl.stageColorAttachmentView(Ref { downcast<TextureView>(view.get()) }->swiftImpl());
        }, [&](const Ref<WebGPU::Texture>& texture) {
            impl.stageColorAttachmentTexture(Ref { downcast<Texture>(texture.get()) }->swiftImpl());
        }), attachment->view);
        if (attachment->resolveTarget) {
            std::visit(WTF::makeVisitor([&](const Ref<WebGPU::TextureView>& view) {
                impl.stageResolveTargetView(Ref { downcast<TextureView>(view.get()) }->swiftImpl());
            }, [&](const Ref<WebGPU::Texture>& texture) {
                impl.stageResolveTargetTexture(Ref { downcast<Texture>(texture.get()) }->swiftImpl());
            }), *attachment->resolveTarget);
        }
    }
    if (auto& attachment = descriptor.depthStencilAttachment) {
        std::visit(WTF::makeVisitor([&](const Ref<WebGPU::TextureView>& view) {
            impl.stageDepthStencilAttachmentView(Ref { downcast<TextureView>(view.get()) }->swiftImpl());
        }, [&](const Ref<WebGPU::Texture>& texture) {
            impl.stageDepthStencilAttachmentTexture(Ref { downcast<Texture>(texture.get()) }->swiftImpl());
        }), attachment->view);
    }
    if (RefPtr occlusionQuerySet = metalOrNull(descriptor.occlusionQuerySet))
        impl.stageOcclusionQuerySet(occlusionQuerySet->swiftImpl());
    if (descriptor.timestampWrites) {
        Ref querySet = metal(descriptor.timestampWrites->querySet);
        impl.stageTimestampWritesQuerySet(querySet->swiftImpl());
    }
    return RenderPassEncoder::create(impl.beginRenderPass(this, descriptor));
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
    return CommandBuffer::create(m_impl->impl.finish(this, descriptor));
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
