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

// Receives the messages of the web process's RemoteCDMFactory, creating and removing the GPU process's
// CDMs, CDM instances and sessions in its RemoteCDMRegistry.
@_expose(Cxx)
final class RemoteCDMFactoryProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMFactoryProxyMessageForwarder?
    private let registry: WebKit.RemoteCDMRegistryWeakReference

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(registry: WebKit.RemoteCDMRegistry) {
        self.registry = WebKit.RemoteCDMRegistryWeakReference(registry)
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
        guard let registry = registry.get() else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return registry.sharedPreferencesForWebProcess()
    }

    @MainActor
    func createCDM(
        connection: IPC.Connection,
        keySystem: String?,
        mediaKeysHashSalt: String?
    ) -> (identifier: IPCTypes.RemoteCDMIdentifier?, configuration: IPCTypes.RemoteCDMConfiguration) {
        var configuration = WebKit.RemoteCDMConfiguration()
        var identifier: IPCTypes.RemoteCDMIdentifier?
        if let registry = registry.get() {
            identifier = IPCTypes.RemoteCDMIdentifier(
                rawValue: WebKit.createRemoteCDM(
                    registry,
                    IPCCoding.WTFString.cxxString(keySystem),
                    IPCCoding.WTFString.cxxString(mediaKeysHashSalt),
                    &configuration
                )
            )
        }
        return (identifier, Self.swiftConfiguration(configuration))
    }

    @MainActor
    func supportsKeySystem(connection: IPC.Connection, keySystem: String?) -> Bool {
        guard let registry = registry.get() else {
            return false
        }
        return registry.supportsKeySystem(IPCCoding.WTFString.cxxString(keySystem))
    }

    @MainActor
    func removeInstance(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceIdentifier) {
        if let registry = registry.get() {
            WebKit.removeRemoteCDMInstance(registry, identifier.rawValue)
        }
    }

    @MainActor
    func removeSession(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceSessionIdentifier) {
        if let registry = registry.get() {
            WebKit.removeRemoteCDMInstanceSession(registry, identifier.rawValue)
        }
    }

    private static func swiftConfiguration(_ configuration: borrowing WebKit.RemoteCDMConfiguration) -> IPCTypes.RemoteCDMConfiguration {
        IPCTypes.RemoteCDMConfiguration(
            supportedInitDataTypes: swiftStrings(configuration.supportedInitDataTypes),
            supportedRobustnesses: swiftStrings(configuration.supportedRobustnesses),
            supportsServerCertificates: configuration.supportsServerCertificates,
            supportsSessions: configuration.supportsSessions,
            logIdentifier: configuration.logIdentifier
        )
    }

    private static func swiftStrings(_ strings: borrowing WebKit.RemoteCDMStrings) -> [String?] {
        var result: [String?] = []
        for index in 0..<WebKit.remoteCDMStringCount(strings) {
            result.append(IPCCoding.WTFString.swiftString(WebKit.remoteCDMString(strings, index)))
        }
        return result
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
