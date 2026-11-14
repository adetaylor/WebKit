/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "PermissionsPolicy.h"

#include "Allowlist.h"
#include "Document.h"
#include "ElementInlines.h"
#include "HTMLIFrameElement.h"
#include "HTMLNames.h"
#include "LocalDOMWindow.h"
#include "OwnerPermissionsPolicyData.h"
#include "Quirks.h"
#include "SecurityOrigin.h"
#include "WebCore-Swift.h"
#include <wtf/TZoneMalloc.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(PermissionsPolicy);

using namespace HTMLNames;

// The Swift implementation numbers the features from the same ENABLE() groups as this enumeration.
static_assert(std::to_underlying(PermissionsPolicy::Feature::Invalid) == 18 + 3 * permissionsPolicyHasDeviceOrientationFeatures + 2 * permissionsPolicyHasWebAuthenticationFeatures + permissionsPolicyHasWebXRFeatures);

// https://w3c.github.io/webappsec-permissions-policy/#serialized-policy-directive
static std::pair<PermissionsPolicy::Feature, StringView> readFeatureIdentifier(StringView value)
{
    auto result = value.is8Bit() ? permissionsPolicyFeatureIdentifier8(value.span8()) : permissionsPolicyFeatureIdentifier16(value.span16());
    return { static_cast<PermissionsPolicy::Feature>(result.feature), value.substring(result.remainingStart, result.remainingLength) };
}

static void forEachFeature(NOESCAPE const Function<void(PermissionsPolicy::Feature)>& apply)
{
    for (uint8_t index = 0, end = static_cast<uint8_t>(PermissionsPolicy::Feature::Invalid); index < end; ++index)
        apply(static_cast<PermissionsPolicy::Feature>(index));
}

static bool isFeatureAllowedByDefaultAllowlist(PermissionsPolicy::Feature feature, const SecurityOriginData& origin, const SecurityOriginData& documentOrigin)
{
    return permissionsPolicyIsAllowedByDefault(std::to_underlying(feature), origin == documentOrigin);
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-check-permissions-policy
static bool checkPermissionsPolicy(const PermissionsPolicy& permissionsPolicy, PermissionsPolicy::Feature feature, const SecurityOriginData& origin, const SecurityOriginData& documentOrigin)
{
    if (!permissionsPolicy.inheritedPolicyValueForFeature(feature))
        return false;

    return isFeatureAllowedByDefaultAllowlist(feature, origin, documentOrigin);
}

// Similar to https://infra.spec.whatwg.org/#split-on-ascii-whitespace but only extract one token at a time.
static std::pair<StringView, StringView> splitOnAsciiWhiteSpace(StringView input)
{
    input = input.trim(isASCIIWhitespace<char16_t>);
    auto position = input.find(isASCIIWhitespace<char16_t>);
    if (position == notFound)
        return { input, StringView { } };

    return  { input.left(position), input.substring(position) };
}

// https://w3c.github.io/webappsec-permissions-policy/#declared-origin
static Ref<SecurityOrigin> declaredOrigin(const HTMLIFrameElement& iframe)
{
    Ref document = iframe.document();
    if (document->isSandboxed(SandboxFlag::Origin) || (iframe.sandboxFlags().contains(SandboxFlag::Origin)))
        return SecurityOrigin::createOpaque();

    if (iframe.hasAttributeWithoutSynchronization(srcdocAttr))
        return document->securityOrigin();

    if (iframe.hasAttributeWithoutSynchronization(srcAttr)) {
        auto url = document->encodingParseURL(iframe.getAttribute(srcAttr));
        if (url.isValid()) {
            if (url.protocolIsInHTTPFamily())
                return SecurityOrigin::create(url);
            if (RefPtr contentDocument = iframe.contentDocument())
                return contentDocument->securityOrigin();
        }
    }

    return document->securityOrigin();
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-is-feature-enabled
static bool computeFeatureEnabled(PermissionsPolicy::Feature feature, const Document& document, const SecurityOriginData& origin, PermissionsPolicy::ShouldReportViolation shouldReportViolation)
{
    bool enabled = checkPermissionsPolicy(document.permissionsPolicy(), feature, origin, document.securityOrigin().data());
    // FIXME: Spec suggests generating violation report for Reporting API but we only add log now.
    if (!enabled && shouldReportViolation == PermissionsPolicy::ShouldReportViolation::Yes) {
        if (RefPtr window = document.window())
            window->printErrorMessage(makeString("Permission policy '"_s, permissionsPolicyFeatureNameForLogging(std::to_underlying(feature)), "' check failed for document with origin '"_s, origin.toString(), "'."_s), MessageSource::Security);
    }

    return enabled;
}

static Allowlist parseAllowlist(StringView value, const SecurityOriginData& containerOrigin, const SecurityOriginData& targetOrigin)
{
    if (value.isEmpty())
        return Allowlist { targetOrigin };

    HashSet<SecurityOriginData> allowedOrigins;
    while (!value.isEmpty()) {
        auto [token, remainingValue] = splitOnAsciiWhiteSpace(value);
        if (!token.isEmpty()) {
            if (token == "*"_s)
                return Allowlist::AllowAllOrigins { };

            if (equalIgnoringASCIICase(token, "'none'"_s))
                return Allowlist { };

            if (equalIgnoringASCIICase(token, "'self'"_s))
                allowedOrigins.add(containerOrigin);
            else if (equalIgnoringASCIICase(token, "'src'"_s))
                allowedOrigins.add(targetOrigin);
            else {
                URL url { { }, token.toString() };
                if (url.isValid()) {
                    auto origin = SecurityOriginData::fromURL(url);
                    if (!origin.isOpaque())
                        allowedOrigins.add(origin);
                }
            }
        }
        value = remainingValue;
    }

    return Allowlist { WTF::move(allowedOrigins) };
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-parse-policy-directive
static PermissionsPolicy::PolicyDirective parsePolicyDirective(StringView value, const SecurityOriginData& containerOrigin, const SecurityOriginData& targetOrigin)
{
    PermissionsPolicy::PolicyDirective result;
    for (auto item : value.split(';')) {
        auto [feature, remainingItem] = readFeatureIdentifier(item);
        if (feature == PermissionsPolicy::Feature::Invalid)
            continue;

        result.add(feature, parseAllowlist(remainingItem, containerOrigin, targetOrigin));
    }

    return result;
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-process-policy-attributes
PermissionsPolicy::PolicyDirective PermissionsPolicy::processPermissionsPolicyAttribute(const HTMLIFrameElement& iframe)
{
    auto allowAttributeValue = iframe.attributeWithoutSynchronization(allowAttr);
    auto policyDirective = parsePolicyDirective(allowAttributeValue, protect(iframe.document())->securityOrigin().data(), declaredOrigin(iframe)->data());

    if (iframe.hasAttributeWithoutSynchronization(allowfullscreenAttr) || iframe.hasAttributeWithoutSynchronization(webkitallowfullscreenAttr))
        policyDirective.add(Feature::Fullscreen, Allowlist::AllowAllOrigins { });

    return policyDirective;
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-get-feature-value-for-origin
NODELETE static bool featureValueForOrigin(PermissionsPolicy::Feature feature, const PermissionsPolicy& documentPermissionsPolicy, const SecurityOriginData&)
{
    // Declared policy is not implemented yet, so origin is unused.
    return documentPermissionsPolicy.inheritedPolicyValueForFeature(feature);
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-define-inherited-policy-in-container
bool PermissionsPolicy::computeInheritedPolicyValueInContainer(Feature feature, const std::optional<OwnerPermissionsPolicyData>& ownerPermissionsPolicy, const SecurityOriginData& origin) const
{
    if (!ownerPermissionsPolicy)
        return true;

    auto documentPolicy = ownerPermissionsPolicy->documentPolicy;
    auto documentOrigin = ownerPermissionsPolicy->documentOrigin;
    if (!featureValueForOrigin(feature, documentPolicy, documentOrigin))
        return false;

    if (!featureValueForOrigin(feature, documentPolicy, origin))
        return false;

    auto containerPolicy = ownerPermissionsPolicy->containerPolicy;
    if (auto iterator = containerPolicy.find(feature); iterator != containerPolicy.end())
        return iterator->value.matches(origin);

    return isFeatureAllowedByDefaultAllowlist(feature, origin, documentOrigin);
}

bool PermissionsPolicy::inheritedPolicyValueForFeature(Feature feature) const
{
    ASSERT(feature != Feature::Invalid);

    return m_inheritedPolicy.contains(feature);
}

// https://w3c.github.io/webappsec-permissions-policy/#algo-create-for-navigable
PermissionsPolicy::PermissionsPolicy(const Document& document)
{
    auto ownerPermissionsPolicy = document.ownerPermissionsPolicy();
    forEachFeature([&](auto feature) {
        if (computeInheritedPolicyValueInContainer(feature, ownerPermissionsPolicy, document.securityOrigin().data()))
            m_inheritedPolicy.add(feature);
    });
}

// https://w3c.github.io/webappsec-permissions-policy/#empty-permissions-policy
PermissionsPolicy::PermissionsPolicy()
{
    forEachFeature([&](auto feature) {
        m_inheritedPolicy.add(feature);
    });
}

bool PermissionsPolicy::isFeatureEnabled(Feature feature, const Document& document, ShouldReportViolation shouldReportViolation)
{
    return computeFeatureEnabled(feature, document, document.securityOrigin().data(), shouldReportViolation);
}

}
