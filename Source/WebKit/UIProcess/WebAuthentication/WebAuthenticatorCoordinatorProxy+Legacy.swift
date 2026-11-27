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

// The legacy ASC path, the queries, the signals, cancel and conditional mediation.
// The ASC classes are reached as the soft-link hook makes them (looked up by name), and the optional ones and
// ASCWebKitSPISupport only through WebAuthnSoftLinkForSwift.h's functions. A framework reply comes on the framework's
// queue: what it carries is turned there into values the reply owns, and the rest runs on the main actor.
extension WebAuthenticatorCoordinatorProxySwift {
    // MARK: The queries

    @MainActor
    func isConditionalMediationAvailable(
        connection: IPC.Connection,
        origin untrustedOrigin: WebCore.UntrustedSecurityOriginData
    ) async -> Bool {
        guard let origin = extractWithMessageCheck(untrustedOrigin, speakingForDomainOn: connection) else {
            return false
        }
        #if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
        let canAccessPasskeyData = await canCurrentProcessAccessPasskeys(forRelyingParty: origin)
        return canAccessPasskeyData && WebKit.webAuthnASCShouldUseAlternateCredentialStore()
        #else
        return false
        #endif
    }

    @MainActor
    func isUserVerifyingPlatformAuthenticatorAvailable(
        connection: IPC.Connection,
        origin untrustedOrigin: WebCore.UntrustedSecurityOriginData
    ) async -> Bool {
        #if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
        guard let origin = extractWithMessageCheck(untrustedOrigin, speakingForDomainOn: connection) else {
            return false
        }
        guard livePage?.configuration().backgroundTextExtractionEnabled() == false else {
            return false
        }
        guard await canCurrentProcessAccessPasskeys(forRelyingParty: origin) else {
            return false
        }
        guard WebKit.webAuthnASCShouldUseAlternateCredentialStore() else {
            return false
        }
        #if HAVE_WEB_AUTHN_PUBLIC_KEY_CREDENTIAL_MANAGER
        guard ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys else {
            return false
        }
        #endif
        return await !arePasskeysDisallowed(forRelyingParty: origin)
        #else
        return WebKit.LocalService.isAvailable()
        #endif
    }

    @MainActor
    func getClientCapabilities(
        connection: IPC.Connection,
        origin untrustedOrigin: WebCore.UntrustedSecurityOriginData
    ) async -> WebKit.WebAuthnClientCapabilities {
        guard let origin = extractWithMessageCheck(untrustedOrigin, speakingForDomainOn: connection) else {
            return WebKit.WebAuthnClientCapabilities()
        }
        #if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
        let relyingParty = relyingPartyDomain(origin)
        let reported: [(key: Swift.String, value: Bool)]? = await withCheckedContinuation { continuation in
            let called = WebKit.webAuthnASCGetClientCapabilities(relyingParty) { result in
                var capabilities = result.map { (key: $0.key, value: $0.value.boolValue) }
                setRelatedOriginsCapability(&capabilities)
                // codePointCompareLessThan: by UTF-16 code unit.
                capabilities.sort { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
                continuation.resume(returning: capabilities)
            }
            if !called {
                continuation.resume(returning: nil)
            }
        }
        var capabilities = WebKit.WebAuthnClientCapabilities()
        if let reported {
            for capability in reported {
                WebKit.appendWebAuthnClientCapability(&capabilities, makeWTFString(capability.key), capability.value)
            }
        } else {
            // ASCWebKitSPISupport has no getClientCapabilitiesForRelyingParty:.
            WebKit.appendWebAuthnClientCapability(&capabilities, makeWTFString(relatedOriginsCapability), true)
        }
        return capabilities
        #else
        return WebKit.WebAuthnClientCapabilities()
        #endif
    }

    // MARK: The signals

    // Each signal replies once, except in an internal SDK build with no credential updater, where it drops its reply
    // and the web process is never answered.

    @MainActor
    func signalUnknownCredential(
        connection: IPC.Connection,
        origin untrustedOrigin: WebCore.UntrustedSecurityOriginData,
        options: WebCore.UnknownCredentialOptions,
        completionHandler: WebAuthenticatorCoordinatorProxySignalUnknownCredentialReply
    ) async throws(InvalidMessage) {
        if let refusal = try checkSignal(from: untrustedOrigin, relyingParty: options.rpId, on: connection) {
            completionHandler(refusal)
            return
        }
        guard let credentialID = fido.base64URLDecodeString(options.credentialId).value else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Failed to parse credentialId for signalUnknownCredential.")
            completionHandler(Self.signalFailure("Unable to parse credential ID."))
            return
        }
        #if USE_APPLE_INTERNAL_SDK
        let relyingParty = makeSwiftString(options.rpId)
        let credentialIDData = makeData(credentialID.span())
        let failed: Bool? = await withCheckedContinuation { continuation in
            guard WebKit.webAuthnCredentialUpdaterShimIsAvailable() else {
                continuation.resume(returning: nil)
                return
            }
            CredentialUpdaterShim.signalUnknownCredential(withRelyingPartyIdentifier: relyingParty, credentialID: credentialIDData) {
                error in
                if let error {
                    WebKit.LogChannel.WebAuthn().releaseLog.error("Error signaling unknown credential: \(error.localizedDescription).")
                }
                continuation.resume(returning: error != nil)
            }
        }
        guard let failed else {
            completionHandler.dropWithoutReplying()
            return
        }
        completionHandler(failed ? Self.signalFailure("Error signaling unknown credential.") : WebCore.OptionalExceptionData())
        #else
        completionHandler(Self.signalFailure("Unsupported."))
        #endif
    }

    @MainActor
    func signalAllAcceptedCredentials(
        connection: IPC.Connection,
        origin untrustedOrigin: WebCore.UntrustedSecurityOriginData,
        options: WebCore.AllAcceptedCredentialsOptions,
        completionHandler: WebAuthenticatorCoordinatorProxySignalAllAcceptedCredentialsReply
    ) async throws(InvalidMessage) {
        if let refusal = try checkSignal(from: untrustedOrigin, relyingParty: options.rpId, on: connection) {
            completionHandler(refusal)
            return
        }
        guard let userHandle = fido.base64URLDecodeString(options.userId).value else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Failed to parse userHandle for signalAllAcceptedCredentials.")
            completionHandler(Self.signalFailure("Unable to parse credential ID."))
            return
        }
        var credentialIDs: [Data] = []
        for credential in options.allAcceptedCredentialIds {
            guard let decodedCredentialID = fido.base64URLDecodeString(credential).value else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Failed to parse credentialId for signalAllAcceptedCredentials.")
                completionHandler(Self.signalFailure("Unable to parse credential ID."))
                return
            }
            credentialIDs.append(makeData(decodedCredentialID.span()))
        }
        #if USE_APPLE_INTERNAL_SDK
        let relyingParty = makeSwiftString(options.rpId)
        let userHandleData = makeData(userHandle.span())
        let failed: Bool? = await withCheckedContinuation { continuation in
            guard WebKit.webAuthnCredentialUpdaterShimIsAvailable() else {
                continuation.resume(returning: nil)
                return
            }
            CredentialUpdaterShim.signalAllAcceptedCredentials(
                withRelyingPartyIdentifier: relyingParty,
                userHandle: userHandleData,
                acceptedCredentialIDs: credentialIDs
            ) { error in
                if let error {
                    WebKit.LogChannel.WebAuthn().releaseLog
                        .error("Error signaling all accepted credentials: \(error.localizedDescription).")
                }
                continuation.resume(returning: error != nil)
            }
        }
        guard let failed else {
            completionHandler.dropWithoutReplying()
            return
        }
        completionHandler(failed ? Self.signalFailure("Error signaling all accepted credentials") : WebCore.OptionalExceptionData())
        #else
        _ = userHandle
        completionHandler(Self.signalFailure("Unsupported."))
        #endif
    }

    @MainActor
    func signalCurrentUserDetails(
        connection: IPC.Connection,
        origin untrustedOrigin: WebCore.UntrustedSecurityOriginData,
        options: WebCore.CurrentUserDetailsOptions,
        completionHandler: WebAuthenticatorCoordinatorProxySignalCurrentUserDetailsReply
    ) async throws(InvalidMessage) {
        if let refusal = try checkSignal(from: untrustedOrigin, relyingParty: options.rpId, on: connection) {
            completionHandler(refusal)
            return
        }
        guard let userHandle = fido.base64URLDecodeString(options.userId).value else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Failed to parse userHandle for signalAllAcceptedCredentials.")
            completionHandler(Self.signalFailure("Unable to parse credential ID."))
            return
        }
        #if USE_APPLE_INTERNAL_SDK
        let relyingParty = makeSwiftString(options.rpId)
        let userHandleData = makeData(userHandle.span())
        let newName = makeSwiftString(options.name)
        let failed: Bool? = await withCheckedContinuation { continuation in
            guard WebKit.webAuthnCredentialUpdaterShimIsAvailable() else {
                continuation.resume(returning: nil)
                return
            }
            CredentialUpdaterShim.signalCurrentUserDetails(
                withRelyingPartyIdentifier: relyingParty,
                userHandle: userHandleData,
                newName: newName
            ) { error in
                if let error {
                    WebKit.LogChannel.WebAuthn().releaseLog.error("Error signaling current user details: \(error.localizedDescription).")
                }
                continuation.resume(returning: error != nil)
            }
        }
        guard let failed else {
            completionHandler.dropWithoutReplying()
            return
        }
        completionHandler(failed ? Self.signalFailure("Error signaling current user details.") : WebCore.OptionalExceptionData())
        #else
        _ = userHandle
        completionHandler(Self.signalFailure("Unsupported."))
        #endif
    }

    // The checks every signal makes first: the sender speaks for the origin's domain, and the relying party is a
    // registrable domain of it. nil when both pass; otherwise the reply. The caller's name and place are what a failed
    // check logs, as when each signal made the checks itself.
    @MainActor
    private func checkSignal(
        from untrustedOrigin: WebCore.UntrustedSecurityOriginData,
        relyingParty: WTF.String,
        on connection: IPC.Connection,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws(InvalidMessage) -> WebCore.OptionalExceptionData? {
        guard
            let origin = extractWithMessageCheck(
                untrustedOrigin,
                speakingForDomainOn: connection,
                function: function,
                file: file,
                line: line
            )
        else {
            return Self.notAuthorizedForRelyingParty()
        }
        try messageCheck(orReply: Self.notAuthorizedForRelyingParty(), function: function, file: file, line: line) {
            fido.webAuthnRelyingPartyIsRegistrableDomainOf(relyingParty, origin)
        }
        return nil
    }

    private static func notAuthorizedForRelyingParty() -> WebCore.OptionalExceptionData {
        WebCore.OptionalExceptionData(
            WebCore.ExceptionData(code: .SecurityError, message: makeWTFString("Not authorized for this relying party"))
        )
    }

    private static func signalFailure(_ message: Swift.String) -> WebCore.OptionalExceptionData {
        WebCore.OptionalExceptionData(WebCore.ExceptionData(code: .UnknownError, message: makeWTFString(message)))
    }

    // MARK: Cancel

    // The Cancel message. With a request in flight, the reply waits for the request's completion (which resumes
    // pendingCancel); otherwise it is immediate. Either way the request is then cancelled.
    @MainActor
    func cancel(connection: IPC.Connection) async {
        guard hasRequestInFlight else {
            cancelUnderlyingRequests()
            return
        }
        await withCheckedContinuation { continuation in
            replacePendingCancel { continuation.resume() }
            cancelUnderlyingRequests()
        }
        #if HAVE_WEB_AUTHN_AS_MODERN
        // Run after the completion: clears the request, and a request a paused completion did not answer is never
        // answered.
        guard livePage != nil else {
            return
        }
        authorization = nil
        dropPendingRequest()
        #endif
    }

    // The owner's destructor: ends the request without a reply and resumes the pending cancel. Not @MainActor; reads
    // no page.
    func cancelRequestForDestruction() {
        #if HAVE_UNIFIED_ASC_AUTH_UI
        cancelUnderlyingRequests()
        #endif
        dropPendingRequest()
        pendingCancel.take()?()
    }

    private var hasRequestInFlight: Bool {
        #if HAVE_WEB_AUTHN_AS_MODERN
        return pendingRequest != nil || authorization != nil
        #elseif HAVE_UNIFIED_ASC_AUTH_UI
        return agentProxy != nil
        #else
        return false
        #endif
    }

    private func cancelUnderlyingRequests() {
        #if HAVE_UNIFIED_ASC_AUTH_UI
        if let agentProxy {
            agentProxy.cancelCurrentRequest()
            self.agentProxy = nil
        }
        #endif
        #if HAVE_WEB_AUTHN_AS_MODERN
        authorization?.controller.cancel()
        #endif
    }

    // The one replaced, a waiting Cancel's reply or a pause's resumption, is resumed after the new one is stored, since a
    // pause's completion runs inline.
    private func replacePendingCancel(_ pending: @escaping () -> Void) {
        let replaced = pendingCancel.take()
        pendingCancel = pending
        replaced?()
    }

    // MARK: Conditional mediation

    #if HAVE_WEB_AUTHN_AS_MODERN
    // The receiver whose conditional assertion is the one running; set when one starts and cleared in its
    // completion.
    @MainActor
    static weak var activeConditionalMediationProxy: WebAuthenticatorCoordinatorProxySwift?

    @MainActor
    func makeActiveConditionalAssertionBody() {
        // A receiver whose owner is gone is no longer the active one.
        guard let activeProxy = Self.activeConditionalMediationProxy, activeProxy.livePage != nil else {
            unpauseConditionalAssertion()
            return
        }
        if activeProxy === self && !isPaused {
            return
        }
        activeProxy.pauseConditionalAssertion { [weak self] in
            guard let self, self.livePage != nil else {
                return
            }
            self.unpauseConditionalAssertion()
        }
    }

    // Calls the completion inline unless a conditional assertion is running and not yet paused; then it pauses it,
    // and the assertion's completion calls it (or destruction does).
    @MainActor
    func pauseConditionalAssertion(_ completion: @escaping () -> Void) {
        guard !isPaused, isConditionalMediation else {
            completion()
            return
        }
        isPaused = true
        replacePendingCancel(completion)
        authorization?.controller.cancel()
    }

    @MainActor
    func unpauseConditionalAssertion() {
        guard isPaused else {
            return
        }
        if let authorization, isConditionalMediation {
            Self.activeConditionalMediationProxy = self
            authorization.controller.performAutoFillAssistedRequests()
        }
        isPaused = false
    }
    #endif

    // MARK: The legacy ASC path

    #if HAVE_UNIFIED_ASC_AUTH_UI
    // The request context for the legacy path (webAuthenticationASEnabled off), or nil when the request needs what this
    // AuthenticationServicesCore lacks (an autofill assertion, or a cross-origin assertion).
    func contextForRequest(_ requestData: borrowing WebKit.WebAuthenticationRequestData) -> ASCCredentialRequestContext? {
        let callerOrigin = requestData.callerOrigin()
        let globalFrameID = requestData.globalFrameID.value
        let mediation = requestData.mediation.value
        if WebKit.webAuthnRequestIsCreation(requestData) {
            return configureRegistrationRequestContext(
                WebKit.webAuthnRequestCreationOptions(requestData),
                globalFrameID,
                mediation,
                callerOrigin
            )
        }
        return configureAssertionRequestContext(
            WebKit.webAuthnRequestRequestOptions(requestData),
            mediation,
            globalFrameID,
            requestData.parentOrigin.value,
            callerOrigin
        )
    }

    // The legacy request: silent, autofill (Mac), or the agent's own UI, on Mac through the remote presenter.
    @MainActor
    func performRequestLegacy(_ requestContext: ASCCredentialRequestContext) async -> RequestReply {
        guard requestContext.requestTypes != 0 else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Request cancelled due to none requestTypes.")
            return Self.failure(.NotAllowedError, makeWTFString("This request has been cancelled by the user."))
        }
        let agentProxy = ASCAgentProxy()
        self.agentProxy = agentProxy

        if requestContext.requestStyle == .silent {
            let reply = await withCheckedContinuation { continuation in
                agentProxy.performSilentAuthorizationRequests(for: requestContext) { credential, error in
                    continuation.resume(returning: legacyRequestReply(credential, error))
                }
            }
            return finishAgentRequest(
                reply,
                logMessage: "Request cancelled after WebAuthenticatorCoordinatorProxy invalid after starting request."
            )
        }

        #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
        if requestContext.responds(to: #selector(getter: ASCCredentialRequestContext.requestStyle))
            && requestContext.requestStyle == .autoFill
        {
            let reply = await withCheckedContinuation { continuation in
                agentProxy.performAutoFillAuthorizationRequests(for: requestContext) { credential, error in
                    continuation.resume(returning: legacyRequestReply(credential, error))
                }
            }
            return finishAgentRequest(
                reply,
                logMessage: "Request cancelled after WebAuthenticatorCoordinatorProxy invalid after staring request."
            )
        }
        #endif

        #if WTF_PLATFORM_IOS || WTF_PLATFORM_VISION
        do {
            guard let webPageProxy = livePage else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("WebPageProxy had been released")
                return Self.failure(.NotAllowedError, makeWTFString("Operation failed."))
            }
            if let pageClient = webPageProxy.pageClient() {
                requestContext.windowSceneIdentifier = makeSwiftString(pageClient.sceneID())
            }
        }
        let reply = await withCheckedContinuation { continuation in
            agentProxy.performAuthorizationRequests(for: requestContext) { credential, error in
                continuation.resume(returning: legacyRequestReply(credential, error))
            }
        }
        if livePage != nil {
            self.agentProxy = nil
        }
        return reply
        #elseif WTF_PLATFORM_MAC
        // A missing page or window fails as a missing daemon does.
        guard let window = livePage?.platformWindow() else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("WebPageProxy had been released")
            self.agentProxy = nil
            return Self.failure(.NotAllowedError, makeWTFString("Operation failed."))
        }
        let clearance: (endpoint: NSXPCListenerEndpoint?, error: (any Error)?) = await withCheckedContinuation { continuation in
            agentProxy.performAuthorizationRequests(for: requestContext) { daemonEndpoint, error in
                continuation.resume(returning: (daemonEndpoint, error))
            }
        }
        let isLive = livePage != nil
        guard isLive, let daemonEndpoint = clearance.endpoint else {
            WebKit.LogChannel.WebAuthn().releaseLog
                .error("Could not connect to authorization daemon: \(clearance.error?.localizedDescription ?? "(null)").")
            if isLive {
                self.agentProxy = nil
            }
            return Self.failure(.NotAllowedError, makeWTFString("Operation failed."))
        }
        let presenter = ASCAuthorizationRemotePresenter()
        self.presenter = presenter
        let reply = await withCheckedContinuation { continuation in
            presenter.present(with: window, daemonEndpoint: daemonEndpoint) { credential, error in
                continuation.resume(returning: legacyRequestReply(credential, error))
            }
        }
        if livePage != nil {
            self.agentProxy = nil
        }
        return reply
        #else
        return Self.failure(.NotAllowedError, makeWTFString("Operation failed."))
        #endif
    }

    // The silent and autofill replies, once on the main actor: a receiver whose owner went away meanwhile fails the
    // request.
    @MainActor
    private func finishAgentRequest(_ reply: RequestReply, logMessage: Swift.String) -> RequestReply {
        guard livePage != nil else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("\(logMessage, privacy: .public)")
            return Self.failure(.NotAllowedError, makeWTFString("Operation failed."))
        }
        agentProxy = nil
        return reply
    }
    #endif // HAVE_UNIFIED_ASC_AUTH_UI
}

// MARK: The passkey queries

#if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
private let relatedOriginsCapability = "relatedOrigins"

private func setRelatedOriginsCapability(_ capabilities: inout [(key: Swift.String, value: Bool)]) {
    if let index = capabilities.firstIndex(where: { $0.key == relatedOriginsCapability }) {
        capabilities[index].value = true
        return
    }
    capabilities.append((key: relatedOriginsCapability, value: true))
}

// The relying party the ASCWebKitSPISupport queries take: the origin's domain.
private func relyingPartyDomain(_ origin: borrowing WebCore.SecurityOriginData) -> Swift.String {
    makeSwiftString(WebKit.webAuthnSecurityOriginDomain(origin))
}

// false when ASCWebKitSPISupport cannot answer.
@MainActor
private func canCurrentProcessAccessPasskeys(forRelyingParty origin: borrowing WebCore.SecurityOriginData) async -> Bool {
    let relyingParty = relyingPartyDomain(origin)
    return await withCheckedContinuation { continuation in
        let called = WebKit.webAuthnASCGetCanCurrentProcessAccessPasskeys(relyingParty) { result in
            continuation.resume(returning: result)
        }
        if !called {
            continuation.resume(returning: false)
        }
    }
}

// false when ASCWebKitSPISupport cannot answer.
@MainActor
private func arePasskeysDisallowed(forRelyingParty origin: borrowing WebCore.SecurityOriginData) async -> Bool {
    let relyingParty = relyingPartyDomain(origin)
    return await withCheckedContinuation { continuation in
        let called = WebKit.webAuthnASCGetArePasskeysDisallowed(relyingParty) { result in
            continuation.resume(returning: result)
        }
        if !called {
            continuation.resume(returning: false)
        }
    }
}
#endif

// MARK: The legacy request context

#if HAVE_UNIFIED_ASC_AUTH_UI
extension WebCore.UserVerificationRequirement {
    fileprivate var ascUserVerificationPreference: Swift.String {
        switch self {
        case .Required:
            return "required"
        case .Discouraged:
            return "discouraged"
        case .Preferred:
            return "preferred"
        @unknown default:
            return "preferred"
        }
    }
}

extension WebCore.AttestationConveyancePreference {
    fileprivate var ascAttestationPreference: Swift.String {
        switch self {
        case .Direct:
            return "direct"
        case .Indirect:
            return "indirect"
        case WebCore.AttestationConveyancePreference.None:
            return "none"
        case .Enterprise:
            return "enterprise"
        @unknown default:
            return "none"
        }
    }
}

private func toASCDescriptor(_ descriptor: borrowing WebCore.PublicKeyCredentialDescriptor) -> ASCPublicKeyCredentialDescriptor {
    var transports: [Swift.String]?
    if !descriptor.transports.isEmpty() {
        var transportStrings: [Swift.String] = []
        for transport in descriptor.transports {
            switch transport {
            case .Usb:
                transportStrings.append("usb")
            case .Nfc:
                transportStrings.append("nfc")
            case .Ble:
                transportStrings.append("ble")
            case .Internal:
                transportStrings.append("internal")
            case .Cable:
                transportStrings.append("cable")
            case .Hybrid:
                transportStrings.append("hybrid")
            case .SmartCard:
                transportStrings.append("smart-card")
            @unknown default:
                break
            }
        }
        transports = transportStrings
    }
    let credentialID = descriptor.id
    return ASCPublicKeyCredentialDescriptor(credentialID: makeData(credentialID.span()), transports: transports)
}

// An ASCWebAuthenticationExtensionsClientInputs with the appid, or nil when this AuthenticationServicesCore has none.
private func toASCExtensions(
    _ extensions: borrowing WebCore.AuthenticationExtensionsClientInputs
) -> (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
    WebKit.createWebAuthnASCExtensionsClientInputs(makeSwiftString(extensions.appid))
}

private func setGlobalFrameIDForContext(_ requestContext: ASCCredentialRequestContext, _ globalFrameID: WebCore.GlobalFrameIdentifier?) {
    guard let globalFrameID else {
        return
    }
    let asGlobalFrameID = WebKit.createWebAuthnASGlobalFrameIdentifier(
        NSNumber(value: UInt(globalFrameID.pageID.toUInt64())),
        NSNumber(value: UInt(globalFrameID.frameID.toUInt64()))
    )
    // Sets it only where the context has the property.
    _ = WebKit.webAuthnSetASCCredentialRequestContextGlobalFrameID(requestContext, asGlobalFrameID)
}

private func toASCResidentKeyPreference(
    _ requirement: WebCore.ResidentKeyRequirement?,
    _ requireResidentKey: Bool
) -> ASPublicKeyCredentialResidentKeyPreference {
    guard let requirement else {
        return requireResidentKey ? .required : .notPresent
    }
    switch requirement {
    case .Discouraged:
        return .discouraged
    case .Preferred:
        return .preferred
    case .Required:
        return .required
    @unknown default:
        assertionFailure("Unknown ResidentKeyRequirement")
        return .notPresent
    }
}

// WebCore::buildClientDataJson's bytes, as the request options carry them.
private func clientDataJSON(
    _ type: WebCore.ClientDataType,
    _ challenge: borrowing WebCore.BufferSource,
    _ callerOrigin: borrowing WebCore.SecurityOriginData,
    _ scope: WebAuthn.Scope,
    _ topOrigin: WTF.String
) -> Data {
    let securityOrigin = callerOrigin.securityOrigin()
    let json = WebCore.buildClientDataJson(type, challenge, securityOrigin.get(), scope, topOrigin)
    let bytes = json.get().toVector()
    return makeData(bytes.span())
}

private func configureRegistrationRequestContext(
    _ options: WebCore.PublicKeyCredentialCreationOptions,
    _ globalFrameID: WebCore.GlobalFrameIdentifier?,
    _ mediation: WebCore.MediationRequirement?,
    _ callerOrigin: borrowing WebCore.SecurityOriginData
) -> ASCCredentialRequestContext {
    var requestTypes: ASCCredentialRequestTypes = [.platformPublicKeyRegistration, .securityKeyPublicKeyRegistration]

    var userVerification: Swift.String?
    var shouldRequireResidentKey = false
    var residentKeyRequirement: WebCore.ResidentKeyRequirement?
    if let authenticatorSelection = options.authenticatorSelection.value {
        let attachment = authenticatorSelection.authenticatorAttachment.value
        if attachment == .Platform {
            requestTypes = .platformPublicKeyRegistration
        } else if attachment == .CrossPlatform {
            requestTypes = .securityKeyPublicKeyRegistration
        }

        userVerification = authenticatorSelection.userVerification.ascUserVerificationPreference

        shouldRequireResidentKey = authenticatorSelection.requireResidentKey
        residentKeyRequirement = authenticatorSelection.residentKey.value
    }
    if !WebKit.LocalService.isAvailable() {
        requestTypes.remove(.platformPublicKeyRegistration)
    }

    let requestContext = ASCCredentialRequestContext(requestTypes: requestTypes)
    assert(!options.rp.id.isNull())
    let relyingPartyIdentifier = makeSwiftString(options.rp.id)
    requestContext.relyingPartyIdentifier = relyingPartyIdentifier
    setGlobalFrameIDForContext(requestContext, globalFrameID)

    let credentialCreationOptions = ASCPublicKeyCredentialCreationOptions()

    credentialCreationOptions.clientDataJSON = clientDataJSON(.Create, options.challenge, callerOrigin, .SameOrigin, WTF.String())

    credentialCreationOptions.relyingPartyIdentifier = relyingPartyIdentifier
    credentialCreationOptions.userName = makeSwiftString(options.user.name)
    let userID = options.user.id
    credentialCreationOptions.userIdentifier = makeData(userID.span())
    credentialCreationOptions.userDisplayName = makeSwiftString(options.user.displayName)
    credentialCreationOptions.userVerificationPreference = userVerification
    if credentialCreationOptions.responds(to: #selector(setter: ASCPublicKeyCredentialCreationOptions.residentKeyPreference)) {
        credentialCreationOptions.residentKeyPreference = toASCResidentKeyPreference(residentKeyRequirement, shouldRequireResidentKey)
    } else {
        credentialCreationOptions.shouldRequireResidentKey = shouldRequireResidentKey
    }
    credentialCreationOptions.attestationPreference = options.attestation.ascAttestationPreference

    var supportedAlgorithmIdentifiers: [NSNumber] = []
    for algorithmParameter in options.pubKeyCredParams {
        supportedAlgorithmIdentifiers.append(NSNumber(value: algorithmParameter.alg))
    }
    credentialCreationOptions.supportedAlgorithmIdentifiers = supportedAlgorithmIdentifiers

    if !options.excludeCredentials.isEmpty() {
        var excludedCredentials: [ASCPublicKeyCredentialDescriptor] = []
        for descriptor in options.excludeCredentials {
            excludedCredentials.append(toASCDescriptor(descriptor))
        }
        credentialCreationOptions.excludedCredentials = excludedCredentials
    }

    if let extensions = options.extensions.value {
        if credentialCreationOptions.responds(to: #selector(setter: ASCPublicKeyCredentialCreationOptions.extensionsCBOR)) {
            let extensionsCBOR = extensions.toCBOR()
            credentialCreationOptions.extensionsCBOR = makeData(extensionsCBOR.span())
        } else {
            WebKit.webAuthnSetASCCreationOptionsExtensions(credentialCreationOptions, toASCExtensions(extensions))
        }
    }

    if let timeout = options.timeout.value,
        credentialCreationOptions.responds(to: #selector(setter: ASCPublicKeyCredentialCreationOptions.timeout))
    {
        credentialCreationOptions.timeout = NSNumber(value: timeout)
    }

    if requestTypes.contains(.platformPublicKeyRegistration) {
        requestContext.platformKeyCredentialCreationOptions = credentialCreationOptions
    }

    if requestTypes.contains(.securityKeyPublicKeyRegistration) {
        requestContext.securityKeyCredentialCreationOptions = credentialCreationOptions
    }

    if mediation == .Conditional {
        requestContext.requestStyle = .silent
    }

    return requestContext
}

private func configureAssertionOptions(
    _ options: borrowing WebCore.PublicKeyCredentialRequestOptions,
    _ kind: ASCPublicKeyCredentialKind,
    _ parentOrigin: WebCore.SecurityOriginData?,
    _ allowedCredentials: [ASCPublicKeyCredentialDescriptor]?,
    _ userVerification: Swift.String,
    _ callerOrigin: borrowing WebCore.SecurityOriginData
) -> ASCPublicKeyCredentialAssertionOptions? {
    // AS API makes no difference between SameSite vs CrossOrigin
    let scope: WebAuthn.Scope = parentOrigin != nil ? .CrossOrigin : .SameOrigin
    let topOrigin = parentOrigin.map { $0.toString() } ?? WTF.String()
    let clientData = clientDataJSON(.Get, options.challenge, callerOrigin, scope, topOrigin)
    let relyingPartyIdentifier = makeSwiftString(options.rpId)
    let assertionOptions: ASCPublicKeyCredentialAssertionOptions
    if ASCPublicKeyCredentialAssertionOptions.instancesRespond(
        to: #selector(
            ASCPublicKeyCredentialAssertionOptions.init(
                kind:
                relyingPartyIdentifier:
                clientDataJSON:
                userVerificationPreference:
                allowedCredentials:
                origin:
            )
        )
    ) {
        assertionOptions = ASCPublicKeyCredentialAssertionOptions(
            kind: kind,
            relyingPartyIdentifier: relyingPartyIdentifier,
            clientDataJSON: clientData,
            userVerificationPreference: userVerification,
            allowedCredentials: allowedCredentials,
            origin: makeSwiftString(callerOrigin.toString())
        )
    } else {
        assertionOptions = ASCPublicKeyCredentialAssertionOptions(
            kind: kind,
            relyingPartyIdentifier: relyingPartyIdentifier,
            clientDataJSON: clientData,
            userVerificationPreference: userVerification,
            allowedCredentials: allowedCredentials
        )
    }
    if let extensions = options.extensions.value {
        if assertionOptions.responds(to: #selector(setter: ASCPublicKeyCredentialAssertionOptions.extensionsCBOR)) {
            let extensionsCBOR = extensions.toCBOR()
            assertionOptions.extensionsCBOR = makeData(extensionsCBOR.span())
        } else {
            WebKit.webAuthnSetASCAssertionOptionsExtensions(assertionOptions, toASCExtensions(extensions))
        }
    }
    if let parentOrigin {
        guard assertionOptions.responds(to: #selector(setter: ASCPublicKeyCredentialAssertionOptions.destinationSiteForCrossSiteAssertion))
        else {
            return nil
        }
        assertionOptions.destinationSiteForCrossSiteAssertion = makeSwiftString(fido.webAuthnRegistrableDomain(parentOrigin))
    }
    if let timeout = options.timeout.value, assertionOptions.responds(to: #selector(setter: ASCPublicKeyCredentialAssertionOptions.timeout))
    {
        assertionOptions.timeout = NSNumber(value: timeout)
    }
    return assertionOptions
}

private func configureAssertionRequestContext(
    _ options: borrowing WebCore.PublicKeyCredentialRequestOptions,
    _ mediation: WebCore.MediationRequirement?,
    _ globalFrameID: WebCore.GlobalFrameIdentifier?,
    _ parentOrigin: WebCore.SecurityOriginData?,
    _ callerOrigin: borrowing WebCore.SecurityOriginData
) -> ASCCredentialRequestContext? {
    var requestTypes: ASCCredentialRequestTypes = [.platformPublicKeyAssertion, .securityKeyPublicKeyAssertion]

    let attachment = options.authenticatorAttachment.value
    if attachment == .Platform {
        requestTypes = .platformPublicKeyAssertion
    } else if attachment == .CrossPlatform {
        requestTypes = .securityKeyPublicKeyAssertion
    }

    let userVerification = options.userVerification.ascUserVerificationPreference

    var allowedCredentials: [ASCPublicKeyCredentialDescriptor]?
    if !options.allowCredentials.isEmpty() {
        var descriptors: [ASCPublicKeyCredentialDescriptor] = []
        for descriptor in options.allowCredentials {
            descriptors.append(toASCDescriptor(descriptor))
        }
        allowedCredentials = descriptors
    }

    let requestContext = ASCCredentialRequestContext(requestTypes: requestTypes)
    requestContext.relyingPartyIdentifier = makeSwiftString(options.rpId)
    if mediation == .Conditional {
        guard requestContext.responds(to: #selector(setter: ASCCredentialRequestContext.requestStyle)) else {
            return nil
        }
        requestContext.requestStyle = .autoFill
    }
    setGlobalFrameIDForContext(requestContext, globalFrameID)

    if requestTypes.contains(.platformPublicKeyAssertion) {
        guard
            let assertionOptions = configureAssertionOptions(
                options,
                .platform,
                parentOrigin,
                allowedCredentials,
                userVerification,
                callerOrigin
            )
        else {
            return nil
        }
        requestContext.platformKeyCredentialAssertionOptions = assertionOptions
    }

    if requestTypes.contains(.securityKeyPublicKeyAssertion) {
        guard
            let assertionOptions = configureAssertionOptions(
                options,
                .securityKey,
                parentOrigin,
                allowedCredentials,
                userVerification,
                callerOrigin
            )
        else {
            return nil
        }
        requestContext.securityKeyCredentialAssertionOptions = assertionOptions
    }

    return requestContext
}

// MARK: The legacy reply

private func toAuthenticatorTransports(_ ascTransports: [Swift.String]) -> fido.TransportVector {
    var transports = fido.TransportVector()
    for ascTransport in ascTransports {
        switch ascTransport {
        case "usb":
            transports.append(consuming: .Usb)
        case "nfc":
            transports.append(consuming: .Nfc)
        case "ble":
            transports.append(consuming: .Ble)
        case "internal":
            transports.append(consuming: .Internal)
        case "cable":
            transports.append(consuming: .Cable)
        case "hybrid":
            transports.append(consuming: .Hybrid)
        case "smartCard":
            transports.append(consuming: .SmartCard)
        default:
            break
        }
    }
    return transports
}

private func toExtensionOutputs(_ extensionOutputsCBOR: Data?) -> fido.OptionalClientOutputs {
    guard let extensionOutputsCBOR else {
        return fido.OptionalClientOutputs()
    }
    return WebCore.AuthenticationExtensionsClientOutputs.fromCBOR(makeByteVector([UInt8](extensionOutputsCBOR)))
}

// ASCAuthorizationErrorUserCanceled. The error domain's enum is not named, so the Swift does not reference the
// domain constant, which AuthenticationServicesCore (not linked) defines.
private let ascAuthorizationErrorUserCanceled = 2

// The reply to a legacy request: the credential's response, or the error's exception. Runs on the framework's
// queue; its reply holds only what it made.
private func legacyRequestReply(
    _ credential: (any ASCCredentialProtocol)?,
    _ error: (any Error)?
) -> sending WebAuthenticatorCoordinatorProxySwift.RequestReply {
    var response = WebCore.AuthenticatorResponseData()
    var exceptionData = WebCore.ExceptionData()
    var rawAttachment: Swift.String?

    if let registrationCredential = credential as? ASCPlatformPublicKeyCredentialRegistration {
        response.isAuthenticatorAttestationResponse = true

        response.rawId = webAuthnMakeArrayBufferPtr(registrationCredential.credentialID)
        response.attestationObject = webAuthnMakeArrayBufferPtr(registrationCredential.attestationObject)
        response.clientDataJSON = webAuthnMakeArrayBufferPtr(registrationCredential.rawClientDataJSON)
        rawAttachment = registrationCredential.attachment
        if registrationCredential.responds(to: #selector(getter: ASCPlatformPublicKeyCredentialRegistration.transports)) {
            response.transports = toAuthenticatorTransports(registrationCredential.transports)
        }
        if registrationCredential.responds(to: #selector(getter: ASCPlatformPublicKeyCredentialRegistration.extensionOutputsCBOR)) {
            response.extensionOutputs = toExtensionOutputs(registrationCredential.extensionOutputsCBOR)
        }
    } else if let registrationCredential = credential as? ASCSecurityKeyPublicKeyCredentialRegistration {
        response.isAuthenticatorAttestationResponse = true

        response.rawId = webAuthnMakeArrayBufferPtr(registrationCredential.credentialID)
        response.attestationObject = webAuthnMakeArrayBufferPtr(registrationCredential.attestationObject)
        response.clientDataJSON = webAuthnMakeArrayBufferPtr(registrationCredential.rawClientDataJSON)
        rawAttachment = registrationCredential.attachment
        if registrationCredential.responds(to: #selector(getter: ASCSecurityKeyPublicKeyCredentialRegistration.transports)) {
            response.transports = toAuthenticatorTransports(registrationCredential.transports)
        }
        if registrationCredential.responds(to: #selector(getter: ASCSecurityKeyPublicKeyCredentialRegistration.extensionOutputsCBOR)) {
            response.extensionOutputs = toExtensionOutputs(registrationCredential.extensionOutputsCBOR)
        }
    } else if let assertionCredential = credential as? ASCPlatformPublicKeyCredentialAssertion {
        response.isAuthenticatorAttestationResponse = false

        response.rawId = webAuthnMakeArrayBufferPtr(assertionCredential.credentialID)
        response.authenticatorData = webAuthnMakeArrayBufferPtr(assertionCredential.authenticatorData)
        response.signature = webAuthnMakeArrayBufferPtr(assertionCredential.signature)
        response.userHandle = webAuthnMakeArrayBufferPtrNilIfEmpty(assertionCredential.userHandle)
        response.clientDataJSON = webAuthnMakeArrayBufferPtr(assertionCredential.rawClientDataJSON)
        rawAttachment = assertionCredential.attachment
        if assertionCredential.responds(to: #selector(getter: ASCPlatformPublicKeyCredentialAssertion.extensionOutputsCBOR)) {
            response.extensionOutputs = toExtensionOutputs(assertionCredential.extensionOutputsCBOR)
        }
    } else if let assertionCredential = credential as? ASCSecurityKeyPublicKeyCredentialAssertion {
        response.isAuthenticatorAttestationResponse = false

        response.rawId = webAuthnMakeArrayBufferPtr(assertionCredential.credentialID)
        response.authenticatorData = webAuthnMakeArrayBufferPtr(assertionCredential.authenticatorData)
        response.signature = webAuthnMakeArrayBufferPtr(assertionCredential.signature)
        response.userHandle = webAuthnMakeArrayBufferPtrNilIfEmpty(assertionCredential.userHandle)
        response.clientDataJSON = webAuthnMakeArrayBufferPtr(assertionCredential.rawClientDataJSON)
        rawAttachment = assertionCredential.attachment
        if assertionCredential.responds(to: #selector(getter: ASCSecurityKeyPublicKeyCredentialAssertion.extensionOutputsCBOR)) {
            response.extensionOutputs = toExtensionOutputs(assertionCredential.extensionOutputsCBOR)
        }
    } else {
        let nsError = error.map { $0 as NSError }
        let exceptionCode: WebCore.ExceptionCode
        let errorMessage: WTF.String
        if let nsError, nsError.domain == WKErrorDomain {
            exceptionCode = webAuthnExceptionCode(forErrorCode: nsError.code)
            errorMessage = webAuthnLocalizedDescription(nsError)
        } else {
            exceptionCode = .NotAllowedError

            if let nsError, nsError.domain == WebKit.get_AuthenticationServicesCore_ASCAuthorizationErrorDomainSingleton() as Swift.String,
                nsError.code == ascAuthorizationErrorUserCanceled
            {
                errorMessage = makeWTFString("This request has been cancelled by the user.")
                WebKit.LogChannel.WebAuthn().releaseLog.error("Request cancelled after ASCAuthorizationErrorUserCanceled.")
            } else {
                errorMessage = makeWTFString("Operation failed.")
                WebKit.LogChannel.WebAuthn().releaseLog
                    .error("Request cancelled after error: \(nsError?.localizedDescription ?? "(null)").")
            }
        }

        exceptionData = WebCore.ExceptionData(code: exceptionCode, message: errorMessage)
    }

    let attachment: WebCore.AuthenticatorAttachment = rawAttachment == "platform" ? .Platform : .CrossPlatform
    return (response, attachment, exceptionData)
}
#endif // HAVE_UNIFIED_ASC_AUTH_UI

// Data has no initializer that takes a Span.
private func makeData(_ bytes: Span<UInt8>) -> Data {
    var data = Data(capacity: bytes.count)
    for index in bytes.indices {
        data.append(bytes[index])
    }
    return data
}

#endif // ENABLE_WEB_AUTHN
