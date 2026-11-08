/*
 * Copyright (C) 2011 Google, Inc. All rights reserved.
 * Copyright (C) 2013-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY GOOGLE INC. ``AS IS'' AND ANY
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
#include "ContentSecurityPolicy.h"

#include "CSPViolationReportBody.h"
#include "ContentSecurityPolicyClient.h"
#include "ContentSecurityPolicyDirective.h"
#include "ContentSecurityPolicyDirectiveList.h"
#include "ContentSecurityPolicyDirectiveNames.h"
#include "ContentSecurityPolicyHash.h"
#include "ContentSecurityPolicySource.h"
#include "ContentSecurityPolicySourceList.h"
#include "DOMStringList.h"
#include "DOMWrapperWorld.h"
#include "DeprecationReportBody.h"
#include "DocumentLoader.h"
#include "DocumentPage.h"
#include "EventNames.h"
#include "FormData.h"
#include "FrameDestructionObserverInlines.h"
#include "FrameLoader.h"
#include "InspectorInstrumentation.h"
#include "JSExecState.h"
#include "JSWindowProxy.h"
#include "LegacySchemeRegistry.h"
#include "LocalFrame.h"
#include "LocalFrameLoaderClient.h"
#include "OriginAccessPatterns.h"
#include "PingLoader.h"
#include "Report.h"
#include "ReportingClient.h"
#include "ResourceRequest.h"
#include "SecurityOrigin.h"
#include "SecurityPolicyViolationEvent.h"
#include "Settings.h"
#include "SubresourceIntegrity.h"
#include "ViolationReportType.h"
#include "WorkerGlobalScope.h"
#if USE_SWIFT_CONTENT_SECURITY_POLICY
#include "ContentSecurityPolicySwift.h"
#include "DocumentSecurityOrigin.h"
#include "LocalFrameInlines.h"
#include "PublicSuffixStore.h"
#include "WebCore-Swift.h"
#endif
#include <JavaScriptCore/HeapCellInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include <JavaScriptCore/ScriptCallStackFactory.h>
#include <algorithm>
#include <pal/crypto/CryptoDigest.h>
#include <pal/text/TextEncoding.h>
#include <wtf/JSONValues.h>
#include <wtf/SetForScope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringParsingBuffer.h>
#include <wtf/text/TextPosition.h>

namespace WebCore {
using namespace Inspector;

WTF_MAKE_TZONE_ALLOCATED_IMPL(ContentSecurityPolicy);

#if USE_SWIFT_CONTENT_SECURITY_POLICY
static_assert(!static_cast<uint8_t>(AllowTrustedTypePolicy::Allowed) && static_cast<uint8_t>(AllowTrustedTypePolicy::DisallowedName) == 1 && static_cast<uint8_t>(AllowTrustedTypePolicy::DisallowedDuplicateName) == 2);
static_assert(!static_cast<uint8_t>(ContentSecurityPolicyHeaderType::Report) && static_cast<uint8_t>(ContentSecurityPolicyHeaderType::Enforce) == 1);
static_assert(!static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::API) && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::HTTPEquivMeta) == 1 && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::HTTPHeader) == 2 && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::Inherited) == 3 && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::InheritedForPluginDocument) == 4);
static_assert(!static_cast<uint8_t>(ContentSecurityPolicyModeForExtension::None) && static_cast<uint8_t>(ContentSecurityPolicyModeForExtension::ManifestV2) == 1 && static_cast<uint8_t>(ContentSecurityPolicyModeForExtension::ManifestV3) == 2);
static_assert(static_cast<uint8_t>(ResourceCryptographicDigest::Algorithm::SHA256) == 1 && static_cast<uint8_t>(ResourceCryptographicDigest::Algorithm::SHA384) == 2 && static_cast<uint8_t>(ResourceCryptographicDigest::Algorithm::SHA512) == 4);
static_assert(ResourceCryptographicDigest::maximumDigestLength == sizeof(ContentSecurityPolicyDigest::words));
#if !ENABLE(APPLICATION_MANIFEST)
#error "USE_SWIFT_CONTENT_SECURITY_POLICY requires ENABLE(APPLICATION_MANIFEST): the Swift directive names include manifest-src"
#endif

struct ContentSecurityPolicy::SwiftDirectives {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(SwiftDirectives);
    ContentSecurityPolicyDirectiveListVector directives;
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ContentSecurityPolicy::SwiftDirectives);

// What reportViolation() reads of the policy that was violated.
struct ContentSecurityPolicy::SwiftViolatedPolicy {
    const String& header() const LIFETIME_BOUND { return m_header; }
    bool isReportOnly() const { return m_isReportOnly; }
    bool shouldReportSample(const String&) const { return m_shouldReportSample; }
    const Vector<String>& reportToTokens() const LIFETIME_BOUND { return m_reportToTokens; }
    const Vector<String>& reportURIs() const LIFETIME_BOUND { return m_reportURIs; }

    String m_header;
    bool m_isReportOnly;
    bool m_shouldReportSample;
    Vector<String> m_reportToTokens;
    Vector<String> m_reportURIs;
};

static thread_local struct ContentSecurityPolicySwiftScope* currentContentSecurityPolicySwiftScope;

// The policy a call into ContentSecurityPolicyDirectiveListVector is for, and the arguments its callbacks need. It is the
// calling thread's current scope while it lives, and keeps the policy and its ContentSecurityPolicyDirectiveListVector alive.
struct ContentSecurityPolicySwiftScope {
    CheckedRef<const ContentSecurityPolicy> policy;
    String blockedURL { };
    URL consoleURL { };
    String sourceURL { };
    StringView sourceContent { };
    std::optional<TextPosition> sourcePosition { };
    URL preRedirectURL { };
    JSC::JSGlobalObject* globalObject { nullptr };
    RefPtr<Element> element { };
    Vector<ResourceCryptographicDigest> subresourceIntegrityDigests { };
    // The ancestors of a frame-ancestors check, which outlive the scope: the frame's, or the given origins.
    RefPtr<const LocalFrame> frame { };
    const Vector<Ref<SecurityOrigin>>* ancestorOrigins { nullptr };
    SandboxFlags sandboxFlags { };
    ContentSecurityPolicyDirectiveListVector directives { policy->m_swiftDirectives->directives };
    SetForScope<ContentSecurityPolicySwiftScope*> activation { currentContentSecurityPolicySwiftScope, this };
};

static ContentSecurityPolicySwiftScope& contentSecurityPolicySwiftScope()
{
    RELEASE_ASSERT(currentContentSecurityPolicySwiftScope);
    return *currentContentSecurityPolicySwiftScope;
}

static ContentSecurityPolicyURLBounds contentSecurityPolicyURLBounds(const URL& url)
{
    auto port = url.port();
    auto defaultPort = WTF::defaultPortForProtocol(url.protocol());
    return { url.string().length(), url.string().is8Bit(), url.protocol().length(), url.hostStart(), url.hostEnd(), url.pathStart(), url.pathEnd(), port.value_or(0), !!port, url.isValid(), url.protocolIsInHTTPFamily(), defaultPort.value_or(0), !!defaultPort };
}

static ContentSecurityPolicyDigest contentSecurityPolicyDigest(const ResourceCryptographicDigest& digest)
{
    ContentSecurityPolicyDigest result { static_cast<uint8_t>(digest.algorithm), 0xFF, { } };
    if (digest.value.size() > ResourceCryptographicDigest::maximumDigestLength)
        return result;
    result.length = static_cast<uint8_t>(digest.value.size());
    memcpySpan(asMutableByteSpan(result.words), digest.value.span());
    return result;
}

static ContentSecurityPolicyContentHashes contentSecurityPolicyContentHashes(const Vector<ContentSecurityPolicyHash>& hashes)
{
    ContentSecurityPolicyContentHashes result { };
    for (auto& hash : hashes)
        std::span { result.digests }[result.count++] = contentSecurityPolicyDigest(hash);
    return result;
}
#endif

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
static String consoleMessageForViolation(const ContentSecurityPolicyDirective& violatedDirective, const URL& blockedURL, ASCIILiteral prefix, ASCIILiteral subject = "it"_s)
{
    bool isDefaultSrc = violatedDirective.isDefaultSrc();
    String name = violatedDirective.nameForReporting();
    if (violatedDirective.nameForReporting().startsWith(StringView { ContentSecurityPolicyDirectiveNames::scriptSrc }))
        name = ContentSecurityPolicyDirectiveNames::scriptSrc;
    else if (violatedDirective.nameForReporting().startsWith(StringView { ContentSecurityPolicyDirectiveNames::styleSrc }))
        name = ContentSecurityPolicyDirectiveNames::styleSrc;

    return makeString(violatedDirective.directiveList().isReportOnly() ? "[Report Only] "_s : ""_s,
        prefix, blockedURL.isEmpty() ? ""_s : " "_s, blockedURL.stringCenterEllipsizedToLength(), " because "_s, subject,
        isDefaultSrc ? " appears in neither the "_s : " does not appear in the "_s,
        name,
        isDefaultSrc ? " directive nor the default-src directive of the Content Security Policy."_s : " directive of the Content Security Policy."_s);
}
#endif

ContentSecurityPolicy::ContentSecurityPolicy(URL&& protectedURL, ContentSecurityPolicyClient* client, ReportingClient* reportingClient)
    : m_client { client }
    , m_reportingClient { reportingClient }
    , m_protectedURL { WTF::move(protectedURL) }
#if USE_SWIFT_CONTENT_SECURITY_POLICY
    , m_swiftDirectives { makeUnique<SwiftDirectives>(ContentSecurityPolicyDirectiveListVector::init()) }
#endif
{
    updateSourceSelf(SecurityOrigin::create(m_protectedURL).get());
}

std::unique_ptr<ContentSecurityPolicy> ContentSecurityPolicy::create(URL&& protectedURL, ContentSecurityPolicyClient* client, ReportingClient* reportingClient)
{
    return makeUnique<ContentSecurityPolicy>(WTF::move(protectedURL), client, reportingClient);
}

ContentSecurityPolicy::ContentSecurityPolicy(URL&& protectedURL, ScriptExecutionContext& scriptExecutionContext)
    : m_scriptExecutionContext(scriptExecutionContext)
    , m_reportingClient { scriptExecutionContext.reportingClient() }
    , m_protectedURL { WTF::move(protectedURL) }
#if USE_SWIFT_CONTENT_SECURITY_POLICY
    , m_swiftDirectives { makeUnique<SwiftDirectives>(ContentSecurityPolicyDirectiveListVector::init()) }
#endif
{
    ASSERT(scriptExecutionContext.securityOrigin());
    Ref securityOrigin = *scriptExecutionContext.securityOrigin();
    // CSP3 2.2.2: a policy's self-origin is the response URL's origin. Apply when the runtime
    // origin is opaque and the URL is http(s); local schemes inherit via Document::initSecurityContext.
    bool hasOpaqueOriginWithResponseURL = securityOrigin->isOpaque() && m_protectedURL.protocolIsInHTTPFamily();
    if (hasOpaqueOriginWithResponseURL)
        updateSourceSelf(SecurityOrigin::create(m_protectedURL).get());
    else
        updateSourceSelf(securityOrigin);
    // FIXME: handle the non-document case.
    if (auto* document = dynamicDowncast<Document>(scriptExecutionContext)) {
        RefPtr page = document->page();
        bool shouldApplyExtensionContentSecurityPolicy = LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(securityOrigin->protocol()) || document->settings().contentSecurityPolicyExtensionModeAppliesToAllSchemesForTesting();
        if (page && shouldApplyExtensionContentSecurityPolicy)
            m_contentSecurityPolicyModeForExtension = page->contentSecurityPolicyModeForExtension();
    }
}

ContentSecurityPolicy::~ContentSecurityPolicy() = default;

void ContentSecurityPolicy::copyStateFrom(const ContentSecurityPolicy* other, ShouldMakeIsolatedCopy shouldMakeIsolatedCopy)
{
    if (m_hasAPIPolicy)
        return;
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    ASSERT(m_policies.isEmpty());
#else
    ASSERT(m_swiftDirectives->directives.isEmpty());
#endif
    m_contentSecurityPolicyModeForExtension = other->m_contentSecurityPolicyModeForExtension;
    m_sandboxFlags = other->m_sandboxFlags;
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    for (auto& policy : other->m_policies)
        didReceiveHeader(policy->header(), policy->headerType(), ContentSecurityPolicy::PolicyFrom::Inherited, String { });
#else
    for (unsigned i = 0, count = other->m_swiftDirectives->directives.policyCount(); i < count; ++i)
        didReceiveHeader(other->m_swiftDirectives->directives.policyHeader(i), static_cast<ContentSecurityPolicyHeaderType>(other->m_swiftDirectives->directives.policyHeaderType(i)), ContentSecurityPolicy::PolicyFrom::Inherited, String { });
#endif
    m_referrer = shouldMakeIsolatedCopy == ShouldMakeIsolatedCopy::Yes ? other->m_referrer.isolatedCopy() : other->m_referrer;
    m_httpStatusCode = other->m_httpStatusCode;
}

void ContentSecurityPolicy::inheritHeadersFrom(const ContentSecurityPolicyResponseHeaders& headers)
{
    if (m_hasAPIPolicy)
        return;
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    ASSERT(m_policies.isEmpty());
#else
    ASSERT(m_swiftDirectives->directives.isEmpty());
#endif
    for (auto& [header, headerType] : headers.m_headers)
        didReceiveHeader(header, headerType, PolicyFrom::Inherited, String { });
}

void ContentSecurityPolicy::createPolicyForPluginDocumentFrom(const ContentSecurityPolicy& other)
{
    if (m_hasAPIPolicy)
        return;
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    ASSERT(m_policies.isEmpty());
    for (auto& policy : other.m_policies)
        didReceiveHeader(policy->header(), policy->headerType(), ContentSecurityPolicy::PolicyFrom::InheritedForPluginDocument, String { });
#else
    ASSERT(m_swiftDirectives->directives.isEmpty());
    for (unsigned i = 0, count = other.m_swiftDirectives->directives.policyCount(); i < count; ++i)
        didReceiveHeader(other.m_swiftDirectives->directives.policyHeader(i), static_cast<ContentSecurityPolicyHeaderType>(other.m_swiftDirectives->directives.policyHeaderType(i)), ContentSecurityPolicy::PolicyFrom::InheritedForPluginDocument, String { });
#endif
    m_referrer = other.m_referrer;
    m_httpStatusCode = other.m_httpStatusCode;
}

void ContentSecurityPolicy::copyUpgradeInsecureRequestStateFrom(const ContentSecurityPolicy& other, ShouldMakeIsolatedCopy shouldMakeIsolatedCopy)
{
    m_upgradeInsecureRequests = other.m_upgradeInsecureRequests;
    m_insecureNavigationRequestsToUpgrade = shouldMakeIsolatedCopy == ShouldMakeIsolatedCopy::Yes ? crossThreadCopy(other.m_insecureNavigationRequestsToUpgrade) : other.m_insecureNavigationRequestsToUpgrade;
}

void ContentSecurityPolicy::didCreateWindowProxy(JSWindowProxy& windowProxy) const
{
    auto* window = windowProxy.window();
    ASSERT(window);
    ASSERT(window->scriptExecutionContext());
    ASSERT(window->scriptExecutionContext()->contentSecurityPolicy() == this);
    if (!windowProxy.world().isNormal()) {
        window->setEvalEnabled(true);
        return;
    }
    window->setEvalEnabled(m_lastPolicyEvalDisabledErrorMessage.isNull(), m_lastPolicyEvalDisabledErrorMessage);
    window->setWebAssemblyEnabled(m_lastPolicyWebAssemblyDisabledErrorMessage.isNull(), m_lastPolicyWebAssemblyDisabledErrorMessage);

    auto requiresTrustedTypesForScript = requireTrustedTypesForSinkGroup("script"_s);
    auto requiresTrustedTypesForScriptEnforced = requireTrustedTypesForSinkGroup("script"_s, IncludeReportOnlyPolicies::No);

    if (requiresTrustedTypesForScript && requiresTrustedTypesForScriptEnforced && m_trustedEvalEnabled)
        window->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::EnforcedWithEvalEnabled);
    else if (requiresTrustedTypesForScript && requiresTrustedTypesForScriptEnforced)
        window->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::Enforced);
    else if (requiresTrustedTypesForScript)
        window->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::ReportOnly);
    else
        window->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::None);
}

ContentSecurityPolicyResponseHeaders ContentSecurityPolicy::responseHeaders() const
{
    if (!m_cachedResponseHeaders) {
        auto makeValidHTTPHeaderIfNeeded = [isHeaderDelivered = m_isHeaderDelivered](auto& header) {
            // If coming from an existing HTTP header it should be valid already.
            if (isHeaderDelivered)
                return header;

            // Newlines are valid in http-equiv but not in HTTP header value.
            auto returnValue = makeStringByReplacingAll(header, '\n', ""_s);
            returnValue = makeStringByReplacingAll(returnValue, '\r', ""_s);
            return returnValue;
        };

        ContentSecurityPolicyResponseHeaders result;
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
        result.m_headers = m_policies.map([&makeValidHTTPHeaderIfNeeded](auto& policy) {
            return std::pair { makeValidHTTPHeaderIfNeeded(policy->header()), policy->headerType() };
        });
#else
        for (unsigned i = 0, count = m_swiftDirectives->directives.policyCount(); i < count; ++i) {
            auto header = m_swiftDirectives->directives.policyHeader(i);
            result.m_headers.append({ makeValidHTTPHeaderIfNeeded(header), static_cast<ContentSecurityPolicyHeaderType>(m_swiftDirectives->directives.policyHeaderType(i)) });
        }
#endif
        result.m_httpStatusCode = m_httpStatusCode;
        m_cachedResponseHeaders = WTF::move(result);
    }
    return *m_cachedResponseHeaders;
}

void ContentSecurityPolicy::didReceiveHeaders(const ContentSecurityPolicyResponseHeaders& headers, String&& referrer, ReportParsingErrors reportParsingErrors)
{
    SetForScope isReportingEnabled(m_isReportingEnabled, reportParsingErrors == ReportParsingErrors::Yes);
    for (auto& header : headers.m_headers)
        didReceiveHeader(header.first, header.second, ContentSecurityPolicy::PolicyFrom::HTTPHeader, String { });
    m_referrer = WTF::move(referrer);
    m_httpStatusCode = headers.m_httpStatusCode;
}

void ContentSecurityPolicy::didReceiveHeaders(const ContentSecurityPolicy& other, ReportParsingErrors reportParsingErrors)
{
    SetForScope isReportingEnabled(m_isReportingEnabled, reportParsingErrors == ReportParsingErrors::Yes);
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    for (auto& policy : other.m_policies)
        didReceiveHeader(policy->header(), policy->headerType(), ContentSecurityPolicy::PolicyFrom::HTTPHeader, String { });
#else
    for (unsigned i = 0, count = other.m_swiftDirectives->directives.policyCount(); i < count; ++i)
        didReceiveHeader(other.m_swiftDirectives->directives.policyHeader(i), static_cast<ContentSecurityPolicyHeaderType>(other.m_swiftDirectives->directives.policyHeaderType(i)), ContentSecurityPolicy::PolicyFrom::HTTPHeader, String { });
#endif
    m_referrer = other.m_referrer;
    m_httpStatusCode = other.m_httpStatusCode;
    m_upgradeInsecureRequests = other.m_upgradeInsecureRequests;
    m_insecureNavigationRequestsToUpgrade.addAll(other.m_insecureNavigationRequestsToUpgrade);
}

void ContentSecurityPolicy::didReceiveHeader(const String& header, ContentSecurityPolicyHeaderType type, ContentSecurityPolicy::PolicyFrom policyFrom, String&& referrer, int httpStatusCode)
{
    if (m_hasAPIPolicy)
        return;

    m_referrer = WTF::move(referrer);
    m_httpStatusCode = httpStatusCode;

    if (policyFrom == PolicyFrom::API) {
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
        ASSERT(m_policies.isEmpty());
#else
        ASSERT(m_swiftDirectives->directives.isEmpty());
#endif
        m_hasAPIPolicy = true;
    } else if (policyFrom == PolicyFrom::HTTPHeader)
        m_isHeaderDelivered = true;

    m_cachedResponseHeaders = std::nullopt;

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    // RFC2616, section 4.2 specifies that headers appearing multiple times can
    // be combined with a comma. Walk the header string, and parse each comma
    // separated chunk as a separate header.
    readCharactersForParsing(header, [&](auto buffer) {
        skipWhile<isASCIIWhitespace>(buffer);
        auto begin = buffer.position();

        while (buffer.hasCharactersRemaining()) {
            skipUntil(buffer, ',');

            // header1,header2 OR header1
            //        ^                  ^
            m_policies.append(ContentSecurityPolicyDirectiveList::create(*this, String({ begin, buffer.position() }), type, policyFrom));

            // Skip the comma, and begin the next header from the current position.
            ASSERT(buffer.atEnd() || *buffer == ',');
            skipExactly(buffer, ',');
            begin = buffer.position();
        }
    });
#else
    ContentSecurityPolicySwiftScope scope { .policy = *this };
    for (auto upgrades = scope.directives.didReceiveHeader(header, static_cast<uint8_t>(type), static_cast<uint8_t>(policyFrom), static_cast<uint8_t>(m_contentSecurityPolicyModeForExtension)); upgrades; --upgrades)
        setUpgradeInsecureRequests(true);
    enforceSandboxFlags(scope.sandboxFlags);
    addHashAlgorithmsForInlineScripts(OptionSet<ContentSecurityPolicyHashAlgorithm>::fromRaw(scope.directives.hashAlgorithmsForInlineScripts()));
    addHashAlgorithmsForInlineStylesheets(OptionSet<ContentSecurityPolicyHashAlgorithm>::fromRaw(scope.directives.hashAlgorithmsForInlineStylesheets()));
#endif
    

    if (m_scriptExecutionContext)
        applyPolicyToScriptExecutionContext();
}

void ContentSecurityPolicy::updateSourceSelf(const SecurityOrigin& securityOrigin)
{
    m_selfSourceProtocol = securityOrigin.protocol().convertToASCIILowercase();
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    m_selfSource = makeUnique<ContentSecurityPolicySource>(*this, m_selfSourceProtocol, securityOrigin.host(), securityOrigin.port(), emptyString(), false, false, IsSelfSource::Yes);
#else
    m_selfOrigin = { m_selfSourceProtocol, securityOrigin.host(), securityOrigin.port() };
    m_swiftDirectives->directives.updateSourceSelf(m_selfSourceProtocol, securityOrigin.host(), securityOrigin.port().value_or(0), !!securityOrigin.port());
#endif
}

void ContentSecurityPolicy::applyPolicyToScriptExecutionContext()
{
    RefPtr scriptExecutionContext = m_scriptExecutionContext.get();
    ASSERT(scriptExecutionContext);

    // Update source self as the security origin may have changed between the time we were created and now.
    // For instance, we may have been initially created for an about:blank iframe that later inherited the
    // security origin of its owner document.
    RefPtr securityOrigin = scriptExecutionContext->securityOrigin();
    ASSERT(securityOrigin);

    // Skip for opaque origins (e.g. sandboxed iframes) to preserve the self-source
    // established after CSP inheritance. Per the CSP spec §2.2 note, the self-origin
    // concept exists to facilitate 'self' checks for opaque-origin documents that
    // inherited their policy.
    if (!securityOrigin->isOpaque())
        updateSourceSelf(*securityOrigin);

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    bool requiresTrustedTypesForScript = false;
    bool requiresTrustedTypesForScriptEnforced = false;
    for (auto& policy : m_policies) {
        const ContentSecurityPolicyDirective* violatedDirective = policy->violatedDirectiveForUnsafeEval();
        if (violatedDirective && !violatedDirective->directiveList().isReportOnly()) {
            m_lastPolicyEvalDisabledErrorMessage = policy->evalDisabledErrorMessage();
            m_lastPolicyWebAssemblyDisabledErrorMessage = policy->webAssemblyDisabledErrorMessage();
        }
        if (policy->requiresTrustedTypesForScript()) {
            requiresTrustedTypesForScript = true;
            requiresTrustedTypesForScriptEnforced = !policy->isReportOnly();
        }

        if (!policy->trustedEvalEnabled())
            m_trustedEvalEnabled = false;
    }
#else
    if (auto index = m_swiftDirectives->directives.lastEnforcedPolicyDisallowingEval(); index >= 0) {
        m_lastPolicyEvalDisabledErrorMessage = m_swiftDirectives->directives.evalDisabledErrorMessage(index);
        m_lastPolicyWebAssemblyDisabledErrorMessage = m_swiftDirectives->directives.webAssemblyDisabledErrorMessage(index);
    }
    bool requiresTrustedTypesForScript = m_swiftDirectives->directives.requiresTrustedTypesForScript();
    bool requiresTrustedTypesForScriptEnforced = m_swiftDirectives->directives.lastPolicyRequiringTrustedTypesForScriptIsEnforced();
    m_trustedEvalEnabled = m_trustedEvalEnabled && m_swiftDirectives->directives.trustedEvalEnabled();
#endif

    if (!m_lastPolicyEvalDisabledErrorMessage.isNull())
        scriptExecutionContext->disableEval(m_lastPolicyEvalDisabledErrorMessage);
    if (!m_lastPolicyWebAssemblyDisabledErrorMessage.isNull())
        scriptExecutionContext->disableWebAssembly(m_lastPolicyWebAssemblyDisabledErrorMessage);
    if (!m_sandboxFlags.isEmpty() && is<Document>(scriptExecutionContext.get()))
        scriptExecutionContext->enforceSandboxFlags(m_sandboxFlags, SecurityContext::SandboxFlagsSource::CSP);
    if (requiresTrustedTypesForScript && requiresTrustedTypesForScriptEnforced && m_trustedEvalEnabled)
        scriptExecutionContext->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::EnforcedWithEvalEnabled);
    else if (requiresTrustedTypesForScript && requiresTrustedTypesForScriptEnforced)
        scriptExecutionContext->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::Enforced);
    else if (requiresTrustedTypesForScript)
        scriptExecutionContext->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::ReportOnly);
    else
        scriptExecutionContext->setTrustedTypesEnforcement(JSC::TrustedTypesEnforcement::None);
}

void ContentSecurityPolicy::setOverrideAllowInlineStyle(bool value)
{
    m_overrideInlineStyleAllowed = value;
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
bool ContentSecurityPolicy::urlMatchesSelf(const URL& url) const
{
    return m_selfSource->matches(url);
}
#endif

bool ContentSecurityPolicy::allowContentSecurityPolicySourceStarToMatchAnyProtocol() const
{
    if (auto* document = dynamicDowncast<Document>(m_scriptExecutionContext.get()))
        return document->settings().allowContentSecurityPolicySourceStarToMatchAnyProtocol();
    return false;
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
template<typename Predicate, typename... Args>
bool ContentSecurityPolicy::allPoliciesWithDispositionAllow(Disposition disposition, Predicate&& predicate, Args&&... args) const
    requires (!std::is_convertible_v<Predicate, ContentSecurityPolicy::ViolatedDirectiveCallback>)
{
    bool isReportOnly = disposition == ContentSecurityPolicy::Disposition::ReportOnly;
    for (auto& policy : m_policies) {
        if (policy->isReportOnly() != isReportOnly)
            continue;
        if ((policy.get()->*predicate)(args...))
            return false;
    }
    return true;
}

template<typename Predicate, typename... Args>
bool ContentSecurityPolicy::allPoliciesWithDispositionAllow(Disposition disposition, NOESCAPE const ViolatedDirectiveCallback& callback, Predicate&& predicate, Args&&... args) const
{
    bool isReportOnly = disposition == ContentSecurityPolicy::Disposition::ReportOnly;
    bool isAllowed = true;
    for (auto& policy : m_policies) {
        if (policy->isReportOnly() != isReportOnly)
            continue;
        if (const ContentSecurityPolicyDirective* violatedDirective = (policy.get()->*predicate)(args...)) {
            isAllowed = false;
            callback(*violatedDirective);
        }
    }
    return isAllowed;
}

template<typename Predicate, typename... Args>
bool ContentSecurityPolicy::allPoliciesAllow(NOESCAPE const ViolatedDirectiveCallback& callback, Predicate&& predicate, Args&&... args) const
{
    bool isAllowed = true;
    for (auto& policy : m_policies) {
        if (const ContentSecurityPolicyDirective* violatedDirective = (policy.get()->*predicate)(args...)) {
            if (!violatedDirective->directiveList().isReportOnly())
                isAllowed = false;
            callback(*violatedDirective);
        }
    }
    return isAllowed;
}
#endif

static Vector<ResourceCryptographicDigest> parseSubResourceIntegrityIntoDigests(const String& subResourceIntegrity)
{
    auto encodedDigests = parseIntegrityMetadata(subResourceIntegrity);
    if (!encodedDigests)
        return { };

    return WTF::compactMap(*encodedDigests, [](auto& encodedDigest) {
        return decodeEncodedResourceCryptographicDigest(encodedDigest);
    });
}

static Vector<ContentSecurityPolicyHash> generateHashesForContent(const StringView content, OptionSet<ContentSecurityPolicyHashAlgorithm> algorithms)
{
    if (algorithms.isEmpty())
        return { };

    auto utf8Content = content.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
    Vector<ContentSecurityPolicyHash> hashes;
    for (auto algorithm : algorithms) {
        auto hash = cryptographicDigestForBytes(algorithm, byteCast<uint8_t>(utf8Content.span()));
        hashes.append(hash);
    }

    return hashes;
}

bool ContentSecurityPolicy::allowJavaScriptURLs(const String& contextURL, const OrdinalNumber& contextLine, const String& source, Element* element) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    bool didNotifyInspector = false;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &didNotifyInspector, &contextURL, &contextLine, &source, element = RefPtr { element }] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, URL(), "Refused to execute a script"_s, "its hash or 'unsafe-inline'"_s);
        checkedThis->reportViolation(violatedDirective, "inline"_s, consoleMessage, contextURL, source, TextPosition(contextLine, OrdinalNumber()), URL(), nullptr, element.get());
        if (!didNotifyInspector && violatedDirective.directiveList().isReportOnly()) {
            checkedThis->reportBlockedScriptExecutionToInspector(violatedDirective.text());
            didNotifyInspector = true;
        }
    };

    auto contentHashes = generateHashesForContent(source, m_hashAlgorithmsForInlineScripts);
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForInlineJavascriptURL, contentHashes);
#else
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = source, .sourcePosition = TextPosition(contextLine, OrdinalNumber()), .element = element };
    return scope.directives.allowJavaScriptURLs(contentSecurityPolicyContentHashes(generateHashesForContent(source, m_hashAlgorithmsForInlineScripts)));
#endif
}

bool ContentSecurityPolicy::allowInlineEventHandlers(const String& contextURL, const OrdinalNumber& contextLine, const String& source, Element* element, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (overrideContentSecurityPolicy || m_policies.isEmpty())
        return true;
    bool didNotifyInspector = false;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &didNotifyInspector, &contextURL, &contextLine, &source, element = RefPtr { element }] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, URL(), "Refused to execute a script for an inline event handler"_s, "'unsafe-inline'"_s);
        checkedThis->reportViolation(violatedDirective, "inline"_s, consoleMessage, contextURL, source, TextPosition(contextLine, OrdinalNumber()), URL(), nullptr, element.get());
        if (!didNotifyInspector && !violatedDirective.directiveList().isReportOnly()) {
            checkedThis->reportBlockedScriptExecutionToInspector(violatedDirective.text());
            didNotifyInspector = true;
        }
    };

    auto contentHashes = generateHashesForContent(source, m_hashAlgorithmsForInlineScripts);
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForInlineEventHandlers, contentHashes);
#else
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = source, .sourcePosition = TextPosition(contextLine, OrdinalNumber()), .element = element };
    return scope.directives.allowInlineEventHandlers(contentSecurityPolicyContentHashes(generateHashesForContent(source, m_hashAlgorithmsForInlineScripts)));
#endif
}

bool ContentSecurityPolicy::allowScriptWithNonce(const String& nonce, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (overrideContentSecurityPolicy || m_policies.isEmpty())
        return true;
    auto trimmedNonce = nonce.trim(isASCIIWhitespace);
    if (trimmedNonce.isEmpty())
        return false;
    // FIXME: We need to report violations in report-only policies. See <https://bugs.webkit.org/show_bug.cgi?id=159830>.
    return allPoliciesWithDispositionAllow(ContentSecurityPolicy::Disposition::Enforce, &ContentSecurityPolicyDirectiveList::violatedDirectiveForScriptNonce, trimmedNonce);
#else
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty())
        return true;
    return m_swiftDirectives->directives.allowScriptWithNonce(nonce.trim(isASCIIWhitespace));
#endif
}

bool ContentSecurityPolicy::allowStyleWithNonce(const String& nonce, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (overrideContentSecurityPolicy || m_policies.isEmpty())
        return true;
    auto trimmedNonce = nonce.trim(isASCIIWhitespace);
    if (trimmedNonce.isEmpty())
        return false;
    // FIXME: We need to report violations in report-only policies. See <https://bugs.webkit.org/show_bug.cgi?id=159830>.
    return allPoliciesWithDispositionAllow(ContentSecurityPolicy::Disposition::Enforce, &ContentSecurityPolicyDirectiveList::violatedDirectiveForStyleNonce, trimmedNonce);
#else
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty())
        return true;
    return m_swiftDirectives->directives.allowStyleWithNonce(nonce.trim(isASCIIWhitespace));
#endif
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
bool ContentSecurityPolicy::shouldPerformEarlyCSPCheck() const
{
    // We perform checks early if strict-dynamic is included in the CSP policy because
    // we have access to necessary information about the script that we do not have later on.
    for (auto& policy : m_policies) {
        if (policy->strictDynamicIncluded())
            return true;
    }
    return false;
}
#endif

bool ContentSecurityPolicy::allowScriptForStrictDynamic(const URL& sourceURL, const URL& contextURL, const OrdinalNumber& contextLine, const String& nonce, const String& subResourceIntegrity, const StringView& scriptContent, ParserInserted parserInserted) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (!shouldPerformEarlyCSPCheck() || m_policies.isEmpty())
        return true;

    if (!sourceURL.isEmpty() && LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(sourceURL.protocol()))
        return true;

    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &contextURL, &contextLine, &scriptContent] (const ContentSecurityPolicyDirective& violatedDirective) {
        TextPosition sourcePosition(contextLine, OrdinalNumber());
        const auto message = sourceURL.isEmpty() ? "Refused to execute a script"_s : "Refused to load"_s;
        String consoleMessage = consoleMessageForViolation(violatedDirective, sourceURL, message);
        checkedThis->reportViolation(violatedDirective, sourceURL.isEmpty() ? "inline"_s : sourceURL.string(), consoleMessage, contextURL.string(), scriptContent, sourcePosition);
    };

    auto subResourceIntegrityDigests = parseSubResourceIntegrityIntoDigests(subResourceIntegrity);
    auto contentHashes = generateHashesForContent(scriptContent, m_hashAlgorithmsForInlineScripts);
    auto trimmedNonce = nonce.trim(isASCIIWhitespace);
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForScriptUnderStrictDynamic, trimmedNonce, contentHashes, subResourceIntegrityDigests, sourceURL, parserInserted);
#else
    if (!m_swiftDirectives->directives.shouldPerformEarlyCSPCheck() || m_swiftDirectives->directives.isEmpty() || (!sourceURL.isEmpty() && LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(sourceURL.protocol())))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = sourceURL.isEmpty() ? "inline"_s : sourceURL.string(), .consoleURL = sourceURL, .sourceURL = contextURL.string(), .sourceContent = scriptContent, .sourcePosition = TextPosition(contextLine, OrdinalNumber()),
        .subresourceIntegrityDigests = parseSubResourceIntegrityIntoDigests(subResourceIntegrity) };
    return scope.directives.allowScriptForStrictDynamic(sourceURL.string(), contentSecurityPolicyURLBounds(sourceURL), nonce.trim(isASCIIWhitespace), parserInserted == ParserInserted::Yes, contentSecurityPolicyContentHashes(generateHashesForContent(scriptContent, m_hashAlgorithmsForInlineScripts)), scope.subresourceIntegrityDigests.size(), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

bool ContentSecurityPolicy::allowInlineScript(const String& contextURL, const TextPosition& contextPosition, StringView scriptContent, Element& element, const String& nonce, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (overrideContentSecurityPolicy || shouldPerformEarlyCSPCheck() || m_policies.isEmpty())
        return true;
    bool didNotifyInspector = false;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &didNotifyInspector, &contextURL, &contextPosition, &scriptContent, element = Ref { element }] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, URL(), "Refused to execute a script"_s, "its hash, its nonce, or 'unsafe-inline'"_s);
        checkedThis->reportViolation(violatedDirective, "inline"_s, consoleMessage, contextURL, scriptContent, contextPosition, URL(), nullptr, element.ptr());
        if (!didNotifyInspector && !violatedDirective.directiveList().isReportOnly()) {
            checkedThis->reportBlockedScriptExecutionToInspector(violatedDirective.text());
            didNotifyInspector = true;
        }
    };

    auto contentHashes = generateHashesForContent(scriptContent, m_hashAlgorithmsForInlineScripts);
    auto trimmedNonce = nonce.trim(isASCIIWhitespace);
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForUnsafeInlineScriptElement, trimmedNonce, contentHashes);
#else
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.shouldPerformEarlyCSPCheck() || m_swiftDirectives->directives.isEmpty())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = scriptContent, .sourcePosition = contextPosition, .element = &element };
    return scope.directives.allowInlineScript(nonce.trim(isASCIIWhitespace), contentSecurityPolicyContentHashes(generateHashesForContent(scriptContent, m_hashAlgorithmsForInlineScripts)));
#endif
}

bool ContentSecurityPolicy::allowInlineStyle(const String& contextURL, const OrdinalNumber& contextLine, StringView styleContent, CheckUnsafeHashes shouldCheckUnsafeHashes, Element& element, const String& nonce, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (overrideContentSecurityPolicy || m_policies.isEmpty())
        return true;
    if (m_overrideInlineStyleAllowed)
        return true;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &contextURL, &contextLine, &styleContent, element = Ref { element }] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, URL(), "Refused to apply a stylesheet"_s, "its hash, its nonce, or 'unsafe-inline'"_s);
        checkedThis->reportViolation(violatedDirective, "inline"_s, consoleMessage, contextURL, styleContent, TextPosition(contextLine, OrdinalNumber()), URL(), nullptr, element.ptr());
    };

    auto contentHashes = generateHashesForContent(styleContent, m_hashAlgorithmsForInlineStylesheets);
    auto trimmedNonce = nonce.trim(isASCIIWhitespace);

    if (shouldCheckUnsafeHashes == CheckUnsafeHashes::Yes)
        return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForUnsafeInlineStyleAttribute, trimmedNonce, contentHashes);

    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForUnsafeInlineStyleElement, trimmedNonce, contentHashes);
#else
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty() || m_overrideInlineStyleAllowed)
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = styleContent, .sourcePosition = TextPosition(contextLine, OrdinalNumber()), .element = &element };
    return scope.directives.allowInlineStyle(nonce.trim(isASCIIWhitespace), shouldCheckUnsafeHashes == CheckUnsafeHashes::Yes, contentSecurityPolicyContentHashes(generateHashesForContent(styleContent, m_hashAlgorithmsForInlineStylesheets)));
#endif
}

bool ContentSecurityPolicy::allowEval(JSC::JSGlobalObject* state, LogToConsole shouldLogToConsole, StringView codeContent, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || overrideContentSecurityPolicy)
        return true;
    if (m_trustedEvalEnabled && requireTrustedTypesForSinkGroup("script"_s, IncludeReportOnlyPolicies::No))
        return true;
    bool didNotifyInspector = false;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &didNotifyInspector, &state, &shouldLogToConsole, &codeContent] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = shouldLogToConsole == LogToConsole::Yes ? consoleMessageForViolation(violatedDirective, URL(), "Refused to execute a script"_s, "'unsafe-eval' and 'trusted-types-eval'"_s) : String();
        checkedThis->reportViolation(violatedDirective, "eval"_s, consoleMessage, state, codeContent);
        if (!didNotifyInspector && !violatedDirective.directiveList().isReportOnly()) {
            checkedThis->reportBlockedScriptExecutionToInspector(violatedDirective.text());
            didNotifyInspector = true;
        }
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForUnsafeEval);
#else
    if (m_swiftDirectives->directives.isEmpty() || overrideContentSecurityPolicy || (m_trustedEvalEnabled && requireTrustedTypesForSinkGroup("script"_s, IncludeReportOnlyPolicies::No)))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "eval"_s, .sourceContent = codeContent, .globalObject = state };
    return scope.directives.allowEval(shouldLogToConsole == LogToConsole::Yes);
#endif
}

bool ContentSecurityPolicy::allowFrameAncestors(const LocalFrame& frame, const URL& url, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || overrideContentSecurityPolicy)
        return true;
    if (&frame == &frame.tree().top())
        return true;
    String sourceURL;
    TextPosition sourcePosition(OrdinalNumber::beforeFirst(), OrdinalNumber());
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &sourcePosition, &url] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, url.string(), consoleMessage, sourceURL, StringView(), sourcePosition);
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForFrameAncestor, frame);
#else
    if (m_swiftDirectives->directives.isEmpty() || overrideContentSecurityPolicy || &frame == &frame.tree().top() || !m_swiftDirectives->directives.hasFrameAncestorsDirective())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()), .frame = &frame };
    return scope.directives.allowFrameAncestors(allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

bool ContentSecurityPolicy::overridesXFrameOptions() const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    // If a resource is delivered with an policy that includes a directive named frame-ancestors and whose disposition
    // is "enforce", then the X-Frame-Options header MUST be ignored.
    // https://www.w3.org/TR/CSP3/#frame-ancestors-and-frame-options
    for (auto& policy : m_policies) {
        if (!policy->isReportOnly() && policy->hasFrameAncestorsDirective())
            return true;
    }
    return false;
#else
    return m_swiftDirectives->directives.overridesXFrameOptions();
#endif
}

bool ContentSecurityPolicy::allowFrameAncestors(const Vector<Ref<SecurityOrigin>>& ancestorOrigins, const URL& url, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || overrideContentSecurityPolicy)
        return true;
    bool isTopLevelFrame = ancestorOrigins.isEmpty();
    if (isTopLevelFrame)
        return true;
    String sourceURL;
    TextPosition sourcePosition(OrdinalNumber::beforeFirst(), OrdinalNumber());
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &sourcePosition, &url] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, url.string(), consoleMessage, sourceURL, StringView(), sourcePosition);
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForFrameAncestorOrigins, ancestorOrigins);
#else
    if (m_swiftDirectives->directives.isEmpty() || overrideContentSecurityPolicy || ancestorOrigins.isEmpty() || !m_swiftDirectives->directives.hasFrameAncestorsDirective())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()), .ancestorOrigins = &ancestorOrigins };
    return scope.directives.allowFrameAncestors(allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

bool ContentSecurityPolicy::allowPluginType(const String&, const String&, const URL&, bool) const
{
    // The 'plugin-types' directive was removed from the CSP specification and is no longer
    // enforced. See https://github.com/w3c/webappsec-csp/issues/424
    return true;
}

bool ContentSecurityPolicy::allowObjectFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    // Report deprecation of 'plugin-types' when an object/embed element is used
    for (auto& policy : m_policies) {
        if (policy->hasPluginTypesDirective()) {
            reportDeprecatedDirective("plugin-types"_s);
            break;
        }
    }

    const auto& urlToCheck = url.isEmpty() ? m_protectedURL : url;
    if (m_policies.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(urlToCheck.protocol()))
        return true;
    String sourceURL;
    const auto& blockedURL = !preRedirectURL.isNull() ? preRedirectURL : urlToCheck;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, sourcePosition = WTF::move(sourcePosition), &blockedURL, &urlToCheck](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        String consoleMessage = consoleMessageForViolation(violatedDirective, urlToCheck, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, blockedURL.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition));
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForObjectSource, urlToCheck, redirectResponseReceived == RedirectResponseReceived::Yes);
#else
    // Report deprecation of 'plugin-types' when an object/embed element is used
    if (m_swiftDirectives->directives.hasPluginTypesDirective())
        reportDeprecatedDirective("plugin-types"_s);

    return allowResourceFromSource(url.isEmpty() ? m_protectedURL : url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowObjectFromSource, preRedirectURL);
#endif
}

bool ContentSecurityPolicy::allowChildFrameFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()) || url.protocolIsJavaScript())
        return true;
    String sourceURL;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, sourcePosition = WTF::move(sourcePosition), &url](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, url.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition));
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForFrame, url, redirectResponseReceived == RedirectResponseReceived::Yes);
#else
    if (url.protocolIsJavaScript())
        return true;
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowChildFrameFromSource);
#endif
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
bool ContentSecurityPolicy::allowResourceFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, ResourcePredicate resourcePredicate, const URL& preRedirectURL) const
{
    if (m_policies.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    String sourceURL;
    const auto& blockedURL = !preRedirectURL.isNull() ? preRedirectURL : url;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &blockedURL, sourcePosition = WTF::move(sourcePosition), &url](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, blockedURL.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition));
    };
    return allPoliciesAllow(handleViolatedDirective, resourcePredicate, url, redirectResponseReceived == RedirectResponseReceived::Yes);
}
#else
template<typename Check>
bool ContentSecurityPolicy::allowResourceFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, Check check, const URL& preRedirectURL) const
{
    if (m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = (!preRedirectURL.isNull() ? preRedirectURL : url).string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition) };
    return (scope.directives.*check)(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}
#endif

bool ContentSecurityPolicy::allowWorkerFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;

    String sourceURL;
    const auto& blockedURL = !preRedirectURL.isNull() ? preRedirectURL : url;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &blockedURL, sourcePosition = WTF::move(sourcePosition), &url](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        auto consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, blockedURL.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition));
    };

    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForWorker, url, redirectResponseReceived == RedirectResponseReceived::Yes);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowWorkerFromSource, preRedirectURL);
#endif
}

bool ContentSecurityPolicy::allowScriptFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL, const String& subResourceIntegrity, const String& nonce) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || shouldPerformEarlyCSPCheck())
        return true;
    if (LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;

    String sourceURL;
    const auto& blockedURL = !preRedirectURL.isNull() ? preRedirectURL : url;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &blockedURL, sourcePosition = WTF::move(sourcePosition), &url](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, blockedURL.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition));
    };

    auto subResourceIntegrityDigests = parseSubResourceIntegrityIntoDigests(subResourceIntegrity);
    auto trimmedNonce = nonce.trim(isASCIIWhitespace);
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForScript, url, redirectResponseReceived == RedirectResponseReceived::Yes, subResourceIntegrityDigests, trimmedNonce);
#else
    if (m_swiftDirectives->directives.isEmpty() || m_swiftDirectives->directives.shouldPerformEarlyCSPCheck() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = (!preRedirectURL.isNull() ? preRedirectURL : url).string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition), .subresourceIntegrityDigests = parseSubResourceIntegrityIntoDigests(subResourceIntegrity) };
    return scope.directives.allowScriptFromSource(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, nonce.trim(isASCIIWhitespace), scope.subresourceIntegrityDigests.size(), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

bool ContentSecurityPolicy::allowImageFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveList::violatedDirectiveForImage, preRedirectURL);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowImageFromSource, preRedirectURL);
#endif
}

bool ContentSecurityPolicy::allowPrefetchFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveList::violatedDirectiveForPrefetch, preRedirectURL);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowPrefetchFromSource, preRedirectURL);
#endif
}

bool ContentSecurityPolicy::allowStyleFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL, const String& nonce) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    String sourceURL;
    const auto& blockedURL = !preRedirectURL.isNull() ? preRedirectURL : url;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &blockedURL, sourcePosition = WTF::move(sourcePosition), &url](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to load"_s);
        checkedThis->reportViolation(violatedDirective, blockedURL.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition));
    };

    auto trimmedNonce = nonce.trim(isASCIIWhitespace);
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForStyle, url, redirectResponseReceived == RedirectResponseReceived::Yes, trimmedNonce);
#else
    if (m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = (!preRedirectURL.isNull() ? preRedirectURL : url).string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition) };
    return scope.directives.allowStyleFromSource(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, nonce.trim(isASCIIWhitespace), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

bool ContentSecurityPolicy::allowFontFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveList::violatedDirectiveForFont, preRedirectURL);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowFontFromSource, preRedirectURL);
#endif
}

#if ENABLE(APPLICATION_MANIFEST)
bool ContentSecurityPolicy::allowManifestFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveList::violatedDirectiveForManifest, preRedirectURL);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowManifestFromSource, preRedirectURL);
#endif
}
#endif // ENABLE(APPLICATION_MANIFEST)

bool ContentSecurityPolicy::allowMediaFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveList::violatedDirectiveForMedia, preRedirectURL);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowMediaFromSource, preRedirectURL);
#endif
}

bool ContentSecurityPolicy::allowConnectToSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (m_policies.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    String sourceURL;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, sourcePosition = WTF::move(sourcePosition), &url, &preRedirectURL](const ContentSecurityPolicyDirective& violatedDirective) mutable {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to connect to"_s);
        checkedThis->reportViolation(violatedDirective, url.string(), consoleMessage, sourceURL, StringView(), WTF::move(sourcePosition), preRedirectURL);
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForConnectSource, url, redirectResponseReceived == RedirectResponseReceived::Yes);
#else
    if (m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition), .preRedirectURL = preRedirectURL };
    return scope.directives.allowConnectToSource(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

bool ContentSecurityPolicy::allowFormAction(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveList::violatedDirectiveForFormAction, preRedirectURL);
#else
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowFormAction, preRedirectURL);
#endif
}

bool ContentSecurityPolicy::allowBaseURI(const URL& url, bool overrideContentSecurityPolicy) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    if (overrideContentSecurityPolicy || m_policies.isEmpty())
        return true;
    if (LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    String sourceURL;
    TextPosition sourcePosition(OrdinalNumber::beforeFirst(), OrdinalNumber());
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &sourcePosition, &url](const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = consoleMessageForViolation(violatedDirective, url, "Refused to change the document base URL to"_s);
        checkedThis->reportViolation(violatedDirective, url.string(), consoleMessage, sourceURL, StringView(), { sourcePosition });
    };
    return allPoliciesAllow(handleViolatedDirective, &ContentSecurityPolicyDirectiveList::violatedDirectiveForBaseURI, url);
#else
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()) };
    return scope.directives.allowBaseURI(url.string(), contentSecurityPolicyURLBounds(url), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
#endif
}

// https://w3c.github.io/trusted-types/dist/spec/#should-block-create-policy
AllowTrustedTypePolicy ContentSecurityPolicy::allowTrustedTypesPolicy(const String& value, bool isDuplicate) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    String sourceURL;
    TextPosition sourcePosition(OrdinalNumber::beforeFirst(), OrdinalNumber());
    AllowTrustedTypePolicy details = AllowTrustedTypePolicy::Allowed;
    auto handleViolatedDirective = [checkedThis = CheckedRef { *this }, &sourceURL, &sourcePosition, &value] (const ContentSecurityPolicyDirective& violatedDirective) {
        String consoleMessage = makeString(violatedDirective.directiveList().isReportOnly() ? "[Report Only] "_s : ""_s,
            "Refused to create a TrustedTypePolicy named '"_s, value, "' because it violates the following Content Security Policy directive: \""_s, violatedDirective.text(), '"');
        checkedThis->reportViolation(violatedDirective, "trusted-types-policy"_s, consoleMessage, sourceURL, StringView(value), sourcePosition);
    };

    auto isAllowed = true;
    for (auto& policy : m_policies) {
        auto perPolicyDetails = AllowTrustedTypePolicy::Allowed;
        if (auto* violatedDirective = policy.get()->violatedDirectiveForTrustedTypesPolicy(value, isDuplicate, perPolicyDetails)) {
            if (!violatedDirective->directiveList().isReportOnly())
                isAllowed = false;
            // If we already have a violation, we should use the details from the first policy that violated the directive.
            if (!isAllowed && details == AllowTrustedTypePolicy::Allowed)
                details = perPolicyDetails;
            handleViolatedDirective(*violatedDirective);
        }
    }

    if (value == "default"_s && isDuplicate)
        return AllowTrustedTypePolicy::DisallowedDuplicateName;

    return isAllowed
        ? AllowTrustedTypePolicy::Allowed
        : details;
#else
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "trusted-types-policy"_s, .sourceURL = String(), .sourceContent = value, .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()) };
    return static_cast<AllowTrustedTypePolicy>(scope.directives.allowTrustedTypesPolicy(value, isDuplicate));
#endif
}

// https://w3c.github.io/trusted-types/dist/spec/#does-sink-require-trusted-types
bool ContentSecurityPolicy::requireTrustedTypesForSinkGroup(const String& sinkGroup, IncludeReportOnlyPolicies includeReportOnlyPolicies) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    for (auto& policy : m_policies) {
        if (policy->requiresTrustedTypesForScript() && sinkGroup == "script"_s) {
            if (!policy->isReportOnly())
                return true;
            if (includeReportOnlyPolicies == IncludeReportOnlyPolicies::Yes)
                return true;
        }
    }
    return false;
#else
    return sinkGroup == "script"_s && m_swiftDirectives->directives.requireTrustedTypesForSinkGroup(includeReportOnlyPolicies == IncludeReportOnlyPolicies::Yes);
#endif
}

// https://w3c.github.io/trusted-types/dist/spec/#should-block-sink-type-mismatch
bool ContentSecurityPolicy::allowMissingTrustedTypesForSinkGroup(const String& stringContext, const String& sink, const String& sinkGroup, StringView source) const
{
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    auto isAllowed = true;
    for (auto& policy : m_policies) {
        if (policy->requiresTrustedTypesForScript() && sinkGroup == "script"_s) {
            if (!policy->isReportOnly())
                isAllowed = false;

            String consoleMessage = makeString(policy->isReportOnly() ? "[Report Only] "_s : ""_s,
                "This requires a "_s, stringContext, " value else it violates the following Content Security Policy directive: \"require-trusted-types-for 'script'\""_s);
            StringView sample = source;

            if (sink == "Function"_s) {
                constexpr std::array<ASCIILiteral, 4> prefixes = {
                    "function anonymous"_s,
                    "async function anonymous"_s,
                    "function* anonymous"_s,
                    "async function* anonymous"_s
                };
                for (auto prefix : prefixes) {
                    if (sample.startsWith(prefix)) {
                        sample = sample.substring(prefix.length());
                        break;
                    }
                }
            }
            String violationSample = makeString(sink, '|', sample.left(40));
            reportViolation("require-trusted-types-for"_s, *policy, "trusted-types-sink"_s, consoleMessage, nullString(), violationSample, TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()), nullptr);
        }
    }
    return isAllowed;
#else
    if (sinkGroup != "script"_s)
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "trusted-types-sink"_s, .sourceURL = nullString(), .sourceContent = source, .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()) };
    // The longest prefix allowMissingTrustedTypesSample() strips, "async function* anonymous" (25), and the 40 characters of the sample.
    return scope.directives.allowMissingTrustedTypesForSinkGroup(stringContext, sink, source.left(65).toString());
#endif
}

static bool shouldReportProtocolOnly(const URL& url)
{
    // FIXME: https://w3c.github.io/webappsec-csp/#strip-url-for-use-in-reports suggests this should
    // be url.protocolIsInHTTPFamily().
    return url.hasOpaquePath() || url.protocolIsFile();
}

String ContentSecurityPolicy::createURLForReporting(const URL& url, const String& violatedDirective, bool usesReportingAPI) const
{
    // This implements the deprecated CSP2 "strip uri for reporting" algorithm from https://www.w3.org/TR/CSP2/#violation-reports
    // with the change that cross-origin is considered safe except on some directives.
    // The frame-src, object-src, and block-all-mixed-content directives would allow a website to put another in a frame
    // and listen to emitted securitypolicyviolations.
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
    bool directiveIsSafe = violatedDirective != ContentSecurityPolicyDirectiveNames::frameSrc
        && violatedDirective != ContentSecurityPolicyDirectiveNames::objectSrc
        && violatedDirective != ContentSecurityPolicyDirectiveNames::blockAllMixedContent;
    auto securityOrigin = static_cast<SecurityOriginData>(*m_selfSource).securityOrigin();
#else
    bool directiveIsSafe = violatedDirective != "frame-src"_s && violatedDirective != "object-src"_s && violatedDirective != "block-all-mixed-content"_s;
    auto securityOrigin = m_selfOrigin.securityOrigin();
#endif

    if (!url.isValid())
        return { };
    if (shouldReportProtocolOnly(url))
        return url.protocol().toString();

    // WPT indicates that modern Reporting API expects explicit port in reported URLs
    //     content-security-policy/reporting-api/report-to-directive-allowed-in-meta.https.sub.html
    //     content-security-policy/reporting-api/reporting-api-sends-reports-on-violation.https.sub.html
    if (securityOrigin->canRequest(url, originAccessPatternsForWebProcessOrEmpty()) || directiveIsSafe)
        return (usesReportingAPI ? url.strippedForUseAsReferrerWithExplicitPort() : url.strippedForUseAsReferrer()).string;

    return SecurityOrigin::create(url)->toString();
}

std::optional<CodePosition> ContentSecurityPolicy::getCurrentCodePosition()
{
    auto stack = createScriptCallStack(JSExecState::currentState(), 2);
    if (auto* callFrame = stack->firstNonNativeCallFrame()) {
        if (callFrame->lineNumber()) {
            return CodePosition {
                callFrame->preRedirectURL().isEmpty() ? callFrame->sourceURL() : callFrame->preRedirectURL(),
                OrdinalNumber::fromOneBasedInt(callFrame->lineNumber()),
                OrdinalNumber::fromOneBasedInt(callFrame->columnNumber())
            };
        }
    }
    return std::nullopt;
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
void ContentSecurityPolicy::reportViolation(const ContentSecurityPolicyDirective& violatedDirective, const String& blockedURL, const String& consoleMessage, JSC::JSGlobalObject* state, StringView sourceContent) const
{
    // FIXME: Extract source file, and position from JSC::ExecState.
    return reportViolation(violatedDirective.nameForReporting(), violatedDirective.directiveList(), blockedURL, consoleMessage, String(), sourceContent.left(40), { }, state);
}

void ContentSecurityPolicy::reportViolation(const String& violatedDirective, const ContentSecurityPolicyDirectiveList& violatedDirectiveList, const String& blockedURL, const String& consoleMessage, JSC::JSGlobalObject* state) const
{
    // FIXME: Extract source file, content, and position from JSC::ExecState.
    return reportViolation(violatedDirective, violatedDirectiveList, blockedURL, consoleMessage, String(), StringView(), { }, state);
}

void ContentSecurityPolicy::reportViolation(const ContentSecurityPolicyDirective& violatedDirective, const String& blockedURL, const String& consoleMessage, const String& sourceURL, StringView sourceContent, std::optional<TextPosition>&& sourcePosition, const URL& preRedirectURL, JSC::JSGlobalObject* state, Element* element) const
{
    return reportViolation(violatedDirective.nameForReporting(), violatedDirective.directiveList(), blockedURL, consoleMessage, sourceURL, sourceContent.left(40), WTF::move(sourcePosition), state, preRedirectURL, element);
}

void ContentSecurityPolicy::reportViolation(const String& effectiveViolatedDirective, const ContentSecurityPolicyDirectiveList& violatedDirectiveList, const String& blockedURLString, const String& consoleMessage, const String& sourceURL, StringView sourceContent, std::optional<TextPosition>&& maybeSourcePosition, JSC::JSGlobalObject* state, const URL& preRedirectURL, Element* element) const
#else
void ContentSecurityPolicy::reportViolation(const String& effectiveViolatedDirective, const SwiftViolatedPolicy& violatedDirectiveList, const String& blockedURLString, const String& consoleMessage, const String& sourceURL, StringView sourceContent, std::optional<TextPosition>&& maybeSourcePosition, JSC::JSGlobalObject* state, const URL& preRedirectURL, Element* element) const
#endif
{
    TextPosition sourcePosition = maybeSourcePosition.value_or(TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber::beforeFirst()));
    logToConsole(consoleMessage, sourceURL, sourcePosition.m_line, sourcePosition.m_column, state);

    if (!m_isReportingEnabled)
        return;

    // FIXME: Support sending reports from worker.
    CSPInfo info;

    bool usesReportTo = !violatedDirectiveList.reportToTokens().isEmpty();

    String blockedURI;
    if (blockedURLString == "eval"_s || blockedURLString == "inline"_s || blockedURLString == "trusted-types-policy"_s || blockedURLString == "trusted-types-sink"_s)
        blockedURI = blockedURLString;
    else {
        // If there is a redirect then we use the pre-redirect URL: https://www.w3.org/TR/CSP3/#security-violation-reports.
        blockedURI = createURLForReporting(preRedirectURL.isNull() ? URL { blockedURLString } : preRedirectURL, effectiveViolatedDirective, usesReportTo);
    }

    info.url = m_documentURL ? m_documentURL.value().strippedForUseAsReferrer().string : blockedURI;
    info.sample = violatedDirectiveList.shouldReportSample(effectiveViolatedDirective) ? sourceContent.toString() : emptyString();

    // Line number and column number are only included when source file is set.
    if (!sourceURL.isEmpty()) {
        info.lineNumber = sourcePosition.m_line.oneBasedInt();
        info.columnNumber = sourcePosition.m_column.oneBasedInt();
    }

    if (!m_client) {
        RefPtr scriptExecutionContext = m_scriptExecutionContext;
        if (!isAnyOf<Document, WorkerGlobalScope>(scriptExecutionContext))
            return;
        if (auto* document = dynamicDowncast<Document>(*scriptExecutionContext); document && !document->frame())
            return;

        auto& contextURL = scriptExecutionContext->url();
        info.url = shouldReportProtocolOnly(contextURL) ? contextURL.protocol().toString() : contextURL.strippedForUseAsReferrer().string;

        auto stack = createScriptCallStack(JSExecState::currentState(), 2);
        auto* callFrame = stack->firstNonNativeCallFrame();
        if (callFrame && callFrame->lineNumber()) {
            info.sourceFile = createURLForReporting(URL { callFrame->preRedirectURL().isEmpty() ? callFrame->sourceURL() : callFrame->preRedirectURL() }, effectiveViolatedDirective, usesReportTo);
            info.lineNumber = callFrame->lineNumber();
            info.columnNumber = callFrame->columnNumber();
        }
    }
    ASSERT((m_client || isAnyOf<Document, WorkerGlobalScope>(m_scriptExecutionContext.get())));

    // FIXME: Is it policy to not use the status code for HTTPS, or is that a bug?
    unsigned short httpStatusCode = m_selfSourceProtocol == "http"_s ? m_httpStatusCode : 0;
    
    // WPT indicate modern Reporting API expect valid status code, regardless of protocol:
    //     content-security-policy/reporting-api/report-to-directive-allowed-in-meta.https.sub.html
    //     content-security-policy/reporting-api/reporting-api-sends-reports-on-violation.https.sub.html
    if (usesReportTo)
        httpStatusCode = m_httpStatusCode;

    // 1. Dispatch violation event.
    SecurityPolicyViolationEventInit violationEventInit;
    violationEventInit.documentURI = info.url;
    violationEventInit.referrer = m_referrer;
    violationEventInit.blockedURI = blockedURI;
    violationEventInit.violatedDirective = effectiveViolatedDirective; // Historical alias to effectiveDirective: https://www.w3.org/TR/CSP3/#violation-events.
    violationEventInit.effectiveDirective = effectiveViolatedDirective;
    violationEventInit.originalPolicy = violatedDirectiveList.header();
    violationEventInit.sourceFile = info.sourceFile;

    violationEventInit.disposition = violatedDirectiveList.isReportOnly() ? SecurityPolicyViolationEventDisposition::Report : SecurityPolicyViolationEventDisposition::Enforce;
    violationEventInit.statusCode = httpStatusCode;
    violationEventInit.lineNumber =  info.lineNumber;
    violationEventInit.columnNumber = info.columnNumber;
    violationEventInit.sample = info.sample;
    violationEventInit.bubbles = true;
    violationEventInit.composed = true;

    Vector<String> endpointURIs;
    Vector<String> endpointTokens;

    auto reportBody = CSPViolationReportBody::create(SecurityPolicyViolationEventInit { violationEventInit });

    if (usesReportTo && m_reportingClient) {
        m_reportingClient->notifyReportObservers(Report::create(reportBody->type(), info.url, reportBody.copyRef()));
        endpointTokens = violatedDirectiveList.reportToTokens();
    } else
        endpointURIs = violatedDirectiveList.reportURIs();

    if (m_client)
        m_client->enqueueSecurityPolicyViolationEvent(WTF::move(violationEventInit));
    else if (RefPtr document = dynamicDowncast<Document>(*m_scriptExecutionContext)) {
        if (element && &element->document() == document.get())
            element->enqueueSecurityPolicyViolationEvent(WTF::move(violationEventInit));
        else
            document->enqueueSecurityPolicyViolationEvent(WTF::move(violationEventInit));
    } else
        protect(downcast<WorkerGlobalScope>(*m_scriptExecutionContext))->enqueueSecurityPolicyViolationEvent(WTF::move(violationEventInit));

    // 2. Send violation report (if applicable).
    if (endpointURIs.isEmpty() && endpointTokens.isEmpty())
        return;

    RELEASE_ASSERT(m_reportingClient || (!m_client && !m_scriptExecutionContext));
    if (!m_reportingClient)
        return;

    auto reportURL = m_documentURL ? m_documentURL.value().strippedForUseAsReferrer().string : blockedURI;

    auto reportFormData = reportBody->createReportFormDataForViolation(usesReportTo, violatedDirectiveList.isReportOnly());
    m_reportingClient->sendReportToEndpoints(m_protectedURL, endpointURIs, endpointTokens, WTF::move(reportFormData), ViolationReportType::ContentSecurityPolicy);
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
void ContentSecurityPolicy::reportUnsupportedDirective(const String& name) const
{
    String message;
    if (equalLettersIgnoringASCIICase(name, "allow"_s))
        message = "The 'allow' directive has been replaced with 'default-src'. Please use that directive instead, as 'allow' has no effect."_s;
    else if (equalLettersIgnoringASCIICase(name, "options"_s))
        message = "The 'options' directive has been replaced with 'unsafe-inline' and 'unsafe-eval' source expressions for the 'script-src' and 'style-src' directives. Please use those directives instead, as 'options' has no effect."_s;
    else if (equalLettersIgnoringASCIICase(name, "policy-uri"_s))
        message = "The 'policy-uri' directive has been removed from the specification. Please specify a complete policy via the Content-Security-Policy header."_s;
    else
        message = makeString("Unrecognized Content-Security-Policy directive '"_s, name, "'.\n"_s); // FIXME: Why does this include a newline?

    logToConsole(message);
}

void ContentSecurityPolicy::reportDeprecatedDirectiveToConsole(const String& name) const
{
    logToConsole(makeString("The Content Security Policy directive '"_s, name, "' has been removed from the specification and is ignored.\n"_s));
}
#endif

void ContentSecurityPolicy::reportDeprecatedDirective(const String& name) const
{
    if (m_reportingClient) {
        auto reportBody = DeprecationReportBody::create(
            "CSPPluginTypesDirective"_s,
            WallTime { },
            makeString("The Content Security Policy directive '"_s, name, "' has been removed from the specification and has no effect."_s),
            { },
            std::nullopt,
            std::nullopt);
        auto type = reportBody->type();
        m_reportingClient->notifyReportObservers(Report::create(type, m_protectedURL.string(), WTF::move(reportBody)));
    }
}

#if !USE_SWIFT_CONTENT_SECURITY_POLICY
void ContentSecurityPolicy::reportDirectiveAsSourceExpression(const String& directiveName, StringView sourceExpression) const
{
    logToConsole(makeString("The Content Security Policy directive '"_s, directiveName, "' contains '"_s, sourceExpression, "' as a source expression. Did you mean '"_s, directiveName, " ...; "_s, sourceExpression, "...' (note the semicolon)?"_s));
}

void ContentSecurityPolicy::reportDuplicateDirective(const String& name) const
{
    logToConsole(makeString("Ignoring duplicate Content-Security-Policy directive '"_s, name, "'.\n"_s));
}

void ContentSecurityPolicy::reportInvalidPluginTypes(const String& pluginType) const
{
    String message;
    if (pluginType.isNull())
        message = "'plugin-types' Content Security Policy directive is empty; all plugins will be blocked.\n"_s;
    else
        message = makeString("Invalid plugin type in 'plugin-types' Content Security Policy directive: '"_s, pluginType, "'.\n"_s);
    logToConsole(message);
}

void ContentSecurityPolicy::reportInvalidTrustedTypesPolicy(const String& policyName) const
{
    String message = makeString("Invalid policy name in 'trusted-types' Content Security Policy directive: '"_s, policyName, "'.\n"_s);
    logToConsole(message);
}

void ContentSecurityPolicy::reportInvalidTrustedTypesNoneKeyword() const
{
    String message = "Invalid policy name in 'trusted-types' Content Security Policy directive: 'none'. Note that 'none' has no effect unless it is the only expression.\n"_s;
    logToConsole(message);
}

void ContentSecurityPolicy::reportInvalidTrustedTypesSinkGroup(const String& sinkGroup) const
{
    String message = makeString("Invalid sink group in 'require-trusted-types-for' Content Security Policy directive: '"_s, sinkGroup, "'.\n"_s);
    logToConsole(message);
}

void ContentSecurityPolicy::reportEmptyRequireTrustedTypesForDirective() const
{
    String message = "'require-trusted-types-for' Content Security Policy directive is empty; The directive has no effect.\n"_s;
    logToConsole(message);
}

void ContentSecurityPolicy::reportInvalidSandboxFlags(const String& invalidFlags) const
{
    logToConsole(makeString("Error while parsing the 'sandbox' Content Security Policy directive: "_s, invalidFlags));
}

void ContentSecurityPolicy::reportInvalidDirectiveInReportOnlyMode(const String& directiveName) const
{
    logToConsole(makeString("The Content Security Policy directive '"_s, directiveName, "' is ignored when delivered in a report-only policy."_s));
}

void ContentSecurityPolicy::reportInvalidDirectiveInHTTPEquivMeta(const String& directiveName) const
{
    logToConsole(makeString("The Content Security Policy directive '"_s, directiveName, "' is ignored when delivered via an HTML meta element."_s));
}

void ContentSecurityPolicy::reportInvalidDirectiveValueCharacter(const String& directiveName, const String& value) const
{
    logToConsole(makeString("The value for Content Security Policy directive '"_s, directiveName, "' contains an invalid character: '"_s, value, "'. Non-whitespace characters outside ASCII 0x21-0x7E must be percent-encoded, as described in RFC 3986, section 2.1: http://tools.ietf.org/html/rfc3986#section-2.1."_s));
}

void ContentSecurityPolicy::reportInvalidPathCharacter(const String& directiveName, const String& value, const char invalidChar) const
{
    ASSERT(invalidChar == '#' || invalidChar == '?');

    ASCIILiteral ignoring = [&] {
        if (invalidChar == '?')
            return "The query component, including the '?', will be ignored."_s;
        return "The fragment identifier, including the '#', will be ignored."_s;
    }();
    logToConsole(makeString("The source list for Content Security Policy directive '"_s, directiveName, "' contains a source with an invalid path: '"_s, value, "'. "_s, ignoring));
}

void ContentSecurityPolicy::reportInvalidSourceExpression(const String& directiveName, const String& source) const
{
    logToConsole(makeString("The source list for Content Security Policy directive '"_s, directiveName, "' contains an invalid source: '"_s, source, "'. It will be ignored."_s,
        equalLettersIgnoringASCIICase(source, "'none'"_s) ? " Note that 'none' has no effect unless it is the only expression in the source list."_s : ""_s));
}

void ContentSecurityPolicy::reportMissingReportURI(const String& policy) const
{
    logToConsole(makeString("The Content Security Policy '"_s, policy, "' was delivered in report-only mode, but does not specify a 'report-uri'; the policy will have no effect. Please either add a 'report-uri' directive, or deliver the policy via the 'Content-Security-Policy' header."_s));
}

void ContentSecurityPolicy::reportMissingReportToTokens(const String& policy) const
{
    logToConsole(makeString("The Content Security Policy '"_s, policy, "' was delivered in report-only mode, but does not specify a 'report-to'; the policy will have no effect. Please either add a 'report-to' directive, or deliver the policy via the 'Content-Security-Policy' header."_s));
}
#endif

void ContentSecurityPolicy::logToConsole(const String& message, const String& contextURL, const OrdinalNumber& contextLine, const OrdinalNumber& contextColumn, JSC::JSGlobalObject* state) const
{
    if (message.isEmpty())
        return;

    if (!m_isReportingEnabled || !m_isReportingToConsoleEnabled)
        return;

    if (m_client)
        m_client->addConsoleMessage(MessageSource::Security, MessageLevel::Error, message, 0);
    else if (RefPtr scriptExecutionContext = m_scriptExecutionContext.get())
        scriptExecutionContext->addConsoleMessage(MessageSource::Security, MessageLevel::Error, message, contextURL, contextLine.oneBasedInt(), contextColumn.oneBasedInt(), state);
}

void ContentSecurityPolicy::reportBlockedScriptExecutionToInspector(const String& directiveText) const
{
    if (RefPtr scriptExecutionContext = m_scriptExecutionContext.get())
        InspectorInstrumentation::scriptExecutionBlockedByCSP(scriptExecutionContext.get(), directiveText);
}

void ContentSecurityPolicy::upgradeInsecureRequestIfNeeded(ResourceRequest& request, InsecureRequestType requestType, AlwaysUpgradeRequest alwaysUpgradeRequest) const
{
    URL url = request.url();
    upgradeInsecureRequestIfNeeded(url, requestType, alwaysUpgradeRequest);
    request.setURL(WTF::move(url));
}

void ContentSecurityPolicy::upgradeInsecureRequestIfNeeded(URL& url, InsecureRequestType requestType, AlwaysUpgradeRequest alwaysUpgradeRequest) const
{
    if (!url.protocolIs("http"_s) && !url.protocolIs("ws"_s))
        return;

    bool upgradeRequest = m_insecureNavigationRequestsToUpgrade.contains(SecurityOriginData::fromURL(url));
    RefPtr scriptExecutionContext = m_scriptExecutionContext.get();
    bool shouldUpgradeLocalhostAndIPAddressInMixedContext = scriptExecutionContext && scriptExecutionContext->settingsValues().iPAddressAndLocalhostMixedContentUpgradeTestingEnabled;

    if (requestType == InsecureRequestType::Load || requestType == InsecureRequestType::FormSubmission)
        upgradeRequest |= m_upgradeInsecureRequests;

    if (!upgradeRequest && alwaysUpgradeRequest == AlwaysUpgradeRequest::No)
        return;

    ShouldUpgradeLocalhostAndIPAddress shouldUpgradeLocalhostAndIPAddress = (upgradeRequest || shouldUpgradeLocalhostAndIPAddressInMixedContext) ? ShouldUpgradeLocalhostAndIPAddress::Yes : ShouldUpgradeLocalhostAndIPAddress::No;
    std::optional<uint16_t> upgradePort;
    if (RefPtr document = dynamicDowncast<Document>(scriptExecutionContext.get()); document && document->page()) {
        auto portsForUpgradingInsecureScheme = document->page()->portsForUpgradingInsecureSchemeForTesting();
        if (portsForUpgradingInsecureScheme) {
            if (url.port() == portsForUpgradingInsecureScheme->first)
                upgradePort = portsForUpgradingInsecureScheme->second;
        }
    }
    ResourceRequest::upgradeInsecureRequestIfNeeded(url, shouldUpgradeLocalhostAndIPAddress, upgradePort);
}

void ContentSecurityPolicy::setUpgradeInsecureRequests(bool upgradeInsecureRequests)
{
    m_upgradeInsecureRequests = upgradeInsecureRequests;
    if (!m_upgradeInsecureRequests)
        return;

    RefPtr scriptExecutionContext = m_scriptExecutionContext.get();
    if (!scriptExecutionContext)
        return;

    // Store the upgrade domain as an 'insecure' protocol so we can quickly identify
    // origins we should upgrade.
    URL upgradeURL = scriptExecutionContext->url();
    if (upgradeURL.protocolIs("https"_s))
        upgradeURL.setProtocol("http"_s);
    else if (upgradeURL.protocolIs("wss"_s))
        upgradeURL.setProtocol("ws"_s);
    
    m_insecureNavigationRequestsToUpgrade.add(SecurityOriginData::fromURL(upgradeURL));
    notifyInsecureNavigationRequestsToUpgradeChanged();
}

void ContentSecurityPolicy::inheritInsecureNavigationRequestsToUpgradeFromOpener(const ContentSecurityPolicy& other)
{
    m_insecureNavigationRequestsToUpgrade.addAll(other.m_insecureNavigationRequestsToUpgrade);
    notifyInsecureNavigationRequestsToUpgradeChanged();
}

HashSet<SecurityOriginData> ContentSecurityPolicy::takeNavigationRequestsToUpgrade()
{
    return WTF::move(m_insecureNavigationRequestsToUpgrade);
}

void ContentSecurityPolicy::setInsecureNavigationRequestsToUpgrade(HashSet<SecurityOriginData>&& insecureNavigationRequests)
{
    m_insecureNavigationRequestsToUpgrade = WTF::move(insecureNavigationRequests);
    notifyInsecureNavigationRequestsToUpgradeChanged();
}

void ContentSecurityPolicy::notifyInsecureNavigationRequestsToUpgradeChanged() const
{
    RefPtr document = dynamicDowncast<Document>(m_scriptExecutionContext.get());
    if (!document)
        return;
    if (!document->settings().siteIsolationEnabled())
        return;
    RefPtr frame = document->frame();
    if (!frame)
        return;
    frame->loader().client().dispatchDidChangeCSPOriginsThatUpgradeInsecureNavigations(m_insecureNavigationRequestsToUpgrade);
}

const HashAlgorithmSetCollection& ContentSecurityPolicy::hashesToReport()
{
    if (m_hashesToReport.isEmpty()) {
        Vector<std::pair<HashAlgorithmSet, FixedVector<String>>> hashesToReport;
#if !USE_SWIFT_CONTENT_SECURITY_POLICY
        for (auto& policy : m_policies) {
            if (auto hash = policy->reportHash())
                hashesToReport.append(std::make_pair(hash, policy->reportToTokens()));
        }
#else
        for (unsigned i = 0, count = m_swiftDirectives->directives.policyCount(); i < count; ++i) {
            if (auto hash = m_swiftDirectives->directives.policyReportHash(i))
                hashesToReport.append({ hash, FixedVector<String>::createWithSizeFromGenerator(m_swiftDirectives->directives.policyReportToTokenCount(i), [&](size_t j) { return m_swiftDirectives->directives.policyReportToToken(i, static_cast<unsigned>(j)); }) });
        }
#endif
        m_hashesToReport = WTF::move(hashesToReport);
    }
    return m_hashesToReport;
}

const String& ContentSecurityPolicy::selfProtocolForTesting() const
{
    return selfProtocol();
}

bool ContentSecurityPolicy::upgradeInsecureRequestsForTesting() const
{
    return upgradeInsecureRequests();
}

const HashSet<SecurityOriginData>& ContentSecurityPolicy::insecureNavigationRequestsToUpgradeForTesting() const
{
    return insecureNavigationRequestsToUpgrade();
}

void ContentSecurityPolicy::setDocumentURLForTesting(URL& documentURL)
{
    setDocumentURL(documentURL);
}

SandboxFlags ContentSecurityPolicy::sandboxFlagsForTesting() const
{
    return sandboxFlags();
}

bool ContentSecurityPolicy::isHeaderDeliveredForTesting() const
{
    return isHeaderDelivered();
}

const String& ContentSecurityPolicy::evalErrorMessageForTesting() const
{
    return evalErrorMessage();
}

const String& ContentSecurityPolicy::webAssemblyErrorMessageForTesting() const
{
    return webAssemblyErrorMessage();
}

ContentSecurityPolicyModeForExtension ContentSecurityPolicy::contentSecurityPolicyModeForExtensionForTesting() const
{
    return contentSecurityPolicyModeForExtension();
}

void ContentSecurityPolicy::setIsReportingToConsoleEnabledForTesting(bool value)
{
    setIsReportingToConsoleEnabled(value);
}

void ContentSecurityPolicy::setIsReportingEnabledForTesting(bool value)
{
    setIsReportingEnabled(value);
}

#if USE_SWIFT_CONTENT_SECURITY_POLICY
void ContentSecurityPolicyCallbacks::logToConsole(String message)
{
    contentSecurityPolicySwiftScope().policy->logToConsole(message);
}

String ContentSecurityPolicyCallbacks::enforceSandboxPolicy(String policy)
{
    String invalidTokens;
    contentSecurityPolicySwiftScope().sandboxFlags.add(SecurityContext::parseSandboxPolicy(policy, invalidTokens));
    return invalidTokens;
}

bool ContentSecurityPolicyCallbacks::isPublicSuffix(String host)
{
    return PublicSuffixStore::singleton().isPublicSuffix(host);
}

bool ContentSecurityPolicyCallbacks::isLocalHostOrLoopbackIPAddress(String host)
{
    return SecurityOrigin::isLocalHostOrLoopbackIPAddress(host);
}

bool ContentSecurityPolicyCallbacks::decodedPathSegmentsMatch(String a, String b)
{
    return PAL::decodeURLEscapeSequences(a) == PAL::decodeURLEscapeSequences(b);
}

uint16_t ContentSecurityPolicyCallbacks::defaultPort(bool isSecure)
{
    return WTF::defaultPortForProtocol(isSecure ? "https"_s : "http"_s).value_or(isSecure ? 443 : 80);
}

// The text between a hash-source's quotes: hash-algorithm "-" base64-value, whose value is at most maximumDigestLength
// bytes. Anything else gives a digest with no algorithm.
ContentSecurityPolicyDigest ContentSecurityPolicyCallbacks::parseHashSource(String source)
{
    return readCharactersForParsing(source, [](auto buffer) {
        auto digest = parseCryptographicDigest(buffer);
        if (!digest || !buffer.atEnd() || digest->value.size() > ContentSecurityPolicyHash::maximumDigestLength)
            return ContentSecurityPolicyDigest { };
        return contentSecurityPolicyDigest(*digest);
    });
}

ContentSecurityPolicyDigest ContentSecurityPolicyCallbacks::integrityDigest(unsigned index)
{
    return contentSecurityPolicyDigest(contentSecurityPolicySwiftScope().subresourceIntegrityDigests.at(index));
}

bool ContentSecurityPolicyCallbacks::frameAncestorURL(unsigned index, String& url, ContentSecurityPolicyURLBounds& bounds)
{
    auto& scope = contentSecurityPolicySwiftScope();
    RefPtr<SecurityOrigin> origin = scope.ancestorOrigins && index < scope.ancestorOrigins->size() ? scope.ancestorOrigins->at(index).ptr() : nullptr;
    for (Ref localFrame : ancestorFrames<LocalFrame>(scope.frame.get())) {
        if (!index--) {
            origin = &protect(localFrame->document())->securityOrigin();
            break;
        }
    }
    if (!origin)
        return false;
    URL ancestorURL { URL { }, origin->toString() };
    bounds = contentSecurityPolicyURLBounds(ancestorURL);
    url = ancestorURL.string();
    return true;
}

String ContentSecurityPolicyCallbacks::blockedURLForConsole()
{
    return contentSecurityPolicySwiftScope().consoleURL.stringCenterEllipsizedToLength();
}

void ContentSecurityPolicyCallbacks::reportViolation(const String& directive, const String& header, bool isReportOnly, bool shouldReportSample, std::span<const String> reportToTokens NOESCAPE, std::span<const String> reportURIs NOESCAPE, const String& consoleMessage, const String& sample, const String& directiveTextForInspector)
{
    auto& scope = contentSecurityPolicySwiftScope();
    ContentSecurityPolicy::SwiftViolatedPolicy violatedPolicy { header, isReportOnly, shouldReportSample, reportToTokens, reportURIs };
    auto sourcePosition = scope.sourcePosition;
    scope.policy->reportViolation(directive, violatedPolicy, scope.blockedURL, consoleMessage, scope.sourceURL, sample.isNull() ? scope.sourceContent.left(40) : StringView { sample }, WTF::move(sourcePosition), scope.globalObject, scope.preRedirectURL, scope.element.get());
    if (!directiveTextForInspector.isNull())
        scope.policy->reportBlockedScriptExecutionToInspector(directiveTextForInspector);
}
#endif
}
