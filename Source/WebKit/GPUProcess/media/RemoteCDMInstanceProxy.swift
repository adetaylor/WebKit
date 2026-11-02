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

extension WebKit.RemoteCDMInstanceSuccessCompletionHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebCore.CDMInstanceSuccessValue
}

// Receives the messages of one of the web process's RemoteCDMInstances, for the CDMInstance it was created
// with. The instance's client is RemoteCDMRegistry's RemoteCDMInstanceClient.
@_expose(Cxx)
final class RemoteCDMInstanceProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMInstanceProxyMessageForwarder?
    private let registry: WebKit.RemoteCDMRegistryWeakReference
    private let cdm: WebKit.RemoteCDMPrivateHandleWeakReference
    private let instance: WebCore.CDMInstance
    private let logIdentifier: UInt64

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(registry: WebKit.RemoteCDMRegistry, cdm: WebKit.RemoteCDMPrivateHandle, instance: WebCore.CDMInstance, logIdentifier: UInt64) {
        self.registry = WebKit.RemoteCDMRegistryWeakReference(registry)
        self.cdm = WebKit.RemoteCDMPrivateHandleWeakReference(cdm)
        self.instance = instance
        self.logIdentifier = logIdentifier
        self.messageForwarder = WebKit.RemoteCDMInstanceProxyMessageForwarder.create(target: self)
    }

    @used
    func getMessageReceiver() -> RefRemoteCDMInstanceProxyMessageForwarder {
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
    func createSession(connection: IPC.Connection, logIdentifier: UInt64) -> IPCTypes.RemoteCDMInstanceSessionIdentifier? {
        IPCTypes.RemoteCDMInstanceSessionIdentifier(
            rawValue: WebKit.createRemoteCDMInstanceSession(registry, cdm, instance, self.logIdentifier)
        )
    }

    @MainActor
    func initializeWithConfiguration(
        connection: IPC.Connection,
        configuration: IPCTypes.CDMKeySystemConfiguration,
        distinctiveIdentifiersAllowed: IPCTypes.CDMInstanceAllowDistinctiveIdentifiers,
        persistentStateAllowed: IPCTypes.CDMInstanceAllowPersistentState
    ) async -> IPCTypes.CDMInstanceSuccessValue {
        var builder = remoteCDMKeySystemConfigurationBuilder(configuration)
        let success = await withCheckedContinuation { continuation in
            WebKit.initializeRemoteCDMInstance(
                instance,
                &builder,
                distinctiveIdentifiersAllowed == .yes,
                persistentStateAllowed == .yes,
                consuming: .init(continuation)
            )
        }
        return success == .Succeeded ? .succeeded : .failed
    }

    @MainActor
    func setServerCertificate(connection: IPC.Connection, certificate: WebCore.SharedBuffer) async -> IPCTypes.CDMInstanceSuccessValue {
        let success = await withCheckedContinuation { continuation in
            WebKit.setRemoteCDMInstanceServerCertificate(instance, certificate, consuming: .init(continuation))
        }
        return success == .Succeeded ? .succeeded : .failed
    }

    @MainActor
    func setStorageDirectory(connection: IPC.Connection, directory: String?) {
        guard cdm.get() != nil, let registry = registry.get() else {
            return
        }
        let mediaKeysStorageDirectory = IPCCoding.WTFString.swiftString(registry.mediaKeysStorageDirectory()) ?? ""
        // Compared by code point, which for Swift strings is what WTF::String::startsWith's comparison of code
        // units gives, rather than by Character.
        guard !mediaKeysStorageDirectory.isEmpty, let directory, directory.utf8.starts(with: mediaKeysStorageDirectory.utf8) else {
            return
        }
        WebKit.setRemoteCDMInstanceStorageDirectory(instance, IPCCoding.WTFString.cxxString(directory))
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
