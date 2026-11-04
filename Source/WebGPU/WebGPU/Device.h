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
namespace WebGPUSwift {
class DeviceImpl;
}
#endif

namespace WebGPU::Metal {

class Instance;

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

// The debug encoder timestamps: logs `resolvedBuffers`, which hold MTLCounterResultTimestamps, when `commandBuffer`
// completes, then hands the command buffer to `forget` on the API thread.
void logTimestampsWhenCompleted(id<MTLCommandBuffer>, NSMutableArray *resolvedBuffers, Queue&, void (^forget)(id<MTLCommandBuffer>));

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
// The state is in DeviceImpl, except the device-observer registration, which observer threads use.
class Device final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<Device> {
    WTF_MAKE_TZONE_ALLOCATED(Device);
public:
    static Ref<Device> create(id<MTLDevice>, String&& deviceLabel, HardwareCapabilities&&, Adapter&);
    static Ref<Device> createInvalid(Adapter&);

    ~Device();

    void destroy();
    Ref<Queue> getQueue() const;
#if !defined(__swift__)
    bool hasFeature(WebGPU::FeatureName) const;
#endif

    bool LEGACY_NODELETE isValid() const;
    bool isLost() const;
#if !defined(__swift__)
    WebGPUSwift::DeviceImpl& swiftImpl() const LIFETIME_BOUND;
#endif
    id<MTLCounterSet> timestampCounterSet() const;
    uint32_t memoryBarrierLimit() const;
    bool supportsNonPrivateDepthStencilTextures() const;
    bool supportsMemorylessTextures() const;

#if !defined(__swift__)
    id<MTLDevice> _Nullable device() const;
    void generateAValidationError(NSString * message);
    void generateAValidationError(String&& message);
#endif

    RefPtr<Instance> instance() const;
    Adapter& adapter() const;
#if !defined(__swift__)
#if CPU(X86_64)
    bool hasUnifiedMemory() const { return false; }
#else
    bool hasUnifiedMemory() const { return device().hasUnifiedMemory; }
#endif
    bool isShaderValidationEnabled() const;
#endif

    bool LEGACY_NODELETE shouldStopCaptureAfterSubmit();
    id<MTLBuffer> placeholderBuffer() const;

    bool LEGACY_NODELETE isDestroyed() const;
#if !defined(__swift__)
    id<MTLBuffer> safeCreateBuffer(NSUInteger length, MTLStorageMode, bool skipMemoryAttribution = false, MTLCPUCacheMode = MTLCPUCacheModeDefaultCache, MTLHazardTrackingMode = MTLHazardTrackingModeDefault) const;
    id<MTLBuffer> safeCreateBuffer(NSUInteger, bool skipMemoryAttribution = false) const;
    void loseTheDevice(WebGPU::DeviceLostReason);
#endif
    bool LEGACY_NODELETE pauseErrorReporting(bool pauseReporting);
    bool enableEncoderTimestamps() const;
    // Nil once the device is lost.
    id<MTLSharedEvent> _Nullable resolveTimestampsSharedEvent();
    uint32_t maxVerticesPerDrawCall() const;

    static constexpr uint64_t maxBindGroups = (1ull << 5);
    uint32_t appleGPUFamily() const;

private:
    Device(id<MTLDevice>, id<MTLCommandQueue> defaultQueue, const HardwareCapabilities&, Adapter&);
    explicit Device(Adapter&);

    // First, so it is built before and destroyed after everything the constructor/destructor hand `*this` to.
    const std::unique_ptr<DeviceImplBox> m_impl;
} SWIFT_SHARED_REFERENCE(refDevice, derefDevice);

// Device::create(), for Swift, which can't pass rvalue references.
Ref<Device> createDevice(id<MTLDevice>, const String& label, const HardwareCapabilities&, Adapter&);

} // namespace WebGPU::Metal

inline void refDevice(WebGPU::Metal::Device* obj)
{
    obj->ref();
}

inline void derefDevice(WebGPU::Metal::Device* obj)
{
    obj->deref();
}

IGNORE_CLANG_WARNINGS_END
