/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
#include "ResourceCryptographicDigest.h"

#include "SharedBuffer.h"
#include <pal/crypto/CryptoDigest.h>

namespace WebCore {

NODELETE static PAL::Crypto::CryptoDigest::Algorithm toCryptoDigestAlgorithm(ResourceCryptographicDigest::Algorithm algorithm)
{
    switch (algorithm) {
    case ResourceCryptographicDigest::Algorithm::SHA256:
        return PAL::Crypto::CryptoDigest::Algorithm::SHA_256;
    case ResourceCryptographicDigest::Algorithm::SHA384:
        return PAL::Crypto::CryptoDigest::Algorithm::SHA_384;
    case ResourceCryptographicDigest::Algorithm::SHA512:
        return PAL::Crypto::CryptoDigest::Algorithm::SHA_512;
    }
    ASSERT_NOT_REACHED();
    return PAL::Crypto::CryptoDigest::Algorithm::SHA_512;
}

ResourceCryptographicDigest cryptographicDigestForBytes(ResourceCryptographicDigest::Algorithm algorithm, std::span<const uint8_t> bytes)
{
    auto cryptoDigest = PAL::Crypto::CryptoDigest::create(toCryptoDigestAlgorithm(algorithm));
    cryptoDigest->addBytes(bytes);
    return { algorithm, cryptoDigest->computeHash() };
}

ResourceCryptographicDigest cryptographicDigestForSharedBuffer(ResourceCryptographicDigest::Algorithm algorithm, const FragmentedSharedBuffer* buffer)
{
    auto cryptoDigest = PAL::Crypto::CryptoDigest::create(toCryptoDigestAlgorithm(algorithm));
    if (buffer) {
        buffer->forEachSegment([&](auto segment) {
            cryptoDigest->addBytes(segment);
        });
    }
    return { algorithm, cryptoDigest->computeHash() };
}

}
