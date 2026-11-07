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
#include "IPCSemaphore.h"
#include "MessageNames.h"
#include "SharedPreferencesForWebProcess.h"
#include "SwiftCoding.h"
#include "WorkQueueMessageReceiver.h"
#include <WebCore/SharedMemory.h>
#include <wtf/Forward.h>
#include <wtf/Function.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/WTFString.h>

namespace WebKit {
class TestWithSwiftWorkQueue;
class TestWithSwiftWorkQueueMessageForwarder;
class TestWithSwiftWorkQueueWeakRef;
}

namespace WebKit {

// Registered with startReceivingMessages() on one serial queue, which the handlers are confined to.
// It keeps its target alive, so the target must not keep it.
class TestWithSwiftWorkQueueMessageForwarder final : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {
public:
    static Ref<TestWithSwiftWorkQueueMessageForwarder> createFromWeak(WebKit::TestWithSwiftWorkQueueWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithSwiftWorkQueueMessageForwarder(handler));
    }
    ~TestWithSwiftWorkQueueMessageForwarder();
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;
    void ref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::ref(); }
    void deref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::deref(); }
    // Registers this for the messages to destinationID on connection, dispatched on workQueue, which it records as
    // the queue its handlers are confined to. Registering again, for another destination, must name the same queue.
    void startReceivingMessages(IPC::Connection&, WorkQueue&, uint64_t destinationID = 0);
    // Lets the C++ that registers the receiver supply its shared preferences, which dispatch otherwise asks Swift for.
    void setSharedPreferencesProvider(Function<std::optional<SharedPreferencesForWebProcess>()>&& provider) { m_sharedPreferencesProvider = WTF::move(provider); }
private:
    TestWithSwiftWorkQueueMessageForwarder(WebKit::TestWithSwiftWorkQueueWeakRef* WTF_NONNULL);
    std::unique_ptr<WebKit::TestWithSwiftWorkQueueWeakRef> m_handler;
    Function<std::optional<SharedPreferencesForWebProcess>()> m_sharedPreferencesProvider;
    RefPtr<WorkQueue> m_workQueue;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

using OptionalSharedPreferencesForWebProcess = std::optional<SharedPreferencesForWebProcess>;

}

using RefTestWithSwiftWorkQueueMessageForwarder = Ref<WebKit::TestWithSwiftWorkQueueMessageForwarder>;

namespace Messages {
namespace TestWithSwiftWorkQueue {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithSwiftWorkQueue;
}

class SendString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendString; }
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

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendStringSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<String, uint64_t>;
    using Reply = CompletionHandler<void(String&&, uint64_t)>;
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

class SendStringAsync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendStringAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftWorkQueue_SendStringAsyncReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<String>;
    using Reply = CompletionHandler<void(String&&)>;
    using Promise = WTF::NativePromise<String, IPC::Error>;
    explicit SendStringAsync(const String& url)
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

class SendEmptyAsync {
public:
    using Arguments = std::tuple<>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendEmptyAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftWorkQueue_SendEmptyAsyncReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<>;
    using Reply = CompletionHandler<void()>;
    using Promise = WTF::NativePromise<void, IPC::Error>;
    SendEmptyAsync()
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
    }

private:
};

class SendCxxDecoded {
public:
    using Arguments = std::tuple<uint32_t, std::optional<WebCore::SharedMemory::Handle>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxDecoded; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxDecodedReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<bool>;
    using Reply = CompletionHandler<void(bool)>;
    using Promise = WTF::NativePromise<bool, IPC::Error>;
    SendCxxDecoded(uint32_t value, std::optional<WebCore::SharedMemory::Handle>&& handle)
        : m_value(value)
        , m_handle(WTF::move(handle))
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
        encoder << WTF::move(m_handle);
    }

private:
    uint32_t m_value;
    std::optional<WebCore::SharedMemory::Handle>&& m_handle;
};

class SendSharedMemory {
public:
    using Arguments = std::tuple<WebCore::SharedMemory::Handle>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendSharedMemory; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftWorkQueue_SendSharedMemoryReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<std::optional<WebCore::SharedMemory::Handle>>;
    using Reply = CompletionHandler<void(std::optional<WebCore::SharedMemory::Handle>&&)>;
    using Promise = WTF::NativePromise<std::optional<WebCore::SharedMemory::Handle>, IPC::Error>;
    explicit SendSharedMemory(WebCore::SharedMemory::Handle&& handle)
        : m_handle(WTF::move(handle))
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << WTF::move(m_handle);
    }

private:
    WebCore::SharedMemory::Handle&& m_handle;
};

class SendSemaphoreSync {
public:
    using Arguments = std::tuple<IPC::Semaphore>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendSemaphoreSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<IPC::Semaphore>;
    using Reply = CompletionHandler<void(IPC::Semaphore&&)>;
    explicit SendSemaphoreSync(const IPC::Semaphore& semaphore)
        : m_semaphore(semaphore)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_semaphore;
    }

private:
    const IPC::Semaphore& m_semaphore;
};

class SendCxxString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxString; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit SendCxxString(const String& url)
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

class SendCxxStringSync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxStringSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<uint64_t>;
    using Reply = CompletionHandler<void(uint64_t)>;
    explicit SendCxxStringSync(const String& url)
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

class SendCxxStringAsync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxStringAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxStringAsyncReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<uint64_t>;
    using Reply = CompletionHandler<void(uint64_t)>;
    using Promise = WTF::NativePromise<uint64_t, IPC::Error>;
    explicit SendCxxStringAsync(const String& url)
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

class SendStringAsyncReply {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendStringAsyncReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit SendStringAsyncReply(const String& reply)
        : m_reply(reply)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_reply;
    }

private:
    const String& m_reply;
};

class SendEmptyAsyncReply {
public:
    using Arguments = std::tuple<>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendEmptyAsyncReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    SendEmptyAsyncReply()
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
    }

private:
};

class SendCxxDecodedReply {
public:
    using Arguments = std::tuple<bool>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxDecodedReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit SendCxxDecodedReply(bool success)
        : m_success(success)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_success;
    }

private:
    bool m_success;
};

class SendSharedMemoryReply {
public:
    using Arguments = std::tuple<std::optional<WebCore::SharedMemory::Handle>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendSharedMemoryReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit SendSharedMemoryReply(std::optional<WebCore::SharedMemory::Handle>&& handle)
        : m_handle(WTF::move(handle))
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << WTF::move(m_handle);
    }

private:
    std::optional<WebCore::SharedMemory::Handle>&& m_handle;
};

class SendCxxStringAsyncReply {
public:
    using Arguments = std::tuple<uint64_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftWorkQueue_SendCxxStringAsyncReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit SendCxxStringAsyncReply(uint64_t length)
        : m_length(length)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_length;
    }

private:
    uint64_t m_length;
};

} // namespace TestWithSwiftWorkQueue
} // namespace Messages

namespace CompletionHandlers {
namespace TestWithSwiftWorkQueue {
using SendCxxStringSyncCompletionHandler = WTF::RefCountable<Messages::TestWithSwiftWorkQueue::SendCxxStringSync::Reply>;
using SendCxxStringAsyncCompletionHandler = WTF::RefCountable<Messages::TestWithSwiftWorkQueue::SendCxxStringAsync::Reply>;

void completeWithDefaultReply(SendCxxStringSyncCompletionHandler&);

void complete(SendCxxStringSyncCompletionHandler&, uint64_t);
} // namespace TestWithSwiftWorkQueue
} // namespace CompletionHandlers

namespace CxxDecodedArguments {
namespace TestWithSwiftWorkQueue {

using SendCxxDecodedHandle = IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>;

} // namespace TestWithSwiftWorkQueue
} // namespace CxxDecodedArguments

