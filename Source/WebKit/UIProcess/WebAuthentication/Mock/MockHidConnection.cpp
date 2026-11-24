/*
 * Copyright (C) 2018 Apple Inc. All rights reserved.
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
#include "MockHidConnection.h"

#if ENABLE(WEB_AUTHN)

#include <WebCore/FidoConstants.h>
#include <wtf/BlockPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/darwin/DispatchExtras.h>

namespace WebKit {
using Mock = WebCore::MockWebAuthenticationConfiguration;
using namespace WebCore;
using namespace fido;

Ref<MockHidConnection> MockHidConnection::create(IOHIDDeviceRef device, const WebCore::MockWebAuthenticationConfiguration& configuration)
{
    Ref connection = adoptRef(*new MockHidConnection(device, configuration));
    // After adoptRef: the Swift member may take a reference to the object, which RefCounted forbids before adoption.
    connection->initializeExpectedCommands();
    return connection;
}

MockHidConnection::MockHidConnection(IOHIDDeviceRef device, const MockWebAuthenticationConfiguration& configuration)
    : HidConnection(device)
    , m_configuration(configuration)
{
}

void MockHidConnection::initialize()
{
    setIsInitialized(true);
}

void MockHidConnection::terminate()
{
    setIsInitialized(false);
}

auto MockHidConnection::sendSync(const Vector<uint8_t>& data) -> DataSent
{
    ASSERT(isInitialized());
    if (m_configuration.hid->expectCancel) {
        auto message = FidoHidMessage::createFromSerializedData(data);
        ASSERT_UNUSED(message, message);
        ASSERT(message->cmd() == FidoHidDeviceCommand::kCancel);
        LOG_ERROR("Request cancelled.");
    }
    return DataSent::Yes;
}

void MockHidConnection::send(Vector<uint8_t>&& data, DataSentCallback&& callback)
{
    ASSERT(isInitialized());
    auto task = makeBlockPtr([weakThis = WeakPtr { *this }, data = WTF::move(data), callback = WTF::move(callback)]() mutable {
        ASSERT(!RunLoop::isMain());
        RunLoop::mainSingleton().dispatch([weakThis, data = WTF::move(data), callback = WTF::move(callback)]() mutable {
            RefPtr protectedThis = weakThis;
            if (!protectedThis) {
                callback(DataSent::No);
                return;
            }

            protectedThis->assembleRequest(WTF::move(data));

            auto sent = DataSent::Yes;
            if (protectedThis->stagesMatch() && protectedThis->m_configuration.hid->error == Mock::HidError::DataNotSent)
                sent = DataSent::No;
            callback(sent);
        });
    });
    dispatch_async(globalDispatchQueueSingleton(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), task.get());
}

void MockHidConnection::assembleRequest(Vector<uint8_t>&& data)
{
    if (!m_requestMessage) {
        m_requestMessage = FidoHidMessage::createFromSerializedData(data);
        ASSERT(m_requestMessage);
    } else {
        auto status = m_requestMessage->addContinuationPacket(data);
        ASSERT_UNUSED(status, status);
    }

    if (m_requestMessage->messageComplete())
        parseRequest();
}

void MockHidConnection::feedReports()
{
    auto response = nextResponse();
    if (!response.valid)
        return;
    auto message = FidoHidMessage::create(response.channelId, response.cmd, WTF::move(response.payload));
    ASSERT(message);
    bool isFirst = true;
    while (message->numPackets()) {
        auto report = message->popNextPacket();
        if (!isFirst && stagesMatch() && m_configuration.hid->error == Mock::HidError::WrongChannelId)
            report = FidoHidContinuationPacket(m_currentChannel - 1, 0, { }).getSerializedData();
        // Packets are feed asynchronously to mimic actual data transmission.
        RunLoop::mainSingleton().dispatch([report = WTF::move(report), weakThis = WeakPtr { *this }]() mutable {
            if (RefPtr protectedThis = weakThis)
                protectedThis->receiveReport(WTF::move(report));
        });
        isFirst = false;
    }
}

void MockHidConnection::continueFeedReports()
{
    // Send actual response for the next run.
    RunLoop::mainSingleton().dispatch([weakThis = WeakPtr { *this }]() mutable {
        if (RefPtr protectedThis = weakThis)
            protectedThis->feedReports();
    });
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
