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
#import <memory>
#import <optional>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/HashTraits.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/WeakPtr.h>

namespace WebGPU::Metal {

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

// For RenderPipeline.swift: what Swift cannot do itself (call a private selector). Defined in RenderPipeline.mm.
void setRenderPipelineSampleMask(MTLRenderPipelineDescriptor *, uint32_t);

// As callCreateComputePipelineAsyncCallback.

} // namespace WebGPU::Metal
