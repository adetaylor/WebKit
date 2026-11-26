// Copyright (C) 2019 Apple Inc. All rights reserved.
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

extension WebKit.ServiceWorkerFetchTask {
    // The release log's prefix: "%p - [fetchIdentifier=%llu] ServiceWorkerFetchTask::".
    private var logPrefix: Swift.String {
        "\(logIdentifier().description) - [fetchIdentifier=\(m_fetchIdentifier.toUInt64())] ServiceWorkerFetchTask::"
    }

    // The Swift forms of the task's identifiers. A C++ ObjectIdentifier is never 0, so each form exists.
    private var ipcServerConnectionIdentifier: IPCTypes.ProcessIdentifier {
        // swift-format-ignore: NeverForceUnwrap
        IPCTypes.ProcessIdentifier(rawValue: m_serverConnectionIdentifier.asOptional().value!.toUInt64())!
    }

    private var ipcServiceWorkerIdentifier: IPCTypes.ServiceWorkerIdentifier {
        // swift-format-ignore: NeverForceUnwrap
        IPCTypes.ServiceWorkerIdentifier(rawValue: m_serviceWorkerIdentifier.asOptional().value!.toUInt64())!
    }

    private var ipcFetchIdentifier: IPCTypes.FetchIdentifier {
        // swift-format-ignore: NeverForceUnwrap
        IPCTypes.FetchIdentifier(rawValue: m_fetchIdentifier.toUInt64())!
    }

    // MARK: Messages

    @cxx
    @implementation
    func workerClosed() {
        if let serviceWorkerConnection = m_serviceWorkerConnection.get() {
            serviceWorkerConnection.unregisterFetch(self)
        }
        contextClosed()
    }

    @cxx
    @implementation
    func usePreload() {
        if m_isDone {
            return
        }

        assert(m_preloader.get() != nil)
        if m_preloader.get() != nil {
            loadResponseFromPreloader()
            return
        }

        m_isDone = true
        stopTimeoutTimer()
        // swift-format-ignore: NeverForceUnwrap
        // A fetch task does not outlive its loader.
        loader()!.serviceWorkerDidNotHandle(self)
    }

    // MARK: Fetch

    @cxx
    @implementation
    func start(_ serviceWorkerConnection: WebKit.WebSWServerToContextConnection) {
        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)start:")
        if m_isDone {
            return
        }

        setServiceWorkerConnection(serviceWorkerConnection)
        serviceWorkerConnection.registerFetch(self)

        startFetch()
    }

    @cxx
    @implementation
    func continueFetchTaskWith(_ request: WebCore.ResourceRequest) {
        WebKit.LogChannel.ServiceWorker().releaseLog.log(
            "\(self.logPrefix, privacy: .public)continueFetchTaskWith: (hasServiceWorkerConnection=\(self.m_serviceWorkerConnection.get() != nil ? 1 : 0))"
        )
        // swift-format-ignore: NeverForceUnwrap
        let loader = loader()!
        if m_serviceWorkerConnection.get() == nil {
            m_isDone = true
            loader.serviceWorkerDidNotHandle(self)
            return
        }
        startTimeoutTimer()
        m_currentRequest = request
        startFetch()
    }

    @cxx
    @implementation
    func cancelFromClient() {
        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)cancelFromClient: isDone=\(self.m_isDone ? 1 : 0)")
        if m_isDone {
            return
        }

        m_isDone = true
        stopTimeoutTimer()

        if m_isLoadingFromPreloader {
            cancelPreloadIfNecessary()
            return
        }

        if let connection = serviceWorkerConnection().get() {
            WebKit.WebSWServerToContextConnection.WebSWContextManagerConnectionMessages.cancelFetch(
                on: connection,
                to: 0,
                serverConnectionIdentifier: ipcServerConnectionIdentifier,
                serviceWorkerIdentifier: ipcServiceWorkerIdentifier,
                fetchIdentifier: ipcFetchIdentifier
            )
        }
    }

    @cxx
    @implementation
    func continueDidReceiveFetchResponse() {
        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)continueDidReceiveFetchResponse:")
        if m_isLoadingFromPreloader {
            loadBodyFromPreloader()
            return
        }

        if finishLoadingWithPendingCacheResponse() {
            return
        }

        if let connection = serviceWorkerConnection().get() {
            WebKit.WebSWServerToContextConnection.WebSWContextManagerConnectionMessages.continueDidReceiveFetchResponse(
                on: connection,
                to: 0,
                serverConnectionIdentifier: ipcServerConnectionIdentifier,
                serviceWorkerIdentifier: ipcServiceWorkerIdentifier,
                fetchIdentifier: ipcFetchIdentifier
            )
        }
    }

    // MARK: Worker and context closing

    @cxx
    @implementation
    func contextClosed() {
        WebKit.LogChannel.ServiceWorker().releaseLog.log(
            "\(self.logPrefix, privacy: .public)contextClosed: (m_isDone=\(self.m_isDone ? 1 : 0), m_wasHandled=\(self.m_wasHandled ? 1 : 0))"
        )
        setServiceWorkerConnection(nil)
        if m_isDone {
            return
        }

        if m_wasHandled && !m_isLoadingFromPreloader {
            didFail(Self.contextClosedError())
            return
        }
        cannotHandle()
    }

    @cxx
    @implementation
    func didNotHandle() {
        if m_isDone {
            return
        }

        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)didNotHandle:")
        stopTimeoutTimer()
        softUpdateIfNeeded()

        if let preloader = m_preloader.get(), !preloader.isServiceWorkerNavigationPreloadEnabled() {
            loadResponseFromPreloader()
            return
        }

        m_isDone = true
        // swift-format-ignore: NeverForceUnwrap
        loader()!.serviceWorkerDidNotHandle(self)
    }

    @cxx
    @implementation
    func timeoutTimerFired() {
        assert(!m_isDone)
        assert(!m_wasHandled)
        WebKit.LogChannel.ServiceWorker().releaseLog.error(
            "\(self.logPrefix, privacy: .public)timeoutTimerFired: (hasServiceWorkerConnection=\(self.m_serviceWorkerConnection.get() != nil ? 1 : 0), hasLoader=\(self.loader() != nil ? 1 : 0))"
        )

        if loader() == nil {
            return
        }

        softUpdateIfNeeded()

        cannotHandle()

        if let swServerConnection = m_swServerConnection.get() {
            swServerConnection.fetchTaskTimedOut(m_serviceWorkerIdentifier.asOptional().value!)
        }
    }

    @cxx
    @implementation
    func softUpdateIfNeeded() {
        WebKit.LogChannel.ServiceWorker().releaseLog.log(
            "\(self.logPrefix, privacy: .public)softUpdateIfNeeded: (m_shouldSoftUpdate=\(self.m_shouldSoftUpdate ? 1 : 0))"
        )
        if !m_shouldSoftUpdate {
            return
        }
        // swift-format-ignore: NeverForceUnwrap
        let loader = loader()!
        guard let swConnection = loader.connectionToWebProcess().swConnection() else {
            return
        }
        guard let server = swConnection.server() else {
            return
        }
        if let registration = server.getRegistration(m_serviceWorkerRegistrationIdentifier.asOptional().value!) {
            registration.scheduleSoftUpdate(loader.isAppInitiated() ? .Yes : .No)
        }
    }

    // MARK: Responses

    @cxx
    @implementation
    func didReceiveRedirectResponse(_ response: WebCore.ResourceResponse) {
        cancelPreloadIfNecessary()

        if let loader = loader() {
            loader.setWorkerFinalRouterSource(.FetchEvent)
        }

        processRedirectResponse(response, .Yes)
    }

    @cxx
    @implementation
    func processRedirectResponse(_ response: WebCore.ResourceResponse, _ shouldSetSource: ShouldSetSource) {
        if m_isDone {
            return
        }

        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)processRedirectResponse:")
        m_wasHandled = true
        stopTimeoutTimer()
        softUpdateIfNeeded()

        var response = response
        if shouldSetSource == .Yes {
            response.setSource(.ServiceWorker)
        }
        // swift-format-ignore: NeverForceUnwrap
        let loader = loader()!
        let newRequest = redirectedCurrentRequest(response)
        loader.willSendServiceWorkerRedirectedRequest(consuming: m_currentRequest, consuming: newRequest, consuming: response)
    }

    @cxx
    @implementation
    func didReceiveResponse(
        _ response: WebCore.ResourceResponse,
        _ firstResponseURL: WTF.URL,
        _ needsContinueDidReceiveResponseMessage: Bool
    ) {
        if let preloader = m_preloader.get(), !preloader.isServiceWorkerNavigationPreloadEnabled() {
            cancelPreloadIfNecessary()
        }

        if let loader = loader() {
            loader.setWorkerFinalRouterSource(.FetchEvent)
        }

        processResponse(response, firstResponseURL, needsContinueDidReceiveResponseMessage, .Yes)
    }

    @cxx
    @implementation
    func processResponse(
        _ response: WebCore.ResourceResponse,
        _ firstResponseURL: WTF.URL,
        _ needsContinueDidReceiveResponseMessage: Bool,
        _ shouldSetSource: ShouldSetSource
    ) {
        if m_isDone {
            return
        }

        // swift-format-ignore: NeverForceUnwrap
        let loader = loader()!
        #if ENABLE_CONTENT_FILTERING
        if !loader.continueAfterServiceWorkerReceivedResponse(response) {
            return
        }
        #endif

        WebKit.LogChannel.ServiceWorker().releaseLog.log(
            "\(self.logPrefix, privacy: .public)processResponse: (httpStatusCode=\(response.httpStatusCode()), MIMEType=\(Self.mimeType(response).description, privacy: .public), expectedContentLength=\(response.expectedContentLength()), needsContinueDidReceiveResponseMessage=\(needsContinueDidReceiveResponseMessage ? 1 : 0), source=\(response.source().rawValue))"
        )
        m_wasHandled = true
        stopTimeoutTimer()
        softUpdateIfNeeded()

        if let error = Optional(fromCxx: crossOriginResourcePolicyError(response, firstResponseURL)) {
            didFail(error)
            return
        }

        if let error = Optional(fromCxx: loader.doCrossOriginEmbedderPolicyHandlingOfNavigationResponse(response)) {
            didFail(error)
            return
        }

        if let error = Optional(fromCxx: loader.doCrossOriginOpenerHandlingOfResponse(response)) {
            didFail(error)
            return
        }

        if loader.isMainResource() {
            if let swServerConnection = m_swServerConnection.get() {
                swServerConnection.fetchTaskReceivedMainResourceResponse(m_serviceWorkerIdentifier.asOptional(), response, loader.frameID())
            }
        }

        var response = response
        if shouldSetSource == .Yes {
            response.setSource(.ServiceWorker)
        }
        loader.sendDidReceiveResponseWithPotentialProcessSwap(response, .No, needsContinueDidReceiveResponseMessage)
        if needsContinueDidReceiveResponseMessage {
            loader.setResponse(consuming: response)
        }
    }

    // MARK: Body

    @cxx
    @implementation
    func didReceiveData(_ data: IPC.SharedBufferReference) {
        if m_isDone {
            return
        }

        guard let buffer = data.unsafeBuffer().get() else {
            return
        }

        sendData(buffer)
    }

    @cxx
    @implementation
    func didReceiveDataFromPreloader(_ data: borrowing WebCore.FragmentedSharedBuffer) {
        if m_isDone {
            return
        }

        sendData(data.makeContiguous().get())
    }

    @cxx
    @implementation
    func sendData(_ data: WebCore.SharedBuffer) {
        assert(!m_isDone)
        assert(!isTimeoutTimerActive())

        #if ENABLE_CONTENT_FILTERING
        // swift-format-ignore: NeverForceUnwrap
        if !loader()!.continueAfterServiceWorkerReceivedData(data) {
            return
        }
        #endif
        sendDidReceiveData(data)
    }

    @cxx
    @implementation
    func didFinish(_ networkLoadMetrics: WebCore.NetworkLoadMetrics) {
        assert(!isTimeoutTimerActive())
        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)didFinish: (m_isDone=\(self.m_isDone ? 1 : 0))")

        if m_isDone {
            return
        }

        m_isDone = true
        stopTimeoutTimer()

        #if ENABLE_CONTENT_FILTERING
        // swift-format-ignore: NeverForceUnwrap
        loader()!.serviceWorkerDidFinish()
        #endif

        sendDidFinishResourceLoad(networkLoadMetrics)

        cancelPreloadIfNecessary()
    }

    @cxx
    @implementation
    func didFail(_ error: WebCore.ResourceError) {
        if m_isDone {
            return
        }

        m_isDone = true
        if isTimeoutTimerActive() {
            stopTimeoutTimer()
            softUpdateIfNeeded()
        }
        cancelPreloadIfNecessary()

        WebKit.LogChannel.ServiceWorker().releaseLog.error(
            "\(self.logPrefix, privacy: .public)didFail: (error.domain=\(Self.errorDomain(error).description, privacy: .public), error.code=\(error.errorCode()))"
        )
        // swift-format-ignore: NeverForceUnwrap
        loader()!.didFailLoading(error)
    }

    // MARK: Navigation preload

    @cxx
    @implementation
    func loadResponseFromPreloader() {
        WebKit.LogChannel.ServiceWorker().releaseLog.log("\(self.logPrefix, privacy: .public)loadResponseFromPreloader")

        if m_isLoadingFromPreloader {
            return
        }

        m_isLoadingFromPreloader = true
        waitForPreloadResponse()
    }

    @cxx
    @implementation
    func preloadResponseIsReady() {
        if m_shouldRaceNetworkAndFetchHandler && !m_wasHandled {
            assert(m_preloader.get() != nil)
            // swift-format-ignore: NeverForceUnwrap
            if !preloadResponseIsSuccessful() {
                cancelPreloadIfNecessary()
                return
            }

            // Let's stop listening to fetch event handler since we will use the preload.
            if let serviceWorkerConnection = m_serviceWorkerConnection.get() {
                serviceWorkerConnection.unregisterFetch(self)
            }
            setServiceWorkerConnection(nil)

            if let loader = loader() {
                loader.setWorkerFinalRouterSource(.Network)
            }

            m_isLoadingFromPreloader = true
            processPreloadResponse()
            return
        }

        if !m_isLoadingFromPreloader {
            if let preloader = m_preloader.get(), preloader.isServiceWorkerNavigationPreloadEnabled(),
                m_serviceWorkerConnection.get() != nil
            {
                sendNavigationPreloadUpdate()
            }
            return
        }
        processPreloadResponse()
    }

    // MARK: Accessors

    @cxx
    @implementation
    func startTime() -> WTF.MonotonicTime {
        guard let preloader = m_preloader.get() else {
            return WTF.MonotonicTime()
        }
        return preloader.startTime()
    }

    @cxx
    @implementation
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        guard let loader = loader() else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }

        return loader.connectionToWebProcess().sharedPreferencesForWebProcess()
    }
}
