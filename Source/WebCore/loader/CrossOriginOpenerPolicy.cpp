/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#include "CrossOriginOpenerPolicy.h"

#include "ContentSecurityPolicy.h"
#include "CrossOriginEmbedderPolicy.h"
#include "FormData.h"
#include "HTTPHeaderNames.h"
#include "LocalFrame.h"
#include "NavigationRequester.h"
#include "Page.h"
#include "PingLoader.h"
#include "Report.h"
#include "ReportingClient.h"
#include "ResourceResponse.h"
#include "ScriptExecutionContext.h"
#include "SecurityPolicy.h"
#include "ViolationReportType.h"
#include "WebCore-Swift.h"

namespace WebCore {

static ASCIILiteral crossOriginOpenerPolicyValueToEffectivePolicyString(CrossOriginOpenerPolicyValue coop)
{
    switch (coop) {
    case CrossOriginOpenerPolicyValue::SameOriginAllowPopups:
        return "same-origin-allow-popups"_s;
    case CrossOriginOpenerPolicyValue::SameOrigin:
        return "same-origin"_s;
    case CrossOriginOpenerPolicyValue::SameOriginPlusCOEP:
        return "same-origin-plus-coep"_s;
    case CrossOriginOpenerPolicyValue::NoopenerAllowPopups:
        return "noopener-allow-popups"_s;
    case CrossOriginOpenerPolicyValue::UnsafeNone:
        break;
    }
    return "unsafe-none"_s;
}

// https://html.spec.whatwg.org/multipage/origin.html#coop-violation-navigation-to
static void sendViolationReportWhenNavigatingToCOOPResponse(ReportingClient& reportingClient, CrossOriginOpenerPolicy coop, COOPDisposition disposition, const URL& coopURL, const URL& previousResponseURL, const SecurityOrigin& coopOrigin, const SecurityOrigin& previousResponseOrigin, const String& referrer)
{
    auto& endpoint = coop.reportingEndpointForDisposition(disposition);
    if (endpoint.isEmpty())
        return;

    Ref report = Report::createReportFormDataForViolation("coop"_s, coopURL, reportingClient.httpUserAgent(), endpoint, [&](auto& body) {
        body.setString("disposition"_s, disposition == COOPDisposition::Reporting ? "reporting"_s : "enforce"_s);
        body.setString("effectivePolicy"_s, crossOriginOpenerPolicyValueToEffectivePolicyString(disposition == COOPDisposition::Reporting ? coop.reportOnlyValue : coop.value));
        body.setString("previousResponseURL"_s, coopOrigin.isSameOriginAs(previousResponseOrigin) ? PingLoader::sanitizeURLForReport(previousResponseURL) : String());
        body.setString("type"_s, "navigation-to-response"_s);
        body.setString("referrer"_s, referrer);
    });
    reportingClient.sendReportToEndpoints(coopURL, { }, singleElementSpan(endpoint), WTF::move(report), ViolationReportType::CrossOriginOpenerPolicy);
}

// https://html.spec.whatwg.org/multipage/origin.html#coop-violation-navigation-from
static void sendViolationReportWhenNavigatingAwayFromCOOPResponse(ReportingClient& reportingClient, CrossOriginOpenerPolicy coop, COOPDisposition disposition, const URL& coopURL, const URL& nextResponseURL, const SecurityOrigin& coopOrigin, const SecurityOrigin& nextResponseOrigin, bool isCOOPResponseNavigationSource)
{
    auto& endpoint = coop.reportingEndpointForDisposition(disposition);
    if (endpoint.isEmpty())
        return;

    Ref report = Report::createReportFormDataForViolation("coop"_s, coopURL, reportingClient.httpUserAgent(), endpoint, [&](auto& body) {
        body.setString("disposition"_s, disposition == COOPDisposition::Reporting ? "reporting"_s : "enforce"_s);
        body.setString("effectivePolicy"_s, crossOriginOpenerPolicyValueToEffectivePolicyString(disposition == COOPDisposition::Reporting ? coop.reportOnlyValue : coop.value));
        body.setString("nextResponseURL"_s, coopOrigin.isSameOriginAs(nextResponseOrigin) || isCOOPResponseNavigationSource ? PingLoader::sanitizeURLForReport(nextResponseURL) : String());
        body.setString("type"_s, "navigation-from-response"_s);
    });

    reportingClient.sendReportToEndpoints(coopURL, { }, singleElementSpan(endpoint), WTF::move(report), ViolationReportType::CrossOriginOpenerPolicy);
}

// Non-initial empty documents (about:blank) should inherit their cross-origin-opener-policy from the navigation's initiator top level document,
// if the initiator and its top level document are same-origin, or default (unsafe-none) otherwise.
// https://github.com/whatwg/html/issues/6913
CrossOriginOpenerPolicy crossOriginOpenerPolicyForEmptyDocument(const NavigationRequester& requester)
{
    if (!protect(requester.securityOrigin)->isSameOriginAs(requester.topOrigin))
        return { };
    return requester.policyContainer.crossOriginOpenerPolicy;
}

static std::pair<Ref<SecurityOrigin>, CrossOriginOpenerPolicy> computeResponseOriginAndCOOP(const ResourceResponse& response, const std::optional<NavigationRequester>& requester, ContentSecurityPolicy* responseCSP, CredentiallessSupport credentiallessSupport)
{
    // FIXME: The flags should include the frame's, and only the sandboxed origin flag should make the origin opaque.
    SandboxFlags sandboxFlags;
    if (responseCSP && !responseCSP->sandboxFlags().isEmpty())
        sandboxFlags.add(SandboxFlag::Origin);
    Ref responseOrigin = SecurityPolicy::determineOrigin(response.url(), sandboxFlags, requester ? requester->securityOrigin.ptr() : nullptr);

    if (SecurityPolicy::shouldInheritSecurityOriginFromOwner(response.url()) && requester)
        return { WTF::move(responseOrigin), crossOriginOpenerPolicyForEmptyDocument(*requester) };

    return { WTF::move(responseOrigin), obtainCrossOriginOpenerPolicy(response, credentiallessSupport) };
}

// https://html.spec.whatwg.org/multipage/origin.html#coop-enforce
static CrossOriginOpenerPolicyEnforcementResult enforceResponseCrossOriginOpenerPolicy(ReportingClient& reportingClient, const CrossOriginOpenerPolicyEnforcementResult& currentCoopEnforcementResult, const URL& responseURL, SecurityOrigin& responseOrigin, const CrossOriginOpenerPolicy& responseCOOP, const String& referrer, bool isDisplayingInitialEmptyDocument)
{
    CrossOriginOpenerPolicyEnforcementResult newCOOPEnforcementResult = {
        responseURL,
        responseOrigin,
        responseCOOP,
        true /* isCurrentContextNavigationSource */,
        currentCoopEnforcementResult.needsBrowsingContextGroupSwitch,
        currentCoopEnforcementResult.needsBrowsingContextGroupSwitchDueToReportOnly
    };

    if (coopValuesRequireBrowsingContextGroupSwitch(isDisplayingInitialEmptyDocument ? IsInitialAboutBlank::Yes : IsInitialAboutBlank::No, currentCoopEnforcementResult.crossOriginOpenerPolicy.value, currentCoopEnforcementResult.currentOrigin, responseCOOP.value, responseOrigin)) {
        newCOOPEnforcementResult.needsBrowsingContextGroupSwitch = true;
        sendViolationReportWhenNavigatingToCOOPResponse(reportingClient, responseCOOP, COOPDisposition::Enforce, responseURL, currentCoopEnforcementResult.url, responseOrigin, currentCoopEnforcementResult.currentOrigin, referrer);
        sendViolationReportWhenNavigatingAwayFromCOOPResponse(reportingClient, currentCoopEnforcementResult.crossOriginOpenerPolicy, COOPDisposition::Enforce, currentCoopEnforcementResult.url, responseURL, currentCoopEnforcementResult.currentOrigin, responseOrigin, currentCoopEnforcementResult.isCurrentContextNavigationSource);
    }

    if (crossOriginOpenerPolicyReportOnlyRequiresBrowsingContextGroupSwitch(isDisplayingInitialEmptyDocument ? IsInitialAboutBlank::Yes : IsInitialAboutBlank::No, currentCoopEnforcementResult.crossOriginOpenerPolicy.value, currentCoopEnforcementResult.crossOriginOpenerPolicy.reportOnlyValue, responseCOOP.value, responseCOOP.reportOnlyValue, currentCoopEnforcementResult.currentOrigin->isSameOriginAs(responseOrigin))) {
        newCOOPEnforcementResult.needsBrowsingContextGroupSwitchDueToReportOnly = true;
        sendViolationReportWhenNavigatingToCOOPResponse(reportingClient, responseCOOP, COOPDisposition::Reporting, responseURL, currentCoopEnforcementResult.url, responseOrigin, currentCoopEnforcementResult.currentOrigin, referrer);
        sendViolationReportWhenNavigatingAwayFromCOOPResponse(reportingClient, currentCoopEnforcementResult.crossOriginOpenerPolicy, COOPDisposition::Reporting, currentCoopEnforcementResult.url, responseURL, currentCoopEnforcementResult.currentOrigin, responseOrigin, currentCoopEnforcementResult.isCurrentContextNavigationSource);
    }

    return newCOOPEnforcementResult;
}

bool isRecognizedCrossOriginOpenerPolicyToken(StringView token)
{
    return token.is8Bit() ? isRecognizedCrossOriginOpenerPolicyToken8(token.span8()) : isRecognizedCrossOriginOpenerPolicyToken16(token.span16());
}

// https://html.spec.whatwg.org/multipage/origin.html#obtain-coop
CrossOriginOpenerPolicy obtainCrossOriginOpenerPolicy(const ResourceResponse& response, CredentiallessSupport credentiallessSupport)
{
    CrossOriginOpenerPolicy policy;
    if (!SecurityOrigin::create(response.url())->isPotentiallyTrustworthy())
        return policy;

    policy = crossOriginOpenerPolicyFromHeaders(response.httpHeaderField(HTTPHeaderName::CrossOriginOpenerPolicy), response.httpHeaderField(HTTPHeaderName::CrossOriginOpenerPolicyReportOnly));
    // The embedder policy is read only for a same-origin value, which it can make same-origin-plus-COEP.
    if (policy.value != CrossOriginOpenerPolicyValue::SameOrigin && policy.reportOnlyValue != CrossOriginOpenerPolicyValue::SameOrigin)
        return policy;
    return crossOriginOpenerPolicyWithEmbedderPolicy(WTF::move(policy), response.httpHeaderField(HTTPHeaderName::CrossOriginEmbedderPolicy), response.httpHeaderField(HTTPHeaderName::CrossOriginEmbedderPolicyReportOnly), credentiallessSupport == CredentiallessSupport::Yes);
}

CrossOriginOpenerPolicy CrossOriginOpenerPolicy::isolatedCopy() const &
{
    return { value, reportOnlyValue, reportingEndpoint.isolatedCopy(), reportOnlyReportingEndpoint.isolatedCopy() };
}

CrossOriginOpenerPolicy CrossOriginOpenerPolicy::isolatedCopy() &&
{
    return { value, reportOnlyValue, WTF::move(reportingEndpoint).isolatedCopy(), WTF::move(reportOnlyReportingEndpoint).isolatedCopy() };
}

void CrossOriginOpenerPolicy::addPolicyHeadersTo(ResourceResponse& response) const
{
    securityPoliciesSetPolicyHeaders(response, HTTPHeaderName::CrossOriginOpenerPolicy, HTTPHeaderName::CrossOriginOpenerPolicyReportOnly, crossOriginOpenerPolicyHeaderValues(value, reportingEndpoint, reportOnlyValue, reportOnlyReportingEndpoint));
}

// https://html.spec.whatwg.org/multipage/browsing-the-web.html#process-a-navigate-fetch (Step 13.5.6)
std::optional<CrossOriginOpenerPolicyEnforcementResult> doCrossOriginOpenerHandlingOfResponse(ReportingClient& reportingClient, const ResourceResponse& response, const std::optional<NavigationRequester>& requester, ContentSecurityPolicy* responseCSP, SandboxFlags effectiveSandboxFlags, const String& referrer, bool isDisplayingInitialEmptyDocument, const CrossOriginOpenerPolicyEnforcementResult& currentCoopEnforcementResult, CredentiallessSupport credentiallessSupport)
{
    auto [responseOrigin, responseCOOP] = computeResponseOriginAndCOOP(response, requester, responseCSP, credentiallessSupport);

    // https://html.spec.whatwg.org/multipage/browsing-the-web.html#process-a-navigate-fetch (Step 13.5.6.2)
    // If sandboxFlags is not empty and responseCOOP's value is not "unsafe-none", then set response to an appropriate network error and break.
    if (responseCOOP.value != CrossOriginOpenerPolicyValue::UnsafeNone && !effectiveSandboxFlags.isEmpty())
        return std::nullopt;

    return enforceResponseCrossOriginOpenerPolicy(reportingClient, currentCoopEnforcementResult, response.url(), responseOrigin, responseCOOP, referrer, isDisplayingInitialEmptyDocument);
}

CrossOriginOpenerPolicyEnforcementResult CrossOriginOpenerPolicyEnforcementResult::from(const URL& currentURL, Ref<SecurityOrigin>&& currentOrigin, const CrossOriginOpenerPolicy& crossOriginOpenerPolicy, std::optional<NavigationRequester> requester, const URL& openerURL)
{
    CrossOriginOpenerPolicyEnforcementResult result { currentURL, WTF::move(currentOrigin), crossOriginOpenerPolicy };
    result.isCurrentContextNavigationSource = requester && Ref { result.currentOrigin }->isSameOriginAs(requester->securityOrigin);
    if (SecurityPolicy::shouldInheritSecurityOriginFromOwner(currentURL) && openerURL.isValid())
        result.url = openerURL;
    return result;
}

} // namespace WebCore
