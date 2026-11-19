/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "ArgumentCoders.h"
#include "Connection.h"
#include "MessageNames.h"
#include "WorkQueueMessageReceiver.h"
#include <wtf/Forward.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/WTFString.h>

namespace WebKit {
class TestWithSwiftTarget;
class TestWithSwiftTargetMessageForwarder;
class TestWithSwiftTargetWeakRef;
}

namespace WebKit {

// Registered with startReceivingMessages() on one serial queue, which the handlers are confined to.
// It keeps its target alive, so the target must not keep it.
class TestWithSwiftTargetMessageForwarder final : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {
public:
    static Ref<TestWithSwiftTargetMessageForwarder> createFromWeak(WebKit::TestWithSwiftTargetWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithSwiftTargetMessageForwarder(handler));
    }
    ~TestWithSwiftTargetMessageForwarder();
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;
    void ref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::ref(); }
    void deref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::deref(); }
    // Registers this for the messages to destinationID on connection, dispatched on workQueue, which it records as
    // the queue its handlers are confined to. Registering again, for another destination, must name the same queue.
    void startReceivingMessages(IPC::Connection&, WorkQueue&, uint64_t destinationID = 0);
private:
    TestWithSwiftTargetMessageForwarder(WebKit::TestWithSwiftTargetWeakRef* WTF_NONNULL);
    std::unique_ptr<WebKit::TestWithSwiftTargetWeakRef> m_handler;
    RefPtr<WorkQueue> m_workQueue;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}

using RefTestWithSwiftTargetMessageForwarder = Ref<WebKit::TestWithSwiftTargetMessageForwarder>;

namespace Messages {
namespace TestWithSwiftTarget {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithSwiftTarget;
}

class SendString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftTarget_SendString; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit SendString(const String& url)
        : m_url(url)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_url;
    }

private:
    const String& m_url;
};

class SendStringSync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftTarget_SendStringSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<uint64_t>;
    using Reply = CompletionHandler<void(uint64_t)>;
    explicit SendStringSync(const String& url)
        : m_url(url)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_url;
    }

private:
    const String& m_url;
};

} // namespace TestWithSwiftTarget
} // namespace Messages

namespace CompletionHandlers {
namespace TestWithSwiftTarget {

} // namespace TestWithSwiftTarget
} // namespace CompletionHandlers

