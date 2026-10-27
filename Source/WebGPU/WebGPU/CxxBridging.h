/*
 * Copyright (c) 2025 Apple Inc. All rights reserved.
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

#include "BindGroup.h"
#include "Buffer.h"
#include "CommandBuffer.h"
#include "ComputePassEncoder.h"
#include "Instance.h"
#include "IsValidToUseWith.h"
#include "RenderPassEncoder.h"
#include "Texture.h"
#include <optional>
#include <span>
#include <wtf/CheckedArithmetic.h>
#include <wtf/Function.h>
#include <wtf/MachSendRight.h>
#include <wtf/MathExtras.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/text/WTFString.h>

inline unsigned long roundUpToMultipleOfNonPowerOfTwoCheckedUInt32UnsignedLong(Checked<uint32_t> x, unsigned long y) { return WTF::roundUpToMultipleOfNonPowerOfTwo(x, y); }
inline uint32_t roundUpToMultipleOfNonPowerOfTwoUInt32UInt32(uint32_t a, uint32_t b) { return WTF::roundUpToMultipleOfNonPowerOfTwo<uint32_t, Checked<uint32_t>>(a, b); }

namespace CxxBridging {

using RefComputePassEncoder = Ref<WebGPU::Metal::ComputePassEncoder>;
using RefRenderPassEncoder = Ref<WebGPU::Metal::RenderPassEncoder>;
using RefCommandBuffer = Ref<WebGPU::Metal::CommandBuffer>;

// The types of the Instance's scheduler and web process ID (Instance.swift).
using InstanceWorkItem = Function<void()>;
using InstanceScheduleWork = Function<void(Function<void()>&&)>;
using FutureCompletedHandler = Function<void(size_t)>;
using OptionalMachSendRight = std::optional<MachSendRight>;

// waitForAnyFuture()'s futures, borrowed for the duration of the call: a nonescapable view whose span() Swift reads as a
// lifetime-checked Span.
struct FutureIDsView {
    std::span<const uint64_t> futureIDs;

    std::span<const uint64_t> span() const LIFETIME_BOUND { return futureIDs; }
} SWIFT_VIEW;

// The render and compute pass descriptors' query sets and attachments, which Swift cannot resolve to their Impls.
inline bool isValidToUseWithQuerySet(const WebGPU::Metal::QuerySet& querySet, const WebGPU::Metal::Device& device)
{
    return WebGPU::Metal::isValidToUseWithDevice(querySet, device);
}

inline bool isValidToUseWith(const WebGPU::Metal::TextureOrTextureView& texture, const WebGPU::Metal::Device& device)
{
    return WebGPU::Metal::isValidToUseWithDevice(texture, device);
}

// FIXME: rdar://130765784 (=== does not accept foreign reference types)
inline bool areDevicesEqual(const WebGPU::Metal::Device& a, const WebGPU::Metal::Device& b)
{
    return &a == &b;
}

// The device's Instance, +1, or nullptr once it is gone.
inline WebGPU::Metal::Instance* protectedInstance(const WebGPU::Metal::Device& device) SWIFT_RETURNS_RETAINED
{
    return device.instance().leakRef();
}

inline NSString * convertWTFStringToNSString(const String& input)
{
    return nsStringNilIfEmpty(input).autorelease();
}

using CommandBufferWeakPtr = ThreadSafeWeakPtr<WebGPU::Metal::CommandBuffer>;
using BufferWeakPtr = ThreadSafeWeakPtr<WebGPU::Metal::Buffer>;
using TextureWeakPtr = ThreadSafeWeakPtr<WebGPU::Metal::Texture>;

inline CommandBufferWeakPtr commandBufferThreadSafeWeakPtr(const WebGPU::Metal::CommandBuffer* input)
{
    return ThreadSafeWeakPtr(input);
}

// The references BufferImpl and TextureImpl keep to the shells that own them, to hand an encoder a strong reference.
// Weak, because a shell can be destroyed on a Metal thread while the API thread still reaches its Impl.
inline BufferWeakPtr bufferThreadSafeWeakPtr(const WebGPU::Metal::Buffer* input)
{
    return ThreadSafeWeakPtr(input);
}

inline TextureWeakPtr textureThreadSafeWeakPtr(const WebGPU::Metal::Texture* input)
{
    return ThreadSafeWeakPtr(input);
}

// nullptr once the shell's last reference is gone.
inline WebGPU::Metal::Buffer* protectedBuffer(const BufferWeakPtr& shell) SWIFT_RETURNS_RETAINED
{
    return shell.get().leakRef();
}

inline WebGPU::Metal::Texture* protectedTexture(const TextureWeakPtr& shell) SWIFT_RETURNS_RETAINED
{
    return shell.get().leakRef();
}

inline bool isTextureGone(const TextureWeakPtr& shell)
{
    return !shell.get();
}

// The bind groups that hold a Buffer or Texture, held by BufferImpl and TextureImpl on the API thread. A bind group can
// die on a Metal thread, so these are weak references to the shells, kept in C++: a Swift weak reference would give each
// BindGroupImpl a side table, and ThreadSafeWeakPtrs in a Swift array would go through value witnesses. A dead entry at
// the sweeping cursor is replaced in place, so the list stays within one sweep of its live count.
class BindGroupHolders {
    WTF_MAKE_NONCOPYABLE(BindGroupHolders);
public:
    BindGroupHolders() = default;
    BindGroupHolders(BindGroupHolders&&) = default;
    BindGroupHolders& operator=(BindGroupHolders&&) = default;

    // A group registers with a resource once per record, so a repeat is the last addition.
    void add(const WebGPU::Metal::BindGroup& bindGroup)
    {
        auto identity = reinterpret_cast<uintptr_t>(&bindGroup);
        if (m_lastAdded < m_entries.size() && m_entries[m_lastAdded].identity == identity && m_entries[m_lastAdded].bindGroup.get())
            return;
        Entry entry { ThreadSafeWeakPtr { bindGroup }, identity };
        if (m_cursor < m_entries.size()) {
            auto index = m_cursor++;
            if (!m_entries[index].bindGroup.get()) {
                m_entries[index] = WTF::move(entry);
                m_lastAdded = index;
                return;
            }
        } else
            m_cursor = 0;
        m_lastAdded = m_entries.size();
        m_entries.append(WTF::move(entry));
    }

    // For a destroyed resource: every live group's releaseDestroyedResources(), then none.
    void releaseDestroyedResourcesAndClear()
    {
        Vector<Ref<WebGPU::Metal::BindGroup>> bindGroups;
        for (auto& entry : m_entries) {
            if (RefPtr bindGroup = entry.bindGroup)
                bindGroups.append(bindGroup.releaseNonNull());
        }
        for (auto& bindGroup : bindGroups)
            bindGroup->releaseDestroyedResources();
        m_entries.clear();
        m_cursor = 0;
        m_lastAdded = std::numeric_limits<unsigned>::max();
    }

private:
    struct Entry {
        ThreadSafeWeakPtr<WebGPU::Metal::BindGroup> bindGroup;
        // The shell's address when added, compared before anything takes a lock; a match is confirmed by the group
        // being alive, so a reused address is never taken for it.
        uintptr_t identity { 0 };
    };
    Vector<Entry> m_entries;
    unsigned m_cursor { 0 };
    unsigned m_lastAdded { std::numeric_limits<unsigned>::max() };
} SWIFT_SELF_CONTAINED;

// CommandEncoderImpl's cached command buffer, which can die on a Metal thread (so it is not a Swift weak reference).
// Each does nothing once the command buffer is gone.
inline void makeCommandBufferInvalid(const CommandBufferWeakPtr& commandBuffer, NSString* errorString)
{
    if (RefPtr protectedCommandBuffer = commandBuffer)
        protectedCommandBuffer->makeInvalid(errorString);
}

inline void setCommandBufferMapCount(const CommandBufferWeakPtr& commandBuffer, int bufferMapCount)
{
    if (RefPtr protectedCommandBuffer = commandBuffer)
        protectedCommandBuffer->setBufferMapCount(bufferMapCount);
}

// Returns false when the wait timed out. The GPU duration is 0 without a command buffer.
inline bool waitForCommandBufferCompletion(const CommandBufferWeakPtr& commandBuffer, double& gpuExecutionDurationSeconds)
{
    gpuExecutionDurationSeconds = 0;
    RefPtr protectedCommandBuffer = commandBuffer;
    if (!protectedCommandBuffer)
        return true;
    bool completed = protectedCommandBuffer->waitForCompletion();
    gpuExecutionDurationSeconds = protectedCommandBuffer->gpuExecutionDurationSeconds();
    return completed;
}

}

#if !defined(__swift__)
namespace WebGPU::Metal {

// Swift returns foreign-reference objects to C++ retained (SWIFT_RETURNS_RETAINED). Borrows such a result
// from a Swift object that keeps its own reference, so the object outlives the caller's use.
template<typename T> T& borrowSwiftRetained(T* retained)
{
    retained->deref();
    return *retained;
}

} // namespace WebGPU::Metal
#endif
