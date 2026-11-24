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

#import <WebKit/_WKWebAuthenticationPanel.h>

#if ENABLE(WEB_AUTHN)

#import "APIWebAuthenticationPanel.h"
#import "WKObject.h"
#import "WebAuthenticationRequestData.h"
#import "_WKAuthenticationExtensionsClientOutputsInternal.h"
#import "_WKAuthenticatorAssertionResponseInternal.h"
#import "_WKAuthenticatorAttestationResponseInternal.h"
#import "_WKPublicKeyCredentialParameters.h"
#import <WebCore/AuthenticationExtensionsClientOutputs.h>
#import <WebCore/AuthenticatorResponse.h>
#import <WebCore/AuthenticatorResponseData.h>
#import <WebCore/ExceptionData.h>
#import <WebCore/MediationRequirement.h>
#import <WebCore/PublicKeyCredentialCreationOptions.h>
#import <WebCore/PublicKeyCredentialRequestOptions.h>
#import <wtf/AlignedStorage.h>

namespace WebKit {

template<> struct WrapperTraits<API::WebAuthenticationPanel> {
    using WrapperClass = _WKWebAuthenticationPanel;
};

}

@interface _WKWebAuthenticationPanel () <WKObject> {
@package
    AlignedStorage<API::WebAuthenticationPanel> _panel;
}
@end

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// Implemented in _WKWebAuthenticationPanel.swift; the class's @implementation, which holds the API object, forwards each public method here.
@interface _WKWebAuthenticationPanel (WKSwiftMembers)
- (NSMutableSet *)makeTransports;
- (_WKWebAuthenticationType)webAuthenticationType;
- (void)performMakeCredentialWithChallenge:(nullable NSData *)challenge origin:(nullable NSString *)origin options:(nullable _WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse * _Nullable, NSError * _Nullable))handler NS_SWIFT_DISABLE_ASYNC;
- (void)performMakeCredentialWithMediationRequirement:(_WKWebAuthenticationMediationRequirement)mediation clientDataHash:(nullable NSData *)clientDataHash options:(nullable _WKPublicKeyCredentialCreationOptions *)options completionHandler:(void (^)(_WKAuthenticatorAttestationResponse * _Nullable, NSError * _Nullable))handler NS_SWIFT_DISABLE_ASYNC;
- (void)performGetAssertionWithChallenge:(nullable NSData *)challenge origin:(nullable NSString *)origin options:(nullable _WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse * _Nullable, NSError * _Nullable))handler NS_SWIFT_DISABLE_ASYNC;
- (void)performGetAssertionWithMediationRequirement:(_WKWebAuthenticationMediationRequirement)mediation clientDataHash:(nullable NSData *)clientDataHash options:(nullable _WKPublicKeyCredentialRequestOptions *)options completionHandler:(void (^)(_WKAuthenticatorAssertionResponse * _Nullable, NSError * _Nullable))handler NS_SWIFT_DISABLE_ASYNC;
+ (void)performDeleteLocalAuthenticatorCredentialWithGroupAndID:(nullable NSString *)group credential:(nullable NSData *)credentialID;
+ (NSData *)performGetClientDataJSONWithTopOrigin:(_WKWebAuthenticationType)type challenge:(nullable NSData *)challenge origin:(nullable NSString *)origin topOrigin:(nullable NSString *)topOrigin crossOrigin:(BOOL)crossOrigin;
+ (NSData *)performEncodeMakeCredentialCommandWithClientDataJSON:(nullable NSData *)clientDataJSON options:(nullable _WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(nullable NSArray<NSString *> *)authenticatorSupportedExtensions;
+ (NSData *)performEncodeGetAssertionCommandWithClientDataJSON:(nullable NSData *)clientDataJSON options:(nullable _WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(nullable NSArray<NSString *> *)authenticatorSupportedExtensions;
+ (NSData *)performEncodeMakeCredentialCommandWithClientDataHash:(nullable NSData *)clientDataHash options:(nullable _WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(nullable NSArray<NSString *> *)authenticatorSupportedExtensions;
+ (NSData *)performEncodeMakeCredentialCommandWithClientDataHash:(nullable NSData *)clientDataHash options:(nullable _WKPublicKeyCredentialCreationOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability credentialParameters:(nullable NSArray<_WKPublicKeyCredentialParameters *> *)credentialParameters;
+ (NSData *)performEncodeGetAssertionCommandWithClientDataHash:(nullable NSData *)clientDataHash options:(nullable _WKPublicKeyCredentialRequestOptions *)options userVerificationAvailability:(_WKWebAuthenticationUserVerificationAvailability)userVerificationAvailability authenticatorSupportedExtensions:(nullable NSArray<NSString *> *)authenticatorSupportedExtensions;
@end

NS_HEADER_AUDIT_END(nullability, sendability)

namespace WebKit {

// For _WKWebAuthenticationPanel.swift: the wrapped API object, and what Swift cannot construct or
// read itself: the response Variant, and the ArrayBuffers behind a Ref or RefPtr.
inline API::WebAuthenticationPanel& webAuthenticationPanel(_WKWebAuthenticationPanel *wrapper) { return *wrapper->_panel; }
// A copy: Swift reads a LIFETIME_BOUND reference return only as an unsafe pointer.
inline Vector<WebCore::AuthenticatorTransport> webAuthenticationPanelTransports(_WKWebAuthenticationPanel *wrapper) { return wrapper->_panel->transports(); }

// One per options type: Swift cannot build the request's options Variant.
inline void webAuthenticationPanelHandleRequest(API::WebAuthenticationPanel& panel, Vector<uint8_t> hash, WebCore::PublicKeyCredentialCreationOptions options, std::optional<WebCore::MediationRequirement> mediation, API::WebAuthenticationPanel::Callback&& callback)
{
    protect(panel)->handleRequest({ .hash = WTF::move(hash), .options = WTF::move(options), .mediation = mediation }, WTF::move(callback));
}

inline void webAuthenticationPanelHandleRequest(API::WebAuthenticationPanel& panel, Vector<uint8_t> hash, WebCore::PublicKeyCredentialRequestOptions options, std::optional<WebCore::MediationRequirement> mediation, API::WebAuthenticationPanel::Callback&& callback)
{
    protect(panel)->handleRequest({ .hash = WTF::move(hash), .options = WTF::move(options), .mediation = mediation }, WTF::move(callback));
}

// The panel's option conversion, which Swift calls with the Objective-C options classes.
Vector<WebCore::PublicKeyCredentialParameters> webAuthenticationPanelCredentialParameters(NSArray<_WKPublicKeyCredentialParameters *> *);

inline bool webAuthenticationPanelResponseIsException(const API::WebAuthenticationPanel::Response& response) { return std::holds_alternative<WebCore::ExceptionData>(response); }
inline WebCore::ExceptionData webAuthenticationPanelResponseException(const API::WebAuthenticationPanel::Response& response) { return std::get<WebCore::ExceptionData>(response); }
inline WebCore::AuthenticatorResponseData webAuthenticationPanelResponseData(const API::WebAuthenticationPanel::Response& response) { return std::get<Ref<WebCore::AuthenticatorResponse>>(response)->data(); }
inline WebCore::AuthenticatorAttachment webAuthenticationPanelResponseAttachment(const API::WebAuthenticationPanel::Response& response) { return std::get<Ref<WebCore::AuthenticatorResponse>>(response)->attachment(); }
inline std::optional<Vector<uint8_t>> webAuthenticationPanelBytes(const RefPtr<JSC::ArrayBuffer>& buffer) { return buffer ? std::optional { buffer->toVector() } : std::nullopt; }
inline std::optional<Vector<uint8_t>> webAuthenticationPanelPRFFirst(const WebCore::AuthenticationExtensionsClientOutputs& outputs) { return outputs.prf && outputs.prf->results ? std::optional { outputs.prf->results->first->toVector() } : std::nullopt; }
inline std::optional<Vector<uint8_t>> webAuthenticationPanelPRFSecond(const WebCore::AuthenticationExtensionsClientOutputs& outputs) { return outputs.prf && outputs.prf->results ? webAuthenticationPanelBytes(outputs.prf->results->second) : std::nullopt; }

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
