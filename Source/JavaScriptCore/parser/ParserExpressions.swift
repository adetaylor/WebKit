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

extension JSC.JSTokenType {
    var isUnaryOpExcludingUpdateOp: Bool {
        if isUpdateOp {
            return false
        }
        return isUnaryOp
    }

    /// The assignment operator this token stands for, or nil when it is not one.
    var assignmentOperator: JSC.Operator? {
        switch self {
        case .equal: return .Equal
        case .plusEqual: return .PlusEq
        case .minusEqual: return .MinusEq
        case .multEqual: return .MultEq
        case .divEqual: return .DivEq
        case .lShiftEqual: return .LShift
        case .rShiftEqual: return .RShift
        case .urShiftEqual: return .URShift
        case .bitAndEqual: return .BitAndEq
        case .bitXorEqual: return .BitXOrEq
        case .bitOrEqual: return .BitOrEq
        case .modEqual: return .ModEq
        case .powEqual: return .PowEq
        case .coalesceEqual: return .CoalesceEq
        case .orEqual: return .OrEq
        case .andEqual: return .AndEq
        default: return nil
        }
    }
}

extension Parser {
    // MARK: Source elements

    mutating func isArrowFunctionParameters<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> Bool {
        if match(.openParen) {
            let saveArrowFunctionPoint = createSavePoint(&context, &facade)
            next([], &facade)
            var isArrowFunction = false
            if consume(.closeParen, [], &facade) {
                isArrowFunction = match(.arrowFunction)
            } else {
                var syntaxChecker = SyntaxChecker()
                // We make fake scope, otherwise parseFormalParameters will add variable to current scope that lead to errors
                let fakeScope = pushScope(&facade)

                withScope(fakeScope) { $0.setSourceParseMode(.ArrowFunctionMode) }
                resetImplementationVisibilityIfNeeded()

                var parametersCount: UInt32 = 0
                let list = syntaxChecker.createFormalParameterList(&facade)
                isArrowFunction =
                    parseFormalParameters(&syntaxChecker, list, isArrowFunction: true, isMethod: false, &parametersCount, &facade)
                    && consume(.closeParen, [], &facade) && match(.arrowFunction)
                if hasError {
                    popScope(fakeScope, shouldTrackClosedVariables: false, takeContainers: false, &facade)
                    return false
                }
                popScope(fakeScope, shouldTrackClosedVariables: SyntaxChecker.needsFreeVariableInfo, takeContainers: false, &facade)
            }
            restoreSavePoint(&context, saveArrowFunctionPoint, &facade)
            return isArrowFunction
        }

        if matchSpecIdentifier(&facade) {
            if isDisallowedIdentifierAwait(token, &facade) {
                logSemanticError(.text("Cannot use 'await' as a parameter name \(disallowedIdentifierAwaitReason())"))
                return false
            }
            let saveArrowFunctionPoint = createSavePoint(&context, &facade)
            next([], &facade)
            let isArrowFunction = match(.arrowFunction)
            restoreSavePoint(&context, saveArrowFunctionPoint, &facade)
            return isArrowFunction
        }

        return false
    }

    mutating func parseExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }
        let headLocation = tokenLocation
        let node = parseAssignmentExpression(&context, &facade)
        if node.isNull {
            return fail("Cannot parse expression")
        }
        context.setEndOffset(&facade, node, Int32(bitPattern: lastTokenLocation.endOffset))
        if !match(.comma) {
            return node
        }
        recordPauseLocation(context.breakpointLocation(&facade, node), &facade)
        next([], &facade)
        parserState.nonTrivialExpressionCount &+= 1
        parserState.nonLHSCount &+= 1
        var tailLocation = tokenLocation
        var right = parseAssignmentExpression(&context, &facade)
        if right.isNull {
            return fail("Cannot parse expression in a comma expression")
        }
        recordPauseLocation(context.breakpointLocation(&facade, right), &facade)
        context.setEndOffset(&facade, right, Int32(bitPattern: lastTokenLocation.endOffset))
        let head = context.createCommaExpr(&facade, headLocation, node)
        var tail = context.appendToCommaExpr(&facade, tailLocation, head, right)
        while match(.comma) {
            next(B.dontBuildStrings, &facade)
            tailLocation = tokenLocation
            right = parseAssignmentExpression(&context, &facade)
            if right.isNull {
                return fail("Cannot parse expression in a comma expression")
            }
            context.setEndOffset(&facade, right, Int32(bitPattern: lastTokenLocation.endOffset))
            recordPauseLocation(context.breakpointLocation(&facade, right), &facade)
            tail = context.appendToCommaExpr(&facade, tailLocation, tail, right)
        }
        context.setEndOffset(&facade, head, Int32(bitPattern: lastTokenLocation.endOffset))
        return head
    }

    func metaPropertyName<B: TreeBuilder>(
        _ context: inout B,
        _ expr: B.Expression,
        _ facade: inout JSC.JSParseFacade
    ) -> Swift.String {
        if context.isNewTarget(&facade, expr) {
            return "new.target"
        }
        if context.isImportMeta(&facade, expr) {
            return "import.meta"
        }
        fatalError("metaPropertyName: not new.target or import.meta")
    }

    mutating func isSimpleAssignmentTarget<B: TreeBuilder>(
        _ context: inout B,
        _ expr: B.Expression,
        ignoringStrictCheck ignoreStrictCheck: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        // Web compatibility concerns prevent us from handling a function call LHS as an early error in sloppy mode.
        // See https://github.com/tc39/ecma262/pull/3568 for details.
        context.isLocation(&facade, expr) || (!(strictMode || ignoreStrictCheck) && context.isFunctionCall(&facade, expr))
    }

    mutating func parseDestructuringAssignment<B: TreeBuilder>(
        _ context: inout B,
        _ savePoint: SavePoint,
        _ location: JSC.JSTokenLocation,
        _ isPossiblePattern: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        let expressionErrorLocation = swapSavePointForError(&context, savePoint, &facade)
        let pattern = tryParseDestructuringPatternExpression(&context, .AssignmentExpression, &facade)

        // The reason why we use restoreSavePointWithError only when isPossiblePattern = true is that
        // this can produce better error message.
        if isPossiblePattern && (pattern.isNull || !match(.equal)) {
            restoreSavePointWithError(&context, expressionErrorLocation, &facade)
            if hasError {
                return .null
            }
        }
        if pattern.isNull {
            return fail("Cannot parse assignment pattern")
        }
        if !consumeOrFail(.equal, "Expected '=' following assignment pattern", &facade) {
            return .null
        }
        let rhs = parseAssignmentExpression(&context, &facade)
        if rhs.isNull && hasError {
            return .null
        }
        return context.createDestructuringAssignment(&facade, location, pattern, rhs)
    }

    mutating func parseArrowFunctionCandidate<B: TreeBuilder>(
        _ context: inout B,
        _ savePoint: SavePoint,
        _ location: JSC.JSTokenLocation,
        _ isArrowFunctionToken: Bool,
        _ wasOpenParen: Bool,
        _ usedVariablesSize: UInt32,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression? {
        let errorRestorationSavePoint = swapSavePointForError(&context, savePoint, &facade)
        var isAsync = false
        if matchContextualKeyword(.async, &facade) {
            next([], &facade)
            if !lexer.hasLineTerminatorBeforeToken && (match(.openParen) || matchSpecIdentifier(&facade)) {
                isAsync = true
            } else {
                // This is async => ... case. So this "async" is not a contextual keyword, it is parameter name.
                restoreSavePoint(&context, savePoint, &facade)
            }
        }

        if isArrowFunctionParameters(&context, &facade) {
            if wasOpenParen {
                scopes[topScope].revertToPreviousUsedVariables(usedVariablesSize, &facade)
            }
            return parseArrowFunctionExpression(&context, isAsync, location, &facade)
        }

        // The reason why we use propagateError only when isArrowFunctionToken = true is that
        // this can produce better error message than restoring it to errorRestorationSavePoint.
        if isArrowFunctionToken && hasError {
            return .null
        }

        restoreSavePointWithError(&context, errorRestorationSavePoint, &facade)
        if isArrowFunctionToken {
            return failDueToUnexpectedToken()
        }
        return nil
    }

    mutating func parseAssignmentExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        assert(!hasError)

        guard canRecurse(&facade) else {
            return failForStackOverflow()
        }

        if match(.yieldKeyword) && !canUseIdentifierYield {
            return parseYieldExpression(&context, &facade)
        }

        var start = tokenStartPosition
        let location = tokenLocation
        let initialAssignmentCount = parserState.assignmentCount
        let initialNonLHSCount = parserState.nonLHSCount
        let maybeAssignmentPattern = match(.openBrace) || match(.openBracket)
        let wasOpenParen = match(.openParen)
        // Do not use matchSpecIdentifier() here since it is slower than isIdentifierOrKeyword.
        // Whether spec identifier is will be validated by isArrowFunctionParameters().
        let wasIdentifierOrKeyword = matchIdentifierOrKeyword() || token.type == .escapedKeyword
        let maybeValidArrowFunctionStart = wasOpenParen || wasIdentifierOrKeyword
        var savePoint: SavePoint?
        if maybeValidArrowFunctionStart || maybeAssignmentPattern {
            savePoint = createSavePoint(&context, &facade)
        }
        var usedVariablesSize: UInt32 = 0

        if wasOpenParen {
            usedVariablesSize = pushParenthesesUsedVariableSet(&facade)
        }
        // Unless the parentheses turn out to be arrow function parameters, the uses inside them belong
        // to this scope. Fold their set back so the number of sets stays bounded by nesting depth.
        defer {
            if wasOpenParen {
                mergeParenthesesUsedVariableSet(usedVariablesSize, &facade)
            }
        }

        var lhs = parseConditionalExpression(&context, &facade)

        // Current implementation of parseAssignmentExpression causes a weird parsing loop
        // for this example:
        //
        //      class C {
        //          static {
        //              ((x = await) => 0);
        //          }
        //      }
        //
        // which makes the 'await' error caught in parseConditionalExpression escaping from
        // parseAssignmentExpression. Therefore, we need to capture the error directly after
        // parseConditionalExpression. Besides, the usage of `await` is strictly limited in
        // class static block.
        if lhs.isNull && scopes[topScope].isStaticBlock && match(.awaitKeyword) && hasError {
            return .null
        }

        if maybeValidArrowFunctionStart && !match(.eof) {
            let isArrowFunctionToken = match(.arrowFunction)
            if lhs.isNull || isArrowFunctionToken {
                if let savePoint,
                    let result = parseArrowFunctionCandidate(
                        &context,
                        savePoint,
                        location,
                        isArrowFunctionToken,
                        wasOpenParen,
                        usedVariablesSize,
                        &facade
                    )
                {
                    return result
                }
            }
        }

        if lhs.isNull && !maybeAssignmentPattern && hasError {
            return .null
        }

        if maybeAssignmentPattern && (lhs.isNull || (match(.equal) && context.isObjectOrArrayLiteral(&facade, lhs))) {
            if let savePoint {
                return parseDestructuringAssignment(&context, savePoint, location, lhs.isNull, &facade)
            }
        }

        if lhs.isNull {
            return fail("Cannot parse expression")
        }
        if initialNonLHSCount != parserState.nonLHSCount {
            if token.type.isAssignmentOperator {
                return failLeftHandSideMustBeReference()
            }
            return lhs
        }

        var assignmentStack: Int32 = 0
        var hadAssignment = false
        while let op = token.type.assignmentOperator {
            parserState.nonTrivialExpressionCount &+= 1
            hadAssignment = true
            if context.isMetaProperty(&facade, lhs) {
                return failMetaPropertyAssignment(&context, lhs, &facade)
            }
            // Even if in sloppy mode, we should throw a syntax error for logical assignment expressions that are not simple.
            // https://tc39.es/ecma262/#sec-assignment-operators-static-semantics-early-errors
            let isLogical = op == .CoalesceEq || op == .OrEq || op == .AndEq
            if !isSimpleAssignmentTarget(&context, lhs, ignoringStrictCheck: isLogical, &facade) {
                return semanticFail("Left side of assignment is not a reference")
            }
            context.assignmentStackAppend(&facade, &assignmentStack, lhs, start, tokenStartPosition, parserState.assignmentCount, op)
            start = tokenStartPosition
            parserState.assignmentCount &+= 1
            next(B.dontBuildStrings, &facade)
            if strictMode && !parserState.lastIdentifier.isNull && context.isResolve(&facade, lhs) {
                let lastIdentifier = parserState.lastIdentifier
                if lastIdentifier.matches(.eval, &facade) {
                    return semanticFail("Cannot modify 'eval' in strict mode")
                }
                if lastIdentifier.matches(.arguments, &facade) {
                    return semanticFail("Cannot modify 'arguments' in strict mode")
                }
                parserState.lastIdentifier = JSC.JSParseIdentifier()
            }
            lhs = parseAssignmentExpression(&context, &facade)
            if lhs.isNull {
                return fail("Cannot parse the right hand side of an assignment expression")
            }
            if initialNonLHSCount != parserState.nonLHSCount {
                if token.type.isAssignmentOperator {
                    return failLeftHandSideMustBeReference()
                }
                break
            }
        }

        if hadAssignment {
            parserState.nonLHSCount &+= 1
        }

        while assignmentStack != 0 {
            lhs = context.createAssignment(
                &facade,
                location,
                &assignmentStack,
                lhs,
                initialAssignmentCount,
                parserState.assignmentCount,
                lastTokenEndPosition
            )
        }

        return lhs
    }

    /// The uses inside parentheses go to a set of their own until it is known whether they are arrow function parameters.
    @inline(never)
    private mutating func pushParenthesesUsedVariableSet(_ facade: inout JSC.JSParseFacade) -> UInt32 {
        let size = scopes[topScope].currentUsedVariablesSize(&facade)
        scopes[topScope].pushUsedVariableSet(&facade)
        return size
    }

    @inline(never)
    private mutating func mergeParenthesesUsedVariableSet(_ size: UInt32, _ facade: inout JSC.JSParseFacade) {
        scopes[topScope].mergeIntoPreviousUsedVariables(size, &facade)
    }

    /// The error paths of parseAssignmentExpression, out of line so that the message is not built in its frame.
    @inline(never)
    private mutating func failLeftHandSideMustBeReference<Result: TreeHandle>() -> Result {
        semanticFail(ErrorMessage(.text("Left hand side of operator '"), tokenSourceText, .text("' must be a reference")))
    }

    @inline(never)
    private mutating func failMetaPropertyAssignment<B: TreeBuilder>(
        _ context: inout B,
        _ lhs: B.Expression,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        semanticFail(
            ErrorMessage(
                .text(metaPropertyName(&context, lhs, &facade)),
                .text(" can't be the left hand side of an assignment expression")
            )
        )
    }

    /// The current token's source text, for error messages.
    private var tokenSourceText: ErrorMessagePart {
        .source(start: Int(token.startPosition.offset), end: Int(token.endPosition.offset))
    }

    mutating func parseYieldExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        // YieldExpression[In] :
        //     yield
        //     yield [no LineTerminator here] AssignmentExpression[?In, Yield]
        //     yield [no LineTerminator here] * AssignmentExpression[?In, Yield]
        assert(match(.yieldKeyword))
        if !(scopes[topScope].isGeneratorFunction && !scopes[topScope].isArrowFunctionBoundary) {
            return fail("Cannot use yield expression out of generator")
        }
        if parserState.functionParsePhase == .parameters {
            return fail("Cannot use yield expression within parameters")
        }
        if parserState.isParsingClassFieldInitializer {
            return fail("Cannot use yield expression inside class field initializer expression")
        }

        let location = tokenLocation
        let divotStart = tokenStartPosition
        let savePoint = createSavePoint(&context, &facade)
        next([], &facade)
        if lexer.hasLineTerminatorBeforeToken {
            return context.createYield(&facade, location)
        }

        let delegate = consume(.times, [], &facade)
        let argumentStart = tokenStartPosition
        let argument = parseAssignmentExpression(&context, &facade)
        if argument.isNull {
            restoreSavePoint(&context, savePoint, &facade)
            next([], &facade)
            return context.createYield(&facade, location)
        }
        return context.createYield(&facade, location, argument, delegate, divotStart, argumentStart, lastTokenEndPosition)
    }

    mutating func parseAwaitExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        assert(match(.awaitKeyword))
        assert(scopes[topScope].isAsyncFunction || isModuleParseMode)
        assert(JSC.isAsyncFunctionParseMode(parseMode) || isModuleParseMode)
        assert(parserState.functionParsePhase != .parameters)
        assert(!parserState.classFieldInitMasksAsync)
        let location = tokenLocation
        let divotStart = tokenStartPosition
        next([], &facade)
        let argumentStart = tokenStartPosition
        let argument = parseUnaryExpressionOutOfLine(&context, &facade)
        if argument.isNull {
            return fail("Failed to parse await expression")
        }
        if match(.pow) {
            return fail(
                "Ambiguous unary expression in the left hand side of the exponentiation expression; parentheses must be used to disambiguate the expression"
            )
        }
        withScope(currentFunctionScope()) { $0.setUsesAwait() }
        return context.createAwait(&facade, location, argument, divotStart, argumentStart, lastTokenEndPosition)
    }

    mutating func parseConditionalExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        let location = tokenLocation
        let cond = parseBinaryExpression(&context, &facade)
        if cond.isNull {
            return fail("Cannot parse expression")
        }
        if !match(.question) {
            return cond
        }
        parserState.nonTrivialExpressionCount &+= 1
        parserState.nonLHSCount &+= 1
        next(B.dontBuildStrings, &facade)
        let lhs: B.Expression
        do {
            // this block is necessary so that we don't leave `in` enabled for the rhs
            let savedAllowsIn = allowsIn
            allowsIn = true
            defer { allowsIn = savedAllowsIn }
            lhs = parseAssignmentExpression(&context, &facade)
        }
        if lhs.isNull {
            return fail("Cannot parse left hand side of ternary operator")
        }
        context.setEndOffset(&facade, lhs, Int32(truncatingIfNeeded: lastTokenLocation.endOffset))
        if !consume(.colon, B.dontBuildStrings, &facade) {
            return fail("Expected ':' in ternary operator")
        }

        let rhs = parseAssignmentExpression(&context, &facade)
        if rhs.isNull {
            return fail("Cannot parse right hand side of ternary operator")
        }
        context.setEndOffset(&facade, rhs, Int32(truncatingIfNeeded: lastTokenLocation.endOffset))
        return context.createConditionalExpr(&facade, location, cond, lhs, rhs)
    }

    func binaryOperatorPrecedence(_ token: JSC.JSTokenType) -> Int32 {
        if allowsIn {
            return Int32(
                token.rawValue
                    & (JSC.JSTokenType.binaryOpPrecedenceMask << JSC.JSTokenType.binaryOpAllowsInPrecedenceAdditionalShift)
            )
        }
        return Int32(token.rawValue & JSC.JSTokenType.binaryOpPrecedenceMask)
    }

    mutating func parseBinaryExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        var operandStackDepth: Int32 = 0
        var operatorStackDepth: Int32 = 0
        let savedBinaryExpression = context.enterBinaryExpression()
        defer { context.leaveBinaryExpression(savedBinaryExpression) }
        let location = tokenLocation
        var hasLogicalOperator = false
        var hasCoalesceOperator = false

        var previousOperator: UInt32 = 0
        while true {
            let exprStart = tokenStartPosition
            let initialAssignments = parserState.assignmentCount
            let leadingTokenTypeForUnaryExpression = token.type

            let current: B.Expression
            if match(.privateName) {
                let ident = token.data.ident
                scopes[topScope].usePrivateName(ident, &facade)
                seenPrivateNameUse = true
                next([], &facade)
                if token.type != .inKeyword || previousOperator >= JSC.JSTokenType.inKeyword.rawValue {
                    return semanticFail("Bare private name can only be used as the left-hand side of an `in` expression")
                }
                current = context.createPrivateIdentifierNode(&facade, location, ident)
            } else {
                current = parseUnaryExpression(&context, &facade)
            }
            if current.isNull {
                return fail("Cannot parse expression")
            }

            context.appendBinaryExpressionInfo(
                &facade,
                &operandStackDepth,
                current,
                exprStart,
                lastTokenEndPosition,
                lastTokenEndPosition,
                initialAssignments != parserState.assignmentCount
            )
            let precedence = binaryOperatorPrecedence(token.type)
            if precedence == 0 {
                break
            }

            // 12.6 https://tc39.github.io/ecma262/#sec-exp-operator
            // ExponentiationExpresion is described as follows.
            //
            //     ExponentiationExpression[Yield]:
            //         UnaryExpression[?Yield]
            //         UpdateExpression[?Yield] ** ExponentiationExpression[?Yield]
            //
            // As we can see, the left hand side of the ExponentiationExpression is UpdateExpression, not UnaryExpression.
            // So placing UnaryExpression not included in UpdateExpression here is a syntax error.
            // This is intentional. For example, if UnaryExpression is allowed, we can have the code like `-x**y`.
            // But this is confusing: `-(x**y)` OR `(-x)**y`, which interpretation is correct?
            // To avoid this problem, ECMA262 makes unparenthesized exponentiation expression as operand of unary operators an early error.
            // More rationale: https://mail.mozilla.org/pipermail/es-discuss/2015-September/044232.html
            //
            // Here, we guarantee that the left hand side of this expression is not unary expression by checking the leading operator of the parseUnaryExpression.
            // This check just works. Let's consider the example,
            //     y <> -x ** z
            //          ^
            //          Check this.
            // If the binary operator <> has higher precedence than one of "**", this check does not work.
            // But it's OK for ** because the operator "**" has the highest operator precedence in the binary operators.
            if match(.pow) && leadingTokenTypeForUnaryExpression.isUnaryOpExcludingUpdateOp {
                return fail(
                    "Ambiguous unary expression in the left hand side of the exponentiation expression; parentheses must be used to disambiguate the expression"
                )
            }

            // Mixing ?? with || or && is currently specified as an early error.
            // Since ?? is the lowest-precedence binary operator, it suffices to check whether these ever coexist in the operator stack.
            if match(.and) || match(.or) {
                hasLogicalOperator = true
            } else if match(.coalesce) {
                hasCoalesceOperator = true
            }
            if hasLogicalOperator && hasCoalesceOperator {
                return fail(
                    "Coalescing and logical operators used together in the same expression; parentheses must be used to disambiguate"
                )
            }

            parserState.nonTrivialExpressionCount &+= 1
            parserState.nonLHSCount &+= 1
            let operatorToken = token.type.rawValue
            next(B.dontBuildStrings, &facade)

            while operatorStackDepth != 0 && context.operatorStackShouldReduce(&facade, precedence) {
                assert(operandStackDepth > 1)
                let rhs = context.getFromOperandStack(&facade, -1)
                let lhs = context.getFromOperandStack(&facade, -2)
                context.shrinkOperandStackBy(&facade, &operandStackDepth, 2)
                context.appendBinaryOperation(&facade, location, &operandStackDepth, &operatorStackDepth, lhs, rhs)
                context.operatorStackPop(&facade, &operatorStackDepth)
            }
            context.operatorStackAppend(&facade, &operatorStackDepth, Int32(bitPattern: operatorToken), precedence)
            previousOperator = operatorToken
        }
        while operatorStackDepth != 0 {
            assert(operandStackDepth > 1)
            let rhs = context.getFromOperandStack(&facade, -1)
            let lhs = context.getFromOperandStack(&facade, -2)
            context.shrinkOperandStackBy(&facade, &operandStackDepth, 2)
            context.appendBinaryOperation(&facade, location, &operandStackDepth, &operatorStackDepth, lhs, rhs)
            context.operatorStackPop(&facade, &operatorStackDepth)
        }
        return context.popOperandStack(&facade, &operandStackDepth)
    }
}
