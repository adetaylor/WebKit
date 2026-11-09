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

extension WebKit.RemoteCDMSupportedConfigurationCompletionHandler: @unsafe CxxConsumingCompletionHandler {
    typealias Argument = WebKit.RemoteCDMEncodedConfiguration
}

// Receives the messages of one of the web process's RemoteCDMs. ClearKey's instances are WebCoreEME's; its C++
// CDMPrivate answers only the configuration algorithm's questions. Other CDMs are C++.
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

    // The configuration the web process's RemoteCDM reports: ClearKey's, or the C++ CDM's.
    @_expose(!Cxx)
    func configuration(_ cxxConfiguration: borrowing WebKit.RemoteCDMConfiguration) -> IPCTypes.RemoteCDMConfiguration {
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
            supportedInitDataTypes: Self.swiftStrings(cxxConfiguration.supportedInitDataTypes),
            supportedRobustnesses: Self.swiftStrings(cxxConfiguration.supportedRobustnesses),
            supportsServerCertificates: cxxConfiguration.supportsServerCertificates,
            supportsSessions: cxxConfiguration.supportsSessions,
            logIdentifier: cxxConfiguration.logIdentifier
        )
    }

    @MainActor
    func getSupportedConfiguration(
        connection: IPC.Connection,
        candidateConfiguration: CxxDecodedArguments.RemoteCDMProxy.GetSupportedConfigurationCandidateConfiguration,
        access: IPCTypes.CDMPrivateLocalStorageAccess
    ) async -> IPCTypes.CDMKeySystemConfiguration? {
        await withCheckedContinuation { continuation in
            WebKit.getSupportedRemoteCDMConfiguration(
                cdm,
                candidateConfiguration,
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
            identifier: identifier,
            proxy: proxy
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

    private static func swiftStrings(_ strings: borrowing WebKit.RemoteCDMStrings) -> [String?] {
        var result: [String?] = []
        for index in 0..<WebKit.remoteCDMStringCount(strings) {
            result.append(IPCCoding.WTFString.swiftString(WebKit.remoteCDMString(strings, index)))
        }
        return result
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
