// Copyright (C) 2018-2023 Apple Inc. All rights reserved.
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

internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

// AuthenticatorManager's request cancellation, timer and authenticator observation. The members that hold a
// CompletionHandler or a TransportSet (WTF::HashSet imports as an unsafe type) are in AuthenticatorManager.cpp.

// Suggested by WebAuthN spec as of 7 August 2018.
private let maxTimeOutValue: UInt32 = 120000

extension WebKit.AuthenticatorManager {
    @cxx
    @implementation
    func cancelRequest(_ pageID: WebCore.PageIdentifier, _ frameID: WebKit.WebAuthnOptionalFrameIdentifier) {
        if !hasPendingCompletionHandler() {
            return
        }
        if let pendingFrameID = Optional(fromCxx: pendingRequestData().globalFrameID) {
            if pendingFrameID.pageID.toUInt64() != pageID.toUInt64() {
                return
            }
            if let frameID = Optional(fromCxx: frameID), frameID.toUInt64() != pendingFrameID.frameID.toUInt64() {
                return
            }
        }
        cancelRequest()
    }

    @cxx
    @implementation
    func cancel() {
        precondition(WTF.RunLoop.isMain())
        if !hasPendingCompletionHandler() {
            return
        }
        cancelRequest()
    }

    @cxx
    @implementation
    func enableNativeSupport() {
        m_mode = .Native
    }

    // MARK: AuthenticatorTransportServiceObserver

    @cxx
    @implementation
    func authenticatorAdded(_ authenticator: WebKit.RefAuthenticator) {
        assert(WTF.RunLoop.isMain())
        if !hasPendingCompletionHandler() {
            return
        }
        observeAndAddAuthenticator(authenticator)
    }

    @cxx
    @implementation
    func serviceStatusUpdated(_ status: WebKit.WebAuthenticationStatus) {
        updatePresenterOrPanel(status)
    }

    // MARK: AuthenticatorObserver

    @cxx
    @implementation
    func authenticatorStatusUpdated(_ status: WebKit.WebAuthenticationStatus) {
        if !hasPendingCompletionHandler() {
            return
        }

        if status != .PINSuccessful {
            // Immediately invalidate the cache if the PIN is incorrect. A status update often means
            // an error. We don't really care what kind of error it really is.
            clearPendingCachedPin()
        }

        updatePresenterOrPanel(status)
    }

    @cxx
    @implementation
    func cancelRequest() {
        failPendingRequest(.NotAllowedError, makeWTFString("This request has been cancelled by the user."))
        WebKit.LogChannel.WebAuthn().releaseLog
            .error(
                "Request cancelled due to AuthenticatorManager::cancelRequest being called."
            )
        clearState()
        stopRequestTimeOutTimer()
    }

    @cxx
    @implementation
    func initTimeOutTimer() {
        if !hasPendingCompletionHandler() {
            return
        }
        let data = pendingRequestData()
        if Optional(fromCxx: data.mediation) == .Conditional {
            return
        }
        let timeOutInMsValue = min(maxTimeOutValue, Optional(fromCxx: WebKit.webAuthnRequestTimeout(data)) ?? maxTimeOutValue)
        startRequestTimeOutTimer(WTF.Seconds.fromMilliseconds(Double(timeOutInMsValue)))
    }

    @cxx
    @implementation
    func timeOutTimerFired() {
        failPendingRequest(.NotAllowedError, makeWTFString("Operation timed out."))
        clearState()
    }
}

#endif // ENABLE_WEB_AUTHN
