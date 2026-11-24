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

extension WebCore.FrameIdentifier {
    init(_ identifier: IPCTypes.FrameIdentifier) {
        self.init(identifier.rawValue)
    }
}

extension WebKit.WebPageProxyIdentifier {
    fileprivate init(_ identifier: IPCTypes.WebPageProxyIdentifier) {
        self.init(identifier.rawValue)
    }
}

extension IPCTypes.StorageAccessWasGranted {
    init(_ wasGranted: WebCore.StorageAccessWasGranted) {
        switch wasGranted {
        case .No: self = .no
        case .Yes: self = .yes
        case .YesWithException: self = .yesWithException
        @unknown default: fatalError("WebCore.StorageAccessWasGranted has no other value")
        }
    }
}

extension WebCore.StorageAccessScope {
    init(_ value: IPCTypes.StorageAccessScope) {
        switch value {
        case .perFrame: self = .PerFrame
        case .perPage: self = .PerPage
        }
    }
}

@MainActor
extension WebKit.WebResourceLoadStatisticsStore {
    func hasStorageAccess(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier?,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        then completion: @escaping (Bool) -> Void
    ) {
        if isEphemeral() {
            completion(
                hasStorageAccessEphemeral(
                    .fromIPC(subFrameDomain),
                    .fromIPC(topFrameDomain),
                    frameID.map { .init(WebCore.FrameIdentifier($0)) } ?? .init(),
                    .init(webPageProxyID)
                )
            )
            return
        }
        let canRequestStorageAccessWithoutUserInteraction = canRequestStorageAccessWithoutUserInteraction(
            .fromIPC(subFrameDomain),
            .fromIPC(topFrameDomain)
        )
        onStatisticsActor(
            hasStorageAccess: subFrameDomain,
            topFrameDomain,
            frameID,
            webPageProxyID,
            canRequestStorageAccessWithoutUserInteraction,
            then: completion
        )
    }

    func requestStorageAccess(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ scope: IPCTypes.StorageAccessScope,
        _ hasUserGestureOrNoUserGestureRequired: IPCTypes.HasUserGestureOrNoUserGestureRequired,
        then completion: @escaping (IPCTypes.RequestStorageAccessResult) -> Void
    ) {
        func reply(_ wasGranted: IPCTypes.StorageAccessWasGranted, _ promptWasShown: IPCTypes.StorageAccessPromptWasShown) {
            completion(
                .init(
                    wasGranted: wasGranted,
                    promptWasShown: promptWasShown,
                    scope: scope,
                    topFrameDomain: topFrameDomain,
                    subFrameDomain: subFrameDomain
                )
            )
        }

        // Converted once for the calls on the main actor; the actor's requests carry the Swift domains.
        let subFrame = WebCore.RegistrableDomain.fromIPC(subFrameDomain)
        let topFrame = WebCore.RegistrableDomain.fromIPC(topFrameDomain)

        if subFrame == topFrame {
            reply(.yes, .no)
            return
        }

        if hasUserGestureOrNoUserGestureRequired == .no
            && !isStorageAccessPermissionGrantedInPage(.init(webPageProxyID), topFrame, subFrame)
        {
            reply(.no, .no)
            return
        }

        let canRequestStorageAccessWithoutUserInteraction = canRequestStorageAccessWithoutUserInteraction(subFrame, topFrame)
        let storageAccessQuirk = storageAccessQuirk(subFrame, topFrame)

        if isEphemeral() {
            guard
                hasNetworkSession()
                    && (hasEphemeralUserInteraction(subFrame)
                        || canRequestStorageAccessWithoutUserInteraction == .Yes)
            else {
                reply(.no, .no)
                return
            }
            confirmStorageAccess(subFrameDomain, topFrameDomain, frameID, webPageProxyID, storageAccessQuirk) { [self] userDidGrantAccess in
                guard userDidGrantAccess else {
                    reply(.no, .yes)
                    return
                }
                let wasGranted = grantStorageAccessInEphemeralStorageSession(
                    .fromIPC(subFrameDomain),
                    .fromIPC(topFrameDomain),
                    .init(frameID),
                    .init(webPageProxyID)
                )
                reply(.init(wasGranted), .yes)
            }
            return
        }

        onStatisticsActor(
            requestStorageAccess: subFrameDomain,
            topFrameDomain,
            frameID,
            webPageProxyID,
            scope,
            canRequestStorageAccessWithoutUserInteraction
        ) { [self] status in
            switch status {
            case .CannotRequestAccess:
                reply(.no, .no)
            case .RequiresUserPrompt:
                guard hasNetworkSession() else {
                    reply(.no, .no)
                    return
                }
                confirmStorageAccess(
                    subFrameDomain,
                    topFrameDomain,
                    frameID,
                    webPageProxyID,
                    storageAccessQuirk
                ) { [self] userDidGrantAccess in
                    guard userDidGrantAccess else {
                        reply(.no, .yes)
                        return
                    }
                    grantStorageAccessAfterConfirm(subFrameDomain, topFrameDomain, frameID, webPageProxyID, scope) { wasGranted in
                        reply(wasGranted, .yes)
                    }
                }
            case .HasAccess:
                reply(.init(storageAccessWasGrantedValueForFrame(.init(frameID), .fromIPC(subFrameDomain))), .no)
            @unknown default:
                fatalError("WebKit.StorageAccessStatus has no other value")
            }
        }
    }

    /// Asks the user, through the UI process, whether to grant the access; `completion` runs when the prompt answers.
    private func confirmStorageAccess(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ storageAccessQuirk: WebKit.StorageAccessPromptQuirkForSwift,
        then completion: @escaping (Bool) -> Void
    ) {
        requestStorageAccessConfirm(
            .init(webPageProxyID),
            .init(frameID),
            .fromIPC(subFrameDomain),
            .fromIPC(topFrameDomain),
            consuming: storageAccessQuirk,
            StatisticsBoolReplies.shared.add(completion)
        )
    }

    private func grantStorageAccessAfterConfirm(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ frameID: IPCTypes.FrameIdentifier,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ scope: IPCTypes.StorageAccessScope,
        then completion: @escaping (IPCTypes.StorageAccessWasGranted) -> Void
    ) {
        wasGrantedStorageAccessPermissionInPage(.init(webPageProxyID), .fromIPC(topFrameDomain), .fromIPC(subFrameDomain))

        // The completion keeps the store alive until the reply, so a granted request always gets the frame's value.
        onStatisticsActor(grantStorageAccess: subFrameDomain, topFrameDomain, frameID, webPageProxyID, scope) { [self] wasGranted in
            guard wasGranted == .yes else {
                completion(wasGranted)
                return
            }
            completion(.init(storageAccessWasGrantedValueForFrame(.init(frameID), .fromIPC(subFrameDomain))))
        }
    }

    func queryStorageAccessPermission(
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier?,
        then completion: @escaping (IPCTypes.PermissionState) -> Void
    ) {
        if isEphemeral() {
            guard let webPageProxyID,
                isStorageAccessPermissionGrantedInPage(.init(webPageProxyID), .fromIPC(topFrameDomain), .fromIPC(subFrameDomain))
            else {
                completion(.prompt)
                return
            }
            completion(.granted)
            return
        }
        onStatisticsActor(storageAccessPermission: subFrameDomain, topFrameDomain, ifNoStore: .denied, then: completion)
    }

    func requestStorageAccessUnderOpener(
        _ domainInNeedOfStorageAccess: IPCTypes.RegistrableDomain,
        _ openerWebPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ openerDomain: IPCTypes.RegistrableDomain
    ) {
        if isEphemeral() {
            requestStorageAccessUnderOpenerEphemeral(
                consuming: .fromIPC(domainInNeedOfStorageAccess),
                .init(openerWebPageProxyID),
                consuming: .fromIPC(openerDomain)
            )
            return
        }
        let canRequestStorageAccessWithoutUserInteraction = canRequestStorageAccessWithoutUserInteraction(
            .fromIPC(domainInNeedOfStorageAccess),
            .fromIPC(openerDomain)
        )
        onStatisticsActor(
            .requestStorageAccessUnderOpener(
                domainInNeedOfStorageAccess,
                openerPage: openerWebPageProxyID.rawValue,
                opener: openerDomain,
                canRequestWithoutUserInteraction: canRequestStorageAccessWithoutUserInteraction
            )
        )
    }

    func setStorageAccessPermissionForTesting(
        _ granted: Bool,
        _ webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        _ topFrameDomain: IPCTypes.RegistrableDomain,
        _ subFrameDomain: IPCTypes.RegistrableDomain,
        then completion: @escaping () -> Void
    ) {
        if granted {
            wasGrantedStorageAccessPermissionInPage(.init(webPageProxyID), .fromIPC(topFrameDomain), .fromIPC(subFrameDomain))
        } else {
            wasRevokedStorageAccessPermissionInPage(.init(webPageProxyID))
        }

        if isEphemeral() {
            completion()
            return
        }

        onStatisticsActor(
            .setStorageAccessPermissionForTesting(granted: granted, top: topFrameDomain, sub: subFrameDomain),
            then: completion
        )
    }
}

/// The main-side C++ calls that answer with a `Bool` (the storage-access prompt, the cookie check without a store)
/// take an identifier, not a closure: their C++ handler completes the reply waiting here under it.
@MainActor
final class StatisticsBoolReplies {
    static let shared = StatisticsBoolReplies()

    private var lastIdentifier: UInt64 = 0
    private var replies: [UInt64: (Bool) -> Void] = [:]

    private init() {}

    isolated deinit {}

    func add(_ reply: @escaping (Bool) -> Void) -> UInt64 {
        lastIdentifier += 1
        replies[lastIdentifier] = reply
        return lastIdentifier
    }

    func take(_ identifier: UInt64) -> ((Bool) -> Void)? {
        replies.removeValue(forKey: identifier)
    }
}

@MainActor
extension WebKit.WebResourceLoadStatisticsStore {
    /// Runs and forgets the reply waiting under `identifier` in `StatisticsBoolReplies`.
    @cxx
    @implementation
    public static func completeStatisticsBoolReplyForSwift(_ identifier: UInt64, _ value: Bool) {
        StatisticsBoolReplies.shared.take(identifier)?(value)
    }
}
