/*
 * Copyright (C) 2011 Nokia Inc. All rights reserved.
 * Copyright (C) 2012 Google Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#pragma once

#include <wtf/Forward.h>
#include <wtf/RefCounted.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class QuotesData : public RefCounted<QuotesData> {
public:
    static Ref<QuotesData> create(const Vector<std::pair<String, String>>& quotes);
    ~QuotesData();

    friend bool operator==(const QuotesData&, const QuotesData&);

    const String& openQuote(unsigned index) const;
    const String& closeQuote(unsigned index) const;

    unsigned size() const { return m_quoteCount; }

private:
    explicit QuotesData(const Vector<std::pair<String, String>>& quotes);

    std::span<const std::pair<String, String>> quotePairs() const;
    std::span<std::pair<String, String>> quotePairs();

    unsigned m_quoteCount;
    std::pair<String, String> m_quotePairs[0];
};

} // namespace WebCore
