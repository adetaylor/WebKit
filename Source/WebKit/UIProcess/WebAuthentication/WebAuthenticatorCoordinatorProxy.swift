// Copyright (C) 2018-2021 Apple Inc. All rights reserved.
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

// The receiver of WebAuthenticatorCoordinatorProxy.messages.in (SwiftReceiver, SwiftTarget=). The C++
// WebAuthenticatorCoordinatorProxy owns it and its forwarder. It is not actor-isolated, because the generated forwarder
// hands it to C++ (an actor-isolated class is not exposed to C++); every handler is @MainActor, as the generated
// dispatch runs it, and the C++ owner calls the rest on the main thread.
//
// This file holds the stored state, makeCredential, getAssertion, handleRequest, the autofill events and the helpers
// both request paths use; WebAuthenticatorCoordinatorProxy+AS.swift the AuthenticationServices request path;
// +Legacy.swift the legacy ASC path, the queries, the signals, cancel and conditional mediation.
@_expose(Cxx)
final class WebAuthenticatorCoordinatorProxySwift {
    typealias RequestReply = (WebCore.AuthenticatorResponseData, WebCore.AuthenticatorAttachment, WebCore.ExceptionData)
    // What MakeCredential's and GetAssertion's handlers reply with: the generated reply object of either message, which
    // have the same reply.
    @MainActor
    protocol RequestCompletionHandler: AnyObject, Sendable {
        func callAsFunction(_ reply: RequestReply)
        // Ends the request without a reply: the web process is never answered.
        func dropWithoutReplying()
    }

    private struct AutofillEvent {
        // How long a recorded autofill can consent to a conditional registration.
        private static let autofillEventTimeout = 5.0 * 60

        var time: WTF.MonotonicTime
        var username: WTF.String
        var url: WTF.URL

        // MonotonicTime's operators do not import, so the comparison is on its seconds.
        func isExpired(at now: WTF.MonotonicTime) -> Bool {
            time.secondsSinceEpoch().value() + Self.autofillEventTimeout < now.secondsSinceEpoch().value()
        }
    }

    // Reached only through livePage: the owner's destructor can run inside ~WebPageProxy, whose WeakPtr still
    // upgrades there, and a page Swift kept from that upgrade would outlive its storage.
    private let pageWeakPtr: WebKit.WeakPtrWebPageProxy
    // Set first in cancelForDestruction; the receiver can outlive its owner while a handler's task finishes, and
    // then answers as when there is no coordinator.
    private var isDisconnected = false
    private lazy var messageForwarder = WebKit.WebAuthenticatorCoordinatorProxyMessageForwarder.create(target: self)

    // The completion handler of the request in flight on the AuthenticationServices path, called once.
    var pendingRequest: (any RequestCompletionHandler)?

    // Ends the request in flight without a reply where its completion handler is let go of uncalled: replaced by a
    // later request, cleared by a cancel after a paused completion, destroyed with the coordinator. Not @MainActor:
    // the owner's destructor calls it on the main thread.
    func dropPendingRequest() {
        guard let completionHandler = pendingRequest.take() else {
            return
        }
        MainActor.assumeIsolated {
            completionHandler.dropWithoutReplying()
        }
    }
    #if HAVE_WEB_AUTHN_AS_MODERN
    // The request in flight's controller and the delegate it holds weakly; set and cleared together.
    var authorization: (controller: ASAuthorizationController, delegate: WKASDelegate)?
    var isPaused = false
    var isConditionalMediation = false
    private var recentAutofills: [AutofillEvent] = []
    #endif
    #if HAVE_UNIFIED_ASC_AUTH_UI
    var presenter: ASCAuthorizationRemotePresenter?
    var agentProxy: ASCAgentProxy?
    #endif
    // What the cancelled request's completion calls, once and inline: a Cancel's reply, or a pause's completion.
    var pendingCancel: (() -> Void)?

    @used
    init(page: consuming WebKit.WeakPtrWebPageProxy) {
        self.pageWeakPtr = page
    }

    @used
    func getMessageReceiver() -> RefWebAuthenticatorCoordinatorProxyMessageForwarder {
        messageForwarder
    }

    // The generated receiver checks EnabledBy=WebAuthenticationEnabled with these (SharedPreferencesNeedsConnection).
    @used
    func sharedPreferencesForWebProcess(_ connection: IPC.Connection) -> WebKit.OptionalSharedPreferencesForWebProcess {
        WebKit.webAuthnSharedPreferencesForWebProcess(connection)
    }

    // The page while this receiver's owner lives. Upgrade it again after every await, and keep neither it nor its
    // authenticator manager across one.
    var livePage: WebKit.WebPageProxy? {
        isDisconnected ? nil : pageWeakPtr.get()
    }

    // MARK: The request handlers

    @MainActor
    func makeCredential(
        connection: IPC.Connection,
        frameID: WebCore.FrameIdentifier,
        frameInfo: WebKit.FrameInfoData,
        options: WebCore.PublicKeyCredentialCreationOptions,
        mediation: WebCore.MediationRequirement,
        completionHandler: any RequestCompletionHandler
    ) async {
        let data: WebKit.WebAuthenticationRequestData
        do {
            // The page stays in this scope, before the first await.
            guard let webPageProxy = livePage else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("WebPageProxy had been released")
                completionHandler(Self.failure(.NotSupportedError, "This request is not supported at this time."))
                return
            }
            guard webFrameForFrameID(frameID) != nil else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Frame not found for WebAuthn MakeCredential request")
                completionHandler(Self.failure(.InvalidStateError))
                return
            }
            data = WebKit.makeWebAuthenticationRequestData(
                options,
                webPageProxy,
                frameID,
                frameInfo,
                mediation,
                WebKit.WebAuthnOptionalSecurityOriginData()
            )
        }
        await handleRequest(data, completionHandler)
    }

    @MainActor
    func getAssertion(
        connection: IPC.Connection,
        frameID: WebCore.FrameIdentifier,
        frameInfo: WebKit.FrameInfoData,
        options: WebCore.PublicKeyCredentialRequestOptions,
        mediation: WebCore.MediationRequirement,
        parentOrigin untrustedParentOrigin: WebCore.UntrustedOptionalSecurityOriginData,
        completionHandler: any RequestCompletionHandler
    ) async throws(InvalidMessage) {
        // Checked below against the origins this frame's ancestors committed, which the UI process derives itself, but
        // only where one of them is HTTP-family.
        // FIXME: https://bugs.webkit.org/show_bug.cgi?id=325604 Add a new validator to strengthen this check
        let parentOrigin = WebKit.extractValidatedElsewhere(untrustedParentOrigin)
        let data: WebKit.WebAuthenticationRequestData
        do {
            // The page and the frames stay in this scope, before the first await.
            guard let webPageProxy = livePage else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("WebPageProxy had been released")
                completionHandler(Self.failure(.NotSupportedError, "This request is not supported at this time."))
                return
            }
            guard let frame = webFrameForFrameID(frameID) else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Frame not found for WebAuthn GetAssertion request")
                completionHandler(Self.failure(.InvalidStateError))
                return
            }
            if let claimedParentOrigin = parentOrigin.value {
                var foundMatchingAncestor = false
                var hasHTTPAncestor = false
                var ancestor = frame.parentFrame()
                while let current = ancestor {
                    ancestor = current.parentFrame()
                    let url = WebKit.webAuthnFrameURL(current)
                    guard url.protocolIsInHTTPFamily() else {
                        continue
                    }
                    hasHTTPAncestor = true
                    if claimedParentOrigin == WebCore.SecurityOriginData.fromURLWithoutStrictOpaqueness(url) {
                        foundMatchingAncestor = true
                        break
                    }
                }
                if hasHTTPAncestor {
                    try messageCheck(orReply: Self.failure(.InvalidStateError)) { foundMatchingAncestor }
                }
            }
            data = WebKit.makeWebAuthenticationRequestData(
                options,
                webPageProxy,
                frameID,
                frameInfo,
                mediation,
                parentOrigin
            )
        }
        await handleRequest(data, completionHandler)
    }

    // MARK: Called by the C++ owner

    // The owner's destructor, on the main thread: cancels the request with no reply. It can run inside
    // ~WebPageProxy, so from here on livePage is nil.
    @used
    func cancelForDestruction() {
        isDisconnected = true
        cancelRequestForDestruction()
    }

    #if HAVE_WEB_AUTHN_AS_MODERN
    // The body reads the active-proxy static, which is @MainActor; the owner calls this on the main thread, once per
    // window activation. The generated withMainActorTarget reaches the receiver on the main actor, as message dispatch
    // reaches it: a @MainActor member is not exposed to C++, and self cannot be sent.
    @used
    func makeActiveConditionalAssertion() {
        withMainActorTarget { $0.makeActiveConditionalAssertionBody() }
    }

    @used
    func recordAutofill(_ username: consuming WTF.String, _ url: consuming WTF.URL) {
        removeExpiredAutofillEvents()
        recentAutofills.append(AutofillEvent(time: WTF.MonotonicTime.now(), username: username, url: url))
    }

    private func removeExpiredAutofillEvents() {
        let now = WTF.MonotonicTime.now()
        recentAutofills.removeAll { $0.isExpired(at: now) }
    }

    private func removeMatchingAutofillEventForUsername(_ username: WTF.String, _ securityOrigin: WebCore.SecurityOriginData) -> Bool {
        removeExpiredAutofillEvents()
        guard
            let index = recentAutofills.lastIndex(where: {
                $0.username == username && WebCore.RegistrableDomain($0.url) == WebCore.RegistrableDomain(securityOrigin)
            })
        else {
            return false
        }
        recentAutofills.remove(at: index)
        return true
    }
    #endif

    // MARK: Handling a request

    // Neither the page nor its authenticator manager is held across an await in this section: each is read again
    // after one, through livePage (setMockWebAuthenticationConfiguration can replace the manager while the embedder
    // is asked).
    @MainActor
    private func handleRequest(
        _ requestData: WebKit.WebAuthenticationRequestData,
        _ completionHandler: any RequestCompletionHandler
    ) async {
        var data = requestData
        guard data.frameInfo.hasValue else {
            completionHandler(Self.failure(.InvalidStateError, attachment: .Platform))
            return
        }
        guard let isMockOrVirtual = isMockOrVirtualAuthenticatorManager() else {
            completionHandler(Self.failure(.InvalidStateError, attachment: .Platform))
            return
        }

        if data.mediation.value == .Conditional && !isMockOrVirtual && WebKit.webAuthnRequestIsCreation(data) {
            let consented = await conditionalRegistrationConsent(WebKit.webAuthnRequestCreationOptions(data), data.callerOrigin())
            guard livePage != nil else {
                completionHandler(Self.failure(.InvalidStateError, attachment: .Platform))
                return
            }
            guard consented else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Request cancelled due to rejected prompt after lack of user gesture.")
                completionHandler(Self.failure(.NotAllowedError, "This request has been cancelled by the user."))
                return
            }
        }

        guard let isMockOrVirtual = isMockOrVirtualAuthenticatorManager() else {
            completionHandler(Self.failure(.InvalidStateError, attachment: .Platform))
            return
        }
        if !isMockOrVirtual {
            guard isASCAvailable() else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Web Authentication is not currently supported in this environment.")
                completionHandler(Self.failure(.NotSupportedError, "Not implemented.", attachment: .Platform))
                return
            }
            // performRequest calls out to ASCAgent which will then call
            // [_WKWebAuthenticationPanel makeCredential/getAssertionWithChallenge], which calls
            // authenticatorManager->handleRequest(..).
            await performRequest(data, completionHandler)
            return
        }

        // AS API makes no difference between SameSite vs CrossOrigin.
        let clientDataJSON = WebKit.webAuthnClientDataJSONForRequest(data, data.callerOrigin())
        guard let clientData = clientDataJSON.get() else {
            preconditionFailure("A request without client data JSON")
        }
        data.hash = WebCore.buildClientDataJsonHash(clientData)
        guard let webPageProxy = livePage else {
            completionHandler(Self.failure(.InvalidStateError, attachment: .Platform))
            return
        }
        webPageProxy.websiteDataStore().authenticatorManager()
            .handleRequest(
                consuming: data,
                consuming: WebKit.makeAuthenticatorManagerCallback(
                    consuming: .init { respond in
                        let reply = WebKit.webAuthnRequestReply(respond, clientDataJSON)
                        completionHandler((reply.data, reply.attachment, reply.exception))
                    }
                )
            )
    }

    // Whether the page's authenticator manager is the mock or the virtual one; nil once the page is gone.
    @MainActor
    private func isMockOrVirtualAuthenticatorManager() -> Bool? {
        guard let webPageProxy = livePage else {
            return nil
        }
        let authenticatorManager = webPageProxy.websiteDataStore().authenticatorManager()
        return authenticatorManager.isMock() || authenticatorManager.isVirtual()
    }

    // The embedder's consent to a conditional registration, with the related origins only when the caller matches
    // the RP ID or the well-known list relates it; no consent falls back to a recent autofill event. No consent once
    // the page is gone.
    @MainActor
    private func conditionalRegistrationConsent(
        _ options: borrowing WebCore.PublicKeyCredentialCreationOptions,
        _ callerOrigin: WebCore.SecurityOriginData
    ) async -> Bool {
        let username = options.user.name
        let relyingPartyIdentifier = options.rp.id
        var origins = fido.StringVector()
        if !relyingPartyIdentifier.isEmpty() {
            guard let result = await relatedOrigins(callerOrigin, relyingPartyIdentifier) else {
                return false
            }
            let callerMatchesRelyingParty = callerOrigin.securityOrigin().get().isMatchingRegistrableDomainSuffix(relyingPartyIdentifier)
            if callerMatchesRelyingParty || result.isRelated {
                origins = result.origins
            }
        }
        let consented: WebCore.OptionalBool? = await withCheckedContinuation { continuation in
            guard let webPageProxy = livePage else {
                continuation.resume(returning: nil)
                return
            }
            WebKit.webAuthnRequestConditionalMediationRegistration(
                webPageProxy,
                username,
                origins,
                consuming: .init { (consented: WebCore.OptionalBool) in
                    continuation.resume(returning: consented)
                }
            )
        }
        guard let consented, livePage != nil else {
            return false
        }
        #if HAVE_WEB_AUTHN_AS_MODERN
        return consented.value ?? removeMatchingAutofillEventForUsername(username, callerOrigin)
        #else
        return consented.value ?? false
        #endif
    }

    // RelatedOriginsValidation.validate for the live page; nil once the page is gone.
    @MainActor
    private func relatedOrigins(
        _ callerOrigin: WebCore.SecurityOriginData,
        _ relyingPartyIdentifier: WTF.String
    ) async -> WebKit.RelatedOriginsValidation.Result? {
        await WebKit.RelatedOriginsValidation.validate({ livePage }, callerOrigin, relyingPartyIdentifier)
    }

    static func failure(
        _ code: WebCore.ExceptionCode,
        _ message: Swift.String,
        attachment: WebCore.AuthenticatorAttachment = .Platform
    ) -> RequestReply {
        failure(code, makeWTFString(message), attachment: attachment)
    }

    static func failure(
        _ code: WebCore.ExceptionCode,
        _ message: WTF.String = WTF.String(),
        attachment: WebCore.AuthenticatorAttachment = .Platform
    ) -> RequestReply {
        (WebCore.AuthenticatorResponseData(), attachment, WebCore.ExceptionData(code: code, message: message))
    }
}

extension WebAuthenticatorCoordinatorProxyMakeCredentialReply: WebAuthenticatorCoordinatorProxySwift.RequestCompletionHandler {}

extension WebAuthenticatorCoordinatorProxyGetAssertionReply: WebAuthenticatorCoordinatorProxySwift.RequestCompletionHandler {}

extension WebKit.WebAuthenticationRequestData {
    // The origin of the requesting frame's document; opaque once the frame is gone.
    func callerOrigin() -> WebCore.SecurityOriginData {
        guard let frameID = globalFrameID.value?.frameID, let frame = webFrameForFrameID(frameID) else {
            return WebCore.SecurityOriginData.createOpaque()
        }
        return frame.documentSecurityOriginData()
    }
}

// MARK: Shared helpers

// ArrayBuffer::create of `bytes`. An empty Array or Data has no base address, and a Span without one traps at the
// std::span parameter, so an empty one makes the empty buffer directly.
func webAuthnMakeArrayBuffer(_ bytes: Span<UInt8>) -> JSC.RefArrayBuffer {
    if bytes.isEmpty {
        return JSC.ArrayBuffer.create(0, 1)
    }
    return JSC.ArrayBuffer.createFromSpan(bytes)
}

func webAuthnMakeArrayBufferPtr(_ data: Data) -> fido.ArrayBufferPtr {
    fido.ArrayBufferPtr(webAuthnMakeArrayBuffer(data.span).get())
}

func webAuthnMakeArrayBufferPtrNilIfEmpty(_ data: Data?) -> fido.ArrayBufferPtr {
    guard let data, !data.isEmpty else {
        return fido.ArrayBufferPtr()
    }
    return webAuthnMakeArrayBufferPtr(data)
}

// The error's NSLocalizedDescriptionKey, or the null string.
func webAuthnLocalizedDescription(_ error: NSError) -> WTF.String {
    (error.userInfo[NSLocalizedDescriptionKey] as? Swift.String).map(makeWTFString) ?? WTF.String()
}

// The NSError code as an ExceptionCode, which is a uint8_t: any value that is not one of its cases is NotAllowedError.
func webAuthnExceptionCode(forErrorCode nsErrorCode: Int) -> WebCore.ExceptionCode {
    let rawValue = UInt8(truncatingIfNeeded: nsErrorCode)
    let exceptionCode: WebCore.ExceptionCode? = WebCore.ExceptionCode(rawValue: rawValue)
    guard rawValue <= WebCore.ExceptionCode.ExistingExceptionError.rawValue, let exceptionCode else {
        return .NotAllowedError
    }
    return exceptionCode
}

#endif // ENABLE_WEB_AUTHN
