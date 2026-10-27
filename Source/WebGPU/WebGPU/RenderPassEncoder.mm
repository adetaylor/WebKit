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
#import "RenderPassEncoder.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "Buffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Queue.h"
#import "RenderBundle.h"
#import "RenderPipeline.h"
#import "Texture.h"
#import "TextureView.h"
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

// The Swift object, wrapped so RenderPassEncoder.h can forward-declare it without the generated header.
struct RenderPassEncoderImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(RenderPassEncoderImplBox);
    WebGPU::RenderPassEncoderImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RenderPassEncoderImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderPassEncoder);

template<typename OnTexture, typename OnView>
static void switchOnAttachmentView(const WebGPU::RenderPassAttachmentView& view, const OnTexture& onTexture, const OnView& onView)
{
    std::visit(WTF::makeVisitor([&](const Ref<WebGPU::TextureView>& textureView) {
        onView(downcast<TextureView>(textureView));
    }, [&](const Ref<WebGPU::Texture>& texture) {
        onTexture(downcast<Texture>(texture));
    }), view);
}

RenderPassEncoder::RenderPassEncoder(id<MTLRenderCommandEncoder> renderCommandEncoder, const WebGPU::RenderPassDescriptor& descriptor, NSUInteger visibilityResultBufferSize, bool depthReadOnly, bool stencilReadOnly, CommandEncoder& parentEncoder, id<MTLBuffer> visibilityResultBuffer, uint64_t maxDrawCount, Device& device, MTLRenderPassDescriptor* metalDescriptor)
    : m_impl(makeUnique<RenderPassEncoderImplBox>(RenderPassEncoderImplBox { .impl = makeRenderPassEncoderImpl(renderCommandEncoder,
        device.memoryBarrierLimit() > maxDrawCount ? nil : metalDescriptor, metalDescriptor.rasterizationRateMap, visibilityResultBuffer,
        RenderPassEncoderParameters { .visibilityResultBufferSize = visibilityResultBufferSize, .maxDrawCount = maxDrawCount, .depthReadOnly = depthReadOnly, .stencilReadOnly = stencilReadOnly },
        &parentEncoder, parentEncoder.swiftImpl(), &device) }))
{
    // In descriptor order: each color attachment, its resolve target, then the depth-stencil attachment.
    auto& impl = m_impl->impl;
    for (size_t i = 0; i < descriptor.colorAttachments.size(); ++i) {
        auto& attachment = descriptor.colorAttachments[i];
        if (!attachment) {
            impl.appendEmptyColorAttachment();
            continue;
        }
        switchOnAttachmentView(attachment->view, [&](Texture& texture) {
            impl.appendColorAttachmentTexture(&texture, texture.swiftImpl());
        }, [&](TextureView& view) {
            impl.appendColorAttachmentView(&view, view.swiftImpl());
        });
        if (attachment->resolveTarget) {
            switchOnAttachmentView(*attachment->resolveTarget, [&](Texture& texture) {
                impl.resolveColorAttachmentTexture(texture.swiftImpl());
            }, [&](TextureView& view) {
                impl.resolveColorAttachmentView(view.swiftImpl());
            });
        }
        impl.endColorAttachment(static_cast<uint32_t>(i), attachment->loadOp, attachment->storeOp, attachment->depthSlice.has_value(), attachment->depthSlice.value_or(0));
    }

    if (auto& attachment = descriptor.depthStencilAttachment) {
        RenderPassDepthStencilParameters parameters {
            .depthClearValue = attachment->depthClearValue,
            .stencilClearValue = attachment->stencilClearValue,
            .depthLoadOpIsLoad = attachment->depthLoadOp == WebGPU::LoadOp::Load,
            .depthStoreOpIsDiscard = attachment->depthStoreOp == WebGPU::StoreOp::Discard,
            .depthReadOnly = attachment->depthReadOnly,
            .stencilLoadOpIsLoad = attachment->stencilLoadOp == WebGPU::LoadOp::Load,
            .stencilStoreOpIsDiscard = attachment->stencilStoreOp == WebGPU::StoreOp::Discard,
            .stencilReadOnly = attachment->stencilReadOnly,
        };
        switchOnAttachmentView(attachment->view, [&](Texture& texture) {
            impl.setDepthStencilAttachmentTexture(&texture, texture.swiftImpl(), parameters);
        }, [&](TextureView& view) {
            impl.setDepthStencilAttachmentView(&view, view.swiftImpl(), parameters);
        });
    }
}

RenderPassEncoder::RenderPassEncoder(CommandEncoder& parentEncoder, Device& device, NSString* errorString)
    : m_impl(makeUnique<RenderPassEncoderImplBox>(RenderPassEncoderImplBox { .impl = makeInvalidRenderPassEncoderImpl(&parentEncoder, parentEncoder.swiftImpl(), &device, errorString) }))
{
}

RenderPassEncoder::~RenderPassEncoder()
{
    m_impl->impl.passWillBeDestroyed();
}

WebGPU::RenderPassEncoderImpl& RenderPassEncoder::swiftImpl() const
{
    return m_impl->impl;
}

void RenderPassEncoder::beginOcclusionQuery(uint32_t queryIndex)
{
    m_impl->impl.beginOcclusionQuery(queryIndex);
}

void RenderPassEncoder::endOcclusionQuery()
{
    m_impl->impl.endOcclusionQuery();
}

void RenderPassEncoder::draw(uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance)
{
    m_impl->impl.draw(vertexCount, instanceCount, firstVertex, firstInstance);
}

void RenderPassEncoder::drawIndexed(uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t baseVertex, uint32_t firstInstance)
{
    m_impl->impl.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
}

void RenderPassEncoder::drawIndexedIndirect(WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset)
{
    m_impl->impl.drawIndexedIndirect(downcast<Buffer>(indirectBuffer).swiftImpl(), indirectOffset);
}

void RenderPassEncoder::drawIndirect(WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset)
{
    m_impl->impl.drawIndirect(downcast<Buffer>(indirectBuffer).swiftImpl(), indirectOffset);
}

void RenderPassEncoder::end()
{
    m_impl->impl.endPass();
}

void RenderPassEncoder::executeBundles(std::span<const Ref<WebGPU::RenderBundle>> apiBundles)
{
    auto& impl = m_impl->impl;
    for (auto& apiBundle : apiBundles) {
        auto& bundle = metal(apiBundle.get());
        impl.appendPendingBundle(&bundle, bundle.swiftImpl());
    }
    impl.executeBundles();
}

void RenderPassEncoder::insertDebugMarker(String&& markerLabel)
{
    m_impl->impl.insertDebugMarker(markerLabel.createNSString().get());
}

void RenderPassEncoder::makeInvalid(NSString* errorString)
{
    m_impl->impl.invalidateFromCxx(errorString);
}

void RenderPassEncoder::popDebugGroup()
{
    m_impl->impl.popDebugGroup();
}

void RenderPassEncoder::pushDebugGroup(String&& groupLabel)
{
    m_impl->impl.pushDebugGroup(groupLabel.createNSString().get());
}

void RenderPassEncoder::setBindGroup(uint32_t groupIndex, const WebGPU::BindGroup* apiGroup, std::optional<std::span<const uint32_t>> dynamicOffsets)
{
    auto& impl = m_impl->impl;
    auto* group = downcast<BindGroup>(apiGroup);
    if (!group) {
        impl.clearBindGroup(groupIndex, dynamicOffsets.has_value(), dynamicOffsets ? dynamicOffsets->size() : 0);
        return;
    }
    // FIXME: rdar://138047285 const_cast is needed as a workaround.
    if (impl.setBindGroup(groupIndex, group->swiftImpl(), dynamicOffsets.has_value(), DynamicOffsetsView { dynamicOffsets.value_or(std::span<const uint32_t> { }) }))
        impl.storeBindGroupShell(groupIndex, const_cast<BindGroup*>(group));
}

void RenderPassEncoder::setBlendConstant(const WebGPU::Color& color)
{
    m_impl->impl.setBlendConstant(color);
}

void RenderPassEncoder::setIndexBuffer(WebGPU::Buffer& apiBuffer, WebGPU::IndexFormat format, uint64_t offset, std::optional<uint64_t> size)
{
    auto& buffer = downcast<Buffer>(apiBuffer);
    m_impl->impl.setIndexBuffer(&buffer, buffer.swiftImpl(), format, offset, size.has_value(), size.value_or(0));
}

void RenderPassEncoder::setPipeline(const WebGPU::RenderPipeline& apiPipeline)
{
    auto& pipeline = downcast<RenderPipeline>(apiPipeline);
    auto& impl = m_impl->impl;
    // FIXME: rdar://138047285 const_cast is needed as a workaround.
    if (impl.setPipeline(pipeline.swiftImpl()))
        impl.storePipelineShell(&const_cast<RenderPipeline&>(pipeline));
}

void RenderPassEncoder::setScissorRect(uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
    m_impl->impl.setScissorRect(x, y, width, height);
}

void RenderPassEncoder::setStencilReference(uint32_t reference)
{
    m_impl->impl.setStencilReference(reference);
}

void RenderPassEncoder::setVertexBuffer(uint32_t slot, WebGPU::Buffer* apiBuffer, uint64_t offset, std::optional<uint64_t> size)
{
    auto* buffer = downcast<Buffer>(apiBuffer);
    if (!buffer) {
        m_impl->impl.clearVertexBuffer(slot);
        return;
    }
    m_impl->impl.setVertexBuffer(slot, buffer->swiftImpl(), offset, size.has_value(), size.value_or(0));
}

void RenderPassEncoder::setViewport(float x, float y, float width, float height, float minDepth, float maxDepth)
{
    m_impl->impl.setViewport(x, y, width, height, minDepth, maxDepth);
}

void RenderPassEncoder::setLabel(String&& label)
{
    m_impl->impl.setLabel(label.createNSString().get());
}

bool RenderPassEncoder::isValid() const
{
    return m_impl->impl.isValid();
}

void RenderPassEncoder::markEncoderStateWasNotOpen()
{
    m_impl->impl.markEncoderStateWasNotOpen();
}

void RenderPassEncoder::deferRenderCommandEncoder(MTLRenderPassDescriptor* descriptor)
{
    m_impl->impl.deferRenderCommandEncoder(descriptor);
}

#pragma mark Primitives for RenderPassEncoder.swift

void setVertexUInt32s(id<MTLRenderCommandEncoder> commandEncoder, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex)
{
    auto bytes = asByteSpan(data);
    [commandEncoder setVertexBytes:bytes.data() length:bytes.size() atIndex:bufferIndex];
}

void setFragmentUInt32s(id<MTLRenderCommandEncoder> commandEncoder, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex)
{
    auto bytes = asByteSpan(data);
    [commandEncoder setFragmentBytes:bytes.data() length:bytes.size() atIndex:bufferIndex];
}

void setVertexUInt32Pair(id<MTLRenderCommandEncoder> commandEncoder, uint32_t first, uint32_t second, uint32_t bufferIndex)
{
    uint32_t data[] = { first, second };
    setVertexUInt32s(commandEncoder, std::span<const uint32_t> { data }, bufferIndex);
}

void setVertexUInt32Triple(id<MTLRenderCommandEncoder> commandEncoder, uint32_t first, uint32_t second, uint32_t third, uint32_t bufferIndex)
{
    uint32_t data[] = { first, second, third };
    setVertexUInt32s(commandEncoder, std::span<const uint32_t> { data }, bufferIndex);
}

void setVertexIndexData(id<MTLRenderCommandEncoder> commandEncoder, const IndexData& indexData, uint32_t bufferIndex)
{
    auto bytes = asByteSpan(indexData);
    [commandEncoder setVertexBytes:bytes.data() length:bytes.size() atIndex:bufferIndex];
}

template <typename T>
static T* LEGACY_NODELETE typedCast(auto& s)
{
    return static_cast<T*>(static_cast<void*>(&s));
}

// Vector does not initialize POD, hence zeroSpan; the inline capacity fits either argument struct.
static id<MTLBuffer> newZeroedIndirectScratch(Device& device, size_t size, uint64_t& offset)
{
    Vector<uint8_t, 32> zero(size);
    zeroSpan(zero.mutableSpan());
    auto [buffer, bufferOffset] = device.getQueue()->newTemporaryBufferWithBytes(zero.mutableSpan(), false);
    offset = bufferOffset;
    return buffer;
}

id<MTLBuffer> newZeroedDrawIndirectScratch(Device& device, uint64_t& offset)
{
    return newZeroedIndirectScratch(device, sizeof(WebKitMTLDrawPrimitivesIndirectArguments), offset);
}

id<MTLBuffer> newZeroedDrawIndexedIndirectScratch(Device& device, uint64_t& offset)
{
    return newZeroedIndirectScratch(device, sizeof(WebKitMTLDrawIndexedPrimitivesIndirectArguments), offset);
}

id<MTLBuffer> newDrawIndexedIndirectArgumentsBuffer(Device& device, uint32_t indexCount, uint32_t instanceCount, uint32_t indexStart, int32_t baseVertex, uint32_t baseInstance, uint64_t& offset)
{
    WebKitMTLDrawIndexedPrimitivesIndirectArguments indirectArguments {
        .args = MTLDrawIndexedPrimitivesIndirectArguments {
            .indexCount = indexCount,
            .instanceCount = instanceCount,
            .indexStart = indexStart,
            .baseVertex = baseVertex,
            .baseInstance = baseInstance
        },
        .lostOrOOBRead = 0u
    };
    auto [buffer, bufferOffset] = device.getQueue()->newTemporaryBufferWithBytes(unsafeMakeSpan(typedCast<uint8_t>(indirectArguments), sizeof(indirectArguments)), false);
    offset = bufferOffset;
    return buffer;
}

bool drawIndirectArgumentsLostOrOOBRead(id<MTLBuffer> buffer, uint64_t offset)
{
    auto checkedEnd = checkedSum<uint64_t>(offset, sizeof(WebKitMTLDrawPrimitivesIndirectArguments));
    if (!buffer.contents || checkedEnd.hasOverflowed() || checkedEnd.value() > buffer.length)
        return false;

    auto contents = unsafeMakeSpan(static_cast<const uint8_t*>(buffer.contents), buffer.length).subspan(offset);
    return reinterpretCastSpanStartTo<const WebKitMTLDrawPrimitivesIndirectArguments>(contents).lostOrOOBRead;
}

void logRenderPassSplit()
{
#ifndef NDEBUG
#if CPU(ARM64)
    WTFLogAlways("WebGPU: Splitting render pass on ARM64 - severe performance penalty"); // NOLINT
#endif
#endif
}

// The Metal thread only reads the command buffer's status and hops to the API thread. Each of these handlers hands
// every reference it holds over to its work item, on every path, so that they are released on the API thread.
void registerIndexValidationCompletion(CommandEncoder& parentEncoder, Device& parentDevice, Buffer& indexBuffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType indexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLBuffer> indexedIndirectBuffer, uint64_t indexedIndirectBufferOffset)
{
    Ref device = parentDevice;
    Ref queue = device->getQueue();
    auto encoderHandle = queue->retainCounterSampleBuffer(parentEncoder);
    [parentEncoder.swiftImpl().commandBuffer() addCompletedHandler:[encoderHandle, protectedDevice = WTF::move(device), queue = WTF::move(queue), firstIndex, indexCount, vertexCount, indexType, primitiveOffset, validationGeneration, refIndexBuffer = protect(indexBuffer), indexedIndirectBuffer, indexedIndirectBufferOffset](id<MTLCommandBuffer> completedCommandBuffer) mutable {
        bool completed = completedCommandBuffer.status == MTLCommandBufferStatusCompleted;
        Queue& hop = queue.get();
        hop.scheduleWork([completed, encoderHandle, protectedDevice = WTF::move(protectedDevice), queue = WTF::move(queue), firstIndex, indexCount, vertexCount, indexType, primitiveOffset, validationGeneration, refIndexBuffer = WTF::move(refIndexBuffer), indexedIndirectBuffer, indexedIndirectBufferOffset] mutable {
            queue->releaseCounterSampleBuffer(encoderHandle);
            if (!completed)
                return;
            auto checkedEnd = checkedSum<uint64_t>(indexedIndirectBufferOffset, sizeof(WebKitMTLDrawIndexedPrimitivesIndirectArguments));
            if (!indexedIndirectBuffer.contents || checkedEnd.hasOverflowed() || checkedEnd.value() > indexedIndirectBuffer.length)
                return;

            auto contents = unsafeMakeSpan(static_cast<const uint8_t*>(indexedIndirectBuffer.contents), indexedIndirectBuffer.length).subspan(indexedIndirectBufferOffset);
            auto& args = reinterpretCastSpanStartTo<const WebKitMTLDrawIndexedPrimitivesIndirectArguments>(contents);
            refIndexBuffer->didReadOOB(args.lostOrOOBRead);
            refIndexBuffer->drawIndexedValidated(firstIndex, indexCount, vertexCount, indexType, primitiveOffset, validationGeneration);
        });
    }];
}

// As registerIndexValidationCompletion, for the index validation of a render bundle's ICB.
void registerICBIndexValidationCompletion(CommandEncoder& parentEncoder, Device& parentDevice, Buffer& indexBuffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType indexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLIndirectCommandBuffer> indirectCommandBuffer, id<MTLBuffer> outOfBoundsReadFlag)
{
    Ref device = parentDevice;
    Ref queue = device->getQueue();
    auto encoderHandle = queue->retainCounterSampleBuffer(parentEncoder);
    [parentEncoder.swiftImpl().commandBuffer() addCompletedHandler:[encoderHandle, protectedDevice = WTF::move(device), queue = WTF::move(queue), firstIndex, indexCount, vertexCount, indexType, primitiveOffset, validationGeneration, refIndexBuffer = protect(indexBuffer), indirectCommandBuffer, outOfBoundsReadFlag](id<MTLCommandBuffer> completedCommandBuffer) mutable {
        bool completed = completedCommandBuffer.status == MTLCommandBufferStatusCompleted;
        Queue& hop = queue.get();
        hop.scheduleWork([completed, encoderHandle, protectedDevice = WTF::move(protectedDevice), queue = WTF::move(queue), indirectCommandBuffer, outOfBoundsReadFlag, firstIndex, indexCount, vertexCount, indexType, primitiveOffset, validationGeneration, refIndexBuffer = WTF::move(refIndexBuffer)] mutable {
            queue->releaseCounterSampleBuffer(encoderHandle);
            if (!completed)
                return;
            // Without the flag (its allocation failed), whether the clamp saw an out-of-bounds read is unknown: the draw
            // is not recorded as validated.
            if (!outOfBoundsReadFlag.contents || outOfBoundsReadFlag.length < sizeof(uint32_t))
                return;
            auto flag = unsafeMakeSpan(static_cast<const uint8_t*>(outOfBoundsReadFlag.contents), outOfBoundsReadFlag.length);
            refIndexBuffer->didReadOOB(reinterpretCastSpanStartTo<const uint32_t>(flag), indirectCommandBuffer);
            refIndexBuffer->drawIndexedValidated(firstIndex, indexCount, vertexCount, indexType, primitiveOffset, validationGeneration, indirectCommandBuffer);
        });
    }];
}

// One handler per pass checks the lostOrOOBRead flags of every clamping indirect draw. The block, which holds the
// Swift IndirectDeviceLostChecks, is retained on the Metal thread and runs, and is released, on the API thread.
void registerIndirectDeviceLostChecks(CommandEncoder& parentEncoder, Device& parentDevice, bool (^takeLostOrOOBRead)(void))
{
    Ref device = parentDevice;
    Ref queue = device->getQueue();
    auto encoderHandle = queue->retainCounterSampleBuffer(parentEncoder);
    [parentEncoder.swiftImpl().commandBuffer() addCompletedHandler:[encoderHandle, protectedDevice = WTF::move(device), queue = WTF::move(queue), takeLostOrOOBRead](id<MTLCommandBuffer> completedCommandBuffer) mutable {
        bool completed = completedCommandBuffer.status == MTLCommandBufferStatusCompleted;
        Queue& hop = queue.get();
        hop.scheduleWork([completed, encoderHandle, protectedDevice = WTF::move(protectedDevice), queue = WTF::move(queue), takeLostOrOOBRead = WTF::move(takeLostOrOOBRead)] mutable {
            queue->releaseCounterSampleBuffer(encoderHandle);
            if (!completed)
                return;
            if (takeLostOrOOBRead())
                protectedDevice->loseTheDevice(WebGPU::DeviceLostReason::Unknown);
        });
    }];
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuRenderPassEncoderAddRef(WGPURenderPassEncoder renderPassEncoder)
{
    WebGPU::Metal::fromAPI(renderPassEncoder).ref();
}

void wgpuRenderPassEncoderRelease(WGPURenderPassEncoder renderPassEncoder)
{
    WebGPU::Metal::fromAPI(renderPassEncoder).deref();
}

void wgpuRenderPassEncoderBeginOcclusionQuery(WGPURenderPassEncoder renderPassEncoder, uint32_t queryIndex)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->beginOcclusionQuery(queryIndex);
}

void wgpuRenderPassEncoderDraw(WGPURenderPassEncoder renderPassEncoder, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->draw(vertexCount, instanceCount, firstVertex, firstInstance);
}

void wgpuRenderPassEncoderDrawIndexed(WGPURenderPassEncoder renderPassEncoder, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t baseVertex, uint32_t firstInstance)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
}

void wgpuRenderPassEncoderDrawIndexedIndirect(WGPURenderPassEncoder renderPassEncoder, WGPUBuffer indirectBuffer, uint64_t indirectOffset)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->drawIndexedIndirect(protect(WebGPU::Metal::fromAPI(indirectBuffer)), indirectOffset);
}

void wgpuRenderPassEncoderDrawIndirect(WGPURenderPassEncoder renderPassEncoder, WGPUBuffer indirectBuffer, uint64_t indirectOffset)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->drawIndirect(protect(WebGPU::Metal::fromAPI(indirectBuffer)), indirectOffset);
}

void wgpuRenderPassEncoderEndOcclusionQuery(WGPURenderPassEncoder renderPassEncoder)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->endOcclusionQuery();
}

void wgpuRenderPassEncoderEnd(WGPURenderPassEncoder renderPassEncoder)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->end();
}

void wgpuRenderPassEncoderExecuteBundles(WGPURenderPassEncoder renderPassEncoder, size_t bundlesCount, const WGPURenderBundle* bundles)
{
    auto apiBundles = WTF::map(unsafeMakeSpan(bundles, bundlesCount), [](auto bundle) {
        return Ref { WebGPU::fromAPI(bundle) };
    });
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->executeBundles(apiBundles.span());
}

void wgpuRenderPassEncoderInsertDebugMarker(WGPURenderPassEncoder renderPassEncoder, WGPUStringView markerLabel)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->insertDebugMarker(WebGPU::Metal::fromAPI(markerLabel));
}

void wgpuRenderPassEncoderPopDebugGroup(WGPURenderPassEncoder renderPassEncoder)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->popDebugGroup();
}

void wgpuRenderPassEncoderPushDebugGroup(WGPURenderPassEncoder renderPassEncoder, WGPUStringView groupLabel)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->pushDebugGroup(WebGPU::Metal::fromAPI(groupLabel));
}

// No dynamic offsets is std::nullopt.
void wgpuRenderPassEncoderSetBindGroup(WGPURenderPassEncoder renderPassEncoder, uint32_t groupIndex, WGPUBindGroup group, size_t dynamicOffsetCount, const uint32_t* dynamicOffsets)
{
    auto offsets = dynamicOffsetCount ? std::optional { unsafeMakeSpan(dynamicOffsets, dynamicOffsetCount) } : std::nullopt;
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setBindGroup(groupIndex, group ? protect(WebGPU::Metal::fromAPI(group)).ptr() : nullptr, offsets);
}

void wgpuRenderPassEncoderSetBlendConstant(WGPURenderPassEncoder renderPassEncoder, const WGPUColor* color)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setBlendConstant(WebGPU::Metal::fromAPI(*color));
}

void wgpuRenderPassEncoderSetIndexBuffer(WGPURenderPassEncoder renderPassEncoder, WGPUBuffer buffer, WGPUIndexFormat format, uint64_t offset, uint64_t size)
{
    Ref protectedRenderPassEncoder = WebGPU::Metal::fromAPI(renderPassEncoder);
    auto apiFormat = WebGPU::Metal::fromAPI(format);
    if (!apiFormat)
        return protectedRenderPassEncoder->makeInvalid(@"setIndexBuffer: invalid index format");
    protectedRenderPassEncoder->setIndexBuffer(protect(WebGPU::Metal::fromAPI(buffer)), *apiFormat, offset, size == WGPU_WHOLE_SIZE ? std::nullopt : std::optional { size });
}

void wgpuRenderPassEncoderSetPipeline(WGPURenderPassEncoder renderPassEncoder, WGPURenderPipeline pipeline)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setPipeline(protect(WebGPU::Metal::fromAPI(pipeline)));
}

void wgpuRenderPassEncoderSetScissorRect(WGPURenderPassEncoder renderPassEncoder, uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setScissorRect(x, y, width, height);
}

void wgpuRenderPassEncoderSetStencilReference(WGPURenderPassEncoder renderPassEncoder, uint32_t reference)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setStencilReference(reference);
}

void wgpuRenderPassEncoderSetVertexBuffer(WGPURenderPassEncoder renderPassEncoder, uint32_t slot, WGPUBuffer buffer, uint64_t offset, uint64_t size)
{
    RefPtr<WebGPU::Metal::Buffer> optionalBuffer;
    if (buffer)
        optionalBuffer = protect(WebGPU::Metal::fromAPI(buffer)).ptr();
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setVertexBuffer(slot, optionalBuffer.get(), offset, size == WGPU_WHOLE_SIZE ? std::nullopt : std::optional { size });
}

void wgpuRenderPassEncoderSetViewport(WGPURenderPassEncoder renderPassEncoder, float x, float y, float width, float height, float minDepth, float maxDepth)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setViewport(x, y, width, height, minDepth, maxDepth);
}

void wgpuRenderPassEncoderSetLabel(WGPURenderPassEncoder renderPassEncoder, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(renderPassEncoder))->setLabel(WebGPU::Metal::fromAPI(label));
}
