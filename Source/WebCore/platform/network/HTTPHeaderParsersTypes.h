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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "HTTPHeaderNames.h"
#include "HTTPParsers.h"
#include "ReferrerPolicy.h"
#include <cstdint>
#include <span>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

using HTTPHeaderLatin1Span = std::span<const Latin1Character>;
using HTTPHeaderUTF16Span = std::span<const char16_t>;
using HTTPHeaderByteSpan = std::span<const uint8_t>;

// A substring of the parsed value, by offset and length.
struct HTTPHeaderExtent {
    uint32_t start;
    uint32_t length;
    bool isNull;
};

// One item of a comma-separated list; the next call starts at the offset in next.
struct HTTPHeaderListItem {
    HTTPHeaderExtent item;
    uint32_t next;
    bool isValid;
};

struct HTTPHeaderOptionalUInt64 {
    uint64_t value;
    bool hasValue;
};

enum class HTTPHeaderCrossOriginSafety : uint8_t { Safe, Unsafe, Exposed };

struct HTTPHeaderRangeResult {
    uint64_t start;
    uint64_t end;
    bool isValid;
    bool hasStart;
    bool hasEnd;
};

struct HTTPHeaderFieldExtents {
    HTTPHeaderExtent name;
    HTTPHeaderExtent value;
};

struct HTTPHeaderLineResult {
    String failureReason;
    size_t length;
    HTTPHeaderFieldExtents field;
};

struct HTTPHeaderContentTypeParameter {
    String name;
    String value;
    uint32_t next;
    bool isAccepted;
};

enum class HTTPHeaderStructuredFieldStepKind : uint8_t {
    Integer,
    Decimal,
    String,
    Token,
    ByteSequence,
    Boolean,
    InnerListStart,
    InnerListEnd,
    ParameterKey,
    MemberKey,
};

// One step of a structured field value, in the order RFC 8941 reads it. A Boolean's value is in the integer
// member. A string's, token's, byte sequence's or key's text is the length characters at start in the value. A
// string's integer member is twice the number of its escapes, plus 1 when it has a code unit above U+00FF.
struct HTTPHeaderStructuredFieldStep {
    double decimal;
    int64_t integer;
    uint32_t start;
    uint32_t length;
    HTTPHeaderStructuredFieldStepKind kind;
};

using HTTPHeaderStructuredFieldStepSpan = std::span<HTTPHeaderStructuredFieldStep>;

enum class HTTPHeaderStructuredFieldType : uint8_t { Item, List, Dictionary };

} // namespace WebCore
