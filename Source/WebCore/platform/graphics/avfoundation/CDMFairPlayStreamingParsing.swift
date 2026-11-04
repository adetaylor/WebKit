// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.CDMRequirement
import WebCore_Private.Core.CDMSessionType
import WebCore_Private.Core.EMEParseResults
import WebCore_Private.Core.ISOParseResults
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCoreEME
import wtf

// The names this file compares with, packed for MediaParserName comparisons.
private enum FairPlayNames {
    static let sinf = MediaParserName("sinf")
    static let skd = MediaParserName("skd")
    static let cenc = MediaParserName("cenc")
    static let mpts = MediaParserName("mpts")
}

// The parsing and the decisions of the FairPlay Streaming CDM. CDMFairPlayStreaming.cpp keeps the JSON and the
// AVFoundation queries.
enum FairPlayStreamingParsing {
    // 'cbcs', 'cbc2', 'cbc1' and 'cenc'.
    static let validSchemes: ContiguousArray<UInt32> = [0x6362_6373, 0x6362_6332, 0x6362_6331, 0x6365_6E63]

    static func isValidScheme(_ scheme: UInt32) -> Bool {
        validSchemes.contains(scheme)
    }

    // Init data type names are compared case-sensitively.
    static func initDataType(_ name: WebCore.MediaParserShortName) -> WebCore.FairPlayInitDataType {
        if FairPlayNames.sinf.matches(name) {
            return .Sinf
        }
        if FairPlayNames.skd.matches(name) {
            return .Skd
        }
        #if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
        if FairPlayNames.cenc.matches(name) {
            return .Cenc
        }
        #endif
        #if HAVE_FAIRPLAYSTREAMING_MTPS_INITDATA
        if FairPlayNames.mpts.matches(name) {
            return .Mpts
        }
        #endif
        return .Other
    }

    // The scheme of the last 'schm' box and the default key ID of the last 'schi' box with a 'tenc' box, among the
    // boxes of a 'sinf' payload; nil unless there are both. The walk ends at a 'schm' or 'schi' box that doesn't parse,
    // keeping what it found before, and steps over other boxes by their size, which may be 1 to 7.
    static func schemeAndKeyID(sinfPayload: Span<UInt8>) -> (scheme: UInt32, keyID: WebCore.InlineBytes16)? {
        var offset: UInt32 = 0
        var scheme: UInt32?
        var keyID: WebCore.InlineBytes16?
        while let box = ISOBoxHeader.peek(sinfPayload, at: offset) {
            if box.type == SchemeTypeBox.boxType {
                guard let schemeType = SchemeTypeBox.read(sinfPayload, at: &offset) else {
                    break
                }
                scheme = schemeType.schemeType
                continue
            }
            if box.type == SchemeInformationBox.boxType {
                guard let schemeInformation = SchemeInformationBox.read(sinfPayload, at: &offset) else {
                    break
                }
                if let trackEncryption = schemeInformation.trackEncryption {
                    keyID = trackEncryption.defaultKID
                }
                continue
            }
            // A peeked size never goes past the end of the bytes, whose size fits in 32 bits.
            offset &+= UInt32(truncatingIfNeeded: box.size)
        }
        guard let scheme, let keyID else {
            return nil
        }
        return (scheme, keyID)
    }

    // For one decoded "sinf" entry: true when it has a scheme and a key ID, and then the key ID is appended to keyIDs
    // if the scheme is valid. So init data whose entries all have invalid schemes has a result with no key IDs, unlike
    // init data with no scheme and key ID at all.
    static func appendKeyID(sinfPayload: ContiguousArray<UInt8>?, to keyIDs: inout WebCore.MediaParserByteVector) -> Bool {
        guard let sinfPayload, let result = schemeAndKeyID(sinfPayload: sinfPayload.span) else {
            return false
        }
        if isValidScheme(result.scheme) {
            result.keyID.append(to: &keyIDs)
        }
        return true
    }

    static func configurationSupport(_ configuration: WebCore.FairPlayConfiguration) -> WebCore.FairPlayConfigurationSupport {
        if !configuration.hasSupportedInitDataType {
            return .NoSupportedInitDataType
        }
        #if HAVE_AVCONTENTKEYSESSION
        // FIXME: verify that FairPlayStreaming does not (and cannot) expose a distinctive identifier to the client
        if configuration.distinctiveIdentifier == .Required {
            return .DistinctiveIdentifierRequired
        }
        if configuration.persistentState == .Required && !configuration.supportsPersistableState {
            return .PersistentStateUnsupported
        }
        let sessionTypes = configuration.sessionTypes
        if sessionTypes.persistentLicense && !sessionTypes.temporary && !configuration.supportsPersistentKeys {
            return .PersistentLicenseUnsupported
        }
        if configuration.hasAudioCapabilities && !configuration.hasSupportedAudioCapability {
            return .NoSupportedAudioCapability
        }
        if configuration.hasVideoCapabilities && !configuration.hasSupportedVideoCapability {
            return .NoSupportedVideoCapability
        }
        return .Supported
        #else
        return .NoContentKeySession
        #endif
    }

    // Denied persistent state rules out every session type but 'temporary', and required persistent state. A
    // configuration whose session types are all denied, which includes having none, is ruled out too.
    static func allowsRestrictions(
        persistentState: WebCore.CDMRequirement,
        sessionTypes: WebCore.FairPlaySessionTypes,
        persistentStateDenied: Bool,
        deniedSessionTypes: WebCore.FairPlaySessionTypes
    ) -> Bool {
        let hasSessionTypes = sessionTypes.temporary || sessionTypes.persistentUsageRecord || sessionTypes.persistentLicense
        if persistentStateDenied && hasSessionTypes && !sessionTypes.temporary {
            return false
        }
        if persistentStateDenied && persistentState == .Required {
            return false
        }
        let allSessionTypesDenied =
            (!sessionTypes.temporary || deniedSessionTypes.temporary)
            && (!sessionTypes.persistentUsageRecord || deniedSessionTypes.persistentUsageRecord)
            && (!sessionTypes.persistentLicense || deniedSessionTypes.persistentLicense)
        return !allSessionTypesDenied
    }

    // A temporary session can't have required persistent state, and the other session types need persistent state.
    static func supportsSessionType(_ sessionType: WebCore.CDMSessionType, persistentState: WebCore.CDMRequirement) -> Bool {
        if sessionType == .Temporary {
            return persistentState != .Required
        }
        return persistentState != .NotAllowed
    }
}

// The key IDs of 'sinf' and 'mpts' init data. For 'sinf' init data, true when some entry has a scheme and a key ID; the
// 16 bytes of each such key ID with a valid scheme are appended to keyIDs. For 'mpts' init data, whether it is valid; its
// key ID is the C++ mptsKeyIDs(). False for other types.
@_expose(Cxx)
func fairPlayInitDataKeyIDsImpl(
    _ type: WebCore.FairPlayInitDataType,
    _ initData: borrowing WebCore.MediaParserBytes,
    _ keyIDs: inout WebCore.MediaParserByteVector
) -> Bool {
    let bytes: Span<UInt8> = initData.span()
    switch type {
    case .Sinf:
        guard let payloads = FairPlayJSON.sinfPayloads(bytes) else {
            return false
        }
        var hasSchemeAndKeyID = false
        for payload in payloads where FairPlayStreamingParsing.appendKeyID(sinfPayload: payload, to: &keyIDs) {
            hasSchemeAndKeyID = true
        }
        return hasSchemeAndKeyID
    case .Mpts:
        return FairPlayJSON.isMptsInitData(bytes)
    default:
        return false
    }
}

// False unless the 'cenc' license response is a JSON array. Each element appends its FairPlayCencResponseEntryStage, key
// ID size, payload size and error code to fields, and its key ID and payload to bytes.
@_expose(Cxx)
func fairPlayCencResponseImpl(
    _ response: borrowing WebCore.MediaParserBytes,
    _ fields: inout WebCore.MediaParserUInt32Vector,
    _ bytes: inout WebCore.MediaParserByteVector
) -> Bool {
    let responseBytes: Span<UInt8> = response.span()
    guard let entries = FairPlayJSON.cencResponse(responseBytes) else {
        return false
    }
    for entry in entries {
        let (stage, keyID, payload, code): (WebCore.FairPlayCencResponseEntryStage, ContiguousArray<UInt8>, ContiguousArray<UInt8>, Int32) =
            switch entry {
            case .noKeyID:
                (.NoKeyID, [], [], 0)
            case .keyIDOnly(let keyID):
                (.KeyIDOnly, keyID, [], 0)
            case .payload(let keyID, let payload):
                (.Payload, keyID, payload, 0)
            case .error(let keyID, let code):
                (.Error, keyID, [], code)
            }
        fields.append(consuming: stage.rawValue)
        fields.append(consuming: UInt32(truncatingIfNeeded: keyID.count))
        fields.append(consuming: UInt32(truncatingIfNeeded: payload.count))
        fields.append(consuming: UInt32(bitPattern: code))
        for part in [keyID, payload] where !part.isEmpty {
            WebCore.appendBytes(&bytes, part.span)
        }
    }
    return true
}

// The 'cenc' license request for key IDs and their requests' data, appended to message: requests holds each key ID and
// then its data, back to back, and sizes their sizes in the same order.
@_expose(Cxx)
func fairPlayCencRequestImpl(
    _ requests: borrowing WebCore.MediaParserBytes,
    _ sizes: borrowing WebCore.MediaParserUInt32Vector,
    _ message: inout WebCore.MediaParserByteVector
) {
    let bytes: Span<UInt8> = requests.span()
    let partSizes: Span<UInt32> = sizes.span()
    var request = ContiguousArray<UInt8>()
    var offset = 0
    var count = 0
    var index = 0
    while index + 1 < partSizes.count {
        let keyIDEnd = offset + Int(partSizes[index])
        let payloadEnd = keyIDEnd + Int(partSizes[index + 1])
        FairPlayJSON.appendCencRequest(
            keyID: bytes.extracting(offset..<keyIDEnd),
            payload: bytes.extracting(keyIDEnd..<payloadEnd),
            isFirst: count == 0,
            to: &request
        )
        offset = payloadEnd
        count += 1
        index += 2
    }
    FairPlayJSON.endCencRequest(count: count, to: &request)
    WebCore.appendBytes(&message, request.span)
}

@_expose(Cxx)
func fairPlayInitDataTypeImpl(_ name: WebCore.MediaParserShortName) -> WebCore.FairPlayInitDataType {
    FairPlayStreamingParsing.initDataType(name)
}

@_expose(Cxx)
func fairPlayConfigurationSupportImpl(_ configuration: WebCore.FairPlayConfiguration) -> WebCore.FairPlayConfigurationSupport {
    FairPlayStreamingParsing.configurationSupport(configuration)
}

@_expose(Cxx)
func fairPlayAllowsRestrictionsImpl(
    _ persistentState: WebCore.CDMRequirement,
    _ sessionTypes: WebCore.FairPlaySessionTypes,
    _ persistentStateDenied: Bool,
    _ deniedSessionTypes: WebCore.FairPlaySessionTypes
) -> Bool {
    FairPlayStreamingParsing.allowsRestrictions(
        persistentState: persistentState,
        sessionTypes: sessionTypes,
        persistentStateDenied: persistentStateDenied,
        deniedSessionTypes: deniedSessionTypes
    )
}

@_expose(Cxx)
func fairPlaySupportsSessionTypeImpl(_ sessionType: WebCore.CDMSessionType, _ persistentState: WebCore.CDMRequirement) -> Bool {
    FairPlayStreamingParsing.supportsSessionType(sessionType, persistentState: persistentState)
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA
