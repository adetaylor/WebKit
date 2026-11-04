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
#import <wtf/BlockPtr.h>
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
    WebGPUSwift::DeviceImpl impl;
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

void logTimestampsWhenCompleted(id<MTLCommandBuffer> commandBuffer, NSMutableArray *resolvedBuffers, Queue& queue, void (^forget)(id<MTLCommandBuffer>))
{
    // The handler, on a Metal thread, only logs the buffers it captured; it hands `forget` to a work item.
    [commandBuffer addCompletedHandler:[protectedQueue = Ref { queue }, resolvedBuffers = RetainPtr { resolvedBuffers }, forget = makeBlockPtr(forget)](id<MTLCommandBuffer> completedCommandBuffer) mutable {
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
        Queue& hop = protectedQueue.get();
        hop.scheduleWork([queue = WTF::move(protectedQueue), forget = WTF::move(forget), completedCommandBuffer = RetainPtr { completedCommandBuffer }] {
            forget(completedCommandBuffer.get());
        });
    }];
}

bool Device::enableEncoderTimestamps() const
{
    return WebGPUSwift::enableEncoderTimestamps();
}

bool Device::shouldStopCaptureAfterSubmit()
{
    return WebGPUSwift::shouldStopCaptureAfterSubmit();
}

bool Device::isDestroyed() const
{
    return m_impl->impl.isDestroyed();
}

bool Device::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPUSwift::DeviceImpl& Device::swiftImpl() const
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
    id<MTLCommandQueue> commandQueue = WebGPUSwift::makeDefaultCommandQueue(device, deviceLabel);
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
    auto box = makeUnique<DeviceImplBox>(DeviceImplBox { .impl = makeDeviceImpl(device, capabilities, &adapter, adapter.swiftImpl(), defaultQueue.ptr(), defaultQueue->swiftImpl()) });
    if (RefPtr instance = adapter.instance())
        box->impl.setInstanceSchedulerHandle(instance->schedulerHandle());
    return box;
}

Device::Device(id<MTLDevice> device, id<MTLCommandQueue> defaultQueue, const HardwareCapabilities& capabilities, Adapter& adapter)
    : m_impl(makeDeviceImplBox(device, Queue::create(defaultQueue, adapter, *this), capabilities, adapter))
{
    Ref xrSubImage = XRSubImage::create(*this);
    m_impl->impl.installXRSubImage(xrSubImage.ptr(), xrSubImage->swiftImpl());

#if PLATFORM(MAC)
    id<NSObject> deviceObserver = nil;
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    // Runs on an observer thread: it uses only the scheduler handle captured here, and hands its reference to the device
    // over to the work item, which releases it on the API thread.
    std::optional<WebGPUSwift::InstanceSchedulerHandle> scheduler;
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

    WebGPUSwift::registerForFrameCapture(device);
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

Ref<Device> createDevice(id<MTLDevice> device, const String& label, const HardwareCapabilities& capabilities, Adapter& adapter)
{
    return Device::create(device, String { label }, HardwareCapabilities { capabilities }, adapter);
}


} // namespace WebGPU::Metal
