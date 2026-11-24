/*
 * Copyright (C) 2018-2024 Apple Inc. All rights reserved.
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
#include "AuthenticatorCoordinator.h"

#if ENABLE(WEB_AUTHN)

#include "AbortSignal.h"
#include "AllAcceptedCredentialsOptions.h"
#include "AuthenticatorAssertionResponse.h"
#include "AuthenticatorAttestationResponse.h"
#include "AuthenticatorCoordinatorClient.h"
#include "AuthenticatorResponseData.h"
#include "ContentSecurityPolicy.h"
#include "CurrentUserDetailsOptions.h"
#include "DocumentPage.h"
#include "DocumentSecurityOrigin.h"
#include "FrameDestructionObserverInlines.h"
#include "JSBasicCredential.h"
#include "LocalFrameInlines.h"
#include "JSCredentialCreationOptions.h"
#include "JSCredentialRequestOptions.h"
#include "JSDOMConvertBoolean.h"
#include "JSDOMConvertInterface.h"
#include "JSDOMConvertNullable.h"
#include "JSDOMConvertRecord.h"
#include "JSDOMConvertStrings.h"
#include "JSDOMPromiseDeferred.h"
#include "JSValueInWrappedObjectInlines.h"
#include "JSWebAuthnOperationException.h"
#include "LoginStatus.h"
#include "Page.h"
#include "PermissionsPolicy.h"
#include "PublicKeyCredential.h"
#include "PublicKeyCredentialCreationOptions.h"
#include "PublicKeyCredentialRequestOptions.h"
#include "RegistrableDomain.h"
#include "RemoteFrame.h"
#include "UnknownCredentialOptions.h"
#include "WebAuthenticationConstants.h"
#include "WebAuthenticationUtils.h"
#include "WebAuthnOperationException.h"
#include "WebCore-Swift.h"
#include <pal/crypto/CryptoDigest.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AuthenticatorCoordinatorClient);

namespace AuthenticatorCoordinatorInternal {

static ScopeAndCrossOriginParent scopeAndCrossOriginParent(const Document& document)
{
    bool isSameSite = true;
    Ref origin = document.securityOrigin();
    auto url = document.url();
    std::optional<SecurityOriginData> crossOriginParent;
    for (Ref parentFrame : ancestorFrames(document.frame())) {
        RefPtr parentOrigin = parentFrame->frameDocumentSecurityOrigin();
        if (!parentOrigin || is<RemoteFrame>(parentFrame) || RegistrableDomain(parentOrigin->data()) != RegistrableDomain(origin->data()))
            isSameSite = false;
        if (parentOrigin && !origin->isSameOriginAs(*parentOrigin))
            crossOriginParent = parentOrigin->data();
    }

    if (!crossOriginParent)
        return std::pair { WebAuthn::Scope::SameOrigin, std::nullopt };
    if (isSameSite)
        return std::pair { WebAuthn::Scope::SameSite, crossOriginParent };
    return std::pair { WebAuthn::Scope::CrossOrigin, crossOriginParent };
}

} // namespace AuthenticatorCoordinatorInternal

WTF_MAKE_TZONE_ALLOCATED_IMPL(AuthenticatorCoordinator);

AuthenticatorCoordinator::AuthenticatorCoordinator(Page& page, std::unique_ptr<AuthenticatorCoordinatorClient>&& client)
    : m_page(page)
    , m_client(WTF::move(client))
{
}

AuthenticatorCoordinator::~AuthenticatorCoordinator() = default;

void AuthenticatorCoordinator::ref() const
{
    m_page->ref();
}

void AuthenticatorCoordinator::deref() const
{
    m_page->deref();
}

void AuthenticatorCoordinator::setClient(std::unique_ptr<AuthenticatorCoordinatorClient>&& client)
{
    m_client = WTF::move(client);
}

void AuthenticatorCoordinator::create(const Document& document, CredentialCreationOptions&& createOptions, RefPtr<AbortSignal>&& abortSignal, CredentialPromise&& promise)
{
    using namespace AuthenticatorCoordinatorInternal;

    Ref callerOrigin = document.securityOrigin();
    RefPtr frame = document.frame();
    ASSERT(frame);
    // The following implements https://www.w3.org/TR/webauthn-2/#createCredential as of 28 June 2022.
    // Step 1, 3, 16 are handled by the caller.
    // Step 1
    if (!createOptions.publicKey) {
        promise.reject(Exception { ExceptionCode::NotSupportedError, "Only PublicKeyCredential is supported."_s });
        return;
    }

    // Step 2.
    if (!document.isSameOriginWithAncestors()) {
        promise.reject(Exception { ExceptionCode::NotAllowedError, "The origin of the document is not the same as its ancestors."_s });
        return;
    }

    // Step 5-13. Validates the options and fills in their defaults (AuthenticatorCoordinatorValidation.swift).
    auto validated = webAuthnValidateCreationOptions(*createOptions.publicKey, callerOrigin->domain(), URL::hostIsIPAddress(callerOrigin->domain()));
    if (!validated.options) {
        promise.reject(WTF::move(validated.exception).toException());
        return;
    }
    createOptions.publicKey = WTF::move(*validated.options);
    const auto& options = createOptions.publicKey.value();

    // Step 4, 18-22.
    if (!m_client) {
        promise.reject(Exception { ExceptionCode::UnknownError, "Unknown internal error."_s });
        return;
    }

    if (RefPtr signal = createOptions.signal) {
        signal->addAlgorithm([weakThis = WeakPtr { *this }](JSC::JSValue) mutable {
            if (!weakThis)
                return;
            weakThis->m_isCancelling = true;
            weakThis->m_client->cancel([weakThis = WTF::move(weakThis)] mutable {
                if (!weakThis)
                    return;
                weakThis->m_isCancelling = false;
                if (auto queuedRequest = WTF::move(weakThis->m_queuedRequest))
                    queuedRequest();
            });
        });
    }

    auto callback = [promise = WTF::move(promise), abortSignal = WTF::move(abortSignal)](AuthenticatorResponseData&& data, AuthenticatorAttachment attachment, ExceptionData&& exception) mutable {
        if (abortSignal && abortSignal->aborted()) {
            promise.rejectType<IDLAny>(abortSignal->reason().getValue());
            return;
        }

        if (RefPtr response = AuthenticatorResponse::tryCreate(WTF::move(data), attachment)) {
            promise.resolve(PublicKeyCredential::create(response.releaseNonNull()).ptr());
            return;
        }
        ASSERT(!exception.message.isNull());
        promise.reject(exception.toException());
    };

    if (m_isCancelling) {
        m_queuedRequest = [weakThis = WeakPtr { *this }, weakFrame = WeakPtr { *frame }, createOptions = WTF::move(createOptions), callback = WTF::move(callback)] mutable {
            if (!weakThis || !weakFrame)
                return;
            const auto options = createOptions.publicKey.value();
            RefPtr frame = weakFrame.get();
            if (!frame)
                return;
            weakThis->m_client->makeCredential(*frame, options, createOptions.mediation, WTF::move(callback));
        };
        return;
    }
    // Async operations are dispatched and handled in the messenger.
    m_client->makeCredential(*frame, options, createOptions.mediation, WTF::move(callback));
}

void AuthenticatorCoordinator::discoverFromExternalSource(Document& document, CredentialRequestOptions&& requestOptions, CredentialPromise&& promise)
{
    using namespace AuthenticatorCoordinatorInternal;

    Ref callerOrigin = document.securityOrigin();
    RefPtr frame = document.frame();
    ASSERT(frame);
    // The following implements https://www.w3.org/TR/webauthn/#createCredential as of 5 December 2017.
    // Step 3, 13 are handled by the caller.
    // Step 2.
    // This implements https://www.w3.org/TR/webauthn-2/#sctn-permissions-policy
    if (!requestOptions.publicKey) {
        promise.reject(Exception { ExceptionCode::NotSupportedError, "Only PublicKeyCredential is supported."_s });
        return;
    }

    // The request will be aborted in WebAuthenticatorCoordinatorProxy if conditional mediation is not available.
    if (requestOptions.mediation != MediationRequirement::Conditional && !document.hasFocus()) {
        promise.reject(Exception { ExceptionCode::NotAllowedError, "The document is not focused."_s });
        return;
    }

    auto scopeCrossOriginParent = scopeAndCrossOriginParent(document);
    if (scopeCrossOriginParent.first != WebAuthn::Scope::SameOrigin && !PermissionsPolicy::isFeatureEnabled(PermissionsPolicy::Feature::PublickeyCredentialsGetRule, document, PermissionsPolicy::ShouldReportViolation::No)) {
        promise.reject(Exception { ExceptionCode::NotAllowedError, "The origin of the document is not the same as its ancestors."_s });
        return;
    }

    // Step 5-9. Validates the options, fills in their defaults and resolves the appid (AuthenticatorCoordinatorValidation.swift).
    auto validated = webAuthnValidateRequestOptions(*requestOptions.publicKey, callerOrigin->domain(), URL::hostIsIPAddress(callerOrigin->domain()), callerOrigin->protocol(), callerOrigin->host());
    if (!validated.options) {
        promise.reject(WTF::move(validated.exception).toException());
        return;
    }
    requestOptions.publicKey = WTF::move(*validated.options);
    const auto& options = requestOptions.publicKey.value();

    if (options.extensions && !options.extensions->crossDeviceFallbackURL.isNull()) {
        URL fallbackURL { options.extensions->crossDeviceFallbackURL };
        if (auto error = validateCrossDeviceFallbackURL(fallbackURL)) {
            promise.reject(Exception { ExceptionCode::SecurityError, String { *error } });
            return;
        }

        // The request the spec constructs for the fallback URL has an empty destination, which CSP governs with connect-src.
        if (!document.shouldBypassMainWorldContentSecurityPolicy() && !protect(document.contentSecurityPolicy())->allowConnectToSource(fallbackURL, document.currentParserSourcePosition())) {
            promise.reject(Exception { ExceptionCode::SecurityError, "The cross-device fallback URL is blocked by the Content Security Policy."_s });
            return;
        }
    }

    if (options.extensions && options.extensions->largeBlob) {
        if (!options.extensions->largeBlob->support.isEmpty()) {
            promise.reject(Exception { ExceptionCode::NotAllowedError, "Support should not be present in largeBlob for assertion."_s });
            return;
        }
        if (options.extensions->largeBlob->read && options.extensions->largeBlob->write) {
            promise.reject(Exception { ExceptionCode::NotAllowedError, "Both read and write may not be present together in largeBlob."_s });
            return;
        }
    }

    // Step 4, 14-19.
    if (!m_client) {
        promise.reject(Exception { ExceptionCode::UnknownError, "Unknown internal error."_s });
        return;
    }

    if (RefPtr signal = requestOptions.signal) {
        signal->addAlgorithm([weakThis = WeakPtr { *this }](JSC::JSValue) mutable {
            if (!weakThis)
                return;
            weakThis->m_isCancelling = true;
            weakThis->m_client->cancel([weakThis = WTF::move(weakThis)] mutable {
                if (!weakThis)
                    return;
                weakThis->m_isCancelling = false;
                if (auto queuedRequest = WTF::move(weakThis->m_queuedRequest))
                    queuedRequest();
            });
        });
    }

    auto callback = [weakThis = WeakPtr { *this }, promise = WTF::move(promise), abortSignal = WTF::move(requestOptions.signal), weakPage = WeakPtr { document.page() }] (AuthenticatorResponseData&& data, AuthenticatorAttachment attachment, ExceptionData&& exception) mutable {
        if (abortSignal && abortSignal->aborted()) {
            promise.rejectType<IDLAny>(abortSignal->reason().getValue());
            return;
        }

        if (data.operationError) {
            promise.rejectType<IDLInterface<WebAuthnOperationException>>(WebAuthnOperationException::create(*data.operationError, exception.message));
            return;
        }

        if (auto response = AuthenticatorResponse::tryCreate(WTF::move(data), attachment)) {
            if (RefPtr page = weakPage.get())
                page->setLastAuthentication(LoginStatus::AuthenticationType::WebAuthn);
            promise.resolve(PublicKeyCredential::create(response.releaseNonNull()).ptr());
            return;
        }
        ASSERT(!exception.message.isNull());
        promise.reject(exception.toException());
    };

    if (m_isCancelling) {
        m_queuedRequest = [weakThis = WeakPtr { *this }, weakFrame = WeakPtr { *frame }, requestOptions = WTF::move(requestOptions), scopeCrossOriginParent, callback = WTF::move(callback)] mutable {
            if (!weakThis || !weakFrame)
                return;
            const auto options = requestOptions.publicKey.value();
            RefPtr frame = weakFrame.get();
            if (!frame)
                return;
            weakThis->m_client->getAssertion(*frame, options, requestOptions.mediation, scopeCrossOriginParent, WTF::move(callback));
        };
        return;
    }
    // Async operations are dispatched and handled in the messenger.
    m_client->getAssertion(*frame, options, requestOptions.mediation, scopeCrossOriginParent, WTF::move(callback));
}

void AuthenticatorCoordinator::isUserVerifyingPlatformAuthenticatorAvailable(const Document& document, DOMPromiseDeferred<IDLBoolean>&& promise) const
{
    // The following implements https://www.w3.org/TR/webauthn/#isUserVerifyingPlatformAuthenticatorAvailable
    // as of 5 December 2017.
    if (!m_client)  {
        promise.reject(Exception { ExceptionCode::UnknownError, "Unknown internal error."_s });
        return;
    }

    // FIXME(182767): We should consider more on the assessment of the return value. Right now, we return true/false
    // immediately according to platform specific procedures.
    auto completionHandler = [promise = WTF::move(promise)] (bool result) mutable {
        promise.resolve(result);
    };

    // Async operation are dispatched and handled in the messenger.
    m_client->isUserVerifyingPlatformAuthenticatorAvailable(protect(document.securityOrigin()).get(), WTF::move(completionHandler));
}


void AuthenticatorCoordinator::isConditionalMediationAvailable(const Document& document, DOMPromiseDeferred<IDLBoolean>&& promise) const
{
    if (!m_client) {
        promise.reject(Exception { ExceptionCode::UnknownError, "Unknown internal error."_s });
        return;
    }

    auto completionHandler = [promise = WTF::move(promise)](bool result) mutable {
        promise.resolve(result);
    };
    // Async operations are dispatched and handled in the messenger.
    m_client->isConditionalMediationAvailable(protect(document.securityOrigin()).get(), WTF::move(completionHandler));
}

void AuthenticatorCoordinator::getClientCapabilities(const Document& document, DOMPromiseDeferred<PublicKeyCredentialClientCapabilities>&& promise) const
{
    if (!m_client)  {
        promise.reject(Exception { ExceptionCode::UnknownError, "Unknown internal error."_s });
        return;
    }

    auto completionHandler = [promise = WTF::move(promise)] (const Vector<KeyValuePair<String, bool>> result) mutable {
        promise.resolve(result);
    };

    m_client->getClientCapabilities(protect(document.securityOrigin()).get(), WTF::move(completionHandler));
}

void AuthenticatorCoordinator::signalUnknownCredential(const Document& document, UnknownCredentialOptions&& options, DOMPromiseDeferred<void>&& promise)
{
    if (!m_client) {
        promise.reject(Exception { ExceptionCode::UnknownError, "Web Authentication client not present."_s });
        return;
    }
    Ref securityOrigin = document.securityOrigin();
    if (RegistrableDomain::uncheckedCreateFromHost(options.rpId) != RegistrableDomain { securityOrigin->data() }) {
        promise.reject(Exception { ExceptionCode::SecurityError, "The origin of the document is not authorized for the provided RP ID."_s });
        return;
    }

    auto completionHandler = [promise = WTF::move(promise)] (std::optional<WebCore::ExceptionData> error) mutable {
        if (error) {
            promise.reject(error->toException());
            return;
        }
        promise.resolve();
    };
    m_client->signalUnknownCredential(securityOrigin.get(), WTF::move(options), WTF::move(completionHandler));
}

void AuthenticatorCoordinator::signalAllAcceptedCredentials(const Document& document, AllAcceptedCredentialsOptions&& options, DOMPromiseDeferred<void>&& promise)
{
    if (!m_client)  {
        promise.reject(Exception { ExceptionCode::UnknownError, "Web Authentication client not present."_s });
        return;
    }
    Ref securityOrigin = document.securityOrigin();
    if (RegistrableDomain::uncheckedCreateFromHost(options.rpId) != RegistrableDomain { securityOrigin->data() }) {
        promise.reject(Exception { ExceptionCode::SecurityError, "The origin of the document is not authorized for the provided RP ID."_s });
        return;
    }

    auto completionHandler = [promise = WTF::move(promise)] (std::optional<WebCore::ExceptionData> error) mutable {
        if (error) {
            promise.reject(error->toException());
            return;
        }
        promise.resolve();
    };
    m_client->signalAllAcceptedCredentials(securityOrigin.get(), WTF::move(options), WTF::move(completionHandler));
}

void AuthenticatorCoordinator::signalCurrentUserDetails(const Document& document, CurrentUserDetailsOptions&& options, DOMPromiseDeferred<void>&& promise)
{
    if (!m_client)  {
        promise.reject(Exception { ExceptionCode::UnknownError, "Web Authentication client not present."_s });
        return;
    }
    Ref securityOrigin = document.securityOrigin();
    if (RegistrableDomain::uncheckedCreateFromHost(options.rpId) != RegistrableDomain { securityOrigin->data() }) {
        promise.reject(Exception { ExceptionCode::SecurityError, "The origin of the document is not authorized for the provided RP ID."_s });
        return;
    }

    auto completionHandler = [promise = WTF::move(promise)] (std::optional<WebCore::ExceptionData> error) mutable {
        if (error) {
            promise.reject(error->toException());
            return;
        }
        promise.resolve();
    };
    m_client->signalCurrentUserDetails(securityOrigin.get(), WTF::move(options), WTF::move(completionHandler));
}

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
