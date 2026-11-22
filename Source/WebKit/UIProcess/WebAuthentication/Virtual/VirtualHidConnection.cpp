/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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
#include "VirtualHidConnection.h"

#if ENABLE(WEB_AUTHN)

#include "VirtualAuthenticatorManager.h"
#include <WebCore/FidoConstants.h>
#include <wtf/BlockPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/darwin/DispatchExtras.h>

namespace WebKit {
using namespace fido;
using namespace WebCore;

Ref<VirtualHidConnection> VirtualHidConnection::create(const String& authenticatorId, const VirtualAuthenticatorConfiguration& configuration, const WeakPtr<VirtualAuthenticatorManager>& manager)
{
    return adoptRef(*new VirtualHidConnection(authenticatorId, configuration, manager));
}

VirtualHidConnection::VirtualHidConnection(const String& authenticatorId, const VirtualAuthenticatorConfiguration& configuration, const WeakPtr<VirtualAuthenticatorManager>& manager)
    : HidConnection(nullptr)
    , m_manager(manager)
    , m_configuration(configuration)
    , m_authenticatorId(authenticatorId)
{
}

void VirtualHidConnection::initialize()
{
    setIsInitialized(true);
}

void VirtualHidConnection::terminate()
{
    setIsInitialized(false);
}

auto VirtualHidConnection::sendSync(const Vector<uint8_t>& data) -> DataSent
{
    ASSERT(isInitialized());
    return DataSent::Yes;
}

void VirtualHidConnection::send(Vector<uint8_t>&& data, DataSentCallback&& callback)
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

            callback(DataSent::Yes);
        });
    });
    dispatch_async(globalDispatchQueueSingleton(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), task.get());
}

void VirtualHidConnection::assembleRequest(Vector<uint8_t>&& data)
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

void VirtualHidConnection::receiveHidMessage(fido::FidoHidMessage&& message)
{
    while (message.numPackets()) {
        auto report = message.popNextPacket();
        RunLoop::mainSingleton().dispatch([report = WTF::move(report), weakThis = WeakPtr { *this }]() mutable {
            if (RefPtr protectedThis = weakThis)
                protectedThis->receiveReport(WTF::move(report));
        });
    }
}

void VirtualHidConnection::receiveResponse(Vector<uint8_t> buffer)
{
    auto message = FidoHidMessage::create(m_currentChannel, FidoHidDeviceCommand::kCbor, WTF::move(buffer));
    receiveHidMessage(WTF::move(*message));
}

void VirtualHidConnection::recieveResponseCode(fido::CtapDeviceResponseCode code)
{
    Vector<uint8_t> buffer;
    buffer.append(static_cast<uint8_t>(code));

    receiveResponse(WTF::move(buffer));
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
