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

#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <wtf/EnumeratedArray.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/HashSet.h>
#import <wtf/HashTraits.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class BindGroupLayoutImpl;
}
#endif

namespace WebGPU::Metal {

class BindGroup;
class Device;
class PipelineLayout;

// Opaque box holding the Swift object; defined in BindGroupLayout.mm, where the generated interop header is includable.
struct BindGroupLayoutImplBox;

// https://gpuweb.github.io/gpuweb/#gpubindgrouplayout
// BindGroupLayout.swift owns the entries, the argument encoders, the counts and the creation, and the bind group and
// encoder code reads them from BindGroupLayoutImpl, which also holds the Device.
class BindGroupLayout final : public WebGPU::BindGroupLayout {
    WTF_MAKE_TZONE_ALLOCATED(BindGroupLayout);
public:
#if !defined(__swift__)
    static Ref<BindGroupLayout> create(std::unique_ptr<BindGroupLayoutImplBox>&&);
#endif
    static Ref<BindGroupLayout> createInvalid(Device&);
    // For BindGroupLayout.swift and PipelineLayout.swift: wraps the Impl staged in DeviceImpl.stagedBindGroupLayoutImpl.
    static Ref<BindGroupLayout> createWithStagedImpl(Device&);

    ~BindGroupLayout();

    void setLabel(String&&) final;

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::BindGroupLayoutImpl& swiftImpl() const LIFETIME_BOUND;
#endif

#if !defined(__swift__)
    // Borrowed from the Impl, which holds the reference.
    const Device& LEGACY_NODELETE device() const;
#endif
private:
    explicit BindGroupLayout(std::unique_ptr<BindGroupLayoutImplBox>&&);

    const std::unique_ptr<BindGroupLayoutImplBox> m_impl;
};

} // namespace WebGPU::Metal
