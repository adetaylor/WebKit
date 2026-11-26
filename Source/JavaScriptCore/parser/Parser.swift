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

// A scope of the parser's stack: its place there and the generation of the Scope pushed there. A read through
// withScope checks the generation, so a reference to a popped scope traps; a read by `index` into the live scope stack
// is bounds-checked and indexes a live scope. The facade handle of its storage is read from the live Scope, never kept
// here.
struct ScopeRef: BitwiseCopyable {
    let index: Int
    let generation: UInt32
}

enum FunctionParsePhase {
    case parameters
    case body
}

/// The parser state a save point restores.
struct ParserState {
    var assignmentCount: Int32 = 0
    var nonLHSCount: Int32 = 0
    var nonTrivialExpressionCount: Int32 = 0
    var returnStatementCount: Int32 = 0
    var functionParsePhase = FunctionParsePhase.body
    var lastIdentifier = JSC.JSParseIdentifier()
    var lastFunctionName = JSC.JSParseIdentifier()
    var lastPrivateName = JSC.JSParseIdentifier()
    var allowAwait = true
    var isParsingClassFieldInitializer = false
    var classFieldInitMasksAsync = false
}

// The parser's state; the grammar files add the productions as generic members over a TreeBuilder.
//
// A member the grammar calls is `mutating` (or `@inline(always)`) even when it only reads: the struct is too big to
// pass in registers, and an out-of-line non-mutating call copies all of it into the caller's frame first, a stack
// slot per call site in every recursive grammar function. `mutating` passes its address instead.
struct Parser<Unit: LexerCharacter>: ~Copyable, ~Escapable {
    var lexer: Lexer<Unit>
    var token = Token()
    var lastTokenLocation = JSC.JSTokenLocation()
    var lastTokenType = JSC.JSTokenType.error
    var scopes = UniqueArray<Scope>()
    /// `scopes.count - 1`, kept by pushScope and popScope so that a scope access does not recompute it (-1 while empty).
    var topScope = -1
    /// `scopes[topScope].strictMode`, which every `next()` reads: kept by pushScope, popScope and setStrictMode (the
    /// only places the current scope or its strict mode change), so that a token costs no indexed read of the stack.
    var topStrictMode = false
    /// The generation of the last Scope pushed: each Scope gets the next, so a ScopeRef to a popped one never matches.
    var scopeGeneration: UInt32 = 0
    /// The start positions of the `new` tokens of the member expressions being parsed, innermost last.
    var newTokenStartPositions: [JSC.JSTextPosition] = []
    /// The labels of every scope on `scopes`, outermost first; a scope's are those from its `labelsBase`.
    var labelStack: [ScopeLabelInfo] = []
    /// The first failure's message; nil until a production fails.
    var errorMessage: ErrorMessage?
    let hasDebuggerParseData: Bool
    let hasFunctionCache: Bool
    let hasModuleScopeData: Bool
    var statementDepth: Int32 = 0
    var immediateParentAllowsFunctionDeclarationInStatement = false
    var parserState = ParserState()
    var allowsIn = true
    var parseMode: JSC.SourceParseMode
    var seenTaggedTemplateInNonReparsingFunctionMode = false
    var seenPrivateNameUse = false
    var seenArgumentsDotLength = false
    /// The enclosing call-or-apply depth scopes, innermost last.
    var callOrApplyDepthScopes = UniqueArray<CallOrApplyDepthScope>()
    var hasStackOverflow = false
    /// The parse's inputs, fixed at the start; `functionMode` and the other members below read it in place.
    let modes: JSC.JSParseModes
    var functionMode: JSC.FunctionMode { modes.functionMode }
    var parsingBuiltin: Bool { modes.builtinMode == .Builtin }
    var implementationVisibility: JSC.ImplementationVisibility { modes.implementationVisibility }
    var constructorKindForTopLevelFunctionExpressions: JSC.ConstructorKind {
        modes.constructorKindForTopLevelFunctionExpressions
    }
    var isInsideOrdinaryFunction: Bool { modes.isInsideOrdinaryFunction }
    var scriptMode: JSC.JSParserScriptMode { modes.scriptMode }
    var superBinding: JSC.SuperBinding { modes.superBinding }

    @_lifetime(copy source)
    init(source: Span<Unit>, modes: JSC.JSParseModes, _ facade: inout JSC.JSParseFacade) {
        lexer = Lexer(source: source, modes: modes)
        self.modes = modes
        hasDebuggerParseData = facade.hasDebuggerParseData()
        hasFunctionCache = facade.hasFunctionCache()
        hasModuleScopeData = facade.hasModuleScopeData()
        parseMode = modes.parseMode

        // The root scope with the parse's modes, and the first token.
        token.startPosition.offset = Int32(bitPattern: modes.startOffset)
        token.endPosition.offset = Int32(bitPattern: modes.startOffset)

        let root = pushScope(&facade)
        withScope(root) { scope in
            scope.lexicallyScopedFeatures = LexicallyScopedFeatureSet(rawValue: modes.lexicallyScopedFeatures)
            scope.setSourceParseMode(modes.parseMode)
            scope.isEvalContext = modes.rootKind == .Eval
            if modes.rootKind == .Eval {
                scope.evalContextType = modes.evalContextType
            }
            if scope.isFunction {
                scope.constructorKind = modes.constructorKind
            } else {
                assert(modes.constructorKind == .None)
            }
            scope.derivedContextType = modes.derivedContextType
            if modes.derivedContextType != .None {
                scope.expectedSuperBinding = .Needed
            }
        }
        // The modes' features (a module's, an eval's in strict code) are the root's strict mode.
        topStrictMode = scopes[root.index].strictMode

        next([], &facade)
    }
}

extension Parser {
    // MARK: Debugger recording

    mutating func recordPauseLocation(_ position: JSC.JSTextPosition, _ facade: inout JSC.JSParseFacade) {
        guard hasDebuggerParseData, position.offset >= 0 else { return }
        facade.appendDebuggerPause(position)
    }

    mutating func recordFunctionEntryLocation(_ position: JSC.JSTextPosition, _ facade: inout JSC.JSParseFacade) {
        guard hasDebuggerParseData else { return }
        facade.appendDebuggerEntry(position)
    }

    mutating func recordFunctionLeaveLocation(_ position: JSC.JSTextPosition, _ facade: inout JSC.JSParseFacade) {
        guard hasDebuggerParseData else { return }
        facade.appendDebuggerLeave(position)
    }
}
