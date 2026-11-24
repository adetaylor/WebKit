// Copyright (C) 2019 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEB_AUTHN && HAVE_NEAR_FIELD

import Foundation
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

// NfcConnection's polling and FIDO applet selection. Every member runs on the main run loop: the reader session's
// delegate hops there before calling didDetectTags, which calls trySelectFidoApplet, and the retry timer fires there.

extension WebKit.NfcConnection {
    // Confirm the FIDO applet is available.
    // https://fidoalliance.org/specs/fido-v2.0-ps-20190130/fido-client-to-authenticator-protocol-v2.0-ps-20190130.html#nfc-applet-selection
    @cxx
    @implementation
    func trySelectFidoApplet() -> Bool {
        let session: NFReaderSession = m_session.get()
        var versionData: Data? = session.transceive(Data(Array(fido.kCtapNfcAppletSelectionCommand)))
        if compareVersion(versionData, Array(fido.kCtapNfcAppletSelectionU2f))
            || compareVersion(versionData, Array(fido.kCtapNfcAppletSelectionCtap))
        {
            return true
        }

        // Some legacy U2F keys such as Google T1 Titan don't understand the FIDO applet command. Instead,
        // they are configured to only have the FIDO applet. Therefore, when the above command fails, we
        // use U2F_VERSION command to double check if the connected tag can actually speak U2F, indicating
        // we are interacting with one of these legacy keys.
        versionData = session.transceive(Data(Array(fido.kCtapNfcU2fVersionCommand)))
        if compareVersion(versionData, Array(fido.kCtapNfcAppletSelectionU2f)) {
            return true
        }

        return false
    }

    // NearField polling is a one shot polling. It halts after tags are detected.
    // Therefore, a restart process is needed to resume polling after error.
    @cxx
    @implementation
    func restartPolling() {
        m_session.get().stopPolling()
        startRetryTimer(WTF.Seconds(1)) // Magic number to give users enough time for reactions.
    }

    @cxx
    @implementation
    func startPolling() {
        do {
            try m_session.get().startPolling()
        } catch {
            webAuthnLogError("Couldn't start NFC reader polling: \(error)")
        }
    }
}

private func compareVersion(_ data: Data?, _ version: [UInt8]) -> Bool {
    guard let data else {
        return false
    }
    return data.elementsEqual(version)
}

#endif // ENABLE_WEB_AUTHN && HAVE_NEAR_FIELD
