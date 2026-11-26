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
import wtf

// The members of WebSWServerToContextConnection that are Swift. The class's SWIFT_PRIVATE_FILEID names this file, so
// its private fields are visible here and nowhere else in Swift.
extension WebKit.WebSWServerToContextConnection {

    @cxx
    @implementation
    func terminateIdleServiceWorkers() {
        if isServerContextConnection(), let server = server() {
            server.terminateIdleServiceWorkers(self)
        }
    }

    @cxx
    @implementation
    func startFetch(_ task: WebKit.ServiceWorkerFetchTask) {
        task.start(self)
    }

    // MARK: Fetches and downloads

    // MARK: Messages to the SW host WebProcess

    @cxx
    @implementation
    override func updateAppInitiatedValue(
        _ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier,
        _ lastNavigationWasAppInitiated: WebCore.LastNavigationWasAppInitiated
    ) {
        guard let connection = protectedIPCConnection().get(),
            let identifier = IPCTypes.ServiceWorkerIdentifier(rawValue: serviceWorkerIdentifier.toUInt64())
        else {
            return
        }
        WebSWContextManagerConnectionMessages.updateAppInitiatedValue(
            on: connection,
            to: 0,
            serviceWorkerIdentifier: identifier,
            lastNavigationWasAppInitiated: lastNavigationWasAppInitiated == .Yes ? .yes : .no
        )
    }

    @cxx
    @implementation
    override func fireInstallEvent(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        guard let connection = protectedIPCConnection().get(),
            let identifier = IPCTypes.ServiceWorkerIdentifier(rawValue: serviceWorkerIdentifier.toUInt64())
        else {
            return
        }
        WebSWContextManagerConnectionMessages.fireInstallEvent(
            on: connection,
            to: 0,
            identifier: identifier
        )
    }

    @cxx
    @implementation
    override func fireActivateEvent(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        guard let connection = protectedIPCConnection().get(),
            let identifier = IPCTypes.ServiceWorkerIdentifier(rawValue: serviceWorkerIdentifier.toUInt64())
        else {
            return
        }
        WebSWContextManagerConnectionMessages.fireActivateEvent(
            on: connection,
            to: 0,
            identifier: identifier
        )
    }

    @cxx
    @implementation
    func setThrottleState(_ isThrottleable: Bool) {
        m_isThrottleable = isThrottleable
        if let connection = protectedIPCConnection().get() {
            WebSWContextManagerConnectionMessages.setThrottleState(
                on: connection,
                to: 0,
                isThrottleable: isThrottleable
            )
        }
    }

    @cxx
    @implementation
    override func setInspectable(_ inspectable: WebCore.ServiceWorkerIsInspectable) {
        if m_isInspectable == inspectable {
            return
        }

        m_isInspectable = inspectable
        if let connection = protectedIPCConnection().get() {
            WebSWContextManagerConnectionMessages.setInspectable(
                on: connection,
                to: 0,
                inspectable: inspectable == .Yes ? .yes : .no
            )
        }
    }

    // MARK: Messages back from the SW host process

    @cxx
    @implementation
    func didFinishActivation(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        guard let worker = WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier) else {
            return
        }

        let state = worker.state()
        if state == .Redundant {
            return
        }

        do {
            try messageCheck("state == ServiceWorkerState::Activating") { state == .Activating }
        } catch {
            // This runs only while one of the connection's messages is dispatched, so the connection exists.
            // swift-format-ignore: NeverForceUnwrap
            markMessageInvalid(error, on: protectedIPCConnection().get()!)
            return
        }
        didFinishActivationInBase(serviceWorkerIdentifier)
    }
}
