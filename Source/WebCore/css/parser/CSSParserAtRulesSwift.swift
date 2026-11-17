// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2025 Apple Inc. All rights reserved.
// Copyright (C) 2025-2026 Samuel Weinig <sam@webkit.org>
// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
// Copyright (C) 2003 Lars Knoll (knoll@kde.org)
// Copyright (C) 2004, 2005, 2006, 2008, 2014 Apple Inc. All rights reserved.
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
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

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

// The at-rules: each one's prelude, the inspector's observer events for it, and its body, which the rule parser
// consumes into a new context. Each ends in one call of the state's makeAtRule, which makes the rule from token
// indices and that context, and leaves it for the rule parser to place. What Swift cannot make (media and container
// queries, cascade layer names, keyframe keys, font family lists, the descriptors' post-processing) makeAtRule() makes
// from the tokens; where such a part decides whether the rule is valid, makeAtRule() is first called, before the body,
// to check it.

// MARK: - Constants

extension CSSParserTokenKind {
    fileprivate static var stringToken: UInt8 { UInt8(WebCore.StringToken.rawValue) }
    fileprivate static var url: UInt8 { UInt8(WebCore.UrlToken.rawValue) }
}

/// The CSSSelector::PagePseudoClass a `@page` pseudo-class name is, ASCII case-insensitively, or nil.
private func cssParserPagePseudoClass(_ s: inout WebCore.CSSParserSwiftState, _ token: Int) -> UInt8? {
    if cssParserRuleTokenValueEquals(s, token, "first") {
        return WebCore.CSSSelector.PagePseudoClass.First.rawValue
    }
    if cssParserRuleTokenValueEquals(s, token, "left") {
        return WebCore.CSSSelector.PagePseudoClass.Left.rawValue
    }
    if cssParserRuleTokenValueEquals(s, token, "right") {
        return WebCore.CSSSelector.PagePseudoClass.Right.rawValue
    }
    return nil
}

/// A token index as makeAtRule takes it. Indices are at most the token count, which runOnTokens checks is below
/// UInt32.max.
private func cssParserAtRuleToken(_ index: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: index)
}

/// No token: makeAtRule() reads it as the EOF token, whose value is null.
private var cssParserNoToken: UInt32 { UInt32.max }

/// `range` as makeAtRule takes it.
private func cssParserAtRuleRange(_ range: CSSParserTokenSpan) -> WebCore.CSSParserSwiftTokenRange {
    var result = WebCore.CSSParserSwiftTokenRange()
    result.start = cssParserAtRuleToken(range.index)
    result.end = cssParserAtRuleToken(range.end)
    return result
}

/// An empty range, for a range makeAtRule does not read.
private var cssParserNoRange: CSSParserTokenSpan { CSSParserTokenSpan(index: 0, end: 0) }

/// `CSSPropertyParserHelpers::consumeFunction` at a function token: its contents, without their leading whitespace;
/// `range` is left after the function and the whitespace after it.
private func cssParserConsumeFunction(_ s: borrowing WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> CSSParserTokenSpan {
    var contents = range.consumeBlock(s)
    range.consumeWhitespace(s)
    contents.consumeWhitespace(s)
    return contents
}

/// `consumeStringOrURI`: the token whose value is the URI (makeAtRule()'s atom of it may be null, which the caller
/// asks it), or nil where there is no URI token.
private func cssParserConsumeStringOrURI(_ s: inout WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> UInt32? {
    let type = range.peekType(s)
    if type == CSSParserTokenKind.stringToken || type == CSSParserTokenKind.url {
        let token = range.index
        range.consumeIncludingWhitespace(s)
        return cssParserAtRuleToken(token)
    }
    guard type == CSSParserTokenKind.function && cssParserRuleTokenValueEquals(s, range.index, "url") else {
        return nil
    }
    var contents = range.consumeBlock(s)
    // consumeIncludingWhitespace(): the first token, or EOF in an empty range.
    let uri = contents.atEnd ? nil : contents.index
    let uriType = contents.peekType(s)
    contents.consumeIncludingWhitespace(s)
    if uriType == CSSParserTokenKind.badString || !contents.atEnd {
        return nil
    }
    return uri.map(cssParserAtRuleToken) ?? cssParserNoToken
}

/// `consumeCascadeLayerName`: the tokens of the name (its idents and the `.` between them), or nil; an empty span for
/// the anonymous name where `allowAnonymous` and `range` is empty. `range` is left after the name and the whitespace
/// after it.
private func cssParserConsumeCascadeLayerName(
    _ s: borrowing WebCore.CSSParserSwiftState,
    _ range: inout CSSParserTokenSpan,
    allowAnonymous: Bool
) -> CSSParserTokenSpan? {
    if range.atEnd {
        return allowAnonymous ? CSSParserTokenSpan(index: range.index, end: range.index) : nil
    }
    let start = range.index
    while true {
        // consume(): the next token, or EOF at the end, which is not an ident.
        let nameType = range.peekType(s)
        range.consume()
        guard nameType == CSSParserTokenKind.ident else {
            return nil
        }
        guard range.peekType(s) == CSSParserTokenKind.delimiter && s.delimiter(range.index) == 0x2E else { // '.'
            break
        }
        range.consume()
    }
    let name = CSSParserTokenSpan(index: start, end: range.index)
    range.consumeWhitespace(s)
    return name
}

/// `consumeEagerlyResolvableDashedIdentRaw`: an ident token whose value starts with `--`, which `range` is then
/// after, with the whitespace after it; else nil.
private func cssParserConsumeDashedIdent(_ s: borrowing WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> Int? {
    guard
        range.peekType(s) == CSSParserTokenKind.ident && s.tokenValueLength(range.index) >= 2
            && s.tokenValueCharacter(range.index, 0) == 0x2D && s.tokenValueCharacter(range.index, 1) == 0x2D // '-'
    else {
        return nil
    }
    let token = range.index
    range.consumeIncludingWhitespace(s)
    return token
}

/// The CSSValueID of an ident token, as `CSSParserToken::id()`.
private func cssParserIdentifier(_ s: borrowing WebCore.CSSParserSwiftState, _ token: Int) -> WebCore.CSSValueID {
    // Never nil: an imported C++ enum's init(rawValue:) does not check its value.
    WebCore.CSSValueID(rawValue: s.identifier(token)) ?? .Invalid
}

// MARK: - <css-type>

extension CSSParserSyntax {
    /// `CSSCustomPropertySyntax::consumeType` on `range`, which it leaves after the tokens it took, whether the type
    /// parsed or not. Reads the syntax text through the state, which it sets to the type's tokens.
    static func consumeType(_ s: inout WebCore.CSSParserSwiftState, _ range: inout CSSParserTokenSpan) -> Parsed? {
        if range.peekType(s) == CSSParserTokenKind.function {
            // <type()> = type( <syntax> )
            guard cssParserRuleTokenValueEquals(s, range.index, "type") else {
                return nil
            }
            let contents = cssParserConsumeFunction(s, &range)
            s.setSyntaxTextToTokens(cssParserAtRuleToken(contents.index), cssParserAtRuleToken(contents.end))
            guard let parsed = parse(&s), !parsed.containsUnknownType else {
                return nil
            }
            return parsed
        }
        let start = range.index
        while !range.atEnd {
            let type = range.peekType(s)
            if type == CSSParserTokenKind.colon || type == CSSParserTokenKind.comma || CSSParserTokenKind.isWhitespace(type) {
                break
            }
            range.consume()
        }
        range.consumeWhitespace(s)
        // The type's tokens with the whitespace after them.
        s.setSyntaxTextToTokens(cssParserAtRuleToken(start), cssParserAtRuleToken(range.index))
        guard let parsed = parse(&s), parsed.count == 1, !parsed.containsUnknownType else {
            return nil
        }
        return parsed
    }
}

/// An @function parameter whose prelude parsed: its name token, its type (the universal syntax where nil), and its
/// default value's tokens.
// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
struct CSSParserFunctionParameter {
    var name: Int
    var type: CSSParserSyntax.Parsed?
    var defaultValue: CSSParserTokenSpan?
}

// MARK: - At-rules

extension CSSParserRuleParser {
    /// makeAtRule: the rule of `type`, or with CSSParserSwiftAtRuleCheck or CSSParserSwiftAtRulePart one of its
    /// parts. The type made (`type`'s value), or nil where the part does not parse.
    @discardableResult
    private func make(
        _ s: inout WebCore.CSSParserSwiftState,
        _ type: WebCore.StyleRuleType,
        flags: UInt32 = 0,
        token: UInt32 = cssParserNoToken,
        _ a: CSSParserTokenSpan = cssParserNoRange,
        _ b: CSSParserTokenSpan = cssParserNoRange,
        _ c: CSSParserTokenSpan = cssParserNoRange
    ) -> UInt8? {
        let made = s.makeAtRule(type.rawValue, flags, token, cssParserAtRuleRange(a), cssParserAtRuleRange(b), cssParserAtRuleRange(c))
        return made != 0 ? made &- 1 : nil // Not 0.
    }

    /// `startRuleHeader(type, startOffset)` and `endRuleHeader(endOffset)` of the tokens [start, end).
    private func observeHeader(_ s: inout WebCore.CSSParserSwiftState, _ type: WebCore.StyleRuleType, _ start: Int, _ end: Int) {
        observe(&s, .StartRuleHeader, start, end, type.rawValue)
        observe(&s, .EndRuleHeader, start, end)
    }

    /// A rule whose body the observer is not shown: `startRuleBody` and `endRuleBody` at the header's end offset
    /// (StartRuleBody's flag 1: the end offset rather than the previous token's start).
    private func observeEmptyBody(_ s: inout WebCore.CSSParserSwiftState, _ end: Int) {
        observe(&s, .StartRuleBody, end, end, 1)
        observe(&s, .EndRuleBody, end, end)
    }

    /// `startRuleBody(previousTokenStartOffset(block))`.
    private func observeBodyStart(_ s: inout WebCore.CSSParserSwiftState, _ block: CSSParserTokenSpan) {
        observe(&s, .StartRuleBody, block.index, block.end)
    }

    /// `endRuleBody(endOffset(block))`.
    private func observeBodyEnd(_ s: inout WebCore.CSSParserSwiftState, _ block: CSSParserTokenSpan) {
        observe(&s, .EndRuleBody, block.index, block.end)
    }

    /// The observer events of a rule with an empty body, the whole header [start, end).
    private func observeRuleWithoutBody(_ s: inout WebCore.CSSParserSwiftState, _ type: WebCore.StyleRuleType, _ start: Int, _ end: Int) {
        if observing {
            observeHeader(&s, type, start, end)
            observeEmptyBody(&s, end)
        }
    }

    /// A group rule's header and body: the observer's events around consumeNestedGroupRules, into a new context that
    /// makeAtRule() closes.
    private mutating func consumeGroupRuleBody(
        _ s: inout WebCore.CSSParserSwiftState,
        _ type: WebCore.StyleRuleType,
        _ headerStart: Int,
        _ headerEnd: Int,
        _ block: CSSParserTokenSpan
    ) {
        if observing {
            observeHeader(&s, type, headerStart, headerEnd)
            observeBodyStart(&s, block)
        }
        s.pushNestingContext(false)
        consumeNestedGroupRules(&s, block)
        if observing {
            observeBodyEnd(&s, block)
        }
    }

    // MARK: Dispatch

    /// The rule at-rule `id` makes from the prelude and, for an at-rule with a block, the
    /// block, which consumeAtRule has checked `allowedRules` allows; its type, or nil. `id` CSSParserSwiftKeyframeStyleRule
    /// is a qualified rule in @keyframes. (The rule parser's makeAtRule calls this.)
    mutating func consumeAtRuleBody(
        _ s: inout WebCore.CSSParserSwiftState,
        _ id: UInt8,
        _ allowedRules: UInt8,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan?
    ) -> UInt8? {
        if id == WebCore.CSSParserSwiftKeyframeStyleRule {
            guard let block else {
                return nil
            }
            return consumeKeyframeStyleRule(&s, prelude, block)
        }
        guard let block else {
            if allowedRules == CSSParserAllowedRules.charsetRules && id == CSSParserAtRuleID.charset {
                return consumeCharsetRule(&s, prelude)
            }
            if allowedRules <= CSSParserAllowedRules.importRules && id == CSSParserAtRuleID.importRule {
                return consumeImportRule(&s, prelude)
            }
            if allowedRules <= CSSParserAllowedRules.namespaceRules && id == CSSParserAtRuleID.namespaceRule {
                return consumeNamespaceRule(&s, prelude)
            }
            if allowedRules <= CSSParserAllowedRules.regularRules && id == CSSParserAtRuleID.layer {
                return consumeLayerRule(&s, prelude, nil)
            }
            return nil // Parse error, unrecognised at-rule without block
        }
        switch id {
        case CSSParserAtRuleID.media:
            return consumeMediaRule(&s, prelude, block)
        case CSSParserAtRuleID.supports:
            return consumeSupportsRule(&s, prelude, block)
        case CSSParserAtRuleID.fontFace:
            return consumeFontFaceRule(&s, prelude, block)
        case CSSParserAtRuleID.fontFeatureValues:
            return consumeFontFeatureValuesRule(&s, prelude, block)
        case CSSParserAtRuleID.styleset, CSSParserAtRuleID.stylistic,
            CSSParserAtRuleID.characterVariant, CSSParserAtRuleID.swash,
            CSSParserAtRuleID.ornaments, CSSParserAtRuleID.annotation:
            return allowedRules == CSSParserAllowedRules.fontFeatureValuesRules
                ? consumeFontFeatureValuesRuleBlock(&s, id, prelude, block) : nil
        case CSSParserAtRuleID.fontPaletteValues:
            return consumeFontPaletteValuesRule(&s, prelude, block)
        case CSSParserAtRuleID.webkitKeyframes, CSSParserAtRuleID.keyframes:
            return consumeKeyframesRule(&s, prelude, block)
        case CSSParserAtRuleID.page:
            return consumePageRule(&s, prelude, block)
        case CSSParserAtRuleID.counterStyle:
            return consumeCounterStyleRule(&s, prelude, block)
        case CSSParserAtRuleID.layer:
            return consumeLayerRule(&s, prelude, block)
        case CSSParserAtRuleID.container:
            return consumeContainerRule(&s, prelude, block)
        case CSSParserAtRuleID.propertyRule:
            return consumePropertyRule(&s, prelude, block)
        case CSSParserAtRuleID.scope:
            return consumeScopeRule(&s, prelude, block)
        case CSSParserAtRuleID.startingStyle:
            return consumeStartingStyleRule(&s, prelude, block)
        case CSSParserAtRuleID.viewTransition:
            return consumeViewTransitionRule(&s, prelude, block)
        case CSSParserAtRuleID.positionTry:
            return consumePositionTryRule(&s, prelude, block)
        case CSSParserAtRuleID.functionRule:
            return consumeFunctionRule(&s, prelude, block)
        case CSSParserAtRuleID.environmentMap:
            // The at-rule exists only where ENABLE(SPATIAL_PORTAL), where cssAtRuleID knows its name.
            return consumeEnvironmentMapRule(&s, prelude, block)
        default:
            return nil // Parse error, unrecognised at-rule with block
        }
    }

    // MARK: Statements

    /// `consumeCharsetRule`.
    mutating func consumeCharsetRule(_ s: inout WebCore.CSSParserSwiftState, _ prelude: CSSParserTokenSpan) -> UInt8? {
        var prelude = prelude
        let type = prelude.peekType(s)
        prelude.consumeIncludingWhitespace(s)
        guard type == CSSParserTokenKind.stringToken && prelude.atEnd else {
            return nil // Parse error, expected a single string
        }
        return make(&s, .Charset)
    }

    /// `consumeImportRule`.
    mutating func consumeImportRule(_ s: inout WebCore.CSSParserSwiftState, _ prelude: CSSParserTokenSpan) -> UInt8? {
        var prelude = prelude
        // [ <url> | <string> ]: a string token, or the tokens `consumeURLRaw` takes for a <url> with its request
        // modifiers, a url token or a url() function. makeAtRule() parses them from `uri` and checks them.
        let uri = prelude.index
        let uriType = prelude.peekType(s)
        if uriType == CSSParserTokenKind.stringToken || uriType == CSSParserTokenKind.url {
            prelude.consumeIncludingWhitespace(s)
        } else if uriType == CSSParserTokenKind.function && s.identifier(uri) == WebCore.CSSValueID.Url.rawValue {
            _ = cssParserConsumeFunction(s, &prelude)
        } else {
            return nil // Parse error, expected string or URI
        }
        guard make(&s, .Import, flags: UInt32(WebCore.CSSParserSwiftAtRuleCheck), token: cssParserAtRuleToken(uri), prelude) != nil else {
            return nil // Parse error, expected string or URI
        }

        observeRuleWithoutBody(&s, .Import, prelude.index, prelude.end)

        prelude.consumeWhitespace(s)
        var flags: UInt32 = 0

        // layer, or layer(<layer-name>); a layer() that does not parse is left for the media queries.
        var layer = cssParserNoRange
        if prelude.peekType(s) == CSSParserTokenKind.function && cssParserRuleTokenValueEquals(s, prelude.index, "layer") {
            let savedPreludeForFailure = prelude
            var contents = cssParserConsumeFunction(s, &prelude)
            if let name = cssParserConsumeCascadeLayerName(s, &contents, allowAnonymous: false), contents.atEnd {
                layer = name
                flags |= UInt32(WebCore.CSSParserSwiftAtRuleFirst)
            } else {
                prelude = savedPreludeForFailure
            }
        } else if prelude.peekType(s) == CSSParserTokenKind.ident && cssParserRuleTokenValueEquals(s, prelude.index, "layer") {
            prelude.consumeIncludingWhitespace(s)
            flags |= UInt32(WebCore.CSSParserSwiftAtRuleFirst) // The anonymous layer: an empty name.
        }

        // supports(<supports-condition>)
        var supports = cssParserNoRange
        if prelude.peekType(s) == CSSParserTokenKind.function && cssParserRuleTokenValueEquals(s, prelude.index, "supports") {
            let arguments = cssParserConsumeFunction(s, &prelude)
            let supported = cssParserSupportsCondition(&s, arguments, allowBareDeclarationAndGeneralEnclosed: true)
            if supported == CSSParserSupportsResult.invalid {
                return nil // Discard import rule with incorrect syntax.
            }
            supports = arguments
            flags |= UInt32(WebCore.CSSParserSwiftAtRuleSecond)
            if supported == CSSParserSupportsResult.supported {
                flags |= UInt32(WebCore.CSSParserSwiftAtRuleYes)
            }
        }

        return make(&s, .Import, flags: flags, token: cssParserAtRuleToken(uri), prelude, layer, supports)
    }

    /// `consumeNamespaceRule`.
    mutating func consumeNamespaceRule(_ s: inout WebCore.CSSParserSwiftState, _ prelude: CSSParserTokenSpan) -> UInt8? {
        var prelude = prelude
        var namespacePrefix = cssParserNoRange
        if prelude.peekType(s) == CSSParserTokenKind.ident {
            namespacePrefix = CSSParserTokenSpan(index: prelude.index, end: prelude.index &+ 1) // Below end.
            prelude.consumeIncludingWhitespace(s)
        }
        guard let uri = cssParserConsumeStringOrURI(&s, &prelude), prelude.atEnd else {
            return nil // Parse error, expected string or URI
        }
        // makeAtRule() makes nothing where the URI's atom is null.
        return make(&s, .Namespace, token: uri, namespacePrefix)
    }

    /// `consumeLayerRule`: the statement where `block` is nil, else the block.
    mutating func consumeLayerRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan?
    ) -> UInt8? {
        let preludeCopy = prelude
        var prelude = prelude

        guard let block else {
            // List syntax.
            while true {
                guard cssParserConsumeCascadeLayerName(s, &prelude, allowAnonymous: false) != nil else {
                    return nil
                }
                if prelude.atEnd {
                    break
                }
                let commaType = prelude.peekType(s)
                prelude.consumeIncludingWhitespace(s)
                guard commaType == CSSParserTokenKind.comma else {
                    return nil
                }
            }
            observeRuleWithoutBody(&s, .LayerStatement, preludeCopy.index, preludeCopy.end)
            // makeAtRule() reads the names off the prelude: idents, `.` and commas between whitespace.
            return make(&s, .LayerStatement, preludeCopy)
        }

        guard let name = cssParserConsumeCascadeLayerName(s, &prelude, allowAnonymous: true) else {
            return nil
        }
        // No comma separated list when using the block syntax.
        guard prelude.atEnd else {
            return nil
        }
        consumeGroupRuleBody(&s, .LayerBlock, preludeCopy.index, preludeCopy.end, block)
        return make(&s, .LayerBlock, name)
    }

    // MARK: Group rules

    /// `consumeMediaRule`.
    mutating func consumeMediaRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        consumeGroupRuleBody(&s, .Media, prelude.index, prelude.end, block)
        return make(&s, .Media, prelude)
    }

    /// `consumeSupportsRule`.
    mutating func consumeSupportsRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        let supported = cssParserSupportsCondition(&s, prelude, allowBareDeclarationAndGeneralEnclosed: false)
        if supported == CSSParserSupportsResult.invalid {
            return nil // Parse error, invalid @supports condition
        }
        consumeGroupRuleBody(&s, .Supports, prelude.index, prelude.end, block)
        return make(
            &s,
            .Supports,
            flags: supported == CSSParserSupportsResult.supported ? UInt32(WebCore.CSSParserSwiftAtRuleYes) : 0,
            prelude
        )
    }

    /// `consumeContainerRule`: makeAtRule() checks the query before the body.
    mutating func consumeContainerRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard !prelude.atEnd, make(&s, .Container, flags: UInt32(WebCore.CSSParserSwiftAtRuleCheck), prelude) != nil else {
            return nil
        }
        consumeGroupRuleBody(&s, .Container, prelude.index, prelude.end, block)
        return make(&s, .Container, prelude)
    }

    /// `consumeStartingStyleRule`.
    mutating func consumeStartingStyleRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard prelude.atEnd else {
            return nil
        }
        consumeGroupRuleBody(&s, .StartingStyle, prelude.index, prelude.end, block)
        return make(&s, .StartingStyle)
    }

    /// consumeScopeRule's `consumeScope`: `( <selector-list> )`, parsed into `scope` but not yet built. Returns whether
    /// it parsed. `prelude` is left after the closing parenthesis and the whitespace after it; on a failure, wherever
    /// wherever the parse stopped.
    /// Never inlined: the parser's inline nodes stay out of the rule parser's recursive frames.
    @inline(never)
    private func consumeScope(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: inout CSSParserTokenSpan,
        nestedContext: UInt8,
        _ scope: inout CSSParserScopeSelectorList?
    ) -> Bool {
        // Consume the left parenthesis
        guard prelude.peekType(s) == CSSParserTokenKind.leftParenthesis else {
            return false
        }
        prelude.consumeIncludingWhitespace(s)

        // Determine the range for the selector list
        let selectorListStart = prelude.index
        while !prelude.atEnd && prelude.peekType(s) != CSSParserTokenKind.rightParenthesis {
            prelude.consumeComponentValue(s)
        }

        // Parse the selector list range, as parseCSSSelectorList: against the style sheet, without pseudo-elements.
        var cursor = CSSParserTokenCursor(selectorListStart, prelude.index)
        var parser = CSSParserSelectorParser(&s, withStyleSheet: true, disallowPseudoElements: true)
        parser.arena.reset(forTokens: cursor.end &- cursor.index) // index is at most end.
        let list = parser.parseMutableSelectorList(&s, &cursor, nestedContext: nestedContext, forgiving: false)
        guard list >= 0 else {
            return false
        }

        // Consume the right parenthesis
        guard prelude.peekType(s) == CSSParserTokenKind.rightParenthesis else {
            return false
        }
        prelude.consumeIncludingWhitespace(s)

        // Return the correctly parsed scope
        scope = CSSParserScopeSelectorList(storage: parser.arena.takeStorage(), list: list)
        return true
    }

    /// consumeScopeRule's `consumePrelude`: [ ( <scope-start> ) ]? [ to ( <scope-end> ) ]?, not empty.
    private func consumeScopePrelude(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: inout CSSParserTokenSpan,
        _ scopeStart: inout CSSParserScopeSelectorList?,
        _ scopeEnd: inout CSSParserScopeSelectorList?
    ) -> Bool {
        let nestedContext = lastAncestorRuleType(&s)
        let successScopeStart = consumeScope(&s, &prelude, nestedContext: nestedContext, &scopeStart)
        if successScopeStart && prelude.atEnd {
            return true
        }
        guard prelude.peekType(s) == CSSParserTokenKind.ident else {
            return false
        }
        let to = prelude.index
        prelude.consumeIncludingWhitespace(s)
        guard cssParserRuleTokenValueEquals(s, to, "to") else {
            return false
        }
        // scopeEnd is always considered nested, at least by the scopeStart
        guard consumeScope(&s, &prelude, nestedContext: CSSParserNestedContextType.scope &+ 1, &scopeEnd) else {
            return false
        }
        return prelude.atEnd
    }

    /// `consumeScopeRule`. The selector lists are built once the body is parsed, right before makeAtRule(), so that a
    /// rule in the body cannot take their place in the parse.
    mutating func consumeScopeRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        let preludeRangeCopy = prelude
        var prelude = prelude
        var scopeStart: CSSParserScopeSelectorList? = nil
        var scopeEnd: CSSParserScopeSelectorList? = nil
        if !prelude.atEnd && !consumeScopePrelude(&s, &prelude, &scopeStart, &scopeEnd) {
            return nil
        }

        let previous = pushAncestorRuleType(&s, CSSParserNestedContextType.scope)
        consumeGroupRuleBody(&s, .Scope, preludeRangeCopy.index, prelude.end, block)
        popAncestorRuleType(&s, CSSParserNestedContextType.scope, previous)

        var flags: UInt32 = 0
        if let start = scopeStart.take() {
            let storage = start.write(&s)
            s.setSelectorList(storage)
            make(&s, .Scope, flags: UInt32(WebCore.CSSParserSwiftAtRulePart))
            flags |= UInt32(WebCore.CSSParserSwiftAtRuleFirst)
        }
        if let end = scopeEnd.take() {
            let storage = end.write(&s)
            s.setSelectorList(storage)
            flags |= UInt32(WebCore.CSSParserSwiftAtRuleSecond)
        }
        return make(&s, .Scope, flags: flags)
    }

    // MARK: Rules with declarations

    /// A rule whose body is a declaration list of its own type, with the observer's events of an empty body: @font-face,
    /// @view-transition, @position-try, @font-palette-values, the environment map.
    private mutating func consumeDescriptorRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ type: WebCore.StyleRuleType,
        _ headerStart: Int,
        _ headerEnd: Int,
        _ block: CSSParserTokenSpan,
        token: UInt32 = cssParserNoToken
    ) -> UInt8? {
        observeRuleWithoutBody(&s, type, headerStart, headerEnd)
        consumeDeclarationListInNewContext(&s, block, type.rawValue)
        return make(&s, type, token: token)
    }

    /// `consumeDeclarationListInNewNestingContext`: the declarations into a new context, whose properties makeAtRule()
    /// takes when it closes it.
    private mutating func consumeDeclarationListInNewContext(
        _ s: inout WebCore.CSSParserSwiftState,
        _ block: CSSParserTokenSpan,
        _ ruleType: UInt8
    ) {
        s.pushNestingContext(false)
        consumeDeclarationList(&s, block, ruleType)
    }

    /// `consumeFontFaceRule`.
    mutating func consumeFontFaceRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard prelude.atEnd else {
            return nil // Parse error; @font-face prelude should be empty
        }
        return consumeDescriptorRule(&s, .FontFace, prelude.index, prelude.end, block)
    }

    /// `consumeViewTransitionRule`.
    mutating func consumeViewTransitionRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard prelude.atEnd else {
            return nil // Parse error; @view-transition prelude should be empty
        }
        return consumeDescriptorRule(&s, .ViewTransition, prelude.index, prelude.end, block)
    }

    /// `consumeEnvironmentMapRule`, which only ENABLE(SPATIAL_PORTAL) has; elsewhere ruleParserState() never sets the
    /// setting's bit.
    mutating func consumeEnvironmentMapRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard state & WebCore.CSSParserSwiftRuleParserSpatialPortal != 0, prelude.atEnd else {
            return nil
        }
        return consumeDescriptorRule(&s, .EnvironmentMap, prelude.index, prelude.end, block)
    }

    /// `consumePositionTryRule`: the prelude is only a <dashed-ident>.
    mutating func consumePositionTryRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        var prelude = prelude
        guard let name = cssParserConsumeDashedIdent(s, &prelude), prelude.atEnd else {
            return nil
        }
        // The header starts after the name: the prelude left after consuming it.
        return consumeDescriptorRule(&s, .PositionTry, prelude.index, prelude.end, block, token: cssParserAtRuleToken(name))
    }

    /// `consumeFontPaletteValuesRule`. makeAtRule() reads the descriptors off the properties.
    mutating func consumeFontPaletteValuesRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        var prelude = prelude
        guard let name = cssParserConsumeDashedIdent(s, &prelude), prelude.atEnd else {
            return nil // Parse error; expected custom ident in @font-palette-values header
        }
        return consumeDescriptorRule(&s, .FontPaletteValues, prelude.index, prelude.end, block, token: cssParserAtRuleToken(name))
    }

    /// `consumeCounterStyleRule`: makeAtRule() checks the name before the body, and makes
    /// nothing where the descriptors are not valid.
    mutating func consumeCounterStyleRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard make(&s, .CounterStyle, flags: UInt32(WebCore.CSSParserSwiftAtRuleCheck), prelude) != nil else {
            return nil
        }
        var rangeCopy = prelude // For inspector callbacks: after the name and the whitespace after it.
        rangeCopy.consumeIncludingWhitespace(s)
        if observing {
            observeHeader(&s, .CounterStyle, rangeCopy.index, prelude.end)
            observeBodyStart(&s, block)
            observeBodyEnd(&s, block)
        }
        consumeDeclarationListInNewContext(&s, block, WebCore.StyleRuleType.CounterStyle.rawValue)
        return make(&s, .CounterStyle, prelude)
    }

    /// `consumePropertyRule`. makeAtRule() reads the descriptors off the properties and checks them.
    mutating func consumePropertyRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        var prelude = prelude
        let nameToken = prelude.index
        let nameType = prelude.peekType(s)
        prelude.consumeIncludingWhitespace(s)
        guard nameType == CSSParserTokenKind.ident && prelude.atEnd && cssParserIsCustomPropertyName(s, nameToken) else {
            return nil
        }
        consumeDeclarationListInNewContext(&s, block, WebCore.StyleRuleType.Property.rawValue)
        return make(&s, .Property, token: cssParserAtRuleToken(nameToken))
    }

    /// `parsePageSelector`: a type selector, a page pseudo-class, both or neither; nil where the prelude is not one.
    private func parsePageSelector(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan
    ) -> (typeToken: Int?, pseudo: UInt8?)? {
        // We only support a small subset of the css-page spec.
        var range = prelude
        range.consumeWhitespace(s)
        var typeToken: Int? = nil
        if range.peekType(s) == CSSParserTokenKind.ident {
            typeToken = range.index
            range.consume()
        }
        var pseudo: UInt8? = nil
        if range.peekType(s) == CSSParserTokenKind.colon {
            range.consume()
            guard range.peekType(s) == CSSParserTokenKind.ident, let pagePseudoClass = cssParserPagePseudoClass(&s, range.index) else {
                return nil
            }
            pseudo = pagePseudoClass
            range.consume()
        }
        range.consumeWhitespace(s)
        guard range.atEnd else {
            return nil // Parse error; extra tokens in @page selector
        }
        return (typeToken, pseudo)
    }

    /// Writes @page's selector list into the parse, as parsePageSelector made it: the type selector (with the style
    /// sheet's default namespace) before the pseudo-class it is appended to, the head marked for the page.
    private func buildPageSelector(_ s: inout WebCore.CSSParserSwiftState, typeToken: Int?, pseudo: UInt8?) {
        let storage = WebCore.CSSSelectorListStorage.createWithCapacity(typeToken != nil && pseudo != nil ? 2 : 1).get()
        var head = WebCore.CSSSelectorFields()
        head.flags = CSSParserSelectorFlag.forPage
        if let typeToken {
            head.match = CSSParserSelectorMatch.Tag.rawValue
            if pseudo != nil {
                head.relation = CSSParserSelectorRelation.Subselector.rawValue // as CSSParserSelectorArena.appendTagInComplexSelector
            }
            let name = s.selectorQualifiedName(cssParserAtRuleToken(typeToken), .Value, .Default, UInt32.max, false, true, false)
            storage.appendSelector(head, WTF.AtomString(), name, WTF.AtomString(), 0, 0, nil, 0)
            if let pseudo {
                var pseudoClass = WebCore.CSSSelectorFields()
                pseudoClass.match = CSSParserSelectorMatch.PagePseudoClass.rawValue
                pseudoClass.pseudoType = pseudo
                pseudoClass.flags = CSSParserSelectorFlag.continuesComplexSelector
                storage.appendSimpleSelector(pseudoClass, WTF.AtomString())
            }
        } else {
            if let pseudo {
                head.match = CSSParserSelectorMatch.PagePseudoClass.rawValue
                head.pseudoType = pseudo
            } else {
                head.match = CSSParserSelectorMatch.Unknown.rawValue // MutableCSSSelector()'s
            }
            storage.appendSimpleSelector(head, WTF.AtomString())
        }
        s.setSelectorList(storage)
    }

    /// `consumePageRule`. The selector list is built once the body is parsed, right before makeAtRule().
    mutating func consumePageRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard let selector = parsePageSelector(&s, prelude) else {
            return nil // Parse error, invalid @page selector
        }
        if observing {
            observeHeader(&s, .Page, prelude.index, prelude.end)
        }
        consumeDeclarationListInNewContext(&s, block, WebCore.StyleRuleType.Page.rawValue)
        buildPageSelector(&s, typeToken: selector.typeToken, pseudo: selector.pseudo)
        return make(&s, .Page)
    }

    // MARK: Rule lists

    /// `consumeKeyframesRule`.
    mutating func consumeKeyframesRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        let rangeCopy = prelude // For inspector callbacks
        var prelude = prelude
        let nameToken = prelude.index
        let nameType = prelude.peekType(s)
        prelude.consumeIncludingWhitespace(s)
        guard prelude.atEnd else {
            return nil // Parse error; expected single non-whitespace token in @keyframes header
        }
        if nameType == CSSParserTokenKind.ident {
            // According to the CSS Values specification, identifier-based keyframe names are not allowed to be CSS
            // wide keywords or "default". And CSS Animations additionally excludes the "none" keyword.
            let id = cssParserIdentifier(s, nameToken)
            guard WebCore.isValidCustomIdentifier(id) && id != .None else {
                return nil
            }
        } else if nameType != CSSParserTokenKind.stringToken {
            return nil // Parse error; expected ident token or string in @keyframes header
        }
        guard s.tokenValueLength(nameToken) != 0 else {
            return nil // Parse error: empty string consider invalid.
        }

        if observing {
            observeHeader(&s, .Keyframes, rangeCopy.index, prelude.end)
            observeBodyStart(&s, block)
        }
        s.pushNestingContext(false)
        _ = consumeRuleList(&s, block, .keyframes, .Context)
        if observing {
            observeBodyEnd(&s, block)
        }
        return make(&s, .Keyframes, token: cssParserAtRuleToken(nameToken))
    }

    /// `consumeKeyframeStyleRule`: the key list is checked, and kept for makeAtRule(), before the body.
    mutating func consumeKeyframeStyleRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard make(&s, .Keyframe, flags: UInt32(WebCore.CSSParserSwiftAtRuleCheck), prelude) != nil else {
            return nil
        }
        if observing {
            observeHeader(&s, .Keyframe, prelude.index, prelude.end)
        }
        consumeDeclarationListInNewContext(&s, block, WebCore.StyleRuleType.Keyframe.rawValue)
        return make(&s, .Keyframe)
    }

    /// `consumeFontFeatureValuesRule`: @font-feature-values <family-name># { <declaration-list> }. The family list is
    /// checked before the body.
    mutating func consumeFontFeatureValuesRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard make(&s, .FontFeatureValues, flags: UInt32(WebCore.CSSParserSwiftAtRuleCheck), prelude) != nil else {
            return nil
        }
        if observing {
            observeHeader(&s, .FontFeatureValues, prelude.index, prelude.end)
            observeBodyStart(&s, block)
        }
        // Every rule of the list, the blocks and whatever else parses there, goes into the context; makeAtRule() keeps
        // the blocks.
        s.pushNestingContext(false)
        _ = consumeRuleList(&s, block, .fontFeatureValues, .Context)
        if observing {
            observeBodyEnd(&s, block)
        }
        return make(&s, .FontFeatureValues, prelude)
    }

    /// `consumeFontFeatureValuesRuleBlock`: <font-feature-value-type> { <declaration-list> }, whose declarations are
    /// tags of non-negative integers. makeAtRule() reads the integers of each tag, which the block's rule then takes.
    mutating func consumeFontFeatureValuesRuleBlock(
        _ s: inout WebCore.CSSParserSwiftState,
        _ id: UInt8,
        _ prelude: CSSParserTokenSpan,
        _ range: CSSParserTokenSpan
    ) -> UInt8? {
        // Prelude should be empty; block should be present.
        guard prelude.atEnd && !range.atEnd else {
            return nil
        }
        if observing {
            observeHeader(&s, .FontFeatureValuesBlock, prelude.index, prelude.end)
            observeBodyStart(&s, range)
            observeBodyEnd(&s, range)
        }

        // The at-rule's CSSAtRuleID, which gives makeAtRule() the block's type and its tags' maximum number of values.
        let atRule = UInt32(id) &<< 8
        var range = range
        while !range.atEnd {
            let type = range.peekType(s)
            if CSSParserTokenKind.isWhitespace(type) || type == CSSParserTokenKind.semicolon {
                range.consume()
                continue
            }
            let declarationStart = range.index
            while !range.atEnd && range.peekType(s) != CSSParserTokenKind.semicolon {
                range.consumeComponentValue(s)
            }
            guard type == CSSParserTokenKind.ident else {
                continue // Parse error, unexpected token in declaration list
            }
            // consumeTag: <ident> : <integer [0,∞]>+
            var tag = CSSParserTokenSpan(index: declarationStart, end: range.index)
            let name = tag.index
            tag.consumeIncludingWhitespace(s)
            let colon = tag.peekType(s)
            tag.consume()
            guard colon == CSSParserTokenKind.colon else {
                continue
            }
            tag.consumeWhitespace(s)
            // Kept for the block unless its values do not parse.
            make(
                &s,
                .FontFeatureValuesBlock,
                flags: UInt32(WebCore.CSSParserSwiftAtRulePart) | atRule,
                token: cssParserAtRuleToken(name),
                tag
            )
        }
        return make(&s, .FontFeatureValuesBlock, flags: atRule)
    }

    // MARK: @function

    /// consumeFunctionRule's `consumeParameter`: <function-parameter> = <custom-property-name> <css-type>? [ :
    /// <default-value> ]?. A default value that may not hold substitution functions is checked against the type by
    /// makeAtRule(), here.
    private func consumeFunctionParameter(
        _ s: inout WebCore.CSSParserSwiftState,
        _ range: inout CSSParserTokenSpan
    ) -> CSSParserFunctionParameter? {
        let nameToken = range.index
        let nameType = range.peekType(s)
        range.consumeIncludingWhitespace(s)
        // <custom-property-name>
        guard nameType == CSSParserTokenKind.ident && cssParserIsCustomPropertyName(s, nameToken) else {
            return nil
        }
        var parameter = CSSParserFunctionParameter(name: nameToken, type: nil, defaultValue: nil)

        if range.atEnd || range.peekType(s) == CSSParserTokenKind.comma {
            return parameter
        }

        // <css-type>?
        if range.peekType(s) != CSSParserTokenKind.colon {
            guard let type = CSSParserSyntax.consumeType(&s, &range) else {
                return nil
            }
            parameter.type = type
        }

        // [ : <default-value> ]?
        if range.peekType(s) == CSSParserTokenKind.colon {
            range.consumeIncludingWhitespace(s)
            // <default-value> = <declaration-value>
            // A comma only separates parameters at the top level, so blocks are consumed whole.
            let defaultStart = range.index
            while !range.atEnd && range.peekType(s) != CSSParserTokenKind.comma {
                if range.peekType(s) == CSSParserTokenKind.delimiter && s.delimiter(range.index) == 0x21 { // '!'
                    return nil
                }
                range.consumeComponentValue(s)
            }
            let defaultValue = CSSParserTokenSpan(index: defaultStart, end: range.index)

            // "If a default value and a parameter type are both provided, then the default value must parse
            // successfully according to that parameter type's syntax. Otherwise, the @function rule is invalid." A
            // default containing arbitrary substitution functions (var(), a dashed-function) is assumed valid at parse
            // time and validated after substitution.
            if !CSSParserSubstitution.containsSubstitutionFunctions(s, defaultValue.index..<defaultValue.end, substitutionFlags) {
                setSyntax(&s, parameter.type)
                guard make(&s, .Function, flags: UInt32(WebCore.CSSParserSwiftAtRuleCheck), defaultValue) != nil else {
                    return nil
                }
            }
            parameter.defaultValue = defaultValue
        }

        if range.atEnd || range.peekType(s) == CSSParserTokenKind.comma {
            return parameter
        }
        return nil
    }

    /// Gives the state the syntax `type`, which the next makeAtRule call takes; none for the universal syntax.
    private func setSyntax(_ s: inout WebCore.CSSParserSwiftState, _ type: CSSParserSyntax.Parsed?) {
        if let type {
            s.setSyntax(WebCore.CSSCustomPropertySyntax(definition: type.definition))
        }
    }

    /// `consumeFunctionRule`: <@function> = @function <function-token> <function-parameter>#? ) [ returns <css-type>
    /// ]?. Its parameters are given to makeAtRule() once the body is parsed, right before the rule, so that an @function
    /// in the body cannot take them.
    /// https://drafts.csswg.org/css-mixins/#function-rule
    mutating func consumeFunctionRule(
        _ s: inout WebCore.CSSParserSwiftState,
        _ prelude: CSSParserTokenSpan,
        _ block: CSSParserTokenSpan
    ) -> UInt8? {
        guard substitutionFlags & UInt32(WebCore.CSSParserSwiftFunctionAtRuleEnabled) != 0 else {
            return nil
        }
        var prelude = prelude
        guard prelude.peekType(s) == CSSParserTokenKind.function else {
            return nil
        }
        let name = prelude.index
        var parametersRange = cssParserConsumeFunction(s, &prelude)

        // <function-parameter>#?
        var parameters: [CSSParserFunctionParameter] = []
        while !parametersRange.atEnd {
            guard let parameter = consumeFunctionParameter(&s, &parametersRange) else {
                return nil
            }
            parameters.append(parameter)
            if parametersRange.peekType(s) == CSSParserTokenKind.comma {
                parametersRange.consumeIncludingWhitespace(s)
            }
        }

        // [ returns <css-type> ]?
        var returnType: CSSParserSyntax.Parsed? = nil
        if prelude.peekType(s) == CSSParserTokenKind.ident && cssParserRuleTokenValueEquals(s, prelude.index, "returns") {
            prelude.consumeIncludingWhitespace(s)
            guard let type = CSSParserSyntax.consumeType(&s, &prelude) else {
                return nil
            }
            returnType = type
        }

        guard prelude.atEnd else {
            return nil
        }

        let previous = pushAncestorRuleType(&s, CSSParserNestedContextType.function)
        s.pushNestingContext(false)
        consumeDeclarationRuleList(&s, block, WebCore.StyleRuleType.Function.rawValue)
        popAncestorRuleType(&s, CSSParserNestedContextType.function, previous)

        for parameter in parameters {
            setSyntax(&s, parameter.type)
            make(
                &s,
                .Function,
                flags: UInt32(WebCore.CSSParserSwiftAtRulePart)
                    | (parameter.defaultValue != nil ? UInt32(WebCore.CSSParserSwiftAtRuleFirst) : 0),
                token: cssParserAtRuleToken(parameter.name),
                parameter.defaultValue ?? cssParserNoRange
            )
        }
        setSyntax(&s, returnType)
        return make(&s, .Function, token: cssParserAtRuleToken(name))
    }
}

/// A selector list of @scope's prelude, parsed and not yet built into the parse.
/// Its arena's storage holds it whole, off the stack, while @scope's body is parsed.
private struct CSSParserScopeSelectorList: ~Copyable {
    var storage: CSSParserSelectorArenaStorage
    let list: Int32

    /// The list's storage. Never inlined: the arena's inline nodes stay out of the rule parser's recursive frames.
    @inline(never)
    consuming func write(_ s: inout WebCore.CSSParserSwiftState) -> WebCore.CSSSelectorListStorage {
        let list = list
        var arena = CSSParserSelectorArena(adopting: storage)
        return arena.write(&s, list)
    }
}
