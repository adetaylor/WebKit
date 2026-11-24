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

/// How a for header continues once its first part is parsed.
private enum ForHeader {
    case standard
    case enumeration
}

extension Parser {
    mutating func parseDoWhileStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.doKeyword))
        next([], &facade)
        let statement = parseLoopBody(&context, &facade)
        if statement.isNull {
            return fail("Expected a statement following 'do'")
        }
        let location = tokenLocation
        if !handleProductionOrFail(.whileKeyword, "while", "end", "a do-while loop", &facade) {
            return .null
        }
        if !handleProductionOrFail(.openParen, "(", "start", "a do-while loop condition", &facade) {
            return .null
        }
        if match(.closeParen) {
            return semanticFail("Must provide an expression as a do-while loop condition")
        }
        let expr = parseExpression(&context, &facade)
        if expr.isNull {
            return fail("Unable to parse do-while loop condition")
        }
        recordPauseLocation(context.breakpointLocation(&facade, expr), &facade)
        if !handleProductionOrFail(.closeParen, ")", "end", "a do-while loop condition", &facade) {
            return .null
        }
        _ = consume(.semicolon, [], &facade) // Always performs automatic semicolon insertion.
        return context.createDoWhileStatement(&facade, location, statement, expr)
    }

    mutating func parseWhileStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.whileKeyword))
        let location = tokenLocation
        next([], &facade)

        if !handleProductionOrFail(.openParen, "(", "start", "a while loop condition", &facade) {
            return .null
        }
        if match(.closeParen) {
            return semanticFail("Must provide an expression as a while loop condition")
        }
        let expr = parseExpression(&context, &facade)
        if expr.isNull {
            return fail("Unable to parse while loop condition")
        }
        recordPauseLocation(context.breakpointLocation(&facade, expr), &facade)
        if !handleProductionOrFail(.closeParen, ")", "end", "a while loop condition", &facade) {
            return .null
        }

        let statement = parseLoopBody(&context, &facade)
        if statement.isNull {
            return fail("Expected a statement as the body of a while loop")
        }
        return context.createWhileStatement(&facade, location, expr, statement)
    }

    /// Pops the for loop's lexical scope, if it pushed one.
    private mutating func popForLoopLexicalScope<B: TreeBuilder>(
        _ context: inout B,
        _ lexicalScope: inout ScopeRef?,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSParseEnvironment {
        guard let scope = lexicalScope else {
            return JSC.JSParseEnvironment()
        }
        lexicalScope = nil
        return popScope(scope, shouldTrackClosedVariables: B.needsFreeVariableInfo, takeContainers: B.createsAST, &facade).lexicalVariables
    }

    mutating func parseForStatement<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        assert(match(.forKeyword))
        let location = tokenLocation
        var isAwaitFor = false
        next([], &facade)

        let savedStatementDepth = statementDepth
        defer { statementDepth = savedStatementDepth }
        statementDepth &+= 1

        if match(.awaitKeyword) {
            if !(scopes[topScope].isAsyncFunction || isModuleParseMode) {
                return semanticFail("for-await-of can only be used in an async function or async generator")
            }
            isAwaitFor = true
            withScope(currentFunctionScope()) { $0.setUsesAwait() }
            next([], &facade)
        }

        if !handleProductionOrFail(.openParen, "(", "start", "a for-loop header", &facade) {
            return .null
        }
        let nonLHSCount = parserState.nonLHSCount
        var declarations = 0
        let declLocation = tokenLocation
        var declsStart = tokenStartPosition
        var decls = B.Expression.null
        var pattern = B.DestructuringPattern.null
        // The kind of declaration the header starts with, if it starts with one.
        var declarationType: DeclarationType? = match(.varKeyword) ? .var : match(.constKeyword) ? .const : nil
        var isAsyncOf = false
        if matchContextualKeyword(.async, &facade) {
            let lexerState = internalSaveLexerState()
            next([], &facade)
            isAsyncOf = matchContextualKeyword(.of, &facade)
            restoreLexerState(lexerState, &facade)
        }
        if modes.useExplicitResourceManagement && match(.identifier)
            && token.data.ident.matches(.usingIdentifier, &facade)
            && !token.data.escaped
        {
            let savePoint = createSavePoint(&context, &facade)
            next([], &facade)
            if !lexer.hasLineTerminatorBeforeToken && matchSpecIdentifier(&facade) {
                if matchContextualKeyword(.of, &facade) {
                    // "for (using of ..." - the spec has [lookahead != `using` `of`] on ForDeclaration,
                    // so this is only a using declaration if 'of' is a binding name with an initializer.
                    // "for (using of = init; ...)" -> using declaration, 'of' is binding name
                    // "for (using of expr)" -> for-of loop, 'using' is identifier, 'of' is keyword
                    // "for (using of of expr)" -> for-of loop, 'using' is identifier, first 'of' is keyword
                    next([], &facade) // consume 'of'
                    if match(.equal) {
                        declarationType = .using
                    }
                } else {
                    declarationType = .using
                }
            }
            restoreSavePoint(&context, savePoint, &facade)
        } else if modes.useExplicitResourceManagement && match(.awaitKeyword)
            && !parserState.classFieldInitMasksAsync
            && (withScope(currentFunctionScope()) { $0.isAsyncFunctionBoundary } || isModuleParseMode)
        {
            let savePoint = createSavePoint(&context, &facade)
            next([], &facade)
            if !lexer.hasLineTerminatorBeforeToken
                && match(.identifier)
                && token.data.ident.matches(.usingIdentifier, &facade)
                && !token.data.escaped
            {
                next([], &facade)
                // Note: unlike sync `using`, there is no [lookahead != `of`] constraint for `await using`,
                // so `for (await using of of expr)` binds `of` as an identifier.
                if !lexer.hasLineTerminatorBeforeToken && matchSpecIdentifier(&facade) {
                    declarationType = .awaitUsing
                }
            }
            restoreSavePoint(&context, savePoint, &facade)
            if declarationType == .awaitUsing {
                withScope(currentFunctionScope()) { $0.setUsesAwait() }
            }
        }
        var isLetIdentifier = false
        if match(.letKeyword) {
            declarationType = .let
            let lexerState = internalSaveLexerState()
            next([], &facade)
            if !strictMode && !matchIdentifierOrPossiblyEscapedContextualKeyword(&facade) && !match(.openBrace) && !match(.openBracket) {
                restoreLexerState(lexerState, &facade)
                declarationType = nil
                isLetIdentifier = true
            }
        }
        let isAnyUsingDeclaration = declarationType?.isUsing ?? false
        let isLexicalDeclaration = declarationType != nil && declarationType != .var
        var forLoopConstDoesNotHaveInitializer = false
        var forLoopInitializerContainsClosure = false

        var lexicalScope: ScopeRef? = nil
        defer {
            if let scope = lexicalScope {
                popScope(scope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
            }
        }

        var forHeader: ForHeader?

        if let declarationType {
            // for (var/let/const/using IDENT in/of expression) statement
            // for (var/let/const varDeclarationList; expressionOpt; expressionOpt)
            if isLexicalDeclaration {
                let newScope = pushScope(&facade)
                lexicalScope = newScope
                withScope(newScope) {
                    $0.setIsLexicalScope()
                    $0.preventVarDeclarations()
                }
            }

            var forInTarget = B.DestructuringPattern.null
            var forInInitializer = B.Expression.null
            allowsIn = false
            var initStart = JSC.JSTextPosition()
            var initEnd = JSC.JSTextPosition()
            let candidatesScope = current
            let candidateCountBeforeInitializer = facade.nameSetSize(scopes[topScope].storage, .ClosedVariableCandidates)
            var output = VariableDeclarationListOutput<B>(identStart: declsStart)
            decls = parseVariableDeclarationList(
                &context,
                &output,
                .forLoop,
                declarationType,
                .notExported,
                isLetKeywordConsumed: declarationType == .let,
                &facade
            )
            declarations = output.declarations
            forInTarget = output.lastPattern
            forInInitializer = output.lastInitializer
            declsStart = output.identStart
            initStart = output.initStart
            initEnd = output.initEnd
            forLoopConstDoesNotHaveInitializer = output.forLoopConstDoesNotHaveInitializer
            forLoopInitializerContainsClosure =
                facade.nameSetSize(withScope(candidatesScope) { $0.storage }, .ClosedVariableCandidates) > candidateCountBeforeInitializer
            allowsIn = true
            if hasError {
                return .null
            }

            // Remainder of a standard for loop is handled identically
            guard match(.semicolon) else {
                if declarations != 1 {
                    return fail("can only declare a single variable in an enumeration")
                }

                // Handle for-in with var declaration
                let inLocation = tokenStartPosition
                var isOfEnumeration = false
                if !match(.inKeyword) {
                    if !matchContextualKeyword(.of, &facade) {
                        return fail("Expected either 'in' or 'of' in enumeration syntax")
                    }
                    isOfEnumeration = true
                    next([], &facade)
                } else {
                    if isAnyUsingDeclaration {
                        return fail("Cannot use 'using' declaration in for-in loop")
                    }
                    if isAwaitFor {
                        return fail("Expected 'of' in for-await syntax")
                    }
                    next([], &facade)
                }

                let hasAnyAssignments = !forInInitializer.isNull
                if hasAnyAssignments {
                    if isOfEnumeration {
                        return semanticFail("Cannot assign to the loop variable inside a for-of loop header")
                    }
                    if strictMode || (declarationType == .let || declarationType == .const)
                        || !context.isBindingNode(&facade, forInTarget)
                    {
                        return semanticFail("Cannot assign to the loop variable inside a for-in loop header")
                    }
                }

                // While for-in uses Expression, for-of / for-await-of use AssignmentExpression.
                // https://tc39.es/ecma262/#sec-for-in-and-for-of-statements
                let expr: B.Expression
                if isOfEnumeration {
                    expr = parseAssignmentExpression(&context, &facade)
                } else {
                    expr = parseExpression(&context, &facade)
                }
                if expr.isNull {
                    return fail("Expected expression to enumerate")
                }
                recordPauseLocation(context.breakpointLocation(&facade, expr), &facade)
                let exprEnd = lastTokenEndPosition

                if !handleProductionOrFail(.closeParen, ")", "end", isOfEnumeration ? "a for-of header" : "a for-in header", &facade) {
                    return .null
                }

                let statement = parseLoopBody(&context, &facade)
                if statement.isNull {
                    return fail(ErrorMessage.text("Expected statement as body of for-" + (isOfEnumeration ? "of" : "in") + " statement"))
                }
                let lexicalVariables = popForLoopLexicalScope(&context, &lexicalScope, &facade)
                if isOfEnumeration {
                    return context.createForOfLoopWithDestructuringPattern(
                        &facade,
                        isAwaitFor,
                        location,
                        forInTarget,
                        expr,
                        statement,
                        declLocation,
                        declsStart,
                        inLocation,
                        exprEnd,
                        lexicalVariables
                    )
                }
                assert(!isAwaitFor)
                if declarationType == .var && !forInInitializer.isNull {
                    return context.createForInLoop(
                        &facade,
                        location,
                        decls,
                        expr,
                        statement,
                        declLocation,
                        declsStart,
                        inLocation,
                        exprEnd,
                        lexicalVariables
                    )
                }
                return context.createForInLoopWithDestructuringPattern(
                    &facade,
                    location,
                    forInTarget,
                    expr,
                    statement,
                    declLocation,
                    declsStart,
                    inLocation,
                    exprEnd,
                    lexicalVariables
                )
            }
            forHeader = .standard
        }

        if forHeader == nil {
            if !match(.semicolon) {
                if match(.openBrace) || match(.openBracket) {
                    let savePoint = createSavePoint(&context, &facade)
                    pattern = tryParseDestructuringPatternExpression(&context, .AssignmentExpression, &facade)
                    if !pattern.isNull && (match(.inKeyword) || matchContextualKeyword(.of, &facade)) {
                        forHeader = .enumeration
                    } else {
                        pattern = .null
                        restoreSavePoint(&context, savePoint, &facade)
                    }
                }
                if forHeader == nil {
                    allowsIn = false
                    if isAsyncOf && isAwaitFor {
                        next([], &facade)
                        decls = createResolveAndUseVariable(
                            &context,
                            facade.wellKnownIdentifier(.async),
                            isEval: false,
                            declsStart,
                            declLocation,
                            &facade
                        )
                    } else {
                        decls = parseExpression(&context, &facade)
                    }
                    allowsIn = true
                    if decls.isNull {
                        return fail("Cannot parse for loop declarations")
                    }
                    recordPauseLocation(context.breakpointLocation(&facade, decls), &facade)
                }
            }
        }

        if forHeader == .standard || (forHeader == nil && match(.semicolon)) {
            if isAwaitFor {
                return fail("Unexpected a ';' in for-await-of header")
            }
            // Standard for loop
            if !decls.isNull {
                recordPauseLocation(context.breakpointLocation(&facade, decls), &facade)
            }
            next([], &facade)
            var condition = B.Expression.null
            if forLoopConstDoesNotHaveInitializer && declarationType == .const {
                return fail("const variables in for loops must have initializers")
            }
            if forLoopConstDoesNotHaveInitializer && isAnyUsingDeclaration {
                return fail("'using' declaration requires an initializer")
            }

            if !match(.semicolon) {
                condition = parseExpression(&context, &facade)
                if condition.isNull {
                    return fail("Cannot parse for loop condition expression")
                }
                recordPauseLocation(context.breakpointLocation(&facade, condition), &facade)
            }
            if !consumeOrFail(.semicolon, "Expected a ';' after the for loop condition expression", &facade) {
                return .null
            }

            var increment = B.Expression.null
            if !match(.closeParen) {
                increment = parseExpression(&context, &facade)
                if increment.isNull {
                    return fail("Cannot parse for loop iteration expression")
                }
                recordPauseLocation(context.breakpointLocation(&facade, increment), &facade)
            }
            if !handleProductionOrFail(.closeParen, ")", "end", "a for-loop header", &facade) {
                return .null
            }
            let statement = parseLoopBody(&context, &facade)
            if statement.isNull {
                return fail("Expected a statement as the body of a for loop")
            }
            let lexicalVariables = popForLoopLexicalScope(&context, &lexicalScope, &facade)
            return context.createForLoop(
                &facade,
                location,
                decls,
                condition,
                increment,
                statement,
                lexicalVariables,
                forLoopInitializerContainsClosure
            )
        }

        // For-in and For-of loop
        if nonLHSCount != parserState.nonLHSCount {
            return fail("Expected a reference on the left hand side of an enumeration statement")
        }
        var isOfEnumeration = false
        let inLocation = tokenStartPosition
        if !match(.inKeyword) {
            if !matchContextualKeyword(.of, &facade) {
                return fail("Expected either 'in' or 'of' in enumeration syntax")
            }
            if isLetIdentifier {
                return fail("The left hand side of a for-of statement cannot start with 'let'")
            }
            if isAsyncOf && !isAwaitFor {
                return fail("The left hand side of a for-of statement cannot be 'async'")
            }
            isOfEnumeration = true
            next([], &facade)
        } else {
            if isAwaitFor {
                return fail("Expected 'of' in for-await syntax")
            }
            next([], &facade)
        }

        // While for-in uses Expression, for-of / for-await-of use AssignmentExpression.
        // https://tc39.es/ecma262/#sec-for-in-and-for-of-statements
        let expr: B.Expression
        if isOfEnumeration {
            expr = parseAssignmentExpression(&context, &facade)
        } else {
            expr = parseExpression(&context, &facade)
        }
        if expr.isNull {
            return fail(ErrorMessage.text("Cannot parse subject for-" + (isOfEnumeration ? "of" : "in") + " statement"))
        }
        recordPauseLocation(context.breakpointLocation(&facade, expr), &facade)
        let exprEnd = lastTokenEndPosition

        if !handleProductionOrFail(.closeParen, ")", "end", isOfEnumeration ? "a for-of header" : "a for-in header", &facade) {
            return .null
        }
        let statement = parseLoopBody(&context, &facade)
        if statement.isNull {
            return fail(ErrorMessage.text("Expected a statement as the body of a for-" + (isOfEnumeration ? "of" : "in") + " loop"))
        }
        if !pattern.isNull {
            assert(decls.isNull)
            let lexicalVariables = popForLoopLexicalScope(&context, &lexicalScope, &facade)
            if isOfEnumeration {
                return context.createForOfLoopWithDestructuringPattern(
                    &facade,
                    isAwaitFor,
                    location,
                    pattern,
                    expr,
                    statement,
                    declLocation,
                    declsStart,
                    inLocation,
                    exprEnd,
                    lexicalVariables
                )
            }
            assert(!isAwaitFor)
            return context.createForInLoopWithDestructuringPattern(
                &facade,
                location,
                pattern,
                expr,
                statement,
                declLocation,
                declsStart,
                inLocation,
                exprEnd,
                lexicalVariables
            )
        }

        if !isSimpleAssignmentTarget(&context, decls, ignoringStrictCheck: false, &facade) {
            return semanticFail("Left side of assignment is not a reference")
        }

        let lexicalVariables = popForLoopLexicalScope(&context, &lexicalScope, &facade)
        if isOfEnumeration {
            return context.createForOfLoop(
                &facade,
                isAwaitFor,
                location,
                decls,
                expr,
                statement,
                declLocation,
                declsStart,
                inLocation,
                exprEnd,
                lexicalVariables
            )
        }
        assert(!isAwaitFor)
        return context.createForInLoop(
            &facade,
            location,
            decls,
            expr,
            statement,
            declLocation,
            declsStart,
            inLocation,
            exprEnd,
            lexicalVariables
        )
    }
}
