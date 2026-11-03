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

#import "BindableResource.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>

#if !defined(__swift__)
namespace WebGPUSwift {
class RenderBundleImpl;
}
#endif

namespace WebGPU::Metal {

class Device;

// https://gpuweb.github.io/gpuweb/#gpurenderbundle
// Forwards to the Swift RenderBundleImpl, which RenderBundleEncoderImpl.finish() builds and which owns the bundle's
// state.
class RenderBundle final : public WebGPU::RenderBundle {
    WTF_MAKE_TZONE_ALLOCATED(RenderBundle);
public:
#if !defined(__swift__)
    static Ref<RenderBundle> create(const WebGPUSwift::RenderBundleImpl&);
#endif
    // Wraps the Impl that Swift staged in DeviceImpl, for a creation made in Swift.
    static Ref<RenderBundle> createWithStagedImpl(Device&);

    ~RenderBundle();

    void setLabel(String&&) final;

    NODELETE bool isValid() const final;

#if !defined(__swift__)
    WebGPUSwift::RenderBundleImpl& swiftImpl() const LIFETIME_BOUND;
#endif

private:
#if !defined(__swift__)
    explicit RenderBundle(const WebGPUSwift::RenderBundleImpl&);
#endif

    // The Swift object: one generated WebGPU::RenderBundleImpl, a single strong reference. RenderBundle.mm, where the
    // generated header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

// For impl(of:) and reference(of:) in ImplLookup.swift, which give WebKit's Swift the RenderBundleImpl of a WebGPU::RenderBundle,
// and its shell.
RenderBundle& deliverImpl(WebGPU::RenderBundle&) SWIFT_RETURNS_UNRETAINED;

} // namespace WebGPU::Metal
