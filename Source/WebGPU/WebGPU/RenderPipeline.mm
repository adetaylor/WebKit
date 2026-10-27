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
#import "RenderPipeline.h"

#import "APIConversions.h"
#import "BindGroupLayout.h"
#import "Device.h"
#import "Pipeline.h"
#import "ShaderModule.h"
#import "Texture.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

// FIXME: remove after radar://104903411 or after we place the mask into the last buffer
@interface NSObject ()
- (void)setSampleMask:(NSUInteger)mask;
@end

namespace WebGPU::Metal {

struct RenderPipelineImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(RenderPipelineImplBox);
    WebGPU::RenderPipelineImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RenderPipelineImplBox);

void setRenderPipelineSampleMask(MTLRenderPipelineDescriptor *descriptor, uint32_t mask)
{
    [descriptor setSampleMask:mask];
}

// The creation is RenderPipelineBuilder (RenderPipeline.swift). This resolves what Swift cannot downcast: the shader
// modules and the layout (the replaced pipeline's or the descriptor's).
static WebGPU::RenderPipelineBuilder renderPipelineBuilder(Device& device, const WebGPU::RenderPipelineDescriptor& descriptor, const RenderPipeline* pipelineToReplace)
{
    Ref vertexModule = metal(descriptor.vertex.stage.module.get());
    auto builder = makeRenderPipelineBuilder(&device, device.swiftImpl(), vertexModule.ptr(), vertexModule->swiftImpl());
    if (descriptor.fragment) {
        Ref fragmentModule = metal(descriptor.fragment->stage.module.get());
        builder.setFragmentModule(fragmentModule.ptr(), fragmentModule->swiftImpl());
    }
    if (pipelineToReplace) {
        Ref pipelineLayout = pipelineToReplace->pipelineLayout();
        builder.setPipelineLayout(pipelineLayout.ptr(), pipelineLayout->swiftImpl(), true);
    } else if (descriptor.layout) {
        Ref pipelineLayout = metal(*descriptor.layout);
        builder.setPipelineLayout(pipelineLayout.ptr(), pipelineLayout->swiftImpl(), false);
    }
    return builder;
}

RefPtr<WebGPU::RenderPipeline> Device::createRenderPipeline(const WebGPU::RenderPipelineDescriptor& descriptor)
{
    return adoptRef(*renderPipelineBuilder(*this, descriptor, nullptr).create(descriptor));
}

void Device::createRenderPipelineAsync(const WebGPU::RenderPipelineDescriptor& descriptor, CompletionHandler<void(std::expected<Ref<WebGPU::RenderPipeline>, WebGPU::PipelineError>&&)>&& callback)
{
    renderPipelineBuilder(*this, descriptor, nullptr).createAsync(descriptor, callback);
}

void Device::createRenderPipelineWithPipelineLayoutFromPipelineAsync(const WebGPU::RenderPipelineDescriptor& descriptor, const WebGPU::RenderPipeline& pipelineToReplace, CompletionHandler<void(std::expected<Ref<WebGPU::RenderPipeline>, WebGPU::PipelineError>&&)>&& callback)
{
    renderPipelineBuilder(*this, descriptor, &downcast<RenderPipeline>(pipelineToReplace)).createAsync(descriptor, callback);
}

void callCreateRenderPipelineAsyncCallback(CreateRenderPipelineAsyncCallback& callback, RenderPipeline& pipeline, bool succeeded, NSString *errorMessage)
{
    if (succeeded)
        return callback(Ref<WebGPU::RenderPipeline> { pipeline });
    callback(makeUnexpected(WebGPU::PipelineError { .reason = WebGPU::PipelineErrorReason::Validation, .message = String { errorMessage } }));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderPipeline);

Ref<RenderPipeline> RenderPipeline::create(std::unique_ptr<RenderPipelineImplBox>&& impl)
{
    return adoptRef(*new RenderPipeline(WTF::move(impl)));
}

Ref<RenderPipeline> RenderPipeline::createInvalid(Device& device)
{
    Ref invalidPipelineLayout = PipelineLayout::createInvalid(device);
    return create(makeUnique<RenderPipelineImplBox>(RenderPipelineImplBox {
        .impl = makeInvalidRenderPipelineImpl(&device, device.swiftImpl(), invalidPipelineLayout.ptr(), invalidPipelineLayout->swiftImpl())
    }));
}

Ref<RenderPipeline> RenderPipeline::createWithStagedImpl(Device& device)
{
    return create(makeUnique<RenderPipelineImplBox>(RenderPipelineImplBox { .impl = device.swiftImpl().takeStagedRenderPipelineImpl() }));
}

RenderPipeline::RenderPipeline(std::unique_ptr<RenderPipelineImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

RenderPipeline::~RenderPipeline() = default;

bool RenderPipeline::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPU::RenderPipelineImpl& RenderPipeline::swiftImpl() const
{
    return m_impl->impl;
}

PipelineLayout& RenderPipeline::pipelineLayout() const
{
    return borrowSwiftRetained(m_impl->impl.pipelineLayout());
}

Ref<WebGPU::BindGroupLayout> RenderPipeline::getBindGroupLayout(uint32_t groupIndex)
{
    return adoptRef(*m_impl->impl.getBindGroupLayout(groupIndex));
}

void RenderPipeline::setLabel(String&&)
{
    // MTLRenderPipelineState's labels are read-only.
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuRenderPipelineAddRef(WGPURenderPipeline renderPipeline)
{
    WebGPU::Metal::fromAPI(renderPipeline).ref();
}

void wgpuRenderPipelineRelease(WGPURenderPipeline renderPipeline)
{
    WebGPU::Metal::fromAPI(renderPipeline).deref();
}

WGPUBindGroupLayout wgpuRenderPipelineGetBindGroupLayout(WGPURenderPipeline renderPipeline, uint32_t groupIndex)
{
    // Every WebGPU::BindGroupLayout that a WebGPU::Metal::RenderPipeline returns is a WebGPU::Metal::BindGroupLayout.
    Ref bindGroupLayout = downcast<WebGPU::Metal::BindGroupLayout>(protect(WebGPU::Metal::fromAPI(renderPipeline))->getBindGroupLayout(groupIndex).get());
    return WebGPU::Metal::releaseToAPI(WTF::move(bindGroupLayout));
}

void wgpuRenderPipelineSetLabel(WGPURenderPipeline renderPipeline, WGPUStringView label)
{
    WebGPU::Metal::fromAPI(renderPipeline).setLabel(WebGPU::Metal::fromAPI(label));
}
