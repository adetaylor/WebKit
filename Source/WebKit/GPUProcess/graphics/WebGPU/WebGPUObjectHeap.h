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

#if ENABLE(GPU_PROCESS)

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
#include <wtf/ThreadSafeWeakHashSet.h>

namespace WebCore {
class WebGPUCompositorIntegration;
class WebGPUIntegration;
}

namespace WebKit {
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT) && !defined(__swift__)
class WebGPUImplTable;
#endif
class RemoteAdapter;
class RemoteBindGroup;
class RemoteBindGroupLayout;
class RemoteBuffer;
class RemoteCommandBuffer;
class RemoteCommandEncoder;
class RemoteCompositorIntegration;
class RemoteComputePassEncoder;
class RemoteComputePipeline;
class RemoteDevice;
class RemoteExternalTexture;
class RemotePipelineLayout;
class RemotePresentationContext;
class RemoteQuerySet;
class RemoteQueue;
class RemoteRenderBundleEncoder;
class RemoteRenderBundle;
class RemoteRenderPassEncoder;
class RemoteRenderPipeline;
class RemoteSampler;
class RemoteShaderModule;
class RemoteTexture;
class RemoteTextureView;
class RemoteXRBinding;
class RemoteXRProjectionLayer;
class RemoteXRSubImage;
class RemoteXRView;
}

namespace WebKit::WebGPU {

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
using BindGroupLayoutObject = SwiftReceiverObject<::WebGPU::BindGroupLayout, RemoteBindGroupLayout>;
using BindGroupObject = SwiftReceiverObject<::WebGPU::BindGroup, RemoteBindGroup>;
using CommandBufferObject = SwiftReceiverObject<::WebGPU::CommandBuffer, RemoteCommandBuffer>;
using ComputePassEncoderObject = SwiftReceiverObject<::WebGPU::ComputePassEncoder, RemoteComputePassEncoder>;
using ComputePipelineObject = SwiftReceiverObject<::WebGPU::ComputePipeline, RemoteComputePipeline>;
using ExternalTextureObject = SwiftReceiverObject<::WebGPU::ExternalTexture, RemoteExternalTexture>;
using PipelineLayoutObject = SwiftReceiverObject<::WebGPU::PipelineLayout, RemotePipelineLayout>;
using QuerySetObject = SwiftReceiverObject<::WebGPU::QuerySet, RemoteQuerySet>;
using RenderBundleObject = SwiftReceiverObject<::WebGPU::RenderBundle, RemoteRenderBundle>;
using RenderPipelineObject = SwiftReceiverObject<::WebGPU::RenderPipeline, RemoteRenderPipeline>;
using SamplerObject = SwiftReceiverObject<::WebGPU::Sampler, RemoteSampler>;
using TextureViewObject = SwiftReceiverObject<::WebGPU::TextureView, RemoteTextureView>;
#else
using BindGroupLayoutObject = IPC::ScopedActiveMessageReceiveQueue<RemoteBindGroupLayout>;
using BindGroupObject = IPC::ScopedActiveMessageReceiveQueue<RemoteBindGroup>;
using CommandBufferObject = IPC::ScopedActiveMessageReceiveQueue<RemoteCommandBuffer>;
using ComputePassEncoderObject = IPC::ScopedActiveMessageReceiveQueue<RemoteComputePassEncoder>;
using ComputePipelineObject = IPC::ScopedActiveMessageReceiveQueue<RemoteComputePipeline>;
using ExternalTextureObject = IPC::ScopedActiveMessageReceiveQueue<RemoteExternalTexture>;
using PipelineLayoutObject = IPC::ScopedActiveMessageReceiveQueue<RemotePipelineLayout>;
using QuerySetObject = IPC::ScopedActiveMessageReceiveQueue<RemoteQuerySet>;
using RenderBundleObject = IPC::ScopedActiveMessageReceiveQueue<RemoteRenderBundle>;
using RenderPipelineObject = IPC::ScopedActiveMessageReceiveQueue<RemoteRenderPipeline>;
using SamplerObject = IPC::ScopedActiveMessageReceiveQueue<RemoteSampler>;
using TextureViewObject = IPC::ScopedActiveMessageReceiveQueue<RemoteTextureView>;
#endif

class ObjectHeap final : public RefCountedAndCanMakeWeakPtr<ObjectHeap>, public WebGPU::ConvertFromBackingContext {
    WTF_MAKE_TZONE_ALLOCATED(ObjectHeap);
public:
    static Ref<ObjectHeap> create()
    {
        return adoptRef(*new ObjectHeap());
    }

    ~ObjectHeap();

    void addObject(WebGPUIdentifier, RemoteAdapter&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, BindGroupObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteBindGroup&);
#endif
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, BindGroupLayoutObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteBindGroupLayout&);
#endif
    void addObject(WebGPUIdentifier, RemoteBuffer&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, CommandBufferObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteCommandBuffer&);
#endif
    void addObject(WebGPUIdentifier, RemoteCommandEncoder&);
    void addObject(WebGPUIdentifier, RemoteCompositorIntegration&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, ComputePassEncoderObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteComputePassEncoder&);
#endif
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, ComputePipelineObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteComputePipeline&);
#endif
    void addObject(WebGPUIdentifier, RemoteDevice&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, ExternalTextureObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteExternalTexture&);
#endif
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, PipelineLayoutObject&&);
#else
    void addObject(WebGPUIdentifier, RemotePipelineLayout&);
#endif
    void addObject(WebGPUIdentifier, RemotePresentationContext&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, QuerySetObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteQuerySet&);
#endif
    void addObject(WebGPUIdentifier, RemoteQueue&);
    void addObject(WebGPUIdentifier, RemoteRenderBundleEncoder&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, RenderBundleObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteRenderBundle&);
#endif
    void addObject(WebGPUIdentifier, RemoteRenderPassEncoder&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, RenderPipelineObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteRenderPipeline&);
#endif
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, SamplerObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteSampler&);
#endif
    void addObject(WebGPUIdentifier, RemoteShaderModule&);
    void addObject(WebGPUIdentifier, RemoteTexture&);
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void addObject(WebGPUIdentifier, TextureViewObject&&);
#else
    void addObject(WebGPUIdentifier, RemoteTextureView&);
#endif
    void addObject(WebGPUIdentifier, RemoteXRBinding&);
    void addObject(WebGPUIdentifier, RemoteXRSubImage&);
    void addObject(WebGPUIdentifier, RemoteXRProjectionLayer&);
    void addObject(WebGPUIdentifier, RemoteXRView&);

    void removeObject(WebGPUIdentifier);

    void clear();

    Vector<Ref<::WebGPU::Device>> devices() const;

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
    ExistsAndValid objectExistsAndValid(const WebCore::WebGPUIntegration&, WebGPUIdentifier) const;

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT) && !defined(__swift__)
    // The Swift receivers' table of the Impls of objects in this heap, which the heap empties of each object it removes.
    WebGPUImplTable& swiftImplTable();
#endif

private:
    ObjectHeap();

    using Object = Variant<
        std::monostate,
        IPC::ScopedActiveMessageReceiveQueue<RemoteAdapter>,
        BindGroupObject,
        BindGroupLayoutObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteBuffer>,
        CommandBufferObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteCommandEncoder>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteCompositorIntegration>,
        ComputePassEncoderObject,
        ComputePipelineObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteDevice>,
        ExternalTextureObject,
        PipelineLayoutObject,
        IPC::ScopedActiveMessageReceiveQueue<RemotePresentationContext>,
        QuerySetObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteQueue>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteRenderBundleEncoder>,
        RenderBundleObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteRenderPassEncoder>,
        RenderPipelineObject,
        SamplerObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteShaderModule>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteTexture>,
        TextureViewObject,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRBinding>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRSubImage>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRProjectionLayer>,
        IPC::ScopedActiveMessageReceiveQueue<RemoteXRView>
    >;

    HashMap<WebGPUIdentifier, Object> m_objects;
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT) && !defined(__swift__)
    std::unique_ptr<WebGPUImplTable> m_swiftImplTable;
#endif
    // Every device added that is still alive: work in flight can keep a device alive after its object is removed.
    ThreadSafeWeakHashSet<::WebGPU::Device> m_devices;
};

} // namespace WebKit::WebGPU

#endif // ENABLE(GPU_PROCESS)
