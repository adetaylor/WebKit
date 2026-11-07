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
#include "StreamMessageReceiver.h"
#include <wtf/Forward.h>
#include <wtf/MachSendRight.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>

namespace WebKit {
class TestWithStreamSwiftReplyValues;
class TestWithStreamSwiftReplyValuesMessageForwarder;
class TestWithStreamSwiftReplyValuesWeakRef;
}

namespace WebKit {

class TestWithStreamSwiftReplyValuesMessageForwarder final : public IPC::StreamMessageReceiver {
public:
    static Ref<TestWithStreamSwiftReplyValuesMessageForwarder> createFromWeak(WebKit::TestWithStreamSwiftReplyValuesWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithStreamSwiftReplyValuesMessageForwarder(handler));
    }
    ~TestWithStreamSwiftReplyValuesMessageForwarder();
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    void ref() const { StreamMessageReceiver::ref(); }
    void deref() const { StreamMessageReceiver::deref(); }
private:
    TestWithStreamSwiftReplyValuesMessageForwarder(WebKit::TestWithStreamSwiftReplyValuesWeakRef* WTF_NONNULL);
    std::unique_ptr<WebKit::TestWithStreamSwiftReplyValuesWeakRef> m_handler;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}

using RefTestWithStreamSwiftReplyValuesMessageForwarder = Ref<WebKit::TestWithStreamSwiftReplyValuesMessageForwarder>;

namespace Messages {
namespace TestWithStreamSwiftReplyValues {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithStreamSwiftReplyValues;
}

class SendLaterSync {
public:
    using Arguments = std::tuple<uint32_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftReplyValues_SendLaterSync; }
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

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftReplyValues_SendCxxEncodedSync; }
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

} // namespace TestWithStreamSwiftReplyValues
} // namespace Messages

namespace CompletionHandlers {
namespace TestWithStreamSwiftReplyValues {

} // namespace TestWithStreamSwiftReplyValues
} // namespace CompletionHandlers

