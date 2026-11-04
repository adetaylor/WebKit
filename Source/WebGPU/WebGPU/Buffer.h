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
#import "Device.h"
#import "Instance.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <optional>
#import <utility>
#import <wtf/CanBorrow.h>
#import <wtf/Compiler.h>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Function.h>
#import <wtf/HashMap.h>
#import <wtf/Range.h>
#import <wtf/RangeSet.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakHashSet.h>
#import <wtf/WeakPtr.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebGPU::Metal {

class Queue;

// Create-time values handed to Swift by value.
struct BufferParameters {
    uint64_t size { 0 };
    uint16_t usage { 0 }; // OptionSet<WebGPU::BufferUsage>::toRaw()
    bool mappedAtCreation { false };
};

// The slow index validation paths' GPU waits and read-backs, for Buffer.swift: whether the indices are valid.
bool verifyIndexBufferForSlowPath(Queue&, id<MTLBuffer> _Nullable indexBuffer, uint32_t firstIndex, uint32_t indexCount, bool isUInt16, uint32_t primitiveOffset, uint32_t vertexCount);
// For a reused indexed indirect draw of a render bundle: whether every index from indexBufferOffset on stays in bounds
// as the clamp shader checks it, with the baseVertex of the arguments at indirectOffset of indirectBuffer, which is nil
// when those are not the arguments the draw's slot was baked with.
bool verifyBundleIndirectDrawIndexBufferForSlowPath(Queue&, id<MTLBuffer> _Nullable indexBuffer, id<MTLBuffer> _Nullable indirectBuffer, uint64_t indirectOffset, uint64_t indexBufferOffset, bool isUInt16, uint32_t vertexCount, uint32_t primitiveOffset);
// Clears the buffer through the queue. Returns its prior contents, to write back once the command buffer
// completed (BufferImpl.restoreIndexBufferContents).
NSMutableData* _Nullable clearIndexBufferContents(Queue&, id<MTLBuffer> _Nullable);
// For Swift, which can't reach a buffer's contents: copies the bytes at that offset into destination, which must lie
// within the contents, as a mapped range Swift has reserved does.
void readBufferContents(id<MTLBuffer> _Nullable, uint64_t offset, std::span<uint8_t> destination NOESCAPE);
// Copies data into the contents at that offset. Returns false, copying nothing, if the contents are empty or don't hold
// it there.
bool writeBufferContentsIfInBounds(id<MTLBuffer> _Nullable, uint64_t offset, std::span<const uint8_t> data NOESCAPE);

#if !defined(__swift__)
// The bytes of a buffer the CPU writes into: the staging and temporary buffers the queue copies through, and a render
// bundle's dynamic-offset buffers, whose storage is shared or managed. RELEASE_ASSERTs that a non-empty buffer has
// contents. Empty for nil.
std::span<uint8_t> cpuVisibleContents(id<MTLBuffer>);
#endif

} // namespace WebGPU::Metal

IGNORE_CLANG_WARNINGS_END
