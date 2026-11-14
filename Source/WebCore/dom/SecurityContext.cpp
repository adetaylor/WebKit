/*
 * Copyright (C) 2011 Google Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY GOOGLE, INC. ``AS IS'' AND ANY
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
 *
 */

#include "config.h"
#include "SecurityContext.h"

#include "ContentSecurityPolicy.h"
#include "IntegrityPolicy.h"
#include "PolicyContainer.h"
#include "SecurityOrigin.h"
#include "SecurityOriginPolicy.h"
#include "WebCore-Swift.h"

namespace WebCore {

SecurityContext::SecurityContext() = default;

SecurityContext::~SecurityContext() = default;

void SecurityContext::setSecurityOriginPolicy(RefPtr<SecurityOriginPolicy>&& securityOriginPolicy)
{
    auto currentOrigin = securityOrigin() ? securityOrigin()->data() : SecurityOriginData { };
    bool haveInitializedSecurityOrigin = std::exchange(m_haveInitializedSecurityOrigin, true);

    m_securityOriginPolicy = WTF::move(securityOriginPolicy);
    m_hasEmptySecurityOriginPolicy = false;

    auto origin = securityOrigin() ? securityOrigin()->data() : SecurityOriginData { };
    if (!haveInitializedSecurityOrigin || currentOrigin != origin)
        securityOriginDidChange();
}

void SecurityContext::setSecurityOriginPolicyAndEmptyContentSecurityPolicy(RefPtr<SecurityOriginPolicy>&& securityOriginPolicy)
{
    ASSERT(!m_securityOriginPolicy);
    ASSERT(!m_contentSecurityPolicy);
    m_hasEmptyContentSecurityPolicy = true;
    if (securityOriginPolicy) {
        setSecurityOriginPolicy(WTF::move(securityOriginPolicy));
        return;
    }
    m_haveInitializedSecurityOrigin = true;
    m_hasEmptySecurityOriginPolicy = true;
}

SUPPRESS_NODELETE ContentSecurityPolicy* SecurityContext::contentSecurityPolicy()
{
    if (!m_contentSecurityPolicy && m_hasEmptyContentSecurityPolicy)
        m_contentSecurityPolicy = makeEmptyContentSecurityPolicy();
    return m_contentSecurityPolicy.get();
}

SecurityOrigin* SecurityContext::securityOrigin() const
{
    RefPtr policy = securityOriginPolicy();
    if (!policy)
        return nullptr;
    return &policy->origin();
}

SecurityOriginPolicy* SecurityContext::securityOriginPolicy() const
{
    if (!m_securityOriginPolicy && m_hasEmptySecurityOriginPolicy)
        const_cast<SecurityContext&>(*this).m_securityOriginPolicy = SecurityOriginPolicy::create(SecurityOrigin::createOpaque());
    return m_securityOriginPolicy.get();
}

void SecurityContext::setContentSecurityPolicy(std::unique_ptr<ContentSecurityPolicy>&& contentSecurityPolicy)
{
    m_contentSecurityPolicy = WTF::move(contentSecurityPolicy);
    m_hasEmptyContentSecurityPolicy = false;
}

bool SecurityContext::isSecureTransitionTo(const URL& url) const
{
    // If we haven't initialized our security origin by now, this is probably
    // a new window created via the API (i.e., that lacks an origin and lacks
    // a place to inherit the origin from).
    if (!haveInitializedSecurityOrigin())
        return true;

    return protect(securityOriginPolicy()->origin())->isSameOriginDomain(SecurityOrigin::create(url).get());
}

void SecurityContext::enforceSandboxFlags(SandboxFlags flags, SandboxFlagsSource source)
{
    if (source != SandboxFlagsSource::CSP)
        m_creationSandboxFlags.add(flags);
    m_sandboxFlags.add(flags);

    // The SandboxFlag::Origin is stored redundantly in the security origin.
    if (isSandboxed(SandboxFlag::Origin) && securityOriginPolicy() && !securityOriginPolicy()->origin().isOpaque())
        setSecurityOriginPolicy(SecurityOriginPolicy::create(SecurityOrigin::createOpaque()));
}

bool SecurityContext::isSupportedSandboxPolicy(StringView policy)
{
    return policy.is8Bit() ? isSupportedSandboxPolicy8(policy.span8()) : isSupportedSandboxPolicy16(policy.span16());
}

SandboxFlags SecurityContext::parseSandboxPolicy(StringView policy, String& invalidTokensErrorMessage)
{
    // parseSandboxPolicy8() and parseSandboxPolicy16() start with every bit of the flags set.
    static_assert(SandboxFlags::all().toRaw() == std::numeric_limits<uint16_t>::max());
    auto result = policy.is8Bit() ? parseSandboxPolicy8(policy.span8()) : parseSandboxPolicy16(policy.span16());
    if (!result.invalidTokensErrorMessage.isNull())
        invalidTokensErrorMessage = WTF::move(result.invalidTokensErrorMessage);
    return SandboxFlags::fromRaw(result.flags);
}

void SecurityContext::setReferrerPolicy(ReferrerPolicy referrerPolicy)
{
    // Do not override existing referrer policy with the "empty string" one as the "empty string" means we should use
    // the policy defined elsewhere.
    if (referrerPolicy == ReferrerPolicy::EmptyString)
        return;

    m_referrerPolicy = referrerPolicy;
}

PolicyContainer SecurityContext::policyContainer() const
{
    ASSERT(m_contentSecurityPolicy);
    return {
        CheckedRef { *m_contentSecurityPolicy }->responseHeaders(),
        crossOriginEmbedderPolicy(),
        crossOriginOpenerPolicy(),
        documentIsolationPolicy(),
        referrerPolicy(),
        ipAddressSpace()
    };
}

void SecurityContext::inheritPolicyContainerFrom(const PolicyContainer& policyContainer)
{
    if (!contentSecurityPolicy())
        setContentSecurityPolicy(makeUnique<ContentSecurityPolicy>(URL { }, nullptr, nullptr));

    protect(contentSecurityPolicy())->inheritHeadersFrom(policyContainer.contentSecurityPolicyResponseHeaders);
    setCrossOriginOpenerPolicy(policyContainer.crossOriginOpenerPolicy);
    setCrossOriginEmbedderPolicy(policyContainer.crossOriginEmbedderPolicy);
    setDocumentIsolationPolicy(policyContainer.documentIsolationPolicy);
    setReferrerPolicy(policyContainer.referrerPolicy);
    setIPAddressSpace(policyContainer.ipAddressSpace);
}

const IntegrityPolicy* SecurityContext::integrityPolicy() const
{
    return m_integrityPolicy.get();
}

void SecurityContext::setIntegrityPolicy(std::unique_ptr<IntegrityPolicy>&& policy)
{
    m_integrityPolicy = WTF::move(policy);
}

const IntegrityPolicy* SecurityContext::integrityPolicyReportOnly() const
{
    return m_integrityPolicyReportOnly.get();
}

void SecurityContext::setIntegrityPolicyReportOnly(std::unique_ptr<IntegrityPolicy>&& policy)
{
    m_integrityPolicyReportOnly = WTF::move(policy);
}

} // namespace WebCore
