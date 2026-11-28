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

@MainActor
extension WebKit.NetworkConnectionToWebProcess {
    func resourceLoadStatisticsUpdated(
        connection: IPC.Connection,
        statistics: [IPCTypes.ResourceLoadStatistics],
        reply: consuming NetworkConnectionToWebProcessResourceLoadStatisticsUpdatedReply
    ) throws(InvalidMessage) {
        do {
            try messageCheck { statistics.allSatisfy(\.containsOnlyObservableFields) }
        } catch {
            reply.send()
            throw error
        }
        guard !sessionID().isEphemeral(), let store = resourceLoadStatisticsForSwift() else {
            reply.send()
            return
        }
        store.resourceLoadStatisticsUpdated(statistics, completion: reply.completionHandler())
    }
}

extension IPCTypes.ResourceLoadStatistics {
    /// Whether the web process set only the fields it observes: its ResourceLoadObserver never sets these, which only the
    /// network process's grant and classification paths write.
    fileprivate var containsOnlyObservableFields: Bool {
        storageAccessUnderTopFrameDomains.isEmpty
            && !grandfathered
            && !isPrevalentResource
            && !isVeryPrevalentResource
            && dataRecordsRemoved == 0
            && timesAccessedAsFirstPartyDueToUserInteraction == 0
            && timesAccessedAsFirstPartyDueToStorageAccessAPI == 0
    }
}
