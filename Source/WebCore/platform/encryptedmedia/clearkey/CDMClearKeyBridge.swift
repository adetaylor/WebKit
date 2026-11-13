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
import WebCore_Private.Core.CDMRequirement
import WebCore_Private.Core.CDMSessionType
import WebCore_Private.Core.EMEParseResults
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCoreEME
import wtf

// What CDMClearKey.cpp's CDMFactory, CDMPrivate, CDMInstance and CDMInstanceSession call; the ClearKey CDM is
// WebCoreEME's.

// The key system is a MediaParserShortName: one of more than 16 characters is empty, which ClearKey's isn't.
@_expose(Cxx)
func clearKeySupportsKeySystemImpl(_ keySystem: WebCore.MediaParserShortName) -> Bool {
    var characters = ContiguousArray<UInt8>()
    for index in 0..<Int(keySystem.length) {
        let word = UInt64(littleEndian: index < 8 ? keySystem.words.0 : keySystem.words.1)
        characters.append(UInt8(truncatingIfNeeded: word >> UInt64(8 * (index & 7))))
    }
    return ClearKey.supportsKeySystem(characters.span)
}

@_expose(Cxx)
func clearKeySupportsInitDataImpl(_ type: borrowing WebCore.MediaParserText, _ initData: borrowing WebCore.MediaParserBytes) -> Bool {
    let bytes: Span<UInt8> = initData.span()
    return ClearKey.supportsInitData(initDataType(type), bytes)
}

@_expose(Cxx)
func clearKeySanitizeResponseImpl(_ response: borrowing WebCore.MediaParserBytes) -> Bool {
    let bytes: Span<UInt8> = response.span()
    return ClearKey.sanitizeResponse(bytes)
}

@_expose(Cxx)
func clearKeyIsValidSessionIDImpl(_ sessionID: borrowing WebCore.MediaParserText) -> Bool {
    if sessionID.is8Bit {
        let characters: Span<UInt8> = sessionID.span8()
        return ClearKey.isValidSessionID(characters)
    }
    let characters: Span<UInt16> = sessionID.span16()
    return ClearKey.isValidSessionID(characters)
}

@_expose(Cxx)
func clearKeySupportsConfigurationImpl(_ configuration: WebCore.ClearKeyConfiguration) -> Bool {
    ClearKey.supportsConfiguration(
        WebCoreEME.ClearKeyConfiguration(
            distinctiveIdentifier: emeRequirement(configuration.distinctiveIdentifier),
            persistentState: emeRequirement(configuration.persistentState),
            sessionTypesIncludePersistentLicense: configuration.sessionTypesIncludePersistentLicense,
            distinctiveIdentifierDenied: configuration.distinctiveIdentifierDenied,
            persistentStateDenied: configuration.persistentStateDenied
        )
    )
}

@_expose(Cxx)
func clearKeySupportsSessionTypeImpl(_ sessionType: WebCore.CDMSessionType) -> Bool {
    switch sessionType {
    case .Temporary:
        ClearKey.supportsSessionType(.temporary)
    case .PersistentUsageRecord:
        ClearKey.supportsSessionType(.persistentUsageRecord)
    case .PersistentLicense:
        ClearKey.supportsSessionType(.persistentLicense)
    @unknown default:
        false
    }
}

@_expose(Cxx)
func clearKeyRequirementImpl(_ denied: Bool) -> WebCore.CDMRequirement {
    switch ClearKey.requirement(denied: denied) {
    case .required:
        .Required
    case .optional:
        .Optional
    case .notAllowed:
        .NotAllowed
    }
}

@_expose(Cxx)
func clearKeyInitializationSucceedsImpl(_ allowsDistinctiveIdentifiers: Bool, _ allowsPersistentState: Bool) -> Bool {
    ClearKey.initializationSucceeds(
        allowsDistinctiveIdentifiers: allowsDistinctiveIdentifiers,
        allowsPersistentState: allowsPersistentState
    )
}

// A CDMInstanceClearKey's state.
@_expose(Cxx)
final class ClearKeyInstanceBridge {
    private let instance = ClearKeyInstance()

    @_expose(Cxx)
    init() {
    }

    @_expose(Cxx)
    func makeSession() -> ClearKeySessionBridge {
        ClearKeySessionBridge(instance.makeSession())
    }
}

// A CDMInstanceSessionClearKey's state. Key IDs reach C++ back to back in keyIDs, with their sizes in keyIDSizes.
@_expose(Cxx)
final class ClearKeySessionBridge {
    private let session: ClearKeySession

    fileprivate init(_ session: ClearKeySession) {
        self.session = session
    }

    // True when the init data itself is the request; otherwise the request is appended to message. The session's new ID
    // is in sessionID.
    @_expose(Cxx)
    func requestLicense(
        _ type: borrowing WebCore.MediaParserText,
        _ initData: borrowing WebCore.MediaParserBytes,
        _ message: inout WebCore.MediaParserByteVector,
        _ sessionID: inout WTF.String
    ) -> Bool {
        let bytes: Span<UInt8> = initData.span()
        let (request, newSessionID) = session.requestLicense(initDataType(type), bytes)
        sessionID = WebCore.makeStringFromLatin1(ContiguousArray(newSessionID.utf8).span)
        switch request {
        case .initData:
            return true
        case .message(let request):
            append(request, to: &message)
            return false
        }
    }

    @_expose(Cxx)
    func updateLicense(
        _ response: borrowing WebCore.MediaParserBytes,
        _ keyIDs: inout WebCore.MediaParserByteVector,
        _ keyIDSizes: inout WebCore.MediaParserUInt32Vector
    ) -> WebCore.ClearKeyUpdateResult {
        let bytes: Span<UInt8> = response.span()
        let update = session.updateLicense(bytes)
        var result = WebCore.ClearKeyUpdateResult()
        result.sessionWasClosed = update.sessionWasClosed
        result.succeeded = update.succeeded
        if let changedKeys = update.changedKeys {
            result.hasChangedKeys = true
            append(changedKeys, to: &keyIDs, &keyIDSizes)
        }
        return result
    }

    @_expose(Cxx)
    func loadSession(_ keyIDs: inout WebCore.MediaParserByteVector, _ keyIDSizes: inout WebCore.MediaParserUInt32Vector) {
        append(session.loadSession(), to: &keyIDs, &keyIDSizes)
    }

    // The released keys' IDs, and the release message.
    @_expose(Cxx)
    func removeSessionData(
        _ keyIDs: inout WebCore.MediaParserByteVector,
        _ keyIDSizes: inout WebCore.MediaParserUInt32Vector,
        _ message: inout WebCore.MediaParserByteVector
    ) {
        let removed = session.removeSessionData()
        append(removed.keys, to: &keyIDs, &keyIDSizes)
        append(removed.message, to: &message)
    }

    private func append(
        _ keys: [EMEKeyIDStatus],
        to keyIDs: inout WebCore.MediaParserByteVector,
        _ keyIDSizes: inout WebCore.MediaParserUInt32Vector
    ) {
        for key in keys {
            append(key.keyID, to: &keyIDs)
            keyIDSizes.append(consuming: UInt32(truncatingIfNeeded: key.keyID.count))
        }
    }

    private func append(_ bytes: ContiguousArray<UInt8>, to vector: inout WebCore.MediaParserByteVector) {
        if !bytes.isEmpty {
            WebCore.appendBytes(&vector, bytes.span)
        }
    }
}

private func initDataType(_ name: borrowing WebCore.MediaParserText) -> ClearKey.InitDataType {
    if name.is8Bit {
        let characters: Span<UInt8> = name.span8()
        return ClearKey.initDataType(characters)
    }
    let characters: Span<UInt16> = name.span16()
    return ClearKey.initDataType(characters)
}

private func emeRequirement(_ requirement: WebCore.CDMRequirement) -> EMERequirement {
    switch requirement {
    case .Required:
        .required
    case .Optional:
        .optional
    case .NotAllowed:
        .notAllowed
    @unknown default:
        .notAllowed
    }
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA
