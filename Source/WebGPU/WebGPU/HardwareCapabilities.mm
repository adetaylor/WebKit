/*
 * Copyright (c) 2023 Apple Inc. All rights reserved.
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
#import "HardwareCapabilities.h"

#import "APIConversions.h"
#import <sys/sysctl.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

bool isShaderValidationEnabled(id<MTLDevice> device)
{
    static bool result = [&] {
        // Workaround for rdar://141660277
        NSString* deviceName = NSStringFromClass([device class]);
        bool result = [deviceName containsString:@"Debug"] || [deviceName containsString:@"LegacySV"] || [deviceName containsString:@"CaptureMTLDevice"];
        if (result)
            WTFLogAlways("WebGPU: Using DEBUG Metal device: retaining references"); // NOLINT
        return result;
    }();
    return result;
}

bool isPhysicalHardware()
{
#if PLATFORM(IOS_FAMILY_SIMULATOR)
    return false;
#else
    static bool result = [] {
        uint32_t isVM = 0;
        size_t size = sizeof(isVM);
        if (!sysctlbyname("kern.hv_vmm_present", &isVM, &size, NULL, 0)) {
            if (isVM) {
                id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"WebKitAllowWebGPUOnVMs"];
                return value ? static_cast<bool>([value boolValue]) : true;
            }
            return true;
        }
        return true;
    }();
    return result;
#endif
}

std::optional<HardwareCapabilities> hardwareCapabilities(id<MTLDevice> device)
{
    HardwareCapabilities result;
    if (!computeHardwareCapabilities(device, result))
        return std::nullopt;
    return result;
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs
