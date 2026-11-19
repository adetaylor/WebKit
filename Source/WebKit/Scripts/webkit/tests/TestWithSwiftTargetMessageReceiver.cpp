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
#include "TestWithSwiftTargetMessages.h" // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithSwiftTargetMessageForwarder::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    ASSERT(m_workQueue && m_workQueue->isCurrent());
    if (decoder.messageName() == Messages::TestWithSwiftTarget::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithSwiftTarget::SendString>(connection, decoder, m_handler.get(), &TestWithSwiftTargetWeakRef::dispatchSendString);
        return;
    }
    UNUSED_PARAM(connection);
    RELEASE_LOG_ERROR(IPC, "Unhandled message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

void TestWithSwiftTargetMessageForwarder::didReceiveSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
    ASSERT(m_workQueue && m_workQueue->isCurrent());
    if (decoder.messageName() == Messages::TestWithSwiftTarget::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithSwiftTarget::SendStringSync>(connection, decoder, replyEncoder, m_handler.get(), &TestWithSwiftTargetWeakRef::dispatchSendStringSync);
        return;
    }
    UNUSED_PARAM(connection);
    UNUSED_PARAM(replyEncoder);
    RELEASE_LOG_ERROR(IPC, "Unhandled synchronous message %s to %" PRIu64, description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithSwiftTargetWeakRef> makeTestWithSwiftTargetWeakRefUniquePtr(TestWithSwiftTargetWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithSwiftTargetWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithSwiftTargetWeakRef>(newRef);
}

TestWithSwiftTargetMessageForwarder::TestWithSwiftTargetMessageForwarder(TestWithSwiftTargetWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithSwiftTargetWeakRefUniquePtr(target))
{
}

void TestWithSwiftTargetMessageForwarder::startReceivingMessages(IPC::Connection& connection, WorkQueue& workQueue, uint64_t destinationID)
{
    if (!m_workQueue)
        m_workQueue = &workQueue;
    RELEASE_ASSERT(m_workQueue.get() == &workQueue);
    connection.addWorkQueueMessageReceiver(Messages::TestWithSwiftTarget::messageReceiverName(), workQueue, *this, destinationID);
}

TestWithSwiftTargetMessageForwarder::~TestWithSwiftTargetMessageForwarder()
{
}


} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftTarget_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftTarget::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftTarget_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftTarget::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftTarget_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftTarget::SendStringSync::ReplyArguments>(globalObject, decoder);
}

}

#endif

