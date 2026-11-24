// Copyright (C) 2019-2021 Apple Inc. All rights reserved.
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

import CryptoKit
import Foundation
import Security
internal import WebCore
import WebCore_Private
import WebKit_Internal
import WebKit_Private
// The WebAuthn option classes are explicit submodules of WebKit_Private, which `import WebKit_Private` does not import.
import WebKit_Private._WKAuthenticationExtensionsClientOutputs
import WebKit_Private._WKAuthenticatorAssertionResponse
import WebKit_Private._WKAuthenticatorAttachment
import WebKit_Private._WKAuthenticatorAttestationResponse
import WebKit_Private._WKPublicKeyCredentialCreationOptions
import WebKit_Private._WKPublicKeyCredentialParameters
import WebKit_Private._WKPublicKeyCredentialRequestOptions
import WebKit_Private._WKWebAuthenticationPanelForTesting
import wtf

// The bodies of _WKWebAuthenticationPanel's members, which stays an Objective-C++ class: its API object lives in an
// ivar of the class extension, which an @implementation of the whole class cannot emit. Each Objective-C++ method
// forwards to its namesake here, and the C++ helpers are in _WKWebAuthenticationPanelInternal.h.

@objc(WKSwiftMembers)
@implementation
extension _WKWebAuthenticationPanel {
    @objc(makeTransports)
    func makeTransports() -> NSMutableSet {
        let transports = WebKit.webAuthenticationPanelTransports(self)
        let result = NSMutableSet(capacity: transports.size())
        for index in 0..<transports.size() {
            result.add(NSNumber(value: Int32(wkWebAuthenticationTransport(transports[index]).rawValue)))
        }
        return result
    }

    @objc(webAuthenticationType)
    func webAuthenticationType() -> _WKWebAuthenticationType {
        switch WebKit.webAuthenticationPanel(self).clientDataType() {
        case .Create:
            return .create
        case .Get:
            return .get
        @unknown default:
            assertionFailure()
            return .create
        }
    }

    @objc(performMakeCredentialWithChallenge:origin:options:completionHandler:)
    func performMakeCredential(
        withChallenge challenge: Data?,
        origin: String?,
        options: _WKPublicKeyCredentialCreationOptions?,
        completionHandler handler: @escaping (_WKAuthenticatorAttestationResponse?, (any Error)?) -> Void
    ) {
        let clientDataJSON = produceClientDataJSON(.create, challenge, origin, nil, .SameOrigin)
        let hash = produceClientDataJSONHash(clientDataJSON)
        let callback = WebKit.makeAuthenticatorManagerCallback(
            consuming: .init { response in
                if let exception = responseException(response) {
                    handler(nil, exception)
                    return
                }
                handler(attestationResponse(response, clientDataJSON), nil)
            }
        )
        WebKit.webAuthenticationPanelHandleRequest(
            WebKit.webAuthenticationPanel(self),
            hash,
            _WKWebAuthenticationPanel.convertToCoreCreationOptions(with: options),
            nil,
            consuming: callback
        )
    }

    @objc(performMakeCredentialWithMediationRequirement:clientDataHash:options:completionHandler:)
    func performMakeCredential(
        with mediation: _WKWebAuthenticationMediationRequirement,
        clientDataHash: Data?,
        options: _WKPublicKeyCredentialCreationOptions?,
        completionHandler handler: @escaping (_WKAuthenticatorAttestationResponse?, (any Error)?) -> Void
    ) {
        let callback = WebKit.makeAuthenticatorManagerCallback(
            consuming: .init { response in
                if let exception = responseException(response) {
                    handler(nil, exception)
                    return
                }
                handler(attestationResponse(response, nil), nil)
            }
        )
        WebKit.webAuthenticationPanelHandleRequest(
            WebKit.webAuthenticationPanel(self),
            byteVector(clientDataHash),
            _WKWebAuthenticationPanel.convertToCoreCreationOptions(with: options),
            .init(toWebCore(mediation)),
            consuming: callback
        )
    }

    @objc(performGetAssertionWithChallenge:origin:options:completionHandler:)
    func performGetAssertion(
        withChallenge challenge: Data?,
        origin: String?,
        options: _WKPublicKeyCredentialRequestOptions?,
        completionHandler handler: @escaping (_WKAuthenticatorAssertionResponse?, (any Error)?) -> Void
    ) {
        let clientDataJSON = produceClientDataJSON(.get, challenge, origin, nil, .SameOrigin)
        let hash = produceClientDataJSONHash(clientDataJSON)
        let callback = WebKit.makeAuthenticatorManagerCallback(
            consuming: .init { response in
                if let exception = responseException(response) {
                    handler(nil, exception)
                    return
                }
                handler(assertionResponse(response, clientDataJSON), nil)
            }
        )
        WebKit.webAuthenticationPanelHandleRequest(
            WebKit.webAuthenticationPanel(self),
            hash,
            _WKWebAuthenticationPanel.convertToCoreRequestOptions(with: options),
            nil,
            consuming: callback
        )
    }

    @objc(performGetAssertionWithMediationRequirement:clientDataHash:options:completionHandler:)
    func performGetAssertion(
        with mediation: _WKWebAuthenticationMediationRequirement,
        clientDataHash: Data?,
        options: _WKPublicKeyCredentialRequestOptions?,
        completionHandler handler: @escaping (_WKAuthenticatorAssertionResponse?, (any Error)?) -> Void
    ) {
        let callback = WebKit.makeAuthenticatorManagerCallback(
            consuming: .init { response in
                if let exception = responseException(response) {
                    handler(nil, exception)
                    return
                }
                handler(assertionResponse(response, nil), nil)
            }
        )
        WebKit.webAuthenticationPanelHandleRequest(
            WebKit.webAuthenticationPanel(self),
            byteVector(clientDataHash),
            _WKWebAuthenticationPanel.convertToCoreRequestOptions(with: options),
            .init(toWebCore(mediation)),
            consuming: callback
        )
    }

    @objc(performDeleteLocalAuthenticatorCredentialWithGroupAndID:credential:)
    class func performDeleteLocalAuthenticatorCredential(withGroupAndID group: String?, credential credentialID: Data?) {
        // -[NSMutableDictionary setObject:forKey:] raises on a nil object.
        guard let credentialID else {
            preconditionFailure("A nil credential ID")
        }
        let useAlternateKeychainAttribute = webAuthnShouldUseAlternateKeychainAttribute()
        let deleteQuery = NSMutableDictionary()
        deleteQuery.setDictionary([
            kSecClass: kSecClassKey,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ])
        updateQueryForGroupIfNecessary(deleteQuery, group)

        deleteQuery[useAlternateKeychainAttribute ? aliasAttribute : kSecAttrApplicationLabel] = credentialID
        SecItemDelete(deleteQuery as CFDictionary)

        if useAlternateKeychainAttribute {
            deleteQuery.removeObject(forKey: aliasAttribute)
            deleteQuery[kSecAttrApplicationLabel] = credentialID
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    @objc(performGetClientDataJSONWithTopOrigin:challenge:origin:topOrigin:crossOrigin:)
    class func performGetClientDataJSON(
        withTopOrigin type: _WKWebAuthenticationType,
        challenge: Data?,
        origin: String?,
        topOrigin: String?,
        crossOrigin: Bool
    ) -> Data {
        produceClientDataJSON(type, challenge, origin, topOrigin, crossOrigin ? .CrossOrigin : .SameOrigin)
    }

    @objc(performEncodeMakeCredentialCommandWithClientDataJSON:options:userVerificationAvailability:authenticatorSupportedExtensions:)
    class func performEncodeMakeCredentialCommand(
        withClientDataJSON clientDataJSON: Data?,
        options: _WKPublicKeyCredentialCreationOptions?,
        userVerificationAvailability: _WKWebAuthenticationUserVerificationAvailability,
        authenticatorSupportedExtensions: [String]?
    ) -> Data {
        let hash = produceClientDataJSONHash(clientDataJSON)
        let coreOptions = _WKWebAuthenticationPanel.convertToCoreCreationOptions(with: options)
        var effectiveUVRequirement = coreOptions.authenticatorSelection.value?.userVerification ?? .Preferred
        if needsPRF(coreOptions.extensions) && supportsHmacSecret(authenticatorSupportedExtensions) {
            effectiveUVRequirement = .Required
        }
        return Data(
            fido.encodeMakeCredentialRequestAsCBOR(
                hash,
                coreOptions,
                coreUserVerificationAvailability(userVerificationAvailability),
                effectiveUVRequirement,
                .supported,
                stringVector(authenticatorSupportedExtensions),
                nil,
                nil,
                nil,
                nil
            )
        )
    }

    @objc(performEncodeGetAssertionCommandWithClientDataJSON:options:userVerificationAvailability:authenticatorSupportedExtensions:)
    class func performEncodeGetAssertionCommand(
        withClientDataJSON clientDataJSON: Data?,
        options: _WKPublicKeyCredentialRequestOptions?,
        userVerificationAvailability: _WKWebAuthenticationUserVerificationAvailability,
        authenticatorSupportedExtensions: [String]?
    ) -> Data {
        let hash = produceClientDataJSONHash(clientDataJSON)
        let coreOptions = _WKWebAuthenticationPanel.convertToCoreRequestOptions(with: options)
        let forcesUserVerification = needsPRF(coreOptions.extensions) && supportsHmacSecret(authenticatorSupportedExtensions)
        let effectiveUVRequirement: WebCore.UserVerificationRequirement = forcesUserVerification ? .Required : coreOptions.userVerification
        return Data(
            fido.encodeGetAssertionRequestAsCBOR(
                hash,
                coreOptions,
                coreUserVerificationAvailability(userVerificationAvailability),
                effectiveUVRequirement,
                stringVector(authenticatorSupportedExtensions),
                nil,
                nil,
                nil
            )
        )
    }

    @objc(performEncodeMakeCredentialCommandWithClientDataHash:options:userVerificationAvailability:authenticatorSupportedExtensions:)
    class func performEncodeMakeCredentialCommand(
        withClientDataHash clientDataHash: Data?,
        options: _WKPublicKeyCredentialCreationOptions?,
        userVerificationAvailability: _WKWebAuthenticationUserVerificationAvailability,
        authenticatorSupportedExtensions: [String]?
    ) -> Data {
        let coreOptions = _WKWebAuthenticationPanel.convertToCoreCreationOptions(with: options)
        let effectiveUV = coreOptions.authenticatorSelection.value?.userVerification ?? .Discouraged
        return Data(
            fido.encodeMakeCredentialRequestAsCBOR(
                byteVector(clientDataHash),
                coreOptions,
                coreUserVerificationAvailability(userVerificationAvailability),
                effectiveUV,
                .supported,
                stringVector(authenticatorSupportedExtensions),
                nil,
                nil,
                nil,
                nil
            )
        )
    }

    @objc(performEncodeMakeCredentialCommandWithClientDataHash:options:userVerificationAvailability:credentialParameters:)
    class func performEncodeMakeCredentialCommand(
        withClientDataHash clientDataHash: Data?,
        options: _WKPublicKeyCredentialCreationOptions?,
        userVerificationAvailability: _WKWebAuthenticationUserVerificationAvailability,
        credentialParameters: [_WKPublicKeyCredentialParameters]?
    ) -> Data {
        let coreOptions = _WKWebAuthenticationPanel.convertToCoreCreationOptions(with: options)
        let effectiveUV = coreOptions.authenticatorSelection.value?.userVerification ?? .Discouraged
        return Data(
            fido.encodeMakeCredentialRequestAsCBOR(
                byteVector(clientDataHash),
                coreOptions,
                coreUserVerificationAvailability(userVerificationAvailability),
                effectiveUV,
                .supported,
                stringVector(nil),
                nil,
                .init(WebKit.webAuthenticationPanelCredentialParameters(credentialParameters)),
                nil,
                nil
            )
        )
    }

    @objc(performEncodeGetAssertionCommandWithClientDataHash:options:userVerificationAvailability:authenticatorSupportedExtensions:)
    class func performEncodeGetAssertionCommand(
        withClientDataHash clientDataHash: Data?,
        options: _WKPublicKeyCredentialRequestOptions?,
        userVerificationAvailability: _WKWebAuthenticationUserVerificationAvailability,
        authenticatorSupportedExtensions: [String]?
    ) -> Data {
        let coreOptions = _WKWebAuthenticationPanel.convertToCoreRequestOptions(with: options)
        // PRF forces user verification to Required.
        let forcesUserVerification = needsPRF(coreOptions.extensions) && supportsHmacSecret(authenticatorSupportedExtensions)
        let effectiveUVRequirement: WebCore.UserVerificationRequirement = forcesUserVerification ? .Required : coreOptions.userVerification
        return Data(
            fido.encodeGetAssertionRequestAsCBOR(
                byteVector(clientDataHash),
                coreOptions,
                coreUserVerificationAvailability(userVerificationAvailability),
                effectiveUVRequirement,
                stringVector(authenticatorSupportedExtensions),
                nil,
                nil,
                nil
            )
        )
    }
}

// MARK: Client data

private func produceClientDataJSON(
    _ type: _WKWebAuthenticationType,
    _ challenge: Data?,
    _ origin: String?,
    _ topOrigin: String?,
    _ scope: WebAuthn.Scope
) -> Data {
    let clientDataType: WebCore.ClientDataType
    switch type {
    case .create:
        clientDataType = .Create
    case .get:
        clientDataType = .Get
    @unknown default:
        preconditionFailure("An unknown authentication type")
    }
    let securityOrigin = WebCore.SecurityOrigin.createFromString(wtfString(origin))
    let clientDataJSON = WebCore.buildClientDataJson(
        clientDataType,
        fido.bufferSourceFromBytes(byteVector(challenge)),
        securityOrigin.get(),
        scope,
        wtfString(topOrigin)
    )
    return Data(clientDataJSON.get().toVector())
}

private func produceClientDataJSONHash(_ clientDataJSON: Data?) -> cbor.Bytes {
    makeByteVector(Array(SHA256.hash(data: clientDataJSON ?? Data())))
}

// MARK: Objective-C values to C++

/// `string` as a WTF string, null when nil, as `String(NSString *)` gives.
private func wtfString(_ string: String?) -> WTF.String {
    string.map(makeWTFString) ?? WTF.String()
}

/// `strings` as a WTF vector, empty when nil, as `makeVector<String>(NSArray *)` gives.
private func stringVector(_ strings: [String]?) -> fido.StringVector {
    var result = fido.StringVector()
    for string in strings ?? [] {
        result.append(consuming: makeWTFString(string))
    }
    return result
}

/// The bytes of `data`, none when nil, as `makeVector(NSData *)` gives.
private func byteVector(_ data: Data?) -> cbor.Bytes {
    makeByteVector([UInt8](data ?? Data()))
}

private func supportsHmacSecret(_ extensions: [String]?) -> Bool {
    // -containsObject: compares with -isEqual:.
    guard let extensions else {
        return false
    }
    return (extensions as NSArray).contains("hmac-secret")
}

private func needsPRF(_ extensions: borrowing fido.OptionalClientInputs) -> Bool {
    extensions.value?.prf.value != nil
}

private func wkWebAuthenticationTransport(_ transport: WebCore.AuthenticatorTransport) -> _WKWebAuthenticationTransport {
    switch transport {
    case .Usb:
        return .USB
    case .Nfc:
        return .NFC
    case .Ble:
        return .BLE
    case .Internal:
        return .internal
    case .Cable:
        return .caBLE
    case .Hybrid:
        return .hybrid
    case .SmartCard:
        return .smartCard
    @unknown default:
        preconditionFailure("An unknown transport")
    }
}

private func coreUserVerificationAvailability(
    _ availability: _WKWebAuthenticationUserVerificationAvailability
) -> fido.AuthenticatorSupportedOptions.UserVerificationAvailability {
    switch availability {
    case .supportedAndConfigured:
        return .supportedAndConfigured
    case .supportedButNotConfigured:
        return .supportedButNotConfigured
    case .notSupported:
        return .notSupported
    @unknown default:
        assertionFailure()
        return .notSupported
    }
}

private func toWebCore(_ mediation: _WKWebAuthenticationMediationRequirement) -> WebCore.MediationRequirement {
    switch mediation {
    case .silent:
        return .Silent
    case .optional:
        return .Optional
    case .required:
        return .Required
    case .conditional:
        return .Conditional
    @unknown default:
        assertionFailure()
        return .Optional
    }
}

// MARK: C++ responses to Objective-C

private func responseException(_ response: borrowing WebKit.AuthenticatorManager.Respond) -> NSError? {
    guard WebKit.webAuthenticationPanelResponseIsException(response) else {
        return nil
    }
    let exception = WebKit.webAuthenticationPanelResponseException(response)
    return NSError(
        domain: WKErrorDomain,
        code: Int(exception.code.rawValue),
        userInfo: [NSLocalizedDescriptionKey: makeSwiftString(exception.message)]
    )
}

/// The bytes of a response buffer the response always has.
private func requiredData(_ buffer: borrowing fido.ArrayBufferPtr) -> Data {
    guard let bytes = WebKit.webAuthenticationPanelBytes(buffer).value else {
        preconditionFailure("A response without a required buffer")
    }
    return Data(bytes)
}

private func authenticatorAttachmentToWKAuthenticatorAttachment(
    _ attachment: WebCore.AuthenticatorAttachment
) -> _WKAuthenticatorAttachment {
    switch attachment {
    case .Platform:
        return .platform
    case .CrossPlatform:
        return .crossPlatform
    @unknown default:
        preconditionFailure("An unknown attachment")
    }
}

private func wkTransports(_ transports: borrowing fido.TransportVector) -> [NSNumber] {
    // The WebCore values.
    var result: [NSNumber] = []
    for transport in transports {
        result.append(NSNumber(value: Int32(transport.rawValue)))
    }
    return result
}

private func wkAuthenticationExtensionsClientOutputs(
    _ outputs: borrowing WebCore.AuthenticationExtensionsClientOutputs
) -> _WKAuthenticationExtensionsClientOutputs {
    let first = WebKit.webAuthenticationPanelPRFFirst(outputs).value.map { Data($0) }
    let second = WebKit.webAuthenticationPanelPRFSecond(outputs).value.map { Data($0) }
    var largeBlob: _WKAuthenticationExtensionsLargeBlobOutputs?
    if let largeBlobOutputs = outputs.largeBlob.value {
        let blob = fido.largeBlobOutputBytes(largeBlobOutputs).value.map { Data($0) }
        largeBlob = _WKAuthenticationExtensionsLargeBlobOutputs(
            supported: largeBlobOutputs.supported.value ?? false,
            blob: blob,
            written: largeBlobOutputs.written.value ?? false
        )
    }
    return _WKAuthenticationExtensionsClientOutputs(
        appid: outputs.appid.value ?? false,
        prfEnabled: outputs.prf.value?.enabled.value ?? false,
        prfFirst: first,
        prfSecond: second,
        largeBlob: largeBlob
    )
}

private func attestationResponse(
    _ response: borrowing WebKit.AuthenticatorManager.Respond,
    _ clientDataJSON: Data?
) -> _WKAuthenticatorAttestationResponse {
    let data = WebKit.webAuthenticationPanelResponseData(response)
    let extensions = data.extensionOutputs.value.map { wkAuthenticationExtensionsClientOutputs($0) }
    return _WKAuthenticatorAttestationResponse(
        clientDataJSON: clientDataJSON,
        rawId: requiredData(data.rawId),
        extensions: extensions,
        attestationObject: requiredData(data.attestationObject),
        attachment: authenticatorAttachmentToWKAuthenticatorAttachment(WebKit.webAuthenticationPanelResponseAttachment(response)),
        transports: wkTransports(data.transports)
    )
}

private func assertionResponse(
    _ response: borrowing WebKit.AuthenticatorManager.Respond,
    _ clientDataJSON: Data?
) -> _WKAuthenticatorAssertionResponse {
    let data = WebKit.webAuthenticationPanelResponseData(response)
    let userHandle = WebKit.webAuthenticationPanelBytes(data.userHandle).value.map { Data($0) }
    let extensions = data.extensionOutputs.value.map { wkAuthenticationExtensionsClientOutputs($0) }
    return _WKAuthenticatorAssertionResponse(
        clientDataJSON: clientDataJSON,
        rawId: requiredData(data.rawId),
        extensions: extensions,
        authenticatorData: requiredData(data.authenticatorData),
        signature: requiredData(data.signature),
        userHandle: userHandle,
        attachment: authenticatorAttachmentToWKAuthenticatorAttachment(WebKit.webAuthenticationPanelResponseAttachment(response))
    )
}

// MARK: Keychain

private func updateQueryForGroupIfNecessary(_ dictionary: NSMutableDictionary, _ group: String?) {
    #if ENABLE_ONGOING_CREDENTIAL_SHARING_WEBKIT_SPI
    if let group {
        dictionary[sharingGroupAttribute] = group
    }
    #endif
}

#endif // ENABLE_WEB_AUTHN
