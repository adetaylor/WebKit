/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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
#include "AuthenticationExtensionsClientOutputs.h"

#if ENABLE(WEB_AUTHN)

#include "CredentialPropertiesOutput.h"
#include "WebCore-Swift.h"
#include <wtf/text/Base64.h>

namespace WebCore {

std::optional<AuthenticationExtensionsClientOutputs> AuthenticationExtensionsClientOutputs::fromCBOR(const Vector<uint8_t>& buffer)
{
    return webAuthnExtensionOutputsFromCBOR(buffer.span());
}

Vector<uint8_t> AuthenticationExtensionsClientOutputs::toCBOR() const
{
    return webAuthnExtensionOutputsToCBOR(*this);
}

AuthenticationExtensionsClientOutputsJSON AuthenticationExtensionsClientOutputs::toJSON() const
{
    AuthenticationExtensionsClientOutputsJSON result;
    result.appid = appid;
    result.credProps = credProps;
    RefPtr<ArrayBuffer> blob;
    if (largeBlob) {
        blob = largeBlob->blob;
        result.largeBlob = AuthenticationExtensionsClientOutputsJSON::LargeBlobOutputsJSON {
            largeBlob->supported,
            blob ? base64URLEncodeToString(blob->span()) : nullString(),
            largeBlob->written,
        };
    }
    if (prf) {
        std::optional<AuthenticationExtensionsClientOutputsJSON::PRFValuesJSON> prfValues;
        if (prf->results) {
            prfValues = AuthenticationExtensionsClientOutputsJSON::PRFValuesJSON {
                base64URLEncodeToString(protect(prf->results->first)->span()),
                prf->results->second ? base64URLEncodeToString(protect(prf->results->second)->span()) : nullString(),
            };
        }
        result.prf = AuthenticationExtensionsClientOutputsJSON::PRFOutputsJSON {
            prf->enabled,
            WTF::move(prfValues),
        };
    }
    return result;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUTHN)
