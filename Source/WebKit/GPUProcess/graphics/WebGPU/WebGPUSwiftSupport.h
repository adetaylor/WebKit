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

#include "IPCSemaphore.h"
#include "MessageReceiver.h"
#include "RemoteGPU.h"
#include "SharedPreferencesForWebProcess.h"
#include "StreamServerConnection.h"
#include "SwiftCoding.h"
#include "WebGPUExtent3D.h"
#include "WebGPUIdentifier.h"
#include "WebGPUImageCopyTexture.h"
#include "WebGPUImageDataLayout.h"
#include <WebCore/SharedMemory.h>
#include <WebCore/WebGPUCppAPI.h>
#include <concepts>
#include <memory>
#include <type_traits>
#include <wtf/CompletionHandler.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

#if PLATFORM(COCOA)
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#endif

namespace WebKit {

// Keeps the messages for a WebGPU receiver written in Swift coming from the stream connection, as
// IPC::ScopedActiveMessageReceiveQueue does for a C++ receiver, until it goes.
class WebGPUSwiftReceiverRegistration final : public RefCounted<WebGPUSwiftReceiverRegistration> {
public:
    static Ref<WebGPUSwiftReceiverRegistration> create(IPC::StreamServerConnection& streamConnection, IPC::StreamMessageReceiver& receiver, IPC::ReceiverName receiverName, uint64_t identifier)
    {
        return adoptRef(*new WebGPUSwiftReceiverRegistration(streamConnection, receiver, receiverName, identifier));
    }

    ~WebGPUSwiftReceiverRegistration();

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<WebGPUSwiftReceiverRegistration>::ref(); }
    void deref() const { RefCounted<WebGPUSwiftReceiverRegistration>::deref(); }
#endif

private:
    WebGPUSwiftReceiverRegistration(IPC::StreamServerConnection&, IPC::StreamMessageReceiver&, IPC::ReceiverName, uint64_t identifier);

    const Ref<IPC::StreamServerConnection> m_streamConnection;
    const IPC::ReceiverName m_receiverName;
    const uint64_t m_identifier;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

template<typename> struct IsRefOfStreamMessageReceiver : std::false_type { };
template<typename T> struct IsRefOfStreamMessageReceiver<Ref<T>> : std::bool_constant<std::derived_from<T, IPC::StreamMessageReceiver>> { };

// Registers a Swift receiver's message forwarder for those messages, with the RemoteGPU's shared preferences. Null if
// the RemoteGPU's stream connection has gone. A template so that Swift, which can't pass a forwarder as the
// StreamMessageReceiver it is, can pass the Ref to it that it holds. The static_assert is used because the constraint
// isn't enforced for Swift callers.
template<typename ForwarderRef>
WebGPUSwiftReceiverRegistration* WTF_NULLABLE registerWebGPUSwiftReceiver(RemoteGPU& gpu, const ForwarderRef& forwarder, IPC::ReceiverName receiverName, uint64_t identifier) SWIFT_RETURNS_RETAINED
{
    static_assert(IsRefOfStreamMessageReceiver<ForwarderRef>::value);
    RefPtr streamConnection = gpu.streamConnection();
    if (!streamConnection)
        return nullptr;
    forwarder->setSharedPreferencesProvider([weakGPU = WeakPtr { gpu }]() -> std::optional<SharedPreferencesForWebProcess> {
        if (RefPtr gpu = weakGPU.get())
            return gpu->sharedPreferencesForWebProcess();
        return std::nullopt;
    });
    return &WebGPUSwiftReceiverRegistration::create(*streamConnection, forwarder.get(), receiverName, identifier).leakRef();
}

using OptionalOwnedBytes = std::optional<::WebGPU::OwnedBytes>;

// The bytes of the shared memory that a message's handle names, mapped read-only, for a write that may read them after
// it returns. std::nullopt if there's none, or no more than the message could have carried in the stream.
OptionalOwnedBytes mapSharedMemory(IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>&);

// Whether a write with copy is no larger than the web process sends in a message (WebGPU::maxCrossProcessResourceCopySize).
bool isValidWebGPUWriteWithCopySize(size_t);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
