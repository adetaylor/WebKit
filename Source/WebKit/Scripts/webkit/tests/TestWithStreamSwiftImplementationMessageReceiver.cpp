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
#include "TestWithStreamSwiftImplementation.h"

#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "TestWithStreamSwiftImplementationMessages.h" // NOLINT
#include <WebCore/SharedMemory.h> // NOLINT
#include <optional> // NOLINT
#include <span> // NOLINT
#include <wtf/MachSendRight.h> // NOLINT
#include <wtf/Seconds.h> // NOLINT
#include <wtf/Vector.h> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithStreamSwiftImplementation::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftImplementation::SendString>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendValues::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftImplementation::SendValues>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendValues);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendEmpty::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftImplementation::SendEmpty>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendEmpty);
        return;
    }
#if PLATFORM(COCOA)
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendCocoaValue::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftImplementation::SendCocoaValue>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendCocoaValue);
        return;
    }
#endif
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftImplementation::SendStringAsync>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendCxxDecoded::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithStreamSwiftImplementation::SendCxxDecoded>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendCxxDecoded);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendLentBytes::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftImplementation::SendLentBytes>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendLentBytes);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendWithConnection::name()) {
        IPC::handleSwiftMessage<Messages::TestWithStreamSwiftImplementation::SendWithConnection>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendWithConnection);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendCxxString::name()) {
        IPC::handleMessage<Messages::TestWithStreamSwiftImplementation::SendCxxString>(connection, decoder, this, &TestWithStreamSwiftImplementation::sendCxxString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendCxxStringAsync::name()) {
        IPC::handleMessageAsync<Messages::TestWithStreamSwiftImplementation::SendCxxStringAsync>(connection, decoder, this, &TestWithStreamSwiftImplementation::sendCxxStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendSendRight::name()) {
        IPC::handleMessage<Messages::TestWithStreamSwiftImplementation::SendSendRight>(connection, decoder, this, &TestWithStreamSwiftImplementation::sendSendRight);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithStreamSwiftImplementation::SendStringSync>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendStringSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendEmptySync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithStreamSwiftImplementation::SendEmptySync>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendEmptySync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendLaterSync::name()) {
        IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestWithStreamSwiftImplementation::SendLaterSync>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendLaterSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendCxxEncodedSync::name()) {
        IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestWithStreamSwiftImplementation::SendCxxEncodedSync>(connection, decoder, this, &SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendCxxEncodedSync);
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendValues>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendValues::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendEmpty>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendEmpty::Arguments>(globalObject, decoder);
}
#if PLATFORM(COCOA)
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCocoaValue>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCocoaValue::Arguments>(globalObject, decoder);
}
#endif
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendEmptySync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendEmptySync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendEmptySync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendEmptySync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendLaterSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendLaterSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendLaterSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendLaterSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxEncodedSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxEncodedSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendCxxEncodedSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxEncodedSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxDecoded>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxDecoded::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendCxxDecoded>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxDecoded::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendLentBytes>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendLentBytes::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendWithConnection>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendWithConnection::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendSendRight>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendSendRight::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendStringAsyncReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxDecodedReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxDecodedReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

