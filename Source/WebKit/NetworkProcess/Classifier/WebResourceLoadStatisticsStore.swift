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

// SWIFT_PRIVATE_FILEID gives this file WebResourceLoadStatisticsStore's private members, the *ForSwift entries among them.

import Synchronization
import WebKit_Internal

extension WebCore.RegistrableDomain {
    /// The C++ domain of the Swift form a message carries, as `fromRawString` decodes it in C++.
    static func fromIPC(_ domain: IPCTypes.RegistrableDomain) -> WebCore.RegistrableDomain {
        fromRawString(consuming: domain.string.map { WTF.String($0) } ?? WTF.String())
    }
}

// MARK: Reply boxes (main)

/// The reply of a statistics request, which waits on the main actor while the request runs.
///
/// Only the reference crosses to the actor and back: what it holds is made, called and destroyed on the main actor.
@MainActor
final class StatisticsReply<Result: Sendable> {
    private var completion: ((Result) -> Void)?
    private let ifNoStore: () -> Result

    /// A box dropped unreplied calls nothing, as a C++ reply handler destroyed uncalled.
    init(ifNoStore: @escaping () -> Result, _ completion: @escaping (Result) -> Void) {
        self.ifNoStore = ifNoStore
        self.completion = completion
    }

    /// Calls the completion once, with the request's result, or with `ifNoStore` if there was no store.
    func complete(_ result: Result?) {
        completion.take()?(result ?? ifNoStore())
    }

    // The last release can be in the actor; the completion, and the reply it may hold, are released on the main actor.
    isolated deinit {}
}

extension StatisticsReply where Result == Void {
    /// The suspension completions, completed together as `invokeAllSuspensionCompletionHandlers` does.
    static func completeAll(_ boxes: [StatisticsReply<Void>]) {
        for box in boxes {
            box.complete(())
        }
    }
}

// MARK: Requests

/// What enters the statistics actor: Swift values, enums and main-isolated boxes only, never a C++ value.
enum StatisticsRequest: Sendable {
    case create(sessionID: UInt64, directory: Swift.String, includeLocalhost: Bool, mainSide: StatisticsMainSide)
    case destroy(sessionID: UInt64, reply: StatisticsReply<Void>)
    case suspendIfNeeded
    // Round trips' second parts, and a main part's handler destroyed uncalled.
    case mainPartDone(id: UInt64, generation: UInt64)
    case boolAnswered(id: UInt64, generation: UInt64, answer: Bool)
    case domainsAnswered(id: UInt64, generation: UInt64, domains: [StatisticsDomain])
    case storageAccessGranted(id: UInt64, generation: UInt64, wasGranted: IPCTypes.StorageAccessWasGranted)
    case quirkGrantsAnswered(
        id: UInt64,
        generation: UInt64,
        pairs: [StatisticsDomainPair]?,
        canRequestWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction
    )
    case part2Dropped(id: UInt64, generation: UInt64)
    case processStatistics(sessionID: UInt64, generation: UInt64, requestID: UInt64)
    case query(sessionID: UInt64, StatisticsQueryRequest, reply: StatisticsReply<Bool>)
    case command(sessionID: UInt64, StatisticsCommandRequest, reply: StatisticsReply<Void>?)
    case deferredCommand(sessionID: UInt64, StatisticsDeferredCommandRequest, reply: StatisticsReply<Void>)
    case dumpStatistics(sessionID: UInt64, reply: StatisticsReply<Swift.String?>)
    case thirdPartyData(sessionID: UInt64, StatisticsThirdPartyDataRequest, reply: StatisticsReply<[IPCTypes.ITPThirdPartyData]>)
    // `reply` follows the merge; `updated` follows the cookie-blocking update after it, and is dropped with no store.
    case statisticsUpdated(
        sessionID: UInt64,
        [IPCTypes.ResourceLoadStatistics],
        reply: StatisticsReply<Void>,
        updated: StatisticsReply<Void>
    )
    case storageAccess(sessionID: UInt64, StatisticsStorageAccessRequest)
    case domainList(sessionID: UInt64, StatisticsDomainListRequest, reply: StatisticsReply<StatisticsDomainList>)
    // `reply` follows the store's work, which itself waits on main.
    case completing(sessionID: UInt64, StatisticsCompletingRequest, reply: StatisticsReply<Void>)
}

/// A C++ caller's request for a list of the store's domains, run by `ResourceLoadStatisticsStore.answer(_:on:)`.
enum StatisticsDomainListRequest: UInt8, Sendable {
    case allDomains = 0
    case allDomainsWithLastAccessedTime = 1
    case domainsExemptFromWebsiteDataDeletion = 2
    case websitesWithUserInteraction = 3
}

/// A domain-list answer: `times`, in raw seconds, is empty or parallel to `domains`; `hasValue` is false for the C++'s
/// std::nullopt.
struct StatisticsDomainList: Sendable {
    var hasValue: Bool
    var domains: [StatisticsDomain]
    var times: [Double]
}

/// A C++ caller's or a message's request whose store work completes later, run by `ResourceLoadStatisticsStore.run(_:on:then:)`.
enum StatisticsCompletingRequest: Sendable {
    case populateMemoryStoreFromDisk
    case clearInMemoryAndPersistent(shouldGrandfather: Bool)
}

/// A message the store answers with its third-party data, run by `ResourceLoadStatisticsStore.answer(_:on:)`.
enum StatisticsThirdPartyDataRequest: Sendable {
    case aggregatedThirdPartyData
}

/// A storage-access message, with the reply of its own type.
enum StatisticsStorageAccessRequest: Sendable {
    case hasStorageAccess(
        sub: IPCTypes.RegistrableDomain,
        top: IPCTypes.RegistrableDomain,
        frameID: IPCTypes.FrameIdentifier?,
        webPageProxyID: UInt64,
        canRequestWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        reply: StatisticsReply<Bool>
    )
    case requestStorageAccess(
        sub: IPCTypes.RegistrableDomain,
        top: IPCTypes.RegistrableDomain,
        frameID: IPCTypes.FrameIdentifier,
        webPageProxyID: UInt64,
        scope: IPCTypes.StorageAccessScope,
        canRequestWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        reply: StatisticsReply<WebKit.StorageAccessStatus>
    )
    case grantStorageAccess(
        sub: IPCTypes.RegistrableDomain,
        top: IPCTypes.RegistrableDomain,
        frameID: IPCTypes.FrameIdentifier,
        webPageProxyID: UInt64,
        scope: IPCTypes.StorageAccessScope,
        reply: StatisticsReply<IPCTypes.StorageAccessWasGranted>
    )
    case storageAccessPermission(
        sub: IPCTypes.RegistrableDomain,
        top: IPCTypes.RegistrableDomain,
        reply: StatisticsReply<IPCTypes.PermissionState>
    )
}

/// A message whose store work completes later, after a main round trip, run by `perform(_:on:then:)`.
enum StatisticsDeferredCommandRequest: Sendable {
    case logUserInteraction(IPCTypes.RegistrableDomain)
    case clearUserInteraction(IPCTypes.RegistrableDomain)
    case updateCookieBlocking
    case processStatisticsAndDataRecords
    case setStorageAccessPermissionForTesting(granted: Bool, top: IPCTypes.RegistrableDomain, sub: IPCTypes.RegistrableDomain)
}

/// A message the store answers with a `Bool`, run on the actor by `ResourceLoadStatisticsStore.answer(_:on:)`.
enum StatisticsQueryRequest: Sendable {
    case isPrevalentResource(IPCTypes.RegistrableDomain)
    case isVeryPrevalentResource(IPCTypes.RegistrableDomain)
    case hasHadUserInteraction(IPCTypes.RegistrableDomain)
    case isGrandfathered(IPCTypes.RegistrableDomain)
    case isRelationshipOnlyInDatabaseOnce(sub: IPCTypes.RegistrableDomain, top: IPCTypes.RegistrableDomain)
    case isRegisteredAsSubresourceUnder(IPCTypes.RegistrableDomain, topFrame: IPCTypes.RegistrableDomain)
    case isRegisteredAsSubFrameUnder(IPCTypes.RegistrableDomain, topFrame: IPCTypes.RegistrableDomain)
    case isRegisteredAsRedirectingTo(from: IPCTypes.RegistrableDomain, to: IPCTypes.RegistrableDomain)
    case domainIDExistsInDatabase(Int32)
    case databaseHasAllTables
}

/// A message the store runs with no answer, run on the actor by `ResourceLoadStatisticsStore.perform(_:on:)`.
enum StatisticsCommandRequest: Sendable {
    case logFrameNavigation(
        target: IPCTypes.RegistrableDomain,
        topFrame: IPCTypes.RegistrableDomain,
        source: IPCTypes.RegistrableDomain,
        isRedirect: Bool,
        isMainFrame: Bool,
        delayAfterMainFrameDocumentLoad: Double,
        wasPotentiallyInitiatedByUser: Bool
    )
    case setLastSeen(IPCTypes.RegistrableDomain, seconds: Double)
    case setPrevalentResource(IPCTypes.RegistrableDomain)
    case setVeryPrevalentResource(IPCTypes.RegistrableDomain)
    case clearPrevalentResource(IPCTypes.RegistrableDomain)
    case setGrandfathered(IPCTypes.RegistrableDomain, Bool)
    case setSubframeUnderTopFrameDomain(IPCTypes.RegistrableDomain, topFrame: IPCTypes.RegistrableDomain)
    case setSubresourceUnderTopFrameDomain(IPCTypes.RegistrableDomain, topFrame: IPCTypes.RegistrableDomain)
    case setSubresourceUniqueRedirectTo(IPCTypes.RegistrableDomain, to: IPCTypes.RegistrableDomain)
    case setSubresourceUniqueRedirectFrom(IPCTypes.RegistrableDomain, from: IPCTypes.RegistrableDomain)
    case setTopFrameUniqueRedirectTo(IPCTypes.RegistrableDomain, to: IPCTypes.RegistrableDomain)
    case setTopFrameUniqueRedirectFrom(IPCTypes.RegistrableDomain, from: IPCTypes.RegistrableDomain)
    case resetParametersToDefaultValues
    case setTimeAdvanceForTesting(Double)
    case setIsRunningTest(Bool)
    case mergeStatisticForTesting(
        IPCTypes.RegistrableDomain,
        topFrame1: IPCTypes.RegistrableDomain,
        topFrame2: IPCTypes.RegistrableDomain,
        lastSeen: Double,
        hadUserInteraction: Bool,
        mostRecentUserInteraction: Double,
        isGrandfathered: Bool,
        isPrevalent: Bool,
        isVeryPrevalent: Bool,
        dataRecordsRemoved: UInt64
    )
    case insertExpiredStatisticForTesting(
        IPCTypes.RegistrableDomain,
        numberOfOperatingDaysPassed: UInt64,
        hadUserInteraction: Bool,
        isScheduledForAllButCookieDataRemoval: Bool,
        isPrevalent: Bool
    )
    case setGrandfatheringTime(Double)
    case setMaxStatisticsEntries(UInt64)
    case setMinimumTimeBetweenDataRecordsRemoval(Double)
    case setPruneEntriesDownTo(UInt64)
    case setTimeToLiveUserInteraction(Double)
    case setShouldClassifyResourcesBeforeDataRecordsRemoval(Bool)
    case requestStorageAccessUnderOpener(
        IPCTypes.RegistrableDomain,
        openerPage: UInt64,
        opener: IPCTypes.RegistrableDomain,
        canRequestWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction
    )
    // The C++ callers' (WebResourceLoadStatisticsStore.cpp), some of them the messages' too.
    case setResourceLoadStatisticsDebugMode(Bool)
    case setPrevalentResourceForDebugMode(StatisticsDomain)
    case setThirdPartyCookieBlockingMode(WebCore.ThirdPartyCookieBlockingMode)
    case setSameSiteStrictEnforcementEnabled(WebCore.SameSiteStrictEnforcementEnabled)
    case setFirstPartyWebsiteDataRemovalMode(WebCore.FirstPartyWebsiteDataRemovalMode)
    case setStandaloneApplicationDomain(StatisticsDomain)
    case performDailyTasks
    case logCrossSiteLoadWithLinkDecoration(from: StatisticsDomain, to: StatisticsDomain, didFilterKnownLinkDecoration: Bool)
    case setMostRecentWebPushInteractionTime(StatisticsDomain)
    case removeDataForDomain(StatisticsDomain)
    case setPersistedDomains([StatisticsDomain])
    #if ENABLE_APP_BOUND_DOMAINS
    case setAppBoundStatisticsDomains([StatisticsDomain])
    #endif
    #if ENABLE_MANAGED_DOMAINS
    case setManagedStatisticsDomains([StatisticsDomain])
    #endif
}

// MARK: Round-trip token

/// What one main part's C++ handler holds: it sends the round trip's second part at most once, and `.part2Dropped` if
/// it is destroyed unsent.
///
/// Neither the class nor its deinit is main-isolated: the deinit runs on the thread that destroys the C++ handler.
final class StatisticsRoundTripToken: Sendable {
    let inbox: StatisticsInbox
    let id: UInt64
    let generation: UInt64
    private let fired = Atomic<Bool>(false)

    init(inbox: StatisticsInbox, id: UInt64, generation: UInt64) {
        self.inbox = inbox
        self.id = id
        self.generation = generation
    }

    func fire(_ part2: StatisticsRequest) {
        if !fired.exchange(true, ordering: .acquiringAndReleasing) {
            inbox.enqueue(part2)
        }
    }

    deinit {
        if !fired.load(ordering: .acquiring) {
            inbox.enqueue(.part2Dropped(id: id, generation: generation))
        }
    }
}

// MARK: Inbox

/// The statistics actor's FIFO of requests, with the suspension of `SuspendableWorkQueue`.
///
/// Each `withLock` only decides, and returns what it took out; completions, resumes and the consumer's `Task` come after
/// it, since the lock is not recursive.
final class StatisticsInbox: Sendable {
    /// The producers' handle (the main side's messages): the actor itself is reached only by the consumer.
    static let shared = StatisticsInbox()

    private init() {}

    enum Phase {
        case running
        case willSuspend
        case suspended
    }

    struct State: ~Copyable {
        var requests: [StatisticsRequest] = []
        var phase: Phase = .running
        var pendingSuspend: [StatisticsReply<Void>] = []
        var waiter: CheckedContinuation<Void, Never>?
        var consumerStarted = false
    }

    private let state = Mutex(State())

    /// Appends a request, from any thread.
    ///
    /// While suspended it appends and wakes nothing.
    func enqueue(_ request: StatisticsRequest) {
        let (waiter, startsConsumer) = state.withLock { state -> (CheckedContinuation<Void, Never>?, Bool) in
            state.requests.append(request)
            let startsConsumer = !state.consumerStarted
            state.consumerStarted = true
            return (state.phase == .suspended ? nil : state.waiter.take(), startsConsumer)
        }
        waiter?.resume()
        if startsConsumer {
            startConsumer()
        }
    }

    private enum SuspendAction {
        case callNow(StatisticsReply<Void>)
        case parked
        case marked(waiter: CheckedContinuation<Void, Never>?, startsConsumer: Bool)
    }

    /// `SuspendableWorkQueue::suspend`: called at once if suspended, parked if a suspension is due, and otherwise a
    /// suspension is queued, waking an idle consumer.
    @MainActor
    func suspend(_ reply: StatisticsReply<Void>) {
        let action = state.withLock { state -> SuspendAction in
            switch state.phase {
            case .suspended:
                return .callNow(reply)
            case .willSuspend:
                state.pendingSuspend.append(reply)
                return .parked
            case .running:
                state.phase = .willSuspend
                state.pendingSuspend.append(reply)
                state.requests.append(.suspendIfNeeded)
                let startsConsumer = !state.consumerStarted
                state.consumerStarted = true
                return .marked(waiter: state.waiter.take(), startsConsumer: startsConsumer)
            }
        }
        switch action {
        case .callNow(let reply):
            reply.complete(())
        case .parked:
            break
        case .marked(let waiter, let startsConsumer):
            waiter?.resume()
            if startsConsumer {
                startConsumer()
            }
        }
    }

    /// `SuspendableWorkQueue::resume`.
    ///
    /// Boxes parked before a resume that comes first stay for the next suspension.
    func resume() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            switch state.phase {
            case .running:
                return nil
            case .willSuspend:
                state.phase = .running
                return nil
            case .suspended:
                state.phase = .running
                return state.waiter.take()
            }
        }
        waiter?.resume()
    }

    /// The consumer's: the parked suspension boxes if a suspension is due, which makes the phase `.suspended`.
    func beginSuspension() -> [StatisticsReply<Void>]? {
        state.withLock { state -> [StatisticsReply<Void>]? in
            guard state.phase == .willSuspend else {
                return nil
            }
            state.phase = .suspended
            var boxes: [StatisticsReply<Void>] = []
            swap(&boxes, &state.pendingSuspend)
            return boxes
        }
    }

    /// Parks the consumer while suspended.
    ///
    /// "Check, then park" is one critical section, so no resume is lost.
    func waitWhileSuspended() async {
        while isSuspended() {
            await park { $0.phase == .suspended }
        }
    }

    /// The consumer's: the whole array once running and not empty; otherwise parks, then checks again.
    func nextBatch() async -> [StatisticsRequest] {
        while true {
            let batch = takeBatch()
            if !batch.isEmpty {
                return batch
            }
            await park { $0.phase == .suspended || $0.requests.isEmpty }
        }
    }

    private func park(while shouldPark: @escaping @Sendable (borrowing State) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = state.withLock { state -> Bool in
                guard shouldPark(state) else {
                    return false
                }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return true
            }
            if !parked {
                continuation.resume()
            }
        }
    }

    private func isSuspended() -> Bool {
        state.withLock { $0.phase == .suspended }
    }

    private func takeBatch() -> [StatisticsRequest] {
        state.withLock { state -> [StatisticsRequest] in
            var batch: [StatisticsRequest] = []
            if state.phase != .suspended {
                swap(&batch, &state.requests)
            }
            return batch
        }
    }

    /// The one consumer, made by the producer that first sets `consumerStarted`.
    private func startConsumer() {
        Task { await StatisticsActor.shared.drain() }
    }
}

// MARK: Main side

/// The WebResourceLoadStatisticsStore's main-thread part, held in the actor's table; its members run only on main.
@MainActor
final class StatisticsMainSide {
    private let owner: WebKit.WebResourceLoadStatisticsStore

    init(owner: WebKit.WebResourceLoadStatisticsStore) {
        self.owner = owner
    }

    // The WebResourceLoadStatisticsStore is released on main even when the actor drops the last reference.
    isolated deinit {}

    #if compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN
    // Each C++ handler below is built from a `@Sendable` closure holding only the token, with `isolation: nil`: the
    // callee may call it on any thread, and the handler converts its argument to Swift before enqueueing.

    func updateCookieBlocking(
        _ domainsToBlock: StatisticsDomainsToBlockCookiesFor,
        _ inbox: StatisticsInbox,
        _ id: UInt64,
        _ generation: UInt64
    ) {
        var domains = WebKit.RegistrableDomainsToBlockCookiesFor()
        for domain in domainsToBlock.blockAndDeleteCookies {
            domains.domainsToBlockAndDeleteCookiesFor.append(consuming: domain.cxxDomain)
        }
        for domain in domainsToBlock.blockButKeepCookies {
            domains.domainsToBlockButKeepCookiesFor.append(consuming: domain.cxxDomain)
        }
        for domain in domainsToBlock.userInteractionAsFirstParty {
            domains.domainsWithUserInteractionAsFirstParty.append(consuming: domain.cxxDomain)
        }
        for pair in domainsToBlock.storageAccess {
            domains.addDomainWithStorageAccessForSwift(pair.topFrame.cxxDomain, pair.subResource.cxxDomain)
        }
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.callUpdatePrevalentDomainsToBlockCookiesForHandler(
            domains,
            consuming: .init(isolation: nil) { @Sendable in
                token.fire(.mainPartDone(id: token.id, generation: token.generation))
            }
        )
    }

    func broadcastConsoleMessage(_ source: UInt8, _ level: UInt8, _ message: Swift.String?) {
        owner.broadcastConsoleMessageForSwift(source, level, message.map { WTF.String($0) } ?? WTF.String())
    }

    func migratePrivateClickMeasurement(_ identifier: UInt64) {
        owner.migratePrivateClickMeasurementForSwift(identifier)
    }

    func setCacheMaxAgeCap(_ seconds: Double) {
        owner.setCacheMaxAgeCap(WTF.Seconds(seconds), consuming: .init(isolation: nil) { @Sendable in })
    }

    func setAgeCapForClientSideCookies(_ seconds: Double) {
        owner.setAgeCapForClientSideCookiesForSwift(WTF.Seconds(seconds))
    }

    func logTestingEvent(_ event: Swift.String) {
        owner.logTestingEvent(WTF.String(event))
    }

    func removeAllStorageAccess(_ inbox: StatisticsInbox, _ id: UInt64, _ generation: UInt64) {
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.removeAllStorageAccess(
            consuming: .init(isolation: nil) { @Sendable in
                token.fire(.mainPartDone(id: token.id, generation: token.generation))
            }
        )
    }

    func registrableDomainsWithWebsiteData(_ inbox: StatisticsInbox, _ id: UInt64, _ generation: UInt64) {
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.registrableDomainsWithWebsiteDataForSwift(
            consuming: .init(isolation: nil) { @Sendable (domains: consuming WebKit.StatisticsRegistrableDomains) in
                let swiftDomains = StatisticsDomain.list(domains.domains)
                token.fire(.domainsAnswered(id: token.id, generation: token.generation, domains: swiftDomains))
            }
        )
    }

    func hasCookies(_ domain: StatisticsDomain, _ inbox: StatisticsInbox, _ id: UInt64, _ generation: UInt64) {
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.hasCookies(
            domain.cxxDomain,
            consuming: .init(isolation: nil) { @Sendable (hasCookies: Bool) in
                token.fire(.boolAnswered(id: token.id, generation: token.generation, answer: hasCookies))
            }
        )
    }

    func deleteAndRestrictWebsiteData(
        _ domainsToDelete: StatisticsDomainsToDeleteOrRestrictWebsiteDataFor,
        _ inbox: StatisticsInbox,
        _ id: UInt64,
        _ generation: UInt64
    ) {
        var domains = WebKit.RegistrableDomainsToDeleteOrRestrictWebsiteDataFor()
        for domain in domainsToDelete.deleteAllCookies {
            domains.domainsToDeleteAllCookiesFor.append(consuming: domain.cxxDomain)
        }
        for domain in domainsToDelete.deleteAllButHttpOnlyCookies {
            domains.domainsToDeleteAllButHttpOnlyCookiesFor.append(consuming: domain.cxxDomain)
        }
        for domain in domainsToDelete.deleteAllScriptWrittenStorage {
            domains.domainsToDeleteAllScriptWrittenStorageFor.append(consuming: domain.cxxDomain)
        }
        for domain in domainsToDelete.enforceSameSiteStrict {
            domains.domainsToEnforceSameSiteStrictFor.append(consuming: domain.cxxDomain)
        }
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.deleteAndRestrictWebsiteDataForRegistrableDomainsForSwift(
            consuming: domains,
            consuming: .init(isolation: nil) { @Sendable (removed: consuming WebKit.StatisticsRegistrableDomains) in
                let swiftDomains = StatisticsDomain.list(removed.domains)
                token.fire(.domainsAnswered(id: token.id, generation: token.generation, domains: swiftDomains))
            }
        )
    }

    func hasStorageAccessForFrame(
        _ subFrame: StatisticsDomain,
        _ topFrame: StatisticsDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: UInt64,
        _ inbox: StatisticsInbox,
        _ id: UInt64,
        _ generation: UInt64
    ) {
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.callHasStorageAccessForFrameHandler(
            subFrame.cxxDomain,
            topFrame.cxxDomain,
            WebCore.FrameIdentifier(frameID),
            WebKit.WebPageProxyIdentifier(webPageProxyID),
            consuming: .init(isolation: nil) { @Sendable (hasAccess: Bool) in
                token.fire(.boolAnswered(id: token.id, generation: token.generation, answer: hasAccess))
            }
        )
    }

    /// The storage-access quirk's other (top frame, subframe) pairs for a grant, in the quirk's order, and whether the
    /// pair may ask without prior user interaction; nil pairs when there is no quirk.
    func storageAccessQuirkGrants(
        _ subFrame: StatisticsDomain,
        _ topFrame: StatisticsDomain,
        _ inbox: StatisticsInbox,
        _ id: UInt64,
        _ generation: UInt64
    ) {
        var hasQuirk = false
        var topFrames = WebKit.RegistrableDomainVector()
        var subFrames = WebKit.RegistrableDomainVector()
        let canRequest = owner.storageAccessQuirkGrantsForSwift(subFrame.cxxDomain, topFrame.cxxDomain, &hasQuirk, &topFrames, &subFrames)
        var pairs: [StatisticsDomainPair]?
        if hasQuirk {
            var list: [StatisticsDomainPair] = []
            for index in 0..<topFrames.size() {
                list.append(
                    StatisticsDomainPair(topFrame: StatisticsDomain(topFrames[index]), subFrame: StatisticsDomain(subFrames[index]))
                )
            }
            pairs = list
        }
        inbox.enqueue(
            .quirkGrantsAnswered(id: id, generation: generation, pairs: pairs, canRequestWithoutUserInteraction: canRequest)
        )
    }

    func grantStorageAccess(
        _ subFrame: StatisticsDomain,
        _ topFrame: StatisticsDomain,
        _ frameID: IPCTypes.FrameIdentifier?,
        _ webPageProxyID: UInt64,
        _ scope: IPCTypes.StorageAccessScope,
        _ inbox: StatisticsInbox,
        _ id: UInt64,
        _ generation: UInt64
    ) {
        let token = StatisticsRoundTripToken(inbox: inbox, id: id, generation: generation)
        owner.callGrantStorageAccessHandler(
            subFrame.cxxDomain,
            topFrame.cxxDomain,
            frameID.map { .init(WebCore.FrameIdentifier($0)) } ?? .init(),
            WebKit.WebPageProxyIdentifier(webPageProxyID),
            WebCore.StorageAccessScope(scope),
            consuming: .init(isolation: nil) { @Sendable (wasGranted: WebCore.StorageAccessWasGranted) in
                token.fire(
                    .storageAccessGranted(
                        id: token.id,
                        generation: token.generation,
                        wasGranted: IPCTypes.StorageAccessWasGranted(wasGranted)
                    )
                )
            }
        )
    }
    #endif
}

#if compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN
// Safe as WebPageProxy's conformance is: no requirement is implemented here, and a consuming handler has no
// continuation initializer, so its domains (`WTF.String`s) cannot reach another thread through one.
extension WebKit.RegistrableDomainVectorCompletionHandler: CxxConsumingCompletionHandler {
    typealias Argument = WebKit.StatisticsRegistrableDomains
}
#endif

/// A C++ domain the store hands back to C++ through the actor, held as its string's code units.
///
/// A Swift `String` would turn each unpaired surrogate into U+FFFD, so two domains C++ keeps apart could arrive as one;
/// the code units rebuild an equal `WTF::String` on the other side.
struct StatisticsDomain: Sendable {
    /// nil for the null string.
    private let codeUnits: [UInt16]?
    private let is8Bit: Bool

    /// Made where the C++ value is (the actor, or a main part's handler).
    init(_ domain: borrowing WebCore.RegistrableDomain) {
        let string = domain.statisticsString
        if string.isNull() {
            codeUnits = nil
            is8Bit = true
            return
        }
        var units: [UInt16] = []
        units.reserveCapacity(Int(string.length()))
        for index in 0..<string.length() {
            units.append(string.codeUnitAt(index))
        }
        codeUnits = units
        is8Bit = string.is8Bit()
    }

    static func list(_ domains: borrowing WebKit.RegistrableDomainVector) -> [Self] {
        var list: [Self] = []
        for index in 0..<domains.size() {
            list.append(Self(domains[index]))
        }
        return list
    }

    /// The C++ domain it was made from.
    var cxxDomain: WebCore.RegistrableDomain {
        guard let codeUnits else {
            return .fromRawString(consuming: WTF.String())
        }
        if codeUnits.isEmpty {
            return .fromRawString(consuming: WTF.String(""))
        }
        var builder = IPC.SwiftStringBuilder()
        for unit in codeUnits {
            if is8Bit {
                builder.appendLatin1(UInt8(truncatingIfNeeded: unit))
            } else {
                builder.appendUTF16(unit)
            }
        }
        return .fromRawString(consuming: builder.toString())
    }
}

/// A (top frame, subframe) pair of domains, for the storage-access quirk's grants.
struct StatisticsDomainPair: Sendable {
    var topFrame: StatisticsDomain
    var subFrame: StatisticsDomain
}

/// `RegistrableDomainsToDeleteOrRestrictWebsiteDataFor` as Swift values, for a data-record removal's main part.
struct StatisticsDomainsToDeleteOrRestrictWebsiteDataFor: Sendable {
    var deleteAllCookies: [StatisticsDomain]
    var deleteAllButHttpOnlyCookies: [StatisticsDomain]
    var deleteAllScriptWrittenStorage: [StatisticsDomain]
    var enforceSameSiteStrict: [StatisticsDomain]

    init(statistics domains: borrowing WebKit.RegistrableDomainsToDeleteOrRestrictWebsiteDataFor) {
        deleteAllCookies = StatisticsDomain.list(domains.domainsToDeleteAllCookiesFor)
        deleteAllButHttpOnlyCookies = StatisticsDomain.list(domains.domainsToDeleteAllButHttpOnlyCookiesFor)
        deleteAllScriptWrittenStorage = StatisticsDomain.list(domains.domainsToDeleteAllScriptWrittenStorageFor)
        enforceSameSiteStrict = StatisticsDomain.list(domains.domainsToEnforceSameSiteStrictFor)
    }
}

/// `RegistrableDomainsToBlockCookiesFor` as Swift values, for a cookie-blocking update's main part.
struct StatisticsDomainsToBlockCookiesFor: Sendable {
    var blockAndDeleteCookies: [StatisticsDomain]
    var blockButKeepCookies: [StatisticsDomain]
    var userInteractionAsFirstParty: [StatisticsDomain]
    /// The storage-access map's (top frame, subresource) pairs, in its iteration order.
    var storageAccess: [(topFrame: StatisticsDomain, subResource: StatisticsDomain)]

    init(statistics domains: borrowing WebKit.RegistrableDomainsToBlockCookiesFor) {
        blockAndDeleteCookies = StatisticsDomain.list(domains.domainsToBlockAndDeleteCookiesFor)
        blockButKeepCookies = StatisticsDomain.list(domains.domainsToBlockButKeepCookiesFor)
        userInteractionAsFirstParty = StatisticsDomain.list(domains.domainsWithUserInteractionAsFirstParty)
        var topFrames = WebKit.RegistrableDomainVector()
        var subResources = WebKit.RegistrableDomainVector()
        domains.appendDomainsWithStorageAccessForSwift(&topFrames, &subResources)
        storageAccess = []
        for index in 0..<topFrames.size() {
            storageAccess.append(
                (StatisticsDomain(topFrames[index]), StatisticsDomain(subResources[index]))
            )
        }
    }
}

// MARK: Actor

/// The one statistics actor: it owns every session's store, on the default executor.
actor StatisticsActor {
    static let shared = StatisticsActor()

    private init() {}

    nonisolated let inbox = StatisticsInbox.shared

    private struct Session {
        let store: WebKit.ResourceLoadStatisticsStore
        let mainSide: StatisticsMainSide
        let generation: UInt64
    }

    /// What a round trip's main part answered, for its second part.
    enum Outcome {
        case done
        case answered(Bool)
        case domains([StatisticsDomain])
        case granted(IPCTypes.StorageAccessWasGranted)
        case quirkGrants([StatisticsDomainPair]?, canRequestWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction)

        /// The domains of `.domains`, and none otherwise.
        var domains: [StatisticsDomain] {
            if case .domains(let domains) = self { domains } else { [] }
        }

        /// The answer of `.answered`, and `false` otherwise.
        var answer: Bool {
            if case .answered(let answer) = self { answer } else { false }
        }

        /// The grant of `.granted`, and `.no` otherwise.
        var wasGranted: IPCTypes.StorageAccessWasGranted {
            if case .granted(let wasGranted) = self { wasGranted } else { .no }
        }

        /// The quirk's grants of `.quirkGrants`, and none otherwise.
        var quirkGrants: [StatisticsDomainPair] {
            if case .quirkGrants(let pairs, _) = self { pairs ?? [] } else { [] }
        }

        /// Whether `.quirkGrants` may request without user interaction, and `.No` otherwise.
        var canRequestWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction {
            if case .quirkGrants(_, let canRequest) = self { canRequest } else { .No }
        }
    }

    /// A round trip's store side: run by its second part, with the store when the generation still matches, and with
    /// `nil` when it does not.
    private struct RoundTrip {
        let sessionID: UInt64
        let generation: UInt64
        let continuation: (WebKit.ResourceLoadStatisticsStore?, Outcome) -> Void
    }

    private var stores: [UInt64: Session] = [:]
    private var lastGeneration: UInt64 = 0
    private var roundTrips: [UInt64: RoundTrip] = [:]
    private var lastRoundTrip: UInt64 = 0

    /// The one consumer: each request runs after the suspension check `SuspendableWorkQueue::dispatch` wraps it in,
    /// and its stores' posts go to main before the next request, so none is held across a suspension.
    func drain() async {
        while true {
            for request in await inbox.nextBatch() {
                await suspendIfNeeded()
                run(request)
                flushPosts()
            }
        }
    }

    /// `SuspendableWorkQueue::suspendIfNeeded`, in the actor, off main.
    private func suspendIfNeeded() async {
        if let boxes = inbox.beginSuspension() {
            for session in stores.values {
                session.store.interruptDatabaseForSwift()
            }
            onMain { StatisticsReply.completeAll(boxes) }
        }
        await inbox.waitWhileSuspended()
    }

    private func run(_ request: StatisticsRequest) {
        switch request {
        case .create(let sessionID, let directory, let includeLocalhost, let mainSide):
            // A store this replaces sends what it posted before it goes.
            flushPosts()
            lastGeneration += 1
            let store = WebKit.ResourceLoadStatisticsStore.createForStatisticsActor(includeLocalhost, WTF.String(directory), sessionID)
                .ptr()
            stores[sessionID] = Session(store: store, mainSide: mainSide, generation: lastGeneration)
            store.didCreateNetworkProcess(on: self)
        case .destroy(let sessionID, let reply):
            // Its posts go before it is released; the reply follows them.
            flushPosts()
            stores[sessionID] = nil
            Self.onMain { reply.complete(nil) }
        case .suspendIfNeeded:
            break
        case .mainPartDone(let id, let generation):
            finishRoundTrip(id, generation, .done)
        case .boolAnswered(let id, let generation, let answer):
            finishRoundTrip(id, generation, .answered(answer))
        case .domainsAnswered(let id, let generation, let domains):
            finishRoundTrip(id, generation, .domains(domains))
        case .storageAccessGranted(let id, let generation, let wasGranted):
            finishRoundTrip(id, generation, .granted(wasGranted))
        case .quirkGrantsAnswered(let id, let generation, let pairs, let canRequest):
            finishRoundTrip(id, generation, .quirkGrants(pairs, canRequestWithoutUserInteraction: canRequest))
        case .part2Dropped(let id, _):
            // The entry goes without running.
            roundTrips[id] = nil
        case .processStatistics(let sessionID, let generation, let requestID):
            guard let session = stores[sessionID], session.generation == generation,
                session.store.isPendingStatisticsProcessingRequestForSwift(requestID)
            else {
                // Canceled or superseded on that store, or the store is gone.
                return
            }
            session.store.processStatisticsRequest(on: self)
        case .query(let sessionID, let query, let reply):
            let answer = stores[sessionID]?.store.answer(query, on: self)
            onMain { reply.complete(answer) }
        case .command(let sessionID, let command, let reply):
            let done: Void?
            if let store = stores[sessionID]?.store {
                store.perform(command, on: self)
                done = ()
            } else {
                done = nil
            }
            if let reply {
                onMain { reply.complete(done) }
            }
        case .deferredCommand(let sessionID, let command, let reply):
            guard let store = stores[sessionID]?.store else {
                let done: Void? = nil
                onMain { reply.complete(done) }
                return
            }
            store.perform(command, on: self) { [self] in
                let done: Void? = ()
                onMain { reply.complete(done) }
            }
        case .dumpStatistics(let sessionID, let reply):
            guard let store = stores[sessionID]?.store else {
                onMain { reply.complete(nil) }
                return
            }
            store.dumpResourceLoadStatistics(
                consuming: WebKit.StatisticsStringCompletionHandler { [self] text in
                    let dumped: Swift.String?? = .some(IPCCoding.WTFString.swiftString(text))
                    onMain { reply.complete(dumped) }
                }
            )
        case .domainList(let sessionID, let query, let reply):
            let answer = stores[sessionID]?.store.answer(query, on: self)
            onMain { reply.complete(answer) }
        case .completing(let sessionID, let request, let reply):
            guard let store = stores[sessionID]?.store else {
                onMain { reply.complete(nil) }
                return
            }
            // The store now, for work that outlives the request.
            let currentStore = { [self] in stores[sessionID]?.store }
            store.run(request, on: self, currentStore: currentStore) { [self] in
                let done: Void? = ()
                onMain { reply.complete(done) }
            }
        case .thirdPartyData(let sessionID, let query, let reply):
            let answer = stores[sessionID]?.store.answer(query, on: self)
            onMain { reply.complete(answer) }
        case .statisticsUpdated(let sessionID, let statistics, let reply, let updated):
            guard let store = stores[sessionID]?.store else {
                onMain { reply.complete(nil) }
                return
            }
            let done: Void? = ()
            if statistics.isEmpty {
                onMain { reply.complete(done) }
                return
            }
            store.mergeStatistics(statistics)
            onMain { reply.complete(done) }
            store.cancelPendingStatisticsProcessingRequest()
            // Fire before processing statistics to propagate user interaction as fast as possible to the network process.
            store.updateCookieBlocking(on: self) { [self] in
                onMain { updated.complete(done) }
            }
            store.processStatisticsAndDataRecords(on: self) {}
        case .storageAccess(let sessionID, let request):
            run(request, stores[sessionID]?.store)
        }
    }

    private func run(_ request: StatisticsStorageAccessRequest, _ store: WebKit.ResourceLoadStatisticsStore?) {
        switch request {
        case .hasStorageAccess(let sub, let top, let frameID, let webPageProxyID, let canRequest, let reply):
            guard let store else {
                onMain { reply.complete(nil) }
                return
            }
            store.hasStorageAccess(.fromIPC(sub), .fromIPC(top), frameID, webPageProxyID, canRequest, on: self) {
                [self] hasAccess in
                onMain { reply.complete(hasAccess) }
            }
        case .requestStorageAccess(let sub, let top, let frameID, let webPageProxyID, let scope, let canRequest, let reply):
            guard let store else {
                onMain { reply.complete(nil) }
                return
            }
            store.requestStorageAccess(.fromIPC(sub), .fromIPC(top), frameID, webPageProxyID, scope, canRequest, on: self) {
                [self] status in
                onMain { reply.complete(status) }
            }
        case .grantStorageAccess(let sub, let top, let frameID, let webPageProxyID, let scope, let reply):
            guard let store else {
                onMain { reply.complete(nil) }
                return
            }
            store.grantStorageAccess(.fromIPC(sub), .fromIPC(top), frameID, webPageProxyID, .Yes, scope, on: self) {
                [self] wasGranted in
                onMain { reply.complete(wasGranted) }
            }
        case .storageAccessPermission(let sub, let top, let reply):
            let permission = store?.storageAccessPermission(sub, top, on: self)
            onMain { reply.complete(permission) }
        }
    }

    /// Part 1 of a round trip, in its FIFO slot: records the store side, or runs it with no store.
    private func beginRoundTrip(
        _ sessionID: UInt64,
        _ continuation: @escaping (WebKit.ResourceLoadStatisticsStore?, Outcome) -> Void
    ) -> (session: Session, id: UInt64)? {
        guard let session = stores[sessionID] else {
            continuation(nil, .done)
            return nil
        }
        lastRoundTrip += 1
        roundTrips[lastRoundTrip] = RoundTrip(sessionID: sessionID, generation: session.generation, continuation: continuation)
        return (session, lastRoundTrip)
    }

    /// Part 2: on the store part 1 used, or with no store if it is gone.
    private func finishRoundTrip(_ id: UInt64, _ generation: UInt64, _ outcome: Outcome) {
        guard let roundTrip = roundTrips.removeValue(forKey: id) else {
            return
        }
        guard let session = stores[roundTrip.sessionID], session.generation == generation else {
            roundTrip.continuation(nil, outcome)
            return
        }
        roundTrip.continuation(session.store, outcome)
    }

    /// A round trip of the store of `sessionID`, made by the store's own Swift (ResourceLoadStatisticsStore.swift).
    ///
    /// Records `part2` and sends `mainPart` on after the posts made before it. With no store for the session, `part2`
    /// runs now with none.
    func roundTrip(
        _ sessionID: UInt64,
        mainPart: @escaping @MainActor @Sendable (StatisticsMainSide, StatisticsInbox, UInt64, UInt64) -> Void,
        then part2: @escaping (WebKit.ResourceLoadStatisticsStore?, Outcome) -> Void
    ) {
        guard let roundTrip = beginRoundTrip(sessionID, part2) else {
            return
        }
        let mainSide = roundTrip.session.mainSide
        let inbox = self.inbox
        let id = roundTrip.id
        let generation = roundTrip.session.generation
        onMain { mainPart(mainSide, inbox, id, generation) }
    }

    /// A main post of the store of `sessionID`, after the posts made before it.
    func post(_ sessionID: UInt64, _ work: @escaping @MainActor @Sendable (StatisticsMainSide) -> Void) {
        guard let mainSide = stores[sessionID]?.mainSide else {
            return
        }
        onMain { work(mainSide) }
    }

    /// The delayed statistics processing, carrying the store's own request id: the
    /// fired request runs only if that id is still the store's pending one.
    private func scheduleStatisticsProcessing(_ sessionID: UInt64, _ generation: UInt64, _ requestID: UInt64, after seconds: Double) {
        let inbox = self.inbox
        let fire: @Sendable () -> Void = {
            inbox.enqueue(.processStatistics(sessionID: sessionID, generation: generation, requestID: requestID))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: fire)
    }

    /// Sends on, in their order, the main-thread posts the stores' C++ and `@cxx` members made since the last flush.
    ///
    /// Called before each of the actor's own main hops, at the end of every job and before a store is released, so no
    /// post is passed by a later one, and none dies unsent. A job touches one store, so the stores' order is moot.
    private func flushPosts() {
        for (sessionID, session) in stores {
            let posts = session.store.takePendingPostsForSwift()
            for index in 0..<posts.size() {
                send(posts[index], sessionID, session)
            }
        }
    }

    private func send(_ post: borrowing WebKit.StatisticsStorePost, _ sessionID: UInt64, _ session: Session) {
        let mainSide = session.mainSide
        switch post.kind {
        case .ConsoleMessage:
            let source = post.consoleMessageSource
            let level = post.consoleMessageLevel
            let message = IPCCoding.WTFString.swiftString(post.consoleMessage)
            Self.onMain { mainSide.broadcastConsoleMessage(source, level, message) }
        case .CacheMaxAgeCap:
            let seconds = post.seconds.value()
            Self.onMain { mainSide.setCacheMaxAgeCap(seconds) }
        case .CookieBlocking:
            let domains = StatisticsDomainsToBlockCookiesFor(statistics: post.domainsToBlock)
            // Part 2: nothing past the store's debug log, and nothing with no store.
            guard let roundTrip = beginRoundTrip(sessionID, { store, _ in store?.logCookieBlockingDoneForSwift() }) else {
                return
            }
            let inbox = self.inbox
            let id = roundTrip.id
            let generation = roundTrip.session.generation
            Self.onMain { mainSide.updateCookieBlocking(domains, inbox, id, generation) }
        case .StatisticsProcessingRequest:
            scheduleStatisticsProcessing(
                sessionID,
                session.generation,
                post.statisticsProcessingRequestIdentifier,
                after: post.seconds.value()
            )
        case .PrivateClickMeasurementMigration:
            let identifier = post.privateClickMeasurementMigrationIdentifier
            Self.onMain { mainSide.migratePrivateClickMeasurement(identifier) }
        @unknown default:
            fatalError("WebKit.StatisticsStorePost.Kind has no other value")
        }
    }

    /// A main hop of the actor's own (a reply, a round trip's main part): the stores' posts made before it go first.
    private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        flushPosts()
        Self.onMain(work)
    }

    /// The one main hop: replies, round trips' main parts and the store's own posts, in the order they are made, on the
    /// main run loop with the IPC messages.
    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        WebKit.dispatchOnMainRunLoopForStatistics(StatisticsMainPosts.shared.add(work))
    }
}

/// The main hop's work, held by identifier until the main run loop runs it: C++ dispatches only the identifier.
final class StatisticsMainPosts: Sendable {
    static let shared = StatisticsMainPosts()

    private init() {}

    private struct State: ~Copyable {
        var lastIdentifier: UInt64 = 0
        var posts: [UInt64: @MainActor @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    func add(_ work: @escaping @MainActor @Sendable () -> Void) -> UInt64 {
        state.withLock { state in
            state.lastIdentifier += 1
            state.posts[state.lastIdentifier] = work
            return state.lastIdentifier
        }
    }

    func take(_ identifier: UInt64) -> (@MainActor @Sendable () -> Void)? {
        state.withLock { $0.posts.removeValue(forKey: identifier) }
    }
}

@MainActor
extension WebKit.NetworkProcess {
    /// `WebResourceLoadStatisticsStore::suspend()`: suspends the statistics inbox, then runs the C++ handler waiting
    /// under `completionIdentifier`.
    @cxx
    @implementation
    public func suspendStatisticsInboxForSwift(_ completionIdentifier: UInt64) {
        StatisticsInbox.shared.suspend(
            StatisticsReply<Void>(ifNoStore: {}) { WebKit.completeStatisticsSuspendForSwift(completionIdentifier) }
        )
    }

    /// `WebResourceLoadStatisticsStore::resume()`.
    @cxx
    @implementation
    public func resumeStatisticsInboxForSwift() {
        StatisticsInbox.shared.resume()
    }
}

@MainActor
extension WebKit.WebResourceLoadStatisticsStore {
    /// Makes this session's store on the statistics actor, which owns it from then on.
    @cxx
    @implementation
    public func createStatisticsStoreForSwift(_ directory: WTF.String, _ includeLocalhost: Bool) {
        sendToStatisticsActor(
            .create(
                sessionID: statisticsSessionIDForSwift(),
                directory: IPCCoding.WTFString.swiftString(directory) ?? "",
                includeLocalhost: includeLocalhost,
                mainSide: StatisticsMainSide(owner: self)
            )
        )
    }

    /// Runs and forgets the statistics actor's main-thread post waiting under `identifier`.
    @cxx
    @implementation
    public static func runStatisticsMainPostForSwift(_ identifier: UInt64) {
        StatisticsMainPosts.shared.take(identifier)?()
    }

    /// Releases this session's store on the statistics actor, then runs the handler waiting under
    /// `completionIdentifier`.
    @cxx
    @implementation
    public func destroyStatisticsStoreForSwift(_ completionIdentifier: UInt64) {
        let reply = StatisticsReply<Void>(ifNoStore: {}, { [self] in completePendingCompletionForSwift(completionIdentifier) })
        sendToStatisticsActor(.destroy(sessionID: statisticsSessionIDForSwift(), reply: reply))
    }

    /// `WebResourceLoadStatisticsStore::setResourceLoadStatisticsDebugMode()`: nothing for an ephemeral session.
    @cxx
    @implementation
    public func setResourceLoadStatisticsDebugMode(_ value: Bool) {
        if isEphemeral() {
            return
        }
        setTrackingPreventionDebugLoggingEnabled(value)
        onStatisticsActor(.setResourceLoadStatisticsDebugMode(value))
    }

    /// `WebResourceLoadStatisticsStore::setPrevalentResourceForDebugMode()`: nothing for an ephemeral session.
    @cxx
    @implementation
    public func setPrevalentResourceForDebugMode(_ domain: WebCore.RegistrableDomain) {
        if isEphemeral() {
            return
        }
        onStatisticsActor(.setPrevalentResourceForDebugMode(StatisticsDomain(domain)))
    }

    /// The store work of `WebResourceLoadStatisticsStore::setThirdPartyCookieBlockingMode()`.
    @cxx
    @implementation
    public func setThirdPartyCookieBlockingModeForSwift(_ mode: WebCore.ThirdPartyCookieBlockingMode) {
        onStatisticsActor(.setThirdPartyCookieBlockingMode(mode))
    }

    /// `WebResourceLoadStatisticsStore::setSameSiteStrictEnforcementEnabled()`: nothing for an ephemeral session.
    @cxx
    @implementation
    public func setSameSiteStrictEnforcementEnabled(_ enabled: WebCore.SameSiteStrictEnforcementEnabled) {
        if isEphemeral() {
            return
        }
        onStatisticsActor(.setSameSiteStrictEnforcementEnabled(enabled))
    }

    /// `WebResourceLoadStatisticsStore::setFirstPartyWebsiteDataRemovalMode()`: nothing for an ephemeral session.
    @cxx
    @implementation
    public func setFirstPartyWebsiteDataRemovalMode(_ mode: WebCore.FirstPartyWebsiteDataRemovalMode) {
        if isEphemeral() {
            return
        }
        onStatisticsActor(.setFirstPartyWebsiteDataRemovalMode(mode))
    }

    /// `WebResourceLoadStatisticsStore::setStandaloneApplicationDomain()`: nothing for an ephemeral session or an empty
    /// domain.
    @cxx
    @implementation
    public func setStandaloneApplicationDomain(_ domain: WebCore.RegistrableDomain) {
        if isEphemeral() || domain.isEmpty() {
            return
        }
        let releaseLog = WebKit.LogChannel.ResourceLoadStatistics().releaseLog
        releaseLog.log("WebResourceLoadStatisticsStore::setStandaloneApplicationDomain() called with non-empty domain.")
        onStatisticsActor(.setStandaloneApplicationDomain(StatisticsDomain(domain)))
    }

    /// `WebResourceLoadStatisticsStore::performDailyTasks()`, which the daily tasks timer calls.
    @cxx
    @implementation
    func performDailyTasks() {
        WebKit.LogChannel.ResourceLoadStatistics().releaseLog.log("WebResourceLoadStatisticsStore::performDailyTasks")
        onStatisticsActor(.performDailyTasks)
    }

    /// The store work of `WebResourceLoadStatisticsStore::logCrossSiteLoadWithLinkDecoration()`, then the handler
    /// waiting under `completionIdentifier`.
    @cxx
    @implementation
    public func logCrossSiteLoadWithLinkDecorationForSwift(
        _ fromDomain: WebCore.RegistrableDomain,
        _ toDomain: WebCore.RegistrableDomain,
        _ didFilterKnownLinkDecoration: Bool,
        _ completionIdentifier: UInt64
    ) {
        let command = StatisticsCommandRequest.logCrossSiteLoadWithLinkDecoration(
            from: StatisticsDomain(fromDomain),
            to: StatisticsDomain(toDomain),
            didFilterKnownLinkDecoration: didFilterKnownLinkDecoration
        )
        onStatisticsActor(command, completionIdentifier: completionIdentifier)
    }

    /// The store work of `WebResourceLoadStatisticsStore::setMostRecentWebPushInteractionTime()`, then the handler
    /// waiting under `completionIdentifier`.
    @cxx
    @implementation
    public func setMostRecentWebPushInteractionTimeForSwift(_ domain: WebCore.RegistrableDomain, _ completionIdentifier: UInt64) {
        onStatisticsActor(.setMostRecentWebPushInteractionTime(StatisticsDomain(domain)), completionIdentifier: completionIdentifier)
    }

    /// The store work of `WebResourceLoadStatisticsStore::removeDataForDomain()`, then the handler waiting under
    /// `completionIdentifier`.
    @cxx
    @implementation
    public func removeDataForDomainForSwift(_ domain: WebCore.RegistrableDomain, _ completionIdentifier: UInt64) {
        onStatisticsActor(.removeDataForDomain(StatisticsDomain(domain)), completionIdentifier: completionIdentifier)
    }

    /// Sends the domain-list query `kind`, then runs the handler waiting under `completionIdentifier` with its list.
    @cxx
    @implementation
    public func domainListForSwift(_ kind: UInt8, _ completionIdentifier: UInt64) {
        guard let query = StatisticsDomainListRequest(rawValue: kind) else {
            preconditionFailure("unknown domain-list kind \(kind)")
        }
        let noStore = StatisticsDomainList(
            hasValue: query == .allDomains || query == .domainsExemptFromWebsiteDataDeletion,
            domains: [],
            times: []
        )
        let reply = StatisticsReply<StatisticsDomainList>(
            ifNoStore: { noStore },
            { [self] answer in
                var domains = WebKit.RegistrableDomainVector()
                for domain in answer.domains {
                    domains.append(consuming: domain.cxxDomain)
                }
                var times = WebKit.StatisticsTimeVector()
                for time in answer.times {
                    times.append(consuming: time)
                }
                completePendingDomainListForSwift(completionIdentifier, answer.hasValue, domains, times)
            }
        )
        sendToStatisticsActor(.domainList(sessionID: statisticsSessionIDForSwift(), query, reply: reply))
    }

    /// `WebResourceLoadStatisticsStore::populateMemoryStoreFromDisk()`.
    @cxx
    @implementation
    public func populateMemoryStoreFromDisk() {
        onStatisticsActor(.populateMemoryStoreFromDisk) {}
    }

    /// The store work of `WebResourceLoadStatisticsStore::scheduleClearInMemoryAndPersistent()`, then the handler
    /// waiting under `completionIdentifier`.
    @cxx
    @implementation
    public func scheduleClearInMemoryAndPersistentForSwift(_ shouldGrandfather: Bool, _ completionIdentifier: UInt64) {
        onStatisticsActor(.clearInMemoryAndPersistent(shouldGrandfather: shouldGrandfather), completionIdentifier: completionIdentifier)
    }

    /// `WebResourceLoadStatisticsStore::setPersistedDomains()`: nothing for an ephemeral session or no domains.
    @cxx
    @implementation
    public func setPersistedDomains(_ domains: WebKit.RegistrableDomainVector) {
        if isEphemeral() || domains.isEmpty() {
            return
        }
        onStatisticsActor(.setPersistedDomains(StatisticsDomain.list(domains)))
    }

    #if ENABLE_APP_BOUND_DOMAINS
    /// The store work of `WebResourceLoadStatisticsStore::setAppBoundDomains()`, then the handler waiting under
    /// `completionIdentifier`.
    @cxx
    @implementation
    public func setAppBoundDomainsOnStatisticsActorForSwift(_ domains: WebKit.RegistrableDomainVector, _ completionIdentifier: UInt64) {
        onStatisticsActor(.setAppBoundStatisticsDomains(StatisticsDomain.list(domains)), completionIdentifier: completionIdentifier)
    }
    #endif

    #if ENABLE_MANAGED_DOMAINS
    /// The store work of `WebResourceLoadStatisticsStore::setManagedDomains()`, then the handler waiting under
    /// `completionIdentifier`.
    @cxx
    @implementation
    public func setManagedDomainsOnStatisticsActorForSwift(_ domains: WebKit.RegistrableDomainVector, _ completionIdentifier: UInt64) {
        onStatisticsActor(.setManagedStatisticsDomains(StatisticsDomain.list(domains)), completionIdentifier: completionIdentifier)
    }
    #endif

    /// Sends a request from this session's main side to the statistics actor.
    private func sendToStatisticsActor(_ request: StatisticsRequest) {
        // Resource load statistics should not be captured for ephemeral sessions.
        precondition(!isEphemeral())

        StatisticsInbox.shared.enqueue(request)
    }

    /// Sends a C++ caller's `request`, then runs the handler waiting under `completionIdentifier`, store or not.
    private func onStatisticsActor(_ request: StatisticsCompletingRequest, completionIdentifier: UInt64) {
        onStatisticsActor(request) { [self] in completePendingCompletionForSwift(completionIdentifier) }
    }

    /// Sends `request` to this session's store on the statistics actor; `completion` runs on the main actor when the
    /// store's work completes, store or not.
    func onStatisticsActor(_ request: StatisticsCompletingRequest, then completion: @escaping () -> Void) {
        let reply = StatisticsReply<Void>(ifNoStore: {}, { completion() })
        sendToStatisticsActor(.completing(sessionID: statisticsSessionIDForSwift(), request, reply: reply))
    }

    /// Sends a C++ caller's `command`, then runs the handler waiting under `completionIdentifier`, store or not.
    private func onStatisticsActor(_ command: StatisticsCommandRequest, completionIdentifier: UInt64) {
        onStatisticsActor(command) { [self] in completePendingCompletionForSwift(completionIdentifier) }
    }
    /// Sends `query` to this session's store on the statistics actor.
    ///
    /// `completion` gets its answer on the main actor, or `ifNoStore` with no store.
    func onStatisticsActor(
        _ query: StatisticsQueryRequest,
        ifNoStore: @autoclosure @escaping () -> Bool,
        then completion: @escaping (Bool) -> Void
    ) {
        sendToStatisticsActor(
            .query(sessionID: statisticsSessionIDForSwift(), query, reply: StatisticsReply(ifNoStore: ifNoStore, completion))
        )
    }

    /// Sends `command` to this session's store on the statistics actor.
    ///
    /// `completion`, if any, runs on the main actor after it, store or not.
    func onStatisticsActor(_ command: StatisticsCommandRequest, then completion: (() -> Void)? = nil) {
        let reply = completion.map { completion in StatisticsReply<Void>(ifNoStore: {}) { completion() } }
        sendToStatisticsActor(.command(sessionID: statisticsSessionIDForSwift(), command, reply: reply))
    }

    /// Sends `command` to this session's store on the statistics actor; `completion` runs on the main actor when the
    /// store's work completes, or at once with no store.
    func onStatisticsActor(_ command: StatisticsDeferredCommandRequest, then completion: @escaping () -> Void) {
        let reply = StatisticsReply<Void>(ifNoStore: {}, { completion() })
        sendToStatisticsActor(.deferredCommand(sessionID: statisticsSessionIDForSwift(), command, reply: reply))
    }

    /// Sends the store's text dump on the statistics actor; `completion` gets it once any data-record removal under way
    /// ends, or `ifNoStore` with no store.
    func onStatisticsActorDumpResourceLoadStatistics(
        ifNoStore: @autoclosure @escaping () -> Swift.String?,
        then completion: @escaping (Swift.String?) -> Void
    ) {
        sendToStatisticsActor(
            .dumpStatistics(sessionID: statisticsSessionIDForSwift(), reply: StatisticsReply(ifNoStore: ifNoStore, completion))
        )
    }

    /// Sends `query` to this session's store on the statistics actor; `completion` gets its answer on the main actor,
    /// or `ifNoStore` with no store.
    func onStatisticsActor(
        _ query: StatisticsThirdPartyDataRequest,
        ifNoStore: @autoclosure @escaping () -> [IPCTypes.ITPThirdPartyData],
        then completion: @escaping ([IPCTypes.ITPThirdPartyData]) -> Void
    ) {
        sendToStatisticsActor(
            .thirdPartyData(sessionID: statisticsSessionIDForSwift(), query, reply: StatisticsReply(ifNoStore: ifNoStore, completion))
        )
    }

    /// Merges a web process's statistics on the statistics actor. `completion` runs after the merge, store or not;
    /// `updated` after the cookie-blocking update that follows a non-empty merge, and never with no store.
    func onStatisticsActor(
        statisticsUpdated statistics: [IPCTypes.ResourceLoadStatistics],
        then completion: @escaping () -> Void,
        afterCookieBlocking updated: @escaping () -> Void
    ) {
        sendToStatisticsActor(
            .statisticsUpdated(
                sessionID: statisticsSessionIDForSwift(),
                statistics,
                reply: StatisticsReply(ifNoStore: {}) { completion() },
                updated: StatisticsReply(ifNoStore: {}) { updated() }
            )
        )
    }

    /// The store's part of `hasStorageAccess`, on the statistics actor; `false` with no store.
    func onStatisticsActor(
        hasStorageAccess subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier?,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        then completion: @escaping (Bool) -> Void
    ) {
        let request = StatisticsStorageAccessRequest.hasStorageAccess(
            sub: subFrameDomain,
            top: topFrameDomain,
            frameID: frameID,
            webPageProxyID: webPageProxyID.rawValue,
            canRequestWithoutUserInteraction: canRequestStorageAccessWithoutUserInteraction,
            reply: StatisticsReply(ifNoStore: { false }, completion)
        )
        sendToStatisticsActor(.storageAccess(sessionID: statisticsSessionIDForSwift(), request))
    }

    /// The store's part of `requestStorageAccess`, on the statistics actor; `.CannotRequestAccess` with no store.
    func onStatisticsActor(
        requestStorageAccess subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ scope: IPCTypes.StorageAccessScope,
        _ canRequestStorageAccessWithoutUserInteraction: WebKit.CanRequestStorageAccessWithoutUserInteraction,
        then completion: @escaping (WebKit.StorageAccessStatus) -> Void
    ) {
        let request = StatisticsStorageAccessRequest.requestStorageAccess(
            sub: subFrameDomain,
            top: topFrameDomain,
            frameID: frameID,
            webPageProxyID: webPageProxyID.rawValue,
            scope: scope,
            canRequestWithoutUserInteraction: canRequestStorageAccessWithoutUserInteraction,
            reply: StatisticsReply(ifNoStore: { .CannotRequestAccess }, completion)
        )
        sendToStatisticsActor(.storageAccess(sessionID: statisticsSessionIDForSwift(), request))
    }

    /// The store's part of a grant the user confirmed in a prompt, on the statistics actor; `.no` with no store.
    func onStatisticsActor(
        grantStorageAccess subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ scope: IPCTypes.StorageAccessScope,
        then completion: @escaping (IPCTypes.StorageAccessWasGranted) -> Void
    ) {
        let request = StatisticsStorageAccessRequest.grantStorageAccess(
            sub: subFrameDomain,
            top: topFrameDomain,
            frameID: frameID,
            webPageProxyID: webPageProxyID.rawValue,
            scope: scope,
            reply: StatisticsReply(ifNoStore: { .no }, completion)
        )
        sendToStatisticsActor(.storageAccess(sessionID: statisticsSessionIDForSwift(), request))
    }

    /// The store's storage-access permission for the pair, on the statistics actor; `ifNoStore` with no store.
    func onStatisticsActor(
        storageAccessPermission subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        ifNoStore: @autoclosure @escaping () -> IPCTypes.PermissionState,
        then completion: @escaping (IPCTypes.PermissionState) -> Void
    ) {
        let request = StatisticsStorageAccessRequest.storageAccessPermission(
            sub: subFrameDomain,
            top: topFrameDomain,
            reply: StatisticsReply(ifNoStore: ifNoStore, completion)
        )
        sendToStatisticsActor(.storageAccess(sessionID: statisticsSessionIDForSwift(), request))
    }
}
