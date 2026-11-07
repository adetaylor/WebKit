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
#include "TestWithStreamSwiftReplyValuesMessages.h" // NOLINT
#include <wtf/MachSendRight.h> // NOLINT
#include <wtf/Seconds.h> // NOLINT
#include <wtf/Vector.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithStreamSwiftReplyValuesMessageForwarder::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftReplyValues::SendLaterSync::name()) {
        IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestWithStreamSwiftReplyValues::SendLaterSync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftReplyValuesWeakRef::dispatchSendLaterSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftReplyValues::SendCxxEncodedSync::name()) {
        IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestWithStreamSwiftReplyValues::SendCxxEncodedSync>(connection, decoder, m_handler.get(), &TestWithStreamSwiftReplyValuesWeakRef::dispatchSendCxxEncodedSync);
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithStreamSwiftReplyValuesWeakRef> makeTestWithStreamSwiftReplyValuesWeakRefUniquePtr(TestWithStreamSwiftReplyValuesWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithStreamSwiftReplyValuesWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithStreamSwiftReplyValuesWeakRef>(newRef);
}

TestWithStreamSwiftReplyValuesMessageForwarder::TestWithStreamSwiftReplyValuesMessageForwarder(TestWithStreamSwiftReplyValuesWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithStreamSwiftReplyValuesWeakRefUniquePtr(target))
{
}

TestWithStreamSwiftReplyValuesMessageForwarder::~TestWithStreamSwiftReplyValuesMessageForwarder()
{
}


} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftReplyValues_SendLaterSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftReplyValues::SendLaterSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftReplyValues_SendLaterSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftReplyValues::SendLaterSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftReplyValues_SendCxxEncodedSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftReplyValues::SendCxxEncodedSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamSwiftReplyValues_SendCxxEncodedSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftReplyValues::SendCxxEncodedSync::ReplyArguments>(globalObject, decoder);
}

}

#endif

