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

import WebKit_Internal
import wtf

extension WebKit.RemoteCDMEncodedReplyCompletionHandler: @unsafe CxxConsumingCompletionHandler {
    typealias Argument = WebKit.RemoteCDMEncodedReply
}

private typealias KeyStatusesCoder = IPCCoding.Vector<IPCCoding.Pair<IPCCoding.CxxDecoded.SharedBuffer, IPCTypes.CxxName.WebCore_CDMKeyStatus>>
private typealias MessageCoder = IPCCoding.Pair<IPCTypes.CxxName.WebCore_CDMMessageType, IPCCoding.CxxDecoded.SharedBuffer>

// Receives the messages of one of the web process's RemoteCDMInstanceSessions, for the CDMInstanceSession it was
// created with. The session's client is RemoteCDMRegistry's RemoteCDMInstanceSessionClient.
@_expose(Cxx)
final class RemoteCDMInstanceSessionProxy {
    typealias KeyStatuses = [(WebCore.SharedBuffer, IPCTypes.CDMKeyStatus)]
    typealias Message = (IPCTypes.CDMMessageType, WebCore.SharedBuffer)
    typealias License = (message: WebCore.SharedBuffer?, sessionId: String?, needsIndividualization: Bool, succeeded: Bool)
    typealias LicenseUpdate = (
        sessionWasClosed: Bool, changedKeys: KeyStatuses?, changedExpiration: Double?, message: Message?, succeeded: Bool
    )
    typealias LoadedSession = (
        changedKeys: KeyStatuses?, changedExpiration: Double?, message: Message?, succeeded: Bool,
        loadFailure: IPCTypes.CDMInstanceSessionLoadFailure
    )
    typealias RemovedSessionData = (changedKeys: KeyStatuses, message: WebCore.SharedBuffer?, succeeded: Bool)

    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMInstanceSessionProxyMessageForwarder?
    private let registry: WebKit.RemoteCDMRegistryWeakReference
    private let cdm: WebKit.RemoteCDMPrivateHandleWeakReference
    private let session: WebCore.CDMInstanceSession

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(registry: WebKit.RemoteCDMRegistry, cdm: WebKit.RemoteCDMPrivateHandle, session: WebCore.CDMInstanceSession) {
        self.registry = WebKit.RemoteCDMRegistryWeakReference(registry)
        self.cdm = WebKit.RemoteCDMPrivateHandleWeakReference(cdm)
        self.session = session
        self.messageForwarder = WebKit.RemoteCDMInstanceSessionProxyMessageForwarder.create(target: self)
    }

    @used
    func getMessageReceiver() -> RefRemoteCDMInstanceSessionProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        guard cdm.get() != nil, let registry = registry.get() else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return registry.sharedPreferencesForWebProcess()
    }

    @MainActor
    func setLogIdentifier(connection: IPC.Connection, logIdentifier: UInt64) {
        WebKit.setRemoteCDMInstanceSessionLogIdentifier(session, logIdentifier)
    }

    @MainActor
    func requestLicense(
        connection: IPC.Connection,
        type: IPCTypes.CDMSessionType,
        keyGroupingStrategy: IPCTypes.CDMKeyGroupingStrategy,
        initDataType: String?,
        initData: WebCore.SharedBuffer?
    ) async -> License {
        let noLicense: License = (nil, "", false, false)
        guard let initData else {
            return noLicense
        }
        let cxxInitDataType = IPCCoding.WTFString.cxxString(initDataType)
        // The check CDMPrivate::supportsInitData() makes.
        guard WebKit.remoteCDMSupportsInitData(cdm, cxxInitDataType, initData) else {
            return noLicense
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
        return license ?? noLicense
    }

    @MainActor
    func updateLicense(
        connection: IPC.Connection,
        sessionId: String?,
        type: IPCTypes.CDMSessionType,
        response: WebCore.SharedBuffer?
    ) async -> LicenseUpdate {
        guard let response else {
            return (true, nil, nil, nil, false)
        }
        // The check CDMPrivate::sanitizeResponse() makes.
        guard let sanitizedResponse = WebKit.sanitizeRemoteCDMResponse(cdm, response) else {
            return (false, nil, nil, nil, false)
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
        return update ?? (false, nil, nil, nil, false)
    }

    @MainActor
    func loadSession(
        connection: IPC.Connection,
        type: IPCTypes.CDMSessionType,
        sessionId: String?,
        origin: String?
    ) async -> LoadedSession {
        let notLoaded: LoadedSession = (nil, nil, nil, false, .mismatchedSessionType)
        // The check CDMPrivate::sanitizeSessionId() makes.
        var sanitizedSessionId = WTF.String()
        guard WebKit.sanitizeRemoteCDMSessionId(cdm, IPCCoding.WTFString.cxxString(sessionId), &sanitizedSessionId) else {
            return notLoaded
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
        return loadedSession ?? notLoaded
    }

    @MainActor
    func closeSession(connection: IPC.Connection, sessionId: String?) async {
        await withCheckedContinuation { continuation in
            WebKit.closeRemoteCDMSession(session, IPCCoding.WTFString.cxxString(sessionId), consuming: .init(continuation))
        }
    }

    @MainActor
    func removeSessionData(connection: IPC.Connection, sessionId: String?, type: IPCTypes.CDMSessionType) async -> RemovedSessionData {
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

    @MainActor
    func storeRecordOfKeyUsage(connection: IPC.Connection, sessionId: String?) {
        WebKit.storeRemoteCDMRecordOfKeyUsage(session, IPCCoding.WTFString.cxxString(sessionId))
    }

    private static func decodeLicense(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> License {
        let message = try IPCCoding.StdOptional<IPCCoding.CxxDecoded.SharedBuffer>.decode(from: &decoder)
        let sessionId = try IPCCoding.WTFString.decode(from: &decoder)
        let needsIndividualization = try Bool.decode(from: &decoder)
        return (message, sessionId, needsIndividualization, try Bool.decode(from: &decoder))
    }

    private static func decodeLicenseUpdate(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> LicenseUpdate {
        let sessionWasClosed = try Bool.decode(from: &decoder)
        let changedKeys = try IPCCoding.StdOptional<KeyStatusesCoder>.decode(from: &decoder)
        let changedExpiration = try IPCCoding.StdOptional<Double>.decode(from: &decoder)
        let message = try IPCCoding.StdOptional<MessageCoder>.decode(from: &decoder)
        return (sessionWasClosed, changedKeys, changedExpiration, message, try Bool.decode(from: &decoder))
    }

    private static func decodeLoadedSession(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> LoadedSession {
        let changedKeys = try IPCCoding.StdOptional<KeyStatusesCoder>.decode(from: &decoder)
        let changedExpiration = try IPCCoding.StdOptional<Double>.decode(from: &decoder)
        let message = try IPCCoding.StdOptional<MessageCoder>.decode(from: &decoder)
        let succeeded = try Bool.decode(from: &decoder)
        return (changedKeys, changedExpiration, message, succeeded, try IPCTypes.CxxName.WebCore_CDMInstanceSessionLoadFailure.decode(from: &decoder))
    }

    private static func decodeRemovedSessionData(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> RemovedSessionData {
        let changedKeys = try KeyStatusesCoder.decode(from: &decoder)
        let message = try IPCCoding.StdOptional<IPCCoding.CxxDecoded.SharedBuffer>.decode(from: &decoder)
        return (changedKeys, message, try Bool.decode(from: &decoder))
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
