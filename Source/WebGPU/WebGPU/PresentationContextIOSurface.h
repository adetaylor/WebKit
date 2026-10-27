/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

#import "PresentationContext.h"
#import <wtf/MachSendRight.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/spi/cocoa/IOSurfaceSPI.h>

namespace WebGPU::Metal {

class Instance;
struct PresentationContextIOSurfaceImplBox;

class PresentationContextIOSurface : public PresentationContext {
    WTF_MAKE_TZONE_ALLOCATED(PresentationContextIOSurface);
public:
    static Ref<PresentationContextIOSurface> create(const WebGPU::PresentationContextDescriptor&, const Instance&);

    virtual ~PresentationContextIOSurface();

    void configure(const WebGPU::CanvasConfiguration&) override;
    void unconfigure() override;

    void present(uint32_t) override;
    Texture* currentTexture(uint32_t) override;

    Seconds lastFrameGPUCost() const override;
    Seconds lastFramePresentStall() const override;

    bool isValid() const final { return true; }
private:
    explicit PresentationContextIOSurface(std::unique_ptr<PresentationContextIOSurfaceImplBox>&&);

    void renderBuffersWereRecreated(std::span<const IOSurfaceRef>);
    void onSubmittedWorkScheduled(Function<void()>&&);
    RetainPtr<CGImageRef> getTextureAsNativeImage(uint32_t bufferIndex, bool& isIOSurfaceSupportedFormat) final;

    // The web process identity, device, IOSurfaces, render buffers, frames in flight, pipelines and canvas modes.
    const std::unique_ptr<PresentationContextIOSurfaceImplBox> m_impl;
};

} // namespace WebGPU::Metal
