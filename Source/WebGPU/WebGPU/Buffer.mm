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
#import "Buffer.h"

#import "BindGroup.h"
#import "CommandEncoder.h"
#import "Device.h"

#import <wtf/Borrow.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/SpanCocoa.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

// The whole Ts of the buffer's contents from byteOffset on, through cpuVisibleContents(), which RELEASE_ASSERTs that a
// non-empty buffer has a CPU-visible base address.
template <typename T>
static inline std::span<T> span(id<MTLBuffer> buffer, uint64_t byteOffset = 0)
{
    auto bytes = cpuVisibleContents(buffer);
    if (byteOffset >= bytes.size())
        return { };
    bytes = bytes.subspan(byteOffset);
    return spanReinterpretCast<T>(bytes.first(bytes.size() - bytes.size() % sizeof(T)));
}

template <typename T>
static bool verifyIndexBufferData(id<MTLBuffer> buffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, uint32_t primitiveRestart, uint32_t indexBufferOffsetInBytes = 0)
{
    auto indexData = span<T>(buffer, indexBufferOffsetInBytes);
    size_t endIndex = static_cast<size_t>(firstIndex) + indexCount;
    if (endIndex > indexData.size())
        return false;
    for (size_t index = firstIndex; index < endIndex; ++index) {
        T vertexIndex = primitiveRestart + indexData[index];
        if (vertexIndex >= vertexCount + primitiveRestart)
            return false;
    }

    return true;
}

static NSMutableData* copyContents(std::span<const uint8_t> contents)
{
    return [toNSData(contents).get() mutableCopy];
}

std::span<uint8_t> cpuVisibleContents(id<MTLBuffer> buffer)
{
    void* contents = buffer.contents;
    NSUInteger length = buffer.length;
    RELEASE_ASSERT(contents || !length);
    return unsafeMakeSpan(static_cast<uint8_t*>(contents), length);
}

void readBufferContents(id<MTLBuffer> buffer, uint64_t offset, std::span<uint8_t> destination NOESCAPE)
{
    memcpySpan(destination, cpuVisibleContents(buffer).subspan(offset, destination.size()));
}

bool writeBufferContentsIfInBounds(id<MTLBuffer> buffer, uint64_t offset, std::span<const uint8_t> data NOESCAPE)
{
    auto contents = cpuVisibleContents(buffer);
    if (contents.empty())
        return false;
    auto endOffset = checkedSum<size_t>(offset, data.size());
    if (endOffset.hasOverflowed() || endOffset.value() > contents.size())
        return false;
    memcpySpan(contents.subspan(offset), data);
    return true;
}

bool verifyIndexBufferForSlowPath(Queue& queue, id<MTLBuffer> mtlBuffer, uint32_t firstIndex, uint32_t indexCount, bool isUInt16, uint32_t primitiveOffset, uint32_t vertexCount)
{
    WTFLogAlways("WARNING: Severe performance penalty due to encoding drawIndexed calls out of order with submission"); // NOLINT
    queue.waitForAllCommitedWorkToComplete();
    queue.synchronizeResourceAndWait(mtlBuffer);
    if (isUInt16)
        return verifyIndexBufferData<uint16_t>(mtlBuffer, firstIndex, indexCount, vertexCount, primitiveOffset);
    return verifyIndexBufferData<uint32_t>(mtlBuffer, firstIndex, indexCount, vertexCount, primitiveOffset);
}

// Mirrors what vsUshortIndexClamp()/vsUintIndexClamp() enforce on the GPU, over every index the clamp
// dispatch could have read: the dispatch's index count is itself clamped to the index buffer's length, and
// each fetched index is offset by primitiveRestart and saturating-added to baseVertex before the bounds
// comparison. Scanning the whole buffer rather than [indexStart, indexStart + indexCount) keeps this a
// superset of what the shader reads, since the baked slot holds an already-clamped index count while the
// indirect arguments still hold the values the page asked for.
template <typename T>
static bool verifyClampedIndirectIndexBufferData(id<MTLBuffer> buffer, uint64_t indexBufferOffsetInBytes, uint32_t vertexCount, uint32_t primitiveRestart, int32_t baseVertex)
{
    auto indexData = span<T>(buffer, indexBufferOffsetInBytes);
    if (indexData.empty())
        return false;

    auto vertexCountBound = static_cast<uint64_t>(vertexCount) + primitiveRestart;
    for (auto indexValue : indexData) {
        uint32_t vertexIndex = primitiveRestart + static_cast<uint32_t>(indexValue);
        auto shiftedVertexIndex = std::min<uint64_t>(static_cast<uint64_t>(vertexIndex) + static_cast<uint32_t>(baseVertex), UINT32_MAX);
        if (shiftedVertexIndex >= vertexCountBound)
            return false;
    }

    return true;
}

bool verifyBundleIndirectDrawIndexBufferForSlowPath(Queue& queue, id<MTLBuffer> mtlBuffer, id<MTLBuffer> indirectBuffer, uint64_t indirectOffset, uint64_t indexBufferOffset, bool isUInt16, uint32_t vertexCount, uint32_t primitiveOffset)
{
    WTFLogAlways("WARNING: Severe performance penalty due to writing an index buffer used by a render bundle's indirect draw out of order with submission"); // NOLINT
    queue.waitForAllCommitedWorkToComplete();
    queue.synchronizeResourceAndWait(mtlBuffer);
    if (!indirectBuffer)
        return false;
    queue.synchronizeResourceAndWait(indirectBuffer);

    auto argumentsEnd = checkedSum<uint64_t>(indirectOffset, sizeof(MTLDrawIndexedPrimitivesIndirectArguments));
    if (argumentsEnd.hasOverflowed() || indirectBuffer.length < argumentsEnd.value())
        return false;
    auto argumentsSpan = span<MTLDrawIndexedPrimitivesIndirectArguments>(indirectBuffer, indirectOffset);
    if (argumentsSpan.empty())
        return false;
    auto baseVertex = argumentsSpan.front().baseVertex;
    if (isUInt16)
        return verifyClampedIndirectIndexBufferData<uint16_t>(mtlBuffer, indexBufferOffset, vertexCount, primitiveOffset, baseVertex);
    return verifyClampedIndirectIndexBufferData<uint32_t>(mtlBuffer, indexBufferOffset, vertexCount, primitiveOffset, baseVertex);
}

NSMutableData* clearIndexBufferContents(Queue& queue, id<MTLBuffer> mtlBuffer)
{
    NSMutableData* priorData = copyContents(span<uint8_t>(mtlBuffer));

    queue.clearBuffer(mtlBuffer);
    queue.finalizeBlitCommandEncoder();
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (mtlBuffer.storageMode == MTLStorageModeManaged)
        [mtlBuffer didModifyRange:NSMakeRange(0, mtlBuffer.length)];
    ALLOW_DEPRECATED_DECLARATIONS_END
#endif
    return priorData;
}

} // namespace WebGPU::Metal
