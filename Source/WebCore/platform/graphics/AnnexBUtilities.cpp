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

#include "config.h"
#include "AnnexBUtilities.h"

#if ENABLE(WEBCORE_SWIFT)

#include "WebCore-Swift.h"

namespace WebCore {

// The scanning, unescaping and length prefixing are in AnnexB.swift.

Vector<NaluIndex> findNaluIndices(std::span<const uint8_t> buffer)
{
    NaluIndexVector indices;
    findNaluIndicesImpl({ buffer }, indices);
    return indices;
}

Vector<uint8_t> parseRbsp(std::span<const uint8_t> data)
{
    Vector<uint8_t> out;
    out.reserveInitialCapacity(data.size());
    parseRbspImpl({ data }, out);
    return out;
}

Vector<uint8_t> annexBToLengthPrefixed(std::span<const uint8_t> data, std::span<const NaluIndex> naluIndices)
{
    Vector<uint8_t> result;
    annexBToLengthPrefixedImpl({ data }, { naluIndices }, result);
    return result;
}

}

#endif // ENABLE(WEBCORE_SWIFT)
