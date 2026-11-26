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
    func operatorName(isPrefix: Bool) -> Swift.String {
        switch self {
        case .minusMinus, .autoMinusMinus:
            return isPrefix ? "prefix-decrement" : "decrement"
        case .plusPlus, .autoPlusPlus:
            return isPrefix ? "prefix-increment" : "increment"
        case .exclamation:
            return "logical-not"
        case .tilde:
            return "bitwise-not"
        case .typeofKeyword:
            return "typeof"
        case .voidKeyword:
            return "void"
        case .deleteKeyword:
            return "delete"
        default:
            preconditionFailure("not reached")
        }
    }
}

extension JSC.JSTextPosition {
    func advanced(by adjustment: Int32) -> JSC.JSTextPosition {
        var result = self
        result.offset += adjustment
        return result
    }
}

extension Parser {
    // MARK: Call and apply depth

    /// The innermost call or apply level being parsed, if any (UniqueArray has no `last`).
    private var innermostCallOrApplyDepthScope: CallOrApplyDepthScope? {
        callOrApplyDepthScopes.isEmpty ? nil : callOrApplyDepthScopes[callOrApplyDepthScopes.count - 1]
    }

    /// Enters a call whose callee is .call or .apply, one level deeper than the enclosing one.
    private mutating func pushCallOrApplyDepthScope() {
        let depth: UInt16 = innermostCallOrApplyDepthScope.map { $0.depth + 1 } ?? 0
        callOrApplyDepthScopes.append(CallOrApplyDepthScope(depth: depth, depthOfInnermostChild: depth))
    }

    /// Leaves it; the enclosing level keeps the deepest level reached below it.
    private mutating func popCallOrApplyDepthScope() {
        let child = callOrApplyDepthScopes.removeLast()
        if !callOrApplyDepthScopes.isEmpty {
            let parent = callOrApplyDepthScopes.count - 1
            callOrApplyDepthScopes[parent].depthOfInnermostChild = max(
                child.depthOfInnermostChild,
                callOrApplyDepthScopes[parent].depthOfInnermostChild
            )
        }
    }

    // MARK: Member expression

    mutating func parseMemberExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        var base = B.Expression.null
        let expressionStart = tokenStartPosition
        let location = tokenLocation

        // No need to accumulate newTokenStartPositions if the builder is SyntaxChecker.
        // They are appended to the parser's newTokenStartPositions from newBase, so no array is made per call.
        let newBase = newTokenStartPositions.count
        defer {
            if B.createsAST && newTokenStartPositions.count > newBase {
                newTokenStartPositions.removeSubrange(newBase...)
            }
        }
        var newCount = 0
        while match(.newKeyword) {
            if B.createsAST {
                newTokenStartPositions.append(tokenStartPosition)
            }
            newCount += 1
            next([], &facade)
        }

        var baseIsSuper = match(.superKeyword)
        var previousBaseWasSuper = false
        let baseIsImport = match(.importKeyword)
        var baseIsAsyncKeyword = false

        if newCount > 0 && consume(.dot, [], &facade) {
            guard matchContextualKeyword(.target, &facade) else {
                if match(.identifier) {
                    return fail("\"new.\" can only be followed with target")
                }
                return failDueToUnexpectedToken()
            }
            let closestOrdinaryFunctionScope = closestParentOrdinaryFunctionNonLexicalScope()
            let isClassFieldInitializer = parserState.isParsingClassFieldInitializer
            let ordinaryEvalContextType = scopes[closestOrdinaryFunctionScope.index].evalContextType
            let isFunctionEvalContextType =
                isInsideOrdinaryFunction
                && (ordinaryEvalContextType == .FunctionEvalContext || ordinaryEvalContextType == .InstanceFieldEvalContext)
            if !(scopes[topScope].isFunction || scopes[topScope].isStaticBlock || isFunctionEvalContextType
                || isClassFieldInitializer)
            {
                return semanticFail("new.target is only valid inside functions or static blocks")
            }
            if scopes[topScope].isArrowFunction {
                if !(!scopes[closestOrdinaryFunctionScope.index].isGlobalCode || isFunctionEvalContextType || isClassFieldInitializer) {
                    return semanticFail("new.target is not valid inside arrow functions in global code")
                }
                scopes[topScope].setInnerArrowFunctionUsesNewTarget()
            }
            base = context.createNewTargetExpr(&facade, location)
            newCount -= 1
            next([], &facade)
        } else if baseIsSuper {
            let closestOrdinaryFunctionScope = closestParentOrdinaryFunctionNonLexicalScope()
            let classScope = closestClassScopeOrTopLevelScope()
            // Check if classScope is deeper than closestOrdinaryFunctionScope (i.e., we're in a class field initializer).
            let isClassFieldInitializer = closestOrdinaryFunctionScope.index < classScope.index
            if !(scopes[topScope].isFunction || isClassFieldInitializer
                || (scopes[closestOrdinaryFunctionScope.index].isEvalContext
                    && scopes[closestOrdinaryFunctionScope.index].expectedSuperBinding == .Needed))
            {
                return semanticFail("super is not valid in this context")
            }
            base = context.createSuperExpr(&facade, location)
            next([], &facade)
            if match(.openParen) && scopes[topScope].evalContextType == .InstanceFieldEvalContext {
                return fail("super call is not valid in this context")
            }
            let functionScope = currentFunctionScope()
            scopes[functionScope.index].setNeedsSuperBinding()
            // It unnecessary to check of using super during reparsing one more time. Also it can lead to syntax error
            // in case of arrow function because during reparsing we don't know whether we currently parse the arrow function
            // inside of the constructor or method.
            if !lexer.isReparsingFunction {
                let functionSuperBinding =
                    !scopes[functionScope.index].isArrowFunction && !scopes[closestOrdinaryFunctionScope.index].isEvalContext
                    ? scopes[functionScope.index].expectedSuperBinding
                    : scopes[closestOrdinaryFunctionScope.index].expectedSuperBinding
                if functionSuperBinding == .NotNeeded && !isClassFieldInitializer {
                    return semanticFail("super is not valid in this context")
                }
            }
        } else if baseIsImport {
            next([], &facade)
            var expressionEnd = lastTokenEndPosition
            var isImportMeta = false
            var deferred = false
            if consume(.dot, [], &facade) {
                if matchContextualKeyword(.meta, &facade) {
                    if scriptMode != .Module {
                        return semanticFail("import.meta is only valid inside modules")
                    }
                    let metaResolve = createResolveAndUseVariable(
                        &context,
                        facade.wellKnownIdentifier(.metaPrivateName),
                        isEval: false,
                        expressionStart,
                        location,
                        &facade
                    )
                    base = context.createImportMetaExpr(&facade, location, metaResolve)
                    scopes[topScope].setUsesImportMeta()
                    isImportMeta = true
                    next([], &facade)
                } else if modes.useImportDefer && matchContextualKeyword(.deferKeyword, &facade) {
                    // ImportCall : import . defer ImportCallArguments
                    // https://tc39.es/proposal-defer-import-eval/#sec-import-call-runtime-semantics-evaluation
                    deferred = true
                    next([], &facade)
                    expressionEnd = lastTokenEndPosition
                } else {
                    if match(.identifier) {
                        return fail(
                            modes.useImportDefer
                                ? "\"import.\" can only be followed with meta or defer" : "\"import.\" can only be followed with meta"
                        )
                    }
                    return failDueToUnexpectedToken()
                }
            }
            if !isImportMeta {
                if newCount != 0 {
                    return semanticFail("Cannot use new with import")
                }
                if !consume(.openParen, [], &facade) {
                    return fail("import call expects one or two arguments")
                }
                let savedNonLHSCount = parserState.nonLHSCount
                defer { parserState.nonLHSCount = savedNonLHSCount }
                let expr = parseAssignmentExpression(&context, &facade)
                if expr.isNull {
                    return fail("Cannot parse expression")
                }
                var optionExpression = B.Expression.null
                if consume(.comma, [], &facade) {
                    if !match(.closeParen) {
                        optionExpression = parseAssignmentExpression(&context, &facade)
                        if optionExpression.isNull {
                            return fail("Cannot parse expression")
                        }
                        _ = consume(.comma, [], &facade)
                    }
                }
                if !consume(.closeParen, [], &facade) {
                    return fail("import call expects one or two arguments")
                }
                base = context.createImportExpr(
                    &facade,
                    location,
                    expr,
                    optionExpression,
                    deferred,
                    expressionStart,
                    expressionEnd,
                    lastTokenEndPosition
                )
            }
        } else {
            let isAsync = matchContextualKeyword(.async, &facade)

            let argumentsDotLengthExpression = tryParseArgumentsDotLengthForFastPath(&context, &facade)
            if !argumentsDotLengthExpression.isNull {
                base = argumentsDotLengthExpression
            } else {
                base = parsePrimaryExpression(&context, &facade)
            }
            if base.isNull {
                return fail("Cannot parse base expression")
            }
            if isAsync && context.isResolve(&facade, base) && !lexer.hasLineTerminatorBeforeToken {
                baseIsAsyncKeyword = true
                if matchSpecIdentifier(&facade) {
                    return failDueToUnexpectedToken()
                }
            }
        }

        if base.isNull {
            return fail("Cannot parse base expression")
        }

        repeat {
            var optionalChainBase = B.Expression.null
            var optionalChainLocation = JSC.JSTokenLocation()
            var isOptionalCall = false
            var type = token.type

            if match(.questionDot) {
                if newCount != 0 {
                    return semanticFail("Cannot call constructor in an optional chain")
                }
                if baseIsSuper {
                    return semanticFail("Cannot use super as the base of an optional chain")
                }
                optionalChainBase = base
                optionalChainLocation = tokenLocation

                let savePoint = createSavePoint(&context, &facade)
                next([], &facade)
                if match(.openBracket) || match(.openParen) || match(.backQuote) {
                    type = token.type
                } else {
                    type = .dot
                    restoreSavePoint(&context, savePoint, &facade)
                }
            }

            chain: while true {
                switch type {
                case .openBracket:
                    parserState.nonTrivialExpressionCount &+= 1
                    let expressionDivot = tokenStartPosition
                    next([], &facade)
                    let savedNonLHSCount = parserState.nonLHSCount
                    defer { parserState.nonLHSCount = savedNonLHSCount }
                    let initialAssignments = parserState.assignmentCount
                    let property = parseExpression(&context, &facade)
                    if property.isNull {
                        return fail("Cannot parse subscript expression")
                    }
                    base = context.createBracketAccess(
                        &facade,
                        location,
                        base,
                        property,
                        initialAssignments != parserState.assignmentCount,
                        expressionStart,
                        expressionDivot,
                        tokenEndPosition
                    )

                    if baseIsSuper && scopes[topScope].isArrowFunction {
                        scopes[currentFunctionScope().index].setInnerArrowFunctionUsesSuperProperty()
                    }

                    if !consume(.closeBracket, [], &facade) {
                        return fail("Expected ']' to end a subscript expression")
                    }
                case .openParen:
                    if baseIsSuper {
                        if parserState.isParsingClassFieldInitializer {
                            return fail("super call is not valid in class field initializer context")
                        }
                    }
                    parserState.nonTrivialExpressionCount &+= 1
                    let savedNonLHSCount = parserState.nonLHSCount
                    defer { parserState.nonLHSCount = savedNonLHSCount }
                    if newCount != 0 {
                        newCount -= 1
                        if baseIsSuper {
                            return semanticFail("Cannot use new with super call")
                        }
                        let expressionEnd = lastTokenEndPosition
                        let arguments = parseArguments(&context, &facade)
                        if arguments.isNull {
                            return fail("Cannot parse call arguments")
                        }
                        base = context.createNewExpr(
                            &facade,
                            location,
                            base,
                            arguments,
                            expressionStart,
                            expressionEnd,
                            lastTokenEndPosition
                        )
                    } else {
                        let usedVariablesSize = scopes[topScope].currentUsedVariablesSize(&facade)
                        let expressionEnd = lastTokenEndPosition
                        // Only the AST builder tracks the depth.
                        var hasCallOrApplyDepthScope = false
                        if B.createsAST, let node = base.parseNode, facade.isCallOrApplyDotAccessor(node) {
                            pushCallOrApplyDepthScope()
                            hasCallOrApplyDepthScope = true
                        }
                        defer {
                            if hasCallOrApplyDepthScope {
                                popCallOrApplyDepthScope()
                            }
                        }

                        let arguments = parseArguments(&context, &facade)

                        if baseIsAsyncKeyword && (arguments.isNull || match(.arrowFunction)) {
                            scopes[topScope].revertToPreviousUsedVariables(usedVariablesSize, &facade)
                            return failDueToUnexpectedToken()
                        }

                        if arguments.isNull {
                            return fail("Cannot parse call arguments")
                        }
                        if baseIsSuper {
                            let functionScope = currentFunctionScope()
                            // It unnecessary to check of using super during reparsing one more time. Also it can lead to syntax error
                            // in case of arrow function because during reparsing we don't know whether we currently parse the arrow function
                            // inside of the constructor or method.
                            if !lexer.isReparsingFunction {
                                let closestOrdinaryFunctionScope = closestParentOrdinaryFunctionNonLexicalScope()
                                let ordinary = closestOrdinaryFunctionScope.index
                                if !(scopes[ordinary].constructorKind == .Extends
                                    || (scopes[ordinary].isEvalContext
                                        && scopes[ordinary].derivedContextType == .DerivedConstructorContext))
                                {
                                    return semanticFail("super is not valid in this context")
                                }
                            }
                            if scopes[topScope].isArrowFunction {
                                scopes[functionScope.index].setInnerArrowFunctionUsesSuperCall()
                            }
                        }

                        isOptionalCall = optionalChainLocation.endOffset == UInt32(truncatingIfNeeded: expressionEnd.offset)
                        let distanceToInnermostChild =
                            hasCallOrApplyDepthScope
                            ? Int(innermostCallOrApplyDepthScope?.distanceToInnermostChild ?? 0) : 0
                        base = context.makeFunctionCallNode(
                            &facade,
                            location,
                            base,
                            previousBaseWasSuper,
                            arguments,
                            expressionStart,
                            expressionEnd,
                            lastTokenEndPosition,
                            distanceToInnermostChild,
                            isOptionalCall
                        )
                    }
                case .dot:
                    parserState.nonTrivialExpressionCount &+= 1
                    let expressionDivot = tokenStartPosition
                    next(B.dontBuildKeywords.union(.ignoreReservedWords), &facade)
                    let ident = token.data.ident
                    var dotType = JSC.DotType.Name
                    if match(.privateName) {
                        if baseIsSuper {
                            return fail("Cannot access private names from super")
                        }
                        if scopes[topScope].evalContextType == .InstanceFieldEvalContext {
                            if !scopes[topScope].hasPrivateName(ident, &facade) {
                                return semanticFail(
                                    ErrorMessage(.text("Cannot reference undeclared private field '"), .identifier(ident), .text("'"))
                                )
                            }
                        }
                        scopes[topScope].usePrivateName(ident, &facade)
                        seenPrivateNameUse = true
                        parserState.lastPrivateName = ident
                        dotType = .PrivateMember
                        token.type = .identifier
                    }
                    if !match(.identifier) {
                        return fail(
                            ErrorMessage(.text("Expected a property name after "), .text(optionalChainBase.isNull ? "'.'" : "'?.'"))
                        )
                    }
                    base = context.createDotAccess(
                        &facade,
                        location,
                        base,
                        ident,
                        dotType,
                        expressionStart,
                        expressionDivot,
                        tokenEndPosition
                    )
                    if baseIsSuper && scopes[topScope].isArrowFunction {
                        scopes[currentFunctionScope().index].setInnerArrowFunctionUsesSuperProperty()
                    }
                    next([], &facade)
                case .backQuote:
                    if !optionalChainBase.isNull {
                        return semanticFail("Cannot use tagged templates in an optional chain")
                    }
                    if baseIsSuper {
                        return semanticFail("Cannot use super as tag for tagged templates")
                    }
                    let expressionDivot = tokenStartPosition
                    let savedNonLHSCount = parserState.nonLHSCount
                    defer { parserState.nonLHSCount = savedNonLHSCount }
                    let templateLiteral = parseTemplateLiteral(&context, .buildRawStrings, &facade)
                    if templateLiteral.isNull {
                        return fail("Cannot parse template literal")
                    }
                    base = context.createTaggedTemplate(
                        &facade,
                        location,
                        base,
                        templateLiteral,
                        expressionStart,
                        expressionDivot,
                        lastTokenEndPosition
                    )
                    seenTaggedTemplateInNonReparsingFunctionMode = true
                default:
                    break chain
                }
                previousBaseWasSuper = baseIsSuper
                baseIsSuper = false
                type = token.type
            }
            if !optionalChainBase.isNull {
                base = context.createOptionalChain(
                    &facade,
                    location,
                    isOptionalCall ? B.Expression.null : optionalChainBase,
                    base,
                    !match(.questionDot)
                )
            }
        } while match(.questionDot)

        if baseIsSuper {
            return semanticFail(newCount != 0 ? "Cannot use new with super call" : "super is not valid in this context")
        }
        while newCount > 0 {
            newCount -= 1
            base = context.createNewExpr(
                &facade,
                location,
                base,
                expressionStart,
                B.createsAST ? newTokenStartPositions[newBase + newCount] : JSC.JSTextPosition(),
                lastTokenEndPosition
            )
        }
        return base
    }

    // MARK: Arrow function

    mutating func parseArrowFunctionExpression<B: TreeBuilder>(
        _ context: inout B,
        _ isAsync: Bool,
        _ location: JSC.JSTokenLocation,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        var info = FunctionInfo<B>()
        info.name = facade.wellKnownIdentifier(.nullIdentifier)

        let savedParseMode = parseMode
        parseMode = isAsync ? .AsyncArrowFunctionMode : .ArrowFunctionMode
        defer { parseMode = savedParseMode }
        if !parseFunctionInfo(
            &context,
            .unnamed,
            nameIsInContainingScope: true,
            .None,
            .NotNeeded,
            location.startOffset,
            &info,
            .expression,
            functionConstructorParametersEndPosition: nil,
            &facade
        ) {
            return fail("Cannot parse arrow function expression")
        }

        return context.createArrowFunctionExpr(&facade, location, info)
    }

    // MARK: Unary expression

    @inline(never)
    private mutating func failOperatorRequiresReference<Result: TreeHandle>(_ op: JSC.JSTokenType, isPrefix: Bool) -> Result {
        semanticFail(
            ErrorMessage(.text("The "), .text(op.operatorName(isPrefix: isPrefix)), .text(" operator requires a reference expression"))
        )
    }

    @inline(never)
    private mutating func failSubexpressionOfOperator<Result: TreeHandle>(_ op: JSC.JSTokenType) -> Result {
        fail(ErrorMessage(.text("Cannot parse subexpression of "), .text(op.operatorName(isPrefix: true)), .text("operator")))
    }

    // The failure arms of the inlined unary production below are out-of-line helpers that build their own literals: a
    // literal built in the inlined body is hoisted by LICM and spilled in parseBinaryExpression's loop (rdar://193663779).
    @inline(never)
    private mutating func failMetaPropertyAfterPrefix<B: TreeBuilder>(
        _ context: inout B,
        _ expr: B.Expression,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        semanticFail(ErrorMessage(.text(metaPropertyName(&context, expr, &facade)), .text(" can't come after a prefix operator")))
    }

    @inline(never)
    private mutating func failMetaPropertyBeforePostfix<B: TreeBuilder>(
        _ context: inout B,
        _ expr: B.Expression,
        _ facade: inout JSC.JSParseFacade
    ) -> B.Expression {
        semanticFail(ErrorMessage(.text(metaPropertyName(&context, expr, &facade)), .text(" can't come before a postfix operator")))
    }

    // rdar://193663779
    @inline(never)
    private mutating func failPostfixNotReference<Result: TreeHandle>(isIncrement: Bool) -> Result {
        semanticFail(
            isIncrement
                ? "Postfix ++ operator applied to value that is not a reference"
                : "Postfix -- operator applied to value that is not a reference"
        )
    }

    // rdar://193663779
    @inline(never)
    private mutating func failDeleteUnqualified<Result: TreeHandle>() -> Result {
        semanticFail(
            ErrorMessage(
                .text("Cannot delete unqualified property '"),
                .identifier(parserState.lastIdentifier),
                .text("' in strict mode")
            )
        )
    }

    // rdar://193663779
    @inline(never)
    private mutating func failDeletePrivate<Result: TreeHandle>() -> Result {
        semanticFail(ErrorMessage(.text("Cannot delete private field "), .identifier(parserState.lastPrivateName)))
    }

    // rdar://193663779
    @inline(never)
    private mutating func failAwaitInStaticBlock<Result: TreeHandle>() -> Result {
        semanticFail("Cannot use 'await' within static block")
    }

    // rdar://193663779
    @inline(never)
    private mutating func failCannotParseMemberExpression<Result: TreeHandle>() -> Result {
        fail("Cannot parse member expression")
    }

    @inline(never)
    private mutating func failPrefixNotReference<Result: TreeHandle>(_ op: JSC.JSTokenType) -> Result {
        semanticFail(
            ErrorMessage(
                .text("Prefix "),
                .text(op == .plusPlus || op == .autoPlusPlus ? "++" : "--"),
                .text(" operator applied to value that is not a reference")
            )
        )
    }

    @inline(never)
    private mutating func failCannotModifyInStrictMode<Result: TreeHandle>() -> Result {
        semanticFail(ErrorMessage(.text("Cannot modify '"), .identifier(parserState.lastIdentifier), .text("' in strict mode")))
    }

    @inline(never)
    private mutating func failCannotBeModifiedInStrictMode<Result: TreeHandle>() -> Result {
        semanticFail(ErrorMessage(.text("'"), .identifier(parserState.lastIdentifier), .text("' cannot be modified in strict mode")))
    }

    /// parseUnaryExpression out of line, for parseAwaitExpression; parseBinaryExpression holds the inlined copy.
    @inline(never)
    mutating func parseUnaryExpressionOutOfLine<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        parseUnaryExpression(&context, &facade)
    }

    /// Inlined into parseBinaryExpression, so each nesting level costs two frames.
    @inline(always)
    mutating func parseUnaryExpression<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Expression {
        let savedUnaryToken = context.enterUnaryExpression()
        defer { context.leaveUnaryExpression(savedUnaryToken) }
        let savedAllowsIn = allowsIn
        allowsIn = true
        defer { allowsIn = savedAllowsIn }
        var tokenStackDepth: Int32 = 0
        var hasPrefixUpdateOp = false
        var lastOperator: JSC.JSTokenType?

        if match(.awaitKeyword) && !parserState.classFieldInitMasksAsync
            && (scopes[currentFunctionScope().index].isAsyncFunctionBoundary || isModuleParseMode)
        {
            if scopes[topScope].isStaticBlock {
                return failAwaitInStaticBlock()
            }
            return parseAwaitExpression(&context, &facade)
        }

        let location = tokenLocation

        while token.type.isUnaryOp {
            if hasPrefixUpdateOp, let lastOperator {
                return failOperatorRequiresReference(lastOperator, isPrefix: true)
            }
            if token.type.isUpdateOp {
                hasPrefixUpdateOp = true
            }
            lastOperator = token.type
            parserState.nonLHSCount &+= 1
            context.appendUnaryToken(&facade, &tokenStackDepth, Int32(bitPattern: token.type.rawValue), tokenStartPosition)
            next([], &facade)
            parserState.nonTrivialExpressionCount &+= 1
        }
        var subExprStart = tokenStartPosition
        var expr = parseMemberExpression(&context, &facade)
        if expr.isNull {
            if hasError {
                return .null
            }
            if let lastOperator {
                return failSubexpressionOfOperator(lastOperator)
            }
            return failCannotParseMemberExpression()
        }
        if let lastOperator, lastOperator.isUpdateOp {
            if context.isMetaProperty(&facade, expr) {
                return failMetaPropertyAfterPrefix(&context, expr, &facade)
            }
            if !isSimpleAssignmentTarget(&context, expr, ignoringStrictCheck: false, &facade) {
                return failPrefixNotReference(lastOperator)
            }
        }
        let isEvalOrArguments = strictMode && context.isResolve(&facade, expr) && parserState.lastIdentifier.isEvalOrArguments(&facade)
        if isEvalOrArguments && hasPrefixUpdateOp {
            return failCannotModifyInStrictMode()
        }
        switch token.type {
        case .plusPlus:
            if context.isMetaProperty(&facade, expr) {
                return failMetaPropertyBeforePostfix(&context, expr, &facade)
            }
            if !isSimpleAssignmentTarget(&context, expr, ignoringStrictCheck: false, &facade) {
                return failPostfixNotReference(isIncrement: true)
            }
            parserState.nonTrivialExpressionCount &+= 1
            parserState.nonLHSCount &+= 1
            expr = context.makePostfixNode(&facade, location, expr, .PlusPlus, subExprStart, lastTokenEndPosition, tokenEndPosition)
            parserState.assignmentCount &+= 1
            if isEvalOrArguments {
                return failCannotModifyInStrictMode()
            }
            if hasPrefixUpdateOp, let lastOperator {
                return failOperatorRequiresReference(lastOperator, isPrefix: false)
            }
            next([], &facade)
        case .minusMinus:
            if context.isMetaProperty(&facade, expr) {
                return failMetaPropertyBeforePostfix(&context, expr, &facade)
            }
            if !isSimpleAssignmentTarget(&context, expr, ignoringStrictCheck: false, &facade) {
                return failPostfixNotReference(isIncrement: false)
            }
            parserState.nonTrivialExpressionCount &+= 1
            parserState.nonLHSCount &+= 1
            expr = context.makePostfixNode(&facade, location, expr, .MinusMinus, subExprStart, lastTokenEndPosition, tokenEndPosition)
            parserState.assignmentCount &+= 1
            if isEvalOrArguments {
                return failCannotBeModifiedInStrictMode()
            }
            if hasPrefixUpdateOp, let lastOperator {
                return failOperatorRequiresReference(lastOperator, isPrefix: false)
            }
            next([], &facade)
        default:
            break
        }

        let end = lastTokenEndPosition
        while tokenStackDepth != 0 {
            subExprStart = context.unaryTokenStackLastStart(&facade, &tokenStackDepth)
            let tokenType = JSC.JSTokenType(rawValue: UInt32(bitPattern: context.unaryTokenStackLastType(&facade, &tokenStackDepth)))
            switch tokenType {
            case .exclamation:
                expr = context.createLogicalNot(&facade, location, expr)
            case .tilde:
                expr = context.makeBitwiseNotNode(&facade, location, expr)
            case .minus:
                expr = context.makeNegateNode(&facade, location, expr)
            case .plus:
                expr = context.createUnaryPlus(&facade, location, expr)
            case .plusPlus, .autoPlusPlus:
                expr = context.makePrefixNode(&facade, location, expr, .PlusPlus, subExprStart, subExprStart.advanced(by: 2), end)
                parserState.assignmentCount &+= 1
            case .minusMinus, .autoMinusMinus:
                expr = context.makePrefixNode(&facade, location, expr, .MinusMinus, subExprStart, subExprStart.advanced(by: 2), end)
                parserState.assignmentCount &+= 1
            case .typeofKeyword:
                expr = context.makeTypeOfNode(&facade, location, expr, subExprStart, subExprStart, end)
            case .voidKeyword:
                expr = context.createVoid(&facade, location, expr)
            case .deleteKeyword:
                if strictMode && context.isResolve(&facade, expr) {
                    return failDeleteUnqualified()
                }
                if context.isPrivateLocation(&facade, expr) {
                    return failDeletePrivate()
                }
                expr = context.makeDeleteNode(&facade, location, expr, subExprStart, end, end)
            default:
                // If we get here something has gone horribly horribly wrong
                preconditionFailure("not reached")
            }
            context.unaryTokenStackRemoveLast(&facade, &tokenStackDepth)
        }
        return expr
    }
}
