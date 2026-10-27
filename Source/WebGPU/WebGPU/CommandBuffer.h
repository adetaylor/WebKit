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

#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/RetainPtr.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class CommandBufferImpl;
}
#endif

namespace WebGPU::Metal {

class CommandEncoder;
class Device;

// Opaque box holding the Swift CommandBufferImpl; defined in CommandBuffer.mm.
struct CommandBufferImplBox;

// https://gpuweb.github.io/gpuweb/#gpucommandbuffer
// The state is in CommandBufferImpl; the shell registers the Metal completion handler.
class CommandBuffer final : public WebGPU::CommandBuffer {
    WTF_MAKE_TZONE_ALLOCATED(CommandBuffer);
public:
    static Ref<CommandBuffer> create(id<MTLCommandBuffer>, Device&, id<MTLSharedEvent>, uint64_t sharedEventSignalValue, CommandEncoder&);
    static Ref<CommandBuffer> createInvalid(Device&);

    ~CommandBuffer();

    void setLabel(String&&) final;

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::CommandBufferImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    id<MTLCommandBuffer> commandBuffer() const;

#if !defined(__swift__)
    // Borrowed from the Impl, which holds the reference. On the API thread only.
    Device& device() const;
#endif
    void makeInvalid(NSString*);
    void setBufferMapCount(int);
    int bufferMapCount() const;

    NSString* lastError() const;
    bool waitForCompletion();

    double gpuExecutionDurationSeconds() const;

    // For Queue.swift, just before the queue commits the command buffer CommandBufferImpl::willCommit() returned.
    void registerCompletedHandler(id<MTLCommandBuffer>);

private:
    explicit CommandBuffer(std::unique_ptr<CommandBufferImplBox>&&);

    // API thread only. The Metal completion handler captures the box's CommandBufferCompletion, which is Sendable,
    // instead.
    const std::unique_ptr<CommandBufferImplBox> m_impl;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(refCommandBuffer, derefCommandBuffer);

} // namespace WebGPU::Metal

#if !ENABLE(SWIFT_BASE_CLASS_ANNOTATIONS)
inline void refCommandBuffer(WebGPU::Metal::CommandBuffer* obj)
{
    obj->ref();
}

inline void derefCommandBuffer(WebGPU::Metal::CommandBuffer* obj)
{
    obj->deref();
}
#endif
