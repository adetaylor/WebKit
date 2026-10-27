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
#import "Adapter.h"

#import "APIConversions.h"
#import "Device.h"
#import "Instance.h"
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct AdapterImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(AdapterImplBox);
    WebGPU::AdapterImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(AdapterImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(Adapter);

Ref<Adapter> Adapter::create(id<MTLDevice> device, Instance& instance, bool xrCompatible, HardwareCapabilities&& capabilities)
{
    auto box = makeUnique<AdapterImplBox>(AdapterImplBox { .impl = makeAdapterImpl(device, xrCompatible, capabilities) });
    return adoptRef(*new Adapter(WTF::move(box), instance));
}

Adapter::Adapter(std::unique_ptr<AdapterImplBox>&& impl, Instance& instance)
    : m_impl(WTF::move(impl))
    , m_instance(&instance)
{
}

Adapter::~Adapter() = default;

WebGPU::Limits Adapter::limits() const
{
    return m_impl->impl.limits();
}

MachSendRight Adapter::webProcessIdentity() const
{
    RefPtr instance = m_instance;
    if (!instance)
        return { };
    auto webProcessID = instance->webProcessID();
    if (!webProcessID)
        return { };
    return MachSendRight { WTF::move(*webProcessID) };
}

Vector<WebGPU::FeatureName> Adapter::features() const
{
    Vector<WebGPU::FeatureName> features;
    m_impl->impl.copyFeatures(features);
    return features;
}

WebGPU::AdapterInfo Adapter::info()
{
    WebGPU::AdapterInfo info {
        .name = device().name,
        // A Metal device is never a fallback (software) adapter.
        .isFallbackAdapter = false,
    };
    m_impl->impl.subgroupSizes(info.subgroupMinSize, info.subgroupMaxSize);
    return info;
}

bool Adapter::hasFeature(WebGPU::FeatureName feature)
{
    return m_impl->impl.hasFeature(feature);
}

void Adapter::requestDevice(const WebGPU::DeviceDescriptor& descriptor, CompletionHandler<void(RefPtr<WebGPU::Device>&&)>&& callback)
{
    requestDeviceOrError(descriptor, [callback = WTF::move(callback)](std::expected<Ref<Device>, String>&& device) mutable {
        callback(device ? RefPtr<WebGPU::Device> { WTF::move(*device) } : nullptr);
    });
}

void Adapter::requestDeviceOrError(const WebGPU::DeviceDescriptor& descriptor, CompletionHandler<void(std::expected<Ref<Device>, String>&&)>&& callback)
{
    HardwareCapabilities capabilities { .features = { descriptor.requiredFeatures } };
    bool invalidatesAdapter = false;
    if (NSString* error = m_impl->impl.errorRequestingDevice(descriptor.requiredLimits.has_value(), descriptor.requiredLimits.value_or(Limits { }), capabilities, invalidatesAdapter)) {
        callback(makeUnexpected(String(error)));
        if (invalidatesAdapter)
            makeInvalid();
        return;
    }

    auto label = descriptor.label;
    // FIXME: this should be asynchronous - https://bugs.webkit.org/show_bug.cgi?id=233621
    callback(Device::create(device(), WTF::move(label), WTF::move(capabilities), *this));
}

void Adapter::setLabel(String&&)
{
}

bool Adapter::isValid() const
{
    return m_impl->impl.isValid();
}

id<MTLDevice> Adapter::device() const
{
    return m_impl->impl.device();
}

void Adapter::makeInvalid()
{
    m_impl->impl.makeInvalid();
}

bool Adapter::isXRCompatible() const
{
    return m_impl->impl.isXRCompatible();
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

// The caller owns the reference to the instance. Null when the instance is gone.
WGPUInstance wgpuAdapterGetInstance(WGPUAdapter adapter)
{
    return WebGPU::Metal::releaseToAPI(protect(WebGPU::Metal::fromAPI(adapter))->instance());
}

void LEGACY_NODELETE wgpuAdapterAddRef(WGPUAdapter adapter)
{
    WebGPU::Metal::fromAPI(adapter).ref();
}

void wgpuAdapterRelease(WGPUAdapter adapter)
{
    WebGPU::Metal::fromAPI(adapter).deref();
}

// The chained structs of limits are not filled in.
WGPUStatus wgpuAdapterGetLimits(WGPUAdapter adapter, WGPULimits* limits)
{
    auto* nextInChain = limits->nextInChain;
    *limits = WebGPU::Metal::toAPI(protect(WebGPU::Metal::fromAPI(adapter))->limits());
    limits->nextInChain = nextInChain;
    return WGPUStatus_Success;
}

// The strings of info are freed with wgpuAdapterInfoFreeMembers().
WGPUStatus wgpuAdapterGetInfo(WGPUAdapter adapter, WGPUAdapterInfo* info)
{
    Ref protectedAdapter = WebGPU::Metal::fromAPI(adapter);
    auto apiInfo = protectedAdapter->info();
    id<MTLDevice> device = protectedAdapter->device();
    // FIXME: What should the vendorID and deviceID be?
    info->vendor = WebGPU::Metal::toAPIAllocated(emptyString());
    info->architecture = WebGPU::Metal::toAPIAllocated(emptyString());
    info->device = WebGPU::Metal::toAPIAllocated(apiInfo.name);
    info->description = WebGPU::Metal::toAPIAllocated(emptyString());
    info->backendType = WGPUBackendType_Metal;
    info->adapterType = device.hasUnifiedMemory ? WGPUAdapterType_IntegratedGPU : WGPUAdapterType_DiscreteGPU;
    info->vendorID = 0;
    info->deviceID = 0;
    info->subgroupMinSize = apiInfo.subgroupMinSize;
    info->subgroupMaxSize = apiInfo.subgroupMaxSize;
    return WGPUStatus_Success;
}

void wgpuAdapterInfoFreeMembers(WGPUAdapterInfo info)
{
    WebGPU::Metal::freeAllocated(info.vendor);
    WebGPU::Metal::freeAllocated(info.architecture);
    WebGPU::Metal::freeAllocated(info.device);
    WebGPU::Metal::freeAllocated(info.description);
}

WGPUBool wgpuAdapterHasFeature(WGPUAdapter adapter, WGPUFeatureName feature)
{
    auto apiFeature = WebGPU::Metal::fromAPI(feature);
    return apiFeature && protect(WebGPU::Metal::fromAPI(adapter))->hasFeature(*apiFeature);
}

// The C API reports a device that could not be created with WGPURequestDeviceStatus_Error and no
// device. A null descriptor is the default one.
WGPUFuture wgpuAdapterRequestDevice(WGPUAdapter adapter, const WGPUDeviceDescriptor* descriptor, WGPURequestDeviceCallbackInfo callbackInfo)
{
    Ref protectedAdapter = WebGPU::Metal::fromAPI(adapter);
    WebGPU::Metal::CAPIFuture future { protectedAdapter->instance() };
    auto callback = [callbackInfo, future](WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message) {
        callbackInfo.callback(status, device, message, callbackInfo.userdata1, callbackInfo.userdata2);
        future.complete();
    };
    WGPUDeviceDescriptor defaultDescriptor = WGPU_DEVICE_DESCRIPTOR_INIT;
    WebGPU::Metal::DeviceDescriptorStorage storage;
    auto apiDescriptor = WebGPU::Metal::fromAPI(descriptor ? *descriptor : defaultDescriptor, storage);
    if (!apiDescriptor) {
        callback(WGPURequestDeviceStatus_Error, nullptr, WebGPU::Metal::toAPI("Device does not support requested features"_s));
        return future.future();
    }
    protectedAdapter->requestDeviceOrError(*apiDescriptor, [callback = WTF::move(callback)](std::expected<Ref<WebGPU::Metal::Device>, String>&& device) {
        if (!device) {
            auto message = device.error().utf8();
            return callback(WGPURequestDeviceStatus_Error, nullptr, WebGPU::Metal::toAPI(message));
        }
        callback(WGPURequestDeviceStatus_Success, WebGPU::Metal::releaseToAPI(WTF::move(*device)), WebGPU::Metal::toAPI(""_s));
    });
    return future.future();
}
