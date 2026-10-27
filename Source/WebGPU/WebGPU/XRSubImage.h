/*
 * Copyright (c) 2024-2026 Apple Inc. All rights reserved.
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

#import "Texture.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <utility>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/WeakPtr.h>


namespace WebGPU::Metal {

class CommandEncoder;
class Device;
class Texture;
class XRProjectionLayer;

// Defined in XRSubImage.mm, where the generated Swift header declaring WebGPU::XRSubImageImpl is includable.
struct XRSubImageImplBox;

// The Texture operations XRSubImageImpl::update needs, in forms Swift can call. createXRTexture() wraps an XR
// layer texture in a Texture that allows views in viewFormat.
Texture& createXRTexture(id<MTLTexture>, bool isDepthTexture, WebGPU::TextureFormat, WebGPU::TextureFormat viewFormat, Device&) SWIFT_RETURNS_RETAINED;
void updateXRTextureCompletionEvent(Texture&, id<MTLSharedEvent>, uint64_t signalValue);
void setXRTextureRasterizationRateMaps(Texture&, id<MTLRasterizationRateMap> left, id<MTLRasterizationRateMap> right);

class XRSubImage final : public WebGPU::XRSubImage {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(XRSubImage);
public:
    static Ref<XRSubImage> create(Device&);

    ~XRSubImage();

    void LEGACY_NODELETE setLabel(String&&) final;

    bool LEGACY_NODELETE isValid() const final;
    void update(const XRProjectionLayer&);
    Texture* depthTexture();
    RefPtr<WebGPU::Texture> colorTexture() final;
    RefPtr<WebGPU::Texture> depthStencilTexture() final;

private:
    XRSubImage(std::unique_ptr<XRSubImageImplBox>&&, Device&);

    // Owns the color/depth texture maps and the current texture index.
    const std::unique_ptr<XRSubImageImplBox> m_impl;

    // Weak because the Device owns this object.
    ThreadSafeWeakPtr<Device> m_device;
};

} // namespace WebGPU::Metal
