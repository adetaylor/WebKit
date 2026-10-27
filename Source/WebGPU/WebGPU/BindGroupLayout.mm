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

#import "config.h"
#import "BindGroupLayout.h"

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

// The Swift object, wrapped so BindGroupLayout.h can forward-declare it without the generated header.
struct BindGroupLayoutImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(BindGroupLayoutImplBox);
    WebGPU::BindGroupLayoutImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(BindGroupLayoutImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(BindGroupLayout);

RefPtr<WebGPU::BindGroupLayout> Device::createBindGroupLayout(const WebGPU::BindGroupLayoutDescriptor& descriptor)
{
    return BindGroupLayout::create(makeUnique<BindGroupLayoutImplBox>(BindGroupLayoutImplBox { .impl = createBindGroupLayoutImpl(this, swiftImpl(), descriptor) }));
}

#pragma mark Shell

Ref<BindGroupLayout> BindGroupLayout::create(std::unique_ptr<BindGroupLayoutImplBox>&& impl)
{
    return adoptRef(*new BindGroupLayout(WTF::move(impl)));
}

Ref<BindGroupLayout> BindGroupLayout::createInvalid(Device& device)
{
    return create(makeUnique<BindGroupLayoutImplBox>(BindGroupLayoutImplBox { .impl = makeInvalidBindGroupLayoutImpl(&device, device.swiftImpl()) }));
}

Ref<BindGroupLayout> BindGroupLayout::createWithStagedImpl(Device& device)
{
    return create(makeUnique<BindGroupLayoutImplBox>(BindGroupLayoutImplBox { .impl = device.swiftImpl().takeStagedBindGroupLayoutImpl() }));
}

BindGroupLayout::BindGroupLayout(std::unique_ptr<BindGroupLayoutImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

BindGroupLayout::~BindGroupLayout()
{
    m_impl->impl.removeFromDeviceCache();
}

void BindGroupLayout::setLabel(String&& label)
{
    m_impl->impl.setLabel(WTF::move(label));
}

bool BindGroupLayout::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPU::BindGroupLayoutImpl& BindGroupLayout::swiftImpl() const
{
    return m_impl->impl;
}

const Device& BindGroupLayout::device() const
{
    return borrowSwiftRetained(m_impl->impl.shellDevice());
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuBindGroupLayoutAddRef(WGPUBindGroupLayout bindGroupLayout)
{
    WebGPU::Metal::fromAPI(bindGroupLayout).ref();
}

void wgpuBindGroupLayoutRelease(WGPUBindGroupLayout bindGroupLayout)
{
    WebGPU::Metal::fromAPI(bindGroupLayout).deref();
}

void wgpuBindGroupLayoutSetLabel(WGPUBindGroupLayout bindGroupLayout, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(bindGroupLayout))->setLabel(WebGPU::Metal::fromAPI(label));
}
