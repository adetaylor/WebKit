// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
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
#include "CSSSupportsParser.h"

#include "CSSAtRuleID.h"
#include "CSSParser.h"
#include "CSSParserSwiftParse.h"
#include "CSSPropertyParserConsumer+Font.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSSelectorParser.h"
#include "CSSTokenizer.h"
#include "FontCustomPlatformData.h"
#include "StyleRule.h"

namespace WebCore {

// CSSParserSupportsSwift.swift returns these values.
static_assert(CSSSupportsParser::Unsupported == 0);
static_assert(CSSSupportsParser::Supported == 1);
static_assert(CSSSupportsParser::Invalid == 2);

CSSSupportsParser::SupportsResult CSSSupportsParser::supportsCondition(StringView condition, const CSSParserContext& context, ParsingMode mode)
{
    CSSParser parser(context, condition);
    if (!parser.tokenizer())
        return SupportsResult::Invalid;
    CSSParserSwiftParse parse { parser.context(), { .context = &parser.context(), .parser = &parser, .mode = std::to_underlying(mode) } };
    parse.run(parser.tokenizer()->tokenRange(), CSSParserSwiftRequest::SupportsCondition);
    RELEASE_ASSERT(parse.result <= Invalid);
    return static_cast<SupportsResult>(parse.result);
}

bool CSSSupportsParser::isMarginTrimInlineValue(StringView value)
{
    CSSTokenizer tokenizer(value);
    CSSParserSwiftParse parse { CSSSelectorParserContext { } };
    parse.run(tokenizer.tokenRange(), CSSParserSwiftRequest::MarginTrimInlineValue);
    return parse.result;
}

uint64_t CSSParserSwiftState::supportsFontFunction(bool technology, uint32_t start, uint32_t end)
{
    auto tokens = static_cast<CSSParserSwiftStateData&>(*this).tokens;
    RELEASE_ASSERT(start <= end && end <= tokens.size());
    CSSParserTokenRange range { tokens.subspan(start, end - start) };
    auto state = CSS::PropertyParserState { .context = static_cast<CSSParserSwiftStateData&>(*this).parse.context() };
    auto result = [&] {
        if (technology) {
            auto technologies = CSSPropertyParserHelpers::consumeFontTech(range, state, true);
            if (technologies.isEmpty())
                return CSSSupportsParser::Unsupported;
            ASSERT(technologies.size() == 1);
            return FontCustomPlatformData::supportsTechnology(technologies[0]) ? CSSSupportsParser::Supported : CSSSupportsParser::Unsupported;
        }
        auto format = CSSPropertyParserHelpers::consumeFontFormat(range, state, true);
        if (format.isNull())
            return CSSSupportsParser::Unsupported;
        return FontCustomPlatformData::supportsFormat(format) ? CSSSupportsParser::Supported : CSSSupportsParser::Unsupported;
    }();
    return static_cast<uint64_t>(end - start - range.size()) << 2 | result;
}

} // namespace WebCore
