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

internal import WebCore_Private.Core.ExceptionData
internal import WebCore_Private.Core.FetchOptions
internal import WebCore_Private.Core.SWServer
internal import WebCore_Private.Core.SWServerRegistration
internal import WebCore_Private.Core.SWServerToContextConnection
internal import WebCore_Private.Core.SWServerWorker
internal import WebCore_Private.Core.ScriptExecutionContextIdentifier
internal import WebCore_Private.Core.ServiceWorkerContextData
internal import WebCore_Private.Core.ServiceWorkerRoute
internal import WebCore_Private.Core.ServiceWorkerTypes
internal import WebCore_Private.Core.WorkerThreadMode

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

extension WebCore.SWServerWorker {
    @cxx
    @implementation
    func updateAppInitiatedValue(_ lastNavigationWasAppInitiated: WebCore.LastNavigationWasAppInitiated) {
        m_lastNavigationWasAppInitiated = lastNavigationWasAppInitiated

        if !isRunning() {
            return
        }

        if let connection = contextConnection() {
            connection.updateAppInitiatedValue(identifier(), lastNavigationWasAppInitiated)
        }
    }

    @cxx
    @implementation
    func scriptContextFailedToStart(
        _ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier,
        _ message: WTF.String
    ) {
        assert(m_server.get() != nil)
        if let server = m_server.get() {
            server.scriptContextFailedToStart(jobDataIdentifier, self, message)
        }
    }

    @cxx
    @implementation
    func scriptContextStarted(_ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier, _ doesHandleFetch: Bool) {
        m_shouldSkipHandleFetch = !doesHandleFetch
        assert(m_server.get() != nil)
        if let server = m_server.get() {
            server.scriptContextStarted(jobDataIdentifier, self)
        }
    }

    @cxx
    @implementation
    func didFinishInstall(_ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier, _ wasSuccessful: Bool) {
        assert(m_server.get() != nil && state() == .Installing)
        if let server = m_server.get() {
            server.didFinishInstall(jobDataIdentifier, self, wasSuccessful)
        }
    }

    @cxx
    @implementation
    func didFinishActivation() {
        let state = self.state()
        if state == .Redundant {
            return
        }

        assert(m_server.get() != nil)
        // WTFCrash, not precondition: WebKit's crash handler ends the process with SIGKILL, where a Swift trap would end
        // it with SIGTRAP. Release builds drop the assertion's message.
        if state != .Activating {
            WTFCrash()
        }
        if let server = m_server.get() {
            server.didFinishActivation(self)
        }
    }

    @cxx
    @implementation
    func contextTerminated() {
        assert(m_server.get() != nil)
        if let server = m_server.get() {
            server.workerContextTerminated(self)
        }
    }

    /// Sets the worker's skip waiting flag and tries to activate its registration.
    @cxx
    @implementation
    public func skipWaiting() {
        m_isSkipWaitingFlagSet = true

        assert(m_registration.get() != nil || isTerminating())
        if let registration = m_registration.get() {
            registration.tryActivate()
        }
    }

    @cxx
    @implementation
    func setHasPendingEvents(_ hasPendingEvents: Bool) {
        if m_hasPendingEvents == hasPendingEvents {
            return
        }

        m_hasPendingEvents = hasPendingEvents
        if m_hasPendingEvents {
            return
        }

        // Do tryClear/tryActivate, as per https://w3c.github.io/ServiceWorker/#wait-until-method.
        guard let registration = m_registration.get() else {
            return
        }

        if registration.isUnregistered() && registration.tryClear() {
            return
        }

        registration.tryActivate()
    }

    @cxx
    @implementation
    func setState(_ state: WebCore.SWServerWorker.State) {
        assert(state != .Running || m_registration.get() != nil)
        assert(state != .Running || m_state != .Terminating)
        m_state = state

        switch state {
        case .Running:
            needsRunning()
            m_shouldSkipHandleFetch = false
        case .Terminating:
            callWhenActivatedHandler(false)
        case .NotRunning:
            let isActivateEventAlreadyFired = m_isActivateEventFired
            terminationCompleted()
            callWhenActivatedHandler(false)

            // As per https://w3c.github.io/ServiceWorker/#activate, a worker goes to activated even if activating fails.
            if m_data.state == .Activating && isActivateEventAlreadyFired {
                didFinishActivation()
            }
        @unknown default:
            break
        }
    }

    @cxx
    @implementation
    func didFailHeartBeatCheck() {
        terminate()
    }

    @cxx
    @implementation
    func workerThreadMode() -> WebCore.WorkerThreadMode {
        if let server = m_server.get(), server.shouldRunServiceWorkersOnMainThreadForTesting() {
            return .UseMainThread
        }
        if serviceWorkerPageIdentifier().hasValue {
            return .UseMainThread
        }
        return .CreateNewThread
    }

    /// The service worker page of the worker's registration, if it has one.
    @cxx
    @implementation
    public func serviceWorkerPageIdentifier() -> WebCore.OptionalScriptExecutionContextIdentifier {
        guard let registration = m_registration.get() else {
            return WebCore.OptionalScriptExecutionContextIdentifier()
        }
        return registration.serviceWorkerPageIdentifier()
    }

    @cxx
    @implementation
    func decrementFunctionalEventCounter() {
        assert(m_functionalEventCounter != 0)
        // m_functionalEventCounter is an int: at its minimum this wraps rather than traps.
        m_functionalEventCounter &-= 1
        terminateIfPossible()
    }

    @cxx
    @implementation
    func setAsInspected(_ isInspected: Bool) {
        m_isInspected = isInspected
        terminateIfPossible()
    }

    /// Whether the client's controlling registration is this worker's.
    @cxx
    @implementation
    public func isClientActiveServiceWorker(_ clientIdentifier: WebCore.ScriptExecutionContextIdentifier) -> Bool {
        guard let server = m_server.get() else {
            return false
        }
        let registrationIdentifier = server.clientIdentifierToControllingRegistration(clientIdentifier)
        guard let registrationIdentifier = registrationIdentifier.value else {
            return false
        }
        return registrationIdentifier.isEqual(m_data.registrationIdentifier)
    }

    @cxx
    @implementation
    func registerServiceWorkerConnection(_ connectionIdentifier: WebCore.SWServerConnectionIdentifier) {
        _ = m_connectionsWithServiceWorker.addValue(connectionIdentifier)
    }

    @cxx
    @implementation
    func unregisterServiceWorkerConnection(_ connectionIdentifier: WebCore.SWServerConnectionIdentifier) {
        _ = m_connectionsWithServiceWorker.remove(connectionIdentifier)
    }

    @cxx
    @implementation
    func shouldPersistToDisk() -> Bool {
        // Do not persist service workers backing browser extensions to disk.
        guard let registration = m_registration.get() else {
            return false
        }
        return !registration.serviceWorkerPageIdentifier().hasValue
    }
}

extension WebCore.SWServerWorker {
    // https://w3c.github.io/ServiceWorker/#get-router-source
    /// The source of the first route whose condition matches the request.
    @cxx
    @implementation
    public func getRouterSource(
        _ mode: WebCore.FetchOptionsMode,
        _ destination: WebCore.FetchOptionsDestination,
        _ url: WTF.URL,
        _ httpMethod: WTF.String
    ) -> WebCore.OptionalRouterSource {
        let isRunning = isRunning()
        for route in m_routes where route.condition.matches(mode, destination, url, httpMethod, isServiceWorkerRunning: isRunning) {
            return WebCore.OptionalRouterSource(route.source)
        }
        return WebCore.OptionalRouterSource()
    }

    /// The source of a request that no route matches.
    @cxx
    @implementation
    public func defaultRouterSource() -> WebCore.RouterSource {
        WebCore.makeRouterSource(m_shouldSkipHandleFetch ? .Network : .FetchEvent)
    }
}
