/*
 * Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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
#import "Device.h"
#import <CoreVideo/CVPixelBuffer.h>
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/cf/CFTypeTraits.h>

WTF_DECLARE_CF_TYPE_TRAIT(CVPixelBuffer);

#if !defined(__swift__)
namespace WebGPU {
class ExternalTextureImpl;
}
#endif

namespace WebGPU::Metal {

class Device;

// Defined in ExternalTexture.mm, where the generated Swift header declaring WebGPU::ExternalTextureImpl is includable.
struct ExternalTextureImplBox;

// Forwards to the Swift ExternalTextureImpl, which holds the state, the encoders that used the texture and the Device.
class ExternalTexture final : public WebGPU::ExternalTexture {
    WTF_MAKE_TZONE_ALLOCATED(ExternalTexture);
public:
    static Ref<ExternalTexture> create(CVPixelBufferRef, WebGPU::PredefinedColorSpace, const WebGPU::Extent2D& visibleSize, Device&);
    static Ref<ExternalTexture> createInvalid(Device&);

    ~ExternalTexture();

#if !defined(__swift__)
    WebGPU::ExternalTextureImpl& swiftImpl() const LIFETIME_BOUND;
#endif

    void destroy() final;
    void undestroy() final;

    void setLabel(String&&) final { }
    bool LEGACY_NODELETE isValid() const final;
    void update(CVPixelBufferRef);
    void updateExternalTexture(CVPixelBufferRef pixelBuffer) final { update(pixelBuffer); }

private:
    explicit ExternalTexture(std::unique_ptr<ExternalTextureImplBox>&&);

    const std::unique_ptr<ExternalTextureImplBox> m_impl;
};

} // namespace WebGPU::Metal
