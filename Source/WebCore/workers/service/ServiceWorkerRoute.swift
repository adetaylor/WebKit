// Copyright (C) 2025 Apple Inc. All rights reserved.
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

internal import WebCore_Private.Core.FetchOptions
internal import WebCore_Private.Core.ServiceWorkerRoute

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

extension WebCore.ServiceWorkerRouteCondition {
    // https://w3c.github.io/ServiceWorker/#match-router-condition
    func matches(
        _ mode: WebCore.FetchOptionsMode,
        _ destination: WebCore.FetchOptionsDestination,
        _ url: borrowing WTF.URL,
        _ httpMethod: WTF.String,
        isServiceWorkerRunning: Bool
    ) -> Bool {
        if !orConditions.isEmpty() {
            for condition in orConditions
            where condition.matches(mode, destination, url, httpMethod, isServiceWorkerRunning: isServiceWorkerRunning) {
                return true
            }
            return false
        }

        if hasNotCondition() {
            return !self[.Condition].matches(mode, destination, url, httpMethod, isServiceWorkerRunning: isServiceWorkerRunning)
        }

        if !urlPatternMatches(url) {
            return false
        }

        if !requestMethod.isNull() && !(requestMethod == httpMethod) {
            return false
        }

        if let requestMode = requestMode.value, requestMode != mode {
            return false
        }

        if let requestDestination = requestDestination.value, requestDestination != destination {
            return false
        }

        if let runningStatus = runningStatus.value, (runningStatus == .Running) != isServiceWorkerRunning {
            return false
        }

        return true
    }
}
