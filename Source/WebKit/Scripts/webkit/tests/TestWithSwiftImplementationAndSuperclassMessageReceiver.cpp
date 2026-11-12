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
#include "TestWithSwiftImplementationAndSuperclass.h"

#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "TestWithSwiftImplementationAndSuperclassMessages.h" // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithSwiftImplementationAndSuperclass::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithSwiftImplementationAndSuperclass::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithSwiftImplementationAndSuperclass::SendString>(connection, decoder, this, &SwiftDispatch::TestWithSwiftImplementationAndSuperclass::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftImplementationAndSuperclass::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithSwiftImplementationAndSuperclass::SendStringAsync>(connection, decoder, this, &SwiftDispatch::TestWithSwiftImplementationAndSuperclass::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftImplementationAndSuperclass::LoadURL::name()) {
        IPC::handleMessage<Messages::TestWithSwiftImplementationAndSuperclass::LoadURL>(connection, decoder, this, &TestWithSwiftImplementationAndSuperclass::loadURL);
        return;
    }
    WebPageBase::didReceiveMessage(connection, decoder);
}

void TestWithSwiftImplementationAndSuperclass::didReceiveSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
    if (decoder.messageName() == Messages::TestWithSwiftImplementationAndSuperclass::TestSyncMessage::name()) {
        IPC::handleMessageSynchronous<Messages::TestWithSwiftImplementationAndSuperclass::TestSyncMessage>(connection, decoder, replyEncoder, this, &TestWithSwiftImplementationAndSuperclass::testSyncMessage);
        return;
    }
    WebPageBase::didReceiveSyncMessage(connection, decoder, replyEncoder);
}

} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementationAndSuperclass_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementationAndSuperclass_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftImplementationAndSuperclass_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementationAndSuperclass_LoadURL>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::LoadURL::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementationAndSuperclass_TestSyncMessage>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::TestSyncMessage::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftImplementationAndSuperclass_TestSyncMessage>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::TestSyncMessage::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftImplementationAndSuperclass_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftImplementationAndSuperclass::SendStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

