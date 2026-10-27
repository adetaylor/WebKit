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

#import "config.h"
#import "RenderBundle.h"

#import "APIConversions.h"
#import "Device.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPU::RenderBundleImpl) == sizeof(void*) && alignof(WebGPU::RenderBundleImpl) == alignof(void*));

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderBundle);

void writeRenderBundleDepthRange(Device& device, id<MTLBuffer> buffer, float minDepth, float maxDepth)
{
    std::array<float, 2> twoFloats = { minDepth, maxDepth };
    device.getQueue()->writeBuffer(buffer, 0, asWritableBytes(std::span(twoFloats)));
}

Ref<RenderBundle> RenderBundle::create(const WebGPU::RenderBundleImpl& impl)
{
    return adoptRef(*new RenderBundle(impl));
}

RenderBundle::RenderBundle(const WebGPU::RenderBundleImpl& impl)
{
    new (m_impl) WebGPU::RenderBundleImpl(impl);
}

RenderBundle::~RenderBundle()
{
    std::destroy_at(&swiftImpl());
}

bool RenderBundle::isValid() const
{
    return swiftImpl().isValid();
}

WebGPU::RenderBundleImpl& RenderBundle::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::RenderBundleImpl*>(const_cast<std::byte*>(m_impl)));
}

void RenderBundle::setLabel(String&& label)
{
    swiftImpl().setLabel(label.createNSString().get());
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuRenderBundleAddRef(WGPURenderBundle renderBundle)
{
    WebGPU::Metal::fromAPI(renderBundle).ref();
}

void wgpuRenderBundleRelease(WGPURenderBundle renderBundle)
{
    WebGPU::Metal::fromAPI(renderBundle).deref();
}

void wgpuRenderBundleSetLabel(WGPURenderBundle renderBundle, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(renderBundle))->setLabel(WebGPU::Metal::fromAPI(label));
}
