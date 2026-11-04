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
#if !defined(__swift__)
class WebGPUImplTable;
#endif
class RemoteGPU;
class RemoteCompositorIntegration;
class RemoteXRBinding;
class RemoteXRProjectionLayer;
class RemoteXRSubImage;
class RemoteXRView;
class WebGPUXRSubImage;
}

namespace WebKit::WebGPU {


class ObjectHeap final : public RefCountedAndCanMakeWeakPtr<ObjectHeap>, public WebGPU::ConvertFromBackingContext {
    WTF_MAKE_TZONE_ALLOCATED(ObjectHeap);
public:
    static Ref<ObjectHeap> create()
    {
        return adoptRef(*new ObjectHeap());
    }

    ~ObjectHeap();

    void addObject(WebGPUIdentifier, RemoteCompositorIntegration&);
    void addObject(WebGPUIdentifier, RemoteXRBinding&);
    void addObject(WebGPUIdentifier, RemoteXRSubImage&);
    void addObject(WebGPUIdentifier, RemoteXRProjectionLayer&);
    void addObject(WebGPUIdentifier, RemoteXRView&);
    // The Swift registry, which owns the objects of the other kinds, makes adapters and canvas contexts for RemoteGPU, and
    // the receivers of an XR sub-image's textures. False if the sub-image has no such texture.
    std::optional<RemoteGPURequestAdapterResponse> requestAdapter(const ::WebGPU::RequestAdapterOptions&, WebGPUIdentifier);
    void addPresentationContext(WebGPUIdentifier, RemoteCompositorIntegration&);
    bool addXRSubImageTexture(WebGPUXRSubImage&, bool depth, WebGPUIdentifier);

    RefPtr<RemoteCompositorIntegration> compositorIntegration(WebGPUIdentifier);
    RefPtr<RemoteXRProjectionLayer> xrProjectionLayer(WebGPUIdentifier);
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

#if !defined(__swift__)
    // The Swift registry of the WebGPU objects whose messages Swift receives, which the heap empties when it's cleared,
    // with the instance that the descriptor describes.
    void createSwiftImplTable(RemoteGPU&, ::WebGPU::InstanceDescriptor&&);
    WebGPUImplTable& swiftImplTable();
#endif
private:
    ObjectHeap();

    using Object = Variant<
        std::monostate,
        IPC::ScopedActiveMessageReceiveQueue<RemoteCompositorIntegration>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRBinding>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRSubImage>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRProjectionLayer>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRView>
    >;

    HashMap<WebGPUIdentifier, Object> m_objects;
#if !defined(__swift__)
    std::unique_ptr<WebGPUImplTable> m_swiftImplTable;
#endif
};

} // namespace WebKit::WebGPU

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
