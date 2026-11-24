//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2023 Apple Inc. All rights reserved.
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

// The Swift parser's entry points, called through JSC::parseWithSwift (ParserSwiftFacade.cpp) for every parse. The root
// is built with ASTBuilderAdapter; the grammar makes its own SyntaxChecker for the syntax-only passes.

// `input` is the provider's characters, which the caller's `SourceCode` keeps alive for the whole call and nothing writes.
// `facade` is the `JSParseState` on the stack of JSC::parseWithSwift; the C++ it reaches runs no script and never calls
// back into the parse.
//
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jscParse8(_ input: JSC.JSParseInput8, _ modes: JSC.JSParseModes, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseResult {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    return parseSource(characters, modes, &facade)
}

// As jscParse8, for UTF-16 characters.
//
// FIXME: Receive the characters as a Span once a std::span parameter can become one safely (rdar://186723514).
@_expose(Cxx)
func jscParse16(_ input: JSC.JSParseInput16, _ modes: JSC.JSParseModes, _ facade: inout JSC.JSParseFacade) -> JSC.JSParseResult {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    return parseSource(characters, modes, &facade)
}

/// Parses the provider's characters from modes.startOffset and fills in the result the caller reads.
private func parseSource<Unit: LexerCharacter>(
    _ characters: Span<Unit>,
    _ modes: JSC.JSParseModes,
    _ facade: inout JSC.JSParseFacade
) -> JSC.JSParseResult {
    facade.clearErrorMessage()
    var parser = Parser(source: characters, modes: modes, &facade)

    // ParsedNode::scopeIsFunction: a FunctionNode reparses the body of a function the first pass checked.
    if modes.rootKind == .Function {
        parser.lexer.isReparsingFunction = true
    }

    let startLocation = parser.tokenLocation
    let parsingContext: ParsingContext = modes.isFunctionConstructor ? .functionConstructor : .normal
    let parametersEndPosition = Optional(fromCxx: modes.functionConstructorParametersEndPosition).map { Int($0) }

    var context = ASTBuilderAdapter()
    var result = parser.parseInner(&context, modes.calleeName, parsingContext, parametersEndPosition, &facade)

    // The lexer's message wins over the parser's.
    if parser.lexer.sawError {
        parser.lexer.appendErrorMessage(&facade)
    } else if result.outcome != .Succeeded {
        parser.flushErrorMessage(&facade)
    }
    parser.lexer.clear()
    result.startLocation = startLocation
    result.endOffset = UInt32(truncatingIfNeeded: parser.lexer.currentOffset)
    result.tokenType = parser.token.type
    result.tokenStartPosition = parser.tokenStartPosition
    result.tokenEndPosition = parser.tokenEndPosition
    if let extent = parser.lexer.sourceURLDirective {
        result.sourceURLDirective = .init(extent)
    }
    if let extent = parser.lexer.sourceMappingURLDirective {
        result.sourceMappingURLDirective = .init(extent)
    }
    return result
}

extension Parser {
    // MARK: Entry

    // Parser.init has pushed the root scope and lexed the first token; the caller fills in the rest of the result.
    mutating func parseInner<B: TreeBuilder>(
        _ context: inout B,
        _ calleeName: JSC.JSParseIdentifier,
        _ parsingContext: ParsingContext,
        _ functionConstructorParametersEndPosition: Int?,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSParseResult where B.Node == JSC.JSParseNode {
        let parseMode = self.parseMode
        let root = topScope
        scopes[root].setIsLexicalScope()

        let hasPrivateNames = scopes[root].isEvalContext && modes.hasParentScopePrivateNames
        if hasPrivateNames {
            scopes[root].setIsPrivateNameScope()
            facade.copyParentScopePrivateNames(scopes[root].storage)
        }

        let savedFunctionParsePhase = parserState.functionParsePhase
        parserState.functionParsePhase = .body
        defer { parserState.functionParsePhase = savedFunctionParsePhase }

        var parameters = B.Node.null
        var isArrowFunctionBodyExpression = parseMode == .AsyncArrowFunctionBodyMode && !match(.openBrace)
        if lexer.isReparsingFunction {
            var functionInfo = FunctionInfo<B>()
            if JSC.isGeneratorOrAsyncFunctionBodyParseMode(parseMode) {
                parameters = createGeneratorParameters(&context, &functionInfo.parameterCount, &facade)
            } else if parseMode == .ClassFieldInitializerMode {
                parameters = context.createFormalParameterList(&facade)
            } else {
                parameters = parseFunctionParameters(&context, &functionInfo.parameterCount, &facade)
            }

            if (parseMode == .ArrowFunctionMode || parseMode == .AsyncArrowFunctionMode) && !hasError {
                // FIXME:
                // Logically, this should be an assert, since we already successfully parsed the arrow
                // function when syntax checking. So logically, we should see the arrow token here.
                // But we're seeing crashes in the wild when making this an assert. Instead, we'll just
                // handle it as an error in release builds, and an assert on debug builds, with the hopes
                // of fixing it in the future.
                // https://bugs.webkit.org/show_bug.cgi?id=221633
                if !match(.arrowFunction) {
                    assertionFailure()
                    return failedParseInner("Parser error")
                }
                next([], &facade)
                isArrowFunctionBodyExpression = !match(.openBrace)
            }
        }

        if !calleeName.isNull && functionMode == .FunctionExpression {
            _ = scopes[root].declareCallee(calleeName, &facade)
        }

        if lexer.isReparsingFunction {
            statementDepth &-= 1
        }

        var sourceElements = B.Node.null
        // The only way we can error this early is if we reparse a function and we run out of stack space.
        if !hasError {
            if JSC.isAsyncFunctionWrapperParseMode(parseMode) {
                sourceElements = parseAsyncFunctionSourceElements(
                    &context,
                    calleeName,
                    isArrowFunctionBodyExpression,
                    .checkForStrictMode,
                    &facade
                )
            } else if isArrowFunctionBodyExpression {
                sourceElements = parseArrowFunctionSingleExpressionBodySourceElements(&context, &facade)
            } else if JSC.isModuleParseMode(parseMode) {
                sourceElements = parseModuleSourceElements(&context, &facade)
            } else if JSC.isGeneratorWrapperParseMode(parseMode) {
                sourceElements = parseGeneratorFunctionSourceElements(&context, calleeName, .checkForStrictMode, &facade)
            } else if JSC.isAsyncGeneratorWrapperParseMode(parseMode) {
                sourceElements = parseAsyncGeneratorFunctionSourceElements(
                    &context,
                    calleeName,
                    isArrowFunctionBodyExpression,
                    .checkForStrictMode,
                    &facade
                )
            } else if parsingContext == .functionConstructor {
                sourceElements = parseSingleFunction(&context, functionConstructorParametersEndPosition, &facade)
            } else if parseMode == .ClassFieldInitializerMode {
                sourceElements = parseClassFieldInitializerSourceElements(&context, &facade)
            } else {
                sourceElements = parseSourceElements(&context, .checkForStrictMode, &facade)
            }
        }

        let validEnding = consume(.eof, [], &facade)
        if sourceElements.isNull || !validEnding {
            return failedParseInner(nil)
        }

        if !lexer.isReparsingFunction && seenPrivateNameUse {
            let undeclared = facade.undeclaredPrivateName(scopes[root].storage)
            if !undeclared.isNull {
                return failedParseInner(
                    ErrorMessage(.text("Cannot reference undeclared private names: \""), .identifier(undeclared), .text("\""))
                )
            }
        }

        let usedPrivateNameCount = seenPrivateNameUse ? UInt32(facade.usedPrivateNameCount(scopes[root].storage)) : 0

        // It's essential to finalize the hoisting before computing captured variables.
        scopes[root].finalizeSloppyModeFunctionHoisting(&facade)
        facade.markCapturedVariablesAsCaptured(scopes[root].storage, scopes[root].needsFullActivation || scopes[root].usesEval)
        scopes[root].finalizeLexicalEnvironment(&facade)

        if JSC.isGeneratorWrapperParseMode(parseMode) || JSC.isAsyncFunctionOrAsyncGeneratorWrapperParseMode(parseMode) {
            if scopes[root].usedVariablesContains(facade.wellKnownIdentifier(.arguments), &facade) {
                context.propagateArgumentsUse(&facade)
            }
        }

        var features = JSC.CodeFeatures(truncatingIfNeeded: context.features(&facade))
        if scopes[root].shadowsArguments {
            features |= JSC.ShadowsArgumentsFeature
        }
        if seenTaggedTemplateInNonReparsingFunctionMode {
            features |= JSC.NoEvalCacheFeature
        }
        if scopes[root].hasNonSimpleParameterList {
            features |= JSC.NonSimpleParameterListFeature
        }
        if scopes[root].usesImportMeta {
            features |= JSC.ImportMetaFeature
        }
        if seenArgumentsDotLength && scopes[root].hasDeclaredGlobalArguments(&facade) {
            features |= JSC.ArgumentsFeature
        }
        if scopes[root].asyncFunctionBodyDoesNotUseAwait {
            features |= JSC.AsyncFunctionWithoutAwaitFeature
        }
        if scopes[root].usesAwait {
            features |= JSC.AwaitFeature
        }

        var result = JSC.JSParseResult()
        result.outcome = .Succeeded
        result.sourceElements = sourceElements
        result.parameters = parameters
        result.rootScope = scopes[root].storage
        result.features = features
        result.innerArrowFunctionFeatures = scopes[root].innerArrowFunctionFeatures.rawValue
        result.lexicallyScopedFeatures = scopes[root].lexicallyScopedFeatures.rawValue
        result.usedPrivateNameCount = usedPrivateNameCount
        return result
    }

    private mutating func failedParseInner(_ defaultMessage: ErrorMessage?) -> JSC.JSParseResult {
        if !hasError {
            setErrorMessage(defaultMessage ?? "Parser error")
        }
        var result = JSC.JSParseResult()
        result.outcome = hasStackOverflow ? .StackOverflow : .SyntaxError
        return result
    }
}
