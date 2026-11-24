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

// WebAuthenticationPanelClient's updatePanel and dismissPanel.

extension WebKit.WebAuthenticationStatus {
    fileprivate var panelUpdate: _WKWebAuthenticationPanelUpdate {
        switch self {
        case .MultipleNFCTagsPresent:
            return .multipleNFCTagsPresent
        case .NoCredentialsFound:
            return .noCredentialsFound
        case .PinBlocked:
            return .pinBlocked
        case .PinAuthBlocked:
            return .pinAuthBlocked
        case .PinInvalid:
            return .pinInvalid
        case .LAError:
            return .laError
        case .LAExcludeCredentialsMatched:
            return .laExcludeCredentialsMatched
        case .LANoCredential:
            return .laNoCredential
        case .KeyStoreFull:
            return .keyStoreFull
        case .PINTooShort:
            return .pinTooShort
        case .PINTooLong:
            return .pinTooLong
        case .PINSuccessful:
            return .pinSuccessful
        @unknown default:
            assertionFailure()
            return .multipleNFCTagsPresent
        }
    }
}

extension WebKit.WebAuthenticationResult {
    fileprivate var panelResult: _WKWebAuthenticationResult {
        switch self {
        case .Succeeded:
            return .succeeded
        case .Failed:
            return .failed
        @unknown default:
            assertionFailure()
            return .failed
        }
    }
}

extension WebKit.WebAuthenticationPanelClient {
    @cxx
    @implementation
    override func updatePanel(_ status: WebKit.WebAuthenticationStatus) {
        if !m_delegateMethods.panelUpdateWebAuthenticationPanel {
            return
        }
        sendUpdateToDelegate(status.panelUpdate)
    }

    @cxx
    @implementation
    override func dismissPanel(_ result: WebKit.WebAuthenticationResult) {
        if !m_delegateMethods.panelDismissWebAuthenticationPanelWithResult {
            return
        }
        sendDismissToDelegate(result.panelResult)
    }
}

#endif // ENABLE_WEB_AUTHN
