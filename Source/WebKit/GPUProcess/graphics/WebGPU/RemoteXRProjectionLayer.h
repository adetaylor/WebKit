/*
 * Copyright (C) 2024-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "SharedPreferencesForWebProcess.h"
#include "StreamMessageReceiver.h"
#include <wtf/Function.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>

#if ENABLE(WEBXR) && PLATFORM(COCOA)
#include <WebCore/PlatformXR.h>
#include <WebCore/WebGPUCppAPI.h>
#include <wtf/MachSendRight.h>
#endif

namespace WebKit {

// The receiver of a WebXR projection layer's messages, on its stream connection's work queue. C++ handles StartFrame,
// whose send rights and rasterization rate map have no Swift form, and passes the frame on to Swift. The layer and its
// other messages are in RemoteXRProjectionLayer.swift, whose state m_swiftState holds.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteXRProjectionLayer.swift") RemoteXRProjectionLayer final : public IPC::StreamMessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteXRProjectionLayer);
public:
    // Takes over swiftState, the address of a retained Swift RemoteXRProjectionLayerState.
    static Ref<RemoteXRProjectionLayer> create(uintptr_t swiftState);
    ~RemoteXRProjectionLayer();

    void setSharedPreferencesProvider(Function<std::optional<SharedPreferencesForWebProcess>()>&&);
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { IPC::StreamMessageReceiver::ref(); }
    void deref() const { IPC::StreamMessageReceiver::deref(); }
#endif

private:
    explicit RemoteXRProjectionLayer(uintptr_t swiftState);

#if ENABLE(WEBXR) && PLATFORM(COCOA)
    void startFrame(uint64_t frameIndex, MachSendRight&& colorBuffer, MachSendRight&& depthBuffer, MachSendRight&& completionSyncEvent, uint64_t textureIndex, PlatformXR::RateMapDescription&&);

    // Implemented in Swift. The mach ports are the frame's send rights, which startFrame() owns for the call,
    // MACH_PORT_NULL for a buffer that the compositor didn't send, and the samples are the rate map's.
    void startSwiftFrame(uint64_t frameIndex, mach_port_t colorBuffer, mach_port_t depthBuffer, mach_port_t completionSyncEvent, uint64_t textureIndex, uint32_t screenWidth, uint32_t screenHeight, ::WebGPU::XRRasterizationSamples horizontalSamplesLeft, ::WebGPU::XRRasterizationSamples horizontalSamplesRight, ::WebGPU::XRRasterizationSamples verticalSamples);
#endif

    // Implemented in Swift.
    static void destroySwiftState(uintptr_t);

    const uintptr_t m_swiftState;
    Function<std::optional<SharedPreferencesForWebProcess>()> m_sharedPreferencesProvider;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
