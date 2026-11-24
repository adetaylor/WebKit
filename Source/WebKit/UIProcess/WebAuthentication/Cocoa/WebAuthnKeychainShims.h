/*
 * Copyright (C) 2018-2025 Apple Inc. All rights reserved.
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

#include <Security/Security.h>
#include <optional>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

OBJC_CLASS LAContext;
OBJC_CLASS NSError;

namespace WebKit {

// The Security calls that return their result through an out-parameter, for Swift, which cannot pass one safely.
// Each returns the result retained, or null, and sets the call's status where it returns one.
CFTypeRef copyMatchingKeychainItems(CFDictionaryRef query, OSStatus&) CF_RETURNS_RETAINED;
SecKeyRef copyIdentityPrivateKey(SecIdentityRef, OSStatus&) CF_RETURNS_RETAINED;
SecCertificateRef copyIdentityCertificate(SecIdentityRef, OSStatus&) CF_RETURNS_RETAINED;
SecTrustRef createTrustWithCertificates(CFArrayRef certificates, SecPolicyRef) CF_RETURNS_RETAINED;
// SecKeyCreateSignature: the signature's bytes go into signature, and the result is the error's description, if any.
std::optional<String> createKeySignature(SecKeyRef, SecKeyAlgorithm, CFDataRef dataToSign, Vector<uint8_t>& signature);
// SecKeyCreateRandomKey: the key, or null with the error's description in errorDescription.
SecKeyRef createWebAuthnRandomKey(CFDictionaryRef attributes, std::optional<String>& errorDescription) CF_RETURNS_RETAINED;
// SecAccessControlCreateWithFlags and SecKeyCopyExternalRepresentation: the result, or null with the error's localized
// description in error.
SecAccessControlRef createWebAuthnAccessControl(SecAccessControlCreateFlags, std::optional<String>& error) CF_RETURNS_RETAINED;
CFDataRef copyWebAuthnKeyExternalRepresentation(SecKeyRef, std::optional<String>& error) CF_RETURNS_RETAINED;
// -[LAContext canEvaluatePolicy:error:] with the biometrics policy: the error, and the result in canEvaluatePolicy.
NSError *canEvaluateBiometricsPolicy(LAContext *, bool& canEvaluatePolicy);

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
