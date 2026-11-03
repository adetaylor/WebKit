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
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/TypeCasts.h>
#import <wtf/WeakHashSet.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPUSwift {
class TextureViewImpl;
}
#endif

namespace WebGPU::Metal {

class Device;
class Texture;

// https://gpuweb.github.io/gpuweb/#gputextureview
// Swift owns the Metal views, the resolved descriptor, the parent Texture and the encoders that used the view.
class TextureView final : public WebGPU::TextureView {
    WTF_MAKE_TZONE_ALLOCATED(TextureView);
public:
#if !defined(__swift__)
    // Texture::createView makes the TextureViewImpl.
    static Ref<TextureView> create(const WebGPUSwift::TextureViewImpl&);
#endif
    static Ref<TextureView> createInvalid(Texture&, Device&);
    // Wraps the Impl that Swift staged in DeviceImpl, for a creation made in Swift.
    static Ref<TextureView> createWithStagedImpl(Device&);

    ~TextureView();

    void setLabel(String&&) final;

    NODELETE bool isValid() const final;

#if !defined(__swift__)
    WebGPUSwift::TextureViewImpl& swiftImpl() const LIFETIME_BOUND;
#endif

private:
#if !defined(__swift__)
    explicit TextureView(const WebGPUSwift::TextureViewImpl&);
#endif

    // The Swift object: one generated WebGPU::TextureViewImpl, a single strong reference. TextureView.mm, where the
    // generated header is includable, builds it in place in the constructor and destroys it in the destructor.
    alignas(void*) std::byte m_impl[sizeof(void*)];
} SWIFT_SHARED_REFERENCE(refTextureView, derefTextureView) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

// For impl(of:) in ImplLookup.swift, which gives WebKit's Swift the TextureViewImpl of a WebGPU::TextureView.
TextureView& deliverImpl(WebGPU::TextureView&) SWIFT_RETURNS_UNRETAINED;
// The shell as the C++ API object it is, for Swift, which can't convert a shared reference to its base class.
inline WebGPU::TextureView& apiObject(TextureView& shell) SWIFT_RETURNS_UNRETAINED { return shell; }

} // namespace WebGPU::Metal

inline void refTextureView(WebGPU::Metal::TextureView* obj)
{
    obj->ref();
}

inline void derefTextureView(WebGPU::Metal::TextureView* obj)
{
    obj->deref();
}

SPECIALIZE_TYPE_TRAITS_BEGIN(WebGPU::Metal::TextureView)
    static bool isType(const WGPUTextureViewImpl&) { return true; }
    static bool isType(const WebGPU::TextureView&) { return true; }
SPECIALIZE_TYPE_TRAITS_END()
