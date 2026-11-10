 /*
 * Copyright (C) 2011 Google Inc. All rights reserved.
 * Copyright (C) 2012 Intel Corporation. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ParsedContentType.h"

#include "HTTPParsers.h"
#include "WebCore-Swift.h"
#include <wtf/text/StringBuilder.h>

namespace WebCore {

bool ParsedContentType::parseContentType()
{
    auto mimeType = m_contentType.is8Bit() ? parseContentTypeMIMEType8(m_contentType.span8()) : parseContentTypeMIMEType16(m_contentType.span16());
    if (!mimeType.isValid)
        return false;
    m_mimeType = StringView(m_contentType).substring(mimeType.item.start, mimeType.item.length).convertToASCIILowercase();
    for (unsigned index = mimeType.next; index < m_contentType.length();) {
        auto parameter = m_contentType.is8Bit() ? parseContentTypeParameter8(m_contentType.span8(), index) : parseContentTypeParameter16(m_contentType.span16(), index);
        index = parameter.next;
        if (!parameter.isAccepted || m_parameterValues.contains(parameter.name))
            continue;
        // FIXME: Lowercasing after a contains check is almost certainly wrong. It means we overwrite
        // when the name is different in case.
        auto name = parameter.name.convertToASCIILowercase();
        m_parameterValues.set(name, WTF::move(parameter.value));
        m_parameterNames.append(WTF::move(name));
    }
    return true;
}

std::optional<ParsedContentType> ParsedContentType::create(const String& contentType)
{
    ParsedContentType parsedContentType(contentType.trim(isASCIIWhitespaceWithoutFF<char16_t>));
    if (!parsedContentType.parseContentType())
        return std::nullopt;
    return { WTF::move(parsedContentType) };
}

bool isValidContentType(const String& contentType)
{
    return ParsedContentType::create(contentType) != std::nullopt;
}

ParsedContentType::ParsedContentType(const String& contentType)
    : m_contentType(contentType)
{
}

String ParsedContentType::charset() const
{
    return parameterValueForName("charset"_s);
}

void ParsedContentType::setCharset(String&& charset)
{
    m_parameterValues.set("charset"_s, WTF::move(charset));
}

String ParsedContentType::parameterValueForName(const String& name) const
{
    return m_parameterValues.get(name);
}

size_t ParsedContentType::parameterCount() const
{
    return m_parameterValues.size();
}

String ParsedContentType::serialize() const
{
    StringBuilder builder;
    builder.append(m_mimeType);
    for (auto& name : m_parameterNames) {
        builder.append(';');
        builder.append(name);
        builder.append('=');
        String value = m_parameterValues.get(name);
        if (value.isEmpty() || !isValidHTTPToken(value)) {
            builder.append('"');
            for (unsigned index = 0; index < value.length(); ++index) {
                auto ch = value[index];
                if (ch == '\\' || ch =='"')
                    builder.append('\\');
                builder.append(ch);
            }
            builder.append('"');
        } else
            builder.append(value);
    }
    return builder.toString();
}

} // namespace WebCore
