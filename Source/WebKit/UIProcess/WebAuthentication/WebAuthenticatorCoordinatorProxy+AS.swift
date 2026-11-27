// Copyright (C) 2021 Apple Inc. All rights reserved.
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

// MARK: The request

extension WebAuthenticatorCoordinatorProxySwift {
    func isASCAvailable() -> Bool {
        #if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
        return WebKit.isAuthenticationServicesCoreAvailable()
        #else
        return false
        #endif
    }

    @MainActor
    func performRequest(_ data: WebKit.WebAuthenticationRequestData, _ completionHandler: any RequestCompletionHandler) async {
        #if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
        var requestData = data
        let relyingPartyIdentifier = WebKit.webAuthnRequestRelyingPartyIdentifier(requestData)
        let callerOrigin: WebCore.SecurityOriginData
        var fallbackOrigin: WebCore.SecurityOriginData?
        do {
            guard let webPageProxy = livePage else {
                completionHandler(Self.notAllowed())
                return
            }

            callerOrigin = requestData.callerOrigin()

            if !WebKit.webAuthnRequestIsCreation(requestData),
                let extensions = WebKit.webAuthnRequestRequestOptions(requestData).extensions.value,
                !extensions.crossDeviceFallbackURL.isNull()
            {
                if !webPageProxy.preferences().webAuthenticationCrossDeviceFallbackURLEnabled() {
                    WebKit.clearCrossDeviceFallbackURL(&requestData)
                } else {
                    let fallbackURL = fido.webAuthnURLFromString(extensions.crossDeviceFallbackURL)
                    if let error = WebCore.validateCrossDeviceFallbackURL(fallbackURL).value {
                        WebKit.LogChannel.WebAuthn().releaseLog.error("\(makeSwiftString(error), privacy: .public)")
                        completionHandler(Self.failure(.SecurityError, error))
                        return
                    }
                    fallbackOrigin = WebCore.SecurityOriginData.fromURL(fallbackURL)
                }
            }
        }

        var originsToValidate: [WebCore.SecurityOriginData] = []
        if !relyingPartyIdentifier.isEmpty()
            && !callerOrigin.securityOrigin().get().isMatchingRegistrableDomainSuffix(relyingPartyIdentifier)
        {
            originsToValidate.append(callerOrigin)
        }
        if let fallbackOrigin, !fallbackOrigin.securityOrigin().get().isMatchingRegistrableDomainSuffix(relyingPartyIdentifier) {
            originsToValidate.append(fallbackOrigin)
        }

        if originsToValidate.isEmpty {
            await performRequestWithValidatedRelyingPartyIdentifier(requestData, completionHandler)
            return
        }

        let isValidatingFallbackOrigin = fallbackOrigin != nil
        let result = await WebKit.RelatedOriginsValidation.validate({ self.livePage }, originsToValidate, relyingPartyIdentifier)
        guard let result else {
            completionHandler(Self.notAllowed())
            return
        }
        if !result.isRelated {
            let message =
                isValidatingFallbackOrigin
                ? "The origin of the document and the cross-device fallback URL must both be authorized for the provided RP ID."
                : "The origin of the document is not authorized for the provided RP ID."
            WebKit.LogChannel.WebAuthn().releaseLog.error("\(message, privacy: .public)")
            completionHandler(Self.failure(.SecurityError, makeWTFString(message)))
            return
        }

        guard livePage != nil else {
            completionHandler(Self.notAllowed())
            return
        }

        await performRequestWithValidatedRelyingPartyIdentifier(requestData, completionHandler)
        #else
        completionHandler(Self.failure(.NotSupportedError, makeWTFString("Not implemented.")))
        #endif
    }

    #if HAVE_UNIFIED_ASC_AUTH_UI || HAVE_WEB_AUTHN_AS_MODERN
    @MainActor
    private func performRequestWithValidatedRelyingPartyIdentifier(
        _ requestData: WebKit.WebAuthenticationRequestData,
        _ completionHandler: any RequestCompletionHandler
    ) async {
        #if HAVE_UNIFIED_ASC_AUTH_UI
        let usesLegacyRequest: Bool
        #endif
        #if HAVE_WEB_AUTHN_AS_MODERN
        let view: WKWebView?
        #endif
        do {
            guard let webPageProxy = livePage else {
                completionHandler(Self.notAllowed())
                return
            }
            if webPageProxy.configuration().backgroundTextExtractionEnabled() {
                completionHandler(Self.notAllowed())
                return
            }
            #if HAVE_UNIFIED_ASC_AUTH_UI
            usesLegacyRequest = !webPageProxy.preferences().webAuthenticationASEnabled()
            #endif
            #if HAVE_WEB_AUTHN_AS_MODERN
            view = WebKit.webAuthnCocoaView(webPageProxy).get()
            #endif
        }

        #if HAVE_UNIFIED_ASC_AUTH_UI
        if usesLegacyRequest {
            guard let context = contextForRequest(requestData) else {
                WebKit.LogChannel.WebAuthn().releaseLog.error("The origin of the document is not the same as its ancestors.")
                completionHandler(
                    Self.failure(.NotAllowedError, makeWTFString("The origin of the document is not the same as its ancestors."))
                )
                return
            }
            completionHandler(await performRequestLegacy(context))
            return
        }
        #endif

        #if HAVE_WEB_AUTHN_AS_MODERN
        isConditionalMediation = requestData.mediation.value == .Conditional
        guard let controller = constructASController(requestData) else {
            completionHandler(Self.notAllowed())
            return
        }
        if isConditionalMediation {
            Self.activeConditionalMediationProxy = self
        }
        let delegate = makeAuthorizationDelegate(view)
        authorization = (controller, delegate)
        let performsAutoFillAssistedRequests = requestData.mediation.value == .Conditional && !WebKit.webAuthnRequestIsCreation(requestData)

        // An earlier request's completion handler is let go of uncalled: that request is never answered.
        dropPendingRequest()
        pendingRequest = completionHandler

        controller.presentationContextProvider = delegate
        controller.delegate = delegate
        if performsAutoFillAssistedRequests {
            controller.performAutoFillAssistedRequests()
        } else {
            #if WTF_PLATFORM_VISION
            if let webPageProxy = livePage {
                webPageProxy.uiClient().willPresentModalUI(webPageProxy)
            }
            #endif
            controller.performRequests()
        }
        #else
        // Without the AuthenticationServices path, the request ends without a reply.
        completionHandler.dropWithoutReplying()
        #endif
    }
    #endif

    private static func notAllowed() -> RequestReply {
        failure(.NotAllowedError, fido.emptyWTFString())
    }
}

#if HAVE_WEB_AUTHN_AS_MODERN

// MARK: The authorization controller

extension WebAuthenticatorCoordinatorProxySwift {
    private func constructASController(_ requestData: borrowing WebKit.WebAuthenticationRequestData) -> ASAuthorizationController? {
        let callerOrigin = requestData.callerOrigin()
        let requests: [ASAuthorizationRequest]
        if WebKit.webAuthnRequestIsCreation(requestData) {
            requests = requestsForRegistration(WebKit.webAuthnRequestCreationOptions(requestData), callerOrigin)
        } else {
            requests = requestsForAssertion(WebKit.webAuthnRequestRequestOptions(requestData), callerOrigin, requestData.parentOrigin.value)
        }
        if requests.isEmpty {
            return nil
        }
        return ASAuthorizationController(authorizationRequests: requests)
    }

    private func requestsForRegistration(
        _ options: borrowing WebCore.PublicKeyCredentialCreationOptions,
        _ callerOrigin: borrowing WebCore.SecurityOriginData
    ) -> [ASAuthorizationRequest] {
        var requests: [ASAuthorizationRequest] = []
        var includePlatformRequest = true

        #if HAVE_SECURITY_KEY_API
        var includeSecurityKeyRequest = true
        switch options.authenticatorSelection.value?.authenticatorAttachment.value {
        case .Platform?:
            includeSecurityKeyRequest = false
        case .CrossPlatform?:
            includePlatformRequest = false
        default:
            break
        }
        #endif

        var platformExcludedCredentials: [ASAuthorizationPlatformPublicKeyCredentialDescriptor] = []
        var crossPlatformExcludedCredentials: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor] = []
        for credential in options.excludeCredentials {
            let hasInternal = hasTransport(credential.transports) { $0 == .Internal }
            if hasInternal || credential.transports.isEmpty() {
                platformExcludedCredentials.append(ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: data(credential.id)))
            }
            if credential.transports.isEmpty() || !hasInternal {
                crossPlatformExcludedCredentials.append(securityKeyDescriptor(credential))
            }
        }

        let clientData = ASPublicKeyCredentialClientData(
            challenge: data(options.challenge),
            origin: makeSwiftString(callerOrigin.toString())
        )
        let relyingPartyIdentifier = makeSwiftString(options.rp.id)
        let extensions = options.extensions.value
        let authenticatorSelection = options.authenticatorSelection.value
        if includePlatformRequest {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
            let request = provider.createCredentialRegistrationRequest(
                with: clientData,
                name: makeSwiftString(options.user.name),
                userID: data(options.user.id)
            )

            if isConditionalMediation
                && request.responds(to: #selector(setter: ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest.requestStyle))
            {
                request.requestStyle = .conditional
            }
            #if HAVE_WEB_AUTHN_PRF_API
            if let prf = extensions?.prf.value {
                request.prf = registrationPRFInput(prf)
            }
            #endif

            // Platform credentials may only support enterprise attestation.
            if options.attestation == .Enterprise {
                request.attestationPreference = options.attestation.asAttestationPreference as String
            }
            if let authenticatorSelection {
                request.userVerificationPreference = authenticatorSelection.userVerification.asUserVerificationPreference as String
            }
            if let largeBlob = extensions?.largeBlob.value {
                // These are satisfied by validation in AuthenticatorCoordinator.
                assert(largeBlob.read.value == nil && largeBlob.write.value == nil)
                request.largeBlob = ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput(
                    supportRequirement: largeBlobSupportRequirement(largeBlob.support)
                )
            }
            request.excludedCredentials = platformExcludedCredentials
            requests.append(request)
        }
        #if HAVE_SECURITY_KEY_API
        if includeSecurityKeyRequest {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
            let request: ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest
            let createsWithClientData = provider.responds(
                to: #selector(
                    ASAuthorizationSecurityKeyPublicKeyCredentialProvider.createCredentialRegistrationRequest(
                        with:
                        displayName:
                        name:
                        userID:
                    )
                )
            )
            if createsWithClientData {
                request = provider.createCredentialRegistrationRequest(
                    with: clientData,
                    displayName: makeSwiftString(options.user.displayName),
                    name: makeSwiftString(options.user.name),
                    userID: data(options.user.id)
                )
            } else {
                request = provider.createCredentialRegistrationRequest(
                    challenge: data(options.challenge),
                    displayName: makeSwiftString(options.user.displayName),
                    name: makeSwiftString(options.user.name),
                    userID: data(options.user.id)
                )
            }
            #if HAVE_WEB_AUTHN_PRF_API
            if let prf = extensions?.prf.value,
                request.responds(to: #selector(setter: ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest.prf))
            {
                request.prf = registrationPRFInput(prf)
            }
            #endif
            request.attestationPreference = options.attestation.asAttestationPreference as String
            var parameters: [ASAuthorizationPublicKeyCredentialParameters] = []
            for parameter in options.pubKeyCredParams {
                parameters.append(
                    ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: Int(parameter.alg)))
                )
            }
            request.credentialParameters = parameters
            if let authenticatorSelection {
                request.userVerificationPreference = authenticatorSelection.userVerification.asUserVerificationPreference as String
                request.residentKeyPreference =
                    residentKeyPreference(authenticatorSelection.residentKey.value, authenticatorSelection.requireResidentKey) as String
            }
            request.excludedCredentials = crossPlatformExcludedCredentials
            requests.append(request)
        }
        #endif

        return requests
    }

    private func requestsForAssertion(
        _ options: borrowing WebCore.PublicKeyCredentialRequestOptions,
        _ callerOrigin: borrowing WebCore.SecurityOriginData,
        _ parentOrigin: WebCore.SecurityOriginData?
    ) -> [ASAuthorizationRequest] {
        var requests: [ASAuthorizationRequest] = []
        var platformAllowedCredentials: [ASAuthorizationPlatformPublicKeyCredentialDescriptor] = []
        var crossPlatformAllowedCredentials: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor] = []
        var allowHybrid = options.allowCredentials.isEmpty()
        for credential in options.allowCredentials {
            if isPlatformRequest(credential.transports) {
                platformAllowedCredentials.append(ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: data(credential.id)))
            }
            if isCrossPlatformRequest(credential.transports) {
                crossPlatformAllowedCredentials.append(securityKeyDescriptor(credential))
            }

            if !allowHybrid && allowsHybrid(credential.transports) {
                allowHybrid = true
            }
        }
        let clientData = ASPublicKeyCredentialClientData(
            challenge: data(options.challenge),
            origin: makeSwiftString(callerOrigin.toString())
        )
        if let parentOrigin {
            clientData.crossOrigin = .crossOrigin
            clientData.topOrigin = makeSwiftString(parentOrigin.toString())
        }
        let relyingPartyIdentifier = makeSwiftString(options.rpId)
        let extensions = options.extensions.value
        if !platformAllowedCredentials.isEmpty || crossPlatformAllowedCredentials.isEmpty {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
            let request = provider.createCredentialAssertionRequest(with: clientData)
            request.allowedCredentials = platformAllowedCredentials
            if let largeBlob = extensions?.largeBlob.value {
                // These are satisfied by validation in AuthenticatorCoordinator.
                assert(largeBlob.support.isNull())
                assert(!(largeBlob.read.value != nil && largeBlob.write.value != nil))
                let assertionInput = ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput(
                    operation: largeBlob.read.value == true ? .read : .write
                )
                if let write = largeBlob.write.value {
                    assertionInput.dataToWrite = data(write)
                }
                request.largeBlob = assertionInput
            }

            request.userVerificationPreference = options.userVerification.asUserVerificationPreference as String

            if !allowHybrid {
                request.shouldShowHybridTransport = false
            }

            #if HAVE_WEB_AUTHN_PRF_API
            if let prf = extensions?.prf.value {
                request.prf = assertionPRFInput(prf)
            }
            #endif

            requests.append(request)
        }

        #if HAVE_SECURITY_KEY_API
        if !isConditionalMediation && (!crossPlatformAllowedCredentials.isEmpty || platformAllowedCredentials.isEmpty) {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
            let request: ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest
            if provider.responds(
                to: #selector(ASAuthorizationSecurityKeyPublicKeyCredentialProvider.createCredentialAssertionRequest(with:))
            ) {
                request = provider.createCredentialAssertionRequest(with: clientData)
            } else {
                request = provider.createCredentialAssertionRequest(challenge: data(options.challenge))
            }
            request.allowedCredentials = crossPlatformAllowedCredentials
            if let extensions, !extensions.appid.isNull() {
                request.appID = makeSwiftString(extensions.appid)
            }
            #if HAVE_WEB_AUTHN_PRF_API
            if let prf = extensions?.prf.value,
                request.responds(to: #selector(setter: ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest.prf))
            {
                request.prf = assertionPRFInput(prf)
            }
            #endif
            requests.append(request)
        }
        #endif

        return requests
    }
}

// MARK: The authorization's completion

extension WebAuthenticatorCoordinatorProxySwift {
    // AuthenticationServices calls the delegate on a queue of its choosing. The delegate's closure captures only a
    // main-actor weak reference to the receiver; the C++ helper carries the framework's objects to the main run loop
    // and calls the main-actor completion with them.
    @MainActor
    private func makeAuthorizationDelegate(_ view: WKWebView?) -> WKASDelegate {
        let target = AuthorizationTarget(self)
        return WKASDelegate(view: view) { @Sendable authorization, error in
            WebKit.WebAuthnAuthorizationCompletion.onMainRunLoop(authorization, error) { authorization, error in
                target.receiver?.completeAuthorization(authorization, error)
            }
        }
    }

    // On the main actor, where the authorization's reply is made and sent: the authorization is not Sendable.
    @MainActor
    private func completeAuthorization(_ authorization: ASAuthorization?, _ error: NSError?) {
        guard livePage != nil else {
            return
        }
        if let active = Self.activeConditionalMediationProxy, active === self {
            Self.activeConditionalMediationProxy = nil
        }
        if !isPaused {
            if let completionHandler = pendingRequest.take() {
                completionHandler(authorizationReply(authorization, error))
            }
            self.authorization = nil
            isConditionalMediation = false
        }
        pendingCancel.take()?()
    }
}

// The C++ helper's private members are reachable only from its extensions in this file.
extension WebKit.WebAuthnAuthorizationCompletion {
    fileprivate static func onMainRunLoop(
        _ authorization: ASAuthorization?,
        _ error: NSError?,
        _ completion: @escaping @MainActor (ASAuthorization?, NSError?) -> Void
    ) {
        // The block's NSError reaches Swift as `any Error`.
        ensureOnMainRunLoop(authorization, error) { authorization, error in
            completion(authorization, error as NSError?)
        }
    }
}

// The receiver as the authorization delegate's closure holds it: main-actor isolated, so Sendable.
@MainActor
private final class AuthorizationTarget {
    weak var receiver: WebAuthenticatorCoordinatorProxySwift?

    init(_ receiver: WebAuthenticatorCoordinatorProxySwift) {
        self.receiver = receiver
    }
}

// ASAuthorizationError's codes, as numbers: Swift's ASAuthorizationError would refer to the error domain's symbol, which
// only the soft link provides.
private enum AuthorizationErrorCode: Int {
    case unknown = 1000
    case canceled = 1001
    case invalidResponse = 1002
    case notHandled = 1003
    case failed = 1004
    case notInteractive = 1005
    case matchedExcludedCredential = 1006
    #if HAVE_CROSS_DEVICE_FALLBACK_URL_API
    case crossDeviceFallback = 1011
    #endif
}

private let ascAuthorizationErrorSecurityError = 17

private func authorizationReply(_ authorization: ASAuthorization?, _ error: NSError?) -> WebAuthenticatorCoordinatorProxySwift.RequestReply
{
    var response = WebCore.AuthenticatorResponseData()
    var exceptionData = WebCore.ExceptionData(code: .NotAllowedError, message: fido.emptyWTFString())
    var attachment = WebCore.AuthenticatorAttachment.Platform
    if let error, error.domain == WKErrorDomain {
        exceptionData = WebCore.ExceptionData(
            code: webAuthnExceptionCode(forErrorCode: error.code),
            message: webAuthnLocalizedDescription(error)
        )
    } else if let error, error.domain == WebKit.get_AuthenticationServices_ASAuthorizationErrorDomainSingleton() {
        switch AuthorizationErrorCode(rawValue: error.code) {
        case .failed?:
            let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError
            if let underlyingError,
                underlyingError.domain == WebKit.get_AuthenticationServicesCore_ASCAuthorizationErrorDomainSingleton(),
                underlyingError.code == ascAuthorizationErrorSecurityError
            {
                let reason = (underlyingError.userInfo[NSLocalizedFailureReasonErrorKey] as? String).map(makeWTFString) ?? WTF.String()
                exceptionData = WebCore.ExceptionData(code: .SecurityError, message: reason)
            } else if let underlyingError, underlyingError.domain == WKErrorDomain {
                exceptionData = WebCore.ExceptionData(
                    code: webAuthnExceptionCode(forErrorCode: underlyingError.code),
                    message: webAuthnLocalizedDescription(underlyingError)
                )
            }
        case .matchedExcludedCredential?:
            exceptionData = WebCore.ExceptionData(code: .InvalidStateError, message: fido.emptyWTFString())
        #if HAVE_CROSS_DEVICE_FALLBACK_URL_API
        case .crossDeviceFallback?:
            response.operationError = .CrossDeviceFallback
            exceptionData = WebCore.ExceptionData(code: .NotAllowedError, message: fido.emptyWTFString())
        #endif
        case .canceled?:
            exceptionData = WebCore.ExceptionData(code: .NotAllowedError, message: fido.emptyWTFString())
        case .unknown?, .invalidResponse?, .notHandled?, .notInteractive?:
            assertionFailure("An authorization error AuthenticationServices does not report to WebKit")
        case nil:
            break
        }
    } else if authorization?.credential is ASAuthorizationPlatformPublicKeyCredentialRegistration,
        let credential = authorization?.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration
    {
        attachment = setResponse(&response, credential)
    } else if authorization?.credential is ASAuthorizationPlatformPublicKeyCredentialAssertion,
        let credential = authorization?.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
    {
        attachment = setResponse(&response, credential)
    } else if authorization?.credential is ASAuthorizationSecurityKeyPublicKeyCredentialRegistration,
        let credential = authorization?.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
    {
        setResponse(&response, credential)
        attachment = .CrossPlatform
    } else if authorization?.credential is ASAuthorizationSecurityKeyPublicKeyCredentialAssertion,
        let credential = authorization?.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
    {
        setResponse(&response, credential)
        attachment = .CrossPlatform
    }
    return (response, attachment, exceptionData)
}

// What the two registration credentials share.
private func setRegistrationFields(
    _ response: inout WebCore.AuthenticatorResponseData,
    _ credential: any ASAuthorizationPublicKeyCredentialRegistration
) {
    response.isAuthenticatorAttestationResponse = true
    response.rawId = webAuthnMakeArrayBufferPtr(credential.credentialID)
    response.attestationObject = webAuthnMakeArrayBufferPtr(credential.rawAttestationObject ?? Data())
}

// What the two assertion credentials share.
private func setAssertionFields(
    _ response: inout WebCore.AuthenticatorResponseData,
    _ credential: any ASAuthorizationPublicKeyCredentialAssertion
) {
    response.rawId = webAuthnMakeArrayBufferPtr(credential.credentialID)
    response.authenticatorData = webAuthnMakeArrayBufferPtr(credential.rawAuthenticatorData)
    response.signature = webAuthnMakeArrayBufferPtr(credential.signature)
    response.userHandle = webAuthnMakeArrayBufferPtrNilIfEmpty(credential.userID)
    response.clientDataJSON = webAuthnMakeArrayBufferPtr(credential.rawClientDataJSON)
}

private func setResponse(
    _ response: inout WebCore.AuthenticatorResponseData,
    _ credential: ASAuthorizationPlatformPublicKeyCredentialRegistration
) -> WebCore.AuthenticatorAttachment {
    setRegistrationFields(&response, credential)
    var transports = fido.TransportVector()
    transports.append(consuming: .Internal)
    transports.append(consuming: .Hybrid)
    response.transports = transports
    response.clientDataJSON = webAuthnMakeArrayBufferPtr(credential.rawClientDataJSON)

    let attachment = credential.attachment.authenticatorAttachment

    var hasExtensionOutput = false
    var extensionOutputs = fido.WebAuthnClientOutputsBuilder()
    if credential.__largeBlob != nil {
        hasExtensionOutput = true
        extensionOutputs.beginLargeBlob()
        extensionOutputs.setLargeBlobSupported(credential.__largeBlob?.isSupported ?? false)
    }

    #if HAVE_WEB_AUTHN_PRF_API
    if credential.responds(to: #selector(getter: ASAuthorizationPlatformPublicKeyCredentialRegistration.prf)), credential.prf != nil {
        hasExtensionOutput = true
        setPRFOutputs(&extensionOutputs) { credential.prf }
    }
    #endif

    if hasExtensionOutput {
        response.extensionOutputs = extensionOutputs.take()
    }
    return attachment
}

private func setResponse(
    _ response: inout WebCore.AuthenticatorResponseData,
    _ credential: ASAuthorizationPlatformPublicKeyCredentialAssertion
) -> WebCore.AuthenticatorAttachment {
    setAssertionFields(&response, credential)

    let attachment = credential.attachment.authenticatorAttachment

    var hasExtensionOutput = false
    var extensionOutputs = fido.WebAuthnClientOutputsBuilder()
    if credential.__largeBlob != nil {
        hasExtensionOutput = true
        extensionOutputs.beginLargeBlob()
        if credential.__largeBlob?.readData != nil, let readData = credential.__largeBlob?.readData {
            extensionOutputs.setLargeBlobBlob(makeByteVector([UInt8](readData)))
        }
        extensionOutputs.setLargeBlobWritten(credential.__largeBlob?.didWrite ?? false)
    }

    #if HAVE_WEB_AUTHN_PRF_API
    if credential.responds(to: #selector(getter: ASAuthorizationPlatformPublicKeyCredentialAssertion.prf)), credential.prf != nil {
        hasExtensionOutput = true
        setPRFOutputs(&extensionOutputs) { credential.prf }
    }
    #endif

    if hasExtensionOutput {
        response.extensionOutputs = extensionOutputs.take()
    }
    return attachment
}

private func setResponse(
    _ response: inout WebCore.AuthenticatorResponseData,
    _ credential: ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
) {
    setRegistrationFields(&response, credential)

    #if HAVE_WEB_AUTHN_PRF_API
    if credential.responds(to: #selector(getter: ASAuthorizationSecurityKeyPublicKeyCredentialRegistration.prf)), credential.prf != nil {
        var extensionOutputs = fido.WebAuthnClientOutputsBuilder()
        setPRFOutputs(&extensionOutputs) { credential.prf }
        response.extensionOutputs = extensionOutputs.take()
    }
    #endif

    if credential.responds(to: #selector(getter: ASAuthorizationSecurityKeyPublicKeyCredentialRegistration.transports)) {
        response.transports = toTransports(credential.transports)
    } else {
        response.transports = fido.TransportVector()
    }
    response.clientDataJSON = webAuthnMakeArrayBufferPtr(credential.rawClientDataJSON)
}

private func setResponse(
    _ response: inout WebCore.AuthenticatorResponseData,
    _ credential: ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
) {
    setAssertionFields(&response, credential)

    var hasExtensionOutput = false
    var extensionOutputs = fido.WebAuthnClientOutputsBuilder()

    #if HAVE_WEB_AUTHN_PRF_API
    if credential.responds(to: #selector(getter: ASAuthorizationSecurityKeyPublicKeyCredentialAssertion.prf)), credential.prf != nil {
        hasExtensionOutput = true
        setPRFOutputs(&extensionOutputs) { credential.prf }
    }
    #endif

    if credential.responds(to: #selector(getter: ASAuthorizationSecurityKeyPublicKeyCredentialAssertion.appID)) {
        hasExtensionOutput = true
        extensionOutputs.setAppid(credential.appID)
    }
    if hasExtensionOutput {
        response.extensionOutputs = extensionOutputs.take()
    }
}

#if HAVE_WEB_AUTHN_PRF_API
private func setPRFOutputs(
    _ extensionOutputs: inout fido.WebAuthnClientOutputsBuilder,
    _ prf: () -> ASAuthorizationPublicKeyCredentialPRFRegistrationOutput?
) {
    var first = fido.ArrayBufferPtr()
    if prf()?.first != nil, let data = prf()?.first {
        first = webAuthnMakeArrayBufferPtr(data)
    }
    var second = fido.ArrayBufferPtr()
    if prf()?.second != nil, let data = prf()?.second {
        second = webAuthnMakeArrayBufferPtr(data)
    }
    let isSupported = prf()?.isSupported ?? false
    WebKit.setPRFRegistrationOutputs(&extensionOutputs.outputs, isSupported, first, second)
}

private func setPRFOutputs(
    _ extensionOutputs: inout fido.WebAuthnClientOutputsBuilder,
    _ prf: () -> ASAuthorizationPublicKeyCredentialPRFAssertionOutput?
) {
    let firstData = prf()?.first ?? Data()
    let first = webAuthnMakeArrayBuffer(firstData.span)
    var second = fido.ArrayBufferPtr()
    if prf()?.second != nil, let data = prf()?.second {
        second = webAuthnMakeArrayBufferPtr(data)
    }
    WebKit.setPRFAssertionOutputs(&extensionOutputs.outputs, first, second)
}
#endif

// MARK: The delegate

// The controller's presentation context provider and delegate. AuthenticationServices may call it on any thread.
@objc(_WKASDelegate)
nonisolated final class WKASDelegate: NSObject, ASAuthorizationControllerPresentationContextProviding,
    ASAuthorizationControllerDelegate
{
    private let view: WKWebView?
    private let completionHandler: (ASAuthorization?, NSError?) -> Void

    init(view: WKWebView?, completionHandler: @escaping (ASAuthorization?, NSError?) -> Void) {
        self.view = view
        self.completionHandler = completionHandler
        super.init()
    }

    @objc(presentationAnchorForAuthorizationController:)
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor! {
        WebKit.webAuthnPresentationAnchor(view).get()
    }

    @objc(authorizationController:didCompleteWithAuthorization:)
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        completionHandler(authorization, nil)
    }

    @objc(authorizationController:didCompleteWithError:)
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        completionHandler(nil, error as NSError)
    }
}

// MARK: Converters

private func data(_ source: borrowing WebCore.BufferSource) -> Data {
    Data(bufferSourceBytes(source))
}

private func hasTransport(
    _ transports: fido.TransportVector,
    _ predicate: (WebCore.AuthenticatorTransport) -> Bool
) -> Bool {
    for transport in transports where predicate(transport) {
        return true
    }
    return false
}

private func isPlatformRequest(_ transports: fido.TransportVector) -> Bool {
    transports.isEmpty() || hasTransport(transports) { $0 == .Internal || $0 == .Hybrid }
}

private func isCrossPlatformRequest(_ transports: fido.TransportVector) -> Bool {
    transports.isEmpty() || hasTransport(transports) { $0 != .Internal && $0 != .Hybrid }
}

private func allowsHybrid(_ transports: fido.TransportVector) -> Bool {
    transports.isEmpty() || hasTransport(transports) { $0 == .Hybrid || $0 == .Cable }
}

private func securityKeyDescriptor(
    _ credential: borrowing WebCore.PublicKeyCredentialDescriptor
) -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor {
    var transports: [String] = []
    for transport in credential.transports {
        if let securityKeyTransport = transport.asSecurityKeyTransport {
            transports.append(securityKeyTransport as String)
        }
    }
    return ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: data(credential.id), transports: transports)
}

private func largeBlobSupportRequirement(
    _ requirement: borrowing WTF.String
) -> ASAuthorizationPublicKeyCredentialLargeBlobSupportRequirement {
    makeSwiftString(requirement) == "required" ? .required : .preferred
}

#if HAVE_SECURITY_KEY_API
private func residentKeyPreference(
    _ requirement: WebCore.ResidentKeyRequirement?,
    _ requireResidentKey: Bool
) -> ASAuthorizationPublicKeyCredentialResidentKeyPreference {
    guard let requirement else {
        return requireResidentKey ? "required" : "discouraged"
    }
    switch requirement {
    case .Discouraged:
        return "discouraged"
    case .Preferred:
        return "preferred"
    case .Required:
        return "required"
    @unknown default:
        assertionFailure("An unknown resident key requirement")
        return "preferred"
    }
}
#endif

#if HAVE_WEB_AUTHN_PRF_API
private func assertionInputValues(
    _ values: borrowing WebCore.AuthenticationExtensionsClientInputs.PRFValues
) -> ASAuthorizationPublicKeyCredentialPRFAssertionInputValues {
    ASAuthorizationPublicKeyCredentialPRFAssertionInputValues(
        saltInput1: data(values.first),
        saltInput2: values.second.value.map { data($0) }
    )
}

private func registrationPRFInput(
    _ prf: borrowing WebCore.AuthenticationExtensionsClientInputs.PRFInputs
) -> ASAuthorizationPublicKeyCredentialPRFRegistrationInput {
    guard let eval = prf.eval.value else {
        return ASAuthorizationPublicKeyCredentialPRFRegistrationInput.checkForSupport()
    }
    return ASAuthorizationPublicKeyCredentialPRFRegistrationInput(inputValues: assertionInputValues(eval))
}

private func assertionPRFInput(
    _ prf: borrowing WebCore.AuthenticationExtensionsClientInputs.PRFInputs
) -> ASAuthorizationPublicKeyCredentialPRFAssertionInput {
    let inputValues = prf.eval.value.map { assertionInputValues($0) }
    var perCredentialInputValues: [Data: ASAuthorizationPublicKeyCredentialPRFAssertionInputValues]?
    if let evalByCredential = prf.evalByCredential.value {
        var valuesByCredential: [Data: ASAuthorizationPublicKeyCredentialPRFAssertionInputValues] = [:]
        for credentialIDAndInputValues in evalByCredential {
            guard let key = fido.base64URLDecodeString(credentialIDAndInputValues.key).value else {
                continue
            }
            valuesByCredential[Data(key)] = assertionInputValues(credentialIDAndInputValues.value)
        }
        perCredentialInputValues = valuesByCredential
    }
    return ASAuthorizationPublicKeyCredentialPRFAssertionInput(inputValues: inputValues, perCredentialInputValues: perCredentialInputValues)
}
#endif

private func toTransports(_ asTransports: [String]) -> fido.TransportVector {
    var transports = fido.TransportVector()
    for asTransport in asTransports {
        if let transport = WebCore.convertStringToAuthenticatorTransport(makeWTFString(asTransport)).value {
            transports.append(consuming: transport)
        }
    }
    return transports
}

extension WebCore.UserVerificationRequirement {
    fileprivate var asUserVerificationPreference: ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch self {
        case .Preferred:
            return "preferred"
        case .Discouraged:
            return "discouraged"
        case .Required:
            return "required"
        @unknown default:
            return "required"
        }
    }
}

extension WebCore.AttestationConveyancePreference {
    fileprivate var asAttestationPreference: ASAuthorizationPublicKeyCredentialAttestationKind {
        switch self {
        case .Direct:
            return "direct"
        case .Indirect:
            return "indirect"
        case .None:
            return "none"
        case .Enterprise:
            return "enterprise"
        @unknown default:
            return "none"
        }
    }
}

extension WebCore.AuthenticatorTransport {
    fileprivate var asSecurityKeyTransport: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransport? {
        switch self {
        case .Ble:
            return "ble"
        case .Nfc:
            return "nfc"
        case .Usb:
            return "usb"
        default:
            return nil
        }
    }
}

extension ASAuthorizationPublicKeyCredentialAttachment {
    fileprivate var authenticatorAttachment: WebCore.AuthenticatorAttachment {
        self == .platform ? .Platform : .CrossPlatform
    }
}

#endif // HAVE_WEB_AUTHN_AS_MODERN

#endif // ENABLE_WEB_AUTHN
