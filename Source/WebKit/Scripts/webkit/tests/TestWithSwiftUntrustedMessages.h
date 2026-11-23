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
#include "SharedPreferencesForWebProcess.h"
#include "Untrusted.h"
#include <optional>
#include <wtf/Forward.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WebCore {
struct FrameIdentifierType;
using FrameIdentifier = ObjectIdentifier<FrameIdentifierType>;
class SecurityOriginData;
struct ExceptionData;
}
namespace WebKit {
class TestWithSwiftUntrusted;
class TestWithSwiftUntrustedMessageForwarder;
class TestWithSwiftUntrustedTarget;
class TestWithSwiftUntrustedWeakRef;
}

namespace WebKit {

class TestWithSwiftUntrustedMessageForwarder: public RefCounted<TestWithSwiftUntrustedMessageForwarder>, public IPC::MessageReceiver {
public:
    static Ref<TestWithSwiftUntrustedMessageForwarder> createFromWeak(WebKit::TestWithSwiftUntrustedWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithSwiftUntrustedMessageForwarder(handler));
    }
    ~TestWithSwiftUntrustedMessageForwarder();
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
private:
    TestWithSwiftUntrustedMessageForwarder(WebKit::TestWithSwiftUntrustedWeakRef* WTF_NONNULL);
    std::optional<WebKit::TestWithSwiftUntrustedTarget> getMessageTarget();
    std::unique_ptr<WebKit::TestWithSwiftUntrustedWeakRef> m_handler;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

using OptionalSharedPreferencesForWebProcess = std::optional<SharedPreferencesForWebProcess>;

}

using RefTestWithSwiftUntrustedMessageForwarder = Ref<WebKit::TestWithSwiftUntrustedMessageForwarder>;

namespace WebCore {
using UntrustedOptionalSecurityOriginData = IPC::Untrusted<std::optional<WebCore::SecurityOriginData>>;
using UntrustedSecurityOriginData = IPC::Untrusted<WebCore::SecurityOriginData>;
}

namespace Messages {
namespace TestWithSwiftUntrusted {

static inline IPC::ReceiverName messageReceiverName()
{
#if ASSERT_ENABLED
    static std::once_flag onceFlag;
    std::call_once(
        onceFlag,
        [&] {
            ASSERT(!isInAuxiliaryProcess());
        }
    );
#endif
    return IPC::ReceiverName::TestWithSwiftUntrusted;
}

class UntrustedOrigin {
public:
    using Arguments = std::tuple<IPC::Untrusted<WebCore::SecurityOriginData>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOrigin; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOriginReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<bool>;
    using Reply = CompletionHandler<void(bool)>;
    using Promise = WTF::NativePromise<bool, IPC::Error>;
    explicit UntrustedOrigin(const WebCore::SecurityOriginData& origin)
        : m_origin(origin)
    {
        ASSERT(isInWebProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_origin;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::SecurityOriginData& m_origin;
};

class UntrustedOptionalOrigin {
public:
    using Arguments = std::tuple<WebCore::FrameIdentifier, IPC::Untrusted<std::optional<WebCore::SecurityOriginData>>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOptionalOrigin; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    static IPC::MessageName asyncMessageReplyName() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOptionalOriginReply; }
    static constexpr auto callbackThread = WTF::CompletionHandlerCallThread::ConstructionThread;
    using ReplyArguments = std::tuple<WebCore::ExceptionData>;
    using Reply = CompletionHandler<void(WebCore::ExceptionData&&)>;
    using Promise = WTF::NativePromise<WebCore::ExceptionData, IPC::Error>;
    UntrustedOptionalOrigin(const WebCore::FrameIdentifier& frameID, const std::optional<WebCore::SecurityOriginData>& parentOrigin)
        : m_frameID(frameID)
        , m_parentOrigin(parentOrigin)
    {
        ASSERT(isInWebProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_frameID;
        SUPPRESS_FORWARD_DECL_ARG encoder << m_parentOrigin;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::FrameIdentifier& m_frameID;
    SUPPRESS_FORWARD_DECL_MEMBER const std::optional<WebCore::SecurityOriginData>& m_parentOrigin;
};

class UntrustedOriginWithoutReply {
public:
    using Arguments = std::tuple<IPC::Untrusted<WebCore::SecurityOriginData>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOriginWithoutReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit UntrustedOriginWithoutReply(const WebCore::SecurityOriginData& origin)
        : m_origin(origin)
    {
        ASSERT(isInWebProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_origin;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::SecurityOriginData& m_origin;
};

class UntrustedOriginReply {
public:
    using Arguments = std::tuple<bool>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOriginReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit UntrustedOriginReply(bool result)
        : m_result(result)
    {
        ASSERT(isInWebProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_result;
    }

private:
    bool m_result;
};

class UntrustedOptionalOriginReply {
public:
    using Arguments = std::tuple<WebCore::ExceptionData>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithSwiftUntrusted_UntrustedOptionalOriginReply; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;

    explicit UntrustedOptionalOriginReply(const WebCore::ExceptionData& exception)
        : m_exception(exception)
    {
        ASSERT(isInWebProcess());
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_exception;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::ExceptionData& m_exception;
};

} // namespace TestWithSwiftUntrusted
} // namespace Messages

namespace CompletionHandlers {
namespace TestWithSwiftUntrusted {
using UntrustedOriginCompletionHandler = WTF::RefCountable<Messages::TestWithSwiftUntrusted::UntrustedOrigin::Reply>;
using UntrustedOptionalOriginCompletionHandler = WTF::RefCountable<Messages::TestWithSwiftUntrusted::UntrustedOptionalOrigin::Reply>;

void completeWithDefaultReply(UntrustedOriginCompletionHandler&);

void completeWithDefaultReply(UntrustedOptionalOriginCompletionHandler&);

void complete(UntrustedOriginCompletionHandler&, bool);
} // namespace TestWithSwiftUntrusted
} // namespace CompletionHandlers

