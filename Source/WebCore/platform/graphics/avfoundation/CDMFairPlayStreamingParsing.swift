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
import WebCore_Private.Core.CDMEncryptionScheme
import WebCore_Private.Core.CDMRequirement
import WebCore_Private.Core.CDMSessionType
import WebCore_Private.Core.EMEParseResults
import WebCore_Private.Core.ISOParseResults
import WebCore_Private.Core.MediaParsersCxxBridging
public import WebCoreEME
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

    // The key IDs of 'sinf' init data are the default key IDs of 'tenc' boxes.
    static let sinfKeyIDSize = 16

    // The key ID of valid 'mpts' init data.
    static let mptsKeyID = ContiguousArray("TransportStreamIdentifier".utf8)

    // True when some entry of 'sinf' init data has a scheme and a key ID; the key IDs with a valid scheme are appended
    // to keyIDs.
    static func sinfKeyIDs(_ initData: Span<UInt8>, into keyIDs: inout WebCore.MediaParserByteVector) -> Bool {
        guard let payloads = FairPlayJSON.sinfPayloads(initData) else {
            return false
        }
        var hasSchemeAndKeyID = false
        for payload in payloads where appendKeyID(sinfPayload: payload, to: &keyIDs) {
            hasSchemeAndKeyID = true
        }
        return hasSchemeAndKeyID
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

    // configurationSupport() with AVFoundation's answers that don't depend on the configuration.
    static func platformConfigurationSupport(_ configuration: WebCore.FairPlayConfiguration) -> WebCore.FairPlayConfigurationSupport {
        var configuration = configuration
        #if HAVE_AVCONTENTKEYSESSION
        configuration.supportsPersistableState = FairPlayAVFoundation.supportsPersistableState
        configuration.supportsPersistentKeys = FairPlayAVFoundation.supportsPersistentKeys
        #endif
        return configurationSupport(configuration)
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

    // The type of an init data type name, as mediaParserShortName() packs a WTF::String's code units.
    static func initDataType(_ name: Swift.String?) -> WebCore.FairPlayInitDataType {
        var shortName = WebCore.MediaParserShortName()
        let units = Array((name ?? "").utf16)
        if units.count <= 16 {
            for (index, unit) in units.enumerated() {
                let byte = UInt64(unit <= 0xFF ? unit : 0xFF) << UInt64(8 * (index & 7))
                if index < 8 {
                    shortName.words.0 |= byte.littleEndian
                } else {
                    shortName.words.1 |= byte.littleEndian
                }
            }
            shortName.length = UInt8(units.count)
        }
        return initDataType(shortName)
    }

    // Whether some entry of 'sinf' init data has a valid scheme and a key ID.
    static func sinfHasKeyID(_ initData: Span<UInt8>) -> Bool {
        guard let payloads = FairPlayJSON.sinfPayloads(initData) else {
            return false
        }
        return payloads.contains { payload in
            guard let payload, let result = schemeAndKeyID(sinfPayload: payload.span) else {
                return false
            }
            return isValidScheme(result.scheme)
        }
    }

    // CDMPrivate::supportsInitData().
    static func supportsInitData(_ type: WebCore.FairPlayInitDataType, _ initData: Span<UInt8>) -> Bool {
        switch type {
        case .Sinf:
            return sinfHasKeyID(initData)
        case .Cenc:
            #if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
            return InitDataParsing.parseCenc(initData)?.hasFairPlayPssh ?? false
            #else
            return false
            #endif
        case .Skd, .Mpts:
            return true
        case .Other:
            return false
        @unknown default:
            return false
        }
    }

    // A temporary session can't have required persistent state, and the other session types need persistent state.
    static func supportsSessionType(_ sessionType: WebCore.CDMSessionType, persistentState: WebCore.CDMRequirement) -> Bool {
        if sessionType == .Temporary {
            return persistentState != .Required
        }
        return persistentState != .NotAllowed
    }
}

/// What the FairPlay Streaming CDM reports of itself, as CDMPrivateFairPlayStreaming does, and its key systems.
///
/// For CDMFairPlayStreaming.cpp and the GPU process's EME receivers. It keeps responses and session IDs as they are
/// (CDMPrivateFairPlayStreaming::sanitizeResponse() and sanitizeSessionId()).
@_spi(WebKitGPU)
public enum FairPlayCDM {
    /// CDMPrivate::supportedInitDataTypes().
    @_spi(WebKitGPU)
    public static let supportedInitDataTypes: [Swift.String] = {
        var types = ["sinf", "skd"]
        #if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
        types.append("cenc")
        #endif
        #if HAVE_FAIRPLAYSTREAMING_MTPS_INITDATA
        types.append("mpts")
        #endif
        return types
    }()
    /// CDMPrivate::supportedRobustnesses(): only the empty robustness.
    @_spi(WebKitGPU)
    public static let supportedRobustnesses = [""]
    /// CDMPrivate::supportsServerCertificates().
    @_spi(WebKitGPU)
    public static let supportsServerCertificates = true
    /// CDMPrivate::supportsSessions().
    @_spi(WebKitGPU)
    public static let supportsSessions = true

    private static let keySystem: ContiguousArray<UInt8> = ContiguousArray("com.apple.fps".utf8)

    /// CDMFactory::supportsKeySystem(): "com.apple.fps", or one that starts with "com.apple.fps.".
    ///
    /// Key systems compare case-sensitively (https://w3c.github.io/encrypted-media/#key-system). The check reads a key
    /// system's length and no more than its first 14 code units, which prefix has, or all of them if it has fewer.
    static func supportsKeySystem<CodeUnit: FixedWidthInteger & UnsignedInteger>(prefix: Span<CodeUnit>, length: Int) -> Bool {
        let nameLength = keySystem.count
        guard length >= nameLength, prefix.count >= min(length, nameLength + 1) else {
            return false
        }
        for index in 0..<nameLength where prefix[index] != CodeUnit(keySystem[index]) {
            return false
        }
        return length == nameLength || prefix[nameLength] == CodeUnit(UInt8(ascii: "."))
    }

    /// CDMPrivate::supportsInitData().
    @_spi(WebKitGPU)
    public static func supportsInitData(_ initDataType: Swift.String?, _ initData: Span<UInt8>) -> Bool {
        FairPlayStreamingParsing.supportsInitData(FairPlayStreamingParsing.initDataType(initDataType), initData)
    }

    /// CDMPrivateFairPlayStreaming's answers for the configuration algorithm.
    @_spi(WebKitGPU)
    public struct ConfigurationAnswers: EMECDMConfigurationAnswers {
        @_spi(WebKitGPU)
        public init() {
        }

        public var supportedInitDataTypes: [Swift.String] {
            FairPlayCDM.supportedInitDataTypes
        }

        public var supportedRobustnesses: [Swift.String] {
            FairPlayCDM.supportedRobustnesses
        }

        private func fairPlayConfiguration(_ configuration: EMEKeySystemConfiguration) -> WebCore.FairPlayConfiguration {
            var result = WebCore.FairPlayConfiguration()
            result.hasSupportedInitDataType = configuration.initDataTypes.contains {
                FairPlayStreamingParsing.initDataType($0) != .Other
            }
            result.distinctiveIdentifier = cdmRequirement(configuration.distinctiveIdentifier)
            result.persistentState = cdmRequirement(configuration.persistentState)
            result.sessionTypes = fairPlaySessionTypes(configuration.sessionTypes)
            result.hasAudioCapabilities = !configuration.audioCapabilities.isEmpty
            result.hasVideoCapabilities = !configuration.videoCapabilities.isEmpty
            #if HAVE_AVCONTENTKEYSESSION
            result.hasSupportedAudioCapability = configuration.audioCapabilities.contains(where: supportsMediaCapability)
            result.hasSupportedVideoCapability = configuration.videoCapabilities.contains(where: supportsMediaCapability)
            #endif
            return result
        }

        #if HAVE_AVCONTENTKEYSESSION
        private func supportsMediaCapability(_ capability: EMEMediaCapability) -> Bool {
            FairPlayAVFoundation.supportsMediaCapability(contentType: capability.contentType ?? "", encryptionScheme: capability.encryptionScheme)
        }
        #endif

        public func supportsConfiguration(_ configuration: EMEKeySystemConfiguration) -> Bool {
            FairPlayStreamingParsing.platformConfigurationSupport(fairPlayConfiguration(configuration)) == .Supported
        }

        public func supportsConfiguration(_ configuration: EMEKeySystemConfiguration, restrictions: EMERestrictions) -> Bool {
            let allowed = FairPlayStreamingParsing.allowsRestrictions(
                persistentState: cdmRequirement(configuration.persistentState),
                sessionTypes: fairPlaySessionTypes(configuration.sessionTypes),
                persistentStateDenied: restrictions.persistentStateDenied,
                deniedSessionTypes: WebCore.FairPlaySessionTypes()
            )
            return allowed && supportsConfiguration(configuration)
        }

        public func supportsSessionType(_ sessionType: EMESessionType, configuration: EMEKeySystemConfiguration) -> Bool {
            FairPlayStreamingParsing.supportsSessionType(cdmSessionType(sessionType), persistentState: cdmRequirement(configuration.persistentState))
                && supportsConfiguration(configuration)
        }

        // FIXME: verify that FairPlayStreaming does not (and cannot) expose a distinctive identifier to the client
        public func distinctiveIdentifiersRequirement(_ configuration: EMEKeySystemConfiguration, restrictions: EMERestrictions) -> EMERequirement {
            .notAllowed
        }

        public func persistentStateRequirement(_ configuration: EMEKeySystemConfiguration, restrictions: EMERestrictions) -> EMERequirement {
            .optional
        }

        public func distinctiveIdentifiersAreUniquePerOriginAndClearable(_ configuration: EMEKeySystemConfiguration) -> Bool {
            true
        }
    }

    /// supportsKeySystem() of a Swift string, whose UTF-16 code units are a WTF::String's.
    @_spi(WebKitGPU)
    public static func supportsKeySystem(_ keySystem: Swift.String?) -> Bool {
        let codeUnits = ContiguousArray((keySystem ?? "").utf16)
        return supportsKeySystem(prefix: codeUnits.span, length: codeUnits.count)
    }
}

// CDMFactoryFairPlayStreaming::supportsKeySystem() of a key system's first MediaParserShortName.capacity characters, and
// its length.
@_expose(Cxx)
func fairPlaySupportsKeySystemImpl(_ prefix: WebCore.MediaParserShortName, _ length: UInt64) -> Bool {
    var characters = ContiguousArray<UInt8>()
    for index in 0..<Int(prefix.length) {
        let word = UInt64(littleEndian: index < 8 ? prefix.words.0 : prefix.words.1)
        characters.append(UInt8(truncatingIfNeeded: word >> UInt64(8 * (index & 7))))
    }
    return FairPlayCDM.supportsKeySystem(prefix: characters.span, length: Int(clamping: length))
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
        return FairPlayStreamingParsing.sinfKeyIDs(bytes, into: &keyIDs)
    case .Mpts:
        return FairPlayJSON.isMptsInitData(bytes)
    default:
        return false
    }
}

@_expose(Cxx)
func fairPlayInitDataTypeImpl(_ name: WebCore.MediaParserShortName) -> WebCore.FairPlayInitDataType {
    FairPlayStreamingParsing.initDataType(name)
}

@_expose(Cxx)
func fairPlayConfigurationSupportImpl(_ configuration: WebCore.FairPlayConfiguration) -> WebCore.FairPlayConfigurationSupport {
    FairPlayStreamingParsing.platformConfigurationSupport(configuration)
}

@_expose(Cxx)
func fairPlaySupportsMediaCapabilityImpl(
    _ contentType: borrowing WebCore.MediaParserText,
    _ hasEncryptionScheme: Bool,
    _ encryptionScheme: WebCore.CDMEncryptionScheme
) -> Bool {
    #if HAVE_AVCONTENTKEYSESSION
    let scheme: EMEEncryptionScheme? = hasEncryptionScheme ? (encryptionScheme == .cbcs ? .cbcs : .cenc) : nil
    return FairPlayAVFoundation.supportsMediaCapability(contentType: fairPlayString(contentType), encryptionScheme: scheme)
    #else
    return false
    #endif
}

@_expose(Cxx)
func fairPlaySupportsInitDataImpl(_ type: WebCore.MediaParserShortName, _ initData: borrowing WebCore.MediaParserBytes) -> Bool {
    let bytes: Span<UInt8> = initData.span()
    return FairPlayStreamingParsing.supportsInitData(FairPlayStreamingParsing.initDataType(type), bytes)
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


private func cdmRequirement(_ requirement: EMERequirement) -> WebCore.CDMRequirement {
    switch requirement {
    case .required:
        .Required
    case .optional:
        .Optional
    case .notAllowed:
        .NotAllowed
    }
}

private func cdmSessionType(_ sessionType: EMESessionType) -> WebCore.CDMSessionType {
    switch sessionType {
    case .temporary:
        .Temporary
    case .persistentUsageRecord:
        .PersistentUsageRecord
    case .persistentLicense:
        .PersistentLicense
    }
}

private func fairPlaySessionTypes(_ sessionTypes: [EMESessionType]) -> WebCore.FairPlaySessionTypes {
    var result = WebCore.FairPlaySessionTypes()
    result.temporary = sessionTypes.contains(.temporary)
    result.persistentUsageRecord = sessionTypes.contains(.persistentUsageRecord)
    result.persistentLicense = sessionTypes.contains(.persistentLicense)
    return result
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA
