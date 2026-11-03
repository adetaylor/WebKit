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

#if !defined(__swift__)
namespace WebGPUSwift {
class BufferImpl;
}
#endif

namespace WebGPU::Metal {

class Buffer;
class CommandEncoder;
class Device;

// Create-time values handed to Swift by value.
struct BufferParameters {
    uint64_t size { 0 };
    uint16_t usage { 0 }; // OptionSet<WebGPU::BufferUsage>::toRaw()
    bool mappedAtCreation { false };
};

// The slow index validation paths' GPU waits and read-backs, for Buffer.swift: whether the indices are valid.
bool verifyIndexBufferForSlowPath(Buffer&, uint32_t firstIndex, uint32_t indexCount, bool isUInt16, uint32_t primitiveOffset, uint32_t vertexCount);
// For a reused indexed indirect draw of a render bundle: whether every index from indexBufferOffset on stays in bounds
// as the clamp shader checks it, with the baseVertex of the arguments at indirectOffset of indirectBuffer, which is nil
// when those are not the arguments the draw's slot was baked with.
bool verifyBundleIndirectDrawIndexBufferForSlowPath(Buffer&, id<MTLBuffer> _Nullable indirectBuffer, uint64_t indirectOffset, uint64_t indexBufferOffset, bool isUInt16, uint32_t vertexCount, uint32_t primitiveOffset);
// Clears the buffer through the queue. Returns its prior contents, to write back once the command buffer
// completed (restoreIndexBufferContents).
NSMutableData* clearIndexBufferContents(Buffer&);
void restoreIndexBufferContents(Buffer&, NSMutableData*);
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

// Opaque box holding the Swift BufferImpl; defined in Buffer.mm.
struct BufferImplBox;

// https://gpuweb.github.io/gpuweb/#gpubuffer
// Swift's BufferImpl owns the state and the Device back-reference, and runs creation and mapping; the shell forms the
// spans over the contents.
class Buffer final : public WebGPU::Buffer, public CanBorrow {
    WTF_MAKE_TZONE_ALLOCATED(Buffer);
public:
    enum class State : uint8_t;

    static Ref<Buffer> createInvalid(Device&);
    // Wraps the Impl that Swift staged in DeviceImpl, for a creation made in Swift.
    static Ref<Buffer> createWithStagedImpl(Device&);
#if !defined(__swift__)
    static Ref<Buffer> create(const WebGPUSwift::BufferImpl&);
#endif

    ~Buffer();

    void destroy() final;
    void mapAsync(OptionSet<WebGPU::MapMode>, uint64_t offset, std::optional<uint64_t> size, CompletionHandler<void(bool)>&&) final;
    void getMappedRange(uint64_t offset, std::optional<uint64_t> size, NOESCAPE const Function<void(std::span<uint8_t>)>&) final;
    void copyFrom(std::span<const uint8_t>, size_t offset) final;
    // The mapped range as a span, for the C API. The C++ API has getMappedRange() instead,
    // because a proxy cannot return a pointer into the mapping.
    std::span<uint8_t> getMappedRangeSpan(uint64_t offset, std::optional<uint64_t> size);
    // The mapped range for the C API, which, unlike the JavaScript API, lets the ranges that it hands
    // out overlap: they are pointers into the mapping, not ArrayBuffers that are detached on unmap.
    std::span<uint8_t> mappedRangeForCAPI(uint64_t offset, std::optional<uint64_t> size);
    void unmap() final;
    void setLabel(String&&) final;
    void generateAValidationError() final;
    void generateAValidationError(String&&);

    bool isValid() const final;
#if !defined(__swift__)
    WebGPUSwift::BufferImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    // https://gpuweb.github.io/gpuweb/#buffer-state
    enum class State : uint8_t {
        Mapped,
        MappedAtCreation,
        MappingPending,
        Unmapped,
        Destroyed,
    };

#if !defined(__swift__)
    id<MTLBuffer> buffer() const;
    OptionSet<WebGPU::BufferUsage> usage() const;
    State state() const;
#endif

    uint64_t initialSize() const;

    // Borrowed from the Impl, which holds the reference.
    Device& device() const;

    std::span<uint8_t> getBufferContents() final;

    // For the drawIndexed completion handlers' work items (RenderPassEncoder.mm).
    void drawIndexedValidated(uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, int32_t baseVertex, MTLIndexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLIndirectCommandBuffer> = nil);
    bool didReadOOB(id<MTLIndirectCommandBuffer> = nil) const;
    void didReadOOB(uint32_t v, id<MTLIndirectCommandBuffer> = nil);

    // Bumped whenever the contents change in a way that invalidates a previously GPU-encoded indirect draw.
    uint64_t contentsGeneration() const;
    uint64_t indexContentsGeneration() const;
    bool allIndexValuesBelow(MTLIndexType, uint32_t vertexCount) const;

private:
    explicit Buffer(std::unique_ptr<BufferImplBox>&&);

    const std::unique_ptr<BufferImplBox> m_impl;
} SWIFT_SHARED_REFERENCE(refBuffer, derefBuffer) SWIFT_PRIVATE_FILEID("WebGPUSwift/Buffer.swift") SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

// The shell as the C++ API object it is, for Swift, which can't convert a shared reference to its base class.
inline WebGPU::Buffer& apiObject(Buffer& shell) SWIFT_RETURNS_UNRETAINED { return shell; }

} // namespace WebGPU::Metal

inline void refBuffer(WebGPU::Metal::Buffer* obj)
{
    obj->ref();
}

inline void derefBuffer(WebGPU::Metal::Buffer* obj)
{
    obj->deref();
}

IGNORE_CLANG_WARNINGS_END
