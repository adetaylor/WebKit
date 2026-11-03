/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "WebGPUObjectHeap.h"

#if ENABLE(GPU_PROCESS)

#include "RemoteAdapter.h"
#include "RemoteBindGroup.h"
#include "RemoteBindGroupLayout.h"
#include "RemoteBuffer.h"
#include "RemoteCommandBuffer.h"
#include "RemoteCommandEncoder.h"
#include "RemoteCompositorIntegration.h"
#include "RemoteComputePassEncoder.h"
#include "RemoteComputePipeline.h"
#include "RemoteDevice.h"
#include "RemoteExternalTexture.h"
#include "RemoteGPU.h"
#include "RemotePipelineLayout.h"
#include "RemotePresentationContext.h"
#include "RemoteQuerySet.h"
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
#include "WebKit-Swift.h"
#endif
#include "RemoteQueue.h"
#include "RemoteRenderBundle.h"
#include "RemoteRenderBundleEncoder.h"
#include "RemoteRenderPassEncoder.h"
#include "RemoteRenderPipeline.h"
#include "RemoteSampler.h"
#include "RemoteShaderModule.h"
#include "RemoteTexture.h"
#include "RemoteTextureView.h"
#include "RemoteXRBinding.h"
#include "RemoteXRProjectionLayer.h"
#include "RemoteXRSubImage.h"
#include "RemoteXRView.h"
#include <wtf/TZoneMallocInlines.h>

#if HAVE(WEBGPU_IMPLEMENTATION)
#include <WebCore/WebGPU.h>
#endif

#include <WebCore/WebGPUCompositorIntegration.h>
#include <WebCore/WebGPUCppAPI.h>
#include <WebCore/WebGPUDevice.h>

namespace WebKit::WebGPU {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ObjectHeap);

ObjectHeap::ObjectHeap()
{
    weakPtrFactory().prepareForUseOnlyOnNonMainThread();
}

ObjectHeap::~ObjectHeap()
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // A Swift receiver can outlive the heap, and keep the table.
    if (m_swiftImplTable)
        m_swiftImplTable->removeAll();
#endif
}

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::createSwiftImplTable(RemoteGPU& gpu)
{
    ASSERT(!m_swiftImplTable);
    m_swiftImplTable = makeUniqueWithoutFastMallocCheck<WebGPUImplTable>(WebGPUImplTable::init(WebGPUSwiftRegistryHost { *this, gpu }));
}

WebGPUImplTable& ObjectHeap::swiftImplTable()
{
    RELEASE_ASSERT(m_swiftImplTable);
    return *m_swiftImplTable;
}

void ObjectHeap::trackDevice(::WebGPU::Device& device)
{
    m_devices.add(device);
}
#endif

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteAdapter& adapter)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteAdapter> { protect(adapter) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, BindGroupObject&& bindGroup)
{
    auto result = m_objects.add(identifier, Object { WTF::move(bindGroup) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteBindGroup& bindGroup)
{
    auto result = m_objects.add(identifier, Object { BindGroupObject { protect(bindGroup) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, BindGroupLayoutObject&& bindGroupLayout)
{
    auto result = m_objects.add(identifier, Object { WTF::move(bindGroupLayout) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteBindGroupLayout& bindGroupLayout)
{
    auto result = m_objects.add(identifier, Object { BindGroupLayoutObject { protect(bindGroupLayout) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, BufferObject&& buffer)
{
    auto result = m_objects.add(identifier, Object { WTF::move(buffer) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteBuffer& buffer)
{
    auto result = m_objects.add(identifier, Object { BufferObject { protect(buffer) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, CommandBufferObject&& commandBuffer)
{
    auto result = m_objects.add(identifier, Object { WTF::move(commandBuffer) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteCommandBuffer& commandBuffer)
{
    auto result = m_objects.add(identifier, Object { CommandBufferObject { protect(commandBuffer) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if !ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteCommandEncoder& commandEncoder)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteCommandEncoder> { protect(commandEncoder) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteCompositorIntegration& querySet)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteCompositorIntegration> { protect(querySet) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, ComputePassEncoderObject&& computePassEncoder)
{
    auto result = m_objects.add(identifier, Object { WTF::move(computePassEncoder) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteComputePassEncoder& computePassEncoder)
{
    auto result = m_objects.add(identifier, Object { ComputePassEncoderObject { protect(computePassEncoder) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, ComputePipelineObject&& computePipeline)
{
    auto result = m_objects.add(identifier, Object { WTF::move(computePipeline) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteComputePipeline& computePipeline)
{
    auto result = m_objects.add(identifier, Object { ComputePipelineObject { protect(computePipeline) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if !ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteDevice& device)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteDevice> { protect(device) } });
    ASSERT_UNUSED(result, result.isNewEntry);
    m_devices.add(device.backing());
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, ExternalTextureObject&& externalTexture)
{
    auto result = m_objects.add(identifier, Object { WTF::move(externalTexture) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteExternalTexture& externalTexture)
{
    auto result = m_objects.add(identifier, Object { ExternalTextureObject { protect(externalTexture) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, PipelineLayoutObject&& pipelineLayout)
{
    auto result = m_objects.add(identifier, Object { WTF::move(pipelineLayout) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemotePipelineLayout& pipelineLayout)
{
    auto result = m_objects.add(identifier, Object { PipelineLayoutObject { protect(pipelineLayout) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemotePresentationContext& presentationContext)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemotePresentationContext> { protect(presentationContext) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, QuerySetObject&& querySet)
{
    auto result = m_objects.add(identifier, Object { WTF::move(querySet) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteQuerySet& querySet)
{
    auto result = m_objects.add(identifier, Object { QuerySetObject { protect(querySet) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if !ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteQueue& queue)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteQueue> { protect(queue) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RenderBundleEncoderObject&& renderBundleEncoder)
{
    auto result = m_objects.add(identifier, Object { WTF::move(renderBundleEncoder) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteRenderBundleEncoder& renderBundleEncoder)
{
    auto result = m_objects.add(identifier, Object { RenderBundleEncoderObject { protect(renderBundleEncoder) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RenderBundleObject&& renderBundle)
{
    auto result = m_objects.add(identifier, Object { WTF::move(renderBundle) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteRenderBundle& renderBundle)
{
    auto result = m_objects.add(identifier, Object { RenderBundleObject { protect(renderBundle) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RenderPassEncoderObject&& renderPassEncoder)
{
    auto result = m_objects.add(identifier, Object { WTF::move(renderPassEncoder) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteRenderPassEncoder& renderPassEncoder)
{
    auto result = m_objects.add(identifier, Object { RenderPassEncoderObject { protect(renderPassEncoder) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RenderPipelineObject&& renderPipeline)
{
    auto result = m_objects.add(identifier, Object { WTF::move(renderPipeline) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteRenderPipeline& renderPipeline)
{
    auto result = m_objects.add(identifier, Object { RenderPipelineObject { protect(renderPipeline) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, SamplerObject&& sampler)
{
    auto result = m_objects.add(identifier, Object { WTF::move(sampler) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteSampler& sampler)
{
    auto result = m_objects.add(identifier, Object { SamplerObject { protect(sampler) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if !ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteShaderModule& shaderModule)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteShaderModule> { protect(shaderModule) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addTexture(WebGPUIdentifier identifier, ::WebGPU::Texture& texture)
{
    swiftImplTable().addTexture(RemoteTextureBacking { texture }, identifier.toUInt64());
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteTexture& texture)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteTexture> { protect(texture) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
void ObjectHeap::addObject(WebGPUIdentifier identifier, TextureViewObject&& textureView)
{
    auto result = m_objects.add(identifier, Object { WTF::move(textureView) });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#else
void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteTextureView& textureView)
{
    auto result = m_objects.add(identifier, Object { TextureViewObject { protect(textureView) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}
#endif

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteXRBinding& xrBinding)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteXRBinding> { protect(xrBinding) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteXRSubImage& xrSubImage)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteXRSubImage> { protect(xrSubImage) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteXRProjectionLayer& layer)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteXRProjectionLayer> { protect(layer) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

void ObjectHeap::addObject(WebGPUIdentifier identifier, RemoteXRView& view)
{
    auto result = m_objects.add(identifier, Object { IPC::ScopedActiveMessageReceiveQueue<RemoteXRView> { protect(view) } });
    ASSERT_UNUSED(result, result.isNewEntry);
}

void ObjectHeap::removeObject(WebGPUIdentifier identifier)
{
    auto result = m_objects.remove(identifier);
    ASSERT_UNUSED(result, result);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    if (m_swiftImplTable)
        m_swiftImplTable->remove(identifier.toUInt64());
#endif
}

void ObjectHeap::clear()
{
    m_objects.clear();
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    if (m_swiftImplTable)
        m_swiftImplTable->removeAll();
#endif
}

Vector<Ref<::WebGPU::Device>> ObjectHeap::devices() const
{
    return m_devices.values();
}

RefPtr<::WebGPU::Adapter> ObjectHeap::convertAdapterFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteAdapter>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteAdapter>>(iterator->value)->backing();
}

RefPtr<::WebGPU::BindGroup> ObjectHeap::convertBindGroupFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<BindGroupObject>(iterator->value))
        return nullptr;
    return &std::get<BindGroupObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::BindGroupLayout> ObjectHeap::convertBindGroupLayoutFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<BindGroupLayoutObject>(iterator->value))
        return nullptr;
    return &std::get<BindGroupLayoutObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::Buffer> ObjectHeap::convertBufferFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns buffers.
    if (!m_swiftImplTable)
        return nullptr;
    auto buffer = m_swiftImplTable->buffer(identifier.toUInt64());
    return buffer ? &buffer->get() : nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<BufferObject>(iterator->value))
        return nullptr;
    return &std::get<BufferObject>(iterator->value)->backing();
#endif
}

RefPtr<::WebGPU::CommandBuffer> ObjectHeap::convertCommandBufferFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<CommandBufferObject>(iterator->value))
        return nullptr;
    return &std::get<CommandBufferObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::CommandEncoder> ObjectHeap::convertCommandEncoderFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns command encoders, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteCommandEncoder>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteCommandEncoder>>(iterator->value)->backing();
#endif
}

WeakPtr<WebCore::WebGPUCompositorIntegration> ObjectHeap::convertCompositorIntegrationFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteCompositorIntegration>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteCompositorIntegration>>(iterator->value)->backing();
}

RefPtr<::WebGPU::ComputePassEncoder> ObjectHeap::convertComputePassEncoderFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<ComputePassEncoderObject>(iterator->value))
        return nullptr;
    return &std::get<ComputePassEncoderObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::ComputePipeline> ObjectHeap::convertComputePipelineFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<ComputePipelineObject>(iterator->value))
        return nullptr;
    return &std::get<ComputePipelineObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::Device> ObjectHeap::convertDeviceFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns devices.
    if (!m_swiftImplTable)
        return nullptr;
    auto device = m_swiftImplTable->device(identifier.toUInt64());
    return device ? &device->get() : nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteDevice>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteDevice>>(iterator->value)->backing();
#endif
}

ThreadSafeWeakPtr<::WebGPU::ExternalTexture> ObjectHeap::convertExternalTextureFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<ExternalTextureObject>(iterator->value))
        return nullptr;
    return &std::get<ExternalTextureObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::PipelineLayout> ObjectHeap::convertPipelineLayoutFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<PipelineLayoutObject>(iterator->value))
        return nullptr;
    return &std::get<PipelineLayoutObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::PresentationContext> ObjectHeap::convertPresentationContextFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemotePresentationContext>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemotePresentationContext>>(iterator->value)->backing();
}

RefPtr<::WebGPU::QuerySet> ObjectHeap::convertQuerySetFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns query sets.
    if (!m_swiftImplTable)
        return nullptr;
    auto querySet = m_swiftImplTable->querySet(identifier.toUInt64());
    return querySet ? &querySet->get() : nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<QuerySetObject>(iterator->value))
        return nullptr;
    return &std::get<QuerySetObject>(iterator->value)->backing();
#endif
}

RefPtr<::WebGPU::Queue> ObjectHeap::convertQueueFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns queues, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteQueue>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteQueue>>(iterator->value)->backing();
#endif
}

RefPtr<::WebGPU::RenderBundleEncoder> ObjectHeap::convertRenderBundleEncoderFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<RenderBundleEncoderObject>(iterator->value))
        return nullptr;
    return &std::get<RenderBundleEncoderObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::RenderBundle> ObjectHeap::convertRenderBundleFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<RenderBundleObject>(iterator->value))
        return nullptr;
    return &std::get<RenderBundleObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::RenderPassEncoder> ObjectHeap::convertRenderPassEncoderFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<RenderPassEncoderObject>(iterator->value))
        return nullptr;
    return &std::get<RenderPassEncoderObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::RenderPipeline> ObjectHeap::convertRenderPipelineFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<RenderPipelineObject>(iterator->value))
        return nullptr;
    return &std::get<RenderPipelineObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::Sampler> ObjectHeap::convertSamplerFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<SamplerObject>(iterator->value))
        return nullptr;
    return &std::get<SamplerObject>(iterator->value)->backing();
}

RefPtr<::WebGPU::ShaderModule> ObjectHeap::convertShaderModuleFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns shader modules, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteShaderModule>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteShaderModule>>(iterator->value)->backing();
#endif
}

RefPtr<::WebGPU::Texture> ObjectHeap::convertTextureFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns textures.
    if (!m_swiftImplTable)
        return nullptr;
    auto texture = m_swiftImplTable->texture(identifier.toUInt64());
    return texture ? &texture->get() : nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteTexture>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteTexture>>(iterator->value)->backing();
#endif
}

RefPtr<::WebGPU::TextureView> ObjectHeap::convertTextureViewFromBacking(WebGPUIdentifier identifier)
{
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    // Swift owns texture views.
    if (!m_swiftImplTable)
        return nullptr;
    auto textureView = m_swiftImplTable->textureView(identifier.toUInt64());
    return textureView ? &textureView->get() : nullptr;
#else
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<TextureViewObject>(iterator->value))
        return nullptr;
    return &std::get<TextureViewObject>(iterator->value)->backing();
#endif
}

RefPtr<::WebGPU::XRBinding> ObjectHeap::convertXRBindingFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteXRBinding>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteXRBinding>>(iterator->value)->backing();
}

RefPtr<::WebGPU::XRSubImage> ObjectHeap::convertXRSubImageFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteXRSubImage>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteXRSubImage>>(iterator->value)->backing();
}

RefPtr<::WebGPU::XRProjectionLayer> ObjectHeap::convertXRProjectionLayerFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteXRProjectionLayer>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteXRProjectionLayer>>(iterator->value)->backing();
}

RefPtr<::WebGPU::XRView> ObjectHeap::createXRViewFromBacking(WebGPUIdentifier identifier)
{
    auto iterator = m_objects.find(identifier);
    if (iterator == m_objects.end() || !std::holds_alternative<IPC::ScopedActiveMessageReceiveQueue<RemoteXRView>>(iterator->value))
        return nullptr;
    return &std::get<IPC::ScopedActiveMessageReceiveQueue<RemoteXRView>>(iterator->value)->backing();
}

ObjectHeap::ExistsAndValid ObjectHeap::objectExistsAndValid(const WebCore::WebGPUIntegration& gpu, WebGPUIdentifier identifier) const
{
    ExistsAndValid result;
#if HAVE(WEBGPU_IMPLEMENTATION)
    auto it = m_objects.find(identifier);
    if (it == m_objects.end()) {
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
        auto state = m_swiftImplTable ? m_swiftImplTable->objectState(identifier.toUInt64()) : WebGPUSwiftObjectState::Absent;
        result.exists = state != WebGPUSwiftObjectState::Absent;
        result.valid = state == WebGPUSwiftObjectState::Valid;
#endif
        return result;
    }

    result.exists = true;
    result.valid = WTF::switchOn(it->value, [&](std::monostate) -> bool {
        return false;
    },
    [&](auto& object) -> bool {
        return gpu.isValid(protect(object->backing()));
    });
#else
    UNUSED_PARAM(gpu);
    UNUSED_PARAM(identifier);
#endif
    return result;
}

} // namespace WebKit::WebGPU

#endif // HAVE(GPU_PROCESS)
