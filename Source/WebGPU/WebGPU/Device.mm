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
#import "Device.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "BindGroupLayout.h"
#import "Buffer.h"
#import "CommandEncoder.h"
#import "ComputePipeline.h"
#import "PipelineLayout.h"
#import "PresentationContext.h"
#import "QuerySet.h"
#import "Queue.h"
#import "RenderBundleEncoder.h"
#import "RenderPipeline.h"
#import "Sampler.h"
#import "ShaderModule.h"
#import "Texture.h"
#import "XRSubImage.h"
#import <algorithm>
#import <notify.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/WeakPtr.h>
#import <wtf/darwin/DispatchExtras.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct DeviceImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(DeviceImplBox);
    WebGPU::DeviceImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(DeviceImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(Device);

void logAlways(NSString *message)
{
    WTFLogAlways("%@", message); // NOLINT
}

void registerNotifyHandler(NSString *name, void (^handler)(int))
{
    int token;
    notify_register_dispatch(name.UTF8String, &token, mainDispatchQueueSingleton(), handler);
}

uint64_t notifyState(int token)
{
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state;
}

bool Device::enableEncoderTimestamps() const
{
    return WebGPU::enableEncoderTimestamps();
}

id<MTLCounterSampleBuffer> Device::timestampsBuffer(id<MTLCommandBuffer> commandBuffer, size_t timestampCount)
{
#if !PLATFORM(WATCHOS)
    MTLCounterSampleBufferDescriptor* sampleBufferDesc = [MTLCounterSampleBufferDescriptor new];
    sampleBufferDesc.sampleCount = timestampCount;
    sampleBufferDesc.storageMode = MTLStorageModeShared;
    sampleBufferDesc.counterSet = timestampCounterSet();

    NSError* error = nil;
    id<MTLCounterSampleBuffer> buffer = [device() newCounterSampleBufferWithDescriptor:sampleBufferDesc error:&error];
    if (error) {
        WTFLogAlways("newCounterSamplerBufferWithDescriptor failed %@", error.localizedDescription);
        return nil;
    }

    trackTimestampsBuffer(commandBuffer, buffer);

    return buffer;
#else
    UNUSED_PARAM(commandBuffer);
    UNUSED_PARAM(timestampCount);
    return nil;
#endif
}

void Device::resolveTimestampsForBuffer(id<MTLCommandBuffer> commandBuffer)
{
    if (!enableEncoderTimestamps())
        return;

    NSMutableArray<id<MTLCounterSampleBuffer>>* sampleBufferArray = [m_sampleCounterBuffers objectForKey:commandBuffer];
    if (!sampleBufferArray)
        return;

    [m_sampleCounterBuffers removeObjectForKey:commandBuffer];
    for (id<MTLCounterSampleBuffer> sampleBuffer in sampleBufferArray) {
        id<MTLBlitCommandEncoder> blitCommandEncoder = [commandBuffer blitCommandEncoder];
        auto timestampCount = sampleBuffer.sampleCount;
        id<MTLBuffer> counterDataBuffer = safeCreateBuffer(sizeof(MTLCounterResultTimestamp) * timestampCount);
        if (!counterDataBuffer) {
            [blitCommandEncoder endEncoding];
            continue;
        }
        [blitCommandEncoder resolveCounters:sampleBuffer inRange:NSMakeRange(0, timestampCount) destinationBuffer:counterDataBuffer destinationOffset:0];
        [blitCommandEncoder endEncoding];
        NSMutableArray<id<MTLBuffer>>* resolvedBuffers = [m_resolvedSampleCounterBuffers objectForKey:commandBuffer];
        if (!resolvedBuffers) {
            resolvedBuffers = [NSMutableArray arrayWithObject:counterDataBuffer];
            [m_resolvedSampleCounterBuffers setObject:resolvedBuffers forKey:commandBuffer];
        } else
            [resolvedBuffers addObject:counterDataBuffer];

        // The map is only touched on the API thread: the handler, on a Metal thread, logs the resolved buffers it
        // captured and hands the removal, with a weak pointer to this device, to a work item.
        [commandBuffer addCompletedHandler:[weakThis = ThreadSafeWeakPtr { *this }, queue = getQueue(), resolvedBuffers = RetainPtr { resolvedBuffers }](id<MTLCommandBuffer> completedCommandBuffer) mutable {
            for (id<MTLBuffer> buffer in resolvedBuffers.get()) {
                if (!buffer.contents)
                    continue;
                auto timestamps = unsafeMakeSpan(static_cast<const MTLCounterResultTimestamp*>(buffer.contents), buffer.length / sizeof(MTLCounterResultTimestamp));
                WTFLogAlways("Timestamps for buffer %@", buffer.label); // NOLINT
                for (size_t i = 0; i + 1 < timestamps.size(); i += 2) {
                    auto timeDifference = timestamps[i + 1].timestamp - timestamps[i].timestamp;
                    WTFLogAlways("\tencoder time %f", timeDifference / 100000.0f); // NOLINT
                }
            }
            Queue& hop = queue.get();
            hop.scheduleWork([weakThis = WTF::move(weakThis), queue = WTF::move(queue), completedCommandBuffer = RetainPtr { completedCommandBuffer }] {
                if (RefPtr protectedThis = weakThis)
                    [protectedThis->m_resolvedSampleCounterBuffers removeObjectForKey:completedCommandBuffer.get()];
            });
        }];
    }
}

bool Device::shouldStopCaptureAfterSubmit()
{
    return WebGPU::shouldStopCaptureAfterSubmit();
}

bool Device::isDestroyed() const
{
    return m_impl->impl.isDestroyed();
}

bool Device::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPU::DeviceImpl& Device::swiftImpl() const
{
    return m_impl->impl;
}

bool Device::isLost() const
{
    return m_impl->impl.isLost();
}

id<MTLDevice> Device::device() const
{
    return m_impl->impl.device();
}

bool Device::isShaderValidationEnabled() const
{
    return m_impl->impl.isShaderValidationEnabled();
}

id<MTLBuffer> Device::placeholderBuffer() const
{
    return m_impl->impl.placeholderBuffer();
}

uint32_t Device::maxVerticesPerDrawCall() const
{
    return m_impl->impl.maxVerticesPerDrawCall();
}

uint32_t Device::appleGPUFamily() const
{
    return m_impl->impl.appleGPUFamily();
}

Ref<Device> Device::create(id<MTLDevice> device, String&& deviceLabel, HardwareCapabilities&& capabilities, Adapter& adapter)
{
    id<MTLCommandQueue> commandQueue = makeDefaultCommandQueue(device, deviceLabel);
    if (!commandQueue)
        return Device::createInvalid(adapter);

    return adoptRef(*new Device(device, commandQueue, capabilities, adapter));
}

Ref<Device> Device::createInvalid(Adapter& adapter)
{
    return adoptRef(*new Device(adapter));
}

// The default queue keeps a weak pointer to the device under construction.
static std::unique_ptr<DeviceImplBox> makeDeviceImplBox(id<MTLDevice> device, Ref<Queue>&& defaultQueue, const HardwareCapabilities& capabilities, Adapter& adapter)
{
    auto box = makeUnique<DeviceImplBox>(DeviceImplBox { .impl = makeDeviceImpl(device, capabilities, &adapter, defaultQueue.ptr(), defaultQueue->swiftImpl()) });
    if (RefPtr instance = adapter.instance())
        box->impl.setInstanceSchedulerHandle(instance->schedulerHandle());
    return box;
}

Device::Device(id<MTLDevice> device, id<MTLCommandQueue> defaultQueue, const HardwareCapabilities& capabilities, Adapter& adapter)
    : m_impl(makeDeviceImplBox(device, Queue::create(defaultQueue, adapter, *this), capabilities, adapter))
{
    Ref xrSubImage = XRSubImage::create(*this);
    m_impl->impl.installXRSubImage(xrSubImage.ptr());

#if PLATFORM(MAC)
    id<NSObject> deviceObserver = nil;
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    // Runs on an observer thread: it uses only the scheduler handle captured here, and hands its reference to the device
    // over to the work item, which releases it on the API thread.
    std::optional<WebGPU::InstanceSchedulerHandle> scheduler;
    if (RefPtr instance = adapter.instance())
        scheduler = instance->schedulerHandle();
    auto devices = MTLCopyAllDevicesWithObserver(&deviceObserver, [weakThis = ThreadSafeWeakPtr { *this }, scheduler = WTF::move(scheduler)](id<MTLDevice> device, MTLDeviceNotificationName) mutable {
        RefPtr protectedThis = weakThis;
        if (!protectedThis || !scheduler)
            return;
        Instance::WorkItem workItem { [protectedThis = WTF::move(protectedThis), device = device] {
            if (![protectedThis->device() isEqual:device])
                return;
            protectedThis->loseTheDevice(WebGPU::DeviceLostReason::Unknown);
        } };
        scheduler->scheduleWork(workItem);
    });
    ALLOW_DEPRECATED_DECLARATIONS_END
    m_impl->impl.setDeviceObserver(deviceObserver);

#if ASSERT_ENABLED
    bool found = false;
    for (id<MTLDevice> observedDevice in devices) {
        if ([observedDevice isEqual:device]) {
            found = true;
            break;
        }
    }
    ASSERT(found);
#else
    UNUSED_VARIABLE(devices);
#endif
#endif

    WebGPU::registerForFrameCapture(device);

    m_sampleCounterBuffers = [NSMapTable weakToStrongObjectsMapTable];
    m_resolvedSampleCounterBuffers = [NSMapTable weakToStrongObjectsMapTable];
}

Device::Device(Adapter& adapter)
    : m_impl(makeDeviceImplBox(nil, Queue::createInvalid(adapter, *this), HardwareCapabilities { }, adapter))
{
    if (!adapter.isValid())
        m_impl->impl.makeInvalid();
}

Device::~Device()
{
#if PLATFORM(MAC)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    MTLRemoveDeviceObserver(m_impl->impl.deviceObserver());
    ALLOW_DEPRECATED_DECLARATIONS_END
#endif
    m_impl->impl.completeCallbacksForDestruction();
}

RefPtr<XRSubImage> Device::getXRViewSubImage(XRProjectionLayer& projectionLayer)
{
    RefPtr subImage = getXRViewSubImage();
    subImage->update(projectionLayer);
    return subImage;
}

RefPtr<XRSubImage> Device::getXRViewSubImage() const
{
    if (!m_impl->impl.hasXRSubImage())
        return nullptr;
    return adoptRef(m_impl->impl.xrSubImage());
}

Adapter& Device::adapter() const
{
    return borrowSwiftRetained(m_impl->impl.adapter());
}

RefPtr<Instance> Device::instance() const
{
    return adapter().instance();
}

Ref<Queue> Device::getQueue() const
{
    return adoptRef(*m_impl->impl.defaultQueue());
}

id<MTLTexture> Device::getXRViewSubImageDepthTexture() const
{
    if (auto subImage = getXRViewSubImage()) {
        if (RefPtr depthTexture = subImage->depthTexture())
            return depthTexture->texture();
    }

    return nil;
}

void Device::loseTheDevice(WebGPU::DeviceLostReason reason)
{
    m_impl->impl.loseTheDevice(reason);
}

void Device::setOwnerWithIdentity(id<MTLResource> resource) const
{
    m_impl->impl.setOwnerWithIdentity(resource);
}

void Device::destroy()
{
    m_impl->impl.destroy();
}

Vector<WebGPU::FeatureName> Device::features() const
{
    Vector<WebGPU::FeatureName> features;
    m_impl->impl.copyFeatures(features);
    return features;
}

SUPPRESS_NODELETE Limits Device::limits() const
{
    return m_impl->impl.deviceLimits();
}

id<MTLCounterSet> Device::timestampCounterSet() const
{
    return m_impl->impl.timestampCounterSet();
}

uint32_t Device::memoryBarrierLimit() const
{
    return m_impl->impl.memoryBarrierLimit();
}

bool Device::supportsNonPrivateDepthStencilTextures() const
{
    return m_impl->impl.supportsNonPrivateDepthStencilTextures();
}

bool Device::supportsMemorylessTextures() const
{
    return m_impl->impl.supportsMemorylessTextures();
}

uint32_t Device::maxBuffersPlusVertexBuffersForVertexStage() const
{
    return m_impl->impl.maxBuffersPlusVertexBuffersForVertexStage();
}

uint32_t Device::maxBuffersForFragmentStage() const
{
    return m_impl->impl.maxBuffersForFragmentStage();
}

uint32_t Device::maxBuffersForComputeStage() const
{
    return m_impl->impl.maxBuffersForComputeStage();
}

id<MTLTexture> Device::placeholderTexture(WebGPU::TextureFormat format) const
{
    return m_impl->impl.placeholderTexture(Texture::isDepthOrStencilFormat(format));
}

bool Device::hasFeature(WebGPU::FeatureName feature) const
{
    return m_impl->impl.hasFeature(feature);
}

void Device::generateAValidationError(NSString * message)
{
    generateAValidationError(String { message });
}

void Device::generateAValidationError(String&& message)
{
    // https://gpuweb.github.io/gpuweb/#abstract-opdef-generate-a-validation-error
    m_impl->impl.generateAnError(WebGPU::ErrorFilter::Validation, WebGPU::ErrorType::Validation, message);
}

void Device::generateAnOutOfMemoryError(String&& message)
{
    // https://gpuweb.github.io/gpuweb/#abstract-opdef-generate-an-out-of-memory-error
    m_impl->impl.generateAnError(WebGPU::ErrorFilter::OutOfMemory, WebGPU::ErrorType::OutOfMemory, message);
}

id<MTLTexture> Device::newTextureWithDescriptor(MTLTextureDescriptor *textureDescriptor, IOSurfaceRef ioSurface, NSUInteger plane) const
{
    return m_impl->impl.newTextureWithDescriptor(textureDescriptor, ioSurface, plane);
}

id<MTLBuffer> Device::safeCreateBuffer(NSUInteger length, MTLStorageMode storageMode, bool skipAttribution, MTLCPUCacheMode cpuCacheMode, MTLHazardTrackingMode hazardTrackingMode) const
{
    return m_impl->impl.safeCreateBuffer(length, storageMode, skipAttribution, cpuCacheMode, hazardTrackingMode);
}

id<MTLBuffer> Device::safeCreateBuffer(NSUInteger length, bool skipAttribution) const
{
    return safeCreateBuffer(length, MTLStorageModeShared, skipAttribution);
}

Ref<WebGPU::Queue> Device::queue()
{
    return getQueue();
}

void Device::pauseAllErrorReporting(bool pause)
{
    pauseErrorReporting(pause);
}

void Device::popErrorScope(CompletionHandler<void(bool, std::optional<WebGPU::Error>&&)>&& callback)
{
    m_impl->impl.popErrorScope(callback, instance().get());
}

void Device::pushErrorScope(WebGPU::ErrorFilter filter)
{
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-pusherrorscope

    m_impl->impl.pushErrorScope(filter);
}

void Device::resolveDeviceLostPromise(CompletionHandler<void(WebGPU::DeviceLostReason, String&&)>&& callback)
{
    m_impl->impl.resolveDeviceLostPromise(callback, !!callback);
}

void Device::resolveUncapturedErrorEvent(CompletionHandler<void(bool, std::optional<WebGPU::Error>&&)>&& callback)
{
    m_impl->impl.resolveUncapturedErrorEvent(callback, !!callback);
}

void Device::setLabel(String&&)
{
    // Because MTLDevices are process-global, we can't set the label on it, because 2 contexts' labels would fight each other.
}

bool Device::pauseErrorReporting(bool pauseReporting)
{
    return m_impl->impl.pauseErrorReporting(pauseReporting);
}

id<MTLSharedEvent> Device::resolveTimestampsSharedEvent()
{
    return m_impl->impl.resolveTimestampsSharedEvent();
}

void Device::trackTimestampsBuffer(id<MTLCommandBuffer> commandBuffer, id<MTLCounterSampleBuffer> counterSampleBuffer)
{
    NSMutableArray<id<MTLCounterSampleBuffer>>* sampleBufferArray = [m_sampleCounterBuffers objectForKey:commandBuffer];
    if (!sampleBufferArray) {
        sampleBufferArray = [NSMutableArray array];
        [m_sampleCounterBuffers setObject:sampleBufferArray forKey:commandBuffer];
    }
    [sampleBufferArray addObject:counterSampleBuffer];
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

static constexpr auto invalidComputePipelineDescriptorMessage = "GPUComputePipelineDescriptor has no shader module"_s;
static constexpr auto invalidRenderPipelineDescriptorMessage = "GPURenderPipelineDescriptor has no shader module or an invalid enum value or color write mask bit"_s;

void LEGACY_NODELETE wgpuDeviceAddRef(WGPUDevice device)
{
    WebGPU::Metal::fromAPI(device).ref();
}

void wgpuDeviceRelease(WGPUDevice device)
{
    WebGPU::Metal::fromAPI(device).deref();
}

WGPUBindGroup wgpuDeviceCreateBindGroup(WGPUDevice device, const WGPUBindGroupDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::BindGroupDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUBindGroupDescriptor has no layout or an entry without exactly one resource"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::BindGroup::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::BindGroup>(protectedDevice->createBindGroup(*apiDescriptor));
}

WGPUBindGroupLayout wgpuDeviceCreateBindGroupLayout(WGPUDevice device, const WGPUBindGroupLayoutDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::BindGroupLayoutDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUBindGroupLayoutDescriptor has an invalid enum value or visibility bit"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::BindGroupLayout::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::BindGroupLayout>(protectedDevice->createBindGroupLayout(*apiDescriptor));
}

WGPUBuffer wgpuDeviceCreateBuffer(WGPUDevice device, const WGPUBufferDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUBufferDescriptor.usage has unknown bits"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::Buffer::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::Buffer>(protectedDevice->createBuffer(*apiDescriptor));
}

WGPUCommandEncoder wgpuDeviceCreateCommandEncoder(WGPUDevice device, const WGPUCommandEncoderDescriptor* descriptor)
{
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::CommandEncoder>(protect(WebGPU::Metal::fromAPI(device))->createCommandEncoder({ .label = WebGPU::Metal::fromAPI(descriptor->label) }));
}

WGPUComputePipeline wgpuDeviceCreateComputePipeline(WGPUDevice device, const WGPUComputePipelineDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::ComputePipelineDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError(invalidComputePipelineDescriptorMessage);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::ComputePipeline::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::ComputePipeline>(protectedDevice->createComputePipeline(*apiDescriptor));
}

// The C API reports a failed asynchronous pipeline creation with a status and no pipeline.
template<typename MetalPipeline, typename T>
static auto createPipelineAsyncCompletion(Function<void(WGPUCreatePipelineAsyncStatus, T*, String&&)>&& callback)
{
    return [callback = WTF::move(callback)](auto&& pipeline) mutable {
        if (!pipeline)
            return callback(WGPUCreatePipelineAsyncStatus_ValidationError, nullptr, WTF::move(pipeline.error().message));
        callback(WGPUCreatePipelineAsyncStatus_Success, WebGPU::Metal::releaseToAPIAs<MetalPipeline>(WTF::move(*pipeline)), { });
    };
}

// Reports a descriptor that did not convert, for the asynchronous pipeline creations.
static void reportInvalidPipelineDescriptor(WebGPU::Metal::Device& device, ASCIILiteral message, auto&& callback)
{
    if (RefPtr instance = device.instance()) {
        instance->scheduleWork([callback = WTF::move(callback), message]() mutable {
            callback(WGPUCreatePipelineAsyncStatus_ValidationError, nullptr, message);
        });
        return;
    }
    callback(WGPUCreatePipelineAsyncStatus_ValidationError, nullptr, message);
}

static void createComputePipelineAsync(WGPUDevice device, const WGPUComputePipelineDescriptor& descriptor, Function<void(WGPUCreatePipelineAsyncStatus, WGPUComputePipeline, String&&)>&& callback)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::ComputePipelineDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(descriptor, storage);
    if (!apiDescriptor)
        return reportInvalidPipelineDescriptor(protectedDevice, invalidComputePipelineDescriptorMessage, WTF::move(callback));
    protectedDevice->createComputePipelineAsync(*apiDescriptor, createPipelineAsyncCompletion<WebGPU::Metal::ComputePipeline>(WTF::move(callback)));
}

WGPUFuture wgpuDeviceCreateComputePipelineAsync(WGPUDevice device, const WGPUComputePipelineDescriptor* descriptor, WGPUCreateComputePipelineAsyncCallbackInfo callbackInfo)
{
    WebGPU::Metal::CAPIFuture future { protect(WebGPU::Metal::fromAPI(device))->instance() };
    createComputePipelineAsync(device, *descriptor, [callbackInfo, future](WGPUCreatePipelineAsyncStatus status, WGPUComputePipeline pipeline, String&& message) {
        auto utf8 = message.utf8();
        callbackInfo.callback(status, pipeline, WebGPU::Metal::toAPI(utf8), callbackInfo.userdata1, callbackInfo.userdata2);
        future.complete();
    });
    return future.future();
}

WGPUPipelineLayout wgpuDeviceCreatePipelineLayout(WGPUDevice device, const WGPUPipelineLayoutDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::PipelineLayoutDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUPipelineLayoutDescriptor has a null bind group layout"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::PipelineLayout::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPI(protectedDevice->createPipelineLayout(*apiDescriptor, !apiDescriptor->bindGroupLayouts));
}

WGPUQuerySet wgpuDeviceCreateQuerySet(WGPUDevice device, const WGPUQuerySetDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor);
    // An unknown query type makes an invalid query set without a validation error.
    if (!apiDescriptor)
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::QuerySet::createInvalid(protectedDevice));
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::QuerySet>(protectedDevice->createQuerySet(*apiDescriptor));
}

WGPURenderBundleEncoder wgpuDeviceCreateRenderBundleEncoder(WGPUDevice device, const WGPURenderBundleEncoderDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::RenderBundleEncoderDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        NSString *error = @"GPURenderBundleEncoderDescriptor has an invalid texture format";
        protectedDevice->generateAValidationError(error);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::RenderBundleEncoder::createInvalid(protectedDevice, error));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::RenderBundleEncoder>(protectedDevice->createRenderBundleEncoder(*apiDescriptor));
}

WGPURenderPipeline wgpuDeviceCreateRenderPipeline(WGPUDevice device, const WGPURenderPipelineDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::RenderPipelineDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError(invalidRenderPipelineDescriptorMessage);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::RenderPipeline::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::RenderPipeline>(protectedDevice->createRenderPipeline(*apiDescriptor));
}

static void createRenderPipelineAsync(WGPUDevice device, const WGPURenderPipelineDescriptor& descriptor, Function<void(WGPUCreatePipelineAsyncStatus, WGPURenderPipeline, String&&)>&& callback)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::RenderPipelineDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(descriptor, storage);
    if (!apiDescriptor)
        return reportInvalidPipelineDescriptor(protectedDevice, invalidRenderPipelineDescriptorMessage, WTF::move(callback));
    protectedDevice->createRenderPipelineAsync(*apiDescriptor, createPipelineAsyncCompletion<WebGPU::Metal::RenderPipeline>(WTF::move(callback)));
}

WGPUFuture wgpuDeviceCreateRenderPipelineAsync(WGPUDevice device, const WGPURenderPipelineDescriptor* descriptor, WGPUCreateRenderPipelineAsyncCallbackInfo callbackInfo)
{
    WebGPU::Metal::CAPIFuture future { protect(WebGPU::Metal::fromAPI(device))->instance() };
    createRenderPipelineAsync(device, *descriptor, [callbackInfo, future](WGPUCreatePipelineAsyncStatus status, WGPURenderPipeline pipeline, String&& message) {
        auto utf8 = message.utf8();
        callbackInfo.callback(status, pipeline, WebGPU::Metal::toAPI(utf8), callbackInfo.userdata1, callbackInfo.userdata2);
        future.complete();
    });
    return future.future();
}

WGPUSampler wgpuDeviceCreateSampler(WGPUDevice device, const WGPUSamplerDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUSamplerDescriptor has an invalid enum value"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::Sampler::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::Sampler>(protectedDevice->createSampler(*apiDescriptor));
}

WGPUShaderModule wgpuDeviceCreateShaderModule(WGPUDevice device, const WGPUShaderModuleDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::ShaderModuleDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUShaderModuleDescriptor has no WGSL code or a null pipeline layout hint"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::ShaderModule::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::ShaderModule>(protectedDevice->createShaderModule(*apiDescriptor));
}

WGPUTexture wgpuDeviceCreateTexture(WGPUDevice device, const WGPUTextureDescriptor* descriptor)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::TextureDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(*descriptor, storage);
    if (!apiDescriptor) {
        protectedDevice->generateAValidationError("GPUTextureDescriptor has an invalid enum value or usage bit"_s);
        return WebGPU::Metal::releaseToAPI(WebGPU::Metal::Texture::createInvalid(protectedDevice));
    }
    return WebGPU::Metal::releaseToAPIAs<WebGPU::Metal::Texture>(protectedDevice->createTexture(*apiDescriptor));
}

void wgpuDeviceDestroy(WGPUDevice device)
{
    protect(WebGPU::Metal::fromAPI(device))->destroy();
}

// The chained structs of limits are not filled in.
WGPUStatus wgpuDeviceGetLimits(WGPUDevice device, WGPULimits* limits)
{
    auto* nextInChain = limits->nextInChain;
    *limits = WebGPU::Metal::toAPI(WebGPU::Metal::fromAPI(device).limits());
    limits->nextInChain = nextInChain;
    return WGPUStatus_Success;
}

// The caller owns the reference to the adapter, as for every object the C API returns.
WGPUAdapter wgpuDeviceGetAdapter(WGPUDevice device)
{
    return WebGPU::Metal::releaseToAPI(Ref { WebGPU::Metal::fromAPI(device).adapter() });
}

// The caller owns the reference to the queue, as for every object the C API returns.
WGPUQueue wgpuDeviceGetQueue(WGPUDevice device)
{
    return WebGPU::Metal::releaseToAPI(WebGPU::Metal::fromAPI(device).getQueue());
}

WGPUBool wgpuDeviceHasFeature(WGPUDevice device, WGPUFeatureName feature)
{
    auto apiFeature = WebGPU::Metal::fromAPI(feature);
    return apiFeature && protect(WebGPU::Metal::fromAPI(device))->hasFeature(*apiFeature);
}

// A scope that could not be popped is WGPUPopErrorScopeStatus_Error.
WGPUFuture wgpuDevicePopErrorScope(WGPUDevice device, WGPUPopErrorScopeCallbackInfo callbackInfo)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    WebGPU::Metal::CAPIFuture future { protectedDevice->instance() };
    protectedDevice->popErrorScope([callbackInfo, future](bool succeeded, std::optional<WebGPU::Error>&& error) {
        if (error) {
            auto message = error->message.utf8();
            callbackInfo.callback(WGPUPopErrorScopeStatus_Success, WebGPU::Metal::toAPI(error), WebGPU::Metal::toAPI(message), callbackInfo.userdata1, callbackInfo.userdata2);
        } else if (succeeded)
            callbackInfo.callback(WGPUPopErrorScopeStatus_Success, WGPUErrorType_NoError, WebGPU::Metal::toAPI(""_s), callbackInfo.userdata1, callbackInfo.userdata2);
        else
            callbackInfo.callback(WGPUPopErrorScopeStatus_Error, WGPUErrorType_NoError, WebGPU::Metal::toAPI("popErrorScope() failed validation."_s), callbackInfo.userdata1, callbackInfo.userdata2);
        future.complete();
    });
    return future.future();
}

void wgpuDevicePushErrorScope(WGPUDevice device, WGPUErrorFilter filter)
{
    Ref protectedDevice = WebGPU::Metal::fromAPI(device);
    auto apiFilter = WebGPU::Metal::fromAPI(filter);
    if (!apiFilter) {
        protectedDevice->generateAValidationError("pushErrorScope: invalid error filter"_s);
        return;
    }
    protectedDevice->pushErrorScope(*apiFilter);
}

void wgpuDeviceSetLabel(WGPUDevice device, WGPUStringView label)
{
    WebGPU::Metal::fromAPI(device).setLabel(WebGPU::Metal::fromAPI(label));
}
