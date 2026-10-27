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

#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <span>
#import <wtf/EnumeratedArray.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/HashTraits.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class PipelineLayoutImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroup;
class BindGroupLayout;
class Device;

// https://gpuweb.github.io/gpuweb/#gpupipelinelayout
// PipelineLayout.swift owns the bind group layouts, the dynamic-offset plans, the Device and the creation. The shell
// forwards everything.
class PipelineLayout final : public WebGPU::PipelineLayout {
    WTF_MAKE_TZONE_ALLOCATED(PipelineLayout);
public:
#if !defined(__swift__)
    // `makeImpl` returns the WebGPU::PipelineLayoutImpl. Defined in PipelineLayout.mm.
    template<typename MakeImpl> static Ref<PipelineLayout> create(MakeImpl&&);
#endif
    static Ref<PipelineLayout> createInvalid(Device&);
    // For PipelineLayout.swift: wraps the Impl staged in DeviceImpl.stagedPipelineLayoutImpl.
    static Ref<PipelineLayout> createWithStagedImpl(Device&);

    ~PipelineLayout();

    void LEGACY_NODELETE setLabel(String&&) final;

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::PipelineLayoutImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    void makeInvalid();
private:
#if !defined(__swift__)
    template<typename MakeImpl> explicit PipelineLayout(MakeImpl&&);
#endif

    // The Swift object: one generated WebGPU::PipelineLayoutImpl, a single strong reference. PipelineLayout.mm, where the
    // generated header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

} // namespace WebGPU::Metal
