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

#include <optional>
#include <span>
#include <wtf/Forward.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {

struct NaluIndex {
    size_t startOffset { 0 };
    size_t payloadStartOffset { 0 };
    size_t payloadSize { 0 };
};

// Swift can only name Vector<NaluIndex> through this typedef.
using NaluIndexVector = Vector<NaluIndex>;

inline constexpr NaluIndex mediaParserEmptyNaluIndices[1] { };

// Borrowed for one call from C++ into Swift, like the views in MediaParsersCxxBridging.h; an empty one lends a
// zero-length span of mediaParserEmptyNaluIndices, so Swift never sees a null base.
struct SWIFT_VIEW MediaParserNaluIndices {
    std::span<const NaluIndex> indices;
    ALWAYS_INLINE std::span<const NaluIndex> span() const LIFETIME_BOUND { return indices.empty() ? std::span { mediaParserEmptyNaluIndices }.first<0>() : indices; }
};

WEBCORE_EXPORT Vector<NaluIndex> findNaluIndices(std::span<const uint8_t>);
WEBCORE_EXPORT Vector<uint8_t> parseRbsp(std::span<const uint8_t>);
WEBCORE_EXPORT Vector<uint8_t> annexBToLengthPrefixed(std::span<const uint8_t>, std::span<const NaluIndex>);

}
