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
#import "RenderBundleEncoder.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "Buffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "PipelineLayout.h"
#import "RenderBundle.h"
#import "RenderPipeline.h"
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPUSwift::RenderBundleEncoderImpl) == sizeof(void*) && alignof(WebGPUSwift::RenderBundleEncoderImpl) == alignof(void*));

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderBundleEncoder);

RefPtr<WebGPU::RenderBundleEncoder> Device::createRenderBundleEncoder(const WebGPU::RenderBundleEncoderDescriptor& descriptor)
{
    return RenderBundleEncoder::create(descriptor, *this);
}

Ref<RenderBundleEncoder> RenderBundleEncoder::create(const WebGPU::RenderBundleEncoderDescriptor& descriptor, Device& device)
{
    return adoptRef(*new RenderBundleEncoder([&] {
        return createRenderBundleEncoderImpl(descriptor, &device, device.swiftImpl());
    }));
}

Ref<RenderBundleEncoder> RenderBundleEncoder::createWithStagedImpl(Device& device)
{
    return adoptRef(*new RenderBundleEncoder([&] {
        return device.swiftImpl().takeStagedRenderBundleEncoderImpl();
    }));
}

Ref<RenderBundleEncoder> RenderBundleEncoder::createInvalid(Device& device, NSString* errorString)
{
    return adoptRef(*new RenderBundleEncoder([&] {
        return makeInvalidRenderBundleEncoderImpl(&device, device.swiftImpl(), errorString);
    }));
}

template<typename MakeImpl>
RenderBundleEncoder::RenderBundleEncoder(MakeImpl&& makeImpl)
{
    // Initialized from the prvalue directly: no copy, so no extra retain and release.
    new (m_impl) WebGPUSwift::RenderBundleEncoderImpl(makeImpl());
}

WebGPUSwift::RenderBundleEncoderImpl& RenderBundleEncoder::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPUSwift::RenderBundleEncoderImpl*>(const_cast<std::byte*>(m_impl)));
}

void RenderBundleEncoder::makeInvalid(NSString* errorString)
{
    swiftImpl().makeInvalid(errorString);
}

RenderBundleEncoder::~RenderBundleEncoder()
{
    std::destroy_at(&swiftImpl());
}

void RenderBundleEncoder::draw(uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance)
{
    swiftImpl().draw(this, vertexCount, instanceCount, firstVertex, firstInstance);
}

void RenderBundleEncoder::drawIndexed(uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t baseVertex, uint32_t firstInstance)
{
    swiftImpl().drawIndexed(this, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
}

void RenderBundleEncoder::drawIndirect(WebGPU::Buffer& apiIndirectBuffer, uint64_t indirectOffset)
{
    auto& indirectBuffer = downcast<Buffer>(apiIndirectBuffer);
    swiftImpl().drawIndirect(this, &indirectBuffer, indirectBuffer.swiftImpl(), indirectOffset);
}

void RenderBundleEncoder::drawIndexedIndirect(WebGPU::Buffer& apiIndirectBuffer, uint64_t indirectOffset)
{
    auto& indirectBuffer = downcast<Buffer>(apiIndirectBuffer);
    swiftImpl().drawIndexedIndirect(this, &indirectBuffer, indirectBuffer.swiftImpl(), indirectOffset);
}

RefPtr<WebGPU::RenderBundle> RenderBundleEncoder::finish(const WebGPU::RenderBundleDescriptor& descriptor)
{
    return RenderBundle::create(swiftImpl().finish(this, descriptor.label.createNSString().get()));
}

bool RenderBundleEncoder::isValid() const
{
    return swiftImpl().isValid();
}

void RenderBundleEncoder::insertDebugMarker(String&&)
{
    swiftImpl().insertDebugMarker();
}

void RenderBundleEncoder::popDebugGroup()
{
    swiftImpl().popDebugGroup();
}

void RenderBundleEncoder::pushDebugGroup(String&&)
{
    swiftImpl().pushDebugGroup();
}

void RenderBundleEncoder::setBindGroup(uint32_t groupIndex, const WebGPU::BindGroup* apiGroup, std::optional<std::span<const uint32_t>> dynamicOffsets)
{
    auto* group = downcast<BindGroup>(apiGroup);
    DynamicOffsetsView offsets { dynamicOffsets.value_or(std::span<const uint32_t> { }) };
    if (!group) {
        swiftImpl().clearBindGroup(this, groupIndex, dynamicOffsets.has_value(), offsets);
        return;
    }
    swiftImpl().setBindGroup(this, groupIndex, group->swiftImpl(), dynamicOffsets.has_value(), offsets);
}

void RenderBundleEncoder::setIndexBuffer(WebGPU::Buffer& apiBuffer, WebGPU::IndexFormat format, uint64_t offset, std::optional<uint64_t> size)
{
    auto& buffer = downcast<Buffer>(apiBuffer);
    swiftImpl().setIndexBuffer(this, &buffer, buffer.swiftImpl(), format, offset, size.has_value(), size.value_or(0));
}

void RenderBundleEncoder::setPipeline(const WebGPU::RenderPipeline& apiPipeline)
{
    auto& pipeline = downcast<RenderPipeline>(apiPipeline);
    // FIXME: rdar://138047285 const_cast is needed as a workaround.
    swiftImpl().setPipeline(this, &const_cast<RenderPipeline&>(pipeline), pipeline.swiftImpl());
}

void RenderBundleEncoder::setVertexBuffer(uint32_t slot, WebGPU::Buffer* apiBuffer, uint64_t offset, std::optional<uint64_t> size)
{
    auto* buffer = downcast<Buffer>(apiBuffer);
    if (!buffer) {
        swiftImpl().clearVertexBuffer(this, slot, offset, size.has_value(), size.value_or(0));
        return;
    }
    swiftImpl().setVertexBuffer(this, slot, buffer, buffer->swiftImpl(), offset, size.has_value(), size.value_or(0));
}

void RenderBundleEncoder::setLabel(String&& label)
{
    swiftImpl().setLabel(label.createNSString().get());
}

template<typename T>
static std::span<T> makeSpanFromBuffer(id<MTLBuffer> buffer)
{
    auto bytes = cpuVisibleContents(buffer);
    if (bytes.size() < sizeof(T)) [[unlikely]]
        return { };

    return unsafeMakeSpan(static_cast<T*>(static_cast<void*>(bytes.data())), bytes.size() / sizeof(T));
}

void copyDynamicOffsetsToBuffer(id<MTLBuffer> buffer, std::span<const uint32_t> contents NOESCAPE)
{
    memcpySpan(makeSpanFromBuffer<uint32_t>(buffer), contents);
}

} // namespace WebGPU::Metal
