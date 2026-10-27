/*
 * Copyright (c) 2021-2022 Apple Inc. All rights reserved.
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

#pragma once

#import "BindableResource.h"
#import "HardwareCapabilities.h"
#import "Queue.h"
#import <CoreVideo/CVMetalTextureCache.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <expected>
#import <memory>
#import <simd/matrix_types.h>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Function.h>
#import <wtf/HashIterators.h>
#import <wtf/HashMap.h>
#import <wtf/HashTable.h>
#import <wtf/KeyValuePair.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakHashSet.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/Vector.h>
#import <wtf/text/WTFString.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")


#if !defined(__swift__)
namespace WebGPU {
class DeviceImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroup;
class BindGroupLayout;
class Buffer;
class CommandEncoder;
class ComputePipeline;
class ExternalTexture;
class Instance;
class PipelineLayout;
class PresentationContext;
class QuerySet;
class RenderBundleEncoder;
class RenderPipeline;
class Sampler;
class ShaderModule;
class Texture;
class XRBinding;
class XRSubImage;
class XRProjectionLayer;
class XRView;

// Opaque box holding the Swift DeviceImpl; defined in Device.mm.
struct DeviceImplBox;

using UncapturedErrorCallback = CompletionHandler<void(bool, std::optional<WebGPU::Error>&&)>;
using DeviceLostCallback = CompletionHandler<void(WebGPU::DeviceLostReason, String&&)>;
using OptionalError = std::optional<WebGPU::Error>;

// The messages DeviceImpl gives the device-lost callback (Swift cannot spell an ASCIILiteral).
inline String deviceLostMessage() { return "Device lost."_s; }
inline String deviceDestroyedMessage() { return ""_s; }

// WTFLogAlways("%@", message), for Swift, which cannot call a C variadic macro.
void logAlways(NSString *message);

// notify(3) for DebugToggles.swift, with no pointer crossing into Swift: the registration's token and the state are
// out-parameters, which Swift can only pass as unsafe pointers. The handler stays registered, and runs on the main queue.
void registerNotifyHandler(NSString *name, void (^ NS_SWIFT_SENDABLE handler)(int token));
uint64_t notifyState(int token);

#define WEBKIT_DRAW_INDEXED_INDIRECT_STRUCT_TYPE \
struct WebKitMTLDrawIndexedPrimitivesIndirectArguments { \
    MTLDrawIndexedPrimitivesIndirectArguments args;         \
    unsigned lostOrOOBRead;                                 \
};
WEBKIT_DRAW_INDEXED_INDIRECT_STRUCT_TYPE

#define WEBKIT_DRAW_INDIRECT_STRUCT_TYPE \
struct WebKitMTLDrawPrimitivesIndirectArguments { \
    MTLDrawPrimitivesIndirectArguments args;                \
    unsigned lostOrOOBRead;                                 \
};
WEBKIT_DRAW_INDIRECT_STRUCT_TYPE

// https://gpuweb.github.io/gpuweb/#gpudevice
// The state is in DeviceImpl, except the device-observer registration and the debug timestamp maps, which Metal and
// observer threads use.
class Device final : public WebGPU::Device {
    WTF_MAKE_TZONE_ALLOCATED(Device);
public:
    static Ref<Device> create(id<MTLDevice>, String&& deviceLabel, HardwareCapabilities&&, Adapter&);
    static Ref<Device> createInvalid(Adapter&);

    ~Device();

    RefPtr<WebGPU::BindGroup> createBindGroup(const WebGPU::BindGroupDescriptor&) final;
    RefPtr<WebGPU::BindGroupLayout> createBindGroupLayout(const WebGPU::BindGroupLayoutDescriptor&) final;
    RefPtr<WebGPU::XRBinding> createXRBinding() final;
    Ref<XRView> createXRView();
    RefPtr<WebGPU::Buffer> createBuffer(const WebGPU::BufferDescriptor&) final;
    RefPtr<WebGPU::CommandEncoder> createCommandEncoder(const WebGPU::CommandEncoderDescriptor&) final;
    RefPtr<WebGPU::ComputePipeline> createComputePipeline(const WebGPU::ComputePipelineDescriptor&) final;
    void createComputePipelineAsync(const WebGPU::ComputePipelineDescriptor&, CompletionHandler<void(std::expected<Ref<WebGPU::ComputePipeline>, WebGPU::PipelineError>&&)>&&) final;
    void createComputePipelineWithPipelineLayoutFromPipelineAsync(const WebGPU::ComputePipelineDescriptor&, const WebGPU::ComputePipeline&, CompletionHandler<void(std::expected<Ref<WebGPU::ComputePipeline>, WebGPU::PipelineError>&&)>&&) final;
    RefPtr<WebGPU::ExternalTexture> importExternalTexture(const WebGPU::ExternalTextureDescriptor&) final;
    RefPtr<WebGPU::PipelineLayout> createPipelineLayout(const WebGPU::PipelineLayoutDescriptor&) final;
    Ref<PipelineLayout> createPipelineLayout(const WebGPU::PipelineLayoutDescriptor&, bool isAutogenerated);
    RefPtr<WebGPU::QuerySet> createQuerySet(const WebGPU::QuerySetDescriptor&) final;
    RefPtr<WebGPU::RenderBundleEncoder> createRenderBundleEncoder(const WebGPU::RenderBundleEncoderDescriptor&) final;

    RefPtr<WebGPU::RenderPipeline> createRenderPipeline(const WebGPU::RenderPipelineDescriptor&) final;
    void createRenderPipelineAsync(const WebGPU::RenderPipelineDescriptor&, CompletionHandler<void(std::expected<Ref<WebGPU::RenderPipeline>, WebGPU::PipelineError>&&)>&&) final;
    void createRenderPipelineWithPipelineLayoutFromPipelineAsync(const WebGPU::RenderPipelineDescriptor&, const WebGPU::RenderPipeline&, CompletionHandler<void(std::expected<Ref<WebGPU::RenderPipeline>, WebGPU::PipelineError>&&)>&&) final;
    RefPtr<WebGPU::Sampler> createSampler(const WebGPU::SamplerDescriptor&) final;
    RefPtr<WebGPU::ShaderModule> createShaderModule(const WebGPU::ShaderModuleDescriptor&) final;
    RefPtr<WebGPU::Texture> createTexture(const WebGPU::TextureDescriptor&) final;
    void destroy() final;
    Vector<WebGPU::FeatureName> features() const final;
    Ref<WebGPU::Queue> queue() final;
    Ref<Queue> getQueue() const;
    bool hasFeature(WebGPU::FeatureName) const;
    void popErrorScope(CompletionHandler<void(bool, std::optional<WebGPU::Error>&&)>&&) final;
    void pushErrorScope(WebGPU::ErrorFilter) final;
    void resolveDeviceLostPromise(CompletionHandler<void(WebGPU::DeviceLostReason, String&&)>&&) final;
    void resolveUncapturedErrorEvent(CompletionHandler<void(bool, std::optional<WebGPU::Error>&&)>&&) final;
    void pauseAllErrorReporting(bool pause) final;
    void LEGACY_NODELETE setLabel(String&&) final;

    bool LEGACY_NODELETE isValid() const final;
    bool isLost() const;
#if !defined(__swift__)
    WebGPU::DeviceImpl& swiftImpl() const LIFETIME_BOUND;
#endif
    Limits LEGACY_NODELETE limits() const final;
    // For the Swift callers that have not switched to DeviceImpl.capabilities.limits.
    Limits limitsCopy() const { return limits(); }
    id<MTLCounterSet> timestampCounterSet() const;
    uint32_t memoryBarrierLimit() const;
    bool supportsNonPrivateDepthStencilTextures() const;
    bool supportsMemorylessTextures() const;

    id<MTLDevice> _Nullable device() const;
    void generateAValidationError(NSString * message);
    void generateAValidationError(String&& message);
    void generateAnOutOfMemoryError(String&& message);

    RefPtr<Instance> instance() const;
    Adapter& adapter() const;
#if CPU(X86_64)
    bool hasUnifiedMemory() const { return false; }
#else
    bool hasUnifiedMemory() const { return device().hasUnifiedMemory; }
#endif
    bool isShaderValidationEnabled() const;

    uint32_t maxBuffersPlusVertexBuffersForVertexStage() const;
    uint32_t maxBuffersForFragmentStage() const;
    uint32_t maxBuffersForComputeStage() const;

    id<MTLTexture> newTextureWithDescriptor(MTLTextureDescriptor *, IOSurfaceRef = nullptr, NSUInteger plane = 0) const;

    bool LEGACY_NODELETE shouldStopCaptureAfterSubmit();
    id<MTLBuffer> placeholderBuffer() const;

    id<MTLTexture> LEGACY_NODELETE placeholderTexture(WebGPU::TextureFormat) const;
    bool LEGACY_NODELETE isDestroyed() const;
    NSString *errorValidatingTextureCreation(const WebGPU::TextureDescriptor&);
    id<MTLBuffer> safeCreateBuffer(NSUInteger length, MTLStorageMode, bool skipMemoryAttribution = false, MTLCPUCacheMode = MTLCPUCacheModeDefaultCache, MTLHazardTrackingMode = MTLHazardTrackingModeDefault) const;
    id<MTLBuffer> safeCreateBuffer(NSUInteger, bool skipMemoryAttribution = false) const;
    void loseTheDevice(WebGPU::DeviceLostReason);
    void setOwnerWithIdentity(id<MTLResource>) const;
    RefPtr<XRSubImage> getXRViewSubImage(XRProjectionLayer&);
    RefPtr<XRSubImage> LEGACY_NODELETE getXRViewSubImage() const;
    id<MTLTexture> _Nullable getXRViewSubImageDepthTexture() const;
#if CPU(X86_64)
    bool isIntel() const { return [device().name localizedCaseInsensitiveContainsString:@"intel"]; }
#else
    constexpr bool isIntel() const { return false; }
#endif
    bool LEGACY_NODELETE pauseErrorReporting(bool pauseReporting);
    bool enableEncoderTimestamps() const;
    id<MTLCounterSampleBuffer> timestampsBuffer(id<MTLCommandBuffer>, size_t);
    void resolveTimestampsForBuffer(id<MTLCommandBuffer>);
    // Nil once the device is lost.
    id<MTLSharedEvent> _Nullable resolveTimestampsSharedEvent();
    uint32_t maxVerticesPerDrawCall() const;
    void trackTimestampsBuffer(id<MTLCommandBuffer>, id<MTLCounterSampleBuffer>);

    static constexpr uint64_t maxBindGroups = (1ull << 5);
    uint32_t appleGPUFamily() const;

private:
    Device(id<MTLDevice>, id<MTLCommandQueue> defaultQueue, const HardwareCapabilities&, Adapter&);
    explicit Device(Adapter&);

    // First, so it is built before and destroyed after everything the constructor/destructor hand `*this` to.
    const std::unique_ptr<DeviceImplBox> m_impl;
    NSMapTable<id<MTLCommandBuffer>, NSMutableArray<id<MTLCounterSampleBuffer>>*>* m_sampleCounterBuffers;
    NSMapTable<id<MTLCommandBuffer>, NSMutableArray<id<MTLBuffer>>*>* m_resolvedSampleCounterBuffers;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(refDevice, derefDevice);

} // namespace WebGPU::Metal

#if !ENABLE(SWIFT_BASE_CLASS_ANNOTATIONS)
inline void refDevice(WebGPU::Metal::Device* obj)
{
    obj->ref();
}

inline void derefDevice(WebGPU::Metal::Device* obj)
{
    obj->deref();
}
#endif

IGNORE_CLANG_WARNINGS_END
