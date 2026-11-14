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
#include "CrossOriginEmbedderPolicy.h"

#include "COEPInheritenceViolationReportBody.h"
#include "CORPViolationReportBody.h"
#include "FrameLoader.h"
#include "HTTPHeaderNames.h"
#include "JSFetchRequestDestination.h"
#include "LocalFrame.h"
#include "PingLoader.h"
#include "Report.h"
#include "ReportingClient.h"
#include "ResourceResponse.h"
#include "ScriptExecutionContext.h"
#include "Settings.h"
#include "ViolationReportType.h"
#include "WebCore-Swift.h"
#include <wtf/persistence/PersistentCoders.h>

namespace WebCore {

CredentiallessSupport credentiallessSupport(bool crossOriginEmbedderPolicyCredentiallessEnabled)
{
    // FIXME: Omitting credentials doesn't protect resources that rely on their network position, so this has to
    // require Local Network Access or Opaque Response Blocking before CrossOriginEmbedderPolicyCredentiallessEnabled can become stable.
    return crossOriginEmbedderPolicyCredentiallessEnabled ? CredentiallessSupport::Yes : CredentiallessSupport::No;
}

CredentiallessSupport credentiallessSupport(const SettingsValues& settings)
{
    return credentiallessSupport(settings.crossOriginEmbedderPolicyCredentiallessEnabled);
}

bool isRecognizedCrossOriginEmbedderPolicyToken(StringView token, CredentiallessSupport credentiallessSupport)
{
    bool supportsCredentialless = credentiallessSupport == CredentiallessSupport::Yes;
    return token.is8Bit() ? isRecognizedCrossOriginEmbedderPolicyToken8(token.span8(), supportsCredentialless) : isRecognizedCrossOriginEmbedderPolicyToken16(token.span16(), supportsCredentialless);
}

bool isUnsupportedCrossOriginEmbedderPolicyToken(StringView token, CredentiallessSupport credentiallessSupport)
{
    bool supportsCredentialless = credentiallessSupport == CredentiallessSupport::Yes;
    return token.is8Bit() ? isUnsupportedCrossOriginEmbedderPolicyToken8(token.span8(), supportsCredentialless) : isUnsupportedCrossOriginEmbedderPolicyToken16(token.span16(), supportsCredentialless);
}

// https://html.spec.whatwg.org/multipage/origin.html#obtain-an-embedder-policy
CrossOriginEmbedderPolicy obtainCrossOriginEmbedderPolicy(const ResourceResponse& response, IsSecureContext isSecureContext, CredentiallessSupport credentiallessSupport, const ScriptExecutionContext* context)
{
    CrossOriginEmbedderPolicy policy;
    if (context && !context->settingsValues().crossOriginEmbedderPolicyEnabled)
        return policy;
    if (isSecureContext == IsSecureContext::No)
        return policy;

    return crossOriginEmbedderPolicyFromHeaders(response.httpHeaderField(HTTPHeaderName::CrossOriginEmbedderPolicy), response.httpHeaderField(HTTPHeaderName::CrossOriginEmbedderPolicyReportOnly), credentiallessSupport == CredentiallessSupport::Yes);
}

CrossOriginEmbedderPolicy CrossOriginEmbedderPolicy::isolatedCopy() const &
{
    return {
        value,
        reportOnlyValue,
        reportingEndpoint.isolatedCopy(),
        reportOnlyReportingEndpoint.isolatedCopy()
    };
}

CrossOriginEmbedderPolicy CrossOriginEmbedderPolicy::isolatedCopy() &&
{
    return {
        value,
        reportOnlyValue,
        WTF::move(reportingEndpoint).isolatedCopy(),
        WTF::move(reportOnlyReportingEndpoint).isolatedCopy()
    };
}

void CrossOriginEmbedderPolicy::addPolicyHeadersTo(ResourceResponse& response) const
{
    securityPoliciesSetPolicyHeaders(response, HTTPHeaderName::CrossOriginEmbedderPolicy, HTTPHeaderName::CrossOriginEmbedderPolicyReportOnly, crossOriginEmbedderPolicyHeaderValues(value, reportingEndpoint, reportOnlyValue, reportOnlyReportingEndpoint));
}

// https://html.spec.whatwg.org/multipage/origin.html#queue-a-cross-origin-embedder-policy-inheritance-violation
void sendCOEPInheritenceViolation(ReportingClient& reportingClient, const URL& embedderURL, const String& endpoint, COEPDisposition disposition, const String& type, const URL& blockedURL)
{
    Ref reportBody = COEPInheritenceViolationReportBody::create(disposition, blockedURL, AtomString { type });
    Ref report = Report::create("coep"_s, embedderURL.string(), WTF::move(reportBody));
    reportingClient.notifyReportObservers(WTF::move(report));

    if (endpoint.isEmpty())
        return;

    Ref reportFormData = Report::createReportFormDataForViolation("coep"_s, embedderURL, reportingClient.httpUserAgent(), endpoint, [&](auto& body) {
        body.setString("disposition"_s, disposition == COEPDisposition::Reporting ? "reporting"_s : "enforce"_s);
        body.setString("type"_s, type);
        body.setString("blockedURL"_s, PingLoader::sanitizeURLForReport(blockedURL));
    });
    reportingClient.sendReportToEndpoints(embedderURL, { }, singleElementSpan(endpoint), WTF::move(reportFormData), ViolationReportType::COEPInheritenceViolation);
}

// https://fetch.spec.whatwg.org/#queue-a-cross-origin-embedder-policy-corp-violation-report
void sendCOEPCORPViolation(ReportingClient& reportingClient, const URL& embedderURL, const String& endpoint, COEPDisposition disposition, FetchOptions::Destination destination, const URL& blockedURL)
{
    // https://fetch.spec.whatwg.org/#serialize-a-response-url-for-reporting
    URL serializedBlockedURL = blockedURL;
    serializedBlockedURL.removeCredentials();
    serializedBlockedURL.removeFragmentIdentifier();

    Ref reportBody = CORPViolationReportBody::create(disposition, serializedBlockedURL, destination);
    Ref report = Report::create("coep"_s, embedderURL.string(), WTF::move(reportBody));
    reportingClient.notifyReportObservers(WTF::move(report));

    if (endpoint.isEmpty())
        return;

    Ref reportFormData = Report::createReportFormDataForViolation("coep"_s, embedderURL, reportingClient.httpUserAgent(), endpoint, [&](auto& body) {
        body.setString("disposition"_s, disposition == COEPDisposition::Reporting ? "reporting"_s : "enforce"_s);
        body.setString("type"_s, "corp"_s);
        body.setString("blockedURL"_s, serializedBlockedURL.string());
        body.setString("destination"_s, convertEnumerationToString(destination));
    });
    reportingClient.sendReportToEndpoints(embedderURL, { }, singleElementSpan(endpoint), WTF::move(reportFormData), ViolationReportType::CORPViolation);
}

void CrossOriginEmbedderPolicy::encode(WTF::Persistence::Encoder& encoder) const
{
    encoder << value << reportingEndpoint << reportOnlyValue << reportOnlyReportingEndpoint;
}

std::optional<CrossOriginEmbedderPolicy> CrossOriginEmbedderPolicy::decode(WTF::Persistence::Decoder& decoder)
{
    std::optional<CrossOriginEmbedderPolicyValue> value;
    decoder >> value;
    if (!value)
        return std::nullopt;

    std::optional<String> reportingEndpoint;
    decoder >> reportingEndpoint;
    if (!reportingEndpoint)
        return std::nullopt;

    std::optional<CrossOriginEmbedderPolicyValue> reportOnlyValue;
    decoder >> reportOnlyValue;
    if (!reportOnlyValue)
        return std::nullopt;

    std::optional<String> reportOnlyReportingEndpoint;
    decoder >> reportOnlyReportingEndpoint;
    if (!reportOnlyReportingEndpoint)
        return std::nullopt;

    return { {
        *value,
        *reportOnlyValue,
        WTF::move(*reportingEndpoint),
        WTF::move(*reportOnlyReportingEndpoint)
    } };
}

} // namespace WebCore
