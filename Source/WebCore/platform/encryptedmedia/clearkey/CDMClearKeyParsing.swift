// Copyright (C) 2016 Metrological Group B.V.
// Copyright (C) 2016 Igalia S.L.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above
//    copyright notice, this list of conditions and the following
//    disclaimer in the documentation and/or other materials provided
//    with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Internal.CDMRequirement
import WebCore_Internal.CDMSessionType
import WebCore_Internal.EMEParseResults
import WebCore_Internal.MediaParsersCxxBridging

// The names this file compares with, packed for MediaParserName comparisons.
private enum ClearKeyNames {
    static let keySystem = MediaParserName("org.w3.clearkey")
    static let keyids = MediaParserName("keyids")
    static let cenc = MediaParserName("cenc")
    static let webm = MediaParserName("webm")
    static let oct = MediaParserName("oct")
}

// The parsing and the decisions of the ClearKey CDM. CDMClearKey.cpp keeps the JSON, the key store and the sessions.
enum ClearKeyParsing {
    // https://www.w3.org/TR/eme-initdata-cenc/#common-system: 1077efec-c0b2-4d02-ace3-3c1e52e2fb4b.
    private static let cencSystemIDHigh: UInt64 = 0x1077_EFEC_C0B2_4D02
    private static let cencSystemIDLow: UInt64 = 0xACE3_3C1E_52E2_FB4B
    private static let systemIDSize: UInt32 = 16
    private static let keyIDSize: UInt32 = 16
    // A box header and a full box header.
    private static let psshHeaderSize: UInt32 = 12

    static func supportsKeySystem(_ keySystem: WebCore.MediaParserShortName) -> Bool {
        ClearKeyNames.keySystem.matchesIgnoringASCIICase(keySystem)
    }

    static func initDataType(_ name: WebCore.MediaParserShortName) -> WebCore.ClearKeyInitDataType {
        if ClearKeyNames.keyids.matchesIgnoringASCIICase(name) {
            return .KeyIDs
        }
        if ClearKeyNames.cenc.matchesIgnoringASCIICase(name) {
            return .Cenc
        }
        if ClearKeyNames.webm.matchesIgnoringASCIICase(name) {
            return .WebM
        }
        return .Other
    }

    static func supportsInitData(
        _ type: WebCore.ClearKeyInitDataType,
        _ initData: Span<UInt8>,
        initDataIsJSONObject: Bool
    ) -> Bool {
        switch type {
        case .KeyIDs:
            return initDataIsJSONObject
        case .Cenc:
            return cencKeyIDs(initData) != nil
        case .WebM:
            return !initData.isEmpty
        case .Other:
            return false
        @unknown default:
            return false
        }
    }

    // A cenc request lists the key IDs of the ClearKey pssh box, and a WebM request the init data, which is a key ID.
    // Other init data is the request itself.
    static func licenseRequest(_ type: WebCore.ClearKeyInitDataType, _ initData: Span<UInt8>) -> WebCore.ClearKeyLicenseRequest {
        var request = WebCore.ClearKeyLicenseRequest()
        switch type {
        case .Cenc:
            if let keyIDs = cencKeyIDs(initData) {
                request.firstKeyIDOffset = keyIDs.firstOffset
                request.keyIDSize = keyIDSize
                request.keyIDCount = keyIDs.count
            }
        case .WebM:
            if !initData.isEmpty, let size = UInt32(exactly: initData.count) {
                request.keyIDSize = size
                request.keyIDCount = 1
            }
        case .KeyIDs, .Other:
            request.initDataIsRequest = true
        @unknown default:
            request.initDataIsRequest = true
        }
        return request
    }

    // The search for the ClearKey pssh box in concatenated cenc init data: a box size is its low 16 bits, the key ID
    // count its low byte, each bounds check needs at least one byte past what it reads, and the arithmetic is 32-bit
    // unsigned. nil when there is no such box, or it has no key IDs or they don't fit.
    static func cencKeyIDs(_ data: Span<UInt8>) -> (count: UInt32, firstOffset: UInt32)? {
        guard !data.isEmpty, let size = UInt32(exactly: data.count) else {
            return nil
        }

        var index: UInt32 = 0
        while true {
            // Adds the header size in 32 bits, wrapping, and then the system ID size in 64.
            guard UInt64(index &+ psshHeaderSize) + UInt64(systemIDSize) < UInt64(size),
                let sizeHigh = byte(data, index &+ 2), let sizeLow = byte(data, index &+ 3)
            else {
                return nil
            }
            let psshSize = UInt32(sizeHigh) << 8 | UInt32(sizeLow)
            if psshSize == 0 {
                return nil
            }
            if hasCencSystemID(data, at: index &+ psshHeaderSize) {
                break
            }
            index &+= psshSize
        }

        index &+= psshHeaderSize &+ systemIDSize
        guard index &+ 3 < size, let countByte = byte(data, index &+ 3) else {
            return nil
        }
        let count = UInt32(countByte)
        index &+= 4
        guard count != 0, index != 0, index &+ count &* keyIDSize < size else {
            return nil
        }
        return (count, index)
    }

    // parseInteger<uint32_t>(sessionId).
    static func isValidSessionID<CodeUnit: WTFCodeUnit>(_ sessionID: Span<CodeUnit>) -> Bool {
        sessionID.parseInteger(UInt32.self) != nil
    }

    // The "kty" of a JSON Web Key for a symmetric key.
    static func isOctKeyType(_ keyType: WebCore.MediaParserShortName) -> Bool {
        ClearKeyNames.oct.matchesIgnoringASCIICase(keyType)
    }

    // https://www.w3.org/TR/encrypted-media/#clear-key-license-format: a "keys" array of valid keys is a license.
    // Anything else with a "kids" array is a release acknowledgement, even with invalid keys.
    static func classifyUpdate(hasKeysArray: Bool, keysAreValid: Bool, hasKidsArray: Bool) -> WebCore.ClearKeyUpdateKind {
        if hasKeysArray && keysAreValid {
            return .License
        }
        if hasKidsArray {
            return .ReleaseAcknowledgement
        }
        return .Invalid
    }

    // Distinctive identifiers can't be required, or optional when denied. Persistent state can't be optional when
    // denied, or required without the 'persistent-license' session type.
    static func supportsConfiguration(_ configuration: WebCore.ClearKeyConfiguration) -> Bool {
        let distinctiveIdentifier = configuration.distinctiveIdentifier
        let persistentState = configuration.persistentState
        if distinctiveIdentifier == .Required || (distinctiveIdentifier == .Optional && configuration.distinctiveIdentifierDenied) {
            return false
        }
        if persistentState == .Optional && configuration.persistentStateDenied {
            return false
        }
        if persistentState == .Required && !configuration.sessionTypesIncludePersistentLicense {
            return false
        }
        return true
    }

    static func supportsSessionType(_ sessionType: WebCore.CDMSessionType) -> Bool {
        sessionType == .Temporary || sessionType == .PersistentLicense
    }

    // For distinctive identifiers and for persistent state.
    static func requirement(denied: Bool) -> WebCore.CDMRequirement {
        denied ? .NotAllowed : .Optional
    }

    static func initializationSucceeds(allowsDistinctiveIdentifiers: Bool, allowsPersistentState: Bool) -> Bool {
        !allowsDistinctiveIdentifiers && !allowsPersistentState
    }

    private static func byte(_ data: Span<UInt8>, _ index: UInt32) -> UInt8? {
        Int(index) < data.count ? data[Int(index)] : nil
    }

    private static func hasCencSystemID(_ data: Span<UInt8>, at offset: UInt32) -> Bool {
        let cursor = ByteCursor(data)
        return cursor.uint64(at: Int(offset)) == cencSystemIDHigh && cursor.uint64(at: Int(offset) + 8) == cencSystemIDLow
    }
}

@_expose(Cxx)
func clearKeySupportsKeySystemImpl(_ keySystem: WebCore.MediaParserShortName) -> Bool {
    ClearKeyParsing.supportsKeySystem(keySystem)
}

@_expose(Cxx)
func clearKeyInitDataTypeImpl(_ name: WebCore.MediaParserShortName) -> WebCore.ClearKeyInitDataType {
    ClearKeyParsing.initDataType(name)
}

// supportsInitData() in one call: the type, and whether the init data is supported unless the type is keyids, whose JSON
// the C++ checks.
@_expose(Cxx)
func clearKeySupportsInitDataImpl(
    _ name: WebCore.MediaParserShortName,
    _ initData: borrowing WebCore.MediaParserBytes
) -> WebCore.ClearKeyInitDataSupport {
    let bytes: Span<UInt8> = initData.span()
    var result = WebCore.ClearKeyInitDataSupport()
    result.type = ClearKeyParsing.initDataType(name)
    result.supported = ClearKeyParsing.supportsInitData(result.type, bytes, initDataIsJSONObject: false)
    return result
}

@_expose(Cxx)
func clearKeyLicenseRequestImpl(
    _ type: WebCore.ClearKeyInitDataType,
    _ initData: borrowing WebCore.MediaParserBytes
) -> WebCore.ClearKeyLicenseRequest {
    let bytes: Span<UInt8> = initData.span()
    return ClearKeyParsing.licenseRequest(type, bytes)
}

@_expose(Cxx)
func clearKeyIsValidSessionIDLatin1Impl(_ sessionID: borrowing WebCore.MediaParserLatin1) -> Bool {
    let characters: Span<UInt8> = sessionID.span()
    return ClearKeyParsing.isValidSessionID(characters)
}

@_expose(Cxx)
func clearKeyIsValidSessionIDUTF16Impl(_ sessionID: borrowing WebCore.MediaParserUTF16) -> Bool {
    let characters: Span<UInt16> = sessionID.span()
    return ClearKeyParsing.isValidSessionID(characters)
}

@_expose(Cxx)
func clearKeyIsOctKeyTypeImpl(_ keyType: WebCore.MediaParserShortName) -> Bool {
    ClearKeyParsing.isOctKeyType(keyType)
}

// keysAreValid: every element of "keys" is an object whose "kty" is "oct" and whose "kid" and "k" decode as base64url.
@_expose(Cxx)
func clearKeyClassifyUpdateImpl(_ hasKeysArray: Bool, _ keysAreValid: Bool, _ hasKidsArray: Bool) -> WebCore.ClearKeyUpdateKind {
    ClearKeyParsing.classifyUpdate(hasKeysArray: hasKeysArray, keysAreValid: keysAreValid, hasKidsArray: hasKidsArray)
}

@_expose(Cxx)
func clearKeySupportsConfigurationImpl(_ configuration: WebCore.ClearKeyConfiguration) -> Bool {
    ClearKeyParsing.supportsConfiguration(configuration)
}

@_expose(Cxx)
func clearKeySupportsSessionTypeImpl(_ sessionType: WebCore.CDMSessionType) -> Bool {
    ClearKeyParsing.supportsSessionType(sessionType)
}

@_expose(Cxx)
func clearKeyRequirementImpl(_ denied: Bool) -> WebCore.CDMRequirement {
    ClearKeyParsing.requirement(denied: denied)
}

@_expose(Cxx)
func clearKeyInitializationSucceedsImpl(_ allowsDistinctiveIdentifiers: Bool, _ allowsPersistentState: Bool) -> Bool {
    ClearKeyParsing.initializationSucceeds(
        allowsDistinctiveIdentifiers: allowsDistinctiveIdentifiers,
        allowsPersistentState: allowsPersistentState
    )
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA
