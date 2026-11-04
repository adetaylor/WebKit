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

// Receives the messages of the web process's RemoteCDMFactory, and owns the GPU process's CDMs, CDM instances and
// sessions, whose messages RemoteCDMRegistry routes.
@_expose(Cxx)
final class RemoteCDMFactoryProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMFactoryProxyMessageForwarder?
    private let registryReference: WebKit.RemoteCDMRegistryWeakReference
    private var cdms: [UInt64: RemoteCDMProxy] = [:]
    private var instances: [UInt64: RemoteCDMInstanceProxy] = [:]
    private var sessions: [UInt64: RemoteCDMInstanceSessionProxy] = [:]

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(registry: WebKit.RemoteCDMRegistry) {
        self.registryReference = WebKit.RemoteCDMRegistryWeakReference(registry)
        self.messageForwarder = WebKit.RemoteCDMFactoryProxyMessageForwarder.create(target: self)
    }

    @used
    func getMessageReceiver() -> RefRemoteCDMFactoryProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        guard let registry = registry() else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return registry.sharedPreferencesForWebProcess()
    }

    // When the web process's connection closes, or as the registry is destroyed, so it doesn't reach the registry.
    @used
    func removeCDMs() {
        cdms.removeAll()
    }

    @_expose(!Cxx)
    func registry() -> WebKit.RemoteCDMRegistry? {
        registryReference.get()
    }

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
        var cxxConfiguration = WebKit.RemoteCDMConfiguration()
        guard let registry = registry(),
            let handle = registry.createCDM(
                IPCCoding.WTFString.cxxString(keySystem),
                IPCCoding.WTFString.cxxString(mediaKeysHashSalt),
                &cxxConfiguration
            )
        else {
            return (nil, noCDM)
        }
        let cdm = RemoteCDMProxy(factory: self, cdm: handle, isClearKey: ClearKey.supportsKeySystem(keySystem))
        let configuration = cdm.configuration(cxxConfiguration)
        let identifier = registry.generateCDMIdentifier()
        registry.addCDMRoute(identifier, cdm.getMessageReceiver().ptr())
        cdms[identifier] = cdm
        return (IPCTypes.RemoteCDMIdentifier(rawValue: identifier), configuration)
    }

    @MainActor
    func supportsKeySystem(connection: IPC.Connection, keySystem: String?) -> Bool {
        guard let registry = registry() else {
            return false
        }
        return ClearKey.supportsKeySystem(keySystem) || registry.supportsKeySystem(IPCCoding.WTFString.cxxString(keySystem))
    }

    @MainActor
    func removeInstance(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceIdentifier) {
        guard let registry = registry() else {
            return
        }
        registry.removeInstance(identifier.rawValue)
        instances.removeValue(forKey: identifier.rawValue)
    }

    @MainActor
    func removeSession(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceSessionIdentifier) {
        guard let registry = registry() else {
            return
        }
        registry.removeSession(identifier.rawValue)
        sessions.removeValue(forKey: identifier.rawValue)
    }

    @_expose(!Cxx)
    func add(instance: RemoteCDMInstanceProxy, identifier: UInt64, registry: WebKit.RemoteCDMRegistry) {
        registry.addInstanceRoute(identifier, instance.getMessageReceiver().ptr())
        instances[identifier] = instance
    }

    @_expose(!Cxx)
    func add(session: RemoteCDMInstanceSessionProxy, identifier: UInt64, registry: WebKit.RemoteCDMRegistry) {
        registry.addSessionRoute(identifier, session.getMessageReceiver().ptr())
        sessions[identifier] = session
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
