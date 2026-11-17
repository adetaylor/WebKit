// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2025 Apple Inc. All rights reserved.
// Copyright (C) 2025-2026 Samuel Weinig <sam@webkit.org>
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

internal import WebCore_Private.Core.CSSAtRuleID
internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSParserEnum
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes
internal import WebCore_Private.Core.CSSParserSwiftState

// The rule parser: rule lists, the dispatch of at-rules, qualified and style rules, the contents of blocks, and
// declarations with !important. It reads the tokens of a CSSParserSwiftState by index. The rules and the parsed
// properties stay in the CSSParser of the request, in its nesting contexts: each style rule's body and each group
// rule's body is a context there. makeStyleRule() and makeAtRule() leave the rule they make in the state, and the
// rule parser then places it (in the context around it, in the style sheet or as the request's result) or drops it.
// The at-rules are in CSSParserAtRulesSwift.swift.

// MARK: - Constants

/// `CSSParser::AllowedRules`, whose values CSSParser.cpp asserts.
enum CSSParserAllowedRules {
    static var charsetRules: UInt8 { 0 }
    static var layerStatementRules: UInt8 { 1 }
    static var importRules: UInt8 { 2 }
    static var namespaceRules: UInt8 { 3 }
    static var regularRules: UInt8 { 4 }
    static var keyframeRules: UInt8 { 5 }
    static var fontFeatureValuesRules: UInt8 { 6 }
    static var conditionalGroupRules: UInt8 { 7 }
    static var noRules: UInt8 { 8 }
}

/// `CSSParserEnum::NestedContextType`.
enum CSSParserNestedContextType {
    static var style: UInt8 { WebCore.CSSParserEnum.NestedContextType.Style.rawValue }
    static var scope: UInt8 { WebCore.CSSParserEnum.NestedContextType.Scope.rawValue }
    static var function: UInt8 { WebCore.CSSParserEnum.NestedContextType.Function.rawValue }
}

/// StyleRuleType values, and StyleRuleBase's predicates on them.
enum CSSParserRuleType {
    static var style: UInt8 { WebCore.StyleRuleType.Style.rawValue }
    static var charset: UInt8 { WebCore.StyleRuleType.Charset.rawValue }
    static var importRule: UInt8 { WebCore.StyleRuleType.Import.rawValue }
    static var namespace: UInt8 { WebCore.StyleRuleType.Namespace.rawValue }
    static var page: UInt8 { WebCore.StyleRuleType.Page.rawValue }
    static var layerStatement: UInt8 { WebCore.StyleRuleType.LayerStatement.rawValue }
    static var positionTry: UInt8 { WebCore.StyleRuleType.PositionTry.rawValue }
    static var function: UInt8 { WebCore.StyleRuleType.Function.rawValue }

    /// `StyleRuleBase::isStyleRule`.
    static func isStyleRule(_ type: UInt8) -> Bool {
        type == WebCore.StyleRuleType.Style.rawValue || type == WebCore.StyleRuleType.StyleWithNesting.rawValue
            || type == WebCore.StyleRuleType.NestedDeclarations.rawValue
    }

    /// `StyleRuleBase::isGroupRule`.
    static func isGroupRule(_ type: UInt8) -> Bool {
        type == WebCore.StyleRuleType.Media.rawValue || type == WebCore.StyleRuleType.Supports.rawValue
            || type == WebCore.StyleRuleType.LayerBlock.rawValue || type == WebCore.StyleRuleType.Container.rawValue
            || type == WebCore.StyleRuleType.Scope.rawValue || type == WebCore.StyleRuleType.StartingStyle.rawValue
            || type == WebCore.StyleRuleType.Function.rawValue
    }

    /// `ruleDoesNotAllowImportant`: the rule types whose declarations cannot be !important.
    static func doesNotAllowImportant(_ type: UInt8) -> Bool {
        type == WebCore.StyleRuleType.CounterStyle.rawValue || type == WebCore.StyleRuleType.FontFace.rawValue
            || type == WebCore.StyleRuleType.FontPaletteValues.rawValue || type == WebCore.StyleRuleType.Keyframe.rawValue
            || type == WebCore.StyleRuleType.PositionTry.rawValue || type == WebCore.StyleRuleType.ViewTransition.rawValue
            || type == WebCore.StyleRuleType.EnvironmentMap.rawValue || type == WebCore.StyleRuleType.Function.rawValue
    }

    /// The rule types whose declarations and blocks the inspector's observer is told about.
    static func isObserved(_ type: UInt8) -> Bool {
        type == WebCore.StyleRuleType.Style.rawValue || type == WebCore.StyleRuleType.Keyframe.rawValue
            || type == WebCore.StyleRuleType.Page.rawValue
    }
}

/// `CSSAtRuleID`'s values.
enum CSSParserAtRuleID {
    static var invalid: UInt8 { UInt8(WebCore.CSSAtRuleInvalid.rawValue) }
    static var charset: UInt8 { UInt8(WebCore.CSSAtRuleCharset.rawValue) }
    static var fontFace: UInt8 { UInt8(WebCore.CSSAtRuleFontFace.rawValue) }
    static var importRule: UInt8 { UInt8(WebCore.CSSAtRuleImport.rawValue) }
    static var keyframes: UInt8 { UInt8(WebCore.CSSAtRuleKeyframes.rawValue) }
    static var media: UInt8 { UInt8(WebCore.CSSAtRuleMedia.rawValue) }
    static var namespaceRule: UInt8 { UInt8(WebCore.CSSAtRuleNamespace.rawValue) }
    static var page: UInt8 { UInt8(WebCore.CSSAtRulePage.rawValue) }
    static var positionTry: UInt8 { UInt8(WebCore.CSSAtRulePositionTry.rawValue) }
    static var supports: UInt8 { UInt8(WebCore.CSSAtRuleSupports.rawValue) }
    static var viewTransition: UInt8 { UInt8(WebCore.CSSAtRuleViewTransition.rawValue) }
    static var webkitKeyframes: UInt8 { UInt8(WebCore.CSSAtRuleWebkitKeyframes.rawValue) }
    static var counterStyle: UInt8 { UInt8(WebCore.CSSAtRuleCounterStyle.rawValue) }
    static var layer: UInt8 { UInt8(WebCore.CSSAtRuleLayer.rawValue) }
    static var container: UInt8 { UInt8(WebCore.CSSAtRuleContainer.rawValue) }
    static var propertyRule: UInt8 { UInt8(WebCore.CSSAtRuleProperty.rawValue) }
    static var fontFeatureValues: UInt8 { UInt8(WebCore.CSSAtRuleFontFeatureValues.rawValue) }
    static var stylistic: UInt8 { UInt8(WebCore.CSSAtRuleStylistic.rawValue) }
    static var styleset: UInt8 { UInt8(WebCore.CSSAtRuleStyleset.rawValue) }
    static var characterVariant: UInt8 { UInt8(WebCore.CSSAtRuleCharacterVariant.rawValue) }
    static var swash: UInt8 { UInt8(WebCore.CSSAtRuleSwash.rawValue) }
    static var ornaments: UInt8 { UInt8(WebCore.CSSAtRuleOrnaments.rawValue) }
    static var annotation: UInt8 { UInt8(WebCore.CSSAtRuleAnnotation.rawValue) }
    static var fontPaletteValues: UInt8 { UInt8(WebCore.CSSAtRuleFontPaletteValues.rawValue) }
    static var scope: UInt8 { UInt8(WebCore.CSSAtRuleScope.rawValue) }
    static var startingStyle: UInt8 { UInt8(WebCore.CSSAtRuleStartingStyle.rawValue) }
    static var functionRule: UInt8 { UInt8(WebCore.CSSAtRuleFunction.rawValue) }
    static var environmentMap: UInt8 { UInt8(WebCore.CSSAtRuleEnvironmentMap.rawValue) }
}

/// The kinds of rule list consumeRuleList parses: a style sheet's, a block's, @keyframes' and @font-feature-values'.
enum CSSParserRuleList {
    case topLevel
    case regular
    case keyframes
    case fontFeatureValues
}

/// The rules allowed in a block (`CSSParser::BlockAllowedRule`); every block allows declarations.
struct CSSParserBlockAllowedRules {
    var qualifiedRules = false
    var atRules = false
}

/// `maximumRuleListNestingLevel`: a style rule or a group rule's body nested deeper is dropped.
private var cssParserMaximumRuleListNestingLevel: UInt32 { 128 }

/// For the inspector, an invalid declaration that may instead be consumed as a nested style rule: its tokens, whose
/// offsets the observer is given once the caller knows it was not.
struct CSSParserDeferredInvalidDeclaration {
    var start: Int
    var end: Int
    var isImportant: Bool
}

// MARK: - Token helpers

extension CSSParserTokenKind {
    static var cdo: UInt8 { UInt8(WebCore.CDOToken.rawValue) }
    static var cdc: UInt8 { UInt8(WebCore.CDCToken.rawValue) }
    static var leftParenthesis: UInt8 { UInt8(WebCore.LeftParenthesisToken.rawValue) }
}

/// Whether the value of token `index` equals `letters`, compared ASCII case-insensitively
/// (`equalLettersIgnoringASCIICase`, whose `letters` are lowercase ASCII).
@inline(always)
func cssParserRuleTokenValueEquals(_ s: borrowing WebCore.CSSParserSwiftState, _ index: Int, _ letters: Swift.String) -> Bool {
    let length = s.valueLength(index)
    // The letters are a short ASCII literal; a token's value is shorter than UInt32.max.
    guard Int(length) == letters.utf8.count else {
        return false
    }
    var offset: UInt32 = 0
    for expected in letters.utf8 {
        // toASCIILower of the code unit: only A to Z change.
        var character = s.valueCharacter(index, offset)
        if character >= 0x41 && character <= 0x5A {
            character |= 0x20
        }
        guard character == UInt16(expected) else {
            return false
        }
        offset &+= 1 // Below length, a UInt32.
    }
    return true
}

/// `CSSParserTokenRange::trimTrailingWhitespace`.
func cssParserTrimTrailingWhitespace(_ s: borrowing WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) {
    while range.end > range.index && CSSParserTokenKind.isWhitespace(s.type(range.end &- 1)) { // Above index, so above 0.
        range.end &-= 1 // Above index.
    }
}

/// `CSSParser::consumeTrailingImportantAndWhitespace`: whether `range` ends in `! important`, which it then no longer
/// holds. Trailing whitespace is trimmed off `range` either way.
func cssParserConsumeTrailingImportant(_ s: borrowing WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> Bool {
    cssParserTrimTrailingWhitespace(s, &range)
    guard range.end &- range.index >= 2 else { // end is at least index.
        return false
    }
    var withoutImportant = range
    withoutImportant.end &-= 1 // Above index: the range has two tokens or more.
    let last = withoutImportant.end
    guard s.type(last) == CSSParserTokenKind.ident && cssParserRuleTokenValueEquals(s, last, "important") else {
        return false
    }
    cssParserTrimTrailingWhitespace(s, &withoutImportant)
    // consumeLast() of an empty range is the EOF token, which is not a delimiter.
    guard !withoutImportant.atEnd else {
        return false
    }
    withoutImportant.end &-= 1 // Above index.
    let bang = withoutImportant.end
    guard s.type(bang) == CSSParserTokenKind.delimiter && s.delimiter(bang) == 0x21 else { // '!'
        return false
    }
    cssParserTrimTrailingWhitespace(s, &withoutImportant)
    range = withoutImportant
    return true
}

/// A token index as the state's members take it. Indices are at most the token count, which runOnTokens checks is
/// below UInt32.max.
private func cssParserTokenIndex(_ index: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: index)
}

// MARK: - The rule parser

/// What CSSParser's rule parsing keeps outside its nesting contexts: whether the inspector's observer is told (it is
/// not while @supports tests a declaration), what the context enables for substitution functions, the ancestor rule
/// types and the rule list nesting level. The request's ruleParserState() is read once; setUsesStyleBasedEditability,
/// the only member that changes what it reports during a request, is called through this parser, which follows it.
struct CSSParserRuleParser: ~Copyable {
    var observing: Bool
    let substitutionFlags: UInt32
    let state: UInt32
    /// The last ancestor rule type, 0 for none, else 1 more than its CSSParserNestedContextType, starting from the
    /// request's nested context (requestInputs' third byte), and the number of style rules on the ancestor stack.
    var lastAncestor: UInt8
    var styleAncestors: UInt32
    /// The number of rule lists being consumed, the current one included.
    var ruleListNestingLevel: UInt32 = 0
    /// Whether the style sheet does not use style-based editability yet.
    var scanForEditability: Bool
    /// The storage of every style rule prelude's selector parse past the arena's inline nodes.
    var selectorStorage = CSSParserSelectorArenaStorage()

    init(_ s: inout WebCore.CSSParserSwiftState) {
        state = s.ruleParserState()
        observing = state & WebCore.CSSParserSwiftRuleParserObserving != 0
        substitutionFlags = s.substitutionFlags()
        lastAncestor = UInt8(truncatingIfNeeded: s.requestInputs() &>> 16)
        styleAncestors = lastAncestor == CSSParserNestedContextType.style &+ 1 ? 1 : 0 // Small constants.
        scanForEditability = state & WebCore.CSSParserSwiftRuleParserScanForEditability != 0
    }

    // MARK: Nesting

    /// `lastAncestorRuleType()`: 0 for none, else 1 more than the type, as the selector parser takes it.
    func lastAncestorRuleType(_ s: inout WebCore.CSSParserSwiftState) -> UInt8 {
        lastAncestor
    }

    /// Pushes `type`, a CSSParserNestedContextType, on the ancestor stack; returns what popAncestorRuleType restores.
    mutating func pushAncestorRuleType(_ s: inout WebCore.CSSParserSwiftState, _ type: UInt8) -> UInt8 {
        let previous = lastAncestor
        lastAncestor = type &+ 1 // A CSSParserNestedContextType, below 3.
        if type == CSSParserNestedContextType.style {
            styleAncestors &+= 1 // At most one per token.
        }
        return previous
    }

    /// Pops the `type` pushAncestorRuleType pushed, which returned `previous`.
    mutating func popAncestorRuleType(_ s: inout WebCore.CSSParserSwiftState, _ type: UInt8, _ previous: UInt8) {
        lastAncestor = previous
        if type == CSSParserNestedContextType.style {
            styleAncestors &-= 1 // Pushed above.
        }
    }

    func isStyleNestedContext(_ s: inout WebCore.CSSParserSwiftState) -> Bool {
        let last = lastAncestorRuleType(&s)
        return last != 0 && last != CSSParserNestedContextType.function &+ 1 // Small constants.
    }

    func isFunctionNestedContext(_ s: inout WebCore.CSSParserSwiftState) -> Bool {
        lastAncestorRuleType(&s) == CSSParserNestedContextType.function &+ 1 // Small constants.
    }

    func hasStyleRuleAncestor(_ s: inout WebCore.CSSParserSwiftState) -> Bool {
        styleAncestors != 0
    }

    // MARK: Observer

    /// One event for the inspector's observer, on the tokens [start, end) (CSSParserSwiftObserverEvent says which end
    /// it reads). Only while observing.
    func observe(
        _ s: inout WebCore.CSSParserSwiftState,
        _ event: WebCore.CSSParserSwiftObserverEvent,
        _ start: Int,
        _ end: Int,
        _ flags: UInt8 = 0
    ) {
        s.observe(event, cssParserTokenIndex(start), cssParserTokenIndex(end), flags)
    }

    /// `observeSelectors`: the style rule's header and each selector of its list, split at top-level commas.
    private func observeSelectors(_ s: inout WebCore.CSSParserSwiftState, _ prelude: CSSParserTokenSpan) {
        var selectors = prelude
        selectors.consumeWhitespace(s)
        let original = selectors
        observe(&s, .StartRuleHeader, original.index, original.end, CSSParserRuleType.style)
        while !selectors.atEnd {
            let selectorStart = selectors.index
            while !selectors.atEnd && selectors.peekType(s) != CSSParserTokenKind.comma {
                selectors.consumeComponentValue(s)
            }
            let selectorEnd = selectors.index
            selectors.consumeIncludingWhitespace(s)
            observe(&s, .ObserveSelector, selectorStart, selectorEnd)
        }
        observe(&s, .EndRuleHeader, original.index, original.end)
    }

    // MARK: Rule lists

    /// `computeNewAllowedRules`: the rules allowed after a rule of type `ruleType`.
    private static func computeNewAllowedRules(_ allowedRules: UInt8, _ ruleType: UInt8) -> UInt8 {
        if allowedRules == CSSParserAllowedRules.fontFeatureValuesRules || allowedRules == CSSParserAllowedRules.keyframeRules
            || allowedRules == CSSParserAllowedRules.noRules
        {
            return allowedRules
        }
        if ruleType == CSSParserRuleType.charset {
            return CSSParserAllowedRules.layerStatementRules
        }
        if allowedRules <= CSSParserAllowedRules.layerStatementRules && ruleType == CSSParserRuleType.layerStatement {
            return CSSParserAllowedRules.layerStatementRules
        }
        if ruleType == CSSParserRuleType.importRule {
            return CSSParserAllowedRules.importRules
        }
        if ruleType == CSSParserRuleType.namespace {
            return CSSParserAllowedRules.namespaceRules
        }
        return CSSParserAllowedRules.regularRules
    }

    /// `consumeRuleList`: each rule of `range`, placed at `target` as it is made. Returns whether the first rule seen
    /// was valid.
    mutating func consumeRuleList(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: CSSParserTokenSpan,
        _ ruleList: CSSParserRuleList,
        _ target: WebCore.CSSParserSwiftRuleTarget
    ) -> Bool {
        var range = range
        var allowedRules: UInt8
        switch ruleList {
        case .topLevel: allowedRules = CSSParserAllowedRules.charsetRules
        case .regular: allowedRules = CSSParserAllowedRules.regularRules
        case .keyframes: allowedRules = CSSParserAllowedRules.keyframeRules
        case .fontFeatureValues: allowedRules = CSSParserAllowedRules.fontFeatureValuesRules
        }

        var seenRule = false
        var firstRuleValid = false
        while !range.atEnd {
            let type = range.peekType(s)
            let rule: UInt8?
            if CSSParserTokenKind.isWhitespace(type) {
                range.consumeWhitespace(s)
                continue
            } else if type == CSSParserTokenKind.atKeyword {
                rule = consumeAtRule(&s, &range, allowedRules)
            } else if ruleList == .topLevel && (type == CSSParserTokenKind.cdo || type == CSSParserTokenKind.cdc) {
                range.consume()
                continue
            } else {
                rule = consumeQualifiedRule(&s, &range, allowedRules)
            }
            if !seenRule {
                seenRule = true
                firstRuleValid = rule != nil
            }
            if let rule {
                allowedRules = Self.computeNewAllowedRules(allowedRules, rule)
                s.placeRule(target)
            }
        }
        return firstRuleValid
    }

    // MARK: At-rules

    /// `CSSParser::consumeAtRule` at an at-keyword token: the type of the rule made, now the state's to place, or nil.
    /// `range` is left after the rule, or after the tokens consumed trying to make one.
    mutating func consumeAtRule(_ s: inout WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan, _ allowedRules: UInt8) -> UInt8?
    {
        let nameToken = range.index
        range.consumeIncludingWhitespace(s)
        let preludeStart = range.index
        while !range.atEnd && range.peekType(s) != CSSParserTokenKind.leftBrace && range.peekType(s) != CSSParserTokenKind.semicolon {
            range.consumeComponentValue(s)
        }
        let preludeEnd = range.index
        let id = s.atRuleID(nameToken)

        if range.atEnd || range.peekType(s) == CSSParserTokenKind.semicolon {
            range.consume()
            return makeAtRule(&s, id, allowedRules, preludeStart, preludeEnd, nil)
        }

        let block = range.consumeBlock(s)
        if allowedRules == CSSParserAllowedRules.keyframeRules {
            return nil // Parse error, no at-rules supported inside @keyframes
        }
        if allowedRules == CSSParserAllowedRules.noRules {
            return nil
        }

        if allowedRules == CSSParserAllowedRules.conditionalGroupRules {
            switch id {
            case CSSParserAtRuleID.media, CSSParserAtRuleID.supports, CSSParserAtRuleID.container:
                break
            case CSSParserAtRuleID.functionRule:
                if !isFunctionNestedContext(&s) {
                    return nil
                }
            default:
                return nil
            }
        }

        return makeAtRule(&s, id, allowedRules, preludeStart, preludeEnd, block)
    }

    /// The rule the at-rule `id` makes from the prelude [preludeStart, preludeEnd) and the block: its type, or nil.
    private mutating func makeAtRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ id: UInt8,
        _ allowedRules: UInt8,
        _ preludeStart: Int,
        _ preludeEnd: Int,
        _ block: CSSParserTokenSpan?
    ) -> UInt8? {
        consumeAtRuleBody(&s, id, allowedRules, CSSParserTokenSpan(index: preludeStart, end: preludeEnd), block)
    }

    /// `consumeNestedGroupRules`: the body of a group rule (@media, @supports, @container, @layer, @scope,
    /// @starting-style), into the innermost context, which the caller made for it; left empty past the nesting limit.
    /// Inside a style rule its orphan declarations become a leading nested declarations rule.
    mutating func consumeNestedGroupRules(_ s: inout WebCore.CSSParserSwiftState, _ block: CSSParserTokenSpan) {
        ruleListNestingLevel &+= 1 // At most one per token.
        defer {
            ruleListNestingLevel &-= 1 // Added above.
        }
        guard ruleListNestingLevel <= cssParserMaximumRuleListNestingLevel else {
            return
        }
        // Declarations are allowed if there is either a parent style rule or parent scope rule.
        // https://drafts.csswg.org/css-cascade-6/#scoped-declarations
        if isStyleNestedContext(&s) {
            consumeStyleBlock(&s, block, CSSParserRuleType.style, inRuleList: true)
            if s.propertyCount() != 0 {
                // This at-rule contains orphan declarations, we attach them to a nested declaration rule. Web
                // Inspector expects this rule to occur first in the children rules, and to contain all orphaned
                // property declarations.
                s.wrapProperties(2)
                if observing {
                    observe(&s, .MarkRuleBodyContainsImplicitlyNestedProperties, 0, 0)
                }
            }
        } else if isFunctionNestedContext(&s) {
            // Only allow <declaration-rule-list> in @function context. Its declarations are all wrapped, so the
            // context's own properties stay empty.
            consumeDeclarationRuleList(&s, block, CSSParserRuleType.function)
        } else {
            _ = consumeRuleList(&s, block, .regular, .Context)
        }
    }

    // MARK: Qualified and style rules

    /// `consumeBlockCheckingForEditability` at a token that starts a block: its contents, noting in the style sheet a
    /// `-webkit-user-modify` ident anywhere in it.
    private mutating func consumeBlockCheckingForEditability(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan
    ) -> CSSParserTokenSpan {
        let start = range.index &+ 1 // index is below end, at the block's start.
        // CSSParserTokenRange's counter is unsigned: an unmatched block end wraps it, as here.
        var nestingLevel: UInt32 = 0
        repeat {
            let token = range.index
            range.index &+= 1 // Below end: the loop runs while tokens remain.
            let blockType = s.blockType(token)
            if blockType == CSSParserTokenKind.blockStart {
                nestingLevel &+= 1
            } else if blockType == CSSParserTokenKind.blockEnd {
                nestingLevel &-= 1
            }
            if scanForEditability && s.type(token) == CSSParserTokenKind.ident
                && cssParserRuleTokenValueEquals(s, token, "-webkit-user-modify")
            {
                s.setUsesStyleBasedEditability()
                scanForEditability = false
            }
        } while nestingLevel != 0 && !range.atEnd
        // With the block closed, index is above start.
        return CSSParserTokenSpan(index: start, end: nestingLevel != 0 ? range.index : range.index &- 1)
    }

    /// `consumeQualifiedRule` (https://drafts.csswg.org/css-syntax/#consume-a-qualified-rule): the type of the rule
    /// made, or nil. `range` is left after the rule or after the error recovery of its context.
    mutating func consumeQualifiedRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan,
        _ allowedRules: UInt8
    ) -> UInt8? {
        let initialRange = range
        let isNestedStyleRule = hasStyleRuleAncestor(&s) && allowedRules <= CSSParserAllowedRules.regularRules
        let preludeStart = range.index

        // Parsing a selector (aka a component value) should stop at the first semicolon (and goes to error recovery)
        // instead of consuming the whole list of declarations (in nested context).
        // At top level (aka non nested context), it's the normal rule list error recovery and we don't need this.
        while !range.atEnd && range.peekType(s) != CSSParserTokenKind.leftBrace
            && (!isNestedStyleRule || range.peekType(s) != CSSParserTokenKind.semicolon)
        {
            range.consumeComponentValue(s)
        }

        if range.atEnd {
            return nil // Parse error, EOF instead of qualified rule block
        }

        // See comment above
        if isNestedStyleRule && range.peekType(s) == CSSParserTokenKind.semicolon {
            range.consume()
            return nil
        }

        // https://github.com/w3c/csswg-drafts/issues/9336#issuecomment-1719806755
        if range.peekType(s) == CSSParserTokenKind.leftBrace {
            var rangeCopyForDashedIdent = initialRange
            // This rule is ambiguous with a custom property because it looks like "--ident: ...."
            if rangeCopyForDashedIdent.peekType(s) == CSSParserTokenKind.ident && s.isDashedIdent(rangeCopyForDashedIdent.index) {
                rangeCopyForDashedIdent.consumeIncludingWhitespace(s)
                if rangeCopyForDashedIdent.peekType(s) == CSSParserTokenKind.colon {
                    if isStyleNestedContext(&s) {
                        // Error, consume until semicolon or end of block.
                        while !range.atEnd && range.peekType(s) != CSSParserTokenKind.semicolon {
                            range.consumeComponentValue(s)
                        }
                        if range.peekType(s) == CSSParserTokenKind.semicolon {
                            range.consume()
                        }
                        return nil
                    }
                    // Error, consume until end of block.
                    _ = range.consumeBlock(s)
                    return nil
                }
            }
        }

        let prelude = CSSParserTokenSpan(index: preludeStart, end: range.index)
        let block = consumeBlockCheckingForEditability(&s, &range)

        if allowedRules <= CSSParserAllowedRules.regularRules {
            return consumeStyleRule(&s, prelude, block)
        }
        if allowedRules == CSSParserAllowedRules.keyframeRules {
            return makeAtRule(&s, WebCore.CSSParserSwiftKeyframeStyleRule, allowedRules, prelude.index, prelude.end, block)
        }
        return nil
    }

    /// `consumeStyleRule`: a StyleRule, or a StyleRuleWithNesting where the rule has nested rules, an explicit `&` or
    /// a style rule around it; nil past the nesting limit or for an invalid selector list.
    mutating func consumeStyleRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        ruleListNestingLevel &+= 1 // At most one per token.
        defer {
            ruleListNestingLevel &-= 1 // Added above.
        }
        guard ruleListNestingLevel <= cssParserMaximumRuleListNestingLevel else {
            return nil
        }

        var selectors = CSSParserTokenCursor(prelude.index, prelude.end)
        let nestedContext = lastAncestorRuleType(&s)
        guard
            cssParserParseSelectorList(
                &s,
                &selectors,
                nestedContext: nestedContext,
                forgiving: false,
                disallowPseudoElements: false,
                storage: &selectorStorage
            )
        else {
            return nil // Parse error, invalid selector list
        }
        // The new context keeps the selector list until makeStyleRule.
        s.pushNestingContext(true)
        if observing {
            observeSelectors(&s, prelude)
        }
        let previous = pushAncestorRuleType(&s, CSSParserNestedContextType.style)
        consumeStyleBlock(&s, block, CSSParserRuleType.style, inRuleList: false)
        popAncestorRuleType(&s, CSSParserNestedContextType.style, previous)
        return s.makeStyleRule(isStyleNestedContext(&s)) &- 1 // Not 0.
    }

    // MARK: Blocks

    /// `consumeDeclarationList`: <declaration-list>, only declarations; at-rules and qualified rules are invalid.
    mutating func consumeDeclarationList(_ s: inout WebCore.CSSParserSwiftState, _ range: CSSParserTokenSpan, _ ruleType: UInt8) {
        consumeBlockContent(&s, range, ruleType, CSSParserBlockAllowedRules(), inRuleList: false)
    }

    /// `consumeDeclarationRuleList`: <declaration-rule-list>, declarations and at-rules.
    mutating func consumeDeclarationRuleList(_ s: inout WebCore.CSSParserSwiftState, _ range: CSSParserTokenSpan, _ ruleType: UInt8) {
        consumeBlockContent(&s, range, ruleType, CSSParserBlockAllowedRules(atRules: true), inRuleList: false)
    }

    /// `consumeStyleBlock`: <block-contents>, declarations, qualified rules and at-rules.
    mutating func consumeStyleBlock(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: CSSParserTokenSpan,
        _ ruleType: UInt8,
        inRuleList: Bool
    ) {
        consumeBlockContent(&s, range, ruleType, CSSParserBlockAllowedRules(qualifiedRules: true, atRules: true), inRuleList: inRuleList)
    }

    /// consumeBlockContent's `storeDeclarations`: the first declaration block is kept aside until the end of the
    /// block (except in @function); each later one, if not empty, becomes a nested declarations rule (in @function,
    /// a function declarations rule).
    private func storeDeclarations(_ s: inout WebCore.CSSParserSwiftState, _ ruleType: UInt8, _ hasInitialDeclarationBlock: inout Bool) {
        if !hasInitialDeclarationBlock && ruleType != CSSParserRuleType.function {
            hasInitialDeclarationBlock = true
            s.swapInitialDeclarationBlock()
            return
        }
        if s.propertyCount() == 0 {
            return // Nothing to wrap
        }
        s.wrapProperties(ruleType == CSSParserRuleType.function ? 1 : 0)
    }

    /// `consumeBlockContent` (https://drafts.csswg.org/css-syntax/#consume-block-contents) into the innermost
    /// context: its properties, and its rules where `allowed` has them.
    mutating func consumeBlockContent(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: CSSParserTokenSpan,
        _ ruleType: UInt8,
        _ allowed: CSSParserBlockAllowedRules,
        inRuleList: Bool
    ) {
        var range = range
        let useObserver = observing && CSSParserRuleType.isObserved(ruleType)
        if useObserver {
            if !inRuleList {
                observe(&s, .StartRuleBody, range.index, range.end)
            }
            observe(&s, .SkipCommentsBefore, range.index, range.end, 1)
        }

        var hasInitialDeclarationBlock = false
        while !range.atEnd {
            let initialRange = range
            let type = range.peekType(s)
            if CSSParserTokenKind.isWhitespace(type) || type == CSSParserTokenKind.semicolon {
                range.consume()
            } else if type == CSSParserTokenKind.ident {
                let declarationStart = range.index
                if useObserver {
                    observe(&s, .YieldCommentsBefore, range.index, range.end)
                }
                consumeUntilSemicolon(s, &range)
                let declaration = CSSParserTokenSpan(index: declarationStart, end: range.index)
                let (isValidDeclaration, deferredInvalidDeclaration) = consumeDeclaration(&s, declaration, ruleType)
                if useObserver {
                    observe(&s, .SkipCommentsBefore, range.index, range.end, 0)
                }
                if !isValidDeclaration {
                    // If it's not a valid declaration, we rewind the parser and try to parse it as a nested style rule.
                    range = initialRange
                    let didConsumeNestedRule = consumeNestedRuleOrInvalidSyntax(
                        &s,
                        &range,
                        initialRange,
                        ruleType,
                        allowed,
                        &hasInitialDeclarationBlock
                    )
                    // Text like `a:hover { ... }` starts like a declaration but may be consumed as a nested style rule
                    // instead. Only notify the observer of an invalid declaration if it was not.
                    if let deferredInvalidDeclaration, !didConsumeNestedRule {
                        observe(
                            &s,
                            .ObserveProperty,
                            deferredInvalidDeclaration.start,
                            deferredInvalidDeclaration.end,
                            deferredInvalidDeclaration.isImportant ? 1 : 0
                        )
                    }
                }
            } else if type == CSSParserTokenKind.atKeyword {
                if allowed.atRules {
                    let allowedRules =
                        ruleType == CSSParserRuleType.function
                        ? CSSParserAllowedRules.conditionalGroupRules : CSSParserAllowedRules.regularRules
                    guard let rule = consumeAtRule(&s, &range, allowedRules) else {
                        continue
                    }
                    // Style rule only support nested group rule.
                    // Small constants.
                    if lastAncestorRuleType(&s) == CSSParserNestedContextType.style &+ 1 && !CSSParserRuleType.isGroupRule(rule) {
                        s.placeRule(.Discard)
                        continue
                    }
                    storeDeclarations(&s, ruleType, &hasInitialDeclarationBlock)
                    s.placeRule(.Context)
                } else {
                    // Rule will be ignored, but consuming the tokens is necessary.
                    if consumeAtRule(&s, &range, CSSParserAllowedRules.noRules) != nil {
                        s.placeRule(.Discard)
                    }
                }
            } else {
                _ = consumeNestedRuleOrInvalidSyntax(&s, &range, initialRange, ruleType, allowed, &hasInitialDeclarationBlock)
            }
        }

        // Store trailing declarations if any
        storeDeclarations(&s, ruleType, &hasInitialDeclarationBlock)

        // Restore the initial declaration block
        if hasInitialDeclarationBlock {
            s.swapInitialDeclarationBlock()
        }

        // Yield remaining comments
        if useObserver {
            observe(&s, .YieldCommentsBefore, range.index, range.end)
            if !inRuleList {
                observe(&s, .EndRuleBody, range.index, range.end)
            }
        }
    }

    /// consumeBlockContent's `consumeUntilSemicolon`.
    private func consumeUntilSemicolon(_ s: borrowing WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) {
        while !range.atEnd && range.peekType(s) != CSSParserTokenKind.semicolon {
            range.consumeComponentValue(s)
        }
    }

    /// consumeBlockContent's `consumeNestedRuleOrInvalidSyntax`: a nested style rule where qualified rules are allowed,
    /// else the error recovery of a declaration list. Returns whether a rule was consumed.
    private mutating func consumeNestedRuleOrInvalidSyntax(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan,
        _ initialRange: CSSParserTokenSpan,
        _ ruleType: UInt8,
        _ allowed: CSSParserBlockAllowedRules,
        _ hasInitialDeclarationBlock: inout Bool
    ) -> Bool {
        if allowed.qualifiedRules {
            // For block, we try to consume a qualified rule (~= a style rule).
            // This consumes tokens and deals with error recovery
            // in the case of invalid syntax.
            guard let rule = consumeQualifiedRule(&s, &range, CSSParserAllowedRules.regularRules) else {
                return false
            }
            guard CSSParserRuleType.isStyleRule(rule) else {
                s.placeRule(.Discard)
                return false
            }
            storeDeclarations(&s, ruleType, &hasInitialDeclarationBlock)
            s.placeRule(.Context)
            return true
        }
        // https://drafts.csswg.org/css-syntax/#typedef-declaration-list
        // For declaration list, we consume invalid tokens until next recovery point.
        range = initialRange
        consumeUntilSemicolon(s, &range)
        return false
    }

    // MARK: Declarations

    /// `consumeDeclaration` (https://drafts.csswg.org/css-syntax/#consume-declaration) of `range`, which starts with an
    /// ident token: whether it added properties to the innermost context, and, for the inspector, an invalid
    /// declaration the caller reports unless it consumes the tokens as a nested style rule.
    func consumeDeclaration(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: CSSParserTokenSpan,
        _ ruleType: UInt8
    ) -> (Bool, CSSParserDeferredInvalidDeclaration?) {
        let rangeCopy = range // For inspector callbacks
        var range = range

        let token = range.index
        range.consumeIncludingWhitespace(s)
        var propertyID = s.propertyID(token)
        // consume(): the colon, or whatever is there.
        let colon = range.peekType(s)
        range.consume()
        guard colon == CSSParserTokenKind.colon else {
            return (false, nil) // Parse error
        }

        range.consumeWhitespace(s)

        let important = cssParserConsumeTrailingImportant(s, &range)
        if important && CSSParserRuleType.doesNotAllowImportant(ruleType) {
            return (false, nil)
        }

        let oldPropertiesCount = s.propertyCount()

        // In @page, `size` aliases the always-exposed `page-size` descriptor; remap
        // before the isExposed() check so gating the shorthand can't disable it.
        if ruleType == CSSParserRuleType.page && propertyID == WebCore.CSSPropertyID.Size.rawValue {
            propertyID = WebCore.CSSPropertyID.PageSize.rawValue
        }

        if !s.isPropertyExposed(propertyID) {
            propertyID = WebCore.CSSPropertyID.Invalid.rawValue
        }

        // @position-try doesn't allow custom properties.
        if propertyID == WebCore.CSSPropertyID.Invalid.rawValue && cssParserIsCustomPropertyName(s, token)
            && ruleType != CSSParserRuleType.positionTry
        {
            consumeCustomPropertyValue(&s, cssParserTokenIndex(token), range, important)
        }

        if propertyID != WebCore.CSSPropertyID.Invalid.rawValue {
            s.parseValue(propertyID, cssParserTokenIndex(range.index), cssParserTokenIndex(range.end), important, ruleType)
        }

        let didParseNewProperties = s.propertyCount() != oldPropertiesCount
        if observing && CSSParserRuleType.isObserved(ruleType) {
            // The caller notifies the observer of an invalid declaration once it knows it was not consumed as a
            // nested style rule instead.
            if !didParseNewProperties {
                return (false, CSSParserDeferredInvalidDeclaration(start: rangeCopy.index, end: rangeCopy.end, isImportant: important))
            }
            observe(&s, .ObserveProperty, rangeCopy.index, rangeCopy.end, (important ? 1 : 0) | 2)
        }
        return (didParseNewProperties, nil)
    }

    /// `consumeCustomPropertyValue`: the custom property named by token `name` (UInt32.max: the request's name), empty
    /// for no tokens, else as CSSSubstitutionParser::parseDeclarationValue makes it, appended to the innermost
    /// context's properties if it is valid.
    func consumeCustomPropertyValue(_ s: inout WebCore.CSSParserSwiftState, _ name: UInt32, _ range: CSSParserTokenSpan, _ important: Bool)
    {
        let kind = range.atEnd ? 0 : CSSParserSubstitution.declarationValueKind(s, range.index..<range.end, substitutionFlags)
        s.appendCustomProperty(name, cssParserTokenIndex(range.index), cssParserTokenIndex(range.end), kind, important)
    }
}

// MARK: - Requests

/// The StyleSheet and StyleSheetForInspector requests (CSSParser::parseStyleSheet, parseStyleSheetForInspector): every
/// rule into the CSSParser's style sheet; the result is whether the first rule was valid.
func cssParserParseStyleSheetRequest(_ s: inout WebCore.CSSParserSwiftState, forInspector: Bool) {
    var parser = CSSParserRuleParser(&s)
    let range = CSSParserTokenSpan(index: 0, end: s.count())
    let firstRuleValid = parser.consumeRuleList(&s, range, .topLevel, forInspector ? .StyleSheetForInspector : .StyleSheet)
    s.setResult(firstRuleValid ? 1 : 0)
}

/// The DeclarationList and DeclarationListForInspector requests: the declarations into the innermost context, for the
/// StyleRuleType in requestInputs' second byte.
func cssParserParseDeclarationListRequest(_ s: inout WebCore.CSSParserSwiftState) {
    var parser = CSSParserRuleParser(&s)
    let ruleType = UInt8(truncatingIfNeeded: s.requestInputs() &>> 8)
    parser.consumeDeclarationList(&s, CSSParserTokenSpan(index: 0, end: s.count()), ruleType)
}

/// The Rule request (CSSParser::parseRule): one rule, at-rule or qualified, of the AllowedRules in requestInputs' low
/// byte, with nothing after it but whitespace, as the request's rule.
func cssParserParseRuleRequest(_ s: inout WebCore.CSSParserSwiftState) {
    var parser = CSSParserRuleParser(&s)
    let allowedRules = UInt8(truncatingIfNeeded: s.requestInputs())
    var range = CSSParserTokenSpan(index: 0, end: s.count())
    range.consumeWhitespace(s)
    if range.atEnd {
        return // Parse error, empty rule
    }
    let rule =
        range.peekType(s) == CSSParserTokenKind.atKeyword
        ? parser.consumeAtRule(&s, &range, allowedRules) : parser.consumeQualifiedRule(&s, &range, allowedRules)
    guard rule != nil else {
        return // Parse error, failed to consume rule
    }
    range.consumeWhitespace(s)
    s.placeRule(range.atEnd ? .Result : .Discard) // Else a parse error, trailing garbage
}

/// The AtRule request (CSSParser::consumeAtRule): one at-rule at the first token, of the AllowedRules in
/// requestInputs' low byte, as the request's rule; the result is the number of tokens consumed.
func cssParserConsumeAtRuleRequest(_ s: inout WebCore.CSSParserSwiftState) {
    var parser = CSSParserRuleParser(&s)
    let allowedRules = UInt8(truncatingIfNeeded: s.requestInputs())
    var range = CSSParserTokenSpan(index: 0, end: s.count())
    if parser.consumeAtRule(&s, &range, allowedRules) != nil {
        s.placeRule(.Result)
    }
    s.setResult(cssParserTokenIndex(range.index))
}

/// The CustomPropertyValue request (CSSParser::parseCustomPropertyValue): the request's custom property, !important
/// where requestInputs' top byte is 1, into the innermost context.
func cssParserParseCustomPropertyValueRequest(_ s: inout WebCore.CSSParserSwiftState) {
    let parser = CSSParserRuleParser(&s)
    let important = s.requestInputs() &>> 24 == 1
    var range = CSSParserTokenSpan(index: 0, end: s.count())
    range.consumeWhitespace(s)
    cssParserTrimTrailingWhitespace(s, &range)
    parser.consumeCustomPropertyValue(&s, UInt32.max, range, important)
}
