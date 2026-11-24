/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(WEB_AUTHN)

#include "WellKnownResourceFetcher.h"
#include <WebCore/SecurityOriginData.h>
#include <wtf/CompletionHandler.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class WebPageProxy;

// Whether a caller is related to a relying party by https://<relying party identifier>/.well-known/webauthn is decided in RelatedOriginsValidator.swift.
namespace RelatedOriginsValidation {

struct Result {
    bool isRelated { false };
    Vector<String> origins;
};

// The name RelatedOriginsValidator.swift spells for the instantiation.
using FetchCompletionHandler = CompletionHandler<void(WellKnownFetchResult)>;

// The URL of the list, which is not valid when the relying party identifier is not a host.
URL relatedOriginsURL(const String& relyingPartyIdentifier);

// WellKnownResourceFetcher::fetch with its default limits, whose handler takes the result by value.
void fetchRelatedOriginsList(WebPageProxy&, URL, FetchCompletionHandler&&);

// wellKnownFetchStatusDescription returns an ASCIILiteral, which does not import.
void logRelatedOriginsFetchFailure(WellKnownFetchResult::Status);

} // namespace RelatedOriginsValidation

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
