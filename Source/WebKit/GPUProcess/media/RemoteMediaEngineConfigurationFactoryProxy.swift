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

#if ENABLE_GPU_PROCESS_MEDIA_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal
import wtf

// Receives one web process's media capabilities queries, which WebCore's media engine configuration factories answer. The
// connection's Swift state owns it (GPUConnectionState).
@_expose(Cxx)
final class RemoteMediaEngineConfigurationFactoryProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteMediaEngineConfigurationFactoryProxyMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    private var connection: WebKit.GPUConnectionToWebProcess?

    @_expose(!Cxx)
    init(connection: WebKit.GPUConnectionToWebProcess) {
        self.connection = connection
        self.messageForwarder = WebKit.RemoteMediaEngineConfigurationFactoryProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteMediaEngineConfigurationFactoryProxyMessageForwarder {
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

    // MARK: Messages

    @MainActor
    func createDecodingConfiguration(
        connection: IPC.Connection,
        configuration: WebCore.PlatformMediaDecodingConfiguration
    ) -> WebCore.PlatformMediaCapabilitiesDecodingInfo {
        WebKit.createMediaDecodingConfiguration(configuration)
    }

    @MainActor
    func createEncodingConfiguration(
        connection: IPC.Connection,
        configuration: WebCore.PlatformMediaEncodingConfiguration
    ) -> WebCore.PlatformMediaCapabilitiesEncodingInfo {
        WebKit.createMediaEncodingConfiguration(configuration)
    }
}

extension RemoteMediaEngineConfigurationFactoryProxy: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        true
    }

    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        connection = nil
    }
}

#endif // ENABLE_GPU_PROCESS_MEDIA_SWIFT
