// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
// Copyright (C) 2025 Samuel Weinig <sam@webkit.org>
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

#pragma once

#include <WebCore/CSSParserEnum.h>
#include <WebCore/CSSParserTokenRange.h>
#include <WebCore/CSSProperty.h>
#include <WebCore/CSSPropertyNames.h>
#include <WebCore/StyleRule.h>
#include <memory>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class CSSParserObserver;
class CSSParserObserverWrapper;
class CSSTokenizer;
class StyleRuleKeyframe;
class StyleRuleBase;
class StyleSheetContents;
class ImmutableStyleProperties;
class Element;
class MutableStyleProperties;

enum class CSSParserSwiftRequest : uint8_t;
struct CSSParserSwiftParseInputs;
struct CSSParserSwiftState;

class CSSParser {
    WTF_MAKE_NONCOPYABLE(CSSParser);
public:
    enum class ParseResult {
        Changed,
        Unchanged,
        Error
    };

    enum class AllowedRules : uint8_t {
        // As per css-syntax, css-cascade and css-namespaces, @charset rules
        // must come first, followed by @import then @namespace.
        // AllowImportRules actually means we allow @import and any rules that
        // may follow it, i.e. @namespace rules and regular rules.
        // AllowCharsetRules and AllowNamespaceRules behave similarly.
        CharsetRules,
        LayerStatementRules,
        ImportRules,
        NamespaceRules,
        RegularRules,
        KeyframeRules,
        FontFeatureValuesRules,
        ConditionalGroupRules,
        NoRules, // For parsing at-rules inside declaration lists (without nesting support)
    };

    CSSParser(const CSSParserContext&, StringView string LIFETIME_BOUND, StyleSheetContents* = nullptr, CSSParserObserverWrapper* = nullptr);
    ~CSSParser();

    static ParseResult parseValue(MutableStyleProperties&, CSSPropertyID, StringView, IsImportant, const CSSParserContext&);
    static ParseResult parseCustomPropertyValue(MutableStyleProperties&, const AtomString& propertyName, StringView, IsImportant, const CSSParserContext&);
    WEBCORE_EXPORT static bool parseDeclarationList(MutableStyleProperties&, StringView, const CSSParserContext&);

    static Ref<ImmutableStyleProperties> parseInlineStyleDeclaration(StringView, const Element&);
    WEBCORE_EXPORT static RefPtr<StyleRuleBase> parseRule(StringView, const CSSParserContext&, StyleSheetContents*, AllowedRules, CSSParserEnum::NestedContext = { });
    static RefPtr<StyleRuleKeyframe> parseKeyframeRule(StringView, const CSSParserContext&);
    static RefPtr<StyleRuleNestedDeclarations> parseNestedDeclarations(StringView, const CSSParserContext&);

    static void parseStyleSheet(StringView, const CSSParserContext&, StyleSheetContents&);

    // This function updates the range it's given.
    RefPtr<StyleRuleBase> consumeAtRule(CSSParserTokenRange&, AllowedRules);

    WEBCORE_EXPORT static void parseDeclarationListForInspector(StringView, const CSSParserContext&, CSSParserObserver&);
    WEBCORE_EXPORT static void parseStyleSheetForInspector(StringView, const CSSParserContext&, StyleSheetContents&, CSSParserObserver&);

    static IsImportant consumeTrailingImportantAndWhitespace(CSSParserTokenRange&);

    const CSSParserContext& context() const LIFETIME_BOUND { return m_context; }
    const CSSTokenizer* tokenizer() const LIFETIME_BOUND { return m_tokenizer.get(); }

private:
    friend struct CSSParserSwiftState;

    struct NestingContext {
        // FIXME: Can we build StylePropertySets directly?
        // FIXME: Investigate using a smaller inline buffer
        ParsedPropertyVector m_parsedProperties;
        Vector<Ref<StyleRuleBase>> m_parsedRules;
        std::unique_ptr<ParsedPropertyVector> m_initialDeclarationBlock;
    };

    // Runs cssParseWithSwift for `request` on the tokens of `range`, with this parser's context, style sheet and
    // nesting state. Returns the request's result.
    uint32_t runWithSwift(CSSParserTokenRange, CSSParserSwiftRequest, CSSParserSwiftParseInputs&&, RefPtr<StyleRuleBase>* rule = nullptr);

    NestingContext& topContext()
    {
        ASSERT(!m_nestingContextStack.isEmpty());
        return m_nestingContextStack.last();
    }

    Vector<NestingContext, 16> m_nestingContextStack { 1 };

    const CSSParserContext& m_context;

    const RefPtr<StyleSheetContents> m_styleSheet;
    const std::unique_ptr<CSSTokenizer> m_tokenizer;

    // For the inspector
    WeakPtr<CSSParserObserverWrapper> m_observerWrapper;
};

} // namespace WebCore
