// Copyright (C) 2012-2026 Apple Inc. All rights reserved.
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

#if ENABLE_APP_BOUND_DOMAINS || ENABLE_MANAGED_DOMAINS

@MainActor
extension WebKit.NetworkProcess {
    #if ENABLE_APP_BOUND_DOMAINS
    func setAppBoundDomainsForResourceLoadStatistics(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        appBoundDomains: IPCTypes.HashSetInWireOrder<IPCTypes.RegistrableDomain>,
        reply: consuming NetworkProcessSetAppBoundDomainsForResourceLoadStatisticsReply
    ) {
        guard let store = resourceLoadStatisticsForSwift(PAL.SessionID(sessionID.toUInt64), false) else {
            assertionFailure()
            reply.send()
            return
        }
        let completion = reply.completionHandler()
        store.setAppBoundDomainsForSwift(
            consuming: registrableDomainVector(appBoundDomains),
            consuming: WTF.VoidCompletionHandler { completion() }
        )
    }
    #endif

    #if ENABLE_MANAGED_DOMAINS
    func setManagedDomainsForResourceLoadStatistics(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        appBoundDomains managedDomains: IPCTypes.HashSetInWireOrder<IPCTypes.RegistrableDomain>,
        reply: consuming NetworkProcessSetManagedDomainsForResourceLoadStatisticsReply
    ) {
        let completion = reply.completionHandler()
        let cxxSessionID = PAL.SessionID(sessionID.toUInt64)
        acceptAllCookiesForManagedDomainsForSwift(
            cxxSessionID,
            consuming: WTF.BoolCompletionHandler { [self] sessionIsAlive in
                guard sessionIsAlive, let store = resourceLoadStatisticsForSwift(cxxSessionID, false) else {
                    completion()
                    return
                }
                store.setManagedDomainsForSwift(
                    consuming: registrableDomainVector(managedDomains),
                    consuming: WTF.VoidCompletionHandler { completion() }
                )
            }
        )
    }
    #endif
}

/// The C++ vector of `domains`, in the order they came in the message.
private func registrableDomainVector(
    _ domains: IPCTypes.HashSetInWireOrder<IPCTypes.RegistrableDomain>
) -> WebKit.RegistrableDomainVector {
    var vector = WebKit.RegistrableDomainVector()
    for domain in domains.elementsInWireOrder {
        vector.append(consuming: .fromIPC(domain))
    }
    return vector
}

#endif // ENABLE_APP_BOUND_DOMAINS || ENABLE_MANAGED_DOMAINS
