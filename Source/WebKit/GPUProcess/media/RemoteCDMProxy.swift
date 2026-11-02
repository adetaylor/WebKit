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

extension WebKit.RemoteCDMSupportedConfigurationCompletionHandler: @unsafe CxxConsumingCompletionHandler {
    typealias Argument = WebKit.RemoteCDMEncodedConfiguration
}

// Receives the messages of one of the web process's RemoteCDMs, for the CDMPrivate it was created with.
@_expose(Cxx)
final class RemoteCDMProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMProxyMessageForwarder?
    private let registry: WebKit.RemoteCDMRegistryWeakReference
    private let cdm: WebKit.RemoteCDMPrivateHandle

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(registry: WebKit.RemoteCDMRegistry, cdm: WebKit.RemoteCDMPrivateHandle) {
        self.registry = WebKit.RemoteCDMRegistryWeakReference(registry)
        self.cdm = cdm
        self.messageForwarder = WebKit.RemoteCDMProxyMessageForwarder.create(target: self)
    }

    @used
    func getMessageReceiver() -> RefRemoteCDMProxyMessageForwarder {
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
    func getSupportedConfiguration(
        connection: IPC.Connection,
        candidateConfiguration: IPCTypes.CDMKeySystemConfiguration,
        access: IPCTypes.CDMPrivateLocalStorageAccess
    ) async -> IPCTypes.CDMKeySystemConfiguration? {
        var builder = remoteCDMKeySystemConfigurationBuilder(candidateConfiguration)
        return await withCheckedContinuation { continuation in
            WebKit.getSupportedRemoteCDMConfiguration(
                cdm,
                &builder,
                access == .allowed,
                consuming: .init { (encodedConfiguration: consuming WebKit.RemoteCDMEncodedConfiguration) in
                    var decoder = WebKit.swiftDecoder(encodedConfiguration)
                    let configuration = try? IPCCoding.StdOptional<IPCTypes.CxxName.WebCore_CDMKeySystemConfiguration>
                        .decode(from: &decoder)
                    continuation.resume(returning: configuration ?? nil)
                }
            )
        }
    }

    @MainActor
    func createInstance(
        connection: IPC.Connection
    ) -> (identifier: IPCTypes.RemoteCDMInstanceIdentifier?, configuration: IPCTypes.RemoteCDMInstanceConfiguration) {
        var configuration = WebKit.RemoteCDMInstanceConfiguration()
        let identifier = IPCTypes.RemoteCDMInstanceIdentifier(rawValue: WebKit.createRemoteCDMInstance(registry, cdm, &configuration))
        return (identifier, IPCTypes.RemoteCDMInstanceConfiguration(keySystem: IPCCoding.WTFString.swiftString(configuration.keySystem)))
    }

    @MainActor
    func loadAndInitialize(connection: IPC.Connection) {
        cdm.loadAndInitialize()
    }

    @MainActor
    func setLogIdentifier(connection: IPC.Connection, logIdentifier: UInt64) {
        cdm.setLogIdentifier(logIdentifier)
    }
}

// The C++ form of a configuration that a Swift receiver hands to a CDM.
func remoteCDMKeySystemConfigurationBuilder(
    _ configuration: IPCTypes.CDMKeySystemConfiguration
) -> WebKit.RemoteCDMKeySystemConfigurationBuilder {
    var builder = WebKit.RemoteCDMKeySystemConfigurationBuilder()
    builder.setLabel(IPCCoding.WTFString.cxxString(configuration.label))
    for type in configuration.initDataTypes {
        builder.appendInitDataType(IPCCoding.WTFString.cxxString(type))
    }
    for (isVideo, capabilities) in [(false, configuration.audioCapabilities), (true, configuration.videoCapabilities)] {
        for capability in capabilities {
            builder.appendCapability(
                isVideo,
                IPCCoding.WTFString.cxxString(capability.contentType),
                IPCCoding.WTFString.cxxString(capability.robustness),
                capability.encryptionScheme != nil,
                capability.encryptionScheme == .cbcs
            )
        }
    }
    builder.setDistinctiveIdentifier(configuration.distinctiveIdentifier.rawValue)
    builder.setPersistentState(configuration.persistentState.rawValue)
    for type in configuration.sessionTypes {
        builder.appendSessionType(type.rawValue)
    }
    return builder
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
