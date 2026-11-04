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

namespace WebGPU::Metal {

// The messages DeviceImpl gives the device-lost callback (Swift cannot spell an ASCIILiteral).
inline String deviceLostMessage() { return "Device lost."_s; }
inline String deviceDestroyedMessage() { return ""_s; }

// WTFLogAlways("%@", message), for Swift, which cannot call a C variadic macro.
void logAlways(NSString *message);

// The debug encoder timestamps: logs `resolvedBuffers`, which hold MTLCounterResultTimestamps, when `commandBuffer`
// completes, then calls didLog on the Metal thread.
void logTimestampsWhenCompleted(id<MTLCommandBuffer>, NSMutableArray *resolvedBuffers, void (^ NS_SWIFT_SENDABLE didLog)(void));

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

#if PLATFORM(MAC)
// The macOS device observer, for DeviceImpl: deviceWasNotified runs on an observer thread for each notification about
// the device. Returns the observer's token, which removeDeviceObserver() takes.
id<NSObject> _Nullable addDeviceObserver(id<MTLDevice>, void (^ NS_SWIFT_SENDABLE deviceWasNotified)(void));
void removeDeviceObserver(id<NSObject>);
#endif

} // namespace WebGPU::Metal

IGNORE_CLANG_WARNINGS_END
