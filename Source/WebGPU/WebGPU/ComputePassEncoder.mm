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
#import "ComputePassEncoder.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "Buffer.h"
#import "CommandEncoder.h"
#import "ComputePipeline.h"
#import "Device.h"
#import "PipelineLayout.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

// The Swift object, wrapped so ComputePassEncoder.h can forward-declare it without the generated header.
struct ComputePassEncoderImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(ComputePassEncoderImplBox);
    WebGPU::ComputePassEncoderImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ComputePassEncoderImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(ComputePassEncoder);

ComputePassEncoder::ComputePassEncoder(id<MTLComputeCommandEncoder> computeCommandEncoder, const WebGPU::ComputePassDescriptor&, CommandEncoder& parentEncoder, Device& device)
    : m_impl(makeUnique<ComputePassEncoderImplBox>(ComputePassEncoderImplBox { .impl = makeComputePassEncoderImpl(computeCommandEncoder, &parentEncoder, parentEncoder.swiftImpl(), &device) }))
{
}

ComputePassEncoder::ComputePassEncoder(CommandEncoder& parentEncoder, Device& device, NSString* errorString)
    : m_impl(makeUnique<ComputePassEncoderImplBox>(ComputePassEncoderImplBox { .impl = makeInvalidComputePassEncoderImpl(&parentEncoder, parentEncoder.swiftImpl(), &device, errorString) }))
{
}

ComputePassEncoder::~ComputePassEncoder()
{
    m_impl->impl.passWillBeDestroyed();
}

void ComputePassEncoder::dispatch(uint32_t x, uint32_t y, uint32_t z)
{
    m_impl->impl.dispatch(x, y, z);
}

void setComputeDynamicOffsets(id<MTLComputeCommandEncoder> computeCommandEncoder, std::span<const uint32_t> dynamicOffsets NOESCAPE, NSUInteger bufferIndex)
{
    [computeCommandEncoder setBytes:dynamicOffsets.data() length:dynamicOffsets.size_bytes() atIndex:bufferIndex];
}

void ComputePassEncoder::dispatchIndirect(const WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset)
{
    m_impl->impl.dispatchIndirect(downcast<Buffer>(indirectBuffer).swiftImpl(), indirectOffset);
}

void ComputePassEncoder::end()
{
    m_impl->impl.endPass();
}

void ComputePassEncoder::insertDebugMarker(String&& markerLabel)
{
    m_impl->impl.insertDebugMarker(markerLabel.createNSString().get());
}

void ComputePassEncoder::popDebugGroup()
{
    m_impl->impl.popDebugGroup();
}

void ComputePassEncoder::pushDebugGroup(String&& groupLabel)
{
    m_impl->impl.pushDebugGroup(groupLabel.createNSString().get());
}

void ComputePassEncoder::setBindGroup(uint32_t groupIndex, const WebGPU::BindGroup* apiGroup, std::optional<std::span<const uint32_t>> dynamicOffsets)
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

void ComputePassEncoder::setPipeline(const WebGPU::ComputePipeline& apiPipeline)
{
    auto& pipeline = downcast<ComputePipeline>(apiPipeline);
    auto& impl = m_impl->impl;
    // FIXME: rdar://138047285 const_cast is needed as a workaround.
    if (impl.setPipeline(pipeline.swiftImpl()))
        impl.storePipelineShell(&const_cast<ComputePipeline&>(pipeline));
}

void ComputePassEncoder::setLabel(String&& label)
{
    m_impl->impl.setLabel(label.createNSString().get());
}

bool ComputePassEncoder::isValid() const
{
    return m_impl->impl.isValid();
}

void ComputePassEncoder::markEncoderStateWasNotOpen()
{
    m_impl->impl.markEncoderStateWasNotOpen();
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuComputePassEncoderAddRef(WGPUComputePassEncoder computePassEncoder)
{
    WebGPU::Metal::fromAPI(computePassEncoder).ref();
}

void wgpuComputePassEncoderRelease(WGPUComputePassEncoder computePassEncoder)
{
    WebGPU::Metal::fromAPI(computePassEncoder).deref();
}

void wgpuComputePassEncoderDispatchWorkgroups(WGPUComputePassEncoder computePassEncoder, uint32_t x, uint32_t y, uint32_t z)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->dispatch(x, y, z);
}

void wgpuComputePassEncoderDispatchWorkgroupsIndirect(WGPUComputePassEncoder computePassEncoder, WGPUBuffer indirectBuffer, uint64_t indirectOffset)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->dispatchIndirect(protect(WebGPU::Metal::fromAPI(indirectBuffer)), indirectOffset);
}

void wgpuComputePassEncoderEnd(WGPUComputePassEncoder computePassEncoder)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->end();
}

void wgpuComputePassEncoderInsertDebugMarker(WGPUComputePassEncoder computePassEncoder, WGPUStringView markerLabel)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->insertDebugMarker(WebGPU::Metal::fromAPI(markerLabel));
}

void wgpuComputePassEncoderPopDebugGroup(WGPUComputePassEncoder computePassEncoder)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->popDebugGroup();
}

void wgpuComputePassEncoderPushDebugGroup(WGPUComputePassEncoder computePassEncoder, WGPUStringView groupLabel)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->pushDebugGroup(WebGPU::Metal::fromAPI(groupLabel));
}

// No dynamic offsets is std::nullopt.
void wgpuComputePassEncoderSetBindGroup(WGPUComputePassEncoder computePassEncoder, uint32_t groupIndex, WGPUBindGroup group, size_t dynamicOffsetCount, const uint32_t* dynamicOffsets)
{
    auto offsets = dynamicOffsetCount ? std::optional { unsafeMakeSpan(dynamicOffsets, dynamicOffsetCount) } : std::nullopt;
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->setBindGroup(groupIndex, group ? protect(WebGPU::Metal::fromAPI(group)).ptr() : nullptr, offsets);
}

void wgpuComputePassEncoderSetPipeline(WGPUComputePassEncoder computePassEncoder, WGPUComputePipeline pipeline)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->setPipeline(protect(WebGPU::Metal::fromAPI(pipeline)));
}

void wgpuComputePassEncoderSetLabel(WGPUComputePassEncoder computePassEncoder, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(computePassEncoder))->setLabel(WebGPU::Metal::fromAPI(label));
}
