/*
 * Copyright (c) 2021-2025 Apple Inc. All rights reserved.
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

#import "CommandEncoder.h"
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <array>
#import <memory>
#import <optional>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>


namespace WebGPU::Metal {

class BindGroup;
class Buffer;
class ComputePipeline;
class Device;

// Defined in ComputePassEncoder.mm, where the generated Swift header declaring WebGPU::ComputePassEncoderImpl
// is includable.
struct ComputePassEncoderImplBox;

// https://gpuweb.github.io/gpuweb/#gpucomputepassencoder
// Shell over the Swift-owned ComputePassEncoderImpl, which owns the pass's state, runs every method's logic and reports
// its errors.
class ComputePassEncoder final : public WebGPU::ComputePassEncoder {
    WTF_MAKE_TZONE_ALLOCATED(ComputePassEncoder);
public:
    static Ref<ComputePassEncoder> create(id<MTLComputeCommandEncoder> computeCommandEncoder, const WebGPU::ComputePassDescriptor& descriptor, CommandEncoder& parentEncoder, Device& device)
    {
        return adoptRef(*new ComputePassEncoder(computeCommandEncoder, descriptor, parentEncoder, device));
    }
    static Ref<ComputePassEncoder> createInvalid(CommandEncoder& parentEncoder, Device& device, NSString* errorString)
    {
        return adoptRef(*new ComputePassEncoder(parentEncoder, device, errorString));
    }
    static Ref<ComputePassEncoder> createInvalidWithEncoderStateNotOpen(CommandEncoder& parentEncoder, Device& device, NSString* errorString)
    {
        Ref computePassEncoder = createInvalid(parentEncoder, device, errorString);
        computePassEncoder->markEncoderStateWasNotOpen();
        return computePassEncoder;
    }

    ~ComputePassEncoder();

    void dispatch(uint32_t x, uint32_t y, uint32_t z) final;
    void insertDebugMarker(String&& markerLabel) final;
    void popDebugGroup() final;
    void pushDebugGroup(String&& groupLabel) final;

    // The WebGPU::ComputePassEncoder methods. Every object they take was created by this
    // implementation, so they cast it to its WebGPU::Metal type.
    void setPipeline(const WebGPU::ComputePipeline&) final;
    void dispatchIndirect(const WebGPU::Buffer& indirectBuffer, uint64_t indirectOffset) final;
    void end() final;
    // std::nullopt dynamic offsets are not validated against the bind group layout.
    void setBindGroup(uint32_t groupIndex, const WebGPU::BindGroup*, std::optional<std::span<const uint32_t>> dynamicOffsets) final;
    void setLabel(String&&) final;

    bool isValid() const final;

    // A pass begun while its command encoder was not open never took the encoder over, so it can
    // never be ended. https://gpuweb.github.io/gpuweb/#dom-gpucomputepassencoder-end
    void markEncoderStateWasNotOpen();

private:
    ComputePassEncoder(id<MTLComputeCommandEncoder>, const WebGPU::ComputePassDescriptor&, CommandEncoder&, Device&);
    ComputePassEncoder(CommandEncoder&, Device&, NSString*);

    const std::unique_ptr<ComputePassEncoderImplBox> m_impl;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(refComputePassEncoder, derefComputePassEncoder);

// For ComputePassEncoder.swift. Free functions, so that the span gets a safe Span overload (rdar://161274084).

void setComputeDynamicOffsets(id<MTLComputeCommandEncoder>, std::span<const uint32_t> dynamicOffsets NOESCAPE, NSUInteger bufferIndex);

} // namespace WebGPU::Metal

#if !ENABLE(SWIFT_BASE_CLASS_ANNOTATIONS)
inline void refComputePassEncoder(WebGPU::Metal::ComputePassEncoder* obj)
{
    obj->ref();
}

inline void derefComputePassEncoder(WebGPU::Metal::ComputePassEncoder* obj)
{
    obj->deref();
}
#endif
