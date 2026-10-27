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

#import "BindableResource.h"
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <optional>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>
#import <wtf/WeakHashSet.h>
#import <wtf/WeakPtr.h>

#if !defined(__swift__)
namespace WebGPU {
class QuerySetImpl;
}
#endif

namespace WebGPU::Metal {

class Buffer;
class CommandEncoder;
class Device;

// https://gpuweb.github.io/gpuweb/#gpuqueryset
class QuerySet final : public WebGPU::QuerySet {
    WTF_MAKE_TZONE_ALLOCATED(QuerySet);
public:
    struct CounterSampleBuffer {
        id<MTLCounterSampleBuffer> buffer { nil }; // Safety: ARC retains this pointer
        uint32_t offset { 0 };
    } SWIFT_SELF_CONTAINED;

    // Validates the descriptor, generating the validation error, and returns an invalid query set if it fails.
    static Ref<QuerySet> create(const WebGPU::QuerySetDescriptor&, Device&);
    static Ref<QuerySet> createInvalid(Device&);

    ~QuerySet();

    void destroy() final;
    void setLabel(String&&) final;

    bool isValid() const final;

    // Borrowed from the Impl, which holds the reference. Swift reads QuerySetImpl.device instead.
    Device& device() const;
    uint32_t count() const;
    // std::nullopt only for invalid query sets.
    std::optional<WebGPU::QueryType> type() const;
    id<MTLBuffer> visibilityBuffer() const;
    CounterSampleBuffer counterSampleBufferWithOffset() const;

    void setCommandEncoder(CommandEncoder&) const;
    bool isDestroyed() const;
#if !defined(__swift__)
    WebGPU::QuerySetImpl& swiftImpl() const LIFETIME_BOUND;
#endif

private:
#if !defined(__swift__)
    template<typename MakeImpl> explicit QuerySet(MakeImpl&&);
#endif

    // Storage for the Swift QuerySetImpl (one strong reference), built in place in QuerySet.mm, where the generated
    // header is visible.
    alignas(void*) std::byte m_impl[sizeof(void*)];
} SWIFT_SHARED_REFERENCE(refQuerySet, derefQuerySet) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

} // namespace WebGPU::Metal

inline void refQuerySet(WebGPU::Metal::QuerySet* obj)
{
    obj->ref();
}

inline void derefQuerySet(WebGPU::Metal::QuerySet* obj)
{
    obj->deref();
}
