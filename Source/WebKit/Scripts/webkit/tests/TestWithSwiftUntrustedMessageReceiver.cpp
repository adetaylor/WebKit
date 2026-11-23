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

#include "config.h"
#include "Shared/WebKit-Swift.h" // NOLINT
#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "SharedPreferencesForWebProcess.h" // NOLINT
#include "TestWithSwiftUntrustedMessages.h" // NOLINT
#include "Untrusted.h" // NOLINT
#include <WebCore/ExceptionData.h> // NOLINT
#include <WebCore/FrameIdentifier.h> // NOLINT
#include <WebCore/SecurityOriginData.h> // NOLINT
#include <optional> // NOLINT
#include <utility> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithSwiftUntrustedMessageForwarder::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    auto target = getMessageTarget();
    if (!target) {
        FATAL("Something is keeping a reference to the message forwarder");
        decoder.markInvalid();
        return;
    }
    auto sharedPreferences = target->sharedPreferencesForWebProcess(&connection);
    UNUSED_VARIABLE(sharedPreferences);
    if (!sharedPreferences || !sharedPreferences->someFeature) {
        RELEASE_LOG_ERROR(IPC, "Message %s received by a disabled message receiver TestWithSwiftUntrusted", IPC::description(decoder.messageName()).characters());
        decoder.markInvalid();
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftUntrusted::UntrustedOrigin::name()) {
        IPC::handleMessageAsync<Messages::TestWithSwiftUntrusted::UntrustedOrigin>(connection, decoder, m_handler.get(), &TestWithSwiftUntrustedWeakRef::dispatchUntrustedOrigin);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftUntrusted::UntrustedOptionalOrigin::name()) {
        IPC::handleMessageAsync<Messages::TestWithSwiftUntrusted::UntrustedOptionalOrigin>(connection, decoder, m_handler.get(), &TestWithSwiftUntrustedWeakRef::dispatchUntrustedOptionalOrigin);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftUntrusted::UntrustedOriginWithoutReply::name()) {
        IPC::handleMessage<Messages::TestWithSwiftUntrusted::UntrustedOriginWithoutReply>(connection, decoder, m_handler.get(), &TestWithSwiftUntrustedWeakRef::dispatchUntrustedOriginWithoutReply);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftUntrusted::UntrustedOriginWithReplies::name()) {
        IPC::handleMessageAsync<Messages::TestWithSwiftUntrusted::UntrustedOriginWithReplies>(connection, decoder, m_handler.get(), &TestWithSwiftUntrustedWeakRef::dispatchUntrustedOriginWithReplies);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftUntrusted::UntrustedOriginWithUnnamedReply::name()) {
        IPC::handleMessageAsync<Messages::TestWithSwiftUntrusted::UntrustedOriginWithUnnamedReply>(connection, decoder, m_handler.get(), &TestWithSwiftUntrustedWeakRef::dispatchUntrustedOriginWithUnnamedReply);
        return;
    }
    UNUSED_PARAM(connection);
    RELEASE_LOG_ERROR(IPC, "Unhandled message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithSwiftUntrustedWeakRef> makeTestWithSwiftUntrustedWeakRefUniquePtr(TestWithSwiftUntrustedWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithSwiftUntrustedWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithSwiftUntrustedWeakRef>(newRef);
}

TestWithSwiftUntrustedMessageForwarder::TestWithSwiftUntrustedMessageForwarder(TestWithSwiftUntrustedWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithSwiftUntrustedWeakRefUniquePtr(target))
{
}

std::optional<TestWithSwiftUntrustedTarget> TestWithSwiftUntrustedMessageForwarder::getMessageTarget()
{
    if (!m_handler->hasMessageTarget())
        return std::nullopt;
    return m_handler->messageTarget();
}

TestWithSwiftUntrustedMessageForwarder::~TestWithSwiftUntrustedMessageForwarder()
{
}


} // namespace WebKit

namespace CompletionHandlers {
namespace TestWithSwiftUntrusted {

void completeWithDefaultReply(UntrustedOriginCompletionHandler& completionHandler)
{
    IPC::Connection::cancelReply<Messages::TestWithSwiftUntrusted::UntrustedOrigin>(*completionHandler);
}

void completeWithDefaultReply(UntrustedOptionalOriginCompletionHandler& completionHandler)
{
    IPC::Connection::cancelReply<Messages::TestWithSwiftUntrusted::UntrustedOptionalOrigin>(*completionHandler);
}

void completeWithDefaultReply(UntrustedOriginWithRepliesCompletionHandler& completionHandler)
{
    IPC::Connection::cancelReply<Messages::TestWithSwiftUntrusted::UntrustedOriginWithReplies>(*completionHandler);
}

void completeWithDefaultReply(UntrustedOriginWithUnnamedReplyCompletionHandler& completionHandler)
{
    IPC::Connection::cancelReply<Messages::TestWithSwiftUntrusted::UntrustedOriginWithUnnamedReply>(*completionHandler);
}

void complete(UntrustedOriginCompletionHandler& completionHandler, bool reply)
{
    (*completionHandler)(reply);
}

void complete(UntrustedOriginWithRepliesCompletionHandler& completionHandler, WebCore::FrameIdentifier&& frameID, WebCore::ExceptionData&& exception)
{
    (*completionHandler)(WTF::move(frameID), WTF::move(exception));
}

} // namespace TestWithSwiftUntrusted
} // namespace CompletionHandlers

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOrigin>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOrigin::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftUntrusted_UntrustedOrigin>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOrigin::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOptionalOrigin>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOptionalOrigin::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftUntrusted_UntrustedOptionalOrigin>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOptionalOrigin::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithoutReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithoutReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithReplies>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithReplies::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithReplies>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithReplies::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithUnnamedReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithUnnamedReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithUnnamedReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithUnnamedReply::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOriginReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOptionalOriginReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOptionalOriginReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithRepliesReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithRepliesReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftUntrusted_UntrustedOriginWithUnnamedReplyReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftUntrusted::UntrustedOriginWithUnnamedReplyReply::Arguments>(globalObject, decoder);
}

}

#endif

