/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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

#import "config.h"
#import "NfcConnection.h"

#if ENABLE(WEB_AUTHN) && HAVE(NEAR_FIELD)

#import "MainRunLoopDestroyedHandler.h"
#import "NfcService.h"
#import "WKNFReaderSessionDelegate.h"
#import <wtf/BlockPtr.h>
#import <wtf/Borrow.h>
#import <wtf/cocoa/VectorCocoa.h>

namespace WebKit {

Ref<NfcConnection> NfcConnection::create(RetainPtr<NFReaderSession>&& session, NfcService& service)
{
    return adoptRef(*new NfcConnection(WTF::move(session), service));
}

NfcConnection::NfcConnection(RetainPtr<NFReaderSession>&& session, NfcService& service)
    : m_session(WTF::move(session))
    , m_delegate(adoptNS([[WKNFReaderSessionDelegate alloc] initWithConnection:*this]))
    , m_service(service)
    , m_retryTimer(RunLoop::mainSingleton(), "NfcConnection::RetryTimer"_s, this, &NfcConnection::startPolling)
{
    [m_session setDelegate:m_delegate.get()];
    startPolling();
}

NfcConnection::~NfcConnection()
{
    stop();
}

Vector<uint8_t> NfcConnection::transact(Vector<uint8_t>&& data) const
{
    // The method will return an empty NSData if the tag is disconnected.
    RetainPtr responseData = [m_session transceive:toNSData(borrow(data)->span()).get()];
    return makeVector(responseData.get());
}

void NfcConnection::stop() const
{
    [m_session disconnectTag];
    [m_session stopPolling];
    [m_session endSession];
}

void NfcConnection::stopWithCompletionHandler(CompletionHandler<void()>&& completionHandler)
{
    [m_session disconnectTag];
    [m_session stopPolling];
    // The handler is called, or destroyed if the block is dropped uncalled, on the main run loop where it was made,
    // whichever queue runs or releases the block.
    [m_session endSessionWithCompletion:makeBlockPtr([completionHandler = MainRunLoopDestroyedHandler { WTF::move(completionHandler) }] mutable {
        RunLoop::mainSingleton().dispatch([completionHandler = completionHandler.take()] mutable {
            completionHandler();
        });
    }).get()];
}

void NfcConnection::didDetectTags(NSArray *tags)
{
    RefPtr service = m_service.get();
    if (!service || !tags.count)
        return;

    // A physical NFC tag could have multiple interfaces.
    // Therefore, we use tagID to detect if there are multiple physical tags.
    RetainPtr<NSData> tagID = ((NFTag *)tags[0]).tagID;
    for (NFTag *tag : tags) {
        if ([tagID isEqualToData:retainPtr(tag.tagID).get()])
            continue;
        service->didDetectMultipleTags();
        restartPolling();
        return;
    }

    // FIXME(203234): Tell users to switch to a different tag if the tag is not supported or can't speak U2F/FIDO2.
    for (NFTag *tag : tags) {
        // FIDO tag is ISO-DEP which can be Tag4A, Tag4B, and DESFIRE (Tag4A).
        if ((tag.type != NFTagTypeGeneric4A && tag.type != NFTagTypeGeneric4B && tag.type != NFTagTypeMiFareDESFire) || ![m_session connectTag:tag])
            continue;

        if (!trySelectFidoApplet()) {
            [m_session disconnectTag];
            continue;
        }

        service->didConnectTag();
        return;
    }
    restartPolling();
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN) && HAVE(NEAR_FIELD)
