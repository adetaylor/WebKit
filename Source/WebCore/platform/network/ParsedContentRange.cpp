/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE COMPUTER, INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE COMPUTER, INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"
#include "ParsedContentRange.h"

#include "WebCore-Swift.h"
#include <wtf/StdLibExtras.h>

namespace WebCore {

// HTTPParsers.swift's httpContentRangeInvalidLength and httpContentRangeUnknownLength are these values.
static_assert(ParsedContentRange::invalidLength == std::numeric_limits<int64_t>::min());
static_assert(ParsedContentRange::unknownLength == std::numeric_limits<int64_t>::max());

ParsedContentRange::ParsedContentRange(const String& headerValue)
    : ParsedContentRange(headerValue.is8Bit() ? parseContentRange8(headerValue.span8()) : parseContentRange16(headerValue.span16()))
{
}

ParsedContentRange::ParsedContentRange(int64_t firstBytePosition, int64_t lastBytePosition, int64_t instanceLength)
    : m_firstBytePosition(firstBytePosition)
    , m_lastBytePosition(lastBytePosition)
    , m_instanceLength(instanceLength)
{
    if (!areContentRangeValuesValid(m_firstBytePosition, m_lastBytePosition, m_instanceLength))
        m_instanceLength = invalidLength;
}

String ParsedContentRange::headerValue() const
{
    return contentRangeHeaderValue(m_firstBytePosition, m_lastBytePosition, m_instanceLength);
}

}
