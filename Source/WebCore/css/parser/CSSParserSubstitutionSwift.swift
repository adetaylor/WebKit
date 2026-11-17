// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2021 Apple Inc. All rights reserved.
// Copyright 2014 The Chromium Authors. All rights reserved.
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

// CSSSubstitutionParser's validation of var(), env(), attr() and the other substitution functions, on the tokens of
// either facade the parser's Swift reads tokens from.

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

// MARK: - Tokens

/// The tokens of a parse, read by index, as both facades derived from `CSSParserSwiftTokenReader` read them: the
/// parser's `WebCore.CSSParserSwiftState` and the property consumers' `WebCore.CSSPropertyConsumerSwiftValue`. Past the
/// last token, a read is that of an EOF token. The requirements are named apart from the readers they forward to.
protocol CSSParserTokenSource: ~Copyable {
    func tokenType(_ index: Int) -> UInt8
    func tokenBlockType(_ index: Int) -> UInt8
    /// The CSSValueID of an ident token (`id()`) or a function token (`functionId()`), else Invalid.
    func tokenIdentifier(_ index: Int) -> UInt16
    func tokenDelimiter(_ index: Int) -> UInt16
    /// The length of `CSSParserToken::value()`, and its code unit at `offset`, 0 past its end.
    func tokenValueLength(_ index: Int) -> UInt32
    func tokenValueCharacter(_ index: Int, _ offset: UInt32) -> UInt16
    /// Whether a token is a number token with an integer value, and the value of a number token.
    func tokenIsIntegerNumber(_ index: Int) -> Bool
    func tokenNumericValue(_ index: Int) -> Double
}

extension WebCore.CSSParserSwiftState: CSSParserTokenSource {
    func tokenType(_ index: Int) -> UInt8 { self.type(index) }
    func tokenBlockType(_ index: Int) -> UInt8 { self.blockType(index) }
    func tokenIdentifier(_ index: Int) -> UInt16 { self.identifier(index) }
    func tokenDelimiter(_ index: Int) -> UInt16 { self.delimiter(index) }
    func tokenValueLength(_ index: Int) -> UInt32 { self.valueLength(index) }
    func tokenValueCharacter(_ index: Int, _ offset: UInt32) -> UInt16 { self.valueCharacter(index, offset) }
    func tokenIsIntegerNumber(_ index: Int) -> Bool { self.isIntegerNumber(index) }
    func tokenNumericValue(_ index: Int) -> Double { self.numericValue(index) }
}

extension WebCore.CSSPropertyConsumerSwiftValue: CSSParserTokenSource {
    func tokenType(_ index: Int) -> UInt8 { self.type(index) }
    func tokenBlockType(_ index: Int) -> UInt8 { self.blockType(index) }
    func tokenIdentifier(_ index: Int) -> UInt16 { self.identifier(index) }
    func tokenDelimiter(_ index: Int) -> UInt16 { self.delimiter(index) }
    func tokenValueLength(_ index: Int) -> UInt32 { self.valueLength(index) }
    func tokenValueCharacter(_ index: Int, _ offset: UInt32) -> UInt16 { self.valueCharacter(index, offset) }
    func tokenIsIntegerNumber(_ index: Int) -> Bool { self.isIntegerNumber(index) }
    func tokenNumericValue(_ index: Int) -> Double { self.numericValue(index) }
}

/// The CSSParserTokenType and block type values the parser compares tokens with.
enum CSSParserTokenKind {
    static var ident: UInt8 { UInt8(WebCore.IdentToken.rawValue) }
    static var function: UInt8 { UInt8(WebCore.FunctionToken.rawValue) }
    static var atKeyword: UInt8 { UInt8(WebCore.AtKeywordToken.rawValue) }
    static var number: UInt8 { UInt8(WebCore.NumberToken.rawValue) }
    static var delimiter: UInt8 { UInt8(WebCore.DelimiterToken.rawValue) }
    static var comma: UInt8 { UInt8(WebCore.CommaToken.rawValue) }
    static var colon: UInt8 { UInt8(WebCore.ColonToken.rawValue) }
    static var semicolon: UInt8 { UInt8(WebCore.SemicolonToken.rawValue) }
    static var leftBrace: UInt8 { UInt8(WebCore.LeftBraceToken.rawValue) }
    static var rightParenthesis: UInt8 { UInt8(WebCore.RightParenthesisToken.rawValue) }
    static var rightBrace: UInt8 { UInt8(WebCore.RightBraceToken.rawValue) }
    static var rightBracket: UInt8 { UInt8(WebCore.RightBracketToken.rawValue) }
    static var badString: UInt8 { UInt8(WebCore.BadStringToken.rawValue) }
    static var badUrl: UInt8 { UInt8(WebCore.BadUrlToken.rawValue) }
    static var eof: UInt8 { UInt8(WebCore.EOFToken.rawValue) }
    static var blockStart: UInt8 { UInt8(WebCore.CSSParserToken.BlockStart.rawValue) }
    static var blockEnd: UInt8 { UInt8(WebCore.CSSParserToken.BlockEnd.rawValue) }

    /// `CSSTokenizer::isWhitespace`.
    static func isWhitespace(_ type: UInt8) -> Bool {
        type == UInt8(WebCore.NonNewlineWhitespaceToken.rawValue) || type == UInt8(WebCore.NewlineToken.rawValue)
    }
}

/// A `CSSParserTokenRange`: the tokens [index, end) of a token source, which every member takes.
struct CSSParserTokenSpan {
    var index: Int
    var end: Int

    var atEnd: Bool { index >= end }

    /// `peek().type()`: EOF at the end.
    func peekType<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens) -> UInt8 {
        atEnd ? CSSParserTokenKind.eof : tokens.tokenType(index)
    }

    /// `consume()`, without the token.
    mutating func consume() {
        if !atEnd {
            index &+= 1 // Below end.
        }
    }

    mutating func consumeWhitespace<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens) {
        while !atEnd && CSSParserTokenKind.isWhitespace(tokens.tokenType(index)) {
            index &+= 1 // Below end.
        }
    }

    mutating func consumeIncludingWhitespace<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens) {
        consume()
        consumeWhitespace(tokens)
    }

    /// `CSSPropertyParserHelpers::consumeCommaIncludingWhitespace`.
    mutating func consumeComma<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens) -> Bool {
        guard peekType(tokens) == CSSParserTokenKind.comma else {
            return false
        }
        consumeIncludingWhitespace(tokens)
        return true
    }

    /// `consumeBlock()` at a token that starts a block: the tokens inside it. A block left open runs to the end.
    mutating func consumeBlock<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens) -> CSSParserTokenSpan {
        let start = index &+ 1 // At most end: the block's first token is below it.
        var nestingLevel = 0
        repeat {
            let blockType = tokens.tokenBlockType(index)
            index &+= 1 // At most end.
            if blockType == CSSParserTokenKind.blockStart {
                nestingLevel &+= 1 // Between 0 and the tokens read.
            } else if blockType == CSSParserTokenKind.blockEnd {
                nestingLevel &-= 1 // Between 0 and the tokens read.
            }
        } while nestingLevel != 0 && index < end
        // index is at least start, and with the block closed, above it.
        return CSSParserTokenSpan(index: start, end: nestingLevel != 0 ? index : index &- 1)
    }

    /// `consumeComponentValue()`: a token, or a block whole. An unmatched block end drops the nesting below zero, and
    /// tokens are consumed until it returns to zero or the end, as CSSParserTokenRange's unsigned nesting level does.
    mutating func consumeComponentValue<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens) {
        var nestingLevel = 0
        repeat {
            guard !atEnd else {
                return
            }
            let blockType = tokens.tokenBlockType(index)
            index &+= 1 // At most end.
            if blockType == CSSParserTokenKind.blockStart {
                nestingLevel &+= 1 // Its magnitude is at most the tokens read.
            } else if blockType == CSSParserTokenKind.blockEnd {
                nestingLevel &-= 1 // Its magnitude is at most the tokens read.
            }
        } while nestingLevel != 0 && !atEnd
    }

    /// Consumes component values up to a token of type `type` or the end, and returns the tokens consumed.
    mutating func consumeUntil<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens, _ type: UInt8) -> CSSParserTokenSpan {
        let start = index
        while !atEnd && tokens.tokenType(index) != type {
            consumeComponentValue(tokens)
        }
        return CSSParserTokenSpan(index: start, end: index)
    }
}

/// Whether the value of token `index` is a custom property name (`isCustomPropertyName`): two dashes and more.
func cssParserIsCustomPropertyName<Tokens: CSSParserTokenSource & ~Copyable>(_ tokens: borrowing Tokens, _ index: Int) -> Bool {
    tokens.tokenValueLength(index) > 2 && tokens.tokenValueCharacter(index, 0) == 0x2D && tokens.tokenValueCharacter(index, 1) == 0x2D
}

// MARK: - Substitution functions

/// CSSSubstitutionParser's validation. `flags` are the CSSParserSwift*Enabled bits of cssParserSubstitutionFlags.
enum CSSParserSubstitution {
    struct BlockClass {
        var hasSubstitutionFunctions = false
        var hasTopLevelBraceBlockMixedWithOtherValues = false
        var hasEmptyTopLevelBraceBlock = false
    }

    /// What `classifyVariableRange` finds: a CSS-wide keyword's CSSValueID, or the class of the tokens.
    struct VariableType {
        var cssWideKeyword: UInt16?
        var blockClass = BlockClass()
    }

    private struct BlockState {
        var range: CSSParserTokenSpan
        var isTopLevelBlock = true
        var isInsideTopLevelBraceBlock = false
        var hasOtherValues = false
        var topLevelBraceBlocks = 0
        var doneWithThisRange = false
    }

    private static func hasFlag(_ flags: UInt32, _ flag: UInt32) -> Bool {
        flags & flag != 0
    }

    /// `classifyBlock`: nil if the tokens are not a valid <declaration-value> or a substitution function in them is not
    /// valid. Blocks nest on a stack of its own, not in calls.
    static func classifyBlock<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ range: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> BlockClass? {
        var stack = UniqueArray<BlockState>()
        stack.append(BlockState(range: range))
        var result = BlockClass()

        while stack.count != 0 {
            let top = stack.count &- 1 // Above 0.
            var current = stack[top]
            if current.doneWithThisRange {
                // If there is a top level brace block, the value should contain only that.
                if current.topLevelBraceBlocks > 1 || (current.topLevelBraceBlocks == 1 && current.hasOtherValues) {
                    result.hasTopLevelBraceBlockMixedWithOtherValues = true
                }
                _ = stack.removeLast()
                continue
            }

            if current.range.atEnd {
                stack[top].doneWithThisRange = true
                continue
            }

            let tokenIndex = current.range.index
            let tokenType = tokens.tokenType(tokenIndex)
            if current.isTopLevelBlock && !CSSParserTokenKind.isWhitespace(tokenType) {
                if tokenType == CSSParserTokenKind.leftBrace {
                    current.topLevelBraceBlocks &+= 1 // At most the token count.
                } else {
                    current.hasOtherValues = true
                }
            }

            if tokens.tokenBlockType(tokenIndex) == CSSParserTokenKind.blockStart {
                var block = current.range.consumeBlock(tokens)
                block.consumeWhitespace(tokens)
                stack[top] = current

                if tokenType == CSSParserTokenKind.leftBrace && current.isTopLevelBlock && block.atEnd {
                    result.hasEmptyTopLevelBraceBlock = true
                }

                let function = tokens.tokenIdentifier(tokenIndex)
                var isValid: Bool?
                if function == WebCore.CSSValueID.Var.rawValue {
                    isValid = isValidVariableReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.Env.rawValue {
                    isValid = isValidEnvReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.Inherit.rawValue && hasFlag(flags, WebCore.CSSParserSwiftInheritFunctionEnabled) {
                    // <inherit-args> is the same argument grammar as var()'s.
                    isValid = isValidVariableReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.Attr.rawValue {
                    isValid = isValidAttrReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.RandomItem.rawValue
                    && hasFlag(flags, WebCore.CSSParserSwiftRandomItemFunctionEnabled)
                {
                    isValid = isValidRandomItemReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.If.rawValue && hasFlag(flags, WebCore.CSSParserSwiftIfFunctionEnabled) {
                    isValid = isValidIfReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.Ident.rawValue && hasFlag(flags, WebCore.CSSParserSwiftIdentFunctionEnabled) {
                    isValid = isValidIdentReference(tokens, block, flags)
                } else if function == WebCore.CSSValueID.InternalAutoBase.rawValue
                    && hasFlag(flags, WebCore.CSSParserSwiftInternalAutoBaseParsingEnabled)
                {
                    isValid = true
                } else if tokenType == CSSParserTokenKind.function && hasFlag(flags, WebCore.CSSParserSwiftFunctionAtRuleEnabled)
                    && cssParserIsCustomPropertyName(tokens, tokenIndex)
                {
                    // https://drafts.csswg.org/css-mixins/#typedef-dashed-function
                    isValid = isValidDashedFunction(tokens, block, flags)
                }
                if let isValid {
                    guard isValid else {
                        return nil
                    }
                    result.hasSubstitutionFunctions = true
                    continue
                }

                // A top-level brace block only wraps the value so that it can contain commas, so '!' inside it is still
                // at the top level of the value.
                // https://drafts.csswg.org/css-values-5/#component-function-commas
                stack.append(
                    BlockState(
                        range: block,
                        isTopLevelBlock: false,
                        isInsideTopLevelBraceBlock: tokenType == CSSParserTokenKind.leftBrace && current.isTopLevelBlock
                    )
                )
                continue
            }

            current.range.consume()
            stack[top] = current
            if tokenType == CSSParserTokenKind.delimiter {
                if tokens.tokenDelimiter(tokenIndex) == 0x21 && (current.isTopLevelBlock || current.isInsideTopLevelBraceBlock) { // '!'
                    return nil
                }
            } else if tokenType == CSSParserTokenKind.rightParenthesis || tokenType == CSSParserTokenKind.rightBrace
                || tokenType == CSSParserTokenKind.rightBracket || tokenType == CSSParserTokenKind.badString
                || tokenType == CSSParserTokenKind.badUrl
            {
                return nil
            } else if tokenType == CSSParserTokenKind.semicolon {
                if current.isTopLevelBlock {
                    return nil
                }
            }
        }

        return result
    }

    /// `isValidDeclarationValueArgument`: one comma-separated argument that is a <declaration-value> under the
    /// comma-containing-production rules: a {}-wrapped block groups internal commas, but may not be mixed with other
    /// values, and a bare {} is not a valid value. `allowEmpty` tells <declaration-value>?# (random-item() items) from
    /// <declaration-value># (dashed functions).
    /// https://drafts.csswg.org/css-values-5/#component-function-commas
    private static func isValidDeclarationValueArgument<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ argument: CSSParserTokenSpan,
        _ flags: UInt32,
        allowEmpty: Bool
    ) -> Bool {
        if argument.atEnd {
            return allowEmpty
        }
        guard let result = classifyBlock(tokens, argument, flags) else {
            return false
        }
        return !result.hasTopLevelBraceBlockMixedWithOtherValues && !result.hasEmptyTopLevelBraceBlock
    }

    /// <var-args> = var( <declaration-value> , <declaration-value>? )
    /// The name argument is a <declaration-value>: it is substituted and then parsed as a <custom-property-name> at
    /// substitution time.
    /// https://drafts.csswg.org/css-variables-2/#funcdef-var
    private static func isValidVariableReference<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)

        // Split at the first literal comma into the name argument and optional fallback.
        let name = range.consumeUntil(tokens, CSSParserTokenKind.comma)
        guard isValidDeclarationValueArgument(tokens, name, flags, allowEmpty: false) else {
            return false
        }

        // The split stopped at a literal comma or at the end, so this covers both a missing and an empty fallback.
        guard range.consumeComma(tokens), !range.atEnd else {
            return true
        }
        return classifyBlock(tokens, range, flags) != nil
    }

    /// env() = env( <custom-ident> <integer [0,∞]>*, <declaration-value>? )
    /// https://drafts.csswg.org/css-env-1/#env-function
    private static func isValidEnvReference<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)
        let nameType = range.peekType(tokens)
        range.consumeIncludingWhitespace(tokens)
        guard nameType == CSSParserTokenKind.ident else {
            return false
        }

        guard consumeEnvVariableIndices(tokens, &range) else {
            return false
        }

        if range.atEnd {
            return true
        }
        guard range.consumeComma(tokens) else {
            return false
        }
        if range.atEnd {
            return true
        }
        return classifyBlock(tokens, range, flags) != nil
    }

    /// `CSSSubstitutionParser::consumeEnvVariableIndices`: consumes the <integer [0,∞]>* indices of an env() reference;
    /// false if one is not a non-negative integer.
    private static func consumeEnvVariableIndices<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ range: inout CSSParserTokenSpan
    ) -> Bool {
        while range.peekType(tokens) == CSSParserTokenKind.number {
            let index = range.index
            range.consumeIncludingWhitespace(tokens)
            guard tokens.tokenIsIntegerNumber(index), tokens.tokenNumericValue(index) >= 0 else {
                return false
            }
        }
        return true
    }

    /// An argument may not begin with <dashed-ident> <colon>, which is reserved for named arguments. A brace block
    /// starts with a brace rather than the ident, so wrapping the value in {} allows it.
    /// https://github.com/w3c/csswg-drafts/issues/11749
    private static func startsWithReservedNamedArgument<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ argument: CSSParserTokenSpan
    ) -> Bool {
        var range = argument
        range.consumeWhitespace(tokens)
        // CSSSubstitutionParser::isValidCustomPropertyName.
        guard range.peekType(tokens) == CSSParserTokenKind.ident, cssParserIsCustomPropertyName(tokens, range.index) else {
            return false
        }
        range.consumeIncludingWhitespace(tokens)
        return range.peekType(tokens) == CSSParserTokenKind.colon
    }

    /// <dashed-function> = --*( <declaration-value>#? )
    private static func isValidDashedFunction<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)

        var isFirst = true
        while let argument = consumeArgument(tokens, &range, isFirst: isFirst) {
            if startsWithReservedNamedArgument(tokens, argument) {
                return false
            }
            if !isValidDeclarationValueArgument(tokens, argument, flags, allowEmpty: false) {
                return false
            }
            isFirst = false
        }
        return true
    }

    /// `CSSPropertyParserHelpers::consumeArgument`: the tokens up to the next comma, blocks whole, after the comma
    /// before them unless it is the first; nil at the end.
    private static func consumeArgument<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ range: inout CSSParserTokenSpan,
        isFirst: Bool
    ) -> CSSParserTokenSpan? {
        if range.atEnd {
            return nil
        }
        if !isFirst {
            range.consume() // The comma.
        }
        range.consumeWhitespace(tokens)

        let start = range.index
        while !range.atEnd {
            if tokens.tokenType(range.index) == CSSParserTokenKind.comma {
                break
            }
            if tokens.tokenBlockType(range.index) == CSSParserTokenKind.blockStart {
                _ = range.consumeBlock(tokens)
                continue
            }
            range.consume()
        }
        return CSSParserTokenSpan(index: start, end: range.index)
    }

    /// <attr-args> = attr( <declaration-value>, <declaration-value>? )
    /// Validated with the argument grammar; <attr-name> <attr-type>? is parsed at substitution time.
    /// https://drafts.csswg.org/css-values-5/#funcdef-attr
    private static func isValidAttrReference<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)

        // Split at the first literal comma into two arguments. The first must be non-empty.
        let first = range.consumeUntil(tokens, CSSParserTokenKind.comma)
        if first.atEnd {
            return false
        }
        if classifyBlock(tokens, first, flags) == nil {
            return false
        }

        // Optional second arg (fallback).
        guard range.consumeComma(tokens) else {
            return range.atEnd
        }
        if range.atEnd {
            return true
        }
        return classifyBlock(tokens, range, flags) != nil
    }

    /// <random-item-args> = random-item( <declaration-value>, [ <declaration-value>? ]# )
    /// Validated with the argument grammar; the <random-key> is parsed and an item selected at substitution time.
    /// https://drafts.csswg.org/css-values-5/#funcdef-random-item
    private static func isValidRandomItemReference<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)

        // The required, non-empty <random-key>, up to the first literal comma; commas inside blocks (e.g. {a, b}) are
        // not separators.
        let key = range.consumeUntil(tokens, CSSParserTokenKind.comma)
        if key.atEnd {
            return false
        }
        if classifyBlock(tokens, key, flags) == nil {
            return false
        }

        // A comma must separate the key from the list of items.
        guard range.consumeComma(tokens) else {
            return false
        }

        // [ <declaration-value>? ]#: one or more items, each of which may be empty, under the comma-containing-production
        // rules.
        repeat {
            let item = range.consumeUntil(tokens, CSSParserTokenKind.comma)
            if !isValidDeclarationValueArgument(tokens, item, flags, allowEmpty: true) {
                return false
            }
        } while range.consumeComma(tokens)

        return range.atEnd
    }

    /// <if-args> = if( [ <if-args-branch>; ]* <if-args-branch> ;? )
    /// <if-args-branch> = <declaration-value> : <declaration-value>?
    /// Validated with the argument grammar; conditions are parsed at substitution time. classifyBlock rejects top-level
    /// semicolons, which separate branches here, so each branch is validated alone.
    /// https://drafts.csswg.org/css-values-5/#funcdef-if
    private static func isValidIfReference<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)
        if range.atEnd {
            return false
        }

        while !range.atEnd {
            let branch = range.consumeUntil(tokens, CSSParserTokenKind.semicolon)
            range.consume() // The semicolon, if any.
            range.consumeWhitespace(tokens)

            if branch.atEnd {
                continue
            }
            if classifyBlock(tokens, branch, flags) == nil {
                return false
            }
        }
        return true
    }

    /// <ident-args> = ident( <declaration-value> )
    /// Validated with the argument grammar; the <ident-arg>s are parsed and the identifier built at substitution time.
    /// https://drafts.csswg.org/css-values-5/#ident
    private static func isValidIdentReference<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ arguments: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> Bool {
        var range = arguments
        range.consumeWhitespace(tokens)

        // ident() takes a single argument, so a top-level comma cannot match its grammar.
        let argument = range.consumeUntil(tokens, CSSParserTokenKind.comma)
        if !range.atEnd {
            return false
        }
        return isValidDeclarationValueArgument(tokens, argument, flags, allowEmpty: false)
    }

    /// `classifyVariableRange`: a lone CSS-wide keyword, with whitespace around it, or the class of the tokens; nil if
    /// they are not valid.
    static func classifyVariableRange<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ value: CSSParserTokenSpan,
        _ flags: UInt32
    ) -> VariableType? {
        var range = value
        range.consumeWhitespace(tokens)

        if range.peekType(tokens) == CSSParserTokenKind.ident {
            let id = tokens.tokenIdentifier(range.index)
            var rest = range
            rest.consumeIncludingWhitespace(tokens)
            // Never nil: an imported C++ enum's init(rawValue:) does not check its value.
            if rest.atEnd && WebCore.isCSSWideKeyword(WebCore.CSSValueID(rawValue: id) ?? .Invalid) {
                return VariableType(cssWideKeyword: id)
            }
        }

        guard let blockClass = classifyBlock(tokens, range, flags) else {
            return nil
        }
        return VariableType(cssWideKeyword: nil, blockClass: blockClass)
    }

    /// `CSSSubstitutionParser::containsSubstitutionFunctions`.
    static func containsSubstitutionFunctions<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ value: Range<Int>,
        _ flags: UInt32
    ) -> Bool {
        guard let type = classifyVariableRange(tokens, CSSParserTokenSpan(index: value.lowerBound, end: value.upperBound), flags) else {
            return false
        }
        return type.blockClass.hasSubstitutionFunctions && !type.blockClass.hasTopLevelBraceBlockMixedWithOtherValues
    }

    /// What `CSSSubstitutionParser::parseDeclarationValue` makes of the tokens: a CSSParserSwiftDeclarationValueKind,
    /// with a CSS-wide keyword's CSSValueID above the low byte.
    static func declarationValueKind<Tokens: CSSParserTokenSource & ~Copyable>(
        _ tokens: borrowing Tokens,
        _ value: Range<Int>,
        _ flags: UInt32
    ) -> UInt32 {
        typealias Kind = WebCore.CSSParserSwiftDeclarationValueKind
        guard let type = classifyVariableRange(tokens, CSSParserTokenSpan(index: value.lowerBound, end: value.upperBound), flags) else {
            return UInt32(Kind.Invalid.rawValue)
        }
        if let keyword = type.cssWideKeyword {
            return UInt32(Kind.CSSWideKeyword.rawValue) | UInt32(keyword) &<< 8
        }
        return UInt32(type.blockClass.hasSubstitutionFunctions ? Kind.Substitution.rawValue : Kind.Tokens.rawValue)
    }
}
