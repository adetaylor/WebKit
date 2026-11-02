/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#import "config.h"
#import "PresentationContextCoreAnimation.h"

#import "APIConversions.h"
#import "Device.h"
#import "Texture.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct PresentationContextCoreAnimationImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(PresentationContextCoreAnimationImplBox);
    WebGPUSwift::PresentationContextCoreAnimationImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(PresentationContextCoreAnimationImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(PresentationContextCoreAnimation);

Ref<PresentationContextCoreAnimation> PresentationContextCoreAnimation::create(CAMetalLayer *layer)
{
    return adoptRef(*new PresentationContextCoreAnimation(makeUnique<PresentationContextCoreAnimationImplBox>(PresentationContextCoreAnimationImplBox { .impl = WebGPUSwift::makePresentationContextCoreAnimationImpl(layer) })));
}

PresentationContextCoreAnimation::PresentationContextCoreAnimation(std::unique_ptr<PresentationContextCoreAnimationImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

PresentationContextCoreAnimation::~PresentationContextCoreAnimation() = default;

void PresentationContextCoreAnimation::configure(const WebGPU::CanvasConfiguration& configuration)
{
    Ref device = metal(configuration.device.get());
    m_impl->impl.configure(configuration, device.ptr(), device->swiftImpl());
}

void PresentationContextCoreAnimation::unconfigure()
{
    m_impl->impl.unconfigure();
}

Texture* PresentationContextCoreAnimation::currentTexture(uint32_t)
{
    if (!m_impl->impl.acquireCurrentFrame())
        return nullptr;
    return &borrowSwiftRetained(m_impl->impl.currentFrameTexture());
}

// The drawable is presented when the work that renders into it, which has been submitted, completes.
void PresentationContextCoreAnimation::present(uint32_t)
{
    m_impl->impl.present();
}

bool PresentationContextCoreAnimation::isValid() const
{
    return m_impl->impl.isConfigured();
}

} // namespace WebGPU::Metal
