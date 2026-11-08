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

// Receives the messages of one of the web process's RemoteCDMInstances, for its CDM instance.
@_expose(Cxx)
final class RemoteCDMInstanceProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMInstanceProxyMessageForwarder?
    private weak var factory: RemoteCDMFactoryProxy?
    private weak var cdm: RemoteCDMProxy?
    private let backend: any RemoteCDMInstanceBackend
    private let logIdentifier: UInt64

    @_expose(!Cxx)
    init(factory: RemoteCDMFactoryProxy, cdm: RemoteCDMProxy, backend: any RemoteCDMInstanceBackend, logIdentifier: UInt64) {
        self.factory = factory
        self.cdm = cdm
        self.backend = backend
        self.logIdentifier = logIdentifier
        self.messageForwarder = WebKit.RemoteCDMInstanceProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteCDMInstanceProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        guard cdm != nil, let registry = factory?.registry() else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return registry.sharedPreferencesForWebProcess()
    }

    @MainActor
    func createSession(connection: IPC.Connection, logIdentifier: UInt64) -> IPCTypes.RemoteCDMInstanceSessionIdentifier? {
        guard let cdm, let factory, let registry = factory.registry() else {
            return nil
        }
        let identifier = registry.generateSessionIdentifier()
        guard let session = backend.makeSession(identifier: identifier, cdm: cdm, connection: connection, logIdentifier: self.logIdentifier) else {
            return nil
        }
        factory.add(
            session: RemoteCDMInstanceSessionProxy(factory: factory, cdm: cdm, backend: session),
            identifier: identifier,
            registry: registry
        )
        return IPCTypes.RemoteCDMInstanceSessionIdentifier(rawValue: identifier)
    }

    @MainActor
    func initializeWithConfiguration(
        connection: IPC.Connection,
        configuration: CxxDecodedArguments.RemoteCDMInstanceProxy.InitializeWithConfigurationConfiguration,
        distinctiveIdentifiersAllowed: IPCTypes.CDMInstanceAllowDistinctiveIdentifiers,
        persistentStateAllowed: IPCTypes.CDMInstanceAllowPersistentState
    ) async -> IPCTypes.CDMInstanceSuccessValue {
        let succeeded = await backend.initialize(
            configuration,
            distinctiveIdentifiersAllowed: distinctiveIdentifiersAllowed == .yes,
            persistentStateAllowed: persistentStateAllowed == .yes
        )
        return succeeded ? .succeeded : .failed
    }

    @MainActor
    func setServerCertificate(connection: IPC.Connection, certificate: WebCore.SharedBuffer) async -> IPCTypes.CDMInstanceSuccessValue {
        await backend.setServerCertificate(certificate) ? .succeeded : .failed
    }

    @MainActor
    func setStorageDirectory(connection: IPC.Connection, directory: String?) {
        guard backend.usesStorageDirectory, cdm != nil, let registry = factory?.registry() else {
            return
        }
        let mediaKeysStorageDirectory = IPCCoding.WTFString.swiftString(registry.mediaKeysStorageDirectory()) ?? ""
        // Compared by code point, which for Swift strings is what WTF::String::startsWith's comparison of code
        // units gives, rather than by Character.
        guard !mediaKeysStorageDirectory.isEmpty, let directory, directory.utf8.starts(with: mediaKeysStorageDirectory.utf8) else {
            return
        }
        backend.setStorageDirectory(directory)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
