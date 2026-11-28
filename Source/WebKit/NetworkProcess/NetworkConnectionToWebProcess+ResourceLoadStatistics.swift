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

@MainActor
extension WebKit.NetworkConnectionToWebProcess {
    // MARK: Login status and user interaction

    func isLoggedIn(connection: IPC.Connection, domain: IPCTypes.RegistrableDomain) async -> Bool {
        guard let store = resourceLoadStatisticsForSwift() else {
            return false
        }
        return await store.isLoggedIn(domain)
    }

    func setLoginStatus(
        connection: IPC.Connection,
        domain: IPCTypes.RegistrableDomain,
        loggedInStatus: IPCTypes.IsLoggedIn,
        lastAuthentication: IPCTypes.LoginStatus?
    ) async {
        let loginStatus: WebCore.LoginStatus?
        if let lastAuthentication {
            loginStatus = WebCore.LoginStatus(lastAuthentication)
        } else if isLoginStatusAPIRequiresWebAuthnEnabled() {
            // LoginStatus::create() with an empty username fails only for an empty domain.
            let registrableDomain = WebCore.RegistrableDomain.fromIPC(domain)
            guard !registrableDomain.isEmpty() else {
                return
            }
            loginStatus = WebCore.LoginStatus(
                registrableDomain,
                WTF.String(""),
                .HTTPStateToken,
                Self.unmanagedLoginStatusAuthenticationType(),
                WTF.WallTime.now(),
                Self.loginStatusTimeToLiveAuthentication()
            )
        } else {
            loginStatus = nil
        }
        guard let store = resourceLoadStatisticsForSwift() else {
            return
        }
        store.setLoginStatus(consuming: .fromIPC(domain), .init(loggedInStatus), consuming: loginStatus.map { .init($0) } ?? .init())
    }

    func logUserInteraction(connection: IPC.Connection, domain: IPCTypes.RegistrableDomain) {
        guard
            WebKit.NetworkProcess.singleton()
                .allowsFirstPartyForCookies(webProcessIdentifier(), .fromIPC(domain))
        else {
            assertionFailure()
            return
        }
        guard let store = resourceLoadStatisticsForSwift() else {
            return
        }
        store.logUserInteraction(domain) {}
    }

    // MARK: Storage access

    func hasStorageAccess(
        connection: IPC.Connection,
        subFrameDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        frameID: IPCTypes.FrameIdentifier,
        webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        reply: consuming NetworkConnectionToWebProcessHasStorageAccessReply
    ) {
        guard let store = resourceLoadStatisticsForSwift() else {
            hasCookiesForSwift(.fromIPC(subFrameDomain), StatisticsBoolReplies.shared.add(reply.completionHandler()))
            return
        }
        store.hasStorageAccess(subFrameDomain, topFrameDomain, frameID, webPageProxyID, then: reply.completionHandler())
    }

    func requestStorageAccess(
        connection: IPC.Connection,
        subFrameDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        frameID: IPCTypes.FrameIdentifier,
        webPageProxyID: IPCTypes.WebPageProxyIdentifier,
        scope: IPCTypes.StorageAccessScope,
        hasUserGestureOrNoUserGestureRequired: IPCTypes.HasUserGestureOrNoUserGestureRequired,
        reply: consuming NetworkConnectionToWebProcessRequestStorageAccessReply
    ) {
        guard let store = resourceLoadStatisticsForSwift() else {
            reply.send(
                .init(
                    wasGranted: .yes,
                    promptWasShown: .no,
                    scope: scope,
                    topFrameDomain: topFrameDomain,
                    subFrameDomain: subFrameDomain
                )
            )
            return
        }
        store.requestStorageAccess(
            subFrameDomain,
            topFrameDomain,
            frameID,
            webPageProxyID,
            scope,
            hasUserGestureOrNoUserGestureRequired,
            then: reply.completionHandler()
        )
    }

    func queryStorageAccessPermission(
        connection: IPC.Connection,
        subFrameDomain: IPCTypes.RegistrableDomain,
        topFrameDomain: IPCTypes.RegistrableDomain,
        webPageProxyID: IPCTypes.WebPageProxyIdentifier?,
        reply: consuming NetworkConnectionToWebProcessQueryStorageAccessPermissionReply
    ) {
        guard let store = resourceLoadStatisticsForSwift() else {
            reply.send(.denied)
            return
        }
        store.queryStorageAccessPermission(subFrameDomain, topFrameDomain, webPageProxyID, then: reply.completionHandler())
    }

    func requestStorageAccessUnderOpener(
        connection: IPC.Connection,
        domainInNeedOfStorageAccess: IPCTypes.RegistrableDomain,
        openerWebPageProxyID: IPCTypes.WebPageProxyIdentifier,
        openerDomain: IPCTypes.RegistrableDomain
    ) throws(InvalidMessage) {
        try messageCheck {
            WebKit.NetworkProcess.singleton()
                .allowsFirstPartyForCookies(
                    webProcessIdentifier(),
                    .fromIPC(domainInNeedOfStorageAccess)
                )
        }
        guard let store = resourceLoadStatisticsForSwift() else {
            return
        }
        store.requestStorageAccessUnderOpener(domainInNeedOfStorageAccess, openerWebPageProxyID, openerDomain)
    }

    func subscribeToStorageAccessPermissionChanges(
        connection: IPC.Connection,
        topFrameDomain: IPCTypes.RegistrableDomain,
        subFrameDomain: IPCTypes.RegistrableDomain
    ) {
        guard let store = resourceLoadStatisticsForSwift() else {
            return
        }
        startListeningForStorageAccessPermissionChanges(store, consuming: .fromIPC(topFrameDomain), consuming: .fromIPC(subFrameDomain))
    }

    func unsubscribeFromStorageAccessPermissionChanges(
        connection: IPC.Connection,
        topFrameDomain: IPCTypes.RegistrableDomain,
        subFrameDomain: IPCTypes.RegistrableDomain
    ) {
        guard let store = resourceLoadStatisticsForSwift() else {
            return
        }
        stopListeningForStorageAccessPermissionChanges(store, consuming: .fromIPC(topFrameDomain), consuming: .fromIPC(subFrameDomain))
    }
}

extension WebCore.LoginStatus {
    // Through the constructor LoginStatus's IPC decoder uses.
    fileprivate init(_ loginStatus: IPCTypes.LoginStatus) {
        self.init(
            .fromIPC(loginStatus.domain),
            loginStatus.username.map { WTF.String($0) } ?? WTF.String(),
            .init(loginStatus.tokenType),
            .init(loginStatus.authType),
            WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(loginStatus.loggedInTime)),
            WTF.Seconds(loginStatus.timeToLive)
        )
    }
}

extension WebCore.LoginStatus.CredentialTokenType {
    fileprivate init(_ tokenType: IPCTypes.CredentialTokenType) {
        switch tokenType {
        case .legacyCookie: self = .LegacyCookie
        case .httpStateToken: self = .HTTPStateToken
        }
    }
}

extension WebCore.LoginStatusAuthenticationType {
    fileprivate init(_ authType: IPCTypes.AuthenticationType) {
        switch authType {
        case .webAuthn: self = .WebAuthn
        case .passwordManager: self = .PasswordManager
        case .unmanaged: self = WebKit.NetworkConnectionToWebProcess.unmanagedLoginStatusAuthenticationType()
        }
    }
}

extension WebCore.IsLoggedIn {
    fileprivate init(_ isLoggedIn: IPCTypes.IsLoggedIn) {
        switch isLoggedIn {
        case .loggedOut: self = .LoggedOut
        case .loggedIn: self = .LoggedIn
        }
    }
}
