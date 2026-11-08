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

#pragma once

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "RemoteGPURequestAdapterResponse.h"
#include "ScopedActiveMessageReceiveQueue.h"
#include "WebGPUConvertFromBackingContext.h"
#include "WebGPUIdentifier.h"
#include "WebGPUSwiftSupport.h"
#include <WebCore/WebGPUCppAPI.h>
#include <WebCore/WebGPUDevice.h>
#include <functional>
#include <wtf/HashMap.h>
#include <wtf/Ref.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {
class WebGPUCompositorIntegration;
}

namespace WebKit {
class RemoteGPU;
}

namespace WebKit::WebGPU {


class SWIFT_PRIVATE_FILEID("WebKit/WebGPUSwiftSupport.swift") ObjectHeap final : public RefCountedAndCanMakeWeakPtr<ObjectHeap>, public WebGPU::ConvertFromBackingContext {
    WTF_MAKE_TZONE_ALLOCATED(ObjectHeap);
public:
    static Ref<ObjectHeap> create()
    {
        return adoptRef(*new ObjectHeap());
    }

    ~ObjectHeap();

    // The Swift registry, which owns the objects of the other kinds, makes adapters and canvas contexts for RemoteGPU.
    std::optional<RemoteGPURequestAdapterResponse> requestAdapter(const ::WebGPU::RequestAdapterOptions&, WebGPUIdentifier);
    void addCompositorIntegration(WebGPUIdentifier);
    // False if there's no compositor integration with that identifier.
    bool addPresentationContext(WebGPUIdentifier, WebGPUIdentifier compositorIntegration);

    bool hasDevice(WebGPUIdentifier);
    // Destroys the devices that are still alive, so that their pending callbacks are called.
    void destroyDevices();

    void removeObject(WebGPUIdentifier);

    void clear();

    RefPtr<::WebGPU::Adapter> convertAdapterFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::BindGroup> convertBindGroupFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::BindGroupLayout> convertBindGroupLayoutFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::Buffer> convertBufferFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::CommandBuffer> convertCommandBufferFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::CommandEncoder> convertCommandEncoderFromBacking(WebGPUIdentifier) final;
    WeakPtr<WebCore::WebGPUCompositorIntegration> convertCompositorIntegrationFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::ComputePassEncoder> convertComputePassEncoderFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::ComputePipeline> convertComputePipelineFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::Device> convertDeviceFromBacking(WebGPUIdentifier) final;
    ThreadSafeWeakPtr<::WebGPU::ExternalTexture> convertExternalTextureFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::PipelineLayout> convertPipelineLayoutFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::PresentationContext> convertPresentationContextFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::QuerySet> convertQuerySetFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::Queue> convertQueueFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::RenderBundleEncoder> convertRenderBundleEncoderFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::RenderBundle> convertRenderBundleFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::RenderPassEncoder> convertRenderPassEncoderFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::RenderPipeline> convertRenderPipelineFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::Sampler> convertSamplerFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::ShaderModule> convertShaderModuleFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::Texture> convertTextureFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::TextureView> convertTextureViewFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::XRBinding> convertXRBindingFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::XRSubImage> convertXRSubImageFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::XRProjectionLayer> convertXRProjectionLayerFromBacking(WebGPUIdentifier) final;
    RefPtr<::WebGPU::XRView> createXRViewFromBacking(WebGPUIdentifier) final;

    struct ExistsAndValid {
        bool exists { false };
        bool valid { false };
    };
    ExistsAndValid objectExistsAndValid(WebGPUIdentifier) const;

    // The Swift registry of the WebGPU objects whose messages Swift receives, which the heap empties when it's cleared,
    // with the instance that the descriptor describes.
    void createSwiftImplTable(RemoteGPU&, ::WebGPU::InstanceDescriptor&&);

    // For Swift, which can only name a specialization through an alias.
    using OptionalAdapterResponse = std::optional<RemoteGPURequestAdapterResponse>;

private:
    ObjectHeap();

    // Implemented in Swift, in WebGPUSwiftSupport.swift, on the registry that m_swiftState holds.
    static uintptr_t createSwiftState(WebGPUSwiftRegistryHost, WebGPUSwiftInstanceDescriptor* WTF_NONNULL);
    static void destroySwiftState(uintptr_t);
    OptionalAdapterResponse swiftRequestAdapter(::WebGPU::RequestAdapterOptions, uint64_t identifier);
    void swiftAddCompositorIntegration(uint64_t identifier);
    bool swiftAddPresentationContext(uint64_t identifier, uint64_t compositorIntegration);
    bool swiftHasDevice(uint64_t identifier) const;
    void swiftDestroyDevices();
    void swiftRemoveAll();
    WebGPUSwiftObjectState swiftObjectState(uint64_t identifier) const;

    using Object = Variant<
        std::monostate
    >;

    HashMap<WebGPUIdentifier, Object> m_objects;
    // A retained reference to the Swift registry, as an address, from createSwiftImplTable() to the destructor; 0 before.
    uintptr_t m_swiftState { 0 };
};

} // namespace WebKit::WebGPU

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
