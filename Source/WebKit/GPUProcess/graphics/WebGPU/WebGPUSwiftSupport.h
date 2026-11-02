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

#include "MessageReceiver.h"
#include "SharedPreferencesForWebProcess.h"
#include "StreamServerConnection.h"
#include "WebGPUIdentifier.h"
#include <WebCore/WebGPUCppAPI.h>
#include <memory>
#include <wtf/Noncopyable.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

class RemoteGPU;

namespace WebGPU {
class ObjectHeap;
}

// What a WebGPU receiver written in Swift uses of the C++ around it, which Swift can't hold directly: the object
// heap that owns the receiver and the RemoteGPU it serves, both weakly, and its identifier.
class WebGPUSwiftReceiverContext {
public:
    WebGPUSwiftReceiverContext(WebGPU::ObjectHeap&, RemoteGPU&, WebGPUIdentifier);

    void removeFromObjectHeap() const;
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    // The external texture with that identifier in the object heap, if there is one.
    ::WebGPU::ExternalTexture* WTF_NULLABLE externalTexture(uint64_t identifier) const SWIFT_RETURNS_RETAINED;

private:
    WeakPtr<WebGPU::ObjectHeap> m_objectHeap;
    WeakPtr<RemoteGPU> m_gpu;
    WebGPUIdentifier m_identifier;
} SWIFT_SELF_CONTAINED;

// The backings WebGPU receivers written in Swift are created with. Swift can't take the ::WebGPU types themselves: the
// C++ header it generates names them WebGPU::..., which inside namespace WebKit means WebKit::WebGPU::....
class RemoteBindGroupBacking {
public:
    explicit RemoteBindGroupBacking(::WebGPU::BindGroup& backing)
        : m_backing(backing)
    {
    }

    ::WebGPU::BindGroup& get() const SWIFT_RETURNS_UNRETAINED { return m_backing; }

private:
    Ref<::WebGPU::BindGroup> m_backing;
} SWIFT_SELF_CONTAINED;

class RemoteQuerySetBacking {
public:
    explicit RemoteQuerySetBacking(::WebGPU::QuerySet& backing)
        : m_backing(backing)
    {
    }

    ::WebGPU::QuerySet& get() const SWIFT_RETURNS_UNRETAINED { return m_backing; }

private:
    Ref<::WebGPU::QuerySet> m_backing;
} SWIFT_SELF_CONTAINED;

namespace WebGPU {

// The object heap's entry for a receiver written in Swift. It owns the receiver, keeps the backing that other
// receivers look up by identifier, and keeps the receiver's messages coming for as long as it exists, as
// IPC::ScopedActiveMessageReceiveQueue does for a receiver written in C++. It also gives the receiver's message
// forwarder the shared preferences from C++, so that dispatching a message doesn't ask Swift for them.
template<typename Backing, typename SwiftReceiver>
class SwiftReceiverObject {
    WTF_MAKE_NONCOPYABLE(SwiftReceiverObject);
public:
    SwiftReceiverObject(Backing& backing, SwiftReceiver&& receiver, const WebGPUSwiftReceiverContext& context, IPC::StreamServerConnection& streamConnection, IPC::ReceiverName receiverName, WebGPUIdentifier identifier)
        : m_backing(backing)
        , m_receiver(WTF::makeUniqueWithoutFastMallocCheck<SwiftReceiver>(WTF::move(receiver)))
        , m_streamConnection(&streamConnection)
        , m_receiverName(receiverName)
        , m_identifier(identifier)
    {
        Ref messageReceiver = m_receiver->getMessageReceiver();
        messageReceiver->setSharedPreferencesProvider([context] {
            return context.sharedPreferencesForWebProcess();
        });
        streamConnection.startReceivingMessages(messageReceiver, receiverName, identifier.toUInt64());
    }

    SwiftReceiverObject(SwiftReceiverObject&& other)
        : m_backing(other.m_backing)
        , m_receiver(WTF::move(other.m_receiver))
        , m_streamConnection(WTF::move(other.m_streamConnection))
        , m_receiverName(other.m_receiverName)
        , m_identifier(other.m_identifier)
    {
    }

    SwiftReceiverObject& operator=(SwiftReceiverObject&& other)
    {
        if (this != &other) {
            stopReceivingMessages();
            m_backing = other.m_backing;
            m_receiver = WTF::move(other.m_receiver);
            m_streamConnection = WTF::move(other.m_streamConnection);
            m_receiverName = other.m_receiverName;
            m_identifier = other.m_identifier;
        }
        return *this;
    }

    ~SwiftReceiverObject()
    {
        stopReceivingMessages();
    }

    Backing& backing() const LIFETIME_BOUND { return m_backing; }

    // Lets the object heap reach the backing as it does through a ScopedActiveMessageReceiveQueue.
    const SwiftReceiverObject* operator->() const LIFETIME_BOUND { return this; }

private:
    void stopReceivingMessages()
    {
        if (RefPtr streamConnection = std::exchange(m_streamConnection, nullptr))
            streamConnection->stopReceivingMessages(m_receiverName, m_identifier.toUInt64());
    }

    Ref<Backing> m_backing;
    std::unique_ptr<SwiftReceiver> m_receiver;
    RefPtr<IPC::StreamServerConnection> m_streamConnection;
    IPC::ReceiverName m_receiverName;
    WebGPUIdentifier m_identifier;
};

} // namespace WebGPU

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
