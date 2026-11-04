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
#include "SwiftCoding.h"
#include <wtf/Forward.h>
#include <wtf/RefPtr.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WebCore {
class FloatRect;
}
namespace WebKit {
class TestWithStreamSwiftLentState;
class TestWithStreamSwiftLentStateMessageForwarder;
class TestWithStreamSwiftLentStateWeakRef;
}

namespace WebKit {
class TestWithStreamSwiftLentStateLender;
}

namespace WebKit {

class TestWithStreamSwiftLentStateMessageForwarder final : public IPC::StreamMessageReceiver {
public:
    static Ref<TestWithStreamSwiftLentStateMessageForwarder> createFromWeak(WebKit::TestWithStreamSwiftLentStateWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithStreamSwiftLentStateMessageForwarder(handler));
    }
    ~TestWithStreamSwiftLentStateMessageForwarder();
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    void ref() const { StreamMessageReceiver::ref(); }
    void deref() const { StreamMessageReceiver::deref(); }
    // Lets the C++ that registers the receiver lend its handlers the state they take inout, through the lender's
    // lendSwiftReceiverState(), for one message at a time. The forwarder keeps the lender, so the lender must not keep it.
    void setStateLender(WebKit::TestWithStreamSwiftLentStateLender&);
private:
    TestWithStreamSwiftLentStateMessageForwarder(WebKit::TestWithStreamSwiftLentStateWeakRef* WTF_NONNULL);
    std::unique_ptr<WebKit::TestWithStreamSwiftLentStateWeakRef> m_handler;
    RefPtr<WebKit::TestWithStreamSwiftLentStateLender> m_stateLender;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}

using RefTestWithStreamSwiftLentStateMessageForwarder = Ref<WebKit::TestWithStreamSwiftLentStateMessageForwarder>;

namespace Messages {
namespace TestWithStreamSwiftLentState {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithStreamSwiftLentState;
}

class Reset {
public:
    using Arguments = std::tuple<>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftLentState_Reset; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    Reset()
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
    }

private:
};

class SetValues {
public:
    using Arguments = std::tuple<uint32_t, float>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftLentState_SetValues; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    SetValues(uint32_t value, float scale)
        : m_value(value)
        , m_scale(scale)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
        encoder << m_scale;
    }

private:
    uint32_t m_value;
    float m_scale;
};

class Draw {
public:
    using Arguments = std::tuple<WebCore::FloatRect, bool>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftLentState_Draw; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    Draw(const WebCore::FloatRect& rect, bool clip)
        : m_rect(rect)
        , m_clip(clip)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_rect;
        encoder << m_clip;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::FloatRect& m_rect;
    bool m_clip;
};

} // namespace TestWithStreamSwiftLentState
} // namespace Messages

namespace CompletionHandlers {
namespace TestWithStreamSwiftLentState {

} // namespace TestWithStreamSwiftLentState
} // namespace CompletionHandlers

