// Copyright (C) 2022 Apple Inc. All rights reserved.
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

private struct OriginQuotaManagerState {
    struct Request {
        let spaceRequested: UInt64
        let callbackBox: WebKit.OriginQuotaManager.RequestCallbackBox
    }

    enum CurrentRequest {
        case checking(Request)
        case awaitingQuotaIncrease(Request, identifier: UInt64)

        var request: Request {
            switch self {
            case .checking(let request), .awaitingQuotaIncrease(let request, _):
                request
            }
        }
    }

    var quotaCountdown: UInt64 = 0
    var quota: UInt64
    var standardReportedQuota: UInt64
    var initialQuota: UInt64 // Test only.
    var usage: UInt64?
    var isHandlingRequests = false
    var pendingRequests: [Request] = []
    var currentRequest: CurrentRequest?

    mutating func makeNextRequestCurrent() -> UInt64? {
        guard currentRequest == nil, !pendingRequests.isEmpty else {
            return nil
        }
        let request = pendingRequests.removeFirst()
        currentRequest = .checking(request)
        return request.spaceRequested
    }
}

private let originQuotaManagerStates = StateTable<OriginQuotaManagerState>()

private enum QuotaGrant {
    case granted
    case denied(usage: UInt64)

    var decision: WebKit.OriginQuotaManager.Decision {
        switch self {
        case .granted:
            .Grant
        case .denied:
            .Deny
        }
    }
}

extension WebKit.OriginQuotaManager {
    private static let defaultReportedQuotaIncreaseFactor = 2.0

    @cxx
    @implementation
    func initializeState(_ quota: UInt64, _ standardReportedQuota: UInt64) {
        let key = swiftKey()
        originQuotaManagerStates.insert(for: key) {
            OriginQuotaManagerState(quota: quota, standardReportedQuota: standardReportedQuota, initialQuota: quota)
        }
    }

    /// Releases the manager's state and its unanswered requests, the current one first, from the destructor on the
    /// storage queue.
    @cxx
    @implementation
    func destroyState() {
        guard var state = originQuotaManagerStates.take(for: swiftKey()) else {
            return
        }
        _ = state.currentRequest.take()
        state.pendingRequests = []
    }

    @cxx
    @implementation
    func usage() -> UInt64 {
        let key = swiftKey()
        let (quota, quotaCountdown, usage) = originQuotaManagerStates.withState(for: key) {
            ($0.quota, $0.quotaCountdown, $0.usage)
        }
        // Estimated usage that includes granted space.
        if quotaCountdown != 0 {
            // quotaCountdown never exceeds quota.
            return quota &- quotaCountdown
        }

        if let usage {
            return min(usage, quota)
        }
        let newUsage = m_getUsageFunction()
        return originQuotaManagerStates.withState(for: key) { state in
            state.usage = newUsage
            return min(newUsage, state.quota)
        }
    }

    @cxx
    @implementation
    func reportedQuota() -> UInt64 {
        let key = swiftKey()
        let (quota, standardReportedQuota) = originQuotaManagerStates.withState(for: key) {
            ($0.quota, $0.standardReportedQuota)
        }
        if standardReportedQuota == 0 {
            return quota
        }

        // Standard reported quota is at least double existing usage.
        let expectedUsage = Double(usage()) * Self.defaultReportedQuotaIncreaseFactor
        return originQuotaManagerStates.withState(for: key) { state in
            while expectedUsage > Double(state.standardReportedQuota) && state.standardReportedQuota < state.quota {
                let increased = Double(state.standardReportedQuota) * Self.defaultReportedQuotaIncreaseFactor
                state.standardReportedQuota = increased < Double(UInt64.max) ? UInt64(increased) : .max
            }
            return min(state.quota, state.standardReportedQuota)
        }
    }

    /// Queues a request for space, on the storage queue, where the handler is made.
    @cxx
    @implementation
    func requestSpace(_ spaceRequested: UInt64, _ callbackBox: WebKit.OriginQuotaManager.RequestCallbackBox) {
        originQuotaManagerStates.withState(for: swiftKey()) { state in
            state.pendingRequests.append(OriginQuotaManagerState.Request(spaceRequested: spaceRequested, callbackBox: callbackBox))
        }
        handleRequests()
    }

    /// Answers the current request with the quota the UI process granted, on the storage queue, where
    /// NetworkStorageManager::didIncreaseQuota posts it.
    @cxx
    @implementation
    func didIncreaseQuota(_ identifier: WebKit.QuotaIncreaseRequestIdentifier, _ newQuota: WebKit.OptionalUInt64) {
        let key = swiftKey()
        let currentRequestSpace = originQuotaManagerStates.withState(for: key) { state -> UInt64? in
            guard case .awaitingQuotaIncrease(let request, identifier.toUInt64()) = state.currentRequest else {
                return nil
            }
            if let newQuota = newQuota.value {
                state.quota = newQuota
                // Recalculate quotaCountdown based on usage.
                state.quotaCountdown = 0
            }
            return request.spaceRequested
        }
        guard let spaceRequested = currentRequestSpace else {
            return
        }

        answerCurrentRequest(grantWithCurrentQuota(spaceRequested).decision)

        if !originQuotaManagerStates.withState(for: key, { $0.isHandlingRequests }) {
            handleRequests()
        }
    }

    @cxx
    @implementation
    func resetQuotaUpdatedBasedOnUsageForTesting() {
        resetQuotaForTesting()
        originQuotaManagerStates.withState(for: swiftKey()) { $0.usage = nil }
    }

    @cxx
    @implementation
    func resetQuotaForTesting() {
        originQuotaManagerStates.withState(for: swiftKey()) { state in
            state.quota = state.initialQuota
            state.quotaCountdown = 0
        }
    }

    @cxx
    @implementation
    func updateQuotaForTesting(_ quota: UInt64, _ standardReportedQuota: UInt64) {
        originQuotaManagerStates.withState(for: swiftKey()) { state in
            state.quota = quota
            state.standardReportedQuota = standardReportedQuota
            state.initialQuota = quota
            state.quotaCountdown = 0
            state.usage = nil
        }
    }

    private func handleRequests() {
        let key = swiftKey()
        let wasHandlingRequests = originQuotaManagerStates.withState(for: key) { state in
            exchange(&state.isHandlingRequests, with: true)
        }
        defer {
            originQuotaManagerStates.withState(for: key) { $0.isHandlingRequests = wasHandlingRequests }
        }

        while let spaceRequested = originQuotaManagerStates.withState(for: key, { $0.makeNextRequestCurrent() }) {
            guard case .denied(let usage) = grantWithCurrentQuota(spaceRequested) else {
                answerCurrentRequest(.Grant)
                continue
            }

            if !Bool(fromCxx: m_increaseQuotaFunction) {
                answerCurrentRequest(.Deny)
                continue
            }

            let identifier = WebKit.QuotaIncreaseRequestIdentifier.generate()
            let quota = originQuotaManagerStates.withState(for: key) { state in
                if case .checking(let request) = state.currentRequest {
                    state.currentRequest = .awaitingQuotaIncrease(request, identifier: identifier.toUInt64())
                }
                return state.quota
            }
            m_increaseQuotaFunction(identifier, quota, usage, spaceRequested)
        }
    }

    /// Answers the current request, which stays current while its handler runs, on the storage queue
    /// (`handleRequests` and `didIncreaseQuota`).
    private func answerCurrentRequest(_ decision: WebKit.OriginQuotaManager.Decision) {
        let key = swiftKey()
        if let callbackBox = originQuotaManagerStates.withState(for: key, { $0.currentRequest?.request.callbackBox }) {
            unsafe callbackBox(decision) // U5(storage queue): handleRequests and didIncreaseQuota run there, where C++ made the handler.
        }
        _ = originQuotaManagerStates.withState(for: key) { $0.currentRequest.take() }
    }

    private func grantWithCurrentQuota(_ spaceRequested: UInt64) -> QuotaGrant {
        if grantFastPath(spaceRequested) {
            return .granted
        }

        // When OriginQuotaManager is used for the first time, we want to make sure its initial quota is bigger than existing disk usage,
        // based on the assumption that the quota was increased to at least the disk usage under user's permission before.
        let key = swiftKey()
        let shouldUpdateQuotaBasedOnUsage = originQuotaManagerStates.withState(for: key) { $0.usage == nil }
        let usage = m_getUsageFunction()
        originQuotaManagerStates.withState(for: key) { state in
            state.usage = usage
            let defaultQuotaStep = state.quota / 10
            if shouldUpdateQuotaBasedOnUsage && defaultQuotaStep != 0 {
                // Wraps for a usage within one step of UInt64.max.
                state.quota = max(state.quota, defaultQuotaStep &* (usage / defaultQuotaStep &+ 1))
            }
            state.quotaCountdown = usage < state.quota ? state.quota - usage : 0
        }

        return grantFastPath(spaceRequested) ? .granted : .denied(usage: usage)
    }

    private func spaceGranted(_ amount: UInt64) {
        if Bool(fromCxx: m_notifySpaceGrantedFunction) {
            m_notifySpaceGrantedFunction(amount)
        }
    }

    private func grantFastPath(_ spaceRequested: UInt64) -> Bool {
        let granted = originQuotaManagerStates.withState(for: swiftKey()) { state in
            guard spaceRequested <= state.quotaCountdown else {
                return false
            }
            state.quotaCountdown -= spaceRequested
            return true
        }
        if granted {
            spaceGranted(spaceRequested)
        }
        return granted
    }
}
