/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CSSCustomPropertySyntax.h"

#include "CSSMarkup.h"
#include "CSSParserSwiftParse.h"
#include "CSSParserTokenRange.h"
#include <wtf/text/StringBuilder.h>

namespace WebCore {

std::optional<CSSCustomPropertySyntax> CSSCustomPropertySyntax::parse(StringView syntax)
{
    // The format doesn't quite parse with CSSTokenizer.
    CSSParserSwiftParse parse { strictCSSParserContext(), { .context = &strictCSSParserContext(), .syntaxText = syntax } };
    parse.run(CSSParserTokenRange { std::span<const CSSParserToken> { } }, CSSParserSwiftRequest::Syntax);
    return WTF::move(parse.syntax);
}

std::optional<CSSCustomPropertySyntax> CSSCustomPropertySyntax::consumeType(CSSParserTokenRange& range)
{
    CSSParserSwiftParse parse { strictCSSParserContext(), { .context = &strictCSSParserContext() } };
    parse.run(range, CSSParserSwiftRequest::SyntaxType);
    // The number of tokens the type took, whether it parsed or not.
    RELEASE_ASSERT(parse.result <= range.size());
    range = CSSParserTokenRange { range.span().subspan(parse.result) };
    return WTF::move(parse.syntax);
}

static ASCIILiteral typeNameForType(CSSCustomPropertySyntax::Type type)
{
    using Type = CSSCustomPropertySyntax::Type;
    switch (type) {
    case Type::Length: return "length"_s;
    case Type::LengthPercentage: return "length-percentage"_s;
    case Type::Percentage: return "percentage"_s;
    case Type::Integer: return "integer"_s;
    case Type::Number: return "number"_s;
    case Type::Angle: return "angle"_s;
    case Type::Time: return "time"_s;
    case Type::Resolution: return "resolution"_s;
    case Type::Color: return "color"_s;
    case Type::Image: return "image"_s;
    case Type::URL: return "url"_s;
    case Type::CustomIdent: return "custom-ident"_s;
    case Type::String: return "string"_s;
    case Type::TransformFunction: return "transform-function"_s;
    case Type::TransformList: return "transform-list"_s;
    case Type::Ident:
    case Type::Unknown:
        break;
    }
    return { };
}

void serializeCustomPropertySyntax(StringBuilder& builder, const CSSCustomPropertySyntax& syntax)
{
    if (syntax.isUniversal()) {
        builder.append('*');
        return;
    }

    auto separator = ""_s;
    for (auto& component : syntax.definition) {
        builder.append(separator);
        separator = " | "_s;

        // The Ident type is a literal custom identifier rather than a named data type.
        if (component.type == CSSCustomPropertySyntax::Type::Ident)
            serializeIdentifier(builder, component.ident);
        else
            builder.append('<', typeNameForType(component.type), '>');

        switch (component.multiplier) {
        case CSSCustomPropertySyntax::Multiplier::Single:
            break;
        case CSSCustomPropertySyntax::Multiplier::SpaceList:
            builder.append('+');
            break;
        case CSSCustomPropertySyntax::Multiplier::CommaList:
            builder.append('#');
            break;
        }
    }
}

void serializeCustomPropertySyntaxAsCSSType(StringBuilder& builder, const CSSCustomPropertySyntax& syntax)
{
    ASSERT(!syntax.isUniversal());
    // A single syntax component is written bare. Anything else must be wrapped in type().
    if (syntax.definition.size() == 1) {
        serializeCustomPropertySyntax(builder, syntax);
        return;
    }
    builder.append("type("_s);
    serializeCustomPropertySyntax(builder, syntax);
    builder.append(')');
}

// MARK: - Hashing

void add(Hasher& hasher, const CSSCustomPropertySyntax::Component& component)
{
    add(hasher, component.type, component.multiplier, component.ident);
}

}
