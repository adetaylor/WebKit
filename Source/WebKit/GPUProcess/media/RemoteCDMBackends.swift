// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT

import WebCoreEME
import WebKit_Internal
import wtf

// The CDM instances and sessions behind the Swift receivers: ClearKey's are WebCoreEME's, and the others are C++
// CDMs' (FairPlay Streaming's), reached through RemoteCDMSwiftSupport.h.

typealias RemoteCDMKeyStatuses = [(WebCore.SharedBuffer, IPCTypes.CDMKeyStatus)]
typealias RemoteCDMMessage = (IPCTypes.CDMMessageType, WebCore.SharedBuffer)
typealias RemoteCDMLicense = (message: WebCore.SharedBuffer?, sessionId: String?, needsIndividualization: Bool, succeeded: Bool)
typealias RemoteCDMLicenseUpdate = (
    sessionWasClosed: Bool, changedKeys: RemoteCDMKeyStatuses?, changedExpiration: Double?, message: RemoteCDMMessage?, succeeded: Bool
)
typealias RemoteCDMLoadedSession = (
    changedKeys: RemoteCDMKeyStatuses?, changedExpiration: Double?, message: RemoteCDMMessage?, succeeded: Bool,
    loadFailure: IPCTypes.CDMInstanceSessionLoadFailure
)
typealias RemoteCDMRemovedSessionData = (changedKeys: RemoteCDMKeyStatuses, message: WebCore.SharedBuffer?, succeeded: Bool)

@MainActor
protocol RemoteCDMInstanceBackend: AnyObject {
    func initialize(
        _ configuration: CxxDecodedArguments.RemoteCDMInstanceProxy.InitializeWithConfigurationConfiguration,
        distinctiveIdentifiersAllowed: Bool,
        persistentStateAllowed: Bool
    ) async -> Bool
    func setServerCertificate(_ certificate: WebCore.SharedBuffer) async -> Bool
    // Only C++ instances store anything.
    var usesStorageDirectory: Bool { get }
    func setStorageDirectory(_ directory: String)
    // A session, which a C++ CDM's instance also registers under identifier.
    func makeSession(
        identifier: UInt64,
        registry: WebKit.RemoteCDMRegistry,
        cdm: WebKit.RemoteCDMPrivateHandle,
        logIdentifier: UInt64
    ) -> (any RemoteCDMSessionBackend)?
}

@MainActor
protocol RemoteCDMSessionBackend: AnyObject {
    func setLogIdentifier(_ logIdentifier: UInt64)
    func requestLicense(
        _ type: IPCTypes.CDMSessionType,
        _ keyGroupingStrategy: IPCTypes.CDMKeyGroupingStrategy,
        _ initDataType: String?,
        _ initData: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicense
    func updateLicense(
        _ sessionId: String?,
        _ type: IPCTypes.CDMSessionType,
        _ response: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicenseUpdate
    func loadSession(
        _ type: IPCTypes.CDMSessionType,
        _ sessionId: String?,
        _ origin: String?,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLoadedSession
    func closeSession(_ sessionId: String?) async
    func removeSessionData(_ sessionId: String?, _ type: IPCTypes.CDMSessionType) async -> RemoteCDMRemovedSessionData
    func storeRecordOfKeyUsage(_ sessionId: String?)
}

let remoteCDMNoLicense: RemoteCDMLicense = (nil, "", false, false)
let remoteCDMFailedUpdate: RemoteCDMLicenseUpdate = (false, nil, nil, nil, false)
let remoteCDMNotLoaded: RemoteCDMLoadedSession = (nil, nil, nil, false, .mismatchedSessionType)

// MARK: ClearKey

final class ClearKeyInstanceBackend: RemoteCDMInstanceBackend {
    private let instance = ClearKeyInstance()

    func initialize(
        _ configuration: CxxDecodedArguments.RemoteCDMInstanceProxy.InitializeWithConfigurationConfiguration,
        distinctiveIdentifiersAllowed: Bool,
        persistentStateAllowed: Bool
    ) async -> Bool {
        ClearKey.initializationSucceeds(
            allowsDistinctiveIdentifiers: distinctiveIdentifiersAllowed,
            allowsPersistentState: persistentStateAllowed
        )
    }

    func setServerCertificate(_ certificate: WebCore.SharedBuffer) async -> Bool {
        ClearKey.supportsServerCertificates
    }

    var usesStorageDirectory: Bool {
        false
    }

    func setStorageDirectory(_ directory: String) {
    }

    func makeSession(
        identifier: UInt64,
        registry: WebKit.RemoteCDMRegistry,
        cdm: WebKit.RemoteCDMPrivateHandle,
        logIdentifier: UInt64
    ) -> (any RemoteCDMSessionBackend)? {
        ClearKeySessionBackend(instance.makeSession())
    }
}

final class ClearKeySessionBackend: RemoteCDMSessionBackend {
    private let session: ClearKeySession

    init(_ session: ClearKeySession) {
        self.session = session
    }

    func setLogIdentifier(_ logIdentifier: UInt64) {
    }

    func requestLicense(
        _ type: IPCTypes.CDMSessionType,
        _ keyGroupingStrategy: IPCTypes.CDMKeyGroupingStrategy,
        _ initDataType: String?,
        _ initData: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicense {
        let initDataBytes = remoteCDMBytes(initData)
        let bytes: Span<UInt8> = initDataBytes.span()
        let initDataType = ClearKey.initDataType(initDataType)
        // The check CDMPrivate::supportsInitData() makes.
        guard ClearKey.supportsInitData(initDataType, bytes) else {
            return remoteCDMNoLicense
        }
        let (request, sessionID) = session.requestLicense(initDataType, bytes)
        switch request {
        case .initData:
            return (initData, sessionID, false, true)
        case .message(let message):
            return (remoteCDMBuffer(message), sessionID, false, true)
        }
    }

    // A response that isn't a JSON object fails here as CDMPrivate::sanitizeResponse() made it fail.
    func updateLicense(
        _ sessionId: String?,
        _ type: IPCTypes.CDMSessionType,
        _ response: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicenseUpdate {
        let responseBytes = remoteCDMBytes(response)
        let update = session.updateLicense(responseBytes.span())
        return (update.sessionWasClosed, update.changedKeys.map(remoteCDMKeyStatuses), nil, nil, update.succeeded)
    }

    func loadSession(
        _ type: IPCTypes.CDMSessionType,
        _ sessionId: String?,
        _ origin: String?,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLoadedSession {
        // The check CDMPrivate::sanitizeSessionId() makes.
        guard ClearKey.isValidSessionID(sessionId) else {
            return remoteCDMNotLoaded
        }
        return (remoteCDMKeyStatuses(session.loadSession()), nil, nil, true, .none)
    }

    func closeSession(_ sessionId: String?) async {
    }

    func removeSessionData(_ sessionId: String?, _ type: IPCTypes.CDMSessionType) async -> RemoteCDMRemovedSessionData {
        let removed = session.removeSessionData()
        return (remoteCDMKeyStatuses(removed.keys), remoteCDMBuffer(removed.message), true)
    }

    func storeRecordOfKeyUsage(_ sessionId: String?) {
    }
}

// MARK: C++ CDMs

extension WebKit.RemoteCDMInstanceSuccessCompletionHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebCore.CDMInstanceSuccessValue
}

extension WebKit.RemoteCDMEncodedReplyCompletionHandler: @unsafe CxxConsumingCompletionHandler {
    typealias Argument = WebKit.RemoteCDMEncodedReply
}

private typealias KeyStatusesCoder = IPCCoding.Vector<
    IPCCoding.Pair<IPCCoding.CxxDecoded.SharedBuffer, IPCTypes.CxxName.WebCore_CDMKeyStatus>
>
private typealias MessageCoder = IPCCoding.Pair<IPCTypes.CxxName.WebCore_CDMMessageType, IPCCoding.CxxDecoded.SharedBuffer>

final class CxxCDMInstanceBackend: RemoteCDMInstanceBackend {
    private let instance: WebCore.CDMInstance

    init(_ instance: WebCore.CDMInstance) {
        self.instance = instance
    }

    func initialize(
        _ configuration: CxxDecodedArguments.RemoteCDMInstanceProxy.InitializeWithConfigurationConfiguration,
        distinctiveIdentifiersAllowed: Bool,
        persistentStateAllowed: Bool
    ) async -> Bool {
        let success = await withCheckedContinuation { continuation in
            WebKit.initializeRemoteCDMInstance(
                instance,
                configuration,
                distinctiveIdentifiersAllowed,
                persistentStateAllowed,
                consuming: .init(continuation)
            )
        }
        return success == .Succeeded
    }

    func setServerCertificate(_ certificate: WebCore.SharedBuffer) async -> Bool {
        let success = await withCheckedContinuation { continuation in
            WebKit.setRemoteCDMInstanceServerCertificate(instance, certificate, consuming: .init(continuation))
        }
        return success == .Succeeded
    }

    var usesStorageDirectory: Bool {
        true
    }

    func setStorageDirectory(_ directory: String) {
        WebKit.setRemoteCDMInstanceStorageDirectory(instance, IPCCoding.WTFString.cxxString(directory))
    }

    func makeSession(
        identifier: UInt64,
        registry: WebKit.RemoteCDMRegistry,
        cdm: WebKit.RemoteCDMPrivateHandle,
        logIdentifier: UInt64
    ) -> (any RemoteCDMSessionBackend)? {
        guard let session = WebKit.createRemoteCDMInstanceSession(registry, cdm, instance, identifier, logIdentifier) else {
            return nil
        }
        return CxxCDMSessionBackend(session)
    }
}

final class CxxCDMSessionBackend: RemoteCDMSessionBackend {
    private let session: WebCore.CDMInstanceSession

    init(_ session: WebCore.CDMInstanceSession) {
        self.session = session
    }

    func setLogIdentifier(_ logIdentifier: UInt64) {
        WebKit.setRemoteCDMInstanceSessionLogIdentifier(session, logIdentifier)
    }

    func requestLicense(
        _ type: IPCTypes.CDMSessionType,
        _ keyGroupingStrategy: IPCTypes.CDMKeyGroupingStrategy,
        _ initDataType: String?,
        _ initData: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicense {
        let cxxInitDataType = IPCCoding.WTFString.cxxString(initDataType)
        // The check CDMPrivate::supportsInitData() makes.
        guard WebKit.remoteCDMSupportsInitData(cdm, cxxInitDataType, initData) else {
            return remoteCDMNoLicense
        }
        let license = await withCheckedContinuation { continuation in
            WebKit.requestRemoteCDMLicense(
                session,
                type.rawValue,
                keyGroupingStrategy == .builtIn,
                cxxInitDataType,
                initData,
                consuming: .init { (reply: consuming WebKit.RemoteCDMEncodedReply) in
                    var decoder = WebKit.swiftDecoder(reply)
                    continuation.resume(returning: try? Self.decodeLicense(from: &decoder))
                }
            )
        }
        return license ?? remoteCDMNoLicense
    }

    func updateLicense(
        _ sessionId: String?,
        _ type: IPCTypes.CDMSessionType,
        _ response: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicenseUpdate {
        // The check CDMPrivate::sanitizeResponse() makes.
        guard let sanitizedResponse = WebKit.sanitizeRemoteCDMResponse(cdm, response) else {
            return remoteCDMFailedUpdate
        }
        let update = await withCheckedContinuation { continuation in
            WebKit.updateRemoteCDMLicense(
                session,
                IPCCoding.WTFString.cxxString(sessionId),
                type.rawValue,
                sanitizedResponse,
                consuming: .init { (reply: consuming WebKit.RemoteCDMEncodedReply) in
                    var decoder = WebKit.swiftDecoder(reply)
                    continuation.resume(returning: try? Self.decodeLicenseUpdate(from: &decoder))
                }
            )
        }
        return update ?? remoteCDMFailedUpdate
    }

    func loadSession(
        _ type: IPCTypes.CDMSessionType,
        _ sessionId: String?,
        _ origin: String?,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLoadedSession {
        // The check CDMPrivate::sanitizeSessionId() makes.
        var sanitizedSessionId = WTF.String()
        guard WebKit.sanitizeRemoteCDMSessionId(cdm, IPCCoding.WTFString.cxxString(sessionId), &sanitizedSessionId) else {
            return remoteCDMNotLoaded
        }
        let loadedSession = await withCheckedContinuation { continuation in
            WebKit.loadRemoteCDMSession(
                session,
                type.rawValue,
                sanitizedSessionId,
                IPCCoding.WTFString.cxxString(origin),
                consuming: .init { (reply: consuming WebKit.RemoteCDMEncodedReply) in
                    var decoder = WebKit.swiftDecoder(reply)
                    continuation.resume(returning: try? Self.decodeLoadedSession(from: &decoder))
                }
            )
        }
        return loadedSession ?? remoteCDMNotLoaded
    }

    func closeSession(_ sessionId: String?) async {
        await withCheckedContinuation { continuation in
            WebKit.closeRemoteCDMSession(session, IPCCoding.WTFString.cxxString(sessionId), consuming: .init(continuation))
        }
    }

    func removeSessionData(_ sessionId: String?, _ type: IPCTypes.CDMSessionType) async -> RemoteCDMRemovedSessionData {
        let removedSessionData = await withCheckedContinuation { continuation in
            WebKit.removeRemoteCDMSessionData(
                session,
                IPCCoding.WTFString.cxxString(sessionId),
                type.rawValue,
                consuming: .init { (reply: consuming WebKit.RemoteCDMEncodedReply) in
                    var decoder = WebKit.swiftDecoder(reply)
                    continuation.resume(returning: try? Self.decodeRemovedSessionData(from: &decoder))
                }
            )
        }
        return removedSessionData ?? ([], nil, false)
    }

    func storeRecordOfKeyUsage(_ sessionId: String?) {
        WebKit.storeRemoteCDMRecordOfKeyUsage(session, IPCCoding.WTFString.cxxString(sessionId))
    }

    private static func decodeLicense(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> RemoteCDMLicense {
        let message = try IPCCoding.StdOptional<IPCCoding.CxxDecoded.SharedBuffer>.decode(from: &decoder)
        let sessionId = try IPCCoding.WTFString.decode(from: &decoder)
        let needsIndividualization = try Bool.decode(from: &decoder)
        return (message, sessionId, needsIndividualization, try Bool.decode(from: &decoder))
    }

    private static func decodeLicenseUpdate(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> RemoteCDMLicenseUpdate {
        let sessionWasClosed = try Bool.decode(from: &decoder)
        let changedKeys = try IPCCoding.StdOptional<KeyStatusesCoder>.decode(from: &decoder)
        let changedExpiration = try IPCCoding.StdOptional<Double>.decode(from: &decoder)
        let message = try IPCCoding.StdOptional<MessageCoder>.decode(from: &decoder)
        return (sessionWasClosed, changedKeys, changedExpiration, message, try Bool.decode(from: &decoder))
    }

    private static func decodeLoadedSession(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> RemoteCDMLoadedSession {
        let changedKeys = try IPCCoding.StdOptional<KeyStatusesCoder>.decode(from: &decoder)
        let changedExpiration = try IPCCoding.StdOptional<Double>.decode(from: &decoder)
        let message = try IPCCoding.StdOptional<MessageCoder>.decode(from: &decoder)
        let succeeded = try Bool.decode(from: &decoder)
        return (
            changedKeys, changedExpiration, message, succeeded,
            try IPCTypes.CxxName.WebCore_CDMInstanceSessionLoadFailure.decode(from: &decoder)
        )
    }

    private static func decodeRemovedSessionData(
        from decoder: inout IPC.SwiftDecoder
    ) throws(IPCDecodingError) -> RemoteCDMRemovedSessionData {
        let changedKeys = try KeyStatusesCoder.decode(from: &decoder)
        let message = try IPCCoding.StdOptional<IPCCoding.CxxDecoded.SharedBuffer>.decode(from: &decoder)
        return (changedKeys, message, try Bool.decode(from: &decoder))
    }
}

// MARK: Bytes

// The bytes of a buffer from IPC.
func remoteCDMBytes(_ buffer: WebCore.SharedBuffer) -> WebKit.RemoteCDMBytes {
    WebKit.remoteCDMBufferBytes(buffer)
}

// A buffer for a reply.
func remoteCDMBuffer(_ bytes: ContiguousArray<UInt8>) -> WebCore.SharedBuffer {
    WebKit.makeRemoteCDMBuffer(bytes.span)
}

func remoteCDMKeyStatuses(_ keys: [EMEKeyIDStatus]) -> RemoteCDMKeyStatuses {
    keys.map { key in
        let status: IPCTypes.CDMKeyStatus =
            switch key.status {
            case .usable:
                .usable
            case .released:
                .released
            }
        return (remoteCDMBuffer(key.keyID), status)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
