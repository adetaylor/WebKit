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
#include "ContentSecurityPolicyHash.h"
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
#include "ContentSecurityPolicySwift.h"
#include "DocumentSecurityOrigin.h"
#include "LocalFrameInlines.h"
#include "PublicSuffixStore.h"
#include "WebCore-Swift.h"
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

static_assert(!static_cast<uint8_t>(AllowTrustedTypePolicy::Allowed) && static_cast<uint8_t>(AllowTrustedTypePolicy::DisallowedName) == 1 && static_cast<uint8_t>(AllowTrustedTypePolicy::DisallowedDuplicateName) == 2);
static_assert(!static_cast<uint8_t>(ContentSecurityPolicyHeaderType::Report) && static_cast<uint8_t>(ContentSecurityPolicyHeaderType::Enforce) == 1);
static_assert(!static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::API) && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::HTTPEquivMeta) == 1 && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::HTTPHeader) == 2 && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::Inherited) == 3 && static_cast<uint8_t>(ContentSecurityPolicy::PolicyFrom::InheritedForPluginDocument) == 4);
static_assert(!static_cast<uint8_t>(ContentSecurityPolicyModeForExtension::None) && static_cast<uint8_t>(ContentSecurityPolicyModeForExtension::ManifestV2) == 1 && static_cast<uint8_t>(ContentSecurityPolicyModeForExtension::ManifestV3) == 2);
static_assert(static_cast<uint8_t>(ResourceCryptographicDigest::Algorithm::SHA256) == 1 && static_cast<uint8_t>(ResourceCryptographicDigest::Algorithm::SHA384) == 2 && static_cast<uint8_t>(ResourceCryptographicDigest::Algorithm::SHA512) == 4);
static_assert(ResourceCryptographicDigest::maximumDigestLength == sizeof(ContentSecurityPolicyDigest::words));
#if !ENABLE(APPLICATION_MANIFEST)
#error "Content Security Policy needs ENABLE(APPLICATION_MANIFEST): the Swift directive names include manifest-src"
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

ContentSecurityPolicy::ContentSecurityPolicy(URL&& protectedURL, ContentSecurityPolicyClient* client, ReportingClient* reportingClient)
    : m_client { client }
    , m_reportingClient { reportingClient }
    , m_protectedURL { WTF::move(protectedURL) }
    , m_swiftDirectives { makeUnique<SwiftDirectives>(ContentSecurityPolicyDirectiveListVector::init()) }
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
    , m_swiftDirectives { makeUnique<SwiftDirectives>(ContentSecurityPolicyDirectiveListVector::init()) }
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
    ASSERT(m_swiftDirectives->directives.isEmpty());
    m_contentSecurityPolicyModeForExtension = other->m_contentSecurityPolicyModeForExtension;
    m_sandboxFlags = other->m_sandboxFlags;
    for (unsigned i = 0, count = other->m_swiftDirectives->directives.policyCount(); i < count; ++i)
        didReceiveHeader(other->m_swiftDirectives->directives.policyHeader(i), static_cast<ContentSecurityPolicyHeaderType>(other->m_swiftDirectives->directives.policyHeaderType(i)), ContentSecurityPolicy::PolicyFrom::Inherited, String { });
    m_referrer = shouldMakeIsolatedCopy == ShouldMakeIsolatedCopy::Yes ? other->m_referrer.isolatedCopy() : other->m_referrer;
    m_httpStatusCode = other->m_httpStatusCode;
}

void ContentSecurityPolicy::inheritHeadersFrom(const ContentSecurityPolicyResponseHeaders& headers)
{
    if (m_hasAPIPolicy)
        return;
    ASSERT(m_swiftDirectives->directives.isEmpty());
    for (auto& [header, headerType] : headers.m_headers)
        didReceiveHeader(header, headerType, PolicyFrom::Inherited, String { });
}

void ContentSecurityPolicy::createPolicyForPluginDocumentFrom(const ContentSecurityPolicy& other)
{
    if (m_hasAPIPolicy)
        return;
    ASSERT(m_swiftDirectives->directives.isEmpty());
    for (unsigned i = 0, count = other.m_swiftDirectives->directives.policyCount(); i < count; ++i)
        didReceiveHeader(other.m_swiftDirectives->directives.policyHeader(i), static_cast<ContentSecurityPolicyHeaderType>(other.m_swiftDirectives->directives.policyHeaderType(i)), ContentSecurityPolicy::PolicyFrom::InheritedForPluginDocument, String { });
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
        for (unsigned i = 0, count = m_swiftDirectives->directives.policyCount(); i < count; ++i) {
            auto header = m_swiftDirectives->directives.policyHeader(i);
            result.m_headers.append({ makeValidHTTPHeaderIfNeeded(header), static_cast<ContentSecurityPolicyHeaderType>(m_swiftDirectives->directives.policyHeaderType(i)) });
        }
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
    for (unsigned i = 0, count = other.m_swiftDirectives->directives.policyCount(); i < count; ++i)
        didReceiveHeader(other.m_swiftDirectives->directives.policyHeader(i), static_cast<ContentSecurityPolicyHeaderType>(other.m_swiftDirectives->directives.policyHeaderType(i)), ContentSecurityPolicy::PolicyFrom::HTTPHeader, String { });
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
        ASSERT(m_swiftDirectives->directives.isEmpty());
        m_hasAPIPolicy = true;
    } else if (policyFrom == PolicyFrom::HTTPHeader)
        m_isHeaderDelivered = true;

    m_cachedResponseHeaders = std::nullopt;

    ContentSecurityPolicySwiftScope scope { .policy = *this };
    for (auto upgrades = scope.directives.didReceiveHeader(header, static_cast<uint8_t>(type), static_cast<uint8_t>(policyFrom), static_cast<uint8_t>(m_contentSecurityPolicyModeForExtension)); upgrades; --upgrades)
        setUpgradeInsecureRequests(true);
    enforceSandboxFlags(scope.sandboxFlags);
    addHashAlgorithmsForInlineScripts(OptionSet<ContentSecurityPolicyHashAlgorithm>::fromRaw(scope.directives.hashAlgorithmsForInlineScripts()));
    addHashAlgorithmsForInlineStylesheets(OptionSet<ContentSecurityPolicyHashAlgorithm>::fromRaw(scope.directives.hashAlgorithmsForInlineStylesheets()));
    
    if (m_scriptExecutionContext)
        applyPolicyToScriptExecutionContext();
}

void ContentSecurityPolicy::updateSourceSelf(const SecurityOrigin& securityOrigin)
{
    m_selfSourceProtocol = securityOrigin.protocol().convertToASCIILowercase();
    m_selfOrigin = { m_selfSourceProtocol, securityOrigin.host(), securityOrigin.port() };
    m_swiftDirectives->directives.updateSourceSelf(m_selfSourceProtocol, securityOrigin.host(), securityOrigin.port().value_or(0), !!securityOrigin.port());
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

    if (auto index = m_swiftDirectives->directives.lastEnforcedPolicyDisallowingEval(); index >= 0) {
        m_lastPolicyEvalDisabledErrorMessage = m_swiftDirectives->directives.evalDisabledErrorMessage(index);
        m_lastPolicyWebAssemblyDisabledErrorMessage = m_swiftDirectives->directives.webAssemblyDisabledErrorMessage(index);
    }
    bool requiresTrustedTypesForScript = m_swiftDirectives->directives.requiresTrustedTypesForScript();
    bool requiresTrustedTypesForScriptEnforced = m_swiftDirectives->directives.lastPolicyRequiringTrustedTypesForScriptIsEnforced();
    m_trustedEvalEnabled = m_trustedEvalEnabled && m_swiftDirectives->directives.trustedEvalEnabled();

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

bool ContentSecurityPolicy::allowContentSecurityPolicySourceStarToMatchAnyProtocol() const
{
    if (auto* document = dynamicDowncast<Document>(m_scriptExecutionContext.get()))
        return document->settings().allowContentSecurityPolicySourceStarToMatchAnyProtocol();
    return false;
}

static Vector<ResourceCryptographicDigest> parseSubResourceIntegrityIntoDigests(const String& subResourceIntegrity)
{
    auto encodedDigests = parseIntegrityMetadata(subResourceIntegrity);
    return WTF::compactMap(encodedDigests, [](auto& encodedDigest) {
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
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = source, .sourcePosition = TextPosition(contextLine, OrdinalNumber()), .element = element };
    return scope.directives.allowJavaScriptURLs(contentSecurityPolicyContentHashes(generateHashesForContent(source, m_hashAlgorithmsForInlineScripts)));
}

bool ContentSecurityPolicy::allowInlineEventHandlers(const String& contextURL, const OrdinalNumber& contextLine, const String& source, Element* element, bool overrideContentSecurityPolicy) const
{
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = source, .sourcePosition = TextPosition(contextLine, OrdinalNumber()), .element = element };
    return scope.directives.allowInlineEventHandlers(contentSecurityPolicyContentHashes(generateHashesForContent(source, m_hashAlgorithmsForInlineScripts)));
}

bool ContentSecurityPolicy::allowScriptWithNonce(const String& nonce, bool overrideContentSecurityPolicy) const
{
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty())
        return true;
    return m_swiftDirectives->directives.allowScriptWithNonce(nonce.trim(isASCIIWhitespace));
}

bool ContentSecurityPolicy::allowStyleWithNonce(const String& nonce, bool overrideContentSecurityPolicy) const
{
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty())
        return true;
    return m_swiftDirectives->directives.allowStyleWithNonce(nonce.trim(isASCIIWhitespace));
}

bool ContentSecurityPolicy::allowScriptForStrictDynamic(const URL& sourceURL, const URL& contextURL, const OrdinalNumber& contextLine, const String& nonce, const String& subResourceIntegrity, const StringView& scriptContent, ParserInserted parserInserted) const
{
    if (!m_swiftDirectives->directives.shouldPerformEarlyCSPCheck() || m_swiftDirectives->directives.isEmpty() || (!sourceURL.isEmpty() && LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(sourceURL.protocol())))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = sourceURL.isEmpty() ? "inline"_s : sourceURL.string(), .consoleURL = sourceURL, .sourceURL = contextURL.string(), .sourceContent = scriptContent, .sourcePosition = TextPosition(contextLine, OrdinalNumber()),
        .subresourceIntegrityDigests = parseSubResourceIntegrityIntoDigests(subResourceIntegrity) };
    return scope.directives.allowScriptForStrictDynamic(sourceURL.string(), contentSecurityPolicyURLBounds(sourceURL), nonce.trim(isASCIIWhitespace), parserInserted == ParserInserted::Yes, contentSecurityPolicyContentHashes(generateHashesForContent(scriptContent, m_hashAlgorithmsForInlineScripts)), scope.subresourceIntegrityDigests.size(), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::allowInlineScript(const String& contextURL, const TextPosition& contextPosition, StringView scriptContent, Element& element, const String& nonce, bool overrideContentSecurityPolicy) const
{
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.shouldPerformEarlyCSPCheck() || m_swiftDirectives->directives.isEmpty())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = scriptContent, .sourcePosition = contextPosition, .element = &element };
    return scope.directives.allowInlineScript(nonce.trim(isASCIIWhitespace), contentSecurityPolicyContentHashes(generateHashesForContent(scriptContent, m_hashAlgorithmsForInlineScripts)));
}

bool ContentSecurityPolicy::allowInlineStyle(const String& contextURL, const OrdinalNumber& contextLine, StringView styleContent, CheckUnsafeHashes shouldCheckUnsafeHashes, Element& element, const String& nonce, bool overrideContentSecurityPolicy) const
{
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty() || m_overrideInlineStyleAllowed)
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "inline"_s, .sourceURL = contextURL, .sourceContent = styleContent, .sourcePosition = TextPosition(contextLine, OrdinalNumber()), .element = &element };
    return scope.directives.allowInlineStyle(nonce.trim(isASCIIWhitespace), shouldCheckUnsafeHashes == CheckUnsafeHashes::Yes, contentSecurityPolicyContentHashes(generateHashesForContent(styleContent, m_hashAlgorithmsForInlineStylesheets)));
}

bool ContentSecurityPolicy::allowEval(JSC::JSGlobalObject* state, LogToConsole shouldLogToConsole, StringView codeContent, bool overrideContentSecurityPolicy) const
{
    if (m_swiftDirectives->directives.isEmpty() || overrideContentSecurityPolicy || (m_trustedEvalEnabled && requireTrustedTypesForSinkGroup("script"_s, IncludeReportOnlyPolicies::No)))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "eval"_s, .sourceContent = codeContent, .globalObject = state };
    return scope.directives.allowEval(shouldLogToConsole == LogToConsole::Yes);
}

bool ContentSecurityPolicy::allowFrameAncestors(const LocalFrame& frame, const URL& url, bool overrideContentSecurityPolicy) const
{
    if (m_swiftDirectives->directives.isEmpty() || overrideContentSecurityPolicy || &frame == &frame.tree().top() || !m_swiftDirectives->directives.hasFrameAncestorsDirective())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()), .frame = &frame };
    return scope.directives.allowFrameAncestors(allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::overridesXFrameOptions() const
{
    return m_swiftDirectives->directives.overridesXFrameOptions();
}

bool ContentSecurityPolicy::allowFrameAncestors(const Vector<Ref<SecurityOrigin>>& ancestorOrigins, const URL& url, bool overrideContentSecurityPolicy) const
{
    if (m_swiftDirectives->directives.isEmpty() || overrideContentSecurityPolicy || ancestorOrigins.isEmpty() || !m_swiftDirectives->directives.hasFrameAncestorsDirective())
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()), .ancestorOrigins = &ancestorOrigins };
    return scope.directives.allowFrameAncestors(allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::allowPluginType(const String&, const String&, const URL&, bool) const
{
    // The 'plugin-types' directive was removed from the CSP specification and is no longer
    // enforced. See https://github.com/w3c/webappsec-csp/issues/424
    return true;
}

bool ContentSecurityPolicy::allowObjectFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    // Report deprecation of 'plugin-types' when an object/embed element is used
    if (m_swiftDirectives->directives.hasPluginTypesDirective())
        reportDeprecatedDirective("plugin-types"_s);

    return allowResourceFromSource(url.isEmpty() ? m_protectedURL : url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowObjectFromSource, preRedirectURL);
}

bool ContentSecurityPolicy::allowChildFrameFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived) const
{
    if (url.protocolIsJavaScript())
        return true;
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowChildFrameFromSource);
}

template<typename Check>
bool ContentSecurityPolicy::allowResourceFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, Check check, const URL& preRedirectURL) const
{
    if (m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = (!preRedirectURL.isNull() ? preRedirectURL : url).string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition) };
    return (scope.directives.*check)(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::allowWorkerFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowWorkerFromSource, preRedirectURL);
}

bool ContentSecurityPolicy::allowScriptFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL, const String& subResourceIntegrity, const String& nonce) const
{
    if (m_swiftDirectives->directives.isEmpty() || m_swiftDirectives->directives.shouldPerformEarlyCSPCheck() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = (!preRedirectURL.isNull() ? preRedirectURL : url).string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition), .subresourceIntegrityDigests = parseSubResourceIntegrityIntoDigests(subResourceIntegrity) };
    return scope.directives.allowScriptFromSource(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, nonce.trim(isASCIIWhitespace), scope.subresourceIntegrityDigests.size(), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::allowImageFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowImageFromSource, preRedirectURL);
}

bool ContentSecurityPolicy::allowPrefetchFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowPrefetchFromSource, preRedirectURL);
}

bool ContentSecurityPolicy::allowStyleFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL, const String& nonce) const
{
    if (m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = (!preRedirectURL.isNull() ? preRedirectURL : url).string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition) };
    return scope.directives.allowStyleFromSource(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, nonce.trim(isASCIIWhitespace), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::allowFontFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowFontFromSource, preRedirectURL);
}

#if ENABLE(APPLICATION_MANIFEST)
bool ContentSecurityPolicy::allowManifestFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowManifestFromSource, preRedirectURL);
}
#endif // ENABLE(APPLICATION_MANIFEST)

bool ContentSecurityPolicy::allowMediaFromSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowMediaFromSource, preRedirectURL);
}

bool ContentSecurityPolicy::allowConnectToSource(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    if (m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = WTF::move(sourcePosition), .preRedirectURL = preRedirectURL };
    return scope.directives.allowConnectToSource(url.string(), contentSecurityPolicyURLBounds(url), redirectResponseReceived == RedirectResponseReceived::Yes, allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

bool ContentSecurityPolicy::allowFormAction(const URL& url, std::optional<TextPosition>&& sourcePosition, RedirectResponseReceived redirectResponseReceived, const URL& preRedirectURL) const
{
    return allowResourceFromSource(url, WTF::move(sourcePosition), redirectResponseReceived, &ContentSecurityPolicyDirectiveListVector::allowFormAction, preRedirectURL);
}

bool ContentSecurityPolicy::allowBaseURI(const URL& url, bool overrideContentSecurityPolicy) const
{
    if (overrideContentSecurityPolicy || m_swiftDirectives->directives.isEmpty() || LegacySchemeRegistry::schemeShouldBypassContentSecurityPolicy(url.protocol()))
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = url.string(), .consoleURL = url, .sourceURL = String(), .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()) };
    return scope.directives.allowBaseURI(url.string(), contentSecurityPolicyURLBounds(url), allowContentSecurityPolicySourceStarToMatchAnyProtocol());
}

// https://w3c.github.io/trusted-types/dist/spec/#should-block-create-policy
AllowTrustedTypePolicy ContentSecurityPolicy::allowTrustedTypesPolicy(const String& value, bool isDuplicate) const
{
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "trusted-types-policy"_s, .sourceURL = String(), .sourceContent = value, .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()) };
    return static_cast<AllowTrustedTypePolicy>(scope.directives.allowTrustedTypesPolicy(value, isDuplicate));
}

// https://w3c.github.io/trusted-types/dist/spec/#does-sink-require-trusted-types
bool ContentSecurityPolicy::requireTrustedTypesForSinkGroup(const String& sinkGroup, IncludeReportOnlyPolicies includeReportOnlyPolicies) const
{
    return sinkGroup == "script"_s && m_swiftDirectives->directives.requireTrustedTypesForSinkGroup(includeReportOnlyPolicies == IncludeReportOnlyPolicies::Yes);
}

// https://w3c.github.io/trusted-types/dist/spec/#should-block-sink-type-mismatch
bool ContentSecurityPolicy::allowMissingTrustedTypesForSinkGroup(const String& stringContext, const String& sink, const String& sinkGroup, StringView source) const
{
    if (sinkGroup != "script"_s)
        return true;
    ContentSecurityPolicySwiftScope scope { .policy = *this, .blockedURL = "trusted-types-sink"_s, .sourceURL = nullString(), .sourceContent = source, .sourcePosition = TextPosition(OrdinalNumber::beforeFirst(), OrdinalNumber()) };
    // The longest prefix allowMissingTrustedTypesSample() strips, "async function* anonymous" (25), and the 40 characters of the sample.
    return scope.directives.allowMissingTrustedTypesForSinkGroup(stringContext, sink, source.left(65).toString());
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
    bool directiveIsSafe = violatedDirective != "frame-src"_s && violatedDirective != "object-src"_s && violatedDirective != "block-all-mixed-content"_s;
    auto securityOrigin = m_selfOrigin.securityOrigin();

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

void ContentSecurityPolicy::reportViolation(const String& effectiveViolatedDirective, const SwiftViolatedPolicy& violatedDirectiveList, const String& blockedURLString, const String& consoleMessage, const String& sourceURL, StringView sourceContent, std::optional<TextPosition>&& maybeSourcePosition, JSC::JSGlobalObject* state, const URL& preRedirectURL, Element* element) const
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
        for (unsigned i = 0, count = m_swiftDirectives->directives.policyCount(); i < count; ++i) {
            if (auto hash = m_swiftDirectives->directives.policyReportHash(i))
                hashesToReport.append({ hash, FixedVector<String>::createWithSizeFromGenerator(m_swiftDirectives->directives.policyReportToTokenCount(i), [&](size_t j) { return m_swiftDirectives->directives.policyReportToToken(i, static_cast<unsigned>(j)); }) });
        }
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
}
