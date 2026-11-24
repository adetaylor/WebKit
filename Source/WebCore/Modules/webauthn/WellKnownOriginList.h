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

#include <WebCore/SecurityOriginData.h>
#include <span>
#include <wtf/Forward.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

constexpr size_t defaultWellKnownMaxResourceSize = 64 * 1024;

struct WellKnownOriginListPolicy {
    size_t maxRegistrableOriginLabels { 5 };
    size_t maxCandidates { 100 };
    size_t maxResourceSize { defaultWellKnownMaxResourceSize };
};

enum class WellKnownOriginListResult : uint8_t {
    Found,
    NotFound,
    Malformed,
};

WEBCORE_EXPORT URL wellKnownURL(StringView host, StringView path);

WEBCORE_EXPORT bool isWellKnownResponseAcceptable(int httpStatusCode, StringView mimeType);

WEBCORE_EXPORT bool isWellKnownRedirectAllowed(const URL&);

WEBCORE_EXPORT WellKnownOriginListResult findOriginInWellKnownList(const SecurityOriginData& callerOrigin, std::span<const uint8_t> resource, ASCIILiteral memberName, WellKnownOriginListPolicy&& = { });

WEBCORE_EXPORT Vector<String> parseOriginsFromWellKnownList(std::span<const uint8_t> resource, ASCIILiteral memberName, WellKnownOriginListPolicy&& = { });

// What the Swift implementation of the two functions above reads a list through: it cannot walk a RefPtr<JSON::Value>
// or build a StringView, so these parse and look at one candidate each.

// Names the vector for the Swift implementation, which cannot spell a template instantiation.
using WellKnownStringVector = Vector<String>;

// One listed origin: its registrable origin label, empty when it is not a valid URL or its host has none, and the URL.
struct WellKnownCandidate {
    String label;
    URL url;

    bool isOrigin(const SecurityOriginData& origin) const { return SecurityOriginData::fromURL(url) == origin; }
};

struct WellKnownCandidates {
    // Reads the array that resource's JSON object holds as memberName. False when the resource is larger than
    // maxResourceSize, is not a JSON object with that member as an array, or the array holds anything but strings.
    // The span is noescape, which gives Swift an overload taking a Span.
    bool parse([[clang::noescape]] std::span<const uint8_t> resource, const String& memberName, size_t maxResourceSize);

    size_t size() const { return strings.size(); }
    WellKnownCandidate candidate(size_t index) const;

    WellKnownStringVector strings;
};

} // namespace WebCore
