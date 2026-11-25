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

private struct LabelInfo {
    var ident: JSC.JSParseIdentifier
    var start: JSC.JSTextPosition
    var end: JSC.JSTextPosition
}

extension Parser {
    /// The length of the source text `"use strict"` with its quotes.
    private static var lengthOfUseStrictLiteral: UInt32 { 12 }

    mutating func parseSourceElements<B: TreeBuilder>(
        _ context: inout B,
        _ mode: SourceElementsMode,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        var sourceElements = context.createSourceElements(&facade)
        var directive = JSC.JSParseIdentifier()
        var directiveLiteralLength: UInt32 = 0
        // Set while the statements read so far may still be directives.
        var useStrictSavePoint: SavePoint? = mode == .checkForStrictMode ? createSavePoint(&context, &facade) : nil

        while true {
            let statement = parseStatementListItem(&context, &directive, &directiveLiteralLength, &facade)
            if statement.isNull {
                break
            }
            if let savePoint = useStrictSavePoint {
                if !directive.isNull {
                    // "use strict" must be the exact literal without escape sequences or line continuation.
                    if directiveLiteralLength == Self.lengthOfUseStrictLiteral && directive.matches(.useStrictIdentifier, &facade) {
                        setStrictMode()
                        useStrictSavePoint = nil // We saw "use strict", there is no need to keep checking for it.
                        if !isValidStrictMode {
                            let lastFunctionName = parserState.lastFunctionName
                            if !lastFunctionName.isNull {
                                if lastFunctionName.matches(.arguments, &facade) {
                                    return semanticFail("Cannot name a function 'arguments' in strict mode")
                                }
                                if lastFunctionName.matches(.eval, &facade) {
                                    return semanticFail("Cannot name a function 'eval' in strict mode")
                                }
                            }
                            if hasDeclaredVariable(facade.wellKnownIdentifier(.arguments), &facade) {
                                return semanticFail("Cannot declare a variable named 'arguments' in strict mode")
                            }
                            if hasDeclaredVariable(facade.wellKnownIdentifier(.eval), &facade) {
                                return semanticFail("Cannot declare a variable named 'eval' in strict mode")
                            }
                            if scopes[topScope].hasNonSimpleParameterList {
                                return semanticFail("'use strict' directive not allowed inside a function with a non-simple parameter list")
                            }
                            if !isValidStrictMode {
                                return semanticFail("Invalid parameters or function name in strict mode")
                            }
                        }
                        // Since strict mode is changed, restoring lexer state by calling next() may cause errors.
                        restoreSavePoint(&context, savePoint, &facade)
                        if hasError {
                            return .null
                        }
                        // Drop any directives parsed so far because they will be parsed again.
                        sourceElements = context.createSourceElements(&facade)
                        continue
                    }

                    // We saw a directive, but it wasn't "use strict". We reset our state to
                    // see if the next statement we parse is also a directive.
                    directive = JSC.JSParseIdentifier()
                } else {
                    // We saw a statement that wasn't in the form of a directive. The spec says that "use strict"
                    // is only allowed as the first statement, or after a sequence of directives before it, but
                    // not after non-directive statements.
                    useStrictSavePoint = nil
                }
            }
            context.appendStatement(&facade, sourceElements, statement)
        }

        if hasError {
            return .null
        }
        return sourceElements
    }

    mutating func parseModuleSourceElements<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.SourceElements {
        let sourceElements = context.createSourceElements(&facade)
        var syntaxChecker = SyntaxChecker()

        loop: while true {
            var statement = B.Statement.null
            switch token.type {
            case .exportKeyword:
                statement = parseExportDeclaration(&context, &facade)
                if !statement.isNull {
                    recordPauseLocation(context.breakpointLocation(&facade, statement), &facade)
                }

            case .importKeyword:
                let savePoint = createSavePoint(&context, &facade)
                next([], &facade)
                let isImportDeclaration = !match(.openParen) && !match(.dot)
                restoreSavePoint(&context, savePoint, &facade)
                if isImportDeclaration {
                    statement = parseImportDeclaration(&context, &facade)
                    if !statement.isNull {
                        recordPauseLocation(context.breakpointLocation(&facade, statement), &facade)
                    }
                    break
                }

                // This is `import("...")` call or `import.meta` meta property case.
                fallthrough

            default:
                var directive = JSC.JSParseIdentifier()
                var directiveLiteralLength: UInt32 = 0
                if parseMode == .ModuleAnalyzeMode {
                    if parseStatementListItem(&syntaxChecker, &directive, &directiveLiteralLength, &facade).isNull {
                        break loop
                    }
                    continue loop
                }
                statement = parseStatementListItem(&context, &directive, &directiveLiteralLength, &facade)
            }

            if statement.isNull {
                break loop
            }
            context.appendStatement(&facade, sourceElements, statement)
        }

        if hasError {
            return .null
        }

        let unresolvedBinding = facade.markExportedBindingsAsExported(scopes[topScope].storage)
        if !unresolvedBinding.isNull {
            return semanticFail(
                ErrorMessage(
                    .text("Exported binding '"),
                    .identifier(unresolvedBinding),
                    .text("' needs to refer to a top-level declared variable")
                )
            )
        }

        return sourceElements
    }

    mutating func parseGeneratorFunctionSourceElements<B: TreeBuilder>(
        _ context: inout B,
        _ name: JSC.JSParseIdentifier,
        _ mode: SourceElementsMode,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        let sourceElements = context.createSourceElements(&facade)

        let functionStart = tokenStart
        let startLocation = tokenLocation
        let start = tokenStartPosition
        let functionNameStart = token.startPosition.offset
        let parametersStart = functionNameStart

        var info = FunctionInfo<B>()
        info.name = facade.wellKnownIdentifier(.nullIdentifier)
        _ = createGeneratorParameters(&context, &info.parameterCount, &facade)
        info.startOffset = UInt32(bitPattern: parametersStart)

        do {
            let generatorBodyScope = pushScope(&facade)
            var popped = false
            defer {
                if !popped {
                    popScope(generatorBodyScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
                }
            }

            withScope(generatorBodyScope) { $0.setSourceParseMode(.GeneratorBodyMode) }
            resetImplementationVisibilityIfNeeded()

            let superBinding = self.superBinding
            withScope(generatorBodyScope) {
                $0.constructorKind = .None
                $0.expectedSuperBinding = superBinding
            }

            var generatorFunctionContext = SyntaxChecker()
            if parseSourceElements(&generatorFunctionContext, mode, &facade).isNull {
                return fail("Cannot parse the body of a generator")
            }
            popped = true
            popScope(generatorBodyScope, shouldTrackClosedVariables: B.needsFreeVariableInfo, takeContainers: false, &facade)
        }
        info.body = context.createFunctionMetadata(
            &facade,
            startLocation,
            tokenLocation,
            functionStart,
            functionNameStart,
            parametersStart,
            currentImplementationVisibility,
            currentLexicallyScopedFeatures,
            .None,
            superBinding,
            info.parameterCount,
            .GeneratorBodyMode,
            false
        )

        // The body is parsed as its own source, so the current token is EOF; the closing brace is the
        // previous token.
        info.endOffset = lastTokenLocation.startOffset

        let functionExpr = context.createGeneratorFunctionBody(&facade, startLocation, info, name)
        let statement = context.createExprStatement(&facade, startLocation, functionExpr, start)
        context.appendStatement(&facade, sourceElements, statement)

        return sourceElements
    }

    mutating func parseAsyncFunctionSourceElements<B: TreeBuilder>(
        _ context: inout B,
        _ calleeName: JSC.JSParseIdentifier,
        _ isArrowFunctionBodyExpression: Bool,
        _ mode: SourceElementsMode,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        assert(JSC.isAsyncFunctionOrAsyncGeneratorWrapperParseMode(parseMode))

        let functionStart = tokenStart
        let startLocation = tokenLocation
        let start = tokenStartPosition
        let functionNameStart = token.startPosition.offset
        let parametersStart = functionNameStart

        let bodyParseMode = parseMode.asyncFunctionBodyMode
        let savedParseMode = parseMode
        parseMode = bodyParseMode
        defer { parseMode = savedParseMode }

        var bodyUsesAwait = false
        let bodySavePoint = createSavePoint(&context, &facade)
        do {
            let asyncFunctionBodyScope = pushScope(&facade)
            var popped = false
            defer {
                if !popped {
                    popScope(asyncFunctionBodyScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
                }
            }

            let currentParseMode = parseMode
            withScope(asyncFunctionBodyScope) { $0.setSourceParseMode(currentParseMode) }
            resetImplementationVisibilityIfNeeded()

            var syntaxChecker = SyntaxChecker()
            if !parseBodySourceElements(&context, &syntaxChecker, isArrowFunctionBodyExpression, mode, &facade) {
                if isArrowFunctionBodyExpression {
                    return fail("Cannot parse the body of async arrow function")
                }
                return fail("Cannot parse the body of async function")
            }
            bodyUsesAwait = withScope(asyncFunctionBodyScope) { $0.usesAwait }

            // When body doesn't use await, we'll inline it directly in the wrapper.
            // In this case, there's no body function, so we don't need to track closed variables
            // (which would unnecessarily mark parameters as captured).
            popped = true
            popScope(
                asyncFunctionBodyScope,
                shouldTrackClosedVariables: bodyUsesAwait ? B.needsFreeVariableInfo : false,
                takeContainers: false,
                &facade
            )
        }

        // If the body doesn't use await, we can inline it directly into the wrapper.
        // without creating a separate body function or generator infrastructure.
        // For example,
        //
        //     async function test(a, b) {
        //         return 42;
        //     }
        //
        if !bodyUsesAwait {
            // Re-parse with ASTBuilder to get the actual body AST.
            // Parse directly in the wrapper's scope (not a separate body scope) so that
            // lexical variables (let, const) are registered in the wrapper's scope.
            restoreSavePoint(&context, bodySavePoint, &facade)
            withScope(currentFunctionScope()) { $0.setAsyncFunctionBodyDoesNotUseAwait() }
            if isArrowFunctionBodyExpression {
                return parseArrowFunctionSingleExpressionBodySourceElements(&context, &facade)
            }
            return parseSourceElements(&context, mode, &facade)
        }

        // Full async function path (has await) - create body function with generator parameters.
        let sourceElements = context.createSourceElements(&facade)

        var info = FunctionInfo<B>()
        info.name = facade.wellKnownIdentifier(.nullIdentifier)
        _ = createGeneratorParameters(&context, &info.parameterCount, &facade)
        info.startOffset = UInt32(bitPattern: parametersStart)

        let implementationVisibility: JSC.ImplementationVisibility =
            currentImplementationVisibility == .Private ? .Public : currentImplementationVisibility

        info.body = context.createFunctionMetadata(
            &facade,
            startLocation,
            tokenLocation,
            functionStart,
            functionNameStart,
            parametersStart,
            implementationVisibility,
            currentLexicallyScopedFeatures,
            .None,
            superBinding,
            info.parameterCount,
            parseMode,
            isArrowFunctionBodyExpression
        )

        // The body is parsed as its own source, so the current token is EOF; the closing brace is the
        // previous token.
        info.endOffset = isArrowFunctionBodyExpression ? tokenLocation.endOffset : lastTokenLocation.startOffset

        let functionExpr = context.createAsyncFunctionBody(&facade, startLocation, info, bodyParseMode, calleeName)
        let statement = context.createExprStatement(&facade, startLocation, functionExpr, start)
        context.appendStatement(&facade, sourceElements, statement)

        return sourceElements
    }

    mutating func parseAsyncGeneratorFunctionSourceElements<B: TreeBuilder>(
        _ context: inout B,
        _ calleeName: JSC.JSParseIdentifier,
        _ isArrowFunctionBodyExpression: Bool,
        _ mode: SourceElementsMode,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        assert(JSC.isAsyncGeneratorWrapperParseMode(parseMode))
        let sourceElements = context.createSourceElements(&facade)

        let functionStart = tokenStart
        let startLocation = tokenLocation
        let start = tokenStartPosition
        let functionNameStart = token.startPosition.offset
        let parametersStart = functionNameStart

        var info = FunctionInfo<B>()
        info.name = facade.wellKnownIdentifier(.nullIdentifier)
        _ = createGeneratorParameters(&context, &info.parameterCount, &facade)
        info.startOffset = UInt32(bitPattern: parametersStart)

        let bodyParseMode = JSC.SourceParseMode.AsyncGeneratorBodyMode
        let savedParseMode = parseMode
        parseMode = bodyParseMode
        defer { parseMode = savedParseMode }
        do {
            let asyncFunctionBodyScope = pushScope(&facade)
            var popped = false
            defer {
                if !popped {
                    popScope(asyncFunctionBodyScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
                }
            }

            withScope(asyncFunctionBodyScope) { $0.setSourceParseMode(bodyParseMode) }
            resetImplementationVisibilityIfNeeded()

            var syntaxChecker = SyntaxChecker()
            if !parseBodySourceElements(&context, &syntaxChecker, isArrowFunctionBodyExpression, mode, &facade) {
                if isArrowFunctionBodyExpression {
                    return fail("Cannot parse the body of async arrow function")
                }
                return fail("Cannot parse the body of async function")
            }
            popped = true
            popScope(asyncFunctionBodyScope, shouldTrackClosedVariables: B.needsFreeVariableInfo, takeContainers: false, &facade)
        }
        info.body = context.createFunctionMetadata(
            &facade,
            startLocation,
            tokenLocation,
            functionStart,
            functionNameStart,
            parametersStart,
            currentImplementationVisibility,
            currentLexicallyScopedFeatures,
            .None,
            superBinding,
            info.parameterCount,
            bodyParseMode,
            isArrowFunctionBodyExpression
        )

        // The body is parsed as its own source, so the current token is EOF; the closing brace is the
        // previous token.
        info.endOffset = isArrowFunctionBodyExpression ? tokenLocation.endOffset : lastTokenLocation.startOffset

        let functionExpr = context.createAsyncFunctionBody(&facade, startLocation, info, bodyParseMode, calleeName)
        let statement = context.createExprStatement(&facade, startLocation, functionExpr, start)
        context.appendStatement(&facade, sourceElements, statement)

        return sourceElements
    }

    mutating func parseSingleFunction<B: TreeBuilder>(
        _ context: inout B,
        _ functionConstructorParametersEndPosition: Int?,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        let sourceElements = context.createSourceElements(&facade)
        let statement: B.Statement
        switch token.type {
        case .functionKeyword:
            statement = parseFunctionDeclaration(
                &context,
                .declaration,
                exportType: .notExported,
                defaultContext: .standard,
                functionConstructorParametersEndPosition: functionConstructorParametersEndPosition,
                &facade
            )
        case .identifier where token.data.ident.matches(.async, &facade) && !token.data.escaped:
            let functionStart = tokenStart
            next([], &facade)
            if !(match(.functionKeyword) && !lexer.hasLineTerminatorBeforeToken) {
                return fail("Cannot parse the async function")
            }
            statement = parseAsyncFunctionDeclaration(
                &context,
                functionStart,
                exportType: .notExported,
                defaultContext: .standard,
                functionConstructorParametersEndPosition: functionConstructorParametersEndPosition,
                &facade
            )
        default:
            return failDueToUnexpectedToken()
        }

        if !statement.isNull {
            context.setEndOffset(&facade, statement, Int32(bitPattern: lastTokenLocation.endOffset))
            context.appendStatement(&facade, sourceElements, statement)
        }

        if hasError {
            return .null
        }
        return sourceElements
    }

    // MARK: Statements

    mutating func parseStatementListItem<B: TreeBuilder>(
        _ context: inout B,
        _ directive: inout JSC.JSParseIdentifier,
        _ directiveLiteralLength: inout UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        // The grammar is documented here:
        // http://www.ecma-international.org/ecma-262/6.0/index.html#sec-statements
        let savedStatementDepth = statementDepth
        defer { statementDepth = savedStatementDepth }
        statementDepth &+= 1
        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }
        var result = B.Statement.null
        var shouldSetEndOffset = true
        var shouldSetPauseLocation = false

        switch token.type {
        case .constKeyword:
            result = parseVariableDeclaration(&context, .const, .notExported, &facade)
            shouldSetPauseLocation = true
        case .letKeyword:
            var shouldParseVariableDeclaration = true
            if !strictMode {
                let savePoint = createSavePoint(&context, &facade)
                next([], &facade)
                // Intentionally use `matchIdentifierOrPossiblyEscapedContextualKeyword()` and not `matchSpecIdentifier()`.
                // We would like contextual keywords to fall under parseVariableDeclaration even when not used as identifiers.
                // For example, under a generator context, matchSpecIdentifier() for "yield" returns `false`.
                // But we would like to enter parseVariableDeclaration and raise an error under the context of parseVariableDeclaration
                // to raise consistent errors between "var", "const" and "let".
                if !matchIdentifierOrPossiblyEscapedContextualKeyword(&facade) && !match(.openBrace) && !match(.openBracket) {
                    shouldParseVariableDeclaration = false
                }
                restoreSavePoint(&context, savePoint, &facade)
            }
            if shouldParseVariableDeclaration {
                result = parseVariableDeclaration(&context, .let, .notExported, &facade)
            } else {
                result = parseExpressionOrLabelStatement(&context, allowFunctionDeclarationAsStatement: true, &facade)
            }
            shouldSetPauseLocation = !context.shouldSkipPauseLocation(&facade, result)
        case .classKeyword:
            result = parseClassDeclaration(&context, exportType: .notExported, defaultContext: .standard, &facade)
        case .functionKeyword:
            result = parseFunctionDeclaration(
                &context,
                .declaration,
                exportType: .notExported,
                defaultContext: .standard,
                functionConstructorParametersEndPosition: nil,
                &facade
            )
        case .escapedKeyword, .identifier, .awaitKeyword, .yieldKeyword:
            if token.type == .escapedKeyword && !matchAllowedEscapedContextualKeyword(&facade) {
                return failDueToUnexpectedToken()
            }
            if token.type == .escapedKeyword || token.type == .identifier {
                if modes.useExplicitResourceManagement && token.data.ident.matches(.usingIdentifier, &facade) && !token.data.escaped {
                    let savePoint = createSavePoint(&context, &facade)
                    next([], &facade)
                    if !lexer.hasLineTerminatorBeforeToken && matchSpecIdentifier(&facade) {
                        restoreSavePoint(&context, savePoint, &facade)
                        let top = topScope
                        if scopes[top].isGlobalCode && !scopes[top].isModuleCode && statementDepth == 1 {
                            return semanticFail("'using' declaration is not allowed at the top level of a script or eval")
                        }
                        if scopes[top].isSwitchBlockScope {
                            return semanticFail("'using' declaration is not allowed directly in a switch case or default clause")
                        }
                        result = parseVariableDeclaration(&context, .using, .notExported, &facade)
                        shouldSetPauseLocation = true
                        break
                    }
                    restoreSavePoint(&context, savePoint, &facade)
                }
                if token.data.ident.matches(.async, &facade) && !token.data.escaped {
                    // Eagerly parse as AsyncFunctionDeclaration. This is the uncommon case,
                    // but could be mistakenly parsed as an AsyncFunctionExpression.
                    let savePoint = createSavePoint(&context, &facade)
                    let functionStart = tokenStart
                    next([], &facade)
                    if match(.functionKeyword) && !lexer.hasLineTerminatorBeforeToken {
                        result = parseAsyncFunctionDeclaration(
                            &context,
                            functionStart,
                            exportType: .notExported,
                            defaultContext: .standard,
                            functionConstructorParametersEndPosition: nil,
                            &facade
                        )
                        break
                    }
                    restoreSavePoint(&context, savePoint, &facade)
                }
            }
            if token.type != .yieldKeyword {
                if modes.useExplicitResourceManagement && match(.awaitKeyword) && !parserState.classFieldInitMasksAsync
                    && (withScope(currentFunctionScope()) { $0.isAsyncFunctionBoundary } || isModuleParseMode)
                {
                    let savePoint = createSavePoint(&context, &facade)
                    next([], &facade)
                    if !lexer.hasLineTerminatorBeforeToken && match(.identifier) && token.data.ident.matches(.usingIdentifier, &facade)
                        && !token.data.escaped
                    {
                        next([], &facade)
                        if !lexer.hasLineTerminatorBeforeToken && matchSpecIdentifier(&facade) {
                            restoreSavePoint(&context, savePoint, &facade)
                            let top = topScope
                            if scopes[top].isGlobalCode && !scopes[top].isModuleCode && statementDepth == 1 {
                                return semanticFail("'await using' declaration is not allowed at the top level of a script or eval")
                            }
                            if scopes[top].isSwitchBlockScope {
                                return semanticFail("'await using' declaration is not allowed directly in a switch case or default clause")
                            }
                            withScope(currentFunctionScope()) { $0.setUsesAwait() }
                            result = parseVariableDeclaration(&context, .awaitUsing, .notExported, &facade)
                            shouldSetPauseLocation = true
                            break
                        }
                    }
                    restoreSavePoint(&context, savePoint, &facade)
                }
            }
            if scopes[topScope].isStaticBlock {
                if match(.yieldKeyword) {
                    return fail("Cannot use 'yield' within static block")
                }
                if match(.awaitKeyword) {
                    return fail("Cannot use 'await' within static block")
                }
            }
            // This is a convenient place to notice labeled statements
            // (even though we also parse them as normal statements)
            // because we allow the following type of code in sloppy mode:
            // ``` function foo() { label: function bar() { } } ```
            result = parseExpressionOrLabelStatement(&context, allowFunctionDeclarationAsStatement: true, &facade)
            shouldSetPauseLocation = !context.shouldSkipPauseLocation(&facade, result)
        default:
            statementDepth &-= 1 // parseStatement() increments the depth.
            result = parseStatement(&context, &directive, &directiveLiteralLength, &facade)
            shouldSetEndOffset = false
        }

        if !result.isNull {
            if shouldSetEndOffset {
                context.setEndOffset(&facade, result, Int32(bitPattern: lastTokenLocation.endOffset))
            }
            if shouldSetPauseLocation {
                recordPauseLocation(context.breakpointLocation(&facade, result), &facade)
            }
        }

        return result
    }

    /// Parses a function body into the context or the syntax checker.
    ///
    /// The context is used when the debugger wants the tree. Returns false when the body did not parse.
    @inline(always)
    mutating func parseBodySourceElements<B: TreeBuilder, S: TreeBuilder>(
        _ context: inout B,
        _ syntaxChecker: inout S,
        _ isArrowFunctionBodyExpression: Bool,
        _ mode: SourceElementsMode,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        if isArrowFunctionBodyExpression {
            if hasDebuggerParseData {
                return !parseArrowFunctionSingleExpressionBodySourceElements(&context, &facade).isNull
            }
            return !parseArrowFunctionSingleExpressionBodySourceElements(&syntaxChecker, &facade).isNull
        }
        if hasDebuggerParseData {
            return !parseSourceElements(&context, mode, &facade).isNull
        }
        return !parseSourceElements(&syntaxChecker, mode, &facade).isNull
    }

    mutating func parseArrowFunctionSingleExpressionBodySourceElements<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> B.SourceElements {
        assert(!match(.openBrace))

        let location = tokenLocation
        let start = tokenStartPosition

        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }
        let expr = parseAssignmentExpression(&context, &facade)
        if expr.isNull {
            return fail("Cannot parse the arrow function expression")
        }

        context.setEndOffset(&facade, expr, Int32(bitPattern: lastTokenLocation.endOffset))

        let end = tokenEndPosition

        let sourceElements = context.createSourceElements(&facade)
        let body = context.createReturnStatement(&facade, location, expr, start, end)
        context.setEndOffset(&facade, body, Int32(bitPattern: lastTokenLocation.endOffset))
        recordPauseLocation(context.breakpointLocation(&facade, body), &facade)
        context.appendStatement(&facade, sourceElements, body)

        return sourceElements
    }

    mutating func parseBreakStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.breakKeyword))
        let location = tokenLocation
        let start = tokenStartPosition
        var end = tokenEndPosition
        next([], &facade)

        if scopes[topScope].isStaticBlock && !scopes[topScope].breakIsValid && !breakIsValid {
            return semanticFail("'break' cannot cross static block boundary")
        }

        if autoSemiColon(&facade) {
            if !breakIsValid {
                return semanticFail("'break' is only valid inside a switch or loop statement")
            }
            return context.createBreakStatement(&facade, location, facade.wellKnownIdentifier(.nullIdentifier), start, end)
        }
        if !matchSpecIdentifier(&facade) {
            return fail("Expected an identifier as the target for a break statement")
        }
        let ident = token.data.ident
        if label(ident, &facade) == nil {
            return semanticFail(ErrorMessage(.text("Cannot use the undeclared label '"), .identifier(ident), .text("'")))
        }
        end = tokenEndPosition
        next([], &facade)
        if !autoSemiColon(&facade) {
            return fail("Expected a ';' following a targeted break statement")
        }
        return context.createBreakStatement(&facade, location, ident, start, end)
    }

    mutating func parseContinueStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.continueKeyword))
        let location = tokenLocation
        let start = tokenStartPosition
        var end = tokenEndPosition
        next([], &facade)

        if scopes[topScope].isStaticBlock && !scopes[topScope].continueIsValid && !continueIsValid {
            return semanticFail("'continue' cannot cross static block boundary")
        }

        if autoSemiColon(&facade) {
            if !continueIsValid {
                return semanticFail("'continue' is only valid inside a loop statement")
            }
            return context.createContinueStatement(&facade, location, facade.wellKnownIdentifier(.nullIdentifier), start, end)
        }
        if !matchSpecIdentifier(&facade) {
            return fail("Expected an identifier as the target for a continue statement")
        }
        let ident = token.data.ident
        guard let targetLabel = label(ident, &facade) else {
            return semanticFail(ErrorMessage(.text("Cannot use the undeclared label '"), .identifier(ident), .text("'")))
        }
        if !targetLabel.isLoop {
            return semanticFail(
                ErrorMessage(.text("Cannot continue to the label '"), .identifier(ident), .text("' as it is not targeting a loop"))
            )
        }
        end = tokenEndPosition
        next([], &facade)
        if !autoSemiColon(&facade) {
            return fail("Expected a ';' following a targeted continue statement")
        }
        return context.createContinueStatement(&facade, location, ident, start, end)
    }

    mutating func parseReturnStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.returnKeyword))
        parserState.returnStatementCount &+= 1
        let location = tokenLocation
        if !(scopes[topScope].isFunction && !scopes[topScope].isStaticBlock) {
            return semanticFail("Return statements are only valid inside functions")
        }
        let start = tokenStartPosition
        var end = tokenEndPosition
        next([], &facade)
        // We do the auto semicolon check before attempting to parse expression
        // as we need to ensure the a line break after the return correctly terminates
        // the statement
        if match(.semicolon) {
            end = tokenEndPosition
        }

        if autoSemiColon(&facade) {
            return context.createReturnStatement(&facade, location, .null, start, end)
        }
        let expr = parseExpression(&context, &facade)
        if expr.isNull {
            return fail("Cannot parse the return expression")
        }
        end = lastTokenEndPosition
        if match(.semicolon) {
            end = tokenEndPosition
        }
        if !autoSemiColon(&facade) {
            return fail("Expected a ';' following a return statement")
        }
        return context.createReturnStatement(&facade, location, expr, start, end)
    }

    mutating func parseThrowStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.throwKeyword))
        let location = tokenLocation
        let start = tokenStartPosition
        next([], &facade)
        if match(.semicolon) {
            return fail("Expected expression after 'throw'")
        }
        if autoSemiColon(&facade) {
            return semanticFail("Cannot have a newline after 'throw'")
        }

        let expr = parseExpression(&context, &facade)
        if expr.isNull {
            return fail("Cannot parse expression for throw statement")
        }
        let end = lastTokenEndPosition
        if !autoSemiColon(&facade) {
            return fail("Expected a ';' after a throw statement")
        }

        return context.createThrowStatement(&facade, location, expr, start, end)
    }

    mutating func parseWithStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.withKeyword))
        let location = tokenLocation
        if strictMode {
            return semanticFail("'with' statements are not valid in strict mode")
        }
        scopes[topScope].setNeedsFullActivation()
        next([], &facade)

        if !handleProductionOrFail(.openParen, "(", "start", "a subject of a 'with' statement", &facade) {
            return .null
        }
        let start = tokenStart
        let expr = parseExpression(&context, &facade)
        if expr.isNull {
            return fail("Cannot parse 'with' subject expression")
        }
        recordPauseLocation(context.breakpointLocation(&facade, expr), &facade)
        let end = lastTokenEndPosition
        if !handleProductionOrFail(.closeParen, ")", "start", "a subject of a 'with' statement", &facade) {
            return .null
        }

        let withScope = pushScope(&facade)
        var withScopePopped = false
        defer {
            if !withScopePopped {
                popScope(withScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }
        self.withScope(withScope) {
            $0.setTaintedByWithScope()
            $0.preventAllVariableDeclarations()
        }

        let statement = parseStatement(&context, &facade)
        if statement.isNull {
            return fail("A 'with' statement must have a body")
        }

        let result = context.createWithStatement(&facade, location, expr, statement, start, end)
        withScopePopped = true
        popScope(withScope, shouldTrackClosedVariables: B.needsFreeVariableInfo, takeContainers: false, &facade)
        return result
    }

    mutating func parseSwitchStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.switchKeyword))
        let location = tokenLocation
        next([], &facade)
        if !handleProductionOrFail(.openParen, "(", "start", "a subject of a 'switch'", &facade) {
            return .null
        }
        let expr = parseExpression(&context, &facade)
        if expr.isNull {
            return fail("Cannot parse switch subject expression")
        }
        recordPauseLocation(context.breakpointLocation(&facade, expr), &facade)

        if !handleProductionOrFail(.closeParen, ")", "end", "a subject of a 'switch'", &facade) {
            return .null
        }
        if !handleProductionOrFail(.openBrace, "{", "start", "a body of a 'switch'", &facade) {
            return .null
        }
        let lexicalScope = pushScope(&facade)
        var lexicalScopePopped = false
        defer {
            if !lexicalScopePopped {
                popScope(lexicalScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }
        withScope(lexicalScope) {
            $0.setIsLexicalScope()
            $0.preventVarDeclarations()
        }
        startSwitch()
        let firstClauses = parseSwitchClauses(&context, &facade)
        if hasError {
            return .null
        }

        let defaultClause = parseSwitchDefaultClause(&context, &facade)
        if hasError {
            return .null
        }

        let secondClauses = parseSwitchClauses(&context, &facade)
        if hasError {
            return .null
        }
        endSwitch()
        if !handleProductionOrFail(.closeBrace, "}", "end", "a body of a 'switch'", &facade) {
            return .null
        }

        lexicalScopePopped = true
        let (lexicalEnvironment, functionDeclarations) = popScope(
            lexicalScope,
            shouldTrackClosedVariables: B.needsFreeVariableInfo,
            takeContainers: B.createsAST,
            &facade
        )
        return context.createSwitchStatement(
            &facade,
            location,
            expr,
            firstClauses,
            defaultClause,
            secondClauses,
            lexicalEnvironment,
            functionDeclarations
        )
    }

    mutating func parseSwitchClauses<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.ClauseList {
        if !match(.caseKeyword) {
            return .null
        }
        var startOffset = Int32(bitPattern: tokenStart)
        next([], &facade)
        var condition = parseExpression(&context, &facade)
        if condition.isNull {
            return fail("Cannot parse switch clause")
        }
        if !consumeOrFail(.colon, "Expected a ':' after switch clause expression", &facade) {
            return .null
        }
        var statements = parseSourceElements(&context, .dontCheckForStrictMode, &facade)
        if statements.isNull {
            return fail("Cannot parse the body of a switch clause")
        }
        var clause = context.createClause(&facade, condition, statements)
        context.setStartOffset(&facade, clause, startOffset)
        let clauseList = context.createClauseList(&facade, clause)
        var tail = clauseList

        while match(.caseKeyword) {
            startOffset = Int32(bitPattern: tokenStart)
            next([], &facade)
            condition = parseExpression(&context, &facade)
            if condition.isNull {
                return fail("Cannot parse switch case expression")
            }
            if !consumeOrFail(.colon, "Expected a ':' after switch clause expression", &facade) {
                return .null
            }
            statements = parseSourceElements(&context, .dontCheckForStrictMode, &facade)
            if statements.isNull {
                return fail("Cannot parse the body of a switch clause")
            }
            clause = context.createClause(&facade, condition, statements)
            context.setStartOffset(&facade, clause, startOffset)
            tail = context.createClauseList(&facade, tail, clause)
        }
        return clauseList
    }

    mutating func parseSwitchDefaultClause<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Clause {
        if !match(.defaultKeyword) {
            return .null
        }
        let startOffset = Int32(bitPattern: tokenStart)
        next([], &facade)
        if !consumeOrFail(.colon, "Expected a ':' after switch default clause", &facade) {
            return .null
        }
        let statements = parseSourceElements(&context, .dontCheckForStrictMode, &facade)
        if statements.isNull {
            return fail("Cannot parse the body of a switch default clause")
        }
        let result = context.createClause(&facade, .null, statements)
        context.setStartOffset(&facade, result, startOffset)
        return result
    }

    mutating func parseTryStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.tryKeyword))
        let location = tokenLocation
        let tryBlock: B.Statement
        var catchPattern = B.DestructuringPattern.null
        var catchBlock = B.Statement.null
        var finallyBlock = B.Statement.null
        next([], &facade)
        if !match(.openBrace) {
            return fail("Expected a block statement as body of a try statement")
        }

        let returnStatementCountBeforeTryBlock = parserState.returnStatementCount
        tryBlock = parseBlockStatement(&context, .normal, &facade)
        if tryBlock.isNull {
            return fail("Cannot parse the body of try block")
        }
        let tryBlockContainsReturn = parserState.returnStatementCount != returnStatementCountBeforeTryBlock
        var catchEnvironment = JSC.JSParseEnvironment()
        if consume(.catchKeyword, [], &facade) {
            if match(.openBrace) {
                catchBlock = parseBlockStatement(&context, .normal, &facade)
                if catchBlock.isNull {
                    return fail("Unable to parse 'catch' block")
                }
            } else {
                if !handleProductionOrFail(.openParen, "(", "start", "a 'catch' target", &facade) {
                    return .null
                }
                let savedStatementDepth = statementDepth
                defer { statementDepth = savedStatementDepth }
                statementDepth &+= 1
                let catchScope = pushScope(&facade)
                var catchScopePopped = false
                defer {
                    if !catchScopePopped {
                        popScope(catchScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
                    }
                }
                withScope(catchScope) {
                    $0.setIsLexicalScope()
                    $0.preventVarDeclarations()
                }
                var ident: JSC.JSParseIdentifier? = nil
                if matchSpecIdentifier(&facade) {
                    if isDisallowedIdentifierAwait(token, &facade) {
                        return semanticFail(
                            ErrorMessage(
                                .text("Cannot use 'await' as a \(DestructuringKind.catchParameters.variableKindName) "),
                                .text(disallowedIdentifierAwaitReason())
                            )
                        )
                    }
                    withScope(catchScope) { $0.setIsSimpleCatchParameterScope() }
                    let name = token.data.ident
                    ident = name
                    catchPattern = context.createBindingLocation(
                        &facade,
                        token.location,
                        name,
                        token.startPosition,
                        token.endPosition,
                        .DeclarationStatement
                    )
                    next([], &facade)
                    let declarationResult = withScope(catchScope) { $0.declareLexicalVariable(name, isConstant: false, &facade) }
                    if strictMode && declarationResult.contains(.invalidStrictMode) {
                        return semanticFail(
                            ErrorMessage(.text("Cannot declare a catch variable named '"), .identifier(name), .text("' in strict mode"))
                        )
                    }
                } else {
                    var duplicateIdentifier = JSC.JSParseIdentifier()
                    var hasDestructuringPattern = false
                    catchPattern = parseDestructuringPattern(
                        &context,
                        .catchParameters,
                        .notExported,
                        &duplicateIdentifier,
                        &hasDestructuringPattern,
                        .DeclarationStatement,
                        depth: 0,
                        &facade
                    )
                    if catchPattern.isNull {
                        return fail("Cannot parse this destructuring pattern")
                    }
                }
                if !handleProductionOrFail(.closeParen, ")", "end", "a 'catch' target", &facade) {
                    return .null
                }
                if !match(.openBrace) {
                    return fail("Expected exception handler to be a block statement")
                }
                catchBlock = parseBlockStatement(&context, .catch, &facade)
                if catchBlock.isNull {
                    return fail("Unable to parse 'catch' block")
                }
                // Handle `try { } catch (/* never used */ error) { }`
                if let name = ident {
                    let neverUsed = withScope(catchScope) {
                        !$0.usedVariablesContains(name, &facade) && !$0.usesEval && !$0.hasVariableBeingHoisted(name, &facade)
                    }
                    if neverUsed {
                        catchPattern = .null
                    }
                }
                catchScopePopped = true
                if B.createsAST, let name = ident {
                    // The catch parameter is the scope's only lexical variable.
                    let catchStorage = withScope(catchScope) { $0.storage }
                    precondition(
                        facade.environmentSize(catchStorage, .Lexical) == 1 && facade.environmentContains(catchStorage, .Lexical, name)
                    )
                }
                (catchEnvironment, _) = popScope(
                    catchScope,
                    shouldTrackClosedVariables: B.needsFreeVariableInfo,
                    takeContainers: B.createsAST,
                    &facade
                )
            }
        }

        if consume(.finallyKeyword, [], &facade) {
            if !match(.openBrace) {
                return fail("Expected block statement for finally body")
            }
            finallyBlock = parseBlockStatement(&context, .normal, &facade)
            if finallyBlock.isNull {
                return fail("Cannot parse finally body")
            }
        }
        if catchBlock.isNull && finallyBlock.isNull {
            return fail("Try statements must have at least a catch or finally block")
        }

        if tryBlockContainsReturn && finallyBlock.isNull && withScope(currentFunctionScope()) { $0.constructorKind } == .Extends {
            // Empty `finally` statement is necessary to prevent BytecodeGenerator::emitReturn() from being
            // called inside the `try` block, which would otherwise result in errors thrown at steps 10-12
            // of https://tc39.es/ecma262/#sec-ecmascript-function-objects-construct-argumentslist-newtarget
            // being caught by the `catch` block.
            finallyBlock = context.createEmptyStatement(&facade, location)
        }

        return context.createTryStatement(&facade, location, tryBlock, catchPattern, catchBlock, finallyBlock, catchEnvironment)
    }

    mutating func parseDebuggerStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.debuggerKeyword))
        let location = tokenLocation
        next([], &facade)
        if !autoSemiColon(&facade) {
            return fail("Debugger keyword must be followed by a ';'")
        }
        return context.createDebugger(&facade, location)
    }

    mutating func parseBlockStatement<B: TreeBuilder>(
        _ context: inout B,
        _ type: BlockType = .normal,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        assert(match(.openBrace))

        // We should treat the first block statement of the function (the body of the function) as the lexical
        // scope of the function itself, and not the lexical scope of a 'block' statement within the function.
        let shouldPushLexicalScope = statementDepth > 0 || type == .staticBlock
        var lexicalScope = ScopeRef?.none
        defer {
            if let lexicalScope {
                popScope(lexicalScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }
        if shouldPushLexicalScope {
            let newScope = pushScope(&facade)
            lexicalScope = newScope
            withScope(newScope) { $0.setIsLexicalScope() }
            switch type {
            case .catch:
                withScope(newScope) {
                    $0.setIsCatchBlockScope()
                    $0.preventVarDeclarations()
                }
            case .normal:
                withScope(newScope) { $0.preventVarDeclarations() }
            case .staticBlock:
                withScope(newScope) {
                    $0.setSourceParseMode(.ClassStaticBlockMode)
                    $0.expectedSuperBinding = .Needed
                }
            }
        }
        let location = tokenLocation
        let startOffset = token.startPosition.offset
        var lexicalEnvironment = JSC.JSParseEnvironment()
        var functionStack = JSC.JSParseFunctionStack()
        next([], &facade)
        if match(.closeBrace) {
            let endOffset = token.startPosition.offset
            next([], &facade)
            if let scopeToPop = lexicalScope.take() {
                (lexicalEnvironment, functionStack) = popScope(
                    scopeToPop,
                    shouldTrackClosedVariables: B.needsFreeVariableInfo,
                    takeContainers: B.createsAST,
                    &facade
                )
            }
            let result = context.createBlockStatement(&facade, location, .null, lexicalEnvironment, functionStack)
            context.setStartOffsetWithNode(&facade, result, startOffset)
            context.setEndOffset(&facade, result, endOffset)
            return result
        }
        let subtree = parseSourceElements(&context, .dontCheckForStrictMode, &facade)
        if subtree.isNull {
            return fail("Cannot parse the body of the block statement")
        }
        if !match(.closeBrace) {
            return fail("Expected a closing '}' at the end of a block statement")
        }
        let endOffset = token.startPosition.offset
        next([], &facade)
        if let scopeToPop = lexicalScope.take() {
            (lexicalEnvironment, functionStack) = popScope(
                scopeToPop,
                shouldTrackClosedVariables: B.needsFreeVariableInfo,
                takeContainers: B.createsAST,
                &facade
            )
        }
        let result = context.createBlockStatement(&facade, location, subtree, lexicalEnvironment, functionStack)
        context.setStartOffsetWithNode(&facade, result, startOffset)
        context.setEndOffset(&facade, result, endOffset)
        return result
    }

    /// A statement whose directive and its length are not wanted.
    @inline(always)
    mutating func parseStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        var directive = JSC.JSParseIdentifier()
        var directiveLiteralLength: UInt32 = 0
        return parseStatement(&context, &directive, &directiveLiteralLength, &facade)
    }

    /// The body of a loop: a statement parsed between startLoop and endLoop.
    @inline(always)
    mutating func parseLoopBody<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        startLoop()
        let statement = parseStatement(&context, &facade)
        endLoop()
        return statement
    }

    mutating func parseStatement<B: TreeBuilder>(
        _ context: inout B,
        _ directive: inout JSC.JSParseIdentifier,
        _ directiveLiteralLength: inout UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        let savedStatementDepth = statementDepth
        defer { statementDepth = savedStatementDepth }
        statementDepth &+= 1
        var nonTrivialExpressionCount: Int32 = 0
        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }
        var result = B.Statement.null
        var shouldSetEndOffset = true
        var shouldSetPauseLocation = false
        let parentAllowsFunctionDeclarationAsStatement = immediateParentAllowsFunctionDeclarationInStatement
        immediateParentAllowsFunctionDeclarationInStatement = false

        switch token.type {
        case .openBrace:
            result = parseBlockStatement(&context, .normal, &facade)
            shouldSetEndOffset = false
        case .varKeyword:
            result = parseVariableDeclaration(&context, .var, .notExported, &facade)
            shouldSetPauseLocation = true
        case .functionKeyword:
            result = parseFunctionDeclarationStatement(&context, parentAllowsFunctionDeclarationAsStatement, &facade)
        case .semicolon:
            let location = tokenLocation
            next([], &facade)
            result = context.createEmptyStatement(&facade, location)
        case .ifKeyword:
            result = parseIfStatement(&context, &facade)
        case .doKeyword:
            result = parseDoWhileStatement(&context, &facade)
        case .whileKeyword:
            result = parseWhileStatement(&context, &facade)
        case .forKeyword:
            result = parseForStatement(&context, &facade)
        case .continueKeyword:
            result = parseContinueStatement(&context, &facade)
            shouldSetPauseLocation = true
        case .breakKeyword:
            result = parseBreakStatement(&context, &facade)
            shouldSetPauseLocation = true
        case .returnKeyword:
            result = parseReturnStatement(&context, &facade)
            shouldSetPauseLocation = true
        case .withKeyword:
            result = parseWithStatement(&context, &facade)
        case .switchKeyword:
            result = parseSwitchStatement(&context, &facade)
        case .throwKeyword:
            result = parseThrowStatement(&context, &facade)
            shouldSetPauseLocation = true
        case .tryKeyword:
            result = parseTryStatement(&context, &facade)
        case .debuggerKeyword:
            result = parseDebuggerStatement(&context, &facade)
            shouldSetPauseLocation = true
        case .eof, .caseKeyword, .closeBrace, .defaultKeyword:
            // These tokens imply the end of a set of source elements
            return .null
        case .escapedKeyword, .letKeyword, .identifier, .awaitKeyword, .yieldKeyword:
            if token.type == .escapedKeyword && !matchAllowedEscapedContextualKeyword(&facade) {
                return failDueToUnexpectedToken()
            }
            result = parseExpressionOrLabelStatement(&context, allowFunctionDeclarationAsStatement: false, &facade)
            shouldSetPauseLocation = !context.shouldSkipPauseLocation(&facade, result)
        default:
            if token.type == .string {
                directive = token.data.ident
                let location = token.location
                directiveLiteralLength = location.endOffset - location.startOffset
                nonTrivialExpressionCount = parserState.nonTrivialExpressionCount
            }
            let exprStatement = parseExpressionStatement(&context, &facade)
            if !directive.isNull && nonTrivialExpressionCount != parserState.nonTrivialExpressionCount {
                directive = JSC.JSParseIdentifier()
            }
            result = exprStatement
            shouldSetPauseLocation = true
        }

        if !result.isNull {
            if shouldSetEndOffset {
                context.setEndOffset(&facade, result, Int32(bitPattern: lastTokenLocation.endOffset))
            }
            if shouldSetPauseLocation {
                recordPauseLocation(context.breakpointLocation(&facade, result), &facade)
            }
        }

        return result
    }

    /// Out of line, as its callers' frames are on every recursion and its own is small.
    @inline(never)
    mutating func parseExpressionOrLabelStatement<B: TreeBuilder>(
        _ context: inout B,
        allowFunctionDeclarationAsStatement: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        // Expression and Label statements are ambiguous at LL(1), so we have a special case that looks for a colon as
        // the next character in the input.
        if !nextTokenIsColon {
            return parseExpressionStatement(&context, &facade)
        }
        return parseLabelledStatement(&context, allowFunctionDeclarationAsStatement: allowFunctionDeclarationAsStatement, &facade)
    }

    /// The labelled-statement half of parseExpressionOrLabelStatement, out of line so its locals are not in every
    /// expression statement's frame.
    @inline(never)
    mutating func parseLabelledStatement<B: TreeBuilder>(
        _ context: inout B,
        allowFunctionDeclarationAsStatement: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Statement {
        var labels: [LabelInfo] = []
        var location = JSC.JSTokenLocation()
        var isFirstLabel = true
        repeat {
            if !isFirstLabel && !nextTokenIsColon {
                // If we hit this path we're making a expression statement, which by definition can't make use of
                // continue/break so we can just ignore any labels we might have accumulated.
                return parseExpressionStatement(&context, &facade)
            }
            isFirstLabel = false

            if isPossiblyEscapedLet(token, &facade) && strictMode {
                return semanticFail(.text("Cannot use 'let' as a label \(disallowedIdentifierLetReason())"))
            }
            if isDisallowedIdentifierAwait(token, &facade) {
                return semanticFail(.text("Cannot use 'await' as a label \(disallowedIdentifierAwaitReason())"))
            }
            if isDisallowedIdentifierYield(token, &facade) {
                return semanticFail(.text("Cannot use 'yield' as a label \(disallowedIdentifierYieldReason())"))
            }

            let ident = token.data.ident
            let start = tokenStartPosition
            let end = tokenEndPosition
            location = tokenLocation
            next([], &facade)
            if !consumeOrFail(.colon, "Labels must be followed by a ':'", &facade) {
                return .null
            }

            // This is O(N^2) over the current list of consecutive labels, but I have never seen more than one label
            // in a row in the real world.
            if labels.contains(where: { facade.sameIdentifier(ident, $0.ident) }) {
                return fail(ErrorMessage(.text("Attempted to redeclare the label '"), .identifier(ident), .text("'")))
            }
            if label(ident, &facade) != nil {
                return fail(ErrorMessage(.text("Cannot find scope for the label '"), .identifier(ident), .text("'")))
            }
            labels.append(LabelInfo(ident: ident, start: start, end: end))
        } while matchSpecIdentifier(&facade)
        let isLoop: Bool
        switch token.type {
        case .forKeyword, .whileKeyword, .doKeyword:
            isLoop = true
        default:
            isLoop = false
        }
        let labelScope = current
        for info in labels {
            pushLabel(info.ident, isLoop: isLoop)
        }
        var statement = B.Statement.null
        if allowFunctionDeclarationAsStatement && match(.functionKeyword) && !strictMode {
            statement = parseFunctionDeclaration(
                &context,
                .statement,
                exportType: .notExported,
                defaultContext: .standard,
                functionConstructorParametersEndPosition: nil,
                &facade
            )
        } else {
            statement = parseStatement(&context, &facade)
        }
        for _ in labels {
            popLabel(labelScope)
        }
        if statement.isNull {
            return fail("Cannot parse statement")
        }
        for info in labels.reversed() {
            statement = context.createLabelStatement(&facade, location, info.ident, statement, info.start, info.end)
        }
        return statement
    }

    mutating func parseExpressionStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        switch token.type {
        // https://tc39.es/ecma262/#sec-expression-statement
        // Despite the spec's requirement to fail from FUNCTION token here, Annex B.3.1 permits a labelled
        // FunctionDeclaration in sloppy mode for web compatibility reasons. We implement this semantics in
        // parseExpressionOrLabelStatement().
        case .classKeyword:
            return fail("'class' declaration is not directly within a block statement")
        case .letKeyword:
            let savePoint = createSavePoint(&context, &facade)
            next([], &facade)
            if match(.openBracket) {
                return fail("Cannot use lexical declaration in single-statement context")
            }
            restoreSavePoint(&context, savePoint, &facade)
        case .identifier:
            if matchContextualKeyword(.async, &facade) {
                let savePoint = createSavePoint(&context, &facade)
                next([], &facade)
                if match(.functionKeyword) && !lexer.hasLineTerminatorBeforeToken {
                    return fail("Cannot use async function declaration in single-statement context")
                }
                restoreSavePoint(&context, savePoint, &facade)
            }
        default:
            break
        }

        let start = tokenStartPosition
        let location = tokenLocation
        let expression = parseExpression(&context, &facade)
        if expression.isNull {
            return fail("Cannot parse expression statement")
        }
        if !autoSemiColon(&facade) {
            return failDueToUnexpectedToken()
        }
        return context.createExprStatement(&facade, location, expression, start)
    }

    mutating func parseIfStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.ifKeyword))
        let ifLocation = tokenLocation
        next([], &facade)
        if !handleProductionOrFail(.openParen, "(", "start", "an 'if' condition", &facade) {
            return .null
        }

        let condition = parseExpression(&context, &facade)
        if condition.isNull {
            return fail("Expected an expression as the condition for an if statement")
        }
        recordPauseLocation(context.breakpointLocation(&facade, condition), &facade)
        if !handleProductionOrFail(.closeParen, ")", "end", "an 'if' condition", &facade) {
            return .null
        }

        immediateParentAllowsFunctionDeclarationInStatement = true
        let trueBlock = parseStatement(&context, &facade)
        if trueBlock.isNull {
            return fail("Expected a statement as the body of an if block")
        }

        if !match(.elseKeyword) {
            return context.createIfStatement(&facade, ifLocation, condition, trueBlock, .null)
        }

        var tempLocation = tokenLocation
        next([], &facade)
        if !match(.ifKeyword) {
            let block = parseElseBlock(&context, &facade)
            if block.isNull {
                return .null
            }
            return context.createIfStatement(&facade, ifLocation, condition, trueBlock, block)
        }

        var chain: [(condition: B.Expression, location: JSC.JSTokenLocation, trueBlock: B.Statement)] = []
        var elseBlock: B.Statement?
        while true {
            next([], &facade)

            if !handleProductionOrFail(.openParen, "(", "start", "an 'if' condition", &facade) {
                return .null
            }

            let innerCondition = parseExpression(&context, &facade)
            if innerCondition.isNull {
                return fail("Expected an expression as the condition for an if statement")
            }
            recordPauseLocation(context.breakpointLocation(&facade, innerCondition), &facade)
            if !handleProductionOrFail(.closeParen, ")", "end", "an 'if' condition", &facade) {
                return .null
            }
            immediateParentAllowsFunctionDeclarationInStatement = true
            let innerTrueBlock = parseStatement(&context, &facade)
            if innerTrueBlock.isNull {
                return fail("Expected a statement as the body of an if block")
            }
            chain.append((innerCondition, tempLocation, innerTrueBlock))
            if !match(.elseKeyword) {
                break
            }
            tempLocation = tokenLocation
            next([], &facade)
            if !match(.ifKeyword) {
                let block = parseElseBlock(&context, &facade)
                if block.isNull {
                    return .null
                }
                elseBlock = block
                break
            }
        }

        var falseBlock: B.Statement
        if let elseBlock {
            falseBlock = elseBlock
        } else {
            let last = chain.removeLast()
            falseBlock = context.createIfStatement(&facade, last.location, last.condition, last.trueBlock, .null)
            context.setEndOffset(&facade, falseBlock, context.endOffset(&facade, last.trueBlock))
        }

        while let link = chain.popLast() {
            let ifStatement = context.createIfStatement(&facade, link.location, link.condition, link.trueBlock, falseBlock)
            context.setEndOffset(&facade, ifStatement, context.endOffset(&facade, falseBlock))
            falseBlock = ifStatement
        }

        return context.createIfStatement(&facade, ifLocation, condition, trueBlock, falseBlock)
    }

    /// The statement after an 'else' that is not followed by 'if'.
    private mutating func parseElseBlock<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        immediateParentAllowsFunctionDeclarationInStatement = true
        let block = parseStatement(&context, &facade)
        if block.isNull {
            return fail("Expected a statement as the body of an else block")
        }
        return block
    }
}
