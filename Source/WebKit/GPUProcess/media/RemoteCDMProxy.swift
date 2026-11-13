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

// Receives the messages of one of the web process's RemoteCDMs. ClearKey's instances are WebCoreEME's; its C++
// CDMPrivate answers only the configuration algorithm's questions. The other CDM is FairPlay Streaming's.
@_expose(Cxx)
final class RemoteCDMProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMProxyMessageForwarder?
    private weak var factory: RemoteCDMFactoryState?
    private let isClearKey: Bool
    @_expose(!Cxx)
    let cdm: WebKit.RemoteCDMPrivateHandle

    @_expose(!Cxx)
    init(factory: RemoteCDMFactoryState, cdm: WebKit.RemoteCDMPrivateHandle, isClearKey: Bool) {
        self.factory = factory
        self.cdm = cdm
        self.isClearKey = isClearKey
        self.messageForwarder = WebKit.RemoteCDMProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteCDMProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        guard let proxy = factory?.proxy else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return proxy.sharedPreferencesForWebProcess()
    }

    // The configuration the web process's RemoteCDM reports: ClearKey's, or FairPlay Streaming's.
    @_expose(!Cxx)
    var configuration: IPCTypes.RemoteCDMConfiguration {
        if isClearKey {
            return IPCTypes.RemoteCDMConfiguration(
                supportedInitDataTypes: ClearKey.supportedInitDataTypes,
                supportedRobustnesses: ClearKey.supportedRobustnesses,
                supportsServerCertificates: ClearKey.supportsServerCertificates,
                supportsSessions: ClearKey.supportsSessions,
                logIdentifier: 0
            )
        }
        return IPCTypes.RemoteCDMConfiguration(
            supportedInitDataTypes: FairPlayCDM.supportedInitDataTypes,
            supportedRobustnesses: FairPlayCDM.supportedRobustnesses,
            supportsServerCertificates: FairPlayCDM.supportsServerCertificates,
            supportsSessions: FairPlayCDM.supportsSessions,
            logIdentifier: 0
        )
    }

    @MainActor
    func getSupportedConfiguration(
        connection: IPC.Connection,
        candidateConfiguration: IPCTypes.CDMKeySystemConfiguration,
        access: IPCTypes.CDMPrivateLocalStorageAccess
    ) async -> IPCTypes.CDMKeySystemConfiguration? {
        let candidate = EMEKeySystemConfiguration(candidateConfiguration)
        let localStorageAccessAllowed = access == .allowed
        let configuration =
            if isClearKey {
                CDMSupportedConfiguration.supportedConfiguration(
                    candidate,
                    localStorageAccessAllowed: localStorageAccessAllowed,
                    answers: ClearKey.ConfigurationAnswers()
                )
            } else {
                CDMSupportedConfiguration.supportedConfiguration(
                    candidate,
                    localStorageAccessAllowed: localStorageAccessAllowed,
                    answers: FairPlayCDM.ConfigurationAnswers()
                )
            }
        return configuration.map { IPCTypes.CDMKeySystemConfiguration($0) }
    }

    @MainActor
    func createInstance(
        connection: IPC.Connection
    ) -> (identifier: IPCTypes.RemoteCDMInstanceIdentifier?, configuration: IPCTypes.RemoteCDMInstanceConfiguration) {
        let noInstance = (IPCTypes.RemoteCDMInstanceIdentifier?.none, IPCTypes.RemoteCDMInstanceConfiguration(keySystem: nil))
        guard let factory, let proxy = factory.proxy else {
            return noInstance
        }
        let identifier = WebKit.RemoteCDMFactoryProxy.generateInstanceIdentifier()
        let backend: any RemoteCDMInstanceBackend
        let keySystem: String?
        if isClearKey {
            backend = ClearKeyInstanceBackend()
            keySystem = ClearKey.keySystem
        } else {
            var cxxKeySystem = WTF.String()
            var fairPlayInstanceToken: UInt64 = 0
            guard let instance = WebKit.createRemoteCDMInstance(proxy, cdm, identifier, &cxxKeySystem, &fairPlayInstanceToken) else {
                return noInstance
            }
            backend = FairPlayCDMInstanceBackend(instance, fairPlayInstance: FairPlayInstance.instance(forToken: fairPlayInstanceToken))
            keySystem = IPCCoding.WTFString.swiftString(cxxKeySystem)
        }
        let logIdentifier = isClearKey ? 0 : cdm.logIdentifier()
        factory.add(
            instance: RemoteCDMInstanceProxy(factory: factory, cdm: self, backend: backend, logIdentifier: logIdentifier),
            identifier: identifier
        )
        return (IPCTypes.RemoteCDMInstanceIdentifier(rawValue: identifier), IPCTypes.RemoteCDMInstanceConfiguration(keySystem: keySystem))
    }

    @MainActor
    func loadAndInitialize(connection: IPC.Connection) {
        if !isClearKey {
            cdm.loadAndInitialize()
        }
    }

    @MainActor
    func setLogIdentifier(connection: IPC.Connection, logIdentifier: UInt64) {
        if !isClearKey {
            cdm.setLogIdentifier(logIdentifier)
        }
    }
}

extension EMEKeySystemConfiguration {
    init(_ configuration: IPCTypes.CDMKeySystemConfiguration) {
        self.init(
            label: configuration.label,
            initDataTypes: configuration.initDataTypes,
            audioCapabilities: configuration.audioCapabilities.map(EMEMediaCapability.init),
            videoCapabilities: configuration.videoCapabilities.map(EMEMediaCapability.init),
            distinctiveIdentifier: EMERequirement(configuration.distinctiveIdentifier),
            persistentState: EMERequirement(configuration.persistentState),
            sessionTypes: configuration.sessionTypes.map(EMESessionType.init)
        )
    }
}

extension IPCTypes.CDMKeySystemConfiguration {
    fileprivate init(_ configuration: EMEKeySystemConfiguration) {
        self.init(
            label: configuration.label,
            initDataTypes: configuration.initDataTypes,
            audioCapabilities: configuration.audioCapabilities.map(IPCTypes.CDMMediaCapability.init),
            videoCapabilities: configuration.videoCapabilities.map(IPCTypes.CDMMediaCapability.init),
            distinctiveIdentifier: IPCTypes.CDMRequirement(configuration.distinctiveIdentifier),
            persistentState: IPCTypes.CDMRequirement(configuration.persistentState),
            sessionTypes: configuration.sessionTypes.map(IPCTypes.CDMSessionType.init)
        )
    }
}

extension EMEMediaCapability {
    fileprivate init(_ capability: IPCTypes.CDMMediaCapability) {
        self.init(
            contentType: capability.contentType,
            robustness: capability.robustness,
            encryptionScheme: capability.encryptionScheme.map { $0 == .cbcs ? .cbcs : .cenc }
        )
    }
}

extension IPCTypes.CDMMediaCapability {
    fileprivate init(_ capability: EMEMediaCapability) {
        self.init(
            contentType: capability.contentType,
            robustness: capability.robustness,
            encryptionScheme: capability.encryptionScheme.map { $0 == .cbcs ? .cbcs : .cenc }
        )
    }
}

extension EMERequirement {
    fileprivate init(_ requirement: IPCTypes.CDMRequirement) {
        switch requirement {
        case .required:
            self = .required
        case .optional:
            self = .optional
        case .notAllowed:
            self = .notAllowed
        }
    }
}

extension IPCTypes.CDMRequirement {
    fileprivate init(_ requirement: EMERequirement) {
        switch requirement {
        case .required:
            self = .required
        case .optional:
            self = .optional
        case .notAllowed:
            self = .notAllowed
        }
    }
}

extension EMESessionType {
    fileprivate init(_ sessionType: IPCTypes.CDMSessionType) {
        switch sessionType {
        case .temporary:
            self = .temporary
        case .persistentUsageRecord:
            self = .persistentUsageRecord
        case .persistentLicense:
            self = .persistentLicense
        }
    }
}

extension IPCTypes.CDMSessionType {
    fileprivate init(_ sessionType: EMESessionType) {
        switch sessionType {
        case .temporary:
            self = .temporary
        case .persistentUsageRecord:
            self = .persistentUsageRecord
        case .persistentLicense:
            self = .persistentLicense
        }
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
