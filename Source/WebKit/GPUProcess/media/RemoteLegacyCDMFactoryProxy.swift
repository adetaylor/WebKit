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

#if ENABLE_GPU_PROCESS && ENABLE_LEGACY_ENCRYPTED_MEDIA

@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal
import wtf

// Receives the legacy EME factory messages of one web process's connection to the GPU process, which owns it
// (GPUConnectionState), and owns the legacy CDMs and sessions, whose messages their registrations route to them.
@_expose(Cxx)
final class RemoteLegacyCDMFactoryProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteLegacyCDMFactoryProxyMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    @_expose(!Cxx)
    private(set) var connection: WebKit.GPUConnectionToWebProcess?
    // By identifier: removed before the receiver, so that its messages stop before its forwarder goes. Declared first, so
    // that they go first.
    private var cdmRegistrations: [UInt64: IPC.SwiftReceiverRegistration] = [:]
    private var sessionRegistrations: [UInt64: IPC.SwiftReceiverRegistration] = [:]
    private var cdms: [UInt64: RemoteLegacyCDMProxy] = [:]
    private var sessions: [UInt64: RemoteLegacyCDMSessionProxy] = [:]

    @_expose(!Cxx)
    init(connection: WebKit.GPUConnectionToWebProcess) {
        self.connection = connection
        self.messageForwarder = WebKit.RemoteLegacyCDMFactoryProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteLegacyCDMFactoryProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        // The connection dispatches the receiver's messages on the main thread, which alone changes `connection`.
        MainActor.preconditionIsolated()
        guard let connection else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return connection.sharedPreferencesForWebProcess()
    }

    // The session the web process's RemoteLegacyCDMSession with that identifier stands for, for the media players.
    @_expose(!Cxx)
    @MainActor
    func session(_ identifier: UInt64) -> WebCore.LegacyCDMSessionClientSwiftAdapter? {
        sessions[identifier]?.client
    }

    @_expose(!Cxx)
    @MainActor
    func add(session: RemoteLegacyCDMSessionProxy, identifier: UInt64) {
        guard let connection else {
            return
        }
        assert(sessions[identifier] == nil)
        sessionRegistrations[identifier] = IPC.registerSwiftReceiver(
            connection,
            session.getMessageReceiver(),
            .RemoteLegacyCDMSessionProxy,
            identifier
        )
        sessions[identifier] = session
    }

    // MARK: Messages

    @MainActor
    func createCDM(
        connection: IPC.Connection,
        keySystem: String?,
        playerId: IPCTypes.MediaPlayerIdentifier?
    ) -> IPCTypes.RemoteLegacyCDMIdentifier? {
        guard let gpuConnection = self.connection,
            let cdm = RemoteLegacyCDMProxy(factory: self, keySystem: IPCCoding.WTFString.cxxString(keySystem), playerId: playerId)
        else {
            return nil
        }
        let identifier = WTF.ObjectIdentifierMainThreadAccessTraits.generateIdentifierInternal()
        assert(cdms[identifier] == nil)
        cdmRegistrations[identifier] = IPC.registerSwiftReceiver(gpuConnection, cdm.getMessageReceiver(), .RemoteLegacyCDMProxy, identifier)
        cdms[identifier] = cdm
        return IPCTypes.RemoteLegacyCDMIdentifier(rawValue: identifier)
    }

    @MainActor
    func supportsKeySystem(connection: IPC.Connection, keySystem: String?, mimeType: String??) -> Bool {
        let cxxKeySystem = IPCCoding.WTFString.cxxString(keySystem)
        if let mimeType {
            return WebCore.LegacyCDM.keySystemSupportsMimeType(cxxKeySystem, IPCCoding.WTFString.cxxString(mimeType))
        }
        return WebCore.LegacyCDM.supportsKeySystem(cxxKeySystem)
    }

    @MainActor
    func removeSession(connection: IPC.Connection, identifier: IPCTypes.RemoteLegacyCDMSessionIdentifier) {
        guard let gpuConnection = self.connection else {
            return
        }
        sessionRegistrations.removeValue(forKey: identifier.rawValue)
        assert(sessions[identifier.rawValue] != nil)
        sessions.removeValue(forKey: identifier.rawValue)?.invalidate()
        if allowsExitUnderMemoryPressure {
            gpuConnection.tryExitIfUnusedAndUnderMemoryPressure()
        }
    }
}

extension RemoteLegacyCDMFactoryProxy: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        sessions.isEmpty
    }

    // No receiver's messages are routed, and the sessions no longer reach the connection.
    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        sessionRegistrations.removeAll()
        cdmRegistrations.removeAll()
        sessions.removeAll()
        cdms.removeAll()
        connection = nil
    }
}

// Receives the messages of one of the web process's RemoteLegacyCDMs, and is its legacy CDM's client, which finds the
// media player the web process names.
@_expose(Cxx)
final class RemoteLegacyCDMProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteLegacyCDMProxyMessageForwarder?
    private weak var factory: RemoteLegacyCDMFactoryProxy?
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var client: WebCore.LegacyCDMClientSwiftAdapter?
    private var playerId: IPCTypes.MediaPlayerIdentifier?

    // Nil if no legacy CDM supports the key system.
    @_expose(!Cxx)
    @MainActor
    init?(factory: RemoteLegacyCDMFactoryProxy, keySystem: WTF.String, playerId: IPCTypes.MediaPlayerIdentifier?) {
        self.factory = factory
        self.playerId = playerId
        guard let client = makeLegacyCDMClientSwiftAdapter(keySystem: keySystem, delegate: self) else {
            return nil
        }
        self.client = client
        self.messageForwarder = WebKit.RemoteLegacyCDMProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteLegacyCDMProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        // The receiver's messages come on the main thread, which alone changes the factory's connection.
        MainActor.preconditionIsolated()
        guard let connection = factory?.connection else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return connection.sharedPreferencesForWebProcess()
    }

    // MARK: Messages

    @MainActor
    func supportsMIMEType(connection: IPC.Connection, mimeType: String?) -> Bool {
        client?.supportsMIMEType(IPCCoding.WTFString.cxxString(mimeType)) ?? false
    }

    @MainActor
    func createSession(connection: IPC.Connection, logIdentifier: UInt64) -> IPCTypes.RemoteLegacyCDMSessionIdentifier? {
        guard let factory, let gpuConnection = factory.connection, let client else {
            return nil
        }
        let identifier = WTF.ObjectIdentifierMainThreadAccessTraits.generateIdentifierInternal()
        let session = RemoteLegacyCDMSessionProxy(
            factory: factory,
            cdm: client,
            logger: gpuConnection.logger(),
            connection: connection,
            identifier: identifier,
            logIdentifier: logIdentifier
        )
        factory.add(session: session, identifier: identifier)
        return IPCTypes.RemoteLegacyCDMSessionIdentifier(rawValue: identifier)
    }

    @MainActor
    func setPlayerId(connection: IPC.Connection, playerId: IPCTypes.MediaPlayerIdentifier?) {
        self.playerId = playerId
    }
}

extension RemoteLegacyCDMProxy: LegacyCDMClientDelegate {
    @_expose(!Cxx)
    @MainActor
    func legacyCDMMediaPlayer() -> WebCore.RefPtrLegacyCDMMediaPlayer {
        guard let playerId, let connection = factory?.connection else {
            return WebCore.RefPtrLegacyCDMMediaPlayer(nil)
        }
        return WebKit.legacyCDMMediaPlayer(connection, playerId.rawValue)
    }
}

// Receives the messages of one of the web process's RemoteLegacyCDMSessions, and is its legacy CDM session's client, which
// sends the session's messages and errors to it.
@_expose(Cxx)
final class RemoteLegacyCDMSessionProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteLegacyCDMSessionProxyMessageForwarder?
    // Until the factory removes the session.
    private weak var factory: RemoteLegacyCDMFactoryProxy?
    // The connection to the web process's RemoteLegacyCDMSession with that identifier.
    private let connection: IPC.Connection
    private let identifier: UInt64
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    @_expose(!Cxx)
    private(set) var client: WebCore.LegacyCDMSessionClientSwiftAdapter?

    @_expose(!Cxx)
    @MainActor
    init(
        factory: RemoteLegacyCDMFactoryProxy,
        cdm: WebCore.LegacyCDMClientSwiftAdapter,
        logger: WTF.Logger,
        connection: IPC.Connection,
        identifier: UInt64,
        logIdentifier: UInt64
    ) {
        self.factory = factory
        self.connection = connection
        self.identifier = identifier
        self.client = makeLegacyCDMSessionClientSwiftAdapter(cdm: cdm, logger: logger, logIdentifier: logIdentifier, delegate: self)
        self.messageForwarder = WebKit.RemoteLegacyCDMSessionProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteLegacyCDMSessionProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    // The session no longer reaches the web process.
    @_expose(!Cxx)
    @MainActor
    func invalidate() {
        factory = nil
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        // The receiver's messages come on the main thread, which alone changes the factory and its connection.
        MainActor.preconditionIsolated()
        guard let connection = factory?.connection else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return connection.sharedPreferencesForWebProcess()
    }

    // MARK: Messages

    @MainActor
    func generateKeyRequest(
        connection: IPC.Connection,
        mimeType: String?,
        initData: WebCore.SharedBuffer?,
        mediaKeysHashSalt: String?
    ) -> (nextMessage: WebCore.SharedBuffer?, destinationURL: String?, errorCode: UInt16, systemCode: UInt32) {
        var destinationURL = WTF.String()
        var errorCode: UInt16 = 0
        var systemCode: UInt32 = 0
        let nextMessage = client?.generateKeyRequest(
            IPCCoding.WTFString.cxxString(mimeType),
            initData,
            IPCCoding.WTFString.cxxString(mediaKeysHashSalt),
            &destinationURL,
            &errorCode,
            &systemCode
        )
        return (nextMessage, IPCCoding.WTFString.swiftString(destinationURL), errorCode, systemCode)
    }

    @MainActor
    func releaseKeys(connection: IPC.Connection) {
        client?.releaseKeys()
    }

    @MainActor
    func update(
        connection: IPC.Connection,
        update: WebCore.SharedBuffer?
    ) -> (succeeded: Bool, nextMessage: WebCore.SharedBuffer?, errorCode: UInt16, systemCode: UInt32) {
        var succeeded = false
        var errorCode: UInt16 = 0
        var systemCode: UInt32 = 0
        let nextMessage = client?.update(update, &succeeded, &errorCode, &systemCode)
        return (succeeded, nextMessage, errorCode, systemCode)
    }

    @MainActor
    func cachedKeyForKeyID(connection: IPC.Connection, keyId: String?) -> WebCore.SharedBuffer? {
        client?.cachedKeyForKeyID(IPCCoding.WTFString.cxxString(keyId))
    }
}

extension RemoteLegacyCDMSessionProxy: LegacyCDMSessionClientDelegate {
    @_expose(!Cxx)
    @MainActor
    func legacyCDMSessionSendMessage(_ message: WebCore.SharedBuffer?, destinationURL: WTF.String) {
        guard factory != nil else {
            return
        }
        Messages.RemoteLegacyCDMSession.sendSendMessage(connection, identifier, message, destinationURL)
    }

    @_expose(!Cxx)
    @MainActor
    func legacyCDMSessionSendError(_ errorCode: UInt16, systemCode: UInt32) {
        guard factory != nil else {
            return
        }
        Messages.RemoteLegacyCDMSession.sendSendError(connection, identifier, errorCode, systemCode)
    }

    @_expose(!Cxx)
    @MainActor
    func legacyCDMSessionMediaKeysStorageDirectory() -> WTF.String {
        factory?.connection?.mediaKeysStorageDirectory() ?? WTF.String()
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func legacyCDMSession(_ identifier: UInt64) -> WebKit.RefPtrLegacyCDMSessionClientSwiftAdapter {
        MainActor.preconditionIsolated()
        return WebKit.RefPtrLegacyCDMSessionClientSwiftAdapter(state.legacyCDMFactory?.session(identifier))
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_LEGACY_ENCRYPTED_MEDIA
