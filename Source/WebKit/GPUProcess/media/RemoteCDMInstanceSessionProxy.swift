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

// Receives the messages of one of the web process's RemoteCDMInstanceSessions, for its CDM session.
@_expose(Cxx)
final class RemoteCDMInstanceSessionProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteCDMInstanceSessionProxyMessageForwarder?
    private weak var factory: RemoteCDMFactoryState?
    private weak var cdm: RemoteCDMProxy?
    private let backend: any RemoteCDMSessionBackend

    @_expose(!Cxx)
    init(factory: RemoteCDMFactoryState, cdm: RemoteCDMProxy, backend: any RemoteCDMSessionBackend) {
        self.factory = factory
        self.cdm = cdm
        self.backend = backend
        self.messageForwarder = WebKit.RemoteCDMInstanceSessionProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteCDMInstanceSessionProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        guard cdm != nil, let proxy = factory?.proxy else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return proxy.sharedPreferencesForWebProcess()
    }

    @MainActor
    func setLogIdentifier(connection: IPC.Connection, logIdentifier: UInt64) {
        backend.setLogIdentifier(logIdentifier)
    }

    @MainActor
    func requestLicense(
        connection: IPC.Connection,
        type: IPCTypes.CDMSessionType,
        keyGroupingStrategy: IPCTypes.CDMKeyGroupingStrategy,
        initDataType: String?,
        initData: WebCore.SharedBuffer?
    ) async -> RemoteCDMLicense {
        guard let initData, let cdm else {
            return remoteCDMNoLicense
        }
        return await backend.requestLicense(type, keyGroupingStrategy, initDataType, initData, cdm: cdm.cdm)
    }

    @MainActor
    func updateLicense(
        connection: IPC.Connection,
        sessionId: String?,
        type: IPCTypes.CDMSessionType,
        response: WebCore.SharedBuffer?
    ) async -> RemoteCDMLicenseUpdate {
        guard let response else {
            return (true, nil, nil, nil, false)
        }
        guard let cdm else {
            return remoteCDMFailedUpdate
        }
        return await backend.updateLicense(sessionId, type, response, cdm: cdm.cdm)
    }

    @MainActor
    func loadSession(
        connection: IPC.Connection,
        type: IPCTypes.CDMSessionType,
        sessionId: String?,
        origin: String?
    ) async -> RemoteCDMLoadedSession {
        guard let cdm else {
            return remoteCDMNotLoaded
        }
        return await backend.loadSession(type, sessionId, origin, cdm: cdm.cdm)
    }

    @MainActor
    func closeSession(connection: IPC.Connection, sessionId: String?) async {
        await backend.closeSession(sessionId)
    }

    @MainActor
    func removeSessionData(
        connection: IPC.Connection,
        sessionId: String?,
        type: IPCTypes.CDMSessionType
    ) async -> RemoteCDMRemovedSessionData {
        await backend.removeSessionData(sessionId, type)
    }

    @MainActor
    func storeRecordOfKeyUsage(connection: IPC.Connection, sessionId: String?) {
        backend.storeRecordOfKeyUsage(sessionId)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
