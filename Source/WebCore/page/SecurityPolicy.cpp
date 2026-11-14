/*
 * Copyright (C) 2011 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Google, Inc. ("Google") nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY GOOGLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "SecurityPolicy.h"

#include "OriginAccessEntry.h"
#include "OriginAccessPatterns.h"
#include "SecurityOrigin.h"
#include "UserContentURLPattern.h"
#include "WebCore-Swift.h"
#include <memory>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/URL.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

static SecurityPolicy::LocalLoadPolicy localLoadPolicy = SecurityPolicy::AllowLocalLoadsForLocalOnly;

using OriginAccessAllowlist = Vector<OriginAccessEntry>;
using OriginAccessMap = HashMap<SecurityOriginData, std::unique_ptr<OriginAccessAllowlist>>;

static Lock originAccessMapLock;
NODELETE static OriginAccessMap& originAccessMap() WTF_REQUIRES_LOCK(originAccessMapLock)
{
    ASSERT_WITH_SECURITY_IMPLICATION(originAccessMapLock.isHeld());
    static NeverDestroyed<OriginAccessMap> originAccessMap;
    return originAccessMap;
}

String SecurityPolicy::referrerToOriginString(const URL& referrer)
{
    String originString = SecurityOrigin::create(referrer)->toString();
    if (originString == "null"_s)
        return String();
    // A security origin is not a canonical URL as it lacks a path. Add /
    // to turn it into a canonical URL we can use as referrer.
    return makeString(originString, '/');
}

String SecurityPolicy::generateReferrerHeader(ReferrerPolicy referrerPolicy, const URL& url, const URL& referrer, const OriginAccessPatterns& patterns)
{
    ASSERT(referrer.string() == URL { referrer.string() }.strippedForUseAsReferrer().string
        || referrer.string() == SecurityOrigin::create(URL { referrer.string() })->toString());

    auto outcome = securityPolicyReferrerOutcome(referrerPolicy, referrer.isEmpty(), referrer.protocolIsInHTTPFamily(), false, false, false, false, false, false);
    bool canRequest = outcome == SecurityPolicyReferrerOutcome::NeedsCanRequest && SecurityOrigin::create(referrer)->canRequest(url, patterns);
    if (outcome == SecurityPolicyReferrerOutcome::NeedsCanRequest)
        outcome = securityPolicyReferrerOutcome(referrerPolicy, false, true, false, false, false, false, true, canRequest);
    if (outcome == SecurityPolicyReferrerOutcome::NeedsSchemes) {
        // The URL's scheme matters only for an https referrer.
        bool referrerIsHTTPS = referrer.protocolIs("https"_s);
        bool referrerIsHTTP = !referrerIsHTTPS && referrer.protocolIs("http"_s);
        bool urlIsHTTPS = referrerIsHTTPS && url.protocolIs("https"_s);
        outcome = securityPolicyReferrerOutcome(referrerPolicy, false, true, true, referrerIsHTTPS, referrerIsHTTP, urlIsHTTPS, true, canRequest);
    }
    if (outcome == SecurityPolicyReferrerOutcome::Origin)
        return referrerToOriginString(referrer);
    if (outcome == SecurityPolicyReferrerOutcome::Full)
        return referrer.string();
    return String();
}

String SecurityPolicy::generateOriginHeader(ReferrerPolicy referrerPolicy, const URL& url, const SecurityOrigin& securityOrigin, const OriginAccessPatterns& patterns)
{
    auto outcome = securityPolicyOriginHeaderOutcome(referrerPolicy, false, false, false, false, false);
    if (outcome == SecurityPolicyReferrerOutcome::NeedsCanRequest)
        outcome = securityPolicyOriginHeaderOutcome(referrerPolicy, false, false, false, true, securityOrigin.canRequest(url, patterns));
    if (outcome == SecurityPolicyReferrerOutcome::NeedsSchemes) {
        // The URL's scheme matters only for an https origin.
        bool originIsHTTPS = protocolIs(securityOrigin.protocol(), "https"_s);
        outcome = securityPolicyOriginHeaderOutcome(referrerPolicy, true, originIsHTTPS && url.protocolIs("https"_s), originIsHTTPS, false, false);
    }
    if (outcome == SecurityPolicyReferrerOutcome::None)
        return "null"_s;
    return securityOrigin.toString();
}

bool SecurityPolicy::shouldInheritSecurityOriginFromOwner(const URL& url)
{
    // Paraphrased from <https://html.spec.whatwg.org/multipage/browsers.html#origin> (8 July 2016)
    //
    // If a Document has the address "about:blank"
    //      The origin of the document is the origin it was assigned when its browsing context was created.
    // If a Document has the address "about:srcdoc"
    //      The origin of the document is the origin of its parent document.
    //
    // Note: We generalize this to invalid URLs because we treat such URLs as about:blank.
    // FIXME: We also allow some URLs like "about:BLANK". We should probably block navigation to these URLs, see rdar://problem/57966056.
    return url.isEmpty() || url.isAboutBlank() || url.isAboutSrcDoc() || equalIgnoringASCIICase(url.string(), aboutBlankURL().string());
}

// https://html.spec.whatwg.org/#determining-the-origin
Ref<SecurityOrigin> SecurityPolicy::determineOrigin(const URL& url, SandboxFlags sandboxFlags, SecurityOrigin* sourceOrigin)
{
    if (sandboxFlags.contains(SandboxFlag::Origin))
        return SecurityOrigin::createOpaque();
    if (sourceOrigin && shouldInheritSecurityOriginFromOwner(url))
        return *sourceOrigin;
    return SecurityOrigin::create(url);
}

bool SecurityPolicy::isBaseURLSchemeAllowed(const URL& url)
{
    // See <https://github.com/whatwg/html/issues/2249>.
    ASSERT(url.isValid());
    return !url.protocolIsData() && !url.protocolIsJavaScript();
}

void SecurityPolicy::setLocalLoadPolicy(LocalLoadPolicy policy)
{
    localLoadPolicy = policy;
}

bool SecurityPolicy::restrictAccessToLocal()
{
    return localLoadPolicy != SecurityPolicy::AllowLocalLoadsForAll;
}

bool SecurityPolicy::allowSubstituteDataAccessToLocal()
{
    return localLoadPolicy != SecurityPolicy::AllowLocalLoadsForLocalOnly;
}

bool SecurityPolicy::isAccessAllowed(const SecurityOrigin& activeOrigin, const SecurityOrigin& targetOrigin, const URL& targetURL, const OriginAccessPatterns& patterns)
{
    ASSERT(targetOrigin.equal(SecurityOrigin::create(targetURL)));
    {
        Locker locker { originAccessMapLock };
        if (auto* list = originAccessMap().get(activeOrigin.data())) {
            for (auto& entry : *list) {
                if (entry.matchesOrigin(targetOrigin))
                    return true;
            }
        }
    }

    return patterns.anyPatternMatches(targetURL);
}

bool SecurityPolicy::isAccessAllowed(const SecurityOrigin& activeOrigin, const URL& url, const OriginAccessPatterns& patterns)
{
    return isAccessAllowed(activeOrigin, SecurityOrigin::create(url).get(), url, patterns);
}

void SecurityPolicy::addOriginAccessAllowlistEntry(const SecurityOrigin& sourceOrigin, const String& destinationProtocol, const String& destinationDomain, bool allowDestinationSubdomains)
{
    ASSERT(!sourceOrigin.isOpaque());
    if (sourceOrigin.isOpaque())
        return;

    Locker locker { originAccessMapLock };
    auto* allowList = originAccessMap().ensure(sourceOrigin.data(), [] { return makeUnique<OriginAccessAllowlist>(); }).iterator->value.get();
    allowList->append(OriginAccessEntry(destinationProtocol, destinationDomain, allowDestinationSubdomains ? OriginAccessEntry::AllowSubdomains : OriginAccessEntry::DisallowSubdomains, OriginAccessEntry::TreatIPAddressAsIPAddress));
}

void SecurityPolicy::removeOriginAccessAllowlistEntry(const SecurityOrigin& sourceOrigin, const String& destinationProtocol, const String& destinationDomain, bool allowDestinationSubdomains)
{
    ASSERT(!sourceOrigin.isOpaque());
    if (sourceOrigin.isOpaque())
        return;

    Locker locker { originAccessMapLock };
    auto& map = originAccessMap();
    auto it = map.find(sourceOrigin.data());
    if (it == map.end())
        return;

    auto& list = *it->value;
    OriginAccessEntry originAccessEntry(destinationProtocol, destinationDomain, allowDestinationSubdomains ? OriginAccessEntry::AllowSubdomains : OriginAccessEntry::DisallowSubdomains, OriginAccessEntry::TreatIPAddressAsIPAddress);
    if (!list.removeFirst(originAccessEntry))
        return;

    if (list.isEmpty())
        map.remove(it);
}

void SecurityPolicy::resetOriginAccessAllowlists()
{
    Locker locker { originAccessMapLock };
    originAccessMap().clear();
}

} // namespace WebCore
