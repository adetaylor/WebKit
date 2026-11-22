// Copyright (C) 2018-2025 Apple Inc. All rights reserved.
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
import wtf

// The platform authenticator: credentials are Secure Enclave keys in the Keychain, each tagged with its user entity
// map (CBOR encoded).

private let counter: UInt32 = 0
// This aaguid is unattested.
private let aaguid: [UInt8] = [
    0xFB, 0xFC, 0x30, 0x07, 0x15, 0x4E, 0x4E, 0xCC, 0x8C, 0x0B, 0x6E, 0x02, 0x05, 0x57, 0xD7, 0xBD,
] // Randomly generated.

private let largeBlobMapKey = "largeBlob"
private let coseAlgorithmES256: Int64 = -7
private let enterpriseAAGUID: [UInt8] = [
    0xDD, 0x4E, 0xC2, 0x89, 0xE0, 0x1D, 0x41, 0xC9, 0xBB, 0x89, 0x70, 0xFA, 0x84, 0x5D, 0x4B, 0xF2,
]

// rpIDHash (32) + signature (4) + flags (1)
private let aaguidStartPosition = 32 + 4 + 1

extension WebKit.LocalAuthenticator {
    @cxx
    @implementation
    static func clearAllCredentials() {
        // FIXME<rdar://problem/57171201>: We should guard the method with a first party entitlement once WebAuthn is available for third parties.
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecAttrAccessGroup: WebCore.LocalAuthenticatorAccessGroup,
            kSecUseDataProtectionKeychain: true,
        ])
        updateQueryIfNecessary(query)

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logError("Couldn't clear all credential: \(status)")
        }
    }

    @cxx
    @implementation
    override func makeCredential() {
        assert(m_state == .Init)
        m_state = .RequestReceived
        let creationOptions = creationOptions()

        // The following implements https://www.w3.org/TR/webauthn/#op-make-cred as of 5 December 2017.
        // Skip Step 4-5 as requireResidentKey and requireUserVerification are enforced.
        // Skip Step 9 as extensions are not supported yet.
        // Step 8 is implicitly captured by all UnknownError exception receiveResponds.
        // Skip Step 10 as counter is constantly 0.
        // Step 2.
        if !supportsES256(creationOptions.pubKeyCredParams) {
            receiveException(
                .NotSupportedError,
                "The platform attached authenticator doesn't support any provided PublicKeyCredentialParameters."
            )
            return
        }

        // Step 3.
        assert(!creationOptions.rp.id.isNull())
        guard let existingCredentials = getExistingCredentials(creationOptions.rp.id) else {
            receiveException(.UnknownError, "Couldn't get existing credentials")
            return
        }
        for credential in existingCredentials {
            appendExistingCredential(credential)
        }

        let excludeCredentialIDs = produceHashSet(creationOptions.excludeCredentials)
        if !excludeCredentialIDs.isEmpty {
            if existingCredentials.contains(where: { excludeCredentialIDs.contains(base64RawID(of: $0)) }) {
                receiveException(
                    .InvalidStateError,
                    "At least one credential matches an entry of the excludeCredentials list in the platform attached authenticator.",
                    status: .LAExcludeCredentialsMatched
                )
                return
            }
        }

        requestLAContextForUserVerification()
    }

    @cxx
    @implementation
    override func getAssertion() {
        assert(m_state == .Init)
        m_state = .RequestReceived
        let requestOptions = requestOptions()

        // The following implements https://www.w3.org/TR/webauthn/#op-get-assertion as of 5 December 2017.
        // Skip Step 2 as requireUserVerification is enforced.
        // Skip Step 9 as counter is constantly 0.
        // Step 12 is implicitly captured by all UnknownError exception callbacks.
        // Step 3-5. Unlike the spec, if an allow list is provided and there is no intersection between existing ones and the allow list, we always return NotAllowedError.
        let allowCredentialIDs = produceHashSet(requestOptions.allowCredentials)
        if !requestOptions.allowCredentials.isEmpty() && allowCredentialIDs.isEmpty {
            receiveNoMatchedCredentialsException()
            return
        }

        // Search Keychain for the RP ID.
        guard let existingCredentials = getExistingCredentials(requestOptions.rpId) else {
            receiveException(.UnknownError, "Couldn't get existing credentials")
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't get existing credentials")
            return
        }
        for credential in existingCredentials {
            appendExistingCredential(credential)
        }

        var matchingCredentials = CredentialIndices()
        for (index, credential) in existingCredentials.enumerated()
        where allowCredentialIDs.isEmpty || allowCredentialIDs.contains(base64RawID(of: credential)) {
            matchingCredentials.append(consuming: UInt(index))
        }
        if matchingCredentials.isEmpty() {
            receiveNoMatchedCredentialsException()
            return
        }

        selectAssertionResponseFromObserver(matchingCredentials)
    }

    @cxx
    @implementation
    func continueGetAssertionAfterUserVerification(
        _ response: WebCore.AuthenticatorAssertionResponse,
        _ verification: WebKit.LocalConnection.UserVerification
    ) {
        assert(m_state == .ResponseSelected)
        m_state = .UserVerified

        guard validateUserVerification(verification) else {
            return
        }

        // Step 10.
        let requestOptions = requestOptions()
        let flags = authDataFlags(.Get, verification, synchronizable: response.synchronizable(), Optional(fromCxx: requestMediation()))
        let noAttestedCredentialData = cbor.Bytes()
        let authData = buildAuthData(requestOptions.rpId, flags, counter, noAttestedCredentialData)

        // Step 11.
        let credentialID = credentialID(of: response)
        guard let signature = assertionSignature(response, credentialID, authData) else {
            return
        }

        // Extra step: update the Keychain item with the same value to update its modification date such that LRU can be used
        // for selectAssertionResponse
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain: true,
        ])
        let updateParams = [aliasAttribute: credentialID] as CFDictionary
        let status = performQuery(query, credentialID: credentialID) { SecItemUpdate($0, updateParams) }

        if status != errSecSuccess {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't update the Keychain item: \(status)")
        }

        // Step 13.
        response.setAuthenticatorData(consuming: authData)
        response.setSignature(consuming: makeArrayBuffer(signature.span))
        if let exception = processClientExtensions(response) {
            receiveException(exception, .LAError)
        } else {
            respondWithResponse(response)
        }
    }

    @cxx
    @implementation
    func userEntityTag() -> cbor.Bytes {
        let creationOptions = creationOptions()
        // id, name, and displayName are required in PublicKeyCredentialUserEntity
        // https://www.w3.org/TR/webauthn-2/#dictdef-publickeycredentialuserentity
        return buildUserEntityMap(
            makeByteVector(bufferSourceBytes(creationOptions.user.id)),
            creationOptions.user.name,
            creationOptions.user.displayName
        )
    }

    @cxx
    @implementation
    func continueMakeCredentialAfterCreatingPrivateKey(
        _ publicKeyDataRef: CFData?,
        _ verification: WebKit.LocalConnection.UserVerification
    ) {
        let creationOptions = creationOptions()
        let secAttrLabel = makeSwiftString(creationOptions.rp.id)
        // 04 | X | Y; empty when the key could not be exported.
        let publicKeyData = publicKeyDataRef.map { [UInt8]($0 as Data) } ?? []

        // Query credentialId in the keychain could be racy as it is the only unique identifier
        // of the key item. Instead we calculate that, and examine its equality in DEBUG build.
        let credentialID = makeByteVector(Array(Insecure.SHA1.hash(data: publicKeyData)))
        m_provisionalCredentialId = credentialID
        let provisionalCredentialID = Data(credentialID)
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecAttrLabel: secAttrLabel,
            kSecAttrApplicationLabel: provisionalCredentialID,
            kSecUseDataProtectionKeychain: true,
        ])
        updateQueryIfNecessary(query)

        assert(SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess)

        let updateAttributes = [aliasAttribute: provisionalCredentialID] as CFDictionary
        SecItemUpdate(query as CFDictionary, updateAttributes)

        // Step 11. https://www.w3.org/TR/webauthn/#attested-credential-data
        // credentialPublicKey
        // COSE Encoding
        let fieldLength = WebCore.ES256FieldElementLength
        let x = coordinate(of: publicKeyData, at: 1, length: fieldLength)
        let y = coordinate(of: publicKeyData, at: 1 + fieldLength, length: fieldLength)
        let cosePublicKey = encodeES256PublicKeyAsCBOR(makeByteVector(x), makeByteVector(y))

        let flags = authDataFlags(.Create, verification, synchronizable: WebKit.shouldUpdateQuery(), Optional(fromCxx: requestMediation()))
        // Skip attestation.
        let authData = buildAuthData(
            creationOptions.rp.id,
            flags,
            counter,
            buildAttestedCredentialData(makeByteVector(aaguid), credentialID, cosePublicKey)
        )

        if creationOptions.attestation == .Enterprise {
            precondition(WTF.RunLoop.isMain())
            // A failed attestation still finishes the credential, with an empty attestation object.
            let attestationObject = performEnterpriseAttestation(creationOptions, authData) ?? cbor.Bytes()
            finishMakeCredential(credentialID, attestationObject)
            return
        }

        let noStatement = cbor.Bytes()
        let attestationObject = buildAttestationObject(authData, fido.emptyWTFString(), noStatement, .None)

        finishMakeCredential(credentialID, attestationObject)
    }

    @cxx
    @implementation
    func receiveException(_ exception: WebCore.ExceptionData, _ status: WebKit.WebAuthenticationStatus) {
        logError(makeSwiftString(exception.message))

        // Roll back the just created credential.
        if !m_provisionalCredentialId.isEmpty() {
            let provisionalCredentialID = Data(m_provisionalCredentialId)
            let query = keychainQuery([
                kSecClass: kSecClassKey,
                kSecUseDataProtectionKeychain: true,
            ])
            updateQueryIfNecessary(query)

            let deleteStatus = performQuery(query, credentialID: provisionalCredentialID) { SecItemDelete($0) }

            if deleteStatus != errSecSuccess {
                WebKit.LogChannel.WebAuthn().releaseLog
                    .error(
                        "Couldn't delete provisional credential while handling error: \(deleteStatus)"
                    )
            }
        }

        updateObserverStatus(status)
        respondWithError(exception.code, exception.message)
    }
}

// MARK: - Credentials in the Keychain

extension WebKit.LocalAuthenticator {
    private func getExistingCredentials(_ rpId: WTF.String) -> [WebCore.AuthenticatorAssertionResponse]? {
        let sortedAttributesArray = (m_connection.get().getExistingCredentials(rpId).get() as? [NSDictionary]) ?? []
        var result: [WebCore.AuthenticatorAssertionResponse] = []
        result.reserveCapacity(sortedAttributesArray.count)
        for attributes in sortedAttributesArray {
            let tag = [UInt8](checkedObjectCast(attributes[kSecAttrApplicationTag], to: Data.self) ?? Data())
            guard let responseMap = CBORView(tag.span), responseMap.isMap else {
                assertionFailure()
                return nil
            }

            let userHandle: fido.ArrayBufferPtr
            if let userID = responseMap.value(forKey: FidoName.entityID)?.byteString {
                userHandle = fido.ArrayBufferPtr(makeArrayBuffer(userID).get())
            } else {
                userHandle = fido.ArrayBufferPtr()
            }

            guard let username = responseMap.value(forKey: FidoName.entityName)?.string else {
                assertionFailure()
                return nil
            }

            let alias = WebKit.shouldUseAlternateKeychainAttribute() ? attributes[aliasAttribute] : nil
            let credentialID = alias ?? attributes[kSecAttrApplicationLabel]
            let rawID = checkedObjectCast(credentialID, to: Data.self) ?? Data()

            let secAccessControl = checkedObjectCast(attributes[kSecAttrAccessControl], to: SecAccessControl.self)
            let response = WebCore.AuthenticatorAssertionResponse
                .create(
                    consuming: makeArrayBuffer(rawID.span),
                    consuming: userHandle,
                    consuming: makeWTFString(username),
                    secAccessControl,
                    .Platform
                )
                .get()

            if let group = attributes[sharingGroupAttribute] as? NSString {
                response.setGroup(makeWTFString(group as String))
                response.setSynchronizable(true)
            } else if let synchronizable = attributes[kSecAttrSynchronizable] {
                response.setSynchronizable((synchronizable as AnyObject).isEqual(NSNumber(value: true)))
            }
            if let displayName = responseMap.value(forKey: FidoName.displayName)?.string {
                response.setDisplayName(makeWTFString(displayName))
            }

            if let largeBlob = responseMap.value(forKey: largeBlobMapKey)?.byteString {
                response.setLargeBlob(consuming: makeArrayBuffer(largeBlob))
            }

            let accessGroup = checkedObjectCast(attributes[kSecAttrAccessGroup], to: NSString.self)
            response.setAccessGroup(accessGroup.map { makeWTFString($0 as String) } ?? WTF.String())

            result.append(response)
        }
        return result
    }

    private func deleteDuplicateCredential() {
        let creationOptions = creationOptions()
        let userID = bufferSourceBytes(creationOptions.user.id)
        for index in 0..<existingCredentialCount() {
            let credential = existingCredential(index).get()
            guard let userHandle = credential.userHandle() else {
                preconditionFailure("A Keychain credential without a user handle")
            }
            if !sameBytes(userHandle.toVector(), userID) {
                continue
            }

            let rawID = credentialID(of: credential)
            let query = keychainQuery([
                kSecClass: kSecClassKey,
                aliasAttribute: rawID,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny,
                kSecUseDataProtectionKeychain: true,
            ])

            let status = performQuery(query, credentialID: rawID) { SecItemDelete($0) }

            if status != errSecSuccess && status != errSecItemNotFound {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't delete older credential: \(status)")
            }
            return
        }
    }
}

// MARK: - Assertion

extension WebKit.LocalAuthenticator {
    // The signature of the authenticator data and the client data hash by the credential's private key, or nil after
    // the exception is received.
    private func assertionSignature(
        _ response: WebCore.AuthenticatorAssertionResponse,
        _ credentialID: Data,
        _ authData: cbor.Bytes
    ) -> [UInt8]? {
        let query = keychainQuery([
            kSecClass: kSecClassKey,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnRef: true,
            kSecUseDataProtectionKeychain: true,
        ])
        WebKit.addAuthenticationContext(response, query)

        var status = errSecSuccess
        let privateKeyRef = copyMatchingItems(query, credentialID: credentialID, &status)

        if status != errSecSuccess {
            receiveException(.UnknownError, "Couldn't get the private key reference: \(status)")
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't get the private key reference: \(status)")
            return nil
        }
        guard let privateKeyRef else {
            receiveException(.UnknownError, "privateKeyRef is null. status:\(status)")
            WebKit.LogChannel.WebAuthn().releaseLog.error("privateKeyRef is null. status: \(status)")
            return nil
        }

        var dataToSign = makeByteArray(authData.span())
        let clientDataHash = requestHash()
        dataToSign.append(contentsOf: makeByteArray(clientDataHash.span()))

        // FIXME: Converting CFTypeRef to SecKeyRef is quite subtle here.
        let privateKey = checkedObjectCast(privateKeyRef, to: SecKey.self)
        var signature = cbor.Bytes()
        let error = WebKit.createKeySignature(privateKey, .ecdsaSignatureMessageX962SHA256, Data(dataToSign) as CFData, &signature)
        if let error = Optional(fromCxx: error) {
            let description = makeSwiftString(error)
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't generate signature: \(description)")
            receiveException(.UnknownError, "Couldn't generate the signature: \(description)")
            return nil
        }
        return makeByteArray(signature.span())
    }

    private func receiveNoMatchedCredentialsException() {
        receiveException(
            .NotAllowedError,
            "No matched credentials are found in the platform attached authenticator.",
            status: .LANoCredential
        )
        WebKit.LogChannel.WebAuthn().releaseLog.error("No matched credentials are found in the platform attached authenticator.")
    }

    private func processClientExtensions(_ response: WebCore.AuthenticatorAssertionResponse) -> WebCore.ExceptionData? {
        let assertionOptions = requestOptions()
        guard let extensions = Optional(fromCxx: assertionOptions.extensions) else {
            return nil
        }

        var extensionOutputs = response.extensions()
        if let exception = processLargeBlobExtension(extensions, &extensionOutputs, response) {
            return exception
        }

        response.setExtensions(consuming: extensionOutputs)
        return nil
    }

    private func processLargeBlobExtension(
        _ extensions: WebCore.AuthenticationExtensionsClientInputs,
        _ extensionOutputs: inout WebCore.AuthenticationExtensionsClientOutputs,
        _ response: WebCore.AuthenticatorAssertionResponse
    ) -> WebCore.ExceptionData? {
        guard let largeBlobInput = Optional(fromCxx: extensions.largeBlob) else {
            return nil
        }
        let read = Optional(fromCxx: largeBlobInput.read)
        let write = Optional(fromCxx: largeBlobInput.write)
        var largeBlobOutput = WebCore.AuthenticationExtensionsClientOutputs.LargeBlobOutputs()

        // Step 1.
        if !largeBlobInput.support.isNull() {
            return exceptionData(.NotSupportedError, "Cannot use `support` with largeBlob during get.")
        }

        // Step 2.
        if read != nil && write != nil {
            return exceptionData(.NotSupportedError, "Cannot use `read` and `write` simultaneously with largeBlob.")
        }

        // Step 3.
        if read == true {
            var blob = alternateBlobIfNecessary()

            if blob.get() == nil {
                blob = response.largeBlob()
            }

            if blob.get() != nil {
                largeBlobOutput.blob = blob
            }
        }

        // Step 4.
        if let write {
            let fetchQuery = keychainQuery([
                kSecClass: kSecClassKey,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny,
                kSecUseDataProtectionKeychain: true,
                kSecReturnAttributes: true,
                kSecReturnPersistentRef: true,
            ])

            var status = errSecSuccess
            let attributesRef = copyMatchingItems(fetchQuery, credentialID: credentialID(of: response), &status)

            if status != errSecSuccess && status != errSecItemNotFound {
                assertionFailure()
                return exceptionData(.UnknownError, "Attempted to update unknown credential.")
            }

            let attributes = checkedObjectCast(attributesRef, to: NSDictionary.self)
            let tag = [UInt8](checkedObjectCast(attributes?[kSecAttrApplicationTag], to: Data.self) ?? Data())
            guard let outputTag = userEntityMapWithLargeBlob(makeByteVector(tag), makeByteVector(bufferSourceBytes(write)))
            else {
                assertionFailure()
                return exceptionData(.UnknownError, "Could not read credential.")
            }

            guard let persistentRef = attributes?[kSecValuePersistentRef] else {
                preconditionFailure("A Keychain item without a persistent reference")
            }
            let updateQuery = [kSecValuePersistentRef: persistentRef] as CFDictionary
            let updateParams = [kSecAttrApplicationTag: Data(outputTag)] as CFDictionary

            status = SecItemUpdate(updateQuery, updateParams)
            largeBlobOutput.written = .init(status == errSecSuccess)
        }

        extensionOutputs.largeBlob = .init(largeBlobOutput)
        return nil
    }
}

// MARK: - Attestation

extension WebKit.LocalAuthenticator {
    private func finishMakeCredential(_ credentialID: cbor.Bytes, _ attestationObject: cbor.Bytes) {
        deleteDuplicateCredential()
        var transports = fido.TransportVector()
        transports.append(consuming: .Hybrid)
        transports.append(consuming: .Internal)
        let response = WebCore.AuthenticatorAttestationResponse
            .create(
                credentialID,
                attestationObject,
                .Platform,
                consuming: transports
            )
            .get()
        if let exception = processClientExtensions(response) {
            receiveException(exception, .LAError)
        } else {
            respondWithResponse(response)
        }
    }

    // The packed attestation statement of the enterprise attestation identity, or nil when it cannot be made.
    private func performEnterpriseAttestation(
        _ creationOptions: WebCore.PublicKeyCredentialCreationOptions,
        _ authData: cbor.Bytes
    ) -> cbor.Bytes? {
        var dataToSign = makeByteArray(authData.span())
        dataToSign.replaceSubrange(aaguidStartPosition..<(aaguidStartPosition + enterpriseAAGUID.count), with: enterpriseAAGUID)
        let clientDataHash = requestHash()
        dataToSign.append(contentsOf: makeByteArray(clientDataHash.span()))

        guard let persistentRef = WebKit.copyEnterpriseAttestationIdentityPersistentReference(creationOptions.rp.id) else {
            return nil
        }

        let query =
            [
                kSecClass: kSecClassIdentity,
                kSecValuePersistentRef: persistentRef,
                kSecReturnRef: true,
            ] as CFDictionary
        var status = errSecSuccess
        let identityRef = WebKit.copyMatchingKeychainItems(query, &status)
        if status != errSecSuccess {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't find attestation certificate: \(status)")
            return nil
        }
        let identity = checkedObjectCast(identityRef, to: SecIdentity.self)

        let privateKey = WebKit.copyIdentityPrivateKey(identity, &status)
        if status != errSecSuccess {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't access attestation signing key: \(status)")
            return nil
        }

        var signature = cbor.Bytes()
        let error = WebKit.createKeySignature(privateKey, .ecdsaSignatureMessageX962SHA256, Data(dataToSign) as CFData, &signature)
        if let error = Optional(fromCxx: error) {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't generate attestation signature: \(makeSwiftString(error))")
            return nil
        }

        let certificate = WebKit.copyIdentityCertificate(identity, &status)
        if status != errSecSuccess {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Couldn't access attestation certificate: \(status)")
            return nil
        }
        guard let certificate else {
            preconditionFailure("An attestation identity without a certificate")
        }

        let trust = WebKit.createTrustWithCertificates([certificate] as CFArray, SecPolicyCreateBasicX509())
        let chain = trust.flatMap { SecTrustCopyCertificateChain($0) as? [SecCertificate] } ?? []

        let signatureBytes = makeByteArray(signature.span())
        var attestationStatementMap = CBORWriter(reservingCapacity: 64 + signatureBytes.count)
        attestationStatementMap.beginMap(count: 3)
        attestationStatementMap.writeTextString("alg")
        attestationStatementMap.writeInteger(coseAlgorithmES256)
        attestationStatementMap.writeTextString("sig")
        attestationStatementMap.writeByteString(signatureBytes.span)
        attestationStatementMap.writeTextString("x5c")
        attestationStatementMap.beginArray(count: chain.count)
        for certificate in chain {
            let certificateBytes = [UInt8](SecCertificateCopyData(certificate) as Data)
            attestationStatementMap.writeByteString(certificateBytes.span)
        }

        return buildAttestationObject(
            authData,
            makeWTFString("packed"),
            attestationStatementMap.takeVector(),
            creationOptions.attestation
        )
    }

    private func processClientExtensions(_ response: WebCore.AuthenticatorAttestationResponse) -> WebCore.ExceptionData? {
        let creationOptions = creationOptions()
        guard let extensions = Optional(fromCxx: creationOptions.extensions) else {
            return nil
        }

        var extensionOutputs = response.extensions()
        if Optional(fromCxx: extensions.credProps) != nil {
            extensionOutputs.credProps = .init(WebCore.CredentialPropertiesOutput(rk: true))
        }

        if let exception = processLargeBlobExtension(extensions, &extensionOutputs) {
            return exception
        }

        response.setExtensions(consuming: extensionOutputs)
        return nil
    }

    private func processLargeBlobExtension(
        _ extensions: WebCore.AuthenticationExtensionsClientInputs,
        _ extensionOutputs: inout WebCore.AuthenticationExtensionsClientOutputs
    ) -> WebCore.ExceptionData? {
        guard let largeBlobInput = Optional(fromCxx: extensions.largeBlob) else {
            return nil
        }

        // Step 1.
        if Optional(fromCxx: largeBlobInput.read) != nil || Optional(fromCxx: largeBlobInput.write) != nil {
            return exceptionData(.NotSupportedError, "Cannot use `read` or `write` with largeBlob during create.")
        }

        // Step 2-3.
        var largeBlobOutput = WebCore.AuthenticationExtensionsClientOutputs.LargeBlobOutputs()
        largeBlobOutput.supported = .init(true)
        extensionOutputs.largeBlob = .init(largeBlobOutput)
        return nil
    }

    private func receiveException(
        _ code: WebCore.ExceptionCode,
        _ message: Swift.String,
        status: WebKit.WebAuthenticationStatus = .LAError
    ) {
        receiveException(exceptionData(code, message), status)
    }
}

// MARK: - Helpers

// ArrayBuffer::create of `bytes`. An empty Array or Data has no base address, and a Span without one traps at the
// std::span parameter, so an empty one makes the empty buffer directly.
private func makeArrayBuffer(_ bytes: Span<UInt8>) -> JSC.RefArrayBuffer {
    if bytes.isEmpty {
        return JSC.ArrayBuffer.create(0, 1)
    }
    return JSC.ArrayBuffer.createFromSpan(bytes)
}

// LOG_ERROR, which builds with assertions keep.
private func logError(_ message: @autoclosure () -> Swift.String) {
    #if ASSERT_ENABLED
    let text = message()
    WebKit.LogChannel.WebAuthn().releaseLog.error("\(text, privacy: .public)")
    #endif
}

private func exceptionData(_ code: WebCore.ExceptionCode, _ message: Swift.String) -> WebCore.ExceptionData {
    WebCore.ExceptionData(code: code, message: makeWTFString(message))
}

private func supportsES256(_ parameters: fido.CredentialParametersVector) -> Bool {
    for parameter in parameters
    where parameter.type == fido.publicKeyCredentialTypePublicKey() && parameter.alg == COSE.ES256 {
        return true
    }
    return false
}

private func emptyTransportsOrContain(_ transports: fido.TransportVector, _ target: WebCore.AuthenticatorTransport) -> Bool {
    if transports.isEmpty() {
        return true
    }
    for transport in transports where transport == target {
        return true
    }
    return false
}

// A Base64 encoded string of the Credential ID is used as the key of the hash set.
private func produceHashSet(_ credentialDescriptors: fido.CredentialDescriptorVector) -> Set<Swift.String> {
    var result = Set<Swift.String>()
    for credentialDescriptor in credentialDescriptors
    where emptyTransportsOrContain(credentialDescriptor.transports, .Internal)
        && credentialDescriptor.type == fido.publicKeyCredentialTypePublicKey()
    {
        result.insert(base64String(makeByteVector(bufferSourceBytes(credentialDescriptor.id))))
    }
    return result
}

private func base64RawID(of credential: WebCore.AuthenticatorAssertionResponse) -> Swift.String {
    base64String(credential.rawId().toVector())
}

// The credential's ID, as the Keychain stores it.
private func credentialID(of credential: WebCore.AuthenticatorAssertionResponse) -> Data {
    Data(credential.rawId().toVector())
}

private func authDataFlags(
    _ type: WebCore.ClientDataType,
    _ verification: WebKit.LocalConnection.UserVerification,
    synchronizable: Bool,
    _ mediation: WebCore.MediationRequirement?
) -> UInt8 {
    var flags: UInt8 = 0
    if type != .Create || mediation != .Conditional {
        flags |= WebAuthn.userPresenceFlag
    }
    if verification != .Presence {
        flags |= WebAuthn.userVerifiedFlag
    }
    if type == .Create {
        flags |= WebAuthn.attestedCredentialDataIncludedFlag
    }
    if synchronizable {
        flags |= WebAuthn.backupEligibilityFlag | WebAuthn.backupStateFlag
    }
    return flags
}

// The `length` bytes at `offset`; zeros, as a message to nil reads, when there are no bytes at all.
private func coordinate(of publicKeyData: [UInt8], at offset: Int, length: Int) -> [UInt8] {
    if publicKeyData.isEmpty {
        return [UInt8](repeating: 0, count: length)
    }
    return Array(publicKeyData[offset..<(offset + length)])
}

private func sameBytes(_ a: cbor.Bytes, _ b: [UInt8]) -> Bool {
    let bytes: Span<UInt8> = a.span()
    if bytes.count != b.count {
        return false
    }
    for index in 0..<b.count where bytes[index] != b[index] {
        return false
    }
    return true
}

#endif // ENABLE_WEB_AUTHN
