/*
 * Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

#import "Pipeline.h"

#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <wtf/CompletionHandler.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>

#if !defined(__swift__)
namespace WebGPU {
class ComputePipelineImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroupLayout;
class Device;
class PipelineLayout;

// The pipeline's unique id and workgroup size.
struct ComputePipelineParameters {
    uint64_t uniqueId { 0 };
    NSUInteger threadsPerThreadgroupWidth { 0 };
    NSUInteger threadsPerThreadgroupHeight { 0 };
    NSUInteger threadsPerThreadgroupDepth { 0 };
};

// https://gpuweb.github.io/gpuweb/#gpucomputepipeline
// Forwards to the Swift ComputePipelineImpl, which the compute pass reads directly.
class ComputePipeline final : public WebGPU::ComputePipeline {
    WTF_MAKE_TZONE_ALLOCATED(ComputePipeline);
public:
#if !defined(__swift__)
    // `makeImpl` returns the WebGPU::ComputePipelineImpl. Defined in ComputePipeline.mm.
    template<typename MakeImpl> static Ref<ComputePipeline> create(MakeImpl&&);
#endif
    static Ref<ComputePipeline> createInvalid(Device&);
    // For ComputePipeline.swift: wraps the Impl staged in DeviceImpl.stagedComputePipelineImpl.
    static Ref<ComputePipeline> createWithStagedImpl(Device&);

    ~ComputePipeline();

    Ref<WebGPU::BindGroupLayout> getBindGroupLayout(uint32_t groupIndex) final;
    void LEGACY_NODELETE setLabel(String&&) final;

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::ComputePipelineImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    PipelineLayout& pipelineLayout() const;
private:
#if !defined(__swift__)
    template<typename MakeImpl> explicit ComputePipeline(MakeImpl&&);
#endif

    // The Swift object: one generated WebGPU::ComputePipelineImpl, a single strong reference. ComputePipeline.mm, where
    // the generated header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

// The embedder's callback of the asynchronous creations, which Swift calls through this: it cannot build the
// std::expected argument.
using CreateComputePipelineAsyncCallback = CompletionHandler<void(std::expected<Ref<WebGPU::ComputePipeline>, WebGPU::PipelineError>&&)>;
void callCreateComputePipelineAsyncCallback(CreateComputePipelineAsyncCallback&, ComputePipeline&, bool succeeded, NSString *errorMessage);

} // namespace WebGPU::Metal
