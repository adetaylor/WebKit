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
#import "PipelineLayout.h"

#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <optional>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/HashTraits.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class RenderPipelineImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroupLayout;
class Device;
class TextureOrTextureView;
class TextureView;

// The scalar pipeline state, which the render encoders read as one value.
struct RenderPipelineParameters {
    MTLPrimitiveType primitiveType { MTLPrimitiveTypePoint };
    MTLWinding frontFace { MTLWindingClockwise };
    MTLCullMode cullMode { MTLCullModeNone };
    MTLDepthClipMode depthClipMode { MTLDepthClipModeClip };
    float depthBias { 0 };
    float depthBiasSlopeScale { 0 };
    float depthBiasClamp { 0 };
    uint32_t sampleMask { UINT32_MAX };
    uint32_t colorAttachmentCount { 0 };
    uint32_t sampleCount { 0 };
    uint32_t vertexShaderBindingCount { 0 };
    uint64_t uniqueId { 0 };
    bool hasFragment { false };
    bool writesStencil { false };
};

// For RenderPipeline.swift: the parts of a WebGPU::RenderPipelineDescriptor it cannot read as Spans or directly: the
// vertex buffer layouts (optionals of a struct holding a span) and the optional fragment state (a view).
struct RenderPipelineVertexBufferFields {
    uint64_t arrayStride { 0 };
    WebGPU::VertexStepMode stepMode { WebGPU::VertexStepMode::Vertex };
};

using OptionalColorTargetState = std::optional<WebGPU::ColorTargetState>;

inline size_t renderPipelineVertexBufferCount(const WebGPU::RenderPipelineDescriptor& descriptor)
{
    return descriptor.vertex.buffers.size();
}

// std::nullopt for an empty vertex buffer slot.
inline std::optional<RenderPipelineVertexBufferFields> renderPipelineVertexBuffer(const WebGPU::RenderPipelineDescriptor& descriptor, size_t index)
{
    auto& buffer = descriptor.vertex.buffers[index];
    if (!buffer)
        return std::nullopt;
    return RenderPipelineVertexBufferFields { .arrayStride = buffer->arrayStride, .stepMode = buffer->stepMode };
}

// Empty for an empty vertex buffer slot.
inline std::span<const WebGPU::VertexAttribute> renderPipelineVertexAttributes(const WebGPU::RenderPipelineDescriptor& descriptor LIFETIME_BOUND, size_t index)
{
    auto& buffer = descriptor.vertex.buffers[index];
    return buffer ? buffer->attributes : std::span<const WebGPU::VertexAttribute> { };
}

inline bool renderPipelineHasFragment(const WebGPU::RenderPipelineDescriptor& descriptor)
{
    return !!descriptor.fragment;
}

// Only called when renderPipelineHasFragment().
inline String renderPipelineFragmentEntryPoint(const WebGPU::RenderPipelineDescriptor& descriptor)
{
    return descriptor.fragment->stage.entryPoint;
}

// Empty without a fragment state.
inline std::span<const WebGPU::ConstantEntry> renderPipelineFragmentConstants(const WebGPU::RenderPipelineDescriptor& descriptor LIFETIME_BOUND)
{
    return descriptor.fragment ? descriptor.fragment->stage.constants : std::span<const WebGPU::ConstantEntry> { };
}

inline std::span<const OptionalColorTargetState> renderPipelineColorTargets(const WebGPU::RenderPipelineDescriptor& descriptor LIFETIME_BOUND)
{
    return descriptor.fragment ? descriptor.fragment->targets : std::span<const OptionalColorTargetState> { };
}

// For RenderPipeline.swift: what Swift cannot do itself (call a private selector). Defined in RenderPipeline.mm.
void setRenderPipelineSampleMask(MTLRenderPipelineDescriptor *, uint32_t);

struct RenderPipelineImplBox;

// https://gpuweb.github.io/gpuweb/#gpurenderpipeline
// Forwards to the Swift RenderPipelineImpl, which the render encoders read directly.
class RenderPipeline final : public WebGPU::RenderPipeline {
    WTF_MAKE_TZONE_ALLOCATED(RenderPipeline);
public:
    static Ref<RenderPipeline> create(std::unique_ptr<RenderPipelineImplBox>&&);
    static Ref<RenderPipeline> createInvalid(Device&);
    // For RenderPipeline.swift: wraps the Impl staged in DeviceImpl.stagedRenderPipelineImpl.
    static Ref<RenderPipeline> createWithStagedImpl(Device&);

    ~RenderPipeline();

    Ref<WebGPU::BindGroupLayout> getBindGroupLayout(uint32_t groupIndex) final;
    void LEGACY_NODELETE setLabel(String&&) final;

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::RenderPipelineImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    PipelineLayout& pipelineLayout() const;

private:
    explicit RenderPipeline(std::unique_ptr<RenderPipelineImplBox>&&);

    const std::unique_ptr<RenderPipelineImplBox> m_impl;
};

// As callCreateComputePipelineAsyncCallback.
using CreateRenderPipelineAsyncCallback = CompletionHandler<void(std::expected<Ref<WebGPU::RenderPipeline>, WebGPU::PipelineError>&&)>;
void callCreateRenderPipelineAsyncCallback(CreateRenderPipelineAsyncCallback&, RenderPipeline&, bool succeeded, NSString *errorMessage);

} // namespace WebGPU::Metal
