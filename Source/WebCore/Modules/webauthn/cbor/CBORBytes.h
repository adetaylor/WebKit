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

#include <optional>
#include <span>
#include <wtf/Vector.h>

namespace cbor {

using Bytes = Vector<uint8_t>;
using ByteSpan = std::span<const uint8_t>;

enum class DecoderError {
    CBORNoError = 0,
    UnsupportedMajorType,
    UnknownAdditionalInfo,
    IncompleteCBORData,
    IncorrectMapKeyType,
    TooMuchNesting,
    InvalidUTF8,
    ExtraneousData,
    DuplicateKey,
    OutOfOrderKey,
    NonMinimalCBOREncoding,
    UnsupportedSimpleValue,
    UnsupportedFloatingPointValue,
    OutOfRangeIntegerValue,
};

constexpr int kCBORMaxDepth = 16;
constexpr size_t kCBORDefaultMaxNestingDepth = 16;

struct CanonicalReadResult {
    DecoderError error { DecoderError::CBORNoError };
    size_t bytesConsumed { 0 };
    Vector<uint8_t> canonical;
};

// Reads one data item from the start of input as the WebAuthn code reads CTAP2 messages, and writes it back in
// canonical form. Bytes after the item are ExtraneousData unless allowTrailingData is true. canonical is empty on
// an error.
WEBCORE_EXPORT CanonicalReadResult readCanonical(std::span<const uint8_t> input, int maxNestingLevel = kCBORMaxDepth, bool allowTrailingData = false);

// Writes one data item canonically: map keys in CTAP2 order, shortest heads. The item's maps may list keys in any
// order and repeat a key (the first value is kept), nested at most 64 deep. Returns nullopt when the item nests
// deeper than maxNestingLevel or cannot be read.
WEBCORE_EXPORT std::optional<Vector<uint8_t>> writeCanonical(Vector<uint8_t> item, size_t maxNestingLevel = kCBORDefaultMaxNestingDepth);

} // namespace cbor

#endif // ENABLE(WEB_AUTHN)
