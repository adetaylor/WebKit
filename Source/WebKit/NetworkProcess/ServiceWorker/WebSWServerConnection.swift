// Copyright (C) 2026 Apple Inc. All rights reserved.
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

import WebKit_Internal

// MARK: - The connection half

extension WebKit.WebSWServerConnection {
    @cxx
    @implementation
    func sessionID() -> PAL.SessionID {
        // A connection never outlives its server.
        // swift-format-ignore: NeverForceUnwrap
        server()!.sessionID()
    }

    @cxx
    @implementation
    func hasMatchingClient(_ domain: WebCore.RegistrableDomain) -> Bool {
        for origin in clientOriginValues() where domain.matches(origin.clientOrigin) {
            return true
        }
        return false
    }

    @cxx
    @implementation
    func setThrottleState(_ isThrottleable: Bool) {
        m_isThrottleable = isThrottleable
        updateThrottleState()
    }

    @cxx
    @implementation
    func gatherClientData(
        _ clientIdentifier: WebCore.ScriptExecutionContextIdentifier
    ) -> WebKit.WebSWServerConnection.OptionalGatheredClientData {
        assert(clientIdentifier.processIdentifier().toUInt64() == identifier().toUInt64())
        guard let clientOrigin = self.clientOrigin(clientIdentifier).value,
            let server = server()
        else {
            return .init()
        }

        return server.gatherClientData(clientOrigin, clientIdentifier)
    }

    @cxx
    @implementation
    func fetchTaskTimedOut(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        guard let server = server(), let worker = server.workerByID(serviceWorkerIdentifier).get() else {
            return
        }

        worker.setHasTimedOutAnyFetchTasks()
        worker.terminate()
    }

    // MARK: Messages to the client web process, and to its context connection if it has one.

    // The IPC connection of the client web process's context connection, if it has one.
    private var contextManagerIPCConnection: IPC.Connection? {
        // A connection never outlives its network connection to the web process.
        // swift-format-ignore: NeverForceUnwrap
        m_networkConnectionToWebProcess.get()!.swContextConnection()?.ipcConnection()
    }

    @cxx
    @implementation
    override func fireUpdateFoundEvent(_ identifier: WebCore.ServiceWorkerRegistrationIdentifier) {
        let registration = IPCTypes.ServiceWorkerRegistrationIdentifier(identifier)
        WebSWClientConnectionMessages.fireUpdateFoundEvent(on: ipcConnection(), to: 0, identifier: registration)
        if let connection = contextManagerIPCConnection {
            WebSWContextManagerConnectionMessages.fireUpdateFoundEvent(on: connection, to: 0, identifier: registration)
        }
    }

    @cxx
    @implementation
    override func setRegistrationLastUpdateTime(
        _ identifier: WebCore.ServiceWorkerRegistrationIdentifier,
        _ lastUpdateTime: WTF.WallTime
    ) {
        let registration = IPCTypes.ServiceWorkerRegistrationIdentifier(identifier)
        let seconds = lastUpdateTime.secondsSinceEpoch().value()
        WebSWClientConnectionMessages.setRegistrationLastUpdateTime(
            on: ipcConnection(),
            to: 0,
            identifier: registration,
            lastUpdateTime: seconds
        )
        if let connection = contextManagerIPCConnection {
            WebSWContextManagerConnectionMessages.setRegistrationLastUpdateTime(
                on: connection,
                to: 0,
                identifier: registration,
                lastUpdateTime: seconds
            )
        }
    }

    @cxx
    @implementation
    override func setRegistrationUpdateViaCache(
        _ identifier: WebCore.ServiceWorkerRegistrationIdentifier,
        _ updateViaCache: WebCore.ServiceWorkerUpdateViaCache
    ) {
        let registration = IPCTypes.ServiceWorkerRegistrationIdentifier(identifier)
        // The [Swift] form has the C++ enumerators in the C++ order, so the raw values agree.
        // swift-format-ignore: NeverForceUnwrap
        let value = IPCTypes.ServiceWorkerUpdateViaCache(rawValue: updateViaCache.rawValue)!
        WebSWClientConnectionMessages.setRegistrationUpdateViaCache(
            on: ipcConnection(),
            to: 0,
            identifier: registration,
            updateViaCache: value
        )
        if let connection = contextManagerIPCConnection {
            WebSWContextManagerConnectionMessages.setRegistrationUpdateViaCache(
                on: connection,
                to: 0,
                identifier: registration,
                updateViaCache: value
            )
        }
    }

    @cxx
    @implementation
    override func updateWorkerStateInClient(_ worker: WebCore.ServiceWorkerIdentifier, _ state: WebCore.ServiceWorkerState) {
        let identifier = IPCTypes.ServiceWorkerIdentifier(worker)
        // swift-format-ignore: NeverForceUnwrap
        let value = IPCTypes.ServiceWorkerState(rawValue: state.rawValue)!
        WebSWClientConnectionMessages.updateWorkerState(
            on: ipcConnection(),
            to: 0,
            serviceWorkerIdentifier: identifier,
            state: value
        )
        if let connection = contextManagerIPCConnection {
            WebSWContextManagerConnectionMessages.updateWorkerState(
                on: connection,
                to: 0,
                serviceWorkerIdentifier: identifier,
                state: value
            )
        }
    }
}

// MARK: - Scheduling a job

extension WebKit.WebSWServerConnection {
    // The release log's prefix: "%p - WebSWServerConnection::".
    private var logPrefix: Swift.String {
        "\(logAddress().description) - WebSWServerConnection::"
    }

    @cxx
    @implementation
    func scheduleJobInServer(_ jobData: WebCore.ServiceWorkerJobData) {
        if !checkTopOrigin(jobData.topOrigin) {
            return
        }

        assert(!jobData.scopeURL.isNull())
        if jobData.scopeURL.isNull() {
            rejectJobInClient(
                jobData.identifier().jobIdentifier,
                WebCore.ExceptionData(code: .InvalidStateError, message: WTF.String("Scope URL is empty"))
            )
            return
        }

        WebKit.LogChannel.ServiceWorker().releaseLog
            .log(
                "\(self.logPrefix, privacy: .public)Scheduling ServiceWorker job \(jobData.identifier().loggingString().description) in server"
            )
        assert(identifier().toUInt64() == jobData.connectionIdentifier().toUInt64())

        if let server = server() {
            server.scheduleJob(consuming: jobData)
        }
    }
}

// MARK: - The IPC forms of the C++ identifiers

// A C++ ObjectIdentifier is never 0, so each IPC form exists.

extension IPCTypes.ProcessIdentifier {
    init(_ identifier: WebCore.SWServerConnectionIdentifier) {
        // swift-format-ignore: NeverForceUnwrap
        self.init(rawValue: identifier.toUInt64())!
    }
}

extension IPCTypes.ServiceWorkerIdentifier {
    init(_ identifier: WebCore.ServiceWorkerIdentifier) {
        // swift-format-ignore: NeverForceUnwrap
        self.init(rawValue: identifier.toUInt64())!
    }
}

extension IPCTypes.ServiceWorkerRegistrationIdentifier {
    init(_ identifier: WebCore.ServiceWorkerRegistrationIdentifier) {
        // swift-format-ignore: NeverForceUnwrap
        self.init(rawValue: identifier.toUInt64())!
    }
}

extension IPCTypes.FetchIdentifier {
    init(_ identifier: WebCore.FetchIdentifier) {
        // swift-format-ignore: NeverForceUnwrap
        self.init(rawValue: identifier.toUInt64())!
    }
}
