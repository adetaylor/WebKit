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

#pragma once

#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/MachSendRight.h>
#import <wtf/Ref.h>
#import <wtf/Seconds.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/WeakPtr.h>


namespace WTF {
class MachSendRight;
}

#if !defined(__swift__)
namespace WebGPU {
class InstanceSchedulerHandle;
}
#endif

namespace WebGPU::Metal {

class Adapter;
class CommandBuffer;
class Device;
class PresentationContext;
class Texture;

// Box holding the Swift objects; defined in Instance.mm.
struct InstanceImplBox;

// https://gpuweb.github.io/gpuweb/#gpu
class Instance final : public WebGPU::Instance {
    WTF_MAKE_TZONE_ALLOCATED(Instance);
public:
    static Ref<Instance> create(WebGPU::InstanceDescriptor&&);

    virtual ~Instance();

    void processEvents();
    void requestAdapter(const WebGPU::RequestAdapterOptions&, CompletionHandler<void(RefPtr<WebGPU::Adapter>&&)>&&) final;
    RefPtr<WebGPU::PresentationContext> createPresentationContext(const WebGPU::PresentationContextDescriptor&) final;

    void setLabel(String&&) final { }
    bool isValid() const final;
    void retainDevice(Device&, id<MTLCommandBuffer>);
    void retainCommandBuffer(CommandBuffer&, id<MTLCommandBuffer>);
    void releaseCompletedCommandBuffers();
    void waitForCommandBufferCompletions();

    // This can be called on a background thread.
    using WorkItem = Function<void()>;
    void scheduleWork(WorkItem&&);
#if !defined(__swift__)
    // For the handlers that run on Metal and observer threads, which must not reference the Instance. The handle
    // drops the work once the Instance is gone; a reference to the scheduler keeps delivering it to the embedder's
    // scheduleWork (or to the event queue, which nothing then drains).
    WebGPU::InstanceSchedulerHandle schedulerHandle() const;
#endif
    std::optional<MachSendRight> webProcessID() const;

    // The futures of the C API. A future completes when the callback it stands for has run.
    uint64_t createFuture();
    void completeFuture(uint64_t);
    // Runs the pending work until one of the futures has completed, and calls didComplete with
    // the index of each completed one, which is then forgotten. False when the timeout passes
    // first. This can be called on a background thread.
    bool waitForAnyFuture(std::span<const uint64_t> futures, Seconds timeout, NOESCAPE const Function<void(size_t)>& didComplete);

private:
    explicit Instance(std::unique_ptr<InstanceImplBox>&&);

    // The scheduler, which any thread may use, and the web process ID and the retained Device / CommandBuffer
    // containers, which only the API thread uses.
    const std::unique_ptr<InstanceImplBox> m_impl;
};

} // namespace WebGPU::Metal
