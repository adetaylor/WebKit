// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes
internal import WebCore_Private.Core.CSSParserSwiftState

// The @supports parser (CSSSupportsParser): conditions of `@supports` rules, `@import ... supports()` and
// `CSS.supports()`, over the tokens of a CSSParserSwiftState. Results are CSSSupportsParser::SupportsResult values.

/// `CSSSupportsParser::SupportsResult`, whose values CSSSupportsParser.cpp asserts.
enum CSSParserSupportsResult {
    static var unsupported: UInt32 { 0 }
    static var supported: UInt32 { 1 }
    static var invalid: UInt32 { 2 }
}

/// `CSSSupportsParser`: a declaration is tested by the rule parser, which does not tell the inspector's observer.
struct CSSParserSupportsParser: ~Copyable {
    private var rules: CSSParserRuleParser

    init(_ s: inout WebCore.CSSParserSwiftState) {
        rules = CSSParserRuleParser(&s)
        // Suppress the observer during condition evaluation because this is a speculative parse to test declaration
        // validity, not an actual property declaration in the style sheet.
        rules.observing = false
    }

    /// `consumeCondition`.
    mutating func consumeCondition(_ s: inout WebCore.CSSParserSwiftState, _ range: CSSParserTokenSpan) -> UInt32 {
        var range = range
        if range.peekType(s) == CSSParserTokenKind.ident && cssParserRuleTokenValueEquals(s, range.index, "not") {
            return consumeNegation(&s, range)
        }

        var result = false
        // ClauseType: 0 unresolved, 1 conjunction, 2 disjunction.
        var clauseType = 0
        let previousTokenType = CSSParserTokenKind.ident

        while true {
            let nextResult = consumeConditionInParenthesis(&s, &range, previousTokenType)
            if nextResult == CSSParserSupportsResult.invalid {
                return CSSParserSupportsResult.invalid
            }
            let nextSupported = nextResult == CSSParserSupportsResult.supported
            if clauseType == 0 {
                result = nextSupported
            } else if clauseType == 1 {
                result = result && nextSupported
            } else {
                result = result || nextSupported
            }

            if range.atEnd {
                break
            }
            range.consumeWhitespace(s)
            if range.atEnd {
                break
            }

            let token = range.index
            if s.type(token) != CSSParserTokenKind.ident {
                return CSSParserSupportsResult.invalid
            }

            if clauseType == 0 {
                clauseType = s.valueLength(token) == 3 ? 1 : 2
            }
            if (clauseType == 1 && !cssParserRuleTokenValueEquals(s, token, "and"))
                || (clauseType == 2 && !cssParserRuleTokenValueEquals(s, token, "or"))
            {
                return CSSParserSupportsResult.invalid
            }

            range.consume()
            if !CSSParserTokenKind.isWhitespace(range.peekType(s)) {
                return CSSParserSupportsResult.invalid
            }
            range.consumeWhitespace(s)
        }
        return result ? CSSParserSupportsResult.supported : CSSParserSupportsResult.unsupported
    }

    /// `consumeNegation`.
    private mutating func consumeNegation(_ s: inout WebCore.CSSParserSwiftState, _ range: CSSParserTokenSpan) -> UInt32 {
        var range = range
        let tokenType = range.peekType(s)
        if range.peekType(s) == CSSParserTokenKind.ident {
            range.consume()
        }
        if !CSSParserTokenKind.isWhitespace(range.peekType(s)) {
            return CSSParserSupportsResult.invalid
        }
        range.consumeWhitespace(s)
        let result = consumeConditionInParenthesis(&s, &range, tokenType)
        range.consumeWhitespace(s)
        if !range.atEnd || result == CSSParserSupportsResult.invalid {
            return CSSParserSupportsResult.invalid
        }
        return result == CSSParserSupportsResult.supported ? CSSParserSupportsResult.unsupported : CSSParserSupportsResult.supported
    }

    /// `consumeSupportsFunction`: <function-token> <any-value>? | <supports-selector-fn> | <supports-font-format-fn> |
    /// <supports-font-tech-fn> | <supports-at-rule-fn> | <supports-named-feature-fn>.
    private mutating func consumeSupportsFunction(_ s: inout WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> UInt32 {
        if range.peekType(s) != CSSParserTokenKind.function {
            return CSSParserSupportsResult.invalid
        }

        switch s.identifier(range.index) {
        case WebCore.CSSValueID.Selector.rawValue:
            // <supports-selector-fn> = selector( <complex-selector> )
            var block = range.consumeBlock(s)
            block.consumeWhitespace(s)
            return cssParserSupportsComplexSelector(&s, block.index, block.end)
                ? CSSParserSupportsResult.supported : CSSParserSupportsResult.unsupported
        case WebCore.CSSValueID.FontFormat.rawValue:
            return consumeSupportsFontFunction(&s, &range, technology: false)
        case WebCore.CSSValueID.FontTech.rawValue:
            return consumeSupportsFontFunction(&s, &range, technology: true)
        case WebCore.CSSValueID.AtRule.rawValue:
            return consumeSupportsAtRuleFunction(&s, &range)
        case WebCore.CSSValueID.NamedFeature.rawValue:
            return consumeSupportsNamedFeatureFunction(&s, &range)
        default: // Unknown functions should parse as unsupported.
            range.consumeComponentValue(s)
            return CSSParserSupportsResult.unsupported
        }
    }

    /// <supports-font-format-fn> and <supports-font-tech-fn>, which the font consumers parse.
    private func consumeSupportsFontFunction(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan,
        technology: Bool
    ) -> UInt32 {
        let result = s.supportsFontFunction(technology, cssParserTokenIndex(range.index), cssParserTokenIndex(range.end))
        // The tokens consumed are at most the range's.
        range.index &+= Int(truncatingIfNeeded: result &>> 2)
        return UInt32(truncatingIfNeeded: result & 3)
    }

    /// `CSSPropertyParserHelpers::consumeFunction` at a function token: its arguments, whitespace trimmed at the start,
    /// with the whitespace after the function consumed.
    private func consumeFunction(_ s: borrowing WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> CSSParserTokenSpan {
        var contents = range.consumeBlock(s)
        range.consumeWhitespace(s)
        contents.consumeWhitespace(s)
        return contents
    }

    /// <supports-at-rule-fn> = at-rule( <at-keyword-token> )
    private func consumeSupportsAtRuleFunction(_ s: inout WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> UInt32 {
        var function = consumeFunction(s, &range)
        let atKeywordToken = function.index
        let atKeywordType = function.peekType(s)
        function.consumeIncludingWhitespace(s)
        if atKeywordType != CSSParserTokenKind.atKeyword {
            return CSSParserSupportsResult.invalid
        }
        if !function.atEnd {
            return CSSParserSupportsResult.invalid
        }

        switch s.atRuleID(atKeywordToken) {
        case CSSParserAtRuleID.webkitKeyframes, CSSParserAtRuleID.annotation,
            CSSParserAtRuleID.characterVariant, CSSParserAtRuleID.container,
            CSSParserAtRuleID.counterStyle, CSSParserAtRuleID.fontFace,
            CSSParserAtRuleID.fontFeatureValues, CSSParserAtRuleID.fontPaletteValues,
            CSSParserAtRuleID.importRule, CSSParserAtRuleID.keyframes,
            CSSParserAtRuleID.layer, CSSParserAtRuleID.media,
            CSSParserAtRuleID.namespaceRule, CSSParserAtRuleID.ornaments,
            CSSParserAtRuleID.page, CSSParserAtRuleID.positionTry,
            CSSParserAtRuleID.propertyRule, CSSParserAtRuleID.scope,
            CSSParserAtRuleID.startingStyle, CSSParserAtRuleID.styleset,
            CSSParserAtRuleID.stylistic, CSSParserAtRuleID.supports,
            CSSParserAtRuleID.swash, CSSParserAtRuleID.viewTransition:
            return CSSParserSupportsResult.supported
        case CSSParserAtRuleID.functionRule:
            return rules.substitutionFlags & WebCore.CSSParserSwiftFunctionAtRuleEnabled != 0
                ? CSSParserSupportsResult.supported : CSSParserSupportsResult.unsupported
        case CSSParserAtRuleID.environmentMap:
            return rules.state & WebCore.CSSParserSwiftRuleParserSpatialPortal != 0
                ? CSSParserSupportsResult.supported : CSSParserSupportsResult.unsupported
        case CSSParserAtRuleID.invalid, CSSParserAtRuleID.charset:
            // Per spec, @charset is not an at-rule.
            return CSSParserSupportsResult.unsupported
        default:
            return CSSParserSupportsResult.invalid
        }
    }

    /// <supports-named-feature-fn> = named-feature( <ident> )
    private func consumeSupportsNamedFeatureFunction(_ s: inout WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> UInt32 {
        var functionArgs = consumeFunction(s, &range)
        // consumeIdentRaw: any ident.
        if functionArgs.peekType(s) != CSSParserTokenKind.ident {
            return CSSParserSupportsResult.invalid
        }
        functionArgs.consumeIncludingWhitespace(s)
        if !functionArgs.atEnd {
            return CSSParserSupportsResult.invalid
        }
        // No named feature is supported: anchor-position-follows-transforms and single-axis-scroll-container are not
        // implemented yet.
        return CSSParserSupportsResult.unsupported
    }

    /// `consumeSupportsFeatureOrGeneralEnclosed`: <supports-feature> | <general-enclosed>.
    mutating func consumeSupportsFeatureOrGeneralEnclosed(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan
    ) -> UInt32 {
        if range.peekType(s) == CSSParserTokenKind.function {
            let result = consumeSupportsFunction(&s, &range)
            if result != CSSParserSupportsResult.invalid {
                return result
            }
        }

        if range.peekType(s) != CSSParserTokenKind.ident {
            return CSSParserSupportsResult.unsupported
        }

        if rules.state & WebCore.CSSParserSwiftRuleParserMarginTrimInlineQuirk != 0 && cssParserIsMarginTrimInlineDeclaration(&s, range) {
            return CSSParserSupportsResult.supported
        }

        // CSSParser::supportsDeclaration: a new nesting context isolates the declaration from those before or after.
        s.pushNestingContext(false)
        let (isValid, _) = rules.consumeDeclaration(&s, range, CSSParserRuleType.style)
        s.popNestingContext()
        return isValid ? CSSParserSupportsResult.supported : CSSParserSupportsResult.unsupported
    }

    /// `consumeConditionInParenthesis`: <supports-in-parens> = ( <supports-condition> ) | <supports-feature> |
    /// <general-enclosed>.
    private mutating func consumeConditionInParenthesis(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan,
        _ startTokenType: UInt8
    ) -> UInt32 {
        if startTokenType == CSSParserTokenKind.ident && range.peekType(s) != CSSParserTokenKind.leftParenthesis {
            return consumeSupportsFunction(&s, &range)
        }

        var innerRange = range.consumeBlock(s)
        innerRange.consumeWhitespace(s)

        let result = consumeCondition(&s, innerRange)
        if result != CSSParserSupportsResult.invalid {
            return result
        }
        return consumeSupportsFeatureOrGeneralEnclosed(&s, &innerRange)
    }
}

/// A token index as the state's members take it. Indices are at most the token count, which runOnTokens checks is
/// below UInt32.max.
private func cssParserTokenIndex(_ index: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: index)
}

/// `isMarginTrimInlineKeyword`: the CSSWG resolved that margin-trim has no inline keywords, but some sites still
/// feature-detect them.
private func cssParserIsMarginTrimInlineKeyword(_ s: inout WebCore.CSSParserSwiftState, _ range: CSSParserTokenSpan) -> Bool {
    var range = range
    range.consumeWhitespace(s)
    // consumeIncludingWhitespace().id(): CSSValueID::Invalid for any token but an ident, and for the EOF token.
    let id = !range.atEnd && range.peekType(s) == CSSParserTokenKind.ident ? s.identifier(range.index) : WebCore.CSSValueID.Invalid.rawValue
    range.consumeIncludingWhitespace(s)
    switch id {
    case WebCore.CSSValueID.Inline.rawValue, WebCore.CSSValueID.InlineStart.rawValue, WebCore.CSSValueID.InlineEnd.rawValue:
        return range.atEnd
    default:
        return false
    }
}

/// `isMarginTrimInlineDeclaration`, at an ident token.
private func cssParserIsMarginTrimInlineDeclaration(_ s: inout WebCore.CSSParserSwiftState, _ range: CSSParserTokenSpan) -> Bool {
    var range = range
    let property = s.propertyID(range.index)
    range.consumeIncludingWhitespace(s)
    if property != WebCore.CSSPropertyID.MarginTrim.rawValue {
        return false
    }
    let colon = range.peekType(s)
    range.consume()
    if colon != CSSParserTokenKind.colon {
        return false
    }
    return cssParserIsMarginTrimInlineKeyword(&s, range)
}

/// `CSSSupportsParser::supportsCondition`: the condition in `range`, a CSSParserSupportsResult.
func cssParserSupportsCondition(
    _ s: inout WebCore.CSSParserSwiftState,
    _ range: CSSParserTokenSpan,
    allowBareDeclarationAndGeneralEnclosed: Bool
) -> UInt32 {
    var parser = CSSParserSupportsParser(&s)
    // FIXME: The spec allows leading whitespace in @supports but not CSS.supports,
    // but major browser vendors allow it in CSS.supports also.
    var range = range
    range.consumeWhitespace(s)
    var result = parser.consumeCondition(&s, range)
    if allowBareDeclarationAndGeneralEnclosed && result == CSSParserSupportsResult.invalid {
        // window.CSS.supports requires parsing as-if the condition was wrapped in
        // parenthesis. The only productions that wouldn't have parsed above are the
        // declaration condition or the general enclosed productions.
        result = parser.consumeSupportsFeatureOrGeneralEnclosed(&s, &range)
    }
    return result
}

// MARK: - Requests

/// The SupportsCondition request (CSSSupportsParser::supportsCondition), in the CSSSupportsParser::ParsingMode of
/// requestInputs' top byte; the result is a CSSSupportsParser::SupportsResult.
func cssParserSupportsConditionRequest(_ s: inout WebCore.CSSParserSwiftState) {
    let allowBareDeclarationAndGeneralEnclosed = s.requestInputs() &>> 24 == 1
    let range = CSSParserTokenSpan(index: 0, end: s.count())
    let result = cssParserSupportsCondition(&s, range, allowBareDeclarationAndGeneralEnclosed: allowBareDeclarationAndGeneralEnclosed)
    s.setResult(result)
}

/// The MarginTrimInlineValue request (CSSSupportsParser::isMarginTrimInlineValue).
func cssParserMarginTrimInlineValueRequest(_ s: inout WebCore.CSSParserSwiftState) {
    let range = CSSParserTokenSpan(index: 0, end: s.count())
    s.setResult(cssParserIsMarginTrimInlineKeyword(&s, range) ? 1 : 0)
}
