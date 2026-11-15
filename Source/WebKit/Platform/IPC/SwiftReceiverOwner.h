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

#pragma once

#if ENABLE(SWIFT_IPC_RECEIVERS)

#include "MessageNames.h"
#include "SharedPreferencesForWebProcess.h"
#include "StreamConnectionWorkQueue.h"
#include "StreamServerConnection.h"
#include <atomic>
#include <concepts>
#include <optional>
#include <type_traits>
#include <wtf/Function.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>

namespace IPC {

// What the owner of a top-level receiver written in Swift asks of it, on the owner's work queue. The generated message
// forwarder of a receiver with 'SwiftReceiverOwner' implements this with the receiver's Swift methods of the same names.
class SwiftReceiverOwnerClient {
public:
    virtual ~SwiftReceiverOwnerClient() = default;

    // Runs the work the receiver asked for with SwiftReceiverOwner::scheduleWork() since it last ran.
    virtual void runScheduledWork() = 0;
    // The receiver's stream connection has been invalidated, so no message comes after this.
    virtual void didStopReceiving() = 0;
    // The work queue has stopped, so nothing else runs on it, or, for an owner on a shared work queue, the owner runs
    // nothing more of the receiver's on it. The last call, after which the owner lets go of the receiver.
    virtual void didStopWorkQueue() = 0;
};

// A C++ receiver on the owner's stream connection that works with the owner's Swift receiver, which the owner keeps from
// setCompanion() until the stream connection stops, and tells, on the work queue, what the stream connection's client is told.
class SwiftReceiverOwnerCompanion : public StreamMessageReceiver {
protected:
    friend class SwiftReceiverOwner;
    // Whether to be told didRunOutOfMessages(), which the owner asks once, in setCompanion(): it comes after every batch.
    virtual bool wantsDidRunOutOfMessages() const { return false; }
    // The stream connection has dispatched the messages it had.
    virtual void didRunOutOfMessages() { }
    // The stream connection has been invalidated, so no message comes after this. Before the receiver's didStopReceiving().
    virtual void didStopReceiving() = 0;
};

// Owns a top-level receiver written in Swift for the C++ that creates it: the stream connection its messages come on, the
// work queue it receives them on, and its message forwarder, from start until stop. The receiver is created after its
// owner, starts receiving with the generated startReceiving(on:), which calls startSwiftReceiver(), and gets onto the
// work queue with scheduleWork() rather than by passing functions to it. Its Swift sends go on connection().
// Sendable for Swift, which can only call what may be called on any thread.
class SWIFT_UNCHECKED_SENDABLE SwiftReceiverOwner final : public StreamServerConnection::Client {
    WTF_MAKE_TZONE_ALLOCATED(SwiftReceiverOwner);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(SwiftReceiverOwner);
public:
    // The receiver of the messages to identifier, with those shared preferences. A message the stream connection finds
    // invalid goes to didReceiveInvalidMessage, on the work queue.
    static Ref<SwiftReceiverOwner> create(Ref<StreamServerConnection>&&, ASCIILiteral workQueueName, ReceiverName, uint64_t identifier, std::optional<WebKit::SharedPreferencesForWebProcess>, Function<void(MessageName)>&& didReceiveInvalidMessage) __attribute__((availability(swift, unavailable)));
    // The same, on a work queue that other receivers share and that outlives the owner, which stopping doesn't stop. Its
    // stream connection opens as soon as it is made, so that sends on it go before its receiver starts, which it may
    // never do; it starts on the work queue.
    static Ref<SwiftReceiverOwner> create(Ref<StreamServerConnection>&&, StreamConnectionWorkQueue& sharedWorkQueue, ReceiverName, uint64_t identifier, std::optional<WebKit::SharedPreferencesForWebProcess>, Function<void(MessageName)>&& didReceiveInvalidMessage) __attribute__((availability(swift, unavailable)));

    ~SwiftReceiverOwner();

    // Stops the receiver's messages, and then the work queue, and lets go of the receiver. For
    // ScopedActiveMessageReceiveQueue, or the Swift state that holds the owner, on the main thread, which created this. An
    // owner on a shared work queue does the same on that queue, later, and leaves the queue running.
    SWIFT_MAIN_ACTOR void stopListeningForIPC();

    // The shared preferences are those of the receiver's creation, which registerSwiftStreamReceiver() keeps a copy of.
    static constexpr bool hasFixedSharedPreferencesForWebProcess = true;
    std::optional<WebKit::SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const { return m_sharedPreferencesForWebProcess; }

    // Null once the receiver stops receiving. On the work queue, for registerSwiftStreamReceiver().
    RefPtr<StreamServerConnection> streamConnection() const __attribute__((availability(swift, unavailable))) { return m_streamConnection; }
    // The connection the receiver's Swift sends go on.
    Connection& connection() const SWIFT_RETURNS_UNRETAINED { return m_connection.get(); }
    StreamConnectionWorkQueue& workQueue() const LIFETIME_BOUND __attribute__((availability(swift, unavailable))) { return m_workQueue.get(); }

    // On any thread.
    bool isWorkQueueCurrent() const { return m_workQueue->isCurrent(); }
    // Asks the work queue to run the receiver's runScheduledWork(), from any thread, once the receiver has started (and so
    // never from the receiver's creation, before startReceiving(on:)). Once the work queue stops, it runs
    // nothing more: the receiver's didStopWorkQueue() runs what is still waiting.
    void scheduleWork();

    // For startSwiftReceiver().
    void start(StreamMessageReceiver&, SwiftReceiverOwnerClient&) __attribute__((availability(swift, unavailable)));
    // On the work queue, until the stream connection stops.
    void setCompanion(SwiftReceiverOwnerCompanion&) __attribute__((availability(swift, unavailable)));

private:
    SwiftReceiverOwner(Ref<StreamServerConnection>&&, Ref<StreamConnectionWorkQueue>&&, bool ownsWorkQueue, ReceiverName, uint64_t identifier, std::optional<WebKit::SharedPreferencesForWebProcess>, Function<void(MessageName)>&&);

    void workQueueInitialize();
    void workQueueUninitialize();
    void releaseReceiver();

    // StreamServerConnection::Client.
    void didReceiveStreamMessage(StreamServerConnection&, Decoder&) final;
    void didReceiveInvalidMessage(StreamServerConnection&, MessageName, const Vector<uint32_t>&) final;
    void didRunOutOfMessages() final;

    const Ref<Connection> m_connection;
    const Ref<StreamConnectionWorkQueue> m_workQueue;
    const bool m_ownsWorkQueue;
    RefPtr<StreamServerConnection> m_streamConnection;
    const ReceiverName m_receiverName;
    const uint64_t m_identifier;
    const std::optional<WebKit::SharedPreferencesForWebProcess> m_sharedPreferencesForWebProcess;
    const Function<void(MessageName)> m_didReceiveInvalidMessage;
    // From start() to didStopWorkQueue(). The receiver is the client, which scheduleWork() reads on the work queue.
    RefPtr<StreamMessageReceiver> m_receiver;
    // On the work queue.
    RefPtr<SwiftReceiverOwnerCompanion> m_companion;
    bool m_companionWantsDidRunOutOfMessages { false };
    std::atomic<SwiftReceiverOwnerClient*> m_client { nullptr };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

template<typename> struct IsRefOfSwiftReceiverOwnerClient : std::false_type { };
template<typename T> struct IsRefOfSwiftReceiverOwnerClient<Ref<T>> : std::bool_constant<std::derived_from<T, StreamMessageReceiver> && std::derived_from<T, SwiftReceiverOwnerClient>> { };

// A C++ object that gives the owner of a Swift receiver it works with, for the receiver to start on.
template<typename Provider>
concept SwiftReceiverOwnerProvider = requires(Provider& provider) {
    { provider.swiftReceiverOwner() } -> std::same_as<SwiftReceiverOwner&>;
};

// Starts the owner's receiver, whose forwarder this registers for the owner's messages, with the owner's shared
// preferences, and keeps until the work queue stops. For generated Swift, which passes the owner, or the C++ object that
// provides it, a foreign reference type, as a pointer to it, and which can't pass a forwarder as the
// StreamMessageReceiver it is, but can pass the Ref to it that it holds. The static_asserts are there because the
// constraints aren't enforced for Swift callers.
template<typename OwnerPointer, typename ForwarderRef>
void startSwiftReceiver(const OwnerPointer& ownerPointer, const ForwarderRef& forwarder)
{
    static_assert(std::is_pointer_v<OwnerPointer>);
    using Owner = std::remove_pointer_t<OwnerPointer>;
    static_assert(std::is_same_v<Owner, SwiftReceiverOwner> || SwiftReceiverOwnerProvider<Owner>);
    static_assert(IsRefOfSwiftReceiverOwnerClient<ForwarderRef>::value);
    auto& owner = [&] -> SwiftReceiverOwner& {
        if constexpr (std::is_same_v<Owner, SwiftReceiverOwner>)
            return *ownerPointer;
        else
            return ownerPointer->swiftReceiverOwner();
    }();
    if constexpr (requires { forwarder->setSharedPreferencesProvider(nullptr); }) {
        forwarder->setSharedPreferencesProvider([sharedPreferences = owner.sharedPreferencesForWebProcess()] {
            return sharedPreferences;
        });
    }
    owner.start(forwarder.get(), forwarder.get());
}

} // namespace IPC

#endif // ENABLE(SWIFT_IPC_RECEIVERS)
