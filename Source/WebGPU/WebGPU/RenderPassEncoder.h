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

#import "BindableResource.h"
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>

namespace WebGPU::Metal {

struct RenderPassEncoderParameters {
    NSUInteger visibilityResultBufferSize { 0 };
    uint64_t maxDrawCount { 0 };
    bool depthReadOnly { false };
    bool stencilReadOnly { false };
};

// Primitives for RenderPassEncoder.swift: byte uploads and MTLBuffer contents reads, as free functions with NOESCAPE
// spans so that Swift gets safe Span overloads (rdar://161274084), and the Metal completion handlers of the clamps,
// which capture C++ references to hop back to the API thread.
void setVertexUInt32s(id<MTLRenderCommandEncoder> _Null_unspecified, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex);
void setFragmentUInt32s(id<MTLRenderCommandEncoder> _Null_unspecified, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex);
void setVertexUInt32Pair(id<MTLRenderCommandEncoder> _Null_unspecified, uint32_t, uint32_t, uint32_t bufferIndex);
void setVertexUInt32Triple(id<MTLRenderCommandEncoder> _Null_unspecified, uint32_t, uint32_t, uint32_t, uint32_t bufferIndex);
void setVertexIndexData(id<MTLRenderCommandEncoder> _Null_unspecified, const IndexData&, uint32_t bufferIndex);
// Writes the arguments, with lostOrOOBRead clear, into the buffer's contents at that offset, which must hold them.
void writeDrawIndexedIndirectArguments(id<MTLBuffer> _Nullable, uint64_t offset, uint32_t indexCount, uint32_t instanceCount, uint32_t indexStart, int32_t baseVertex, uint32_t baseInstance);
bool drawIndirectArgumentsLostOrOOBRead(id<MTLBuffer> _Null_unspecified scratch, uint64_t offset);
void logRenderPassSplit();
// The out-of-bounds flag a completed index clamp wrote: into the indexed indirect arguments, or into an ICB's flag.
// False, leaving the flag, if it can't be read.
bool readIndexedIndirectArgumentsLostOrOOBRead(id<MTLBuffer> _Nullable indexedIndirectBuffer, uint64_t indexedIndirectBufferOffset, uint32_t& lostOrOOBRead);
bool readOutOfBoundsReadFlag(id<MTLBuffer> _Nullable outOfBoundsReadFlag, uint32_t& outOfBoundsRead);

} // namespace WebGPU::Metal

