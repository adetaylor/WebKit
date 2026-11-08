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
#include "TestWithSwiftImplementation.h"

#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "TestWithSwiftImplementationMessages.h" // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithSwiftImplementation::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithSwiftImplementation::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithSwiftImplementation::SendString>(connection, decoder, this, &SwiftDispatch::TestWithSwiftImplementation::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftImplementation::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithSwiftImplementation::SendStringAsync>(connection, decoder, this, &SwiftDispatch::TestWithSwiftImplementation::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftImplementation::SendDirect::name()) {
        IPC::handleSwiftMessage<Messages::TestWithSwiftImplementation::SendDirect>(connection, decoder, this, &SwiftDispatch::TestWithSwiftImplementation::dispatchSendDirect);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftImplementation::SendCxxString::name()) {
        IPC::handleMessage<Messages::TestWithSwiftImplementation::SendCxxString>(connection, decoder, this, &TestWithSwiftImplementation::sendCxxString);
        return;
    }
    UNUSED_PARAM(connection);
    RELEASE_LOG_ERROR(IPC, "Unhandled message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

void TestWithSwiftImplementation::didReceiveSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
    if (decoder.messageName() == Messages::TestWithSwiftImplementation::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithSwiftImplementation::SendStringSync>(connection, decoder, replyEncoder, this, &SwiftDispatch::TestWithSwiftImplementation::dispatchSendStringSync);
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

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementation_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementation_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftImplementation_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementation_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftImplementation_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementation_SendDirect>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendDirect::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementation_SendCxxString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendCxxString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementation_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementation::SendStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

