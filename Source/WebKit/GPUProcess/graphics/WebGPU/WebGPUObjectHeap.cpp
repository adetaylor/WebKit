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

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "RemoteGPU.h"
#include "WebKit-Swift.h"
#include <wtf/TZoneMallocInlines.h>

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
    // A Swift receiver can outlive the heap, and keep the table.
    if (m_swiftImplTable)
        m_swiftImplTable->removeAll();
}

void ObjectHeap::createSwiftImplTable(RemoteGPU& gpu, ::WebGPU::InstanceDescriptor&& instanceDescriptor)
{
    ASSERT(!m_swiftImplTable);
    Ref descriptor = WebGPUSwiftInstanceDescriptor::create(WTF::move(instanceDescriptor));
    m_swiftImplTable = makeUniqueWithoutFastMallocCheck<WebGPUImplTable>(WebGPUImplTable::init(WebGPUSwiftRegistryHost { *this, gpu }, descriptor.ptr()));
}

WebGPUImplTable& ObjectHeap::swiftImplTable()
{
    RELEASE_ASSERT(m_swiftImplTable);
    return *m_swiftImplTable;
}

std::optional<RemoteGPURequestAdapterResponse> ObjectHeap::requestAdapter(const ::WebGPU::RequestAdapterOptions& options, WebGPUIdentifier identifier)
{
    RemoteGPURequestAdapterResponse response { };
    if (!swiftImplTable().requestAdapter(options, identifier.toUInt64(), response))
        return std::nullopt;
    return response;
}

void ObjectHeap::addCompositorIntegration(WebGPUIdentifier identifier)
{
    swiftImplTable().addCompositorIntegration(identifier.toUInt64());
}

bool ObjectHeap::addPresentationContext(WebGPUIdentifier identifier, WebGPUIdentifier compositorIntegration)
{
    return swiftImplTable().addPresentationContext(identifier.toUInt64(), compositorIntegration.toUInt64());
}

bool ObjectHeap::hasDevice(WebGPUIdentifier identifier)
{
    return m_swiftImplTable && m_swiftImplTable->hasDevice(identifier.toUInt64());
}

void ObjectHeap::destroyDevices()
{
    if (m_swiftImplTable)
        m_swiftImplTable->destroyDevices();
}

void ObjectHeap::removeObject(WebGPUIdentifier identifier)
{
    auto result = m_objects.remove(identifier);
    ASSERT_UNUSED(result, result);
}

void ObjectHeap::clear()
{
    m_objects.clear();
    if (m_swiftImplTable)
        m_swiftImplTable->removeAll();
}

RefPtr<::WebGPU::Adapter> ObjectHeap::convertAdapterFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns adapters, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::BindGroup> ObjectHeap::convertBindGroupFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns bind groups, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::BindGroupLayout> ObjectHeap::convertBindGroupLayoutFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns bind group layouts, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::Buffer> ObjectHeap::convertBufferFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns buffers, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::CommandBuffer> ObjectHeap::convertCommandBufferFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns command buffers, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::CommandEncoder> ObjectHeap::convertCommandEncoderFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns command encoders, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

WeakPtr<WebCore::WebGPUCompositorIntegration> ObjectHeap::convertCompositorIntegrationFromBacking(WebGPUIdentifier identifier)
{
    // A compositor integration has no WebCore backing: RemoteGPU links it to its canvas context.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::ComputePassEncoder> ObjectHeap::convertComputePassEncoderFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns compute pass encoders, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::ComputePipeline> ObjectHeap::convertComputePipelineFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns compute pipelines, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::Device> ObjectHeap::convertDeviceFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns devices, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

ThreadSafeWeakPtr<::WebGPU::ExternalTexture> ObjectHeap::convertExternalTextureFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns external textures, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::PipelineLayout> ObjectHeap::convertPipelineLayoutFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns pipeline layouts, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::PresentationContext> ObjectHeap::convertPresentationContextFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns canvas contexts, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::QuerySet> ObjectHeap::convertQuerySetFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns query sets, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::Queue> ObjectHeap::convertQueueFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns queues, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::RenderBundleEncoder> ObjectHeap::convertRenderBundleEncoderFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns render bundle encoders, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::RenderBundle> ObjectHeap::convertRenderBundleFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns render bundles, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::RenderPassEncoder> ObjectHeap::convertRenderPassEncoderFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns render pass encoders, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::RenderPipeline> ObjectHeap::convertRenderPipelineFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns render pipelines, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::Sampler> ObjectHeap::convertSamplerFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns samplers, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::ShaderModule> ObjectHeap::convertShaderModuleFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns shader modules, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::Texture> ObjectHeap::convertTextureFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns textures, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::TextureView> ObjectHeap::convertTextureViewFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns texture views, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::XRBinding> ObjectHeap::convertXRBindingFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns the WebXR objects, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::XRSubImage> ObjectHeap::convertXRSubImageFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns the WebXR objects, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::XRProjectionLayer> ObjectHeap::convertXRProjectionLayerFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns the WebXR objects, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

RefPtr<::WebGPU::XRView> ObjectHeap::createXRViewFromBacking(WebGPUIdentifier identifier)
{
    // Swift owns the WebXR objects, and no C++ receiver names one.
    UNUSED_PARAM(identifier);
    return nullptr;
}

ObjectHeap::ExistsAndValid ObjectHeap::objectExistsAndValid(WebGPUIdentifier identifier) const
{
    ExistsAndValid result;
    auto it = m_objects.find(identifier);
    if (it == m_objects.end()) {
        auto state = m_swiftImplTable ? m_swiftImplTable->objectState(identifier.toUInt64()) : WebGPUSwiftObjectState::Absent;
        result.exists = state != WebGPUSwiftObjectState::Absent;
        result.valid = state == WebGPUSwiftObjectState::Valid;
        return result;
    }

    // The objects of the C++ receivers are never invalid.
    result.exists = true;
    result.valid = !std::holds_alternative<std::monostate>(it->value);
    return result;
}

} // namespace WebKit::WebGPU

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
