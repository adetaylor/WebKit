/*
 * Copyright (c) 2024 Apple Inc. All rights reserved.
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
#import <span>
#import <utility>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class XRProjectionLayerImpl;
}
#endif

namespace WebGPU::Metal {

class CommandEncoder;
class Device;

// Defined in XRProjectionLayer.mm, where the generated Swift header declaring WebGPU::XRProjectionLayerImpl is includable.
struct XRProjectionLayerImplBox;

// The descriptor values, handed to Swift in one value: std::optional and OptionSet stay on this side.
struct XRProjectionLayerParameters {
    WebGPU::TextureFormat colorFormat { WebGPU::TextureFormat::Bgra8unorm };
    bool hasDepthStencilFormat { false };
    WebGPU::TextureFormat depthStencilFormat { WebGPU::TextureFormat::Bgra8unorm };
    uint8_t textureUsage { 0 };
    double scaleFactor { 1 };
};

// A frame's rasterization samples, borrowed for the duration of startFrame: a nonescapable view, which Swift hands back
// to makeXRRasterizationRateMaps without reading it, where a std::span would be unsafe to pass.
struct XRRasterizationSamples {
    std::span<const float> samples;
} SWIFT_VIEW;

// The SPI and soft-linked CompositorServices calls XRProjectionLayerImpl::startFrame makes. They return nil
// outside visionOS device builds with the internal SDK, where XRProjectionLayer::startFrame never reaches Swift.
id<MTLTexture> makeXRSharedTexture(id<MTLDevice>, mach_port_t);
id<MTLSharedEvent> makeXRSharedEvent(id<MTLDevice>, mach_port_t);
NSArray<id<MTLRasterizationRateMap>> *makeXRRasterizationRateMaps(id<MTLDevice>, unsigned screenWidth, unsigned screenHeight, const XRRasterizationSamples& horizontalSamplesLeft, const XRRasterizationSamples& horizontalSamplesRight, const XRRasterizationSamples& verticalSamples);

class XRProjectionLayer final : public WebGPU::XRProjectionLayer {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(XRProjectionLayer);
public:
    static Ref<XRProjectionLayer> create(const WebGPU::XRProjectionLayerDescriptor&, Device&);

    ~XRProjectionLayer();

    void LEGACY_NODELETE setLabel(String&&) final;

    bool LEGACY_NODELETE isValid() const final;
    void LEGACY_NODELETE startFrame(size_t frameIndex, MachSendRight&& colorBuffer, MachSendRight&& depthBuffer, MachSendRight&& completionSyncEvent, size_t reusableTextureIndex, unsigned screenWidth, unsigned screenHeight, Vector<float>&& horizontalSamplesLeft, Vector<float>&& horizontalSamplesRight, Vector<float>&& verticalSamples) final;
    void endFrame() final { }

#if !defined(__swift__)
    WebGPU::XRProjectionLayerImpl& swiftImpl() const LIFETIME_BOUND;
#endif

private:
    explicit XRProjectionLayer(std::unique_ptr<XRProjectionLayerImplBox>&&);

    // Owns the descriptor values, the per-frame textures (and their per-index caches), the completion event,
    // the current reusable texture index, the rasterization rate maps and the Device.
    const std::unique_ptr<XRProjectionLayerImplBox> m_impl;
};

} // namespace WebGPU::Metal
