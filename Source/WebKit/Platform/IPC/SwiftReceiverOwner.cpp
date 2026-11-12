/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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

#include "config.h"
#include "SwiftReceiverOwner.h"

#if ENABLE(SWIFT_IPC_RECEIVERS)

#include "Decoder.h"
#include <wtf/TZoneMallocInlines.h>

namespace IPC {

WTF_MAKE_TZONE_ALLOCATED_IMPL(SwiftReceiverOwner);

Ref<SwiftReceiverOwner> SwiftReceiverOwner::create(Ref<StreamServerConnection>&& streamConnection, ASCIILiteral workQueueName, ReceiverName receiverName, uint64_t identifier, std::optional<WebKit::SharedPreferencesForWebProcess> sharedPreferences, Function<void(MessageName)>&& didReceiveInvalidMessage)
{
    return adoptRef(*new SwiftReceiverOwner(WTF::move(streamConnection), workQueueName, receiverName, identifier, WTF::move(sharedPreferences), WTF::move(didReceiveInvalidMessage)));
}

SwiftReceiverOwner::SwiftReceiverOwner(Ref<StreamServerConnection>&& streamConnection, ASCIILiteral workQueueName, ReceiverName receiverName, uint64_t identifier, std::optional<WebKit::SharedPreferencesForWebProcess> sharedPreferences, Function<void(MessageName)>&& didReceiveInvalidMessage)
    : m_connection(streamConnection->connection())
    , m_workQueue(StreamConnectionWorkQueue::create(workQueueName))
    , m_streamConnection(WTF::move(streamConnection))
    , m_receiverName(receiverName)
    , m_identifier(identifier)
    , m_sharedPreferencesForWebProcess(WTF::move(sharedPreferences))
    , m_didReceiveInvalidMessage(WTF::move(didReceiveInvalidMessage))
{
}

SwiftReceiverOwner::~SwiftReceiverOwner() = default;

void SwiftReceiverOwner::start(StreamMessageReceiver& receiver, SwiftReceiverOwnerClient& client)
{
    RELEASE_ASSERT(!m_receiver && m_streamConnection);
    m_receiver = &receiver;
    m_client.store(&client, std::memory_order_release);
    RefPtr streamConnection = m_streamConnection;
    streamConnection->startReceivingMessages(receiver, m_receiverName, m_identifier);
    m_workQueue->dispatch([protectedThis = Ref { *this }] {
        protectedThis->workQueueInitialize();
    });
}

void SwiftReceiverOwner::workQueueInitialize()
{
    assertIsCurrent(workQueue());
    if (RefPtr streamConnection = m_streamConnection)
        streamConnection->open(*this, m_workQueue);
}

void SwiftReceiverOwner::scheduleWork()
{
    m_workQueue->dispatch([protectedThis = Ref { *this }] {
        if (auto* client = protectedThis->m_client.load(std::memory_order_acquire))
            client->runScheduledWork();
    });
}

void SwiftReceiverOwner::stopListeningForIPC()
{
    m_workQueue->dispatch([protectedThis = Ref { *this }] {
        protectedThis->workQueueUninitialize();
    });
    m_workQueue->stopAndWaitForCompletion([this] {
        assertIsCurrent(workQueue());
        if (auto* client = m_client.exchange(nullptr, std::memory_order_acq_rel))
            client->didStopWorkQueue();
        m_receiver = nullptr;
    });
}

void SwiftReceiverOwner::workQueueUninitialize()
{
    assertIsCurrent(workQueue());
    RefPtr streamConnection = std::exchange(m_streamConnection, nullptr);
    if (!streamConnection)
        return;
    if (m_receiver)
        streamConnection->stopReceivingMessages(m_receiverName, m_identifier);
    streamConnection->invalidate();
    if (auto* client = m_client.load(std::memory_order_acquire))
        client->didStopReceiving();
}

void SwiftReceiverOwner::didReceiveStreamMessage(StreamServerConnection&, Decoder& decoder)
{
    // Only the receiver is registered for messages, never its owner.
    ASSERT_NOT_REACHED();
    decoder.markInvalid();
}

void SwiftReceiverOwner::didReceiveInvalidMessage(StreamServerConnection&, MessageName messageName, const Vector<uint32_t>&)
{
    m_didReceiveInvalidMessage(messageName);
}

} // namespace IPC

#endif // ENABLE(SWIFT_IPC_RECEIVERS)
