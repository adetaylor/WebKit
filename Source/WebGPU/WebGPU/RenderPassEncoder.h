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
#import "TextureOrTextureView.h"
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>

#if !defined(__swift__)
namespace WebGPU {
class RenderPassEncoderImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroup;
class Buffer;
class CommandEncoder;
class Device;
class RenderPipeline;

struct RenderPassEncoderParameters {
    NSUInteger visibilityResultBufferSize { 0 };
    uint64_t maxDrawCount { 0 };
    bool depthReadOnly { false };
    bool stencilReadOnly { false };
};

// The parts of a WebGPU::RenderPassDepthStencilAttachment the pass reads, for RenderPassEncoderImpl.
struct RenderPassDepthStencilParameters {
    float depthClearValue { 0 };
    uint32_t stencilClearValue { 0 };
    bool depthLoadOpIsLoad { false };
    bool depthStoreOpIsDiscard { false };
    bool depthReadOnly { false };
    bool stencilLoadOpIsLoad { false };
    bool stencilStoreOpIsDiscard { false };
    bool stencilReadOnly { false };
};

// Defined in RenderPassEncoder.mm, where the generated Swift header declaring WebGPU::RenderPassEncoderImpl
// is includable.
struct RenderPassEncoderImplBox;

// https://gpuweb.github.io/gpuweb/#gpurenderpassencoder
// Shell over the Swift-owned RenderPassEncoderImpl, which owns all of the pass's state (including the Device), runs its
// logic and reports its errors. The shell hands the descriptor's attachments and executeBundles' bundles to the Impl.
class RenderPassEncoder final : public WebGPU::RenderPassEncoder {
    WTF_MAKE_TZONE_ALLOCATED(RenderPassEncoder);
public:
    static Ref<RenderPassEncoder> create(id<MTLRenderCommandEncoder> renderCommandEncoder, const WebGPU::RenderPassDescriptor& descriptor, NSUInteger visibilityResultBufferSize, bool depthReadOnly, bool stencilReadOnly, CommandEncoder& parentEncoder, id<MTLBuffer> visibilityResultBuffer, uint64_t maxDrawCount, Device& device, MTLRenderPassDescriptor* mtlDescriptor)
    {
        return adoptRef(*new RenderPassEncoder(renderCommandEncoder, descriptor, visibilityResultBufferSize, depthReadOnly, stencilReadOnly, parentEncoder, visibilityResultBuffer, maxDrawCount, device, mtlDescriptor));
    }
    static Ref<RenderPassEncoder> createInvalid(CommandEncoder& parentEncoder, Device& device, NSString* errorString)
    {
        return adoptRef(*new RenderPassEncoder(parentEncoder, device, errorString));
    }
    static Ref<RenderPassEncoder> createInvalidWithEncoderStateNotOpen(CommandEncoder& parentEncoder, Device& device, NSString* errorString)
    {
        Ref renderPassEncoder = createInvalid(parentEncoder, device, errorString);
        renderPassEncoder->markEncoderStateWasNotOpen();
        return renderPassEncoder;
    }

    ~RenderPassEncoder();

    void beginOcclusionQuery(uint32_t queryIndex) final;
    void draw(uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) final;
    void drawIndexed(uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t baseVertex, uint32_t firstInstance) final;
    void endOcclusionQuery() final;
    void executeBundles(std::span<const Ref<WebGPU::RenderBundle>>) final;
    void insertDebugMarker(String&& markerLabel) final;
    void popDebugGroup() final;
    void pushDebugGroup(String&& groupLabel) final;
    void setBlendConstant(const WebGPU::Color&) final;
    void setScissorRect(uint32_t x, uint32_t y, uint32_t width, uint32_t height) final;
    void setStencilReference(uint32_t) final;
    void setViewport(float x, float y, float width, float height, float minDepth, float maxDepth) final;

    // The WebGPU::RenderPassEncoder methods that take objects. Every object they take was
    // created by this implementation, so they cast it to its WebGPU::Metal type.
    void setPipeline(const WebGPU::RenderPipeline&) final;
    // A std::nullopt size is the rest of the buffer after the offset.
    void setIndexBuffer(WebGPU::Buffer&, WebGPU::IndexFormat, uint64_t offset, std::optional<uint64_t> size) final;
    void setVertexBuffer(uint32_t slot, WebGPU::Buffer*, uint64_t offset, std::optional<uint64_t> size) final;
    void drawIndirect(WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset) final;
    void drawIndexedIndirect(WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset) final;
    // std::nullopt dynamic offsets are not validated against the bind group layout.
    void setBindGroup(uint32_t groupIndex, const WebGPU::BindGroup*, std::optional<std::span<const uint32_t>> dynamicOffsets) final;
    void end() final;
    void setLabel(String&&) final;

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::RenderPassEncoderImpl& swiftImpl() const LIFETIME_BOUND;
#endif
    // A pass begun while its command encoder was not open never took the encoder over, so it can
    // never be ended. https://gpuweb.github.io/gpuweb/#dom-gpurenderpassencoder-end
    void markEncoderStateWasNotOpen();

    // A render pass whose attachments all load and store and which has no occlusion query cannot
    // change anything unless it encodes a command, so CommandEncoder hands the descriptor over here
    // instead of creating the MTLRenderCommandEncoder up front. The encoder is created the first time
    // this pass actually needs one; if nothing ever does, the pass costs nothing. See
    // canDeferRenderCommandEncoder in CommandEncoder.swift.
    void deferRenderCommandEncoder(MTLRenderPassDescriptor*);
    void makeInvalid(NSString* = nil);

private:
    RenderPassEncoder(id<MTLRenderCommandEncoder>, const WebGPU::RenderPassDescriptor&, NSUInteger, bool depthReadOnly, bool stencilReadOnly, CommandEncoder&, id<MTLBuffer>, uint64_t maxDrawCount, Device&, MTLRenderPassDescriptor*);
    RenderPassEncoder(CommandEncoder&, Device&, NSString*);

    const std::unique_ptr<RenderPassEncoderImplBox> m_impl;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(refRenderPassEncoder, derefRenderPassEncoder);

// Primitives for RenderPassEncoder.swift: byte uploads and MTLBuffer contents reads, as free functions with NOESCAPE
// spans so that Swift gets safe Span overloads (rdar://161274084), and the Metal completion handlers of the clamps,
// which capture C++ references to hop back to the API thread.
void setVertexUInt32s(id<MTLRenderCommandEncoder>, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex);
void setFragmentUInt32s(id<MTLRenderCommandEncoder>, std::span<const uint32_t> data NOESCAPE, uint32_t bufferIndex);
void setVertexUInt32Pair(id<MTLRenderCommandEncoder>, uint32_t, uint32_t, uint32_t bufferIndex);
void setVertexUInt32Triple(id<MTLRenderCommandEncoder>, uint32_t, uint32_t, uint32_t, uint32_t bufferIndex);
void setVertexIndexData(id<MTLRenderCommandEncoder>, const IndexData&, uint32_t bufferIndex);
// Temporary buffers from the device's queue; the clamp shaders store lostOrOOBRead only on failure, so scratch is zeroed.
id<MTLBuffer> newZeroedDrawIndirectScratch(Device&, uint64_t& offset);
id<MTLBuffer> newZeroedDrawIndexedIndirectScratch(Device&, uint64_t& offset);
id<MTLBuffer> newDrawIndexedIndirectArgumentsBuffer(Device&, uint32_t indexCount, uint32_t instanceCount, uint32_t indexStart, int32_t baseVertex, uint32_t baseInstance, uint64_t& offset);
bool drawIndirectArgumentsLostOrOOBRead(id<MTLBuffer> scratch, uint64_t offset);
void logRenderPassSplit();
void registerIndexValidationCompletion(CommandEncoder&, Device&, Buffer& indexBuffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLBuffer> indexedIndirectBuffer, uint64_t indexedIndirectBufferOffset);
void registerICBIndexValidationCompletion(CommandEncoder&, Device&, Buffer& indexBuffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLIndirectCommandBuffer>, id<MTLBuffer> outOfBoundsReadFlag);
// The block runs on the API thread once the command buffer completed, and returns whether to lose the device.
void registerIndirectDeviceLostChecks(CommandEncoder&, Device&, bool (^takeLostOrOOBRead)(void));

} // namespace WebGPU::Metal

#if !ENABLE(SWIFT_BASE_CLASS_ANNOTATIONS)
inline void refRenderPassEncoder(WebGPU::Metal::RenderPassEncoder* obj)
{
    obj->ref();
}

inline void derefRenderPassEncoder(WebGPU::Metal::RenderPassEncoder* obj)
{
    obj->deref();
}
#endif
