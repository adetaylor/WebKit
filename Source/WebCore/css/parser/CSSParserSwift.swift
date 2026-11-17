// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

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

/// Parses the tokens of `state` for `request`, a `CSSParserSwiftRequest`, leaving what the request produces in the
/// parse behind `state`.
///
/// `state` is the `CSSParserSwiftStateData` that `CSSParserSwiftParse::runOnTokens` makes on its stack for this call
/// only, the only place one is made, over the `CSSParserSwiftParse` of the C++ entry point that called it, on that
/// entry's stack. Its tokens are a span of the entry's `CSSTokenizer`, which outlives the call, or of the token range
/// the entry was given, whose owner outlives the entry. While it is live, Swift calls only `state`'s members: the
/// token readers of `CSSParserSwiftTokenReader`, `requestInputs`, `setResult`, `substitutionFlags`, `syntaxTextLength`,
/// `syntaxTextCharacter`, `setSyntaxTextToTokens`, `syntaxIdent` and `setSyntax`, the selector parser's token readers
/// (`parseIntegerInValue` to `typeAndDelimiter`), `setResultAtom`, the selector list's atoms and names
/// (`selectorAtom`, `selectorQualifiedName`) and `setSelectorList`, which makes the `CSSSelectorList` in the parse of
/// a `CSSSelectorListStorage` Swift made with `CSSSelectorListStorage::createWithCapacity` and `Ref::get` and wrote
/// with the storage's own writer, which reaches no state; the rule parser's members (`ruleParserState` to
/// `supportsFontFunction`), which read and change the nesting state of the request's `CSSParser` and call its rule
/// constructors, the property parser and the font consumers; and `isCSSWideKeyword`, `isValidCustomIdentifier`,
/// `AtomString::isNull`, the `CSSCustomPropertySyntax` it builds, and `CSSSelector::pseudoClassRequiresArgument`,
/// `CSSSelector::pseudoElementRequiresArgument`, `isLogicalCombinationPseudoClass` and `isTreeStructuralPseudoClass`,
/// which read only their argument. Some members call `cssParseWithSwift` again, with a parse and a state of their own:
/// `makeAtRule`, through the `@property` syntax parser and the media and container query parsers, and `parseValue`,
/// through the property parser. No pointer to `state` or to its parse leaves `runOnTokens` or the entry, so whatever
/// those members run, nothing but these member calls reaches `state` or changes it during the call.
@_expose(Cxx)
func cssParseWithSwift(_ state: inout WebCore.CSSParserSwiftState, _ request: UInt8) {
    // Compared with each enumerator's own value: an imported enum's init(rawValue:) accepts any value.
    switch request {
    case WebCore.CSSParserSwiftRequest.ContainsSubstitutionFunctions.rawValue:
        let flags = state.substitutionFlags()
        let count = state.count()
        let contains = CSSParserSubstitution.containsSubstitutionFunctions(state, 0..<count, flags)
        state.setResult(contains ? 1 : 0)
    case WebCore.CSSParserSwiftRequest.DeclarationValue.rawValue:
        let flags = state.substitutionFlags()
        let count = state.count()
        let kind = CSSParserSubstitution.declarationValueKind(state, 0..<count, flags)
        state.setResult(kind)
    case WebCore.CSSParserSwiftRequest.Syntax.rawValue:
        CSSParserSyntax.parseSyntax(&state)
    case WebCore.CSSParserSwiftRequest.SyntaxType.rawValue:
        CSSParserSyntax.consumeType(&state)
    case WebCore.CSSParserSwiftRequest.SelectorList.rawValue:
        cssParserParseSelectorListRequest(&state)
    case WebCore.CSSParserSwiftRequest.PseudoElement.rawValue:
        cssParserParsePseudoElementRequest(&state)
    case WebCore.CSSParserSwiftRequest.QualifiedName.rawValue:
        cssParserQualifiedNameRequest(&state)
    case WebCore.CSSParserSwiftRequest.SupportsCondition.rawValue:
        cssParserSupportsConditionRequest(&state)
    case WebCore.CSSParserSwiftRequest.MarginTrimInlineValue.rawValue:
        cssParserMarginTrimInlineValueRequest(&state)
    case WebCore.CSSParserSwiftRequest.StyleSheet.rawValue:
        cssParserParseStyleSheetRequest(&state, forInspector: false)
    case WebCore.CSSParserSwiftRequest.StyleSheetForInspector.rawValue:
        cssParserParseStyleSheetRequest(&state, forInspector: true)
    case WebCore.CSSParserSwiftRequest.DeclarationList.rawValue, WebCore.CSSParserSwiftRequest.DeclarationListForInspector.rawValue:
        cssParserParseDeclarationListRequest(&state)
    case WebCore.CSSParserSwiftRequest.Rule.rawValue:
        cssParserParseRuleRequest(&state)
    case WebCore.CSSParserSwiftRequest.AtRule.rawValue:
        cssParserConsumeAtRuleRequest(&state)
    case WebCore.CSSParserSwiftRequest.CustomPropertyValue.rawValue:
        cssParserParseCustomPropertyValueRequest(&state)
    default:
        // Only the parser's entry points call this, each with a request one of the cases above handles.
        preconditionFailure("unhandled CSSParserSwiftRequest")
    }
}
