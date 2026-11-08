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
#include <WebCore/SharedMemory.h>
#include <span>
#include <wtf/Forward.h>
#include <wtf/MachSendRight.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>


namespace Messages {
namespace TestWithStreamSwiftImplementation {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithStreamSwiftImplementation;
}

class SendString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendString; }
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

class SendValues {
public:
    using Arguments = std::tuple<uint32_t, std::optional<uint64_t>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendValues; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    SendValues(uint32_t value, const std::optional<uint64_t>& optionalValue)
        : m_value(value)
        , m_optionalValue(optionalValue)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
        SUPPRESS_FORWARD_DECL_ARG encoder << m_optionalValue;
    }

private:
    uint32_t m_value;
    SUPPRESS_FORWARD_DECL_MEMBER const std::optional<uint64_t>& m_optionalValue;
};

class SendEmpty {
public:
    using Arguments = std::tuple<>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendEmpty; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    SendEmpty()
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
    }

private:
};

#if PLATFORM(COCOA)
class SendCocoaValue {
public:
    using Arguments = std::tuple<uint64_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCocoaValue; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    explicit SendCocoaValue(uint64_t value)
        : m_value(value)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
    }

private:
    uint64_t m_value;
};
#endif

class SendStringSync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendStringSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

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

class SendEmptySync {
public:
    using Arguments = std::tuple<>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendEmptySync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<>;
    using Reply = CompletionHandler<void()>;
    SendEmptySync()
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
    }

private:
};

class SendStringAsync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendStringAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendStringAsyncReply; }
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

class SendLaterSync {
public:
    using Arguments = std::tuple<uint32_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendLaterSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = false;
    static constexpr bool isStreamBatched = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<Seconds, Seconds>;
    using Reply = CompletionHandler<void(Seconds&&, Seconds&&)>;
    explicit SendLaterSync(uint32_t value)
        : m_value(value)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
    }

private:
    uint32_t m_value;
};

class SendCxxEncodedSync {
public:
    using Arguments = std::tuple<uint32_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxEncodedSync; }
    static constexpr bool isSync = true;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = false;
    static constexpr bool isStreamBatched = false;

    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<Vector<MachSendRight>>;
    using Reply = CompletionHandler<void(Vector<MachSendRight>&&)>;
    explicit SendCxxEncodedSync(uint32_t count)
        : m_count(count)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_count;
    }

private:
    uint32_t m_count;
};

class SendCxxDecoded {
public:
    using Arguments = std::tuple<uint32_t, std::optional<WebCore::SharedMemory::Handle>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxDecoded; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = false;
    static constexpr bool isReplyStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxDecodedReply; }
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

class SendLentBytes {
public:
    using Arguments = std::tuple<uint32_t, std::span<const uint8_t>, uint64_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendLentBytes; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    SendLentBytes(uint32_t value, const std::span<const uint8_t>& bytes, uint64_t tail)
        : m_value(value)
        , m_bytes(bytes)
        , m_tail(tail)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
        SUPPRESS_FORWARD_DECL_ARG encoder << m_bytes;
        encoder << m_tail;
    }

private:
    uint32_t m_value;
    SUPPRESS_FORWARD_DECL_MEMBER const std::span<const uint8_t>& m_bytes;
    uint64_t m_tail;
};

class SendWithConnection {
public:
    using Arguments = std::tuple<uint32_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendWithConnection; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    explicit SendWithConnection(uint32_t value)
        : m_value(value)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
    }

private:
    uint32_t m_value;
};

class SendCxxString {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxString; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

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

class SendCxxStringAsync {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsync; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isReplyStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsyncReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<String>;
    using Reply = CompletionHandler<void(String&&)>;
    using Promise = WTF::NativePromise<String, IPC::Error>;
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

class SendSendRight {
public:
    using Arguments = std::tuple<MachSendRight>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendSendRight; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = false;
    static constexpr bool isStreamBatched = false;

    explicit SendSendRight(MachSendRight&& sendRight)
        : m_sendRight(WTF::move(sendRight))
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << WTF::move(m_sendRight);
    }

private:
    MachSendRight&& m_sendRight;
};

class SendStringAsyncReply {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendStringAsyncReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

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

class SendCxxDecodedReply {
public:
    using Arguments = std::tuple<bool>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxDecodedReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

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

class SendCxxStringAsyncReply {
public:
    using Arguments = std::tuple<String>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsyncReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    explicit SendCxxStringAsyncReply(const String& reply)
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

} // namespace TestWithStreamSwiftImplementation
} // namespace Messages
namespace CxxDecodedArguments {
namespace TestWithStreamSwiftImplementation {

using SendCxxDecodedHandle = IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>;

} // namespace TestWithStreamSwiftImplementation
} // namespace CxxDecodedArguments

namespace WebKit {
class TestWithStreamSwiftImplementation;
}

// What TestWithStreamSwiftImplementationMessageReceiver.swift implements, with @cxx @implementation: the dispatch of each message that
// takes Swift types, which decodes it and calls the handler, and returns false if it is malformed.
namespace SwiftDispatch {
namespace TestWithStreamSwiftImplementation {

bool dispatchSendString(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder);
bool dispatchSendValues(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder);
bool dispatchSendEmpty(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder);
bool dispatchSendCocoaValue(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder);
bool dispatchSendStringSync(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendEmptySync(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::StreamServerConnection* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendStringAsync(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendLaterSync(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendCxxEncodedSync(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendCxxDecoded(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);
bool dispatchSendLentBytes(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::SwiftDecoder);
bool dispatchSendWithConnection(WebKit::TestWithStreamSwiftImplementation* WTF_NONNULL, IPC::StreamServerConnection* WTF_NONNULL, IPC::SwiftDecoder);

} // namespace TestWithStreamSwiftImplementation
} // namespace SwiftDispatch

