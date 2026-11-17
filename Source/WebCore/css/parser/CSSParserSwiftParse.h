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

#include "CSSParser.h"
#include "CSSParserSwiftState.h"
#include "CSSPrimitiveNumericTypes.h"
#include "CSSSelectorList.h"
#include "CSSSelectorParserContext.h"
#include "CSSTokenizer.h"
#include "ContainerQuery.h"
#include "FontFeatureValues.h"
#include "StyleRuleFunction.h"
#include "StyleSheetContents.h"
#include <wtf/Noncopyable.h>

namespace WebCore {

// What an entry point passes to CSSParserSwiftParse besides the context; each entry sets only the fields its request
// reads.
struct CSSParserSwiftParseInputs {
    const CSSParserContext* context { nullptr }; // Every request's but the selector parser's, which has only a CSSSelectorParserContext.
    RefPtr<StyleSheetContents> styleSheet;
    CSSParser* parser { nullptr }; // The rule parser's requests' CSSParser, which outlives the parse.
    AtomString customPropertyName; // CSSParser::parseCustomPropertyValue's name.
    CSSParserEnum::NestedContext nestedContext { };
    CSSParser::AllowedRules allowedRules { CSSParser::AllowedRules::RegularRules };
    StyleRuleType ruleType { StyleRuleType::Style };
    uint8_t mode { 0 }; // CSSSupportsParser::ParsingMode, or the selector parser's options.
    StringView syntaxText; // CSSCustomPropertySyntax::parse's text.
};

// One parse request's inputs, working state and results, on its entry point's stack. run() tokenizes the input (or
// takes the entry's tokens) and calls cssParseWithSwift once; the entry then reads the results. Swift reaches it only
// through CSSParserSwiftState's members.
class CSSParserSwiftParse {
    WTF_MAKE_NONCOPYABLE(CSSParserSwiftParse);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    using Inputs = CSSParserSwiftParseInputs;

    CSSParserSwiftParse(const CSSSelectorParserContext& selectorContext, Inputs inputs = { })
        : selectorContext(selectorContext)
        , inputs(WTF::move(inputs))
        , syntaxText(this->inputs.syntaxText)
    {
    }

    // `input` is the entry's StringView, tokenized as CSSParser's constructor tokenizes it, or its CSSParserTokenRange.
    // Returns false when the tokenizer cannot be created.
    template<typename Input>
    bool run(const Input& input, CSSParserSwiftRequest request)
    {
        if constexpr (std::is_same_v<Input, CSSParserTokenRange>)
            runOnTokens(input.span(), request);
        else {
            auto tokenizer = CSSTokenizer::tryCreate(input);
            if (!tokenizer)
                return false;
            runOnTokens(tokenizer->tokenRange().span(), request);
        }
        return true;
    }

    // The CSSParserContext, which every request but the selector parser's has.
    const CSSParserContext& context() const
    {
        RELEASE_ASSERT(inputs.context);
        return *inputs.context;
    }

    const CSSSelectorParserContext selectorContext;
    const Inputs inputs;

    uint32_t result { 0 };

    // The <syntax> text being parsed: the Syntax request's own, or the serialization of a SyntaxType request's tokens,
    // which serializedSyntax holds. And the syntax parsed, if it parsed.
    StringView syntaxText;
    String serializedSyntax;
    std::optional<CSSCustomPropertySyntax> syntax;

    std::array<AtomString, 2> resultAtoms;
    std::optional<CSSSelectorList> selectorList;

    // The rule parser's: the CSSParser, the selector lists of the style rules being parsed, innermost last, the rule
    // makeStyleRule() or makeAtRule() last made, and the request's rule.
    CSSParser& parser() const
    {
        RELEASE_ASSERT(inputs.parser);
        return *inputs.parser;
    }
    Vector<CSSSelectorList, 4> styleRuleSelectorLists;
    RefPtr<StyleRuleBase> rule;
    RefPtr<StyleRuleBase> resultRule;
    // Parts of the at-rule makeAtRule() makes next.
    Vector<FontFeatureValuesTag> fontFeatureValuesTags;
    Vector<StyleRuleFunction::Parameter> functionParameters;
    Vector<std::pair<CSSValueID, CSS::Percentage<>>> keyframeKeys;
    Vector<CQ::ContainerQuery> containerQueries; // innermost last: @container nests
    CSSSelectorList scopeStart;

private:
    // Makes the CSSParserSwiftStateData on its stack and calls cssParseWithSwift.
    void runOnTokens(std::span<const CSSParserToken>, CSSParserSwiftRequest);
};

} // namespace WebCore
