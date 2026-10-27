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

#import "BindGroupLayout.h"
#import "BindableResource.h"
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <span>
#import <wtf/EnumeratedArray.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashTraits.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class BindGroupImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroupLayout;
class Device;
class ExternalTexture;
class Sampler;

struct ExternalTextureIndices {
    NSUInteger containerIndex { NSNotFound };
    NSUInteger resourceIndex { NSNotFound };
    NSUInteger argumentBufferIndex { NSNotFound };
};

// The constants an external texture binding writes into an argument buffer after its two planes. The matrices are
// column-major, as the shader's float3x2, float4x3 and float3x3 lay them out.
struct ExternalTextureConstants {
    float uvRemapping[6] { };
    float colorSpaceConversion[12] { };
    float primariesConversion[9] { };
    uint32_t visibleWidth { 0 };
    uint32_t visibleHeight { 0 };
};

// For BindGroup.swift, which cannot address argument-buffer constant data without unsafe.
void writeExternalTextureConstants(id<MTLArgumentEncoder>, NSUInteger firstIndex, const ExternalTextureConstants&);
void writeBufferLengthConstant(id<MTLArgumentEncoder>, NSUInteger index, uint32_t length);
// buffer.label = encoder.label, without bridging the label through a Swift String.
void copyArgumentEncoderLabel(id<MTLArgumentEncoder>, id<MTLBuffer>);
// The WTF::HashSet that checks EncoderModel.swift's WTFHashMap replica. An operation >= 0 adds that key, a negative one
// removes -operation - 1, and INT64_MIN clears; `keys` receives the keys in iteration order, and the result is the set's
// size.
size_t wtfHashSetOrderForOperations(std::span<const int64_t> operations NOESCAPE, std::span<uint32_t> keys NOESCAPE);

// https://gpuweb.github.io/gpuweb/#gpubindgroup
// BindGroup.swift owns the resources, argument buffers, samplers, dynamic buffers, validation cache and the Device, and
// runs creation and every check.
class BindGroup final : public WebGPU::BindGroup {
    WTF_MAKE_TZONE_ALLOCATED(BindGroup);
public:
#if !defined(__swift__)
    // `makeImpl` returns the WebGPU::BindGroupImpl. Defined in BindGroup.mm.
    template<typename MakeImpl> static Ref<BindGroup> create(MakeImpl&&);
#endif
    static Ref<BindGroup> createInvalid(Device&);

    ~BindGroup();

    void setLabel(String&&) final;

    bool LEGACY_NODELETE isValid() const final;
    bool updateExternalTextures(WebGPU::ExternalTexture&) final;
    // For a destroyed Buffer or Texture that this group holds.
    void releaseDestroyedResources();

#if !defined(__swift__)
    WebGPU::BindGroupImpl& swiftImpl() const LIFETIME_BOUND;
    // Borrowed from the Impl, which holds the reference.
    Device& device() const;
#endif

private:
#if !defined(__swift__)
    template<typename MakeImpl> explicit BindGroup(MakeImpl&&);
#endif

    // The Swift object: one generated WebGPU::BindGroupImpl, a single strong reference. BindGroup.mm, where the generated
    // header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

} // namespace WebGPU::Metal
