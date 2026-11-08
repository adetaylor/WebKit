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
#include <optional> // NOLINT
#include <wtf/MachSendRight.h> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithStreamSwiftImplementation::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendString::name()) {
        IPC::handleSwiftImplementedMessage<Messages::TestWithStreamSwiftImplementation::SendString>(connection, decoder, *this, SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendValues::name()) {
        IPC::handleSwiftImplementedMessage<Messages::TestWithStreamSwiftImplementation::SendValues>(connection, decoder, *this, SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendValues);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendEmpty::name()) {
        IPC::handleSwiftImplementedMessage<Messages::TestWithStreamSwiftImplementation::SendEmpty>(connection, decoder, *this, SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendEmpty);
        return;
    }
#if PLATFORM(COCOA)
    if (decoder.messageName() == Messages::TestWithStreamSwiftImplementation::SendCocoaValue::name()) {
        IPC::handleSwiftImplementedMessage<Messages::TestWithStreamSwiftImplementation::SendCocoaValue>(connection, decoder, *this, SwiftDispatch::TestWithStreamSwiftImplementation::dispatchSendCocoaValue);
        return;
    }
#endif
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
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftImplementation_SendCxxStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftImplementation::SendCxxStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

