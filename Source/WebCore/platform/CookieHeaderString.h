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

#include <wtf/text/WTFString.h>

namespace WebCore {

// The value of a Cookie request header field, or of document.cookie: the names and values
// of every cookie matching some request, serialized into one string.
//
// This is as sensitive as the cookies it was built from, but a bare String cannot be told
// apart from the many unremarkable strings that cross the same process boundaries. Giving
// it a type of its own is what lets the IPC layer recognise it and require a permission
// check before it is sent to a less privileged process.
class CookieHeaderString {
public:
    CookieHeaderString() = default;

    explicit CookieHeaderString(String&& string)
        : m_string(WTF::move(string))
    {
    }

    explicit CookieHeaderString(const String& string)
        : m_string(string)
    {
    }

    const String& string() const LIFETIME_BOUND { return m_string; }
    String takeString() { return WTF::move(m_string); }

    bool isEmpty() const { return m_string.isEmpty(); }

private:
    String m_string;
};

} // namespace WebCore
