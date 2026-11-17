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
#include "ArrayReferenceTuple.h" // NOLINT
#include "Decoder.h" // NOLINT
#include "HandleMessage.h" // NOLINT
#include "IPCSemaphore.h" // NOLINT
#include "TestWithStreamSwiftRecordableLender.h" // NOLINT
#include "TestWithStreamSwiftRecordableMessages.h" // NOLINT
#include "TestWithStreamSwiftRecordableRun.h" // NOLINT
#include <WebCore/FloatPoint.h> // NOLINT
#if PLATFORM(COCOA)
#include <WebCore/FloatRect.h> // NOLINT
#endif
#include <WebCore/FloatSegment.h> // NOLINT
#include <WebCore/GlyphBufferMembers.h> // NOLINT
#include <WebCore/GraphicsTypes.h> // NOLINT
#include <WebCore/Path.h> // NOLINT
#include <array> // NOLINT
#include <optional> // NOLINT
#include <span> // NOLINT
#include <wtf/text/WTFString.h> // NOLINT

#if ENABLE(IPC_TESTING_API)
#include "JSIPCBinding.h"
#endif

namespace WebKit {

void TestWithStreamSwiftRecordableMessageForwarder::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::Reset::name()) {
        IPC::handleSwiftMessageWithLentState<Messages::TestWithStreamSwiftRecordable::Reset>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchReset);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetSource::name()) {
        IPC::handleSwiftMessageWithLentState<Messages::TestWithStreamSwiftRecordable::SetSource>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchSetSource);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetValues::name()) {
        IPC::handleSwiftMessageWithLentState<Messages::TestWithStreamSwiftRecordable::SetValues>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchSetValues);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::DrawRun::name()) {
        IPC::handleSwiftMessageWithLentState<Messages::TestWithStreamSwiftRecordable::DrawRun>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchDrawRun);
        return;
    }
#if PLATFORM(COCOA)
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::Draw::name()) {
        IPC::handleSwiftMessageWithLentState<Messages::TestWithStreamSwiftRecordable::Draw>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchDraw);
        return;
    }
#endif
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetLabel::name()) {
        IPC::handleSwiftTypesMessageWithLentState<Messages::TestWithStreamSwiftRecordable::SetLabel>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchSetLabel);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetLabelSource::name()) {
        IPC::handleSwiftTypesMessageWithLentState<Messages::TestWithStreamSwiftRecordable::SetLabelSource>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchSetLabelSource);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::FillPath::name()) {
        IPC::handleSwiftTypesMessageWithLentState<Messages::TestWithStreamSwiftRecordable::FillPath>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchFillPath);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetSemaphore::name()) {
        IPC::handleSwiftTypesMessageWithLentState<Messages::TestWithStreamSwiftRecordable::SetSemaphore>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchSetSemaphore);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::DrawGlyphs::name()) {
        IPC::handleSwiftTypesMessageWithLentState<Messages::TestWithStreamSwiftRecordable::DrawGlyphs>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchDrawGlyphs);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetMatrix::name()) {
        IPC::handleSwiftTypesMessageWithLentState<Messages::TestWithStreamSwiftRecordable::SetMatrix>(connection, decoder, m_stateLender, m_handler.get(), &TestWithStreamSwiftRecordableWeakRef::dispatchSetMatrix);
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithStreamSwiftRecordableWeakRef> makeTestWithStreamSwiftRecordableWeakRefUniquePtr(TestWithStreamSwiftRecordableWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithStreamSwiftRecordableWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithStreamSwiftRecordableWeakRef>(newRef);
}

TestWithStreamSwiftRecordableMessageForwarder::TestWithStreamSwiftRecordableMessageForwarder(TestWithStreamSwiftRecordableWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithStreamSwiftRecordableWeakRefUniquePtr(target))
{
}

TestWithStreamSwiftRecordableMessageForwarder::~TestWithStreamSwiftRecordableMessageForwarder()
{
}

void TestWithStreamSwiftRecordableMessageForwarder::setStateLender(WebKit::TestWithStreamSwiftRecordableLender& lender)
{
    m_stateLender = &lender;
}

void TestWithStreamSwiftRecordableRecorderMessageForwarder::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    dispatch(&connection, decoder);
}

bool TestWithStreamSwiftRecordableRecorderMessageForwarder::didReceiveRecordedMessages(std::span<const uint8_t> messages)
{
    return IPC::forEachRecordedMessage(messages, [&](IPC::Decoder& decoder) {
        dispatch(nullptr, decoder);
        return decoder.isValid();
    });
}

void TestWithStreamSwiftRecordableRecorderMessageForwarder::dispatch(IPC::StreamServerConnection* connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::Reset::name()) {
        IPC::handleSwiftRecordedMessage<Messages::TestWithStreamSwiftRecordable::Reset>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchReset);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetSource::name()) {
        IPC::handleSwiftRecordedMessage<Messages::TestWithStreamSwiftRecordable::SetSource>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchSetSource);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetValues::name()) {
        IPC::handleSwiftRecordedMessage<Messages::TestWithStreamSwiftRecordable::SetValues>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchSetValues);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::DrawRun::name()) {
        IPC::handleSwiftRecordedMessage<Messages::TestWithStreamSwiftRecordable::DrawRun>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchDrawRun);
        return;
    }
#if PLATFORM(COCOA)
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::Draw::name()) {
        IPC::handleSwiftRecordedMessage<Messages::TestWithStreamSwiftRecordable::Draw>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchDraw);
        return;
    }
#endif
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetLabel::name()) {
        IPC::handleSwiftTypesRecordedMessage<Messages::TestWithStreamSwiftRecordable::SetLabel>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchSetLabel);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetLabelSource::name()) {
        IPC::handleSwiftTypesRecordedMessage<Messages::TestWithStreamSwiftRecordable::SetLabelSource>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchSetLabelSource);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::FillPath::name()) {
        IPC::handleSwiftTypesRecordedMessage<Messages::TestWithStreamSwiftRecordable::FillPath>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchFillPath);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetSemaphore::name()) {
        IPC::handleSwiftTypesRecordedMessage<Messages::TestWithStreamSwiftRecordable::SetSemaphore>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchSetSemaphore);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::DrawGlyphs::name()) {
        IPC::handleSwiftTypesRecordedMessage<Messages::TestWithStreamSwiftRecordable::DrawGlyphs>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchDrawGlyphs);
        return;
    }
    if (decoder.messageName() == Messages::TestWithStreamSwiftRecordable::SetMatrix::name()) {
        IPC::handleSwiftTypesRecordedMessage<Messages::TestWithStreamSwiftRecordable::SetMatrix>(connection, decoder, m_handler.get(), &TestWithStreamSwiftRecordableRecorderWeakRef::dispatchSetMatrix);
        return;
    }
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

static std::unique_ptr<TestWithStreamSwiftRecordableRecorderWeakRef> makeTestWithStreamSwiftRecordableRecorderWeakRefUniquePtr(TestWithStreamSwiftRecordableRecorderWeakRef* WTF_NONNULL handler)
{
    auto newRef = _impl::_impl_TestWithStreamSwiftRecordableRecorderWeakRef::makeRetained(handler);
    return WTF::makeUniqueWithoutFastMallocCheck<TestWithStreamSwiftRecordableRecorderWeakRef>(newRef);
}

TestWithStreamSwiftRecordableRecorderMessageForwarder::TestWithStreamSwiftRecordableRecorderMessageForwarder(TestWithStreamSwiftRecordableRecorderWeakRef* WTF_NONNULL target)
    : m_handler(makeTestWithStreamSwiftRecordableRecorderWeakRefUniquePtr(target))
{
}

TestWithStreamSwiftRecordableRecorderMessageForwarder::~TestWithStreamSwiftRecordableRecorderMessageForwarder()
{
}

void TestWithStreamSwiftRecordableRecordedMessageEncoder::encodeReset()
{
    IPC::appendRecordedMessage(m_encodedMessages, Messages::TestWithStreamSwiftRecordable::Reset::name());
}

void TestWithStreamSwiftRecordableRecordedMessageEncoder::encodeSetValues(uint32_t value, float scale)
{
    IPC::appendRecordedMessage(m_encodedMessages, Messages::TestWithStreamSwiftRecordable::SetValues::name(), value, scale);
}

void TestWithStreamSwiftRecordableRecordedMessageEncoder::encodeDrawRun(const WebCore::FloatPoint& origin, const WebKit::TestWithStreamSwiftRecordableRun& run)
{
    IPC::appendRecordedMessage(m_encodedMessages, Messages::TestWithStreamSwiftRecordable::DrawRun::name(), origin, run);
}

#if PLATFORM(COCOA)
void TestWithStreamSwiftRecordableRecordedMessageEncoder::encodeDraw(const WebCore::FloatRect& rect, bool clip)
{
    IPC::appendRecordedMessage(m_encodedMessages, Messages::TestWithStreamSwiftRecordable::Draw::name(), rect, clip);
}

#endif

IPC::SwiftReplyEncoder* TestWithStreamSwiftRecordableRecordedMessageEncoder::encoderForSetLabel()
{
    return IPC::SwiftReplyEncoder::createForRecordedMessage(Messages::TestWithStreamSwiftRecordable::SetLabel::name());
}

IPC::SwiftReplyEncoder* TestWithStreamSwiftRecordableRecordedMessageEncoder::encoderForFillPath()
{
    return IPC::SwiftReplyEncoder::createForRecordedMessage(Messages::TestWithStreamSwiftRecordable::FillPath::name());
}

IPC::SwiftReplyEncoder* TestWithStreamSwiftRecordableRecordedMessageEncoder::encoderForDrawGlyphs()
{
    return IPC::SwiftReplyEncoder::createForRecordedMessage(Messages::TestWithStreamSwiftRecordable::DrawGlyphs::name());
}

IPC::SwiftReplyEncoder* TestWithStreamSwiftRecordableRecordedMessageEncoder::encoderForSetMatrix()
{
    return IPC::SwiftReplyEncoder::createForRecordedMessage(Messages::TestWithStreamSwiftRecordable::SetMatrix::name());
}

void TestWithStreamSwiftRecordableRecordedMessageEncoder::appendEncodedMessage(IPC::SwiftReplyEncoder& encoder)
{
    IPC::appendSwiftEncodedRecordedMessage(m_encodedMessages, encoder);
}


} // namespace WebKit

#if ENABLE(IPC_TESTING_API)

namespace IPC {

template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_Reset>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::Reset::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_SetSource>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::SetSource::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_SetValues>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::SetValues::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_DrawRun>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::DrawRun::Arguments>(globalObject, decoder);
}
#if PLATFORM(COCOA)
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_Draw>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::Draw::Arguments>(globalObject, decoder);
}
#endif
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_SetLabel>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::SetLabel::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_SetLabelSource>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::SetLabelSource::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_FillPath>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::FillPath::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_SetSemaphore>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::SetSemaphore::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_DrawGlyphs>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::DrawGlyphs::Arguments>(globalObject, decoder);
}
template<> std::optional<JSC::JSValue> jsValueForDecodedMessage<MessageName::TestWithStreamSwiftRecordable_SetMatrix>(JSC::JSGlobalObject* globalObject, Decoder& decoder)
{
    return jsValueForDecodedArguments<Messages::TestWithStreamSwiftRecordable::SetMatrix::Arguments>(globalObject, decoder);
}

}

#endif

