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
#import "QuerySet.h"

#import "APIConversions.h"
#import "Buffer.h"
#import "CommandEncoder.h"
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

static_assert(sizeof(WebGPU::QuerySetImpl) == sizeof(void*) && alignof(WebGPU::QuerySetImpl) == alignof(void*));

RefPtr<WebGPU::QuerySet> Device::createQuerySet(const WebGPU::QuerySetDescriptor& descriptor)
{
    return QuerySet::create(descriptor, *this);
}

#pragma mark Shell

WTF_MAKE_TZONE_ALLOCATED_IMPL(QuerySet);

Ref<QuerySet> QuerySet::create(const WebGPU::QuerySetDescriptor& descriptor, Device& device)
{
    return adoptRef(*new QuerySet([&] {
        return createQuerySetImpl(&device, device.swiftImpl(), descriptor, device.timestampCounterSet());
    }));
}

Ref<QuerySet> QuerySet::createInvalid(Device& device)
{
    return adoptRef(*new QuerySet([&] {
        return makeInvalidQuerySetImpl(&device, device.swiftImpl());
    }));
}

template<typename MakeImpl>
QuerySet::QuerySet(MakeImpl&& makeImpl)
{
    // Initialized from the prvalue directly: no copy, so no extra retain and release.
    new (m_impl) WebGPU::QuerySetImpl(makeImpl());
}

// The Swift object returns its counter sample range to the pool in its deinit.
QuerySet::~QuerySet()
{
    std::destroy_at(&swiftImpl());
}

WebGPU::QuerySetImpl& QuerySet::swiftImpl() const
{
    return *std::launder(reinterpret_cast<WebGPU::QuerySetImpl*>(const_cast<std::byte*>(m_impl)));
}

Device& QuerySet::device() const
{
    return borrowSwiftRetained(swiftImpl().shellDevice());
}

bool QuerySet::isValid() const
{
    return swiftImpl().isValid();
}

bool QuerySet::isDestroyed() const
{
    return swiftImpl().isDestroyed();
}

void QuerySet::destroy()
{
    swiftImpl().destroy();
}

void QuerySet::setLabel(String&& label)
{
    swiftImpl().setLabel(WTF::move(label));
}

uint32_t QuerySet::count() const
{
    return swiftImpl().count();
}

std::optional<WebGPU::QueryType> QuerySet::type() const
{
    if (!swiftImpl().hasType())
        return std::nullopt;
    return static_cast<WebGPU::QueryType>(swiftImpl().typeRawValue());
}

id<MTLBuffer> QuerySet::visibilityBuffer() const
{
    return swiftImpl().visibilityBuffer();
}

void QuerySet::setCommandEncoder(CommandEncoder& commandEncoder) const
{
    swiftImpl().setCommandEncoder(commandEncoder.swiftImpl());
}

QuerySet::CounterSampleBuffer QuerySet::counterSampleBufferWithOffset() const
{
    return CounterSampleBuffer { swiftImpl().counterSampleBuffer(), swiftImpl().counterSampleBufferOffset() };
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuQuerySetAddRef(WGPUQuerySet querySet)
{
    WebGPU::Metal::fromAPI(querySet).ref();
}

void wgpuQuerySetRelease(WGPUQuerySet querySet)
{
    WebGPU::Metal::fromAPI(querySet).deref();
}

void wgpuQuerySetDestroy(WGPUQuerySet querySet)
{
    protect(WebGPU::Metal::fromAPI(querySet))->destroy();
}

void wgpuQuerySetSetLabel(WGPUQuerySet querySet, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(querySet))->setLabel(WebGPU::Metal::fromAPI(label));
}

uint32_t wgpuQuerySetGetCount(WGPUQuerySet querySet)
{
    return WebGPU::Metal::fromAPI(querySet).count();
}

WGPUQueryType wgpuQuerySetGetType(WGPUQuerySet querySet)
{
    auto type = WebGPU::Metal::fromAPI(querySet).type();
    return type ? WebGPU::Metal::toAPI(*type) : WGPUQueryType_Force32;
}
