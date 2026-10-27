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
#import <cstddef>
#import <memory>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>

#if !defined(__swift__)
namespace WebGPU {
class RenderBundleEncoderImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroup;
class Buffer;
class Device;
class RenderPipeline;

struct RenderBundleEncoderParameters {
    uint32_t sampleCount { 0 };
    WebGPU::TextureFormat depthStencilFormat { WebGPU::TextureFormat::R8unorm };
    bool hasDepthStencilFormat { false };
    bool depthReadOnly { false };
    bool stencilReadOnly { false };
};

void copyDynamicOffsetsToBuffer(id<MTLBuffer>, std::span<const uint32_t> contents NOESCAPE);

// https://gpuweb.github.io/gpuweb/#gpurenderbundleencoder
// Forwards to the Swift RenderBundleEncoderImpl, which owns the encoder's state and logic.
class RenderBundleEncoder final : public WebGPU::RenderBundleEncoder {
    WTF_MAKE_TZONE_ALLOCATED(RenderBundleEncoder);
public:
    // An invalid descriptor reports the error and gives an invalid encoder.
    static Ref<RenderBundleEncoder> create(const WebGPU::RenderBundleEncoderDescriptor&, Device&);
    static Ref<RenderBundleEncoder> createInvalid(Device&, NSString* errorString);

    ~RenderBundleEncoder();

    RefPtr<WebGPU::RenderBundle> finish(const WebGPU::RenderBundleDescriptor&) final;
    void insertDebugMarker(String&& markerLabel) final;
    void popDebugGroup() final;
    void pushDebugGroup(String&& groupLabel) final;

    // The WebGPU::RenderBundleEncoder methods. The ones that take objects cast them to their
    // WebGPU::Metal type, which every object that this implementation receives has.
    void draw(uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) final;
    void drawIndexed(uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t baseVertex, uint32_t firstInstance) final;
    void drawIndirect(WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset) final;
    void drawIndexedIndirect(WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset) final;
    void setPipeline(const WebGPU::RenderPipeline&) final;
    // A std::nullopt size is the rest of the buffer after the offset.
    void setIndexBuffer(WebGPU::Buffer&, WebGPU::IndexFormat, uint64_t offset, std::optional<uint64_t> size) final;
    void setVertexBuffer(uint32_t slot, WebGPU::Buffer*, uint64_t offset, std::optional<uint64_t> size) final;
    // std::nullopt dynamic offsets are not validated against the bind group layout.
    void setBindGroup(uint32_t groupIndex, const WebGPU::BindGroup*, std::optional<std::span<const uint32_t>> dynamicOffsets) final;
    void makeInvalid(NSString* = nil);
    void setLabel(String&&) final;

    bool isValid() const final;

private:
#if !defined(__swift__)
    template<typename MakeImpl> explicit RenderBundleEncoder(MakeImpl&&);
    WebGPU::RenderBundleEncoderImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    // The Swift object: one generated WebGPU::RenderBundleEncoderImpl, a single strong reference.
    // RenderBundleEncoder.mm, where the generated header is includable, builds it in place in the constructor and
    // destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

} // namespace WebGPU::Metal
