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

#if ENABLE_WEB_AUTHN

internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

private let webAuthnOriginsMember = "origins"

// The related origins fetch's handler.
extension WebKit.RelatedOriginsValidation.FetchCompletionHandler: CxxCompletionHandler {
    typealias Argument = WebKit.WellKnownFetchResult
}

extension WebKit.RelatedOriginsValidation {
    /// Whether `callerOrigin` is related to `relyingPartyIdentifier` by its list, and the origins the list names.
    ///
    /// Not related, with no origins, when the identifier is not a host or the list cannot be fetched; nil when
    /// `livePage` finds no page to fetch through. `livePage` runs once, as the fetch starts: nothing here holds the page
    /// across the wait for the list.
    @MainActor
    static func validate(
        _ livePage: () -> WebKit.WebPageProxy?,
        _ callerOrigin: WebCore.SecurityOriginData,
        _ relyingPartyIdentifier: WTF.String
    ) async -> Result? {
        await validate(livePage, [callerOrigin], relyingPartyIdentifier)
    }

    /// Fetches the list once and checks every origin against it: related only if all of them are listed, and not when
    /// there are none.
    @MainActor
    static func validate(
        _ livePage: () -> WebKit.WebPageProxy?,
        _ originsToCheck: [WebCore.SecurityOriginData],
        _ relyingPartyIdentifier: WTF.String
    ) async -> Result? {
        let url = relatedOriginsURL(relyingPartyIdentifier)
        guard url.isValid() else {
            WebKit.LogChannel.WebAuthn().releaseLog.error("Related origins: relying party identifier is not a host.")
            return Result()
        }

        let fetchedList: WebKit.WellKnownFetchResult? = await withCheckedContinuation { continuation in
            guard let page = livePage() else {
                continuation.resume(returning: nil)
                return
            }
            fetchRelatedOriginsList(
                page,
                url,
                consuming: .init { (result: WebKit.WellKnownFetchResult) in
                    continuation.resume(returning: result)
                }
            )
        }
        guard let fetched = fetchedList else {
            return nil
        }
        guard fetched.succeeded() else {
            logRelatedOriginsFetchFailure(fetched.status)
            return Result()
        }

        let body = makeByteArray(fetched.body)
        let list = body.span
        let memberName = makeWTFString(webAuthnOriginsMember)
        let policy = WebCore.WellKnownOriginListPolicy()
        var result = Result()
        result.origins = wellKnownListedOrigins(list, memberName, policy)
        var allFound = !originsToCheck.isEmpty
        for originToCheck in originsToCheck {
            let found = wellKnownFindOrigin(originToCheck, list, memberName, policy)
            if found == .Malformed {
                WebKit.LogChannel.WebAuthn().releaseLog.error("Related origins: well-known resource is malformed.")
            }
            if found != .Found {
                allFound = false
                break
            }
        }
        result.isRelated = allFound
        return result
    }
}

#endif // ENABLE_WEB_AUTHN
