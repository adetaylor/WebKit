// Copyright (C) 2018 Apple Inc. All rights reserved.
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

private typealias Mock = WebCore.MockWebAuthenticationConfiguration

extension WebKit.MockHidConnection {
    @cxx
    @implementation
    func parseRequest() {
        let request = requestMessageState()
        assert(request.valid)
        // Set stages.
        if request.cmd == .`init` {
            let previousSubStage = m_subStage
            m_subStage = .Init
            if previousSubStage == .Msg {
                m_stage = .Request
            }
        }
        if request.cmd == .cbor || request.cmd == .msg {
            m_subStage = .Msg
        }

        if m_stage == .Request && m_subStage == .Msg {
            if let hid = m_configuration.hid.value, hid.validateExpectedCommands {
                validateExpectedCommand(request.payload)
            }

            // Make sure we issue different msg cmd for CTAP and U2F.
            if hid.canDowngrade && !hid.isU2f {
                changeHid { $0.isU2f = request.cmd == .msg }
            }
            assert(hid.isU2f != (request.cmd != .msg))

            if request.cmd == .cbor {
                setRequestOptions(request.payload)
            }
        }

        // Store nonce.
        if m_subStage == .Init {
            m_nonce = request.payload
            assert(m_nonce.size() == fido.kHidInitNonceLength)
        }

        m_currentChannel = request.channelId
        clearRequestMessage()
        if hid.fastDataArrival {
            feedReports()
        }
    }

    @cxx
    @implementation
    override func registerDataReceivedCallbackInternal() {
        if stagesMatch() && hid.error == .EmptyReport {
            receiveReport(consuming: cbor.Bytes())
            shouldContinueFeedReports()
            return
        }
        if !hid.fastDataArrival {
            feedReports()
        }
    }

    @cxx
    @implementation
    func nextResponse() -> fido.HidMessageState {
        if m_subStage == .Init {
            sendInitResponse()
            return fido.HidMessageState()
        }
        if m_stage == .Info {
            return infoResponse()
        }
        return requestResponse()
    }

    @cxx
    @implementation
    func stagesMatch() -> Bool {
        let hid = self.hid
        return hid.stage == m_stage && hid.subStage == m_subStage
    }

    @cxx
    @implementation
    func shouldContinueFeedReports() {
        if !hid.continueAfterErrorData {
            return
        }
        changeHid {
            $0.continueAfterErrorData = false
            $0.error = .Success
        }
        continueFeedReports()
    }

    @cxx
    @implementation
    func initializeExpectedCommands() {
        guard let hid = m_configuration.hid.value, hid.validateExpectedCommands else {
            return
        }

        m_expectedCommands = fido.ByteVectorVector()
        m_currentExpectedCommandIndex = 0

        for index in 0..<hid.expectedCommandsBase64.size() {
            let expectedCommandBase64 = hid.expectedCommandsBase64[index]
            if let decodedMessage = Optional(fromCxx: fido.base64DecodeString(expectedCommandBase64)) {
                m_expectedCommands.append(consuming: decodedMessage)
            } else {
                WebKit.LogChannel.WebAuthn().releaseLog
                    .error(
                        "MockHidConnection: Failed to decode expected command: \(expectedCommandBase64.description)"
                    )
            }
        }

        WebKit.LogChannel.WebAuthn().releaseLog
            .log(
                "MockHidConnection: Initialized \(self.m_expectedCommands.size()) expected commands for validation"
            )
    }

    @cxx
    @implementation
    func validateExpectedCommand(_ actualCommand: cbor.Bytes) {
        if m_currentExpectedCommandIndex >= m_expectedCommands.size() {
            WebKit.LogChannel.WebAuthn().releaseLog
                .error(
                    "MockHidConnection: VALIDATION FAILED - Received unexpected command beyond expected count. Expected \(self.m_expectedCommands.size()) commands, but received command \(self.m_currentExpectedCommandIndex + 1). Content: \(fido.base64EncodeBytes(actualCommand).description)"
                )
            preconditionFailure("MockHidConnection: Unexpected command.")
        }

        let expectedCommand = m_expectedCommands[m_currentExpectedCommandIndex]
        if makeByteArray(actualCommand) != makeByteArray(expectedCommand) {
            WebKit.LogChannel.WebAuthn().releaseLog
                .error(
                    "MockHidConnection: VALIDATION FAILED - Command mismatch at index \(self.m_currentExpectedCommandIndex). Expected \(fido.base64EncodeBytes(expectedCommand).description) Actual \(fido.base64EncodeBytes(actualCommand).description)"
                )
            preconditionFailure("MockHidConnection: Command did not match expected value.")
        }

        m_currentExpectedCommandIndex += 1
    }

    @cxx
    @implementation
    func validateExpectedCommandsCompleted() {
        guard let hid = m_configuration.hid.value, hid.validateExpectedCommands else {
            return
        }
        if m_currentExpectedCommandIndex >= m_expectedCommands.size() {
            return
        }

        for index in m_currentExpectedCommandIndex..<m_expectedCommands.size() {
            WebKit.LogChannel.WebAuthn().releaseLog
                .error(
                    "MockHidConnection: Missing expected command \(index): \(fido.base64EncodeBytes(self.m_expectedCommands[index]).description)"
                )
        }
        preconditionFailure(
            "MockHidConnection: validateAllExpectedCommandsConsumed called - \(m_currentExpectedCommandIndex) of \(m_expectedCommands.size()) commands consumed"
        )
    }

    // The configuration of a connection, which MockHidService makes only with one.
    private var hid: Mock.HidConfiguration {
        guard let hid = m_configuration.hid.value else {
            preconditionFailure("A mock HID connection without a HID configuration")
        }
        return hid
    }

    // Changes the configuration on a copy, then stores the copy.
    private func changeHid(_ change: (inout Mock.HidConfiguration) -> Void) {
        var hid = self.hid
        change(&hid)
        m_configuration.hid = .init(hid)
    }

    // Set options.
    private func setRequestOptions(_ payload: borrowing cbor.Bytes) {
        m_requireResidentKey = false
        m_requireUserVerification = false

        var request = makeByteArray(payload)
        assert(!request.isEmpty)
        guard let cmd = fido.CtapRequestCommand(rawValue: request.removeFirst()) else {
            preconditionFailure("an imported C++ enum's init(rawValue:) never fails")
        }
        let options = Optional(fromCxx: WebCore.decodeMockRequestOptions(makeByteVector(request), cmd))
        assert(options != nil || cmd == .authenticatorGetNextAssertion)
        if let requireResidentKey = options?.requireResidentKey.value {
            m_requireResidentKey = requireResidentKey
        }
        if let requireUserVerification = options?.requireUserVerification.value {
            m_requireUserVerification = requireUserVerification
        }
    }

    // The CTAPHID_INIT response: the nonce, a random channel ID and zeros up to the response size.
    private func sendInitResponse() {
        let hid = self.hid
        let stagesMatch = stagesMatch()
        var payload = makeByteArray(m_nonce)
        let writePosition = payload.count
        if stagesMatch && hid.error == .WrongNonce {
            payload[0] &-= 1
        }
        if stagesMatch && hid.error == .ShortInitResponse {
            // Emit an INIT response whose payload matches the requested nonce but is too short
            // to contain the subsequent 4-byte channel ID, to exercise the bounds check in
            // CtapHidDriver::continueAfterChannelAllocated().
            let shortPacket = fido.FidoHidMessage.serializeInitPacket(
                fido.kHidBroadcastChannel,
                .`init`,
                UInt16(fido.kHidInitNonceLength),
                makeByteVector(payload)
            )
            receiveReport(consuming: shortPacket)
            shouldContinueFeedReports()
            return
        }
        payload.append(contentsOf: repeatElement(0, count: fido.kHidInitResponseSize - writePosition))
        for index in writePosition..<(writePosition + fido.kCtapChannelIdSize) {
            payload[index] = UInt8.random(in: .min ... .max)
        }
        var channel = fido.kHidBroadcastChannel
        if stagesMatch && hid.error == .WrongChannelId {
            channel &-= 1
        }
        let initPacket = fido.FidoHidMessage.serializeInitPacket(
            channel,
            .`init`,
            UInt16(truncatingIfNeeded: payload.count),
            makeByteVector(payload)
        )
        receiveReport(consuming: initPacket)
        shouldContinueFeedReports()
    }

    private func infoResponse() -> fido.HidMessageState {
        let hid = self.hid
        // FIXME(205839):
        var fields = fido.GetInfoResponseFields()
        fields.versions.append(consuming: .ctap2)
        if hid.canDowngrade {
            fields.versions.append(consuming: .u2f)
        }
        fields.aaguid = makeByteVector([UInt8](repeating: 0, count: WebCore.aaguidLength))
        if !hid.canDowngrade {
            if hid.supportClientPin {
                fields.pinProtocols = fido.OptionalPinProtocolVector(pinProtocols(hid))
                fields.clientPinAvailability = .supportedAndPinSet
            }
            if hid.supportInternalUV {
                fields.userVerificationAvailability = .supportedAndConfigured
            }
            fields.maxCredentialCountInList = fido.OptionalUInt32(UInt32(truncatingIfNeeded: hid.maxCredentialCountInList))
            fields.maxCredentialIDLength = fido.OptionalUInt32(UInt32(truncatingIfNeeded: hid.maxCredentialIdLength))
        }
        let info = fido.encodeAsCBOR(consuming: fields)
        // Prepend status code.
        let infoData = makeByteVector([fido.CtapDeviceResponseCode.success.rawValue] + makeByteArray(info))

        if stagesMatch() && hid.error == .WrongChannelId {
            return responseMessage(m_currentChannel &- 1, .cbor, infoData)
        }
        if !hid.isU2f {
            return responseMessage(m_currentChannel, .cbor, infoData)
        }
        let invalidCommand = makeByteVector([fido.CtapDeviceResponseCode.ctap1ErrInvalidCommand.rawValue])
        return responseMessage(m_currentChannel, .error, invalidCommand)
    }

    // Order and repeats do not matter: the encoder keeps each protocol once, in enum order.
    private func pinProtocols(_ hid: borrowing Mock.HidConfiguration) -> fido.PinProtocolVector {
        var protocols = fido.PinProtocolVector()
        if hid.pinProtocols.isEmpty() {
            protocols.append(consuming: .pinProtocol1)
            return protocols
        }
        for index in 0..<hid.pinProtocols.size() {
            let protocolNumber = hid.pinProtocols[index]
            if protocolNumber == fido.PINUVAuthProtocol.pinProtocol1.rawValue {
                protocols.append(consuming: .pinProtocol1)
            } else if protocolNumber == fido.PINUVAuthProtocol.pinProtocol2.rawValue {
                protocols.append(consuming: .pinProtocol2)
            }
        }
        return protocols
    }

    // The response to a request, or no message when the response is sent another way or not at all.
    private func requestResponse() -> fido.HidMessageState {
        let hid = self.hid
        if hid.expectCancel {
            return fido.HidMessageState()
        }
        if hid.keepAlive {
            changeHid { $0.keepAlive = false }
            let initPacket = fido.FidoHidMessage.serializeInitPacket(
                m_currentChannel,
                .keepAlive,
                1,
                makeByteVector([fido.kCtapKeepAliveStatusProcessing])
            )
            receiveReport(consuming: initPacket)
            continueFeedReports()
            return fido.HidMessageState()
        }
        if stagesMatch() && hid.error == .UnsupportedOptions && (m_requireResidentKey || m_requireUserVerification) {
            let unsupportedOption = makeByteVector([fido.CtapDeviceResponseCode.ctap2ErrUnsupportedOption.rawValue])
            return responseMessage(m_currentChannel, .cbor, unsupportedOption)
        }

        assert(!hid.payloadBase64.isEmpty())
        let payload = Optional(fromCxx: fido.base64DecodeString(hid.payloadBase64[0]))
        changeHid { $0.payloadBase64.removeAt(0) }
        guard let payload else {
            preconditionFailure("A mock HID payload that is not base64")
        }
        return responseMessage(m_currentChannel, hid.isU2f ? .msg : .cbor, payload)
    }

    private func responseMessage(
        _ channelId: UInt32,
        _ cmd: fido.FidoHidDeviceCommand,
        _ payload: cbor.Bytes
    ) -> fido.HidMessageState {
        var message = fido.HidMessageState()
        message.valid = true
        message.channelId = channelId
        message.cmd = cmd
        message.payload = payload
        return message
    }
}

#endif // ENABLE_WEB_AUTHN
