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

#import "BindGroup.h"
#import "Buffer.h"
#import "CommandEncoder.h"
#import "ComputePipeline.h"
#import "PresentationContext.h"
#import "Queue.h"
#import "RenderBundleEncoder.h"
#import "RenderPipeline.h"
#import "ShaderModule.h"
#import "Texture.h"
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
#endif

namespace WebGPU::Metal {

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

void logTimestampsWhenCompleted(id<MTLCommandBuffer> commandBuffer, NSMutableArray *resolvedBuffers, void (^didLog)(void))
{
    [commandBuffer addCompletedHandler:[resolvedBuffers = RetainPtr { resolvedBuffers }, didLog = makeBlockPtr(didLog)](id<MTLCommandBuffer>) {
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
        didLog();
    }];
}

#if PLATFORM(MAC)
id<NSObject> addDeviceObserver(id<MTLDevice> device, void (^deviceWasNotified)(void))
{
    id<NSObject> deviceObserver = nil;
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    auto devices = MTLCopyAllDevicesWithObserver(&deviceObserver, [device = RetainPtr { device }, deviceWasNotified = makeBlockPtr(deviceWasNotified)](id<MTLDevice> notifiedDevice, MTLDeviceNotificationName) {
        if ([notifiedDevice isEqual:device.get()])
            deviceWasNotified();
    });
    ALLOW_DEPRECATED_DECLARATIONS_END

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
    return deviceObserver;
}

void removeDeviceObserver(id<NSObject> deviceObserver)
{
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    MTLRemoveDeviceObserver(deviceObserver);
    ALLOW_DEPRECATED_DECLARATIONS_END
}
#endif

} // namespace WebGPU::Metal
