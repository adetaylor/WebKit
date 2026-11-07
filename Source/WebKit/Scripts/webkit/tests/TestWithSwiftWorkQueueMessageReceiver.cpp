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
#include "SharedPreferencesForWebProcess.h" // NOLINT
#include "TestWithSwiftWorkQueueMessages.h" // NOLINT
#include <WebCore/SharedMemory.h> // NOLINT
#include <optional> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithSwiftWorkQueueMessageForwarder::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    ASSERT(m_workQueue && m_workQueue->isCurrent());
    auto sharedPreferences = m_sharedPreferencesProvider ? m_sharedPreferencesProvider() : m_handler->sharedPreferencesForWebProcess();
    UNUSED_VARIABLE(sharedPreferences);
    if (!sharedPreferences || !sharedPreferences->someFeature) {
        RELEASE_LOG_ERROR(IPC, "Message %s received by a disabled message receiver TestWithSwiftWorkQueue", IPC::description(decoder.messageName()).characters());
        decoder.markInvalid();
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendString::name()) {
        IPC::handleSwiftMessage<Messages::TestWithSwiftWorkQueue::SendString>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendStringAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithSwiftWorkQueue::SendStringAsync>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendStringAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendEmptyAsync::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithSwiftWorkQueue::SendEmptyAsync>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendEmptyAsync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendCxxDecoded::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithSwiftWorkQueue::SendCxxDecoded>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendCxxDecoded);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendSharedMemory::name()) {
        IPC::handleSwiftMessageAsync<Messages::TestWithSwiftWorkQueue::SendSharedMemory>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendSharedMemory);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendCxxString::name()) {
        IPC::handleMessage<Messages::TestWithSwiftWorkQueue::SendCxxString>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendCxxString);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendCxxStringAsync::name()) {
        IPC::handleMessageAsync<Messages::TestWithSwiftWorkQueue::SendCxxStringAsync>(connection, decoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendCxxStringAsync);
        return;
    }
    UNUSED_PARAM(connection);
    RELEASE_LOG_ERROR(IPC, "Unhandled message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

void TestWithSwiftWorkQueueMessageForwarder::didReceiveSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
    ASSERT(m_workQueue && m_workQueue->isCurrent());
    auto sharedPreferences = m_sharedPreferencesProvider ? m_sharedPreferencesProvider() : m_handler->sharedPreferencesForWebProcess();
    UNUSED_VARIABLE(sharedPreferences);
    if (!sharedPreferences || !sharedPreferences->someFeature) {
        RELEASE_LOG_ERROR(IPC, "Message %s received by a disabled message receiver TestWithSwiftWorkQueue", IPC::description(decoder.messageName()).characters());
        decoder.markInvalid();
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendStringSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithSwiftWorkQueue::SendStringSync>(connection, decoder, replyEncoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendStringSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendSemaphoreSync::name()) {
        IPC::handleSwiftMessageSynchronous<Messages::TestWithSwiftWorkQueue::SendSemaphoreSync>(connection, decoder, replyEncoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendSemaphoreSync);
        return;
    }
    if (decoder.messageName() == Messages::TestWithSwiftWorkQueue::SendCxxStringSync::name()) {
        IPC::handleMessageSynchronous<Messages::TestWithSwiftWorkQueue::SendCxxStringSync>(connection, decoder, replyEncoder, m_handler.get(), &TestWithSwiftWorkQueueWeakRef::dispatchSendCxxStringSync);
        return;
    }
    UNUSED_PARAM(connection);
    UNUSED_PARAM(replyEncoder);
    RELEASE_LOG_ERROR(IPC, "Unhandled synchronous message %s to %" PRIu64, description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithSwiftWorkQueueWeakRef> makeTestWithSwiftWorkQueueWeakRefUniquePtr(TestWithSwiftWorkQueueWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithSwiftWorkQueueWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithSwiftWorkQueueWeakRef>(newRef);
}

TestWithSwiftWorkQueueMessageForwarder::TestWithSwiftWorkQueueMessageForwarder(TestWithSwiftWorkQueueWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithSwiftWorkQueueWeakRefUniquePtr(target))
{
}

void TestWithSwiftWorkQueueMessageForwarder::startReceivingMessages(IPC::Connection& connection, WorkQueue& workQueue, uint64_t destinationID)
{
    if (!m_workQueue)
        m_workQueue = &workQueue;
    RELEASE_ASSERT(m_workQueue.get() == &workQueue);
    connection.addWorkQueueMessageReceiver(Messages::TestWithSwiftWorkQueue::messageReceiverName(), workQueue, *this, destinationID);
}

TestWithSwiftWorkQueueMessageForwarder::~TestWithSwiftWorkQueueMessageForwarder()
{
}


} // namespace WebKit

namespace CompletionHandlers {
namespace TestWithSwiftWorkQueue {

void completeWithDefaultReply(SendCxxStringSyncCompletionHandler& completionHandler)
{
    IPC::Connection::cancelReply<Messages::TestWithSwiftWorkQueue::SendCxxStringSync>(*completionHandler);
}

void complete(SendCxxStringSyncCompletionHandler& completionHandler, uint64_t reply)
{
    (*completionHandler)(reply);
}

} // namespace TestWithSwiftWorkQueue
} // namespace CompletionHandlers

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendEmptyAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendEmptyAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendEmptyAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendEmptyAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendCxxDecoded>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxDecoded::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendCxxDecoded>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxDecoded::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendSharedMemory>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendSharedMemory::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendSharedMemory>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendSharedMemory::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendSemaphoreSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendSemaphoreSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendSemaphoreSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendSemaphoreSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendCxxString>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxString::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendCxxStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxStringSync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendCxxStringSync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxStringSync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendCxxStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxStringAsync::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessageReply<MessageName::TestWithSwiftWorkQueue_SendCxxStringAsync>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxStringAsync::ReplyArguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendStringAsyncReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendEmptyAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendEmptyAsyncReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendCxxDecodedReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxDecodedReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendSharedMemoryReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendSharedMemoryReply::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithSwiftWorkQueue_SendCxxStringAsyncReply>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithSwiftWorkQueue::SendCxxStringAsyncReply::Arguments>(globalObject, decoder);
}

}

#endif

