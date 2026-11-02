/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "IPCTester.h"

#if ENABLE(IPC_TESTING_API)
#include "Connection.h"
#include "Decoder.h"
#include "IPCConnectionTester.h"
#include "IPCStreamTester.h"
#include "IPCStreamTesterMessages.h"
#include "IPCTesterMessages.h"
#include "IPCTesterPayload.h"
#include "IPCTesterReceiver.h"
#include "IPCTesterReceiverMessages.h"
#if ENABLE(IPC_TESTING_SWIFT)
#include "IPCSwiftStreamTesterMessages.h"
#endif
#include "IPCUtilities.h"
#include "Logging.h"
#include "StreamClientConnection.h"
#include "TestParameter.h"
#include "WebKit-Swift.h"
#include <WebCore/ExceptionData.h>
#include <array>
#include <atomic>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <wtf/Borrow.h>
#include <wtf/Box.h>
#include <wtf/CallbackAggregator.h>
#include <wtf/CryptographicallyRandomNumber.h>
#include <wtf/threads/BinarySemaphore.h>

// The tester API.
extern "C" {
// Returns 0 if driver should continue.
typedef int (*WKMessageTestSendMessageFunc)(std::span<const uint8_t> buffer, void* context);
typedef void (*WKMessageTestDriverFunc)(WKMessageTestSendMessageFunc sendMessageFunc, void* context);
}

namespace {
struct SendMessageContext {
    Ref<IPC::Connection> connection;
    std::atomic<bool>& shouldStop;
};

}

extern "C" {

static void defaultTestDriver(WKMessageTestSendMessageFunc sendMessageFunc, void* context)
{
    Vector<uint8_t> data(1000);
    Borrow borrowedData = data;
    for (unsigned i = 0; i < 1000; ++i) {
        cryptographicallyRandomValues(borrowedData->mutableSpan());
        if (sendMessageFunc(borrowedData->span(), context))
            return;
    }
}

static int sendTestMessage(std::span<const uint8_t> buffer, void* context)
{
    auto messageContext = reinterpret_cast<SendMessageContext*>(context);
    if (messageContext->shouldStop)
        return 1;
    Ref testedConnection = messageContext->connection;
    if (!testedConnection->isValid())
        return 1;
    BinarySemaphore semaphore;
    auto decoder = IPC::Decoder::create(buffer, [&semaphore] (std::span<const uint8_t>) { semaphore.signal(); }, { }); // NOLINT
    if (decoder) {
        testedConnection->dispatchIncomingMessageForTesting(makeUniqueRefFromNonNullUniquePtr(WTF::move(decoder)));
        semaphore.wait();
    }
    return 0;
}

}

namespace WebKit {

static WKMessageTestDriverFunc messageTestDriver(String&& driverName)
{
    if (driverName.isEmpty() || driverName == "default"_s)
        driverName = String::fromUTF8(getenv("WEBKIT_MESSAGE_TEST_DEFAULT_DRIVER"));
    if (driverName.isEmpty() || driverName == "default"_s)
        return defaultTestDriver;
    auto testDriver = reinterpret_cast<WKMessageTestDriverFunc>(dlsym(RTLD_DEFAULT, driverName.utf8().legacyCStringPointer()));
    RELEASE_ASSERT(testDriver);
    return testDriver;
}

static void runMessageTesting(IPC::Connection& connection, std::atomic<bool>& shouldStop, String&& driverName)
{
    connection.setIgnoreInvalidMessageForTesting();
    SendMessageContext context { connection, shouldStop };
    auto driver = messageTestDriver(WTF::move(driverName));
    driver(sendTestMessage, &context);
}

Ref<IPCTester> IPCTester::create()
{
    return adoptRef(*new IPCTester);
}

IPCTester::IPCTester() = default;

IPCTester::~IPCTester()
{
    stopIfNeeded();
}

void IPCTester::startMessageTesting(IPC::Connection& connection, String&& driverName)
{
    if (!m_testQueue)
        m_testQueue = WorkQueue::create("IPC testing work queue"_s);
    m_testQueue->dispatch([connection = Ref { connection }, &shouldStop = m_shouldStop, driverName = WTF::move(driverName)]() mutable {
        IPC::startTestingIPC();
        runMessageTesting(connection, shouldStop, WTF::move(driverName));
        IPC::stopTestingIPC();
    });
}

void IPCTester::stopMessageTesting(CompletionHandler<void()>&& completionHandler)
{
    stopIfNeeded();
    completionHandler();
}

void IPCTester::createStreamTester(IPC::Connection& connection, IPCStreamTesterIdentifier identifier, IPC::StreamServerConnection::Handle&& serverConnection)
{
    auto addResult = m_streamTesters.ensure(identifier, [&] {
        return IPC::ScopedActiveMessageReceiveQueue<IPCStreamTester> { IPCStreamTester::create(identifier, WTF::move(serverConnection), connection.ignoreInvalidMessageForTesting()) };
    });
    ASSERT_UNUSED(addResult, addResult.isNewEntry || IPC::isTestingIPC());
}

void IPCTester::releaseStreamTester(IPCStreamTesterIdentifier identifier, CompletionHandler<void()>&& completionHandler)
{
    m_streamTesters.remove(identifier);
    completionHandler();
}

void IPCTester::sendSameSemaphoreBack(IPC::Connection& connection, IPC::Semaphore&& semaphore)
{
    connection.send(Messages::IPCTester::SendSameSemaphoreBack(semaphore), 0);
}

void IPCTester::sendSemaphoreBackAndSignalProtocol(IPC::Connection& connection, IPC::Semaphore&& semaphore)
{
    IPC::Semaphore newSemaphore;
    connection.send(Messages::IPCTester::SendSemaphoreBackAndSignalProtocol(newSemaphore), 0);
    if (!semaphore.waitFor(10_s)) {
        ASSERT_IS_TESTING_IPC();
        return;
    }
    newSemaphore.signal();
    // Wait for protocol commit. Otherwise newSemaphore will be destroyed, and the waiter on the other side
    // will fail to wait.
    if (!semaphore.waitFor(10_s)) {
        ASSERT_IS_TESTING_IPC();
        return;
    }
}

void IPCTester::sendSemaphores(Vector<IPC::Semaphore>&& semaphores, CompletionHandler<void(uint64_t)>&& completionHandler)
{
    completionHandler(semaphores.size());
}

void IPCTester::sendAsyncMessageToReceiver(IPC::Connection& connection, uint32_t arg0)
{
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::AsyncMessage(arg0 + 1), [arg0](uint32_t newArg0) {
        ASSERT_UNUSED(arg0, newArg0 == arg0 + 2);
    }, 0);
}

void IPCTester::sendAsyncMessageToReceiverRequestingReply(IPC::Connection& connection, uint32_t arg0, CompletionHandler<void(uint32_t, bool)>&& completionHandler)
{
#if ENABLE(IPC_TESTING_SWIFT)
    constexpr bool usingSwift = true;
#else
    constexpr bool usingSwift = false;
#endif
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::AsyncMessage(arg0 + 1), [completionHandler = WTF::move(completionHandler)](uint32_t newArg0) mutable {
        completionHandler(newArg0, usingSwift);
    }, 0);
}

void IPCTester::sendDeferredReplyMessageToReceiver(IPC::Connection& connection, uint32_t arg0, CompletionHandler<void(uint64_t, bool)>&& completionHandler)
{
#if ENABLE(IPC_TESTING_SWIFT)
    constexpr bool usingSwift = true;
#else
    constexpr bool usingSwift = false;
#endif
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::DeferredReplyMessage(arg0 + 1), [completionHandler = WTF::move(completionHandler)](uint64_t newArg0) mutable {
        completionHandler(newArg0, usingSwift);
    }, 0);
}

void IPCTester::completeDeferredReplyOnReceiver(IPC::Connection& connection, uint32_t arg0)
{
    connection.send(Messages::IPCTesterReceiver::CompleteDeferredReply(arg0), 0);
}

void IPCTester::createConnectionTester(IPC::Connection& connection, IPCConnectionTesterIdentifier identifier, IPC::Connection::Handle&& testedConnectionIdentifier)
{
    auto addResult = m_connectionTesters.ensure(identifier, [&] {
        return IPC::ScopedActiveMessageReceiveQueue<IPCConnectionTester> { IPCConnectionTester::create(connection, identifier, WTF::move(testedConnectionIdentifier)) };
    });
    ASSERT_UNUSED(addResult, addResult.isNewEntry || IPC::isTestingIPC());
}

void IPCTester::createConnectionTesterAndSendAsyncMessages(IPC::Connection& connection, IPCConnectionTesterIdentifier identifier, IPC::Connection::Handle&& testedConnectionIdentifier, uint32_t messageCount)
{
    auto addResult = m_connectionTesters.ensure(identifier, [&] {
        return IPC::ScopedActiveMessageReceiveQueue<IPCConnectionTester> { IPCConnectionTester::create(connection, identifier, WTF::move(testedConnectionIdentifier)) };
    });
    if (!addResult.isNewEntry) {
        ASSERT_IS_TESTING_IPC();
        return;
    }
    addResult.iterator->value->sendAsyncMessages(messageCount);
}

void IPCTester::releaseConnectionTester(IPCConnectionTesterIdentifier identifier, CompletionHandler<void()>&& completionHandler)
{
    m_connectionTesters.remove(identifier);
    completionHandler();
}

void IPCTester::asyncPing(uint32_t value, CompletionHandler<void(uint32_t)>&& completionHandler)
{
    completionHandler(value + 1);
}

void IPCTester::syncPing(IPC::Connection&, uint32_t value, CompletionHandler<void(uint32_t)>&& completionHandler)
{
    completionHandler(value + 1);
}

void IPCTester::syncPingEmptyReply(IPC::Connection&, uint32_t value, CompletionHandler<void()>&& completionHandler)
{
    UNUSED_PARAM(value);
    completionHandler();
}

void IPCTester::asyncOptionalExceptionData(IPC::Connection&, bool sendEngaged, CompletionHandler<void(std::optional<WebCore::ExceptionData>, String)>&& completionHandler)
{
    if (sendEngaged) {
        completionHandler(WebCore::ExceptionData { WebCore::ExceptionCode::WrongDocumentError, "m"_s }, "a"_s);
        return;
    }
    completionHandler(std::nullopt, "b"_s);
}

void IPCTester::stopIfNeeded()
{
    if (RefPtr testQueue = m_testQueue) {
        m_shouldStop = true;
        testQueue->dispatchSync([] { });
        m_testQueue = nullptr;
    }
}

void IPCTester::emptyMessageWithReply(CompletionHandler<void(uint64_t)>&& completionHandler)
{
    completionHandler(0x1);
}

void IPCTester::checkTestParameter(IPC::Connection& connection, TestParameter param)
{
    MESSAGE_CHECK_WITH_MESSAGE_BASE(param.value < 100, connection, "Test parameter must be less than 100");
}

static bool nodesAreEqual(const IPCTesterNode& a, const IPCTesterNode& b)
{
    if (a.name() != b.name() || a.children().size() != b.children().size())
        return false;
    for (size_t i = 0; i < a.children().size(); ++i) {
        if (!nodesAreEqual(a.children()[i], b.children()[i]))
            return false;
    }
    return true;
}

// Sends IPCTesterReceiver in the WebContent process messages that it takes as C++ types and as Swift
// types, and replies with the names of the messages whose replies differ from what IPCTesterPayload.h
// says they should be.
void IPCTester::sendSwiftTypesMessagesToReceiver(IPC::Connection& connection, CompletionHandler<void(String&&)>&& completionHandler)
{
    auto failures = Box<Vector<String>>::create();
    Ref aggregator = CallbackAggregator::create([failures, completionHandler = WTF::move(completionHandler)] mutable {
        completionHandler(makeStringByJoining(failures->span(), ", "_s));
    });
    auto check = [failures](bool passed, ASCIILiteral description) {
        if (!passed)
            failures->append(description);
    };

    auto latin1 = String::fromLatin1("caf\xe9");
    auto utf16 = String::fromUTF8("caf\xc3\xa9 \xe2\x98\xba \xf0\x9f\x98\x80");

    IPCTesterInner inner { -5, "inner"_s };
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TransformInner(inner), [aggregator, check, inner](IPCTesterInner&& reply) {
        check(reply == IPCTesterInner { 5, inner.label }, "TransformInner"_s);
    }, 0);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TransformInnerSwift(inner), [aggregator, check, inner](IPCTesterInner&& reply) {
        check(reply == ipcTesterTransformed(inner), "TransformInnerSwift"_s);
    }, 0);

    Vector<IPCTesterPayload> payloads;
    payloads.append(IPCTesterPayload {
        .flag = true,
        .u8 = 0xFE,
        .u16 = 0xFFFF,
        .u32 = 123456789,
        .u64 = 0x123456789ABCDEF0,
        .i8 = std::numeric_limits<int8_t>::min(),
        .i16 = -2,
        .i32 = std::numeric_limits<int32_t>::max(),
        .i64 = 42,
        .f = 1.5f,
        .d = -0.25,
        .text = "Hello, world"_s,
        .nullText = { },
        .numbers = { 1, 2, 3, 0xFFFFFFFF },
        .strings = { "a"_s, latin1, utf16, emptyString(), String() },
        .color = IPCTesterColor::Blue,
        .flags = { IPCTesterFlag::First, IPCTesterFlag::Third },
        .choice = IPCTesterChoice::Yes,
        .inner = { 7, "inner"_s },
        .inners = { { -1, utf16 }, { 0, String() } },
        .variant = IPCTesterInner { 3, "variant"_s },
        .identifier = IPCConnectionTesterIdentifier::generate(),
    });
    payloads.append(IPCTesterPayload {
        .u64 = std::numeric_limits<uint64_t>::max(),
        .i64 = std::numeric_limits<int64_t>::min(),
        .text = emptyString(),
        .flags = { IPCTesterFlag::First, IPCTesterFlag::Second },
        .variant = std::numeric_limits<uint64_t>::max(),
    });
    payloads.append(IPCTesterPayload {
        .text = latin1,
        .color = IPCTesterColor::Red,
        .flags = { IPCTesterFlag::Second },
        .variant = utf16,
    });
    for (auto& payload : payloads) {
        connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TransformPayloadSwift(payload), [aggregator, check, payload](IPCTesterPayload&& reply) {
            check(reply == ipcTesterTransformed(payload), "TransformPayloadSwift"_s);
        }, 0);
    }

    auto syncResult = connection.sendSync(Messages::IPCTesterReceiver::TransformPayloadSynchronouslySwift(payloads[0]), 0);
    check(syncResult.succeeded() && std::get<0>(syncResult.reply()) == ipcTesterTransformed(payloads[0]), "TransformPayloadSynchronouslySwift"_s);

    Ref node = IPCTesterNode::create("root"_s, { IPCTesterNode::create("first"_s, { }), IPCTesterNode::create(String { utf16 }, { IPCTesterNode::create("grandchild"_s, { }) }) });
    RefPtr link = IPCTesterNode::create("link"_s, { IPCTesterNode::create("child"_s, { }) });
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TransformNodeSwift(node, link), [aggregator, check, node](RefPtr<IPCTesterNode>&& mirrored, uint32_t nodeCount) {
        check(mirrored && nodesAreEqual(*mirrored, ipcTesterMirrored(node)), "TransformNodeSwift mirrored"_s);
        check(nodeCount == 6, "TransformNodeSwift nodeCount"_s);
    }, 0);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TransformNodeSwift(node, nullptr), [aggregator, check](RefPtr<IPCTesterNode>&& mirrored, uint32_t nodeCount) {
        check(!mirrored, "TransformNodeSwift without link mirrored"_s);
        check(nodeCount == 4, "TransformNodeSwift without link nodeCount"_s);
    }, 0);

    auto identifier = IPCConnectionTesterIdentifier::generate();
    IPCTesterVariant variant = IPCTesterInner { -9, String() };
    auto expectedDescription = ipcTesterDescription(IPCTesterColor::Green, { IPCTesterFlag::First, IPCTesterFlag::Second }, IPCTesterChoice::No, identifier, variant, true);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::DescribeSwift(IPCTesterColor::Green, { IPCTesterFlag::First, IPCTesterFlag::Second }, IPCTesterChoice::No, identifier, variant, true), [aggregator, check, expectedDescription](String&& description) {
        check(description == expectedDescription, "DescribeSwift"_s);
    }, 0);

    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::HalveEvenNumberSwift(10), [aggregator, check](uint32_t half) {
        check(half == 5, "HalveEvenNumberSwift"_s);
    }, 0);

    connection.send(Messages::IPCTesterReceiver::RecordSwift("one"_s), 0);
    connection.send(Messages::IPCTesterReceiver::RecordSwift(String()), 0);
    connection.send(Messages::IPCTesterReceiver::RecordSwift(latin1), 0);
    connection.send(Messages::IPCTesterReceiver::RecordSwift(utf16), 0);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TakeRecordedSwift(), [aggregator, check, latin1, utf16](Vector<String>&& texts) {
        check(texts == Vector<String> { "one"_s, String(), latin1, utf16 } && texts[1].isNull(), "TakeRecordedSwift"_s);
    }, 0);
    connection.send(Messages::IPCTesterReceiver::RecordSwift("two"_s), 0);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::ClearRecordedSwift(), [aggregator] { }, 0);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TakeRecordedSwift(), [aggregator, check](Vector<String>&& texts) {
        check(texts.isEmpty(), "ClearRecordedSwift"_s);
    }, 0);

    Vector<AtomString> atoms { AtomString { "one"_s }, nullAtom(), AtomString { latin1 }, AtomString { utf16 } };
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::ReverseAtomsSwift(atoms), [aggregator, check, atoms](Vector<AtomString>&& reversed) {
        check(reversed == Vector<AtomString> { atoms[3], atoms[2], atoms[1], atoms[0] } && reversed[2].isNull(), "ReverseAtomsSwift"_s);
    }, 0);

#if ENABLE(IPC_TESTING_SWIFT)
    constexpr bool usingSwift = true;
#else
    constexpr bool usingSwift = false;
#endif
    // Swift has no String with an unpaired surrogate, so it decodes one as U+FFFD.
    const std::array<char16_t, 2> loneSurrogate { 0xD800, 'x' };
    const std::array<char16_t, 2> replacedLoneSurrogate { 0xFFFD, 'x' };
    Vector<std::pair<String, String>> textsAndRoundTrips {
        { String(), String() },
        { emptyString(), emptyString() },
        { "abc"_s, "abc"_s },
        { latin1, latin1 },
        { utf16, utf16 },
        { String(std::span { loneSurrogate }), String(std::span { usingSwift ? replacedLoneSurrogate : loneSurrogate }) },
    };
    for (auto& [text, expected] : textsAndRoundTrips) {
        connection.sendWithAsyncReply(Messages::IPCTesterReceiver::RoundTripStringThroughCxxSwift(text), [aggregator, check, expected](String&& roundTripped, uint32_t cxxLength, bool cxxIsNull, bool cxxIs8Bit) {
            check(roundTripped == expected && roundTripped.isNull() == expected.isNull() && cxxLength == expected.length() && cxxIsNull == expected.isNull() && cxxIs8Bit == expected.is8Bit(), "RoundTripStringThroughCxxSwift"_s);
        }, 0);
    }

    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::HalveEvenNumberSyncHandlerSwift(10), [aggregator, check](uint32_t half) {
        check(half == 5, "HalveEvenNumberSyncHandlerSwift"_s);
    }, 0);
    auto syncHandlerResult = connection.sendSync(Messages::IPCTesterReceiver::TransformPayloadSyncHandlerSwift(payloads[0]), 0);
    check(syncHandlerResult.succeeded() && std::get<0>(syncHandlerResult.reply()) == ipcTesterTransformed(payloads[0]), "TransformPayloadSyncHandlerSwift"_s);
    connection.send(Messages::IPCTesterReceiver::RecordSyncHandlerSwift("three"_s), 0);
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::TakeRecordedSwift(), [aggregator, check](Vector<String>&& texts) {
        check(texts == Vector<String> { "three"_s }, "RecordSyncHandlerSwift"_s);
    }, 0);

    // Below 4096 bytes a SharedBuffer is sent inline, and from 4096 in shared memory.
    for (size_t size : { 0, 1, 4095, 4096, 10000 }) {
        Vector<uint8_t> bytes(size);
        for (size_t index = 0; index < size; ++index)
            bytes[index] = static_cast<uint8_t>(index * 7);
        RefPtr<WebCore::SharedBuffer> buffer = WebCore::SharedBuffer::create(WTF::move(bytes));
        connection.sendWithAsyncReply(Messages::IPCTesterReceiver::RoundTripBufferSwift(buffer), [aggregator, check, buffer](RefPtr<WebCore::SharedBuffer>&& roundTripped, uint64_t size) {
            check(roundTripped && size == buffer->size() && equalSpans(roundTripped->span(), buffer->span()), "RoundTripBufferSwift"_s);
        }, 0);
    }
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::RoundTripBufferSwift(nullptr), [aggregator, check](RefPtr<WebCore::SharedBuffer>&& roundTripped, uint64_t size) {
        check(!roundTripped && !size, "RoundTripBufferSwift null"_s);
    }, 0);

    Vector<std::pair<String, uint32_t>> pairs { { "one"_s, 1 }, { String(), 2 }, { latin1, 3 }, { utf16, 4 } };
    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::SwapPairsSwift(pairs), [aggregator, check, pairs](Vector<std::pair<uint32_t, String>>&& swapped) {
        bool matches = swapped.size() == pairs.size();
        for (size_t index = 0; matches && index < pairs.size(); ++index)
            matches = swapped[index].first == pairs[index].second && swapped[index].second == pairs[index].first && swapped[index].second.isNull() == pairs[index].first.isNull();
        check(matches, "SwapPairsSwift"_s);
    }, 0);

    connection.sendWithAsyncReply(Messages::IPCTesterReceiver::EnabledMessageSwift(21), [aggregator, check](uint32_t doubled) {
        check(doubled == 42, "EnabledMessageSwift"_s);
    }, 0);
}

// Connection::addMessageReceiver() refs its receiver on the connection's queue, but IPCTesterReceiver's
// message receiver is only RefCounted, so is registered through this, which forwards on the main thread.
class MainThreadMessageReceiver final : public IPC::MessageReceiver, public ThreadSafeRefCounted<MainThreadMessageReceiver, WTF::DestructionThread::Main> {
public:
    static Ref<MainThreadMessageReceiver> create(Ref<IPC::MessageReceiver>&& receiver)
    {
        return adoptRef(*new MainThreadMessageReceiver(WTF::move(receiver)));
    }

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    void didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder) final
    {
        assertIsMainThread();
        m_receiver->didReceiveMessage(connection, decoder);
    }

    void didReceiveSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder) final
    {
        assertIsMainThread();
        m_receiver->didReceiveSyncMessage(connection, decoder, replyEncoder);
    }

private:
    explicit MainThreadMessageReceiver(Ref<IPC::MessageReceiver>&& receiver)
        : m_receiver(WTF::move(receiver))
    {
    }

    const Ref<IPC::MessageReceiver> m_receiver;
};

void IPCTester::addReceiverForSwiftTypesTesting(IPC::Connection& connection, CompletionHandler<void(bool)>&& completionHandler)
{
    if (!m_threadSafeReceiverForSwiftTypesTesting) {
#if ENABLE(IPC_TESTING_SWIFT)
        m_receiverForSwiftTypesTesting = WTF::makeUniqueWithoutFastMallocCheck<IPCTesterReceiver>(IPCTesterReceiver::init());
        m_threadSafeReceiverForSwiftTypesTesting = MainThreadMessageReceiver::create(m_receiverForSwiftTypesTesting->getMessageReceiver());
#else
        m_receiverForSwiftTypesTesting = IPCTesterReceiver::create();
        m_threadSafeReceiverForSwiftTypesTesting = MainThreadMessageReceiver::create(*m_receiverForSwiftTypesTesting);
#endif
    }
    connection.addMessageReceiver(RunLoop::mainSingleton(), protect(*m_threadSafeReceiverForSwiftTypesTesting), Messages::IPCTesterReceiver::messageReceiverName());
#if ENABLE(IPC_TESTING_SWIFT)
    completionHandler(true);
#else
    completionHandler(false);
#endif
}

void IPCTester::removeReceiverForSwiftTypesTesting(IPC::Connection& connection, CompletionHandler<void()>&& completionHandler)
{
    connection.removeMessageReceiver(Messages::IPCTesterReceiver::messageReceiverName());
    completionHandler();
}

#if ENABLE(IPC_TESTING_SWIFT)

namespace {

// The client end of a stream connection whose server end is in this process. It is only sent replies.
class InProcessStreamConnectionClient final : public IPC::Connection::Client, public RefCounted<InProcessStreamConnectionClient> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(InProcessStreamConnectionClient);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(InProcessStreamConnectionClient);
public:
    static Ref<InProcessStreamConnectionClient> create() { return adoptRef(*new InProcessStreamConnectionClient); }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    void didClose(IPC::Connection&) final { }
    void didReceiveInvalidMessage(IPC::Connection&, IPC::MessageName, const Vector<uint32_t>&) final { }
};

// RecordTextSwift whose is8Bit flag is not a bool, whichever bytes follow it in the stream buffer.
struct MalformedRecordTextSwift {
    static constexpr bool isSync = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;
    static constexpr IPC::MessageName name() { return IPC::MessageName::IPCSwiftStreamTester_RecordTextSwift; }

    template<typename Encoder> void encode(Encoder& encoder)
    {
        encoder << static_cast<uint32_t>(1) << static_cast<uint8_t>(2);
    }
};

}

// Sends IPCSwiftStreamTester messages through the stream buffer, which the IPC testing API can't, since it sends
// stream messages out of stream. Replies with the names of the checks that failed.
void IPCTester::sendSwiftStreamMessagesInProcess(CompletionHandler<void(String&&)>&& completionHandler)
{
    Vector<String> failures;
    auto check = [&failures](bool passed, ASCIILiteral description) {
        if (!passed)
            failures.append(description);
    };

    constexpr unsigned bufferSizeLog2 = 9;
    auto connectionPair = IPC::StreamClientConnection::create(bufferSizeLog2, 2_s);
    if (!connectionPair) {
        completionHandler("StreamClientConnection::create"_s);
        return;
    }
    Ref streamConnection = WTF::move(connectionPair->streamConnection);
    auto identifier = IPCStreamTesterIdentifier::generate();
    RefPtr tester = IPCStreamTester::create(identifier, WTF::move(connectionPair->connectionHandle), false);
    Ref client = InProcessStreamConnectionClient::create();
    streamConnection->open(client);

    // Enough messages to wrap around the stream buffer.
    uint32_t expectedDigest = 0;
    for (uint32_t value = 1; value <= 100; ++value) {
        check(streamConnection->send(Messages::IPCSwiftStreamTester::Record(value), identifier) == IPC::Error::NoError, "Record"_s);
        expectedDigest = expectedDigest * 31 + value;
    }
    for (const auto& text : { String("ascii"_s), String::fromLatin1("caf\xe9"), String::fromUTF8("\xe6\x97\xa5\xe6\x9c\xac \xe2\x98\xba") }) {
        check(streamConnection->send(Messages::IPCSwiftStreamTester::RecordTextSwift(text), identifier) == IPC::Error::NoError, "RecordTextSwift"_s);
        auto utf8 = text.utf8();
        for (auto byte : utf8.span())
            expectedDigest = expectedDigest * 31 + static_cast<uint8_t>(byte);
        expectedDigest *= 31;
    }
    auto digest = streamConnection->sendSync(Messages::IPCSwiftStreamTester::TakeRecordedDigest(), identifier);
    check(digest.succeeded() && std::get<0>(digest.reply()) == expectedDigest, "TakeRecordedDigest"_s);

    auto digestSwift = streamConnection->sendSync(Messages::IPCSwiftStreamTester::TakeRecordedDigestSwift(), identifier);
    check(digestSwift.succeeded() && !std::get<0>(digestSwift.reply()), "TakeRecordedDigestSwift"_s);

    // Replies that fit in the stream buffer, and one that has to be sent out of stream.
    for (uint32_t count : { 0u, 1u, 3u, 300u }) {
        StringBuilder expected;
        for (uint32_t i = 0; i < count; ++i)
            expected.append("abc"_s);
        auto repeated = streamConnection->sendSync(Messages::IPCSwiftStreamTester::RepeatTextSwift("abc"_s, count), identifier);
        check(repeated.succeeded() && std::get<0>(repeated.reply()) == expected.toString(), "RepeatTextSwift"_s);
    }
    auto repeatedNull = streamConnection->sendSync(Messages::IPCSwiftStreamTester::RepeatTextSwift(String(), 2), identifier);
    check(repeatedNull.succeeded() && std::get<0>(repeatedNull.reply()).isNull(), "RepeatTextSwift null"_s);

    // Asynchronous replies, sent at once, later, and dropped for the default reply.
    auto sendAdd = [&]<typename Message>(Message&& message, std::optional<bool> sendDeferredReply, uint32_t expected, ASCIILiteral description) {
        auto sum = std::make_shared<std::optional<uint32_t>>();
        auto replyID = streamConnection->sendWithAsyncReply(std::forward<Message>(message), [sum](uint32_t reply) {
            *sum = reply;
        }, identifier);
        if (sendDeferredReply)
            check(streamConnection->send(Messages::IPCSwiftStreamTester::CompleteDeferredAddSwift(*sendDeferredReply), identifier) == IPC::Error::NoError, description);
        check(replyID && streamConnection->waitForAsyncReplyAndDispatchImmediately<std::remove_cvref_t<Message>>(*replyID) == IPC::Error::NoError, description);
        check(*sum == expected, description);
    };
    sendAdd(Messages::IPCSwiftStreamTester::AddSwift(40, 2), std::nullopt, 42, "AddSwift"_s);
    sendAdd(Messages::IPCSwiftStreamTester::DeferAddSwift(40, 2), true, 42, "DeferAddSwift"_s);
    sendAdd(Messages::IPCSwiftStreamTester::DeferAddSwift(40, 2), false, 0, "DeferAddSwift dropped"_s);

    // A malformed message invalidates the stream connection, so nothing more is answered.
    check(streamConnection->send(MalformedRecordTextSwift { }, identifier) == IPC::Error::NoError, "MalformedRecordTextSwift"_s);
    auto afterMalformed = streamConnection->sendSync(Messages::IPCSwiftStreamTester::TakeRecordedDigest(), identifier);
    check(!afterMalformed.succeeded(), "TakeRecordedDigest after MalformedRecordTextSwift"_s);

    streamConnection->invalidate();
    Ref protectedTester = tester.releaseNonNull();
    protectedTester->stopListeningForIPC(protectedTester.copyRef());
    check(protectedTester->invalidMessageCount() == 1, "invalid message count"_s);
    completionHandler(makeStringByJoining(failures.span(), ", "_s));
}

// Times sending messageCount messages of one shape through the stream buffer, from this process, to IPCStreamTester's
// C++ handlers or IPCSwiftStreamTester's Swift ones, until the last one has been handled. The stream buffer is large
// enough that the time is the server's dispatch rather than the client waiting for room. Replies with 0 on failure.
void IPCTester::benchmarkStreamDispatch(uint32_t kind, bool swift, uint32_t messageCount, CompletionHandler<void(uint64_t)>&& completionHandler)
{
    constexpr unsigned bufferSizeLog2 = 20;
    auto connectionPair = IPC::StreamClientConnection::create(bufferSizeLog2, 10_s);
    if (!connectionPair) {
        completionHandler(0);
        return;
    }
    Ref streamConnection = WTF::move(connectionPair->streamConnection);
    auto identifier = IPCStreamTesterIdentifier::generate();
    RefPtr tester = IPCStreamTester::create(identifier, WTF::move(connectionPair->connectionHandle), false);
    Ref client = InProcessStreamConnectionClient::create();
    streamConnection->open(client);

    String text = "0123456789abcdef"_s;
    Vector<uint32_t> values;
    values.fill(7, 16);
    bool succeeded = true;
    auto sendOne = [&](uint32_t index) {
        IPC::Error error = IPC::Error::NoError;
        switch (kind) {
        case 0:
            error = swift ? streamConnection->send(Messages::IPCSwiftStreamTester::BenchEmptySwift(), identifier) : streamConnection->send(Messages::IPCStreamTester::EmptyMessage(), identifier);
            break;
        case 1:
            error = swift ? streamConnection->send(Messages::IPCSwiftStreamTester::BenchFourValuesSwift(index, 1, 2, 3), identifier) : streamConnection->send(Messages::IPCStreamTester::BenchFourValues(index, 1, 2, 3), identifier);
            break;
        case 2:
            error = swift ? streamConnection->send(Messages::IPCSwiftStreamTester::BenchStringSwift(text), identifier) : streamConnection->send(Messages::IPCStreamTester::BenchString(text), identifier);
            break;
        case 3:
            error = swift ? streamConnection->send(Messages::IPCSwiftStreamTester::BenchVectorSwift(values), identifier) : streamConnection->send(Messages::IPCStreamTester::BenchVector(values), identifier);
            break;
        case 4:
            if (swift) {
                auto result = streamConnection->sendSync(Messages::IPCSwiftStreamTester::BenchSyncSwift(index), identifier);
                succeeded &= result.succeeded() && std::get<0>(result.reply()) == index;
            } else {
                auto result = streamConnection->sendSync(Messages::IPCStreamTester::BenchSync(index), identifier);
                succeeded &= result.succeeded() && std::get<0>(result.reply()) == index;
            }
            break;
        case 6:
            error = swift ? streamConnection->send(Messages::IPCSwiftStreamTester::BenchEnabledFourValuesSwift(index, 1, 2, 3), identifier) : streamConnection->send(Messages::IPCStreamTester::BenchEnabledFourValues(index, 1, 2, 3), identifier);
            break;
        case 5:
            // Swift taking C++ types.
            error = swift ? streamConnection->send(Messages::IPCSwiftStreamTester::BenchFourValues(index, 1, 2, 3), identifier) : streamConnection->send(Messages::IPCStreamTester::BenchFourValues(index, 1, 2, 3), identifier);
            break;
        default:
            succeeded = false;
        }
        succeeded &= error == IPC::Error::NoError;
    };
    auto waitUntilHandled = [&] {
        succeeded &= streamConnection->sendSync(Messages::IPCStreamTester::SyncMessage(0), identifier).succeeded();
    };

    for (uint32_t index = 0; index < 1000; ++index)
        sendOne(index);
    waitUntilHandled();
    auto start = MonotonicTime::now();
    for (uint32_t index = 0; index < messageCount; ++index)
        sendOne(index);
    waitUntilHandled();
    auto elapsed = MonotonicTime::now() - start;

    streamConnection->invalidate();
    Ref protectedTester = tester.releaseNonNull();
    protectedTester->stopListeningForIPC(protectedTester.copyRef());
    completionHandler(succeeded ? static_cast<uint64_t>(elapsed.nanoseconds()) : 0);
}

#endif

} // namespace WebKit

#endif
