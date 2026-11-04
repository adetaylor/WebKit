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
#import "Adapter.h"

#import "Device.h"
#import "Instance.h"
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct AdapterImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(AdapterImplBox);
    WebGPUSwift::AdapterImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(AdapterImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(Adapter);

Ref<Adapter> Adapter::create(id<MTLDevice> device, Instance& instance, bool xrCompatible, HardwareCapabilities&& capabilities)
{
    auto box = makeUnique<AdapterImplBox>(AdapterImplBox { .impl = WebGPUSwift::makeAdapterImpl(device, xrCompatible, capabilities) });
    return adoptRef(*new Adapter(WTF::move(box), instance));
}

Adapter::Adapter(std::unique_ptr<AdapterImplBox>&& impl, Instance& instance)
    : m_impl(WTF::move(impl))
    , m_instance(&instance)
{
}

Adapter::~Adapter() = default;

MachSendRight Adapter::webProcessIdentity() const
{
    RefPtr instance = m_instance;
    if (!instance)
        return { };
    auto webProcessID = instance->webProcessID();
    if (!webProcessID)
        return { };
    return MachSendRight { WTF::move(*webProcessID) };
}

bool Adapter::isValid() const
{
    return m_impl->impl.isValid();
}

id<MTLDevice> Adapter::device() const
{
    return m_impl->impl.device();
}

void Adapter::makeInvalid()
{
    m_impl->impl.makeInvalid();
}

WebGPUSwift::AdapterImpl& Adapter::swiftImpl() const
{
    return m_impl->impl;
}

void deliverAdapterImpl(Adapter& shell)
{
    WebGPUSwift::receiveImpl(shell.swiftImpl());
}

} // namespace WebGPU::Metal
