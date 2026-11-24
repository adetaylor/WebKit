//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2023 Apple Inc. All rights reserved.
//  Copyright (C) 2003-2024 Apple Inc. All rights reserved.
//  Copyright (C) 2026 Apple Inc. All rights reserved.
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.
//

internal import JSCSwiftBoundary

extension Parser {
    // MARK: Tokens

    @inline(always)
    mutating func next(_ flags: LexerFlags = [], _ facade: inout JSC.JSParseFacade) {
        lastTokenLocation = token.location
        lastTokenType = token.type
        let type = lexer.lex(&token, flags: flags, strictMode: strictMode, &facade)
        token.type = type
    }

    @inline(always)
    mutating func nextWithoutClearingLineTerminator(_ flags: LexerFlags = [], _ facade: inout JSC.JSParseFacade) {
        lastTokenLocation = token.location
        lastTokenType = token.type
        let type = lexer.lexWithoutClearingLineTerminator(&token, flags: flags, strictMode: strictMode, &facade)
        token.type = type
    }

    @inline(always)
    var nextTokenIsColon: Bool {
        lexer.nextTokenIsColon
    }

    @inline(always)
    mutating func consume(_ expected: JSC.JSTokenType, _ flags: LexerFlags = [], _ facade: inout JSC.JSParseFacade) -> Bool {
        let result = token.type == expected
        if result {
            next(flags, &facade)
        }
        return result
    }

    @inline(always)
    func match(_ expected: JSC.JSTokenType) -> Bool {
        token.type == expected
    }

    @inline(always)
    func matchContextualKeyword(_ name: JSC.JSParseWellKnownName, _ facade: inout JSC.JSParseFacade) -> Bool {
        token.type == .identifier && token.data.ident.matches(name, &facade) && !token.data.escaped
    }

    @inline(always)
    func matchIdentifierOrKeyword() -> Bool {
        token.type == .identifier || token.type.isKeyword
    }

    var tokenStart: UInt32 { UInt32(bitPattern: token.startPosition.offset) }

    var tokenStartPosition: JSC.JSTextPosition { token.startPosition }

    var tokenEndPosition: JSC.JSTextPosition { token.endPosition }

    var tokenLocation: JSC.JSTokenLocation { token.location }

    /// A position holding only the last token's end offset.
    var lastTokenEndPosition: JSC.JSTextPosition { JSC.JSTextPosition(offset: Int(lastTokenLocation.endOffset)) }

    /// Consumes a semicolon, or accepts a statement end where automatic semicolon insertion applies.
    @inline(always)
    mutating func autoSemiColon(_ facade: inout JSC.JSParseFacade) -> Bool {
        if token.type == .semicolon {
            next([], &facade)
            return true
        }
        return allowAutomaticSemicolon
    }

    var allowAutomaticSemicolon: Bool {
        match(.closeBrace) || match(.eof) || lexer.hasLineTerminatorBeforeToken
    }

    // MARK: Identifiers

    func isPossiblyEscapedLet(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        token.isPossiblyEscaped(.letKeyword, named: .letKeyword, &facade)
    }

    func isPossiblyEscapedAwait(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        token.isPossiblyEscaped(.awaitKeyword, named: .awaitKeyword, &facade)
    }

    mutating func isDisallowedIdentifierAwait(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        isPossiblyEscapedAwait(token, &facade) && !canUseIdentifierAwait
    }

    mutating func isDisallowedIdentifierYield(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        isPossiblyEscapedYield(token, &facade) && !canUseIdentifierYield
    }

    var canUseIdentifierAwait: Bool {
        parserState.allowAwait && !currentIsAsyncFunction && !currentIsStaticBlock && scriptMode != .Module
    }

    var isModuleParseMode: Bool { parseMode == .ModuleAnalyzeMode || parseMode == .ModuleEvaluateMode }

    @inline(always)
    func isAllowedIdentifierLet(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        isPossiblyEscapedLet(token, &facade) && !strictMode
    }

    func isPossiblyEscapedYield(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        token.isPossiblyEscaped(.yieldKeyword, named: .yieldKeyword, &facade)
    }

    var canUseIdentifierYield: Bool {
        !strictMode && !currentIsGeneratorFunction
    }

    @inline(always)
    func isAllowedIdentifierYield(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        isPossiblyEscapedYield(token, &facade) && canUseIdentifierYield
    }

    @inline(always)
    mutating func matchSpecIdentifier(_ facade: inout JSC.JSParseFacade) -> Bool {
        match(.identifier) || isAllowedIdentifierLet(token, &facade) || isAllowedIdentifierYield(token, &facade)
            || isPossiblyEscapedAwait(token, &facade)
    }

    mutating func disallowedIdentifierLetReason() -> Swift.String {
        assert(strictMode)
        return "in strict mode"
    }

    mutating func disallowedIdentifierAwaitReason() -> Swift.String {
        if !parserState.allowAwait || currentIsAsyncFunction {
            return "in an async function"
        }
        if currentIsStaticBlock {
            return "in a static block"
        }
        if scriptMode == .Module {
            return "in a module"
        }
        fatalError("not reached")
    }

    mutating func disallowedIdentifierYieldReason() -> Swift.String {
        if strictMode {
            return "in strict mode"
        }
        if currentIsGeneratorFunction {
            return "in a generator function"
        }
        fatalError("not reached")
    }

    mutating func isAllowedIdentifierAwait(_ token: Token, _ facade: inout JSC.JSParseFacade) -> Bool {
        isPossiblyEscapedAwait(token, &facade) && canUseIdentifierAwait
    }

    // Special case where some information is already known.
    mutating func matchSpecIdentifier(canUseYield: Bool, isAwait: Bool, _ facade: inout JSC.JSParseFacade) -> Bool {
        isAwait || match(.identifier) || isAllowedIdentifierLet(token, &facade) || (canUseYield && isPossiblyEscapedYield(token, &facade))
    }

    mutating func matchIdentifierOrPossiblyEscapedContextualKeyword(_ facade: inout JSC.JSParseFacade) -> Bool {
        match(.identifier) || isPossiblyEscapedLet(token, &facade) || isPossiblyEscapedYield(token, &facade)
            || isPossiblyEscapedAwait(token, &facade)
    }

    mutating func matchAllowedEscapedContextualKeyword(_ facade: inout JSC.JSParseFacade) -> Bool {
        assert(token.type == .escapedKeyword)
        let ident = token.data.ident
        return (ident.matches(.letKeyword, &facade) && !strictMode) || (ident.matches(.awaitKeyword, &facade) && canUseIdentifierAwait)
            || (ident.matches(.yieldKeyword, &facade) && canUseIdentifierYield)
    }

    func isArgumentsIdentifier(_ facade: inout JSC.JSParseFacade) -> Bool {
        token.data.ident.matches(.arguments, &facade)
    }
}
