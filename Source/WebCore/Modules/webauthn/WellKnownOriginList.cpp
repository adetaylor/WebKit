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

#include "config.h"
#include "WellKnownOriginList.h"

#include "PublicSuffixStore.h"
#include <wtf/JSONValues.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringCommon.h>

#if ENABLE(WEB_AUTHN)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

URL wellKnownURL(StringView host, StringView path)
{
    if (host.isEmpty() || !path.startsWith('/'))
        return { };

    URL url { makeString("https://"_s, host, path) };
    if (!url.isValid() || !url.protocolIs("https"_s))
        return { };

    if (!equalIgnoringASCIICase(url.host(), host))
        return { };
    if (url.path() != path)
        return { };
    if (url.port() || url.hasCredentials() || url.hasQuery() || url.hasFragmentIdentifier())
        return { };

    return url;
}

bool isWellKnownResponseAcceptable(int httpStatusCode, StringView mimeType)
{
    return httpStatusCode == 200 && equalLettersIgnoringASCIICase(mimeType, "application/json"_s);
}

bool isWellKnownRedirectAllowed(const URL& url)
{
    return url.isValid() && url.protocolIs("https"_s);
}

bool WellKnownCandidates::parse([[clang::noescape]] std::span<const uint8_t> resource, const String& memberName, size_t maxResourceSize)
{
    if (resource.empty() || resource.size() > maxResourceSize)
        return false;

    RefPtr parsedValue = JSON::Value::parseJSON(String::fromUTF8(resource));
    if (!parsedValue)
        return false;

    RefPtr object = parsedValue->asObject();
    if (!object)
        return false;

    RefPtr member = object->getValue(memberName);
    if (!member)
        return false;

    RefPtr candidates = member->asArray();
    if (!candidates)
        return false;

    for (Ref entry : *candidates) {
        if (entry->type() != JSON::Value::Type::String)
            return false;
    }

    strings.clear();
    for (Ref entry : *candidates)
        strings.append(entry->asString());
    return true;
}

WellKnownCandidate WellKnownCandidates::candidate(size_t index) const
{
    URL url { strings[index] };
    if (!url.isValid())
        return { };

    auto label = PublicSuffixStore::singleton().topPrivatelyControlledDomainWithoutPublicSuffix(url.host());
    return { WTF::move(label), WTF::move(url) };
}

#if ENABLE(WEB_AUTHN)

WellKnownOriginListResult findOriginInWellKnownList(const SecurityOriginData& callerOrigin, std::span<const uint8_t> resource, ASCIILiteral memberName, WellKnownOriginListPolicy&& policy)
{
    return webAuthnFindOriginInWellKnownList(callerOrigin, resource, String { memberName }, policy);
}

Vector<String> parseOriginsFromWellKnownList(std::span<const uint8_t> resource, ASCIILiteral memberName, WellKnownOriginListPolicy&& policy)
{
    return webAuthnParseOriginsFromWellKnownList(resource, String { memberName }, policy);
}

#endif // ENABLE(WEB_AUTHN)

} // namespace WebCore
