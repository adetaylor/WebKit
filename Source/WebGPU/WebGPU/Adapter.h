/*
 * Copyright (c) 2021-2022 Apple Inc. All rights reserved.
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

#import "HardwareCapabilities.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <bmalloc/CompactAllocationMode.h>
#import <expected>
#import <memory>
#import <wtf/Assertions.h>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashSet.h>
#import <wtf/MachSendRight.h>
#import <wtf/Ref.h>
#import <wtf/RefPtr.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/WeakPtr.h>


namespace WebGPU::Metal {

class Device;
class Instance;

// Opaque box holding the Swift AdapterImpl; defined in Adapter.mm.
struct AdapterImplBox;

// https://gpuweb.github.io/gpuweb/#gpuadapter
class Adapter final : public WebGPU::Adapter {
    WTF_MAKE_TZONE_ALLOCATED(Adapter);
public:
    static Ref<Adapter> create(id<MTLDevice>, Instance&, bool xrCompatible, HardwareCapabilities&&);

    ~Adapter();

    Vector<WebGPU::FeatureName> features() const final;
    WebGPU::Limits limits() const final;
    WebGPU::AdapterInfo info() final;
    // The C API adapter info, which has members that WebGPU::AdapterInfo does not have.
    bool hasFeature(WebGPU::FeatureName);
    void requestDevice(const WebGPU::DeviceDescriptor&, CompletionHandler<void(RefPtr<WebGPU::Device>&&)>&&) final;
    // requestDevice() with the reason a device could not be created, for the C API.
    void requestDeviceOrError(const WebGPU::DeviceDescriptor&, CompletionHandler<void(std::expected<Ref<Device>, String>&&)>&&);

    void setLabel(String&&) final;
    bool isValid() const final;
    id<MTLDevice> device() const;
    void makeInvalid();
    bool isXRCompatible() const final;

    RefPtr<Instance> instance() const { return m_instance.get(); }
    ThreadSafeWeakPtr<Instance> weakInstance() const { return m_instance; }
    // For DeviceImpl's resource attribution: the Instance's web process identity, or an empty right when the Instance
    // has none or is gone.
    MachSendRight webProcessIdentity() const;

private:
    Adapter(std::unique_ptr<AdapterImplBox>&&, Instance&);

    const std::unique_ptr<AdapterImplBox> m_impl;
    const ThreadSafeWeakPtr<Instance> m_instance;
};

} // namespace WebGPU::Metal
