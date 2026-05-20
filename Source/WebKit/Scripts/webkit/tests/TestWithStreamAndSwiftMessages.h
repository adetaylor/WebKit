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
#include <wtf/Forward.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/WTFString.h>

#if ENABLE(SWIFT_TEST_CONDITION)
namespace WebKit {
class TestWithStreamAndSwift;
class TestWithStreamAndSwiftMessageForwarder;
class TestWithStreamAndSwiftWeakRef;
}
#endif // ENABLE(SWIFT_TEST_CONDITION)

#if ENABLE(SWIFT_TEST_CONDITION)
#include "StreamMessageReceiver.h"
namespace IPC { class StreamServerConnection; }

namespace WebKit {

class TestWithStreamAndSwiftMessageForwarder: public ThreadSafeRefCounted<TestWithStreamAndSwiftMessageForwarder>, public IPC::StreamMessageReceiver {
public:
    static Ref<TestWithStreamAndSwiftMessageForwarder> createFromWeak(WebKit::TestWithStreamAndSwiftWeakRef* _Nonnull handler)
    {
        return adoptRef(*new TestWithStreamAndSwiftMessageForwarder(handler));
    }
    ~TestWithStreamAndSwiftMessageForwarder();
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }
private:
    TestWithStreamAndSwiftMessageForwarder(WebKit::TestWithStreamAndSwiftWeakRef* _Nonnull);
    std::unique_ptr<WebKit::TestWithStreamAndSwift> getMessageTarget();
    std::unique_ptr<WebKit::TestWithStreamAndSwiftWeakRef> m_handler;
} SWIFT_SHARED_REFERENCE(.ref, .deref);

}

using RefTestWithStreamAndSwiftMessageForwarder = Ref<WebKit::TestWithStreamAndSwiftMessageForwarder>;

#endif // ENABLE(SWIFT_TEST_CONDITION)
namespace Messages {
namespace TestWithStreamAndSwift {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithStreamAndSwift;
}

class SendString {
public:
    using Arguments = std::tuple<String>;

    static IPC::MessageName name() { return IPC::MessageName::TestWithStreamAndSwift_SendString; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

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

class SendStringAsync {
public:
    using Arguments = std::tuple<String>;

    static IPC::MessageName name() { return IPC::MessageName::TestWithStreamAndSwift_SendStringAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithStreamAndSwift_SendStringAsyncReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<int64_t>;
    using Reply = CompletionHandler<void(int64_t)>;
    using Promise = WTF::NativePromise<int64_t, IPC::Error>;
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

class SendStringAsyncReply {
public:
    using Arguments = std::tuple<int64_t>;

    static IPC::MessageName name() { return IPC::MessageName::TestWithStreamAndSwift_SendStringAsyncReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    explicit SendStringAsyncReply(int64_t returnValue)
        : m_returnValue(returnValue)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_returnValue;
    }

private:
    int64_t m_returnValue;
};

} // namespace TestWithStreamAndSwift
} // namespace Messages
#if ENABLE(SWIFT_TEST_CONDITION)

namespace CompletionHandlers {
namespace TestWithStreamAndSwift {
using SendStringAsyncCompletionHandler = WTF::RefCountable<Messages::TestWithStreamAndSwift::SendStringAsync::Reply>;
} // namespace TestWithStreamAndSwift
} // namespace CompletionHandlers

#endif // ENABLE(SWIFT_TEST_CONDITION)
