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

#include "DateComponents.h"
#include "HTMLParserIdioms.h"
#include <span>
#include <wtf/text/Latin1Character.h>

#if USE_SWIFT_HTML_MICROSYNTAXES

// The types that the Swift HTML microsyntax and date parsers exchange with their C++ callers.

namespace WebCore {

// A string's characters are passed as a span of their width, to the function for that width.
using HTMLMicrosyntaxSpan8 = std::span<const Latin1Character>;
using HTMLMicrosyntaxSpan16 = std::span<const char16_t>;
using HTMLMicrosyntaxDoubles = std::span<double>;
using HTMLMicrosyntaxDimensions = std::span<HTMLDimensionsListValue>;

struct HTMLMicrosyntaxIntegerResult {
    int value;
    HTMLIntegerParsingError error;
    bool isValid;
};

// The URL of a refresh is the characters [urlStart, urlStart + urlLength) of the parsed string.
struct HTMLMicrosyntaxRefreshResult {
    unsigned urlStart;
    unsigned urlLength;
    bool isValid;
    bool hasURL;
};

// The URL of a srcset candidate is the characters [start, start + length) of the attribute. density and width are
// UninitializedDescriptor when not given.
struct HTMLMicrosyntaxSrcsetCandidate {
    unsigned start;
    unsigned length;
    float density;
    int width;
    bool found;
};

// isSrc is 1 for the candidate from the src attribute and 0 for the others. Picking a candidate sets its key's
// density to the density it has after normalization.
struct HTMLMicrosyntaxSrcsetPickKey {
    float density;
    int width;
    uint8_t isSrc;
};
using HTMLMicrosyntaxSrcsetPickKeys = std::span<HTMLMicrosyntaxSrcsetPickKey>;

// The state of a scan of a <meta> tag's attributes for a character encoding. When hasEncoding is set, the
// encoding's name is the characters [start, start + length) of the value of the attribute at index attribute.
struct HTMLMicrosyntaxMetaCharsetScan {
    unsigned attribute;
    unsigned start;
    unsigned length;
    uint8_t mode;
    bool gotPragma;
    bool hasEncoding;
};

} // namespace WebCore

#endif // USE_SWIFT_HTML_MICROSYNTAXES
