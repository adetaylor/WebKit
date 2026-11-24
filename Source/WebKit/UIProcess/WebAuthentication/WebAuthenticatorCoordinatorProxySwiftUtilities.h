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

// The Swift receiver's own types, as WebBackForwardListSwiftUtilities.h is for WebBackForwardList: the generated
// WebAuthenticatorCoordinatorProxyMessages.h (the reply and argument aliases, the forwarder) and what its handlers
// take and return.

#include "AuthenticatorManager.h"
#include "FrameInfoData.h"
#include "RelatedOriginsValidator.h"
#include "SharedPreferencesForWebProcess.h"
#include "Untrusted.h"
#include "WebAuthenticationFlags.h"
#include "WebAuthenticationRequestData.h"
#include "WebAuthenticatorCoordinatorProxy.h"
#include "WebAuthenticatorCoordinatorProxyMessages.h"
#include "WebProcessProxy.h"
#include <WebCore/AllAcceptedCredentialsOptions.h>
#include <WebCore/AuthenticationExtensionsClientOutputs.h>
#include <WebCore/AuthenticatorAttachment.h>
#include <WebCore/AuthenticatorResponseData.h>
#include <WebCore/CurrentUserDetailsOptions.h>
#include <WebCore/ExceptionData.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/MediationRequirement.h>
#include <WebCore/PublicKeyCredentialCreationOptions.h>
#include <WebCore/PublicKeyCredentialRequestOptions.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/UnknownCredentialOptions.h>
#include <WebCore/WebAuthenticationUtils.h>
#include <optional>
#include <wtf/KeyValuePair.h>
#include <wtf/MainThread.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

#if defined(__OBJC__) && HAVE(WEB_AUTHN_AS_MODERN)
#import "WebAuthnSoftLinkForSwift.h"
#import <WebKit/WKWebView.h>
#import <wtf/BlockPtr.h>
#import <wtf/RetainPtr.h>
#endif

namespace WebKit {

// WTF's Swift closure bridge takes a copyable argument by value only, so Swift makes this instance and passes it
// through makeAuthenticatorManagerCallback.
using WebAuthnRespondHandler = CompletionHandler<void(AuthenticatorManager::Respond)>;
inline AuthenticatorManager::Callback makeAuthenticatorManagerCallback(WebAuthnRespondHandler&& handler)
{
    return [handler = WTF::move(handler)](AuthenticatorManager::Respond&& respond) mutable {
        handler(WTF::move(respond));
    };
}

class WebFrameProxy;

// Swift cannot spell this template instance.
using WebAuthnClientCapabilities = Vector<KeyValuePair<String, bool>>;

// The CompletionHandler instances the Swift here makes, named so WebAuthnRequestsConformances.swift can conform them
// (each instance is one Swift type, so one conformance covers every alias of it).
using WebAuthnOptionalBoolCompletionHandler = CompletionHandler<void(std::optional<bool>)>; // requestWebAuthenticationConditonalMediationRegistration
using WebAuthnPanelResultCompletionHandler = CompletionHandler<void(WebAuthenticationPanelResult)>; // runWebAuthenticationPanel

// Swift cannot build WebAuthenticationRequestData (a Variant and optionals), and the reply's three values come back as
// one struct.
using WebAuthnOptionalSecurityOriginData = std::optional<WebCore::SecurityOriginData>;

struct WebAuthnRequestReply {
    WebCore::AuthenticatorResponseData data;
    WebCore::AuthenticatorAttachment attachment { WebCore::AuthenticatorAttachment::Platform };
    WebCore::ExceptionData exception;
};

// One per options type: Swift cannot build the request's options Variant.
inline WebAuthenticationRequestData makeWebAuthenticationRequestData(WebCore::PublicKeyCredentialCreationOptions options, WebPageProxy& page, WebCore::FrameIdentifier frameID, FrameInfoData frameInfo, WebCore::MediationRequirement mediation, WebAuthnOptionalSecurityOriginData parentOrigin)
{
    return { .options = WTF::move(options), .page = page, .globalFrameID = WebCore::GlobalFrameIdentifier { page.webPageIDInMainFrameProcess(), frameID }, .frameInfo = WTF::move(frameInfo), .mediation = mediation, .parentOrigin = WTF::move(parentOrigin) };
}

inline WebAuthenticationRequestData makeWebAuthenticationRequestData(WebCore::PublicKeyCredentialRequestOptions options, WebPageProxy& page, WebCore::FrameIdentifier frameID, FrameInfoData frameInfo, WebCore::MediationRequirement mediation, WebAuthnOptionalSecurityOriginData parentOrigin)
{
    return { .options = WTF::move(options), .page = page, .globalFrameID = WebCore::GlobalFrameIdentifier { page.webPageIDInMainFrameProcess(), frameID }, .frameInfo = WTF::move(frameInfo), .mediation = mediation, .parentOrigin = WTF::move(parentOrigin) };
}

// By value: Swift reads a const String& accessor as an unsafe pointer.
inline String webAuthnSecurityOriginDomain(const WebCore::SecurityOriginData& origin)
{
    return origin.securityOrigin()->domain();
}

// By value (Swift reads the const URL& accessor as an unsafe pointer); in WebAuthenticatorCoordinatorProxy.cpp.
URL webAuthnFrameURL(const WebFrameProxy&);
// Swift does not reach the page's API::UIClient; in WebAuthenticatorCoordinatorProxy.cpp.
void webAuthnRequestConditionalMediationRegistration(WebPageProxy&, const String& username, Vector<String> relatedOrigins, CompletionHandler<void(std::optional<bool>)>&&);

// The client data JSON for the mock and virtual paths, its scope and top origin from the parent origin: C++ reads the
// challenge in place, where Swift would copy the options.
RefPtr<JSC::ArrayBuffer> webAuthnClientDataJSONForRequest(const WebAuthenticationRequestData&, const WebCore::SecurityOriginData& callerOrigin);

// For WebAuthenticatorCoordinatorProxy+AS.swift.
inline void clearCrossDeviceFallbackURL(WebAuthenticationRequestData& data)
{
    if (auto* options = std::get_if<WebCore::PublicKeyCredentialRequestOptions>(&data.options); options && options->extensions)
        options->extensions->crossDeviceFallbackURL = nullString();
}

// Swift cannot construct the PRF results' Ref member.
inline void setPRFRegistrationOutputs(WebCore::AuthenticationExtensionsClientOutputs& outputs, bool isSupported, RefPtr<JSC::ArrayBuffer> first, RefPtr<JSC::ArrayBuffer> second)
{
    if (first)
        outputs.prf = { isSupported, { { first.releaseNonNull(), WTF::move(second) } } };
    else
        outputs.prf = { isSupported, std::nullopt };
}

inline void setPRFAssertionOutputs(WebCore::AuthenticationExtensionsClientOutputs& outputs, Ref<JSC::ArrayBuffer> first, RefPtr<JSC::ArrayBuffer> second)
{
    outputs.prf = { std::nullopt, { { WTF::move(first), WTF::move(second) } } };
}

#if defined(__OBJC__) && HAVE(WEB_AUTHN_AS_MODERN)
// Objective-C objects reach Swift in a RetainPtr, by value (an inline function returning one at +0 is over-released
// under thin LTO).
inline RetainPtr<WKWebView> webAuthnCocoaView(WebPageProxy& page)
{
    return page.cocoaView();
}

// The view's window, read on whichever thread AuthenticationServices asks for it.
inline RetainPtr<ASPresentationAnchor> webAuthnPresentationAnchor(WKWebView * _Nullable view)
{
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    return [view window];
ALLOW_DEPRECATED_DECLARATIONS_END
}

// The authorization delegate's completion, called by AuthenticationServices on a queue of its choosing: carries the
// framework's objects to the main run loop (inline when already there) and calls the main-actor block with them.
// The block is NS_SWIFT_UI_ACTOR, and ensureOnMainRunLoop is what makes that true.
struct SWIFT_PRIVATE_FILEID("WebKit/WebAuthenticatorCoordinatorProxy+AS.swift") WebAuthnAuthorizationCompletion {
private:
    static void ensureOnMainRunLoop(ASAuthorization * _Nullable authorization, NSError * _Nullable error, void (^ NS_SWIFT_UI_ACTOR _Nonnull completion)(ASAuthorization * _Nullable, NSError * _Nullable))
    {
        WTF::ensureOnMainRunLoop([completion = makeBlockPtr(completion), authorization = retainPtr(authorization), error = retainPtr(error)] {
            completion(authorization.get(), error.get());
        });
    }
};
#endif

// Swift cannot read the Respond Variant.
WebAuthnRequestReply webAuthnRequestReply(AuthenticatorManager::Respond, RefPtr<JSC::ArrayBuffer> clientDataJSON);

// The generated receiver checks EnabledBy=WebAuthenticationEnabled with the sending process's preferences.
inline OptionalSharedPreferencesForWebProcess webAuthnSharedPreferencesForWebProcess(IPC::Connection& connection)
{
    return WebProcessProxy::fromConnection(connection)->sharedPreferencesForWebProcess();
}

// GetClientCapabilities's reply entries (WebAuthenticatorCoordinatorProxy+Legacy.swift).
inline void appendWebAuthnClientCapability(WebAuthnClientCapabilities& capabilities, const String& key, bool value)
{
    capabilities.append({ key, value });
}

} // namespace WebKit

#if defined(__swift__) && HAVE(WEB_AUTHN_AS_MODERN) && USE(APPLE_INTERNAL_SDK)

// WebKitSwift's CredentialUpdaterShim (WebKitSwift/CredentialUpdaterShim.h), which the Signal* handlers message. The
// class is optional and WebKit does not link WebKitSwift, so it is looked up by name (no class symbol), and Swift
// messages it only after webAuthnCredentialUpdaterShimIsAvailable() has loaded WebKitSwift and found it. The handler
// is called once, on a queue of the shim's choosing.
NS_HEADER_AUDIT_BEGIN(nullability, sendability)

__attribute__((objc_runtime_visible))
@interface CredentialUpdaterShim : NSObject
+ (void)signalUnknownCredentialWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier credentialID:(NSData *)credentialID completionHandler:(NS_SWIFT_SENDABLE void (^)(NSError * _Nullable))completionHandler;
+ (void)signalAllAcceptedCredentialsWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier userHandle:(NSData *)userHandle acceptedCredentialIDs:(NSArray<NSData *> *)acceptedCredentialIDs completionHandler:(NS_SWIFT_SENDABLE void (^)(NSError * _Nullable))completionHandler;
+ (void)signalCurrentUserDetailsWithRelyingPartyIdentifier:(NSString *)relyingPartyIdentifier userHandle:(NSData *)userHandle newName:(NSString *)newName completionHandler:(NS_SWIFT_SENDABLE void (^)(NSError * _Nullable))completionHandler;
@end

namespace WebKit {

// WebKitSwiftSoftLink.h's getter, which loads WebKitSwift; nil when the class is absent. Shared mutable state, so
// Swift does not see it.
extern ::Class _Nullable (*getCredentialUpdaterShimClassSingleton)() NS_SWIFT_UNAVAILABLE("Use webAuthnCredentialUpdaterShimIsAvailable");

inline bool webAuthnCredentialUpdaterShimIsAvailable()
{
    return getCredentialUpdaterShimClassSingleton();
}

} // namespace WebKit

NS_HEADER_AUDIT_END(nullability, sendability)

#endif // defined(__swift__) && HAVE(WEB_AUTHN_AS_MODERN) && USE(APPLE_INTERNAL_SDK)

#endif // ENABLE(WEB_AUTHN)
