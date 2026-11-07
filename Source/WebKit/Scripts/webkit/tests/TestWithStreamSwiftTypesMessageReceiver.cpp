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
#include "IPCSemaphore.h" // NOLINT
#include "TestWithStreamSwiftTypesMessages.h" // NOLINT
#include <WebCore/SharedMemory.h> // NOLINT
#include <optional> // NOLINT
#include <span> // NOLINT
#include <wtf/MachSendRight.h> // NOLINT
#include <wtf/Vector.h> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithStreamSwiftTypesMessageForwarder::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftTypes::SendString>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendValues::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftTypes::SendValues>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendValues);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendCxxString::name()) {
        IPC::handleMessage<Messages::TestWithStreamSwiftTypes::SendCxxString>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendCxxString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftTypes::SendStringAsync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendValuesAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftTypes::SendValuesAsync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendValuesAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendEmptyAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftTypes::SendEmptyAsync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendEmptyAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendCxxDecoded::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftTypes::SendCxxDecoded>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendCxxDecoded);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendLentBytes::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftTypes::SendLentBytes>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendLentBytes);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendSemaphore::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftTypes::SendSemaphore>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendSemaphore);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithStreamSwiftTypes::SendStringSync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendStringSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendEmptySync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithStreamSwiftTypes::SendEmptySync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendEmptySync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendLentBytesSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithStreamSwiftTypes::SendLentBytesSync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendLentBytesSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftTypes::SendSendRight::name()) {
        IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestWithStreamSwiftTypes::SendSendRight>(connection, decoder, m_handler.get(), &TestWithStreamSwiftTypesWeakRef::dispatchSendSendRight);
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithStreamSwiftTypesWeakRef> makeTestWithStreamSwiftTypesWeakRefUniquePtr(TestWithStreamSwiftTypesWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithStreamSwiftTypesWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithStreamSwiftTypesWeakRef>(newRef);
}

TestWithStreamSwiftTypesMessageForwarder::TestWithStreamSwiftTypesMessageForwarder(TestWithStreamSwiftTypesWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithStreamSwiftTypesWeakRefUniquePtr(target))
{
}

TestWithStreamSwiftTypesMessageForwarder::~TestWithStreamSwiftTypesMessageForwarder()
{
}


} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendValues>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendValues::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendCxxString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendCxxString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendEmptySync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendEmptySync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendEmptySync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendEmptySync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendValuesAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendValuesAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendValuesAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendValuesAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendEmptyAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendEmptyAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendEmptyAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendEmptyAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendCxxDecoded>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendCxxDecoded::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendCxxDecoded>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendCxxDecoded::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendLentBytes>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendLentBytes::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendLentBytesSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendLentBytesSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendLentBytesSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendLentBytesSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendSemaphore>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendSemaphore::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendSendRight>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendSendRight::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftTypes_SendSendRight>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendSendRight::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendStringAsyncReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendValuesAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendValuesAsyncReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendEmptyAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendEmptyAsyncReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftTypes_SendCxxDecodedReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftTypes::SendCxxDecodedReply::Arguments>(globalObject, decoder);
}

}

#endif

