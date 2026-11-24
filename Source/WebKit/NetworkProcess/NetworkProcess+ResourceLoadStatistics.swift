// Copyright (C) 2012-2026 Apple Inc. All rights reserved.
// Copyright (C) 2018 Sony Interactive Entertainment Inc.
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

extension PAL.SessionID {
    fileprivate init(_ sessionID: IPCTypes.SessionID) {
        self.init(sessionID.toUInt64)
    }
}

@MainActor
extension WebKit.NetworkProcess {
    private func resourceLoadStatistics(for sessionID: IPCTypes.SessionID) -> WebKit.WebResourceLoadStatisticsStore? {
        resourceLoadStatisticsForSwift(PAL.SessionID(sessionID), true)
    }

    // For a handler that does not assert on a missing session.
    private func resourceLoadStatisticsIfSession(for sessionID: IPCTypes.SessionID) -> WebKit.WebResourceLoadStatisticsStore? {
        resourceLoadStatisticsForSwift(PAL.SessionID(sessionID), false)
    }

    func isPrevalentResource(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        targetDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsPrevalentResourceReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isPrevalentResource(targetDomain, then: reply.completionHandler())
    }

    func setCrossSiteLoadWithLinkDecorationForTesting(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        fromDomain: IPCTypes.RegistrableDomain,
        toDomain: IPCTypes.RegistrableDomain,
        didFilterKnownLinkDecoration: IPCTypes.DidFilterKnownLinkDecoration,
        reply: consuming NetworkProcessSetCrossSiteLoadWithLinkDecorationForTestingReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.logCrossSiteLoadWithLinkDecoration(fromDomain, toDomain, didFilterKnownLinkDecoration, then: reply.completionHandler())
    }

    func setStorageAccessPermissionForTesting(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        granted: Bool,
        webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        topFrameDomain: IPCTypes.RegistrableDomain,
        subFrameDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetStorageAccessPermissionForTestingReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setStorageAccessPermissionForTesting(granted, webPageProxyID, topFrameDomain, subFrameDomain, then: reply.completionHandler())
    }

    func clearPrevalentResource(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessClearPrevalentResourceReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.clearPrevalentResource(resourceDomain, then: reply.completionHandler())
    }

    func clearUserInteraction(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessClearUserInteractionReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.clearUserInteraction(resourceDomain, then: reply.completionHandler())
    }

    func isGrandfathered(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        targetDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsGrandfatheredReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isGrandfathered(targetDomain, then: reply.completionHandler())
    }

    func isVeryPrevalentResource(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        targetDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsVeryPrevalentResourceReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isVeryPrevalentResource(targetDomain, then: reply.completionHandler())
    }

    func setLastSeen(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        seconds: Double,
        reply: consuming NetworkProcessSetLastSeenReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setLastSeen(resourceDomain, seconds, then: reply.completionHandler())
    }

    func setPrevalentResource(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetPrevalentResourceReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setPrevalentResource(resourceDomain, then: reply.completionHandler())
    }

    func hadUserInteraction(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessHadUserInteractionReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.hasHadUserInteraction(resourceDomain, then: reply.completionHandler())
    }

    func isRelationshipOnlyInDatabaseOnce(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subDomain: IPCTypes.RegistrableDomain,
        topDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsRelationshipOnlyInDatabaseOnceReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isRelationshipOnlyInDatabaseOnce(subDomain, topDomain, then: reply.completionHandler())
    }

    func isRegisteredAsRedirectingTo(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        redirectedFromDomain: IPCTypes.RegistrableDomain,
        redirectedToDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsRegisteredAsRedirectingToReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isRegisteredAsRedirectingTo(redirectedFromDomain, redirectedToDomain, then: reply.completionHandler())
    }

    func isRegisteredAsSubFrameUnder(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subFrameDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsRegisteredAsSubFrameUnderReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isRegisteredAsSubFrameUnder(subFrameDomain, topFrameDomain, then: reply.completionHandler())
    }

    func isRegisteredAsSubresourceUnder(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subresourceDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessIsRegisteredAsSubresourceUnderReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.isRegisteredAsSubresourceUnder(subresourceDomain, topFrameDomain, then: reply.completionHandler())
    }

    func domainIDExistsInDatabase(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        domainID: Int32,
        reply: consuming NetworkProcessDomainIDExistsInDatabaseReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.domainIDExistsInDatabase(domainID, then: reply.completionHandler())
    }

    func logFrameNavigation(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        targetDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        sourceDomain: IPCTypes.RegistrableDomain,
        isRedirect: Bool,
        isMainFrame: Bool,
        delayAfterMainFrameDocumentLoad: Double,
        wasPotentiallyInitiatedByUser: Bool
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            return
        }
        store.logFrameNavigation(
            targetDomain,
            topFrameDomain,
            sourceDomain,
            isRedirect,
            isMainFrame,
            delayAfterMainFrameDocumentLoad,
            wasPotentiallyInitiatedByUser
        )
    }

    func logUserInteraction(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        topFrameDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessLogUserInteractionReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.logUserInteraction(topFrameDomain, then: reply.completionHandler())
    }

    func setGrandfathered(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        isGrandfathered: Bool,
        reply: consuming NetworkProcessSetGrandfatheredReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setGrandfathered(resourceDomain, isGrandfathered, then: reply.completionHandler())
    }

    func setVeryPrevalentResource(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetVeryPrevalentResourceReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setVeryPrevalentResource(resourceDomain, then: reply.completionHandler())
    }

    func setSubframeUnderTopFrameDomain(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subFrameDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetSubframeUnderTopFrameDomainReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setSubframeUnderTopFrameDomain(subFrameDomain, topFrameDomain, then: reply.completionHandler())
    }

    func setSubresourceUnderTopFrameDomain(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subresourceDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetSubresourceUnderTopFrameDomainReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setSubresourceUnderTopFrameDomain(subresourceDomain, topFrameDomain, then: reply.completionHandler())
    }

    func setSubresourceUniqueRedirectTo(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subresourceDomain: IPCTypes.RegistrableDomain,
        redirectedToDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetSubresourceUniqueRedirectToReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setSubresourceUniqueRedirectTo(subresourceDomain, redirectedToDomain, then: reply.completionHandler())
    }

    func setSubresourceUniqueRedirectFrom(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        subresourceDomain: IPCTypes.RegistrableDomain,
        redirectedFromDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetSubresourceUniqueRedirectFromReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setSubresourceUniqueRedirectFrom(subresourceDomain, redirectedFromDomain, then: reply.completionHandler())
    }

    func setTopFrameUniqueRedirectTo(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        topFrameDomain: IPCTypes.RegistrableDomain,
        redirectedToDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetTopFrameUniqueRedirectToReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setTopFrameUniqueRedirectTo(topFrameDomain, redirectedToDomain, then: reply.completionHandler())
    }

    func setTopFrameUniqueRedirectFrom(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        topFrameDomain: IPCTypes.RegistrableDomain,
        redirectedFromDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetTopFrameUniqueRedirectFromReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setTopFrameUniqueRedirectFrom(topFrameDomain, redirectedFromDomain, then: reply.completionHandler())
    }

    func scheduleCookieBlockingUpdate(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        reply: consuming NetworkProcessScheduleCookieBlockingUpdateReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.scheduleCookieBlockingUpdate(then: reply.completionHandler())
    }

    func scheduleClearInMemoryAndPersistent(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        modifiedSince: Double?,
        shouldGrandfather: IPCTypes.ShouldGrandfatherStatistics,
        reply: consuming NetworkProcessScheduleClearInMemoryAndPersistentReply
    ) {
        clearIsolatedSessionsForSwift(PAL.SessionID(sessionID))
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.scheduleClearInMemoryAndPersistent(modifiedSince, shouldGrandfather, then: reply.completionHandler())
    }

    func scheduleStatisticsAndDataRecordsProcessing(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        reply: consuming NetworkProcessScheduleStatisticsAndDataRecordsProcessingReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.scheduleStatisticsAndDataRecordsProcessing(then: reply.completionHandler())
    }

    func getResourceLoadStatisticsDataSummary(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        reply: consuming NetworkProcessGetResourceLoadStatisticsDataSummaryReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send([])
            return
        }
        store.aggregatedThirdPartyData(then: reply.completionHandler())
    }

    func setFirstPartyWebsiteDataRemovalModeForTesting(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        mode: IPCTypes.FirstPartyWebsiteDataRemovalMode,
        reply: consuming NetworkProcessSetFirstPartyWebsiteDataRemovalModeForTestingReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setFirstPartyWebsiteDataRemovalMode(mode, then: reply.completionHandler())
    }

    func dumpResourceLoadStatistics(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        reply: consuming NetworkProcessDumpResourceLoadStatisticsReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(nil)
            return
        }
        store.dumpResourceLoadStatistics(then: reply.completionHandler())
    }

    func resetParametersToDefaultValues(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        reply: consuming NetworkProcessResetParametersToDefaultValuesReply
    ) {
        resetFirstPartyDNSDataForSwift(PAL.SessionID(sessionID))
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.resetParametersToDefaultValues(then: reply.completionHandler())
    }

    func statisticsDatabaseHasAllTables(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        reply: consuming NetworkProcessStatisticsDatabaseHasAllTablesReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send(false)
            return
        }
        store.statisticsDatabaseHasAllTables(then: reply.completionHandler())
    }

    func setResourceLoadStatisticsTimeAdvanceForTesting(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        time: Double,
        reply: consuming NetworkProcessSetResourceLoadStatisticsTimeAdvanceForTestingReply
    ) {
        guard let store = resourceLoadStatisticsIfSession(for: sessionID) else {
            reply.send()
            return
        }
        store.setTimeAdvanceForTesting(time, then: reply.completionHandler())
    }

    func setIsRunningResourceLoadStatisticsTest(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        value: Bool,
        reply: consuming NetworkProcessSetIsRunningResourceLoadStatisticsTestReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setIsRunningTest(value, then: reply.completionHandler())
    }

    func mergeStatisticForTesting(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        topFrameDomain1: IPCTypes.RegistrableDomain,
        topFrameDomain2: IPCTypes.RegistrableDomain,
        lastSeen: Double,
        hadUserInteraction: Bool,
        mostRecentUserInteraction: Double,
        isGrandfathered: Bool,
        isPrevalent: Bool,
        isVeryPrevalent: Bool,
        dataRecordsRemoved: UInt64,
        reply: consuming NetworkProcessMergeStatisticForTestingReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.mergeStatisticForTesting(
            resourceDomain,
            topFrameDomain1,
            topFrameDomain2,
            lastSeen,
            hadUserInteraction,
            mostRecentUserInteraction,
            isGrandfathered,
            isPrevalent,
            isVeryPrevalent,
            dataRecordsRemoved,
            then: reply.completionHandler()
        )
    }

    func insertExpiredStatisticForTesting(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        numberOfOperatingDaysPassed: UInt64,
        hadUserInteraction: Bool,
        isScheduledForAllButCookieDataRemoval: Bool,
        isPrevalent: Bool,
        reply: consuming NetworkProcessInsertExpiredStatisticForTestingReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.insertExpiredStatisticForTesting(
            resourceDomain,
            numberOfOperatingDaysPassed,
            hadUserInteraction,
            isScheduledForAllButCookieDataRemoval,
            isPrevalent,
            then: reply.completionHandler()
        )
    }

    func setGrandfatheringTime(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        seconds: Double,
        reply: consuming NetworkProcessSetGrandfatheringTimeReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setGrandfatheringTime(seconds, then: reply.completionHandler())
    }

    func setMaxStatisticsEntries(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        maximumEntryCount: UInt64,
        reply: consuming NetworkProcessSetMaxStatisticsEntriesReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setMaxStatisticsEntries(maximumEntryCount, then: reply.completionHandler())
    }

    func setMinimumTimeBetweenDataRecordsRemoval(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        seconds: Double,
        reply: consuming NetworkProcessSetMinimumTimeBetweenDataRecordsRemovalReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setMinimumTimeBetweenDataRecordsRemoval(seconds, then: reply.completionHandler())
    }

    func setPruneEntriesDownTo(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        maximumEntryCount: UInt64,
        reply: consuming NetworkProcessSetPruneEntriesDownToReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setPruneEntriesDownTo(maximumEntryCount, then: reply.completionHandler())
    }

    func setTimeToLiveUserInteraction(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        seconds: Double,
        reply: consuming NetworkProcessSetTimeToLiveUserInteractionReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setTimeToLiveUserInteraction(seconds, then: reply.completionHandler())
    }

    func setShouldClassifyResourcesBeforeDataRecordsRemoval(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        value: Bool,
        reply: consuming NetworkProcessSetShouldClassifyResourcesBeforeDataRecordsRemovalReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setShouldClassifyResourcesBeforeDataRecordsRemoval(value, then: reply.completionHandler())
    }

    func setResourceLoadStatisticsDebugMode(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        debugMode: Bool,
        reply: consuming NetworkProcessSetResourceLoadStatisticsDebugModeReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setResourceLoadStatisticsDebugMode(debugMode, then: reply.completionHandler())
    }

    func setPrevalentResourceForDebugMode(
        connection: IPC.Connection,
        sessionID: IPCTypes.SessionID,
        resourceDomain: IPCTypes.RegistrableDomain,
        reply: consuming NetworkProcessSetPrevalentResourceForDebugModeReply
    ) {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            reply.send()
            return
        }
        store.setPrevalentResourceForDebugMode(resourceDomain, then: reply.completionHandler())
    }

    func isResourceLoadStatisticsEphemeral(connection: IPC.Connection, sessionID: IPCTypes.SessionID) -> Bool {
        guard let store = resourceLoadStatistics(for: sessionID) else {
            return false
        }
        return store.isEphemeral()
    }
}
