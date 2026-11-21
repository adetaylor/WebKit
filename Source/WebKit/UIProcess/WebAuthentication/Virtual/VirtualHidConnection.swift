// Copyright (C) 2022 Apple Inc. All rights reserved.
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

// The CTAP2 device the virtual authenticator emulates: answers each request with a response, keeping its
// credentials in the authenticator manager.

// A request field of the wrong CBOR type traps.
private func wrongType() -> Never {
    preconditionFailure("CTAP2 request field of the wrong CBOR type")
}

extension WebKit.VirtualHidConnection {
    @cxx
    @implementation
    func parseRequest() {
        let request = requestMessageState()
        guard request.valid else {
            return
        }
        guard let manager = m_manager.get() else {
            return
        }
        m_currentChannel = request.channelId
        switch request.cmd {
        case .`init`:
            m_nonce = request.payload
            assert(m_nonce.size() == fido.kHidInitNonceLength)
            // The response is the nonce, a random channel ID and zeros up to the response size.
            let writePosition = request.payload.size()
            precondition(writePosition + fido.kCtapChannelIdSize <= fido.kHidInitResponseSize)
            var payload = makeByteArray(request.payload.span())
            payload.append(contentsOf: repeatElement(0, count: fido.kHidInitResponseSize - writePosition))
            for index in 0..<fido.kCtapChannelIdSize {
                payload[writePosition + index] = UInt8.random(in: .min ... .max)
            }
            let initPacket = fido.FidoHidMessage.serializeInitPacket(
                fido.kHidBroadcastChannel,
                .`init`,
                UInt16(truncatingIfNeeded: payload.count),
                makeByteVector(payload)
            )
            receiveReport(consuming: initPacket)
        case .cbor:
            let message: Span<UInt8> = request.payload.span()
            let cmd = message[0]
            let requestMap = CBORView(message.extracting(1...))
            assert(requestMap != nil || cmd == fido.CtapRequestCommand.authenticatorGetNextAssertion.rawValue)
            if cmd == fido.CtapRequestCommand.authenticatorMakeCredential.rawValue {
                guard let requestMap, requestMap.isMap else {
                    wrongType()
                }
                if let errorCode = makeCredentialResponse(requestMap, manager) {
                    recieveResponseCode(errorCode)
                    return
                }
            } else if cmd == fido.CtapRequestCommand.authenticatorGetAssertion.rawValue {
                guard let requestMap, requestMap.isMap else {
                    wrongType()
                }
                if let errorCode = getAssertionResponse(requestMap, manager) {
                    recieveResponseCode(errorCode)
                    return
                }
            }
        default:
            break
        }
        clearRequestMessage()
    }

    // Answers a makeCredential request and returns nil, or returns the error code to send.
    private func makeCredentialResponse(
        _ requestMap: borrowing CBORView,
        _ manager: WebKit.VirtualAuthenticatorManager
    ) -> fido.CtapDeviceResponseCode? {
        // The counter and flags are zero unless the request's options set them.
        var credential = WebKit.VirtualCredential()
        credential.signCount = 0
        credential.isResidentCredential = false
        credential.isVerificationRequired = false
        if let errorCode = applyMakeCredentialOptions(requestMap, to: &credential) {
            return errorCode
        }
        guard let rpEntity = requestMap.value(forKey: fido.kCtapMakeCredentialRpKey) else {
            return .ctap2ErrMissingParameter
        }
        guard rpEntity.isMap else {
            wrongType()
        }
        guard let rpID = rpEntity.value(forKey: FidoName.entityID) else {
            return .ctap2ErrMissingParameter
        }
        guard let rpIDText = rpID.string else {
            wrongType()
        }
        credential.rpId = makeWTFString(rpIDText)
        guard let privateKey = createPrivateKey() else {
            preconditionFailure("SecKeyCreateRandomKey failed")
        }
        credential.privateKey = base64PrivateKey(privateKey)

        guard let userEntity = requestMap.value(forKey: fido.kCtapMakeCredentialUserKey) else {
            return .ctap2ErrMissingParameter
        }
        guard userEntity.isMap else {
            wrongType()
        }
        guard let userID = userEntity.value(forKey: FidoName.entityID) else {
            return .ctap2ErrMissingParameter
        }
        guard let userHandle = userID.byteString else {
            wrongType()
        }
        credential.userHandle = fido.OptionalByteVector(makeByteVector(userHandle))
        let credentialIDAndCosePubKey = credentialIDAndCosePubKeyForPrivateKey(privateKey)
        credential.credentialId = credentialIDAndCosePubKey.credentialID
        manager.addCredential(m_authenticatorId, &credential)

        let attestedCredentialData = buildAttestedCredentialData(
            aaguidOfZeros(),
            credentialIDAndCosePubKey.credentialID,
            credentialIDAndCosePubKey.cosePublicKey
        )
        let authenticatorData = buildAuthData(
            credential.rpId,
            flagsForConfig(m_configuration),
            UInt32(truncatingIfNeeded: credential.signCount),
            attestedCredentialData
        )
        let noStatement = cbor.Bytes()
        let attObj = buildAttestationObject(authenticatorData, fido.emptyWTFString(), noStatement, .None)
        var writer = CBORWriter(reservingCapacity: 64 + authenticatorData.size() + attObj.size())
        writer.append(byte: fido.CtapDeviceResponseCode.success.rawValue)
        writer.beginMap(count: 3)
        writer.writeInteger(1)
        writer.writeTextString("none")
        writer.writeInteger(2)
        writer.writeByteString(authenticatorData.span())
        writer.writeInteger(3)
        writer.append(encodedItem: attObj.span())
        receiveResponse(writer.takeVector())
        return nil
    }

    // Takes the resident key and user verification options of a makeCredential request into the credential, or returns
    // the error code when the configuration cannot meet them.
    private func applyMakeCredentialOptions(
        _ requestMap: borrowing CBORView,
        to credential: inout WebKit.VirtualCredential
    ) -> fido.CtapDeviceResponseCode? {
        guard let optionMap = requestMap.value(forKey: fido.kCtapMakeCredentialRequestOptionsKey) else { // Find options.
            return nil
        }
        guard optionMap.isMap else {
            wrongType()
        }
        if let requireResidentKey = option(optionMap, FidoName.residentKey) {
            // https://fidoalliance.org/specs/fido-v2.1-rd-20210309/fido-client-to-authenticator-protocol-v2.1-rd-20210309.html#op-makecred-step-options
            if requireResidentKey && !m_configuration.hasResidentKey {
                return .ctap2ErrUnsupportedOption
            }
            if requireResidentKey {
                credential.isResidentCredential = true
            }
        }

        if let requireUserVerification = option(optionMap, FidoName.userVerification) {
            if let errorCode = userVerificationError(requireUserVerification) {
                return errorCode
            }
            credential.isVerificationRequired = requireUserVerification
        }
        return nil
    }

    // The error code when the request asks for user verification the configuration cannot give, else nil.
    private func userVerificationError(_ requireUserVerification: Bool) -> fido.CtapDeviceResponseCode? {
        if requireUserVerification && !m_configuration.hasUserVerification {
            return .ctap2ErrInvalidOption
        }
        if requireUserVerification && !m_configuration.isUserVerified {
            return .ctap2ErrOperationDenied
        }
        return nil
    }

    // Answers a getAssertion request and returns nil, or returns the error code to send.
    private func getAssertionResponse(
        _ requestMap: borrowing CBORView,
        _ manager: WebKit.VirtualAuthenticatorManager
    ) -> fido.CtapDeviceResponseCode? {
        guard let rpIDItem = requestMap.value(forKey: fido.kCtapGetAssertionRpIdKey) else {
            return .ctap2ErrMissingParameter
        }
        guard let rpIDText = rpIDItem.string else {
            wrongType()
        }
        let rpID = makeWTFString(rpIDText)
        guard let clientDataHashItem = requestMap.value(forKey: fido.kCtapGetAssertionClientDataHashKey) else {
            return .ctap2ErrMissingParameter
        }
        guard let clientDataHash = clientDataHashItem.byteString else {
            wrongType()
        }
        var allowList = fido.ByteVectorVector()
        if let errorCode = readAllowList(requestMap, into: &allowList) {
            return errorCode
        }
        if let errorCode = getAssertionOptionsError(requestMap) {
            return errorCode
        }
        let matchingCredentials = manager.credentialsMatchingList(m_authenticatorId, rpID, allowList)
        if matchingCredentials.isEmpty() {
            return .ctap2ErrNoCredentials
        }
        let credential = matchingCredentials[0]

        guard let key = privateKeyFromBase64(credential.privateKey) else {
            preconditionFailure("The stored private key does not decode")
        }
        let credentialIDAndCosePubKey = credentialIDAndCosePubKeyForPrivateKey(key)
        let attestedCredentialData = buildAttestedCredentialData(
            aaguidOfZeros(),
            credentialIDAndCosePubKey.credentialID,
            credentialIDAndCosePubKey.cosePublicKey
        )
        let authData = buildAuthData(
            rpID,
            flagsForConfig(m_configuration),
            UInt32(truncatingIfNeeded: credential.signCount),
            attestedCredentialData
        )
        let signature = signatureForPrivateKey(key, authData.span(), clientDataHash)
        let userHandle = Optional(fromCxx: credential.userHandle)

        var writer = CBORWriter(reservingCapacity: 128 + authData.size() + signature.size())
        writer.append(byte: fido.CtapDeviceResponseCode.success.rawValue)
        writer.beginMap(count: userHandle == nil ? 4 : 5)
        writer.writeInteger(1)
        let credentialDescriptor = buildCredentialDescriptor(credential.credentialId)
        writer.append(encodedItem: credentialDescriptor.span())
        writer.writeInteger(2)
        writer.writeByteString(authData.span())
        writer.writeInteger(3)
        writer.writeByteString(signature.span())
        if let userHandle {
            writer.writeInteger(4)
            let userEntity = buildUserEntityMap(userHandle, fido.emptyWTFString(), fido.emptyWTFString())
            writer.append(encodedItem: userEntity.span())
        }
        writer.writeInteger(5)
        writer.writeInteger(Int64(truncatingIfNeeded: matchingCredentials.size()))
        receiveResponse(writer.takeVector())
        return nil
    }

    // Reads a getAssertion request's allow list into `allowList`, or returns the error code for one that is empty or
    // has a credential without an ID.
    private func readAllowList(
        _ requestMap: borrowing CBORView,
        into allowList: inout fido.ByteVectorVector
    ) -> fido.CtapDeviceResponseCode? {
        guard let cborAllowList = requestMap.value(forKey: fido.kCtapGetAssertionAllowListKey) else {
            return nil
        }
        guard var cborCredentials = cborAllowList.elements, let credentialCount = cborAllowList.count else {
            wrongType()
        }
        if credentialCount == 0 {
            return .ctap2ErrInvalidOption
        }

        while let cborCredential = cborCredentials.next() {
            guard cborCredential.isMap else {
                wrongType()
            }
            guard let credentialID = cborCredential.value(forKey: FidoName.entityID)?.byteString else {
                return .ctap2ErrInvalidOption
            }
            allowList.append(consuming: makeByteVector(credentialID))
        }
        return nil
    }

    // The error code when a getAssertion request asks for user verification or presence the configuration cannot give,
    // else nil.
    private func getAssertionOptionsError(_ requestMap: borrowing CBORView) -> fido.CtapDeviceResponseCode? {
        guard let optionMap = requestMap.value(forKey: fido.kCtapGetAssertionRequestOptionsKey) else {
            return nil
        }
        guard optionMap.isMap else {
            wrongType()
        }
        if let requireUserVerification = option(optionMap, FidoName.userVerification),
            let errorCode = userVerificationError(requireUserVerification)
        {
            return errorCode
        }
        if let requireUserPresence = option(optionMap, FidoName.userPresence), requireUserPresence && !m_configuration.isUserConsenting {
            return .ctap2ErrOperationDenied
        }
        return nil
    }
}

// The boolean option at `key`, or nil when the options do not have it.
private func option(_ optionMap: borrowing CBORView, _ key: Swift.String) -> Bool? {
    guard let option = optionMap.value(forKey: key) else {
        return nil
    }
    guard let value = option.bool else {
        wrongType()
    }
    return value
}

private func aaguidOfZeros() -> cbor.Bytes {
    makeByteVector([UInt8](repeating: 0, count: WebCore.aaguidLength))
}

#endif // ENABLE_WEB_AUTHN
