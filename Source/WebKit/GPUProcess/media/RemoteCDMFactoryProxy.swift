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

@_spi(WebKitGPU) internal import WebCore
import WebCoreEME
import WebKit_Internal
import wtf

// Receives the EME factory messages of one web process's connection to the GPU process, which owns it (GPUConnectionState),
// and owns the GPU process's CDMs, CDM instances and sessions, whose messages their registrations route to them, and the
// C++ instances the media players use.
@_expose(Cxx)
final class RemoteCDMFactoryProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMFactoryProxyMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    @_expose(!Cxx)
    private(set) var connection: WebKit.GPUConnectionToWebProcess?
    // By identifier, which ObjectIdentifier makes unique across the three kinds: removed before the receiver, so that its
    // messages stop before its forwarder goes. Declared first, so that it goes first.
    private var registrations: [UInt64: IPC.SwiftReceiverRegistration] = [:]
    private var cdms: [UInt64: RemoteCDMProxy] = [:]
    private var instances: [UInt64: RemoteCDMInstanceProxy] = [:]
    private var sessions: [UInt64: RemoteCDMInstanceSessionProxy] = [:]

    @_expose(!Cxx)
    init(connection: WebKit.GPUConnectionToWebProcess) {
        self.connection = connection
        self.messageForwarder = WebKit.RemoteCDMFactoryProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteCDMFactoryProxyMessageForwarder {
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

    @_expose(!Cxx)
    @MainActor
    func hasInstance(_ identifier: UInt64) -> Bool {
        instances[identifier] != nil
    }

    // The C++ instance of a CDM instance, for the media players: ClearKey's have none.
    @_expose(!Cxx)
    @MainActor
    func cxxInstance(_ identifier: UInt64) -> WebCore.CDMInstance? {
        instances[identifier]?.cxxInstance
    }

    private func add(cdm: RemoteCDMProxy, identifier: UInt64) {
        guard let connection else {
            return
        }
        registrations[identifier] = IPC.registerSwiftReceiver(connection, cdm.getMessageReceiver(), .RemoteCDMProxy, identifier)
        cdms[identifier] = cdm
    }

    @_expose(!Cxx)
    func add(instance: RemoteCDMInstanceProxy, identifier: UInt64) {
        guard let connection else {
            return
        }
        registrations[identifier] = IPC.registerSwiftReceiver(connection, instance.getMessageReceiver(), .RemoteCDMInstanceProxy, identifier)
        instances[identifier] = instance
    }

    @_expose(!Cxx)
    func add(session: RemoteCDMInstanceSessionProxy, identifier: UInt64) {
        guard let connection else {
            return
        }
        registrations[identifier] = IPC.registerSwiftReceiver(
            connection,
            session.getMessageReceiver(),
            .RemoteCDMInstanceSessionProxy,
            identifier
        )
        sessions[identifier] = session
    }

    // MARK: Messages

    @MainActor
    func createCDM(
        connection: IPC.Connection,
        keySystem: String?,
        mediaKeysHashSalt: String?
    ) -> (identifier: IPCTypes.RemoteCDMIdentifier?, configuration: IPCTypes.RemoteCDMConfiguration) {
        let noCDM = IPCTypes.RemoteCDMConfiguration(
            supportedInitDataTypes: [],
            supportedRobustnesses: [],
            supportsServerCertificates: false,
            supportsSessions: false,
            logIdentifier: 0
        )
        guard let gpuConnection = self.connection,
            let handle = WebKit.RemoteCDMPrivateHandle.create(
                gpuConnection,
                IPCCoding.WTFString.cxxString(keySystem),
                IPCCoding.WTFString.cxxString(mediaKeysHashSalt)
            )
        else {
            return (nil, noCDM)
        }
        let cdm = RemoteCDMProxy(factory: self, cdm: handle, isClearKey: ClearKey.supportsKeySystem(keySystem))
        let identifier = WTF.ObjectIdentifierMainThreadAccessTraits.generateIdentifierInternal()
        add(cdm: cdm, identifier: identifier)
        return (IPCTypes.RemoteCDMIdentifier(rawValue: identifier), cdm.configuration)
    }

    @MainActor
    func supportsKeySystem(connection: IPC.Connection, keySystem: String?) -> Bool {
        ClearKey.supportsKeySystem(keySystem) || FairPlayCDM.supportsKeySystem(keySystem)
    }

    @MainActor
    func removeInstance(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceIdentifier) {
        guard instances[identifier.rawValue] != nil else {
            return
        }
        registrations.removeValue(forKey: identifier.rawValue)
        // With its C++ instance, before the GPU process checks whether it may exit, which it may once this was the last
        // instance.
        instances.removeValue(forKey: identifier.rawValue)
        guard let gpuConnection = self.connection else {
            return
        }
        if allowsExitUnderMemoryPressure {
            gpuConnection.tryExitIfUnusedAndUnderMemoryPressure()
        }
    }

    @MainActor
    func removeSession(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceSessionIdentifier) {
        guard sessions[identifier.rawValue] != nil else {
            return
        }
        registrations.removeValue(forKey: identifier.rawValue)
        sessions.removeValue(forKey: identifier.rawValue)
    }
}

extension RemoteCDMFactoryProxy: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        instances.isEmpty
    }

    // The CDMs no longer reach the connection, and no receiver's messages are routed.
    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        registrations.removeAll()
        cdms.removeAll()
        connection = nil
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func cdmInstance(_ identifier: UInt64) -> WebKit.RefPtrCDMInstance {
        MainActor.preconditionIsolated()
        return WebKit.RefPtrCDMInstance(state.cdmFactory?.cxxInstance(identifier))
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
