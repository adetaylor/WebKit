/*
 * Copyright (C) 2016 Canon Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted, provided that the following conditions
 * are required to be met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Canon Inc. nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY CANON INC. AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL CANON INC. AND ITS CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "FetchHeaders.h"

#include "ExceptionOr.h"
#include "WebCore-Swift.h"
#include <wtf/Borrow.h>

namespace WebCore {

// https://fetch.spec.whatwg.org/#concept-headers-fill
static ExceptionOr<void> fillHeaderMap(HTTPHeaderMap& headers, Vector<String>& setCookieValues, const FetchHeaders::Init& headersInit, FetchHeaders::Guard guard)
{
    if (std::holds_alternative<Vector<Vector<String>>>(headersInit)) {
        auto& sequence = std::get<Vector<Vector<String>>>(headersInit);
        for (auto& header : borrow(sequence)) {
            if (header.size() != 2)
                return Exception { ExceptionCode::TypeError, "Header sub-sequence must contain exactly two items"_s };
            auto result = appendToHeaderMap(borrow(header)[0], borrow(header)[1], headers, setCookieValues, guard);
            if (result.hasException())
                return result.releaseException();
        }
    } else {
        auto& record = std::get<Vector<KeyValuePair<String, String>>>(headersInit);
        for (auto& header : borrow(record)) {
            auto result = appendToHeaderMap(header.key, header.value, headers, setCookieValues, guard);
            if (result.hasException())
                return result.releaseException();
        }
    }

    return { };
}

ExceptionOr<Ref<FetchHeaders>> FetchHeaders::create(std::optional<Init>&& headersInit)
{
    HTTPHeaderMap headers;
    Vector<String> setCookieValues;

    if (headersInit) {
        auto result = fillHeaderMap(headers, setCookieValues, *headersInit, Guard::None);
        if (result.hasException())
            return result.releaseException();
    }

    return adoptRef(*new FetchHeaders { Guard::None, WTF::move(headers), WTF::move(setCookieValues) });
}

ExceptionOr<void> FetchHeaders::fill(const Init& headerInit)
{
    return fillHeaderMap(m_headers, m_setCookieValues, headerInit, m_guard);
}

ExceptionOr<void> FetchHeaders::fill(const FetchHeaders& otherHeaders)
{
    // fetchHeadersFill() reads the source while it changes this object, so it is given a copy when they are the same.
    if (&otherHeaders == this)
        return fill(FetchHeaders::create(otherHeaders).get());
    return fetchHeadersFill(m_headers, m_setCookieValues, m_guard, otherHeaders.m_headers, otherHeaders.m_setCookieValues);
}

ExceptionOr<void> FetchHeaders::append(const String& name, const String& value)
{
    ++m_updateCounter;
    return appendToHeaderMap(name, value, m_headers, m_setCookieValues, m_guard);
}

// https://fetch.spec.whatwg.org/#dom-headers-delete
ExceptionOr<void> FetchHeaders::remove(const String& name)
{
    return fetchHeadersRemove(m_headers, m_setCookieValues, m_guard, m_updateCounter, name);
}

ExceptionOr<String> FetchHeaders::get(const String& name) const
{
    if (fetchHeadersNeedsLookup(name))
        return m_headers.get(name);
    return fetchHeadersGet(name, m_setCookieValues);
}

const Vector<String>& FetchHeaders::getSetCookie() const
{
    return m_setCookieValues;
}

ExceptionOr<bool> FetchHeaders::has(const String& name) const
{
    if (fetchHeadersNeedsLookup(name))
        return m_headers.contains(name);
    return fetchHeadersHas(name, !m_setCookieValues.isEmpty());
}

ExceptionOr<void> FetchHeaders::set(const String& name, const String& value)
{
    return fetchHeadersSet(m_headers, m_setCookieValues, m_guard, m_updateCounter, name, value);
}

void FetchHeaders::filterAndFill(const HTTPHeaderMap& headers, Guard guard)
{
    // fetchHeadersFilterAndFill() reads the source while it changes m_headers, so it is given a copy when they are the same.
    if (&headers == &m_headers)
        return filterAndFill(HTTPHeaderMap { headers }, guard);
    fetchHeadersFilterAndFill(m_headers, headers, guard);
}

std::optional<KeyValuePair<String, String>> FetchHeaders::Iterator::next()
{
    return fetchHeadersIteratorNext(m_headers->m_headers, m_headers->m_setCookieValues, m_headers->m_updateCounter, m_keys, m_currentIndex, m_setCookieIndex, m_updateCounter);
}

FetchHeaders::Iterator::Iterator(FetchHeaders& headers)
    : m_headers(headers)
{
}

} // namespace WebCore
