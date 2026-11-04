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
#import "Instance.h"

#import "Adapter.h"
#import "Device.h"
#import "HardwareCapabilities.h"
#import "PresentationContext.h"
#import <wtf/BlockPtr.h>
#import <wtf/MachSendRight.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"

namespace WebGPU::Metal {

WTF_MAKE_TZONE_ALLOCATED_IMPL(Instance);

// Destroyed in reverse order: the embedder's scheduleWork first, then the web process ID and the retained
// CommandBuffers and Devices, and the work items still waiting for processEvents() last.
struct InstanceImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(InstanceImplBox);
    WebGPUSwift::InstanceEventQueue events;
    WebGPUSwift::InstanceImpl impl;
    WebGPUSwift::InstanceScheduler scheduler;
    WebGPUSwift::InstanceSchedulerHandle schedulerHandle;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(InstanceImplBox);

static NSArray<id<MTLDevice>>* getDevices()
{
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
#else
    NSMutableArray<id<MTLDevice>> *devices = [NSMutableArray array];
    if (id<MTLDevice> device = MTLCreateSystemDefaultDevice())
        [devices addObject:device];
#endif
    return devices;
}

Ref<Instance> Instance::create(WebGPU::InstanceDescriptor&& descriptor)
{
    auto events = WebGPUSwift::makeInstanceEventQueue();
    auto scheduler = descriptor.scheduleWork ? makeInstanceScheduler(descriptor.scheduleWork, events) : makeInstanceSchedulerWithoutEmbedder(events);
    auto box = makeUnique<InstanceImplBox>(InstanceImplBox { .events = events, .impl = WebGPUSwift::makeInstanceImpl(descriptor.webProcessResourceOwner), .scheduler = scheduler, .schedulerHandle = makeInstanceSchedulerHandle(scheduler) });
    return adoptRef(*new Instance(WTF::move(box)));
}

Instance::Instance(std::unique_ptr<InstanceImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

Instance::~Instance() = default;

bool Instance::isValid() const
{
    return true;
}

void Instance::waitForCommandBufferCompletions()
{
    m_impl->impl.waitForCommandBufferCompletions();
}

void Instance::scheduleWork(WorkItem&& workItem)
{
    m_impl->scheduler.scheduleWork(workItem);
}

WebGPUSwift::InstanceSchedulerHandle Instance::schedulerHandle() const
{
    return m_impl->schedulerHandle;
}

WebGPUSwift::InstanceImpl& Instance::swiftImpl() const
{
    return m_impl->impl;
}

std::optional<MachSendRight> Instance::webProcessID() const
{
    return m_impl->impl.webProcessID();
}

uint64_t Instance::createFuture()
{
    return m_impl->events.createFuture();
}

void Instance::completeFuture(uint64_t future)
{
    m_impl->events.completeFuture(future);
}

bool Instance::waitForAnyFuture(std::span<const uint64_t> futures, Seconds timeout, NOESCAPE const Function<void(size_t)>& didComplete)
{
    return m_impl->events.waitForAnyFuture(CxxBridging::FutureIDsView { futures }, timeout.value(), didComplete);
}

void Instance::processEvents()
{
    m_impl->events.processEvents();
}

static NSArray<id<MTLDevice>> *sortedDevices(NSArray<id<MTLDevice>> *devices, std::optional<WebGPU::PowerPreference> powerPreference)
{
    if (!powerPreference)
        return devices;
    switch (*powerPreference) {
    case WebGPU::PowerPreference::LowPower:
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
        return [devices sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult (id<MTLDevice> obj1, id<MTLDevice> obj2)
        {
            ALLOW_DEPRECATED_DECLARATIONS_BEGIN
            if (obj1.lowPower == obj2.lowPower)
                return NSOrderedSame;
            if (obj1.lowPower)
                return NSOrderedAscending;
            ALLOW_DEPRECATED_DECLARATIONS_END
            return NSOrderedDescending;
        }];
#else
        return devices;
#endif
    case WebGPU::PowerPreference::HighPerformance:
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
        return [devices sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult (id<MTLDevice> obj1, id<MTLDevice> obj2)
        {
            ALLOW_DEPRECATED_DECLARATIONS_BEGIN
            if (obj1.lowPower == obj2.lowPower)
                return NSOrderedSame;
            if (obj1.lowPower)
                return NSOrderedDescending;
            ALLOW_DEPRECATED_DECLARATIONS_END
            return NSOrderedAscending;
        }];
#else
        return devices;
#endif
    }
}

RefPtr<Adapter> Instance::adapter(const WebGPU::RequestAdapterOptions& options)
{
    auto devices = getDevices();

    // FIXME: Deal with options.compatibleSurface.

    auto sortedDevices = WebGPU::Metal::sortedDevices(devices, options.powerPreference);

    // There is no fallback adapter.
    if (options.forceFallbackAdapter || !sortedDevices || !sortedDevices.count || !sortedDevices[0])
        return nullptr;

    auto device = sortedDevices[0];

    // The device does not support WebGPU.
    auto deviceCapabilities = hardwareCapabilities(device);
    if (!deviceCapabilities)
        return nullptr;

    return Adapter::create(sortedDevices[0], *this, options.xrCompatible, WTF::move(*deviceCapabilities));
}

void Instance::retainDevice(Device& device, id<MTLCommandBuffer> commandBuffer)
{
    m_impl->impl.retainDevice(&device, reinterpret_cast<uintptr_t>(&device), commandBuffer);
}

Instance* createInstance(WebGPU::InstanceDescriptor& descriptor)
{
    return &Instance::create(WTF::move(descriptor)).leakRef();
}

Adapter* requestAdapter(Instance& instance, const WebGPU::RequestAdapterOptions& options)
{
    return instance.adapter(options).leakRef();
}

mach_port_t webProcessIdentityPort(const Instance& instance)
{
#if HAVE(IOSURFACE_SET_OWNERSHIP_IDENTITY) && HAVE(TASK_IDENTITY_TOKEN)
    if (const auto& webProcessID = instance.webProcessID())
        return webProcessID->sendRight();
#else
    UNUSED_PARAM(instance);
#endif
    return MACH_PORT_NULL;
}

} // namespace WebGPU::Metal

#else

namespace WebGPU {

// Without Swift there is no WebGPU implementation: a null instance means no WebGPU.
RefPtr<Instance> createInstance(InstanceDescriptor&&)
{
    return nullptr;
}

} // namespace WebGPU

#endif // ENABLE(WEBGPU_SWIFT)
