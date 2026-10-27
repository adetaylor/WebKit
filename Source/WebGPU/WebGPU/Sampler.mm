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
#import "Sampler.h"

#import "APIConversions.h"
#import "Device.h"
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

static_assert(sizeof(WebGPU::SamplerImpl) == sizeof(void*) && alignof(WebGPU::SamplerImpl) == alignof(void*));

RefPtr<WebGPU::Sampler> Device::createSampler(const WebGPU::SamplerDescriptor& descriptor)
{
    return Sampler::create(descriptor, *this);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(Sampler);

Ref<Sampler> Sampler::create(const WebGPU::SamplerDescriptor& descriptor, Device& device)
{
    return adoptRef(*new Sampler([&] {
        return createSamplerImpl(&device, device.swiftImpl(), descriptor);
    }));
}

Ref<Sampler> Sampler::createInvalid(Device& device)
{
    return adoptRef(*new Sampler([&] {
        return makeInvalidSamplerImpl(&device, device.swiftImpl());
    }));
}

template<typename MakeImpl>
Sampler::Sampler(MakeImpl&& makeImpl)
{
    // Initialized from the prvalue directly: no copy, so no extra retain and release.
    new (m_impl) WebGPU::SamplerImpl(makeImpl());
}

Sampler::~Sampler()
{
    std::destroy_at(&swiftImpl());
}

WebGPU::SamplerImpl& Sampler::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::SamplerImpl*>(const_cast<std::byte*>(m_impl)));
}

Device& Sampler::device() const
{
    return borrowSwiftRetained(swiftImpl().shellDevice());
}

void Sampler::setLabel(String&& label)
{
    swiftImpl().setLabel(WTF::move(label));
}

bool Sampler::isValid() const
{
    return swiftImpl().isValid();
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuSamplerAddRef(WGPUSampler sampler)
{
    WebGPU::Metal::fromAPI(sampler).ref();
}

void wgpuSamplerRelease(WGPUSampler sampler)
{
    WebGPU::Metal::fromAPI(sampler).deref();
}

void wgpuSamplerSetLabel(WGPUSampler sampler, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(sampler))->setLabel(WebGPU::Metal::fromAPI(label));
}
