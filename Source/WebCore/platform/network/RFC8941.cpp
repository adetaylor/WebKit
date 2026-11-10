/*
 * Copyright (C) 2021-2022 Apple Inc. All rights reserved.
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

#include "config.h"
#include "RFC8941.h"

#include "WebCore-Swift.h"
#include <wtf/text/Base64.h>
#include <wtf/text/StringHash.h>
#include <wtf/text/StringView.h>

namespace RFC8941 {

using Step = WebCore::HTTPHeaderStructuredFieldStep;
using StepKind = WebCore::HTTPHeaderStructuredFieldStepKind;

struct StructuredFieldSteps {
    bool atEnd() const { return m_index == m_steps.size(); }
    bool next(StepKind kind) const { return !atEnd() && m_steps[m_index].kind == kind; }
    String key() { return text(m_steps[m_index++]); }

    std::optional<BareItem> bareItem()
    {
        auto& step = m_steps[m_index++];
        switch (step.kind) {
        case StepKind::Integer:
            return BareItem { step.integer };
        case StepKind::Decimal:
            return BareItem { step.decimal };
        case StepKind::String:
            return BareItem { m_header.is8Bit() ? WebCore::structuredFieldString8(m_header.span8(), step.start, step.length, step.integer) : WebCore::structuredFieldString16(m_header.span16(), step.start, step.length, step.integer) };
        case StepKind::Token:
            return BareItem { Token { text(step) } };
        case StepKind::ByteSequence:
            if (auto decoded = base64Decode(m_header.substring(step.start, step.length)))
                return BareItem { WTF::move(*decoded) };
            return std::nullopt;
        case StepKind::Boolean:
            return BareItem { !!step.integer };
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    }

    std::optional<std::pair<BareItem, Parameters>> item()
    {
        auto item = bareItem();
        auto parameters = this->parameters();
        if (!item || !parameters)
            return std::nullopt;
        return std::pair { WTF::move(*item), WTF::move(*parameters) };
    }

    std::optional<std::pair<ItemOrInnerList, Parameters>> itemOrInnerList()
    {
        if (!next(StepKind::InnerListStart)) {
            auto item = this->item();
            if (!item)
                return std::nullopt;
            return std::pair { ItemOrInnerList { WTF::move(item->first) }, WTF::move(item->second) };
        }
        ++m_index;
        InnerList list;
        while (!next(StepKind::InnerListEnd)) {
            auto item = this->item();
            if (!item)
                return std::nullopt;
            list.append(WTF::move(*item));
        }
        ++m_index;
        auto parameters = this->parameters();
        if (!parameters)
            return std::nullopt;
        return std::pair { ItemOrInnerList { WTF::move(list) }, WTF::move(*parameters) };
    }

    std::optional<Parameters> parameters()
    {
        HashMap<String, BareItem> parameters;
        while (next(StepKind::ParameterKey)) {
            auto name = key();
            auto value = bareItem();
            if (!value)
                return std::nullopt;
            parameters.set(WTF::move(name), WTF::move(*value));
        }
        return Parameters { WTF::move(parameters) };
    }

    String text(const Step& step) const { return m_header.substring(step.start, step.length).toString(); }

    StringView m_header;
    std::span<const Step> m_steps;
    size_t m_index { 0 };
};

template<typename Result, typename Build>
static std::optional<Result> parseStructuredField(StringView header, WebCore::HTTPHeaderStructuredFieldType type, NOESCAPE const Build& build)
{
    if (header.isEmpty())
        return std::nullopt;
    // parseStructuredField8() and parseStructuredField16() return the number of steps, which can be more than the
    // buffer holds, or -1 when the value does not parse.
    Vector<Step, 32> buffer(32);
    auto count = header.is8Bit() ? WebCore::parseStructuredField8(header.span8(), type, buffer.mutableSpan()) : WebCore::parseStructuredField16(header.span16(), type, buffer.mutableSpan());
    if (count > static_cast<int64_t>(buffer.size())) {
        buffer.grow(static_cast<size_t>(count));
        count = header.is8Bit() ? WebCore::parseStructuredField8(header.span8(), type, buffer.mutableSpan()) : WebCore::parseStructuredField16(header.span16(), type, buffer.mutableSpan());
    }
    if (count < 0)
        return std::nullopt;
    StructuredFieldSteps steps { header, buffer.span().first(count) };
    return build(steps);
}

// https://datatracker.ietf.org/doc/html/rfc8941#section-4.2 with type "item".
std::optional<std::pair<BareItem, Parameters>> parseItemStructuredFieldValue(StringView header)
{
    return parseStructuredField<std::pair<BareItem, Parameters>>(header, WebCore::HTTPHeaderStructuredFieldType::Item, [](auto& steps) {
        return steps.item();
    });
}

// https://datatracker.ietf.org/doc/html/rfc8941#section-4.2 with type "list".
std::optional<Vector<std::pair<ItemOrInnerList, Parameters>>> parseListStructuredFieldValue(StringView header)
{
    return parseStructuredField<Vector<std::pair<ItemOrInnerList, Parameters>>>(header, WebCore::HTTPHeaderStructuredFieldType::List, [](auto& steps) -> std::optional<Vector<std::pair<ItemOrInnerList, Parameters>>> {
        Vector<std::pair<ItemOrInnerList, Parameters>> list;
        while (!steps.atEnd()) {
            auto member = steps.itemOrInnerList();
            if (!member)
                return std::nullopt;
            list.append(WTF::move(*member));
        }
        return list;
    });
}

// https://datatracker.ietf.org/doc/html/rfc8941#section-4.2 with type "dictionary".
std::optional<HashMap<String, std::pair<ItemOrInnerList, Parameters>>> parseDictionaryStructuredFieldValue(StringView header)
{
    return parseStructuredField<HashMap<String, std::pair<ItemOrInnerList, Parameters>>>(header, WebCore::HTTPHeaderStructuredFieldType::Dictionary, [](auto& steps) -> std::optional<HashMap<String, std::pair<ItemOrInnerList, Parameters>>> {
        HashMap<String, std::pair<ItemOrInnerList, Parameters>> dictionary;
        while (!steps.atEnd()) {
            auto name = steps.key();
            auto member = steps.itemOrInnerList();
            if (!member)
                return std::nullopt;
            dictionary.set(WTF::move(name), WTF::move(*member));
        }
        return dictionary;
    });
}

std::optional<String> escapeString(StringView input)
{
    auto escaped = input.is8Bit() ? WebCore::escapeStructuredFieldString8(input.span8()) : WebCore::escapeStructuredFieldString16(input.span16());
    if (escaped.isNull())
        return std::nullopt;
    return escaped;
}

} // namespace RFC8941
