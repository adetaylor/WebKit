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

extension WebKit.ServiceWorkerSoftUpdateLoader {
    // didReceiveResponse's body: the C++ override keeps the move-only completion handler and calls it with the result
    // after this returns, so after fail() and the cache load.
    @cxx
    @implementation
    func policyForResponse(_ response: WebCore.ResourceResponse) -> WebCore.PolicyAction {
        // The load asks for the certificate info (needsCertificateInfo).
        m_certificateInfo = Self.certificateInfo(response)
        if response.httpStatusCode() == WebCore.httpStatus304NotModified && loadWithCacheEntryIfAny() {
            return .Ignore
        }
        let error = processResponse(response)
        if !error.isNull() {
            fail(consuming: error)
            return .Ignore
        }
        return .Use
    }

    // https://w3c.github.io/ServiceWorker/#update-algorithm, steps 9.7 to 9.17
    @cxx
    @implementation
    func processResponse(_ response: WebCore.ResourceResponse) -> WebCore.ResourceError {
        let source: WebCore.WorkerScriptLoader.Source = m_jobData.workerType == .Module ? .ModuleScript : .ClassicWorkerScript
        let workerError = WebCore.WorkerScriptLoader.validateWorkerResponse(response, source, .Serviceworker)
        if !workerError.isNull() {
            return workerError
        }

        let serviceWorkerError = validateServiceWorkerResponse(response)
        if !serviceWorkerError.isNull() {
            return serviceWorkerError
        }

        m_contentSecurityPolicy = WebCore.ContentSecurityPolicyResponseHeaders(response)
        m_crossOriginEmbedderPolicy = Self.crossOriginEmbedderPolicy(response)
        m_referrerPolicy = response.httpHeaderField(.ReferrerPolicy)
        m_responseEncoding = Self.textEncodingName(response)

        return WebCore.ResourceError()
    }
}
