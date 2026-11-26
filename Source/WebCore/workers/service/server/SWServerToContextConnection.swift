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
internal import WebCore_Private.Core.SWServer
internal import WebCore_Private.Core.SWServerToContextConnection
internal import WebCore_Private.Core.SWServerWorker
internal import WebCore_Private.Core.ServiceWorkerContextData
internal import WebCore_Private.Core.ServiceWorkerJobDataIdentifier
internal import WebCore_Private.Core.ServiceWorkerTypes

extension WebCore.SWServerToContextConnection {
    @cxx
    @implementation
    public func scriptContextFailedToStart(
        _ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier,
        _ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier,
        _ message: WTF.String
    ) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?
            .scriptContextFailedToStart(jobDataIdentifier, message)
    }

    @cxx
    @implementation
    public func scriptContextStarted(
        _ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier,
        _ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier,
        _ doesHandleFetch: Bool
    ) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?
            .scriptContextStarted(jobDataIdentifier, doesHandleFetch)
    }

    @cxx
    @implementation
    public func didFinishInstall(
        _ jobDataIdentifier: WebCore.OptionalServiceWorkerJobDataIdentifier,
        _ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier,
        _ wasSuccessful: Bool
    ) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?
            .didFinishInstall(jobDataIdentifier, wasSuccessful)
    }

    @cxx
    @implementation
    public func didFinishActivation(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?.didFinishActivation()
    }

    @cxx
    @implementation
    public func setServiceWorkerHasPendingEvents(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier, _ hasPendingEvents: Bool) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?.setHasPendingEvents(hasPendingEvents)
    }

    @cxx
    @implementation
    public func workerTerminated(_ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?.contextTerminated()
    }

    @cxx
    @implementation
    public func setScriptResource(
        _ serviceWorkerIdentifier: WebCore.ServiceWorkerIdentifier,
        _ scriptURL: WTF.URL,
        _ script: WebCore.SWServerToContextConnection.ImportedScriptArgument
    ) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(serviceWorkerIdentifier)?.setScriptResource(consuming: scriptURL, consuming: script.take())
    }

    @cxx
    @implementation
    public func didFailHeartBeatCheck(_ identifier: WebCore.ServiceWorkerIdentifier) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(identifier)?.didFailHeartBeatCheck()
    }

    @cxx
    @implementation
    public func setAsInspected(_ identifier: WebCore.ServiceWorkerIdentifier, _ isInspected: Bool) {
        WebCore.SWServerWorker.existingWorkerForIdentifier(identifier)?.setAsInspected(isInspected)
    }
}
