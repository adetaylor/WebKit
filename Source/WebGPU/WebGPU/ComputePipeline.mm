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
#import "ComputePipeline.h"

#import "APIConversions.h"
#import "BindGroupLayout.h"
#import "Device.h"
#import "Pipeline.h"
#import "PipelineLayout.h"
#import "ShaderModule.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPU::ComputePipelineImpl) == sizeof(void*) && alignof(WebGPU::ComputePipelineImpl) == alignof(void*));

// The creation is ComputePipelineBuilder (ComputePipeline.swift). This resolves what Swift cannot downcast: the shader
// module and the layout (the replaced pipeline's or the descriptor's).
static WebGPU::ComputePipelineBuilder computePipelineBuilder(Device& device, const WebGPU::ComputePipelineDescriptor& descriptor, const ComputePipeline* pipelineToReplace)
{
    Ref shaderModule = metal(descriptor.compute.module.get());
    auto builder = makeComputePipelineBuilder(&device, device.swiftImpl(), shaderModule->swiftImpl());
    if (pipelineToReplace) {
        Ref pipelineLayout = pipelineToReplace->pipelineLayout();
        builder.setPipelineLayout(pipelineLayout.ptr(), pipelineLayout->swiftImpl(), true);
    } else if (descriptor.layout) {
        Ref pipelineLayout = metal(*descriptor.layout);
        builder.setPipelineLayout(pipelineLayout.ptr(), pipelineLayout->swiftImpl(), false);
    }
    return builder;
}

RefPtr<WebGPU::ComputePipeline> Device::createComputePipeline(const WebGPU::ComputePipelineDescriptor& descriptor)
{
    return adoptRef(*computePipelineBuilder(*this, descriptor, nullptr).create(descriptor));
}

void Device::createComputePipelineAsync(const WebGPU::ComputePipelineDescriptor& descriptor, CompletionHandler<void(std::expected<Ref<WebGPU::ComputePipeline>, WebGPU::PipelineError>&&)>&& callback)
{
    computePipelineBuilder(*this, descriptor, nullptr).createAsync(descriptor, callback);
}

void Device::createComputePipelineWithPipelineLayoutFromPipelineAsync(const WebGPU::ComputePipelineDescriptor& descriptor, const WebGPU::ComputePipeline& pipelineToReplace, CompletionHandler<void(std::expected<Ref<WebGPU::ComputePipeline>, WebGPU::PipelineError>&&)>&& callback)
{
    computePipelineBuilder(*this, descriptor, &downcast<ComputePipeline>(pipelineToReplace)).createAsync(descriptor, callback);
}

void callCreateComputePipelineAsyncCallback(CreateComputePipelineAsyncCallback& callback, ComputePipeline& pipeline, bool succeeded, NSString *errorMessage)
{
    if (succeeded)
        return callback(Ref<WebGPU::ComputePipeline> { pipeline });
    callback(makeUnexpected(WebGPU::PipelineError { .reason = WebGPU::PipelineErrorReason::Validation, .message = String { errorMessage } }));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(ComputePipeline);

#pragma mark Shell

template<typename MakeImpl>
Ref<ComputePipeline> ComputePipeline::create(MakeImpl&& makeImpl)
{
    return adoptRef(*new ComputePipeline(std::forward<MakeImpl>(makeImpl)));
}

Ref<ComputePipeline> ComputePipeline::createWithStagedImpl(Device& device)
{
    return create([&] {
        return device.swiftImpl().takeStagedComputePipelineImpl();
    });
}

Ref<ComputePipeline> ComputePipeline::createInvalid(Device& device)
{
    // An invalid pipeline still holds an invalid PipelineLayout, so pipelineLayout() never returns null.
    Ref invalidPipelineLayout = PipelineLayout::createInvalid(device);
    return create([&] {
        return makeInvalidComputePipelineImpl(&device, device.swiftImpl(), invalidPipelineLayout.ptr(), invalidPipelineLayout->swiftImpl());
    });
}

template<typename MakeImpl>
ComputePipeline::ComputePipeline(MakeImpl&& makeImpl)
{
    // Initialized from the prvalue directly: no copy, so no extra retain and release.
    new (m_impl) WebGPU::ComputePipelineImpl(makeImpl());
}

ComputePipeline::~ComputePipeline()
{
    std::destroy_at(&swiftImpl());
}

bool ComputePipeline::isValid() const
{
    return swiftImpl().isValid();
}

WebGPU::ComputePipelineImpl& ComputePipeline::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::ComputePipelineImpl*>(const_cast<std::byte*>(m_impl)));
}

PipelineLayout& ComputePipeline::pipelineLayout() const
{
    return borrowSwiftRetained(swiftImpl().pipelineLayout());
}

Ref<WebGPU::BindGroupLayout> ComputePipeline::getBindGroupLayout(uint32_t groupIndex)
{
    return adoptRef(*swiftImpl().getBindGroupLayout(groupIndex));
}

void ComputePipeline::setLabel(String&&)
{
    // MTLComputePipelineState's labels are read-only.
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuComputePipelineAddRef(WGPUComputePipeline computePipeline)
{
    WebGPU::Metal::fromAPI(computePipeline).ref();
}

void wgpuComputePipelineRelease(WGPUComputePipeline computePipeline)
{
    WebGPU::Metal::fromAPI(computePipeline).deref();
}

WGPUBindGroupLayout wgpuComputePipelineGetBindGroupLayout(WGPUComputePipeline computePipeline, uint32_t groupIndex)
{
    // Every WebGPU::BindGroupLayout that a WebGPU::Metal::ComputePipeline returns is a WebGPU::Metal::BindGroupLayout.
    Ref bindGroupLayout = downcast<WebGPU::Metal::BindGroupLayout>(protect(WebGPU::Metal::fromAPI(computePipeline))->getBindGroupLayout(groupIndex).get());
    return WebGPU::Metal::releaseToAPI(WTF::move(bindGroupLayout));
}

void wgpuComputePipelineSetLabel(WGPUComputePipeline computePipeline, WGPUStringView label)
{
    WebGPU::Metal::fromAPI(computePipeline).setLabel(WebGPU::Metal::fromAPI(label));
}
