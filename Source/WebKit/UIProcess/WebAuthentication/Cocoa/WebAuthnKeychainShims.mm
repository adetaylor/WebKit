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

#import "config.h"
#import "WebAuthnKeychainShims.h"

#if ENABLE(WEB_AUTHN)

#import <wtf/RetainPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>

namespace WebKit {

CFTypeRef copyMatchingKeychainItems(CFDictionaryRef query, OSStatus& status)
{
    CFTypeRef result = nullptr;
    status = SecItemCopyMatching(query, &result);
    return result;
}

SecKeyRef copyIdentityPrivateKey(SecIdentityRef identity, OSStatus& status)
{
    SecKeyRef privateKey = nullptr;
    status = SecIdentityCopyPrivateKey(identity, &privateKey);
    return privateKey;
}

SecCertificateRef copyIdentityCertificate(SecIdentityRef identity, OSStatus& status)
{
    SecCertificateRef certificate = nullptr;
    status = SecIdentityCopyCertificate(identity, &certificate);
    return certificate;
}

SecTrustRef createTrustWithCertificates(CFArrayRef certificates, SecPolicyRef policy)
{
    SecTrustRef trust = nullptr;
    SecTrustCreateWithCertificates(certificates, policy, &trust);
    return trust;
}

std::optional<String> createKeySignature(SecKeyRef key, SecKeyAlgorithm algorithm, CFDataRef dataToSign, Vector<uint8_t>& signature)
{
    CFErrorRef rawError = nullptr;
    RetainPtr result = adoptCF(SecKeyCreateSignature(key, algorithm, dataToSign, &rawError));
    signature = makeVector(bridge_cast(result.get()));
    // FIXME: The Security framework API is missing the `CF_RETURNS_RETAINED` annotation (rdar://161546781).
    SUPPRESS_RETAINPTR_CTOR_ADOPT if (RetainPtr error = adoptCF(rawError))
        return String(bridge_cast(error.get()).localizedDescription);
    return std::nullopt;
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
