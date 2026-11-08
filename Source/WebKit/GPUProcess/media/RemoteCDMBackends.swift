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

import Foundation
import os
@_spi(WebKitGPU) internal import WebCore
import WebCoreEME
import WebKit_Internal
import wtf

// The CDM instances and sessions behind the Swift receivers: ClearKey's are WebCoreEME's, and FairPlay Streaming's are
// WebCore's Swift FairPlayInstance and FairPlaySessions, whose instance a C++ CDMInstance owns.

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
    // A session, which tells the web process's RemoteCDMInstanceSession with that identifier, on connection, what it
    // reports while cdm exists.
    func makeSession(
        identifier: UInt64,
        cdm: RemoteCDMProxy,
        connection: IPC.Connection,
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
        cdm: RemoteCDMProxy,
        connection: IPC.Connection,
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

// MARK: FairPlay Streaming

extension WebKit.RemoteCDMInstanceSuccessCompletionHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebCore.CDMInstanceSuccessValue
}

// FairPlay Streaming's instance. The C++ CDM makes it, a CDMInstance, through which AVFoundation's players attach its
// keys to their samples, and which configures it and its storage; the certificate and the sessions are its Swift
// FairPlayInstance's. On Cocoa, FairPlay Streaming's CDM is the GPU process's only C++ one: ClearKey's is Swift.
@MainActor
final class FairPlayCDMInstanceBackend: RemoteCDMInstanceBackend {
    private let instance: WebCore.CDMInstance
    private let fairPlayInstance: FairPlayInstance?

    init(_ instance: WebCore.CDMInstance, fairPlayInstance: FairPlayInstance?) {
        self.instance = instance
        self.fairPlayInstance = fairPlayInstance
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
        guard let fairPlayInstance else {
            return false
        }
        let bytes = remoteCDMBytes(certificate)
        fairPlayInstance.setServerCertificate(Data(contiguousBytes(bytes.span())))
        return true
    }

    var usesStorageDirectory: Bool {
        true
    }

    func setStorageDirectory(_ directory: String) {
        WebKit.setRemoteCDMInstanceStorageDirectory(instance, IPCCoding.WTFString.cxxString(directory))
    }

    func makeSession(
        identifier: UInt64,
        cdm: RemoteCDMProxy,
        connection: IPC.Connection,
        logIdentifier: UInt64
    ) -> (any RemoteCDMSessionBackend)? {
        guard let fairPlayInstance else {
            return nil
        }
        let host = RemoteFairPlaySessionHost(connection: connection, identifier: identifier, cdm: cdm, logIdentifier: logIdentifier)
        return FairPlayCDMSessionBackend(fairPlayInstance.makeSession(host: host), host)
    }
}

private let fairPlayLog = os.Logger(subsystem: "com.apple.WebKit", category: "EME")

// What a FairPlay session reports, sent to the web process's RemoteCDMInstanceSession, as the C++
// CDMInstanceSessionClient of the registry sent it.
final class RemoteFairPlaySessionHost: FairPlaySessionHosting {
    private let connection: IPC.Connection
    private let identifier: UInt64
    private weak var cdm: RemoteCDMProxy?
    var logIdentifier: UInt64

    init(connection: IPC.Connection, identifier: UInt64, cdm: RemoteCDMProxy, logIdentifier: UInt64) {
        self.connection = connection
        self.identifier = identifier
        self.cdm = cdm
        self.logIdentifier = logIdentifier
    }

    var hasSessionClient: Bool {
        cdm != nil
    }

    func sendSessionMessage(_ type: WebCore.CDMMessageType, _ message: Span<UInt8>) {
        guard hasSessionClient, let messageType = IPCTypes.CDMMessageType(rawValue: type.rawValue) else {
            return
        }
        RemoteCDMInstanceSessionProxy.RemoteCDMInstanceSessionMessages.sendMessage(
            on: connection,
            to: identifier,
            type: messageType,
            message: WebKit.makeRemoteCDMBuffer(message)
        )
    }

    func sessionIdentifierChanged(_ sessionId: String) {
        guard hasSessionClient else {
            return
        }
        RemoteCDMInstanceSessionProxy.RemoteCDMInstanceSessionMessages.sessionIdChanged(on: connection, to: identifier, sessionId: sessionId)
    }

    func sessionKeyStatusesChanged(_ keyIDs: Span<UInt8>, _ keyIDSizes: Span<UInt32>, _ statuses: Span<UInt8>) {
        guard hasSessionClient else {
            return
        }
        RemoteCDMInstanceSessionProxy.RemoteCDMInstanceSessionMessages.updateKeyStatuses(
            on: connection,
            to: identifier,
            keyStatuses: fairPlayKeyStatuses(keyIDs, keyIDSizes, statuses)
        )
    }

    func logFromSession(_ level: FairPlaySessionLogLevel, _ method: String, _ message: String) {
        let identifier = logIdentifier
        switch level {
        case .always:
            fairPlayLog.notice("FairPlaySession::\(method, privacy: .public)(\(identifier, privacy: .public))\(message, privacy: .public)")
        case .error:
            fairPlayLog.error("FairPlaySession::\(method, privacy: .public)(\(identifier, privacy: .public))\(message, privacy: .public)")
        case .info:
            fairPlayLog.info("FairPlaySession::\(method, privacy: .public)(\(identifier, privacy: .public))\(message, privacy: .public)")
        }
    }
}

// A key status list as FairPlaySessionHosting lists it, as the C++ keyStatuses() of CDMInstanceFairPlayStreamingAVFObjC.mm
// reads it.
private func fairPlayKeyStatuses(_ keyIDs: Span<UInt8>, _ keyIDSizes: Span<UInt32>, _ statuses: Span<UInt8>) -> RemoteCDMKeyStatuses {
    var result: RemoteCDMKeyStatuses = []
    var offset = 0
    for index in 0..<min(keyIDSizes.count, statuses.count) {
        let size = min(Int(keyIDSizes[index]), keyIDs.count - offset)
        guard let status = IPCTypes.CDMKeyStatus(rawValue: statuses[index]) else {
            continue
        }
        result.append((WebKit.makeRemoteCDMBuffer(keyIDs.extracting(offset..<offset + size)), status))
        offset += size
    }
    return result
}

// Key statuses of released keys, whose IDs the expired session reports don't have.
private func releasedKeyStatuses(_ count: Int) -> RemoteCDMKeyStatuses {
    (0..<count).map { _ in (remoteCDMBuffer([]), .released) }
}

private func fairPlaySessionType(_ type: IPCTypes.CDMSessionType) -> WebCore.CDMSessionType {
    switch type {
    case .temporary:
        .Temporary
    case .persistentUsageRecord:
        .PersistentUsageRecord
    case .persistentLicense:
        .PersistentLicense
    }
}

// A license request's completion, for the reply of RequestLicense, which a session that ends without completing it
// fails.
private final class FairPlayLicenseRequest: FairPlayLicenseRequestCompleting {
    private var continuation: CheckedContinuation<RemoteCDMLicense, Never>?

    init(_ continuation: CheckedContinuation<RemoteCDMLicense, Never>) {
        self.continuation = continuation
    }

    deinit {
        continuation?.resume(returning: remoteCDMNoLicense)
    }

    func completeLicenseRequest(_ message: Span<UInt8>, _ sessionId: String?, _ succeeded: Bool) {
        continuation.take()?.resume(returning: (WebKit.makeRemoteCDMBuffer(message), sessionId, false, succeeded))
    }
}

// A license update's completion, for the reply of UpdateLicense.
private final class FairPlayLicenseUpdate: FairPlayLicenseUpdateCompleting {
    private var continuation: CheckedContinuation<RemoteCDMLicenseUpdate, Never>?

    init(_ continuation: CheckedContinuation<RemoteCDMLicenseUpdate, Never>) {
        self.continuation = continuation
    }

    deinit {
        continuation?.resume(returning: remoteCDMFailedUpdate)
    }

    func failLicenseUpdate(sessionWasClosed: Bool) {
        continuation.take()?.resume(returning: (sessionWasClosed, nil, nil, nil, false))
    }

    func succeedLicenseUpdate() {
        continuation.take()?.resume(returning: (false, nil, nil, nil, true))
    }

    func succeedLicenseUpdate(keyIDs: Span<UInt8>, keyIDSizes: Span<UInt32>, statuses: Span<UInt8>) {
        continuation.take()?.resume(returning: (false, fairPlayKeyStatuses(keyIDs, keyIDSizes, statuses), nil, nil, true))
    }

    func succeedLicenseUpdate(messageType: WebCore.CDMMessageType, message: Span<UInt8>) {
        guard let type = IPCTypes.CDMMessageType(rawValue: messageType.rawValue) else {
            failLicenseUpdate(sessionWasClosed: false)
            return
        }
        continuation.take()?.resume(returning: (false, nil, nil, (type, WebKit.makeRemoteCDMBuffer(message)), true))
    }
}

@MainActor
final class FairPlayCDMSessionBackend: RemoteCDMSessionBackend {
    private let session: FairPlaySession
    private let host: RemoteFairPlaySessionHost

    init(_ session: FairPlaySession, _ host: RemoteFairPlaySessionHost) {
        self.session = session
        self.host = host
    }

    func setLogIdentifier(_ logIdentifier: UInt64) {
        host.logIdentifier = logIdentifier
    }

    func requestLicense(
        _ type: IPCTypes.CDMSessionType,
        _ keyGroupingStrategy: IPCTypes.CDMKeyGroupingStrategy,
        _ initDataType: String?,
        _ initData: WebCore.SharedBuffer,
        cdm: WebKit.RemoteCDMPrivateHandle
    ) async -> RemoteCDMLicense {
        // The check CDMPrivate::supportsInitData() makes.
        guard WebKit.remoteCDMSupportsInitData(cdm, IPCCoding.WTFString.cxxString(initDataType), initData) else {
            return remoteCDMNoLicense
        }
        let bytes = remoteCDMBytes(initData)
        let initDataBytes = contiguousBytes(bytes.span())
        return await withCheckedContinuation { continuation in
            session.requestLicense(
                fairPlaySessionType(type),
                builtInKeyGrouping: keyGroupingStrategy == .builtIn,
                initDataType: initDataType ?? "",
                initData: initDataBytes,
                callback: FairPlayLicenseRequest(continuation)
            )
        }
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
        let bytes = remoteCDMBytes(sanitizedResponse)
        let responseBytes = contiguousBytes(bytes.span())
        return await withCheckedContinuation { continuation in
            session.updateLicense(responseBytes, callback: FairPlayLicenseUpdate(continuation))
        }
    }

    // A load that FairPlay doesn't handle, of a session that isn't a persistent usage record, which the web process
    // never asks for, fails.
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
        switch session.loadSession(fairPlaySessionType(type), sessionId: IPCCoding.WTFString.swiftString(sanitizedSessionId) ?? "") {
        case .notHandled:
            return remoteCDMNotLoaded
        case .succeeded(let releasedKeyCount):
            return (releasedKeyStatuses(releasedKeyCount), nil, nil, true, .none)
        case .mismatchedSessionType:
            return (nil, nil, nil, false, .mismatchedSessionType)
        case .noSessionData:
            return (nil, nil, nil, false, .noSessionData)
        }
    }

    func closeSession(_ sessionId: String?) async {
        session.closeSession()
    }

    func removeSessionData(_ sessionId: String?, _ type: IPCTypes.CDMSessionType) async -> RemoteCDMRemovedSessionData {
        let removed = session.removeSessionData(fairPlaySessionType(type), sessionId: sessionId ?? "")
        return (releasedKeyStatuses(removed.releasedKeyCount), removed.message.map { remoteCDMBuffer(ContiguousArray<UInt8>($0)) }, removed.succeeded)
    }

    // Key usage is stored as it happens.
    func storeRecordOfKeyUsage(_ sessionId: String?) {
    }
}

// The bytes of a span, in a Swift array.
private func contiguousBytes(_ bytes: Span<UInt8>) -> ContiguousArray<UInt8> {
    var result = ContiguousArray<UInt8>()
    result.reserveCapacity(bytes.count)
    for index in bytes.indices {
        result.append(bytes[index])
    }
    return result
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
