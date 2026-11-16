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
#include "TestWithWorkQueueSwiftState.h"

#include "Shared/WebKit-Swift.h" // NOLINT
#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "SharedPreferencesForWebProcess.h" // NOLINT
#include "TestWithWorkQueueSwiftStateMessages.h" // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

// The Swift dispatch of the messages that go to the receiver's Swift state, which keeps the state. It is made for the
// first of them, on the queue they are dispatched on, and kept until the receiver goes.
static TestWithWorkQueueSwiftStateStateDispatch& testWithWorkQueueSwiftStateStateDispatch(IPC::SwiftStateDispatch& dispatch, TestWithWorkQueueSwiftState& receiver)
{
    if (!dispatch) [[unlikely]]
        dispatch.set(TestWithWorkQueueSwiftStateStateDispatch::create(&receiver));
    return dispatch.get<TestWithWorkQueueSwiftStateStateDispatch>();
}

void TestWithWorkQueueSwiftState::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    auto sharedPreferences = sharedPreferencesForWebProcess();
    UNUSED_VARIABLE(sharedPreferences);
    if (!sharedPreferences || !sharedPreferences->someFeature) {
        RELEASE_LOG_ERROR(IPC, "Message %s received by a disabled message receiver TestWithWorkQueueSwiftState", IPC::description(decoder.messageName()).characters());
        decoder.markInvalid();
        return;
    }
    if (decoder.messageName() == Messages::TestWithWorkQueueSwiftState::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithWorkQueueSwiftState::SendString>(connection, decoder, &testWithWorkQueueSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithWorkQueueSwiftStateStateDispatch::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithWorkQueueSwiftState::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithWorkQueueSwiftState::SendStringAsync>(connection, decoder, &testWithWorkQueueSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithWorkQueueSwiftStateStateDispatch::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithWorkQueueSwiftState::SendToReceiver::name()) {
        IPC::handleSwiftMessage<Messages::TestWithWorkQueueSwiftState::SendToReceiver>(connection, decoder, this, &SwiftDispatch::TestWithWorkQueueSwiftState::dispatchSendToReceiver);
        return;
    }
    if (decoder.messageName() == Messages::TestWithWorkQueueSwiftState::SendCxxString::name()) {
        IPC::handleMessage<Messages::TestWithWorkQueueSwiftState::SendCxxString>(connection, decoder, this, &TestWithWorkQueueSwiftState::sendCxxString);
        return;
    }
    UNUSED_PARAM(connection);
    RELEASE_LOG_ERROR(IPC, "Unhandled message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

void TestWithWorkQueueSwiftState::didReceiveSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
    auto sharedPreferences = sharedPreferencesForWebProcess();
    UNUSED_VARIABLE(sharedPreferences);
    if (!sharedPreferences || !sharedPreferences->someFeature) {
        RELEASE_LOG_ERROR(IPC, "Message %s received by a disabled message receiver TestWithWorkQueueSwiftState", IPC::description(decoder.messageName()).characters());
        decoder.markInvalid();
        return;
    }
    if (decoder.messageName() == Messages::TestWithWorkQueueSwiftState::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithWorkQueueSwiftState::SendStringSync>(connection, decoder, replyEncoder, &testWithWorkQueueSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithWorkQueueSwiftStateStateDispatch::dispatchSendStringSync);
        return;
    }
    UNUSED_PARAM(connection);
    UNUSED_PARAM(replyEncoder);
    RELEASE_LOG_ERROR(IPC, "Unhandled synchronous message %s to %" PRIu64, description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithWorkQueueSwiftState_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithWorkQueueSwiftState_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithWorkQueueSwiftState_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithWorkQueueSwiftState_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithWorkQueueSwiftState_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithWorkQueueSwiftState_SendToReceiver>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendToReceiver::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithWorkQueueSwiftState_SendCxxString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendCxxString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithWorkQueueSwiftState_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithWorkQueueSwiftState::SendStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

