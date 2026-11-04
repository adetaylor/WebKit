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

#import "config.h"
#import "RenderPassEncoder.h"

#import "BindGroup.h"
#import "Buffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Queue.h"
#import "RenderPipeline.h"
#import "Texture.h"
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

#pragma mark Primitives for RenderPassEncoder.swift

void setVertexUInt32s(id<MTLRenderCommandEncoder> commandEncoder, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex)
{
    auto bytes = asByteSpan(data);
    [commandEncoder setVertexBytes:bytes.data() length:bytes.size() atIndex:bufferIndex];
}

void setFragmentUInt32s(id<MTLRenderCommandEncoder> commandEncoder, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex)
{
    auto bytes = asByteSpan(data);
    [commandEncoder setFragmentBytes:bytes.data() length:bytes.size() atIndex:bufferIndex];
}

void setVertexUInt32Pair(id<MTLRenderCommandEncoder> commandEncoder, uint32_t first, uint32_t second, uint32_t bufferIndex)
{
    uint32_t data[] = { first, second };
    setVertexUInt32s(commandEncoder, std::span<const uint32_t> { data }, bufferIndex);
}

void setVertexUInt32Triple(id<MTLRenderCommandEncoder> commandEncoder, uint32_t first, uint32_t second, uint32_t third, uint32_t bufferIndex)
{
    uint32_t data[] = { first, second, third };
    setVertexUInt32s(commandEncoder, std::span<const uint32_t> { data }, bufferIndex);
}

void setVertexIndexData(id<MTLRenderCommandEncoder> commandEncoder, const IndexData& indexData, uint32_t bufferIndex)
{
    auto bytes = asByteSpan(indexData);
    [commandEncoder setVertexBytes:bytes.data() length:bytes.size() atIndex:bufferIndex];
}

template <typename T>
static T* LEGACY_NODELETE typedCast(auto& s)
{
    return static_cast<T*>(static_cast<void*>(&s));
}

// Vector does not initialize POD, hence zeroSpan; the inline capacity fits either argument struct.
static id<MTLBuffer> newZeroedIndirectScratch(Device& device, size_t size, uint64_t& offset)
{
    Vector<uint8_t, 32> zero(size);
    zeroSpan(zero.mutableSpan());
    auto [buffer, bufferOffset] = device.getQueue()->newTemporaryBufferWithBytes(zero.mutableSpan(), false);
    offset = bufferOffset;
    return buffer;
}

id<MTLBuffer> newZeroedDrawIndirectScratch(Device& device, uint64_t& offset)
{
    return newZeroedIndirectScratch(device, sizeof(WebKitMTLDrawPrimitivesIndirectArguments), offset);
}

id<MTLBuffer> newZeroedDrawIndexedIndirectScratch(Device& device, uint64_t& offset)
{
    return newZeroedIndirectScratch(device, sizeof(WebKitMTLDrawIndexedPrimitivesIndirectArguments), offset);
}

id<MTLBuffer> newDrawIndexedIndirectArgumentsBuffer(Device& device, uint32_t indexCount, uint32_t instanceCount, uint32_t indexStart, int32_t baseVertex, uint32_t baseInstance, uint64_t& offset)
{
    WebKitMTLDrawIndexedPrimitivesIndirectArguments indirectArguments {
        .args = MTLDrawIndexedPrimitivesIndirectArguments {
            .indexCount = indexCount,
            .instanceCount = instanceCount,
            .indexStart = indexStart,
            .baseVertex = baseVertex,
            .baseInstance = baseInstance
        },
        .lostOrOOBRead = 0u
    };
    auto [buffer, bufferOffset] = device.getQueue()->newTemporaryBufferWithBytes(unsafeMakeSpan(typedCast<uint8_t>(indirectArguments), sizeof(indirectArguments)), false);
    offset = bufferOffset;
    return buffer;
}

bool drawIndirectArgumentsLostOrOOBRead(id<MTLBuffer> buffer, uint64_t offset)
{
    auto checkedEnd = checkedSum<uint64_t>(offset, sizeof(WebKitMTLDrawPrimitivesIndirectArguments));
    if (!buffer.contents || checkedEnd.hasOverflowed() || checkedEnd.value() > buffer.length)
        return false;

    auto contents = unsafeMakeSpan(static_cast<const uint8_t*>(buffer.contents), buffer.length).subspan(offset);
    return reinterpretCastSpanStartTo<const WebKitMTLDrawPrimitivesIndirectArguments>(contents).lostOrOOBRead;
}

void logRenderPassSplit()
{
#ifndef NDEBUG
#if CPU(ARM64)
    WTFLogAlways("WebGPU: Splitting render pass on ARM64 - severe performance penalty"); // NOLINT
#endif
#endif
}

bool readIndexedIndirectArgumentsLostOrOOBRead(id<MTLBuffer> indexedIndirectBuffer, uint64_t indexedIndirectBufferOffset, uint32_t& lostOrOOBRead)
{
    auto checkedEnd = checkedSum<uint64_t>(indexedIndirectBufferOffset, sizeof(WebKitMTLDrawIndexedPrimitivesIndirectArguments));
    if (!indexedIndirectBuffer.contents || checkedEnd.hasOverflowed() || checkedEnd.value() > indexedIndirectBuffer.length)
        return false;

    auto contents = unsafeMakeSpan(static_cast<const uint8_t*>(indexedIndirectBuffer.contents), indexedIndirectBuffer.length).subspan(indexedIndirectBufferOffset);
    lostOrOOBRead = reinterpretCastSpanStartTo<const WebKitMTLDrawIndexedPrimitivesIndirectArguments>(contents).lostOrOOBRead;
    return true;
}

bool readOutOfBoundsReadFlag(id<MTLBuffer> outOfBoundsReadFlag, uint32_t& outOfBoundsRead)
{
    if (!outOfBoundsReadFlag.contents || outOfBoundsReadFlag.length < sizeof(uint32_t))
        return false;
    auto flag = unsafeMakeSpan(static_cast<const uint8_t*>(outOfBoundsReadFlag.contents), outOfBoundsReadFlag.length);
    outOfBoundsRead = reinterpretCastSpanStartTo<const uint32_t>(flag);
    return true;
}

} // namespace WebGPU::Metal
