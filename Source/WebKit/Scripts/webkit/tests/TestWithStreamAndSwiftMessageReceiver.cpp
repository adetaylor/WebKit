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
#if ENABLE(SWIFT_TEST_CONDITION)
#include "Shared/WebKit-Swift.h" // NOLINT
#else // ENABLE(SWIFT_TEST_CONDITION)
#include "TestWithStreamAndSwift.h"

#endif // ENABLE(SWIFT_TEST_CONDITION)
#include "ArgumentCoders.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "TestWithStreamAndSwiftMessages.h" // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

#if ENABLE(SWIFT_TEST_CONDITION)
void TestWithStreamAndSwiftMessageForwarder::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
#else // ENABLE(SWIFT_TEST_CONDITION)
void TestWithStreamAndSwift::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
#endif // ENABLE(SWIFT_TEST_CONDITION)
{
    Ref protectedThis { *this };
#if ENABLE(SWIFT_TEST_CONDITION)
    auto target = getMessageTarget();
    if (!target) {
        FATAL("Something is keeping a reference to the message forwarder");
        decoder.markInvalid();
        return;
    }
#endif // ENABLE(SWIFT_TEST_CONDITION)
    if (decoder.messageName() == Messages::TestWithStreamAndSwift::SendString::name()) {
#if ENABLE(SWIFT_TEST_CONDITION)
        IPC::handleMessage<Messages::TestWithStreamAndSwift::SendString>(connection, decoder, target.get(), &TestWithStreamAndSwift::sendString);
#else // ENABLE(SWIFT_TEST_CONDITION)
        IPC::handleMessage<Messages::TestWithStreamAndSwift::SendString>(connection, decoder, this, &TestWithStreamAndSwift::sendString);
#endif // ENABLE(SWIFT_TEST_CONDITION)
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamAndSwift::SendStringAsync::name()) {
#if ENABLE(SWIFT_TEST_CONDITION)
        IPC::handleMessageAsync<Messages::TestWithStreamAndSwift::SendStringAsync>(connection, decoder, target.get(), &TestWithStreamAndSwift::sendStringAsync);
#else // ENABLE(SWIFT_TEST_CONDITION)
        IPC::handleMessageAsync<Messages::TestWithStreamAndSwift::SendStringAsync>(connection, decoder, this, &TestWithStreamAndSwift::sendStringAsync);
#endif // ENABLE(SWIFT_TEST_CONDITION)
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}
#if ENABLE(SWIFT_TEST_CONDITION)

static std::unique_ptr<TestWithStreamAndSwiftWeakRef> makeTestWithStreamAndSwiftWeakRefUniquePtr(TestWithStreamAndSwiftWeakRef* _Nonnull handler)
{
    auto newRef = _impl::_impl_TestWithStreamAndSwiftWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithStreamAndSwiftWeakRef>(newRef);
}

TestWithStreamAndSwiftMessageForwarder::TestWithStreamAndSwiftMessageForwarder(TestWithStreamAndSwiftWeakRef* _Nonnull target)
    : m_handler(makeTestWithStreamAndSwiftWeakRefUniquePtr(target))
{
}

std::unique_ptr<TestWithStreamAndSwift> TestWithStreamAndSwiftMessageForwarder::getMessageTarget()
{
    auto target = m_handler->getMessageTarget();
    if (target)
        return WTF::makeUniqueWithoutFastMallocCheck<TestWithStreamAndSwift>(target.get());
    return nullptr;
}

TestWithStreamAndSwiftMessageForwarder::~TestWithStreamAndSwiftMessageForwarder()
{
}

#endif // ENABLE(SWIFT_TEST_CONDITION)

} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamAndSwift_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamAndSwift::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamAndSwift_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamAndSwift::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithStreamAndSwift_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamAndSwift::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamAndSwift_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamAndSwift::SendStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

