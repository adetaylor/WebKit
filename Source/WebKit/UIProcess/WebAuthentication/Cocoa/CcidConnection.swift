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

#if ENABLE_WEB_AUTHN

import Foundation
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

private let kGetUidCommand: [UInt8] = [
    0xFF, 0xCA, 0x00, 0x00, 0x00,
]

extension WebKit.CcidConnection {
    @cxx
    @implementation
    func startPolling() {
        detectContactless()
    }

    @cxx
    @implementation
    func detectContactless() {
        let weakThis = threadSafeWeakThis()
        transact(
            consuming: makeByteVector(kGetUidCommand),
            consuming: .init { response in
                assert(WTF.RunLoop.isMain())
                guard let protectedThis = weakThis.get().get() else {
                    return
                }
                // Only contactless smart cards have uid, check for longer length than apdu status
                if response.size() > 2 {
                    protectedThis.m_contactless = true
                }
                protectedThis.trySelectFidoApplet()
            }
        )
    }

    @cxx
    @implementation
    func trySelectFidoApplet() {
        let weakThis = threadSafeWeakThis()
        transact(
            consuming: makeByteVector(Array(fido.kCtapNfcAppletSelectionCommand)),
            consuming: .init { response in
                assert(WTF.RunLoop.isMain())
                guard let protectedThis = weakThis.get().get() else {
                    return
                }
                let responseBytes = makeByteArray(response.span())
                if responseBytes == Array(fido.kCtapNfcAppletSelectionU2f)
                    || responseBytes == Array(fido.kCtapNfcAppletSelectionCtap)
                {
                    protectedThis.service().get()?.didConnectTag()
                    return
                }
                // Some legacy U2F keys don't understand the FIDO applet selection command and are configured to
                // only have the FIDO applet. When applet selection fails, use the U2F_VERSION command to check
                // whether the connected tag can speak U2F, indicating one of these legacy keys.
                protectedThis.transact(
                    consuming: makeByteVector(Array(fido.kCtapNfcU2fVersionCommand)),
                    consuming: .init { response in
                        assert(WTF.RunLoop.isMain())
                        guard let protectedThis = weakThis.get().get() else {
                            return
                        }
                        if makeByteArray(response.span()) == Array(fido.kCtapNfcAppletSelectionU2f) {
                            protectedThis.service().get()?.didConnectTag()
                            return
                        }
                        protectedThis.stop()
                    }
                )
            }
        )
    }
}

#endif // ENABLE_WEB_AUTHN
