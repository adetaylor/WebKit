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
#include "TestWithStreamSwiftState.h"

#include "Shared/WebKit-Swift.h" // NOLINT
#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "TestWithStreamSwiftStateMessages.h" // NOLINT
#include <optional> // NOLINT
#include <wtf/Seconds.h> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

// The Swift dispatch of the messages that go to the receiver's Swift state, which keeps the state. It is made for the
// first of them, on the queue they are dispatched on, and kept until the receiver goes.
static TestWithStreamSwiftStateStateDispatch& testWithStreamSwiftStateStateDispatch(IPC::SwiftStateDispatch& dispatch, TestWithStreamSwiftState& receiver)
{
    if (!dispatch) [[unlikely]]
        dispatch.set(TestWithStreamSwiftStateStateDispatch::create(&receiver));
    return dispatch.get<TestWithStreamSwiftStateStateDispatch>();
}

void TestWithStreamSwiftState::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendValues::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftState::SendValues>(connection, decoder, &testWithStreamSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithStreamSwiftStateStateDispatch::dispatchSendValues);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendWithConnection::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftState::SendWithConnection>(connection, decoder, &testWithStreamSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithStreamSwiftStateStateDispatch::dispatchSendWithConnection);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftState::SendStringAsync>(connection, decoder, &testWithStreamSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithStreamSwiftStateStateDispatch::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendToReceiver::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftState::SendToReceiver>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftState::dispatchSendToReceiver);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendCxxString::name()) {
        IPC::handleMessage<Messages::TestWithStreamSwiftState::SendCxxString>(connection, decoder, this, &TestWithStreamSwiftState::sendCxxString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithStreamSwiftState::SendStringSync>(connection, decoder, &testWithStreamSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithStreamSwiftStateStateDispatch::dispatchSendStringSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftState::SendLaterSync::name()) {
        IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestWithStreamSwiftState::SendLaterSync>(connection, decoder, &testWithStreamSwiftStateStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestWithStreamSwiftStateStateDispatch::dispatchSendLaterSync);
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendValues>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendValues::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendWithConnection>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendWithConnection::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftState_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendLaterSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendLaterSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftState_SendLaterSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendLaterSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftState_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendToReceiver>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendToReceiver::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendCxxString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendCxxString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftState_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftState::SendStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

