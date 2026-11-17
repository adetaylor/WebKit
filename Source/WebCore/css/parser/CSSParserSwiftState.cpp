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

#include "config.h"
#include "CSSParserSwiftParse.h"

#include "CSSParserIdioms.h"
#include "CSSSubstitutionParser.h"
#include "WebCore-Swift.h"

namespace WebCore {

static_assert(std::is_empty_v<CSSParserSwiftState>);
static_assert(!std::is_polymorphic_v<CSSParserSwiftState>);
static_assert(!std::is_default_constructible_v<CSSParserSwiftState>);
static_assert(!std::is_copy_constructible_v<CSSParserSwiftState>);
static_assert(!std::is_copy_assignable_v<CSSParserSwiftState>);
static_assert(!std::is_move_assignable_v<CSSParserSwiftState>);
static_assert(std::is_move_constructible_v<CSSParserSwiftState>);
static_assert(!std::is_trivially_destructible_v<CSSParserSwiftState>);
// cssParseWithSwift compares a request with each enumerator's value.
static_assert(std::to_underlying(CSSParserSwiftRequest::SyntaxType) == 15);

CSSParserSwiftState::CSSParserSwiftState(CSSParserSwiftState&&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

CSSParserSwiftState::~CSSParserSwiftState() = default;

static CSSParserSwiftParse& parse(CSSParserSwiftState& state)
{
    return static_cast<CSSParserSwiftStateData&>(state).parse;
}

void CSSParserSwiftParse::runOnTokens(std::span<const CSSParserToken> tokens, CSSParserSwiftRequest request)
{
    // Token indices cross as uint32_t.
    RELEASE_ASSERT(tokens.size() < std::numeric_limits<uint32_t>::max());
    CSSParserSwiftStateData state { tokens, *this };
    cssParseWithSwift(state, std::to_underlying(request));
}

uint32_t CSSParserSwiftState::requestInputs()
{
    auto& inputs = parse(*this).inputs;
    uint32_t nestedContext = inputs.nestedContext ? 1 + std::to_underlying(*inputs.nestedContext) : 0;
    return std::to_underlying(inputs.allowedRules) | std::to_underlying(inputs.ruleType) << 8 | nestedContext << 16 | static_cast<uint32_t>(inputs.mode) << 24;
}

void CSSParserSwiftState::setResult(uint32_t value)
{
    parse(*this).result = value;
}

uint32_t CSSParserSwiftState::substitutionFlags()
{
    return cssParserSubstitutionFlags(parse(*this).context());
}

uint32_t CSSParserSwiftState::syntaxTextLength()
{
    return parse(*this).syntaxText.length();
}

uint16_t CSSParserSwiftState::syntaxTextCharacter(uint32_t offset)
{
    auto text = parse(*this).syntaxText;
    return offset < text.length() ? text[offset] : 0;
}

void CSSParserSwiftState::setSyntaxTextToTokens(uint32_t start, uint32_t end)
{
    auto& tokens = static_cast<CSSParserSwiftStateData&>(*this).tokens;
    RELEASE_ASSERT(start <= end && end <= tokens.size());
    auto& parse = WebCore::parse(*this);
    parse.serializedSyntax = CSSParserTokenRange { tokens.subspan(start, end - start) }.serialize();
    parse.syntaxText = parse.serializedSyntax;
}

AtomString CSSParserSwiftState::syntaxIdent(uint32_t start, uint32_t end)
{
    auto text = parse(*this).syntaxText;
    RELEASE_ASSERT(start <= end && end <= text.length());
    auto tokenizer = CSSTokenizer::tryCreate(text.substring(start, end - start));
    if (!tokenizer)
        return nullAtom();

    auto range = tokenizer->tokenRange();
    range.consumeWhitespace();
    if (range.peek().type() != IdentToken || !isValidCustomIdentifier(range.peek().id()))
        return nullAtom();

    auto value = range.consumeIncludingWhitespace().value();
    return range.atEnd() ? value.toAtomString() : nullAtom();
}

void CSSParserSwiftState::setSyntax(const CSSCustomPropertySyntax& syntax)
{
    // Swift can make an imported enum of any raw value.
    for (auto& component : syntax.definition)
        RELEASE_ASSERT(component.type <= CSSCustomPropertySyntax::Type::Unknown && component.multiplier <= CSSCustomPropertySyntax::Multiplier::CommaList);
    parse(*this).syntax = syntax;
}

} // namespace WebCore
