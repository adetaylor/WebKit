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
#include "SwiftCoding.h"
#include <wtf/Forward.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/WTFString.h>


namespace Messages {
namespace TestWithWorkQueueSwiftImplementation {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithWorkQueueSwiftImplementation;
}

class SendString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithWorkQueueSwiftImplementation_SendString; }
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

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithWorkQueueSwiftImplementation_SendStringSync; }
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

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithWorkQueueSwiftImplementation_SendStringAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithWorkQueueSwiftImplementation_SendStringAsyncReply; }
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

class SendCxxString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithWorkQueueSwiftImplementation_SendCxxString; }
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

class SendStringAsyncReply {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithWorkQueueSwiftImplementation_SendStringAsyncReply; }
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

} // namespace TestWithWorkQueueSwiftImplementation
} // namespace Messages
namespace WebKit {
class TestWithWorkQueueSwiftImplementation;
}

// What TestWithWorkQueueSwiftImplementationMessageReceiver.swift implements, with @cxx @implementation: the dispatch of each message that
// takes Swift types, which decodes it and calls the handler, and returns false if it is malformed.
namespace SwiftDispatch {
namespace TestWithWorkQueueSwiftImplementation {

bool dispatchSendString(WebKit::TestWithWorkQueueSwiftImplementation* WTF_NONNULL, IPC::Connection* WTF_NONNULL, IPC::SwiftDecoder);
bool dispatchSendStringSync(WebKit::TestWithWorkQueueSwiftImplementation* WTF_NONNULL, IPC::Connection* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendStringAsync(WebKit::TestWithWorkQueueSwiftImplementation* WTF_NONNULL, IPC::Connection* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);

} // namespace TestWithWorkQueueSwiftImplementation
} // namespace SwiftDispatch

