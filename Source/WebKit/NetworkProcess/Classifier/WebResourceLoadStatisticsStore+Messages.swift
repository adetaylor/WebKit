// Copyright (C) 2016-2025 Apple Inc. All rights reserved.
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

extension WebCore.FirstPartyWebsiteDataRemovalMode {
    fileprivate init(_ mode: IPCTypes.FirstPartyWebsiteDataRemovalMode) {
        switch mode {
        case .allButCookies: self = .AllButCookies
        case .none: self = .None
        case .allButCookiesLiveOnTestingTimeout: self = .AllButCookiesLiveOnTestingTimeout
        case .allButCookiesReproTestingTimeout: self = .AllButCookiesReproTestingTimeout
        }
    }
}

/// The answer of a handler that asserts the session has a store: Debug stops, Release answers `value`.
private func unreachableWithoutStore<Value>(_ value: Value) -> Value {
    assertionFailure()
    return value
}

// The store's side of the statistics messages. It reaches the session's store only through the statistics actor's
// requests, by onStatisticsActor (WebResourceLoadStatisticsStore.swift).
@MainActor
extension WebKit.WebResourceLoadStatisticsStore {
    func isPrevalentResource(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping (Bool) -> Void) {
        if isEphemeral() {
            completion(false)
            return
        }
        onStatisticsActor(.isPrevalentResource(domain), ifNoStore: false, then: completion)
    }

    // Async: a synchronous answer measured slower in ResourceLoadStatisticsBench's WebProcessMessages.
    func isLoggedIn(_ domain: IPCTypes.RegistrableDomain) async -> Bool {
        isLoggedIn(.fromIPC(domain))
    }

    func logCrossSiteLoadWithLinkDecoration(
        _ fromDomain: IPCTypes.RegistrableDomain,
        _ toDomain: IPCTypes.RegistrableDomain,
        _ didFilterKnownLinkDecoration: IPCTypes.DidFilterKnownLinkDecoration,
        then completion: @escaping () -> Void
    ) {
        let fromDomain = WebCore.RegistrableDomain.fromIPC(fromDomain)
        let toDomain = WebCore.RegistrableDomain.fromIPC(toDomain)
        // WebCore.RegistrableDomain imports operator== only.
        assert(!(fromDomain == toDomain))
        let command = StatisticsCommandRequest.logCrossSiteLoadWithLinkDecoration(
            from: StatisticsDomain(fromDomain),
            to: StatisticsDomain(toDomain),
            didFilterKnownLinkDecoration: didFilterKnownLinkDecoration == .yes
        )
        onStatisticsActor(command, then: completion)
    }

    func logFrameNavigation(
        _ targetDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ sourceDomain: IPCTypes.RegistrableDomain,
        _ isRedirect: Bool,
        _ isMainFrame: Bool,
        _ delayAfterMainFrameDocumentLoad: Double,
        _ wasPotentiallyInitiatedByUser: Bool
    ) {
        onStatisticsActor(
            .logFrameNavigation(
                target: targetDomain,
                topFrame: topFrameDomain,
                source: sourceDomain,
                isRedirect: isRedirect,
                isMainFrame: isMainFrame,
                delayAfterMainFrameDocumentLoad: delayAfterMainFrameDocumentLoad,
                wasPotentiallyInitiatedByUser: wasPotentiallyInitiatedByUser
            )
        )
    }

    func logUserInteraction(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping () -> Void) {
        // User interactions need to be logged for ephemeral sessions to support the Storage Access API.
        if isEphemeral() {
            logUserInteractionEphemeral(.fromIPC(domain))
            completion()
            return
        }
        onStatisticsActor(.logUserInteraction(domain), then: completion)
    }

    func clearUserInteraction(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping () -> Void) {
        if isEphemeral() {
            clearUserInteractionEphemeral(.fromIPC(domain))
            completion()
            return
        }
        onStatisticsActor(.clearUserInteraction(domain), then: completion)
    }

    func hasHadUserInteraction(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping (Bool) -> Void) {
        if isEphemeral() {
            completion(hasEphemeralUserInteraction(.fromIPC(domain)))
            return
        }
        onStatisticsActor(.hasHadUserInteraction(domain), ifNoStore: false, then: completion)
    }

    func setLastSeen(_ domain: IPCTypes.RegistrableDomain, _ seconds: Double, then completion: @escaping () -> Void) {
        onStatisticsActor(.setLastSeen(domain, seconds: seconds), then: completion)
    }

    func isRelationshipOnlyInDatabaseOnce(
        _ subDomain: IPCTypes.RegistrableDomain,
        _ topDomain: IPCTypes.RegistrableDomain,
        then completion: @escaping (Bool) -> Void
    ) {
        onStatisticsActor(.isRelationshipOnlyInDatabaseOnce(sub: subDomain, top: topDomain), ifNoStore: false, then: completion)
    }

    func setPrevalentResource(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping () -> Void) {
        onStatisticsActor(.setPrevalentResource(domain), then: completion)
    }

    func setVeryPrevalentResource(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping () -> Void) {
        onStatisticsActor(.setVeryPrevalentResource(domain), then: completion)
    }

    func isVeryPrevalentResource(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping (Bool) -> Void) {
        onStatisticsActor(.isVeryPrevalentResource(domain), ifNoStore: false, then: completion)
    }

    func isRegisteredAsSubresourceUnder(
        _ subresourceDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        then completion: @escaping (Bool) -> Void
    ) {
        onStatisticsActor(
            .isRegisteredAsSubresourceUnder(subresourceDomain, topFrame: topFrameDomain),
            ifNoStore: false,
            then: completion
        )
    }

    func isRegisteredAsSubFrameUnder(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        then completion: @escaping (Bool) -> Void
    ) {
        onStatisticsActor(.isRegisteredAsSubFrameUnder(subFrameDomain, topFrame: topFrameDomain), ifNoStore: false, then: completion)
    }

    func isRegisteredAsRedirectingTo(
        _ domainRedirectedFrom: IPCTypes.RegistrableDomain,
        _ domainRedirectedTo: IPCTypes.RegistrableDomain,
        then completion: @escaping (Bool) -> Void
    ) {
        onStatisticsActor(
            .isRegisteredAsRedirectingTo(from: domainRedirectedFrom, to: domainRedirectedTo),
            ifNoStore: false,
            then: completion
        )
    }

    func clearPrevalentResource(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping () -> Void) {
        onStatisticsActor(.clearPrevalentResource(domain), then: completion)
    }

    func setGrandfathered(_ domain: IPCTypes.RegistrableDomain, _ value: Bool, then completion: @escaping () -> Void) {
        onStatisticsActor(.setGrandfathered(domain, value), then: completion)
    }

    func isGrandfathered(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping (Bool) -> Void) {
        onStatisticsActor(.isGrandfathered(domain), ifNoStore: false, then: completion)
    }

    func setSubframeUnderTopFrameDomain(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(.setSubframeUnderTopFrameDomain(subFrameDomain, topFrame: topFrameDomain), then: completion)
    }

    func setSubresourceUnderTopFrameDomain(
        _ subresourceDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(.setSubresourceUnderTopFrameDomain(subresourceDomain, topFrame: topFrameDomain), then: completion)
    }

    func setSubresourceUniqueRedirectTo(
        _ subresourceDomain: IPCTypes.RegistrableDomain,
        _ domainRedirectedTo: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(.setSubresourceUniqueRedirectTo(subresourceDomain, to: domainRedirectedTo), then: completion)
    }

    func setSubresourceUniqueRedirectFrom(
        _ subresourceDomain: IPCTypes.RegistrableDomain,
        _ domainRedirectedFrom: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(.setSubresourceUniqueRedirectFrom(subresourceDomain, from: domainRedirectedFrom), then: completion)
    }

    func setTopFrameUniqueRedirectTo(
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ domainRedirectedTo: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(.setTopFrameUniqueRedirectTo(topFrameDomain, to: domainRedirectedTo), then: completion)
    }

    func setTopFrameUniqueRedirectFrom(
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ domainRedirectedFrom: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(.setTopFrameUniqueRedirectFrom(topFrameDomain, from: domainRedirectedFrom), then: completion)
    }

    func domainIDExistsInDatabase(_ domainID: Int32, then completion: @escaping (Bool) -> Void) {
        onStatisticsActor(.domainIDExistsInDatabase(domainID), ifNoStore: false, then: completion)
    }

    // Helper function used by testing system.
    func scheduleCookieBlockingUpdate(then completion: @escaping () -> Void) {
        onStatisticsActor(.updateCookieBlocking, then: completion)
    }

    func scheduleClearInMemoryAndPersistent(
        _ modifiedSince: Double?,
        _ shouldGrandfather: IPCTypes.ShouldGrandfatherStatistics,
        then completion: @escaping () -> Void
    ) {
        // As the C++, everything is cleared whatever `modifiedSince` is.
        if isEphemeral() {
            clearInMemoryEphemeral()
            completion()
            return
        }
        onStatisticsActor(.clearInMemoryAndPersistent(shouldGrandfather: shouldGrandfather == .yes), then: completion)
    }

    func scheduleStatisticsAndDataRecordsProcessing(then completion: @escaping () -> Void) {
        onStatisticsActor(.processStatisticsAndDataRecords, then: completion)
    }

    func aggregatedThirdPartyData(then completion: @escaping ([IPCTypes.ITPThirdPartyData]) -> Void) {
        onStatisticsActor(.aggregatedThirdPartyData, ifNoStore: [], then: completion)
    }

    func setFirstPartyWebsiteDataRemovalMode(
        _ mode: IPCTypes.FirstPartyWebsiteDataRemovalMode,
        then completion: @escaping () -> Void
    ) {
        if isEphemeral() {
            completion()
            return
        }
        onStatisticsActor(.setFirstPartyWebsiteDataRemovalMode(WebCore.FirstPartyWebsiteDataRemovalMode(mode)), then: completion)
    }

    func dumpResourceLoadStatistics(then completion: @escaping (Swift.String?) -> Void) {
        onStatisticsActorDumpResourceLoadStatistics(ifNoStore: "", then: completion)
    }

    func resetParametersToDefaultValues(then completion: @escaping () -> Void) {
        if isEphemeral() {
            completion()
            return
        }
        resetStorageSessionDomainsToDefaultValues()
        onStatisticsActor(.resetParametersToDefaultValues, then: completion)
    }

    func statisticsDatabaseHasAllTables(then completion: @escaping (Bool) -> Void) {
        onStatisticsActor(.databaseHasAllTables, ifNoStore: unreachableWithoutStore(false), then: completion)
    }

    func setTimeAdvanceForTesting(_ time: Double, then completion: @escaping () -> Void) {
        onStatisticsActor(.setTimeAdvanceForTesting(time), then: completion)
    }

    func setIsRunningTest(_ value: Bool, then completion: @escaping () -> Void) {
        if isEphemeral() {
            completion()
            return
        }
        onStatisticsActor(.setIsRunningTest(value), then: completion)
    }

    func mergeStatisticForTesting(
        _ domain: IPCTypes.RegistrableDomain,
        _ topFrameDomain1: IPCTypes.RegistrableDomain,
        _ topFrameDomain2: IPCTypes.RegistrableDomain,
        _ lastSeen: Double,
        _ hadUserInteraction: Bool,
        _ mostRecentUserInteraction: Double,
        _ isGrandfathered: Bool,
        _ isPrevalent: Bool,
        _ isVeryPrevalent: Bool,
        _ dataRecordsRemoved: UInt64,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(
            .mergeStatisticForTesting(
                domain,
                topFrame1: topFrameDomain1,
                topFrame2: topFrameDomain2,
                lastSeen: lastSeen,
                hadUserInteraction: hadUserInteraction,
                mostRecentUserInteraction: mostRecentUserInteraction,
                isGrandfathered: isGrandfathered,
                isPrevalent: isPrevalent,
                isVeryPrevalent: isVeryPrevalent,
                dataRecordsRemoved: dataRecordsRemoved
            ),
            then: completion
        )
    }

    func insertExpiredStatisticForTesting(
        _ domain: IPCTypes.RegistrableDomain,
        _ numberOfOperatingDaysPassed: UInt64,
        _ hadUserInteraction: Bool,
        _ isScheduledForAllButCookieDataRemoval: Bool,
        _ isPrevalent: Bool,
        then completion: @escaping () -> Void
    ) {
        onStatisticsActor(
            .insertExpiredStatisticForTesting(
                domain,
                numberOfOperatingDaysPassed: numberOfOperatingDaysPassed,
                hadUserInteraction: hadUserInteraction,
                isScheduledForAllButCookieDataRemoval: isScheduledForAllButCookieDataRemoval,
                isPrevalent: isPrevalent
            ),
            then: completion
        )
    }

    func setGrandfatheringTime(_ seconds: Double, then completion: @escaping () -> Void) {
        onStatisticsActor(.setGrandfatheringTime(seconds), then: completion)
    }

    func setMaxStatisticsEntries(_ maximumEntryCount: UInt64, then completion: @escaping () -> Void) {
        onStatisticsActor(.setMaxStatisticsEntries(maximumEntryCount), then: completion)
    }

    func setMinimumTimeBetweenDataRecordsRemoval(_ seconds: Double, then completion: @escaping () -> Void) {
        onStatisticsActor(.setMinimumTimeBetweenDataRecordsRemoval(seconds), then: completion)
    }

    func setPruneEntriesDownTo(_ pruneTargetCount: UInt64, then completion: @escaping () -> Void) {
        onStatisticsActor(.setPruneEntriesDownTo(pruneTargetCount), then: completion)
    }

    func setTimeToLiveUserInteraction(_ seconds: Double, then completion: @escaping () -> Void) {
        onStatisticsActor(.setTimeToLiveUserInteraction(seconds), then: completion)
    }

    func setShouldClassifyResourcesBeforeDataRecordsRemoval(_ value: Bool, then completion: @escaping () -> Void) {
        onStatisticsActor(.setShouldClassifyResourcesBeforeDataRecordsRemoval(value), then: completion)
    }

    func setResourceLoadStatisticsDebugMode(_ value: Bool, then completion: @escaping () -> Void) {
        if isEphemeral() {
            completion()
            return
        }
        setTrackingPreventionDebugLoggingEnabled(value)
        onStatisticsActor(.setResourceLoadStatisticsDebugMode(value), then: completion)
    }

    func setPrevalentResourceForDebugMode(_ domain: IPCTypes.RegistrableDomain, then completion: @escaping () -> Void) {
        if isEphemeral() {
            completion()
            return
        }
        onStatisticsActor(.setPrevalentResourceForDebugMode(StatisticsDomain(.fromIPC(domain))), then: completion)
    }

    /// Merges a web process's statistics and replies; then, as the merge processes them synchronously, cancels any
    /// pending processing request, updates cookie blocking and processes the statistics and data records.
    func resourceLoadStatisticsUpdated(_ statistics: [IPCTypes.ResourceLoadStatistics], completion: @escaping () -> Void) {
        onStatisticsActor(statisticsUpdated: statistics, then: completion) { [self] in
            logTestingEvent(WTF.String("Statistics Updated"))
        }
    }
}
