// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2021 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"
#include "CSSSubstitutionParser.h"

#include "CSSCustomPropertyValue.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSParserSwiftParse.h"
#include "CSSParserToken.h"
#include "CSSParserTokenRange.h"
#include "CSSPropertyParser.h"
#include "CSSSubstitutionValue.h"
#include "CSSValueKeywords.h"
#include "StyleCustomProperty.h"
#include "StyleSheetContents.h"

namespace WebCore {

bool CSSSubstitutionParser::isValidCustomPropertyName(const CSSParserToken& token)
{
    if (token.type() != IdentToken)
        return false;

    return isCustomPropertyName(token.value());
}

uint32_t cssParserSubstitutionFlags(const CSSParserContext& context)
{
    return (context.cssInheritFunctionEnabled ? CSSParserSwiftInheritFunctionEnabled : 0)
        | (context.cssRandomItemFunctionEnabled ? CSSParserSwiftRandomItemFunctionEnabled : 0)
        | (context.cssIfFunctionEnabled ? CSSParserSwiftIfFunctionEnabled : 0)
        | (context.cssIdentFunctionEnabled ? CSSParserSwiftIdentFunctionEnabled : 0)
        | (context.cssInternalAutoBaseParsingEnabled ? CSSParserSwiftInternalAutoBaseParsingEnabled : 0)
        | (context.propertySettings.cssFunctionAtRuleEnabled ? CSSParserSwiftFunctionAtRuleEnabled : 0)
        | (context.viewportSegmentsAPIEnabled ? CSSParserSwiftViewportSegmentsAPIEnabled : 0);
}

std::optional<Vector<unsigned, 2>> CSSSubstitutionParser::consumeEnvVariableIndices(CSSParserTokenRange& range)
{
    Vector<unsigned, 2> indices;
    while (range.peek().type() == NumberToken) {
        auto& token = range.consumeIncludingWhitespace();
        if (token.numericValueType() != IntegerValueType || token.numericValue() < 0)
            return std::nullopt;
        indices.append(clampTo<unsigned>(token.numericValue()));
    }
    return indices;
}

bool CSSSubstitutionParser::containsSubstitutionFunctions(CSSParserTokenRange range, const CSSParserContext& parserContext)
{
    CSSParserSwiftParse parse { parserContext, { .context = &parserContext } };
    parse.run(range, CSSParserSwiftRequest::ContainsSubstitutionFunctions);
    return parse.result;
}

RefPtr<CSSCustomPropertyValue> cssCustomPropertyValueOfKind(uint32_t result, const AtomString& variableName, CSSParserTokenRange range, const CSSParserContext& parserContext, const CSSNamespacePrefixMap& namespaceMap)
{
    using Kind = CSSParserSwiftDeclarationValueKind;
    auto kind = result & 0xff;
    RELEASE_ASSERT(kind <= std::to_underlying(Kind::Tokens));
    switch (static_cast<Kind>(kind)) {
    case Kind::Invalid:
        return nullptr;
    case Kind::CSSWideKeyword: {
        auto keyword = parseCSSWideKeyword(static_cast<CSSValueID>(result >> 8));
        RELEASE_ASSERT(keyword);
        return CSSCustomPropertyValue::createWithCSSWideKeyword(variableName, *keyword);
    }
    case Kind::Substitution:
        return CSSCustomPropertyValue::createUnresolved(variableName, CSSSubstitutionValue::create(range, namespaceMap, parserContext));
    case Kind::Tokens:
        return CSSCustomPropertyValue::createSyntaxAll(variableName, CSSVariableData::create(range, parserContext));
    }
    RELEASE_ASSERT_NOT_REACHED();
}

RefPtr<CSSCustomPropertyValue> CSSSubstitutionParser::parseDeclarationValue(const AtomString& variableName, CSSParserTokenRange range, const CSSParserContext& parserContext, const CSSNamespacePrefixMap& namespaceMap)
{
    CSSParserSwiftParse parse { parserContext, { .context = &parserContext } };
    parse.run(range, CSSParserSwiftRequest::DeclarationValue);
    return cssCustomPropertyValueOfKind(parse.result, variableName, range, parserContext, namespaceMap);
}

RefPtr<const Style::CustomProperty> CSSSubstitutionParser::parseInitialValueForUniversalSyntax(const AtomString& variableName, CSSParserTokenRange range)
{
    CSSParserSwiftParse parse { strictCSSParserContext(), { .context = &strictCSSParserContext() } };
    parse.run(range, CSSParserSwiftRequest::DeclarationValue);
    if (parse.result != std::to_underlying(CSSParserSwiftDeclarationValueKind::Tokens))
        return nullptr;

    return Style::CustomProperty::createForVariableData(variableName, CSSVariableData::create(range));
}

} // namespace WebCore
