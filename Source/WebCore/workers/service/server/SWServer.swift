// Copyright (C) 2017-2025 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.BackgroundFetchEngine
internal import WebCore_Private.Core.ClientOrigin
internal import WebCore_Private.Core.ExceptionData
internal import WebCore_Private.Core.ProcessIdentifier
internal import WebCore_Private.Core.SWOriginStore
internal import WebCore_Private.Core.SWRegistrationStore
internal import WebCore_Private.Core.SWServer
internal import WebCore_Private.Core.SWServerJobQueue
internal import WebCore_Private.Core.SWServerRegistration
internal import WebCore_Private.Core.SWServerToContextConnection
internal import WebCore_Private.Core.SWServerWorker
internal import WebCore_Private.Core.SecurityOriginData
internal import WebCore_Private.Core.ServiceWorkerClientData
internal import WebCore_Private.Core.ServiceWorkerContextData
internal import WebCore_Private.Core.ServiceWorkerJobData
internal import WebCore_Private.Core.ServiceWorkerRegistrationData
internal import WebCore_Private.Core.ServiceWorkerRegistrationKey
internal import WebCore_Private.Core.ServiceWorkerTypes
internal import wtf.Core.text.WTFString

extension WebCore.SWServer {
    @cxx
    @implementation
    func maxRegistrationCount() -> UInt32 {
        if let overrideServiceWorkerRegistrationCountTestingValue = m_overrideServiceWorkerRegistrationCountTestingValue.value {
            return overrideServiceWorkerRegistrationCountTestingValue
        }

        return Self.defaultMaxRegistrationCount()
    }

    @cxx
    @implementation
    public func isImportCompletedForOrigin(_ topOrigin: WebCore.SecurityOriginData) -> Bool {
        if topOrigin.isNull() || topOrigin.isOpaque() {
            return true
        }
        return isImportedTopOrigin(topOrigin)
    }

    @cxx
    @implementation
    func didReconnectServiceWorkerPage(
        _ registration: WebCore.SWServerRegistration,
        _ newServiceWorkerPageIdentifier: WebCore.ScriptExecutionContextIdentifier
    ) {
        if let previousIdentifier = registration.serviceWorkerPageIdentifier().value {
            m_serviceWorkerPageIdentifierToRegistrationMap.remove(previousIdentifier)
        }

        registration.setServiceWorkerPageIdentifier(.init(newServiceWorkerPageIdentifier))
        addServiceWorkerPageIdentifierToRegistration(newServiceWorkerPageIdentifier, registration)

        replaceContextConnectionIfNotInServiceWorkerPageProcess(registration, newServiceWorkerPageIdentifier)
    }

    @cxx
    @implementation
    public func scheduleUnregisterJob(
        _ jobDataIdentifier: WebCore.ServiceWorkerJobDataIdentifier,
        _ registration: WebCore.SWServerRegistration,
        _ contextIdentifier: WebCore.ServiceWorkerOrClientIdentifier,
        _ clientCreationURL: WTF.URL
    ) {
        var jobData = WebCore.ServiceWorkerJobData(jobDataIdentifier, contextIdentifier)
        jobData.clientCreationURL = clientCreationURL
        jobData.topOrigin = Self.topOrigin(registration.data().key)
        jobData.type = .Unregister
        jobData.scopeURL = registration.data().scopeURL

        scheduleJob(consuming: jobData)
    }

    @cxx
    @implementation
    func rejectJob(_ jobData: WebCore.ServiceWorkerJobData, _ exceptionData: WebCore.ExceptionData) {
        logRejectedJob(jobData)
        guard let connection = self.connection(jobData.connectionIdentifier()) else {
            return
        }

        connection.rejectJobInClient(jobData.identifier().jobIdentifier, exceptionData)
    }

    @cxx
    @implementation
    func resolveRegistrationJob(
        _ jobData: WebCore.ServiceWorkerJobData,
        _ registrationData: WebCore.ServiceWorkerRegistrationData,
        _ shouldNotifyWhenResolved: WebCore.ShouldNotifyWhenResolved
    ) {
        logResolvedRegistrationJob(jobData, registrationData)
        guard let connection = self.connection(jobData.connectionIdentifier()) else {
            if shouldNotifyWhenResolved == .Yes && jobData.connectionIdentifier().isEqual(WebCore.Process.identifier()) {
                didResolveRegistrationPromise(nil, registrationData.key)
            }
            return
        }

        connection.resolveRegistrationJobInClient(jobData.identifier().jobIdentifier, registrationData, shouldNotifyWhenResolved)
    }

    @cxx
    @implementation
    func resolveUnregistrationJob(
        _ jobData: WebCore.ServiceWorkerJobData,
        _ registrationKey: WebCore.ServiceWorkerRegistrationKey,
        _ unregistrationResult: Bool
    ) {
        guard let connection = self.connection(jobData.connectionIdentifier()) else {
            return
        }

        connection.resolveUnregistrationJobInClient(jobData.identifier().jobIdentifier, registrationKey, unregistrationResult)
    }

    @cxx
    @implementation
    func scriptContextFailedToStart(
        _ optionalJobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier,
        _ worker: WebCore.SWServerWorker,
        _ message: WTF.String
    ) {
        guard let jobDataIdentifier = optionalJobDataIdentifier.value else {
            return
        }

        logScriptContextFailedToStart(optionalJobDataIdentifier, message)

        guard let jobQueue = jobQueueForWorker(worker).get(), jobQueue.isCurrentlyProcessingJob(jobDataIdentifier) else {
            // The job which started this worker has been canceled, terminate this worker.
            terminatePreinstallationWorker(worker)
            return
        }
        jobQueue.scriptContextFailedToStart(jobDataIdentifier, worker.identifier(), message)
    }

    @cxx
    @implementation
    func scriptContextStarted(_ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier, _ worker: WebCore.SWServerWorker) {
        guard let jobDataIdentifier = jobDataIdentifier.value else {
            return
        }

        guard let jobQueue = jobQueueForWorker(worker).get(), jobQueue.isCurrentlyProcessingJob(jobDataIdentifier) else {
            // The job which started this worker has been canceled, terminate this worker.
            terminatePreinstallationWorker(worker)
            return
        }
        jobQueue.scriptContextStarted(jobDataIdentifier, worker.identifier())
    }

    @cxx
    @implementation
    func terminatePreinstallationWorker(_ worker: WebCore.SWServerWorker) {
        worker.terminate()
        // C++ reference types have no identity comparison in Swift; a live worker's identifier is unique.
        if let registration = worker.registration(),
            let preInstallationWorker = registration.preInstallationWorker(),
            preInstallationWorker.identifier().isEqual(worker.identifier())
        {
            registration.setPreInstallationWorker(nil)
        }
    }

    @cxx
    @implementation
    func didFinishInstall(
        _ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier,
        _ worker: WebCore.SWServerWorker,
        _ wasSuccessful: Bool
    ) {
        logDidFinishInstall(worker, wasSuccessful)

        guard let jobDataIdentifier = jobDataIdentifier.value else {
            return
        }

        if wasSuccessful {
            storeRegistrationForWorkerIfNecessary(worker)
        }

        if let jobQueue = jobQueueForWorker(worker).get() {
            jobQueue.didFinishInstall(jobDataIdentifier, worker, wasSuccessful)
        }
    }

    @cxx
    @implementation
    func didFinishActivation(_ worker: WebCore.SWServerWorker) {
        logDidFinishActivation(worker)

        if let registration = worker.registration() {
            registration.didFinishActivation(worker.identifier())
        }
    }

    @cxx
    @implementation
    func storeRegistrationForWorkerIfNecessary(_ worker: WebCore.SWServerWorker) {
        logStoreRegistrationForWorker(worker)

        if !worker.shouldPersistToDisk() {
            logNotSavingWorkerBackingExtension(worker)
            return
        }

        if let store = m_registrationStore.get() {
            store.updateRegistration(worker.contextData())
        }
    }

    @cxx
    @implementation
    func didResolveRegistrationPromise(_ connection: WebCore.SWServer.Connection?, _ registrationKey: WebCore.ServiceWorkerRegistrationKey)
    {
        assert(connection.map { self.connection($0.identifier()) != nil } ?? true)

        if let jobQueue = self.jobQueue(registrationKey) {
            jobQueue.didResolveRegistrationPromise()
        }
    }

    @cxx
    @implementation
    func addClientServiceWorkerRegistration(
        _ connection: WebCore.SWServer.Connection,
        _ identifier: WebCore.ServiceWorkerRegistrationIdentifier
    ) {
        guard let registration = getRegistration(identifier) else {
            logMissingRegistrationForClientRegistration()
            return
        }

        registration.addClientServiceWorkerRegistration(connection.identifier())
    }

    @cxx
    @implementation
    func removeClientServiceWorkerRegistration(
        _ connection: WebCore.SWServer.Connection,
        _ identifier: WebCore.ServiceWorkerRegistrationIdentifier
    ) {
        if let registration = getRegistration(identifier) {
            registration.removeClientServiceWorkerRegistration(connection.identifier())
        }
    }

    @cxx
    @implementation
    func registerServiceWorkerConnection(_ connection: WebCore.SWServer.Connection, _ identifier: WebCore.ServiceWorkerIdentifier) {
        if let worker = runningOrTerminatingWorker(identifier) {
            worker.registerServiceWorkerConnection(connection.identifier())
        }
    }

    @cxx
    @implementation
    func unregisterServiceWorkerConnection(_ connection: WebCore.SWServer.Connection, _ identifier: WebCore.ServiceWorkerIdentifier) {
        if let worker = runningOrTerminatingWorker(identifier) {
            worker.unregisterServiceWorkerConnection(connection.identifier())
        }
    }

    @cxx
    @implementation
    func fireInstallEvent(_ worker: WebCore.SWServerWorker) {
        guard let contextConnection = worker.contextConnection() else {
            logMissingContextConnectionForInstallEvent()
            return
        }

        logFireInstallEvent(worker)
        contextConnection.fireInstallEvent(worker.identifier())
    }

    @cxx
    @implementation
    func addRegistration(_ registration: WebCore.RefSWServerRegistration) {
        let key = registration.get().keyValue()
        logAddingRegistration(registration)

        if getRegistration(key) == nil && !allowLoopbackIPAddress(Self.topOriginHost(key)) {
            // m_uniqueRegistrationCount is unsigned: it wraps rather than traps.
            m_uniqueRegistrationCount &+= 1
        }

        if let serviceWorkerPageIdentifier = registration.get().serviceWorkerPageIdentifier().value {
            addServiceWorkerPageIdentifierToRegistration(serviceWorkerPageIdentifier, registration.get())
        }

        m_originStore.get().add(Self.topOrigin(key))
        let registrationID = registration.get().identifierValue()
        assert(getRegistration(key) == nil)
        setScopeToRegistration(key, registration.get())
        // HashMap::add keeps an existing entry, where setValue would replace it.
        let isNewEntry = getRegistration(registrationID) == nil
        assert(isNewEntry)
        if isNewEntry {
            _ = m_registrations.setValue(registrationID, registration)
        }
    }

    @cxx
    @implementation
    func removeRegistration(_ registrationID: WebCore.ServiceWorkerRegistrationIdentifier) {
        let takenRegistration = m_registrations.take(registrationID).get()
        assert(takenRegistration != nil)
        // Callers remove only a registration the map holds.
        let registration = takenRegistration!

        if let serviceWorkerPageIdentifier = registration.serviceWorkerPageIdentifier().value {
            m_serviceWorkerPageIdentifierToRegistrationMap.remove(serviceWorkerPageIdentifier)
        }

        let key = registration.keyValue()
        if removeScopeToRegistrationIfSame(key, registration) && !Self.isTopOriginLocalHostOrLoopbackIPAddress(key) {
            // m_uniqueRegistrationCount is unsigned: it wraps rather than traps.
            m_uniqueRegistrationCount &-= 1
        }

        m_originStore.get().remove(Self.topOrigin(key))
        if let store = m_registrationStore.get() {
            store.removeRegistration(key)
        }

        backgroundFetchEngine().remove(registration)
    }

    @cxx
    @implementation
    func removeFromScopeToRegistrationMap(_ key: WebCore.ServiceWorkerRegistrationKey) {
        if getRegistration(key) != nil && !allowLoopbackIPAddress(Self.topOriginHost(key)) {
            // m_uniqueRegistrationCount is unsigned: it wraps rather than traps.
            m_uniqueRegistrationCount &-= 1
        }

        removeScopeToRegistration(key)
    }
}

// Clients, context connections, workers and connections.
extension WebCore.SWServer {
    @cxx
    @implementation
    func runServiceWorker(_ identifier: WebCore.ServiceWorkerIdentifier) -> Bool {
        guard let worker = workerByID(identifier).get() else {
            return false
        }

        return runServiceWorker(worker)
    }

    @cxx
    @implementation
    public func markAllWorkersForRegistrableDomainAsTerminated(_ registrableDomain: WebCore.RegistrableDomain) {
        var terminatedWorkers: [WebCore.SWServerWorker] = []
        for worker in runningOrTerminatingWorkerValues() where Self.workerTopRegistrableDomain(worker.get()) == registrableDomain {
            terminatedWorkers.append(worker.get())
        }
        for terminatedWorker in terminatedWorkers {
            workerContextTerminated(terminatedWorker)
        }
    }

    @cxx
    @implementation
    func workerContextTerminated(_ worker: WebCore.SWServerWorker) {
        // At this point if no registrations are referencing the worker then it will be destroyed,
        // removing itself from the m_workersByID map.
        // `taken` may hold the last reference to `worker`, so it is kept alive to the end of the body.
        guard let taken = m_runningOrTerminatingWorkers.take(worker.identifier()).get() else {
            assert(worker.isNotRunning())
            return
        }
        // `taken` is `worker`: the map is keyed by identifier, and each worker adds itself to allWorkers() under its own
        // unique identifier when it is constructed.

        withExtendedLifetime(taken) {
            worker.setState(WebCore.SWServerWorker.State.NotRunning)

            if let jobQueue = jobQueueForWorker(worker).get() {
                jobQueue.cancelJobsFromServiceWorker(worker.identifier())
            }
        }
    }

    @cxx
    @implementation
    public func addConnection(_ connection: WebCore.SWServer.RefConnection) {
        let identifier = connection.get().identifier()
        // HashMap::add keeps an existing entry, where setValue would replace it.
        let isNewEntry = self.connection(identifier) == nil
        assert(isNewEntry)
        if isNewEntry {
            _ = m_connections.setValue(identifier, connection)
        }
    }

    @cxx
    @implementation
    public func removeConnection(_ connectionIdentifier: WebCore.SWServerConnectionIdentifier) {
        assert(self.connection(connectionIdentifier) != nil)
        m_connections.remove(connectionIdentifier)

        for registration in registrationValues() {
            registration.get().unregisterServerConnection(connectionIdentifier)
        }

        for jobQueue in jobQueueValues() {
            jobQueue.get().cancelJobsFromConnection(connectionIdentifier)
        }
    }

    @cxx
    @implementation
    public func setInspectable(_ inspectable: WebCore.ServiceWorkerIsInspectable) {
        if m_isInspectable == inspectable {
            return
        }

        m_isInspectable = inspectable

        for unsafe connection in unsafe contextConnectionValues() {
            connection.get().setInspectable(inspectable)
        }
    }

    @cxx
    @implementation
    func resolveRegistrationReadyRequests(_ registration: WebCore.SWServerRegistration) {
        for connection in connectionValues() {
            connection.get().resolveRegistrationReadyRequests(registration)
        }
    }

    @cxx
    @implementation
    public func releaseServiceWorkerClientPendingMessage(
        _ contextIdentifier: WebCore.ScriptExecutionContextIdentifier
    ) -> WebCore.SWServer.ServiceWorkerClientPendingMessages {
        m_clientsToBeCreatedById.take(contextIdentifier)
    }

    @cxx
    @implementation
    public func serviceWorkerClientWithOriginByID(
        _ clientOrigin: WebCore.ClientOrigin,
        _ clientIdentifier: WebCore.ScriptExecutionContextIdentifier
    ) -> WebCore.SWServer.OptionalServiceWorkerClientData {
        guard isClientOfOrigin(clientOrigin, clientIdentifier) else {
            return WebCore.SWServer.OptionalServiceWorkerClientData()
        }

        let clientData = serviceWorkerClientDataByID(clientIdentifier)
        assert(clientData.value != nil)
        return clientData
    }

    @cxx
    @implementation
    public func topLevelServiceWorkerClientFromPageIdentifier(
        _ clientOrigin: WebCore.ClientOrigin,
        _ pageIdentifier: WebCore.PageIdentifier
    ) -> WebCore.SWServer.OptionalServiceWorkerClientData {
        for clientIdentifier in clientIdentifiersByOrigin(clientOrigin) {
            guard let clientData = serviceWorkerClientDataByID(clientIdentifier).value else {
                assertionFailure()
                continue
            }
            if clientData.frameType == .TopLevel, let clientPageIdentifier = clientData.pageIdentifier.value,
                clientPageIdentifier.isEqual(pageIdentifier)
            {
                return WebCore.SWServer.OptionalServiceWorkerClientData(clientData)
            }
        }
        return WebCore.SWServer.OptionalServiceWorkerClientData()
    }

    @cxx
    @implementation
    func updateAppInitiatedValueForWorkers(
        _ clientOrigin: WebCore.ClientOrigin,
        _ lastNavigationWasAppInitiated: WebCore.LastNavigationWasAppInitiated
    ) {
        let clientRegistrableDomain = clientOrigin.clientRegistrableDomain()
        for worker in runningOrTerminatingWorkerValues()
        where Self.workerClientRegistrableDomain(worker.get()) == clientRegistrableDomain {
            worker.get().updateAppInitiatedValue(lastNavigationWasAppInitiated)
        }
    }
}
