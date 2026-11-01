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
import WebCore_Internal.CDMRequirement
import WebCore_Internal.CDMSessionType
import WebCore_Internal.EMEParseResults
import WebCore_Internal.ISOParseResults
import WebCore_Internal.MediaParsersCxxBridging

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

    // An entry of the "sinf" array of 'sinf' init data is the payload of a 'sinf' box in base64, which may contain
    // whitespace, and whose padding is optional but checked when present.
    static func decodeSinf(_ base64: Span<UInt8>) -> ContiguousArray<UInt8>? {
        WTFBase64.decode(base64, options: [.validatePadding, .ignoreWhitespace])
    }

    static func decodeSinf(_ base64: Span<UInt16>) -> ContiguousArray<UInt8>? {
        WTFBase64.decode(base64, options: [.validatePadding, .ignoreWhitespace])
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

// One base64 entry of the "sinf" array of 'sinf' init data. True when its boxes have a scheme and a key ID; the 16
// bytes of the key ID are then appended to keyIDs if the scheme is valid.
@_expose(Cxx)
func fairPlaySinfKeyIDLatin1Impl(_ base64Sinf: borrowing WebCore.MediaParserLatin1, _ keyIDs: inout WebCore.MediaParserByteVector) -> Bool {
    let characters: Span<UInt8> = base64Sinf.span()
    return FairPlayStreamingParsing.appendKeyID(sinfPayload: FairPlayStreamingParsing.decodeSinf(characters), to: &keyIDs)
}

@_expose(Cxx)
func fairPlaySinfKeyIDUTF16Impl(_ base64Sinf: borrowing WebCore.MediaParserUTF16, _ keyIDs: inout WebCore.MediaParserByteVector) -> Bool {
    let characters: Span<UInt16> = base64Sinf.span()
    return FairPlayStreamingParsing.appendKeyID(sinfPayload: FairPlayStreamingParsing.decodeSinf(characters), to: &keyIDs)
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
