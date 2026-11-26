// Copyright (C) 2017 Apple Inc. All rights reserved.
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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import JavaScriptCore_Private.Cxx.YarrInterpreter
#endif
internal import WebCore_Private.Core.FetchOptions
internal import WebCore_Private.Core.SWServer
internal import WebCore_Private.Core.SWServerRegistration
internal import WebCore_Private.Core.SWServerWorker
internal import WebCore_Private.Core.ServiceWorkerTypes

extension WebCore.SWServerRegistration {
    @cxx
    @implementation
    func getNewestWorker() -> WebCore.RefPtrSWServerWorker {
        if m_installingWorker.get() != nil {
            return m_installingWorker
        }
        if m_waitingWorker.get() != nil {
            return m_waitingWorker
        }
        return m_activeWorker
    }

    @cxx
    @implementation
    func addClientServiceWorkerRegistration(_ connectionIdentifier: WebCore.SWServerConnectionIdentifier) {
        _ = m_connectionsWithClientRegistrations.addValue(connectionIdentifier)
    }

    @cxx
    @implementation
    func removeClientServiceWorkerRegistration(_ connectionIdentifier: WebCore.SWServerConnectionIdentifier) {
        _ = m_connectionsWithClientRegistrations.remove(connectionIdentifier)
    }

    // https://w3c.github.io/ServiceWorker/#try-clear-registration-algorithm
    @cxx
    @implementation
    func tryClear() -> Bool {
        if hasClientsUsingRegistration() {
            return false
        }

        if let worker = installingWorker(), worker.hasPendingEvents() {
            return false
        }
        if let worker = waitingWorker(), worker.hasPendingEvents() {
            return false
        }
        if let worker = activeWorker(), worker.hasPendingEvents() {
            return false
        }

        clear()
        return true
    }

    // https://w3c.github.io/ServiceWorker/#try-activate-algorithm
    @cxx
    @implementation
    func tryActivate() {
        // If registration's waiting worker is null, return.
        guard let waitingWorker = self.waitingWorker() else {
            return
        }
        // If registration's active worker is not null and registration's active worker's state is activating, return.
        if let activeWorker = self.activeWorker(), activeWorker.state() == .Activating {
            return
        }

        // Invoke Activate with registration if either of the following is true:
        // - registration's active worker is null.
        // - The result of running Service Worker Has No Pending Events with registration's active worker is true,
        //   and no service worker client is using registration or registration's waiting worker's skip waiting flag is set.
        guard let activeWorker = self.activeWorker() else {
            activate()
            return
        }
        if !activeWorker.hasPendingEvents() && (!hasClientsUsingRegistration() || waitingWorker.isSkipWaitingFlagSet()) {
            activate()
        }
    }

    // https://w3c.github.io/ServiceWorker/#activate
    @cxx
    @implementation
    func activate() {
        // If registration's waiting worker is null, abort these steps.
        if waitingWorker() == nil {
            return
        }

        // If registration's active worker is not null, then:
        if let worker = self.activeWorker() {
            // Terminate registration's active worker.
            worker.terminate()
            // Run the Update Worker State algorithm passing registration's active worker and redundant as the arguments.
            updateWorkerState(worker, .Redundant)
        }
        // Run the Update Registration State algorithm passing registration, "active" and registration's waiting worker as the arguments.
        updateRegistrationState(.Active, waitingWorker())
        // Run the Update Registration State algorithm passing registration, "waiting" and null as the arguments.
        updateRegistrationState(.Waiting, nil)
        // Run the Update Worker State algorithm passing registration's active worker and activating as the arguments.
        // swift-format-ignore: NeverForceUnwrap
        updateWorkerState(self.activeWorker()!, .Activating)
        // FIXME: For each service worker client whose creation URL matches registration's scope url...

        // The registration now has an active worker so we need to check if there are any ready promises that were waiting for this.
        // A registration never outlives its server.
        // swift-format-ignore: NeverForceUnwrap
        server()!.resolveRegistrationReadyRequests(self)

        // For each service worker client who is using registration:
        // - Set client's active worker to registration's active worker.

        // - Invoke Notify Controller Change algorithm with client as the argument.
        notifyClientsOfControllerChange()

        // Invoke Run Service Worker algorithm with activeWorker as the argument.
        // Queue a task to fire the activate event.
        let activeWorker = self.activeWorker()
        assert(activeWorker != nil)
        // A registration never outlives its server.
        // swift-format-ignore: NeverForceUnwrap
        server()!.runServiceWorkerAndFireActivateEvent(activeWorker!)
    }

    // https://w3c.github.io/ServiceWorker/#activate (post activate event steps).
    @cxx
    @implementation
    func didFinishActivation(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        guard let activeWorker = self.activeWorker(), activeWorker.identifier().isEqual(serviceWorkerIdentifier) else {
            return
        }

        // Run the Update Worker State algorithm passing registration's active worker and activated as the arguments.
        updateWorkerState(activeWorker, .Activated)
    }

    // https://w3c.github.io/ServiceWorker/#on-client-unload-algorithm
    @cxx
    @implementation
    func handleClientUnload() {
        if hasClientsUsingRegistration() {
            return
        }
        if isUnregistered() && tryClear() {
            return
        }
        tryActivate()
    }

    @cxx
    @implementation
    public func shouldSoftUpdate(_ options: WebCore.FetchOptions) -> Bool {
        if options.mode == .Navigate {
            return true
        }

        return WebCore.isNonSubresourceRequest(options.destination) && isStale()
    }

    @cxx
    @implementation
    func softUpdate() {
        // A registration never outlives its server.
        // swift-format-ignore: NeverForceUnwrap
        server()!.softUpdate(self)
    }
}
